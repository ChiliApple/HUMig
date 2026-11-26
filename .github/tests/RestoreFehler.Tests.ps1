#Requires -Version 5.1
# Pester-Tests (Pester 5): Module, die im Backup mit Fehlern gesichert sind, bleiben im Restore waehlbar, wenn Daten im Backup liegen.
# Nachgestellte Backups (manifest.json und Modulordner) in TestDrive. Ohne feste Laufwerke, ohne Adminrechte, ohne Netz.

BeforeDiscovery {
    # WPF-Steuerelemente nur in einem STA-Thread (Windows PowerShell 5.1 ist es immer)
    $script:StaD = ([System.Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA')
}

BeforeAll {
    $script:Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    . (Join-Path $script:Root 'Functions\Migration-Engine.ps1')
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Root 'Functions\UI-Quality.ps1'), [ref]$null, [ref]$null)
    . ([scriptblock]::Create(@($ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'Get-HMRestoreIncompleteText' }, $true))[0].Extent.Text))

    function New-TDir([string]$Name) { $d = Join-Path $TestDrive ($Name + '_' + [guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory -Path $d -Force | Out-Null; $d }
    function New-TJob { @{ Log = (New-Object System.Collections.Queue); Cancel = $false; Progress = 0; Status = ''; LogFile = $null } }
    function Get-TLog($j) { (@($j.Log.ToArray() | ForEach-Object { "$($_.Msg)" }) -join "`n") }
    function New-TItem([string]$Name, [string]$Status, [long]$Bytes = 0, [string]$Msg = '') { [pscustomobject]@{ Name = $Name; Status = $Status; Msg = $Msg; Bytes = $Bytes; Source = '' } }
    function New-TModRes([string]$Id, [string]$Status, [object[]]$Items, [long]$Bytes = -1) {
        if ($Bytes -lt 0) { $Bytes = [long](@($Items | ForEach-Object { [long]$_.Bytes }) | Measure-Object -Sum).Sum }
        [pscustomobject]@{ Id = $Id; Name = "Modul $Id"; Status = $Status; Bytes = $Bytes; Items = @($Items) }
    }
    # Backup nachstellen wie Start-HMBackup: manifest.json und je Modul mit Daten ein Ordner <Backup>\<Id>\<Eintrag> mit einer Datei
    function New-TBackup([string]$Status, [object[]]$Modules, [string[]]$DataFor = @()) {
        $p = New-TDir 'Backup'
        $m = [ordered]@{ Created = '2026-11-20 10:00:00'; SourceComputer = 'QPC'; UserName = 'quelle'; Account = 'DOM\quelle'; UserSid = 'S-1-5-21-1-2-3-1001'
                         ProfilePath = 'Q:\Users\quelle'; Status = $Status; SizeBytes = 1234; Modules = @($Modules) }
        [System.IO.File]::WriteAllText((Join-Path $p 'manifest.json'), ($m | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($true)))
        foreach ($id in @($DataFor | Where-Object { $_ })) {
            $d = Join-Path (Join-Path $p $id) 'A'; New-Item -ItemType Directory -Path $d -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $d 'a.txt'), 'x')
        }
        return $p
    }
    $script:Fail2 = 'Q:\Users\quelle\Desktop: 120 Dateien, 3 MB, 2 FEHLGESCHLAGEN (gesperrt/keine Rechte - siehe Robocopy-Log): Q:\Users\quelle\Desktop\a.db; Q:\Users\quelle\Desktop\b.db'
}

