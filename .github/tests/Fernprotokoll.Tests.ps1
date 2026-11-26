#Requires -Version 5.1
# Pester-Tests (Pester 5): Zugriffsprotokoll der Handy-Fernbedienung - keine Verknuepfung im Protokollpfad, entschaerfte Werte,
# Groessengrenze. Echte Junctions im Temp-Ordner (cmd /c mklink /J, ohne Adminrechte), keine festen Laufwerke, kein Eingriff am System.

BeforeAll {
    $script:Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    . (Join-Path $script:Root 'Functions\Remote-Core.ps1')
    function New-HMTestJunction([string]$Link, [string]$Target) {
        New-Item -ItemType Directory -Path $Target -Force | Out-Null
        New-Item -ItemType Directory -Path (Split-Path $Link -Parent) -Force | Out-Null
        $o = & cmd.exe /c mklink /J "$Link" "$Target" 2>&1
        if (-not (Test-Path -LiteralPath $Link)) { throw "Junction nicht angelegt: $o" }
    }
    # Meldungen der Oberflaeche ersetzen (nur aufzeichnen)
    function Out-Console([string]$Text, [string]$Level = 'Info') { $script:Console += , @($Level, $Text) }
}

Describe 'Zugriffsprotokoll der Fernbedienung' {
    BeforeEach {
        $script:Console = @()
        # eigener Ordner je Test; Pfade immer ueber denselben Weg gebildet (Kurznamen im Temp-Pfad des CI-Runners)
        $script:Logs = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8) + '\Logs')
        $script:Rem = Join-Path $script:Logs 'Remote'
        New-Item -ItemType Directory -Path $script:Rem -Force | Out-Null
        $script:File = Join-Path $script:Rem 'Remote_2026-11.log'
    }
    It 'Werte des Aufrufers: keine Zeilenumbrueche, Steuer- oder Zeilentrennzeichen, Laenge begrenzt' {
        $t = ConvertTo-HMRemoteLogText ("Origin: x`r`n2026-01-01 00:00:00  gefaelschte Zeile`t" + [char]0x85 + [char]0x2028 + [char]0x2029 + ('A' * 2000))
        $t | Should -Not -Match "[`r`n`t\u0085  ]"
        $t.Length | Should -BeLessThan 700
        ConvertTo-HMRemoteLogText ("a" + [char]0x2028 + "b") | Should -Be 'a b'
    }
    It 'schreibt im Normalfall eine Zeile je Eintrag' {
        $S = @{ LogFile = $script:File }
        Write-HMRemoteLog $S "Zeile 1`r`nZeile 2"
        Write-HMRemoteLog $S 'Zeile 3'
        @(Get-Content -LiteralPath $script:File).Count | Should -Be 2
        Test-HMRemoteLogTarget $script:File | Should -Be ''
    }
    It 'Ordner Remote wird im Betrieb gegen eine Junction getauscht: nicht geschrieben, einmal gemeldet' {
        $S = @{ LogFile = $script:File }
        Write-HMRemoteLog $S 'vorher'
        $fremd = Join-Path (Split-Path $script:Logs -Parent) 'Fremd'
        Remove-Item -LiteralPath $script:Rem -Recurse -Force
        New-HMTestJunction $script:Rem $fremd
        Write-HMRemoteLog $S 'darf nicht ankommen'
        Write-HMRemoteLog $S 'darf auch nicht ankommen'
        Test-Path -LiteralPath (Join-Path $fremd 'Remote_2026-11.log') | Should -BeFalse
        Test-HMRemoteLogTarget $script:File | Should -Match 'Verknuepfung'
        @($script:Console | Where-Object { $_[0] -eq 'Warning' -and $_[1] -match 'Zugriffsprotokoll wird nicht geschrieben' }).Count | Should -Be 1
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
    It 'im Webserver (ohne Oberflaeche) wird der Fund als Ereignis weitergegeben, nicht geschrieben' {
        $fremd = Join-Path (Split-Path $script:Logs -Parent) 'Fremd2'
        Remove-Item -LiteralPath $script:Rem -Recurse -Force
        New-HMTestJunction $script:Rem $fremd
        $q = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue))
        $S = @{ LogFile = $script:File; Events = $q }
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'Out-Console' }
        Write-HMRemoteLog $S 'x'
        Write-HMRemoteLog $S 'y'
        $q.Count | Should -Be 1
        $q.Peek().Kind | Should -Be 'LogBlocked'
        Test-Path -LiteralPath (Join-Path $fremd 'Remote_2026-11.log') | Should -BeFalse
    }
    It 'Groessengrenze: volles Protokoll bekommt eine letzte Zeile "Protokoll voll", danach nichts mehr' {
        $keep = $script:HMRemoteLogMaxBytes; $script:HMRemoteLogMaxBytes = 100
        try {
            Set-Content -LiteralPath $script:File -Value ('x' * 200)
            $S = @{ LogFile = $script:File }
            Write-HMRemoteLog $S 'neu 1'
            Write-HMRemoteLog $S 'neu 2'
            $l = @(Get-Content -LiteralPath $script:File)
            $l.Count | Should -Be 2
            $l[1] | Should -Match 'Protokoll voll'
        } finally { $script:HMRemoteLogMaxBytes = $keep }
    }
    It 'volles Protokoll in einem gegen eine Junction getauschten Ordner: auch keine letzte Zeile' {
        $fremd = Join-Path (Split-Path $script:Logs -Parent) 'Fremd3'
        Remove-Item -LiteralPath $script:Rem -Recurse -Force
        New-HMTestJunction $script:Rem $fremd
        Set-Content -LiteralPath (Join-Path $fremd 'Remote_2026-11.log') -Value ('x' * 200)
        $keep = $script:HMRemoteLogMaxBytes; $script:HMRemoteLogMaxBytes = 100
        try { Write-HMRemoteLog @{ LogFile = $script:File } 'neu' } finally { $script:HMRemoteLogMaxBytes = $keep }
        @(Get-Content -LiteralPath (Join-Path $fremd 'Remote_2026-11.log')).Count | Should -Be 1
    }
}
