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

$script:SbDirName = 'HUMig-ServerBackup'
$script:SbJob = $null

function Write-HMSbLog([string]$Msg, [string]$Lvl = 'Info') {
    if ($script:SbJob) { $script:SbJob.Log.Enqueue(@{ Msg = $Msg; Lvl = $Lvl }) }
}

function Get-HMSbOemEncoding {
    try { return [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage) } catch { return [System.Text.Encoding]::Default }
}

function ConvertTo-HMSbPsString([string]$s) { return "'" + ("$s" -replace "'", "''") + "'" }

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

# Virtuelle Computer des Hosts mit Groesse der virtuellen Festplatten
function Get-HMSbVmList {
    $list = @()
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
        }
    }
    return ,$list
}

# Moegliche Ziel-Laufwerke (nicht System/Start), offline geschaltete USB-Platten werden online geschaltet
function Get-HMSbDriveList {
    $msgs = @()
    foreach ($d in @(Get-Disk -ErrorAction SilentlyContinue | Where-Object { "$($_.BusType)" -match '^(USB|7)$' -and $_.IsOffline })) {
        try { Set-Disk -Number $d.Number -IsOffline $false -ErrorAction Stop; $msgs += "USB-Platte $($d.Number) ($($d.FriendlyName)) war offline - online geschaltet" }
        catch { $msgs += "USB-Platte $($d.Number) ist offline und konnte nicht online geschaltet werden: $($_.Exception.Message)" }
    }
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

# USB-Datentraeger fuer "Platte einrichten" (nie System/Start, nie Platten mit VM-Dateien)
function Get-HMSbDiskList {
    $vmLetters = @()
    try {
        foreach ($vm in @(Get-VM -ErrorAction Stop)) {
            foreach ($p in @("$($vm.Path)", "$($vm.ConfigurationLocation)") + @(Get-VMHardDiskDrive -VM $vm -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Path)" })) {
                if ($p -match '^([A-Za-z]):') { $vmLetters += $Matches[1].ToUpper() }
            }
        }
    } catch { }
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
        if (@($letters | Where-Object { $vmLetters -contains $_ }).Count) { continue }
        $out += [pscustomobject]@{
            Number = [int]$d.Number; Model = "$($d.FriendlyName)".Trim(); Serial = "$($d.SerialNumber)".Trim(); Bus = "$($d.BusType)"
            SizeBytes = [long]$d.Size; Style = "$($d.PartitionStyle)"; Offline = [bool]$d.IsOffline; Volumes = ($labels -join ', ')
        }
    }
    return ,$out
}

