#Requires -Version 5.1
# Pester-Tests (Pester 5): Release signieren - Abgleich der Pruefsummen-Datei mit dem lokalen Stand in der Bestaetigung,
# zweite Rueckfrage nur bei echter Abweichung. Nichts wird signiert, kein Zertifikat, nichts geladen (Attrappen).

BeforeAll {
    $script:Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:MainFile = Join-Path $script:Root 'HUMig.ps1'
    $src = Get-Content -Raw -LiteralPath $script:MainFile -Encoding UTF8
    $code = [regex]::Match($src, '(?s)#region HMSign.*?#endregion HMSign').Value
    if (-not $code) { throw 'Region HMSign fehlt in HUMig.ps1' }
    . ([scriptblock]::Create($code))
    $script:MainAst = [System.Management.Automation.Language.Parser]::ParseFile($script:MainFile, [ref]$null, [ref]$null)
    function Get-SignFn([string]$Name) { @($script:MainAst.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $Name }, $true))[0].Extent.Text }
    function New-Chk([string]$Tag, [string]$State, [string]$Text = '', [string[]]$Diff = @()) { [pscustomobject]@{ Tag = $Tag; State = $State; Text = $Text; Diff = $Diff } }
}

Describe 'Signieren: Zeile je Release in der Bestaetigung' {
    It 'gleich, abweichend, andere Version, Fehler' {
        Get-HMSignCheckLine 'v2.1.24' (New-Chk 'v2.1.24' 'gleich' "gleich wie der lokale Stand ($(Join-Path $TestDrive 'HUMig'), 60 Dateien)") | Should -Be 'v2.1.24: gleich wie der lokale Stand'
        Get-HMSignCheckLine 'v2.1.24' (New-Chk 'v2.1.24' 'abweichend' 'weicht ab' @('HUMig.ps1: Inhalt anders', 'Pull.ps1: fehlt lokal')) | Should -Be 'v2.1.24: WEICHT vom lokalen Stand ab (2 Datei(en))'
        Get-HMSignCheckLine 'v2.1.25' (New-Chk 'v2.1.25' 'nicht abgleichbar' 'nicht mit lokalem Stand abgeglichen, lokal ist Version 2.1.24 (Q:\Werkzeug\Programm)') | Should -Be 'v2.1.25: nicht abgeglichen, lokal ist Version 2.1.24'
        Get-HMSignCheckLine 'v2.1.25' (New-Chk 'v2.1.25' 'nicht abgleichbar' 'nicht abgleichbar: Zugriff verweigert') | Should -Be 'v2.1.25: nicht abgeglichen: Zugriff verweigert'
        Get-HMSignCheckLine 'v2.1.25' (New-Chk 'v2.1.25' 'Fehler' 'Der Remoteserver hat einen Fehler zurueckgegeben') | Should -Be 'v2.1.25: nicht abgeglichen: Der Remoteserver hat einen Fehler zurueckgegeben'
        Get-HMSignCheckLine 'v2.1.25' $null | Should -Be 'v2.1.25: nicht abgeglichen'
        # Klammern im Programmordner (z.B. Program Files (x86)) und Netzpfad: Ordner wird ganz weggelassen
        Get-HMSignCheckLine 'v2.1.25' (New-Chk 'v2.1.25' 'nicht abgleichbar' 'nicht mit lokalem Stand abgeglichen, lokal ist Version 2.1.24 (Q:\Programme (x86)\Werkzeug)') | Should -Be 'v2.1.25: nicht abgeglichen, lokal ist Version 2.1.24'
        Get-HMSignCheckLine 'v2.1.25' (New-Chk 'v2.1.25' 'nicht abgleichbar' 'nicht mit lokalem Stand abgeglichen, kein lokaler Stand (\\server\freigabe (alt)\HUMig)') | Should -Be 'v2.1.25: nicht abgeglichen, kein lokaler Stand'
        # Klammer ohne Pfad bleibt
        Get-HMSignCheckLine 'v1' (New-Chk 'v1' 'Fehler' 'Timeout (abgebrochen)') | Should -Be 'v1: nicht abgeglichen: Timeout (abgebrochen)'
    }
    It 'Text aus dem echten Abgleich (Core-Update): installierte Version aelter als das Release' {
        . (Join-Path $script:Root 'Functions\Core-Update.ps1')
        $loc = Join-Path $TestDrive 'HUMig'
        [void](New-Item -ItemType Directory -Path (Join-Path $loc 'Config') -Force)
        Set-Content -LiteralPath (Join-Path $loc 'Config\version.json') -Value '{"version":"2.1.20"}' -Encoding UTF8
        $cmp = Compare-HMReleaseManifest "version 2.1.24`n" '2.1.24' $loc
        Get-HMSignCheckLine 'v2.1.24' ([pscustomobject]@{ Tag = 'v2.1.24'; State = $cmp.State; Text = $cmp.Text; Diff = @($cmp.Diff) }) | Should -Be 'v2.1.24: nicht abgeglichen, lokal ist Version 2.1.20'
    }
}

