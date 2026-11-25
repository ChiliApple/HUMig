#Requires -Version 5.1
<#
.SYNOPSIS
    Tests fuer Werkzeuge, Software- und Treiberverteilung, App-Updates, Restore-Vorschau, Katalog und Status (Einzelfehler).
.DESCRIPTION
    Texte, die am Ziel-PC laufen, werden in einem eigenen Prozess mit Ersatzfunktionen ausgefuehrt. Vorher prueft der Test
    per Syntaxbaum, dass jeder aufgerufene Befehl ersetzt oder harmlos ist - am PC wird nichts geaendert.
    Adressen nur aus dem Dokumentationsbereich, zur Laufzeit zusammengesetzt.
#>

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $script:WinPs = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    # harmlose Befehle, die ohne Ersatz laufen duerfen
    $script:SafeCmds = @('New-Object', 'Where-Object', 'ForEach-Object', 'Select-Object', 'Out-Null', 'Join-Path', 'Move-Item', 'Sort-Object', 'Group-Object', 'Measure-Object', 'ConvertTo-Json', 'ConvertFrom-Json', 'Get-Date')
    # Liefert die Namen aller Befehle eines Skripttexts, die weder im Text definiert noch in $Allowed stehen
    function Get-UnstubbedCommands([string]$Text, [string[]]$Allowed) {
        $err = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$null, [ref]$err)
        if (@($err).Count) { throw "Syntaxfehler: $(@($err)[0].Message)" }
        $defs = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })
        $cmds = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ } | Sort-Object -Unique)
        return @($cmds | Where-Object { $defs -notcontains $_ -and $Allowed -notcontains $_ })
    }
    # Skripttext mit Vorspann in einem eigenen Windows-PowerShell-Prozess ausfuehren
    function Invoke-InChild([string]$Prelude, [string]$Text, [string]$Epilog = '') {
        $f = Join-Path $TestDrive ("run_{0}.ps1" -f [guid]::NewGuid().ToString('N'))
        [System.IO.File]::WriteAllText($f, ($Prelude + "`r`n" + $Text + "`r`n" + $Epilog), (New-Object System.Text.UTF8Encoding($true)))
        $o = & $script:WinPs -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $f 2>&1
        return @($o | ForEach-Object { "$_" })
    }
    function New-TestIp([int]$Last) { return (@(192, 0, 2, $Last) -join '.') }
}

