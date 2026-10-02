#Requires -Version 5.1
<#
.SYNOPSIS
    Reiter "App-Updates": installierte Programme ueber WinGet aktualisieren - Liste mit Haken, Ausnahmen und Quellen je Standort, Verlauf.
.NOTES
    Zielmaschine: oben gewaehlter PC oder mehrere PCs (AD-Auswahl, WinRM), HUMig als Administrator. Wird im UI-Thread geladen (dot-source aus HUMig.ps1).
    Ausnahmen/Quellen: Config\appupdates.json (je Standort, Vorlage Config\appupdates.default.json) | Verlauf: Config\AppUpdates\history.json
#>

$script:AuEngine   = Join-Path $script:AppRoot 'Functions\AppUpdates-Engine.ps1'
$script:AuCfgFile  = Join-Path $script:ConfigDir 'appupdates.json'
$script:AuDefFile  = Join-Path $script:ConfigDir 'appupdates.default.json'
$script:AuHistFile = Join-Path $script:ConfigDir 'AppUpdates\history.json'
$script:AuInit     = $false
$script:AuReady    = $false
$script:AuSources  = @()
$script:AuDt       = $null
$script:AuButtons  = @()
$script:AuUsers    = @{}     # je PC: Benutzer der letzten Suche (Account, Sid)
$script:AuTargets  = @()     # mehrere Ziel-PCs (leer = oben gewaehlter PC)
$script:AuSchedData = @{}

# ----------------------------------------------------------------------------
# Einstellungen je Standort
# ----------------------------------------------------------------------------
function Get-HMAuLocation { if ($script:ActiveSchool -and "$($script:ActiveSchool.Name)".Trim()) { return "$($script:ActiveSchool.Name)".Trim() } return '(Standard)' }
function Get-HMAuConfig {
    $def = Read-JsonFile $script:AuDefFile
    $loc = Get-HMAuLocation
    $all = Read-JsonFile $script:AuCfgFile
    $mine = $null
    if ($all -and $all.Locations -and $all.Locations.PSObject.Properties[$loc]) { $mine = $all.Locations.$loc }
    $src = if ($mine -and $null -ne $mine.Sources) { @($mine.Sources) } elseif ($def) { @($def.Sources) } else { @('winget') }
    $exc = if ($mine -and $null -ne $mine.Exclude) { @($mine.Exclude) } elseif ($def) { @($def.Exclude) } else { @() }
    return [pscustomobject]@{
        Location = $loc
        Sources = @($src | Where-Object { "$_".Trim() } | ForEach-Object { "$_".Trim() })
        Exclude = @($exc | Where-Object { $_ -and "$($_.Pattern)".Trim() } | ForEach-Object { [pscustomobject]@{ Pattern = "$($_.Pattern)".Trim(); Reason = "$($_.Reason)".Trim() } })
        IncludeUnknown = [bool]($all -and $all.IncludeUnknown)
    }
}
function Save-HMAuConfig($Sources, $Exclude) {
    $all = Read-JsonFile $script:AuCfgFile
    $locs = [ordered]@{}
    if ($all -and $all.Locations) { foreach ($p in $all.Locations.PSObject.Properties) { $locs[$p.Name] = $p.Value } }
    $locs[(Get-HMAuLocation)] = [ordered]@{ Sources = @($Sources); Exclude = @($Exclude | ForEach-Object { [ordered]@{ Pattern = "$($_.Pattern)"; Reason = "$($_.Reason)" } }) }
    Write-JsonFile $script:AuCfgFile ([pscustomobject][ordered]@{
            _Info = 'App-Updates: Quellen und Ausnahmen je Standort (vom Reiter App-Updates gepflegt).'
            IncludeUnknown = [bool]$ui.chkAuUnknown.IsChecked
            Locations = [pscustomobject]$locs
        })
}

# ----------------------------------------------------------------------------
# Anzeige
# ----------------------------------------------------------------------------
function Update-HMAuExclList {
    $c = Get-HMAuConfig
    $ui.lstAuExcl.Items.Clear()
    foreach ($e in $c.Exclude) {
        $it = New-Object System.Windows.Controls.ListBoxItem
        $it.Content = "$($e.Pattern)$(if ($e.Reason) { "  -  $($e.Reason)" })"
        $it.Tag = $e
        $it.Foreground = New-Brush '#FFCDD6F4'
        [void]$ui.lstAuExcl.Items.Add($it)
    }
    $ui.lblAuLocation.Text = "Standort: $($c.Location)  -  Quellen und Ausnahmen gelten fuer diesen Standort (Standort oben im Reiter Werkzeuge bzw. Einstellungen > Standorte)"
}
function Update-HMAuSourceList {
    $c = Get-HMAuConfig
    $ui.pnlAuSources.Children.Clear()
    if (-not @($script:AuSources).Count) {
        $t = New-Object System.Windows.Controls.TextBlock; $t.Text = $(if ($script:AuReady) { "werden mit 'Updates suchen' gelesen - angehakt: $((Get-HMAuConfig).Sources -join ', ')" } else { '(WinGet nicht bereit)' }); $t.TextWrapping = 'Wrap'; $t.Foreground = New-Brush '#FF6C7086'; $t.FontSize = 11
        [void]$ui.pnlAuSources.Children.Add($t); return
    }
    foreach ($s in @($script:AuSources)) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = "$($s.Name)$(if ($s.Name -notin @('winget', 'msstore', 'winget-font')) { "  ($($s.Argument))" })"
        $cb.Tag = "$($s.Name)"
        $cb.IsChecked = ($c.Sources -contains "$($s.Name)")
        $cb.Foreground = New-Brush '#FFCDD6F4'
        $cb.Margin = [System.Windows.Thickness]::new(0, 1, 0, 1)
        $cb.ToolTip = "$($s.Type): $($s.Argument)$(if ($s.Name -eq 'msstore') { "`nMicrosoft Store - braucht Zustimmungen, in Schulen oft gesperrt (Firewall mit SSL-Pruefung)" })`nRechtsklick = Quelle von diesem PC entfernen"
        $cb.Add_Click({
                $sel = @($ui.pnlAuSources.Children | Where-Object { $_ -is [System.Windows.Controls.CheckBox] -and $_.IsChecked } | ForEach-Object { "$($_.Tag)" })
                $c2 = Get-HMAuConfig
                Save-HMAuConfig $sel $c2.Exclude
            })
        $cb.Add_MouseRightButtonUp({ param($s, $e) $e.Handled = $true; Remove-HMAuSourceUi "$($s.Tag)" })
        [void]$ui.pnlAuSources.Children.Add($cb)
    }
}
function Update-HMAuHistory {
    $h = @()
    # ConvertFrom-Json gibt ein JSON-Array in PS 5.1 als EIN Objekt weiter -> mit ForEach-Object aufloesen
    try { if (Test-Path -LiteralPath $script:AuHistFile) { $h = @(Get-Content -LiteralPath $script:AuHistFile -Raw -Encoding UTF8 | ConvertFrom-Json | ForEach-Object { $_ }) } } catch { }
    $rows = @(@($h) | Where-Object { $_ } | Sort-Object Date -Descending | Select-Object -First 500 | ForEach-Object {
            $st = switch ("$($_.Status)") { 'OK' { 'OK' } 'Skipped' { 'uebersprungen' } default { 'FEHLER' } }
            [pscustomobject]@{ Datum = "$($_.Date)"; PC = "$($_.Computer)"; Programm = "$($_.Name)"; Version = "$($_.From) -> $($_.To)"; Ergebnis = "$st - $($_.Text)" }
        })
    $ui.dgAuHistory.ItemsSource = $rows
}
function Add-HMAuHistory($Entries) {
    $h = @()
    try { if (Test-Path -LiteralPath $script:AuHistFile) { $h = @(Get-Content -LiteralPath $script:AuHistFile -Raw -Encoding UTF8 | ConvertFrom-Json | ForEach-Object { $_ }) } } catch { }
    $h = @(@($h) + @($Entries) | Where-Object { $_ } | Sort-Object Date -Descending | Select-Object -First 2000)
    try {
        $d = Split-Path $script:AuHistFile -Parent
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        ConvertTo-Json -InputObject @($h) -Depth 4 | Set-Content -LiteralPath $script:AuHistFile -Encoding UTF8
    } catch { Out-Console "App-Updates: Verlauf nicht speicherbar: $($_.Exception.Message)" 'Warning' }
    Update-HMAuHistory
}
function New-HMAuTable {
    $dt = New-Object System.Data.DataTable
    foreach ($c in @(@('Sel', [bool]), @('PC', [string]), @('Programm', [string]), @('Installiert', [string]), @('Verfuegbar', [string]), @('Quelle', [string]), @('Paket', [string]), @('Hinweis', [string]), @('Excl', [bool]), @('Bereich', [string]), @('Scope', [string]), @('Unknown', [bool]))) { [void]$dt.Columns.Add($c[0], $c[1]) }
    return , $dt
}