Describe 'Signieren: Ergebnis des Abgleichs je Release' {
    It 'Zeitgrenze oder Fehler: jedes Release gilt als nicht abgeglichen' {
        $c = @(Get-HMSignChecks @('v1', 'v2') 'FEHLER: Timeout - keine Antwort nach 90 Sekunden (abgebrochen)')
        $c.Count | Should -Be 2
        Get-HMSignCheckLine 'v1' $c[0] | Should -Be 'v1: nicht abgeglichen: Timeout - keine Antwort nach 90 Sekunden (abgebrochen)'
        (@(Get-HMSignChecks @('v1') ([pscustomobject]@{ Checks = @(); Err = 'Netz weg' }))[0]).Text | Should -Be 'Netz weg'
        (@(Get-HMSignChecks @('v1') $null)[0]).Text | Should -Be 'keine Antwort'
    }
    It 'fehlt ein Release im Ergebnis, gilt nur dieses als nicht abgeglichen' {
        $c = @(Get-HMSignChecks @('v1', 'v2') ([pscustomobject]@{ Checks = @((New-Chk 'v1' 'gleich')); Err = '' }))
        $c[0].State | Should -Be 'gleich'
        $c[1].State | Should -Be 'Fehler'
        $c[1].Text | Should -Be 'kein Ergebnis'
    }
}

Describe 'Signieren: Plan und Entscheidung' {
    It 'Normalfall: Zeilen in der vorhandenen Bestaetigung, keine zweite Rueckfrage, alles signieren' {
        $p = Get-HMSignPlan @('v2.1.24', 'v2.1.25') @((New-Chk 'v2.1.24' 'gleich'), (New-Chk 'v2.1.25' 'nicht abgleichbar' 'nicht mit lokalem Stand abgeglichen, lokal ist Version 2.1.24 (C:\x)'))
        $p.ConfirmText | Should -Match "^Diese Releases jetzt mit deinem Zertifikat signieren\?`n`nv2\.1\.24: gleich wie der lokale Stand`nv2\.1\.25: nicht abgeglichen, lokal ist Version 2\.1\.24`n`nDanach werden sie allen HUMig-Installationen als Update angeboten \(je nach Kanal Stabil/Test\)\.$"
        @($p.Mismatch).Count | Should -Be 0
        $p.MismatchText | Should -Be ''
        $d = Get-HMSignDecision $p ''
        # ohne ausdrueckliches Ja immer Skip: wirkt im Signier-Lauf nur auf echte Abweichungen
        $d.OnMismatch | Should -Be 'Skip'
        @($d.Skipped).Count | Should -Be 0
        @($d.SignTags) | Should -Be @('v2.1.24', 'v2.1.25')
    }
    It 'Abweichung: zweite Rueckfrage mit hoechstens acht Dateien je Release, als Satz gelesen' {
        $diff = @(1..10 | ForEach-Object { "Functions/Datei$_.ps1: Inhalt anders" })
        $p = Get-HMSignPlan @('v2.1.24', 'v2.1.23') @((New-Chk 'v2.1.24' 'abweichend' 'x' $diff), (New-Chk 'v2.1.23' 'gleich'))
        @($p.Mismatch) | Should -Be @('v2.1.24')
        $p.MismatchText | Should -Match "^Die Pruefsummen-Datei auf GitHub weicht bei gleicher Version vom lokalen Stand ab:`n`nv2\.1\.24:`n   Functions/Datei1\.ps1: Inhalt anders"
        ([regex]::Matches($p.MismatchText, 'Inhalt anders')).Count | Should -Be 8
        $p.MismatchText | Should -Match '   \.\.\. und 2 weitere'
        $p.MismatchText | Should -Match "Trotzdem signieren\? Die Signatur bestaetigt dann den Stand auf GitHub, nicht deinen lokalen\.`n`nJa = trotzdem signieren`nNein = diese Releases auslassen, die anderen signieren$"
        $p.MismatchText | Should -Not -Match 'v2\.1\.23'
        (Get-HMSignDecision $p 'Yes').OnMismatch | Should -Be 'Sign'
        $no = Get-HMSignDecision $p 'No'
        $no.OnMismatch | Should -Be 'Skip'
        @($no.Skipped) | Should -Be @('v2.1.24')
        @($no.SignTags) | Should -Be @('v2.1.23')
        # alle abweichend und Nein: nichts zu signieren
        $all = Get-HMSignPlan @('v1') @((New-Chk 'v1' 'abweichend' 'x' @('a: Inhalt anders')))
        @((Get-HMSignDecision $all 'No').SignTags).Count | Should -Be 0
        (Get-HMSignDecision $p '').OnMismatch | Should -Be 'Skip'   # Schliessen = sicher
    }
}

