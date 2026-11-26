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

Describe 'PowerShell 7 am Ziel-PC: feste Fassung, Tausch der eigenen Kopie, jeder Fall der Abwaertsvertraeglichkeit' {
    BeforeAll {
        Import-TargetFunction @('Get-TPwsh', 'Select-TPwshPackage', 'Compare-TPwshVersion', 'Get-TPwshZip', 'Get-TFileSha256', 'Expand-TPwshZip', 'Move-TDir', 'Remove-TDir',
            'Get-TProcessPaths', 'Get-TFileProductVersion', 'Test-TPathsInDirs', 'Test-TPwshInUse', 'Get-TPwshOwnVersion', 'Clear-TPwshLeftover', 'Install-TPwshPackage', 'Install-TPwsh')
        # echtes ZIP mit einem Ersatz-pwsh.exe (Text) im TestDrive, Pruefsumme dazu
        $src = Join-Path $TestDrive 'zipsrc'; New-Item -ItemType Directory -Path $src -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $src 'pwsh.exe'), 'NEU 7.6.10')
        $script:Zip = Join-Path $TestDrive 'PowerShell-7.6.10-win-x64.zip'
        Compress-Archive -Path (Join-Path $src '*') -DestinationPath $script:Zip -Force
        $src2 = Join-Path $TestDrive 'zipleer'; New-Item -ItemType Directory -Path $src2 -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $src2 'liesmich.txt'), 'kein pwsh')
        $script:ZipOhne = Join-Path $TestDrive 'ohne.zip'
        Compress-Archive -Path (Join-Path $src2 '*') -DestinationPath $script:ZipOhne -Force
        $script:Sha = (Get-FileHash -LiteralPath $script:Zip -Algorithm SHA256).Hash
        $script:ShaOhne = (Get-FileHash -LiteralPath $script:ZipOhne -Algorithm SHA256).Hash
        function global:Out-L([string]$t) { $global:T_Log += $t }
        # Ersatz fuer Download und Prozessliste (kein Netz, keine echten Prozesse)
        function global:Get-TPwshZip([string]$Url, [string]$OutFile) {
            $global:T_Calls += "ZIP:$Url"
            if (-not $global:T_Net) { throw 'Netz nicht erreichbar' }
            Copy-Item -LiteralPath $global:T_ZipFile -Destination $OutFile
        }
        function global:Get-TProcessPaths { if ($global:T_ProcFail) { throw 'Zugriff verweigert' }; return @($global:T_Procs) }
        function global:Get-TFileProductVersion([string]$Path) { if (-not (Test-Path -LiteralPath $Path)) { throw 'fehlt' }; return $global:T_ProdVer }
        # Umbenennen mit gezieltem Fehlschlag (T_FailFrom = Ordner, dessen Umbenennen scheitert)
        function global:Move-TDir([string]$From, [string]$To) {
            $global:T_Calls += "MOVE:$(Split-Path $From -Leaf)>$(Split-Path $To -Leaf)"
            if ($global:T_FailFrom -and $From -eq $global:T_FailFrom) { throw 'Zugriff verweigert (Ersatz)' }
            Move-Item -LiteralPath $From -Destination $To -ErrorAction Stop
        }
        # Fall vorbereiten: Ordner im TestDrive, eigene Kopie mit Version (Versionsdatei oder nur Produktversion), MSI ja/nein
        $script:Setup = {
            param([string]$Own = '', [bool]$Json = $true, [bool]$Msi = $false, [bool]$Net = $true, [string]$Sha = $script:Sha, [string]$ZipFile = $script:Zip, [bool]$Install = $true, $Tools = 'gueltig')
            $pf = Join-Path $TestDrive ('pf_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            $global:PwshDir = Join-Path $pf 'HUMig\PowerShell7'; $global:PwshNeu = "$global:PwshDir.neu"; $global:PwshAlt = "$global:PwshDir.alt"; $global:PwshInfo = 'humig-pwsh.json'
            $global:PwshMsi = Join-Path $pf 'PowerShell\7\pwsh.exe'; $global:Base = Join-Path $pf 'Data\HUMig\AppUpdates'
            if ($Own) {
                New-Item -ItemType Directory -Path $global:PwshDir -Force | Out-Null
                [IO.File]::WriteAllText((Join-Path $global:PwshDir 'pwsh.exe'), "ALT $Own")
                if ($Json) { [IO.File]::WriteAllText((Join-Path $global:PwshDir 'humig-pwsh.json'), "{`"version`":`"$Own`"}") }
            }
            if ($Msi) { New-Item -ItemType Directory -Path (Split-Path $global:PwshMsi) -Force | Out-Null; [IO.File]::WriteAllText($global:PwshMsi, 'MSI') }
            $global:T_ProdVer = "$Own SHA: 0123abcd"
            $global:T_Net = $Net; $global:T_ZipFile = $ZipFile; $global:T_Procs = @(); $global:T_ProcFail = $false; $global:T_FailFrom = ''
            $global:T_Log = @(); $global:T_Calls = @(); $script:TErr = @(); $global:TErr = @()
            $global:My = @{ InstallPwsh = $Install }
            $url = 'https://github.com/PowerShell/PowerShell/releases/download/v7.6.10/PowerShell-7.6.10-win-x64.zip'
            $pk = @{ Datei = 'PowerShell-7.6.10-win-x64.zip'; Url = $url; Sha256 = $Sha }
            $global:Payload = @{ Tools = $(if ("$Tools" -eq 'gueltig') { @{ Pwsh = @{ Version = '7.6.10'; Pakete = @{ x64 = $pk; arm64 = $pk } } } } else { $Tools }) }
        }
        $script:OwnExe = { Join-Path $global:PwshDir 'pwsh.exe' }
        $script:Content = { [IO.File]::ReadAllText((Join-Path $global:PwshDir 'pwsh.exe')) }
        $script:Errs = { @(@($script:TErr) + @($global:TErr) | Where-Object { $_ }) }
        $script:NoRest = { (Test-Path -LiteralPath $global:PwshNeu) -or (Test-Path -LiteralPath $global:PwshAlt) }
        # Ergebnis aus den Wirkungen ablesen: Fehler, Protokollzeilen, Downloads
        $script:State = {
            $log = ($global:T_Log -join "`n")
            if (@(& $script:Errs | Where-Object { $_ -like 'PowerShell 7*' }).Count) { 'Fehlt' }
            elseif ($log -match 'laeuft gerade') { 'Laeuft' }
            elseif ($log -match 'ist neuer als die feste') { 'Neuer' }
            elseif ($log -match 'Version der eigenen Kopie nicht lesbar') { 'Unlesbar' }
            elseif ($log -match '(?m)^Warnung:') { 'Behalten' }
            elseif ($log -match 'wird durch die feste Fassung' -and $log -match 'bereit \(') { 'Ersetzt' }
            elseif ($log -match 'bereit \(') { 'Neu' }
            elseif (Test-Path -LiteralPath $global:PwshMsi) { 'Msi' }
            elseif (-not $global:My.InstallPwsh) { 'Vorhanden' }
            elseif (-not @($global:T_Calls | Where-Object { $_ -like 'ZIP:*' }).Count) { 'Aktuell' }
            else { 'unbekannt' }
        }
    }
    AfterAll {
        foreach ($n in @('Out-L', 'Get-TPwsh', 'Select-TPwshPackage', 'Compare-TPwshVersion', 'Get-TPwshZip', 'Get-TFileSha256', 'Expand-TPwshZip', 'Move-TDir', 'Remove-TDir', 'Get-TProcessPaths', 'Get-TFileProductVersion', 'Test-TPathsInDirs', 'Test-TPwshInUse', 'Get-TPwshOwnVersion', 'Clear-TPwshLeftover', 'Install-TPwshPackage', 'Install-TPwsh')) {
            Remove-Item "Function:\global:$n" -ErrorAction SilentlyContinue
        }
    }

    It 'nichts vorhanden, Netz da: feste Fassung wird eingerichtet, mit Versionsdatei, ohne Reste' {
        & $script:Setup
        Install-TPwsh
        & $script:State | Should -Be 'Neu'
        & $script:Content | Should -Be 'NEU 7.6.10'
        (Get-Content (Join-Path $global:PwshDir 'humig-pwsh.json') -Raw | ConvertFrom-Json).version | Should -Be '7.6.10'
        Get-TPwsh | Should -Be (& $script:OwnExe)
        & $script:NoRest | Should -BeFalse
        & $script:Errs | Should -BeNullOrEmpty
        @($global:T_Calls | Where-Object { $_ -like 'ZIP:*' }) | Should -Be @('ZIP:https://github.com/PowerShell/PowerShell/releases/download/v7.6.10/PowerShell-7.6.10-win-x64.zip')
        @(Get-ChildItem -LiteralPath $global:Base -Filter 'pwsh_*.zip').Count | Should -Be 0
    }
    It 'eigene aeltere Kopie (Versionsdatei): wird ohne Rueckfrage ersetzt, Protokollzeile, ohne Reste' {
        & $script:Setup '7.4.6'
        Install-TPwsh
        & $script:State | Should -Be 'Ersetzt'
        & $script:Content | Should -Be 'NEU 7.6.10'
        ($global:T_Log -join "`n") | Should -Match 'PowerShell 7 7\.4\.6 wird durch die feste Fassung 7\.6\.10 ersetzt'
        & $script:NoRest | Should -BeFalse
        & $script:Errs | Should -BeNullOrEmpty
    }
    It 'eigene aeltere Kopie von frueher (ohne Versionsdatei, Version aus pwsh.exe): wird ersetzt' {
        & $script:Setup '7.5.4' $false
        Install-TPwsh
        & $script:State | Should -Be 'Ersetzt'
        & $script:Content | Should -Be 'NEU 7.6.10'
    }
    It 'eigene Kopie mit unlesbarer Version (keine Versionsdatei, Produktversion leer oder unbekannt): nie zurueckstufen, in diesem Lauf nicht ersetzt' {
        & $script:Setup '7.5.4' $false
        $global:T_ProdVer = ''
        Install-TPwsh
        & $script:State | Should -Be 'Unlesbar'
        & $script:Content | Should -Be 'ALT 7.5.4'
        @($global:T_Calls | Where-Object { $_ -like 'ZIP:*' }).Count | Should -Be 0
        & $script:Errs | Should -BeNullOrEmpty
        & $script:Setup '7.5.4' $false
        $global:T_ProdVer = 'Version unbekannt'
        Install-TPwsh
        & $script:State | Should -Be 'Unlesbar'
        & $script:Content | Should -Be 'ALT 7.5.4'
    }
    It 'gleiche Version schon da: nichts geladen, nichts geaendert' {
        & $script:Setup '7.6.10'
        Install-TPwsh
        & $script:State | Should -Be 'Aktuell'
        & $script:Content | Should -Be 'ALT 7.6.10'
        @($global:T_Calls).Count | Should -Be 0
        @($global:T_Log).Count | Should -Be 0
    }
    It 'eigene Kopie neuer als die feste (frueher von "latest" geladen): bleibt, Protokollzeile' {
        & $script:Setup '7.7.1'
        Install-TPwsh
        & $script:State | Should -Be 'Neuer'
        & $script:Content | Should -Be 'ALT 7.7.1'
        @($global:T_Calls).Count | Should -Be 0
    }
    It 'eigene aeltere Kopie, kein Netz: bleibt, Warnung, kein Fehler, der Lauf nimmt sie (Get-TPwsh)' {
        & $script:Setup '7.4.6' -Net $false
        Install-TPwsh
        & $script:State | Should -Be 'Behalten'
        & $script:Content | Should -Be 'ALT 7.4.6'
        Get-TPwsh | Should -Be (& $script:OwnExe)
        ($global:T_Log -join "`n") | Should -Match '(?m)^Warnung: PowerShell 7 7\.6\.10 nicht eingerichtet \(Netz nicht erreichbar\) - die vorhandene Fassung 7\.4\.6 wird weiter verwendet'
        & $script:Errs | Should -BeNullOrEmpty
        & $script:NoRest | Should -BeFalse
    }
    It 'eigene aeltere Kopie, Pruefsumme falsch: nicht eingerichtet, alte bleibt, Warnung, nichts entpackt' {
        & $script:Setup '7.4.6' -Sha ('0' * 64)
        Install-TPwsh
        & $script:State | Should -Be 'Behalten'
        & $script:Content | Should -Be 'ALT 7.4.6'
        ($global:T_Log -join "`n") | Should -Match 'Pruefsumme passt nicht'
        @($global:T_Calls | Where-Object { $_ -like 'MOVE:*' }).Count | Should -Be 0
        & $script:NoRest | Should -BeFalse
        & $script:Errs | Should -BeNullOrEmpty
    }
    It 'eigene aeltere Kopie, ZIP ohne pwsh.exe: alte bleibt, nichts getauscht' {
        & $script:Setup '7.4.6' -Sha $script:ShaOhne -ZipFile $script:ZipOhne
        Install-TPwsh
        & $script:State | Should -Be 'Behalten'
        & $script:Content | Should -Be 'ALT 7.4.6'
        ($global:T_Log -join "`n") | Should -Match 'pwsh.exe nach dem Entpacken nicht gefunden'
        & $script:NoRest | Should -BeFalse
    }
    It 'eigene Kopie laeuft gerade (Zeitplan): in diesem Lauf nicht getauscht, Protokollzeile, nichts geladen' {
        & $script:Setup '7.4.6'
        $global:T_Procs = @('C:\Windows\explorer.exe', (Join-Path $global:PwshDir 'pwsh.exe'))
        Install-TPwsh
        & $script:State | Should -Be 'Laeuft'
        & $script:Content | Should -Be 'ALT 7.4.6'
        ($global:T_Log -join "`n") | Should -Match 'laeuft gerade'
        @($global:T_Calls).Count | Should -Be 0
        Get-TPwsh | Should -Be (& $script:OwnExe)
    }
    It 'Prozessliste nicht lesbar: gilt als laufend, nicht getauscht' {
        & $script:Setup '7.4.6'
        $global:T_ProcFail = $true
        Install-TPwsh
        & $script:State | Should -Be 'Laeuft'
        & $script:Content | Should -Be 'ALT 7.4.6'
    }
    It 'Umbenennen der neuen Fassung scheitert: alte wird zurueckbenannt, keine Reste, Warnung' {
        & $script:Setup '7.4.6'
        $global:T_FailFrom = $global:PwshNeu
        Install-TPwsh
        & $script:State | Should -Be 'Behalten'
        & $script:Content | Should -Be 'ALT 7.4.6'
        @($global:T_Calls | Where-Object { $_ -like 'MOVE:*' }) | Should -Be @('MOVE:PowerShell7>PowerShell7.alt', 'MOVE:PowerShell7.neu>PowerShell7', 'MOVE:PowerShell7.alt>PowerShell7')
        ($global:T_Log -join "`n") | Should -Match 'Tausch fehlgeschlagen'
        & $script:NoRest | Should -BeFalse
        & $script:Errs | Should -BeNullOrEmpty
    }
    It 'Umbenennen der alten Fassung scheitert: alte bleibt unberuehrt, keine Reste' {
        & $script:Setup '7.4.6'
        $global:T_FailFrom = $global:PwshDir
        Install-TPwsh
        & $script:State | Should -Be 'Behalten'
        & $script:Content | Should -Be 'ALT 7.4.6'
        & $script:NoRest | Should -BeFalse
    }
    It 'gar keine PowerShell 7 und kein Netz: derselbe Fehler wie bisher ("PowerShell 7 nicht installierbar")' {
        & $script:Setup '' -Net $false
        Install-TPwsh
        & $script:State | Should -Be 'Fehlt'
        @(& $script:Errs) | Should -Be @('PowerShell 7 nicht installierbar: Netz nicht erreichbar')
        Get-TPwsh | Should -Be ''
        & $script:NoRest | Should -BeFalse
        Test-Path -LiteralPath $global:PwshDir | Should -BeFalse
    }
    It 'MSI-PowerShell vorhanden: wird verwendet, nichts geladen, eigene Kopie und MSI unberuehrt' {
        & $script:Setup '7.4.6' -Msi $true
        Install-TPwsh
        & $script:State | Should -Be 'Msi'
        Get-TPwsh | Should -Be $global:PwshMsi
        [IO.File]::ReadAllText($global:PwshMsi) | Should -Be 'MSI'
        & $script:Content | Should -Be 'ALT 7.4.6'
        @($global:T_Calls).Count | Should -Be 0
        @($global:T_Log).Count | Should -Be 0
    }
    It 'Auftrag ohne InstallPwsh: vorhandene Kopie wird nur verwendet (kein Download), ohne Kopie die bisherige Meldung' {
        & $script:Setup '7.4.6' -Install $false
        Install-TPwsh
        & $script:State | Should -Be 'Vorhanden'
        @($global:T_Calls).Count | Should -Be 0
        & $script:Setup '' -Install $false
        Install-TPwsh
        @(& $script:Errs) | Should -Be @('PowerShell 7 fehlt (fuer das Lesen ohne angemeldeten Benutzer und den Zeitplan noetig)')
    }
    It 'keine gueltige feste Version im Auftrag: vorhandene Kopie bleibt (Warnung), ohne Kopie Fehler, nie ein Download' {
        & $script:Setup '7.4.6' -Tools $null
        Install-TPwsh
        & $script:State | Should -Be 'Behalten'
        ($global:T_Log -join "`n") | Should -Match '(?m)^Warnung: keine gueltige feste Version'
        & $script:Setup '' -Tools @{ Pwsh = @{ Version = 'latest' } }
        Install-TPwsh
        & $script:State | Should -Be 'Fehlt'
        @(& $script:Errs)[0] | Should -Match '^PowerShell 7 nicht installierbar: keine gueltige feste Version'
        @($global:T_Calls).Count | Should -Be 0
    }
    It 'Reste eines abgebrochenen Tauschs: PowerShell7.alt ohne PowerShell7 wird zurueckbenannt (nie geloescht), PowerShell7.neu entfernt' {
        & $script:Setup '7.6.10'
        Move-Item -LiteralPath $global:PwshDir -Destination $global:PwshAlt
        New-Item -ItemType Directory -Path $global:PwshNeu -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $global:PwshNeu 'pwsh.exe'), 'HALB')
        Install-TPwsh
        & $script:Content | Should -Be 'ALT 7.6.10'
        & $script:State | Should -Be 'Aktuell'
        & $script:NoRest | Should -BeFalse
        ($global:T_Log -join "`n") | Should -Match 'vorige Fassung wiederhergestellt'
    }
    It 'Reste: ueberzaehliges PowerShell7.alt neben PowerShell7 wird entfernt, aber nicht, solange daraus etwas laeuft' {
        & $script:Setup '7.6.10'
        New-Item -ItemType Directory -Path $global:PwshAlt -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $global:PwshAlt 'pwsh.exe'), 'ALT')
        $global:T_Procs = @((Join-Path $global:PwshAlt 'pwsh.exe'))
        Install-TPwsh
        Test-Path -LiteralPath $global:PwshAlt | Should -BeTrue
        $global:T_Procs = @()
        Install-TPwsh
        Test-Path -LiteralPath $global:PwshAlt | Should -BeFalse
    }
    It 'Pruefung "laeuft ein Programm daraus" (rein): nur Pfade im Ordner selbst, ohne Gross-/Kleinschreibung, kein Namensanfang' {
        Test-TPathsInDirs @('C:\Programme\HUMig\PowerShell7\pwsh.exe') @('C:\Programme\HUMig\PowerShell7') | Should -BeTrue
        Test-TPathsInDirs @('c:\programme\humig\powershell7\x\y.exe') @('C:\Programme\HUMig\PowerShell7\') | Should -BeTrue
        Test-TPathsInDirs @('C:\Programme\HUMig\PowerShell7.alt\pwsh.exe') @('C:\Programme\HUMig\PowerShell7') | Should -BeFalse
        Test-TPathsInDirs @('C:\Programme\HUMig\PowerShell7.alt\pwsh.exe') @('C:\Programme\HUMig\PowerShell7', 'C:\Programme\HUMig\PowerShell7.alt') | Should -BeTrue
        Test-TPathsInDirs @() @('C:\X') | Should -BeFalse
        Test-TPathsInDirs @('', $null) @('C:\X') | Should -BeFalse
    }
}

