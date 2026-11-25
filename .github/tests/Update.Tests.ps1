#Requires -Version 5.1
# Pester-Tests (Pester 5) fuer die Update-Kette: Pull.ps1 (Dateiliste, Journal, Zurueckstellen, Sperre, Zurueckstufen),
# Start-Dateien und Release-Abgleich vor dem Signieren. Ohne Netz, nur Ersatzordner in $TestDrive.

BeforeAll {
    $script:Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    . (Join-Path $script:Root 'Functions\Core-Update.ps1')
    # Hilfsfunktionen aus Pull.ps1 laden (Pull.ps1 selbst startet sofort einen Update-Lauf und wird darum nicht ausgefuehrt)
    $tok = $null; $err = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Root 'Pull.ps1'), [ref]$tok, [ref]$err)
    $names = @('ConvertTo-HMPullRelPath', 'Get-HMPullFileList', 'Get-HMPullOrder', 'New-HMPullJournalText', 'Get-HMPullCommonDir',
        'Resolve-HMPullJournal', 'Restore-HMPullJournal', 'Undo-HMPullReplace', 'Enter-HMPullLock', 'Get-HMPullInstalledVersion', 'Test-HMPullDowngrade')
    $defs = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false) | Where-Object { $names -contains $_.Name })
    foreach ($d in $defs) { . ([scriptblock]::Create($d.Extent.Text)) }
    $script:PullFunctions = @($defs | ForEach-Object { $_.Name })
    function New-HMTestFile([string]$Path, [string]$Text) {
        $d = Split-Path $Path -Parent
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        [IO.File]::WriteAllText($Path, $Text)
    }
}

Describe 'Pull.ps1: Hilfsfunktionen vorhanden' {
    It 'alle Funktionen aus Pull.ps1 geladen' {
        @($script:PullFunctions).Count | Should -Be 11
    }
}

Describe 'Pull.ps1: Dateiliste aus der Pruefsummen-Datei' {
    It 'nur relative Pfade ohne Laufwerk und ohne ..' {
        ConvertTo-HMPullRelPath 'Functions/Core-Update.ps1' | Should -Be 'Functions/Core-Update.ps1'
        ConvertTo-HMPullRelPath 'Functions\Core-Update.ps1' | Should -Be 'Functions/Core-Update.ps1'
        ConvertTo-HMPullRelPath '../x.ps1' | Should -Be ''
        ConvertTo-HMPullRelPath 'a/../../x' | Should -Be ''
        ConvertTo-HMPullRelPath 'C:\Windows\x.ps1' | Should -Be ''
        ConvertTo-HMPullRelPath '/etc/x' | Should -Be ''
        ConvertTo-HMPullRelPath '\\server\share\x' | Should -Be ''
        ConvertTo-HMPullRelPath 'a//b' | Should -Be ''
        ConvertTo-HMPullRelPath './a' | Should -Be ''
        ConvertTo-HMPullRelPath '' | Should -Be ''
    }
    It 'Liste sortiert, Pull.ps1 am Ende, .github ausgelassen' {
        $h = 'a' * 64
        $m = ConvertFrom-HMManifest ("# HUMig-Release v9.0.1`n$h  Pull.ps1`n$h  HUMig.ps1`n$h  Functions/B.ps1`n$h  .github/x.yml`n$h  Docs/a b.html`n")
        $r = Get-HMPullFileList $m
        @($r.Bad).Count | Should -Be 0
        @($r.Files)[-1] | Should -Be 'Pull.ps1'
        @($r.Files) | Should -Not -Contain '.github/x.yml'
        @($r.Files) | Should -Contain 'Docs/a b.html'
        @($r.Files).Count | Should -Be 4
    }
    It 'unzulaessige Eintraege werden gemeldet (nicht installiert)' {
        $h = 'b' * 64
        $m = ConvertFrom-HMManifest ("$h  HUMig.ps1`n$h  ../boese.ps1`n$h  Functions\Rueck.ps1`n$h  C:/x.ps1`n")
        $r = Get-HMPullFileList $m
        @($r.Bad) | Should -Contain '../boese.ps1'
        @($r.Bad) | Should -Contain 'Functions\Rueck.ps1'
        @($r.Bad) | Should -Contain 'C:/x.ps1'
        @($r.Files) | Should -Be @('HUMig.ps1')
    }
    It 'Git-Baum-Reihenfolge (ohne Pruefsummen-Datei): Pull.ps1 ebenfalls am Ende' {
        @(Get-HMPullOrder @('A.ps1', 'Pull.ps1', 'Z.ps1')) | Should -Be @('A.ps1', 'Z.ps1', 'Pull.ps1')
    }
}

