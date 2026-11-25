#Requires -Version 5.1
# Pester-Tests (Pester 5): Ziel ist, was verbunden ist - Computer, Benutzerliste und Rueckfragen im Hauptfenster.
# Die Funktionen kommen aus HUMig.ps1 (Region HMZiel bzw. einzelne Funktionen per Syntaxbaum), ohne Fenster.

BeforeAll {
    $script:Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:MainFile = Join-Path $script:Root 'HUMig.ps1'
    $script:MainSrc = Get-Content -Raw -LiteralPath $script:MainFile -Encoding UTF8
    $script:MainAst = [System.Management.Automation.Language.Parser]::ParseFile($script:MainFile, [ref]$null, [ref]$null)
    # Quelltext einer Funktion aus HUMig.ps1 (Syntaxbaum), zum Dot-Sourcen im Test
    function Get-ZielFn([string]$Name) {
        $f = @($script:MainAst.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $Name }, $true))[0]
        if (-not $f) { throw "Funktion $Name fehlt in HUMig.ps1" }
        return $f.Extent.Text
    }
    $code = [regex]::Match($script:MainSrc, '(?s)#region HMZiel.*?#endregion HMZiel').Value
    if (-not $code) { throw 'Region HMZiel fehlt in HUMig.ps1' }
    . ([scriptblock]::Create($code))
    function New-ZielProfile([string]$Sid, [string]$Account, [bool]$Interactive = $false, [bool]$Loaded = $false, [string]$LastUse = '') {
        [pscustomobject]@{ SID = $Sid; Account = $Account; Folder = $Account.Split('\')[-1]; LocalPath = "C:\Users\$($Account.Split('\')[-1])"; Interactive = $Interactive; Loaded = $Loaded; LastUse = $LastUse }
    }
}

Describe 'Ziel: Computernamen vergleichen' {
    It 'lokal, gross/klein, FQDN gegen kurzen Namen, IP-Adressen' {
        Test-HMSameComputer 'pc01' 'PC01' 'EIGEN' 'a.local' | Should -BeTrue
        Test-HMSameComputer '' 'EIGEN' 'EIGEN' 'a.local' | Should -BeTrue
        Test-HMSameComputer 'localhost' '.' 'EIGEN' 'a.local' | Should -BeTrue
        Test-HMSameComputer 'PC01.schule.local' 'PC01' 'EIGEN' 'a.local' | Should -BeTrue
        Test-HMSameComputer 'PC01' 'PC02' 'EIGEN' 'a.local' | Should -BeFalse
        Test-HMSameComputer 'PC01' 'EIGEN' 'EIGEN' 'a.local' | Should -BeFalse
        Test-HMSameComputer '203.0.113.5' '203' 'EIGEN' 'a.local' | Should -BeFalse
        Test-HMSameComputer '203.0.113.5' '203.0.113.5' 'EIGEN' 'a.local' | Should -BeTrue
    }
    It 'FQDN mit anderer Domaene ist ein anderer PC, auch beim eigenen Namen' {
        Test-HMSameComputer 'PC01.a.local' 'PC01.b.local' 'EIGEN' 'a.local' | Should -BeFalse
        Test-HMSameComputer 'PC01.a.local' 'pc01.A.LOCAL' 'EIGEN' 'a.local' | Should -BeTrue
        Test-HMSameComputer 'eigen.a.local' 'EIGEN' 'EIGEN' 'a.local' | Should -BeTrue
        Test-HMSameComputer 'eigen.b.local' 'EIGEN' 'EIGEN' 'a.local' | Should -BeFalse
        Test-HMSameComputer 'eigen.a.local' 'eigen.b.local' 'EIGEN' 'a.local' | Should -BeFalse
        # Arbeitsgruppe (keine Domaene bekannt): eigener Name mit Domaene gilt als lokal
        Test-HMSameComputer 'eigen.fritz.box' '' 'EIGEN' '' | Should -BeTrue
    }
}
Describe 'Ziel: Feld gegen verbundenen PC' {
    It 'Zustand Match, Differs, None und Verbindungsstand' {
        $s = Get-HMTargetState 'PC01' @{ Computer = 'PC01'; Connected = $true } 'EIGEN'
        $s.Kind | Should -Be 'Match'; $s.Conn | Should -Be 'Connected'
        $s = Get-HMTargetState 'PC02' @{ Computer = 'PC01'; Connected = $true } 'EIGEN'
        $s.Kind | Should -Be 'Differs'; $s.Field | Should -Be 'PC02'; $s.Computer | Should -Be 'PC01'
        (Get-HMTargetState 'PC01' @{ Computer = 'PC01'; Connected = $false; Connecting = $true } 'EIGEN').Conn | Should -Be 'Connecting'
        (Get-HMTargetState 'PC01' @{ Computer = 'PC01'; Connected = $false; Connecting = $false } 'EIGEN').Conn | Should -Be 'Failed'
        (Get-HMTargetState 'PC01' $null 'EIGEN').Kind | Should -Be 'None'
        # leeres Feld = dieser PC (wie bisher)
        (Get-HMTargetState '  ' @{ Computer = 'EIGEN'; Connected = $true } 'EIGEN').Kind | Should -Be 'Match'
    }
    It 'Anzeige "verbunden mit" in beiden Zustaenden, Hinweisfarbe bei Unterschied' {
        $l = Get-HMTargetLabel (Get-HMTargetState 'PC01' @{ Computer = 'PC01'; Connected = $true } 'EIGEN')
        $l.Text | Should -Be 'verbunden mit PC01'
        $l.Color | Should -Be '#FFA6E3A1'
        $l = Get-HMTargetLabel (Get-HMTargetState 'PC02' @{ Computer = 'PC01'; Connected = $true } 'EIGEN')
        $l.Text | Should -Be 'verbunden mit PC01   |   im Feld: PC02 (Enter = verbinden)'
        $l.Color | Should -Be '#FFF9E2AF'
        $l.Tip | Should -Match '^Im Feld Computer steht PC02, Ziel ist aber PC01\. Enter oder Verbinden = mit PC02 verbinden\.'
        (Get-HMTargetLabel (Get-HMTargetState 'PC02' @{ Computer = 'PC01' } 'EIGEN')).Text | Should -Be 'nicht verbunden: PC01 (fehlgeschlagen)   |   im Feld: PC02 (Enter = verbinden)'
        # lange Namen kurz, wenn eindeutig; sonst voll; IP-Adressen nie gekuerzt
        (Get-HMTargetLabel (Get-HMTargetState 'pc02.a.local' @{ Computer = 'pc01.a.local'; Connected = $true } 'EIGEN')).Text | Should -Be 'verbunden mit pc01   |   im Feld: pc02 (Enter = verbinden)'
        (Get-HMTargetLabel (Get-HMTargetState 'pc01.b.local' @{ Computer = 'pc01.a.local'; Connected = $true } 'EIGEN')).Text | Should -Be 'verbunden mit pc01.a.local   |   im Feld: pc01.b.local (Enter = verbinden)'
        (Get-HMTargetLabel (Get-HMTargetState '203.0.113.6' @{ Computer = '203.0.113.5'; Connected = $true } 'EIGEN')).Text | Should -Be 'verbunden mit 203.0.113.5   |   im Feld: 203.0.113.6 (Enter = verbinden)'
        (Get-HMTargetLabel (Get-HMTargetState 'pc02.a.local' @{ Computer = 'pc01.a.local'; Connected = $true } 'EIGEN')).Tip | Should -Match 'steht pc02\.a\.local, Ziel ist aber pc01\.a\.local'
        (Get-HMTargetLabel (Get-HMTargetState 'PC01' @{ Computer = 'PC01'; Connecting = $true } 'EIGEN')).Text | Should -Be 'verbinde mit PC01 ...'
        (Get-HMTargetLabel (Get-HMTargetState 'PC01' @{ Computer = 'PC01' } 'EIGEN')).Text | Should -Match '^nicht verbunden: PC01 \(Verbindung fehlgeschlagen'
        (Get-HMTargetLabel (Get-HMTargetState 'PC01' $null 'EIGEN')).Text | Should -Be 'nicht verbunden'
    }
    It 'Rueckfrage nur bei Unterschied, in beiden Varianten gleich belegt (als Satz gelesen)' {
        Get-HMTargetQuestion (Get-HMTargetState 'PC01' @{ Computer = 'PC01'; Connected = $true } 'EIGEN') 'Backup' | Should -BeNullOrEmpty
        $q = Get-HMTargetQuestion (Get-HMTargetState 'PC02' @{ Computer = 'PC01'; Connected = $true } 'EIGEN') 'Backup'
        $q | Should -Match '^Im Feld Computer steht PC02, verbunden ist PC01\.'
        $q | Should -Match 'Backup wuerde auf PC01 laufen, nicht auf PC02\.'
        $q | Should -Match 'Ja = Backup auf PC01 ausfuehren \(das Feld wird auf PC01 zurueckgesetzt\)'
        $q | Should -Match 'Nein = nichts tun'
        $q | Should -Match 'Fuer PC02: Nein, dann im Feld Enter oder Verbinden\.$'
        (Get-HMTargetQuestion (Get-HMTargetState 'PC02' @{ Computer = 'PC01'; Connecting = $true } 'EIGEN') 'Restore') | Should -Match 'die Verbindung zu PC01 wird gerade aufgebaut'
        (Get-HMTargetQuestion (Get-HMTargetState 'PC02' @{ Computer = 'PC01' } 'EIGEN') 'Restore') | Should -Match 'gewaehlt ist PC01 \(nicht verbunden\)'
        # waehrend Backup/Restore: dieselbe Belegung, Hinweis auf spaeteres Verbinden
        $j = Get-HMTargetQuestion (Get-HMTargetState 'PC02' @{ Computer = 'PC01'; Connected = $true } 'EIGEN') "'Netzwerktest'" 'Restore'
        $j | Should -Match "Ja = 'Netzwerktest' auf PC01 ausfuehren \(das Feld wird auf PC01 zurueckgesetzt\)"
        $j | Should -Match 'Nein = nichts tun'
        $j | Should -Match "Waehrend 'Restore' laeuft, wird nicht neu verbunden\. Fuer PC02: Nein, nach dem Vorgang im Feld Enter oder Verbinden\.$"
        foreach ($x in @($q, $j)) { $x | Should -Not -Match 'Nein = .*ausfuehren'; $x | Should -Not -Match 'Abbrechen' }
    }
    It 'Art des Vorgangs: nur Backup und Restore belegen PC und Profil' {
        Test-HMIsBackupRestoreJob 'Backup' | Should -BeTrue
        Test-HMIsBackupRestoreJob 'Restore' | Should -BeTrue
        foreach ($t in @('Groesse ermitteln', 'Backup pruefen', 'Backups vergleichen', 'Restore-Vorschau', 'Updates suchen', 'WinGet einrichten', 'Server-Backup', 'VM-Export', '')) { Test-HMIsBackupRestoreJob $t | Should -BeFalse }
    }
    It 'Entscheidung je Werkzeugart: nur PC = still umschalten, Benutzer = Rueckfrage, ohne Ziel = laufen' {
        $d = Get-HMTargetState 'PC02' @{ Computer = 'PC01'; Connected = $true } 'EIGEN'
        $m = Get-HMTargetState 'PC01' @{ Computer = 'PC01'; Connected = $true } 'EIGEN'
        Get-HMToolDecision 'Pc' $d $false | Should -Be 'Switch'
        Get-HMToolDecision 'Pc' $d $true | Should -Be 'Ask'
        Get-HMToolDecision 'User' $d $false | Should -Be 'Ask'
        Get-HMToolDecision 'None' $d $true | Should -Be 'Run'
        Get-HMToolDecision 'Pc' $m $false | Should -Be 'Run'
        Get-HMToolDecision 'User' $m $true | Should -Be 'Run'
    }
    It 'Antwort eines Verbindens zaehlt nur, wenn sie zum neuesten gehoert' {
        Test-HMConnectCurrent 3 3 | Should -BeTrue
        Test-HMConnectCurrent 2 3 | Should -BeFalse
    }
}

Describe 'Ziel: Aktionen nehmen PC und Benutzer aus dem Ziel, nie den PC aus dem Feld' {
    BeforeAll {
        . ([scriptblock]::Create((Get-ZielFn 'Get-HMFieldComputer')))
        . ([scriptblock]::Create((Get-ZielFn 'Get-TargetComputer')))
        . ([scriptblock]::Create((Get-ZielFn 'New-BaseCtx')))
    }
    It 'Get-TargetComputer liefert den verbundenen PC, auch wenn im Feld etwas anderes steht' {
        $ui = @{ cmbComputer = [pscustomobject]@{ Text = 'PC02' } }
        $script:Target = @{ Computer = 'PC01'; Connected = $true }
        Get-TargetComputer | Should -Be 'PC01'
        # Verbinden gescheitert: Ziel bleibt der gewaehlte PC (Wake-on-LAN, Fernwartung aktivieren, Netzwerktest)
        $script:Target = @{ Computer = 'PC03'; Connected = $false }
        Get-TargetComputer | Should -Be 'PC03'
        # vor dem ersten Verbinden: Feld, leer = dieser PC
        $script:Target = $null
        Get-TargetComputer | Should -Be 'PC02'
        $ui.cmbComputer.Text = ' '
        Get-TargetComputer | Should -Be $env:COMPUTERNAME
    }
    It 'Backup-Kontext: Computer und SID/Profilpfad gehoeren zusammen' {
        $ui = @{ cmbComputer = [pscustomobject]@{ Text = 'PC02' }; cmbThreads = [pscustomobject]@{ SelectedItem = 8 } }
        $script:Target = @{ Computer = 'PC01'; Connected = $true }
        function Get-SelectedProfile { New-ZielProfile 'S-1-5-21-1-1001' 'SCHULE\anna' }
        function Get-BackupRoot { 'X:\BACKUPS' }
        function Get-BackupOptions { @{} }
        $c = New-BaseCtx
        $c.Computer | Should -Be 'PC01'
        $c.UserSid | Should -Be 'S-1-5-21-1-1001'
        $c.ProfilePath | Should -Be 'C:\Users\anna'
    }
}

Describe 'Ziel: Verbinden verwirft veraltete Antworten und behaelt die Auswahl' {
    BeforeAll {
        . ([scriptblock]::Create((Get-ZielFn 'Get-HMFieldComputer')))
        . ([scriptblock]::Create((Get-ZielFn 'Get-TargetComputer')))
        . ([scriptblock]::Create((Get-ZielFn 'Connect-Target')))
        function Set-ConnectStatus { param($t, $c) $script:LastStatus = $t }
        function Out-Console { param($m, $l) $script:Lines.Add("$l|$m") }
        function Update-HMTargetLabel { }
        function Update-SidLabel { }
        function Start-HMAppDetect { }
        function Add-ComputerHistory { }
        function Format-ProfileEntry($p) { "$($p.Account)" }
        function Test-HMIsLocal($c) { $false }
        function Get-SelectedProfile { $i = $ui.cmbUser.SelectedIndex; if ($i -ge 0 -and $i -lt @($script:Profiles).Count) { return $script:Profiles[$i] }; return $null }
        function Invoke-AsyncCommand { param($ScriptBlock, $ArgumentList, $TimeoutSec, $State, $OnComplete) $script:Calls.Add(@{ State = $State; OnComplete = $OnComplete }) }
    }
    BeforeEach {
        $script:Calls = New-Object System.Collections.Generic.List[object]
        $script:Lines = New-Object System.Collections.Generic.List[string]
        $script:Target = $null; $script:ConnectSeq = 0; $script:Profiles = @(); $script:UserMode = $false
        $script:BackupChecks = @{}; $script:JobEndStatus = $null; $script:Engine = 'x'; $script:RemoteCred = $null
        $ui = @{ cmbComputer = [pscustomobject]@{ Text = 'PC02' }; cmbUser = [pscustomobject]@{ Items = (New-Object System.Collections.ArrayList); SelectedIndex = -1; Text = '' }; lblSid = [pscustomobject]@{ Text = '' } }
    }
    It 'Antwort von PC02 kommt nach dem Verbinden mit PC03 an: verworfen, Liste bleibt bei PC03' {
        Connect-Target -FromField
        $ui.cmbComputer.Text = 'PC03'
        Connect-Target -FromField
        $script:Calls.Count | Should -Be 2
        $old = [pscustomobject]@{ Profiles = @(New-ZielProfile 'S-2' 'PC02\bert'); Error = $null; WinRM = $null; Laptop = $false }
        & $script:Calls[0].OnComplete $old $script:Calls[0].State
        @($script:Profiles).Count | Should -Be 0
        $script:Target.Computer | Should -Be 'PC03'
        $script:Target.Connected | Should -BeFalse
        ($script:Lines -join "`n") | Should -Match 'Antwort von PC02 verworfen'
        $new = [pscustomobject]@{ Profiles = @(New-ZielProfile 'S-3' 'PC03\cara' $true); Error = $null; WinRM = $null; Laptop = $false }
        & $script:Calls[1].OnComplete $new $script:Calls[1].State
        $script:Profiles[0].Account | Should -Be 'PC03\cara'
        $script:Target.Connected | Should -BeTrue
        $ui.cmbUser.SelectedIndex | Should -Be 0
    }
    It 'Neuladen ohne Schalter (z.B. nach dem Restore) nimmt das Ziel, nicht das Feld, und behaelt den Benutzer' {
        $ui.cmbComputer.Text = 'PC01'
        Connect-Target -FromField
        $p = @((New-ZielProfile 'S-A' 'PC01\anna' $true), (New-ZielProfile 'S-B' 'PC01\bert'))
        & $script:Calls[0].OnComplete ([pscustomobject]@{ Profiles = $p; Error = $null; WinRM = $null }) $script:Calls[0].State
        $ui.cmbUser.SelectedIndex = 1   # bert gewaehlt
        $ui.cmbComputer.Text = 'PC09'   # im Feld steht inzwischen ein anderer PC
        Connect-Target
        $script:Calls[1].State.Comp | Should -Be 'PC01'
        $p2 = @((New-ZielProfile 'S-A' 'PC01\anna' $true), (New-ZielProfile 'S-C' 'PC01\cara'), (New-ZielProfile 'S-B' 'PC01\bert'))
        & $script:Calls[1].OnComplete ([pscustomobject]@{ Profiles = $p2; Error = $null; WinRM = $null }) $script:Calls[1].State
        $ui.cmbUser.SelectedIndex | Should -Be 2
    }
    It 'zweites Neuladen waehrend das erste noch verbindet: Auswahl bleibt erhalten' {
        $ui.cmbComputer.Text = 'PC01'; Connect-Target -FromField
        $p = @((New-ZielProfile 'S-A' 'PC01\anna' $true), (New-ZielProfile 'S-B' 'PC01\bert'))
        & $script:Calls[0].OnComplete ([pscustomobject]@{ Profiles = $p; Error = $null; WinRM = $null }) $script:Calls[0].State
        $ui.cmbUser.SelectedIndex = 1
        Connect-Target
        $ui.cmbUser.SelectedIndex = -1   # Liste ist beim Neuladen leer (wie im Fenster)
        Connect-Target
        & $script:Calls[1].OnComplete ([pscustomobject]@{ Profiles = $p; Error = $null; WinRM = $null }) $script:Calls[1].State
        & $script:Calls[2].OnComplete ([pscustomobject]@{ Profiles = $p; Error = $null; WinRM = $null }) $script:Calls[2].State
        $ui.cmbUser.SelectedIndex | Should -Be 1
    }
    It 'anderer PC: eingetipptes Konto des bisherigen PCs wird geleert, gleicher PC behaelt es' {
        $ui.cmbComputer.Text = 'PC01'; Connect-Target -FromField
        & $script:Calls[0].OnComplete ([pscustomobject]@{ Profiles = @(New-ZielProfile 'S-A' 'PC01\anna'); Error = $null; WinRM = $null }) $script:Calls[0].State
        $ui.cmbUser.Text = 'PC01\neu'
        Connect-Target
        $ui.cmbUser.Text | Should -Be 'PC01\neu'
        $ui.cmbComputer.Text = 'PC02'; Connect-Target -FromField
        $ui.cmbUser.Text | Should -Be ''
    }
    It 'Gescheitertes Verbinden: Ziel ist der PC aus dem Feld, Benutzerliste leer' {
        Connect-Target -FromField
        & $script:Calls[0].OnComplete 'FEHLER: Timeout' $script:Calls[0].State
        $script:Target.Computer | Should -Be 'PC02'
        $script:Target.Connected | Should -BeFalse
        $script:Target.Connecting | Should -BeFalse
        @($script:Profiles).Count | Should -Be 0
        $script:LastStatus | Should -Be 'Fehler'
    }
}

Describe 'Ziel: Vorauswahl nach dem Verbinden' {
    It 'gleicher PC: SID, sonst Konto (nach USMT), sonst Konto ohne Domaene' {
        $l = @((New-ZielProfile 'S-A' 'PC01\anna' $true), (New-ZielProfile 'S-B' 'PC01\bert'))
        Select-HMProfileIndex $l ([pscustomobject]@{ SID = 'S-B'; Account = 'PC01\bert' }) $true $false '' | Should -Be 1
        Select-HMProfileIndex $l ([pscustomobject]@{ SID = $null; Account = 'pc01\BERT' }) $true $false '' | Should -Be 1
        Select-HMProfileIndex $l ([pscustomobject]@{ SID = $null; Account = 'bert' }) $true $false '' | Should -Be 1
    }
    It 'Auswahl behalten erkennt dieselben Faelle wie die Vorauswahl (keine falsche Warnung)' {
        $p = New-ZielProfile 'S-B' 'PC01\bert'
        Test-HMProfileKept $p ([pscustomobject]@{ SID = 'S-B'; Account = 'PC01\bert' }) | Should -BeTrue
        Test-HMProfileKept $p ([pscustomobject]@{ SID = $null; Account = 'pc01\BERT' }) | Should -BeTrue
        Test-HMProfileKept $p ([pscustomobject]@{ SID = $null; Account = 'bert' }) | Should -BeTrue
        Test-HMProfileKept $p ([pscustomobject]@{ SID = 'S-X'; Account = 'PC01\xaver' }) | Should -BeFalse
        Test-HMProfileKept $p $null | Should -BeFalse
    }
    It 'anderer PC oder Benutzer weg: angemeldet, geladen, zuletzt verwendet; leer = -1' {
        $l = @((New-ZielProfile 'S-A' 'PC01\anna' $false $false '2026-01-01'), (New-ZielProfile 'S-B' 'PC01\bert' $false $true '2025-01-01'), (New-ZielProfile 'S-C' 'PC01\cara' $true))
        Select-HMProfileIndex $l ([pscustomobject]@{ SID = 'S-B' }) $false $false '' | Should -Be 2
        Select-HMProfileIndex $l ([pscustomobject]@{ SID = 'S-X'; Account = 'PC01\xaver' }) $true $false '' | Should -Be 2
        Select-HMProfileIndex @($l[0], $l[1]) $null $false $false '' | Should -Be 1
        Select-HMProfileIndex @($l[0]) $null $false $false '' | Should -Be 0
        Select-HMProfileIndex @((New-ZielProfile 'S-A' 'PC01\anna' $true), (New-ZielProfile 'S-ME' 'PC01\ich' $true)) $null $false $true 'S-ME' | Should -Be 1
        Select-HMProfileIndex @() $null $false $false '' | Should -Be -1
    }
}

Describe 'Ziel: Rueckfrage beim Start eines Vorgangs' {
    BeforeAll {
        . ([scriptblock]::Create((Get-ZielFn 'Get-HMFieldComputer')))
        . ([scriptblock]::Create((Get-ZielFn 'Confirm-HMTarget')))
        . ([scriptblock]::Create((Get-ZielFn 'Test-HMBackupRestoreRunning')))
        function Out-Console { }
        function Update-HMTargetLabel { }
        function Connect-Target([switch]$FromField) { $script:Connected = "FromField=$([bool]$FromField)" }
        function Show-HMDialogBox { param($Owner, $Text, $Title, $Mode, $Icon, $Default) $script:Asked = @{ Text = $Text; Mode = $Mode; Default = $Default }; return $script:Answer }
    }
    BeforeEach { $script:Asked = $null; $script:Connected = $null; $script:UserMode = $false; $script:JobRunning = $false; $script:JobTitle = ''; $script:Target = @{ Computer = 'PC01'; Connected = $true }; $ui = @{ cmbComputer = [pscustomobject]@{ Text = 'PC02' } } }
    It 'Feld passt: keine Rueckfrage' {
        $ui.cmbComputer.Text = 'pc01'
        Confirm-HMTarget 'Backup' | Should -BeTrue
        $script:Asked | Should -BeNullOrEmpty
        $script:HMTargetDeclined | Should -BeFalse
    }
    It 'Ja: auf dem verbundenen PC, Feld wird zurueckgesetzt; verbindet nie' {
        $script:Answer = 'Yes'
        Confirm-HMTarget 'Backup' | Should -BeTrue
        $ui.cmbComputer.Text | Should -Be 'PC01'
        $script:Asked.Mode | Should -Be 'YesNo'
        $script:Asked.Default | Should -Be 'No'
        $script:Connected | Should -BeNullOrEmpty
    }
    It 'Nein oder Schliessen: nichts, Ablehnung wird gemerkt' {
        $script:Answer = 'No'
        Confirm-HMTarget 'Backup' | Should -BeFalse
        $ui.cmbComputer.Text | Should -Be 'PC02'
        $script:Connected | Should -BeNullOrEmpty
        $script:HMTargetDeclined | Should -BeTrue
    }
    It 'waehrend Backup/Restore dieselbe Belegung; bei anderen Vorgaengen die normale Variante' {
        $script:JobRunning = $true; $script:JobTitle = 'Restore'; $script:Answer = 'No'
        Confirm-HMTarget "'Netzwerktest'" | Should -BeFalse
        $script:Asked.Text | Should -Match "Waehrend 'Restore' laeuft"
        $script:Asked.Default | Should -Be 'No'
        $script:JobTitle = 'Groesse ermitteln'
        Confirm-HMTarget "'Netzwerktest'" | Should -BeFalse
        $script:Asked.Text | Should -Not -Match 'Waehrend'
        $script:Answer = 'Yes'; $script:JobTitle = 'Restore'
        Confirm-HMTarget "'Netzwerktest'" | Should -BeTrue
        $ui.cmbComputer.Text | Should -Be 'PC01'
        $script:Connected | Should -BeNullOrEmpty
    }
    It 'Benutzer-Modus: keine Rueckfrage' {
        $script:UserMode = $true
        Confirm-HMTarget 'Backup' | Should -BeTrue
        $script:Asked | Should -BeNullOrEmpty
    }
    It 'Knoepfe mit Benutzerbezug fragen vor allem anderen, Verbinden nur aus dem Feld' {
        $script:MainSrc | Should -Match "btnBackup\.Add_Click\(\{\r?\n    if \(-not \(Confirm-HMTarget 'Backup'\)\) \{ return \}\r?\n    \`$p = Get-SelectedProfile"
        $script:MainSrc | Should -Match "if \(-not \(Confirm-HMTarget 'Restore'\)\) \{ return \}\r?\n    \`$b = \`$script:SelectedBackup"
        $script:MainSrc | Should -Match '\$ui\.btnConnect\.Add_Click\(\{ Connect-Target -FromField \}\)'
        $script:MainSrc | Should -Match "Add_KeyDown\(\{ if \(\`$_\.Key -eq 'Return'\) \{ Connect-Target -FromField \} \}\)"
    }
}

Describe 'Ziel: Werkzeuge (Busy, nur PC, Benutzer)' {
    BeforeAll {
        . ([scriptblock]::Create((Get-ZielFn 'Get-HMFieldComputer')))
        . ([scriptblock]::Create((Get-ZielFn 'Test-HMToolStart')))
        . ([scriptblock]::Create((Get-ZielFn 'Test-HMBackupRestoreRunning')))
        . ([scriptblock]::Create((Get-ZielFn 'Select-HMFieldTarget')))
        . ([scriptblock]::Create((Get-ZielFn 'Use-HMPcTarget')))
        function Out-Console { }
        function Update-HMTargetLabel { }
        function Update-RestoreTargetLabel { }
        function Set-ConnectStatus { param($t, $c) $script:LastStatus = $t }
        function Confirm-HMTarget([string]$Action) { $script:TargetAsked = $Action; return $script:TargetOk }
        function Show-HMDialogBox { param($Owner, $Text, $Title, $Mode, $Icon, $Default) $script:Asked = @{ Text = $Text; Mode = $Mode; Default = $Default }; return $script:Answer }
    }
    BeforeEach {
        $script:Asked = $null; $script:TargetAsked = $null; $script:TargetOk = $true; $script:JobRunning = $false; $script:JobTitle = ''; $script:UserMode = $false; $script:LastStatus = $null
        $script:Target = @{ Computer = 'PC01'; Connected = $true }; $script:ConnectSeq = 4; $script:Profiles = @(New-ZielProfile 'S-A' 'PC01\anna')
        $ui = @{ cmbComputer = [pscustomobject]@{ Text = 'PC01' }; cmbUser = [pscustomobject]@{ Items = (New-Object System.Collections.ArrayList); Text = 'PC01\anna' }; lblSid = [pscustomobject]@{ Text = 'C:\Users\anna' } }
        [void]$ui.cmbUser.Items.Add('PC01\anna')
    }
    It 'nur PC (z.B. Laufwerke C$, Wake-on-LAN): anderer PC im Feld - ohne Rueckfrage umschalten, Benutzer von PC01 verworfen' {
        $ui.cmbComputer.Text = 'PC02'
        Test-HMToolStart @{ Kind = 'Pc'; Busy = $false; Name = 'Laufwerke (C$)' } | Should -BeTrue
        $script:Asked | Should -BeNullOrEmpty
        $script:TargetAsked | Should -BeNullOrEmpty
        $script:Target.Computer | Should -Be 'PC02'
        $script:Target.Connected | Should -BeFalse
        $script:Target.Chosen | Should -BeTrue
        @($script:Profiles).Count | Should -Be 0
        $ui.cmbUser.Items.Count | Should -Be 0
        $ui.cmbUser.Text | Should -Be ''
        $script:ConnectSeq | Should -Be 5
        $script:LastStatus | Should -Be 'Gewaehlt: PC02 (nicht verbunden)'
        (Get-HMTargetLabel (Get-HMTargetState 'PC02' $script:Target 'EIGEN')).Text | Should -Be 'gewaehlt: PC02 (nicht verbunden, Benutzerliste leer)'
    }
    It 'nur PC, Feld passt: nichts aendert sich' {
        Test-HMToolStart @{ Kind = 'Pc'; Busy = $false; Name = 'Netzwerktest' } | Should -BeTrue
        $script:Target.Connected | Should -BeTrue
        @($script:Profiles).Count | Should -Be 1
    }
    It 'nur PC waehrend Backup/Restore: nicht umschalten, Rueckfrage; waehrend anderer Vorgaenge: umschalten' {
        $ui.cmbComputer.Text = 'PC02'; $script:JobRunning = $true; $script:JobTitle = 'Backup'
        Test-HMToolStart @{ Kind = 'Pc'; Busy = $false; Name = 'Netzwerktest' } | Should -BeTrue
        $script:TargetAsked | Should -Be "'Netzwerktest'"
        $script:Target.Computer | Should -Be 'PC01'
        $script:JobTitle = 'Groesse ermitteln'; $script:TargetAsked = $null
        Test-HMToolStart @{ Kind = 'Pc'; Busy = $false; Name = 'Netzwerktest' } | Should -BeTrue
        $script:TargetAsked | Should -BeNullOrEmpty
        $script:Target.Computer | Should -Be 'PC02'
    }
    It 'Benutzer (z.B. Profil erneuern): Rueckfrage, abgelehnt = nichts; ohne Ziel: keine Pruefung' {
        $ui.cmbComputer.Text = 'PC02'; $script:TargetOk = $false
        Test-HMToolStart @{ Kind = 'User'; Busy = $false; Name = 'Profil erneuern (Test)' } | Should -BeFalse
        $script:TargetAsked | Should -Be "'Profil erneuern (Test)'"
        $script:Target.Computer | Should -Be 'PC01'
        $script:TargetAsked = $null
        Test-HMToolStart @{ Kind = 'None'; Busy = $false; Name = 'Inventar (mehrere PCs)' } | Should -BeTrue
        $script:TargetAsked | Should -BeNullOrEmpty
        $script:Target.Computer | Should -Be 'PC01'
    }
    It 'Knoepfe ausserhalb der Leisten, die nur den PC brauchen (Software, Treiber, Links): ebenso umschalten' {
        $ui.cmbComputer.Text = 'PC02'
        Use-HMPcTarget 'Softwareverteilung' | Should -BeTrue
        $script:Target.Computer | Should -Be 'PC02'
        $script:Asked | Should -BeNullOrEmpty
    }
    It 'Busy: Rueckfrage nur waehrend Backup oder Restore, Standard Nein' {
        $script:JobRunning = $true; $script:JobTitle = 'Backup'; $script:Answer = 'No'
        Test-HMToolStart @{ Kind = 'Pc'; Busy = $true; Name = 'Neustart / Herunterfahren' } | Should -BeFalse
        $script:Asked.Mode | Should -Be 'YesNo'
        $script:Asked.Default | Should -Be 'No'
        $script:Asked.Text | Should -Match "^Es laeuft gerade: Backup\.\s+'Neustart / Herunterfahren' greift in den PC bzw\. das Benutzerprofil ein und kann den laufenden Vorgang stoeren\.\s+Trotzdem ausfuehren\?$"
        $script:Answer = 'Yes'
        Test-HMToolStart @{ Kind = 'Pc'; Busy = $true; Name = 'Neustart / Herunterfahren' } | Should -BeTrue
        foreach ($t in @('Groesse ermitteln', 'Backup pruefen', 'Server-Backup', 'Updates suchen')) {
            $script:Asked = $null; $script:JobTitle = $t
            Test-HMToolStart @{ Kind = 'Pc'; Busy = $true; Name = 'Neustart / Herunterfahren' } | Should -BeTrue
            $script:Asked | Should -BeNullOrEmpty
        }
    }
    It 'Zuordnung der Werkzeuge (Busy, Benutzer, ohne Ziel) und Weitergabe an Links- und Rechtsklick' {
        $f = Get-ZielFn 'Add-ToolButton'
        ([regex]::Matches($f, 'Test-HMToolStart \$src\.Tag')).Count | Should -Be 2
        foreach ($n in @('Umbenennen', 'IP-Adresse / DHCP', 'Neustart / Herunterfahren', 'Profil erneuern \(Test\)', 'Profil zurueckholen', 'Profilordner umbenennen', 'Profil anderem Konto zuweisen', 'Alte Profile loeschen')) {
            $script:MainSrc | Should -Match "(?m)^Add-ToolButton \`$t[cp] '$n' .* -Busy"
        }
        foreach ($n in @('Profil erneuern \(Test\)', 'Profilordner umbenennen', 'Profil anderem Konto zuweisen', 'Windows-Apps neu registrieren', 'Gruppenrichtlinien-Ergebnis', 'Datenbanken suchen')) {
            $script:MainSrc | Should -Match "(?m)^Add-ToolButton \`$tp '$n' .* -User\r?$"
        }
        foreach ($n in @('Geraete \(AD\) / Mehrfach', 'USMT einrichten \(ADK\)', 'Inventar \(mehrere PCs\)', 'HUPilot \.\.\.', 'Im Backup suchen')) {
            $script:MainSrc | Should -Match "(?m)^Add-ToolButton \`$t[cp] '$n' .* -NoTarget\r?$"
        }
        $script:MainSrc | Should -Not -Match 'FieldOk'
    }
}

Describe 'Ziel: Umzugs-Assistent bei abgelehnter Rueckfrage' {
    BeforeAll {
        $wa = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Root 'Functions\UI-Wizard.ps1'), [ref]$null, [ref]$null)
        . ([scriptblock]::Create(@($wa.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'Invoke-HMWizardAction' }, $true))[0].Extent.Text))
        function Test-HMWizSelection { $true }
        function Select-HMMainTab { }
        function Set-HMWizDone($n) { $script:Done.Add($n) }
        function Save-HMWizState { }
        function Update-HMWizard { }
        function Out-Console { }
        function Invoke-HMMainButton($b) { $script:HMTargetDeclined = $script:Decline }
    }
    BeforeEach { $script:Done = New-Object System.Collections.Generic.List[int]; $script:JobRunning = $false; $script:WizWaitFor = $null; $ui = @{ btnPrecheck = 'p'; btnBackup = 'b' } }
    It 'Schritt 2: abgelehnt = nicht erledigt, sonst erledigt' {
        $script:WizState = [pscustomobject]@{ Step = 2; Source = 'x' }
        $script:Decline = $true; Invoke-HMWizardAction
        $script:Done.Count | Should -Be 0
        $script:Decline = $false; Invoke-HMWizardAction
        @($script:Done) | Should -Be @(2)
    }
    It 'Schritt 3: abgelehnt = es wird auf kein Backup gewartet' {
        $script:WizState = [pscustomobject]@{ Step = 3; Source = 'x' }
        $script:Decline = $true; Invoke-HMWizardAction
        $script:WizWaitFor | Should -BeNullOrEmpty
        $script:Decline = $false; Invoke-HMWizardAction
        $script:WizWaitFor | Should -Be 'Backup'
    }
}

