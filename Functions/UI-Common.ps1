#Requires -Version 5.1
<#
.SYNOPSIS
    Gemeinsame Oberflaechen-Bausteine: Tabellenfenster (Filter, Sortierung, CSV, Drucken, Aktions-Buttons),
    Texteingabe-Dialog, verstaendliche Remote-Fehlermeldungen.
.NOTES
    Wird im UI-Thread geladen (dot-source aus HUMig.ps1). Nutzt $script:Window, $script:AppIcon.
#>

# ----------------------------------------------------------------------------
# Meldungen und Rueckfragen im HUMig-Stil (ersetzt die Windows-MessageBox ueberall nach dem Start)
# Mode: OK | OKCancel | YesNo | YesNoCancel.  Icon: Information | Warning | Error | Question.
# Rueckgabe als Text: 'OK' | 'Cancel' | 'Yes' | 'No' (wie MessageBoxResult, Vergleiche mit -eq 'Yes' bleiben gueltig).
# Schliessen (X, Esc): OK -> 'OK', OKCancel/YesNoCancel -> 'Cancel', YesNo -> 'No'.
# -Default bestimmt den Enter-Knopf; ohne Angabe: Warnung mit Ja/Nein -> Nein (sicher), sonst erster Knopf.
# Rueckfall auf die Windows-MessageBox, wenn das Hauptfenster noch nicht steht oder das Fenster nicht aufgebaut werden kann.
# ----------------------------------------------------------------------------
function Show-HMDialogBox {
    param([object]$Owner = $null, [string]$Text = '', [string]$Title = 'HUMig', [string]$Mode = 'OK', [string]$Icon = 'Information', [string]$Default = '')
    $Mode = switch ("$Mode") { 'YesNo' { 'YesNo' } 'YesNoCancel' { 'YesNoCancel' } 'OKCancel' { 'OKCancel' } default { 'OK' } }
    $Icon = switch ("$Icon") { 'Warning' { 'Warning' } 'Exclamation' { 'Warning' } 'Error' { 'Error' } 'Stop' { 'Error' } 'Hand' { 'Error' } 'Question' { 'Question' } default { 'Information' } }
    $o = $null
    try { if ($Owner -is [System.Windows.Window] -and $Owner.IsLoaded) { $o = $Owner } elseif ($script:Window -and $script:Window.IsLoaded) { $o = $script:Window } } catch { $o = $null }
    $fallback = {
        $img = $(if ($Icon -eq 'Information') { 'Information' } else { $Icon })
        $def = $(if ($Default) { $Default } elseif ($Mode -eq 'YesNo' -and $Icon -eq 'Warning') { 'No' } elseif ($Mode -in @('YesNoCancel', 'OKCancel') -and $Icon -eq 'Warning') { 'Cancel' } else { '' })
        $r = if ($o -and $def) { [System.Windows.MessageBox]::Show($o, $Text, $Title, $Mode, $img, $def) }
        elseif ($o) { [System.Windows.MessageBox]::Show($o, $Text, $Title, $Mode, $img) }
        elseif ($def) { [System.Windows.MessageBox]::Show($Text, $Title, $Mode, $img, $def) }
        else { [System.Windows.MessageBox]::Show($Text, $Title, $Mode, $img) }
        return "$r"
    }
    if (-not $o) { return (& $fallback) }
    try {
        $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        SizeToContent="WidthAndHeight" MinWidth="420" MinHeight="150" WindowStartupLocation="CenterOwner" ResizeMode="NoResize"
        ShowInTaskbar="False" Background="#FF1E1E2E" UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
  <DockPanel>
    <Border DockPanel.Dock="Bottom" Background="#FF181825" BorderBrush="#FF313244" BorderThickness="0,1,0,0" Padding="14,9">
      <StackPanel x:Name="pnlButtons" Orientation="Horizontal" HorizontalAlignment="Right"/>
    </Border>
    <Grid Margin="18,18,22,16">
      <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <Grid x:Name="icoBox" Width="34" Height="34" VerticalAlignment="Top" Margin="0,0,16,0">
        <Ellipse x:Name="icoCircle"/>
        <TextBlock x:Name="icoGlyph" Foreground="#FF1E1E2E" FontSize="19" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,-2,0,0"/>
      </Grid>
      <ScrollViewer x:Name="scroll" Grid.Column="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" VerticalAlignment="Center">
        <TextBox x:Name="txt" IsReadOnly="True" TextWrapping="Wrap" BorderThickness="0" Background="Transparent" Foreground="#FFCDD6F4"
                 FontSize="13" Padding="0" Cursor="Arrow" IsTabStop="False" MinWidth="300"/>
      </ScrollViewer>
    </Grid>
  </DockPanel>
</Window>
'@
        $w = [System.Windows.Markup.XamlReader]::Parse($x)
        $w.Title = "$Title"
        if ($script:AppIcon) { try { $w.Icon = $script:AppIcon } catch { } }
        try { $w.Owner = $o } catch { $w.WindowStartupLocation = 'CenterScreen'; $w.ShowInTaskbar = $true }
        $txt = "$Text".TrimEnd()
        $tb = $w.FindName('txt'); $tb.Text = $txt
        $len = $txt.Length; $lines = @($txt -split "`n").Count
        $tb.MaxWidth = $(if ($len -gt 1200 -or $lines -gt 24) { 760 } elseif ($len -gt 400) { 620 } else { 520 })
        $wa = [System.Windows.SystemParameters]::WorkArea
        $w.FindName('scroll').MaxHeight = [Math]::Max(240, $wa.Height * 0.65)
        $bc = [System.Windows.Media.BrushConverter]::new()
        $ic = switch ($Icon) { 'Warning' { @('#FFF9E2AF', '!') } 'Error' { @('#FFF38BA8', [string][char]0x2715) } 'Question' { @('#FFCBA6F7', '?') } default { @('#FF89B4FA', 'i') } }
        $w.FindName('icoCircle').Fill = $bc.ConvertFrom($ic[0])
        $g = $w.FindName('icoGlyph'); $g.Text = $ic[1]
        if ($Icon -eq 'Error') { $g.FontSize = 16; $g.Margin = [System.Windows.Thickness]::new(0) }
        $kind = switch ($Icon) { 'Warning' { 'Warnung' } 'Error' { 'Fehler' } 'Question' { 'Frage' } default { 'Hinweis' } }
        $ap = [System.Windows.Automation.AutomationProperties]
        $short = $(if ($txt.Length -gt 400) { $txt.Substring(0, 400) + ' ...' } else { $txt })
        $ap::SetName($w, "${kind}: $Title"); $ap::SetName($w.FindName('icoBox'), $kind); $ap::SetName($tb, $short)
        # Knoepfe: Blau = Standardaktion, Rot = Ja bei Warnung (etwas Riskantes), Grau = Nein/Abbrechen
        $yesCol = $(if ($Icon -in @('Warning', 'Error')) { '#FFF38BA8' } else { '#FF89B4FA' })
        $defs = @(switch ($Mode) {
            'YesNo' { @(@('Yes', 'Ja', $yesCol, '#FF1E1E2E'), @('No', 'Nein', '#FF45475A', '#FFCDD6F4')) }
            'YesNoCancel' { @(@('Yes', 'Ja', $yesCol, '#FF1E1E2E'), @('No', 'Nein', '#FF45475A', '#FFCDD6F4'), @('Cancel', 'Abbrechen', '#FF45475A', '#FFCDD6F4')) }
            'OKCancel' { @(@('OK', 'OK', $yesCol, '#FF1E1E2E'), @('Cancel', 'Abbrechen', '#FF45475A', '#FFCDD6F4')) }
            default { , @('OK', 'OK', '#FF89B4FA', '#FF1E1E2E') }
        })
        $keys = @($defs | ForEach-Object { $_[0] })
        $cancelKey = $(switch ($Mode) { 'YesNo' { 'No' } 'YesNoCancel' { 'Cancel' } 'OKCancel' { 'Cancel' } default { 'OK' } })
        $defaultKey = $(if ($Default -and $keys -contains "$Default") { "$Default" } elseif ($Mode -eq 'YesNo' -and $Icon -eq 'Warning') { 'No' } elseif ($Mode -in @('YesNoCancel', 'OKCancel') -and $Icon -eq 'Warning') { $cancelKey } else { $keys[0] })
        $st = @{ R = $cancelKey; First = $null }
        $w.Tag = $st
        foreach ($b in $defs) {
            $btn = New-Object System.Windows.Controls.Button
            $btn.Content = $b[1]; $btn.Tag = $b[0]; $btn.MinWidth = 96; $btn.Height = 28; $btn.FontWeight = [System.Windows.FontWeights]::SemiBold
            $btn.Padding = [System.Windows.Thickness]::new(12, 0, 12, 0); $btn.Cursor = [System.Windows.Input.Cursors]::Hand
            $btn.Background = $bc.ConvertFrom($b[2]); $btn.Foreground = $bc.ConvertFrom($b[3]); $btn.BorderThickness = [System.Windows.Thickness]::new(0)
            $ap::SetName($btn, $(if ($b[0] -eq $defaultKey -and $defs.Count -gt 1) { "$($b[1]) (Enter)" } else { "$($b[1])" }))
            $ap::SetHelpText($btn, $short)
            if ($b[0] -eq $defaultKey) { $btn.IsDefault = $true; $st.First = $btn }
            if ($b[0] -eq $cancelKey) { $btn.IsCancel = $true }
            $btn.Add_Click({ param($sd, $e) $win = [System.Windows.Window]::GetWindow($sd); $win.Tag.R = "$($sd.Tag)"; $win.Close() })
            if ($b[0] -eq $defaultKey -and $defs.Count -gt 1) {
                # vorgewaehlter Knopf (Enter) mit hellem Rahmen
                $fr = New-Object System.Windows.Controls.Border
                $fr.BorderBrush = $bc.ConvertFrom('#FFCDD6F4'); $fr.BorderThickness = [System.Windows.Thickness]::new(2)
                $fr.CornerRadius = [System.Windows.CornerRadius]::new(4); $fr.Padding = [System.Windows.Thickness]::new(1); $fr.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0)
                $fr.ToolTip = 'Enter'; $fr.Child = $btn
                [void]$w.FindName('pnlButtons').Children.Add($fr)
            } else { $btn.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0); [void]$w.FindName('pnlButtons').Children.Add($btn) }
        }
        $w.Add_KeyDown({
            param($sd, $e)
            if ($e.Key -eq 'C' -and ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control)) {
                $t = $sd.FindName('txt'); if ($t.SelectionLength) { return }
                try { [System.Windows.Clipboard]::SetText("$($sd.Title)`r`n`r`n$($t.Text)") } catch { }
                $e.Handled = $true
            }
        })
        $w.Add_ContentRendered({ param($sd, $e) if ($sd.Tag.First) { [void]$sd.Tag.First.Focus() } })
        Set-HMWindowScale $w
        [void]$w.ShowDialog()
        return "$($st.R)"
    } catch {
        try { Out-Console "Meldungsfenster: $($_.Exception.Message) - Windows-Meldung verwendet" 'Warning' } catch { }
        return (& $fallback)
    }
}

