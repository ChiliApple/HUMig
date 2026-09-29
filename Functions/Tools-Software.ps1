#Requires -Version 5.1
<#
.SYNOPSIS
    Softwareverteilung: Pakete aus einem Ordner auf den gewaehlten oder mehrere PCs installieren (silent),
    inkl. Erkennung ob schon installiert, Mindestversion, Erfolgs-ExitCodes, Timeout, Neustart-Erkennung.
    Dazu: Software-Inventar (installierte Programme) als Tabelle.
.DESCRIPTION
    Paketordner: Einstellungen > SoftwareFolder, sonst <Tool>\Softwareverteilung
      - eine Datei (.msi/.exe/.msp) = ein Paket
      - ein Unterordner = ein Paket mit allen Dateien (Installer + Zubehoer); Ordner mit _ am Anfang werden ignoriert
    Einstellungen je Paket: <Datei>.hu.json bzw. <Ordner>\hu-package.json
    Ablauf am Ziel: Temp-Ordner (nur SYSTEM/Admins) -> Kopie -> Erkennung -> Installation (MSI-Log in C:\Windows\Temp)
                    -> Warten auf Unterprozesse -> Nachkontrolle -> Temp-Ordner loeschen.
    Eigener PC: direkt (ohne WinRM). Andere PCs: PowerShell-Remoting, bis zu 8 parallel.
.NOTES
    Laeuft im UI-Thread (dot-source aus HUMig.ps1), die Arbeit selbst im Hintergrund.
    Zielmaschine: der/die gewaehlten PCs.
#>

function Get-SwFolder {
    $f = "$($script:Settings.SoftwareFolder)".Trim()
    if ($f) { return $f }
    return (Join-Path $script:AppRoot 'Softwareverteilung')
}

# Installer analysieren: MSI-Eigenschaften (Windows Installer COM, nur lesend) bzw. EXE-Framework (Signaturen im Stub)
$script:SwInfoCache = @{}
function Get-SwInstallerInfo([string]$Path) {
    $fi = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $fi) { return $null }
    $key = "$($fi.FullName)|$($fi.Length)|$($fi.LastWriteTimeUtc.Ticks)"
    if ($script:SwInfoCache.ContainsKey($key)) { return $script:SwInfoCache[$key] }
    $ext = $fi.Extension.ToLower()
    $info = [pscustomobject]@{ Type = 'EXE'; Framework = 'unbekannt'; Suggested = ''; Alternatives = @(); ProductName = ''; Version = ''; Manufacturer = ''; ProductCode = ''; Props = @(); Note = '' }
    if ($ext -eq '.msi' -or $ext -eq '.msp') {
        $info.Type = if ($ext -eq '.msp') { 'MSP' } else { 'MSI' }
        $info.Framework = "Windows Installer ($($info.Type))"
        $info.Suggested = '/qn /norestart'
        $info.Alternatives = @('/qn /norestart', '/qn /norestart ALLUSERS=1', '/qb! /norestart', '/passive /norestart')
        if ($info.Type -eq 'MSI') {
            $wi = $null; $db = $null; $view = $null
            try {
                $wi = New-Object -ComObject WindowsInstaller.Installer
                $db = $wi.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $wi, @($fi.FullName, 0))
                $view = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db, @('SELECT `Property`, `Value` FROM `Property`'))
                [void]$view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null)
                $props = New-Object System.Collections.Generic.List[string]
                while ($true) {
                    $rec = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
                    if ($null -eq $rec) { break }
                    $pn = "$($rec.GetType().InvokeMember('StringData', 'GetProperty', $null, $rec, @(1)))"
                    $pv = "$($rec.GetType().InvokeMember('StringData', 'GetProperty', $null, $rec, @(2)))"
                    switch ($pn) { 'ProductName' { $info.ProductName = $pv } 'ProductVersion' { $info.Version = $pv } 'Manufacturer' { $info.Manufacturer = $pv } 'ProductCode' { $info.ProductCode = $pv } }
                    # Oeffentliche Eigenschaften (GROSSBUCHSTABEN) sind per Befehlszeile setzbar
                    if ($pn -cmatch '^[A-Z][A-Z0-9_]+$') { $props.Add("$pn=$pv") }
                    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($rec)
                }
                $info.Props = $props.ToArray()
            } catch { $info.Note = "MSI nicht lesbar: $($_.Exception.Message)" }
            finally {
                if ($view) { try { [void]$view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, $null) } catch { }; [void][Runtime.InteropServices.Marshal]::ReleaseComObject($view) }
                if ($db) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($db) }
                if ($wi) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($wi) }
                [GC]::Collect(); [GC]::WaitForPendingFinalizers()
            }
        }
    } else {
        try {
            $vi = [Diagnostics.FileVersionInfo]::GetVersionInfo($fi.FullName)
            $info.ProductName = "$($vi.ProductName)".Trim(); $info.Version = "$($vi.ProductVersion)".Trim(); $info.Manufacturer = "$($vi.CompanyName)".Trim()
        } catch { }
        $txt = ''
        try {
            $fs = [IO.File]::OpenRead($fi.FullName)
            try { $len = [int][Math]::Min($fs.Length, 4MB); $buf = New-Object byte[] $len; [void]$fs.Read($buf, 0, $len) } finally { $fs.Dispose() }
            $txt = [Text.Encoding]::GetEncoding(28591).GetString($buf)
        } catch { }
        # Reihenfolge wichtig: spezifische Signaturen zuerst
        if     ($txt -match 'Inno Setup')          { $info.Framework = 'Inno Setup';         $info.Suggested = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-'; $info.Alternatives = @('/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-', '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /ALLUSERS', '/SILENT /NORESTART') }
        elseif ($txt -match 'Nullsoft|NSIS Error') { $info.Framework = 'NSIS (Nullsoft)';    $info.Suggested = '/S'; $info.Alternatives = @('/S', '/S /AllUsers', '/S /D=C:\Program Files\<Ordner>'); $info.Note = 'NSIS: /S ist gross-/kleinschreibungsabhaengig; /D= muss der LETZTE Parameter sein.' }
        elseif ($txt -match '\.wixburn|WixBundle') { $info.Framework = 'WiX Burn Bundle';    $info.Suggested = '/quiet /norestart'; $info.Alternatives = @('/quiet /norestart', '/passive /norestart') }
        elseif ($txt -match 'Advanced Installer')  { $info.Framework = 'Advanced Installer'; $info.Suggested = '/exenoui /qn /norestart'; $info.Alternatives = @('/exenoui /qn /norestart', '/quiet /norestart') }
        elseif ($txt -match 'InstallShield')       { $info.Framework = 'InstallShield';      $info.Suggested = '/s /v"/qn /norestart"'; $info.Alternatives = @('/s /v"/qn /norestart"', '/S /v/qn', '/s'); $info.Note = 'InstallShield: je nach Projekttyp unterschiedlich (Basic MSI vs. InstallScript) - Herstellerdoku pruefen.' }
        elseif ($txt -match 'Squirrel')            { $info.Framework = 'Squirrel';           $info.Suggested = '--silent'; $info.Alternatives = @('--silent'); $info.Note = 'Squirrel installiert meist PRO BENUTZER (AppData) - fuer Geraete-Installation eher MSI/MSIX des Herstellers nehmen.' }
        elseif ($txt -match '7-Zip|;!@Install@!')  { $info.Framework = '7-Zip SFX';          $info.Suggested = ''; $info.Alternatives = @(''); $info.Note = '7-Zip-SFX: Parameter haengen vom enthaltenen Installer ab - besser entpacken und als Ordner-Paket ablegen.' }
        else { $info.Suggested = '/S'; $info.Alternatives = @('/S', '/silent', '/quiet /norestart', '/VERYSILENT /NORESTART'); $info.Note = 'Framework nicht erkannt - Parameter sind nur geraten, bitte Herstellerdoku pruefen (oft: setup.exe /? lokal ausfuehren).' }
    }
    $script:SwInfoCache[$key] = $info
    return $info
}

