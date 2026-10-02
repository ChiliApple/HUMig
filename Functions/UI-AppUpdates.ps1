#Requires -Version 5.1
<#
.SYNOPSIS
    Reiter "App-Updates": installierte Programme ueber WinGet aktualisieren - Liste mit Haken, Ausnahmen und Quellen je Standort, Verlauf.
.NOTES
    Zielmaschine: dieser PC, HUMig als Administrator. Wird im UI-Thread geladen (dot-source aus HUMig.ps1).
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
$script:AuUser     = $null   # Benutzer der letzten Suche (Account, Sid)

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
    try { if (Test-Path -LiteralPath $script:AuHistFile) { $h = @(Get-Content -LiteralPath $script:AuHistFile -Raw -Encoding UTF8 | ConvertFrom-Json) } } catch { }
    $rows = @(@($h) | Where-Object { $_ } | Sort-Object Date -Descending | Select-Object -First 500 | ForEach-Object {
            $st = switch ("$($_.Status)") { 'OK' { 'OK' } 'Skipped' { 'uebersprungen' } default { 'FEHLER' } }
            [pscustomobject]@{ Datum = "$($_.Date)"; PC = "$($_.Computer)"; Programm = "$($_.Name)"; Version = "$($_.From) -> $($_.To)"; Ergebnis = "$st - $($_.Text)" }
        })
    $ui.dgAuHistory.ItemsSource = $rows
}
function Add-HMAuHistory($Entries) {
    $h = @()
    try { if (Test-Path -LiteralPath $script:AuHistFile) { $h = @(Get-Content -LiteralPath $script:AuHistFile -Raw -Encoding UTF8 | ConvertFrom-Json) } } catch { }
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
    foreach ($c in @(@('Sel', [bool]), @('Programm', [string]), @('Installiert', [string]), @('Verfuegbar', [string]), @('Quelle', [string]), @('Paket', [string]), @('Hinweis', [string]), @('Excl', [bool]), @('Bereich', [string]), @('Scope', [string]), @('Unknown', [bool]))) { [void]$dt.Columns.Add($c[0], $c[1]) }
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
        $ui.lblAuInfo.Text = $(if ($s.Ready) { "WinGet $($s.WinGet)  |  Modul Microsoft.WinGet.Client $($s.Module)  |  App Installer $($s.AppInstaller)  |  Gelesen wird als SYSTEM (Programme fuer alle Benutzer) und im Konto des oben gewaehlten Benutzers (nur fuer ihn installierte - er muss angemeldet sein)." } else { "$($s.Problem)" })
        foreach ($b in @($ui.btnAuSearch, $ui.btnAuUpdateSel, $ui.btnAuUpdateAll, $ui.btnAuSourceAdd)) { $b.IsEnabled = [bool]$s.Ready -and -not $script:JobRunning }
        Update-HMAuSourceList
        if ($s.Ready -and $stt.Search) { Start-HMAuSearch }
        elseif (-not $s.Ready) { Out-Console "App-Updates: $($s.Problem)" 'Warning' }
    }
}
function Start-HMAuSetup {
    if ($script:JobRunning) { Out-Console 'Es laeuft bereits ein Vorgang.' 'Warning'; return }
    if (-not (Confirm-Action "WinGet einrichten?`n`n- Modul Microsoft.WinGet.Client aus der PowerShell Gallery installieren (fuer alle Benutzer)`n- WinGet (App Installer) fuer dieses Konto registrieren bzw. reparieren`n`nInternet noetig (www.powershellgallery.com, github.com)." 'App-Updates')) { return }
    Start-EngineJob -Command 'Install-HMAuWinGet $Job | Out-Null' -Ctx @{ Kind = 'Setup' } -Title 'WinGet einrichten' -ScriptFiles @($script:Engine, $script:AuEngine) -OnFinished { param($j) Update-HMAuState -Search }
}