Describe 'Restore mit Fehler-Modulen: Erkennung im Backup' {
    It 'Ausgangszustand: Fehler-Modul mit Daten ist im Restore waehlbar (auf main ausgeblendet)' {
        $p = New-TBackup 'Error' @(
            (New-TModRes 'Profile' 'OK' @(New-TItem 'Dokumente' 'OK' 500)),
            (New-TModRes 'Daten' 'Error' @((New-TItem 'A' 'OK' 300), (New-TItem 'B' 'Error' 200 $script:Fail2)))) @('Profile', 'Daten')
        $i = Read-HMBackupInfo -Path $p -Modules @()
        @($i.Modules) | Should -Contain 'Daten'
        @($i.Modules) | Should -Contain 'Profile'
        @($i.ErrorModules) | Should -Be @('Daten')
    }
    It 'Backup ganz ohne Fehler: Module wie bisher (OK und Warnung), keine Fehler-Module' {
        $p = New-TBackup 'Warning' @(
            (New-TModRes 'Profile' 'OK' @(New-TItem 'Dokumente' 'OK' 500)),
            (New-TModRes 'Chrome' 'Warning' @(New-TItem 'Profil' 'Warning' 50 'Hinweis: gesperrt')),
            (New-TModRes 'Edge' 'Skip' @(New-TItem 'Profil' 'Skip' 0 'nicht vorhanden'))) @('Profile', 'Chrome')
        $i = Read-HMBackupInfo -Path $p -Modules @()
        @($i.Modules) | Should -Be @('Profile', 'Chrome')
        @($i.ErrorModules).Count | Should -Be 0
    }
    It 'Fehler-Modul ohne Daten bleibt ausgeblendet: nicht lesbar (Warnung, 0 Bytes) und Quelle nicht erreichbar' {
        $p = New-TBackup 'Error' @(
            (New-TModRes 'Gesperrt' 'Error' @((New-TItem 'A' 'Warning' 0 'nicht lesbar: Q:\x (Zugriff verweigert) - nicht gesichert'), (New-TItem 'Hinweis' 'OK' 0 'Programm geschlossen'))),
            (New-TModRes 'Weg' 'Error' @(New-TItem 'A' 'Error' 0 'Quelle nicht erreichbar: Q:\x (siehe Eintrag Quelle) - nicht gesichert'))) @('Weg')
        # Weg: im Ordner liegt noch ein aelterer Stand (fortlaufendes Backup) - zaehlt nicht, dieser Lauf hat nichts gesichert
        $i = Read-HMBackupInfo -Path $p -Modules @()
        @($i.Modules).Count | Should -Be 0
        @($i.ErrorModules).Count | Should -Be 0
    }
    It 'Fehler-Modul mit einem Eintrag OK und 0 Bytes zaehlt als gesichert, ein Hinweis nicht' {
        (Test-HMBackupModuleHasData (New-TModRes 'R' 'Error' @((New-TItem 'Reg' 'OK' 0 'Registry exportiert'), (New-TItem 'B' 'Error' 0 'kaputt')))) | Should -BeTrue
        (Test-HMBackupModuleHasData (New-TModRes 'H' 'Error' @((New-TItem 'Hinweis' 'OK' 0 'Info'), (New-TItem 'B' 'Error' 0 'kaputt')))) | Should -BeFalse
        (Test-HMBackupModuleHasData $null) | Should -BeFalse
        (Test-HMBackupModuleHasData ([pscustomobject]@{ Id = 'X'; Status = 'Error'; Bytes = 'kaputt'; Items = $null })) | Should -BeFalse
    }
    It 'USMT mit Fehler bleibt ausgeblendet (kein oder unbrauchbares USMT.MIG), mit Warnung waehlbar' {
        $bad = [pscustomobject]@{ Id = 'Usmt'; Name = 'Windows-Einstellungen (USMT)'; Status = 'Error'; Bytes = 5000; MigState = 'Unusable'; Items = @(New-TItem 'Usmt' 'Error' 5000 'USMT.MIG in der Ablage ist nicht verwendbar') }
        $old = [pscustomobject]@{ Id = 'Usmt'; Name = 'Windows-Einstellungen (USMT)'; Status = 'Warning'; Bytes = 5000; Items = @(New-TItem 'Usmt' 'Warning' 5000 'USMT-Stand stammt vom ...') }
        @((Read-HMBackupInfo -Path (New-TBackup 'Error' @($bad) @('Usmt')) -Modules @()).Modules).Count | Should -Be 0
        @((Read-HMBackupInfo -Path (New-TBackup 'Warning' @($old) @('Usmt')) -Modules @()).Modules) | Should -Be @('Usmt')
    }
    It 'Abgebrochenes Backup: gesicherte Module und das abgebrochene Modul mit Daten sind waehlbar' {
        $p = New-TBackup 'Cancelled' @(
            (New-TModRes 'Profile' 'OK' @(New-TItem 'Dokumente' 'OK' 500)),
            (New-TModRes 'Daten' 'Error' @(New-TItem 'A' 'Cancel' 100 'abgebrochen'))) @('Profile', 'Daten')
        $i = Read-HMBackupInfo -Path $p -Modules @()
        @($i.Modules) | Should -Be @('Profile', 'Daten')
        @($i.ErrorModules) | Should -Be @('Daten')
    }
    It 'Altes Backup: Module ohne Statusangabe bleiben wie bisher aus, alte Ordnerstruktur unveraendert' {
        $p = New-TBackup '' @([pscustomobject]@{ Id = 'Profile'; Name = 'Profil'; Bytes = 10; Items = @() }) @('Profile')
        $i = Read-HMBackupInfo -Path $p -Modules @()
        @($i.Modules).Count | Should -Be 0
        @($i.ErrorModules).Count | Should -Be 0
        $l = New-TDir 'alt'; New-Item -ItemType Directory -Path (Join-Path $l 'USER') -Force | Out-Null
        $li = Read-HMBackupInfo -Path $l -Modules @()
        $li.Legacy | Should -BeTrue
        @($li.ErrorModules).Count | Should -Be 0
    }
    It 'Backup-Liste mit mehreren Backups: jedes Backup hat seine eigenen Fehler-Module' {
        $root = New-TDir 'Liste'
        foreach ($n in '2026-11-01_1000_QPC_quelle', '2026-11-02_1000_QPC_quelle') { New-Item -ItemType Directory -Path (Join-Path $root $n) -Force | Out-Null }
        $mk = { param($dir, $st, $mods) [System.IO.File]::WriteAllText((Join-Path $dir 'manifest.json'), ([ordered]@{ Status = $st; Modules = @($mods) } | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($true))) }
        & $mk (Join-Path $root '2026-11-01_1000_QPC_quelle') 'OK' @(New-TModRes 'Daten' 'OK' @(New-TItem 'A' 'OK' 5))
        & $mk (Join-Path $root '2026-11-02_1000_QPC_quelle') 'Error' @(New-TModRes 'Daten' 'Error' @(New-TItem 'A' 'Error' 5 'teilweise'))
        New-Item -ItemType Directory -Path (Join-Path $root '2026-11-02_1000_QPC_quelle\Daten\A') -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $root '2026-11-02_1000_QPC_quelle\Daten\A\a.txt'), 'x')
        $l = @(Get-HMBackupList -Root $root -Modules @())
        $l.Count | Should -Be 2
        @($l[0].ErrorModules) | Should -Be @('Daten')
        @($l[1].ErrorModules).Count | Should -Be 0
        @($l[1].Modules) | Should -Be @('Daten')
    }
}

