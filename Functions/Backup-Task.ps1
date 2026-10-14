#Requires -Version 5.1
<#
.SYNOPSIS
    Geplantes Profil-Backup ohne Oberflaeche (wird von einer geplanten Aufgabe im Konto des Benutzers gestartet).
.DESCRIPTION
    Liest die Zeitplan-Definition %LOCALAPPDATA%\HUMig\Zeitplaene\<Id>.json (angelegt in HUMig > Backup > Zeitplan),
    sucht das Backup-Ziel (USB-Laufwerk ueber seine Bezeichnung, Netzwerkpfad als UNC), sichert das eigene Profil
    mit der Backup-Engine (fortlaufend = vorhandenes Backup aktualisieren, oder neues Backup), loescht auf Wunsch alte
    Backups (neueste N je PC + Benutzer bleiben), wirft auf Wunsch das USB-Laufwerk aus und zeigt eine Windows-Meldung.
    Protokoll: %LOCALAPPDATA%\HUMig\Zeitplaene\Logs\*.log, dazu HUMig.log + Bericht_Backup.html im Backup-Ordner.
.NOTES
    Zielmaschine: der PC des Benutzers (Aufruf durch die Aufgabenplanung, im Konto des Benutzers, nur wenn angemeldet).
    Ohne Administratorrechte: nur Module des eigenen Profils (wie im Benutzer-Modus).
    Exitcode: 0 = OK, 1 = Warnung, 2 = Fehler / Ziel nicht erreichbar / uebersprungen.
#>
param([Parameter(Mandatory)][string]$Id)
$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
$script:AppRoot   = $root
$script:ConfigDir = Join-Path $root 'Config'
$script:ConfigErrors = @()
$schedDir = Join-Path $env:LOCALAPPDATA 'HUMig\Zeitplaene'
$logDir   = Join-Path $schedDir 'Logs'
try { New-Item -ItemType Directory -Path $logDir -Force | Out-Null } catch { }
if ($Id -notmatch '^[A-Za-z0-9]{8,40}$') { exit 2 }
$defFile = Join-Path $schedDir "$Id.json"
$script:TaskLog = Join-Path $logDir ('{0}_{1}.log' -f (Get-Date -Format 'yyyy-MM-dd_HHmmss'), $Id)

