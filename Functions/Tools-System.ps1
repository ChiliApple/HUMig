#Requires -Version 5.1
<#
.SYNOPSIS
    Werkzeuge fuer den gewaehlten Computer (lokal oder remote): Umbenennen, IP/DHCP, lokale Gruppen, Autologon,
    Sperrbildschirm/Timeout, Profil erneuern/umbenennen/einem anderen Konto zuweisen, Windows-Apps neu registrieren,
    Aufgaben importieren, Akku-Bericht, Ereignisanzeige, Anmeldedaten, Firewall/Netzwerkprofil.
.NOTES
    Wird im UI-Thread geladen (dot-source aus HUMig.ps1). Zielmaschine: der im Kopfbereich gewaehlte Computer
    (lokal direkt, remote ueber PowerShell-Remoting/WinRM). Alle Aenderungen mit Rueckfrage.
#>

# ----------------------------------------------------------------------------
# Ausfuehrung am Ziel-PC (asynchron) + Ergebnisausgabe
# ----------------------------------------------------------------------------
function Invoke-HMTool {
    param(
        [string]$Title, [scriptblock]$Script, [object[]]$ArgumentList = @(), [string]$Computer = '',
        [int]$TimeoutSec = 180, [scriptblock]$OnResult, [object]$State = $null
    )
    if (-not $Computer) { $Computer = Get-TargetComputer }
    Out-Console "$Title - $Computer ..." 'Info'
    Invoke-AsyncCommand -ScriptBlock {
        param($h, $cred, $text, $argList)
        $sb = [scriptblock]::Create($text)
        $isLocal = ($h -eq '.' -or $h -ieq 'localhost' -or $h -ieq $env:COMPUTERNAME -or $h -ilike "$($env:COMPUTERNAME).*")
        try {
            if ($isLocal) { & $sb @argList }
            else {
                $p = @{ ComputerName = $h; ScriptBlock = $sb; ArgumentList = $argList; ErrorAction = 'Stop' }
                if ($cred) { $p.Credential = $cred }
                Invoke-Command @p
            }
        } catch { "FEHLER: $($_.Exception.Message)" }
    } -ArgumentList @($Computer, $script:RemoteCred, $Script.ToString(), @($ArgumentList)) -TimeoutSec $TimeoutSec -State @{ Title = $Title; Computer = $Computer; On = $OnResult; State = $State } -OnComplete {
        param($r, $st)
        if ("$r" -match '^FEHLER: ' -and -not ($r -is [System.Array])) { Out-Console (Format-RemoteError "$r") 'Error'; return }
        if ($st.On) { & $st.On $r $st.Computer $st.State; return }
        Write-HMToolResult $r
    }
}

# Zeilen "OK ...", "WARN ...", "FEHLER ...", "INFO ..." farbig in die Konsole
function Write-HMToolResult($Result) {
    foreach ($l in @($Result)) {
        foreach ($line in ("$l" -split "`r?`n")) {
            if (-not $line.Trim()) { continue }
            $lvl = if ($line -match '^\s*(FEHLER|ERROR)') { 'Error' } elseif ($line -match '^\s*(WARN|ACHTUNG)') { 'Warning' } elseif ($line -match '^\s*OK') { 'Success' } else { 'Info' }
            Out-Console "   $line" $lvl
        }
    }
}

# ----------------------------------------------------------------------------
# Formular-Dialog (Text, Kennwort, Haekchen, Auswahl, Hinweis)
#   Fields: @{ Name; Label; Type = 'Text'|'Password'|'Check'|'Combo'|'Info'; Default; Items; Hint }
#   Rueckgabe: Hashtable Name -> Wert (Password: SecureString, dazu Name_Len = Laenge) oder $null
# ----------------------------------------------------------------------------
function Show-HMFormDialog {
    param([string]$Title, [string]$Intro = '', [object[]]$Fields, [string]$OkText = 'OK', [string]$OkColor = '#FFA6E3A1', [int]$Width = 520)
    $x = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$([System.Security.SecurityElement]::Escape($Title))" Width="$Width" SizeToContent="Height" ResizeMode="NoResize" WindowStartupLocation="CenterOwner" Background="#FF1E1E2E">
  <StackPanel Margin="16">
    <TextBlock x:Name="intro" Foreground="#FFCDD6F4" TextWrapping="Wrap" Margin="0,0,0,10"/>
    <StackPanel x:Name="pnl"/>
    <TextBlock x:Name="err" Foreground="#FFF38BA8" TextWrapping="Wrap" Margin="0,4,0,4"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,8,0,0">
      <Button x:Name="ok" Width="150" Height="28" Foreground="#FF1E1E2E" FontWeight="SemiBold" Margin="0,0,6,0" IsDefault="True"/>
      <Button x:Name="cancel" Content="Abbrechen" Width="100" Height="28" Background="#FF45475A" Foreground="#FFCDD6F4" IsCancel="True"/>
    </StackPanel>
  </StackPanel>
</Window>
"@
    $w = [System.Windows.Markup.XamlReader]::Parse($x)
    if ($script:AppIcon) { $w.Icon = $script:AppIcon }
    $w.Owner = $script:Window; Set-HMWindowScale $w
    $w.FindName('intro').Text = $Intro
    if (-not $Intro) { $w.FindName('intro').Visibility = 'Collapsed' }
    $okB = $w.FindName('ok'); $okB.Content = $OkText
    $okB.Background = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString($OkColor))
    $pnl = $w.FindName('pnl')
    $fg = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString('#FFCDD6F4'))
    $sub = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString('#FFA6ADC8'))
    $bg = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString('#FF313244'))
    $bd = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString('#FF585B70'))
    $ctl = @{}
    $first = $null
    foreach ($f in @($Fields)) {
        if (-not $f) { continue }
        switch ($f.Type) {
            'Info' {
                $t = New-Object System.Windows.Controls.TextBlock
                $t.Text = "$($f.Label)"; $t.TextWrapping = 'Wrap'; $t.Margin = [System.Windows.Thickness]::new(0, 2, 0, 8)
                $t.Foreground = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString($(if ($f.Color) { $f.Color } else { '#FFF9E2AF' })))
                [void]$pnl.Children.Add($t)
            }
            'Check' {
                $c = New-Object System.Windows.Controls.CheckBox
                $c.Content = "$($f.Label)"; $c.IsChecked = [bool]$f.Default; $c.Foreground = $fg; $c.Margin = [System.Windows.Thickness]::new(0, 2, 0, 6)
                if ($f.Hint) { $c.ToolTip = "$($f.Hint)" }
                [void]$pnl.Children.Add($c); $ctl[$f.Name] = $c
            }
            default {
                $l = New-Object System.Windows.Controls.TextBlock
                $l.Text = "$($f.Label)"; $l.Foreground = $sub; $l.Margin = [System.Windows.Thickness]::new(0, 0, 0, 2)
                [void]$pnl.Children.Add($l)
                if ($f.Type -eq 'Password') {
                    $c = New-Object System.Windows.Controls.PasswordBox
                } elseif ($f.Type -eq 'Combo') {
                    $c = New-Object System.Windows.Controls.ComboBox
                    foreach ($i in @($f.Items)) { [void]$c.Items.Add("$i") }
                    if ($null -ne $f.Default) { $c.SelectedItem = "$($f.Default)" }
                    if ($c.SelectedIndex -lt 0 -and $c.Items.Count) { $c.SelectedIndex = 0 }
                    $c.IsEditable = [bool]$f.Editable
                } else {
                    $c = New-Object System.Windows.Controls.TextBox
                    $c.Text = "$($f.Default)"
                    $c.Background = $bg; $c.Foreground = $fg; $c.BorderBrush = $bd; $c.CaretBrush = $fg
                }
                if ($f.Type -eq 'Password') { $c.Background = $bg; $c.Foreground = $fg; $c.BorderBrush = $bd; $c.CaretBrush = $fg }
                $c.Padding = [System.Windows.Thickness]::new(4, 3, 4, 3); $c.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
                if ($f.Hint) { $c.ToolTip = "$($f.Hint)" }
                [void]$pnl.Children.Add($c); $ctl[$f.Name] = $c
                if (-not $first) { $first = $c }
            }
        }
    }
    $res = @{ V = $null }
    $okB.Add_Click({
        $o = @{}
        foreach ($k in $ctl.Keys) {
            $c = $ctl[$k]
            if ($c -is [System.Windows.Controls.PasswordBox]) { $o[$k] = $c.SecurePassword; $o["${k}_Len"] = $c.Password.Length }
            elseif ($c -is [System.Windows.Controls.CheckBox]) { $o[$k] = [bool]$c.IsChecked }
            elseif ($c -is [System.Windows.Controls.ComboBox]) { $o[$k] = $(if ($c.IsEditable) { "$($c.Text)".Trim() } else { "$($c.SelectedItem)" }) }
            else { $o[$k] = "$($c.Text)".Trim() }
        }
        $res.V = $o
        $w.DialogResult = $true
    }.GetNewClosure())
    if ($first) { [void]$first.Focus() }
    if ($w.ShowDialog() -eq $true) { return $res.V }
    return $null
}

function Test-HMIPv4([string]$Ip) { $a = $null; return ($Ip -match '^\d{1,3}(\.\d{1,3}){3}$' -and [System.Net.IPAddress]::TryParse($Ip, [ref]$a)) }
function ConvertTo-HMPrefix([string]$Mask) {
    $m = "$Mask".Trim().TrimStart('/')
    if ($m -match '^\d{1,2}$') { $n = [int]$m; if ($n -ge 1 -and $n -le 32) { return $n } else { return $null } }
    if (-not (Test-HMIPv4 $m)) { return $null }
    $bits = (([System.Net.IPAddress]$m).GetAddressBytes() | ForEach-Object { [Convert]::ToString($_, 2).PadLeft(8, '0') }) -join ''
    if ($bits -notmatch '^1+0*$') { return $null }
    return ($bits.TrimEnd('0')).Length
}

# ============================================================================
# 1. COMPUTER UMBENENNEN
# ============================================================================
function Start-HMRenameComputer {
    $c = Get-TargetComputer
    $f = Show-HMFormDialog -Title "Computer umbenennen - $c" -OkText 'Umbenennen' -OkColor '#FFFAB387' -Fields @(
        @{ Name = 'New'; Label = 'Neuer Computername (max. 15 Zeichen, A-Z 0-9 -):'; Type = 'Text' }
        @{ Name = 'Restart'; Label = 'Danach neu starten (in 30 Sekunden, mit Hinweis an den Benutzer)'; Type = 'Check' }
        @{ Type = 'Info'; Label = 'Bei Domaenen-PCs werden Domaenen-Anmeldedaten mit dem Recht zum Umbenennen des Computerkontos abgefragt.' }
    )
    if (-not $f) { return }
    $n = "$($f.New)".Trim()
    if ($n.Length -lt 1 -or $n.Length -gt 15 -or $n -notmatch '^[A-Za-z0-9-]+$' -or $n -match '^\d+$' -or $n.StartsWith('-')) { Out-Console "Ungueltiger Name '$n' (1-15 Zeichen, A-Z, 0-9, '-', nicht nur Ziffern)" 'Warning'; return }
    $cred = $null
    try { $cred = Get-Credential -UserName "$env:USERDOMAIN\$env:USERNAME" -Message 'Domaenen-Anmeldedaten fuer das Umbenennen (bei Arbeitsgruppen-PC: Abbrechen)' } catch { $cred = $null }
    if (-not (Confirm-Action "Computer '$c' umbenennen in '$n'$(if ($f.Restart) { ' und neu starten' })?")) { return }
    Invoke-HMTool -Title "Umbenennen in $n" -Computer $c -ArgumentList @($n, $cred, [bool]$f.Restart) -Script {
        param($nn, $cc, $restart)
        try {
            $cs = Get-CimInstance Win32_ComputerSystem
            if ($cs.PartOfDomain) {
                if (-not $cc) { return 'FEHLER: Domaenen-PC - Domaenen-Anmeldedaten erforderlich' }
                Rename-Computer -NewName $nn -DomainCredential $cc -Force -ErrorAction Stop -WarningAction SilentlyContinue
            } else { Rename-Computer -NewName $nn -Force -ErrorAction Stop -WarningAction SilentlyContinue }
            if ($restart) { & shutdown.exe /r /t 30 /c "Der Computer wird umbenannt ($nn) und in 30 Sekunden neu gestartet." | Out-Null; "OK umbenannt in $nn - Neustart in 30 Sekunden" }
            else { "OK umbenannt in $nn - wirksam nach dem naechsten Neustart" }
        } catch { "FEHLER: $($_.Exception.Message)" }
    }
}

# ============================================================================
# 2. IP-ADRESSE STATISCH / DHCP (als SYSTEM-Aufgabe am Ziel - Verbindungsabbruch egal)
# ============================================================================
$script:RS_NetInfo = {
    # ohne Get-NetIPConfiguration: das bricht auf manchen PCs ab ("Exception setting NetAdapter ... Object[]", z.B. bei
    # mehreren Adaptern mit gleichem Index/Namen, Hyper-V) - Werte einzeln aus NetAdapter/NetIPAddress/NetRoute/DnsClient
    foreach ($a in @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { "$($_.Status)" -eq 'Up' } | Sort-Object ifIndex)) {
        $idx = [int]$a.ifIndex
        $dhcp = $null; try { $dhcp = "$((Get-NetIPInterface -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction Stop).Dhcp)" } catch { }
        $ip = @(Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { "$($_.IPAddress)" -notlike '169.254.*' })[0]
        $gw = @(Get-NetRoute -InterfaceIndex $idx -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric)[0]
        $dns = @(Get-DnsClientServerAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object { $_.ServerAddresses })
        [pscustomobject]@{
            Index = $idx; Name = "$($a.Name)"; Desc = "$($a.InterfaceDescription)"; Mac = "$($a.MacAddress)"
            IP = "$(if ($ip) { $ip.IPAddress })"; Prefix = "$(if ($ip) { $ip.PrefixLength })"; Gateway = "$(if ($gw) { $gw.NextHop })"; Dhcp = $dhcp
            Dns = (@($dns | Where-Object { $_ }) -join ',')
        }
    }
}
function Start-HMNetworkConfig {
    $c = Get-TargetComputer
    Invoke-HMTool -Title 'Netzwerkadapter lesen' -Computer $c -Script $script:RS_NetInfo -OnResult {
        param($r, $comp)
        $ads = @($r | Where-Object { $_ -and $_.Index })
        if (-not $ads.Count) { Out-Console "Keine aktiven Netzwerkadapter auf $comp gefunden" 'Warning'; return }
        $labels = @($ads | ForEach-Object { "{0} - {1} ({2}, {3})" -f $_.Index, $_.Name, $(if ($_.Dhcp -eq 'Enabled') { 'DHCP' } else { 'statisch' }), $_.IP })
        $def = @($ads | Where-Object { $_.Gateway } | Select-Object -First 1)
        if (-not $def) { $def = @($ads[0]) }
        $d = $def[0]
        $mask = if ($script:Settings.Network -and $script:Settings.Network.SubnetMask) { "$($script:Settings.Network.SubnetMask)" } else { '255.255.255.0' }
        $dnsDef = if ($d.Dns) { $d.Dns } elseif ($script:Settings.Network -and @($script:Settings.Network.DnsServers).Count) { (@($script:Settings.Network.DnsServers) -join ',') } else { '' }
        $f = Show-HMFormDialog -Title "IP-Adresse - $comp" -OkText 'Anwenden' -OkColor '#FFFAB387' -Width 560 -Intro 'Aenderung laeuft als SYSTEM-Aufgabe am Ziel-PC (in ca. 3 Sekunden) - die Verbindung kann dabei abbrechen.' -Fields @(
            @{ Name = 'Adapter'; Label = 'Netzwerkadapter:'; Type = 'Combo'; Items = $labels; Default = @($labels | Where-Object { $_ -like "$($d.Index) -*" })[0] }
            @{ Name = 'Mode'; Label = 'Modus:'; Type = 'Combo'; Items = @('Statisch', 'DHCP'); Default = $(if ($d.Dhcp -eq 'Enabled') { 'DHCP' } else { 'Statisch' }) }
            @{ Name = 'IP'; Label = 'IP-Adresse (auch 192.168.10.50/24):'; Type = 'Text'; Default = $d.IP }
            @{ Name = 'Mask'; Label = 'Subnetzmaske oder Prefix:'; Type = 'Text'; Default = $(if ($d.Prefix) { $d.Prefix } else { $mask }) }
            @{ Name = 'Gw'; Label = 'Standardgateway:'; Type = 'Text'; Default = $d.Gateway }
            @{ Name = 'Dns'; Label = 'DNS-Server (Komma getrennt):'; Type = 'Text'; Default = $dnsDef }
        )
        if (-not $f) { return }
        $idx = [int]("$($f.Adapter)".Split(' ')[0])
        if ($f.Mode -eq 'DHCP') {
            if (-not (Confirm-Action "DHCP auf $comp (Adapter $idx) aktivieren und DNS zuruecksetzen?`n`nDie IP-Adresse kann sich aendern.")) { return }
            $body = "Remove-NetRoute -InterfaceIndex $idx -DestinationPrefix '0.0.0.0/0' -Confirm:`$false -ErrorAction SilentlyContinue`r`nRemove-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -PrefixOrigin Manual -Confirm:`$false -ErrorAction SilentlyContinue`r`nSet-NetIPInterface -InterfaceIndex $idx -Dhcp Enabled`r`nSet-DnsClientServerAddress -InterfaceIndex $idx -ResetServerAddresses`r`nipconfig.exe /renew | Out-Null"
        } else {
            $ip = "$($f.IP)"; $mk = "$($f.Mask)"
            if ($ip -match '^(.+)/(\d{1,2})$') { $ip = $Matches[1]; $mk = $Matches[2] }
            if (-not (Test-HMIPv4 $ip)) { Out-Console "Ungueltige IP-Adresse: '$ip'" 'Warning'; return }
            $pfx = ConvertTo-HMPrefix $mk
            if (-not $pfx) { Out-Console "Ungueltige Subnetzmaske/Prefix: '$mk'" 'Warning'; return }
            $gw = "$($f.Gw)"
            if ($gw -and -not (Test-HMIPv4 $gw)) { Out-Console "Ungueltiges Gateway: '$gw'" 'Warning'; return }
            $dns = @("$($f.Dns)" -split '[,; ]+' | Where-Object { $_ })
            foreach ($x in $dns) { if (-not (Test-HMIPv4 $x)) { Out-Console "Ungueltiger DNS-Server: '$x'" 'Warning'; return } }
            if (-not (Confirm-Action "Statische IP auf $comp setzen:`n`n  Adapter: $idx`n  IP:      $ip/$pfx`n  Gateway: $gw`n  DNS:     $($dns -join ', ')`n`nBei falschen Werten verliert der PC die Netzwerkverbindung. Fortfahren?")) { return }
            $gwPart = if ($gw) { " -DefaultGateway '$gw'" } else { '' }
            $dnsPart = if ($dns.Count) { "Set-DnsClientServerAddress -InterfaceIndex $idx -ServerAddresses @('" + ($dns -join "','") + "')" } else { '' }
            $body = "Set-NetIPInterface -InterfaceIndex $idx -Dhcp Disabled -ErrorAction SilentlyContinue`r`nRemove-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -Confirm:`$false -ErrorAction SilentlyContinue`r`nRemove-NetRoute -InterfaceIndex $idx -DestinationPrefix '0.0.0.0/0' -Confirm:`$false -ErrorAction SilentlyContinue`r`nNew-NetIPAddress -InterfaceIndex $idx -IPAddress '$ip' -PrefixLength $pfx$gwPart | Out-Null`r`n$dnsPart"
        }
        Invoke-HMTool -Title "Netzwerk ($($f.Mode))" -Computer $comp -ArgumentList @($body) -Script {
            param($b)
            try {
                $name = "HUMig_Netzwerk_$([guid]::NewGuid().ToString('N').Substring(0, 8))"
                $full = "Start-Sleep -Seconds 3`r`ntry {`r`n$b`r`n} finally { Unregister-ScheduledTask -TaskName '$name' -Confirm:`$false -ErrorAction SilentlyContinue }"
                $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($full))
                $a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand $enc"
                $p = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
                $s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
                Register-ScheduledTask -TaskName $name -Action $a -Principal $p -Settings $s -Force -ErrorAction Stop | Out-Null
                Start-ScheduledTask -TaskName $name -ErrorAction Stop
                'OK Aenderung wird in ca. 3 Sekunden angewendet (SYSTEM-Aufgabe)'
            } catch { "FEHLER: $($_.Exception.Message)" }
        }
    }
}

