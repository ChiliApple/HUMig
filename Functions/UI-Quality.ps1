#Requires -Version 5.1
<#
.SYNOPSIS
    Oberflaeche fuer Backup-Qualitaet und Verwaltung: Backup pruefen (Pruefsummen-Katalog), Backups vergleichen,
    Restore-Vorschau, Checkliste nach dem Restore, Aufbewahrung nach Regeln, HTML-Uebersicht aller Backups.
.NOTES
    Wird im UI-Thread geladen (dot-source aus HUMig.ps1). Lange Vorgaenge laufen ueber Start-EngineJob im Hintergrund.
#>

# ----------------------------------------------------------------------------
# Restore-Kontext (gemeinsam fuer Restore und Vorschau)
# ----------------------------------------------------------------------------
function New-HMRestoreCtx([switch]$Quiet) {
    $b = $script:SelectedBackup
    if (-not $b) { Out-Console 'Bitte zuerst ein Backup waehlen.' 'Warning'; return $null }
    $p = Get-SelectedProfile
    if (-not $p) { Out-Console 'Bitte Zielbenutzer waehlen (oder DOMAENE\Benutzer eintragen).' 'Warning'; return $null }
    $mods = @(Get-CheckedModules $script:RestoreChecks)
    if (-not $mods.Count) { Out-Console 'Keine Module gewaehlt.' 'Warning'; return $null }
    $ctx = New-BaseCtx
    $ctx.Backup = $b
    $ctx.Modules = $mods
    $ctx.PostOptions = @{
        GpUpdate = [bool]$ui.chkGpUpdate.IsChecked; DisableWUDrivers = [bool]$ui.chkWUDrivers.IsChecked; NumLockOn = [bool]$ui.chkNumLock.IsChecked
        ExplorerFavorites = [bool]$ui.chkFavorites.IsChecked; FastBootOff = [bool]$ui.chkFastBoot.IsChecked; PostScript = "$($ui.txtPostScript.Text)".Trim()
    }
    if ($p.NoProfile) { $ctx.UserSid = $null; $ctx.ProfilePath = $null }
    $ctx.Options.VerifyAfter = ($script:Settings.Restore.VerifyAfter -ne $false)
    $ctx.SkippedApps = @()
    $ctx.ExtraTargets = Get-HMExtraTargetsFor $b
    return $ctx
}

