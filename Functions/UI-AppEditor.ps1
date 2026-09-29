#Requires -Version 5.1
<#
.SYNOPSIS
    Katalog-Editor: Programm-Katalog (Config\apps.default.json + Config\apps.json) in einem Fenster bearbeiten.
.DESCRIPTION
    Links alle Eintraege (Suche, Filter), rechts Reiter Allgemein / Sichern / Schliessen & Dienste / Hinweise / Quelle.
    Gespeichert wird NUR in Config\apps.json (vorher Sicherung apps.json.bak); apps.default.json bleibt unveraendert.
    Ein bearbeiteter Standard-Eintrag wird als vollstaendige Kopie mit gleicher Id in apps.json abgelegt.
    Tests am verbundenen PC: Erkennung (Detect), Paket, Pfad/Registry vorhanden + Groesse, laufende Prozesse, Dienste.
.NOTES
    Wird im UI-Thread geladen (dot-source aus HUMig.ps1). Handler ohne GetNewClosure (Skript-Funktionen bleiben sichtbar),
    Zustand in $script:Ae. Zielmaschine der Tests: der oben gewaehlte PC.
#>

$script:Ae = $null
$script:AeTokens = @('PROFILE', 'APPDATA', 'LOCALAPPDATA', 'SYSTEMDRIVE', 'WINDIR', 'PROGRAMDATA', 'PROGRAMFILES', 'PROGRAMFILESX86', 'PUBLIC')
$script:AeRoles = @('', 'Settings', 'Plugins', 'Data', 'Database', 'License', 'Template')
$script:AeRoleNames = @{ '' = '(keine)'; Settings = 'Einstellungen'; Plugins = 'Plug-ins/Add-ins'; Data = 'Daten'; Database = 'Datenbank'; License = 'Lizenz'; Template = 'Vorlagen' }

# ----------------------------------------------------------------------------
# Daten: JSON <-> bearbeitbare Eintraege (geordnete Hashtables)
# ----------------------------------------------------------------------------
function Get-HMAeList($v) { return @(@($v) | Where-Object { $null -ne $_ -and "$_".Trim() -ne '' } | ForEach-Object { "$_".Trim() }) }
function ConvertTo-HMAeItem($i) {
    $h = [ordered]@{}
    foreach ($k in @('Type', 'Name', 'Role', 'Path', 'Key', 'DbKind')) { $h[$k] = "$($i.$k)" }
    foreach ($k in @('Filter', 'XD', 'XF')) { $h[$k] = @(Get-HMAeList $i.$k) }
    $h.NoHidden = [bool]$i.NoHidden
    $h.License = [bool]$i.License
    # unbekannte Felder (z.B. Exceptions, Legacy) unveraendert behalten
    $h.Extra = [ordered]@{}
    foreach ($p in @($i.PSObject.Properties)) { if ($p.Name -notin @('Type', 'Name', 'Role', 'Path', 'Key', 'DbKind', 'Filter', 'XD', 'XF', 'NoHidden', 'License')) { $h.Extra[$p.Name] = $p.Value } }
    return $h
}
function ConvertTo-HMAeEntry($a) {
    $e = [ordered]@{}
    foreach ($k in @('Id', 'Name', 'Detect', 'Package', 'Transfer', 'NotTransfer', 'License', 'Version')) { $e[$k] = "$($a.$k)" }
    foreach ($k in @('Modules', 'After', 'CloseProcess', 'StopService')) { $e[$k] = @(Get-HMAeList $a.$k) }
    $e.Items = @(foreach ($i in @($a.Items | Where-Object { $_ })) { ConvertTo-HMAeItem $i })
    $e.VDate = ''; $e.VSources = @(); $e.VNote = ''
    if ($a.Verified) { $e.VDate = "$($a.Verified.Date)"; $e.VSources = @(Get-HMAeList $a.Verified.Sources); $e.VNote = "$($a.Verified.Note)" }
    $e.Extra = [ordered]@{}
    foreach ($p in @($a.PSObject.Properties)) { if ($p.Name -notin @('Id', 'Name', 'Detect', 'Package', 'Transfer', 'NotTransfer', 'License', 'Version', 'Modules', 'After', 'CloseProcess', 'StopService', 'Items', 'Verified')) { $e.Extra[$p.Name] = $p.Value } }
    return $e
}
# Eintrag -> Objekt fuer apps.json (leere Felder weglassen, Reihenfolge fest)
function ConvertFrom-HMAeEntry($e) {
    $o = [ordered]@{ Id = $e.Id; Name = $e.Name }
    if ($e.Detect) { $o.Detect = $e.Detect }
    if (@($e.Modules).Count) { $o.Modules = @($e.Modules) }
    if (@($e.Items).Count) {
        $o.Items = @(foreach ($i in $e.Items) {
            $x = [ordered]@{ Type = $i.Type; Name = $i.Name }
            if ($i.Type -eq 'Reg') { $x.Key = $i.Key } else { $x.Path = $i.Path }
            if ($i.Type -eq 'Files' -and @($i.Filter).Count) { $x.Filter = @($i.Filter) }
            if (@($i.XD).Count) { $x.XD = @($i.XD) }
            if (@($i.XF).Count) { $x.XF = @($i.XF) }
            if ($i.NoHidden) { $x.NoHidden = $true }
            if ($i.License) { $x.License = $true }
            if ($i.Role) { $x.Role = $i.Role }
            if ($i.Role -eq 'Database' -and $i.DbKind) { $x.DbKind = $i.DbKind }
            foreach ($k in @($i.Extra.Keys)) { $x[$k] = $i.Extra[$k] }
            [pscustomobject]$x
        })
    }
    foreach ($k in @('Transfer', 'NotTransfer', 'License', 'Version')) { if ($e[$k]) { $o[$k] = $e[$k] } }
    if (@($e.After).Count) { $o.After = @($e.After) }
    if ($e.Package) { $o.Package = $e.Package }
    if (@($e.CloseProcess).Count) { $o.CloseProcess = @($e.CloseProcess) }
    if (@($e.StopService).Count) { $o.StopService = @($e.StopService) }
    if ($e.VDate -or @($e.VSources).Count -or $e.VNote) {
        $v = [ordered]@{}
        if ($e.VDate) { $v.Date = $e.VDate }
        if (@($e.VSources).Count) { $v.Sources = @($e.VSources) }
        if ($e.VNote) { $v.Note = $e.VNote }
        $o.Verified = [pscustomobject]$v
    }
    foreach ($k in @($e.Extra.Keys)) { $o[$k] = $e.Extra[$k] }
    return [pscustomobject]$o
}
function Get-HMAeJson($e) { return ((ConvertFrom-HMAeEntry $e) | ConvertTo-Json -Depth 10 -Compress) }

# Katalog laden (Standard + eigene), Kennzeichen je Eintrag
function Import-HMAeData {
    $def = Read-JsonFile (Join-Path $script:ConfigDir 'apps.default.json')
    $loc = Read-JsonFile (Join-Path $script:ConfigDir 'apps.json')
    $script:Ae.DefaultIds = @(@($def.Apps) | Where-Object { $_ -and $_.Id } | ForEach-Object { "$($_.Id)" })
    $script:Ae.Default = @{}
    foreach ($a in @($def.Apps | Where-Object { $_ -and $_.Id })) { $script:Ae.Default["$($a.Id)"] = $a }
    $script:Ae.LocalObj = $loc
    $script:Ae.Local = [System.Collections.Generic.List[object]]::new()
    foreach ($a in @($loc.Apps | Where-Object { $_ -and $_.Id })) { $script:Ae.Local.Add($a) }
    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($id in $script:Ae.DefaultIds) {
        $l = @($script:Ae.Local | Where-Object { "$($_.Id)" -eq $id })[0]
        $list.Add([pscustomobject]@{ Id = $id; Kind = $(if ($l) { 'geaendert' } else { 'Standard' }); Obj = $(if ($l) { $l } else { $script:Ae.Default[$id] }) })
    }
    foreach ($l in $script:Ae.Local) { if ($script:Ae.DefaultIds -notcontains "$($l.Id)") { $list.Add([pscustomobject]@{ Id = "$($l.Id)"; Kind = 'eigen'; Obj = $l }) } }
    $script:Ae.All = @($list | Sort-Object { "$($_.Obj.Name)" })
}

