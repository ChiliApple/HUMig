#Requires -Version 5.1
<#
.SYNOPSIS
    Server-Backup (Hyper-V): virtuelle Computer mit der Windows Server-Sicherung (wbadmin) auf wechselnde USB-Platten sichern,
    Host-Konfiguration exportieren (virtuelle Switches, VLANs, Netzwerk, VM-Einstellungen + Wiederherstellungs-Skript),
    optional Host-System (Bare-Metal, -allCritical), Pruefung der Sicherung, Verlauf/Statistik auf Platte und im Tool-Ordner.
.NOTES
    Zielmaschine: Hyper-V-Host (Windows Server mit Feature "Windows Server-Sicherung"), HUMig als Administrator.
    Wird im UI-Thread (Hilfsfunktionen, Invoke-AsyncCommand) und im Hintergrund-Runspace (Start-HMServerBackup) geladen.
#>

# Dauer lesbar: "45 s", "3 min 20 s", "12 min", "6 h 12 min" - Wert: TimeSpan oder Minuten (Zahl)
function Format-HMDuration($Value) {
    if ($null -eq $Value -or "$Value" -eq '') { return '' }
    try { $ts = if ($Value -is [TimeSpan]) { $Value } else { [TimeSpan]::FromMinutes([double]$Value) } } catch { return "$Value" }
    $s = [long][Math]::Round($ts.TotalSeconds)
    if ($s -lt 60) { return "$s s" }
    $h = [long][Math]::Floor($s / 3600); $m = [long][Math]::Floor(($s % 3600) / 60); $sec = $s % 60
    if ($h -gt 0) { return "$h h $m min" }
    if ($m -lt 10 -and $sec) { return "$m min $sec s" }
    return "$m min"
}
$script:SbDirName = 'HUMig-ServerBackup'
$script:SbJob = $null