Describe 'PowerShell 7 am Ziel-PC: Aufrufstellen im ganzen Ziel-Skript (Zeitplan anlegen, Lesen als SYSTEM)' -Skip:([Environment]::OSVersion.Platform -ne 'Win32NT') {
    BeforeAll {
        $script:WinPs = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        # Ersatz fuer alles, was am PC etwas aendert oder ins Netz geht; Programme und ProgramData zeigen in den TestDrive
        $script:Stubs = @'
$ErrorActionPreference = 'Stop'
# Module mit den echten Befehlen vorher laden: sonst laedt das Ziel-Skript sie unterwegs nach und sie verdecken den Ersatz
Import-Module ScheduledTasks, CimCmdlets -ErrorAction SilentlyContinue
function global:Get-CimInstance { param($ClassName, $Filter, $ErrorAction) if ($ClassName -eq 'Win32_OperatingSystem') { return [pscustomobject]@{ ProductType = 1 } }; return @($global:T_ProcObj) }
function global:Invoke-CimMethod { }
function global:Get-PackageProvider { @([pscustomobject]@{ Version = [version]'2.8.5.201' }) }
function global:Install-PackageProvider { [Console]::Out.WriteLine('C|Install-PackageProvider') }
function global:Install-Module { [Console]::Out.WriteLine('C|Install-Module ' + ($args -join ' ')); throw 'kein Netz (Ersatz)' }
function global:Invoke-WebRequest { [Console]::Out.WriteLine('C|Invoke-WebRequest ' + ($args -join ' ')); throw 'kein Netz (Ersatz)' }
function global:Invoke-RestMethod { [Console]::Out.WriteLine('C|Invoke-RestMethod ' + ($args -join ' ')); throw 'kein Netz (Ersatz)' }
function global:Expand-Archive { [Console]::Out.WriteLine('C|Expand-Archive'); throw 'nicht erwartet' }
function global:Register-ScheduledTask { param($TaskName, $TaskPath, $Action, $Trigger, $Principal, $Settings, $Description, [switch]$Force, $ErrorAction) $global:T_Act = $Action; [Console]::Out.WriteLine('C|Register|' + $TaskName + '|' + $Action.Execute) }
function global:Get-AuthenticodeSignature { param($LiteralPath) [pscustomobject]@{ Status = $(if ($env:T_BADSIG) { 'HashMismatch' } elseif ($env:T_UNKSIG) { 'UnknownError' } else { 'Valid' }); SignerCertificate = [pscustomobject]@{ Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US' } } }
function global:Start-ScheduledTask { param($TaskPath, $TaskName) $m = [regex]::Match("$($global:T_Act.Arguments)", '-Dir "([^"]+)"'); if ($m.Success) { [Console]::Out.WriteLine('C|Request|' + ([IO.File]::ReadAllText((Join-Path $m.Groups[1].Value 'request.json')) -replace '\s+', ' ')); [IO.File]::WriteAllText((Join-Path $m.Groups[1].Value 'result.json'), '{"Items":[{"Id":"Test.App","Name":"Test App","Scope":"User"}],"Errors":[],"Notes":["Hinweis aus dem Worker (Test)"]}') } }
function global:Stop-ScheduledTask { }
function global:Unregister-ScheduledTask { }
function global:Get-ScheduledTask { [pscustomobject]@{ State = 'Running' } }
function global:Get-ScheduledTaskInfo { [pscustomobject]@{ NextRunTime = (Get-Date); LastTaskResult = 0 } }
function global:Get-Service { }
function global:Start-Service { }
function global:Stop-Service { }
function global:Stop-Process { }
function global:Get-Process { @() }
function global:icacls.exe { }
function global:Set-ExecutionPolicy { }
function global:Add-Type { }
function global:Start-Sleep { }
# Sperre: jeder Ersatz muss als eigene Funktion greifen, sonst abbrechen (nie ein echter Befehl)
foreach ($n in @('Get-AuthenticodeSignature', 'Register-ScheduledTask', 'Start-ScheduledTask', 'Stop-ScheduledTask', 'Unregister-ScheduledTask', 'Install-Module', 'Install-PackageProvider', 'Invoke-WebRequest', 'Invoke-RestMethod', 'Expand-Archive', 'Get-CimInstance', 'Stop-Process', 'Stop-Service', 'Start-Service', 'Set-ExecutionPolicy')) { $c = Get-Command $n -ErrorAction SilentlyContinue; if (-not $c -or $c.CommandType -ne 'Function' -or $c.Module) { [Console]::Out.WriteLine("SPERRE|$n"); exit 9 } }
'@
        $script:Safe = @('ConvertFrom-Json', 'ConvertTo-Json', 'ForEach-Object', 'Get-ChildItem', 'Get-Command', 'Get-Content', 'Get-Date', 'Get-FileHash', 'Get-Item', 'Get-ItemProperty',
            'Join-Path', 'Move-Item', 'New-Item', 'New-Object', 'New-ScheduledTaskAction', 'New-ScheduledTaskPrincipal', 'New-ScheduledTaskSettingsSet', 'New-ScheduledTaskTrigger', 'New-TimeSpan',
            'Out-Null', 'Remove-Item', 'Select-Object', 'Set-Content', 'Sort-Object', 'Split-Path', 'Test-Path', 'Where-Object', 'Protect-HMDataDir')
        # Ziel-Skript mit Ersatz in eigenem Prozess; $Prep legt Ordner im TestDrive an. Rueckgabe: Zeilen R|..., L|..., C|...
        $script:RunTarget = {
            param([string]$Op, [string]$PayloadText, [string]$Own = '7.4.6', [bool]$Msi = $false)
            $pf = Join-Path $TestDrive ('PF_' + [guid]::NewGuid().ToString('N').Substring(0, 6)); $pd = Join-Path $TestDrive ('PD_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
            New-Item -ItemType Directory -Path (Join-Path $pf 'WindowsPowerShell\Modules\Microsoft.WinGet.Client\1.29.380') -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $pf 'WindowsPowerShell\Modules\Microsoft.WinGet.Client\1.29.380\Microsoft.WinGet.Client.psd1'), '@{}')
            New-Item -ItemType Directory -Path (Join-Path $pf 'WindowsApps\Microsoft.DesktopAppInstaller_1.0.0.0_x64__8wekyb3d8bbwe') -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $pf 'WindowsApps\Microsoft.DesktopAppInstaller_1.0.0.0_x64__8wekyb3d8bbwe\winget.exe'), 'x')
            if ($Own) {
                New-Item -ItemType Directory -Path (Join-Path $pf 'HUMig\PowerShell7') -Force | Out-Null
                [IO.File]::WriteAllText((Join-Path $pf 'HUMig\PowerShell7\pwsh.exe'), 'ALT')
                [IO.File]::WriteAllText((Join-Path $pf 'HUMig\PowerShell7\humig-pwsh.json'), "{`"version`":`"$Own`"}")
            }
            if ($Msi) { New-Item -ItemType Directory -Path (Join-Path $pf 'PowerShell\7') -Force | Out-Null; [IO.File]::WriteAllText((Join-Path $pf 'PowerShell\7\pwsh.exe'), 'MSI') }
            $q = { param($s) "'" + ("$s" -replace "'", "''") + "'" }
            $pre = $script:Stubs + "`r`n`$env:ProgramFiles = $(& $q $pf)`r`n`$env:ProgramData = $(& $q $pd)`r`n" +
            "`$tools = @{ Pwsh = @{ Version = '7.6.10'; Pakete = @{ x64 = @{ Datei = 'PowerShell-7.6.10-win-x64.zip'; Url = 'https://github.com/PowerShell/PowerShell/releases/download/v7.6.10/PowerShell-7.6.10-win-x64.zip'; Sha256 = '$('A' * 64)' }; arm64 = @{ Datei = 'PowerShell-7.6.10-win-arm64.zip'; Url = 'https://github.com/PowerShell/PowerShell/releases/download/v7.6.10/PowerShell-7.6.10-win-arm64.zip'; Sha256 = '$('B' * 64)' } } }; WinGet = @{ Version = '1.29.380'; Name = 'Microsoft.WinGet.Client'; Herausgeber = ', O=Microsoft Corporation, L=Redmond, S=Washington, C=US' } }`r`n" +
            "`$p = $PayloadText`r`n" +
            "foreach (`$o in @(& $(& $q $script:TargetFile) -Op '$Op' -Payload `$p -WorkerText 'w' -AutoText 'a')) { if (`"`$(`$o.HMAu)`" -eq 'R') { [Console]::Out.WriteLine('R|' + `$o.J) } elseif (`"`$(`$o.HMAu)`" -eq 'L') { [Console]::Out.WriteLine('L|' + `$o.V) } }"
            $f = Join-Path $TestDrive ("run_{0}.ps1" -f [guid]::NewGuid().ToString('N'))
            [IO.File]::WriteAllText($f, $pre, (New-Object System.Text.UTF8Encoding($true)))
            $out = @(& $script:WinPs -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $f 2>&1 | ForEach-Object { "$_" })
            return [pscustomobject]@{ Out = $out; Pf = $pf; Pd = $pd; Psd = (Join-Path $pf 'WindowsPowerShell\Modules\Microsoft.WinGet.Client\1.29.380\Microsoft.WinGet.Client.psd1'); Own = (Join-Path $pf 'HUMig\PowerShell7\pwsh.exe'); Msi = (Join-Path $pf 'PowerShell\7\pwsh.exe')
                R = $(try { (@($out | Where-Object { $_ -like 'R|*' })[0]).Substring(2) | ConvertFrom-Json } catch { $null }) }
        }
        $script:SchedPayload = "@{ Mode = 'Daily'; Time = '03:00'; Days = @(); Sources = @('winget'); Exclude = @(); Location = ''; By = 'Test'; Wake = `$false; InstallPwsh = `$true; Tools = `$tools }"
        $script:SearchPayload = "@{ ByPc = @{ `"`$(`"`$env:COMPUTERNAME`".ToUpper())`" = @{ Sources = @('winget'); IncludeUnknown = `$false; UserSid = ''; InstallPwsh = `$true } }; Tools = `$tools }"
    }
    It 'Vorbedingung: jeder Befehl des Ziel-Skripts ist im Skript definiert, ersetzt oder harmlos (am PC wird nichts geaendert)' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:TargetFile, [ref]$null, [ref]$null)
        $defs = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })
        $sa = [System.Management.Automation.Language.Parser]::ParseInput($script:Stubs, [ref]$null, [ref]$null)
        $stub = @($sa.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name -replace '^global:', '' })
        $cmds = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ } | Sort-Object -Unique)
        @($cmds | Where-Object { $defs -notcontains $_ -and $stub -notcontains $_ -and $script:Safe -notcontains $_ }) | Should -BeNullOrEmpty
        # die Sperre im Vorspann bricht ab, wenn ein Ersatz nicht greift
        $script:Stubs | Should -Match 'exit 9'
    }
    It 'Zeitplan anlegen, eigene aeltere Kopie, kein Netz: Zeitplan wird mit der vorhandenen PowerShell 7 angelegt, Warnung, kein Fehler' {
        $r = & $script:RunTarget 'ScheduleSet' $script:SchedPayload
        $r.R.Ok | Should -BeTrue -Because ($r.Out -join "`n")
        @($r.R.Errors).Count | Should -Be 0
        @($r.Out | Where-Object { $_ -like 'C|Register|*' }) | Should -Be @("C|Register|HUMig App-Updates|$($r.Own)")
        @($r.Out | Where-Object { $_ -like 'L|Warnung: PowerShell 7 7.6.10 nicht eingerichtet*' }).Count | Should -Be 1
        @($r.Out | Where-Object { $_ -like 'C|Invoke-WebRequest*' }) | Should -Match 'v7\.6\.10/PowerShell-7\.6\.10-win-x64\.zip'
        @($r.Out | Where-Object { $_ -like 'C|Invoke-RestMethod*' }).Count | Should -Be 0
        [IO.File]::ReadAllText($r.Own) | Should -Be 'ALT'
        # der Zeitplan bekommt den Ladepfad der festen Modulversion (laedt spaeter nie selbst etwas nach)
        (Get-Content -LiteralPath (Join-Path $r.Pd 'HUMig\AppUpdates\auto\config.json') -Raw | ConvertFrom-Json).ModulePath | Should -Be $r.Psd
        @($r.Out | Where-Object { $_ -like 'C|Install-Module*' }).Count | Should -Be 0
    }
    It 'Zeitplan anlegen, gar keine PowerShell 7 und kein Netz: wie bisher abgebrochen mit "PowerShell 7 nicht installierbar"' {
        $r = & $script:RunTarget 'ScheduleSet' $script:SchedPayload ''
        $r.R.Ok | Should -BeFalse
        @($r.R.Errors) -join ' ' | Should -Match 'PowerShell 7 nicht installierbar'
        @($r.Out | Where-Object { $_ -like 'C|Register|*' }).Count | Should -Be 0
    }
    It 'Zeitplan anlegen mit MSI-PowerShell: Zeitplan nimmt sie, nichts geladen, eigene Kopie unberuehrt' {
        $r = & $script:RunTarget 'ScheduleSet' $script:SchedPayload '7.4.6' $true
        $r.R.Ok | Should -BeTrue
        @($r.Out | Where-Object { $_ -like 'C|Register|*' }) | Should -Be @("C|Register|HUMig App-Updates|$($r.Msi)")
        @($r.Out | Where-Object { $_ -like 'C|Invoke-WebRequest*' }).Count | Should -Be 0
        [IO.File]::ReadAllText($r.Own) | Should -Be 'ALT'
    }
    It 'Lesen ohne angemeldeten Benutzer, eigene aeltere Kopie, kein Netz: liest als SYSTEM mit der vorhandenen PowerShell 7' {
        $r = & $script:RunTarget 'Search' $script:SearchPayload
        $r.R.ReadAs | Should -Be 'SYSTEM (PowerShell 7)' -Because ($r.Out -join "`n")
        @($r.R.Items).Count | Should -Be 1
        @($r.Out | Where-Object { $_ -like 'C|Register|*' }) | Should -Match ([regex]::Escape("|$($r.Own)"))
        @($r.Out | Where-Object { $_ -like 'L|Warnung: PowerShell 7*' }).Count | Should -Be 1
        @($r.R.Errors | Where-Object { $_ -match 'PowerShell 7' }).Count | Should -Be 0
        # die Hilfsaufgabe laedt das Modul ueber den Pfad der festen Version
        $rq = @($r.Out | Where-Object { $_ -like 'C|Request|*' })[0].Substring(10) | ConvertFrom-Json
        $rq.ModulePath | Should -Be $r.Psd
        $rq.ModuleBlocked | Should -BeFalse
        $rq.Mode | Should -Be 'List'
        # Hinweise des Workers (z. B. Modul nicht ladbar) kommen ins Protokoll
        @($r.Out | Where-Object { $_ -eq 'L|Hinweis aus dem Worker (Test)' }).Count | Should -Be 1
    }
    It 'feste Modulversion mit ungueltiger Signatur, keine andere: Lesen bricht ab wie ohne Modul, kein Worker, nichts nach Namen geladen' {
        $env:T_BADSIG = '1'
        try { $r = & $script:RunTarget 'Search' $script:SearchPayload } finally { $env:T_BADSIG = '' }
        $r.R.ReadAs | Should -Be ''
        @($r.R.Items).Count | Should -Be 0
        @($r.R.Errors) -join ' ' | Should -Match 'WinGet-Modul nicht nutzbar'
        @($r.Out | Where-Object { $_ -like 'C|Register|*' }).Count | Should -Be 0
        @($r.Out | Where-Object { $_ -like 'L|Warnung: WinGet-Modul 1.29.380 wird nicht geladen, Signatur ungueltig*' }).Count | Should -Be 1
    }
    It 'Signatur nicht pruefbar: Lesen laeuft wie bisher mit der festen Version, Warnung im Protokoll' {
        $env:T_UNKSIG = '1'
        try { $r = & $script:RunTarget 'Search' $script:SearchPayload } finally { $env:T_UNKSIG = '' }
        $r.R.ReadAs | Should -Be 'SYSTEM (PowerShell 7)'
        (@($r.Out | Where-Object { $_ -like 'C|Request|*' })[0].Substring(10) | ConvertFrom-Json).ModulePath | Should -Be $r.Psd
        @($r.Out | Where-Object { $_ -like 'L|Warnung: WinGet-Modul 1.29.380: Signatur nicht pruefbar*' }).Count | Should -Be 1
        @($r.Out | Where-Object { $_ -like 'C|Install-Module*' }).Count | Should -Be 0
    }
    It 'feste Modulversion mit ungueltiger Signatur, keine andere: Zeitplan wird nicht angelegt (Ok = falsch)' {
        $env:T_BADSIG = '1'
        try { $r = & $script:RunTarget 'ScheduleSet' $script:SchedPayload } finally { $env:T_BADSIG = '' }
        $r.R.Ok | Should -BeFalse
        @($r.R.Errors) -join ' ' | Should -Match 'WinGet-Modul nicht nutzbar'
        @($r.Out | Where-Object { $_ -like 'C|Register|*' }).Count | Should -Be 0
    }
}