# ============================================================================
# 3. LOKALE GRUPPEN: Administratoren / Netzwerkkonfigurations-Operatoren (per SID, sprachunabhaengig)
# ============================================================================
$script:HMLocalGroups = [ordered]@{ 'Administratoren' = 'S-1-5-32-544'; 'Netzwerkkonfigurations-Operatoren' = 'S-1-5-32-556'; 'Remotedesktopbenutzer' = 'S-1-5-32-555'; 'Benutzer' = 'S-1-5-32-545' }
$script:RS_GroupList = {
    param($groups)
    foreach ($g in $groups.GetEnumerator()) {
        $sid = $g.Value
        $list = @()
        try { $list = @(Get-LocalGroupMember -SID $sid -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ Name = "$($_.Name)"; Type = "$($_.ObjectClass)"; Source = "$($_.PrincipalSource)" } }) }
        catch {
            try {
                $gn = (New-Object System.Security.Principal.SecurityIdentifier($sid)).Translate([System.Security.Principal.NTAccount]).Value.Split('\')[-1]
                $ad = [ADSI]("WinNT://$env:COMPUTERNAME/$gn,group")
                $list = @($ad.Invoke('Members') | ForEach-Object { [pscustomobject]@{ Name = (($_.GetType().InvokeMember('AdsPath', 'GetProperty', $null, $_, $null)) -replace '^WinNT://', '' -replace '/', '\'); Type = "$($_.GetType().InvokeMember('Class', 'GetProperty', $null, $_, $null))"; Source = '' } })
            } catch { $list = @([pscustomobject]@{ Name = "FEHLER: $($_.Exception.Message)"; Type = ''; Source = '' }) }
        }
        foreach ($m in $list) { [pscustomobject]@{ Gruppe = $g.Key; Sid = $sid; Mitglied = $m.Name; Typ = $m.Type; Quelle = $m.Source } }
    }
}
$script:RS_GroupChange = {
    param($action, $sid, $member)
    try {
        if ($action -eq 'Add') { Add-LocalGroupMember -SID $sid -Member $member -ErrorAction Stop; "OK $member hinzugefuegt" }
        else { Remove-LocalGroupMember -SID $sid -Member $member -ErrorAction Stop; "OK $member entfernt" }
    } catch {
        # Fallback ADSI (z.B. verwaiste SIDs oder aeltere Systeme)
        try {
            $gn = (New-Object System.Security.Principal.SecurityIdentifier($sid)).Translate([System.Security.Principal.NTAccount]).Value.Split('\')[-1]
            $g = [ADSI]("WinNT://$env:COMPUTERNAME/$gn,group")
            $path = if ($member -match '^S-1-') { "WinNT://$member" } else { 'WinNT://' + ($member -replace '\\', '/') }
            if ($action -eq 'Add') { $g.Add($path) } else { $g.Remove($path) }
            "OK $member $(if ($action -eq 'Add') { 'hinzugefuegt' } else { 'entfernt' }) (ADSI)"
        } catch { "FEHLER $member : $($_.Exception.InnerException.Message)$($_.Exception.Message)" }
    }
}
function Show-HMLocalGroups {
    $c = Get-TargetComputer
    Invoke-HMTool -Title 'Lokale Gruppen lesen' -Computer $c -ArgumentList @(, $script:HMLocalGroups) -Script $script:RS_GroupList -OnResult {
        param($r, $comp)
        $rows = New-Object System.Collections.Generic.List[object]
        foreach ($m in @($r)) { if ($m -and $m.Gruppe) { $rows.Add(@($m.Gruppe, $m.Mitglied, $m.Typ, $m.Quelle)) } }
        Out-Console "$($rows.Count) Gruppenmitglieder auf $comp" 'Success'
        Show-DataGridWindow -Title "Lokale Gruppen - $comp" -Columns @('Gruppe', 'Mitglied', 'Typ', 'Quelle') -Rows $rows.ToArray() -Sort 'Gruppe ASC, Mitglied ASC' -Width 900 -Height 520 `
            -ActionContext @{ Computer = $comp } -Actions @(
                @{ Text = 'Hinzufuegen ...'; Color = '#FFA6E3A1'; NoSelection = $true; Handler = {
                    param($rows, $win, $ctx)
                    $f = Show-HMFormDialog -Title "Mitglied hinzufuegen - $($ctx.Computer)" -OkText 'Hinzufuegen' -Fields @(
                        @{ Name = 'Group'; Label = 'Gruppe:'; Type = 'Combo'; Items = @($script:HMLocalGroups.Keys) }
                        @{ Name = 'Member'; Label = 'Konto (DOMAENE\Benutzer, DOMAENE\Gruppe oder PC\lokalerBenutzer):'; Type = 'Text'; Default = "$env:USERDOMAIN\" }
                    )
                    if (-not $f -or -not $f.Member -or $f.Member -match '\\$') { return }
                    $win.Close()
                    Invoke-HMTool -Title "$($f.Member) -> $($f.Group)" -Computer $ctx.Computer -ArgumentList @('Add', $script:HMLocalGroups[$f.Group], $f.Member) -Script $script:RS_GroupChange -OnResult { param($r2) Write-HMToolResult $r2; Show-HMLocalGroups }
                } }
                @{ Text = 'Entfernen (markierte)'; Color = '#FFF38BA8'; Handler = {
                    param($rows, $win, $ctx)
                    $sel = @($rows | Where-Object { $_.Mitglied -and $_.Mitglied -notlike 'FEHLER*' })
                    if (-not $sel.Count) { return }
                    $bad = @($sel | Where-Object { $_.Gruppe -eq 'Administratoren' -and ($_.Mitglied -match '\\Administrator$' -or $_.Mitglied -match '\\Domain Admins$|\\Domaenen-Admins$') })
                    $msg = "Auf $($ctx.Computer) entfernen?`n`n" + (($sel | ForEach-Object { "  $($_.Gruppe): $($_.Mitglied)" }) -join "`n")
                    if ($bad.Count) { $msg += "`n`nACHTUNG: eingebauter Administrator / Domaenen-Admins dabei - Zugriff kann verloren gehen!" }
                    if ("$([System.Windows.MessageBox]::Show($win, $msg, 'Lokale Gruppen', 'YesNo', 'Warning'))" -ne 'Yes') { return }
                    $win.Close()
                    $n = 0
                    foreach ($s in $sel) {
                        $n++
                        $last = ($n -eq $sel.Count)
                        Invoke-HMTool -Title "$($s.Mitglied) aus $($s.Gruppe) entfernen" -Computer $ctx.Computer -ArgumentList @('Remove', $script:HMLocalGroups[$s.Gruppe], $s.Mitglied) -Script $script:RS_GroupChange -State $last -OnResult { param($r2, $c2, $isLast) Write-HMToolResult $r2; if ($isLast) { Show-HMLocalGroups } }
                    }
                } }
            )
    }
}

# ============================================================================
# 4. AUTOLOGON (Kennwort als LSA-Geheimnis wie Sysinternals Autologon, nicht im Klartext)
# ============================================================================
$script:HMLsaSource = @'
using System;
using System.Runtime.InteropServices;
public static class HMLsa {
    [StructLayout(LayoutKind.Sequential)] struct LSA_UNICODE_STRING { public ushort Length; public ushort MaximumLength; public IntPtr Buffer; }
    [StructLayout(LayoutKind.Sequential)] struct LSA_OBJECT_ATTRIBUTES { public int Length; public IntPtr RootDirectory; public IntPtr ObjectName; public uint Attributes; public IntPtr SecurityDescriptor; public IntPtr SecurityQualityOfService; }
    [DllImport("advapi32.dll")] static extern uint LsaOpenPolicy(IntPtr SystemName, ref LSA_OBJECT_ATTRIBUTES ObjectAttributes, uint DesiredAccess, out IntPtr PolicyHandle);
    [DllImport("advapi32.dll")] static extern uint LsaStorePrivateData(IntPtr PolicyHandle, ref LSA_UNICODE_STRING KeyName, IntPtr PrivateData);
    [DllImport("advapi32.dll")] static extern uint LsaRetrievePrivateData(IntPtr PolicyHandle, ref LSA_UNICODE_STRING KeyName, out IntPtr PrivateData);
    [DllImport("advapi32.dll")] static extern uint LsaClose(IntPtr PolicyHandle);
    [DllImport("advapi32.dll")] static extern uint LsaFreeMemory(IntPtr Buffer);
    [DllImport("advapi32.dll")] static extern int LsaNtStatusToWinError(uint Status);
    static LSA_UNICODE_STRING Make(string s) {
        LSA_UNICODE_STRING u = new LSA_UNICODE_STRING();
        u.Buffer = Marshal.StringToHGlobalUni(s); u.Length = (ushort)(s.Length * 2); u.MaximumLength = (ushort)(s.Length * 2 + 2);
        return u;
    }
    static IntPtr Open() {
        LSA_OBJECT_ATTRIBUTES a = new LSA_OBJECT_ATTRIBUTES(); a.Length = Marshal.SizeOf(typeof(LSA_OBJECT_ATTRIBUTES));
        IntPtr h; uint st = LsaOpenPolicy(IntPtr.Zero, ref a, 0x00000020 | 0x00000004, out h);
        if (st != 0) throw new System.ComponentModel.Win32Exception(LsaNtStatusToWinError(st));
        return h;
    }
    // value == null -> Geheimnis loeschen
    public static void Store(string key, string value) {
        IntPtr h = Open();
        LSA_UNICODE_STRING k = Make(key);
        IntPtr pv = IntPtr.Zero; LSA_UNICODE_STRING v = new LSA_UNICODE_STRING();
        try {
            if (value != null) { v = Make(value); pv = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(LSA_UNICODE_STRING))); Marshal.StructureToPtr(v, pv, false); }
            uint st = LsaStorePrivateData(h, ref k, pv);
            if (st != 0 && !(value == null && LsaNtStatusToWinError(st) == 2)) throw new System.ComponentModel.Win32Exception(LsaNtStatusToWinError(st));
        } finally {
            Marshal.FreeHGlobal(k.Buffer); if (v.Buffer != IntPtr.Zero) Marshal.FreeHGlobal(v.Buffer); if (pv != IntPtr.Zero) Marshal.FreeHGlobal(pv); LsaClose(h);
        }
    }
    public static bool Exists(string key) {
        IntPtr h = Open(); LSA_UNICODE_STRING k = Make(key); IntPtr p;
        try { uint st = LsaRetrievePrivateData(h, ref k, out p); if (st == 0) { LsaFreeMemory(p); return true; } return false; }
        finally { Marshal.FreeHGlobal(k.Buffer); LsaClose(h); }
    }
}
'@
$script:RS_Autologon = {
    param($action, $user, $domain, $cred, $count, $lsaSrc)
    $k = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    try {
        if (-not ('HMLsa' -as [type])) { Add-Type -TypeDefinition $lsaSrc -ErrorAction Stop }
        switch ($action) {
            'Status' {
                $p = Get-ItemProperty -LiteralPath $k
                "INFO Autologon: $(if ("$($p.AutoAdminLogon)" -eq '1') { 'AKTIV' } else { 'aus' })"
                "INFO Benutzer: $($p.DefaultDomainName)\$($p.DefaultUserName)"
                "INFO Kennwort: $(if ([HMLsa]::Exists('DefaultPassword')) { 'als LSA-Geheimnis gespeichert' } else { 'kein LSA-Geheimnis' })$(if ($null -ne $p.DefaultPassword) { ' - ACHTUNG: zusaetzlich KLARTEXT in der Registry (DefaultPassword)' })"
                if ($p.AutoLogonCount) { "INFO Verbleibende Anmeldungen: $($p.AutoLogonCount)" }
            }
            'Enable' {
                $pw = if ($cred) { $cred.GetNetworkCredential().Password } else { '' }
                [HMLsa]::Store('DefaultPassword', $pw)
                Set-ItemProperty -LiteralPath $k -Name AutoAdminLogon -Value '1' -Type String
                Set-ItemProperty -LiteralPath $k -Name DefaultUserName -Value $user -Type String
                Set-ItemProperty -LiteralPath $k -Name DefaultDomainName -Value $domain -Type String
                Remove-ItemProperty -LiteralPath $k -Name DefaultPassword -ErrorAction SilentlyContinue
                if ([int]$count -gt 0) { Set-ItemProperty -LiteralPath $k -Name AutoLogonCount -Value ([int]$count) -Type DWord } else { Remove-ItemProperty -LiteralPath $k -Name AutoLogonCount -ErrorAction SilentlyContinue }
                "OK Autologon aktiv fuer $domain\$user$(if ([int]$count -gt 0) { " ($count Anmeldung(en))" }) - Kennwort als LSA-Geheimnis gespeichert"
            }
            'Disable' {
                Set-ItemProperty -LiteralPath $k -Name AutoAdminLogon -Value '0' -Type String
                Remove-ItemProperty -LiteralPath $k -Name DefaultPassword -ErrorAction SilentlyContinue
                Remove-ItemProperty -LiteralPath $k -Name AutoLogonCount -ErrorAction SilentlyContinue
                [HMLsa]::Store('DefaultPassword', $null)
                'OK Autologon deaktiviert, gespeichertes Kennwort geloescht'
            }
        }
    } catch { "FEHLER: $($_.Exception.Message)" }
}
function Start-HMAutologon {
    $c = Get-TargetComputer
    $f = Show-HMFormDialog -Title "Autologon - $c" -OkText 'Ausfuehren' -OkColor '#FFFAB387' -Fields @(
        @{ Name = 'Action'; Label = 'Aktion:'; Type = 'Combo'; Items = @('Status anzeigen', 'Aktivieren', 'Deaktivieren') }
        @{ Name = 'User'; Label = 'Benutzer (DOMAENE\Name oder nur Name fuer lokales Konto):'; Type = 'Text' }
        @{ Name = 'Pw'; Label = 'Kennwort:'; Type = 'Password' }
        @{ Name = 'Count'; Label = 'Nur fuer so viele Anmeldungen (leer = dauerhaft):'; Type = 'Text' }
        @{ Type = 'Info'; Label = 'Das Kennwort wird wie beim Sysinternals-Autologon als LSA-Geheimnis gespeichert (nicht im Klartext). Wer Administrator am PC ist, kann es trotzdem auslesen - nur fuer Kiosk-/Praesentations-PCs verwenden.' }
    )
    if (-not $f) { return }
    $act = switch ($f.Action) { 'Aktivieren' { 'Enable' } 'Deaktivieren' { 'Disable' } default { 'Status' } }
    $user = ''; $dom = ''; $cred = $null; $count = 0
    if ($act -eq 'Enable') {
        $u = "$($f.User)".Trim()
        if (-not $u) { Out-Console 'Benutzer fehlt' 'Warning'; return }
        if ($u -match '^(.+)\\(.+)$') { $dom = $Matches[1]; $user = $Matches[2] } else { $dom = if ($c -and -not (Test-HMIsLocal $c)) { $c.Split('.')[0] } else { $env:COMPUTERNAME }; $user = $u }
        if ($dom -eq '.') { $dom = if (Test-HMIsLocal $c) { $env:COMPUTERNAME } else { $c.Split('.')[0] } }
        if ("$($f.Count)" -match '^\d+$') { $count = [int]$f.Count } elseif ("$($f.Count)".Trim()) { Out-Console "Anzahl ungueltig: '$($f.Count)'" 'Warning'; return }
        $cred = New-Object System.Management.Automation.PSCredential ("$dom\$user", $f.Pw)
        if (-not (Confirm-Action "Autologon auf $c fuer $dom\$user aktivieren?")) { return }
    }
    Invoke-HMTool -Title "Autologon ($($f.Action))" -Computer $c -ArgumentList @($act, $user, $dom, $cred, $count, $script:HMLsaSource) -Script $script:RS_Autologon
}

