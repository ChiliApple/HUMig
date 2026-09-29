#Requires -Version 5.1
<#
.SYNOPSIS
    Assistent "Programm hinzufuegen": ein installiertes Programm waehlen, HUMig schlaegt vor, was mitgesichert wird.
.DESCRIPTION
    1. Programm aus der Liste der installierten Programme des gewaehlten PCs waehlen (Erkennung wird automatisch erstellt).
    2. HUMig sucht am PC Ordner und Registry-Schluessel mit Hersteller-/Programmnamen: AppData Roaming/Local/LocalLow,
       Dokumente, ProgramData, HKCU\Software, HKLM\SOFTWARE (+WOW6432Node) und im Programmordner Unterordner fuer
       Plug-ins/Add-ins/Vorlagen/Konfiguration sowie Lizenzdateien. Caches/Logs werden automatisch ausgelassen.
    3. Vorschlaege mit Groesse zum Abhaken, Programm vorher schliessen (Prozessnamen aus dem Programmordner).
    4. Speichern (Config\apps.json) - oder im Katalog-Editor verfeinern.
.NOTES
    Wird im UI-Thread geladen (dot-source aus HUMig.ps1). Vorschlaege sind Heuristik (Ordnernamen) - immer zum Abhaken, nie automatisch.
    Zielmaschine der Suche: der oben gewaehlte PC, Benutzer: das oben gewaehlte Profil.
#>