Describe 'Ziel: Backups nicht still loeschen, die gerade benutzt werden' {
    It 'Pfade: gleich, darunter, darueber; kein Treffer bei aehnlichem Namen' {
        Get-HMPathConflict @('X:\BACKUPS\A') @('x:\backups\a\') | Should -Be 'X:\BACKUPS\A'
        Get-HMPathConflict @('X:\BACKUPS\A\_GELOESCHT') @('X:\BACKUPS\A') | Should -Be 'X:\BACKUPS\A\_GELOESCHT'
        Get-HMPathConflict @('X:\BACKUPS\A') @('X:\BACKUPS\A\_GELOESCHT') | Should -Be 'X:\BACKUPS\A'
        Get-HMPathConflict @('X:\BACKUPS\A') @('X:\BACKUPS\AB') | Should -BeNullOrEmpty
        Get-HMPathConflict @('X:\BACKUPS\A') @() | Should -BeNullOrEmpty
        # mehrere gegen mehrere (Treffer nicht nur beim letzten Element)
        Get-HMPathConflict @('X:\n', 'X:\b1') @('X:\b1', 'X:\b2') | Should -Be 'X:\b1'
        Get-HMPathConflict @('X:\n', 'X:\m') @('X:\b1', 'X:\b2') | Should -BeNullOrEmpty
        Get-HMPathConflict @('') @('X:\BACKUPS\A') | Should -BeNullOrEmpty
    }
    It 'benutzte Pfade eines Vorgangs: Backup-Ziel, weitergefuehrtes Backup, Restore-Quelle' {
        @(Get-HMCtxPaths @{ BackupPath = 'X:\B\neu'; ExistingBackup = 'X:\B\alt' }) | Should -Be @('X:\B\neu', 'X:\B\alt')
        @(Get-HMCtxPaths @{ Backup = [pscustomobject]@{ Path = 'X:\B\r' } }) | Should -Be @('X:\B\r')
        @(Get-HMCtxPaths @{ CompareA = 'X:\B\1'; CompareB = 'X:\B\2' }) | Should -Be @('X:\B\1', 'X:\B\2')
        @(Get-HMCtxPaths @{ Kind = 'Setup' }).Count | Should -Be 0
        @(Get-HMCtxPaths $null).Count | Should -Be 0
    }
    It 'Warntexte' {
        Get-HMDeleteWarning 'B1' 'Restore' | Should -Match "(?s)^ACHTUNG: Das Backup 'B1' wird gerade vom laufenden Vorgang 'Restore' benutzt.*Trotzdem jetzt loeschen\?$"
        Get-HMDeleteWarning 'B1' 'Restore' | Should -Match '\(der Restore liest daraus\)'
        Get-HMDeleteWarning 'B1' 'Backup' | Should -Match '\(das Backup schreibt hinein\)'
        Get-HMDeleteWarning 'B1' 'Backup pruefen' | Should -Match '\(die Pruefung liest daraus\)'
        Get-HMDeleteWarning 'B1' 'Backups vergleichen' | Should -Match '\(der Vergleich liest daraus\)'
        Get-HMDeleteWarning 'B1' 'Restore-Vorschau' | Should -Match '\(die Vorschau liest daraus\)'
        Get-HMDeleteWarning 'B1' 'Groesse ermitteln' | Should -Match '\(der Vorgang arbeitet damit\)'
        Get-HMDeletingWarning 'B1' 'Restore' | Should -Match "(?s)^ACHTUNG: Das Backup 'B1' wird gerade geloescht\..*Restore wuerde damit arbeiten.*Trotzdem starten\?$"
    }
    Context 'Rueckfrage im Hauptfenster' {
        BeforeAll {
            . ([scriptblock]::Create((Get-ZielFn 'Confirm-HMBackupNotInUse')))
            function Out-Console { }
            function Show-HMDialogBox { param($Owner, $Text, $Title, $Mode, $Icon, $Default) $script:Asked = @{ Text = $Text; Mode = $Mode; Default = $Default }; return $script:Answer }
        }
        BeforeEach { $script:Asked = $null; $script:JobRunning = $true; $script:JobTitle = 'Restore'; $script:JobCtx = @{ Backup = [pscustomobject]@{ Path = 'X:\B\r' } } }
        It 'Restore laeuft aus diesem Backup: Warnung mit Standard Nein' {
            $script:Answer = 'No'
            Confirm-HMBackupNotInUse @('X:\B\r') 'r' | Should -BeFalse
            $script:Asked.Default | Should -Be 'No'
            $script:Asked.Text | Should -Match "vom laufenden Vorgang 'Restore' benutzt"
            $script:Answer = 'Yes'
            Confirm-HMBackupNotInUse @('X:\B\r\_GELOESCHT') 'r' | Should -BeTrue
        }
        It 'anderes Backup oder kein Vorgang: keine Rueckfrage' {
            Confirm-HMBackupNotInUse @('X:\B\anders') 'anders' | Should -BeTrue
            $script:JobRunning = $false
            Confirm-HMBackupNotInUse @('X:\B\r') 'r' | Should -BeTrue
            $script:Asked | Should -BeNullOrEmpty
        }
    }
    Context 'Vorgang starten, waehrend das Backup geloescht wird; Start scheitert' {
        BeforeAll {
            . ([scriptblock]::Create((Get-ZielFn 'Start-EngineJob')))
            function Out-Console { }
            function Set-Status { param($t, $c) $script:Status = $t }
            function New-JobState { @{} }
            function Set-JobUi([bool]$Running) { $script:UiCalls.Add($Running) }
            function Set-HMTaskbarProgress { }
            function Start-LongJob { $script:LongJobStarted = $true; if ($script:LongJobThrows) { throw 'kaputt' } }
            function Show-HMDialogBox { param($Owner, $Text, $Title, $Mode, $Icon, $Default) $script:Asked = @{ Text = $Text; Default = $Default }; return $script:Answer }
        }
        BeforeEach {
            $script:UiCalls = New-Object System.Collections.Generic.List[bool]; $script:LongJobStarted = $false; $script:LongJobThrows = $false; $script:Asked = $null
            $script:HMDeleting = New-Object System.Collections.Generic.List[string]; $script:CurrentJob = $null; $script:JobCtx = $null
            $ui = @{ pbMain = [pscustomobject]@{ Value = 0 } }
        }
        It 'Backup wird geloescht: Warnung, bei Nein startet nichts' {
            $script:HMDeleting.Add('X:\B\r')
            $script:Answer = 'No'
            Start-EngineJob -Command 'x' -Ctx @{ Backup = [pscustomobject]@{ Path = 'X:\B\r' } } -Title 'Restore' -ScriptFiles @('a')
            $script:Asked.Default | Should -Be 'No'
            $script:LongJobStarted | Should -BeFalse
            $script:UiCalls.Count | Should -Be 0
        }
        It 'anderes Backup wird geloescht: startet ohne Rueckfrage und merkt sich den Kontext' {
            $script:HMDeleting.Add('X:\B\anders')
            $ctx = @{ Backup = [pscustomobject]@{ Path = 'X:\B\r' } }
            Start-EngineJob -Command 'x' -Ctx $ctx -Title 'Restore' -ScriptFiles @('a')
            $script:Asked | Should -BeNullOrEmpty
            $script:LongJobStarted | Should -BeTrue
            $script:JobCtx | Should -Be $ctx
        }
        It 'Start wirft: Oberflaeche wird wieder freigegeben ("Vorgang laeuft" zurueck)' {
            $script:LongJobThrows = $true
            Start-EngineJob -Command 'x' -Ctx @{} -Title 'Backup' -ScriptFiles @('a')
            @($script:UiCalls) | Should -Be @($true, $false)
            $script:CurrentJob | Should -BeNullOrEmpty
            $script:Status | Should -Be 'Backup nicht gestartet'
        }
    }
    Context 'Fenster Alte loeschen (nicht modal)' {
        BeforeAll {
            . (Join-Path $script:Root 'Functions\UI-Quality.ps1')
            . ([scriptblock]::Create((Get-ZielFn 'Add-HMDeleting')))
            . ([scriptblock]::Create((Get-ZielFn 'Remove-HMDeleting')))
            function Out-Console { }
            function Update-BackupList { }
            function Update-BackupRootInfo { }
            function Get-BackupRoot { $script:CurRoot }
            function Invoke-AsyncCommand { param($ScriptBlock, $ArgumentList, $TimeoutSec, $State, $OnComplete) $script:Async = @{ Args = $ArgumentList; State = $State; OnComplete = $OnComplete } }
            function Show-HMDialogBox { param($Owner, $Text, $Title, $Mode, $Icon, $Default) $script:Texts.Add("$Text"); return $script:Answers.Dequeue() }
        }
        BeforeEach {
            $script:Async = $null; $script:Texts = New-Object System.Collections.Generic.List[string]; $script:Answers = New-Object System.Collections.Queue
            $script:CurRoot = 'X:\B'; $script:BackupInfos = @(); $script:JobRunning = $false; $script:JobCtx = $null; $script:JobTitle = ''
            $script:HMDeleting = New-Object System.Collections.Generic.List[string]; $script:Engine = 'x'
            $script:Win = [pscustomobject]@{ Closed = $false } | Add-Member -MemberType ScriptMethod -Name Close -Value { $this.Closed = $true } -PassThru
        }
        It 'Backup-Ordner inzwischen gewechselt: nichts loeschen' {
            $script:CurRoot = 'Y:\NEU'
            $script:Answers.Enqueue('OK')
            Remove-HMBackupFolders $script:Win 'X:\B' @('alt1')
            $script:Async | Should -BeNullOrEmpty
            $script:Texts[0] | Should -Match 'Backup-Ordner wurde gewechselt'
        }
        It 'Restore laeuft aus einem der Backups: deutliche Warnung, bei Nein nichts' {
            $script:JobRunning = $true; $script:JobTitle = 'Restore'; $script:JobCtx = @{ Backup = [pscustomobject]@{ Path = 'X:\B\alt1' } }
            $script:Answers.Enqueue('Yes'); $script:Answers.Enqueue('No')
            Remove-HMBackupFolders $script:Win 'X:\B' @('alt1', 'alt2')
            $script:Async | Should -BeNullOrEmpty
            $script:Win.Closed | Should -BeFalse
            $script:Texts[1] | Should -Match "Das Backup 'alt1' wird gerade vom laufenden Vorgang 'Restore' benutzt"
        }
        It 'ohne Konflikt: loescht, merkt die Pfade bis zum Ende der Loeschung' {
            $script:Answers.Enqueue('Yes')
            Remove-HMBackupFolders $script:Win 'X:\B' @('alt1')
            $script:Async | Should -Not -BeNullOrEmpty
            $script:Win.Closed | Should -BeTrue
            @($script:HMDeleting) | Should -Be @('X:\B\alt1')
            function Update-HMBackupOverview { }
            & $script:Async.OnComplete @('OK X:\B\alt1') $script:Async.State
            $script:HMDeleting.Count | Should -Be 0
        }
    }
}
