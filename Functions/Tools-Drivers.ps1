#Requires -Version 5.1
<#
.SYNOPSIS
    Treiberverteilung: Treiberpakete (INF-Ordner oder Hersteller-Setup EXE/MSI) aus einem eigenen Ordner
    auf den gewaehlten oder mehrere PCs ausrollen - mit Hardware-Pruefung und Versionsvergleich.
.DESCRIPTION
    Paketordner: Einstellungen > DriverFolder, sonst <Tool>\Treiberverteilung
      - ein Unterordner = ein Paket (entpackter Treiber mit INF-Dateien und/oder Setup); Ordner mit _ am Anfang werden ignoriert
      - eine EXE/MSI direkt im Ordner = ein Setup-Paket
    Einstellungen je Paket: <Ordner>\hu-driver.json bzw. <Datei>.hu-driver.json
    Art INF:   pnputil /add-driver <Ordner>\*.inf /subdirs /install  (Windows waehlt den besten Treiber)
               "Erzwingen": UpdateDriverForPlugAndPlayDevices mit INSTALLFLAG_FORCE je passender Hardware-ID
               (installiert auch, wenn Windows einen neueren/besser bewerteten Treiber hat)
    Art Setup: Hersteller-Installer mit Silent-Parametern (wie Softwareverteilung)
    Vorher/nachher: passende Geraete (Win32_PnPEntity HardwareID/CompatibleID) und aktiver Treiber (Win32_PnPSignedDriver).
    Kopie, Temp-Ordner und Worker kommen aus der Softwareverteilung (Tools-Software.ps1).
.NOTES
    Laeuft im UI-Thread (dot-source aus HUMig.ps1), die Arbeit selbst im Hintergrund.
    Zielmaschine: der/die gewaehlten PCs.
    Quellen: learn.microsoft.com - PnPUtil Command Syntax / PnPUtil Return Values / UpdateDriverForPlugAndPlayDevicesW
#>

function Get-DrvFolder {
    $f = "$($script:Settings.DriverFolder)".Trim()
    if ($f) { return $f }
    return (Join-Path $script:AppRoot 'Treiberverteilung')
}

# ----------------------------------------------------------------------------
# Gemeinsamer Code (lokal im UI UND am Ziel-PC): INF lesen, passende Geraete + aktiven Treiber ermitteln
# ----------------------------------------------------------------------------
$script:DrvLibText = @'
function Resolve-HUInfStr([string]$s, $str) {
    foreach ($m in [regex]::Matches("$s", '%([^%]+)%')) {
        $k = $m.Groups[1].Value.ToUpperInvariant()
        if ($str.ContainsKey($k)) { $s = $s.Replace($m.Value, $str[$k]) }
    }
    return "$s".Trim().Trim('"').Trim()
}
function Read-HUInf([string]$Path) {
    $b = [IO.File]::ReadAllBytes($Path)
    $enc = [Text.Encoding]::Default
    if ($b.Length -ge 2 -and $b[0] -eq 0xFF -and $b[1] -eq 0xFE) { $enc = [Text.Encoding]::Unicode }
    elseif ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { $enc = [Text.Encoding]::UTF8 }
    elseif ($b.Length -ge 4 -and $b[1] -eq 0 -and $b[3] -eq 0) { $enc = [Text.Encoding]::Unicode }
    $txt = $enc.GetString($b).TrimStart([char]0xFEFF)
    $sec = @{}; $cur = ''; $pending = ''
    $rxC = [regex]'^((?:[^;"]|"[^"]*(?:"|$))*)'
    foreach ($raw in ($txt -split "`r?`n")) {
        $l = $rxC.Match($raw).Groups[1].Value.Trim()
        if ($pending) { $l = $pending + $l; $pending = '' }
        if ($l.EndsWith('\')) { $pending = $l.Substring(0, $l.Length - 1); continue }
        if (-not $l) { continue }
        if ($l -match '^\[(.+)\]$') {
            $cur = $Matches[1].Trim().ToUpperInvariant()
            if (-not $sec.ContainsKey($cur)) { $sec[$cur] = [System.Collections.Generic.List[string]]::new() }
            continue
        }
        if ($cur) { $sec[$cur].Add($l) }
    }
    # Strings: [Strings] zuerst, fehlende Schluessel aus lokalisierten [Strings.xxxx]
    $str = @{}
    foreach ($k in @($sec.Keys | Where-Object { $_ -eq 'STRINGS' -or $_ -like 'STRINGS.*' } | Sort-Object { if ($_ -eq 'STRINGS') { 0 } else { 1 } }, { $_ })) {
        foreach ($l in $sec[$k]) { if ($l -match '^([^=]+?)\s*=\s*(.*)$') { $n = $Matches[1].Trim().ToUpperInvariant(); if (-not $str.ContainsKey($n)) { $str[$n] = $Matches[2].Trim().Trim('"') } } }
    }
    $ver = @{}
    if ($sec.ContainsKey('VERSION')) { foreach ($l in $sec['VERSION']) { if ($l -match '^([^=]+?)\s*=\s*(.*)$') { $ver[$Matches[1].Trim().ToUpperInvariant()] = Resolve-HUInfStr $Matches[2] $str } } }
    $date = ''; $version = ''
    if ("$($ver['DRIVERVER'])" -match '^\s*([0-9]{1,2}[/\-\.][0-9]{1,2}[/\-\.][0-9]{4})\s*(?:,\s*([0-9]+(?:\.[0-9]+){0,3}))?') { $date = $Matches[1]; $version = "$($Matches[2])" }
    $devs = [System.Collections.Generic.List[object]]::new(); $ids = [System.Collections.Generic.List[string]]::new(); $seen = @{}; $seenDev = @{}
    if ($sec.ContainsKey('MANUFACTURER')) {
        foreach ($l in $sec['MANUFACTURER']) {
            $rhs = if ($l -match '^[^=]*=\s*(.*)$') { $Matches[1] } else { $l }
            $parts = @($rhs -split ',' | ForEach-Object { $_.Trim().Trim('"').Trim() } | Where-Object { $_ })
            if ($parts.Count -eq 0) { continue }
            $base = Resolve-HUInfStr $parts[0] $str
            $names = @($base) + @($parts | Select-Object -Skip 1 | ForEach-Object { "$base.$_" })
            foreach ($sn in $names) {
                $key = $sn.ToUpperInvariant()
                if (-not $sec.ContainsKey($key)) { continue }
                foreach ($ml in $sec[$key]) {
                    if ($ml -notmatch '^([^=]*)=\s*(.*)$') { continue }
                    $desc = Resolve-HUInfStr $Matches[1] $str
                    $f = @($Matches[2] -split ',' | ForEach-Object { $_.Trim().Trim('"').Trim() })
                    $hw = @($f | Select-Object -Skip 1 | Where-Object { $_ } | ForEach-Object { $_.ToUpperInvariant() })
                    if ($hw.Count -eq 0) { continue }
                    $dk = "$desc|$($hw[0])"
                    if (-not $seenDev.ContainsKey($dk)) { $seenDev[$dk] = $true; $devs.Add([pscustomobject]@{ Desc = $desc; Ids = $hw }) }
                    foreach ($h in $hw) { if (-not $seen.ContainsKey($h)) { $seen[$h] = $true; $ids.Add($h) } }
                }
            }
        }
    }
    [pscustomobject]@{
        Path = $Path; Class = "$($ver['CLASS'])"; ClassGuid = "$($ver['CLASSGUID'])".ToUpperInvariant(); Provider = "$($ver['PROVIDER'])"
        Date = $date; Version = $version; Catalog = "$($ver['CATALOGFILE'])"; Devices = $devs.ToArray(); HwIds = $ids.ToArray()
    }
}
# Passende Geraete + aktiver Treiber. $HwMap: Hardware-ID (GROSS) -> Paket-Versionen (Array). $ClassGuids: nur fuer die Anzeige "gleiche Klasse"
function Get-HUDrvState($HwMap, [string[]]$ClassGuids = @()) {
    $rows = [System.Collections.Generic.List[object]]::new()
    $cls = @{}; foreach ($g in @($ClassGuids)) { if ($g) { $cls["$g".ToUpperInvariant()] = $true } }
    foreach ($e in @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue)) {
        if (-not $e.PNPDeviceID) { continue }
        $hit = ''
        foreach ($i in (@($e.HardwareID) + @($e.CompatibleID))) {
            if (-not $i) { continue }
            $u = "$i".ToUpperInvariant()
            if ($HwMap.ContainsKey($u)) { $hit = $u; break }
        }
        $sameCls = ($e.ClassGuid -and $cls.ContainsKey("$($e.ClassGuid)".ToUpperInvariant()))
        if (-not $hit -and -not $sameCls) { continue }
        $hwl = @(@($e.HardwareID) | Where-Object { $_ } | ForEach-Object { "$_".ToUpperInvariant() })
        # Sperr-ID: genaueste Hardware-ID ohne Revision (PCI: VEN&DEV&SUBSYS), sonst die erste
        $lk = @($hwl | Where-Object { $_ -notmatch '&REV_' })[0]; if (-not $lk) { $lk = @($hwl)[0] }
        $rows.Add([pscustomobject]@{ Id = "$($e.PNPDeviceID)"; Name = "$($e.Name)"; Hw = $hit; FirstHw = "$(@($e.HardwareID)[0])"; Match = [bool]$hit
                                     PkgVer = $(if ($hit) { (@($HwMap[$hit]) -join '/') } else { '' }); Err = [int]$e.ConfigManagerErrorCode
                                     Version = ''; Provider = ''; Date = ''; Inf = ''; LockId = "$lk"
                                     AllIds = @($hwl + @(@($e.CompatibleID) | Where-Object { $_ } | ForEach-Object { "$_".ToUpperInvariant() })) })
    }
    if ($rows.Count -gt 0) {
        $sd = @{}
        foreach ($d in @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue)) { if ($d.DeviceID) { $sd["$($d.DeviceID)".ToUpperInvariant()] = $d } }
        foreach ($r in $rows) {
            $d = $sd[$r.Id.ToUpperInvariant()]
            if (-not $d) { continue }
            $r.Version = "$($d.DriverVersion)"; $r.Provider = "$($d.DriverProviderName)"; $r.Inf = "$($d.InfName)"
            $r.Date = if ($d.DriverDate -is [datetime]) { $d.DriverDate.ToString('yyyy-MM-dd') } else { "$($d.DriverDate)" }
        }
    }
    return $rows.ToArray()
}
# --- Geraete-Sperre (Richtlinie "Installation von Geraeten verhindern, die diesen Geraete-IDs entsprechen", DeviceInstallation.admx)
#     nur Windows Pro/Education/Enterprise; HUMig merkt sich eigene Eintraege unter HKLM\SOFTWARE\HUMig\DriverLocks (Locks = ID|Paket|Version|Datum)
$HUDenyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions'
$HULockKey = 'HKLM:\SOFTWARE\HUMig\DriverLocks'
function Get-HUEdition {
    $ed = "$((Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name EditionID -ErrorAction SilentlyContinue).EditionID)"
    [pscustomobject]@{ Name = $ed; Ok = [bool]($ed -and $ed -notmatch '^Core') }
}
function Get-HUDenyIds {
    $k = $HUDenyKey + '\DenyDeviceIDs'
    if (-not (Test-Path -LiteralPath $k)) { return @() }
    $it = Get-Item -LiteralPath $k
    $names = @($it.GetValueNames() | Where-Object { $_ } | Sort-Object { $n = 0; [void][int]::TryParse($_, [ref]$n); $n }, { $_ })
    return @($names | ForEach-Object { "$($it.GetValue($_))".Trim() } | Where-Object { $_ })
}
function Set-HUDenyIds([string[]]$Ids) {
    $list = [System.Collections.Generic.List[string]]::new(); $seen = @{}
    foreach ($i in @($Ids)) { if ($i -and -not $seen.ContainsKey($i.ToUpperInvariant())) { $seen[$i.ToUpperInvariant()] = $true; $list.Add($i) } }
    $k = $HUDenyKey + '\DenyDeviceIDs'
    if (-not (Test-Path -LiteralPath $HUDenyKey)) { New-Item -Path $HUDenyKey -Force -ErrorAction Stop | Out-Null }
    if (Test-Path -LiteralPath $k) { Remove-Item -LiteralPath $k -Recurse -Force -ErrorAction Stop }
    if ($list.Count -gt 0) {
        New-Item -Path $k -Force -ErrorAction Stop | Out-Null
        for ($n = 0; $n -lt $list.Count; $n++) { New-ItemProperty -LiteralPath $k -Name "$($n + 1)" -Value $list[$n] -PropertyType String -Force -ErrorAction Stop | Out-Null }
        New-ItemProperty -LiteralPath $HUDenyKey -Name DenyDeviceIDs -Value 1 -PropertyType DWord -Force -ErrorAction Stop | Out-Null
        if ($null -eq (Get-ItemProperty -LiteralPath $HUDenyKey -Name DenyDeviceIDsRetroactive -ErrorAction SilentlyContinue)) { New-ItemProperty -LiteralPath $HUDenyKey -Name DenyDeviceIDsRetroactive -Value 0 -PropertyType DWord -Force | Out-Null }
    } else {
        Remove-ItemProperty -LiteralPath $HUDenyKey -Name DenyDeviceIDs, DenyDeviceIDsRetroactive -ErrorAction SilentlyContinue
    }
}
function Get-HULocks {
    $h = [ordered]@{}
    foreach ($l in @((Get-ItemProperty -LiteralPath $HULockKey -Name Locks -ErrorAction SilentlyContinue).Locks)) { if ("$l" -match '^([^|]+)\|(.*)$') { $h[$Matches[1].ToUpperInvariant()] = $Matches[2] } }
    return $h
}
function Save-HULocks($Locks) {
    $arr = @(foreach ($k in @($Locks.Keys)) { "$k|$($Locks[$k])" })
    if ($arr.Count -gt 0) {
        if (-not (Test-Path -LiteralPath $HULockKey)) { New-Item -Path $HULockKey -Force -ErrorAction Stop | Out-Null }
        New-ItemProperty -LiteralPath $HULockKey -Name Locks -Value ([string[]]$arr) -PropertyType MultiString -Force -ErrorAction Stop | Out-Null
    } elseif (Test-Path -LiteralPath $HULockKey) { Remove-ItemProperty -LiteralPath $HULockKey -Name Locks -ErrorAction SilentlyContinue }
}
# Sperre fuer die Zeilen (Get-HUDrvState) setzen, Rueckgabe = Hinweistext
function Set-HUDrvLock($Rows, [string]$Pkg) {
    $ed = Get-HUEdition
    if (-not $ed.Ok) { return " | Schutz NICHT gesetzt: Windows-Edition '$($ed.Name)' (Geraete-Sperre nur bei Pro/Education/Enterprise)" }
    $ret = (Get-ItemProperty -LiteralPath $HUDenyKey -Name DenyDeviceIDsRetroactive -ErrorAction SilentlyContinue).DenyDeviceIDsRetroactive
    if ("$ret" -eq '1') { return ' | Schutz NICHT gesetzt: DenyDeviceIDsRetroactive=1 ist aktiv (wuerde vorhandene Geraete entfernen)' }
    $ids = @($Rows | Where-Object { $_.LockId } | ForEach-Object { $_.LockId } | Sort-Object -Unique)
    if ($ids.Count -eq 0) { return ' | Schutz NICHT gesetzt: keine Hardware-ID' }
    $deny = @(Get-HUDenyIds)
    Set-HUDenyIds (@($deny) + @($ids))
    $l = Get-HULocks
    foreach ($r in @($Rows | Where-Object { $_.LockId })) { $l[$r.LockId] = "$Pkg|$($r.Version)|$(Get-Date -Format 'yyyy-MM-dd')" }
    Save-HULocks $l
    return " | vor Treiber-Updates geschuetzt (Geraete-Sperre: $($ids -join ', '))"
}
'@
# Lokal verfuegbar machen (UI: Paket-Info)
. ([scriptblock]::Create($script:DrvLibText))

