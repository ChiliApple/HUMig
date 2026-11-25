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
        Mock Wait-HMSbIdle { Start-Sleep -Milliseconds 1500; $true }
        Mock Invoke-HMSbWbadmin { [pscustomobject]@{ ExitCode = 0; Lines = @(); Text = ''; LogFiles = @() } }
        $r = Invoke-HMSbStart -Arguments 'start backup -backupTarget:X: -quiet' -Job $job
        [double]$r.WbSec | Should -BeLessThan 1.0
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
        Save-HMSbDiskProfile $script:Dir ([pscustomobject]@{ Name = 'PROFIL-A'; DiskPrefix = 'HUMIG-PROFIL-A' })
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
        $ctx = @{ LocalHistory = (Join-Path $script:Dir 'history.json'); Profile = 'PROFIL-A'; DiskLabel = 'HV-1'; VMs = @('DC1'); Volumes = @() }
        Set-HMSbRunMarker $ctx 'X:\R' (Get-Date)
        $f = Get-HMSbRunMarkerPath $script:Dir 'PROFIL-A'
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
        [System.IO.File]::WriteAllText($script:SbCfgFile, '{"Profiles":[{"Name":"PROFIL-A"')
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
        $good = '{"LastProfile":"PROFIL-A","Profiles":[{"Name":"PROFIL-A","VMs":["DC1"]}],"Renames":[]}'
        [System.IO.File]::WriteAllText($script:SbCfgFile, $good)
        $c = Get-HMSbConfig
        $lock = New-Object System.IO.FileStream($script:SbCfgFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        try { Save-HMSbConfig $c } finally { $lock.Dispose() }
        [System.IO.File]::ReadAllText($script:SbCfgFile) | Should -Be $good
        @($script:Console | Where-Object { $_[1] -match 'NICHT gespeichert' }).Count | Should -Be 1
    }
    It 'Felder einer neueren Version bleiben beim Speichern erhalten (Profil und Datei)' {
        [System.IO.File]::WriteAllText($script:SbCfgFile, '{"LastProfile":"PROFIL-A","Profiles":[{"Name":"PROFIL-A","VMs":["DC1"],"NeuesFeld":"x"}],"Renames":[],"Zukunft":{"a":1}}')
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
        $m = @([pscustomobject]@{ Profile = 'PROFIL-A'; Disk = 'HUMIG-PROFIL-A-1'; Started = (Get-Date).ToString('o'); Kind = 'Zeitplan' })
        $h = @(Get-HMSbDiskRunHints $m @() @() @('humig-profil-a-1'))
        $h.Count | Should -Be 1
        $h[0] | Should -Match 'SYSTEM'
        @(Get-HMSbDiskRunHints $m @() @() @('HUMIG-PROFIL-A-2')).Count | Should -Be 0
    }
    It 'laufende Aufgabe ohne Markierung wird genannt, mit Markierung nicht doppelt' {
        $t = @([pscustomobject]@{ TaskName = 'Server-Backup - PROFIL-A - taeglich 22-00'; State = 'Running' })
        @(Get-HMSbDiskRunHints @() $t @() @('HUMIG-PROFIL-A-1')).Count | Should -Be 1
        $m = @([pscustomobject]@{ Profile = 'PROFIL-A'; Disk = 'HUMIG-PROFIL-A-2'; Started = (Get-Date).ToString('o'); Kind = 'Zeitplan' })
        @(Get-HMSbDiskRunHints $m $t @() @('HUMIG-PROFIL-A-1')).Count | Should -Be 0
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
Describe 'Server-Backup: Ziel-Platte vor dem Start abgleichen (SB-06)' {
    It 'passt: gleiche Bezeichnung und Seriennummer' {
        Get-HMSbDriveMismatch 'E' 'HUMIG-PROFIL-A-1' 'S1' ([pscustomobject]@{ FileSystemLabel = 'HUMIG-PROFIL-A-1' }) ([pscustomobject]@{ SerialNumber = 'S1' }) | Should -BeNullOrEmpty
    }
    It 'andere Bezeichnung unter dem Buchstaben wird erkannt' {
        Get-HMSbDriveMismatch 'E:' 'HUMIG-PROFIL-A-1' '' ([pscustomobject]@{ FileSystemLabel = 'HUMIG-PROFIL-B-2' }) | Should -Match "HUMIG-PROFIL-B-2.*statt 'HUMIG-PROFIL-A-1'"
    }
    It 'gleiche Bezeichnung, andere Seriennummer wird erkannt; ohne Seriennummer kein Vergleich' {
        Get-HMSbDriveMismatch 'E' 'HUMIG-PROFIL-A-1' 'S1' ([pscustomobject]@{ FileSystemLabel = 'HUMIG-PROFIL-A-1' }) ([pscustomobject]@{ SerialNumber = 'S2' }) | Should -Match 'Seriennummer S2 statt S1'
        Get-HMSbDriveMismatch 'E' 'HUMIG-PROFIL-A-1' '' ([pscustomobject]@{ FileSystemLabel = 'HUMIG-PROFIL-A-1' }) ([pscustomobject]@{ SerialNumber = 'S2' }) | Should -BeNullOrEmpty
        Get-HMSbDriveMismatch 'E' 'HUMIG-PROFIL-A-1' 'S1' ([pscustomobject]@{ FileSystemLabel = 'HUMIG-PROFIL-A-1' }) ([pscustomobject]@{ SerialNumber = '' }) | Should -BeNullOrEmpty
    }
    It 'Hauptablauf warnt (kein Abbruch), Oberflaeche fragt vor dem Start' {
        $eng = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:Root 'Functions\ServerBackup-Engine.ps1')
        $eng | Should -Match 'Get-HMSbDriveMismatch \$L "\$\(\$Ctx\.DiskLabel\)" "\$\(\$Ctx\.DiskSerial\)"'
        $ui = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:Root 'Functions\UI-ServerBackup.ps1')
        [regex]::Match($ui, '(?s)function Start-HMSbBackup \{.*?\r?\n\}\r?\n').Value | Should -Match 'Get-HMSbDriveMismatch'
    }
}

