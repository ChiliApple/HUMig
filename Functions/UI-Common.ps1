#Requires -Version 5.1
<#
.SYNOPSIS
    Gemeinsame Oberflaechen-Bausteine: Tabellenfenster (Filter, Sortierung, CSV, Drucken, Aktions-Buttons),
    Texteingabe-Dialog, verstaendliche Remote-Fehlermeldungen.
.NOTES
    Wird im UI-Thread geladen (dot-source aus HUMig.ps1). Nutzt $script:Window, $script:AppIcon.
#>

# ----------------------------------------------------------------------------
# Tabellenfenster (nicht modal)
# ----------------------------------------------------------------------------
function Show-DataGridWindow {
    param(
        [string]$Title,
        [string[]]$Columns,
        [object[]]$Rows,               # Array von Arrays (Werte in Spaltenreihenfolge)
        [string]$Sort = '',
        [string]$CountText = '',
        [int]$Width = 900,
        [int]$Height = 560,
        [hashtable]$ColumnTypes = @{},
        [object[]]$Actions = @(),      # @{ Text; Color; Handler = { param($rows, $win, $ctx) }; NoSelection = $true }
        [object]$ActionContext = $null
    )
    $safeTitle = [System.Security.SecurityElement]::Escape($Title)
    $dgXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$safeTitle" Height="$Height" Width="$Width" MinWidth="400" MinHeight="250"
        WindowStartupLocation="CenterOwner" Background="#FF1E1E2E">
  <DockPanel LastChildFill="True">
    <Border DockPanel.Dock="Top" Background="#FF181825" Padding="6,4">
      <DockPanel>
        <TextBlock Text="Filter:" Foreground="#FFA6ADC8" VerticalAlignment="Center" Margin="0,0,6,0"/>
        <TextBox x:Name="txtFilter" Background="#FF313244" Foreground="#FFCDD6F4" BorderBrush="#FF585B70" CaretBrush="#FFCDD6F4" Padding="4,2"/>
      </DockPanel>
    </Border>
    <Border DockPanel.Dock="Bottom" Background="#FF11111B" Padding="6,4">
      <StackPanel Orientation="Horizontal">
        <StackPanel x:Name="pnlActions" Orientation="Horizontal"/>
        <Button x:Name="btnPrint" Content="Drucken" Width="100" Height="26" Background="#FF89B4FA" Foreground="#FF1E1E2E" FontWeight="SemiBold" Cursor="Hand"/>
        <Button x:Name="btnCsv" Content="Als CSV exportieren" Width="160" Height="26" Margin="6,0,0,0" Background="#FFA6E3A1" Foreground="#FF1E1E2E" FontWeight="SemiBold" Cursor="Hand"/>
        <TextBlock x:Name="lblCount" Text="" Foreground="#FFA6ADC8" VerticalAlignment="Center" Margin="12,0,0,0"/>
      </StackPanel>
    </Border>
    <DataGrid x:Name="dg" AutoGenerateColumns="True" IsReadOnly="True"
              Background="#FF313244" Foreground="#FFCDD6F4" RowBackground="#FF313244"
              AlternatingRowBackground="#FF45475A" GridLinesVisibility="Horizontal"
              HorizontalGridLinesBrush="#FF585B70" BorderBrush="#FF585B70"
              HeadersVisibility="Column" CanUserSortColumns="True" SelectionUnit="FullRow">
      <DataGrid.ColumnHeaderStyle>
        <Style TargetType="DataGridColumnHeader">
          <Setter Property="Background" Value="#FF181825"/>
          <Setter Property="Foreground" Value="#FFCDD6F4"/>
          <Setter Property="FontWeight" Value="SemiBold"/>
          <Setter Property="Padding" Value="6,4"/>
          <Setter Property="BorderBrush" Value="#FF45475A"/>
          <Setter Property="BorderThickness" Value="0,0,1,1"/>
        </Style>
      </DataGrid.ColumnHeaderStyle>
      <DataGrid.CellStyle>
        <Style TargetType="DataGridCell">
          <Setter Property="BorderThickness" Value="0"/>
          <Style.Triggers>
            <Trigger Property="IsSelected" Value="True">
              <Setter Property="Background" Value="#FF89B4FA"/>
              <Setter Property="Foreground" Value="#FF1E1E2E"/>
            </Trigger>
          </Style.Triggers>
        </Style>
      </DataGrid.CellStyle>
    </DataGrid>
  </DockPanel>
</Window>
"@
    $w = [System.Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new(([xml]$dgXaml)))
    $dg        = $w.FindName('dg')
    $btnPrint  = $w.FindName('btnPrint')
    $btnCsv    = $w.FindName('btnCsv')
    $lblCnt    = $w.FindName('lblCount')
    $txtFilter = $w.FindName('txtFilter')
    if ($script:AppIcon) { $w.Icon = $script:AppIcon }

    $dt = New-Object System.Data.DataTable
    foreach ($c in $Columns) {
        $type = if ($ColumnTypes.ContainsKey($c)) { $ColumnTypes[$c] } else { [string] }
        [void]$dt.Columns.Add($c, $type)
    }
    foreach ($r in $Rows) {
        $row = $dt.NewRow()
        for ($i = 0; $i -lt $Columns.Count; $i++) {
            $v = if ($i -lt @($r).Count) { @($r)[$i] } else { $null }
            if ($null -eq $v -or "$v" -eq '') { $row[$i] = [System.DBNull]::Value } else { $row[$i] = $v }
        }
        $dt.Rows.Add($row)
    }
    $dv = $dt.DefaultView
    if ($Sort) { try { $dv.Sort = $Sort } catch { } }
    # Spaltenkopf als TextBlock: sonst verschluckt WPF '_' (Access-Key)
    $dg.Add_AutoGeneratingColumn({
        param($s, $e)
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = ("$($e.PropertyName)" -replace '_', ' ')
        $e.Column.Header = $tb
        # Breite nach Inhalt (ganzer Text sichtbar, sonst waagrechter Bildlauf)
        $e.Column.Width = [System.Windows.Controls.DataGridLength]::Auto
    })
    $dg.ItemsSource = $dv
    $baseCount = if ($CountText) { $CountText } else { "$($dt.Rows.Count) Eintraege" }
    $lblCnt.Text = $baseCount
    $printTitle = $Title
    $colNames = @($Columns)

    # Diese Handler brauchen nur lokale Variablen -> GetNewClosure ist hier korrekt
    $txtFilter.Add_TextChanged({
        $t = $txtFilter.Text
        if ([string]::IsNullOrWhiteSpace($t)) { $dv.RowFilter = ''; $lblCnt.Text = $baseCount; return }
        $sb = New-Object System.Text.StringBuilder
        foreach ($ch in $t.Trim().ToCharArray()) {
            if ($ch -eq "'") { [void]$sb.Append("''") }
            elseif ('*%[]'.IndexOf($ch) -ge 0) { [void]$sb.Append("[$ch]") }
            else { [void]$sb.Append($ch) }
        }
        $pat = $sb.ToString()
        $parts = foreach ($cn in $colNames) { "Convert([$cn], 'System.String') LIKE '*$pat*'" }
        try { $dv.RowFilter = ($parts -join ' OR ') } catch { $dv.RowFilter = '' }
        $lblCnt.Text = "$($dv.Count) von $($dt.Rows.Count) Eintraegen (gefiltert)"
    }.GetNewClosure())

    $btnPrint.Add_Click({
        $pd = New-Object System.Windows.Controls.PrintDialog
        if ($pd.ShowDialog() -eq $true) {
            try {
                $dg.UpdateLayout()
                $size = New-Object System.Windows.Size $pd.PrintableAreaWidth, $pd.PrintableAreaHeight
                $dg.Measure($size); $dg.Arrange((New-Object System.Windows.Rect $size))
                $pd.PrintVisual($dg, $printTitle)
            } catch { [void][System.Windows.MessageBox]::Show("Druck fehlgeschlagen: $_", 'Drucken', 'OK', 'Error') }
            finally { $dg.InvalidateMeasure() }
        }
    }.GetNewClosure())

    $btnCsv.Add_Click({
        $sfd = New-Object Microsoft.Win32.SaveFileDialog
        $sfd.Filter = 'CSV (*.csv)|*.csv'
        $sfd.FileName = ($printTitle -replace '[\\/:*?"<>|]', '_') + '.csv'
        if ($sfd.ShowDialog() -eq $true) {
            try {
                $out = foreach ($rv in $dv) {
                    $o = [ordered]@{}
                    foreach ($cn in $colNames) { $val = $rv.Row[$cn]; $o[$cn] = if ($val -is [System.DBNull]) { '' } elseif ($val -is [datetime]) { $val.ToString('dd.MM.yyyy HH:mm:ss') } else { "$val" } }
                    [pscustomobject]$o
                }
                @($out) | Export-Csv -Path $sfd.FileName -NoTypeInformation -Encoding UTF8 -Delimiter ';' -Force
                [void][System.Windows.MessageBox]::Show("Exportiert: $($sfd.FileName)", 'CSV-Export', 'OK', 'Information')
            } catch { [void][System.Windows.MessageBox]::Show("CSV-Export fehlgeschlagen: $_", 'Export', 'OK', 'Error') }
        }
    }.GetNewClosure())

    # Aktions-Buttons: Daten im Tag, Handler ohne Closure (Skript-Funktionen bleiben sichtbar)
    $pnl = $w.FindName('pnlActions')
    foreach ($act in @($Actions)) {
        if (-not $act) { continue }
        $b = New-Object System.Windows.Controls.Button
        $b.Content = $act.Text
        $b.Height = 26; $b.MinWidth = 90
        $b.Padding = [System.Windows.Thickness]::new(10, 0, 10, 0)
        $b.Margin = [System.Windows.Thickness]::new(0, 0, 6, 0)
        $b.FontWeight = [System.Windows.FontWeights]::SemiBold
        $b.Cursor = [System.Windows.Input.Cursors]::Hand
        $b.Foreground = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString('#FF1E1E2E'))
        $col = if ($act.Color) { $act.Color } else { '#FF89B4FA' }
        $b.Background = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString($col))
        $b.Tag = @{ Act = $act; Ctx = $ActionContext; Grid = $dg; Win = $w; Cols = $colNames }
        $b.Add_Click({
            param($src)
            $t = $src.Tag
            $selRows = @(foreach ($rv in @($t.Grid.SelectedItems)) {
                if ($rv -isnot [System.Data.DataRowView]) { continue }
                $o = [ordered]@{}
                foreach ($cn in $t.Cols) { $v = $rv.Row[$cn]; $o[$cn] = if ($v -is [System.DBNull]) { $null } else { $v } }
                [pscustomobject]$o
            })
            if (-not $t.Act.NoSelection -and $selRows.Count -eq 0) {
                [void][System.Windows.MessageBox]::Show($t.Win, 'Bitte zuerst eine oder mehrere Zeilen markieren.', "$($t.Act.Text)", 'OK', 'Information')
                return
            }
            try { & $t.Act.Handler $selRows $t.Win $t.Ctx }
            catch { [void][System.Windows.MessageBox]::Show($t.Win, "Fehler: $($_.Exception.Message)", "$($t.Act.Text)", 'OK', 'Error') }
        })
        [void]$pnl.Children.Add($b)
    }
    $w.Owner = $script:Window; Set-HMWindowScale $w
    $w.Show()
}

