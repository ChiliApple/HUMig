#Requires -Version 5.1
<#
.SYNOPSIS
    Einstellungsfenster: Allgemein, Restore, Ausnahmen, Module (inkl. eigene Module), Links, Update.
    Schreibt Config\settings.json, exceptions.json, modules.json, update.json (lokal, nicht im Repo).
.NOTES
    Wird im UI-Thread geladen (dot-source aus HUMig.ps1). Gibt $true zurueck, wenn gespeichert wurde.
#>

# --- Teams-Ziele im Einstellungsfenster ($script:SetDlg.TeamsList: Id, Name, Url, Cats, Saved, NewUrl)
# Vergleichswert einer Ziel-Liste (geaendert ja/nein)
# Wurzel einer Freigabe (\\server\freigabe) aus einem UNC-Pfad, sonst ''
function Get-HMShareRoot([string]$Path) {
    if ("$Path" -match '^(\\\\[^\\/]+\\[^\\/]+)') { return $Matches[1] }
    return ''
}
function Get-HMTeamsListKey($List) {
    $parts = foreach ($t in @($List | Where-Object { $_ })) {
        $c = ConvertTo-HMNotifyCats $t.Cats
        $bits = foreach ($n in $script:HMNotifyCats.Keys) { [int][bool]$c[$n] }
        '{0}|{1}|{2}|{3}|{4}' -f "$($t.Id)", "$($t.Name)".Trim(), "$($t.Url)".Trim(), ($bits -join ''), (@(ConvertTo-HMNotifySbProfiles $t.SbProfiles) -join '/')
    }
    return (@($parts) -join ';')
}
# Felder des gewaehlten Ziels in die Liste uebernehmen
function Save-HMSetTeamsCur {
    $S = $script:SetDlg
    if (-not $S -or $S.TeamsCur -lt 0 -or $S.TeamsCur -ge $S.TeamsList.Count) { return }
    $t = $S.TeamsList[$S.TeamsCur]
    $t.Name = "$($S.F.txtTeamsName.Text)".Trim()
    foreach ($n in $S.TeamsChk.Keys) { $t.Cats[$n] = [bool]$S.TeamsChk[$n].IsChecked }
    # Server-Backup-Profile: "alle" oder Auswahl (keine Auswahl = alle)
    $t.SbProfiles = if ($S.TeamsSbAll.IsChecked) { @() } else { @($S.TeamsSbChk.Keys | Where-Object { $S.TeamsSbChk[$_].IsChecked }) }
    $u = "$($S.F.pwdTeams.Password)".Trim()
    if ($u) { $t.Url = $u; $t.NewUrl = $true }
    $S.F.pwdTeams.Password = ''
}
# Auswahlliste neu fuellen und Ziel $Select anzeigen (-1 = keins)
function Update-HMSetTeamsCombo([int]$Select) {
    $S = $script:SetDlg; $F = $S.F
    $S.TeamsLoading = $true
    $F.cmbTeams.Items.Clear()
    foreach ($t in $S.TeamsList) { [void]$F.cmbTeams.Items.Add($(if ("$($t.Name)") { "$($t.Name)" } else { '(ohne Namen)' })) }
    if ($Select -ge $S.TeamsList.Count) { $Select = $S.TeamsList.Count - 1 }
    if ($Select -lt 0 -and $S.TeamsList.Count) { $Select = 0 }
    $F.cmbTeams.SelectedIndex = $Select
    $S.TeamsLoading = $false
    $F.pwdTeams.Password = ''   # Adresse nie beim naechsten Ziel stehen lassen (Aufrufer haben vorher gespeichert)
    $S.TeamsCur = $Select
    $has = $Select -ge 0
    foreach ($c in @(@($F.txtTeamsName, $F.pwdTeams, $F.btnTeamsTest, $F.btnTeamsDel, $S.TeamsSbAll) + @($S.TeamsChk.Values))) { if ($isAdmin) { $c.IsEnabled = $has } }
    if (-not $has) {
        $F.txtTeamsName.Text = ''
        foreach ($n in $S.TeamsChk.Keys) { $S.TeamsChk[$n].IsChecked = $false }
        $S.TeamsSbAll.IsChecked = $true
        foreach ($cb in @($S.TeamsSbChk.Values)) { $cb.IsChecked = $false; $cb.IsEnabled = $false }
        $F.lblTeams.Text = "Kein Ziel eingerichtet (Benachrichtigung aus) - mit 'Neues Ziel' anlegen."
        return
    }
    $t = $S.TeamsList[$Select]
    $F.txtTeamsName.Text = "$($t.Name)"
    foreach ($n in $S.TeamsChk.Keys) { $S.TeamsChk[$n].IsChecked = [bool](Test-HMNotifyCat $t $n) }
    $sel = @(ConvertTo-HMNotifySbProfiles $t.SbProfiles)
    $S.TeamsSbAll.IsChecked = (-not $sel.Count)
    foreach ($k in @($S.TeamsSbChk.Keys)) { $S.TeamsSbChk[$k].IsChecked = [bool]($sel | Where-Object { $_ -ieq $k }); $S.TeamsSbChk[$k].IsEnabled = ($isAdmin -and $sel.Count -gt 0) }
    $F.lblTeams.Text = if ($t.Saved -and -not $t.NewUrl -and "$($t.Url)") { "Adresse gespeichert - zum Aendern neue Adresse eintragen. $($S.TeamsList.Count) Ziel(e) auf diesem PC." }
        elseif ("$($t.Url)") { 'Adresse eingetragen - wird mit Speichern uebernommen.' }
        else { 'Noch keine Adresse - Adresse aus der Teams-App Workflows eintragen.' }
}