# ============================================================================
# 5. SPERRBILDSCHIRM / BILDSCHIRM-TIMEOUT / ENERGIE
# ============================================================================
$script:RS_Power = {
    param($o)
    $out = @()
    try {
        if ($o.Query) {
            $pol = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization' -ErrorAction SilentlyContinue
            $sys = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction SilentlyContinue
            $out += "INFO Sperrbildschirm (Bild vor Anmeldung): $(if ($pol.NoLockScreen -eq 1) { 'aus' } else { 'an' })"
            $out += "INFO Automatisch sperren nach: $(if ($sys.InactivityTimeoutSecs) { "$($sys.InactivityTimeoutSecs) s" } else { 'nicht gesetzt' })"
            $sch = (& powercfg.exe /getactivescheme) -join ' '
            $plan = if ($sch -match '\(([^)]+)\)\s*$') { $Matches[1] } else { $sch -replace '^.*:\s*', '' }
            $out += "INFO Energieplan: $plan"
            foreach ($s in @(@('SUB_VIDEO', 'VIDEOIDLE', 'Bildschirm aus'), @('SUB_SLEEP', 'STANDBYIDLE', 'Energiesparmodus'))) {
                $q = (& powercfg.exe /q SCHEME_CURRENT $s[0] $s[1]) -join "`n"
                # Die beiden Zeilen mit "...index: 0x..." sind Netz (AC) und Akku (DC) - sprachunabhaengig
                $mm = @([regex]::Matches($q, '(?im)^[^:\r\n]*index[^:\r\n]*:\s*0x([0-9a-f]+)\s*$'))
                $ac = if ($mm.Count -ge 1) { [Convert]::ToInt32($mm[0].Groups[1].Value, 16) } else { $null }
                $dc = if ($mm.Count -ge 2) { [Convert]::ToInt32($mm[1].Groups[1].Value, 16) } else { $null }
                $fmt = { param($v) if ($null -eq $v) { '?' } elseif ($v -eq 0) { 'nie' } else { "$([int]($v / 60)) min" } }
                $out += "INFO $($s[2]): Netz $(& $fmt $ac), Akku $(& $fmt $dc)"
            }
            $hb = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -ErrorAction SilentlyContinue).HiberbootEnabled
            $out += "INFO Schnellstart: $(if ($hb -eq 0) { 'aus' } else { 'an' })"
            return $out
        }
        if ($null -ne $o.NoLockScreen) {
            $k = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization'
            if (-not (Test-Path $k)) { New-Item -Path $k -Force | Out-Null }
            Set-ItemProperty -Path $k -Name NoLockScreen -Value ([int][bool]$o.NoLockScreen) -Type DWord
            $out += "OK Sperrbildschirm $(if ($o.NoLockScreen) { 'aus (wirkt nur bei Enterprise/Education)' } else { 'an' })"
        }
        if ($null -ne $o.LockSecs) {
            $k = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
            if ([int]$o.LockSecs -gt 0) { Set-ItemProperty -Path $k -Name InactivityTimeoutSecs -Value ([int]$o.LockSecs) -Type DWord; $out += "OK Automatisch sperren nach $($o.LockSecs) s (nach Neustart)" }
            else { Remove-ItemProperty -Path $k -Name InactivityTimeoutSecs -ErrorAction SilentlyContinue; $out += 'OK Automatisches Sperren (Richtlinie) entfernt' }
        }
        foreach ($p in @(@('MonAC', 'monitor-timeout-ac', 'Bildschirm aus (Netz)'), @('MonDC', 'monitor-timeout-dc', 'Bildschirm aus (Akku)'), @('SleepAC', 'standby-timeout-ac', 'Energiesparmodus (Netz)'), @('SleepDC', 'standby-timeout-dc', 'Energiesparmodus (Akku)'))) {
            if ($null -ne $o.($p[0])) { & powercfg.exe /change $p[1] ([int]$o.($p[0])) | Out-Null; $out += "OK $($p[2]): $(if ([int]$o.($p[0]) -eq 0) { 'nie' } else { "$($o.($p[0])) min" })" }
        }
        if ($null -ne $o.FastBoot) {
            Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -Value ([int][bool]$o.FastBoot) -Type DWord
            $out += "OK Schnellstart $(if ($o.FastBoot) { 'an' } else { 'aus' })"
        }
        if (-not $out.Count) { $out += 'INFO nichts geaendert' }
    } catch { $out += "FEHLER: $($_.Exception.Message)" }
    $out
}
function Start-HMPowerSettings {
    $c = Get-TargetComputer
    $f = Show-HMFormDialog -Title "Sperrbildschirm und Energie - $c" -OkText 'Anwenden' -Width 560 -Intro 'Leere Felder bleiben unveraendert. Minuten: 0 = nie. Aktuelle Werte: Rechtsklick auf den Knopf.' -Fields @(
        @{ Name = 'Lock'; Label = 'Sperrbildschirm (Bild vor der Anmeldung):'; Type = 'Combo'; Items = @('unveraendert', 'aus', 'an') }
        @{ Name = 'LockSecs'; Label = 'Automatisch sperren nach Sekunden Inaktivitaet (0 = Richtlinie entfernen):'; Type = 'Text' }
        @{ Name = 'MonAC'; Label = 'Bildschirm aus nach Minuten - Netzbetrieb:'; Type = 'Text' }
        @{ Name = 'MonDC'; Label = 'Bildschirm aus nach Minuten - Akku:'; Type = 'Text' }
        @{ Name = 'SleepAC'; Label = 'Energiesparmodus nach Minuten - Netzbetrieb:'; Type = 'Text' }
        @{ Name = 'SleepDC'; Label = 'Energiesparmodus nach Minuten - Akku:'; Type = 'Text' }
        @{ Name = 'Fast'; Label = 'Schnellstart (Fast Boot):'; Type = 'Combo'; Items = @('unveraendert', 'aus', 'an') }
    )
    if (-not $f) { return }
    $o = @{}
    if ($f.Lock -eq 'aus') { $o.NoLockScreen = $true } elseif ($f.Lock -eq 'an') { $o.NoLockScreen = $false }
    if ($f.Fast -eq 'aus') { $o.FastBoot = $false } elseif ($f.Fast -eq 'an') { $o.FastBoot = $true }
    foreach ($n in @('LockSecs', 'MonAC', 'MonDC', 'SleepAC', 'SleepDC')) {
        $v = "$($f.$n)".Trim()
        if (-not $v) { continue }
        if ($v -notmatch '^\d+$') { Out-Console "Ungueltiger Wert '$v'" 'Warning'; return }
        $o[$n] = [int]$v
    }
    if (-not $o.Count) { Out-Console 'Nichts ausgewaehlt' 'Info'; return }
    Invoke-HMTool -Title 'Sperrbildschirm/Energie' -Computer $c -ArgumentList @(, $o) -Script $script:RS_Power
}
function Show-HMPowerSettings { Invoke-HMTool -Title 'Sperrbildschirm/Energie (Status)' -ArgumentList @(, @{ Query = $true }) -Script $script:RS_Power }

# ============================================================================
# 6. PROFIL ERNEUERN / PROFILORDNER UMBENENNEN (Benutzer muss abgemeldet sein, Sicherung der Registry)
# ============================================================================
$script:RS_ProfileOp = {
    param($action, $sid, $newName)
    try {
        $bdir = Join-Path $env:ProgramData 'HUMig\ProfilSicherung'
        if ($action -eq 'List') {
            foreach ($f in @(Get-ChildItem -LiteralPath $bdir -Filter 'Profil_*.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
                try { $m = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json; $m | Add-Member -NotePropertyName File -NotePropertyValue $f.FullName -Force; $m | Add-Member -NotePropertyName AltExists -NotePropertyValue (Test-Path -LiteralPath $m.AltPath) -Force; $m } catch { }
            }
            return
        }
        if ($action -eq 'Undo') {
            $m = Get-Content -LiteralPath $newName -Raw | ConvertFrom-Json
            $sid = $m.Sid
            if (Test-Path -LiteralPath "Registry::HKEY_USERS\$sid") { return 'FEHLER: Benutzer ist angemeldet (oder Registry geladen) - erst abmelden bzw. PC neu starten' }
            if (-not (Test-Path -LiteralPath $m.AltPath)) { return "FEHLER: gesicherter Profilordner fehlt: $($m.AltPath)" }
            $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
            $out = @()
            $pl2 = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid"
            if (Test-Path -LiteralPath $pl2) {
                $reg2 = Join-Path $bdir "ProfileList_$($sid)_TESTPROFIL_$ts.reg"
                & reg.exe export "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid" "$reg2" /y | Out-Null
                $p2 = [Environment]::ExpandEnvironmentVariables("$((Get-ItemProperty -LiteralPath $pl2).ProfileImagePath)")
                $g2 = (Get-ItemProperty -LiteralPath $pl2).Guid
                Remove-Item -LiteralPath $pl2 -Recurse -Force -ErrorAction Stop
                if ($g2 -and (Test-Path -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileGuid\$g2")) { Remove-Item -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileGuid\$g2" -Recurse -Force -ErrorAction SilentlyContinue }
                $out += "OK Test-Profil-Eintrag entfernt (Sicherung: $reg2)"
                if ($p2 -and (Test-Path -LiteralPath $p2)) { Rename-Item -LiteralPath $p2 -NewName ((Split-Path $p2 -Leaf) + ".test_$ts") -ErrorAction Stop; $out += "OK Test-Profil beiseitegelegt: $p2.test_$ts" }
            }
            if (Test-Path -LiteralPath $m.Path) { Rename-Item -LiteralPath $m.Path -NewName ((Split-Path $m.Path -Leaf) + ".test_$ts") -ErrorAction Stop; $out += "OK vorhandener Ordner beiseitegelegt: $($m.Path).test_$ts" }
            Rename-Item -LiteralPath $m.AltPath -NewName (Split-Path $m.Path -Leaf) -ErrorAction Stop
            $out += "OK Profilordner zurueck: $($m.Path)"
            $o = & reg.exe import "$($m.Reg)" 2>&1
            if ($LASTEXITCODE -ne 0) { $out += "FEHLER Registry-Import: $o"; return $out }
            $out += 'OK Profil-Eintrag wiederhergestellt - der Benutzer meldet sich wieder mit dem alten Profil an'
            Rename-Item -LiteralPath $newName -NewName ((Split-Path $newName -Leaf) + ".erledigt_$ts") -ErrorAction SilentlyContinue
            return $out
        }
        $pl = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid"
        if (-not (Test-Path -LiteralPath $pl)) { return "FEHLER: Profil $sid nicht in der ProfileList" }
        if (Test-Path -LiteralPath "Registry::HKEY_USERS\$sid") { return 'FEHLER: Benutzer ist angemeldet (oder Registry geladen) - erst abmelden bzw. PC neu starten' }
        $path = (Get-ItemProperty -LiteralPath $pl).ProfileImagePath
        $path = [Environment]::ExpandEnvironmentVariables("$path")
        New-Item -ItemType Directory -Path $bdir -Force | Out-Null
        $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
        $reg = Join-Path $bdir "ProfileList_$($sid)_$ts.reg"
        & reg.exe export "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid" "$reg" /y | Out-Null
        $out = @("INFO Registry-Sicherung: $reg")
        if ($action -eq 'Renew') {
            $new = "$path.alt_$ts"
            if (Test-Path -LiteralPath $path) { Rename-Item -LiteralPath $path -NewName (Split-Path $new -Leaf) -ErrorAction Stop; $out += "OK Profilordner umbenannt: $new" }
            $guid = (Get-ItemProperty -LiteralPath $pl).Guid
            Remove-Item -LiteralPath $pl -Recurse -Force -ErrorAction Stop
            if ($guid -and (Test-Path -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileGuid\$guid")) { Remove-Item -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileGuid\$guid" -Recurse -Force -ErrorAction SilentlyContinue }
            $out += 'OK Profil-Eintrag entfernt - bei der naechsten Anmeldung wird ein neues Profil angelegt'
            $acc = $null; try { $acc = (New-Object System.Security.Principal.SecurityIdentifier($sid)).Translate([System.Security.Principal.NTAccount]).Value } catch { }
            [pscustomobject]@{ Sid = $sid; Account = $acc; Path = $path; AltPath = $new; Reg = $reg; Created = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); Computer = $env:COMPUTERNAME } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $bdir "Profil_$($sid)_$ts.json") -Encoding UTF8
            $out += 'INFO Zurueckholen: Werkzeuge > Profil zurueckholen (das Test-Profil wird dabei beiseitegelegt, nicht geloescht)' 
        } else {
            $parent = Split-Path $path -Parent
            $target = Join-Path $parent $newName
            if (Test-Path -LiteralPath $target) { return "FEHLER: $target existiert bereits" }
            Rename-Item -LiteralPath $path -NewName $newName -ErrorAction Stop
            Set-ItemProperty -LiteralPath $pl -Name ProfileImagePath -Value $target -Type ExpandString
            $out += "OK Profilordner $path -> $target, ProfileList angepasst"
            $out += 'WARN Programme mit fest gespeicherten Pfaden auf den alten Ordner muessen evtl. neu eingerichtet werden'
        }
        $out
    } catch { "FEHLER: $($_.Exception.Message)" }
}
function Start-HMProfileRenew {
    $p = Get-SelectedProfile
    if (-not $p -or $p.NoProfile -or -not $p.SID) { Out-Console 'Bitte zuerst einen Benutzer mit Profil waehlen.' 'Warning'; return }
    if ($p.Loaded) { Out-Console "$($p.Folder) ist angemeldet - erst abmelden." 'Warning'; return }
    $c = Get-TargetComputer
    if (-not (Confirm-Action "Profil von $($p.Account) auf $c ERNEUERN?`n`n  Ordner $($p.LocalPath) wird umbenannt (.alt_Datum),`n  der Profil-Eintrag entfernt (Sicherung als .reg unter ProgramData\HUMig).`n`nBei der naechsten Anmeldung entsteht ein leeres Profil - Daten danach z.B. per Restore zurueckholen.`n`nFortfahren?")) { return }
    Invoke-HMTool -Title "Profil erneuern ($($p.Folder))" -Computer $c -ArgumentList @('Renew', $p.SID, '') -Script $script:RS_ProfileOp -OnResult { param($r) Write-HMToolResult $r; Connect-Target }
}
function Show-HMProfileRestore {
    $c = Get-TargetComputer
    Invoke-HMTool -Title 'Gesicherte Profile lesen' -Computer $c -ArgumentList @('List', '', '') -Script $script:RS_ProfileOp -OnResult {
        param($r, $comp)
        $rows = New-Object System.Collections.Generic.List[object]
        foreach ($m in @($r)) { if ($m -and $m.Sid) { $rows.Add(@("$($m.Created)", "$($m.Account)", "$($m.Path)", "$($m.AltPath)", $(if ($m.AltExists) { 'ja' } else { 'FEHLT' }), "$($m.File)")) } }
        if (-not $rows.Count) { Out-Console "Keine erneuerten Profile auf $comp gefunden (ProgramData\HUMig\ProfilSicherung)." 'Info'; return }
        Show-DataGridWindow -Title "Erneuerte Profile - $comp" -Columns @('Erneuert', 'Konto', 'Profilpfad', 'Gesicherter Ordner', 'Vorhanden', 'Datei') -Rows $rows.ToArray() -Sort 'Erneuert DESC' -Width 1200 -Height 420 `
            -ActionContext @{ Computer = $comp } -Actions @(@{ Text = 'Altes Profil zurueckholen (markiertes)'; Color = '#FFA6E3A1'; Handler = {
                param($rows, $win, $ctx)
                $r = @($rows)[0]
                if ("$([System.Windows.MessageBox]::Show($win, "Altes Profil von $($r.Konto) auf $($ctx.Computer) zurueckholen?`n`n  $($r.'Gesicherter Ordner')  ->  $($r.Profilpfad)`n`nDas Test-Profil wird umbenannt (.test_Datum), nicht geloescht. Der Benutzer muss abgemeldet sein.", 'Profil zurueckholen', 'YesNo', 'Question'))" -ne 'Yes') { return }
                $win.Close()
                Invoke-HMTool -Title 'Profil zurueckholen' -Computer $ctx.Computer -ArgumentList @('Undo', '', "$($r.Datei)") -Script $script:RS_ProfileOp -OnResult { param($x) Write-HMToolResult $x; Connect-Target }
            } })
    }
}
function Start-HMProfileRename {
    $p = Get-SelectedProfile
    if (-not $p -or $p.NoProfile -or -not $p.SID) { Out-Console 'Bitte zuerst einen Benutzer mit Profil waehlen.' 'Warning'; return }
    if ($p.Loaded) { Out-Console "$($p.Folder) ist angemeldet - erst abmelden." 'Warning'; return }
    $c = Get-TargetComputer
    $f = Show-HMFormDialog -Title "Profilordner umbenennen - $c" -OkText 'Umbenennen' -OkColor '#FFFAB387' -Fields @(
        @{ Type = 'Info'; Label = "Aktuell: $($p.LocalPath)"; Color = '#FFCDD6F4' }
        @{ Name = 'New'; Label = 'Neuer Ordnername (nur der Name, z.B. nach Namensaenderung):'; Type = 'Text'; Default = $p.Folder }
    )
    if (-not $f) { return }
    $n = "$($f.New)".Trim()
    if (-not $n -or $n -match '[\\/:*?"<>|]' -or $n -eq $p.Folder) { Out-Console "Ungueltiger oder unveraenderter Name '$n'" 'Warning'; return }
    if (-not (Confirm-Action "Profilordner $($p.LocalPath) in '$n' umbenennen und ProfileList anpassen?")) { return }
    Invoke-HMTool -Title "Profilordner umbenennen ($($p.Folder) -> $n)" -Computer $c -ArgumentList @('Rename', $p.SID, $n) -Script $script:RS_ProfileOp -OnResult { param($r) Write-HMToolResult $r; Connect-Target }
}

# ============================================================================
# 7. WINDOWS-APPS NEU REGISTRIEREN (als Aufgabe im Kontext des Benutzers: jetzt, wenn angemeldet, sonst bei Anmeldung)
# ============================================================================
$script:RS_AppxReregister = {
    param($account, $loaded)
    try {
        $name = "HUMig_AppsNeu_$([guid]::NewGuid().ToString('N').Substring(0, 8))"
        $body = "Get-AppxPackage | Where-Object { `$_.InstallLocation -and (Test-Path (Join-Path `$_.InstallLocation 'AppxManifest.xml')) } | ForEach-Object { try { Add-AppxPackage -DisableDevelopmentMode -Register (Join-Path `$_.InstallLocation 'AppxManifest.xml') -ErrorAction Stop } catch { } }"
        $full = "try {`r`n$body`r`n} finally { Unregister-ScheduledTask -TaskName '$name' -Confirm:`$false -ErrorAction SilentlyContinue }"
        $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($full))
        $a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand $enc"
        $p = New-ScheduledTaskPrincipal -UserId $account -LogonType Interactive -RunLevel Limited
        $t = New-ScheduledTaskTrigger -AtLogOn -User $account
        $s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 1)
        $s.DeleteExpiredTaskAfter = 'P30D'
        $t.EndBoundary = (Get-Date).AddDays(30).ToString('s')
        Register-ScheduledTask -TaskName $name -Action $a -Principal $p -Trigger $t -Settings $s -Force -ErrorAction Stop | Out-Null
        if ($loaded) { Start-ScheduledTask -TaskName $name -ErrorAction Stop; "OK Windows-Apps werden jetzt fuer $account neu registriert (dauert einige Minuten, im Hintergrund)" }
        else { "OK Windows-Apps werden bei der naechsten Anmeldung von $account neu registriert" }
    } catch { "FEHLER: $($_.Exception.Message)" }
}
function Start-HMAppxReregister {
    $p = Get-SelectedProfile
    if (-not $p -or -not $p.Account) { Out-Console 'Bitte zuerst einen Benutzer waehlen (Konto muss aufloesbar sein).' 'Warning'; return }
    $c = Get-TargetComputer
    if (-not (Confirm-Action "Windows-Apps (Store-Apps, Startmenue, Einstellungen ...) fuer $($p.Account) auf $c neu registrieren?`n`n$(if ($p.Loaded) { 'Der Benutzer ist angemeldet - laeuft sofort in seiner Sitzung.' } else { 'Laeuft bei der naechsten Anmeldung des Benutzers.' })")) { return }
    Invoke-HMTool -Title "Windows-Apps neu registrieren ($($p.Account))" -Computer $c -ArgumentList @($p.Account, [bool]$p.Loaded) -Script $script:RS_AppxReregister
}

