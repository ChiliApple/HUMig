#Requires -Version 5.1
# Pester-Tests (Pester 5) fuer das Server-Backup: Abbrechen, Zustandsdateien, Plattenabgleich, Laufzeit-Schaetzung
# Nur Ersatzobjekte im Temp-Ordner (TestDrive) - kein wbadmin, keine Platten, keine Aufgabenplanung, keine Registry.

BeforeAll {
    $script:Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    . (Join-Path $script:Root 'Functions\ServerBackup-Engine.ps1')
    # Windows-Ereignisprotokoll nie wirklich schreiben
    function Write-HMSbEvent([string]$Status, [string]$Message) { $script:TestEvents += , @($Status, $Message) }
    $script:TestEvents = @()
}

Describe 'Server-Backup: Abbrechen beendet nur den eigenen Lauf (SB-01)' {
    BeforeEach { $script:Job = @{ Cancel = $false; Log = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue)) } }
    It 'Abbruch waehrend des Wartens auf einen fremden Vorgang: kein eigener Start, kein stop job' {
        Mock Wait-HMSbIdle { $false }
        Mock Invoke-HMSbWbadmin { throw 'darf nicht laufen' }
        $r = Invoke-HMSbStart -Arguments 'start backup -backupTarget:X: -quiet' -Job $script:Job
        $r.Started | Should -BeFalse
        $r.Busy | Should -BeTrue
        Test-HMSbOwnJobRunning $r | Should -BeFalse
        Stop-HMSbOwnJob $r | Should -BeFalse
        Should -Invoke Invoke-HMSbWbadmin -Times 0
    }
    It 'Abbruch in der Wiederholungs-Pause nach "anderer Vorgang laeuft": kein stop job' {
        Mock Wait-HMSbIdle { $true }
        Mock Invoke-HMSbWbadmin { $script:Job.Cancel = $true; [pscustomobject]@{ ExitCode = 1; Lines = @(); Text = 'Ein weiterer Sicherungs- oder Wiederherstellungsvorgang wird ausgefuehrt'; LogFiles = @() } }
        $r = Invoke-HMSbStart -Arguments 'start backup -backupTarget:X: -quiet' -Job $script:Job
        $r.Started | Should -BeTrue
        $r.Busy | Should -BeTrue
        Test-HMSbOwnJobRunning $r | Should -BeFalse
    }
    It 'Abbruch waehrend des eigenen Laufs (Prozess beendet, Exitcode ungleich 0): stop job' {
        Mock Wait-HMSbIdle { $true }
        Mock Invoke-HMSbWbadmin { param($Arguments) if ($Arguments -like 'stop job*') { $script:Stopped = $true }; [pscustomobject]@{ ExitCode = -1; Lines = @(); Text = ''; LogFiles = @() } }
        $script:Stopped = $false
        $r = Invoke-HMSbStart -Arguments 'start backup -backupTarget:X: -quiet' -Job $script:Job
        Test-HMSbOwnJobRunning $r | Should -BeTrue
        Stop-HMSbOwnJob $r | Should -BeTrue
        $script:Stopped | Should -BeTrue
    }
    It 'eigener Lauf schon fertig (Exitcode 0): kein stop job' {
        Test-HMSbOwnJobRunning ([pscustomobject]@{ ExitCode = 0; Started = $true; Busy = $false }) | Should -BeFalse
        Test-HMSbOwnJobRunning $null | Should -BeFalse
    }
    It 'alle drei Abbruch-Stellen im Hauptablauf gehen ueber Stop-HMSbOwnJob, kein direktes stop job mehr' {
        $eng = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:Root 'Functions\ServerBackup-Engine.ps1')
        ([regex]::Matches($eng, 'Stop-HMSbOwnJob \$r[23]?\)')).Count | Should -Be 3
        ([regex]::Matches($eng, "'stop job -quiet'")).Count | Should -Be 1
    }
}

Describe 'Server-Backup: Schreibtempo ohne Wartezeit (SB-07)' {
    It 'WbSec zaehlt nur die Laufzeit von wbadmin, nicht das Warten' {
        $job = @{ Cancel = $false }
        Mock Wait-HMSbIdle { Start-Sleep -Milliseconds 400; $true }
        Mock Invoke-HMSbWbadmin { [pscustomobject]@{ ExitCode = 0; Lines = @(); Text = ''; LogFiles = @() } }
        $r = Invoke-HMSbStart -Arguments 'start backup -backupTarget:X: -quiet' -Job $job
        [double]$r.WbSec | Should -BeLessThan 0.3
    }
}

