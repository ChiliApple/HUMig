#Requires -Version 5.1
<#
.SYNOPSIS
    Reiter "Server-Backup": Hyper-V-VMs je Profil (Schule/Standort) auf rotierende USB-Platten sichern,
    Platten einrichten/erkennen/auswerfen, Verlauf und Statistik, Versionen, Host-Konfiguration, Wiederherstellung.
.NOTES
    Zielmaschine: Hyper-V-Host, HUMig als Administrator. Wird im UI-Thread geladen (dot-source aus HUMig.ps1).
    Profile: Config\serverbackup.json | Verlauf: Config\ServerBackup\history.json + <Platte>\HUMig-ServerBackup\history.json
#>

$script:SbEngine     = Join-Path $script:AppRoot 'Functions\ServerBackup-Engine.ps1'
$script:SbCfgFile    = Join-Path $script:ConfigDir 'serverbackup.json'
$script:SbHistFile   = Join-Path $script:ConfigDir 'ServerBackup\history.json'
$script:SbReportDir  = Join-Path $script:LogDir 'ServerBackup'
$script:SbVms        = @()
$script:SbDrives     = @()
$script:SbInit       = $false
$script:SbPrereq     = $null
$script:SbSuppress   = $false
$script:SbSuppressDrive = $false
$script:SbButtons    = @()

