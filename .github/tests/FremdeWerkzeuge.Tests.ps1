#Requires -Version 5.1
<#
.SYNOPSIS
    Tests fuer feste Versionen fremder Werkzeuge: Config\tools.json, PowerShell 7 am Ziel-PC, WinGet-Modul, USMT-Version, Waechter.
.DESCRIPTION
    Ohne Netz und unabhaengig vom PC: Download, Pruefsumme, Entpacken, Umbenennen und Prozessliste werden durch Ersatzfunktionen
    ersetzt, Ordner liegen nur im TestDrive. Am PC wird nichts installiert, geladen oder geaendert.
#>

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $script:TargetFile = Join-Path $script:Root 'Functions\AppUpdates-Target.ps1'
    # Funktionen aus dem Ziel-Skript (laeuft sonst als Text am Ziel-PC) einzeln laden, ohne den Skriptkoerper auszufuehren
    function Import-TargetFunction([string[]]$Names, [string]$File = $script:TargetFile) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($File, [ref]$null, [ref]$null)
        foreach ($n in $Names) {
            $fn = @($ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $n }, $true))[0]
            if (-not $fn) { throw "Funktion $n nicht gefunden" }
            . ([scriptblock]::Create($fn.Extent.Text.Replace("function $n", "function global:$n")))
        }
    }
    # gueltige Angaben wie in Config\tools.json (Pruefsummen nur als Muster)
    function New-ToolsData {
        $d = [ordered]@{
            dateien = @(
                [ordered]@{ id = 'powershell7'; version = '7.6.10'; pakete = [ordered]@{
                        x64   = [ordered]@{ datei = 'PowerShell-7.6.10-win-x64.zip'; url = 'https://github.com/PowerShell/PowerShell/releases/download/v7.6.10/PowerShell-7.6.10-win-x64.zip'; sha256 = ('a' * 64) }
                        arm64 = [ordered]@{ datei = 'PowerShell-7.6.10-win-arm64.zip'; url = 'https://github.com/PowerShell/PowerShell/releases/download/v7.6.10/PowerShell-7.6.10-win-arm64.zip'; sha256 = ('b' * 64) } } }
                [ordered]@{ id = 'winget-modul'; version = '1.29.380'; name = 'Microsoft.WinGet.Client'; herausgeber = ', O=Microsoft Corporation, L=Redmond, S=Washington, C=US' }
            )
        }
        return ($d | ConvertTo-Json -Depth 8 | ConvertFrom-Json)
    }
}

