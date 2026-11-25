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
        Test-HMSameComputer 'pc01' 'PC01' 'EIGEN' | Should -BeTrue
        Test-HMSameComputer '' 'EIGEN' 'EIGEN' | Should -BeTrue
        Test-HMSameComputer 'localhost' '.' 'EIGEN' | Should -BeTrue
        Test-HMSameComputer 'eigen.schule.local' 'EIGEN' 'EIGEN' | Should -BeTrue
        Test-HMSameComputer 'PC01.schule.local' 'PC01' 'EIGEN' | Should -BeTrue
        Test-HMSameComputer 'PC01.a.local' 'PC01.b.local' 'EIGEN' | Should -BeFalse
        Test-HMSameComputer 'PC01' 'PC02' 'EIGEN' | Should -BeFalse
        Test-HMSameComputer 'PC01' 'EIGEN' 'EIGEN' | Should -BeFalse
        Test-HMSameComputer '203.0.113.5' '203' 'EIGEN' | Should -BeFalse
        Test-HMSameComputer '203.0.113.5' '203.0.113.5' 'EIGEN' | Should -BeTrue
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
    It 'Rueckfrage nur bei Unterschied, mit klarer Wahl (als Satz gelesen)' {
        Get-HMTargetQuestion (Get-HMTargetState 'PC01' @{ Computer = 'PC01'; Connected = $true } 'EIGEN') 'Backup' | Should -BeNullOrEmpty
        $q = Get-HMTargetQuestion (Get-HMTargetState 'PC02' @{ Computer = 'PC01'; Connected = $true } 'EIGEN') 'Backup'
        $q | Should -Match '^Im Feld Computer steht PC02, verbunden ist PC01\.'
        $q | Should -Match 'Backup wuerde auf PC01 laufen, nicht auf PC02\.'
        $q | Should -Match 'Ja = zuerst mit PC02 verbinden \(Backup startet danach nicht von selbst\)'
        $q | Should -Match 'Nein = Backup auf PC01 ausfuehren \(das Feld wird auf PC01 zurueckgesetzt\)'
        $q | Should -Match 'Abbrechen = nichts tun$'
        (Get-HMTargetQuestion (Get-HMTargetState 'PC02' @{ Computer = 'PC01'; Connecting = $true } 'EIGEN') 'Restore') | Should -Match 'die Verbindung zu PC01 wird gerade aufgebaut'
        (Get-HMTargetQuestion (Get-HMTargetState 'PC02' @{ Computer = 'PC01' } 'EIGEN') 'Restore') | Should -Match 'gewaehlt ist PC01 \(nicht verbunden\)'
        # waehrend eines Vorgangs: kein Verbinden anbieten
        $q = Get-HMTargetQuestion (Get-HMTargetState 'PC02' @{ Computer = 'PC01'; Connected = $true } 'EIGEN') "'Netzwerktest'" 'Restore'
        $q | Should -Match "Waehrend 'Restore' laeuft, wird nicht neu verbunden\."
        $q | Should -Match "Ja = 'Netzwerktest' auf PC01 ausfuehren \(das Feld wird auf PC01 zurueckgesetzt\)"
        $q | Should -Match 'Nein = nichts tun \(mit PC02 erst nach dem Vorgang verbinden: Enter oder Verbinden\)$'
        $q | Should -Not -Match 'zuerst mit'
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
        $ui = @{ cmbComputer = [pscustomobject]@{ Text = 'PC02' }; cmbUser = [pscustomobject]@{ Items = (New-Object System.Collections.ArrayList); SelectedIndex = -1 }; lblSid = [pscustomobject]@{ Text = '' } }
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
        function Out-Console { }
        function Update-HMTargetLabel { }
        function Connect-Target([switch]$FromField) { $script:Connected = "FromField=$([bool]$FromField)" }
        function Show-HMDialogBox { param($Owner, $Text, $Title, $Mode, $Icon, $Default) $script:Asked = @{ Text = $Text; Mode = $Mode; Default = $Default }; return $script:Answer }
    }
    BeforeEach { $script:Asked = $null; $script:Connected = $null; $script:UserMode = $false; $script:JobRunning = $false; $script:Target = @{ Computer = 'PC01'; Connected = $true }; $ui = @{ cmbComputer = [pscustomobject]@{ Text = 'PC02' } } }
    It 'Feld passt: keine Rueckfrage' {
        $ui.cmbComputer.Text = 'pc01'
        Confirm-HMTarget 'Backup' | Should -BeTrue
        $script:Asked | Should -BeNullOrEmpty
    }
    It 'Ja: zuerst mit dem PC im Feld verbinden, Vorgang startet nicht' {
        $script:Answer = 'Yes'
        Confirm-HMTarget 'Backup' | Should -BeFalse
        $script:Connected | Should -Be 'FromField=True'
        $script:Asked.Mode | Should -Be 'YesNoCancel'
        $script:Asked.Default | Should -Be 'Cancel'
    }
    It 'Nein: auf dem verbundenen PC, Feld wird zurueckgesetzt' {
        $script:Answer = 'No'
        Confirm-HMTarget 'Backup' | Should -BeTrue
        $ui.cmbComputer.Text | Should -Be 'PC01'
        $script:Connected | Should -BeNullOrEmpty
    }
    It 'Abbrechen oder Schliessen: nichts' {
        $script:Answer = 'Cancel'
        Confirm-HMTarget 'Backup' | Should -BeFalse
        $ui.cmbComputer.Text | Should -Be 'PC02'
        $script:Connected | Should -BeNullOrEmpty
    }
    It 'waehrend eines Vorgangs: nie neu verbinden, Ja = auf dem Ziel, Standard Nein' {
        $script:JobRunning = $true; $script:JobTitle = 'Restore'
        $script:Answer = 'No'
        Confirm-HMTarget "'Netzwerktest'" | Should -BeFalse
        $script:Asked.Mode | Should -Be 'YesNo'
        $script:Asked.Default | Should -Be 'No'
        $script:Connected | Should -BeNullOrEmpty
        $ui.cmbComputer.Text | Should -Be 'PC02'
        $script:Answer = 'Yes'
        Confirm-HMTarget "'Netzwerktest'" | Should -BeTrue
        $script:Connected | Should -BeNullOrEmpty
        $ui.cmbComputer.Text | Should -Be 'PC01'
        $script:JobRunning = $false
    }
    It 'Benutzer-Modus: keine Rueckfrage' {
        $script:UserMode = $true
        Confirm-HMTarget 'Backup' | Should -BeTrue
        $script:Asked | Should -BeNullOrEmpty
    }
    It 'Backup, Restore, Groesse, Vorab-Pruefung und Profilordner fragen vor allem anderen' {
        $script:MainSrc | Should -Match "btnBackup\.Add_Click\(\{\r?\n    if \(-not \(Confirm-HMTarget 'Backup'\)\) \{ return \}\r?\n    \`$p = Get-SelectedProfile"
        $script:MainSrc | Should -Match "if \(-not \(Confirm-HMTarget 'Restore'\)\) \{ return \}\r?\n    \`$b = \`$script:SelectedBackup"
        $script:MainSrc | Should -Match "btnProfileSize\.Add_Click\(\{ if \(Confirm-HMTarget 'Groesse ermitteln'\)"
        $script:MainSrc | Should -Match "if \(-not \(Confirm-HMTarget 'Vorab-Pruefung'\)\) \{ return \}"
        (Get-ZielFn 'Get-SelectedProfilePath') | Should -Match "Confirm-HMTarget 'Ordner oeffnen'"
        $script:MainSrc | Should -Match "btnBackupSchedule\.Add_Click\(\{ if \(Confirm-HMTarget 'Zeitplan'\) \{ New-HMBackupSchedule \} \}\)"
    }
    It 'Verbinden aus dem Feld nur ueber Verbinden, Enter, Lokal und den Geraete-Dialog' {
        $script:MainSrc | Should -Match '\$ui\.btnConnect\.Add_Click\(\{ Connect-Target -FromField \}\)'
        $script:MainSrc | Should -Match "Add_KeyDown\(\{ if \(\`$_\.Key -eq 'Return'\) \{ Connect-Target -FromField \} \}\)"
        $script:MainSrc | Should -Match 'btnLocal\.Add_Click\(\{ .*Connect-Target -FromField \}\)'
        $m = Get-Content -Raw -LiteralPath (Join-Path $script:Root 'Functions\Tools-Multi.ps1') -Encoding UTF8
        $m | Should -Match '(?s)\$ui\.cmbComputer\.Text = "\$\(\$rv\.Row\.Name\)".*?if \(\$script:JobRunning\) \{.*?return \}\r?\n\s+Connect-Target -FromField'
    }
}