# Suche am Ziel-PC (lokal oder per Invoke-Command). Rueckgabe: ein Objekt mit Clean, Install, HiveLoaded, Candidates, Exes, Running
$script:RS_AppScan = {
    param([string]$DisplayName, [string]$Publisher, [string]$ProfilePath, [string]$Sid)
    $norm = { param($s) ("$s".ToLowerInvariant() -replace '[^a-z0-9]', '') }
    $stop = @('for', 'the', 'and', 'und', 'fuer', 'der', 'die', 'das', 'app', 'apps', 'desktop', 'client', 'edition', 'version', 'update', 'updater', 'setup',
        'installer', 'tools', 'tool', 'software', 'suite', 'runtime', 'x64', 'x86', 'bit', 'professional', 'pro', 'free', 'home', 'plus', 'user', 'machine',
        'system', 'service', 'helper', 'driver', 'drivers', 'manager', 'studio', 'reader', 'viewer', 'player', 'media', 'program', 'programm', 'windows', 'win',
        'language', 'pack', 'german', 'deutsch', 'english', 'office', 'online', 'portable', 'standard', 'enterprise', 'community', 'express')
    # Anzeigename bereinigen: Klammern, Sprachzusatz, Version, Architektur
    $clean = "$DisplayName" -replace '\s*[\(\[].*?[\)\]]', ''
    $clean = $clean -replace '\s+-\s+.*$', ''
    $clean = $clean -replace '(?i)\s+(v(ersion)?\s*)?\d+([\.\-_]\d+)*\b.*$', ''
    $clean = ($clean -replace '(?i)\s+(x64|x86|64-bit|32-bit|64 bit|32 bit)\b.*$', '').Trim()
    if (-not $clean) { $clean = "$DisplayName".Trim() }
    $pubClean = ("$Publisher" -replace '(?i)[,\.]?\s*\b(inc|ltd|gmbh|ag|kg|llc|corp|corporation|co|company|team|foundation|project|software|systems|technologies|limited|s\.r\.o|sa|bv|oy|ab|srl|development|contributors)\b\.?', '' -replace '\s+', ' ').Trim(' ', ',', '.')
    $pubTokens = @($pubClean -split '[\s,]+' | Where-Object { $_.Length -ge 2 })
    $pubNorms = @($pubTokens | ForEach-Object { & $norm $_ })
    $pubKey = if ($pubTokens.Count) { & $norm $pubTokens[0] } else { '' }
    $pubFull = & $norm $pubClean
    $broad = @('microsoft', 'google', 'adobe', 'apple', 'intel', 'nvidia', 'amd', 'hp', 'hewlett', 'dell', 'lenovo', 'oracle', 'mozilla', 'mcafee', 'norton', 'realtek')
    $words = @($clean -split '[\s_]+' | Where-Object { $_ })
    $full = & $norm $clean
    $fullNoPub = & $norm ((@($words | Where-Object { $pubNorms -notcontains (& $norm $_) })) -join '')
    $tok = @($words | ForEach-Object { & $norm $_ } | Where-Object { $_.Length -ge 3 -and $stop -notcontains $_ -and $pubNorms -notcontains $_ })
    $keys = @(@($full, $fullNoPub) + $tok | Where-Object { $_ } | Select-Object -Unique)
    $isProd = { param($n) $k = & $norm $n; [bool]($k -and ($keys -contains $k)) }
    $isPub = { param($n) $k = & $norm $n; [bool]($k -and $pubKey -and ($k -eq $pubKey -or $k -eq $pubFull)) }
    $xdNames = @('*Cache*', 'Crash*', 'Temp', 'tmp', 'Logs', 'ShaderCache', 'Service Worker', 'blob_storage')
    $sizeOf = {
        param($dir)
        $t0 = [DateTime]::Now; $b = [long]0; $n = 0; $partial = $false
        $st = New-Object System.Collections.Generic.Stack[string]; $st.Push($dir)
        while ($st.Count) {
            if (([DateTime]::Now - $t0).TotalSeconds -gt 6 -or $n -gt 100000) { $partial = $true; break }
            $d = $st.Pop()
            try {
                foreach ($i in (New-Object System.IO.DirectoryInfo $d).EnumerateFileSystemInfos()) {
                    if ($i.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
                    if ($i -is [System.IO.DirectoryInfo]) { $skip = $false; foreach ($x in $xdNames) { if ($i.Name -like $x) { $skip = $true; break } }; if (-not $skip) { $st.Push($i.FullName) }; continue }
                    $n++; $b += $i.Length
                }
            } catch { }
        }
        @{ MB = [math]::Round($b / 1MB, 1); Files = $n; Partial = $partial }
    }
    $cands = [System.Collections.Generic.List[object]]::new()
    $addDir = {
        param($kind, $path, $role, [bool]$checked, $note, [bool]$useXd)
        foreach ($c in $cands) { if ($c.Path -and $c.Path -ieq $path) { return } }
        $sz = & $sizeOf $path
        $cands.Add([pscustomobject]@{ Kind = $kind; Type = 'Folder'; Path = $path; Key = ''; Filter = @(); Role = $role; Checked = $checked; SizeMB = $sz.MB; Files = $sz.Files; Partial = $sz.Partial; Note = $note; XD = $(if ($useXd) { $xdNames } else { @() }) })
    }
    # --- Ordner in AppData, Dokumente, ProgramData ---
    $bases = [ordered]@{}
    if ($ProfilePath) {
        $bases['AppData Roaming'] = Join-Path $ProfilePath 'AppData\Roaming'
        $bases['AppData Local'] = Join-Path $ProfilePath 'AppData\Local'
        $bases['AppData LocalLow'] = Join-Path $ProfilePath 'AppData\LocalLow'
        $bases['Dokumente'] = Join-Path $ProfilePath 'Documents'
    }
    if ($env:ProgramData) { $bases['ProgramData'] = $env:ProgramData }
    foreach ($bk in $bases.Keys) {
        $base = $bases[$bk]
        if (-not (Test-Path -LiteralPath $base)) { continue }
        $inDocs = ($bk -eq 'Dokumente')
        foreach ($d in @(Get-ChildItem -LiteralPath $base -Directory -Force -ErrorAction SilentlyContinue)) {
            if (& $isProd $d.Name) {
                & $addDir $bk $d.FullName 'Settings' (-not $inDocs) $(if ($inDocs) { 'in Dokumente - meist schon im Profil-Backup' } else { '' }) (-not $inDocs)
            } elseif (& $isPub $d.Name) {
                $hit = $false
                foreach ($s in @(Get-ChildItem -LiteralPath $d.FullName -Directory -Force -ErrorAction SilentlyContinue)) {
                    if (& $isProd $s.Name) { $hit = $true; & $addDir $bk $s.FullName 'Settings' (-not $inDocs) '' (-not $inDocs) }
                }
                if (-not $hit -and $broad -notcontains $pubKey) { & $addDir $bk $d.FullName 'Settings' $false 'Herstellerordner - kann mehrere Programme enthalten' (-not $inDocs) }
            }
        }
    }
    # --- Registry ---
    $hive = [bool]($Sid -and (Test-Path -LiteralPath "Registry::HKEY_USERS\$Sid"))
    $regBases = @()
    if ($hive) { $regBases += @{ Kind = 'Registry Benutzer'; Ps = "Registry::HKEY_USERS\$Sid\Software"; Disp = 'HKCU\Software'; Checked = $true } }
    $regBases += @{ Kind = 'Registry Maschine'; Ps = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE'; Disp = 'HKLM\SOFTWARE'; Checked = $false }
    $regBases += @{ Kind = 'Registry Maschine 32-Bit'; Ps = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node'; Disp = 'HKLM\SOFTWARE\WOW6432Node'; Checked = $false }
    $addReg = {
        param($rb, $rel)
        $key = "$($rb.Disp)\$rel"
        foreach ($c in $cands) { if ($c.Key -ieq $key) { return } }
        $cands.Add([pscustomobject]@{ Kind = $rb.Kind; Type = 'Reg'; Path = ''; Key = $key; Filter = @(); Role = 'Settings'; Checked = $rb.Checked; SizeMB = $null; Files = 0; Partial = $false
            Note = $(if (-not $rb.Checked) { 'Maschine - nur wenn Einstellungen dort liegen (Restore nur als Administrator)' } else { '' }); XD = @() })
    }
    foreach ($rb in $regBases) {
        foreach ($k in @(Get-ChildItem -LiteralPath $rb.Ps -ErrorAction SilentlyContinue)) {
            $n = $k.PSChildName
            if ($n -in @('Classes', 'Policies', 'WOW6432Node', 'Clients', 'RegisteredApplications', 'Microsoft')) { continue }
            if (& $isProd $n) { & $addReg $rb $n }
            elseif (& $isPub $n) {
                $hit = $false
                foreach ($s in @(Get-ChildItem -LiteralPath $k.PSPath -ErrorAction SilentlyContinue)) { if (& $isProd $s.PSChildName) { $hit = $true; & $addReg $rb "$n\$($s.PSChildName)" } }
                if (-not $hit -and $broad -notcontains $pubKey -and $rb.Checked) { & $addReg $rb $n }
            }
        }
    }
    # --- Programmordner (InstallLocation) ---
    $inst = ''
    $unRoots = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')
    if ($Sid) { $unRoots += "Registry::HKEY_USERS\$Sid\Software\Microsoft\Windows\CurrentVersion\Uninstall" }
    foreach ($ur in $unRoots) {
        foreach ($k in @(Get-ChildItem -LiteralPath $ur -ErrorAction SilentlyContinue)) {
            $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
            if ("$($p.DisplayName)".Trim() -ne "$DisplayName".Trim()) { continue }
            $inst = "$($p.InstallLocation)".Trim().Trim('"')
            if (-not $inst -and "$($p.DisplayIcon)") { $ic = ("$($p.DisplayIcon)" -split ',')[0].Trim().Trim('"'); if ($ic -match '\.exe$') { $inst = Split-Path $ic -Parent } }
            break
        }
        if ($inst) { break }
    }
    $inst = $inst.TrimEnd('\')
    $generic = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:SystemDrive, $env:windir, $env:ProgramData) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') }
    if ($inst -and (($generic -contains $inst) -or -not (Test-Path -LiteralPath $inst -PathType Container))) { $inst = '' }
    $exes = @(); $running = @()
    if ($inst) {
        $roles = @(@('^(plugins?|plug-ins|addins?|add-ins|addons?|extensions?|modules?)$', 'Plugins'), @('^(templates?|vorlagen)$', 'Template'), @('^(config|configuration|settings|cfg|conf|ini)$', 'Settings'), @('^(data|userdata|user|profiles?)$', 'Data'), @('^(licen[cs]es?|lizenz(en)?)$', 'License'))
        foreach ($d in @(Get-ChildItem -LiteralPath $inst -Directory -Force -ErrorAction SilentlyContinue)) {
            foreach ($r in $roles) { if ($d.Name -match $r[0]) { & $addDir 'Programmordner' $d.FullName $r[1] $true 'Programmordner (nicht das ganze Programm) - passt meist nur bei gleicher Programmversion' $false; break } }
        }
        $lic = @(Get-ChildItem -LiteralPath $inst -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '(?i)(\.lic|\.key|\.license|\.licence)$|^licen[cs]e.*\.(dat|txt|xml|key)$|^lizenz' } | ForEach-Object { $_.Name })
        if ($lic.Count) {
            $cands.Add([pscustomobject]@{ Kind = 'Programmordner'; Type = 'Files'; Path = $inst; Key = ''; Filter = @($lic); Role = 'License'; Checked = $true; SizeMB = $null; Files = $lic.Count; Partial = $false; Note = "Lizenzdatei(en): $($lic -join ', ')"; XD = @() })
        }
        $exeDirs = @($inst) + @(Join-Path $inst 'bin' | Where-Object { Test-Path -LiteralPath $_ })
        $exes = @(foreach ($ed in $exeDirs) { Get-ChildItem -LiteralPath $ed -Filter *.exe -File -ErrorAction SilentlyContinue | Where-Object { $_.BaseName -notmatch '(?i)^(unins|uninstall|update|updater|setup|install|crash|report|elevat|notif|maintenance|repair|register|helper|vc_?redist)' } | ForEach-Object { $_.BaseName } }) | Select-Object -Unique
        $running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { try { $_.Path -and $_.Path.StartsWith($inst + '\', [StringComparison]::OrdinalIgnoreCase) } catch { $false } } | ForEach-Object { $_.ProcessName } | Select-Object -Unique)
    }
    [pscustomobject]@{ Clean = $clean; Install = $inst; HiveLoaded = $hive; Candidates = @($cands); Exes = @($exes); Running = @($running); Keys = ($keys -join ', ') }
}

# ----------------------------------------------------------------------------
# Ablauf. ForEditor = aus dem offenen Katalog-Editor (Ergebnis wird dort als neuer Eintrag geladen)
# ----------------------------------------------------------------------------
function Start-HMAppWizard([switch]$ForEditor) {
    if ($script:UserMode -and -not $ForEditor) { Out-Console 'Programm hinzufuegen: im Benutzer-Modus nicht moeglich (Config-Ordner).' 'Warning'; return }
    $comp = Get-TargetComputer
    $p = Get-SelectedProfile
    $sid = if ($p -and -not $p.NoProfile) { "$($p.SID)" } else { '' }
    $st = @{ ForEditor = [bool]$ForEditor; Comp = $comp; Sid = $sid; Profile = $(if ($p -and -not $p.NoProfile) { "$($p.LocalPath)" } else { '' }) }
    if (-not $st.Profile) { Out-Console 'Programm hinzufuegen: bitte oben zuerst einen Benutzer mit Profil waehlen (Verbinden) - dessen Einstellungen werden untersucht.' 'Warning' }
    if ($script:DetectedSoftware -and $script:DetectedFor -eq "$comp|$sid") { Show-HMAwPickProgram @($script:DetectedSoftware) $st; return }
    Out-Console "Programm hinzufuegen: installierte Programme an $comp lesen ..." 'Info'
    Get-HMSoftwareAsync -Computer $comp -Sid $sid -State $st -OnDone {
        param($sw, $s)
        if ($null -eq $sw) { Out-Console "$($s.Computer) nicht erreichbar - Programmliste nicht lesbar" 'Error'; return }
        Show-HMAwPickProgram @($sw) $s.State
    }
}
function Show-HMAwPickProgram([object[]]$Software, [hashtable]$St) {
    $owner = if ($St.ForEditor -and $script:Ae) { $script:Ae.Win } else { $script:Window }
    $rows = @($Software | Where-Object { $_.Name } | Sort-Object Name -Unique | ForEach-Object {
        $n = "$($_.Name)"
        $inCat = @($script:AppCatalog | Where-Object { "$($_.Detect)" -and $(try { $n -match "$($_.Detect)" } catch { $false }) } | Select-Object -First 1)
        [pscustomobject]@{ Tag = $n; Text = "$n   $($_.Version)$(if ($_.Publisher) { "   ($($_.Publisher))" })$(if ($inCat.Count) { "   [im Katalog: $($inCat[0].Name)]" })"; Pub = "$($_.Publisher)" }
    })
    $sel = @(Show-HMAePick "Programm hinzufuegen - Programm an $($St.Comp) waehlen" $rows -Single -Owner $owner)
    if (-not $sel.Count) { return }
    $row = @($rows | Where-Object { $_.Tag -eq $sel[0] })[0]
    $hit = @($script:AppCatalog | Where-Object { "$($_.Detect)" -and $(try { $row.Tag -match "$($_.Detect)" } catch { $false }) } | Select-Object -First 1)
    if ($hit.Count) {
        $a = "$([System.Windows.MessageBox]::Show($owner, "'$($row.Tag)' ist schon im Katalog: $($hit[0].Name)`n`nJa = diesen Eintrag im Editor bearbeiten`nNein = trotzdem einen neuen Eintrag anlegen", 'Programm hinzufuegen', 'YesNoCancel', 'Question'))"
        if ($a -eq 'Cancel') { return }
        if ($a -eq 'Yes') {
            if ($St.ForEditor -and $script:Ae) { if (Confirm-HMAeDiscard) { Select-HMAeListItem "$($hit[0].Id)" } } else { Show-HMAppEditor -SelectId "$($hit[0].Id)" }
            return
        }
    }
    $St.Program = $row.Tag
    Invoke-HMTool -Title "Programm untersuchen: $($row.Tag)" -Computer $St.Comp -TimeoutSec 300 -ArgumentList @($row.Tag, $row.Pub, $St.Profile, $St.Sid) -Script $script:RS_AppScan -State $St -OnResult {
        param($r, $comp, $s)
        $res = @($r | Where-Object { $_ -and $_.PSObject.Properties['Candidates'] })[0]
        if (-not $res) { Out-Console "Untersuchung ohne Ergebnis: $r" 'Error'; return }
        Show-HMAwDialog $res $s
    }
}

# Dialog mit den Vorschlaegen
function Show-HMAwDialog($Res, [hashtable]$St) {
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Programm hinzufuegen" Width="1050" Height="720" MinWidth="800" MinHeight="500" WindowStartupLocation="CenterOwner" Background="#FF1E1E2E">
  <DockPanel Margin="12">
    <StackPanel DockPanel.Dock="Top">
      <TextBlock x:Name="head" Foreground="#FFCDD6F4" FontSize="16" FontWeight="SemiBold" Margin="0,0,0,6"/>
      <Grid Margin="0,0,0,6">
        <Grid.ColumnDefinitions><ColumnDefinition Width="90"/><ColumnDefinition Width="*"/><ColumnDefinition Width="90"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <TextBlock Text="Name" Foreground="#FFA6ADC8" VerticalAlignment="Center"/>
        <TextBox x:Name="tName" Grid.Column="1" Style="{DynamicResource DarkTextBox}" Margin="0,0,10,0"/>
        <TextBlock Grid.Column="2" Text="Erkennung" Foreground="#FFA6ADC8" VerticalAlignment="Center" ToolTip="Woran HUMig das Programm erkennt (Anfang des Namens in 'Apps &amp; Features') - normalerweise nicht aendern"/>
        <TextBox x:Name="tDetect" Grid.Column="3" Style="{DynamicResource DarkTextBox}"/>
      </Grid>
      <TextBlock x:Name="info" Foreground="#FFA6ADC8" TextWrapping="Wrap" Margin="0,0,0,6"/>
      <TextBlock Text="WAS SOLL MITGESICHERT WERDEN? (Vorschlaege - Haken setzen oder entfernen)" Foreground="#FF89B4FA" FontWeight="SemiBold" Margin="0,4,0,4"/>
    </StackPanel>
    <StackPanel DockPanel.Dock="Bottom">
      <Border Background="#FF181825" CornerRadius="6" Padding="8" Margin="0,8,0,8">
        <StackPanel>
          <CheckBox x:Name="xClose" Content="Programm vor Backup und Restore schliessen - Prozessname(n) ohne .exe:"/>
          <TextBox x:Name="tClose" Style="{DynamicResource DarkTextBox}" Margin="22,4,0,0" ToolTip="Mit ; trennen, z.B. thunderbird"/>
        </StackPanel>
      </Border>
      <TextBlock x:Name="note" Foreground="#FF6C7086" TextWrapping="Wrap" FontSize="11" Margin="0,0,0,8"/>
      <DockPanel>
        <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
          <Button x:Name="bSave" Content="Speichern" Style="{DynamicResource BtnGreen}" Width="120" FontWeight="Bold"/>
          <Button x:Name="bEditor" Content="Erweitert (Editor) ..." Style="{DynamicResource BtnMauve}"/>
          <Button x:Name="bCancel" Content="Abbrechen" Style="{DynamicResource BtnDefault}" Margin="0"/>
        </StackPanel>
        <TextBlock x:Name="state" Foreground="#FFF9E2AF" VerticalAlignment="Center" TextWrapping="Wrap"/>
      </DockPanel>
    </StackPanel>
    <ListBox x:Name="list"/>
  </DockPanel>
</Window>
'@
    $w = [System.Windows.Markup.XamlReader]::Parse($x)
    $w.Resources.MergedDictionaries.Add($script:Window.Resources)
    if ($script:AppIcon) { $w.Icon = $script:AppIcon }
    $f = @{}
    foreach ($n in @('head', 'tName', 'tDetect', 'info', 'xClose', 'tClose', 'note', 'bSave', 'bEditor', 'bCancel', 'state', 'list')) { $f[$n] = $w.FindName($n) }
    $cands = @($Res.Candidates | Where-Object { $_ })
    $f.head.Text = "Programm hinzufuegen: $($St.Program)"
    $f.tName.Text = "$($Res.Clean)"
    $f.tDetect.Text = '^' + ([regex]::Escape("$($Res.Clean)") -replace '\\ ', ' ')
    $inf = @()
    $inf += "PC: $($St.Comp)$(if ($St.Profile) { "   Benutzer-Profil: $($St.Profile)" })"
    $inf += $(if ($Res.Install) { "Programmordner: $($Res.Install)" } else { 'Programmordner: nicht gefunden (nur AppData/Registry durchsucht)' })
    if (-not $Res.HiveLoaded -and $St.Sid) { $inf += 'Benutzer-Registry nicht geladen (Benutzer nicht angemeldet) - HKCU wurde nicht durchsucht.' }
    $inf += "Gesucht nach: $($Res.Keys)"
    $f.info.Text = $inf -join "`n"
    $f.note.Text = 'Caches, Logs und Temp-Ordner werden bei AppData/ProgramData automatisch ausgelassen. Gespeicherte Kennwoerter (Windows-Verschluesselung) sind meist nicht uebertragbar. Nicht passende Vorschlaege einfach abhaken - gesucht wird nach Ordnernamen, die dem Programm- oder Herstellernamen entsprechen.'
    $boxes = [System.Collections.Generic.List[object]]::new()
    foreach ($c in $cands) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $w1 = if ($c.Type -eq 'Reg') { $c.Key } elseif ($c.Type -eq 'Files') { "$($c.Path)\$(@($c.Filter) -join ';')" } else { $c.Path }
        $sz = if ($c.Type -eq 'Folder') { "   $(if ($c.Partial) { '>' })$($c.SizeMB) MB, $($c.Files) Dateien" } else { '' }
        $cb.Content = "[$($c.Kind)]  $w1$sz$(if ($c.Note) { "   - $($c.Note)" })"
        $cb.IsChecked = [bool]$c.Checked
        $cb.Tag = $c
        $cb.Margin = [System.Windows.Thickness]::new(2, 3, 2, 3)
        [void]$f.list.Items.Add($cb)
        $boxes.Add($cb)
    }
    if (-not $cands.Count) { $f.state.Text = 'Nichts gefunden - im Editor Ordner von Hand eintragen (Erweitert).' }
    $procs = @(@($Res.Running) + @(@($Res.Exes) | Where-Object { $n = ($_ -replace '[^A-Za-z0-9]', '').ToLower(); $n -and ("$($Res.Keys)" -replace '[^a-z0-9,]', '').Split(',') -contains $n }) | Where-Object { $_ } | Select-Object -Unique)
    if (-not $procs.Count -and @($Res.Exes).Count -eq 1) { $procs = @($Res.Exes) }
    $f.tClose.Text = ($procs -join ';')
    $f.xClose.IsChecked = [bool]$procs.Count
    if (@($Res.Exes).Count) { $f.tClose.ToolTip = "Programme im Programmordner: $(@($Res.Exes) -join ', ')`nMit ; trennen" }
    $script:Aw = @{ Win = $w; F = $f; Boxes = $boxes; St = $St; Res = $Res; Result = $null }
    $f.bSave.Content = $(if ($St.ForEditor) { 'Uebernehmen' } else { 'Speichern' })
    if ($St.ForEditor) { $f.bEditor.Visibility = 'Collapsed' }
    $f.bSave.Add_Click({ Complete-HMAw 'Save' })
    $f.bEditor.Add_Click({ Complete-HMAw 'Editor' })
    $f.bCancel.Add_Click({ $script:Aw.Win.Close() })
    $w.Owner = $(if ($St.ForEditor -and $script:Ae) { $script:Ae.Win } else { $script:Window }); Set-HMWindowScale $w
    [void]$w.ShowDialog()
    $res = $script:Aw.Result
    $script:Aw = $null
    if (-not $res) { return }
    if ($St.ForEditor -and $script:Ae) {
        $e = ConvertTo-HMAeEntry $res.Obj
        $base = $e.Id; $c = 2
        while (@($script:Ae.All | Where-Object { $_.Id -ieq $e.Id }).Count) { $e.Id = "$base$c"; $c++ }
        Set-HMAeForm $e 'eigen' $true
        $script:Ae.F.lState.Text = 'Eintrag aus dem Assistenten - pruefen und Speichern'
    } elseif ($res.Mode -eq 'Editor') {
        Show-HMAppEditor -NewEntry $res.Obj
    }
}
# Eintrag aus den Haken bauen
function New-HMAwEntry {
    $f = $script:Aw.F
    $name = "$($f.tName.Text)".Trim()
    $items = [System.Collections.Generic.List[object]]::new()
    $used = @{}
    $mkName = { param($b) $n = $b; $i = 2; while ($used.ContainsKey($n)) { $n = "$b$i"; $i++ }; $used[$n] = 1; $n }
    $kinds = @()
    foreach ($cb in $script:Aw.Boxes) {
        if (-not $cb.IsChecked) { continue }
        $c = $cb.Tag
        $base = switch -Regex ("$($c.Kind)") {
            'Roaming' { 'ROAMING' } 'LocalLow' { 'LOCALLOW' } 'Local' { 'LOCAL' } 'Dokumente' { 'DOCS' } 'ProgramData' { 'PROGDATA' }
            'Registry Benutzer' { 'REG' } 'Registry Maschine' { 'REGLM' }
            default { switch ("$($c.Role)") { 'Plugins' { 'PLUGINS' } 'Template' { 'TEMPLATES' } 'License' { 'LIC' } 'Data' { 'DATA' } default { 'CONFIG' } } }
        }
        $it = [ordered]@{ Type = $c.Type; Name = (& $mkName $base) }
        if ($c.Type -eq 'Reg') { $it.Key = "$($c.Key)" } else { $it.Path = (ConvertTo-HMAeToken "$($c.Path)") }
        if ($c.Type -eq 'Files') { $it.Filter = @($c.Filter) }
        if (@($c.XD).Count) { $it.XD = @($c.XD) }
        if ("$($c.Role)" -eq 'License') { $it.License = $true }
        if ("$($c.Role)") { $it.Role = "$($c.Role)" }
        $items.Add([pscustomobject]$it)
        $kinds += $(switch ("$($c.Role)") { 'Plugins' { 'Plug-ins/Add-ins' } 'Template' { 'Vorlagen' } 'License' { 'Lizenzdatei' } 'Data' { 'Daten' } default { if ($c.Type -eq 'Reg') { 'Registry' } else { 'Einstellungen' } } })
    }
    $procs = @()
    if ($f.xClose.IsChecked) { $procs = @("$($f.tClose.Text)" -split '[;,\s]+' | ForEach-Object { $_.Trim() -replace '\.exe$', '' } | Where-Object { $_ } | Select-Object -Unique) }
    $idBase = 'App_' + (($name -replace '[^A-Za-z0-9_\-]', ''))
    if ($idBase -eq 'App_') { $idBase = 'App_Programm' }
    $o = [ordered]@{ Id = $idBase; Name = $name; Detect = "$($f.tDetect.Text)".Trim() }
    if ($items.Count) { $o.Items = @($items) }
    $o.Transfer = $(if ($kinds.Count) { (@($kinds | Select-Object -Unique) -join ', ') } else { '' })
    if ($procs.Count) { $o.CloseProcess = @($procs) }
    $o.After = @("${name}: Programm starten und Einstellungen pruefen")
    $o.Verified = [pscustomobject]@{ Note = "Mit dem Assistenten angelegt am $(Get-Date -Format 'yyyy-MM-dd') (Vorschlaege nach Ordnernamen, nicht vom Hersteller bestaetigt)" }
    return [pscustomobject]$o
}
function Complete-HMAw([string]$Mode) {
    $aw = $script:Aw
    $obj = New-HMAwEntry
    if ($Mode -eq 'Editor' -or $aw.St.ForEditor) { $aw.Result = @{ Mode = $Mode; Obj = $obj }; $aw.Win.Close(); return }
    # Direkt speichern: Editor-Datenfunktionen nutzen (eigener Zustand, Editor ist hier nicht offen)
    $script:Ae = @{ Saved = $false }
    try {
        Import-HMAeData
        $base = "$($obj.Id)"; $c = 2
        while (@($script:Ae.All | Where-Object { $_.Id -ieq $obj.Id }).Count) { $obj.Id = "$base$c"; $c++ }
        $err = @(Test-HMAeEntry (ConvertTo-HMAeEntry $obj) $true)
        if (-not @($obj.Items).Count) { $err = @('Nichts angehakt - mindestens einen Ordner oder Registry-Schluessel waehlen (oder Erweitert).') + $err }
        if ($err.Count) { [void][System.Windows.MessageBox]::Show($aw.Win, "Bitte korrigieren:`n`n- $($err -join "`n- ")", 'Programm hinzufuegen', 'OK', 'Warning'); return }
        $obj = ConvertFrom-HMAeEntry (ConvertTo-HMAeEntry $obj)   # gleiche Form wie aus dem Editor
        Write-HMAeLocal (@($script:Ae.Local) + @($obj))
    } catch {
        [void][System.Windows.MessageBox]::Show($aw.Win, "Speichern fehlgeschlagen: $($_.Exception.Message)", 'Programm hinzufuegen', 'OK', 'Error'); return
    } finally { $script:Ae = $null }
    Out-Console "Programm-Katalog: '$($obj.Name)' hinzugefuegt ($(@($obj.Items).Count) Eintraege$(if ($obj.CloseProcess) { ", schliesst $(@($obj.CloseProcess) -join ', ')" })) - Config\apps.json" 'Success'
    $aw.Result = @{ Mode = 'Saved'; Obj = $obj }
    $aw.Win.Close()
    Update-HMAeCatalog
}