Describe 'Server-Backup: durchgereichte Platten (Pass-Through, SB-02)' {
    BeforeAll {
        function Get-VM { }
        function Get-VMHardDiskDrive { param($VM) }
        function Get-Disk { }
        function Set-Disk { param($Number, $IsOffline) }
        function Get-Volume { }
        function Get-Partition { }
    }
    BeforeEach {
        Mock Get-HMSbOfflineMarks { @() }
        Mock Set-HMSbOfflineMarks { }
        Mock Get-Volume { @() }
        Mock Get-Disk { @([pscustomobject]@{ Number = 4; BusType = 'USB'; IsOffline = $true; FriendlyName = 'An VM'; UniqueId = 'U4' }, [pscustomobject]@{ Number = 5; BusType = 'USB'; IsOffline = $true; FriendlyName = 'Sicherung'; UniqueId = 'U5' }) }
        Mock Set-Disk { }
    }
    It 'Pass-Through-Platte bleibt offline, andere offline USB-Platte wird wie bisher online geschaltet' {
        Mock Get-HMSbPassThroughDisks { , @(4) }
        $r = Get-HMSbDriveList
        Should -Invoke Get-HMSbPassThroughDisks -Times 1 -Exactly -ParameterFilter { $TimeoutSec -gt 0 }
        Should -Invoke Set-Disk -Times 1 -Exactly -ParameterFilter { $Number -eq 5 }
        Should -Invoke Set-Disk -Times 0 -Exactly -ParameterFilter { $Number -eq 4 }
        @($r.Messages) -join ' ' | Should -Match 'Pass-Through'
    }
    It 'VM-Liste nicht lesbar oder zu langsam: wie bisher online schalten, aber Hinweis' {
        Mock Get-HMSbPassThroughDisks { $null }
        $r = Get-HMSbDriveList
        Should -Invoke Set-Disk -Times 2 -Exactly
        @($r.Messages) -join ' ' | Should -Match 'nicht pruefbar'
    }
    It 'Platte einrichten: Pass-Through-Nummern zaehlen als Platten mit VM-Daten' {
        Mock Get-VM { @([pscustomobject]@{ Name = 'FS1'; Path = 'D:\VMs'; ConfigurationLocation = 'D:\VMs'; SnapshotFileLocation = ''; SmartPagingFilePath = '' }) }
        Mock Get-VMHardDiskDrive { @([pscustomobject]@{ Path = 'Disk 4 1.82 TB Bus 0 Lun 0 Target 0'; DiskNumber = 4 }) }
        Mock Get-Partition { @([pscustomobject]@{ DiskNumber = 1; AccessPaths = @('D:\') }) }
        $n = @(Get-HMSbVmDiskNumbers)
        $n -contains 4 | Should -BeTrue
        $n -contains 1 | Should -BeTrue
        (Get-HMSbPassThroughDisks) -contains 4 | Should -BeTrue
        Mock Get-VM { throw 'nicht lesbar' }
        Get-HMSbPassThroughDisks | Should -BeNullOrEmpty
        $null -eq (Get-HMSbPassThroughDisks) | Should -BeTrue
    }
}

Describe 'Server-Backup: Laufzeit-Schaetzung, Versionen, Sperrzeit, frueher Fehler (SB-03, SB-08, SB-11, SB-12)' {
    It 'abgebrochene Laeufe (Zeit bis zur Erkennung) zaehlen nicht zur Schaetzung' {
        $h = @(
            [pscustomobject]@{ Profile = 'PROFIL-A'; Date = '2026-11-01 22:00'; Minutes = 120; Status = 'OK' }
            [pscustomobject]@{ Profile = 'PROFIL-A'; Date = '2026-11-02 22:00'; Minutes = 2900; Status = 'Error'; Aborted = $true }
        )
        Get-HMSbEstimateMinutes $h 'PROFIL-A' | Should -Be 120
        $h2 = @($h[0], [pscustomobject]@{ Profile = 'PROFIL-A'; Date = '2026-11-03 22:00'; Minutes = 300; Status = 'Error' })
        Get-HMSbEstimateMinutes $h2 'PROFIL-A' | Should -Be 300
    }
    It 'Version gehoert nur zum Lauf, wenn sie nach dem Start entstand' {
        $t0 = Get-Date '2026-11-25 22:00'
        Test-HMSbVersionFromRun ([pscustomobject]@{ When = (Get-Date '2026-11-25 22:01') }) $t0 | Should -BeTrue
        Test-HMSbVersionFromRun ([pscustomobject]@{ When = (Get-Date '2026-11-24 22:01') }) $t0 | Should -BeFalse
        Test-HMSbVersionFromRun ([pscustomobject]@{ When = [datetime]::MinValue }) $t0 | Should -BeFalse
        Test-HMSbVersionFromRun $null $t0 | Should -BeFalse
    }
    It 'Sperrzeit-Pruefung warnt einmal, auch wenn wbadmin laufend Fortschritt meldet' {
        $script:SbJob = @{ Log = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue)) }
        $now = Get-Date
        $script:SbBlockWindows = @((ConvertFrom-HMSbBlockText ("taeglich {0} - {1}" -f $now.AddMinutes(-5).ToString('HH:mm'), $now.AddMinutes(30).ToString('HH:mm'))).Windows)
        $script:SbBlockWarned = $false
        Invoke-HMSbBlockCheck
        Invoke-HMSbBlockCheck
        $script:SbBlockWarned | Should -BeTrue
        @($script:SbJob.Log.ToArray() | Where-Object { $_.Msg -match 'Sperrzeit' }).Count | Should -Be 1
        $eng = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:Root 'Functions\ServerBackup-Engine.ps1')
        [regex]::Match($eng, '(?s)function Invoke-HMSbWbadmin \{.*?\r?\n\}\r?\n').Value | Should -Match '\$lastBlockChk = Get-Date; Invoke-HMSbBlockCheck'
        $script:SbJob = $null; $script:SbBlockWindows = $null
    }
    It 'Fehler vor dem Berichtsordner: Verlaufseintrag "Nicht gestartet" im Tool-Ordner' {
        $p = Join-Path $TestDrive 'early\history.json'
        Add-HMSbEarlyError @{ LocalHistory = $p; Profile = 'PROFIL-A'; DiskLabel = 'HUMIG-PROFIL-A-1'; VMs = @('DC1'); Volumes = @(); Version = '9' } 'Ziel-Laufwerk E: nicht vorhanden'
        $h = Read-HMSbHistory $p
        $h.Count | Should -Be 1
        $h[0].Status | Should -Be 'Error'
        $h[0].Note | Should -Match 'Nicht gestartet: Ziel-Laufwerk'
        $ui = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:Root 'Functions\UI-ServerBackup.ps1')
        $ui | Should -Match 'if \(-not \$Job\.SbStarted\) \{ Add-HMSbEarlyError \$Ctx \$e \}'
        $eng = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:Root 'Functions\ServerBackup-Engine.ps1')
        $eng | Should -Match '\$Job\.SbStarted = \$true\r?\n.*\r?\n\s*Set-HMSbRunMarker \$Ctx \$rep \$t0'
    }
    It 'Zeitplan-Skript: Platten lesen und unerwartete Fehler enden mit Verlauf und Meldung (SB-04)' {
        $tsk = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:Root 'Functions\ServerBackup-Task.ps1')
        $tsk | Should -Match 'try \{ \$dl = Get-HMSbDriveList \} catch \{ Add-HMSbTaskError'
        $tsk | Should -Match '(?s)trap \{.*Add-HMSbTaskError \$tm.*exit 2'
    }
}