$script:SbRunLog = $null
function Add-HMSbRunLog([string]$Msg, [string]$Lvl) {
    if ($null -ne $script:SbRunLog) { $script:SbRunLog.Add(('{0} [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Lvl.ToUpper(), $Msg)) }
}
function Write-HMSbLog([string]$Msg, [string]$Lvl = 'Info') {
    Add-HMSbRunLog $Msg $Lvl
    if ($script:SbJob) { $script:SbJob.Log.Enqueue(@{ Msg = $Msg; Lvl = $Lvl }) }
}

function Get-HMSbOemEncoding {
    try { return [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage) } catch { return [System.Text.Encoding]::Default }
}

function ConvertTo-HMSbPsString([string]$s) { return "'" + ("$s" -replace "'", "''") + "'" }

# PartitionStyle kommt je nach Umgebung als Text (RAW/MBR/GPT) oder als Zahl (0/1/2)
function ConvertTo-HMSbPartStyle($v) {
    switch ("$v") { '0' { return 'RAW' } '1' { return 'MBR' } '2' { return 'GPT' } default { return "$v" } }
}

function ConvertTo-HMSbSafeName([string]$s) {
    $r = ("$s" -replace '[^A-Za-z0-9_\-]', '_').Trim('_')
    if (-not $r) { $r = 'Profil' }
    return $r
}

# Voraussetzungen: Hyper-V-Modul, wbadmin, Feature Windows Server-Sicherung
function Test-HMSbPrereq {
    $r = [ordered]@{ HyperV = $false; Wbadmin = $false; Feature = $null; IsServer = $false }
    $r.HyperV = [bool](Get-Command Get-VM -ErrorAction SilentlyContinue)
    $r.Wbadmin = Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32\wbadmin.exe')
    try { $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop; $r.IsServer = ([int]$os.ProductType -ne 1) } catch { }
    if (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue) {
        try { $f = Get-WindowsFeature -Name Windows-Server-Backup -ErrorAction Stop; if ($f) { $r.Feature = [bool]$f.Installed } } catch { }
    }
    return [pscustomobject]$r
}

# Echter Hyper-V-Host? (Dienst vmms laeuft - nur die Verwaltungstools reichen nicht)
function Test-HMSbHyperVHost {
    $s = Get-Service -Name vmms -ErrorAction SilentlyContinue
    return [bool]($s -and "$($s.Status)" -eq 'Running')
}

# Lokale Laufwerke dieses Servers (fest, NTFS/ReFS, mit Buchstaben, keine USB-Platten)
function Get-HMSbVolumeList {
    $out = @()
    foreach ($v in @(Get-Volume -ErrorAction Stop | Where-Object { $_.DriveLetter -and "$($_.DriveType)" -match '^(Fixed|3)$' -and "$($_.FileSystem)" -match '^(NTFS|ReFS)$' } | Sort-Object DriveLetter)) {
        $L = "$($v.DriveLetter)".ToUpper()
        $bus = ''
        try { $bus = "$((Get-Partition -DriveLetter $L -ErrorAction Stop | Get-Disk -ErrorAction Stop).BusType)" } catch { }
        if ($bus -match '^(USB|7)$') { continue }
        $out += [pscustomobject]@{ Letter = "${L}:"; Label = "$($v.FileSystemLabel)"; FileSystem = "$($v.FileSystem)"; Size = [long]$v.Size; Used = [long]($v.Size - $v.SizeRemaining); System = ("$env:SystemDrive".ToUpper() -eq "${L}:") }
    }
    return ,$out
}

# Alles fuer die Anzeige im Reiter: Hyper-V ja/nein, VMs, lokale Laufwerke
function Get-HMSbSources {
    $hv = Test-HMSbHyperVHost
    $vms = @()
    $err = ''
    if ($hv) { try { $vms = Get-HMSbVmList; $vms = @($vms) } catch { $err = $_.Exception.Message } }
    $vols = @()
    try { $vols = Get-HMSbVolumeList; $vols = @($vols) } catch { if (-not $err) { $err = $_.Exception.Message } }
    return [pscustomobject]@{ HyperV = $hv; VMs = $vms; Volumes = $vols; Error = $err }
}

# Virtuelle Computer des Hosts mit Groesse der virtuellen Festplatten
# Hyper-V-Meldungen, warum eine VM nicht online (Hotbackup) gesichert werden kann - Protokoll Hyper-V-Worker-Admin
# Rueckgabe: Hashtable VM-Name -> @{ Messages = @(...); Dynamic = $true/$false; Last = [datetime] }
function Get-HMSbOfflineReasons {
    param([datetime]$Since = (Get-Date).AddDays(-90), [datetime]$Until = (Get-Date).AddMinutes(1))
    $map = @{}
    $ev = @()
    try {
        $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Hyper-V-Worker-Admin'; ProviderName = 'Microsoft-Windows-Hyper-V-Integration'; Level = 2, 3; StartTime = $Since; EndTime = $Until } -MaxEvents 3000 -ErrorAction Stop)
    } catch { return $map }
    foreach ($e in $ev) {
        $m = "$($e.Message)".Trim()
        if ($m -notmatch '(?i)backup|sicherung') { continue }
        if ($m -notmatch '^(.+?):\s') { continue }
        $n = $Matches[1].Trim()
        if (-not $map.ContainsKey($n)) { $map[$n] = @{ Messages = @(); Dynamic = $false; Last = $e.TimeCreated } }
        $txt = ($m.Substring($n.Length + 1).Trim() -replace '\s*\((ID des virtuellen Computers|virtual machine ID)[^)]*\)', '' -replace '\s[0-9A-Fa-f]{8}-[0-9A-Fa-f\-]{27}\s', ' ')
        if ($map[$n].Messages -notcontains $txt) { $map[$n].Messages += $txt }
        if ($m -match '(?i)dynamisch|dynamic') { $map[$n].Dynamic = $true }
        if ($e.TimeCreated -gt $map[$n].Last) { $map[$n].Last = $e.TimeCreated }
    }
    return $map
}
function Get-HMSbOfflineHintText($Info) {
    if (-not $Info) { return '' }
    if ($Info.Dynamic) { return 'dynamische Datentraeger im Gast' }
    return (@($Info.Messages) | Select-Object -First 1)
}

function Get-HMSbVmList {
    $list = @()
    $reasons = Get-HMSbOfflineReasons
    foreach ($vm in @(Get-VM -ErrorAction Stop | Sort-Object Name)) {
        $size = [long]0; $paths = @()
        foreach ($d in @(Get-VMHardDiskDrive -VM $vm -ErrorAction SilentlyContinue)) {
            if ($d.Path) {
                $paths += "$($d.Path)"
                try { $size += [long](Get-Item -LiteralPath $d.Path -ErrorAction Stop).Length } catch { }
            }
        }
        $cp = 0
        try { $cp = @(Get-VMSnapshot -VM $vm -ErrorAction SilentlyContinue).Count } catch { }
        $list += [pscustomobject]@{
            Name = "$($vm.Name)"; State = "$($vm.State)"; SizeBytes = $size; Checkpoints = $cp
            Paths = $paths; VmPath = "$($vm.Path)"; ConfigPath = "$($vm.ConfigurationLocation)"; Id = "$($vm.Id)"
            OfflineHint = (Get-HMSbOfflineHintText $reasons["$($vm.Name)"])
            OfflineDetail = $(if ($reasons["$($vm.Name)"]) { (@($reasons["$($vm.Name)"].Messages) -join ' | ') } else { '' })
        }
    }
    return ,$list
}

# Moegliche Ziel-Laufwerke (nicht System/Start), offline geschaltete USB-Platten werden online geschaltet
# -KeepHumigOffline: von HUMig nach der Sicherung offline geschaltete Platten bleiben offline (automatisches Einlesen)
function Get-HMSbDriveList([switch]$KeepHumigOffline) {
    $msgs = @()
    $marks = @(Get-HMSbOfflineMarks)
    $marksNew = @($marks)
    foreach ($d in @(Get-Disk -ErrorAction SilentlyContinue | Where-Object { "$($_.BusType)" -match '^(USB|7)$' })) {
        $k = Get-HMSbDiskKey $d
        $m = $null
        if ($k) { $m = @($marks | Where-Object { "$_".Split('|')[0] -eq $k })[0] }
        if (-not $d.IsOffline) { if ($m) { $marksNew = @($marksNew | Where-Object { $_ -ne $m }) }; continue }
        if ($KeepHumigOffline -and $m) { $msgs += "USB-Platte $("$m".Split('|')[1]) (Datentraeger $($d.Number)) wurde nach der Sicherung von HUMig offline geschaltet und bleibt offline - ""Aktualisieren"" schaltet sie wieder online."; continue }
        try {
            Set-Disk -Number $d.Number -IsOffline $false -ErrorAction Stop
            $msgs += "USB-Platte $($d.Number) ($($d.FriendlyName)) war offline - online geschaltet"
            if ($m) { $marksNew = @($marksNew | Where-Object { $_ -ne $m }) }
        } catch { $msgs += "USB-Platte $($d.Number) ist offline und konnte nicht online geschaltet werden: $($_.Exception.Message)" }
    }
    if ($marksNew.Count -ne $marks.Count) { Set-HMSbOfflineMarks $marksNew }
    $sysLetter = "$env:SystemDrive".TrimEnd(':').ToUpper()
    $out = @()
    foreach ($v in @(Get-Volume -ErrorAction Stop | Where-Object { $_.DriveLetter -and "$($_.DriveType)" -match '^(Fixed|Removable|2|3)$' } | Sort-Object DriveLetter)) {
        $L = "$($v.DriveLetter)".ToUpper()
        if ($L -eq $sysLetter) { continue }
        $disk = $null
        try { $disk = Get-Partition -DriveLetter $L -ErrorAction Stop | Get-Disk -ErrorAction Stop } catch { }
        if ($disk -and ($disk.IsBoot -or $disk.IsSystem)) { continue }
        $out += [pscustomobject]@{
            Letter = $L; Label = "$($v.FileSystemLabel)"; FileSystem = "$($v.FileSystem)"; Size = [long]$v.Size; Free = [long]$v.SizeRemaining
            Bus = $(if ($disk) { "$($disk.BusType)" } else { '' }); DiskNumber = $(if ($disk) { [int]$disk.Number } else { -1 })
            Model = $(if ($disk) { "$($disk.FriendlyName)".Trim() } else { '' }); Serial = $(if ($disk) { "$($disk.SerialNumber)".Trim() } else { '' })
        }
    }
    return [pscustomobject]@{ Drives = $out; Messages = $msgs }
}

# Datentraeger-Nummern, auf denen Dateien von Hyper-V-VMs liegen (Konfiguration, Snapshots, Smart Paging, virtuelle Platten).
# Zuordnung ueber die Zugriffspfade der Partitionen (Laufwerksbuchstabe, Bereitstellungspunkt, \\?\Volume{...}\) - laengster passender Pfad.
# Ist Hyper-V installiert, aber die VM-Liste nicht lesbar: Fehler (nie "keine VMs" annehmen). Ohne Hyper-V: leere Liste.
function Get-HMSbVmDiskNumbers {
    if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) { return }
    $paths = @()
    try {
        foreach ($vm in @(Get-VM -ErrorAction Stop)) {
            $paths += @("$($vm.Path)", "$($vm.ConfigurationLocation)", "$($vm.SnapshotFileLocation)", "$($vm.SmartPagingFilePath)")
            $paths += @(Get-VMHardDiskDrive -VM $vm -ErrorAction Stop | ForEach-Object { "$($_.Path)" })
        }
    } catch { throw "VM-Liste nicht lesbar ($($_.Exception.Message)) - zur Sicherheit abgebrochen (Platten mit VM-Dateien waeren nicht erkennbar)" }
    $map = @()
    foreach ($p in @(Get-Partition -ErrorAction Stop)) {
        foreach ($ap in @($p.AccessPaths)) { if ("$ap") { $map += [pscustomobject]@{ Path = "$ap".TrimEnd('\') + '\'; Disk = [int]$p.DiskNumber } } }
    }
    $nums = @()
    foreach ($x in @($paths | Where-Object { "$_".Trim() } | Select-Object -Unique)) {
        $f = "$x".TrimEnd('\') + '\'
        $hit = @($map | Where-Object { $f.StartsWith($_.Path, [StringComparison]::OrdinalIgnoreCase) } | Sort-Object { $_.Path.Length } -Descending)[0]
        if ($hit -and $nums -notcontains $hit.Disk) { $nums += $hit.Disk }
    }
    return $nums
}
# Merkmale einer Platte zum Wiedererkennen (Nummern koennen nach dem Umstecken wechseln)
function Get-HMSbDiskIdentity($d) { return ('{0}|{1}|{2}|{3}' -f "$($d.UniqueId)".Trim(), "$($d.SerialNumber)".Trim(), [long]$d.Size, "$($d.FriendlyName)".Trim()) }

# USB-Datentraeger fuer "Platte einrichten" (nie System/Start, nie Platten mit VM-Dateien)
function Get-HMSbDiskList {
    $vmDisks = @(Get-HMSbVmDiskNumbers)
    $out = @()
    foreach ($d in @(Get-Disk -ErrorAction Stop | Sort-Object Number)) {
        if ($d.IsBoot -or $d.IsSystem) { continue }
        if ("$($d.BusType)" -notmatch '^(USB|7)$') { continue }
        $labels = @(); $letters = @()
        try {
            foreach ($p in @(Get-Partition -DiskNumber $d.Number -ErrorAction Stop)) {
                if ($p.DriveLetter) { $letters += "$($p.DriveLetter)".ToUpper() }
                try { $v = $p | Get-Volume -ErrorAction Stop; if ($v) { $labels += ('{0}{1}' -f $(if ($v.DriveLetter) { "$($v.DriveLetter): " } else { '' }), "$($v.FileSystemLabel)") } } catch { }
            }
        } catch { }
        if ($vmDisks -contains [int]$d.Number) { continue }
        $out += [pscustomobject]@{
            Id = (Get-HMSbDiskIdentity $d); Number = [int]$d.Number; Model = "$($d.FriendlyName)".Trim(); Serial = "$($d.SerialNumber)".Trim(); Bus = "$($d.BusType)"
            SizeBytes = [long]$d.Size; Style = (ConvertTo-HMSbPartStyle $d.PartitionStyle); Offline = [bool]$d.IsOffline; Volumes = ($labels -join ', ')
        }
    }
    return ,$out
}

# USB-Platte neu einrichten: ALLE Daten loeschen, GPT, NTFS 64K, Bezeichnung
# -ExpectId: Merkmale aus der angezeigten Liste (Get-HMSbDiskList). Direkt vor dem Loeschen wird erneut geprueft, dass unter der
# Nummer noch genau diese Platte steckt und keine VM-Dateien auf ihr liegen - sonst Abbruch.
function Initialize-HMSbDisk([int]$Number, [string]$Label, [string]$Profile = '', [string]$ExpectId = '') {
    if ($Label -notmatch '^[A-Za-z0-9_\-]{1,32}$') { throw "Ungueltige Bezeichnung '$Label' (max. 32 Zeichen: A-Z, 0-9, - und _)" }
    if (-not "$ExpectId".Trim()) { throw 'Platte nicht eindeutig bestimmt (Merkmale fehlen) - abgebrochen' }
    $check = {
        $x = Get-Disk -Number $Number -ErrorAction Stop
        if ($x.IsBoot -or $x.IsSystem) { throw "Datentraeger $Number ist System-/Startdatentraeger - abgebrochen" }
        if ("$($x.BusType)" -notmatch '^(USB|7)$') { throw "Datentraeger $Number ist kein USB-Datentraeger ($($x.BusType)) - abgebrochen" }
        if ((Get-HMSbDiskIdentity $x) -ne $ExpectId) { throw "Unter Nummer $Number steckt inzwischen eine andere Platte ($("$($x.FriendlyName)".Trim()), SN $("$($x.SerialNumber)".Trim())) - abgebrochen, nichts geloescht. Liste neu oeffnen." }
        if (@(Get-HMSbVmDiskNumbers) -contains $Number) { throw "Auf Datentraeger $Number liegen Dateien von Hyper-V-VMs - abgebrochen, nichts geloescht" }
        return $x
    }
    $d = & $check
    if ($d.IsOffline) { Set-Disk -Number $Number -IsOffline $false -ErrorAction Stop }
    if ($d.IsReadOnly) { Set-Disk -Number $Number -IsReadOnly $false -ErrorAction Stop }
    # nach dem Online-Schalten sind Volumes sichtbar: unmittelbar vor dem Loeschen nochmals pruefen (Platte + VM-Dateien)
    $d = & $check
    if ((ConvertTo-HMSbPartStyle $d.PartitionStyle) -ne 'RAW') { Clear-Disk -Number $Number -RemoveData -RemoveOEM -Confirm:$false -ErrorAction Stop }
    $d = Get-Disk -Number $Number -ErrorAction Stop
    if ((ConvertTo-HMSbPartStyle $d.PartitionStyle) -eq 'RAW') { Initialize-Disk -Number $Number -PartitionStyle GPT -ErrorAction Stop }
    $p = New-Partition -DiskNumber $Number -UseMaximumSize -AssignDriveLetter -ErrorAction Stop
    $v = $p | Format-Volume -FileSystem NTFS -NewFileSystemLabel $Label -AllocationUnitSize 65536 -Confirm:$false -Force -ErrorAction Stop
    $p = Get-Partition -DiskNumber $Number -PartitionNumber $p.PartitionNumber -ErrorAction Stop
    $L = "$($p.DriveLetter)"
    if ($L) {
        try {
            $dir = "${L}:\$($script:SbDirName)"
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            [pscustomobject]@{ Label = $Label; Profile = $Profile; Created = (Get-Date).ToString('yyyy-MM-dd HH:mm'); Host = $env:COMPUTERNAME; Model = "$($d.FriendlyName)".Trim(); Serial = "$($d.SerialNumber)".Trim() } |
                ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dir 'disk.json') -Encoding UTF8
        } catch { }
    }
    return [pscustomobject]@{ Letter = $L; Label = $Label; SizeBytes = [long]$v.Size }
}

# Vorhandene USB-Platte UEBERNEHMEN (nichts loeschen): groesstes NTFS/ReFS-Volume mit Laufwerksbuchstaben, Belegung, Ordner,
# Konflikte: Windows-Sicherung dieses Hosts schon auf der Platte (gleicher Ordnername!), frueher von HUMig anders benannt
function Get-HMSbDiskVolumeInfo([int]$Number) {
    $d = Get-Disk -Number $Number -ErrorAction Stop
    if ($d.IsBoot -or $d.IsSystem) { throw "Datentraeger $Number ist System-/Startdatentraeger" }
    if ("$($d.BusType)" -notmatch '^(USB|7)$') { throw "Datentraeger $Number ist kein USB-Datentraeger ($($d.BusType))" }
    if ($d.IsOffline) { throw "Datentraeger $Number ist offline - zuerst online schalten (Aktualisieren)" }
    $vols = @(foreach ($p in @(Get-Partition -DiskNumber $Number -ErrorAction Stop)) {
            if (-not $p.DriveLetter) { continue }
            try { $v = $p | Get-Volume -ErrorAction Stop; if ($v) { $v } } catch { }
        })
    $ok = @($vols | Where-Object { "$($_.FileSystem)" -match '^(NTFS|ReFS)$' } | Sort-Object Size -Descending)
    if (-not $ok.Count) { throw "Datentraeger $Number hat kein NTFS/ReFS-Volume mit Laufwerksbuchstaben ($(@($vols | ForEach-Object { "$($_.DriveLetter): $($_.FileSystem)" }) -join ', ')) - dann nur 'Einrichten' (loescht alles)" }
    $v = $ok[0]
    $L = "$($v.DriveLetter)".ToUpper()
    $dirs = @(Get-ChildItem -LiteralPath "${L}:\" -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin @('System Volume Information', '$RECYCLE.BIN') } | Sort-Object Name | ForEach-Object { $_.Name })
    $wb = @(Get-ChildItem -LiteralPath "${L}:\WindowsImageBackup" -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    $prev = $null
    try { $prev = Get-Content -LiteralPath "${L}:\$($script:SbDirName)\disk.json" -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json } catch { }
    return [pscustomobject]@{
        Number = $Number; Letter = $L; Label = "$($v.FileSystemLabel)"; FileSystem = "$($v.FileSystem)"; SizeBytes = [long]$v.Size; FreeBytes = [long]$v.SizeRemaining
        Folders = $dirs; OtherVolumes = [math]::Max(0, $vols.Count - 1); Model = "$($d.FriendlyName)".Trim(); Serial = "$($d.SerialNumber)".Trim()
        WbHosts = $wb; WbThisHost = ($wb -contains "$env:COMPUTERNAME"); Host = "$env:COMPUTERNAME"
        PrevLabel = $(if ($prev) { "$($prev.Label)" } else { '' }); PrevProfile = $(if ($prev) { "$($prev.Profile)" } else { '' }); PrevHost = $(if ($prev) { "$($prev.Host)" } else { '' })
    }
}
# Bezeichnung schon an einem anderen angeschlossenen Laufwerk vergeben?
function Test-HMSbLabelInUse([string]$Label, [string]$ExceptLetter) {
    return @(Get-Volume -ErrorAction SilentlyContinue | Where-Object { "$($_.FileSystemLabel)" -ieq $Label -and "$($_.DriveLetter)" -ine $ExceptLetter } | ForEach-Object { "$(if ($_.DriveLetter) { "$($_.DriveLetter):" } else { '(ohne Buchstabe)' })" })
}
# Nur die Bezeichnung des Volumes aendern + Kennzeichnung im Ordner HUMig-ServerBackup (Daten bleiben unveraendert)
function Rename-HMSbDiskVolume([int]$Number, [string]$Letter, [string]$Label, [string]$Profile = '') {
    if ($Label -notmatch '^[A-Za-z0-9_\-]{1,32}$') { throw "Ungueltige Bezeichnung '$Label' (max. 32 Zeichen: A-Z, 0-9, - und _)" }
    $i = Get-HMSbDiskVolumeInfo $Number
    if ($i.Letter -ne "$Letter".ToUpper()) { throw "Laufwerk ${Letter}: gehoert nicht (mehr) zu Datentraeger $Number - Liste neu oeffnen" }
    $dup = @(Test-HMSbLabelInUse $Label $i.Letter)
    if ($dup.Count) { throw "Bezeichnung '$Label' hat schon $($dup -join ', ') - andere Bezeichnung waehlen" }
    $old = $i.Label
    Set-Volume -DriveLetter $i.Letter -NewFileSystemLabel $Label -ErrorAction Stop
    try {
        $dir = "$($i.Letter):\$($script:SbDirName)"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        [pscustomobject]@{ Label = $Label; Profile = $Profile; Created = (Get-Date).ToString('yyyy-MM-dd HH:mm'); Host = $env:COMPUTERNAME; Model = $i.Model; Serial = $i.Serial; Shared = $true; OldLabel = $old; Note = 'uebernommen ohne Formatieren - andere Daten auf der Platte bleiben unveraendert' } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dir 'disk.json') -Encoding UTF8
    } catch { }
    return [pscustomobject]@{ Letter = $i.Letter; Label = $Label; OldLabel = $old; FreeBytes = $i.FreeBytes; SizeBytes = $i.SizeBytes }
}

# wbadmin ausfuehren (stdout+stderr), Fortschritt in $Job, Zeilen ins Log
function Invoke-HMSbWbadmin {
    param([string]$Arguments, [string]$Phase = '', [double]$PBase = 0, [double]$PSpan = 100, [string]$LogFile = '', [switch]$Quiet)
    $wb = Join-Path $env:SystemRoot 'System32\wbadmin.exe'
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
    $psi.Arguments = '/d /s /c ""' + $wb + '" ' + $Arguments + ' 2>&1"'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = Get-HMSbOemEncoding
    $lines = New-Object System.Collections.Generic.List[string]
    $p = [System.Diagnostics.Process]::Start($psi)
    if ($script:SbJob -and -not $Quiet) { $script:SbJob.Process = $p }
    $lastPct = -1; $prev = ''
    while ($null -ne ($line = $p.StandardOutput.ReadLine())) {
        $t = $line.Trim()
        if (-not $t) { continue }
        $lines.Add($t)
        if ($Quiet) { continue }
        if ($t -match '(\d{1,3})\s?%') {
            $pct = [Math]::Min(100, [int]$Matches[1])
            if ($script:SbJob) {
                $script:SbJob.Progress = [Math]::Min(100, [int]($PBase + $PSpan * $pct / 100))
                $script:SbJob.Status = "$Phase $pct %"
            }
            if ($pct -ge $lastPct + 10 -or ($pct -eq 100 -and $lastPct -ne 100)) { Write-HMSbLog "  $t"; $lastPct = $pct }
            continue
        }
        if ($t -eq $prev) { continue }
        $prev = $t
        $lvl = 'Info'
        if ($t -match '(?i)fehler|error|fehlgeschlagen|failed|nicht erfolgreich|abgebrochen|aborted') { $lvl = 'Error' }
        elseif ($t -match '(?i)warnung|warning|\(Offline\)') { $lvl = 'Warning' }
        elseif ($t -match '(?i)erfolgreich|successfully') { $lvl = 'Success' }
        Write-HMSbLog "  $t" $lvl
    }
    $p.WaitForExit()
    $code = $p.ExitCode
    if ($script:SbJob -and -not $Quiet) { $script:SbJob.Process = $null }
    if ($LogFile) { try { [System.IO.File]::WriteAllLines($LogFile, $lines.ToArray(), (New-Object System.Text.UTF8Encoding($true))) } catch { } }
    $logs = @()
    foreach ($l in $lines) { foreach ($m in [regex]::Matches($l, '([A-Za-z]:\\[^"]+?\.log)')) { $logs += $m.Groups[1].Value } }
    return [pscustomobject]@{ ExitCode = $code; Lines = $lines.ToArray(); Text = ($lines.ToArray() -join "`r`n"); LogFiles = @($logs | Select-Object -Unique) }
}

# Laeuft am Host schon eine Sicherung/Wiederherstellung? (Get-WBJob + wbadmin-Prozesse mit start ...)
# Rueckgabe: Liste mit Beschreibungen (leer = frei). Die Windows Server-Sicherung kann nur EINEN Vorgang gleichzeitig.
function Get-HMSbBusy {
    $why = @()
    try {
        if (Get-Command Get-WBJob -ErrorAction SilentlyContinue) {
            $j = Get-WBJob -ErrorAction Stop
            if ($j) {
                # JobState-Werte sind nicht dokumentiert - nur eindeutig laufende zaehlen (sonst greift die Wiederholung bei der wbadmin-Meldung)
                $st = "$($j.JobState)"
                if ($st -match '(?i)running|queued|progress') {
                    $why += "Windows Server-Sicherung: $($j.JobType) laeuft$(if ($j.StartTime) { ' seit ' + ([datetime]$j.StartTime).ToString('dd.MM. HH:mm') })$(if ("$($j.CurrentOperation)".Trim()) { ' - ' + "$($j.CurrentOperation)".Trim() })"
                }
            }
        }
    } catch { }
    $procs = @(); try { $procs = @(Get-CimInstance Win32_Process -Filter "Name='wbadmin.exe'" -ErrorAction Stop) } catch { }
    foreach ($p in $procs) {
        $cl = "$($p.CommandLine)"
        if ($cl -notmatch '(?i)\bstart\s+\w+') { continue }
        $own = ''
        try { $o = Invoke-CimMethod -InputObject $p -MethodName GetOwner -ErrorAction Stop; if ($o.User) { $own = " von $($o.Domain)\$($o.User)" } } catch { }
        $t = ''; try { $t = ' seit ' + ([datetime]$p.CreationDate).ToString('dd.MM. HH:mm') } catch { }
        $why += "wbadmin (PID $($p.ProcessId))$own$t`: $(($cl -replace '^.*?wbadmin(\.exe)?"?\s*', '').Trim())"
    }
    # ohne Komma: leer = $null -> Aufrufer immer mit @() zaehlen
    return @($why | Select-Object -Unique)
}
# Warten, bis der Host frei ist (max. $MaxMin Minuten, Abbruch ueber $Job.Cancel). $true = frei
function Wait-HMSbIdle($Job, [int]$MaxMin = 480) {
    $b = Get-HMSbBusy
    if (-not @($b).Count) { return $true }
    Write-HMSbLog "Am Host laeuft bereits eine Sicherung/Wiederherstellung - die Windows Server-Sicherung kann nur einen Vorgang gleichzeitig. HUMig wartet (hoechstens $(Format-HMDuration $MaxMin), Abbrechen jederzeit moeglich):" 'Warning'
    foreach ($x in @($b)) { Write-HMSbLog "  $x" 'Warning' }
    $t0 = Get-Date; $next = 30
    while ($true) {
        for ($i = 0; $i -lt 30; $i++) { if ($Job.Cancel) { return $false }; Start-Sleep -Seconds 2 }
        $el = ((Get-Date) - $t0).TotalMinutes
        $b = Get-HMSbBusy
        if (-not @($b).Count) { Write-HMSbLog "Anderer Vorgang beendet (gewartet $(Format-HMDuration $el)) - HUMig startet" 'Info'; Start-Sleep -Seconds 15; return $true }
        $Job.Status = "Warte auf andere Sicherung ($(Format-HMDuration $el))"
        if ($el -ge $next) { Write-HMSbLog "  wartet noch ($(Format-HMDuration $el)) ..."; $next += 30 }
        if ($el -ge $MaxMin) { Write-HMSbLog "Wartezeit abgelaufen ($(Format-HMDuration $MaxMin)) - der andere Vorgang laeuft noch" 'Error'; return $false }
    }
}
# wbadmin start ... mit Vorab-Pruefung, Warten und bis zu 2 Wiederholungen, wenn wbadmin 'weiterer Vorgang laeuft' meldet
function Invoke-HMSbStart {
    param([string]$Arguments, [string]$Phase = '', [double]$PBase = 0, [double]$PSpan = 100, [string]$LogFile = '', $Job)
    for ($try = 1; $try -le 3; $try++) {
        if (-not (Wait-HMSbIdle $Job)) {
            return [pscustomobject]@{ ExitCode = -3; Lines = @(); Text = 'Ein weiterer Sicherungs- oder Wiederherstellungsvorgang wird ausgefuehrt (Wartezeit abgelaufen oder abgebrochen).'; LogFiles = @(); Busy = $true }
        }
        $r = Invoke-HMSbWbadmin -Arguments $Arguments -Phase $Phase -PBase $PBase -PSpan $PSpan -LogFile $LogFile
        $busy = ($r.ExitCode -ne 0 -and "$($r.Text)" -match '(?i)weiterer Sicherungs|anderer Sicherungs|another backup or recovery|operation is already in progress|bereits ausgef')
        $r | Add-Member -NotePropertyName Busy -NotePropertyValue $busy -Force
        if (-not $busy -or $Job.Cancel -or $try -eq 3) { return $r }
        Write-HMSbLog "wbadmin meldet einen anderen laufenden Vorgang - HUMig wartet und versucht es erneut ($($try + 1). Versuch)" 'Warning'
        for ($i = 0; $i -lt 60; $i++) { if ($Job.Cancel) { return $r }; Start-Sleep -Seconds 2 }
    }
}
$script:HMSbBusyFix = 'Es lief bereits eine andere Sicherung/Wiederherstellung am Host (die Windows Server-Sicherung kann nur einen Vorgang gleichzeitig). Laufenden Vorgang in wbadmin.msc bzw. mit "wbadmin get status" pruefen, Zeitplaene verschiedener Profile am selben Host zeitlich trennen und die Sicherung spaeter erneut starten.'

# Sicherungsversionen auf einem Ziel (wbadmin get versions), neueste zuletzt
function Get-HMSbVersions([string]$Target) {
    $r = Invoke-HMSbWbadmin -Arguments "get versions -backupTarget:$Target" -Quiet
    $list = @(); $cur = $null
    foreach ($t in @($r.Lines)) {
        if ($t -match '^(Sicherungszeit|Backup time)\s*:\s*(.+)$') {
            if ($cur -and $cur.Id) { $list += [pscustomobject]$cur }
            $cur = [ordered]@{ Time = $Matches[2].Trim(); Id = ''; Items = ''; Target = ''; When = [datetime]::MinValue }
            continue
        }
        if (-not $cur) { continue }
        if ($t -match '(\d{2}/\d{2}/\d{4}-\d{2}:\d{2})' -and -not $cur.Id) {
            $cur.Id = $Matches[1]
            try { $cur.When = [datetime]::ParseExact($cur.Id, 'MM/dd/yyyy-HH:mm', [System.Globalization.CultureInfo]::InvariantCulture) } catch { }
        } elseif ($t -match '^(Wiederherstellbar|Can recover)\s*:\s*(.+)$') { $cur.Items = $Matches[2].Trim() }
        elseif ($t -match '^(Sicherungsziel|Backup target|Backup location)\s*:\s*(.+)$') { $cur.Target = $Matches[2].Trim() }
    }
    if ($cur -and $cur.Id) { $list += [pscustomobject]$cur }
    $sorted = @($list | Sort-Object When)
    return [pscustomobject]@{ Versions = $sorted; ExitCode = $r.ExitCode; Text = $r.Text }
}

# Verlauf (JSON-Array) lesen / ergaenzen
function Read-HMSbHistory([string]$Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return ,@() }
    try {
        $j = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        $arr = @($j | ForEach-Object { $_ } | Where-Object { $_ })
        return ,$arr
    } catch { return ,@() }
}
function Add-HMSbHistory([string]$Path, $Entry) {
    $old = Read-HMSbHistory $Path
    $arr = @($old) + @($Entry)
    if ($arr.Count -gt 1000) { $arr = @($arr[($arr.Count - 1000)..($arr.Count - 1)]) }
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    ConvertTo-Json -InputObject @($arr) -Depth 5 | Set-Content -LiteralPath $Path -Encoding UTF8
}

# Eintraege aus einem Verlauf entfernen (Schluessel Datum|Host|Platte), Rueckgabe = Anzahl entfernt
function Remove-HMSbHistory([string]$Path, [string[]]$Keys) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return 0 }
    $k = @{}; foreach ($x in @($Keys)) { if ($x) { $k[$x.ToUpperInvariant()] = $true } }
    $old = Read-HMSbHistory $Path
    $old = @($old)
    $keep = @($old | Where-Object { -not $k.ContainsKey(("$($_.Date)|$($_.Host)|$($_.Disk)").ToUpperInvariant()) })
    $n = $old.Count - $keep.Count
    if ($n -gt 0) { ConvertTo-Json -InputObject @($keep) -Depth 5 | Set-Content -LiteralPath $Path -Encoding UTF8 }
    return $n
}

# Platte gehoert zum Profil, wenn die Bezeichnung = Praefix oder Praefix-<...> ist
function Test-HMSbLabelMatch([string]$Label, [string]$Prefix) {
    if (-not $Label -or -not $Prefix) { return $false }
    return ($Label -ieq $Prefix -or $Label.StartsWith("$Prefix-", [System.StringComparison]::OrdinalIgnoreCase))
}
# Archiv-Platte: Bezeichnung <Prefix>-A<n> (ohne Prefix: jede Bezeichnung, die auf -A<n> endet)
function Test-HMSbArchiveLabel([string]$Label, [string]$Prefix) {
    if (-not $Label) { return $false }
    if ($Prefix) { return ($Label -imatch ('^' + [regex]::Escape($Prefix) + '-A\d+$')) }
    return ($Label -imatch '-A\d+$')
}

# ----------------------------------------------------------------------------
# Nach der Sicherung: Platte auswerfen oder offline schalten
# Je Platte im Profil: DiskAfter = { "<Bezeichnung>": "Eject" | "Offline" }
# Von HUMig offline geschaltete Platten: HKLM\SOFTWARE\HUMig\ServerBackup OfflineDisks ("<UniqueId>|<Bezeichnung>|<Datum>")
# ----------------------------------------------------------------------------
$script:SbRegKey = 'HKLM:\SOFTWARE\HUMig\ServerBackup'
function Get-HMSbAfterMode($Profile, [string]$Label) {
    if (-not $Profile -or -not $Label) { return '' }
    $m = $null
    try { $m = $Profile.DiskAfter } catch { }
    if ($null -eq $m) { return '' }
    $v = ''
    if ($m -is [System.Collections.IDictionary]) { foreach ($k in @($m.Keys)) { if ("$k" -ieq $Label) { $v = "$($m[$k])" } } }
    else { foreach ($pp in @($m.PSObject.Properties)) { if ($pp.Name -ieq $Label) { $v = "$($pp.Value)" } } }
    if ($v -match '^(Eject|Offline)$') { return $v }
    return ''
}
function Format-HMSbAfterMode([string]$Mode) {
    switch ($Mode) { 'Eject' { return 'auswerfen' } 'Offline' { return 'offline schalten' } default { return 'nichts tun' } }
}
function Get-HMSbDiskKey($Disk) {
    $k = "$($Disk.UniqueId)".Trim()
    if (-not $k) { $k = "$($Disk.SerialNumber)".Trim() }
    return $k
}
function Get-HMSbOfflineMarks {
    try { return @(@((Get-ItemProperty -LiteralPath $script:SbRegKey -Name OfflineDisks -ErrorAction Stop).OfflineDisks) | Where-Object { "$_" }) } catch { return @() }
}
function Set-HMSbOfflineMarks([string[]]$List) {
    try {
        $l = @($List | Where-Object { "$_" })
        if (-not (Test-Path -LiteralPath $script:SbRegKey)) { New-Item -Path $script:SbRegKey -Force | Out-Null }
        if ($l.Count) { New-ItemProperty -LiteralPath $script:SbRegKey -Name OfflineDisks -PropertyType MultiString -Value ([string[]]$l) -Force | Out-Null }
        else { Remove-ItemProperty -LiteralPath $script:SbRegKey -Name OfflineDisks -ErrorAction SilentlyContinue }
    } catch { }
}
# USB-Platte sicher entfernen (wie "Auswerfen" im Explorer) ueber CM_Request_Device_Eject - auch ohne Desktop (SYSTEM)
function Invoke-HMSbDiskEject([int]$Number) {
    if (-not ('HMSbEject' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class HMSbEject {
    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)] static extern int CM_Locate_DevNodeW(out uint pdnDevInst, string pDeviceID, int ulFlags);
    [DllImport("cfgmgr32.dll")] static extern int CM_Get_Parent(out uint pdnDevInst, uint dnDevInst, int ulFlags);
    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)] static extern int CM_Request_Device_EjectW(uint dnDevInst, out int pVetoType, StringBuilder pszVetoName, int ulNameLength, int ulFlags);
    static string Request(uint inst) {
        StringBuilder sb = new StringBuilder(260);
        int veto;
        int cr = CM_Request_Device_EjectW(inst, out veto, sb, sb.Capacity, 0);
        if (cr == 0 && veto == 0) return "";
        return "CR " + cr + ", Veto " + veto + (sb.Length > 0 ? " " + sb.ToString() : "");
    }
    public static string Eject(string deviceId) {
        uint inst;
        int cr = CM_Locate_DevNodeW(out inst, deviceId, 0);
        if (cr != 0) return "Geraet nicht gefunden (CR " + cr + ")";
        string r1 = "kein uebergeordnetes Geraet";
        uint parent;
        if (CM_Get_Parent(out parent, inst, 0) == 0) { r1 = Request(parent); if (r1 == "") return ""; }
        string r2 = Request(inst);
        if (r2 == "") return "";
        return r1 + " / " + r2;
    }
}
'@
    }
    $dd = @(Get-CimInstance -ClassName Win32_DiskDrive -Filter "Index=$Number" -ErrorAction Stop)[0]
    if (-not $dd) { throw "Datentraeger $Number nicht gefunden" }
    return [HMSbEject]::Eject("$($dd.PNPDeviceID)")
}
# Ereignisanzeige (Anwendung, Quelle HUMig): 1000 = OK, 1001 = Warnung, 1002 = Fehler - fuer Ueberwachung/Benachrichtigung
function Write-HMSbEvent([string]$Status, [string]$Message) {
    try {
        $exists = $false
        try { $exists = [System.Diagnostics.EventLog]::SourceExists('HUMig') } catch { }
        if (-not $exists) { New-EventLog -LogName Application -Source 'HUMig' -ErrorAction Stop }
        $type = switch ($Status) { 'OK' { 'Information' } 'Warning' { 'Warning' } default { 'Error' } }
        $id = switch ($Status) { 'OK' { 1000 } 'Warning' { 1001 } default { 1002 } }
        if ($Message.Length -gt 30000) { $Message = $Message.Substring(0, 30000) }
        Write-EventLog -LogName Application -Source 'HUMig' -EntryType $type -EventId $id -Message $Message -ErrorAction Stop
    } catch { }
}
# VMs mit Dateien auf dem Systemlaufwerk (werden beim Host-System / -allCritical beruehrt)
# $Vms: Objekte mit Name, Paths (virtuelle Festplatten), VmPath, ConfigPath
function Get-HMSbSysDriveVms($Vms, [string]$SysDrive = $env:SystemDrive) {
    $sd = "$SysDrive".TrimEnd('\').ToUpper() + '\'
    $out = @()
    foreach ($v in @($Vms)) {
        if (-not $v -or -not "$($v.Name)") { continue }
        $disks = @(@($v.Paths) | Where-Object { "$_".ToUpper().StartsWith($sd) } | ForEach-Object { "$_" })
        $cfg = @(@("$($v.VmPath)", "$($v.ConfigPath)") | Where-Object { "$_".ToUpper().StartsWith($sd) } | Select-Object -Unique)
        if ($disks.Count -or $cfg.Count) { $out += [pscustomobject]@{ Name = "$($v.Name)"; Disks = $disks; Config = $cfg; ConfigOnly = (-not $disks.Count) } }
    }
    return $out
}
function Format-HMSbSysDriveVms($List, [string]$SysDrive = $env:SystemDrive) {
    $l = @($List | Where-Object { $_ })
    if (-not $l.Count) { return '' }
    $sd = "$SysDrive".TrimEnd('\').ToUpper()
    $t = @()
    $a = @($l | Where-Object { -not $_.ConfigOnly })
    $b = @($l | Where-Object { $_.ConfigOnly })
    if ($a.Count) {
        $t += "ACHTUNG - virtuelle Festplatten auf ${sd} - diese VMs werden beim Host-System mitgesichert (deutlich mehr Zeit und Platz, die VM wird dabei evtl. kurz angehalten):"
        foreach ($x in $a) { $t += "  $($x.Name): $(@($x.Disks) -join ', ')" }
    }
    if ($b.Count) {
        $t += "Hinweis - nur VM-Konfiguration auf ${sd} (klein): $(@($b | ForEach-Object { $_.Name }) -join ', ')"
        $t += "  Ob die Windows Server-Sicherung diese VMs beim Host-System ganz mitnimmt, ist nicht sicher - nach dem ersten Lauf wbadmin-HostSystem.log im Berichtsordner pruefen."
    }
    return ($t -join "`n")
}
# Veto-Grund von CM_Request_Device_Eject lesbar machen (PNP_VETO_TYPE)
function Format-HMSbVeto([string]$Result) {
    if ($Result -notmatch 'Veto (\d+)') { return $Result }
    $t = switch ([int]$Matches[1]) {
        1 { 'Legacy-Geraet' } 2 { 'wird gerade geschlossen' } 3 { 'ein Programm verwendet die Platte' } 4 { 'ein Dienst verwendet die Platte' }
        5 { 'Dateien/Volume auf der Platte sind noch geoeffnet' } 6 { 'ein anderes Geraet verhindert es' } 7 { 'Treiber verhindert es' }
        9 { 'zu wenig Strom' } 10 { 'Geraet nicht abschaltbar' } 12 { 'fehlende Rechte' } 13 { 'bereits entfernt' } default { 'Grund unbekannt' }
    }
    return "$t - $Result"
}
# Platte offline schalten + als "von HUMig offline" merken
function Set-HMSbDiskOffline([int]$Number, [string]$Label) {
    $disk = Get-Disk -Number $Number -ErrorAction Stop
    if ($disk.IsBoot -or $disk.IsSystem) { throw "Datentraeger $Number ist System-/Startplatte" }
    Set-Disk -Number $Number -IsOffline $true -ErrorAction Stop
    $k = Get-HMSbDiskKey $disk
    if ($k) { Set-HMSbOfflineMarks (@(Get-HMSbOfflineMarks | Where-Object { "$_".Split('|')[0] -ne $k }) + @("$k|$Label|$((Get-Date).ToString('yyyy-MM-dd HH:mm'))")) }
}
# Auswerfen mit Wiederholung (die Windows Server-Sicherung gibt die Platte nach dem Lauf teils erst nach einigen Sekunden frei)
function Invoke-HMSbDiskEjectRetry([int]$Number, [int]$Tries = 3, [int]$WaitSec = 10) {
    $r = ''
    for ($i = 1; $i -le $Tries; $i++) {
        $r = Invoke-HMSbDiskEject -Number $Number
        if (-not $r) { return '' }
        if ($i -lt $Tries) { Start-Sleep -Seconds $WaitSec }
    }
    return (Format-HMSbVeto $r)
}
function Invoke-HMSbAfterBackup([string]$Letter, [string]$Mode, [string]$Label) {
    if ($Mode -notmatch '^(Eject|Offline)$') { return }
    $L = "$Letter".TrimEnd(':')
    $disk = $null
    try { $disk = Get-Partition -DriveLetter $L -ErrorAction Stop | Get-Disk -ErrorAction Stop } catch { Write-HMSbLog "Nach der Sicherung: Datentraeger von ${L}: nicht ermittelt - $($_.Exception.Message)" 'Warning'; return }
    if ($disk.IsBoot -or $disk.IsSystem -or "$($disk.BusType)" -notmatch '^(USB|7)$') { Write-HMSbLog "Nach der Sicherung: ${L}: ist keine USB-Platte - wird nicht $(if ($Mode -eq 'Eject') { 'ausgeworfen' } else { 'offline geschaltet' })" 'Warning'; return }
    try { Write-VolumeCache -DriveLetter $L -ErrorAction Stop } catch { }
    if ($Mode -eq 'Offline') {
        try {
            Set-HMSbDiskOffline -Number $disk.Number -Label $Label
            Write-HMSbLog "Platte $Label offline geschaltet (Datentraeger $($disk.Number), kein Laufwerksbuchstabe mehr). Wieder online: HUMig ""Aktualisieren"", naechster geplanter Lauf oder Datentraegerverwaltung." 'Success'
        } catch { Write-HMSbLog "Platte $Label konnte nicht offline geschaltet werden: $($_.Exception.Message)" 'Warning' }
    } else {
        try {
            $r = Invoke-HMSbDiskEjectRetry -Number $disk.Number
            if ($r) {
                Write-HMSbLog "Platte $Label liess sich nicht auswerfen ($r) - wird stattdessen offline geschaltet." 'Warning'
                try { Set-HMSbDiskOffline -Number $disk.Number -Label $Label; Write-HMSbLog "Platte $Label offline geschaltet (kein Laufwerksbuchstabe mehr) - kann abgezogen werden." 'Success' }
                catch { Write-HMSbLog "Platte $Label konnte auch nicht offline geschaltet werden: $($_.Exception.Message)" 'Warning' }
            }
            else { Write-HMSbLog "Platte $Label ausgeworfen - kann abgezogen werden (bis zum erneuten Anstecken nicht mehr verfuegbar)." 'Success' }
        } catch { Write-HMSbLog "Platte $Label auswerfen: $($_.Exception.Message)" 'Warning' }
    }
}

# Bezeichnung einer Platte wurde geaendert: Verlauf auf der Platte (alle Eintraege gehoeren zu ihr) und
# die passenden Eintraege im Tool-Ordner (gleicher Lauf = Datum/Host/Profil auch auf der Platte) nachziehen
function Sync-HMSbDiskLabel([string]$Letter, [string]$Label, [string]$LocalHistory) {
    if (-not $Label) { return 0 }
    $f = "$($Letter):\$($script:SbDirName)\history.json"
    if (-not (Test-Path -LiteralPath $f)) { return 0 }
    $disk = Read-HMSbHistory $f
    $disk = @($disk)
    if (-not $disk.Count) { return 0 }
    $n = 0
    $keys = @{}
    foreach ($e in $disk) {
        $keys["$($e.Date)|$($e.Host)|$($e.Profile)"] = $true
        if ("$($e.Disk)" -ne $Label) { $e.Disk = $Label; $n++ }
    }
    if ($n) { ConvertTo-Json -InputObject @($disk) -Depth 5 | Set-Content -LiteralPath $f -Encoding UTF8 }
    if ($LocalHistory -and (Test-Path -LiteralPath $LocalHistory)) {
        $loc = Read-HMSbHistory $LocalHistory
        $loc = @($loc)
        $m = 0
        foreach ($e in $loc) {
            if ($keys.ContainsKey("$($e.Date)|$($e.Host)|$($e.Profile)") -and "$($e.Disk)" -ne $Label) { $e.Disk = $Label; $m++ }
        }
        if ($m) { ConvertTo-Json -InputObject @($loc) -Depth 5 | Set-Content -LiteralPath $LocalHistory -Encoding UTF8 }
        $n += $m
    }
    return $n
}

# Profile auf der Platte (profiles.json) - Wiederherstellung der Profile nach Verlust des Hosts
function Read-HMSbDiskProfiles([string]$Dir) {
    $f = Join-Path $Dir 'profiles.json'
    return (Read-HMSbHistory $f)
}
function Save-HMSbDiskProfile([string]$Dir, $Profile) {
    $f = Join-Path $Dir 'profiles.json'
    $old = Read-HMSbHistory $f
    $name = "$($Profile.Name)"
    $arr = @(@($old) | Where-Object { "$($_.Name)" -ne $name }) + @($Profile)
    if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
    ConvertTo-Json -InputObject @($arr) -Depth 5 | Set-Content -LiteralPath $f -Encoding UTF8
}
# Profil umbenennen in Verlauf/Profil-Dateien (Tool-Ordner oder Platte); Rueckgabe: Anzahl geaenderter Eintraege
function Rename-HMSbProfileInFile([string]$Path, [string]$Old, [string]$New) {
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    $arr = Read-HMSbHistory $Path
    $arr = @($arr)
    $n = 0
    foreach ($e in $arr) {
        if ($e.PSObject.Properties['Profile'] -and "$($e.Profile)" -eq $Old) { $e.Profile = $New; $n++ }
        if ($e.PSObject.Properties['DiskPrefix'] -and $e.PSObject.Properties['Name'] -and "$($e.Name)" -eq $Old) { $e.Name = $New; $n++ }
    }
    if ($n) { ConvertTo-Json -InputObject @($arr) -Depth 5 | Set-Content -LiteralPath $Path -Encoding UTF8 }
    return $n
}

# ----------------------------------------------------------------------------
# Host-Konfiguration: JSON + HTML + Wiederherstellungs-Skript fuer virtuelle Switches
# ----------------------------------------------------------------------------
function Get-HMSbVlanInfo($Adapter) {
    $r = [ordered]@{ VlanMode = ''; AccessVlanId = ''; NativeVlanId = ''; AllowedVlans = '' }
    try {
        $vl = Get-VMNetworkAdapterVlan -VMNetworkAdapter $Adapter -ErrorAction Stop
        if ($vl) {
            $r.VlanMode = "$($vl.OperationMode)"
            $r.AccessVlanId = "$($vl.AccessVlanId)"
            $r.NativeVlanId = "$($vl.NativeVlanId)"
            $r.AllowedVlans = "$($vl.AllowedVlanIdListString)"
            if (-not $r.AllowedVlans -and $vl.AllowedVlanIdList) { $r.AllowedVlans = (@($vl.AllowedVlanIdList) -join ',') }
        }
    } catch { }
    return $r
}

function Export-HMSbHostConfig {
    param([Parameter(Mandatory)][string]$Dest)
    if (-not (Test-Path -LiteralPath $Dest)) { New-Item -ItemType Directory -Path $Dest -Force | Out-Null }
    $warn = @()
    $cfg = [ordered]@{ Created = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); Host = $env:COMPUTERNAME; Domain = "$env:USERDNSDOMAIN"; OS = '' }
    try { $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop; $cfg.OS = "$($os.Caption) ($($os.Version))" } catch { }

    $hv = Test-HMSbHyperVHost
    $cfg.HyperV = $hv
    # Hyper-V-Host
    $cfg.VMHost = $null
    if ($hv) { try {
        $h = Get-VMHost -ErrorAction Stop
        $cfg.VMHost = [ordered]@{
            VirtualHardDiskPath = "$($h.VirtualHardDiskPath)"; VirtualMachinePath = "$($h.VirtualMachinePath)"
            LogicalProcessorCount = $h.LogicalProcessorCount; MemoryCapacityGB = [math]::Round([double]$h.MemoryCapacity / 1GB, 1)
            NumaSpanningEnabled = [bool]$h.NumaSpanningEnabled; EnableEnhancedSessionMode = [bool]$h.EnableEnhancedSessionMode
            VirtualMachineMigrationEnabled = [bool]$h.VirtualMachineMigrationEnabled; MaximumVirtualMachineMigrations = $h.MaximumVirtualMachineMigrations
            MaximumStorageMigrations = $h.MaximumStorageMigrations; MacAddressMinimum = "$($h.MacAddressMinimum)"; MacAddressMaximum = "$($h.MacAddressMaximum)"
        }
    } catch { $warn += "Get-VMHost: $($_.Exception.Message)" } }

    # Netzwerkkarten
    $allNics = @()
    try { $allNics = @(Get-NetAdapter -ErrorAction Stop) } catch { $warn += "Get-NetAdapter: $($_.Exception.Message)" }
    $cfg.NetAdapters = @($allNics | Sort-Object Name | ForEach-Object {
        [ordered]@{ Name = "$($_.Name)"; InterfaceDescription = "$($_.InterfaceDescription)"; MacAddress = "$($_.MacAddress)"; Status = "$($_.Status)"
                    LinkSpeed = "$($_.LinkSpeed)"; Virtual = [bool]$_.Virtual; VlanID = "$($_.VlanID)" }
    })

    # IP-Konfiguration (IPv4)
    $ips = @()
    try {
        foreach ($ip in @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.IPAddress -ne '127.0.0.1' -and "$($_.PrefixOrigin)" -ne 'WellKnown' })) {
            $gw = ''
            try { $gw = "$((@(Get-NetRoute -InterfaceIndex $ip.InterfaceIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop) | Select-Object -First 1).NextHop)" } catch { }
            $dns = ''
            try { $dns = (@((Get-DnsClientServerAddress -InterfaceIndex $ip.InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop).ServerAddresses) -join ', ') } catch { }
            $ips += [ordered]@{ Interface = "$($ip.InterfaceAlias)"; IPAddress = "$($ip.IPAddress)"; PrefixLength = $ip.PrefixLength; Dhcp = ("$($ip.PrefixOrigin)" -eq 'Dhcp'); Gateway = $gw; DNS = $dns }
        }
    } catch { $warn += "IP-Konfiguration: $($_.Exception.Message)" }
    $cfg.IPv4 = $ips

    # NIC-Teams (LBFO, alt)
    $cfg.LbfoTeams = @()
    if (Get-Command Get-NetLbfoTeam -ErrorAction SilentlyContinue) {
        try { $cfg.LbfoTeams = @(Get-NetLbfoTeam -ErrorAction Stop | ForEach-Object { [ordered]@{ Name = "$($_.Name)"; Members = (@($_.Members) -join ', '); TeamingMode = "$($_.TeamingMode)"; LoadBalancing = "$($_.LoadBalancingAlgorithm)" } }) } catch { }
    }

    # Virtuelle Switches
    $sw = @()
    if ($hv) { try {
        foreach ($s in @(Get-VMSwitch -ErrorAction Stop | Sort-Object Name)) {
            $descs = @($s.NetAdapterInterfaceDescriptions | Where-Object { $_ })
            if (-not $descs.Count -and $s.NetAdapterInterfaceDescription) { $descs = @("$($s.NetAdapterInterfaceDescription)") }
            $tm = ''; $lb = ''
            if ($s.EmbeddedTeamingEnabled) {
                try { $t = Get-VMSwitchTeam -Name $s.Name -ErrorAction Stop; $tm = "$($t.TeamingMode)"; $lb = "$($t.LoadBalancingAlgorithm)"; if (-not $descs.Count) { $descs = @($t.NetAdapterInterfaceDescription | Where-Object { $_ }) } } catch { }
            }
            $mem = @()
            foreach ($d in $descs) {
                $na = @($allNics | Where-Object { "$($_.InterfaceDescription)" -eq "$d" })[0]
                $mem += [ordered]@{ Description = "$d"; Name = "$($na.Name)"; MacAddress = "$($na.MacAddress)" }
            }
            $sw += [ordered]@{
                Name = "$($s.Name)"; SwitchType = "$($s.SwitchType)"; AllowManagementOS = [bool]$s.AllowManagementOS
                EmbeddedTeaming = [bool]$s.EmbeddedTeamingEnabled; TeamingMode = $tm; LoadBalancing = $lb
                BandwidthMode = "$($s.BandwidthReservationMode)"; IovEnabled = [bool]$s.IovEnabled; Members = $mem; Notes = "$($s.Notes)"
            }
        }
    } catch { $warn += "Get-VMSwitch: $($_.Exception.Message)" } }
    $cfg.Switches = $sw

    # Host-Netzwerkadapter (vEthernet) inkl. VLAN
    $mg = @()
    if ($hv) { try {
        foreach ($a in @(Get-VMNetworkAdapter -ManagementOS -ErrorAction Stop)) {
            $v = Get-HMSbVlanInfo $a
            $mg += [ordered]@{ Name = "$($a.Name)"; SwitchName = "$($a.SwitchName)"; MacAddress = "$($a.MacAddress)"; VlanMode = $v.VlanMode; AccessVlanId = $v.AccessVlanId; NativeVlanId = $v.NativeVlanId; AllowedVlans = $v.AllowedVlans }
        }
    } catch { $warn += "Host-vNICs: $($_.Exception.Message)" } }
    $cfg.ManagementAdapters = $mg

    # Virtuelle Computer
    $vms = @()
    if ($hv) { try {
        foreach ($vm in @(Get-VM -ErrorAction Stop | Sort-Object Name)) {
            $nics = @()
            foreach ($a in @(Get-VMNetworkAdapter -VM $vm -ErrorAction SilentlyContinue)) {
                $v = Get-HMSbVlanInfo $a
                $nics += [ordered]@{ Name = "$($a.Name)"; SwitchName = "$($a.SwitchName)"; MacAddress = "$($a.MacAddress)"; DynamicMac = [bool]$a.DynamicMacAddressEnabled; VlanMode = $v.VlanMode; AccessVlanId = $v.AccessVlanId; NativeVlanId = $v.NativeVlanId; AllowedVlans = $v.AllowedVlans }
            }
            $disks = @(Get-VMHardDiskDrive -VM $vm -ErrorAction SilentlyContinue | ForEach-Object { [ordered]@{ Controller = "$($_.ControllerType) $($_.ControllerNumber):$($_.ControllerLocation)"; Path = "$($_.Path)" } })
            $sb = ''
            if ([int]$vm.Generation -eq 2) { try { $fw = Get-VMFirmware -VM $vm -ErrorAction Stop; $sb = "$($fw.SecureBoot) $($fw.SecureBootTemplate)".Trim() } catch { } }
            $cp = 0; try { $cp = @(Get-VMSnapshot -VM $vm -ErrorAction SilentlyContinue).Count } catch { }
            $vms += [ordered]@{
                Name = "$($vm.Name)"; Id = "$($vm.Id)"; State = "$($vm.State)"; Generation = $vm.Generation; Version = "$($vm.Version)"
                CPU = $vm.ProcessorCount; StartupGB = [math]::Round([double]$vm.MemoryStartup / 1GB, 2); DynamicMemory = [bool]$vm.DynamicMemoryEnabled
                MinGB = [math]::Round([double]$vm.MemoryMinimum / 1GB, 2); MaxGB = [math]::Round([double]$vm.MemoryMaximum / 1GB, 2)
                AutoStart = "$($vm.AutomaticStartAction)"; AutoStartDelay = $vm.AutomaticStartDelay; AutoStop = "$($vm.AutomaticStopAction)"
                SecureBoot = $sb; Checkpoints = $cp; Path = "$($vm.Path)"; Notes = "$($vm.Notes)"; NetworkAdapters = $nics; Disks = $disks
            }
        }
    } catch { $warn += "Get-VM: $($_.Exception.Message)" } }
    $cfg.VMs = $vms
    $cfg.Warnings = $warn

    [pscustomobject]$cfg | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $Dest 'HostConfig.json') -Encoding UTF8
    Write-HMSbSwitchScript -Cfg $cfg -Path (Join-Path $Dest 'Restore-VMSwitches.ps1')
    Write-HMSbHostHtml -Cfg $cfg -Path (Join-Path $Dest 'HostConfig.html')
    return [pscustomobject]@{ Switches = $sw.Count; VMs = $vms.Count; ManagementAdapters = $mg.Count; Warnings = $warn; Folder = $Dest }
}