# ============================================================================
# 8. AUFGABEN AUS EINEM BACKUP EINZELN IMPORTIEREN
# ============================================================================
function Show-HMTaskImport {
    $b = $script:SelectedBackup
    if (-not $b) { Out-Console 'Im Reiter Restore zuerst ein Backup markieren (mit Modul Aufgabenplanung).' 'Warning'; return }
    $dir = Join-Path $b.Path 'Tasks'
    $idx = Join-Path $dir 'tasks.json'
    if (-not (Test-Path -LiteralPath $idx)) { Out-Console "Im Backup $($b.Name) sind keine Aufgaben gesichert (Modul 'Aufgabenplanung')." 'Warning'; return }
    $list = @(Get-Content -LiteralPath $idx -Raw -Encoding UTF8 | ConvertFrom-Json)
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($t in $list) {
        $user = ''
        try { [xml]$x = Get-Content -LiteralPath (Join-Path $dir $t.File) -Raw; $user = "$($x.Task.Principals.Principal.UserId)$($x.Task.Principals.Principal.GroupId)" } catch { }
        $rows.Add(@("$($t.Path)", "$($t.Name)", $user, "$($t.File)"))
    }
    Show-DataGridWindow -Title "Aufgaben im Backup $($b.Name)" -Columns @('Ordner', 'Name', 'Ausfuehren als', 'Datei') -Rows $rows.ToArray() -Sort 'Ordner ASC, Name ASC' -Width 1000 -Height 520 `
        -ActionContext @{ Dir = $dir } -Actions @(@{ Text = 'Auf gewaehltem Computer importieren (markierte)'; Color = '#FFA6E3A1'; Handler = {
            param($rows, $win, $ctx)
            $c = Get-TargetComputer
            if ("$([System.Windows.MessageBox]::Show($win, "$(@($rows).Count) Aufgabe(n) auf $c importieren?`n`nAufgaben mit gespeichertem Kennwort muessen danach in der Aufgabenplanung neu mit Kennwort gespeichert werden.", 'Aufgaben', 'YesNo', 'Question'))" -ne 'Yes') { return }
            $items = @(foreach ($r in @($rows)) { [pscustomobject]@{ Path = "$($r.Ordner)"; Name = "$($r.Name)"; Xml = (Get-Content -LiteralPath (Join-Path $ctx.Dir $r.Datei) -Raw) } })
            Invoke-HMTool -Title 'Aufgaben importieren' -Computer $c -ArgumentList @(, $items) -Script {
                param($items)
                foreach ($i in $items) {
                    try { Register-ScheduledTask -Xml $i.Xml -TaskName $i.Name -TaskPath $i.Path -Force -ErrorAction Stop | Out-Null; "OK $($i.Path)$($i.Name)" }
                    catch { "FEHLER $($i.Path)$($i.Name): $($_.Exception.Message)" }
                }
            }
        } })
}

# ============================================================================
# 9. AKKU-BERICHT
# ============================================================================
function Start-HMBatteryReport {
    $c = Get-TargetComputer
    Invoke-HMTool -Title 'Akku-Bericht' -Computer $c -TimeoutSec 120 -Script {
        $o = @()
        $b = @(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
        if (-not $b.Count) { return @('INFO Kein Akku gefunden (Desktop-PC?)') }
        foreach ($x in $b) { $o += "INFO Ladestand: $($x.EstimatedChargeRemaining) %  ($($x.Name))" }
        $health = $false
        try {
            $full = @(Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction Stop)
            $des = @(Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData -ErrorAction Stop)
            $cyc = @(Get-CimInstance -Namespace root\wmi -ClassName BatteryCycleCount -ErrorAction SilentlyContinue)
            for ($i = 0; $i -lt $full.Count; $i++) {
                $f = [double]$full[$i].FullChargedCapacity; $d = [double]$des[$i].DesignedCapacity
                if ($d -gt 0) {
                    $h = [math]::Round(100 * $f / $d)
                    $o += "$(if ($h -lt 60) { 'WARN' } else { 'OK' }) Akku-Zustand: $h % ($([math]::Round($f / 1000, 1)) von $([math]::Round($d / 1000, 1)) Wh)$(if ($cyc.Count -gt $i -and $cyc[$i].CycleCount) { ", $($cyc[$i].CycleCount) Ladezyklen" })"
                    $health = $true
                }
            }
        } catch { }
        $f = Join-Path $env:windir "Temp\HUMig_Akku_$(Get-Date -Format 'yyyyMMdd_HHmmss').html"
        & powercfg.exe /batteryreport /output "$f" | Out-Null
        if (Test-Path $f) {
            # WMI ohne Kapazitaeten (haeufig): aus dem Akku-Bericht lesen - erste zwei mWh-Werte = Nenn- und aktuelle Vollladekapazitaet, danach Ladezyklen
            if (-not $health) {
                try {
                    $html = [System.IO.File]::ReadAllText($f)
                    $m = [regex]::Matches($html, '>\s*([\d\.,\s\u00A0\u202F\u2009]+?)\s*mWh[^<]*<')
                    if ($m.Count -ge 2) {
                        $d = [double](($m[0].Groups[1].Value) -replace '\D', ''); $fc = [double](($m[1].Groups[1].Value) -replace '\D', '')
                        $rest = $html.Substring($m[1].Index + $m[1].Length)
                        $cy = if ($rest -match '<td[^>]*>\s*(\d+|-)\s*</td>') { $Matches[1] } else { '' }
                        if ($d -gt 0) {
                            $h = [math]::Round(100 * $fc / $d)
                            $o += "$(if ($h -lt 60) { 'WARN' } else { 'OK' }) Akku-Zustand: $h % ($([math]::Round($fc / 1000, 1)) von $([math]::Round($d / 1000, 1)) Wh)$(if ($cy -match '^\d+$') { ", $cy Ladezyklen" })"
                        }
                    }
                } catch { }
            }
            $o += "FILE|$f"
        }
        $o
    } -OnResult {
        param($r, $comp)
        foreach ($l in @($r)) {
            if ("$l" -like 'FILE|*') {
                $remote = "$l".Substring(5)
                $src = if (Test-HMIsLocal $comp) { $remote } else { Convert-HMPath @{ IsRemote = $true; Computer = $comp } $remote }
                $dst = Join-Path $script:LogDir ("Akku_{0}_{1}.html" -f ($comp -replace '[^\w\-]', '_'), (Get-Date -Format 'yyyyMMdd_HHmmss'))
                try { Copy-Item -LiteralPath $src -Destination $dst -Force -ErrorAction Stop; Out-Console "   Bericht: $dst" 'Success'; Start-Process $dst } catch { Out-Console "   Bericht nicht kopierbar: $($_.Exception.Message)" 'Warning' }
            } else { Write-HMToolResult $l }
        }
    }
}

# ============================================================================
# 10. EREIGNISANZEIGE: Fehler/Warnungen der letzten Tage als Tabelle
# ============================================================================
function Show-HMEventLog([int]$Days = 3, [bool]$Warnings = $false) {
    $c = Get-TargetComputer
    Invoke-HMTool -Title "Ereignisse (letzte $Days Tage$(if ($Warnings) { ', mit Warnungen' }))" -Computer $c -TimeoutSec 180 -ArgumentList @($Days, $Warnings) -Script {
        param($days, $warn)
        $lv = if ($warn) { @(1, 2, 3) } else { @(1, 2) }
        $ev = @()
        foreach ($log in @('System', 'Application')) {
            try { $ev += @(Get-WinEvent -FilterHashtable @{ LogName = $log; Level = $lv; StartTime = (Get-Date).AddDays(-$days) } -MaxEvents 1000 -ErrorAction Stop) } catch { }
        }
        foreach ($e in $ev) {
            $msg = "$($e.Message)"; if (-not $msg) { $msg = "(ohne Text, ID $($e.Id))" }
            [pscustomobject]@{ Zeit = $e.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'); Log = $e.LogName; Stufe = "$($e.LevelDisplayName)"; Quelle = $e.ProviderName; ID = $e.Id; Meldung = (($msg -split "`r?`n")[0]) }
        }
    } -OnResult {
        param($r, $comp)
        $rows = New-Object System.Collections.Generic.List[object]
        foreach ($e in @($r)) { if ($e -and $e.Zeit) { $rows.Add(@($e.Zeit, $e.Log, $e.Stufe, $e.Quelle, [int]$e.ID, $e.Meldung)) } }
        Out-Console "$($rows.Count) Ereignisse auf $comp" 'Success'
        Show-DataGridWindow -Title "Ereignisse - $comp" -Columns @('Zeit', 'Log', 'Stufe', 'Quelle', 'ID', 'Meldung') -ColumnTypes @{ ID = [int] } -Rows $rows.ToArray() -Sort 'Zeit DESC' -Width 1300 -Height 680
    }
}

# ============================================================================
# 11. GESPEICHERTE ANMELDEDATEN (Anmeldeinformationsverwaltung) dieses Kontos anzeigen/loeschen
# ============================================================================
function Get-HMCmdKeyList {
    $out = & cmdkey.exe /list 2>&1
    $list = @(); $cur = $null
    foreach ($l in $out) {
        $s = "$l".Trim()
        if ($s -match '^(Ziel|Target)\s*:\s*(.+)$') { if ($cur) { $list += $cur }; $cur = [ordered]@{ Target = $Matches[2].Trim(); Type = ''; User = '' } }
        elseif ($cur -and $s -match '^(Typ|Type)\s*:\s*(.+)$') { $cur.Type = $Matches[2].Trim() }
        elseif ($cur -and $s -match '^(Benutzer|User)\s*:\s*(.+)$') { $cur.User = $Matches[2].Trim() }
    }
    if ($cur) { $list += $cur }
    return @($list | ForEach-Object { [pscustomobject]$_ })
}
function Show-HMCredentials {
    $list = @(Get-HMCmdKeyList)
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($x in $list) { $rows.Add(@($x.Target, $x.Type, $x.User)) }
    Show-DataGridWindow -Title "Gespeicherte Anmeldedaten - $env:USERDOMAIN\$env:USERNAME (dieses Konto)" -Columns @('Ziel', 'Typ', 'Benutzer') -Rows $rows.ToArray() -Sort 'Ziel ASC' -Width 1000 -Height 520 `
        -CountText "$($rows.Count) Eintraege (ohne Kennwoerter)" -Actions @(@{ Text = 'Markierte loeschen'; Color = '#FFF38BA8'; Handler = {
            param($rows, $win, $ctx)
            if ("$([System.Windows.MessageBox]::Show($win, "$(@($rows).Count) gespeicherte Anmeldedaten loeschen?", 'Anmeldedaten', 'YesNo', 'Warning'))" -ne 'Yes') { return }
            foreach ($r in @($rows)) {
                $t = "$($r.Ziel)" -replace '^(LegacyGeneric|Domain|WindowsLive|Generic)[^=]*=', ''
                $o = & cmdkey.exe "/delete:$t" 2>&1
                Out-Console "   $t : $(("$o" -split "`n")[-1].Trim())" $(if ($LASTEXITCODE -eq 0) { 'Success' } else { 'Error' })
            }
            $win.Close(); Show-HMCredentials
        } })
}

# ============================================================================
# 12. FIREWALL-PROFILE UND NETZWERKKATEGORIE
# ============================================================================
$script:RS_Firewall = {
    param($action, $arg)
    try {
        switch ($action) {
            'Category' { Get-NetConnectionProfile -InterfaceAlias $arg.Alias -ErrorAction Stop | Set-NetConnectionProfile -NetworkCategory $arg.Category -ErrorAction Stop; "OK $($arg.Alias): Netzwerk ist jetzt $($arg.Category)" }
            'Profile' { Set-NetFirewallProfile -Profile $arg.Profile -Enabled $arg.Enabled -ErrorAction Stop; "OK Firewall-Profil $($arg.Profile): $(if ($arg.Enabled -eq 'True') { 'EIN' } else { 'AUS' })" }
            default {
                foreach ($p in @(Get-NetFirewallProfile -ErrorAction Stop)) { [pscustomobject]@{ Art = 'Firewall-Profil'; Name = "$($p.Name)"; Wert = $(if ("$($p.Enabled)" -eq 'True') { 'Ein' } else { 'AUS' }); Details = "Eingehend: $(if ("$($p.DefaultInboundAction)" -eq 'NotConfigured') { 'Standard (blockieren)' } else { $p.DefaultInboundAction }), Ausgehend: $(if ("$($p.DefaultOutboundAction)" -eq 'NotConfigured') { 'Standard (erlauben)' } else { $p.DefaultOutboundAction })" } }
                foreach ($c in @(Get-NetConnectionProfile -ErrorAction SilentlyContinue)) { [pscustomobject]@{ Art = 'Netzwerk'; Name = "$($c.InterfaceAlias)"; Wert = "$($c.NetworkCategory)"; Details = "$($c.Name) (IPv4: $($c.IPv4Connectivity))" } }
            }
        }
    } catch { "FEHLER: $($_.Exception.Message)" }
}
function Show-HMFirewall {
    $c = Get-TargetComputer
    Invoke-HMTool -Title 'Firewall/Netzwerkprofil' -Computer $c -ArgumentList @('List', $null) -Script $script:RS_Firewall -OnResult {
        param($r, $comp)
        $rows = New-Object System.Collections.Generic.List[object]
        foreach ($x in @($r)) { if ($x -and $x.Art) { $rows.Add(@($x.Art, $x.Name, $x.Wert, $x.Details)) } }
        Show-DataGridWindow -Title "Firewall und Netzwerkprofil - $comp" -Columns @('Art', 'Name', 'Wert', 'Details') -Rows $rows.ToArray() -Width 950 -Height 420 -ActionContext @{ Computer = $comp } -Actions @(
            @{ Text = 'Netzwerk: Privat'; Color = '#FFA6E3A1'; Handler = { param($rows, $win, $ctx) Set-HMFirewallRow $rows $win $ctx 'Private' } }
            @{ Text = 'Netzwerk: Oeffentlich'; Color = '#FFF9E2AF'; Handler = { param($rows, $win, $ctx) Set-HMFirewallRow $rows $win $ctx 'Public' } }
            @{ Text = 'Profil EIN'; Color = '#FFA6E3A1'; Handler = { param($rows, $win, $ctx) Set-HMFirewallRow $rows $win $ctx 'On' } }
            @{ Text = 'Profil AUS'; Color = '#FFF38BA8'; Handler = { param($rows, $win, $ctx) Set-HMFirewallRow $rows $win $ctx 'Off' } }
        )
    }
}
function Set-HMFirewallRow($Rows, $Win, $Ctx, [string]$What) {
    $r = @($Rows)[0]
    if ($What -in @('Private', 'Public')) {
        if ($r.Art -ne 'Netzwerk') { [void][System.Windows.MessageBox]::Show($Win, 'Bitte eine Zeile "Netzwerk" markieren.', 'Firewall', 'OK', 'Information'); return }
        if ($r.Wert -eq 'DomainAuthenticated') { [void][System.Windows.MessageBox]::Show($Win, 'Domaenennetzwerke werden automatisch erkannt und koennen nicht umgestellt werden.', 'Firewall', 'OK', 'Information'); return }
        $arg = @{ Alias = "$($r.Name)"; Category = $What }; $act = 'Category'
    } else {
        if ($r.Art -ne 'Firewall-Profil') { [void][System.Windows.MessageBox]::Show($Win, 'Bitte eine Zeile "Firewall-Profil" markieren.', 'Firewall', 'OK', 'Information'); return }
        if ($What -eq 'Off' -and "$([System.Windows.MessageBox]::Show($Win, "Firewall-Profil '$($r.Name)' auf $($Ctx.Computer) AUSSCHALTEN?`n`nDer PC ist dann in diesem Netzwerk ungeschuetzt.", 'Firewall', 'YesNo', 'Warning'))" -ne 'Yes') { return }
        $arg = @{ Profile = "$($r.Name)"; Enabled = $(if ($What -eq 'On') { 'True' } else { 'False' }) }; $act = 'Profile'
    }
    $Win.Close()
    Invoke-HMTool -Title 'Firewall/Netzwerk aendern' -Computer $Ctx.Computer -ArgumentList @($act, $arg) -Script $script:RS_Firewall -OnResult { param($x) Write-HMToolResult $x; Show-HMFirewall }
}

# ============================================================================
# 13. PROFIL EINEM ANDEREN KONTO ZUWEISEN (z.B. Domaene -> lokal). Profil bleibt am Ort, nichts wird kopiert.
#     Benutzer abgemeldet; Sicherung: ProfileList-.reg + Dateirechte (icacls /save) unter ProgramData\HUMig\ProfilZuweisung
# ============================================================================
$script:RS_ProfileAssign = {
    param($srcSid, $target, $createLocal, $cred, $addAdmin, $setOwner)
    $out = New-Object System.Collections.Generic.List[string]
    $hkuName = 'HUMIG_ZUWEISUNG'
    $loaded = @()
    try {
        $plRoot = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
        $pl1 = Join-Path $plRoot $srcSid
        if (-not (Test-Path -LiteralPath $pl1)) { return 'FEHLER: Quellprofil nicht in der ProfileList' }
        if (Test-Path -LiteralPath "Registry::HKEY_USERS\$srcSid") { return 'FEHLER: Quellbenutzer ist angemeldet (oder Registry geladen) - abmelden bzw. PC neu starten' }
        $path = [Environment]::ExpandEnvironmentVariables("$((Get-ItemProperty -LiteralPath $pl1).ProfileImagePath)")
        if (-not (Test-Path -LiteralPath (Join-Path $path 'NTUSER.DAT'))) { return "FEHLER: NTUSER.DAT fehlt in $path" }

        # --- Zielkonto ermitteln/anlegen ---
        $name = $target
        if ($name -match '^\.\\(.+)$') { $name = "$env:COMPUTERNAME\$($Matches[1])" }
        if ($name -notmatch '\\') { $name = "$env:COMPUTERNAME\$name" }
        $sid2 = $null
        try { $sid2 = (New-Object System.Security.Principal.NTAccount($name)).Translate([System.Security.Principal.SecurityIdentifier]).Value } catch { }
        if (-not $sid2) {
            if (-not $createLocal -or $name -notlike "$env:COMPUTERNAME\*") { return "FEHLER: Konto $name nicht gefunden$(if ($name -notlike "$env:COMPUTERNAME\*") { ' (Domaene erreichbar?)' } else { ' - Option Lokales Konto anlegen waehlen' })" }
            $short = $name.Split('\')[-1]
            New-LocalUser -Name $short -Password $cred.Password -FullName $short -PasswordNeverExpires:$false -ErrorAction Stop | Out-Null
            Add-LocalGroupMember -SID 'S-1-5-32-545' -Member $short -ErrorAction SilentlyContinue
            $sid2 = (New-Object System.Security.Principal.NTAccount($name)).Translate([System.Security.Principal.SecurityIdentifier]).Value
            $out.Add("OK Lokales Konto angelegt: $name")
        }
        if ($sid2 -eq $srcSid) { return 'FEHLER: Quell- und Zielkonto sind identisch' }
        if (Test-Path -LiteralPath (Join-Path $plRoot $sid2)) {
            $p2 = (Get-ItemProperty -LiteralPath (Join-Path $plRoot $sid2)).ProfileImagePath
            return "FEHLER: $name hat bereits ein Profil ($p2) - zuerst entfernen (Systemsteuerung > Benutzerprofile) oder anderes Konto waehlen"
        }
        if (Test-Path -LiteralPath "Registry::HKEY_USERS\$sid2") { return "FEHLER: $name ist angemeldet" }
        if ($addAdmin) { try { Add-LocalGroupMember -SID 'S-1-5-32-544' -Member $name -ErrorAction Stop; $out.Add("OK $name zu Administratoren hinzugefuegt") } catch { if ("$($_.Exception.Message)" -notmatch 'bereits|already') { $out.Add("WARN Administratoren: $($_.Exception.Message)") } } }

        # --- Sicherungen ---
        $bdir = Join-Path $env:ProgramData 'HUMig\ProfilZuweisung'
        New-Item -ItemType Directory -Path $bdir -Force | Out-Null
        $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
        & reg.exe export "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$srcSid" (Join-Path $bdir "ProfileList_$($srcSid)_$ts.reg") /y | Out-Null
        & icacls.exe "$path" /save (Join-Path $bdir "Rechte_$($srcSid)_$ts.acl") /T /C /Q | Out-Null
        $out.Add("INFO Sicherung: $bdir (ProfileList_*.reg, Rechte_*.acl - wiederherstellen mit icacls <Elternordner> /restore <Datei>)")

        # --- Dateirechte: Vollzugriff (vererbt) fuer das neue Konto, optional Besitzer ---
        $o = & icacls.exe "$path" /grant "*$($sid2):(OI)(CI)F" /T /C /Q 2>&1
        $fail = @($o | Where-Object { "$_" -match '(\d+) .*(fehl|fail)' } | ForEach-Object { if ("$_" -match '(\d+)\D+$') { [int]$Matches[1] } })
        $out.Add("OK Dateirechte fuer $name gesetzt$(if (@($fail | Where-Object { $_ -gt 0 }).Count) { ' (einige Dateien nicht aenderbar - siehe icacls)' })")
        if ($setOwner) { & icacls.exe "$path" /setowner "*$sid2" /T /C /Q | Out-Null; $out.Add('OK Besitzer gesetzt') }

        # --- Registry-Hives (NTUSER.DAT, UsrClass.dat): Rechte des alten Kontos fuer das neue uebernehmen ---
        $id1 = New-Object System.Security.Principal.SecurityIdentifier($srcSid)
        $id2 = New-Object System.Security.Principal.SecurityIdentifier($sid2)
        $hives = @(@((Join-Path $path 'NTUSER.DAT'), $hkuName), @((Join-Path $path 'AppData\Local\Microsoft\Windows\UsrClass.dat'), "${hkuName}_Classes"))
        foreach ($h in $hives) {
            if (-not (Test-Path -LiteralPath $h[0])) { continue }
            $r = & reg.exe load "HKU\$($h[1])" "$($h[0])" 2>&1
            if ($LASTEXITCODE -ne 0) { $out.Add("FEHLER reg load $($h[0]): $r"); continue }
            $loaded += $h[1]
            $keys = 0; $changed = 0; $denied = 0
            $stack = New-Object System.Collections.Generic.Stack[string]; $stack.Push($h[1])
            while ($stack.Count) {
                $sub = $stack.Pop(); $keys++
                $k = $null
                try { $k = [Microsoft.Win32.Registry]::Users.OpenSubKey($sub, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree, [System.Security.AccessControl.RegistryRights]'ReadKey, ChangePermissions') } catch { $denied++ }
                if (-not $k) { try { $k = [Microsoft.Win32.Registry]::Users.OpenSubKey($sub, $false) } catch { $denied++; continue } }
                if (-not $k) { continue }
                try {
                    if ($k.GetType()) {
                        try {
                            $acl = $k.GetAccessControl()
                            $mod = $false
                            foreach ($rule in @($acl.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]))) {
                                if ($rule.IdentityReference -eq $id1) {
                                    $acl.AddAccessRule((New-Object System.Security.AccessControl.RegistryAccessRule($id2, $rule.RegistryRights, $rule.InheritanceFlags, $rule.PropagationFlags, $rule.AccessControlType)))
                                    $mod = $true
                                }
                            }
                            if ($mod) { $k.SetAccessControl($acl); $changed++ }
                        } catch { $denied++ }
                    }
                    foreach ($n in $k.GetSubKeyNames()) { $stack.Push("$sub\$n") }
                } finally { $k.Close() }
            }
            $out.Add("OK Registry $(Split-Path $h[0] -Leaf): $keys Schluessel geprueft, $changed angepasst$(if ($denied) { ", $denied nicht aenderbar" })")
        }
        foreach ($l in $loaded) { [GC]::Collect(); [GC]::WaitForPendingFinalizers(); for ($i = 0; $i -lt 5; $i++) { & reg.exe unload "HKU\$l" 2>&1 | Out-Null; if ($LASTEXITCODE -eq 0) { break }; Start-Sleep -Seconds 2 } }
        $loaded = @()

        # --- ProfileList: Eintrag auf das neue Konto umhaengen ---
        $pl2 = Join-Path $plRoot $sid2
        New-Item -Path $pl2 -Force | Out-Null
        $src = Get-Item -LiteralPath $pl1
        foreach ($vn in $src.GetValueNames()) {
            if ($vn -in @('Sid', 'Guid')) { continue }
            $kind = $src.GetValueKind($vn)
            $val = $src.GetValue($vn, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $pt = switch ("$kind") { 'String' { 'String' } 'ExpandString' { 'ExpandString' } 'DWord' { 'DWord' } 'QWord' { 'QWord' } 'Binary' { 'Binary' } 'MultiString' { 'MultiString' } default { 'String' } }
            New-ItemProperty -LiteralPath $pl2 -Name $vn -Value $val -PropertyType $pt -Force | Out-Null
        }
        $b = New-Object byte[] ($id2.BinaryLength); $id2.GetBinaryForm($b, 0)
        New-ItemProperty -LiteralPath $pl2 -Name Sid -Value $b -PropertyType Binary -Force | Out-Null
        $guid = $src.GetValue('Guid')
        Remove-Item -LiteralPath $pl1 -Recurse -Force -ErrorAction Stop
        if ($guid -and (Test-Path -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileGuid\$guid")) { Remove-Item -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileGuid\$guid" -Recurse -Force -ErrorAction SilentlyContinue }
        $out.Add("OK Profil $path gehoert jetzt $name ($sid2)")
        $out.Add('INFO Danach: mit dem neuen Konto anmelden. Gespeicherte Kennwoerter (Browser, Anmeldeinformationsverwaltung), Zertifikate mit privatem Schluessel und EFS-Dateien sind nicht mehr lesbar. Store-Apps ggf. mit Windows-Apps neu registrieren.')
        $out.ToArray()
    } catch {
        foreach ($l in $loaded) { [GC]::Collect(); & reg.exe unload "HKU\$l" 2>&1 | Out-Null }
        $out.Add("FEHLER: $($_.Exception.Message)")
        $out.ToArray()
    }
}
function Start-HMProfileAssign {
    $p = Get-SelectedProfile
    if (-not $p -or $p.NoProfile -or -not $p.SID) { Out-Console 'Bitte zuerst den Benutzer waehlen, dessen Profil uebernommen werden soll.' 'Warning'; return }
    if ($p.Loaded) { Out-Console "$($p.Folder) ist angemeldet - erst abmelden." 'Warning'; return }
    $c = Get-TargetComputer
    $f = Show-HMFormDialog -Title "Profil einem anderen Konto zuweisen - $c" -OkText 'Zuweisen' -OkColor '#FFFAB387' -Width 600 -Fields @(
        @{ Type = 'Info'; Label = "Profil: $($p.LocalPath)  (bisher: $($p.Account))"; Color = '#FFCDD6F4' }
        @{ Name = 'Target'; Label = 'Neues Konto (lokal: nur Name oder .\Name, Domaene: DOMAENE\Name):'; Type = 'Text'; Default = $(if ($p.Account) { ".\$($p.Account.Split('\')[-1])" } else { '' }) }
        @{ Name = 'Create'; Label = 'Lokales Konto anlegen, falls es nicht existiert'; Type = 'Check'; Default = $true }
        @{ Name = 'Pw'; Label = 'Kennwort fuer das neue lokale Konto (nur beim Anlegen):'; Type = 'Password' }
        @{ Name = 'Pw2'; Label = 'Kennwort wiederholen:'; Type = 'Password' }
        @{ Name = 'Admin'; Label = 'Neues Konto zu den lokalen Administratoren hinzufuegen'; Type = 'Check' }
        @{ Name = 'Owner'; Label = 'Besitzer der Dateien auf das neue Konto setzen'; Type = 'Check'; Default = $true }
        @{ Type = 'Info'; Label = 'Vorher unbedingt ein Backup machen. Nicht uebertragbar (Windows-Verschluesselung DPAPI): gespeicherte Kennwoerter in Browser und Anmeldeinformationsverwaltung, Zertifikate mit privatem Schluessel, EFS. OneDrive/Office/Teams neu anmelden. Entra-ID-Konten (AzureAD\...) werden nicht unterstuetzt.' }
    )
    if (-not $f) { return }
    $t = "$($f.Target)".Trim()
    if (-not $t -or $t -match '^AzureAD\\' -or $t -match '@') { Out-Console "Ungueltiges oder nicht unterstuetztes Konto: '$t' (Entra-ID/UPN nicht moeglich)" 'Warning'; return }
    $cred = $null
    if ($f.Create) {
        if ($f.Pw_Len -gt 0) {
            $a = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($f.Pw))
            $b = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($f.Pw2))
            $same = ($a -ceq $b); $a = $null; $b = $null
            if (-not $same) { Out-Console 'Die Kennwoerter stimmen nicht ueberein.' 'Warning'; return }
        }
        $cred = New-Object System.Management.Automation.PSCredential ('x', $f.Pw)
    }
    if (-not (Confirm-Action "Profil $($p.LocalPath)`nvon $($p.Account)`nan $t uebergeben (auf $c)?`n`nDer Profil-Eintrag des alten Kontos wird entfernt (Sicherung unter ProgramData\HUMig\ProfilZuweisung).`nDauer: je nach Profilgroesse einige Minuten.`n`nFortfahren?")) { return }
    Invoke-HMTool -Title "Profil zuweisen ($($p.Folder) -> $t)" -Computer $c -TimeoutSec 3600 -ArgumentList @($p.SID, $t, [bool]$f.Create, $cred, [bool]$f.Admin, [bool]$f.Owner) -Script $script:RS_ProfileAssign -OnResult { param($r) Write-HMToolResult $r; Connect-Target }
}

# ============================================================================
# ZUSATZ-WERKZEUGE
# ============================================================================
# --- Angemeldete Benutzer (quser) anzeigen / abmelden ---
function Show-HMSessions {
    $c = Get-TargetComputer
    Invoke-HMTool -Title 'Angemeldete Benutzer' -Computer $c -Script {
        $q = & quser.exe 2>&1
        foreach ($l in @($q | Select-Object -Skip 1)) {
            $s = "$l"
            if ($s -match '^\s*>?(?<u>\S+)\s+(?:(?<n>\S+)\s+)?(?<id>\d+)\s+(?<st>\S+)\s+(?<idle>\S+)\s+(?<t>.+?)\s*$') {
                [pscustomobject]@{ Benutzer = $Matches.u; Sitzung = "$($Matches.n)"; ID = [int]$Matches.id; Status = $Matches.st; Leerlauf = $Matches.idle; Anmeldung = $Matches.t }
            }
        }
    } -OnResult {
        param($r, $comp)
        $rows = New-Object System.Collections.Generic.List[object]
        foreach ($x in @($r)) { if ($x -and $x.Benutzer) { $rows.Add(@($x.Benutzer, $x.Sitzung, [int]$x.ID, $x.Status, $x.Leerlauf, $x.Anmeldung)) } }
        if (-not $rows.Count) { Out-Console "Niemand an $comp angemeldet." 'Success'; return }
        Show-DataGridWindow -Title "Angemeldete Benutzer - $comp" -Columns @('Benutzer', 'Sitzung', 'ID', 'Status', 'Leerlauf', 'Anmeldung') -ColumnTypes @{ ID = [int] } -Rows $rows.ToArray() -Width 850 -Height 360 `
            -ActionContext @{ Computer = $comp } -Actions @(@{ Text = 'Abmelden (markierte)'; Color = '#FFF38BA8'; Handler = {
                param($rows, $win, $ctx)
                if ("$([System.Windows.MessageBox]::Show($win, "$(@($rows).Count) Sitzung(en) auf $($ctx.Computer) abmelden?`n`nNicht gespeicherte Daten gehen verloren.", 'Abmelden', 'YesNo', 'Warning'))" -ne 'Yes') { return }
                $ids = @($rows | ForEach-Object { [int]$_.ID })
                $win.Close()
                Invoke-HMTool -Title 'Abmelden' -Computer $ctx.Computer -ArgumentList @(, $ids) -Script { param($ids) foreach ($i in $ids) { & logoff.exe $i 2>&1 | Out-Null; if ($LASTEXITCODE -eq 0) { "OK Sitzung $i abgemeldet" } else { "FEHLER Sitzung ${i}: logoff $LASTEXITCODE" } } }
            } })
    }
}

# --- Neustart / Herunterfahren mit Nachricht ---
function Start-HMShutdown {
    $c = Get-TargetComputer
    $f = Show-HMFormDialog -Title "Neustart / Herunterfahren - $c" -OkText 'Ausfuehren' -OkColor '#FFF38BA8' -Fields @(
        @{ Name = 'Action'; Label = 'Aktion:'; Type = 'Combo'; Items = @('Neustart', 'Herunterfahren', 'Geplanten Neustart abbrechen') }
        @{ Name = 'Delay'; Label = 'Wartezeit in Sekunden:'; Type = 'Text'; Default = '120' }
        @{ Name = 'Msg'; Label = 'Nachricht an den Benutzer:'; Type = 'Text'; Default = 'Der Computer wird fuer Wartungsarbeiten neu gestartet. Bitte Dateien speichern.' }
    )
    if (-not $f) { return }
    if ($f.Action -eq 'Geplanten Neustart abbrechen') { $a = 'Abort'; $d = 0 }
    else {
        if ("$($f.Delay)" -notmatch '^\d+$') { Out-Console 'Wartezeit ungueltig' 'Warning'; return }
        $d = [int]$f.Delay; $a = if ($f.Action -eq 'Neustart') { 'Restart' } else { 'Shutdown' }
        if (-not (Confirm-Action "$($f.Action) von $c in $d Sekunden?")) { return }
    }
    Invoke-HMTool -Title $f.Action -Computer $c -ArgumentList @($a, $d, "$($f.Msg)") -Script {
        param($a, $d, $m)
        $m = ($m -replace '"', "'"); if ($m.Length -gt 500) { $m = $m.Substring(0, 500) }
        switch ($a) {
            'Abort' { & shutdown.exe /a 2>&1 | Out-Null; if ($LASTEXITCODE -eq 0) { 'OK geplanter Neustart abgebrochen' } else { "INFO kein geplanter Neustart (Code $LASTEXITCODE)" } }
            default { & shutdown.exe $(if ($a -eq 'Restart') { '/r' } else { '/s' }) /t $d /d p:0:0 /c "$m" 2>&1 | Out-Null; if ($LASTEXITCODE -eq 0) { "OK $(if ($a -eq 'Restart') { 'Neustart' } else { 'Herunterfahren' }) in $d Sekunden" } else { "FEHLER shutdown Code $LASTEXITCODE" } }
        }
    }
}

# --- Nachricht an angemeldete Benutzer ---
function Start-HMMessage {
    $c = Get-TargetComputer
    $f = Show-HMFormDialog -Title "Nachricht senden - $c" -OkText 'Senden' -Fields @(
        @{ Name = 'Msg'; Label = 'Nachricht an alle angemeldeten Benutzer:'; Type = 'Text' }
        @{ Name = 'Time'; Label = 'Anzeigedauer in Sekunden:'; Type = 'Text'; Default = '300' }
    )
    if (-not $f -or -not $f.Msg) { return }
    $sec = if ("$($f.Time)" -match '^\d+$') { [int]$f.Time } else { 300 }
    Invoke-HMTool -Title 'Nachricht senden' -Computer $c -ArgumentList @("$($f.Msg)", $sec) -Script {
        param($m, $s)
        $exe = Join-Path $env:windir 'System32\msg.exe'
        if (-not (Test-Path $exe)) { return 'FEHLER: msg.exe fehlt (Windows Home?)' }
        & $exe * "/time:$s" $m 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { 'OK Nachricht angezeigt' } else { "WARN msg Code $LASTEXITCODE (niemand angemeldet?)" }
    }
}

# --- Gruppenrichtlinien-Ergebnis (gpresult /h) fuer PC + gewaehlten Benutzer ---
function Start-HMGpResult {
    $c = Get-TargetComputer
    $p = Get-SelectedProfile
    $acc = if ($p -and $p.Account) { $p.Account } else { '' }
    # gpresult /h scheitert in Remote-Sitzungen (WinRM) mit "Zugriff verweigert" - /r, /v und /x funktionieren.
    # Daher: erst /h versuchen, sonst eigener HTML-Bericht aus /x (GPO-Tabellen, Gruppen) + /v (alle Einstellungen als Text).
    Invoke-HMTool -Title "Gruppenrichtlinien-Ergebnis$(if ($acc) { " ($acc)" })" -Computer $c -TimeoutSec 300 -ArgumentList @($acc) -Script {
        param($acc)
        $dir = Join-Path $env:windir 'Temp'
        $id = [guid]::NewGuid().ToString('N')
        $oem = [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
        $gp = {
            param([string]$a)
            $o = Join-Path $dir "HUMig_GP_$([guid]::NewGuid().ToString('N')).txt"
            & cmd.exe /c "gpresult.exe $a > `"$o`" 2>&1" | Out-Null
            $txt = if (Test-Path -LiteralPath $o) { [System.IO.File]::ReadAllText($o, $oem) -replace '\?(?=\d)', '' } else { '' }   # Richtungszeichen vor Datumsziffern (werden in der Codepage zu '?')
            Remove-Item -LiteralPath $o -Force -ErrorAction SilentlyContinue
            return $txt
        }
        $big = { param($f) (Test-Path -LiteralPath $f) -and (Get-Item -LiteralPath $f).Length -gt 2000 }
        $scope = if ($acc) { "/user `"$acc`"" } else { '/scope computer' }
        $html = Join-Path $dir "HUMig_GPResult_$id.html"

        # 1. Original-Bericht (klappt lokal bzw. interaktiv)
        [void](& $gp "$scope /h `"$html`" /f")
        if (-not (& $big $html) -and $acc) {
            $vt = & $gp "$scope /v"
            if ($vt -match 'RSoP|RSOP') {
                $msg = (($vt -split "`r?`n") | Where-Object { $_ -match 'RSoP|RSOP' } | Select-Object -First 1).Trim()
                "WARN Benutzer-Teil fuer $acc nicht verfuegbar (gpresult: $msg) - Bericht nur mit Computer-Richtlinien. Den Benutzer-Teil gibt es i.d.R. nur, solange der Benutzer an diesem PC angemeldet ist"
                $scope = '/scope computer'; [void](& $gp "$scope /h `"$html`" /f")
            }
        }
        if (& $big $html) { "FILE|$html"; return }

        # 2. Eigener Bericht aus XML + Text
        $xf = Join-Path $dir "HUMig_GP_$id.xml"
        $xt = & $gp "$scope /x `"$xf`" /f"
        $vtext = & $gp "$scope /v"
        $enc = { param($s) [System.Net.WebUtility]::HtmlEncode("$s") }
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append("<!DOCTYPE html><html lang='de'><head><meta charset='utf-8'><title>Gruppenrichtlinien-Ergebnis $env:COMPUTERNAME</title><style>body{font:14px 'Segoe UI',Arial,sans-serif;margin:24px;color:#222}h1{font-size:22px}h2{font-size:17px;margin-top:26px;border-bottom:2px solid #b9a88a}table{border-collapse:collapse;width:100%;margin:8px 0}th,td{border:1px solid #ccc;padding:5px 8px;text-align:left;vertical-align:top}th{background:#eee}.no{color:#b00020}.ok{color:#2e7d32}pre{background:#f6f6f6;border:1px solid #ddd;padding:10px;font:12px Consolas,monospace;white-space:pre-wrap}</style></head><body>")
        [void]$sb.Append("<h1>Gruppenrichtlinien-Ergebnis &ndash; $(& $enc $env:COMPUTERNAME)</h1><p>Erstellt $(Get-Date -Format 'dd.MM.yyyy HH:mm') &middot; $(if ($acc -and $scope -ne '/scope computer') { 'Benutzer ' + (& $enc $acc) + ' + Computer' } else { 'nur Computer' }) &middot; (HUMig-Bericht aus gpresult /x und /v, da /h in Remote-Sitzungen nicht moeglich ist)</p>")
        if (Test-Path -LiteralPath $xf) {
            try {
                [xml]$x = Get-Content -LiteralPath $xf -Raw -Encoding UTF8
                foreach ($part in @(@{ N = 'ComputerResults'; T = 'Computer' }, @{ N = 'UserResults'; T = 'Benutzer' })) {
                    $res = $x.SelectSingleNode("//*[local-name()='$($part.N)']")
                    if (-not $res) { continue }
                    $rows = foreach ($g in @($res.SelectNodes("*[local-name()='GPO']"))) {
                        $v = { param($n) $nd = $g.SelectSingleNode("*[local-name()='$n']"); if ($nd) { $nd.InnerText } else { '' } }
                        $link = $g.SelectSingleNode(".//*[local-name()='SOMPath']")
                        $name = & $v 'Name'
                        $why = @()
                        if ((& $v 'IsValid') -eq 'false') {
                            # GPO nicht lesbar (fehlende Leserechte fuer den PC/Benutzer oder im SYSVOL nicht vorhanden) - dann ist auch der Name nur die GUID
                            $why += 'nicht lesbar (Leserecht/Sicherheitsfilter oder GPO fehlt im SYSVOL)'
                        } else {
                            if ((& $v 'Enabled') -eq 'false') { $why += 'deaktiviert' }
                            if ((& $v 'FilterAllowed') -eq 'false') { $why += 'WMI-Filter trifft nicht zu' }
                            if ((& $v 'AccessDenied') -eq 'true') { $why += 'Sicherheitsfilter (kein Zugriff)' }
                        }
                        [pscustomobject]@{ Name = $name; Link = $(if ($link) { $link.InnerText } else { '' }); Why = ($why -join ', '); Ok = (-not $why.Count) }
                    }
                    $rows = @($rows | Sort-Object @{ Expression = { -not $_.Ok } }, Name)
                    [void]$sb.Append("<h2>$($part.T): Gruppenrichtlinienobjekte ($(@($rows | Where-Object { $_.Ok }).Count) angewendet, $(@($rows | Where-Object { -not $_.Ok }).Count) nicht)</h2><table><tr><th>GPO</th><th>Verknuepft mit</th><th>Status</th></tr>")
                    foreach ($rw in $rows) {
                        $st = if ($rw.Ok) { "<span class='ok'>angewendet</span>" } else { "<span class='no'>nicht angewendet: $(& $enc $rw.Why)</span>" }
                        [void]$sb.Append("<tr><td>$(& $enc $rw.Name)</td><td>$(& $enc $rw.Link)</td><td>$st</td></tr>")
                    }
                    [void]$sb.Append('</table>')
                    $grp = @($res.SelectNodes(".//*[local-name()='SecurityGroup']/*[local-name()='Name']") | ForEach-Object { $_.InnerText } | Sort-Object -Unique)
                    if ($grp.Count) { [void]$sb.Append("<h2>$($part.T): Sicherheitsgruppen</h2><p>$((@($grp | ForEach-Object { & $enc $_ })) -join '<br>')</p>") }
                }
            } catch { [void]$sb.Append("<p class='no'>XML-Auswertung nicht moeglich: $(& $enc $_.Exception.Message)</p>") }
        } elseif ($xt) { [void]$sb.Append("<p class='no'>gpresult /x: $(& $enc $xt.Trim())</p>") }
        [void]$sb.Append("<h2>Alle Einstellungen (gpresult /v)</h2><pre>$(& $enc $vtext)</pre></body></html>")
        [System.IO.File]::WriteAllText($html, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
        Remove-Item -LiteralPath $xf -Force -ErrorAction SilentlyContinue
        if (& $big $html) { "FILE|$html" } else { "FEHLER gpresult: $($vtext.Trim())" }
    } -OnResult {
        param($r, $comp)
        foreach ($l in @($r)) {
            if ("$l" -like 'FILE|*') {
                $remote = "$l".Substring(5)
                $src = if (Test-HMIsLocal $comp) { $remote } else { Convert-HMPath @{ IsRemote = $true; Computer = $comp } $remote }
                $dst = Join-Path $script:LogDir ("GPResult_{0}_{1}.html" -f ($comp -replace '[^\w\-]', '_'), (Get-Date -Format 'yyyyMMdd_HHmmss'))
                try {
                    if (-not (Test-Path -LiteralPath $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }
                    Copy-Item -LiteralPath $src -Destination $dst -Force -ErrorAction Stop; Remove-Item -LiteralPath $src -Force -ErrorAction SilentlyContinue
                    Out-Console "   Bericht: $dst" 'Success'; Start-Process -FilePath explorer.exe -ArgumentList "`"$dst`""
                } catch { Out-Console "   Bericht nicht kopierbar ($src): $($_.Exception.Message)" 'Error' }
            } else { Write-HMToolResult $l }
        }
    }
}

# --- Entra ID / Intune: Status und Synchronisierung ---
function Start-HMIntune([bool]$Sync) {
    $c = Get-TargetComputer
    Invoke-HMTool -Title "Entra ID / Intune$(if ($Sync) { ' - Synchronisierung' })" -Computer $c -TimeoutSec 120 -ArgumentList @($Sync) -Script {
        param($sync)
        $o = @()
        $ds = & dsregcmd.exe /status 2>&1
        foreach ($k in @('AzureAdJoined', 'EnterpriseJoined', 'DomainJoined', 'DomainName', 'TenantName', 'DeviceId', 'MdmUrl', 'AzureAdPrt', 'WorkplaceJoined')) {
            $line = @($ds | Where-Object { "$_" -match "^\s*$k\s*:" }) | Select-Object -First 1
            if ($line) { $o += "INFO $("$line".Trim())" }
        }
        $enr = @(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Enrollments' -ErrorAction SilentlyContinue | ForEach-Object { Get-ItemProperty $_.PSPath } | Where-Object { $_.ProviderID -eq 'MS DM Server' })
        if ($enr.Count) { foreach ($e in $enr) { $o += "OK MDM-Registrierung: $($e.UPN) (Status $($e.EnrollmentState), $($e.PSChildName))" } } else { $o += 'WARN keine MDM-Registrierung (Intune) gefunden' }
        if ($sync) {
            $n = 0
            foreach ($e in $enr) {
                foreach ($t in @(Get-ScheduledTask -TaskPath "\Microsoft\Windows\EnterpriseMgmt\$($e.PSChildName)\" -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like 'Schedule #3*' -or $_.TaskName -like 'PushLaunch*' })) {
                    try { Start-ScheduledTask -InputObject $t -ErrorAction Stop; $n++ } catch { }
                }
            }
            $o += $(if ($n) { "OK Synchronisierung angestossen ($n Aufgabe(n)) - Ergebnis nach einigen Minuten im Intune-Portal" } else { 'WARN keine Intune-Synchronisierungsaufgabe gefunden' })
        }
        $o
    }
}

# --- Domaene: Vertrauensstellung, Zeit, Kerberos ---
function Start-HMDomainRepair {
    $c = Get-TargetComputer
    $f = Show-HMFormDialog -Title "Domaene / Zeit / Kerberos - $c" -OkText 'Ausfuehren' -Fields @(
        @{ Name = 'Action'; Label = 'Aktion:'; Type = 'Combo'; Items = @('Pruefen (Vertrauensstellung, Zeit, DC)', 'Vertrauensstellung reparieren', 'Zeit synchronisieren', 'Kerberos-Tickets des Computers leeren') }
    )
    if (-not $f) { return }
    $act = switch -Wildcard ($f.Action) { 'Pruefen*' { 'Test' } 'Vertrauen*' { 'Repair' } 'Zeit*' { 'Time' } default { 'Klist' } }
    $cred = $null
    if ($act -eq 'Repair') {
        try { $cred = Get-Credential -UserName "$env:USERDOMAIN\$env:USERNAME" -Message 'Domaenen-Anmeldedaten mit Recht zum Zuruecksetzen des Computerkontos' } catch { }
        if (-not $cred) { return }
    }
    Invoke-HMTool -Title $f.Action -Computer $c -TimeoutSec 180 -ArgumentList @($act, $cred) -Script {
        param($act, $cred)
        $cs = Get-CimInstance Win32_ComputerSystem
        if (-not $cs.PartOfDomain -and $act -in @('Test', 'Repair')) { return 'INFO Computer ist nicht in einer Domaene' }
        switch ($act) {
            'Test' {
                try { $ok = Test-ComputerSecureChannel -ErrorAction Stop; "$(if ($ok) { 'OK' } else { 'FEHLER' }) Vertrauensstellung zur Domaene $($cs.Domain): $(if ($ok) { 'in Ordnung' } else { 'DEFEKT - Reparieren waehlen' })" } catch { "FEHLER Vertrauensstellung: $($_.Exception.Message)" }
                $dc = (& nltest.exe /dsgetdc:$($cs.Domain) 2>&1 | Where-Object { "$_" -match '^\s*DC:' }) -join ''
                if ($dc) { "INFO $("$dc".Trim())" }
                "INFO $(((& w32tm.exe /query /status 2>&1) | Where-Object { "$_" -match '^(Quelle|Source)' }) -join ' ')"
                "INFO Uhrzeit PC: $((Get-Date).ToString('dd.MM.yyyy HH:mm:ss'))"
            }
            'Repair' { try { if (Test-ComputerSecureChannel -Repair -Credential $cred -ErrorAction Stop) { 'OK Vertrauensstellung repariert' } else { 'FEHLER Reparatur fehlgeschlagen' } } catch { "FEHLER: $($_.Exception.Message)" } }
            'Time' { $o = & w32tm.exe /resync /force 2>&1; "$(if ($LASTEXITCODE -eq 0) { 'OK' } else { 'FEHLER' }) Zeit: $(($o | Out-String).Trim())" }
            'Klist' { & klist.exe -li 0x3e7 purge 2>&1 | Out-Null; "$(if ($LASTEXITCODE -eq 0) { 'OK Kerberos-Tickets des Computers geleert (gpupdate holt neue)' } else { "FEHLER klist Code $LASTEXITCODE" })" }
        }
    }
}

# --- Druckwarteschlange leeren / Spooler neu starten ---
function Start-HMSpoolerReset {
    $c = Get-TargetComputer
    if (-not (Confirm-Action "Druckwarteschlange auf $c leeren und Druckspooler neu starten?`n`nAlle wartenden Druckauftraege gehen verloren.")) { return }
    Invoke-HMTool -Title 'Druckspooler' -Computer $c -Script {
        try {
            Stop-Service Spooler -Force -ErrorAction Stop
            $d = Join-Path $env:windir 'System32\spool\PRINTERS'
            $f = @(Get-ChildItem -LiteralPath $d -File -Force -ErrorAction SilentlyContinue)
            $f | Remove-Item -Force -ErrorAction SilentlyContinue
            Start-Service Spooler -ErrorAction Stop
            "OK $($f.Count) Datei(en) aus der Warteschlange geloescht, Spooler laeuft"
        } catch { "FEHLER: $($_.Exception.Message)"; try { Start-Service Spooler -ErrorAction SilentlyContinue } catch { } }
    }
}

# --- Speicher aufraeumen ---
$script:RS_Cleanup = {
    param($o)
    function Get-HUFreeBytes { [long](Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'").FreeSpace }
    function Remove-HUOld([string]$Root, [int]$Hours) {
        if (-not (Test-Path -LiteralPath $Root)) { return 0 }
        $lim = (Get-Date).AddHours(-$Hours); $n = 0
        $stack = New-Object System.Collections.Generic.Stack[string]; $stack.Push($Root)
        while ($stack.Count) {
            $d = $stack.Pop()
            try {
                foreach ($i in (New-Object System.IO.DirectoryInfo $d).EnumerateFileSystemInfos()) {
                    if ($i.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                    if ($i -is [IO.DirectoryInfo]) { $stack.Push($i.FullName); continue }
                    if ($i.LastWriteTime -lt $lim) { try { $i.Attributes = 'Normal'; $i.Delete(); $n++ } catch { } }
                }
            } catch { }
        }
        return $n
    }
    $before = Get-HUFreeBytes
    $out = @()
    if ($o.Temp) {
        $n = Remove-HUOld (Join-Path $env:windir 'Temp') 24
        foreach ($p in @(Get-CimInstance Win32_UserProfile | Where-Object { -not $_.Special -and $_.LocalPath })) { $n += Remove-HUOld (Join-Path $p.LocalPath 'AppData\Local\Temp') 24 }
        $out += "OK Temp-Ordner: $n Dateien (aelter als 24 h) geloescht"
    }
    if ($o.WU) {
        try {
            Stop-Service wuauserv, bits -Force -ErrorAction SilentlyContinue
            $n = Remove-HUOld (Join-Path $env:windir 'SoftwareDistribution\Download') 0
            $out += "OK Windows-Update-Downloadcache: $n Dateien geloescht"
        } finally { Start-Service bits, wuauserv -ErrorAction SilentlyContinue }
        try { Delete-DeliveryOptimizationCache -Force -ErrorAction Stop | Out-Null; $out += 'OK Cache der Uebermittlungsoptimierung geleert' } catch { }
    }
    if ($o.Wer) { $n = Remove-HUOld (Join-Path $env:ProgramData 'Microsoft\Windows\WER') 0; $out += "OK Fehlerberichte: $n Dateien geloescht" }
    if ($o.Bin) {
        $rb = Join-Path $env:SystemDrive '$Recycle.Bin'
        $n = 0
        foreach ($d in @(Get-ChildItem -LiteralPath $rb -Directory -Force -ErrorAction SilentlyContinue)) {
            foreach ($i in @(Get-ChildItem -LiteralPath $d.FullName -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' })) { try { Remove-Item -LiteralPath $i.FullName -Recurse -Force -ErrorAction Stop; $n++ } catch { } }
        }
        $out += "OK Papierkorb (alle Benutzer, Systemlaufwerk): $n Eintraege geloescht"
    }
    if ($o.WinOld) {
        $wo = Join-Path $env:SystemDrive 'Windows.old'
        if (-not (Test-Path -LiteralPath $wo)) { $out += 'OK Windows.old: nicht vorhanden' }
        else {
            # 1. Datentraegerbereinigung (offizieller Weg): "Vorherige Windows-Installation(en)" + Setup-Reste
            $vc = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
            $keys = @('Previous Installations', 'Temporary Setup Files', 'Windows Upgrade Log Files', 'Setup Log Files')
            foreach ($k in $keys) { if (Test-Path -LiteralPath "$vc\$k") { New-ItemProperty -LiteralPath "$vc\$k" -Name 'StateFlags0077' -Value 2 -PropertyType DWord -Force | Out-Null } }
            try { $p = Start-Process -FilePath (Join-Path $env:windir 'System32\cleanmgr.exe') -ArgumentList '/sagerun:77' -WindowStyle Hidden -PassThru; if (-not $p.WaitForExit(1800000)) { try { $p.Kill() } catch { } } } catch { }
            foreach ($k in $keys) { Remove-ItemProperty -LiteralPath "$vc\$k" -Name 'StateFlags0077' -ErrorAction SilentlyContinue }
            # 2. falls noch vorhanden: Besitz uebernehmen + loeschen
            if (Test-Path -LiteralPath $wo) {
                & takeown.exe /F $wo /A /R /D Y 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) { & takeown.exe /F $wo /A /R /D J 2>&1 | Out-Null }
                & icacls.exe $wo /grant "*S-1-5-32-544:(OI)(CI)F" /T /C /Q 2>&1 | Out-Null
                & cmd.exe /c "attrib -r -s -h `"$wo\*`" /S /D >nul 2>&1 & rd /s /q `"$wo`"" 2>&1 | Out-Null
            }
            if (Test-Path -LiteralPath $wo) { $out += "WARN Windows.old nur teilweise entfernt (gesperrte Dateien) - nach Neustart nochmal ausfuehren" } else { $out += 'OK Windows.old entfernt' }
        }
    }
    if ($o.Dism) {
        $null = & dism.exe /Online /Cleanup-Image /StartComponentCleanup 2>&1
        $out += "$(if ($LASTEXITCODE -eq 0) { 'OK' } else { 'WARN' }) Komponentenspeicher (DISM): Code $LASTEXITCODE"
    }
    $after = Get-HUFreeBytes
    $out += ("OK Freigegeben: {0:N2} GB (frei jetzt {1:N2} GB)" -f ([math]::Max([double]0, [double]($after - $before)) / 1GB), ($after / 1GB))
    $out
}
function Start-HMCleanup([string[]]$Hosts = @()) {
    $c = if ($Hosts.Count) { "$($Hosts.Count) PC(s)" } else { Get-TargetComputer }
    $f = Show-HMFormDialog -Title "Speicher aufraeumen - $c" -OkText 'Aufraeumen' -OkColor '#FFFAB387' -Fields @(
        @{ Name = 'Temp'; Label = 'Temp-Ordner (Windows + alle Benutzer, Dateien aelter als 24 h)'; Type = 'Check'; Default = $true }
        @{ Name = 'WU'; Label = 'Windows-Update-Downloads und Uebermittlungsoptimierung'; Type = 'Check'; Default = $true }
        @{ Name = 'Wer'; Label = 'Windows-Fehlerberichte'; Type = 'Check'; Default = $true }
        @{ Name = 'Bin'; Label = 'Papierkorb aller Benutzer leeren'; Type = 'Check' }
        @{ Name = 'WinOld'; Label = 'Windows.old entfernen (alte Windows-Version nach Upgrade - Zurueckgehen ist danach nicht mehr moeglich)'; Type = 'Check' }
        @{ Name = 'Dism'; Label = 'Komponentenspeicher bereinigen (DISM, dauert bis zu 30 min)'; Type = 'Check' }
    )
    if (-not $f) { return }
    $o = @{ Temp = [bool]$f.Temp; WU = [bool]$f.WU; Wer = [bool]$f.Wer; Bin = [bool]$f.Bin; Dism = [bool]$f.Dism; WinOld = [bool]$f.WinOld }
    if ($o.WinOld -and -not (Confirm-Action "Windows.old auf $c endgueltig entfernen?`n`nDanach ist 'Zur vorherigen Windows-Version zurueckkehren' nicht mehr moeglich.")) { return }
    if ($Hosts.Count) { Invoke-HMMultiRemote -Hosts $Hosts -Title 'Speicher aufraeumen' -TimeoutSec 3600 -Arguments @(, $o) -Script $script:RS_Cleanup; return }
    Invoke-HMTool -Title 'Speicher aufraeumen' -Computer $c -TimeoutSec 3600 -ArgumentList @(, $o) -Script $script:RS_Cleanup
}

# --- Systemdateien reparieren (DISM RestoreHealth + SFC) als SYSTEM-Aufgabe mit Protokoll ---
function Start-HMSystemRepair([bool]$StatusOnly) {
    $c = Get-TargetComputer
    if (-not $StatusOnly -and -not (Confirm-Action "Systemdateien auf $c pruefen und reparieren (DISM /RestoreHealth + SFC /scannow)?`n`nLaeuft im Hintergrund (20-60 min). Ergebnis: Rechtsklick auf den Knopf.")) { return }
    Invoke-HMTool -Title $(if ($StatusOnly) { 'Systemreparatur - Status' } else { 'Systemreparatur starten' }) -Computer $c -ArgumentList @($StatusOnly) -Script {
        param($status)
        $log = Join-Path $env:windir 'Temp\HUMig_Systemreparatur.log'
        $name = 'HUMig_Systemreparatur'
        $t = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
        if ($status) {
            if ($t -and $t.State -eq 'Running') { 'INFO laeuft noch ...' }
            if (Test-Path $log) { Get-Content -LiteralPath $log -Tail 12 | ForEach-Object { "INFO $_" } } else { 'INFO noch keine Reparatur gelaufen' }
            return
        }
        if ($t -and $t.State -eq 'Running') { return 'WARN Reparatur laeuft bereits' }
        $body = @"
`$log = '$log'
"Start: `$(Get-Date)" | Set-Content -LiteralPath `$log -Encoding UTF8
`$d = & dism.exe /Online /Cleanup-Image /RestoreHealth 2>&1 | Select-Object -Last 3
"DISM Code `$LASTEXITCODE : `$((`$d | Out-String).Trim())" | Add-Content -LiteralPath `$log -Encoding UTF8
`$s = & sfc.exe /scannow 2>&1
`$st = ((`$s | Out-String) -replace [char]0, '') -split '\r?\n' | Where-Object { `$_.Trim() } | Select-Object -Last 3
"SFC Code `$LASTEXITCODE : `$((`$st -join ' ').Trim())" | Add-Content -LiteralPath `$log -Encoding UTF8
"Ende: `$(Get-Date) - Details: C:\Windows\Logs\CBS\CBS.log" | Add-Content -LiteralPath `$log -Encoding UTF8
Unregister-ScheduledTask -TaskName '$name' -Confirm:`$false -ErrorAction SilentlyContinue
"@
        try {
            if ($t) { Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue }
            $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($body))
            $a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand $enc"
            $p = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
            $s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 3)
            Register-ScheduledTask -TaskName $name -Action $a -Principal $p -Settings $s -Force -ErrorAction Stop | Out-Null
            Start-ScheduledTask -TaskName $name -ErrorAction Stop
            'OK Reparatur laeuft im Hintergrund - Ergebnis: Rechtsklick auf den Knopf'
        } catch { "FEHLER: $($_.Exception.Message)" }
    }
}

# --- Windows- und Office-Aktivierung ---
function Show-HMActivation {
    $c = Get-TargetComputer
    Invoke-HMTool -Title 'Aktivierungsstatus' -Computer $c -TimeoutSec 120 -Script {
        $st = @{ 0 = 'nicht lizenziert'; 1 = 'AKTIVIERT'; 2 = 'Kulanzzeit (OOB)'; 3 = 'Kulanzzeit (OOT)'; 4 = 'Kulanzzeit (nicht echt)'; 5 = 'Benachrichtigungsmodus'; 6 = 'erweiterte Kulanzzeit' }
        foreach ($p in @(Get-CimInstance SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL" -ErrorAction SilentlyContinue)) {
            $kind = if ($p.ApplicationID -eq '55c92734-d682-4d71-983e-d6ec3f16059f') { 'Windows' } elseif ($p.ApplicationID -eq '0ff1ce15-a989-479d-af46-f275c6370663') { 'Office' } else { 'Produkt' }
            $s = if ($st.ContainsKey([int]$p.LicenseStatus)) { $st[[int]$p.LicenseStatus] } else { "Status $($p.LicenseStatus)" }
            $kms = if ($p.KeyManagementServiceMachine) { " - KMS: $($p.KeyManagementServiceMachine)" } elseif ($p.DiscoveredKeyManagementServiceMachineName) { " - KMS: $($p.DiscoveredKeyManagementServiceMachineName)" } else { '' }
            # Microsoft 365 (Klick-und-Los, Abo): "Grace"-Eintraege sind normal, die Lizenz kommt ueber die Anmeldung des Benutzers
            $lvl = if ([int]$p.LicenseStatus -eq 1) { 'OK' } elseif ($kind -eq 'Office' -and "$($p.Name)$($p.Description)" -match 'Grace') { 'INFO' } else { 'WARN' }
            if ($lvl -eq 'INFO') { $s = 'Platzhalter (Abo-Lizenz ueber Benutzeranmeldung - normal)' }
            "$lvl ${kind}: $($p.Name) - $s ($($p.Description -replace '^.*?,\s*', ''))$kms"
        }
        $c2r = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue
        $chan = @{ '492350f6-3a01-4f97-b9c0-c7c6ddf67d60' = 'Aktueller Kanal'; '55336b82-a18d-4dd6-b5f6-9e5095c314a6' = 'Monatlicher Enterprise-Kanal'; '7ffbc6bf-bc32-4f92-8982-f9dd17fd3114' = 'Halbjaehrlicher Enterprise-Kanal'; '64256afe-f5d9-4f86-8936-8840a6a4f5be' = 'Aktueller Kanal (Vorschau)'; 'b8f9b850-328d-4355-9145-c59439a0c4cf' = 'Halbjaehrlicher Enterprise-Kanal (Vorschau)'; '5440fd1f-7ecb-4221-8110-145efaa6372f' = 'Beta-Kanal' }
        if ($c2r) { $cid = (("$($c2r.CDNBaseUrl)") -split '/')[-1]; "INFO Office (Klick-und-Los): $($c2r.ProductReleaseIds), Version $($c2r.VersionToReport), $(if ($chan.ContainsKey($cid)) { $chan[$cid] } else { "Kanal $cid" })" }
        if ($c2r -and "$($c2r.ProductReleaseIds)" -match 'O365|M365') { 'INFO Microsoft 365 Apps: Lizenz ueber die Anmeldung des Benutzers (Abonnement)' }
    }
}

# --- Netzwerktest vom Tool-PC zum gewaehlten Computer ---
function Start-HMNetTest {
    $c = Get-TargetComputer
    Out-Console "Netzwerktest -> $c ..." 'Info'
    Invoke-AsyncCommand -ScriptBlock {
        param($h)
        $o = @()
        try {
            $ips = @([System.Net.Dns]::GetHostAddresses($h) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | ForEach-Object { $_.IPAddressToString })
            $o += if ($ips.Count) { "OK DNS: $h -> $($ips -join ', ')" } else { "FEHLER DNS: keine IPv4-Adresse fuer $h" }
            foreach ($ip in $ips) { try { $rev = [System.Net.Dns]::GetHostEntry($ip).HostName; $o += "$(if ($rev.Split('.')[0] -ieq $h.Split('.')[0]) { 'OK' } else { 'WARN' }) Rueckwaerts: $ip -> $rev$(if ($rev.Split('.')[0] -ine $h.Split('.')[0]) { ' (anderer Name! veralteter DNS-Eintrag?)' })" } catch { $o += "INFO Rueckwaerts: $ip ohne PTR-Eintrag" } }
        } catch { $o += "FEHLER DNS: $($_.Exception.Message)" }
        try { $png = New-Object System.Net.NetworkInformation.Ping; $r = $png.Send($h, 1500); $o += if ("$($r.Status)" -eq 'Success') { "OK Ping: $($r.RoundtripTime) ms" } else { "WARN Ping: $($r.Status) (Firewall?)" } } catch { $o += "WARN Ping: $($_.Exception.InnerException.Message)" }
        foreach ($pt in @(@(445, 'SMB (Admin-Freigabe C$)'), @(5985, 'WinRM (PowerShell-Remoting)'), @(135, 'RPC'), @(3389, 'Remotedesktop'))) {
            $tc = New-Object System.Net.Sockets.TcpClient
            try { $ok = $tc.ConnectAsync($h, $pt[0]).Wait(1500) -and $tc.Connected; $o += "$(if ($ok) { 'OK' } else { 'WARN' }) Port $($pt[0]) $($pt[1]): $(if ($ok) { 'offen' } else { 'nicht erreichbar' })" } catch { $o += "WARN Port $($pt[0]) $($pt[1]): nicht erreichbar" } finally { $tc.Dispose() }
        }
        try { [void](Test-WSMan -ComputerName $h -ErrorAction Stop); $o += 'OK WinRM antwortet (Test-WSMan)' } catch { $o += 'WARN WinRM antwortet nicht' }
        $o
    } -ArgumentList @($c) -TimeoutSec 60 -OnComplete { param($r) Write-HMToolResult $r }
}

# ============================================================================
# FERNWARTUNG AKTIVIEREN (wie AdminTool "Alles aktivieren"): WinRM, RDP (NLA), SMB/C$, Remote Registry, Firewall-Gruppen
#   Start ueber WMI/DCOM (Port 135) - funktioniert auch, wenn WinRM noch aus ist. Danach automatische Pruefung.
# ============================================================================
$script:HMEnableAllClientScript = @'
$log = Join-Path $env:SystemRoot 'Temp\HUMig_Fernwartung.log'
function L([string]$m) { "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $m" | Add-Content -Path $log -Encoding UTF8 }
"$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') === HUMig: Fernwartung aktivieren ===" | Set-Content -Path $log -Encoding UTF8
try { Enable-PSRemoting -Force -SkipNetworkProfileCheck -ErrorAction Stop | Out-Null; L 'OK WinRM: Enable-PSRemoting' } catch { L "FEHLER WinRM: $($_.Exception.Message)" }
try { Set-Service WinRM -StartupType Automatic -ErrorAction Stop; Start-Service WinRM -ErrorAction Stop; L 'OK WinRM-Dienst: Automatisch + gestartet' } catch { L "FEHLER WinRM-Dienst: $($_.Exception.Message)" }
try {
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0 -Type DWord -Force -ErrorAction Stop
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name UserAuthentication -Value 1 -Type DWord -Force -ErrorAction Stop
    Set-Service TermService -StartupType Manual -ErrorAction SilentlyContinue
    Start-Service TermService -ErrorAction SilentlyContinue
    L 'OK RDP: aktiviert (NLA an)'
} catch { L "FEHLER RDP: $($_.Exception.Message)" }
try {
    Set-Service LanmanServer -StartupType Automatic -ErrorAction Stop; Start-Service LanmanServer -ErrorAction SilentlyContinue
    $p = 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters'
    $v = (Get-ItemProperty $p -Name AutoShareWks -ErrorAction SilentlyContinue).AutoShareWks
    if ($null -ne $v -and $v -eq 0) { Set-ItemProperty $p -Name AutoShareWks -Value 1 -Type DWord -Force; Restart-Service LanmanServer -Force -ErrorAction SilentlyContinue; L 'OK AutoShareWks=1 gesetzt' }
    L 'OK SMB: LanmanServer Automatisch + gestartet'
} catch { L "FEHLER SMB: $($_.Exception.Message)" }
try { Set-Service RemoteRegistry -StartupType Automatic -ErrorAction Stop; Start-Service RemoteRegistry -ErrorAction SilentlyContinue; L 'OK RemoteRegistry: Automatisch + gestartet' } catch { L "FEHLER RemoteRegistry: $($_.Exception.Message)" }
$groups = [ordered]@{
    '@FirewallAPI.dll,-30267' = 'Windows-Remoteverwaltung (WinRM)'
    '@FirewallAPI.dll,-28752' = 'Remotedesktop'
    '@FirewallAPI.dll,-28502' = 'Datei- und Druckerfreigabe (SMB, Ping)'
    '@FirewallAPI.dll,-34251' = 'Windows-Verwaltungsinstrumentation (WMI)'
    '@FirewallAPI.dll,-29502' = 'Remotedienstverwaltung'
    '@FirewallAPI.dll,-29252' = 'Remote-Ereignisprotokollverwaltung'
}
foreach ($g in $groups.Keys) {
    # Nur Domaenen-/Privat-Profil: reine Public-Regeln bleiben aus (Notebooks in fremden Netzen)
    $r = @(Get-NetFirewallRule -Group $g -ErrorAction SilentlyContinue | Where-Object { "$($_.Profile)" -ne 'Public' })
    if ($r.Count -gt 0) { $r | Enable-NetFirewallRule -ErrorAction SilentlyContinue; L "OK Firewall: $($groups[$g]) ($($r.Count) Regeln, Domaene/Privat)" }
    else { L "WARN Firewall: Gruppe $($groups[$g]) nicht vorhanden" }
}
if (-not (Get-NetFirewallRule -Group '@FirewallAPI.dll,-28752' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name 'HUMig_RDP_In' -DisplayName 'HUMig RDP-In-TCP' -Direction Inbound -Protocol TCP -LocalPort 3389 -Action Allow -Profile Domain,Private -ErrorAction SilentlyContinue | Out-Null
    L 'OK Firewall: Ersatzregel RDP 3389'
}
if (-not (Get-NetFirewallRule -Group '@FirewallAPI.dll,-28502' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name 'HUMig_SMB_In' -DisplayName 'HUMig SMB-In' -Direction Inbound -Protocol TCP -LocalPort 445 -Action Allow -Profile Domain,Private -ErrorAction SilentlyContinue | Out-Null
    New-NetFirewallRule -Name 'HUMig_ICMPv4_In' -DisplayName 'HUMig ICMPv4-In' -Direction Inbound -Protocol ICMPv4 -IcmpType 8 -Action Allow -Profile Domain,Private -ErrorAction SilentlyContinue | Out-Null
    L 'OK Firewall: Ersatzregeln SMB 445 + Ping'
}
L '=== Ende ==='
'@
$script:RS_EnableAllJob = {
    param($h, $inner, $cred)
    $out = @()
    $isLocal = ($h -eq '.' -or $h -ieq 'localhost' -or $h -ieq $env:COMPUTERNAME -or $h -ilike "$($env:COMPUTERNAME).*")
    if ($isLocal) {
        try { & ([scriptblock]::Create($inner)); Get-Content (Join-Path $env:SystemRoot 'Temp\HUMig_Fernwartung.log') | ForEach-Object { "$_" -replace '^\S+ \S+ ', '' } } catch { "FEHLER: $($_.Exception.Message)" }
        return
    }
    $cs = $null
    try {
        $b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($inner))
        $cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand $b64"
        $sp = @{ ComputerName = $h; SessionOption = (New-CimSessionOption -Protocol Dcom); ErrorAction = 'Stop' }
        if ($cred) { $sp.Credential = $cred }
        $cs = New-CimSession @sp
        $res = Invoke-CimMethod -CimSession $cs -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmd } -ErrorAction Stop
        if ($res.ReturnValue -ne 0) { return "FEHLER: WMI Win32_Process.Create ReturnValue=$($res.ReturnValue)" }
        $out += "OK Aktivierung gestartet (WMI, PID $($res.ProcessId)) - warte auf Abschluss ..."
    } catch { return "FEHLER: WMI/DCOM (Port 135) nicht erreichbar oder kein Zugriff ($($_.Exception.Message)). Dann nur per GPO oder direkt am PC." }
    finally { if ($cs) { Remove-CimSession $cs -ErrorAction SilentlyContinue } }
    # Pruefung: bis zu 60 s auf WinRM warten, dann Ports + Protokoll am Ziel
    $deadline = (Get-Date).AddSeconds(60)
    do {
        Start-Sleep -Seconds 5
        $tcp = New-Object System.Net.Sockets.TcpClient
        try { $w = $tcp.ConnectAsync($h, 5985).Wait(1000) -and $tcp.Connected } catch { $w = $false } finally { $tcp.Dispose() }
    } while (-not $w -and (Get-Date) -lt $deadline)
    Start-Sleep -Seconds 5
    foreach ($svc in @(@('WinRM (5985)', 5985), @('SMB/C$ (445)', 445), @('RDP (3389)', 3389))) {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $open = $false
        try { $open = $tcp.ConnectAsync($h, $svc[1]).Wait(1500) -and $tcp.Connected } catch { } finally { $tcp.Dispose() }
        $out += $(if ($open) { "OK Pruefung $($svc[0]): offen" } else { "WARN Pruefung $($svc[0]): nicht erreichbar" })
    }
    try {
        $p = @{ ComputerName = $h; ErrorAction = 'Stop'; ScriptBlock = {
            $f = Join-Path $env:SystemRoot 'Temp\HUMig_Fernwartung.log'
            $until = (Get-Date).AddSeconds(30)
            do { $c = @(Get-Content $f -ErrorAction SilentlyContinue); if (($c -join "`n") -match '=== Ende ===') { break }; Start-Sleep -Seconds 2 } while ((Get-Date) -lt $until)
            $c
        } }
        if ($cred) { $p.Credential = $cred }
        $log = Invoke-Command @p
        $out += 'INFO Protokoll am Ziel-PC (C:\Windows\Temp\HUMig_Fernwartung.log):'
        foreach ($l in @($log)) { $t = "$l" -replace '^\S+ \S+ ', ''; if ($t -match '^(OK|FEHLER|WARN)') { $out += $t } else { $out += "INFO $t" } }
    } catch { $out += 'WARN Protokoll nicht lesbar (WinRM noch nicht bereit?) - in einer Minute erneut Verbinden' }
    $out
}
function Start-HMEnableRemote {
    $c = Get-TargetComputer
    if (-not (Confirm-Action "Am PC $c alles fuer die Fernwartung aktivieren?`n`n  - WinRM / PowerShell-Remoting`n  - Remotedesktop (mit NLA)`n  - SMB + Admin-Freigabe C$`n  - Remoteregistrierung`n  - Firewall: Datei/Drucker (inkl. Ping), WMI, Dienst- und Ereignisprotokoll-Verwaltung (nur Domaene/Privat)`n`nStart ueber WMI/DCOM (Port 135), danach automatische Pruefung (ca. 1 Minute).`n`nFortfahren?" 'Fernwartung aktivieren')) { return }
    Out-Console "Fernwartung aktivieren - $c (ueber WMI) ..." 'Info'
    Invoke-AsyncCommand -ScriptBlock $script:RS_EnableAllJob -ArgumentList @($c, $script:HMEnableAllClientScript, $script:RemoteCred) -TimeoutSec 240 -State $c -OnComplete {
        param($r, $comp)
        if ("$r" -match '^FEHLER' -and -not ($r -is [System.Array])) { Out-Console (Format-RemoteError "$r") 'Error'; return }
        Write-HMToolResult $r
        Out-Console "Fertig - jetzt 'Verbinden' fuer $comp" 'Info'
    }
}
