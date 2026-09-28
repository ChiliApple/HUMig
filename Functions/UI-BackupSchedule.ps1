#Requires -Version 5.1
<#
.SYNOPSIS
    Zeitplan fuer das normale Backup (eigenes Profil): taeglich, woechentlich oder bei Anmeldung automatisch sichern.
.DESCRIPTION
    Speichert die aktuelle Auswahl (Module, Optionen, Zusaetzliche Ordner, Ausschluesse, Backup-Ordner) als
    %LOCALAPPDATA%\HUMig\Zeitplaene\<Id>.json und legt eine geplante Aufgabe im Konto des Benutzers an
    (ohne Kennwort, laeuft nur bei Anmeldung). Die Aufgabe startet Functions\Backup-Task.ps1 - HUMig muss nicht offen sein.
    Backup-Ziel: USB-Laufwerk ueber seine Bezeichnung (Laufwerksbuchstabe darf wechseln), Netzlaufwerk als UNC-Pfad.
.NOTES
    Wird im UI-Thread geladen (dot-source aus HUMig.ps1).
    Zielmaschine: der PC, an dem HUMig laeuft (nur eigenes Profil, lokal).
#>

$script:BsDir = Join-Path $env:LOCALAPPDATA 'HUMig\Zeitplaene'
$script:BsTaskPrefix = 'HUMig Backup - '

