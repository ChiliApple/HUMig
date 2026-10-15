#Requires -Version 5.1
<#
.SYNOPSIS
    Programm-Katalog: erkennt installierte Programme am gewaehlten PC, blendet passende Module ein und hakt sie an,
    zeigt was uebertragbar ist (Einstellungen, Lizenzen, Nacharbeiten) und installiert fehlende Programme am neuen PC
    aus der Softwareverteilung nach (Bare-Metal).
.NOTES
    Wird im UI-Thread geladen (dot-source aus HUMig.ps1). Katalog: Config\apps.default.json + Config\apps.json (eigene Eintraege).
#>

$script:AppCatalog = @()
$script:DetectedApps = @()
$script:DetectedModuleIds = @()
$script:DetectedFor = ''

# ----------------------------------------------------------------------------
# Katalog laden und Module fuer Programme mit eigenen Eintraegen (Items) anlegen
# (Aufruf aus Import-AppConfig, VOR dem Uebernehmen der Modul-Overrides)
# ----------------------------------------------------------------------------
function Import-HMAppCatalog([System.Collections.Generic.List[object]]$Mods) {
    $def = Read-JsonFile (Join-Path $script:ConfigDir 'apps.default.json')
    $loc = Read-JsonFile (Join-Path $script:ConfigDir 'apps.json')
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($a in @($def.Apps)) { if ($a -and $a.Id) { $list.Add($a) } }
    foreach ($a in @($loc.Apps)) {
        if (-not $a -or -not $a.Id) { continue }
        $idx = -1
        for ($i = 0; $i -lt $list.Count; $i++) { if ($list[$i].Id -eq $a.Id) { $idx = $i; break } }
        if ($idx -ge 0) { $list[$idx] = $a } else { $list.Add($a) }
    }
    $script:AppCatalog = @($list.ToArray() | Sort-Object { "$($_.Name)" })   # alphabetisch (Liste Programme, Erkennung, Konsole)
    foreach ($a in $script:AppCatalog) {
        $cp = @(@($a.CloseProcess) | Where-Object { "$_".Trim() } | ForEach-Object { "$_".Trim() -replace '\.exe$', '' })
        $ss = @(@($a.StopService) | Where-Object { "$_".Trim() } | ForEach-Object { "$_".Trim() })
        # Eintraege, die auf vorhandene Module verweisen (z.B. Firefox): Schliessen/Dienste dort ergaenzen
        if ($cp.Count -or $ss.Count) {
            foreach ($mid in @($a.Modules | Where-Object { $_ })) {
                foreach ($m in $Mods) {
                    if ("$($m.Id)" -ne "$mid") { continue }
                    $m | Add-Member -NotePropertyName CloseProcess -NotePropertyValue @(@($m.CloseProcess) + $cp | Where-Object { $_ } | Select-Object -Unique) -Force
                    $m | Add-Member -NotePropertyName StopService -NotePropertyValue @(@($m.StopService) + $ss | Where-Object { $_ } | Select-Object -Unique) -Force
                }
            }
        }
        if (-not @($a.Items | Where-Object { $_ }).Count) { continue }
        $exists = $false
        foreach ($m in $Mods) { if ($m.Id -eq $a.Id) { $exists = $true; break } }
        if ($exists) { continue }
        $user = @($a.Items | Where-Object { ($_.Path -match '^\{(PROFILE|APPDATA|LOCALAPPDATA)\}') -or ($_.Key -match '^HK(CU|EY_CURRENT_USER)') }).Count -gt 0
        $lic = @($a.Items | Where-Object { $_ -and $_.License }).Count
        $trial = Test-HMAppTrial $a
        $hint = "$($a.Name): $($a.Transfer)" + $(if ($a.License) { "`nLizenz: $($a.License)" } else { '' }) + $(if ($lic) { "`nLIZENZDATEI wird mitgesichert - am neuen PC gleich lizenziert" } else { '' }) + $(if ($trial) { "`nACHTUNG: $script:HMAppTrialText" } else { '' }) + "`n(Programm-Katalog - wird eingeblendet, wenn das Programm installiert ist)"
        $Mods.Add([pscustomobject]@{ Id = "$($a.Id)"; Name = "$($a.Name)$(if ($lic) { ' (+ Lizenz)' })$(if ($trial) { ' (ungeprueft)' })"; Group = 'Programme'; Default = $false; Show = $false; Catalog = $true
            Scope = $(if ($user) { 'User' } else { 'Machine' }); Remote = $true; Hint = $hint; Items = @($a.Items)
            CloseProcess = $cp; StopService = $ss; AppId = "$($a.Id)" })
    }
}

# Katalog-Eintrag nur testweise: kopiert Dateien/Registry, ist aber noch an keinem PC bestaetigt (Verified.Date leer)
function Test-HMAppTrial($App) {
    if (-not $App -or -not @($App.Items | Where-Object { $_ }).Count) { return $false }
    return -not ($App.Verified -and "$($App.Verified.Date)".Trim())
}
$script:HMAppTrialText = 'ungeprueft - nur testweise im Katalog: nach dem Umzug Programm testen und Rueckmeldung geben (gelber Knopf Rueckmeldung im Reiter Backup bzw. Restore)'

# Module eines Katalog-Eintrags (eigene Items -> Modul mit Id des Eintrags, sonst "Modules")
function Get-HMAppModuleIds($App) {
    $ids = @()
    if (@($App.Items | Where-Object { $_ }).Count) { $ids += "$($App.Id)" }
    $ids += @($App.Modules | Where-Object { $_ })
    return @($ids | Select-Object -Unique)
}

# Software-Liste am Ziel (asynchron). OnDone: param($software, $state) - $software = $null bei Fehler
function Get-HMSoftwareAsync([string]$Computer, [string]$Sid, [scriptblock]$OnDone, $State = $null) {
    Invoke-AsyncCommand -ScriptBlock {
        param($h, $cred, $text, $sid)
        $sb = [scriptblock]::Create($text)
        $isLocal = ($h -eq '.' -or $h -ieq 'localhost' -or $h -ieq $env:COMPUTERNAME -or $h -ilike "$($env:COMPUTERNAME).*")
        try {
            $r = if ($isLocal) { & $sb $sid } else {
                $p = @{ ComputerName = $h; ScriptBlock = $sb; ArgumentList = @($sid); ErrorAction = 'Stop' }
                if ($cred) { $p.Credential = $cred }
                Invoke-Command @p
            }
            @($r | ForEach-Object { "SW:$($_.Name)|$($_.Version)|$($_.Publisher)|$($_.Scope)" -replace "[\r\n]", ' ' })
        } catch { "FEHLER: $($_.Exception.Message)" }
    } -ArgumentList @($Computer, $script:RemoteCred, $script:HMSoftwareScript.ToString(), $Sid) -TimeoutSec 120 -State @{ On = $OnDone; State = $State; Computer = $Computer } -OnComplete {
        param($r, $st)
        $lines = @($r)
        if ($lines.Count -eq 1 -and "$($lines[0])" -match '^FEHLER: ') { & $st.On $null $st; return }
        $sw = @(foreach ($l in $lines) {
            if ("$l" -notmatch '^SW:(.*)$') { continue }
            $p = $Matches[1].Split('|')
            [pscustomobject]@{ Name = $p[0]; Version = $(if ($p.Count -gt 1) { $p[1] }); Publisher = $(if ($p.Count -gt 2) { $p[2] }); Scope = $(if ($p.Count -gt 3) { $p[3] }) }
        })
        & $st.On $sw $st
    }
}

