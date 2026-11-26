#Requires -Version 5.1
# Pester-Tests (Pester 5): Regeln der Oberflaeche fuer Haupt- und Einstellungsfenster.
# Geprueft wird das XAML (Tooltips, Farbstile, Anfasser, Start und Abbrechen in einer Zelle), dass alle im Code
# verwendeten Namen im XAML stehen, und dass Set-JobUi Start und Abbrechen richtig umschaltet. Ohne Laufwerke, ohne Adminrechte.

BeforeDiscovery {
    # WPF-Fenster lassen sich nur in einem STA-Thread laden (Windows PowerShell 5.1 ist es immer)
    $script:StaD = ([System.Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA')
}

BeforeAll {
    $script:Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:NsX = 'http://schemas.microsoft.com/winfx/2006/xaml'
    $script:Code = (@(Get-Item (Join-Path $script:Root 'HUMig.ps1')) + @(Get-ChildItem (Join-Path $script:Root 'Functions') -Filter *.ps1) | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 }) -join "`n"
    function Get-UiXml([string]$File) {
        $d = New-Object System.Xml.XmlDocument
        $d.Load((Join-Path $script:Root "XAML\$File"))
        return $d
    }
    # Element liegt in einer Vorlage oder einem Stil (zaehlt nicht als eigenes Steuerelement)
    function Test-InTemplate($Node) {
        $a = $Node.ParentNode
        while ($a -and $a.LocalName) { if ($a.LocalName -match 'Template$|^Style$|^Setter') { return $true }; $a = $a.ParentNode }
        return $false
    }
    function Get-UiControls($Doc) {
        $types = 'Button', 'CheckBox', 'ComboBox', 'TextBox', 'ListBox', 'ListView', 'DataGrid', 'RadioButton', 'PasswordBox', 'Slider', 'ToggleButton'
        return @($Doc.SelectNodes('//*') | Where-Object { $types -contains $_.LocalName -and -not (Test-InTemplate $_) })
    }
    function Get-UiName($Node) { return $Node.GetAttribute('Name', $script:NsX) }
    function Get-UiTip($Node) {
        if ($Node.HasAttribute('ToolTip')) { return $Node.GetAttribute('ToolTip') }
        $c = @($Node.ChildNodes | Where-Object { $_.LocalName -eq "$($Node.LocalName).ToolTip" })
        if ($c.Count) { return $c[0].InnerText }
        return ''
    }
    $script:MainXml = Get-UiXml 'MainWindow.xaml'
    $script:SetXml = Get-UiXml 'SettingsWindow.xaml'
    # Steuerelemente, deren Tooltip der Code setzt (der Test prueft, dass der Code es wirklich tut)
    $script:TipByCode = @('txtBackupRoot')
    # gleicher Tooltip mit Grund: dieselbe Live-Anzeige steht in Backup und in Restore
    $script:TipDupOk = @('Live-Anzeige waehrend Backup/Restore - CPU und Arbeitsspeicher des PCs, auf dem HUMig laeuft')
    # Knoepfe ohne einen der vier Farbstile (Hauptvorgang, veraendernd, loeschend/Abbruch, neutral)
    $script:StyleOk = @()
    # Mitglieder der Hashtabellen selbst, keine Steuerelemente
    $script:NotControls = @('Keys', 'Values', 'Count', 'ContainsKey', 'ContainsValue', 'Contains', 'Add', 'Remove', 'Clear', 'GetEnumerator', 'Item', 'FullName', 'Name')
    $script:Pairs = @(@('btnBackup', 'btnCancel'), @('btnRestore', 'btnCancelRestore'), @('btnSbBackup', 'btnSbCancel'), @('btnAuUpdateSel', 'btnAuCancel'))
    $script:Sta = ([System.Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA')
}

Describe 'Oberflaeche: Tooltips' {
    It 'jedes Steuerelement im <Datei> hat einen Tooltip' -ForEach @(@{ Datei = 'Hauptfenster'; Key = 'Main' }, @{ Datei = 'Einstellungsfenster'; Key = 'Set' }) {
        $doc = $(if ($Key -eq 'Main') { $script:MainXml } else { $script:SetXml })
        $ohne = @(Get-UiControls $doc | Where-Object { -not (Get-UiTip $_) -and $script:TipByCode -notcontains (Get-UiName $_) } | ForEach-Object { "$($_.LocalName) '$(Get-UiName $_)' $($_.GetAttribute('Content'))" })
        $ohne | Should -BeNullOrEmpty
    }
    It 'Tooltips aus dem Code werden wirklich gesetzt' {
        foreach ($n in $script:TipByCode) { $script:Code | Should -Match ('\$ui\.' + $n + '\.ToolTip\s*=') }
    }
    It 'kein Tooltip-Text steht zweimal (ausser begruendeten)' {
        $tips = @(@($script:MainXml, $script:SetXml) | ForEach-Object { $_.SelectNodes('//*[@ToolTip]') } | ForEach-Object { $_.GetAttribute('ToolTip') } | Where-Object { $_ -and $script:TipDupOk -notcontains $_ })
        @($tips | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name }) | Should -BeNullOrEmpty
    }
    It 'die begruendeten Doppel gibt es noch (sonst Ausnahme streichen)' {
        foreach ($t in $script:TipDupOk) { @($script:MainXml.SelectNodes('//*[@ToolTip]') | Where-Object { $_.GetAttribute('ToolTip') -eq $t }).Count | Should -BeGreaterThan 1 }
    }
    It 'Tooltip-Texte nur mit Tastaturzeichen (App-Texte ohne Umlaute)' {
        $tips = @(@($script:MainXml, $script:SetXml) | ForEach-Object { Get-UiControls $_ } | ForEach-Object { Get-UiTip $_ })
        @($tips | Where-Object { $_ -match '[^\x20-\x7E\r\n]' }) | Should -BeNullOrEmpty
    }
}

Describe 'Oberflaeche: Farben der Knoepfe' {
    It 'jeder Knopf im <Datei> hat einen der vier Farbstile' -ForEach @(@{ Datei = 'Hauptfenster'; Key = 'Main' }, @{ Datei = 'Einstellungsfenster'; Key = 'Set' }) {
        $doc = $(if ($Key -eq 'Main') { $script:MainXml } else { $script:SetXml })
        $falsch = @(Get-UiControls $doc | Where-Object { $_.LocalName -eq 'Button' -and $script:StyleOk -notcontains (Get-UiName $_) -and $_.GetAttribute('Style') -notmatch '^\{(Static|Dynamic)Resource (BtnMain|BtnChange|BtnDanger|BtnDefault)\}$' } | ForEach-Object { "'$(Get-UiName $_)' $($_.GetAttribute('Style'))" })
        $falsch | Should -BeNullOrEmpty
    }
    It 'die vier Farbstile sind im Hauptfenster definiert' {
        $keys = @($script:MainXml.SelectNodes("//*[local-name()='Style']") | ForEach-Object { $_.GetAttribute('Key', $script:NsX) })
        foreach ($s in 'BtnMain', 'BtnChange', 'BtnDanger', 'BtnDefault') { @($keys | Where-Object { $_ -eq $s }).Count | Should -Be 1 }
    }
}

Describe 'Oberflaeche: Namen und Aufbau' {
    It 'jeder im Code verwendete Name ($ui.Name) steht im Hauptfenster oder wird im Code angelegt' {
        $names = @($script:MainXml.SelectNodes('//*') | ForEach-Object { Get-UiName $_ } | Where-Object { $_ })
        $refs = @([regex]::Matches($script:Code, '\$ui\.([A-Za-z_][A-Za-z0-9_]*)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $made = @([regex]::Matches($script:Code, '\$ui(?:\.([A-Za-z0-9_]+)|\[''([A-Za-z0-9_]+)''\])\s*=(?!=)') | ForEach-Object { $_.Groups[1].Value + $_.Groups[2].Value })
        @($refs | Where-Object { $names -notcontains $_ -and $made -notcontains $_ -and $script:NotControls -notcontains $_ }) | Should -BeNullOrEmpty
    }
    It 'jeder in UI-Settings.ps1 verwendete Name steht im Einstellungsfenster' {
        $names = @($script:SetXml.SelectNodes('//*') | ForEach-Object { Get-UiName $_ } | Where-Object { $_ })
        $src = Get-Content -LiteralPath (Join-Path $script:Root 'Functions\UI-Settings.ps1') -Raw -Encoding UTF8
        $refs = @([regex]::Matches($src, '\$(?:f|F|F2|script:SetDlg\.F)\.([A-Za-z_][A-Za-z0-9_]*)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        @($refs | Where-Object { $names -notcontains $_ -and $script:NotControls -notcontains $_ }) | Should -BeNullOrEmpty
    }
    It 'beide Fenster haben den Anfasser rechts unten' {
        $script:MainXml.DocumentElement.GetAttribute('ResizeMode') | Should -Be 'CanResizeWithGrip'
        $script:SetXml.DocumentElement.GetAttribute('ResizeMode') | Should -Be 'CanResizeWithGrip'
    }
    It 'Start und Abbrechen teilen sich eine Zelle, Abbrechen ist im Leerlauf ausgeblendet (<S> / <C>)' -ForEach @(
        @{ S = 'btnBackup'; C = 'btnCancel' }, @{ S = 'btnRestore'; C = 'btnCancelRestore' }, @{ S = 'btnSbBackup'; C = 'btnSbCancel' }, @{ S = 'btnAuUpdateSel'; C = 'btnAuCancel' }) {
        $s = @($script:MainXml.SelectNodes('//*') | Where-Object { (Get-UiName $_) -eq $S })[0]
        $c = @($script:MainXml.SelectNodes('//*') | Where-Object { (Get-UiName $_) -eq $C })[0]
        $s | Should -Not -BeNullOrEmpty
        $c | Should -Not -BeNullOrEmpty
        [object]::ReferenceEquals($s.ParentNode, $c.ParentNode) | Should -BeTrue
        $s.ParentNode.LocalName | Should -Be 'Grid'
        @($s.ParentNode.ChildNodes | Where-Object { $_.NodeType -eq 'Element' }).Count | Should -Be 2
        $c.GetAttribute('Visibility') | Should -Be 'Collapsed'
        $c.HasAttribute('IsEnabled') | Should -BeFalse
    }
}

Describe 'Oberflaeche: Set-JobUi schaltet Start und Abbrechen' {
    BeforeAll {
        if ($script:Sta) {
            Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
            $script:Win = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $script:MainXml))
            $script:ui = @{}
            foreach ($n in @($script:MainXml.SelectNodes('//*') | ForEach-Object { Get-UiName $_ } | Where-Object { $_ })) { $script:ui[$n] = $script:Win.FindName($n) }
            $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Root 'HUMig.ps1'), [ref]$null, [ref]$null)
            $fn = @($ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'Set-JobUi' }, $true))[0]
            . ([scriptblock]::Create($fn.Extent.Text))
            function Start-HMMonitor { }
            function Stop-HMMonitor { }
            $script:SbButtons = @(); $script:AuButtons = @(); $script:MultiDelBusy = $false; $script:UserMode = $false
        }
    }
    It 'im Lauf: Start unsichtbar mit Platz, Abbrechen sichtbar und bedienbar; im Leerlauf umgekehrt' -Skip:(-not $script:StaD) {
        $ui = $script:ui
        $tipIdle = @{}; foreach ($p in $script:Pairs) { $tipIdle[$p[1]] = "$($ui[$p[1]].ToolTip)" }
        $script:JobTitle = 'Backup'
        Set-JobUi $true
        foreach ($p in $script:Pairs) {
            "$($ui[$p[0]].Visibility)" | Should -Be 'Hidden'
            "$($ui[$p[1]].Visibility)" | Should -Be 'Visible'
            $ui[$p[1]].IsEnabled | Should -BeTrue
            # jeder Reiter nennt den laufenden Vorgang (ein Klick bricht ihn ab, wie bisher)
            "$($ui[$p[1]].Content.Text)" | Should -Be 'Abbrechen: Backup'
            "$($ui[$p[1]].ToolTip)" | Should -Match "'Backup'"
        }
        Set-JobUi $false
        foreach ($p in $script:Pairs) {
            "$($ui[$p[0]].Visibility)" | Should -Be 'Visible'
            "$($ui[$p[1]].Visibility)" | Should -Be 'Collapsed'
            $ui[$p[1]].IsEnabled | Should -BeFalse
            "$($ui[$p[1]].Content)" | Should -Be 'Abbrechen'
            "$($ui[$p[1]].ToolTip)" | Should -Be $tipIdle[$p[1]]
        }
    }
    It 'Tooltip im Lauf: eigener Reiter mit Hinweis aus dem XAML, andere Reiter nur der Vorgang (<Job>)' -Skip:(-not $script:StaD) -ForEach @(
        @{ Job = 'Backup'; Own = 'btnCancel' }, @{ Job = 'Restore'; Own = 'btnCancelRestore' }, @{ Job = 'Server-Backup'; Own = 'btnSbCancel' }, @{ Job = 'App-Updates'; Own = 'btnAuCancel' }) {
        $ui = $script:ui
        $xamlTip = @{}; foreach ($p in $script:Pairs) { $n = @($script:MainXml.SelectNodes('//*') | Where-Object { (Get-UiName $_) -eq $p[1] })[0]; $xamlTip[$p[1]] = $n.GetAttribute('ToolTip') }
        $script:JobTitle = $Job
        Set-JobUi $true
        foreach ($p in $script:Pairs) {
            $c = $p[1]
            "$($ui[$c].Content.Text)" | Should -Be "Abbrechen: $Job"
            if ($c -eq $Own) { "$($ui[$c].ToolTip)" | Should -Be ("Laufenden Vorgang '$Job' abbrechen, wirkt aus jedem Reiter.`n" + $xamlTip[$c]) }
            else { "$($ui[$c].ToolTip)" | Should -Be "Laufenden Vorgang '$Job' abbrechen (mit Rueckfrage), wirkt aus jedem Reiter." }
        }
        Set-JobUi $false
        foreach ($p in $script:Pairs) { "$($ui[$p[1]].ToolTip)" | Should -Be $xamlTip[$p[1]] }
    }
}