Describe 'Restore mit Fehler-Modulen: Backup aus Start-HMBackup (Robocopy ersetzt)' {
    BeforeAll {
        Mock Get-HMTargetEnv { @{ WINDIR = (Join-Path $TestDrive 'win'); PROFILE = '' } }
        Mock Get-HMSyncRoots { @() }
        Mock Get-HMMachineGuid { '' }
        Mock Get-HMTargetComputerName { '' }
        Mock Dismount-HMHive { }
        Mock Set-HMBackupFolderAcl { [pscustomobject]@{ Ok = $true; Who = @('Test'); Extra = @(); Notes = @(); Unchanged = $true; Skipped = $false; Error = '' } }
        Mock Update-HMCatalogStats { 0 }
        # nichts Echtes anfassen, auch nicht als Administrator auf dem Runner: Benutzer-Registry und ProgramData\HUMig
        Mock Mount-HMHive { $false }
        Mock Protect-HMDataDir { }
        # Ordner A: Robocopy kopiert eine Datei und meldet 2 gescheiterte; Ordner B: alle Dateien gescheitert, nichts kopiert
        Mock Invoke-HMRobocopy {
            $part = ("$Source" -like '*\A')
            if ($part) { New-Item -ItemType Directory -Path $Dest -Force | Out-Null; [System.IO.File]::WriteAllText((Join-Path $Dest 'a.txt'), 'x') }
            [pscustomobject]@{ ExitCode = 9; Level = 'Error'; FilesTotal = 3; FilesCopied = $(if ($part) { 1 } else { 0 }); FilesSkipped = 0; FilesFailed = $(if ($part) { 2 } else { 3 })
                BytesTotal = 300; BytesCopied = $(if ($part) { 100 } else { 0 }); BytesSkipped = 0; FilesExtra = 0; DirsExtra = 0; HaveDirs = $true
                FailedFiles = @("$Source\b.db"); ErrorCodes = @(5) }
        }
        $script:RunBackup = {
            param([string[]]$Folders)
            $prof = New-TDir 'prof'; $root = New-TDir 'BKR'
            $mods = @(foreach ($f in $Folders) {
                New-Item -ItemType Directory -Path (Join-Path $prof $f) -Force | Out-Null
                [pscustomobject]@{ Id = "M$f"; Name = "Modul $f"; Scope = 'User'; Items = @([pscustomobject]@{ Name = $f; Type = 'Folder'; Path = (Join-Path $prof $f) }) }
            })
            $ctx = @{ Computer = $env:COMPUTERNAME; BackupPath = (Join-Path $root 'neu'); BackupRoot = $root; Options = @{ SkipSpaceCheck = $true }; Settings = @{}; Modules = $mods
                      ToolRoot = $TestDrive; ToolVersion = 'Test'; UserFolder = 'u'; Account = 'u'; UserSid = 'S-1-5-21-1-2-3-1001'; ProfilePath = $prof; Threads = 2 }
            $j = New-TJob
            Start-HMBackup -Ctx $ctx -Job $j
            [pscustomobject]@{ Result = $j.Result; Info = (Read-HMBackupInfo -Path $ctx.BackupPath -Modules @()) }
        }
    }
    It 'Einzelne Dateien gescheitert: Modul Fehler, im Restore waehlbar und markiert; alle gescheitert: ausgeblendet' {
        $o = & $script:RunBackup @('A', 'B')
        @($o.Result.Modules | Where-Object { $_.Id -eq 'MA' })[0].Status | Should -Be 'Error'
        @($o.Result.Modules | Where-Object { $_.Id -eq 'MB' })[0].Status | Should -Be 'Error'
        # B traegt Bytes > 0 (Robocopy zaehlt gescheiterte Dateien mit), liegt aber mit keiner Datei im Backup
        [long]@($o.Result.Modules | Where-Object { $_.Id -eq 'MB' })[0].Bytes | Should -BeGreaterThan 0
        $o.Result.Status | Should -Be 'Error'
        @($o.Info.Modules) | Should -Be @('MA')
        @($o.Info.ErrorModules) | Should -Be @('MA')
    }
    It 'Ohne Backup-Ordner (nur Manifest) entscheidet das Manifest, mit Ordner zaehlt nur eine Datei im Modulordner' {
        $m = New-TModRes 'X' 'Error' @(New-TItem 'A' 'Error' 300 'alle gescheitert')
        Test-HMBackupModuleHasData $m | Should -BeTrue
        $p = New-TDir 'leer'
        Test-HMBackupModuleHasData $m $p | Should -BeFalse
        New-Item -ItemType Directory -Path (Join-Path $p 'X\A') -Force | Out-Null
        Test-HMBackupModuleHasData $m $p | Should -BeFalse
        [System.IO.File]::WriteAllText((Join-Path $p 'X\A\a.txt'), 'x')
        Test-HMBackupModuleHasData $m $p | Should -BeTrue
    }
    It 'Ordnerpruefung: Zeitgrenze zaehlt als mit Daten, Verknuepfungen werden nicht verfolgt' {
        $p = New-TDir 'viele'
        for ($i = 0; $i -lt 300; $i++) { [void][System.IO.Directory]::CreateDirectory((Join-Path $p ("a\b{0:D3}" -f $i))) }
        Test-HMDirHasFile $p 60000 | Should -BeFalse
        Test-HMDirHasFile $p 1 | Should -BeTrue
        Test-HMDirHasFile (Join-Path $p 'gibtsnicht') 1000 | Should -BeFalse
        $z = New-TDir 'ziel'; [System.IO.File]::WriteAllText((Join-Path $z 'x.txt'), 'x')
        $null = & cmd.exe /c mklink /J (Join-Path $p 'a\link') $z
        if (Test-Path -LiteralPath (Join-Path $p 'a\link\x.txt')) { Test-HMDirHasFile $p 60000 | Should -BeFalse }
    }
    It 'Zwischenspeicher je Backup: gleiche manifest.json = gleiches Ergebnis ohne neue Ordnerpruefung, geaenderte = neu; geplante Laeufe ohne Ordnerpruefung' {
        $p = New-TBackup 'Error' @(New-TModRes 'Daten' 'Error' @(New-TItem 'A' 'Error' 300 'alle gescheitert'))
        @((Read-HMBackupInfo -Path $p -Modules @()).Modules).Count | Should -Be 0
        New-Item -ItemType Directory -Path (Join-Path $p 'Daten\A') -Force | Out-Null; [System.IO.File]::WriteAllText((Join-Path $p 'Daten\A\a.txt'), 'x')
        @((Read-HMBackupInfo -Path $p -Modules @()).Modules).Count | Should -Be 0
        $mf = Join-Path $p 'manifest.json'; (Get-Item $mf).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(1)
        @((Read-HMBackupInfo -Path $p -Modules @()).Modules) | Should -Be @('Daten')
        $q = New-TBackup 'Error' @(New-TModRes 'Daten' 'Error' @(New-TItem 'A' 'Error' 300 'alle gescheitert'))
        @((Read-HMBackupInfo -Path $q -Modules @() -NoFileCheck).Modules) | Should -Be @('Daten')
        $bt = Get-Content -Raw -LiteralPath (Join-Path $script:Root 'Functions\Backup-Task.ps1')
        ([regex]::Matches($bt, 'Get-HMBackupList -Root \$targetRoot -Modules \$script:Modules -NoFileCheck')).Count | Should -Be 2
        ([regex]::Matches($bt, 'Get-HMBackupList ')).Count | Should -Be 2
    }
}

