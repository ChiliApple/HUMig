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
#>
param(
    [Parameter(Mandatory)][string]$ProfileName,
    [string]$VMs = '',              # VM-Namen getrennt durch |  (leer = VMs aus dem Profil)
    [string]$Volumes = '',          # Laufwerke getrennt durch | (z.B. C:|D:), leer = Laufwerke aus dem Profil
    [switch]$HostConfig,
    [switch]$HostSystem,
    [switch]$NoVerify,
    [switch]$Explicit               # VMs/Laufwerke genau wie angegeben (leer = keine), sonst leer = aus dem Profil
)
$ErrorActionPreference = 'Stop'
$root   = Split-Path $PSScriptRoot -Parent
$cfgDir = Join-Path $root 'Config'
$repDir = Join-Path $root 'Logs\ServerBackup'
try { New-Item -ItemType Directory -Path $repDir -Force | Out-Null } catch { }
$script:TaskLog = Join-Path $repDir ('Aufgabe_{0}_{1}.log' -f (Get-Date -Format 'yyyy-MM-dd_HHmm'), ($ProfileName -replace '[^\w\-]', '_'))

. (Join-Path $PSScriptRoot 'ServerBackup-Engine.ps1')

# Protokoll direkt in die Datei (ueberschreibt die Queue-Variante der Engine)
function Write-HMSbLog([string]$Msg, [string]$Lvl = 'Info') {
    Add-HMSbRunLog $Msg $Lvl
    try { Add-Content -LiteralPath $script:TaskLog -Value ('{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Lvl.ToUpper(), $Msg) -Encoding UTF8 } catch { }
}

$localHist = Join-Path $cfgDir 'ServerBackup\history.json'
$version = ''
try { if ((Get-Content -LiteralPath (Join-Path $root 'HUMig.ps1') -Raw -Encoding UTF8) -match "\`$script:Version\s*=\s*'([0-9\.]+)'") { $version = $Matches[1] } } catch { }

function Add-HMSbTaskError([string]$Note, [string]$Disk = '') {
    Write-HMSbLog $Note 'Error'
    try {
        Add-HMSbHistory $localHist ([pscustomobject][ordered]@{
            Date = (Get-Date).ToString('yyyy-MM-dd HH:mm'); Profile = $ProfileName; Host = $env:COMPUTERNAME; Disk = $Disk; DiskSerial = ''
            VMs = ($VMs -replace '\|', ', '); Status = 'Error'; Minutes = 0; SizeGB = 0; VersionId = ''; HostConfig = $false; HostSystem = $false
            HostVersionId = ''; Note = "Geplante Aufgabe: $Note"; Tool = "HUMig $version"
        })
    } catch { }
}

Write-HMSbLog "Geplantes Server-Backup - Profil '$ProfileName' - Host $env:COMPUTERNAME - Konto $env:USERDOMAIN\$env:USERNAME - HUMig $version" 'Header'

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
$prefix = "$($prof.DiskPrefix)".Trim()
if (-not $prefix) { $prefix = 'HUMIG-' + (ConvertTo-HMSbSafeName $ProfileName).ToUpper() }

# --- Platte des Profils suchen
$dl = Get-HMSbDriveList
foreach ($m in @($dl.Messages)) { if ($m) { Write-HMSbLog $m 'Warning' } }
$drives = @(@($dl.Drives) | Where-Object { $_ -and (Test-HMSbLabelMatch "$($_.Label)" $prefix) })
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
$ctx = @{
    Profile = $ProfileName; DiskPrefix = $prefix; Drive = $d.Letter; DiskLabel = $d.Label; DiskSerial = $d.Serial
    VMs = @($list); Volumes = @($volList); HostConfig = [bool]$HostConfig; HostSystem = [bool]$HostSystem; Verify = -not $NoVerify
    LocalHistory = $localHist; LocalReportDir = $repDir; Version = $version; ProfileData = $prof
    After = (Get-HMSbAfterMode $prof "$($d.Label)")
}
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
Write-HMSbLog "Ende - Status $st" $(if ($st -eq 'OK') { 'Success' } elseif ($st -eq 'Warning') { 'Warning' } else { 'Error' })
if ($st -eq 'OK') { exit 0 } elseif ($st -eq 'Warning') { exit 1 } else { exit 2 }
