#Requires -Version 5.1
<#
.SYNOPSIS
    Umzugs-Assistent: fuehrt Schritt fuer Schritt durch einen PC-Umzug - alter PC und Benutzer, Vorab-Pruefung, Backup,
    neuer PC und Benutzer, Restore (mit fehlenden Programmen zuerst), Checkliste. Fortsetzbar nach Abbruch oder Neustart.
.DESCRIPTION
    Der Assistent steuert das Hauptfenster (Auswahl Computer/Benutzer, Reiter, Knoepfe) und merkt sich den Stand in
    %APPDATA%\HUMig\umzug.json. Backup und Restore melden ihr Ende ueber Update-HMWizardAfterJob.
.NOTES
    Dot-Source aus HUMig.ps1. Zielmaschine: der PC, auf dem HUMig laeuft.
#>

$script:WizFile = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'HUMig\umzug.json'
$script:Wiz = $null        # Fenster-Zustand
$script:WizState = $null   # gespeicherter Umzug

$script:WizSteps = @(
    @{ T = 'Alter PC und Benutzer'; D = "Oben im Hauptfenster den ALTEN PC waehlen (Lokal, oder Name eintippen + Verbinden) und den Benutzer, der umziehen soll.`n`nDann 'Auswahl uebernehmen'."; A = 'Auswahl uebernehmen' }
    @{ T = 'Vorab-Pruefung'; D = "Prueft Verbindung, Anmeldestatus, OneDrive, USMT, laufende Programme und den freien Platz am Backup-Ziel. Ergebnis steht unten in der Ausgabe.`n`nAm besten ist der Benutzer abgemeldet und Outlook/Browser sind geschlossen."; A = 'Vorab-Pruefung starten' }
    @{ T = 'Backup'; D = "Im Reiter Backup die Vorlage waehlen (fuer einen kompletten Umzug: Komplett) und bei Bedarf 'Programme' (erkannte Programme als Module).`n`n'Backup starten' sichert den Benutzer des alten PCs. Nach erfolgreichem Backup geht es automatisch weiter."; A = 'Backup starten' }
    @{ T = 'Neuer PC und Benutzer'; D = "Oben im Hauptfenster den NEUEN PC waehlen und den Zielbenutzer. Hat er dort noch kein Profil: Konto als DOMAENE\Benutzer eintragen (dann im Restore das Modul Windows-Einstellungen (USMT) mitwaehlen).`n`nDann 'Auswahl uebernehmen'."; A = 'Auswahl uebernehmen' }
    @{ T = 'Restore'; D = "Waehlt das Backup aus Schritt 3 im Reiter Restore aus. 'Restore starten' bietet zuerst an, fehlende Programme zu installieren, und spielt danach die Einstellungen zurueck. Nach dem Restore geht es automatisch weiter."; A = 'Restore starten' }
    @{ T = 'Checkliste und Abschluss'; D = "Checkliste abhaken (Anmeldung, Outlook, Drucker, OneDrive ...). Programm-Einstellungen, die ausgelassen wurden, weil das Programm noch fehlte: Programm installieren und Restore wiederholen (nur diese Module sind dann angehakt).`n`nZum Schluss 'Umzug abschliessen'."; A = 'Checkliste oeffnen' }
)

function Read-HMWizState {
    try { if (Test-Path -LiteralPath $script:WizFile) { $j = Get-Content -LiteralPath $script:WizFile -Raw -Encoding UTF8 | ConvertFrom-Json; if ($j -and -not $j.Finished) { return $j } } } catch { }
    return $null
}
function Save-HMWizState {
    if (-not $script:WizState) { return }
    try {
        $d = Split-Path $script:WizFile -Parent
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        ConvertTo-Json -InputObject $script:WizState -Depth 5 | Set-Content -LiteralPath $script:WizFile -Encoding UTF8
    } catch { Out-Console "Umzugs-Assistent: Stand nicht gespeichert ($($_.Exception.Message))" 'Warning' }
}
function New-HMWizState {
    return [pscustomobject][ordered]@{ Started = (Get-Date).ToString('yyyy-MM-dd HH:mm'); Step = 1; Done = @(); Source = $null; Target = $null
        BackupPath = ''; BackupStatus = ''; RestoreReport = ''; RestoreStatus = ''; Finished = '' }
}
function Set-HMWizDone([int]$Step) {
    $s = $script:WizState
    if (@($s.Done) -notcontains $Step) { $s.Done = @(@($s.Done) + $Step | Sort-Object -Unique) }
}
# aktuelle Auswahl im Hauptfenster
function Get-HMWizSelection {
    $p = Get-SelectedProfile
    if (-not $p) { return $null }
    $c = Get-TargetComputer; if (Test-HMIsLocal $c) { $c = $env:COMPUTERNAME }
    return [pscustomobject]@{ Computer = "$c".ToUpper(); Account = "$($p.Account)"; Folder = "$($p.Folder)"; SID = "$($p.SID)"; NoProfile = [bool]$p.NoProfile }
}
function Format-HMWizSel($x) { if (-not $x) { return '(noch nicht gewaehlt)' }; return "$($x.Computer) \ $($x.Folder)$(if ($x.Account -and $x.Account -ne $x.Folder) { "  ($($x.Account))" })$(if ($x.NoProfile) { '  - noch kein Profil' })" }
function Select-HMMainTab([string]$Header) { $t = @($ui.tabMain.Items | Where-Object { $_ -is [System.Windows.Controls.TabItem] -and "$($_.Header)" -like "$Header*" })[0]; if ($t) { $ui.tabMain.SelectedItem = $t } }
function Invoke-HMMainButton($Btn) { $Btn.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Button]::ClickEvent))) }

