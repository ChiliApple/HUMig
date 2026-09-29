#Requires -Version 5.1
<#
.SYNOPSIS
    Geraete aus dem AD laden (Auswahl mit Filter/OU), Mehrfachauswahl mit Aktionen auf vielen PCs parallel,
    Remote-PowerShell/-CMD, Uebermittlungsoptimierung, Ordnerfreigaben (mit Rechten, Uebernahme aus Backup),
    USMT aus dem Windows ADK einrichten.
.NOTES
    Wird im UI-Thread geladen (dot-source aus HUMig.ps1).
#>

# ----------------------------------------------------------------------------
# AD-Computer laden (ohne RSAT: ADSI DirectorySearcher) - Ergebnis wird fuer die Sitzung zwischengespeichert
# ----------------------------------------------------------------------------
$script:ADComputers = $null
$script:MultiHosts = @()
$script:RS_ADComputers = {
    param([string]$Server, $Cred)
    try {
        $ds = New-Object System.DirectoryServices.DirectorySearcher
        if ($Server) {
            # Domaene/DC angegeben (z.B. PC nicht in der Domaene, ueber VPN): LDAP://<Domaene oder DC>, optional mit Anmeldedaten
            $root = if ($Cred) { New-Object System.DirectoryServices.DirectoryEntry("LDAP://$Server", $Cred.UserName, $Cred.GetNetworkCredential().Password) } else { New-Object System.DirectoryServices.DirectoryEntry("LDAP://$Server") }
            $ds.SearchRoot = $root
        }
        $ds.Filter = '(&(objectCategory=computer)(!(userAccountControl:1.2.840.113556.1.4.803:=2)))'
        $ds.PageSize = 1000
        foreach ($p in 'name', 'distinguishedName', 'operatingSystem', 'operatingSystemVersion', 'lastLogonTimestamp', 'description') { [void]$ds.PropertiesToLoad.Add($p) }
        $all = $ds.FindAll()
        foreach ($r in $all) {
            $pr = $r.Properties
            $dn = "$($pr['distinguishedname'][0])"
            $ou = @(([regex]::Matches($dn, '(?:OU|CN)=((?:\\.|[^,])+)') | Select-Object -Skip 1 | ForEach-Object { $_.Groups[1].Value -replace '\\(.)', '$1' }))
            [array]::Reverse($ou)
            $ll = $null; if ($pr['lastlogontimestamp'].Count) { try { $ll = [datetime]::FromFileTime([long]$pr['lastlogontimestamp'][0]) } catch { } }
            [pscustomobject]@{ Name = "$($pr['name'][0])"; OU = ($ou -join '\'); OS = "$($pr['operatingsystem'][0]) $($pr['operatingsystemversion'][0])".Trim(); Last = $ll; Desc = "$($pr['description'][0])" }
        }
        $all.Dispose()
    } catch { "FEHLER: $($_.Exception.Message)" }
}
$script:ADLoaded = $false
$script:ADError = ''
function Start-HMADLoad([scriptblock]$Then, [switch]$Force) {
    if ($script:ADLoaded -and -not $Force) { & $Then; return }
    $srv = "$($script:Settings.ADServer)".Trim()
    $cred = $script:RemoteCred
    if ($srv -and -not $cred) {
        $inDomain = $true
        try { $inDomain = [bool](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).PartOfDomain } catch { }
        if (-not $inDomain) {
            $cred = Get-Credential -Message "Anmeldedaten fuer das AD ($srv), z.B. DOMAENE\Administrator - gilt auch fuer Remote-Zugriffe dieser Sitzung"
            if (-not $cred) { $script:ADComputers = @(); $script:ADLoaded = $true; $script:ADError = 'keine Anmeldedaten'; & $Then; return }
            $script:RemoteCred = $cred
        }
    }
    Out-Console "Computer aus dem Active Directory laden$(if ($srv) { " ($srv)" }) ..." 'Info'
    $script:ADThen = $Then
    Invoke-AsyncCommand -ScriptBlock $script:RS_ADComputers -ArgumentList @($srv, $cred) -TimeoutSec 180 -OnComplete {
        param($r)
        $script:ADLoaded = $true; $script:ADError = ''
        if ("$r" -match '^FEHLER' -and -not ($r -is [System.Array])) {
            $script:ADError = ("$r" -replace '^FEHLER:\s*', '' -replace '^.*?"(.+)"\s*$', '$1').Trim()
            Out-Console "AD nicht lesbar: $($script:ADError) - im Dialog oben 'Domaene/DC' eintragen (z.B. schule.local oder IP des Domaenen-Controllers) und 'Laden'. Namen koennen auch unten eingetragen werden." 'Warning'
            $script:ADComputers = @()
        }
        else { $script:ADComputers = @($r | Where-Object { $_ -and $_.Name } | Sort-Object Name); Out-Console "$($script:ADComputers.Count) Computer aus dem AD geladen" 'Success' }
        if ($script:ADThen) { $t = $script:ADThen; $script:ADThen = $null; & $t }
    }
}

# ----------------------------------------------------------------------------
# Auswahl-Dialog: PCs anhaken (Filter, OU, eigene Namen) + Aktion. Doppelklick = als Computer oben uebernehmen
# ----------------------------------------------------------------------------
$script:HMMultiActions = @(
    [pscustomobject]@{ Key = 'online';    Text = 'Online-Check';                         Desc = 'Ping + WinRM (Port 5985) aller gewaehlten PCs, IP-Adresse.' }
    [pscustomobject]@{ Key = 'enable';    Text = 'Fernwartung aktivieren';               Desc = 'WinRM, RDP, SMB/C$, Remoteregistrierung, Firewall - ueber WMI (auch wenn WinRM noch aus ist).' }
    [pscustomobject]@{ Key = 'inventory'; Text = 'Inventar (CSV)';                       Desc = 'Hardware, Windows, BitLocker, TPM, IP/MAC - Tabelle + CSV im Backup-Ordner\Inventar.' }
    [pscustomobject]@{ Key = 'invsw';     Text = 'Inventar + Software (CSV)';            Desc = 'Wie Inventar, zusaetzlich installierte Programme je PC.' }
    [pscustomobject]@{ Key = 'autopilot'; Text = 'Autopilot-Hash (eine CSV)';            Desc = 'Hardware-Hashes aller PCs in EINER CSV fuer den Intune-Import (Backup-Ordner\Autopilot).' }
    [pscustomobject]@{ Key = 'doopt';     Text = 'Uebermittlungsoptimierung setzen';     Desc = 'Delivery Optimization: Peer-Modus (LAN/Gruppe) per lokaler Richtlinie - Updates werden zwischen den PCs geteilt.' }
    [pscustomobject]@{ Key = 'cleanup';   Text = 'Speicher aufraeumen';                  Desc = 'Temp, Update-Cache, Fehlerberichte - optional Windows.old und Papierkorb.' }
    [pscustomobject]@{ Key = 'software';  Text = 'Software verteilen';                   Desc = 'Paket aus der Softwareverteilung installieren (bis 8 PCs gleichzeitig).' }
    [pscustomobject]@{ Key = 'drivers';   Text = 'Treiber verteilen';                    Desc = 'Treiber aus der Treiberverteilung installieren (INF/Setup, Hardware-Pruefung, bis 8 PCs gleichzeitig).' }
    [pscustomobject]@{ Key = 'gpupdate';  Text = 'GPUpdate /force';                      Desc = 'Gruppenrichtlinien aktualisieren (Computer + Benutzer).' }
    [pscustomobject]@{ Key = 'intune';    Text = 'Intune-Synchronisierung';              Desc = 'MDM-Sync anstossen (geplante Aufgabe EnterpriseMgmt) + Intune Management Extension neu starten.' }
    [pscustomobject]@{ Key = 'message';   Text = 'Nachricht senden';                     Desc = 'Text an alle angemeldeten Benutzer.' }
    [pscustomobject]@{ Key = 'restart';   Text = 'Neustart (in 2 min)';                  Desc = 'Neustart mit 120 Sekunden Vorwarnung.' }
)
# -OnPick: nur PCs auswaehlen (ohne Aktionsliste), Rueckgabe an den Aufrufer: & $OnPick <string[]>
function Show-HMMultiDialog([scriptblock]$OnPick = $null, [string]$PickTitle = '', $Owner = $null) {
    if ($script:MultiDlg -and $script:MultiDlg.W) { try { $script:MultiDlg.W.Close() } catch { } }
    $script:MultiPick = if ($OnPick) { @{ On = $OnPick; Title = $PickTitle; Owner = $Owner } } else { $null }
    Start-HMADLoad { Show-HMMultiDialogCore }
}
function Show-HMMultiDialogCore {
    $mx = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Geraete (AD) - Auswahl und Aktionen" Height="680" Width="1060" MinHeight="420" MinWidth="700" WindowStartupLocation="CenterOwner" Background="#FF1E1E2E">
  <DockPanel Margin="8">
    <DockPanel DockPanel.Dock="Bottom" Margin="0,8,0,0">
      <TextBlock x:Name="lblCount" Foreground="#FFA6ADC8" VerticalAlignment="Center"/>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
        <Button x:Name="btnTake" Content="Als Computer uebernehmen" Width="190" Height="28" Background="#FF89B4FA" Foreground="#FF1E1E2E" FontWeight="SemiBold" Margin="0,0,6,0" ToolTip="Markierten PC oben eintragen und verbinden (auch Doppelklick)"/>
        <Button x:Name="btnOk" Content="Aktion ausfuehren" Width="150" Height="28" Background="#FFA6E3A1" Foreground="#FF1E1E2E" FontWeight="SemiBold" Margin="0,0,6,0"/>
        <Button x:Name="btnCancel" Content="Schliessen" Width="100" Height="28" Background="#FF45475A" Foreground="#FFCDD6F4" IsCancel="True"/>
      </StackPanel>
    </DockPanel>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="2*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <DockPanel Grid.Column="0" Margin="0,0,8,0">
        <DockPanel DockPanel.Dock="Top" Margin="0,0,0,4">
          <TextBlock Text="Domaene/DC:" Foreground="#FFA6ADC8" VerticalAlignment="Center" Margin="0,0,6,0"/>
          <TextBox x:Name="txtDC" Width="150" Background="#FF313244" Foreground="#FFCDD6F4" BorderBrush="#FF585B70" CaretBrush="#FFCDD6F4" Padding="4,2" Margin="0,0,4,0" ToolTip="Leer = Domaene dieses PCs. Sonst Domaenenname (schule.local) oder Name/IP eines Domaenen-Controllers - z.B. ueber VPN von einem PC ausserhalb der Domaene (fragt nach Anmeldedaten)"/>
          <Button x:Name="btnLoadAD" Content="Laden" Width="60" Background="#FF89B4FA" Foreground="#FF1E1E2E" Margin="0,0,10,0"/>
          <TextBlock Text="OU:" Foreground="#FFA6ADC8" VerticalAlignment="Center" Margin="0,0,6,0"/>
          <ComboBox x:Name="cmbOU" Width="240" Margin="0,0,8,0"/>
          <TextBlock Text="Filter:" Foreground="#FFA6ADC8" VerticalAlignment="Center" Margin="0,0,6,0"/>
          <TextBox x:Name="txtFilter" Background="#FF313244" Foreground="#FFCDD6F4" BorderBrush="#FF585B70" CaretBrush="#FFCDD6F4" Padding="4,2" ToolTip="Name, OU, Windows-Version, Beschreibung"/>
        </DockPanel>
        <DockPanel DockPanel.Dock="Bottom" Margin="0,4,0,0">
          <Button x:Name="btnAdd" DockPanel.Dock="Right" Content="Hinzufuegen" Width="90" Background="#FF89B4FA" Foreground="#FF1E1E2E" Margin="4,0,0,0"/>
          <Button x:Name="btnNone" DockPanel.Dock="Left" Content="Keine" Width="60" Background="#FF45475A" Foreground="#FFCDD6F4" Margin="0,0,4,0"/>
          <Button x:Name="btnAll" DockPanel.Dock="Left" Content="Alle sichtbaren" Width="110" Background="#FF45475A" Foreground="#FFCDD6F4" Margin="0,0,4,0"/>
          <TextBox x:Name="txtAdd" Background="#FF313244" Foreground="#FFCDD6F4" BorderBrush="#FF585B70" CaretBrush="#FFCDD6F4" Padding="4,2" ToolTip="Weitere PCs (nicht im AD): Namen/IPs mit Komma oder Leerzeichen"/>
        </DockPanel>
        <DataGrid x:Name="dg" AutoGenerateColumns="False" CanUserAddRows="False" HeadersVisibility="Column" SelectionMode="Extended" SelectionUnit="FullRow"
                  Background="#FF313244" Foreground="#FFCDD6F4" RowBackground="#FF313244" AlternatingRowBackground="#FF45475A" GridLinesVisibility="None" BorderBrush="#FF585B70">
          <DataGrid.ColumnHeaderStyle><Style TargetType="DataGridColumnHeader"><Setter Property="Background" Value="#FF181825"/><Setter Property="Foreground" Value="#FFCDD6F4"/><Setter Property="Padding" Value="6,3"/></Style></DataGrid.ColumnHeaderStyle>
          <DataGrid.Columns>
            <DataGridTemplateColumn Header="X" Width="32"><DataGridTemplateColumn.CellTemplate><DataTemplate><CheckBox IsChecked="{Binding Sel, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" HorizontalAlignment="Center" VerticalAlignment="Center"/></DataTemplate></DataGridTemplateColumn.CellTemplate></DataGridTemplateColumn>
            <DataGridTextColumn Header="Computer" Binding="{Binding Name}" IsReadOnly="True" Width="Auto"/>
            <DataGridTextColumn Header="OU" Binding="{Binding OU}" IsReadOnly="True" Width="Auto"/>
            <DataGridTextColumn Header="Windows" Binding="{Binding OS}" IsReadOnly="True" Width="Auto"/>
            <DataGridTextColumn Header="Zuletzt im AD" Binding="{Binding Last, StringFormat=dd.MM.yyyy}" IsReadOnly="True" Width="Auto"/>
          </DataGrid.Columns>
        </DataGrid>
      </DockPanel>
      <DockPanel x:Name="pnlAct" Grid.Column="1">
        <TextBlock DockPanel.Dock="Top" Text="Aktion fuer die angehakten PCs:" Foreground="#FFA6ADC8" Margin="0,0,0,4"/>
        <TextBlock x:Name="lblDesc" DockPanel.Dock="Bottom" Foreground="#FFF9E2AF" TextWrapping="Wrap" Margin="0,6,0,0" MinHeight="48"/>
        <ListBox x:Name="lstA" Background="#FF313244" Foreground="#FFCDD6F4" BorderBrush="#FF585B70" FontSize="13"/>
      </DockPanel>
    </Grid>
  </DockPanel>
</Window>
"@
    $w = [System.Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new(([xml]$mx)))
    if ($script:AppIcon) { $w.Icon = $script:AppIcon }
    $pk = $script:MultiPick
    $w.Owner = $(if ($pk -and $pk.Owner) { $pk.Owner } else { $script:Window }); Set-HMWindowScale $w
    if ($pk) {
        $w.Title = "PCs auswaehlen$(if ($pk.Title) { " - $($pk.Title)" })"
        $w.FindName('pnlAct').Visibility = 'Collapsed'
        $w.FindName('pnlAct').Parent.ColumnDefinitions[1].Width = [System.Windows.GridLength]::new(0)
        $w.FindName('btnTake').Visibility = 'Collapsed'
        $w.FindName('btnOk').Content = 'PCs uebernehmen'
    }
    $dt = New-Object System.Data.DataTable
    [void]$dt.Columns.Add('Sel', [bool]); [void]$dt.Columns.Add('Name', [string]); [void]$dt.Columns.Add('OU', [string]); [void]$dt.Columns.Add('OS', [string]); [void]$dt.Columns.Add('Last', [datetime]); [void]$dt.Columns.Add('Desc', [string])
    $pre = @{}; foreach ($h in @($script:MultiHosts)) { $pre["$h".ToUpper()] = $true }
    foreach ($c in @($script:ADComputers)) {
        $r = $dt.NewRow(); $r.Sel = $pre.ContainsKey($c.Name.ToUpper()); $r.Name = $c.Name; $r.OU = $c.OU; $r.OS = $c.OS; $r.Desc = $c.Desc
        if ($c.Last) { $r.Last = [datetime]$c.Last } else { $r.Last = [System.DBNull]::Value }
        $dt.Rows.Add($r)
    }
    foreach ($h in @($script:MultiHosts)) { if (-not @($script:ADComputers | Where-Object { $_.Name -ieq $h }).Count) { $r = $dt.NewRow(); $r.Sel = $true; $r.Name = $h; $r.OU = '(manuell)'; $dt.Rows.Add($r) } }
    $dv = $dt.DefaultView; $dv.Sort = 'OU ASC, Name ASC'
    $dg = $w.FindName('dg'); $dg.ItemsSource = $dv
    $cmb = $w.FindName('cmbOU')
    [void]$cmb.Items.Add('(alle)')
    foreach ($o in @($script:ADComputers | ForEach-Object { $_.OU } | Sort-Object -Unique)) { [void]$cmb.Items.Add($o) }
    $cmb.SelectedIndex = 0
    $lst = $w.FindName('lstA'); foreach ($a in $script:HMMultiActions) { [void]$lst.Items.Add($a.Text) }
    $st = @{ W = $w; Dt = $dt; Dv = $dv; Dg = $dg; Cmb = $cmb; Txt = $w.FindName('txtFilter'); Lbl = $w.FindName('lblCount'); Lst = $lst; Desc = $w.FindName('lblDesc'); Add = $w.FindName('txtAdd') }
    $script:MultiDlg = $st
    $apply = {
        $s = $script:MultiDlg
        $parts = @()
        $ou = "$($s.Cmb.SelectedItem)"
        if ($ou -and $ou -ne '(alle)') { $parts += "(OU = '$($ou -replace "'", "''")' OR OU LIKE '$(($ou -replace "'", "''") -replace '([\[\]\*%])', '[$1]')\*')" }
        $t = "$($s.Txt.Text)".Trim()
        if ($t) { $e = ($t -replace "'", "''") -replace '([\[\]\*%])', '[$1]'; $parts += "(Name LIKE '*$e*' OR OU LIKE '*$e*' OR OS LIKE '*$e*' OR Desc LIKE '*$e*')" }
        try { $s.Dv.RowFilter = ($parts -join ' AND ') } catch { $s.Dv.RowFilter = '' }
        & $script:MultiDlgCount
    }
    $script:MultiDlgApply = $apply
    $script:MultiDlgCount = { $s = $script:MultiDlg; $n = @($s.Dt.Rows | Where-Object { $_.Sel -eq $true }).Count; $s.Lbl.Text = "$n angehakt  |  $($s.Dv.Count) von $($s.Dt.Rows.Count) sichtbar" }
    & $apply
    if ($script:ADError) { $st.Lbl.Text = "AD nicht lesbar: $($script:ADError) - oben Domaene/DC eintragen und 'Laden', oder Namen unten eintragen" }
    $cmb.Add_SelectionChanged({ & $script:MultiDlgApply })
    $st.Txt.Add_TextChanged({ & $script:MultiDlgApply })
    $dt.Add_ColumnChanged({ if ($script:MultiDlg) { & $script:MultiDlgCount } })
    $dg.Add_PreviewKeyDown({ param($s, $e) if ($e.Key -eq 'Space') { foreach ($rv in @($script:MultiDlg.Dg.SelectedItems)) { $rv.Row.Sel = -not ($rv.Row.Sel -eq $true) }; $e.Handled = $true; & $script:MultiDlgCount } })
    $lst.Add_SelectionChanged({ $s = $script:MultiDlg; $i = $s.Lst.SelectedIndex; $s.Desc.Text = if ($i -ge 0) { $script:HMMultiActions[$i].Desc } else { '' } })
    $w.FindName('btnAll').Add_Click({ foreach ($rv in @($script:MultiDlg.Dv)) { $rv.Row.Sel = $true }; & $script:MultiDlgCount })
    $w.FindName('btnNone').Add_Click({ foreach ($r in @($script:MultiDlg.Dt.Rows)) { $r.Sel = $false }; & $script:MultiDlgCount })
    $w.FindName('txtDC').Text = "$($script:Settings.ADServer)"
    $w.FindName('btnLoadAD').Add_Click({
        $s = $script:MultiDlg
        $v = "$($s.W.FindName('txtDC').Text)".Trim()
        if ($v -ne "$($script:Settings.ADServer)".Trim()) { Set-SiteSetting 'ADServer' $v }
        $s.W.Close()
        Start-HMADLoad { Show-HMMultiDialogCore } -Force
    })
    $w.FindName('btnCancel').Add_Click({ $script:MultiDlg.W.Close() })
    $w.FindName('btnAdd').Add_Click({
        $s = $script:MultiDlg
        foreach ($n in @("$($s.Add.Text)" -split '[,;\s]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^[A-Za-z0-9][A-Za-z0-9\.\-_]*$' })) {
            $ex = @($s.Dt.Rows | Where-Object { "$($_.Name)" -ieq $n })
            if ($ex.Count) { $ex[0].Sel = $true } else { $r = $s.Dt.NewRow(); $r.Sel = $true; $r.Name = $n; $r.OU = '(manuell)'; $s.Dt.Rows.Add($r) }
        }
        $s.Add.Text = ''; & $script:MultiDlgCount
    })
    $take = {
        if ($script:MultiPick) { return }
        $s = $script:MultiDlg
        $rv = $s.Dg.SelectedItem
        if (-not $rv) { return }
        $ui.cmbComputer.Text = "$($rv.Row.Name)"
        $s.W.Close()
        Connect-Target
    }
    $script:MultiDlgTake = $take
    $w.FindName('btnTake').Add_Click({ & $script:MultiDlgTake })
    $dg.Add_MouseDoubleClick({ param($s, $e) if ($e.OriginalSource -is [System.Windows.Controls.CheckBox] -or ($e.OriginalSource.TemplatedParent -is [System.Windows.Controls.CheckBox])) { return }; & $script:MultiDlgTake })
    $w.FindName('btnOk').Add_Click({
        $s = $script:MultiDlg
        $s.Dg.CommitEdit(); $s.Dg.CommitEdit()
        $hosts = @($s.Dt.Rows | Where-Object { $_.Sel -eq $true } | ForEach-Object { "$($_.Name)" })
        if (-not $hosts.Count) { [void][System.Windows.MessageBox]::Show($s.W, 'Bitte PCs anhaken (Spalte X, Leertaste fuer markierte Zeilen).', 'Aktion', 'OK', 'Information'); return }
        if ($script:MultiPick) {
            $script:MultiHosts = $hosts
            $on = $script:MultiPick.On; $script:MultiPick = $null
            $s.W.Close()
            & $on $hosts
            return
        }
        if ($s.Lst.SelectedIndex -lt 0) { [void][System.Windows.MessageBox]::Show($s.W, 'Bitte rechts eine Aktion waehlen.', 'Aktion', 'OK', 'Information'); return }
        $script:MultiHosts = $hosts
        $act = $script:HMMultiActions[$s.Lst.SelectedIndex]
        Invoke-HMMultiAction $hosts $act.Key $act.Text $s.W
    })
    $w.Add_Closed({ $script:MultiDlg = $null })
    $w.Show()
}

# ----------------------------------------------------------------------------
# Aktionen auf vielen PCs
# ----------------------------------------------------------------------------
function Invoke-HMMultiAction([string[]]$Hosts, [string]$Key, [string]$Text, $Owner) {
    $n = $Hosts.Count
    $list = (($Hosts | Select-Object -First 25) -join ', ') + $(if ($n -gt 25) { ', ...' } else { '' })
    switch ($Key) {
        'online' { Start-HMOnlineCheck $Hosts; return }
        'inventory' { Start-HMInventory $false $Hosts; return }
        'invsw' { Start-HMInventory $true $Hosts; return }
        'autopilot' { Start-HMAutopilotMulti $Hosts; return }
        'doopt' { Start-HMDeliveryOpt $Hosts; return }
        'cleanup' { Start-HMCleanup $Hosts; return }
        'software' {
            $pk = @(Get-SwPackages)
            if (-not $pk.Count) { Out-Console 'Keine Pakete in der Softwareverteilung.' 'Warning'; return }
            $f = Show-HMFormDialog -Title "Software verteilen - $n PC(s)" -OkText 'Installieren' -Fields @(
                @{ Name = 'P'; Label = 'Paket:'; Type = 'Combo'; Items = @($pk | ForEach-Object { "$($_.Settings.Name)  [$($_.Id)]" }) }
                @{ Name = 'Force'; Label = 'Auch installieren, wenn schon vorhanden'; Type = 'Check' }
            )
            if (-not $f) { return }
            $p = @($pk | Where-Object { "$($_.Settings.Name)  [$($_.Id)]" -eq $f.P })[0]
            if ($p -and (Confirm-SwDeploy $p $Hosts ([bool]$f.Force))) { Start-SoftwareDeploy -Hosts $Hosts -Package $p -Force ([bool]$f.Force) -Label 'Mehrfachauswahl' }
            return
        }
        'drivers' {
            $pk = @(Get-DrvPackages)
            if (-not $pk.Count) { Out-Console 'Keine Pakete in der Treiberverteilung.' 'Warning'; return }
            $f = Show-HMFormDialog -Title "Treiber verteilen - $n PC(s)" -OkText 'Installieren' -Fields @(
                @{ Name = 'P'; Label = 'Treiber:'; Type = 'Combo'; Items = @($pk | ForEach-Object { "$($_.Settings.Name)  [$($_.Id)]" }) }
                @{ Name = 'Force'; Label = 'Auch installieren, wenn diese Version schon aktiv ist'; Type = 'Check' }
                @{ Type = 'Info'; Label = 'Einstellungen (Art, Erzwingen, nur passende Hardware) aus dem Fenster Treiberverteilung.' }
            )
            if (-not $f) { return }
            $p = @($pk | Where-Object { "$($_.Settings.Name)  [$($_.Id)]" -eq $f.P })[0]
            if ($p -and (Confirm-DrvDeploy $p $Hosts ([bool]$f.Force))) { Start-DriverDeploy -Hosts $Hosts -Package $p -Force ([bool]$f.Force) -Label 'Mehrfachauswahl' }
            return
        }
        'enable' {
            if (-not (Confirm-Action "Fernwartung auf $n PC(s) aktivieren (WinRM, RDP, C$, Remoteregistrierung, Firewall)?`n`n$list" 'Fernwartung aktivieren')) { return }
            Start-HMEnableRemoteMulti $Hosts; return
        }
        'gpupdate' {
            if (-not (Confirm-Action "GPUpdate /force auf $n PC(s)?`n`n$list")) { return }
            Invoke-HMMultiRemote -Hosts $Hosts -Title 'GPUpdate' -Script { $o = cmd.exe /c 'echo n | gpupdate /force' 2>&1 | Out-String; if ($LASTEXITCODE -eq 0) { 'OK gpupdate' } else { "WARN gpupdate Code $LASTEXITCODE : $(($o -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 1))" } }
        }
        'intune' {
            Invoke-HMMultiRemote -Hosts $Hosts -Title 'Intune-Sync' -Script {
                $t = @(Get-ScheduledTask -TaskPath '\Microsoft\Windows\EnterpriseMgmt\*' -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like '*PushLaunch*' -or $_.TaskName -like '*Schedule #3*' })
                foreach ($x in $t) { try { Start-ScheduledTask -TaskPath $x.TaskPath -TaskName $x.TaskName } catch { } }
                $ime = Get-Service IntuneManagementExtension -ErrorAction SilentlyContinue
                if ($ime) { Restart-Service IntuneManagementExtension -Force -ErrorAction SilentlyContinue }
                if ($t.Count) { "OK MDM-Sync angestossen ($($t.Count) Aufgaben)$(if ($ime) { ', IME neu gestartet' })" } else { 'WARN keine MDM-Registrierung gefunden' }
            }
        }
        'message' {
            $f = Show-HMFormDialog -Title "Nachricht an $n PC(s)" -OkText 'Senden' -Fields @(@{ Name = 'M'; Label = 'Nachricht:'; Type = 'Text'; Default = '' })
            if (-not $f -or -not "$($f.M)".Trim()) { return }
            Invoke-HMMultiRemote -Hosts $Hosts -Title 'Nachricht' -Arguments @("$($f.M)") -Script { param($m) & msg.exe * /TIME:300 $m 2>&1 | Out-Null; if ($LASTEXITCODE -eq 0) { 'OK gesendet' } else { "WARN msg Code $LASTEXITCODE (niemand angemeldet?)" } }
        }
        'restart' {
            if (-not (Confirm-Action "$n PC(s) in 2 Minuten NEU STARTEN?`n`n$list" 'Neustart')) { return }
            Invoke-HMMultiRemote -Hosts $Hosts -Title 'Neustart' -Script { & shutdown.exe /r /t 120 /c 'Wartung: Neustart in 2 Minuten - bitte Dateien speichern.' 2>&1 | Out-Null; if ($LASTEXITCODE -eq 0) { 'OK Neustart in 120 s' } else { "FEHLER shutdown Code $LASTEXITCODE" } }
        }
    }
}

