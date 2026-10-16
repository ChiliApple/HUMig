#Requires -Version 5.1
<#
.SYNOPSIS
    Geplantes Server-Backup ohne Oberflaeche (wird von einer geplanten Aufgabe unter SYSTEM gestartet).
.DESCRIPTION
    Sucht die angesteckte Platte des Profils (Bezeichnung), sichert die angegebenen VMs mit der Windows Server-Sicherung,
    schreibt Verlauf (Tool-Ordner + Platte), Bericht und ein Protokoll nach Logs\ServerBackup\Aufgabe_*.log.
    Angelegt/verwaltet ueber HUMig > Server-Backup > Zeitplan.
.NOTES
    Zielmaschine: Hyper-V-Host mit HUMig (Aufruf durch die Aufgabenplanung, als SYSTEM).
    Exitcode: 0 = OK, 1 = Warnung, 2 = Fehler / keine Platte.
    Auch fuer "Server-Backup im Hintergrund" (einmalige Aufgabe ohne Ausloeser, aus der Oberflaeche gestartet, mit -DiskLabel).
#>
param(
    [Parameter(Mandatory)][string]$ProfileName,
    [string]$VMs = '',              # VM-Namen getrennt durch |  (leer = VMs aus dem Profil)
    [string]$Volumes = '',          # Laufwerke getrennt durch | (z.B. C:|D:), leer = Laufwerke aus dem Profil
    [switch]$HostConfig,
    [switch]$HostSystem,
    [switch]$NoVerify,
    [switch]$Explicit,              # VMs/Laufwerke genau wie angegeben (leer = keine), sonst leer = aus dem Profil
    [string]$DiskLabel = ''         # nur diese Platte verwenden (Start im Hintergrund aus der Oberflaeche: dort gewaehlte Platte)
)
$ErrorActionPreference = 'Stop'
$root   = Split-Path $PSScriptRoot -Parent
$cfgDir = Join-Path $root 'Config'
$repDir = Join-Path $root 'Logs\ServerBackup'
try { New-Item -ItemType Directory -Path $repDir -Force | Out-Null } catch { }
$script:TaskLog = Join-Path $repDir ('Aufgabe_{0}_{1}.log' -f (Get-Date -Format 'yyyy-MM-dd_HHmm'), ($ProfileName -replace '[^\w\-]', '_'))

. (Join-Path $PSScriptRoot 'ServerBackup-Engine.ps1')
. (Join-Path $PSScriptRoot 'Core-Notify.ps1')
. (Join-Path $PSScriptRoot 'UI-Status.ps1')   # nur Get-HMStatusData (Erinnerungen Plattenwechsel/Archiv)