function Write-HMSbSwitchScript($Cfg, [string]$Path) {
    $q = { param($s) ConvertTo-HMSbPsString $s }
    $L = New-Object System.Collections.Generic.List[string]
    $L.Add('#Requires -Version 5.1')
    $L.Add('#Requires -RunAsAdministrator')
    $L.Add('<#')
    $L.Add("    Virtuelle Switches + Host-vNICs/VLANs wiederherstellen - erzeugt von HUMig am $($Cfg.Created) auf $($Cfg.Host).")
    $L.Add('    Zielmaschine: der NEU installierte Hyper-V-Host (PowerShell als Administrator), BEVOR die VMs wiederhergestellt werden.')
    $L.Add('    VOR dem Ausfuehren pruefen! Netzwerkkarten werden ueber die MAC-Adresse gesucht, sonst ueber die Beschreibung.')
    $L.Add('    Die Switch-Namen bleiben gleich - wiederhergestellte VMs finden ihr Netzwerk dadurch automatisch.')
    $L.Add('    VLANs der VMs sind in der VM-Sicherung enthalten. IP-Adressen des Hosts setzt das Skript NICHT (siehe HostConfig.html).')
    $L.Add('#>')
    $L.Add('$ErrorActionPreference = ''Stop''')
    $L.Add('function Find-Nic([string]$Mac, [string]$Desc) {')
    $L.Add('    $n = $null')
    $L.Add('    if ($Mac) { $n = @(Get-NetAdapter -Physical | Where-Object { $_.MacAddress -eq $Mac })[0] }')
    $L.Add('    if (-not $n -and $Desc) { $n = @(Get-NetAdapter -Physical | Where-Object { $_.InterfaceDescription -eq $Desc })[0] }')
    $L.Add('    if (-not $n) { throw "Netzwerkkarte nicht gefunden (MAC $Mac / $Desc)" }')
    $L.Add('    return $n')
    $L.Add('}')
    $L.Add('')
    foreach ($s in @($Cfg.Switches)) {
        $n = & $q $s.Name
        $dn = ("$($s.Name)" -replace '[^\w \-\.]', '')
        $L.Add("# ---- Switch $($s.Name) ($($s.SwitchType)$(if ($s.EmbeddedTeaming) { ', SET-Team' }))")
        $L.Add('try {')
        $L.Add("    if (Get-VMSwitch -Name $n -ErrorAction SilentlyContinue) { Write-Host ""Switch $dn existiert bereits"" -ForegroundColor Yellow }")
        $L.Add('    else {')
        if ("$($s.SwitchType)" -eq 'External') {
            $names = @()
            $i = 0
            foreach ($m in @($s.Members)) {
                $i++
                $L.Add("        `$nic$i = Find-Nic $(& $q $m.MacAddress) $(& $q $m.Description)")
                $names += "`$nic$i.Name"
            }
            if (-not $names.Count) { $L.Add("        throw 'Keine Netzwerkkarte fuer diesen Switch gespeichert'") }
            $extra = ''
            if ($s.BandwidthMode -match '^(Weight|Absolute)$') { $extra += " -MinimumBandwidthMode $($s.BandwidthMode)" }
            if ($s.EmbeddedTeaming -or $names.Count -gt 1) {
                $L.Add("        New-VMSwitch -Name $n -NetAdapterName @($($names -join ', ')) -EnableEmbeddedTeaming `$true -AllowManagementOS `$$($s.AllowManagementOS.ToString().ToLower())$extra | Out-Null")
                if ($s.LoadBalancing) { $L.Add("        try { Set-VMSwitchTeam -Name $n -LoadBalancingAlgorithm $($s.LoadBalancing) } catch { Write-Host `$_.Exception.Message -ForegroundColor Yellow }") }
            } else {
                $L.Add("        New-VMSwitch -Name $n -NetAdapterName $($names -join ', ') -AllowManagementOS `$$($s.AllowManagementOS.ToString().ToLower())$extra | Out-Null")
            }
        } else {
            $L.Add("        New-VMSwitch -Name $n -SwitchType $($s.SwitchType) | Out-Null")
        }
        $L.Add("        Write-Host ""Switch $dn erstellt"" -ForegroundColor Green")
        $L.Add('    }')
        $L.Add("} catch { Write-Host ""FEHLER Switch ${dn}: `$(`$_.Exception.Message)"" -ForegroundColor Red }")
        $L.Add('')
    }
    foreach ($a in @($Cfg.ManagementAdapters)) {
        if (-not $a.SwitchName) { continue }
        $an = & $q $a.Name
        $da = ("$($a.Name)" -replace '[^\w \-\.]', '')
        $L.Add("# ---- Host-vNIC $($a.Name) an Switch $($a.SwitchName)")
        $L.Add('try {')
        $L.Add("    if (-not (Get-VMNetworkAdapter -ManagementOS -Name $an -ErrorAction SilentlyContinue)) { Add-VMNetworkAdapter -ManagementOS -Name $an -SwitchName $(& $q $a.SwitchName) }")
        if ($a.VlanMode -eq 'Access' -and $a.AccessVlanId -and [int]$a.AccessVlanId -gt 0) {
            $L.Add("    Set-VMNetworkAdapterVlan -ManagementOS -VMNetworkAdapterName $an -Access -VlanId $([int]$a.AccessVlanId)")
        } elseif ($a.VlanMode -eq 'Trunk' -and $a.AllowedVlans) {
            $L.Add("    Set-VMNetworkAdapterVlan -ManagementOS -VMNetworkAdapterName $an -Trunk -AllowedVlanIdList $(& $q $a.AllowedVlans) -NativeVlanId $([int]$a.NativeVlanId)")
        }
        $L.Add("    Write-Host ""Host-vNIC $da OK"" -ForegroundColor Green")
        $L.Add("} catch { Write-Host ""FEHLER Host-vNIC ${da}: `$(`$_.Exception.Message)"" -ForegroundColor Red }")
        $L.Add('')
    }
    $L.Add('Get-VMSwitch | Format-Table Name, SwitchType, NetAdapterInterfaceDescription, AllowManagementOS -AutoSize')
    [System.IO.File]::WriteAllLines($Path, $L.ToArray(), (New-Object System.Text.UTF8Encoding($true)))
}