Describe 'Server-Backup: Zeitplaene nach Umbenennen und beim Loeschen des Profils (US-07)' {
    BeforeAll {
        $script:AppRoot = $script:Root
        . (Join-Path $script:Root 'Functions\UI-ServerBackup.ps1')
    }
    It 'Aufgabe unter dem alten Profilnamen gehoert weiter zum Profil' {
        $ren = @([pscustomobject]@{ Old = 'Profil alt'; New = 'PROFIL-A' })
        Test-HMSbTaskOfProfile 'Server-Backup - Profil alt - taeglich 22-00' 'PROFIL-A' $ren | Should -BeTrue
        Test-HMSbTaskOfProfile 'Server-Backup - PROFIL-A - taeglich 22-00' 'PROFIL-A' $ren | Should -BeTrue
        Test-HMSbTaskOfProfile 'Server-Backup - PROFIL-B - taeglich 22-00' 'PROFIL-A' $ren | Should -BeFalse
        Test-HMSbTaskOfProfile 'Server-Backup - Profil alt - taeglich 22-00' 'PROFIL-A' @() | Should -BeFalse
    }
    It 'Loeschen des Profils nennt die bleibenden Zeitplaene' {
        $ui = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:Root 'Functions\UI-ServerBackup.ps1')
        [regex]::Match($ui, '(?s)function Remove-HMSbProfile \{.*?\r?\n\}\r?\n').Value | Should -Match 'Test-HMSbTaskOfProfile'
    }
}
Describe 'Server-Backup: Nachpruefung (Meldungen, Platten-Liste ohne offline Platte)' {
    BeforeAll {
        $script:AppRoot = $script:Root
        if (-not $script:ConfigDir) { $script:ConfigDir = Join-Path $TestDrive 'CfgUi3'; $script:LogDir = Join-Path $TestDrive 'LogsUi3' }
        New-Item -ItemType Directory -Path $script:ConfigDir -Force | Out-Null
        . (Join-Path $script:Root 'Functions\UI-ServerBackup.ps1')
        function Out-Console([string]$Text, [string]$Level = 'Info') { }
        function Write-JsonFile([string]$Path, $Data, [int]$Depth = 6) { $Data | ConvertTo-Json -Depth $Depth | Set-Content -LiteralPath $Path -Encoding UTF8 }
        function Get-VM { }
        function Get-VMHardDiskDrive { param($VM) }
        function Get-Disk { }
        function Set-Disk { param($Number, $IsOffline) }
        function Get-Volume { }
    }
    It 'Abbruch nach fertigem eigenen Lauf: eigene Meldung, kein stop job' {
        $script:SbJob = @{ Log = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue)) }
        Stop-HMSbOwnJob ([pscustomobject]@{ ExitCode = 0; Started = $true; Busy = $false }) | Should -BeFalse
        @($script:SbJob.Log.ToArray())[-1].Msg | Should -Match 'schon beendet'
        $script:SbJob = $null
    }
    It 'gesperrte Profil-Datei: Speichern meldet keinen Erfolg (SbLastSaveOk)' {
        [System.IO.File]::WriteAllText($script:SbCfgFile, '{"LastProfile":"","Profiles":[],"Renames":[]}')
        $c = Get-HMSbConfig
        $lock = New-Object System.IO.FileStream($script:SbCfgFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        try { Save-HMSbConfig $c } finally { $lock.Dispose() }
        $script:SbLastSaveOk | Should -BeFalse
        Save-HMSbConfig $c
        $script:SbLastSaveOk | Should -BeTrue
        $ui = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:Root 'Functions\UI-ServerBackup.ps1')
        ([regex]::Matches($ui, 'Save-HMSbConfig \$cfg\r?\n\s*if \(-not \$script:SbLastSaveOk\) \{ return \}')).Count | Should -Be 4
    }
    It 'ohne offline USB-Platte wird die VM-Liste beim Lesen der Platten nicht abgefragt' {
        Mock Get-HMSbOfflineMarks { @() }
        Mock Set-HMSbOfflineMarks { }
        Mock Get-Volume { @() }
        Mock Get-Disk { @([pscustomobject]@{ Number = 5; BusType = 'USB'; IsOffline = $false; FriendlyName = 'Sicherung'; UniqueId = 'U5' }) }
        Mock Get-HMSbPassThroughDisks { throw 'darf nicht laufen' }
        Mock Set-Disk { }
        $r = Get-HMSbDriveList
        Should -Invoke Get-HMSbPassThroughDisks -Times 0 -Exactly
        @($r.Messages).Count | Should -Be 0
    }
}
Describe 'Server-Backup: Befunde der unabhaengigen Pruefung' {
    BeforeAll {
        $script:AppRoot = $script:Root
        if (-not $script:ConfigDir) { $script:ConfigDir = Join-Path $TestDrive 'CfgUi4'; $script:LogDir = Join-Path $TestDrive 'LogsUi4' }
        New-Item -ItemType Directory -Path $script:ConfigDir -Force | Out-Null
        . (Join-Path $script:Root 'Functions\UI-ServerBackup.ps1')
        function Out-Console([string]$Text, [string]$Level = 'Info') { $script:Console += , @($Level, $Text) }
        function Write-JsonFile([string]$Path, $Data, [int]$Depth = 6) { $Data | ConvertTo-Json -Depth $Depth | Set-Content -LiteralPath $Path -Encoding UTF8 }
    }
    BeforeEach { $script:Console = @(); $script:SbCorruptSeen = @{} }
    It 'Profile beim Lesen gesperrt: spaeteres Speichern ersetzt die Profile nie' {
        $good = '{"LastProfile":"PROFIL-A","Profiles":[{"Name":"PROFIL-A"}],"Renames":[]}'
        [System.IO.File]::WriteAllText($script:SbCfgFile, $good)
        $lock = New-Object System.IO.FileStream($script:SbCfgFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        try { $c = Get-HMSbConfig } finally { $lock.Dispose() }
        $c.ReadState | Should -Be 'Unreadable'
        @($c.Profiles).Count | Should -Be 0
        Save-HMSbConfig $c
        $script:SbLastSaveOk | Should -BeFalse
        [System.IO.File]::ReadAllText($script:SbCfgFile) | Should -Be $good
    }
    It 'Schreiben gescheitert (Write-JsonFile schluckt Fehler): kein Erfolg gemeldet' {
        [System.IO.File]::WriteAllText($script:SbCfgFile, '{"LastProfile":"","Profiles":[],"Renames":[]}')
        $c = Get-HMSbConfig
        function Write-JsonFile([string]$Path, $Data, [int]$Depth = 6) { }
        Save-HMSbConfig $c
        $script:SbLastSaveOk | Should -BeFalse
        @($script:Console | Where-Object { $_[1] -match 'NICHT gespeichert' }).Count | Should -Be 1
    }
    It 'gueltiges JSON mit NUL am Ende gilt unter 5.1 und 7 als lesbar' {
        $p = Join-Path $TestDrive 'nul.json'
        [System.IO.File]::WriteAllText($p, '[{"A":1}]' + [char]0 + [char]0)
        (Read-HMSbJsonState $p).State | Should -Be 'Ok'
    }
    It 'Abbrechen zwischen Warten und Start: eigene Sicherung startet nicht, kein stop job' {
        $job = @{ Cancel = $false }
        Mock Wait-HMSbIdle { $job.Cancel = $true; $true }
        Mock Invoke-HMSbWbadmin { throw 'darf nicht laufen' }
        $r = Invoke-HMSbStart -Arguments 'start backup -backupTarget:X: -quiet' -Job $job
        $r.Started | Should -BeFalse
        Test-HMSbOwnJobRunning $r | Should -BeFalse
        Should -Invoke Invoke-HMSbWbadmin -Times 0
    }
}

Describe 'Server-Backup: Nachbesserung der Abnahme (eigene Platte, Zeitgrenze, Wortlaut, Ziel bei Abweichung)' {
    BeforeAll {
        function Get-Disk { }
        function Set-Disk { param($Number, $IsOffline) }
        function Get-Volume { }
    }
    BeforeEach {
        Mock Set-HMSbOfflineMarks { }
        Mock Get-Volume { @() }
        Mock Set-Disk { }
    }
    It 'von HUMig offline geschaltete Platte wird ohne Pass-Through-Pruefung online geschaltet (auch bei gleicher Nummer)' {
        Mock Get-HMSbOfflineMarks { @('U5|HUMIG-PROFIL-A-1') }
        Mock Get-Disk { @([pscustomobject]@{ Number = 4; BusType = 'USB'; IsOffline = $true; FriendlyName = 'Sicherung'; UniqueId = 'U5' }) }
        Mock Get-HMSbPassThroughDisks { , @(4) }
        $r = Get-HMSbDriveList
        Should -Invoke Get-HMSbPassThroughDisks -Times 0 -Exactly
        Should -Invoke Set-Disk -Times 1 -Exactly -ParameterFilter { $Number -eq 4 }
        @($r.Messages) -join ' ' | Should -Not -Match 'Pass-Through'
    }
    It 'nur offline Platten OHNE Markierung loesen die VM-Abfrage aus, und nur einmal' {
        Mock Get-HMSbOfflineMarks { @('U5|HUMIG-PROFIL-A-1') }
        Mock Get-Disk { @([pscustomobject]@{ Number = 5; BusType = 'USB'; IsOffline = $true; FriendlyName = 'A'; UniqueId = 'U5' }, [pscustomobject]@{ Number = 6; BusType = 'USB'; IsOffline = $true; FriendlyName = 'B'; UniqueId = 'U6' }, [pscustomobject]@{ Number = 7; BusType = 'USB'; IsOffline = $true; FriendlyName = 'C'; UniqueId = 'U7' }) }
        Mock Get-HMSbPassThroughDisks { , @() }
        [void](Get-HMSbDriveList)
        Should -Invoke Get-HMSbPassThroughDisks -Times 1 -Exactly
        Should -Invoke Set-Disk -Times 3 -Exactly
    }
    It 'Zeitgrenze: haengende Abfrage kehrt nach der Grenze zurueck, schnelle liefert ihr Ergebnis' {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-HMSbWithTimeout { Start-Sleep -Seconds 20; 'OK:1' } 1
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 8
        $r.Done | Should -BeFalse
        $r2 = Invoke-HMSbWithTimeout { 'OK:3,4' } 10
        $r2.Done | Should -BeTrue
        $r2.Output | Should -Be 'OK:3,4'
    }
    It 'Ergebnistext der Pass-Through-Abfrage' {
        $l = ConvertFrom-HMSbPassThroughText 'OK:3,4'
        ($l -join ',') | Should -Be '3,4'
        $l0 = ConvertFrom-HMSbPassThroughText 'OK:'
        $l0.Count | Should -Be 0
        $null -eq (ConvertFrom-HMSbPassThroughText 'ERR') | Should -BeTrue
        $null -eq (ConvertFrom-HMSbPassThroughText '') | Should -BeTrue
    }
    It 'Pass-Through-Meldungen kommen in den Fehlertext, andere Meldungen nicht' {
        Get-HMSbPassThroughNote @('USB-Platte 4 (X) ist direkt an eine VM durchgereicht (Pass-Through) - bleibt offline', 'USB-Platte 5 online geschaltet') | Should -Match '^ - USB-Platte 4 .*Pass-Through'
        Get-HMSbPassThroughNote @('USB-Platte 5 online geschaltet') | Should -Be ''
    }
    It 'Wortlaut beim Abbrechen je Fall' {
        Get-HMSbCancelText ([pscustomobject]@{ Started = $false; Busy = $false; ExitCode = -3 }) | Should -Match 'vor dem Start abgebrochen'
        Get-HMSbCancelText ([pscustomobject]@{ Started = $false; Busy = $true; ExitCode = -3 }) | Should -Match 'wartete auf einen anderen Vorgang'
        Get-HMSbCancelText ([pscustomobject]@{ Started = $true; Busy = $true; ExitCode = 1 }) | Should -Match 'wartete auf einen anderen Vorgang'
        Get-HMSbCancelText ([pscustomobject]@{ Started = $true; Busy = $false; ExitCode = 0 }) | Should -Match 'schon beendet'
        Get-HMSbCancelText $null | Should -Match 'vor dem Start'
    }
    It 'Abweichung der Ziel-Platte: Nein startet nicht, Ja nimmt Bezeichnung und Seriennummer der jetzt steckenden Platte' {
        $d = [pscustomobject]@{ Letter = 'E'; Label = 'HUMIG-PROFIL-A-1'; Serial = 'S1'; Free = 1 }
        $ok = Resolve-HMSbStartDrive $d '' '' $null
        $ok.Start | Should -BeTrue; $ok.Drive.Label | Should -Be 'HUMIG-PROFIL-A-1'; $ok.Note | Should -Be ''
        (Resolve-HMSbStartDrive $d 'andere Platte' 'No' $null).Start | Should -BeFalse
        $y = Resolve-HMSbStartDrive $d 'andere Platte' 'Yes' ([pscustomobject]@{ Label = 'HUMIG-PROFIL-B-2'; Serial = 'S9' })
        $y.Start | Should -BeTrue
        $y.Drive.Label | Should -Be 'HUMIG-PROFIL-B-2'
        $y.Drive.Serial | Should -Be 'S9'
        $y.Drive.Letter | Should -Be 'E'
        $y.Note | Should -Be 'andere Platte'
        $d.Label | Should -Be 'HUMIG-PROFIL-A-1'
    }
    It 'Verlauf entfernen und umbenennen auf beschaedigter Datei: danach gueltiger, leerer Verlauf' {
        $dir = Join-Path $TestDrive 'rmrn'; New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $p = Join-Path $dir 'history.json'
        [System.IO.File]::WriteAllText($p, '[{')
        Remove-HMSbHistory $p @('a|b|c') | Should -Be 0
        (Read-HMSbJsonState $p).State | Should -Be 'Ok'
        [System.IO.File]::WriteAllText($p, '[{')
        Rename-HMSbProfileInFile $p 'A' 'B' | Should -Be 0
        (Read-HMSbJsonState $p).State | Should -Be 'Ok'
        @(Get-ChildItem -LiteralPath $dir -Filter 'history.defekt-*.json').Count | Should -Be 2
    }
}

Describe 'Server-Backup: Verhalten der Oberflaeche ohne Fenster (Laden, Speichern, Auswerfen, Einrichten, VM-Export)' {
    BeforeAll {
        $script:AppRoot = $script:Root
        if (-not $script:ConfigDir) { $script:ConfigDir = Join-Path $TestDrive 'CfgUi5'; $script:LogDir = Join-Path $TestDrive 'LogsUi5' }
        . (Join-Path $script:Root 'Functions\UI-ServerBackup.ps1')
        function Out-Console([string]$Text, [string]$Level = 'Info') { $script:Console += , @($Level, $Text) }
        function Show-HMDialogBox { param($Owner, $Text, $Title, $Mode, $Icon, $Default) 'No' }
        function Show-TextInputDialog { param($Title, $Label, $Text, $Owner) $null }
        function Invoke-AsyncCommand { param($ScriptBlock, $ArgumentList, $TimeoutSec, $State, $BusyTag, $BusyText, $OnComplete) }
        function Write-VolumeCache { param($DriveLetter) }
        function Get-ScheduledTask { param($TaskPath, $TaskName) @() }
        $ui = @{ chkSbHostConfig = [pscustomobject]@{ IsChecked = $true }; chkSbVerify = [pscustomobject]@{ IsChecked = $true }; chkSbHostSystem = [pscustomobject]@{ IsChecked = $false } }
        $script:JobRunning = $false
    }
    BeforeEach {
        $script:Console = @()
        Mock Get-HMSbProfile { [pscustomobject]@{ Name = 'PROFIL-A'; DiskPrefix = 'HUMIG-PROFIL-A'; VMs = @('VM1', 'VM2'); Volumes = @('D:') } }
        Mock Show-HMDialogBox { 'No' }
        Mock Show-TextInputDialog { $null }
        Mock Invoke-AsyncCommand { }
        Mock Get-HMSbAliveRuns { @() }
        Mock Get-HMSbBusy { @() }
    }
    It 'waehrend des Lesens: Speichern, Neu, Planen und Starten tun nichts und sind danach von selbst wieder frei' {
        $script:SbVmsState = 'Loading'; $script:SbVolsState = 'Ok'
        Mock Save-HMSbConfig { }
        Mock Show-HMSbScheduleDialog { $null }
        Mock Get-HMSbDrive { $null }
        Save-HMSbProfile; New-HMSbProfile; New-HMSbSchedule; Start-HMSbBackup
        Should -Invoke Save-HMSbConfig -Times 0 -Exactly
        Should -Invoke Show-TextInputDialog -Times 0 -Exactly
        Should -Invoke Show-HMSbScheduleDialog -Times 0 -Exactly
        Should -Invoke Get-HMSbDrive -Times 0 -Exactly
        @($script:Console | Where-Object { $_[1] -match 'noch gelesen' }).Count | Should -Be 4
        $script:SbVmsState = 'Ok'
        Mock Get-HMSbCheckedVms { @('VM1') }
        Mock Get-HMSbCheckedVols { @('D:') }
        New-HMSbSchedule
        Should -Invoke Show-HMSbScheduleDialog -Times 1 -Exactly
    }
    It 'nicht lesbare VM-Liste: Speichern behaelt die gespeicherten VMs, ohne Rueckfrage, und speichert den Rest' {
        $script:SbVmsState = 'Error'; $script:SbVolsState = 'Ok'
        Mock Get-HMSbConfig { [pscustomobject]@{ LastProfile = 'PROFIL-A'; Profiles = @([pscustomobject]@{ Name = 'PROFIL-A'; VMs = @('VM1', 'VM2'); Volumes = @('D:'); HostConfig = $false; Verify = $false; HostSystem = $false }); Renames = @(); ReadState = 'Ok' } }
        Mock Get-HMSbCheckedVms { @() }
        Mock Get-HMSbCheckedVols { @('E:') }
        Mock Update-HMSbHistory { }
        Mock Save-HMSbConfig { param($Cfg) $script:Saved = $Cfg; $script:SbLastSaveOk = $true }
        Save-HMSbProfile
        Should -Invoke Show-HMDialogBox -Times 0 -Exactly
        @($script:Saved.Profiles[0].VMs) | Should -Be @('VM1', 'VM2')
        @($script:Saved.Profiles[0].Volumes) | Should -Be @('E:')
        $script:Saved.Profiles[0].HostConfig | Should -BeTrue
        $script:SbVmsState = 'Ok'
    }
    It 'Auswerfen ohne laufende Sicherung: keine Rueckfrage, wirft wie bisher aus' {
        Mock Get-HMSbDrive { [pscustomobject]@{ Letter = 'E'; Label = 'HUMIG-PROFIL-A-1' } }
        Invoke-HMSbEject
        Should -Invoke Show-HMDialogBox -Times 0 -Exactly
        Should -Invoke Invoke-AsyncCommand -Times 1 -Exactly
    }
    It 'Auswerfen bei laufender Sicherung auf dieser Platte: Rueckfrage, bei Nein passiert nichts' {
        Mock Get-HMSbDrive { [pscustomobject]@{ Letter = 'E'; Label = 'HUMIG-PROFIL-A-1' } }
        Mock Get-HMSbAliveRuns { @([pscustomobject]@{ Profile = 'PROFIL-A'; Disk = 'HUMIG-PROFIL-A-1'; Started = (Get-Date).ToString('o'); Kind = 'Zeitplan' }) }
        Invoke-HMSbEject
        Should -Invoke Show-HMDialogBox -Times 1 -Exactly
        Should -Invoke Invoke-AsyncCommand -Times 0 -Exactly
    }
    It 'Einrichten mit veralteter Zeile: Meldung, Abbruch vor jeder Eingabe' {
        $script:SbDiskRows = @([pscustomobject]@{ Number = 3; Id = 'X'; Model = 'Neu'; Serial = 'S2'; Volumes = 'E: HUMIG-PROFIL-A-1' })
        Invoke-HMSbDiskSetup @([pscustomobject]@{ Nr = 3; Modell = 'Alt'; Seriennummer = 'S1' }) $null
        Should -Invoke Show-TextInputDialog -Times 0 -Exactly
        Should -Invoke Show-HMDialogBox -Times 1 -Exactly -ParameterFilter { $Text -match 'nicht mehr aktuell' }
    }
    It 'Einrichten ohne laufende Sicherung: keine neue Rueckfrage, weiter wie bisher zur Bezeichnung' {
        $script:SbDiskRows = @([pscustomobject]@{ Number = 3; Id = 'X'; Model = 'Neu'; Serial = ''; Volumes = 'E: HUMIG-PROFIL-A-1' })
        Invoke-HMSbDiskSetup @([pscustomobject]@{ Nr = 3; Modell = 'Neu'; Seriennummer = $null }) $null
        Should -Invoke Show-HMDialogBox -Times 0 -Exactly
        Should -Invoke Show-TextInputDialog -Times 1 -Exactly
    }
    It 'Einrichten bei laufender Sicherung auf der Platte: Rueckfrage, bei Nein Abbruch' {
        $script:SbDiskRows = @([pscustomobject]@{ Number = 3; Id = 'X'; Model = 'Neu'; Serial = 'S2'; Volumes = 'E: HUMIG-PROFIL-A-1' })
        Mock Get-HMSbAliveRuns { @([pscustomobject]@{ Profile = 'PROFIL-A'; Disk = 'HUMIG-PROFIL-A-1'; Started = (Get-Date).ToString('o'); Kind = 'Zeitplan' }) }
        Invoke-HMSbDiskSetup @([pscustomobject]@{ Nr = 3; Modell = 'Neu'; Seriennummer = 'S2' }) $null
        Should -Invoke Show-HMDialogBox -Times 1 -Exactly
        Should -Invoke Show-TextInputDialog -Times 0 -Exactly
    }
    It 'VM-Export-Einstellungen: keine Erfolgsmeldung, wenn nicht gespeichert wurde' {
        $script:SbVms = @([pscustomobject]@{ Name = 'VM1' })
        Mock Get-HMSbDrive { $null }
        Mock Show-HMSbExportDialog { [pscustomobject]@{ Action = 'Save'; VMs = @('VM1'); Folder = ''; Keep = 1; After = $true } }
        Mock Update-HMSbSchedules { }
        Mock Save-HMSbExportSettings { $script:SbLastSaveOk = $false }
        Start-HMSbExportUi
        @($script:Console | Where-Object { $_[1] -match 'VM-Export' }).Count | Should -Be 0
        Mock Save-HMSbExportSettings { $script:SbLastSaveOk = $true }
        Start-HMSbExportUi
        @($script:Console | Where-Object { $_[1] -match 'VM-Export' }).Count | Should -Be 1
    }
}

Describe 'Server-Backup: Zeitplan-Skript wirklich ausgefuehrt (Testordner, Ersatzfunktionen)' {
    BeforeAll {
        $script:Fx = Join-Path $TestDrive 'taskfx'
        $fn = Join-Path $script:Fx 'Functions'
        New-Item -ItemType Directory -Path $fn, (Join-Path $script:Fx 'Config') -Force | Out-Null
        foreach ($n in 'ServerBackup-Task.ps1', 'ServerBackup-Engine.ps1', 'Core-Notify.ps1', 'UI-Status.ps1') { Copy-Item -LiteralPath (Join-Path $script:Root "Functions\$n") -Destination $fn }
        # Ersatz am Ende der Kopien: nichts am System (Ereignisprotokoll, Aufgabenplanung, Platten, Teams)
        $ov = @'
function Write-HMSbEvent([string]$Status, [string]$Message) { }
function Resolve-HMSbAbortedRuns { @() }
function Remove-HMSbStaleOnceTasks { @() }
function Get-HMSbAliveRuns { @() }
function Get-HMSbDriveList {
    switch ($env:HMSB_TESTFALL) {
        'platten' { throw 'Platten-Testfehler' }
        'pt' { return [pscustomobject]@{ Drives = @(); Messages = @('USB-Platte 4 (X) ist direkt an eine VM durchgereicht (Pass-Through) - bleibt offline und ist kein Sicherungsziel') } }
        default { return [pscustomobject]@{ Drives = @([pscustomobject]@{ Letter = 'Q'; Label = 'HUMIG-PROFIL-A-1'; Serial = ''; FileSystem = 'NTFS' }); Messages = @() } }
    }
}
function Get-HMSbPendingReboot { if ($env:HMSB_TESTFALL -eq 'trap') { throw 'Unerwarteter Testfehler' }; @() }
'@
        Add-Content -LiteralPath (Join-Path $fn 'ServerBackup-Engine.ps1') -Value $ov -Encoding UTF8
        Add-Content -LiteralPath (Join-Path $fn 'Core-Notify.ps1') -Value 'function Send-HMNotify { param($Title, $Lines, $Level, $Category, $SbProfile) $script:LastNotify = $Title; "" }' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $script:Fx 'Config\serverbackup.json') -Value '{"LastProfile":"PROFIL-A","Profiles":[{"Name":"PROFIL-A","DiskPrefix":"HUMIG-PROFIL-A","VMs":[],"Volumes":["D:"]}],"Renames":[]}' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $script:Fx 'Config\version.json') -Value '{"version":"9.9.9"}' -Encoding UTF8
        function Invoke-HMSbTaskFixture([string]$Fall) {
            $env:HMSB_TESTFALL = $Fall
            try { $null = & 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:Fx 'Functions\ServerBackup-Task.ps1') -ProfileName 'PROFIL-A' 2>&1; return $LASTEXITCODE }
            finally { Remove-Item Env:\HMSB_TESTFALL -ErrorAction SilentlyContinue }
        }
        $script:Hist = Join-Path $script:Fx 'Config\ServerBackup\history.json'
    }
    It 'unerwarteter Fehler ausserhalb der Pruefungen: trap schreibt Verlauf, Exitcode 2' {
        Invoke-HMSbTaskFixture 'trap' | Should -Be 2
        $h = Read-HMSbHistory $script:Hist
        @($h | Where-Object { $_.Note -match 'Unerwarteter Fehler: Unerwarteter Testfehler' -and $_.Status -eq 'Error' }).Count | Should -Be 1
    }
    It 'Platten nicht lesbar: Verlauf mit Grund, Exitcode 2 (SB-04)' {
        Invoke-HMSbTaskFixture 'platten' | Should -Be 2
        $h = Read-HMSbHistory $script:Hist
        @($h | Where-Object { $_.Note -match 'Platten nicht lesbar: Platten-Testfehler' }).Count | Should -Be 1
    }
    It 'keine Platte, weil durchgereicht: Grund steht im Fehlertext des Verlaufs' {
        Invoke-HMSbTaskFixture 'pt' | Should -Be 2
        $h = Read-HMSbHistory $script:Hist
        @($h | Where-Object { $_.Note -match 'Keine Platte des Profils angesteckt .*Pass-Through' }).Count | Should -Be 1
    }
}