Describe 'Ziel: Werkzeuge waehrend Backup/Restore (Merkmal Busy)' {
    BeforeAll {
        . ([scriptblock]::Create((Get-ZielFn 'Test-HMToolStart')))
        function Out-Console { }
        function Confirm-HMTarget([string]$Action) { $script:TargetAsked = $Action; return $script:TargetOk }
        function Show-HMDialogBox { param($Owner, $Text, $Title, $Mode, $Icon, $Default) $script:Asked = @{ Text = $Text; Mode = $Mode; Default = $Default }; return $script:Answer }
    }
    BeforeEach { $script:Asked = $null; $script:TargetAsked = $null; $script:TargetOk = $true; $script:JobRunning = $true; $script:JobTitle = 'Backup' }
    It 'eingreifendes Werkzeug waehrend eines Vorgangs: Rueckfrage mit Standard Nein' {
        $script:Answer = 'No'
        Test-HMToolStart @{ Busy = $true; Target = $true; Name = 'Neustart / Herunterfahren' } | Should -BeFalse
        $script:Asked.Mode | Should -Be 'YesNo'
        $script:Asked.Default | Should -Be 'No'
        $script:Asked.Text | Should -Match "^Es laeuft gerade: Backup\.\s+'Neustart / Herunterfahren' greift in den PC bzw\. das Benutzerprofil ein und kann den laufenden Vorgang stoeren\.\s+Trotzdem ausfuehren\?$"
        $script:TargetAsked | Should -BeNullOrEmpty
        $script:Answer = 'Yes'
        Test-HMToolStart @{ Busy = $true; Target = $true; Name = 'Neustart / Herunterfahren' } | Should -BeTrue
        $script:TargetAsked | Should -Be "'Neustart / Herunterfahren'"
    }
    It 'ohne Vorgang oder ohne Merkmal: keine Rueckfrage; -NoTarget: keine Frage zum Feld' {
        $script:JobRunning = $false
        Test-HMToolStart @{ Busy = $true; Target = $true; Name = 'X' } | Should -BeTrue
        $script:Asked | Should -BeNullOrEmpty
        $script:JobRunning = $true; $script:TargetAsked = $null
        Test-HMToolStart @{ Busy = $false; Target = $false; Name = 'Y' } | Should -BeTrue
        $script:Asked | Should -BeNullOrEmpty
        $script:TargetAsked | Should -BeNullOrEmpty
        $script:TargetOk = $false
        Test-HMToolStart @{ Busy = $false; Target = $true; Name = 'Z' } | Should -BeFalse
    }
    It 'Merkmal wird gesetzt und an Links- und Rechtsklick geprueft; eingreifende Werkzeuge sind gekennzeichnet' {
        $f = Get-ZielFn 'Add-ToolButton'
        $f | Should -Match 'Busy = \[bool\]\$Busy'
        ([regex]::Matches($f, 'Test-HMToolStart \$src\.Tag')).Count | Should -Be 2
        foreach ($n in @('Umbenennen', 'IP-Adresse / DHCP', 'Neustart / Herunterfahren', 'Profil erneuern \(Test\)', 'Profil zurueckholen', 'Profilordner umbenennen', 'Profil anderem Konto zuweisen', 'Alte Profile loeschen')) {
            $script:MainSrc | Should -Match "(?m)^Add-ToolButton \`$t[cp] '$n' .* -Busy\r?$"
        }
        foreach ($n in @('Geraete \(AD\) / Mehrfach', 'USMT einrichten \(ADK\)', 'Inventar \(mehrere PCs\)', 'HUPilot \.\.\.', 'Im Backup suchen')) {
            $script:MainSrc | Should -Match "(?m)^Add-ToolButton \`$t[cp] '$n' .* -NoTarget\r?$"
        }
    }
}