function Write-TaskLog([string]$Msg, [string]$Lvl = 'Info') {
    try { Add-Content -LiteralPath $script:TaskLog -Value ('{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), "$Lvl".ToUpper(), $Msg) -Encoding UTF8 } catch { }
}

# ----------------------------------------------------------------------------
# Konfiguration (wie HUMig.ps1 > Import-AppConfig, ohne Oberflaeche)
# ----------------------------------------------------------------------------
function Read-JsonFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { Write-TaskLog "$Path fehlerhaft: $($_.Exception.Message)" 'Warning'; $script:ConfigErrors += "$(Split-Path $Path -Leaf)"; return $null }
}
function Merge-Config($Default, $Local) {
    if ($null -eq $Local) { return $Default }
    if ($null -eq $Default) { return $Local }
    if ($Default -is [System.Management.Automation.PSCustomObject] -and $Local -is [System.Management.Automation.PSCustomObject]) {
        $r = [ordered]@{}
        foreach ($p in $Default.PSObject.Properties) { $r[$p.Name] = $p.Value }
        foreach ($p in $Local.PSObject.Properties) {
            if ($r.Contains($p.Name)) { $r[$p.Name] = Merge-Config $r[$p.Name] $p.Value } else { $r[$p.Name] = $p.Value }
        }
        return [pscustomobject]$r
    }
    return $Local
}
function Import-TaskConfig {
    $script:Settings = Merge-Config (Read-JsonFile (Join-Path $script:ConfigDir 'settings.default.json')) (Read-JsonFile (Join-Path $script:ConfigDir 'settings.json'))
    $an = "$($script:Settings.ActiveProfile)".Trim()
    $school = $null
    if ($an) { $school = @($script:Settings.Profiles | Where-Object { $_ -and "$($_.Name)" -eq $an })[0] }
    if ($school) {
        $ov = [ordered]@{}
        foreach ($k in @('BackupRoot', 'SoftwareFolder', 'UsmtPath', 'ADServer')) { if ("$($school.$k)".Trim()) { $ov[$k] = "$($school.$k)".Trim() } }
        if ($ov.Count) { $script:Settings = Merge-Config $script:Settings ([pscustomobject]$ov) }
    }
    $script:Exceptions = Merge-Config (Read-JsonFile (Join-Path $script:ConfigDir 'exceptions.default.json')) (Read-JsonFile (Join-Path $script:ConfigDir 'exceptions.json'))
    $modDef = Read-JsonFile (Join-Path $script:ConfigDir 'modules.default.json')
    $modLoc = Read-JsonFile (Join-Path $script:ConfigDir 'modules.json')
    $mods = [System.Collections.Generic.List[object]]::new()
    foreach ($m in @($modDef.Modules)) { if ($m) { $mods.Add($m) } }
    if ($modLoc -and $modLoc.Modules) {
        foreach ($m in @($modLoc.Modules)) {
            if (-not $m) { continue }
            $idx = -1
            for ($i = 0; $i -lt $mods.Count; $i++) { if ($mods[$i].Id -eq $m.Id) { $idx = $i; break } }
            if ($idx -ge 0) { $mods[$idx] = $m } else { $mods.Add($m) }
        }
    }
    try { Import-HMAppCatalog $mods } catch { Write-TaskLog "Programm-Katalog nicht lesbar: $($_.Exception.Message)" 'Warning' }
    $script:Modules = @($mods)
}

# Zeitplan-Datei lesen/ergaenzen (Ergebnis des Laufs fuer die Anzeige in HUMig)
function Save-TaskState([hashtable]$Values) {
    try {
        $cur = Get-Content -LiteralPath $defFile -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $h = [ordered]@{}
        foreach ($p in $cur.PSObject.Properties) { $h[$p.Name] = $p.Value }
        foreach ($k in $Values.Keys) { $h[$k] = $Values[$k] }
        [pscustomobject]$h | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $defFile -Encoding UTF8 -Force
    } catch { Write-TaskLog "Status konnte nicht in die Zeitplan-Datei geschrieben werden: $($_.Exception.Message)" 'Warning' }
}

# Windows-Meldung (Symbol im Infobereich, Klick oeffnet den Bericht)
function Show-TaskNotification([string]$Title, [string]$Text, [string]$Kind, [string]$OpenPath) {
    try {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        $ni = New-Object System.Windows.Forms.NotifyIcon
        $ico = Join-Path $root 'Assets\icon.ico'
        $ni.Icon = if (Test-Path -LiteralPath $ico) { New-Object System.Drawing.Icon $ico } else { [System.Drawing.SystemIcons]::Information }
        $ni.Text = 'HUMig'
        $script:NotifyOpen = $OpenPath
        $open = { if ($script:NotifyOpen -and (Test-Path -LiteralPath $script:NotifyOpen)) { try { Start-Process -FilePath $script:NotifyOpen } catch { } } }
        $ni.Add_BalloonTipClicked($open)
        $ni.Add_MouseClick($open)
        $ni.Visible = $true
        $ti = switch ($Kind) { 'Error' { [System.Windows.Forms.ToolTipIcon]::Error } 'Warning' { [System.Windows.Forms.ToolTipIcon]::Warning } default { [System.Windows.Forms.ToolTipIcon]::Info } }
        $ni.ShowBalloonTip(15000, $Title, $(if ($Text) { $Text } else { ' ' }), $ti)
        $t0 = Get-Date
        while (((Get-Date) - $t0).TotalSeconds -lt 20) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 }
        $ni.Visible = $false
        $ni.Dispose()
    } catch { Write-TaskLog "Meldung nicht moeglich: $($_.Exception.Message)" 'Debug' }
}