Describe 'WinGet-Modul: nur die feste Version installieren und laden, Signatur geprueft, Rueckfall auf eine vorhandene Version' {
    BeforeAll {
        Import-TargetFunction @('Test-TModule', 'Get-TModFixed', 'Install-TModule', 'Get-TModuleSigFiles', 'Test-TModuleSignature', 'Get-TModuleLoad', 'Resolve-TModuleLoad',
            'Get-TModOtherDir', 'Test-TModRetryDue', 'Set-TModRetryMarker', 'Clear-TModRetryMarker', 'Get-TModSigState', 'Get-TModBlockedText')
        function global:Get-TNow { $global:T_Now }
        . (Join-Path $script:Root 'Functions\AppUpdates-Engine.ps1')
        $script:Pub = ', O=Microsoft Corporation, L=Redmond, S=Washington, C=US'
        function global:Out-L([string]$t) { $global:T_Log += $t }
        function global:Get-PackageProvider { @([pscustomobject]@{ Version = [version]'2.8.5.201' }) }
        function global:Install-PackageProvider { $global:T_Calls += 'NuGet' }
        function global:Install-Module {
            param($Name, $RequiredVersion, $Repository, $Scope, [switch]$Force, [switch]$AllowClobber, $ErrorAction)
            $global:T_Calls += "Install-Module $Name $RequiredVersion"
            if (-not $global:T_Net) { throw 'kein Netz (Ersatz)' }
            $d = Join-Path $global:ModRoot $RequiredVersion; New-Item -ItemType Directory -Path $d -Force | Out-Null; [IO.File]::WriteAllText((Join-Path $d "$Name.psd1"), '@{}')
            if ($global:T_RepairFixes) { $global:T_BadSig = @($global:T_BadSig | Where-Object { $_ -ne $RequiredVersion }) }
        }
        function global:Find-Module { $global:T_Calls += 'Find-Module' }
        # Signaturen als Ersatz: je Version gueltig oder nicht
        function global:Get-TModuleSigFiles([string]$Dir) {
            $global:T_SigCalls++
            if ($global:T_SigThrow) { throw 'Zertifikatspruefung nicht moeglich (Ersatz)' }
            $v = Split-Path $Dir -Leaf
            $st = if ($global:T_BadSig -contains $v) { 'HashMismatch' } elseif ($global:T_UnkSig -contains $v) { 'NotTrusted' } else { 'Valid' }
            return @(@{ Path = (Join-Path $Dir 'Microsoft.WinGet.Client.psd1'); Status = $st; Subject = "CN=Microsoft Corporation$script:Pub" }, @{ Path = (Join-Path $Dir 'a.dll'); Status = 'Valid'; Subject = "CN=Microsoft Corporation$script:Pub" })
        }
        $script:Setup = {
            param([string[]]$Have = @(), [bool]$Net = $true, $Fixed = 'gueltig', [string[]]$BadSig = @(), [string[]]$UnkSig = @(), [bool]$RepairFixes = $false)
            $global:Base = Join-Path $TestDrive ('base_' + [guid]::NewGuid().ToString('N').Substring(0, 8)); $global:TModMarker = Join-Path $global:Base 'winget-modul-versuch.json'
            $global:T_UnkSig = $UnkSig; $global:T_RepairFixes = $RepairFixes; $global:T_SigCalls = 0; $global:T_SigThrow = $false; $global:T_Now = [datetime]'2026-11-26T03:00:00'
            $global:TModSig = $null; $script:TModSig = $null
            $pf = Join-Path $TestDrive ('mod_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            $global:ModName = 'Microsoft.WinGet.Client'; $global:ModRoot = Join-Path $pf 'WindowsPowerShell\Modules\Microsoft.WinGet.Client'
            $env:ProgramFiles = $pf
            foreach ($v in $Have) { $d = Join-Path $global:ModRoot $v; New-Item -ItemType Directory -Path $d -Force | Out-Null; [IO.File]::WriteAllText((Join-Path $d 'Microsoft.WinGet.Client.psd1'), '@{}') }
            $global:T_Net = $Net; $global:T_BadSig = $BadSig; $global:T_Log = @(); $global:T_Calls = @(); $script:TErr = @(); $global:TErr = @(); $global:TModLoad = $null; $script:TModLoad = $null
            $global:Payload = @{ Tools = $(if ("$Fixed" -eq 'gueltig') { @{ WinGet = @{ Version = '1.29.380'; Name = 'Microsoft.WinGet.Client'; Herausgeber = $script:Pub } } } else { $Fixed }) }
        }
        $script:Errs = { @(@($script:TErr) + @($global:TErr) | Where-Object { $_ }) }
        $script:PF0 = $env:ProgramFiles
    }
    AfterAll {
        $env:ProgramFiles = $script:PF0
        foreach ($n in @('Out-L', 'Get-TNow', 'Get-PackageProvider', 'Install-PackageProvider', 'Install-Module', 'Find-Module', 'Test-TModule', 'Get-TModFixed', 'Install-TModule', 'Get-TModuleSigFiles', 'Test-TModuleSignature', 'Get-TModuleLoad', 'Resolve-TModuleLoad', 'Get-TModOtherDir', 'Test-TModRetryDue', 'Set-TModRetryMarker', 'Clear-TModRetryMarker', 'Get-TModSigState', 'Get-TModBlockedText')) { Remove-Item "Function:\global:$n" -ErrorAction SilentlyContinue }
    }
    AfterEach { $env:ProgramFiles = $script:PF0 }
    It 'feste Version fehlt, keine andere da: Install-Module nur mit -RequiredVersion 1.29.380, nie Find-Module' {
        & $script:Setup
        Install-TModule
        @($global:T_Calls | Where-Object { $_ -like 'Install-Module*' }) | Should -Be @('Install-Module Microsoft.WinGet.Client 1.29.380')
        $global:T_Calls | Should -Not -Contain 'Find-Module'
        & $script:Errs | Should -BeNullOrEmpty
    }
    It 'feste Version schon da: kein Install-Module (auch nicht dieselbe Version erneut)' {
        & $script:Setup @('1.29.380')
        Install-TModule
        @($global:T_Calls).Count | Should -Be 0
        @($global:T_Log).Count | Should -Be 0
    }
    It 'andere Version da, feste nicht installierbar: vorhandene wird verwendet, Protokollzeile, kein Fehler, nichts geloescht' {
        & $script:Setup @('1.9.2411') -Net $false
        Install-TModule
        & $script:Errs | Should -BeNullOrEmpty
        ($global:T_Log -join "`n") | Should -Match '(?m)^Warnung: WinGet-Modul 1\.29\.380 nicht installierbar .* die vorhandene Version wird verwendet'
        Test-TModule | Should -BeTrue
        $ld = Get-TModuleLoad
        $ld.Path | Should -Be (Join-Path $global:ModRoot '1.9.2411\Microsoft.WinGet.Client.psd1')
        $ld.Note | Should -Match 'feste Version 1\.29\.380 fehlt - die vorhandene Version 1\.9\.2411 wird verwendet'
    }
    It 'gar kein Modul und kein Netz: derselbe Fehler wie bisher' {
        & $script:Setup @() -Net $false
        Install-TModule
        @(& $script:Errs) | Should -Be @('WinGet-Modul nicht installierbar (Internet/Proxy?): kein Netz (Ersatz)')
        Test-TModule | Should -BeFalse
    }
    It 'keine gueltige feste Version im Auftrag: vorhandenes Modul bleibt ohne Download, ohne Modul ein Fehler, nie ein Install-Module ohne Version' {
        & $script:Setup @('1.9.2411') -Fixed $null
        Install-TModule
        @($global:T_Calls).Count | Should -Be 0
        & $script:Errs | Should -BeNullOrEmpty
        (Get-TModuleLoad).Path | Should -Match '1\.9\.2411'
        & $script:Setup @() -Fixed @{ WinGet = @{ Version = 'latest'; Name = 'Microsoft.WinGet.Client'; Herausgeber = $script:Pub } }
        Install-TModule
        @($global:T_Calls).Count | Should -Be 0
        @(& $script:Errs)[0] | Should -Match 'keine gueltige feste Version'
    }
    It 'feste Version installiert und gueltig signiert: sie wird geladen (Pfad), auch wenn eine hoehere andere da ist' {
        & $script:Setup @('1.29.380', '1.30.1')
        $ld = Get-TModuleLoad
        $ld.Path | Should -Be (Join-Path $global:ModRoot '1.29.380\Microsoft.WinGet.Client.psd1')
        $ld.Note | Should -Be ''
    }
    It 'feste Version mit ungueltiger Signatur: nicht geladen, vorhandene andere verwendet, nichts geloescht' {
        & $script:Setup @('1.29.380', '1.9.2411') -BadSig @('1.29.380')
        $ld = Get-TModuleLoad
        $ld.Path | Should -Be (Join-Path $global:ModRoot '1.9.2411\Microsoft.WinGet.Client.psd1')
        $ld.Blocked | Should -BeFalse
        $ld.Note | Should -Match 'Signatur ungueltig .*HashMismatch.* - die vorhandene Version 1\.9\.2411 wird verwendet'
        Test-Path -LiteralPath (Join-Path $global:ModRoot '1.29.380\Microsoft.WinGet.Client.psd1') | Should -BeTrue
    }
    It 'feste Version mit ungueltiger Signatur und keine andere: gesperrt (nie nach Namen laden), Warnung, nichts geloescht' {
        & $script:Setup @('1.29.380') -BadSig @('1.29.380')
        $ld = Get-TModuleLoad
        $ld.Path | Should -Be ''
        $ld.Blocked | Should -BeTrue
        $ld.Note | Should -Match '^Warnung: WinGet-Modul 1\.29\.380 wird nicht geladen, Signatur ungueltig'
        Test-Path -LiteralPath (Join-Path $global:ModRoot '1.29.380') | Should -BeTrue
    }
    It 'Hinweis nur einmal je Lauf ins Protokoll (Resolve-TModuleLoad)' {
        & $script:Setup @('1.9.2411')
        Resolve-TModuleLoad; Resolve-TModuleLoad
        @($global:T_Log | Where-Object { $_ -like '*1.9.2411 wird verwendet*' }).Count | Should -Be 1
    }
    $sigCases = @(
        @{ Fall = 'alle gueltig, Microsoft'; Sigs = @(@{ Path = 'x\m.psd1'; Status = 'Valid'; Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US' }, @{ Path = 'x\a.dll'; Status = 'Valid'; Subject = 'CN=Microsoft Windows, O=Microsoft Corporation, L=Redmond, S=Washington, C=US' }); Erg = 'Ok' }
        @{ Fall = 'eine Datei veraendert (HashMismatch)'; Sigs = @(@{ Path = 'x\m.psd1'; Status = 'Valid'; Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US' }, @{ Path = 'x\a.dll'; Status = 'HashMismatch'; Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US' }); Erg = 'Ungueltig' }
        @{ Fall = 'nicht signiert (NotSigned)'; Sigs = @(@{ Path = 'x\m.psd1'; Status = 'NotSigned'; Subject = '' }); Erg = 'Ungueltig' }
        @{ Fall = 'anderer Herausgeber'; Sigs = @(@{ Path = 'x\m.psd1'; Status = 'Valid'; Subject = 'CN=Fremd, O=Fremd GmbH, L=Wien, C=AT' }); Erg = 'Ungueltig' }
        @{ Fall = 'Herausgeber nur als Teil im Namen'; Sigs = @(@{ Path = 'x\m.psd1'; Status = 'Valid'; Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US, OU=Fremd' }); Erg = 'Ungueltig' }
        @{ Fall = 'ohne .psd1'; Sigs = @(@{ Path = 'x\a.dll'; Status = 'Valid'; Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US' }); Erg = 'Ungueltig' }
        @{ Fall = 'leer'; Sigs = @(); Erg = 'Ungueltig' }
        @{ Fall = 'Stammzertifikat fehlt (NotTrusted)'; Sigs = @(@{ Path = 'x\m.psd1'; Status = 'NotTrusted'; Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US' }); Erg = 'NichtPruefbar' }
        @{ Fall = 'UnknownError'; Sigs = @(@{ Path = 'x\m.psd1'; Status = 'Valid'; Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US' }, @{ Path = 'x\a.dll'; Status = 'UnknownError'; Subject = '' }); Erg = 'NichtPruefbar' }
        @{ Fall = 'Incompatible'; Sigs = @(@{ Path = 'x\m.psd1'; Status = 'Incompatible'; Subject = '' }); Erg = 'NichtPruefbar' }
        @{ Fall = 'NotSupportedFileFormat'; Sigs = @(@{ Path = 'x\m.psd1'; Status = 'NotSupportedFileFormat'; Subject = '' }); Erg = 'NichtPruefbar' }
        @{ Fall = 'eindeutiger Befund geht vor (NotTrusted und HashMismatch)'; Sigs = @(@{ Path = 'x\m.psd1'; Status = 'NotTrusted'; Subject = '' }, @{ Path = 'x\a.dll'; Status = 'HashMismatch'; Subject = '' }); Erg = 'Ungueltig' }
    )
    It 'Signaturpruefung (rein), Ziel-PC und HUMig-PC gleich: <Fall> ergibt <Erg>' -TestCases $sigCases {
        param($Fall, $Sigs, $Erg)
        $t = Test-TModuleSignature $Sigs $script:Pub
        $e = Test-HMAuModuleSignature $Sigs $script:Pub
        $t.State | Should -Be $Erg
        $e.State | Should -Be $t.State
        $e.Reason | Should -Be $t.Reason
        if ($Erg -ne 'Ok') { $t.Reason | Should -Not -BeNullOrEmpty }
    }
    It 'Signatur nicht pruefbar (z. B. Stammzertifikate fehlen): feste Version wird wie bisher geladen, Warnung, kein Install-Module' {
        & $script:Setup @('1.29.380') -UnkSig @('1.29.380')
        Install-TModule
        @($global:T_Calls).Count | Should -Be 0
        $ld = Get-TModuleLoad
        $ld.Path | Should -Be (Join-Path $global:ModRoot '1.29.380\Microsoft.WinGet.Client.psd1')
        $ld.Blocked | Should -BeFalse
        $ld.Note | Should -Match '^Warnung: WinGet-Modul 1\.29\.380: Signatur nicht pruefbar \(Microsoft\.WinGet\.Client\.psd1: NotTrusted\) - wird wie bisher geladen'
    }
    It 'Pruefung wirft eine Ausnahme: nicht pruefbar, Modul wird wie bisher geladen' {
        & $script:Setup @('1.29.380')
        $global:T_SigThrow = $true
        Install-TModule
        @($global:T_Calls).Count | Should -Be 0
        $ld = Get-TModuleLoad
        $ld.Path | Should -Match '1\.29\.380'
        $ld.Note | Should -Match 'Signatur nicht pruefbar \(Zertifikatspruefung nicht moeglich'
    }
    It 'Signatur je Lauf nur einmal geprueft (Install-TModule, Ladepfad, Hinweis)' {
        & $script:Setup @('1.29.380')
        Install-TModule; Resolve-TModuleLoad; [void](Get-TModuleLoad)
        $global:T_SigCalls | Should -Be 1
    }
    It 'Selbstreparatur: feste Version eindeutig ungueltig, keine andere - einmal neu installiert, danach gueltig und geladen' {
        & $script:Setup @('1.29.380') -BadSig @('1.29.380') -RepairFixes $true
        Install-TModule
        @($global:T_Calls | Where-Object { $_ -like 'Install-Module*' }) | Should -Be @('Install-Module Microsoft.WinGet.Client 1.29.380')
        ($global:T_Log -join "`n") | Should -Match 'Signatur ungueltig .* wird neu installiert'
        $ld = Get-TModuleLoad
        $ld.Path | Should -Be (Join-Path $global:ModRoot '1.29.380\Microsoft.WinGet.Client.psd1')
        $ld.Blocked | Should -BeFalse
        & $script:Errs | Should -BeNullOrEmpty
    }
    It 'Selbstreparatur ohne Erfolg, keine andere Version: gesperrt, Meldung mit Ordner und Abhilfe, nichts geloescht, bei jedem Lauf neuer Versuch' {
        & $script:Setup @('1.29.380') -BadSig @('1.29.380')
        Install-TModule
        $ld = Get-TModuleLoad
        $ld.Blocked | Should -BeTrue
        $txt = Get-TModBlockedText
        $txt | Should -Match ([regex]::Escape((Join-Path $global:ModRoot '1.29.380')))
        $txt | Should -Match 'Abhilfe: den Ordner .* als Administrator loeschen'
        Test-Path -LiteralPath (Join-Path $global:ModRoot '1.29.380\Microsoft.WinGet.Client.psd1') | Should -BeTrue
        Test-Path -LiteralPath $global:TModMarker | Should -BeFalse
        $global:TModSig = $null; $script:TModSig = $null; $global:T_Calls = @()
        Install-TModule
        @($global:T_Calls | Where-Object { $_ -like 'Install-Module*' }).Count | Should -Be 1
    }
    It 'Selbstreparatur ohne Erfolg, andere Version da: andere wird verwendet, Merker gesetzt' {
        & $script:Setup @('1.29.380', '1.9.2411') -BadSig @('1.29.380')
        Install-TModule
        ($global:T_Log -join "`n") | Should -Match '(?m)^Warnung: WinGet-Modul 1\.29\.380 nicht installierbar \(Signatur weiter ungueltig'
        Test-Path -LiteralPath $global:TModMarker | Should -BeTrue
        (Get-TModuleLoad).Path | Should -Match '1\.9\.2411'
    }
    It 'Merker: andere Version da, kein Netz - naechster Versuch erst nach 24 Stunden, dann wieder; Erfolg entfernt den Merker' {
        & $script:Setup @('1.9.2411') -Net $false
        Install-TModule
        @($global:T_Calls | Where-Object { $_ -like 'Install-Module*' }).Count | Should -Be 1
        $m = Get-Content -LiteralPath $global:TModMarker -Raw | ConvertFrom-Json
        $m.version | Should -Be '1.29.380'
        Test-Path -LiteralPath "$global:TModMarker.tmp" | Should -BeFalse
        $global:T_Calls = @(); $global:T_Log = @(); $global:T_Now = $global:T_Now.AddHours(23)
        Install-TModule
        @($global:T_Calls).Count | Should -Be 0
        ($global:T_Log -join "`n") | Should -Match 'fruehestens 24 Stunden'
        $global:T_Calls = @(); $global:T_Now = $global:T_Now.AddHours(2); $global:T_Net = $true
        Install-TModule
        @($global:T_Calls | Where-Object { $_ -like 'Install-Module*' }).Count | Should -Be 1
        Test-Path -LiteralPath $global:TModMarker | Should -BeFalse
    }
    It 'Merker gilt nicht: andere feste Version, Zeit in der Zukunft, unlesbar' {
        & $script:Setup @('1.9.2411')
        New-Item -ItemType Directory -Path $global:Base -Force | Out-Null
        $now = $global:T_Now.ToUniversalTime().Ticks
        [IO.File]::WriteAllText($global:TModMarker, "{`"version`":`"1.28.0`",`"zeit`":$now}"); Test-TModRetryDue '1.29.380' | Should -BeTrue
        [IO.File]::WriteAllText($global:TModMarker, "{`"version`":`"1.29.380`",`"zeit`":$($now + [TimeSpan]::FromHours(5).Ticks)}"); Test-TModRetryDue '1.29.380' | Should -BeTrue
        [IO.File]::WriteAllText($global:TModMarker, '{ kaputt'); Test-TModRetryDue '1.29.380' | Should -BeTrue
        [IO.File]::WriteAllText($global:TModMarker, "{`"version`":`"1.29.380`",`"zeit`":$now}"); Test-TModRetryDue '1.29.380' | Should -BeFalse
    }
    It 'Merker gilt nicht ohne jede Version: dann wie bisher bei jedem Lauf versuchen' {
        & $script:Setup @() -Net $false
        New-Item -ItemType Directory -Path $global:Base -Force | Out-Null
        [IO.File]::WriteAllText($global:TModMarker, "{`"version`":`"1.29.380`",`"zeit`":$($global:T_Now.ToUniversalTime().Ticks)}")
        Install-TModule
        @($global:T_Calls | Where-Object { $_ -like 'Install-Module*' }).Count | Should -Be 1
        @(& $script:Errs) | Should -Be @('WinGet-Modul nicht installierbar (Internet/Proxy?): kein Netz (Ersatz)')
    }
    It 'Signaturen lesen: nur signierbare Dateitypen (Hilfe-XML und Texte zaehlen nicht)' {
        $d = Join-Path $TestDrive 'sigdir'; New-Item -ItemType Directory -Path $d -Force | Out-Null
        foreach ($n in @('m.psd1', 'a.dll', 'b.ps1xml', 'help.xml', 'NOTICE.txt')) { [IO.File]::WriteAllText((Join-Path $d $n), 'x') }
        Remove-Item Function:\global:Get-TModuleSigFiles
        Import-TargetFunction @('Get-TModuleSigFiles')
        $s = @(Get-TModuleSigFiles $d)
        @($s | ForEach-Object { Split-Path $_.Path -Leaf } | Sort-Object) | Should -Be @('a.dll', 'b.ps1xml', 'm.psd1')
        @(Get-HMAuModuleSigFiles $d).Count | Should -Be 3
        foreach ($x in $s) { $x.Status | Should -Not -Be 'Valid' }
    }
}

Describe 'WinGet-Modul: Worker und Zeitplan-Skript laden den Pfad aus dem Auftrag, sonst wie bisher' -Skip:([Environment]::OSVersion.Platform -ne 'Win32NT') {
    BeforeAll {
        $script:WinPs = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $script:Pwsh = @(Get-Command pwsh.exe -ErrorAction SilentlyContinue)[0]
        # Import-Module als Ersatz (meldet, was geladen wuerde, laedt nichts); Fall "laedt nicht": T_ImportFail
        $script:Pre = @'
$ErrorActionPreference = 'Stop'
function global:Import-Module { param([Parameter(Position = 0)]$Name, [switch]$Force) [Console]::Out.WriteLine("C|Import|$Name"); if ($env:T_IMPORTFAIL -and "$Name" -like $env:T_IMPORTFAIL) { throw 'Modul kaputt (Ersatz)' } }
function global:Get-WinGetSource { @() }
function global:Get-WinGetPackage { @() }
function global:winget.exe { }
'@
        $script:RunScript = {
            param([string]$Exe, [string]$Text)
            $f = Join-Path $TestDrive ("run_{0}.ps1" -f [guid]::NewGuid().ToString('N'))
            [IO.File]::WriteAllText($f, $Text, (New-Object System.Text.UTF8Encoding($true)))
            return @(& $Exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $f 2>&1 | ForEach-Object { "$_" })
        }
        $script:Psd = Join-Path $TestDrive 'Mod\1.29.380\Microsoft.WinGet.Client.psd1'
        New-Item -ItemType Directory -Path (Split-Path $script:Psd) -Force | Out-Null; [IO.File]::WriteAllText($script:Psd, '@{}')
    }
    AfterEach { $env:T_IMPORTFAIL = '' }
    $wcases = @(
        @{ Fall = 'Pfad aus dem Auftrag'; Mp = 'fest'; Fail = ''; Want = @('fest'); Note = $false }
        @{ Fall = 'kein Pfad (aelterer Auftrag)'; Mp = ''; Fail = ''; Want = @('Microsoft.WinGet.Client'); Note = $false }
        @{ Fall = 'Pfad fehlt am PC'; Mp = 'fehlt'; Fail = ''; Want = @('Microsoft.WinGet.Client'); Note = $false }
        @{ Fall = 'feste Version laedt nicht'; Mp = 'fest'; Fail = '*1.29.380*'; Want = @('fest', 'Microsoft.WinGet.Client'); Note = $true }
    )
    It 'Worker (Lesen, Windows PowerShell): <Fall>' -TestCases $wcases {
        param($Fall, $Mp, $Fail, $Want, $Note)
        $d = Join-Path $TestDrive ('w_' + [guid]::NewGuid().ToString('N').Substring(0, 6)); New-Item -ItemType Directory -Path $d -Force | Out-Null
        $mp = switch ($Mp) { 'fest' { $script:Psd } 'fehlt' { Join-Path $TestDrive 'nicht\da.psd1' } default { '' } }
        @{ Mode = 'List'; Sources = @(); IncludeUnknown = $false; ModulePath = $mp } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $d 'request.json') -Encoding UTF8
        $env:T_IMPORTFAIL = $Fail
        $q = "'" + ((Join-Path $script:Root 'Functions\AppUpdates-Worker.ps1') -replace "'", "''") + "'"
        $o = & $script:RunScript $script:WinPs ($script:Pre + "`r`n& $q -Dir '$($d -replace "'", "''")'")
        $exp = @($Want | ForEach-Object { if ($_ -eq 'fest') { "C|Import|$script:Psd" } else { "C|Import|$_" } })
        @($o | Where-Object { $_ -like 'C|Import|*' }) | Should -Be $exp
        $r = Get-Content -LiteralPath (Join-Path $d 'result.json') -Raw | ConvertFrom-Json
        @($r.Errors).Count | Should -Be 0
        (@($r.Notes).Count -gt 0) | Should -Be $Note
    }
    It 'Zeitplan-Skript (PowerShell 7, ohne HUMig): <Fall>' -TestCases $wcases -Skip:(-not (Get-Command pwsh.exe -ErrorAction SilentlyContinue)) {
        param($Fall, $Mp, $Fail, $Want, $Note)
        $d = Join-Path $TestDrive ('a_' + [guid]::NewGuid().ToString('N').Substring(0, 6)); New-Item -ItemType Directory -Path $d -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:Root 'Functions\AppUpdates-Auto.ps1') -Destination (Join-Path $d 'auto.ps1')
        $cfg = [ordered]@{ Sources = @('winget'); Exclude = @(); Location = ''; Created = '2026-11-26 03:00'; By = 'Test' }
        $mp = switch ($Mp) { 'fest' { $script:Psd } 'fehlt' { Join-Path $TestDrive 'nicht\da.psd1' } default { '' } }
        if ($Mp) { $cfg.ModulePath = $mp }   # aeltere config.json hat das Feld gar nicht
        $cfg | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $d 'config.json') -Encoding UTF8
        $env:T_IMPORTFAIL = $Fail
        $pf = Join-Path $d 'PF'; New-Item -ItemType Directory -Path $pf -Force | Out-Null
        $o = & $script:RunScript $script:Pwsh.Source ($script:Pre + "`r`n`$env:ProgramFiles = '$($pf -replace "'", "''")'`r`n& '$((Join-Path $d 'auto.ps1') -replace "'", "''")'")
        $exp = @($Want | ForEach-Object { if ($_ -eq 'fest') { "C|Import|$script:Psd" } else { "C|Import|$_" } })
        @($o | Where-Object { $_ -like 'C|Import|*' }) | Should -Be $exp
        $log = Get-Content -LiteralPath (Join-Path $d 'log.txt') -Raw
        $log | Should -Match 'winget\.exe nicht gefunden'   # lief nach dem Laden weiter bis zum naechsten Schritt
        if ($Mp -eq 'fehlt') { $log | Should -Match 'fehlt - die vorhandene Version wird verwendet' }
        if ($Note) { $log | Should -Match 'nicht ladbar .* die vorhandene Version wird verwendet' }
    }
}

Describe 'WinGet-Modul: Einrichten auf diesem PC (Engine) nur in der festen Version' {
    BeforeAll {
        . (Join-Path $script:Root 'Functions\AppUpdates-Engine.ps1')
        $script:PF0 = $env:ProgramFiles
        $script:Pub = ', O=Microsoft Corporation, L=Redmond, S=Washington, C=US'
    }
    AfterEach { $env:ProgramFiles = $script:PF0 }
    BeforeEach {
        $pf = Join-Path $TestDrive ('e_' + [guid]::NewGuid().ToString('N').Substring(0, 6)); $env:ProgramFiles = $pf
        $script:Root2 = Join-Path $pf 'WindowsPowerShell\Modules\Microsoft.WinGet.Client'
        $script:Lines = New-Object System.Collections.Generic.List[string]
        $script:Job = [pscustomobject]@{ Log = New-Object System.Collections.Concurrent.ConcurrentQueue[object]; Result = $null; Cancel = $false }
        $script:Scr = @()
        Mock Get-AppxPackage { @([pscustomobject]@{ Version = '1.0' }) }
        Mock Add-AppxPackage { }
        Mock Get-PackageProvider { @([pscustomobject]@{ Version = [version]'2.8.5.201' }) }
        Mock Install-PackageProvider { }
        Mock Find-Module { throw 'darf nicht aufgerufen werden' }
        Mock Get-HMAuModuleSigFiles { @(@{ Path = (Join-Path $Dir 'Microsoft.WinGet.Client.psd1'); Status = 'Valid'; Subject = "CN=Microsoft Corporation$script:Pub" }) }
        Mock Invoke-HMAuIsolated { $script:Scr += $Script; [pscustomobject]@{ Ok = $true; Crashed = $false; Cancelled = $false; TimedOut = $false; Error = '' } }
        Mock Get-HMAuTools { @{ Ok = $true; Errors = @(); Pwsh = $null; WinGet = @{ Version = '1.29.380'; Name = 'Microsoft.WinGet.Client'; Herausgeber = $script:Pub } } }
        $script:AddVer = { param($v) $d = Join-Path $script:Root2 $v; New-Item -ItemType Directory -Path $d -Force | Out-Null; [IO.File]::WriteAllText((Join-Path $d 'Microsoft.WinGet.Client.psd1'), '@{}') }
        $script:Logs = { @($script:Job.Log.ToArray() | ForEach-Object { "$($_.Lvl)|$($_.Msg)" }) }
    }
    It 'feste Version fehlt, kein Modul da: Install-Module mit -RequiredVersion, danach wird genau sie geladen' {
        Mock Get-Module { @() }
        Mock Install-Module { & $script:AddVer $RequiredVersion }
        Install-HMAuWinGet $script:Job | Should -BeTrue
        Should -Invoke Install-Module -Times 1 -Exactly -ParameterFilter { $RequiredVersion -eq '1.29.380' -and $Name -eq 'Microsoft.WinGet.Client' -and $Scope -eq 'AllUsers' }
        Should -Invoke Find-Module -Times 0
        $script:Scr[0] | Should -Match ([regex]::Escape("Import-Module '$(Join-Path $script:Root2 '1.29.380\Microsoft.WinGet.Client.psd1')' -Force"))
    }
    It 'feste Version schon da: kein Install-Module, keine Pruefung auf neuere Versionen' {
        & $script:AddVer '1.29.380'
        Mock Get-Module { @([pscustomobject]@{ Version = [version]'1.29.380'; ModuleBase = (Join-Path $script:Root2 '1.29.380') }) }
        Mock Install-Module { }
        Install-HMAuWinGet $script:Job | Should -BeTrue
        Should -Invoke Install-Module -Times 0
        Should -Invoke Find-Module -Times 0
    }
    It 'andere Version da, feste nicht installierbar: Warnung, die vorhandene wird geladen, Einrichten laeuft weiter' {
        & $script:AddVer '1.9.2411'
        Mock Get-Module { @([pscustomobject]@{ Version = [version]'1.9.2411'; ModuleBase = (Join-Path $script:Root2 '1.9.2411') }) }
        Mock Install-Module { throw 'kein Netz (Ersatz)' }
        Install-HMAuWinGet $script:Job | Should -BeTrue
        (& $script:Logs) -join "`n" | Should -Match 'Warning\|Modul 1\.29\.380 nicht installierbar \(kein Netz \(Ersatz\)\) - vorhandenes Modul 1\.9\.2411 wird verwendet'
        $script:Scr[0] | Should -Match ([regex]::Escape("Import-Module '$(Join-Path $script:Root2 '1.9.2411\Microsoft.WinGet.Client.psd1')' -Force"))
    }
    It 'kein Modul und kein Netz: Fehler wie bisher, nichts geladen' {
        Mock Get-Module { @() }
        Mock Install-Module { throw 'kein Netz (Ersatz)' }
        Install-HMAuWinGet $script:Job | Should -BeFalse
        (& $script:Logs) -join "`n" | Should -Match 'Error\|Modul nicht installierbar: kein Netz'
        Should -Invoke Invoke-HMAuIsolated -Times 0
    }
    It 'Status pruefen laedt die feste Version ueber den Pfad' {
        & $script:AddVer '1.29.380'
        Mock Get-Module { @([pscustomobject]@{ Version = [version]'1.29.380'; ModuleBase = (Join-Path $script:Root2 '1.29.380') }) }
        Mock Test-HMAuOsSupported { $true }
        Mock Test-HMAuOsExperimental { $false }
        Mock Invoke-HMAuIsolated { $script:Scr += $Script; [pscustomobject]@{ Ok = $true; Result = '1.12.0'; Crashed = $false; TimedOut = $false; Error = '' } }
        $s = Get-HMAuState
        $s.Ready | Should -BeTrue
        $script:Scr[0] | Should -Match ([regex]::Escape("Import-Module '$(Join-Path $script:Root2 '1.29.380\Microsoft.WinGet.Client.psd1')';"))
    }
    It 'lokale Hilfsaufgabe (Quellen als SYSTEM) bekommt den Ladepfad in request.json' {
        & $script:AddVer '1.29.380'
        $pd = Join-Path $TestDrive ('pd_' + [guid]::NewGuid().ToString('N').Substring(0, 6)); $pd0 = $env:ProgramData; $env:ProgramData = $pd
        try {
            Mock Protect-HMDataDir { }
            # beim Schreiben von request.json abbrechen: keine Aufgabe wird angelegt
            $script:Rq = ''
            Mock Set-Content { $script:Rq = "$Value"; throw 'Ende des Tests' } -ParameterFilter { "$LiteralPath" -like '*request.json' }
            { Start-HMAuTask 'SYSTEM' '' @{ Mode = 'SourceRemove'; Name = 'x' } } | Should -Throw 'Ende des Tests'
            ($script:Rq | ConvertFrom-Json).ModulePath | Should -Be (Join-Path $script:Root2 '1.29.380\Microsoft.WinGet.Client.psd1')
            ($script:Rq | ConvertFrom-Json).Mode | Should -Be 'SourceRemove'
        } finally { $env:ProgramData = $pd0 }
    }
}

Describe 'USMT-Version: Einstellungen, Manifest, Backup- und Restore-Bericht' {
    BeforeAll {
        . (Join-Path $script:Root 'Functions\Migration-Engine.ps1')
        # Text unter dem USMT-Ordner (UI-Settings.ps1) einzeln laden
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Root 'Functions\UI-Settings.ps1'), [ref]$null, [ref]$null)
        $fn = @($ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'Get-HMUsmtLabel' }, $true))[0]
        . ([scriptblock]::Create($fn.Extent.Text))
        $script:AppRoot = $TestDrive
        # Ausdruck der Fakten des Backup-Berichts (aus Migration-Engine.ps1) zum Auswerten mit eigenen Werten
        $me = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Root 'Functions\Migration-Engine.ps1'), [ref]$null, [ref]$null)
        $script:BackupFacts = @($me.FindAll({ param($x) $x -is [System.Management.Automation.Language.AssignmentStatementAst] -and "$($x.Left)" -eq '$facts' -and $x.Extent.Text -match "'Computer \(Quelle\)'" }, $true))[0].Extent.Text
        $script:RestoreUsmt = @($me.FindAll({ param($x) $x -is [System.Management.Automation.Language.IfStatementAst] -and $x.Extent.Text -like 'if ($Ctx.UsmtVersion)*' }, $true))[0].Extent.Text
    }
    It 'Version aus der Datei lesen, nicht lesbar ergibt leer' {
        Mock Get-Item { [pscustomobject]@{ VersionInfo = [pscustomobject]@{ ProductVersion = ' 10.0.26100.1 (WinBuild.160101.0800) ' } } } -ParameterFilter { "$LiteralPath" -like '*scanstate.exe' }
        Get-HMUsmtVersion 'C:\USMT\amd64' | Should -Be '10.0.26100.1 (WinBuild.160101.0800)'
        Get-HMUsmtVersion (Join-Path $TestDrive 'fehlt') 'loadstate.exe' | Should -Be ''
    }
    It 'Einstellungen: Text unter dem USMT-Ordner nennt die Version, ohne lesbare Version wie bisher' {
        Mock Find-HMUsmt { 'C:\USMT\amd64' }
        Mock Get-HMUsmtVersion { '10.0.26100.1' }
        Get-HMUsmtLabel '' | Should -Be 'gefunden: C:\USMT\amd64 (Version 10.0.26100.1)'
        Mock Get-HMUsmtVersion { '' }
        Get-HMUsmtLabel '' | Should -Be 'gefunden: C:\USMT\amd64'
        Mock Find-HMUsmt { $null }
        Get-HMUsmtLabel '' | Should -Match '^USMT nicht gefunden'
    }
    It 'Backup: die Version kommt ins Manifest (UsmtVersion), ScanState-Aufruf bleibt dahinter' {
        Mock Find-HMUsmt { 'C:\USMT\amd64' }
        Mock Get-HMUsmtVersion { '10.0.26100.1' } -ParameterFilter { $Exe -eq 'scanstate.exe' }
        Mock Write-HMLog { throw 'Halt nach der Versionszeile' } -ParameterFilter { $Msg -like '*USMT: C:\USMT\amd64 (Version 10.0.26100.1)*' }
        $ctx = @{ Account = 'PC\anna'; ToolRoot = $TestDrive; BackupPath = (Join-Path $TestDrive 'B1'); Manifest = [ordered]@{ Status = '' }; IsRemote = $false }
        { Backup-HMUsmt -Ctx $ctx -Job $null -Module ([pscustomobject]@{ Id = 'Usmt' }) } | Should -Throw 'Halt nach der Versionszeile'
        $ctx.Manifest.UsmtVersion | Should -Be '10.0.26100.1'
    }
    It 'Backup-Bericht: Zeile "USMT" mit Version, ohne Version keine Zeile (leere Fakten zeigt der Bericht nicht)' {
        $allBytes = 0; $verify = $null; $Ctx = @{ BackupPath = 'X' }
        $m = @{ UsmtVersion = '10.0.26100.1'; SyncRoots = @(); Catalog = $null }
        . ([scriptblock]::Create($script:BackupFacts))
        $facts['USMT'] | Should -Be 'Version 10.0.26100.1'
        $m = @{ SyncRoots = @(); Catalog = $null }
        . ([scriptblock]::Create($script:BackupFacts))
        "$($facts['USMT'])" | Should -Be ''
    }
    It 'Restore: Version von loadstate.exe, Zeile "USMT" im Bericht' {
        Mock Find-HMUsmt { 'C:\USMT\amd64' }
        Mock Get-HMUsmtVersion { '10.0.26100.2' } -ParameterFilter { $Exe -eq 'loadstate.exe' }
        Mock Write-HMLog { throw 'Halt vor LoadState' } -ParameterFilter { $Msg -like 'Windows-Einstellungen (USMT LoadState)*' }
        $st = Join-Path $TestDrive 'B2\Usmt\STORE'; New-Item -ItemType Directory -Path $st -Force | Out-Null; [IO.File]::WriteAllText((Join-Path $st 'USMT.MIG'), 'x')
        $ctx = @{ Account = 'PC\anna'; ToolRoot = $TestDrive; Backup = @{ Path = (Join-Path $TestDrive 'B2'); Legacy = $false; Account = 'PC\anna' }; IsRemote = $false }
        { Restore-HMUsmt -Ctx $ctx -Job $null } | Should -Throw 'Halt vor LoadState'
        $ctx.UsmtVersion | Should -Be '10.0.26100.2'
        $Ctx = $ctx; $facts = [ordered]@{}
        . ([scriptblock]::Create($script:RestoreUsmt))
        $facts['USMT'] | Should -Be 'Version 10.0.26100.2'
        $Ctx = @{}; $facts = [ordered]@{}
        . ([scriptblock]::Create($script:RestoreUsmt))
        $facts.Contains('USMT') | Should -BeFalse
    }
}

Describe 'Waechter: Liste der fremden Werkzeuge und Aufruf' {
    BeforeAll {
        $script:W = Get-Content -LiteralPath (Join-Path $script:Root '.github\waechter.json') -Raw | ConvertFrom-Json
        $script:T = Get-Content -LiteralPath (Join-Path $script:Root 'Config\tools.json') -Raw | ConvertFrom-Json
        $script:Y = [IO.File]::ReadAllText((Join-Path $script:Root '.github\workflows\waechter.yml'))
    }
    It 'jede Datei aus Config\tools.json hat einen Eintrag im Waechter (Versionen kommen aus tools.json)' {
        $script:W.werkzeugpaket | Should -Be 'Config/tools.json'
        foreach ($d in @($script:T.dateien)) { @($script:W.eintraege | Where-Object { $_.id -eq $d.id }).Count | Should -Be 1 -Because $d.id }
        foreach ($e in @($script:W.eintraege)) { $e.neueste.art | Should -BeIn @('github', 'githubCommit', 'pypi', 'nuget', 'npm', 'endoflife') }
    }
    It 'PowerShell 7 wird auf dem Zweig der festen Version beobachtet (LTS)' {
        $ps = @($script:W.eintraege | Where-Object { $_.id -eq 'powershell7' })[0]
        $v = @($script:T.dateien | Where-Object { $_.id -eq 'powershell7' })[0].version
        $ps.neueste.zweig | Should -Be (($v -split '\.')[0..1] -join '.')
    }
    It 'Aufruf des Waechters: nur lesen und Issues schreiben, kein Commit, keine Schreibrechte am Repository' {
        $script:Y | Should -Match '(?m)^\s+contents:\s*read\s*$'
        $script:Y | Should -Match '(?m)^\s+issues:\s*write\s*$'
        $script:Y | Should -Not -Match 'contents:\s*write'
        $script:Y | Should -Match 'uses: ChiliApple/HU-Amt/\.github/workflows/waechter\.yml@main'
    }
}

Describe 'WinGet-Modul gesperrt (ungueltige Signatur, keine andere Version): nie nach Namen laden' {
    BeforeAll {
        . (Join-Path $script:Root 'Functions\AppUpdates-Engine.ps1')
        $script:WinPs = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $script:PF0 = $env:ProgramFiles
        $script:Pub = ', O=Microsoft Corporation, L=Redmond, S=Washington, C=US'
    }
    AfterEach { $env:ProgramFiles = $script:PF0 }
    It 'Worker: Auftrag mit Sperre laedt kein Modul und meldet den Fehler wie ohne Modul' -Skip:([Environment]::OSVersion.Platform -ne 'Win32NT') {
        $d = Join-Path $TestDrive ('wb_' + [guid]::NewGuid().ToString('N').Substring(0, 6)); New-Item -ItemType Directory -Path $d -Force | Out-Null
        @{ Mode = 'List'; Sources = @(); IncludeUnknown = $false; ModulePath = ''; ModuleBlocked = $true } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $d 'request.json') -Encoding UTF8
        $pre = "`$ErrorActionPreference = 'Stop'`r`nfunction global:Import-Module { param([Parameter(Position = 0)]`$Name, [switch]`$Force) [Console]::Out.WriteLine(`"C|Import|`$Name`") }`r`n"
        $f = Join-Path $TestDrive ("run_{0}.ps1" -f [guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($f, $pre + "& '$((Join-Path $script:Root 'Functions\AppUpdates-Worker.ps1') -replace "'", "''")' -Dir '$($d -replace "'", "''")'", (New-Object System.Text.UTF8Encoding($true)))
        $o = @(& $script:WinPs -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $f 2>&1 | ForEach-Object { "$_" })
        @($o | Where-Object { $_ -like 'C|Import|*' }).Count | Should -Be 0
        $r = Get-Content -LiteralPath (Join-Path $d 'result.json') -Raw | ConvertFrom-Json
        @($r.Errors) -join ' ' | Should -Match 'WinGet-Modul nicht nutzbar'
    }
    It 'Engine, WinGet einrichten: gesperrt -> Fehler, kein Laden im eigenen Prozess' {
        $pf = Join-Path $TestDrive ('eb_' + [guid]::NewGuid().ToString('N').Substring(0, 6)); $env:ProgramFiles = $pf
        $root = Join-Path $pf 'WindowsPowerShell\Modules\Microsoft.WinGet.Client\1.29.380'; New-Item -ItemType Directory -Path $root -Force | Out-Null; [IO.File]::WriteAllText((Join-Path $root 'Microsoft.WinGet.Client.psd1'), '@{}')
        $job = [pscustomobject]@{ Log = New-Object System.Collections.Concurrent.ConcurrentQueue[object]; Result = $null; Cancel = $false }
        Mock Get-AppxPackage { @([pscustomobject]@{ Version = '1.0' }) }
        Mock Get-Module { @([pscustomobject]@{ Version = [version]'1.29.380'; ModuleBase = $root }) }
        Mock Install-Module { }
        Mock Get-HMAuTools { @{ Ok = $true; Errors = @(); Pwsh = $null; WinGet = @{ Version = '1.29.380'; Name = 'Microsoft.WinGet.Client'; Herausgeber = $script:Pub } } }
        Mock Get-HMAuModuleSigFiles { @(@{ Path = (Join-Path $Dir 'Microsoft.WinGet.Client.psd1'); Status = 'HashMismatch'; Subject = "CN=Microsoft Corporation$script:Pub" }) }
        Mock Invoke-HMAuIsolated { [pscustomobject]@{ Ok = $true } }
        Install-HMAuWinGet $job | Should -BeFalse
        Should -Invoke Invoke-HMAuIsolated -Times 0
        @($job.Log.ToArray() | ForEach-Object { "$($_.Lvl)|$($_.Msg)" }) -join "`n" | Should -Match 'Error\|WinGet-Modul nicht nutzbar'
    }
    It 'Engine, Status: gesperrt -> nicht bereit mit Hinweis, kein Laden' {
        $pf = Join-Path $TestDrive ('es_' + [guid]::NewGuid().ToString('N').Substring(0, 6)); $env:ProgramFiles = $pf
        $root = Join-Path $pf 'WindowsPowerShell\Modules\Microsoft.WinGet.Client\1.29.380'; New-Item -ItemType Directory -Path $root -Force | Out-Null; [IO.File]::WriteAllText((Join-Path $root 'Microsoft.WinGet.Client.psd1'), '@{}')
        Mock Get-Module { @([pscustomobject]@{ Version = [version]'1.29.380'; ModuleBase = $root }) }
        Mock Get-AppxPackage { @() }
        Mock Test-HMAuOsSupported { $true }
        Mock Test-HMAuOsExperimental { $false }
        Mock Get-HMAuTools { @{ Ok = $true; Errors = @(); Pwsh = $null; WinGet = @{ Version = '1.29.380'; Name = 'Microsoft.WinGet.Client'; Herausgeber = $script:Pub } } }
        Mock Get-HMAuModuleSigFiles { @(@{ Path = (Join-Path $Dir 'Microsoft.WinGet.Client.psd1'); Status = 'NotSigned'; Subject = '' }) }
        Mock Invoke-HMAuIsolated { [pscustomobject]@{ Ok = $true; Result = '1.0' } }
        $s = Get-HMAuState
        $s.Ready | Should -BeFalse
        $s.Problem | Should -Match 'Signatur ungueltig.*eine andere Version ist nicht vorhanden'
        Should -Invoke Invoke-HMAuIsolated -Times 0
    }
}

Describe 'WinGet einrichten am Ziel-PC (Install-TWinGet): feste Modulversion vor der Reparatur, gesperrt keine Reparatur' {
    BeforeAll {
        Import-TargetFunction @('Test-TModule', 'Get-TModFixed', 'Test-TModuleSignature', 'Get-TModuleLoad', 'Resolve-TModuleLoad', 'Test-TWinGet', 'Test-TOsOk', 'Test-TOsExperimental', 'Install-TWinGet', 'Get-TModSigState', 'Get-TModOtherDir', 'Get-TModBlockedText')
        function global:Out-L([string]$t) { $global:T_Log += $t }
        function global:Get-TModuleSigFiles([string]$Dir) { @(@{ Path = (Join-Path $Dir 'Microsoft.WinGet.Client.psd1'); Status = $(if ($global:T_Bad) { 'HashMismatch' } else { 'Valid' }); Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US' }) }
        # Ersatz fuer den eigenen Prozess: merkt den Befehl, startet nichts
        function global:Invoke-TPsEncoded([string]$EncodedCommand) { $global:T_Cmd = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($EncodedCommand)); return @{ Out = ''; Code = 0 } }
        $script:PF0 = $env:ProgramFiles
        $script:Setup = {
            param([bool]$Bad = $false)
            $pf = Join-Path $TestDrive ('wg_' + [guid]::NewGuid().ToString('N').Substring(0, 6)); $env:ProgramFiles = $pf
            $global:ModName = 'Microsoft.WinGet.Client'; $global:ModRoot = Join-Path $pf 'WindowsPowerShell\Modules\Microsoft.WinGet.Client'
            $d = Join-Path $global:ModRoot '1.29.380'; New-Item -ItemType Directory -Path $d -Force | Out-Null; [IO.File]::WriteAllText((Join-Path $d 'Microsoft.WinGet.Client.psd1'), '@{}')
            $global:T_Bad = $Bad; $global:T_Cmd = $null; $global:T_Log = @(); $script:TErr = @(); $global:TErr = @(); $script:TModLoad = $null; $global:TModLoad = $null
            $global:TModSig = $null; $script:TModSig = $null
            $global:Payload = @{ Tools = @{ WinGet = @{ Version = '1.29.380'; Name = 'Microsoft.WinGet.Client'; Herausgeber = ', O=Microsoft Corporation, L=Redmond, S=Washington, C=US' } } }
        }
    }
    AfterAll {
        $env:ProgramFiles = $script:PF0
        foreach ($n in @('Out-L', 'Get-TModuleSigFiles', 'Invoke-TPsEncoded', 'Test-TModule', 'Get-TModFixed', 'Test-TModuleSignature', 'Get-TModuleLoad', 'Resolve-TModuleLoad', 'Test-TWinGet', 'Test-TOsOk', 'Test-TOsExperimental', 'Install-TWinGet', 'Get-TModSigState', 'Get-TModOtherDir', 'Get-TModBlockedText')) { Remove-Item "Function:\global:$n" -ErrorAction SilentlyContinue }
    }
    AfterEach { $env:ProgramFiles = $script:PF0 }
    It 'WinGet fehlt: der eigene Prozess laedt die feste Modulversion ueber ihren Pfad und repariert' -Skip:([Environment]::OSVersion.Version.Build -lt 17763) {
        & $script:Setup
        Install-TWinGet
        $global:T_Cmd | Should -Match ([regex]::Escape("Import-Module '$(Join-Path $global:ModRoot '1.29.380\Microsoft.WinGet.Client.psd1')'"))
        $global:T_Cmd | Should -Match 'Repair-WinGetPackageManager -AllUsers -Latest -Force'
    }
    It 'WinGet fehlt, Modul gesperrt: keine Reparatur, Fehler wie ohne Modul' -Skip:([Environment]::OSVersion.Version.Build -lt 17763) {
        & $script:Setup $true
        Install-TWinGet
        $global:T_Cmd | Should -BeNullOrEmpty
        (@(@($script:TErr) + @($global:TErr) | Where-Object { $_ }) -join ' ') | Should -Match 'WinGet-Modul nicht nutzbar: die feste Version 1\.29\.380 in .*Abhilfe'
    }
}

Describe 'Nachbesserung: Engine pruefbar/nicht pruefbar, einmal je Lauf, Hinweise weitergeben, Form von tools.json' {
    BeforeAll {
        . (Join-Path $script:Root 'Functions\AppUpdates-Engine.ps1')
        $script:PF0 = $env:ProgramFiles
        $script:Pub = ', O=Microsoft Corporation, L=Redmond, S=Washington, C=US'
    }
    AfterEach { $env:ProgramFiles = $script:PF0 }
    BeforeEach {
        $pf = Join-Path $TestDrive ('n_' + [guid]::NewGuid().ToString('N').Substring(0, 6)); $env:ProgramFiles = $pf
        $script:Fix = Join-Path $pf 'WindowsPowerShell\Modules\Microsoft.WinGet.Client\1.29.380'
        New-Item -ItemType Directory -Path $script:Fix -Force | Out-Null; [IO.File]::WriteAllText((Join-Path $script:Fix 'Microsoft.WinGet.Client.psd1'), '@{}')
        $script:Job = [pscustomobject]@{ Log = New-Object System.Collections.Concurrent.ConcurrentQueue[object]; Result = $null; Cancel = $false }
        $script:Scr = @()
        Mock Get-AppxPackage { @([pscustomobject]@{ Version = '1.0' }) }
        Mock Get-Module { @([pscustomobject]@{ Version = [version]'1.29.380'; ModuleBase = $script:Fix }) }
        Mock Install-Module { }
        Mock Find-Module { throw 'darf nicht aufgerufen werden' }
        Mock Get-HMAuTools { @{ Ok = $true; Errors = @(); Pwsh = $null; WinGet = @{ Version = '1.29.380'; Name = 'Microsoft.WinGet.Client'; Herausgeber = $script:Pub } } }
        Mock Invoke-HMAuIsolated { $script:Scr += $Script; [pscustomobject]@{ Ok = $true; Result = '1.0'; Crashed = $false; Cancelled = $false; TimedOut = $false; Error = '' } }
    }
    It 'Engine, Signatur nicht pruefbar (NotTrusted): WinGet einrichten laeuft mit der festen Version, Warnung, keine Neuinstallation' {
        Mock Get-HMAuModuleSigFiles { @(@{ Path = (Join-Path $Dir 'Microsoft.WinGet.Client.psd1'); Status = 'NotTrusted'; Subject = '' }) }
        Install-HMAuWinGet $script:Job | Should -BeTrue
        Should -Invoke Install-Module -Times 0
        $script:Scr[0] | Should -Match ([regex]::Escape("Import-Module '$(Join-Path $script:Fix 'Microsoft.WinGet.Client.psd1')' -Force"))
        @($script:Job.Log.ToArray() | ForEach-Object { "$($_.Lvl)|$($_.Msg)" }) -join "`n" | Should -Match 'Warning\|WinGet-Modul 1\.29\.380: Signatur nicht pruefbar'
    }
    It 'Engine, Signatur je Lauf nur einmal geprueft (WinGet einrichten)' {
        Mock Get-HMAuModuleSigFiles { @(@{ Path = (Join-Path $Dir 'Microsoft.WinGet.Client.psd1'); Status = 'Valid'; Subject = "CN=Microsoft Corporation$script:Pub" }) }
        Install-HMAuWinGet $script:Job | Should -BeTrue
        Should -Invoke Get-HMAuModuleSigFiles -Times 1 -Exactly
        Install-HMAuWinGet $script:Job | Should -BeTrue
        Should -Invoke Get-HMAuModuleSigFiles -Times 2 -Exactly   # neuer Lauf, neue Pruefung
    }
    It 'Engine, Selbstreparatur: eindeutig ungueltig, Neuinstallation macht sie gueltig, dann geladen' {
        $script:Bad = $true
        Mock Get-HMAuModuleSigFiles { @(@{ Path = (Join-Path $Dir 'Microsoft.WinGet.Client.psd1'); Status = $(if ($script:Bad) { 'HashMismatch' } else { 'Valid' }); Subject = "CN=Microsoft Corporation$script:Pub" }) }
        Mock Install-Module { $script:Bad = $false }
        Install-HMAuWinGet $script:Job | Should -BeTrue
        Should -Invoke Install-Module -Times 1 -Exactly -ParameterFilter { $RequiredVersion -eq '1.29.380' }
        $script:Scr[0] | Should -Match ([regex]::Escape("Import-Module '$(Join-Path $script:Fix 'Microsoft.WinGet.Client.psd1')' -Force"))
    }
    It 'Engine, Selbstreparatur ohne Erfolg und keine andere Version: Fehler mit Ordner und Abhilfe, nichts geloescht' {
        Mock Get-HMAuModuleSigFiles { @(@{ Path = (Join-Path $Dir 'Microsoft.WinGet.Client.psd1'); Status = 'HashMismatch'; Subject = '' }) }
        Install-HMAuWinGet $script:Job | Should -BeFalse
        $log = @($script:Job.Log.ToArray() | ForEach-Object { "$($_.Lvl)|$($_.Msg)" }) -join "`n"
        $log | Should -Match 'Error\|WinGet-Modul nicht nutzbar: auch nach einer Neuinstallation ungueltig'
        $log | Should -Match ([regex]::Escape("Abhilfe: den Ordner $script:Fix als Administrator loeschen"))
        Test-Path -LiteralPath (Join-Path $script:Fix 'Microsoft.WinGet.Client.psd1') | Should -BeTrue
    }
    It 'Hilfsaufgabe: Hinweis zur Modulwahl und Hinweise des Workers kommen im Ergebnis an (Notes)' {
        $d = Join-Path $TestDrive ('h_' + [guid]::NewGuid().ToString('N').Substring(0, 6)); New-Item -ItemType Directory -Path $d -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $d 'result.json'), '{"Items":[],"Errors":[],"Notes":["Hinweis des Workers"]}')
        Mock Unregister-ScheduledTask { }
        $r = Wait-HMAuTask ([pscustomobject]@{ Dir = $d; TaskName = 'x'; Account = 'SYSTEM'; Note = 'Hinweis zur Modulwahl' }) 10
        @($r.Notes) | Should -Be @('Hinweis zur Modulwahl', 'Hinweis des Workers')
        $d2 = Join-Path $TestDrive ('h2_' + [guid]::NewGuid().ToString('N').Substring(0, 6)); New-Item -ItemType Directory -Path $d2 -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $d2 'result.json'), '{"Items":[],"Errors":[]}')
        $r2 = Wait-HMAuTask ([pscustomobject]@{ Dir = $d2; TaskName = 'x'; Account = 'SYSTEM'; Note = '' }) 10
        @($r2.Notes).Count | Should -Be 0
    }
    It 'Form der festen Angaben in Config\tools.json: SHA256 mit 64 Hex-Zeichen je Architektur, Adresse mit der Versionsnummer, nie latest' {
        $raw = [IO.File]::ReadAllText((Join-Path $script:Root 'Config\tools.json'))
        $raw | Should -Not -Match '(?i)latest'
        $j = $raw | ConvertFrom-Json
        $ps = @($j.dateien | Where-Object { $_.id -eq 'powershell7' })[0]
        foreach ($a in @('x64', 'arm64')) {
            $ps.pakete.$a.sha256 | Should -Match '^[0-9a-fA-F]{64}$' -Because $a
            $ps.pakete.$a.url | Should -Match ([regex]::Escape("/v$($ps.version)/")) -Because $a
            $ps.pakete.$a.url | Should -Match ([regex]::Escape("PowerShell-$($ps.version)-win-$a.zip") + '$') -Because $a
        }
        @($j.dateien | Where-Object { $_.id -eq 'winget-modul' })[0].version | Should -Match '^\d+\.\d+\.\d+$'
    }
}
