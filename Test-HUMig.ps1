#Requires -Version 5.1
<#
.SYNOPSIS
    Selbsttest fuer HUMig (ohne Adminrechte, aendert nichts am System).
.DESCRIPTION
    Prueft: PowerShell-Syntax aller Skripte, XAML-Fenster, Konfigurationsdateien und Modul-Katalog,
    Engine-Hilfsfunktionen und eine echte Robocopy-Test-Kopie im TEMP-Ordner (Backup + Restore eines Testordners).
    Ergebnis: Test-HUMig.result.txt im Tool-Ordner.
.NOTES
    Aufruf: powershell -NoProfile -ExecutionPolicy Bypass -File .\Test-HUMig.ps1
    Zielmaschine: jeder Windows-PC mit HUMig-Ordner.
#>
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$out = New-Object System.Collections.Generic.List[string]
$fail = 0
function T([string]$Name, [scriptblock]$Test) {
    try {
        $r = & $Test
        if ($r -eq $false) { $script:fail++; $script:out.Add("FAIL  $Name") } else { $script:out.Add("OK    $Name$(if ($r -and $r -ne $true) { "  ($r)" })") }
    } catch { $script:fail++; $script:out.Add("FAIL  $Name : $($_.Exception.Message)") }
}

$out.Add("HUMig Selbsttest $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - PowerShell $($PSVersionTable.PSVersion) - $([Environment]::OSVersion.VersionString)")

# 1. Syntax
foreach ($f in @(Get-ChildItem -LiteralPath $root -Recurse -Filter *.ps1 | Where-Object { $_.FullName -notmatch '\\(BACKUPS|BIN)\\' })) {
    T "Syntax $($f.Name)" {
        $e = $null; $t = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$t, [ref]$e)
        if ($e.Count) { throw (($e | Select-Object -First 3 | ForEach-Object { "Zeile $($_.Extent.StartLineNumber): $($_.Message)" }) -join ' | ') }
        $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
        if (-not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) { throw 'kein UTF-8-BOM (Umlaute in PowerShell 5.1)' }
        $true
    }
}

# 2. XAML
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
T 'XAML MainWindow laden' {
    [xml]$x = Get-Content (Join-Path $root 'XAML\MainWindow.xaml') -Raw -Encoding UTF8
    $w = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $x))
    $need = 'cmbComputer', 'cmbUser', 'btnBackup', 'btnRestore', 'dgBackups', 'rtbConsole', 'pnlBackupModules', 'pnlRestoreModules', 'imgLogo', 'pbMain',
        'lblSizeTotal', 'lstExclude', 'btnBigFiles', 'chkIncremental', 'chkSpaceCheck', 'chkVerify', 'chkOneDriveLocal', 'btnBitLocker', 'btnReport', 'chkRestoreOneDrive', 'pnlToolsComputer', 'pnlToolsProfile', 'pnlToolsDiag',
        'chkCatalog', 'btnVerifyBackup', 'btnCompare', 'btnOverview', 'chkKeepNewer', 'btnRestorePreview', 'btnChecklist', 'pnlSchool', 'cmbSchool', 'btnApps', 'btnReinstall', 'btnADDevices', 'btnBackupSchedule', 'lblBackupSchedule'
    $miss = @($need | Where-Object { -not $w.FindName($_) })
    if ($miss.Count) { throw "fehlt: $($miss -join ', ')" }
    $true
}
T 'XAML Einstellungsfenster laden' {
    [xml]$x = Get-Content (Join-Path $root 'XAML\MainWindow.xaml') -Raw -Encoding UTF8
    $main = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $x))
    [xml]$y = Get-Content (Join-Path $root 'XAML\SettingsWindow.xaml') -Raw -Encoding UTF8
    $w = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $y))
    $w.Resources.MergedDictionaries.Add($main.Resources)
    $need = 'txtRoot', 'cmbThreads', 'dgModules', 'dgLinks', 'txtExPF', 'btnSave', 'btnNmAdd', 'btnLauncher', 'txtRetentionKeep', 'chkOverviewAuto', 'txtChecklist', 'chkChecklistAuto', 'dgSchools', 'btnSchoolAdd', 'btnUsmtAdk', 'cmbUiScale'
    $miss = @($need | Where-Object { -not $w.FindName($_) })
    if ($miss.Count) { throw "fehlt: $($miss -join ', ')" }
    $true
}
T 'Logo + Icon vorhanden' { (Test-Path (Join-Path $root 'Assets\logo.png')) -and (Test-Path (Join-Path $root 'Assets\icon.ico')) }