# ----------------------------------------------------------------------------
# Status / Einrichten
# ----------------------------------------------------------------------------
function Update-HMAuState([switch]$Search) {
    $ui.lblAuInfo.Text = 'WinGet wird geprueft ...'
    Invoke-AsyncCommand -ScriptBlock {
        param($eng)
        . $eng
        $st = Get-HMAuState
        [pscustomobject]@{ State = $st }
    } -ArgumentList @($script:AuEngine) -TimeoutSec 90 -BusyTag 'Au' -BusyText 'WinGet wird geprueft ...' -State @{ Search = [bool]$Search } -OnComplete {
        param($r, $stt)
        if (-not $r -or $r -is [string]) { $ui.lblAuInfo.Text = "WinGet nicht pruefbar: $r"; $ui.btnAuSetup.Visibility = 'Visible'; return }
        $s = $r.State
        $script:AuReady = [bool]$s.Ready
        $ui.btnAuSetup.Visibility = $(if ($s.Ready -or -not $s.OsOk) { 'Collapsed' } else { 'Visible' })
        $ui.lblAuInfo.Text = "$(if ($s.Ready) { "Dieser PC: WinGet $($s.WinGet), Modul $($s.Module), App Installer $($s.AppInstaller)" } else { "Dieser PC: $($s.Problem)" })  |  Gelesen wird am Ziel-PC im Konto des angemeldeten Benutzers (oben gewaehlter bevorzugt), ist niemand angemeldet als SYSTEM mit PowerShell 7 (wird bei Bedarf installiert). Aktualisiert: fuer alle Benutzer als SYSTEM, nur fuer einen Benutzer installierte in seinem Konto."
        $ui.btnAuSourceAdd.IsEnabled = [bool]$s.Ready -and -not $script:JobRunning
        Update-HMAuSourceList
        if ($s.Ready -and $stt.Search -and -not $script:JobRunning) { Start-HMAuSearch }
        elseif (-not $s.Ready) { Out-Console "App-Updates: $($s.Problem)" 'Warning' }
    }
}
function Start-HMAuSetup {
    if ($script:JobRunning) { Out-Console 'Es laeuft bereits ein Vorgang.' 'Warning'; return }
    if (-not (Confirm-Action "WinGet einrichten?`n`n- Modul Microsoft.WinGet.Client aus der PowerShell Gallery installieren (fuer alle Benutzer)`n- WinGet (App Installer) fuer dieses Konto registrieren bzw. reparieren`n`nInternet noetig (www.powershellgallery.com, github.com)." 'App-Updates')) { return }
    Start-EngineJob -Command 'Install-HMAuWinGet $Job | Out-Null' -Ctx @{ Kind = 'Setup' } -Title 'WinGet einrichten' -ScriptFiles @($script:Engine, $script:AuEngine) -OnFinished { param($j) Update-HMAuState -Search }
}

# ----------------------------------------------------------------------------
# Ziel-PCs: oben gewaehlter PC oder mehrere (AD-Auswahl)
# ----------------------------------------------------------------------------
function Get-HMAuComputers { if (@($script:AuTargets).Count) { return @($script:AuTargets) } return @(Get-TargetComputer) }
function Update-HMAuTargetLabel {
    $t = @($script:AuTargets)
    if ($t.Count) {
        $ui.lblAuTarget.Text = "$($t.Count) PC(s): $(@($t | Select-Object -First 6) -join ', ')$(if ($t.Count -gt 6) { ', ...' })"
        $ui.lblAuTarget.ToolTip = ($t -join "`n")
    } else {
        $ui.lblAuTarget.Text = "$(Get-TargetComputer) (oben gewaehlt)"
        $ui.lblAuTarget.ToolTip = 'Computer oben im Fenster - mit "Mehrere PCs / EDV-Saal" mehrere waehlen'
    }
}
function Select-HMAuTargets {
    Show-HMMultiDialog -PickTitle 'App-Updates' -OnPick {
        param($names)
        $script:AuTargets = @($names | Where-Object { "$_".Trim() } | Select-Object -Unique)
        Update-HMAuTargetLabel
        Out-Console "App-Updates: Ziel $($script:AuTargets.Count) PC(s) - Fernzugriff ueber WinRM, Anmeldedaten wie oben (Verbinden)." 'Info'
        Clear-HMAuList
    }
}
function Clear-HMAuList {
    $script:AuDt = $null; $ui.dgAu.ItemsSource = $null
    $ui.lblAuListTitle.Text = 'VERFUEGBARE UPDATES - "Updates suchen" fuer die Ziel-PCs'
}

