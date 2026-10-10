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
$script:SbVols       = @()
$script:SbHyperV     = $true
$script:SbDrives     = @()
$script:SbInit       = $false
$script:SbPrereq     = $null
$script:SbSuppress   = $false
$script:SbSuppressDrive = $false
$script:SbSuppressAfter = $false
$script:SbAfterRun   = ''
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
    $ad = 0; try { $ad = [int]$p.ArchiveDisks } catch { }
    $ai = 0; try { $ai = [int]$p.ArchiveDays } catch { }
    $da = [ordered]@{}
    if ($null -ne $p.DiskAfter) {
        if ($p.DiskAfter -is [System.Collections.IDictionary]) { foreach ($k in @($p.DiskAfter.Keys)) { if ("$($p.DiskAfter[$k])" -match '^(Eject|Offline)$') { $da["$k".ToUpper()] = "$($p.DiskAfter[$k])" } } }
        else { foreach ($pp in @($p.DiskAfter.PSObject.Properties)) { if ("$($pp.Value)" -match '^(Eject|Offline)$') { $da[$pp.Name.ToUpper()] = "$($pp.Value)" } } }
    }
    return [pscustomobject][ordered]@{
        Name = $name; DiskPrefix = $pre; Disks = $(if ($n -gt 0) { $n } else { 2 })
        VMs = @($p.VMs | Where-Object { "$_".Trim() } | ForEach-Object { "$_".Trim() })
        Volumes = @($p.Volumes | Where-Object { "$_".Trim() } | ForEach-Object { "$_".Trim().ToUpper() })
        HostConfig = ($p.HostConfig -ne $false); Verify = ($p.Verify -ne $false); HostSystem = ($p.HostSystem -eq $true)
        WarnDays = $(if ($w -gt 0) { $w } else { 14 })
        ArchiveDisks = $(if ($ad -gt 0 -and $ad -le 9) { $ad } else { 0 })
        ArchiveDays = $(if ($ai -gt 0) { $ai } else { 30 })
        DiskAfter = [pscustomobject]$da
    }
}
function Get-HMSbConfig {
    $c = Read-JsonFile $script:SbCfgFile
    $list = @()
    if ($c -and $c.Profiles) { foreach ($p in @($c.Profiles)) { if ($p -and "$($p.Name)".Trim()) { $list += (ConvertTo-HMSbProfile $p) } } }
    $ren = @()
    if ($c -and $c.Renames) { foreach ($r in @($c.Renames)) { if ($r -and "$($r.Old)" -and "$($r.New)") { $ren += [pscustomobject]@{ Old = "$($r.Old)"; New = "$($r.New)" } } } }
    $cw = if ($c -and $c.PSObject.Properties['ConflictWords'] -and $null -ne $c.ConflictWords) { @($c.ConflictWords | Where-Object { "$_".Trim() } | ForEach-Object { "$_".Trim() }) } else { $null }
    return [pscustomobject]@{ LastProfile = "$($c.LastProfile)"; Profiles = $list; Renames = $ren; ConflictWords = $cw }
}
function Save-HMSbConfig($Cfg) {
    $o = [ordered]@{ LastProfile = "$($Cfg.LastProfile)"; Profiles = @($Cfg.Profiles); Renames = @($Cfg.Renames) }
    if ($Cfg.PSObject.Properties['ConflictWords'] -and $null -ne $Cfg.ConflictWords) { $o.ConflictWords = @($Cfg.ConflictWords) }
    Write-JsonFile $script:SbCfgFile ([pscustomobject]$o) -Depth 6
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
    return @($ui.pnlSbVms.Children | Where-Object { $_ -is [System.Windows.Controls.CheckBox] -and $_.IsChecked -and "$($_.Tag)" -notlike 'vol:*' } | ForEach-Object { "$($_.Tag)" })
}
function Get-HMSbCheckedVols {
    return @($ui.pnlSbVms.Children | Where-Object { $_ -is [System.Windows.Controls.CheckBox] -and $_.IsChecked -and "$($_.Tag)" -like 'vol:*' } | ForEach-Object { "$($_.Tag)".Substring(4) })
}
function Format-HMSbStatus([string]$s, [string]$Note = '') { switch ($s) { 'OK' { if ("$Note".Trim()) { 'OK (Hinweis)' } else { 'OK' } } 'Warning' { 'Warnung' } 'Error' { 'FEHLER' } default { $s } } }
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
        if ($cb -is [System.Windows.Controls.CheckBox]) {
            $tg = "$($cb.Tag)"
            if ($tg -like 'vol:*') { $cb.IsChecked = [bool]($p -and (@($p.Volumes) -contains $tg.Substring(4))) }
            else { $cb.IsChecked = [bool]($p -and (@($p.VMs) -contains $tg)) }
        }
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
    $prof = ConvertTo-HMSbProfile ([pscustomobject]@{ Name = $n; DiskPrefix = $pre; Disks = $cnt; VMs = @(Get-HMSbCheckedVms); Volumes = @(Get-HMSbCheckedVols)
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
            if ($x.PSObject.Properties['Volumes']) { $x.Volumes = @(Get-HMSbCheckedVols) } else { $x | Add-Member -NotePropertyName Volumes -NotePropertyValue @(Get-HMSbCheckedVols) -Force }
            $x.HostConfig = [bool]$ui.chkSbHostConfig.IsChecked
            $x.Verify = [bool]$ui.chkSbVerify.IsChecked
            $x.HostSystem = [bool]$ui.chkSbHostSystem.IsChecked
        }
    }
    Save-HMSbConfig $cfg
    Out-Console "Profil '$($p.Name)' gespeichert: $(@(Get-HMSbCheckedVms).Count) VM(s), $(@(Get-HMSbCheckedVols).Count) Laufwerk(e)" 'Success'
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
    $a = Show-TextInputDialog -Title 'Archiv-Platten' -Label "Wie viele ARCHIV-Platten (0 = keine)?`nArchiv-Platten heissen $pre-A1, -A2 ..., sind von der Rotation ausgenommen und werden nur in groesseren Abstaenden`n(z. B. monatlich) beschrieben, dann abgezogen und getrennt gelagert - so reicht die Sicherung weit genug zurueck,`nfalls Schadsoftware laenger unbemerkt war." -Text "$($p.ArchiveDisks)"
    if ($null -eq $a) { return }
    $ad = 0
    if (-not [int]::TryParse("$a".Trim(), [ref]$ad) -or $ad -lt 0 -or $ad -gt 9) { Out-Console "Ungueltige Anzahl '$a' (0-9)" 'Error'; return }
    $ai = $p.ArchiveDays
    if ($ad -gt 0) {
        $i = Show-TextInputDialog -Title 'Archiv-Platten' -Label 'Archiv-Sicherung faellig nach (Tagen, z. B. 30 = monatlich):' -Text "$($p.ArchiveDays)"
        if ($null -eq $i) { return }
        if (-not [int]::TryParse("$i".Trim(), [ref]$ai) -or $ai -lt 1 -or $ai -gt 365) { Out-Console "Ungueltige Tage '$i' (1-365)" 'Error'; return }
    }
    foreach ($x in $cfg.Profiles) { if ($x.Name -eq $p.Name) { $x.Name = $n; $x.DiskPrefix = $pre; $x.Disks = $cnt; $x.WarnDays = $wd; $x.ArchiveDisks = $ad; $x.ArchiveDays = $ai } }
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
    Out-Console "Profil '$n': Platten $pre-1 bis $pre-$cnt$(if ($ad) { ", Archiv $pre-A1 bis $pre-A$ad (faellig nach $ai Tagen)" }), Warnung nach $wd Tagen" 'Success'
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
function Add-HMSbHeader([string]$Text) {
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $Text; $tb.FontSize = 10; $tb.FontWeight = [System.Windows.FontWeights]::Bold
    $tb.Foreground = New-Brush '#FFA6ADC8'; $tb.Margin = [System.Windows.Thickness]::new(0, 8, 0, 3)
    [void]$ui.pnlSbVms.Children.Add($tb)
}
function Update-HMSbVms {
    $ui.pnlSbVms.Children.Clear()
    Add-HMSbInfoText 'VMs und Laufwerke werden gelesen ...'
    Invoke-AsyncCommand -ScriptBlock { param($eng) . $eng; Get-HMSbSources } -ArgumentList @($script:SbEngine) -TimeoutSec 120 -BusyTag 'Sb' -BusyText 'VMs und Laufwerke werden gelesen ...' -OnComplete {
        param($r)
        $ui.pnlSbVms.Children.Clear()
        if ($r -is [string] -or $null -eq $r) { $script:SbVms = @(); $script:SbVols = @(); Add-HMSbInfoText "Nicht lesbar: $r" '#FFF38BA8'; return }
        $script:SbHyperV = [bool]$r.HyperV
        $script:SbVms = @($r.VMs | Where-Object { $_ -and $_.Name })
        $script:SbVols = @($r.Volumes | Where-Object { $_ -and $_.Letter })
        if ($script:SbHyperV) {
            Add-HMSbHeader 'VIRTUELLE COMPUTER (Hyper-V)'
            foreach ($v in $script:SbVms) {
                $cb = New-Object System.Windows.Controls.CheckBox
                $cb.Content = ('{0}   [{1}]   {2:N1} GB{3}' -f $v.Name, (Format-HMSbState $v.State), ($v.SizeBytes / 1GB), $(if ([int]$v.Checkpoints) { "   $($v.Checkpoints) Pruefpunkt(e)" } else { '' }))
                $cb.Tag = $v.Name
                $cb.ToolTip = "Speicherort: $($v.VmPath)`nFestplatten: $(@($v.Paths) -join ', ')"
                if ($v.OfflineHint) {
                    $cb.Content = "$($cb.Content)   ! nur offline ($($v.OfflineHint))"
                    $cb.Foreground = New-Brush '#FFFAB387'
                    $cb.ToolTip = "$($cb.ToolTip)`n`nWird OFFLINE gesichert: die VM wird zu Beginn der Sicherung kurz angehalten (gespeicherter Zustand), danach laeuft sie weiter.`nLaut Hyper-V-Protokoll: $($v.OfflineDetail)$(if ($v.OfflineHint -match 'dynamisch') { "`n`nAbhilfe: Laufwerke im Gast auf Basisdatentraeger umstellen (neue Basis-VHDX anhaengen, Daten kopieren) - Details in der Anleitung." })"
                }
                $cb.Add_Click({ Update-HMSbSize })
                [void]$ui.pnlSbVms.Children.Add($cb)
            }
            if (-not $script:SbVms.Count) { Add-HMSbInfoText 'Keine VMs auf diesem Host gefunden.' '#FFF9E2AF' }
            if ("$($r.Error)") { Add-HMSbInfoText "VMs nicht lesbar: $($r.Error)" '#FFF38BA8' }
        } else {
            Add-HMSbInfoText "Auf diesem Server laeuft kein Hyper-V. VMs sichern: HUMig am Hyper-V-Host starten, auf dem die VMs laufen. Hier koennen die Laufwerke und das System dieses Servers gesichert werden." '#FFF9E2AF'
        }
        Add-HMSbHeader 'LAUFWERKE DIESES SERVERS (Volume-Sicherung)'
        foreach ($v in $script:SbVols) {
            $cb = New-Object System.Windows.Controls.CheckBox
            $cb.Content = ('{0}  {1}   {2} belegt von {3}{4}' -f $v.Letter, $(if ($v.Label) { $v.Label } else { '' }), (Format-HMSize $v.Used), (Format-HMSize $v.Size), $(if ($v.System) { '   (System)' } else { '' }))
            $cb.Tag = "vol:$($v.Letter)"
            $cb.ToolTip = "Sichert das ganze Laufwerk $($v.Letter) blockbasiert (Dateien und Ordner einzeln wiederherstellbar).$(if ($script:SbHyperV) { "`nAuf einem Hyper-V-Host: Laufwerke mit VM-Dateien besser ueber die VM-Sicherung sichern." })"
            $cb.Add_Click({ Update-HMSbSize })
            [void]$ui.pnlSbVms.Children.Add($cb)
        }
        if (-not $script:SbVols.Count) { Add-HMSbInfoText 'Keine lokalen NTFS/ReFS-Laufwerke gefunden.' '#FFA6ADC8' }
        $ui.chkSbHostSystem.Content = $(if ($script:SbHyperV) { 'Host-System mitsichern (nur der Host: C:, Boot/EFI - fuer Bare-Metal-Wiederherstellung)' } else { 'System dieses Servers mitsichern (C:, Boot/EFI - fuer Bare-Metal-Wiederherstellung)' })
        $ui.lblSbHost.Text = "$(if ($script:SbHyperV) { 'Hyper-V-Host' } else { 'Server (kein Hyper-V)' }) $env:COMPUTERNAME - $($script:SbVms.Count) VM(s), $($script:SbVols.Count) Laufwerk(e)" + $(if ($script:SbPrereq) { " - Windows Server-Sicherung: $(if ($script:SbPrereq.Feature -eq $false -or -not $script:SbPrereq.Wbadmin) { 'FEHLT' } else { 'OK' })" } else { '' })
        Set-HMSbFromProfile
        Update-HMSbHostSysInfo
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
function Update-HMSbDrives([switch]$All) {
    $script:SbSuppressDrive = $true
    $ui.cmbSbDrive.Items.Clear()
    [void]$ui.cmbSbDrive.Items.Add('(Laufwerke werden gelesen ...)')
    $ui.cmbSbDrive.SelectedIndex = 0
    $script:SbDrives = @()
    $script:SbSuppressDrive = $false
    Invoke-AsyncCommand -ScriptBlock { param($eng, $all) . $eng; Get-HMSbDriveList -KeepHumigOffline:(-not $all) } -ArgumentList @($script:SbEngine, [bool]$All) -TimeoutSec 60 -BusyTag 'Sb' -BusyText 'Platten werden gelesen ...' -OnComplete {
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
            if (Confirm-Action "Auf der Platte $($d.Letter): $($d.Label) ist das Server-Backup-Profil '$n' gespeichert, das es auf diesem Host nicht gibt.`n`nPlatten: $($pr.DiskPrefix)-1 bis -$($pr.Disks)$(if ($pr.ArchiveDisks) { ", Archiv $($pr.DiskPrefix)-A1 bis -A$($pr.ArchiveDisks)" })`nVMs: $(@($pr.VMs) -join ', ')`n`nProfil uebernehmen?" 'Server-Backup') {
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
function Update-HMSbAfterUi {
    $d = Get-HMSbDrive
    $p = Get-HMSbProfile
    $ok = [bool]($d -and $p -and (Test-HMSbLabelMatch $d.Label $p.DiskPrefix))
    $mode = if ($ok) { Get-HMSbAfterMode $p $d.Label } else { '' }
    $script:SbSuppressAfter = $true
    $ui.cmbSbAfter.SelectedIndex = $(switch ($mode) { 'Eject' { 1 } 'Offline' { 2 } default { 0 } })
    $ui.cmbSbAfter.IsEnabled = $ok
    $script:SbSuppressAfter = $false
    return $mode
}
function Set-HMSbAfterMode {
    if ($script:SbSuppressAfter) { return }
    $d = Get-HMSbDrive
    $p = Get-HMSbProfile
    if (-not $d -or -not $p -or -not (Test-HMSbLabelMatch $d.Label $p.DiskPrefix)) { return }
    $mode = switch ($ui.cmbSbAfter.SelectedIndex) { 1 { 'Eject' } 2 { 'Offline' } default { '' } }
    $cfg = Get-HMSbConfig
    foreach ($x in $cfg.Profiles) {
        if ($x.Name -ne $p.Name) { continue }
        $m = [ordered]@{}
        foreach ($pp in @($x.DiskAfter.PSObject.Properties)) { if ($pp.Name -ine $d.Label) { $m[$pp.Name] = "$($pp.Value)" } }
        if ($mode) { $m["$($d.Label)".ToUpper()] = $mode }
        $x.DiskAfter = [pscustomobject]$m
    }
    Save-HMSbConfig $cfg
    Out-Console "Platte $($d.Label): nach der Sicherung $(Format-HMSbAfterMode $mode)" 'Info'
    Update-HMSbDiskInfo
}
function Update-HMSbDiskInfo {
    $after = Update-HMSbAfterUi
    $d = Get-HMSbDrive
    $p = Get-HMSbProfile
    if (-not $d) { $ui.lblSbDiskInfo.Text = 'Keine Ziel-Platte - USB-Platte anstecken und "Aktualisieren" druecken.'; $ui.lblSbDiskInfo.Foreground = New-Brush '#FFF9E2AF'; return }
    $t = ''; $col = '#FFA6ADC8'
    if (-not $p) { $t = "Platte $($d.Label) - kein Profil gewaehlt (mit ""Neu ..."" anlegen)"; $col = '#FFF9E2AF' }
    elseif (Test-HMSbLabelMatch $d.Label $p.DiskPrefix) {
        $arc = Test-HMSbArchiveLabel $d.Label $p.DiskPrefix
        $t = "$(if ($arc) { 'ARCHIV-Platte' } else { 'Platte' }) des Profils erkannt: $($d.Label)"
        if ($d.Model -or $d.Serial) { $t += "  ($($d.Model)$(if ($d.Serial) { ", SN $($d.Serial)" }))" }
        if ($arc) { $t += "  -  nach der Sicherung auswerfen, abziehen und getrennt lagern" }
        $col = '#FFA6E3A1'
    } else {
        $t = "ACHTUNG: '$($d.Label)' ist keine Platte des Profils '$($p.Name)' ($($p.DiskPrefix)-1 bis -$($p.Disks)). Neue Platte? -> ""Platte einrichten ..."" (loescht alles) - schon anders genutzte Platte: dort ""Uebernehmen"" (nur umbenennen)"
        $col = '#FFFAB387'
    }
    if ($d.FileSystem -and $d.FileSystem -notmatch '^(NTFS|ReFS)$') { $t += "  |  Dateisystem $($d.FileSystem) wird nicht unterstuetzt (NTFS noetig)"; $col = '#FFF38BA8' }
    if ($d.Bus -and $d.Bus -notmatch '^(USB|7)$') { $t += "  |  kein USB-Datentraeger ($($d.Bus))" }
    if ($after) { $t += "  |  nach der Sicherung automatisch: $(if ($after -eq 'Eject') { 'AUSWERFEN' } else { 'OFFLINE SCHALTEN' })" }
    $ui.lblSbDiskInfo.Text = $t
    $ui.lblSbDiskInfo.Foreground = New-Brush $col
}
function Update-HMSbSize {
    $sel = @(Get-HMSbCheckedVms)
    $sum = [long]0
    foreach ($n in $sel) { $v = @($script:SbVms | Where-Object { $_.Name -eq $n })[0]; if ($v) { $sum += [long]$v.SizeBytes } }
    $selV = @(Get-HMSbCheckedVols)
    $sumV = [long]0
    foreach ($n in $selV) { $v = @($script:SbVols | Where-Object { $_.Letter -eq $n })[0]; if ($v) { $sumV += [long]$v.Used } }
    $t = "$($sel.Count) VM(s) gewaehlt - virtuelle Festplatten ca. $(Format-HMSize $sum)"
    if ($selV.Count) { $t += " | $($selV.Count) Laufwerk(e) - belegt ca. $(Format-HMSize $sumV)" }
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
# Laeufe aus dem Verlauf entfernen (Tool-Ordner + angesteckte Platten). $Keys: "Datum|Host|Platte"
function Remove-HMSbRuns([string[]]$Keys, $Owner = $null) {
    $Keys = @($Keys | Where-Object { $_ } | Select-Object -Unique)
    if (-not $Keys.Count) { return }
    $o = if ($Owner) { $Owner } else { $script:Window }
    if ("$([System.Windows.MessageBox]::Show($o, "$($Keys.Count) Lauf/Laeufe aus dem Verlauf entfernen?`n`n  " + (@($Keys | Select-Object -First 10 | ForEach-Object { $_ -replace '\|', '  ' }) -join "`n  ") + $(if ($Keys.Count -gt 10) { "`n  ..." }) + "`n`nEntfernt wird nur der Eintrag im Verlauf (Tool-Ordner und angesteckte Platten). Die Sicherung selbst und der Berichtsordner auf der Platte bleiben unveraendert.", 'Server-Backup - Verlauf', 'YesNo', 'Question'))" -ne 'Yes') { return }
    $n = 0
    try { $n += Remove-HMSbHistory $script:SbHistFile $Keys } catch { Out-Console "Verlauf im Tool-Ordner nicht geaendert: $($_.Exception.Message)" 'Error' }
    foreach ($d in @($script:SbDrives)) {
        $f = "$($d.Letter):\$($script:SbDirName)\history.json"
        try { $n += Remove-HMSbHistory $f $Keys } catch { Out-Console "Verlauf auf $($d.Letter): nicht geaendert: $($_.Exception.Message)" 'Warning' }
    }
    Out-Console "Server-Backup: $($Keys.Count) Lauf/Laeufe aus dem Verlauf entfernt ($n Eintraege in Tool-Ordner/Platten)" 'Success'
    Update-HMSbHistory
}
# ----------------------------------------------------------------------------
# Plattenstatus (rechts oben): Modell + Darstellung
# ----------------------------------------------------------------------------
function Format-HMSbAge([int]$Age) {
    if ($Age -le 0) { return 'heute' }
    if ($Age -eq 1) { return 'vor 1 Tag' }
    return "vor $Age Tagen"
}
function Get-HMSbDiskStatus($p, $mine) {
    $mine = @($mine)
    $now = Get-Date
    $labels = @(1..$p.Disks | ForEach-Object { "$($p.DiskPrefix)-$_" })
    $arcLabels = @(); if ($p.ArchiveDisks -gt 0) { $arcLabels = @(1..$p.ArchiveDisks | ForEach-Object { "$($p.DiskPrefix)-A$_" }) }
    foreach ($x in @($mine | ForEach-Object { "$($_.Disk)" } | Where-Object { $_ } | Select-Object -Unique)) {
        if (Test-HMSbArchiveLabel $x $p.DiskPrefix) { if ($arcLabels -notcontains $x) { $arcLabels += $x } }
        elseif ($labels -notcontains $x) { $labels += $x }
    }
    $mkRows = {
        param($list, [bool]$arc)
        $out = @()
        foreach ($lb in $list) {
            $last = @($mine | Where-Object { "$($_.Disk)" -eq $lb -and "$($_.Status)" -ne 'Error' })[0]
            $any = @($mine | Where-Object { "$($_.Disk)" -eq $lb })[0]
            $dt = if ($last) { Get-HMSbDate "$($last.Date)" } else { $null }
            $age = if ($dt) { [int][Math]::Floor(($now - $dt).TotalDays) } else { $null }
            $tags = New-Object System.Collections.Generic.List[object]
            if ($any -and "$($any.Status)" -eq 'Error') { $tags.Add([pscustomobject]@{ Text = 'letzter Lauf fehlgeschlagen'; Color = '#FFF38BA8' }) }
            $out += [pscustomobject]@{ Label = $lb; Archive = $arc; Date = $dt; Age = $age; Dot = '#FF6C7086'; Tags = $tags }
        }
        return $out
    }
    $rot = @(& $mkRows $labels $false)
    $arcRows = @(& $mkRows $arcLabels $true)
    $hints = @()
    # Rotation: Punkt gruen / orange (aelter als Warnfrist) / grau (nie); naechste = am laengsten nicht verwendet
    $next = $null
    foreach ($r in $rot) {
        if ($null -ne $r.Age) { $r.Dot = $(if ($r.Age -gt $p.WarnDays) { '#FFFAB387' } else { '#FFA6E3A1' }) }
        if (-not $next) { $next = $r; continue }
        if ($null -eq $r.Date) { if ($null -ne $next.Date) { $next = $r } }
        elseif ($null -ne $next.Date -and $r.Date -lt $next.Date) { $next = $r }
    }
    if ($next -and $rot.Count -gt 1) { $next.Tags.Insert(0, [pscustomobject]@{ Text = 'naechste laut Rotation'; Color = '#FF89B4FA' }) }
    $lastOk = @($mine | Where-Object { "$($_.Status)" -ne 'Error' })[0]
    if (-not $lastOk) { $hints += [pscustomobject]@{ Text = "Noch keine erfolgreiche Sicherung fuer '$($p.Name)'."; Color = '#FFF9E2AF' } }
    else {
        $ld = Get-HMSbDate "$($lastOk.Date)"
        if ($ld) {
            $age = [int][Math]::Floor(($now - $ld).TotalDays)
            if ($age -gt $p.WarnDays) { $hints += [pscustomobject]@{ Text = "Letzte erfolgreiche Sicherung vor $age Tagen - aelter als $($p.WarnDays) Tage."; Color = '#FFFAB387' } }
        }
    }
    # Archiv: faellig nach ArchiveDays, Platte = am laengsten nicht verwendet
    if ($arcRows.Count) {
        $aLast = $null; $aNext = $null
        foreach ($r in $arcRows) {
            if ($r.Date -and (-not $aLast -or $r.Date -gt $aLast)) { $aLast = $r.Date }
            if (-not $aNext) { $aNext = $r; continue }
            if ($null -eq $r.Date) { if ($null -ne $aNext.Date) { $aNext = $r } }
            elseif ($null -ne $aNext.Date -and $r.Date -lt $aNext.Date) { $aNext = $r }
        }
        $aAge = if ($aLast) { [int][Math]::Floor(($now - $aLast).TotalDays) } else { $null }
        $due = ($null -eq $aAge -or $aAge -ge $p.ArchiveDays)
        foreach ($r in $arcRows) { if ($null -ne $r.Age) { $r.Dot = $(if ($due) { '#FFF9E2AF' } else { '#FFA6E3A1' }) } }
        if ($due) {
            $aNext.Tags.Insert(0, [pscustomobject]@{ Text = 'faellig'; Color = '#FFF9E2AF' })
            $hints += [pscustomobject]@{ Text = "Archiv-Sicherung faellig$(if ($null -ne $aAge) { " (letzte $(Format-HMSbAge $aAge), Abstand $($p.ArchiveDays) Tage)" }): $($aNext.Label) anstecken, sichern, abziehen und getrennt lagern."; Color = '#FFF9E2AF' }
        } else {
            $n = $p.ArchiveDays - $aAge
            $aNext.Tags.Insert(0, [pscustomobject]@{ Text = "naechste in $n Tag$(if ($n -ne 1) { 'en' })"; Color = '#FF94E2D5' })
        }
    }
    return [pscustomobject]@{ Rotation = $rot; Archive = $arcRows; Hints = $hints }
}
function New-HMSbTb([string]$Text, [string]$Color, [double]$Size = 12, [switch]$Bold) {
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $Text
    $tb.Foreground = New-Brush $Color
    $tb.FontSize = $Size
    if ($Bold) { $tb.FontWeight = [System.Windows.FontWeights]::SemiBold }
    $tb.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $tb.Margin = [System.Windows.Thickness]::new(0, 2, 18, 2)
    return $tb
}
function Add-HMSbCell($Grid, $El, [int]$Row, [int]$Col, [int]$Span = 1) {
    [System.Windows.Controls.Grid]::SetRow($El, $Row)
    [System.Windows.Controls.Grid]::SetColumn($El, $Col)
    if ($Span -gt 1) { [System.Windows.Controls.Grid]::SetColumnSpan($El, $Span) }
    [void]$Grid.Children.Add($El)
}
function Show-HMSbDiskStatus($Model) {
    $pn = $ui.pnlSbDisks
    $pn.Children.Clear()
    if (-not $Model) { return }
    $g = New-Object System.Windows.Controls.Grid
    foreach ($w in 1..5) {
        $cd = New-Object System.Windows.Controls.ColumnDefinition
        $cd.Width = $(if ($w -eq 5) { [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star) } else { [System.Windows.GridLength]::Auto })
        $g.ColumnDefinitions.Add($cd)
    }
    $row = 0
    foreach ($grp in @(@{ Title = 'ROTATION'; Sub = ''; Rows = @($Model.Rotation) }, @{ Title = 'ARCHIV'; Sub = 'getrennt vom Server lagern'; Rows = @($Model.Archive) })) {
        if (-not $grp.Rows.Count) { continue }
        $rd = New-Object System.Windows.Controls.RowDefinition; $rd.Height = [System.Windows.GridLength]::Auto; $g.RowDefinitions.Add($rd)
        $h = New-Object System.Windows.Controls.TextBlock
        $h.Margin = [System.Windows.Thickness]::new(0, $(if ($row) { 8 } else { 0 }), 0, 2)
        $r1 = New-Object System.Windows.Documents.Run $grp.Title
        $r1.Foreground = New-Brush '#FFA6ADC8'; $r1.FontSize = 10.5; $r1.FontWeight = [System.Windows.FontWeights]::SemiBold
        [void]$h.Inlines.Add($r1)
        if ($grp.Sub) { $r2 = New-Object System.Windows.Documents.Run ("   " + $grp.Sub); $r2.Foreground = New-Brush '#FF6C7086'; $r2.FontSize = 10.5; [void]$h.Inlines.Add($r2) }
        Add-HMSbCell $g $h $row 0 5
        $row++
        foreach ($d in $grp.Rows) {
            $rd = New-Object System.Windows.Controls.RowDefinition; $rd.Height = [System.Windows.GridLength]::Auto; $g.RowDefinitions.Add($rd)
            $dot = New-Object System.Windows.Shapes.Ellipse
            $dot.Width = 9; $dot.Height = 9; $dot.Fill = New-Brush $d.Dot
            $dot.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
            $dot.Margin = [System.Windows.Thickness]::new(2, 0, 8, 0)
            Add-HMSbCell $g $dot $row 0
            Add-HMSbCell $g (New-HMSbTb $d.Label '#FFCDD6F4' -Bold) $row 1
            if ($d.Date) {
                Add-HMSbCell $g (New-HMSbTb $d.Date.ToString('dd.MM.yyyy') '#FFCDD6F4') $row 2
                Add-HMSbCell $g (New-HMSbTb (Format-HMSbAge $d.Age) '#FFA6ADC8') $row 3
            } else {
                Add-HMSbCell $g (New-HMSbTb 'noch keine Sicherung' '#FF6C7086') $row 2 2
            }
            if ($d.Tags.Count) {
                $sp = New-Object System.Windows.Controls.WrapPanel
                $sp.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
                foreach ($t in $d.Tags) {
                    $chip = New-Object System.Windows.Controls.Border
                    $chip.BorderBrush = New-Brush $t.Color
                    $chip.BorderThickness = [System.Windows.Thickness]::new(1)
                    $chip.CornerRadius = [System.Windows.CornerRadius]::new(3)
                    $chip.Padding = [System.Windows.Thickness]::new(6, 0, 6, 1)
                    $chip.Margin = [System.Windows.Thickness]::new(0, 1, 6, 1)
                    $ct = New-Object System.Windows.Controls.TextBlock
                    $ct.Text = $t.Text; $ct.Foreground = New-Brush $t.Color; $ct.FontSize = 10.5
                    $chip.Child = $ct
                    [void]$sp.Children.Add($chip)
                }
                Add-HMSbCell $g $sp $row 4
            }
            $row++
        }
    }
    $card = New-Object System.Windows.Controls.Border
    $card.Background = New-Brush '#FF1E1E2E'
    $card.CornerRadius = [System.Windows.CornerRadius]::new(4)
    $card.Padding = [System.Windows.Thickness]::new(10, 6, 10, 6)
    $card.Margin = [System.Windows.Thickness]::new(0, 2, 0, 4)
    $card.Child = $g
    [void]$pn.Children.Add($card)
    foreach ($hi in @($Model.Hints)) {
        $b = New-Object System.Windows.Controls.Border
        $b.BorderBrush = New-Brush $hi.Color
        $b.BorderThickness = [System.Windows.Thickness]::new(3, 0, 0, 0)
        $b.Background = New-Brush '#FF1E1E2E'
        $b.Padding = [System.Windows.Thickness]::new(8, 3, 8, 3)
        $b.Margin = [System.Windows.Thickness]::new(0, 0, 0, 3)
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = $hi.Text; $tb.Foreground = New-Brush $hi.Color; $tb.FontSize = 12; $tb.TextWrapping = [System.Windows.TextWrapping]::Wrap
        $b.Child = $tb
        [void]$pn.Children.Add($b)
    }
}
function Update-HMSbHistory {
    $p = Get-HMSbProfile
    $all = Get-HMSbAllHistory
    $all = @($all)
    $rows = @()
    if (-not $p) { $ui.dgSbHistory.ItemsSource = $rows; Show-HMSbDiskStatus $null; $ui.lblSbHostSystem.Text = ''; return }
    $mine = @($all | Where-Object { "$($_.Profile)" -eq $p.Name })
    foreach ($e in @($mine | Select-Object -First 300)) {
        $hin = "$($e.Note)"
        if (-not $hin -and "$($e.Status)" -eq 'OK') { $hin = 'alles in Ordnung' }
        $rows += [pscustomobject]@{ Datum = "$($e.Date)"; Platte = "$($e.Disk)"; Status = (Format-HMSbStatus "$($e.Status)" "$($e.Note)"); Minuten = (Format-HMDuration $e.Minutes); GB = $e.SizeGB; VMs = ((@("$($e.VMs)", $(if ("$($e.Volumes)") { "Laufwerke $($e.Volumes)" })) | Where-Object { $_ }) -join ' | '); Hinweis = $hin; Entry = $e }
    }
    $ui.dgSbHistory.ItemsSource = $rows
    # Plattenstatus + Rotationsempfehlung + Archiv
    Show-HMSbDiskStatus (Get-HMSbDiskStatus $p $mine)
    $hs = @($mine | Where-Object { $_.HostSystem -eq $true })[0]
    $ui.lblSbHostSystem.Text = $(if ($hs) { "letzte Host-System-Sicherung: $($hs.Date) auf $($hs.Disk)" } else { 'noch keine Host-System-Sicherung' })
    Update-HMSbHostSysInfo
}
# Host-System: VMs mit Dateien auf C: anzeigen (Zeile unter "Host-System mitsichern")
function Update-HMSbHostSysInfo {
    $base = "$($ui.lblSbHostSystem.Text)" -replace '\s+\|\s+(ACHTUNG|Hinweis):.*$', ''
    $l = @(Get-HMSbSysDriveVms $script:SbVms)
    $a = @($l | Where-Object { -not $_.ConfigOnly })
    $b = @($l | Where-Object { $_.ConfigOnly })
    $sd = "$env:SystemDrive".TrimEnd('\').ToUpper()
    $col = '#FF6C7086'
    if ($a.Count) { $base += "   |   ACHTUNG: $($a.Count) VM(s) mit Festplatten auf ${sd} ($(@($a | ForEach-Object { $_.Name }) -join ', ')) - werden beim Host-System mitgesichert"; $col = '#FFFAB387' }
    elseif ($b.Count) { $base += "   |   Hinweis: $($b.Count) VM(s) mit Konfiguration auf ${sd}" }
    $ui.lblSbHostSystem.Text = $base
    $ui.lblSbHostSystem.Foreground = New-Brush $col
    $ui.lblSbHostSystem.ToolTip = $(if ($l.Count) { Format-HMSbSysDriveVms $l } else { $null })
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
        $rows.Add(@("$($last.Profile)", "$($last.Disk)", $(if (Test-HMSbArchiveLabel "$($last.Disk)" '') { 'Archiv' } else { 'Rotation' }), "$($last.Host)", $(if ($lastOk) { "$($lastOk.Date)" } else { '-' }), $age, (Format-HMSbStatus "$($last.Status)" "$($last.Note)"), $items.Count, $(if ($avg) { Format-HMDuration $avg } else { '' }), "$($last.SizeGB)", $(if ($hs) { "$($hs.Date)" } else { '' })))
    }
    Show-DataGridWindow -Title 'Server-Backup - Statistik je Profil und Platte' -Width 1100 -Height 520 `
        -Columns @('Profil', 'Platte', 'Art', 'Host', 'Letzte_Sicherung', 'Tage', 'Letzter_Status', 'Laeufe', 'Mittlere_Dauer', 'GB', 'Host_System') `
        -Rows $rows.ToArray() -Sort 'Profil ASC, Platte ASC' -ColumnTypes @{ Tage = [int]; Laeufe = [int] } `
        -CountText "$($rows.Count) Platte(n), $($all.Count) Laeufe (Tool-Ordner + angesteckte Platten)" `
        -Actions @(@{ Text = 'Alle Laeufe anzeigen'; Color = '#FFCBA6F7'; NoSelection = $true; Handler = { param($r, $w, $c) Show-HMSbAllRuns } })
}
function Show-HMSbAllRuns {
    $all = Get-HMSbAllHistory
    $all = @($all)
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($e in $all) {
        $rows.Add(@("$($e.Date)", "$($e.Profile)", "$($e.Host)", "$($e.Disk)", (Format-HMSbStatus "$($e.Status)" "$($e.Note)"), (Format-HMDuration $e.Minutes), "$($e.SizeGB)", "$($e.VMs)",
                $(if ($e.HostConfig -eq $true) { 'ja' } else { '' }), $(if ($e.HostSystem -eq $true) { 'ja' } else { '' }), "$($e.VersionId)", "$($e.Note)", "$($e.Tool)"))
    }
    Show-DataGridWindow -Title 'Server-Backup - alle Laeufe' -Width 1250 -Height 600 `
        -Columns @('Datum', 'Profil', 'Host', 'Platte', 'Status', 'Dauer', 'GB', 'VMs', 'Host_Konfig', 'Host_System', 'Version', 'Hinweis', 'Tool') `
        -Rows $rows.ToArray() -Sort 'Datum DESC' `
        -Actions @(@{ Text = 'Markierte aus dem Verlauf entfernen'; Color = '#FFF38BA8'; Handler = {
            param($rows, $win, $ctx)
            $k = @(@($rows) | ForEach-Object { "$($_.Datum)|$($_.Host)|$($_.Platte)" })
            $win.Close()
            Remove-HMSbRuns $k
        } })
}

# ----------------------------------------------------------------------------
# Aktionen
# ----------------------------------------------------------------------------
function Start-HMSbBackup {
    if ($script:JobRunning) { Out-Console 'Es laeuft bereits ein Vorgang.' 'Warning'; return }
    $p = Get-HMSbProfile
    $d = Get-HMSbDrive
    $vms = @(Get-HMSbCheckedVms)
    $vols = @(Get-HMSbCheckedVols)
    $hc = [bool]$ui.chkSbHostConfig.IsChecked
    $hs = [bool]$ui.chkSbHostSystem.IsChecked
    if (-not $d) { Out-Console 'Server-Backup: keine Ziel-Platte gewaehlt.' 'Warning'; return }
    if ($vols -contains "$($d.Letter):") { Out-Console "Server-Backup: das Ziel-Laufwerk $($d.Letter): kann nicht sich selbst sichern - abwaehlen." 'Error'; return }
    if ($d.FileSystem -and $d.FileSystem -notmatch '^(NTFS|ReFS)$') { Out-Console "Server-Backup: Dateisystem $($d.FileSystem) auf $($d.Letter): wird nicht unterstuetzt - Platte einrichten (NTFS)." 'Error'; return }
    if (-not $vms.Count -and -not $vols.Count -and -not $hs -and -not $hc) { Out-Console 'Server-Backup: nichts gewaehlt (VMs, Laufwerke, Host-Konfiguration oder System).' 'Warning'; return }
    if ($script:SbPrereq -and ($script:SbPrereq.Feature -eq $false -or -not $script:SbPrereq.Wbadmin)) { Out-Console 'Windows Server-Sicherung fehlt - Button "Windows Server-Sicherung installieren".' 'Error'; return }
    $pName = if ($p) { $p.Name } else { '(ohne Profil)' }
    $msg = "Server-Backup starten?`n`nProfil: $pName`nZiel: $($d.Letter): $($d.Label)`nVMs ($($vms.Count)): $(if ($vms.Count) { $vms -join ', ' } else { '-' })`nLaufwerke: $(if ($vols.Count) { $vols -join ', ' } else { '-' })`nHost-Konfiguration: $(if ($hc) { 'ja' } else { 'nein' })`nSystem (Bare-Metal): $(if ($hs) { 'ja' } else { 'nein' })`n`nVMs und Server laufen weiter (Online-Sicherung ueber VSS)."
    if ($hs) { $sv = Format-HMSbSysDriveVms (Get-HMSbSysDriveVms $script:SbVms); if ($sv) { $msg += "`n`n$sv" } }
    $after = if ($p -and (Test-HMSbLabelMatch $d.Label $p.DiskPrefix)) { Get-HMSbAfterMode $p $d.Label } else { '' }
    if ($after -eq 'Eject') { $msg += "`n`nNach der Sicherung wird die Platte automatisch ausgeworfen." }
    elseif ($after -eq 'Offline') { $msg += "`n`nNach der Sicherung wird die Platte automatisch offline geschaltet." }
    if (-not $p) { $msg += "`n`nHinweis: kein Profil gewaehlt - Verlauf unter '(ohne Profil)'." }
    elseif (-not (Test-HMSbLabelMatch $d.Label $p.DiskPrefix)) { $msg += "`n`nACHTUNG: Die Platte '$($d.Label)' gehoert laut Bezeichnung NICHT zum Profil ($($p.DiskPrefix)-...)." }
    if ($p) {
        $a = @($p.VMs | Sort-Object) -join '|'; $b = @($vms | Sort-Object) -join '|'
        if ($a -ne $b) { $msg += "`n`nHinweis: Die VM-Auswahl weicht vom gespeicherten Profil ab (gilt nur fuer diesen Lauf - 'Profil speichern' uebernimmt sie)." }
    }
    $off = @($vms | ForEach-Object { $n = $_; @($script:SbVms | Where-Object { $_.Name -eq $n -and $_.OfflineHint })[0] } | Where-Object { $_ })
    if ($off.Count) { $msg += "`n`nACHTUNG - nur OFFLINE sicherbar (VM wird zu Beginn kurz angehalten):`n" + (@($off | ForEach-Object { "  $($_.Name): $($_.OfflineHint)" }) -join "`n") + "`nTipp: solche VMs ausserhalb der Unterrichtszeit sichern (Zeitplan)." }
    if (-not (Confirm-Action $msg 'Server-Backup')) { return }
    # Vorab-Pruefung: laeuft schon eine Sicherung/Wiederherstellung am Host?
    $busy = @(Get-HMSbBusy)
    if ($busy.Count) {
        $bm = "Am Host laeuft bereits eine Sicherung oder Wiederherstellung - die Windows Server-Sicherung kann nur einen Vorgang gleichzeitig:`n`n  " + ($busy -join "`n  ") + "`n`nJa = HUMig wartet, bis der andere Vorgang fertig ist, und startet dann automatisch (hoechstens 8 h, Abbrechen jederzeit moeglich)`nNein = jetzt nicht starten"
        if ("$([System.Windows.MessageBox]::Show($script:Window, $bm, 'Server-Backup', 'YesNo', 'Warning'))" -ne 'Yes') { Out-Console 'Server-Backup nicht gestartet - am Host laeuft bereits eine Sicherung/Wiederherstellung.' 'Warning'; return }
    }
    if ($p) { Save-HMSbLastProfile $p.Name }
    $script:SbArchiveRun = $(if ($p -and (Test-HMSbArchiveLabel $d.Label $p.DiskPrefix)) { "$($d.Label)" } else { '' })
    $ctx = @{
        Profile = $pName; DiskPrefix = $(if ($p) { $p.DiskPrefix } else { '' }); Drive = $d.Letter; DiskLabel = $d.Label; DiskSerial = $d.Serial
        VMs = $vms; Volumes = $vols; HostConfig = $hc; HostSystem = $hs; Verify = [bool]$ui.chkSbVerify.IsChecked
        LocalHistory = $script:SbHistFile; LocalReportDir = $script:SbReportDir; Version = $script:Version
        ProfileData = $(if ($p) { $p } else { $null }); After = $after
    }
    $script:SbAfterRun = $after
    Start-EngineJob -Command 'Start-HMServerBackup -Ctx $Ctx -Job $Job' -Ctx $ctx -Title 'Server-Backup' -ScriptFiles @($script:SbEngine) -OnFinished {
        param($j)
        Update-HMSbHistory
        if ($j.Result -and $j.Result.Report) { Out-Console "Berichtsordner: $($j.Result.Report)" 'Info' }
        if ($script:SbAfterRun) { Update-HMSbDrives }
        if ($script:SbArchiveRun) { Out-Console "Archiv-Platte $($script:SbArchiveRun): $(if ($script:SbAfterRun -eq 'Eject') { 'abziehen' } else { 'jetzt ""Auswerfen"", abziehen' }) und getrennt vom Server lagern (nicht angesteckt lassen)." 'Warning' }
    }
}

function Show-HMSbDiskSetup {
    if ($script:JobRunning) { Out-Console 'Waehrend eines Vorgangs nicht moeglich.' 'Warning'; return }
    Out-Console 'Server-Backup: USB-Datentraeger werden gelesen ...' 'Info'
    Invoke-AsyncCommand -ScriptBlock { param($eng) . $eng; Get-HMSbDiskList } -ArgumentList @($script:SbEngine) -TimeoutSec 90 -BusyTag 'Sb' -BusyText 'USB-Datentraeger werden gelesen ...' -OnComplete {
        param($r)
        if ($r -is [string]) { Out-Console "Datentraeger nicht lesbar: $r" 'Error'; return }
        $disks = @($r | Where-Object { $_ })
        $script:SbDiskRows = $disks
        if (-not $disks.Count) { Out-Console 'Kein USB-Datentraeger gefunden (System-/Startplatten und Platten mit VM-Dateien werden nie angezeigt).' 'Warning'; return }
        $rows = New-Object System.Collections.Generic.List[object]
        foreach ($d in $disks) { $rows.Add(@([int]$d.Number, $d.Model, $d.Serial, (Format-HMSize $d.SizeBytes), $d.Style, $d.Volumes, $(if ($d.Offline) { 'offline' } else { '' }))) }
        Show-DataGridWindow -Title 'USB-Platte fuer Server-Backup: einrichten (loescht alles) oder uebernehmen (Daten bleiben)' -Width 1100 -Height 380 `
            -Columns @('Nr', 'Modell', 'Seriennummer', 'Groesse', 'Partitionsstil', 'Volumes', 'Status') -Rows $rows.ToArray() -ColumnTypes @{ Nr = [int] } `
            -CountText 'Platte markieren - "Einrichten" LOESCHT ALLES, "Uebernehmen" aendert nur die Bezeichnung (fuer Platten, die schon anders genutzt werden)' `
            -Actions @(
                @{ Text = 'Einrichten (loescht alles) ...'; Color = '#FFFAB387'; Handler = { param($sel, $w, $c) Invoke-HMSbDiskSetup $sel $w } }
                @{ Text = 'Uebernehmen (ohne Formatieren) ...'; Color = '#FFA6E3A1'; Handler = { param($sel, $w, $c) Invoke-HMSbDiskAdopt $sel $w } }
            )
    }
}
function Get-HMSbNextLabel($p) {
    if (-not $p) { return 'HUMIG-BACKUP-1' }
    $used = @()
    $all = Get-HMSbAllHistory
    $used += @(@($all) | Where-Object { "$($_.Profile)" -eq $p.Name } | ForEach-Object { "$($_.Disk)" })
    $used += @($script:SbDrives | ForEach-Object { "$($_.Label)" })
    $cand = @(1..$p.Disks | ForEach-Object { "$($p.DiskPrefix)-$_" })
    if ($p.ArchiveDisks -gt 0) { $cand += @(1..$p.ArchiveDisks | ForEach-Object { "$($p.DiskPrefix)-A$_" }) }
    $cand += @(($p.Disks + 1)..30 | ForEach-Object { "$($p.DiskPrefix)-$_" })
    foreach ($l in $cand) { if (-not (@($used) -contains $l)) { return $l } }
    return "$($p.DiskPrefix)-1"
}
function Invoke-HMSbDiskSetup($Sel, $Win) {
    $row = @($Sel)[0]
    if (-not $row) { return }
    $num = [int]$row.Nr
    $disk = @($script:SbDiskRows | Where-Object { [int]$_.Number -eq $num })[0]
    if (-not $disk -or -not "$($disk.Id)") { Out-Console 'Platte einrichten: Platte nicht eindeutig bestimmbar - Liste neu oeffnen.' 'Warning'; return }
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
    Invoke-AsyncCommand -ScriptBlock { param($eng, $n, $l, $pn, $id) . $eng; Initialize-HMSbDisk -Number $n -Label $l -Profile $pn -ExpectId $id } -ArgumentList @($script:SbEngine, $num, $label, $(if ($p) { $p.Name } else { '' }), "$($disk.Id)") -TimeoutSec 900 -BusyTag 'Sb' -BusyText 'Platte wird eingerichtet ...' -OnComplete {
        param($r)
        if ($r -is [string]) { Out-Console "Platte einrichten FEHLGESCHLAGEN: $r" 'Error'; Set-Status 'Platte einrichten fehlgeschlagen' '#FFF38BA8' }
        else { Out-Console "Platte eingerichtet: $($r.Letter): $($r.Label) ($(Format-HMSize $r.SizeBytes), NTFS 64K)" 'Success'; Set-Status 'Platte eingerichtet' '#FFA6E3A1' }
        Update-HMSbDrives
    }
}

# Vorhandene Platte uebernehmen: nur Bezeichnung aendern (z.B. 'My Book' -> HUMIG-BHAK-1), alle Daten bleiben
function Invoke-HMSbDiskAdopt($Sel, $Win) {
    $row = @($Sel)[0]
    if (-not $row) { return }
    if ($script:JobRunning) { Out-Console 'Waehrend eines Vorgangs nicht moeglich.' 'Warning'; return }
    $num = [int]$row.Nr
    $script:SbAdopt = @{ Win = $Win; Num = $num }
    Invoke-AsyncCommand -ScriptBlock { param($eng, $n) . $eng; Get-HMSbDiskVolumeInfo $n } -ArgumentList @($script:SbEngine, $num) -TimeoutSec 120 -BusyTag 'Sb' -BusyText 'Platte wird gelesen ...' -OnComplete {
        param($r)
        $a = $script:SbAdopt
        if ($r -is [string]) { [void][System.Windows.MessageBox]::Show($a.Win, "Uebernehmen nicht moeglich:`n$r", 'Platte uebernehmen', 'OK', 'Warning'); return }
        $p = Get-HMSbProfile
        $label = Show-TextInputDialog -Title 'Platte uebernehmen' -Label "Neue Bezeichnung fuer $($r.Letter): '$($r.Label)' (Datentraeger $($a.Num), $($r.Model)):" -Text (Get-HMSbNextLabel $p) -Owner $a.Win
        if ($null -eq $label) { return }
        $label = "$label".Trim().ToUpper()
        if ($label -notmatch '^[A-Z0-9_\-]{1,32}$') { [void][System.Windows.MessageBox]::Show($a.Win, "Ungueltige Bezeichnung '$label' (max. 32 Zeichen: A-Z, 0-9, - und _)", 'Platte uebernehmen', 'OK', 'Warning'); return }
        $dup = @($script:SbDrives | Where-Object { "$($_.Label)" -ieq $label -and "$($_.Letter)" -ine "$($r.Letter)" } | ForEach-Object { "$($_.Letter):" })
        if ($dup.Count) { [void][System.Windows.MessageBox]::Show($a.Win, "Die Bezeichnung '$label' hat schon $($dup -join ', ') - bitte eine andere waehlen.", 'Platte uebernehmen', 'OK', 'Warning'); return }
        $fold = @($r.Folders)
        $fl = if ($fold.Count) { (@($fold | Select-Object -First 15) -join ', ') + $(if ($fold.Count -gt 15) { " ... (+$($fold.Count - 15))" } else { '' }) } else { '(keine)' }
        $used = [long]$r.SizeBytes - [long]$r.FreeBytes
        $msg = "Platte uebernehmen OHNE Formatieren?`n`n" +
            "Laufwerk $($r.Letter): '$($r.Label)'  ->  neue Bezeichnung '$label'`n" +
            "$($r.Model)$(if ($r.Serial) { ", SN $($r.Serial)" }), $($r.FileSystem)`n" +
            "Belegt $(Format-HMSize $used) von $(Format-HMSize $r.SizeBytes), frei $(Format-HMSize $r.FreeBytes)`n" +
            "Vorhandene Ordner: $fl`n`n" +
            "- Es wird NICHTS geloescht - nur die Bezeichnung des Laufwerks wird umbenannt.`n" +
            "- Die Sicherung landet im Ordner $($r.Letter):\WindowsImageBackup\$($r.Host) (Name fest von Windows vorgegeben) - andere Ordner bleiben unberuehrt.`n" +
            "- ACHTUNG Umbenennen: Programme, Aufgaben oder Personen, die die Platte am Namen '$($r.Label)' erkennen, finden sie danach nur noch als '$label'. Vorher mit dem Besitzer der Platte abstimmen.`n" +
            "- Gemeinsam genutzte Platte: genug Platz frei lassen; aeltere Sicherungsversionen haelt Windows auf diesem Laufwerk (Schattenkopien) - wird es knapp, fallen alte Versionen frueher weg.`n" +
            "- Eine andere Sicherung auf diese Platte darf nicht gleichzeitig laufen."
        if ($r.PrevLabel -and $r.PrevLabel -ine $label) { $msg += "`n`nHINWEIS: Die Platte war schon von HUMig als '$($r.PrevLabel)' eingerichtet$(if ($r.PrevProfile) { " (Profil $($r.PrevProfile))" })$(if ($r.PrevHost) { " am Host $($r.PrevHost)" }) - der Verlauf dort laeuft unter dem alten Namen." }
        if ([int]$r.OtherVolumes -gt 0) { $msg += "`n`nHinweis: die Platte hat $($r.OtherVolumes) weitere(s) Volume(s) - genutzt wird nur $($r.Letter):." }
        if ("$([System.Windows.MessageBox]::Show($a.Win, $msg, 'Platte uebernehmen (umbenennen)', 'YesNo', 'Warning', 'No'))" -ne 'Yes') { Out-Console 'Platte uebernehmen abgebrochen.' 'Info'; return }
        # gleicher Ordnername: Windows-Sicherung dieses Hosts liegt schon auf der Platte (z.B. von einer anderen Person/einem anderen Programm eingerichtet)
        if ($r.WbThisHost) {
            $w2 = "VORSICHT - auf $($r.Letter): gibt es schon eine Windows Server-Sicherung DIESES Hosts:`n$($r.Letter):\WindowsImageBackup\$($r.Host)`n`n" +
                "Windows legt die Sicherung immer in genau diesen Ordner - HUMig kann keinen anderen Namen verwenden. Die Sicherungen von HUMig und die vorhandenen landen dann im SELBEN Ordner und Katalog:`n" +
                "- vorhandene Versionen bleiben erhalten und erscheinen unter 'Versionen auf der Platte'`n" +
                "- wird der Platz knapp, loescht Windows die AELTESTEN Versionen - auch die der anderen Sicherung`n" +
                "- laeuft die andere Sicherung weiter, mischen sich beide Zeitplaene`n`n" +
                "Nur fortfahren, wenn das mit dem Besitzer der vorhandenen Sicherung abgestimmt ist (oder sie nicht mehr gebraucht wird).`n`nTrotzdem uebernehmen?"
            if ("$([System.Windows.MessageBox]::Show($a.Win, $w2, 'Platte uebernehmen - vorhandene Sicherung', 'YesNo', 'Warning', 'No'))" -ne 'Yes') { Out-Console "Platte uebernehmen abgebrochen (vorhandene Windows-Sicherung von $($r.Host) auf $($r.Letter):)." 'Warning'; return }
        } elseif (@($r.WbHosts).Count) {
            Out-Console "Hinweis: auf $($r.Letter): liegen Windows-Sicherungen anderer Rechner ($(@($r.WbHosts) -join ', ')) - getrennte Ordner, bleiben unberuehrt." 'Info'
        }
        try { $a.Win.Close() } catch { }
        Out-Console "Platte $($r.Letter): '$($r.Label)' wird als '$label' uebernommen (ohne Formatieren) ..." 'Info'
        Invoke-AsyncCommand -ScriptBlock { param($eng, $n, $l, $lb, $pn) . $eng; Rename-HMSbDiskVolume -Number $n -Letter $l -Label $lb -Profile $pn } -ArgumentList @($script:SbEngine, $a.Num, $r.Letter, $label, $(if ($p) { $p.Name } else { '' })) -TimeoutSec 120 -BusyTag 'Sb' -BusyText 'Platte wird umbenannt ...' -OnComplete {
            param($x)
            if ($x -is [string]) { Out-Console "Platte uebernehmen FEHLGESCHLAGEN: $x" 'Error' }
            else { Out-Console "Platte uebernommen: $($x.Letter): '$($x.OldLabel)' -> '$($x.Label)' (Daten unveraendert, frei $(Format-HMSize $x.FreeBytes))" 'Success' }
            Update-HMSbDrives
        }
    }
}

function Invoke-HMSbEject {
    if ($script:JobRunning) { Out-Console 'Waehrend eines Vorgangs nicht moeglich.' 'Warning'; return }
    $d = Get-HMSbDrive
    if (-not $d) { return }
    $L = $d.Letter
    try { Write-VolumeCache -DriveLetter $L -ErrorAction Stop; Out-Console "Schreibcache von ${L}: geleert" 'Info' } catch { Out-Console "Schreibcache ${L}: $($_.Exception.Message)" 'Warning' }
    # Sicher entfernen ueber die Geraeteverwaltung (CM_Request_Device_Eject) - liefert den Grund, falls Windows ablehnt
    Invoke-AsyncCommand -ScriptBlock {
        param($eng, $L)
        . $eng
        $disk = Get-Partition -DriveLetter $L -ErrorAction Stop | Get-Disk -ErrorAction Stop
        if ($disk.IsBoot -or $disk.IsSystem) { throw 'System-/Startplatte' }
        $r = Invoke-HMSbDiskEjectRetry -Number $disk.Number -Tries 2 -WaitSec 5
        [pscustomobject]@{ Number = [int]$disk.Number; Result = $r }
    } -ArgumentList @($script:SbEngine, $L) -TimeoutSec 90 -State $d -BusyTag 'Sb' -BusyText 'Platte wird ausgeworfen ...' -OnComplete {
        param($r, $d)
        if ($r -is [string]) { Out-Console "Auswerfen von $($d.Letter): ($($d.Label)): $r" 'Warning'; Update-HMSbDrives; return }
        if (-not $r.Result) {
            Out-Console "Platte $($d.Label) ausgeworfen - kann jetzt abgezogen werden." 'Success'
            [System.Media.SystemSounds]::Asterisk.Play()
            Update-HMSbDrives
            return
        }
        Out-Console "Platte $($d.Label) wurde von Windows NICHT ausgeworfen: $($r.Result)" 'Warning'
        if (Confirm-Action "Die Platte $($d.Letter): $($d.Label) laesst sich nicht auswerfen:`n$($r.Result)`n`nStattdessen OFFLINE schalten? (Windows trennt das Volume sofort, die Platte kann danach abgezogen werden.`nWieder online: ""Aktualisieren"" oder der naechste geplante Lauf.)" 'Auswerfen') {
            Invoke-AsyncCommand -ScriptBlock { param($eng, $n, $lb) . $eng; Set-HMSbDiskOffline -Number $n -Label $lb; 'OK' } -ArgumentList @($script:SbEngine, $r.Number, "$($d.Label)") -TimeoutSec 60 -State $d -BusyTag 'Sb' -BusyText 'Platte wird offline geschaltet ...' -OnComplete {
                param($x, $d)
                if ("$x" -eq 'OK') { Out-Console "Platte $($d.Label) offline geschaltet - kann jetzt abgezogen werden." 'Success'; [System.Media.SystemSounds]::Asterisk.Play() }
                else { Out-Console "Offline schalten von $($d.Label) fehlgeschlagen: $x" 'Error' }
                Update-HMSbDrives
            }
        } else { Update-HMSbDrives }
    }
}

function Show-HMSbVersions {
    $d = Get-HMSbDrive
    if (-not $d) { Out-Console 'Keine Ziel-Platte gewaehlt.' 'Warning'; return }
    Out-Console "Versionen auf $($d.Letter): werden gelesen ..." 'Info'
    Invoke-AsyncCommand -ScriptBlock { param($eng, $t) . $eng; Get-HMSbVersions $t } -ArgumentList @($script:SbEngine, "$($d.Letter):") -TimeoutSec 120 -State $d -BusyTag 'Sb' -BusyText 'Versionen werden gelesen ...' -OnComplete {
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
    Invoke-AsyncCommand -ScriptBlock { param($eng, $dst) . $eng; Export-HMSbHostConfig -Dest $dst } -ArgumentList @($script:SbEngine, $dest) -TimeoutSec 300 -BusyTag 'Sb' -BusyText 'Host-Konfiguration wird exportiert ...' -OnComplete {
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
    } -TimeoutSec 1800 -BusyTag 'Sb' -BusyText 'Windows Server-Sicherung wird installiert ...' -OnComplete {
        param($r)
        if ("$r" -like 'OK:True*') { Out-Console "Windows Server-Sicherung installiert$(if ("$r" -match ':Yes$') { ' - Neustart erforderlich' })" 'Success'; Set-Status 'Windows Server-Sicherung installiert' '#FFA6E3A1' }
        else { Out-Console "Installation: $r" 'Error'; Set-Status 'Installation fehlgeschlagen' '#FFF38BA8' }
        Update-HMSbPrereq
    }
}

function Update-HMSbPrereq {
    Invoke-AsyncCommand -ScriptBlock { param($eng) . $eng; Test-HMSbPrereq } -ArgumentList @($script:SbEngine) -TimeoutSec 60 -BusyTag 'Sb' -BusyText 'Windows Server-Sicherung wird geprueft ...' -OnComplete {
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

# Bericht eines Laufs finden (Platte oder Tool-Ordner\Logs\ServerBackup) und oeffnen
function Open-HMSbReport($Entry) {
    if (-not $Entry) { return }
    $bases = @()
    foreach ($d in @($script:SbDrives)) { $bases += "$($d.Letter):\$($script:SbDirName)" }
    $bases += $script:SbReportDir
    $cands = @()
    if ("$($Entry.Report)") { foreach ($b in $bases) { $cands += (Join-Path $b "$($Entry.Report)") } }
    # aeltere Eintraege ohne Report-Feld: Ordner <yyyy-MM-dd_HHmm>_<Profil> mit +-3 Minuten
    $dt = Get-HMSbDate "$($Entry.Date)"
    if ($dt) {
        $safe = ConvertTo-HMSbSafeName "$($Entry.Profile)"
        foreach ($b in $bases) {
            if (-not (Test-Path -LiteralPath $b)) { continue }
            foreach ($f in @(Get-ChildItem -LiteralPath $b -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*_$safe" })) {
                if ($f.Name -match '^(\d{4}-\d{2}-\d{2}_\d{4})_') {
                    $fd = $null; try { $fd = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd_HHmm', [System.Globalization.CultureInfo]::InvariantCulture) } catch { }
                    if ($fd -and [math]::Abs(($fd - $dt).TotalMinutes) -le 3) { $cands += $f.FullName }
                }
            }
        }
    }
    foreach ($c in $cands) {
        $h = Join-Path $c 'Bericht.html'
        if (Test-Path -LiteralPath $h) { try { Start-Process $h; return } catch { } }
        if (Test-Path -LiteralPath $c) { try { Start-Process explorer.exe -ArgumentList "`"$c`""; return } catch { } }
    }
    $msg = "Bericht zum Lauf $($Entry.Date) nicht gefunden (Platte $($Entry.Disk) angesteckt?)."
    if ("$($Entry.Note)") { $msg += " Hinweis: $($Entry.Note)" }
    Out-Console $msg 'Warning'
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
# ----------------------------------------------------------------------------
# Andere Sicherungsaufgaben in der Aufgabenplanung, die sich mit HUMig ueberschneiden koennen
#   Suchwoerter frei (serverbackup.json ConflictWords), "-Wort" = ausschliessen
# ----------------------------------------------------------------------------
$script:SbConflictDefault = @('backup', 'sicherung', 'wbadmin', 'veeam', 'acronis', '-RegIdleBackup')
function Get-HMSbConflictWords {
    $w = (Get-HMSbConfig).ConflictWords
    if ($null -eq $w -or -not @($w).Count) { return $script:SbConflictDefault }
    return @($w)
}
# Startzeiten eines Plans (Daily/Weekly/Once bzw. Aufgaben-Trigger) im Zeitraum
function Get-HMSbPlanStarts($Plan, [datetime]$From, [datetime]$To) {
    $out = @()
    switch ($Plan.Mode) {
        'Once'  { if ($Plan.At -ge $From -and $Plan.At -le $To) { $out += $Plan.At } }
        'Daily' { for ($d = $From.Date; $d -le $To; $d = $d.AddDays(1)) { $x = $d.Add($Plan.At.TimeOfDay); if ($x -ge $From -and $x -le $To) { $out += $x } } }
        default { for ($d = $From.Date; $d -le $To; $d = $d.AddDays(1)) { if (@($Plan.Days) -contains "$($d.DayOfWeek)") { $x = $d.Add($Plan.At.TimeOfDay); if ($x -ge $From -and $x -le $To) { $out += $x } } } }
    }
    return $out
}
function Get-HMSbTaskStarts($Task, [datetime]$From, [datetime]$To) {
    $out = @()
    foreach ($t in @($Task.Triggers)) {
        if (-not $t) { continue }
        if ($t.PSObject.Properties['Enabled'] -and $t.Enabled -eq $false) { continue }
        $sb = $null; try { if ("$($t.StartBoundary)") { $sb = [datetime]"$($t.StartBoundary)" } } catch { }
        if (-not $sb) { continue }
        $cls = "$($t.CimClass.CimClassName)"
        if ($cls -like '*DailyTrigger') {
            $iv = 1; try { $iv = [Math]::Max(1, [int]$t.DaysInterval) } catch { }
            $d = $sb; $n = 0
            while ($d -lt $From -and $n -lt 100000) { $d = $d.AddDays($iv); $n++ }
            while ($d -le $To) { $out += $d; $d = $d.AddDays($iv) }
        } elseif ($cls -like '*WeeklyTrigger') {
            $mask = 0; try { $mask = [int]$t.DaysOfWeek } catch { }
            for ($d = $From.Date; $d -le $To; $d = $d.AddDays(1)) {
                if ($mask -band (1 -shl [int]$d.DayOfWeek)) { $x = $d.Add($sb.TimeOfDay); if ($x -ge $From -and $x -le $To -and $x -ge $sb) { $out += $x } }
            }
        } elseif ($cls -like '*TimeTrigger') { if ($sb -ge $From -and $sb -le $To) { $out += $sb } }
    }
    return $out
}
function Get-HMSbTriggerText($Task) {
    $days = @('So', 'Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa')
    $parts = foreach ($t in @($Task.Triggers)) {
        if (-not $t) { continue }
        $cls = "$($t.CimClass.CimClassName)"
        $tm = ''; try { $tm = ([datetime]"$($t.StartBoundary)").ToString('HH:mm') } catch { }
        if ($cls -like '*DailyTrigger') { "taeglich $tm" }
        elseif ($cls -like '*WeeklyTrigger') { $m = 0; try { $m = [int]$t.DaysOfWeek } catch { }; "$((@(0..6 | Where-Object { $m -band (1 -shl $_) } | ForEach-Object { $days[$_] })) -join ',') $tm" }
        elseif ($cls -like '*TimeTrigger') { "einmalig $(try { ([datetime]"$($t.StartBoundary)").ToString('dd.MM.yyyy HH:mm') } catch { '' })" }
        elseif ($cls -like '*LogonTrigger') { 'bei Anmeldung' }
        elseif ($cls -like '*BootTrigger') { 'beim Start' }
        elseif ($cls -like '*IdleTrigger') { 'im Leerlauf' }
        else { ($cls -replace '^MSFT_Task', '' -replace 'Trigger$', '') }
    }
    return (@($parts) -join ' | ')
}
# Passende Aufgaben (ohne die Zeitplaene des eigenen Profils). $Plan (optional): geplanter Lauf -> Ueberschneidung pruefen
function Get-HMSbConflicts($Plan = $null, [string]$OwnPrefix = '', [double]$OwnMinutes = 360) {
    $words = @(Get-HMSbConflictWords)
    $inc = @($words | Where-Object { $_ -notlike '-*' })
    $exc = @($words | Where-Object { $_ -like '-*' } | ForEach-Object { $_.Substring(1) } | Where-Object { $_ })
    $from = Get-Date; $to = $from.AddDays(14)
    $mine = @(); if ($Plan) { $mine = @(Get-HMSbPlanStarts $Plan $from $to) }
    $rows = @()
    foreach ($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue)) {
        $full = "$($t.TaskPath)$($t.TaskName)"
        if ($OwnPrefix -and "$($t.TaskPath)" -eq $script:SbTaskPath -and $t.TaskName -like "$OwnPrefix*") { continue }
        $acts = (@($t.Actions) | ForEach-Object { "$($_.Execute) $($_.Arguments)".Trim() }) -join ' ; '
        $txt = "$full $($t.Description) $acts"
        $hit = @($inc | Where-Object { $txt -like "*$_*" })
        $isHumig = ("$($t.TaskPath)" -eq $script:SbTaskPath -and $t.TaskName -like 'Server-Backup*')
        if (-not $hit.Count -and -not $isHumig) { continue }
        if (@($exc | Where-Object { $txt -like "*$_*" }).Count) { continue }
        $info = $null; try { $info = Get-ScheduledTaskInfo -TaskPath $t.TaskPath -TaskName $t.TaskName -ErrorAction Stop } catch { }
        $enabled = ("$($t.State)" -ne 'Disabled')
        $over = ''
        if ($Plan -and $enabled) {
            $dur = 180
            if ($isHumig) { $dur = 360 }
            foreach ($a in @(Get-HMSbTaskStarts $t $from $to)) {
                foreach ($m in $mine) { if ($m -lt $a.AddMinutes($dur) -and $a -lt $m.AddMinutes($OwnMinutes)) { $over = $a.ToString('ddd dd.MM. HH:mm'); break } }
                if ($over) { break }
            }
        }
        $rows += [pscustomobject]@{
            Ueberschneidung = $(if ($over) { "JA ($over)" } elseif (-not $enabled) { 'nein (deaktiviert)' } elseif ($Plan) { 'nein' } else { '' })
            Aufgabe = $full; Zustand = $(switch ("$($t.State)") { 'Ready' { 'Bereit' } 'Disabled' { 'Deaktiviert' } 'Running' { 'Laeuft' } default { "$($t.State)" } })
            Ausloeser = (Get-HMSbTriggerText $t)
            Naechster_Lauf = $(if ($info -and $info.NextRunTime) { $info.NextRunTime.ToString('dd.MM.yyyy HH:mm') } else { '' })
            Letzter_Lauf = $(if ($info -and $info.LastRunTime -and $info.LastRunTime.Year -gt 2000) { $info.LastRunTime.ToString('dd.MM.yyyy HH:mm') } else { '' })
            Suchwort = $(if ($hit.Count) { $hit -join ', ' } elseif ($isHumig) { 'HUMig' } else { '' })
            Aktion = $acts
        }
    }
    return ,@($rows | Sort-Object @{ E = { if ("$($_.Ueberschneidung)" -like 'JA*') { 0 } elseif ($_.Zustand -eq 'Deaktiviert') { 2 } else { 1 } } }, Aufgabe)
}
function Edit-HMSbConflictWords($Owner = $null) {
    $cur = @(Get-HMSbConflictWords) -join "`r`n"
    $t = Show-TextInputDialog -Title 'Suchwoerter fuer andere Sicherungsaufgaben' -Label "Ein Suchwort je Zeile - gesucht wird in Pfad, Name, Beschreibung und Aufruf aller geplanten Aufgaben (Gross/Klein egal).`nMit - davor = Aufgaben mit diesem Wort ausschliessen (z.B. -RegIdleBackup).`nLeer lassen = Standard: $($script:SbConflictDefault -join ', ')" -Text $cur -Owner $Owner -MultiLine
    if ($null -eq $t) { return $false }
    $list = @("$t" -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $cfg = Get-HMSbConfig
    $cfg.ConflictWords = $(if ($list.Count) { $list } else { $null })
    Save-HMSbConfig $cfg
    Out-Console "Server-Backup: Suchwoerter fuer andere Sicherungsaufgaben gespeichert ($(if ($list.Count) { $list -join ', ' } else { 'Standard' }))" 'Success'
    return $true
}
function Show-HMSbConflicts($Plan = $null, [string]$OwnPrefix = '', [double]$OwnMinutes = 360) {
    [System.Windows.Input.Mouse]::OverrideCursor = [System.Windows.Input.Cursors]::Wait
    try { $rows = Get-HMSbConflicts $Plan $OwnPrefix $OwnMinutes } finally { [System.Windows.Input.Mouse]::OverrideCursor = $null }
    $rows = @($rows)
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($r in $rows) { $list.Add(@($r.Ueberschneidung, $r.Aufgabe, $r.Zustand, $r.Ausloeser, $r.Naechster_Lauf, $r.Letzter_Lauf, $r.Suchwort, $r.Aktion)) }
    $n = @($rows | Where-Object { "$($_.Ueberschneidung)" -like 'JA*' }).Count
    Show-DataGridWindow -Title 'Server-Backup - andere Sicherungsaufgaben (Aufgabenplanung)' -Width 1300 -Height 480 `
        -Columns @('Ueberschneidung', 'Aufgabe', 'Zustand', 'Ausloeser', 'Naechster_Lauf', 'Letzter_Lauf', 'Suchwort', 'Aktion') -Rows $list.ToArray() `
        -CountText "$($rows.Count) Aufgabe(n) gefunden$(if ($Plan) { ", $n ueberschneiden sich (naechste 14 Tage)" }) - Suchwoerter: $((Get-HMSbConflictWords) -join ', ')" `
        -Actions @(@{ Text = 'Suchwoerter aendern ...'; Color = '#FFCBA6F7'; NoSelection = $true; Handler = { param($sel, $w, $c) if (Edit-HMSbConflictWords $w) { $w.Close(); Show-HMSbConflicts } } })
}

function New-HMSbSchedule {
    $p = Get-HMSbProfile
    if (-not $p) { Out-Console 'Zeitplan: zuerst ein Profil waehlen/anlegen.' 'Warning'; return }
    $vms = @(Get-HMSbCheckedVms)
    $vols = @(Get-HMSbCheckedVols)
    $hc = [bool]$ui.chkSbHostConfig.IsChecked; $hs = [bool]$ui.chkSbHostSystem.IsChecked; $vf = [bool]$ui.chkSbVerify.IsChecked
    if (-not $vms.Count -and -not $vols.Count -and -not $hs -and -not $hc) { Out-Console 'Zeitplan: nichts gewaehlt (VMs, Laufwerke, Host-Konfiguration oder System).' 'Warning'; return }
    foreach ($x in @($p.Name) + $vms) { if ("$x" -match '["|]') { Out-Console "Zeitplan: Name '$x' enthaelt ein nicht erlaubtes Zeichen (Anfuehrungszeichen oder |)." 'Error'; return } }
    $info = "Profil: $($p.Name)   (Platten $($p.DiskPrefix)-...)`nVMs ($($vms.Count)): $(if ($vms.Count) { $vms -join ', ' } else { '-' })`nLaufwerke: $(if ($vols.Count) { $vols -join ', ' } else { '-' })`nHost-Konfiguration: $(if ($hc) { 'ja' } else { 'nein' })   Pruefen: $(if ($vf) { 'ja' } else { 'nein' })   Host-System: $(if ($hs) { 'ja' } else { 'nein' })`n`nEs gelten die aktuell angehakten VMs und Optionen."
    if ($hs) { $sv = Format-HMSbSysDriveVms (Get-HMSbSysDriveVms $script:SbVms); if ($sv) { $info += "`n`n$sv" } }
    $r = Show-HMSbScheduleDialog $info
    if (-not $r) { return }
    # andere Sicherungsaufgaben, die sich ueberschneiden (naechste 14 Tage)
    try {
        $own = 'Server-Backup - {0} - ' -f ($p.Name -replace '[\\/:*?"<>|]', '_')
        $avg = 360.0
        try { $okr = @(Get-HMSbAllHistory | Where-Object { "$($_.Profile)" -eq $p.Name -and "$($_.Status)" -ne 'Error' -and [double]$_.Minutes -gt 0 }); if ($okr.Count) { $avg = [double](@($okr | ForEach-Object { [double]$_.Minutes }) | Measure-Object -Maximum).Maximum } } catch { }
        $cf = Get-HMSbConflicts $r $own $avg
        $hit = @(@($cf) | Where-Object { "$($_.Ueberschneidung)" -like 'JA*' })
        if ($hit.Count) {
            $m = "Diese Aufgaben laufen zur selben Zeit wie der geplante Lauf (angenommene Dauer $(Format-HMDuration $avg)) - die Windows Server-Sicherung kann nur einen Vorgang gleichzeitig:`n`n" + (@($hit | Select-Object -First 10 | ForEach-Object { "  $($_.Aufgabe)  [$($_.Ausloeser)]  -> $($_.Ueberschneidung)" }) -join "`n") + $(if ($hit.Count -gt 10) { "`n  ..." }) + "`n`nHUMig wartet zwar, bis der andere Vorgang fertig ist (hoechstens 8 h), besser ist aber eine andere Uhrzeit.`n`nJa = trotzdem planen`nNein = nicht planen (Uhrzeit aendern)`nAbbrechen = Liste aller gefundenen Aufgaben anzeigen"
            $ans = "$([System.Windows.MessageBox]::Show($script:Window, $m, 'Server-Backup planen', 'YesNoCancel', 'Warning'))"
            if ($ans -eq 'Cancel') { Show-HMSbConflicts $r $own $avg; return }
            if ($ans -ne 'Yes') { return }
        }
    } catch { Out-Console "Pruefung auf andere Sicherungsaufgaben nicht moeglich: $($_.Exception.Message)" 'Warning' }
    $task = Join-Path $script:AppRoot 'Functions\ServerBackup-Task.ps1'
    $arg = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$task`" -ProfileName `"$($p.Name)`""
    if ($vms.Count) { $arg += " -VMs `"$($vms -join '|')`"" }
    if ($vols.Count) { $arg += " -Volumes `"$($vols -join '|')`"" }
    if ($hc) { $arg += ' -HostConfig' }
    if ($hs) { $arg += ' -HostSystem' }
    if (-not $vf) { $arg += ' -NoVerify' }
    $arg += ' -Explicit'
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
    if (-not $rows.Count) { Out-Console 'Keine geplanten Server-Backups (Aufgabenplanung \HUMig) - angezeigt werden andere Sicherungsaufgaben am Host.' 'Info'; Show-HMSbConflicts; return }
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($r in $rows) { $list.Add(@($r.Name, $r.State, $r.Next, $r.Last, $r.Result, $r.Args)) }
    Show-DataGridWindow -Title 'Geplante Server-Backups (Aufgabenplanung \HUMig)' -Width 1200 -Height 420 `
        -Columns @('Name', 'Zustand', 'Naechster_Lauf', 'Letzter_Lauf', 'Ergebnis', 'Aufruf') -Rows $list.ToArray() `
        -CountText 'Ergebnis: OK / Warnung / Fehler - Details im Verlauf und in Logs\ServerBackup\Aufgabe_*.log' `
        -Actions @(
            @{ Text = 'Andere Sicherungsaufgaben ...'; Color = '#FFCBA6F7'; NoSelection = $true; Handler = { param($sel, $w, $c) Show-HMSbConflicts } },
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
    # sichtbar auf Windows Server (mit oder ohne Hyper-V) und auf PCs mit Hyper-V-Modul
    $isServer = $false
    try { $isServer = ([int](Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).ProductType -ne 1) } catch { }
    if ($script:UserMode -or -not $IsAdmin -or (-not $isServer -and -not (Get-Command Get-VM -ErrorAction SilentlyContinue))) { $tab.Visibility = 'Collapsed'; return }
    $script:SbButtons = @($ui.btnSbBackup, $ui.btnSbSchedule, $ui.btnSbProfileNew, $ui.btnSbProfileSave, $ui.btnSbProfileEdit, $ui.btnSbProfileDel, $ui.btnSbDrives, $ui.btnSbDiskSetup, $ui.btnSbEject, $ui.btnSbHostOnly, $ui.btnSbFeature)
    $ui.btnSbBackup.Add_Click({ Start-HMSbBackup })
    $ui.btnSbCancel.Add_Click($cancelAction)
    $ui.btnSbProfileNew.Add_Click({ New-HMSbProfile })
    $ui.btnSbProfileSave.Add_Click({ Save-HMSbProfile })
    $ui.btnSbProfileEdit.Add_Click({ Edit-HMSbProfile })
    $ui.btnSbProfileDel.Add_Click({ Remove-HMSbProfile })
    $ui.btnSbDrives.Add_Click({ Update-HMSbVms; Update-HMSbDrives -All })
    $ui.btnSbDiskSetup.Add_Click({ Show-HMSbDiskSetup })
    $ui.btnSbEject.Add_Click({ Invoke-HMSbEject })
    $ui.btnSbOpenDrive.Add_Click({
        $d = Get-HMSbDrive
        $f = if ($d) { "$($d.Letter):\$($script:SbDirName)" } else { $script:SbReportDir }
        if (-not (Test-Path -LiteralPath $f)) { $f = if ($d) { "$($d.Letter):\" } else { $script:LogDir } }
        try { Start-Process explorer.exe -ArgumentList "`"$f`"" } catch { }
    })
    $ui.btnSbVersions.Add_Click({ Show-HMSbVersions })
    $ui.dgSbHistory.Add_MouseDoubleClick({ $it = $ui.dgSbHistory.SelectedItem; if ($it -and $it.Entry) { Open-HMSbReport $it.Entry } })
    # Kontextmenue: Bericht oeffnen, markierte / alle fehlgeschlagenen aus dem Verlauf entfernen
    $cm = New-Object System.Windows.Controls.ContextMenu
    $mi1 = New-Object System.Windows.Controls.MenuItem; $mi1.Header = 'Bericht oeffnen'
    $mi1.Add_Click({ $it = $ui.dgSbHistory.SelectedItem; if ($it -and $it.Entry) { Open-HMSbReport $it.Entry } })
    $mi2 = New-Object System.Windows.Controls.MenuItem; $mi2.Header = 'Markierte aus dem Verlauf entfernen'
    $mi2.Add_Click({ $k = @(@($ui.dgSbHistory.SelectedItems) | Where-Object { $_.Entry } | ForEach-Object { "$($_.Entry.Date)|$($_.Entry.Host)|$($_.Entry.Disk)" }); if ($k.Count) { Remove-HMSbRuns $k } })
    $mi3 = New-Object System.Windows.Controls.MenuItem; $mi3.Header = 'Alle fehlgeschlagenen dieses Profils aus dem Verlauf entfernen'
    $mi3.Add_Click({
        $k = @(@($ui.dgSbHistory.ItemsSource) | Where-Object { $_.Entry -and "$($_.Entry.Status)" -eq 'Error' } | ForEach-Object { "$($_.Entry.Date)|$($_.Entry.Host)|$($_.Entry.Disk)" })
        if ($k.Count) { Remove-HMSbRuns $k } else { Out-Console 'Server-Backup: keine fehlgeschlagenen Laeufe in diesem Profil.' 'Info' }
    })
    foreach ($m in @($mi1, (New-Object System.Windows.Controls.Separator), $mi2, $mi3)) { [void]$cm.Items.Add($m) }
    $ui.dgSbHistory.ContextMenu = $cm
    $ui.dgSbHistory.ToolTip = 'Doppelklick = Bericht des Laufs oeffnen - Rechtsklick = Laeufe aus dem Verlauf entfernen'
    $ui.dgSbHistory.SelectionMode = 'Extended' 
    $ui.btnSbOverview.Add_Click({ Show-HMSbOverview })
    $ui.btnSbOverview.Add_MouseRightButtonUp({ param($s, $e) $e.Handled = $true; Show-HMSbAllRuns })
    $ui.btnSbHostOnly.Add_Click({ Start-HMSbHostOnly })
    $ui.btnSbSchedule.Add_Click({ New-HMSbSchedule })
    $ui.btnSbSchedule.Add_MouseRightButtonUp({ param($s, $e) $e.Handled = $true; Show-HMSbSchedules })
    if ($ui.btnSbConflicts) { $ui.btnSbConflicts.Add_Click({ Show-HMSbConflicts }) }
    $ui.btnSbRestore.Add_Click({ Show-HMSbRestoreHelp })
    $ui.btnSbFeature.Add_Click({ Install-HMSbFeature })
    $ui.chkSbHostSystem.Add_Click({ if ($ui.chkSbHostSystem.IsChecked) { Out-Console 'Host-System: sichert nur den Host (C:, Boot/EFI) fuer eine Bare-Metal-Wiederherstellung - Datenlaufwerke mit VMs (z.B. D:) sind nicht dabei, dafuer die VM-Sicherung. Liegen VMs auf C:, werden sie zusaetzlich gesichert (Platz!).' 'Info'; $sv = Format-HMSbSysDriveVms (Get-HMSbSysDriveVms $script:SbVms); if ($sv) { foreach ($ln in ($sv -split "`n")) { Out-Console $ln $(if ($ln -like 'ACHTUNG*') { 'Warning' } else { 'Info' }) } } else { Out-Console "Keine VM hat Dateien auf $($env:SystemDrive) - das Host-System bleibt klein." 'Success' } } })
    $ui.cmbSbProfile.Add_SelectionChanged({
        if ($script:SbSuppress -or $null -eq $ui.cmbSbProfile.SelectedItem) { return }
        Save-HMSbLastProfile "$($ui.cmbSbProfile.SelectedItem)"
        Set-HMSbFromProfile
    })
    $ui.cmbSbAfter.Add_SelectionChanged({ Set-HMSbAfterMode })
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
