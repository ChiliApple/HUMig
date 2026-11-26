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
            "$($ui[$p[1]].Content.Text)" | Should -Be 'Backup abbrechen'
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
    It 'Grosse Dateien ist im XAML ausgeblendet und nie gesperrt' {
        $b = @($script:MainXml.SelectNodes('//*') | Where-Object { (Get-UiName $_) -eq 'btnBigFiles' })[0]
        $b.GetAttribute('Visibility') | Should -Be 'Collapsed'
        $b.HasAttribute('IsEnabled') | Should -BeFalse
    }
}