# Skript per Invoke-Command parallel (32) auf vielen PCs, Ergebnis-Tabelle. Ausgabezeilen "OK ...", "WARN ...", "FEHLER ..."
function Invoke-HMMultiRemote {
    param([string[]]$Hosts, [string]$Title, [scriptblock]$Script, [object[]]$Arguments = @(), [int]$TimeoutSec = 900, [scriptblock]$OnRows = $null)
    $Hosts = @($Hosts | Where-Object { $_ } | Sort-Object -Unique)
    if (-not $Hosts.Count) { return }
    Out-Console "$Title auf $($Hosts.Count) PC(s) parallel ..." 'Info'
    $total = [int]($TimeoutSec * [Math]::Ceiling($Hosts.Count / 32.0))
    Invoke-AsyncCommand -ScriptBlock {
        param($hostStr, $sbText, $argsArr, $waitSec, $cred)
        $list = @($hostStr -split '\|' | Where-Object { $_ })
        $out = New-Object System.Collections.Generic.List[string]
        $sb = [scriptblock]::Create($sbText)
        $remote = New-Object System.Collections.Generic.List[string]
        foreach ($h in $list) {
            if ($h -eq '.' -or $h -ieq 'localhost' -or $h -ieq $env:COMPUTERNAME -or $h -ilike "$($env:COMPUTERNAME).*") {
                try { $res = @(& $sb @argsArr); $out.Add("R:$h`t$((@($res | ForEach-Object { "$_" -replace '[\r\n\t]+', ' ' }) -join ' | '))") } catch { $out.Add("R:$h`tFEHLER $($_.Exception.Message)") }
            } else { $remote.Add($h) }
        }
        if ($remote.Count) {
            $p = @{ ComputerName = $remote.ToArray(); ThrottleLimit = 32; SessionOption = (New-PSSessionOption -OpenTimeout 15000); ScriptBlock = $sb; ArgumentList = $argsArr; AsJob = $true }
            if ($cred) { $p.Credential = $cred }
            $job = Invoke-Command @p
            $null = Wait-Job -Job $job -Timeout ([int][Math]::Max(30, $waitSec))
            foreach ($cj in @($job.ChildJobs)) {
                $cn = "$($cj.Location)"
                if ($cj.State -in 'Completed', 'Failed', 'Stopped') {
                    $ev = $null
                    $res = @(Receive-Job -Job $cj -ErrorAction SilentlyContinue -ErrorVariable ev)
                    $lines = @($res | ForEach-Object { "$_" -replace '[\r\n\t]+', ' ' } | Where-Object { $_.Trim() })
                    if (-not $lines.Count) {
                        $msg = if ($cj.JobStateInfo.Reason) { $cj.JobStateInfo.Reason.Message } elseif (@($ev).Count) { "$(@($ev)[0])" } else { '' }
                        if ($msg) { $lines = @("FEHLER $($msg -replace '[\r\n\t]+', ' ')") }
                    }
                    $out.Add("R:$cn`t$($lines -join ' | ')")
                } else { $out.Add("R:$cn`tFEHLER Zeitlimit - keine Antwort (laeuft evtl. weiter)") }
            }
            if ($job.State -in 'Completed', 'Failed', 'Stopped') { try { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } catch { } }
        }
        $out -join "`n"
    } -ArgumentList @(($Hosts -join '|'), $Script.ToString(), $Arguments, ($total - 60), $script:RemoteCred) -TimeoutSec $total -State @{ Title = $Title; Hosts = $Hosts; OnRows = $OnRows } -OnComplete {
        param($result, $st)
        $r = "$result".Trim()
        if ($r -match '^FEHLER:') { Out-Console "$($st.Title): $r" 'Error'; return }
        $rows = New-Object System.Collections.Generic.List[object]
        $seen = @{}
        foreach ($l in ($r -split "`r?`n")) {
            if ($l -notmatch '^R:([^\t]*)\t(.*)$') { continue }
            $h = $Matches[1]; $txt = Format-RemoteError $Matches[2]
            $seen[$h.ToUpper()] = $true
            $stat = if ($txt -match '(^|\| )(FEHLER|ERR)') { 'FEHLER' } elseif ($txt -match '(^|\| )WARN') { 'WARN' } elseif (-not $txt) { 'OK (keine Ausgabe)' } else { 'OK' }
            $rows.Add(@($h, $stat, ($txt -replace '(^|\| )(OK|INFO) ', '$1')))
        }
        foreach ($h in $st.Hosts) { if (-not $seen.ContainsKey($h.ToUpper())) { $rows.Add(@($h, 'FEHLER', 'keine Antwort')) } }
        $ok = @($rows | Where-Object { $_[1] -like 'OK*' }).Count; $bad = @($rows | Where-Object { $_[1] -eq 'FEHLER' }).Count
        Out-Console "$($st.Title): $ok OK / $($rows.Count - $ok - $bad) Warnung / $bad Fehler" $(if ($bad) { 'Warning' } else { 'Success' })
        if ($st.OnRows) { & $st.OnRows $rows }
        Show-DataGridWindow -Title "$($st.Title) - $($rows.Count) PC(s)" -Columns @('Computer', 'Status', 'Ergebnis') -Rows $rows.ToArray() -Sort 'Status ASC, Computer ASC' -CountText "$ok OK / $bad Fehler" -Width 1150 -Height 560
    }
}