# ----------------------------------------------------------------------------
# Hilfen: Token, Scope, Pruefung
# ----------------------------------------------------------------------------
function Get-HMAeScope($i) {
    if ($i.Type -eq 'Reg') { if ("$($i.Key)" -match '^HK(CU|EY_CURRENT_USER)') { return 'Benutzer' } else { return 'Maschine' } }
    if ("$($i.Path)" -match '^\{(PROFILE|APPDATA|LOCALAPPDATA)\}') { return 'Benutzer' }
    return 'Maschine'
}
# Lokalen Pfad in Token-Schreibweise umwandeln (laengster passender Ordner gewinnt)
function ConvertTo-HMAeToken([string]$Path) {
    $map = [System.Collections.Generic.List[object]]::new()
    $add = { param($t, $v) if ($v) { $map.Add([pscustomobject]@{ T = $t; V = "$v".TrimEnd('\') }) } }
    # Profil des gewaehlten Benutzers (Pfad am Ziel-PC, gilt auch remote)
    $p = Get-SelectedProfile
    if ($p -and $p.LocalPath -and -not $p.NoProfile) {
        $pp = "$($p.LocalPath)".TrimEnd('\')   # Pfad am Ziel-PC - kein Join-Path (Laufwerk muss hier nicht existieren)
        & $add 'PROFILE' $pp; & $add 'APPDATA' "$pp\AppData\Roaming"; & $add 'LOCALAPPDATA' "$pp\AppData\Local"
    }
    if (Test-HMIsLocal (Get-TargetComputer)) {
        & $add 'APPDATA' $env:APPDATA; & $add 'LOCALAPPDATA' $env:LOCALAPPDATA; & $add 'PROFILE' $env:USERPROFILE
        & $add 'PROGRAMFILESX86' ${env:ProgramFiles(x86)}; & $add 'PROGRAMFILES' $env:ProgramFiles; & $add 'PROGRAMDATA' $env:ProgramData
        & $add 'PUBLIC' $env:PUBLIC; & $add 'WINDIR' $env:windir; & $add 'SYSTEMDRIVE' $env:SystemDrive
    } else {
        # Remote-PC: Windows-Standardorte (Systemlaufwerk C:)
        & $add 'PROGRAMFILESX86' 'C:\Program Files (x86)'; & $add 'PROGRAMFILES' 'C:\Program Files'; & $add 'PROGRAMDATA' 'C:\ProgramData'
        & $add 'PUBLIC' 'C:\Users\Public'; & $add 'WINDIR' 'C:\Windows'; & $add 'SYSTEMDRIVE' 'C:'
    }
    foreach ($m in @($map | Sort-Object { $_.V.Length } -Descending)) {
        if ($Path.Equals($m.V, [StringComparison]::OrdinalIgnoreCase)) { return "{$($m.T)}" }
        if ($Path.StartsWith($m.V + '\', [StringComparison]::OrdinalIgnoreCase)) { return "{$($m.T)}" + $Path.Substring($m.V.Length) }
    }
    return $Path
}
# Eintrag pruefen. Rueckgabe: Liste von Fehlertexten (leer = OK)
function Test-HMAeEntry($e, [bool]$IsNew) {
    $err = [System.Collections.Generic.List[string]]::new()
    if ($e.Id -notmatch '^App_[A-Za-z0-9_\-]+$') { $err.Add("Id muss mit App_ beginnen und darf nur Buchstaben, Ziffern, _ und - enthalten ($($e.Id))") }
    elseif ($IsNew -and @($script:Ae.All | Where-Object { "$($_.Id)" -ieq $e.Id }).Count) { $err.Add("Id $($e.Id) gibt es schon") }
    if (-not "$($e.Name)".Trim()) { $err.Add('Name fehlt') }
    if (-not "$($e.Detect)".Trim()) { $err.Add('Erkennung (Detect) fehlt - ohne Erkennung wird das Programm nie eingeblendet') }
    else { try { if ([regex]::IsMatch('', "$($e.Detect)")) { $err.Add("Erkennung '$($e.Detect)' ist zu allgemein (passt auf jedes Programm) - Programmnamen eintragen, z.B. ^Mozilla Thunderbird") } } catch { } }
    foreach ($f in @('Detect', 'Package')) { if ("$($e[$f])".Trim()) { try { [void][regex]::new("$($e[$f])") } catch { $err.Add("$f ist kein gueltiger regulaerer Ausdruck: $($_.Exception.InnerException.Message)") } } }
    $known = @($script:Modules | ForEach-Object { "$($_.Id)" })
    foreach ($m in @($e.Modules)) { if ($known -notcontains $m) { $err.Add("Modul '$m' gibt es nicht") } }
    $names = @{}
    $n = 0
    foreach ($i in @($e.Items)) {
        $n++
        $lab = "Eintrag $n ($($i.Name))"
        if ($i.Type -notin @('Folder', 'Files', 'Reg')) { $err.Add("${lab}: Typ fehlt") }
        if ("$($i.Name)" -notmatch '^[A-Za-z0-9_\-]+$') { $err.Add("${lab}: Name nur Buchstaben, Ziffern, _ und - (wird Ordner im Backup)") }
        elseif ($names.ContainsKey("$($i.Name)".ToUpper())) { $err.Add("${lab}: Name doppelt") } else { $names["$($i.Name)".ToUpper()] = 1 }
        if ($i.Type -eq 'Reg') {
            if ("$($i.Key)" -notmatch '^(HKCU|HKLM|HKEY_CURRENT_USER|HKEY_LOCAL_MACHINE)\\.+') { $err.Add("${lab}: Registry-Schluessel muss mit HKCU\ oder HKLM\ beginnen") }
        } else {
            if (-not "$($i.Path)".Trim()) { $err.Add("${lab}: Pfad fehlt") }
            foreach ($t in [regex]::Matches("$($i.Path)", '\{([^}]*)\}')) { if ($script:AeTokens -notcontains $t.Groups[1].Value) { $err.Add("${lab}: unbekannter Platzhalter {$($t.Groups[1].Value)}") } }
            if ("$($i.Path)" -notmatch '^(\{[A-Z0-9]+\}|[A-Za-z]:\\|\\\\)') { $err.Add("${lab}: Pfad muss mit einem Platzhalter, Laufwerk (D:\...) oder \\Server beginnen") }
            if ($i.Type -eq 'Files' -and -not @($i.Filter).Count) { $err.Add("${lab}: Typ 'Dateien' braucht einen Filter (z.B. *.lic)") }
        }
        if ($i.DbKind -and $i.Role -ne 'Database') { $err.Add("${lab}: Datenbank-Art nur bei Rolle Datenbank") }
        if ($i.Role -eq 'Database' -and $i.DbKind -eq 'Service' -and -not @($e.StopService).Count) { $err.Add("${lab}: Dienst-Datenbank braucht einen Dienst unter 'Schliessen & Dienste'") }
    }
    foreach ($p in @($e.CloseProcess)) { if ($p -match '[\\/:*?"<>|]' -or $p -match '\.exe$') { $err.Add("Prozess '$p': nur Name ohne .exe und ohne Pfad") } }
    if ($e.VDate -and $e.VDate -notmatch '^\d{4}-\d{2}-\d{2}$') { $err.Add('Geprueft-Datum als JJJJ-MM-TT') }
    return $err.ToArray()
}

# ----------------------------------------------------------------------------
# Fenster
# ----------------------------------------------------------------------------
function Show-HMAppEditor([string]$SelectId = '', $Owner = $null, $NewEntry = $null) {
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Programm-Katalog bearbeiten" Width="1280" Height="820" MinWidth="980" MinHeight="600" WindowStartupLocation="CenterOwner" Background="#FF1E1E2E">
  <DockPanel Margin="10">
    <DockPanel DockPanel.Dock="Bottom" Margin="0,8,0,0">
      <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
        <Button x:Name="bSave" Content="Speichern" Style="{DynamicResource BtnGreen}" Width="110" FontWeight="Bold"/>
        <Button x:Name="bRevert" Content="Verwerfen" Style="{DynamicResource BtnDefault}"/>
        <Button x:Name="bClose" Content="Schliessen" Style="{DynamicResource BtnDefault}" Margin="0"/>
      </StackPanel>
      <StackPanel Orientation="Horizontal">
        <Button x:Name="bWizard" Content="+ Programm hinzufuegen ..." Style="{DynamicResource BtnGreen}" ToolTip="Assistent: installiertes Programm waehlen - HUMig schlaegt Ordner, Registry, Plug-ins und Lizenzdateien vor"/>
        <Button x:Name="bNew" Content="+ Leer" Style="{DynamicResource BtnBlue}" ToolTip="Leeren Eintrag von Hand anlegen"/>
        <Button x:Name="bReset" Content="Auf Standard zuruecksetzen" Style="{DynamicResource BtnPeach}" ToolTip="Eigene Aenderung an einem Standard-Eintrag entfernen (Eintrag aus apps.json loeschen)"/>
        <Button x:Name="bDelete" Content="Loeschen" Style="{DynamicResource BtnRed}" ToolTip="Nur eigene Eintraege"/>
        <Button x:Name="bExport" Content="Exportieren ..." Style="{DynamicResource BtnDefault}" ToolTip="Diesen Eintrag als JSON-Datei speichern (weitergeben)"/>
        <Button x:Name="bImport" Content="Importieren ..." Style="{DynamicResource BtnDefault}" ToolTip="Eintrag aus JSON-Datei laden (danach Speichern)"/>
        <TextBlock x:Name="lState" Foreground="#FFA6ADC8" VerticalAlignment="Center" Margin="8,0,0,0" TextWrapping="Wrap"/>
      </StackPanel>
    </DockPanel>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="330"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <DockPanel Grid.Column="0" Margin="0,0,10,0">
        <TextBox x:Name="tSearch" DockPanel.Dock="Top" Style="{DynamicResource DarkTextBox}" Margin="0,0,0,4" ToolTip="Suche in Name, Id, Erkennung"/>
        <ComboBox x:Name="cFilter" DockPanel.Dock="Top" Margin="0,0,0,4"/>
        <TextBlock x:Name="lCount" DockPanel.Dock="Bottom" Foreground="#FF6C7086" FontSize="11" Margin="0,4,0,0" TextWrapping="Wrap"/>
        <ListBox x:Name="lApps"/>
      </DockPanel>
      <DockPanel Grid.Column="1">
        <TextBlock x:Name="lHead" DockPanel.Dock="Top" Foreground="#FFCDD6F4" FontSize="16" FontWeight="SemiBold" Margin="0,0,0,6"/>
        <TabControl x:Name="tabs">
          <TabItem Header="Allgemein">
            <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel Margin="4">
              <TextBlock Text="Id (App_..., bleibt fest)" Foreground="#FFA6ADC8"/>
              <TextBox x:Name="tId" Style="{DynamicResource DarkTextBox}" Margin="0,2,0,8"/>
              <TextBlock Text="Name" Foreground="#FFA6ADC8"/>
              <TextBox x:Name="tName" Style="{DynamicResource DarkTextBox}" Margin="0,2,0,8"/>
              <TextBlock Text="Erkennung (Detect): regulaerer Ausdruck auf den Programmnamen in 'Apps &amp; Features', z.B. ^Mozilla Thunderbird" Foreground="#FFA6ADC8" TextWrapping="Wrap"/>
              <DockPanel Margin="0,2,0,8">
                <Button x:Name="bDetect" DockPanel.Dock="Right" Content="Testen am PC" Style="{DynamicResource BtnTeal}" Margin="4,0,0,0"/>
                <TextBox x:Name="tDetect" Style="{DynamicResource DarkTextBox}"/>
              </DockPanel>
              <TextBlock Text="Paket in der Softwareverteilung (regulaerer Ausdruck auf Paket-/Ordnernamen) - fuer 'Fehlende Programme installieren'" Foreground="#FFA6ADC8" TextWrapping="Wrap"/>
              <DockPanel Margin="0,2,0,8">
                <Button x:Name="bPackage" DockPanel.Dock="Right" Content="Testen" Style="{DynamicResource BtnTeal}" Margin="4,0,0,0"/>
                <TextBox x:Name="tPackage" Style="{DynamicResource DarkTextBox}"/>
              </DockPanel>
              <TextBlock Text="Vorhandene Module mitverwenden (Modul-Ids, eine je Zeile, z.B. Firefox) - optional" Foreground="#FFA6ADC8"/>
              <TextBox x:Name="tModules" Style="{DynamicResource DarkTextBox}" Margin="0,2,0,8" AcceptsReturn="True" Height="48" VerticalScrollBarVisibility="Auto"/>
              <TextBlock x:Name="lGen" Foreground="#FFF9E2AF" TextWrapping="Wrap" Margin="0,4,0,0"/>
            </StackPanel></ScrollViewer>
          </TabItem>
          <TabItem Header="Sichern">
            <DockPanel Margin="4">
              <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,0,0,4">
                <Button x:Name="bIAdd" Content="+ Eintrag" Style="{DynamicResource BtnGreen}"/>
                <Button x:Name="bIDup" Content="Duplizieren" Style="{DynamicResource BtnDefault}"/>
                <Button x:Name="bIDel" Content="- Entfernen" Style="{DynamicResource BtnRed}"/>
                <Button x:Name="bIUp" Content="Hoch" Style="{DynamicResource BtnDefault}"/>
                <Button x:Name="bIDown" Content="Runter" Style="{DynamicResource BtnDefault}"/>
              </StackPanel>
              <Border DockPanel.Dock="Bottom" Background="#FF181825" CornerRadius="6" Padding="8" Margin="0,6,0,0">
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="110"/><ColumnDefinition Width="*"/><ColumnDefinition Width="110"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <Grid.RowDefinitions><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
                  <TextBlock Grid.Row="0" Grid.Column="0" Text="Typ" Foreground="#FFA6ADC8" VerticalAlignment="Center"/>
                  <ComboBox x:Name="cIType" Grid.Row="0" Grid.Column="1" Margin="0,2,8,2"/>
                  <TextBlock Grid.Row="0" Grid.Column="2" Text="Name (Ordner)" Foreground="#FFA6ADC8" VerticalAlignment="Center"/>
                  <TextBox x:Name="tIName" Grid.Row="0" Grid.Column="3" Style="{DynamicResource DarkTextBox}" Margin="0,2,0,2"/>
                  <TextBlock Grid.Row="1" Grid.Column="0" Text="Rolle" Foreground="#FFA6ADC8" VerticalAlignment="Center"/>
                  <ComboBox x:Name="cIRole" Grid.Row="1" Grid.Column="1" Margin="0,2,8,2"/>
                  <TextBlock Grid.Row="1" Grid.Column="2" Text="Datenbank-Art" Foreground="#FFA6ADC8" VerticalAlignment="Center"/>
                  <ComboBox x:Name="cIDb" Grid.Row="1" Grid.Column="3" Margin="0,2,0,2"/>
                  <TextBlock x:Name="lIPath" Grid.Row="2" Grid.Column="0" Text="Pfad" Foreground="#FFA6ADC8" VerticalAlignment="Center"/>
                  <DockPanel Grid.Row="2" Grid.Column="1" Grid.ColumnSpan="3" Margin="0,2,0,2">
                    <Button x:Name="bICheck" DockPanel.Dock="Right" Content="Pfad pruefen" Style="{DynamicResource BtnTeal}" Margin="4,0,0,0" ToolTip="Am oben gewaehlten PC fuer den gewaehlten Benutzer: vorhanden? Groesse?"/>
                    <Button x:Name="bIFolder" DockPanel.Dock="Right" Content="Ordner waehlen ..." Style="{DynamicResource BtnDefault}" Margin="4,0,0,0" ToolTip="Ordner an diesem PC waehlen - wird in Platzhalter umgewandelt ({APPDATA}\...)"/>
                    <TextBox x:Name="tIPath" Style="{DynamicResource DarkTextBox}"/>
                  </DockPanel>
                  <TextBlock Grid.Row="3" Grid.Column="0" Text="Filter (Dateien)" Foreground="#FFA6ADC8" VerticalAlignment="Center"/>
                  <TextBox x:Name="tIFilter" Grid.Row="3" Grid.Column="1" Style="{DynamicResource DarkTextBox}" Margin="0,2,8,2" ToolTip="Nur bei Typ Dateien: Muster, mit ; getrennt (z.B. *.lic;license.dat) - nur dieser Ordner, ohne Unterordner"/>
                  <TextBlock Grid.Row="3" Grid.Column="2" Text="Scope" Foreground="#FFA6ADC8" VerticalAlignment="Center"/>
                  <TextBlock x:Name="lIScope" Grid.Row="3" Grid.Column="3" Foreground="#FF89B4FA" VerticalAlignment="Center" FontWeight="SemiBold"/>
                  <TextBlock Grid.Row="4" Grid.Column="0" Text="Ordner auslassen" Foreground="#FFA6ADC8" VerticalAlignment="Center"/>
                  <TextBox x:Name="tIXD" Grid.Row="4" Grid.Column="1" Style="{DynamicResource DarkTextBox}" Margin="0,2,8,2" ToolTip="Unterordner auslassen (XD), mit ; getrennt, z.B. Cache;*Temp*;Logs"/>
                  <TextBlock Grid.Row="4" Grid.Column="2" Text="Dateien auslassen" Foreground="#FFA6ADC8" VerticalAlignment="Center"/>
                  <TextBox x:Name="tIXF" Grid.Row="4" Grid.Column="3" Style="{DynamicResource DarkTextBox}" Margin="0,2,0,2" ToolTip="Dateimuster auslassen (XF), mit ; getrennt, z.B. *.log;*.tmp"/>
                  <StackPanel Grid.Row="5" Grid.Column="1" Grid.ColumnSpan="3" Orientation="Horizontal" Margin="0,4,0,0">
                    <CheckBox x:Name="xILic" Content="Lizenzdatei/-schluessel" Margin="0,0,16,0" ToolTip="Wird mit gesichert und am neuen PC zurueckgeschrieben - Programm ist dort gleich lizenziert"/>
                    <CheckBox x:Name="xIHidden" Content="versteckte/System-Dateien auslassen"/>
                  </StackPanel>
                </Grid>
              </Border>
              <TextBlock x:Name="lICheck" DockPanel.Dock="Bottom" Foreground="#FFF9E2AF" TextWrapping="Wrap" Margin="0,4,0,0"/>
              <ListBox x:Name="lItems" FontFamily="Consolas"/>
            </DockPanel>
          </TabItem>
          <TabItem Header="Schliessen &amp; Dienste">
            <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel Margin="4">
              <TextBlock Text="Programm vorher schliessen - Prozessnamen ohne .exe, einer je Zeile (z.B. thunderbird). Laeuft das Programm, fragt HUMig vor Backup/Restore: schliessen, ueberspringen oder trotzdem kopieren. Geplante Backups beenden nie ein Programm - das Modul wird dann uebersprungen." Foreground="#FFA6ADC8" TextWrapping="Wrap"/>
              <DockPanel Margin="0,4,0,10">
                <Button x:Name="bProc" DockPanel.Dock="Right" Content="Laufende Prozesse am PC ..." Style="{DynamicResource BtnTeal}" Margin="4,0,0,0" VerticalAlignment="Top"/>
                <TextBox x:Name="tClose" Style="{DynamicResource DarkTextBox}" AcceptsReturn="True" Height="90" VerticalScrollBarVisibility="Auto"/>
              </DockPanel>
              <TextBlock Text="Dienste vorher stoppen - Dienstnamen (nicht Anzeigenamen), einer je Zeile (z.B. MSSQL$FACHPROGRAMM). Nur mit Administratorrechten; nach dem Kopieren wird der Dienst immer wieder gestartet. Fuer Datenbanken, die ein Dienst geoeffnet haelt (SQL Server Express, Firebird, MySQL)." Foreground="#FFA6ADC8" TextWrapping="Wrap"/>
              <DockPanel Margin="0,4,0,10">
                <Button x:Name="bSvc" DockPanel.Dock="Right" Content="Dienste am PC ..." Style="{DynamicResource BtnTeal}" Margin="4,0,0,0" VerticalAlignment="Top"/>
                <TextBox x:Name="tSvc" Style="{DynamicResource DarkTextBox}" AcceptsReturn="True" Height="70" VerticalScrollBarVisibility="Auto"/>
              </DockPanel>
              <TextBlock Foreground="#FF6C7086" TextWrapping="Wrap" FontSize="11" Text="Datenbank-Dateien: im Reiter Sichern Rolle 'Datenbank' waehlen. Datei-Datenbank (SQLite, Access, KeePass ...): Programm vorher schliessen; bei SQLite kopiert HUMig -wal/-shm/-journal automatisch mit. Dienst-Datenbank: Dienst hier eintragen - Dateikopie ist nur bei gleicher Datenbank-Version am Ziel verlaesslich, sonst die Sicherung des Herstellers verwenden."/>
            </StackPanel></ScrollViewer>
          </TabItem>
          <TabItem Header="Hinweise">
            <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel Margin="4">
              <TextBlock Text="Was wird uebertragen" Foreground="#FFA6ADC8"/>
              <TextBox x:Name="tTransfer" Style="{DynamicResource DarkTextBox}" Margin="0,2,0,8" TextWrapping="Wrap"/>
              <TextBlock Text="Nicht uebertragbar (z.B. gespeicherte Kennwoerter - Windows-Verschluesselung DPAPI)" Foreground="#FFA6ADC8"/>
              <TextBox x:Name="tNot" Style="{DynamicResource DarkTextBox}" Margin="0,2,0,8" TextWrapping="Wrap"/>
              <TextBlock Text="Lizenz (Hinweis; Konto/Hardware-Lizenzen nie kopieren)" Foreground="#FFA6ADC8"/>
              <TextBox x:Name="tLicense" Style="{DynamicResource DarkTextBox}" Margin="0,2,0,8" TextWrapping="Wrap"/>
              <TextBlock Text="Version (z.B. Einstellungen nur fuer gleiche/neuere Hauptversion)" Foreground="#FFA6ADC8"/>
              <TextBox x:Name="tVersion" Style="{DynamicResource DarkTextBox}" Margin="0,2,0,8" TextWrapping="Wrap"/>
              <TextBlock Text="Nacharbeiten fuer die Checkliste nach dem Restore - eine je Zeile" Foreground="#FFA6ADC8"/>
              <TextBox x:Name="tAfter" Style="{DynamicResource DarkTextBox}" Margin="0,2,0,8" AcceptsReturn="True" Height="110" VerticalScrollBarVisibility="Auto" TextWrapping="Wrap"/>
            </StackPanel></ScrollViewer>
          </TabItem>
          <TabItem Header="Quelle">
            <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel Margin="4">
              <TextBlock Text="Geprueft am (JJJJ-MM-TT) - leer = ungeprueft" Foreground="#FFA6ADC8"/>
              <StackPanel Orientation="Horizontal" Margin="0,2,0,8">
                <TextBox x:Name="tVDate" Style="{DynamicResource DarkTextBox}" Width="120"/>
                <Button x:Name="bToday" Content="heute" Style="{DynamicResource BtnDefault}" Margin="4,0,0,0"/>
              </StackPanel>
              <TextBlock Text="Quellen (Links auf Hersteller-Doku/FAQ, einer je Zeile)" Foreground="#FFA6ADC8"/>
              <DockPanel Margin="0,2,0,8">
                <Button x:Name="bLinks" DockPanel.Dock="Right" Content="Links oeffnen" Style="{DynamicResource BtnDefault}" Margin="4,0,0,0" VerticalAlignment="Top"/>
                <TextBox x:Name="tSources" Style="{DynamicResource DarkTextBox}" AcceptsReturn="True" Height="110" VerticalScrollBarVisibility="Auto"/>
              </DockPanel>
              <TextBlock Text="Notiz" Foreground="#FFA6ADC8"/>
              <TextBox x:Name="tVNote" Style="{DynamicResource DarkTextBox}" Margin="0,2,0,8" AcceptsReturn="True" Height="70" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"/>
            </StackPanel></ScrollViewer>
          </TabItem>
        </TabControl>
      </DockPanel>
    </Grid>
  </DockPanel>
</Window>
'@
    $w = [System.Windows.Markup.XamlReader]::Parse($x)
    $w.Resources.MergedDictionaries.Add($script:Window.Resources)
    if ($script:AppIcon) { $w.Icon = $script:AppIcon }
    $f = @{}
    foreach ($n in @('bSave', 'bRevert', 'bClose', 'bWizard', 'bNew', 'bReset', 'bDelete', 'bExport', 'bImport', 'lState', 'tSearch', 'cFilter', 'lCount', 'lApps', 'lHead', 'tabs',
            'tId', 'tName', 'bDetect', 'tDetect', 'bPackage', 'tPackage', 'tModules', 'lGen', 'bIAdd', 'bIDup', 'bIDel', 'bIUp', 'bIDown', 'cIType', 'tIName', 'cIRole', 'cIDb',
            'lIPath', 'bICheck', 'bIFolder', 'tIPath', 'tIFilter', 'lIScope', 'tIXD', 'tIXF', 'xILic', 'xIHidden', 'lICheck', 'lItems', 'bProc', 'tClose', 'bSvc', 'tSvc',
            'tTransfer', 'tNot', 'tLicense', 'tVersion', 'tAfter', 'tVDate', 'bToday', 'bLinks', 'tSources', 'tVNote')) { $f[$n] = $w.FindName($n) }
    $script:Ae = @{ Win = $w; F = $f; Cur = $null; CurKind = ''; IsNew = $false; Snapshot = ''; Items = ([System.Collections.Generic.List[object]]::new()); Loading = $false; ReadOnly = $false; Saved = $false }

    foreach ($t in @('alle', 'am PC erkannt', 'geprueft', 'ungeprueft', 'nur Hinweis (ohne Inhalt)', 'eigene', 'geaendert')) { [void]$f.cFilter.Items.Add($t) }
    $f.cFilter.SelectedIndex = 0
    foreach ($t in @(@('Folder', 'Ordner'), @('Files', 'Dateien'), @('Reg', 'Registry'))) { $ci = New-Object System.Windows.Controls.ComboBoxItem; $ci.Content = $t[1]; $ci.Tag = $t[0]; [void]$f.cIType.Items.Add($ci) }
    foreach ($r in $script:AeRoles) { $ci = New-Object System.Windows.Controls.ComboBoxItem; $ci.Content = $script:AeRoleNames[$r]; $ci.Tag = $r; [void]$f.cIRole.Items.Add($ci) }
    foreach ($t in @(@('', '-'), @('File', 'Datei (SQLite, Access ...)'), @('Service', 'Dienst (SQL Server, Firebird ...)'))) { $ci = New-Object System.Windows.Controls.ComboBoxItem; $ci.Content = $t[1]; $ci.Tag = $t[0]; [void]$f.cIDb.Items.Add($ci) }

    # Nur lesen: Benutzer-Modus oder Config-Ordner nicht beschreibbar
    $ro = ''
    try { $tf = Join-Path $script:ConfigDir ('.hmtest_' + [guid]::NewGuid().ToString('N')); [System.IO.File]::WriteAllText($tf, 'x'); Remove-Item -LiteralPath $tf -Force } catch { $ro = 'Config-Ordner nicht beschreibbar - nur Ansicht' }
    if ($script:UserMode -and -not $ro) { $ro = 'Benutzer-Modus - nur Ansicht' }
    if ($ro) {
        $script:Ae.ReadOnly = $true
        foreach ($b in @($f.bSave, $f.bWizard, $f.bNew, $f.bReset, $f.bDelete, $f.bImport)) { $b.IsEnabled = $false }
        $f.lState.Text = $ro
    }

    Import-HMAeData
    # --- Ereignisse ---
    $f.tSearch.Add_TextChanged({ Update-HMAeList })
    $f.cFilter.Add_SelectionChanged({ Update-HMAeList })
    $f.lApps.Add_SelectionChanged({
        if ($script:Ae.Loading) { return }
        $sel = $script:Ae.F.lApps.SelectedItem
        if (-not $sel) { return }
        if ($script:Ae.Cur -and "$($sel.Tag)" -eq "$($script:Ae.Cur.Id)" -and -not $script:Ae.IsNew) { return }
        if (-not (Confirm-HMAeDiscard)) {
            $script:Ae.Loading = $true
            if ($script:Ae.IsNew) { $script:Ae.F.lApps.SelectedItem = $null } else { Select-HMAeListItem "$($script:Ae.Cur.Id)" }
            $script:Ae.Loading = $false
            return
        }
        $e = @($script:Ae.All | Where-Object { $_.Id -eq "$($sel.Tag)" })[0]
        if ($e) { Set-HMAeForm (ConvertTo-HMAeEntry $e.Obj) $e.Kind $false }
    })
    $f.lItems.Add_SelectionChanged({ if (-not $script:Ae.Loading) { Show-HMAeItem } })
    foreach ($c in @($f.tIName, $f.tIPath, $f.tIFilter, $f.tIXD, $f.tIXF)) { $c.Add_TextChanged({ Save-HMAeItem }) }
    foreach ($c in @($f.cIType, $f.cIRole, $f.cIDb)) { $c.Add_SelectionChanged({ Save-HMAeItem }) }
    foreach ($c in @($f.xILic, $f.xIHidden)) { $c.Add_Click({ Save-HMAeItem }) }
    $f.bIAdd.Add_Click({ Add-HMAeItem $null })
    $f.bIDup.Add_Click({ $i = Get-HMAeSelItem; if ($i) { Add-HMAeItem $i } })
    $f.bIDel.Add_Click({ Remove-HMAeItem })
    $f.bIUp.Add_Click({ Move-HMAeItem -1 })
    $f.bIDown.Add_Click({ Move-HMAeItem 1 })
    $f.bIFolder.Add_Click({ Select-HMAeFolder })
    $f.bICheck.Add_Click({ Test-HMAePath })
    $f.bDetect.Add_Click({ Test-HMAeDetect })
    $f.bPackage.Add_Click({ Test-HMAePackage })
    $f.bProc.Add_Click({ Select-HMAeProcesses })
    $f.bSvc.Add_Click({ Select-HMAeServices })
    $f.bToday.Add_Click({ $script:Ae.F.tVDate.Text = (Get-Date).ToString('yyyy-MM-dd') })
    $f.bLinks.Add_Click({ foreach ($l in @(ConvertFrom-HMLines $script:Ae.F.tSources.Text)) { if ($l -match '^https?://') { try { Start-Process -FilePath $l } catch { } } } })
    $f.bSave.Add_Click({ Save-HMAeEntry })
    $f.bRevert.Add_Click({ if ($script:Ae.Cur) { Set-HMAeForm $script:Ae.Orig $script:Ae.CurKind $script:Ae.IsNew } })
    $f.bNew.Add_Click({ New-HMAeEntry })
    $f.bWizard.Add_Click({ if (Confirm-HMAeDiscard) { Start-HMAppWizard -ForEditor } })
    $f.bReset.Add_Click({ Reset-HMAeEntry })
    $f.bDelete.Add_Click({ Remove-HMAeEntry })
    $f.bExport.Add_Click({ Export-HMAeEntry })
    $f.bImport.Add_Click({ Import-HMAeEntry })
    $f.bClose.Add_Click({ $script:Ae.Win.Close() })
    $w.Add_Closing({ param($s, $ev) if (-not (Confirm-HMAeDiscard)) { $ev.Cancel = $true } })

    Update-HMAeList
    if ($NewEntry -and -not $script:Ae.ReadOnly) {
        # vorbelegter neuer Eintrag (z.B. aus 'Datenbanken suchen'): Id eindeutig machen
        $e = ConvertTo-HMAeEntry $NewEntry
        $base = $e.Id; $c = 2
        while (@($script:Ae.All | Where-Object { $_.Id -ieq $e.Id }).Count) { $e.Id = "$base$c"; $c++ }
        Set-HMAeForm $e 'eigen' $true
        $f.lGen.Text = 'Neuer Eintrag aus der Suche: Name und Erkennung (Programm, zu dem die Datenbank gehoert) eintragen, unter "Schliessen & Dienste" das Programm waehlen, dann Speichern.'
    } elseif ($SelectId) { Select-HMAeListItem $SelectId }
    if (-not $script:Ae.Cur -and $f.lApps.Items.Count) { $f.lApps.SelectedIndex = 0 }
    $w.Owner = $(if ($Owner) { $Owner } else { $script:Window }); Set-HMWindowScale $w
    [void]$w.ShowDialog()
    # Nach dem Schliessen: Katalog neu laden, wenn gespeichert wurde
    if ($script:Ae.Saved) { Update-HMAeCatalog }
    $script:Ae = $null
}

# ----------------------------------------------------------------------------
# Liste links
# ----------------------------------------------------------------------------
function Update-HMAeList {
    $f = $script:Ae.F
    $q = "$($f.tSearch.Text)".Trim()
    $flt = "$($f.cFilter.SelectedItem)"
    $det = @(@($script:DetectedApps) | ForEach-Object { "$($_.Id)" })
    $script:Ae.Loading = $true
    try {
        $f.lApps.Items.Clear()
        $n = 0
        foreach ($e in $script:Ae.All) {
            $o = $e.Obj
            $has = @($o.Items | Where-Object { $_ }).Count -or @($o.Modules | Where-Object { $_ }).Count
            $ver = [bool]($o.Verified -and "$($o.Verified.Date)")
            $ok = switch ($flt) {
                'am PC erkannt' { $det -contains $e.Id }
                'geprueft' { $ver }
                'ungeprueft' { -not $ver }
                'nur Hinweis (ohne Inhalt)' { -not $has }
                'eigene' { $e.Kind -eq 'eigen' }
                'geaendert' { $e.Kind -eq 'geaendert' }
                default { $true }
            }
            if ($ok -and $q) { $ok = ("$($o.Name) $($e.Id) $($o.Detect)" -like "*$q*") }
            if (-not $ok) { continue }
            $n++
            $li = New-Object System.Windows.Controls.ListBoxItem
            $mark = @()
            if ($e.Kind -ne 'Standard') { $mark += $e.Kind }
            if ($ver) { $mark += 'geprueft' }
            if (-not $has) { $mark += 'nur Hinweis' }
            if ($det -contains $e.Id) { $mark += 'am PC' }
            $li.Content = "$($o.Name)$(if ($mark.Count) { "   [$($mark -join ', ')]" })"
            $li.Tag = $e.Id
            $li.Foreground = New-Brush $(if ($e.Kind -eq 'eigen') { '#FFA6E3A1' } elseif ($e.Kind -eq 'geaendert') { '#FFFAB387' } elseif (-not $has) { '#FF6C7086' } else { '#FFCDD6F4' })
            [void]$f.lApps.Items.Add($li)
            if ($script:Ae.Cur -and $e.Id -eq "$($script:Ae.Cur.Id)") { $f.lApps.SelectedItem = $li }
        }
        $all = @($script:Ae.All).Count
        $f.lCount.Text = "$n von $all Eintraegen - Standard: $(@($script:Ae.All | Where-Object { $_.Kind -eq 'Standard' }).Count), geaendert: $(@($script:Ae.All | Where-Object { $_.Kind -eq 'geaendert' }).Count), eigene: $(@($script:Ae.All | Where-Object { $_.Kind -eq 'eigen' }).Count)`nGespeichert wird in Config\apps.json"
    } finally { $script:Ae.Loading = $false }
}
function Select-HMAeListItem([string]$Id) {
    foreach ($li in $script:Ae.F.lApps.Items) { if ("$($li.Tag)" -eq $Id) { $script:Ae.F.lApps.SelectedItem = $li; $script:Ae.F.lApps.ScrollIntoView($li); return } }
}

# ----------------------------------------------------------------------------
# Formular
# ----------------------------------------------------------------------------
function Set-HMAeForm($e, [string]$Kind, [bool]$IsNew) {
    $f = $script:Ae.F
    $script:Ae.Loading = $true
    try {
        $script:Ae.Cur = $e; $script:Ae.CurKind = $Kind; $script:Ae.IsNew = $IsNew
        $script:Ae.Orig = ConvertTo-HMAeEntry (ConvertFrom-HMAeEntry $e)   # Kopie fuer "Verwerfen"
        $f.lHead.Text = "$($e.Name)   ($(if ($IsNew) { 'neu - noch nicht gespeichert' } else { switch ($Kind) { 'eigen' { 'eigener Eintrag' } 'geaendert' { 'Standard-Eintrag, geaendert' } default { 'Standard-Eintrag' } } }))"
        $f.tId.Text = $e.Id; $f.tId.IsReadOnly = -not $IsNew
        $f.tName.Text = $e.Name; $f.tDetect.Text = $e.Detect; $f.tPackage.Text = $e.Package
        $f.tModules.Text = ConvertTo-HMLines $e.Modules
        $f.tClose.Text = ConvertTo-HMLines $e.CloseProcess; $f.tSvc.Text = ConvertTo-HMLines $e.StopService
        $f.tTransfer.Text = $e.Transfer; $f.tNot.Text = $e.NotTransfer; $f.tLicense.Text = $e.License; $f.tVersion.Text = $e.Version
        $f.tAfter.Text = ConvertTo-HMLines $e.After
        $f.tVDate.Text = $e.VDate; $f.tSources.Text = ConvertTo-HMLines $e.VSources; $f.tVNote.Text = $e.VNote
        $f.lGen.Text = ''; $f.lICheck.Text = ''
        $script:Ae.Items.Clear()
        foreach ($i in @($e.Items)) { $script:Ae.Items.Add($i) }
        Update-HMAeItemList 0
        $f.bReset.IsEnabled = (-not $script:Ae.ReadOnly) -and $Kind -eq 'geaendert' -and -not $IsNew
        $f.bDelete.IsEnabled = (-not $script:Ae.ReadOnly) -and ($Kind -eq 'eigen' -or $IsNew)
    } finally { $script:Ae.Loading = $false }
    Show-HMAeItem
    $script:Ae.Snapshot = Get-HMAeJson (Get-HMAeForm)
}
# Formular -> Eintrag
function Get-HMAeForm {
    $f = $script:Ae.F
    $e = [ordered]@{}
    $e.Id = "$($f.tId.Text)".Trim(); $e.Name = "$($f.tName.Text)".Trim(); $e.Detect = "$($f.tDetect.Text)".Trim(); $e.Package = "$($f.tPackage.Text)".Trim()
    $e.Transfer = "$($f.tTransfer.Text)".Trim(); $e.NotTransfer = "$($f.tNot.Text)".Trim(); $e.License = "$($f.tLicense.Text)".Trim(); $e.Version = "$($f.tVersion.Text)".Trim()
    $e.Modules = @(ConvertFrom-HMLines $f.tModules.Text)
    $e.After = @(ConvertFrom-HMLines $f.tAfter.Text)
    $e.CloseProcess = @(ConvertFrom-HMLines $f.tClose.Text | ForEach-Object { $_ -replace '\.exe$', '' } | Select-Object -Unique)
    $e.StopService = @(ConvertFrom-HMLines $f.tSvc.Text)
    $e.Items = @($script:Ae.Items)
    $e.VDate = "$($f.tVDate.Text)".Trim(); $e.VSources = @(ConvertFrom-HMLines $f.tSources.Text); $e.VNote = "$($f.tVNote.Text)".Trim()
    $e.Extra = if ($script:Ae.Cur) { $script:Ae.Cur.Extra } else { [ordered]@{} }
    return $e
}
function Test-HMAeDirty {
    if (-not $script:Ae -or -not $script:Ae.Cur -or $script:Ae.ReadOnly) { return $false }
    return ($script:Ae.IsNew -or (Get-HMAeJson (Get-HMAeForm)) -ne $script:Ae.Snapshot)
}
function Confirm-HMAeDiscard {
    if (-not (Test-HMAeDirty)) { return $true }
    return ("$([System.Windows.MessageBox]::Show($script:Ae.Win, "Aenderungen an '$($script:Ae.F.tName.Text)' sind nicht gespeichert.`n`nVerwerfen?", 'Katalog', 'YesNo', 'Question'))" -eq 'Yes')
}

# ----------------------------------------------------------------------------
# Sichern-Eintraege (Items)
# ----------------------------------------------------------------------------
function Format-HMAeItem($i) {
    $t = switch ($i.Type) { 'Reg' { 'REG ' } 'Files' { 'DATEI' } default { 'ORDNR' } }
    $w = if ($i.Type -eq 'Reg') { $i.Key } else { $i.Path }
    $extra = @()
    if ($i.Type -eq 'Files' -and @($i.Filter).Count) { $extra += "Filter $(@($i.Filter) -join ';')" }
    if ($i.Role) { $extra += $script:AeRoleNames[$i.Role] + $(if ($i.DbKind) { "/$($i.DbKind)" }) }
    if ($i.License) { $extra += 'Lizenz' }
    return ("{0}  {1,-14} {2}{3}   [{4}]" -f $t, $i.Name, $w, $(if ($extra.Count) { "   ($($extra -join ', '))" }), (Get-HMAeScope $i))
}
function Update-HMAeItemList([int]$Select = -1) {
    $f = $script:Ae.F
    $old = $script:Ae.Loading
    $script:Ae.Loading = $true
    try {
        $f.lItems.Items.Clear()
        for ($k = 0; $k -lt $script:Ae.Items.Count; $k++) {
            $li = New-Object System.Windows.Controls.ListBoxItem
            $li.Content = Format-HMAeItem $script:Ae.Items[$k]; $li.Tag = $k
            [void]$f.lItems.Items.Add($li)
        }
        if ($Select -ge 0 -and $Select -lt $f.lItems.Items.Count) { $f.lItems.SelectedIndex = $Select }
    } finally { $script:Ae.Loading = $old }
}
function Get-HMAeSelItem {
    $li = $script:Ae.F.lItems.SelectedItem
    if (-not $li) { return $null }
    return $script:Ae.Items[[int]$li.Tag]
}
function Set-HMAeCombo($Combo, [string]$Tag) {
    foreach ($ci in $Combo.Items) { if ("$($ci.Tag)" -eq $Tag) { $Combo.SelectedItem = $ci; return } }
    $Combo.SelectedIndex = 0
}
function Show-HMAeItem {
    $f = $script:Ae.F
    $i = Get-HMAeSelItem
    $old = $script:Ae.Loading
    $script:Ae.Loading = $true
    try {
        $en = [bool]$i -and -not $script:Ae.ReadOnly
        foreach ($c in @($f.cIType, $f.tIName, $f.cIRole, $f.cIDb, $f.tIPath, $f.tIFilter, $f.tIXD, $f.tIXF, $f.xILic, $f.xIHidden, $f.bIFolder, $f.bIDup, $f.bIDel, $f.bIUp, $f.bIDown)) { $c.IsEnabled = $en }
        $f.bICheck.IsEnabled = [bool]$i
        if (-not $i) { foreach ($c in @($f.tIName, $f.tIPath, $f.tIFilter, $f.tIXD, $f.tIXF)) { $c.Text = '' }; $f.lIScope.Text = ''; return }
        Set-HMAeCombo $f.cIType $i.Type
        $f.tIName.Text = $i.Name
        Set-HMAeCombo $f.cIRole $i.Role
        Set-HMAeCombo $f.cIDb $i.DbKind
        $f.tIPath.Text = $(if ($i.Type -eq 'Reg') { $i.Key } else { $i.Path })
        $f.tIFilter.Text = (@($i.Filter) -join ';'); $f.tIXD.Text = (@($i.XD) -join ';'); $f.tIXF.Text = (@($i.XF) -join ';')
        $f.xILic.IsChecked = [bool]$i.License; $f.xIHidden.IsChecked = [bool]$i.NoHidden
        Update-HMAeItemState $i
    } finally { $script:Ae.Loading = $old }
}
function Update-HMAeItemState($i) {
    $f = $script:Ae.F
    $f.lIPath.Text = $(if ($i.Type -eq 'Reg') { 'Schluessel' } else { 'Pfad' })
    $f.tIFilter.IsEnabled = ($i.Type -eq 'Files') -and -not $script:Ae.ReadOnly
    $f.tIXD.IsEnabled = ($i.Type -ne 'Reg') -and -not $script:Ae.ReadOnly
    $f.tIXF.IsEnabled = ($i.Type -ne 'Reg') -and -not $script:Ae.ReadOnly
    $f.bIFolder.IsEnabled = ($i.Type -ne 'Reg') -and -not $script:Ae.ReadOnly
    $f.cIDb.IsEnabled = ($i.Role -eq 'Database') -and -not $script:Ae.ReadOnly
    $f.lIScope.Text = "$(Get-HMAeScope $i)$(if ((Get-HMAeScope $i) -eq 'Maschine') { ' - Restore nur mit Administratorrechten' } else { '' })"
}
# Felder -> aktuelles Item (bei jeder Aenderung)
function Save-HMAeItem {
    if ($script:Ae.Loading) { return }
    $f = $script:Ae.F
    $i = Get-HMAeSelItem
    if (-not $i) { return }
    $split = { param($t) @("$t" -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    $i.Type = "$($f.cIType.SelectedItem.Tag)"
    $i.Name = "$($f.tIName.Text)".Trim()
    $i.Role = "$($f.cIRole.SelectedItem.Tag)"
    $i.DbKind = if ($i.Role -eq 'Database') { "$($f.cIDb.SelectedItem.Tag)" } else { '' }
    $v = "$($f.tIPath.Text)".Trim()
    if ($i.Type -eq 'Reg') { $i.Key = $v; $i.Path = '' } else { $i.Path = $v; $i.Key = '' }
    $i.Filter = @(& $split $f.tIFilter.Text); $i.XD = @(& $split $f.tIXD.Text); $i.XF = @(& $split $f.tIXF.Text)
    if ($i.Role -eq 'License' -and -not $f.xILic.IsChecked) { $script:Ae.Loading = $true; $f.xILic.IsChecked = $true; $script:Ae.Loading = $false }
    $i.License = [bool]$f.xILic.IsChecked; $i.NoHidden = [bool]$f.xIHidden.IsChecked
    $f.lItems.SelectedItem.Content = Format-HMAeItem $i
    Update-HMAeItemState $i
}
function Add-HMAeItem($From) {
    $n = [ordered]@{ Type = 'Folder'; Name = ''; Role = 'Settings'; Path = '{APPDATA}\'; Key = ''; DbKind = ''; Filter = @(); XD = @(); XF = @(); NoHidden = $false; License = $false; Extra = [ordered]@{} }
    if ($From) { foreach ($k in @($From.Keys)) { $n[$k] = $From[$k] }; $n.Extra = [ordered]@{}; foreach ($k in @($From.Extra.Keys)) { $n.Extra[$k] = $From.Extra[$k] } }
    $base = if ($From) { "$($From.Name)" } else { 'CFG' }
    $nm = $base; $c = 2
    while (@($script:Ae.Items | Where-Object { "$($_.Name)" -ieq $nm }).Count) { $nm = "$base$c"; $c++ }
    $n.Name = $nm
    $script:Ae.Items.Add($n)
    Update-HMAeItemList ($script:Ae.Items.Count - 1)
    Show-HMAeItem
}
function Remove-HMAeItem {
    $li = $script:Ae.F.lItems.SelectedItem
    if (-not $li) { return }
    $k = [int]$li.Tag
    $script:Ae.Items.RemoveAt($k)
    Update-HMAeItemList ([Math]::Min($k, $script:Ae.Items.Count - 1))
    Show-HMAeItem
}
function Move-HMAeItem([int]$Dir) {
    $li = $script:Ae.F.lItems.SelectedItem
    if (-not $li) { return }
    $k = [int]$li.Tag; $j = $k + $Dir
    if ($j -lt 0 -or $j -ge $script:Ae.Items.Count) { return }
    $t = $script:Ae.Items[$k]; $script:Ae.Items[$k] = $script:Ae.Items[$j]; $script:Ae.Items[$j] = $t
    Update-HMAeItemList $j
    Show-HMAeItem
}
function Select-HMAeFolder {
    $d = New-Object System.Windows.Forms.FolderBrowserDialog
    $d.Description = 'Ordner des Programms waehlen (an diesem PC) - wird in Platzhalter umgewandelt, z.B. {APPDATA}\Hersteller\Programm'
    $cur = "$($script:Ae.F.tIPath.Text)"
    if ($cur -and $cur -notmatch '\{') { $d.SelectedPath = $cur }
    if ($d.ShowDialog() -ne 'OK') { return }
    $script:Ae.F.tIPath.Text = ConvertTo-HMAeToken $d.SelectedPath
}

# ----------------------------------------------------------------------------
# Tests am verbundenen PC (asynchron)
# ----------------------------------------------------------------------------
function Test-HMAeDetect {
    $f = $script:Ae.F
    $rx = "$($f.tDetect.Text)".Trim()
    if (-not $rx) { $f.lGen.Text = 'Erkennung ist leer.'; return }
    try { [void][regex]::new($rx) } catch { $f.lGen.Text = "Kein gueltiger regulaerer Ausdruck: $($_.Exception.InnerException.Message)"; return }
    $comp = Get-TargetComputer
    $p = Get-SelectedProfile
    $sid = if ($p -and -not $p.NoProfile) { $p.SID } else { '' }
    $key = "$comp|$sid"
    if ($script:DetectedSoftware -and $script:DetectedFor -eq $key) { Show-HMAeDetectResult $rx @($script:DetectedSoftware) $comp; return }
    $f.lGen.Text = "Programmliste von $comp wird gelesen ..."
    Get-HMSoftwareAsync -Computer $comp -Sid $sid -State @{ Rx = $rx } -OnDone {
        param($sw, $st)
        if (-not $script:Ae) { return }
        if ($null -eq $sw) { $script:Ae.F.lGen.Text = "$($st.Computer) nicht erreichbar - Programmliste nicht lesbar"; return }
        Show-HMAeDetectResult $st.State.Rx @($sw) $st.Computer
    }
}
function Show-HMAeDetectResult([string]$Rx, [object[]]$Software, [string]$Comp) {
    $hits = @($Software | Where-Object { "$($_.Name)" -match $Rx })
    $script:Ae.F.lGen.Text = if ($hits.Count) { "Treffer an ${Comp} ($($hits.Count)): " + (@($hits | Select-Object -First 8 | ForEach-Object { "$($_.Name) $($_.Version)".Trim() }) -join ' | ') } else { "Kein Treffer an $Comp (von $(@($Software).Count) Programmen). Tipp: Name so wie in 'Apps & Features', ^ = Anfang." }
}
function Test-HMAePackage {
    $f = $script:Ae.F
    $rx = "$($f.tPackage.Text)".Trim()
    if (-not $rx) { $f.lGen.Text = 'Paket ist leer.'; return }
    try { [void][regex]::new($rx) } catch { $f.lGen.Text = "Kein gueltiger regulaerer Ausdruck: $($_.Exception.InnerException.Message)"; return }
    $pk = @(); try { $pk = @(Get-SwPackages) } catch { }
    $hits = @($pk | Where-Object { "$($_.Id)" -match "(?i)$rx" -or "$($_.Settings.Name)" -match "(?i)$rx" })
    $f.lGen.Text = if ($hits.Count) { "Paket(e) in der Softwareverteilung: " + (@($hits | ForEach-Object { "$($_.Id)" }) -join ', ') } else { "Kein Paket gefunden ($($pk.Count) Pakete im Softwareverteilungs-Ordner)." }
}
function Test-HMAePath {
    $f = $script:Ae.F
    $i = Get-HMAeSelItem
    if (-not $i) { return }
    $comp = Get-TargetComputer
    $p = Get-SelectedProfile
    $sid = if ($p -and -not $p.NoProfile) { "$($p.SID)" } else { '' }
    $pp = if ($p -and -not $p.NoProfile) { "$($p.LocalPath)" } else { '' }
    $f.lICheck.Text = "Pruefe an $comp ..."
    Invoke-AsyncCommand -ScriptBlock {
        param($eng, $comp, $cred, $sid, $pp, $type, $path, $key, $filter)
        . $eng
        $c = @{ Computer = $comp; IsRemote = -not (Test-HMIsLocal $comp); Credential = $cred }
        try {
            if ($type -eq 'Reg') {
                $k = Resolve-HMRegKey $key $sid
                if ($key -match '^HK(CU|EY_CURRENT_USER)' -and -not $sid) { return 'Benutzer-Registry: zuerst oben einen Benutzer mit Profil waehlen' }
                $ps = 'Registry::' + ($k -replace '^HKU', 'HKEY_USERS' -replace '^HKLM', 'HKEY_LOCAL_MACHINE')
                $r = Invoke-HMTarget $c { param($ps, $sid) if ($sid -and $ps -like 'Registry::HKEY_USERS*' -and -not (Test-Path -LiteralPath "Registry::HKEY_USERS\$sid")) { 'NOTLOADED' } elseif (Test-Path -LiteralPath $ps) { 'OK' } else { 'MISSING' } } @($ps, $sid)
                switch ("$r") { 'OK' { "Vorhanden an ${comp}: $k" } 'NOTLOADED' { 'Benutzer-Registry nicht geladen (Benutzer nicht angemeldet) - beim Backup wird sie geladen, hier nicht pruefbar' } default { "NICHT vorhanden an ${comp}: $k" } }
            } else {
                if ($path -match '^\{(PROFILE|APPDATA|LOCALAPPDATA)\}' -and -not $pp) { return 'Benutzer-Pfad: zuerst oben einen Benutzer mit Profil waehlen' }
                $tenv = Get-HMTargetEnv $c $sid $pp
                $local = Resolve-HMToken $tenv $path
                $reach = Convert-HMPath $c $local
                if (-not (Test-Path -LiteralPath $reach)) { return "NICHT vorhanden an ${comp}: $local" }
                $files = if ($type -eq 'Files') { @(foreach ($fl in @($filter)) { Get-ChildItem -LiteralPath $reach -Filter $fl -File -Force -ErrorAction SilentlyContinue }) } else { @(Get-ChildItem -LiteralPath $reach -Recurse -File -Force -ErrorAction SilentlyContinue) }
                $sum = [long](@($files | Measure-Object Length -Sum).Sum)
                "Vorhanden an ${comp}: $local - $(@($files).Count) Dateien, $(Format-HMSize $sum)"
            }
        } catch { "FEHLER: $($_.Exception.Message)" }
    } -ArgumentList @($script:Engine, $comp, $script:RemoteCred, $sid, $pp, $i.Type, $i.Path, $i.Key, @($i.Filter)) -TimeoutSec 120 -OnComplete {
        param($r)
        if ($script:Ae) { $script:Ae.F.lICheck.Text = "$r" }
    }
}
# Auswahl-Dialog (Mehrfachauswahl mit Filter). Rueckgabe: gewaehlte Tags
function Show-HMAePick([string]$Title, [object[]]$Rows, [switch]$Single, $Owner = $null) {
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="620" Height="560" WindowStartupLocation="CenterOwner" Background="#FF1E1E2E">
  <DockPanel Margin="10">
    <TextBox x:Name="q" DockPanel.Dock="Top" Style="{DynamicResource DarkTextBox}" Margin="0,0,0,6"/>
    <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,8,0,0">
      <Button x:Name="ok" Content="Uebernehmen" Style="{DynamicResource BtnGreen}" Width="120" IsDefault="True"/>
      <Button x:Name="cancel" Content="Abbrechen" Style="{DynamicResource BtnDefault}" Width="100" IsCancel="True" Margin="0"/>
    </StackPanel>
    <ListBox x:Name="l"/>
  </DockPanel>
</Window>
'@
    $w = [System.Windows.Markup.XamlReader]::Parse($x)
    $w.Resources.MergedDictionaries.Add($script:Window.Resources)
    $w.Title = $Title
    if ($script:AppIcon) { $w.Icon = $script:AppIcon }
    $l = $w.FindName('l'); $q = $w.FindName('q')
    $l.SelectionMode = $(if ($Single) { 'Single' } else { 'Extended' })
    $fill = {
        $l.Items.Clear()
        foreach ($r in $Rows) { if (-not $q.Text -or "$($r.Text)" -like "*$($q.Text)*") { $li = New-Object System.Windows.Controls.ListBoxItem; $li.Content = "$($r.Text)"; $li.Tag = "$($r.Tag)"; [void]$l.Items.Add($li) } }
    }.GetNewClosure()
    & $fill
    $q.Add_TextChanged($fill)
    $w.FindName('ok').Add_Click({ $w.DialogResult = $true }.GetNewClosure())
    $l.Add_MouseDoubleClick({ $w.DialogResult = $true }.GetNewClosure())
    $w.Owner = $(if ($Owner) { $Owner } elseif ($script:Ae -and $script:Ae.Win) { $script:Ae.Win } else { $script:Window }); Set-HMWindowScale $w
    if ($w.ShowDialog() -ne $true) { return @() }
    return @($l.SelectedItems | ForEach-Object { "$($_.Tag)" })
}
function Add-HMAeLines($Box, [string[]]$New) {
    $cur = @(ConvertFrom-HMLines $Box.Text)
    $Box.Text = ConvertTo-HMLines (@($cur) + @($New | Where-Object { $cur -notcontains $_ }))
}
function Select-HMAeProcesses {
    $comp = Get-TargetComputer
    $script:Ae.F.lGen.Text = ''
    $script:Ae.F.bProc.IsEnabled = $false
    Invoke-AsyncCommand -ScriptBlock {
        param($eng, $comp, $cred)
        . $eng
        $c = @{ Computer = $comp; IsRemote = -not (Test-HMIsLocal $comp); Credential = $cred }
        try { @(Invoke-HMTarget $c { Get-Process | Where-Object { $_.SessionId -ne 0 } | Group-Object ProcessName | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Title = (@($_.Group | Where-Object { $_.MainWindowTitle } | ForEach-Object { $_.MainWindowTitle }) | Select-Object -First 1) } } }) } catch { "FEHLER: $($_.Exception.Message)" }
    } -ArgumentList @($script:Engine, $comp, $script:RemoteCred) -TimeoutSec 60 -State @{ Comp = $comp } -OnComplete {
        param($r, $st)
        if (-not $script:Ae) { return }
        $script:Ae.F.bProc.IsEnabled = $true
        if ($r -is [string]) { [void][System.Windows.MessageBox]::Show($script:Ae.Win, "$r", 'Prozesse', 'OK', 'Warning'); return }
        $rows = @(@($r) | Where-Object { $_ -and $_.Name } | Sort-Object Name | ForEach-Object { [pscustomobject]@{ Tag = "$($_.Name)"; Text = "$($_.Name)$(if ($_.Title) { "   - $($_.Title)" })" } })
        $sel = @(Show-HMAePick "Laufende Programme an $($st.Comp) (Benutzersitzungen) - Mehrfachauswahl mit Strg" $rows)
        if ($sel.Count) { Add-HMAeLines $script:Ae.F.tClose $sel }
    }
}
function Select-HMAeServices {
    $comp = Get-TargetComputer
    $script:Ae.F.bSvc.IsEnabled = $false
    Invoke-AsyncCommand -ScriptBlock {
        param($eng, $comp, $cred)
        . $eng
        $c = @{ Computer = $comp; IsRemote = -not (Test-HMIsLocal $comp); Credential = $cred }
        try { @(Invoke-HMTarget $c { Get-Service | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Display = $_.DisplayName; Status = "$($_.Status)" } } }) } catch { "FEHLER: $($_.Exception.Message)" }
    } -ArgumentList @($script:Engine, $comp, $script:RemoteCred) -TimeoutSec 60 -State @{ Comp = $comp } -OnComplete {
        param($r, $st)
        if (-not $script:Ae) { return }
        $script:Ae.F.bSvc.IsEnabled = $true
        if ($r -is [string]) { [void][System.Windows.MessageBox]::Show($script:Ae.Win, "$r", 'Dienste', 'OK', 'Warning'); return }
        $rows = @(@($r) | Where-Object { $_ -and $_.Name } | Sort-Object Display | ForEach-Object { [pscustomobject]@{ Tag = "$($_.Name)"; Text = "$($_.Display)   ($($_.Name), $(if ($_.Status -eq 'Running') { 'laeuft' } else { $_.Status }))" } })
        $sel = @(Show-HMAePick "Dienste an $($st.Comp) - Mehrfachauswahl mit Strg" $rows)
        if ($sel.Count) { Add-HMAeLines $script:Ae.F.tSvc $sel }
    }
}

# ----------------------------------------------------------------------------
# Speichern / Neu / Zuruecksetzen / Loeschen / Export / Import
# ----------------------------------------------------------------------------
# Eigene Eintraege nach Config\apps.json schreiben (vorher apps.json.bak), andere Felder der Datei bleiben erhalten
function Write-HMAeLocal([object[]]$Apps) {
    $p = Join-Path $script:ConfigDir 'apps.json'
    if (Test-Path -LiteralPath $p) { Copy-Item -LiteralPath $p -Destination "$p.bak" -Force -ErrorAction Stop }
    $h = [ordered]@{}
    if ($script:Ae.LocalObj) { foreach ($x in @($script:Ae.LocalObj.PSObject.Properties)) { if ($x.Name -ne 'Apps') { $h[$x.Name] = $x.Value } } }
    if (-not $h.Contains('_Info')) { $h._Info = 'Eigene Eintraege und Aenderungen am Programm-Katalog (gleiche Id wie in apps.default.json ueberschreibt). Bearbeiten: HUMig > Programme > Katalog bearbeiten.' }
    $h.Apps = @($Apps)
    $json = [pscustomobject]$h | ConvertTo-Json -Depth 12
    [System.IO.File]::WriteAllText($p, $json, (New-Object System.Text.UTF8Encoding $false))
    $script:Ae.Saved = $true
}
function Save-HMAeEntry {
    if ($script:Ae.ReadOnly -or -not $script:Ae.Cur) { return }
    $e = Get-HMAeForm
    $err = @(Test-HMAeEntry $e $script:Ae.IsNew)
    if ($err.Count) { [void][System.Windows.MessageBox]::Show($script:Ae.Win, "Bitte korrigieren:`n`n- $($err -join "`n- ")", 'Katalog', 'OK', 'Warning'); return }
    # Unveraenderter Standard-Eintrag: nichts speichern
    if (-not $script:Ae.IsNew -and $script:Ae.CurKind -eq 'Standard' -and (Get-HMAeJson $e) -eq $script:Ae.Snapshot) { $script:Ae.F.lState.Text = 'Keine Aenderung.'; return }
    $obj = ConvertFrom-HMAeEntry $e
    $list = @($script:Ae.Local | Where-Object { "$($_.Id)" -ne $e.Id }) + @($obj)
    try { Write-HMAeLocal $list } catch { [void][System.Windows.MessageBox]::Show($script:Ae.Win, "Speichern fehlgeschlagen: $($_.Exception.Message)", 'Katalog', 'OK', 'Error'); return }
    $script:Ae.F.lState.Text = "Gespeichert: $($e.Name) ($(Get-Date -Format 'HH:mm:ss')) - Config\apps.json (Sicherung apps.json.bak)"
    Out-Console "Programm-Katalog: '$($e.Name)' gespeichert (Config\apps.json)" 'Success'
    Import-HMAeData
    $k = @($script:Ae.All | Where-Object { $_.Id -eq $e.Id })[0]
    $script:Ae.Cur = $null
    Update-HMAeList
    if ($k) { Set-HMAeForm (ConvertTo-HMAeEntry $k.Obj) $k.Kind $false; Select-HMAeListItem $e.Id }
}
function New-HMAeEntry {
    if (-not (Confirm-HMAeDiscard)) { return }
    $n = 'App_Neu'; $c = 2
    while (@($script:Ae.All | Where-Object { $_.Id -ieq $n }).Count) { $n = "App_Neu$c"; $c++ }
    $e = ConvertTo-HMAeEntry ([pscustomobject]@{ Id = $n; Name = 'Neues Programm'; Detect = '^'; Items = @() })
    $script:Ae.Loading = $true; $script:Ae.F.lApps.SelectedItem = $null; $script:Ae.Loading = $false
    Set-HMAeForm $e 'eigen' $true
    $script:Ae.F.tabs.SelectedIndex = 0
    $script:Ae.F.tId.Focus() | Out-Null
}
function Reset-HMAeEntry {
    if ($script:Ae.ReadOnly -or $script:Ae.CurKind -ne 'geaendert') { return }
    $id = "$($script:Ae.Cur.Id)"
    if ("$([System.Windows.MessageBox]::Show($script:Ae.Win, "Eigene Aenderungen an '$($script:Ae.Cur.Name)' entfernen und den Standard-Eintrag verwenden?", 'Katalog', 'YesNo', 'Question'))" -ne 'Yes') { return }
    try { Write-HMAeLocal @($script:Ae.Local | Where-Object { "$($_.Id)" -ne $id }) } catch { [void][System.Windows.MessageBox]::Show($script:Ae.Win, "Speichern fehlgeschlagen: $($_.Exception.Message)", 'Katalog', 'OK', 'Error'); return }
    Out-Console "Programm-Katalog: '$id' auf Standard zurueckgesetzt" 'Info'
    Import-HMAeData
    $script:Ae.Cur = $null
    Update-HMAeList
    $k = @($script:Ae.All | Where-Object { $_.Id -eq $id })[0]
    if ($k) { Set-HMAeForm (ConvertTo-HMAeEntry $k.Obj) $k.Kind $false; Select-HMAeListItem $id }
}
function Remove-HMAeEntry {
    if ($script:Ae.ReadOnly -or -not $script:Ae.Cur) { return }
    if ($script:Ae.IsNew) { $script:Ae.Cur = $null; $script:Ae.IsNew = $false; Update-HMAeList; if ($script:Ae.F.lApps.Items.Count) { $script:Ae.F.lApps.SelectedIndex = 0 }; return }
    if ($script:Ae.CurKind -ne 'eigen') { return }
    $id = "$($script:Ae.Cur.Id)"
    if ("$([System.Windows.MessageBox]::Show($script:Ae.Win, "Eigenen Eintrag '$($script:Ae.Cur.Name)' loeschen?`n(Vorhandene Backups bleiben unveraendert.)", 'Katalog', 'YesNo', 'Warning'))" -ne 'Yes') { return }
    try { Write-HMAeLocal @($script:Ae.Local | Where-Object { "$($_.Id)" -ne $id }) } catch { [void][System.Windows.MessageBox]::Show($script:Ae.Win, "Speichern fehlgeschlagen: $($_.Exception.Message)", 'Katalog', 'OK', 'Error'); return }
    Out-Console "Programm-Katalog: '$id' geloescht" 'Info'
    Import-HMAeData
    $script:Ae.Cur = $null
    Update-HMAeList
    if ($script:Ae.F.lApps.Items.Count) { $script:Ae.F.lApps.SelectedIndex = 0 }
}
function Export-HMAeEntry {
    if (-not $script:Ae.Cur) { return }
    $e = Get-HMAeForm
    $d = New-Object Microsoft.Win32.SaveFileDialog
    $d.Filter = 'JSON (*.json)|*.json'; $d.FileName = "$($e.Id).json"
    if ($d.ShowDialog($script:Ae.Win) -ne $true) { return }
    try {
        [System.IO.File]::WriteAllText($d.FileName, ((ConvertFrom-HMAeEntry $e) | ConvertTo-Json -Depth 12), (New-Object System.Text.UTF8Encoding $false))
        $script:Ae.F.lState.Text = "Exportiert: $($d.FileName)"
    } catch { [void][System.Windows.MessageBox]::Show($script:Ae.Win, "Export fehlgeschlagen: $($_.Exception.Message)", 'Katalog', 'OK', 'Error') }
}
function Import-HMAeEntry {
    if ($script:Ae.ReadOnly -or -not (Confirm-HMAeDiscard)) { return }
    $d = New-Object Microsoft.Win32.OpenFileDialog
    $d.Filter = 'JSON (*.json)|*.json'
    if ($d.ShowDialog($script:Ae.Win) -ne $true) { return }
    try {
        $o = Get-Content -LiteralPath $d.FileName -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($o.Apps) { $arr = @($o.Apps); $o = $arr[0] }   # auch apps.json-Aufbau: erster Eintrag
        if (-not $o -or -not "$($o.Id)") { throw 'keine Id im Eintrag' }
    } catch { [void][System.Windows.MessageBox]::Show($script:Ae.Win, "Datei nicht lesbar: $($_.Exception.Message)", 'Katalog', 'OK', 'Error'); return }
    $k = @($script:Ae.All | Where-Object { $_.Id -eq "$($o.Id)" })[0]
    $script:Ae.Loading = $true; $script:Ae.F.lApps.SelectedItem = $null; $script:Ae.Loading = $false
    if ($k) { Set-HMAeForm (ConvertTo-HMAeEntry $k.Obj) $k.Kind $false; Select-HMAeListItem $k.Id }
    else { Set-HMAeForm (ConvertTo-HMAeEntry $o) 'eigen' $true }
    # Inhalt der Datei ins Formular (Speichern uebernimmt ihn)
    $imp = ConvertTo-HMAeEntry $o
    $keepSnap = $script:Ae.Snapshot; $keepOrig = $script:Ae.Orig
    Set-HMAeForm $imp $script:Ae.CurKind $script:Ae.IsNew
    $script:Ae.Snapshot = $keepSnap; $script:Ae.Orig = $keepOrig
    $script:Ae.F.lState.Text = "Importiert aus $($d.FileName) - mit Speichern uebernehmen"
}
# Nach dem Speichern: Katalog + Module neu laden, Backup-Liste aktualisieren (Haken bleiben), Programme neu erkennen
function Update-HMAeCatalog {
    try {
        Import-AppConfig
        if ($ui -and $ui.pnlBackupModules) { Update-BackupPanelKeepChecks }
        if ($ui -and $ui.cmbComputer) { Start-HMAppDetect }
        Out-Console 'Programm-Katalog neu geladen.' 'Info'
    } catch { Out-Console "Katalog neu laden: $($_.Exception.Message)" 'Warning' }
}