Describe 'Oberflaeche: Werkzeuge stehen im Abschnitt ihrer Einstufung' {
    BeforeAll {
        $script:MainSrc = Get-Content -LiteralPath (Join-Path $script:Root 'HUMig.ps1') -Raw -Encoding UTF8
        $script:PanelOf = @{ tc = 'pnlToolsComputer'; td = 'pnlToolsDiag'; tp = 'pnlToolsProfile'; tm = 'pnlToolsMulti'; tn = 'pnlToolsNoTarget' }
        function Get-XamlParentPanel([string]$Name) {
            $n = @($script:MainXml.SelectNodes('//*') | Where-Object { (Get-UiName $_) -eq $Name })[0]
            if (-not $n) { return '' }
            return (Get-UiName $n.ParentNode)
        }
    }
    It 'die Abschnittsvariablen zeigen auf die richtigen Leisten' {
        foreach ($k in $script:PanelOf.Keys) { $script:MainSrc | Should -Match ('(?m)^\$' + $k + ' = \$ui\.' + $script:PanelOf[$k] + '\s*$') }
    }
    It 'Add-ToolButton: ohne Schalter im PC- oder Diagnose-Abschnitt, -User im Benutzer-Abschnitt, -NoTarget bei mehreren PCs oder ohne Ziel-PC' {
        $lines = @([regex]::Matches($script:MainSrc, '(?m)^Add-ToolButton \$(t\w+) ''([^'']*)''.*$') | ForEach-Object { $_ })
        $lines.Count | Should -BeGreaterThan 30
        $falsch = @()
        foreach ($m in $lines) {
            $v = $m.Groups[1].Value; $l = $m.Value
            $soll = $(if ($l -match ' -NoTarget\b') { @('tm', 'tn') } elseif ($l -match ' -User\b') { @('tp') } else { @('tc', 'td') })
            if ($soll -notcontains $v) { $falsch += "$($m.Groups[2].Value) steht in `$$v" }
        }
        $falsch | Should -BeNullOrEmpty
    }
    It 'Knoepfe aus dem XAML stehen im Abschnitt, den ihr Klick verlangt' {
        foreach ($n in 'btnToolSoftDeploy', 'btnToolDrvDeploy', 'btnToolSoftList') {
            Get-XamlParentPanel $n | Should -Be 'pnlToolsSoft'
            $script:MainSrc | Should -Match ('\$ui\.' + $n + '\.Add_Click\(\{ if \(Use-HMPcTarget ')
        }
        foreach ($n in 'btnToolUserAppData', 'btnToolUserStartup', 'btnToolProfileFolder') {
            Get-XamlParentPanel $n | Should -Be 'pnlToolsProfile'
            $script:MainSrc | Should -Match ('\$ui\.' + $n + '\.Add_Click\(\{ \$x = Get-SelectedProfilePath ')
        }
        foreach ($n in 'btnToolCredWiz', 'btnToolCredList') {
            Get-XamlParentPanel $n | Should -Be 'pnlToolsNoTarget'
            $script:MainSrc | Should -Not -Match ('\$ui\.' + $n + '\.Add_Click\(\{[^\r\n]*(Use-HMPcTarget|Get-SelectedProfilePath|Confirm-HMTarget)')
        }
    }
    It 'Ueberschriften ziehen nach: Ziel-Anzeige und Benutzerwahl rufen Update-HMToolHeads auf' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Root 'HUMig.ps1'), [ref]$null, [ref]$null)
        foreach ($n in 'Update-HMTargetLabel', 'Update-SidLabel', 'Set-HMUserModeUi') {
            $fn = @($ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $n }, $true))[0]
            $fn | Should -Not -BeNullOrEmpty
            $fn.Extent.Text | Should -Match 'Update-HMToolHeads'
        }
    }
    It 'Ueberschriften nennen PC und Benutzer' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Root 'HUMig.ps1'), [ref]$null, [ref]$null)
        $fn = @($ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'Update-HMToolHeads' }, $true))[0]
        $fn | Should -Not -BeNullOrEmpty
        . ([scriptblock]::Create($fn.Extent.Text))
        function Get-HMTargetCaption { 'PC-TEST-01' }
        function Get-SelectedProfile { [pscustomobject]@{ Account = 'DOM\max.muster' } }
        $ui = @{}
        foreach ($n in 'lblToolsPc', 'lblToolsDiag', 'lblToolsSoft', 'lblToolsUser', 'lblScopeBackup') { $ui[$n] = [pscustomobject]@{ Text = '' } }
        $ui['cmbUser'] = [pscustomobject]@{ Text = '' }
        $script:UserMode = $false
        Update-HMToolHeads
        $ui.lblToolsPc.Text | Should -Be 'GEWAEHLTER PC: PC-TEST-01'
        $ui.lblToolsDiag.Text | Should -Match 'PC-TEST-01$'
        $ui.lblToolsSoft.Text | Should -Match 'PC-TEST-01$'
        $ui.lblToolsUser.Text | Should -Be 'GEWAEHLTER BENUTZER: DOM\max.muster auf PC-TEST-01'
        $ui.lblScopeBackup.Text | Should -Be 'Sichert DOM\max.muster von PC-TEST-01'
    }
}