# Online-Check (Ping, sonst TCP 5985) parallel
function Start-HMOnlineCheck([string[]]$Hosts) {
    Out-Console "Online-Check: $($Hosts.Count) PC(s) ..." 'Info'
    Invoke-AsyncCommand -ScriptBlock {
        param($list)
        $probe = {
            param($h)
            $ping = $false; $winrm = $false; $ip = ''
            try { $p = New-Object System.Net.NetworkInformation.Ping; $ping = ($p.Send($h, 800).Status -eq 'Success'); $p.Dispose() } catch { }
            try { $t = New-Object System.Net.Sockets.TcpClient; $a = $t.BeginConnect($h, 5985, $null, $null); if ($a.AsyncWaitHandle.WaitOne(900, $false) -and $t.Connected) { $winrm = $true }; $t.Close() } catch { }
            try { $ip = ([System.Net.Dns]::GetHostAddresses($h) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1).IPAddressToString } catch { }
            "$h`t$(if ($ping -or $winrm) { 'Online' } else { 'Offline' })`t$(if ($ping) { 'ja' } else { 'nein' })`t$(if ($winrm) { 'ja' } else { 'nein' })`t$ip"
        }
        $pool = [runspacefactory]::CreateRunspacePool(1, 32); $pool.Open()
        $jobs = foreach ($h in $list) { $ps = [PowerShell]::Create().AddScript($probe).AddArgument($h); $ps.RunspacePool = $pool; [pscustomobject]@{ PS = $ps; H = $ps.BeginInvoke() } }
        $res = foreach ($j in $jobs) { try { $j.PS.EndInvoke($j.H) } catch { } finally { $j.PS.Dispose() } }
        $pool.Close(); $pool.Dispose()
        @($res)
    } -ArgumentList @(, $Hosts) -TimeoutSec 300 -OnComplete {
        param($r)
        $rows = New-Object System.Collections.Generic.List[object]
        foreach ($l in @($r)) { $p = "$l".Split("`t"); if ($p.Count -ge 5) { $rows.Add(@($p[0], $p[1], $p[2], $p[3], $p[4])) } }
        $on = @($rows | Where-Object { $_[1] -eq 'Online' }).Count
        Out-Console "Online-Check: $on von $($rows.Count) erreichbar" 'Success'
        Show-DataGridWindow -Title 'Online-Check' -Columns @('Computer', 'Status', 'Ping', 'WinRM', 'IP') -Rows $rows.ToArray() -Sort 'Status DESC, Computer ASC' -CountText "$on von $($rows.Count) online" -Width 800 -Height 560 -Actions @(
            @{ Text = 'Markierte: Fernwartung aktivieren'; Color = '#FFA6E3A1'; Handler = { param($rows, $win, $ctx) Start-HMEnableRemoteMulti @($rows | ForEach-Object { "$($_.Computer)" }) } }
        )
    }
}

