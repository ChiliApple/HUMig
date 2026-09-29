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
    $script:AppCatalog = $list.ToArray()
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
        $hint = "$($a.Name): $($a.Transfer)" + $(if ($a.License) { "`nLizenz: $($a.License)" } else { '' }) + $(if ($lic) { "`nLIZENZDATEI wird mitgesichert - am neuen PC gleich lizenziert" } else { '' }) + "`n(Programm-Katalog - wird eingeblendet, wenn das Programm installiert ist)"
        $Mods.Add([pscustomobject]@{ Id = "$($a.Id)"; Name = "$($a.Name)$(if ($lic) { ' (+ Lizenz)' })"; Group = 'Programme'; Default = $false; Show = $false; Catalog = $true
            Scope = $(if ($user) { 'User' } else { 'Machine' }); Remote = $true; Hint = $hint; Items = @($a.Items)
            CloseProcess = $cp; StopService = $ss; AppId = "$($a.Id)" })
    }
}

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
        if ($newOnes.Count -or $gone.Count) { Update-BackupPanelKeepChecks -Check @($newOnes | Where-Object { $_ -like 'App_*' }) }
        if ($found.Count) {
            Out-Console ("Programme erkannt ({0}): {1}" -f $found.Count, (@($found | ForEach-Object { $_.Name }) -join ', ')) 'Info'
            $auto = @($newOnes | Where-Object { $_ -like 'App_*' })
            if ($auto.Count) { Out-Console "   Einstellungen dieser Programme werden mitgesichert (Gruppe PROGRAMME, abwaehlbar) - Details: Knopf 'Programme'" 'Info' }
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
    foreach ($a in $script:AppCatalog) {
        $d = $det[$a.Id]
        $mods = @(Get-HMAppModuleIds $a | ForEach-Object { $id = $_; $m = @($script:Modules | Where-Object { $_.Id -eq $id })[0]; if ($m) { $m.Name } })
        $pkg = Find-HMAppPackage $a $pk
        $licItems = @($a.Items | Where-Object { $_ -and $_.License } | ForEach-Object { if ($_.Filter) { @($_.Filter) -join ',' } elseif ($_.Key) { "$($_.Key)" } else { Split-Path "$($_.Path)" -Leaf } } | Select-Object -Unique)
        $db = @($a.Items | Where-Object { $_ -and "$($_.Role)" -eq 'Database' } | ForEach-Object { if ("$($_.DbKind)" -eq 'Service') { 'Dienst' } else { 'Datei' } } | Select-Object -Unique)
        $ver = if ($a.Verified -and "$($a.Verified.Date)") { "$($a.Verified.Date)" } else { 'nein' }
        $rows.Add(@($(if ($d) { 'installiert' } else { '-' }), "$($a.Name)", $(if ($d) { "$($d.Version)" } else { '' }), "$($a.Transfer)", "$($a.NotTransfer)", $(if ($licItems.Count) { "JA: $($licItems -join ', ')" } else { 'nein' }), "$($a.License)", ($db -join ', '), (@(@($a.CloseProcess) | Where-Object { $_ }) -join ', '), ($mods -join ', '), $(if ($pkg) { "$($pkg.Id)" } else { '' }), ((@($a.After) | Where-Object { $_ }) -join ' | '), $ver, "$($a.Id)"))
    }
    $n = @($script:DetectedApps).Count
    Show-DataGridWindow -Title "Programm-Katalog - $(Get-TargetComputer)" -Columns @('Status', 'Programm', 'Version', 'Uebertragbar', 'Nicht_uebertragbar', 'Lizenz uebertragen', 'Lizenz-Hinweis', 'DB', 'Schliessen', 'Modul', 'Paket', 'Nacharbeit', 'Geprueft', 'Id') -Rows $rows.ToArray() `
        -Sort 'Status DESC, Programm ASC' -CountText "$n von $($rows.Count) Katalog-Programmen installiert - eigene Eintraege: Config\apps.json" -Width 1600 -Height 640 `
        -Actions @(
            @{ Text = 'Katalog bearbeiten ...'; Color = '#FFCBA6F7'; NoSelection = $true; Handler = { param($sel, $w, $c) $id = if (@($sel).Count) { "$(@($sel)[0].Id)" } else { '' }; Show-HMAppEditor -SelectId $id } }
        )
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
        $have = @($sw | ForEach-Object { "$($_.Name)" })
        $pk = @(); try { $pk = @(Get-SwPackages) } catch { }
        $rows = New-Object System.Collections.Generic.List[object]
        $script:ReinstallPackages = @{}
        $noPkg = 0
        foreach ($s in @($st.State.Src | Sort-Object Name -Unique)) {
            if ($have -contains $s.Name) { continue }
            # schon installiert in anderer Version? (gleicher Name ohne Versionsnummer)
            $base = ($s.Name -replace '[\s\-_(]*(x64|x86|64-bit|32-bit)?[\s\-_(]*v?\d+([\.\d]+)*.*$', '').Trim()
            if ($base.Length -ge 4 -and @($have | Where-Object { $_.StartsWith($base, [StringComparison]::OrdinalIgnoreCase) }).Count) { continue }
            $pkg = $null; $how = ''
            $app = @($script:AppCatalog | Where-Object { "$($_.Detect)" -and $s.Name -match "$($_.Detect)" })[0]
            if ($app) { $pkg = Find-HMAppPackage $app $pk; $how = 'Katalog' }
            if (-not $pkg) { foreach ($p in $pk) { if ("$($p.Settings.DetectName)" -and $s.Name -like "$($p.Settings.DetectName)") { $pkg = $p; $how = 'Paket-Erkennung'; break } } }
            if ($pkg) { $script:ReinstallPackages["$($pkg.Id)"] = $pkg } else { $noPkg++ }
            $rows.Add(@($(if ($pkg) { 'Paket vorhanden' } else { 'kein Paket' }), $s.Name, "$($s.Version)", $(if ($pkg) { "$($pkg.Id)" } else { '' }), $how, $(if ($app) { "$($app.License)" } else { '' })))
        }
        if (-not $rows.Count) { Out-Console "Alle Programme aus dem Backup sind an $($st.Computer) installiert." 'Success'; return }
        $withPkg = $rows.Count - $noPkg
        Out-Console "$($rows.Count) Programme fehlen an $($st.Computer) - $withPkg mit Paket in der Softwareverteilung" $(if ($withPkg) { 'Info' } else { 'Warning' })
        Show-DataGridWindow -Title "Fehlende Programme - $($st.Computer)  (Backup $($b.Name))" -Columns @('Status', 'Programm', 'Version (Backup)', 'Paket', 'Zuordnung', 'Lizenz') -Rows $rows.ToArray() `
            -Sort 'Status DESC, Programm ASC' -CountText "$($rows.Count) fehlen, $withPkg mit Paket - Pakete ablegen: Softwareverteilung-Ordner" -Width 1400 -Height 620 `
            -ActionContext @{ Computer = $st.Computer } -Actions @(
                @{ Text = 'Markierte installieren'; Color = '#FFA6E3A1'; Handler = { param($rows, $win, $ctx) Start-HMReinstallQueue $win $ctx.Computer @($rows | Where-Object { $_.Paket } | ForEach-Object { "$($_.Paket)" }) } }
                @{ Text = 'Alle mit Paket installieren'; Color = '#FF89B4FA'; NoSelection = $true; Handler = { param($rows, $win, $ctx) Start-HMReinstallQueue $win $ctx.Computer @($script:ReinstallPackages.Keys) } }
            )
    }
}
# Pakete nacheinander installieren (msiexec vertraegt keine parallelen Installationen)
$script:SwQueue = $null
function Start-HMReinstallQueue($Win, [string]$Computer, [string[]]$PackageIds) {
    $ids = @($PackageIds | Where-Object { $_ } | Select-Object -Unique)
    if (-not $ids.Count) { [void][System.Windows.MessageBox]::Show($Win, 'Keine Zeile mit Paket markiert.', 'Installieren', 'OK', 'Information'); return }
    if ($script:SwQueue -and $script:SwQueue.Count) { [void][System.Windows.MessageBox]::Show($Win, 'Es laeuft bereits eine Installations-Warteschlange.', 'Installieren', 'OK', 'Information'); return }
    $names = @($ids | ForEach-Object { "$($script:ReinstallPackages[$_].Settings.Name)" })
    if ("$([System.Windows.MessageBox]::Show($Win, "$($ids.Count) Paket(e) nacheinander an $Computer installieren?`n`n$(($names | Select-Object -First 20) -join "`n")", 'Programme installieren', 'YesNo', 'Question'))" -ne 'Yes') { return }
    $script:SwQueue = New-Object System.Collections.Generic.Queue[object]
    foreach ($id in $ids) { $script:SwQueue.Enqueue(@{ Host = $Computer; Package = $script:ReinstallPackages[$id] }) }
    $script:SwQueueTotal = $ids.Count
    Invoke-HMSwQueueNext
}
function Invoke-HMSwQueueNext {
    if (-not $script:SwQueue) { return }
    if ($script:SwQueue.Count -eq 0) { $script:SwQueue = $null; Out-Console 'Installations-Warteschlange fertig.' 'Success'; return }
    $n = $script:SwQueue.Dequeue()
    Start-SoftwareDeploy -Hosts @($n.Host) -Package $n.Package -Label ("{0}/{1}" -f ($script:SwQueueTotal - $script:SwQueue.Count), $script:SwQueueTotal)
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
function Show-HMProcDialog([object[]]$Rows, [string]$Kind, [string]$Computer) {
    $x = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Programme geoeffnet" Width="760" SizeToContent="Height" ResizeMode="NoResize" WindowStartupLocation="CenterOwner" Background="#FF1E1E2E">
  <StackPanel Margin="14">
    <TextBlock x:Name="info" Foreground="#FFCDD6F4" TextWrapping="Wrap" Margin="0,0,0,10"/>
    <StackPanel x:Name="rows" Margin="0,0,0,10"/>
    <TextBlock Foreground="#FF6C7086" TextWrapping="Wrap" FontSize="11" Margin="0,0,0,12" Text="Schliessen = wie der Benutzer das Fenster schliesst (ungespeicherte Arbeit fragt das Programm selbst nach). Laesst sich das Programm in 20 s nicht schliessen, wird das Modul uebersprungen - ausser 'notfalls beenden' ist gewaehlt (Programm wird dann hart beendet, ungespeicherte Daten gehen verloren). Trotzdem kopieren: geoeffnete Dateien/Datenbanken koennen fehlen oder inkonsistent sein."/>
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
    $opts = @(@('Close', 'Schliessen'), @('CloseForce', 'Schliessen, notfalls beenden'), @('Skip', 'Modul ueberspringen'), @('Copy', 'Trotzdem kopieren'))
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