Describe 'Oberflaeche: ausgeblendet statt gesperrt' {
    It 'Grosse Dateien: ohne Groessenermittlung ausgeblendet mit Hinweis, danach sichtbar' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Root 'HUMig.ps1'), [ref]$null, [ref]$null)
        $fn = @($ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'Show-ModuleSizes' }, $true))[0]
        . ([scriptblock]::Create($fn.Extent.Text))
        function Update-SizeTotal { }
        $script:ModuleSizeLbl = @{}
        $ui = @{ btnBigFiles = [pscustomobject]@{ Visibility = 'Visible' }; lblBigFilesHint = [pscustomobject]@{ Visibility = 'Visible' } }
        function Test-SizeCacheValid { $false }
        Show-ModuleSizes
        $ui.btnBigFiles.Visibility | Should -Be 'Collapsed'
        $ui.lblBigFilesHint.Visibility | Should -Be 'Visible'
        function Test-SizeCacheValid { $true }
        $script:SizeCache = @{ Modules = @{}; Top = @('x') }
        Show-ModuleSizes
        $ui.btnBigFiles.Visibility | Should -Be 'Visible'
        $ui.lblBigFilesHint.Visibility | Should -Be 'Collapsed'
    }
    It 'Restore: Module, die das Backup nicht enthaelt, und leere Gruppen sind ausgeblendet (echtes Build-ModulePanel)' -Skip:(-not $script:StaD) {
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Root 'HUMig.ps1'), [ref]$null, [ref]$null)
        function Get-ConsoleBrush { param($c) New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($c)) }
        foreach ($n in 'Build-ModulePanel', 'Set-HMRestoreModulesForBackup', 'Get-CheckedModules', 'New-Brush') { . ([scriptblock]::Create(@($ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $n }, $true))[0].Extent.Text)) }
        $script:UserMode = $false
        $script:Groups = @('Profil', 'Browser')
        $script:Modules = @([pscustomobject]@{ Id = 'Profile'; Name = 'Benutzerprofil'; Group = 'Profil'; Show = $true; Default = $true }, [pscustomobject]@{ Id = 'Edge'; Name = 'Edge'; Group = 'Browser'; Show = $true; Default = $true }, [pscustomobject]@{ Id = 'Chrome'; Name = 'Chrome'; Group = 'Browser'; Show = $true; Default = $true })
        $script:RestoreChecks = @{}
        $ui = @{ pnlRestoreModules = New-Object System.Windows.Controls.StackPanel }
        Build-ModulePanel $ui.pnlRestoreModules $script:RestoreChecks -Restore
        $n = Set-HMRestoreModulesForBackup ([pscustomobject]@{ Modules = @('Profile') })
        $n | Should -Be 2
        "$($script:RestoreChecks['Edge'].Parent.Visibility)" | Should -Be 'Collapsed'
        "$($script:RestoreChecks['Profile'].Parent.Visibility)" | Should -Be 'Visible'
        "$($ui.pnlRestoreModules.Children[1].Visibility)" | Should -Be 'Collapsed'
        "$($ui.pnlRestoreModules.Children[0].Visibility)" | Should -Be 'Visible'
        @(Get-CheckedModules $script:RestoreChecks | ForEach-Object { $_.Id }) | Should -Be @('Profile')
        [void](Set-HMRestoreModulesForBackup ([pscustomobject]@{ Modules = @('Profile', 'Chrome') }))
        "$($ui.pnlRestoreModules.Children[1].Visibility)" | Should -Be 'Visible'
        "$($script:RestoreChecks['Chrome'].Parent.Visibility)" | Should -Be 'Visible'
        "$($script:RestoreChecks['Edge'].Parent.Visibility)" | Should -Be 'Collapsed'
    }
    It 'Grosse Dateien ist im XAML ausgeblendet und nie gesperrt' {
        $b = @($script:MainXml.SelectNodes('//*') | Where-Object { (Get-UiName $_) -eq 'btnBigFiles' })[0]
        $b.GetAttribute('Visibility') | Should -Be 'Collapsed'
        $b.HasAttribute('IsEnabled') | Should -BeFalse
    }
}