Describe 'Feste Versionen: Config\tools.json lesen und pruefen' {
    BeforeAll { . (Join-Path $script:Root 'Functions\AppUpdates-Engine.ps1') }
    It 'die Datei im Repo ist gueltig: PowerShell 7 fuer x64 und arm64, WinGet-Modul mit Herausgeber' {
        $t = Get-HMAuTools
        $t.Ok | Should -BeTrue
        @($t.Errors).Count | Should -Be 0
        $t.Pwsh.Version | Should -Match '^\d+\.\d+\.\d+$'
        foreach ($a in @('x64', 'arm64')) {
            $p = $t.Pwsh.Pakete[$a]
            $p.Url | Should -Match ('^https://.+/' + [regex]::Escape($p.Datei) + '$')
            $p.Url | Should -Match ([regex]::Escape($t.Pwsh.Version))
            $p.Sha256 | Should -Match '^[0-9A-F]{64}$'
        }
        $t.WinGet.Name | Should -Be 'Microsoft.WinGet.Client'
        $t.WinGet.Version | Should -Match '^\d+\.\d+\.\d+$'
        $t.WinGet.Herausgeber | Should -Match '^, O=Microsoft Corporation'
    }
    It 'gueltige Angaben ergeben nur Hashtables und Texte (uebersteht den Fernzugriff)' {
        $t = ConvertTo-HMAuTools (New-ToolsData)
        $t.Ok | Should -BeTrue
        $t | Should -BeOfType [hashtable]
        $t.Pwsh | Should -BeOfType [hashtable]
        $t.Pwsh.Pakete.x64 | Should -BeOfType [hashtable]
        $t.Pwsh.Pakete.x64.Sha256 | Should -Be ('A' * 64)
        $t.WinGet | Should -BeOfType [hashtable]
    }
    $bad = @(
        @{ Fall = 'Adresse mit latest'; Set = { param($d) $d.dateien[0].pakete.x64.url = 'https://github.com/PowerShell/PowerShell/releases/latest/download/PowerShell-7.6.10-win-x64.zip' } }
        @{ Fall = 'Adresse ohne die Version'; Set = { param($d) $d.dateien[0].pakete.x64.url = 'https://github.com/PowerShell/PowerShell/releases/download/vX/PowerShell-win-x64.zip'; $d.dateien[0].pakete.x64.datei = 'PowerShell-win-x64.zip' } }
        @{ Fall = 'Adresse nicht https'; Set = { param($d) $d.dateien[0].pakete.x64.url = 'http://github.com/PowerShell/PowerShell/releases/download/v7.6.10/PowerShell-7.6.10-win-x64.zip' } }
        @{ Fall = 'SHA256 zu kurz'; Set = { param($d) $d.dateien[0].pakete.arm64.sha256 = ('b' * 63) } }
        @{ Fall = 'SHA256 kein Hex'; Set = { param($d) $d.dateien[0].pakete.arm64.sha256 = ('g' * 64) } }
        @{ Fall = 'Version ohne dritte Stelle'; Set = { param($d) $d.dateien[0].version = '7.6' } }
        @{ Fall = 'Version latest'; Set = { param($d) $d.dateien[0].version = 'latest' } }
        @{ Fall = 'Dateiname passt nicht'; Set = { param($d) $d.dateien[0].pakete.x64.datei = 'anders.zip' } }
        @{ Fall = 'Paket arm64 fehlt'; Set = { param($d) $d.dateien[0].pakete.PSObject.Properties.Remove('arm64') } }
    )
    It 'PowerShell 7 ungueltig (<Fall>): kein Eintrag fuer PowerShell 7, WinGet-Modul bleibt nutzbar' -TestCases $bad {
        param($Fall, $Set)
        $d = New-ToolsData
        & $Set $d
        $t = ConvertTo-HMAuTools $d
        $t.Ok | Should -BeFalse
        $t.Pwsh | Should -BeNullOrEmpty
        @($t.Errors | Where-Object { $_ -like 'powershell7:*' }).Count | Should -BeGreaterThan 0
        $t.WinGet.Version | Should -Be '1.29.380'
    }
    It 'WinGet-Modul ohne feste Version: kein Eintrag dafuer, PowerShell 7 bleibt nutzbar' {
        $d = New-ToolsData; $d.dateien[1].version = ''
        $t = ConvertTo-HMAuTools $d
        $t.WinGet | Should -BeNullOrEmpty
        $t.Pwsh.Version | Should -Be '7.6.10'
    }
    It 'Datei fehlt oder ist kein JSON: nicht nutzbar, mit Fehlertext' {
        $f = Join-Path $TestDrive 'kaputt.json'; [IO.File]::WriteAllText($f, '{ kein json')
        $t = Get-HMAuTools $f
        $t.Ok | Should -BeFalse; $t.Pwsh | Should -BeNullOrEmpty; $t.WinGet | Should -BeNullOrEmpty
        @($t.Errors)[0] | Should -Match 'tools.json nicht lesbar'
        (Get-HMAuTools (Join-Path $TestDrive 'fehlt.json')).Ok | Should -BeFalse
    }
}