# ----------------------------------------------------------------------------
# Suchen (Hintergrundvorgang, alle Ziel-PCs parallel)
# ----------------------------------------------------------------------------
function Start-HMAuSearch {
    if ($script:JobRunning) { Out-Console 'Es laeuft bereits ein Vorgang.' 'Warning'; return }
    $c = Get-HMAuConfig
    if (-not $c.Sources.Count) { Out-Console 'App-Updates: keine Quelle angehakt.' 'Warning'; return }
    Update-HMAuTargetLabel
    $pcs = @(Get-HMAuComputers)
    $top = Get-TargetComputer
    $p = Get-SelectedProfile
    $sid = ''
    if ($p -and $p.SID -and -not $p.NoProfile) { $sid = "$($p.SID)" }
    $ui.lblAuListTitle.Text = "VERFUEGBARE UPDATES - wird gesucht ($($pcs.Count) PC(s)) ..."
    $ctx = @{ Computers = $pcs; Sources = @($c.Sources); IncludeUnknown = [bool]$ui.chkAuUnknown.IsChecked; UserSid = $sid; SidPc = $top; Credential = $script:RemoteCred }
    Start-EngineJob -Command 'Start-HMAuSearchJob -Ctx $Ctx -Job $Job' -Ctx $ctx -Title 'Updates suchen' -ScriptFiles @($script:Engine, $script:AuEngine) -OnFinished { param($j) Show-HMAuSearchResult $j.Result }
}
function Show-HMAuSearchResult($Res) {
    if (-not $Res -or -not $Res.ByPc) { $ui.lblAuListTitle.Text = 'VERFUEGBARE UPDATES'; return }
    $c = Get-HMAuConfig
    $dt = New-HMAuTable
    $n = 0; $x = 0; $okPc = 0; $bad = @(); $readAs = @()
    $script:AuUsers = @{}
    $keys = @($Res.ByPc.Keys | Sort-Object)
    foreach ($k in $keys) {
        $v = $Res.ByPc[$k]
        if (-not $v -or -not $v.PSObject.Properties['Items'] -or -not "$($v.ReadAs)") { $bad += $k; continue }
        $okPc++
        $script:AuUsers[$k] = [pscustomobject]@{ Sid = "$($v.UserSid)"; Account = "$($v.UserAccount)" }
        if ("$($v.ReadAs)") { $readAs += "$($v.ReadAs)" }
        if (@($v.Sources).Count -and ((Test-HMIsLocal $k) -or -not @($script:AuSources).Count)) { $script:AuSources = @($v.Sources | Where-Object { $_ }) }
        foreach ($it in @($v.Items | Where-Object { $_ -and "$($_.Id)" })) {
            $ex = Find-HMAuExclusion $it $c.Exclude
            $unk = [bool]$it.Unknown
            $row = $dt.NewRow()
            $row.Sel = (-not $ex -and -not $unk)
            $row.PC = $k
            $row.Programm = "$($it.Name)"; $row.Installiert = "$($it.Installed)"; $row.Verfuegbar = "$($it.Available)"; $row.Quelle = "$($it.Source)"; $row.Paket = "$($it.Id)"
            $row.Excl = [bool]$ex
            $row.Scope = $(if ("$($it.Scope)" -eq 'User') { 'User' } else { 'Machine' }); $row.Unknown = $unk
            $row.Bereich = $(if ($row.Scope -eq 'User') { "nur $(("$($v.UserAccount)" -split '\\')[-1])" } else { 'alle Benutzer' })
            $row.Hinweis = $(if ($ex) { "Ausnahme ($($ex.Pattern)): $($ex.Reason)" } elseif ($unk) { 'Version unbekannt - Zuordnung unsicher' } else { '' })
            $dt.Rows.Add($row)
            if ($ex) { $x++ } else { $n++ }
        }
    }
    Update-HMAuSourceList
    $dt.DefaultView.Sort = 'PC ASC, Programm ASC'
    $script:AuDt = $dt
    $ui.dgAu.ItemsSource = $dt.DefaultView
    $ui.dgAu.Columns[1].Visibility = $(if ($keys.Count -gt 1) { 'Visible' } else { 'Collapsed' })
    $ra = @($readAs | Select-Object -Unique)
    $who = if ($keys.Count -eq 1 -and $ra.Count) { "  |  gelesen als $($ra[0])" } else { "  |  $okPc von $($keys.Count) PC(s) gelesen" }
    $ui.lblAuListTitle.Text = "VERFUEGBARE UPDATES - $n$(if ($x) { " (+ $x Ausnahme(n))" })$who  |  Stand $((Get-Date).ToString('HH:mm'))"
    if ($okPc) { Out-Console "App-Updates: $n Update(s) verfuegbar$(if ($x) { ", $x als Ausnahme ausgelassen" })$(if ($keys.Count -gt 1) { " auf $okPc PC(s)" })" $(if ($n) { 'Info' } else { 'Success' }) }
    if ($bad.Count) { Out-Console "App-Updates: nicht gelesen ($($bad.Count)): $($bad -join ', ') - Grund steht oben in der Konsole (nicht erreichbar / WinRM aus / PowerShell 7 oder WinGet-Modul fehlt)" $(if ($okPc) { 'Warning' } else { 'Error' }) }
}