# Fernwartung aktivieren fuer viele PCs (je PC ueber WMI, 16 parallel)
function Start-HMEnableRemoteMulti([string[]]$Hosts) {
    Out-Console "Fernwartung aktivieren: $($Hosts.Count) PC(s) ueber WMI ..." 'Info'
    Invoke-AsyncCommand -ScriptBlock {
        param($list, $jobText, $inner, $cred)
        $pool = [runspacefactory]::CreateRunspacePool(1, 16); $pool.Open()
        $jobs = foreach ($h in $list) { $ps = [PowerShell]::Create().AddScript($jobText).AddArgument($h).AddArgument($inner).AddArgument($cred); $ps.RunspacePool = $pool; [pscustomobject]@{ PS = $ps; H = $ps.BeginInvoke(); Host = $h } }
        $out = foreach ($j in $jobs) {
            $t = ''
            try { $t = (@($j.PS.EndInvoke($j.H)) | ForEach-Object { "$_" }) -join ' | ' } catch { $t = "FEHLER $($_.Exception.Message)" } finally { $j.PS.Dispose() }
            "R:$($j.Host)`t$($t -replace '[\r\n\t]+', ' ')"
        }
        $pool.Close(); $pool.Dispose()
        $out -join "`n"
    } -ArgumentList @($Hosts, $script:RS_EnableAllJob.ToString(), $script:HMEnableAllClientScript, $script:RemoteCred) -TimeoutSec 900 -OnComplete {
        param($r)
        $rows = New-Object System.Collections.Generic.List[object]
        foreach ($l in ("$r" -split "`r?`n")) { if ($l -match '^R:([^\t]*)\t(.*)$') { $t = $Matches[2]; $rows.Add(@($Matches[1], $(if ($t -match 'FEHLER') { 'FEHLER' } elseif ($t -match 'WARN') { 'WARN' } else { 'OK' }), (Format-RemoteError $t))) } }
        Out-Console "Fernwartung aktivieren: $(@($rows | Where-Object { $_[1] -eq 'OK' }).Count) von $($rows.Count) OK" 'Success'
        Show-DataGridWindow -Title 'Fernwartung aktivieren' -Columns @('Computer', 'Status', 'Ergebnis') -Rows $rows.ToArray() -Sort 'Status ASC, Computer ASC' -Width 1200 -Height 560
    }
}