# Auswerfen (USB-Laufwerk, Schutz vor Verschluesselungstrojanern) - nur einmal je Lauf, auch nach einem Fehler.
# Gibt den Text fuer die Meldung zurueck ('' = nichts zu tun); $script:EjectFailed = Auswerfen nicht moeglich
$script:EjectDone = $false
$script:EjectFailed = $false
$script:TargetRoot = $null
function Invoke-TaskEject {
    if ($script:EjectDone) { return '' }
    if (-not $script:Def -or -not [bool]$script:Def.EjectAfter -or "$($script:Def.Target.Type)" -ne 'Drive' -or -not "$($script:TargetRoot)") { return '' }
    $script:EjectDone = $true
    $ejL = "$($script:TargetRoot)".Substring(0, 1).ToUpper()
    try { Set-Location -LiteralPath $env:SystemRoot } catch { }
    [GC]::Collect(); [GC]::WaitForPendingFinalizers()
    $ejR = ''
    try { $ejR = Invoke-HMDriveEject $ejL } catch { $ejR = $_.Exception.Message }
    if ($ejR) {
        $script:EjectFailed = $true
        Write-TaskLog "Laufwerk ${ejL}: nicht ausgeworfen - $ejR" 'Warning'
        return " - Auswerfen nicht moeglich: $ejR"
    }
    Write-TaskLog "Laufwerk ${ejL}: ausgeworfen - kann abgezogen werden; vor dem naechsten Lauf wieder anstecken" 'Success'
    return ' - Laufwerk ausgeworfen'
}

# Ende: Status speichern, ggf. Meldung, Exitcode
function Complete-Task([string]$Status, [string]$Msg, [string]$BackupPath = '') {
    # vorzeitiges Ende (Ausnahme, zu wenig Platz, keine Module): Laufwerk trotzdem auswerfen, Ergebnis in Meldung/Status
    $ej = ''
    try { $ej = Invoke-TaskEject } catch { Write-TaskLog "Auswerfen fehlgeschlagen: $($_.Exception.Message)" 'Warning' }
    if ($ej) {
        $Msg = "$Msg$ej"
        if ($script:EjectFailed -and $Status -eq 'OK') { $Status = 'Warning' }
    }
    $st = switch ($Status) { 'OK' { 'OK' } 'Warning' { 'Warnung' } 'Skipped' { 'uebersprungen' } default { 'Fehler' } }
    Write-TaskLog "Ende - $st$(if ($Msg) { ": $Msg" })" $(if ($Status -eq 'OK') { 'Success' } elseif ($Status -eq 'Warning') { 'Warning' } else { 'Error' })
    $state = @{ LastRun = (Get-Date).ToString('yyyy-MM-dd HH:mm'); LastStatus = $Status; LastMessage = $Msg; LastBackup = $BackupPath; LastLog = $script:TaskLog; LastMassDelete = [bool]$script:MassDelete }
    if ($Status -in @('OK', 'Warning')) { $state.LastSuccess = $state.LastRun }   # fuer die Warnung "seit X Tagen kein erfolgreicher Lauf"
    Save-TaskState $state
    # Ereignis im Anwendungsprotokoll (Quelle HUMig, 1100 OK, 1101 Warnung, 1102 Fehler, 1103 uebersprungen). Ist am PC die
    # Teams-Benachrichtigung eingerichtet, meldet eine Aufgabe unter SYSTEM den Lauf weiter (Functions\Notify-Relay.ps1) -
    # dieses Skript selbst kennt die Webhook-Adressen nicht. Ohne Quelle 'HUMig' (legt HUMig als Administrator an) entfaellt es.
    try {
        $eid = switch ($Status) { 'OK' { 1100 } 'Warning' { 1101 } 'Skipped' { 1103 } default { 1102 } }
        $ety = switch ($Status) { 'OK' { 'Information' } 'Error' { 'Error' } default { 'Warning' } }
        $nm = if ($script:Def) { "$($script:Def.Name)" } else { $Id }
        Write-EventLog -LogName Application -Source 'HUMig' -EntryType $ety -EventId $eid -Message ("Geplantes Profil-Backup '{0}' von {1}\{2} an {3}: {4}{5}" -f $nm, $env:USERDOMAIN, $env:USERNAME, $env:COMPUTERNAME, $st, $(if ($Msg) { " - $Msg" })) -ErrorAction Stop
    } catch { Write-TaskLog "Ereignis nicht geschrieben (Quelle HUMig fehlt?): $($_.Exception.Message)" 'Debug' }
    # alte Protokolle dieses Zeitplans aufraeumen (neueste 30 bleiben)
    try { Get-ChildItem -LiteralPath $logDir -Filter "*_$Id.log" -File | Sort-Object Name -Descending | Select-Object -Skip 30 | Remove-Item -Force -ErrorAction SilentlyContinue } catch { }
    $always = $true
    if ($script:Def -and $null -ne $script:Def.NotifyAlways) { $always = [bool]$script:Def.NotifyAlways }
    if ($always -or $Status -ne 'OK') {
        $name = if ($script:Def) { "$($script:Def.Name)" } else { $Id }
        $rep = if ($BackupPath) { Join-Path $BackupPath 'Bericht_Backup.html' } else { '' }
        if (-not $rep -or -not (Test-Path -LiteralPath $rep)) { $rep = $script:TaskLog }
        $kind = switch ($Status) { 'OK' { 'Info' } 'Warning' { 'Warning' } default { 'Error' } }
        Show-TaskNotification "HUMig Backup ($name): $st" $Msg $kind $rep
    }
    switch ($Status) { 'OK' { exit 0 } 'Warning' { exit 1 } default { exit 2 } }
}

