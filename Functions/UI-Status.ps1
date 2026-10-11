#Requires -Version 5.1
<#
.SYNOPSIS
    Reiter "Status" (Startseite) und Hinweise beim Start: Backup-Zeitplaene, letzte Backups je PC, Server-Backup (Platten),
    App-Updates - alles auf einen Blick. Abschaltbar unter Einstellungen > Allgemein (Reiter Status).
.DESCRIPTION
    Get-HMStatusData rechnet nur (testbar, ohne Oberflaeche), Update-HMStatusPage zeichnet den Reiter.
    Hinweise beim Start (Zeitplan seit X Tagen ohne Erfolg, Platte seit X Tagen nicht gesichert, Archiv faellig,
    Massenloeschung) erscheinen auch bei ausgeblendetem Reiter in der Ausgabe.
.NOTES
    Dot-Source aus HUMig.ps1. Zielmaschine: der PC, auf dem HUMig laeuft.
#>

# Alle Werte fuer die Startseite. Eingaben sind schon gelesene Daten (Zeitplaene, Backups, Server-Backup-Profile + Verlauf,
# App-Update-Verlauf, Plattenzustand je Bezeichnung = Get-HMSbHealthSummary); $Now und $StaleDays fuer Tests.
# Rueckgabe: Warnings (Text, Level), Schedules, Backups, Server, Apps
function Get-HMStatusData {
    param($BsRows = @(), $Backups = @(), $SbProfiles = @(), $SbHistory = @(), $AuHistory = @(), [datetime]$Now = (Get-Date), [int]$StaleDays = 8, $SbHealth = @{})
    if ($null -eq $SbHealth) { $SbHealth = @{} }
    $warn = New-Object System.Collections.Generic.List[object]
    $parse = {
        param($s)
        $d = [datetime]::MinValue
        foreach ($f in @('yyyy-MM-dd HH:mm', 'yyyy-MM-dd HH:mm:ss', 'yyyy-MM-ddTHH:mm:ss', 'dd.MM.yyyy HH:mm')) {
            if ([datetime]::TryParseExact("$s", $f, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$d)) { return $d }
        }
        if ([datetime]::TryParse("$s", [ref]$d)) { return $d }
        return $null
    }
    $days = { param($d) if ($d) { [int][Math]::Floor(($Now - $d).TotalDays) } else { $null } }

    # --- Backup-Zeitplaene: letzter Erfolg (LastSuccess, aeltere Zeitplaene: LastRun mit OK/Warnung)
    $sched = @()
    foreach ($r in @($BsRows | Where-Object { $_ })) {
        $d = $r.Def
        $ls = $null
        if ($d -and $d.PSObject.Properties['LastSuccess'] -and "$($d.LastSuccess)") { $ls = & $parse "$($d.LastSuccess)" }
        elseif ($d -and "$($d.LastStatus)" -in @('OK', 'Warning')) { $ls = & $parse "$($d.LastRun)" }
        $created = if ($d -and $d.PSObject.Properties['Created']) { & $parse "$($d.Created)" } else { $null }
        $age = & $days $ls
        $level = 'OK'; $note = ''
        if ("$($r.Zustand)" -eq 'fehlt') { $level = 'Error'; $note = 'geplante Aufgabe fehlt' }
        elseif ("$($r.Zustand)" -eq 'deaktiviert') { $level = 'Warning'; $note = 'deaktiviert' }
        elseif ("$($d.LastStatus)" -eq 'Error') { $level = 'Error'; $note = 'letzter Lauf fehlgeschlagen' }
        if ($level -ne 'Error' -and "$($r.Zustand)" -ne 'deaktiviert') {
            if ($null -ne $age -and $age -gt $StaleDays) { $level = 'Error'; $note = "seit $age Tagen kein erfolgreicher Lauf" }
            elseif ($null -eq $age -and $created -and (& $days $created) -gt $StaleDays) { $level = 'Error'; $note = "seit dem Anlegen ($(& $days $created) Tage) kein erfolgreicher Lauf" }
        }
        $sched += [pscustomobject]@{ Name = "$($r.Name)"; When = "$($r.Wann)"; Last = "$($r.Last)"; Result = "$($r.Result)"; SuccessAge = $age; Next = "$($r.Next)"; Level = $level; Note = $note }
        if ($level -ne 'OK') { $warn.Add([pscustomobject]@{ Level = $level; Area = 'Zeitplan'; Text = "Backup-Zeitplan '$($r.Name)': $note" }) }
    }

    # --- letzte Backups je PC + Benutzer (neuestes Backup je Gruppe)
    $groups = @{}
    foreach ($b in @($Backups | Where-Object { $_ })) {
        $k = ("{0}|{1}" -f $b.Computer, $(if ($b.Sid) { $b.Sid } else { $b.User })).ToUpperInvariant()
        $dt = & $parse "$($b.Created)"
        if (-not $groups.ContainsKey($k) -or ($dt -and $dt -gt $groups[$k].Date)) { $groups[$k] = [pscustomobject]@{ B = $b; Date = $dt } }
    }
    $bk = @()
    foreach ($g in @($groups.Values | Sort-Object Date -Descending)) {
        $b = $g.B
        $age = & $days $g.Date
        $level = switch ("$($b.Status)") { 'OK' { 'OK' } 'Legacy' { 'OK' } 'Warning' { 'Warning' } default { 'Error' } }
        $mass = [bool]($b.Manifest -and $b.Manifest.MassDeleteAlert)
        if ($mass) {
            $level = 'Error'
            if ($null -ne $age -and $age -le 14) { $warn.Add([pscustomobject]@{ Level = 'Error'; Area = 'Backup'; Text = "Massenloeschung erkannt: $($b.Computer) \ $(if ($b.Account) { $b.Account } else { $b.User }) ($($g.Date.ToString('dd.MM.yyyy'))) - typisches Zeichen fuer einen Verschluesselungstrojaner, Quell-PC pruefen" }) }
        }
        $bk += [pscustomobject]@{ Computer = "$($b.Computer)"; User = "$(if ($b.Account) { $b.Account } else { $b.User })"; Date = $g.Date; Age = $age; Status = "$($b.Status)"; Size = [long]$b.SizeBytes; Level = $level; Mass = $mass }
    }

    # --- Server-Backup: je Profil letzte erfolgreiche Sicherung, Platten seit X Tagen nicht gesichert, Archiv faellig
    $sb = @()
    foreach ($p in @($SbProfiles | Where-Object { $_ })) {
        $mine = @(@($SbHistory) | Where-Object { $_ -and "$($_.Profile)" -eq $p.Name } | Sort-Object { "$($_.Date)" } -Descending)
        $wd = if ([int]$p.WarnDays -gt 0) { [int]$p.WarnDays } else { 14 }
        $lastOk = @($mine | Where-Object { "$($_.Status)" -ne 'Error' })[0]
        $lastAny = $mine | Select-Object -First 1
        $okAge = if ($lastOk) { & $days (& $parse "$($lastOk.Date)") } else { $null }
        $disks = @()
        $labels = @(1..[Math]::Max(1, [int]$p.Disks) | ForEach-Object { "$($p.DiskPrefix)-$_" })
        if ([int]$p.ArchiveDisks -gt 0) { $labels += @(1..[int]$p.ArchiveDisks | ForEach-Object { "$($p.DiskPrefix)-A$_" }) }
        foreach ($lb in $labels) {
            $isArc = $lb -match '-A\d+$'
            $e = @($mine | Where-Object { "$($_.Disk)" -eq $lb -and "$($_.Status)" -ne 'Error' })[0]
            $a = if ($e) { & $days (& $parse "$($e.Date)") } else { $null }
            # Plattenzustand (letzte Messung)
            $hl = ''; $ht = ''
            if ($SbHealth.ContainsKey($lb) -and $SbHealth[$lb].Verdict) { $hl = "$($SbHealth[$lb].Verdict.Level)"; $ht = "$($SbHealth[$lb].Verdict.Text)" }
            if (-not $isArc) { $disks += [pscustomobject]@{ Label = $lb; Age = $a; Level = $(if ($null -eq $a -or $a -gt $wd) { 'Warning' } else { 'OK' }); Health = $hl; HealthText = $ht } }
            elseif ($hl) { $disks += [pscustomobject]@{ Label = $lb; Age = $a; Level = 'OK'; Health = $hl; HealthText = $ht; Archive = $true } }
            if (-not $isArc -and $mine.Count -and $null -ne $a -and $a -gt $wd) { $warn.Add([pscustomobject]@{ Level = 'Warning'; Area = 'Server-Backup'; Text = "Server-Backup '$($p.Name)': Platte $lb seit $a Tagen nicht gesichert - Platte wechseln (Rotation)" }) }
            if ($hl -in @('Warning', 'Error')) { $warn.Add([pscustomobject]@{ Level = $hl; Area = 'Server-Backup'; Text = "Server-Backup '$($p.Name)': Platte $lb - $ht" }) }
        }
        $arcDue = $false; $arcAge = $null
        if ([int]$p.ArchiveDisks -gt 0) {
            $ae = @($mine | Where-Object { "$($_.Disk)" -match ('^' + [regex]::Escape("$($p.DiskPrefix)") + '-A\d+$') -and "$($_.Status)" -ne 'Error' })[0]
            $arcAge = if ($ae) { & $days (& $parse "$($ae.Date)") } else { $null }
            $ad = if ([int]$p.ArchiveDays -gt 0) { [int]$p.ArchiveDays } else { 30 }
            $arcDue = ($null -eq $arcAge -or $arcAge -ge $ad)
            if ($arcDue -and $mine.Count) { $warn.Add([pscustomobject]@{ Level = 'Warning'; Area = 'Server-Backup'; Text = "Server-Backup '$($p.Name)': Archiv-Sicherung faellig$(if ($null -ne $arcAge) { " (letzte vor $arcAge Tagen)" })" }) }
        }
        $level = 'OK'
        if (-not $lastOk) { $level = $(if ($mine.Count) { 'Error' } else { 'Warning' }) }
        elseif ($okAge -gt $wd) { $level = 'Error' }
        elseif ($lastAny -and "$($lastAny.Status)" -eq 'Error') { $level = 'Error' }
        if ($level -eq 'Error' -and $mine.Count) {
            $t = if (-not $lastOk) { 'noch keine erfolgreiche Sicherung' } elseif ($okAge -gt $wd) { "letzte erfolgreiche Sicherung vor $okAge Tagen" } else { 'letzter Lauf fehlgeschlagen' }
            $warn.Add([pscustomobject]@{ Level = 'Error'; Area = 'Server-Backup'; Text = "Server-Backup '$($p.Name)': $t" })
        }
        # Plattenzustand hebt die Stufe (Hinweis steht schon oben je Platte)
        if (@($disks | Where-Object { "$($_.Health)" -eq 'Error' }).Count) { $level = 'Error' }
        elseif ($level -eq 'OK' -and @($disks | Where-Object { "$($_.Health)" -eq 'Warning' }).Count) { $level = 'Warning' }
        $sb += [pscustomobject]@{ Name = "$($p.Name)"; LastOk = $(if ($lastOk) { "$($lastOk.Date)" } else { '' }); OkAge = $okAge; LastDisk = $(if ($lastOk) { "$($lastOk.Disk)" } else { '' }); Disks = $disks; ArchiveDue = $arcDue; ArchiveAge = $arcAge; Level = $level; Runs = $mine.Count }
    }

    # --- App-Updates: letzte 7 Tage je PC
    $au = @()
    $since = $Now.AddDays(-7)
    $recent = @(@($AuHistory) | Where-Object { $_ -and ($d = & $parse "$($_.Date)") -and $d -ge $since })
    foreach ($g in @($recent | Group-Object { "$($_.Computer)".ToUpperInvariant() } | Sort-Object Name)) {
        $ok = @($g.Group | Where-Object { "$($_.Status)" -eq 'OK' }).Count
        $bad = @($g.Group | Where-Object { "$($_.Status)" -notin @('OK', 'Skipped') })
        $au += [pscustomobject]@{ Computer = "$($g.Group[0].Computer)"; Ok = $ok; Failed = $bad.Count; FailedNames = @($bad | ForEach-Object { "$($_.Name)" } | Select-Object -Unique -First 4); Level = $(if ($bad.Count) { 'Warning' } else { 'OK' }) }
    }
    return [pscustomobject]@{ Warnings = $warn.ToArray(); Schedules = $sched; Backups = $bk; Server = $sb; Apps = $au; Time = $Now }
}

