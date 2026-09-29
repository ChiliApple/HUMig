#Requires -Version 5.1
<#
.SYNOPSIS
    Werkzeuge fuer den Betrieb mehrerer PCs: Inventar mehrerer PCs (CSV), alte Profile loeschen, BitLocker-Schluessel pruefen/sichern,
    Autopilot-Hardware-Hash, Wake-on-LAN, wichtige Dateien ausserhalb des Profils finden, Suche im Backup.
.NOTES
    Wird im UI-Thread geladen (dot-source aus HUMig.ps1). Remote-Teile laufen ueber Invoke-HMTool / Invoke-AsyncCommand.
#>

# ----------------------------------------------------------------------------
# Inventar (mehrere PCs parallel ueber WinRM) -> Tabelle + CSV im Backup-Ordner\Inventar
# ----------------------------------------------------------------------------
$script:RS_Inventory = {
    param([bool]$WithSoftware)
    $ErrorActionPreference = 'SilentlyContinue'
    $cs = Get-CimInstance Win32_ComputerSystem; $os = Get-CimInstance Win32_OperatingSystem; $bios = Get-CimInstance Win32_BIOS
    $prod = Get-CimInstance Win32_ComputerSystemProduct; $cpu = @(Get-CimInstance Win32_Processor)[0]
    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
    $media = ''; try { $pd = @(Get-PhysicalDisk -ErrorAction Stop | Sort-Object DeviceId)[0]; $media = "$($pd.MediaType) $($pd.BusType)".Trim() } catch { }
    $bl = '?'; try { $v = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction Stop; $bl = "$($v.ProtectionStatus) ($($v.VolumeStatus))" } catch { }
    $tpm = '?'; try { $t = Get-Tpm -ErrorAction Stop; $tpm = if ($t.TpmPresent) { if ($t.TpmReady) { 'bereit' } else { 'vorhanden' } } else { 'keins' } } catch { }
    $sb = '-'; try { $sb = if (Confirm-SecureBootUEFI -ErrorAction Stop) { 'an' } else { 'aus' } } catch { }
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $net = @(Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True')
    $join = ''
    try {
        $ds = @(& dsregcmd.exe /status 2>$null)
        $aad = (($ds | Where-Object { $_ -match '^\s*AzureAdJoined\s*:' }) -replace '.*:\s*', '').Trim()
        $dj = (($ds | Where-Object { $_ -match '^\s*DomainJoined\s*:' }) -replace '.*:\s*', '').Trim()
        $join = "Domaene $dj / Entra $aad"
    } catch { }
    $model = if ("$($cs.Manufacturer)" -match 'LENOVO' -and $prod.Version) { "$($prod.Version) ($($cs.Model))" } else { "$($cs.Model)" }
    $sw = @()
    if ($WithSoftware) {
        $sw = @($(foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
            foreach ($k in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
                $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
                if ($p.DisplayName -and $p.SystemComponent -ne 1 -and -not $p.ParentKeyName) { "$($p.DisplayName)|$($p.DisplayVersion)|$($p.Publisher)" }
            }
        }) | Sort-Object -Unique)
    }
    [pscustomobject]@{
        Computer = $env:COMPUTERNAME; Hersteller = "$($cs.Manufacturer)".Trim(); Modell = $model.Trim(); Seriennummer = "$($bios.SerialNumber)".Trim(); BIOS = "$($bios.SMBIOSBIOSVersion)"
        Windows = "$($os.Caption)" -replace '^Microsoft ', ''; Version = "$($cv.DisplayVersion)"; Build = "$($os.BuildNumber).$($cv.UBR)"
        CPU = "$($cpu.Name)".Trim(); RAM_GB = [math]::Round([double]$cs.TotalPhysicalMemory / 1GB, 1)
        C_GB = [math]::Round([double]$disk.Size / 1GB, 0); C_frei_GB = [math]::Round([double]$disk.FreeSpace / 1GB, 1); Datentraeger = $media
        BitLocker = $bl; TPM = $tpm; SecureBoot = $sb; Beitritt = $join; Domaene = "$($cs.Domain)"
        IP = (@($net | ForEach-Object { @($_.IPAddress) | Where-Object { $_ -match '^\d+\.' } }) -join ', '); MAC = (@($net | ForEach-Object { $_.MACAddress }) -join ', ')
        Angemeldet = "$($cs.UserName)"; Letzter_Start = $os.LastBootUpTime; Software = $sw
    }
}
function Start-HMInventory([bool]$WithSoftware, [string[]]$Hosts = @()) {
    $list = @($Hosts | Where-Object { $_ } | Select-Object -Unique)
    if (-not $list.Count) {
        $hist = @(Read-JsonFile $script:ComputerHistoryFile | Where-Object { $_ })
        $pre = (@(Get-TargetComputer) + $hist + @($script:MultiHosts) | Where-Object { $_ } | Select-Object -Unique) -join "`r`n"
        $txt = Show-TextInputDialog -Title "Inventar$(if ($WithSoftware) { ' + Software' })" -Label 'PC-Namen oder IP-Adressen (je Zeile, auch mit Komma/Leerzeichen getrennt). Abfrage parallel ueber WinRM. Tipp: Knopf "Geraete (AD)" fuer die Auswahl aus dem AD.' -Text $pre -MultiLine
        if (-not $txt) { return }
        $list = @($txt -split '[\s,;]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
    }
    if (-not $list.Count) { return }
    Out-Console "Inventar: $($list.Count) PC(s) werden abgefragt$(if ($WithSoftware) { ' (mit Software)' }) ..." 'Info'
    Invoke-AsyncCommand -ScriptBlock {
        param($hosts, $cred, $text, $withSw)
        $sb = [scriptblock]::Create($text)
        $out = [System.Collections.Generic.List[object]]::new()
        $remote = [System.Collections.Generic.List[string]]::new()
        foreach ($h in $hosts) {
            if ($h -eq '.' -or $h -ieq 'localhost' -or $h -ieq $env:COMPUTERNAME -or $h -ilike "$($env:COMPUTERNAME).*") { try { $o = & $sb $withSw; $o | Add-Member -NotePropertyName Ziel -NotePropertyValue $h -Force; $out.Add($o) } catch { $out.Add([pscustomobject]@{ Ziel = $h; Fehler = $_.Exception.Message }) } }
            else { $remote.Add($h) }
        }
        if ($remote.Count) {
            $opt = New-PSSessionOption -OpenTimeout 20000 -OperationTimeout 300000
            $p = @{ ComputerName = $remote.ToArray(); ScriptBlock = $sb; ArgumentList = @($withSw); ThrottleLimit = 32; SessionOption = $opt; ErrorAction = 'SilentlyContinue'; ErrorVariable = 'ev' }
            if ($cred) { $p.Credential = $cred }
            $ev = $null
            $res = @(Invoke-Command @p)
            $seen = @{}
            foreach ($r in $res) { $n = "$($r.PSComputerName)"; $seen[$n.ToUpper()] = 1; $r | Add-Member -NotePropertyName Ziel -NotePropertyValue $n -Force; $out.Add($r) }
            $errs = @{}
            foreach ($e in @($ev)) { $t = "$($e.TargetObject)"; if (-not $t -and $e.OriginInfo) { $t = "$($e.OriginInfo.PSComputerName)" }; if ($t) { $errs[$t.ToUpper()] = "$($e.Exception.Message)" } }
            foreach ($h in $remote) { if (-not $seen.ContainsKey($h.ToUpper())) { $out.Add([pscustomobject]@{ Ziel = $h; Fehler = $(if ($errs.ContainsKey($h.ToUpper())) { $errs[$h.ToUpper()] } else { 'keine Antwort' }) }) } }
        }
        $out.ToArray()
    } -ArgumentList @($list, $script:RemoteCred, $script:RS_Inventory.ToString(), $WithSoftware) -TimeoutSec 900 -State @{ Sw = $WithSoftware; Count = $list.Count } -OnComplete {
        param($r, $st)
        if ("$r" -match '^FEHLER' -and -not ($r -is [System.Array])) { Out-Console "Inventar: $r" 'Error'; return }
        $cols = @('Ziel', 'Status', 'Computer', 'Hersteller', 'Modell', 'Seriennummer', 'BIOS', 'Windows', 'Version', 'Build', 'CPU', 'RAM_GB', 'C_GB', 'C_frei_GB', 'Datentraeger', 'BitLocker', 'TPM', 'SecureBoot', 'Beitritt', 'Domaene', 'IP', 'MAC', 'Angemeldet', 'Letzter_Start')
        $rows = [System.Collections.Generic.List[object]]::new()
        $swRows = [System.Collections.Generic.List[object]]::new()
        $csv = [System.Collections.Generic.List[object]]::new()
        $macs = @{}; try { $mc = Read-JsonFile (Join-Path $script:ConfigDir 'mac_cache.json'); if ($mc) { foreach ($x in $mc.PSObject.Properties) { $macs[$x.Name] = "$($x.Value)" } } } catch { }
        $ok = 0
        foreach ($x in @($r)) {
            if (-not $x) { continue }
            $err = "$($x.Fehler)"
            if (-not $err) { $ok++ }
            $o = [ordered]@{}
            foreach ($c in $cols) {
                $o[$c] = switch ($c) {
                    'Status' { if ($err) { Format-RemoteError $err } else { 'OK' } }
                    'Letzter_Start' { if ($x.Letzter_Start) { ([datetime]$x.Letzter_Start).ToString('yyyy-MM-dd HH:mm') } else { '' } }
                    default { "$($x.$c)" }
                }
            }
            $rows.Add(@($cols | ForEach-Object { $o[$_] })); $csv.Add([pscustomobject]$o)
            if (-not $err -and $x.MAC -and $x.Computer) { $macs["$($x.Computer)".ToUpper()] = "$($x.MAC)".Split(',')[0].Trim() }
            foreach ($s in @($x.Software | Where-Object { $_ })) { $p = "$s".Split('|'); $swRows.Add(@("$($x.Computer)", $p[0], $(if ($p.Count -gt 1) { $p[1] }), $(if ($p.Count -gt 2) { $p[2] }))) }
        }
        try { Write-JsonFile (Join-Path $script:ConfigDir 'mac_cache.json') ([pscustomobject]$macs) } catch { }
        $file = $null
        try {
            $dir = Join-Path (Get-BackupRoot) 'Inventar'
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            $file = Join-Path $dir ("Inventar_{0}.csv" -f (Get-Date -Format 'yyyy-MM-dd_HHmm'))
            $csv | Export-Csv -LiteralPath $file -NoTypeInformation -Delimiter ';' -Encoding UTF8
            if ($swRows.Count) {
                $swRows | ForEach-Object { [pscustomobject][ordered]@{ Computer = $_[0]; Programm = $_[1]; Version = $_[2]; Hersteller = $_[3] } } | Export-Csv -LiteralPath ($file -replace '\.csv$', '_Software.csv') -NoTypeInformation -Delimiter ';' -Encoding UTF8
            }
        } catch { Out-Console "Inventar-CSV nicht gespeichert: $($_.Exception.Message)" 'Warning' }
        Out-Console "Inventar: $ok von $($rows.Count) PC(s) erreicht$(if ($file) { " - $file" })" $(if ($ok -eq $rows.Count) { 'Success' } else { 'Warning' })
        Show-DataGridWindow -Title 'Inventar' -Columns $cols -ColumnTypes @{ RAM_GB = [double]; C_GB = [double]; C_frei_GB = [double] } -Rows $rows.ToArray() -Sort 'Status DESC, Ziel ASC' -CountText "$ok von $($rows.Count) erreicht - CSV: Backup-Ordner\Inventar" -Width 1500 -Height 620
        if ($swRows.Count) { Show-DataGridWindow -Title 'Inventar - Software' -Columns @('Computer', 'Programm', 'Version', 'Hersteller') -Rows $swRows.ToArray() -Sort 'Programm ASC, Computer ASC' -Width 1100 -Height 620 }
    }
}

# ----------------------------------------------------------------------------
# Alte Profile anzeigen und loeschen (Win32_UserProfile.Delete: Ordner + Registry)
# ----------------------------------------------------------------------------
function Show-HMOldProfiles {
    $c = Get-TargetComputer
    Invoke-HMTool -Title 'Profile auflisten' -Computer $c -TimeoutSec 300 -Script {
        foreach ($p in @(Get-CimInstance Win32_UserProfile | Where-Object { -not $_.Special -and $_.LocalPath -notmatch '\\(systemprofile|LocalService|NetworkService)$' -and "$($_.SID)" -match '^S-1-(5-21|12-1)-' })) {
            $name = ''; try { $name = (New-Object System.Security.Principal.SecurityIdentifier($p.SID)).Translate([System.Security.Principal.NTAccount]).Value } catch { $name = '(Konto unbekannt/geloescht)' }
            $nt = $null; try { $nt = (Get-Item -LiteralPath (Join-Path $p.LocalPath 'NTUSER.DAT') -Force -ErrorAction Stop).LastWriteTime } catch { }
            [pscustomobject]@{ Konto = $name; Pfad = "$($p.LocalPath)"; SID = "$($p.SID)"; Geladen = [bool]$p.Loaded; Zuletzt = $p.LastUseTime; NtUser = $nt }
        }
    } -OnResult {
        param($r, $comp)
        $rows = [System.Collections.Generic.List[object]]::new()
        foreach ($x in @($r)) {
            if (-not $x -or -not $x.SID) { continue }
            $last = if ($x.NtUser) { [datetime]$x.NtUser } elseif ($x.Zuletzt) { [datetime]$x.Zuletzt } else { $null }
            $age = if ($last) { [int]((Get-Date) - $last).TotalDays } else { $null }
            $rows.Add(@("$($x.Konto)", "$($x.Pfad)", $last, $age, $(if ($x.Geladen) { 'JA' } else { '' }), "$($x.SID)"))
        }
        Show-DataGridWindow -Title "Profile - $comp" -Columns @('Konto', 'Pfad', 'Letzte Anmeldung', 'Tage', 'Angemeldet', 'SID') -ColumnTypes @{ 'Letzte Anmeldung' = [datetime]; Tage = [int] } -Rows $rows.ToArray() `
            -Sort 'Tage DESC' -CountText "$($rows.Count) Profile - letzte Anmeldung = Aenderung von NTUSER.DAT" -Width 1150 -Height 560 -ActionContext @{ Computer = $comp } -Actions @(
                @{ Text = 'Markierte Profile loeschen'; Color = '#FFF38BA8'; Handler = {
                    param($rows, $win, $ctx)
                    $sel = @($rows | Where-Object { "$($_.Angemeldet)" -ne 'JA' })
                    if (-not $sel.Count) { [void][System.Windows.MessageBox]::Show($win, 'Angemeldete Profile koennen nicht geloescht werden.', 'Profile', 'OK', 'Information'); return }
                    $txt = ($sel | Select-Object -First 15 | ForEach-Object { "$($_.Konto)  ($($_.Pfad))" }) -join "`n"
                    if ("$([System.Windows.MessageBox]::Show($win, "$($sel.Count) Profil(e) an $($ctx.Computer) ENDGUELTIG loeschen (Ordner + Registry)?`n`n$txt`n`nTipp: vorher sichern (Backup) oder 'Profil erneuern' verwenden, wenn es nur um einen Test geht.", 'Profile loeschen', 'YesNo', 'Warning'))" -ne 'Yes') { return }
                    $sids = @($sel | ForEach-Object { "$($_.SID)" })
                    $win.Close()
                    Invoke-HMTool -Title 'Profile loeschen' -Computer $ctx.Computer -TimeoutSec 1800 -ArgumentList @(, $sids) -Script {
                        param($sids)
                        foreach ($s in $sids) {
                            try {
                                $p = Get-CimInstance Win32_UserProfile -Filter "SID='$s'" -ErrorAction Stop
                                if (-not $p) { "WARN $s nicht gefunden"; continue }
                                if ($p.Loaded) { "FEHLER $($p.LocalPath): angemeldet"; continue }
                                $p | Remove-CimInstance -ErrorAction Stop
                                "OK $($p.LocalPath) geloescht"
                            } catch { "FEHLER ${s}: $($_.Exception.Message)" }
                        }
                    }
                } }
            )
    }
}