Describe 'Oberflaeche: Rueckfragen mit eigenen Knopftexten' {
    BeforeAll {
        if ($script:Sta) {
            Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
            $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Root 'Functions\UI-Common.ps1'), [ref]$null, [ref]$null)
            $fn = @($ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'Show-HMDialogBox' }, $true))[0]
            . ([scriptblock]::Create($fn.Extent.Text))
            function Set-HMWindowScale { param($w) }
            function Out-Console { param($a, $b) }
            # Besitzerfenster ausserhalb des Bildschirms (die Rueckfrage braucht ein geladenes Fenster)
            $script:OwnerWin = New-Object System.Windows.Window
            $script:OwnerWin.Left = -20000; $script:OwnerWin.Top = 0; $script:OwnerWin.Width = 200; $script:OwnerWin.Height = 100; $script:OwnerWin.ShowInTaskbar = $false; $script:OwnerWin.ShowActivated = $false
            $script:OwnerWin.Show()
            # jede neue Rueckfrage: Knopftexte merken und je nach $script:Press Enter, Esc oder Schliessen ausloesen
            $script:Seen = New-Object System.Collections.ArrayList
            $script:Press = 'Enter'
            # nur waehrend dieser Tests aktiv (der Handler bleibt im Prozess registriert); Zeitgrenze schliesst haengende Rueckfragen
            $script:DlgActive = $true; $script:DlgTimeout = $false
            [System.Windows.EventManager]::RegisterClassHandler([System.Windows.Window], [System.Windows.FrameworkElement]::LoadedEvent, [System.Windows.RoutedEventHandler] {
                param($sd, $e)
                if (-not $script:DlgActive -or [object]::ReferenceEquals($sd, $script:OwnerWin)) { return }
                $wd = New-Object System.Windows.Threading.DispatcherTimer; $wd.Interval = [TimeSpan]::FromSeconds(10)
                $wd.Add_Tick({ param($tm) $tm.Stop(); if ($sd.IsVisible) { $script:DlgTimeout = $true; $sd.Close() } }.GetNewClosure()); $wd.Start()
                $btns = New-Object System.Collections.ArrayList
                $walk = { param($v) if ($v -is [System.Windows.Controls.Button]) { [void]$btns.Add($v) }; for ($i = 0; $i -lt [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($v); $i++) { & $walk ([System.Windows.Media.VisualTreeHelper]::GetChild($v, $i)) } }
                & $walk $sd
                [void]$script:Seen.Clear(); foreach ($b in $btns) { [void]$script:Seen.Add("$($b.Content)") }
                $target = $(switch ($script:Press) { 'Enter' { @($btns | Where-Object { $_.IsDefault })[0] } 'Esc' { @($btns | Where-Object { $_.IsCancel })[0] } default { $null } })
                $sd.Dispatcher.BeginInvoke([action] {
                    if ($target) { $target.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) } else { $sd.Close() }
                }.GetNewClosure(), [System.Windows.Threading.DispatcherPriority]::Background) | Out-Null
            })
        }
    }
    AfterAll { $script:DlgActive = $false; if ($script:OwnerWin) { $script:OwnerWin.Close() } }
    It 'gleiche Rueckgabe mit und ohne eigene Texte (<Mode>, <Icon>, Standard <Def>, Taste <Key>)' -Skip:(-not $script:StaD) -ForEach @(
        @{ Mode = 'YesNo'; Icon = 'Warning'; Def = ''; Key = 'Enter' }, @{ Mode = 'YesNo'; Icon = 'Warning'; Def = ''; Key = 'Esc' }, @{ Mode = 'YesNo'; Icon = 'Warning'; Def = ''; Key = 'Close' },
        @{ Mode = 'YesNo'; Icon = 'Warning'; Def = 'No'; Key = 'Enter' }, @{ Mode = 'YesNo'; Icon = 'Question'; Def = 'Yes'; Key = 'Enter' },
        @{ Mode = 'YesNoCancel'; Icon = 'Question'; Def = 'No'; Key = 'Enter' }, @{ Mode = 'YesNoCancel'; Icon = 'Question'; Def = 'No'; Key = 'Esc' }, @{ Mode = 'YesNoCancel'; Icon = 'Question'; Def = 'No'; Key = 'Close' },
        @{ Mode = 'YesNoCancel'; Icon = 'Warning'; Def = ''; Key = 'Enter' }, @{ Mode = 'OKCancel'; Icon = 'Warning'; Def = ''; Key = 'Esc' }) {
        $script:Press = $Key
        $a = Show-HMDialogBox -Owner $script:OwnerWin -Text 'Test' -Title 'Test' -Mode $Mode -Icon $Icon -Default $Def
        $plain = @($script:Seen)
        $lab = @{ Yes = 'Machen'; No = 'Lassen'; Cancel = 'Zurueck'; OK = 'Weiter' }
        $b = Show-HMDialogBox -Owner $script:OwnerWin -Text 'Test' -Title 'Test' -Mode $Mode -Icon $Icon -Default $Def -Labels $lab
        $b | Should -Be $a
        $script:DlgTimeout | Should -BeFalse
        $plain.Count | Should -BeGreaterThan 1
        @($script:Seen).Count | Should -Be $plain.Count
        @($script:Seen) | Should -Not -Contain 'Ja'
        @($script:Seen) | Should -Not -Contain 'Nein'
    }
    It 'ohne Parameter bleiben die festen Texte' -Skip:(-not $script:StaD) {
        $script:Press = 'Esc'
        [void](Show-HMDialogBox -Owner $script:OwnerWin -Text 'Test' -Mode 'YesNoCancel' -Icon 'Question')
        @($script:Seen) | Should -Be @('Ja', 'Nein', 'Abbrechen')
    }
}