# ----------------------------------------------------------------------------
# Pakete
# ----------------------------------------------------------------------------
$script:DrvInfCache = @{}
function Get-DrvInfSummary($Package) {
    $infs = [System.Collections.Generic.List[object]]::new()
    foreach ($rel in @($Package.InfFiles)) {
        $full = $Package.SrcPath + '\' + $rel
        $fi = Get-Item -LiteralPath $full -ErrorAction SilentlyContinue
        if (-not $fi) { continue }
        $key = "$($fi.FullName)|$($fi.Length)|$($fi.LastWriteTimeUtc.Ticks)"
        if (-not $script:DrvInfCache.ContainsKey($key)) {
            try { $script:DrvInfCache[$key] = Read-HUInf $fi.FullName }
            catch { $script:DrvInfCache[$key] = [pscustomobject]@{ Path = $fi.FullName; Class = ''; ClassGuid = ''; Provider = ''; Date = ''; Version = ''; Catalog = ''; Devices = @(); HwIds = @(); Error = "$($_.Exception.Message)" } }
        }
        $x = $script:DrvInfCache[$key]
        $infs.Add([pscustomobject]@{ Rel = $rel; Inf = $x })
    }
    $map = @{}; $cls = [System.Collections.Generic.List[string]]::new()
    foreach ($i in $infs) {
        if ($i.Inf.ClassGuid -and -not $cls.Contains($i.Inf.ClassGuid)) { $cls.Add($i.Inf.ClassGuid) }
        foreach ($h in @($i.Inf.HwIds)) {
            if (-not $map.ContainsKey($h)) { $map[$h] = [System.Collections.Generic.List[string]]::new() }
            $v = if ($i.Inf.Version) { $i.Inf.Version } else { '?' }
            if (-not $map[$h].Contains($v)) { $map[$h].Add($v) }
        }
    }
    return [pscustomobject]@{ Infs = $infs.ToArray(); HwMap = $map; ClassGuids = $cls.ToArray() }
}

