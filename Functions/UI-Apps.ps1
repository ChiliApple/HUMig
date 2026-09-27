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
        if (-not @($a.Items | Where-Object { $_ }).Count) { continue }
        $exists = $false
        foreach ($m in $Mods) { if ($m.Id -eq $a.Id) { $exists = $true; break } }
        if ($exists) { continue }
        $user = @($a.Items | Where-Object { ($_.Path -match '^\{(PROFILE|APPDATA|LOCALAPPDATA)\}') -or ($_.Key -match '^HK(CU|EY_CURRENT_USER)') }).Count -gt 0
        $lic = @($a.Items | Where-Object { $_ -and $_.License }).Count
        $hint = "$($a.Name): $($a.Transfer)" + $(if ($a.License) { "`nLizenz: $($a.License)" } else { '' }) + $(if ($lic) { "`nLIZENZDATEI wird mitgesichert - am neuen PC gleich lizenziert" } else { '' }) + "`n(Programm-Katalog - wird eingeblendet, wenn das Programm installiert ist)"
        $Mods.Add([pscustomobject]@{ Id = "$($a.Id)"; Name = "$($a.Name)$(if ($lic) { ' (+ Lizenz)' })"; Group = 'Programme'; Default = $false; Show = $false; Catalog = $true
            Scope = $(if ($user) { 'User' } else { 'Machine' }); Remote = $true; Hint = $hint; Items = @($a.Items) })
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
        $rows.Add(@($(if ($d) { 'installiert' } else { '-' }), "$($a.Name)", $(if ($d) { "$($d.Version)" } else { '' }), "$($a.Transfer)", $(if ($licItems.Count) { "JA: $($licItems -join ', ')" } else { 'nein' }), "$($a.License)", ($mods -join ', '), $(if ($pkg) { "$($pkg.Id)" } else { '' }), ((@($a.After) | Where-Object { $_ }) -join ' | ')))
    }
    $n = @($script:DetectedApps).Count
    Show-DataGridWindow -Title "Programm-Katalog - $(Get-TargetComputer)" -Columns @('Status', 'Programm', 'Version', 'Uebertragbar', 'Lizenz uebertragen', 'Lizenz-Hinweis', 'Modul', 'Paket', 'Nacharbeit') -Rows $rows.ToArray() `
        -Sort 'Status DESC, Programm ASC' -CountText "$n von $($rows.Count) Katalog-Programmen installiert - eigene Eintraege: Config\apps.json" -Width 1500 -Height 640
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