# ----------------------------------------------------------------------------
# Oberflaeche
# ----------------------------------------------------------------------------
$script:StatusColors = @{ OK = '#FFA6E3A1'; Warning = '#FFFAB387'; Error = '#FFF38BA8'; Info = '#FF89B4FA'; Grey = '#FF6C7086' }
function New-HMStatusLine([string]$Level, [string]$Text, [string]$Sub = '') {
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.TextWrapping = 'Wrap'
    $tb.Margin = [System.Windows.Thickness]::new(4, 2, 0, 2)
    $dot = New-Object System.Windows.Documents.Run ("$([char]0x25CF)  ")
    $dot.Foreground = New-Brush $(if ($script:StatusColors.ContainsKey($Level)) { $script:StatusColors[$Level] } else { $script:StatusColors.Grey })
    [void]$tb.Inlines.Add($dot)
    $r = New-Object System.Windows.Documents.Run $Text
    $r.Foreground = New-Brush '#FFCDD6F4'
    [void]$tb.Inlines.Add($r)
    if ($Sub) { $s = New-Object System.Windows.Documents.Run ("   " + $Sub); $s.Foreground = New-Brush '#FFA6ADC8'; [void]$tb.Inlines.Add($s) }
    return $tb
}
function New-HMStatusHeader([string]$Text, $Tab) {
    $dp = New-Object System.Windows.Controls.DockPanel
    $dp.LastChildFill = $false   # sonst fuellt der Knopf die ganze Breite
    $dp.Margin = [System.Windows.Thickness]::new(0, 14, 0, 4)
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $Text
    try { $tb.Style = $script:Window.FindResource('SectionLabel') } catch { }
    $tb.VerticalAlignment = 'Center'
    if ($Tab) {
        $b = New-Object System.Windows.Controls.Button
        $b.Content = 'Oeffnen'
        try { $b.Style = $script:Window.FindResource('BtnDefault') } catch { }
        $b.Margin = [System.Windows.Thickness]::new(10, 0, 0, 0)
        $b.Padding = [System.Windows.Thickness]::new(10, 1, 10, 1)
        $b.HorizontalAlignment = 'Left'
        $b.Tag = $Tab
        $b.Add_Click({ param($s) $ui.tabMain.SelectedItem = $s.Tag })
        [System.Windows.Controls.DockPanel]::SetDock($b, 'Left')
        [void]$dp.Children.Add($tb); [void]$dp.Children.Add($b)
    } else { [void]$dp.Children.Add($tb) }
    return $dp
}
function Get-HMStatusTab([string]$Header) { return @($ui.tabMain.Items | Where-Object { $_ -is [System.Windows.Controls.TabItem] -and "$($_.Header)" -eq $Header })[0] }