Describe 'Restore mit Fehler-Modulen: Hinweis, Rueckfrage und Protokoll' {
    It 'Hinweis nennt die betroffenen Eintraege mit Grund, gekuerzt, hoechstens drei' {
        $long = 'x' * 400
        $m = New-TModRes 'Daten' 'Error' @((New-TItem 'A' 'Error' 1 $script:Fail2), (New-TItem 'B' 'Error' 1 $long), (New-TItem 'C' 'Cancel' 1 "Zeile1`nZeile2"), (New-TItem 'D' 'Error' 1 'd'), (New-TItem 'E' 'OK' 1 'ok'))
        $h = Get-HMModuleErrorHint $m
        $h | Should -Match '^Mit Fehlern gesichert'
        $h | Should -Match 'A: Q:\\Users'
        $h | Should -Match 'C: Zeile1 Zeile2'
        $h | Should -Not -Match 'D: d'
        $h | Should -Not -Match 'E: ok'
        $h | Should -Match '\.\.\. und 1 weitere'
        $h | Should -Match 'Bericht_Backup\.html'
        @($h -split "`n" | Where-Object { $_.Length -gt 200 }).Count | Should -Be 0
        $m | Add-Member -NotePropertyName FromPrevious -NotePropertyValue '2026-11-01 10:00:00'
        Get-HMModuleErrorHint $m | Should -Match 'frueheren Lauf dieses Backups \(2026-11-01 10:00:00\)'
        Get-HMModuleErrorHint $null | Should -Be ''
    }
    It 'Gewaehlte Module mit Fehlern: nur die gewaehlten, mit dem Namen aus dem Manifest' {
        $man = [pscustomobject]@{ Modules = @((New-TModRes 'Daten' 'Error' @()), (New-TModRes 'Mail' 'Error' @()), (New-TModRes 'Profile' 'OK' @())) }
        @(Get-HMRestoreErrorModuleNames $man @([pscustomobject]@{ Id = 'Daten' }, [pscustomobject]@{ Id = 'Profile' })) | Should -Be @('Modul Daten')
        @(Get-HMRestoreErrorModuleNames $man @()).Count | Should -Be 0
    }
    It 'Rueckfrage: Backup ohne Fehler und ohne gewaehlte Fehler-Module - keine Rueckfrage (kein Klick mehr)' {
        Get-HMRestoreIncompleteText 'OK' @() | Should -Be ''
        Get-HMRestoreIncompleteText 'Warning' @() | Should -Be ''
        Get-HMRestoreIncompleteText '' @() | Should -Be ''
    }
    It 'Rueckfrage: Backup mit Fehlern nennt die gewaehlten Fehler-Module, abgebrochenes Backup wie bisher' {
        $t = Get-HMRestoreIncompleteText 'Error' @('Daten', 'Mail')
        $t | Should -Match 'mit FEHLERN beendet'
        $t | Should -Match 'Gewaehlte Module mit Fehlern: Daten, Mail'
        $t | Should -Match 'fehlt auch nach dem Restore'
        $t | Should -Match 'Trotzdem wiederherstellen\?$'
        $o = Get-HMRestoreIncompleteText 'Error' @()
        $o | Should -Match 'mit FEHLERN beendet'
        $o | Should -Not -Match 'Gewaehlte Module'
        Get-HMRestoreIncompleteText 'Cancelled' @() | Should -Match 'ABGEBROCHEN beendet'
    }
    It 'Rueckfrage: Backup OK oder Warnung mit einem uebernommenen Fehler-Modul - sichtbar und markiert, aber keine Rueckfrage (kein zusaetzlicher Klick)' {
        $prev = New-TModRes 'Daten' 'Error' @((New-TItem 'A' 'OK' 5), (New-TItem 'B' 'Error' 5 $script:Fail2))
        $prev | Add-Member -NotePropertyName FromPrevious -NotePropertyValue '2026-11-01 10:00:00'
        $p = New-TBackup 'OK' @((New-TModRes 'Profile' 'OK' @(New-TItem 'Dokumente' 'OK' 500)), $prev) @('Profile', 'Daten')
        $i = Read-HMBackupInfo -Path $p -Modules @()
        @($i.Modules) | Should -Be @('Profile', 'Daten')
        @($i.ErrorModules) | Should -Be @('Daten')
        Get-HMModuleErrorHint @($i.Manifest.Modules | Where-Object { $_.Id -eq 'Daten' })[0] | Should -Match 'frueheren Lauf'
        $bad = @(Get-HMRestoreErrorModuleNames $i.Manifest @([pscustomobject]@{ Id = 'Daten' }))
        $bad | Should -Be @('Modul Daten')
        Get-HMRestoreIncompleteText 'OK' $bad | Should -Be ''
        Get-HMRestoreIncompleteText 'Warning' $bad | Should -Be ''
        Get-HMRestoreIncompleteText 'Running' $bad | Should -Be ''
    }
    It 'Restore-Knopf: eine Rueckfrage aus Get-HMRestoreIncompleteText, gewaehlte Module aus Get-HMRestoreErrorModuleNames' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Root 'HUMig.ps1'), [ref]$null, [ref]$null)
        $txt = @($ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and "$($x.Member)" -eq 'Add_Click' -and "$($x.Expression.Extent.Text)" -eq '$ui.btnRestore' }, $true))[0].Extent.Text
        $txt | Should -Match 'Get-HMRestoreIncompleteText \$bst \$bad'
        $txt | Should -Match 'Get-HMRestoreErrorModuleNames \$b\.Manifest \$mods'
        ([regex]::Matches($txt, 'Restore aus unvollstaendigem Backup''')).Count | Should -Be 1
    }
}