# ----------------------------------------------------------------------------
# Start
# ----------------------------------------------------------------------------
$script:Def = $null
try { $script:Def = Get-Content -LiteralPath $defFile -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop } catch { }
$version = ''
try { $version = "$((Get-Content -LiteralPath (Join-Path $root 'Config\version.json') -Raw -Encoding UTF8 | ConvertFrom-Json).version)".Trim() } catch { }
if (-not $version) { try { if ((Get-Content -LiteralPath (Join-Path $root 'HUMig.ps1') -Raw -Encoding UTF8) -match "\`$script:Version\s*=\s*'([0-9\.]+)'") { $version = $Matches[1] } } catch { } }
$me = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$elevated = ([Security.Principal.WindowsPrincipal]$me).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-TaskLog "Geplantes Backup '$(if ($script:Def) { $script:Def.Name } else { $Id })' - $($me.Name) an $env:COMPUTERNAME - HUMig $version - $(if ($elevated) { 'mit Administratorrechten' } else { 'Benutzer-Modus (ohne Administratorrechte)' })" 'Header'
if (-not $script:Def) { Complete-Task 'Error' "Zeitplan-Datei fehlt oder ist fehlerhaft: $defFile" }
if ("$($script:Def.Sid)" -and "$($script:Def.Sid)" -ne $me.User.Value) { Complete-Task 'Error' 'Zeitplan gehoert zu einem anderen Benutzerkonto - nicht ausgefuehrt' }

# Engine laeuft wie in HUMig (Hintergrund-Runspace) mit der Standard-Fehlerbehandlung
$ErrorActionPreference = 'Continue'
try {
    foreach ($f in @('Migration-Engine.ps1', 'Migration-Quality.ps1', 'UI-Apps.ps1', 'UI-Quality.ps1')) { . (Join-Path $PSScriptRoot $f) }
    Import-TaskConfig
} catch { Complete-Task 'Error' "HUMig-Dateien nicht ladbar: $($_.Exception.Message)" }