# ----------------------------------------------------------------------------
# Suchen
# ----------------------------------------------------------------------------
function Start-HMAuSearch {
    if (-not $script:AuReady) { Update-HMAuState -Search; return }
    $c = Get-HMAuConfig
    if (-not $c.Sources.Count) { Out-Console 'App-Updates: keine Quelle angehakt.' 'Warning'; return }
    if (-not (Test-HMIsLocal (Get-TargetComputer))) { Out-Console "App-Updates: derzeit nur fuer diesen PC ($env:COMPUTERNAME) - gewaehlt ist $(Get-TargetComputer)." 'Warning'; return }
    $p = Get-SelectedProfile
    $acct = ''; $sid = ''
    if ($p -and $p.SID -and -not $p.NoProfile) { $acct = "$($p.Account)"; $sid = "$($p.SID)" }
    $script:AuUser = [pscustomobject]@{ Account = $acct; Sid = $sid }
    $ui.lblAuListTitle.Text = "VERFUEGBARE UPDATES - wird gesucht (SYSTEM$(if ($acct) { " + $acct" })) ..."
    Invoke-AsyncCommand -ScriptBlock {
        param($eng, $src, $unk, $acct, $sid)
        . $eng
        Get-HMAuUpdates $src $unk $acct $sid
    } -ArgumentList @($script:AuEngine, [string[]]$c.Sources, [bool]$ui.chkAuUnknown.IsChecked, $acct, $sid) -TimeoutSec 1300 -BusyTag 'Au' -BusyText 'Updates werden gesucht ...' -OnComplete {
        param($r)
        if (-not $r -or $r -is [string]) { $ui.lblAuListTitle.Text = 'VERFUEGBARE UPDATES'; Out-Console "App-Updates: Suche fehlgeschlagen - $r" 'Error'; return }
        foreach ($e in @($r.Errors)) { Out-Console "App-Updates: $e" 'Warning' }
        if (@($r.Sources).Count) { $script:AuSources = @($r.Sources); Update-HMAuSourceList }
        $u = $script:AuUser
        if ($u -and $u.Account -and -not $r.LoggedOn) { Out-Console "App-Updates: $($u.Account) ist nicht angemeldet - nur Programme fuer alle Benutzer gelesen. Fuer seine eigenen Programme muss er angemeldet sein." 'Warning'; $script:AuUser = [pscustomobject]@{ Account = ''; Sid = '' } }
        elseif (-not ($u -and $u.Account)) { Out-Console 'App-Updates: kein Benutzer gewaehlt - nur Programme fuer alle Benutzer gelesen.' 'Info' }
        if (-not $r.SysOk) { Out-Console 'App-Updates: Lesen als SYSTEM fehlgeschlagen - Bereich unsicher, alle als Benutzer-Programme behandelt.' 'Warning' }
        $c = Get-HMAuConfig
        $dt = New-HMAuTable
        $n = 0; $x = 0
        foreach ($it in @($r.Items | Where-Object { $_ })) {
            $ex = Find-HMAuExclusion $it $c.Exclude
            $row = $dt.NewRow()
            $row.Sel = (-not $ex -and -not $it.Unknown)
            $row.Programm = "$($it.Name)"; $row.Installiert = "$($it.Installed)"; $row.Verfuegbar = "$($it.Available)"; $row.Quelle = "$($it.Source)"; $row.Paket = "$($it.Id)"
            $row.Excl = [bool]$ex
            $row.Scope = "$($it.Scope)"; $row.Unknown = [bool]$it.Unknown
            $row.Bereich = $(if ("$($it.Scope)" -eq 'User') { "nur $(("$($script:AuUser.Account)" -split '\\')[-1])" } else { 'alle Benutzer' })
            $row.Hinweis = $(if ($ex) { "Ausnahme ($($ex.Pattern)): $($ex.Reason)" } elseif ($it.Unknown) { 'Version unbekannt - Zuordnung unsicher' } else { '' })
            $dt.Rows.Add($row)
            if ($ex) { $x++ } else { $n++ }
        }
        $script:AuDt = $dt
        $ui.dgAu.ItemsSource = $dt.DefaultView
        $ui.lblAuListTitle.Text = "VERFUEGBARE UPDATES - $n$(if ($x) { " (+ $x Ausnahme(n))" })  |  gelesen als SYSTEM$(if ($r.UserRead) { " + $($script:AuUser.Account)" })  |  Stand $((Get-Date).ToString('HH:mm'))"
        Out-Console "App-Updates: $n Update(s) verfuegbar$(if ($x) { ", $x als Ausnahme ausgelassen" })" $(if ($n) { 'Info' } else { 'Success' })
    }
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
    if ($exRows.Count -and -not $All) { Out-Console "App-Updates: $(@($exRows | ForEach-Object { $_.Programm }) -join ', ') - Ausnahme, wird nicht aktualisiert (Ausnahme zuerst entfernen)." 'Warning' }
    if (-not $rows.Count) { Out-Console 'App-Updates: nichts zu aktualisieren.' 'Warning'; return }
    $items = @($rows | ForEach-Object { [pscustomobject]@{ Id = "$($_.Paket)"; Name = "$($_.Programm)"; Source = "$($_.Quelle)"; Installed = "$($_.Installiert)"; Available = "$($_.Verfuegbar)"; Unknown = [bool]$_.Unknown; Scope = "$($_.Scope)" } })
    $uAcct = if ($script:AuUser) { "$($script:AuUser.Account)" } else { '' }
    if (@($items | Where-Object { $_.Scope -eq 'User' }).Count -and -not $uAcct) { Out-Console 'App-Updates: Programme "nur Benutzer" brauchen einen angemeldeten Benutzer - neu suchen.' 'Warning'; return }
    $list = @($items | Select-Object -First 25 | ForEach-Object { "  $($_.Name): $($_.Installed) -> $($_.Available)" }) -join "`n"
    if ($items.Count -gt 25) { $list += "`n  ... und $($items.Count - 25) weitere" }
    if (-not (Confirm-Action "$($items.Count) Programm(e) an $env:COMPUTERNAME still aktualisieren?`n`n$list`n`nLaufende Programme werden vorher erkannt (Schliessen wird angeboten)." 'App-Updates')) { return }
    Out-Console 'App-Updates: laufende Programme pruefen ...' 'Debug'
    Invoke-AsyncCommand -ScriptBlock {
        param($eng, $items)
        . $eng
        @(Get-HMAuRunning $items)
    } -ArgumentList @($script:AuEngine, $items) -TimeoutSec 60 -BusyTag 'Au' -BusyText 'Laufende Programme pruefen ...' -State @{ Items = $items } -OnComplete {
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
        $ctx = @{ Items = @($st.Items); Running = $running; ProcDecisions = $dec; UserAccount = $(if ($script:AuUser) { "$($script:AuUser.Account)" } else { '' }); UserSid = $(if ($script:AuUser) { "$($script:AuUser.Sid)" } else { '' }) }
        Start-EngineJob -Command 'Start-HMAppUpdate -Ctx $Ctx -Job $Job' -Ctx $ctx -Title 'App-Updates' -ScriptFiles @($script:Engine, $script:AuEngine) -OnFinished {
            param($j)
            if ($j.Result -and $j.Result.Items) { Add-HMAuHistory @($j.Result.Items) }
            if ($j.Result -and $j.Result.Reboot) { Out-Console 'App-Updates: mindestens ein Programm braucht einen Neustart.' 'Warning' }
            Start-HMAuSearch
        }
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
    $script:AuButtons = @($ui.btnAuSearch, $ui.btnAuUpdateSel, $ui.btnAuUpdateAll, $ui.btnAuSetup, $ui.btnAuSourceAdd, $ui.btnAuExclAdd, $ui.btnAuExclDel)
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
    $ui.chkAuUnknown.Add_Click({ $c = Get-HMAuConfig; Save-HMAuConfig $c.Sources $c.Exclude; if ($script:AuReady) { Start-HMAuSearch } })
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
                if (-not $script:AuInit) { $script:AuInit = $true; Update-HMAuHistory; Update-HMAuState -Search }
            }
        })
}