Describe 'Oberflaeche: drei Begriffe einheitlich' {
    BeforeAll {
        $script:AllXamlText = (@($script:MainXml, $script:SetXml) | ForEach-Object { $_.OuterXml }) -join "`n"
        function Get-Content2([string]$n) { "$((@($script:MainXml.SelectNodes('//*') | Where-Object { (Get-UiName $_) -eq $n })[0]).GetAttribute('Content'))" }
    }
    It 'Listen neu lesen heisst "Neu laden"' {
        foreach ($n in 'btnStatusRefresh', 'btnRefreshBackups', 'btnSbDrives') { Get-Content2 $n | Should -Be 'Neu laden' }
        $script:AllXamlText | Should -Not -Match "'Aktualisieren'|beim Aktualisieren"
    }
    It 'das Weiterfuehren heisst "Fortlaufendes Backup"' {
        Get-Content2 'chkIncremental' | Should -Match '^Fortlaufendes Backup'
        $script:AllXamlText | Should -Not -Match 'Vorhandenes Backup aktualisieren|weitergefuehrt'
        (Get-Content -LiteralPath (Join-Path $script:Root 'Functions\UI-BackupSchedule.ps1') -Raw -Encoding UTF8) | Should -Not -Match 'vorhandenes Backup aktualisieren'
    }
    It 'der Bericht eines Laufs heisst "Bericht"' {
        Get-Content2 'btnReport' | Should -Be 'Bericht'
        $script:AllXamlText | Should -Not -Match 'Restore-Protokoll|Backup-/Restore-Protokoll|im Protokoll\)'
    }
}