Describe 'Restore mit Fehler-Modulen: Ablauf und Status' {
    BeforeAll {
        Mock Invoke-HMTarget { throw 'Test: Invoke-HMTarget nicht ersetzt' }
        Mock Get-HMTargetEnv { @{ WINDIR = (Join-Path $TestDrive 'win'); PROFILE = '' } }
        Mock Mount-HMHive { $true }
        Mock Dismount-HMHive { }
        Mock Repair-HMRestoredOwner { }
        Mock Register-HMLogonTask { $true }
        Mock Invoke-HMPostRestore { }
        Mock Get-HMUserProfiles { @() }
        function New-TRestoreCtx([object[]]$Modules, $Manifest) {
            $bk = New-TDir 'BK'
            @{ Computer = $env:COMPUTERNAME; Modules = $Modules; Options = @{}; UserFolder = 'ziel'; Account = 'ziel'; ProfilePath = (New-TDir 'prof'); UserSid = 'S-1-5-21-1-2-3-1001'
               ToolRoot = $TestDrive; Threads = 2; Settings = @{}
               Backup = [pscustomobject]@{ Path = $bk; Name = 'BK'; Legacy = $false; Manifest = $Manifest; Account = 'quelle'; Computer = 'QPC'; User = 'quelle'; Created = '2026-11-01'; Sid = ''; ProfilePath = '' } }
        }
        $script:TMods = @([pscustomobject]@{ Id = 'Daten'; Name = 'Daten'; Scope = 'Computer'; Items = @([pscustomobject]@{ Name = 'Info'; Type = 'Builtin'; Handler = 'Info' }) },
                          [pscustomobject]@{ Id = 'Profile'; Name = 'Profil'; Scope = 'Computer'; Items = @([pscustomobject]@{ Name = 'Info'; Type = 'Builtin'; Handler = 'Info' }) })
        $script:TMan = [pscustomobject]@{ Status = 'Error'; Modules = @(([pscustomobject]@{ Id = 'Daten'; Name = 'Daten'; Status = 'Error'; Bytes = 5; Items = @() }), ([pscustomobject]@{ Id = 'Profile'; Name = 'Profil'; Status = 'OK'; Bytes = 5; Items = @() })) }
    }
    It 'Restore eines Fehler-Moduls laeuft durch: Erfolg bleibt Erfolg, Protokoll, Bericht und Ergebnis nennen das Modul' {
        Mock Restore-HMBuiltin { [pscustomobject]@{ Name = 'Info'; Status = 'OK'; Msg = 'ok' } }
        Mock New-HMReport { $script:RepNotes = @($Notes); 'bericht.html' }
        $ctx = New-TRestoreCtx $script:TMods $script:TMan
        $j = New-TJob
        Start-HMRestore -Ctx $ctx -Job $j
        $j.Result.Status | Should -Be 'OK'
        @($j.Result.Modules | Where-Object { $_.Id -eq 'Daten' })[0].Status | Should -Be 'OK'
        (Get-TLog $j) | Should -Match 'Im Backup mit Fehlern gesichert: Daten - was beim Backup nicht gesichert wurde, fehlt auch nach dem Restore'
        (Get-TLog $j) | Should -Not -Match 'Fehlern gesichert: .*Profil'
        @($script:RepNotes | Where-Object { $_ -match '^Im Backup mit Fehlern gesichert: Daten - was beim Backup nicht gesichert wurde, fehlt auch am Ziel' }).Count | Should -Be 1
        @($j.Result.ErrorModules) | Should -Be @('Daten')
    }
    It 'Backup OK mit uebernommenem Fehler-Modul: Restore OK, Hinweis im Bericht' {
        Mock Restore-HMBuiltin { [pscustomobject]@{ Name = 'Info'; Status = 'OK'; Msg = 'ok' } }
        Mock New-HMReport { $script:RepNotes = @($Notes); 'bericht.html' }
        $man = [pscustomobject]@{ Status = 'OK'; Modules = @(([pscustomobject]@{ Id = 'Daten'; Name = 'Daten'; Status = 'Error'; Bytes = 5; FromPrevious = '2026-11-01'; Items = @() }), ([pscustomobject]@{ Id = 'Profile'; Name = 'Profil'; Status = 'OK'; Bytes = 5; Items = @() })) }
        $ctx = New-TRestoreCtx $script:TMods $man
        $j = New-TJob
        Start-HMRestore -Ctx $ctx -Job $j
        $j.Result.Status | Should -Be 'OK'
        ($script:RepNotes -join ' ') | Should -Match 'Im Backup mit Fehlern gesichert: Daten'
    }
    It 'Fehler-Modul mit ausgelassenen Admin-Teilen: weder Protokoll noch Bericht nennen es' {
        Mock Restore-HMBuiltin { [pscustomobject]@{ Name = 'Info'; Status = 'OK'; Msg = 'ok' } }
        Mock New-HMReport { $script:RepNotes = @($Notes); 'bericht.html' }
        $ctx = New-TRestoreCtx $script:TMods $script:TMan
        $ctx.SkipUntrustedMachine = @('Daten')
        $j = New-TJob
        Start-HMRestore -Ctx $ctx -Job $j
        (Get-TLog $j) | Should -Not -Match 'mit Fehlern gesichert'
        ($script:RepNotes -join ' ') | Should -Not -Match 'mit Fehlern gesichert'
        @($j.Result.ErrorModules).Count | Should -Be 0
    }
    It 'Fehler beim Restore des Fehler-Moduls bleibt Fehler' {
        Mock Restore-HMBuiltin { [pscustomobject]@{ Name = 'Info'; Status = $(if ($Module.Id -eq 'Daten') { 'Error' } else { 'OK' }); Msg = 'x' } }
        $ctx = New-TRestoreCtx $script:TMods $script:TMan
        $j = New-TJob
        Start-HMRestore -Ctx $ctx -Job $j
        $j.Result.Status | Should -Be 'Error'
        @($j.Result.Modules | Where-Object { $_.Id -eq 'Daten' })[0].Status | Should -Be 'Error'
    }
    It 'Backup ohne Fehler-Module: keine zusaetzliche Protokollzeile' {
        Mock Restore-HMBuiltin { [pscustomobject]@{ Name = 'Info'; Status = 'OK'; Msg = 'ok' } }
        $man = [pscustomobject]@{ Status = 'OK'; Modules = @([pscustomobject]@{ Id = 'Profile'; Name = 'Profil'; Status = 'OK'; Bytes = 5; Items = @() }) }
        $ctx = New-TRestoreCtx @($script:TMods[1]) $man
        $j = New-TJob
        Start-HMRestore -Ctx $ctx -Job $j
        $j.Result.Status | Should -Be 'OK'
        (Get-TLog $j) | Should -Not -Match 'mit Fehlern gesichert'
        @($j.Result.ErrorModules).Count | Should -Be 0
    }
}