function ConvertTo-HMLines($Arr) { return ((@($Arr) | Where-Object { "$_".Trim() }) -join "`r`n") }
function ConvertFrom-HMLines([string]$Text) { return @($Text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique) }

# Anzeige unter dem USMT-Feld: gefunden / eingetragener Ordner ohne scanstate.exe (dann wird ein anderer verwendet)
function Get-HMUsmtLabel([string]$Path) {
    $u = Find-HMUsmt @{ Settings = [pscustomobject]@{ UsmtPath = $Path }; ToolRoot = $script:AppRoot }
    $p = "$Path".Trim().TrimEnd('\')
    if ($p -and -not (Test-Path -LiteralPath $p)) { return "ACHTUNG: eingetragener Ordner existiert nicht ($p)$(if ($u) { " - verwendet wird: $u" } else { ' - USMT nicht gefunden' })" }
    if ($p -and $u -and -not "$u".StartsWith($p, [StringComparison]::OrdinalIgnoreCase)) { return "ACHTUNG: im eingetragenen Ordner liegt keine scanstate.exe - verwendet wird: $u (Feld leeren = automatisch suchen)" }
    if ($u) { return "gefunden: $u" }
    return 'USMT nicht gefunden - nur fuer das Modul Windows-Einstellungen noetig (Windows ADK bzw. BIN\USMT\amd64)'
}

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
    foreach ($n in @('lblPath', 'btnOpenConfig', 'btnSave', 'btnCancel', 'tabs', 'txtRoot', 'btnRoot', 'cmbThreads', 'txtRetention', 'txtRetentionKeep', 'txtDeletedKeep', 'txtDeletedMass', 'txtFeedbackMail', 'cmbUiScale', 'chkOverviewAuto', 'chkStatusPage', 'chkSplashAnim', 'txtChecklist', 'chkChecklistAuto', 'tabSchools', 'dgSchools', 'btnSchoolAdd', 'btnSchoolDel', 'txtUsmt', 'btnUsmt', 'btnUsmtAdk', 'lblUsmt',
        'chkWlanClear', 'txtSwDir', 'btnSwDir', 'txtDrvDir', 'btnDrvDir', 'txtSubnet', 'txtDns', 'btnLauncher', 'btnShortcut', 'chkRGp', 'chkRWu', 'chkRNum', 'chkRFav', 'chkRFast', 'txtRScript', 'btnRScript', 'chkROfferApps', 'chkRVerify', 'cmbTeams', 'btnTeamsAdd', 'txtTeamsName', 'pwdTeams', 'btnTeamsTest', 'btnTeamsDel', 'lblTeams', 'pnlTeamsCats', 'pnlTeamsSbProfiles',
        'tabExceptions', 'btnExcDefault', 'txtExPF', 'txtExPFi', 'txtExPMin', 'txtExSF', 'txtExSFi', 'txtExSMin', 'tabModules', 'txtNmName', 'cmbNmGroup',
        'cmbNmType', 'txtNmFilter', 'txtNmPath', 'btnNmAdd', 'btnModDel', 'btnModJson', 'btnAppEditor', 'dgModules', 'btnLinkAdd', 'btnLinkDel', 'dgLinks',
        'txtOwner', 'txtRepo', 'txtBranch', 'lblToken', 'btnTokenSet', 'btnTokenDel', 'tabUpdate', 'cmbChannel', 'lblInstalled', 'btnVersions', 'chkRequireSig', 'txtSignerThumb', 'chkUseBranch',
        'tabRemote', 'chkRemoteAuto', 'txtRemotePort', 'cmbRemoteTime', 'txtRemoteNets', 'txtRemoteUser', 'btnRemoteSetup', 'btnRemoteUnsetup', 'lblRemoteSetup', 'chkSchedBackup', 'chkSchedServer', 'chkSchedAu')) { $f[$n] = $w.FindName($n) }
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
    $f.txtDeletedKeep.Text = "$(if ($null -ne $s.DeletedKeepDays) { [int]$s.DeletedKeepDays } else { 90 })"
    $f.txtDeletedMass.Text = "$(if ($null -ne $s.DeletedMassPercent) { [int]$s.DeletedMassPercent } else { 20 })"
    $f.chkOverviewAuto.IsChecked = ($s.OverviewAuto -ne $false)
    $f.chkStatusPage.IsChecked = ($s.ShowStatusPage -ne $false)
    $f.chkSplashAnim.IsChecked = ($s.SplashAnimation -ne $false)
    $f.txtFeedbackMail.Text = "$($s.FeedbackMail)"
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
    $f.lblUsmt.Text = Get-HMUsmtLabel $f.txtUsmt.Text
    $f.txtUsmt.Add_LostFocus({ $script:SetDlg.F.lblUsmt.Text = Get-HMUsmtLabel $script:SetDlg.F.txtUsmt.Text })
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
            $script:SetDlg.F.lblUsmt.Text = Get-HMUsmtLabel $d.SelectedPath
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
    # Teams-Benachrichtigung: mehrere Ziele, je Ziel Name, Adresse, Kategorien (Adressen nur auf diesem PC, verschluesselt in HKLM)
    $st.TeamsCfg = Get-HMNotifyConfig
    $st.TeamsList = New-Object System.Collections.ArrayList
    foreach ($t in @($st.TeamsCfg.Targets | Where-Object { $_ })) { [void]$st.TeamsList.Add(@{ Id = "$($t.Id)"; Name = "$($t.Name)"; Url = "$($t.Url)"; Cats = (ConvertTo-HMNotifyCats $t.Cats); SbProfiles = @(ConvertTo-HMNotifySbProfiles $t.SbProfiles); Saved = $true; NewUrl = $false }) }
    $st.TeamsOrig = Get-HMTeamsListKey $st.TeamsList
    $st.TeamsCur = -1; $st.TeamsLoading = $false
    $st.TeamsChk = [ordered]@{}
    foreach ($n in $script:HMNotifyCats.Keys) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = "$($script:HMNotifyCats[$n][0])"
        $cb.Margin = [System.Windows.Thickness]::new(0, 2, 0, 0)
        [void]$f.pnlTeamsCats.Children.Add($cb)
        $st.TeamsChk[$n] = $cb
    }
    # Server-Backup-Meldungen je Ziel auf bestimmte Profile beschraenken (Profile aus Config\serverbackup.json + schon gewaehlte)
    $sbNames = New-Object System.Collections.Generic.List[string]
    try { $sbc = Read-JsonFile (Join-Path $script:ConfigDir 'serverbackup.json'); foreach ($p in @($sbc.Profiles)) { if ($p -and "$($p.Name)".Trim()) { $sbNames.Add("$($p.Name)".Trim()) } } } catch { }
    foreach ($t in $st.TeamsList) { foreach ($x in @($t.SbProfiles)) { if (-not ($sbNames | Where-Object { $_ -ieq $x })) { $sbNames.Add("$x") } } }
    $st.TeamsSbAll = New-Object System.Windows.Controls.CheckBox
    $st.TeamsSbAll.Content = 'alle Profile'; $st.TeamsSbAll.Margin = [System.Windows.Thickness]::new(0, 2, 14, 0)
    [void]$f.pnlTeamsSbProfiles.Children.Add($st.TeamsSbAll)
    $st.TeamsSbChk = [ordered]@{}
    foreach ($nm in $sbNames) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = $nm; $cb.Margin = [System.Windows.Thickness]::new(0, 2, 14, 0)
        [void]$f.pnlTeamsSbProfiles.Children.Add($cb)
        $st.TeamsSbChk[$nm] = $cb
    }
    if (-not $sbNames.Count) { $tb = New-Object System.Windows.Controls.TextBlock; $tb.Text = '(auf diesem PC keine Server-Backup-Profile)'; $tb.Foreground = New-Brush '#FF6C7086'; $tb.Margin = [System.Windows.Thickness]::new(0, 2, 0, 0); [void]$f.pnlTeamsSbProfiles.Children.Add($tb) }
    $st.TeamsSbAll.Add_Click({
        $S = $script:SetDlg
        $all = [bool]$S.TeamsSbAll.IsChecked
        foreach ($cb in @($S.TeamsSbChk.Values)) { $cb.IsEnabled = -not $all; if ($all) { $cb.IsChecked = $false } }
        if (-not $all -and -not $S.TeamsSbChk.Count) { $S.TeamsSbAll.IsChecked = $true }
    })
    Update-HMSetTeamsCombo 0
    if ($st.TeamsCfg.Error) { $f.lblTeams.Text = "Gespeicherte Ziele nicht lesbar: $($st.TeamsCfg.Error)" }
    if (-not $isAdmin) { foreach ($c in @(@($f.cmbTeams, $f.btnTeamsAdd, $f.txtTeamsName, $f.pwdTeams, $f.btnTeamsTest, $f.btnTeamsDel, $st.TeamsSbAll) + @($st.TeamsChk.Values) + @($st.TeamsSbChk.Values))) { $c.IsEnabled = $false }; $f.lblTeams.Text = 'Nur als Administrator einstellbar.' }
    $f.cmbTeams.Add_SelectionChanged({
        $S = $script:SetDlg
        if ($S.TeamsLoading) { return }
        $i = $S.F.cmbTeams.SelectedIndex
        Save-HMSetTeamsCur
        Update-HMSetTeamsCombo $i
    })
    $f.btnTeamsAdd.Add_Click({
        $S = $script:SetDlg
        if ($S.TeamsList.Count -ge $script:HMNotifyMaxTargets) { [void][System.Windows.MessageBox]::Show($S.Win, "Hoechstens $($script:HMNotifyMaxTargets) Ziele.", 'Teams', 'OK', 'Information'); return }
        Save-HMSetTeamsCur
        $nm = "Ziel $($S.TeamsList.Count + 1)"
        [void]$S.TeamsList.Add(@{ Id = [guid]::NewGuid().ToString('N').Substring(0, 8); Name = $nm; Url = ''; Cats = (Get-HMNotifyDefaultCats); SbProfiles = @(); Saved = $false; NewUrl = $false })
        Update-HMSetTeamsCombo ($S.TeamsList.Count - 1)
        $S.F.txtTeamsName.Focus(); $S.F.txtTeamsName.SelectAll()
    })
    $f.btnTeamsTest.Add_Click({
        $S = $script:SetDlg
        if ($S.TeamsCur -lt 0) { [void][System.Windows.MessageBox]::Show($S.Win, "Bitte zuerst mit 'Neues Ziel' ein Ziel anlegen.", 'Teams', 'OK', 'Information'); return }
        Save-HMSetTeamsCur
        $t = $S.TeamsList[$S.TeamsCur]
        Update-HMSetTeamsCombo $S.TeamsCur
        if (-not "$($t.Url)") { [void][System.Windows.MessageBox]::Show($S.Win, 'Bitte zuerst die Webhook-Adresse eintragen.', 'Teams', 'OK', 'Information'); return }
        $r = Send-HMTeamsMessage -Title "HUMig - Testnachricht ($($t.Name))" -Lines @("Die Benachrichtigung von $env:COMPUTERNAME an '$($t.Name)' funktioniert.") -Level 'OK' -Url $t.Url
        if ($r) { [void][System.Windows.MessageBox]::Show($S.Win, "$r`n`nPruefen: Adresse vollstaendig kopiert? Workflow eingeschaltet? Ausgehendes HTTPS am PC erlaubt?", 'Teams', 'OK', 'Warning') }
        else {
            $hint = if (-not (Test-HMTeamsWebhookHostKnown $t.Url)) { "`n`nHinweis: die Adresse stammt nicht erkennbar aus der Workflows-App." } else { '' }
            [void][System.Windows.MessageBox]::Show($S.Win, "Testnachricht an '$($t.Name)' gesendet - sie sollte gleich im Chat/Kanal stehen.$(if (-not $t.Saved -or $t.NewUrl) { ' Mit Speichern wird die Adresse uebernommen.' })$hint", 'Teams', 'OK', 'Information')
        }
    })
    $f.btnTeamsDel.Add_Click({
        $S = $script:SetDlg
        if ($S.TeamsCur -lt 0) { return }
        $t = $S.TeamsList[$S.TeamsCur]
        $q = "Ziel '$($t.Name)' entfernen?$(if ($t.Saved) { "`n`nDie gespeicherte Adresse wird sofort von diesem PC geloescht, die anderen Ziele bleiben.`nDanach in Teams den Workflow loeschen oder ausschalten - sonst bleibt die Adresse gueltig." })"
        if ("$([System.Windows.MessageBox]::Show($S.Win, $q, 'Teams', 'YesNo', 'Question'))" -ne 'Yes') { return }
        if ($t.Saved) {
            try { Remove-HMNotifyTarget "$($t.Id)"; Out-Console "Teams-Benachrichtigung: Ziel '$($t.Name)' entfernt." 'Info' }
            catch { [void][System.Windows.MessageBox]::Show($S.Win, "Entfernen fehlgeschlagen: $($_.Exception.Message)", 'Teams', 'OK', 'Error'); return }
        }
        $S.F.pwdTeams.Password = ''   # eingetippte Adresse gehoert zum entfernten Ziel
        $S.TeamsList.RemoveAt($S.TeamsCur)
        if ($t.Saved) { try { $rr = Update-HMNotifyRelay; if ($rr) { Out-Console $rr 'Info' } } catch { Out-Console "Teams-Meldung Profil-Backups: $($_.Exception.Message)" 'Warning' } }
        # gespeicherten Stand ohne dieses Ziel als Vergleich merken (Entfernen ist schon gespeichert)
        $cfgN = Get-HMNotifyConfig
        $S.TeamsOrig = Get-HMTeamsListKey $cfgN.Targets
        $S.TeamsCur = -1
        Update-HMSetTeamsCombo ([Math]::Min($S.F.cmbTeams.SelectedIndex, $S.TeamsList.Count - 1))
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
    $f.chkROfferApps.IsChecked = ($s.Restore.OfferApps -ne $false)
    $f.chkRVerify.IsChecked = ($s.Restore.VerifyAfter -ne $false)
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
        # beschaedigte modules.json nicht ueberschreiben (eigene Module/Vorlagen gingen verloren)
        $bad = Test-HMJsonBroken $mp
        if ($bad) { [void][System.Windows.MessageBox]::Show($script:SetDlg.Win, "modules.json ist fehlerhaft ($bad).`n`nModul nicht angelegt - Datei bleibt unveraendert (bitte mit 'modules.json (Experten)' reparieren).", 'Eigenes Modul', 'OK', 'Warning'); return }
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
        $bad = Test-HMJsonBroken $mp
        if ($bad) { [void][System.Windows.MessageBox]::Show($script:SetDlg.Win, "modules.json ist fehlerhaft ($bad).`n`nModul nicht geloescht - Datei bleibt unveraendert.", 'Module', 'OK', 'Warning'); return }
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
    $uc = Get-HMUpdateConfig $script:ConfigDir
    $f.txtOwner.Text = $uc.Owner; $f.txtRepo.Text = $uc.Repo; $f.txtBranch.Text = $uc.Branch
    foreach ($t in @('Stabil (empfohlen, freigegebene Versionen)', 'Test (neue Versionen vor der Freigabe)')) { [void]$f.cmbChannel.Items.Add($t) }
    $f.cmbChannel.SelectedIndex = $(if ($uc.Channel -eq 'Test') { 1 } else { 0 })
    $f.chkUseBranch.IsChecked = [bool]$uc.UseBranch
    $f.chkRequireSig.IsChecked = [bool]$uc.RequireSignature
    $f.txtSignerThumb.Text = "$($uc.SignerThumbprint)"
    $st.ReqWas = [bool]$uc.RequireSignature
    $inst = Get-HMInstalledInfo
    $f.lblInstalled.Text = "installiert: v$($script:Version)$(if ($inst -and "$($inst.Check)") { "  ($($inst.Date), $($inst.Check))" })"
    $f.btnVersions.Add_Click({ $script:SetDlg.Win.Close(); Show-HMVersionPicker })
    $updTok = { $script:SetDlg.F.lblToken.Text = if (Test-Path -LiteralPath (Get-GitHubTokenFile)) { 'gespeichert' } elseif ("$env:HUMIG_GITHUB_TOKEN".Trim()) { 'aus Umgebungsvariable' } else { 'keiner' } }
    $st.UpdTok = $updTok
    & $updTok
    $f.btnTokenSet.Add_Click({
        $c = Get-Credential -UserName 'github' -Message 'GitHub-Token (Nur-Lese) als Kennwort eingeben - wird verschluesselt gespeichert'
        if ($c) { $c | Export-Clixml -Path (Get-GitHubTokenFile) -Force; Out-Console 'GitHub-Token gespeichert (DPAPI)' 'Success' }
        & $script:SetDlg.UpdTok
    })
    $f.btnTokenDel.Add_Click({ Remove-Item -LiteralPath (Get-GitHubTokenFile) -Force -ErrorAction SilentlyContinue; & $script:SetDlg.UpdTok })

    # --- Handy-Fernbedienung ---
    try { Initialize-HMRemoteSettingsTab $f } catch { Out-Console "Einstellungen Handy: $($_.Exception.Message)" 'Warning' }

    # --- Buttons ---
    $f.btnOpenConfig.Add_Click({ Start-Process explorer.exe -ArgumentList "`"$($script:ConfigDir)`"" })
    $f.btnCancel.Add_Click({ $script:SetDlg.Win.Close() })
    $f.btnSave.Add_Click({
        $F = $script:SetDlg.F; $W = $script:SetDlg.Win
        $tp0 = ("$($F.txtSignerThumb.Text)" -replace '[^0-9A-Fa-f]', '')
        if ([bool]$F.chkRequireSig.IsChecked -and $tp0.Length -ne 40) { [void][System.Windows.MessageBox]::Show($W, 'Nur signierte Updates: bitte den Fingerabdruck (Thumbprint, 40 Zeichen) des Signatur-Zertifikats eintragen - sonst wird kein Update mehr angenommen.', 'Einstellungen', 'OK', 'Warning'); $F.tabs.SelectedItem = $F.tabUpdate; return }
        if ([bool]$F.chkRequireSig.IsChecked -and [bool]$F.chkUseBranch.IsChecked) { [void][System.Windows.MessageBox]::Show($W, "Ein Branch-Stand ist nicht signiert. 'Branch statt Releases laden' geht nur, wenn 'Nur signierte Updates annehmen' ausgeschaltet ist.", 'Einstellungen', 'OK', 'Warning'); $F.tabs.SelectedItem = $F.tabUpdate; return }
        if ($script:SetDlg.ReqWas -and -not [bool]$F.chkRequireSig.IsChecked) {
            $F.tabs.SelectedItem = $F.tabUpdate
            if ([System.Windows.MessageBox]::Show($W, "Signaturpruefung wirklich ausschalten?`n`nDann werden auch Versionen installiert, die nicht vom Herausgeber signiert sind (z.B. wenn das GitHub-Konto missbraucht wird). Empfohlen: eingeschaltet lassen.", 'Einstellungen', 'YesNo', 'Warning') -ne 'Yes') { return }
        }
        $ret = 0
        if (-not [int]::TryParse("$($F.txtRetention.Text)".Trim(), [ref]$ret) -or $ret -lt 0 -or $ret -gt 3650) { [void][System.Windows.MessageBox]::Show($W, 'Aufbewahrung: Zahl 0 bis 3650', 'Einstellungen', 'OK', 'Warning'); return }
        $keep = 0
        if (-not [int]::TryParse("$($F.txtRetentionKeep.Text)".Trim(), [ref]$keep) -or $keep -lt 0 -or $keep -gt 100) { [void][System.Windows.MessageBox]::Show($W, 'Aufbewahrung: Anzahl 0 bis 100', 'Einstellungen', 'OK', 'Warning'); return }
        $delKeep = 0
        if (-not [int]::TryParse("$($F.txtDeletedKeep.Text)".Trim(), [ref]$delKeep) -or $delKeep -lt 0 -or $delKeep -gt 3650) { [void][System.Windows.MessageBox]::Show($W, 'Geloeschte Dateien aufheben: Tage 0 bis 3650 (0 = nie entfernen)', 'Einstellungen', 'OK', 'Warning'); return }
        $delMass = 0
        if (-not [int]::TryParse("$($F.txtDeletedMass.Text)".Trim(), [ref]$delMass) -or $delMass -lt 0 -or $delMass -gt 100) { [void][System.Windows.MessageBox]::Show($W, 'Warnung bei Massenloeschung: Prozent 0 bis 100 (0 = aus)', 'Einstellungen', 'OK', 'Warning'); return }
        Save-HMSetTeamsCur; Update-HMSetTeamsCombo $script:SetDlg.TeamsCur
        $tWhy = Test-HMNotifyTargets @($script:SetDlg.TeamsList)
        if ($isAdmin -and $tWhy) { [void][System.Windows.MessageBox]::Show($W, "Teams-Benachrichtigung: $tWhy`n`nAdresse eintragen oder das Ziel entfernen.", 'Einstellungen', 'OK', 'Warning'); return }
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
            # Freigabe selbst nicht erreichbar (gibt es nicht - z. B. keine Admin-Freigabe C$/D$ - oder kein Zugriff): klare Meldung statt "ungueltiges Format"
            $shr = Get-HMShareRoot $root
            if ($shr -and -not (Test-Path -LiteralPath $shr)) { [void][System.Windows.MessageBox]::Show($W, "Die Freigabe '$shr' ist nicht erreichbar - es gibt sie nicht (z. B. keine Admin-Freigabe C`$/D`$ an diesem PC) oder es fehlt der Zugriff.`n`nPfad pruefen bzw. die Freigabe einrichten - nichts gespeichert.", 'Einstellungen', 'OK', 'Warning'); return }
            if ("$([System.Windows.MessageBox]::Show($W, "Backup-Ordner '$root' existiert nicht. Anlegen?", 'Einstellungen', 'YesNo', 'Question'))" -ne 'Yes') { return }
            try { New-Item -ItemType Directory -Path $root -Force -ErrorAction Stop | Out-Null } catch { [void][System.Windows.MessageBox]::Show($W, "Anlegen fehlgeschlagen: $($_.Exception.Message)", 'Einstellungen', 'OK', 'Error'); return }
        }
        # settings.json: vorhandene (auch unbekannte) Schluessel behalten
        $p = Join-Path $script:ConfigDir 'settings.json'
        # beschaedigte settings.json: erst sichern, dann neu schreiben (sonst gingen unbekannte Schluessel ohne Sicherung verloren)
        $bad = Test-HMJsonBroken $p
        if ($bad) {
            $bk = "$p.defekt_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
            if ("$([System.Windows.MessageBox]::Show($W, "settings.json ist fehlerhaft ($bad).`n`nAls $(Split-Path $bk -Leaf) sichern und neu schreiben?`n`nNein = Einstellungen nicht speichern.", 'Einstellungen', 'YesNo', 'Warning'))" -ne 'Yes') { return }
            try { Copy-Item -LiteralPath $p -Destination $bk -Force -ErrorAction Stop }
            catch { [void][System.Windows.MessageBox]::Show($W, "Sicherung fehlgeschlagen ($($_.Exception.Message)) - nichts gespeichert.", 'Einstellungen', 'OK', 'Error'); return }
            Out-Console "settings.json war fehlerhaft - gesichert als $bk (wird mit den Werten dieses Fensters neu geschrieben)." 'Warning'
        }
        $cur = if ($bad) { $null } else { Read-JsonFile $p }
        $h = [ordered]@{}
        if ($cur) { foreach ($x in $cur.PSObject.Properties) { if ($x.Name -ne '_Info') { $h[$x.Name] = $x.Value } } }
        $h.BackupRoot = $root
        $h.Threads = if ($F.cmbThreads.SelectedItem) { [int]$F.cmbThreads.SelectedItem } else { 32 }
        $h.RetentionDays = $ret
        $h.RetentionKeepPerUser = $keep
        $h.DeletedKeepDays = $delKeep
        $h.DeletedMassPercent = $delMass
        $h.OverviewAuto = [bool]$F.chkOverviewAuto.IsChecked
        $h.ShowStatusPage = [bool]$F.chkStatusPage.IsChecked
        $h.SplashAnimation = [bool]$F.chkSplashAnim.IsChecked
        $fm = "$($F.txtFeedbackMail.Text)".Trim()
        if ($fm -and $fm -notmatch '^[^@\s;,]+@[^@\s;,]+\.[^@\s;,]+$') { [void][System.Windows.MessageBox]::Show($W, 'Rueckmeldung: ungueltige E-Mail-Adresse', 'Einstellungen', 'OK', 'Warning'); return }
        $h.FeedbackMail = $fm
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
        $rs.OfferApps = [bool]$F.chkROfferApps.IsChecked; $rs.VerifyAfter = [bool]$F.chkRVerify.IsChecked
        $h.Restore = $rs
        # Teams: nur speichern, wenn sich an den Zielen etwas geaendert hat
        if ($isAdmin -and (Get-HMTeamsListKey $script:SetDlg.TeamsList) -ne $script:SetDlg.TeamsOrig) {
            try { Set-HMNotifyTargets -Targets @($script:SetDlg.TeamsList); Out-Console "Teams-Benachrichtigung: $($script:SetDlg.TeamsList.Count) Ziel(e) auf diesem PC gespeichert (verschluesselt)." 'Success' }
            catch { [void][System.Windows.MessageBox]::Show($W, "Teams-Ziele nicht gespeichert: $($_.Exception.Message)", 'Einstellungen', 'OK', 'Error'); return }
        }
        # Weitergabe der geplanten Profil-Backups (Aufgabe unter SYSTEM) einrichten bzw. entfernen
        if ($isAdmin) {
            try { $rr = Update-HMNotifyRelay -Targets @($script:SetDlg.TeamsList); if ($rr) { Out-Console $rr 'Info' } }
            catch { Out-Console "Teams-Meldung Profil-Backups nicht eingerichtet: $($_.Exception.Message)" 'Warning' }
        }
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
        $rem = Get-HMRemoteSettingsFromTab $F $W
        if ($null -eq $rem) { $F.tabs.SelectedItem = $F.tabRemote; return }
        $h.Remote = $rem
        Write-JsonFile $p ([pscustomobject]$h) 8
        # Ausnahmen
        $ex = [ordered]@{
            _Info = 'Ausnahmen fuer Robocopy (vom Einstellungsfenster gepflegt).'
            ProfileFolders = @(ConvertFrom-HMLines $F.txtExPF.Text); ProfileFiles = @(ConvertFrom-HMLines $F.txtExPFi.Text)
            SystemFolders = @(ConvertFrom-HMLines $F.txtExSF.Text); SystemFiles = @(ConvertFrom-HMLines $F.txtExSFi.Text)
            MinimalProfileFolders = @(ConvertFrom-HMLines $F.txtExPMin.Text); MinimalSystemFolders = @(ConvertFrom-HMLines $F.txtExSMin.Text)
        }
        # beschaedigte exceptions.json/update.json nicht ueberschreiben (das Fenster zeigt dann nur Standardwerte)
        $exP = Join-Path $script:ConfigDir 'exceptions.json'
        $bad = Test-HMJsonBroken $exP
        if ($bad) { [void][System.Windows.MessageBox]::Show($W, "exceptions.json ist fehlerhaft ($bad).`n`nAusnahmen nicht gespeichert - Datei bleibt unveraendert. Die uebrigen Einstellungen werden gespeichert.", 'Einstellungen', 'OK', 'Warning') }
        else { Write-JsonFile $exP ([pscustomobject]$ex) }
        # Update-Quelle
        $o = "$($F.txtOwner.Text)".Trim(); $rp = "$($F.txtRepo.Text)".Trim(); $b = "$($F.txtBranch.Text)".Trim()
        $tp = ("$($F.txtSignerThumb.Text)" -replace '[^0-9A-Fa-f]', '').ToUpper()
        if ($tp -and $tp -eq (Get-HMDefaultSigner $o $rp)) { $tp = '' }   # eingebauter Fingerabdruck der offiziellen Quelle: nicht festschreiben
        $upP = Join-Path $script:ConfigDir 'update.json'
        $bad = if ($o -and $rp) { Test-HMJsonBroken $upP } else { '' }
        if ($bad) { [void][System.Windows.MessageBox]::Show($W, "update.json ist fehlerhaft ($bad).`n`nUpdate-Quelle nicht gespeichert - Datei bleibt unveraendert. Die uebrigen Einstellungen werden gespeichert.", 'Einstellungen', 'OK', 'Warning') }
        elseif ($o -and $rp) {
            Write-JsonFile $upP ([pscustomobject][ordered]@{
                Owner = $o; Repo = $rp; Branch = $(if ($b) { $b } else { 'main' }); UseBranch = [bool]$F.chkUseBranch.IsChecked
                Channel = $(if ($F.cmbChannel.SelectedIndex -eq 1) { 'Test' } else { 'Stable' }); AllowUnsigned = (-not [bool]$F.chkRequireSig.IsChecked); SignerThumbprint = $tp
            })
        }
        $script:SetDlg.Saved = $true
        Out-Console 'Einstellungen gespeichert' 'Success'
        $W.Close()
    })

    switch ($Tab) {
        'Ausnahmen' { $f.tabs.SelectedItem = $f.tabExceptions }
        'Module' { $f.tabs.SelectedItem = $f.tabModules }
        'Standorte' { $f.tabs.SelectedItem = $f.tabSchools }
        'Update' { $f.tabs.SelectedItem = $f.tabUpdate }
        'Handy' { $f.tabs.SelectedItem = $f.tabRemote }
    }
    [void]$w.ShowDialog()
    $saved = $st.Saved
    $script:SetDlg = $null
    return $saved
}