Describe 'Quelltext: keine verschmolzenen Zeilen' {
    BeforeAll {
        $script:SrcFiles = @(Get-Item (Join-Path $script:Root 'HUMig.ps1')) + @(Get-ChildItem (Join-Path $script:Root 'Functions') -Filter *.ps1)
        $script:Defs = @{}; $script:Calls = New-Object System.Collections.ArrayList
        foreach ($f in $script:SrcFiles) {
            $a = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
            foreach ($d in $a.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) { $script:Defs[$d.Name] = 1 }
            foreach ($c in $a.FindAll({ param($x) $x -is [System.Management.Automation.Language.CommandAst] }, $true)) { $n = $c.GetCommandName(); if ($n) { [void]$script:Calls.Add([pscustomobject]@{ Name = $n; Where = "$($f.Name):$($c.Extent.StartLineNumber)" }) } }
        }
        # Funktionen, die als Text in Skriptbloecken stehen (z.B. fuer entfernte PCs), zaehlen ebenfalls als definiert
        $txt = ($script:SrcFiles | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 }) -join "`n"
        foreach ($m in [regex]::Matches($txt, 'function\s+(?:global:|script:)?([\w-]+)')) { $script:Defs[$m.Groups[1].Value] = 1 }
    }
    It 'kein Befehlsname enthaelt $ oder = (z.B. "Update-HMToolHeads$sysTools")' {
        @($script:Calls | Where-Object { $_.Name -match '[\$=]' } | ForEach-Object { "$($_.Where) $($_.Name)" }) | Should -BeNullOrEmpty
    }
    It 'jeder Aufruf einer Projektfunktion (Verb-HM...) ist im Projekt definiert' {
        @($script:Calls | Where-Object { $_.Name -match '^[A-Z][a-z]+-HM' -and -not $script:Defs.ContainsKey($_.Name) } | ForEach-Object { "$($_.Where) $($_.Name)" }) | Should -BeNullOrEmpty
    }
    It 'Meldungen der Ordnerrechte-Pruefung werden ohne @( ) gelesen und kommen an' {
        $src = Get-Content -LiteralPath (Join-Path $script:Root 'HUMig.ps1') -Raw -Encoding UTF8
        $src | Should -Not -Match '@\(\$[\w:]+\.Msgs\)'
        # eine mit New-Object erzeugte List[object] wirft in @( ) "Die Argumenttypen stimmen nicht ueberein", auch leer
        $src | Should -Not -MatchExactly '\bMsgs\s*=\s*\(?New-Object'
        $r = [pscustomobject]@{ Msgs = [System.Collections.Generic.List[object]]::new() }
        $n = 0; foreach ($x in $r.Msgs) { $n++ }; $n | Should -Be 0
        $r.Msgs.Add([pscustomobject]@{ Text = 'a'; Level = 'Warning' }); $r.Msgs.Add([pscustomobject]@{ Text = 'b'; Level = 'Info' })
        $got = @(); foreach ($x in $r.Msgs) { $got += "$($x.Level)|$($x.Text)" }
        $got -join ',' | Should -Be 'Warning|a,Info|b'
        $leer = [pscustomobject]@{ Msgs = $null }; $n = 0; foreach ($x in $leer.Msgs) { $n++ }; $n | Should -Be 0
    }
    It 'keine Funktion beginnt direkt hinter einer schliessenden Klammer' {
        $hits = @()
        foreach ($f in $script:SrcFiles) { $i = 0; foreach ($l in (Get-Content -LiteralPath $f.FullName -Encoding UTF8)) { $i++; if ($l -match '[\}\)]function\s') { $hits += "$($f.Name):$i" } } }
        $hits | Should -BeNullOrEmpty
    }
}