function Get-DrvPackages {
    $dir = Get-DrvFolder
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    $list = [System.Collections.Generic.List[object]]::new()
    $setupExt = @('.exe', '.msi')
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Where-Object { $setupExt -contains $_.Extension.ToLower() } | Sort-Object Name)) {
        $list.Add([pscustomobject]@{ Id = $f.Name; IsDir = $false; SrcPath = $f.FullName; Candidates = @($f.Name); InfFiles = @(); ConfigPath = "$($f.FullName).hu-driver.json"; SizeMB = [math]::Round($f.Length / 1MB, 1) })
    }
    foreach ($d in @(Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '_*' } | Sort-Object Name)) {
        $all = @(Get-ChildItem -LiteralPath $d.FullName -File -Recurse -ErrorAction SilentlyContinue)
        $base = $d.FullName.TrimEnd('\') + '\'
        $infs = @($all | Where-Object { $_.Extension -ieq '.inf' } | Sort-Object FullName | Select-Object -First 400 | ForEach-Object { $_.FullName.Substring($base.Length) })
        # Setup-Kandidaten: oberste Ebene, sonst eine Ebene tiefer (ZIP mit Unterordner)
        $cand = @($all | Where-Object { $setupExt -contains $_.Extension.ToLower() -and $_.DirectoryName.TrimEnd('\') -ieq $d.FullName.TrimEnd('\') })
        if ($cand.Count -eq 0) { $cand = @($all | Where-Object { $setupExt -contains $_.Extension.ToLower() -and $_.Directory.Parent -and $_.Directory.Parent.FullName.TrimEnd('\') -ieq $d.FullName.TrimEnd('\') }) }
        $cand = @($cand | Sort-Object @{ E = { if ($_.Name -match '(?i)^(setup|install|installer)[^\\]*\.exe$') { 0 } elseif ($_.Extension -ieq '.msi') { 1 } else { 2 } } }, Name | ForEach-Object { $_.FullName.Substring($base.Length) })
        if ($infs.Count -eq 0 -and $cand.Count -eq 0) { continue }
        $size = ($all | Measure-Object Length -Sum).Sum
        $list.Add([pscustomobject]@{ Id = "$($d.Name)\"; IsDir = $true; SrcPath = $d.FullName; Candidates = $cand; InfFiles = $infs; ConfigPath = ($base + 'hu-driver.json'); SizeMB = [math]::Round($size / 1MB, 1) })
    }
    foreach ($p in $list) {
        $cfg = $null
        if (Test-Path -LiteralPath $p.ConfigPath) { try { $cfg = Get-Content -LiteralPath $p.ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $cfg = $null } }
        $inst = if ($cfg -and "$($cfg.Installer)" -and (@($p.Candidates) -contains "$($cfg.Installer)")) { "$($cfg.Installer)" } elseif (@($p.Candidates).Count) { @($p.Candidates)[0] } else { '' }
        $info = $null
        if ($inst) { $info = Get-SwInstallerInfo $(if ($p.IsDir) { $p.SrcPath + '\' + $inst } else { $p.SrcPath }) }
        $def = [ordered]@{
            Name = $(if (-not $p.IsDir -and $info -and $info.ProductName) { "$($info.ProductName) $($info.Version)".Trim() } elseif ($p.IsDir) { $p.Id.TrimEnd('\') } else { [IO.Path]::GetFileNameWithoutExtension($p.Id) })
            Mode = $(if (@($p.InfFiles).Count -gt 0) { 'Inf' } else { 'Setup' })
            Installer = $inst; Arguments = $(if ($info) { $info.Suggested } else { '' }); SuccessCodes = '0'
            TimeoutMin = 20; OnlyMatching = $true; ForceDriver = $false; ProtectDriver = $false; Note = ''
        }
        $set = [ordered]@{}
        foreach ($k in @($def.Keys)) {
            $has = $cfg -and (@($cfg.PSObject.Properties.Name) -contains $k) -and ($null -ne $cfg.$k)
            $set[$k] = if ($has) { $cfg.$k } else { $def[$k] }
        }
        $set.Installer = $inst
        if ($set.Mode -ne 'Inf' -and $set.Mode -ne 'Setup') { $set.Mode = $def.Mode }
        if ($set.Mode -eq 'Inf' -and @($p.InfFiles).Count -eq 0) { $set.Mode = 'Setup' }
        if ($set.Mode -eq 'Setup' -and -not $inst) { $set.Mode = 'Inf' }
        $set.OnlyMatching = [bool]$set.OnlyMatching; $set.ForceDriver = [bool]$set.ForceDriver; $set.ProtectDriver = [bool]$set.ProtectDriver
        $p | Add-Member -NotePropertyName Settings -NotePropertyValue ([pscustomobject]$set) -Force
        $p | Add-Member -NotePropertyName Info -NotePropertyValue $info -Force
        $p | Add-Member -NotePropertyName Configured -NotePropertyValue ([bool]$cfg) -Force
    }
    return $list.ToArray()
}

function Save-DrvSettings($Package, $Settings) {
    try {
        [pscustomobject]$Settings | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $Package.ConfigPath -Encoding UTF8 -Force -ErrorAction Stop
        return $true
    } catch { Out-Console "Einstellungen nicht gespeichert ($($Package.ConfigPath)): $($_.Exception.Message)" 'Error'; return $false }
}

function Confirm-DrvDeploy($Package, [string[]]$Hosts, [bool]$Force) {
    $s = $Package.Settings
    $how = if ($s.Mode -eq 'Inf') {
        if ($s.ForceDriver) { "INF erzwingen (UpdateDriverForPlugAndPlayDevices, auch aeltere Version) - $(@($Package.InfFiles).Count) INF-Datei(en)" }
        else { "pnputil /add-driver *.inf /subdirs /install - $(@($Package.InfFiles).Count) INF-Datei(en), Windows waehlt den besten Treiber" }
    } else { "Setup: `"$($s.Installer)`" $($s.Arguments)" }
    $hw = if ($s.OnlyMatching) { 'nur PCs mit passender Hardware' } else { 'auch ohne passende Hardware (Treiberspeicher)' }
    $prot = if ($s.ProtectDriver) { "`n  Schutz:   danach vor Treiber-Updates schuetzen (Geraete-Sperre, nur Windows Pro/Education/Enterprise)" } else { '' }
    $ziel = if ($Hosts.Count -le 5) { $Hosts -join ', ' } else { "$($Hosts.Count) PCs" }
    return (Confirm-Action "Treiber '$($s.Name)' installieren auf: $ziel`n`n  Art:      $how`n  Hardware: $hw$prot`n  Version:  $(if ($Force) { 'auch wenn dieselbe Version schon aktiv ist' } else { 'PCs mit derselben aktiven Version werden uebersprungen' })`n  Groesse:  $($Package.SizeMB) MB`n`nGeraete koennen dabei kurz ausfallen (Bildschirm flackert, Netzwerk trennt kurz).`nFortfahren?" 'Treiberverteilung')
}

# ----------------------------------------------------------------------------
# Skript am Ziel-PC (als Text: param + gemeinsamer Code + Ablauf)
# ----------------------------------------------------------------------------
$script:RS_DrvInstallBody = {
    $ErrorActionPreference = 'SilentlyContinue'
    function ConvertTo-HUVer([string]$v) { if ("$v" -match '^\d+(\.\d+){0,3}') { $t = $Matches[0]; if ($t -notmatch '\.') { $t += '.0' }; try { return [version]$t } catch { } }; return $null }
    function Format-HUState($rows) {
        $m = @($rows | Where-Object { $_.Match })
        if ($m.Count -eq 0) { return 'keine passenden Geraete' }
        return ((@($m | Group-Object { "$($_.Version) ($($_.Provider))" } | ForEach-Object { "$($_.Name) x$($_.Count)" })) -join ', ')
    }
    try {
        $p = $PkgJson | ConvertFrom-Json
        $wow = [Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess
        $sys = if ($wow) { Join-Path $env:SystemRoot 'Sysnative' } else { Join-Path $env:SystemRoot 'System32' }
        $safe = ("$($p.Name)" -replace '[^\w\-\.]', '_')
        $log = Join-Path $env:SystemRoot ("Temp\HU_DRV_{0}_{1}.log" -f $safe, (Get-Date -Format 'yyyyMMdd-HHmmss'))
        # INF-Dateien des Pakets lesen
        $infs = @(Get-ChildItem -LiteralPath $Dir -Recurse -File -Filter *.inf -ErrorAction SilentlyContinue | Select-Object -First 400)
        $parsed = @(foreach ($f in $infs) { try { Read-HUInf $f.FullName } catch { } })
        $map = @{}; $cls = @()
        foreach ($i in $parsed) {
            if ($i.ClassGuid -and $cls -notcontains $i.ClassGuid) { $cls += $i.ClassGuid }
            $v = if ($i.Version) { $i.Version } else { '?' }
            foreach ($h in @($i.HwIds)) { if (-not $map.ContainsKey($h)) { $map[$h] = @() }; if ($map[$h] -notcontains $v) { $map[$h] += $v } }
        }
        $before = @(Get-HUDrvState $map)
        $matched = @($before | Where-Object { $_.Match })
        if ($map.Count -gt 0 -and $matched.Count -eq 0 -and [bool]$p.OnlyMatching) { return "SKIP|keine passende Hardware ($(@($parsed).Count) INF, $($map.Count) Hardware-IDs)" }
        $protect = [bool]$p.ProtectDriver
        if (-not $Force -and $matched.Count -gt 0) {
            $same = @($matched | Where-Object { $_.Version -and (@($map[$_.Hw]) -contains $_.Version) })
            if ($same.Count -eq $matched.Count) {
                $ln = ''
                if ($protect) {
                    $own = Get-HULocks
                    $open = @($same | Where-Object { $_.LockId -and -not $own.Contains($_.LockId) })
                    $ln = if ($open.Count) { Set-HUDrvLock $same "$($p.Name)" } else { ' | Schutz bereits aktiv' }
                }
                return "SKIP|Version bereits aktiv: $(Format-HUState $before)$ln"
            }
        }
        # Geraete-Sperren: eigene (HUMig) fuer die Installation aufheben, fremde (GPO/Intune/Hand) melden
        $devIds = @{}; foreach ($m in $matched) { foreach ($i in @($m.AllIds)) { $devIds[$i] = $true } }
        $denyOrig = @(Get-HUDenyIds); $locksOrig = Get-HULocks
        $hitOwn = @($denyOrig | Where-Object { $devIds.ContainsKey($_.ToUpperInvariant()) -and $locksOrig.Contains($_.ToUpperInvariant()) })
        $hitForeign = @($denyOrig | Where-Object { $devIds.ContainsKey($_.ToUpperInvariant()) -and -not $locksOrig.Contains($_.ToUpperInvariant()) })
        if ($hitForeign.Count) { return "FEHLER|Geraet ist durch eine Richtlinie gesperrt ($($hitForeign -join ', ')) - Installation wuerde blockiert (GPO/Intune: Geraeteinstallation einschraenken pruefen)" }
        $lockRestore = $false; $lockNote = ''
        if ($hitOwn.Count) {
            $hitU = @($hitOwn | ForEach-Object { $_.ToUpperInvariant() })
            Set-HUDenyIds @($denyOrig | Where-Object { $hitU -notcontains $_.ToUpperInvariant() })
            $lockRestore = $true
        }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $tmo = [int]$p.TimeoutMin; if ($tmo -lt 1) { $tmo = 20 }
        $limitMs = $tmo * 60000
        $reboot = $false; $note = ''
        if ("$($p.Mode)" -eq 'Inf') {
            if ($infs.Count -eq 0) { return 'FEHLER|keine INF-Datei im Paket' }
            if ([bool]$p.ForceDriver -and $matched.Count -gt 0) {
                # Erzwingen: je passender Hardware-ID das INF, das sie enthaelt (INSTALLFLAG_FORCE 0x1 | INSTALLFLAG_NONINTERACTIVE 0x4)
                if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { return 'FEHLER|Erzwingen braucht 64-Bit-PowerShell am Ziel-PC' }
                if (-not ('HUDrv.NewDev' -as [type])) {
                    Add-Type -Namespace HUDrv -Name NewDev -ErrorAction Stop -MemberDefinition @'
[DllImport("newdev.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern bool UpdateDriverForPlugAndPlayDevicesW(IntPtr hwndParent, string HardwareId, string FullInfPath, uint InstallFlags, out bool bRebootRequired);
'@
                }
                $done = @(); $errs = @()
                foreach ($hw in @($matched | ForEach-Object { $_.Hw } | Sort-Object -Unique)) {
                    $inf = @($parsed | Where-Object { @($_.HwIds) -contains $hw } | Sort-Object { ConvertTo-HUVer $_.Version } -Descending | Select-Object -First 1)
                    if ($inf.Count -eq 0) { continue }
                    $rb = $false
                    $ok = [HUDrv.NewDev]::UpdateDriverForPlugAndPlayDevicesW([IntPtr]::Zero, $hw, $inf[0].Path, [uint32]5, [ref]$rb)
                    $le = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
                    Add-Content -LiteralPath $log -Value ("{0}  {1}  {2}  ok={3} err=0x{4:X8} reboot={5}" -f (Get-Date -Format 's'), $hw, $inf[0].Path, $ok, $le, $rb) -ErrorAction SilentlyContinue
                    if ($ok) { $done += $hw; if ($rb) { $reboot = $true } }
                    else {
                        $hx = '{0:X8}' -f $le
                        $errs += ('{0}: 0x{1}{2}' -f $hw, $hx, $(switch ($hx) { '00000103' { ' (nicht besser als der aktuelle)' } '00000002' { ' (Datei fehlt)' } 'E000020B' { ' (Geraet nicht vorhanden)' } '00000005' { ' (Zugriff verweigert)' } default { '' } }))
                    }
                }
                if ($done.Count -eq 0) { return "FEHLER|Erzwingen fehlgeschlagen: $($errs -join '; ') | Log: $log" }
                if ($errs.Count) { $note = " | teilweise: $($errs -join '; ')" }
            } else {
                $pnp = Join-Path $sys 'pnputil.exe'
                $args2 = "/add-driver `"$($Dir.TrimEnd('\'))\*.inf`" /subdirs"
                if ($matched.Count -gt 0) { $args2 += ' /install' }
                $psi = New-Object System.Diagnostics.ProcessStartInfo $pnp, $args2
                $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
                try { $psi.StandardOutputEncoding = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage) } catch { }
                $proc = [System.Diagnostics.Process]::Start($psi)
                $tOut = $proc.StandardOutput.ReadToEndAsync(); $tErr = $proc.StandardError.ReadToEndAsync()
                if (-not $proc.WaitForExit($limitMs)) { try { $proc.Kill() } catch { }; return "FEHLER|pnputil Timeout nach $tmo min" }
                $proc.WaitForExit()
                $rc = $proc.ExitCode
                Set-Content -LiteralPath $log -Value ("pnputil.exe $args2`r`nExitCode $rc`r`n`r`n" + $tOut.Result + "`r`n" + $tErr.Result) -Encoding UTF8 -ErrorAction SilentlyContinue
                switch ($rc) {
                    0 { }
                    3010 { $reboot = $true }
                    1641 { $reboot = $true }
                    259 {
                        $st = Format-HUState (Get-HUDrvState $map)
                        if ($matched.Count -eq 0) { return "OK|in den Treiberspeicher aufgenommen (keine passende Hardware - wird beim Anstecken verwendet) ($([int]$sw.Elapsed.TotalSeconds) s)" }
                        return "SKIP|Windows behaelt den vorhandenen Treiber (neuer oder besser bewertet) - aktiv: $st. Fuer diese Version 'Treiber erzwingen' einschalten | Log: $log"
                    }
                    default { return "FEHLER|pnputil ExitCode $rc | Log: $log (Details: C:\Windows\INF\setupapi.dev.log)" }
                }
                if ($matched.Count -eq 0) { return "OK|in den Treiberspeicher aufgenommen (keine passende Hardware) ($([int]$sw.Elapsed.TotalSeconds) s)" }
            }
        } else {
            $inst = $Dir.TrimEnd('\') + '\' + "$($p.Installer)"
            if (-not (Test-Path -LiteralPath $inst)) { return "FEHLER|Installer fehlt am Client ($($p.Installer))" }
            $a2 = "$($p.Arguments)".Trim()
            if ($inst -match '(?i)\.msi$') { $file = Join-Path $sys 'msiexec.exe'; $argLine = "/i `"$inst`" $a2 /l*v `"$log`"" } else { $file = $inst; $argLine = $a2 }
            $psi = New-Object System.Diagnostics.ProcessStartInfo $file, $argLine
            $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.WorkingDirectory = [IO.Path]::GetDirectoryName($inst)
            $dirEsc = $Dir.TrimEnd('\')
            function Get-HUPkgProcs { @(Get-CimInstance Win32_Process | Where-Object { ("$($_.ExecutablePath)" -like "$dirEsc\*") -or ("$($_.CommandLine)" -like "*$dirEsc\*") }) }
            $proc = [System.Diagnostics.Process]::Start($psi)
            if (-not $proc.WaitForExit($limitMs)) {
                try { $proc.Kill() } catch { }
                foreach ($x in (Get-HUPkgProcs)) { try { Stop-Process -Id $x.ProcessId -Force -ErrorAction Stop } catch { } }
                return "FEHLER|Timeout nach $tmo min - Setup beendet (wartet es auf Eingabe? Parameter pruefen)"
            }
            $rc = $proc.ExitCode
            Start-Sleep -Seconds 2
            while ($sw.ElapsedMilliseconds -lt $limitMs -and (Get-HUPkgProcs).Count -gt 0) { Start-Sleep -Seconds 3 }
            if ($sw.ElapsedMilliseconds -ge $limitMs) {
                foreach ($x in (Get-HUPkgProcs)) { try { Stop-Process -Id $x.ProcessId -Force -ErrorAction Stop } catch { } }
                return "FEHLER|Timeout nach $tmo min (Unterprozesse des Setups liefen noch)"
            }
            $okCodes = @("$($p.SuccessCodes)" -split '[,;\s]+' | Where-Object { $_ -match '^-?\d+$' } | ForEach-Object { [int]$_ })
            if ($okCodes.Count -eq 0) { $okCodes = @(0) }
            if ($rc -eq 3010 -or $rc -eq 1641) { $reboot = $true }
            elseif ($okCodes -notcontains $rc) { return "FEHLER|Setup ExitCode $rc ($([int]$sw.Elapsed.TotalSeconds) s)$(if ($argLine -match '/l\*v') { " | Log: $log" })" }
        }
        # Nachkontrolle
        $dur = "$([int]$sw.Elapsed.TotalSeconds) s"
        $rbTxt = if ($reboot) { ' - NEUSTART erforderlich' } else { '' }
        if ($map.Count -eq 0) { return "OK|installiert$rbTxt ($dur)$note" }
        $after = @(Get-HUDrvState $map)
        $am = @($after | Where-Object { $_.Match })
        $newOk = @($am | Where-Object { $_.Version -and (@($map[$_.Hw]) -contains $_.Version) })
        $notNew = @($am | Where-Object { -not ($_.Version -and (@($map[$_.Hw]) -contains $_.Version)) })
        $warn = if ($am.Count -gt 0 -and $notNew.Count -gt 0 -and -not $reboot) { " | ACHTUNG: $($notNew.Count) Geraet(e) noch mit anderer Version - Neustart pruefen" } else { '' }
        # Schutz setzen: nur Geraete, auf denen die Paket-Version jetzt aktiv ist
        if ($protect) {
            if ($newOk.Count) {
                $own = Get-HULocks
                foreach ($k in @($own.Keys)) { if ($hitOwn -contains $k) { $own.Remove($k) } }
                Save-HULocks $own
                $lockNote = Set-HUDrvLock $newOk "$($p.Name)"
            } else { $lockNote = ' | Schutz noch NICHT gesetzt (Version erst nach Neustart aktiv) - danach erneut verteilen, setzt dann nur den Schutz'; $lockRestore = $false }
            if ($lockNote -notlike ' | vor Treiber*') { $l2 = Get-HULocks; foreach ($k in @($hitOwn)) { $l2.Remove($k.ToUpperInvariant()) }; Save-HULocks $l2 }
        } elseif ($hitOwn.Count) {
            $l2 = Get-HULocks; foreach ($k in @($hitOwn)) { $l2.Remove($k.ToUpperInvariant()) }; Save-HULocks $l2
            $lockNote = ' | bisherige Geraete-Sperre aufgehoben (Paket ohne Schutz)'
        }
        $lockRestore = $false
        return "OK|installiert$rbTxt ($dur) - aktiv: $(Format-HUState $after)$warn$note$lockNote"
    } catch { return "FEHLER|$($_.Exception.Message -replace '[\r\n|]+', ' ')" }
    finally {
        # Installation fehlgeschlagen/abgebrochen: vorherige Geraete-Sperren wiederherstellen
        if ($lockRestore) { try { Set-HUDenyIds $denyOrig; Save-HULocks $locksOrig } catch { } }
        Set-Location -Path $env:SystemRoot
        if ($Dir -like "$env:ProgramData\HU_SW_*") { Start-Sleep -Seconds 1; Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
function Get-DrvInstallText {
    return "param([string]`$Dir, [string]`$PkgJson, [bool]`$Force)`n" + $script:DrvLibText + "`n" + $script:RS_DrvInstallBody.ToString()
}

# Pruefung am Ziel-PC ohne Installation: Zeilen ROW|...
$script:RS_DrvCheckBody = {
    $ErrorActionPreference = 'SilentlyContinue'
    $o = $InfoJson | ConvertFrom-Json
    $map = @{}
    foreach ($e in @($o.Map)) { if ($e.H) { $map["$($e.H)"] = @("$($e.V)" -split '/') } }
    $rows = @(Get-HUDrvState $map @($o.Cls))
    if ($rows.Count -eq 0) { return 'INFO|keine passenden Geraete und keine Geraete derselben Klasse' }
    $ed = Get-HUEdition
    'EDI|' + $ed.Name + '|' + $ed.Ok
    $deny = @{}; foreach ($d in @(Get-HUDenyIds)) { $deny[$d.ToUpperInvariant()] = $true }
    $own = Get-HULocks
    foreach ($r in $rows) {
        $lk = ''
        foreach ($i in @($r.AllIds)) { if ($deny.ContainsKey($i)) { $lk = if ($own.Contains($i)) { 'HUMig' } else { 'Richtlinie' }; break } }
        $st = 'passt - wuerde installiert'
        if (-not $r.Match) { $st = 'passt nicht' }
        elseif ($r.Version -and (@($map[$r.Hw]) -contains $r.Version)) { $st = 'gleiche Version aktiv' }
        else {
            $cv = $null; try { $cv = [version]$r.Version } catch { }
            $pv = @(foreach ($v in @($map[$r.Hw])) { try { [version]$v } catch { } })
            if ($cv -and $pv.Count -and @($pv | Where-Object { $_ -ge $cv }).Count -eq 0) { $st = 'passt - NEUERER Treiber aktiv (nur mit Erzwingen)' }
        }
        if ($r.Err) { $st += " (Geraetefehler $($r.Err))" }
        'ROW|' + ((@($r.Name, $st, $r.Version, $r.PkgVer, $lk, $r.Provider, $r.Date, $r.Inf, $(if ($r.Hw) { $r.Hw } else { $r.FirstHw }), $r.Id) | ForEach-Object { "$_" -replace '[|\r\n]', ' ' }) -join '|')
    }
}
function Get-DrvCheckText { return "param([string]`$InfoJson)`n" + $script:DrvLibText + "`n" + $script:RS_DrvCheckBody.ToString() }

function Start-DriverCheck($Package, [string]$Computer) {
    if (@($Package.InfFiles).Count -eq 0) { Out-Console "Treiber pruefen: '$($Package.Settings.Name)' enthaelt keine INF-Dateien - Hardware-Pruefung nicht moeglich (reines Setup)." 'Warning'; return }
    $sum = Get-DrvInfSummary $Package
    if ($sum.HwMap.Count -eq 0) { Out-Console "Treiber pruefen: keine Hardware-IDs in den INF-Dateien gefunden." 'Warning'; return }
    $json = [pscustomobject]@{ Map = @(foreach ($k in $sum.HwMap.Keys) { [pscustomobject]@{ H = $k; V = (@($sum.HwMap[$k]) -join '/') } }); Cls = @($sum.ClassGuids) } | ConvertTo-Json -Depth 4 -Compress
    Invoke-HMTool -Title "Treiber pruefen '$($Package.Settings.Name)'" -Computer $Computer -Script ([scriptblock]::Create((Get-DrvCheckText))) -ArgumentList @($json) -TimeoutSec 240 -State $Package -OnResult {
        param($r, $comp, $pkg)
        $rows = [System.Collections.Generic.List[object]]::new()
        foreach ($l in @($r)) {
            $t = "$l"
            if ($t -like 'INFO|*') { Out-Console "Treiber pruefen ($comp): $($t.Substring(5))" 'Warning'; return }
            if ($t -like 'EDI|*') { $e = $t -split '\|'; if ($e[2] -ne 'True') { Out-Console "Treiber pruefen ($comp): Windows-Edition '$($e[1])' - Schutz vor Treiber-Updates (Geraete-Sperre) nur bei Pro/Education/Enterprise" 'Warning' }; continue }
            if ($t -notlike 'ROW|*') { continue }
            $f = $t.Substring(4) -split '\|'
            if ($f.Count -ge 10) { $rows.Add(@($f[0], $f[1], $f[2], $f[3], $f[4], $f[5], $f[6], $f[7], $f[8], $f[9])) }
        }
        $m = @($rows | Where-Object { $_[1] -notlike 'passt nicht*' }).Count
        Out-Console "Treiber pruefen ($comp): $m passende Geraet(e), $($rows.Count - $m) weitere derselben Klasse" $(if ($m) { 'Success' } else { 'Warning' })
        Show-DataGridWindow -Title "Treiber pruefen - $($pkg.Settings.Name) - $comp" -Columns @('Geraet', 'Status', 'Aktive Version', 'Paket-Version', 'Gesperrt', 'Anbieter', 'Datum', 'INF', 'Hardware-ID', 'Instanz') `
            -Rows $rows.ToArray() -Sort 'Status DESC, Geraet ASC' -CountText "$($rows.Count) Geraete ($m passend)" -Width 1300 -Height 520
    }
}

# Geraete-Sperren am Ziel-PC anzeigen / aufheben
$script:RS_DrvLocksBody = {
    $ErrorActionPreference = 'SilentlyContinue'
    $ed = Get-HUEdition
    $out = [System.Collections.Generic.List[string]]::new()
    try {
        if ($Remove) {
            $rm = @($Remove -split '\|' | Where-Object { $_ } | ForEach-Object { $_.ToUpperInvariant() })
            $own = Get-HULocks
            $rm = @($rm | Where-Object { $own.Contains($_) })
            Set-HUDenyIds @(Get-HUDenyIds | Where-Object { $rm -notcontains $_.ToUpperInvariant() })
            foreach ($k in $rm) { $own.Remove($k) }
            Save-HULocks $own
            $out.Add("DONE|$($rm.Count)")
        }
    } catch { $out.Add("ERR|$($_.Exception.Message -replace '[\r\n|]+', ' ')") }
    $out.Add('EDI|' + $ed.Name + '|' + $ed.Ok)
    $ret = (Get-ItemProperty -LiteralPath $HUDenyKey -Name DenyDeviceIDsRetroactive -ErrorAction SilentlyContinue).DenyDeviceIDsRetroactive
    $out.Add("RET|$ret")
    $own = Get-HULocks
    $names = @{}
    foreach ($e in @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue)) { foreach ($i in (@($e.HardwareID) + @($e.CompatibleID))) { if ($i -and -not $names.ContainsKey("$i".ToUpperInvariant())) { $names["$i".ToUpperInvariant()] = "$($e.Name)" } } }
    foreach ($d in @(Get-HUDenyIds)) {
        $u = $d.ToUpperInvariant()
        $inf = if ($own.Contains($u)) { @("$($own[$u])" -split '\|') } else { @('', '', '') }
        $out.Add('LOCK|' + ((@($d, $(if ($own.Contains($u)) { 'HUMig' } else { 'Richtlinie/andere' }), "$($names[$u])", $inf[0], $(if ($inf.Count -gt 1) { $inf[1] }), $(if ($inf.Count -gt 2) { $inf[2] })) | ForEach-Object { "$_" -replace '[|\r\n]', ' ' }) -join '|'))
    }
    $out.ToArray()
}
function Get-DrvLocksText { return "param([string]`$Remove = '')`n" + $script:DrvLibText + "`n" + $script:RS_DrvLocksBody.ToString() }
function Show-DriverLocks([string]$Computer, [string]$Remove = '') {
    Invoke-HMTool -Title $(if ($Remove) { 'Geraete-Sperre aufheben' } else { 'Geraete-Sperren anzeigen' }) -Computer $Computer -Script ([scriptblock]::Create((Get-DrvLocksText))) -ArgumentList @($Remove) -TimeoutSec 180 -OnResult {
        param($r, $comp, $st)
        $rows = [System.Collections.Generic.List[object]]::new(); $edTxt = ''; $retTxt = ''
        foreach ($l in @($r)) {
            $t = "$l"; $f = $t -split '\|'
            switch -Wildcard ($t) {
                'DONE|*' { Out-Console "Geraete-Sperre ($comp): $($f[1]) Sperre(n) aufgehoben" 'Success' }
                'ERR|*'  { Out-Console "Geraete-Sperre ($comp): FEHLER $($f[1])" 'Error' }
                'EDI|*'  { $edTxt = "Windows-Edition: $($f[1])$(if ($f[2] -ne 'True') { ' - Geraete-Sperre wird hier NICHT unterstuetzt (nur Pro/Education/Enterprise)' })" }
                'RET|*'  { if ("$($f[1])" -eq '1') { $retTxt = '  |  ACHTUNG: DenyDeviceIDsRetroactive=1 (Richtlinie gilt auch fuer installierte Geraete)' } }
                'LOCK|*' { if ($f.Count -ge 7) { $rows.Add(@($f[1], $f[2], $f[3], $f[4], $f[5], $f[6])) } }
            }
        }
        Out-Console "Geraete-Sperren ($comp): $($rows.Count) Hardware-ID(s) gesperrt. $edTxt" 'Info'
        Show-DataGridWindow -Title "Geraete-Sperren (Schutz vor Treiber-Updates) - $comp" -Columns @('Hardware-ID', 'Von', 'Geraet', 'Paket', 'Version', 'Seit') -Rows $rows.ToArray() -Sort 'Von ASC, Geraet ASC' `
            -CountText "$($rows.Count) gesperrt  |  $edTxt$retTxt" -Width 1150 -Height 460 -ActionContext @{ Computer = $comp } `
            -Actions @(@{ Text = 'Sperre aufheben (markierte, nur HUMig)'; Color = '#FFFAB387'; Handler = {
                param($rows, $win, $ctx)
                $sel = @(@($rows) | Where-Object { "$($_.Von)" -eq 'HUMig' } | ForEach-Object { "$($_.'Hardware-ID')" })
                if (-not $sel.Count) { [void][System.Windows.MessageBox]::Show($win, "Nur von HUMig gesetzte Sperren koennen hier aufgehoben werden.`n`nAndere kommen aus einer Richtlinie (GPO/Intune) oder wurden von Hand gesetzt.", 'Geraete-Sperre', 'OK', 'Information'); return }
                if ("$([System.Windows.MessageBox]::Show($win, "Sperre fuer $($sel.Count) Hardware-ID(s) an $($ctx.Computer) aufheben?`n`nDanach kann Windows Update den Treiber wieder ersetzen.", 'Geraete-Sperre', 'YesNo', 'Question'))" -ne 'Yes') { return }
                $win.Close()
                Show-DriverLocks -Computer $ctx.Computer -Remove ($sel -join '|')
            } })
    }
}

# ----------------------------------------------------------------------------
# Verteilung (Worker, Temp-Ordner und Kopie wie Softwareverteilung)
# ----------------------------------------------------------------------------
function Start-DriverDeploy {
    param([string[]]$Hosts, [object]$Package, [bool]$Force = $false, [string]$Label = '')
    $Hosts = @($Hosts | Where-Object { $_ } | ForEach-Object { "$_".Trim() } | Where-Object { $_ } | Sort-Object -Unique)
    if ($Hosts.Count -eq 0 -or -not $Package) { return }
    $s = $Package.Settings
    $pkg = [ordered]@{ Name = "$($s.Name)"; Mode = "$($s.Mode)"; Installer = "$($s.Installer)"; Arguments = "$($s.Arguments)"; SuccessCodes = "$($s.SuccessCodes)"
                       TimeoutMin = [int]$s.TimeoutMin; OnlyMatching = [bool]$s.OnlyMatching; ForceDriver = [bool]$s.ForceDriver; ProtectDriver = [bool]$s.ProtectDriver }
    $pkgJson = [pscustomobject]$pkg | ConvertTo-Json -Compress
    Out-Console "Treiberverteilung '$($s.Name)' auf $($Hosts.Count) PC(s)$(if ($Label) { " [$Label]" })$(if ($Force) { ' - auch wenn gleiche Version aktiv' }) ..." 'Info'
    $tmo = [int]$s.TimeoutMin; if ($tmo -lt 1) { $tmo = 20 }
    $jobSec = [int][Math]::Max(1800, ([Math]::Ceiling($Hosts.Count / 8.0) * (($tmo + 15) * 60 + [double]$Package.SizeMB)))
    Invoke-AsyncCommand -ScriptBlock {
        param($hostStr, $src, $isDir, $pkgJson, $force, $prepText, $instText, $cleanText, $workerText, $sizeMB, $timeoutMin, $deadlineSec)
        $list = @($hostStr -split '\|' | Where-Object { $_ })
        $deadline = (Get-Date).AddSeconds($deadlineSec)
        $pool = [runspacefactory]::CreateRunspacePool(1, 8); $pool.Open()
        $jobs = foreach ($h in $list) {
            $ps = [PowerShell]::Create().AddScript($workerText).AddArgument($h).AddArgument($src).AddArgument($isDir).AddArgument($pkgJson).AddArgument($force).AddArgument($prepText).AddArgument($instText).AddArgument($cleanText).AddArgument($sizeMB).AddArgument($timeoutMin)
            $ps.RunspacePool = $pool
            [pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke(); Host = $h }
        }
        $out = [System.Collections.Generic.List[string]]::new()
        while (@($jobs | Where-Object { -not $_.Handle.IsCompleted }).Count -gt 0 -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
        $stuck = 0
        foreach ($j in @($jobs)) {
            if ($j.Handle.IsCompleted) {
                try { foreach ($x in $j.PS.EndInvoke($j.Handle)) { if ("$x") { $out.Add("$x") } } }
                catch { $out.Add("RES:$($j.Host)|FEHLER|$($_.Exception.Message -replace '[\r\n|]+', ' ')") }
                finally { $j.PS.Dispose() }
            } else {
                $stuck++
                $out.Add("RES:$($j.Host)|FEHLER|Zeitlimit des Tools erreicht - Kopie/Installation lief noch (Ergebnis am Client pruefen)")
                try { [void]$j.PS.BeginStop($null, $null) } catch { }
            }
        }
        if ($stuck -eq 0) { try { $pool.Close(); $pool.Dispose() } catch { } }
        $out -join "`n"
    } -ArgumentList @(($Hosts -join '|'), $Package.SrcPath, [bool]$Package.IsDir, $pkgJson, $Force, $script:RS_SwPrep.ToString(), (Get-DrvInstallText), $script:RS_SwCleanup.ToString(), $script:SwWorkerText, [double]$Package.SizeMB, $tmo, ($jobSec - 60)) `
      -TimeoutSec $jobSec -State @{ Name = "$($s.Name)"; Hosts = $Hosts; Package = $Package; Force = $Force } -OnComplete {
        param($result, $st)
        $r = "$result".Trim()
        if ($r -match '^FEHLER:') { Out-Console "Treiberverteilung: $r" 'Error'; return }
        $rows = [System.Collections.Generic.List[object]]::new()
        $seen = @{}
        foreach ($l in ($r -split "`r?`n")) {
            if ($l -notmatch '^RES:([^|]*)\|(OK|SKIP|FEHLER)\|(.*)$') { continue }
            $seen[$Matches[1].ToUpper()] = $true
            $rows.Add(@($Matches[1], $Matches[2], (Format-RemoteError $Matches[3])))
        }
        foreach ($h in $st.Hosts) { if (-not $seen.ContainsKey($h.ToUpper())) { $rows.Add(@($h, 'FEHLER', 'keine Antwort')) } }
        $ok = @($rows | Where-Object { $_[1] -eq 'OK' }).Count; $sk = @($rows | Where-Object { $_[1] -eq 'SKIP' }).Count; $bad = $rows.Count - $ok - $sk
        $rows.Sort([System.Comparison[object]] { param($x, $y) [string]::Compare("$($x[0])", "$($y[0])", $true) })
        foreach ($rw in $rows) {
            $lvl = switch ($rw[1]) { 'OK' { if ("$($rw[2])" -match 'ACHTUNG') { 'Warning' } else { 'Success' } } 'SKIP' { 'Warning' } default { 'Error' } }
            Out-Console "  $($rw[0]): $($rw[2])" $lvl
        }
        Out-Console "Treiberverteilung '$($st.Name)': $ok installiert / $sk uebersprungen / $bad Fehler" $(if ($bad) { 'Warning' } else { 'Success' })
        if ($rows.Count -gt 1) {
            Show-DataGridWindow -Title "Treiberverteilung - $($st.Name)" -Columns @('Computer', 'Status', 'Ergebnis') -Rows $rows.ToArray() -Sort 'Status ASC, Computer ASC' `
                -CountText "$($rows.Count) PCs ($ok OK / $sk uebersprungen / $bad Fehler)" -Width 1200 -Height 560 -ActionContext @{ Package = $st.Package; Force = $st.Force } `
                -Actions @(@{ Text = 'Erneut installieren (markierte)'; Color = '#FFFAB387'; Handler = {
                    param($rows, $win, $ctx)
                    $h = @(@($rows) | ForEach-Object { "$($_.Computer)" })
                    if ("$([System.Windows.MessageBox]::Show($win, "Treiber '$($ctx.Package.Settings.Name)' erneut auf $($h.Count) PC(s) installieren?", 'Treiberverteilung', 'YesNo', 'Question'))" -ne 'Yes') { return }
                    Start-DriverDeploy -Hosts $h -Package $ctx.Package -Force ([bool]$ctx.Force) -Label 'Wiederholung'
                } })
        }
    }
}

# ----------------------------------------------------------------------------
# Pakete hinzufuegen (im Hintergrund kopieren / entpacken)
# ----------------------------------------------------------------------------
function Get-DrvFreeName([string]$Name) {
    $root = Get-DrvFolder
    $n = ($Name -replace '[\\/:*?"<>|]', '_').Trim().TrimStart('_')
    if (-not $n) { $n = 'Treiber' }
    $c = $n; $i = 2
    while (Test-Path -LiteralPath ($root.TrimEnd('\') + '\' + $c)) { $c = "$n ($i)"; $i++ }
    return $c
}
function Add-DrvPackage([string]$Source, [string]$Kind) {
    $root = Get-DrvFolder
    try { if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Path $root -Force -ErrorAction Stop | Out-Null } } catch { Out-Console "Ordner nicht anlegbar: $root" 'Error'; return }
    $name = if ($Kind -eq 'Folder') { Split-Path -Leaf $Source.TrimEnd('\') } else { [IO.Path]::GetFileNameWithoutExtension($Source) }
    if ($Kind -eq 'File') {
        $dst = $root.TrimEnd('\') + '\' + [IO.Path]::GetFileName($Source)
        if ((Test-Path -LiteralPath $dst) -and -not (Confirm-Action "$([IO.Path]::GetFileName($Source)) ist schon in der Treiberverteilung. Ersetzen?" 'Treiberverteilung')) { return }
    } else { $dst = $root.TrimEnd('\') + '\' + (Get-DrvFreeName $name) }
    if ($Kind -eq 'Folder' -and $dst.TrimEnd('\').StartsWith($Source.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { Out-Console 'Der Treiberverteilungs-Ordner liegt im gewaehlten Ordner - bitte den Treiber-Unterordner waehlen.' 'Error'; return }
    Out-Console "Treiberverteilung: $([IO.Path]::GetFileName($Source.TrimEnd('\'))) wird $(if ($Kind -in 'Zip', 'Cab') { 'entpackt' } else { 'kopiert' }) ..." 'Info'
    Invoke-AsyncCommand -ScriptBlock {
        param($src, $dst, $kind)
        try {
            switch ($kind) {
                'Folder' { Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force -ErrorAction Stop }
                'File'   { Copy-Item -LiteralPath $src -Destination $dst -Force -ErrorAction Stop }
                'Zip' {
                    Add-Type -AssemblyName System.IO.Compression.FileSystem
                    [System.IO.Compression.ZipFile]::ExtractToDirectory($src, $dst)
                }
                'Cab' {
                    New-Item -ItemType Directory -Path $dst -Force -ErrorAction Stop | Out-Null
                    $o = & (Join-Path $env:SystemRoot 'System32\expand.exe') -F:* "$src" "$dst" 2>&1 | Out-String
                    if ($LASTEXITCODE -ne 0) { throw "expand.exe ExitCode $LASTEXITCODE $($o.Trim())" }
                }
            }
            "OK|$dst"
        } catch {
            if ($kind -ne 'File' -and (Test-Path -LiteralPath $dst)) { Remove-Item -LiteralPath $dst -Recurse -Force -ErrorAction SilentlyContinue }
            "FEHLER|$($_.Exception.Message)"
        }
    } -ArgumentList @($Source, $dst, $Kind) -TimeoutSec 3600 -State @{ Dst = $dst; IsFile = ($Kind -eq 'File') } -OnComplete {
        param($r, $st)
        $t = "$r"
        if ($t -like 'OK|*') {
            Out-Console "Treiberverteilung: hinzugefuegt - $($st.Dst)" 'Success'
            $leaf = Split-Path -Leaf $st.Dst
            Update-DrvWindowList $(if ($st.IsFile) { $leaf } else { "$leaf\" })
        } else { Out-Console "Treiberverteilung: hinzufuegen fehlgeschlagen - $($t -replace '^FEHLER\|', '')" 'Error' }
    }
}

# ----------------------------------------------------------------------------
# Fenster Treiberverteilung
# ----------------------------------------------------------------------------
$script:DrvUi = $null
function Update-DrvWindowList([string]$SelectId = '') {
    $dw = $script:DrvUi; if (-not $dw -or -not $dw.Win.IsVisible) { return }
    $dw.Pkgs = @(Get-DrvPackages)
    $dw.Loading = $true
    $dw.Lst.Items.Clear()
    foreach ($p in $dw.Pkgs) {
        $k = if ($p.Settings.Mode -eq 'Inf') { "INF x$(@($p.InfFiles).Count)$(if ($p.Settings.ForceDriver) { ', erzwingen' })$(if ($p.Settings.ProtectDriver) { ', geschuetzt' })" } else { 'Setup' }
        [void]$dw.Lst.Items.Add("$(if ($p.Configured) { '' } else { '* ' })$($p.Settings.Name)   [$k]")
    }
    $dw.Loading = $false
    $dw.LblFolder.Text = "Ordner: $(Get-DrvFolder)   ($($dw.Pkgs.Count) Pakete, * = noch nicht gespeichert)"
    $dw.LblTarget.Text = "Gewaehlter Computer: $(Get-TargetComputer)"
    $idx = 0
    if ($SelectId) { for ($i = 0; $i -lt $dw.Pkgs.Count; $i++) { if ($dw.Pkgs[$i].Id -eq $SelectId) { $idx = $i } } }
    if ($dw.Pkgs.Count -gt 0) { $dw.Lst.SelectedIndex = -1; $dw.Lst.SelectedIndex = $idx } else { Show-DrvPackageDetails $null }
}
function Set-DrvModeUi {
    $dw = $script:DrvUi
    $inf = ("$($dw.CmbMode.SelectedItem)" -like 'INF*')
    foreach ($c in 'CmbInst', 'CmbArgs', 'TxtCodes') { $dw[$c].IsEnabled = (-not $inf) }
    $dw.ChkForceDrv.IsEnabled = $inf
    $i = $dw.Lst.SelectedIndex
    $dw.ChkProtect.IsEnabled = ($inf -or ($i -ge 0 -and $i -lt $dw.Pkgs.Count -and @($dw.Pkgs[$i].InfFiles).Count -gt 0))
    if ($dw.CmbInst.Items.Count -le 1) { $dw.CmbInst.IsEnabled = $false }
}
function Show-DrvPackageDetails($p) {
    $dw = $script:DrvUi; if (-not $dw) { return }
    $dw.Loading = $true
    try {
        $dw.CmbInst.Items.Clear(); $dw.CmbArgs.Items.Clear(); $dw.CmbMode.Items.Clear()
        if (-not $p) {
            foreach ($c in 'TxtName', 'TxtCodes', 'TxtTimeout', 'TxtNote') { $dw[$c].Text = '' }
            $dw.CmbArgs.Text = ''; $dw.ChkMatch.IsChecked = $true; $dw.ChkForceDrv.IsChecked = $false; $dw.ChkProtect.IsChecked = $false
            $dw.TxtInfo.Text = "Noch keine Treiber.`n`n'Ordner hinzufuegen': entpackter Treiber mit INF-Dateien (z.B. vom Hersteller oder aus dem Microsoft Update-Katalog).`n'Datei hinzufuegen': Setup (EXE/MSI) oder ZIP/CAB (wird entpackt).`n`nJeder Unterordner im Treiberverteilungs-Ordner ist ein Paket."
            return
        }
        $s = $p.Settings
        $hasInf = (@($p.InfFiles).Count -gt 0); $hasSetup = (@($p.Candidates).Count -gt 0)
        if ($hasInf) { [void]$dw.CmbMode.Items.Add('INF (pnputil)') }
        if ($hasSetup) { [void]$dw.CmbMode.Items.Add('Setup (EXE/MSI)') }
        $dw.CmbMode.SelectedItem = if ($s.Mode -eq 'Inf') { 'INF (pnputil)' } else { 'Setup (EXE/MSI)' }
        $dw.CmbMode.IsEnabled = ($dw.CmbMode.Items.Count -gt 1)
        foreach ($c in @($p.Candidates)) { [void]$dw.CmbInst.Items.Add($c) }
        if ($s.Installer) { $dw.CmbInst.SelectedItem = "$($s.Installer)" }
        $dw.TxtName.Text = "$($s.Name)"
        if ($p.Info) { foreach ($a in @($p.Info.Alternatives)) { if ($a) { [void]$dw.CmbArgs.Items.Add($a) } } }
        $dw.CmbArgs.Text = "$($s.Arguments)"
        $dw.TxtCodes.Text = "$($s.SuccessCodes)"; $dw.TxtTimeout.Text = "$($s.TimeoutMin)"; $dw.TxtNote.Text = "$($s.Note)"
        $dw.ChkMatch.IsChecked = [bool]$s.OnlyMatching; $dw.ChkForceDrv.IsChecked = [bool]$s.ForceDriver; $dw.ChkProtect.IsChecked = [bool]$s.ProtectDriver
        Set-DrvModeUi
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add("Paket:        $($p.Id)   ($($p.SizeMB) MB$(if ($p.IsDir) { ', ganzer Ordner wird kopiert' }))$(if (-not $p.Configured) { '   - noch nicht gespeichert' })")
        if ($hasInf) {
            $sum = Get-DrvInfSummary $p
            $inf = @($sum.Infs | ForEach-Object { $_.Inf })
            $lines.Add("INF-Dateien:  $(@($p.InfFiles).Count)$(if (@($p.InfFiles).Count -ge 400) { ' (nur die ersten 400)' })")
            $lines.Add("Klasse:       $((@($inf | ForEach-Object { $_.Class } | Where-Object { $_ } | Sort-Object -Unique)) -join ', ')")
            $lines.Add("Anbieter:     $((@($inf | ForEach-Object { $_.Provider } | Where-Object { $_ } | Sort-Object -Unique)) -join ', ')")
            $lines.Add("Version:      $((@($inf | ForEach-Object { if ($_.Version) { "$($_.Version) ($($_.Date))" } } | Sort-Object -Unique)) -join ', ')")
            $lines.Add("Hardware-IDs: $($sum.HwMap.Count)")
            $bad = @($inf | Where-Object { $_.PSObject.Properties['Error'] })
            if ($bad.Count) { $lines.Add("NICHT LESBAR: $((@($bad | ForEach-Object { Split-Path -Leaf $_.Path })) -join ', ')") }
            $lines.Add('')
            foreach ($i in @($sum.Infs | Select-Object -First 15)) {
                $lines.Add("  $($i.Rel)   [$($i.Inf.Class) $($i.Inf.Version), $(@($i.Inf.HwIds).Count) IDs]")
                foreach ($d in @($i.Inf.Devices | Select-Object -First 4)) { $lines.Add("      $($d.Desc)   $(@($d.Ids)[0])") }
                if (@($i.Inf.Devices).Count -gt 4) { $lines.Add("      ... $(@($i.Inf.Devices).Count - 4) weitere") }
            }
            if (@($sum.Infs).Count -gt 15) { $lines.Add("  ... $(@($sum.Infs).Count - 15) weitere INF-Dateien") }
        }
        if ($hasSetup -and $p.Info) {
            $lines.Add('')
            $lines.Add("Setup:        $($s.Installer)   $($p.Info.ProductName) $($p.Info.Version) - $($p.Info.Manufacturer)")
            $lines.Add("Framework:    $($p.Info.Framework)   Vorschlag: $($p.Info.Suggested)")
            if ($p.Info.Note) { $lines.Add("HINWEIS: $($p.Info.Note)") }
            $lines.Add('HINWEIS: Silent-Parameter von Treiber-Setups sind herstellerspezifisch - Herstellerdoku pruefen (oft: setup.exe /? lokal).')
        }
        $lines.Add('')
        $lines.Add('INF: Windows installiert nur, wenn der Treiber besser/neuer ist als der vorhandene.')
        $lines.Add("     'Treiber erzwingen' installiert diese Version trotzdem (z.B. aeltere, besser funktionierende Version).")
        $lines.Add("     'Vor Treiber-Updates schuetzen' sperrt danach die Geraete (Windows Pro/Education/Enterprise) -")
        $lines.Add('     Windows Update und andere Treiber-Installationen aendern den Treiber dann nicht mehr.')
        $dw.TxtInfo.Text = ($lines -join "`r`n")
    } finally { $dw.Loading = $false }
}
function Get-DrvFormSettings {
    $dw = $script:DrvUi
    $name = "$($dw.TxtName.Text)".Trim(); if (-not $name) { throw 'Name fehlt' }
    $mode = if ("$($dw.CmbMode.SelectedItem)" -like 'INF*') { 'Inf' } else { 'Setup' }
    $codes = "$($dw.TxtCodes.Text)".Trim(); if (-not $codes) { $codes = '0' }
    if (@($codes -split '[,;\s]+' | Where-Object { $_ -notmatch '^-?\d+$' }).Count -gt 0) { throw 'Erfolgs-ExitCodes: nur Zahlen, mit Komma getrennt (z.B. 0,1)' }
    $tmo = 0; if (-not [int]::TryParse("$($dw.TxtTimeout.Text)".Trim(), [ref]$tmo) -or $tmo -lt 1 -or $tmo -gt 600) { throw 'Timeout: 1 bis 600 Minuten' }
    return [ordered]@{
        Name = $name; Mode = $mode; Installer = "$($dw.CmbInst.SelectedItem)"; Arguments = "$($dw.CmbArgs.Text)".Trim(); SuccessCodes = $codes
        TimeoutMin = $tmo; OnlyMatching = [bool]$dw.ChkMatch.IsChecked; ForceDriver = [bool]$dw.ChkForceDrv.IsChecked; ProtectDriver = [bool]$dw.ChkProtect.IsChecked; Note = "$($dw.TxtNote.Text)".Trim()
    }
}
function Save-DrvForm {
    $dw = $script:DrvUi
    $i = $dw.Lst.SelectedIndex
    if ($i -lt 0 -or $i -ge $dw.Pkgs.Count) { return $null }
    $p = $dw.Pkgs[$i]
    try { $set = Get-DrvFormSettings } catch { [void][System.Windows.MessageBox]::Show($dw.Win, "$($_.Exception.Message)", 'Treiberverteilung', 'OK', 'Warning'); return $null }
    if ($set.Mode -eq 'Setup' -and -not $set.Arguments) {
        if ("$([System.Windows.MessageBox]::Show($dw.Win, "Keine Parameter fuer das Setup angegeben.`n`nOhne Silent-Parameter kann das Setup am Client unsichtbar auf eine Eingabe warten (bis zum Timeout).`n`nTrotzdem speichern?", 'Treiberverteilung', 'YesNo', 'Warning'))" -ne 'Yes') { return $null }
    }
    if ($set.Mode -eq 'Inf' -and $set.ForceDriver -and -not [bool]$p.Settings.ForceDriver) {
        if ("$([System.Windows.MessageBox]::Show($dw.Win, "Treiber erzwingen: Diese Version wird auf passende Geraete installiert, auch wenn Windows einen neueren oder besser bewerteten Treiber hat.`n`nNur verwenden, wenn genau diese Version gewuenscht ist. Weiter?", 'Treiberverteilung', 'YesNo', 'Warning'))" -ne 'Yes') { return $null }
    }
    if ($set.ProtectDriver -and -not [bool]$p.Settings.ProtectDriver) {
        if ("$([System.Windows.MessageBox]::Show($dw.Win, "Vor Treiber-Updates schuetzen:`n`nNach der Installation setzt HUMig am PC die Richtlinie 'Installation von Geraeten verhindern, die diesen Geraete-IDs entsprechen' fuer die betroffenen Geraete. Windows Update (und jede andere Treiber-Installation) aendert den Treiber dieser Geraete dann nicht mehr.`n`n- Nur Windows Pro, Education und Enterprise (bei Home wird nichts gesetzt).`n- Eine GPO/Intune-Richtlinie zur Geraeteinstallation ueberschreibt die lokale Einstellung.`n- Neue Treiber aus HUMig: die Sperre wird dafuer automatisch kurz aufgehoben.`n- Aufheben: 'Sperren am PC ...'.`n`nWeiter?", 'Treiberverteilung', 'YesNo', 'Question'))" -ne 'Yes') { return $null }
    }
    if (-not (Save-DrvSettings $p $set)) { return $null }
    Out-Console "Treiberverteilung: Einstellungen fuer '$($set.Name)' gespeichert" 'Success'
    $id = $p.Id
    Update-DrvWindowList $id
    return ($dw.Pkgs | Where-Object { $_.Id -eq $id } | Select-Object -First 1)
}

function Show-DriverWindow {
    if ($script:DrvUi -and $script:DrvUi.Win -and $script:DrvUi.Win.IsVisible) { [void]$script:DrvUi.Win.Activate(); Update-DrvWindowList; return }
    $dir = Get-DrvFolder
    try { if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null } } catch { Out-Console "Ordner nicht anlegbar: $dir" 'Error' }
    $dx = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="HUMig - Treiberverteilung" Height="720" Width="1120" MinHeight="480" MinWidth="840"
        WindowStartupLocation="CenterOwner" Background="#FF1E1E2E">
  <Window.Resources>
    <Style TargetType="TextBlock"><Setter Property="Foreground" Value="#FFA6ADC8"/><Setter Property="VerticalAlignment" Value="Center"/></Style>
    <Style TargetType="TextBox"><Setter Property="Background" Value="#FF313244"/><Setter Property="Foreground" Value="#FFCDD6F4"/><Setter Property="BorderBrush" Value="#FF585B70"/><Setter Property="CaretBrush" Value="#FFCDD6F4"/><Setter Property="Padding" Value="4,2"/><Setter Property="Margin" Value="0,2,0,2"/></Style>
    <Style TargetType="Button"><Setter Property="Height" Value="28"/><Setter Property="Margin" Value="0,0,6,0"/><Setter Property="Cursor" Value="Hand"/><Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Foreground" Value="#FF1E1E2E"/><Setter Property="Padding" Value="10,0"/></Style>
    <Style TargetType="CheckBox"><Setter Property="Foreground" Value="#FFCDD6F4"/><Setter Property="VerticalAlignment" Value="Center"/><Setter Property="Margin" Value="0,4,0,4"/></Style>
  </Window.Resources>
  <DockPanel Margin="8">
    <DockPanel DockPanel.Dock="Top" Margin="0,0,0,6">
      <Image x:Name="imgLogo" DockPanel.Dock="Left" Width="30" Height="30" Margin="0,0,8,0" RenderOptions.BitmapScalingMode="HighQuality"/>
      <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
        <Button x:Name="btnAddDir" Content="Ordner hinzufuegen" Background="#FFA6E3A1" ToolTip="Entpackten Treiber (Ordner mit INF-Dateien und/oder Setup) in die Treiberverteilung kopieren"/>
        <Button x:Name="btnAddFile" Content="Datei hinzufuegen" Background="#FFA6E3A1" ToolTip="Setup (EXE/MSI) kopieren oder ZIP/CAB als eigenes Paket entpacken"/>
        <Button x:Name="btnOpen" Content="Ordner oeffnen" Background="#FF89B4FA"/>
        <Button x:Name="btnReload" Content="Aktualisieren" Background="#FF89B4FA" Margin="0"/>
      </StackPanel>
      <TextBlock x:Name="lblFolder" TextTrimming="CharacterEllipsis"/>
    </DockPanel>
    <Border DockPanel.Dock="Bottom" Background="#FF181825" Padding="6" Margin="0,6,0,0">
      <DockPanel>
        <CheckBox x:Name="chkForce" DockPanel.Dock="Right" Content="auch wenn diese Version schon aktiv ist" Margin="0"/>
        <StackPanel Orientation="Horizontal">
          <TextBlock Text="Installieren auf:" Margin="0,0,8,0" Foreground="#FFF9E2AF"/>
          <Button x:Name="btnClient" Content="Gewaehlten Computer" Background="#FFA6E3A1"/>
          <Button x:Name="btnMultiSel" Content="Mehrere PCs ..." Background="#FFA6E3A1" ToolTip="PCs aus dem Active Directory anhaken (OU, Filter) oder Namen eintragen - installiert wird parallel (bis zu 8 gleichzeitig)"/>
          <TextBlock x:Name="lblTarget" Margin="8,0,0,0"/>
        </StackPanel>
      </DockPanel>
    </Border>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="330"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <ListBox x:Name="lstPkg" Grid.Column="0" Background="#FF313244" Foreground="#FFCDD6F4" BorderBrush="#FF585B70" Margin="0,0,8,0" FontSize="12"/>
      <DockPanel Grid.Column="1">
        <Grid DockPanel.Dock="Top">
          <Grid.ColumnDefinitions><ColumnDefinition Width="150"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
          <Grid.RowDefinitions><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
          <TextBlock Grid.Row="0" Text="Name:"/>              <TextBox x:Name="txtName" Grid.Row="0" Grid.Column="1"/>
          <TextBlock Grid.Row="1" Text="Art:"/>               <ComboBox x:Name="cmbMode" Grid.Row="1" Grid.Column="1" Width="220" HorizontalAlignment="Left" Margin="0,2,0,2" ToolTip="INF = Treiber aus INF-Dateien per pnputil (empfohlen). Setup = Hersteller-Installer mit Silent-Parametern"/>
          <TextBlock Grid.Row="2" Text="Setup:"/>             <ComboBox x:Name="cmbInst" Grid.Row="2" Grid.Column="1" Margin="0,2,0,2"/>
          <TextBlock Grid.Row="3" Text="Parameter:"/>         <ComboBox x:Name="cmbArgs" Grid.Row="3" Grid.Column="1" IsEditable="True" Margin="0,2,0,2" FontFamily="Consolas" ToolTip="Silent-Parameter des Setups (nur Art Setup). MSI: msiexec /i und das Log werden automatisch ergaenzt"/>
          <TextBlock Grid.Row="4" Text="Erfolgs-ExitCodes:"/> <TextBox x:Name="txtCodes" Grid.Row="4" Grid.Column="1" Width="160" HorizontalAlignment="Left" ToolTip="Nur Art Setup. Komma-getrennt, z.B. 0 oder 0,1 - 3010/1641 gelten immer als Erfolg mit Neustart"/>
          <TextBlock Grid.Row="5" Text="Timeout (Minuten):"/> <TextBox x:Name="txtTimeout" Grid.Row="5" Grid.Column="1" Width="80" HorizontalAlignment="Left"/>
          <TextBlock Grid.Row="6" Text="Hardware:"/>          <CheckBox x:Name="chkMatch" Grid.Row="6" Grid.Column="1" Content="nur installieren, wenn passende Hardware vorhanden ist (sonst: in den Treiberspeicher aufnehmen)"/>
          <TextBlock Grid.Row="7" Text="Erzwingen:"/>         <CheckBox x:Name="chkForceDrv" Grid.Row="7" Grid.Column="1" Content="Treiber erzwingen - auch wenn Windows einen neueren/besser bewerteten Treiber hat (nur INF)"/>
          <TextBlock Grid.Row="8" Text="Schutz:"/>            <CheckBox x:Name="chkProtect" Grid.Row="8" Grid.Column="1" Content="nach der Installation vor Treiber-Updates schuetzen (Geraete-Sperre - nur Windows Pro/Education/Enterprise)" ToolTip="Setzt am PC die Richtlinie 'Installation von Geraeten verhindern, die diesen Geraete-IDs entsprechen' fuer die Geraete mit diesem Treiber. Windows Update ersetzt den Treiber dann nicht mehr. HUMig hebt die Sperre fuer eigene spaetere Installationen selbst auf."/>
          <TextBlock Grid.Row="9" Text="Notiz:"/>             <TextBox x:Name="txtNote" Grid.Row="9" Grid.Column="1"/>
        </Grid>
        <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,6,0,6">
          <Button x:Name="btnSave" Content="Speichern" Background="#FFF9E2AF"/>
          <Button x:Name="btnCheck" Content="Am gewaehlten PC pruefen" Background="#FF94E2D5" ToolTip="Zeigt passende Geraete und den aktiven Treiber am gewaehlten Computer - installiert nichts"/>
          <Button x:Name="btnLocks" Content="Sperren am PC ..." Background="#FFCBA6F7" ToolTip="Geraete-Sperren (Schutz vor Treiber-Updates) am gewaehlten Computer anzeigen und aufheben"/>
        </StackPanel>
        <TextBox x:Name="txtInfo" IsReadOnly="True" FontFamily="Consolas" FontSize="11" TextWrapping="NoWrap" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"/>
      </DockPanel>
    </Grid>
  </DockPanel>
</Window>
"@
    $w = [System.Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new(([xml]$dx)))
    if ($script:AppIcon) { $w.Icon = $script:AppIcon }
    if ($script:LogoImage) { $w.FindName('imgLogo').Source = $script:LogoImage }
    $script:DrvUi = @{
        Win = $w; Pkgs = @(); Loading = $false
        Lst = $w.FindName('lstPkg'); LblFolder = $w.FindName('lblFolder'); LblTarget = $w.FindName('lblTarget')
        TxtName = $w.FindName('txtName'); CmbMode = $w.FindName('cmbMode'); CmbInst = $w.FindName('cmbInst'); CmbArgs = $w.FindName('cmbArgs')
        TxtCodes = $w.FindName('txtCodes'); TxtTimeout = $w.FindName('txtTimeout'); ChkMatch = $w.FindName('chkMatch'); ChkForceDrv = $w.FindName('chkForceDrv')
        TxtNote = $w.FindName('txtNote'); TxtInfo = $w.FindName('txtInfo'); ChkForce = $w.FindName('chkForce'); ChkProtect = $w.FindName('chkProtect')
    }
    # Handler ohne GetNewClosure -> Skript-Funktionen sichtbar; Zustand in $script:DrvUi
    $script:DrvUi.Lst.Add_SelectionChanged({
        $dw = $script:DrvUi
        if ($dw.Loading) { return }
        $i = $dw.Lst.SelectedIndex
        if ($i -ge 0 -and $i -lt $dw.Pkgs.Count) { Show-DrvPackageDetails $dw.Pkgs[$i] }
    })
    $script:DrvUi.CmbMode.Add_SelectionChanged({ if (-not $script:DrvUi.Loading) { Set-DrvModeUi } })
    $script:DrvUi.CmbInst.Add_SelectionChanged({
        $dw = $script:DrvUi
        if ($dw.Loading) { return }
        $i = $dw.Lst.SelectedIndex
        if ($i -lt 0 -or $i -ge $dw.Pkgs.Count) { return }
        $p = $dw.Pkgs[$i]
        $inst = "$($dw.CmbInst.SelectedItem)"; if (-not $inst) { return }
        $info = Get-SwInstallerInfo $(if ($p.IsDir) { $p.SrcPath + '\' + $inst } else { $p.SrcPath })
        if ($info) {
            $dw.CmbArgs.Items.Clear(); foreach ($a in @($info.Alternatives)) { if ($a) { [void]$dw.CmbArgs.Items.Add($a) } }
            $dw.CmbArgs.Text = $info.Suggested
        }
    })
    $w.FindName('btnAddDir').Add_Click({
        $d = New-Object System.Windows.Forms.FolderBrowserDialog
        $d.Description = 'Entpackten Treiber-Ordner waehlen (mit INF-Dateien und/oder Setup) - wird als Paket kopiert'
        if ($d.ShowDialog() -ne 'OK' -or -not $d.SelectedPath) { return }
        $src = $d.SelectedPath
        $n = @(Get-ChildItem -LiteralPath $src -Recurse -File -Filter *.inf -ErrorAction SilentlyContinue | Select-Object -First 1).Count
        $e = @(Get-ChildItem -LiteralPath $src -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.exe', '.msi' } | Select-Object -First 1).Count
        if (-not $n -and -not $e) { [void][System.Windows.MessageBox]::Show($script:DrvUi.Win, "Im Ordner sind weder INF-Dateien noch ein Setup (EXE/MSI).`n`n$src", 'Treiberverteilung', 'OK', 'Warning'); return }
        Add-DrvPackage -Source $src -Kind 'Folder'
    })
    $w.FindName('btnAddFile').Add_Click({
        $d = New-Object Microsoft.Win32.OpenFileDialog
        $d.Filter = 'Treiber (*.exe;*.msi;*.zip;*.cab)|*.exe;*.msi;*.zip;*.cab'
        $d.Multiselect = $true
        $d.Title = 'Setup kopieren bzw. ZIP/CAB entpacken (Treiberverteilung)'
        if ($d.ShowDialog() -ne $true) { return }
        foreach ($f in $d.FileNames) {
            $k = switch ([IO.Path]::GetExtension($f).ToLower()) { '.zip' { 'Zip' } '.cab' { 'Cab' } default { 'File' } }
            Add-DrvPackage -Source $f -Kind $k
        }
    })
    $w.FindName('btnOpen').Add_Click({ $d = Get-DrvFolder; if (Test-Path -LiteralPath $d) { Start-Process explorer.exe -ArgumentList "`"$d`"" } })
    $w.FindName('btnReload').Add_Click({ $script:DrvInfCache = @{}; $script:SwInfoCache = @{}; $dw = $script:DrvUi; $sel = if ($dw.Lst.SelectedIndex -ge 0) { $dw.Pkgs[$dw.Lst.SelectedIndex].Id } else { '' }; Update-DrvWindowList $sel })
    $w.FindName('btnSave').Add_Click({ [void](Save-DrvForm) })
    $w.FindName('btnCheck').Add_Click({
        $dw = $script:DrvUi; $i = $dw.Lst.SelectedIndex
        if ($i -lt 0 -or $i -ge $dw.Pkgs.Count) { return }
        Start-DriverCheck -Package $dw.Pkgs[$i] -Computer (Get-TargetComputer)
    })
    $w.FindName('btnLocks').Add_Click({ Show-DriverLocks -Computer (Get-TargetComputer) })
    $w.Add_Activated({ if ($script:DrvUi) { $script:DrvUi.LblTarget.Text = "Gewaehlter Computer: $(Get-TargetComputer)" } })
    $w.FindName('btnClient').Add_Click({
        $dw = $script:DrvUi
        $h = Get-TargetComputer
        $p = Save-DrvForm; if (-not $p) { return }
        $force = [bool]$dw.ChkForce.IsChecked
        if (-not (Confirm-DrvDeploy -Package $p -Hosts @($h) -Force $force)) { return }
        Start-DriverDeploy -Hosts @($h) -Package $p -Force $force
    })
    $w.FindName('btnMultiSel').Add_Click({
        $dw = $script:DrvUi
        $p = Save-DrvForm; if (-not $p) { return }
        $script:DrvPick = @{ Package = $p; Force = [bool]$dw.ChkForce.IsChecked }
        # PCs aus dem AD anhaken (Filter/OU) oder Namen eintragen
        Show-HMMultiDialog -PickTitle "Treiber '$($p.Settings.Name)'" -Owner $dw.Win -OnPick {
            param($hosts)
            $pp = $script:DrvPick; if (-not $pp) { return }
            $hosts = @($hosts | Where-Object { $_ } | Sort-Object -Unique)
            if (-not $hosts.Count) { return }
            if (-not (Confirm-DrvDeploy -Package $pp.Package -Hosts $hosts -Force $pp.Force)) { return }
            Start-DriverDeploy -Hosts $hosts -Package $pp.Package -Force $pp.Force -Label 'Mehrere PCs'
        }
    })
    $w.Add_Closed({ $script:DrvUi = $null })
    $w.Owner = $script:Window; Set-HMWindowScale $w
    $w.Show()
    Update-DrvWindowList
}