# ----------------------------------------------------------------------------
# Aktualisieren
# ----------------------------------------------------------------------------
function Start-HMAuUpdate([switch]$All) {
    if ($script:JobRunning) { Out-Console 'Es laeuft bereits ein Vorgang.' 'Warning'; return }
    if (-not $script:AuDt -or -not $script:AuDt.Rows.Count) { Out-Console 'App-Updates: zuerst "Updates suchen".' 'Warning'; return }
    $ui.dgAu.CommitEdit(); $ui.dgAu.CommitEdit()
    $rows = @(foreach ($r in $script:AuDt.Rows) { if ($r.RowState -ne 'Deleted' -and ($All -or [bool]$r.Sel)) { $r } })
    $exRows = @($rows | Where-Object { [bool]$_.Excl })
    $rows = @($rows | Where-Object { -not [bool]$_.Excl })
    if ($exRows.Count -and -not $All) { Out-Console "App-Updates: $(@($exRows | ForEach-Object { $_.Programm } | Select-Object -Unique) -join ', ') - Ausnahme, wird nicht aktualisiert (Ausnahme zuerst entfernen)." 'Warning' }
    if (-not $rows.Count) { Out-Console 'App-Updates: nichts zu aktualisieren.' 'Warning'; return }
    $byPc = @{}; $noUser = @()
    foreach ($r in $rows) {
        $k = "$($r.PC)"
        $u = $script:AuUsers[$k]
        if ("$($r.Scope)" -eq 'User' -and -not ($u -and $u.Sid)) { $noUser += "$($r.Programm) ($k)"; continue }
        if (-not $byPc.ContainsKey($k)) { $byPc[$k] = @{ Items = @(); UserSid = $(if ($u) { "$($u.Sid)" } else { '' }); UserAccount = $(if ($u) { "$($u.Account)" } else { '' }) } }
        $byPc[$k].Items += [pscustomobject]@{ Id = "$($r.Paket)"; Name = "$($r.Programm)"; Source = "$($r.Quelle)"; Installed = "$($r.Installiert)"; Available = "$($r.Verfuegbar)"; Unknown = [bool]$r.Unknown; Scope = "$($r.Scope)" }
    }
    if ($noUser.Count) { Out-Console "App-Updates: ohne angemeldeten Benutzer nicht moeglich: $($noUser -join ', ')" 'Warning' }
    if (-not $byPc.Count) { return }
    $cnt = 0; foreach ($k in $byPc.Keys) { $cnt += $byPc[$k].Items.Count }
    $all2 = @(foreach ($k in @($byPc.Keys | Sort-Object)) { foreach ($i in $byPc[$k].Items) { "  $(if ($byPc.Count -gt 1) { "${k}: " })$($i.Name): $($i.Installed) -> $($i.Available)" } })
    $list = @($all2 | Select-Object -First 25) -join "`n"
    if ($all2.Count -gt 25) { $list += "`n  ... und $($all2.Count - 25) weitere" }
    $where = if ($byPc.Count -eq 1) { @($byPc.Keys)[0] } else { "$($byPc.Count) PCs" }
    if (-not (Confirm-Action "$cnt Programm(e) an $where still aktualisieren?`n`n$list`n`nLaufende Programme: an diesem PC wird vorher gefragt; an anderen PCs meldet der Installer sie (dann spaeter erneut)." 'App-Updates')) { return }
    $lk = "$env:COMPUTERNAME".ToUpper()
    $localItems = @(); if ($byPc.ContainsKey($lk)) { $localItems = @($byPc[$lk].Items) }
    $go = {
        param($byPc, $running, $dec)
        $ctx = @{ Op = 'Update'; ByPc = $byPc; Running = $running; ProcDecisions = $dec; Credential = $script:RemoteCred }
        Start-EngineJob -Command 'Start-HMAppUpdate -Ctx $Ctx -Job $Job' -Ctx $ctx -Title 'App-Updates' -ScriptFiles @($script:Engine, $script:AuEngine) -OnFinished {
            param($j)
            if ($j.Result -and $j.Result.Items) { Add-HMAuHistory @($j.Result.Items); Update-HMAuAfterRun @($j.Result.Items) }
            if ($j.Result -and $j.Result.Reboot) { Out-Console 'App-Updates: mindestens ein Programm braucht einen Neustart.' 'Warning' }
        }
    }
    if (-not $localItems.Count) { & $go $byPc @() @{}; return }
    Out-Console 'App-Updates: laufende Programme pruefen ...' 'Debug'
    Invoke-AsyncCommand -ScriptBlock {
        param($eng, $items)
        . $eng
        @(Get-HMAuRunning $items)
    } -ArgumentList @($script:AuEngine, $localItems) -TimeoutSec 60 -BusyTag 'Au' -BusyText 'Laufende Programme pruefen ...' -State @{ ByPc = $byPc; Go = $go } -OnComplete {
        param($r, $st)
        $running = @()
        if ($r -is [string]) { Out-Console "App-Updates: laufende Programme nicht pruefbar ($r) - Installer melden sich dann selbst" 'Warning' }
        else { $running = @(@($r) | Where-Object { $_ -and $_.Id }) }
        $dec = @{}
        if ($running.Count) {
            $dec = Show-HMProcDialog $running 'App-Update' $env:COMPUTERNAME -Options @(@('Close', 'Schliessen'), @('CloseForce', 'Schliessen, notfalls beenden'), @('Skip', 'Nicht aktualisieren'), @('Run', 'Trotzdem aktualisieren')) `
                -Note 'Schliessen = wie der Benutzer das Fenster schliesst (ungespeicherte Arbeit fragt das Programm selbst nach). Laesst sich das Programm in 20 s nicht schliessen, wird es nicht aktualisiert - ausser notfalls beenden ist gewaehlt. Trotzdem aktualisieren: der Installer kann fehlschlagen (Code 1603) oder das Programm selbst beenden.'
            if ($null -eq $dec) { Out-Console 'App-Updates abgebrochen (laufende Programme).' 'Warning'; return }
            foreach ($x in $running) { Out-Console ("   {0}: {1} -> {2}" -f $x.Name, $x.Running, $(switch ("$($dec[$x.Id])") { 'Close' { 'schliessen' } 'CloseForce' { 'schliessen, notfalls beenden' } 'Skip' { 'nicht aktualisieren' } default { 'trotzdem aktualisieren' } })) 'Info' }
        }
        & $st.Go $st.ByPc $running $dec
    }
}
# nach dem Lauf: erfolgreiche Zeilen aus der Liste nehmen, Fehler im Hinweis zeigen (kein neues Suchen noetig)
function Update-HMAuAfterRun($Items) {
    if (-not $script:AuDt) { return }
    foreach ($e in @($Items)) {
        foreach ($r in @($script:AuDt.Rows | Where-Object { $_.RowState -ne 'Deleted' -and "$($_.PC)" -eq "$($e.Computer)" -and "$($_.Paket)" -eq "$($e.Id)" })) {
            if ("$($e.Status)" -eq 'OK') { $r.Delete() } else { $r.Hinweis = "$(if ("$($e.Status)" -eq 'Skipped') { 'uebersprungen' } else { 'FEHLER' }): $($e.Text)"; $r.Sel = $false }
        }
    }
    $script:AuDt.AcceptChanges()
    $left = @($script:AuDt.Rows | Where-Object { -not [bool]$_.Excl }).Count
    $ui.lblAuListTitle.Text = "VERFUEGBARE UPDATES - $left offen  |  Stand $((Get-Date).ToString('HH:mm')) (nach Aktualisierung)"
}

# ----------------------------------------------------------------------------
# Zeitplan: Programme fuer alle Benutzer automatisch aktualisieren (geplante Aufgabe am Ziel-PC, als SYSTEM mit PowerShell 7)
# ----------------------------------------------------------------------------
$script:AuDays = @(@('Monday', 'Mo'), @('Tuesday', 'Di'), @('Wednesday', 'Mi'), @('Thursday', 'Do'), @('Friday', 'Fr'), @('Saturday', 'Sa'), @('Sunday', 'So'))
function Show-HMAuScheduleDialog([string]$Where) {
    $x = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="App-Updates - Zeitplan" Width="560" SizeToContent="Height" ResizeMode="NoResize" WindowStartupLocation="CenterOwner" Background="#FF1E1E2E">
  <StackPanel Margin="14">
    <TextBlock x:Name="info" Foreground="#FFCDD6F4" TextWrapping="Wrap" Margin="0,0,0,10"/>
    <StackPanel Orientation="Horizontal" Margin="0,0,0,6">
      <RadioButton x:Name="rDaily" Content="taeglich" Foreground="#FFCDD6F4" Margin="0,0,16,0"/>
      <RadioButton x:Name="rWeekly" Content="woechentlich an:" Foreground="#FFCDD6F4" IsChecked="True"/>
    </StackPanel>
    <WrapPanel x:Name="days" Margin="20,0,0,8"/>
    <StackPanel Orientation="Horizontal" Margin="0,0,0,6">
      <TextBlock Text="Uhrzeit (HH:mm):" Foreground="#FFA6ADC8" Width="120" VerticalAlignment="Center"/>
      <TextBox x:Name="time" Width="70" Text="12:30" Background="#FF313244" Foreground="#FFCDD6F4" CaretBrush="#FFCDD6F4" Padding="4,2"/>
    </StackPanel>
    <CheckBox x:Name="wake" Content="PC zum Termin aufwecken (Energiesparen) - verpasste Termine werden nachgeholt" Foreground="#FFCDD6F4" IsChecked="True" Margin="0,4,0,12"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
      <Button x:Name="ok" Content="Zeitplan anlegen" Width="140" Height="28" Background="#FFA6E3A1" Foreground="#FF1E1E2E" FontWeight="SemiBold" Margin="0,0,6,0" IsDefault="True"/>
      <Button x:Name="del" Content="Zeitplan entfernen" Width="140" Height="28" Background="#FFF38BA8" Foreground="#FF1E1E2E" Margin="0,0,6,0"/>
      <Button x:Name="cancel" Content="Abbrechen" Width="100" Height="28" Background="#FF45475A" Foreground="#FFCDD6F4" IsCancel="True"/>
    </StackPanel>
  </StackPanel>
</Window>
"@
    $w = [System.Windows.Markup.XamlReader]::Parse($x)
    if ($script:AppIcon) { $w.Icon = $script:AppIcon }
    $c = Get-HMAuConfig
    $w.FindName('info').Text = "Ziel: $Where`n`nAm Ziel-PC wird die geplante Aufgabe 'HUMig App-Updates' angelegt: sie aktualisiert als SYSTEM alle Programme fuer alle Benutzer (ohne Anmeldung). Programme nur fuer einen Benutzer bleiben aussen vor.`nQuellen: $($c.Sources -join ', ')  |  Ausnahmen des Standorts $($c.Location): $(@($c.Exclude).Count) (werden mitgegeben - nach Aenderungen Zeitplan neu anlegen).`nPowerShell 7 und das WinGet-Modul werden bei Bedarf installiert. Verlauf: 'Zeitplaene ansehen'."
    $pnl = $w.FindName('days')
    $boxes = @()
    foreach ($d in $script:AuDays) {
        $cb = New-Object System.Windows.Controls.CheckBox; $cb.Content = $d[1]; $cb.Tag = $d[0]; $cb.Foreground = New-Brush '#FFCDD6F4'; $cb.Margin = [System.Windows.Thickness]::new(0, 0, 10, 0)
        $cb.IsChecked = ($d[0] -eq 'Wednesday')
        [void]$pnl.Children.Add($cb); $boxes += $cb
    }
    $st = @{ W = $w; Res = $null }
    $w.FindName('ok').Add_Click({
            $t = "$($w.FindName('time').Text)".Trim()
            if ($t -notmatch '^([01]?\d|2[0-3]):[0-5]\d$') { [void][System.Windows.MessageBox]::Show($w, 'Uhrzeit als HH:mm, z.B. 12:30', 'Zeitplan', 'OK', 'Information'); return }
            $wk = [bool]$w.FindName('rWeekly').IsChecked
            $ds = @($boxes | Where-Object { $_.IsChecked } | ForEach-Object { "$($_.Tag)" })
            if ($wk -and -not $ds.Count) { [void][System.Windows.MessageBox]::Show($w, 'Mindestens einen Wochentag anhaken.', 'Zeitplan', 'OK', 'Information'); return }
            $st.Res = @{ Action = 'Set'; Mode = $(if ($wk) { 'Weekly' } else { 'Daily' }); Days = $ds; Time = ('{0:D2}:{1}' -f [int]($t.Split(':')[0]), $t.Split(':')[1]); Wake = [bool]$w.FindName('wake').IsChecked }
            $w.DialogResult = $true
        }.GetNewClosure())
    $w.FindName('del').Add_Click({ $st.Res = @{ Action = 'Remove' }; $w.DialogResult = $true }.GetNewClosure())
    $w.Owner = $script:Window; Set-HMWindowScale $w
    if ($w.ShowDialog() -ne $true) { return $null }
    return $st.Res
}
function Start-HMAuSchedule {
    if ($script:JobRunning) { Out-Console 'Es laeuft bereits ein Vorgang.' 'Warning'; return }
    Update-HMAuTargetLabel
    $pcs = @(Get-HMAuComputers)
    $where = if ($pcs.Count -eq 1) { $pcs[0] } else { "$($pcs.Count) PCs ($(@($pcs | Select-Object -First 4) -join ', ')$(if ($pcs.Count -gt 4) { ', ...' }))" }
    $d = Show-HMAuScheduleDialog $where
    if (-not $d) { return }
    $c = Get-HMAuConfig
    if ($d.Action -eq 'Remove') {
        if (-not (Confirm-Action "Zeitplan 'HUMig App-Updates' an $where entfernen?`nDer Verlauf am PC bleibt erhalten." 'App-Updates')) { return }
        $ctx = @{ Op = 'ScheduleRemove'; Computers = $pcs; Payload = @{}; Credential = $script:RemoteCred }
    } else {
        $txt = if ($d.Mode -eq 'Weekly') { "woechentlich ($(@($script:AuDays | Where-Object { $d.Days -contains $_[0] } | ForEach-Object { $_[1] }) -join ', ')) um $($d.Time)" } else { "taeglich um $($d.Time)" }
        if (-not (Confirm-Action "Zeitplan an $where anlegen: $txt$(if ($d.Wake) { ', PC wecken' })?`n`nAktualisiert als SYSTEM alle Programme fuer alle Benutzer aus $($c.Sources -join ', '), ausser den $(@($c.Exclude).Count) Ausnahme(n) des Standorts $($c.Location).`nEin bestehender Zeitplan wird ersetzt." 'App-Updates')) { return }
        $pl = @{ Mode = $d.Mode; Days = @($d.Days); Time = $d.Time; Wake = [bool]$d.Wake; Sources = @($c.Sources); Exclude = @($c.Exclude | ForEach-Object { @{ Pattern = "$($_.Pattern)"; Reason = "$($_.Reason)" } }); Location = "$($c.Location)"; By = "$env:USERDOMAIN\$env:USERNAME"; InstallPwsh = $true }
        $ctx = @{ Op = 'ScheduleSet'; Computers = $pcs; Payload = $pl; Credential = $script:RemoteCred }
    }
    Start-EngineJob -Command 'Start-HMAuScheduleJob -Ctx $Ctx -Job $Job' -Ctx $ctx -Title 'App-Updates Zeitplan' -ScriptFiles @($script:Engine, $script:AuEngine) -OnFinished { param($j) }
}
function Start-HMAuScheduleView {
    if ($script:JobRunning) { Out-Console 'Es laeuft bereits ein Vorgang.' 'Warning'; return }
    Update-HMAuTargetLabel
    $ctx = @{ Op = 'ScheduleGet'; Computers = @(Get-HMAuComputers); Payload = @{}; Credential = $script:RemoteCred }
    Start-EngineJob -Command 'Start-HMAuScheduleJob -Ctx $Ctx -Job $Job' -Ctx $ctx -Title 'App-Updates Zeitplaene' -ScriptFiles @($script:Engine, $script:AuEngine) -OnFinished {
        param($j)
        if (-not $j.Result -or -not $j.Result.ByPc) { return }
        $script:AuSchedData = $j.Result.ByPc
        $rows = New-Object System.Collections.ArrayList
        foreach ($k in @($j.Result.ByPc.Keys | Sort-Object)) {
            $v = $j.Result.ByPc[$k]
            if (-not $v.PSObject.Properties['Exists']) { [void]$rows.Add(@($k, '(nicht erreichbar)', '', '', '', '', (@($v.Errors) -join '; '))); continue }
            $lr = "$($v.LastResult)"
            $lrT = if (-not $v.Last) { '' } elseif ($lr -eq '0') { 'OK' } elseif ($lr -eq '267009') { 'laeuft' } else { "Code $lr" }
            [void]$rows.Add(@($k, $(if ($v.Exists) { "$($v.When)" } else { '(kein Zeitplan)' }), "$($v.Next)", "$($v.Last)", $lrT, "$($v.Summary)", "$(@($v.History).Count) Eintraege"))
        }
        Show-DataGridWindow -Title 'App-Updates - Zeitplaene' -Columns @('PC', 'Zeitplan', 'Naechster Lauf', 'Letzter Lauf', 'Ergebnis', 'Letzter Bericht', 'Verlauf') -Rows $rows.ToArray() -Sort 'PC ASC' -CountText "$($rows.Count) PC(s)" -Width 1100 -Height 520 -Actions @(
            @{ Text = 'Verlauf aller PCs uebernehmen'; Color = '#FF89B4FA'; NoSelection = $true; Handler = { param($rows, $win, $ctx) Import-HMAuScheduleHistory } }
            @{ Text = 'Markierte: Zeitplan entfernen'; Color = '#FFF38BA8'; Handler = {
                    param($rows, $win, $ctx)
                    $pcs = @($rows | ForEach-Object { "$($_.PC)" })
                    if (-not (Confirm-Action "Zeitplan an $($pcs -join ', ') entfernen? Der Verlauf am PC bleibt erhalten." 'App-Updates')) { return }
                    $win.Close()
                    Start-EngineJob -Command 'Start-HMAuScheduleJob -Ctx $Ctx -Job $Job' -Ctx @{ Op = 'ScheduleRemove'; Computers = $pcs; Payload = @{}; Credential = $script:RemoteCred } -Title 'App-Updates Zeitplan' -ScriptFiles @($script:Engine, $script:AuEngine) -OnFinished { param($j) }
                } }
        )
    }
}
# Verlauf der Zeitplan-Laeufe (am Ziel-PC) in den Verlauf hier uebernehmen - doppelte Eintraege werden ausgelassen
function Import-HMAuScheduleHistory {
    $have = @{}
    try { if (Test-Path -LiteralPath $script:AuHistFile) { foreach ($h in @(Get-Content -LiteralPath $script:AuHistFile -Raw -Encoding UTF8 | ConvertFrom-Json | ForEach-Object { $_ })) { $have["$($h.Date)|$($h.Computer)|$($h.Id)"] = $true } } } catch { }
    $new = @()
    foreach ($k in @($script:AuSchedData.Keys)) {
        foreach ($h in @($script:AuSchedData[$k].History | Where-Object { $_ -and "$($_.Id)" })) {
            $key = "$($h.Date)|$($h.Computer)|$($h.Id)"
            if ($have.ContainsKey($key)) { continue }
            $have[$key] = $true
            $new += [pscustomobject]@{ Date = "$($h.Date)"; Computer = "$($h.Computer)"; Id = "$($h.Id)"; Name = "$($h.Name)"; From = "$($h.From)"; To = "$($h.To)"; Source = "$($h.Source)"; Scope = 'Machine'; Status = "$($h.Status)"; Text = "$($h.Text)"; Reboot = [bool]$h.Reboot }
        }
    }
    if ($new.Count) { Add-HMAuHistory $new }
    Out-Console "App-Updates: $($new.Count) Eintrag/Eintraege aus Zeitplan-Laeufen uebernommen." $(if ($new.Count) { 'Success' } else { 'Info' })
}

# ----------------------------------------------------------------------------
# Fehlende Programme ueber WinGet installieren (aus "Programme neu installieren" nach dem Restore): $Items = Id, Name
# ----------------------------------------------------------------------------
function Start-HMAuInstall([string]$Computer, $Items) {
    if ($script:JobRunning) { Out-Console 'WinGet-Installation: es laeuft bereits ein Vorgang - spaeter erneut starten.' 'Warning'; return }
    $its = @($Items | Where-Object { $_ -and "$($_.Id)" })
    if (-not $its.Count) { return }
    $k = if (Test-HMIsLocal $Computer) { "$env:COMPUTERNAME".ToUpper() } else { "$Computer".Trim().ToUpper() }
    $byPc = @{ $k = @{ UserSid = ''; UserAccount = ''; Items = @($its | ForEach-Object { [pscustomobject]@{ Id = "$($_.Id)"; Name = "$($_.Name)"; Source = 'winget'; Installed = ''; Available = 'neu'; Unknown = $false; Scope = 'Machine' } }) } }
    $ctx = @{ Op = 'Install'; ByPc = $byPc; Running = @(); ProcDecisions = @{}; Credential = $script:RemoteCred }
    Start-EngineJob -Command 'Start-HMAppUpdate -Ctx $Ctx -Job $Job' -Ctx $ctx -Title 'WinGet installieren' -ScriptFiles @($script:Engine, $script:AuEngine) -OnFinished {
        param($j)
        if ($j.Result -and $j.Result.Items) { Add-HMAuHistory @($j.Result.Items) }
        if ($j.Result -and $j.Result.Reboot) { Out-Console 'WinGet: mindestens ein Programm braucht einen Neustart.' 'Warning' }
    }
}

# ----------------------------------------------------------------------------
# Ausnahmen / Quellen bearbeiten
# ----------------------------------------------------------------------------
function Show-HMAuInputDialog([string]$Title, [string]$Info, [string[]]$Labels, [string[]]$Values, [string[]]$Choices = @()) {
    $x = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$Title" Width="560" SizeToContent="Height" ResizeMode="NoResize" WindowStartupLocation="CenterOwner" Background="#FF1E1E2E">
  <StackPanel Margin="14">
    <TextBlock x:Name="info" Foreground="#FFCDD6F4" TextWrapping="Wrap" Margin="0,0,0,10"/>
    <StackPanel x:Name="rows" Margin="0,0,0,12"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
      <Button x:Name="ok" Content="OK" Width="100" Height="28" Background="#FFA6E3A1" Foreground="#FF1E1E2E" FontWeight="SemiBold" Margin="0,0,6,0" IsDefault="True"/>
      <Button x:Name="cancel" Content="Abbrechen" Width="100" Height="28" Background="#FF45475A" Foreground="#FFCDD6F4" IsCancel="True"/>
    </StackPanel>
  </StackPanel>
</Window>
"@
    $w = [System.Windows.Markup.XamlReader]::Parse($x)
    if ($script:AppIcon) { $w.Icon = $script:AppIcon }
    $w.FindName('info').Text = $Info
    $pnl = $w.FindName('rows')
    $boxes = @()
    for ($i = 0; $i -lt $Labels.Count; $i++) {
        $sp = New-Object System.Windows.Controls.StackPanel; $sp.Orientation = 'Horizontal'; $sp.Margin = [System.Windows.Thickness]::new(0, 2, 0, 2)
        $l = New-Object System.Windows.Controls.TextBlock; $l.Text = $Labels[$i]; $l.Width = 130; $l.Foreground = New-Brush '#FFA6ADC8'; $l.VerticalAlignment = 'Center'
        if ($i -eq $Labels.Count - 1 -and $Choices.Count) {
            $tb = New-Object System.Windows.Controls.ComboBox; $tb.Width = 380
            foreach ($c in $Choices) { [void]$tb.Items.Add($c) }
            $tb.SelectedIndex = [Math]::Max(0, [array]::IndexOf($Choices, "$($Values[$i])"))
        } else {
            $tb = New-Object System.Windows.Controls.TextBox; $tb.Width = 380; $tb.Text = "$($Values[$i])"; $tb.Padding = [System.Windows.Thickness]::new(4, 2, 4, 2)
            $tb.Background = New-Brush '#FF313244'; $tb.Foreground = New-Brush '#FFCDD6F4'; $tb.CaretBrush = New-Brush '#FFCDD6F4'
        }
        [void]$sp.Children.Add($l); [void]$sp.Children.Add($tb); [void]$pnl.Children.Add($sp)
        $boxes += $tb
    }
    $w.FindName('ok').Add_Click({ $w.DialogResult = $true }.GetNewClosure())
    $w.Owner = $script:Window; Set-HMWindowScale $w
    if ($w.ShowDialog() -ne $true) { return $null }
    return @($boxes | ForEach-Object { if ($_ -is [System.Windows.Controls.ComboBox]) { "$($_.SelectedItem)" } else { "$($_.Text)".Trim() } })
}
function Add-HMAuExclusionUi {
    $sel = @(@($ui.dgAu.SelectedItems) | Where-Object { $_ -and "$($_.Paket)" })
    $c = Get-HMAuConfig
    $pats = if ($sel.Count) { @($sel | ForEach-Object { "$($_.Paket)" }) } else { @('') }
    foreach ($p0 in $pats) {
        $v = Show-HMAuInputDialog 'Ausnahme' "Programme, die auf diesem Standort ($($c.Location)) NIE ueber App-Updates aktualisiert werden (z.B. Pruefungssoftware, gezielt verteilte Versionen).`nMuster mit Platzhalter * auf Paket-ID oder Programmname, z.B. Mozilla.Firefox* oder *Next-Exam*." @('Muster:', 'Grund:') @($p0, '')
        if (-not $v -or -not $v[0]) { continue }
        if (@($c.Exclude | Where-Object { $_.Pattern -eq $v[0] }).Count) { Out-Console "Ausnahme '$($v[0])' gibt es schon." 'Info'; continue }
        $c.Exclude = @($c.Exclude) + @([pscustomobject]@{ Pattern = $v[0]; Reason = $v[1] })
        Save-HMAuConfig $c.Sources $c.Exclude
        Out-Console "App-Updates: Ausnahme '$($v[0])' fuer Standort $($c.Location) eingetragen." 'Success'
    }
    Update-HMAuExclList
    if ($script:AuDt) { Start-HMAuSearch }
}
function Remove-HMAuExclusionUi {
    $sel = @(@($ui.lstAuExcl.SelectedItems) | ForEach-Object { $_.Tag } | Where-Object { $_ })
    if (-not $sel.Count) { Out-Console 'App-Updates: keine Ausnahme markiert.' 'Info'; return }
    if (-not (Confirm-Action "$(@($sel | ForEach-Object { $_.Pattern }) -join ', ') aus den Ausnahmen entfernen?`nDanach werden diese Programme wieder aktualisiert." 'App-Updates')) { return }
    $c = Get-HMAuConfig
    $pat = @($sel | ForEach-Object { $_.Pattern })
    Save-HMAuConfig $c.Sources @($c.Exclude | Where-Object { $pat -notcontains $_.Pattern })
    Update-HMAuExclList
    if ($script:AuDt) { Start-HMAuSearch }
}
function Add-HMAuSourceUi {
    $v = Show-HMAuInputDialog 'WinGet-Quelle hinzufuegen' "Eigene Quelle fuer diesen PC (braucht Administratorrechte). Nur vertrauenswuerdige Quellen verwenden - sie entscheiden, was installiert wird.`nREST-Quelle: https-Adresse (Typ Microsoft.Rest). Vorindizierte Quelle: Adresse oder Netzwerkpfad (Typ Microsoft.PreIndexed.Package)." @('Name:', 'Adresse / Pfad:', 'Typ:') @('', '', 'Microsoft.Rest') @('Microsoft.Rest', 'Microsoft.PreIndexed.Package')
    if (-not $v -or -not $v[0] -or -not $v[1]) { return }
    Invoke-AsyncCommand -ScriptBlock { param($eng, $n, $a, $t) . $eng; Add-HMAuSource $n $a $t; 'OK' } -ArgumentList @($script:AuEngine, $v[0], $v[1], $v[2]) -TimeoutSec 360 -BusyTag 'Au' -BusyText 'Quelle wird hinzugefuegt ...' -State @{ Name = $v[0] } -OnComplete {
        param($r, $st)
        if ("$r" -ne 'OK') { Out-Console "Quelle $($st.Name) nicht hinzugefuegt: $r" 'Error'; return }
        $c = Get-HMAuConfig
        Save-HMAuConfig (@($c.Sources) + @($st.Name) | Select-Object -Unique) $c.Exclude
        Out-Console "Quelle $($st.Name) hinzugefuegt und fuer Standort $($c.Location) angehakt." 'Success'
        Start-HMAuSearch
    }
}
function Remove-HMAuSourceUi([string]$Name) {
    if (-not $Name) { return }
    if (-not (Confirm-Action "Quelle '$Name' von diesem PC entfernen?$(if ($Name -in @('winget', 'msstore', 'winget-font')) { "`n`nACHTUNG: Standardquelle von WinGet - wiederherstellen mit: winget source reset --force" })" 'App-Updates')) { return }
    Invoke-AsyncCommand -ScriptBlock { param($eng, $n) . $eng; Remove-HMAuSource $n; 'OK' } -ArgumentList @($script:AuEngine, $Name) -TimeoutSec 360 -BusyTag 'Au' -State @{ Name = $Name } -OnComplete {
        param($r, $st)
        if ("$r" -ne 'OK') { Out-Console "Quelle $($st.Name) nicht entfernt: $r" 'Error'; return }
        Out-Console "Quelle $($st.Name) entfernt." 'Info'
        Start-HMAuSearch
    }
}

# ----------------------------------------------------------------------------
# Initialisierung
# ----------------------------------------------------------------------------
function Initialize-HMAppUpdatesTab {
    param([bool]$IsAdmin)
    $tab = $ui.tabAppUpdates
    if (-not $tab) { return }
    if ($script:UserMode -or -not $IsAdmin) { $tab.Visibility = 'Collapsed'; return }
    $script:AuButtons = @($ui.btnAuSearch, $ui.btnAuUpdateSel, $ui.btnAuUpdateAll, $ui.btnAuSetup, $ui.btnAuSourceAdd, $ui.btnAuExclAdd, $ui.btnAuExclDel, $ui.btnAuPcs, $ui.btnAuPcTop, $ui.btnAuSchedule, $ui.btnAuScheduleView)
    $ui.btnAuPcs.Add_Click({ Select-HMAuTargets })
    $ui.btnAuPcTop.Add_Click({ $script:AuTargets = @(); Update-HMAuTargetLabel; Clear-HMAuList })
    $ui.btnAuSchedule.Add_Click({ Start-HMAuSchedule })
    $ui.btnAuScheduleView.Add_Click({ Start-HMAuScheduleView })
    $cfg0 = Read-JsonFile $script:AuCfgFile
    $ui.chkAuUnknown.IsChecked = [bool]($cfg0 -and $cfg0.IncludeUnknown)
    $ui.btnAuSearch.Add_Click({ Start-HMAuSearch })
    $ui.btnAuUpdateSel.Add_Click({ Start-HMAuUpdate })
    $ui.btnAuUpdateAll.Add_Click({ Start-HMAuUpdate -All })
    $ui.btnAuCancel.Add_Click($cancelAction)
    $ui.btnAuSetup.Add_Click({ Start-HMAuSetup })
    $ui.btnAuExclAdd.Add_Click({ Add-HMAuExclusionUi })
    $ui.btnAuExclDel.Add_Click({ Remove-HMAuExclusionUi })
    $ui.btnAuSourceAdd.Add_Click({ Add-HMAuSourceUi })
    $ui.chkAuUnknown.Add_Click({ $c = Get-HMAuConfig; Save-HMAuConfig $c.Sources $c.Exclude; if ($script:AuDt) { Start-HMAuSearch } })
    $cm = New-Object System.Windows.Controls.ContextMenu
    $m1 = New-Object System.Windows.Controls.MenuItem; $m1.Header = 'Markierte als Ausnahme eintragen ...'; $m1.Add_Click({ Add-HMAuExclusionUi })
    $m2 = New-Object System.Windows.Controls.MenuItem; $m2.Header = 'Alle anhaken (ausser Ausnahmen)'; $m2.Add_Click({ if ($script:AuDt) { foreach ($r in $script:AuDt.Rows) { $r.Sel = -not [bool]$r.Excl } } })
    $m3 = New-Object System.Windows.Controls.MenuItem; $m3.Header = 'Alle abhaken'; $m3.Add_Click({ if ($script:AuDt) { foreach ($r in $script:AuDt.Rows) { $r.Sel = $false } } })
    foreach ($m in @($m1, (New-Object System.Windows.Controls.Separator), $m2, $m3)) { [void]$cm.Items.Add($m) }
    $ui.dgAu.ContextMenu = $cm
    # Daten erst beim ersten Oeffnen des Reiters laden
    $ui.tabMain.Add_SelectionChanged({
            param($s, $e)
            if ($e.OriginalSource -ne $ui.tabMain) { return }
            if ($ui.tabMain.SelectedItem -eq $ui.tabAppUpdates) {
                Update-HMAuExclList
                Update-HMAuTargetLabel
                if (-not $script:AuInit) { $script:AuInit = $true; Update-HMAuHistory; Update-HMAuState -Search }
            }
        })
}