# ----------------------------------------------------------------------------
# Erkennung am gewaehlten PC -> Module einblenden/anhaken
# ----------------------------------------------------------------------------
function Start-HMAppDetect([switch]$Show) {
    $comp = Get-TargetComputer
    $p = Get-SelectedProfile
    $sid = if ($p -and -not $p.NoProfile) { $p.SID } else { '' }
    if (-not $script:AppCatalog.Count) { if ($Show) { Out-Console 'Programm-Katalog leer (Config\apps.default.json fehlt?)' 'Warning' }; return }
    $script:AppDetectShow = [bool]$Show
    if ($Show) { Out-Console "Programme erkennen - $comp ..." 'Info' }
    Get-HMSoftwareAsync -Computer $comp -Sid $sid -State @{ Key = "$comp|$sid" } -OnDone {
        param($sw, $st)
        if ($null -eq $sw) { if ($script:AppDetectShow) { Out-Console "Programm-Erkennung: $($st.Computer) nicht erreichbar" 'Warning' }; return }
        if ((Get-TargetComputer) -ne $st.Computer) { return }   # inzwischen anderer PC gewaehlt
        $found = @(Find-HMCatalogApps $sw $script:AppCatalog)
        $script:DetectedApps = $found
        $script:DetectedSoftware = $sw
        $script:DetectedFor = $st.State.Key
        $ids = @(); foreach ($f in $found) { $a = @($script:AppCatalog | Where-Object { $_.Id -eq $f.Id })[0]; if ($a) { $ids += Get-HMAppModuleIds $a } }
        $ids = @($ids | Select-Object -Unique)
        $newOnes = @($ids | Where-Object { $script:DetectedModuleIds -notcontains $_ })
        $gone = @(@($script:DetectedModuleIds) | Where-Object { $ids -notcontains $_ })
        $script:DetectedModuleIds = $ids
        # Neu erkannte Programme nur anhaken, wenn die gewaehlte Vorlage sie enthaelt (Komplett = alle, eigene Vorlage = gespeicherte);
        # Standard enthaelt keine Programme - dann von Hand anhaken
        $pre = $null; try { $pre = Get-HMPreset "$($ui.cmbPreset.SelectedItem)" } catch { }
        $preMods = @(if ($pre) { @($pre.Modules) })
        $auto = @($newOnes | Where-Object { $_ -like 'App_*' -and (($preMods -contains '*') -or ($preMods -contains $_)) })
        if ($newOnes.Count -or $gone.Count) { Update-BackupPanelKeepChecks -Check $auto }
        if ($found.Count) {
            $tr = @{}; foreach ($a in $script:AppCatalog) { if (Test-HMAppTrial $a) { $tr[$a.Id] = $true } }
            Out-Console ("Programme erkannt ({0}): {1}" -f $found.Count, (@($found | ForEach-Object { "$($_.Name)$(if ($tr[$_.Id]) { '*' })" }) -join ', ')) 'Info'
            if (@($found | Where-Object { $tr[$_.Id] }).Count) { Out-Console "   * = $script:HMAppTrialText" 'Warning' }
            if ($auto.Count) { Out-Console "   Einstellungen von $($auto.Count) Programm(en) werden laut Vorlage mitgesichert (Gruppe PROGRAMME, abwaehlbar) - Details: Knopf 'Programme'" 'Info' }
            elseif (@($newOnes | Where-Object { $_ -like 'App_*' }).Count) { Out-Console "   Zum Mitsichern in der Gruppe PROGRAMME anhaken (Vorlage Komplett hakt alle an) - Details: Knopf 'Programme'" 'Info' }
        } elseif ($script:AppDetectShow) { Out-Console 'Keine Programme aus dem Katalog gefunden.' 'Info' }
        if ($script:AppDetectShow) { Show-HMAppCatalog }
    }
}

# Backup-Modulliste neu aufbauen (eingeblendete Katalog-Module), Haken behalten
function Update-BackupPanelKeepChecks([string[]]$Check = @()) {
    $keep = @{}
    foreach ($k in $script:BackupChecks.Keys) { $keep[$k] = [bool]$script:BackupChecks[$k].IsChecked }
    Build-ModulePanel $ui.pnlBackupModules $script:BackupChecks -Extra $script:DetectedModuleIds
    foreach ($k in @($script:BackupChecks.Keys)) {
        if ($keep.ContainsKey($k)) { $script:BackupChecks[$k].IsChecked = $keep[$k] }
        if ($Check -contains $k) { $script:BackupChecks[$k].IsChecked = $true }
    }
    Show-ModuleSizes
    Update-SizeTotal
}

# ----------------------------------------------------------------------------
# Uebersicht: erkannte Programme (oder ganzer Katalog)
# ----------------------------------------------------------------------------
function Show-HMAppCatalog {
    $rows = New-Object System.Collections.Generic.List[object]
    $det = @{}; foreach ($d in @($script:DetectedApps)) { $det[$d.Id] = $d }
    $pk = @(); try { $pk = @(Get-SwPackages) } catch { }
    $stats = @{}; try { $stats = Read-HMCatalogStats (Get-BackupRoot) } catch { }
    foreach ($a in $script:AppCatalog) {
        $d = $det[$a.Id]
        $mods = @(Get-HMAppModuleIds $a | ForEach-Object { $id = $_; $m = @($script:Modules | Where-Object { $_.Id -eq $id })[0]; if ($m) { $m.Name } })
        $pkg = Find-HMAppPackage $a $pk
        $licItems = @($a.Items | Where-Object { $_ -and $_.License } | ForEach-Object { if ($_.Filter) { @($_.Filter) -join ',' } elseif ($_.Key) { "$($_.Key)" } else { Split-Path "$($_.Path)" -Leaf } } | Select-Object -Unique)
        $db = @($a.Items | Where-Object { $_ -and "$($_.Role)" -eq 'Database' } | ForEach-Object { if ("$($_.DbKind)" -eq 'Service') { 'Dienst' } else { 'Datei' } } | Select-Object -Unique)
        $ver = if ($a.Verified -and "$($a.Verified.Date)") { "$($a.Verified.Date)" } elseif (Test-HMAppTrial $a) { 'nein - testweise' } else { 'nein (nur Hinweis/Modul)' }
        $rows.Add(@($(if ($d) { 'installiert' } else { '-' }), "$($a.Name)", $(if ($d) { "$($d.Version)" } else { '' }), "$($a.Transfer)", "$($a.NotTransfer)", $(if ($licItems.Count) { "JA: $($licItems -join ', ')" } else { 'nein' }), "$($a.License)", ($db -join ', '), (@(@($a.CloseProcess) | Where-Object { $_ }) -join ', '), ($mods -join ', '), $(if ($pkg) { "$($pkg.Id)" } else { '' }), ((@($a.After) | Where-Object { $_ }) -join ' | '), $ver, $(if ($stats.ContainsKey("$($a.Id)")) { (Get-HMCatalogStatsSummary $stats["$($a.Id)"]).Text } else { '' }), "$($a.Id)"))
    }
    $n = @($script:DetectedApps).Count
    Show-DataGridWindow -Title "Programm-Katalog - $(Get-TargetComputer)" -Columns @('Status', 'Programm', 'Version', 'Uebertragbar', 'Nicht_uebertragbar', 'Lizenz uebertragen', 'Lizenz-Hinweis', 'DB', 'Schliessen', 'Modul', 'Paket', 'Nacharbeit', 'Geprueft', 'Praxis (Backups)', 'Id') -Rows $rows.ToArray() `
        -Sort 'Status DESC, Programm ASC' -CountText "$n von $($rows.Count) Katalog-Programmen installiert - eigene Eintraege: Config\apps.json" -Width 1600 -Height 640 `
        -Actions @(
            @{ Text = '+ Programm hinzufuegen ...'; Color = '#FFA6E3A1'; NoSelection = $true; Handler = { param($sel, $w, $c) Start-HMAppWizard } }
            @{ Text = 'Katalog bearbeiten ...'; Color = '#FFCBA6F7'; NoSelection = $true; Handler = { param($sel, $w, $c) $id = if (@($sel).Count) { "$(@($sel)[0].Id)" } else { '' }; Show-HMAppEditor -SelectId $id } }
            @{ Text = 'Rueckmeldung geben ...'; Color = '#FFF9E2AF'; NoSelection = $true; Handler = { param($sel, $w, $c) Start-HMAppFeedback -Rows @($sel) } }
            @{ Text = 'Katalog-Statistik ...'; Color = '#FF94E2D5'; NoSelection = $true; Handler = { param($sel, $w, $c) Show-HMCatalogStats } }
        )
}