# Wartefenster (nicht modal): zeigt "bitte warten", wird spaeter mit Update-HMWaitBox auf Ergebnis gestellt und freigegeben.
# Rueckgabe: Fenster (oder $null, wenn das Hauptfenster noch nicht steht).
function Show-HMWaitBox([string]$Title, [string]$Text, [object]$Owner = $null) {
    $o = $null
    try { if ($Owner -is [System.Windows.Window] -and $Owner.IsLoaded) { $o = $Owner } elseif ($script:Window -and $script:Window.IsLoaded) { $o = $script:Window } } catch { $o = $null }
    if (-not $o) { return $null }
    try {
        $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        SizeToContent="WidthAndHeight" MinWidth="440" WindowStartupLocation="CenterOwner" ResizeMode="NoResize" ShowInTaskbar="False"
        Background="#FF1E1E2E" UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
  <DockPanel>
    <Border DockPanel.Dock="Bottom" Background="#FF181825" BorderBrush="#FF313244" BorderThickness="0,1,0,0" Padding="14,9">
      <DockPanel>
        <TextBlock x:Name="lblState" Foreground="#FFA6ADC8" VerticalAlignment="Center" FontSize="12"/>
        <Button x:Name="btnOk" Content="OK" MinWidth="96" Height="28" HorizontalAlignment="Right" FontWeight="SemiBold" Background="#FF89B4FA" Foreground="#FF1E1E2E" BorderThickness="0" IsEnabled="False" Cursor="Hand"/>
      </DockPanel>
    </Border>
    <Grid Margin="18,18,22,16">
      <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <Grid Width="34" Height="34" VerticalAlignment="Top" Margin="0,0,16,0">
        <Ellipse x:Name="icoCircle" Fill="#FF89B4FA"/>
        <TextBlock x:Name="icoGlyph" Text="…" Foreground="#FF1E1E2E" FontSize="19" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,-6,0,0"/>
      </Grid>
      <StackPanel Grid.Column="1" VerticalAlignment="Center">
        <TextBlock x:Name="txt" Foreground="#FFCDD6F4" FontSize="13" TextWrapping="Wrap" MaxWidth="560"/>
        <ProgressBar x:Name="bar" IsIndeterminate="True" Height="6" Margin="0,12,0,0" Background="#FF313244" Foreground="#FF89B4FA" BorderThickness="0"/>
      </StackPanel>
    </Grid>
  </DockPanel>
</Window>
'@
        $w = [System.Windows.Markup.XamlReader]::Parse($x)
        $w.Title = "$Title"
        if ($script:AppIcon) { try { $w.Icon = $script:AppIcon } catch { } }
        try { $w.Owner = $o } catch { }
        $w.FindName('txt').Text = "$Text"
        $w.FindName('lblState').Text = 'Bitte warten ...'
        $w.Tag = @{ Done = $false }
        $w.FindName('btnOk').Add_Click({ param($sd, $e) [System.Windows.Window]::GetWindow($sd).Close() })
        # solange nicht fertig: Schliessen (X, Alt+F4) nur ausblenden, nicht moeglich - Ergebnis soll ankommen
        $w.Add_Closing({ param($sd, $e) if (-not $sd.Tag.Done) { $e.Cancel = $true } })
        Set-HMWindowScale $w
        $w.Show()
        return $w
    } catch { return $null }
}
# Wartefenster auf Ergebnis stellen: Icon Information | Success | Warning | Error, Text, OK-Knopf frei (Enter/Esc schliessen)
function Update-HMWaitBox($W, [string]$Text, [string]$Icon = 'Success', [string]$State = 'Fertig') {
    if (-not $W) { return }
    try {
        if (-not $W.IsLoaded) { return }
        $bc = [System.Windows.Media.BrushConverter]::new()
        $ic = switch ($Icon) { 'Success' { @('#FFA6E3A1', [string][char]0x2713) } 'Warning' { @('#FFF9E2AF', '!') } 'Error' { @('#FFF38BA8', [string][char]0x2715) } default { @('#FF89B4FA', 'i') } }
        $W.FindName('icoCircle').Fill = $bc.ConvertFrom($ic[0])
        $g = $W.FindName('icoGlyph'); $g.Text = $ic[1]; $g.Margin = [System.Windows.Thickness]::new(0, -2, 0, 0)
        $W.FindName('txt').Text = "$Text"
        $W.FindName('bar').Visibility = 'Collapsed'
        $W.FindName('lblState').Text = "$State"
        $W.Tag.Done = $true
        $b = $W.FindName('btnOk'); $b.IsEnabled = $true; $b.IsDefault = $true; $b.IsCancel = $true
        $b.Background = $bc.ConvertFrom($ic[0])
        try { $W.Activate() | Out-Null; [void]$b.Focus() } catch { }
    } catch { }
}

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
            } catch { [void](Show-HMDialogBox -Text "Druck fehlgeschlagen: $_" -Title 'Drucken' -Mode 'OK' -Icon 'Error') }
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
                [void](Show-HMDialogBox -Text ("Exportiert: $($sfd.FileName)") -Title 'CSV-Export' -Mode 'OK' -Icon 'Information')
            } catch { [void](Show-HMDialogBox -Text "CSV-Export fehlgeschlagen: $_" -Title 'Export' -Mode 'OK' -Icon 'Error') }
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
                [void](Show-HMDialogBox -Owner $t.Win -Text 'Bitte zuerst eine oder mehrere Zeilen markieren.' -Title ("$($t.Act.Text)") -Mode 'OK' -Icon 'Information')
                return
            }
            try { & $t.Act.Handler $selRows $t.Win $t.Ctx }
            catch { [void](Show-HMDialogBox -Owner $t.Win -Text ("Fehler: $($_.Exception.Message)") -Title ("$($t.Act.Text)") -Mode 'OK' -Icon 'Error') }
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