# ---- nur ein geplanter Lauf gleichzeitig je Benutzer (z.B. taeglich + woechentlich zur selben Zeit) ----
$script:TaskMutex = $null
try {
    $script:TaskMutex = New-Object System.Threading.Mutex($false, ('Local\HUMig_Backup_' + ($me.User.Value -replace '[^\w\-]', '_')))
    $got = $false
    try { $got = $script:TaskMutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $got = $true }
    if (-not $got) {
        Write-TaskLog 'Ein anderer geplanter Backup-Lauf dieses Benutzers laeuft gerade - warte, bis er fertig ist ...' 'Info'
        try { $got = $script:TaskMutex.WaitOne([TimeSpan]::FromHours(11)) } catch [System.Threading.AbandonedMutexException] { $got = $true }
        if (-not $got) { Complete-Task 'Skipped' 'anderer geplanter Lauf wurde nicht fertig - uebersprungen' }
    }
} catch { Write-TaskLog "Sperre nicht moeglich: $($_.Exception.Message)" 'Debug' }

# ---- Backup-Ziel finden ----
$t = $script:Def.Target
$targetRoot = $null
$why = ''
switch ("$($t.Type)") {
    'Unc' {
        $p = "$($t.Path)".TrimEnd('\')
        try { if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force -ErrorAction Stop | Out-Null }; $targetRoot = $p }
        catch { $why = "Netzwerkpfad $p nicht erreichbar ($($_.Exception.Message))" }
    }
    'Drive' {
        $lbl = "$($t.Label)"; $let = "$($t.Letter)".TrimEnd(':', '\').ToUpper(); $rel = "$($t.Rel)".Trim('\')
        $ready = @([System.IO.DriveInfo]::GetDrives() | Where-Object { try { $_.IsReady -and $_.DriveType -ne 'Network' } catch { $false } })
        $d = $null
        if ($lbl) {
            $cand = @($ready | Where-Object { "$($_.VolumeLabel)" -eq $lbl })
            $d = @($cand | Where-Object { $_.Name.Substring(0, 1).ToUpper() -eq $let }) + @($cand) | Select-Object -First 1
            if ($cand.Count -gt 1) { Write-TaskLog "Mehrere Laufwerke mit der Bezeichnung '$lbl' - verwendet wird $($d.Name)" 'Warning' }
            if (-not $d) { $why = "Laufwerk '$lbl' ist nicht angesteckt (oder gesperrt)" }
        } else {
            $d = @($ready | Where-Object { $_.Name.Substring(0, 1).ToUpper() -eq $let })[0]
            if (-not $d) { $why = "Laufwerk ${let}: ist nicht verfuegbar" }
        }
        if ($d) {
            $p = if ($rel) { Join-Path $d.RootDirectory.FullName $rel } else { $d.RootDirectory.FullName }   # Wurzel mit \ (E:\)
            try { if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force -ErrorAction Stop | Out-Null }; $targetRoot = $p }
            catch { $why = "Backup-Ordner $p nicht beschreibbar ($($_.Exception.Message))" }
        }
    }
    default { $why = 'Backup-Ziel in der Zeitplan-Datei fehlt' }
}
if (-not $targetRoot) { Complete-Task 'Skipped' "$why - Backup nicht ausgefuehrt" }
$script:TargetRoot = $targetRoot   # ab hier wird bei jedem Ende ausgeworfen (falls eingestellt)
Write-TaskLog "Backup-Ziel: $targetRoot" 'Info'

