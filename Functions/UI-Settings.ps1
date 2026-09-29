#Requires -Version 5.1
<#
.SYNOPSIS
    Einstellungsfenster: Allgemein, Restore, Ausnahmen, Module (inkl. eigene Module), Links, Update.
    Schreibt Config\settings.json, exceptions.json, modules.json, update.json (lokal, nicht im Repo).
.NOTES
    Wird im UI-Thread geladen (dot-source aus HUMig.ps1). Gibt $true zurueck, wenn gespeichert wurde.
#>

function ConvertTo-HMLines($Arr) { return ((@($Arr) | Where-Object { "$_".Trim() }) -join "`r`n") }
function ConvertFrom-HMLines([string]$Text) { return @($Text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique) }

function Show-SettingsDialog {
    param([string]$Tab = '')
    try {
        [xml]$x = Get-Content (Join-Path $script:AppRoot 'XAML\SettingsWindow.xaml') -Raw -Encoding UTF8
        $w = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $x))
    } catch { Out-Console "Einstellungsfenster nicht ladbar: $($_.Exception.Message)" 'Error'; return $false }
    $w.Resources.MergedDictionaries.Add($script:Window.Resources)
    if ($script:AppIcon) { $w.Icon = $script:AppIcon }
    if ($script:LogoImage) { $w.FindName('imgLogo').Source = $script:LogoImage }
    $w.Owner = $script:Window; Set-HMWindowScale $w
    $f = @{}
    foreach ($n in @('lblPath', 'btnOpenConfig', 'btnSave', 'btnCancel', 'tabs', 'txtRoot', 'btnRoot', 'cmbThreads', 'txtRetention', 'txtRetentionKeep', 'cmbUiScale', 'chkOverviewAuto', 'txtChecklist', 'chkChecklistAuto', 'tabSchools', 'dgSchools', 'btnSchoolAdd', 'btnSchoolDel', 'txtUsmt', 'btnUsmt', 'btnUsmtAdk', 'lblUsmt',
        'chkWlanClear', 'txtSwDir', 'btnSwDir', 'txtDrvDir', 'btnDrvDir', 'txtSubnet', 'txtDns', 'btnLauncher', 'btnShortcut', 'chkRGp', 'chkRWu', 'chkRNum', 'chkRFav', 'chkRFast', 'txtRScript', 'btnRScript',
        'tabExceptions', 'btnExcDefault', 'txtExPF', 'txtExPFi', 'txtExPMin', 'txtExSF', 'txtExSFi', 'txtExSMin', 'tabModules', 'txtNmName', 'cmbNmGroup',
        'cmbNmType', 'txtNmFilter', 'txtNmPath', 'btnNmAdd', 'btnModDel', 'btnModJson', 'btnAppEditor', 'dgModules', 'btnLinkAdd', 'btnLinkDel', 'dgLinks',
        'txtOwner', 'txtRepo', 'txtBranch', 'lblToken', 'btnTokenSet', 'btnTokenDel')) { $f[$n] = $w.FindName($n) }
    $f.lblPath.Text = $script:ConfigDir
    $st = @{ Saved = $false; Win = $w; F = $f }
    $script:SetDlg = $st

    # --- Allgemein --- (Grundwerte ohne Standort-Profil, das aktive Profil ueberlagert sie nur)
    $s = if ($script:SettingsBase) { $script:SettingsBase } else { $script:Settings }
    $f.txtRoot.Text = "$($s.BackupRoot)"
    foreach ($t in @(1, 4, 8, 16, 32, 64, 128)) { [void]$f.cmbThreads.Items.Add("$t") }
    $f.cmbThreads.SelectedItem = "$([int]$s.Threads)"; if (-not $f.cmbThreads.SelectedItem) { $f.cmbThreads.SelectedItem = '32' }
    $f.txtRetention.Text = "$([int]$s.RetentionDays)"
    $f.txtRetentionKeep.Text = "$(if ($null -ne $s.RetentionKeepPerUser) { [int]$s.RetentionKeepPerUser } else { 3 })"
    $f.chkOverviewAuto.IsChecked = ($s.OverviewAuto -ne $false)
    foreach ($t in @('Automatisch', '70 %', '80 %', '90 %', '100 %', '110 %', '125 %', '140 %', '160 %')) { [void]$f.cmbUiScale.Items.Add($t) }
    $cur = if ($script:UiScaleAuto) { 'Automatisch' } else { '{0} %' -f [int][Math]::Round([double]$script:UiScale * 100) }
    if (-not $f.cmbUiScale.Items.Contains($cur)) { [void]$f.cmbUiScale.Items.Add($cur) }
    $f.cmbUiScale.SelectedItem = $cur
    $f.txtUsmt.Text = "$($s.UsmtPath)"
    $f.txtSwDir.Text = "$($s.SoftwareFolder)"
    $f.txtDrvDir.Text = "$($s.DriverFolder)"
    $f.chkWlanClear.IsChecked = [bool]$s.WlanExportClearKey
    $f.txtSubnet.Text = "$($s.Network.SubnetMask)"
    $f.txtDns.Text = ConvertTo-HMLines $s.Network.DnsServers
    $u0 = Find-HMUsmt @{ Settings = [pscustomobject]@{ UsmtPath = $f.txtUsmt.Text }; ToolRoot = $script:AppRoot }
    $f.lblUsmt.Text = if ($u0) { "gefunden: $u0" } else { 'USMT nicht gefunden - nur fuer das Modul Windows-Einstellungen noetig (Windows ADK bzw. BIN\USMT\amd64)' }
    $f.txtUsmt.Add_LostFocus({ $u = Find-HMUsmt @{ Settings = [pscustomobject]@{ UsmtPath = $script:SetDlg.F.txtUsmt.Text }; ToolRoot = $script:AppRoot }; $script:SetDlg.F.lblUsmt.Text = if ($u) { "gefunden: $u" } else { 'USMT nicht gefunden' } })
    $f.btnRoot.Add_Click({
        $d = New-Object System.Windows.Forms.FolderBrowserDialog
        $d.Description = 'Backup-Ordner waehlen'
        if ($script:SetDlg.F.txtRoot.Text) { $d.SelectedPath = $script:SetDlg.F.txtRoot.Text }
        if ($d.ShowDialog() -eq 'OK') { $script:SetDlg.F.txtRoot.Text = $d.SelectedPath }
    })
    $f.btnUsmt.Add_Click({
        $d = New-Object System.Windows.Forms.FolderBrowserDialog
        $d.Description = 'Ordner mit scanstate.exe / loadstate.exe (z.B. ...\User State Migration Tool\amd64)'
        if ($d.ShowDialog() -eq 'OK') {
            $script:SetDlg.F.txtUsmt.Text = $d.SelectedPath
            $ok = Test-Path -LiteralPath (Join-Path $d.SelectedPath 'scanstate.exe')
            $script:SetDlg.F.lblUsmt.Text = if ($ok) { "gefunden: $($d.SelectedPath)" } else { 'In diesem Ordner liegt keine scanstate.exe' }
        }
    })
    $f.btnUsmtAdk.Add_Click({ Start-HMUsmtSetup; [void][System.Windows.MessageBox]::Show($script:SetDlg.Win, "Fortschritt in der Konsole. Das Feld 'USMT-Ordner' leer lassen - HUMig findet BIN\USMT\amd64 automatisch.", 'USMT', 'OK', 'Information') })
    $f.btnSwDir.Add_Click({
        $d = New-Object System.Windows.Forms.FolderBrowserDialog
        $d.Description = 'Ordner fuer die Softwareverteilung (Pakete)'
        if ($d.ShowDialog() -eq 'OK') { $script:SetDlg.F.txtSwDir.Text = $d.SelectedPath }
    })
    $f.btnDrvDir.Add_Click({
        $d = New-Object System.Windows.Forms.FolderBrowserDialog
        $d.Description = 'Ordner fuer die Treiberverteilung (Treiberpakete)'
        if ($d.ShowDialog() -eq 'OK') { $script:SetDlg.F.txtDrvDir.Text = $d.SelectedPath }
    })
    $f.btnLauncher.Add_Click({
        if (New-HMLauncher -Force -Name 'HUMig-Benutzer.exe') { Out-Console "Starter fuer den Benutzer-Modus erstellt: $(Join-Path $script:AppRoot 'HUMig-Benutzer.exe')" 'Success' }
        if (New-HMLauncher -Force) { Out-Console "Starter erstellt: $(Join-Path $script:AppRoot 'HUMig.exe')" 'Success'; [void][System.Windows.MessageBox]::Show($script:SetDlg.Win, "HUMig.exe wurde erstellt.`n`nKann an die Taskleiste angeheftet werden (Rechtsklick > An Taskleiste anheften).", 'HUMig', 'OK', 'Information') }
        else { [void][System.Windows.MessageBox]::Show($script:SetDlg.Win, 'Starter konnte nicht erstellt werden (Details in der Konsole). Start.cmd funktioniert weiterhin.', 'HUMig', 'OK', 'Warning') }
    })
    $f.btnShortcut.Add_Click({
        try { $l = New-HMDesktopShortcut; Out-Console "Desktop-Verknuepfung erstellt: $l" 'Success' } catch { Out-Console "Verknuepfung fehlgeschlagen: $($_.Exception.Message)" 'Error' }
    })

    # --- Restore ---
    $f.chkRGp.IsChecked = [bool]$s.Restore.GpUpdate
    $f.chkRWu.IsChecked = [bool]$s.Restore.DisableWUDrivers
    $f.chkRNum.IsChecked = [bool]$s.Restore.NumLockOn
    $f.chkRFav.IsChecked = [bool]$s.Restore.ExplorerFavorites
    $f.chkRFast.IsChecked = [bool]$s.Restore.FastBootOff
    $f.txtRScript.Text = "$($s.Restore.PostScript)"
    $f.txtChecklist.Text = ConvertTo-HMLines $s.RestoreChecklist
    $f.chkChecklistAuto.IsChecked = ($s.RestoreChecklistAuto -ne $false)
    $f.btnRScript.Add_Click({ $d = New-Object Microsoft.Win32.OpenFileDialog; $d.Filter = 'PowerShell (*.ps1)|*.ps1'; if ($d.ShowDialog() -eq $true) { $script:SetDlg.F.txtRScript.Text = $d.FileName } })

    # --- Ausnahmen ---
    $fillEx = {
        param($ex)
        $F = $script:SetDlg.F
        $F.txtExPF.Text = ConvertTo-HMLines $ex.ProfileFolders; $F.txtExPFi.Text = ConvertTo-HMLines $ex.ProfileFiles; $F.txtExPMin.Text = ConvertTo-HMLines $ex.MinimalProfileFolders
        $F.txtExSF.Text = ConvertTo-HMLines $ex.SystemFolders; $F.txtExSFi.Text = ConvertTo-HMLines $ex.SystemFiles; $F.txtExSMin.Text = ConvertTo-HMLines $ex.MinimalSystemFolders
    }
    $st.FillEx = $fillEx
    & $fillEx $script:Exceptions
    $f.btnExcDefault.Add_Click({
        if ("$([System.Windows.MessageBox]::Show($script:SetDlg.Win, 'Alle Ausnahmelisten auf den Standard zuruecksetzen (erst beim Speichern wirksam)?', 'Ausnahmen', 'YesNo', 'Question'))" -ne 'Yes') { return }
        & $script:SetDlg.FillEx (Read-JsonFile (Join-Path $script:ConfigDir 'exceptions.default.json'))
    })

    # --- Module ---
    $dtM = New-Object System.Data.DataTable
    foreach ($c in @('Id', 'Name', 'Gruppe', 'Herkunft')) { [void]$dtM.Columns.Add($c, [string]) }
    [void]$dtM.Columns.Add('Anzeigen', [bool]); [void]$dtM.Columns.Add('Standard', [bool])
    $st.DtM = $dtM
    $fillMods = {
        $dt = $script:SetDlg.DtM
        $dt.Rows.Clear()
        foreach ($m in $script:Modules) {
            $r = $dt.NewRow()
            $r.Id = $m.Id; $r.Name = $m.Name; $r.Gruppe = $m.Group
            $r.Herkunft = if ($script:DefaultModuleIds -contains $m.Id) { 'Standard' } else { 'Eigenes' }
            $r.Anzeigen = ($m.Show -ne $false); $r.Standard = [bool]$m.Default
            $dt.Rows.Add($r)
        }
    }
    $st.FillMods = $fillMods
    & $fillMods
    $f.dgModules.ItemsSource = $dtM.DefaultView
    foreach ($g in $script:Groups) { [void]$f.cmbNmGroup.Items.Add($g) }
    $f.cmbNmGroup.Text = 'Programme'
    foreach ($t in @('Ordner (komplett)', 'Dateien (mit Filter)', 'Registry-Schluessel')) { [void]$f.cmbNmType.Items.Add($t) }
    $f.cmbNmType.SelectedIndex = 0
    $f.btnNmAdd.Add_Click({
        $F = $script:SetDlg.F
        $name = "$($F.txtNmName.Text)".Trim(); $path = "$($F.txtNmPath.Text)".Trim(); $grp = "$($F.cmbNmGroup.Text)".Trim()
        if (-not $name -or -not $path) { [void][System.Windows.MessageBox]::Show($script:SetDlg.Win, 'Name und Pfad/Schluessel angeben.', 'Eigenes Modul', 'OK', 'Warning'); return }
        if (-not $grp) { $grp = 'Programme' }
        $type = switch ($F.cmbNmType.SelectedIndex) { 1 { 'Files' } 2 { 'Reg' } default { 'Folder' } }
        if ($type -eq 'Reg' -and $path -notmatch '^(HKCU|HKLM)\\.+') { [void][System.Windows.MessageBox]::Show($script:SetDlg.Win, 'Registry-Schluessel muss mit HKCU\ oder HKLM\ beginnen.', 'Eigenes Modul', 'OK', 'Warning'); return }
        if ($type -ne 'Reg' -and $path -notmatch '^(\{[A-Z0-9]+\}|[A-Za-z]:\\)') { [void][System.Windows.MessageBox]::Show($script:SetDlg.Win, 'Pfad muss mit einem Platzhalter wie {APPDATA} oder einem Laufwerk (C:\...) beginnen.', 'Eigenes Modul', 'OK', 'Warning'); return }
        $flt = @(("$($F.txtNmFilter.Text)" -split '[;,\s]+') | Where-Object { $_ })
        if ($type -eq 'Files' -and -not $flt.Count) { [void][System.Windows.MessageBox]::Show($script:SetDlg.Win, "Bei 'Dateien' einen Filter angeben (z.B. *.xml).", 'Eigenes Modul', 'OK', 'Warning'); return }
        $id = 'Custom_' + (($name -replace '[^A-Za-z0-9]', '')).Substring(0, [Math]::Min(30, ($name -replace '[^A-Za-z0-9]', '').Length))
        if ($id -eq 'Custom_') { $id = 'Custom_' + [guid]::NewGuid().ToString('N').Substring(0, 8) }
        $isUser = ($path -match '^\{(PROFILE|APPDATA|LOCALAPPDATA)\}') -or ($path -match '^HKCU\\')
        $item = [ordered]@{ Type = $type; Name = 'DATA' }
        if ($type -eq 'Reg') { $item.Name = 'REG'; $item.Key = $path } else { $item.Path = $path }
        if ($type -eq 'Files') { $item.Filter = $flt }
        $mod = [pscustomobject][ordered]@{ Id = $id; Name = $name; Group = $grp; Default = $true; Scope = $(if ($isUser) { 'User' } else { 'Machine' }); Remote = $true; Hint = "Eigenes Modul: $path"; Items = @([pscustomobject]$item) }
        $mp = Join-Path $script:ConfigDir 'modules.json'
        $cur = Read-JsonFile $mp
        $mods = @(); $pre = @()
        if ($cur) { $mods = @($cur.Modules | Where-Object { $_ -and $_.Id -ne $id }); $pre = @($cur.Presets | Where-Object { $_ }) }
        $mods += $mod
        Write-JsonFile $mp ([pscustomobject]@{ _Info = 'Eigene Module/Vorlagen (vom Einstellungsfenster gepflegt). Gleiche Id wie in modules.default.json ueberschreibt das Standardmodul.'; Modules = $mods; Presets = $pre }) 8
        Import-AppConfig
        & $script:SetDlg.FillMods
        $F.txtNmName.Text = ''; $F.txtNmPath.Text = ''; $F.txtNmFilter.Text = ''
        Out-Console "Eigenes Modul '$name' angelegt" 'Success'
        $script:SetDlg.Saved = $true
    })
    $f.btnModDel.Add_Click({
        $F = $script:SetDlg.F
        $rv = $F.dgModules.SelectedItem
        if (-not $rv) { return }
        if ($rv.Row.Herkunft -ne 'Eigenes') { [void][System.Windows.MessageBox]::Show($script:SetDlg.Win, "Standard-Module koennen nicht geloescht werden - 'Anzeigen' abhaken, um sie auszublenden.", 'Module', 'OK', 'Information'); return }
        $id = $rv.Row.Id
        if ("$([System.Windows.MessageBox]::Show($script:SetDlg.Win, "Eigenes Modul '$($rv.Row.Name)' loeschen?", 'Module', 'YesNo', 'Question'))" -ne 'Yes') { return }
        $mp = Join-Path $script:ConfigDir 'modules.json'
        $cur = Read-JsonFile $mp
        if ($cur) {
            $cur.Modules = @($cur.Modules | Where-Object { $_.Id -ne $id })
            Write-JsonFile $mp $cur 8
        }
        Import-AppConfig
        & $script:SetDlg.FillMods
        $script:SetDlg.Saved = $true
    })
    $f.btnAppEditor.Add_Click({ Show-HMAppEditor -Owner $script:SetDlg.Win })
    $f.btnModJson.Add_Click({
        $mp = Join-Path $script:ConfigDir 'modules.json'
        if (-not (Test-Path -LiteralPath $mp)) { Write-JsonFile $mp ([pscustomobject]@{ _Info = 'Eigene Module/Vorlagen. Aufbau wie modules.default.json.'; Modules = @(); Presets = @() }) }
        Start-Process notepad.exe -ArgumentList "`"$mp`""
        [void][System.Windows.MessageBox]::Show($script:SetDlg.Win, "modules.json wird im Editor geoeffnet.`nAenderungen werden nach dem Speichern beim naechsten Oeffnen der Einstellungen bzw. Neustart von HUMig wirksam.", 'Module', 'OK', 'Information')
    })

    # --- Links ---
    $dtL = New-Object System.Data.DataTable
    [void]$dtL.Columns.Add('Name', [string]); [void]$dtL.Columns.Add('Url', [string]); [void]$dtL.Columns.Add('CopySerial', [bool])
    foreach ($l in @($s.Links)) { if ($l) { $r = $dtL.NewRow(); $r.Name = "$($l.Name)"; $r.Url = "$($l.Url)"; $r.CopySerial = [bool]$l.CopySerial; $dtL.Rows.Add($r) } }
    $st.DtL = $dtL
    $f.dgLinks.ItemsSource = $dtL.DefaultView
    $f.btnLinkAdd.Add_Click({ $r = $script:SetDlg.DtL.NewRow(); $r.Name = 'Neuer Link'; $r.Url = 'https://'; $r.CopySerial = $false; $script:SetDlg.DtL.Rows.Add($r) })
    $f.btnLinkDel.Add_Click({ $rv = $script:SetDlg.F.dgLinks.SelectedItem; if ($rv) { $rv.Row.Delete() } })

    # --- Standorte ---
    $dtS = New-Object System.Data.DataTable
    foreach ($c in @('Name', 'BackupRoot', 'SoftwareFolder', 'DriverFolder', 'UsmtPath', 'ADServer', 'SubnetMask', 'DnsServers', 'Note')) { [void]$dtS.Columns.Add($c, [string]) }
    foreach ($pr in @($s.Profiles)) {
        if (-not $pr -or -not "$($pr.Name)".Trim()) { continue }
        $r = $dtS.NewRow()
        $r.Name = "$($pr.Name)"; $r.BackupRoot = "$($pr.BackupRoot)"; $r.SoftwareFolder = "$($pr.SoftwareFolder)"; $r.DriverFolder = "$($pr.DriverFolder)"; $r.UsmtPath = "$($pr.UsmtPath)"; $r.ADServer = "$($pr.ADServer)"
        $r.SubnetMask = "$($pr.SubnetMask)"; $r.DnsServers = (@($pr.DnsServers | Where-Object { $_ }) -join ', '); $r.Note = "$($pr.Note)"
        $dtS.Rows.Add($r)
    }
    $st.DtS = $dtS
    $f.dgSchools.ItemsSource = $dtS.DefaultView
    $f.btnSchoolAdd.Add_Click({ $r = $script:SetDlg.DtS.NewRow(); $r.Name = "Standort $($script:SetDlg.DtS.Rows.Count + 1)"; $script:SetDlg.DtS.Rows.Add($r) })
    $f.btnSchoolDel.Add_Click({ $rv = $script:SetDlg.F.dgSchools.SelectedItem; if ($rv) { $rv.Row.Delete() } })

    # --- Update ---
    $f.txtOwner.Text = $script:UpdateOwner; $f.txtRepo.Text = $script:UpdateRepo; $f.txtBranch.Text = $script:UpdateBranch
    $updTok = { $script:SetDlg.F.lblToken.Text = if (Test-Path -LiteralPath (Get-GitHubTokenFile)) { 'gespeichert' } elseif ("$env:HUMIG_GITHUB_TOKEN".Trim()) { 'aus Umgebungsvariable' } else { 'keiner' } }
    $st.UpdTok = $updTok
    & $updTok
    $f.btnTokenSet.Add_Click({
        $c = Get-Credential -UserName 'github' -Message 'GitHub-Token (Nur-Lese) als Kennwort eingeben - wird verschluesselt gespeichert'
        if ($c) { $c | Export-Clixml -Path (Get-GitHubTokenFile) -Force; Out-Console 'GitHub-Token gespeichert (DPAPI)' 'Success' }
        & $script:SetDlg.UpdTok
    })
    $f.btnTokenDel.Add_Click({ Remove-Item -LiteralPath (Get-GitHubTokenFile) -Force -ErrorAction SilentlyContinue; & $script:SetDlg.UpdTok })

    # --- Buttons ---
    $f.btnOpenConfig.Add_Click({ Start-Process explorer.exe -ArgumentList "`"$($script:ConfigDir)`"" })
    $f.btnCancel.Add_Click({ $script:SetDlg.Win.Close() })
    $f.btnSave.Add_Click({
        $F = $script:SetDlg.F; $W = $script:SetDlg.Win
        $ret = 0
        if (-not [int]::TryParse("$($F.txtRetention.Text)".Trim(), [ref]$ret) -or $ret -lt 0 -or $ret -gt 3650) { [void][System.Windows.MessageBox]::Show($W, 'Aufbewahrung: Zahl 0 bis 3650', 'Einstellungen', 'OK', 'Warning'); return }
        $keep = 0
        if (-not [int]::TryParse("$($F.txtRetentionKeep.Text)".Trim(), [ref]$keep) -or $keep -lt 0 -or $keep -gt 100) { [void][System.Windows.MessageBox]::Show($W, 'Aufbewahrung: Anzahl 0 bis 100', 'Einstellungen', 'OK', 'Warning'); return }
        $F.dgSchools.CommitEdit(); $F.dgSchools.CommitEdit()
        $schools = @(foreach ($r in $script:SetDlg.DtS.Rows) {
            if ($r.RowState -eq 'Deleted' -or -not "$($r.Name)".Trim()) { continue }
            [ordered]@{ Name = "$($r.Name)".Trim(); BackupRoot = "$($r.BackupRoot)".Trim(); SoftwareFolder = "$($r.SoftwareFolder)".Trim(); DriverFolder = "$($r.DriverFolder)".Trim(); UsmtPath = "$($r.UsmtPath)".Trim(); ADServer = "$($r.ADServer)".Trim()
                SubnetMask = "$($r.SubnetMask)".Trim(); DnsServers = @("$($r.DnsServers)" -split '[,;\s]+' | Where-Object { $_ }); Note = "$($r.Note)".Trim() }
        })
        $dup = @($schools | Group-Object { $_.Name.ToUpperInvariant() } | Where-Object { $_.Count -gt 1 })
        if ($dup.Count) { [void][System.Windows.MessageBox]::Show($W, "Standort-Name doppelt: $($dup[0].Group[0].Name)", 'Einstellungen', 'OK', 'Warning'); return }
        $root = "$($F.txtRoot.Text)".Trim()
        if ($root -and -not (Test-Path -LiteralPath $root)) {
            if ("$([System.Windows.MessageBox]::Show($W, "Backup-Ordner '$root' existiert nicht. Anlegen?", 'Einstellungen', 'YesNo', 'Question'))" -ne 'Yes') { return }
            try { New-Item -ItemType Directory -Path $root -Force -ErrorAction Stop | Out-Null } catch { [void][System.Windows.MessageBox]::Show($W, "Anlegen fehlgeschlagen: $($_.Exception.Message)", 'Einstellungen', 'OK', 'Error'); return }
        }
        # settings.json: vorhandene (auch unbekannte) Schluessel behalten
        $p = Join-Path $script:ConfigDir 'settings.json'
        $cur = Read-JsonFile $p
        $h = [ordered]@{}
        if ($cur) { foreach ($x in $cur.PSObject.Properties) { if ($x.Name -ne '_Info') { $h[$x.Name] = $x.Value } } }
        $h.BackupRoot = $root
        $h.Threads = if ($F.cmbThreads.SelectedItem) { [int]$F.cmbThreads.SelectedItem } else { 32 }
        $h.RetentionDays = $ret
        $h.RetentionKeepPerUser = $keep
        $h.OverviewAuto = [bool]$F.chkOverviewAuto.IsChecked
        $us = "$($F.cmbUiScale.SelectedItem)"
        $h.UiScale = if ($us -match '^(\d+)\s*%$') { [Math]::Round([double]$Matches[1] / 100, 2) } else { 0 }
        $h.RestoreChecklist = @(ConvertFrom-HMLines $F.txtChecklist.Text)
        $h.RestoreChecklistAuto = [bool]$F.chkChecklistAuto.IsChecked
        $h.Profiles = @($schools)
        if ($h.Contains('ActiveProfile') -and "$($h.ActiveProfile)" -and -not @($schools | Where-Object { $_.Name -eq "$($h.ActiveProfile)" }).Count) { $h.ActiveProfile = '' }
        $h.UsmtPath = "$($F.txtUsmt.Text)".Trim()
        $h.WlanExportClearKey = [bool]$F.chkWlanClear.IsChecked
        $h.SoftwareFolder = "$($F.txtSwDir.Text)".Trim()
        $h.DriverFolder = "$($F.txtDrvDir.Text)".Trim()
        $h.Network = [ordered]@{ SubnetMask = "$($F.txtSubnet.Text)".Trim(); DnsServers = @(ConvertFrom-HMLines $F.txtDns.Text) }
        $rs = [ordered]@{}
        if ($s.Restore) { foreach ($x in $s.Restore.PSObject.Properties) { $rs[$x.Name] = $x.Value } }
        $rs.GpUpdate = [bool]$F.chkRGp.IsChecked; $rs.DisableWUDrivers = [bool]$F.chkRWu.IsChecked; $rs.NumLockOn = [bool]$F.chkRNum.IsChecked
        $rs.ExplorerFavorites = [bool]$F.chkRFav.IsChecked; $rs.FastBootOff = [bool]$F.chkRFast.IsChecked; $rs.PostScript = "$($F.txtRScript.Text)".Trim()
        $h.Restore = $rs
        $F.dgLinks.CommitEdit(); $F.dgLinks.CommitEdit()
        $h.Links = @(foreach ($r in $script:SetDlg.DtL.Rows) { if ($r.RowState -ne 'Deleted' -and "$($r.Name)".Trim() -and "$($r.Url)".Trim()) { [ordered]@{ Name = "$($r.Name)".Trim(); Url = "$($r.Url)".Trim(); CopySerial = [bool]($r.CopySerial -eq $true) } } })
        $F.dgModules.CommitEdit(); $F.dgModules.CommitEdit()
        $ov = [ordered]@{}
        foreach ($r in $script:SetDlg.DtM.Rows) {
            $defShow = $true; $defDef = $false
            $orig = @($script:ModuleCatalog | Where-Object { $_.Id -eq $r.Id })[0]
            if ($orig) { $defShow = ($orig.Show -ne $false); $defDef = [bool]$orig.Default }
            $show = [bool]($r.Anzeigen -eq $true); $dfl = [bool]($r.Standard -eq $true)
            if ($show -ne $defShow -or $dfl -ne $defDef) { $ov[$r.Id] = [ordered]@{ Show = $show; Default = $dfl } }
        }
        $h.ModuleOverrides = $ov
        Write-JsonFile $p ([pscustomobject]$h) 8
        # Ausnahmen
        $ex = [ordered]@{
            _Info = 'Ausnahmen fuer Robocopy (vom Einstellungsfenster gepflegt).'
            ProfileFolders = @(ConvertFrom-HMLines $F.txtExPF.Text); ProfileFiles = @(ConvertFrom-HMLines $F.txtExPFi.Text)
            SystemFolders = @(ConvertFrom-HMLines $F.txtExSF.Text); SystemFiles = @(ConvertFrom-HMLines $F.txtExSFi.Text)
            MinimalProfileFolders = @(ConvertFrom-HMLines $F.txtExPMin.Text); MinimalSystemFolders = @(ConvertFrom-HMLines $F.txtExSMin.Text)
        }
        Write-JsonFile (Join-Path $script:ConfigDir 'exceptions.json') ([pscustomobject]$ex)
        # Update-Quelle
        $o = "$($F.txtOwner.Text)".Trim(); $rp = "$($F.txtRepo.Text)".Trim(); $b = "$($F.txtBranch.Text)".Trim()
        if ($o -and $rp) { Write-JsonFile (Join-Path $script:ConfigDir 'update.json') ([pscustomobject][ordered]@{ Owner = $o; Repo = $rp; Branch = $(if ($b) { $b } else { 'main' }) }) }
        $script:SetDlg.Saved = $true
        Out-Console 'Einstellungen gespeichert' 'Success'
        $W.Close()
    })

    switch ($Tab) {
        'Ausnahmen' { $f.tabs.SelectedItem = $f.tabExceptions }
        'Module' { $f.tabs.SelectedItem = $f.tabModules }
        'Standorte' { $f.tabs.SelectedItem = $f.tabSchools }
    }
    [void]$w.ShowDialog()
    $saved = $st.Saved
    $script:SetDlg = $null
    return $saved
}