Describe 'Server-Backup: Zustandsdateien sicher lesen und schreiben (SB-05)' {
    BeforeEach {
        $script:Dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Dir -Force | Out-Null
        $script:TestEvents = @()
        [void](Get-HMSbStateNotes)
        $script:SbCorruptSeen = @{}
    }
    It 'schreibt ueber eine Hilfsdatei: Inhalt lesbar, UTF-8 mit BOM, keine Hilfsdatei bleibt liegen' {
        $p = Join-Path $script:Dir 'history.json'
        Add-HMSbHistory $p ([pscustomobject]@{ Date = '2026-11-25 10:00'; Profile = 'P'; Host = 'H'; Disk = 'D-1' })
        Add-HMSbHistory $p ([pscustomobject]@{ Date = '2026-11-25 11:00'; Profile = 'P'; Host = 'H'; Disk = 'D-1' })
        $h = Read-HMSbHistory $p
        $h.Count | Should -Be 2
        $b = [System.IO.File]::ReadAllBytes($p)
        ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) | Should -BeTrue
        @(Get-ChildItem -LiteralPath $script:Dir -File | Where-Object { $_.Name -ne 'history.json' }).Count | Should -Be 0
    }
    It 'Anzeige: beschaedigter Verlauf ergibt leer, wird aber NICHT umbenannt, Meldung genau einmal' {
        $p = Join-Path $script:Dir 'history.json'
        Set-Content -LiteralPath $p -Value '[{"Date":"2026-11-01 10:00","Profile":"P"' -Encoding UTF8
        $h = Read-HMSbHistory $p
        $h.Count | Should -Be 0
        $h = Read-HMSbHistory $p
        Test-Path -LiteralPath $p | Should -BeTrue
        @(Get-ChildItem -LiteralPath $script:Dir -Filter '*defekt*').Count | Should -Be 0
        @(Get-HMSbStateNotes).Count | Should -Be 1
    }
    It 'Eintrag in beschaedigten Verlauf: Datei wird mit Zeitstempel beiseitegelegt, gemeldet, neu begonnen' {
        $p = Join-Path $script:Dir 'history.json'
        $bad = '[{"Date":"2026-11-01 10:00","Profile":"P"'
        [System.IO.File]::WriteAllText($p, $bad)
        Add-HMSbHistory $p ([pscustomobject]@{ Date = '2026-11-25 10:00'; Profile = 'P'; Host = 'H'; Disk = 'D-1' })
        $moved = @(Get-ChildItem -LiteralPath $script:Dir -Filter 'history.defekt-*.json')
        $moved.Count | Should -Be 1
        $moved[0].Name | Should -Match '^history\.defekt-\d{8}-\d{6}\.json$'
        [System.IO.File]::ReadAllText($moved[0].FullName) | Should -Be $bad
        $h = Read-HMSbHistory $p
        $h.Count | Should -Be 1
        @(Get-HMSbStateNotes) -join ' ' | Should -Match 'beiseitegelegt'
        $script:TestEvents.Count | Should -Be 1
    }
    It 'leere Datei (0 Byte) zaehlt als leerer Verlauf, nichts wird beiseitegelegt' {
        $p = Join-Path $script:Dir 'history.json'
        [System.IO.File]::WriteAllBytes($p, [byte[]]@())
        (Read-HMSbJsonState $p).State | Should -Be 'Empty'
        Add-HMSbHistory $p ([pscustomobject]@{ Date = '2026-11-25 10:00'; Profile = 'P' })
        $h = Read-HMSbHistory $p
        $h.Count | Should -Be 1
        @(Get-ChildItem -LiteralPath $script:Dir -Filter '*defekt*').Count | Should -Be 0
    }
    It 'nicht lesbare (gesperrte) Datei wird nie ueberschrieben: Fehler an den Aufrufer, Inhalt unveraendert' {
        $p = Join-Path $script:Dir 'history.json'
        $good = '[{"Date":"2026-11-01 10:00","Profile":"P"}]'
        [System.IO.File]::WriteAllText($p, $good)
        $lock = New-Object System.IO.FileStream($p, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        try {
            (Read-HMSbJsonState $p).State | Should -Be 'Unreadable'
            { Add-HMSbHistory $p ([pscustomobject]@{ Date = '2026-11-25 10:00'; Profile = 'P' }) } | Should -Throw '*nicht lesbar*'
        } finally { $lock.Dispose() }
        [System.IO.File]::ReadAllText($p) | Should -Be $good
        @(Get-ChildItem -LiteralPath $script:Dir -File).Count | Should -Be 1
    }
    It 'Profile auf der Platte, Entfernen und Umbenennen legen eine beschaedigte Datei ebenfalls beiseite' {
        $pf = Join-Path $script:Dir 'profiles.json'
        [System.IO.File]::WriteAllText($pf, '{kaputt')
        Save-HMSbDiskProfile $script:Dir ([pscustomobject]@{ Name = 'GYM'; DiskPrefix = 'HUMIG-GYM' })
        $l = Read-HMSbDiskProfiles $script:Dir
        @($l).Count | Should -Be 1
        @(Get-ChildItem -LiteralPath $script:Dir -Filter 'profiles.defekt-*.json').Count | Should -Be 1
        $hp = Join-Path $script:Dir 'history.json'
        [System.IO.File]::WriteAllText($hp, '[{')
        Remove-HMSbHistory $hp @('x|y|z') | Should -Be 0
        @(Get-ChildItem -LiteralPath $script:Dir -Filter 'history.defekt-*.json').Count | Should -Be 1
        Add-HMSbHistory $hp ([pscustomobject]@{ Date = 'd'; Profile = 'ALT'; Host = 'h'; Disk = 'k' })
        Rename-HMSbProfileInFile $hp 'ALT' 'NEU' | Should -Be 1
        $h = Read-HMSbHistory $hp
        $h[0].Profile | Should -Be 'NEU'
        Remove-HMSbHistory $hp @('d|h|k') | Should -Be 1
    }
    It 'Plattenzustand: beschaedigte Datei wird bei der naechsten Messung beiseitegelegt' {
        $p = Join-Path $script:Dir 'disk-health.json'
        [System.IO.File]::WriteAllText($p, '{"HV-1": [')
        (Read-HMSbHealthStore $p).Count | Should -Be 0
        @(Get-ChildItem -LiteralPath $script:Dir -Filter '*defekt*').Count | Should -Be 0
        Add-HMSbHealthStore $p 'HV-1' ([pscustomobject]@{ Date = '2026-11-25 10:00'; Health = 'Healthy' })
        @(Get-ChildItem -LiteralPath $script:Dir -Filter 'disk-health.defekt-*.json').Count | Should -Be 1
        $s = Read-HMSbHealthStore $p
        @($s['HV-1']).Count | Should -Be 1
    }
    It 'Laufend-Markierung wird ueber eine Hilfsdatei geschrieben und gelesen' {
        $ctx = @{ LocalHistory = (Join-Path $script:Dir 'history.json'); Profile = 'GYM'; DiskLabel = 'HV-1'; VMs = @('DC1'); Volumes = @() }
        Set-HMSbRunMarker $ctx 'X:\R' (Get-Date)
        $f = Get-HMSbRunMarkerPath $script:Dir 'GYM'
        (Read-HMSbJsonState $f).State | Should -Be 'Ok'
        (Read-HMSbJsonState $f).Data.Disk | Should -Be 'HV-1'
        Clear-HMSbRunMarker $ctx
        Test-Path -LiteralPath $f | Should -BeFalse
    }
    It 'Zeitplan-Skript liest serverbackup.json ohne beiseitezulegen und nennt den Grund' {
        $tsk = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:Root 'Functions\ServerBackup-Task.ps1')
        $tsk | Should -Match "Read-HMSbJsonState \(Join-Path \`$cfgDir 'serverbackup.json'\)"
        $tsk | Should -Match 'serverbackup.json ist beschaedigt'
        $tsk | Should -Not -Match 'Read-HMSbJsonForWrite'
    }
}