Describe 'Oberflaeche: Listen in Bildlaufbereichen wachsen nicht mit' {
    It 'jede Liste oder Tabelle in einem Bildlaufbereich hat eine feste Hoehe oder liegt in einem Raster mit der Hoehe des sichtbaren Bereichs' {
        $falsch = @()
        foreach ($doc in @($script:MainXml, $script:SetXml)) {
            foreach ($sv in @($doc.SelectNodes("//*[local-name()='ScrollViewer']"))) {
                foreach ($l in @($sv.SelectNodes(".//*[local-name()='DataGrid' or local-name()='ListBox' or local-name()='ListView']"))) {
                    if ($l.HasAttribute('Height') -or $l.HasAttribute('MaxHeight')) { continue }
                    $a = $l.ParentNode; $ok = $false
                    while ($a -and -not [object]::ReferenceEquals($a, $sv)) { if ($a.GetAttribute('Height') -like '*ViewportHeight*') { $ok = $true; break }; $a = $a.ParentNode }
                    if (-not $ok) { $falsch += (Get-UiName $l) }
                }
            }
        }
        $falsch | Should -BeNullOrEmpty
    }
    It 'Server-Backup: die Haken stehen mit 300 Verlaufszeilen dort, wo sie ohne Verlauf stehen, der Startknopf bleibt sichtbar' -Skip:(-not $script:StaD) {
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
        $w = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $script:MainXml))
        $w.Left = -20000; $w.Top = 0; $w.Width = 1200; $w.Height = 800; $w.ShowInTaskbar = $false; $w.ShowActivated = $false
        try {
            $w.Show(); $w.FindName('tabMain').SelectedItem = $w.FindName('tabServerBackup')
            $dg = $w.FindName('dgSbHistory')
            $mess = { param($n) $dg.ItemsSource = @(1..([Math]::Max(1, $n)) | Select-Object -First $n | ForEach-Object { [pscustomobject]@{ Datum = "$_"; Status = 'OK' } }); $w.UpdateLayout(); [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([action] {}, 'Background'); $w.UpdateLayout()
                [pscustomobject]@{ Haken = $w.FindName('chkSbHostConfig').TranslatePoint([System.Windows.Point]::new(0, 0), $w.Content).Y; Start = $w.FindName('btnSbBackup').TranslatePoint([System.Windows.Point]::new(0, 0), $w.Content).Y; Tabelle = $dg.ActualHeight } }
            $leer = & $mess 0; $voll = & $mess 300
            $voll.Haken | Should -Be $leer.Haken
            $voll.Tabelle | Should -Be $leer.Tabelle
            $voll.Start | Should -BeLessThan $w.Content.ActualHeight
        } finally { $w.Close() }
    }
}
