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
            # neue Felder (alte Pakete ohne diese Felder: leer = wie bisher)
            UninstallCmd = ''; DetectKey = ''; DetectFile = ''; NoDesktop = $false; DependsOn = @(); WingetId = ''; Sandbox = $null
        }
        $set = [ordered]@{}
        foreach ($k in @($def.Keys)) {
            $has = $cfg -and (@($cfg.PSObject.Properties.Name) -contains $k) -and ($null -ne $cfg.$k)
            $set[$k] = if ($has) { $cfg.$k } else { $def[$k] }
        }
        $set.NoDesktop = ($set.NoDesktop -eq $true -or "$($set.NoDesktop)" -eq 'True')
        $set.DependsOn = @(@($set.DependsOn) | Where-Object { "$_".Trim() } | ForEach-Object { "$_".Trim() })
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
        [pscustomobject]$Settings | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Package.ConfigPath -Encoding UTF8 -Force -ErrorAction Stop
        return $true
    } catch { Out-Console "Einstellungen nicht gespeichert ($($Package.ConfigPath)): $($_.Exception.Message)" 'Error'; return $false }
}

# Einstellungen (PSCustomObject/Hashtable) als veraenderbare, geordnete Hashtable
function ConvertTo-SwSettingsHash($Settings) {
    $h = [ordered]@{}
    if ($null -eq $Settings) { return $h }
    if ($Settings -is [System.Collections.IDictionary]) { foreach ($k in @($Settings.Keys)) { $h["$k"] = $Settings[$k] } }
    else { foreach ($pr in $Settings.PSObject.Properties) { $h[$pr.Name] = $pr.Value } }
    return $h
}

# Schneller Fingerabdruck des Pakets: Groesse + Aenderungszeit des Installers bzw. aller Dateien im Ordner,
# dazu Installer und Parameter (anderer Aufruf = alter Sandbox-Test gilt nicht mehr). Paket-Einstellungen zaehlen nicht.
function Get-SwPackageSignature {
    param([Parameter(Mandatory)][object]$Package)
    $lines = New-Object System.Collections.Generic.List[string]
    $src = "$($Package.SrcPath)"
    if ($Package.IsDir) {
        $root = $src.TrimEnd('\', '/')
        foreach ($f in @(Get-ChildItem -LiteralPath $root -File -Recurse -Force -ErrorAction SilentlyContinue)) {
            $rel = $f.FullName.Substring($root.Length).TrimStart('\', '/') -replace '/', '\'
            if ($rel -ieq 'hu-package.json') { continue }
            $lines.Add(('{0}|{1}|{2}' -f $rel.ToLowerInvariant(), $f.Length, $f.LastWriteTimeUtc.Ticks))
        }
    } else {
        $f = Get-Item -LiteralPath $src -Force -ErrorAction SilentlyContinue
        if ($f) { $lines.Add(('{0}|{1}|{2}' -f $f.Name.ToLowerInvariant(), $f.Length, $f.LastWriteTimeUtc.Ticks)) }
    }
    $arr = $lines.ToArray(); [Array]::Sort($arr, [StringComparer]::Ordinal)
    $s = $Package.Settings
    $txt = ($arr -join "`n") + "`nI|$("$($s.Installer)".ToLowerInvariant())|$("$($s.Arguments)".Trim())"
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $b = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($txt)) } finally { $sha.Dispose() }
    return (-join ($b[0..11] | ForEach-Object { $_.ToString('x2') }))
}

# Kennzeichen Sandbox-Test: OK / Hinweise / Fehler / Ungetestet / Veraltet (Paket seit dem Test geaendert)
function Get-SwTestState($Package, [string]$Signature = '') {
    $sb = $Package.Settings.Sandbox
    if (-not $sb -or -not "$($sb.Result)") { return [pscustomobject]@{ State = 'Ungetestet'; Mark = [string][char]0x25CB; Text = 'nicht in der Sandbox getestet' } }
    if (-not $Signature) { try { $Signature = Get-SwPackageSignature -Package $Package } catch { $Signature = '' } }
    $when = "$($sb.Date)"
    if ("$($sb.Signature)" -ne $Signature) { return [pscustomobject]@{ State = 'Veraltet'; Mark = [string][char]0x21BB; Text = "Test veraltet - Paket seit dem Test ($when) geaendert" } }
    switch ("$($sb.Result)") {
        'OK'       { return [pscustomobject]@{ State = 'OK'; Mark = [string][char]0x2713; Text = "in der Sandbox getestet ($when): OK" } }
        'Hinweise' { return [pscustomobject]@{ State = 'Hinweise'; Mark = '!'; Text = "in der Sandbox getestet ($when): mit Hinweisen" } }
        default    { return [pscustomobject]@{ State = 'Fehler'; Mark = [string][char]0x2717; Text = "in der Sandbox getestet ($when): FEHLER" } }
    }
}

# Abhaengigkeiten in Installationsreihenfolge (tiefste zuerst), ohne das Paket selbst. Fehler bei Kreis/fehlendem Paket.
function Get-SwDepOrder($Package, [object[]]$All) {
    $byId = @{}; foreach ($x in @($All)) { if ($x) { $byId["$($x.Id)"] = $x } }
    $order = New-Object System.Collections.Generic.List[object]
    $errs = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    $visit = $null
    $visit = {
        param($x, [string[]]$Path)
        foreach ($id in @($x.Settings.DependsOn | Where-Object { "$_".Trim() })) {
            $d = $byId["$id".Trim()]
            if (-not $d) { $errs.Add("$($x.Settings.Name): Abhaengigkeit '$id' fehlt im Ordner Softwareverteilung"); continue }
            if ($Path -contains $d.Id) { $errs.Add("Kreis: '$($d.Settings.Name)' haengt ueber Umwege von sich selbst ab"); continue }
            & $visit $d (@($Path) + $d.Id)
            if (-not $seen.ContainsKey($d.Id)) { $seen[$d.Id] = $true; $order.Add($d) }
        }
    }
    & $visit $Package @($Package.Id)
    return [pscustomobject]@{ Order = $order.ToArray(); Errors = @($errs | Select-Object -Unique) }
}

# haengt $Candidate (direkt oder ueber Umwege) von $TargetId ab? (Kreis-Schutz bei der Auswahl)
function Test-SwDependsOn($Candidate, [string]$TargetId, [object[]]$All, [hashtable]$Seen = @{}) {
    foreach ($id in @($Candidate.Settings.DependsOn | Where-Object { "$_".Trim() })) {
        if ("$id" -eq $TargetId) { return $true }
        if ($Seen.ContainsKey("$id")) { continue }
        $Seen["$id"] = $true
        $d = @($All | Where-Object { $_.Id -eq "$id" }) | Select-Object -First 1
        if ($d -and (Test-SwDependsOn $d $TargetId $All $Seen)) { return $true }
    }
    return $false
}

# Paketdaten fuer den Ziel-PC (gleicher Text fuer Verteilung, Status und Sandbox)
function Get-SwPkgJson($Package, $Settings = $null) {
    $s = if ($null -ne $Settings) { $Settings } else { $Package.Settings }
    $pkg = [ordered]@{ Name = "$($s.Name)"; Installer = "$($s.Installer)"; Type = "$($Package.Type)"; Arguments = "$($s.Arguments)"; SuccessCodes = "$($s.SuccessCodes)"; DetectName = "$($s.DetectName)"; DetectProductCode = "$($s.DetectProductCode)"; MinVersion = "$($s.MinVersion)"; TimeoutMin = [int]$s.TimeoutMin }
    $pkg.DetectKey = "$($s.DetectKey)"; $pkg.DetectFile = "$($s.DetectFile)"; $pkg.NoDesktop = ($s.NoDesktop -eq $true -or "$($s.NoDesktop)" -eq 'True')
    return ([pscustomobject]$pkg | ConvertTo-Json -Compress)
}

# Installationsauftrag: genau der Text, der auch bei der Verteilung an die PCs geht
# Aufruf im Ziel: & ([scriptblock]::Create($ScriptText)) -Dir <Ordner mit Setup> -PkgJson $PkgJson -Force $true
function Get-SwInstallJob {
    param([Parameter(Mandatory)][object]$Package, [object]$Settings = $null)
    return @{ ScriptText = $script:RS_SwInstall.ToString(); PkgJson = (Get-SwPkgJson $Package $Settings); Force = $true }
}

# Deinstallationseintrag eines Pakets: eigener Befehl (UninstallCmd) oder MSI-ProductCode. $null = nichts hinterlegt
function Get-SwUninstallItem($Package, $Settings = $null) {
    $s = if ($null -ne $Settings) { $Settings } else { $Package.Settings }
    $name = "$($s.Name)"
    $cmd = "$($s.UninstallCmd)".Trim()
    $code = "$($s.DetectProductCode)".Trim()
    if ($code -notmatch '^\{[0-9A-Fa-f-]{36}\}$') { $code = '' }
    if (-not $code -and -not $cmd -and "$($Package.Type)" -eq 'MSI' -and "$($Package.Info.ProductCode)" -match '^\{[0-9A-Fa-f-]{36}\}$') { $code = "$($Package.Info.ProductCode)" }
    # Schluessel nur aus HKLM (HKCU waere am Ziel das Profil des Admins)
    $key = ConvertTo-SwRegPath "$($s.DetectKey)"
    if ($key -notmatch '^HKLM:\\') { $key = '' }
    if ($cmd) {
        if ($cmd -match '(?i)msiexec' -and $cmd -match '(\{[0-9A-Fa-f-]{36}\})') { if (-not $code) { $code = $Matches[1] } }
        $add = ''
        if ($cmd -notmatch '(?i)msiexec' -and $cmd -notmatch '(?i)(^|\s)(/VERYSILENT|/SILENT|/quiet|/qn|/passive|--silent|-silent|-s)(\s|$)' -and $cmd -cnotmatch '(^|\s)/S(\s|$)') { $add = Get-SwSilentGuess $cmd }
        return [pscustomobject]@{ Name = $name; Key = $key; Method = 'Cmd'; Args = $add; Cmd = $cmd; Code = $(if ($key) { '' } else { $code }) }
    }
    if ($code) { return [pscustomobject]@{ Name = $name; Key = ''; Method = 'MSI'; Args = ''; Cmd = "msiexec /x $code /qn /norestart"; Code = $code } }
    return $null
}

# Deinstallationsauftrag: @{ ScriptText; ArgsJson; TimeoutMin } bzw. $null ohne Befehl
# Aufruf im Ziel: & ([scriptblock]::Create($ScriptText)) -ArgsJson $ArgsJson
function Get-SwUninstallJob {
    param([Parameter(Mandatory)][object]$Package, [object]$Settings = $null)
    $it = Get-SwUninstallItem $Package $Settings
    if (-not $it) { return $null }
    $s = if ($null -ne $Settings) { $Settings } else { $Package.Settings }
    $tmo = [int]$s.TimeoutMin; if ($tmo -lt 1) { $tmo = 10 }
    return @{ ScriptText = $script:RS_SwUninstall.ToString(); ArgsJson = (ConvertTo-Json -InputObject @($it) -Compress); TimeoutMin = $tmo; Item = $it }
}

# Registry-Pfad vereinheitlichen (HKEY_LOCAL_MACHINE\... / HKLM\... -> HKLM:\...)
function ConvertTo-SwRegPath([string]$Path) {
    $k = "$Path".Trim() -replace '^(?i)Microsoft\.PowerShell\.Core\\Registry::', '' -replace '^(?i)Registry::', ''
    $k = $k -replace '^(?i)HKEY_LOCAL_MACHINE(\\|$)', 'HKLM:\' -replace '^(?i)HKLM\\', 'HKLM:\' -replace '^(?i)HKEY_CURRENT_USER(\\|$)', 'HKCU:\' -replace '^(?i)HKCU\\', 'HKCU:\'
    return $k
}

# Versionen vergleichen: -1 / 0 / 1, $null wenn nicht lesbar
function ConvertTo-SwVersion([string]$V) {
    if ("$V" -match '\d+(\.\d+){0,3}') { $t = $Matches[0]; if ($t -notmatch '\.') { $t += '.0' }; try { return [version]$t } catch { } }
    return $null
}
function Compare-SwVersion([string]$A, [string]$B) {
    $va = ConvertTo-SwVersion $A; $vb = ConvertTo-SwVersion $B
    if ($null -eq $va -or $null -eq $vb) { return $null }
    return $va.CompareTo($vb)
}