Describe 'Server-Backup: Profile (serverbackup.json) in der Oberflaeche (US-05, US-06)' {
    BeforeAll {
        $script:AppRoot = $script:Root
        $script:ConfigDir = Join-Path $TestDrive 'CfgUi'
        $script:LogDir = Join-Path $TestDrive 'LogsUi'
        New-Item -ItemType Directory -Path $script:ConfigDir -Force | Out-Null
        . (Join-Path $script:Root 'Functions\UI-ServerBackup.ps1')
        function Out-Console([string]$Text, [string]$Level = 'Info') { $script:Console += , @($Level, $Text) }
        function Write-JsonFile([string]$Path, $Data, [int]$Depth = 6) { $Data | ConvertTo-Json -Depth $Depth | Set-Content -LiteralPath $Path -Encoding UTF8 }
    }
    BeforeEach {
        $script:Console = @()
        $script:SbCorruptSeen = @{}
        Get-ChildItem -LiteralPath $script:ConfigDir -File -ErrorAction SilentlyContinue | Remove-Item -Force
    }
    It 'beschaedigte Datei: keine Profile, Meldung, Datei bleibt bis zum Speichern; Speichern legt sie beiseite' {
        [System.IO.File]::WriteAllText($script:SbCfgFile, '{"Profiles":[{"Name":"GYM"')
        $c = Get-HMSbConfig
        @($c.Profiles).Count | Should -Be 0
        @($script:Console | Where-Object { $_[0] -eq 'Error' }).Count | Should -Be 1
        Test-Path -LiteralPath $script:SbCfgFile | Should -BeTrue
        $c.LastProfile = 'X'
        Save-HMSbConfig $c
        @(Get-ChildItem -LiteralPath $script:ConfigDir -Filter 'serverbackup.defekt-*.json').Count | Should -Be 1
        (Get-HMSbConfig).LastProfile | Should -Be 'X'
    }
    It 'gesperrte Datei: Speichern schreibt nichts und meldet es' {
        $good = '{"LastProfile":"GYM","Profiles":[{"Name":"GYM","VMs":["DC1"]}],"Renames":[]}'
        [System.IO.File]::WriteAllText($script:SbCfgFile, $good)
        $c = Get-HMSbConfig
        $lock = New-Object System.IO.FileStream($script:SbCfgFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        try { Save-HMSbConfig $c } finally { $lock.Dispose() }
        [System.IO.File]::ReadAllText($script:SbCfgFile) | Should -Be $good
        @($script:Console | Where-Object { $_[1] -match 'NICHT gespeichert' }).Count | Should -Be 1
    }
    It 'Felder einer neueren Version bleiben beim Speichern erhalten (Profil und Datei)' {
        [System.IO.File]::WriteAllText($script:SbCfgFile, '{"LastProfile":"GYM","Profiles":[{"Name":"GYM","VMs":["DC1"],"NeuesFeld":"x"}],"Renames":[],"Zukunft":{"a":1}}')
        $c = Get-HMSbConfig
        Save-HMSbConfig $c
        $j = Get-Content -Raw -LiteralPath $script:SbCfgFile | ConvertFrom-Json
        $j.Profiles[0].NeuesFeld | Should -Be 'x'
        $j.Zukunft.a | Should -Be 1
        @($j.Profiles[0].VMs) | Should -Be @('DC1')
    }
}
Describe 'Server-Backup: Speichern, Planen, Starten nur mit gelesener Liste (US-02)' {
    BeforeAll {
        $script:AppRoot = $script:Root
        if (-not $script:ConfigDir) { $script:ConfigDir = Join-Path $TestDrive 'CfgUi2'; $script:LogDir = Join-Path $TestDrive 'LogsUi2' }
        . (Join-Path $script:Root 'Functions\UI-ServerBackup.ps1')
    }
    It 'Ladezustand: lesen geht vor, Fehler vor Ok' {
        Get-HMSbListState 'Loading' 'Ok' | Should -Be 'Loading'
        Get-HMSbListState 'Ok' 'Loading' | Should -Be 'Loading'
        Get-HMSbListState 'Error' 'Ok' | Should -Be 'Error'
        Get-HMSbListState 'Ok' 'Error' | Should -Be 'Error'
        Get-HMSbListState 'Ok' 'Ok' | Should -Be 'Ok'
    }
    It 'vor dem ersten Lesen gilt die Liste als "wird gelesen" (nie als leer)' {
        $script:SbVmsState | Should -Be 'Loading'
        Get-HMSbListState | Should -Be 'Loading'
    }
    It 'Engine liefert Lesefehler fuer VMs und Laufwerke getrennt' {
        Mock Test-HMSbHyperVHost { $true }
        Mock Get-HMSbVmList { throw 'Hyper-V antwortet nicht' }
        Mock Get-HMSbVolumeList { , @([pscustomobject]@{ Letter = 'D:' }) }
        $r = Get-HMSbSources
        $r.VmError | Should -Match 'Hyper-V'
        $r.VolError | Should -BeNullOrEmpty
        Mock Test-HMSbHyperVHost { $false }
        (Get-HMSbSources).VmError | Should -BeNullOrEmpty
    }
    It 'Speichern, Neu, Planen und Starten pruefen den Ladezustand' {
        $ui = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:Root 'Functions\UI-ServerBackup.ps1')
        foreach ($fn in @('Save-HMSbProfile', 'New-HMSbProfile', 'New-HMSbSchedule', 'Start-HMSbBackup')) {
            $body = [regex]::Match($ui, "(?s)function $fn \{.*?\r?\n\}\r?\n").Value
            $body | Should -Match 'Get-HMSbListState'
        }
        $sv = [regex]::Match($ui, '(?s)function Save-HMSbProfile \{.*?\r?\n\}\r?\n').Value
        $sv | Should -Match 'if \(-not \$keepVms\) \{ \$x\.VMs = @\(Get-HMSbCheckedVms\) \}'
    }
}