function Show-HMWizard {
    if ($script:Wiz -and $script:Wiz.Win.IsVisible) { $script:Wiz.Win.Activate() | Out-Null; return }
    $x = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="HUMig - Umzugs-Assistent" Width="820" Height="500" WindowStartupLocation="CenterOwner" Background="#FF1E1E2E" ResizeMode="CanResizeWithGrip">
  <DockPanel Margin="12">
    <DockPanel DockPanel.Dock="Bottom" Margin="0,10,0,0">
      <Button x:Name="bClose" DockPanel.Dock="Right" Content="Schliessen (Stand bleibt)" Padding="12,4" Background="#FF45475A" Foreground="#FFCDD6F4"/>
      <Button x:Name="bNew" Content="Neu beginnen" Padding="12,4" Background="#FF45475A" Foreground="#FFCDD6F4" HorizontalAlignment="Left"/>
    </DockPanel>
    <Border DockPanel.Dock="Left" Width="230" Background="#FF181825" CornerRadius="4" Padding="10" Margin="0,0,12,0">
      <StackPanel>
        <TextBlock Text="UMZUG" Foreground="#FFA6ADC8" FontWeight="SemiBold" FontSize="11" Margin="0,0,0,8"/>
        <StackPanel x:Name="pSteps"/>
        <TextBlock x:Name="tStarted" Foreground="#FF6C7086" FontSize="11" TextWrapping="Wrap" Margin="0,12,0,0"/>
      </StackPanel>
    </Border>
    <DockPanel>
      <TextBlock x:Name="tTitle" DockPanel.Dock="Top" Foreground="#FFCDD6F4" FontSize="18" FontWeight="SemiBold" Margin="0,0,0,8"/>
      <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" Margin="0,10,0,0">
        <Button x:Name="bBack" Content="Zurueck" Padding="12,5" Margin="0,0,6,0" Background="#FF45475A" Foreground="#FFCDD6F4"/>
        <Button x:Name="bAct" Padding="14,5" Margin="0,0,6,0" Background="#FF89B4FA" Foreground="#FF1E1E2E" FontWeight="SemiBold"/>
        <Button x:Name="bNext" Content="Weiter" Padding="14,5" Margin="0,0,6,0" Background="#FFA6E3A1" Foreground="#FF1E1E2E" FontWeight="SemiBold"/>
        <Button x:Name="bFinish" Content="Umzug abschliessen" Padding="14,5" Background="#FFA6E3A1" Foreground="#FF1E1E2E" FontWeight="SemiBold" Visibility="Collapsed"/>
      </StackPanel>
      <Border DockPanel.Dock="Bottom" Background="#FF181825" CornerRadius="4" Padding="10,6" Margin="0,10,0,0">
        <TextBlock x:Name="tInfo" Foreground="#FFA6ADC8" TextWrapping="Wrap"/>
      </Border>
      <TextBlock x:Name="tDesc" Foreground="#FFCDD6F4" TextWrapping="Wrap" FontSize="13"/>
    </DockPanel>
  </DockPanel>
</Window>
"@
    $w = [System.Windows.Markup.XamlReader]::Parse($x)
    if ($script:AppIcon) { $w.Icon = $script:AppIcon }
    $w.Owner = $script:Window
    try { Set-HMWindowScale $w } catch { }
    $f = @{}; foreach ($n in @('pSteps', 'tStarted', 'tTitle', 'tDesc', 'tInfo', 'bBack', 'bAct', 'bNext', 'bFinish', 'bNew', 'bClose')) { $f[$n] = $w.FindName($n) }
    $script:Wiz = @{ Win = $w; F = $f }
    $script:WizState = Read-HMWizState
    if ($script:WizState) { Out-Console "Umzugs-Assistent: begonnener Umzug vom $($script:WizState.Started) wird fortgesetzt (Schritt $($script:WizState.Step))." 'Info' }
    else { $script:WizState = New-HMWizState; Save-HMWizState }
    $f.bClose.Add_Click({ $script:Wiz.Win.Close() })
    $f.bNew.Add_Click({
        if ("$((Show-HMDialogBox -Owner $script:Wiz.Win -Text 'Begonnenen Umzug verwerfen und neu beginnen? (Backups bleiben erhalten)' -Title 'Umzugs-Assistent' -Mode 'YesNo' -Icon 'Question'))" -ne 'Yes') { return }
        $script:WizState = New-HMWizState; Save-HMWizState; Update-HMWizard
    })
    $f.bBack.Add_Click({ if ($script:WizState.Step -gt 1) { $script:WizState.Step--; Save-HMWizState; Update-HMWizard } })
    $f.bNext.Add_Click({ if ($script:WizState.Step -lt $script:WizSteps.Count) { Set-HMWizDone $script:WizState.Step; $script:WizState.Step++; Save-HMWizState; Update-HMWizard } })
    $f.bAct.Add_Click({ Invoke-HMWizardAction })
    $f.bFinish.Add_Click({
        $script:WizState.Finished = (Get-Date).ToString('yyyy-MM-dd HH:mm'); Set-HMWizDone 6; Save-HMWizState
        Out-Console "Umzug abgeschlossen: $(Format-HMWizSel $script:WizState.Source) -> $(Format-HMWizSel $script:WizState.Target)" 'Success'
        $script:Wiz.Win.Close()
    })
    $w.Add_Closed({ $script:Wiz = $null })
    Update-HMWizard
    $w.Show()
}