# ----------------------------------------------------------------------------
# Profile
# ----------------------------------------------------------------------------
function ConvertTo-HMSbProfile($p) {
    $name = "$($p.Name)".Trim()
    $pre = "$($p.DiskPrefix)".Trim().ToUpper()
    if (-not $pre) { $pre = 'HUMIG-' + (ConvertTo-HMSbSafeName $name).ToUpper() }
    $n = 0; try { $n = [int]$p.Disks } catch { }
    $w = 0; try { $w = [int]$p.WarnDays } catch { }
    return [pscustomobject][ordered]@{
        Name = $name; DiskPrefix = $pre; Disks = $(if ($n -gt 0) { $n } else { 2 })
        VMs = @($p.VMs | Where-Object { "$_".Trim() } | ForEach-Object { "$_".Trim() })
        HostConfig = ($p.HostConfig -ne $false); Verify = ($p.Verify -ne $false); HostSystem = ($p.HostSystem -eq $true)
        WarnDays = $(if ($w -gt 0) { $w } else { 14 })
    }
}
function Get-HMSbConfig {
    $c = Read-JsonFile $script:SbCfgFile
    $list = @()
    if ($c -and $c.Profiles) { foreach ($p in @($c.Profiles)) { if ($p -and "$($p.Name)".Trim()) { $list += (ConvertTo-HMSbProfile $p) } } }
    $ren = @()
    if ($c -and $c.Renames) { foreach ($r in @($c.Renames)) { if ($r -and "$($r.Old)" -and "$($r.New)") { $ren += [pscustomobject]@{ Old = "$($r.Old)"; New = "$($r.New)" } } } }
    return [pscustomobject]@{ LastProfile = "$($c.LastProfile)"; Profiles = $list; Renames = $ren }
}
function Save-HMSbConfig($Cfg) {
    Write-JsonFile $script:SbCfgFile ([pscustomobject]@{ LastProfile = "$($Cfg.LastProfile)"; Profiles = @($Cfg.Profiles); Renames = @($Cfg.Renames) }) -Depth 6
}
# Umbenennungen (alter -> neuer Profilname) auf Verlaufseintraege nicht angesteckter Platten anwenden
function Get-HMSbCurrentName([string]$Name, $Renames) {
    $n = $Name
    for ($i = 0; $i -lt 20; $i++) {
        $r = @($Renames | Where-Object { $_.Old -eq $n })[0]
        if (-not $r) { break }
        $n = $r.New
    }
    return $n
}
function Get-HMSbProfile {
    $n = "$($ui.cmbSbProfile.SelectedItem)"
    if (-not $n) { return $null }
    $cfg = Get-HMSbConfig
    return (@($cfg.Profiles | Where-Object { $_.Name -eq $n })[0])
}
function Get-HMSbCheckedVms {
    return @($ui.pnlSbVms.Children | Where-Object { $_ -is [System.Windows.Controls.CheckBox] -and $_.IsChecked } | ForEach-Object { "$($_.Tag)" })
}
function Format-HMSbStatus([string]$s) { switch ($s) { 'OK' { 'OK' } 'Warning' { 'Warnung' } 'Error' { 'FEHLER' } default { $s } } }
function Format-HMSbState([string]$s) { switch ($s) { 'Running' { 'laeuft' } 'Off' { 'aus' } 'Saved' { 'gespeichert' } 'Paused' { 'angehalten' } default { $s } } }
function Get-HMSbDate([string]$s) {
    try { return [datetime]::ParseExact($s, 'yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture) } catch { return $null }
}

function Update-HMSbProfileList([string]$Select = '') {
    $cfg = Get-HMSbConfig
    $script:SbSuppress = $true
    $ui.cmbSbProfile.Items.Clear()
    foreach ($p in $cfg.Profiles) { [void]$ui.cmbSbProfile.Items.Add($p.Name) }
    if (-not $Select) { $Select = $cfg.LastProfile }
    if ($Select -and $ui.cmbSbProfile.Items.Contains($Select)) { $ui.cmbSbProfile.SelectedItem = $Select }
    elseif ($ui.cmbSbProfile.Items.Count) { $ui.cmbSbProfile.SelectedIndex = 0 }
    $script:SbSuppress = $false
    Set-HMSbFromProfile
}
function Set-HMSbFromProfile {
    $p = Get-HMSbProfile
    foreach ($cb in @($ui.pnlSbVms.Children)) {
        if ($cb -is [System.Windows.Controls.CheckBox]) { $cb.IsChecked = [bool]($p -and (@($p.VMs) -contains "$($cb.Tag)")) }
    }
    if ($p) {
        $ui.chkSbHostConfig.IsChecked = $p.HostConfig
        $ui.chkSbVerify.IsChecked = $p.Verify
        $ui.chkSbHostSystem.IsChecked = $p.HostSystem
        if (@($script:SbVms).Count) {
            $miss = @($p.VMs | Where-Object { $n = $_; -not @($script:SbVms | Where-Object { $_.Name -eq $n }).Count })
            if ($miss.Count) { Out-Console "Server-Backup: VM(s) aus Profil '$($p.Name)' gibt es auf diesem Host nicht: $($miss -join ', ') - Profil pruefen" 'Warning' }
        }
    }
    Select-HMSbDriveForProfile
    Update-HMSbSize
    Update-HMSbHistory
    Update-HMSbSchedules
}
function Save-HMSbLastProfile([string]$Name) {
    $cfg = Get-HMSbConfig
    if ($cfg.LastProfile -ne $Name) { $cfg.LastProfile = $Name; Save-HMSbConfig $cfg }
}

function New-HMSbProfile {
    $n = Show-TextInputDialog -Title 'Neues Sicherungs-Profil' -Label 'Name des Profils (z.B. Schule oder Standort):'
    if (-not "$n".Trim()) { return }
    $n = "$n".Trim()
    $cfg = Get-HMSbConfig
    if (@($cfg.Profiles | Where-Object { $_.Name -eq $n }).Count) { Out-Console "Profil '$n' gibt es bereits" 'Warning'; return }
    $pre = Read-HMSbPrefix ('HUMIG-' + (ConvertTo-HMSbSafeName $n).ToUpper())
    if (-not $pre) { return }
    $cnt = Read-HMSbDiskCount 2
    if (-not $cnt) { return }
    $prof = ConvertTo-HMSbProfile ([pscustomobject]@{ Name = $n; DiskPrefix = $pre; Disks = $cnt; VMs = @(Get-HMSbCheckedVms)
            HostConfig = [bool]$ui.chkSbHostConfig.IsChecked; Verify = [bool]$ui.chkSbVerify.IsChecked; HostSystem = [bool]$ui.chkSbHostSystem.IsChecked; WarnDays = 14 })
    $cfg.Profiles = @($cfg.Profiles) + @($prof)
    $cfg.LastProfile = $n
    Save-HMSbConfig $cfg
    Out-Console "Profil '$n' angelegt: Platten $pre-1 bis $pre-$cnt, $(@($prof.VMs).Count) VM(s)" 'Success'
    Update-HMSbProfileList $n
}
function Read-HMSbPrefix([string]$Default) {
    $pre = Show-TextInputDialog -Title 'Platten-Bezeichnung' -Label "Bezeichnung der Platten OHNE Nummer - die Platten heissen dann <Bezeichnung>-1, -2 ...`n(max. 29 Zeichen: A-Z, 0-9, - und _)" -Text $Default
    if ($null -eq $pre) { return $null }
    $pre = "$pre".Trim().ToUpper()
    if ($pre -notmatch '^[A-Z0-9_\-]{1,29}$') { Out-Console "Ungueltige Bezeichnung '$pre' (max. 29 Zeichen: A-Z, 0-9, - und _)" 'Error'; return $null }
    return $pre
}
function Read-HMSbDiskCount([int]$Default) {
    $c = Show-TextInputDialog -Title 'Anzahl Platten' -Label 'Wie viele Platten gehoeren zu diesem Profil (Rotation + ausgelagerte Platte)?' -Text "$Default"
    if ($null -eq $c) { return $null }
    $i = 0
    if (-not [int]::TryParse("$c".Trim(), [ref]$i) -or $i -lt 1 -or $i -gt 20) { Out-Console "Ungueltige Anzahl '$c' (1-20)" 'Error'; return $null }
    return $i
}
function Save-HMSbProfile {
    $p = Get-HMSbProfile
    if (-not $p) { Out-Console 'Kein Profil gewaehlt - zuerst "Neu ..."' 'Warning'; return }
    $cfg = Get-HMSbConfig
    foreach ($x in $cfg.Profiles) {
        if ($x.Name -eq $p.Name) {
            $x.VMs = @(Get-HMSbCheckedVms)
            $x.HostConfig = [bool]$ui.chkSbHostConfig.IsChecked
            $x.Verify = [bool]$ui.chkSbVerify.IsChecked
            $x.HostSystem = [bool]$ui.chkSbHostSystem.IsChecked
        }
    }
    Save-HMSbConfig $cfg
    Out-Console "Profil '$($p.Name)' gespeichert: $(@(Get-HMSbCheckedVms).Count) VM(s)" 'Success'
    Update-HMSbHistory
}
function Edit-HMSbProfile {
    $p = Get-HMSbProfile
    if (-not $p) { Out-Console 'Kein Profil gewaehlt' 'Warning'; return }
    if ($script:JobRunning) { Out-Console 'Waehrend eines Vorgangs nicht moeglich.' 'Warning'; return }
    $cfg = Get-HMSbConfig
    $n = Show-TextInputDialog -Title 'Profil bearbeiten' -Label 'Name des Profils (frei waehlbar) - der Verlauf wird uebernommen:' -Text $p.Name
    if ($null -eq $n) { return }
    $n = "$n".Trim()
    if (-not $n) { Out-Console 'Name darf nicht leer sein' 'Error'; return }
    if ($n -ne $p.Name -and @($cfg.Profiles | Where-Object { $_.Name -eq $n }).Count) { Out-Console "Profil '$n' gibt es bereits" 'Error'; return }
    $pre = Read-HMSbPrefix $p.DiskPrefix
    if (-not $pre) { return }
    $cnt = Read-HMSbDiskCount $p.Disks
    if (-not $cnt) { return }
    $w = Show-TextInputDialog -Title 'Warnung' -Label 'Warnen, wenn die letzte erfolgreiche Sicherung aelter ist als (Tage):' -Text "$($p.WarnDays)"
    if ($null -eq $w) { return }
    $wd = 0
    if (-not [int]::TryParse("$w".Trim(), [ref]$wd) -or $wd -lt 1 -or $wd -gt 365) { Out-Console "Ungueltige Tage '$w' (1-365)" 'Error'; return }
    foreach ($x in $cfg.Profiles) { if ($x.Name -eq $p.Name) { $x.Name = $n; $x.DiskPrefix = $pre; $x.Disks = $cnt; $x.WarnDays = $wd } }
    if ($n -ne $p.Name) { $cfg.Renames = @(@($cfg.Renames) | Where-Object { $_.Old -ne $n }) + @([pscustomobject]@{ Old = $p.Name; New = $n }) }
    if ($cfg.LastProfile -eq $p.Name) { $cfg.LastProfile = $n }
    Save-HMSbConfig $cfg
    if ($n -ne $p.Name) {
        # Verlauf und Profil-Kopien mitnehmen: Tool-Ordner + alle angesteckten Platten
        $cnt2 = 0
        $files = @($script:SbHistFile)
        foreach ($d in @($script:SbDrives)) { $files += "$($d.Letter):\$($script:SbDirName)\history.json"; $files += "$($d.Letter):\$($script:SbDirName)\profiles.json" }
        foreach ($f in $files) { try { $cnt2 += (Rename-HMSbProfileInFile $f $p.Name $n) } catch { Out-Console "Umbenennen in $f`: $($_.Exception.Message)" 'Warning' } }
        Out-Console "Profil '$($p.Name)' umbenannt in '$n' - $cnt2 Verlaufseintrag/-eintraege angepasst (Tool-Ordner und angesteckte Platten; nicht angesteckte Platten beim naechsten Backup)" 'Success'
    }
    Out-Console "Profil '$n': Platten $pre-1 bis $pre-$cnt, Warnung nach $wd Tagen" 'Success'
    Update-HMSbProfileList $n
}
function Remove-HMSbProfile {
    $p = Get-HMSbProfile
    if (-not $p) { return }
    if (-not (Confirm-Action "Profil '$($p.Name)' loeschen?`n`nSicherungen und Verlauf auf den Platten bleiben erhalten.")) { return }
    $cfg = Get-HMSbConfig
    $cfg.Profiles = @($cfg.Profiles | Where-Object { $_.Name -ne $p.Name })
    if ($cfg.LastProfile -eq $p.Name) { $cfg.LastProfile = '' }
    Save-HMSbConfig $cfg
    Out-Console "Profil '$($p.Name)' geloescht" 'Info'
    Update-HMSbProfileList
}

# ----------------------------------------------------------------------------
# VMs / Laufwerke / Anzeige
# ----------------------------------------------------------------------------
function Add-HMSbInfoText([string]$Text, [string]$Color = '#FFA6ADC8') {
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $Text; $tb.Foreground = New-Brush $Color; $tb.TextWrapping = 'Wrap'
    [void]$ui.pnlSbVms.Children.Add($tb)
}
function Update-HMSbVms {
    $ui.pnlSbVms.Children.Clear()
    Add-HMSbInfoText 'VMs werden gelesen ...'
    Invoke-AsyncCommand -ScriptBlock { param($eng) . $eng; Get-HMSbVmList } -ArgumentList @($script:SbEngine) -TimeoutSec 120 -OnComplete {
        param($r)
        $ui.pnlSbVms.Children.Clear()
        if ($r -is [string]) { $script:SbVms = @(); Add-HMSbInfoText "VMs nicht lesbar: $r" '#FFF38BA8'; return }
        $script:SbVms = @($r | Where-Object { $_ -and $_.Name })
        foreach ($v in $script:SbVms) {
            $cb = New-Object System.Windows.Controls.CheckBox
            $cb.Content = ('{0}   [{1}]   {2:N1} GB{3}' -f $v.Name, (Format-HMSbState $v.State), ($v.SizeBytes / 1GB), $(if ([int]$v.Checkpoints) { "   $($v.Checkpoints) Pruefpunkt(e)" } else { '' }))
            $cb.Tag = $v.Name
            $cb.ToolTip = "Speicherort: $($v.VmPath)`nFestplatten: $(@($v.Paths) -join ', ')"
            $cb.Add_Click({ Update-HMSbSize })
            [void]$ui.pnlSbVms.Children.Add($cb)
        }
        if (-not $script:SbVms.Count) { Add-HMSbInfoText 'Keine VMs auf diesem Host gefunden.' '#FFF9E2AF' }
        $ui.lblSbHost.Text = "Host $env:COMPUTERNAME - $($script:SbVms.Count) VM(s)" + $(if ($script:SbPrereq) { " - Windows Server-Sicherung: $(if ($script:SbPrereq.Feature -eq $false) { 'FEHLT' } elseif ($script:SbPrereq.Wbadmin) { 'OK' } else { 'FEHLT' })" } else { '' })
        Set-HMSbFromProfile
    }
}
function Format-HMSbDrive($d) {
    return ('{0}:  {1}   {2} frei von {3}   {4} {5}' -f $d.Letter, $(if ($d.Label) { $d.Label } else { '(ohne Bezeichnung)' }), (Format-HMSize $d.Free), (Format-HMSize $d.Size), $d.Bus, $d.Model).Trim()
}
function Get-HMSbDrive {
    $i = $ui.cmbSbDrive.SelectedIndex
    $list = @($script:SbDrives)
    if ($i -ge 0 -and $i -lt $list.Count) { return $list[$i] }
    return $null
}
function Update-HMSbDrives {
    $script:SbSuppressDrive = $true
    $ui.cmbSbDrive.Items.Clear()
    [void]$ui.cmbSbDrive.Items.Add('(Laufwerke werden gelesen ...)')
    $ui.cmbSbDrive.SelectedIndex = 0
    $script:SbDrives = @()
    $script:SbSuppressDrive = $false
    Invoke-AsyncCommand -ScriptBlock { param($eng) . $eng; Get-HMSbDriveList } -ArgumentList @($script:SbEngine) -TimeoutSec 60 -OnComplete {
        param($r)
        $script:SbSuppressDrive = $true
        $ui.cmbSbDrive.Items.Clear()
        if ($r -is [string] -or $null -eq $r) { Out-Console "Server-Backup: Laufwerke nicht lesbar: $r" 'Error'; $script:SbDrives = @() }
        else {
            foreach ($m in @($r.Messages)) { if ($m) { Out-Console $m 'Warning' } }
            $script:SbDrives = @($r.Drives | Where-Object { $_ })
            # umbenannte Platten: Verlaufseintraege auf den aktuellen Namen bringen
            foreach ($d in $script:SbDrives) {
                try { $c = Sync-HMSbDiskLabel $d.Letter $d.Label $script:SbHistFile; if ($c) { Out-Console "Platte $($d.Letter): heisst jetzt '$($d.Label)' - $c Verlaufseintrag/-eintraege angepasst" 'Info' } }
                catch { Out-Console "Verlauf der Platte $($d.Letter): $($_.Exception.Message)" 'Warning' }
            }
        }
        foreach ($d in $script:SbDrives) { [void]$ui.cmbSbDrive.Items.Add((Format-HMSbDrive $d)) }
        if (-not $script:SbDrives.Count) { [void]$ui.cmbSbDrive.Items.Add('(keine Platte gefunden - USB-Platte anstecken, dann Aktualisieren)'); $ui.cmbSbDrive.SelectedIndex = 0 }
        $script:SbSuppressDrive = $false
        Select-HMSbDriveForProfile
        Update-HMSbHistory
        Import-HMSbDiskProfiles
    }
}
# Profile von angesteckten Platten anbieten, die es am Host nicht gibt (z.B. nach Neuinstallation)
function Import-HMSbDiskProfiles {
    if (-not $script:SbImportAsked) { $script:SbImportAsked = @{} }
    $cfg = Get-HMSbConfig
    $added = @()
    foreach ($d in @($script:SbDrives)) {
        $list = Read-HMSbDiskProfiles "$($d.Letter):\$($script:SbDirName)"
        foreach ($x in @($list)) {
            if (-not $x -or -not "$($x.Name)".Trim()) { continue }
            $n = Get-HMSbCurrentName "$($x.Name)".Trim() @($cfg.Renames)
            if (@($cfg.Profiles | Where-Object { $_.Name -eq $n }).Count) { continue }
            $key = "$($d.Letter)|$n"
            if ($script:SbImportAsked.ContainsKey($key)) { continue }
            $script:SbImportAsked[$key] = $true
            $pr = ConvertTo-HMSbProfile $x
            $pr.Name = $n
            if (Confirm-Action "Auf der Platte $($d.Letter): $($d.Label) ist das Server-Backup-Profil '$n' gespeichert, das es auf diesem Host nicht gibt.`n`nPlatten: $($pr.DiskPrefix)-1 bis -$($pr.Disks)`nVMs: $(@($pr.VMs) -join ', ')`n`nProfil uebernehmen?" 'Server-Backup') {
                $cfg.Profiles = @($cfg.Profiles) + @($pr)
                $added += $n
            }
        }
    }
    if ($added.Count) {
        Save-HMSbConfig $cfg
        Out-Console "Profil(e) von der Platte uebernommen: $($added -join ', ')" 'Success'
        Update-HMSbProfileList $added[0]
    }
}
function Select-HMSbDriveForProfile {
    $p = Get-HMSbProfile
    $list = @($script:SbDrives)
    if ($p -and $list.Count) {
        for ($i = 0; $i -lt $list.Count; $i++) {
            if (Test-HMSbLabelMatch $list[$i].Label $p.DiskPrefix) { $script:SbSuppressDrive = $true; $ui.cmbSbDrive.SelectedIndex = $i; $script:SbSuppressDrive = $false; break }
        }
    }
    if ($list.Count -and $ui.cmbSbDrive.SelectedIndex -lt 0) { $ui.cmbSbDrive.SelectedIndex = 0 }
    Update-HMSbDiskInfo
}
function Update-HMSbDiskInfo {
    $d = Get-HMSbDrive
    $p = Get-HMSbProfile
    if (-not $d) { $ui.lblSbDiskInfo.Text = 'Keine Ziel-Platte - USB-Platte anstecken und "Aktualisieren" druecken.'; $ui.lblSbDiskInfo.Foreground = New-Brush '#FFF9E2AF'; return }
    $t = ''; $col = '#FFA6ADC8'
    if (-not $p) { $t = "Platte $($d.Label) - kein Profil gewaehlt (mit ""Neu ..."" anlegen)"; $col = '#FFF9E2AF' }
    elseif (Test-HMSbLabelMatch $d.Label $p.DiskPrefix) {
        $t = "Platte des Profils erkannt: $($d.Label)"
        if ($d.Model -or $d.Serial) { $t += "  ($($d.Model)$(if ($d.Serial) { ", SN $($d.Serial)" }))" }
        $col = '#FFA6E3A1'
    } else {
        $t = "ACHTUNG: '$($d.Label)' ist keine Platte des Profils '$($p.Name)' ($($p.DiskPrefix)-1 bis -$($p.Disks)). Neue Platte? -> ""Platte einrichten ..."""
        $col = '#FFFAB387'
    }
    if ($d.FileSystem -and $d.FileSystem -notmatch '^(NTFS|ReFS)$') { $t += "  |  Dateisystem $($d.FileSystem) wird nicht unterstuetzt (NTFS noetig)"; $col = '#FFF38BA8' }
    if ($d.Bus -and $d.Bus -notmatch '^(USB|7)$') { $t += "  |  kein USB-Datentraeger ($($d.Bus))" }
    $ui.lblSbDiskInfo.Text = $t
    $ui.lblSbDiskInfo.Foreground = New-Brush $col
}
function Update-HMSbSize {
    $sel = @(Get-HMSbCheckedVms)
    $sum = [long]0
    foreach ($n in $sel) { $v = @($script:SbVms | Where-Object { $_.Name -eq $n })[0]; if ($v) { $sum += [long]$v.SizeBytes } }
    $t = "$($sel.Count) VM(s) gewaehlt - virtuelle Festplatten ca. $(Format-HMSize $sum)"
    $d = Get-HMSbDrive
    if ($d) { $t += " - Platte $($d.Letter): $(Format-HMSize $d.Free) frei" }
    $ui.lblSbSize.Text = $t
}

# ----------------------------------------------------------------------------
# Verlauf / Statistik
# ----------------------------------------------------------------------------
function Get-HMSbAllHistory {
    $all = @()
    $h = Read-HMSbHistory $script:SbHistFile
    $all += @($h)
    foreach ($d in @($script:SbDrives)) {
        $f = "$($d.Letter):\$($script:SbDirName)\history.json"
        if (Test-Path -LiteralPath $f) { $h2 = Read-HMSbHistory $f; $all += @($h2) }
    }
    $ren = @((Get-HMSbConfig).Renames)
    $seen = @{}; $out = @()
    foreach ($e in $all) {
        if (-not $e) { continue }
        if ($ren.Count -and $e.PSObject.Properties['Profile']) { $e.Profile = Get-HMSbCurrentName "$($e.Profile)" $ren }
        $k = "$($e.Date)|$($e.Host)|$($e.Profile)|$($e.Disk)"
        if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; $out += $e }
    }
    return ,@($out | Sort-Object { "$($_.Date)" } -Descending)
}
function Update-HMSbHistory {
    $p = Get-HMSbProfile
    $all = Get-HMSbAllHistory
    $all = @($all)
    $rows = @()
    if (-not $p) { $ui.dgSbHistory.ItemsSource = $rows; $ui.lblSbDisks.Text = ''; $ui.lblSbHostSystem.Text = ''; return }
    $mine = @($all | Where-Object { "$($_.Profile)" -eq $p.Name })
    foreach ($e in @($mine | Select-Object -First 300)) {
        $rows += [pscustomobject]@{ Datum = "$($e.Date)"; Platte = "$($e.Disk)"; Status = (Format-HMSbStatus "$($e.Status)"); Minuten = $e.Minutes; GB = $e.SizeGB; VMs = "$($e.VMs)" }
    }
    $ui.dgSbHistory.ItemsSource = $rows
    # Plattenstatus + Rotationsempfehlung
    $labels = @(1..$p.Disks | ForEach-Object { "$($p.DiskPrefix)-$_" })
    foreach ($x in @($mine | ForEach-Object { "$($_.Disk)" } | Where-Object { $_ } | Select-Object -Unique)) { if ($labels -notcontains $x) { $labels += $x } }
    $parts = @(); $oldest = $null; $oldestDate = [datetime]::MaxValue
    foreach ($lb in $labels) {
        $last = @($mine | Where-Object { "$($_.Disk)" -eq $lb -and "$($_.Status)" -ne 'Error' })[0]
        $dt = if ($last) { Get-HMSbDate "$($last.Date)" } else { $null }
        if ($dt) {
            $age = [int][Math]::Floor(((Get-Date) - $dt).TotalDays)
            $parts += "$lb`: $($dt.ToString('dd.MM.yyyy')) (vor $age Tag$(if ($age -ne 1) { 'en' }))"
            if ($dt -lt $oldestDate) { $oldestDate = $dt; $oldest = $lb }
        } else {
            $parts += "$lb`: noch keine Sicherung"
            if ($oldestDate -ne [datetime]::MinValue) { $oldestDate = [datetime]::MinValue; $oldest = $lb }
        }
    }
    $t = ($parts -join '   |   ')
    $lastOk = @($mine | Where-Object { "$($_.Status)" -ne 'Error' })[0]
    $col = '#FFCDD6F4'
    if (-not $lastOk) { $t += "`nNoch keine erfolgreiche Sicherung fuer '$($p.Name)'."; $col = '#FFF9E2AF' }
    else {
        $ld = Get-HMSbDate "$($lastOk.Date)"
        if ($ld) {
            $age = [int][Math]::Floor(((Get-Date) - $ld).TotalDays)
            if ($age -gt $p.WarnDays) { $t += "`nLetzte erfolgreiche Sicherung vor $age Tagen - aelter als $($p.WarnDays) Tage!"; $col = '#FFFAB387' }
        }
    }
    if ($oldest -and $labels.Count -gt 1) { $t += "`nNaechste Platte laut Rotation: $oldest (am laengsten nicht verwendet)" }
    $ui.lblSbDisks.Text = $t
    $ui.lblSbDisks.Foreground = New-Brush $col
    $hs = @($mine | Where-Object { $_.HostSystem -eq $true })[0]
    $ui.lblSbHostSystem.Text = $(if ($hs) { "letzte Host-System-Sicherung: $($hs.Date) auf $($hs.Disk)" } else { 'noch keine Host-System-Sicherung' })
}
function Show-HMSbOverview {
    $all = Get-HMSbAllHistory
    $all = @($all)
    if (-not $all.Count) { Out-Console 'Server-Backup: noch kein Verlauf vorhanden (Tool-Ordner und angesteckte Platten).' 'Info'; return }
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($g in @($all | Group-Object { "$($_.Profile)|$($_.Disk)" })) {
        $items = @($g.Group | Sort-Object { "$($_.Date)" } -Descending)
        $last = $items[0]
        $ok = @($items | Where-Object { "$($_.Status)" -ne 'Error' })
        $lastOk = $ok | Select-Object -First 1
        $age = $null
        if ($lastOk) { $dt = Get-HMSbDate "$($lastOk.Date)"; if ($dt) { $age = [int][Math]::Floor(((Get-Date) - $dt).TotalDays) } }
        $avg = 0.0
        if ($ok.Count) { try { $avg = [math]::Round([double](@($ok | ForEach-Object { [double]$_.Minutes }) | Measure-Object -Average).Average, 1) } catch { } }
        $hs = @($items | Where-Object { $_.HostSystem -eq $true })[0]
        $rows.Add(@("$($last.Profile)", "$($last.Disk)", "$($last.Host)", $(if ($lastOk) { "$($lastOk.Date)" } else { '-' }), $age, (Format-HMSbStatus "$($last.Status)"), $items.Count, $avg, "$($last.SizeGB)", $(if ($hs) { "$($hs.Date)" } else { '' })))
    }
    Show-DataGridWindow -Title 'Server-Backup - Statistik je Profil und Platte' -Width 1100 -Height 520 `
        -Columns @('Profil', 'Platte', 'Host', 'Letzte_Sicherung', 'Tage', 'Letzter_Status', 'Laeufe', 'Mittel_Min', 'GB', 'Host_System') `
        -Rows $rows.ToArray() -Sort 'Profil ASC, Platte ASC' -ColumnTypes @{ Tage = [int]; Laeufe = [int]; Mittel_Min = [double] } `
        -CountText "$($rows.Count) Platte(n), $($all.Count) Laeufe (Tool-Ordner + angesteckte Platten)" `
        -Actions @(@{ Text = 'Alle Laeufe anzeigen'; Color = '#FFCBA6F7'; NoSelection = $true; Handler = { param($r, $w, $c) Show-HMSbAllRuns } })
}
function Show-HMSbAllRuns {
    $all = Get-HMSbAllHistory
    $all = @($all)
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($e in $all) {
        $rows.Add(@("$($e.Date)", "$($e.Profile)", "$($e.Host)", "$($e.Disk)", (Format-HMSbStatus "$($e.Status)"), "$($e.Minutes)", "$($e.SizeGB)", "$($e.VMs)",
                $(if ($e.HostConfig -eq $true) { 'ja' } else { '' }), $(if ($e.HostSystem -eq $true) { 'ja' } else { '' }), "$($e.VersionId)", "$($e.Note)", "$($e.Tool)"))
    }
    Show-DataGridWindow -Title 'Server-Backup - alle Laeufe' -Width 1250 -Height 600 `
        -Columns @('Datum', 'Profil', 'Host', 'Platte', 'Status', 'Minuten', 'GB', 'VMs', 'Host_Konfig', 'Host_System', 'Version', 'Hinweis', 'Tool') `
        -Rows $rows.ToArray() -Sort 'Datum DESC'
}

# ----------------------------------------------------------------------------
# Aktionen
# ----------------------------------------------------------------------------
function Start-HMSbBackup {
    if ($script:JobRunning) { Out-Console 'Es laeuft bereits ein Vorgang.' 'Warning'; return }
    $p = Get-HMSbProfile
    $d = Get-HMSbDrive
    $vms = @(Get-HMSbCheckedVms)
    $hc = [bool]$ui.chkSbHostConfig.IsChecked
    $hs = [bool]$ui.chkSbHostSystem.IsChecked
    if (-not $d) { Out-Console 'Server-Backup: keine Ziel-Platte gewaehlt.' 'Warning'; return }
    if ($d.FileSystem -and $d.FileSystem -notmatch '^(NTFS|ReFS)$') { Out-Console "Server-Backup: Dateisystem $($d.FileSystem) auf $($d.Letter): wird nicht unterstuetzt - Platte einrichten (NTFS)." 'Error'; return }
    if (-not $vms.Count -and -not $hs -and -not $hc) { Out-Console 'Server-Backup: nichts gewaehlt (VMs, Host-Konfiguration oder Host-System).' 'Warning'; return }
    if ($script:SbPrereq -and ($script:SbPrereq.Feature -eq $false -or -not $script:SbPrereq.Wbadmin)) { Out-Console 'Windows Server-Sicherung fehlt - Button "Windows Server-Sicherung installieren".' 'Error'; return }
    $pName = if ($p) { $p.Name } else { '(ohne Profil)' }
    $msg = "Server-Backup starten?`n`nProfil: $pName`nZiel: $($d.Letter): $($d.Label)`nVMs ($($vms.Count)): $(if ($vms.Count) { $vms -join ', ' } else { '-' })`nHost-Konfiguration: $(if ($hc) { 'ja' } else { 'nein' })`nHost-System (Bare-Metal): $(if ($hs) { 'ja' } else { 'nein' })`n`nDie VMs laufen weiter (Online-Sicherung ueber VSS)."
    if (-not $p) { $msg += "`n`nHinweis: kein Profil gewaehlt - Verlauf unter '(ohne Profil)'." }
    elseif (-not (Test-HMSbLabelMatch $d.Label $p.DiskPrefix)) { $msg += "`n`nACHTUNG: Die Platte '$($d.Label)' gehoert laut Bezeichnung NICHT zum Profil ($($p.DiskPrefix)-...)." }
    if ($p) {
        $a = @($p.VMs | Sort-Object) -join '|'; $b = @($vms | Sort-Object) -join '|'
        if ($a -ne $b) { $msg += "`n`nHinweis: Die VM-Auswahl weicht vom gespeicherten Profil ab (gilt nur fuer diesen Lauf - 'Profil speichern' uebernimmt sie)." }
    }
    if (-not (Confirm-Action $msg 'Server-Backup')) { return }
    if ($p) { Save-HMSbLastProfile $p.Name }
    $ctx = @{
        Profile = $pName; DiskPrefix = $(if ($p) { $p.DiskPrefix } else { '' }); Drive = $d.Letter; DiskLabel = $d.Label; DiskSerial = $d.Serial
        VMs = $vms; HostConfig = $hc; HostSystem = $hs; Verify = [bool]$ui.chkSbVerify.IsChecked
        LocalHistory = $script:SbHistFile; LocalReportDir = $script:SbReportDir; Version = $script:Version
        ProfileData = $(if ($p) { $p } else { $null })
    }
    Start-EngineJob -Command 'Start-HMServerBackup -Ctx $Ctx -Job $Job' -Ctx $ctx -Title 'Server-Backup' -ScriptFiles @($script:SbEngine) -OnFinished {
        param($j)
        Update-HMSbHistory
        if ($j.Result -and $j.Result.Report) { Out-Console "Berichtsordner: $($j.Result.Report)" 'Info' }
    }
}

function Show-HMSbDiskSetup {
    if ($script:JobRunning) { Out-Console 'Waehrend eines Vorgangs nicht moeglich.' 'Warning'; return }
    Out-Console 'Server-Backup: USB-Datentraeger werden gelesen ...' 'Info'
    Invoke-AsyncCommand -ScriptBlock { param($eng) . $eng; Get-HMSbDiskList } -ArgumentList @($script:SbEngine) -TimeoutSec 90 -OnComplete {
        param($r)
        if ($r -is [string]) { Out-Console "Datentraeger nicht lesbar: $r" 'Error'; return }
        $disks = @($r | Where-Object { $_ })
        if (-not $disks.Count) { Out-Console 'Kein USB-Datentraeger gefunden (System-/Startplatten und Platten mit VM-Dateien werden nie angezeigt).' 'Warning'; return }
        $rows = New-Object System.Collections.Generic.List[object]
        foreach ($d in $disks) { $rows.Add(@([int]$d.Number, $d.Model, $d.Serial, (Format-HMSize $d.SizeBytes), $d.Style, $d.Volumes, $(if ($d.Offline) { 'offline' } else { '' }))) }
        Show-DataGridWindow -Title 'USB-Platte fuer Server-Backup einrichten (ALLE DATEN WERDEN GELOESCHT)' -Width 1000 -Height 380 `
            -Columns @('Nr', 'Modell', 'Seriennummer', 'Groesse', 'Partitionsstil', 'Volumes', 'Status') -Rows $rows.ToArray() -ColumnTypes @{ Nr = [int] } `
            -CountText 'Platte markieren, dann "Einrichten ..."' `
            -Actions @(@{ Text = 'Einrichten ...'; Color = '#FFFAB387'; Handler = { param($sel, $w, $c) Invoke-HMSbDiskSetup $sel $w } })
    }
}
function Get-HMSbNextLabel($p) {
    if (-not $p) { return 'HUMIG-BACKUP-1' }
    $used = @()
    $all = Get-HMSbAllHistory
    $used += @(@($all) | Where-Object { "$($_.Profile)" -eq $p.Name } | ForEach-Object { "$($_.Disk)" })
    $used += @($script:SbDrives | ForEach-Object { "$($_.Label)" })
    for ($i = 1; $i -le 30; $i++) { $l = "$($p.DiskPrefix)-$i"; if (-not (@($used) -contains $l)) { return $l } }
    return "$($p.DiskPrefix)-1"
}
function Invoke-HMSbDiskSetup($Sel, $Win) {
    $row = @($Sel)[0]
    if (-not $row) { return }
    $num = [int]$row.Nr
    $p = Get-HMSbProfile
    $label = Show-TextInputDialog -Title 'Platte einrichten' -Label "Bezeichnung fuer Datentraeger $num ($($row.Modell), $($row.Groesse)):" -Text (Get-HMSbNextLabel $p) -Owner $Win
    if ($null -eq $label) { return }
    $label = "$label".Trim().ToUpper()
    if ($label -notmatch '^[A-Z0-9_\-]{1,32}$') { [void][System.Windows.MessageBox]::Show($Win, "Ungueltige Bezeichnung '$label' (max. 32 Zeichen: A-Z, 0-9, - und _)", 'Platte einrichten', 'OK', 'Warning'); return }
    $chk = Show-TextInputDialog -Title 'Sicherheitsabfrage' -Label "ALLE DATEN auf Datentraeger $num werden geloescht:`n$($row.Modell), SN $($row.Seriennummer), $($row.Groesse)`nVolumes: $($row.Volumes)`n`nZum Bestaetigen die Nummer des Datentraegers ($num) eingeben:" -Owner $Win
    if ("$chk".Trim() -ne "$num") { Out-Console 'Platte einrichten abgebrochen (Bestaetigung falsch).' 'Warning'; return }
    try { $Win.Close() } catch { }
    Out-Console "Datentraeger $num wird eingerichtet ($label) ..." 'Warning'
    Set-Status "Platte $label wird eingerichtet ..." '#FFF9E2AF'
    Invoke-AsyncCommand -ScriptBlock { param($eng, $n, $l, $pn) . $eng; Initialize-HMSbDisk -Number $n -Label $l -Profile $pn } -ArgumentList @($script:SbEngine, $num, $label, $(if ($p) { $p.Name } else { '' })) -TimeoutSec 900 -OnComplete {
        param($r)
        if ($r -is [string]) { Out-Console "Platte einrichten FEHLGESCHLAGEN: $r" 'Error'; Set-Status 'Platte einrichten fehlgeschlagen' '#FFF38BA8' }
        else { Out-Console "Platte eingerichtet: $($r.Letter): $($r.Label) ($(Format-HMSize $r.SizeBytes), NTFS 64K)" 'Success'; Set-Status 'Platte eingerichtet' '#FFA6E3A1' }
        Update-HMSbDrives
    }
}

function Invoke-HMSbEject {
    if ($script:JobRunning) { Out-Console 'Waehrend eines Vorgangs nicht moeglich.' 'Warning'; return }
    $d = Get-HMSbDrive
    if (-not $d) { return }
    $L = $d.Letter
    try { Write-VolumeCache -DriveLetter $L -ErrorAction Stop; Out-Console "Schreibcache von ${L}: geleert" 'Info' } catch { Out-Console "Schreibcache ${L}: $($_.Exception.Message)" 'Warning' }
    try {
        $sh = New-Object -ComObject Shell.Application
        $item = $sh.Namespace(17).ParseName("${L}:")
        if ($item) { $item.InvokeVerb('Eject') }
    } catch { Out-Console "Auswerfen: $($_.Exception.Message)" 'Warning' }
    $script:SbEjectLetter = $L
    $script:SbEjectLabel = $d.Label
    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromSeconds(4)
    $t.Add_Tick({
        param($src)
        $src.Stop()
        $L = $script:SbEjectLetter
        if (Test-Path -LiteralPath "${L}:\") {
            Out-Console "Platte ${L}: ($($script:SbEjectLabel)) wurde von Windows NICHT ausgeworfen (wird noch verwendet?). Schreibcache ist geleert - Explorer: Rechtsklick > Auswerfen, oder Datentraegerverwaltung > Offline." 'Warning'
        } else {
            Out-Console "Platte $($script:SbEjectLabel) ausgeworfen - kann jetzt abgezogen werden." 'Success'
            [System.Media.SystemSounds]::Asterisk.Play()
        }
        Update-HMSbDrives
    })
    $t.Start()
}

function Show-HMSbVersions {
    $d = Get-HMSbDrive
    if (-not $d) { Out-Console 'Keine Ziel-Platte gewaehlt.' 'Warning'; return }
    Out-Console "Versionen auf $($d.Letter): werden gelesen ..." 'Info'
    Invoke-AsyncCommand -ScriptBlock { param($eng, $t) . $eng; Get-HMSbVersions $t } -ArgumentList @($script:SbEngine, "$($d.Letter):") -TimeoutSec 120 -State $d -OnComplete {
        param($r, $d)
        if ($r -is [string]) { Out-Console "Versionen: $r" 'Error'; return }
        $v = @($r.Versions)
        if (-not $v.Count) { Out-Console "Keine Sicherungsversionen auf $($d.Letter): ($($d.Label)) gefunden. wbadmin: $("$($r.Text)" -replace '\s+', ' ')" 'Warning'; return }
        $rows = New-Object System.Collections.Generic.List[object]
        foreach ($x in $v) { $rows.Add(@("$($x.Time)", "$($x.Id)", "$($x.Items)")) }
        Show-DataGridWindow -Title "Sicherungsversionen auf $($d.Letter): $($d.Label)" -Width 900 -Height 420 -Columns @('Sicherungszeit', 'Versions_ID', 'Wiederherstellbar') -Rows $rows.ToArray() -CountText "$($v.Count) Version(en) - Versions-ID ist UTC"
    }
}

function Start-HMSbHostOnly {
    $d = Get-HMSbDrive
    $base = if ($d) { "$($d.Letter):\$($script:SbDirName)" } else { $script:SbReportDir }
    $dest = Join-Path $base ('Host-Konfiguration_{0}_{1}' -f $env:COMPUTERNAME, (Get-Date -Format 'yyyy-MM-dd_HHmm'))
    Out-Console "Host-Konfiguration wird exportiert -> $dest" 'Info'
    Invoke-AsyncCommand -ScriptBlock { param($eng, $dst) . $eng; Export-HMSbHostConfig -Dest $dst } -ArgumentList @($script:SbEngine, $dest) -TimeoutSec 300 -OnComplete {
        param($r)
        if ($r -is [string]) { Out-Console "Host-Konfiguration: $r" 'Error'; return }
        Out-Console "Host-Konfiguration: $($r.Switches) Switch(es), $($r.ManagementAdapters) Host-vNIC(s), $($r.VMs) VM(s) -> $($r.Folder)" 'Success'
        foreach ($w in @($r.Warnings)) { if ($w) { Out-Console "  $w" 'Warning' } }
        $h = Join-Path $r.Folder 'HostConfig.html'
        if (Test-Path -LiteralPath $h) { try { Start-Process $h } catch { } }
    }
}

function Show-HMSbRestoreHelp {
    $txt = "VM wiederherstellen (Windows Server-Sicherung):`n`n" +
        "1. Platte anstecken. Fehlen am Host die virtuellen Switches (neu installierter Host): zuerst Restore-VMSwitches.ps1 aus dem Berichtsordner (HUMig-ServerBackup\...\Host-Konfiguration) pruefen und als Administrator ausfuehren.`n" +
        "2. In der Windows Server-Sicherung rechts 'Wiederherstellen ...'.`n" +
        "3. 'Eine an einem anderen Speicherort gespeicherte Sicherung' > 'Lokale Laufwerke' > Platte waehlen (auf demselben Host geht auch 'Dieser Server').`n" +
        "4. Datum/Uhrzeit der Sicherung waehlen (Button 'Versionen auf der Platte' zeigt alle).`n" +
        "5. Wiederherstellungstyp 'Hyper-V' > VM(s) auswaehlen.`n" +
        "6. 'Am urspruenglichen Speicherort' (ueberschreibt die vorhandene VM!) oder 'An anderem Speicherort'.`n`n" +
        "Hinweis: Ein aelterer MS-Artikel (KB 958662, Server 2008) nennt Einschraenkungen bei VMs mit 2 oder mehr Pruefpunkten - fuer aktuelle Server nicht belegt. Wiederherstellung einmal testen (z.B. an anderem Speicherort).`n`n" +
        'Windows Server-Sicherung jetzt oeffnen?'
    if ([System.Windows.MessageBox]::Show($script:Window, $txt, 'Server-Backup - Wiederherstellen', 'YesNo', 'Information') -eq 'Yes') {
        try { Start-Process 'wbadmin.msc' } catch { Out-Console "wbadmin.msc: $($_.Exception.Message) - Feature 'Windows Server-Sicherung' installiert?" 'Error' }
    }
}

function Install-HMSbFeature {
    if (-not (Confirm-Action "Feature 'Windows Server-Sicherung' (Windows-Server-Backup) jetzt installieren?`nKein Neustart noetig.")) { return }
    Out-Console 'Windows Server-Sicherung wird installiert ...' 'Info'
    Set-Status 'Windows Server-Sicherung wird installiert ...' '#FFF9E2AF'
    Invoke-AsyncCommand -ScriptBlock {
        try { $r = Install-WindowsFeature -Name Windows-Server-Backup -IncludeManagementTools -ErrorAction Stop; return "OK:$($r.Success):$($r.RestartNeeded)" } catch { return "FEHLER: $($_.Exception.Message)" }
    } -TimeoutSec 1800 -OnComplete {
        param($r)
        if ("$r" -like 'OK:True*') { Out-Console "Windows Server-Sicherung installiert$(if ("$r" -match ':Yes$') { ' - Neustart erforderlich' })" 'Success'; Set-Status 'Windows Server-Sicherung installiert' '#FFA6E3A1' }
        else { Out-Console "Installation: $r" 'Error'; Set-Status 'Installation fehlgeschlagen' '#FFF38BA8' }
        Update-HMSbPrereq
    }
}

function Update-HMSbPrereq {
    Invoke-AsyncCommand -ScriptBlock { param($eng) . $eng; Test-HMSbPrereq } -ArgumentList @($script:SbEngine) -TimeoutSec 60 -OnComplete {
        param($r)
        if ($r -is [string]) { Out-Console "Server-Backup Pruefung: $r" 'Warning'; return }
        $script:SbPrereq = $r
        $missing = ($r.Feature -eq $false -or -not $r.Wbadmin)
        $ui.btnSbFeature.Visibility = $(if ($missing -and $r.IsServer) { 'Visible' } else { 'Collapsed' })
        if ($missing) { Out-Console "Server-Backup: Windows Server-Sicherung ist nicht installiert$(if ($r.IsServer) { ' - Button ""Windows Server-Sicherung installieren""' } else { ' (nur auf Windows Server verfuegbar)' })." 'Warning' }
        $ui.lblSbHost.Text = "Host $env:COMPUTERNAME - $(@($script:SbVms).Count) VM(s) - Windows Server-Sicherung: $(if ($missing) { 'FEHLT' } else { 'OK' })"
    }
}

function Update-HMSbAll {
    Update-HMSbPrereq
    Update-HMSbProfileList
    Update-HMSbVms
    Update-HMSbDrives
}

# ----------------------------------------------------------------------------
# Zeitplan: geplante Aufgabe (SYSTEM) startet Functions\ServerBackup-Task.ps1
# ----------------------------------------------------------------------------
$script:SbTaskPath = '\HUMig\'
function Show-HMSbScheduleDialog([string]$Info) {
    $x = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Server-Backup planen" Width="560" SizeToContent="Height" ResizeMode="NoResize" WindowStartupLocation="CenterOwner" Background="#FF1E1E2E">
  <StackPanel Margin="14">
    <TextBlock x:Name="info" Foreground="#FFCDD6F4" TextWrapping="Wrap" Margin="0,0,0,12"/>
    <RadioButton x:Name="rbOnce" Content="Einmalig am (TT.MM.JJJJ)" IsChecked="True" Foreground="#FFCDD6F4" Margin="0,2"/>
    <TextBox x:Name="txtDate" Width="120" HorizontalAlignment="Left" Margin="22,2,0,6" Background="#FF313244" Foreground="#FFCDD6F4" BorderBrush="#FF585B70" CaretBrush="#FFCDD6F4" Padding="4,2"/>
    <RadioButton x:Name="rbDaily" Content="Taeglich" Foreground="#FFCDD6F4" Margin="0,2"/>
    <RadioButton x:Name="rbWeekly" Content="Woechentlich an" Foreground="#FFCDD6F4" Margin="0,2"/>
    <WrapPanel x:Name="pnlDays" Margin="22,2,0,6"/>
    <StackPanel Orientation="Horizontal" Margin="0,6,0,10">
      <TextBlock Text="Uhrzeit (HH:MM):" Foreground="#FFA6ADC8" VerticalAlignment="Center" Margin="0,0,8,0"/>
      <TextBox x:Name="txtTime" Width="70" Text="22:00" Background="#FF313244" Foreground="#FFCDD6F4" BorderBrush="#FF585B70" CaretBrush="#FFCDD6F4" Padding="4,2"/>
    </StackPanel>
    <TextBlock Foreground="#FF6C7086" TextWrapping="Wrap" Margin="0,0,0,12" Text="Die Aufgabe laeuft als SYSTEM ohne Anmeldung (auch nach Neustart). Zur Startzeit muss eine Platte des Profils angesteckt sein - sonst wird ein Fehler im Verlauf eingetragen. Protokoll: Logs\ServerBackup\Aufgabe_*.log"/>
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
    $txtDate = $w.FindName('txtDate'); $txtTime = $w.FindName('txtTime')
    $txtDate.Text = (Get-Date).ToString('dd.MM.yyyy')
    $days = @(@('Monday', 'Mo'), @('Tuesday', 'Di'), @('Wednesday', 'Mi'), @('Thursday', 'Do'), @('Friday', 'Fr'), @('Saturday', 'Sa'), @('Sunday', 'So'))
    $pnl = $w.FindName('pnlDays')
    foreach ($d in $days) { $cb = New-Object System.Windows.Controls.CheckBox; $cb.Content = $d[1]; $cb.Tag = $d[0]; $cb.Foreground = New-Brush '#FFCDD6F4'; $cb.Margin = [System.Windows.Thickness]::new(0, 0, 10, 0); [void]$pnl.Children.Add($cb) }
    $res = @{ V = $null }
    $rbOnce = $w.FindName('rbOnce'); $rbDaily = $w.FindName('rbDaily'); $rbWeekly = $w.FindName('rbWeekly')
    $w.FindName('ok').Add_Click({
        $t = [datetime]::MinValue
        if (-not [datetime]::TryParseExact("$($txtTime.Text)".Trim(), 'H:mm', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$t)) {
            [void][System.Windows.MessageBox]::Show($w, 'Uhrzeit bitte als HH:MM eingeben (z.B. 22:00).', 'Zeitplan', 'OK', 'Warning'); return
        }
        $mode = if ($rbDaily.IsChecked) { 'Daily' } elseif ($rbWeekly.IsChecked) { 'Weekly' } else { 'Once' }
        $at = (Get-Date).Date.AddHours($t.Hour).AddMinutes($t.Minute)
        $sel = @()
        if ($mode -eq 'Once') {
            $dd = [datetime]::MinValue
            if (-not [datetime]::TryParseExact("$($txtDate.Text)".Trim(), 'd.M.yyyy', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$dd)) {
                [void][System.Windows.MessageBox]::Show($w, 'Datum bitte als TT.MM.JJJJ eingeben.', 'Zeitplan', 'OK', 'Warning'); return
            }
            $at = $dd.Date.AddHours($t.Hour).AddMinutes($t.Minute)
            if ($at -le (Get-Date)) { [void][System.Windows.MessageBox]::Show($w, 'Der Zeitpunkt liegt in der Vergangenheit.', 'Zeitplan', 'OK', 'Warning'); return }
        } elseif ($mode -eq 'Weekly') {
            $sel = @($pnl.Children | Where-Object { $_.IsChecked } | ForEach-Object { "$($_.Tag)" })
            if (-not $sel.Count) { [void][System.Windows.MessageBox]::Show($w, 'Mindestens einen Wochentag waehlen.', 'Zeitplan', 'OK', 'Warning'); return }
        }
        $res.V = @{ Mode = $mode; At = $at; Days = $sel }
        $w.DialogResult = $true
    }.GetNewClosure())
    $w.Owner = $script:Window; Set-HMWindowScale $w
    if ($w.ShowDialog() -eq $true) { return $res.V }
    return $null
}
function New-HMSbSchedule {
    $p = Get-HMSbProfile
    if (-not $p) { Out-Console 'Zeitplan: zuerst ein Profil waehlen/anlegen.' 'Warning'; return }
    $vms = @(Get-HMSbCheckedVms)
    $hc = [bool]$ui.chkSbHostConfig.IsChecked; $hs = [bool]$ui.chkSbHostSystem.IsChecked; $vf = [bool]$ui.chkSbVerify.IsChecked
    if (-not $vms.Count -and -not $hs -and -not $hc) { Out-Console 'Zeitplan: nichts gewaehlt (VMs, Host-Konfiguration oder Host-System).' 'Warning'; return }
    foreach ($x in @($p.Name) + $vms) { if ("$x" -match '["|]') { Out-Console "Zeitplan: Name '$x' enthaelt ein nicht erlaubtes Zeichen (Anfuehrungszeichen oder |)." 'Error'; return } }
    $info = "Profil: $($p.Name)   (Platten $($p.DiskPrefix)-...)`nVMs ($($vms.Count)): $(if ($vms.Count) { $vms -join ', ' } else { '-' })`nHost-Konfiguration: $(if ($hc) { 'ja' } else { 'nein' })   Pruefen: $(if ($vf) { 'ja' } else { 'nein' })   Host-System: $(if ($hs) { 'ja' } else { 'nein' })`n`nEs gelten die aktuell angehakten VMs und Optionen."
    $r = Show-HMSbScheduleDialog $info
    if (-not $r) { return }
    $task = Join-Path $script:AppRoot 'Functions\ServerBackup-Task.ps1'
    $arg = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$task`" -ProfileName `"$($p.Name)`""
    if ($vms.Count) { $arg += " -VMs `"$($vms -join '|')`"" }
    if ($hc) { $arg += ' -HostConfig' }
    if ($hs) { $arg += ' -HostSystem' }
    if (-not $vf) { $arg += ' -NoVerify' }
    $dayNames = @{ Monday = 'Mo'; Tuesday = 'Di'; Wednesday = 'Mi'; Thursday = 'Do'; Friday = 'Fr'; Saturday = 'Sa'; Sunday = 'So' }
    try {
        $a = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Argument $arg -WorkingDirectory $script:AppRoot
        $s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 23) -MultipleInstances IgnoreNew
        switch ($r.Mode) {
            'Once' {
                $t = New-ScheduledTaskTrigger -Once -At $r.At
                $t.EndBoundary = $r.At.AddDays(1).ToString('s')
                $s.DeleteExpiredTaskAfter = 'P7D'
                $when = 'einmalig ' + $r.At.ToString('dd.MM.yyyy HH-mm')
            }
            'Daily' { $t = New-ScheduledTaskTrigger -Daily -At $r.At; $when = 'taeglich ' + $r.At.ToString('HH-mm') }
            default { $t = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $r.Days -At $r.At; $when = (@($r.Days | ForEach-Object { $dayNames[$_] }) -join ',') + ' ' + $r.At.ToString('HH-mm') }
        }
        $pr = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $base = ('Server-Backup - {0} - {1}' -f ($p.Name -replace '[\\/:*?"<>|]', '_'), $when)
        $name = $base; $i = 2
        while (Get-ScheduledTask -TaskPath $script:SbTaskPath -TaskName $name -ErrorAction SilentlyContinue) { $name = "$base ($i)"; $i++ }
        $desc = "HUMig Server-Backup, Profil $($p.Name), VMs: $(if ($vms.Count) { $vms -join ', ' } else { '-' }). Verwalten: HUMig > Server-Backup > Zeitplan (Rechtsklick)."
        Register-ScheduledTask -TaskName $name -TaskPath $script:SbTaskPath -Action $a -Trigger $t -Principal $pr -Settings $s -Description $desc -ErrorAction Stop | Out-Null
        Out-Console "Geplant: '$name' (Aufgabenplanung \HUMig) - laeuft als SYSTEM, Protokoll Logs\ServerBackup\Aufgabe_*.log" 'Success'
    } catch { Out-Console "Zeitplan konnte nicht angelegt werden: $($_.Exception.Message)" 'Error' }
    Update-HMSbSchedules
}
function Get-HMSbScheduleRows {
    $rows = @()
    foreach ($t in @(Get-ScheduledTask -TaskPath $script:SbTaskPath -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like 'Server-Backup*' })) {
        $i = $null; try { $i = Get-ScheduledTaskInfo -TaskPath $t.TaskPath -TaskName $t.TaskName -ErrorAction Stop } catch { }
        $next = if ($i -and $i.NextRunTime) { $i.NextRunTime.ToString('dd.MM.yyyy HH:mm') } else { '' }
        $last = if ($i -and $i.LastRunTime -and $i.LastRunTime.Year -gt 2000) { $i.LastRunTime.ToString('dd.MM.yyyy HH:mm') } else { '' }
        $res = ''
        if ($last) { $res = switch ([int64]$i.LastTaskResult) { 0 { 'OK' } 1 { 'Warnung' } 2 { 'Fehler' } 267009 { 'laeuft' } default { '0x{0:X}' -f [int64]$i.LastTaskResult } } }
        $rows += [pscustomobject]@{ Name = $t.TaskName; State = "$($t.State)"; Next = $next; Last = $last; Result = $res; Args = "$(@($t.Actions)[0].Arguments)" }
    }
    return ,$rows
}
function Update-HMSbSchedules {
    try {
        $rows = Get-HMSbScheduleRows
        $rows = @($rows)
        $p = Get-HMSbProfile
        $mine = @($rows | Where-Object { -not $p -or $_.Name -like "Server-Backup - $($p.Name -replace '[\\/:*?"<>|]', '_') - *" })
        if ($mine.Count) {
            $ui.lblSbSchedule.Text = 'Geplant: ' + (@($mine | ForEach-Object { "$(($_.Name -split ' - ', 3)[-1])$(if ($_.Next) { " (naechster Lauf $($_.Next))" })$(if ($_.Result) { " letzter: $($_.Result)" })" }) -join '   |   ')
        } else { $ui.lblSbSchedule.Text = 'Kein Zeitplan fuer dieses Profil (Button Zeitplan ...)' }
    } catch { $ui.lblSbSchedule.Text = '' }
}
function Show-HMSbSchedules {
    $rows = Get-HMSbScheduleRows
    $rows = @($rows)
    if (-not $rows.Count) { Out-Console 'Keine geplanten Server-Backups (Aufgabenplanung \HUMig).' 'Info'; return }
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($r in $rows) { $list.Add(@($r.Name, $r.State, $r.Next, $r.Last, $r.Result, $r.Args)) }
    Show-DataGridWindow -Title 'Geplante Server-Backups (Aufgabenplanung \HUMig)' -Width 1200 -Height 420 `
        -Columns @('Name', 'Zustand', 'Naechster_Lauf', 'Letzter_Lauf', 'Ergebnis', 'Aufruf') -Rows $list.ToArray() `
        -CountText 'Ergebnis: OK / Warnung / Fehler - Details im Verlauf und in Logs\ServerBackup\Aufgabe_*.log' `
        -Actions @(
            @{ Text = 'Jetzt starten'; Color = '#FFA6E3A1'; Handler = { param($sel, $w, $c) foreach ($r in $sel) { try { Start-ScheduledTask -TaskPath $script:SbTaskPath -TaskName "$($r.Name)" -ErrorAction Stop; Out-Console "Gestartet: $($r.Name) (laeuft im Hintergrund als SYSTEM)" 'Success' } catch { Out-Console "$($r.Name): $($_.Exception.Message)" 'Error' } }; $w.Close(); Update-HMSbSchedules } },
            @{ Text = 'Loeschen'; Color = '#FFF38BA8'; Handler = { param($sel, $w, $c)
                    if (-not (Confirm-Action "$(@($sel).Count) geplante(s) Server-Backup(s) loeschen?")) { return }
                    foreach ($r in $sel) { try { Unregister-ScheduledTask -TaskPath $script:SbTaskPath -TaskName "$($r.Name)" -Confirm:$false -ErrorAction Stop; Out-Console "Zeitplan geloescht: $($r.Name)" 'Info' } catch { Out-Console "$($r.Name): $($_.Exception.Message)" 'Error' } }
                    $w.Close(); Update-HMSbSchedules } }
        )
}

# ----------------------------------------------------------------------------
# Initialisierung (nach dem Laden des Hauptfensters)
# ----------------------------------------------------------------------------
function Initialize-HMServerBackupTab {
    param([bool]$IsAdmin)
    $tab = $ui.tabServerBackup
    if (-not $tab) { return }
    if ($script:UserMode -or -not $IsAdmin -or -not (Get-Command Get-VM -ErrorAction SilentlyContinue)) { $tab.Visibility = 'Collapsed'; return }
    $script:SbButtons = @($ui.btnSbBackup, $ui.btnSbSchedule, $ui.btnSbProfileNew, $ui.btnSbProfileSave, $ui.btnSbProfileEdit, $ui.btnSbProfileDel, $ui.btnSbDrives, $ui.btnSbDiskSetup, $ui.btnSbEject, $ui.btnSbHostOnly, $ui.btnSbFeature)
    $ui.btnSbBackup.Add_Click({ Start-HMSbBackup })
    $ui.btnSbCancel.Add_Click($cancelAction)
    $ui.btnSbProfileNew.Add_Click({ New-HMSbProfile })
    $ui.btnSbProfileSave.Add_Click({ Save-HMSbProfile })
    $ui.btnSbProfileEdit.Add_Click({ Edit-HMSbProfile })
    $ui.btnSbProfileDel.Add_Click({ Remove-HMSbProfile })
    $ui.btnSbDrives.Add_Click({ Update-HMSbVms; Update-HMSbDrives })
    $ui.btnSbDiskSetup.Add_Click({ Show-HMSbDiskSetup })
    $ui.btnSbEject.Add_Click({ Invoke-HMSbEject })
    $ui.btnSbOpenDrive.Add_Click({
        $d = Get-HMSbDrive
        $f = if ($d) { "$($d.Letter):\$($script:SbDirName)" } else { $script:SbReportDir }
        if (-not (Test-Path -LiteralPath $f)) { $f = if ($d) { "$($d.Letter):\" } else { $script:LogDir } }
        try { Start-Process explorer.exe -ArgumentList "`"$f`"" } catch { }
    })
    $ui.btnSbVersions.Add_Click({ Show-HMSbVersions })
    $ui.btnSbOverview.Add_Click({ Show-HMSbOverview })
    $ui.btnSbOverview.Add_MouseRightButtonUp({ param($s, $e) $e.Handled = $true; Show-HMSbAllRuns })
    $ui.btnSbHostOnly.Add_Click({ Start-HMSbHostOnly })
    $ui.btnSbSchedule.Add_Click({ New-HMSbSchedule })
    $ui.btnSbSchedule.Add_MouseRightButtonUp({ param($s, $e) $e.Handled = $true; Show-HMSbSchedules })
    $ui.btnSbRestore.Add_Click({ Show-HMSbRestoreHelp })
    $ui.btnSbFeature.Add_Click({ Install-HMSbFeature })
    $ui.chkSbHostSystem.Add_Click({ if ($ui.chkSbHostSystem.IsChecked) { Out-Console 'Host-System: sichert nur den Host (C:, Boot/EFI) fuer eine Bare-Metal-Wiederherstellung - Datenlaufwerke mit VMs (z.B. D:) sind nicht dabei, dafuer die VM-Sicherung. Liegen VMs auf C:, werden sie zusaetzlich gesichert (Platz!).' 'Info' } })
    $ui.cmbSbProfile.Add_SelectionChanged({
        if ($script:SbSuppress -or $null -eq $ui.cmbSbProfile.SelectedItem) { return }
        Save-HMSbLastProfile "$($ui.cmbSbProfile.SelectedItem)"
        Set-HMSbFromProfile
    })
    $ui.cmbSbDrive.Add_SelectionChanged({
        if ($script:SbSuppressDrive) { return }
        Update-HMSbDiskInfo
        Update-HMSbSize
    })
    # Daten erst beim ersten Oeffnen des Reiters laden (Start bleibt schnell)
    $ui.tabMain.Add_SelectionChanged({
        param($s, $e)
        if ($e.OriginalSource -ne $ui.tabMain) { return }
        if ($ui.tabMain.SelectedItem -eq $ui.tabServerBackup -and -not $script:SbInit) { $script:SbInit = $true; Update-HMSbAll }
    })
}
