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