Describe 'Ziel: Backups nicht still loeschen, die gerade benutzt werden' {
    It 'Pfade: gleich, darunter, darueber; kein Treffer bei aehnlichem Namen' {
        Get-HMPathConflict @('X:\BACKUPS\A') @('x:\backups\a\') | Should -Be 'X:\BACKUPS\A'
        Get-HMPathConflict @('X:\BACKUPS\A\_GELOESCHT') @('X:\BACKUPS\A') | Should -Be 'X:\BACKUPS\A\_GELOESCHT'
        Get-HMPathConflict @('X:\BACKUPS\A') @('X:\BACKUPS\A\_GELOESCHT') | Should -Be 'X:\BACKUPS\A'
        Get-HMPathConflict @('X:\BACKUPS\A') @('X:\BACKUPS\AB') | Should -BeNullOrEmpty
        Get-HMPathConflict @('X:\BACKUPS\A') @() | Should -BeNullOrEmpty
        Get-HMPathConflict @('') @('X:\BACKUPS\A') | Should -BeNullOrEmpty
    }
    It 'benutzte Pfade eines Vorgangs: Backup-Ziel, weitergefuehrtes Backup, Restore-Quelle' {
        @(Get-HMCtxPaths @{ BackupPath = 'X:\B\neu'; ExistingBackup = 'X:\B\alt' }) | Should -Be @('X:\B\neu', 'X:\B\alt')
        @(Get-HMCtxPaths @{ Backup = [pscustomobject]@{ Path = 'X:\B\r' } }) | Should -Be @('X:\B\r')
        @(Get-HMCtxPaths @{ Kind = 'Setup' }).Count | Should -Be 0
        @(Get-HMCtxPaths $null).Count | Should -Be 0
    }
    It 'Warntexte' {
        Get-HMDeleteWarning 'B1' 'Restore' | Should -Match "(?s)^ACHTUNG: Das Backup 'B1' wird gerade vom laufenden Vorgang 'Restore' benutzt.*Trotzdem jetzt loeschen\?$"
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