# ---- eigenes Profil ----
$sid = $me.User.Value
$prof = $null
try { $prof = @(Get-HMUserProfiles -Computer $env:COMPUTERNAME | Where-Object { "$($_.SID)" -eq $sid })[0] } catch { Write-TaskLog "Profilliste nicht lesbar: $($_.Exception.Message)" 'Debug' }
if (-not $prof) { $prof = [pscustomobject]@{ SID = $sid; LocalPath = $env:USERPROFILE; Folder = (Split-Path $env:USERPROFILE -Leaf); Account = $me.Name } }

# ---- Module ----
$userMode = -not $elevated
$mods = New-Object System.Collections.Generic.List[object]
foreach ($mid in @($script:Def.Modules | Where-Object { $_ })) {
    $m = @($script:Modules | Where-Object { "$($_.Id)" -eq "$mid" })[0]
    if (-not $m) { Write-TaskLog "Modul '$mid' gibt es nicht mehr - ausgelassen" 'Warning'; continue }
    if ($userMode -and -not (Test-HMModuleUserOk $m)) { Write-TaskLog "Modul '$($m.Name)' braucht Administratorrechte - ausgelassen" 'Warning'; continue }
    $mods.Add($m)
}
if (-not $mods.Count) { Complete-Task 'Error' 'Keine sicherbaren Module im Zeitplan' }

# ---- geoeffnete Programme (deren Dateien sind gesperrt) ----
$openApps = @()
try {
    $sess = (Get-Process -Id $PID).SessionId
    $names = [ordered]@{ OUTLOOK = 'Outlook'; thunderbird = 'Thunderbird'; firefox = 'Firefox'; chrome = 'Chrome'; msedge = 'Edge'; brave = 'Brave'; opera = 'Opera' }
    foreach ($n in $names.Keys) { if (@(Get-Process -Name $n -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $sess }).Count) { $openApps += $names[$n] } }
    if ($openApps.Count) { Write-TaskLog "Geoeffnet: $($openApps -join ', ') - deren geoeffnete Dateien (Outlook-PST, Browser-Datenbanken) koennen fehlen" 'Warning' }
} catch { }

# ---- Optionen / Kontext ----
$o = $script:Def.Options
$opt = @{
    ExtraFolders = @(@($o.ExtraFolders) | Where-Object { $_ } | ForEach-Object { "$_" })
    ExcludePaths = @(@($o.ExcludePaths) | Where-Object { $_ } | ForEach-Object { "$_" })
    MinimalProfileExceptions = [bool]$o.MinimalProfileExceptions; NoProfileFileExceptions = [bool]$o.NoProfileFileExceptions
    MinimalSystemExceptions = [bool]$o.MinimalSystemExceptions; NoSystemFileExceptions = [bool]$o.NoSystemFileExceptions
    OneDriveLocal = [bool]$o.OneDriveLocal; SkipSpaceCheck = [bool]$o.SkipSpaceCheck; Verify = [bool]$o.Verify
    RestoreOneDrive = $false; Catalog = [bool]$o.Catalog; KeepNewer = $false
    VerifySamples = $(if ($script:Settings.Backup -and $script:Settings.Backup.VerifySamples) { [int]$script:Settings.Backup.VerifySamples } else { 30 })
}
$threads = [int]$script:Def.Threads
if ($threads -lt 1) { $threads = 32 }
$ctx = @{
    ToolVersion = $version; ToolRoot = $root; Computer = $env:COMPUTERNAME; Credential = $null; UserMode = $userMode
    UserSid = $prof.SID; ProfilePath = $prof.LocalPath; UserFolder = $prof.Folder; Account = $(if ($prof.Account) { $prof.Account } else { $me.Name })
    Settings = $script:Settings; Exceptions = $script:Exceptions; Threads = $threads
    BackupRoot = $targetRoot; Options = $opt; AppCatalog = @($script:AppCatalog); Modules = $mods.ToArray()
}
$ctx.BackupPath = Join-Path $targetRoot ('{0}_{1}_{2}' -f (Get-Date -Format 'yyyy-MM-dd_HHmm'), (ConvertTo-HMSafeName $env:COMPUTERNAME), (ConvertTo-HMSafeName $prof.Folder))