# Protokoll direkt in die Datei (ueberschreibt die Queue-Variante der Engine)
function Write-HMSbLog([string]$Msg, [string]$Lvl = 'Info') {
    Add-HMSbRunLog $Msg $Lvl
    try { Add-Content -LiteralPath $script:TaskLog -Value ('{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Lvl.ToUpper(), $Msg) -Encoding UTF8 } catch { }
}

$localHist = Join-Path $cfgDir 'ServerBackup\history.json'
$localHealth = Join-Path $cfgDir 'ServerBackup\disk-health.json'
$version = ''
try { $version = "$((Get-Content -LiteralPath (Join-Path $root 'Config\version.json') -Raw -Encoding UTF8 | ConvertFrom-Json).version)".Trim() } catch { }
if (-not $version) { try { if ((Get-Content -LiteralPath (Join-Path $root 'HUMig.ps1') -Raw -Encoding UTF8) -match "\`$script:Version\s*=\s*'([0-9\.]+)'") { $version = $Matches[1] } } catch { } }

function Add-HMSbTaskError([string]$Note, [string]$Disk = '') {
    Write-HMSbLog $Note 'Error'
    Write-HMSbEvent 'Error' "Geplantes Server-Backup '$ProfileName' auf $env:COMPUTERNAME FEHLGESCHLAGEN: $Note`nProtokoll: $($script:TaskLog)`nHUMig $version"
    try {
        Add-HMSbHistory $localHist ([pscustomobject][ordered]@{
            Date = (Get-Date).ToString('yyyy-MM-dd HH:mm'); Profile = $ProfileName; Host = $env:COMPUTERNAME; Disk = $Disk; DiskSerial = ''
            VMs = ($VMs -replace '\|', ', '); Status = 'Error'; Minutes = 0; SizeGB = 0; VersionId = ''; HostConfig = $false; HostSystem = $false
            HostVersionId = ''; Note = "Geplante Aufgabe: $Note"; Tool = "HUMig $version"
        })
    } catch { }
    $n = Send-HMNotify -Title "Server-Backup '$ProfileName' auf $env:COMPUTERNAME FEHLGESCHLAGEN" -Lines @($Note, "Protokoll: $($script:TaskLog)") -Level 'Error' -Category 'SbError' -SbProfile $(if ($prof) { $ProfileName } else { '' })
    if ($n) { Write-HMSbLog $n 'Info' }
}

Write-HMSbLog "Geplantes Server-Backup - Profil '$ProfileName' - Host $env:COMPUTERNAME - Konto $env:USERDOMAIN\$env:USERNAME - HUMig $version" 'Header'

# --- frueher abgebrochene Laeufe (Neustart, Absturz) melden und im Verlauf festhalten
try {
    foreach ($ab in @(Resolve-HMSbAbortedRuns $localHist $version)) { Write-HMSbLog "Frueherer Lauf: $($ab.Text) - im Verlauf festgehalten und gemeldet" 'Error' }
} catch { Write-HMSbLog "Pruefung auf abgebrochene Laeufe: $($_.Exception.Message)" 'Warning' }
# --- erledigte Hintergrund-Aufgaben (Server-Backup im Hintergrund) aufraeumen
try { foreach ($x in @(Remove-HMSbStaleOnceTasks)) { Write-HMSbLog "Erledigte Hintergrund-Aufgabe entfernt: $x" 'Info' } } catch { }

# --- Profil (auch nach Umbenennung)
$prof = $null
try {
    $cfg = Get-Content -LiteralPath (Join-Path $cfgDir 'serverbackup.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $name = $ProfileName
    for ($i = 0; $i -lt 20; $i++) {
        $r = @(@($cfg.Renames) | Where-Object { $_ -and "$($_.Old)" -eq $name })[0]
        if (-not $r) { break }
        $name = "$($r.New)"
    }
    $prof = @(@($cfg.Profiles) | Where-Object { $_ -and "$($_.Name)" -eq $name })[0]
    if ($prof) { $ProfileName = $name }
} catch { }
if (-not $prof) { Add-HMSbTaskError "Profil '$ProfileName' nicht gefunden (Config\serverbackup.json)"; exit 2 }
# laeuft dieses Profil schon (Oberflaeche, Hintergrund, anderer Zeitplan)? Dann nicht doppelt
try {
    $live = @(Get-HMSbAliveRuns (Split-Path $localHist -Parent) $ProfileName)
    if ($live.Count) {
        # kein Fehler der Sicherung (das Profil wird gerade gesichert): gelb, ohne Verlaufseintrag (zaehlt nie als Sicherung oder Fehler)
        $txt = "Uebersprungen: Profil laeuft bereits (seit $(try { ([datetime]$live[0].Started).ToString('dd.MM. HH:mm') } catch { '?' }), $(if ("$($live[0].Kind)" -eq 'Zeitplan') { 'Zeitplan/Hintergrund' } else { 'in HUMig' }), Platte $($live[0].Disk)) - nicht doppelt gestartet"
        Write-HMSbLog $txt 'Warning'
        Write-HMSbEvent 'Warning' "Geplantes Server-Backup '$ProfileName' auf ${env:COMPUTERNAME}: $txt`nProtokoll: $($script:TaskLog)`nHUMig $version"
        try { $n = Send-HMNotify -Title "Server-Backup '$ProfileName' auf $env:COMPUTERNAME - uebersprungen" -Lines @($txt) -Level 'Warning' -Category 'SbWarning' -SbProfile $ProfileName; if ($n) { Write-HMSbLog $n 'Info' } } catch { }
        exit 1
    }
} catch { Write-HMSbLog "Pruefung auf laufende Sicherung: $($_.Exception.Message)" 'Warning' }
$prefix = "$($prof.DiskPrefix)".Trim()
if (-not $prefix) { $prefix = 'HUMIG-' + (ConvertTo-HMSbSafeName $ProfileName).ToUpper() }

# --- Platte des Profils suchen
$dl = Get-HMSbDriveList
foreach ($m in @($dl.Messages)) { if ($m) { Write-HMSbLog $m 'Warning' } }
$drives = @(@($dl.Drives) | Where-Object { $_ -and (Test-HMSbLabelMatch "$($_.Label)" $prefix) })
if ($DiskLabel) {
    # bestimmte Platte (in der Oberflaeche gewaehlt): nur diese - nie eine andere Platte des Profils
    if (-not (Test-HMSbDiskLabel $DiskLabel)) { Add-HMSbTaskError "Ungueltige Platten-Bezeichnung '$DiskLabel'"; exit 2 }
    $drives = @($drives | Where-Object { "$($_.Label)" -ieq $DiskLabel })
    if (-not $drives.Count) { Add-HMSbTaskError "Platte $DiskLabel ist nicht (mehr) angesteckt oder gehoert nicht zum Profil ($prefix-...)"; exit 2 }
}
if (-not $drives.Count) { Add-HMSbTaskError "Keine Platte des Profils angesteckt ($prefix-...)"; exit 2 }
# Rotations-Platten vor Archiv-Platten (<Prefix>-A<n>)
$drives = @(@($drives | Where-Object { -not (Test-HMSbArchiveLabel "$($_.Label)" $prefix) }) + @($drives | Where-Object { Test-HMSbArchiveLabel "$($_.Label)" $prefix }))
if ($drives.Count -gt 1) { Write-HMSbLog "Mehrere Platten des Profils angesteckt - verwendet wird $($drives[0].Letter): $($drives[0].Label)" 'Warning' }
$d = $drives[0]
if (Test-HMSbArchiveLabel "$($d.Label)" $prefix) { Write-HMSbLog "Archiv-Platte $($d.Label) wird verwendet - Archiv-Platten nach der Sicherung abziehen und getrennt lagern." 'Warning' }

$list = @(if ($VMs) { $VMs -split '\|' } else { @($prof.VMs) }) | Where-Object { "$_".Trim() } | ForEach-Object { "$_".Trim() }
$volList = @(if ($Volumes) { $Volumes -split '\|' } else { @($prof.Volumes) }) | Where-Object { "$_".Trim() } | ForEach-Object { "$_".Trim() }
if ($Explicit) {
    $list = @($VMs -split '\|' | Where-Object { "$_".Trim() } | ForEach-Object { "$_".Trim() })
    $volList = @($Volumes -split '\|' | Where-Object { "$_".Trim() } | ForEach-Object { "$_".Trim() })
} elseif ($VMs -and -not $Volumes) { $volList = @() }   # aeltere Zeitplaene (nur VMs angegeben)
# --- Neustart ausstehend? (Windows Update startet sonst evtl. mitten in der Sicherung neu)
$pend = Format-HMSbPendingReboot @(Get-HMSbPendingReboot) (Get-HMSbActiveHours)
if ($pend) {
    if ($prof.RebootPendingSkip -eq $true) { Add-HMSbTaskError "Nicht gestartet: $pend (Profil-Einstellung: bei ausstehendem Neustart nicht sichern)" "$($d.Label)"; exit 2 }
    Write-HMSbLog "$pend - Sicherung wird trotzdem gestartet" 'Warning'
    try { $n = Send-HMNotify -Title "Server-Backup '$ProfileName' auf $env:COMPUTERNAME - Neustart ausstehend" -Lines @($pend, 'Die Sicherung wird trotzdem gestartet. Bricht sie durch den Neustart ab, meldet HUMig das beim naechsten Start.') -Level 'Warning' -Category 'SbWarning' -SbProfile $ProfileName; if ($n) { Write-HMSbLog $n 'Info' } } catch { }
}
$ctx = @{
    Scheduled = $true
    Profile = $ProfileName; DiskPrefix = $prefix; Drive = $d.Letter; DiskLabel = $d.Label; DiskSerial = $d.Serial
    VMs = @($list); Volumes = @($volList); HostConfig = [bool]$HostConfig; HostSystem = [bool]$HostSystem; Verify = -not $NoVerify
    LocalHistory = $localHist; LocalHealth = $localHealth; LocalReportDir = $repDir; Version = $version; ProfileData = $prof; TaskLog = (Split-Path $script:TaskLog -Leaf)
    After = (Get-HMSbAfterMode $prof "$($d.Label)")
    Export = (Get-HMSbExportOptions $prof)
}
if ($ctx.Export) { Write-HMSbLog "Nach der Sicherung: VM-Export $(@($ctx.Export.VMs) -join ', ') -> $(Get-HMSbExportBase $ctx.Export.Folder $d.Letter) (behalten: $($ctx.Export.Keep))" 'Info' }
if ($ctx.After) { Write-HMSbLog "Nach der Sicherung: Platte $($d.Label) $(Format-HMSbAfterMode $ctx.After)" 'Info' }
$q = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue))
$Job = [hashtable]::Synchronized(@{ Log = $q; Progress = 0; Status = ''; Cancel = $false; Done = $false; Result = $null; Process = $null; Error = $null; Started = (Get-Date) })
try {
    Start-HMServerBackup -Ctx $ctx -Job $Job
} catch {
    Add-HMSbTaskError "Abbruch: $($_.Exception.Message)" "$($d.Label)"
    exit 2
}
$st = "$($Job.Result.Status)"
# Benachrichtigung (Teams, wenn auf diesem Server eingetragen): Fehler/Warnung, Plattenzustand, Erinnerungen Plattenwechsel/Archiv
try {
    $rem = @(Get-HMSbReminders $prof $localHist)
    # eine Karte je Lauf aus den eingeschalteten Kategorien (Einstellungen > Allgemein > Teams-Benachrichtigung)
    # je Ziel (Chat/Kanal) mit dessen Kategorien - nicht jeder bekommt alles
    $nc = Get-HMNotifyConfig
    if ($nc.Configured) {
        foreach ($tg in @($nc.Targets | Where-Object { $_ })) {
            if (-not (Test-HMNotifySbProfile $tg $ProfileName)) { Write-HMSbLog "Teams-Benachrichtigung '$($tg.Name)': gilt nicht fuer Profil '$ProfileName'" 'Info'; continue }
            $msg = New-HMSbNotifyMessage -Result $Job.Result -ProfileName $ProfileName -Disk "$($d.Label)" -Reminders $rem -Cats $tg.Cats
            if ($msg) {
                $r = Send-HMTeamsMessage -Title $msg.Title -Lines $msg.Lines -Level $msg.Level -Url $tg.Url
                Write-HMSbLog "Teams-Benachrichtigung '$($tg.Name)': $(if ($r) { $r } else { 'gesendet' })" 'Info'
            } else { Write-HMSbLog "Teams-Benachrichtigung '$($tg.Name)': nichts zu melden (Kategorien ausgeschaltet)" 'Info' }
        }
    } elseif ($nc.Error) { Write-HMSbLog "Teams-Benachrichtigung: Webhook nicht lesbar: $($nc.Error)" 'Warning' }
} catch { Write-HMSbLog "Benachrichtigung: $($_.Exception.Message)" 'Warning' }
Write-HMSbLog "Ende - Status $st" $(if ($st -eq 'OK') { 'Success' } elseif ($st -eq 'Warning') { 'Warning' } else { 'Error' })
if ($st -eq 'OK') { exit 0 } elseif ($st -eq 'Warning') { exit 1 } else { exit 2 }