# Sicherer Dateiname aus der Paket-Id (Ordner-Pakete enden auf \)
function Get-SwSafeId([string]$Id) {
    $n = ("$Id".TrimEnd('\', '/') -replace '[\\/:*?"<>|]', '_').Trim()
    if (-not $n) { $n = 'paket' }
    return $n
}

# Letztes Ergebnis je PC: <Softwareverteilung>\_status\<Id>.json (Ordner mit _ ignoriert Get-SwPackages)
function Get-SwStatusPath($Package) { return (Join-Path (Join-Path (Get-SwFolder) '_status') ("$(Get-SwSafeId $Package.Id).json")) }
function Get-SwStatus($Package) {
    $f = Get-SwStatusPath $Package
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    try { return (Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}
# $Rows: Objekte mit Computer, Installed ($true/$false/$null), Version, Detection, Result; Source = 'Status'|'Verteilung'|'Deinstallation'
function Save-SwStatus($Package, [object[]]$Rows, [string]$Source) {
    try {
        $f = Get-SwStatusPath $Package
        $d = Split-Path -Parent $f
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        $map = [ordered]@{}
        $old = Get-SwStatus $Package
        if ($old) { foreach ($c in @($old.Computers)) { if ($c -and "$($c.Computer)") { $map["$($c.Computer)".ToUpper()] = $c } } }
        $now = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        foreach ($r in @($Rows)) {
            if (-not $r -or -not "$($r.Computer)") { continue }
            $map["$($r.Computer)".ToUpper()] = [pscustomobject][ordered]@{ Computer = "$($r.Computer)"; Date = $now; Source = $Source; Installed = $r.Installed; Version = "$($r.Version)"; Detection = "$($r.Detection)"; Result = "$($r.Result)" }
        }
        $o = [pscustomobject][ordered]@{ Id = "$($Package.Id)"; Name = "$($Package.Settings.Name)"; Updated = $now; Computers = @($map.Values | Sort-Object Computer) }
        $o | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $f -Encoding UTF8 -Force -ErrorAction Stop
        return $f
    } catch { Out-Console "Status nicht gespeichert: $($_.Exception.Message)" 'Warning'; return $null }
}

function Confirm-SwDeploy($Package, [string[]]$Hosts, [bool]$Force) {
    $s = $Package.Settings
    $cmd = switch ($Package.Type) { 'MSI' { "msiexec /i `"$($s.Installer)`" $($s.Arguments)" } 'MSP' { "msiexec /p `"$($s.Installer)`" $($s.Arguments)" } default { "`"$($s.Installer)`" $($s.Arguments)" } }
    $det = if ($s.DetectProductCode) { "ProductCode $($s.DetectProductCode)" } elseif ($s.DetectName) { "$($s.DetectName)$(if ($s.MinVersion) { " ab Version $($s.MinVersion)" })" } else { '(keine)' }
    $more = @()
    if ("$($s.DetectKey)".Trim()) { $more += "Schluessel $($s.DetectKey)$(if ((ConvertTo-SwRegPath "$($s.DetectKey)") -match '^HKCU:') { ' (Benutzerprofil - nur angemeldete Benutzer)' })" }
    if ("$($s.DetectFile)".Trim()) { $more += "Datei $($s.DetectFile)" }
    if ($more.Count) { $det = if ($det -eq '(keine)') { $more -join ' + ' } else { "$det + $($more -join ' + ')" } }
    $ziel = if ($Hosts.Count -le 5) { $Hosts -join ', ' } else { "$($Hosts.Count) PCs" }
    $extra = ''
    if (@($s.DependsOn).Count) {
        $dep = $null; try { $dep = Get-SwDepOrder $Package @(Get-SwPackages) } catch { }
        if ($dep) {
            $extra += "`n  Vorher:    $(@($dep.Order | ForEach-Object { $_.Settings.Name }) -join ', ') (nur wenn nicht vorhanden)"
            if (@($dep.Errors).Count) { $extra += "`n  ACHTUNG:   $(@($dep.Errors) -join '; ')" }
        }
    }
    if ($s.NoDesktop) { $extra += "`n  Desktop:   neue Verknuepfungen werden entfernt" }
    $ts = $null; try { $ts = Get-SwTestState $Package } catch { }
    if ($ts -and $ts.State -ne 'OK') { $extra += "`n  Sandbox:   $($ts.Text)" }
    return (Confirm-Action "Paket '$($s.Name)' installieren auf: $ziel`n`n  Befehl:    $cmd`n  Erkennung: $det$(if ($Force) { '  -> trotzdem installieren' } else { '  -> installierte werden uebersprungen' })`n  Erfolg:    ExitCode $($s.SuccessCodes) (3010/1641 = Neustart noetig)`n  Groesse:   $($Package.SizeMB) MB$(if ($Package.IsDir) { ' (ganzer Ordner)' })$extra`n`nFortfahren?" 'Softwareverteilung')
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
    # DetectOnly: nur Erkennung (Status je PC), Ausgabe STATUS|1/0/?|Version|Text
    param([string]$Dir, [string]$PkgJson, [bool]$Force, [bool]$DetectOnly = $false)
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
    # Registry-Schluessel vorhanden (optional Version >= MinVer aus DisplayVersion/Version). HKCU -> alle geladenen Benutzerprofile
    function Find-HUKey([string]$Path, [string]$MinVer) {
        $k = "$Path".Trim() -replace '^(?i)Microsoft\.PowerShell\.Core\\Registry::', '' -replace '^(?i)Registry::', ''
        $k = $k -replace '^(?i)HKEY_LOCAL_MACHINE(\\|$)', 'HKLM:\' -replace '^(?i)HKLM\\', 'HKLM:\' -replace '^(?i)HKEY_CURRENT_USER(\\|$)', 'HKCU:\' -replace '^(?i)HKCU\\', 'HKCU:\'
        if (-not $k) { return $null }
        $user = $k -match '^(?i)HKCU:\\'
        $paths = @($k)
        if ($user) {
            $rest = $k.Substring(6)
            $sids = @(Get-ChildItem -LiteralPath 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^S-1-5-21-[\d-]+$' } | ForEach-Object { $_.PSChildName })
            if ($sids.Count) { $paths = @($sids | ForEach-Object { "Registry::HKEY_USERS\$_\$rest" }) }
        }
        $min = ConvertTo-HUVer $MinVer
        foreach ($x in $paths) {
            if (-not (Test-Path -LiteralPath $x)) { continue }
            $ip = Get-ItemProperty -LiteralPath $x -ErrorAction SilentlyContinue
            $v = "$($ip.DisplayVersion)"; if (-not $v) { $v = "$($ip.Version)" }
            if ($min) { $iv = ConvertTo-HUVer $v; if (-not $iv -or $iv -lt $min) { continue } }
            return [pscustomobject]@{ DisplayName = "$($ip.DisplayName)"; DisplayVersion = $v; Text = "Schluessel $k$(if ($user) { ' (Benutzerprofil)' })" }
        }
        return $null
    }
    # Datei/Ordner vorhanden (Umgebungsvariablen wie %ProgramFiles% werden aufgeloest)
    function Find-HUFile([string]$Path) {
        $f = [Environment]::ExpandEnvironmentVariables("$Path".Trim())
        if (-not $f -or -not (Test-Path -LiteralPath $f)) { return $null }
        $v = ''
        $it = Get-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
        if ($it -and -not $it.PSIsContainer) { try { $v = "$($it.VersionInfo.ProductVersion)".Trim() } catch { } }
        return [pscustomobject]@{ DisplayName = ''; DisplayVersion = $v; Text = "Datei $f" }
    }
    # Alle festgelegten Erkennungen muessen zutreffen. Any = ueberhaupt eine Erkennung festgelegt
    function Get-HUDetect($P, [string]$MinVer) {
        $dn = "$($P.DetectName)".Trim(); $dc = "$($P.DetectProductCode)".Trim(); $dk = "$($P.DetectKey)".Trim(); $df = "$($P.DetectFile)".Trim()
        $r = [pscustomobject]@{ Any = [bool]($dn -or $dc -or $dk -or $df); Hit = $false; App = $null; Display = ''; Version = ''; Text = ''; Missing = '' }
        if (-not $r.Any) { return $r }
        $txt = @(); $miss = @()
        if ($dn -or $dc) {
            $a = Find-HUApp $dn $dc $MinVer
            if ($a) { $r.App = $a; $r.Display = "$($a.DisplayName) $($a.DisplayVersion)"; $r.Version = "$($a.DisplayVersion)"; $txt += $(if ($dc) { "ProductCode $dc" } else { "Name $dn" }) } else { $miss += "$dn$dc" }
        }
        if ($dk) {
            $k = Find-HUKey $dk $MinVer
            if ($k) { $txt += $k.Text; if (-not $r.Version) { $r.Version = $k.DisplayVersion }; if (-not $r.Display) { $r.Display = "$($k.DisplayName) $($k.DisplayVersion)".Trim() } } else { $miss += "Schluessel $dk" }
        }
        if ($df) {
            $fh = Find-HUFile $df
            if ($fh) { $txt += $fh.Text; if (-not $r.Version) { $r.Version = $fh.DisplayVersion } } else { $miss += "Datei $df" }
        }
        $r.Hit = ($miss.Count -eq 0)
        $r.Text = ($txt -join ' + ')
        $r.Missing = ($miss -join "' + '")
        if (-not $r.Display) { $r.Display = $r.Text }
        return $r
    }
    # Neue Desktop-Verknuepfungen (Allgemein, eigener, Default) entfernen - einige Setups legen sie erst nach dem Ende an
    function Remove-HUNewLinks([string[]]$Dirs, [string[]]$Before, [int]$Rounds = 15, [int]$DelaySec = 2) {
        $n = 0
        for ($i = 0; $i -lt $Rounds; $i++) {
            foreach ($l in @(Get-ChildItem -LiteralPath $Dirs -Filter *.lnk -Force -ErrorAction SilentlyContinue | Where-Object { $Before -notcontains $_.FullName })) {
                try { Remove-Item -LiteralPath $l.FullName -Force -ErrorAction Stop; $n++ } catch { }
            }
            if ($DelaySec -gt 0 -and $i -lt $Rounds - 1) { Start-Sleep -Seconds $DelaySec }
        }
        if ($n) { try { Add-Type -Namespace HM -Name Shell -MemberDefinition '[System.Runtime.InteropServices.DllImport("shell32.dll")] public static extern void SHChangeNotify(int e, uint f, System.IntPtr a, System.IntPtr b);' -ErrorAction Stop; [HM.Shell]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero) } catch { } }
        return $n
    }
    try {
        $p = $PkgJson | ConvertFrom-Json
        $dn = "$($p.DetectName)".Trim(); $dc = "$($p.DetectProductCode)".Trim(); $mv = "$($p.MinVersion)".Trim()
        $dk = "$($p.DetectKey)".Trim(); $df = "$($p.DetectFile)".Trim()
        if ($DetectOnly) {
            $d = Get-HUDetect $p $mv
            if (-not $d.Any) { return 'STATUS|?||keine Erkennung festgelegt' }
            if ($d.Hit) { return "STATUS|1|$($d.Version -replace '\|', '/')|$($d.Text -replace '\|', '/')" }
            $old = $null; if ($mv) { $old = Get-HUDetect $p '' }
            return "STATUS|0|$(if ($old -and $old.Hit) { $old.Version -replace '\|', '/' })|$(if ($old -and $old.Hit) { "aeltere Version (Mindestversion $mv)" } else { "nicht gefunden: '$($d.Missing -replace '\|', '/')'" })"
        }
        if (-not $Force -and ($dn -or $dc -or $dk -or $df)) {
            $d = Get-HUDetect $p $mv
            if ($d.Hit) { return "SKIP|bereits installiert: $($d.Display)" }
        }
        $noDesk = ($p.NoDesktop -eq $true)
        $deskDirs = @("$env:PUBLIC\Desktop", [Environment]::GetFolderPath('Desktop'), "$env:SystemDrive\Users\Default\Desktop") | Where-Object { $_ } | Select-Object -Unique
        $deskBefore = @()
        if ($noDesk) { $deskBefore = @(Get-ChildItem -LiteralPath $deskDirs -Filter *.lnk -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }) }
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
        # Freigeben braucht das Recht Modify - ohne Freigabe bliebe der Mutex belegt und blockierte msiexec.
        # Modify verweigert: Zustand unbekannt -> "nicht belegt" (nie WaitOne ohne moegliche Freigabe)
        function Test-HUMsiBusy {
            $m = $null; $own = $false
            try {
                $ok = $false
                try { $ok = [System.Threading.Mutex]::TryOpenExisting('Global\_MSIExecute', [System.Security.AccessControl.MutexRights]'Synchronize, Modify', [ref]$m) }
                catch [System.UnauthorizedAccessException] { $m = $null; return $false }
                if (-not $ok) { return $false }
                try { if ($m.WaitOne(0)) { $own = $true; return $false } else { return $true } }
                catch [System.Threading.AbandonedMutexException] { $own = $true; return $false }
            } catch { return $false } finally { if ($m) { if ($own) { try { $m.ReleaseMutex() } catch { } }; $m.Dispose() } }
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
        # Keine Desktop-Verknuepfung: 30 s lang neue entfernen
        $deskNote = ''
        if ($noDesk) { $nl = Remove-HUNewLinks $deskDirs $deskBefore; if ($nl) { $deskNote = " - $nl Desktop-Verknuepfung(en) entfernt" } }
        $chk = if ($dn -or $dc -or $dk -or $df) { Get-HUDetect $p '' } else { $null }
        $after = if ($chk -and $chk.App) { $chk.App } else { $null }
        $ver = if ($after) { " - $($after.DisplayName) $($after.DisplayVersion)" } elseif ($chk -and $chk.Hit -and $chk.Display) { " - $($chk.Display)" } else { '' }
        $dur = "$(if ($sw.Elapsed.TotalSeconds -lt 60) { '{0} s' -f [int]$sw.Elapsed.TotalSeconds } else { '{0} min {1} s' -f [int][Math]::Floor($sw.Elapsed.TotalMinutes), $sw.Elapsed.Seconds })"
        if ($okCodes -contains $rc) {
            if ($chk -and -not $chk.Hit) { return "FEHLER|ExitCode $rc, aber Programm danach nicht gefunden (Erkennung '$($chk.Missing)' pruefen) ($dur)$(if ($log) { " | Log: $log" })" }
            return "OK|installiert (ExitCode $rc, $dur)$ver$deskNote"
        }
        if ($rc -eq 3010 -or $rc -eq 1641) { return "OK|installiert - NEUSTART erforderlich (ExitCode $rc, $dur)$ver$deskNote" }
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
param($h, $src, $isDir, $pkgJson, $force, $prepText, $instText, $cleanText, $sizeMB, $timeoutMin, $cred)
$isLocal = ($h -eq '.' -or $h -eq 'localhost' -or $h -ieq $env:COMPUTERNAME -or $h -ilike "$($env:COMPUTERNAME).*")
$s = $null; $remote = ''; $done = $false; $pre = ''
# Abhaengigkeiten: $pkgJson = {"Chain":[{Id,Name,Src,IsDir,PkgJson,SizeMB}, ...]} - letzter Eintrag = das Paket selbst
$chain = @()
try { $cj = $pkgJson | ConvertFrom-Json; if ($cj -and $cj.PSObject.Properties['Chain']) { $chain = @($cj.Chain) } } catch { }
if (-not $chain.Count) { $chain = @([pscustomobject]@{ Id = ''; Name = ''; Src = $src; IsDir = $isDir; PkgJson = $pkgJson; SizeMB = $sizeMB }) }
try {
    if (-not $isLocal) {
        $opt = New-PSSessionOption -OpenTimeout 15000 -OperationTimeout ([int](($timeoutMin + 10) * 60000))
        # zuerst mit dem eigenen Konto, nur bei Fehler mit den hinterlegten Remote-Anmeldedaten
        try { $s = New-PSSession -ComputerName $h -SessionOption $opt -ErrorAction Stop }
        catch { if (-not $cred) { throw }; $s = New-PSSession -ComputerName $h -SessionOption $opt -Credential $cred -ErrorAction Stop }
    }
    for ($n = 0; $n -lt $chain.Count; $n++) {
        $e = $chain[$n]; $main = ($n -eq $chain.Count - 1)
        $pre = if ($main) { '' } else { "Abhaengigkeit '$($e.Name)': " }
        $remote = ''; $done = $false
        $eSrc = "$($e.Src)"; $eDir = [bool]$e.IsDir; $eJson = "$($e.PkgJson)"; $eForce = $(if ($main) { $force } else { $false }); $eSize = [double]$e.SizeMB
        if ($isLocal) { $prep = "$(& ([scriptblock]::Create($prepText)))".Trim() }
        else { $prep = "$(Invoke-Command -Session $s -ErrorAction Stop -ScriptBlock ([scriptblock]::Create($prepText)))".Trim() }
        if ($prep -notmatch '^READY\|([^|]+)\|(\d*)$') { return "RES:$h|FEHLER|${pre}Vorbereitung: $prep" }
        $remote = $Matches[1]
        if ($Matches[2] -and ([int]$Matches[2]) -lt ($eSize * 3 + 500)) { return "RES:$h|FEHLER|${pre}Zu wenig Speicher am Systemlaufwerk ($($Matches[2]) MB frei)" }
        if ($isLocal) {
            if ($eDir) { foreach ($it in @(Get-ChildItem -LiteralPath $eSrc -Force)) { Copy-Item -LiteralPath $it.FullName -Destination $remote -Recurse -Force -ErrorAction Stop } }
            else { Copy-Item -LiteralPath $eSrc -Destination $remote -Force -ErrorAction Stop }
            $r = "$(& ([scriptblock]::Create($instText)) $remote $eJson $eForce)".Trim()
        } else {
            if ($eDir) { foreach ($it in @(Get-ChildItem -LiteralPath $eSrc -Force)) { Copy-Item -LiteralPath $it.FullName -Destination $remote -ToSession $s -Recurse -Force -ErrorAction Stop } }
            else { Copy-Item -LiteralPath $eSrc -Destination $remote -ToSession $s -Force -ErrorAction Stop }
            $r = "$(Invoke-Command -Session $s -ErrorAction Stop -ScriptBlock ([scriptblock]::Create($instText)) -ArgumentList $remote, $eJson, $eForce)".Trim()
        }
        $done = $true
        if ($r -notmatch '^(OK|SKIP|FEHLER)\|') { $r = "FEHLER|Unerwartete Antwort: $r" }
        if ($main) { "RES:$h|$r"; break }
        "DEP:$h|$($e.Id)|$($e.Name -replace '\|', '/')|$r"
        # Abhaengigkeit fehlgeschlagen -> Paket auf diesem PC nicht installieren
        if ($r -match '^FEHLER\|(.*)$') { "RES:$h|FEHLER|${pre}$($Matches[1])"; break }
    }
} catch { "RES:$h|FEHLER|$pre$($_.Exception.Message -replace '[\r\n|]+', ' ')" }
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
    $pkgJson = Get-SwPkgJson $Package $s
    $tmo = [int]$s.TimeoutMin; if ($tmo -lt 1) { $tmo = 30 }
    $perHost = ($tmo + 15) * 60 + [double]$Package.SizeMB
    # Abhaengigkeiten vorher auf denselben PCs (nie erzwungen - vorhandene werden uebersprungen)
    $depNames = @(); $depMap = @{}
    if (@($s.DependsOn).Count) {
        $dep = Get-SwDepOrder $Package @(Get-SwPackages)
        if (@($dep.Errors).Count) {
            Out-Console "Softwareverteilung '$($s.Name)' NICHT gestartet - Abhaengigkeiten: $(@($dep.Errors) -join '; ')" 'Error'
            if ($script:SwQueue) { Invoke-HMSwQueueNext }
            return
        }
        if (@($dep.Order).Count) {
            $chain = New-Object System.Collections.Generic.List[object]
            foreach ($d in @($dep.Order) + $Package) {
                $chain.Add([ordered]@{ Id = "$($d.Id)"; Name = "$($d.Settings.Name)"; Src = "$($d.SrcPath)"; IsDir = [bool]$d.IsDir; PkgJson = (Get-SwPkgJson $d $d.Settings); SizeMB = [double]$d.SizeMB })
                if ("$($d.Id)" -ne "$($Package.Id)") {
                    $dt = [int]$d.Settings.TimeoutMin; if ($dt -lt 1) { $dt = 30 }
                    if ($dt -gt $tmo) { $tmo = $dt }
                    $perHost += ($dt + 15) * 60 + [double]$d.SizeMB
                    $depNames += "$($d.Settings.Name)"; $depMap["$($d.Id)"] = $d
                }
            }
            $pkgJson = ConvertTo-Json -InputObject @{ Chain = $chain.ToArray() } -Depth 4 -Compress
        }
    }
    Out-Console "Softwareverteilung '$($s.Name)' auf $($Hosts.Count) PC(s)$(if ($Label) { " [$Label]" })$(if ($Force) { ' - auch wenn installiert' })$(if ($depNames.Count) { " - vorher: $($depNames -join ', ')" }) ..." 'Info'
    $jobSec = [int][Math]::Max(1800, ([Math]::Ceiling($Hosts.Count / 8.0) * $perHost))
    Invoke-AsyncCommand -ScriptBlock {
        param($hostStr, $src, $isDir, $pkgJson, $force, $prepText, $instText, $cleanText, $workerText, $sizeMB, $timeoutMin, $deadlineSec, $cred)
        $list = @($hostStr -split '\|' | Where-Object { $_ })
        $deadline = (Get-Date).AddSeconds($deadlineSec)
        $pool = [runspacefactory]::CreateRunspacePool(1, 8); $pool.Open()
        $jobs = foreach ($h in $list) {
            $ps = [PowerShell]::Create().AddScript($workerText).AddArgument($h).AddArgument($src).AddArgument($isDir).AddArgument($pkgJson).AddArgument($force).AddArgument($prepText).AddArgument($instText).AddArgument($cleanText).AddArgument($sizeMB).AddArgument($timeoutMin).AddArgument($cred)
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
    } -ArgumentList @(($Hosts -join '|'), $Package.SrcPath, [bool]$Package.IsDir, $pkgJson, $Force, $script:RS_SwPrep.ToString(), $script:RS_SwInstall.ToString(), $script:RS_SwCleanup.ToString(), $script:SwWorkerText, [double]$Package.SizeMB, $tmo, ($jobSec - 60), $script:RemoteCred) `
      -TimeoutSec $jobSec -State @{ Name = "$($s.Name)"; Hosts = $Hosts; Package = $Package; Force = $Force; Deps = $depMap } -OnComplete {
        param($result, $st)
        $r = "$result".Trim()
        if ($r -match '^FEHLER:') { Out-Console "Softwareverteilung: $r" 'Error'; if ($script:SwQueue) { Invoke-HMSwQueueNext }; return }
        $rows = New-Object System.Collections.Generic.List[object]
        $seen = @{}
        $depRows = @{}
        foreach ($l in ($r -split "`r?`n")) {
            # Abhaengigkeiten: DEP:PC|Id|Name|Status|Text
            if ($l -match '^DEP:([^|]*)\|([^|]*)\|([^|]*)\|(OK|SKIP|FEHLER)\|(.*)$') {
                $lvl = switch ($Matches[4]) { 'OK' { 'Success' } 'SKIP' { 'Info' } default { 'Error' } }
                Out-Console "  $($Matches[1]): Abhaengigkeit '$($Matches[3])': $(Format-RemoteError $Matches[5])" $lvl
                if (-not $depRows.ContainsKey($Matches[2])) { $depRows[$Matches[2]] = New-Object System.Collections.Generic.List[object] }
                $depRows[$Matches[2]].Add([pscustomobject]@{ Computer = $Matches[1]; Installed = $(if ($Matches[4] -eq 'FEHLER') { $null } else { $true }); Version = ''; Detection = ''; Result = "$($Matches[4]): $($Matches[5])" })
                continue
            }
            if ($l -notmatch '^RES:([^|]*)\|(OK|SKIP|FEHLER)\|(.*)$') { continue }
            $seen[$Matches[1].ToUpper()] = $true
            $rows.Add(@($Matches[1], $Matches[2], (Format-RemoteError $Matches[3])))
        }
        foreach ($h in $st.Hosts) { if (-not $seen.ContainsKey($h.ToUpper())) { $rows.Add(@($h, 'FEHLER', 'keine Antwort')) } }
        # letztes Ergebnis je PC ablegen (Paket und Abhaengigkeiten)
        try {
            [void](Save-SwStatus $st.Package @($rows | ForEach-Object { [pscustomobject]@{ Computer = $_[0]; Installed = $(if ($_[1] -eq 'FEHLER') { $null } else { $true }); Version = ''; Detection = ''; Result = "$($_[1]): $($_[2])" } }) 'Verteilung')
            if ($st.Deps) { foreach ($k in @($depRows.Keys)) { if ($st.Deps.ContainsKey($k)) { [void](Save-SwStatus $st.Deps[$k] $depRows[$k].ToArray() 'Verteilung') } } }
        } catch { }
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
                    if ("$((Show-HMDialogBox -Owner $win -Text ("Paket '$($ctx.Package.Settings.Name)' erneut auf $($h.Count) PC(s) installieren?") -Title 'Softwareverteilung' -Mode 'YesNo' -Icon 'Question'))" -ne 'Yes') { return }
                    Start-SoftwareDeploy -Hosts $h -Package $ctx.Package -Force ([bool]$ctx.Force) -Label 'Wiederholung'
                } })
        }
        # Warteschlange (Neuinstallation fehlender Programme): naechstes Paket
        if ($script:SwQueue) { Invoke-HMSwQueueNext }
    }
}

# ----------------------------------------------------------------------------
# Paket-Status und Paket-Deinstallation auf mehreren PCs (bis zu 8 parallel)
# ----------------------------------------------------------------------------
# Worker je PC: Skripttext lokal oder per PSSession (eigenes Konto, bei Fehler Remote-Anmeldedaten). Ausgabe je Zeile H:PC|...
$script:SwRunWorkerText = @'
param($h, $scriptText, $argList, $cred, $opMin)
$isLocal = ($h -eq '.' -or $h -eq 'localhost' -or $h -ieq $env:COMPUTERNAME -or $h -ilike "$($env:COMPUTERNAME).*")
$s = $null
try {
    $sb = [scriptblock]::Create($scriptText)
    if ($isLocal) { $r = @(& $sb @argList) }
    else {
        $opt = New-PSSessionOption -OpenTimeout 15000 -OperationTimeout ([int](($opMin + 5) * 60000))
        try { $s = New-PSSession -ComputerName $h -SessionOption $opt -ErrorAction Stop }
        catch { if (-not $cred) { throw }; $s = New-PSSession -ComputerName $h -SessionOption $opt -Credential $cred -ErrorAction Stop }
        $r = @(Invoke-Command -Session $s -ErrorAction Stop -ScriptBlock $sb -ArgumentList $argList)
    }
    foreach ($x in $r) { if ("$x") { "H:$h|$x" } }
} catch { "H:$h|ERR|$($_.Exception.Message -replace '[\r\n|]+', ' ')" }
finally { if ($s) { Remove-PSSession $s -ErrorAction SilentlyContinue } }
'@

# Fuehrt $ScriptText mit $ArgList auf allen PCs aus; OnComplete erhaelt param($lines (H:PC|... ohne H:), $state)
function Start-SwParallel {
    param([string[]]$Hosts, [string]$ScriptText, [object[]]$ArgList, [int]$OpMin = 5, [object]$State, [scriptblock]$OnComplete)
    $jobSec = [int][Math]::Max(300, [Math]::Ceiling($Hosts.Count / 8.0) * ($OpMin + 6) * 60)
    Invoke-AsyncCommand -ScriptBlock {
        param($hostStr, $scriptText, $argList, $workerText, $opMin, $deadlineSec, $cred)
        $list = @($hostStr -split '\|' | Where-Object { $_ })
        $deadline = (Get-Date).AddSeconds($deadlineSec)
        $pool = [runspacefactory]::CreateRunspacePool(1, 8); $pool.Open()
        $jobs = foreach ($h in $list) {
            $ps = [PowerShell]::Create().AddScript($workerText).AddArgument($h).AddArgument($scriptText).AddArgument($argList).AddArgument($cred).AddArgument($opMin)
            $ps.RunspacePool = $pool
            [pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke(); Host = $h }
        }
        $out = New-Object System.Collections.Generic.List[string]
        while (@($jobs | Where-Object { -not $_.Handle.IsCompleted }).Count -gt 0 -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 1 }
        $stuck = 0
        foreach ($j in @($jobs)) {
            if ($j.Handle.IsCompleted) {
                try { foreach ($x in $j.PS.EndInvoke($j.Handle)) { if ("$x") { $out.Add("$x") } } }
                catch { $out.Add("H:$($j.Host)|ERR|$($_.Exception.Message -replace '[\r\n|]+', ' ')") }
                finally { $j.PS.Dispose() }
            } else {
                $stuck++
                $out.Add("H:$($j.Host)|ERR|Zeitlimit des Tools erreicht (Ergebnis am Client pruefen)")
                try { [void]$j.PS.BeginStop($null, $null) } catch { }
            }
        }
        if ($stuck -eq 0) { try { $pool.Close(); $pool.Dispose() } catch { } }
        $out -join "`n"
    } -ArgumentList @(($Hosts -join '|'), $ScriptText, $ArgList, $script:SwRunWorkerText, $OpMin, ($jobSec - 30), $script:RemoteCred) -TimeoutSec $jobSec -State $State -OnComplete $OnComplete
}

# Ausgabe zerlegen: Hashtable PC -> Liste der Zeilen (ohne H:PC|); fehlende PCs -> 'ERR|keine Antwort'
function Split-SwParallelResult([string]$Result, [string[]]$Hosts) {
    $map = [ordered]@{}
    foreach ($h in @($Hosts)) { $map[$h.ToUpper()] = [pscustomobject]@{ Computer = $h; Lines = New-Object System.Collections.Generic.List[string] } }
    foreach ($l in ("$Result" -split "`r?`n")) {
        if ($l -notmatch '^H:([^|]*)\|(.*)$') { continue }
        $k = $Matches[1].ToUpper()
        if (-not $map.Contains($k)) { $map[$k] = [pscustomobject]@{ Computer = $Matches[1]; Lines = New-Object System.Collections.Generic.List[string] } }
        $map[$k].Lines.Add($Matches[2])
    }
    foreach ($v in $map.Values) { if ($v.Lines.Count -eq 0) { $v.Lines.Add('ERR|keine Antwort') } }
    return @($map.Values)
}

# Status-Zeilen eines PCs -> Tabellenzeile: PC | installiert | Version | Erkennung | Fehler
function ConvertFrom-SwStatusLines([string]$Computer, [string[]]$Lines) {
    $st = @($Lines | Where-Object { $_ -match '^STATUS\|' }) | Select-Object -First 1
    if ($st) {
        $p = $st -split '\|', 4; while ($p.Count -lt 4) { $p += '' }
        $inst = switch ($p[1]) { '1' { 'Ja' } '0' { 'Nein' } default { '?' } }
        return [pscustomobject]@{ Computer = $Computer; Installed = $(if ($p[1] -eq '1') { $true } elseif ($p[1] -eq '0') { $false } else { $null }); Text = $inst; Version = $p[2]; Detection = $p[3]; Error = '' }
    }
    $err = @($Lines | ForEach-Object { $_ -replace '^ERR\|', '' }) -join ' '
    return [pscustomobject]@{ Computer = $Computer; Installed = $null; Text = 'Fehler'; Version = ''; Detection = ''; Error = $err }
}

function Start-SwPackageStatus {
    param([string[]]$Hosts, [object]$Package)
    $Hosts = @($Hosts | Where-Object { $_ } | ForEach-Object { "$_".Trim() } | Where-Object { $_ } | Sort-Object -Unique)
    if (-not $Hosts.Count -or -not $Package) { return }
    $s = $Package.Settings
    Out-Console "Status '$($s.Name)' auf $($Hosts.Count) PC(s) ..." 'Info'
    Start-SwParallel -Hosts $Hosts -ScriptText $script:RS_SwInstall.ToString() -ArgList @('', (Get-SwPkgJson $Package $s), $false, $true) -OpMin 2 `
        -State @{ Hosts = $Hosts; Package = $Package } -OnComplete {
        param($result, $st)
        $r = "$result".Trim()
        if ($r -match '^FEHLER:') { Out-Console "Status: $r" 'Error'; return }
        $objs = @(Split-SwParallelResult $r $st.Hosts | ForEach-Object { ConvertFrom-SwStatusLines $_.Computer $_.Lines.ToArray() })
        $yes = @($objs | Where-Object { $_.Installed -eq $true }).Count; $no = @($objs | Where-Object { $_.Installed -eq $false }).Count; $bad = $objs.Count - $yes - $no
        foreach ($o in $objs) { Out-Console "  $($o.Computer): $($o.Text)$(if ($o.Version) { " $($o.Version)" })$(if ($o.Detection) { " - $($o.Detection)" })$(if ($o.Error) { " - $(Format-RemoteError $o.Error)" })" $(if ($o.Installed -eq $true) { 'Success' } elseif ($o.Installed -eq $false) { 'Warning' } else { 'Error' }) }
        Out-Console "Status '$($st.Package.Settings.Name)': $yes installiert / $no nicht installiert / $bad unbekannt" 'Info'
        [void](Save-SwStatus $st.Package @($objs | ForEach-Object { [pscustomobject]@{ Computer = $_.Computer; Installed = $_.Installed; Version = $_.Version; Detection = $_.Detection; Result = $(if ($_.Error) { $_.Error } else { $_.Text }) } }) 'Status')
        $rows = @($objs | ForEach-Object { , @($_.Computer, $_.Text, $_.Version, $_.Detection, (Format-RemoteError $_.Error)) })
        Show-DataGridWindow -Title "Status - $($st.Package.Settings.Name)" -Columns @('Computer', 'installiert', 'Version', 'Erkennung', 'Fehler') -Rows $rows -Sort 'Computer ASC' `
            -CountText "$($rows.Count) PCs ($yes installiert / $no nicht installiert / $bad unbekannt)" -Width 1100 -Height 560
        if ($script:SwUi) { try { Show-SwSelectedDetails } catch { } }
    }
}

function Start-SwPackageUninstall {
    param([string[]]$Hosts, [object]$Package)
    $Hosts = @($Hosts | Where-Object { $_ } | ForEach-Object { "$_".Trim() } | Where-Object { $_ } | Sort-Object -Unique)
    if (-not $Hosts.Count -or -not $Package) { return }
    $job = Get-SwUninstallJob -Package $Package
    if (-not $job) { Out-Console "Deinstallation '$($Package.Settings.Name)': kein Deinstallationsbefehl hinterlegt" 'Error'; return }
    Out-Console "Deinstallation '$($Package.Settings.Name)' auf $($Hosts.Count) PC(s) ..." 'Info'
    Start-SwParallel -Hosts $Hosts -ScriptText $job.ScriptText -ArgList @($job.ArgsJson, $job.TimeoutMin) -OpMin ($job.TimeoutMin + 2) `
        -State @{ Hosts = $Hosts; Package = $Package } -OnComplete {
        param($result, $st)
        $r = "$result".Trim()
        if ($r -match '^FEHLER:') { Out-Console "Deinstallation: $r" 'Error'; return }
        $rows = New-Object System.Collections.Generic.List[object]
        foreach ($x in @(Split-SwParallelResult $r $st.Hosts)) {
            $res = @($x.Lines | Where-Object { $_ -match '^RES:' }) | Select-Object -Last 1
            if ($res -and $res -match '^RES:[^|]*\|(OK|WARN|FEHLER)\|(.*)$') { $rows.Add(@($x.Computer, $Matches[1], (Format-RemoteError $Matches[2]))) }
            else { $rows.Add(@($x.Computer, 'FEHLER', (Format-RemoteError (@($x.Lines | ForEach-Object { $_ -replace '^ERR\|', '' }) -join ' ')))) }
        }
        $ok = @($rows | Where-Object { $_[1] -eq 'OK' }).Count; $bad = $rows.Count - $ok
        foreach ($rw in $rows) { Out-Console "  $($rw[0]): $($rw[2])" $(switch ($rw[1]) { 'OK' { 'Success' } 'WARN' { 'Warning' } default { 'Error' } }) }
        Out-Console "Deinstallation '$($st.Package.Settings.Name)': $ok OK / $bad mit Problemen" $(if ($bad) { 'Warning' } else { 'Success' })
        [void](Save-SwStatus $st.Package @($rows | ForEach-Object { [pscustomobject]@{ Computer = $_[0]; Installed = $(if ($_[1] -eq 'OK') { $false } else { $null }); Version = ''; Detection = ''; Result = "Deinstallation $($_[1]): $($_[2])" } }) 'Deinstallation')
        if ($rows.Count -gt 1) {
            Show-DataGridWindow -Title "Deinstallation - $($st.Package.Settings.Name)" -Columns @('Computer', 'Status', 'Ergebnis') -Rows $rows.ToArray() -Sort 'Status ASC, Computer ASC' `
                -CountText "$($rows.Count) PCs ($ok OK / $bad mit Problemen)" -Width 1100 -Height 560
        }
        if ($script:SwUi) { try { Show-SwSelectedDetails } catch { } }
    }
}

# Abgelegte Dateien/Ordner in die Softwareverteilung kopieren (Drag&Drop und "Datei hinzufuegen")
# Rueckgabe: @{ Added = Namen; Skipped = Texte }
function Add-SwItems([string[]]$Paths, [string]$Dest) {
    $added = New-Object System.Collections.Generic.List[string]
    $skip = New-Object System.Collections.Generic.List[string]
    $destFull = [IO.Path]::GetFullPath($Dest).TrimEnd('\', '/')
    foreach ($p in @($Paths | Where-Object { $_ })) {
        $it = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
        if (-not $it) { $skip.Add("$([IO.Path]::GetFileName($p)): nicht gefunden"); continue }
        $parent = [IO.Path]::GetFullPath((Split-Path -Parent $it.FullName)).TrimEnd('\', '/')
        if ($parent -ieq $destFull -or $it.FullName.TrimEnd('\', '/') -ieq $destFull) { $skip.Add("$($it.Name): liegt schon in der Softwareverteilung"); continue }
        try {
            if ($it.PSIsContainer) {
                if ($it.Name -like '_*') { $skip.Add("$($it.Name): Ordner mit _ am Anfang werden ignoriert"); continue }
                $inst = @(Get-ChildItem -LiteralPath $it.FullName -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.msi', '.exe', '.msp' })
                if (-not $inst.Count) { $skip.Add("$($it.Name): kein Installer (.msi/.exe/.msp) direkt im Ordner"); continue }
                $target = Join-Path $Dest $it.Name
                if (-not (Test-Path -LiteralPath $target)) { New-Item -ItemType Directory -Path $target -Force -ErrorAction Stop | Out-Null }
                foreach ($c in @(Get-ChildItem -LiteralPath $it.FullName -Force)) { Copy-Item -LiteralPath $c.FullName -Destination $target -Recurse -Force -ErrorAction Stop }
                $added.Add("$($it.Name)\")
            } else {
                if ($it.Extension.ToLower() -notin '.msi', '.exe', '.msp') { $skip.Add("$($it.Name): nur .msi, .exe oder .msp"); continue }
                Copy-Item -LiteralPath $it.FullName -Destination $Dest -Force -ErrorAction Stop
                $added.Add($it.Name)
            }
        } catch { $skip.Add("$($it.Name): $($_.Exception.Message)") }
    }
    return [pscustomobject]@{ Added = $added.ToArray(); Skipped = $skip.ToArray() }
}

# Dateien aus einem Drag&Drop-Ereignis (nur Dateisystem)
function Get-SwDropPaths($Data) {
    # 'FileDrop' = [System.Windows.DataFormats]::FileDrop
    try { if (-not $Data -or -not $Data.GetDataPresent('FileDrop')) { return @() } } catch { return @() }
    return @(@($Data.GetData('FileDrop')) | ForEach-Object { "$_" } | Where-Object { $_ })
}

# Vorschlaege aus dem Sandbox-Test, die vom Paket abweichen: Liste @{ Field; Value; Text }
# Wird eine Erkennung vorgeschlagen, werden die uebrigen Erkennungsfelder geleert (bei der Verteilung muessen ALLE
# ausgefuellten Erkennungen zutreffen - eine alte, nicht passende wuerde die neue aushebeln). Mindestversion nur, wenn
# nicht mit vorgeschlagen.
function Get-SwSandboxChanges($Settings, $Proposal) {
    $out = New-Object System.Collections.Generic.List[object]
    if (-not $Proposal) { return @() }
    $labels = [ordered]@{ DetectProductCode = 'Erkennung (ProductCode)'; DetectName = 'Erkennung (Name)'; MinVersion = 'Mindestversion'; DetectKey = 'Erkennung (Schluessel)'; DetectFile = 'Erkennung (Datei)'; UninstallCmd = 'Deinstallation' }
    foreach ($k in $labels.Keys) {
        $v = "$($Proposal.$k)".Trim()
        if ($v -and $v -ne "$($Settings.$k)".Trim()) { $out.Add([pscustomobject]@{ Field = $k; Value = $v; Text = "$($labels[$k]): $v" }) }
    }
    $det = @('DetectName', 'DetectProductCode', 'DetectKey', 'DetectFile')
    if (@($det | Where-Object { "$($Proposal.$_)".Trim() }).Count) {
        foreach ($k in @($det + 'MinVersion')) {
            if ("$($Proposal.$k)".Trim()) { continue }
            $old = "$($Settings.$k)".Trim()
            if ($old) { $out.Add([pscustomobject]@{ Field = $k; Value = ''; Text = "wird geleert: $($labels[$k]) (bisher $old)" }) }
        }
    }
    if ($Proposal.OfferNoDesktop -and -not ($Settings.NoDesktop -eq $true)) { $out.Add([pscustomobject]@{ Field = 'NoDesktop'; Value = $true; Text = 'Keine Desktop-Verknuepfung: anhaken (Setup legt eine an)' }) }
    return $out.ToArray()
}

# ----------------------------------------------------------------------------
# Fenster Softwareverteilung
# ----------------------------------------------------------------------------
$script:SwUi = $null
$script:SwSb = $null
$script:SwSbTimer = $null
function Update-SwWindowList([string]$SelectId = '') {
    $sw = $script:SwUi; if (-not $sw) { return }
    $sw.Pkgs = @(Get-SwPackages)
    $sw.Loading = $true
    $sw.Lst.Items.Clear()
    foreach ($p in $sw.Pkgs) {
        $ts = Get-SwTestState $p
        [void]$sw.Lst.Items.Add("$($ts.Mark) $(if ($p.Configured) { '' } else { '* ' })$($p.Settings.Name)   [$($p.Type)$(if ($p.IsDir) { ', Ordner' })]$(if ($ts.State -eq 'Veraltet') { '  (Test veraltet)' })")
    }
    $sw.Loading = $false
    $sw.LblFolder.Text = "Ordner: $(Get-SwFolder)   ($($sw.Pkgs.Count) Pakete, * = noch nicht geprueft/gespeichert)"
    $sw.LblTarget.Text = "Gewaehlter Computer: $(Get-TargetComputer)"
    $idx = 0
    if ($SelectId) { for ($i = 0; $i -lt $sw.Pkgs.Count; $i++) { if ($sw.Pkgs[$i].Id -eq $SelectId) { $idx = $i } } }
    if ($sw.Pkgs.Count -gt 0) { $sw.Lst.SelectedIndex = $idx } else { Show-SwPackageDetails $null }
    Update-SwSandboxButton
}
# Text fuer die Abhaengigkeiten (Namen, fehlende markiert)
function Get-SwDepText([string[]]$Ids, [object[]]$Pkgs) {
    $ids = @($Ids | Where-Object { "$_".Trim() })
    if (-not $ids.Count) { return 'keine' }
    return (@($ids | ForEach-Object { $i = "$_"; $d = @($Pkgs | Where-Object { $_.Id -eq $i }) | Select-Object -First 1; if ($d) { "$($d.Settings.Name)" } else { "$i (fehlt)" } }) -join ', ')
}
# Ergebnisfeld Sandbox (Farbe nach Level)
function Set-SwSandboxText([string]$Text, [string]$Level = 'Info') {
    $sw = $script:SwUi; if (-not $sw -or -not $sw.TxtSandbox) { return }
    $c = switch ($Level) { 'OK' { '#FFA6E3A1' } 'Hinweise' { '#FFF9E2AF' } 'Fehler' { '#FFF38BA8' } 'Veraltet' { '#FFFAB387' } default { '#FFCDD6F4' } }
    $sw.TxtSandbox.Text = $Text
    try { $sw.TxtSandbox.Foreground = (New-Object System.Windows.Media.BrushConverter).ConvertFromString($c) } catch { }
}
# Infotext rechts (Installer, Sandbox-Test, Abhaengigkeiten, letzter Status)
function Get-SwInfoLines($p) {
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
    $ts = Get-SwTestState $p
    $lines += "Sandbox:      $($ts.Mark) $($ts.Text)"
    if (@($p.Settings.DependsOn).Count) { $lines += "Vorher:       $(Get-SwDepText @($p.Settings.DependsOn) $script:SwUi.Pkgs)" }
    $st = Get-SwStatus $p
    if ($st -and @($st.Computers).Count) {
        $c = @($st.Computers)
        $lines += "Letzter Status ($($st.Updated)): $(@($c | Where-Object { $_.Installed -eq $true }).Count) von $($c.Count) PC(s) installiert"
    }
    if ($i.Note) { $lines += ''; $lines += "HINWEIS: $($i.Note)" }
    if (@($i.Props).Count -gt 0) {
        $lines += ''; $lines += 'Oeffentliche MSI-Eigenschaften (per Parameter setzbar, z.B. INSTALLDIR="C:\Pfad"):'
        $lines += @($i.Props | ForEach-Object { "  $_" })
    }
    return $lines
}
# nur Infotext des gewaehlten Pakets neu (Formular bleibt unveraendert)
function Show-SwSelectedDetails {
    $sw = $script:SwUi; if (-not $sw) { return }
    $i = $sw.Lst.SelectedIndex
    if ($i -lt 0 -or $i -ge $sw.Pkgs.Count) { return }
    $sw.TxtInfo.Text = ((Get-SwInfoLines $sw.Pkgs[$i]) -join "`r`n")
}
function Show-SwPackageDetails($p) {
    $sw = $script:SwUi; if (-not $sw) { return }
    $sw.Loading = $true
    try {
        $sw.CmbInst.Items.Clear(); $sw.CmbArgs.Items.Clear()
        if (-not $p) {
            foreach ($c in 'TxtName', 'TxtDetect', 'TxtCode', 'TxtMinVer', 'TxtCodes', 'TxtTimeout', 'TxtNote', 'TxtInfo', 'TxtUninst', 'TxtDetKey', 'TxtDetFile', 'TxtWinget') { $sw[$c].Text = '' }
            $sw.CmbArgs.Text = ''; $sw.LblType.Text = ''; $sw.ChkNoDesk.IsChecked = $false; $sw.Deps = @(); $sw.LblDeps.Text = 'keine'
            $sw.TxtInfo.Text = "Noch keine Pakete.`n`n'Datei hinzufuegen' oder MSI/EXE/MSP in den Ordner legen (ein Paket = eine Datei)`noder einen Unterordner mit Installer + allen benoetigten Dateien anlegen.`nSetup-Dateien oder Ordner koennen auch auf die Paketliste gezogen werden.`n(Ziehen aus dem Explorer geht nur, wenn der Explorer ebenfalls als Administrator laeuft (Windows-Sperre) - sonst 'Datei hinzufuegen'.)"
            if (-not $script:SwSb) { Set-SwSandboxText '' }
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
        $sw.TxtUninst.Text = "$($s.UninstallCmd)"; $sw.TxtDetKey.Text = "$($s.DetectKey)"; $sw.TxtDetFile.Text = "$($s.DetectFile)"; $sw.TxtWinget.Text = "$($s.WingetId)"
        $sw.ChkNoDesk.IsChecked = ($s.NoDesktop -eq $true)
        $sw.Deps = @($s.DependsOn); $sw.LblDeps.Text = Get-SwDepText $sw.Deps $sw.Pkgs
        $sw.LblType.Text = "$($p.Type) - $($p.Info.Framework)$(if (-not $p.Configured) { '   (noch nicht gespeichert)' })"
        $sw.TxtInfo.Text = ((Get-SwInfoLines $p) -join "`r`n")
        if (-not ($script:SwSb -and $script:SwSb.Id -eq $p.Id)) {
            $ts = Get-SwTestState $p
            $t = $ts.Text
            if ($s.Sandbox -and "$($s.Sandbox.Note)") { $t += "`r`n$($s.Sandbox.Note)" }
            Set-SwSandboxText $t $(switch ($ts.State) { 'OK' { 'OK' } 'Hinweise' { 'Hinweise' } 'Fehler' { 'Fehler' } 'Veraltet' { 'Veraltet' } default { 'Info' } })
        }
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
    $dkT = "$($sw.TxtDetKey.Text)".Trim(); if ($dkT -and (ConvertTo-SwRegPath $dkT) -notmatch '^(HKLM|HKCU):\\.+') { throw 'Erkennung (Schluessel): Registry-Pfad wie HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\<Name>' }
    $wgT = "$($sw.TxtWinget.Text)".Trim(); if ($wgT -and $wgT -notmatch '^\S+$') { throw 'WinGet-ID ohne Leerzeichen (z.B. 7zip.7zip)' }
    return [ordered]@{
        Name = $name; Installer = "$($sw.CmbInst.SelectedItem)"; Arguments = "$($sw.CmbArgs.Text)".Trim(); SuccessCodes = $codes
        DetectName = $dnT; DetectProductCode = "$($sw.TxtCode.Text)".Trim(); MinVersion = $mvT; TimeoutMin = $tmo; Note = "$($sw.TxtNote.Text)".Trim()
        UninstallCmd = "$($sw.TxtUninst.Text)".Trim(); DetectKey = $dkT; DetectFile = "$($sw.TxtDetFile.Text)".Trim(); NoDesktop = [bool]$sw.ChkNoDesk.IsChecked
        DependsOn = @($sw.Deps | Where-Object { "$_".Trim() }); WingetId = $wgT
    }
}
function Save-SwForm {
    $sw = $script:SwUi
    $i = $sw.Lst.SelectedIndex
    if ($i -lt 0 -or $i -ge $sw.Pkgs.Count) { return $null }
    $p = $sw.Pkgs[$i]
    try { $set = Get-SwFormSettings } catch { [void](Show-HMDialogBox -Owner $sw.Win -Text ("$($_.Exception.Message)") -Title 'Softwareverteilung' -Mode 'OK' -Icon 'Warning'); return $null }
    if ($p.Type -eq 'EXE' -and -not $set.Arguments) {
        if ("$((Show-HMDialogBox -Owner $sw.Win -Text "Keine Parameter fuer die EXE angegeben.`n`nOhne Silent-Parameter kann der Installer am Client unsichtbar auf eine Eingabe warten (bis zum Timeout).`n`nTrotzdem speichern?" -Title 'Softwareverteilung' -Mode 'YesNo' -Icon 'Warning'))" -ne 'Yes') { return $null }
    }
    # Sandbox-Ergebnis bleibt erhalten (Signatur entscheidet, ob es noch gilt)
    $set.Sandbox = $p.Settings.Sandbox
    if (-not (Save-SwSettings $p $set)) { return $null }
    Out-Console "Softwareverteilung: Einstellungen fuer '$($set.Name)' gespeichert" 'Success'
    $id = $p.Id
    Update-SwWindowList $id
    return ($sw.Pkgs | Where-Object { $_.Id -eq $id } | Select-Object -First 1)
}

# Auswahlliste (dunkel): Items mit Title, Sub, Id. Rueckgabe: Ids oder $null bei Abbruch
function Show-SwPickList {
    param([string]$Title, [string]$Hint, [object[]]$Items, [string[]]$Selected = @(), [switch]$Multi, $Owner = $null)
    $x = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$([System.Security.SecurityElement]::Escape($Title))" Width="520" Height="460" WindowStartupLocation="CenterOwner" Background="#FF1E1E2E" ShowInTaskbar="False">
  <DockPanel Margin="12">
    <TextBlock x:Name="lblHint" DockPanel.Dock="Top" Foreground="#FFA6ADC8" TextWrapping="Wrap" Margin="0,0,0,8"/>
    <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,10,0,0">
      <Button x:Name="btnOk" Content="OK" Width="100" Height="28" Background="#FFA6E3A1" Foreground="#FF1E1E2E" FontWeight="SemiBold" Margin="0,0,6,0" IsDefault="True"/>
      <Button x:Name="btnCancel" Content="Abbrechen" Width="100" Height="28" Background="#FF45475A" Foreground="#FFCDD6F4" IsCancel="True"/>
    </StackPanel>
    <ListBox x:Name="lst" Background="#FF313244" Foreground="#FFCDD6F4" BorderBrush="#FF585B70">
      <ListBox.ItemTemplate>
        <DataTemplate>
          <StackPanel Margin="0,2">
            <TextBlock Text="{Binding Title}" FontWeight="SemiBold"/>
            <TextBlock Text="{Binding Sub}" Foreground="#FFA6ADC8" FontSize="10"/>
          </StackPanel>
        </DataTemplate>
      </ListBox.ItemTemplate>
    </ListBox>
  </DockPanel>
</Window>
"@
    $w = [System.Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new(([xml]$x)))
    if ($script:AppIcon) { $w.Icon = $script:AppIcon }
    if ($Owner) { try { $w.Owner = $Owner } catch { } }
    $lst = $w.FindName('lst')
    $w.FindName('lblHint').Text = $Hint
    $lst.SelectionMode = $(if ($Multi) { 'Multiple' } else { 'Single' })
    $src = @($Items)
    $lst.ItemsSource = $src
    foreach ($it in $src) { if (@($Selected) -contains "$($it.Id)") { if ($Multi) { [void]$lst.SelectedItems.Add($it) } else { $lst.SelectedItem = $it } } }
    $state = @{ Ids = $null }
    $ok = { $state.Ids = @(@($lst.SelectedItems) | ForEach-Object { "$($_.Id)" }); $w.Close() }
    $w.FindName('btnOk').Add_Click($ok)
    if (-not $Multi) { $lst.Add_MouseDoubleClick($ok) }
    $w.FindName('btnCancel').Add_Click({ $w.Close() })
    try { Set-HMWindowScale $w } catch { }
    [void]$w.ShowDialog()
    if ($null -eq $state.Ids) { return $null }
    # Reihenfolge wie in der Liste
    $sel = $state.Ids
    return , @($src | Where-Object { $sel -contains "$($_.Id)" } | ForEach-Object { "$($_.Id)" })
}

# Abhaengigkeiten waehlen (ohne Kreis: Pakete, die selbst vom aktuellen abhaengen, fehlen in der Liste)
function Select-SwDependencies {
    $sw = $script:SwUi; if (-not $sw) { return }
    $i = $sw.Lst.SelectedIndex
    if ($i -lt 0 -or $i -ge $sw.Pkgs.Count) { return }
    $p = $sw.Pkgs[$i]
    $cand = @($sw.Pkgs | Where-Object { $_.Id -ne $p.Id -and -not (Test-SwDependsOn $_ $p.Id $sw.Pkgs) })
    if (-not $cand.Count) { [void](Show-HMDialogBox -Owner $sw.Win -Text 'Keine weiteren Pakete im Ordner Softwareverteilung (oder alle haengen von diesem Paket ab).' -Title 'Abhaengigkeiten' -Mode 'OK' -Icon 'Information'); return }
    $items = @($cand | ForEach-Object { [pscustomobject]@{ Title = "$($_.Settings.Name)"; Sub = "$($_.Id)   [$($_.Type)]"; Id = "$($_.Id)" } })
    $sel = Show-SwPickList -Title 'Abhaengigkeiten' -Multi -Owner $sw.Win -Items $items -Selected @($sw.Deps) `
        -Hint "Diese Pakete werden vorher auf denselben PCs installiert (bereits vorhandene werden uebersprungen). Anklicken = auswaehlen/abwaehlen. Danach 'Speichern'."
    if ($null -eq $sel) { return }
    $sw.Deps = @($sel)
    $sw.LblDeps.Text = "$(Get-SwDepText $sw.Deps $sw.Pkgs)   (Speichern nicht vergessen)"
}

# Knopf Testinstallation nur aktiv, wenn keine Sandbox laeuft und nichts kopiert/geladen wird; WinGet nicht waehrend des Kopierens
function Update-SwSandboxButton {
    $sw = $script:SwUi; if (-not $sw -or -not $sw.BtnSandbox) { return }
    $busy = [bool]$script:SwSb -or [bool]$script:SwWg
    if (-not $busy -and (Get-Command Test-HMSandboxBusy -ErrorAction SilentlyContinue)) { try { $busy = [bool](Test-HMSandboxBusy) } catch { } }
    $sw.BtnSandbox.IsEnabled = -not $busy
    if ($sw.Contains('BtnWinget') -and $sw.BtnWinget) { $sw.BtnWinget.IsEnabled = -not ([bool]$script:SwWg -or ($script:SwSb -and "$($script:SwSb.Phase)" -eq 'Copy')) }
}

# einmalig nach $Seconds Knopfzustand neu pruefen (die Sandbox braucht nach dem Schliessen ein paar Sekunden)
$script:SwSbRecheck = $null
function Start-SwSandboxRecheck([int]$Seconds = 10) {
    try {
        if (-not $script:SwSbRecheck) {
            $script:SwSbRecheck = New-Object System.Windows.Threading.DispatcherTimer
            $script:SwSbRecheck.Add_Tick({ $script:SwSbRecheck.Stop(); try { Update-SwSandboxButton } catch { } })
        }
        $script:SwSbRecheck.Stop()
        $script:SwSbRecheck.Interval = [TimeSpan]::FromSeconds($Seconds)
        $script:SwSbRecheck.Start()
    } catch { }
}

function Start-SwSandboxTest {
    $sw = $script:SwUi; if (-not $sw) { return }
    if ($script:SwSb) { [void](Show-HMDialogBox -Owner $sw.Win -Text 'Es laeuft bereits eine Testinstallation.' -Title 'Sandbox' -Mode 'OK' -Icon 'Information'); return }
    if ($script:SwWg) { [void](Show-HMDialogBox -Owner $sw.Win -Text 'WinGet arbeitet noch - bitte warten.' -Title 'Sandbox' -Mode 'OK' -Icon 'Information'); return }
    foreach ($fn in 'Test-HMSandboxAvailable', 'Show-HMSandboxSetup', 'Test-HMSandboxBusy', 'Start-HMSandboxTest', 'Get-HMSandboxProgress', 'Get-HMSandboxSummary') {
        if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) { [void](Show-HMDialogBox -Owner $sw.Win -Text "Sandbox-Funktion fehlt ($fn) - HUMig unvollstaendig?" -Title 'Sandbox' -Mode 'OK' -Icon 'Warning'); return }
    }
    # Inno-Setup: fuer alle Benutzer installieren (sonst landet das Programm im Benutzerprofil des ausfuehrenden Kontos)
    $i0 = $sw.Lst.SelectedIndex
    if ($i0 -ge 0 -and $i0 -lt $sw.Pkgs.Count -and "$($sw.Pkgs[$i0].Info.Framework)" -eq 'Inno Setup' -and "$($sw.CmbArgs.Text)" -notmatch '(?i)/(ALLUSERS|CURRENTUSER)\b') {
        $sw.CmbArgs.Text = ("$($sw.CmbArgs.Text)".Trim() + ' /ALLUSERS').Trim()
        Out-Console 'Softwareverteilung: Parameter um /ALLUSERS ergaenzt (Inno-Setup fuer alle Benutzer statt ins Benutzerprofil).' 'Info'
    }
    # Deinstallationsbefehl aus dem Sandbox-Profil (frueherer Test) passt auf keinem PC - wird beim Test neu ermittelt
    if ("$($sw.TxtUninst.Text)" -match '(?i)\\Users\\WDAGUtilityAccount\\') {
        $sw.TxtUninst.Text = ''
        Out-Console 'Softwareverteilung: Deinstallationsbefehl zeigte ins Sandbox-Benutzerprofil - wird neu ermittelt.' 'Warning'
    }
    $p = Save-SwForm; if (-not $p) { return }
    if (-not (Test-HMSandboxAvailable)) { Show-HMSandboxSetup -Owner $sw.Win; return }
    if (Test-HMSandboxBusy) { [void](Show-HMDialogBox -Owner $sw.Win -Text 'Es laeuft bereits eine Windows Sandbox - bitte zuerst schliessen.' -Title 'Sandbox' -Mode 'OK' -Icon 'Information'); Update-SwSandboxButton; return }
    $testUn = [bool]$sw.ChkSbUninst.IsChecked; $keep = [bool]$sw.ChkSbKeep.IsChecked
    $sig = Get-SwPackageSignature -Package $p
    $script:SwSb = @{ Job = $null; Phase = 'Copy'; Package = $p; Id = $p.Id; Name = "$($p.Settings.Name)"; Signature = $sig; TestUn = $testUn; KeepOpen = $keep; Started = (Get-Date); Sync = $null; LastLog = (Get-Date) }
    # Paket (und Abhaengigkeiten) zuerst in den lokalen Sandbox-Ordner spiegeln - im Hintergrund, kann bei grossen Paketen dauern
    $plan = @()
    if (Get-Command Get-HMSandboxSyncPlan -ErrorAction SilentlyContinue) {
        try { $plan = @(Get-HMSandboxSyncPlan -Package $p -Settings $p.Settings) } catch { $plan = @() }
    }
    if ($plan.Count) {
        $sync = New-HMSandboxSyncState $plan
        $script:SwSb.Sync = $sync
        $mb = [Math]::Round([double]$sync.Total / 1MB, 1)
        Out-Console "Testinstallation '$($p.Settings.Name)': kopiere $mb MB in den lokalen Sandbox-Ordner ($(@($plan | ForEach-Object { $_.Name }) -join ', ')) ..." 'Info'
        Set-SwSandboxText "Kopiere Paket fuer die Sandbox: $(Get-HMSandboxSyncText $sync)" 'Info'
        Start-SwSandboxTimer
        Update-SwSandboxButton
        [void](Start-HMSandboxSync -Plan $plan -Sync $sync -State $script:SwSb -OnComplete { param($result, $st) Complete-SwSandboxCopy $result $st })
        return
    }
    Start-SwSandboxRun
}

# Kopieren fertig (Hintergrund) -> Sandbox starten
function Complete-SwSandboxCopy($Result, $State) {
    if (-not $script:SwSb -or -not [object]::ReferenceEquals($script:SwSb, $State)) { return }
    $r = ConvertTo-HMAsyncResult $Result
    $secs = [int]((Get-Date) - [datetime]$State.Sync.Started).TotalSeconds
    if (-not $r.Ok) {
        Out-Console "Testinstallation '$($State.Name)': Kopieren fehlgeschlagen nach $secs s - $($r.Error)" 'Error'
        Stop-SwSandboxWatch
        Set-SwSandboxText "Sandbox nicht gestartet - Kopieren fehlgeschlagen: $($r.Error)" 'Fehler'
        return
    }
    Out-Console "Testinstallation '$($State.Name)': $([Math]::Round([double]$State.Sync.Total / 1MB, 1)) MB kopiert in $secs s" 'Success'
    Start-SwSandboxRun
}

# Sandbox starten (Quelle ist gespiegelt bzw. aktuell)
function Start-SwSandboxRun {
    $w = $script:SwSb; if (-not $w) { return }
    $p = $w.Package
    $job = $null
    try { $job = Start-HMSandboxTest -Package $p -Settings $p.Settings -TestUninstall:$w.TestUn -KeepOpen:$w.KeepOpen }
    catch {
        Out-Console "Sandbox nicht gestartet: $($_.Exception.Message)" 'Error'
        Stop-SwSandboxWatch
        Set-SwSandboxText "Sandbox nicht gestartet: $($_.Exception.Message)" 'Fehler'
        return
    }
    $w.Job = $job; $w.Phase = 'Run'; $w.Started = (Get-Date)
    Out-Console "Testinstallation in der Sandbox: '$($p.Settings.Name)'$(if ($w.TestUn) { ' (mit Deinstallation)' }) - die Installation laeuft im Sandbox-Fenster ..." 'Info'
    Set-SwSandboxText 'Sandbox wird gestartet ...' 'Info'
    Start-SwSandboxTimer
    Update-SwSandboxButton
}

function Start-SwSandboxTimer {
    if (-not $script:SwSbTimer) {
        $script:SwSbTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:SwSbTimer.Interval = [TimeSpan]::FromSeconds(3)
        $script:SwSbTimer.Add_Tick({ try { Update-SwSandboxWatch } catch { Out-Console "Sandbox-Ueberwachung: $($_.Exception.Message)" 'Error' } })
    }
    $script:SwSbTimer.Start()
}

function Stop-SwSandboxWatch {
    if ($script:SwSbTimer) { $script:SwSbTimer.Stop() }
    $script:SwSb = $null
    Update-SwSandboxButton
}

function Update-SwSandboxWatch {
    $w = $script:SwSb
    if (-not $w) { if ($script:SwSbTimer) { $script:SwSbTimer.Stop() }; return }
    $show = (-not $script:SwUi) -or ($script:SwUi.Lst.SelectedIndex -ge 0 -and $script:SwUi.Lst.SelectedIndex -lt $script:SwUi.Pkgs.Count -and $script:SwUi.Pkgs[$script:SwUi.Lst.SelectedIndex].Id -eq $w.Id)
    if ("$($w.Phase)" -eq 'Copy') {
        $t = Get-HMSandboxSyncText $w.Sync
        if ($show) { Set-SwSandboxText "Kopiere Paket fuer die Sandbox: $t" 'Info' }
        if (((Get-Date) - $w.LastLog).TotalSeconds -ge 30) { $w.LastLog = Get-Date; Out-Console "  kopiere fuer die Sandbox: $t" 'Info' }
        return
    }
    if (-not $w.Job) { return }
    $pr = $null; $msg = ''
    try { $pr = Get-HMSandboxProgress -Job $w.Job } catch { $msg = $_.Exception.Message }
    $state = if ($pr) { "$($pr.State)" } else { 'Error' }
    $secs = [int]((Get-Date) - $w.Started).TotalSeconds
    $clock = "$([int][Math]::Floor($secs / 60)):$('{0:D2}' -f ($secs % 60))"
    switch ($state) {
        'Waiting' { if ($show) { Set-SwSandboxText "Sandbox startet ($clock) - '$($w.Name)' ..." 'Info' }; return }
        'Running' { if ($show) { Set-SwSandboxText "Sandbox laeuft ($clock) - Installation von '$($w.Name)' im Sandbox-Fenster ..." 'Info' }; return }
        'Done' {
            Stop-SwSandboxWatch
            if (-not $w.KeepOpen -and (Get-Command Stop-HMSandbox -ErrorAction SilentlyContinue)) { try { Stop-HMSandbox } catch { } }
            Complete-SwSandboxTest $w $pr.Result
            # Sandbox-Prozesse enden erst einige Sekunden nach dem Schliessen -> Knopf danach noch einmal pruefen
            Start-SwSandboxRecheck 10
            return
        }
        default {
            Stop-SwSandboxWatch
            $t = switch ($state) {
                'Closed' { 'Sandbox wurde ohne Ergebnis geschlossen.' }
                'NotStarted' { 'Sandbox startet nicht - laeuft die Virtualisierung? (Task-Manager > Leistung > CPU > Virtualisierung: Aktiviert)' }
                'Timeout' { if ($pr -and "$($pr.Text)") { "$($pr.Text)" } else { 'Abbruch ohne Ergebnis (Zeitlimit) - Sandbox bitte von Hand schliessen.' } }
                default { "Sandbox-Ueberwachung abgebrochen: $msg" }
            }
            Out-Console "Testinstallation '$($w.Name)': $t" 'Warning'
            Set-SwSandboxText $t 'Hinweise'
            Start-SwSandboxRecheck 10
        }
    }
}

# Ergebnis auswerten: anzeigen, im Paket ablegen (Settings.Sandbox + Signatur), Vorschlaege nach Rueckfrage uebernehmen
function Complete-SwSandboxTest($Watch, $Result) {
    $pk = @(Get-SwPackages | Where-Object { $_.Id -eq $Watch.Id }) | Select-Object -First 1
    if (-not $pk) { Out-Console "Sandbox-Ergebnis: Paket '$($Watch.Name)' nicht mehr vorhanden" 'Warning'; return }
    $sum = $null
    $wd = ''; if ($Watch.Job) { $wd = "$($Watch.Job.WorkDir)" }
    try { $sum = Get-HMSandboxSummary -Result $Result -Package $pk -Settings $pk.Settings -WorkDir $wd } catch { Out-Console "Sandbox-Ergebnis nicht auswertbar: $($_.Exception.Message)" 'Error'; return }
    $lvl = "$($sum.Level)"; if ($lvl -notin 'OK', 'Hinweise', 'Fehler') { $lvl = 'Fehler' }
    $cl = switch ($lvl) { 'OK' { 'Success' } 'Hinweise' { 'Warning' } default { 'Error' } }
    $lines = @($sum.Lines | Where-Object { $null -ne $_ } | ForEach-Object { "$_" })
    Out-Console "=== Testinstallation: $($pk.Settings.Name) - $lvl ===" $cl
    foreach ($l in $lines) { Out-Console "  $l" $cl }
    $warn = @($sum.Proposal.Warnings | Where-Object { "$_" } | ForEach-Object { "$_" })
    if ($sum.Proposal -and $sum.Proposal.RunAsUser) { $warn += 'Setup installiert nur ins Benutzerprofil - die Verteilung laeuft als Administrator/SYSTEM: Schalter fuer "alle Benutzer" verwenden (Inno: /ALLUSERS, MSI: ALLUSERS=1).' }
    foreach ($x in $warn) { Out-Console "  ACHTUNG: $x" 'Warning' }
    $shown = $(if ($script:SwUi -and $script:SwUi.Lst.SelectedIndex -ge 0 -and $script:SwUi.Pkgs[$script:SwUi.Lst.SelectedIndex].Id -eq $pk.Id) { $true } else { $false })
    if ($shown) { Set-SwSandboxText (@($lines + @($warn | ForEach-Object { "ACHTUNG: $_" })) -join "`r`n") $lvl }

    $set = ConvertTo-SwSettingsHash $pk.Settings
    $info = ConvertTo-SwSettingsHash $sum.SandboxInfo
    if (-not "$($info.Result)") { $info.Result = $lvl }
    if (-not "$($info.Date)") { $info.Date = (Get-Date -Format 'yyyy-MM-dd HH:mm') }
    $info.Signature = $Watch.Signature
    $set.Sandbox = [pscustomobject]$info
    $changes = @(Get-SwSandboxChanges $pk.Settings $sum.Proposal)
    $taken = $false
    if ($changes.Count -and $lvl -ne 'Fehler') {
        $own = if ($script:SwUi) { $script:SwUi.Win } else { $script:Window }
        $msg = "Testinstallation '$($pk.Settings.Name)': $lvl`n`nVorschlag:`n  $(@($changes | ForEach-Object { $_.Text }) -join "`n  ")"
        if ($warn.Count) { $msg += "`n`nACHTUNG:`n  $($warn -join "`n  ")" }
        $msg += "`n`nIns Paket uebernehmen und speichern?"
        if ("$((Show-HMDialogBox -Owner $own -Text $msg -Title 'Testinstallation' -Mode 'YesNo' -Icon 'Question'))" -eq 'Yes') {
            foreach ($c in $changes) { $set[$c.Field] = $c.Value }
            $taken = $true
        }
    }
    if (-not $changes.Count -and $sum.Proposal -and $sum.Proposal.Available -and $lvl -ne 'Fehler') { Out-Console '  Vorschlag entspricht bereits den Paket-Einstellungen - nichts zu uebernehmen.' 'Info' }
    if (Save-SwSettings $pk $set) { Out-Console "Testergebnis$(if ($taken) { ' und Vorschlaege' }) bei '$($pk.Settings.Name)' gespeichert" 'Success' }
    if ($taken -and -not $Watch.TestUn -and @($changes | Where-Object { $_.Field -eq 'UninstallCmd' }).Count) { Out-Console "Tipp: Testinstallation noch einmal mit 'Deinstallation mittesten' starten." 'Info' }
    if ($script:SwUi) {
        $sw = $script:SwUi
        $cur = if ($sw.Lst.SelectedIndex -ge 0 -and $sw.Lst.SelectedIndex -lt $sw.Pkgs.Count) { $sw.Pkgs[$sw.Lst.SelectedIndex].Id } else { $pk.Id }
        Update-SwWindowList $cur
        if ($shown) { Set-SwSandboxText (@($lines + @($warn | ForEach-Object { "ACHTUNG: $_" })) -join "`r`n") $lvl }
    }
}

# Deinstallation / Status: Menue "gewaehlter Computer" oder "mehrere PCs"
function Show-SwTargetMenu($Button, [string]$Kind) {
    $cm = New-Object System.Windows.Controls.ContextMenu
    $h = "$(Get-TargetComputer)".Trim()
    $m1 = New-Object System.Windows.Controls.MenuItem
    $m1.Header = $(if ($h) { "Gewaehlter Computer ($h)" } else { 'Gewaehlter Computer (keiner gewaehlt)' }); $m1.IsEnabled = [bool]$h; $m1.Tag = $Kind
    $m1.Add_Click({ param($s, $e) Invoke-SwTargetAction "$($s.Tag)" $false })
    $m2 = New-Object System.Windows.Controls.MenuItem
    $m2.Header = 'Mehrere PCs ...'; $m2.Tag = $Kind
    $m2.Add_Click({ param($s, $e) Invoke-SwTargetAction "$($s.Tag)" $true })
    [void]$cm.Items.Add($m1); [void]$cm.Items.Add($m2)
    $cm.PlacementTarget = $Button; $cm.Placement = [System.Windows.Controls.Primitives.PlacementMode]::Bottom
    $cm.IsOpen = $true
}
function Invoke-SwTargetAction([string]$Kind, [bool]$Multi) {
    $sw = $script:SwUi; if (-not $sw) { return }
    $p = Save-SwForm; if (-not $p) { return }
    if ($Kind -eq 'Uninstall' -and -not (Get-SwUninstallItem $p)) {
        [void](Show-HMDialogBox -Owner $sw.Win -Text ("Fuer '$($p.Settings.Name)' ist kein Deinstallationsbefehl hinterlegt.`n`nFeld 'Deinstallation' ausfuellen (z.B. `"C:\Program Files\X\uninstall.exe`" /S) - oder die Testinstallation in der Sandbox mit 'Deinstallation mittesten' ermittelt ihn.") -Title 'Deinstallation' -Mode 'OK' -Icon 'Information')
        return
    }
    if (-not $Multi) {
        $h = "$(Get-TargetComputer)".Trim(); if (-not $h) { return }
        Invoke-SwTargetRun $Kind $p @($h)
        return
    }
    $script:SwPickX = @{ Package = $p; Kind = $Kind }
    Show-HMMultiDialog -PickTitle "$(if ($Kind -eq 'Uninstall') { 'Deinstallieren' } else { 'Status' }): '$($p.Settings.Name)'" -Owner $sw.Win -OnPick {
        param($hosts)
        $pp = $script:SwPickX; if (-not $pp) { return }
        $hosts = @($hosts | Where-Object { $_ } | Sort-Object -Unique)
        if (-not $hosts.Count) { return }
        Invoke-SwTargetRun $pp.Kind $pp.Package $hosts
    }
}
function Invoke-SwTargetRun([string]$Kind, $Package, [string[]]$Hosts) {
    if ($Kind -eq 'Status') { Start-SwPackageStatus -Hosts $Hosts -Package $Package; return }
    $it = Get-SwUninstallItem $Package
    if (-not $it) { return }
    $ziel = if ($Hosts.Count -le 5) { $Hosts -join ', ' } else { "$($Hosts.Count) PCs" }
    $cmd = "$($it.Cmd) $($it.Args)".Trim()
    if (-not (Confirm-Action "Paket '$($Package.Settings.Name)' DEINSTALLIEREN auf: $ziel`n`n  Befehl: $cmd`n`nStill, ohne automatischen Neustart. Fortfahren?" 'Deinstallation')) { return }
    Start-SwPackageUninstall -Hosts $Hosts -Package $Package
}

# Dateien/Ordner uebernehmen (Knopf und Drag&Drop)
function Invoke-SwAddItems([string[]]$Paths) {
    $r = Add-SwItems -Paths $Paths -Dest (Get-SwFolder)
    foreach ($a in $r.Added) { Out-Console "Softwareverteilung: $a hinzugefuegt" 'Success' }
    foreach ($x in $r.Skipped) { Out-Console "Softwareverteilung: nicht uebernommen - $x" 'Warning' }
    if ($r.Skipped.Count -and $script:SwUi) { [void](Show-HMDialogBox -Owner $script:SwUi.Win -Text ("Nicht uebernommen:`n  $($r.Skipped -join "`n  ")") -Title 'Softwareverteilung' -Mode 'OK' -Icon 'Information') }
    Update-SwWindowList $(if ($r.Added.Count) { $r.Added[0] } else { '' })
}

function Set-SwBusy([bool]$On) {
    try { [System.Windows.Input.Mouse]::OverrideCursor = $(if ($On) { [System.Windows.Input.Cursors]::Wait } else { $null }) } catch { }
}

# Neue Version per WinGet holen und ins Paket uebernehmen (Einstellungen bleiben, Sandbox-Test wird ueber die Signatur ungueltig).
# Suche, Versionsabfrage und Download laufen im Hintergrund (Fenster bleibt bedienbar), dazwischen die Rueckfragen.
$script:SwWg = $null
function Set-SwWingetWork([string]$Text) {
    $script:SwWg = if ($Text) { @{ Text = $Text; Started = (Get-Date) } } else { $null }
    Update-SwSandboxButton
}
function Get-SwWingetSeconds { if ($script:SwWg) { return [int]((Get-Date) - $script:SwWg.Started).TotalSeconds }; return 0 }

function Update-SwFromWinget {
    $sw = $script:SwUi; if (-not $sw) { return }
    foreach ($fn in 'Get-HMWingetLatest', 'Save-HMWingetInstaller', 'Find-HMWingetId', 'Invoke-HMWingetAsync', 'ConvertTo-HMAsyncResult') {
        if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) { [void](Show-HMDialogBox -Owner $sw.Win -Text "WinGet-Funktion fehlt ($fn) - HUMig unvollstaendig?" -Title 'WinGet' -Mode 'OK' -Icon 'Warning'); return }
    }
    if ($script:SwWg) { [void](Show-HMDialogBox -Owner $sw.Win -Text ("WinGet arbeitet noch ($($script:SwWg.Text)) - bitte warten.") -Title 'WinGet' -Mode 'OK' -Icon 'Information'); return }
    if ($script:SwSb -and "$($script:SwSb.Phase)" -eq 'Copy') { [void](Show-HMDialogBox -Owner $sw.Win -Text 'Das Paket wird gerade fuer die Sandbox kopiert - bitte warten.' -Title 'WinGet' -Mode 'OK' -Icon 'Information'); return }
    $p = Save-SwForm; if (-not $p) { return }
    $own = $sw.Win
    $id = "$($p.Settings.WingetId)".Trim()
    if ($id) { Start-SwWingetLatest $p $id; return }
    $q0 = if ("$($p.Info.ProductName)".Trim()) { "$($p.Info.ProductName)".Trim() } else { "$($p.Settings.Name)" -replace '\s+v?\d+(\.\d+)+.*$', '' }
    $q = Show-TextInputDialog -Title 'WinGet-ID suchen' -Owner $own -Text $q0 -Label "Fuer dieses Paket ist keine WinGet-ID hinterlegt.`n`nProgrammname fuer die Suche im WinGet-Katalog:"
    if ($null -eq $q -or -not "$q".Trim()) { return }
    $q = "$q".Trim()
    Set-SwWingetWork "Suche '$q'"
    Out-Console "WinGet: suche '$q' ..." 'Info'
    [void](Invoke-HMWingetAsync -Command 'Find-HMWingetId' -Arguments @{ Name = $q } -State @{ Package = $p; Query = $q } -TimeoutSec 300 -OnComplete { param($result, $st) Complete-SwWingetFind $result $st })
}

function Complete-SwWingetFind($Result, $State) {
    $secs = Get-SwWingetSeconds
    Set-SwWingetWork ''
    $r = ConvertTo-HMAsyncResult $Result
    $own = if ($script:SwUi) { $script:SwUi.Win } else { $script:Window }
    if (-not $r.Ok) { Out-Console "WinGet-Suche fehlgeschlagen ($secs s): $($r.Error)" 'Error'; [void](Show-HMDialogBox -Owner $own -Text ("WinGet-Suche fehlgeschlagen:`n$($r.Error)") -Title 'WinGet' -Mode 'OK' -Icon 'Warning'); return }
    $hits = @($r.Value | Where-Object { $_ -and "$($_.Id)" })
    Out-Console "WinGet: $($hits.Count) Treffer fuer '$($State.Query)' ($secs s)" 'Info'
    if (-not $hits.Count) { [void](Show-HMDialogBox -Owner $own -Text ("Im WinGet-Katalog nichts gefunden fuer '$($State.Query)'.") -Title 'WinGet' -Mode 'OK' -Icon 'Information'); return }
    $sel = Show-SwPickList -Title 'WinGet-Paket waehlen' -Owner $own -Hint 'Passendes Paket waehlen (Doppelklick oder OK). Die ID wird im Paket gespeichert.' `
        -Items @($hits | ForEach-Object { [pscustomobject]@{ Title = "$($_.Name)"; Sub = "$($_.Id)   $($_.Version)"; Id = "$($_.Id)" } })
    if (-not $sel -or -not @($sel).Count) { return }
    $id = "$(@($sel)[0])"
    # ID direkt im Paket speichern (das Formular kann inzwischen ein anderes Paket zeigen)
    $pid0 = "$($State.Package.Id)"
    $p = @(Get-SwPackages | Where-Object { $_.Id -eq $pid0 }) | Select-Object -First 1
    if (-not $p) { Out-Console "WinGet: Paket '$pid0' nicht mehr vorhanden" 'Warning'; return }
    $set = ConvertTo-SwSettingsHash $p.Settings
    $set.WingetId = $id
    if (-not (Save-SwSettings $p $set)) { return }
    $p.Settings = [pscustomobject]$set
    $sw = $script:SwUi
    if ($sw -and $sw.Lst.SelectedIndex -ge 0 -and $sw.Lst.SelectedIndex -lt $sw.Pkgs.Count -and $sw.Pkgs[$sw.Lst.SelectedIndex].Id -eq $pid0) { $sw.TxtWinget.Text = $id }
    Start-SwWingetLatest $p $id
}

function Start-SwWingetLatest($Package, [string]$Id) {
    Set-SwWingetWork "Version von '$Id'"
    Out-Console "WinGet: frage neueste Version von '$Id' ab ..." 'Info'
    [void](Invoke-HMWingetAsync -Command 'Get-HMWingetLatest' -Arguments @{ Id = $Id } -State @{ Package = $Package; Id = $Id } -TimeoutSec 300 -OnComplete { param($result, $st) Complete-SwWingetLatest $result $st })
}

function Complete-SwWingetLatest($Result, $State) {
    $secs = Get-SwWingetSeconds
    Set-SwWingetWork ''
    $r = ConvertTo-HMAsyncResult $Result
    $own = if ($script:SwUi) { $script:SwUi.Win } else { $script:Window }
    $p = $State.Package; $id = $State.Id
    if (-not $r.Ok) { Out-Console "WinGet ($secs s): $($r.Error)" 'Error'; [void](Show-HMDialogBox -Owner $own -Text ("WinGet: $($r.Error)") -Title 'WinGet' -Mode 'OK' -Icon 'Warning'); return }
    $lat = @($r.Value) | Select-Object -First 1
    $lv = "$($lat.Version)".Trim()
    if (-not $lv) { [void](Show-HMDialogBox -Owner $own -Text "WinGet: keine Version fuer '$id' gefunden." -Title 'WinGet' -Mode 'OK' -Icon 'Information'); return }
    $cv = "$($p.Info.Version)".Trim(); if (-not $cv -and "$($p.Settings.Name)" -match '\d+(\.\d+)+') { $cv = $Matches[0] }
    $cmp = Compare-SwVersion $lv $cv
    $q = if ($null -ne $cmp -and $cmp -le 0) { "WinGet '$id': aktuell $lv - das Paket hat bereits $cv.`n`nTrotzdem herunterladen?" } else { "WinGet '$id': neue Version $lv (Paket: $(if ($cv) { $cv } else { 'unbekannt' })).`n`nHerunterladen und ins Paket uebernehmen?" }
    if ("$((Show-HMDialogBox -Owner $own -Text $q -Title 'WinGet' -Mode 'YesNo' -Icon 'Question'))" -ne 'Yes') { return }
    $mode = 'dir'
    if (-not $p.IsDir) {
        $a = "$((Show-HMDialogBox -Owner $own -Text ("Einzeldatei-Paket '$($p.Id)' - wohin mit der neuen Version?`n`nJa = als neue Datei in den Ordner Softwareverteilung (das alte Paket bleibt)`nNein = in einen neuen Unterordner (Ordner-Paket)`nAbbrechen = nichts tun") -Title 'WinGet' -Mode 'YesNoCancel' -Icon 'Question'))"
        if ($a -eq 'Yes') { $mode = 'file' } elseif ($a -eq 'No') { $mode = 'sub' } else { return }
    }
    # MSI-Paket: wieder ein MSI holen (sonst wechselt die Erkennung per ProductCode ins Leere)
    $preferMsi = ("$($p.Type)" -eq 'MSI' -or [IO.Path]::GetExtension("$($p.Settings.Installer)") -ieq '.msi')
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('HUMig_wg_' + [guid]::NewGuid().ToString('N'))
    Set-SwWingetWork "Download '$id' $lv"
    Out-Console "WinGet: lade $id $lv$(if ($preferMsi) { ' (MSI bevorzugt)' }) ..." 'Info'
    $st = @{ Package = $p; Id = $id; Latest = $lv; Current = $cv; Mode = $mode; Tmp = $tmp }
    [void](Invoke-HMWingetAsync -Command 'Save-HMWingetInstaller' -Arguments @{ Id = $id; DestDir = $tmp; PreferMsi = [bool]$preferMsi } -State $st -TimeoutSec 1800 -OnComplete { param($result, $st) Complete-SwWingetDownload $result $st })
}

# Neue Paket-Einstellungen nach dem Download (ohne UI, testbar): Rueckgabe @{ Settings; Messages = @(@{ Text; Level }) }
function Get-SwWingetSettings($Settings, [string]$FileName, [string]$Silent, [string]$WingetId, [string]$OldVersion, [string]$NewVersion, $NewInfo) {
    $set = ConvertTo-SwSettingsHash $Settings
    $msgs = New-Object System.Collections.Generic.List[object]
    $set.Installer = $FileName
    if ("$Silent".Trim()) { $set.Arguments = "$Silent".Trim() }
    $set.WingetId = $WingetId
    $cv = "$OldVersion".Trim()
    # alte Version nur als ganze Zahl ersetzen (nicht "1.2" in "11.2")
    $vre = if ($cv) { '(?<![\d.])' + [regex]::Escape($cv) + '(?![\d])' } else { '' }
    if ($cv -and "$($set.Name)".Contains($cv)) { $set.Name = "$($set.Name)".Replace($cv, $NewVersion) }
    $dn = "$($set.DetectName)".Trim()
    if ($dn) {
        if ($vre -and $dn -match $vre) {
            $set.DetectName = [regex]::Replace($dn, $vre, [System.Management.Automation.WildcardPattern]::Escape($NewVersion).Replace('$', '$$'))
            $msgs.Add(@{ Text = "Erkennung (Name): $dn -> $($set.DetectName)"; Level = 'Info' })
        } elseif ($dn -match '\d+\.\d+') {
            $msgs.Add(@{ Text = "Erkennung (Name) '$dn' enthaelt eine Versionsnummer, die nicht zur alten Version passt - bitte pruefen (findet die neue Version sonst evtl. nicht)."; Level = 'Warning' })
        }
    }
    $nv = ConvertTo-SwVersion $NewVersion
    if ("$($set.MinVersion)".Trim() -and $nv) { $set.MinVersion = "$nv" }
    $oc = "$($set.DetectProductCode)".Trim()
    $newCode = if ($NewInfo) { "$($NewInfo.ProductCode)".Trim() } else { '' }
    if ($oc -and $newCode) {
        $set.DetectProductCode = $newCode
        if ("$($set.UninstallCmd)".Contains($oc)) { $set.UninstallCmd = "$($set.UninstallCmd)".Replace($oc, $newCode) }
    } elseif ($oc) {
        # neuer Installer ohne ProductCode (z. B. EXE): alter Code wuerde die neue Version nie erkennen
        $set.DetectProductCode = ''
        $msgs.Add(@{ Text = "Erkennung (ProductCode) $oc geleert - der neue Installer hat keinen ProductCode."; Level = 'Warning' })
        if ("$($set.UninstallCmd)".IndexOf($oc, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $msgs.Add(@{ Text = "Deinstallation '$($set.UninstallCmd)' geleert (enthielt den alten ProductCode) - Testinstallation mit 'Deinstallation mittesten' ermittelt den neuen Befehl."; Level = 'Warning' })
            $set.UninstallCmd = ''
        }
        if (-not ("$($set.DetectName)".Trim() -or "$($set.DetectKey)".Trim() -or "$($set.DetectFile)".Trim())) {
            $msgs.Add(@{ Text = 'Paket hat jetzt keine Erkennung mehr - Testinstallation in der Sandbox schlaegt eine vor.'; Level = 'Warning' })
        }
    }
    return [pscustomobject]@{ Settings = $set; Messages = $msgs.ToArray() }
}

function Complete-SwWingetDownload($Result, $State) {
    $secs = Get-SwWingetSeconds
    Set-SwWingetWork ''
    $r = ConvertTo-HMAsyncResult $Result
    $own = if ($script:SwUi) { $script:SwUi.Win } else { $script:Window }
    $p = $State.Package; $id = $State.Id; $lv = $State.Latest; $cv = $State.Current; $mode = $State.Mode; $tmp = $State.Tmp
    try {
        if (-not $r.Ok) { throw $r.Error }
        $dl = @($r.Value) | Select-Object -First 1
        $f = "$($dl.File)"; if ($f -and -not [IO.Path]::IsPathRooted($f)) { $f = Join-Path $tmp $f }
        if (-not $f -or -not (Test-Path -LiteralPath $f)) { throw 'Download lieferte keine Datei' }
        $fn = [IO.Path]::GetFileName($f)
        Out-Console "WinGet: $fn heruntergeladen ($([Math]::Round((Get-Item -LiteralPath $f).Length / 1MB, 1)) MB, $secs s)" 'Info'
        if ([IO.Path]::GetExtension($fn).ToLower() -notin '.msi', '.exe', '.msp') { throw "Installer-Typ $([IO.Path]::GetExtension($fn)) wird nicht unterstuetzt (nur .msi/.exe/.msp)" }
        $newVer = if ("$($dl.Version)".Trim()) { "$($dl.Version)".Trim() } else { $lv }
        $root = Get-SwFolder
        switch ($mode) {
            'file' {
                $dest = Join-Path $root $fn; $cfgPath = "$dest.hu.json"; $newId = $fn
                if ((Test-Path -LiteralPath $dest) -and $dest -ine $p.SrcPath) {
                    if ("$((Show-HMDialogBox -Owner $own -Text "'$fn' gibt es schon in der Softwareverteilung. Ueberschreiben?" -Title 'WinGet' -Mode 'YesNo' -Icon 'Warning'))" -ne 'Yes') { return }
                }
            }
            'sub' {
                $base = ("$($p.Settings.Name)" -replace '\s+v?\d+(\.\d+)+.*$', '').Trim(); if (-not $base) { $base = [IO.Path]::GetFileNameWithoutExtension($fn) }
                $sub = Get-SwSafeId "$base $newVer"
                $dir = Join-Path $root $sub
                if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
                $dest = Join-Path $dir $fn; $cfgPath = Join-Path $dir 'hu-package.json'; $newId = "$sub\"
            }
            default { $dest = Join-Path $p.SrcPath $fn; $cfgPath = $p.ConfigPath; $newId = $p.Id }
        }
        Set-SwBusy $true
        Copy-Item -LiteralPath $f -Destination $dest -Force -ErrorAction Stop
        $oldInst = "$($p.Settings.Installer)"
        $ni = Get-SwInstallerInfo $dest
        $res = Get-SwWingetSettings -Settings $p.Settings -FileName $fn -Silent "$($dl.Silent)" -WingetId $id -OldVersion $cv -NewVersion $newVer -NewInfo $ni
        $set = $res.Settings
        foreach ($m in @($res.Messages)) { Out-Console "WinGet: $($m.Text)" "$($m.Level)" }
        if (-not (Save-SwSettings ([pscustomobject]@{ ConfigPath = $cfgPath }) $set)) { return }
        Out-Console "WinGet: $fn ($newVer) uebernommen -> Paket $newId" 'Success'
        if ($set.Sandbox) { Out-Console 'Hinweis: der Sandbox-Test gilt fuer die neue Version nicht mehr - bitte erneut testen.' 'Warning' }
        Set-SwBusy $false
        if ($mode -eq 'dir' -and $oldInst -and $oldInst -ine $fn) {
            $old = Join-Path $p.SrcPath $oldInst
            if ((Test-Path -LiteralPath $old) -and "$((Show-HMDialogBox -Owner $own -Text "Alten Installer '$oldInst' aus dem Paketordner loeschen?`n(Sonst wird er weiterhin mit auf die PCs kopiert.)" -Title 'WinGet' -Mode 'YesNo' -Icon 'Question'))" -eq 'Yes') {
                try { Remove-Item -LiteralPath $old -Force -ErrorAction Stop; Out-Console "WinGet: alter Installer $oldInst geloescht" 'Info' } catch { Out-Console "Nicht geloescht: $($_.Exception.Message)" 'Warning' }
            }
        }
        $script:SwInfoCache = @{}
        if ($script:SwUi) { Update-SwWindowList $newId }
    } catch {
        Set-SwBusy $false
        Out-Console "WinGet: $($_.Exception.Message)" 'Error'
        [void](Show-HMDialogBox -Owner $own -Text ("WinGet: $($_.Exception.Message)") -Title 'WinGet' -Mode 'OK' -Icon 'Warning')
    } finally {
        Set-SwBusy $false
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Show-SoftwareWindow {
    if ($script:SwUi -and $script:SwUi.Win -and $script:SwUi.Win.IsVisible) { [void]$script:SwUi.Win.Activate(); Update-SwWindowList; return }
    $dir = Get-SwFolder
    try { if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null } } catch { Out-Console "Ordner nicht anlegbar: $dir" 'Error' }
    $sx = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="HUMig - Softwareverteilung" Height="840" Width="1200" MinHeight="600" MinWidth="900"
        WindowStartupLocation="CenterOwner" Background="#FF1E1E2E">
  <Window.Resources>
    <Style TargetType="TextBlock"><Setter Property="Foreground" Value="#FFA6ADC8"/><Setter Property="VerticalAlignment" Value="Center"/></Style>
    <Style TargetType="TextBox"><Setter Property="Background" Value="#FF313244"/><Setter Property="Foreground" Value="#FFCDD6F4"/><Setter Property="BorderBrush" Value="#FF585B70"/><Setter Property="CaretBrush" Value="#FFCDD6F4"/><Setter Property="Padding" Value="4,2"/><Setter Property="Margin" Value="0,2,0,2"/></Style>
    <Style TargetType="Button"><Setter Property="Height" Value="28"/><Setter Property="Margin" Value="0,0,6,0"/><Setter Property="Cursor" Value="Hand"/><Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Foreground" Value="#FF1E1E2E"/><Setter Property="Padding" Value="10,0"/></Style>
    <Style TargetType="CheckBox"><Setter Property="Foreground" Value="#FFCDD6F4"/><Setter Property="VerticalAlignment" Value="Center"/></Style>
  </Window.Resources>
  <DockPanel Margin="8">
    <DockPanel DockPanel.Dock="Top" Margin="0,0,0,6">
      <Image x:Name="imgLogo" DockPanel.Dock="Left" Width="30" Height="30" Margin="0,0,8,0" RenderOptions.BitmapScalingMode="HighQuality"/>
      <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
        <Button x:Name="btnAdd" Content="Datei hinzufuegen" Background="#FFA6E3A1" ToolTip="Setup-Dateien (MSI/EXE/MSP) in die Softwareverteilung kopieren - Dateien oder ganze Ordner koennen auch auf die Paketliste gezogen werden. Ziehen aus dem Explorer geht nur, wenn der Explorer ebenfalls als Administrator laeuft (Windows-Sperre) - sonst 'Datei hinzufuegen'"/>
        <Button x:Name="btnOpen" Content="Ordner oeffnen" Background="#FF89B4FA"/>
        <Button x:Name="btnReload" Content="Aktualisieren" Background="#FF89B4FA" Margin="0"/>
      </StackPanel>
      <TextBlock x:Name="lblFolder" TextTrimming="CharacterEllipsis"/>
    </DockPanel>
    <Border DockPanel.Dock="Bottom" Background="#FF181825" Padding="6" Margin="0,6,0,0">
      <DockPanel>
        <CheckBox x:Name="chkForce" DockPanel.Dock="Right" Content="auch wenn schon installiert" Margin="8,0,0,0"/>
        <WrapPanel Orientation="Horizontal">
          <TextBlock Text="Installieren auf:" Margin="0,0,8,0" Foreground="#FFF9E2AF"/>
          <Button x:Name="btnClient" Content="Gewaehlten Computer" Background="#FFA6E3A1" Margin="0,2,6,2"/>
          <Button x:Name="btnMultiSel" Content="Mehrere PCs ..." Background="#FFA6E3A1" Margin="0,2,12,2" ToolTip="PCs aus dem Active Directory anhaken (OU, Filter) oder Namen eintragen - installiert wird parallel (bis zu 8 gleichzeitig)"/>
          <Button x:Name="btnUninst" Content="Deinstallieren ..." Background="#FFF38BA8" Margin="0,2,6,2" ToolTip="Paket auf dem gewaehlten oder mehreren PCs entfernen (Feld 'Deinstallation' bzw. MSI-ProductCode)"/>
          <Button x:Name="btnStatus" Content="Status auf PCs ..." Background="#FF89B4FA" Margin="0,2,6,2" ToolTip="Pruefen, ob das Paket installiert ist (gleiche Erkennung wie bei der Verteilung) - Ergebnis als Tabelle"/>
          <TextBlock x:Name="lblTarget" Margin="8,0,0,0"/>
        </WrapPanel>
      </DockPanel>
    </Border>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="340"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <ListBox x:Name="lstPkg" Grid.Column="0" Background="#FF313244" Foreground="#FFCDD6F4" BorderBrush="#FF585B70" Margin="0,0,8,0" FontSize="12" AllowDrop="True"/>
      <Grid Grid.Column="1">
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*" MinHeight="60"/></Grid.RowDefinitions>
        <Grid Grid.Row="0">
          <Grid.ColumnDefinitions><ColumnDefinition Width="170"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
          <Grid.RowDefinitions><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
          <TextBlock Grid.Row="0" Text="Name:"/>                    <TextBox x:Name="txtName" Grid.Row="0" Grid.Column="1"/>
          <TextBlock Grid.Row="1" Text="Installer:"/>               <ComboBox x:Name="cmbInst" Grid.Row="1" Grid.Column="1" Margin="0,2,0,2"/>
          <TextBlock Grid.Row="2" Text="Typ:"/>                     <TextBlock x:Name="lblType" Grid.Row="2" Grid.Column="1" Foreground="#FFF9E2AF"/>
          <TextBlock Grid.Row="3" Text="Parameter:"/>               <ComboBox x:Name="cmbArgs" Grid.Row="3" Grid.Column="1" IsEditable="True" Margin="0,2,0,2" FontFamily="Consolas" ToolTip="Silent-Parameter. MSI: Eigenschaften anhaengen, z.B. /qn /norestart INSTALLDIR=&quot;C:\Programme\X&quot; - msiexec /i und das Log werden automatisch ergaenzt"/>
          <TextBlock Grid.Row="4" Text="Erkennung (Name):"/>        <TextBox x:Name="txtDetect" Grid.Row="4" Grid.Column="1" ToolTip="DisplayName in 'Programme und Features', Platzhalter * erlaubt (z.B. 7-Zip*). Installiert = wird uebersprungen, danach wird geprueft ob es da ist. Leer = keine Pruefung"/>
          <TextBlock Grid.Row="5" Text="Erkennung (ProductCode):"/> <TextBox x:Name="txtCode" Grid.Row="5" Grid.Column="1" FontFamily="Consolas" ToolTip="MSI-ProductCode {GUID} - wenn gesetzt, wird NUR danach erkannt (exakt diese Version). Leer = Erkennung per Name"/>
          <TextBlock Grid.Row="6" Text="Erkennung (Schluessel):"/>  <TextBox x:Name="txtDetKey" Grid.Row="6" Grid.Column="1" FontFamily="Consolas" ToolTip="Registry-Schluessel, der nach der Installation existiert, z.B. HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\7-Zip - mit Mindestversion wird DisplayVersion verglichen. HKCU:\... prueft die Profile der angemeldeten Benutzer (Benutzer-Installation). Leer = nicht pruefen"/>
          <TextBlock Grid.Row="7" Text="Erkennung (Datei/Ordner):"/> <TextBox x:Name="txtDetFile" Grid.Row="7" Grid.Column="1" FontFamily="Consolas" ToolTip="Datei oder Ordner, der nach der Installation existiert, z.B. %ProgramFiles%\7-Zip\7z.exe (Umgebungsvariablen erlaubt). Alle ausgefuellten Erkennungen muessen zutreffen. Leer = nicht pruefen"/>
          <TextBlock Grid.Row="8" Text="Mindestversion:"/>
          <StackPanel Grid.Row="8" Grid.Column="1" Orientation="Horizontal">
            <TextBox x:Name="txtMinVer" Width="140" ToolTip="Mit Erkennung per Name/Schluessel: aeltere installierte Version gilt als NICHT installiert -> wird aktualisiert"/>
            <TextBlock Text="Erfolgs-ExitCodes:" Margin="14,0,6,0"/>
            <TextBox x:Name="txtCodes" Width="110" ToolTip="Komma-getrennt, z.B. 0 oder 0,1 - 3010/1641 gelten immer als Erfolg mit Neustart"/>
            <TextBlock Text="Timeout (Minuten):" Margin="14,0,6,0"/>
            <TextBox x:Name="txtTimeout" Width="60"/>
          </StackPanel>
          <TextBlock Grid.Row="9" Text="Deinstallation:"/>          <TextBox x:Name="txtUninst" Grid.Row="9" Grid.Column="1" FontFamily="Consolas" ToolTip="Befehl fuer die stille Deinstallation, z.B. &quot;%ProgramFiles%\X\uninstall.exe&quot; /S oder msiexec /x {GUID} /qn. Leer + MSI-ProductCode = msiexec /x {ProductCode} /qn"/>
          <TextBlock Grid.Row="10" Text="Abhaengigkeiten:"/>
          <DockPanel Grid.Row="10" Grid.Column="1" Margin="0,2,0,2">
            <CheckBox x:Name="chkNoDesk" DockPanel.Dock="Right" Content="Keine Desktop-Verknuepfung" Margin="10,0,0,0" ToolTip="Nach der Installation 30 Sekunden lang neu angelegte Verknuepfungen auf dem Desktop (Oeffentlich, Standardprofil, Admin) entfernen"/>
            <Button x:Name="btnDeps" DockPanel.Dock="Right" Content="Auswaehlen ..." Background="#FFCBA6F7" Height="24" Margin="6,0,0,0" ToolTip="Pakete, die vorher auf denselben PCs installiert werden (vorhandene werden uebersprungen)"/>
            <TextBlock x:Name="lblDeps" Text="keine" Foreground="#FFCDD6F4" TextTrimming="CharacterEllipsis"/>
          </DockPanel>
          <TextBlock Grid.Row="11" Text="WinGet-ID:"/>              <TextBox x:Name="txtWinget" Grid.Row="11" Grid.Column="1" Width="300" HorizontalAlignment="Left" FontFamily="Consolas" ToolTip="Paket-ID im WinGet-Katalog (z.B. 7zip.7zip) - fuer 'Neue Version (WinGet)'. Leer = beim ersten Mal suchen"/>
          <TextBlock Grid.Row="12" Text="Notiz:"/>                  <TextBox x:Name="txtNote" Grid.Row="12" Grid.Column="1"/>
        </Grid>
        <WrapPanel Grid.Row="1" Orientation="Horizontal" Margin="0,6,0,4">
          <Button x:Name="btnSave" Content="Speichern" Background="#FFF9E2AF" Margin="0,2,6,2"/>
          <Button x:Name="btnSuggest" Content="Standard vorschlagen" Background="#FFFAB387" Margin="0,2,12,2"/>
          <Button x:Name="btnSandbox" Content="Testinstallation in der Sandbox" Background="#FFCBA6F7" Margin="0,2,6,2" ToolTip="Paket in der Windows Sandbox installieren (gleicher Ablauf wie bei der Verteilung) - ermittelt Erkennung und Deinstallation"/>
          <CheckBox x:Name="chkSbUninst" Content="Deinstallation mittesten" IsChecked="True" Margin="0,2,10,2"/>
          <CheckBox x:Name="chkSbKeep" Content="Sandbox offen lassen" Margin="0,2,12,2"/>
          <Button x:Name="btnWinget" Content="Neue Version (WinGet) ..." Background="#FF94E2D5" Margin="0,2,0,2" ToolTip="Neueste Version aus dem WinGet-Katalog herunterladen und ins Paket uebernehmen (Einstellungen bleiben)"/>
        </WrapPanel>
        <Border Grid.Row="2" Background="#FF181825" BorderBrush="#FF585B70" BorderThickness="1" Margin="0,0,0,6" Padding="2">
          <TextBox x:Name="txtSandbox" IsReadOnly="True" Background="Transparent" BorderThickness="0" FontFamily="Consolas" FontSize="11" TextWrapping="Wrap" Height="86" VerticalScrollBarVisibility="Auto" Margin="0"/>
        </Border>
        <TextBox x:Name="txtInfo" Grid.Row="3" IsReadOnly="True" FontFamily="Consolas" FontSize="11" TextWrapping="NoWrap" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"/>
      </Grid>
    </Grid>
  </DockPanel>
</Window>
"@
    $w = [System.Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new(([xml]$sx)))
    if ($script:AppIcon) { $w.Icon = $script:AppIcon }
    if ($script:LogoImage) { $w.FindName('imgLogo').Source = $script:LogoImage }
    $script:SwUi = @{
        Win = $w; Pkgs = @(); Loading = $false; Deps = @()
        Lst = $w.FindName('lstPkg'); LblFolder = $w.FindName('lblFolder'); LblType = $w.FindName('lblType'); LblTarget = $w.FindName('lblTarget')
        TxtName = $w.FindName('txtName'); CmbInst = $w.FindName('cmbInst'); CmbArgs = $w.FindName('cmbArgs')
        TxtDetect = $w.FindName('txtDetect'); TxtCode = $w.FindName('txtCode'); TxtMinVer = $w.FindName('txtMinVer'); TxtCodes = $w.FindName('txtCodes')
        TxtTimeout = $w.FindName('txtTimeout'); TxtNote = $w.FindName('txtNote'); TxtInfo = $w.FindName('txtInfo'); ChkForce = $w.FindName('chkForce')
        TxtUninst = $w.FindName('txtUninst'); TxtDetKey = $w.FindName('txtDetKey'); TxtDetFile = $w.FindName('txtDetFile'); TxtWinget = $w.FindName('txtWinget')
        ChkNoDesk = $w.FindName('chkNoDesk'); LblDeps = $w.FindName('lblDeps'); TxtSandbox = $w.FindName('txtSandbox')
        BtnSandbox = $w.FindName('btnSandbox'); ChkSbUninst = $w.FindName('chkSbUninst'); ChkSbKeep = $w.FindName('chkSbKeep'); BtnWinget = $w.FindName('btnWinget')
    }
    $script:SwUi.Lst.ToolTip = "Kennzeichen Sandbox-Test: $([char]0x2713) OK   ! mit Hinweisen   $([char]0x2717) Fehler   $([char]0x25CB) ungetestet   $([char]0x21BB) Test veraltet (Paket geaendert)`n* = Einstellungen noch nicht gespeichert`nSetup-Dateien oder Ordner hierher ziehen = hinzufuegen`n(Ziehen aus dem Explorer geht nur, wenn der Explorer ebenfalls als Administrator laeuft (Windows-Sperre) - sonst 'Datei hinzufuegen')"
    # Handler ohne GetNewClosure -> Skript-Funktionen sichtbar; Zustand in $script:SwUi
    $script:SwUi.Lst.Add_SelectionChanged({
        $sw = $script:SwUi
        if ($sw.Loading) { return }
        $i = $sw.Lst.SelectedIndex
        if ($i -ge 0 -and $i -lt $sw.Pkgs.Count) { Show-SwPackageDetails $sw.Pkgs[$i] }
    })
    # Setup-Dateien/Ordner auf die Paketliste ziehen = hinzufuegen
    $script:SwUi.Lst.Add_DragOver({ param($s, $e) $e.Effects = $(if (@(Get-SwDropPaths $e.Data).Count) { [System.Windows.DragDropEffects]::Copy } else { [System.Windows.DragDropEffects]::None }); $e.Handled = $true })
    $script:SwUi.Lst.Add_Drop({
        param($s, $e)
        $paths = @(Get-SwDropPaths $e.Data)
        $e.Handled = $true
        if ($paths.Count) { Invoke-SwAddItems $paths }
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
        Invoke-SwAddItems @($d.FileNames)
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
    $w.FindName('btnDeps').Add_Click({ Select-SwDependencies })
    $w.FindName('btnSandbox').Add_Click({ Start-SwSandboxTest })
    $w.FindName('btnWinget').Add_Click({ Update-SwFromWinget })
    $w.FindName('btnUninst').Add_Click({ param($s, $e) Show-SwTargetMenu $s 'Uninstall' })
    $w.FindName('btnStatus').Add_Click({ param($s, $e) Show-SwTargetMenu $s 'Status' })
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
    $w.Add_Activated({ if ($script:SwUi) { $script:SwUi.LblTarget.Text = "Gewaehlter Computer: $(Get-TargetComputer)"; Update-SwSandboxButton } })
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
    # Eintraege: Name, Key, Method (MSI / Still (Hersteller) / EXE / Cmd), Args, Cmd (nur Cmd), Code (MSI-ProductCode, wenn Key leer)
    param([Alias('ArgsJson')][string]$ItemsJson, [int]$TimeoutMin)
    $ErrorActionPreference = 'SilentlyContinue'
    if ($TimeoutMin -lt 1) { $TimeoutMin = 10 }
    function Split-HUCmd([string]$s) {
        $s = [Environment]::ExpandEnvironmentVariables("$s".Trim())
        if ($s -match '^"([^"]+)"\s*(.*)$') { return @($Matches[1], $Matches[2]) }
        if ($s -match '^(.+?\.exe)\s*(.*)$') { return @($Matches[1], $Matches[2]) }
        return @($s, '')
    }
    # eigener Deinstallationsbefehl des Pakets: msiexec immer aus System32, sonst Programm ggf. ueber PATH suchen
    function Resolve-HUUninstCmd([string]$s) {
        $s = [Environment]::ExpandEnvironmentVariables("$s".Trim())
        if ($s -match '^(?i)"?(?:[A-Z]:\\[^"]*\\)?msiexec(?:\.exe)?"?(?:\s+(.*))?$') { return @((Join-Path $env:SystemRoot 'System32\msiexec.exe'), "$($Matches[1])".Trim()) }
        $c = Split-HUCmd $s
        if ($c[0] -and -not $c[1] -and $c[0] -notmatch '\.exe$' -and $c[0] -match '^(\S+)\s+(.*)$') { $c = @($Matches[1], $Matches[2]) }
        if ($c[0] -and -not [IO.Path]::IsPathRooted($c[0])) {
            $g = Get-Command $c[0] -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($g) { $c = @($g.Path, $c[1]) }
        }
        return $c
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
            $key = "$($it.Key)".Trim()
            # nur ProductCode bekannt -> Eintrag in HKLM (64/32 Bit) suchen
            if (-not $key -and "$($it.Code)" -match '^\{[0-9A-Fa-f-]{36}\}$') {
                foreach ($b in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall') { if (Test-Path -LiteralPath "$b\$($it.Code)") { $key = "$b\$($it.Code)"; break } }
                if (-not $key) { "RES:$name|OK|war bereits entfernt (ProductCode $($it.Code) nicht gefunden)"; continue }
            }
            $reg = $null
            if ($key) {
                $reg = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
                if (-not $reg) { "RES:$name|OK|war bereits entfernt"; continue }
            } elseif ("$($it.Method)" -ne 'Cmd') { throw 'kein Registry-Schluessel angegeben' }
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
                'Cmd' {
                    $c = Resolve-HUUninstCmd "$($it.Cmd)"; $file = $c[0]; $argLine = ("$($c[1]) $($it.Args)").Trim()
                    if (-not $file) { throw 'kein Deinstallationsbefehl hinterlegt' }
                    if ($file -like '*\msiexec.exe' -and $argLine -notmatch '(?i)(^|\s)/l') {
                        $safe = ($name -replace '[^\w\-\.]', '_'); if ($safe.Length -gt 40) { $safe = $safe.Substring(0, 40) }
                        $log = Join-Path $env:SystemRoot ("Temp\HU_SWX_{0}_{1}.log" -f $safe, (Get-Date -Format 'yyyyMMdd-HHmmss'))
                        $argLine = "$argLine /l*v `"$log`"".Trim()
                    }
                }
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
            # Warten bis Eintrag weg ist bzw. keine Deinstaller-Unterprozesse mehr laufen (ohne Schluessel: nur Unterprozesse)
            $gone = if ($key) { -not (Test-Path -LiteralPath $key) } else { $false }
            while (-not $gone -and "$($it.Method)" -ne 'MSI' -and $sw.ElapsedMilliseconds -lt $limitMs) {
                if ($key -and -not (Test-Path -LiteralPath $key)) { $gone = $true; break }
                if ((Get-HUUninstProcs $start $exeDir).Count -eq 0 -and $sw.ElapsedMilliseconds -gt 15000) { break }
                Start-Sleep -Seconds 2
            }
            if (-not $gone -and $sw.ElapsedMilliseconds -ge $limitMs) {
                foreach ($x in (Get-HUUninstProcs $start $exeDir)) { try { Stop-Process -Id $x.ProcessId -Force } catch { } }
                "RES:$name|FEHLER|Timeout nach $TimeoutMin min (Unterprozesse liefen noch - wartet auf Eingabe?)"; continue
            }
            $dur = "$(if ($sw.Elapsed.TotalSeconds -lt 60) { '{0} s' -f [int]$sw.Elapsed.TotalSeconds } else { '{0} min {1} s' -f [int][Math]::Floor($sw.Elapsed.TotalMinutes), $sw.Elapsed.Seconds })"
            $reboot = ($rc -eq 3010 -or $rc -eq 1641)
            if ($gone) { "RES:$name|OK|entfernt (ExitCode $rc, $dur)$(if ($reboot) { ' - NEUSTART erforderlich' })"; continue }
            if ($rc -eq 1605) { "RES:$name|OK|war laut Windows Installer nicht (mehr) installiert"; continue }
            if ($reboot) { "RES:$name|OK|ExitCode $rc - wird nach NEUSTART entfernt ($dur)"; continue }
            if (-not $key -and $rc -eq 0) { "RES:$name|OK|Deinstallationsbefehl ausgefuehrt (ExitCode 0, $dur)"; continue }
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
    if ($noCmd.Count) { [void](Show-HMDialogBox -Owner $Win -Text ("Ohne Deinstallationsbefehl (werden uebersprungen):`n  " + ($noCmd -join "`n  ")) -Title 'Deinstallation' -Mode 'OK' -Icon 'Information') }
    if ($items.Count -eq 0) { return }
    $lines = foreach ($i in $items) {
        $c = switch ($i.Method) { 'MSI' { 'msiexec /x (still)' } 'EXE' { "$($i.Cmd) $($i.Args)".Trim() } default { "$($i.Cmd)" } }
        if ($c.Length -gt 110) { $c = $c.Substring(0, 107) + '...' }
        "  - $($i.Name)`n      $c"
    }
    $msg = "Auf $h deinstallieren ($($items.Count)):`n`n$($lines -join "`n")`n`nNacheinander, still, ohne automatischen Neustart. Fortfahren?"
    if ("$((Show-HMDialogBox -Owner $Win -Text $msg -Title 'Software deinstallieren' -Mode 'YesNo' -Icon 'Warning'))" -ne 'Yes') { return }

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