# ----------------------------------------------------------------------------
# Datei (Protokoll, Bericht, Anleitung) oeffnen.
# HTML: direkt mit dem Standard-Browser starten (Browser-Zuordnung https), NICHT ueber die .html-Zuordnung - Windows 11 zeigt
# sonst "Waehlen Sie eine App aus" (z.B. wenn HUMig unter einem eigenen Admin-Konto laeuft oder ein neues Programm .html
# registriert hat). Laeuft HUMig unter einem anderen Konto als der Desktop-Benutzer, gilt dessen Standard-Browser (ProgId aus
# seinem Hive, Befehl aber nur aus HKLM und nur ein Programm unter Programme/Windows - sonst der eigene bzw. Edge).
# ----------------------------------------------------------------------------
# Befehlszeile zu einer ProgId (Root = 'HKCU:' oder 'Registry::HKEY_USERS\<SID>'), sonst ''
# -MachineOnly (fremder Benutzer-Hive): Befehl NUR aus HKLM\SOFTWARE\Classes und nur ein Programm unter Programme/Windows,
# keine Skript-Hosts/Installer - den Hive eines anderen Kontos kann dessen Benutzer beliebig fuellen, HUMig startet das als
# Administrator. Mit -Ext zusaetzlich: Browser (http/https/.htm/.html) nur bekannte Browser-Programme, andere Endungen nur
# eine ProgId, die in HKLM fuer diese Endung eingetragen ist (Standardwert oder OpenWithProgids) - sonst z.B. Msi.Package.
function Get-HMProgIdCommand([string]$ProgId, [string]$Root = 'HKCU:', [switch]$MachineOnly, [string]$Ext = '') {
    if (-not "$ProgId".Trim()) { return '' }
    $keys = @("$Root\Software\Classes\$ProgId\shell\open\command", "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Classes\$ProgId\shell\open\command")
    $browser = $false
    if ($MachineOnly) {
        $keys = @($keys[1])
        if ($Ext) {
            $browser = @('http', 'https', '.htm', '.html') -contains $Ext.ToLowerInvariant()
            if (-not $browser -and -not (Test-HMMachineProgIdForExt $ProgId $Ext)) { return '' }
        }
    }
    foreach ($cls in $keys) {
        try {
            $c = (Get-ItemProperty -LiteralPath $cls -ErrorAction Stop).'(default)'
            if ("$c".Trim()) {
                if ($MachineOnly -and -not (Test-HMSafeHandlerCommand "$c".Trim())) { return '' }
                if ($browser -and -not (Test-HMBrowserCommand "$c".Trim())) { return '' }
                return "$c".Trim()
            }
        } catch { }
    }
    return ''
}
# Erstes Programm einer Befehlszeile (Pfad wie angegeben, Umgebungsvariablen aufgeloest), sonst ''
function Get-HMCommandExe([string]$Cmd) {
    if (-not $Cmd -or $Cmd -notmatch '^\s*"([^"]+)"|^\s*(\S+)') { return '' }
    $exe = if ($Matches[1]) { $Matches[1] } else { $Matches[2] }
    return [Environment]::ExpandEnvironmentVariables($exe)
}
# Ist das Programm der Befehlszeile ein bekannter Browser? (nur Dateiname; Ort prueft Test-HMSafeHandlerCommand)
function Test-HMBrowserCommand([string]$Cmd) {
    $exe = Get-HMCommandExe $Cmd
    if (-not $exe) { return $false }
    $name = [System.IO.Path]::GetFileName(($exe -replace '\\', '/').Split('/')[-1]).ToLowerInvariant()
    return (@('msedge.exe', 'chrome.exe', 'firefox.exe', 'brave.exe', 'opera.exe', 'launcher.exe', 'vivaldi.exe', 'iexplore.exe') -contains $name)
}
# Ist die ProgId in HKLM fuer diese Endung eingetragen (Standardwert von HKLM\SOFTWARE\Classes\<ext> oder OpenWithProgids)?
function Test-HMMachineProgIdForExt([string]$ProgId, [string]$Ext) {
    if (-not "$ProgId".Trim() -or -not "$Ext".StartsWith('.')) { return $false }
    $k = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Classes\$Ext"
    try { if ("$((Get-ItemProperty -LiteralPath $k -ErrorAction Stop).'(default)')" -ieq $ProgId) { return $true } } catch { }
    try {
        $o = Get-ItemProperty -LiteralPath "$k\OpenWithProgids" -ErrorAction Stop
        if (@($o.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' -and $_.Name -ieq $ProgId }).Count) { return $true }
    } catch { }
    return $false
}
# Programm einer Befehlszeile: liegt es unter %ProgramFiles%, %ProgramFiles(x86)% oder %windir% und ist kein Skript-Host,
# Installer oder sonstiges Werkzeug, das Befehle/Programme startet? (explorer bleibt erlaubt - legitimer Handler)
function Test-HMSafeHandlerCommand([string]$Cmd) {
    $exe = Get-HMCommandExe $Cmd
    if (-not $exe) { return $false }
    if (-not [System.IO.Path]::IsPathRooted($exe) -or $exe -like '\\*') { return $false }
    try { $full = [System.IO.Path]::GetFullPath($exe) } catch { return $false }
    $name = [System.IO.Path]::GetFileNameWithoutExtension($full)
    $deny = @('mshta', 'wscript', 'cscript', 'cmd', 'powershell', 'powershell_ise', 'pwsh', 'rundll32', 'regsvr32',
        'msiexec', 'mmc', 'hh', 'control', 'infdefaultinstall', 'cmstp', 'msbuild', 'installutil', 'regasm', 'regsvcs', 'forfiles',
        'bitsadmin', 'certutil', 'wmic', 'schtasks', 'reg', 'sc', 'net', 'net1', 'msdt', 'odbcconf', 'pcalua')
    if ($deny -contains $name.ToLowerInvariant()) { return $false }
    foreach ($b in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramW6432, $env:windir)) {
        if (-not "$b".Trim()) { continue }
        $bp = "$b".TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
        if ($full.StartsWith($bp, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}
# ProgId aus UserChoice bzw. (neuere Windows 11) UserChoiceLatest
function Get-HMUserChoiceProgId([string]$KeyPath) {
    foreach ($k in @("$KeyPath\UserChoiceLatest", "$KeyPath\UserChoice")) {
        try { $p0 = "$((Get-ItemProperty -LiteralPath $k -ErrorAction Stop).ProgId)"; if ($p0) { return $p0 } } catch { }
    }
    return ''
}
function Get-HMAssocCommand([string]$Ext, [string]$Root = 'HKCU:', [switch]$MachineOnly) {
    return (Get-HMProgIdCommand (Get-HMUserChoiceProgId "$Root\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\$Ext") $Root -MachineOnly:$MachineOnly -Ext $Ext)
}
# Standard-Browser (Befehlszeile) eines Kontos, sonst ''
function Get-HMBrowserCommand([string]$Root = 'HKCU:', [switch]$MachineOnly) {
    foreach ($proto in @('https', 'http')) {
        $c = Get-HMProgIdCommand (Get-HMUserChoiceProgId "$Root\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\$proto") $Root -MachineOnly:$MachineOnly -Ext $proto
        if ($c) { return $c }
    }
    return ''
}
function Get-HMDesktopUserSid {
    try {
        $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $sess = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
        foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop | Where-Object { $_.SessionId -eq $sess })) {
            $o = Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid -ErrorAction SilentlyContinue
            if ($o -and "$($o.Sid)" -and "$($o.Sid)" -ne $sid) { return "$($o.Sid)" }
        }
    } catch { }
    return ''
}
# Befehlszeile mit Platzhalter %1 starten. Rueckgabe: $true = gestartet
function Start-HMCommandWithFile([string]$Cmd, [string]$Path) {
    if (-not $Cmd -or $Cmd -notmatch '^\s*"([^"]+)"\s*(.*)$|^\s*(\S+)\s*(.*)$') { return $false }
    $exe = if ($Matches[1]) { $Matches[1] } else { $Matches[3] }
    $rest = if ($Matches[1]) { $Matches[2] } else { $Matches[4] }
    $exe = [Environment]::ExpandEnvironmentVariables($exe)
    if (-not (Test-Path -LiteralPath $exe)) { return $false }
    # %1 / %L = Datei (Platzhalter vereinheitlichen, uebrige wie %* entfernen), Pfad nur ohne vorhandene Anfuehrungszeichen quoten
    $r2 = ($rest -replace '%[1lL]', '<<HMFILE>>' -replace '%\*', '' -replace '%[A-Za-z0-9]', '').Trim()
    if ($r2 -notmatch '<<HMFILE>>') { $r2 = "$r2 <<HMFILE>>".Trim() }
    $q = if ($r2 -match '"<<HMFILE>>"' -or $r2 -match '--single-argument\s+<<HMFILE>>') { $Path } else { '"' + $Path + '"' }
    try { Start-Process -FilePath $exe -ArgumentList $r2.Replace('<<HMFILE>>', $q) -ErrorAction Stop; return $true } catch { return $false }
}
function Open-HMFile([string]$Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return }
    $ext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    $us = Get-HMDesktopUserSid
    $uRoot = if ($us -and (Test-Path -LiteralPath "Registry::HKEY_USERS\$us")) { "Registry::HKEY_USERS\$us" } else { '' }
    if ($ext -in @('.html', '.htm')) {
        $cmds = @()
        if ($uRoot) { $cmds += Get-HMBrowserCommand $uRoot -MachineOnly }
        $cmds += Get-HMBrowserCommand 'HKCU:'
        $edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if ($edge) { $cmds += "`"$edge`" `"%1`"" }
        foreach ($c in @($cmds | Where-Object { $_ })) { if (Start-HMCommandWithFile $c $Path) { return } }
        Start-Process -FilePath $Path; return
    }
    # andere Dateien: eigene Zuordnung, sonst die des Desktop-Benutzers
    if (-not $ext -or (Get-HMAssocCommand $ext) -or -not $uRoot) { Start-Process -FilePath $Path; return }
    if (Start-HMCommandWithFile (Get-HMAssocCommand $ext $uRoot -MachineOnly) $Path) { return }
    Start-Process -FilePath $Path
}

# Webseite im Standard-Browser oeffnen (wie Open-HMFile: Browser des Desktop-Benutzers, Adresse unveraendert uebergeben -
# ueber explorer.exe wurden lange Adressen mit ?-Teil teils verfaelscht, GitHub zeigte dann "Seite nicht gefunden")
function Open-HMUrl([string]$Url) {
    if ("$Url" -notmatch '^https?://') { return }
    $cmds = @()
    $us = Get-HMDesktopUserSid
    if ($us -and (Test-Path -LiteralPath "Registry::HKEY_USERS\$us")) { $cmds += Get-HMBrowserCommand "Registry::HKEY_USERS\$us" -MachineOnly }
    $cmds += Get-HMBrowserCommand 'HKCU:'
    foreach ($c in @($cmds | Where-Object { $_ })) { if (Start-HMCommandWithFile $c $Url) { return } }
    try { Start-Process -FilePath $Url } catch { }
}