# ----------------------------------------------------------------------------
# BitLocker: Status + Schluesselschutz, Wiederherstellungsschluessel in AD / Entra ID sichern
# ----------------------------------------------------------------------------
function Show-HMBitLockerKeys {
    $c = Get-TargetComputer
    Invoke-HMTool -Title 'BitLocker-Schluessel' -Computer $c -Script {
        try { $vols = @(Get-BitLockerVolume -ErrorAction Stop) } catch { "FEHLER: BitLocker-Modul nicht verfuegbar: $($_.Exception.Message)"; return }
        foreach ($v in $vols) {
            $kps = @($v.KeyProtector)
            if (-not $kps.Count) { [pscustomobject]@{ LW = "$($v.MountPoint)"; Status = "$($v.ProtectionStatus)"; Prozent = [int]$v.EncryptionPercentage; Methode = "$($v.EncryptionMethod)"; Typ = '(kein Schutz)'; Id = ''; Kennwort = '' }; continue }
            foreach ($k in $kps) {
                [pscustomobject]@{ LW = "$($v.MountPoint)"; Status = "$($v.ProtectionStatus) / $($v.VolumeStatus)"; Prozent = [int]$v.EncryptionPercentage; Methode = "$($v.EncryptionMethod)"; Typ = "$($k.KeyProtectorType)"; Id = "$($k.KeyProtectorId)"; Kennwort = "$($k.RecoveryPassword)" }
            }
        }
    } -OnResult {
        param($r, $comp)
        $rows = [System.Collections.Generic.List[object]]::new()
        foreach ($x in @($r)) { if ($x -and $x.LW) { $rows.Add(@("$($x.LW)", "$($x.Status)", [int]$x.Prozent, "$($x.Methode)", "$($x.Typ)", "$($x.Id)", "$($x.Kennwort)")) } }
        if (-not $rows.Count) { Out-Console "Keine BitLocker-Daten von $comp." 'Warning'; return }
        $hasRp = @($rows | Where-Object { $_[4] -eq 'RecoveryPassword' }).Count
        if (-not $hasRp) { Out-Console "$comp : kein Wiederherstellungskennwort vorhanden - ohne Schluessel ist ein TPM-Fehler/Board-Tausch nicht mehr zu retten!" 'Warning' }
        Show-DataGridWindow -Title "BitLocker - $comp" -Columns @('LW', 'Status', 'Prozent', 'Methode', 'Typ', 'Id', 'Kennwort') -ColumnTypes @{ Prozent = [int] } -Rows $rows.ToArray() -Width 1250 -Height 420 `
            -CountText 'Wiederherstellungskennwort markieren und sichern: AD (Domaenen-PC) oder Entra ID (Entra-/Hybrid-PC)' -ActionContext @{ Computer = $comp } -Actions @(
                @{ Text = 'In AD sichern'; Color = '#FF89B4FA'; Handler = { param($rows, $win, $ctx) Start-HMBitLockerBackup $ctx.Computer $rows 'AD' } }
                @{ Text = 'In Entra ID sichern'; Color = '#FFCBA6F7'; Handler = { param($rows, $win, $ctx) Start-HMBitLockerBackup $ctx.Computer $rows 'AAD' } }
            )
    }
}
function Start-HMBitLockerBackup([string]$Computer, $Rows, [string]$Where) {
    $sel = @($Rows | Where-Object { $_.Typ -eq 'RecoveryPassword' -and $_.Id })
    if (-not $sel.Count) { Out-Console 'Bitte Zeilen vom Typ RecoveryPassword markieren.' 'Warning'; return }
    $items = @($sel | ForEach-Object { @{ LW = "$($_.LW)"; Id = "$($_.Id)" } })
    Invoke-HMTool -Title "BitLocker-Schluessel in $(if ($Where -eq 'AD') { 'AD' } else { 'Entra ID' }) sichern" -Computer $Computer -ArgumentList @($Where, ($items | ConvertTo-Json -Compress)) -Script {
        param($where, $json)
        $arr = $json | ConvertFrom-Json   # PS 5.1: Array kommt als ein Objekt -> foreach ueber die Variable zaehlt korrekt auf
        foreach ($i in $arr) {
            try {
                if ($where -eq 'AD') { Backup-BitLockerKeyProtector -MountPoint $i.LW -KeyProtectorId $i.Id -ErrorAction Stop | Out-Null }
                else { BackupToAAD-BitLockerKeyProtector -MountPoint $i.LW -KeyProtectorId $i.Id -ErrorAction Stop | Out-Null }
                "OK $($i.LW) $($i.Id) gesichert"
            } catch { "FEHLER $($i.LW): $($_.Exception.Message)" }
        }
    }
}

# ----------------------------------------------------------------------------
# Autopilot: Hardware-Hash als CSV (fuer Intune > Geraete > Windows-Registrierung > Importieren)
# ----------------------------------------------------------------------------
function Start-HMAutopilotHash {
    $c = Get-TargetComputer
    $f = Show-HMFormDialog -Title "Autopilot-Hash - $c" -OkText 'Auslesen' -Fields @(
        @{ Name = 'Tag'; Label = 'Gruppentag (optional):'; Type = 'Text'; Default = '' }
        @{ Type = 'Info'; Label = 'Liest den Hardware-Hash ueber WMI (MDM-Bridge, Administratorrechte noetig) und speichert eine CSV im Backup-Ordner\Autopilot. Import: Intune > Geraete > Windows > Registrierung > Geraete > Importieren.' }
    )
    if (-not $f) { return }
    Invoke-HMTool -Title 'Autopilot-Hash' -Computer $c -ArgumentList @("$($f.Tag)") -Script {
        param($tag)
        try {
            $d = Get-CimInstance -Namespace 'root/cimv2/mdm/dmmap' -ClassName 'MDM_DevDetail_Ext01' -Filter "InstanceID='Ext' AND ParentID='./DevDetail'" -ErrorAction Stop
            $sn = "$((Get-CimInstance Win32_BIOS).SerialNumber)".Trim()
            if (-not $d.DeviceHardwareData) { 'FEHLER: kein Hardware-Hash (Administratorrechte? Windows-Edition?)'; return }
            [pscustomobject]@{ Serial = $sn; Hash = "$($d.DeviceHardwareData)"; Tag = $tag; Computer = $env:COMPUTERNAME }
        } catch { "FEHLER: $($_.Exception.Message)" }
    } -OnResult {
        param($r, $comp)
        $x = @($r | Where-Object { $_ -and $_.Hash })[0]
        if (-not $x) { Write-HMToolResult $r; return }
        try {
            $dir = Join-Path (Get-BackupRoot) 'Autopilot'
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            $sn = ("$($x.Serial)" -replace '[\\/:*?"<>|\s]', '_').Trim('_'); if (-not $sn) { $sn = 'ohneSN' }
            $file = Join-Path $dir ("AutopilotHWID_{0}_{1}_{2}.csv" -f $x.Computer, $sn, (Get-Date -Format 'yyyyMMdd_HHmm'))
            $lines = @()
            if ($x.Tag) { $lines += 'Device Serial Number,Windows Product ID,Hardware Hash,Group Tag'; $lines += ('{0},,{1},{2}' -f $x.Serial, $x.Hash, $x.Tag) }
            else { $lines += 'Device Serial Number,Windows Product ID,Hardware Hash'; $lines += ('{0},,{1}' -f $x.Serial, $x.Hash) }
            [System.IO.File]::WriteAllLines($file, $lines, (New-Object System.Text.UTF8Encoding $false))
            Out-Console "Autopilot-Hash von $($x.Computer) (SN $($x.Serial)): $file" 'Success'
            Start-Process explorer.exe -ArgumentList "/select,`"$file`""
        } catch { Out-Console "Autopilot-CSV nicht gespeichert: $($_.Exception.Message)" 'Error' }
    }
}