Describe 'Pull.ps1: Journal' {
    It 'neues Journal: erster Eintrag ist der Programmordner, danach volle Pfade' {
        $t = Join-Path $TestDrive 'HUMig'
        $j = @(New-HMPullJournalText $t @("$t\HUMig.ps1", "$t\Functions\A.ps1") | ConvertFrom-Json)
        $j = @($j | ForEach-Object { $_ })
        $j[0] | Should -Be "$t\"
        $j[1] | Should -Be "$t\HUMig.ps1"
        $j.Count | Should -Be 3
    }
    It 'gleicher Ordner: Pfade bleiben gleich' {
        $t = Join-Path $TestDrive 'HUMig'
        $e = @(New-HMPullJournalText $t @("$t\HUMig.ps1", "$t\Functions\A.ps1") | ConvertFrom-Json) | ForEach-Object { $_ }
        $r = Resolve-HMPullJournal $e $t
        @($r.Paths) | Should -Be @("$t\HUMig.ps1", "$t\Functions\A.ps1")
        @($r.Bad).Count | Should -Be 0
    }
    It 'anderer Laufwerksbuchstabe (neues Journal): Pfade folgen dem Programmordner' {
        $r = Resolve-HMPullJournal @('E:\Tools\HUMig\', 'E:\Tools\HUMig\HUMig.ps1', 'E:\Tools\HUMig\Functions\A.ps1') 'F:\Tools\HUMig'
        @($r.Paths) | Should -Be @('F:\Tools\HUMig\HUMig.ps1', 'F:\Tools\HUMig\Functions\A.ps1')
    }
    It 'altes Journal (nur volle Pfade) im selben Ordner und nach Laufwerkswechsel' {
        $r = Resolve-HMPullJournal @('C:\X\HUMig\HUMig.ps1', 'C:\X\HUMig\Functions\Core-Update.ps1') 'C:\X\HUMig'
        @($r.Paths) | Should -Be @('C:\X\HUMig\HUMig.ps1', 'C:\X\HUMig\Functions\Core-Update.ps1')
        $r = Resolve-HMPullJournal @('E:\HUMig\HUMig.ps1', 'E:\HUMig\Functions\Core-Update.ps1', 'E:\HUMig\Docs\Sub\a.html') 'F:\HUMig'
        @($r.Paths) | Should -Be @('F:\HUMig\HUMig.ps1', 'F:\HUMig\Functions\Core-Update.ps1', 'F:\HUMig\Docs\Sub\a.html')
    }
    It 'relative Eintraege werden auf den Programmordner bezogen, Ausbrueche abgelehnt' {
        $r = Resolve-HMPullJournal @('HUMig.ps1', 'Functions/A.ps1', '..\boese.ps1', 'Functions\..\..\x') 'D:\HUMig'
        @($r.Paths) | Should -Be @('D:\HUMig\HUMig.ps1', 'D:\HUMig\Functions\A.ps1')
        @($r.Bad).Count | Should -Be 2
    }
    It 'Eintrag ausserhalb des Ordner-Eintrags wird nicht angefasst' {
        $r = Resolve-HMPullJournal @('D:\HUMig\', 'D:\HUMig\HUMig.ps1', 'C:\Windows\System32\x.dll') 'D:\HUMig'
        @($r.Paths) | Should -Be @('D:\HUMig\HUMig.ps1')
        @($r.Bad) | Should -Be @('C:\Windows\System32\x.dll')
    }
    It 'alte Leselogik (Pull.ps1 bis 2.1.21) stellt mit dem neuen Journal richtig zurueck und stoert sich nicht am Ordner-Eintrag' {
        $t = Join-Path $TestDrive 'AltLeser'
        New-HMTestFile "$t\HUMig.ps1.pullold" 'alt'; New-HMTestFile "$t\HUMig.ps1" 'neu'
        New-HMTestFile "$t\Functions\A.ps1.pullold" 'altA'
        New-HMTestFile "$t\Functions\A.ps1.pulltmp" 'tmp'
        $jl = New-HMPullJournalText $t @("$t\HUMig.ps1", "$t\Functions\A.ps1") | ConvertFrom-Json
        # Kopie der Schleife aus Pull.ps1 2.1.18 bis 2.1.21 (unveraendert)
        $jbad = 0
        foreach ($jp in @($jl)) {
            if (-not "$jp") { continue }
            $jo = "$jp.pullold"
            if (Test-Path -LiteralPath $jo) {
                try { Move-Item -LiteralPath $jo -Destination "$jp" -Force -ErrorAction Stop }
                catch { $jbad++ }
            }
            Remove-Item -LiteralPath "$jp.pulltmp" -Force -ErrorAction SilentlyContinue
        }
        $jbad | Should -Be 0
        Get-Content -LiteralPath "$t\HUMig.ps1" -Raw | Should -Be 'alt'
        Get-Content -LiteralPath "$t\Functions\A.ps1" -Raw | Should -Be 'altA'
        Test-Path -LiteralPath "$t\Functions\A.ps1.pulltmp" | Should -BeFalse
        @(Get-ChildItem -LiteralPath $t -Recurse -Force -Filter '*.pullold').Count | Should -Be 0
    }
    It 'Zurueckstellen: Sicherungen zurueck, Zwischendateien weg, gesperrte Datei wird als Fehler gemeldet' {
        $t = Join-Path $TestDrive 'Restore'
        New-HMTestFile "$t\A.ps1.pullold" 'altA'; New-HMTestFile "$t\A.ps1" 'neuA'; New-HMTestFile "$t\A.ps1.pulltmp" 'x'
        New-HMTestFile "$t\B.ps1.pullold" 'altB'; New-HMTestFile "$t\B.ps1" 'neuB'
        New-HMTestFile "$t\C.ps1" 'neuC'   # neu hinzugekommen, keine Sicherung
        $lock = [IO.File]::Open("$t\B.ps1", 'Open', 'Read', 'None')
        try { $r = @(Restore-HMPullJournal @("$t\A.ps1", "$t\B.ps1", "$t\C.ps1")) } finally { $lock.Dispose() }
        $r.Count | Should -Be 2
        @($r | Where-Object { $_.Path -eq "$t\A.ps1" })[0].Ok | Should -BeTrue
        @($r | Where-Object { $_.Path -eq "$t\B.ps1" })[0].Ok | Should -BeFalse
        Get-Content -LiteralPath "$t\A.ps1" -Raw | Should -Be 'altA'
        Test-Path -LiteralPath "$t\A.ps1.pulltmp" | Should -BeFalse
        Test-Path -LiteralPath "$t\B.ps1.pullold" | Should -BeTrue
    }
}

Describe 'Pull.ps1: Ersetzen rueckgaengig machen (ehrliche Meldung)' {
    It 'alles zurueck: keine Restliste' {
        $t = Join-Path $TestDrive 'Undo1'
        New-HMTestFile "$t\A.ps1" 'neuA'; New-HMTestFile "$t\A.ps1.pullold" 'altA'; New-HMTestFile "$t\N.ps1" 'neu'
        $moved = New-Object System.Collections.Generic.List[object]
        $moved.Add(@("$t\A.ps1", "$t\A.ps1.pullold")); $moved.Add(@("$t\N.ps1", ''))
        @(Undo-HMPullReplace $moved).Count | Should -Be 0
        Get-Content -LiteralPath "$t\A.ps1" -Raw | Should -Be 'altA'
        Test-Path -LiteralPath "$t\N.ps1" | Should -BeFalse
    }
    It 'gesperrte Datei: wird mit Zustand gemeldet, die anderen trotzdem zurueckgestellt' {
        $t = Join-Path $TestDrive 'Undo2'
        New-HMTestFile "$t\A.ps1" 'neuA'; New-HMTestFile "$t\A.ps1.pullold" 'altA'
        New-HMTestFile "$t\B.ps1" 'neuB'; New-HMTestFile "$t\B.ps1.pullold" 'altB'
        $moved = New-Object System.Collections.Generic.List[object]
        $moved.Add(@("$t\A.ps1", "$t\A.ps1.pullold")); $moved.Add(@("$t\B.ps1", "$t\B.ps1.pullold"))
        $lock = [IO.File]::Open("$t\B.ps1", 'Open', 'Read', 'None')
        try { $r = @(Undo-HMPullReplace $moved) } finally { $lock.Dispose() }
        $r.Count | Should -Be 1
        $r[0].Path | Should -Be "$t\B.ps1"
        $r[0].Text | Should -Match 'B\.ps1\.pullold'
        Get-Content -LiteralPath "$t\A.ps1" -Raw | Should -Be 'altA'
    }
}

Describe 'Pull.ps1: Sperre gegen zwei gleichzeitige Laeufe' {
    It 'zweiter Lauf bekommt die Sperre nicht, nach dem Ende ist sie frei und die Datei weg' {
        $t = Join-Path $TestDrive 'Sperre'; New-Item -ItemType Directory -Path $t -Force | Out-Null
        $a = Enter-HMPullLock $t
        $a | Should -Not -BeNullOrEmpty
        try { Enter-HMPullLock $t | Should -BeNullOrEmpty } finally { $a.Dispose() }
        Test-Path -LiteralPath (Join-Path $t 'pull.lock') | Should -BeFalse
        $b = Enter-HMPullLock $t
        $b | Should -Not -BeNullOrEmpty
        $b.Dispose()
    }
    It 'Sperre gilt auch fuer einen anderen Prozess' {
        $t = Join-Path $TestDrive 'Sperre2'; New-Item -ItemType Directory -Path $t -Force | Out-Null
        $a = Enter-HMPullLock $t
        try {
            $f = Join-Path $t 'pull.lock'
            $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $o = & $ps -NoProfile -Command "try { [IO.File]::Open('$f', 'OpenOrCreate', 'ReadWrite', 'None').Dispose(); 'frei' } catch { 'besetzt' }"
            "$o".Trim() | Should -Be 'besetzt'
        } finally { $a.Dispose() }
    }
}

Describe 'Pull.ps1: kein stilles Zurueckstufen' {
    It 'installierte Version aus version.json, sonst installed.json' {
        $t = Join-Path $TestDrive 'Ver'
        New-HMTestFile "$t\Config\installed.json" '{ "Version": "2.1.19" }'
        "$(Get-HMPullInstalledVersion $t)" | Should -Be '2.1.19'
        New-HMTestFile "$t\Config\version.json" '{ "version": "2.1.20" }'
        "$(Get-HMPullInstalledVersion $t)" | Should -Be '2.1.20'
        New-HMTestFile "$t\Config\version.json" '{ "version": "kaputt" }'
        "$(Get-HMPullInstalledVersion $t)" | Should -Be '2.1.19'
        $u = Join-Path $TestDrive 'VerBranch'
        New-HMTestFile "$u\Config\installed.json" '{ "Version": "Branch main" }'
        Get-HMPullInstalledVersion $u | Should -BeNullOrEmpty
    }
    It 'aeltere Version ohne -Version: nachfragen; gleiche, neuere, ausdrueckliche oder unbekannte: nicht' {
        Test-HMPullDowngrade ([Version]'2.1.20') ([Version]'2.1.19') '' | Should -BeTrue
        Test-HMPullDowngrade ([Version]'2.1.20') ([Version]'2.1.19') '2.1.19' | Should -BeFalse
        Test-HMPullDowngrade ([Version]'2.1.20') ([Version]'2.1.20') '' | Should -BeFalse
        Test-HMPullDowngrade ([Version]'2.1.19') ([Version]'2.1.21') '' | Should -BeFalse
        Test-HMPullDowngrade $null ([Version]'2.1.19') '' | Should -BeFalse
    }
}

Describe 'Update-Bibliothek: Grenzversion der Versionszeile' {
    It 'Grenze ist einstellbar (Vorlage fuer andere Apps)' {
        $old = $script:HMManifestTagSince
        try {
            Test-HMManifestRelease 'abc' '2.0.120' | Should -BeNullOrEmpty
            Test-HMManifestRelease 'abc' '2.0.121' | Should -Match 'ohne Versionszeile'
            $script:HMManifestTagSince = '1.0.0'
            Test-HMManifestRelease 'abc' '1.0.0' | Should -Match 'Pflicht ab 1\.0\.0'
        } finally { $script:HMManifestTagSince = $old }
    }
}

Describe 'Start-Dateien: Ordner mit Klammer im Namen' {
    It 'kein Ordnerpfad (%~dp0) in einem Klammerblock' {
        foreach ($f in @('Start.cmd', 'Start-Benutzer.cmd')) {
            $t = Get-Content -LiteralPath (Join-Path $script:Root $f) -Raw
            $t | Should -Not -Match '(?m)\(\s*$'
            $t | Should -Not -Match "'%~dp0"
        }
    }
    It 'laufen in "Test (1)" ohne Syntaxfehler bis zur Meldung "nicht gefunden"' {
        $d = Join-Path $TestDrive 'Test (1)'; New-Item -ItemType Directory -Path $d -Force | Out-Null
        foreach ($f in @('Start.cmd', 'Start-Benutzer.cmd')) {
            Copy-Item -LiteralPath (Join-Path $script:Root $f) -Destination $d
            $o = cmd.exe /c "echo.| `"$(Join-Path $d $f)`"" 2>&1
            $LASTEXITCODE | Should -Be 1
            "$o" | Should -Match 'nicht gefunden'
        }
    }
}

Describe 'Signieren: Abgleich mit dem lokalen Stand (UP-01)' {
    BeforeAll {
        function New-HMSha([byte[]]$B) { $s = [System.Security.Cryptography.SHA256]::Create(); try { -join ($s.ComputeHash($B) | ForEach-Object { $_.ToString('x2') }) } finally { $s.Dispose() } }
        $script:L = Join-Path $TestDrive 'Lokal'
        New-HMTestFile "$script:L\Config\version.json" '{ "version": "9.0.1" }'
        New-HMTestFile "$script:L\HUMig.ps1" "Zeile1`r`nZeile2`r`n"          # lokal CRLF, im Repo LF
        New-HMTestFile "$script:L\Functions\B.ps1" 'B'
        New-HMTestFile "$script:L\BACKUPS\x\eigen.ps1" 'eigene Daten'       # ausserhalb der Programmordner: zaehlt nicht
        $script:Man = "# HUMig-Release v9.0.1`n" +
            (New-HMSha ([Text.Encoding]::UTF8.GetBytes("Zeile1`nZeile2`n"))) + "  HUMig.ps1`n" +
            (New-HMSha ([Text.Encoding]::UTF8.GetBytes('B'))) + "  Functions/B.ps1`n" +
            (New-HMSha ([Text.Encoding]::UTF8.GetBytes('{ "version": "9.0.1" }'))) + "  Config/version.json`n"
    }
    It 'gleicher Stand (nur Zeilenenden anders): gleich' {
        $r = Compare-HMReleaseManifest $script:Man '9.0.1' $script:L
        $r.State | Should -Be 'gleich'
        @($r.Diff).Count | Should -Be 0
    }
    It 'andere Version lokal oder kein Ordner: nicht abgleichbar' {
        (Compare-HMReleaseManifest $script:Man '9.0.2' $script:L).State | Should -Be 'nicht abgleichbar'
        (Compare-HMReleaseManifest $script:Man '9.0.1' (Join-Path $TestDrive 'fehlt')).State | Should -Be 'nicht abgleichbar'
        (Compare-HMReleaseManifest $script:Man '9.0.1' '').State | Should -Be 'nicht abgleichbar'
    }
    It 'anderer Inhalt, fehlende Datei, lokale Programmdatei ohne Eintrag: abweichend mit Liste' {
        $m2 = $script:Man -replace '  Functions/B\.ps1', '  Functions/B-alt.ps1'
        New-HMTestFile "$script:L\Functions\Extra.ps1" 'x'
        try {
            $r = Compare-HMReleaseManifest ($m2 + ('0' * 64) + "  XAML/Neu.xaml`n") '9.0.1' $script:L
            $r.State | Should -Be 'abweichend'
            @($r.Diff) | Should -Contain 'Functions/B-alt.ps1: fehlt lokal'
            @($r.Diff) | Should -Contain 'XAML/Neu.xaml: fehlt lokal'
            @($r.Diff) | Should -Contain 'Functions/Extra.ps1: lokal vorhanden, fehlt in der Pruefsummen-Datei'
            @($r.Diff) | Should -Contain 'Functions/B.ps1: lokal vorhanden, fehlt in der Pruefsummen-Datei'
            @($r.Diff | Where-Object { $_ -like 'BACKUPS*' }).Count | Should -Be 0
            $r.Text | Should -Not -Match 'Schreibrecht'   # dieses Wort loescht in HUMig den gespeicherten Schreib-Token
        } finally { Remove-Item -LiteralPath "$script:L\Functions\Extra.ps1" -Force }
        New-HMTestFile "$script:L\Functions\B.ps1" 'B geaendert'
        try { (Compare-HMReleaseManifest $script:Man '9.0.1' $script:L).Diff | Should -Contain 'Functions/B.ps1: Inhalt anders' }
        finally { New-HMTestFile "$script:L\Functions\B.ps1" 'B' }
    }
    It 'bei Abweichung signiert nur ausdruecklich (Sign oder Rueckfrage), Standard ist auslassen' {
        $c = [pscustomobject]@{ State = 'abweichend'; Diff = @('a'); Text = 't' }
        Confirm-HMSignMismatch 'v9.0.1' $c 'Skip' | Should -BeFalse
        Confirm-HMSignMismatch 'v9.0.1' $c '' | Should -BeFalse
        Confirm-HMSignMismatch 'v9.0.1' $c 'Sign' | Should -BeTrue
    }
    It 'Invoke-HMReleaseSigning: neue Parameter hinten, alter Aufruf mit fuenf Werten bleibt gueltig' {
        $ps = @((Get-Command Invoke-HMReleaseSigning).Parameters.Keys)
        $ix = [array]::IndexOf($ps, 'Tags')
        $ix | Should -Be 4
        [array]::IndexOf($ps, 'LocalRoot') | Should -BeGreaterThan $ix
        [array]::IndexOf($ps, 'OnMismatch') | Should -BeGreaterThan $ix
    }
}

Describe 'Signieren: Invoke-HMReleaseSigning im Ganzen (ohne Zertifikat, ohne Netz)' {
    BeforeAll {
        function New-HMSha2([byte[]]$B) { $s = [System.Security.Cryptography.SHA256]::Create(); try { -join ($s.ComputeHash($B) | ForEach-Object { $_.ToString('x2') }) } finally { $s.Dispose() } }
        $script:S = Join-Path $TestDrive 'SignLokal'
        New-HMTestFile "$script:S\Config\version.json" '{ "version": "9.0.5" }'
        New-HMTestFile "$script:S\HUMig.ps1" 'H'
        $script:SignMan = [Text.Encoding]::UTF8.GetBytes("# HUMig-Release v9.0.5`n" + (New-HMSha2 ([Text.Encoding]::UTF8.GetBytes('H'))) + "  HUMig.ps1`n" + (New-HMSha2 ([Text.Encoding]::UTF8.GetBytes('{ "version": "9.0.5" }'))) + "  Config/version.json`n")
    }
    BeforeEach {
        Mock Get-HMSigningCert { [pscustomobject]@{ Thumbprint = 'AB' } }
        Mock Get-HMReleases { @([pscustomobject]@{ Version = [Version]'9.0.5'; Tag = 'v9.0.5'; ManifestUrl = 'm'; ManifestApi = 'm'; SignatureUrl = ''; SignatureApi = '' }) }
        Mock Get-HMReleaseAsset { , $script:SignMan }
        Mock New-HMManifestSignature { , ([byte[]](1, 2, 3)) }
        Mock Test-HMManifestSignature { '' }
        Mock Publish-HMReleaseSignature { }
    }
    It 'gleicher lokaler Stand: signiert, Ergebnis nennt den Abgleich' {
        $r = @(Invoke-HMReleaseSigning 'o' 'r' 'AB' 't' @() -LocalRoot $script:S)
        $r[0].Ok | Should -BeTrue
        $r[0].Text | Should -Match 'lokal abgeglichen'
        Should -Invoke Publish-HMReleaseSignature -Times 1 -Exactly
    }
    It 'Aufruf wie in der Oberflaeche (fuenf Werte), lokaler Stand weicht ab: nicht signiert, nichts hochgeladen' {
        New-HMTestFile "$script:S\HUMig.ps1" 'H anders'
        try {
            $r = @(Invoke-HMReleaseSigning 'o' 'r' 'AB' 't' @('v9.0.5') -LocalRoot $script:S)
            $r[0].Ok | Should -BeFalse
            $r[0].Text | Should -Match 'nicht signiert'
            $r[0].Text | Should -Not -Match 'Schreibrecht'
            Should -Invoke Publish-HMReleaseSignature -Times 0 -Exactly
            # mit -OnMismatch Sign: signiert, der Grund steht im Ergebnis
            $r = @(Invoke-HMReleaseSigning 'o' 'r' 'AB' 't' @('v9.0.5') -LocalRoot $script:S -OnMismatch Sign)
            $r[0].Ok | Should -BeTrue
            $r[0].Text | Should -Match 'OHNE lokalen Abgleich'
            Should -Invoke Publish-HMReleaseSignature -Times 1 -Exactly
        } finally { New-HMTestFile "$script:S\HUMig.ps1" 'H' }
    }
    It 'ohne -LocalRoot gilt der Programmordner von Core-Update.ps1 (hier: andere Version = nicht abgleichbar, nicht signiert)' {
        $r = @(Invoke-HMReleaseSigning 'o' 'r' 'AB' 't' @('v9.0.5'))
        $r[0].Ok | Should -BeFalse
        $r[0].Text | Should -Match 'kein Abgleich moeglich'
        Should -Invoke Publish-HMReleaseSignature -Times 0 -Exactly
    }
}