# 3. Konfiguration
$mods = $null
T 'settings.default.json' { $s = Get-Content (Join-Path $root 'Config\settings.default.json') -Raw -Encoding UTF8 | ConvertFrom-Json; [bool]$s.Threads }
T 'exceptions.default.json' { $e = Get-Content (Join-Path $root 'Config\exceptions.default.json') -Raw -Encoding UTF8 | ConvertFrom-Json; @($e.ProfileFolders).Count -gt 0 }
T 'modules.default.json' {
    $script:mods = Get-Content (Join-Path $root 'Config\modules.default.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $ids = @($script:mods.Modules | ForEach-Object { $_.Id })
    $dup = @($ids | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
    if ($dup.Count) { throw "doppelte Id: $($dup -join ', ')" }
    $handlers = 'ExtraFolders', 'Wlan', 'Shares', 'PrinterConnections', 'PrintersFull', 'Fonts', 'Tasks', 'Drivers', 'Info', 'Wallpaper', 'Usmt'
    foreach ($m in $script:mods.Modules) {
        if (-not $m.Name -or -not $m.Group) { throw "$($m.Id): Name/Gruppe fehlt" }
        foreach ($i in @($m.Items)) {
            switch ($i.Type) {
                'Folder'  { if (-not $i.Path -or -not $i.Name) { throw "$($m.Id): Folder ohne Path/Name" } }
                'Files'   { if (-not $i.Path -or -not $i.Filter) { throw "$($m.Id): Files ohne Path/Filter" } }
                'Reg'     { if ($i.Key -notmatch '^(HKCU|HKLM|HKU)\\') { throw "$($m.Id): Reg-Key '$($i.Key)'" } }
                'Builtin' { if ($handlers -notcontains $i.Handler) { throw "$($m.Id): unbekannter Handler $($i.Handler)" } }
                default   { throw "$($m.Id): unbekannter Typ $($i.Type)" }
            }
        }
    }
    foreach ($p in $script:mods.Presets) { foreach ($x in @($p.Modules)) { if ($x -ne '*' -and $ids -notcontains $x) { throw "Vorlage '$($p.Name)': Modul $x fehlt" } } }
    "$($ids.Count) Module"
}
T 'apps.default.json (Programm-Katalog)' {
    $a = Get-Content (Join-Path $root 'Config\apps.default.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $ids = @($script:mods.Modules | ForEach-Object { $_.Id })
    foreach ($x in @($a.Apps)) {
        if (-not $x.Id -or -not $x.Name -or -not $x.Detect) { throw "Eintrag ohne Id/Name/Detect: $($x.Id)" }
        [void][regex]::new("$($x.Detect)")
        foreach ($m in @($x.Modules | Where-Object { $_ })) { if ($ids -notcontains $m) { throw "$($x.Id): Modul $m fehlt" } }
        foreach ($i in @($x.Items | Where-Object { $_ })) { if ($i.Type -notin 'Folder', 'Files', 'Reg') { throw "$($x.Id): Typ $($i.Type)" } }
    }
    "$(@($a.Apps).Count) Programme"
}
T 'USMT-XML' { foreach ($f in @(Get-ChildItem (Join-Path $root 'Config\USMT') -Filter *.xml)) { [xml](Get-Content $f.FullName -Raw) | Out-Null }; $true }

# 4. Engine
. (Join-Path $root 'Functions\Migration-Engine.ps1')
T 'Resolve-HMRegKey' { (Resolve-HMRegKey 'HKCU\Software\X' 'S-1-5-21-1') -eq 'HKU\S-1-5-21-1\Software\X' }
T 'Convert-HMPath remote' { (Convert-HMPath @{ IsRemote = $true; Computer = 'PC1' } 'C:\Users\a') -eq '\\PC1\C$\Users\a' }
T 'Convert-HMRegText' {
    $o = Convert-HMRegText -Text "[HKEY_CURRENT_USER\Network\Z]`r`n""P""=""C:\\Users\\alt\\x""" -TargetSid 'S-1-5-21-9' -SourceSid 'S-1-5-21-1' -SourceProfile 'C:\Users\alt' -TargetProfile 'C:\Users\neu'
    ($o -match 'HKEY_USERS\\S-1-5-21-9\\Network') -and ($o -match 'C:\\\\Users\\\\neu\\\\x')
}
T 'Lokale Profile lesen' { $p = @(Get-HMUserProfiles -Computer $env:COMPUTERNAME); "$($p.Count) Profile" }
T 'Robocopy Backup/Restore (TEMP)' {
    $base = Join-Path $env:TEMP "HUMigTest_$([guid]::NewGuid().ToString('N'))"
    $src = Join-Path $base 'src'; $dst = Join-Path $base 'dst'; $back = Join-Path $base 'back'
    New-Item -ItemType Directory -Path (Join-Path $src 'Unter\AppData') -Force | Out-Null
    Set-Content (Join-Path $src 'a.txt') 'Hallo' -Encoding UTF8
    Set-Content (Join-Path $src 'Unter\b.docx') ('x' * 5000) -Encoding UTF8
    Set-Content (Join-Path $src 'Unter\AppData\c.txt') 'weg' -Encoding UTF8
    Set-Content (Join-Path $src 'd.log') 'weg' -Encoding UTF8
    $job = @{ Log = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue)); Cancel = $false }
    try {
        $r = Invoke-HMRobocopy -Job $job -Source $src -Dest $dst -XD @('AppData') -XF @('*.log') -Threads 8
        if ($r.Level -ne 'OK') { throw "Backup Robocopy $($r.ExitCode)" }
        if (-not (Test-Path (Join-Path $dst 'Unter\b.docx'))) { throw 'Datei fehlt im Backup' }
        if (Test-Path (Join-Path $dst 'Unter\AppData\c.txt')) { throw 'Ausnahme AppData nicht wirksam' }
        if (Test-Path (Join-Path $dst 'd.log')) { throw 'Ausnahme *.log nicht wirksam' }
        if ($r.FilesTotal -lt 2) { throw "Zusammenfassung: $($r.FilesTotal) Dateien statt 2" }
        $r2 = Invoke-HMRobocopy -Job $job -Source $dst -Dest $back -Threads 8
        if ($r2.Level -ne 'OK' -or -not (Test-Path (Join-Path $back 'a.txt'))) { throw 'Restore fehlgeschlagen' }
        [void](Invoke-HMRobocopy -Job $job -Source $src -Dest (Join-Path $base 'list') -ListOnly -Threads 4)
        if (Test-Path (Join-Path $base 'list\a.txt')) { throw '/L hat kopiert' }
        "2 Dateien, $($r.BytesTotal) Bytes"
    } finally { Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue }
}

# 4b. Neue Backup-Funktionen (v0.0.3): Dateiliste, Ausschluss per Pfad, Cloud-Ordner, Pruefung, Protokoll
T 'Robocopy Dateiliste + Ausschluss per Pfad (TEMP)' {
    $base = Join-Path $env:TEMP "HUMigTest_$([guid]::NewGuid().ToString('N'))"
    $src = Join-Path $base 'src'
    New-Item -ItemType Directory -Path (Join-Path $src 'Gross\Tief\Er') -Force | Out-Null
    Set-Content (Join-Path $src 'a.txt') 'Hallo' -Encoding UTF8
    [System.IO.File]::WriteAllBytes((Join-Path $src 'Gross\Tief\Er\video test.bin'), (New-Object byte[] 300000))
    Set-Content (Join-Path $src 'weg.txt') 'nicht sichern' -Encoding UTF8
    $job = @{ Log = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue)); Cancel = $false }
    try {
        $st = New-HMStats
        [void](Invoke-HMRobocopy -Job $job -Source $src -Dest (Join-Path $base 'm') -ListOnly -ListFiles -Stats $st -StatsRoot $src -StatsModule 'Test' -Threads 4)
        $top = @($st.Files | Sort-Object Size -Descending)
        if ($top.Count -ne 3) { throw "Dateiliste: $($top.Count) statt 3 Dateien erkannt (Robocopy-Ausgabeformat?)" }
        if ($top[0].Path -notlike '*video test.bin' -or $top[0].Size -ne 300000) { throw "Groesste Datei falsch: $($top[0].Path) $($top[0].Size)" }
        if (-not @($st.Folders.Values | Where-Object { $_.Path -like '*\Gross' -and $_.Size -eq 300000 }).Count) { throw 'Ordnersumme fehlt' }
        [void](Invoke-HMRobocopy -Job $job -Source $src -Dest (Join-Path $base 'b') -XF @((Join-Path $src 'weg.txt')) -XD @((Join-Path $src 'Gross\Tief')) -Threads 4)
        if (Test-Path (Join-Path $base 'b\weg.txt')) { throw '/XF mit vollem Pfad nicht wirksam' }
        if (Test-Path (Join-Path $base 'b\Gross\Tief')) { throw '/XD mit vollem Pfad nicht wirksam' }
        if (-not (Test-Path (Join-Path $base 'b\a.txt'))) { throw 'a.txt fehlt' }
        $map = @([pscustomobject]@{ Module = 'T'; Name = 'T'; Src = $src; Dst = (Join-Path $base 'b'); Files = @(); XD = @((Join-Path $src 'Gross\Tief')); XF = @((Join-Path $src 'weg.txt')); NoHidden = $false; NoRecurse = $false })
        $v = Test-HMBackupIntegrity @{ Threads = 4; ListOnly = $false } $job $map 5
        if ($v.DiffFiles -ne 0 -or $v.Sampled -lt 1 -or @($v.HashMismatch).Count) { throw "Pruefung: Diff $($v.DiffFiles), geprueft $($v.Sampled), Abweichungen $(@($v.HashMismatch).Count)" }
        "Liste $($top.Count) Dateien, Pruefung $($v.Sampled) Dateien OK"
    } finally { Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue }
}
T 'Cloud-Ordner kopieren (nur lokale Dateien, TEMP)' {
    $base = Join-Path $env:TEMP "HUMigTest_$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path (Join-Path $base 'od\Sub') -Force | Out-Null
    Set-Content (Join-Path $base 'od\x.docx') 'x' -Encoding UTF8
    Set-Content (Join-Path $base 'od\Sub\y.tmp') 'y' -Encoding UTF8
    try {
        $ctx = @{ IsRemote = $false; ListOnly = $false }
        $job = @{ Cancel = $false; Status = '' }
        $r = Backup-HMCloudFolder $ctx $job (Join-Path $base 'od') (Join-Path $base 'out') @('*.tmp') 'T'
        if (-not (Test-Path (Join-Path $base 'out\x.docx')) -or (Test-Path (Join-Path $base 'out\Sub\y.tmp'))) { throw 'Kopie/Ausnahme falsch' }
        $r2 = Backup-HMCloudFolder $ctx $job (Join-Path $base 'od') (Join-Path $base 'out') @('*.tmp') 'T'
        if ($r2.BytesCopied -ne 0) { throw 'inkrementell: unveraenderte Datei erneut kopiert' }
        $r.Msg
    } finally { Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue }
}
T 'Cloud-Ordner des angemeldeten Benutzers erkennen' {
    $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $r = @(Get-HMSyncRoots @{ IsRemote = $false } $sid $env:USERPROFILE)
    "$($r.Count) gefunden$(if ($r.Count) { ': ' + (($r | ForEach-Object { Split-Path $_ -Leaf }) -join ', ') })"
}
T 'Freier Platz (TEMP)' { $f = Get-HMFreeSpace $env:TEMP; if ($f -le 0) { throw "Wert $f" }; Format-HMSize $f }
T 'Protokoll (HTML)' {
    $f = Join-Path $env:TEMP "HUMigTest_$([guid]::NewGuid().ToString('N')).html"
    try {
        $r = New-HMReport -Ctx @{ ToolRoot = $root; ToolVersion = 'Test' } -Kind Backup -OutFile $f -Modules @([pscustomobject]@{ Name = 'Test <1>'; Status = 'OK'; Items = @() }) -Facts ([ordered]@{ Computer = 'PC' }) -Status 'OK'
        if (-not $r -or (Get-Content $f -Raw) -notmatch 'Test &lt;1&gt;') { throw 'Inhalt fehlt' }
        $true
    } finally { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
}
T 'Backup-Laufwerk: USB/BitLocker-Abfrage' {
    . (Join-Path $root 'Functions\UI-Extras.ps1')
    $r = & $script:RS_DriveSecurity ($env:SystemDrive.Substring(0, 1))
    "Bus $($r.Bus), BitLocker-Schutz $($r.Protection)$(if ($r.Error) { ' (' + $r.Error.Split([char]10)[0] + ')' })"
}

# 4d. Backup-Qualitaet (v0.0.5): Pruefsummen-Katalog, Pruefung, Vergleich, Programmliste
. (Join-Path $root 'Functions\Migration-Quality.ps1')
T 'Pruefsummen-Katalog + Pruefung + Vergleich (TEMP)' {
    $base = Join-Path $env:TEMP "HUMigTest_$([guid]::NewGuid().ToString('N'))"
    $a = Join-Path $base 'A'; $b = Join-Path $base 'B'
    New-Item -ItemType Directory -Path (Join-Path $a 'Profile\USER'), (Join-Path $b 'Profile\USER') -Force | Out-Null
    Set-Content (Join-Path $a 'Profile\USER\x.txt') 'eins' -Encoding UTF8
    Set-Content (Join-Path $a 'Profile\USER\y.txt') 'zwei' -Encoding UTF8
    Copy-Item (Join-Path $a 'Profile\USER\x.txt') (Join-Path $b 'Profile\USER\x.txt')
    Set-Content (Join-Path $b 'Profile\USER\z.txt') 'neu' -Encoding UTF8
    $job = @{ Log = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue)); Cancel = $false; Progress = 0; Status = '' }
    try {
        $c = Update-HMChecksumCatalog $a $job
        if ($c.Files -ne 2) { throw "Katalog: $($c.Files) statt 2 Dateien" }
        Test-HMBackupCatalog -Ctx @{ Backup = @{ Path = $a } } -Job $job
        if ($job.Result.Status -ne 'OK') { throw "Pruefung: $($job.Result.Status)" }
        $fi = Get-Item (Join-Path $a 'Profile\USER\y.txt'); $t = $fi.LastWriteTimeUtc
        [System.IO.File]::WriteAllText($fi.FullName, 'zwex'); $fi.LastWriteTimeUtc = $t
        Test-HMBackupCatalog -Ctx @{ Backup = @{ Path = $a } } -Job $job
        if ($job.Result.Status -ne 'Error' -or -not @($job.Result.Problems | Where-Object { $_.Status -eq 'BESCHAEDIGT' }).Count) { throw 'Beschaedigung nicht erkannt' }
        Compare-HMBackups -Ctx @{ CompareA = $a; CompareB = $b } -Job $job
        "$($job.Result.Summary)"
    } finally { Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue }
}
T 'Installierte Programme lesen (Programm-Katalog)' {
    $sw = @(Get-HMInstalledSoftware @{ IsRemote = $false; Computer = $env:COMPUTERNAME } '')
    if (-not $sw.Count) { throw 'keine Programme gefunden' }
    $cat = @((Get-Content (Join-Path $root 'Config\apps.default.json') -Raw -Encoding UTF8 | ConvertFrom-Json).Apps)
    $f = @(Find-HMCatalogApps $sw $cat)
    "$($sw.Count) Programme, erkannt: $((@($f | ForEach-Object { $_.Name }) | Select-Object -First 8) -join ', ')"
}