Describe 'IP-Adresse aendern (SYSTEM-Aufgabe mit Pruefung und Rueckbau)' {
    BeforeAll {
        . (Join-Path $script:Root 'Functions\Tools-System.ps1')
        # Ersatz fuer die Netzwerk-Befehle: Zustand in $global:T_S, am Ende als JSON in die Datei $global:StateOut
        $script:NetStubs = @'
param()
$global:T_S = (Get-Content -LiteralPath $env:HM_TEST_STATE -Raw | ConvertFrom-Json)
$global:T_Addrs = New-Object System.Collections.ArrayList
foreach ($a in @($global:T_S.Addrs)) { [void]$global:T_Addrs.Add([pscustomobject]@{ IPAddress = $a.IPAddress; PrefixLength = [int]$a.PrefixLength; PrefixOrigin = $a.PrefixOrigin; AddressState = $a.AddressState }) }
$global:T_Gw = New-Object System.Collections.ArrayList; foreach ($g in @($global:T_S.Gw)) { if ($g) { [void]$global:T_Gw.Add($g) } }
$global:T_Dns = @($global:T_S.Dns | Where-Object { $_ }); $global:T_DnsStatic = [bool]$global:T_S.DnsStatic; $global:T_Dhcp = [bool]$global:T_S.Dhcp
function Get-NetIPInterface { [pscustomobject]@{ Dhcp = $(if ($global:T_Dhcp) { 'Enabled' } else { 'Disabled' }) } }
function Get-NetAdapter { [pscustomobject]@{ InterfaceGuid = '{00000000-0000-0000-0000-000000000001}'; Name = 'Ethernet Test' } }
function New-NetRoute { param($InterfaceIndex, $DestinationPrefix, $NextHop, $ErrorAction) [void]$global:T_Gw.Add($NextHop) }
function Get-ItemProperty { [pscustomobject]@{ NameServer = $(if ($global:T_DnsStatic) { ($global:T_Dns -join ',') } else { '' }) } }
function Get-NetIPAddress { @($global:T_Addrs) }
function Get-NetRoute { @($global:T_Gw | ForEach-Object { [pscustomobject]@{ NextHop = $_ } }) }
function Get-DnsClientServerAddress { [pscustomobject]@{ ServerAddresses = @($global:T_Dns) } }
function Remove-NetRoute { $global:T_Gw.Clear() }
function Remove-NetIPAddress { param($InterfaceIndex, $AddressFamily, $PrefixOrigin, [switch]$Confirm, $ErrorAction)
    foreach ($a in @($global:T_Addrs)) { if (-not $PrefixOrigin -or $a.PrefixOrigin -eq $PrefixOrigin) { $global:T_Addrs.Remove($a) } } }
function Set-NetIPInterface { param($InterfaceIndex, $Dhcp, $ErrorAction)
    $global:T_Dhcp = ($Dhcp -eq 'Enabled')
    if ($global:T_Dhcp -and $global:T_S.Lease) { [void]$global:T_Addrs.Add([pscustomobject]@{ IPAddress = $global:T_S.Lease; PrefixLength = 24; PrefixOrigin = 'Dhcp'; AddressState = 'Preferred' }) } }
function Set-DnsClientServerAddress { param($InterfaceIndex, $ServerAddresses, [switch]$ResetServerAddresses)
    if ($ResetServerAddresses) { $global:T_Dns = @(); $global:T_DnsStatic = $false } else { $global:T_Dns = @($ServerAddresses); $global:T_DnsStatic = $true } }
function Start-Process { param($FilePath, $ArgumentList, $WindowStyle) $global:T_Renew = @($ArgumentList) }
function Start-Sleep { }
function New-NetIPAddress { param($InterfaceIndex, $IPAddress, $PrefixLength, $DefaultGateway)
    if ($global:T_S.FailAll -or ($global:T_S.FailNew -and $IPAddress -eq $global:T_S.NewIp)) { throw 'Testfehler beim Anlegen der Adresse' }
    $st = if ($global:T_S.Dup -and $IPAddress -eq $global:T_S.NewIp) { 'Duplicate' } else { 'Preferred' }
    [void]$global:T_Addrs.Add([pscustomobject]@{ IPAddress = $IPAddress; PrefixLength = [int]$PrefixLength; PrefixOrigin = 'Manual'; AddressState = $st })
    if ($DefaultGateway) { [void]$global:T_Gw.Add($DefaultGateway) } }
'@
        $script:NetEpilog = @'
[pscustomobject]@{ Dhcp = $global:T_Dhcp; Addrs = @($global:T_Addrs); Gw = @($global:T_Gw); Dns = @($global:T_Dns); DnsStatic = $global:T_DnsStatic; Renew = @($global:T_Renew) } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $env:HM_TEST_OUT -Encoding UTF8
'@
        $script:NetStubNames = @('Get-NetIPInterface', 'Get-NetAdapter', 'Get-ItemProperty', 'Get-NetIPAddress', 'Get-NetRoute', 'Get-DnsClientServerAddress', 'Remove-NetRoute', 'Remove-NetIPAddress', 'Set-NetIPInterface', 'Set-DnsClientServerAddress', 'Start-Process', 'Start-Sleep', 'New-NetIPAddress', 'New-NetRoute')
        # Fall ausfuehren: Rueckgabe Ergebniszeilen und Endzustand
        $script:RunNet = {
            param([hashtable]$State, [hashtable]$Args1)
            $sf = Join-Path $TestDrive ("state_{0}.json" -f [guid]::NewGuid().ToString('N'))
            $of = "$sf.out"; $rf = "$sf.res.txt"
            $State | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $sf -Encoding UTF8
            $body = New-HMNetChangeScript @Args1 -ResultFile $rf
            $env:HM_TEST_STATE = $sf; $env:HM_TEST_OUT = $of
            try { $o = Invoke-InChild $script:NetStubs $body $script:NetEpilog } finally { Remove-Item Env:\HM_TEST_STATE, Env:\HM_TEST_OUT -ErrorAction SilentlyContinue }
            [string[]]$lines = if (Test-Path -LiteralPath $rf) { @(Get-Content -LiteralPath $rf -Encoding UTF8) } else { @("KEIN ERGEBNIS: $($o -join ' | ')") }
            $end = if (Test-Path -LiteralPath $of) { Get-Content -LiteralPath $of -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
            return [pscustomobject]@{ Lines = $lines; End = $end; Out = $o }
        }
        $script:OldIp = New-TestIp 20; $script:OldGw = New-TestIp 1; $script:OldDns = New-TestIp 53
        $script:NewIp = New-TestIp 30; $script:Lease = New-TestIp 99
        $script:StaticOld = @{ Dhcp = $false; Addrs = @(@{ IPAddress = $script:OldIp; PrefixLength = 24; PrefixOrigin = 'Manual'; AddressState = 'Preferred' }); Gw = @($script:OldGw); Dns = @($script:OldDns); DnsStatic = $true; NewIp = $script:NewIp; Lease = '' }
    }

    It 'ruft am Ziel nur ersetzte oder harmlose Befehle auf (beide Modi)' {
        foreach ($m in @('Static', 'DHCP')) {
            $t = New-HMNetChangeScript -Index 7 -Mode $m -Ip $script:NewIp -Prefix 24 -Gateway $script:OldGw -Dns @($script:OldDns) -ResultFile 'x'
            @(Get-UnstubbedCommands $t ($script:NetStubNames + $script:SafeCmds)) | Should -BeNullOrEmpty
        }
    }
    It 'statische Adresse gelungen: OK erst nach Kontrolle, Werte gesetzt' {
        $r = & $script:RunNet $script:StaticOld @{ Index = 7; Mode = 'Static'; Ip = $script:NewIp; Prefix = 24; Gateway = $script:OldGw; Dns = @($script:OldDns) }
        $r.Lines[0] | Should -Match '^OK statische Adresse'
        @($r.Lines | Where-Object { $_ -match '^FEHLER' }).Count | Should -Be 0
        @($r.End.Addrs | ForEach-Object { $_.IPAddress }) | Should -Contain $script:NewIp
        $r.End.Dhcp | Should -BeFalse
    }
    It 'Anlegen scheitert: FEHLER und alter Zustand (Adresse, Gateway, DNS) wiederhergestellt' {
        $s = $script:StaticOld.Clone(); $s.FailNew = $true
        $r = & $script:RunNet $s @{ Index = 7; Mode = 'Static'; Ip = $script:NewIp; Prefix = 24; Gateway = $script:OldGw; Dns = @($script:OldDns) }
        ($r.Lines -join ' ') | Should -Match 'FEHLER - Testfehler.*alter Zustand wiederhergestellt'
        @($r.Lines | Where-Object { $_ -match '^OK' }).Count | Should -Be 0
        @($r.End.Addrs | ForEach-Object { $_.IPAddress }) | Should -Be @($script:OldIp)
        @($r.End.Gw) | Should -Be @($script:OldGw)
        @($r.End.Dns) | Should -Be @($script:OldDns)
        $r.End.DnsStatic | Should -BeTrue
    }
    It 'Adresse doppelt im Netz: FEHLER und Rueckbau' {
        $s = $script:StaticOld.Clone(); $s.Dup = $true
        $r = & $script:RunNet $s @{ Index = 7; Mode = 'Static'; Ip = $script:NewIp; Prefix = 24; Gateway = $script:OldGw; Dns = @() }
        ($r.Lines -join ' ') | Should -Match 'bereits verwendet.*alter Zustand wiederhergestellt'
        @($r.End.Addrs | ForEach-Object { $_.IPAddress }) | Should -Be @($script:OldIp)
    }
    It 'DHCP ohne Antwort des DHCP-Servers: DHCP bleibt eingeschaltet, Warnung statt Rueckbau, nur dieser Adapter erneuert' {
        $r = & $script:RunNet $script:StaticOld @{ Index = 7; Mode = 'DHCP'; WaitDhcpSec = 2 }
        $r.Lines[0] | Should -Match '^WARN DHCP ist eingeschaltet, aber nach 2 Sekunden kam noch keine Adresse'
        @($r.Lines | Where-Object { $_ -match '^(OK|FEHLER)' }).Count | Should -Be 0
        $r.End.Dhcp | Should -BeTrue
        @($r.End.Renew) | Should -Be @('/renew', '"Ethernet Test"')
    }
    It 'Rueckbau mit zwei Standardgateways: beide wieder eingetragen, Kontrolle prueft Gateway und DNS' {
        $s = $script:StaticOld.Clone(); $s.FailNew = $true; $s.Gw = @($script:OldGw, (New-TestIp 2))
        $r = & $script:RunNet $s @{ Index = 7; Mode = 'Static'; Ip = $script:NewIp; Prefix = 24; Gateway = $script:OldGw; Dns = @() }
        ($r.Lines -join ' ') | Should -Match 'alter Zustand wiederhergestellt'
        @($r.End.Gw) | Should -Be @($script:OldGw, (New-TestIp 2))
        $t = New-HMNetChangeScript -Index 7 -Mode Static -Ip $script:NewIp -Prefix 24 -ResultFile 'x'
        $t | Should -Match ([regex]::Escape('$miss += @($old.Gw | Where-Object { @($chk.Gw) -notcontains $_ }'))
        $t | Should -Match ([regex]::Escape("`$miss += 'DNS-Server'"))
    }
    It 'DHCP gelungen: OK mit der Adresse vom DHCP-Server' {
        $s = $script:StaticOld.Clone(); $s.Lease = $script:Lease
        $r = & $script:RunNet $s @{ Index = 7; Mode = 'DHCP'; WaitDhcpSec = 2 }
        $r.Lines[0] | Should -Be "OK DHCP aktiv, Adresse vom DHCP-Server: $($script:Lease)"
        $r.End.Dhcp | Should -BeTrue
    }
    It 'Rueckbau scheitert auch: beide FEHLER-Zeilen mit dem vorherigen Zustand, kein OK' {
        $s = $script:StaticOld.Clone(); $s.FailAll = $true
        $r = & $script:RunNet $s @{ Index = 7; Mode = 'Static'; Ip = $script:NewIp; Prefix = 24; Gateway = ''; Dns = @() }
        ($r.Lines -join ' ') | Should -Match 'alter Zustand nicht wiederhergestellt'
        ($r.Lines -join ' ') | Should -Match ([regex]::Escape("$($script:OldIp)/24"))
        @($r.Lines | Where-Object { $_ -match '^OK' }).Count | Should -Be 0
    }
    It 'Ergebniszeilen beginnen nie mit "FEHLER: " (das hiesse fuer Invoke-HMTool: Verbindung gescheitert)' {
        $s = $script:StaticOld.Clone(); $s.FailNew = $true
        $r = & $script:RunNet $s @{ Index = 7; Mode = 'Static'; Ip = $script:NewIp; Prefix = 24 }
        @($r.Lines | Where-Object { $_ -match '^FEHLER: ' }).Count | Should -Be 0
        $script:RS_NetApply.ToString() | Should -Not -Match '"FEHLER: '
    }
    It 'Start am Ziel unabhaengig von der Ausfuehrungsrichtlinie (Befehl statt Skriptdatei), Rueckgabe sofort nach dem Start' {
        $t = $script:RS_NetApply.ToString()
        $t | Should -Match ([regex]::Escape('[scriptblock]::Create([System.IO.File]::ReadAllText('))
        $t | Should -Match ([regex]::Escape('-Command `"$cmd`"'))
        $t | Should -Not -Match ([regex]::Escape('-File `"'))
        $t | Should -Match ([regex]::Escape('"STARTED|$res"'))
        $t | Should -Not -Match 'while \('
    }
    It 'Abholen: Verbindung bricht ab -> Hinweis (INFO) statt Fehler, Nachkontrolle per Ping auf die neue Adresse' {
        Mock Invoke-Command { throw 'WinRM: Verbindung getrennt' }
        Mock Test-Connection { $true }
        Mock Start-Sleep { }
        $r = @(& $script:RS_NetPoll 'PC-ANDERS' $null 'C:\ProgramData\HUMig\Netzwerk\x.txt' 1 $script:NewIp $false)
        $r[0] | Should -Match '^INFO Verbindung getrennt, wie bei einer Adressaenderung zu erwarten'
        $r[1] | Should -Match "^INFO Nachkontrolle: die neue Adresse $([regex]::Escape($script:NewIp)) antwortet \(Ping\)"
        @($r | Where-Object { $_ -match '^(FEHLER|WARN)' }).Count | Should -Be 0
        Should -Invoke Invoke-Command -ParameterFilter { $ComputerName -eq $script:NewIp }
    }
    It 'Abholen: erst noch nicht fertig, dann Ergebnis -> Ergebniszeilen des Ziels' {
        $script:Calls = 0
        Mock Invoke-Command { $script:Calls++; if ($script:Calls -lt 2) { 'NOCH-NICHT' } else { @('OK statische Adresse ...') } }
        Mock Start-Sleep { }
        $r = @(& $script:RS_NetPoll 'PC-ANDERS' $null 'x.txt' 30 '' $false)
        $r | Should -Be @('OK statische Adresse ...')
    }
    It 'Abholen: DHCP ohne Antwort und ohne neue Adresse -> "Ergebnis offen", kein Ping' {
        Mock Invoke-Command { throw 'weg' }
        Mock Test-Connection { $true }
        Mock Start-Sleep { }
        $r = @(& $script:RS_NetPoll 'PC-ANDERS' $null 'x.txt' 1 '' $false)
        ($r -join ' ') | Should -Match 'Ergebnis offen'
        Should -Invoke Test-Connection -Times 0
    }
    It 'Abholen am eigenen PC: liest die Datei direkt' {
        $f = Join-Path $TestDrive 'netres.txt'; [IO.File]::WriteAllLines($f, [string[]]@('OK DHCP aktiv, Adresse vom DHCP-Server: x'))
        @(& $script:RS_NetPoll $env:COMPUTERNAME $null $f 5 '' $true) | Should -Be @('OK DHCP aktiv, Adresse vom DHCP-Server: x')
    }
}

Describe 'Profil anderem Konto zuweisen: Konto ohne Kennwort nur nach Rueckfrage' {
    BeforeAll { . (Join-Path $script:Root 'Functions\Tools-System.ps1') }
    It 'das Ziel fragt zurueck, bevor irgendetwas geaendert wird' {
        $t = $script:RS_ProfileAssign.ToString()
        $pos = $t.IndexOf("return 'FRAGE OHNE_KENNWORT'")
        $pos | Should -BeGreaterThan 0
        $before = (($t.Substring(0, $pos) -split "`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
        # vor der Rueckfrage nur Lesen: kein Anlegen, kein Gruppen-, Rechte-, Registry- oder Datei-Schreiben
        foreach ($w in @('New-LocalUser', 'Add-LocalGroupMember', 'icacls', 'reg.exe', 'New-Item', 'Remove-Item', 'Set-ItemProperty', 'New-ItemProperty', 'SetAccessControl')) {
            $before | Should -Not -Match ([regex]::Escape($w)) -Because "$w steht vor der Rueckfrage"
        }
        # und die Rueckfrage kommt nur, wenn kein Kennwort da ist und nicht ausdruecklich erlaubt
        $t | Should -Match ([regex]::Escape("-and -not `$allowBlank) { return 'FRAGE OHNE_KENNWORT' }"))
    }
    It 'erkennt die Rueckfrage in der Antwort (einzeln und in einer Liste)' {
        Test-HMBlankPasswordQuestion 'FRAGE OHNE_KENNWORT' | Should -BeTrue
        Test-HMBlankPasswordQuestion @('INFO x', 'FRAGE OHNE_KENNWORT') | Should -BeTrue
        Test-HMBlankPasswordQuestion @('OK Lokales Konto angelegt: PC\x') | Should -BeFalse
        Test-HMBlankPasswordQuestion $null | Should -BeFalse
    }
    It 'Rueckfrage nennt Konto, PC und Administrator, Nein bricht ab' {
        $x = Get-HMBlankPasswordText '.\schueler' 'PC01' $true
        $x | Should -Match 'OHNE Kennwort'
        $x | Should -Match 'lokaler Administrator'
        $x | Should -Match 'PC01'
        $x | Should -Match 'Nein = abbrechen'
        (Get-HMBlankPasswordText '.\schueler' 'PC01' $false) | Should -Not -Match 'Administrator'
    }
}

Describe 'Werkzeuge: Firewall, lokale Gruppen, Profil-Zuweisung, Autologon' {
    BeforeAll { . (Join-Path $script:Root 'Functions\Tools-System.ps1') }
    It 'Firewall: Rueckfrage nur, wenn ein anderer PC auf Oeffentlich gestellt wird' {
        Test-HMFirewallPublicRisk 'Public' 'Private' 'PC-ANDERS' | Should -BeTrue
        Test-HMFirewallPublicRisk 'Public' 'Public' 'PC-ANDERS' | Should -BeFalse
        Test-HMFirewallPublicRisk 'Private' 'Public' 'PC-ANDERS' | Should -BeFalse
        Test-HMFirewallPublicRisk 'Public' 'Private' $env:COMPUTERNAME | Should -BeFalse
        Test-HMFirewallPublicRisk 'Public' 'Private' 'localhost' | Should -BeFalse
        Test-HMFirewallPublicRisk 'Public' 'Private' '' | Should -BeFalse
        (Get-HMFirewallPublicText 'Ethernet' 'PC-ANDERS') | Should -Match 'PC-ANDERS'
    }
    It 'Gruppen: eingebauter Administrator und Domaenen-Admins werden erkannt (SID oder Name, auch mit Umlaut)' {
        $dom = 'S-1-5-21-1111111111-2222222222-3333333333'
        Test-HMCriticalAdmin 'DOM\Irgendwas' "$dom-512" | Should -BeTrue
        Test-HMCriticalAdmin 'PC\Umbenannt' "$dom-500" | Should -BeTrue
        Test-HMCriticalAdmin ("DOM\Dom" + [char]0xE4 + 'nen-Admins') '' | Should -BeTrue
        Test-HMCriticalAdmin 'DOM\Domaenen-Admins' '' | Should -BeTrue
        Test-HMCriticalAdmin 'DOM\Domain Admins' '' | Should -BeTrue
        Test-HMCriticalAdmin 'PC\Administrator' '' | Should -BeTrue
        Test-HMCriticalAdmin 'DOM\Lehrer' "$dom-1105" | Should -BeFalse
        Test-HMCriticalAdmin 'DOM\Admins-Schule' '' | Should -BeFalse
    }
    It 'Gruppen: Liste liefert die SID der Mitglieder mit' {
        $script:RS_GroupList.ToString() | Should -Match 'MitgliedSid'
    }
    It 'Profil-Zuweisung: nicht entladene Registry-Datei fuehrt zu einer Warnung mit Neustart' {
        $t = $script:RS_ProfileAssign.ToString()
        $t | Should -Match ([regex]::Escape('liess sich nicht entladen - PC VOR der ersten Anmeldung'))
        $t.IndexOf('liess sich nicht entladen') | Should -BeGreaterThan $t.IndexOf('reg.exe unload')
    }
    It 'Autologon: lokale Domaene bestimmt das Ziel, nicht der eingetippte Name' {
        $t = $script:RS_Autologon.ToString()
        $t | Should -Match ([regex]::Escape("if (-not `"`$domain`".Trim() -or `"`$domain`" -eq '.') { `$domain = `$env:COMPUTERNAME }"))
        ${function:Start-HMAutologon}.ToString() | Should -Not -Match ([regex]::Escape("Split('.')[0]"))
    }
}

Describe 'Werkzeuge: Druckspooler und Systemdatei-Reparatur' {
    BeforeAll { . (Join-Path $script:Root 'Functions\Tools-System.ps1') }
    It 'Druckspooler: laufende abhaengige Dienste werden gemerkt und wieder gestartet' {
        $t = ${function:Start-HMSpoolerReset}.ToString()
        $t | Should -Match 'DependentServices'
        $t.IndexOf('DependentServices') | Should -BeLessThan $t.IndexOf('Stop-Service Spooler')
        $t | Should -Match ([regex]::Escape('abhaengiger Dienst $n wieder gestartet'))
    }
    It 'Systemdatei-Reparatur: Code ungleich 0 erscheint als WARN' {
        ${function:Start-HMSystemRepair}.ToString() | Should -Match ([regex]::Escape("(DISM|SFC) Code (-?\d+)' -and `$Matches[2] -ne '0') { `"WARN"))
    }
}

Describe 'Softwareverteilung: Nachkontrolle mit Mindestversion und Rechte der Paketablage' {
    BeforeAll {
        . (Join-Path $script:Root 'Functions\Tools-Software.ps1')
        # verschachtelte Funktion aus dem Text, der am Ziel-PC laeuft, herausloesen
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($script:RS_SwInstall.ToString(), [ref]$null, [ref]$null)
        foreach ($nm in @('Get-HUInstallVerdict', 'ConvertTo-HUVer', 'Find-HUApp')) {
            $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $nm }, $true) | Select-Object -First 1
            . ([scriptblock]::Create($fn.Extent.Text))
        }
        $script:Det ={ param([bool]$Hit, [string]$Ver) [pscustomobject]@{ Hit = $Hit; Version = $Ver; Missing = 'Name x*' } }
        $script:NewAcl = {
            param([string]$Sid, [string]$Rights, [string]$Type = 'Allow')
            $a = New-Object System.Security.AccessControl.DirectorySecurity
            $a.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule((New-Object System.Security.Principal.SecurityIdentifier $Sid), $Rights, 'ContainerInherit,ObjectInherit', 'None', $Type)))
            return $a
        }
    }
    It 'Update ohne Wirkung (alte Version bleibt, Mindestversion verfehlt) ist FEHLER statt installiert' {
        $r = Get-HUInstallVerdict 0 @(0) (& $script:Det $true '1.0') (& $script:Det $false '') '2.0' '5 s' ' - App 1.0' '' ''
        $r | Should -Match '^FEHLER\|'
        $r | Should -Match 'nur Version 1\.0 gefunden \(Mindestversion 2\.0\)'
    }
    It 'Mindestversion erreicht: OK wie bisher' {
        Get-HUInstallVerdict 0 @(0) (& $script:Det $true '2.1') (& $script:Det $true '2.1') '2.0' '5 s' ' - App 2.1' '' '' | Should -Match '^OK\|installiert \(ExitCode 0'
    }
    It 'ohne Mindestversion: Verhalten unveraendert (OK bzw. FEHLER nicht gefunden)' {
        Get-HUInstallVerdict 0 @(0) (& $script:Det $true '1.0') (& $script:Det $true '1.0') '' '5 s' '' '' '' | Should -Match '^OK\|'
        Get-HUInstallVerdict 0 @(0) (& $script:Det $false '') (& $script:Det $false '') '' '5 s' '' '' '' | Should -Match '^FEHLER\|ExitCode 0, aber Programm danach nicht gefunden'
        Get-HUInstallVerdict 0 @(0) $null $null '' '5 s' '' '' '' | Should -Match '^OK\|'
    }
    It 'Neustart-Code bleibt OK, sagt aber, dass die Version erst danach pruefbar ist' {
        $r = Get-HUInstallVerdict 3010 @(0) (& $script:Det $true '1.0') (& $script:Det $false '') '2.0' '5 s' '' '' ''
        $r | Should -Match '^OK\|installiert - NEUSTART erforderlich'
        $r | Should -Match 'erst nach dem Neustart pruefbar'
    }
    It 'Neustart-Code als Erfolgscode eingetragen (0,3010) und Mindestversion erst nach Neustart: OK mit Hinweis wie bisher' {
        $r = Get-HUInstallVerdict 3010 @(0, 3010) (& $script:Det $true '1.0') (& $script:Det $false '') '2.0' '5 s' '' '' ''
        $r | Should -Match '^OK\|installiert - NEUSTART erforderlich'
        $r | Should -Match 'erst nach dem Neustart pruefbar'
        Get-HUInstallVerdict 3010 @(0, 3010) (& $script:Det $true '2.0') (& $script:Det $true '2.0') '2.0' '5 s' '' '' '' | Should -Match '^OK\|installiert \(ExitCode 3010'
    }
    It 'anderer Fehlercode: leer (Fehlercode-Zweig wie bisher)' {
        Get-HUInstallVerdict 1603 @(0) (& $script:Det $true '1.0') (& $script:Det $false '') '2.0' '5 s' '' '' '' | Should -Be ''
    }
    It 'Versionen werden gleich normalisiert (1.2.3 = 1.2.3.0, v1.2, Anhaenge), Unlesbares ist $null' {
        (ConvertTo-HUVer '1.2.3') -eq (ConvertTo-HUVer '1.2.3.0') | Should -BeTrue
        (ConvertTo-HUVer 'v1.2') -eq (ConvertTo-HUVer '1.2.0.0') | Should -BeTrue
        (ConvertTo-HUVer '1.2.3-beta') -eq (ConvertTo-HUVer '1.2.3') | Should -BeTrue
        (ConvertTo-HUVer '7') -eq (ConvertTo-HUVer '7.0.0.0') | Should -BeTrue
        (ConvertTo-HUVer '1.2.3') -lt (ConvertTo-HUVer '1.2.10') | Should -BeTrue
        ConvertTo-HUVer '' | Should -BeNullOrEmpty
        ConvertTo-HUVer 'Version unbekannt' | Should -BeNullOrEmpty
    }
    It 'Erkennung mit Mindestversion: 1.2.3.0 gegen DisplayVersion 1.2.3 gilt als erreicht' {
        Mock Get-ItemProperty { [pscustomobject]@{ PSChildName = '{X}'; DisplayName = 'Testprogramm'; DisplayVersion = '1.2.3' } }
        Find-HUApp 'Testprogramm*' '' '1.2.3.0' | Should -Not -BeNullOrEmpty
        Find-HUApp 'Testprogramm*' '' '1.2.4' | Should -BeNullOrEmpty
    }
    It 'installierte Version leer oder nicht lesbar: OK mit "Version nicht pruefbar" statt Fehler' {
        $r = Get-HUInstallVerdict 0 @(0) (& $script:Det $true '') (& $script:Det $false '') '2.0' '5 s' '' '' ''
        $r | Should -Match '^OK\|installiert \(ExitCode 0'
        $r | Should -Match 'Version nicht pruefbar'
        Get-HUInstallVerdict 0 @(0) (& $script:Det $true 'neu') (& $script:Det $false '') '2.0' '5 s' '' '' '' | Should -Match '^OK\|.*Version nicht pruefbar'
    }
    It 'Nachkontrolle am Ziel nutzt die Mindestversion' {
        $script:RS_SwInstall.ToString() | Should -Match ([regex]::Escape('$chkMin = if ($chk -and $mv) { Get-HUDetect $p $mv } else { $chk }'))
    }
    It 'breite Gruppen mit Schreibrecht werden erkannt, Leserechte und Administratoren nicht' {
        @(Get-SwBroadWriters (& $script:NewAcl 'S-1-5-32-545' 'Modify')) | Should -Be @('Benutzer')
        @(Get-SwBroadWriters (& $script:NewAcl 'S-1-1-0' 'Write')) | Should -Be @('Jeder')
        @(Get-SwBroadWriters (& $script:NewAcl 'S-1-5-11' 'Delete')) | Should -Be @('Authentifizierte Benutzer')
        @(Get-SwBroadWriters (& $script:NewAcl 'S-1-5-21-1111111111-2222222222-3333333333-513' 'Write')) | Should -Be @('Domaenen-Benutzer')
        @(Get-SwBroadWriters (& $script:NewAcl 'S-1-5-32-545' 'ReadAndExecute')) | Should -BeNullOrEmpty
        @(Get-SwBroadWriters (& $script:NewAcl 'S-1-5-32-544' 'FullControl')) | Should -BeNullOrEmpty
        @(Get-SwBroadWriters (& $script:NewAcl 'S-1-5-32-545' 'Modify' 'Deny')) | Should -BeNullOrEmpty
    }
    It 'echter Ordner: ohne Freigabe kein Hinweis, mit Aendern fuer Benutzer ein Hinweis' {
        $d = Join-Path $TestDrive 'Ablage'; New-Item -ItemType Directory -Path $d -Force | Out-Null
        @(Get-SwPathWriteRisk @($d)) | Should -BeNullOrEmpty
        $i = Get-Item -LiteralPath $d
        $acl = Get-Acl -LiteralPath $d   # GetAccessControl() gibt es unter PowerShell 7 an DirectoryInfo nicht
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule((New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-545'), 'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
        if ($i.PSObject.Methods['SetAccessControl']) { $i.SetAccessControl($acl) } else { [System.IO.FileSystemAclExtensions]::SetAccessControl($i, $acl) }
        $r = @(Get-SwPathWriteRisk @($d))
        $r.Count | Should -Be 1
        $r[0] | Should -Match 'aendern duerfen: Benutzer'
        (Get-SwPackageRiskText ([pscustomobject]@{ SrcPath = $d; ConfigPath = '' }) '') | Should -Match 'laeuft als Administrator'
        (Get-SwPackageRiskText ([pscustomobject]@{ SrcPath = (Join-Path $TestDrive 'gibtsnicht'); ConfigPath = '' }) '') | Should -Be ''
    }
    It 'Pruefung nur beim Bestaetigen (kein Get-Acl beim Start im UI-Thread)' {
        ${function:Confirm-SwDeploy}.ToString() | Should -Match 'Get-SwPackageRiskText'
        ${function:Start-SoftwareDeploy}.ToString() | Should -Not -Match 'Get-SwPackageRiskText'
        ${function:Start-SwPackageUninstall}.ToString() | Should -Not -Match 'Get-SwPackageRiskText'
    }
    It 'Ablage auf FAT/exFAT: einmal ein ruhiger Hinweis, danach nichts (statt Warnung bei jedem Vorgang)' {
        $script:SwFatHintShown = $false
        Mock Get-SwPathFileSystem { 'exFAT' }
        Mock Get-SwPathWriteRisk { throw 'darf auf FAT nicht laufen' }
        $p = [pscustomobject]@{ SrcPath = 'X:\Ablage\x'; ConfigPath = '' }
        (Get-SwPackageRiskText $p 'X:\Ablage') | Should -Match '^Hinweis: Paketablage auf einem Datentraeger ohne Rechte \(exFAT\)'
        (Get-SwPackageRiskText $p 'X:\Ablage') | Should -Be ''
    }
}

Describe 'Treiberverteilung: Nachkontrolle und Hinweis zur Geraete-Sperre' {
    BeforeAll {
        . (Join-Path $script:Root 'Functions\Tools-Drivers.ps1')
        $script:DrvBody = $script:RS_DrvInstallBody.ToString()
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($script:DrvBody, [ref]$null, [ref]$null)
        $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-HUDrvVerdict' }, $true) | Select-Object -First 1
        . ([scriptblock]::Create($fn.Extent.Text))
    }
    It 'Treiberversion: INF-Text und Geraeteversion werden normalisiert verglichen, Unlesbares ist nicht vergleichbar' {
        Test-HUVerIn '1.2.3.0' @('1.02.0003') | Should -BeTrue
        Test-HUVerIn '1.2.3.0' @('1.2.3') | Should -BeTrue
        Test-HUVerIn '31.0.15.3623' @('31.0.15.3623') | Should -BeTrue
        Test-HUVerIn '1.2.4.0' @('1.2.3') | Should -BeFalse
        Test-HUVerIn '1.2.3.0' @('?') | Should -BeNullOrEmpty
        Test-HUVerIn '' @('1.2.3') | Should -BeNullOrEmpty
        Get-HUDrvVerdict 2 0 $false $true | Should -Be 'Ok'
    }
    It 'Nachkontrolle und Vorpruefung nutzen den normalisierten Vergleich, Hinweis bei nicht vergleichbarer Version' {
        ([regex]::Matches($script:DrvBody, [regex]::Escape('(Test-HUVerIn $_.Version $map[$_.Hw]) -eq $true'))).Count | Should -BeGreaterThan 2
        $script:RS_DrvPreBody.ToString() | Should -Match ([regex]::Escape('Test-HUVerIn $_.Version $map[$_.Hw]'))
        $script:DrvBody | Should -Match 'Version nicht pruefbar'
    }
    It 'kein Geraet mit der neuen Version und kein Neustart: nicht installiert' {
        Get-HUDrvVerdict 2 0 $false | Should -Be 'NoneNew'
        Get-HUDrvVerdict 2 0 $true | Should -Be 'Ok'
        Get-HUDrvVerdict 2 1 $false | Should -Be 'Ok'
        Get-HUDrvVerdict 0 0 $false | Should -Be 'Ok'
    }
    It 'die Rueckgabe kommt vor der Sperren-Buchfuehrung (finally stellt die alten Sperren her)' {
        $i1 = $script:DrvBody.IndexOf('if ($nv -eq ''NoneNew'') { return "SKIP|nicht wirksam')
        $i1 | Should -BeGreaterThan 0
        $i1 | Should -BeLessThan $script:DrvBody.IndexOf('$lockNote = Set-HUDrvLock $newOk')
    }
    It 'Hinweis: Sperre gilt auch fuer neu angesteckte Geraete (Rueckfrage, Ergebnis)' {
        $script:DrvLockNote | Should -Match 'neu angesteckte'
        ${function:Confirm-DrvDeploy}.ToString() | Should -Match 'DrvLockNote'
        $script:DrvLibText | Should -Match 'gilt auch fuer neu angesteckte Geraete'
        ${function:Confirm-DrvDeploy}.ToString() | Should -Match 'Get-SwPackageRiskText'
    }
}

Describe 'App-Updates: Doppelstart, Zeitplan-Status, Zeitlimit' {
    BeforeAll {
        . (Join-Path $script:Root 'Functions\AppUpdates-Engine.ps1')
        # einzelne Funktionen aus Dateien laden, die sonst die Oberflaeche brauchen bzw. eigenstaendig laufen
        $script:LoadFn = {
            param([string]$File, [string[]]$Names)
            $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Root $File), [ref]$null, [ref]$null)
            foreach ($n in $Names) {
                $fn = $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $n }, $true) | Select-Object -First 1
                if (-not $fn) { throw "Funktion $n fehlt in $File" }
                . ([scriptblock]::Create($fn.Extent.Text.Replace("function $n", "function global:$n")))
            }
        }
        & $script:LoadFn 'Functions\UI-AppUpdates.ps1' @('Get-HMAuScheduleResultText', 'Get-HMAuBusyText')
        & $script:LoadFn 'Functions\AppUpdates-Auto.ps1' @('Invoke-AWinget')
        $script:Target = [System.IO.File]::ReadAllText((Join-Path $script:Root 'Functions\AppUpdates-Target.ps1'))
        $script:Worker = [System.IO.File]::ReadAllText((Join-Path $script:Root 'Functions\AppUpdates-Worker.ps1'))
        $script:Auto = [System.IO.File]::ReadAllText((Join-Path $script:Root 'Functions\AppUpdates-Auto.ps1'))
    }
    It 'Zeitlimit je Programm als SYSTEM (Standard 120 min, Rest laeuft weiter)' {
        $script:Target | Should -Match ([regex]::Escape('$SysItemMin = 120; $simTmp = 0; if ([int]::TryParse("$($Payload.ItemTimeoutMin)", [ref]$simTmp) -and $simTmp -gt 0)'))
        $script:Target | Should -Match ([regex]::Escape('$false 10800 $SysItemMin'))
        $script:Auto | Should -Match ([regex]::Escape('$itemMin = 120; $im = 0; if ([int]::TryParse("$($cfg.ItemTimeoutMin)", [ref]$im) -and $im -gt 0)'))
        # "-5" oder Text werfen nicht, sondern ergeben den Standardwert
        foreach ($v in @('-5', 'abc', '', $null)) { $im = 0; $x = 120; if ([int]::TryParse("$v", [ref]$im) -and $im -gt 0) { $x = $im }; $x | Should -Be 120 }
    }
    It 'Zeitplan: eine nicht lesbare Quelle ist ein Hinweis, Fehler nur ohne jede lesbare Quelle' {
        $script:Auto | Should -Match ([regex]::Escape('} catch { $srcBad += "$src"; Write-ALog "Hinweis: Quelle ${src} nicht lesbar'))
        $script:Auto | Should -Match ([regex]::Escape('if ($srcBad.Count -and -not $srcOk) { $err++'))
    }
    It 'Doppelstart: Rueckfrage nur, wenn die Vorpruefung eines frueheren Klicks laeuft' {
        $global:AuPreCheck = 0; $script:AuPreCheck = 0
        Get-HMAuBusyText | Should -Be ''
        $global:AuPreCheck = 1; $script:AuPreCheck = 1
        Get-HMAuBusyText | Should -Match 'Pruefung der laufenden Programme eines frueheren Klicks'
        # andere Arbeiten mit der Kennung Au (WinGet pruefen, Quellen) zaehlen nicht
        $global:AuPreCheck = 0; $script:AuPreCheck = 0; $script:AsyncBusy = @{ 'Au' = 3 }; $script:AsyncBusyText = @{ 'Au' = 'Laufende Programme pruefen ...' }
        Get-HMAuBusyText | Should -Be ''
        $ui = [System.IO.File]::ReadAllText((Join-Path $script:Root 'Functions\UI-AppUpdates.ps1'))
        # Zaehler: zweimal erhoeht (lokal, andere PCs), zweimal im OnComplete gesenkt
        ([regex]::Matches($ui, [regex]::Escape('$script:AuPreCheck = [int]$script:AuPreCheck + 1'))).Count | Should -Be 2
        ([regex]::Matches($ui, [regex]::Escape('$script:AuPreCheck = [Math]::Max(0, [int]$script:AuPreCheck - 1)'))).Count | Should -Be 2
        # Rueckfrage erst, wenn wirklich etwas zu aktualisieren ist
        $ui.IndexOf("if (`$busy -and -not (Confirm-Action") | Should -BeGreaterThan $ui.IndexOf('if (-not $byPc.Count) { return }')
    }
    It 'Zeitplan: Fehler aus dem letzten Bericht gehen vor dem Rueckgabewert 0' {
        Get-HMAuScheduleResultText $false '0' '26.11.2026 03:00' 5 | Should -Be 'Fehler (5)'
        Get-HMAuScheduleResultText $false '0' '26.11.2026 03:00' 0 | Should -Be 'OK'
        Get-HMAuScheduleResultText $false '0' '26.11.2026 03:00' $null | Should -Be 'OK'
        Get-HMAuScheduleResultText $false '1' '26.11.2026 03:00' 2 | Should -Be 'Fehler (2)'
        Get-HMAuScheduleResultText $false '2147942402' '26.11.2026 03:00' $null | Should -Be 'Code 2147942402'
        Get-HMAuScheduleResultText $true '0' '26.11.2026 03:00' 3 | Should -Be 'laeuft'
        Get-HMAuScheduleResultText $false '267009' '' 0 | Should -Be 'laeuft'
        Get-HMAuScheduleResultText $false '0' '' 0 | Should -Be ''
    }
    It 'Zeitplan: Ziel liefert die Fehlerzahl, Skript setzt den Rueckgabewert' {
        $script:Target | Should -Match ([regex]::Escape('$o.LastErr = [int]"0$($l.Err)"'))
        $script:Auto | Should -Match ([regex]::Escape('exit $(if ($err -gt 0) { 1 } else { 0 })'))
        $script:Auto | Should -Match ([regex]::Escape('Invoke-AWinget $wg @('))
    }
    It 'Zeitplan: winget mit Zeitlimit - Rueckgabecode, Ausgabe und Abbruch nach dem Limit' {
        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $r = Invoke-AWinget $ps @('-NoProfile', '-Command', 'Write-Output "Zeile eins"; exit 3') 1
        $r.TimedOut | Should -BeFalse
        $r.Code | Should -Be 3
        ($r.Out -join ' ') | Should -Match 'Zeile eins'
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r2 = Invoke-AWinget $ps @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30') 0.03
        $sw.Stop()
        $r2.TimedOut | Should -BeTrue
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 20
    }
}