Describe 'Signieren: Ablauf in der Oberflaeche (Attrappen statt GitHub und Zertifikat)' {
    BeforeAll {
        . ([scriptblock]::Create((Get-SignFn 'Start-HMReleaseSigning')))
        . ([scriptblock]::Create((Get-SignFn 'Stop-HMSigning')))
        function Get-HMUpdateConfig { [pscustomobject]@{ Owner = 'o'; Repo = 'r'; SignerThumbprint = 'AB' } }
        function Get-HMSigningCert { $true }
        function Get-HMSignTokenOrPrompt { 'tok' }
        function Get-HMSignTokenFile { Join-Path $TestDrive 'token' }
        function Out-Console { param($m, $l) $script:Lines.Add("$l|$m") }
        function Invoke-UpdateCheck { }
        function Confirm-Action { param($m, $t) $script:Confirms.Add("$m"); return $script:ConfirmAnswer }
        function Show-HMDialogBox { param($Owner, $Text, $Title, $Mode, $Icon, $Default) $script:Dialogs.Add(@{ Text = $Text; Default = $Default }); return $script:MisAnswer }
        # Hintergrundlaeufe der Reihe nach mit vorbereiteten Antworten, keine echten Laeufe
        # mit $script:Defer werden die Laeufe nur vorgemerkt und spaeter einzeln beendet (Klick waehrend der Pruefung)
        function Invoke-AsyncCommand { param($ScriptBlock, $ArgumentList, $TimeoutSec, $State, $OnComplete) $run = @{ Args = $ArgumentList; Timeout = $TimeoutSec; State = $State; OnComplete = $OnComplete }; $script:Runs.Add($run); if ($script:Defer) { $script:Pending.Enqueue($run); return }; $res = $script:Answers.Dequeue(); & $OnComplete $res $State }
        function Complete-Next($Res) { $run = $script:Pending.Dequeue(); & $run.OnComplete $Res $run.State }
    }
    BeforeEach {
        $script:Lines = New-Object System.Collections.Generic.List[string]; $script:Confirms = New-Object System.Collections.Generic.List[string]
        $script:Dialogs = New-Object System.Collections.Generic.List[object]; $script:Runs = New-Object System.Collections.Generic.List[object]
        $script:Answers = New-Object System.Collections.Queue; $script:ConfirmAnswer = $true; $script:MisAnswer = 'No'
        $script:JobRunning = $false; $script:ConfigDir = $TestDrive; $script:AppRoot = $script:Root; $script:SignBusy = $false; $script:RunspacePool = 'Pool'; $script:Defer = $false; $script:Pending = New-Object System.Collections.Queue
        $script:Rels = @([pscustomobject]@{ Tag = 'v2.1.24'; Version = '2.1.24' }, [pscustomobject]@{ Tag = 'v2.1.25'; Version = '2.1.25' })
    }
    It 'Normalfall: ein Klick wie bisher, Abgleich steht in der Bestaetigung, Signier-Lauf mit OnMismatch Skip' {
        $script:Answers.Enqueue([pscustomobject]@{ Tags = @('v2.1.24', 'v2.1.25'); Releases = $script:Rels; Err = '' })
        $script:Answers.Enqueue([pscustomobject]@{ Checks = @((New-Chk 'v2.1.24' 'gleich'), (New-Chk 'v2.1.25' 'nicht abgleichbar' 'nicht mit lokalem Stand abgeglichen, lokal ist Version 2.1.24 (C:\x)')); Err = '' })
        $script:Answers.Enqueue([pscustomobject]@{ Items = @([pscustomobject]@{ Tag = 'v2.1.24'; Ok = $true; Text = 'signiert' }); Err = '' })
        Start-HMReleaseSigning
        $script:Confirms.Count | Should -Be 1
        $script:Confirms[0] | Should -Match 'v2\.1\.24: gleich wie der lokale Stand'
        $script:Dialogs.Count | Should -Be 0
        $script:Runs.Count | Should -Be 3
        $script:Runs[1].Timeout | Should -Be 90   # 30 + 30 je Release
        @($script:Runs[2].Args)[-1] | Should -Be 'Skip'
        @(@($script:Runs[2].Args)[5]) | Should -Be @('v2.1.24', 'v2.1.25')
    }
    It 'Abweichung und Nein: diese Releases auslassen, die anderen signieren (OnMismatch Skip)' {
        $script:Answers.Enqueue([pscustomobject]@{ Tags = @('v2.1.24', 'v2.1.25'); Releases = $script:Rels; Err = '' })
        $script:Answers.Enqueue([pscustomobject]@{ Checks = @((New-Chk 'v2.1.24' 'abweichend' 'x' @('HUMig.ps1: Inhalt anders')), (New-Chk 'v2.1.25' 'gleich')); Err = '' })
        $script:Answers.Enqueue([pscustomobject]@{ Items = @(); Err = '' })
        Start-HMReleaseSigning
        $script:Dialogs.Count | Should -Be 1
        $script:Dialogs[0].Default | Should -Be 'No'
        @($script:Runs[2].Args)[-1] | Should -Be 'Skip'
        @(@($script:Runs[2].Args)[5]) | Should -Be @('v2.1.25')   # ausgelassene gehen nicht an den Signier-Lauf
        ($script:Lines -join "`n") | Should -Match 'Info\|Ausgelassen \(weicht vom lokalen Stand ab\): v2\.1\.24'
        ($script:Lines -join "`n") | Should -Match 'Signiere v2\.1\.25 \.\.\.'
    }
    It 'Abweichung und Ja: trotzdem signieren (OnMismatch Sign)' {
        $script:MisAnswer = 'Yes'
        $script:Answers.Enqueue([pscustomobject]@{ Tags = @('v2.1.24'); Releases = @($script:Rels[0]); Err = '' })
        $script:Answers.Enqueue([pscustomobject]@{ Checks = @((New-Chk 'v2.1.24' 'abweichend' 'x' @('HUMig.ps1: Inhalt anders'))); Err = '' })
        $script:Answers.Enqueue([pscustomobject]@{ Items = @(); Err = '' })
        Start-HMReleaseSigning
        @($script:Runs[2].Args)[-1] | Should -Be 'Sign'
    }
    It 'Abgleich scheitert oder laeuft in die Zeitgrenze: Signier-Lauf wie bisher (Skip wirkt nur auf echte Abweichung), Zeile "nicht abgeglichen"' {
        $script:Answers.Enqueue([pscustomobject]@{ Tags = @('v2.1.24'); Releases = @($script:Rels[0]); Err = '' })
        $script:Answers.Enqueue('FEHLER: Timeout - keine Antwort nach 60 Sekunden (abgebrochen)')
        $script:Answers.Enqueue([pscustomobject]@{ Items = @(); Err = '' })
        Start-HMReleaseSigning
        $script:Confirms[0] | Should -Match 'v2\.1\.24: nicht abgeglichen: Timeout'
        $script:Dialogs.Count | Should -Be 0
        $script:Runs.Count | Should -Be 3
        @($script:Runs[2].Args)[-1] | Should -Be 'Skip'   # erst der Signier-Lauf erkennt eine Abweichung -> nicht ohne Rueckfrage
    }
    It 'alle abweichend und Nein: kein Signier-Lauf, ruhige Zeile statt Fehlern' {
        $script:Answers.Enqueue([pscustomobject]@{ Tags = @('v2.1.24'); Releases = @($script:Rels[0]); Err = '' })
        $script:Answers.Enqueue([pscustomobject]@{ Checks = @((New-Chk 'v2.1.24' 'abweichend' 'x' @('HUMig.ps1: Inhalt anders'))); Err = '' })
        Start-HMReleaseSigning
        $script:Runs.Count | Should -Be 2
        ($script:Lines -join "`n") | Should -Match 'Info\|Nichts signiert: v2\.1\.24 ausgelassen \(weicht vom lokalen Stand ab\)\.'
        ($script:Lines -join "`n") | Should -Not -Match 'Error\|'
        ($script:Lines -join "`n") | Should -Not -Match 'Signiere'
        $script:SignBusy | Should -BeFalse
    }
    It 'zwei Starts kurz nacheinander: der zweite startet keinen Ablauf, der erste signiert genau seine Releases' {
        $script:Defer = $true
        Start-HMReleaseSigning
        Start-HMReleaseSigning
        $script:Runs.Count | Should -Be 1
        ($script:Lines -join "`n") | Should -Match 'Warning\|Signieren laeuft bereits'
        Complete-Next ([pscustomobject]@{ Tags = @('v2.1.24'); Releases = @($script:Rels[0]); Err = '' })
        Start-HMReleaseSigning                                   # waehrend der Pruefung noch einmal
        $script:Runs.Count | Should -Be 2
        Complete-Next ([pscustomobject]@{ Checks = @((New-Chk 'v2.1.24' 'gleich')); Err = '' })
        $script:Confirms[0] | Should -Match 'v2\.1\.24: gleich wie der lokale Stand'
        @(@($script:Runs[2].Args)[5]) | Should -Be @('v2.1.24')
        $script:SignBusy | Should -BeTrue
        Complete-Next ([pscustomobject]@{ Items = @(); Err = '' })
        $script:SignBusy | Should -BeFalse
    }
    It 'Fehler im ersten Lauf bzw. Zeitgrenze beim Signieren: Merkmal zurueck, neuer Start moeglich' {
        $script:Answers.Enqueue('FEHLER: Timeout - keine Antwort nach 40 Sekunden (abgebrochen)')
        Start-HMReleaseSigning
        $script:SignBusy | Should -BeFalse
        $script:Answers.Enqueue([pscustomobject]@{ Tags = @('v2.1.24'); Releases = @($script:Rels[0]); Err = '' })
        $script:Answers.Enqueue([pscustomobject]@{ Checks = @((New-Chk 'v2.1.24' 'gleich')); Err = '' })
        $script:Answers.Enqueue('FEHLER: Timeout - keine Antwort nach 180 Sekunden (abgebrochen)')
        Start-HMReleaseSigning
        $script:Runs.Count | Should -Be 4
        $script:SignBusy | Should -BeFalse
        ($script:Lines -join "`n") | Should -Match 'Signieren fehlgeschlagen: FEHLER: Timeout'
    }
    It 'ohne Hintergrund-Pool: Meldung, kein Lauf, Merkmal bleibt frei' {
        $script:RunspacePool = $null
        Start-HMReleaseSigning
        $script:Runs.Count | Should -Be 0
        $script:SignBusy | Should -BeFalse
        ($script:Lines -join "`n") | Should -Match 'Error\|Signieren nicht moeglich: Hintergrundlaeufe sind nicht bereit'
    }
    It 'erst im Signier-Lauf erkannte Abweichung: Hinweiszeile statt Fehler' {
        $script:Answers.Enqueue([pscustomobject]@{ Tags = @('v2.1.24'); Releases = @($script:Rels[0]); Err = '' })
        $script:Answers.Enqueue('FEHLER: Timeout')
        $script:Answers.Enqueue([pscustomobject]@{ Items = @([pscustomobject]@{ Tag = 'v2.1.24'; Ok = $false; Text = 'nicht signiert: weicht vom lokalen Stand (Q:\x) ab: 1 Datei(en)' }); Err = '' })
        Start-HMReleaseSigning
        ($script:Lines -join "`n") | Should -Match 'Info\|v2\.1\.24: weicht ab, nicht signiert: Release signieren erneut starten, dann kommt die Rueckfrage'
        ($script:Lines -join "`n") | Should -Not -Match 'Error\|v2\.1\.24'
    }
    It 'Bestaetigung abgelehnt: nichts wird signiert' {
        $script:ConfirmAnswer = $false
        $script:Answers.Enqueue([pscustomobject]@{ Tags = @('v2.1.24'); Releases = @($script:Rels[0]); Err = '' })
        $script:Answers.Enqueue([pscustomobject]@{ Checks = @((New-Chk 'v2.1.24' 'gleich')); Err = '' })
        Start-HMReleaseSigning
        $script:Runs.Count | Should -Be 2
        $script:SignBusy | Should -BeFalse
        # danach ist ein neuer Start wieder moeglich
        $script:Answers.Enqueue([pscustomobject]@{ Tags = @(); Releases = @(); Err = '' })
        Start-HMReleaseSigning
        $script:Runs.Count | Should -Be 3
        ($script:Lines -join "`n") | Should -Match 'Alle Releases mit Pruefsumme sind bereits signiert'
    }
}