# 4c. Werkzeuge (v0.0.4) - nur lesende Abfragen am eigenen PC
. (Join-Path $root 'Functions\Tools-System.ps1')
T 'Werkzeug: Netzwerkadapter lesen' { $r = @(& $script:RS_NetInfo); if (-not $r.Count) { throw 'kein aktiver Adapter' }; "$($r.Count) Adapter, $($r[0].Name) $($r[0].IP)" }
T 'Werkzeug: Lokale Gruppen lesen' { $r = @(& $script:RS_GroupList $script:HMLocalGroups | Where-Object { $_.Gruppe }); $a = @($r | Where-Object { $_.Sid -eq 'S-1-5-32-544' }); if (-not $a.Count) { throw 'Administratoren leer?' }; "$($r.Count) Mitglieder, $($a.Count) Admins" }
T 'Werkzeug: Energie-Werte lesen' { $r = @(& $script:RS_Power @{ Query = $true }); if (@($r | Where-Object { $_ -like 'FEHLER*' }).Count) { throw ($r -join ' | ') }; if (-not @($r | Where-Object { $_ -match 'Bildschirm aus: Netz \d+ min|Bildschirm aus: Netz nie' }).Count) { throw "powercfg-Werte nicht erkannt: $($r -join ' | ')" }; ($r | Where-Object { $_ -match 'Bildschirm' }) -replace '^INFO ', '' }
T 'Werkzeug: Firewall lesen' { $r = @(& $script:RS_Firewall 'List' $null | Where-Object { $_.Art }); if (-not $r.Count) { throw 'keine Daten' }; "$($r.Count) Eintraege" }
T 'Werkzeug: LSA-Baustein (Autologon) kompilieren' { if (-not ('HMLsa' -as [type])) { Add-Type -TypeDefinition $script:HMLsaSource -ErrorAction Stop }; $true }
T 'Werkzeug: Anmeldedaten lesen (cmdkey)' { $r = @(Get-HMCmdKeyList); "$($r.Count) Eintraege" }
T 'Werkzeug: Profil-Sicherungen lesen' { $r = @(& $script:RS_ProfileOp 'List' '' ''); "$($r.Count) erneuerte Profile" }
. (Join-Path $root 'Functions\Tools-School.ps1')
T 'Werkzeug: Ordnerfreigaben lesen (v0.0.5)' { $r = @(& $script:HMShareReadScript); "$($r.Count) Freigaben$(if ($r.Count) { ': ' + ((@($r | ForEach-Object { $_.Name })) -join ', ') })" }
. (Join-Path $root 'Functions\Tools-Multi.ps1')
T 'Werkzeug: Uebermittlungsoptimierung lesen (v0.0.5)' { $r = @(& $script:RS_DeliveryOpt @{ Query = $true }); if (@($r | Where-Object { $_ -like 'FEHLER*' }).Count) { throw ($r -join ' | ') }; ($r -replace '^INFO ', '') -join ' | ' }
T 'Werkzeug: AD-Computer lesen (v0.0.5)' { $r = @(& $script:RS_ADComputers); if (@($r | Where-Object { "$_" -like 'FEHLER*' }).Count) { "nicht in der Domaene oder DC nicht erreichbar: $($r -join ' ')" } else { "$($r.Count) Computer" } }
T 'Werkzeug: Inventar lokal (v0.0.5)' { $r = & $script:RS_Inventory $false; if (-not $r.Computer) { throw 'keine Daten' }; "$($r.Hersteller) $($r.Modell), SN $($r.Seriennummer), $($r.Windows) $($r.Version), BitLocker $($r.BitLocker)" }