Describe 'Restore-Vorschau zeigt, was der Restore nicht zurueckspielt' {
    BeforeAll {
        . (Join-Path $script:Root 'Functions\Migration-Engine.ps1')
        . (Join-Path $script:Root 'Functions\Migration-Quality.ps1')
        $script:Mk = { param([string]$P, [string]$T = 'x') New-Item -ItemType Directory -Path (Split-Path $P -Parent) -Force | Out-Null; [IO.File]::WriteAllText($P, $T) }
        $script:FreeDrive = @('Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y') | Where-Object { -not (Test-Path -LiteralPath "$($_):\") } | Select-Object -First 1
        $script:RunPreview = {
            param([hashtable]$Ctx)
            $job = @{ Cancel = $false; Status = ''; Progress = 0; Log = (New-Object System.Collections.Concurrent.ConcurrentQueue[object]); LogFile = $null }
            Get-HMRestorePreview -Ctx $Ctx -Job $job
            return $job.Result
        }
    }
    BeforeEach {
        $script:Bk = Join-Path $TestDrive ("BK_{0}" -f [guid]::NewGuid().ToString('N').Substring(0, 6))
        $script:Ctx = @{
            Computer = $env:COMPUTERNAME; UserFolder = 'max'; UserSid = $null; ProfilePath = $null; Account = ''; Credential = $null
            Options = @{ KeepNewer = $false }; ExtraTargets = @{}
            Backup = @{ Path = $script:Bk; Name = 'BK'; Legacy = $false; Manifest = [pscustomobject]@{ MachineGuid = 'nicht-dieser-pc'; UserSid = 'S-1-5-21-1-2-3-1001'; SourceComputerName = 'ANDERER-PC' } }
            Modules = @()
        }
    }
    It 'Ziel ohne Profil: Benutzer-Module erscheinen als "nicht zurueckgespielt"' {
        & $script:Mk (Join-Path $script:Bk 'Docs\Eigene\a.txt')
        $script:Ctx.Modules = @([pscustomobject]@{ Id = 'Docs'; Name = 'Dokumente'; Scope = 'User'; Items = @([pscustomobject]@{ Type = 'Folder'; Name = 'Eigene'; Path = '{PROFILE}\Documents' }) })
        $r = & $script:RunPreview $script:Ctx
        @($r.Rows).Count | Should -Be 1
        $r.Rows[0].Aktion | Should -Match 'nicht zurueckgespielt: Zielbenutzer hat am Ziel-PC noch kein Profil'
        $r.Counts.Nicht | Should -Be 1
        $r.Summary | Should -Match 'NICHT zurueckgespielt'
    }
    It 'Ziel ohne Profil, aber USMT gewaehlt: Hinweis statt falscher Liste' {
        $script:Ctx.Modules = @(
            [pscustomobject]@{ Id = 'Usmt'; Name = 'Windows-Einstellungen (USMT)'; Scope = 'User'; Items = @() }
            [pscustomobject]@{ Id = 'Docs'; Name = 'Dokumente'; Scope = 'User'; Items = @([pscustomobject]@{ Type = 'Folder'; Name = 'Eigene'; Path = '{PROFILE}\Documents' }) })
        $r = & $script:RunPreview $script:Ctx
        @($r.Rows | Where-Object { $_.Modul -eq 'Dokumente' })[0].Aktion | Should -Match 'USMT legt es erst beim Restore an'
    }
    It 'fehlendes Ziel-Laufwerk: Zeile statt Dateiliste' {
        if (-not $script:FreeDrive) { Set-ItResult -Skipped -Because 'kein freier Laufwerksbuchstabe'; return }
        & $script:Mk (Join-Path $script:Bk 'Daten\D1\a.txt')
        $script:Ctx.Modules = @([pscustomobject]@{ Id = 'Daten'; Name = 'Daten'; Scope = 'Machine'; Items = @([pscustomobject]@{ Type = 'Folder'; Name = 'D1'; Path = "$($script:FreeDrive):\Daten" }) })
        $r = & $script:RunPreview $script:Ctx
        @($r.Rows).Count | Should -Be 1
        $r.Rows[0].Aktion | Should -Match "Laufwerk $($script:FreeDrive): gibt es am Ziel-PC nicht"
    }
    It 'an PC und Konto gebundene Registry auf anderem PC: nicht zurueckgespielt' {
        & $script:Mk (Join-Path $script:Bk 'BrReg\Prefs.reg')
        $script:Ctx.Modules = @([pscustomobject]@{ Id = 'BrReg'; Name = 'Browser-Werte'; Scope = 'Machine'; Items = @([pscustomobject]@{ Type = 'Reg'; Name = 'Prefs'; Key = 'HKLM\SOFTWARE\HUMigTest'; SameMachineOnly = $true }) })
        $r = & $script:RunPreview $script:Ctx
        $r.Rows[0].Aktion | Should -Match 'an PC und Konto gebunden'
    }
    It 'Browser auf anderem PC: nur Lesezeichen zusammenfuehren, keine Dateiliste' {
        $dst = Join-Path $TestDrive 'ZielBrowser'
        & $script:Mk (Join-Path $script:Bk 'Chrome\UserData\Default\Bookmarks')
        & $script:Mk (Join-Path $dst 'Default\Bookmarks')
        $script:Ctx.Modules = @([pscustomobject]@{ Id = 'Chrome'; Name = 'Chrome'; Scope = 'Machine'; Group = 'Browser'; Items = @([pscustomobject]@{ Type = 'Folder'; Name = 'UserData'; Path = $dst; Chromium = '' }) })
        $r = & $script:RunPreview $script:Ctx
        @($r.Rows).Count | Should -Be 1
        $r.Rows[0].Aktion | Should -Be 'Browser: nur Lesezeichen zusammenfuehren'
    }
    It 'Zusaetzliche Ordner: abgewaehlte als "nicht zurueckgespielt", geaenderte mit neuem Ziel' {
        $ed = Join-Path $script:Bk 'ExtraFolders'
        & $script:Mk (Join-Path $ed 'FOLDER1\a.txt'); & $script:Mk (Join-Path $ed 'FOLDER2\b.txt')
        $p1 = 'D:\Projekte'; $p2 = 'D:\Archiv'
        [IO.File]::WriteAllText((Join-Path $ed 'folders.json'), (ConvertTo-Json -InputObject @(@{ Index = 1; Path = $p1 }, @{ Index = 2; Path = $p2 })))
        $neu = "$($env:SystemDrive)\HUMigTestZiel\Archiv"
        $script:Ctx.ExtraTargets = @{ (ConvertTo-HMExtraKey $p1) = ''; (ConvertTo-HMExtraKey $p2) = $neu }
        $script:Ctx.Modules = @([pscustomobject]@{ Id = 'ExtraFolders'; Name = 'Zusaetzliche Ordner'; Scope = 'Machine'; Items = @([pscustomobject]@{ Type = 'Builtin'; Name = 'ExtraFolders'; Handler = 'ExtraFolders' }) })
        $r = & $script:RunPreview $script:Ctx
        @($r.Rows | Where-Object { $_.Aktion -match 'beim Restore abgewaehlt' -and $_.Ziel -eq $p1 }).Count | Should -Be 1
        $row = @($r.Rows | Where-Object { $_.Aktion -match '^Zusaetzlicher Ordner' -and $_.Ziel -match ([regex]::Escape("$neu (statt D:\Archiv)")) })
        $row.Count | Should -Be 1
        $row[0].Aktion | Should -Match 'Restore leitet noch um'
    }
    It 'Zusaetzlicher Ordner auf fehlendem Laufwerk: nicht zurueckgespielt' {
        if (-not $script:FreeDrive) { Set-ItResult -Skipped -Because 'kein freier Laufwerksbuchstabe'; return }
        $ed = Join-Path $script:Bk 'ExtraFolders'
        & $script:Mk (Join-Path $ed 'FOLDER1\a.txt')
        [IO.File]::WriteAllText((Join-Path $ed 'folders.json'), (ConvertTo-Json -InputObject @(@{ Index = 1; Path = "$($script:FreeDrive):\Projekte" })))
        $script:Ctx.Modules = @([pscustomobject]@{ Id = 'ExtraFolders'; Name = 'Zusaetzliche Ordner'; Scope = 'Machine'; Items = @([pscustomobject]@{ Type = 'Builtin'; Name = 'ExtraFolders'; Handler = 'ExtraFolders' }) })
        $r = & $script:RunPreview $script:Ctx
        @($r.Rows).Count | Should -Be 1
        $r.Rows[0].Aktion | Should -Match "Laufwerk $($script:FreeDrive): gibt es am Ziel-PC nicht"
    }
    It 'normaler Ordner: Dateivergleich wie bisher (aeltere Zieldatei wird ueberschrieben)' {
        $dst = Join-Path $TestDrive ("ZielN_{0}" -f [guid]::NewGuid().ToString('N').Substring(0, 6))
        & $script:Mk (Join-Path $script:Bk 'Norm\N1\a.txt') 'neu und laenger'
        & $script:Mk (Join-Path $dst 'a.txt') 'alt'
        (Get-Item (Join-Path $dst 'a.txt')).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddDays(-3)
        $script:Ctx.Modules = @([pscustomobject]@{ Id = 'Norm'; Name = 'Normal'; Scope = 'Machine'; Items = @([pscustomobject]@{ Type = 'Folder'; Name = 'N1'; Path = $dst }) })
        $r = & $script:RunPreview $script:Ctx
        @($r.Rows).Count | Should -Be 1
        $r.Rows[0].Aktion | Should -Be 'ueberschreibt (Ziel aelter)'
        $r.Counts.Nicht | Should -Be 0
    }
}

Describe 'Katalog-Editor: eigene Eintraege sicher speichern' {
    BeforeAll {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Root 'Functions\UI-AppEditor.ps1'), [ref]$null, [ref]$null)
        foreach ($n in @('Write-HMAeLocal', 'Test-HMAeLocalFile', 'Write-HMAeTextAtomic')) {
            $fn = $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $n }, $true) | Select-Object -First 1
            . ([scriptblock]::Create($fn.Extent.Text.Replace("function $n", "function global:$n")))
        }
        function global:Show-HMDialogBox { param($Owner, $Text, $Title, $Mode, $Icon) return $global:T_Answer }
    }
    AfterAll { Remove-Item Function:\global:Show-HMDialogBox -ErrorAction SilentlyContinue }
    BeforeEach {
        $d = Join-Path $TestDrive ("cfg_{0}" -f [guid]::NewGuid().ToString('N').Substring(0, 6))
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        $global:ConfigDir = $d; $script:ConfigDir = $d
        $global:Ae = @{ LocalObj = $null; Win = $null; Saved = $false }; $script:Ae = $global:Ae
        $global:T_Answer = 'No'
        $script:P = Join-Path $d 'apps.json'
    }
    It 'ohne Datei: wird angelegt, keine Sicherung, keine Hilfsdatei bleibt liegen' {
        Write-HMAeLocal @([pscustomobject]@{ Id = 'App_A'; Name = 'A' })
        (Get-Content -LiteralPath $script:P -Raw | ConvertFrom-Json).Apps[0].Id | Should -Be 'App_A'
        Test-Path "$($script:P).bak" | Should -BeFalse
        @(Get-ChildItem -LiteralPath $global:ConfigDir -Filter '*.tmp-*').Count | Should -Be 0
    }
    It 'lesbare Datei: Sicherung aus der alten Datei, neue Datei vollstaendig' {
        [IO.File]::WriteAllText($script:P, '{"Apps":[{"Id":"App_Alt"}]}')
        Write-HMAeLocal @([pscustomobject]@{ Id = 'App_Neu'; Name = 'N' })
        (Get-Content -LiteralPath "$($script:P).bak" -Raw) | Should -Match 'App_Alt'
        (Get-Content -LiteralPath $script:P -Raw | ConvertFrom-Json).Apps[0].Id | Should -Be 'App_Neu'
    }
    It 'beschaedigte Datei, Rueckfrage Nein: nichts geaendert, gute Sicherung bleibt' {
        [IO.File]::WriteAllText($script:P, '{"Apps":[{"Id":"App_Kaputt"')
        [IO.File]::WriteAllText("$($script:P).bak", '{"Apps":[{"Id":"App_Gut1"},{"Id":"App_Gut2"}]}')
        { Write-HMAeLocal @([pscustomobject]@{ Id = 'App_Neu' }) } | Should -Throw '*nicht gespeichert*'
        [IO.File]::ReadAllText($script:P) | Should -Be '{"Apps":[{"Id":"App_Kaputt"'
        [IO.File]::ReadAllText("$($script:P).bak") | Should -Match 'App_Gut2'
        $global:Ae.Saved | Should -BeFalse
    }
    It 'beschaedigte Datei, Rueckfrage Ja: defekte Datei bleibt erhalten, Sicherung unveraendert, neue Datei lesbar' {
        [IO.File]::WriteAllText($script:P, '{"Apps":[{"Id":"App_Kaputt"')
        [IO.File]::WriteAllText("$($script:P).bak", '{"Apps":[{"Id":"App_Gut1"},{"Id":"App_Gut2"}]}')
        $global:T_Answer = 'Yes'
        Write-HMAeLocal @([pscustomobject]@{ Id = 'App_Neu' })
        @(Get-ChildItem -LiteralPath $global:ConfigDir -Filter 'apps.json.defekt-*').Count | Should -Be 1
        [IO.File]::ReadAllText("$($script:P).bak") | Should -Match 'App_Gut2'
        Test-HMAeLocalFile $script:P | Should -Be 'OK'
    }
    It 'gesperrte Datei: "Gesperrt", nicht "beschaedigt", nichts gespeichert, keine Rueckfrage' {
        [IO.File]::WriteAllText($script:P, '{"Apps":[{"Id":"App_A"}]}')
        $fs = [System.IO.File]::Open($script:P, 'Open', 'ReadWrite', 'None')
        try {
            Test-HMAeLocalFile $script:P | Should -Be 'Gesperrt'
            $global:T_Answer = 'Yes'
            { Write-HMAeLocal @([pscustomobject]@{ Id = 'App_Neu' }) } | Should -Throw '*nicht lesbar (in Benutzung oder keine Rechte)*'
        } finally { $fs.Dispose() }
        [IO.File]::ReadAllText($script:P) | Should -Match 'App_A'
        @(Get-ChildItem -LiteralPath $global:ConfigDir -Filter 'apps.json.defekt-*').Count | Should -Be 0
    }
    It 'Zustand der Datei: Fehlt, OK, Defekt (auch leer)' {
        Test-HMAeLocalFile (Join-Path $global:ConfigDir 'gibtsnicht.json') | Should -Be 'Fehlt'
        [IO.File]::WriteAllText($script:P, '   '); Test-HMAeLocalFile $script:P | Should -Be 'Defekt'
        [IO.File]::WriteAllText($script:P, '{}'); Test-HMAeLocalFile $script:P | Should -Be 'OK'
    }
}