# Autopilot-Hashes vieler PCs in einer CSV
function Start-HMAutopilotMulti([string[]]$Hosts) {
    $f = Show-HMFormDialog -Title "Autopilot-Hash - $($Hosts.Count) PC(s)" -OkText 'Auslesen' -Fields @(@{ Name = 'Tag'; Label = 'Gruppentag (optional):'; Type = 'Text'; Default = '' })
    if (-not $f) { return }
    $script:AutopilotTag = "$($f.Tag)".Trim()
    Invoke-HMMultiRemote -Hosts $Hosts -Title 'Autopilot-Hash' -Script {
        try {
            $d = Get-CimInstance -Namespace 'root/cimv2/mdm/dmmap' -ClassName 'MDM_DevDetail_Ext01' -Filter "InstanceID='Ext' AND ParentID='./DevDetail'" -ErrorAction Stop
            if (-not $d.DeviceHardwareData) { 'FEHLER kein Hardware-Hash'; return }
            "OK SN=$("$((Get-CimInstance Win32_BIOS).SerialNumber)".Trim()) HASH=$($d.DeviceHardwareData)"
        } catch { "FEHLER $($_.Exception.Message)" }
    } -OnRows {
        param($rows)
        $lines = New-Object System.Collections.Generic.List[string]
        $tag = $script:AutopilotTag
        $lines.Add($(if ($tag) { 'Device Serial Number,Windows Product ID,Hardware Hash,Group Tag' } else { 'Device Serial Number,Windows Product ID,Hardware Hash' }))
        foreach ($rw in $rows) {
            if ("$($rw[2])" -match 'SN=(\S*) HASH=(\S+)') {
                $lines.Add($(if ($tag) { '{0},,{1},{2}' -f $Matches[1], $Matches[2], $tag } else { '{0},,{1}' -f $Matches[1], $Matches[2] }))
                $rw[2] = "Seriennummer $($Matches[1]) - Hash gelesen"
            }
        }
        if ($lines.Count -le 1) { return }
        try {
            $dir = Join-Path (Get-BackupRoot) 'Autopilot'
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            $file = Join-Path $dir ("AutopilotHWID_{0}PCs_{1}.csv" -f ($lines.Count - 1), (Get-Date -Format 'yyyyMMdd_HHmm'))
            [System.IO.File]::WriteAllLines($file, $lines.ToArray(), (New-Object System.Text.UTF8Encoding $false))
            Out-Console "Autopilot-CSV ($($lines.Count - 1) Geraete): $file" 'Success'
            Start-Process explorer.exe -ArgumentList "/select,`"$file`""
        } catch { Out-Console "Autopilot-CSV nicht gespeichert: $($_.Exception.Message)" 'Error' }
    }
}

# ----------------------------------------------------------------------------
# Remote-PowerShell / Remote-CMD (eigenes Fenster)
# ----------------------------------------------------------------------------
function Start-HMRemoteShell([bool]$Cmd) {
    $c = Get-TargetComputer
    if (Test-HMIsLocal $c) { Out-Console 'Lokaler PC gewaehlt - Remote-Konsole nur fuer andere PCs.' 'Warning'; return }
    if ($Cmd) {
        Out-Console "Remote-CMD (winrs) zu $c ..." 'Info'
        $u = if ($script:RemoteCred) { " -u:$($script:RemoteCred.UserName)" } else { '' }
        Start-Process cmd.exe -ArgumentList '/k', "title winrs $c & winrs -r:$c$u cmd"
    } else {
        Out-Console "Remote-PowerShell zu $c ..." 'Info'
        $cmdText = if ($script:RemoteCred) { "Enter-PSSession -ComputerName '$c' -Credential (Get-Credential -UserName '$($script:RemoteCred.UserName)' -Message 'Kennwort fuer $c')" } else { "Enter-PSSession -ComputerName '$c'" }
        Start-Process powershell.exe -ArgumentList '-NoExit', '-Command', $cmdText
    }
}

# ----------------------------------------------------------------------------
# Uebermittlungsoptimierung (Delivery Optimization) - lokale Richtlinie
# Werte laut Microsoft (Policy CSP DeliveryOptimization): DODownloadMode 0=HTTP, 1=LAN, 2=Gruppe, 3=Internet, 99=einfach
# ----------------------------------------------------------------------------
$script:RS_DeliveryOpt = {
    param($o)
    $key = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'
    $names = @{ 0 = 'nur HTTP (kein Peer)'; 1 = 'LAN (gleiches Netz/NAT)'; 2 = 'Gruppe'; 3 = 'Internet'; 99 = 'einfach (kein DO-Dienst)'; 100 = 'Bypass' }
    if (-not $o.Query) {
        try {
            if ($o.Mode -eq -1) { Remove-ItemProperty -LiteralPath $key -Name DODownloadMode, DOGroupId, DORestrictPeerSelectionBy -ErrorAction SilentlyContinue; 'OK lokale Richtlinie entfernt (Windows-Standard bzw. GPO/Intune gilt)' }
            else {
                if (-not (Test-Path -LiteralPath $key)) { New-Item -Path $key -Force | Out-Null }
                New-ItemProperty -LiteralPath $key -Name DODownloadMode -Value ([int]$o.Mode) -PropertyType DWord -Force | Out-Null
                if ($o.Subnet) { New-ItemProperty -LiteralPath $key -Name DORestrictPeerSelectionBy -Value 1 -PropertyType DWord -Force | Out-Null } else { Remove-ItemProperty -LiteralPath $key -Name DORestrictPeerSelectionBy -ErrorAction SilentlyContinue }
                if ($o.Mode -eq 2 -and $o.Group) { New-ItemProperty -LiteralPath $key -Name DOGroupId -Value "$($o.Group)" -PropertyType String -Force | Out-Null } else { Remove-ItemProperty -LiteralPath $key -Name DOGroupId -ErrorAction SilentlyContinue }
                "OK Modus $($o.Mode) = $($names[[int]$o.Mode])$(if ($o.Subnet) { ', nur eigenes Subnetz' })$(if ($o.Mode -eq 2 -and $o.Group) { ", Gruppe $($o.Group)" })"
            }
            $svc = Get-Service DoSvc -ErrorAction SilentlyContinue
            if ($svc -and "$($svc.StartType)" -eq 'Disabled') { Set-Service DoSvc -StartupType Manual -ErrorAction SilentlyContinue; 'WARN Dienst DoSvc war deaktiviert - auf Manuell gesetzt' }
            try { Restart-Service DoSvc -Force -ErrorAction Stop } catch { }
        } catch { "FEHLER $($_.Exception.Message)" }
    }
    $p = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
    $mdm = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\DeliveryOptimization' -ErrorAction SilentlyContinue
    $eff = ''; try { $eff = "$(Get-DODownloadMode -ErrorAction Stop)" } catch { }
    "INFO Richtlinie (lokal/GPO): $(if ($null -ne $p.DODownloadMode) { "$($p.DODownloadMode) = $($names[[int]$p.DODownloadMode])" } else { 'nicht gesetzt' })$(if ($p.DORestrictPeerSelectionBy -eq 1) { ', nur Subnetz' })$(if ($p.DOGroupId) { ", Gruppe $($p.DOGroupId)" })"
    if ($mdm -and $null -ne $mdm.DODownloadMode) { "WARN Intune/MDM setzt DODownloadMode = $($mdm.DODownloadMode) (hat Vorrang bzw. ueberschreibt)" }
    if ($eff) { "INFO wirksamer Modus: $eff" }
    try {
        $s = Get-DeliveryOptimizationPerfSnapThisMonth -ErrorAction Stop
        "INFO diesen Monat: {0:N0} MB geladen, davon {1:N0} MB von anderen PCs, {2:N0} MB an andere PCs geliefert" -f ($s.DownloadHttpBytes / 1MB + $s.DownloadLanBytes / 1MB + $s.DownloadGroupBytes / 1MB + $s.DownloadInternetBytes / 1MB), (($s.DownloadLanBytes + $s.DownloadGroupBytes) / 1MB), (($s.UploadLanBytes + $s.UploadGroupBytes) / 1MB)
    } catch { }
}
function Start-HMDeliveryOpt([string[]]$Hosts = @()) {
    $multi = $Hosts.Count -gt 0
    $c = if ($multi) { "$($Hosts.Count) PC(s)" } else { Get-TargetComputer }
    $f = Show-HMFormDialog -Title "Uebermittlungsoptimierung - $c" -OkText 'Setzen' -Width 600 -Fields @(
        @{ Name = 'Mode'; Label = 'Download-Modus:'; Type = 'Combo'; Items = @('1 - LAN: Updates im selben Netz teilen (empfohlen)', '2 - Gruppe: ueber Subnetze hinweg (AD-Standort/Gruppen-ID)', '0 - nur HTTP, kein Teilen', 'Lokale Richtlinie entfernen', 'Nur anzeigen') }
        @{ Name = 'Subnet'; Label = 'Nur mit PCs im selben Subnetz teilen'; Type = 'Check'; Default = $true }
        @{ Name = 'Group'; Label = 'Gruppen-ID (nur Modus 2, GUID, optional):'; Type = 'Text'; Default = '' }
        @{ Type = 'Info'; Label = 'Setzt HKLM\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization (wie GPO). Eine GPO oder Intune-Richtlinie ueberschreibt den Wert - dann dort einstellen. Werte laut Microsoft Policy CSP DeliveryOptimization.' }
    )
    if (-not $f) { return }
    $o = @{ Query = $false; Mode = 1; Subnet = [bool]$f.Subnet; Group = "$($f.Group)".Trim() }
    switch -Wildcard ("$($f.Mode)") { '1 -*' { $o.Mode = 1 } '2 -*' { $o.Mode = 2 } '0 -*' { $o.Mode = 0 } 'Lokale*' { $o.Mode = -1 } 'Nur*' { $o.Query = $true } }
    if ($o.Group -and $o.Group -notmatch '^\{?[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\}?$') { Out-Console 'Gruppen-ID muss eine GUID sein.' 'Warning'; return }
    if ($multi) { Invoke-HMMultiRemote -Hosts $Hosts -Title 'Uebermittlungsoptimierung' -Arguments @(, $o) -Script $script:RS_DeliveryOpt }
    else { Invoke-HMTool -Title 'Uebermittlungsoptimierung' -Computer $c -ArgumentList @(, $o) -Script $script:RS_DeliveryOpt }
}

# ----------------------------------------------------------------------------
# Ordnerfreigaben: anzeigen (Freigabe- + NTFS-Rechte), aus Backup uebernehmen
# ----------------------------------------------------------------------------
function Show-HMShares {
    $c = Get-TargetComputer
    Invoke-HMTool -Title 'Ordnerfreigaben' -Computer $c -Script $script:HMShareReadScript -OnResult {
        param($r, $comp)
        $sh = @($r | Where-Object { $_ -and $_.Name })
        $rows = New-Object System.Collections.Generic.List[object]
        foreach ($x in $sh) { $rows.Add(@("$($x.Name)", "$($x.Path)", (Format-HMShareAccess $x), (Format-HMNtfsAccess $x), "$($x.Description)")) }
        if (-not $rows.Count) { Out-Console "$comp hat keine eigenen Ordnerfreigaben." 'Info' }
        Show-DataGridWindow -Title "Ordnerfreigaben - $comp" -Columns @('Freigabe', 'Pfad', 'Freigabe-Rechte', 'NTFS-Rechte', 'Beschreibung') -Rows $rows.ToArray() -Sort 'Freigabe ASC' `
            -CountText "$($rows.Count) Freigaben (ohne C$/ADMIN$/IPC$)" -Width 1400 -Height 520 -ActionContext @{ Computer = $comp } -Actions @(
                @{ Text = 'Aus Backup uebernehmen ...'; Color = '#FFA6E3A1'; NoSelection = $true; Handler = { param($rows, $win, $ctx) Show-HMSharesFromBackup $ctx.Computer } }
            )
    }
}
function Show-HMSharesFromBackup([string]$Computer) {
    $b = $script:SelectedBackup
    if (-not $b) { Out-Console 'Bitte im Reiter Restore das Backup markieren, aus dem die Freigaben kommen.' 'Warning'; return }
    $f = Join-Path $b.Path 'Shares\shares.json'
    if (-not (Test-Path -LiteralPath $f)) { Out-Console "Im Backup '$($b.Name)' sind keine Freigaben (Modul 'Ordnerfreigaben' ab v0.0.6)." 'Warning'; return }
    $arr = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json
    $script:BackupShares = @(foreach ($x in $arr) { $x })
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($x in $script:BackupShares) { $rows.Add(@("$($x.Name)", "$($x.Path)", (Format-HMShareAccess $x), (Format-HMNtfsAccess $x), $(if ($x.PathExists) { 'ja' } else { 'nein' }))) }
    Show-DataGridWindow -Title "Freigaben im Backup $($b.Name) (Quelle $($b.Computer)) -> $Computer" -Columns @('Freigabe', 'Pfad', 'Freigabe-Rechte', 'NTFS-Rechte', 'Ordner war da') -Rows $rows.ToArray() -Sort 'Freigabe ASC' `
        -CountText 'Markieren und anlegen - vorhandene Freigaben werden nicht veraendert, fehlende Ordner angelegt' -Width 1400 -Height 520 -ActionContext @{ Computer = $Computer } -Actions @(
            @{ Text = 'Markierte anlegen (Freigabe-Rechte)'; Color = '#FFA6E3A1'; Handler = { param($rows, $win, $ctx) New-HMSharesOnTarget $win $ctx.Computer @($rows | ForEach-Object { "$($_.Freigabe)" }) $false } }
            @{ Text = 'Markierte anlegen + NTFS-Rechte'; Color = '#FFFAB387'; Handler = { param($rows, $win, $ctx) New-HMSharesOnTarget $win $ctx.Computer @($rows | ForEach-Object { "$($_.Freigabe)" }) $true } }
        )
}
function New-HMSharesOnTarget($Win, [string]$Computer, [string[]]$Names, [bool]$Ntfs) {
    $sel = @($script:BackupShares | Where-Object { $Names -contains "$($_.Name)" })
    if (-not $sel.Count) { return }
    $q = "$($sel.Count) Freigabe(n) an $Computer anlegen?$(if ($Ntfs) { "`n`nNTFS-Rechte werden auf die Ordner GESETZT (ersetzt die vorhandenen). Konten, die am Ziel unbekannt sind (lokale Konten des alten PCs), fallen weg." })`n`n$(($sel | ForEach-Object { "$($_.Name)  ->  $($_.Path)" }) -join "`n")"
    if ("$([System.Windows.MessageBox]::Show($Win, $q, 'Freigaben uebernehmen', 'YesNo', 'Question'))" -ne 'Yes') { return }
    $json = ConvertTo-Json -InputObject @($sel) -Depth 5 -Compress
    Invoke-HMTool -Title 'Freigaben anlegen' -Computer $Computer -ArgumentList @($json, $Ntfs) -Script $script:HMShareCreateScript
}

# ----------------------------------------------------------------------------
# USMT aus dem Windows ADK in den Tool-Ordner (BIN\USMT\<Architektur>) kopieren - ADK bei Bedarf nur mit USMT installieren
# ----------------------------------------------------------------------------
function Get-HMAdkUsmtDir { return (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Assessment and Deployment Kit\User State Migration Tool') }
function Start-HMUsmtSetup {
    $src = Get-HMAdkUsmtDir
    if (Test-Path -LiteralPath (Join-Path $src 'amd64\scanstate.exe')) { Copy-HMUsmtToTool; return }
    $f = Show-HMFormDialog -Title 'USMT einrichten' -OkText 'adksetup.exe waehlen ...' -Width 620 -Fields @(
        @{ Type = 'Info'; Label = "Auf diesem PC ist das Windows ADK (User State Migration Tool) nicht installiert.`n`n1. adksetup.exe von Microsoft laden (Seite 'Download and install the Windows ADK' - wird geoeffnet)`n2. hier auswaehlen - installiert wird NUR das User State Migration Tool (still, Administratorrechte)`n3. danach werden die Dateien nach BIN\USMT kopiert (der Tool-Ordner kann dann auch auf PCs ohne ADK verwendet werden)" }
        @{ Name = 'Open'; Label = 'Download-Seite im Browser oeffnen'; Type = 'Check'; Default = $true }
    )
    if (-not $f) { return }
    if ($f.Open) { Start-Process 'https://learn.microsoft.com/windows-hardware/get-started/adk-install' }
    $d = New-Object Microsoft.Win32.OpenFileDialog
    $d.Filter = 'ADK-Setup (adksetup.exe)|adksetup.exe|Programme (*.exe)|*.exe'
    $d.Title = 'adksetup.exe auswaehlen'
    if ($d.ShowDialog() -ne $true) { return }
    Out-Console "ADK: installiere nur das User State Migration Tool (still, einige Minuten) ..." 'Info'
    $exe = $d.FileName
    Invoke-AsyncCommand -ScriptBlock {
        param($exe)
        try {
            $p = Start-Process -FilePath $exe -ArgumentList '/quiet', '/norestart', '/ceip off', '/features', 'OptionId.UserStateMigrationTool' -Verb RunAs -PassThru -Wait -ErrorAction Stop
            "CODE:$($p.ExitCode)"
        } catch { "FEHLER: $($_.Exception.Message)" }
    } -ArgumentList @($exe) -TimeoutSec 3600 -OnComplete {
        param($r)
        if ("$r" -match '^FEHLER') { Out-Console "ADK-Setup: $r" 'Error'; return }
        Out-Console "ADK-Setup beendet ($r)" $(if ("$r" -eq 'CODE:0' -or "$r" -eq 'CODE:3010') { 'Success' } else { 'Warning' })
        if (Test-Path -LiteralPath (Join-Path (Get-HMAdkUsmtDir) 'amd64\scanstate.exe')) { Copy-HMUsmtToTool } else { Out-Console 'USMT nach dem Setup nicht gefunden - ADK-Setup-Protokoll: %TEMP%\adk' 'Error' }
    }
}
function Copy-HMUsmtToTool {
    $src = Get-HMAdkUsmtDir
    $dst = Join-Path $script:AppRoot 'BIN\USMT'
    $n = 0
    foreach ($arch in 'amd64', 'arm64', 'x86') {
        $s = Join-Path $src $arch
        if (-not (Test-Path -LiteralPath (Join-Path $s 'scanstate.exe'))) { continue }
        try {
            $t = Join-Path $dst $arch
            if (-not (Test-Path -LiteralPath $t)) { New-Item -ItemType Directory -Path $t -Force | Out-Null }
            Copy-Item -Path (Join-Path $s '*') -Destination $t -Recurse -Force -ErrorAction Stop
            $v = (Get-Item -LiteralPath (Join-Path $t 'scanstate.exe')).VersionInfo.ProductVersion
            Out-Console "USMT $arch kopiert nach $t (Version $v)" 'Success'; $n++
        } catch { Out-Console "USMT $arch kopieren fehlgeschlagen: $($_.Exception.Message)" 'Error' }
    }
    if (-not $n) { Out-Console "Keine USMT-Dateien unter $src gefunden." 'Warning' }
}

# ----------------------------------------------------------------------------
# Laufwerke / Admin-Freigaben des gewaehlten PCs im Explorer oeffnen (C$, USB-Sticks, weitere Freigaben)
# Explorer laeuft als angemeldeter Windows-Benutzer - dieser braucht Adminrechte am Ziel-PC.
# ----------------------------------------------------------------------------
function Open-HMDrivePath([string]$Path) {
    Out-Console "Explorer: $Path" 'Info'
    try { Start-Process -FilePath explorer.exe -ArgumentList "`"$Path`"" } catch { Out-Console "Oeffnen nicht moeglich: $($_.Exception.Message)" 'Error' }
}
function Open-HMAdminShare {
    $c = Get-TargetComputer
    if (Test-HMIsLocal $c) { Open-HMDrivePath "$env:SystemDrive\" } else { Open-HMDrivePath "\\$c\C$" }
}
function Show-HMDriveMenu {
    $c = Get-TargetComputer
    Out-Console "Laufwerke und Freigaben von $c lesen ..." 'Info'
    Invoke-AsyncCommand -ScriptBlock {
        param($comp, $cred, $isLocal)
        $cs = $null
        try {
            if (-not $isLocal) {
                $p = @{ ComputerName = $comp; ErrorAction = 'Stop' }; if ($cred) { $p.Credential = $cred }
                try { $cs = New-CimSession @p; [void](Get-CimInstance -CimSession $cs Win32_OperatingSystem -ErrorAction Stop) }
                catch { if ($cs) { Remove-CimSession $cs -ErrorAction SilentlyContinue }; $p.SessionOption = New-CimSessionOption -Protocol Dcom; $cs = New-CimSession @p }
            }
            $q = @{ ErrorAction = 'Stop' }; if ($cs) { $q.CimSession = $cs }
            $disks = @(Get-CimInstance @q Win32_LogicalDisk | Where-Object { $_.DriveType -in 2, 3, 5 } | ForEach-Object {
                [pscustomobject]@{ Letter = "$($_.DeviceID)".TrimEnd(':'); Type = [int]$_.DriveType; Label = "$($_.VolumeName)"; Size = [double]$_.Size; Free = [double]$_.FreeSpace } })
            $usb = @{}
            try {
                foreach ($dd in @(Get-CimInstance @q Win32_DiskDrive | Where-Object { $_.InterfaceType -eq 'USB' })) {
                    foreach ($part in @(Get-CimAssociatedInstance -InputObject $dd -ResultClassName Win32_DiskPartition -ErrorAction SilentlyContinue)) {
                        foreach ($ld in @(Get-CimAssociatedInstance -InputObject $part -ResultClassName Win32_LogicalDisk -ErrorAction SilentlyContinue)) { $usb["$($ld.DeviceID)".TrimEnd(':')] = $true }
                    }
                }
            } catch { }
            $shares = @(Get-CimInstance @q Win32_Share | Where-Object { $_.Type -eq 0 } | ForEach-Object { [pscustomobject]@{ Name = "$($_.Name)"; Path = "$($_.Path)" } })
            [pscustomobject]@{ Disks = $disks; Usb = @($usb.Keys); Shares = $shares; Error = $null }
        } catch { [pscustomobject]@{ Disks = @(); Usb = @(); Shares = @(); Error = $_.Exception.Message } }
        finally { if ($cs) { Remove-CimSession $cs -ErrorAction SilentlyContinue } }
    } -ArgumentList @($c, $script:RemoteCred, [bool](Test-HMIsLocal $c)) -TimeoutSec 60 -State $c -OnComplete {
        param($r, $comp)
        if ($r -is [string] -or -not $r) { Out-Console "Laufwerke von ${comp}: $r" 'Error'; return }
        if ($r.Error) { Out-Console "Laufwerke von $comp nicht lesbar: $($r.Error) - Abhilfe: Fernwartung aktivieren" 'Error'; return }
        $local = Test-HMIsLocal $comp
        $m = New-Object System.Windows.Controls.ContextMenu
        $h = New-Object System.Windows.Controls.MenuItem; $h.Header = "Laufwerke von $comp"; $h.IsEnabled = $false; [void]$m.Items.Add($h)
        foreach ($d in @($r.Disks | Sort-Object Letter)) {
            $kind = if (@($r.Usb) -contains $d.Letter) { 'USB' } elseif ($d.Type -eq 2) { 'Wechseldatentraeger/USB' } elseif ($d.Type -eq 5) { 'CD/DVD' } else { 'Lokal' }
            $size = if ($d.Size -gt 0) { ", $(Format-HMSize $d.Free) frei von $(Format-HMSize $d.Size)" } else { '' }
            $mi = New-Object System.Windows.Controls.MenuItem
            $mi.Header = "$($d.Letter):   $(if ($d.Label) { $d.Label } else { '(ohne Namen)' })   [$kind$size]"
            $mi.Tag = $(if ($local) { "$($d.Letter):\" } else { "\\$comp\$($d.Letter)$" })
            if ($kind -like '*USB*') { $mi.FontWeight = [System.Windows.FontWeights]::Bold }
            $mi.Add_Click({ param($src) Open-HMDrivePath "$($src.Tag)" })
            [void]$m.Items.Add($mi)
        }
        $sh = @($r.Shares | Sort-Object Name)
        if ($sh.Count) {
            [void]$m.Items.Add((New-Object System.Windows.Controls.Separator))
            $h2 = New-Object System.Windows.Controls.MenuItem; $h2.Header = 'Freigaben'; $h2.IsEnabled = $false; [void]$m.Items.Add($h2)
            foreach ($s in $sh) {
                $mi = New-Object System.Windows.Controls.MenuItem
                $mi.Header = "$($s.Name)   ($($s.Path))"
                $mi.Tag = $(if ($local) { $s.Path } else { "\\$comp\$($s.Name)" })
                $mi.Add_Click({ param($src) Open-HMDrivePath "$($src.Tag)" })
                [void]$m.Items.Add($mi)
            }
        }
        $m.Placement = [System.Windows.Controls.Primitives.PlacementMode]::MousePoint
        $m.IsOpen = $true
        Out-Console "$(@($r.Disks).Count) Laufwerke, $($sh.Count) Freigaben auf $comp" 'Debug'
    }
}