Describe 'Feste Versionen: die Engine gibt sie mit jedem Auftrag an das Ziel-Skript' {
    BeforeAll {
        . (Join-Path $script:Root 'Functions\AppUpdates-Engine.ps1')
        # Ersatz-Ziel-Skript: meldet, was es als Payload.Tools bekommen hat (lokal, ohne Fernzugriff)
        $fake = Join-Path $TestDrive 'Ziel-Ersatz.ps1'
        [IO.File]::WriteAllText($fake, @'
param([string]$Op, $Payload, [string]$WorkerText, [string]$AutoText)
$v = @{ Op = $Op; HasTools = [bool]$Payload.Tools; Pwsh = "$($Payload.Tools.Pwsh.Version)"; WinGet = "$($Payload.Tools.WinGet.Version)"; Own = "$($Payload.Own)"; Errors = @() }
[pscustomobject]@{ HMAu = 'R'; PC = 'X'; J = (ConvertTo-Json -InputObject $v -Compress) }
'@)
        $script:OldTarget = $script:HMAuTargetFile
        $script:HMAuTargetFile = $fake
    }
    AfterAll { $script:HMAuTargetFile = $script:OldTarget }
    It 'Auftrag ohne Tools: das Ziel bekommt die festen Versionen aus Config\tools.json, der Auftrag des Aufrufers bleibt unveraendert' {
        $p = @{ Own = 'eigener Wert' }
        $r = Invoke-HMAuTarget @('localhost') 'ScheduleSet' $p
        $v = $r["$env:COMPUTERNAME".ToUpper()]
        $v.Op | Should -Be 'ScheduleSet'
        $v.HasTools | Should -BeTrue
        $v.Pwsh | Should -Be (Get-HMAuTools).Pwsh.Version
        $v.WinGet | Should -Be (Get-HMAuTools).WinGet.Version
        $v.Own | Should -Be 'eigener Wert'
        $p.ContainsKey('Tools') | Should -BeFalse
    }
    It 'Auftrag ohne Payload ($null) laeuft weiter und bekommt die festen Versionen' {
        $r = Invoke-HMAuTarget @('localhost') 'ScheduleGet' $null
        $r["$env:COMPUTERNAME".ToUpper()].HasTools | Should -BeTrue
    }
    It 'schon mitgegebene Tools werden nicht ueberschrieben' {
        $r = Invoke-HMAuTarget @('localhost') 'Search' @{ ByPc = @{}; Tools = @{ Pwsh = @{ Version = '1.2.3' } } }
        $r["$env:COMPUTERNAME".ToUpper()].Pwsh | Should -Be '1.2.3'
    }
}

Describe 'Ziel-Skript: feste Fassung waehlen und Versionen vergleichen' {
    BeforeAll {
        . (Join-Path $script:Root 'Functions\AppUpdates-Engine.ps1')
        Import-TargetFunction @('Select-TPwshPackage', 'Compare-TPwshVersion')
        $script:T = ConvertTo-HMAuTools (New-ToolsData)
    }
    AfterAll { Remove-Item Function:\global:Select-TPwshPackage, Function:\global:Compare-TPwshVersion -ErrorAction SilentlyContinue }
    It 'Architektur: ARM64 nimmt arm64, AMD64 und alles andere x64 (wie bisher)' {
        (Select-TPwshPackage $script:T 'ARM64').Datei | Should -Be 'PowerShell-7.6.10-win-arm64.zip'
        (Select-TPwshPackage $script:T 'AMD64').Datei | Should -Be 'PowerShell-7.6.10-win-x64.zip'
        (Select-TPwshPackage $script:T 'x86').Datei | Should -Be 'PowerShell-7.6.10-win-x64.zip'
        $p = Select-TPwshPackage $script:T 'AMD64'
        $p.Version | Should -Be '7.6.10'; $p.Sha256 | Should -Be ('A' * 64)
    }
    It 'keine oder ungueltige Angaben: keine Fassung (dann wird nichts geladen)' {
        Select-TPwshPackage $null 'AMD64' | Should -BeNullOrEmpty
        Select-TPwshPackage @{ Pwsh = $null } 'AMD64' | Should -BeNullOrEmpty
        Select-TPwshPackage @{ Pwsh = @{ Version = '7.6.10'; Pakete = @{ x64 = @{ Datei = 'a.zip'; Url = 'https://example.invalid/latest/7.6.10/a.zip'; Sha256 = ('a' * 64) } } } } 'AMD64' | Should -BeNullOrEmpty
        Select-TPwshPackage @{ Pwsh = @{ Version = '7.6.10'; Pakete = @{ x64 = @{ Datei = 'a.zip'; Url = 'https://example.invalid/7.6.10/a.zip'; Sha256 = 'zu kurz' } } } } 'AMD64' | Should -BeNullOrEmpty
        Select-TPwshPackage @{ Pwsh = @{ Version = '7.6'; Pakete = @{ x64 = @{ Datei = 'a.zip'; Url = 'https://example.invalid/7.6/a.zip'; Sha256 = ('a' * 64) } } } } 'AMD64' | Should -BeNullOrEmpty
    }
    $cmp = @(
        @{ Have = '7.4.6 SHA: 0b2b5f0e'; Want = '7.6.10'; Erg = -1 }
        @{ Have = '7.6.9'; Want = '7.6.10'; Erg = -1 }
        @{ Have = '7.6.10'; Want = '7.6.10'; Erg = 0 }
        @{ Have = '7.6.10 SHA: 1234abcd'; Want = '7.6.10'; Erg = 0 }
        @{ Have = 'v7.6.10'; Want = '7.6.10'; Erg = 0 }
        @{ Have = '7.6.10-preview.2'; Want = '7.6.10'; Erg = -1 }
        @{ Have = '7.6.11'; Want = '7.6.10'; Erg = 1 }
        @{ Have = '7.10.0'; Want = '7.6.10'; Erg = 1 }
        @{ Have = '8.0.0'; Want = '7.6.10'; Erg = 1 }
    )
    It 'Vergleich <Have> mit <Want> ergibt <Erg>' -TestCases $cmp {
        param($Have, $Want, $Erg)
        Compare-TPwshVersion $Have $Want | Should -Be $Erg
    }
    It 'nicht lesbare Version ergibt $null' {
        Compare-TPwshVersion '' '7.6.10' | Should -BeNullOrEmpty
        Compare-TPwshVersion 'unbekannt' '7.6.10' | Should -BeNullOrEmpty
        Compare-TPwshVersion '7.6.10' 'latest' | Should -BeNullOrEmpty
    }
}

Describe 'Kein fremdes Werkzeug ohne feste Version in Functions\*.ps1' {
    BeforeAll {
        # Regeln (auch in Texten, die als Skript an andere Prozesse gehen; Kommentare zaehlen nicht)
        $script:Rules = [ordered]@{
            'releases/latest'                   = 'releases/latest'
            'Find-Module'                       = '\bFind-Module\b'
            'Update-Module'                     = '\bUpdate-Module\b'
            'Save-Module/Install-Script'        = '\b(Save-Module|Install-Script)\b'
            'Install-Module ohne RequiredVersion' = '\bInstall-Module\b(?![^\r\n;|}]*-RequiredVersion)'
            'Repair-WinGetPackageManager -Latest' = '\bRepair-WinGetPackageManager\b[^\r\n;|}]*?-Latest\b'
            'Install-PackageProvider'           = '\bInstall-PackageProvider\b'
        }
        # Ausnahmen mit Begruendung: Datei, Regel, genaue Anzahl (eine neue Stelle faellt damit auf)
        $script:Allowed = @(
            @{ File = 'AppUpdates-Engine.ps1'; Rule = 'Install-PackageProvider'; Count = 1; Why = 'NuGet-Anbieter: Voraussetzung von Install-Module, Mindestversion 2.8.5.201, kommt von Microsoft (begruendete Ausnahme)' }
            @{ File = 'AppUpdates-Target.ps1'; Rule = 'Install-PackageProvider'; Count = 1; Why = 'NuGet-Anbieter am Ziel-PC, wie oben' }
            @{ File = 'AppUpdates-Engine.ps1'; Rule = 'Repair-WinGetPackageManager -Latest'; Count = 4; Why = 'App Installer (WinGet) ist ein Windows-Bestandteil, nur Microsoft liefert passende Fassungen; repariert wird nur, wenn WinGet nicht laeuft' }
            @{ File = 'AppUpdates-Target.ps1'; Rule = 'Repair-WinGetPackageManager -Latest'; Count = 3; Why = 'App Installer am Ziel-PC, wie oben (ein Aufruf, zwei Hinweistexte fuer den Administrator)' }
            # bis Schritt 2 (PowerShell 7 fest) bzw. 3 (WinGet-Modul fest)
            @{ File = 'AppUpdates-Target.ps1'; Rule = 'releases/latest'; Count = 1; Why = 'voruebergehend' }
            @{ File = 'AppUpdates-Engine.ps1'; Rule = 'Find-Module'; Count = 1; Why = 'voruebergehend' }
            @{ File = 'AppUpdates-Engine.ps1'; Rule = 'Install-Module ohne RequiredVersion'; Count = 2; Why = 'voruebergehend' }
            @{ File = 'AppUpdates-Target.ps1'; Rule = 'Install-Module ohne RequiredVersion'; Count = 1; Why = 'voruebergehend' }
        )
        # Dateitext ohne Kommentare
        function Get-CodeText([string]$File) {
            $tok = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($File, [ref]$tok, [ref]$null)
            $sb = New-Object System.Text.StringBuilder ([IO.File]::ReadAllText($File))
            foreach ($t in @($tok | Where-Object { $_.Kind -eq 'Comment' } | Sort-Object { $_.Extent.StartOffset } -Descending)) {
                $len = $t.Extent.EndOffset - $t.Extent.StartOffset
                [void]$sb.Remove($t.Extent.StartOffset, $len).Insert($t.Extent.StartOffset, (' ' * $len))
            }
            return $sb.ToString()
        }
        $script:Found = @{}
        foreach ($f in @(Get-ChildItem -Path (Join-Path $script:Root 'Functions') -Filter *.ps1 -File)) {
            $code = Get-CodeText $f.FullName
            foreach ($r in $script:Rules.Keys) {
                $n = [regex]::Matches($code, $script:Rules[$r], 'IgnoreCase').Count
                if ($n) { $script:Found["$($f.Name)|$r"] = $n }
            }
        }
    }
    It 'jede Fundstelle steht mit genau dieser Anzahl in der Ausnahmeliste' {
        $extra = @(foreach ($k in $script:Found.Keys) {
                $f, $r = $k -split '\|', 2
                $a = @($script:Allowed | Where-Object { $_.File -eq $f -and $_.Rule -eq $r })[0]
                if (-not $a) { "$k ($($script:Found[$k])x, nicht erlaubt)" } elseif ($a.Count -ne $script:Found[$k]) { "$k ($($script:Found[$k])x statt $($a.Count)x)" }
            })
        $extra | Should -BeNullOrEmpty
    }
    It 'jede Ausnahme gibt es noch (veraltete Eintraege fallen auf) und hat eine Begruendung' {
        foreach ($a in $script:Allowed) {
            $script:Found.ContainsKey("$($a.File)|$($a.Rule)") | Should -BeTrue -Because "$($a.File): $($a.Rule)"
            "$($a.Why)".Length | Should -BeGreaterThan 10 -Because "$($a.File): $($a.Rule)"
        }
    }
    It 'die Pruefung erkennt Aufrufe ohne feste Version (auch in Texten) und laesst feste Aufrufe und Kommentare durch' {
        $f = Join-Path $TestDrive 'probe.ps1'
        [IO.File]::WriteAllText($f, @'
# Install-Module -Name X  (Kommentar zaehlt nicht)
Install-Module -Name X -RequiredVersion 1.2.3 -Scope AllUsers
Install-Module -Name Y -Scope AllUsers
$s = "Install-Module -Name Z -Force; Find-Module Z"
$u = 'https://api.github.com/repos/a/b/releases/latest'
'@)
        $code = Get-CodeText $f
        [regex]::Matches($code, $script:Rules['Install-Module ohne RequiredVersion'], 'IgnoreCase').Count | Should -Be 2
        [regex]::Matches($code, $script:Rules['Find-Module'], 'IgnoreCase').Count | Should -Be 1
        [regex]::Matches($code, $script:Rules['releases/latest'], 'IgnoreCase').Count | Should -Be 1
    }
}