Describe 'Status-Reiter: nicht lesbare Quellen und Profile ohne Lauf' {
    BeforeAll { . (Join-Path $script:Root 'Functions\UI-Status.ps1') }
    It 'nicht lesbare Quelle ergibt einen Hinweis (kein "Alles in Ordnung")' {
        $s = Get-HMStatusData -Now ([datetime]'2026-11-26 10:00') -Unreadable @('App-Updates-Verlauf', 'App-Updates-Verlauf')
        @($s.Warnings).Count | Should -Be 1
        $s.Warnings[0].Text | Should -Be 'Status: App-Updates-Verlauf nicht lesbar - die Angaben dazu fehlen hier'
        @((Get-HMStatusData -Now ([datetime]'2026-11-26 10:00')).Warnings).Count | Should -Be 0
    }
    It 'Server-Backup-Profil ohne jeden Lauf ergibt einen Hinweis, keine Warnung' {
        $p = [pscustomobject]@{ Name = 'Neu'; DiskPrefix = 'HUMIG-NEU'; Disks = 2; WarnDays = 14; ArchiveDisks = 0; ArchiveDays = 30 }
        $s = Get-HMStatusData -SbProfiles @($p) -SbHistory @() -Now ([datetime]'2026-11-26 10:00')
        @($s.Notes | Where-Object { $_.Text -match "Server-Backup 'Neu': noch kein Lauf" -and $_.Level -eq 'Info' }).Count | Should -Be 1
        @($s.Warnings | Where-Object { $_.Text -match 'noch kein Lauf' }).Count | Should -Be 0
    }
    It 'JSON-Datei pruefen: fehlt = lesbar, leer oder beschaedigt = nicht lesbar' {
        Test-HMStatusJsonFile '' | Should -BeTrue
        Test-HMStatusJsonFile (Join-Path $TestDrive 'fehlt.json') | Should -BeTrue
        $f = Join-Path $TestDrive 'st.json'
        [IO.File]::WriteAllText($f, '{"a":1}'); Test-HMStatusJsonFile $f | Should -BeTrue
        [IO.File]::WriteAllText($f, '{"a":'); Test-HMStatusJsonFile $f | Should -BeFalse
        [IO.File]::WriteAllText($f, ''); Test-HMStatusJsonFile $f | Should -BeFalse
    }
    It 'Startseite gibt die nicht lesbaren Quellen weiter' {
        $t = ${function:Update-HMStatusPage}.ToString()
        $t | Should -Match ([regex]::Escape('-Unreadable $unread'))
        $t | Should -Match ([regex]::Escape("catch { `$unread += 'App-Updates-Verlauf' }"))
    }
}