Describe 'Server-Backup: Auswerfen und Einrichten gegen laufende Sicherungen (US-03, US-04)' {
    BeforeAll {
        $script:AppRoot = $script:Root
        . (Join-Path $script:Root 'Functions\UI-ServerBackup.ps1')
    }
    It 'nennt eine Sicherung (auch im Hintergrund) auf genau dieser Platte' {
        $m = @([pscustomobject]@{ Profile = 'GYM'; Disk = 'HUMIG-GYM-1'; Started = (Get-Date).ToString('o'); Kind = 'Zeitplan' })
        $h = @(Get-HMSbDiskRunHints $m @() @() @('humig-gym-1'))
        $h.Count | Should -Be 1
        $h[0] | Should -Match 'SYSTEM'
        @(Get-HMSbDiskRunHints $m @() @() @('HUMIG-GYM-2')).Count | Should -Be 0
    }
    It 'laufende Aufgabe ohne Markierung wird genannt, mit Markierung nicht doppelt' {
        $t = @([pscustomobject]@{ TaskName = 'Server-Backup - GYM - taeglich 22-00'; State = 'Running' })
        @(Get-HMSbDiskRunHints @() $t @() @('HUMIG-GYM-1')).Count | Should -Be 1
        $m = @([pscustomobject]@{ Profile = 'GYM'; Disk = 'HUMIG-GYM-2'; Started = (Get-Date).ToString('o'); Kind = 'Zeitplan' })
        @(Get-HMSbDiskRunHints $m $t @() @('HUMIG-GYM-1')).Count | Should -Be 0
    }
    It 'wbadmin auf ein anderes Ziel betrifft die Platte nicht, ohne erkennbares Ziel schon' {
        $b = @('wbadmin (PID 1): start backup -backupTarget:F: -quiet')
        @(Get-HMSbDiskRunHints @() @() $b @('X') @('E')).Count | Should -Be 0
        @(Get-HMSbDiskRunHints @() @() $b @('X') @('F:')).Count | Should -Be 1
        @(Get-HMSbDiskRunHints @() @() @('Windows Server-Sicherung: Backup laeuft') @('X') @('E')).Count | Should -Be 1
    }
    It 'Auswerfen, Offline-Schalten und Einrichten fragen vorher nach' {
        $ui = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:Root 'Functions\UI-ServerBackup.ps1')
        ([regex]::Match($ui, '(?s)function Invoke-HMSbEject \{.*?\r?\n\}\r?\n').Value | Select-String -Pattern 'Confirm-HMSbNoRunOnDisk' -AllMatches).Matches.Count | Should -Be 2
        [regex]::Match($ui, '(?s)function Invoke-HMSbDiskSetup\(.*?\r?\n\}\r?\n').Value | Should -Match 'Confirm-HMSbNoRunOnDisk'
    }
    It 'Einrichten: markierte Zeile muss zur gemerkten Platte passen (zwei offene Fenster)' {
        $d = [pscustomobject]@{ Number = 3; Model = 'WD Elements'; Serial = 'S1' }
        Test-HMSbDiskRowMatch ([pscustomobject]@{ Nr = 3; Modell = 'WD Elements'; Seriennummer = 'S1' }) $d | Should -BeTrue
        Test-HMSbDiskRowMatch ([pscustomobject]@{ Nr = 3; Modell = 'Seagate'; Seriennummer = 'S9' }) $d | Should -BeFalse
        Test-HMSbDiskRowMatch $null $d | Should -BeFalse
    }
}