# Daten sammeln (am PC, auf dem HUMig laeuft) und Startseite zeichnen; -StartUp: Hinweise zusaetzlich in die Ausgabe
function Update-HMStatusPage([switch]$StartUp) {
    $sd = 8
    try { if ($null -ne $script:Settings.StatusStaleDays -and [int]$script:Settings.StatusStaleDays -gt 0) { $sd = [int]$script:Settings.StatusStaleDays } } catch { }
    $bs = @(); $sbp = @(); $sbh = @(); $au = @(); $sbHealth = @{}
    try { $bs = @(Get-HMBsRows) } catch { }
    if (-not $script:UserMode) {
        try { $sbp = @((Get-HMSbConfig).Profiles) } catch { }
        try { if ($sbp.Count) { $sbh = @(Get-HMSbAllHistory) } } catch { }
        try { if ($sbp.Count) { $sbHealth = Get-HMSbHealthSummary (Read-HMSbHealthStore $script:SbHealthFile) } } catch { }
        try { if (Test-Path -LiteralPath $script:AuHistFile) { $aj = Get-Content -LiteralPath $script:AuHistFile -Raw -Encoding UTF8 | ConvertFrom-Json; $au = @($aj) } } catch { }
    }
    $data = Get-HMStatusData -BsRows $bs -Backups @($script:BackupInfos) -SbProfiles $sbp -SbHistory $sbh -AuHistory $au -StaleDays $sd -SbHealth $sbHealth
    $script:StatusData = $data
    $nw = @($data.Warnings).Count
    if ($ui.tabStatus) { $ui.tabStatus.Header = $(if ($nw) { "Status ($nw)" } else { 'Status' }) }
    if ($StartUp -and $nw) {
        Out-Console "Hinweise beim Start ($nw) - Details: Reiter Status" 'Warning'
        foreach ($w in @($data.Warnings)) { Out-Console "   $($w.Text)" $(if ($w.Level -eq 'Error') { 'Error' } else { 'Warning' }) }
    }
    if (-not $ui.pnlStatus) { return }
    $p = $ui.pnlStatus
    $p.Children.Clear()
    $ui.lblStatusTime.Text = "Stand $($data.Time.ToString('dd.MM.yyyy HH:mm'))  |  Backup-Ordner: $(Get-BackupRoot)"
    # Wichtig
    [void]$p.Children.Add((New-HMStatusHeader 'WICHTIG' $null))
    if ($nw) { foreach ($w in @($data.Warnings)) { [void]$p.Children.Add((New-HMStatusLine $w.Level $w.Text)) } }
    else { [void]$p.Children.Add((New-HMStatusLine 'OK' 'Alles in Ordnung - keine offenen Hinweise.')) }
    # Zeitplaene
    [void]$p.Children.Add((New-HMStatusHeader 'BACKUP-ZEITPLAENE' (Get-HMStatusTab 'Backup')))
    if (@($data.Schedules).Count) {
        foreach ($s in @($data.Schedules)) {
            $sub = @("$($s.When)", $(if ($s.Last) { "zuletzt $($s.Last) $($s.Result)" } else { 'noch nie gelaufen' }), $(if ($null -ne $s.SuccessAge) { "letzter Erfolg vor $($s.SuccessAge) Tag(en)" }), $(if ($s.Next) { "naechster $($s.Next)" }), $s.Note) | Where-Object { $_ }
            [void]$p.Children.Add((New-HMStatusLine $s.Level $s.Name ($sub -join '  |  ')))
        }
    } else { [void]$p.Children.Add((New-HMStatusLine 'Grey' 'Kein Zeitplan angelegt (Reiter Backup > Zeitplan ...)')) }
    # letzte Backups
    [void]$p.Children.Add((New-HMStatusHeader 'LETZTE BACKUPS JE PC UND BENUTZER' (Get-HMStatusTab 'Restore')))
    if (@($data.Backups).Count) {
        foreach ($b in @($data.Backups | Select-Object -First 25)) {
            $lv = $b.Level; if ($lv -eq 'OK' -and $null -ne $b.Age -and $b.Age -gt 30) { $lv = 'Grey' }
            $st = switch ($b.Status) { 'OK' { 'OK' } 'Warning' { 'Warnung' } 'Error' { 'FEHLER' } 'Cancelled' { 'abgebrochen' } 'Running' { 'unvollstaendig' } 'Legacy' { 'altes Format' } default { $b.Status } }
            $sub = @($(if ($b.Date) { "$($b.Date.ToString('dd.MM.yyyy HH:mm')) (vor $($b.Age) Tag(en))" }), $st, $(if ($b.Size) { Format-HMSize $b.Size }), $(if ($b.Mass) { 'MASSENLOESCHUNG ERKANNT' })) | Where-Object { $_ }
            [void]$p.Children.Add((New-HMStatusLine $lv "$($b.Computer) \ $($b.User)" ($sub -join '  |  ')))
        }
        if (@($data.Backups).Count -gt 25) { [void]$p.Children.Add((New-HMStatusLine 'Grey' "... und $(@($data.Backups).Count - 25) weitere (Reiter Restore)")) }
    } else { [void]$p.Children.Add((New-HMStatusLine 'Grey' 'Keine Backups im Backup-Ordner')) }
    # Server-Backup
    if (@($data.Server).Count) {
        [void]$p.Children.Add((New-HMStatusHeader 'SERVER-BACKUP' (Get-HMStatusTab 'Server-Backup')))
        foreach ($s in @($data.Server)) {
            $dk = @($s.Disks | ForEach-Object {
                $hz = switch ("$($_.Health)") { 'Error' { ', DEFEKT?' } 'Warning' { ', Zustand pruefen' } 'OK' { ', Zustand gut' } default { '' } }
                if ($_.Archive) { "$($_.Label)$hz" } else { "$($_.Label): $(if ($null -eq $_.Age) { 'nie' } elseif ($_.Age -le 0) { 'heute' } else { "vor $($_.Age) T." })$hz" }
            }) -join ', '
            $sub = @($(if ($s.LastOk) { "zuletzt erfolgreich $($s.LastOk) auf $($s.LastDisk)" } else { 'noch keine erfolgreiche Sicherung' }), $dk, $(if ($s.ArchiveDue) { 'Archiv faellig' })) | Where-Object { $_ }
            [void]$p.Children.Add((New-HMStatusLine $s.Level $s.Name ($sub -join '  |  ')))
        }
    }
    # App-Updates
    if (-not $script:UserMode) {
        [void]$p.Children.Add((New-HMStatusHeader 'APP-UPDATES (LETZTE 7 TAGE)' (Get-HMStatusTab 'App-Updates')))
        if (@($data.Apps).Count) {
            foreach ($a in @($data.Apps)) {
                $sub = "$($a.Ok) aktualisiert$(if ($a.Failed) { ", $($a.Failed) FEHLER: $($a.FailedNames -join ', ')" })"
                [void]$p.Children.Add((New-HMStatusLine $a.Level $a.Computer $sub))
            }
        } else { [void]$p.Children.Add((New-HMStatusLine 'Grey' 'Keine App-Updates in den letzten 7 Tagen')) }
    }
}
function Set-HMStatusTabVisibility {
    $show = $true
    try { if ($null -ne $script:Settings.ShowStatusPage) { $show = [bool]$script:Settings.ShowStatusPage } } catch { }
    if ($ui.tabStatus) {
        $ui.tabStatus.Visibility = $(if ($show) { 'Visible' } else { 'Collapsed' })
        if (-not $show -and $ui.tabMain.SelectedItem -eq $ui.tabStatus) { $ui.tabMain.SelectedIndex = 1 }
    }
}
function Initialize-HMStatusTab {
    Set-HMStatusTabVisibility
    if ($ui.btnStatusRefresh) { $ui.btnStatusRefresh.Add_Click({ Update-HMStatusPage }) }
}