# ----------------------------------------------------------------------------
# Mehrzeilige Texteingabe (z.B. Liste von PC-Namen)
# ----------------------------------------------------------------------------
function Show-TextInputDialog {
    param([string]$Title, [string]$Label, [string]$Text = '', [object]$Owner = $null, [switch]$MultiLine)
    $x = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$([System.Security.SecurityElement]::Escape($Title))" Width="480" SizeToContent="Height" ResizeMode="NoResize" WindowStartupLocation="CenterOwner" Background="#FF1E1E2E">
  <StackPanel Margin="14">
    <TextBlock x:Name="lbl" Foreground="#FFCDD6F4" TextWrapping="Wrap" Margin="0,0,0,8"/>
    <TextBox x:Name="txt" Background="#FF313244" Foreground="#FFCDD6F4" BorderBrush="#FF585B70" CaretBrush="#FFCDD6F4" Padding="4,3" Margin="0,0,0,12"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
      <Button x:Name="ok" Content="OK" Width="100" Height="28" Background="#FFA6E3A1" Foreground="#FF1E1E2E" FontWeight="SemiBold" Margin="0,0,6,0" IsDefault="True"/>
      <Button x:Name="cancel" Content="Abbrechen" Width="100" Height="28" Background="#FF45475A" Foreground="#FFCDD6F4" IsCancel="True"/>
    </StackPanel>
  </StackPanel>
</Window>
"@
    $w = [System.Windows.Markup.XamlReader]::Parse($x)
    if ($script:AppIcon) { $w.Icon = $script:AppIcon }
    $w.FindName('lbl').Text = $Label
    $t = $w.FindName('txt'); $t.Text = $Text
    if ($MultiLine) { $t.AcceptsReturn = $true; $t.Height = 160; $t.VerticalScrollBarVisibility = 'Auto'; $w.FindName('ok').IsDefault = $false }
    $res = @{ V = $null }
    $w.FindName('ok').Add_Click({ $res.V = $t.Text; $w.DialogResult = $true }.GetNewClosure())
    $w.Owner = $(if ($Owner) { $Owner } else { $script:Window }); Set-HMWindowScale $w
    [void]$t.Focus()
    if ($w.ShowDialog() -eq $true) { return $res.V }
    return $null
}