# Rueckmeldung zu Katalog-Eintraegen: GitHub-Issue im Browser oder (wenn in den Einstellungen eine Adresse steht) E-Mail
# ueber das Mailprogramm - vorausgefuellt, es wird nichts automatisch gesendet.
#   -Rows: markierte Zeilen im Fenster Programme | -Source Detected: erkannte Programme am PC | -Source Backup: Programme des markierten Backups
function Start-HMAppFeedback([object[]]$Rows = @(), [ValidateSet('', 'Detected', 'Backup')][string]$Source = '') {
    $apps = @()
    if (@($Rows | Where-Object { $_ }).Count) {
        $apps = @(foreach ($r in $Rows) { $a = @($script:AppCatalog | Where-Object { $_.Id -eq "$($r.Id)" })[0]; if ($a) { $a } })
    } else {
        $ids = @()
        if ($Source -eq 'Backup') {
            $b = $script:SelectedBackup
            if (-not $b -or -not $b.Manifest -or -not @($b.Manifest.Apps).Count) { Out-Console 'Rueckmeldung: im Reiter Restore zuerst ein Backup markieren (Programme aus dem Katalog stehen im Backup).' 'Warning'; return }
            $ids = @($b.Manifest.Apps | ForEach-Object { "$($_.Id)" })
        } else {
            if (-not @($script:DetectedApps).Count) { Out-Console "Rueckmeldung: zuerst Knopf 'Programme' (erkennt die installierten Programme)." 'Warning'; return }
            $ids = @($script:DetectedApps | ForEach-Object { "$($_.Id)" })
        }
        $apps = @($script:AppCatalog | Where-Object { $ids -contains $_.Id -and (Test-HMAppTrial $_) })
        if (-not $apps.Count) { Out-Console 'Rueckmeldung: keine ungeprueften Katalog-Eintraege dabei - danke, nichts zu melden. Einzelne Eintraege: Knopf Programme > Zeile markieren > Rueckmeldung geben.' 'Info'; return }
    }
    $title = if ($apps.Count -eq 1) { "Katalog: $($apps[0].Name) ($($apps[0].Id))" } elseif ($apps.Count) { "Katalog: $($apps.Count) Programme" } else { 'Katalog: Rueckmeldung' }
    $stats = @{}; try { $stats = Read-HMCatalogStats (Get-BackupRoot) } catch { }
    $lines = @(foreach ($a in $apps) { $st = if ($stats.ContainsKey("$($a.Id)")) { " [Backups: $((Get-HMCatalogStatsSummary $stats["$($a.Id)"]).Text)]" } else { '' }; "- $($a.Name) ($($a.Id))$($st): passt / fehlte: ... / falscher Pfad: ..." })
    $body = "HUMig-Version: $script:Version`nWindows: $([Environment]::OSVersion.Version)`n`nErgebnis nach dem Umzug je Programm (Zutreffendes stehen lassen):`n$(if ($lines.Count) { $lines -join "`n" } else { '- (Programm eintragen)' })`n`nBemerkungen:`n`n(bitte keine Kennwoerter, Benutzernamen oder Pfade mit Personennamen eintragen)"
    $mail = "$($script:Settings.FeedbackMail)".Trim()
    $how = 'GitHub'
    if ($mail) {
        $m = "Rueckmeldung zu $($apps.Count) Programm(en) senden:`n`nJa = E-Mail an $mail (Mailprogramm, ohne Konto)`nNein = GitHub-Issue im Browser (GitHub-Konto noetig)`nAbbrechen = nichts tun`n`nDer Text ist vorausgefuellt - vor dem Senden ergaenzen. Es wird nichts automatisch gesendet."
        $r = "$([System.Windows.MessageBox]::Show($script:Window, $m, 'HUMig - Rueckmeldung', 'YesNoCancel', 'Question', 'Yes'))"
        if ($r -eq 'Cancel') { return }
        $how = if ($r -eq 'Yes') { 'Mail' } else { 'GitHub' }
    }
    try {
        if ($how -eq 'Mail') {
            $mb = $body
            if ($mb.Length -gt 1500) { $mb = $mb.Substring(0, 1500) + "`n... (gekuerzt)" }   # mailto-Links sind in der Laenge begrenzt
            Start-Process -FilePath ("mailto:{0}?subject={1}&body={2}" -f $mail, [uri]::EscapeDataString("HUMig $title"), [uri]::EscapeDataString(($mb -replace "`r?`n", "`r`n")))
            Out-Console "Rueckmeldung: E-Mail an $mail im Mailprogramm geoeffnet - bitte ergaenzen und senden." 'Info'
        } else {
            $base = "https://github.com/$($script:UpdateOwner)/$($script:UpdateRepo)/issues/new?title=$([uri]::EscapeDataString($title))"
            $url = "$base&body=$([uri]::EscapeDataString($body))"
            $clip = $false
            # lange Adressen scheitern bei GitHub (vor allem ueber die Anmeldeseite) - Text dann ueber die Zwischenablage
            if ($url.Length -gt 1800) {
                try { Set-Clipboard -Value $body -ErrorAction Stop; $clip = $true } catch { $clip = $false }
                $url = "$base&body=$([uri]::EscapeDataString($(if ($clip) { "(Text aus der Zwischenablage hier einfuegen: Strg+V)" } else { $body.Substring(0, [Math]::Min($body.Length, 900)) + "`n... (gekuerzt)" })))"
            }
            Open-HMUrl $url
            if ($clip) { Out-Console 'Rueckmeldung: GitHub-Issue im Browser geoeffnet - der Text liegt in der Zwischenablage: im Feld mit Strg+V einfuegen, ergaenzen und absenden (GitHub-Konto noetig).' 'Info' }
            else { Out-Console 'Rueckmeldung: GitHub-Issue im Browser geoeffnet - bitte ergaenzen und absenden (GitHub-Konto noetig).' 'Info' }
        }
    } catch { Out-Console "Rueckmeldung: konnte nicht geoeffnet werden ($($_.Exception.Message))." 'Warning' }
}

# Katalog-Statistik (Katalog-Statistik.json im Backup-Ordner): welche Eintraege in der Praxis Daten hatten
function Show-HMCatalogStats {
    $root = Get-BackupRoot
    $stats = Read-HMCatalogStats $root
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($a in $script:AppCatalog) {
        if (-not $stats.ContainsKey("$($a.Id)")) { continue }
        $s = Get-HMCatalogStatsSummary $stats["$($a.Id)"]
        $ver = if ($a.Verified -and "$($a.Verified.Date)") { "$($a.Verified.Date)" } elseif (Test-HMAppTrial $a) { 'nein - testweise' } else { 'nein' }
        $rows.Add(@("$($a.Name)", $ver, [int]$s.Found, [int]$s.Partial, [int]$s.Missing, "$($s.Last)", "$($a.Id)"))
    }
    Show-DataGridWindow -Title "Katalog-Statistik - $root" -Columns @('Programm', 'Geprueft', 'gefunden', 'teilweise', 'nicht_vorhanden', 'zuletzt', 'Id') -Rows $rows.ToArray() `
        -Sort 'nicht_vorhanden DESC, gefunden DESC' -CountText "$($rows.Count) Katalog-Programme mit Backup-Ergebnis (je PC + Benutzer das letzte Backup) - nur lokal, nichts wird gesendet" -Width 1100 -Height 600 `
        -Actions @(
            @{ Text = 'Aus vorhandenen Backups einlesen'; Color = '#FF94E2D5'; NoSelection = $true; Handler = { param($sel, $w, $c) $n = Import-HMCatalogStatsFromBackups (Get-BackupRoot); Out-Console "Katalog-Statistik: $n Backup(s) eingelesen - Fenster neu oeffnen." 'Success'; $w.Close(); Show-HMCatalogStats } }
            @{ Text = 'Markierte als geprueft ...'; Color = '#FFA6E3A1'; Handler = { param($sel, $w, $c) Set-HMAppsVerifiedFromStats @($sel) } }
            @{ Text = 'Rueckmeldung geben ...'; Color = '#FFF9E2AF'; NoSelection = $true; Handler = { param($sel, $w, $c) Start-HMAppFeedback -Rows @($sel) } }
        )
}
# Markierte Katalog-Eintraege als geprueft speichern (Config\apps.json, gleiche Id ueberschreibt den Standard-Eintrag)
function Set-HMAppsVerifiedFromStats([object[]]$Sel) {
    if (-not $isAdmin) { Out-Console 'Als geprueft markieren: nur als Administrator.' 'Warning'; return }
    $ids = @($Sel | Where-Object { $_ } | ForEach-Object { "$($_.Id)" })
    if (-not $ids.Count) { return }
    $stats = Read-HMCatalogStats (Get-BackupRoot)
    $bad = @($ids | Where-Object { -not $stats.ContainsKey($_) -or (Get-HMCatalogStatsSummary $stats[$_]).Found -lt 1 })
    $msg = "$($ids.Count) Eintrag/Eintraege als geprueft markieren (Datum heute, Notiz mit dem Backup-Ergebnis)?$(if ($bad.Count) { "`n`nACHTUNG: $($bad.Count) davon wurden noch an keinem PC vollstaendig gefunden." })`n`nNur markieren, wenn das Programm nach einem Restore auch wirklich mit seinen Einstellungen lief. Gespeichert in Config\apps.json."
    if (-not (Confirm-Action $msg 'Katalog')) { return }
    $p = Join-Path $script:ConfigDir 'apps.json'
    $loc = Read-JsonFile $p
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($x in @($loc.Apps)) { if ($x -and $ids -notcontains "$($x.Id)") { $list.Add($x) } }
    foreach ($id in $ids) {
        $a = @($script:AppCatalog | Where-Object { $_.Id -eq $id })[0]
        if (-not $a) { continue }
        $c = $a | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $sum = if ($stats.ContainsKey($id)) { (Get-HMCatalogStatsSummary $stats[$id]).Text } else { '' }
        $c | Add-Member -NotePropertyName Verified -NotePropertyValue ([pscustomobject]@{ Date = (Get-Date).ToString('yyyy-MM-dd'); Sources = @(); Note = "geprueft am Standort ($env:USERDOMAIN)$(if ($sum) { "; Backups: $sum" })" }) -Force
        $list.Add($c)
    }
    $obj = [ordered]@{}
    if ($loc) { foreach ($pp in $loc.PSObject.Properties) { if ($pp.Name -ne 'Apps') { $obj[$pp.Name] = $pp.Value } } }
    $obj.Apps = $list.ToArray()
    Write-JsonFile $p ([pscustomobject]$obj)
    Out-Console "Katalog: $($ids.Count) Eintrag/Eintraege als geprueft markiert (Config\apps.json)." 'Success'
    Update-HMAeCatalog
}

# Paket in der Softwareverteilung zu einem Katalog-Eintrag (Package = Regex auf Ordner-/Dateiname oder Paketnamen)
function Find-HMAppPackage($App, [object[]]$Packages) {
    if (-not $App -or -not "$($App.Package)") { return $null }
    foreach ($p in @($Packages)) {
        try { if ("$($p.Id)" -match "(?i)$($App.Package)" -or "$($p.Settings.Name)" -match "(?i)$($App.Package)") { return $p } } catch { return $null }
    }
    return $null
}

# Nacharbeiten + Lizenzhinweise fuer die Checkliste (aus dem Manifest des Backups)
function Get-HMAppAfterSteps($Backup) {
    $out = New-Object System.Collections.Generic.List[string]
    if (-not $Backup -or -not $Backup.Manifest -or -not $Backup.Manifest.Apps) { return @() }
    foreach ($f in @($Backup.Manifest.Apps)) {
        $a = @($script:AppCatalog | Where-Object { $_.Id -eq $f.Id })[0]
        if (-not $a) { continue }
        foreach ($s in @($a.After | Where-Object { $_ })) { $out.Add("$s") }
        if (@($a.Items | Where-Object { $_ -and $_.License }).Count) { $out.Add("Lizenz $($a.Name): Lizenzdatei wurde uebertragen - registriert?") }
        elseif ("$($a.License)" -match '(?i)konto|lizenz|schluessel|abmelden|aktivier|abo') { $out.Add("Lizenz $($a.Name): $($a.License)") }
        if ("$($a.NotTransfer)".Trim()) { $out.Add("$($a.Name) - nicht uebertragen: $($a.NotTransfer)") }
        if (Test-HMAppTrial $a) { $out.Add("$($a.Name): Katalog-Eintrag $script:HMAppTrialText") }
        if ("$($a.Version)".Trim()) { $out.Add("$($a.Name) - Version: $($a.Version)") }
        $dbs = @($a.Items | Where-Object { $_ -and "$($_.Role)" -eq 'Database' })
        if (@($dbs | Where-Object { "$($_.DbKind)" -eq 'Service' }).Count) { $out.Add("$($a.Name): Dienst-Datenbank zurueckkopiert - Programm starten und Datenbank pruefen (ggf. im Programm/SQL-Verwaltung anfuegen bzw. Hersteller-Sicherung verwenden)") }
        elseif ($dbs.Count) { $out.Add("$($a.Name): Datenbank zurueckkopiert - Programm oeffnen und Daten pruefen") }
    }
    return @($out | Select-Object -Unique)
}

# ----------------------------------------------------------------------------
# Neuinstallation fehlender Programme (Backup -> neuer PC, Pakete aus der Softwareverteilung)
# ----------------------------------------------------------------------------
function Get-HMBackupSoftware($Backup) {
    if ($Backup.Manifest -and @($Backup.Manifest.Software | Where-Object { $_ }).Count) {
        return @(foreach ($l in @($Backup.Manifest.Software | Where-Object { $_ })) { $p = "$l".Split('|'); [pscustomobject]@{ Name = $p[0]; Version = $(if ($p.Count -gt 1) { $p[1] }) } })
    }
    $csv = Join-Path $Backup.Path 'Info\01-Software.csv'
    if (Test-Path -LiteralPath $csv) { try { return @(Import-Csv -LiteralPath $csv -Delimiter ';' -Encoding UTF8 | ForEach-Object { [pscustomobject]@{ Name = "$($_.Name)"; Version = "$($_.Version)" } }) } catch { } }
    return @()
}
# Fehlende Programme: Programmliste des Backups mit dem Ziel vergleichen (ohne Oberflaeche, testbar).
# $Have = Anzeigenamen am Ziel. Rueckgabe: Rows (Status, Programm, Version, Paket, Zuordnung, Lizenz), Packages (Id -> Paket),
# Winget ('winget:<Id>' -> Id/Name), NoPkg (Anzahl ohne Paket), Installable (Anzahl mit Paket/WinGet)
# -Restrict: nur Programme der Katalog-Eintraege in $OnlyApps (Restore: angehakte Programm-Module); andere fehlende zaehlen in Other
function Get-HMMissingAppPlan {
    param([object[]]$Src = @(), [string[]]$Have = @(), [object[]]$Packages = @(), [object[]]$Catalog = @(), [string[]]$OnlyApps = @(), [switch]$Restrict)
    $rows = New-Object System.Collections.Generic.List[object]
    $pkgs = @{}; $wgs = @{}; $noPkg = 0; $other = 0
    foreach ($s in @($Src | Where-Object { $_ -and "$($_.Name)" } | Sort-Object Name -Unique)) {
        if ($Have -contains $s.Name) { continue }
        # gleiches Programm laut Katalog-Erkennung schon installiert (andere Variante/Schreibweise, z. B. "7-Zip 26.04 (x64)" vs. "... (x64 edition)").
        # Nur wenn der erkannte Teil gleich ist - sonst verdeckt ein Familien-Muster ein fehlendes Programm (B34: Revit vs. AutoCAD,
        # Python 3.12 vs. 3.8). Eintraege mit DetectFamily (ein Muster fuer verschiedene Produkte, z. B. Acrobat Pro/Reader) nie.
        $app0 = @($Catalog | Where-Object { "$($_.Detect)" -and $s.Name -match "$($_.Detect)" })[0]
        if ($app0 -and -not $app0.DetectFamily -and $s.Name -match "$($app0.Detect)") {
            $key = "$($Matches[0])".Trim()
            if ($key -and @($Have | Where-Object { "$_" -match "$($app0.Detect)" -and "$($Matches[0])".Trim() -ieq $key }).Count) { continue }
        }
        # schon installiert in anderer Version? (gleicher Name ohne Versionsnummer)
        $base = ("$($s.Name)" -replace '[\s\-_(]*(x64|x86|64-bit|32-bit)?[\s\-_(]*v?\d+([\.\d]+)*.*$', '').Trim()
        if ($base.Length -ge 4 -and @($Have | Where-Object { "$_".StartsWith($base, [StringComparison]::OrdinalIgnoreCase) }).Count) { continue }
        $pkg = $null; $how = ''
        $app = @($Catalog | Where-Object { "$($_.Detect)" -and $s.Name -match "$($_.Detect)" })[0]
        if ($Restrict -and (-not $app -or @($OnlyApps) -notcontains "$($app.Id)")) { $other++; continue }
        if ($app) { $pkg = Find-HMAppPackage $app $Packages; $how = 'Katalog' }
        if (-not $pkg) { foreach ($p in @($Packages)) { if ("$($p.Settings.DetectName)" -and $s.Name -like "$($p.Settings.DetectName)") { $pkg = $p; $how = 'Paket-Erkennung'; break } } }
        # sonst WinGet (Katalog-Eintrag mit WingetId) - Softwareverteilung hat Vorrang
        $wg = ''
        if (-not $pkg -and $app -and "$($app.WingetId)".Trim()) { $wg = "$($app.WingetId)".Trim(); $wgs["winget:$wg"] = [pscustomobject]@{ Id = $wg; Name = "$($app.Name)" }; $how = 'Katalog (WinGet)' }
        if ($pkg) { $pkgs["$($pkg.Id)"] = $pkg } elseif (-not $wg) { $noPkg++ }
        $rows.Add(@($(if ($pkg) { 'Paket vorhanden' } elseif ($wg) { 'WinGet' } else { 'kein Paket' }), "$($s.Name)", "$($s.Version)", $(if ($pkg) { "$($pkg.Id)" } elseif ($wg) { "winget:$wg" } else { '' }), $how, $(if ($app) { "$($app.License)" } else { '' })))
    }
    return [pscustomobject]@{ Rows = $rows.ToArray(); Packages = $pkgs; Winget = $wgs; NoPkg = $noPkg; Installable = ($pkgs.Count + $wgs.Count); Other = $other }
}

# Programm-Module (eigene Katalog-Module) im Restore, deren Programm am Ziel NICHT installiert ist.
# Einstellungen vor der Installation zurueckzuspielen ist sinnlos (Installer ueberschreibt sie) - diese Module werden ausgelassen.
function Get-HMRestoreAppGap {
    param([object[]]$Modules = @(), [object[]]$Software = @(), [object[]]$Catalog = @())
    $inst = @(Find-HMCatalogApps $Software $Catalog | ForEach-Object { "$($_.Id)" })
    return @(foreach ($m in @($Modules | Where-Object { $_ -and $_.Catalog -and "$($_.AppId)" })) {
        if ($inst -contains "$($m.AppId)") { continue }
        $a = @($Catalog | Where-Object { "$($_.Id)" -eq "$($m.AppId)" })[0]
        if (-not $a -or -not "$($a.Detect)") { continue }   # ohne Erkennung nicht pruefbar -> nicht auslassen
        [pscustomobject]@{ Id = "$($m.Id)"; Name = "$($a.Name)" }
    })
}

function Start-HMAppReinstall {
    $b = $script:SelectedBackup
    if (-not $b) { Out-Console 'Bitte im Reiter Restore zuerst das Backup markieren.' 'Warning'; return }
    $src = @(Get-HMBackupSoftware $b)
    if (-not $src.Count) { Out-Console "Im Backup '$($b.Name)' ist keine Programmliste (erst ab v0.0.5 bzw. mit Modul 'Info-Export')." 'Warning'; return }
    $comp = Get-TargetComputer
    Out-Console "Programme vergleichen: Backup $($b.Name) <-> $comp ..." 'Info'
    Get-HMSoftwareAsync -Computer $comp -Sid '' -State @{ Backup = $b; Src = $src } -OnDone {
        param($sw, $st)
        if ($null -eq $sw) { Out-Console "$($st.Computer) nicht erreichbar (WinRM?) - 'Fernwartung aktivieren' hilft." 'Error'; return }
        $b = $st.State.Backup
        $pk = @(); try { $pk = @(Get-SwPackages) } catch { }
        $plan = Get-HMMissingAppPlan -Src $st.State.Src -Have @($sw | ForEach-Object { "$($_.Name)" }) -Packages $pk -Catalog $script:AppCatalog
        $script:ReinstallPackages = $plan.Packages
        $script:ReinstallWinget = $plan.Winget
        $rows = @($plan.Rows)
        if (-not $rows.Count) { Out-Console "Alle Programme aus dem Backup sind an $($st.Computer) installiert." 'Success'; return }
        $nWg = $plan.Winget.Count
        $withPkg = $plan.Packages.Count
        Out-Console "$($rows.Count) Programme fehlen an $($st.Computer) - $withPkg mit Paket in der Softwareverteilung$(if ($nWg) { ", $nWg ueber WinGet" })" $(if ($withPkg + $nWg) { 'Info' } else { 'Warning' })
        Show-DataGridWindow -Title "Fehlende Programme - $($st.Computer)  (Backup $($b.Name))" -Columns @('Status', 'Programm', 'Version (Backup)', 'Paket', 'Zuordnung', 'Lizenz') -Rows $rows `
            -Sort 'Status DESC, Programm ASC' -CountText "$($rows.Count) fehlen, $withPkg mit Paket, $nWg ueber WinGet (aktuelle Version, fuer alle Benutzer) - Pakete ablegen: Softwareverteilung-Ordner" -Width 1400 -Height 620 `
            -ActionContext @{ Computer = $st.Computer } -Actions @(
                @{ Text = 'Markierte installieren'; Color = '#FFA6E3A1'; Handler = { param($rows, $win, $ctx) [void](Start-HMReinstallQueue $win $ctx.Computer @($rows | Where-Object { $_.Paket } | ForEach-Object { "$($_.Paket)" })) } }
                @{ Text = 'Alle mit Paket / WinGet installieren'; Color = '#FF89B4FA'; NoSelection = $true; Handler = { param($rows, $win, $ctx) [void](Start-HMReinstallQueue $win $ctx.Computer (@($script:ReinstallPackages.Keys) + @($script:ReinstallWinget.Keys))) } }
            )
    }
}
# Pakete nacheinander installieren (msiexec vertraegt keine parallelen Installationen)
$script:SwQueue = $null
# Paket-IDs: Softwareverteilung, 'winget:<Id>' = WinGet (danach, als ein Hintergrundvorgang - Installer stoeren sich sonst)
$script:ReinstallWinget = @{}
$script:SwQueueThen = $null
# Nach der ganzen Installation (Pakete + WinGet) einmal aufrufen: param([bool]$Cancelled) - z.B. Restore danach starten
$script:SwQueueDone = $null
# Rueckgabe: $true = Installation gestartet
function Start-HMReinstallQueue($Win, [string]$Computer, [string[]]$PackageIds, [switch]$NoConfirm) {
    $all = @($PackageIds | Where-Object { $_ } | Select-Object -Unique)
    $wgs = @($all | Where-Object { "$_".StartsWith('winget:') -and $script:ReinstallWinget.ContainsKey("$_") } | ForEach-Object { $script:ReinstallWinget["$_"] })
    $ids = @($all | Where-Object { -not "$_".StartsWith('winget:') -and $script:ReinstallPackages.ContainsKey("$_") })
    $own = if ($Win) { $Win } else { $script:Window }
    if (-not ($ids.Count + $wgs.Count)) { [void][System.Windows.MessageBox]::Show($own, 'Keine Zeile mit Paket markiert.', 'Installieren', 'OK', 'Information'); return $false }
    if (($script:SwQueue -and $script:SwQueue.Count) -or $script:SwQueueThen) { [void][System.Windows.MessageBox]::Show($own, 'Es laeuft bereits eine Installations-Warteschlange.', 'Installieren', 'OK', 'Information'); return $false }
    if ($wgs.Count -and $script:JobRunning) { [void][System.Windows.MessageBox]::Show($own, 'Es laeuft bereits ein Vorgang - WinGet-Installation danach erneut starten.', 'Installieren', 'OK', 'Information'); return $false }
    $names = @($ids | ForEach-Object { "$($script:ReinstallPackages[$_].Settings.Name)" }) + @($wgs | ForEach-Object { "$($_.Name) (WinGet $($_.Id))" })
    if (-not $NoConfirm -and "$([System.Windows.MessageBox]::Show($own, "$($names.Count) Programm(e) nacheinander an $Computer installieren?$(if ($wgs.Count) { "`nWinGet: aktuelle Version fuer alle Benutzer, nach den Paketen der Softwareverteilung." })`n`n$(($names | Select-Object -First 20) -join "`n")", 'Programme installieren', 'YesNo', 'Question'))" -ne 'Yes') { return $false }
    $script:SwQueueThen = $null
    if ($wgs.Count) { $script:SwQueueThen = @{ Computer = $Computer; Items = @($wgs) } }
    if (-not $ids.Count) { $t = $script:SwQueueThen; $script:SwQueueThen = $null; Start-HMAuInstall $t.Computer $t.Items; return $true }
    $script:SwQueue = New-Object System.Collections.Generic.Queue[object]
    foreach ($id in $ids) { $script:SwQueue.Enqueue(@{ Host = $Computer; Package = $script:ReinstallPackages[$id] }) }
    $script:SwQueueTotal = $ids.Count
    Invoke-HMSwQueueNext
    return $true
}
function Invoke-HMSwQueueNext {
    if (-not $script:SwQueue) { return }
    if ($script:SwQueue.Count -eq 0) {
        $script:SwQueue = $null; Out-Console 'Installations-Warteschlange fertig.' 'Success'
        if ($script:SwQueueThen) { $t = $script:SwQueueThen; $script:SwQueueThen = $null; Start-HMAuInstall $t.Computer $t.Items }
        else { Complete-HMInstallQueue $false }
        return
    }
    $n = $script:SwQueue.Dequeue()
    Start-SoftwareDeploy -Hosts @($n.Host) -Package $n.Package -Label ("{0}/{1}" -f ($script:SwQueueTotal - $script:SwQueue.Count), $script:SwQueueTotal)
}
# Ende der ganzen Installation (auch nach WinGet): wartende Folgeaktion ausserhalb des laufenden Ereignisses starten
function Complete-HMInstallQueue([bool]$Cancelled) {
    $d = $script:SwQueueDone
    $script:SwQueueDone = $null
    if (-not $d) { return }
    $script:SwQueueDoneArgs = @{ Action = $d; Cancelled = $Cancelled }
    $script:Window.Dispatcher.BeginInvoke([action]{ $a = $script:SwQueueDoneArgs; $script:SwQueueDoneArgs = $null; if ($a) { & $a.Action $a.Cancelled } }, [System.Windows.Threading.DispatcherPriority]::Background) | Out-Null
}

# ----------------------------------------------------------------------------
# Restore: zuerst fehlende Programme installieren (Empfehlung Microsoft: Programme vor dem Zurueckspielen der Einstellungen),
# Programm-Module ohne installiertes Programm auslassen (2. Lauf nach der Installation nur mit diesen Modulen).
# ----------------------------------------------------------------------------
$script:RestoreAfterInstall = $null
function Start-HMRestorePrep([hashtable]$Ctx) {
    $b = $Ctx.Backup
    $offer = (-not $Ctx.UserMode) -and ($script:Settings.Restore.OfferApps -ne $false)
    $src = @(); if ($offer) { $src = @(Get-HMBackupSoftware $b) }
    $hasAppMods = @($Ctx.Modules | Where-Object { $_.Catalog -and "$($_.AppId)" }).Count -gt 0
    if (-not $src.Count -and -not $hasAppMods) { Invoke-HMProcCheck -Ctx $Ctx -Kind 'Restore'; return }
    Out-Console "Programme am Ziel pruefen ($($Ctx.Computer)) ..." 'Info'
    Get-HMSoftwareAsync -Computer $Ctx.Computer -Sid "$($Ctx.UserSid)" -State @{ Ctx = $Ctx; Src = $src } -OnDone {
        param($sw, $st)
        $c = $st.State.Ctx
        if ($null -eq $sw) { Out-Console "Programme am Ziel nicht lesbar (WinRM?) - Restore ohne Programm-Pruefung." 'Warning'; Invoke-HMProcCheck -Ctx $c -Kind 'Restore'; return }
        $plan = $null
        if (@($st.State.Src).Count) {
            $pk = @(); try { $pk = @(Get-SwPackages) } catch { }
            # nur Programme der angehakten Module anbieten (Programm-Module des Katalogs, dazu Edge/Chrome/Firefox/Office)
            $only = @(Get-HMRestoreModuleApps $c.Modules)
            $plan = Get-HMMissingAppPlan -Src $st.State.Src -Have @($sw | ForEach-Object { "$($_.Name)" }) -Packages $pk -Catalog $script:AppCatalog -OnlyApps $only -Restrict
            if ([int]$plan.Other -gt 0) { Out-Console "Weitere $([int]$plan.Other) Programm(e) aus dem Backup fehlen an $($c.Computer) (ohne angehaktes Modul) - Liste und Installation: Knopf 'Fehlende Programme installieren ...'" 'Info' }
        }
        if ($plan -and $plan.Installable -gt 0) {
            $script:ReinstallPackages = $plan.Packages
            $script:ReinstallWinget = $plan.Winget
            $names = @(@($plan.Rows) | Where-Object { $_[3] } | ForEach-Object { "  $($_[1])$(if ("$($_[3])".StartsWith('winget:')) { ' (WinGet)' })" })
            $miss = @($plan.Rows).Count
            $msg = "An $($c.Computer) fehlen $miss Programm(e) zu den angehakten Modulen, $($plan.Installable) davon installierbar (Softwareverteilung/WinGet):`n`n$(($names | Select-Object -First 15) -join "`n")$(if ($names.Count -gt 15) { "`n  ..." })`n`n" +
                "Microsoft empfiehlt, Programme VOR dem Zurueckspielen der Einstellungen zu installieren.`n`n" +
                "Ja = zuerst installieren, danach startet der Restore automatisch`nNein = nur Restore (Programm-Module fehlender Programme werden ausgelassen)`nAbbrechen = nichts tun"
            $a = "$([System.Windows.MessageBox]::Show($script:Window, $msg, 'Restore - fehlende Programme', 'YesNoCancel', 'Question', 'Yes'))"
            if ($a -eq 'Cancel') { Out-Console 'Restore abgebrochen.' 'Warning'; return }
            if ($a -eq 'Yes') {
                $script:RestoreAfterInstall = $c
                $script:SwQueueDone = {
                    param($cancelled)
                    $rc = $script:RestoreAfterInstall
                    $script:RestoreAfterInstall = $null
                    if (-not $rc) { return }
                    if ($cancelled) { Out-Console "Installation abgebrochen - Restore wird NICHT gestartet (bei Bedarf 'Restore starten')." 'Warning'; return }
                    Out-Console 'Installation fertig - Programme am Ziel neu pruefen, dann Restore ...' 'Info'
                    Start-HMRestoreAfterApps $rc
                }
                $ok = Start-HMReinstallQueue $script:Window $c.Computer (@($plan.Packages.Keys) + @($plan.Winget.Keys)) -NoConfirm
                if (-not $ok) { $script:SwQueueDone = $null; $script:RestoreAfterInstall = $null; Out-Console 'Installation nicht gestartet - Restore abgebrochen.' 'Warning' }
                else { Out-Console "Zuerst werden $($plan.Installable) Programm(e) installiert - der Restore startet danach automatisch." 'Info' }
                return
            }
        } elseif ($plan -and @($plan.Rows).Count) {
            Out-Console "$(@($plan.Rows).Count) Programm(e) zu den angehakten Modulen fehlen an $($c.Computer) (kein Paket/WinGet) - Liste: Knopf 'Fehlende Programme installieren ...'" 'Warning'
        }
        Resume-HMRestoreWithApps $c $sw
    }
}
# Katalog-Eintraege (Programme) der angehakten Restore-Module: Programm-Module und die festen Module Edge/Chrome/Firefox/Office
function Get-HMRestoreModuleApps([object[]]$Modules) {
    $core = @{ Edge = 'App_Edge'; Chrome = 'App_Chrome'; Firefox = 'App_Firefox'; Office = 'App_Office' }
    return @(foreach ($m in @($Modules | Where-Object { $_ })) {
        if ($m.Catalog -and "$($m.AppId)") { "$($m.AppId)" }
        elseif ($core.ContainsKey("$($m.Id)")) { $core["$($m.Id)"] }
    }) | Select-Object -Unique
}
# Nach der Installation: Software neu lesen, dann wie ohne Installation weiter
function Start-HMRestoreAfterApps([hashtable]$Ctx) {
    Get-HMSoftwareAsync -Computer $Ctx.Computer -Sid "$($Ctx.UserSid)" -State @{ Ctx = $Ctx } -OnDone {
        param($sw, $st)
        if ($null -eq $sw) { Out-Console 'Programme am Ziel nicht lesbar - Restore ohne Programm-Pruefung.' 'Warning'; Invoke-HMProcCheck -Ctx $st.State.Ctx -Kind 'Restore'; return }
        Resume-HMRestoreWithApps $st.State.Ctx $sw
    }
}
# Programm-Module ohne installiertes Programm auslassen und fuer einen 2. Lauf merken, dann Restore
function Resume-HMRestoreWithApps([hashtable]$Ctx, $Software) {
    $gap = @(Get-HMRestoreAppGap -Modules $Ctx.Modules -Software $Software -Catalog $script:AppCatalog)
    $Ctx.SkippedApps = @()
    if ($gap.Count) {
        $ids = @($gap | ForEach-Object { $_.Id })
        $Ctx.Modules = @($Ctx.Modules | Where-Object { $ids -notcontains $_.Id })
        $Ctx.SkippedApps = $gap
        Out-Console "Programm nicht installiert - Einstellungen werden diesmal NICHT zurueckgespielt: $(@($gap | ForEach-Object { $_.Name }) -join ', ')" 'Warning'
        if (-not @($Ctx.Modules).Count) {
            Out-Console 'Nichts zurueckzuspielen: alle gewaehlten Programm-Module gehoeren zu Programmen, die am Ziel fehlen. Erst installieren, dann erneut Restore starten.' 'Warning'
            return
        }
        Out-Console "   Nach der Installation erneut 'Restore starten' - dann sind nur diese Programm-Module angehakt." 'Info'
    }
    $script:RestoreSkippedApps = @($Ctx.SkippedApps)
    Invoke-HMProcCheck -Ctx $Ctx -Kind 'Restore'
}
# Nach dem Restore: fuer den 2. Lauf nur die ausgelassenen Programm-Module anhaken
function Set-HMRestoreChecksForSkippedApps {
    $sk = @($script:RestoreSkippedApps)
    $script:RestoreSkippedApps = @()
    if (-not $sk.Count) { return }
    $ids = @($sk | ForEach-Object { $_.Id })
    foreach ($k in @($script:RestoreChecks.Keys)) { $script:RestoreChecks[$k].IsChecked = ($ids -contains $k -and $script:RestoreChecks[$k].IsEnabled) }
    Out-Console "Fuer den 2. Lauf angehakt (nur Programm-Einstellungen): $(@($sk | ForEach-Object { $_.Name }) -join ', ') - Programme installieren, dann 'Restore starten'." 'Info'
}

# ----------------------------------------------------------------------------
# Vor Backup/Restore: laufende Programme der Katalog-Module (CloseProcess) abfragen - eine Sammelabfrage
# Kind = 'Backup' | 'Restore'. Danach wird der Vorgang gestartet (Start-BackupJob bzw. Start-RestoreJob).
# ----------------------------------------------------------------------------
function Invoke-HMProcCheck([hashtable]$Ctx, [string]$Kind) {
    $spec = @(foreach ($m in @($Ctx.Modules)) {
        $cp = @(@($m.CloseProcess) | Where-Object { "$_".Trim() })
        if ($cp.Count) { [pscustomobject]@{ Id = "$($m.Id)"; Name = "$($m.Name)"; Procs = $cp } }
    })
    $Ctx.ProcDecisions = @{}
    if (-not $spec.Count) { Resume-HMProcCheck $Ctx $Kind; return }
    Out-Console "Laufende Programme pruefen ($(@($spec | ForEach-Object { $_.Name }) -join ', ')) ..." 'Debug'
    Invoke-AsyncCommand -ScriptBlock {
        param($eng, $comp, $cred, $userMode, $sid, $account, $spec)
        . $eng
        $c = @{ Computer = $comp; IsRemote = -not (Test-HMIsLocal $comp); Credential = $cred; UserMode = [bool]$userMode; Account = $account }
        foreach ($s in @($spec)) {
            $run = @(Get-HMRunningProcs $c @($s.Procs) $sid)
            if ($run.Count) { [pscustomobject]@{ Id = $s.Id; Name = $s.Name; Running = (@($run | ForEach-Object { "$($_.Name) ($($_.Id))" }) -join ', ') } }
        }
    } -ArgumentList @($script:Engine, $Ctx.Computer, $Ctx.Credential, [bool]$Ctx.UserMode, $Ctx.UserSid, $Ctx.Account, $spec) -TimeoutSec 60 -State @{ Ctx = $Ctx; Kind = $Kind } -OnComplete {
        param($r, $st)
        $c = $st.Ctx
        if ($r -is [string] -and $r -like 'FEHLER*') {
            Out-Console "Laufende Programme nicht pruefbar ($r) - laeuft ein Programm, wird sein Modul uebersprungen" 'Warning'
            Resume-HMProcCheck $c $st.Kind; return
        }
        $rows = @(@($r) | Where-Object { $_ -and $_.Id })
        if (-not $rows.Count) { Resume-HMProcCheck $c $st.Kind; return }
        $dec = Show-HMProcDialog $rows $st.Kind $c.Computer
        if ($null -eq $dec) { Out-Console "$($st.Kind) abgebrochen (laufende Programme)." 'Warning'; return }
        $c.ProcDecisions = $dec
        foreach ($x in $rows) { Out-Console ("   {0}: {1} -> {2}" -f $x.Name, $x.Running, (Format-HMProcDecision $dec[$x.Id])) 'Info' }
        Resume-HMProcCheck $c $st.Kind
    }
}
function Resume-HMProcCheck([hashtable]$Ctx, [string]$Kind) {
    if ($script:JobRunning) { Out-Console 'Es laeuft bereits ein Vorgang.' 'Warning'; return }
    if ($Kind -eq 'Restore') { Start-RestoreJob $Ctx } else { Start-BackupJob $Ctx }
}
function Format-HMProcDecision([string]$D) {
    switch ($D) { 'Close' { 'schliessen' } 'CloseForce' { 'schliessen, notfalls beenden' } 'Copy' { 'trotzdem kopieren' } default { 'ueberspringen' } }
}
# Dialog: je Programm Schliessen / Schliessen, notfalls beenden / Ueberspringen / Trotzdem kopieren. Rueckgabe Hashtable Id -> Entscheidung, $null = Abbrechen
function Show-HMProcDialog([object[]]$Rows, [string]$Kind, [string]$Computer, [object[]]$Options = @(), [string]$Note = '') {
    $x = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Programme geoeffnet" Width="760" SizeToContent="Height" ResizeMode="NoResize" WindowStartupLocation="CenterOwner" Background="#FF1E1E2E">
  <StackPanel Margin="14">
    <TextBlock x:Name="info" Foreground="#FFCDD6F4" TextWrapping="Wrap" Margin="0,0,0,10"/>
    <StackPanel x:Name="rows" Margin="0,0,0,10"/>
    <TextBlock x:Name="note" Foreground="#FF6C7086" TextWrapping="Wrap" FontSize="11" Margin="0,0,0,12" Text="Schliessen = wie der Benutzer das Fenster schliesst (ungespeicherte Arbeit fragt das Programm selbst nach). Laesst sich das Programm in 20 s nicht schliessen, wird das Modul uebersprungen - ausser 'notfalls beenden' ist gewaehlt (Programm wird dann hart beendet, ungespeicherte Daten gehen verloren). Trotzdem kopieren: geoeffnete Dateien/Datenbanken koennen fehlen oder inkonsistent sein."/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
      <Button x:Name="ok" Content="Weiter" Width="110" Height="28" Background="#FFA6E3A1" Foreground="#FF1E1E2E" FontWeight="SemiBold" Margin="0,0,6,0" IsDefault="True"/>
      <Button x:Name="cancel" Content="Abbrechen" Width="100" Height="28" Background="#FF45475A" Foreground="#FFCDD6F4" IsCancel="True"/>
    </StackPanel>
  </StackPanel>
</Window>
"@
    $w = [System.Windows.Markup.XamlReader]::Parse($x)
    if ($script:AppIcon) { $w.Icon = $script:AppIcon }
    $w.FindName('info').Text = "An $Computer laufen Programme, deren Dateien beim $Kind gesperrt sein koennen. Was soll HUMig tun?"
    $pnl = $w.FindName('rows')
    $combos = @{}
    $opts = if (@($Options).Count) { @($Options) } else { @(@('Close', 'Schliessen'), @('CloseForce', 'Schliessen, notfalls beenden'), @('Skip', 'Modul ueberspringen'), @('Copy', 'Trotzdem kopieren')) }
    if ($Note) { $w.FindName('note').Text = $Note }
    foreach ($r in $Rows) {
        $g = New-Object System.Windows.Controls.Grid
        $g.Margin = [System.Windows.Thickness]::new(0, 2, 0, 2)
        foreach ($wd in @(230, 280, 210)) { $cd = New-Object System.Windows.Controls.ColumnDefinition; $cd.Width = [System.Windows.GridLength]::new($wd); [void]$g.ColumnDefinitions.Add($cd) }
        $t1 = New-Object System.Windows.Controls.TextBlock; $t1.Text = "$($r.Name)"; $t1.Foreground = New-Brush '#FFCDD6F4'; $t1.FontWeight = 'SemiBold'; $t1.VerticalAlignment = 'Center'; $t1.TextTrimming = 'CharacterEllipsis'
        $t2 = New-Object System.Windows.Controls.TextBlock; $t2.Text = "$($r.Running)"; $t2.Foreground = New-Brush '#FFA6ADC8'; $t2.VerticalAlignment = 'Center'; $t2.TextTrimming = 'CharacterEllipsis'; $t2.ToolTip = "$($r.Running)"
        $cb = New-Object System.Windows.Controls.ComboBox
        foreach ($o in $opts) { $it = New-Object System.Windows.Controls.ComboBoxItem; $it.Content = $o[1]; $it.Tag = $o[0]; [void]$cb.Items.Add($it) }
        $cb.SelectedIndex = 0
        [System.Windows.Controls.Grid]::SetColumn($t2, 1); [System.Windows.Controls.Grid]::SetColumn($cb, 2)
        [void]$g.Children.Add($t1); [void]$g.Children.Add($t2); [void]$g.Children.Add($cb)
        [void]$pnl.Children.Add($g)
        $combos["$($r.Id)"] = $cb
    }
    $w.FindName('ok').Add_Click({ $w.DialogResult = $true }.GetNewClosure())
    $w.Owner = $script:Window; Set-HMWindowScale $w
    if ($w.ShowDialog() -ne $true) { return $null }
    $dec = @{}
    foreach ($k in $combos.Keys) { $dec[$k] = "$($combos[$k].SelectedItem.Tag)" }
    return $dec
}