# ----------------------------------------------------------------------------
# Restore: Ziele der Zusaetzlichen Ordner (anderer Ort oder auslassen)
# $script:ExtraTargets[<Backup-Pfad>] = @{ <Originalpfad-Schluessel> = <neues Ziel> ('' = auslassen) } - nur Abweichungen
# ----------------------------------------------------------------------------
if ($null -eq $script:ExtraTargets) { $script:ExtraTargets = @{} }
# Kopie der gewaehlten Ziele fuer den Restore-Lauf (nur Eintraege, die es im Backup gibt)
function Get-HMExtraTargetsFor($Backup) {
    $out = @{}
    if (-not $Backup -or -not $Backup.Path -or -not $script:ExtraTargets.ContainsKey("$($Backup.Path)")) { return $out }
    $keys = @(Get-HMExtraFolderEntries "$($Backup.Path)" ([bool]$Backup.Legacy) | ForEach-Object { ConvertTo-HMExtraKey $_.Path })
    $m = $script:ExtraTargets["$($Backup.Path)"]
    foreach ($k in @($m.Keys)) { if ($keys -contains $k) { $out[$k] = "$($m[$k])" } }
    return $out
}
# Text fuer Bestaetigung/Statuszeile: nur geaenderte Ziele (leer = alles wie gesichert)
function Get-HMExtraTargetsText($Backup, [switch]$Short) {
    if (-not $Backup) { return '' }
    $t = Get-HMExtraTargetsFor $Backup
    if (-not $t.Count) { return '' }
    $ent = @(Get-HMExtraFolderEntries "$($Backup.Path)" ([bool]$Backup.Legacy))
    $chg = 0; $skip = 0; $lines = @()
    foreach ($e in $ent) {
        $k = ConvertTo-HMExtraKey $e.Path
        if (-not $t.ContainsKey($k)) { continue }
        if (-not "$($t[$k])".Trim()) { $skip++; $lines += "  $($e.Path)  ->  (ausgelassen)" } else { $chg++; $lines += "  $($e.Path)  ->  $($t[$k])" }
    }
    if ($Short) {
        $parts = @(); if ($chg) { $parts += "$chg neues Ziel$(if ($chg -gt 1) { 'e' })" }; if ($skip) { $parts += "$skip ausgelassen" }
        return ($parts -join ', ')
    }
    return ($lines -join "`n")
}
# Knopf und Statuszeile im Reiter Restore: nur bei einem Backup mit Zusaetzlichen Ordnern
function Update-HMExtraTargetsUi {
    try {
        $b = $script:SelectedBackup
        $ent = @(); if ($b -and @($b.Modules) -contains 'ExtraFolders') { $ent = @(Get-HMExtraFolderEntries "$($b.Path)" ([bool]$b.Legacy)) }
        if (-not $ent.Count) { $ui.btnExtraTargets.Visibility = 'Collapsed'; $ui.lblExtraTargets.Visibility = 'Collapsed'; return }
        $ui.btnExtraTargets.Visibility = 'Visible'; $ui.lblExtraTargets.Visibility = 'Visible'
        $sh = Get-HMExtraTargetsText $b -Short
        $ui.lblExtraTargets.Text = "$($ent.Count) Zusaetzliche$(if ($ent.Count -eq 1) { 'r' }) Ordner im Backup - $(if ($sh) { $sh } else { 'zurueck an denselben Pfad' })"
        $ui.lblExtraTargets.Foreground = Get-ConsoleBrush $(if ($sh) { '#FF89B4FA' } else { '#FF6C7086' })
    } catch { }
}
# Laufwerk am Ziel-PC vorhanden? (lokal direkt, sonst ueber die Admin-Freigabe) - $null = nicht pruefbar
function Test-HMTargetDrive([string]$Computer, [string]$Letter, [hashtable]$Cache) {
    $l = "$Letter".ToUpper()
    if ($Cache.ContainsKey($l)) { return $Cache[$l] }
    $r = $null
    try {
        if (Test-HMIsLocal $Computer) { $r = [bool](Test-Path -LiteralPath "${l}:\") }
        else { $r = [bool](Test-Path -LiteralPath "\\$Computer\$l`$\") ; if (-not $r) { $r = $null } }
    } catch { $r = $null }
    $Cache[$l] = $r
    return $r
}
function Get-HMExtraTargetHint([string]$Orig, [string]$Target, [bool]$Sel, [string]$Computer, [hashtable]$Cache) {
    if (-not $Sel) { return 'wird nicht zurueckgespielt' }
    $t = "$Target".Trim()
    if (-not $t) { return 'bitte Ziel angeben (oder Haken weg = auslassen)' }
    $bad = Test-HMExtraTargetPath $t
    if ($bad) { return "Achtung: $bad" }
    $txt = if ((ConvertTo-HMExtraKey $t) -eq (ConvertTo-HMExtraKey $Orig)) { 'wie gesichert' } else { 'neues Ziel' }
    if ($t -match '^C:\\(Windows|Program Files|Program Files \(x86\)|ProgramData)(\\|$)') { return 'Systemordner - HUMig legt den Ordner stattdessen ins Profil des Zielbenutzers' }
    $d = Test-HMTargetDrive $Computer $t.Substring(0, 1) $Cache
    if ($d -eq $false) { return "Laufwerk $($t.Substring(0, 2).ToUpper()) gibt es am Ziel-PC nicht - bitte anderes Ziel waehlen" }
    if ($null -eq $d) { return "$txt (Laufwerk am Ziel-PC nicht pruefbar)" }
    return $txt
}
function Show-HMExtraTargetsDialog {
    $b = $script:SelectedBackup
    if (-not $b) { Out-Console 'Bitte zuerst ein Backup waehlen.' 'Warning'; return }
    $ent = @(Get-HMExtraFolderEntries "$($b.Path)" ([bool]$b.Legacy))
    if (-not $ent.Count) { Out-Console 'Dieses Backup enthaelt keine Zusaetzlichen Ordner.' 'Warning'; return }
    $comp = Get-TargetComputer
    $cur = Get-HMExtraTargetsFor $b
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Zusaetzliche Ordner - Ziele beim Restore" Width="1040" Height="460" MinWidth="720" MinHeight="300" WindowStartupLocation="CenterOwner" Background="#FF1E1E2E">
  <DockPanel Margin="12">
    <StackPanel DockPanel.Dock="Top" Margin="0,0,0,8">
      <TextBlock x:Name="lblHead" Foreground="#FFCDD6F4" FontWeight="SemiBold" FontSize="13" TextWrapping="Wrap"/>
      <TextBlock Foreground="#FFA6ADC8" TextWrapping="Wrap" Margin="0,4,0,0" Text="Standard: zurueck an denselben Pfad. Anderes Ziel: Pfad in 'Zurueck nach' eintippen oder ... waehlen (fehlende Ordner legt der Restore an). Haken weg: diesen Ordner nicht zurueckspielen. Kopiert wird wie beim Backup (Robocopy mit Threads, Protokoll, Pruefung)."/>
    </StackPanel>
    <DockPanel DockPanel.Dock="Bottom" Margin="0,10,0,0">
      <Button x:Name="btnReset" DockPanel.Dock="Left" Content="Alle wie gesichert" Width="140" Height="28" Background="#FF45475A" Foreground="#FFCDD6F4" ToolTip="Alle Ordner wieder an den Originalpfad, alle angehakt"/>
      <TextBlock x:Name="lblSum" Foreground="#FFA6ADC8" VerticalAlignment="Center" Margin="12,0,0,0"/>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
        <Button x:Name="btnOk" Content="Uebernehmen" Width="120" Height="28" Background="#FFA6E3A1" Foreground="#FF1E1E2E" FontWeight="SemiBold" Margin="0,0,6,0" IsDefault="True"/>
        <Button x:Name="btnCancel" Content="Abbrechen" Width="100" Height="28" Background="#FF45475A" Foreground="#FFCDD6F4" IsCancel="True"/>
      </StackPanel>
    </DockPanel>
    <DataGrid x:Name="dg" AutoGenerateColumns="False" CanUserAddRows="False" CanUserDeleteRows="False" HeadersVisibility="Column" SelectionMode="Single" SelectionUnit="FullRow"
              Background="#FF313244" Foreground="#FFCDD6F4" RowBackground="#FF313244" AlternatingRowBackground="#FF3B3D52" GridLinesVisibility="None" BorderBrush="#FF585B70" RowHeight="30">
      <DataGrid.ColumnHeaderStyle><Style TargetType="DataGridColumnHeader"><Setter Property="Background" Value="#FF181825"/><Setter Property="Foreground" Value="#FFCDD6F4"/><Setter Property="Padding" Value="6,4"/></Style></DataGrid.ColumnHeaderStyle>
      <DataGrid.CellStyle><Style TargetType="DataGridCell"><Setter Property="BorderThickness" Value="0"/><Setter Property="VerticalContentAlignment" Value="Center"/><Style.Triggers><Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="#FF45475A"/><Setter Property="Foreground" Value="#FFCDD6F4"/></Trigger></Style.Triggers></Style></DataGrid.CellStyle>
      <DataGrid.Columns>
        <DataGridTemplateColumn Header="Zurueck" Width="62"><DataGridTemplateColumn.CellTemplate><DataTemplate><CheckBox IsChecked="{Binding Sel, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" HorizontalAlignment="Center" VerticalAlignment="Center" ToolTip="Haken weg = nicht zurueckspielen"/></DataTemplate></DataGridTemplateColumn.CellTemplate></DataGridTemplateColumn>
        <DataGridTextColumn Header="Gesichert von" Binding="{Binding Orig}" IsReadOnly="True" Width="260"/>
        <DataGridTemplateColumn Header="Zurueck nach" Width="*"><DataGridTemplateColumn.CellTemplate><DataTemplate>
          <DockPanel>
            <Button DockPanel.Dock="Right" Tag="browse" Content="..." Width="30" Height="24" Margin="4,0,2,0" Background="#FF89B4FA" Foreground="#FF1E1E2E" ToolTip="Ordner am Ziel-PC waehlen (auch neuen Ordner anlegen)"/>
            <Button DockPanel.Dock="Right" Tag="orig" Content="&#x21BA;" Width="26" Height="24" Margin="4,0,0,0" Background="#FF45475A" Foreground="#FFCDD6F4" ToolTip="Zurueck auf den Originalpfad"/>
            <TextBox Text="{Binding Target, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" IsEnabled="{Binding Sel}" Background="#FF1E1E2E" Foreground="#FFCDD6F4" BorderBrush="#FF585B70" CaretBrush="#FFCDD6F4" Padding="4,2" VerticalContentAlignment="Center"/>
          </DockPanel>
        </DataTemplate></DataGridTemplateColumn.CellTemplate></DataGridTemplateColumn>
        <DataGridTextColumn Header="Hinweis" Binding="{Binding Hint}" IsReadOnly="True" Width="300">
          <DataGridTextColumn.ElementStyle><Style TargetType="TextBlock"><Setter Property="TextWrapping" Value="Wrap"/><Setter Property="VerticalAlignment" Value="Center"/>
            <Style.Triggers>
              <DataTrigger Binding="{Binding Level}" Value="ok"><Setter Property="Foreground" Value="#FFA6E3A1"/></DataTrigger>
              <DataTrigger Binding="{Binding Level}" Value="new"><Setter Property="Foreground" Value="#FF89B4FA"/></DataTrigger>
              <DataTrigger Binding="{Binding Level}" Value="warn"><Setter Property="Foreground" Value="#FFF9E2AF"/></DataTrigger>
              <DataTrigger Binding="{Binding Level}" Value="bad"><Setter Property="Foreground" Value="#FFF38BA8"/></DataTrigger>
              <DataTrigger Binding="{Binding Level}" Value="off"><Setter Property="Foreground" Value="#FF6C7086"/></DataTrigger>
            </Style.Triggers></Style></DataGridTextColumn.ElementStyle>
        </DataGridTextColumn>
      </DataGrid.Columns>
    </DataGrid>
  </DockPanel>
</Window>
'@
    $w = [System.Windows.Markup.XamlReader]::Parse($x)
    if ($script:AppIcon) { try { $w.Icon = $script:AppIcon } catch { } }
    $w.Owner = $script:Window
    $w.FindName('lblHead').Text = "Backup $($b.Name)  ->  Ziel-PC $comp  -  $($ent.Count) Zusaetzliche$(if ($ent.Count -eq 1) { 'r' }) Ordner"
    $dt = New-Object System.Data.DataTable
    foreach ($c in @('Orig', 'Target', 'Hint', 'Level', 'Key')) { [void]$dt.Columns.Add($c, [string]) }
    [void]$dt.Columns.Add('Sel', [bool])
    $st = @{ W = $w; Dt = $dt; Comp = $comp; Cache = @{}; Busy = $false; Lbl = $w.FindName('lblSum'); B = $b }
    foreach ($e in $ent) {
        $k = ConvertTo-HMExtraKey $e.Path
        $r = $dt.NewRow(); $r.Orig = "$($e.Path)"; $r.Key = $k; $r.Sel = $true; $r.Target = "$($e.Path)"
        if ($cur.ContainsKey($k)) { if ("$($cur[$k])".Trim()) { $r.Target = "$($cur[$k])" } else { $r.Sel = $false } }
        $dt.Rows.Add($r)
    }
    $refresh = {
        param($s, $row)
        $rows = @($s.Dt.Rows)   # immer alle: Hinweise wie 'gleiches Ziel wie ...' haengen von den anderen Zeilen ab
        $s.Busy = $true
        try {
            foreach ($r in $rows) {
                $h = Get-HMExtraTargetHint "$($r.Orig)" "$($r.Target)" ([bool]($r.Sel -eq $true)) $s.Comp $s.Cache
                $r.Hint = $h
                $r.Level = $(if ($h -eq 'wird nicht zurueckgespielt') { 'off' } elseif ($h -like 'Achtung:*' -or $h -like 'Laufwerk*gibt es*' -or $h -like 'bitte Ziel*') { 'bad' } elseif ($h -like 'Systemordner*' -or $h -like '*nicht pruefbar*') { 'warn' } elseif ($h -like 'neues Ziel*') { 'new' } else { 'ok' })
            }
            # gleiches Ziel fuer mehrere Ordner (Inhalte werden zusammengefuehrt), Ziel im Backup-Ordner (nur lokal pruefbar) - Codepruefung B13
            $sel = @($s.Dt.Rows | Where-Object { $_.Sel -eq $true -and "$($_.Target)".Trim() -and $_.Level -ne 'bad' })
            foreach ($g in @($sel | Group-Object { ConvertTo-HMExtraKey "$($_.Target)" } | Where-Object { $_.Count -gt 1 })) {
                foreach ($r in $g.Group) { $r.Hint = "gleiches Ziel wie $(@($g.Group | Where-Object { $_ -ne $r } | ForEach-Object { $_.Orig }) -join ', ') - Inhalte werden zusammengefuehrt"; $r.Level = 'warn' }
            }
            if (Test-HMIsLocal $s.Comp) {
                $broot = ''; try { $broot = ConvertTo-HMExtraKey (Get-BackupRoot) } catch { }
                if ($broot) { foreach ($r in $sel) { $k = ConvertTo-HMExtraKey "$($r.Target)"; if ($k -eq $broot -or $k.StartsWith($broot + '\')) { $r.Hint = 'Ziel liegt im Backup-Ordner - bitte anderes Ziel waehlen'; $r.Level = 'bad' } } }
            }
            $n = @($s.Dt.Rows | Where-Object { $_.Sel -eq $true -and "$($_.Hint)" -like 'neues Ziel*' }).Count
            $o = @($s.Dt.Rows | Where-Object { $_.Sel -ne $true }).Count
            $bd = @($s.Dt.Rows | Where-Object { $_.Level -eq 'bad' }).Count
            $s.Lbl.Text = "$($s.Dt.Rows.Count) Ordner: $(@($s.Dt.Rows).Count - $n - $o) wie gesichert, $n neues Ziel, $o ausgelassen$(if ($bd) { "  -  $bd mit Problem" })"
        } finally { $s.Busy = $false }
    }
    $st.Refresh = $refresh
    $script:ExtraDlg = $st
    & $refresh $st $null
    $dg = $w.FindName('dg'); $dg.ItemsSource = $dt.DefaultView
    $dt.Add_ColumnChanged({
        param($sd, $e)
        $s = $script:ExtraDlg
        if (-not $s -or $s.Busy -or $e.Column.ColumnName -notin @('Target', 'Sel')) { return }
        & $s.Refresh $s $e.Row
    })
    # Knoepfe in den Zeilen (... = Ordner waehlen, Pfeil = Originalpfad)
    $dg.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler]{
        param($sd, $e)
        $btn = $e.OriginalSource
        if ($btn -isnot [System.Windows.Controls.Button] -or "$($btn.Tag)" -notin @('browse', 'orig')) { return }
        $rv = $btn.DataContext
        if ($rv -isnot [System.Data.DataRowView]) { return }
        $e.Handled = $true
        if ("$($btn.Tag)" -eq 'orig') { $rv.Row.Sel = $true; $rv.Row.Target = "$($rv.Row.Orig)"; return }
        $sel = Select-HMSourceFolder "Ziel fuer $($rv.Row.Orig) am Ziel-PC waehlen (Ordner anlegen moeglich)" -Start "$($rv.Row.Target)" -AllowNew
        if ($sel) { $rv.Row.Sel = $true; $rv.Row.Target = "$sel".TrimEnd('\') }
    })
    $w.FindName('btnReset').Add_Click({ $s = $script:ExtraDlg; foreach ($r in @($s.Dt.Rows)) { $r.Sel = $true; $r.Target = "$($r.Orig)" } })
    $w.FindName('btnCancel').Add_Click({ $script:ExtraDlg.W.Close() })
    $w.FindName('btnOk').Add_Click({
        $s = $script:ExtraDlg
        $dgx = $s.W.FindName('dg'); try { [void]$dgx.CommitEdit(); [void]$dgx.CommitEdit() } catch { }
        & $s.Refresh $s $null
        $bad = @($s.Dt.Rows | Where-Object { $_.Sel -eq $true -and $_.Level -eq 'bad' })
        if ($bad.Count) {
            $m = "Bei $($bad.Count) Ordner(n) passt das Ziel nicht:`n`n$(@($bad | ForEach-Object { "  $($_.Orig): $($_.Hint)" }) -join "`n")`n`nBitte korrigieren oder den Haken wegnehmen."
            [void](Show-HMDialogBox -Owner $s.W -Text $m -Title 'Ziele pruefen' -Mode 'OK' -Icon 'Warning'); return
        }
        $map = @{}
        foreach ($r in @($s.Dt.Rows)) {
            if ($r.Sel -ne $true) { $map["$($r.Key)"] = ''; continue }
            $t = "$($r.Target)".Trim().TrimEnd('\')
            if ((ConvertTo-HMExtraKey $t) -ne "$($r.Key)") { $map["$($r.Key)"] = $t }
        }
        if ($map.Count) { $script:ExtraTargets["$($s.B.Path)"] = $map } elseif ($script:ExtraTargets.ContainsKey("$($s.B.Path)")) { $script:ExtraTargets.Remove("$($s.B.Path)") }
        $sh = Get-HMExtraTargetsText $s.B -Short
        Out-Console "Zusaetzliche Ordner beim Restore: $(if ($sh) { $sh } else { 'alle zurueck an denselben Pfad' })" 'Info'
        foreach ($l in @((Get-HMExtraTargetsText $s.B) -split "`n" | Where-Object { "$_".Trim() })) { Out-Console $l 'Info' }
        if ($map.Count -and -not @($script:RestoreChecks.Keys | Where-Object { $_ -eq 'ExtraFolders' -and $script:RestoreChecks[$_].IsChecked }).Count -and $script:RestoreChecks.ContainsKey('ExtraFolders')) { $script:RestoreChecks['ExtraFolders'].IsChecked = $true }
        Update-HMExtraTargetsUi
        $s.W.Close()
    })
    $w.Add_Closed({ $script:ExtraDlg = $null })
    Set-HMWindowScale $w
    [void]$w.ShowDialog()
}

# ----------------------------------------------------------------------------
# Restore: Ziel-Konto passend zum Backup (Vorschlag) und fehlendes lokales Konto anlegen
# ----------------------------------------------------------------------------
# Rein auswertbar (testbar). $Profiles = Profile am Ziel (Account, Folder). Rueckgabe:
#   Kind  = 'Domain' | 'Local' | 'Entra' | '' (Konto im Backup unbekannt)
#   Name  = Benutzername ohne Domaene; Suggest = vorgeschlagenes Ziel-Konto; Hit = vorhandenes Profil am Ziel oder $null
#   Differs = gewaehltes Ziel ist ein anderer Benutzer als im Backup
function Get-HMRestoreAccountPlan([string]$BackupAccount, [string]$BackupFolder, [string]$SourcePc, [string]$TargetAccount, [string]$TargetPc, [object[]]$Profiles = @()) {
    $o = [pscustomobject]@{ Kind = ''; Name = ''; Suggest = ''; Hit = $null; Differs = $false }
    if ("$BackupAccount".Trim() -notmatch '^([^\\]+)\\([^\\]+)$') { return $o }
    $dom = $Matches[1]; $o.Name = $Matches[2]
    $src = "$SourcePc".Trim().Split('.')[0]
    $o.Kind = if ($dom -ieq 'AzureAD') { 'Entra' } elseif ($src -and $dom -ieq $src) { 'Local' } else { 'Domain' }
    $o.Hit = @($Profiles | Where-Object { $_ -and (("$($_.Account)" -split '\\')[-1] -ieq $o.Name -or ("$BackupFolder" -and "$($_.Folder)" -ieq "$BackupFolder")) })[0]
    $o.Suggest = if ($o.Hit) { "$($o.Hit.Account)" } elseif ($o.Kind -eq 'Local') { "$("$TargetPc".Trim().Split('.')[0])\$($o.Name)" } else { "$BackupAccount".Trim() }
    $o.Differs = (("$TargetAccount" -split '\\')[-1] -ine $o.Name)
    return $o
}
# Lokales Konto am Ziel? (ohne Domaene oder Domaene = Computername des Ziels)
function Test-HMLocalTargetAccount([string]$Account, [string]$TargetPc) {
    $a = "$Account".Trim()
    if ($a -notmatch '\\') { return $true }
    return (($a -split '\\')[0] -ieq "$TargetPc".Trim().Split('.')[0])
}
# Kennwort fuer ein neues lokales Konto (zweimal), optional Administrator. Rueckgabe @{ Password (SecureString); Admin } oder $null
function Show-HMNewLocalAccountDialog([string]$Name, [string]$Computer) {
    $x = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Lokales Konto anlegen" Width="480" SizeToContent="Height" ResizeMode="NoResize" WindowStartupLocation="CenterOwner" Background="#FF1E1E2E">
  <StackPanel Margin="14">
    <TextBlock x:Name="info" Foreground="#FFCDD6F4" TextWrapping="Wrap" Margin="0,0,0,10"/>
    <TextBlock Text="Kennwort:" Foreground="#FFA6ADC8"/>
    <PasswordBox x:Name="pw1" Background="#FF313244" Foreground="#FFCDD6F4" BorderBrush="#FF585B70" CaretBrush="#FFCDD6F4" Padding="4,2" Margin="0,2,0,6"/>
    <TextBlock Text="Kennwort wiederholen:" Foreground="#FFA6ADC8"/>
    <PasswordBox x:Name="pw2" Background="#FF313244" Foreground="#FFCDD6F4" BorderBrush="#FF585B70" CaretBrush="#FFCDD6F4" Padding="4,2" Margin="0,2,0,8"/>
    <CheckBox x:Name="chkAdmin" Content="Mitglied der Administratoren (sonst normaler Benutzer)" Foreground="#FFCDD6F4" Margin="0,2,0,8"/>
    <TextBlock Foreground="#FF6C7086" TextWrapping="Wrap" FontSize="11" Margin="0,0,0,12" Text="Das Kennwort wird nur zum Anlegen verwendet - nicht gespeichert, nicht protokolliert und nie auf einer Befehlszeile uebergeben."/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
      <Button x:Name="ok" Content="Anlegen" Width="110" Height="28" Background="#FFA6E3A1" Foreground="#FF1E1E2E" FontWeight="SemiBold" Margin="0,0,6,0" IsDefault="True"/>
      <Button x:Name="cancel" Content="Abbrechen" Width="100" Height="28" Background="#FF45475A" Foreground="#FFCDD6F4" IsCancel="True"/>
    </StackPanel>
  </StackPanel>
</Window>
"@
    $w = [System.Windows.Markup.XamlReader]::Parse($x)
    if ($script:AppIcon) { $w.Icon = $script:AppIcon }
    $w.FindName('info').Text = "Lokales Konto '$Name' an $Computer anlegen. Danach legt USMT beim Restore das Profil an (Modul Windows-Einstellungen) - sonst einmal mit dem Konto anmelden."
    $pw1 = $w.FindName('pw1'); $pw2 = $w.FindName('pw2'); $chk = $w.FindName('chkAdmin')
    $res = @{ V = $null }
    $w.FindName('ok').Add_Click({
        if ($pw1.SecurePassword.Length -lt 1) { [void](Show-HMDialogBox -Owner $w -Text 'Bitte ein Kennwort eingeben (ein leeres Kennwort legt HUMig nicht an).' -Title 'Lokales Konto' -Mode 'OK' -Icon 'Warning'); return }
        $b1 = [IntPtr]::Zero; $b2 = [IntPtr]::Zero; $same = $false
        try {
            $b1 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($pw1.SecurePassword); $b2 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($pw2.SecurePassword)
            # zeichenweise ueber die BSTR vergleichen - ohne verwaltete Strings mit dem Kennwort
            $l1 = [Runtime.InteropServices.Marshal]::ReadInt32($b1, -4); $l2 = [Runtime.InteropServices.Marshal]::ReadInt32($b2, -4); $same = ($l1 -eq $l2)
            for ($k = 0; $same -and $k -lt $l1; $k += 2) { if ([Runtime.InteropServices.Marshal]::ReadInt16($b1, $k) -ne [Runtime.InteropServices.Marshal]::ReadInt16($b2, $k)) { $same = $false } }
        } finally { if ($b1 -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b1) }; if ($b2 -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b2) } }
        if (-not $same) { [void](Show-HMDialogBox -Owner $w -Text 'Die Kennwoerter stimmen nicht ueberein.' -Title 'Lokales Konto' -Mode 'OK' -Icon 'Warning'); return }
        $sp = $pw1.SecurePassword.Copy(); $sp.MakeReadOnly()
        $res.V = @{ Password = $sp; Admin = [bool]$chk.IsChecked }
        $w.DialogResult = $true
    }.GetNewClosure())
    $w.Owner = $script:Window; Set-HMWindowScale $w
    [void]$w.ShowDialog()
    $pw1.Clear(); $pw2.Clear()
    return $res.V
}
# Vor dem Restore: anderer Benutzer als im Backup -> Konto des Backups vorschlagen; lokales Konto ohne Profil, das es am Ziel
# nicht gibt -> anlegen (Kennwort-Abfrage). Setzt ggf. die Auswahl oben. Rueckgabe: $true = weiter, $false = Restore abbrechen
function Invoke-HMRestoreAccountCheck($Backup, $Target, [object[]]$Modules, [string]$Computer) {
    if ($script:UserMode -or -not $Backup -or -not $Target) { return $true }
    $tctx = @{ Computer = $Computer; IsRemote = -not (Test-HMIsLocal $Computer); Credential = $script:RemoteCred }
    $tpc = ''; try { $tpc = "$(Invoke-HMTarget $tctx { $env:COMPUTERNAME })".Trim() } catch { }
    if (-not $tpc) { $tpc = "$Computer".Split('.')[0] }
    $src = ''; try { $src = Get-HMManifestComputerName $Backup.Manifest } catch { }
    if (-not $src) { $src = "$($Backup.Computer)" }
    $pl = Get-HMRestoreAccountPlan "$($Backup.Account)" "$($Backup.User)" $src "$($Target.Account)" $tpc @($script:Profiles)
    if (-not $pl.Kind) { return $true }
    $sel = $Target
    if ($pl.Differs -and $pl.Kind -ne 'Entra') {
        $m = "Im Backup ist das Konto $($Backup.Account) - oben gewaehlt ist $(if ($Target.Account) { $Target.Account } else { $Target.Folder }) (anderer Benutzer).`n`nJa = Ziel auf $($pl.Suggest) setzen$(if (-not $pl.Hit) { ' (hat am Ziel noch kein Profil)' })`nNein = trotzdem nach $(if ($Target.Account) { $Target.Account } else { $Target.Folder }) zurueckspielen`nAbbrechen = nichts tun"
        $a = "$((Show-HMDialogBox -Owner $script:Window -Text $m -Title 'Restore - Ziel-Benutzer' -Mode 'YesNoCancel' -Icon 'Question' -Default 'Yes'))"
        if ($a -eq 'Cancel') { return $false }
        if ($a -eq 'Yes') {
            if ($pl.Hit) { $ui.cmbUser.SelectedIndex = [array]::IndexOf(@($script:Profiles), $pl.Hit) }
            else { $ui.cmbUser.SelectedIndex = -1; $ui.cmbUser.Text = $pl.Suggest }
            try { Update-SidLabel } catch { }
            $sel = Get-SelectedProfile
            Out-Console "Ziel-Benutzer: $($pl.Suggest)$(if (-not $pl.Hit) { ' (noch kein Profil)' })" 'Info'
        }
    }
    # Konto ohne Profil, ohne Domaene eingetragen: als <Ziel-PC>\<Name> fuehren (USMT-Zuordnung und Profilsuche danach)
    if ($sel.NoProfile -and "$($sel.Account)" -notmatch '\\') {
        $ui.cmbUser.SelectedIndex = -1; $ui.cmbUser.Text = "$tpc\$($sel.Account)"
        try { Update-SidLabel } catch { }
        $sel = Get-SelectedProfile
    }
    if (-not $sel.NoProfile -or -not (Test-HMLocalTargetAccount "$($sel.Account)" $tpc)) { return $true }
    # lokales Konto ohne Profil: gibt es das Konto am Ziel?
    $name = ("$($sel.Account)" -split '\\')[-1]
    $have = $null
    try { $have = Invoke-HMTarget $tctx { param($n) if (-not (Get-Command Get-LocalUser -ErrorAction SilentlyContinue)) { return $null }; [bool](Get-LocalUser -Name $n -ErrorAction SilentlyContinue) } @($name) } catch { $have = $null }
    if ($have -eq $true) { return $true }
    if ($null -eq $have) { Out-Console "Lokale Konten an $Computer nicht pruefbar - ist '$name' dort nicht vorhanden, legt USMT kein Profil an (Code 14)." 'Warning'; return $true }
    $m = "Das lokale Konto '$name' gibt es an $tpc noch nicht.`n`nUSMT legt fehlende lokale Konten nicht an (dafuer muesste das Kennwort im Klartext auf der Befehlszeile stehen, und Programm-Einstellungen wuerden nicht uebertragen).`n`nJa = Konto jetzt anlegen (Kennwort eingeben)`nNein = nicht anlegen (nur Computer-Module, Benutzer-Module werden uebersprungen)`nAbbrechen = nichts tun"
    $a = "$((Show-HMDialogBox -Owner $script:Window -Text $m -Title 'Restore - lokales Konto' -Mode 'YesNoCancel' -Icon 'Question' -Default 'Yes'))"
    if ($a -eq 'Cancel') { return $false }
    if ($a -ne 'Yes') { return $true }
    $d = Show-HMNewLocalAccountDialog $name $tpc
    if (-not $d) { return $false }
    $r = ''
    try {
        $r = "$(Invoke-HMTarget $tctx {
            param($n, $pw, $adm)
            try {
                $u = New-LocalUser -Name $n -Password $pw -AccountNeverExpires -ErrorAction Stop
                try { Add-LocalGroupMember -SID 'S-1-5-32-545' -Member $u -ErrorAction Stop } catch { if ("$($_.FullyQualifiedErrorId)" -notlike '*MemberExists*') { throw } }
                if ($adm) { Add-LocalGroupMember -SID 'S-1-5-32-544' -Member $u -ErrorAction Stop }
                'OK'
            } catch { "FEHLER $($_.Exception.Message)" }
        } @($name, $d.Password, $d.Admin))"
    } catch { $r = "FEHLER $($_.Exception.Message)" }
    finally { try { $d.Password.Dispose() } catch { } }
    if ($r -ne 'OK') { Out-Console "Lokales Konto '$name' an $tpc nicht angelegt: $($r -replace '^FEHLER ', '')" 'Error'; return $false }
    Out-Console "Lokales Konto '$name' an $tpc angelegt$(if ($d.Admin) { ' (Administratoren)' } else { ' (Benutzer)' })." 'Success'
    if (-not @($Modules | Where-Object { $_.Id -eq 'Usmt' }).Count) { Out-Console "   Ohne Modul 'Windows-Einstellungen (USMT)' hat '$name' noch kein Profil: einmal mit dem Konto anmelden und abmelden, dann Restore - oder USMT mitwaehlen." 'Warning' }
    return $true
}

# ----------------------------------------------------------------------------
# Backup pruefen / Katalog erstellen
# ----------------------------------------------------------------------------
function Start-HMVerifyBackup([bool]$CreateCatalog) {
    $b = $script:SelectedBackup
    if (-not $b) { Out-Console 'Bitte zuerst ein Backup waehlen.' 'Warning'; return }
    $ctx = New-BaseCtx
    $ctx.Backup = $b
    Out-Separator
    if ($CreateCatalog) {
        $has = Test-Path -LiteralPath (Join-Path $b.Path 'Pruefsummen.tsv')
        if (-not (Confirm-Action "Pruefsummen-Katalog fuer '$($b.Name)' $(if ($has) { 'aktualisieren' } else { 'erstellen' })?`n`nACHTUNG: Der Katalog beschreibt den HEUTIGEN Stand der Dateien - eine Beschaedigung, die schon besteht, wird so nicht erkannt.`nDauer: je nach Groesse einige Minuten." 'Pruefsummen-Katalog')) { return }
        Start-EngineJob -Command 'Start-HMCatalogUpdate -Ctx $Ctx -Job $Job' -Ctx $ctx -Title 'Pruefsummen-Katalog' -OnFinished { param($j) Update-BackupList }
        return
    }
    Start-EngineJob -Command 'Test-HMBackupCatalog -Ctx $Ctx -Job $Job' -Ctx $ctx -Title 'Backup pruefen' -OnFinished {
        param($j)
        $r = $j.Result
        if (-not $r) { return }
        if ($r.Status -eq 'NoCatalog') { Out-Console 'Tipp: Rechtsklick auf "Backup pruefen" erstellt einen Katalog (Stand heute).' 'Info'; return }
        $probs = @($r.Problems)
        if ($probs.Count) {
            $rows = New-Object System.Collections.Generic.List[object]
            foreach ($x in $probs) { $rows.Add(@($x.Status, $x.Pfad, $x.Detail)) }
            Show-DataGridWindow -Title "Backup-Pruefung - $($script:SelectedBackup.Name)" -Columns @('Status', 'Pfad', 'Detail') -Rows $rows.ToArray() -Sort 'Status ASC, Pfad ASC' -CountText "$($r.Summary)" -Width 1200 -Height 560
        }
        Update-BackupList
    }
}

# ----------------------------------------------------------------------------
# Zwei Backups vergleichen
# ----------------------------------------------------------------------------
function Get-HMBackupDate($b) {
    $d = [datetime]::MinValue
    if ($null -eq $b) { return [datetime]::MinValue }
    if ($b.Created -and [datetime]::TryParse("$($b.Created)", [ref]$d)) { return $d }
    if (-not "$($b.Path)") { return [datetime]::MinValue }
    try { return (Get-Item -LiteralPath $b.Path -ErrorAction Stop).LastWriteTime } catch { return [datetime]::MinValue }
}
function Start-HMCompareBackups {
    $a = $script:SelectedBackup
    if (-not $a) { Out-Console 'Bitte zuerst ein Backup markieren.' 'Warning'; return }
    $others = @($script:BackupInfos | Where-Object { $_.Path -ne $a.Path })
    if (-not $others.Count) { Out-Console 'Kein zweites Backup im Backup-Ordner.' 'Warning'; return }
    $lab = { param($x) "{0}  |  {1}  |  {2}  |  {3}" -f (Get-HMBackupDate $x).ToString('yyyy-MM-dd HH:mm'), $x.Computer, $(if ($x.Account) { $x.Account } else { $x.User }), $x.Name }
    $labels = @($others | Sort-Object { Get-HMBackupDate $_ } -Descending | ForEach-Object { & $lab $_ })
    $same = @($others | Where-Object { ($a.Sid -and $_.Sid -eq $a.Sid) -or (-not $a.Sid -and $_.User -eq $a.User) } | Sort-Object { Get-HMBackupDate $_ } -Descending) | Select-Object -First 1
    $f = Show-HMFormDialog -Title 'Backups vergleichen' -OkText 'Vergleichen' -Width 760 -Fields @(
        @{ Type = 'Info'; Label = "Backup A: $(& $lab $a)"; Color = '#FFCDD6F4' }
        @{ Name = 'Other'; Label = 'Vergleichen mit Backup B:'; Type = 'Combo'; Items = $labels; Default = $(if ($same) { & $lab $same } else { $null }) }
        @{ Type = 'Info'; Label = 'Das aeltere Backup wird als A, das neuere als B gewertet. Mit Pruefsummen-Katalog in beiden wird per SHA-256 verglichen, sonst per Groesse und Aenderungszeit.' }
    )
    if (-not $f) { return }
    $o = @($others | Where-Object { (& $lab $_) -eq $f.Other })[0]
    if (-not $o) { return }
    $older = if ((Get-HMBackupDate $o) -lt (Get-HMBackupDate $a)) { $o } else { $a }
    $newer = if ($older.Path -eq $a.Path) { $o } else { $a }
    $ctx = New-BaseCtx
    $ctx.CompareA = $older.Path; $ctx.CompareB = $newer.Path
    $script:CompareTitle = "A = $($older.Name)   B = $($newer.Name)"
    Out-Separator
    Start-EngineJob -Command 'Compare-HMBackups -Ctx $Ctx -Job $Job' -Ctx $ctx -Title 'Backups vergleichen' -OnFinished {
        param($j)
        $r = $j.Result
        if (-not $r) { return }
        $rows = New-Object System.Collections.Generic.List[object]
        foreach ($x in @($r.Rows)) { $rows.Add(@($x.Status, $x.Pfad, $x.GroesseA, $x.GroesseB, $x.ZeitA, $x.ZeitB)) }
        if (-not $rows.Count) { Out-Console 'Die Backups sind (im Dateiteil) identisch.' 'Success'; return }
        Show-DataGridWindow -Title "Vergleich - $($script:CompareTitle)" -Columns @('Status', 'Pfad', 'Groesse A', 'Groesse B', 'Zeit A', 'Zeit B') `
            -ColumnTypes @{ 'Groesse A' = [long]; 'Groesse B' = [long]; 'Zeit A' = [datetime]; 'Zeit B' = [datetime] } -Rows $rows.ToArray() -Sort 'Status ASC, Pfad ASC' -CountText $r.Summary -Width 1300 -Height 640
    }
}

# ----------------------------------------------------------------------------
# Restore-Vorschau
# ----------------------------------------------------------------------------
function Start-HMRestorePreviewUi {
    $ctx = New-HMRestoreCtx
    if (-not $ctx) { return }
    Out-Separator
    Start-EngineJob -Command 'Get-HMRestorePreview -Ctx $Ctx -Job $Job' -Ctx $ctx -Title 'Restore-Vorschau' -OnFinished {
        param($j)
        $r = $j.Result
        if (-not $r) { return }
        $rows = New-Object System.Collections.Generic.List[object]
        foreach ($x in @($r.Rows)) { $rows.Add(@($x.Aktion, $x.Modul, $x.Ziel, $x.Groesse, $x.Backup, $x.Ziel_Datei)) }
        $sum = "$($r.Summary)"
        $b = $script:SelectedBackup
        if ($b -and $b.Manifest -and $b.Manifest.Deleted -and [int]$b.Manifest.Deleted.Files -gt 0) { $sum += " | $([int]$b.Manifest.Deleted.Files) beiseitegelegte (am Quell-PC geloeschte) Dateien werden nicht zurueckgespielt" }
        if (-not $rows.Count) { Out-Console "Vorschau: am Ziel ist alles bereits gleich (nichts zu tun).$(if ($sum -ne "$($r.Summary)") { $sum.Substring("$($r.Summary)".Length) })" 'Success'; return }
        Show-DataGridWindow -Title 'Restore-Vorschau' -Columns @('Aktion', 'Modul', 'Ziel', 'Groesse', 'Stand Backup', 'Stand Ziel') `
            -ColumnTypes @{ Groesse = [long]; 'Stand Backup' = [datetime]; 'Stand Ziel' = [datetime] } -Rows $rows.ToArray() -Sort 'Aktion ASC, Ziel ASC' -CountText $sum -Width 1300 -Height 640
    }
}

# ----------------------------------------------------------------------------
# Checkliste nach dem Restore (landet im Restore-Protokoll)
# ----------------------------------------------------------------------------
function Show-HMChecklist([string]$ReportPath, [string[]]$Extra = @()) {
    if (-not $ReportPath) {
        $b = $script:SelectedBackup
        if (-not $b) { Out-Console 'Bitte zuerst ein Backup markieren.' 'Warning'; return }
        $rp = @(Get-ChildItem -LiteralPath $b.Path -Filter 'Bericht_Restore_*.html' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
        if (-not $rp.Count) { Out-Console 'Zu diesem Backup gibt es noch kein Restore-Protokoll - die Checkliste gehoert zum Restore.' 'Info'; return }
        $ReportPath = $rp[0].FullName
        if (Get-Command Get-HMAppAfterSteps -ErrorAction SilentlyContinue) { $Extra = @(Get-HMAppAfterSteps $b) }
    }
    $jsonPath = [System.IO.Path]::ChangeExtension($ReportPath, '.checkliste.json')
    $prev = $null
    if (Test-Path -LiteralPath $jsonPath) { try { $prev = Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { } }
    $items = @(@($script:Settings.RestoreChecklist) + @($Extra) | Where-Object { "$_".Trim() } | Select-Object -Unique)
    if ($prev) { foreach ($pi in @($prev.Items)) { if ($items -notcontains $pi.Text) { $items += $pi.Text } } }
    $x = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Checkliste nach dem Restore" Width="640" Height="620" WindowStartupLocation="CenterOwner" Background="#FF1E1E2E">
  <DockPanel Margin="14">
    <TextBlock DockPanel.Dock="Top" x:Name="head" Foreground="#FFCDD6F4" TextWrapping="Wrap" Margin="0,0,0,8"/>
    <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,8,0,0">
      <Button x:Name="all" Content="Alle erledigt" Width="110" Height="28" Background="#FF45475A" Foreground="#FFCDD6F4" Margin="0,0,6,0"/>
      <Button x:Name="ok" Content="Ins Protokoll uebernehmen" Width="190" Height="28" Background="#FFA6E3A1" Foreground="#FF1E1E2E" FontWeight="SemiBold" Margin="0,0,6,0"/>
      <Button x:Name="cancel" Content="Abbrechen" Width="100" Height="28" Background="#FF45475A" Foreground="#FFCDD6F4" IsCancel="True"/>
    </StackPanel>
    <DockPanel DockPanel.Dock="Bottom" Margin="0,8,0,0">
      <TextBlock DockPanel.Dock="Top" Text="Bemerkung:" Foreground="#FFA6ADC8" Margin="0,0,0,2"/>
      <TextBox x:Name="note" Height="60" AcceptsReturn="True" TextWrapping="Wrap" Background="#FF313244" Foreground="#FFCDD6F4" BorderBrush="#FF585B70" CaretBrush="#FFCDD6F4"/>
    </DockPanel>
    <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="pnl"/></ScrollViewer>
  </DockPanel>
</Window>
"@
    $w = [System.Windows.Markup.XamlReader]::Parse($x)
    if ($script:AppIcon) { $w.Icon = $script:AppIcon }
    $w.Owner = $script:Window; Set-HMWindowScale $w
    $w.FindName('head').Text = "Protokoll: $(Split-Path $ReportPath -Leaf)`nErledigtes abhaken - Stand und Bemerkung werden ins Restore-Protokoll geschrieben (kann spaeter ergaenzt werden)."
    $pnl = $w.FindName('pnl')
    $fg = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString('#FFCDD6F4'))
    $boxes = New-Object System.Collections.Generic.List[object]
    foreach ($t in $items) {
        $c = New-Object System.Windows.Controls.CheckBox
        $c.Content = "$t"; $c.Foreground = $fg; $c.Margin = [System.Windows.Thickness]::new(0, 3, 0, 3)
        if ($prev) { $pi = @($prev.Items | Where-Object { $_.Text -eq "$t" })[0]; if ($pi) { $c.IsChecked = [bool]$pi.Done } }
        [void]$pnl.Children.Add($c); $boxes.Add($c)
    }
    $noteBox = $w.FindName('note')
    if ($prev) { $noteBox.Text = "$($prev.Note)" }
    $res = @{ Ok = $false }
    $w.FindName('all').Add_Click({ foreach ($c in $boxes) { $c.IsChecked = $true } }.GetNewClosure())
    $w.FindName('ok').Add_Click({ $res.Ok = $true; $w.DialogResult = $true }.GetNewClosure())
    if ($w.ShowDialog() -ne $true -or -not $res.Ok) { return }
    $state = [pscustomobject]@{
        Date = (Get-Date).ToString('yyyy-MM-dd HH:mm'); By = "$env:USERDOMAIN\$env:USERNAME"; Note = "$($noteBox.Text)"
        Items = @(foreach ($c in $boxes) { [pscustomobject]@{ Text = "$($c.Content)"; Done = [bool]$c.IsChecked } })
    }
    try { $state | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $jsonPath -Encoding UTF8 } catch { }
    try {
        $html = [System.IO.File]::ReadAllText($ReportPath)
        $html = [regex]::Replace($html, '(?s)<!--HM-CHECKLIST-START-->.*?<!--HM-CHECKLIST-END-->', '')
        $enc = { param($s) [System.Net.WebUtility]::HtmlEncode("$s") }
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append('<!--HM-CHECKLIST-START--><h2 style="font-size:16px">Checkliste nach dem Restore</h2><table><tr><th style="width:60px">Erledigt</th><th>Punkt</th></tr>')
        foreach ($i in $state.Items) { [void]$sb.Append('<tr><td style="text-align:center;font-weight:600;color:' + $(if ($i.Done) { '#2e7d32">&#10004;' } else { '#c62828">&#10008;' }) + '</td><td>' + (& $enc $i.Text) + '</td></tr>') }
        [void]$sb.Append('</table>')
        if ($state.Note) { [void]$sb.Append('<p><b>Bemerkung:</b> ' + ((& $enc $state.Note) -replace "`r?`n", '<br>') + '</p>') }
        [void]$sb.Append('<p><small>Stand ' + (& $enc $state.Date) + ' - ' + (& $enc $state.By) + '</small></p><!--HM-CHECKLIST-END-->')
        $marker = '<div class="sig">'
        if ($html.Contains($marker)) { $i0 = $html.IndexOf($marker); $html = $html.Substring(0, $i0) + $sb.ToString() + $html.Substring($i0) }
        else { $html = $html.Replace('</body>', $sb.ToString() + '</body>') }
        [System.IO.File]::WriteAllText($ReportPath, $html, (New-Object System.Text.UTF8Encoding $true))
        $done = @($state.Items | Where-Object { $_.Done }).Count
        Out-Console "Checkliste gespeichert ($done von $(@($state.Items).Count) erledigt) - im Protokoll: $ReportPath" $(if ($done -eq @($state.Items).Count) { 'Success' } else { 'Warning' })
    } catch { Out-Console "Checkliste konnte nicht ins Protokoll geschrieben werden: $($_.Exception.Message)" 'Error' }
}

# ----------------------------------------------------------------------------
# Aufbewahrung: neueste N je PC + Benutzer behalten, aeltere nach X Tagen vorschlagen
# Archiv-Backups zaehlen nicht mit und werden nie vorgeschlagen
# ----------------------------------------------------------------------------
function Get-HMRetentionCandidates {
    param([object[]]$Backups, [int]$Days, [int]$Keep)
    $now = Get-Date
    $out = New-Object System.Collections.Generic.List[object]
    $groups = @{}
    foreach ($b in @($Backups)) {
        if (-not $b -or $b.Archived) { continue }
        $k = ("{0}|{1}" -f $b.Computer, $(if ($b.Sid) { $b.Sid } else { $b.User })).ToUpperInvariant()
        if (-not $groups.ContainsKey($k)) { $groups[$k] = New-Object System.Collections.Generic.List[object] }
        $groups[$k].Add($b)
    }
    # Gezaehlt werden nur brauchbare Backups (OK/Warnung, alte Ordnerstruktur). Das neueste brauchbare je Gruppe bleibt immer.
    # Abgebrochene/fehlgeschlagene werden nur vorgeschlagen, wenn es ein neueres brauchbares gibt; laufende ('Running') nie.
    if ($Keep -le 0 -and $Days -le 0) { return @() }
    foreach ($k in $groups.Keys) {
        $rank = 0
        foreach ($b in @($groups[$k] | Sort-Object { Get-HMBackupDate $_ } -Descending)) {
            $age = [int]($now - (Get-HMBackupDate $b)).TotalDays
            $good = (Test-HMBackupUsable $b)
            if ($good) {
                $rank++
                if ($rank -eq 1) { continue }
                if ($Keep -gt 0 -and $rank -le $Keep) { continue }
            } else {
                if ("$($b.Status)" -eq 'Running' -or $rank -eq 0) { continue }
            }
            if ($Days -gt 0 -and $age -le $Days) { continue }
            $out.Add([pscustomobject]@{ Backup = $b; Rank = $(if ($good) { $rank } else { 0 }); Age = $age; Usable = $good })
        }
    }
    return $out.ToArray()
}
# Brauchbares Backup: abgeschlossen mit OK oder Warnung (oder alte Ordnerstruktur ohne Manifest)
function Test-HMBackupUsable($b) { return ([bool]$b.Legacy -or "$($b.Status)" -in @('OK', 'Warning')) }
function Format-HMBackupStatus($b) {
    if ($b.Legacy) { return 'alt (ohne Manifest)' }
    switch ("$($b.Status)") { 'OK' { 'OK' } 'Warning' { 'Warnung' } 'Error' { 'FEHLER' } 'Cancelled' { 'abgebrochen' } 'Running' { 'laeuft/unvollstaendig' } default { "unbekannt ($($b.Status))" } }
}
function Start-HMRetentionCleanup {
    if ($script:MultiDelBusy) { Out-Console 'Waehrend Backups geloescht werden, nicht moeglich - bitte nach Abschluss.' 'Warning'; return }
    Update-BackupList
    $days = [int]$script:Settings.RetentionDays
    $keep = [int]$script:Settings.RetentionKeepPerUser
    if ($days -le 0 -and $keep -le 0) { Out-Console 'Aufbewahrung ist aus (Einstellungen > Allgemein: Tage und Anzahl = 0).' 'Info'; return }
    $cand = @(Get-HMRetentionCandidates -Backups $script:BackupInfos -Days $days -Keep $keep)
    $rule = "Regel: je PC + Benutzer die neuesten $keep behalten$(if ($days -gt 0) { ", aeltere loeschen, wenn aelter als $days Tage" } else { ', aeltere loeschen' })"
    if (-not $cand.Count) { Out-Console "Nichts zu loeschen. $rule" 'Success'; return }
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($c in $cand) { $b = $c.Backup; $rows.Add(@((Get-HMBackupDate $b).ToString('yyyy-MM-dd HH:mm'), "$($b.Computer)", "$(if ($b.Account) { $b.Account } else { $b.User })", (Format-HMBackupStatus $b), [int]$c.Rank, [int]$c.Age, $(if ($b.SizeBytes) { [math]::Round($b.SizeBytes / 1GB, 2) } else { $null }), "$($b.Name)")) }
    $rule += ' (gezaehlt werden nur brauchbare Backups - OK/Warnung; das neueste brauchbare bleibt immer; abgebrochene/fehlerhafte nur, wenn es ein neueres brauchbares gibt; Nr. 0 = nicht brauchbar)'
    Show-DataGridWindow -Title 'Alte Backups (Aufbewahrung)' -Columns @('Datum', 'Computer', 'Benutzer', 'Status', 'Nr. (neueste = 1)', 'Alter (Tage)', 'GB', 'Ordner') `
        -ColumnTypes @{ 'Nr. (neueste = 1)' = [int]; 'Alter (Tage)' = [int]; GB = [double] } -Rows $rows.ToArray() -Sort 'Computer ASC, Benutzer ASC, Datum DESC' -Width 1100 -Height 520 `
        -CountText "$($rows.Count) Backups zum Loeschen vorgeschlagen - $rule" -ActionContext @{ Root = (Get-BackupRoot) } -Actions @(
            @{ Text = 'Alle vorgeschlagenen loeschen'; Color = '#FFF38BA8'; NoSelection = $true; Handler = { param($rows, $win, $ctx) Remove-HMBackupFolders $win $ctx.Root $null } }
            @{ Text = 'Markierte loeschen'; Color = '#FFFAB387'; Handler = { param($rows, $win, $ctx) Remove-HMBackupFolders $win $ctx.Root @($rows | ForEach-Object { "$($_.Ordner)" }) } }
        )
}
function Remove-HMBackupFolders($Win, [string]$Root, [string[]]$Names) {
    if ($null -eq $Names) {
        $cand = @(Get-HMRetentionCandidates -Backups $script:BackupInfos -Days ([int]$script:Settings.RetentionDays) -Keep ([int]$script:Settings.RetentionKeepPerUser))
        $Names = @($cand | ForEach-Object { $_.Backup.Name })
    }
    $Names = @($Names | Where-Object { $_ -and $_ -notmatch '[\\/]' -and $_ -ne '..' })
    if (-not $Names.Count) { return }
    # Loeschen ist endgueltig -> immer nachfragen, mit Status je Backup
    $info = @{}; foreach ($b in @($script:BackupInfos)) { if ($b) { $info["$($b.Name)"] = $b } }
    $lines = @($Names | ForEach-Object { if ($info.ContainsKey($_)) { "$_  ($(Format-HMBackupStatus $info[$_]))" } else { $_ } })
    $list = (($lines | Select-Object -First 15) -join "`n") + $(if ($lines.Count -gt 15) { "`n..." } else { '' })
    # Schutz: ist darunter das neueste brauchbare Backup eines PCs/Benutzers, extra warnen
    $newest = @{}
    foreach ($b in @($script:BackupInfos | Where-Object { $_ -and (Test-HMBackupUsable $_) })) {
        $k = ("{0}|{1}" -f $b.Computer, $(if ($b.Sid) { $b.Sid } else { $b.User })).ToUpperInvariant()
        if (-not $newest.ContainsKey($k) -or (Get-HMBackupDate $b) -gt (Get-HMBackupDate $newest[$k])) { $newest[$k] = $b }
    }
    $last = @($newest.Values | Where-Object { $Names -contains "$($_.Name)" } | ForEach-Object { "$($_.Name)" })
    if ($last.Count) { $list += "`n`nACHTUNG - das ist das NEUESTE brauchbare Backup dieses PCs/Benutzers:`n$($last -join "`n")" }
    if ("$((Show-HMDialogBox -Owner $Win -Text ("$($Names.Count) Backup(s) endgueltig loeschen?`n`n$list") -Title 'Backups loeschen' -Mode 'YesNo' -Icon 'Warning'))" -ne 'Yes') { return }
    $Win.Close()
    $paths = @($Names | ForEach-Object { Join-Path $Root $_ })
    Out-Console "Loesche $($paths.Count) Backup(s) ..." 'Warning'
    Invoke-AsyncCommand -ScriptBlock { param($eng, $list) . $eng; foreach ($p in $list) { $r = Remove-HMBackupFolder $p; if ($r -eq 'OK') { "OK $p" } else { "$($r -replace '^FEHLER: ', "FEHLER $p : ")" } } } -ArgumentList @($script:Engine, $paths) -TimeoutSec 7200 -OnComplete {
        param($r) foreach ($l in @($r)) { Out-Console "$l" $(if ("$l" -like 'OK*') { 'Success' } else { 'Error' }) }; $script:SelectedBackup = $null; Update-BackupList; Update-BackupRootInfo; Update-HMBackupOverview -Quiet
    }
}

# ----------------------------------------------------------------------------
# HTML-Uebersicht aller Backups (Backups.html im Backup-Ordner)
# ----------------------------------------------------------------------------
function Update-HMBackupOverview([switch]$Open, [switch]$Quiet) {
    $root = Get-BackupRoot
    if (-not (Test-Path -LiteralPath $root)) { return }
    try {
        $list = @(Get-HMBackupList -Root $root -Modules $script:Modules)
        $enc = { param($s) [System.Net.WebUtility]::HtmlEncode("$s") }
        $logo = ''
        $lp = Join-Path $script:AppRoot 'Assets\logo64.png'
        if (Test-Path -LiteralPath $lp) { $logo = '<img src="data:image/png;base64,' + [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($lp)) + '" alt="">' }
        $total = [long]0; foreach ($b in $list) { $total += [long]$b.SizeBytes }
        $col = @{ OK = '#2e7d32'; Warning = '#b26a00'; Error = '#c62828'; Cancelled = '#c62828'; Running = '#1565c0'; Legacy = '#777' }
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append('<!DOCTYPE html><html lang="de"><head><meta charset="utf-8"><title>HUMig - Backup-Uebersicht</title><style>')
        [void]$sb.Append('body{font-family:Segoe UI,Arial,sans-serif;margin:20px;color:#222}header{display:flex;gap:14px;align-items:center;border-bottom:2px solid #444;padding-bottom:8px;margin-bottom:12px}h1{font-size:20px;margin:0}')
        [void]$sb.Append('input{padding:6px 8px;width:320px;margin:6px 0 10px}table{border-collapse:collapse;width:100%}td,th{border:1px solid #ccc;padding:4px 7px;font-size:13px;text-align:left}th{background:#eee;cursor:pointer;user-select:none}')
        [void]$sb.Append('tr:nth-child(even){background:#fafafa}.st{font-weight:600}small{color:#666}a{color:#1565c0}</style></head><body>')
        [void]$sb.Append('<header>' + $logo + '<div><h1>HUMig - Backup-Uebersicht</h1><div>' + (& $enc $root) + '</div></div></header>')
        [void]$sb.Append('<div>' + $list.Count + ' Backups, zusammen ' + (& $enc (Format-HMSize $total)) + ' - Stand ' + (Get-Date).ToString('dd.MM.yyyy HH:mm') + '</div>')
        [void]$sb.Append('<input id="f" placeholder="Filter (Computer, Benutzer, Status ...)" oninput="flt()"><table id="t"><thead><tr>')
        foreach ($h in @('Datum', 'Computer', 'Benutzer', 'Groesse', 'Status', 'Module', 'Pruefung', 'Katalog / letzte Kontrolle', 'Durchlaeufe', 'Protokoll')) { [void]$sb.Append('<th onclick="srt(this)">' + $h + '</th>') }
        [void]$sb.Append('</tr></thead><tbody>')
        foreach ($b in @($list | Sort-Object { Get-HMBackupDate $_ } -Descending)) {
            $m = $b.Manifest
            $st = "$($b.Status)"; $c = if ($col.ContainsKey($st)) { $col[$st] } else { '#222' }
            if ($b.Archived) { $st += ' - Archiv' }
            $ver = if ($m -and $m.Verify) { "$($m.Verify.Sampled) geprueft, $(@($m.Verify.HashMismatch | Where-Object { $_ }).Count) Abw." } else { '' }
            $cat = if ($m -and $m.Catalog) { "$($m.Catalog.Files) Dateien" } else { '-' }
            if ($m -and $m.LastCheck) { $cat += " / $($m.LastCheck.Date): $($m.LastCheck.Status)" }
            $runs = if ($m -and $m.Increments) { @($m.Increments).Count + 1 } else { 1 }
            $rep = @(Get-ChildItem -LiteralPath $b.Path -Filter 'Bericht_*.html' -File -ErrorAction SilentlyContinue | Sort-Object Name)
            $links = @(foreach ($r in $rep) { '<a href="' + [Uri]::EscapeUriString(($b.Name + '/' + $r.Name)) + '">' + (& $enc ($r.BaseName -replace '^Bericht_', '' -replace '_', ' ')) + '</a>' }) -join '<br>'
            [void]$sb.Append('<tr><td>' + (& $enc (Get-HMBackupDate $b).ToString('yyyy-MM-dd HH:mm')) + '</td><td>' + (& $enc $b.Computer) + '</td><td>' + (& $enc $(if ($b.Account) { $b.Account } else { $b.User })) + '</td>')
            [void]$sb.Append('<td data-v="' + [long]$b.SizeBytes + '">' + (& $enc $(if ($b.SizeBytes) { Format-HMSize $b.SizeBytes } else { '' })) + '</td><td class="st" style="color:' + $c + '">' + (& $enc $st) + '</td><td>' + @($b.Modules).Count + '</td>')
            [void]$sb.Append('<td>' + (& $enc $ver) + '</td><td>' + (& $enc $cat) + '</td><td>' + $runs + '</td><td>' + $links + '</td></tr>')
        }
        [void]$sb.Append('</tbody></table><p><small>Erstellt mit HUMig ' + (& $enc $script:Version) + ' - wird nach jedem Backup automatisch aktualisiert.</small></p>')
        [void]$sb.Append('<script>function flt(){var q=document.getElementById("f").value.toLowerCase();document.querySelectorAll("#t tbody tr").forEach(function(r){r.style.display=r.innerText.toLowerCase().indexOf(q)>=0?"":"none"})}')
        [void]$sb.Append('function srt(th){var i=Array.prototype.indexOf.call(th.parentNode.children,th),tb=document.querySelector("#t tbody"),rs=Array.prototype.slice.call(tb.rows),d=th.dataset.d=th.dataset.d=="1"?"0":"1";')
        [void]$sb.Append('rs.sort(function(a,b){var x=a.cells[i],y=b.cells[i],p=x.dataset.v!==undefined?+x.dataset.v:x.innerText,q=y.dataset.v!==undefined?+y.dataset.v:y.innerText;return (p>q?1:p<q?-1:0)*(d=="1"?1:-1)});rs.forEach(function(r){tb.appendChild(r)})}</script></body></html>')
        $file = Join-Path $root 'Backups.html'
        [System.IO.File]::WriteAllText($file, $sb.ToString(), (New-Object System.Text.UTF8Encoding $true))
        if (-not $Quiet) { Out-Console "Uebersicht: $file" 'Success' }
        if ($Open) { Open-HMFile $file }
    } catch { if (-not $Quiet) { Out-Console "Uebersicht fehlgeschlagen: $($_.Exception.Message)" 'Error' } }
}
