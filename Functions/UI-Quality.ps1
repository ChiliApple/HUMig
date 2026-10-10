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
    return $ctx
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
    if ($b.Created -and [datetime]::TryParse("$($b.Created)", [ref]$d)) { return $d }
    try { return (Get-Item -LiteralPath $b.Path).LastWriteTime } catch { return [datetime]::MinValue }
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
        if (-not $rows.Count) { Out-Console 'Vorschau: am Ziel ist alles bereits gleich (nichts zu tun).' 'Success'; return }
        Show-DataGridWindow -Title 'Restore-Vorschau' -Columns @('Aktion', 'Modul', 'Ziel', 'Groesse', 'Stand Backup', 'Stand Ziel') `
            -ColumnTypes @{ Groesse = [long]; 'Stand Backup' = [datetime]; 'Stand Ziel' = [datetime] } -Rows $rows.ToArray() -Sort 'Aktion ASC, Ziel ASC' -CountText $r.Summary -Width 1300 -Height 640
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
# ----------------------------------------------------------------------------
function Get-HMRetentionCandidates {
    param([object[]]$Backups, [int]$Days, [int]$Keep)
    $now = Get-Date
    $out = New-Object System.Collections.Generic.List[object]
    $groups = @{}
    foreach ($b in @($Backups)) {
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
    if ("$([System.Windows.MessageBox]::Show($Win, "$($Names.Count) Backup(s) endgueltig loeschen?`n`n$list", 'Backups loeschen', 'YesNo', 'Warning'))" -ne 'Yes') { return }
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
        if ($Open) { Start-Process $file }
    } catch { if (-not $Quiet) { Out-Console "Uebersicht fehlgeschlagen: $($_.Exception.Message)" 'Error' } }
}