Describe 'Signieren: OnMismatch Skip im echten Signier-Lauf (Core-Update, Attrappen fuer Zertifikat und GitHub)' {
    BeforeAll {
        . (Join-Path $script:Root 'Functions\Core-Update.ps1')
        function Get-HMSigningCert { [pscustomobject]@{ Thumbprint = 'AB' } }
        function Get-HMReleases { @([pscustomobject]@{ Tag = 'v2.1.24'; Version = '2.1.24'; ManifestUrl = 'u'; ManifestApi = 'a'; SignatureUrl = '' }) }
        function Get-HMReleaseAsset { [System.Text.Encoding]::UTF8.GetBytes((('a' * 64) + "  HUMig.ps1`n")) }
        function Test-HMManifestRelease { '' }
        function New-HMManifestSignature { [byte[]](1, 2, 3) }
        function Test-HMManifestSignature { '' }
        function Publish-HMReleaseSignature { $script:Published++ }
    }
    BeforeEach {
        $script:Published = 0
        $script:Loc = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path (Join-Path $script:Loc 'Config') -Force)
        Set-Content -LiteralPath (Join-Path $script:Loc 'HUMig.ps1') -Value 'lokaler Inhalt' -Encoding UTF8
    }
    It 'lokal andere Version, OnMismatch Skip: wird signiert (Normalfall beim Signieren aus der aelteren Installation)' {
        Set-Content -LiteralPath (Join-Path $script:Loc 'Config\version.json') -Value '{"version":"2.1.20"}' -Encoding UTF8
        $r = @(Invoke-HMReleaseSigning 'o' 'r' 'AB' 'tok' @('v2.1.24') $script:Loc -OnMismatch Skip)
        $r[0].Ok | Should -BeTrue
        $r[0].Text | Should -Match '^signiert \(nicht mit lokalem Stand abgeglichen, lokal ist Version 2\.1\.20'
        $script:Published | Should -Be 1
    }
    It 'gleiche Version, anderer Inhalt, OnMismatch Skip: nicht signiert' {
        Set-Content -LiteralPath (Join-Path $script:Loc 'Config\version.json') -Value '{"version":"2.1.24"}' -Encoding UTF8
        $r = @(Invoke-HMReleaseSigning 'o' 'r' 'AB' 'tok' @('v2.1.24') $script:Loc -OnMismatch Skip)
        $r[0].Ok | Should -BeFalse
        $r[0].Text | Should -Match '^nicht signiert: weicht vom lokalen Stand'
        $script:Published | Should -Be 0
        (Get-HMSignResultLine $r[0]).Level | Should -Be 'Info'
    }
}