# 5. Softwareverteilung / Starter
. (Join-Path $root 'Functions\Tools-Software.ps1')
T 'Installer-Erkennung (EXE)' { $i = Get-SwInstallerInfo (Join-Path $env:windir 'System32\robocopy.exe'); if (-not $i -or $i.Type -ne 'EXE') { throw 'keine Info' }; "$($i.Framework)" }
T 'Starter HUMig.exe erzeugen (TEMP)' {
    . (Join-Path $root 'Functions\UI-Shell.ps1')
    $tmpRoot = Join-Path $env:TEMP "HUMigLauncherTest_$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path (Join-Path $tmpRoot 'Assets') -Force | Out-Null
    Copy-Item (Join-Path $root 'Assets\icon.ico') (Join-Path $tmpRoot 'Assets\icon.ico')
    $saveRoot = $script:AppRoot; $script:AppRoot = $tmpRoot
    try {
        if (-not (New-HMLauncher -Force)) { throw 'Kompilieren fehlgeschlagen' }
        $len = (Get-Item (Join-Path $tmpRoot 'HUMig.exe')).Length
        "$len Bytes"
    } finally { $script:AppRoot = $saveRoot; Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

$out.Add('')
$out.Add($(if ($fail) { "ERGEBNIS: $fail FEHLER" } else { 'ERGEBNIS: alles OK' }))
$outFile = Join-Path $root 'Test-HUMig.result.txt'
$out | Set-Content -LiteralPath $outFile -Encoding UTF8
$out | ForEach-Object { if ($_ -like 'FAIL*') { Write-Host $_ -ForegroundColor Red } elseif ($_ -like 'OK*') { Write-Host $_ -ForegroundColor Green } else { Write-Host $_ } }
exit $fail