function Get-SwPackages {
    $dir = Get-SwFolder
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.msi', '.exe', '.msp' } | Sort-Object Name)) {
        $list.Add([pscustomobject]@{ Id = $f.Name; IsDir = $false; SrcPath = $f.FullName; Candidates = @($f.Name); ConfigPath = "$($f.FullName).hu.json"; SizeMB = [math]::Round($f.Length / 1MB, 1) })
    }
    foreach ($d in @(Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '_*' } | Sort-Object Name)) {
        $c = @(Get-ChildItem -LiteralPath $d.FullName -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.msi', '.exe', '.msp' } | Sort-Object @{ E = { if ($_.Extension -eq '.msi') { 0 } else { 1 } } }, Name | ForEach-Object { $_.Name })
        if ($c.Count -eq 0) { continue }
        $size = (Get-ChildItem -LiteralPath $d.FullName -File -Recurse -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
        $list.Add([pscustomobject]@{ Id = "$($d.Name)\"; IsDir = $true; SrcPath = $d.FullName; Candidates = $c; ConfigPath = (Join-Path $d.FullName 'hu-package.json'); SizeMB = [math]::Round($size / 1MB, 1) })
    }
    foreach ($p in $list) {
        $cfg = $null
        if (Test-Path -LiteralPath $p.ConfigPath) { try { $cfg = Get-Content -LiteralPath $p.ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $cfg = $null } }
        $inst = if ($cfg -and "$($cfg.Installer)" -and ($p.Candidates -contains "$($cfg.Installer)")) { "$($cfg.Installer)" } else { $p.Candidates[0] }
        $full = if ($p.IsDir) { Join-Path $p.SrcPath $inst } else { $p.SrcPath }
        $info = Get-SwInstallerInfo $full
        $def = [ordered]@{
            Name = $(if ($info -and $info.ProductName) { "$($info.ProductName) $($info.Version)".Trim() } else { [IO.Path]::GetFileNameWithoutExtension($inst) })
            Installer = $inst; Arguments = $(if ($info) { $info.Suggested } else { '' }); SuccessCodes = '0'
            DetectName = $(if ($info -and $info.ProductName -and $info.Type -ne 'MSP') { [System.Management.Automation.WildcardPattern]::Escape($info.ProductName) + '*' } else { '' })
            DetectProductCode = $(if ($info) { $info.ProductCode } else { '' })
            MinVersion = $(if ($info -and $info.Type -eq 'MSI' -and $info.Version -match '^\d+(\.\d+){1,3}') { $Matches[0] } else { '' })
            TimeoutMin = 30; Note = ''
        }
        $set = [ordered]@{}
        foreach ($k in @($def.Keys)) {
            $has = $cfg -and (@($cfg.PSObject.Properties.Name) -contains $k) -and ($null -ne $cfg.$k)
            $set[$k] = if ($has) { $cfg.$k } else { $def[$k] }
        }
        $set.Installer = $inst
        $p | Add-Member -NotePropertyName Settings -NotePropertyValue ([pscustomobject]$set) -Force
        $p | Add-Member -NotePropertyName Info -NotePropertyValue $info -Force
        $p | Add-Member -NotePropertyName Configured -NotePropertyValue ([bool]$cfg) -Force
        $p | Add-Member -NotePropertyName Type -NotePropertyValue $(if ($info) { $info.Type } else { 'EXE' }) -Force
    }
    return $list.ToArray()
}

function Save-SwSettings($Package, $Settings) {
    try {
        [pscustomobject]$Settings | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $Package.ConfigPath -Encoding UTF8 -Force -ErrorAction Stop
        return $true
    } catch { Out-Console "Einstellungen nicht gespeichert ($($Package.ConfigPath)): $($_.Exception.Message)" 'Error'; return $false }
}

function Confirm-SwDeploy($Package, [string[]]$Hosts, [bool]$Force) {
    $s = $Package.Settings
    $cmd = switch ($Package.Type) { 'MSI' { "msiexec /i `"$($s.Installer)`" $($s.Arguments)" } 'MSP' { "msiexec /p `"$($s.Installer)`" $($s.Arguments)" } default { "`"$($s.Installer)`" $($s.Arguments)" } }
    $det = if ($s.DetectProductCode) { "ProductCode $($s.DetectProductCode)" } elseif ($s.DetectName) { "$($s.DetectName)$(if ($s.MinVersion) { " ab Version $($s.MinVersion)" })" } else { '(keine)' }
    $ziel = if ($Hosts.Count -le 5) { $Hosts -join ', ' } else { "$($Hosts.Count) PCs" }
    return (Confirm-Action "Paket '$($s.Name)' installieren auf: $ziel`n`n  Befehl:    $cmd`n  Erkennung: $det$(if ($Force) { '  -> trotzdem installieren' } else { '  -> installierte werden uebersprungen' })`n  Erfolg:    ExitCode $($s.SuccessCodes) (3010/1641 = Neustart noetig)`n  Groesse:   $($Package.SizeMB) MB$(if ($Package.IsDir) { ' (ganzer Ordner)' })`n`nFortfahren?" 'Softwareverteilung')
}

# --- Skripte, die am Ziel-PC laufen (als Text uebergeben) ---
$script:RS_SwPrep = {
    $ErrorActionPreference = 'SilentlyContinue'
    $tmp = Join-Path $env:ProgramData ('HU_SW_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    if (-not (Test-Path -LiteralPath $tmp)) { return 'FAIL|Temp-Ordner konnte nicht angelegt werden' }
    $null = & icacls.exe "$tmp" /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' 2>&1
    if ($LASTEXITCODE -ne 0) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue; return "FAIL|icacls ExitCode $LASTEXITCODE" }
    if (@(Get-ChildItem -LiteralPath $tmp -Force -ErrorAction SilentlyContinue).Count -gt 0) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue; return 'FAIL|Temp-Ordner war nicht leer - abgebrochen' }
    $ld = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'"
    $free = if ($ld -and $ld.FreeSpace) { [math]::Round($ld.FreeSpace / 1MB) } else { '' }
    "READY|$tmp|$free"
}
$script:RS_SwCleanup = {
    param([string]$Dir)
    if ($Dir -and $Dir -like "$env:ProgramData\HU_SW_*") { Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction SilentlyContinue }
    'CLEAN'
}
$script:RS_SwInstall = {
    param([string]$Dir, [string]$PkgJson, [bool]$Force)
    $ErrorActionPreference = 'SilentlyContinue'
    function ConvertTo-HUVer([string]$v) { if ("$v" -match '^\d+(\.\d+){0,3}') { $t = $Matches[0]; if ($t -notmatch '\.') { $t += '.0' }; try { return [version]$t } catch { } }; return $null }
    # ProductCode gesetzt -> NUR danach (exakt). Sonst DisplayName-Muster + optional Mindestversion (aeltere Version = nicht installiert -> Update)
    function Find-HUApp([string]$Name, [string]$Code, [string]$MinVer) {
        $min = ConvertTo-HUVer $MinVer
        foreach ($k in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*') {
            foreach ($i in @(Get-ItemProperty -Path $k -ErrorAction SilentlyContinue)) {
                if ($Code) { if ($i.PSChildName -eq $Code) { return $i } else { continue } }
                $hit = $false
                try { $hit = ($Name -and $i.DisplayName -and "$($i.DisplayName)" -like $Name) } catch { $hit = ("$($i.DisplayName)" -eq $Name) }
                if (-not $hit) { continue }
                if ($min) { $iv = ConvertTo-HUVer "$($i.DisplayVersion)"; if (-not $iv -or $iv -lt $min) { continue } }
                return $i
            }
        }
        return $null
    }
    try {
        $p = $PkgJson | ConvertFrom-Json
        $dn = "$($p.DetectName)".Trim(); $dc = "$($p.DetectProductCode)".Trim(); $mv = "$($p.MinVersion)".Trim()
        if (-not $Force -and ($dn -or $dc)) {
            $a = Find-HUApp $dn $dc $mv
            if ($a) { return "SKIP|bereits installiert: $($a.DisplayName) $($a.DisplayVersion)" }
        }
        $inst = Join-Path $Dir "$($p.Installer)"
        if (-not (Test-Path -LiteralPath $inst)) { return "FEHLER|Installer fehlt am Client ($($p.Installer))" }
        $safe = ("$($p.Name)" -replace '[^\w\-\.]', '_')
        $log = Join-Path $env:SystemRoot ("Temp\HU_SW_{0}_{1}.log" -f $safe, (Get-Date -Format 'yyyyMMdd-HHmmss'))
        $args2 = "$($p.Arguments)".Trim()
        switch ("$($p.Type)") {
            'MSI' { $file = Join-Path $env:SystemRoot 'System32\msiexec.exe'; $argLine = "/i `"$inst`" $args2 /l*v `"$log`"" }
            'MSP' { $file = Join-Path $env:SystemRoot 'System32\msiexec.exe'; $argLine = "/p `"$inst`" $args2 /l*v `"$log`"" }
            default { $file = $inst; $argLine = $args2; $log = '' }
        }
        $psi = New-Object System.Diagnostics.ProcessStartInfo $file, $argLine
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.WorkingDirectory = $Dir
        # Prozesse, die aus dem Paketordner laufen (Bootstrapper starten oft Unterprozesse und beenden sich frueh)
        $dirEsc = $Dir.TrimEnd('\')
        function Get-HUPkgProcs { @(Get-CimInstance Win32_Process | Where-Object { ("$($_.ExecutablePath)" -like "$dirEsc\*") -or ("$($_.CommandLine)" -like "*$dirEsc\*") }) }
        # Windows Installer belegt: Mutex existiert UND ist gehalten
        function Test-HUMsiBusy {
            $m = $null
            try {
                if (-not [System.Threading.Mutex]::TryOpenExisting('Global\_MSIExecute', [System.Security.AccessControl.MutexRights]::Synchronize, [ref]$m)) { return $false }
                try { if ($m.WaitOne(0)) { $m.ReleaseMutex(); return $false } else { return $true } }
                catch [System.Threading.AbandonedMutexException] { return $false }
            } catch { return $false } finally { if ($m) { $m.Dispose() } }
        }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $proc = [System.Diagnostics.Process]::Start($psi)
        $tmo = [int]$p.TimeoutMin; if ($tmo -lt 1) { $tmo = 30 }
        $limitMs = $tmo * 60000
        if (-not $proc.WaitForExit($limitMs)) {
            try { $proc.Kill() } catch { }
            foreach ($x in (Get-HUPkgProcs)) { try { Stop-Process -Id $x.ProcessId -Force -ErrorAction Stop } catch { } }
            return "FEHLER|Timeout nach $tmo min - Installer beendet (wartet er auf Eingabe? Parameter pruefen)$(if ($log) { " | Log: $log" })"
        }
        $rc = $proc.ExitCode
        Start-Sleep -Seconds 2
        while ($sw.ElapsedMilliseconds -lt $limitMs -and ((Get-HUPkgProcs).Count -gt 0 -or ("$($p.Type)" -eq 'EXE' -and (Test-HUMsiBusy)))) { Start-Sleep -Seconds 3 }
        if ($sw.ElapsedMilliseconds -ge $limitMs) {
            foreach ($x in (Get-HUPkgProcs)) { try { Stop-Process -Id $x.ProcessId -Force -ErrorAction Stop } catch { } }
            return "FEHLER|Timeout nach $tmo min (Unterprozesse des Installers liefen noch)$(if ($log) { " | Log: $log" })"
        }
        $okCodes = @("$($p.SuccessCodes)" -split '[,;\s]+' | Where-Object { $_ -match '^-?\d+$' } | ForEach-Object { [int]$_ })
        if ($okCodes.Count -eq 0) { $okCodes = @(0) }
        $after = if ($dn -or $dc) { Find-HUApp $dn $dc '' } else { $null }
        $ver = if ($after) { " - $($after.DisplayName) $($after.DisplayVersion)" } else { '' }
        $dur = "$([int]$sw.Elapsed.TotalSeconds) s"
        if ($okCodes -contains $rc) {
            if (($dn -or $dc) -and -not $after) { return "FEHLER|ExitCode $rc, aber Programm danach nicht gefunden (Erkennung '$dn$dc' pruefen) ($dur)$(if ($log) { " | Log: $log" })" }
            return "OK|installiert (ExitCode $rc, $dur)$ver"
        }
        if ($rc -eq 3010 -or $rc -eq 1641) { return "OK|installiert - NEUSTART erforderlich (ExitCode $rc, $dur)$ver" }
        $hint = switch ($rc) { 1603 { ' = schwerer Fehler (MSI-Log)' } 1618 { ' = andere Installation laeuft gerade' } 1619 { ' = Paket nicht lesbar' } 1620 { ' = Paket ungueltig' } 1633 { ' = falsche Plattform (32/64 Bit)' } 1638 { ' = andere Version bereits installiert' } default { '' } }
        return "FEHLER|ExitCode $rc$hint ($dur)$(if ($log) { " | Log: $log" })"
    } catch { return "FEHLER|$($_.Exception.Message -replace '[\r\n|]+', ' ')" }
    finally {
        Set-Location -Path $env:SystemRoot
        if ($Dir -like "$env:ProgramData\HU_SW_*") { Start-Sleep -Seconds 1; Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
# Worker je PC: eigener PC direkt, andere per PSSession
$script:SwWorkerText = @'
param($h, $src, $isDir, $pkgJson, $force, $prepText, $instText, $cleanText, $sizeMB, $timeoutMin)
$isLocal = ($h -eq '.' -or $h -eq 'localhost' -or $h -ieq $env:COMPUTERNAME -or $h -ilike "$($env:COMPUTERNAME).*")
$s = $null; $remote = ''; $done = $false
try {
    if ($isLocal) {
        $prep = "$(& ([scriptblock]::Create($prepText)))".Trim()
    } else {
        $opt = New-PSSessionOption -OpenTimeout 15000 -OperationTimeout ([int](($timeoutMin + 10) * 60000))
        $s = New-PSSession -ComputerName $h -SessionOption $opt -ErrorAction Stop
        $prep = "$(Invoke-Command -Session $s -ErrorAction Stop -ScriptBlock ([scriptblock]::Create($prepText)))".Trim()
    }
    if ($prep -notmatch '^READY\|([^|]+)\|(\d*)$') { return "RES:$h|FEHLER|Vorbereitung: $prep" }
    $remote = $Matches[1]
    if ($Matches[2] -and ([int]$Matches[2]) -lt ($sizeMB * 3 + 500)) { return "RES:$h|FEHLER|Zu wenig Speicher am Systemlaufwerk ($($Matches[2]) MB frei)" }
    if ($isLocal) {
        if ($isDir) { foreach ($it in @(Get-ChildItem -LiteralPath $src -Force)) { Copy-Item -LiteralPath $it.FullName -Destination $remote -Recurse -Force -ErrorAction Stop } }
        else { Copy-Item -LiteralPath $src -Destination $remote -Force -ErrorAction Stop }
        $r = "$(& ([scriptblock]::Create($instText)) $remote $pkgJson $force)".Trim()
    } else {
        if ($isDir) { foreach ($it in @(Get-ChildItem -LiteralPath $src -Force)) { Copy-Item -LiteralPath $it.FullName -Destination $remote -ToSession $s -Recurse -Force -ErrorAction Stop } }
        else { Copy-Item -LiteralPath $src -Destination $remote -ToSession $s -Force -ErrorAction Stop }
        $r = "$(Invoke-Command -Session $s -ErrorAction Stop -ScriptBlock ([scriptblock]::Create($instText)) -ArgumentList $remote, $pkgJson, $force)".Trim()
    }
    $done = $true
    if ($r -notmatch '^(OK|SKIP|FEHLER)\|') { $r = "FEHLER|Unerwartete Antwort: $r" }
    "RES:$h|$r"
} catch { "RES:$h|FEHLER|$($_.Exception.Message -replace '[\r\n|]+', ' ')" }
finally {
    if (-not $done -and $remote) {
        try { if ($isLocal) { $null = & ([scriptblock]::Create($cleanText)) $remote } elseif ($s) { $null = Invoke-Command -Session $s -ErrorAction Stop -ScriptBlock ([scriptblock]::Create($cleanText)) -ArgumentList $remote } } catch { }
    }
    if ($s) { Remove-PSSession $s -ErrorAction SilentlyContinue }
}
'@

function Start-SoftwareDeploy {
    param([string[]]$Hosts, [object]$Package, [bool]$Force = $false, [string]$Label = '')
    $Hosts = @($Hosts | Where-Object { $_ } | ForEach-Object { "$_".Trim() } | Where-Object { $_ } | Sort-Object -Unique)
    if ($Hosts.Count -eq 0 -or -not $Package) { return }
    $s = $Package.Settings
    $pkg = [ordered]@{ Name = "$($s.Name)"; Installer = "$($s.Installer)"; Type = "$($Package.Type)"; Arguments = "$($s.Arguments)"; SuccessCodes = "$($s.SuccessCodes)"; DetectName = "$($s.DetectName)"; DetectProductCode = "$($s.DetectProductCode)"; MinVersion = "$($s.MinVersion)"; TimeoutMin = [int]$s.TimeoutMin }
    $pkgJson = [pscustomobject]$pkg | ConvertTo-Json -Compress
    Out-Console "Softwareverteilung '$($s.Name)' auf $($Hosts.Count) PC(s)$(if ($Label) { " [$Label]" })$(if ($Force) { ' - auch wenn installiert' }) ..." 'Info'
    $tmo = [int]$s.TimeoutMin; if ($tmo -lt 1) { $tmo = 30 }
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
        $out = New-Object System.Collections.Generic.List[string]
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
    } -ArgumentList @(($Hosts -join '|'), $Package.SrcPath, [bool]$Package.IsDir, $pkgJson, $Force, $script:RS_SwPrep.ToString(), $script:RS_SwInstall.ToString(), $script:RS_SwCleanup.ToString(), $script:SwWorkerText, [double]$Package.SizeMB, $tmo, ($jobSec - 60)) `
      -TimeoutSec $jobSec -State @{ Name = "$($s.Name)"; Hosts = $Hosts; Package = $Package; Force = $Force } -OnComplete {
        param($result, $st)
        $r = "$result".Trim()
        if ($r -match '^FEHLER:') { Out-Console "Softwareverteilung: $r" 'Error'; if ($script:SwQueue) { Invoke-HMSwQueueNext }; return }
        $rows = New-Object System.Collections.Generic.List[object]
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
            $lvl = switch ($rw[1]) { 'OK' { 'Success' } 'SKIP' { 'Warning' } default { 'Error' } }
            Out-Console "  $($rw[0]): $($rw[2])" $lvl
        }
        Out-Console "Softwareverteilung '$($st.Name)': $ok installiert / $sk uebersprungen / $bad Fehler" $(if ($bad) { 'Warning' } else { 'Success' })
        if ($rows.Count -gt 1) {
            Show-DataGridWindow -Title "Softwareverteilung - $($st.Name)" -Columns @('Computer', 'Status', 'Ergebnis') -Rows $rows.ToArray() -Sort 'Status ASC, Computer ASC' `
                -CountText "$($rows.Count) PCs ($ok OK / $sk uebersprungen / $bad Fehler)" -Width 1100 -Height 560 -ActionContext @{ Package = $st.Package; Force = $st.Force } `
                -Actions @(@{ Text = 'Erneut installieren (markierte)'; Color = '#FFFAB387'; Handler = {
                    param($rows, $win, $ctx)
                    $h = @(@($rows) | ForEach-Object { "$($_.Computer)" })
                    if ("$([System.Windows.MessageBox]::Show($win, "Paket '$($ctx.Package.Settings.Name)' erneut auf $($h.Count) PC(s) installieren?", 'Softwareverteilung', 'YesNo', 'Question'))" -ne 'Yes') { return }
                    Start-SoftwareDeploy -Hosts $h -Package $ctx.Package -Force ([bool]$ctx.Force) -Label 'Wiederholung'
                } })
        }
        # Warteschlange (Neuinstallation fehlender Programme): naechstes Paket
        if ($script:SwQueue) { Invoke-HMSwQueueNext }
    }
}

# ----------------------------------------------------------------------------
# Fenster Softwareverteilung
# ----------------------------------------------------------------------------
$script:SwUi = $null
function Update-SwWindowList([string]$SelectId = '') {
    $sw = $script:SwUi; if (-not $sw) { return }
    $sw.Pkgs = @(Get-SwPackages)
    $sw.Loading = $true
    $sw.Lst.Items.Clear()
    foreach ($p in $sw.Pkgs) { [void]$sw.Lst.Items.Add("$(if ($p.Configured) { '' } else { '* ' })$($p.Settings.Name)   [$($p.Type)$(if ($p.IsDir) { ', Ordner' })]") }
    $sw.Loading = $false
    $sw.LblFolder.Text = "Ordner: $(Get-SwFolder)   ($($sw.Pkgs.Count) Pakete, * = noch nicht geprueft/gespeichert)"
    $sw.LblTarget.Text = "Gewaehlter Computer: $(Get-TargetComputer)"
    $idx = 0
    if ($SelectId) { for ($i = 0; $i -lt $sw.Pkgs.Count; $i++) { if ($sw.Pkgs[$i].Id -eq $SelectId) { $idx = $i } } }
    if ($sw.Pkgs.Count -gt 0) { $sw.Lst.SelectedIndex = $idx } else { Show-SwPackageDetails $null }
}
function Show-SwPackageDetails($p) {
    $sw = $script:SwUi; if (-not $sw) { return }
    $sw.Loading = $true
    try {
        $sw.CmbInst.Items.Clear(); $sw.CmbArgs.Items.Clear()
        if (-not $p) {
            foreach ($c in 'TxtName', 'TxtDetect', 'TxtCode', 'TxtMinVer', 'TxtCodes', 'TxtTimeout', 'TxtNote', 'TxtInfo') { $sw[$c].Text = '' }
            $sw.CmbArgs.Text = ''; $sw.LblType.Text = ''
            $sw.TxtInfo.Text = "Noch keine Pakete.`n`n'Datei hinzufuegen' oder MSI/EXE/MSP in den Ordner legen (ein Paket = eine Datei)`noder einen Unterordner mit Installer + allen benoetigten Dateien anlegen."
            return
        }
        $s = $p.Settings
        foreach ($c in $p.Candidates) { [void]$sw.CmbInst.Items.Add($c) }
        $sw.CmbInst.SelectedItem = "$($s.Installer)"
        $sw.CmbInst.IsEnabled = ($p.Candidates.Count -gt 1)
        $sw.TxtName.Text = "$($s.Name)"
        foreach ($a in @($p.Info.Alternatives)) { if ($a) { [void]$sw.CmbArgs.Items.Add($a) } }
        $sw.CmbArgs.Text = "$($s.Arguments)"
        $sw.TxtDetect.Text = "$($s.DetectName)"; $sw.TxtCode.Text = "$($s.DetectProductCode)"; $sw.TxtMinVer.Text = "$($s.MinVersion)"
        $sw.TxtCodes.Text = "$($s.SuccessCodes)"; $sw.TxtTimeout.Text = "$($s.TimeoutMin)"; $sw.TxtNote.Text = "$($s.Note)"
        $sw.LblType.Text = "$($p.Type) - $($p.Info.Framework)$(if (-not $p.Configured) { '   (noch nicht gespeichert)' })"
        $i = $p.Info
        $lines = @(
            "Paket:        $($p.Id)   ($($p.SizeMB) MB$(if ($p.IsDir) { ', ganzer Ordner wird kopiert' }))"
            "Produkt:      $($i.ProductName)"
            "Version:      $($i.Version)"
            "Hersteller:   $($i.Manufacturer)"
        )
        if ($i.ProductCode) { $lines += "ProductCode:  $($i.ProductCode)" }
        $lines += "Framework:    $($i.Framework)"
        $lines += "Vorschlag:    $($i.Suggested)"
        if ($i.Note) { $lines += ''; $lines += "HINWEIS: $($i.Note)" }
        if (@($i.Props).Count -gt 0) {
            $lines += ''; $lines += 'Oeffentliche MSI-Eigenschaften (per Parameter setzbar, z.B. INSTALLDIR="C:\Pfad"):'
            $lines += @($i.Props | ForEach-Object { "  $_" })
        }
        $sw.TxtInfo.Text = ($lines -join "`r`n")
    } finally { $sw.Loading = $false }
}
function Get-SwFormSettings {
    $sw = $script:SwUi
    $codes = "$($sw.TxtCodes.Text)".Trim(); if (-not $codes) { $codes = '0' }
    if (@($codes -split '[,;\s]+' | Where-Object { $_ -notmatch '^-?\d+$' }).Count -gt 0) { throw 'Erfolgs-ExitCodes: nur Zahlen, mit Komma getrennt (z.B. 0,3010)' }
    $tmo = 0; if (-not [int]::TryParse("$($sw.TxtTimeout.Text)".Trim(), [ref]$tmo) -or $tmo -lt 1 -or $tmo -gt 600) { throw 'Timeout: 1 bis 600 Minuten' }
    $name = "$($sw.TxtName.Text)".Trim(); if (-not $name) { throw 'Name fehlt' }
    $mvT = "$($sw.TxtMinVer.Text)".Trim(); if ($mvT -and $mvT -notmatch '^\d+(\.\d+){0,3}$') { throw 'Mindestversion: nur Zahlen mit Punkten (z.B. 24.08 oder 124.0.6367.60)' }
    $dnT = "$($sw.TxtDetect.Text)".Trim(); if ($dnT) { try { $null = [System.Management.Automation.WildcardPattern]::new($dnT); $null = 'x' -like $dnT } catch { throw 'Erkennung (Name): ungueltiges Muster - eckige Klammern weglassen oder durch * ersetzen' } }
    return [ordered]@{
        Name = $name; Installer = "$($sw.CmbInst.SelectedItem)"; Arguments = "$($sw.CmbArgs.Text)".Trim(); SuccessCodes = $codes
        DetectName = $dnT; DetectProductCode = "$($sw.TxtCode.Text)".Trim(); MinVersion = $mvT; TimeoutMin = $tmo; Note = "$($sw.TxtNote.Text)".Trim()
    }
}
function Save-SwForm {
    $sw = $script:SwUi
    $i = $sw.Lst.SelectedIndex
    if ($i -lt 0 -or $i -ge $sw.Pkgs.Count) { return $null }
    $p = $sw.Pkgs[$i]
    try { $set = Get-SwFormSettings } catch { [void][System.Windows.MessageBox]::Show($sw.Win, "$($_.Exception.Message)", 'Softwareverteilung', 'OK', 'Warning'); return $null }
    if ($p.Type -eq 'EXE' -and -not $set.Arguments) {
        if ("$([System.Windows.MessageBox]::Show($sw.Win, "Keine Parameter fuer die EXE angegeben.`n`nOhne Silent-Parameter kann der Installer am Client unsichtbar auf eine Eingabe warten (bis zum Timeout).`n`nTrotzdem speichern?", 'Softwareverteilung', 'YesNo', 'Warning'))" -ne 'Yes') { return $null }
    }
    if (-not (Save-SwSettings $p $set)) { return $null }
    Out-Console "Softwareverteilung: Einstellungen fuer '$($set.Name)' gespeichert" 'Success'
    $id = $p.Id
    Update-SwWindowList $id
    return ($sw.Pkgs | Where-Object { $_.Id -eq $id } | Select-Object -First 1)
}

function Show-SoftwareWindow {
    if ($script:SwUi -and $script:SwUi.Win -and $script:SwUi.Win.IsVisible) { [void]$script:SwUi.Win.Activate(); Update-SwWindowList; return }
    $dir = Get-SwFolder
    try { if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null } } catch { Out-Console "Ordner nicht anlegbar: $dir" 'Error' }
    $sx = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="HUMig - Softwareverteilung" Height="700" Width="1080" MinHeight="480" MinWidth="820"
        WindowStartupLocation="CenterOwner" Background="#FF1E1E2E">
  <Window.Resources>
    <Style TargetType="TextBlock"><Setter Property="Foreground" Value="#FFA6ADC8"/><Setter Property="VerticalAlignment" Value="Center"/></Style>
    <Style TargetType="TextBox"><Setter Property="Background" Value="#FF313244"/><Setter Property="Foreground" Value="#FFCDD6F4"/><Setter Property="BorderBrush" Value="#FF585B70"/><Setter Property="CaretBrush" Value="#FFCDD6F4"/><Setter Property="Padding" Value="4,2"/><Setter Property="Margin" Value="0,2,0,2"/></Style>
    <Style TargetType="Button"><Setter Property="Height" Value="28"/><Setter Property="Margin" Value="0,0,6,0"/><Setter Property="Cursor" Value="Hand"/><Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Foreground" Value="#FF1E1E2E"/><Setter Property="Padding" Value="10,0"/></Style>
  </Window.Resources>
  <DockPanel Margin="8">
    <DockPanel DockPanel.Dock="Top" Margin="0,0,0,6">
      <Image x:Name="imgLogo" DockPanel.Dock="Left" Width="30" Height="30" Margin="0,0,8,0" RenderOptions.BitmapScalingMode="HighQuality"/>
      <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
        <Button x:Name="btnAdd" Content="Datei hinzufuegen" Background="#FFA6E3A1"/>
        <Button x:Name="btnOpen" Content="Ordner oeffnen" Background="#FF89B4FA"/>
        <Button x:Name="btnReload" Content="Aktualisieren" Background="#FF89B4FA" Margin="0"/>
      </StackPanel>
      <TextBlock x:Name="lblFolder" TextTrimming="CharacterEllipsis"/>
    </DockPanel>
    <Border DockPanel.Dock="Bottom" Background="#FF181825" Padding="6" Margin="0,6,0,0">
      <DockPanel>
        <CheckBox x:Name="chkForce" DockPanel.Dock="Right" Content="auch wenn schon installiert" Foreground="#FFCDD6F4" VerticalAlignment="Center"/>
        <StackPanel Orientation="Horizontal">
          <TextBlock Text="Installieren auf:" Margin="0,0,8,0" Foreground="#FFF9E2AF"/>
          <Button x:Name="btnClient" Content="Gewaehlten Computer" Background="#FFA6E3A1"/>
          <Button x:Name="btnMultiSel" Content="Mehrere PCs ..." Background="#FFA6E3A1" ToolTip="PCs aus dem Active Directory anhaken (OU, Filter) oder Namen eintragen - installiert wird parallel (bis zu 8 gleichzeitig)"/>
          <TextBlock x:Name="lblTarget" Margin="8,0,0,0"/>
        </StackPanel>
      </DockPanel>
    </Border>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="320"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <ListBox x:Name="lstPkg" Grid.Column="0" Background="#FF313244" Foreground="#FFCDD6F4" BorderBrush="#FF585B70" Margin="0,0,8,0" FontSize="12"/>
      <DockPanel Grid.Column="1">
        <Grid DockPanel.Dock="Top">
          <Grid.ColumnDefinitions><ColumnDefinition Width="170"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
          <Grid.RowDefinitions><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
          <TextBlock Grid.Row="0" Text="Name:"/>                    <TextBox x:Name="txtName" Grid.Row="0" Grid.Column="1"/>
          <TextBlock Grid.Row="1" Text="Installer:"/>               <ComboBox x:Name="cmbInst" Grid.Row="1" Grid.Column="1" Margin="0,2,0,2"/>
          <TextBlock Grid.Row="2" Text="Typ:"/>                     <TextBlock x:Name="lblType" Grid.Row="2" Grid.Column="1" Foreground="#FFF9E2AF"/>
          <TextBlock Grid.Row="3" Text="Parameter:"/>               <ComboBox x:Name="cmbArgs" Grid.Row="3" Grid.Column="1" IsEditable="True" Margin="0,2,0,2" FontFamily="Consolas" ToolTip="Silent-Parameter. MSI: Eigenschaften anhaengen, z.B. /qn /norestart INSTALLDIR=&quot;C:\Programme\X&quot; - msiexec /i und das Log werden automatisch ergaenzt"/>
          <TextBlock Grid.Row="4" Text="Erkennung (Name):"/>        <TextBox x:Name="txtDetect" Grid.Row="4" Grid.Column="1" ToolTip="DisplayName in 'Programme und Features', Platzhalter * erlaubt (z.B. 7-Zip*). Installiert = wird uebersprungen, danach wird geprueft ob es da ist. Leer = keine Pruefung"/>
          <TextBlock Grid.Row="5" Text="Erkennung (ProductCode):"/> <TextBox x:Name="txtCode" Grid.Row="5" Grid.Column="1" FontFamily="Consolas" ToolTip="MSI-ProductCode {GUID} - wenn gesetzt, wird NUR danach erkannt (exakt diese Version). Leer = Erkennung per Name"/>
          <TextBlock Grid.Row="6" Text="Mindestversion:"/>          <TextBox x:Name="txtMinVer" Grid.Row="6" Grid.Column="1" Width="160" HorizontalAlignment="Left" ToolTip="Nur mit Erkennung per Name: aeltere installierte Version gilt als NICHT installiert -> wird aktualisiert"/>
          <TextBlock Grid.Row="7" Text="Erfolgs-ExitCodes:"/>       <TextBox x:Name="txtCodes" Grid.Row="7" Grid.Column="1" ToolTip="Komma-getrennt, z.B. 0 oder 0,1 - 3010/1641 gelten immer als Erfolg mit Neustart"/>
          <TextBlock Grid.Row="8" Text="Timeout (Minuten):"/>       <TextBox x:Name="txtTimeout" Grid.Row="8" Grid.Column="1" Width="80" HorizontalAlignment="Left"/>
          <TextBlock Grid.Row="9" Text="Notiz:"/>                   <TextBox x:Name="txtNote" Grid.Row="9" Grid.Column="1"/>
        </Grid>
        <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,6,0,6">
          <Button x:Name="btnSave" Content="Speichern" Background="#FFF9E2AF"/>
          <Button x:Name="btnSuggest" Content="Standard vorschlagen" Background="#FFFAB387"/>
        </StackPanel>
        <TextBox x:Name="txtInfo" IsReadOnly="True" FontFamily="Consolas" FontSize="11" TextWrapping="NoWrap" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"/>
      </DockPanel>
    </Grid>
  </DockPanel>
</Window>
"@
    $w = [System.Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new(([xml]$sx)))
    if ($script:AppIcon) { $w.Icon = $script:AppIcon }
    if ($script:LogoImage) { $w.FindName('imgLogo').Source = $script:LogoImage }
    $script:SwUi = @{
        Win = $w; Pkgs = @(); Loading = $false
        Lst = $w.FindName('lstPkg'); LblFolder = $w.FindName('lblFolder'); LblType = $w.FindName('lblType'); LblTarget = $w.FindName('lblTarget')
        TxtName = $w.FindName('txtName'); CmbInst = $w.FindName('cmbInst'); CmbArgs = $w.FindName('cmbArgs')
        TxtDetect = $w.FindName('txtDetect'); TxtCode = $w.FindName('txtCode'); TxtMinVer = $w.FindName('txtMinVer'); TxtCodes = $w.FindName('txtCodes')
        TxtTimeout = $w.FindName('txtTimeout'); TxtNote = $w.FindName('txtNote'); TxtInfo = $w.FindName('txtInfo'); ChkForce = $w.FindName('chkForce')
    }
    # Handler ohne GetNewClosure -> Skript-Funktionen sichtbar; Zustand in $script:SwUi
    $script:SwUi.Lst.Add_SelectionChanged({
        $sw = $script:SwUi
        if ($sw.Loading) { return }
        $i = $sw.Lst.SelectedIndex
        if ($i -ge 0 -and $i -lt $sw.Pkgs.Count) { Show-SwPackageDetails $sw.Pkgs[$i] }
    })
    $script:SwUi.CmbInst.Add_SelectionChanged({
        $sw = $script:SwUi
        if ($sw.Loading) { return }
        $i = $sw.Lst.SelectedIndex
        if ($i -lt 0 -or $i -ge $sw.Pkgs.Count) { return }
        $p = $sw.Pkgs[$i]
        $inst = "$($sw.CmbInst.SelectedItem)"; if (-not $inst) { return }
        $info = Get-SwInstallerInfo (Join-Path $p.SrcPath $inst)
        if ($info) {
            $sw.CmbArgs.Items.Clear(); foreach ($a in @($info.Alternatives)) { if ($a) { [void]$sw.CmbArgs.Items.Add($a) } }
            $sw.CmbArgs.Text = $info.Suggested
            $sw.LblType.Text = "$($info.Type) - $($info.Framework)   (Installer geaendert - Speichern nicht vergessen)"
        }
    })
    $w.FindName('btnAdd').Add_Click({
        $d = New-Object Microsoft.Win32.OpenFileDialog
        $d.Filter = 'Installer (*.msi;*.exe;*.msp)|*.msi;*.exe;*.msp'
        $d.Multiselect = $true
        $d.Title = 'Installer in die Softwareverteilung kopieren'
        if ($d.ShowDialog() -ne $true) { return }
        $dst = Get-SwFolder
        foreach ($f in $d.FileNames) {
            try { Copy-Item -LiteralPath $f -Destination $dst -Force -ErrorAction Stop; Out-Console "Softwareverteilung: $([IO.Path]::GetFileName($f)) hinzugefuegt" 'Success' }
            catch { Out-Console "Kopieren fehlgeschlagen: $($_.Exception.Message)" 'Error' }
        }
        Update-SwWindowList ([IO.Path]::GetFileName($d.FileNames[0]))
    })
    $w.FindName('btnOpen').Add_Click({ $d = Get-SwFolder; if (Test-Path -LiteralPath $d) { Start-Process explorer.exe -ArgumentList "`"$d`"" } })
    $w.FindName('btnReload').Add_Click({ $script:SwInfoCache = @{}; $sw = $script:SwUi; $sel = if ($sw.Lst.SelectedIndex -ge 0) { $sw.Pkgs[$sw.Lst.SelectedIndex].Id } else { '' }; Update-SwWindowList $sel })
    $w.FindName('btnSave').Add_Click({ [void](Save-SwForm) })
    $w.FindName('btnSuggest').Add_Click({
        $sw = $script:SwUi; $i = $sw.Lst.SelectedIndex
        if ($i -lt 0 -or $i -ge $sw.Pkgs.Count) { return }
        $p = $sw.Pkgs[$i]
        $inst = "$($sw.CmbInst.SelectedItem)"; if (-not $inst) { $inst = $p.Candidates[0] }
        $info = Get-SwInstallerInfo $(if ($p.IsDir) { Join-Path $p.SrcPath $inst } else { $p.SrcPath })
        if (-not $info) { return }
        $sw.CmbArgs.Text = $info.Suggested
        if ($info.ProductName) { $sw.TxtName.Text = "$($info.ProductName) $($info.Version)".Trim(); if ($info.Type -ne 'MSP') { $sw.TxtDetect.Text = [System.Management.Automation.WildcardPattern]::Escape($info.ProductName) + '*' } }
        $sw.TxtMinVer.Text = if ($info.Type -eq 'MSI' -and "$($info.Version)" -match '^\d+(\.\d+){1,3}') { $Matches[0] } else { '' }
        $sw.TxtCode.Text = "$($info.ProductCode)"; $sw.TxtCodes.Text = '0'; $sw.TxtTimeout.Text = '30'
    })
    $w.FindName('btnClient').Add_Click({
        $sw = $script:SwUi
        $h = Get-TargetComputer
        $p = Save-SwForm; if (-not $p) { return }
        $force = [bool]$sw.ChkForce.IsChecked
        if (-not (Confirm-SwDeploy -Package $p -Hosts @($h) -Force $force)) { return }
        Start-SoftwareDeploy -Hosts @($h) -Package $p -Force $force
    })
    $w.FindName('btnMultiSel').Add_Click({
        $sw = $script:SwUi
        $p = Save-SwForm; if (-not $p) { return }
        $script:SwPick = @{ Package = $p; Force = [bool]$sw.ChkForce.IsChecked }
        # PCs aus dem AD anhaken (Filter/OU) oder Namen eintragen
        Show-HMMultiDialog -PickTitle "Paket '$($p.Settings.Name)'" -Owner $sw.Win -OnPick {
            param($hosts)
            $pp = $script:SwPick; if (-not $pp) { return }
            $hosts = @($hosts | Where-Object { $_ } | Sort-Object -Unique)
            if (-not $hosts.Count) { return }
            if (-not (Confirm-SwDeploy -Package $pp.Package -Hosts $hosts -Force $pp.Force)) { return }
            Start-SoftwareDeploy -Hosts $hosts -Package $pp.Package -Force $pp.Force -Label 'Mehrere PCs'
        }
    })
    $w.Add_Closed({ $script:SwUi = $null })
    $w.Owner = $script:Window; Set-HMWindowScale $w
    $w.Show()
    Update-SwWindowList
}

# ----------------------------------------------------------------------------
# Software-Inventar (installierte Programme) des gewaehlten PCs + Deinstallation
# ----------------------------------------------------------------------------
# Liest die Uninstall-Schluessel (HKLM 64/32 Bit) am Ziel-PC. Pro Eintrag: Deinstallations-Methode + Schluessel.
$script:RS_SwInventory = {
    $paths = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')
    Get-ItemProperty $paths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -and -not $_.SystemComponent -and -not $_.ParentKeyName } |
        Sort-Object DisplayName, DisplayVersion |
        ForEach-Object {
            $us = "$($_.UninstallString)".Trim(); $qs = "$($_.QuietUninstallString)".Trim()
            $m = if (($_.WindowsInstaller -eq 1 -and $_.PSChildName -match '^\{[0-9A-Fa-f-]{36}\}$') -or ($us -match '(?i)msiexec' -and $us -match '\{[0-9A-Fa-f-]{36}\}')) { 'MSI' }
                 elseif ($qs) { 'Still (Hersteller)' } elseif ($us) { 'EXE' } else { '-' }
            $key = ("$($_.PSPath)" -replace '^Microsoft\.PowerShell\.Core\\Registry::HKEY_LOCAL_MACHINE', 'HKLM:')
            $cmd = if ($m -eq 'Still (Hersteller)') { $qs } else { $us }
            ("SW:$($_.DisplayName)|$($_.DisplayVersion)|$($_.Publisher)|$($_.InstallDate)|$(if ($_.PSPath -like '*WOW6432Node*') { '32 Bit' } else { '64 Bit' })|$m|$key|$cmd" -replace "[\r\n]", ' ')
        }
}

# Deinstalliert eine Liste von Eintraegen nacheinander am Ziel-PC (lokal oder per Invoke-Command). Ausgabe je Eintrag: RES:Name|OK/WARN/FEHLER|Text
$script:RS_SwUninstall = {
    param([string]$ItemsJson, [int]$TimeoutMin)
    $ErrorActionPreference = 'SilentlyContinue'
    if ($TimeoutMin -lt 1) { $TimeoutMin = 10 }
    function Split-HUCmd([string]$s) {
        $s = [Environment]::ExpandEnvironmentVariables("$s".Trim())
        if ($s -match '^"([^"]+)"\s*(.*)$') { return @($Matches[1], $Matches[2]) }
        if ($s -match '^(.+?\.exe)\s*(.*)$') { return @($Matches[1], $Matches[2]) }
        return @($s, '')
    }
    # Unterprozesse typischer Deinstaller (NSIS kopiert sich als Au_.exe nach TEMP, Inno als _iu*.tmp)
    function Get-HUUninstProcs([datetime]$Since, [string]$ExeDir) {
        @(Get-CimInstance Win32_Process | Where-Object {
            $_.CreationDate -ge $Since -and (
                ($_.Name -match '^(Au_|Un_A|_iu|unins|uninst)' -or ($_.Name -ieq 'msiexec.exe' -and "$($_.CommandLine)" -notmatch '\s/V\b')) -or
                ($ExeDir -and "$($_.ExecutablePath)" -like "$ExeDir\*"))
        })
    }
    $items = $ItemsJson | ConvertFrom-Json   # PS 5.1: Array kommt als ein Objekt -> foreach zaehlt korrekt auf
    foreach ($it in $items) {
        $name = "$($it.Name)" -replace '\|', '/'
        try {
            $reg = Get-ItemProperty -LiteralPath $it.Key -ErrorAction SilentlyContinue
            if (-not $reg) { "RES:$name|OK|war bereits entfernt"; continue }
            $us = "$($reg.UninstallString)".Trim(); $qs = "$($reg.QuietUninstallString)".Trim()
            $log = ''; $exeDir = ''
            switch ("$($it.Method)") {
                'MSI' {
                    $code = if ("$($reg.PSChildName)" -match '^\{[0-9A-Fa-f-]{36}\}$') { $reg.PSChildName } elseif ($us -match '(\{[0-9A-Fa-f-]{36}\})') { $Matches[1] } else { '' }
                    if (-not $code) { throw 'ProductCode nicht gefunden' }
                    $safe = ($name -replace '[^\w\-\.]', '_'); if ($safe.Length -gt 40) { $safe = $safe.Substring(0, 40) }
                    $log = Join-Path $env:SystemRoot ("Temp\HU_SWX_{0}_{1}.log" -f $safe, (Get-Date -Format 'yyyyMMdd-HHmmss'))
                    $file = Join-Path $env:SystemRoot 'System32\msiexec.exe'
                    $argLine = "/x $code /qn /norestart /l*v `"$log`""
                }
                'Still (Hersteller)' { $c = Split-HUCmd $qs; $file = $c[0]; $argLine = $c[1] }
                'EXE' { $c = Split-HUCmd $us; $file = $c[0]; $argLine = ("$($c[1]) $($it.Args)").Trim() }
                default { throw 'kein Deinstallationsbefehl hinterlegt' }
            }
            if ("$($it.Method)" -ne 'MSI') {
                if (-not (Test-Path -LiteralPath $file)) { throw "Deinstaller nicht gefunden: $file" }
                $exeDir = Split-Path -Parent $file
                if ($exeDir -like "$env:SystemRoot*") { $exeDir = '' }
            }
            $psi = New-Object System.Diagnostics.ProcessStartInfo $file, $argLine
            $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
            $psi.WorkingDirectory = $(if ($exeDir) { $exeDir } else { $env:SystemRoot })
            $start = (Get-Date).AddSeconds(-1)
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $limitMs = $TimeoutMin * 60000
            $proc = [System.Diagnostics.Process]::Start($psi)
            if (-not $proc.WaitForExit($limitMs)) {
                try { $proc.Kill() } catch { }
                foreach ($x in (Get-HUUninstProcs $start $exeDir)) { try { Stop-Process -Id $x.ProcessId -Force } catch { } }
                "RES:$name|FEHLER|Timeout nach $TimeoutMin min - Deinstaller wartet vermutlich auf Eingabe (Parameter fuer stille Deinstallation noetig)"; continue
            }
            $rc = $proc.ExitCode
            # Warten bis Eintrag weg ist bzw. keine Deinstaller-Unterprozesse mehr laufen
            $gone = -not (Test-Path -LiteralPath $it.Key)
            while (-not $gone -and "$($it.Method)" -ne 'MSI' -and $sw.ElapsedMilliseconds -lt $limitMs) {
                if (-not (Test-Path -LiteralPath $it.Key)) { $gone = $true; break }
                if ((Get-HUUninstProcs $start $exeDir).Count -eq 0 -and $sw.ElapsedMilliseconds -gt 15000) { break }
                Start-Sleep -Seconds 2
            }
            if (-not $gone -and $sw.ElapsedMilliseconds -ge $limitMs) {
                foreach ($x in (Get-HUUninstProcs $start $exeDir)) { try { Stop-Process -Id $x.ProcessId -Force } catch { } }
                "RES:$name|FEHLER|Timeout nach $TimeoutMin min (Unterprozesse liefen noch - wartet auf Eingabe?)"; continue
            }
            $dur = "$([int]$sw.Elapsed.TotalSeconds) s"
            $reboot = ($rc -eq 3010 -or $rc -eq 1641)
            if ($gone) { "RES:$name|OK|entfernt (ExitCode $rc, $dur)$(if ($reboot) { ' - NEUSTART erforderlich' })"; continue }
            if ($rc -eq 1605) { "RES:$name|OK|war laut Windows Installer nicht (mehr) installiert"; continue }
            if ($reboot) { "RES:$name|OK|ExitCode $rc - wird nach NEUSTART entfernt ($dur)"; continue }
            $hint = switch ($rc) { 0 { ' - Eintrag aber noch vorhanden (Deinstaller evtl. abgebrochen oder braucht Neustart)' } 1603 { ' = schwerer Fehler (MSI-Log)' } 1618 { ' = andere Installation laeuft gerade' } 1602 { ' = vom Benutzer abgebrochen' } default { '' } }
            "RES:$name|$(if ($rc -eq 0) { 'WARN' } else { 'FEHLER' })|ExitCode $rc$hint ($dur)$(if ($log) { " | Log: $log" })"
        } catch { "RES:$name|FEHLER|$($_.Exception.Message -replace '[\r\n|]+', ' ')" }
    }
}

# Vorschlag fuer stille Parameter bei EXE-Deinstallern (nur Vorschlag - wird im Dialog angezeigt)
function Get-SwSilentGuess([string]$Cmd) {
    if ($Cmd -match '(?i)unins\d{3}\.exe') { return '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' }   # Inno Setup
    if ($Cmd -match '(?i)\\(uninst|uninstall|uninstaller|un_[^\\]*)\.exe') { return '/S' }        # meist NSIS
    if ($Cmd -match '(?i)setup\.exe') { return '' }
    return ''
}

function Show-InstalledSoftware([string]$Computer) {
    Out-Console "Installierte Software auf $Computer ..." 'Info'
    Invoke-AsyncCommand -ScriptBlock {
        param($h, $cred, $invText)
        $sb = [scriptblock]::Create($invText)
        try {
            if ($h -ieq $env:COMPUTERNAME -or $h -eq 'localhost' -or $h -eq '.') { & $sb }
            else { $p = @{ ComputerName = $h; ScriptBlock = $sb; ErrorAction = 'Stop' }; if ($cred) { $p.Credential = $cred }; Invoke-Command @p }
        } catch { "FEHLER: $($_.Exception.Message)" }
    } -ArgumentList @($Computer, $script:RemoteCred, $script:RS_SwInventory.ToString()) -TimeoutSec 120 -State $Computer -OnComplete {
        param($result, $h)
        $r = (@($result) -join "`n").Trim()
        if (-not $r) { Out-Console 'Keine Software-Daten erhalten' 'Warning'; return }
        if ($r -match '^FEHLER:') { Out-Console (Format-RemoteError $r) 'Error'; return }
        $rows = New-Object System.Collections.Generic.List[object]
        $map = @{}
        foreach ($line in ($r -split "`r?`n")) {
            if ($line -notmatch '^SW:') { continue }
            $p = $line.Substring(3).Trim() -split '\|', 8
            while ($p.Count -lt 8) { $p += '' }
            $id = "$($p[0])|$($p[1])|$($p[4])"
            if ($map.ContainsKey($id)) { continue }
            $map[$id] = @{ Name = $p[0]; Method = $p[5]; Key = $p[6]; Cmd = $p[7] }
            $rows.Add(@($p[0], $p[1], $p[2], $p[3], $p[4], $p[5]))
        }
        Out-Console "$($rows.Count) Programme auf $h" 'Success'
        Show-DataGridWindow -Title "Installierte Software - $h" -Columns @('Name', 'Version', 'Hersteller', 'Installiert', 'Art', 'Deinstallation') -Rows $rows.ToArray() `
            -Sort 'Name ASC' -CountText "$($rows.Count) Programme" -Width 1150 -Height 640 -ActionContext @{ Computer = $h; Map = $map } `
            -Actions @(
                @{ Text = 'Deinstallieren (markierte)'; Color = '#FFF38BA8'; Handler = { param($rows, $win, $ctx) Start-SoftwareUninstall -Rows $rows -Win $win -Ctx $ctx } },
                @{ Text = 'Aktualisieren'; Color = '#FF89B4FA'; NoSelection = $true; Handler = { param($rows, $win, $ctx) $win.Close(); Show-InstalledSoftware $ctx.Computer } }
            )
    }
}

function Start-SoftwareUninstall {
    param([object[]]$Rows, [object]$Win, [hashtable]$Ctx)
    $h = $Ctx.Computer
    $items = New-Object System.Collections.Generic.List[object]
    $noCmd = New-Object System.Collections.Generic.List[string]
    foreach ($row in @($Rows)) {
        $id = "$($row.Name)|$($row.Version)|$($row.Art)"
        $e = $Ctx.Map[$id]
        if (-not $e -or $e.Method -eq '-' -or -not $e.Key) { $noCmd.Add("$($row.Name)"); continue }
        $argsX = ''
        if ($e.Method -eq 'EXE') {
            $guess = Get-SwSilentGuess $e.Cmd
            $a = Show-TextInputDialog -Title "Parameter - $($e.Name)" -Owner $Win -Text $guess -Label ("Kein stiller Deinstallationsbefehl hinterlegt.`n`nBefehl: $($e.Cmd)`n`nZusaetzliche Parameter fuer stille Deinstallation (Vorschlag - bitte pruefen!).`nTypisch: NSIS /S   Inno /VERYSILENT /SUPPRESSMSGBOXES /NORESTART   InstallShield -s`n`nOhne passende Parameter wartet der Deinstaller unsichtbar und wird nach 10 min abgebrochen.")
            if ($null -eq $a) { Out-Console 'Deinstallation abgebrochen' 'Warning'; return }
            $argsX = "$a".Trim()
        }
        $items.Add([pscustomobject]@{ Name = $e.Name; Key = $e.Key; Method = $e.Method; Args = $argsX; Cmd = $e.Cmd })
    }
    if ($noCmd.Count) { [void][System.Windows.MessageBox]::Show($Win, "Ohne Deinstallationsbefehl (werden uebersprungen):`n  " + ($noCmd -join "`n  "), 'Deinstallation', 'OK', 'Information') }
    if ($items.Count -eq 0) { return }
    $lines = foreach ($i in $items) {
        $c = switch ($i.Method) { 'MSI' { 'msiexec /x (still)' } 'EXE' { "$($i.Cmd) $($i.Args)".Trim() } default { "$($i.Cmd)" } }
        if ($c.Length -gt 110) { $c = $c.Substring(0, 107) + '...' }
        "  - $($i.Name)`n      $c"
    }
    $msg = "Auf $h deinstallieren ($($items.Count)):`n`n$($lines -join "`n")`n`nNacheinander, still, ohne automatischen Neustart. Fortfahren?"
    if ("$([System.Windows.MessageBox]::Show($Win, $msg, 'Software deinstallieren', 'YesNo', 'Warning'))" -ne 'Yes') { return }

    $json = ConvertTo-Json -InputObject @($items | Select-Object Name, Key, Method, Args) -Compress
    $tmo = 10
    Out-Console "Deinstallation auf ${h}: $($items.Count) Programm(e) ..." 'Info'
    Invoke-AsyncCommand -ScriptBlock {
        param($h, $cred, $unText, $json, $tmo)
        $sb = [scriptblock]::Create($unText)
        try {
            if ($h -ieq $env:COMPUTERNAME -or $h -eq 'localhost' -or $h -eq '.') { & $sb $json $tmo }
            else { $p = @{ ComputerName = $h; ScriptBlock = $sb; ArgumentList = @($json, $tmo); ErrorAction = 'Stop' }; if ($cred) { $p.Credential = $cred }; Invoke-Command @p }
        } catch { "FEHLER: $($_.Exception.Message)" }
    } -ArgumentList @($h, $script:RemoteCred, $script:RS_SwUninstall.ToString(), $json, $tmo) -TimeoutSec ($items.Count * ($tmo + 2) * 60 + 120) -State @{ Computer = $h; Win = $Win } -OnComplete {
        param($result, $st)
        $r = (@($result) -join "`n").Trim()
        if ($r -match '^FEHLER:') { Out-Console (Format-RemoteError $r) 'Error'; return }
        $ok = 0; $bad = 0
        foreach ($line in ($r -split "`r?`n")) {
            if ($line -notmatch '^RES:([^|]*)\|(OK|WARN|FEHLER)\|(.*)$') { continue }
            $lvl = switch ($Matches[2]) { 'OK' { 'Success' } 'WARN' { 'Warning' } default { 'Error' } }
            if ($Matches[2] -eq 'OK') { $ok++ } else { $bad++ }
            Out-Console "  $($Matches[1]): $($Matches[3])" $lvl
        }
        Out-Console "Deinstallation auf $($st.Computer): $ok OK / $bad mit Problemen" $(if ($bad) { 'Warning' } else { 'Success' })
        # Liste neu laden (altes Fenster schliessen, falls noch offen)
        try { if ($st.Win -and $st.Win.IsLoaded) { $st.Win.Close() } } catch { }
        Show-InstalledSoftware $st.Computer
    }
}