# USB-Platte neu einrichten: ALLE Daten loeschen, GPT, NTFS 64K, Bezeichnung
function Initialize-HMSbDisk([int]$Number, [string]$Label, [string]$Profile = '') {
    if ($Label -notmatch '^[A-Za-z0-9_\-]{1,32}$') { throw "Ungueltige Bezeichnung '$Label' (max. 32 Zeichen: A-Z, 0-9, - und _)" }
    $d = Get-Disk -Number $Number -ErrorAction Stop
    if ($d.IsBoot -or $d.IsSystem) { throw "Datentraeger $Number ist System-/Startdatentraeger - abgebrochen" }
    if ("$($d.BusType)" -notmatch '^(USB|7)$') { throw "Datentraeger $Number ist kein USB-Datentraeger ($($d.BusType)) - abgebrochen" }
    if ($d.IsOffline) { Set-Disk -Number $Number -IsOffline $false -ErrorAction Stop }
    if ($d.IsReadOnly) { Set-Disk -Number $Number -IsReadOnly $false -ErrorAction Stop }
    $d = Get-Disk -Number $Number -ErrorAction Stop
    if ("$($d.PartitionStyle)" -ne 'RAW') { Clear-Disk -Number $Number -RemoveData -RemoveOEM -Confirm:$false -ErrorAction Stop }
    $d = Get-Disk -Number $Number -ErrorAction Stop
    if ("$($d.PartitionStyle)" -eq 'RAW') { Initialize-Disk -Number $Number -PartitionStyle GPT -ErrorAction Stop }
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

    # Hyper-V-Host
    $cfg.VMHost = $null
    try {
        $h = Get-VMHost -ErrorAction Stop
        $cfg.VMHost = [ordered]@{
            VirtualHardDiskPath = "$($h.VirtualHardDiskPath)"; VirtualMachinePath = "$($h.VirtualMachinePath)"
            LogicalProcessorCount = $h.LogicalProcessorCount; MemoryCapacityGB = [math]::Round([double]$h.MemoryCapacity / 1GB, 1)
            NumaSpanningEnabled = [bool]$h.NumaSpanningEnabled; EnableEnhancedSessionMode = [bool]$h.EnableEnhancedSessionMode
            VirtualMachineMigrationEnabled = [bool]$h.VirtualMachineMigrationEnabled; MaximumVirtualMachineMigrations = $h.MaximumVirtualMachineMigrations
            MaximumStorageMigrations = $h.MaximumStorageMigrations; MacAddressMinimum = "$($h.MacAddressMinimum)"; MacAddressMaximum = "$($h.MacAddressMaximum)"
        }
    } catch { $warn += "Get-VMHost: $($_.Exception.Message)" }

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
    try {
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
    } catch { $warn += "Get-VMSwitch: $($_.Exception.Message)" }
    $cfg.Switches = $sw

    # Host-Netzwerkadapter (vEthernet) inkl. VLAN
    $mg = @()
    try {
        foreach ($a in @(Get-VMNetworkAdapter -ManagementOS -ErrorAction Stop)) {
            $v = Get-HMSbVlanInfo $a
            $mg += [ordered]@{ Name = "$($a.Name)"; SwitchName = "$($a.SwitchName)"; MacAddress = "$($a.MacAddress)"; VlanMode = $v.VlanMode; AccessVlanId = $v.AccessVlanId; NativeVlanId = $v.NativeVlanId; AllowedVlans = $v.AllowedVlans }
        }
    } catch { $warn += "Host-vNICs: $($_.Exception.Message)" }
    $cfg.ManagementAdapters = $mg

    # Virtuelle Computer
    $vms = @()
    try {
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
    } catch { $warn += "Get-VM: $($_.Exception.Message)" }
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

# ----------------------------------------------------------------------------
# Hauptablauf (Hintergrund-Runspace)
#   Ctx: Profile, DiskPrefix, Drive (Buchstabe), DiskLabel, DiskSerial, VMs (Namen), HostConfig, HostSystem, Verify, LocalHistory, LocalReportDir, Version
# ----------------------------------------------------------------------------
function Start-HMServerBackup {
    param([hashtable]$Ctx, [hashtable]$Job)
    $script:SbJob = $Job
    $t0 = Get-Date
    $status = 'OK'; $notes = @()
    $L = "$($Ctx.Drive)".TrimEnd(':', '\').ToUpper()
    $target = "${L}:"
    $vms = @($Ctx.VMs | Where-Object { "$_".Trim() })
    $res = [ordered]@{ Status = 'Error'; SizeBytes = [long]0; Report = ''; VersionId = ''; HostVersionId = '' }
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
            if ([int]$v.Checkpoints -ge 2) { Write-HMSbLog "Hinweis: VM '$n' hat $($v.Checkpoints) Pruefpunkte - die Windows Server-Sicherung stellt VMs mit 2+ Pruefpunkten nicht direkt wieder her (MS KB 958662). Pruefpunkte moeglichst zusammenfuehren." 'Warning' }
            $info += $v
        }
        $res.SizeBytes = [long](@($info | Measure-Object -Property SizeBytes -Sum).Sum)
        Write-HMSbLog ("{0} VM(s): {1} - virtuelle Festplatten ca. {2:N1} GB" -f $vms.Count, ($vms -join ', '), ($res.SizeBytes / 1GB)) 'Info'
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

    # --- Host-Konfiguration
    $hostCfgOk = $false
    if ($Ctx.HostConfig) {
        $Job.Status = 'Host-Konfiguration'
        try {
            $hc = Export-HMSbHostConfig -Dest (Join-Path $rep 'Host-Konfiguration')
            $hostCfgOk = $true
            Write-HMSbLog "Host-Konfiguration gesichert: $($hc.Switches) Switch(es), $($hc.ManagementAdapters) Host-vNIC(s), $($hc.VMs) VM(s) -> Host-Konfiguration\ (HTML, JSON, Restore-VMSwitches.ps1)" 'Success'
            foreach ($w in @($hc.Warnings)) { Write-HMSbLog "  Host-Konfiguration: $w" 'Warning' }
        } catch { Write-HMSbLog "Host-Konfiguration nicht gesichert: $($_.Exception.Message)" 'Warning'; $notes += 'Host-Konfiguration fehlgeschlagen'; $status = 'Warning' }
    }
    if ($Job.Cancel) { throw 'Abgebrochen' }

    $spanVm = $(if ($Ctx.HostSystem) { 70 } else { 95 })
    # --- VMs sichern
    $verId = ''
    if ($vms.Count) {
        Write-HMSbLog "wbadmin: VMs sichern -> $target (Online-Sicherung ueber VSS, VMs laufen weiter)" 'Header'
        $argList = "start backup -backupTarget:$target -hyperv:""$($vms -join ',')"" -quiet"
        $r = Invoke-HMSbWbadmin -Arguments $argList -Phase 'VMs' -PBase 2 -PSpan $spanVm -LogFile (Join-Path $rep 'wbadmin-VMs.log')
        if ($Job.Cancel) {
            Write-HMSbLog 'Abbruch: laufende Sicherung wird beendet (wbadmin stop job) ...' 'Warning'
            [void](Invoke-HMSbWbadmin -Arguments 'stop job -quiet' -Quiet)
            throw 'Abgebrochen'
        }
        foreach ($lf in @($r.LogFiles)) { try { Copy-Item -LiteralPath $lf -Destination $rep -Force -ErrorAction Stop } catch { } }
        if ($r.ExitCode -ne 0) { $status = 'Error'; $notes += "VM-Sicherung Exitcode $($r.ExitCode)"; Write-HMSbLog "VM-Sicherung FEHLGESCHLAGEN (wbadmin Exitcode $($r.ExitCode)) - Details: wbadmin-VMs.log im Berichtsordner" 'Error' }
        else {
            if (@($r.Lines | Where-Object { $_ -match '\(Offline\)' }).Count) { $notes += 'VM(s) offline gesichert (gespeicherter Zustand)'; if ($status -eq 'OK') { $status = 'Warning' }; Write-HMSbLog 'Mindestens eine VM wurde OFFLINE gesichert (kurz in gespeicherten Zustand versetzt) - Integrationsdienste/Pruefpunkte der VM pruefen.' 'Warning' }
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
                if ($gi.ExitCode -ne 0) { Write-HMSbLog "Pruefung: wbadmin get items Exitcode $($gi.ExitCode) - siehe Inhalt.txt" 'Warning'; if ($status -eq 'OK') { $status = 'Warning' } }
                elseif ($miss.Count) { Write-HMSbLog "Pruefung: in Version $verId NICHT gefunden: $($miss -join ', ') - siehe Inhalt.txt" 'Warning'; $notes += "Pruefung: fehlt $($miss -join ', ')"; if ($status -eq 'OK') { $status = 'Warning' } }
                else { Write-HMSbLog "Pruefung OK: alle $($vms.Count) VM(s) in Version $verId enthalten" 'Success' }
            }
        } catch { Write-HMSbLog "Versionen/Pruefung nicht moeglich: $($_.Exception.Message)" 'Warning' }
    }
    if ($Job.Cancel) { throw 'Abgebrochen' }

    # --- Host-System (Bare-Metal)
    $hostSysOk = $false
    if ($Ctx.HostSystem) {
        Write-HMSbLog "wbadmin: Host-System (alle kritischen Volumes, Bare-Metal) -> $target" 'Header'
        $r2 = Invoke-HMSbWbadmin -Arguments "start backup -backupTarget:$target -allCritical -quiet" -Phase 'Host-System' -PBase (2 + $spanVm) -PSpan (97 - 2 - $spanVm) -LogFile (Join-Path $rep 'wbadmin-HostSystem.log')
        if ($Job.Cancel) {
            Write-HMSbLog 'Abbruch: laufende Sicherung wird beendet (wbadmin stop job) ...' 'Warning'
            [void](Invoke-HMSbWbadmin -Arguments 'stop job -quiet' -Quiet)
            throw 'Abgebrochen'
        }
        foreach ($lf in @($r2.LogFiles)) { try { Copy-Item -LiteralPath $lf -Destination $rep -Force -ErrorAction Stop } catch { } }
        if ($r2.ExitCode -ne 0) { if ($status -eq 'OK') { $status = 'Warning' }; $notes += "Host-System Exitcode $($r2.ExitCode)"; Write-HMSbLog "Host-System-Sicherung FEHLGESCHLAGEN (Exitcode $($r2.ExitCode)) - wbadmin-HostSystem.log" 'Error' }
        else {
            $hostSysOk = $true
            Write-HMSbLog 'Host-System-Sicherung erfolgreich' 'Success'
            try { $vv2 = Get-HMSbVersions $target; $l2 = @($vv2.Versions) | Select-Object -Last 1; if ($l2) { $res.HostVersionId = "$($l2.Id)"; Set-Content -LiteralPath (Join-Path $rep 'Versionen.txt') -Value $vv2.Text -Encoding UTF8 } } catch { }
        }
    }

    # --- Verlauf, Bericht
    $Job.Status = 'Bericht'
    $dur = [math]::Round(((Get-Date) - $t0).TotalMinutes, 1)
    if (-not $vms.Count -and -not $Ctx.HostSystem -and -not $hostCfgOk) { $status = 'Error' }
    $entry = [pscustomobject][ordered]@{
        Date = $t0.ToString('yyyy-MM-dd HH:mm'); Profile = "$($Ctx.Profile)"; Host = $env:COMPUTERNAME; Disk = "$($Ctx.DiskLabel)"; DiskSerial = "$($Ctx.DiskSerial)"
        VMs = ($vms -join ', '); Status = $status; Minutes = $dur; SizeGB = [math]::Round($res.SizeBytes / 1GB, 1); VersionId = $verId
        HostConfig = $hostCfgOk; HostSystem = $hostSysOk; HostVersionId = "$($res.HostVersionId)"; Note = ($notes -join '; '); Tool = "HUMig $($Ctx.Version)"
    }
    try { Add-HMSbHistory (Join-Path "$target\$($script:SbDirName)" 'history.json') $entry } catch { Write-HMSbLog "Verlauf auf der Platte nicht gespeichert: $($_.Exception.Message)" 'Warning' }
    if ($Ctx.LocalHistory) { try { Add-HMSbHistory "$($Ctx.LocalHistory)" $entry } catch { Write-HMSbLog "Verlauf im Tool-Ordner nicht gespeichert: $($_.Exception.Message)" 'Warning' } }
    try {
        $enc = { param($s) [System.Net.WebUtility]::HtmlEncode("$s") }
        $rows = ''
        foreach ($p in $entry.PSObject.Properties) { $rows += "<tr><th>$(& $enc $p.Name)</th><td>$(& $enc $p.Value)</td></tr>" }
        $col = switch ($status) { 'OK' { '#2e7d32' } 'Warning' { '#e69500' } default { '#c62828' } }
        $html = "<!DOCTYPE html><html><head><meta charset='utf-8'><title>Server-Backup $(& $enc $Ctx.Profile)</title><style>body{font-family:Segoe UI,Arial;font-size:13px;margin:20px}table{border-collapse:collapse}th,td{border:1px solid #bbb;padding:3px 8px;text-align:left}th{background:#eee}</style></head><body>" +
            "<h1 style='color:$col'>Server-Backup $(& $enc $Ctx.Profile): $(& $enc $status)</h1><table>$rows</table>" +
            "<p>Dateien in diesem Ordner: wbadmin-*.log (Ausgabe), Versionen.txt, Inhalt.txt (Pruefung), Host-Konfiguration\ (HostConfig.html, Restore-VMSwitches.ps1).</p></body></html>"
        [System.IO.File]::WriteAllText((Join-Path $rep 'Bericht.html'), $html, (New-Object System.Text.UTF8Encoding($true)))
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
    Write-HMSbLog ("SERVER-BACKUP {0}: {1} in {2} min - Bericht: {3}" -f $Ctx.Profile, $(switch ($status) { 'OK' { 'erfolgreich' } 'Warning' { 'mit Warnungen' } default { 'FEHLGESCHLAGEN' } }), $dur, (Join-Path $rep 'Bericht.html')) $lvl
    if ($status -eq 'Error') { $Job.Error = ($notes -join '; ') }
}