Describe 'Restore mit Fehler-Modulen: Reiter Restore (echtes Build-ModulePanel)' {
    BeforeAll {
        # Funktionen aus HUMig.ps1 als Text; jeder Test laedt sie mit ". ([scriptblock]::Create($script:FnText))" in seinen Bereich
        $hast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Root 'HUMig.ps1'), [ref]$null, [ref]$null)
        $script:FnText = (@('Build-ModulePanel', 'Set-HMRestoreModulesForBackup', 'Set-HMRestoreCheckMark', 'Get-CheckedModules', 'New-Brush') | ForEach-Object {
            $n = $_; @($hast.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $n }, $true))[0].Extent.Text }) -join "`n"
        $script:FnText += "`nfunction Get-ConsoleBrush { param(`$c) New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString(`$c)) }"
        function New-TPanel([bool]$UserMode) {
            Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
            $script:UserMode = $UserMode
            $script:Groups = @('Profil', 'System')
            $script:Modules = @([pscustomobject]@{ Id = 'Profile'; Name = 'Benutzerprofil mit einem sehr langen Namen, der umbrechen muss'; Group = 'Profil'; Scope = 'User'; Show = $true; Default = $true; Hint = 'Dokumente, Bilder' },
                                [pscustomobject]@{ Id = 'Daten'; Name = 'Daten'; Group = 'Profil'; Scope = 'User'; Show = $true; Default = $true },
                                [pscustomobject]@{ Id = 'Info'; Name = 'Info-Export'; Group = 'System'; Scope = 'Computer'; Show = $true; Default = $true })
            $script:RestoreChecks = @{}
            $script:ui = @{ pnlRestoreModules = New-Object System.Windows.Controls.StackPanel }
            Build-ModulePanel $script:ui.pnlRestoreModules $script:RestoreChecks -Restore
        }
        $script:ErrBackup = [pscustomobject]@{ Modules = @('Profile', 'Daten', 'Info'); ErrorModules = @('Profile', 'Info')
            Manifest = [pscustomobject]@{ Status = 'Error'; Modules = @((New-TModRes 'Profile' 'Error' @(New-TItem 'Desktop' 'Error' 5 $script:Fail2)), (New-TModRes 'Daten' 'OK' @()), (New-TModRes 'Info' 'Error' @(New-TItem 'Info' 'Error' 5 'teilweise'))) } }
    }
    BeforeEach {
        $script:StatusColors = @{ OK = '#FFA6E3A1'; Warning = '#FFFAB387'; Error = '#FFF38BA8'; Info = '#FF89B4FA'; Grey = '#FF6C7086' }
    }
    It 'Fehler-Modul: sichtbar, waehlbar, angehakt wie ein Modul mit Warnung, markiert; Info bleibt ohne Haken' -Skip:(-not $script:StaD) {
        . ([scriptblock]::Create($script:FnText))
        New-TPanel $false
        $n = Set-HMRestoreModulesForBackup $script:ErrBackup
        $n | Should -Be 0
        $cb = $script:RestoreChecks['Profile']
        "$($cb.Parent.Visibility)" | Should -Be 'Visible'
        $cb.IsEnabled | Should -BeTrue
        $cb.IsChecked | Should -BeTrue
        $cb.Content.Text | Should -Be 'Benutzerprofil mit einem sehr langen Namen, der umbrechen muss (mit Fehlern gesichert)'
        "$($cb.Content.TextWrapping)" | Should -Be 'Wrap'
        "$($cb.Content.Foreground.Color)" | Should -Be '#FFFAB387'
        "$($cb.ToolTip)" | Should -Match '^Benutzerprofil mit einem sehr langen Namen, der umbrechen muss\nDokumente, Bilder\n\nMit Fehlern gesichert'
        "$($cb.ToolTip)" | Should -Match 'Desktop: Q:\\Users'
        $script:RestoreChecks['Info'].IsChecked | Should -BeFalse
        $script:RestoreChecks['Info'].Content.Text | Should -Match 'mit Fehlern gesichert'
        $script:RestoreChecks['Daten'].Content.Text | Should -Be 'Daten'
        @(Get-CheckedModules $script:RestoreChecks | ForEach-Object { $_.Id }) | Should -Be @('Profile', 'Daten')
    }
    It 'Wechsel auf ein Backup ohne Fehler nimmt die Markierung zurueck, Fehler-Modul ohne Daten ist ausgeblendet' -Skip:(-not $script:StaD) {
        . ([scriptblock]::Create($script:FnText))
        New-TPanel $false
        [void](Set-HMRestoreModulesForBackup $script:ErrBackup)
        $n = Set-HMRestoreModulesForBackup ([pscustomobject]@{ Modules = @('Profile'); ErrorModules = @(); Manifest = [pscustomobject]@{ Status = 'OK'; Modules = @() } })
        $n | Should -Be 2
        $cb = $script:RestoreChecks['Profile']
        $cb.Content.Text | Should -Be 'Benutzerprofil mit einem sehr langen Namen, der umbrechen muss'
        $cb.Content.ReadLocalValue([System.Windows.Controls.TextBlock]::ForegroundProperty) | Should -Be ([System.Windows.DependencyProperty]::UnsetValue)
        "$($cb.ToolTip)" | Should -Be "Benutzerprofil mit einem sehr langen Namen, der umbrechen muss`nDokumente, Bilder"
        "$($script:RestoreChecks['Daten'].Parent.Visibility)" | Should -Be 'Collapsed'
        # Backup ohne Eigenschaft ErrorModules (z. B. aus einer aelteren Liste): keine Markierung, kein Fehler
        { Set-HMRestoreModulesForBackup ([pscustomobject]@{ Modules = @('Profile') }) } | Should -Not -Throw
        $cb.Content.Text | Should -Not -Match 'Fehlern'
    }
    It 'Benutzer-Modus: Markierung und Auswahl wie im Administrator-Modus' -Skip:(-not $script:StaD) {
        . ([scriptblock]::Create($script:FnText))
        New-TPanel $true
        [void](Set-HMRestoreModulesForBackup $script:ErrBackup)
        $script:RestoreChecks['Profile'].Content.Text | Should -Match '\(mit Fehlern gesichert\)$'
        $script:RestoreChecks['Profile'].IsEnabled | Should -BeTrue
        $script:RestoreChecks['Profile'].IsChecked | Should -BeTrue
        # Computer-Module gibt es im Benutzer-Modus nicht (wie bisher), auch nicht mit Fehlern
        $script:RestoreChecks.ContainsKey('Info') | Should -BeFalse
    }
}