# ----------------------------------------------------------------------------
# Wake-on-LAN (optional ueber einen PC im selben Netz senden)
# ----------------------------------------------------------------------------
$script:RS_WakeOnLan = {
    param([string]$Mac, [string]$Broadcast, [int]$Port)
    $hex = ($Mac -replace '[^0-9A-Fa-f]', '')
    if ($hex.Length -ne 12) { "FEHLER: MAC-Adresse ungueltig ($Mac)"; return }
    $b = [byte[]](0..5 | ForEach-Object { [Convert]::ToByte($hex.Substring($_ * 2, 2), 16) })
    $pkt = [byte[]](@(0xFF) * 6 + (@($b) * 16))
    $u = New-Object System.Net.Sockets.UdpClient
    try {
        $u.EnableBroadcast = $true
        foreach ($i in 1..3) { [void]$u.Send($pkt, $pkt.Length, $Broadcast, $Port) }
        "OK Magic Packet an $Mac gesendet ($Broadcast`:$Port, von $env:COMPUTERNAME)"
    } catch { "FEHLER: $($_.Exception.Message)" } finally { $u.Close() }
}
function Start-HMWakeOnLan {
    $c = Get-TargetComputer
    $mac = ''
    try { $mc = Read-JsonFile (Join-Path $script:ConfigDir 'mac_cache.json'); if ($mc) { $mac = "$($mc.($c.ToUpper()))" } } catch { }
    if (-not $mac -and $script:SelectedBackup -and $script:SelectedBackup.Manifest -and $script:SelectedBackup.Manifest.Network) { $mac = "$(@($script:SelectedBackup.Manifest.Network | Where-Object { $_.MAC })[0].MAC)" }
    $f = Show-HMFormDialog -Title 'Wake-on-LAN' -OkText 'Aufwecken' -Fields @(
        @{ Name = 'Mac'; Label = "MAC-Adresse ($c):"; Type = 'Text'; Default = $mac; Hint = 'Aus dem Inventar bzw. dem markierten Backup vorbelegt' }
        @{ Name = 'Bc'; Label = 'Broadcast-Adresse:'; Type = 'Text'; Default = '255.255.255.255'; Hint = 'Fuer ein anderes Netz die Subnetz-Broadcast-Adresse (z.B. 192.168.10.255) - Router muessen das erlauben' }
        @{ Name = 'Via'; Label = 'Senden ueber PC (optional, im selben Netz):'; Type = 'Text'; Default = ''; Hint = 'Ueber VPN kommt ein Broadcast meist nicht an - dann ueber einen eingeschalteten PC im Zielnetz senden (WinRM)' }
        @{ Type = 'Info'; Label = 'Voraussetzung: WoL im BIOS/UEFI und am Netzwerkadapter aktiv, Kabel-Netzwerk (WLAN meist nicht).' }
    )
    if (-not $f) { return }
    if ("$($f.Mac)" -replace '[^0-9A-Fa-f]', '' -notmatch '^[0-9A-Fa-f]{12}$') { Out-Console 'MAC-Adresse ungueltig (12 Hex-Zeichen).' 'Warning'; return }
    $via = "$($f.Via)".Trim(); if (-not $via) { $via = $env:COMPUTERNAME }
    Invoke-HMTool -Title 'Wake-on-LAN' -Computer $via -ArgumentList @("$($f.Mac)", "$($f.Bc)".Trim(), 9) -Script $script:RS_WakeOnLan
}