# Fortlaufend: neuestes Backup dieses PCs + Benutzers im Ziel weiterfuehren. Ist das neueste ein Archiv: neues Backup anlegen
$mine = @()
$archived = $null
try {
    $all = Get-HMBackupList -Root $targetRoot -Modules $script:Modules
    $mine = @(@($all) | Where-Object { $_ -and -not $_.Legacy -and "$($_.Sid)" -eq $sid -and ("$($_.Computer)" -ieq $env:COMPUTERNAME -or "$($_.Computer)".Split('.')[0] -ieq $env:COMPUTERNAME) } | Sort-Object Name -Descending)
    if ($mine.Count -and $mine[0].Archived) { $archived = $mine[0].Name }
} catch { Write-TaskLog "Backup-Liste nicht lesbar: $($_.Exception.Message)" 'Warning' }
if ("$($script:Def.Kind)" -eq 'Update') {
    if ($archived) { Write-TaskLog "Fortlaufend: neuestes Backup '$archived' ist als Archiv markiert und bleibt unveraendert - es wird ein neues angelegt" 'Info' }
    elseif ($mine.Count) { $ctx.ExistingBackup = $mine[0].Path; Write-TaskLog "Fortlaufend: vorhandenes Backup wird aktualisiert ($($mine[0].Name))" 'Info' }
    else { Write-TaskLog 'Fortlaufend: noch kein Backup dieses PCs/Benutzers im Ziel - es wird ein neues angelegt' 'Info' }
} else { Write-TaskLog 'Neues Backup (eigener Stand)' 'Info' }
Write-TaskLog ("Module ({0}): {1}" -f $mods.Count, (@($mods | ForEach-Object { $_.Name }) -join ', ')) 'Info'

# ---- Backup ----
$logSink = [pscustomobject]@{ Kind = 'TaskLog' }
$logSink | Add-Member -MemberType ScriptMethod -Name Enqueue -Value { param($e) Write-TaskLog "$($e.Msg)" "$($e.Lvl)" }
$Job = [hashtable]::Synchronized(@{ Log = $logSink; Progress = 0; Status = ''; Cancel = $false; Done = $false; Result = $null; Process = $null; Error = $null; Started = (Get-Date); LogFile = $null })
try {
    Start-HMBackup -Ctx $ctx -Job $Job
} catch {
    Write-TaskLog "Abbruch: $($_.Exception.Message)" 'Error'
    Complete-Task 'Error' "Abbruch: $($_.Exception.Message)" "$($ctx.BackupPath)"
}
$res = $Job.Result
$st = if ($res) { "$($res.Status)" } else { 'Error' }
if ($st -eq 'NoSpace') {
    Complete-Task 'Error' ("Zu wenig Platz am Ziel: benoetigt ca. {0}, frei {1}" -f (Format-HMSize ([long]$res.Need)), (Format-HMSize ([long]$res.Free)))
}
$size = if ($res -and $res.SizeBytes) { Format-HMSize ([long]$res.SizeBytes) } else { '' }
$dur = if ($res -and $res.Duration) { "$($res.Duration)" } else { '' }
$msg = (@($size, $(if ($dur) { "Dauer $dur" })) | Where-Object { $_ }) -join ', '
if ($openApps.Count) { $msg += $(if ($st -eq 'OK') { " - Hinweis: geoeffnet waren $($openApps -join ', ') (gesperrte Dateien wie Cookies fehlen evtl.)" } else { " - geoeffnet waren: $($openApps -join ', ')" }) }
# Massenloeschung an der Quelle: typisches Zeichen fuer einen Verschluesselungstrojaner - immer melden
$script:MassDelete = $false
if ($ctx.Manifest -and $ctx.Manifest.MassDeleteAlert) {
    $script:MassDelete = $true
    $msg = "ACHTUNG: ungewoehnlich viele Dateien an der Quelle verschwunden - typisches Zeichen fuer einen Verschluesselungstrojaner. Quell-PC pruefen! $msg"
    if ($st -eq 'OK') { $st = 'Warning' }
}