function ConvertTo-HMSbHtmlTable($Rows, [string[]]$Props) {
    $rows = @($Rows | Where-Object { $_ })
    if (-not $rows.Count) { return '<p class="muted">- keine -</p>' }
    $objs = foreach ($r in $rows) { $o = [ordered]@{}; foreach ($p in $Props) { $o[$p] = $r[$p] }; [pscustomobject]$o }
    return (@($objs) | ConvertTo-Html -Fragment | Out-String)
}

function Write-HMSbHostHtml($Cfg, [string]$Path) {
    $enc = { param($s) [System.Net.WebUtility]::HtmlEncode("$s") }
    $sw = @($Cfg.Switches | ForEach-Object { $x = [ordered]@{}; foreach ($k in $_.Keys) { $x[$k] = $_[$k] }; $x.Members = (@($_.Members | ForEach-Object { "$($_.Name) [$($_.MacAddress)] $($_.Description)" }) -join ' | '); $x })
    $vms = @($Cfg.VMs | ForEach-Object {
        $x = [ordered]@{}; foreach ($k in $_.Keys) { $x[$k] = $_[$k] }
        $x.NetworkAdapters = (@($_.NetworkAdapters | ForEach-Object { "$($_.Name) -> $($_.SwitchName) [$($_.MacAddress)] VLAN $($_.VlanMode) $($_.AccessVlanId)$(if ($_.AllowedVlans) { " Trunk $($_.AllowedVlans)" })" }) -join ' | ')
        $x.Disks = (@($_.Disks | ForEach-Object { "$($_.Controller) $($_.Path)" }) -join ' | ')
        $x
    })
    $hostRows = @()
    if ($Cfg.VMHost) { foreach ($k in $Cfg.VMHost.Keys) { $hostRows += [ordered]@{ Eigenschaft = $k; Wert = "$($Cfg.VMHost[$k])" } } }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("<!DOCTYPE html><html><head><meta charset='utf-8'><title>Hyper-V-Host $(& $enc $Cfg.Host)</title><style>body{font-family:Segoe UI,Arial;font-size:13px;margin:20px;color:#222}h1{font-size:20px}h2{font-size:15px;margin-top:22px;border-bottom:1px solid #ccc}table{border-collapse:collapse;margin:6px 0}th,td{border:1px solid #bbb;padding:3px 6px;text-align:left;vertical-align:top}th{background:#eee}.muted{color:#888}.warn{color:#b00}</style></head><body>")
    [void]$sb.Append("<h1>Hyper-V-Host $(& $enc $Cfg.Host)</h1><p>$(& $enc $Cfg.OS) - Domaene $(& $enc $Cfg.Domain) - erstellt $(& $enc $Cfg.Created) mit HUMig</p>")
    if (@($Cfg.Warnings).Count) { [void]$sb.Append("<p class='warn'>Hinweise: $(& $enc (@($Cfg.Warnings) -join ' | '))</p>") }
    [void]$sb.Append('<h2>Hyper-V-Einstellungen</h2>' + (ConvertTo-HMSbHtmlTable $hostRows @('Eigenschaft', 'Wert')))
    [void]$sb.Append('<h2>Virtuelle Switches</h2>' + (ConvertTo-HMSbHtmlTable $sw @('Name', 'SwitchType', 'AllowManagementOS', 'EmbeddedTeaming', 'TeamingMode', 'LoadBalancing', 'BandwidthMode', 'Members', 'Notes')))
    [void]$sb.Append('<h2>Host-Netzwerkadapter (vEthernet)</h2>' + (ConvertTo-HMSbHtmlTable @($Cfg.ManagementAdapters) @('Name', 'SwitchName', 'MacAddress', 'VlanMode', 'AccessVlanId', 'NativeVlanId', 'AllowedVlans')))
    [void]$sb.Append('<h2>IPv4-Konfiguration</h2>' + (ConvertTo-HMSbHtmlTable @($Cfg.IPv4) @('Interface', 'IPAddress', 'PrefixLength', 'Dhcp', 'Gateway', 'DNS')))
    [void]$sb.Append('<h2>Netzwerkkarten</h2>' + (ConvertTo-HMSbHtmlTable @($Cfg.NetAdapters) @('Name', 'InterfaceDescription', 'MacAddress', 'Status', 'LinkSpeed', 'Virtual', 'VlanID')))
    if (@($Cfg.LbfoTeams).Count) { [void]$sb.Append('<h2>NIC-Teams (LBFO)</h2>' + (ConvertTo-HMSbHtmlTable @($Cfg.LbfoTeams) @('Name', 'Members', 'TeamingMode', 'LoadBalancing'))) }
    [void]$sb.Append('<h2>Virtuelle Computer</h2>' + (ConvertTo-HMSbHtmlTable $vms @('Name', 'State', 'Generation', 'Version', 'CPU', 'StartupGB', 'DynamicMemory', 'MinGB', 'MaxGB', 'AutoStart', 'AutoStartDelay', 'AutoStop', 'SecureBoot', 'Checkpoints', 'NetworkAdapters', 'Disks', 'Path')))
    [void]$sb.Append("<h2>Wiederherstellung</h2><p>1. Windows Server + Hyper-V installieren, IP-Adressen wie oben setzen.<br>2. <b>Restore-VMSwitches.ps1</b> pruefen und als Administrator ausfuehren (gleiche Switch-Namen).<br>3. VMs mit der Windows Server-Sicherung von der USB-Platte wiederherstellen (wbadmin.msc &gt; Wiederherstellen &gt; Anwendungen &gt; Hyper-V).</p>")
    [void]$sb.Append('</body></html>')
    [System.IO.File]::WriteAllText($Path, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
}

# Bericht eines Laufs (deutsch, Status mit Erklaerung, Hinweise mit Abhilfe, Links zu den Dateien, Protokoll)
function Write-HMSbReport {
    param([string]$Path, $Entry, $Hints = @(), [string]$Folder, $Ctx)
    $e = { param($x) [System.Net.WebUtility]::HtmlEncode("$x") }
    $st = "$($Entry.Status)"
    $hasInfo = [bool](@($Hints | Where-Object { $_.Lvl -eq 'Info' }).Count)
    $title = switch ($st) { 'OK' { if ($hasInfo) { 'OK (Hinweis)' } else { 'OK' } } 'Warning' { 'Warnung' } default { 'Fehler' } }
    $col = switch ($st) { 'OK' { if ($hasInfo) { '#1565c0' } else { '#2e7d32' } } 'Warning' { '#e69500' } default { '#c62828' } }
    $expl = switch ($st) {
        'OK' { if ($hasInfo) { 'Alles wurde vollstaendig gesichert und geprueft. Es gibt einen Hinweis, den man kennen sollte (siehe unten) - kein Handlungsbedarf fuer diese Sicherung.' } else { 'Alles wurde vollstaendig gesichert und geprueft.' } }
        'Warning' { 'Die Sicherung ist gelaufen, aber nicht alles ist einwandfrei - bitte die Hinweise unten ansehen.' }
        default { 'Die Sicherung ist fehlgeschlagen oder unvollstaendig - bitte die Hinweise unten ansehen und die Sicherung wiederholen.' }
    }
    $ja = { param($b) if ($b -eq $true) { 'ja' } else { 'nein' } }
    $rows = @(
        @('Datum', $Entry.Date), @('Profil', $Entry.Profile), @('Hyper-V-Host', $Entry.Host),
        @('Platte', "$($Entry.Disk)$(if ($Entry.DiskSerial) { "  (Seriennummer $($Entry.DiskSerial))" })"),
        @('Virtuelle Computer', $(if ($Entry.VMs) { $Entry.VMs } else { '-' })),
        @('Laufwerke dieses Servers', $(if ($Entry.Volumes) { "$($Entry.Volumes)$(if ($Entry.VolVersionId) { " - Version $($Entry.VolVersionId) (UTC)" })" } else { '-' })),
        @('Dauer', (Format-HMDuration $Entry.Minutes)), @('Gesicherte Datenmenge', "ca. $($Entry.SizeGB) GB (virtuelle Festplatten der VMs + belegter Platz der Laufwerke)"),
        @('Sicherungsversion', $(if ($Entry.VersionId) { "$($Entry.VersionId) (UTC) - fuer die Wiederherstellung" } else { '-' })),
        @('Host-Konfiguration', (& $ja $Entry.HostConfig)),
        @('Host-System (Bare-Metal)', "$(& $ja $Entry.HostSystem)$(if ($Entry.HostVersionId) { " - Version $($Entry.HostVersionId) (UTC)" })"),
        @('Erstellt mit', $Entry.Tool)
    )
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("<!DOCTYPE html><html lang='de'><head><meta charset='utf-8'><title>Server-Backup $(& $e $Entry.Profile) $(& $e $Entry.Date)</title><style>body{font-family:Segoe UI,Arial;font-size:13px;margin:24px;color:#222;max-width:1100px}h1{font-size:22px;margin:0 0 4px}h2{font-size:15px;margin-top:22px;border-bottom:1px solid #ccc;padding-bottom:3px}table{border-collapse:collapse}th,td{border:1px solid #bbb;padding:4px 9px;text-align:left;vertical-align:top}th{background:#f1f1f1;width:190px}.box{border-left:5px solid #999;background:#f7f7f7;padding:8px 12px;margin:8px 0}.Info{border-color:#1565c0}.Warning{border-color:#e69500}.Error{border-color:#c62828}.fix{color:#444;margin-top:4px}pre{background:#1e1e2e;color:#cdd6f4;padding:10px;font-size:12px;overflow:auto;max-height:520px}a{color:#1565c0}.muted{color:#777}</style></head><body>")
    [void]$sb.Append("<h1 style='color:$col'>Server-Backup $(& $e $Entry.Profile): $title</h1><p>$(& $e $expl)</p>")
    [void]$sb.Append('<h2>Zusammenfassung</h2><table>')
    foreach ($r in $rows) { [void]$sb.Append("<tr><th>$(& $e $r[0])</th><td>$(& $e $r[1])</td></tr>") }
    [void]$sb.Append('</table>')
    [void]$sb.Append('<h2>Hinweise</h2>')
    if (@($Hints).Count) {
        foreach ($h in @($Hints)) {
            $lab = switch ($h.Lvl) { 'Info' { 'Hinweis' } 'Warning' { 'Warnung' } default { 'Fehler' } }
            [void]$sb.Append("<div class='box $($h.Lvl)'><b>$lab</b>: $(& $e $h.Text)$(if ($h.Fix) { "<div class='fix'><b>Was tun:</b> $(& $e $h.Fix)</div>" })</div>")
        }
    } else { [void]$sb.Append("<p class='muted'>Keine - alles in Ordnung.</p>") }
    # Dateien im Ordner mit Erklaerung
    $desc = [ordered]@{
        'wbadmin-VMs.log' = 'Ausgabe der Windows Server-Sicherung (wbadmin) waehrend der VM-Sicherung'
        'wbadmin-Laufwerke.log' = 'Ausgabe von wbadmin waehrend der Sicherung der Laufwerke dieses Servers'
        'Inhalt-Laufwerke.txt' = 'Inhalt der Laufwerks-Sicherung - Grundlage der Pruefung'
        'wbadmin-HostSystem.log' = 'Ausgabe von wbadmin waehrend der Host-System-Sicherung (zeigt auch, welche Volumes gesichert wurden)'
        'Versionen.txt' = 'alle Sicherungsstaende (Versionen) auf dieser Platte'
        'Inhalt.txt' = 'Inhalt der neuen Version - Grundlage der Pruefung'
        'Host-Konfiguration\HostConfig.html' = 'Host-Konfiguration: Switches, VLANs, Netzwerk, Hyper-V- und VM-Einstellungen'
        'Host-Konfiguration\Restore-VMSwitches.ps1' = 'Skript: virtuelle Switches auf einem neu installierten Host wieder anlegen'
        'Host-Konfiguration\HostConfig.json' = 'Host-Konfiguration maschinenlesbar'
    }
    [void]$sb.Append('<h2>Dateien in diesem Ordner</h2><table>')
    foreach ($k in $desc.Keys) {
        if (Test-Path -LiteralPath (Join-Path $Folder $k)) { [void]$sb.Append("<tr><th><a href='$(& $e ($k -replace '\\', '/'))'>$(& $e $k)</a></th><td>$(& $e $desc[$k])</td></tr>") }
    }
    foreach ($f in @(Get-ChildItem -LiteralPath $Folder -File -Filter '*.log' -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike 'wbadmin-*' })) {
        $d = if ($f.Name -like '*Error*') { 'Fehlerprotokoll der Windows Server-Sicherung' } elseif ($f.Name -like 'Backup*') { 'Protokoll der Windows Server-Sicherung (gesicherte Dateien)' } else { 'Protokoll der Windows Server-Sicherung' }
        [void]$sb.Append("<tr><th><a href='$(& $e $f.Name)'>$(& $e $f.Name)</a></th><td>$(& $e $d)</td></tr>")
    }
    [void]$sb.Append('</table>')
    [void]$sb.Append("<h2>Wiederherstellen</h2><p>Die Sicherung ist eine normale Windows-Server-Sicherung (Ordner <code>WindowsImageBackup</code> auf der Platte) und auch ohne HUMig wiederherstellbar: <code>wbadmin.msc</code> &gt; Wiederherstellen &gt; an einem anderen Speicherort gespeicherte Sicherung &gt; Lokale Laufwerke &gt; Datum &gt; Hyper-V. Neu installierter Host: vorher <code>Restore-VMSwitches.ps1</code> ausfuehren.</p>")
    if ($null -ne $script:SbRunLog -and $script:SbRunLog.Count) {
        [void]$sb.Append("<h2>Protokoll des Laufs</h2><details><summary>anzeigen ($($script:SbRunLog.Count) Zeilen)</summary><pre>$(& $e (($script:SbRunLog.ToArray()) -join "`n"))</pre></details>")
    }
    [void]$sb.Append('</body></html>')
    [System.IO.File]::WriteAllText($Path, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
}

# ----------------------------------------------------------------------------
# Hauptablauf (Hintergrund-Runspace)
#   Ctx: Profile, DiskPrefix, Drive (Buchstabe), DiskLabel, DiskSerial, VMs (Namen), HostConfig, HostSystem, Verify, LocalHistory, LocalReportDir, Version
# ----------------------------------------------------------------------------
function Start-HMServerBackup {
    param([hashtable]$Ctx, [hashtable]$Job)
    $script:SbJob = $Job
    $t0 = Get-Date
    $status = 'OK'; $notes = @(); $hints = @()
    $script:SbRunLog = New-Object System.Collections.Generic.List[string]
    $L = "$($Ctx.Drive)".TrimEnd(':', '\').ToUpper()
    $target = "${L}:"
    $vms = @($Ctx.VMs | Where-Object { "$_".Trim() })
    $vols = @($Ctx.Volumes | Where-Object { "$_".Trim() } | ForEach-Object { ("$_".Trim().TrimEnd('\', ':')).ToUpper() + ':' } | Select-Object -Unique)
    $res = [ordered]@{ Status = 'Error'; SizeBytes = [long]0; Report = ''; VersionId = ''; HostVersionId = ''; VolVersionId = '' }
    $Job.Result = [pscustomobject]$res

    Write-HMSbLog "SERVER-BACKUP $($Ctx.Profile) - Host $env:COMPUTERNAME - Ziel $target $($Ctx.DiskLabel)" 'Header'
    # --- Pruefungen
    if (-not (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32\wbadmin.exe'))) { throw 'wbadmin.exe fehlt - Feature "Windows Server-Sicherung" installieren' }
    if (-not (Test-Path -LiteralPath "$target\")) { throw "Ziel-Laufwerk $target nicht vorhanden" }
    if ("$env:SystemDrive".TrimEnd(':').ToUpper() -eq $L) { throw 'Ziel darf nicht das System-Laufwerk sein' }
    $info = @()
    if ($vms.Count) {
        $all = Get-HMSbVmList
        $all = @($all)
        foreach ($n in $vms) {
            if ($n -match ',') { throw "VM-Name '$n' enthaelt ein Komma - wbadmin kann diese VM nicht einzeln sichern" }
            $v = @($all | Where-Object { $_.Name -eq $n })[0]
            if (-not $v) { throw "VM '$n' gibt es auf diesem Host nicht (umbenannt/geloescht?) - Profil anpassen" }
            foreach ($p in @($v.Paths) + @($v.VmPath)) { if ("$p" -match "^$L`:") { throw "VM '$n' liegt (teilweise) auf dem Ziel-Laufwerk $target ($p)" } }
            if ($v.OfflineHint) { Write-HMSbLog "Vorab-Hinweis: VM '$n' wird voraussichtlich OFFLINE gesichert ($($v.OfflineHint)) - sie wird zu Beginn kurz angehalten (gespeicherter Zustand), danach laeuft sie weiter. Laut Hyper-V: $($v.OfflineDetail)" 'Warning' }
            if ([int]$v.Checkpoints -ge 2) { Write-HMSbLog "Hinweis: VM '$n' hat $($v.Checkpoints) Pruefpunkte. Die Sicherung funktioniert; ein aelterer MS-Artikel (KB 958662, Server 2008) nennt Einschraenkungen beim Wiederherstellen von VMs mit 2+ Pruefpunkten - fuer aktuelle Server nicht belegt. Nicht mehr benoetigte Pruefpunkte zusammenfuehren, Wiederherstellung einmal testen." 'Warning' }
            $info += $v
        }
        $res.SizeBytes = [long](@($info | Measure-Object -Property SizeBytes -Sum).Sum)
        Write-HMSbLog ("{0} VM(s): {1} - virtuelle Festplatten ca. {2:N1} GB" -f $vms.Count, ($vms -join ', '), ($res.SizeBytes / 1GB)) 'Info'
    }
    if ($vols.Count) {
        if ($vols -contains $target) { throw "Das Ziel-Laufwerk $target kann nicht sich selbst sichern - Laufwerk abwaehlen" }
        $volUsed = [long]0
        foreach ($vl in $vols) {
            try { $vo = Get-Volume -DriveLetter $vl.TrimEnd(':') -ErrorAction Stop; $volUsed += [long]($vo.Size - $vo.SizeRemaining) } catch { throw "Laufwerk $vl nicht gefunden" }
        }
        $res.SizeBytes += $volUsed
        Write-HMSbLog ("Laufwerke dieses Servers: {0} - belegt ca. {1:N1} GB" -f ($vols -join ', '), ($volUsed / 1GB)) 'Info'
    }
    try {
        $vol = Get-Volume -DriveLetter $L -ErrorAction Stop
        Write-HMSbLog ("Ziel {0} {1}: {2:N0} GB frei von {3:N0} GB" -f $target, "$($vol.FileSystemLabel)", ($vol.SizeRemaining / 1GB), ($vol.Size / 1GB)) 'Info'
        if ($res.SizeBytes -gt 0 -and [long]$vol.SizeRemaining -lt $res.SizeBytes) { Write-HMSbLog 'Wenig freier Platz: reicht evtl. nur fuer eine Aenderungs-Sicherung - die Windows Server-Sicherung loescht bei Platzmangel automatisch die aeltesten Versionen.' 'Warning' }
    } catch { }

    # --- Berichtsordner auf der Platte
    $stamp = Get-Date -Format 'yyyy-MM-dd_HHmm'
    $rep = Join-Path "$target\$($script:SbDirName)" ("{0}_{1}" -f $stamp, (ConvertTo-HMSbSafeName $Ctx.Profile))
    New-Item -ItemType Directory -Path $rep -Force | Out-Null
    $res.Report = $rep
    if ($Ctx.ProfileData) {
        try { Save-HMSbDiskProfile "$target\$($script:SbDirName)" $Ctx.ProfileData; Write-HMSbLog "Profil '$($Ctx.Profile)' auf der Platte gespeichert (profiles.json)" 'Info' }
        catch { Write-HMSbLog "Profil nicht auf der Platte gespeichert: $($_.Exception.Message)" 'Warning' }
    }

    # Ab hier existiert der Berichtsordner: Abbruch/Fehler wird trotzdem in Verlauf und Bericht festgehalten
    $hostCfgOk = $false; $verId = ''; $volOk = $false; $hostSysOk = $false
    try {
        # --- Host-Konfiguration
        $hostCfgOk = $false
        if ($Ctx.HostConfig) {
            $Job.Status = 'Host-Konfiguration'
            try {
                $hc = Export-HMSbHostConfig -Dest (Join-Path $rep 'Host-Konfiguration')
                $hostCfgOk = $true
                Write-HMSbLog "Host-Konfiguration gesichert: $($hc.Switches) Switch(es), $($hc.ManagementAdapters) Host-vNIC(s), $($hc.VMs) VM(s) -> Host-Konfiguration\ (HTML, JSON, Restore-VMSwitches.ps1)" 'Success'
                foreach ($w in @($hc.Warnings)) { Write-HMSbLog "  Host-Konfiguration: $w" 'Warning' }
            } catch {
                Write-HMSbLog "Host-Konfiguration nicht gesichert: $($_.Exception.Message)" 'Warning'; $notes += 'Host-Konfiguration fehlgeschlagen'; $status = 'Warning'
                $hints += [pscustomobject]@{ Lvl = 'Warning'; Text = "Die Host-Konfiguration konnte nicht gesichert werden: $($_.Exception.Message)"; Fix = 'Die VM-Sicherung ist davon nicht betroffen. Mit "Nur Host-Konfiguration" erneut versuchen.' }
            }
        }
        if ($Job.Cancel) { throw 'Abgebrochen' }

        $nPh = [Math]::Max(1, [int][bool]$vms.Count + [int][bool]$vols.Count + [int][bool]$Ctx.HostSystem)
        $span = [int](95 / $nPh)
        $pb = 2
        # --- VMs sichern
        $verId = ''
        if ($vms.Count) {
            $Job.Status = 'VMs: Schattenkopie wird erstellt ...'
            Write-HMSbLog "wbadmin: VMs sichern -> $target (Online-Sicherung ueber VSS, VMs laufen weiter)" 'Header'
            $argList = "start backup -backupTarget:$target -hyperv:""$($vms -join ',')"" -quiet"
            $r = Invoke-HMSbStart -Arguments $argList -Phase 'VMs' -PBase $pb -PSpan $span -LogFile (Join-Path $rep 'wbadmin-VMs.log') -Job $Job
            if ($Job.Cancel) {
                Write-HMSbLog 'Abbruch: laufende Sicherung wird beendet (wbadmin stop job) ...' 'Warning'
                [void](Invoke-HMSbWbadmin -Arguments 'stop job -quiet' -Quiet)
                throw 'Abgebrochen'
            }
            foreach ($lf in @($r.LogFiles)) { try { Copy-Item -LiteralPath $lf -Destination $rep -Force -ErrorAction Stop } catch { } }
            if ($r.ExitCode -ne 0 -and $r.Busy) { $status = 'Error'; $notes += 'VM-Sicherung: anderer Sicherungsvorgang lief'; $hints += [pscustomobject]@{ Lvl = 'Error'; Text = 'Die VM-Sicherung wurde nicht ausgefuehrt: am Host lief bereits eine andere Sicherung/Wiederherstellung.'; Fix = $script:HMSbBusyFix }; Write-HMSbLog 'VM-Sicherung NICHT ausgefuehrt - am Host lief bereits eine andere Sicherung/Wiederherstellung (spaeter erneut starten)' 'Error' }
            elseif ($r.ExitCode -ne 0) { $status = 'Error'; $notes += "VM-Sicherung Exitcode $($r.ExitCode)"; $hints += [pscustomobject]@{ Lvl = 'Error'; Text = "Die VM-Sicherung ist fehlgeschlagen (wbadmin Exitcode $($r.ExitCode))."; Fix = 'Ursache steht in wbadmin-VMs.log und im Backup-/Fehlerprotokoll der Windows Server-Sicherung (Links unten). Haeufig: Platte voll, VM gesperrt, VSS-Fehler im Gast.' }; Write-HMSbLog "VM-Sicherung FEHLGESCHLAGEN (wbadmin Exitcode $($r.ExitCode)) - Details: wbadmin-VMs.log im Berichtsordner" 'Error' }
            else {
                $offVms = @($r.Lines | Where-Object { $_ -match '"(.+?) \(Offline\)"' } | ForEach-Object { if ($_ -match '"(.+?) \(Offline\)"') { $Matches[1] } } | Select-Object -Unique)
                if ($offVms.Count) {
                    # vollstaendig gesichert -> kein Warnstatus, nur Hinweis
                    $why = Get-HMSbOfflineReasons -Since $t0.AddMinutes(-1)
                    foreach ($ov in $offVms) {
                        $h = Get-HMSbOfflineHintText $why[$ov]
                        if ($h) {
                            Write-HMSbLog "VM '$ov' wurde OFFLINE gesichert (kurz angehalten) - Grund laut Hyper-V: $h$(if ($why[$ov].Dynamic) { '. Abhilfe: Laufwerke im Gast auf Basisdatentraeger umstellen (neue Basis-VHDX, Daten kopieren) - siehe Anleitung.' })" 'Warning'
                            $notes += "Hinweis: $ov offline gesichert ($h)"
                            $hints += [pscustomobject]@{ Lvl = 'Info'; Text = "VM $ov wurde vollstaendig gesichert, aber OFFLINE: Hyper-V hat sie zu Beginn kurz angehalten (gespeicherter Zustand, meist 1-2 Minuten), danach lief sie weiter. Grund laut Hyper-V: $h."; Fix = $(if ($why[$ov].Dynamic) { 'Im Gast sind dynamische Datentraeger eingerichtet (diskpart > list disk, Spalte Dyn). Abhilfe: auf Basisdatentraeger umstellen (neue Basis-VHDX anhaengen, Daten kopieren). Bis dahin ausserhalb der Unterrichtszeit sichern (Zeitplan).' } else { 'Integrationsdienst Sicherung (VSS) der VM und den Dienst vmicvss im Gast pruefen.' }) }
                        } else {
                            Write-HMSbLog "VM '$ov' wurde OFFLINE gesichert (kurz angehalten) - Grund nicht im Hyper-V-Protokoll gefunden: Integrationsdienst Sicherung (VSS), Dienst vmicvss im Gast und Volumes (NTFS/ReFS, Basisdatentraeger) pruefen." 'Warning'
                            $notes += "Hinweis: $ov offline gesichert"
                            $hints += [pscustomobject]@{ Lvl = 'Info'; Text = "VM $ov wurde vollstaendig gesichert, aber OFFLINE (zu Beginn kurz angehalten). Ein Grund stand nicht im Hyper-V-Protokoll."; Fix = 'Integrationsdienst Sicherung (VSS) der VM, Dienst vmicvss im Gast und Volumes im Gast (NTFS/ReFS, Basisdatentraeger) pruefen.' }
                        }
                    }
                }
                Write-HMSbLog 'VM-Sicherung erfolgreich' 'Success'
            }
            # Version ermitteln + pruefen
            $Job.Status = 'Pruefen'
            try {
                $vv = Get-HMSbVersions $target
                $last = @($vv.Versions) | Select-Object -Last 1
                if ($last) {
                    $verId = "$($last.Id)"; $res.VersionId = $verId
                    Write-HMSbLog "Versionen auf der Platte: $(@($vv.Versions).Count) - neueste: $($last.Time) (ID $verId)" 'Info'
                    Set-Content -LiteralPath (Join-Path $rep 'Versionen.txt') -Value $vv.Text -Encoding UTF8
                }
                if ($Ctx.Verify -and $verId -and $r.ExitCode -eq 0) {
                    $gi = Invoke-HMSbWbadmin -Arguments "get items -version:$verId -backupTarget:$target" -Quiet
                    Set-Content -LiteralPath (Join-Path $rep 'Inhalt.txt') -Value $gi.Text -Encoding UTF8
                    $miss = @($vms | Where-Object { $gi.Text -notmatch [regex]::Escape($_) })
                    if ($gi.ExitCode -ne 0) { Write-HMSbLog "Pruefung: wbadmin get items Exitcode $($gi.ExitCode) - siehe Inhalt.txt" 'Warning'; if ($status -eq 'OK') { $status = 'Warning' }; $notes += 'Pruefung nicht moeglich'
                        $hints += [pscustomobject]@{ Lvl = 'Warning'; Text = "Die Pruefung konnte den Inhalt der Sicherung nicht lesen (Exitcode $($gi.ExitCode))."; Fix = 'Inhalt.txt ansehen; "Versionen auf der Platte" zeigt, ob die Version vorhanden ist.' } }
                    elseif ($miss.Count) { Write-HMSbLog "Pruefung: in Version $verId NICHT gefunden: $($miss -join ', ') - siehe Inhalt.txt" 'Warning'; $notes += "Pruefung: fehlt $($miss -join ', ')"; if ($status -eq 'OK') { $status = 'Warning' }
                        $hints += [pscustomobject]@{ Lvl = 'Warning'; Text = "Die Pruefung hat folgende VMs in der neuen Version nicht gefunden: $($miss -join ', ')."; Fix = 'Inhalt.txt ansehen. Fehlen die VMs wirklich, Sicherung wiederholen.' } }
                    else { Write-HMSbLog "Pruefung OK: alle $($vms.Count) VM(s) in Version $verId enthalten" 'Success' }
                }
            } catch { Write-HMSbLog "Versionen/Pruefung nicht moeglich: $($_.Exception.Message)" 'Warning' }
        }
        if ($vms.Count) { $pb += $span }
        if ($Job.Cancel) { throw 'Abgebrochen' }

        # --- Laufwerke dieses Servers (Volume-Sicherung, blockbasiert)
        $volOk = $false
        if ($vols.Count) {
            $Job.Status = 'Laufwerke: Schattenkopie wird erstellt ...'
            Write-HMSbLog "wbadmin: Laufwerke sichern ($($vols -join ', ')) -> $target" 'Header'
            $r3 = Invoke-HMSbStart -Arguments "start backup -backupTarget:$target -include:$($vols -join ',') -quiet" -Phase 'Laufwerke' -PBase $pb -PSpan $span -LogFile (Join-Path $rep 'wbadmin-Laufwerke.log') -Job $Job
            $pb += $span
            if ($Job.Cancel) {
                Write-HMSbLog 'Abbruch: laufende Sicherung wird beendet (wbadmin stop job) ...' 'Warning'
                [void](Invoke-HMSbWbadmin -Arguments 'stop job -quiet' -Quiet)
                throw 'Abgebrochen'
            }
            foreach ($lf in @($r3.LogFiles)) { try { Copy-Item -LiteralPath $lf -Destination $rep -Force -ErrorAction Stop } catch { } }
            if ($r3.ExitCode -ne 0) {
                $status = 'Error'; $notes += $(if ($r3.Busy) { 'Laufwerke: anderer Sicherungsvorgang lief' } else { "Laufwerke Exitcode $($r3.ExitCode)" })
                if ($r3.Busy) { $hints += [pscustomobject]@{ Lvl = 'Error'; Text = 'Die Sicherung der Laufwerke wurde nicht ausgefuehrt: am Host lief bereits eine andere Sicherung/Wiederherstellung.'; Fix = $script:HMSbBusyFix } }
                else { $hints += [pscustomobject]@{ Lvl = 'Error'; Text = "Die Sicherung der Laufwerke $($vols -join ', ') ist fehlgeschlagen (wbadmin Exitcode $($r3.ExitCode))."; Fix = 'Ursache in wbadmin-Laufwerke.log und im Protokoll der Windows Server-Sicherung. Haeufig: Platte voll, VSS-Fehler (vssadmin list writers).' } }
                Write-HMSbLog "Laufwerks-Sicherung FEHLGESCHLAGEN (Exitcode $($r3.ExitCode)) - wbadmin-Laufwerke.log" 'Error'
            } else {
                $volOk = $true
                Write-HMSbLog 'Laufwerks-Sicherung erfolgreich' 'Success'
                try {
                    $vv3 = Get-HMSbVersions $target
                    $l3 = @($vv3.Versions) | Select-Object -Last 1
                    if ($l3) { $res.VolVersionId = "$($l3.Id)"; Set-Content -LiteralPath (Join-Path $rep 'Versionen.txt') -Value $vv3.Text -Encoding UTF8 }
                    if ($Ctx.Verify -and $res.VolVersionId) {
                        $gi3 = Invoke-HMSbWbadmin -Arguments "get items -version:$($res.VolVersionId) -backupTarget:$target" -Quiet
                        Set-Content -LiteralPath (Join-Path $rep 'Inhalt-Laufwerke.txt') -Value $gi3.Text -Encoding UTF8
                        $missV = @($vols | Where-Object { $gi3.Text -notmatch [regex]::Escape($_) })
                        if ($gi3.ExitCode -ne 0 -or $missV.Count) {
                            if ($status -eq 'OK') { $status = 'Warning' }
                            $notes += "Pruefung Laufwerke: $(if ($missV.Count) { 'fehlt ' + ($missV -join ', ') } else { 'nicht moeglich' })"
                            $hints += [pscustomobject]@{ Lvl = 'Warning'; Text = "Die Pruefung der Laufwerks-Sicherung war nicht erfolgreich$(if ($missV.Count) { " (nicht gefunden: $($missV -join ', '))" })."; Fix = 'Inhalt-Laufwerke.txt ansehen, ggf. Sicherung wiederholen.' }
                            Write-HMSbLog 'Pruefung Laufwerke: nicht alle Laufwerke in der Version gefunden - siehe Inhalt-Laufwerke.txt' 'Warning'
                        } else { Write-HMSbLog "Pruefung OK: alle $($vols.Count) Laufwerk(e) in Version $($res.VolVersionId) enthalten" 'Success' }
                    }
                } catch { Write-HMSbLog "Versionen/Pruefung Laufwerke nicht moeglich: $($_.Exception.Message)" 'Warning' }
            }
        }
        if ($Job.Cancel) { throw 'Abgebrochen' }

        # --- Host-System (Bare-Metal)
        $hostSysOk = $false
        if ($Ctx.HostSystem) {
            $Job.Status = 'Host-System: wird vorbereitet ...'
            Write-HMSbLog "wbadmin: Host-System (alle kritischen Volumes, Bare-Metal) -> $target" 'Header'
            try {
                $sv = @(Get-VM -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Paths = @(Get-VMHardDiskDrive -VM $_ -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Path)" }); VmPath = "$($_.Path)"; ConfigPath = "$($_.ConfigurationLocation)" } })
                $svt = Format-HMSbSysDriveVms (Get-HMSbSysDriveVms $sv)
                if ($svt) { foreach ($ln in ($svt -split "`n")) { Write-HMSbLog $ln 'Warning' } }
            } catch { }
            $r2 = Invoke-HMSbStart -Arguments "start backup -backupTarget:$target -allCritical -quiet" -Phase 'Host-System' -PBase $pb -PSpan $span -LogFile (Join-Path $rep 'wbadmin-HostSystem.log') -Job $Job
            if ($Job.Cancel) {
                Write-HMSbLog 'Abbruch: laufende Sicherung wird beendet (wbadmin stop job) ...' 'Warning'
                [void](Invoke-HMSbWbadmin -Arguments 'stop job -quiet' -Quiet)
                throw 'Abgebrochen'
            }
            foreach ($lf in @($r2.LogFiles)) { try { Copy-Item -LiteralPath $lf -Destination $rep -Force -ErrorAction Stop } catch { } }
            if ($r2.ExitCode -ne 0) { if ($status -eq 'OK') { $status = 'Warning' }; $notes += "Host-System Exitcode $($r2.ExitCode)"; $hints += [pscustomobject]@{ Lvl = 'Warning'; Text = "Die Host-System-Sicherung ist fehlgeschlagen (Exitcode $($r2.ExitCode)). Die VM-Sicherung ist davon nicht betroffen."; Fix = $(if ($r2.Busy) { $script:HMSbBusyFix } else { 'Ursache in wbadmin-HostSystem.log.' }) }; Write-HMSbLog "Host-System-Sicherung FEHLGESCHLAGEN (Exitcode $($r2.ExitCode)) - wbadmin-HostSystem.log" 'Error' }
            else {
                $hostSysOk = $true
                Write-HMSbLog 'Host-System-Sicherung erfolgreich' 'Success'
                try { $vv2 = Get-HMSbVersions $target; $l2 = @($vv2.Versions) | Select-Object -Last 1; if ($l2) { $res.HostVersionId = "$($l2.Id)"; Set-Content -LiteralPath (Join-Path $rep 'Versionen.txt') -Value $vv2.Text -Encoding UTF8 } } catch { }
            }
        }
    } catch {
        $msg = "$($_.Exception.Message)"
        $status = 'Error'
        if ($msg -eq 'Abgebrochen' -or $Job.Cancel) { $notes += 'abgebrochen'; Write-HMSbLog 'Server-Backup ABGEBROCHEN - Lauf wird im Verlauf festgehalten' 'Error'; $hints += [pscustomobject]@{ Lvl = 'Error'; Text = 'Die Sicherung wurde abgebrochen.'; Fix = 'Sicherung erneut starten. Was bis zum Abbruch gesichert war, zeigt der Button Versionen auf der Platte.' } }
        else { $notes += "Fehler: $msg"; Write-HMSbLog "Server-Backup FEHLER: $msg" 'Error'; $hints += [pscustomobject]@{ Lvl = 'Error'; Text = "Die Sicherung ist mit einem Fehler abgebrochen: $msg"; Fix = 'Protokoll im Berichtsordner pruefen und erneut starten.' } }
    }

    # --- Verlauf, Bericht
    $Job.Status = 'Bericht'
    $dur = [math]::Round(((Get-Date) - $t0).TotalMinutes, 1)
    if (-not $vms.Count -and -not $vols.Count -and -not $Ctx.HostSystem -and -not $hostCfgOk) { $status = 'Error' }
    $entry = [pscustomobject][ordered]@{
        Date = $t0.ToString('yyyy-MM-dd HH:mm'); Profile = "$($Ctx.Profile)"; Host = $env:COMPUTERNAME; Disk = "$($Ctx.DiskLabel)"; DiskSerial = "$($Ctx.DiskSerial)"
        VMs = ($vms -join ', '); Volumes = ($vols -join ', '); VolVersionId = "$($res.VolVersionId)"; Status = $status; Minutes = $dur; SizeGB = [math]::Round($res.SizeBytes / 1GB, 1); VersionId = $verId
        HostConfig = $hostCfgOk; HostSystem = $hostSysOk; HostVersionId = "$($res.HostVersionId)"; Note = ($notes -join '; '); Tool = "HUMig $($Ctx.Version)"; Report = (Split-Path $rep -Leaf)
    }
    try { Add-HMSbHistory (Join-Path "$target\$($script:SbDirName)" 'history.json') $entry } catch { Write-HMSbLog "Verlauf auf der Platte nicht gespeichert: $($_.Exception.Message)" 'Warning' }
    if ($Ctx.LocalHistory) { try { Add-HMSbHistory "$($Ctx.LocalHistory)" $entry } catch { Write-HMSbLog "Verlauf im Tool-Ordner nicht gespeichert: $($_.Exception.Message)" 'Warning' } }
    try {
        Write-HMSbReport -Path (Join-Path $rep 'Bericht.html') -Entry $entry -Hints $hints -Folder $rep -Ctx $Ctx
        if ($Ctx.LocalReportDir) {
            $ld = Join-Path "$($Ctx.LocalReportDir)" (Split-Path $rep -Leaf)
            New-Item -ItemType Directory -Path $ld -Force | Out-Null
            Get-ChildItem -LiteralPath $rep -File -ErrorAction SilentlyContinue | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $ld -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath (Join-Path $rep 'Host-Konfiguration')) { Copy-Item -LiteralPath (Join-Path $rep 'Host-Konfiguration') -Destination $ld -Recurse -Force -ErrorAction SilentlyContinue }
        }
    } catch { Write-HMSbLog "Bericht: $($_.Exception.Message)" 'Warning' }
    # Schreibcache der Platte leeren (sicheres Abziehen)
    try { Write-VolumeCache -DriveLetter $L -ErrorAction Stop } catch { }

    $res.Status = $status
    $Job.Result = [pscustomobject]$res
    $Job.Progress = 100
    $lvl = switch ($status) { 'OK' { 'Success' } 'Warning' { 'Warning' } default { 'Error' } }
    Write-HMSbLog ("SERVER-BACKUP {0}: {1} in {2} - Bericht: {3}" -f $Ctx.Profile, $(switch ($status) { 'OK' { if ($notes.Count) { 'erfolgreich (mit Hinweis - siehe Bericht)' } else { 'erfolgreich' } } 'Warning' { 'mit Warnungen' } default { 'FEHLGESCHLAGEN' } }), (Format-HMDuration $dur), (Join-Path $rep 'Bericht.html')) $lvl
    Write-HMSbEvent $status ("Server-Backup '{0}' auf {1}: {2}`nPlatte: {3}`nVMs: {4}{5}`nHost-System: {6}`nDauer: {7}{8}`nBericht: {9}`nHUMig {10}" -f $Ctx.Profile, $env:COMPUTERNAME, $(switch ($status) { 'OK' { 'erfolgreich' } 'Warning' { 'mit Warnungen' } default { 'FEHLGESCHLAGEN' } }), "$($Ctx.DiskLabel)", $(if ($vms.Count) { $vms -join ', ' } else { '-' }), $(if ($vols.Count) { "`nLaufwerke: $($vols -join ', ')" } else { '' }), $(if ($Ctx.HostSystem) { $(if ($hostSysOk) { 'ja' } else { 'FEHLER' }) } else { 'nein' }), (Format-HMDuration $dur), $(if ($notes.Count) { "`nHinweis: $($notes -join '; ')" } else { '' }), (Join-Path $rep 'Bericht.html'), "$($Ctx.Version)")
    # Nach der Sicherung: Platte auswerfen / offline schalten (Einstellung je Platte)
    if ("$($Ctx.After)") { $Job.Status = 'Platte'; Invoke-HMSbAfterBackup -Letter $L -Mode "$($Ctx.After)" -Label "$($Ctx.DiskLabel)" }
    $script:SbRunLog = $null
    if ($status -eq 'Error') { $Job.Error = ($notes -join '; ') }
}