# ----------------------------------------------------------------------------
# Wichtige Dateien am PC finden (ausserhalb der gesicherten Bereiche) -> als Zusaetzliche Ordner aufnehmen
# ----------------------------------------------------------------------------
function Start-HMFileSearch {
    $c = Get-TargetComputer
    $f = Show-HMFormDialog -Title "Dateien suchen - $c" -OkText 'Suchen' -Width 600 -Fields @(
        @{ Name = 'Pat'; Label = 'Dateitypen / Namen (mit ; trennen):'; Type = 'Text'; Default = '*.pst;*.kdbx;*.accdb;*.mdb;*.one;*.dwg;*.qgz;*.sav;*.vhdx' }
        @{ Name = 'Root'; Label = 'Suchen in:'; Type = 'Text'; Default = 'C:\' }
        @{ Name = 'Users'; Label = 'Auch Benutzerprofile (C:\Users) durchsuchen'; Type = 'Check'; Default = $false }
        @{ Type = 'Info'; Label = 'Windows, Programme, ProgramData und Papierkorb werden ausgelassen. Treffer koennen als "Zusaetzliche Ordner" in das Backup aufgenommen werden.' }
    )
    if (-not $f) { return }
    $pats = @("$($f.Pat)" -split '[;,]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if (-not $pats.Count) { return }
    Invoke-HMTool -Title 'Dateien suchen' -Computer $c -TimeoutSec 900 -ArgumentList @("$($f.Root)".Trim(), ($pats -join '|'), [bool]$f.Users) -Script {
        param($root, $patStr, $users)
        $pats = @($patStr -split '\|' | ForEach-Object { New-Object System.Management.Automation.WildcardPattern ($_, [System.Management.Automation.WildcardOptions]::IgnoreCase) })
        $skip = @('\Windows', '\Program Files', '\Program Files (x86)', '\ProgramData', '\$Recycle.Bin', '\System Volume Information', '\Recovery', '\$WinREAgent', '\Windows.old', '\PerfLogs')
        if (-not $users) { $skip += '\Users' }
        $r0 = $root.TrimEnd('\')
        $stack = New-Object System.Collections.Generic.Stack[string]; $stack.Push($root)
        $n = 0
        while ($stack.Count -and $n -lt 5000) {
            $d = $stack.Pop()
            $rel = $d.TrimEnd('\').Substring([Math]::Min($r0.Length, $d.TrimEnd('\').Length))
            if ($rel -and @($skip | Where-Object { $rel -ieq $_ }).Count) { continue }
            try {
                foreach ($i in (New-Object System.IO.DirectoryInfo $d).EnumerateFileSystemInfos()) {
                    if ($i.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
                    if ($i -is [System.IO.DirectoryInfo]) { $stack.Push($i.FullName); continue }
                    foreach ($p in $pats) { if ($p.IsMatch($i.Name)) { $n++; [pscustomobject]@{ Pfad = $i.FullName; Groesse = [long]$i.Length; Geaendert = $i.LastWriteTime }; break } }
                }
            } catch { }
        }
    } -OnResult {
        param($r, $comp)
        $rows = [System.Collections.Generic.List[object]]::new()
        foreach ($x in @($r)) { if ($x -and $x.Pfad) { $rows.Add(@("$($x.Pfad)", [long]$x.Groesse, [datetime]$x.Geaendert, (Split-Path "$($x.Pfad)" -Parent))) } }
        if (-not $rows.Count) { Out-Console "Keine passenden Dateien an $comp gefunden." 'Success'; return }
        Show-DataGridWindow -Title "Gefundene Dateien - $comp" -Columns @('Pfad', 'Groesse', 'Geaendert', 'Ordner') -ColumnTypes @{ Groesse = [long]; Geaendert = [datetime] } -Rows $rows.ToArray() `
            -Sort 'Pfad ASC' -CountText "$($rows.Count) Dateien$(if ($rows.Count -ge 5000) { ' (Suche nach 5000 Treffern beendet)' })" -Width 1250 -Height 600 -Actions @(
                @{ Text = 'Ordner als "Zusaetzliche Ordner" aufnehmen'; Color = '#FFA6E3A1'; Handler = {
                    param($rows, $win, $ctx)
                    $dirs = @($rows | ForEach-Object { "$($_.Ordner)" } | Select-Object -Unique)
                    $n = 0
                    foreach ($d in $dirs) { if (-not $ui.lstExtra.Items.Contains($d)) { [void]$ui.lstExtra.Items.Add($d); $n++ } }
                    if ($n -and $script:BackupChecks.ContainsKey('ExtraFolders')) { $script:BackupChecks['ExtraFolders'].IsChecked = $true }
                    Out-Console "$n Ordner in 'Zusaetzliche Ordner' aufgenommen (Modul angehakt)." 'Success'
                    [void][System.Windows.MessageBox]::Show($win, "$n Ordner aufgenommen - Reiter Backup, 'Zusaetzliche Ordner'.", 'Dateien suchen', 'OK', 'Information')
                } }
            )
    }
}

# ----------------------------------------------------------------------------
# Datenbanken am PC suchen (lokale Datei-Datenbanken + Datenbank-Dienste) -> Zusaetzliche Ordner oder Katalog-Eintrag
# Ergebnis je Ordner gruppiert: Art, Anzahl, Groesse, zuletzt geaendert, in Benutzung (geoeffnet)
# ----------------------------------------------------------------------------
$script:RS_DbSearch = {
    param([string]$ProfilePath, [bool]$AllProfiles)
    $kinds = @{ '.sqlite' = 'SQLite'; '.sqlite3' = 'SQLite'; '.db3' = 'SQLite'; '.s3db' = 'SQLite'; '.db' = 'Datenbank (.db)'; '.accdb' = 'Access'; '.mdb' = 'Access'
        '.mdf' = 'SQL Server (Datendatei)'; '.sdf' = 'SQL Server Compact'; '.fdb' = 'Firebird'; '.kdbx' = 'KeePass'; '.kdb' = 'KeePass' }
    # Ordner, die nie gesucht werden (System, Caches, Browser/Mail-Profile - die sichern eigene Module)
    $skipRx = '\\(Windows|\$Recycle\.Bin|System Volume Information|Recovery|\$WinREAgent|Windows\.old|PerfLogs|WindowsApps|WinSxS|node_modules|\.git)(\\|$)|' +
              '\\AppData\\Local\\(Temp|Packages|Microsoft|Google\\Chrome|CrashDumps|D3DSCache|NVIDIA|Mozilla|Comms)(\\|$)|\\AppData\\LocalLow(\\|$)|' +
              '\\AppData\\Roaming\\(Mozilla|Thunderbird|Microsoft\\(Windows|Protect|Crypto|SystemCertificates))(\\|$)|\\ProgramData\\(Microsoft|Packages|Package Cache)(\\|$)|' +
              '\\(BACKUPS|WindowsImageBackup|HUMig-ServerBackup)(\\|$)'   # Backups (auch von HUMig) nicht als Datenbank melden
    $roots = [System.Collections.Generic.List[string]]::new()
    $sys = $env:SystemDrive.TrimEnd('\')
    if ($AllProfiles) { $roots.Add("$sys\Users") } elseif ($ProfilePath) { $roots.Add($ProfilePath) }
    foreach ($r in @($env:ProgramData, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $(if (-not $AllProfiles) { $env:PUBLIC }))) { if ($r -and -not $roots.Contains($r)) { $roots.Add($r) } }
    $roots.Add("$sys\")   # Systemlaufwerk ohne Windows, Programme, Benutzer (siehe unten)
    foreach ($d in @([System.IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady -and "$($_.DriveType)" -eq 'Fixed' })) { $n = $d.RootDirectory.FullName; if (-not $n.StartsWith($sys, [StringComparison]::OrdinalIgnoreCase)) { $roots.Add($n) } }
    $topSkip = @("$sys\Windows", "$sys\Users", "$sys\Program Files", "$sys\Program Files (x86)", "$sys\ProgramData")
    $groups = @{}
    $n = 0
    foreach ($root in $roots) {
        $stack = New-Object System.Collections.Generic.Stack[string]; $stack.Push($root)
        while ($stack.Count -and $n -lt 20000) {
            $dir = $stack.Pop()
            if ($root -eq "$sys\" -and @($topSkip | Where-Object { $dir.TrimEnd('\') -ieq $_ }).Count) { continue }
            if ($dir -match $skipRx) { continue }
            try {
                foreach ($i in (New-Object System.IO.DirectoryInfo $dir).EnumerateFileSystemInfos()) {
                    if ($i.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
                    if ($i -is [System.IO.DirectoryInfo]) { $stack.Push($i.FullName); continue }
                    $ext = $i.Extension.ToLowerInvariant()
                    if (-not $kinds.ContainsKey($ext)) { continue }
                    if ($i.Name -ieq 'Thumbs.db' -or $i.Length -lt 1024) { continue }
                    # Nur-Cloud-Platzhalter (OneDrive ...) nie oeffnen
                    $at = [int]$i.Attributes
                    if (($at -band 0x00400000) -or ($at -band 0x00040000) -or ($at -band 0x00001000)) { continue }
                    $n++
                    $k = $i.DirectoryName
                    if (-not $groups.ContainsKey($k)) { $groups[$k] = @{ Kinds = @{}; Count = 0; Bytes = [long]0; Newest = [datetime]::MinValue; Files = [System.Collections.Generic.List[string]]::new(); Open = 0 } }
                    $g = $groups[$k]
                    $g.Kinds[$kinds[$ext]] = 1; $g.Count++; $g.Bytes += $i.Length
                    if ($i.LastWriteTime -gt $g.Newest) { $g.Newest = $i.LastWriteTime }
                    if ($g.Files.Count -lt 5) { $g.Files.Add($i.Name) }
                    if ($g.Count -le 20) { try { $fs = [System.IO.File]::Open($i.FullName, 'Open', 'Read', 'None'); $fs.Close() } catch [System.IO.IOException] { $g.Open++ } catch { } }
                }
            } catch { }
        }
    }
    foreach ($k in $groups.Keys) {
        $g = $groups[$k]
        [pscustomobject]@{ Typ = 'Ordner'; Ordner = $k; Art = (@($g.Kinds.Keys | Sort-Object) -join ', '); Anzahl = $g.Count; Bytes = $g.Bytes; Geaendert = $g.Newest
            Offen = $g.Open; Dateien = (@($g.Files) -join ', '); Dienst = ''; Status = '' }
    }
    # Datenbank-Dienste (SQL Server, Firebird, MySQL/MariaDB, PostgreSQL)
    foreach ($s in @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(MSSQL\$.+|MSSQLSERVER|FirebirdServer.*|MySQL.*|MariaDB.*|postgresql.*)$' })) {
        $dataDir = ''
        if ($s.Name -match '^MSSQL\$(.+)$|^MSSQLSERVER$') {
            $inst = if ($Matches[1]) { $Matches[1] } else { 'MSSQLSERVER' }
            try {
                $id = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL' -ErrorAction Stop).$inst
                if ($id) { $dataDir = "$((Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$id\Setup" -ErrorAction Stop).SQLDataRoot)\DATA" }
            } catch { }
        }
        [pscustomobject]@{ Typ = 'Dienst'; Ordner = $dataDir; Art = "Dienst: $($s.DisplayName)"; Anzahl = 0; Bytes = [long]0; Geaendert = $null; Offen = 0; Dateien = ''; Dienst = $s.Name; Status = "$($s.Status)" }
    }
}
function Start-HMDbSearch {
    $c = Get-TargetComputer
    $p = Get-SelectedProfile
    $pp = if ($p -and -not $p.NoProfile) { "$($p.LocalPath)" } else { '' }
    $all = $false
    if (-not $script:UserMode) {
        $f = Show-HMFormDialog -Title "Datenbanken suchen - $c" -OkText 'Suchen' -Width 620 -Fields @(
            @{ Type = 'Info'; Label = "Sucht lokale Datenbanken (SQLite, Access, KeePass, SQL Server, Firebird ...) im Profil$(if ($p -and $p.Folder) { " von $($p.Folder)" }), in ProgramData, den Programmordnern und auf allen Festplatten - dazu Datenbank-Dienste. Windows, Caches sowie Browser- und Mail-Profile (eigene Module) werden ausgelassen." }
            @{ Name = 'All'; Label = 'Alle Benutzerprofile durchsuchen (statt nur des gewaehlten)'; Type = 'Check'; Default = (-not $pp) }
        )
        if (-not $f) { return }
        $all = [bool]$f.All
    }
    Invoke-HMTool -Title 'Datenbanken suchen' -Computer $c -TimeoutSec 900 -ArgumentList @($pp, $all) -Script $script:RS_DbSearch -OnResult {
        param($r, $comp)
        $rows = [System.Collections.Generic.List[object]]::new()
        $ordRx = { param($o) if ($o -match '\\AppData\\Roaming\\') { 'AppData Roaming' } elseif ($o -match '\\AppData\\Local\\') { 'AppData Local' } elseif ($o -match '^[A-Za-z]:\\Users\\') { 'Profil' } elseif ($o -match '\\ProgramData\\') { 'ProgramData' } elseif ($o -match '\\Program Files') { 'Programmordner' } elseif ($o -match '^[A-Za-z]:\\') { "Laufwerk $($o.Substring(0, 2))" } else { '' } }
        foreach ($x in @($r)) {
            if (-not $x -or -not $x.Typ) { continue }
            $ort = if ($x.Typ -eq 'Dienst') { 'Dienst' } else { & $ordRx "$($x.Ordner)" }
            $offen = if ($x.Typ -eq 'Dienst') { $(if ($x.Status -eq 'Running') { 'Dienst laeuft' } else { "Dienst $($x.Status)" }) } elseif ([int]$x.Offen) { "JA ($($x.Offen))" } else { '' }
            $rows.Add(@("$($x.Art)", "$($x.Ordner)", $ort, [int]$x.Anzahl, $(if ($x.Bytes) { [math]::Round([long]$x.Bytes / 1MB, 1) } else { $null }), $(if ($x.Geaendert) { [datetime]$x.Geaendert } else { $null }), $offen, "$($x.Dateien)", "$($x.Dienst)"))
        }
        if (-not $rows.Count) { Out-Console "Keine lokalen Datenbanken an $comp gefunden." 'Success'; return }
        Out-Console "$($rows.Count) Datenbank-Ordner/-Dienste an $comp gefunden - Tabelle" 'Success'
        $acts = @(
            @{ Text = 'Ordner als "Zusaetzliche Ordner" aufnehmen'; Color = '#FFA6E3A1'; Handler = {
                param($sel, $win, $ctx)
                $dirs = @($sel | Where-Object { "$($_.Ordner)" -and -not "$($_.Dienst)" } | ForEach-Object { "$($_.Ordner)" } | Select-Object -Unique)
                $n = 0
                foreach ($d in $dirs) { if (-not $ui.lstExtra.Items.Contains($d)) { [void]$ui.lstExtra.Items.Add($d); $n++ } }
                if ($n -and $script:BackupChecks.ContainsKey('ExtraFolders')) { $script:BackupChecks['ExtraFolders'].IsChecked = $true }
                Out-Console "$n Ordner in 'Zusaetzliche Ordner' aufgenommen - Programme vorher schliessen (geoeffnete Datenbanken werden nicht vollstaendig kopiert)." 'Success'
                [void][System.Windows.MessageBox]::Show($win, "$n Ordner aufgenommen (Reiter Backup, 'Zusaetzliche Ordner').`n`nWichtig: das zugehoerige Programm vor dem Backup schliessen. Bequemer: 'Als Katalog-Eintrag anlegen' - dann schliesst HUMig das Programm selbst.", 'Datenbanken', 'OK', 'Information')
            } }
        )
        if (-not $script:UserMode) {
            $acts += @{ Text = 'Als Katalog-Eintrag anlegen ...'; Color = '#FFCBA6F7'; Handler = { param($sel, $win, $ctx) New-HMDbCatalogEntry @($sel) } }
        }
        Show-DataGridWindow -Title "Datenbanken - $comp" -Columns @('Art', 'Ordner', 'Ort', 'Dateien_Anzahl', 'MB', 'Geaendert', 'Geoeffnet', 'Beispiele', 'Dienst') `
            -ColumnTypes @{ 'Dateien_Anzahl' = [int]; MB = [double]; Geaendert = [datetime] } -Rows $rows.ToArray() -Sort 'Ort ASC, Ordner ASC' `
            -CountText "$($rows.Count) Eintraege - Geoeffnet = Datei gerade in Benutzung (Programm laeuft). Markieren und uebernehmen." -Width 1400 -Height 620 -Actions $acts
    }
}
# Markierte Datenbank-Ordner/-Dienste als neuen Katalog-Eintrag im Editor vorbelegen
function New-HMDbCatalogEntry([object[]]$Rows) {
    $items = [System.Collections.Generic.List[object]]::new()
    $svc = @(); $n = 0
    foreach ($r in $Rows) {
        if ("$($r.Dienst)") { $svc += "$($r.Dienst)" }
        if (-not "$($r.Ordner)") { continue }
        $n++
        $isSvc = [bool]"$($r.Dienst)" -or "$($r.Art)" -match 'SQL Server \(Datendatei\)'
        $items.Add([pscustomobject]@{ Type = 'Folder'; Name = $(if ($n -eq 1) { 'DB' } else { "DB$n" }); Path = (ConvertTo-HMAeToken "$($r.Ordner)"); Role = 'Database'; DbKind = $(if ($isSvc) { 'Service' } else { 'File' }) })
    }
    if (-not $items.Count -and -not $svc.Count) { return }
    $leaf = if ($items.Count) { Split-Path "$(@($Rows | Where-Object { "$($_.Ordner)" })[0].Ordner)" -Leaf } else { "$($svc[0])" }
    $o = [pscustomobject]@{ Id = ('App_' + (($leaf -replace '[^A-Za-z0-9_\-]', '') | ForEach-Object { if ($_) { $_ } else { 'Datenbank' } })); Name = "Datenbank $leaf"; Detect = '^'
        Items = @($items); StopService = @($svc | Select-Object -Unique)
        Transfer = 'Datenbank'; After = @("Datenbank ${leaf}: Programm oeffnen und Daten pruefen")
        Version = $(if ($svc.Count) { 'Dienst-Datenbank: Dateikopie nur bei gleicher Datenbank-Version am Ziel verlaesslich - sonst Sicherung des Herstellers verwenden' } else { '' }) }
    Show-HMAppEditor -NewEntry $o
}

# ----------------------------------------------------------------------------
# Im Backup suchen und einzelne Dateien herauskopieren
# ----------------------------------------------------------------------------
function Start-HMBackupSearch {
    $b = $script:SelectedBackup
    if (-not $b) { Out-Console 'Bitte im Reiter Restore zuerst ein Backup markieren.' 'Warning'; return }
    $f = Show-HMFormDialog -Title "Im Backup suchen - $($b.Name)" -OkText 'Suchen' -Fields @(
        @{ Name = 'Q'; Label = 'Dateiname (* und ? erlaubt, z.B. *Zeugnis*.docx):'; Type = 'Text'; Default = '*' }
        @{ Type = 'Info'; Label = 'Treffer koennen einzeln herauskopiert werden (z.B. versehentlich geloeschte Datei nach dem Restore).' }
    )
    if (-not $f) { return }
    $q = "$($f.Q)".Trim(); if (-not $q) { $q = '*' }
    if ($q -notmatch '[\*\?]') { $q = "*$q*" }
    Out-Console "Suche '$q' in $($b.Name) ..." 'Info'
    Invoke-AsyncCommand -ScriptBlock {
        param($root, $q)
        $wp = New-Object System.Management.Automation.WildcardPattern ($q, [System.Management.Automation.WildcardOptions]::IgnoreCase)
        $r0 = $root.TrimEnd('\')
        $stack = New-Object System.Collections.Generic.Stack[string]
        foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue)) { $stack.Push($d.FullName) }
        $n = 0
        while ($stack.Count -and $n -lt 20000) {
            $d = $stack.Pop()
            try {
                foreach ($i in (New-Object System.IO.DirectoryInfo $d).EnumerateFileSystemInfos()) {
                    if ($i.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
                    if ($i -is [System.IO.DirectoryInfo]) { $stack.Push($i.FullName); continue }
                    if ($wp.IsMatch($i.Name)) { $n++; [pscustomobject]@{ Rel = $i.FullName.Substring($r0.Length + 1); Size = [long]$i.Length; Time = $i.LastWriteTime; Full = $i.FullName } }
                }
            } catch { }
        }
    } -ArgumentList @($b.Path, $q) -TimeoutSec 900 -State @{ Backup = $b } -OnComplete {
        param($r, $st)
        $rows = [System.Collections.Generic.List[object]]::new()
        foreach ($x in @($r)) { if ($x -and $x.Rel) { $rows.Add(@("$($x.Rel)", [long]$x.Size, [datetime]$x.Time)) } }
        if (-not $rows.Count) { Out-Console 'Keine Treffer im Backup.' 'Info'; return }
        Show-DataGridWindow -Title "Suche im Backup - $($st.Backup.Name)" -Columns @('Pfad', 'Groesse', 'Geaendert') -ColumnTypes @{ Groesse = [long]; Geaendert = [datetime] } -Rows $rows.ToArray() `
            -Sort 'Pfad ASC' -CountText "$($rows.Count) Treffer$(if ($rows.Count -ge 20000) { ' (nach 20000 beendet)' })" -Width 1200 -Height 600 -ActionContext @{ Root = $st.Backup.Path } -Actions @(
                @{ Text = 'Markierte kopieren nach ...'; Color = '#FFA6E3A1'; Handler = {
                    param($rows, $win, $ctx)
                    $d = New-Object System.Windows.Forms.FolderBrowserDialog
                    $d.Description = 'Zielordner fuer die Dateien (Unterordner-Struktur des Backups bleibt erhalten)'
                    if ($d.ShowDialog() -ne 'OK') { return }
                    $ok = 0; $bad = 0
                    foreach ($x in @($rows)) {
                        try {
                            $src = Join-Path $ctx.Root "$($x.Pfad)"; $dst = Join-Path $d.SelectedPath "$($x.Pfad)"
                            $dd = Split-Path $dst -Parent; if (-not (Test-Path -LiteralPath $dd)) { New-Item -ItemType Directory -Path $dd -Force | Out-Null }
                            Copy-Item -LiteralPath $src -Destination $dst -Force -ErrorAction Stop; $ok++
                        } catch { $bad++; Out-Console "Kopieren fehlgeschlagen: $($x.Pfad): $($_.Exception.Message)" 'Error' }
                    }
                    Out-Console "$ok Datei(en) kopiert nach $($d.SelectedPath)$(if ($bad) { ", $bad Fehler" })" $(if ($bad) { 'Warning' } else { 'Success' })
                    Start-Process explorer.exe -ArgumentList "`"$($d.SelectedPath)`""
                } }
                @{ Text = 'Im Explorer zeigen'; Color = '#FF89B4FA'; Handler = { param($rows, $win, $ctx) $x = @($rows)[0]; Start-Process explorer.exe -ArgumentList "/select,`"$(Join-Path $ctx.Root "$($x.Pfad)")`"" } }
            )
    }
}
