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
function Get-NetAdapter { [pscustomobject]@{ InterfaceGuid = '{00000000-0000-0000-0000-000000000001}' } }
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
function ipconfig.exe { }
function Start-Sleep { }
function New-NetIPAddress { param($InterfaceIndex, $IPAddress, $PrefixLength, $DefaultGateway)
    if ($global:T_S.FailAll -or ($global:T_S.FailNew -and $IPAddress -eq $global:T_S.NewIp)) { throw 'Testfehler beim Anlegen der Adresse' }
    $st = if ($global:T_S.Dup -and $IPAddress -eq $global:T_S.NewIp) { 'Duplicate' } else { 'Preferred' }
    [void]$global:T_Addrs.Add([pscustomobject]@{ IPAddress = $IPAddress; PrefixLength = [int]$PrefixLength; PrefixOrigin = 'Manual'; AddressState = $st })
    if ($DefaultGateway) { [void]$global:T_Gw.Add($DefaultGateway) } }
'@
        $script:NetEpilog = @'
[pscustomobject]@{ Dhcp = $global:T_Dhcp; Addrs = @($global:T_Addrs); Gw = @($global:T_Gw); Dns = @($global:T_Dns); DnsStatic = $global:T_DnsStatic } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $env:HM_TEST_OUT -Encoding UTF8
'@
        $script:NetStubNames = @('Get-NetIPInterface', 'Get-NetAdapter', 'Get-ItemProperty', 'Get-NetIPAddress', 'Get-NetRoute', 'Get-DnsClientServerAddress', 'Remove-NetRoute', 'Remove-NetIPAddress', 'Set-NetIPInterface', 'Set-DnsClientServerAddress', 'ipconfig.exe', 'Start-Sleep', 'New-NetIPAddress')
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
    It 'DHCP ohne Antwort des DHCP-Servers: FEHLER und Rueckbau auf die statische Adresse' {
        $r = & $script:RunNet $script:StaticOld @{ Index = 7; Mode = 'DHCP'; WaitDhcpSec = 2 }
        ($r.Lines -join ' ') | Should -Match 'keine Adresse vom DHCP-Server.*alter Zustand wiederhergestellt'
        $r.End.Dhcp | Should -BeFalse
        @($r.End.Addrs | ForEach-Object { $_.IPAddress }) | Should -Be @($script:OldIp)
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