function Test-HMBsElevated {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Alle Zeitplaene dieses Benutzers (Dateien in %LOCALAPPDATA%)
function Get-HMBsDefinitions {
    $list = @()
    if (-not (Test-Path -LiteralPath $script:BsDir)) { return ,$list }
    foreach ($f in @(Get-ChildItem -LiteralPath $script:BsDir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        try {
            $d = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($d -and $d.Id) { $list += $d }
        } catch { }
    }
    return ,$list
}

# Backup-Ordner in ein Ziel umwandeln, das auch mit wechselndem Laufwerksbuchstaben gefunden wird
function ConvertTo-HMBsTarget([string]$Root) {
    $r = "$Root".Trim().TrimEnd('\')
    if ($r -match '^\\\\[^\\]+\\[^\\]+') { return @{ Type = 'Unc'; Path = $r; Display = $r } }
    if ($r -notmatch '^([A-Za-z]):(\\.*)?$') { return "Backup-Ordner '$Root' ist kein vollstaendiger Pfad" }
    $let = $Matches[1].ToUpper()
    $rel = "$($Matches[2])".Trim('\')
    $di = $null
    try { $di = New-Object System.IO.DriveInfo ($let) } catch { }
    if (-not $di -or -not $di.IsReady) { return "Laufwerk ${let}: ist nicht bereit" }
    if ("$($di.DriveType)" -eq 'Network') {
        $unc = $null
        try { $unc = (Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='${let}:'" -ErrorAction Stop).ProviderName } catch { }
        if (-not $unc) { try { $unc = (Get-ItemProperty -LiteralPath "HKCU:\Network\$let" -ErrorAction Stop).RemotePath } catch { } }
        if (-not $unc) { return "Netzlaufwerk ${let}: - Freigabepfad nicht ermittelbar. Backup-Ordner bitte als \\Server\Freigabe\... waehlen." }
        $p = if ($rel) { Join-Path $unc.TrimEnd('\') $rel } else { $unc.TrimEnd('\') }
        return @{ Type = 'Unc'; Path = $p; Display = "$p  (Netzlaufwerk ${let}:)" }
    }
    $lbl = "$($di.VolumeLabel)"
    $disp = if ($lbl) { "Laufwerk '$lbl' (jetzt ${let}:)$(if ($rel) { " \$rel" })" } else { "${let}:\$rel  (Laufwerk ohne Bezeichnung - wird nur unter ${let}: gefunden)" }
    return @{ Type = 'Drive'; Letter = $let; Label = $lbl; Rel = $rel; DriveType = "$($di.DriveType)"; Display = $disp }
}

function Format-HMBsWhen($d) {
    $dayNames = @{ Monday = 'Mo'; Tuesday = 'Di'; Wednesday = 'Mi'; Thursday = 'Do'; Friday = 'Fr'; Saturday = 'Sa'; Sunday = 'So' }
    switch ("$($d.Trigger.Mode)") {
        'Daily'  { return "taeglich $($d.Trigger.Time)" }
        'Weekly' { return "$((@($d.Trigger.Days) | ForEach-Object { $dayNames["$_"] }) -join ',') $($d.Trigger.Time)" }
        'Logon'  { return "bei Anmeldung (+$($d.Trigger.Delay) Min.)" }
        default  { return '' }
    }
}

# ----------------------------------------------------------------------------
# Dialog
# ----------------------------------------------------------------------------
function Show-HMBsDialog([string]$Info, [string]$DefaultName) {
    $x = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Backup planen" Width="600" SizeToContent="Height" ResizeMode="NoResize" WindowStartupLocation="CenterOwner" Background="#FF1E1E2E">
  <StackPanel Margin="14">
    <TextBlock x:Name="info" Foreground="#FFCDD6F4" TextWrapping="Wrap" Margin="0,0,0,10"/>
    <StackPanel Orientation="Horizontal" Margin="0,0,0,10">
      <TextBlock Text="Name:" Foreground="#FFA6ADC8" VerticalAlignment="Center" Width="60"/>
      <TextBox x:Name="txtName" Width="300" Background="#FF313244" Foreground="#FFCDD6F4" BorderBrush="#FF585B70" CaretBrush="#FFCDD6F4" Padding="4,2"/>
    </StackPanel>
    <TextBlock Text="ART" Foreground="#FF89B4FA" FontWeight="SemiBold" Margin="0,0,0,2"/>
    <RadioButton x:Name="rbUpdate" GroupName="kind" IsChecked="True" Foreground="#FFCDD6F4" Margin="0,2" Content="Fortlaufend: vorhandenes Backup aktualisieren (nur neue/geaenderte Dateien - schnell, ein Stand)"/>
    <RadioButton x:Name="rbNew" GroupName="kind" Foreground="#FFCDD6F4" Margin="0,2,0,8" Content="Neues Backup: eigener Stand (kopiert alles - dauert laenger, braucht mehr Platz)"/>
    <TextBlock Text="WANN" Foreground="#FF89B4FA" FontWeight="SemiBold" Margin="0,0,0,2"/>
    <RadioButton x:Name="rbDaily" GroupName="when" IsChecked="True" Content="Taeglich" Foreground="#FFCDD6F4" Margin="0,2"/>
    <RadioButton x:Name="rbWeekly" GroupName="when" Content="Woechentlich an" Foreground="#FFCDD6F4" Margin="0,2"/>
    <WrapPanel x:Name="pnlDays" Margin="22,2,0,4"/>
    <StackPanel Orientation="Horizontal" Margin="22,2,0,6">
      <TextBlock Text="Uhrzeit (HH:MM):" Foreground="#FFA6ADC8" VerticalAlignment="Center" Margin="0,0,8,0"/>
      <TextBox x:Name="txtTime" Width="70" Text="12:30" Background="#FF313244" Foreground="#FFCDD6F4" BorderBrush="#FF585B70" CaretBrush="#FFCDD6F4" Padding="4,2"/>
    </StackPanel>
    <StackPanel Orientation="Horizontal" Margin="0,2,0,8">
      <RadioButton x:Name="rbLogon" GroupName="when" Content="Bei Anmeldung, nach" Foreground="#FFCDD6F4" VerticalAlignment="Center"/>
      <TextBox x:Name="txtDelay" Width="40" Text="10" Margin="6,0,6,0" Background="#FF313244" Foreground="#FFCDD6F4" BorderBrush="#FF585B70" CaretBrush="#FFCDD6F4" Padding="4,2"/>
      <TextBlock Text="Minuten" Foreground="#FFCDD6F4" VerticalAlignment="Center"/>
    </StackPanel>
    <TextBlock Text="AUFBEWAHRUNG / MELDUNG" Foreground="#FF89B4FA" FontWeight="SemiBold" Margin="0,0,0,2"/>
    <StackPanel Orientation="Horizontal" Margin="0,2">
      <CheckBox x:Name="chkRet" Content="Alte Backups automatisch loeschen, neueste" Foreground="#FFCDD6F4" VerticalAlignment="Center"/>
      <TextBox x:Name="txtKeep" Width="40" Text="3" Margin="6,0,6,0" Background="#FF313244" Foreground="#FFCDD6F4" BorderBrush="#FF585B70" CaretBrush="#FFCDD6F4" Padding="4,2"/>
      <TextBlock Text="behalten" Foreground="#FFCDD6F4" VerticalAlignment="Center"/>
    </StackPanel>
    <TextBlock Foreground="#FF6C7086" TextWrapping="Wrap" Margin="22,0,0,4" FontSize="11" Text="Gilt fuer alle Backups dieses Benutzers von diesem PC im Backup-Ordner (auch von Hand erstellte). Geloescht wird nur nach einem erfolgreichen Lauf und endgueltig."/>
    <CheckBox x:Name="chkNotify" IsChecked="True" Content="Nach jedem Lauf Meldung anzeigen (aus = nur bei Warnung/Fehler/uebersprungen)" Foreground="#FFCDD6F4" Margin="0,2,0,10"/>
    <TextBlock x:Name="note" Foreground="#FF6C7086" TextWrapping="Wrap" Margin="0,0,0,12" FontSize="11"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
      <Button x:Name="ok" Content="Planen" Width="110" Height="28" Background="#FFA6E3A1" Foreground="#FF1E1E2E" FontWeight="SemiBold" Margin="0,0,6,0" IsDefault="True"/>
      <Button x:Name="cancel" Content="Abbrechen" Width="100" Height="28" Background="#FF45475A" Foreground="#FFCDD6F4" IsCancel="True"/>
    </StackPanel>
  </StackPanel>
</Window>
"@
    $w = [System.Windows.Markup.XamlReader]::Parse($x)
    if ($script:AppIcon) { $w.Icon = $script:AppIcon }
    $w.FindName('info').Text = $Info
    $w.FindName('note').Text = "Die Aufgabe laeuft im Konto $([Security.Principal.WindowsIdentity]::GetCurrent().Name) ohne Kennwort, nur solange dieser Benutzer angemeldet ist - HUMig muss nicht geoeffnet sein. Verpasste Laeufe (PC aus) werden nachgeholt. Fehlt das Ziel (USB nicht angesteckt, Netz nicht erreichbar), wird der Lauf uebersprungen und gemeldet. Geoeffnete Programme (Outlook, Browser) sperren ihre Dateien - diese koennen im Backup fehlen."
    $txtName = $w.FindName('txtName'); $txtName.Text = $DefaultName
    $txtTime = $w.FindName('txtTime'); $txtDelay = $w.FindName('txtDelay'); $txtKeep = $w.FindName('txtKeep')
    $rbUpdate = $w.FindName('rbUpdate'); $rbDaily = $w.FindName('rbDaily'); $rbWeekly = $w.FindName('rbWeekly'); $rbLogon = $w.FindName('rbLogon')
    $chkRet = $w.FindName('chkRet'); $chkNotify = $w.FindName('chkNotify')
    $days = @(@('Monday', 'Mo'), @('Tuesday', 'Di'), @('Wednesday', 'Mi'), @('Thursday', 'Do'), @('Friday', 'Fr'), @('Saturday', 'Sa'), @('Sunday', 'So'))
    $pnl = $w.FindName('pnlDays')
    foreach ($d in $days) { $cb = New-Object System.Windows.Controls.CheckBox; $cb.Content = $d[1]; $cb.Tag = $d[0]; $cb.Foreground = New-Brush '#FFCDD6F4'; $cb.Margin = [System.Windows.Thickness]::new(0, 0, 10, 0); [void]$pnl.Children.Add($cb) }
    $res = @{ V = $null }
    $w.FindName('ok').Add_Click({
        $name = "$($txtName.Text)".Trim()
        if (-not $name -or $name -match '[\\/:*?"<>|]') { [void][System.Windows.MessageBox]::Show($w, 'Bitte einen Namen ohne \ / : * ? " < > | eingeben.', 'Zeitplan', 'OK', 'Warning'); return }
        $mode = if ($rbLogon.IsChecked) { 'Logon' } elseif ($rbWeekly.IsChecked) { 'Weekly' } else { 'Daily' }
        $t = [datetime]::MinValue; $delay = 0; $sel = @()
        if ($mode -ne 'Logon') {
            if (-not [datetime]::TryParseExact("$($txtTime.Text)".Trim(), 'H:mm', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$t)) {
                [void][System.Windows.MessageBox]::Show($w, 'Uhrzeit bitte als HH:MM eingeben (z.B. 12:30).', 'Zeitplan', 'OK', 'Warning'); return
            }
        } elseif (-not [int]::TryParse("$($txtDelay.Text)".Trim(), [ref]$delay) -or $delay -lt 0 -or $delay -gt 240) {
            [void][System.Windows.MessageBox]::Show($w, 'Verzoegerung bitte als Minuten 0-240 eingeben.', 'Zeitplan', 'OK', 'Warning'); return
        }
        if ($mode -eq 'Weekly') {
            $sel = @($pnl.Children | Where-Object { $_.IsChecked } | ForEach-Object { "$($_.Tag)" })
            if (-not $sel.Count) { [void][System.Windows.MessageBox]::Show($w, 'Mindestens einen Wochentag waehlen.', 'Zeitplan', 'OK', 'Warning'); return }
        }
        $keep = 0
        if ($chkRet.IsChecked -and (-not [int]::TryParse("$($txtKeep.Text)".Trim(), [ref]$keep) -or $keep -lt 1 -or $keep -gt 999)) {
            [void][System.Windows.MessageBox]::Show($w, 'Anzahl der Backups, die bleiben sollen: 1-999.', 'Zeitplan', 'OK', 'Warning'); return
        }
        $res.V = @{ Name = $name; Kind = $(if ($rbUpdate.IsChecked) { 'Update' } else { 'New' }); Mode = $mode; Time = $(if ($mode -ne 'Logon') { $t.ToString('HH:mm') } else { '' })
            Days = $sel; Delay = $delay; RetEnabled = [bool]$chkRet.IsChecked; Keep = $(if ($chkRet.IsChecked) { $keep } else { 3 }); NotifyAlways = [bool]$chkNotify.IsChecked }
        $w.DialogResult = $true
    }.GetNewClosure())
    $w.Owner = $script:Window; Set-HMWindowScale $w
    if ($w.ShowDialog() -eq $true) { return $res.V }
    return $null
}

# ----------------------------------------------------------------------------
# Neuer Zeitplan aus der aktuellen Auswahl im Reiter Backup
# ----------------------------------------------------------------------------
function New-HMBackupSchedule {
    $me = [Security.Principal.WindowsIdentity]::GetCurrent()
    $comp = Get-TargetComputer
    $p = Get-SelectedProfile
    if (-not (Test-HMIsLocal $comp)) { Out-Console "Zeitplan: nur fuer diesen PC moeglich (gewaehlt ist $comp). Fuer andere PCs HUMig dort starten." 'Warning'; return }
    if (-not $p -or $p.NoProfile -or "$($p.SID)" -ne $me.User.Value) {
        Out-Console "Zeitplan: nur fuer das eigene Profil moeglich - HUMig laeuft als $($me.Name). Fuer einen anderen Benutzer HUMig in dessen Anmeldung starten (Benutzer-Modus)." 'Warning'; return
    }
    $mods = @(Get-BackupModules)
    if (-not $mods.Count) { Out-Console 'Zeitplan: keine Module gewaehlt.' 'Warning'; return }
    $elev = Test-HMBsElevated
    if (-not $elev) {
        $bad = @($mods | Where-Object { -not (Test-HMModuleUserOk $_) })
        if ($bad.Count) { Out-Console "Zeitplan ohne Administratorrechte: $(@($bad | ForEach-Object { $_.Name }) -join ', ') werden nicht gesichert (nur eigenes Profil)." 'Warning' }
        $mods = @($mods | Where-Object { Test-HMModuleUserOk $_ })
        if (-not $mods.Count) { Out-Console 'Zeitplan: keine Module, die ohne Administratorrechte sicherbar sind.' 'Warning'; return }
    }
    $tg = ConvertTo-HMBsTarget (Get-BackupRoot)
    if ($tg -is [string]) { Out-Console "Zeitplan: $tg" 'Error'; return }
    if ($tg.Type -eq 'Drive' -and $tg.Letter -eq $env:SystemDrive.Substring(0, 1).ToUpper()) {
        if (-not (Confirm-Action "Der Backup-Ordner liegt auf dem Systemlaufwerk ($($env:SystemDrive)).`nFaellt die Festplatte aus, ist das Backup auch weg.`n`nTrotzdem planen?" 'Zeitplan')) { return }
    }
    # HUMig selbst muss zur Laufzeit erreichbar sein
    $appQ = $script:AppRoot.Substring(0, [Math]::Min(2, $script:AppRoot.Length)).ToUpper()
    if ($script:AppRoot -like '\\*') {
        if (-not (Confirm-Action "HUMig liegt auf einer Netzwerkfreigabe ($($script:AppRoot)).`nDie geplante Aufgabe startet HUMig von dort - die Freigabe muss beim Lauf erreichbar sein.`nEmpfehlung: HUMig lokal ablegen (z.B. C:\Tools\HUMig).`n`nTrotzdem planen?" 'Zeitplan')) { return }
    } elseif ($appQ -ne $env:SystemDrive.ToUpper()) {
        if (-not (Confirm-Action "HUMig liegt auf $appQ (nicht auf $($env:SystemDrive)).`nDie geplante Aufgabe startet HUMig von dort - ist das Laufwerk (z.B. USB) beim Lauf nicht angesteckt, laeuft das Backup nicht.`nEmpfehlung: HUMig lokal ablegen (z.B. C:\Tools\HUMig) und dort planen.`n`nTrotzdem planen?" 'Zeitplan')) { return }
    }
    $defs = Get-HMBsDefinitions
    $defs = @($defs)
    $opt = Get-BackupOptions
    $info = "Benutzer: $($me.Name) an $env:COMPUTERNAME$(if (-not $elev) { '  (ohne Administratorrechte: nur eigenes Profil)' })`nModule ($($mods.Count)): $(@($mods | ForEach-Object { $_.Name }) -join ', ')$(if (@($opt.ExtraFolders).Count) { "`nZusaetzliche Ordner: $(@($opt.ExtraFolders) -join '; ')" })`nZiel: $($tg.Display)`n`nEs gelten die aktuelle Modulauswahl, Ausnahmen und Optionen (Pruefen, Katalog, OneDrive ...)."
    $n = 1; $defName = 'Backup'
    while (@($defs | Where-Object { "$($_.Name)" -eq $defName }).Count) { $n++; $defName = "Backup $n" }
    $r = Show-HMBsDialog $info $defName
    if (-not $r) { return }
    if (@($defs | Where-Object { "$($_.Name)" -eq $r.Name }).Count) { Out-Console "Zeitplan '$($r.Name)' gibt es schon - bitte anderen Namen waehlen oder den alten loeschen (Rechtsklick auf Zeitplan)." 'Warning'; return }

    $id = [guid]::NewGuid().ToString('N').Substring(0, 16)
    # Benutzername im Aufgabennamen: Aufgaben mehrerer Benutzer (oberste Ebene) kommen sich nicht in die Quere
    $taskName = $script:BsTaskPrefix + ($env:USERNAME -replace '[\\/:*?"<>|]', '_') + ' - ' + $r.Name
    $def = [ordered]@{
        Id = $id; Name = $r.Name; Created = (Get-Date).ToString('yyyy-MM-dd HH:mm'); ToolVersion = $script:Version
        Account = $me.Name; Sid = $me.User.Value; Computer = $env:COMPUTERNAME; Elevated = [bool]$elev
        Kind = $r.Kind; Trigger = [ordered]@{ Mode = $r.Mode; Time = $r.Time; Days = @($r.Days); Delay = $r.Delay }
        Modules = @($mods | ForEach-Object { "$($_.Id)" }); ModuleNames = @($mods | ForEach-Object { "$($_.Name)" })
        Options = [ordered]@{
            ExtraFolders = @($opt.ExtraFolders); ExcludePaths = @($opt.ExcludePaths)
            MinimalProfileExceptions = [bool]$opt.MinimalProfileExceptions; NoProfileFileExceptions = [bool]$opt.NoProfileFileExceptions
            MinimalSystemExceptions = [bool]$opt.MinimalSystemExceptions; NoSystemFileExceptions = [bool]$opt.NoSystemFileExceptions
            OneDriveLocal = [bool]$opt.OneDriveLocal; SkipSpaceCheck = [bool]$opt.SkipSpaceCheck; Verify = [bool]$opt.Verify; Catalog = [bool]$opt.Catalog
        }
        Threads = [int]$ui.cmbThreads.SelectedItem
        Target = $tg
        Retention = [ordered]@{ Enabled = [bool]$r.RetEnabled; Keep = [int]$r.Keep }
        NotifyAlways = [bool]$r.NotifyAlways
        TaskName = $taskName; TaskPath = ''
        LastRun = ''; LastStatus = ''; LastMessage = ''; LastBackup = ''; LastLog = ''
    }
    $defFile = Join-Path $script:BsDir "$id.json"
    try {
        New-Item -ItemType Directory -Path $script:BsDir -Force | Out-Null
        [pscustomobject]$def | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $defFile -Encoding UTF8 -Force
    } catch { Out-Console "Zeitplan-Datei konnte nicht gespeichert werden: $($_.Exception.Message)" 'Error'; return }

    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $task = Join-Path $script:AppRoot 'Functions\Backup-Task.ps1'
    $arg = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$task`" -Id $id"
    $used = $null; $err = ''
    try {
        $a = New-ScheduledTaskAction -Execute $ps -Argument $arg -WorkingDirectory $script:AppRoot
        $s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 12) -MultipleInstances IgnoreNew
        $at = if ($r.Time) { [datetime]::ParseExact($r.Time, 'HH:mm', [System.Globalization.CultureInfo]::InvariantCulture) } else { Get-Date }
        $desc = "HUMig: geplantes Backup '$($r.Name)' fuer $($me.Name). Verwalten: HUMig > Backup > Zeitplan (Rechtsklick). Definition: $defFile"
        # Konto: Name (DOMAENE\Benutzer, AzureAD\...), notfalls SID
        foreach ($uid in @($me.Name, $me.User.Value)) {
            $trg = switch ($r.Mode) {
                'Daily'  { New-ScheduledTaskTrigger -Daily -At $at }
                'Weekly' { New-ScheduledTaskTrigger -Weekly -DaysOfWeek $r.Days -At $at }
                default  { $lt = New-ScheduledTaskTrigger -AtLogOn -User $uid; if ($r.Delay -gt 0) { $lt.Delay = "PT$($r.Delay)M" }; $lt }
            }
            $pr = New-ScheduledTaskPrincipal -UserId $uid -LogonType Interactive -RunLevel $(if ($elev) { 'Highest' } else { 'Limited' })
            # eigener Ordner \HUMig\ - ohne Rechte dafuer (Standardbenutzer) in der obersten Ebene
            foreach ($tp in @('\HUMig\', '\')) {
                try {
                    Register-ScheduledTask -TaskName $taskName -TaskPath $tp -Action $a -Trigger $trg -Principal $pr -Settings $s -Description $desc -Force -ErrorAction Stop | Out-Null
                    $used = $tp; break
                } catch { $err = $_.Exception.Message }
            }
            if ($used) { break }
        }
    } catch { $err = $_.Exception.Message }
    if (-not $used) {
        Remove-Item -LiteralPath $defFile -Force -ErrorAction SilentlyContinue
        Out-Console "Zeitplan konnte nicht angelegt werden: $err" 'Error'; return
    }
    $def.TaskPath = $used
    try { [pscustomobject]$def | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $defFile -Encoding UTF8 -Force } catch { }
    Out-Console "Geplant: '$($r.Name)' - $(Format-HMBsWhen ([pscustomobject]@{ Trigger = [pscustomobject]$def.Trigger })), $(if ($r.Kind -eq 'Update') { 'fortlaufend' } else { 'neues Backup' }) -> $($tg.Display)$(if ($r.RetEnabled) { ", neueste $($r.Keep) bleiben" })" 'Success'
    Out-Console "   Aufgabenplanung: $used$taskName   (Konto $($me.Name)$(if ($elev) { ', mit Administratorrechten' } else { ', Benutzer-Modus' }))   Verwalten: Rechtsklick auf 'Zeitplan ...'" 'Info'
    Update-HMBsLabel
}

# ----------------------------------------------------------------------------
# Anzeige / Verwaltung
# ----------------------------------------------------------------------------
function Get-HMBsTask($d) {
    if (-not $d.TaskName) { return $null }
    foreach ($tp in @("$($d.TaskPath)", '\HUMig\', '\') | Where-Object { $_ } | Select-Object -Unique) {
        $t = Get-ScheduledTask -TaskPath $tp -TaskName "$($d.TaskName)" -ErrorAction SilentlyContinue
        if ($t) { return $t }
    }
    return $null
}
function Get-HMBsRows {
    $rows = @()
    $defs = Get-HMBsDefinitions
    foreach ($d in @($defs)) {
        $t = Get-HMBsTask $d
        $next = ''; $state = 'fehlt'
        if ($t) {
            $state = switch ("$($t.State)") { 'Ready' { 'bereit' } 'Running' { 'laeuft' } 'Disabled' { 'deaktiviert' } default { "$($t.State)" } }
            try { $i = Get-ScheduledTaskInfo -TaskPath $t.TaskPath -TaskName $t.TaskName -ErrorAction Stop; if ($i.NextRunTime) { $next = $i.NextRunTime.ToString('dd.MM.yyyy HH:mm') } } catch { }
        }
        $res = switch ("$($d.LastStatus)") { 'OK' { 'OK' } 'Warning' { 'Warnung' } 'Skipped' { 'uebersprungen' } 'Error' { 'Fehler' } default { '' } }
        $tgt = if ($d.Target.Type -eq 'Unc') { "$($d.Target.Path)" } elseif ($d.Target.Label) { "'$($d.Target.Label)'$(if ($d.Target.Rel) { "\$($d.Target.Rel)" })" } else { "$($d.Target.Letter):\$($d.Target.Rel)" }
        $rows += [pscustomobject]@{
            Name = "$($d.Name)"; Art = $(if ($d.Kind -eq 'Update') { 'fortlaufend' } else { 'neu' }); Wann = (Format-HMBsWhen $d); Ziel = $tgt
            Aufbewahrung = $(if ($d.Retention -and $d.Retention.Enabled) { "neueste $($d.Retention.Keep)" } else { 'aus' })
            Zustand = $state; Next = $next; Last = "$($d.LastRun)"; Result = $res; Msg = "$($d.LastMessage)"; Def = $d; Task = $t
        }
    }
    return ,$rows
}
function Update-HMBsLabel {
    if (-not $ui.lblBackupSchedule) { return }
    try {
        $rows = Get-HMBsRows
        $rows = @($rows)
        if (-not $rows.Count) { $ui.lblBackupSchedule.Text = 'Kein Zeitplan (Links: planen)'; return }
        $ui.lblBackupSchedule.Text = (@($rows | ForEach-Object { "$($_.Name): $($_.Wann)$(if ($_.Result) { ", zuletzt $($_.Result)" })$(if ($_.Zustand -eq 'fehlt') { ' - AUFGABE FEHLT' })" }) -join "`n") + "`n(Rechtsklick: verwalten)"
    } catch { $ui.lblBackupSchedule.Text = '' }
}
function Show-HMBackupSchedules {
    $rows = Get-HMBsRows
    $rows = @($rows)
    if (-not $rows.Count) { Out-Console "Keine geplanten Backups fuer $([Security.Principal.WindowsIdentity]::GetCurrent().Name). Anlegen: Links-Klick auf 'Zeitplan ...'." 'Info'; return }
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($r in $rows) { $list.Add(@($r.Name, $r.Art, $r.Wann, $r.Ziel, $r.Aufbewahrung, $r.Zustand, $r.Next, $r.Last, $r.Result, $r.Msg, "$($r.Def.Id)")) }
    Show-DataGridWindow -Title "Geplante Backups - $([Security.Principal.WindowsIdentity]::GetCurrent().Name)" -Width 1350 -Height 420 `
        -Columns @('Name', 'Art', 'Wann', 'Ziel', 'Aufbewahrung', 'Zustand', 'Naechster_Lauf', 'Letzter_Lauf', 'Ergebnis', 'Meldung', 'Id') -Rows $list.ToArray() `
        -CountText 'Protokolle: %LOCALAPPDATA%\HUMig\Zeitplaene\Logs - Bericht des Backups: Bericht_Backup.html im Backup-Ordner' `
        -Actions @(
            @{ Text = 'Jetzt starten'; Color = '#FFA6E3A1'; Handler = { param($sel, $w, $c)
                    foreach ($x in $sel) {
                        $all = Get-HMBsDefinitions; $d = @(@($all) | Where-Object { "$($_.Id)" -eq "$($x.Id)" })[0]
                        $t = if ($d) { Get-HMBsTask $d } else { $null }
                        if (-not $t) { Out-Console "$($x.Name): Aufgabe fehlt - Zeitplan loeschen und neu anlegen" 'Error'; continue }
                        try { Start-ScheduledTask -TaskPath $t.TaskPath -TaskName $t.TaskName -ErrorAction Stop; Out-Console "Gestartet: $($x.Name) (laeuft im Hintergrund, Meldung am Ende)" 'Success' } catch { Out-Console "$($x.Name): $($_.Exception.Message)" 'Error' }
                    }
                    $w.Close(); Update-HMBsLabel } },
            @{ Text = 'Protokoll'; Color = '#FF89B4FA'; Handler = { param($sel, $w, $c)
                    foreach ($x in @($sel | Select-Object -First 1)) {
                        $all = Get-HMBsDefinitions; $d = @(@($all) | Where-Object { "$($_.Id)" -eq "$($x.Id)" })[0]
                        if ($d -and $d.LastLog -and (Test-Path -LiteralPath "$($d.LastLog)")) { Start-Process notepad.exe -ArgumentList "`"$($d.LastLog)`"" } else { Out-Console "$($x.Name): noch kein Protokoll (Zeitplan ist noch nicht gelaufen)" 'Info' }
                    } } },
            @{ Text = 'Bericht'; Color = '#FF89B4FA'; Handler = { param($sel, $w, $c)
                    foreach ($x in @($sel | Select-Object -First 1)) {
                        $all = Get-HMBsDefinitions; $d = @(@($all) | Where-Object { "$($_.Id)" -eq "$($x.Id)" })[0]
                        $rep = if ($d -and $d.LastBackup) { Join-Path "$($d.LastBackup)" 'Bericht_Backup.html' } else { '' }
                        if ($rep -and (Test-Path -LiteralPath $rep)) { Start-Process -FilePath $rep } else { Out-Console "$($x.Name): kein Bericht vorhanden (noch nicht gelaufen, uebersprungen oder Ziel nicht angesteckt)" 'Info' }
                    } } },
            @{ Text = 'Loeschen'; Color = '#FFF38BA8'; Handler = { param($sel, $w, $c)
                    if (-not (Confirm-Action "$(@($sel).Count) Zeitplan/Zeitplaene loeschen?`n(Vorhandene Backups bleiben erhalten.)")) { return }
                    foreach ($x in $sel) {
                        $all = Get-HMBsDefinitions; $d = @(@($all) | Where-Object { "$($_.Id)" -eq "$($x.Id)" })[0]
                        if (-not $d) { continue }
                        $t = Get-HMBsTask $d
                        $ok = $true
                        if ($t) { try { Unregister-ScheduledTask -TaskPath $t.TaskPath -TaskName $t.TaskName -Confirm:$false -ErrorAction Stop } catch { $ok = $false; Out-Console "$($x.Name): Aufgabe nicht loeschbar: $($_.Exception.Message)" 'Error' } }
                        if ($ok) { Remove-Item -LiteralPath (Join-Path $script:BsDir "$($d.Id).json") -Force -ErrorAction SilentlyContinue; Out-Console "Zeitplan geloescht: $($x.Name)" 'Info' }
                    }
                    $w.Close(); Update-HMBsLabel } }
        )
}