function Update-HMWizard {
    if (-not $script:Wiz) { return }
    $f = $script:Wiz.F; $s = $script:WizState
    $f.pSteps.Children.Clear()
    for ($i = 1; $i -le $script:WizSteps.Count; $i++) {
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Margin = [System.Windows.Thickness]::new(0, 3, 0, 3); $tb.TextWrapping = 'Wrap'
        $done = @($s.Done) -contains $i
        $dot = New-Object System.Windows.Documents.Run ("$(if ($done) { [char]0x2714 } elseif ($i -eq $s.Step) { [char]0x25B6 } else { [char]0x25CB })  ")
        $dot.Foreground = New-Brush $(if ($done) { '#FFA6E3A1' } elseif ($i -eq $s.Step) { '#FF89B4FA' } else { '#FF6C7086' })
        $r = New-Object System.Windows.Documents.Run ("$i. $($script:WizSteps[$i - 1].T)")
        $r.Foreground = New-Brush $(if ($i -eq $s.Step) { '#FFCDD6F4' } else { '#FFA6ADC8' })
        if ($i -eq $s.Step) { $r.FontWeight = [System.Windows.FontWeights]::SemiBold }
        [void]$tb.Inlines.Add($dot); [void]$tb.Inlines.Add($r)
        [void]$f.pSteps.Children.Add($tb)
    }
    $f.tStarted.Text = "begonnen $($s.Started)`nStand: $script:WizFile"
    $st = $script:WizSteps[$s.Step - 1]
    $f.tTitle.Text = "Schritt $($s.Step): $($st.T)"
    $f.tDesc.Text = $st.D
    $f.bAct.Content = $st.A
    $f.bBack.IsEnabled = ($s.Step -gt 1)
    $last = ($s.Step -eq $script:WizSteps.Count)
    $f.bNext.Visibility = $(if ($last) { 'Collapsed' } else { 'Visible' })
    $f.bFinish.Visibility = $(if ($last) { 'Visible' } else { 'Collapsed' })
    $sel = $null; try { $sel = Get-HMWizSelection } catch { }
    $info = switch ($s.Step) {
        1 { "Alter PC: $(Format-HMWizSel $s.Source)`nAuswahl im Hauptfenster: $(Format-HMWizSel $sel)" }
        2 { "Alter PC: $(Format-HMWizSel $s.Source)" }
        3 { "Alter PC: $(Format-HMWizSel $s.Source)$(if ($s.BackupPath) { "`nBackup: $($s.BackupPath) ($($s.BackupStatus))" } else { "`nNoch kein Backup in diesem Umzug." })" }
        4 { "Neuer PC: $(Format-HMWizSel $s.Target)`nAuswahl im Hauptfenster: $(Format-HMWizSel $sel)$(if ($s.Source -and $sel -and $sel.Computer -eq $s.Source.Computer) { "`nHinweis: das ist noch der alte PC." })" }
        5 { "Backup: $(if ($s.BackupPath) { $s.BackupPath } else { '(keins - Schritt 3)' })`nNeuer PC: $(Format-HMWizSel $s.Target)$(if ($s.RestoreReport) { "`nRestore: $($s.RestoreStatus) - $($s.RestoreReport)" })" }
        6 { "$(Format-HMWizSel $s.Source)  ->  $(Format-HMWizSel $s.Target)$(if ($s.RestoreReport) { "`nProtokoll: $($s.RestoreReport)" })" }
    }
    $f.tInfo.Text = $info
    # Weiter nur, wenn die Voraussetzung des Schritts erfuellt ist (Schritt 2 und 6 frei)
    $f.bNext.IsEnabled = switch ($s.Step) { 1 { [bool]$s.Source } 3 { [bool]$s.BackupPath } 4 { [bool]$s.Target } 5 { [bool]$s.RestoreReport } default { $true } }
}

function Test-HMWizSelection($Expect, [string]$What) {
    $sel = Get-HMWizSelection
    if (-not $Expect -or -not $sel) { return $true }
    if ($sel.Computer -eq $Expect.Computer -and ($sel.Folder -eq $Expect.Folder -or $sel.Account -eq $Expect.Account)) { return $true }
    $m = "Im Hauptfenster ist gerade $(Format-HMWizSel $sel) gewaehlt, fuer diesen Schritt gehoert aber der $What dazu: $(Format-HMWizSel $Expect).`n`nTrotzdem fortfahren?"
    return ("$((Show-HMDialogBox -Owner $script:Wiz.Win -Text $m -Title 'Umzugs-Assistent' -Mode 'YesNo' -Icon 'Warning' -Default 'No'))" -eq 'Yes')
}

function Invoke-HMWizardAction {
    $s = $script:WizState
    if ($script:JobRunning) { [void](Show-HMDialogBox -Owner $script:Wiz.Win -Text 'Es laeuft gerade ein Vorgang - bitte warten, bis er fertig ist.' -Title 'Umzugs-Assistent' -Mode 'OK' -Icon 'Information'); return }
    switch ($s.Step) {
        1 {
            $sel = Get-HMWizSelection
            if (-not $sel -or $sel.NoProfile) { [void](Show-HMDialogBox -Owner $script:Wiz.Win -Text 'Bitte im Hauptfenster einen PC verbinden und einen Benutzer MIT Profil waehlen.' -Title 'Umzugs-Assistent' -Mode 'OK' -Icon 'Information'); return }
            $s.Source = $sel; Set-HMWizDone 1; $s.Step = 2
            Out-Console "Umzugs-Assistent: alter PC $(Format-HMWizSel $sel)" 'Info'
        }
        2 {
            if (-not (Test-HMWizSelection $s.Source 'alte PC')) { return }
            Select-HMMainTab 'Backup'; Invoke-HMMainButton $ui.btnPrecheck; Set-HMWizDone 2
        }
        3 {
            if (-not (Test-HMWizSelection $s.Source 'alte PC')) { return }
            Select-HMMainTab 'Backup'; $script:WizWaitFor = 'Backup'; Invoke-HMMainButton $ui.btnBackup
        }
        4 {
            $sel = Get-HMWizSelection
            if (-not $sel) { [void](Show-HMDialogBox -Owner $script:Wiz.Win -Text 'Bitte im Hauptfenster den neuen PC verbinden und den Zielbenutzer waehlen (oder DOMAENE\Benutzer eintragen).' -Title 'Umzugs-Assistent' -Mode 'OK' -Icon 'Information'); return }
            if ($s.Source -and $sel.Computer -eq $s.Source.Computer -and "$((Show-HMDialogBox -Owner $script:Wiz.Win -Text ("Der gewaehlte PC ist derselbe wie der alte ($($sel.Computer)). Richtig (z.B. nach Neuinstallation)?") -Title 'Umzugs-Assistent' -Mode 'YesNo' -Icon 'Question'))" -ne 'Yes') { return }
            $s.Target = $sel; Set-HMWizDone 4; $s.Step = 5
            Out-Console "Umzugs-Assistent: neuer PC $(Format-HMWizSel $sel)" 'Info'
        }
        5 {
            if (-not $s.BackupPath -or -not (Test-Path -LiteralPath "$($s.BackupPath)")) { [void](Show-HMDialogBox -Owner $script:Wiz.Win -Text ("Das Backup aus Schritt 3 ist nicht erreichbar:`n$($s.BackupPath)`n`nBackup-Ordner (USB/Freigabe) verbinden oder Schritt 3 wiederholen.") -Title 'Umzugs-Assistent' -Mode 'OK' -Icon 'Warning'); return }
            if (-not (Test-HMWizSelection $s.Target 'neue PC')) { return }
            Select-HMMainTab 'Restore'
            # Backup in der Liste markieren (Backup-Ordner ggf. vorher neu einlesen)
            $row = @(@($ui.dgBackups.ItemsSource) | Where-Object { $_ -and $_.Info -and "$($_.Info.Path)".TrimEnd('\') -ieq "$($s.BackupPath)".TrimEnd('\') })[0]
            if (-not $row) { try { Update-BackupList } catch { }; $row = @(@($ui.dgBackups.ItemsSource) | Where-Object { $_ -and $_.Info -and "$($_.Info.Path)".TrimEnd('\') -ieq "$($s.BackupPath)".TrimEnd('\') })[0] }
            if (-not $row) { [void](Show-HMDialogBox -Owner $script:Wiz.Win -Text ("Das Backup steht nicht in der Liste des Backup-Ordners ($(Get-BackupRoot)).`nOben den Backup-Ordner waehlen, in dem $(Split-Path "$($s.BackupPath)" -Leaf) liegt.") -Title 'Umzugs-Assistent' -Mode 'OK' -Icon 'Warning'); return }
            $ui.dgBackups.SelectedItem = $row; $ui.dgBackups.ScrollIntoView($row)
            $script:WizWaitFor = 'Restore'
            $script:Window.Dispatcher.BeginInvoke([action]{ Invoke-HMMainButton $ui.btnRestore }, [System.Windows.Threading.DispatcherPriority]::Background) | Out-Null
        }
        6 {
            if ($s.RestoreReport -and (Test-Path -LiteralPath "$($s.RestoreReport)")) { Show-HMChecklist -ReportPath "$($s.RestoreReport)" } else { Show-HMChecklist }
        }
    }
    Save-HMWizState; Update-HMWizard
}

# Ende von Backup/Restore (aus Start-BackupJob / Start-RestoreJob): Ergebnis uebernehmen, naechster Schritt
function Update-HMWizardAfterJob([string]$Kind, $Job, [string]$Path = '') {
    if (-not $script:WizState -or "$script:WizWaitFor" -ne $Kind) { return }
    $script:WizWaitFor = ''
    $s = $script:WizState
    $st = if ($Job.Cancel) { 'Cancelled' } elseif ($Job.Result -and $Job.Result.Status) { "$($Job.Result.Status)" } else { 'Error' }
    $ok = $st -in @('OK', 'Warning')
    if ($Kind -eq 'Backup') {
        if ($Path) { $s.BackupPath = $Path }
        $s.BackupStatus = $st
        if ($ok) { Set-HMWizDone 3; $s.Step = 4; Out-Console 'Umzugs-Assistent: Backup fertig - weiter mit Schritt 4 (neuer PC).' 'Success' }
        else { Out-Console "Umzugs-Assistent: Backup $st - Protokoll pruefen und Schritt 3 wiederholen." 'Warning' }
    } elseif ($Kind -eq 'Restore') {
        $s.RestoreStatus = $st
        if ($Job.Result -and $Job.Result.Report) { $s.RestoreReport = "$($Job.Result.Report)" }
        if ($ok -or ($st -eq 'Error' -and $s.RestoreReport)) { Set-HMWizDone 5; $s.Step = 6; Out-Console "Umzugs-Assistent: Restore $st - weiter mit Schritt 6 (Checkliste)." $(if ($ok) { 'Success' } else { 'Warning' }) }
    }
    Save-HMWizState
    if ($script:Wiz) { Update-HMWizard; try { $script:Wiz.Win.Activate() | Out-Null } catch { } }
}