# ---- Aufbewahrung (nur nach erfolgreichem Lauf) ----
$ret = $script:Def.Retention
if ($ret -and [bool]$ret.Enabled -and $st -in @('OK', 'Warning')) {
    $keep = [int]$ret.Keep
    if ($keep -lt 1) { $keep = 1 }
    try {
        $all = Get-HMBackupList -Root $targetRoot -Modules $script:Modules
        $mine = @(@($all) | Where-Object { $_ -and -not $_.Legacy -and "$($_.Sid)" -eq $sid -and ("$($_.Computer)" -ieq $env:COMPUTERNAME -or "$($_.Computer)".Split('.')[0] -ieq $env:COMPUTERNAME) })
        # Massenloeschung in diesem Lauf oder in einem Backup der letzten 14 Tage: alte Staende sind evtl. die einzigen sauberen
        $recentAlert = @($mine | Where-Object { $_.Manifest -and $_.Manifest.MassDeleteAlert -and ((Get-Date) - (Get-HMBackupDate $_)).TotalDays -le 14 }).Count
        if ($script:MassDelete -or $recentAlert) {
            Write-TaskLog 'Aufbewahrung ausgesetzt: Massenloeschung erkannt (letzte 14 Tage) - alte Backups bleiben erhalten' 'Warning'
            $msg += ' - Aufbewahrung ausgesetzt (Massenloeschung)'
        } else {
            $bad = @($mine | Where-Object { "$($_.Status)" -notin @('OK', 'Warning') }).Count
            if ($bad) { Write-TaskLog "Aufbewahrung: $bad unvollstaendige/fehlerhafte Backup(s) zaehlen nicht mit (werden nur entfernt, wenn ein neueres brauchbares existiert)" 'Info' }
            $cand = @(Get-HMRetentionCandidates -Backups $mine -Days 0 -Keep $keep)
            $cur = "$($ctx.BackupPath)".TrimEnd('\')
            $del = 0
            foreach ($c in $cand) {
                $bp = "$($c.Backup.Path)".TrimEnd('\')
                if (-not $bp -or $bp -ieq $cur -or (Split-Path $bp -Parent).TrimEnd('\') -ine $targetRoot.TrimEnd('\')) { continue }
                $r = Remove-HMBackupFolder $bp
                if ($r -eq 'OK') { $del++; Write-TaskLog "Aufbewahrung: altes Backup geloescht: $($c.Backup.Name)" 'Info' }
                else { Write-TaskLog "Aufbewahrung: $($c.Backup.Name): $r" 'Warning' }
            }
            Write-TaskLog "Aufbewahrung: neueste $keep brauchbare behalten, $del geloescht" 'Info'
            if ($del) { $msg += " - $del alte(s) Backup(s) geloescht" }
        }
    } catch { Write-TaskLog "Aufbewahrung fehlgeschlagen: $($_.Exception.Message)" 'Warning' }
}

# ---- Auswerfen (USB-Laufwerk, Schutz vor Verschluesselungstrojanern) - auch nach einem Fehler ----
$msg += Invoke-TaskEject
if ($script:EjectFailed -and $st -eq 'OK') { $st = 'Warning' }

switch ($st) {
    'OK'        { Complete-Task 'OK' $msg "$($ctx.BackupPath)" }
    'Warning'   { Complete-Task 'Warning' "$msg - Details im Bericht" "$($ctx.BackupPath)" }
    'Cancelled' { Complete-Task 'Error' 'abgebrochen' "$($ctx.BackupPath)" }
    default     { Complete-Task 'Error' "$msg - Details im Bericht" "$($ctx.BackupPath)" }
}
