#Requires -Version 5.1
# Pester-Tests (Pester 5): Zugriffsprotokoll der Handy-Fernbedienung - keine Verknuepfung im Protokollpfad, entschaerfte Werte,
# Groessengrenze. Echte Junctions im Temp-Ordner (cmd /c mklink /J, ohne Adminrechte), keine festen Laufwerke, kein Eingriff am System.

BeforeAll {
    $script:Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    . (Join-Path $script:Root 'Functions\Remote-Core.ps1')
    . (Join-Path $script:Root 'Functions\UI-Remote.ps1')
    function New-HMTestJunction([string]$Link, [string]$Target) {
        New-Item -ItemType Directory -Path $Target -Force | Out-Null
        New-Item -ItemType Directory -Path (Split-Path $Link -Parent) -Force | Out-Null
        $o = & cmd.exe /c mklink /J "$Link" "$Target" 2>&1
        if (-not (Test-Path -LiteralPath $Link)) { throw "Junction nicht angelegt: $o" }
    }
    # Out-Console steckt im Hauptskript (HUMig.ps1): nur fuer die Ausgabe der Oberflaeche aufzeichnen. Remote-Core fragt es nicht ab.
    function Out-Console([string]$Msg, [string]$Lvl = 'Info') { $script:Out += , @($Lvl, $Msg) }
}

Describe 'Zugriffsprotokoll der Fernbedienung' {
    BeforeEach {
        # eigener Ordner je Test; Pfade immer ueber denselben Weg gebildet (Kurznamen im Temp-Pfad des CI-Runners)
        $script:Logs = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8) + '\Logs')
        $script:Rem = Join-Path $script:Logs 'Remote'
        New-Item -ItemType Directory -Path $script:Rem -Force | Out-Null
        $script:File = Join-Path $script:Rem 'Remote_2026-11.log'
    }
    It 'Werte des Aufrufers: keine Zeilenumbrueche, Steuer- oder Zeilentrennzeichen, Laenge begrenzt' {
        $t = ConvertTo-HMRemoteLogText ("Origin: x`r`n2026-01-01 00:00:00  gefaelschte Zeile`t" + [char]0x85 + [char]0x2028 + [char]0x2029 + ('A' * 2000))
        $t | Should -Not -Match '[\r\n\t\u0085\u2028\u2029\u200E\u202E]'
        $t.Length | Should -BeLessThan 700
        ConvertTo-HMRemoteLogText ("a" + [char]0x2028 + "b") | Should -Be 'a b'
        # uebrige C1-Zeichen und Zeichen, die die Schreibrichtung umordnen
        foreach ($c in @(0x80, 0x9B, 0x9F, 0x200E, 0x200F, 0x202A, 0x202E, 0x2066, 0x2069)) { ConvertTo-HMRemoteLogText ("a" + [char]$c + "b") | Should -Be 'a b' }
        ConvertTo-HMRemoteLogText 'Umlaute äöü und Text' | Should -Be 'Umlaute äöü und Text'
    }
    It 'schreibt im Normalfall eine Zeile je Eintrag' {
        $S = @{ LogFile = $script:File }
        Write-HMRemoteLog $S "Zeile 1`r`nZeile 2"
        Write-HMRemoteLog $S 'Zeile 3'
        @(Get-Content -LiteralPath $script:File).Count | Should -Be 2
        Test-HMRemoteLogTarget $script:File | Should -Be ''
    }
    It 'Ordner Remote wird im Betrieb gegen eine Junction getauscht: nicht geschrieben, Ereignis genau einmal, Ausgabe genau einmal' {
        $q = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue))
        $S = @{ LogFile = $script:File; Events = $q }
        Write-HMRemoteLog $S 'vorher'
        $fremd = Join-Path (Split-Path $script:Logs -Parent) 'Fremd'
        Remove-Item -LiteralPath $script:Rem -Recurse -Force
        New-HMTestJunction $script:Rem $fremd
        Write-HMRemoteLog $S 'darf nicht ankommen'
        Write-HMRemoteLog $S 'darf auch nicht ankommen'
        Test-Path -LiteralPath (Join-Path $fremd 'Remote_2026-11.log') | Should -BeFalse
        Test-HMRemoteLogTarget $script:File | Should -Match 'Verknuepfung'
        $q.Count | Should -Be 1
        $q.Peek().Kind | Should -Be 'LogBlocked'
        # Ausgabe in der Oberflaeche
        $script:Out = @()
        Show-HMRemoteEvents $S
        $S.Events.Enqueue(@{ Kind = 'LogBlocked'; Text = 'zweites Mal' })
        Show-HMRemoteEvents $S
        @($script:Out | Where-Object { $_[0] -eq 'Warning' -and $_[1] -match 'Zugriffsprotokoll wird nicht geschrieben' }).Count | Should -Be 1
        @($script:Out).Count | Should -Be 1
        $q.Count | Should -Be 0
    }
    It 'Ordner Logs ist eine Junction: nicht geschrieben' {
        $base = Split-Path $script:Logs -Parent
        Remove-Item -LiteralPath $script:Logs -Recurse -Force
        $fremd = Join-Path $base 'FremdLogs'
        New-HMTestJunction $script:Logs $fremd
        New-Item -ItemType Directory -Path (Join-Path $fremd 'Remote') -Force | Out-Null
        Write-HMRemoteLog @{ LogFile = $script:File } 'darf nicht ankommen'
        Test-Path -LiteralPath (Join-Path $fremd 'Remote\Remote_2026-11.log') | Should -BeFalse
    }
    It 'grosses Protokoll wird weiter beschrieben (keine Groessengrenze)' {
        Set-Content -LiteralPath $script:File -Value ('x' * 200000)
        $len = (Get-Item -LiteralPath $script:File).Length
        Write-HMRemoteLog @{ LogFile = $script:File } 'neu'
        (Get-Item -LiteralPath $script:File).Length | Should -BeGreaterThan $len
        Get-Content -LiteralPath $script:File -Tail 1 | Should -Match 'neu$'
    }
}