# ----------------------------------------------------------------------------
# Remote-Fehler kurz und verstaendlich (WinRM / Kerberos / DNS)
# ----------------------------------------------------------------------------
$script:RemoteErrorMap = @(
    @{ P = '0x80090322|SEC_E_WRONG_PRINCIPAL'; T = 'Kerberos: falsches Ziel (0x80090322) - DNS zeigt auf fremde IP, doppelter SPN oder Computerkonto defekt' }
    @{ P = '0x80090324|SEC_E_TIME_SKEW|Zeitunterschied|clock skew|time difference'; T = 'Kerberos: Uhrzeit weicht mehr als 5 min ab (0x80090324) - am Client w32tm /resync' }
    @{ P = '0x80090311|SEC_E_NO_AUTHENTICATING_AUTHORITY|keine Authentifizierungsautorit|No authority could be contacted'; T = 'Kerberos: kein Domaenencontroller erreichbar bzw. Client nicht in der Domaene (0x80090311)' }
    @{ P = '0x80090303|SEC_E_TARGET_UNKNOWN'; T = 'Kerberos: Ziel unbekannt (0x80090303) - Computerkonto/SPN fehlt im AD' }
    @{ P = '0x8009030e|SEC_E_NO_CREDENTIALS|Anmeldesitzung ist nicht vorhanden|logon session does not exist'; T = 'Anmeldedaten fehlen (0x8009030E) - Kerberos-Ticket abgelaufen (klist purge) oder Doppel-Hop' }
    @{ P = '0x8009030c|SEC_E_LOGON_DENIED'; T = 'Anmeldung verweigert (0x8009030C) - Konto/Kennwort pruefen' }
    @{ P = 'Vertrauensstellung|trust relationship'; T = 'Vertrauensstellung Client <-> Domaene defekt - am Client Test-ComputerSecureChannel -Repair' }
    @{ P = 'mit einer IP-Adresse|with an IP address'; T = 'Ziel als IP angegeben - Kerberos braucht den Computernamen' }
    @{ P = 'TrustedHosts'; T = 'Kerberos nicht moeglich (Alias/CNAME, SPN fehlt, fremde Domaene oder IP) - Computernamen verwenden' }
    @{ P = '0x80338012|in der Anforderung angegebenen Ziel|cannot connect to the destination'; T = 'WinRM nicht erreichbar (0x80338012) - PC aus, Firewall oder WinRM-Dienst/Listener fehlt' }
    @{ P = '0x80072ee7|cannot be resolved|could not be resolved|nicht aufgel|Cannot find the computer|Der angeforderte Name ist g'; T = 'DNS: Computername nicht aufloesbar (0x80072EE7)' }
    @{ P = 'MaxShellsPerUser|maximale Anzahl|maximum number of concurrent|Kontingent|quota'; T = 'WinRM-Kontingent erschoepft (zu viele offene Sitzungen) - WinRM-Dienst am Client neu starten' }
    @{ P = 'Zugriff verweigert|Access is denied|0x80070005'; T = 'Zugriff verweigert - dein Konto ist am Client kein lokaler Admin' }
    @{ P = '0x80338029|within the time specified|innerhalb der angegebenen Zeit|0x80072efd|0x80072ee2|0x800705b4|Zeit.berschreitung|timed out'; T = 'Zeitueberschreitung - PC aus, Firewall blockt WinRM (5985) oder Netzwerk sehr langsam' }
    @{ P = 'WinRM(-| )?(client )?cannot (complete|process)|WinRM(-Client)? kann (den Vorgang|die Anforderung) nicht'; T = 'WinRM nicht erreichbar - PC aus, falscher Name, Firewall oder WinRM deaktiviert' }
)
function Format-RemoteError([string]$Text) {
    if (-not $Text) { return $Text }
    foreach ($m in $script:RemoteErrorMap) { if ($Text.Contains($m.T)) { return $Text } }
    if ($Text -notmatch '(?i)Remoteserver|remote server|WinRM|WS-Management|WS-Verwaltung|Kerberos|0x8[0-9a-f]{7}') { return $Text }
    $pre = ''
    if ($Text -match '^(\s*(?:(?:FEHLER|ERR|WARN|OK)\b[:| ]*)?(?:[^:"]{1,40}:\s+)?)') { $pre = $Matches[1] }
    if ($pre -and $pre -notmatch '(?i)^\s*(FEHLER|ERR|WARN|OK)' -and $pre -match '(?i)Beim Verbinden|Connecting') { $pre = '' }
    foreach ($m in $script:RemoteErrorMap) { if ($Text -match "(?i)$($m.P)") { return "$pre$($m.T)" } }
    if ($Text.Length -gt 300) { return $Text.Substring(0, 300) + ' ...' }
    return $Text
}
