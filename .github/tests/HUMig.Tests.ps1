#Requires -Version 5.1
# Pester-Tests (Pester 5) fuer reine Logik-Funktionen von HUMig - laufen bei jedem Push auf GitHub (Windows PowerShell 5.1)

BeforeAll {
    $script:Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:AppRoot = $script:Root
    $script:ConfigDir = Join-Path $TestDrive 'Config'
    $script:LogDir = Join-Path $TestDrive 'Logs'
    . (Join-Path $script:Root 'Functions\Core-Update.ps1')
    . (Join-Path $script:Root 'Functions\ServerBackup-Engine.ps1')
    . (Join-Path $script:Root 'Functions\UI-ServerBackup.ps1')
    function New-HMRel($Tag, $Pre, $Assets = @(), $Draft = $false) {
        [pscustomobject]@{ tag_name = $Tag; prerelease = $Pre; draft = $Draft; published_at = '2026-10-01T08:00:00Z'; body = "Notiz $Tag"; assets = $Assets }
    }
}

Describe 'Update: Versionen und Kanal' {
    It 'erkennt Versionen aus Tags' {
        "$(ConvertTo-HMVersion 'v2.0.53')" | Should -Be '2.0.53'
        "$(ConvertTo-HMVersion '2.0.9')" | Should -Be '2.0.9'
        ConvertTo-HMVersion 'backup-20260101' | Should -BeNullOrEmpty
    }
    It 'sortiert numerisch (2.0.10 > 2.0.9) und ignoriert Entwuerfe' {
        $l = ConvertTo-HMReleaseList @((New-HMRel 'v2.0.9' $false), (New-HMRel 'v2.0.10' $false), (New-HMRel 'v2.0.99' $false @() $true), (New-HMRel 'backup-x' $false))
        @($l).Count | Should -Be 2
        "$($l[0].Version)" | Should -Be '2.0.10'
    }
    It 'Kanal Stabil nimmt nur freigegebene, Test auch Vorab-Releases' {
        $l = ConvertTo-HMReleaseList @((New-HMRel 'v2.0.54' $true), (New-HMRel 'v2.0.53' $false))
        (Select-HMRelease $l 'Stable').Tag | Should -Be 'v2.0.53'
        (Select-HMRelease $l 'Test').Tag | Should -Be 'v2.0.54'
        Select-HMRelease @() 'Stable' | Should -BeNullOrEmpty
    }
    It 'Signaturpflicht: nur Releases mit Pruefsumme und Signatur' {
        $m = [pscustomobject]@{ name = 'HUMig-files.sha256'; browser_download_url = 'https://x/m'; url = 'https://api/m' }
        $s = [pscustomobject]@{ name = 'HUMig-files.sha256.p7s'; browser_download_url = 'https://x/s'; url = 'https://api/s' }
        $l = ConvertTo-HMReleaseList @((New-HMRel 'v2.0.56' $false @($m)), (New-HMRel 'v2.0.55' $false @($m, $s)), (New-HMRel 'v2.0.54' $false @($s)))
        (Select-HMRelease $l 'Stable' -SignedOnly).Tag | Should -Be 'v2.0.55'
        (Select-HMRelease $l 'Stable').Tag | Should -Be 'v2.0.56'
        Select-HMRelease @(ConvertTo-HMReleaseList @(New-HMRel 'v2.0.56' $false @($m))) 'Test' -SignedOnly | Should -BeNullOrEmpty
    }
    It 'findet Pruefsummen- und Signatur-Datei im Release' {
        $a = @([pscustomobject]@{ name = 'HUMig-files.sha256'; browser_download_url = 'https://x/m'; url = 'https://api/m' }, [pscustomobject]@{ name = 'HUMig-files.sha256.p7s'; browser_download_url = 'https://x/s'; url = 'https://api/s' })
        $r = @(ConvertTo-HMReleaseList @(New-HMRel 'v2.0.53' $false $a))[0]
        $r.ManifestUrl | Should -Be 'https://x/m'
        $r.SignatureApi | Should -Be 'https://api/s'
    }
    It 'liest update.json (Standard: offizielle Quelle, Kanal Stabil, nur signiert)' {
        $d = Join-Path $TestDrive 'cfg1'; New-Item -ItemType Directory -Path $d -Force | Out-Null
        $c = Get-HMUpdateConfig $d
        $c.Channel | Should -Be 'Stable'; $c.Owner | Should -Be 'ChiliApple'
        $c.RequireSignature | Should -BeTrue; $c.DefaultSigner | Should -BeTrue; $c.SignerThumbprint | Should -Match '^[0-9A-F]{40}$'
        Set-Content (Join-Path $d 'update.json') '{"Channel":"Test","UseBranch":true}' -Encoding UTF8
        $c = Get-HMUpdateConfig $d
        $c.Channel | Should -Be 'Test'; $c.RequireSignature | Should -BeTrue; $c.UseBranch | Should -BeFalse
        Set-Content (Join-Path $d 'update.json') '{"AllowUnsigned":true,"UseBranch":true}' -Encoding UTF8
        $c = Get-HMUpdateConfig $d
        $c.RequireSignature | Should -BeFalse; $c.UseBranch | Should -BeTrue
        Set-Content (Join-Path $d 'update.json') '{"Owner":"Schule","Repo":"Eigen"}' -Encoding UTF8
        $c = Get-HMUpdateConfig $d
        $c.RequireSignature | Should -BeFalse; $c.SignerThumbprint | Should -Be ''
        Set-Content (Join-Path $d 'update.json') '{"Owner":"Schule","Repo":"Eigen","SignerThumbprint":"ab:cd ef"}' -Encoding UTF8
        $c = Get-HMUpdateConfig $d
        $c.RequireSignature | Should -BeTrue; $c.SignerThumbprint | Should -Be 'ABCDEF'; $c.DefaultSigner | Should -BeFalse
    }
}

Describe 'Update: Pruefsumme und Signatur' {
    It 'liest die Pruefsummen-Datei (sha256sum-Format)' {
        $m = ConvertFrom-HMManifest (('a' * 64) + "  Functions/X.ps1`n" + ('B' * 64) + " *Docs/a b.html`r`nkaputt")
        $m.Count | Should -Be 2
        $m['Docs/a b.html'] | Should -Be ('b' * 64)
    }
    It 'berechnet SHA256 wie Get-FileHash' {
        $f = Join-Path $TestDrive 'h.bin'; [System.IO.File]::WriteAllBytes($f, [byte[]](1..200))
        Get-HMFileSha256 $f | Should -Be (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash.ToLower()
    }
    It 'prueft die Signatur (gueltig / anderes Zertifikat / veraendert / fehlt)' {
        try { Add-Type -AssemblyName System.Security -ErrorAction Stop } catch { }
        $cert = $null; $fromStore = $false
        try {
            if (Get-Command New-SelfSignedCertificate -ErrorAction SilentlyContinue) {
                $cert = New-SelfSignedCertificate -Subject 'CN=HUMig CI Test' -Type CodeSigningCert -CertStoreLocation Cert:\CurrentUser\My -NotAfter (Get-Date).AddDays(1)
                $fromStore = $true
            } else {
                $rsa = [System.Security.Cryptography.RSA]::Create(2048)
                $req = New-Object System.Security.Cryptography.X509Certificates.CertificateRequest -ArgumentList 'CN=HUMig CI Test', $rsa, ([System.Security.Cryptography.HashAlgorithmName]::SHA256), ([System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
                $cert = $req.CreateSelfSigned((Get-Date).AddDays(-1), (Get-Date).AddDays(1))
            }
            $man = [System.Text.Encoding]::UTF8.GetBytes(('a' * 64) + "  HUMig.ps1`n")
            $ci = New-Object System.Security.Cryptography.Pkcs.ContentInfo -ArgumentList (, [byte[]]$man)
            $cms = New-Object System.Security.Cryptography.Pkcs.SignedCms -ArgumentList $ci, $true
            $cms.ComputeSignature((New-Object System.Security.Cryptography.Pkcs.CmsSigner -ArgumentList $cert), $true)
            $sig = $cms.Encode()
            Test-HMManifestSignature $man $sig $cert.Thumbprint | Should -BeNullOrEmpty
            Test-HMManifestSignature $man $sig ('0' * 40) | Should -Match 'anderen Zertifikat'
            $man2 = [System.Text.Encoding]::UTF8.GetBytes(('b' * 64) + "  HUMig.ps1`n")
            Test-HMManifestSignature $man2 $sig $cert.Thumbprint | Should -Match 'ungueltig'
            Test-HMManifestSignature $man $null $cert.Thumbprint | Should -Match 'keine Signatur'
            Test-HMManifestSignature $man $sig '' | Should -Match 'Fingerabdruck'
            # Signieren wie in HUMig (Release signieren)
            $sig2 = New-HMManifestSignature $man $cert
            Test-HMManifestSignature $man $sig2 $cert.Thumbprint | Should -BeNullOrEmpty
            if ($fromStore) { (Get-HMSigningCert $cert.Thumbprint).Thumbprint | Should -Be $cert.Thumbprint }
            Get-HMSigningCert ('0' * 40) | Should -BeNullOrEmpty
        } finally { if ($fromStore -and $cert) { Remove-Item -LiteralPath "Cert:\CurrentUser\My\$($cert.Thumbprint)" -Force -ErrorAction SilentlyContinue } }
    }
}

Describe 'Server-Backup: Hilfsfunktionen' {
    It 'Dauer lesbar' {
        Format-HMDuration 372 | Should -Be '6 h 12 min'
        Format-HMDuration 5.5 | Should -Be '5 min 30 s'
        Format-HMDuration 45 | Should -Be '45 min'
        Format-HMDuration 0.5 | Should -Be '30 s'
    }
    It 'Archiv-Platten (Prefix-A1, -A2 ...)' {
        Test-HMSbArchiveLabel 'HUMIG-GYM-A1' 'HUMIG-GYM' | Should -BeTrue
        Test-HMSbArchiveLabel 'humig-gym-a12' 'HUMIG-GYM' | Should -BeTrue
        Test-HMSbArchiveLabel 'HUMIG-GYM-1' 'HUMIG-GYM' | Should -BeFalse
        Test-HMSbArchiveLabel 'HUMIG-GYMA-1' 'HUMIG-GYM' | Should -BeFalse
        Test-HMSbArchiveLabel 'X-A2' '' | Should -BeTrue
    }
    It 'Nach Sicherung je Platte (auswerfen/offline)' {
        $p = ConvertTo-HMSbProfile ([pscustomobject]@{ Name = 'Gym'; DiskPrefix = 'HUMIG-GYM'; Disks = 2; DiskAfter = [pscustomobject]@{ 'HUMIG-GYM-1' = 'Eject'; 'HUMIG-GYM-2' = 'Unsinn' } })
        Get-HMSbAfterMode $p 'humig-gym-1' | Should -Be 'Eject'
        Get-HMSbAfterMode $p 'HUMIG-GYM-2' | Should -Be ''
        Get-HMSbAfterMode ([pscustomobject]@{ DiskAfter = @{ 'A' = 'Offline' } }) 'a' | Should -Be 'Offline'
    }
    It 'VMs mit Dateien auf C: (Host-System)' {
        $v = @(
            [pscustomobject]@{ Name = 'DC'; Paths = @('D:\Hyper-V\DC.vhdx'); VmPath = 'D:\Hyper-V'; ConfigPath = 'D:\Hyper-V' },
            [pscustomobject]@{ Name = 'WSUS'; Paths = @('C:\VMs\wsus.vhdx', 'D:\x.vhdx'); VmPath = 'D:\VMs'; ConfigPath = 'D:\VMs' },
            [pscustomobject]@{ Name = 'Print'; Paths = @('D:\p.vhdx'); VmPath = 'C:\ProgramData\Microsoft\Windows\Hyper-V'; ConfigPath = 'C:\ProgramData\Microsoft\Windows\Hyper-V' })
        $l = @(Get-HMSbSysDriveVms $v 'C:')
        $l.Count | Should -Be 2
        @($l | Where-Object { -not $_.ConfigOnly }).Name | Should -Be 'WSUS'
        @($l | Where-Object { $_.ConfigOnly }).Name | Should -Be 'Print'
        Format-HMSbSysDriveVms (Get-HMSbSysDriveVms @($v[0]) 'C:') 'C:' | Should -Be ''
    }
    It 'Veto-Grund beim Auswerfen' {
        Format-HMSbVeto 'CR 23, Veto 5 STORAGE\Volume' | Should -Match 'noch geoeffnet'
        Format-HMSbVeto 'Geraet nicht gefunden' | Should -Be 'Geraet nicht gefunden'
    }
    It 'Plattenstatus: Rotation, Archiv faellig, Hinweise' {
        $now = Get-Date
        $e = { param($d, $disk, $st = 'OK') [pscustomobject]@{ Date = $now.AddDays(-$d).ToString('yyyy-MM-dd HH:mm'); Profile = 'Gym'; Disk = $disk; Status = $st } }
        $p = ConvertTo-HMSbProfile ([pscustomobject]@{ Name = 'Gym'; DiskPrefix = 'HUMIG-GYM'; Disks = 3; ArchiveDisks = 2; ArchiveDays = 30 })
        $m = Get-HMSbDiskStatus $p @((& $e 0 'HUMIG-GYM-1' 'Error'), (& $e 1 'HUMIG-GYM-1'), (& $e 8 'HUMIG-GYM-2'), (& $e 20 'HUMIG-GYM-3'), (& $e 10 'HUMIG-GYM-A1'), (& $e 50 'HUMIG-GYM-A2'))
        @($m.Rotation).Count | Should -Be 3
        @($m.Archive).Count | Should -Be 2
        @($m.Rotation[2].Tags | ForEach-Object { $_.Text }) | Should -Contain 'naechste laut Rotation'
        @($m.Rotation[0].Tags | ForEach-Object { $_.Text }) | Should -Contain 'letzter Lauf fehlgeschlagen'
        $m.Rotation[2].Dot | Should -Be '#FFFAB387'
        @($m.Archive[1].Tags | ForEach-Object { $_.Text }) | Should -Contain 'naechste in 20 Tagen'
        $m2 = Get-HMSbDiskStatus $p @()
        @($m2.Hints | ForEach-Object { $_.Text }) -join ' ' | Should -Match 'Noch keine erfolgreiche Sicherung'
        @($m2.Archive[0].Tags | ForEach-Object { $_.Text }) | Should -Contain 'faellig'
    }
}

Describe 'App-Updates (WinGet)' {
    BeforeAll {
        . (Join-Path $script:Root 'Functions\AppUpdates-Engine.ps1')
        function global:Get-WinGetPackage { param($Source) }
        function global:Update-WinGetPackage { param($Id, $Source, $MatchOption, $Mode, [switch]$IncludeUnknown) }
        if (-not (Get-Command Write-HMLog -ErrorAction SilentlyContinue)) { function global:Write-HMLog($Job, $Msg, $Lvl) { } }
        if (-not (Get-Command Test-HMCancel -ErrorAction SilentlyContinue)) { function global:Test-HMCancel($Job) { $false } }
    }
    It 'Ausnahmen: Muster auf Paket-ID oder Name' {
        $ex = @([pscustomobject]@{ Pattern = 'Microsoft.Edge*'; Reason = 'selbst' }, [pscustomobject]@{ Pattern = '*Next-Exam*'; Reason = 'Pruefung' })
        (Find-HMAuExclusion ([pscustomobject]@{ Id = 'Microsoft.EdgeWebView2Runtime'; Name = 'WebView2' }) $ex).Reason | Should -Be 'selbst'
        (Find-HMAuExclusion ([pscustomobject]@{ Id = 'X.Y'; Name = 'Next-Exam 1.4' }) $ex).Reason | Should -Be 'Pruefung'
        Find-HMAuExclusion ([pscustomobject]@{ Id = 'Mozilla.Firefox'; Name = 'Mozilla Firefox' }) $ex | Should -BeNullOrEmpty
    }
    It 'Ergebnis lesbar' {
        Format-HMAuResult 'Ok' 0 0 $false | Should -Be 'aktualisiert'
        Format-HMAuResult 'Ok' 0 0 $true | Should -Match 'Neustart'
        Format-HMAuResult 'InstallError' 1603 0 $false | Should -Match '1603.*Programm laeuft'
    }
    It 'winget.exe-Code (als SYSTEM) lesbar' {
        (Format-HMAuCliResult 0 '').Ok | Should -BeTrue
        $r = Format-HMAuCliResult -1978335189 ''
        $r.Ok | Should -BeFalse; $r.Text | Should -Match '0x8A15002B'
        $r = Format-HMAuCliResult -1978334967 ''
        $r.Ok | Should -BeTrue; $r.Reboot | Should -BeTrue
        (Format-HMAuCliResult 5 'Zugriff verweigert').Text | Should -Match 'Zugriff verweigert'
    }
    It 'Aktualisieren: je PC ein Auftrag, Uebersprungen bei laufendem Programm, Ergebnis je PC' {
        $global:AuCall = $null
        Mock Invoke-HMAuTarget {
            $global:AuCall = @{ Computers = @($Computers); Op = $Op; Payload = $Payload }
            $out = @{}
            foreach ($k in @($Payload.ByPc.Keys)) {
                $res = @(foreach ($i in @($Payload.ByPc[$k].Items)) {
                        if ($i.Id -eq 'A.A') { [pscustomobject]@{ Id = 'A.A'; Status = 'Cli'; Code = -1978334967; Text = '' } }
                        elseif ($i.Id -eq 'B.B') { [pscustomobject]@{ Id = 'B.B'; Status = 'InstallError'; InstallerErrorCode = 1603; ExtendedErrorCode = 0; Reboot = $false } }
                    })
                $out[$k] = [pscustomobject]@{ Results = $res; Errors = @() }
            }
            $out
        }
        $job = @{ Log = $null; Progress = 0; Status = ''; Cancel = $false; Result = $null }
        $lk = "$env:COMPUTERNAME".ToUpper()
        $ctx = @{ Op = 'Update'; ByPc = @{
                $lk = @{ UserSid = 'S-1-5-21-1'; UserAccount = 'PC\lehrer'; Items = @(
                        [pscustomobject]@{ Id = 'A.A'; Name = 'Alpha'; Source = 'winget'; Installed = '1'; Available = '2'; Scope = 'Machine' },
                        [pscustomobject]@{ Id = 'C.C'; Name = 'Gamma'; Source = 'winget'; Installed = '1'; Available = '2'; Scope = 'User' }) }
                'PC-R2' = @{ UserSid = ''; UserAccount = ''; Items = @([pscustomobject]@{ Id = 'B.B'; Name = 'Beta'; Source = 'winget'; Installed = '1'; Available = '2'; Scope = 'Machine' }) }
            }
            Running = @([pscustomobject]@{ Id = 'C.C'; Name = 'Gamma'; Running = 'gamma (1)'; Procs = @() }); ProcDecisions = @{ 'C.C' = 'Skip' }
        }
        Start-HMAppUpdate -Ctx $ctx -Job $job
        $global:AuCall.Op | Should -Be 'Update'
        @($global:AuCall.Computers).Count | Should -Be 2
        @($global:AuCall.Payload.ByPc[$lk].Items).Count | Should -Be 1   # Gamma uebersprungen
        $it = @($job.Result.Items)
        $it.Count | Should -Be 3
        ($it | Where-Object Id -eq 'A.A').Status | Should -Be 'OK'
        ($it | Where-Object Id -eq 'A.A').Computer | Should -Be $lk
        ($it | Where-Object Id -eq 'B.B').Computer | Should -Be 'PC-R2'
        ($it | Where-Object Id -eq 'B.B').Text | Should -Match '1603'
        ($it | Where-Object Id -eq 'C.C').Status | Should -Be 'Skipped'
        $job.Result.Status | Should -Be 'Warning'
        $job.Result.Reboot | Should -BeTrue
    }
    It 'Ziel-Skripte: gueltige Syntax, Ziel-PC findet seinen Auftrag' {
        foreach ($f in 'AppUpdates-Target.ps1', 'AppUpdates-Auto.ps1', 'AppUpdates-Worker.ps1') {
            $t = $null; $e = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Root "Functions\$f"), [ref]$t, [ref]$e)
            @($e).Count | Should -Be 0
        }
        Get-HMAuPcKey 'localhost' | Should -Be "$env:COMPUTERNAME".ToUpper()
        Get-HMAuPcKey 'pc-01.schule.local' | Should -Be 'PC-01.SCHULE.LOCAL'
        (Format-HMAuCliResult -1978335215 '').Text | Should -Match 'Pruefsumme'
    }
}

Describe 'Migration: Robocopy-Auswertung' {
    BeforeAll {
        . (Join-Path $script:Root 'Functions\Migration-Engine.ps1')
    }
    It 'Zusammenfassung: Fehler und Extras (nur im Backup) werden gelesen' {
        $t = @'
               Insgesamt   KopiertÜbersprungenKeine Übereinstimmung    FEHLER    Extras
    Verzeich.:        12         0        12         0         0         1
      Dateien:       120        10       105         0         5         7
        Bytes:    100000     20000     70000         0     10000      3000
'@
        $s = Get-HMRobocopySummary $t
        $s.FilesTotal | Should -Be 120
        $s.FilesFailed | Should -Be 5
        $s.FilesExtra | Should -Be 7
        $s.BytesCopied | Should -Be 20000
    }
    It 'Zusammenfassung ohne Extras-Spalte (aeltere Ausgabe) bleibt lesbar' {
        $s = Get-HMRobocopySummary '   Files :  3  1  2  0  0'
        $s.FilesTotal | Should -Be 3
        $s.FilesExtra | Should -Be 0
    }
}

Describe 'Schutz von ProgramData\HUMig (Core-Protect.ps1)' {
    BeforeAll {
        . (Join-Path $script:Root 'Functions\Migration-Engine.ps1')
        $script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        $script:OldPD = $env:ProgramData
        function Get-HMTestAcl([string]$Path) {
            $a = [System.IO.Directory]::GetAccessControl($Path)
            [pscustomobject]@{
                Protected = $a.AreAccessRulesProtected
                Owner = $a.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
                Rules = @($a.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]) | ForEach-Object { "$($_.IdentityReference.Value)=$($_.FileSystemRights)" } | Sort-Object)
            }
        }
    }
    AfterEach { $env:ProgramData = $script:OldPD }
    It 'legt den Ordner an: Besitzer Administratoren, Vererbung aus, nur SYSTEM/Admins schreiben, Benutzer lesen' {
        if (-not $script:IsAdmin) { Set-ItResult -Skipped -Because 'braucht Administratorrechte'; return }
        $env:ProgramData = Join-Path $TestDrive 'pd1'; New-Item -ItemType Directory -Path $env:ProgramData -Force | Out-Null
        Protect-HMDataDir | Should -Match 'abgesichert'
        $a = Get-HMTestAcl (Join-Path $env:ProgramData 'HUMig')
        $a.Protected | Should -BeTrue
        $a.Owner | Should -Be 'S-1-5-32-544'
        ($a.Rules -join ';') | Should -Be 'S-1-5-18=FullControl;S-1-5-32-544=FullControl;S-1-5-32-545=ReadAndExecute, Synchronize'
        Protect-HMDataDir | Should -BeNullOrEmpty   # zweiter Aufruf: schon geschuetzt, nichts zu tun
    }
    It 'entfernt Verknuepfungen nur als Link (Ziel bleibt) und setzt Rechte im Inhalt zurueck' {
        if (-not $script:IsAdmin) { Set-ItResult -Skipped -Because 'braucht Administratorrechte'; return }
        $env:ProgramData = Join-Path $TestDrive 'pd2'
        $root = Join-Path $env:ProgramData 'HUMig'
        $outside = Join-Path $TestDrive 'aussen'; New-Item -ItemType Directory -Path $outside -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $outside 'wichtig.txt') -Value 'bleibt'
        New-Item -ItemType Directory -Path (Join-Path $root 'AppUpdates\auto') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'AppUpdates\auto\auto.ps1') -Value 'x'
        New-Item -ItemType Junction -Path (Join-Path $root 'Link') -Target $outside | Out-Null
        # wie ein Benutzer-Eintrag aus alten Versionen: Schreib-/Loeschrecht fuer Benutzer
        $null = & icacls.exe (Join-Path $root 'AppUpdates') /grant '*S-1-5-32-545:(OI)(CI)M'
        $null = & icacls.exe $root /grant '*S-1-5-32-545:(OI)(CI)(RX,D)'
        Protect-HMDataDir | Should -Match 'abgesichert'
        Test-Path -LiteralPath (Join-Path $root 'Link') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $outside 'wichtig.txt') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $root 'AppUpdates\auto\auto.ps1') | Should -BeTrue
        $s = Get-HMTestAcl (Join-Path $root 'AppUpdates')
        $s.Protected | Should -BeFalse
        @($s.Rules).Count | Should -Be 0          # keine eigenen Eintraege mehr, nur geerbte
        $s.Owner | Should -Be 'S-1-5-32-544'
        (Get-HMTestAcl $root).Rules -join ';' | Should -Not -Match 'S-1-5-32-545=.*(Modify|Delete)'
    }
    It 'ist die Wurzel selbst eine Verknuepfung, wird nur der Link entfernt' {
        if (-not $script:IsAdmin) { Set-ItResult -Skipped -Because 'braucht Administratorrechte'; return }
        $env:ProgramData = Join-Path $TestDrive 'pd3'; New-Item -ItemType Directory -Path $env:ProgramData -Force | Out-Null
        $tgt = Join-Path $TestDrive 'ziel3'; New-Item -ItemType Directory -Path $tgt -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $tgt 'daten.txt') -Value 'bleibt'
        New-Item -ItemType Junction -Path (Join-Path $env:ProgramData 'HUMig') -Target $tgt | Out-Null
        Protect-HMDataDir | Should -Match 'abgesichert'
        ((Get-Item -LiteralPath (Join-Path $env:ProgramData 'HUMig') -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) | Should -Be 0
        Test-Path -LiteralPath (Join-Path $tgt 'daten.txt') | Should -BeTrue
        (Get-HMTestAcl $tgt).Protected | Should -BeFalse   # Ziel unveraendert
    }
    It 'Invoke-HMTargetProtected: Absicherung vor dem Skript, Argumente kommen an' {
        if (-not $script:IsAdmin) { Set-ItResult -Skipped -Because 'braucht Administratorrechte'; return }
        $env:ProgramData = Join-Path $TestDrive 'pd4'; New-Item -ItemType Directory -Path $env:ProgramData -Force | Out-Null
        $r = Invoke-HMTargetProtected @{ IsRemote = $false } { param($a, $b) "$a|$b|$HMProtected" } @('x', 'y z')
        $r | Should -Be 'x|y z|True'
        (Get-HMTestAcl (Join-Path $env:ProgramData 'HUMig')).Protected | Should -BeTrue
        Invoke-HMTargetProtected @{ IsRemote = $false; UserMode = $true } { param($a) "um:$a" } @('1') | Should -Be 'um:1'
    }
    Context 'Profil-Sicherung pruefen (Test-HMProfileBackup)' {
        BeforeAll {
            $script:Bd = Join-Path $TestDrive 'ProfilSicherung'; New-Item -ItemType Directory -Path $script:Bd -Force | Out-Null
            $script:Sid = 'S-1-5-21-111-222-333-1001'
            function New-HMTestReg([string]$Sid, [string]$Img, [string]$Key = '') {
                if (-not $Key) { $Key = "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$Sid" }
                $hex = (@([System.Text.Encoding]::Unicode.GetBytes($Img + [char]0)) | ForEach-Object { '{0:x2}' -f $_ }) -join ','
                $f = Join-Path $script:Bd "ProfileList_$($Sid)_20261010_120000.reg"
                $txt = "Windows Registry Editor Version 5.00`r`n`r`n[$Key]`r`n`"ProfileImagePath`"=hex(2):$($hex.Substring(0, 30))\`r`n  $($hex.Substring(30))`r`n`"Flags`"=dword:00000000`r`n"
                Set-Content -LiteralPath $f -Value $txt -Encoding Unicode
                return $f
            }
            function New-HMTestBackup([string]$Sid, [string]$Path, [string]$Reg) {
                [pscustomobject]@{ Sid = $Sid; Path = $Path; AltPath = "$Path.alt_20261010_120000"; Reg = $Reg }
            }
            $script:Json = Join-Path $script:Bd "Profil_$($script:Sid)_20261010_120000.json"
        }
        It 'echte Sicherung (wie von Profil erneuern angelegt) ist gueltig' {
            $reg = New-HMTestReg $script:Sid '%SystemDrive%\Users\max'
            $b = New-HMTestBackup $script:Sid "$env:SystemDrive\Users\max" $reg
            Test-HMProfileBackup $b $script:Json $script:Bd "$env:SystemDrive\Users" | Should -BeNullOrEmpty
        }
        It 'Entra-ID-SID ist gueltig' {
            $sid = 'S-1-12-1-111-222-333-444'
            $reg = New-HMTestReg $sid "$env:SystemDrive\Users\eva"
            $b = New-HMTestBackup $sid "$env:SystemDrive\Users\eva" $reg
            Test-HMProfileBackup $b (Join-Path $script:Bd "Profil_$($sid)_20261010_120000.json") $script:Bd "$env:SystemDrive\Users" | Should -BeNullOrEmpty
        }
        It 'lehnt Faelschungen ab' {
            $reg = New-HMTestReg $script:Sid "$env:SystemDrive\Users\max"
            $ok = New-HMTestBackup $script:Sid "$env:SystemDrive\Users\max" $reg
            $pd = "$env:SystemDrive\Users"
            # SID-Format
            Test-HMProfileBackup ([pscustomobject]@{ Sid = '..\..\x'; Path = $ok.Path; AltPath = $ok.AltPath; Reg = $reg }) $script:Json $script:Bd $pd | Should -Match 'SID'
            # Dateiname passt nicht zur SID
            Test-HMProfileBackup $ok (Join-Path $script:Bd 'Profil_S-1-5-21-9-9-9-9_20261010_120000.json') $script:Bd $pd | Should -Match 'Dateiname'
            # Profil ausserhalb des Profilverzeichnisses
            Test-HMProfileBackup ([pscustomobject]@{ Sid = $script:Sid; Path = "$env:ProgramData\boese"; AltPath = "$env:ProgramData\boese.alt_20261010_120000"; Reg = $reg }) $script:Json $script:Bd $pd | Should -Match 'nicht direkt unter'
            # gesicherter Ordner frei gewaehlt
            Test-HMProfileBackup ([pscustomobject]@{ Sid = $script:Sid; Path = $ok.Path; AltPath = "$env:SystemDrive\Temp\x"; Reg = $reg }) $script:Json $script:Bd $pd | Should -Match 'gesicherter Ordner'
            # .reg von woanders
            $fremd = Join-Path $TestDrive "ProfileList_$($script:Sid)_20261010_120000.reg"; Copy-Item $reg $fremd
            Test-HMProfileBackup ([pscustomobject]@{ Sid = $script:Sid; Path = $ok.Path; AltPath = $ok.AltPath; Reg = $fremd }) $script:Json $script:Bd $pd | Should -Match 'stammt nicht'
            # .reg mit fremdem Schluessel
            $reg2 = New-HMTestReg $script:Sid "$env:SystemDrive\Users\max" 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
            Test-HMProfileBackup $ok $script:Json $script:Bd $pd | Should -Match 'andere Registry'
            # .reg zeigt auf einen anderen Ordner
            $reg3 = New-HMTestReg $script:Sid "$env:SystemDrive\Users\angreifer"
            Test-HMProfileBackup $ok $script:Json $script:Bd $pd | Should -Match 'anderen Ordner'
        }
    }
}

Describe 'Aufbewahrung, Backup-Ordner und Platte einrichten (Code-Pruefung H1, H2, M1, N1)' {
    BeforeAll {
        # einzelne Funktionen aus Dateien laden, die sonst die Oberflaeche brauchen (direkt hier, damit sie in den Tests sichtbar sind)
        $want = @(
            @('Functions\UI-Quality.ps1', @('Get-HMBackupDate', 'Get-HMRetentionCandidates', 'Test-HMBackupUsable', 'Format-HMBackupStatus')),
            @('Functions\Migration-Engine.ps1', @('Remove-HMBackupFolder', 'Get-HMBackupList'))
        )
        foreach ($w in $want) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Root $w[0]), [ref]$null, [ref]$null)
            foreach ($n in $w[1]) {
                $f = @($ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $n }, $true))[0]
                if (-not $f) { throw "Funktion $n fehlt in $($w[0])" }
                . ([scriptblock]::Create($f.Extent.Text))
            }
        }
        function New-HMTestBk([int]$DaysAgo, [string]$Status) {
            [pscustomobject]@{ Name = "B$DaysAgo"; Computer = 'PC1'; Sid = 'S-1-5-21-1-2-3-1001'; User = 'max'; Legacy = $false; Status = $Status; Path = "X:\B$DaysAgo"
                Created = (Get-Date).AddDays(-$DaysAgo).ToString('yyyy-MM-dd HH:mm:ss') }
        }
    }
    It 'H2: defekte neue Backups verdraengen das einzige gute nicht' {
        $l = @((New-HMTestBk 1 'Error'), (New-HMTestBk 2 'Running'), (New-HMTestBk 3 'Cancelled'), (New-HMTestBk 9 'OK'))
        @(Get-HMRetentionCandidates -Backups $l -Days 0 -Keep 2).Count | Should -Be 0
    }
    It 'M1: neueste N brauchbare bleiben, defekte nur mit neuerem brauchbaren, laufende nie' {
        $l = @((New-HMTestBk 1 'OK'), (New-HMTestBk 2 'Error'), (New-HMTestBk 3 'Cancelled'), (New-HMTestBk 4 'Running'), (New-HMTestBk 5 'OK'), (New-HMTestBk 6 'Warning'), (New-HMTestBk 7 'OK'))
        $c = @(Get-HMRetentionCandidates -Backups $l -Days 0 -Keep 3)
        @($c | ForEach-Object { $_.Backup.Name }) | Sort-Object | Should -Be @('B2', 'B3', 'B7')
        @($c | Where-Object { $_.Backup.Name -eq 'B7' })[0].Rank | Should -Be 4
    }
    It 'das neueste brauchbare Backup wird nie vorgeschlagen (auch Keep 0 + Tage)' {
        $l = @((New-HMTestBk 40 'OK'), (New-HMTestBk 50 'OK'))
        @(Get-HMRetentionCandidates -Backups $l -Days 30 -Keep 0 | ForEach-Object { $_.Backup.Name }) | Should -Be @('B50')
    }
    It 'N1: Backup-Ordner als Junction - nur der Link wird entfernt, Ziel bleibt; Liste ignoriert ihn' {
        $root = Join-Path $TestDrive 'BACKUPS'; New-Item -ItemType Directory -Path $root -Force | Out-Null
        $target = Join-Path $TestDrive 'Fremd'; New-Item -ItemType Directory -Path $target -Force | Out-Null
        '{ "Status": "OK" }' | Set-Content (Join-Path $target 'manifest.json'); 'wichtig' | Set-Content (Join-Path $target 'daten.txt')
        $link = Join-Path $root 'PC1_max_20260101_120000'
        cmd /c mklink /J "$link" "$target" | Out-Null
        Test-Path -LiteralPath $link | Should -BeTrue
        @(Get-HMBackupList -Root $root -Modules @()).Count | Should -Be 0
        Remove-HMBackupFolder $link | Should -Be 'OK'
        Test-Path -LiteralPath $link | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $target 'daten.txt') | Should -BeTrue
    }
    Context 'H1: Platte einrichten prueft direkt vor dem Loeschen' {
        BeforeAll {
            $script:Disk = [pscustomobject]@{ Number = 3; UniqueId = 'USBSTOR\A1'; SerialNumber = 'SN-A'; Size = 1000GB; FriendlyName = 'Platte A'; BusType = 'USB'; IsBoot = $false; IsSystem = $false; IsOffline = $false; IsReadOnly = $false; PartitionStyle = 'GPT' }
            $script:Id = Get-HMSbDiskIdentity $script:Disk
        }
        It 'ohne Merkmale: Abbruch' {
            { Initialize-HMSbDisk -Number 3 -Label 'TEST-1' } | Should -Throw '*nicht eindeutig*'
        }
        It 'andere Platte unter derselben Nummer: Abbruch, nichts geloescht' {
            Mock Get-Disk { [pscustomobject]@{ Number = 3; UniqueId = 'USBSTOR\B2'; SerialNumber = 'SN-B'; Size = 2000GB; FriendlyName = 'Platte B'; BusType = 'USB'; IsBoot = $false; IsSystem = $false; IsOffline = $false; IsReadOnly = $false; PartitionStyle = 'GPT' } }
            Mock Clear-Disk { }
            { Initialize-HMSbDisk -Number 3 -Label 'TEST-1' -ExpectId $script:Id } | Should -Throw '*andere Platte*'
            Should -Invoke Clear-Disk -Times 0
        }
        It 'VM-Dateien auf der Platte: Abbruch, nichts geloescht' {
            Mock Get-Disk { $script:Disk }
            Mock Get-HMSbVmDiskNumbers { 3 }
            Mock Clear-Disk { }
            { Initialize-HMSbDisk -Number 3 -Label 'TEST-1' -ExpectId $script:Id } | Should -Throw '*Hyper-V*'
            Should -Invoke Clear-Disk -Times 0
        }
    }
}

Describe 'Fortlaufendes Backup: an der Quelle geloeschte Dateien beiseitelegen' {
    BeforeAll {
        . (Join-Path $script:Root 'Functions\Migration-Engine.ps1')
        function New-HMTestFile([string]$Path, [string]$Text = 'x') {
            $d = Split-Path $Path -Parent; if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
            [System.IO.File]::WriteAllText($Path, $Text)
        }
    }
    It 'Robocopy-Zusammenfassung: Ordner-Extras deutsch und englisch' {
        $de = (Get-HMRobocopySummary "   Verzeich.:         3         1         2         0         0         4`r`n    Dateien:        10         2         8         0         0         5")
        $de.HaveDirs | Should -BeTrue; $de.DirsExtra | Should -Be 4; $de.FilesExtra | Should -Be 5
        $en = (Get-HMRobocopySummary "    Dirs :         3         1         2         0         0         2`r`n   Files :        10         2         8         0         0         0")
        $en.HaveDirs | Should -BeTrue; $en.DirsExtra | Should -Be 2
    }
    It 'verschiebt nur sicher geloeschte Dateien; Ausgeschlossenes, Cloud-Ordner und Vorhandenes bleiben' {
        $src = Join-Path $TestDrive 'Quelle'; $bk = Join-Path $TestDrive 'BACKUPS\PC_max_1'; $dst = Join-Path $bk 'Dokumente\Eigene'
        New-HMTestFile "$src\bleibt.txt"; New-HMTestFile "$src\sub\bleibt2.txt"; New-HMTestFile "$src\geaendert.txt" 'neu'
        New-HMTestFile "$src\OneDrive\cloud.txt"
        # Backup-Stand (aelter): alles von damals + inzwischen an der Quelle geloeschte Dateien
        New-HMTestFile "$dst\bleibt.txt"; New-HMTestFile "$dst\sub\bleibt2.txt"; New-HMTestFile "$dst\geaendert.txt" 'alt'
        New-HMTestFile "$dst\weg.txt"; New-HMTestFile "$dst\sub\weg2.txt"; New-HMTestFile "$dst\ordnerweg\a.txt"; New-HMTestFile "$dst\ordnerweg\tief\b.txt"
        New-HMTestFile "$dst\Temp\ausgeschlossen.txt"      # per Ordnername ausgeschlossen
        New-HMTestFile "$dst\alt.tmp"                      # per Dateimuster ausgeschlossen
        New-HMTestFile "$dst\OneDrive\nurimbackup.txt"     # Cloud-Ordner (voller Quellpfad ausgeschlossen)
        $ctx = @{ BackupPath = $bk }
        $r = Move-HMDeletedFromBackup -Ctx $ctx -Job $null -Src $src -Dst $dst -XD @('Temp', "$src\OneDrive") -XF @('*.tmp')
        $r.Error | Should -BeNullOrEmpty
        $r.Moved | Should -Be 4
        $g = $ctx.DeletedDir
        $g | Should -Match '_GELOESCHT\\\d{8}_\d{6}$'
        foreach ($x in 'weg.txt', 'sub\weg2.txt', 'ordnerweg\a.txt', 'ordnerweg\tief\b.txt') {
            Test-Path -LiteralPath "$dst\$x" | Should -BeFalse
            Test-Path -LiteralPath "$g\Dokumente\Eigene\$x" | Should -BeTrue
        }
        Test-Path -LiteralPath "$dst\ordnerweg" | Should -BeFalse   # leer gewordene Ordner werden entfernt
        foreach ($x in 'bleibt.txt', 'sub\bleibt2.txt', 'geaendert.txt', 'Temp\ausgeschlossen.txt', 'alt.tmp', 'OneDrive\nurimbackup.txt') { Test-Path -LiteralPath "$dst\$x" | Should -BeTrue }
        # Suche/Katalog sehen _GELOESCHT nicht als Teil des Backups
        . (Join-Path $script:Root 'Functions\Migration-Quality.ps1')
        @(Get-HMBackupFiles $bk | Where-Object { $_.Rel -like '_GELOESCHT*' }).Count | Should -Be 0
    }
    It 'Quelle nicht erreichbar: nichts wird verschoben' {
        $bk = Join-Path $TestDrive 'BACKUPS\PC_max_2'; $dst = Join-Path $bk 'Dokumente\Eigene'
        New-HMTestFile "$dst\datei.txt"
        $ctx = @{ BackupPath = $bk }
        $r = Move-HMDeletedFromBackup -Ctx $ctx -Job $null -Src (Join-Path $TestDrive 'gibtsnicht') -Dst $dst
        $r.Moved | Should -Be 0
        Test-Path -LiteralPath "$dst\datei.txt" | Should -BeTrue
    }
    It 'entfernt beiseitegelegte Laeufe erst nach der eingestellten Zahl von Tagen' {
        $bk = Join-Path $TestDrive 'BACKUPS\PC_max_3'
        New-HMTestFile "$bk\_GELOESCHT\20200101_120000\Mod\alt.txt"
        $neu = (Get-Date).ToString('yyyyMMdd_HHmmss'); New-HMTestFile "$bk\_GELOESCHT\$neu\Mod\neu.txt"
        (Remove-HMDeletedExpired $bk 0).Removed | Should -Be 0
        (Remove-HMDeletedExpired $bk 90).Removed | Should -Be 1
        Test-Path -LiteralPath "$bk\_GELOESCHT\20200101_120000" | Should -BeFalse
        Test-Path -LiteralPath "$bk\_GELOESCHT\$neu\Mod\neu.txt" | Should -BeTrue
    }
}

Describe 'PS 5.1: JSON-Arrays aus ConvertFrom-Json' {
    It 'Zuweisen und dann @() liefert jedes Element einzeln (auch unter Windows PowerShell 5.1)' {
        $j = '[{"Index":1,"Path":"C:\\a"},{"Index":2,"Path":"C:\\b"}]' | ConvertFrom-Json
        @($j).Count | Should -Be 2
        @($j)[1].Index | Should -Be 2
    }
    It 'kein Code nutzt @(... | ConvertFrom-Json) oder verarbeitet das Array direkt im Pipeline-Schritt' {
        # unter PS 5.1 kommt ein JSON-Array als EIN Objekt aus ConvertFrom-Json - @() und ForEach-Object sehen dann nur ein Element
        $bad = @()
        foreach ($f in @(Get-ChildItem -Path (Join-Path $script:Root 'Functions'), $script:Root -Filter *.ps1 -File)) {
            $n = 0
            foreach ($l in (Get-Content -LiteralPath $f.FullName -Encoding UTF8)) {
                $n++
                if ($l -match '^\s*#') { continue }
                if ($l -match '@\([^()]*\|\s*ConvertFrom-Json\s*\)' -or ($l -match 'ConvertFrom-Json\s*\|\s*(ForEach-Object|Where-Object|%|\?)\s*\{' -and $l -notmatch 'ConvertFrom-Json\s*\|\s*ForEach-Object\s*\{\s*\$_\s*\}')) { $bad += "$($f.Name):$n" }
            }
        }
        $bad | Should -BeNullOrEmpty
    }
}

Describe 'Schutz vor Massenloeschung, Zaehler, Originalort' {
    BeforeAll {
        . (Join-Path $script:Root 'Functions\Migration-Engine.ps1')
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Root 'Functions\Tools-School.ps1'), [ref]$null, [ref]$null)
        $f = @($ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'Get-HMOriginalPath' }, $true))[0]
        . ([scriptblock]::Create($f.Extent.Text))
        function New-HMTestFile([string]$Path, [string]$Text = 'x') {
            $d = Split-Path $Path -Parent; if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
            [System.IO.File]::WriteAllText($Path, $Text)
        }
    }
    It 'fehlen ungewoehnlich viele Dateien, wird nichts beiseitegelegt (Massenloeschung)' {
        $src = Join-Path $TestDrive 'Q1'; $bk = Join-Path $TestDrive 'B1'; $dst = Join-Path $bk 'Dokumente\Eigene'
        1..100 | ForEach-Object { New-HMTestFile "$dst\d$_.docx" }
        1..30 | ForEach-Object { New-HMTestFile "$src\d$_.docx" }
        $ctx = @{ BackupPath = $bk }
        $r = Move-HMDeletedFromBackup -Ctx $ctx -Job $null -Src $src -Dst $dst -TotalFiles 30 -MassPercent 20 -MassMin 50
        $r.Mass | Should -BeTrue
        $r.Count | Should -Be 70
        $r.Moved | Should -Be 0
        @(Get-ChildItem -LiteralPath $dst -File).Count | Should -Be 100
        Test-Path -LiteralPath (Join-Path $bk '_GELOESCHT') | Should -BeFalse
        # Schutz aus (0 %): wird beiseitegelegt
        $r2 = Move-HMDeletedFromBackup -Ctx $ctx -Job $null -Src $src -Dst $dst -TotalFiles 30 -MassPercent 0
        $r2.Moved | Should -Be 70
    }
    It 'zaehlt beiseitegelegte Dateien und schreibt den Zaehler ins manifest.json' {
        $bk = Join-Path $TestDrive 'B2'
        New-HMTestFile "$bk\_GELOESCHT\20261011_120000\Mod\a.txt" 'abc'; New-HMTestFile "$bk\_GELOESCHT\20261011_120000\Mod\b.txt" 'de'
        '{ "Status": "OK", "Modules": [ { "Id": "Mod" } ], "MassDeleteAlert": [ "x" ] }' | Set-Content -LiteralPath "$bk\manifest.json" -Encoding UTF8
        $i = Get-HMDeletedInfo $bk
        $i.Files | Should -Be 2; $i.Bytes | Should -Be 5
        Update-HMManifestDeleted $bk -ClearAlert
        $m = Get-Content -LiteralPath "$bk\manifest.json" -Raw | ConvertFrom-Json
        [int]$m.Deleted.Files | Should -Be 2
        $m.Status | Should -Be 'OK'
        $m.PSObject.Properties['MassDeleteAlert'] | Should -BeNullOrEmpty
    }
    It 'findet den Originalort (normale Eintraege, beiseitegelegte, Zusaetzliche Ordner)' {
        $bk = Join-Path $TestDrive 'B3'
        New-Item -ItemType Directory -Path "$bk\ExtraFolders" -Force | Out-Null
        $fj = '[{"Index":1,"Path":"D:\\Projekte"},{"Index":2,"Path":"E:\\Daten"}]'
        [System.IO.File]::WriteAllText("$bk\ExtraFolders\folders.json", $fj)
        $b = [pscustomobject]@{ Path = $bk; ProfilePath = 'C:\Users\max'; Manifest = [pscustomobject]@{ Modules = @(
            [pscustomobject]@{ Id = 'Dokumente'; Items = @([pscustomobject]@{ Name = 'DOCS'; Source = 'C:\Users\max\Documents' }) },
            [pscustomobject]@{ Id = 'ExtraFolders'; Items = @([pscustomobject]@{ Name = 'ExtraFolders'; Source = '' }) }) } }
        Get-HMOriginalPath $b 'Dokumente\DOCS\Brief\a.docx' | Should -Be 'C:\Users\max\Documents\Brief\a.docx'
        Get-HMOriginalPath $b '_GELOESCHT\20261011_120000\Dokumente\DOCS\b.docx' | Should -Be 'C:\Users\max\Documents\b.docx'
        Get-HMOriginalPath $b 'ExtraFolders\FOLDER2\x\y.txt' | Should -Be 'E:\Daten\x\y.txt'
        Get-HMOriginalPath $b 'Registry\HKCU.reg' | Should -BeNullOrEmpty
    }
}

Describe 'Startseite Status und Hinweise beim Start' {
    BeforeAll {
        . (Join-Path $script:Root 'Functions\UI-Status.ps1')
        $script:Now = [datetime]'2026-10-20 10:00'
        function D([int]$Ago) { $script:Now.AddDays(-$Ago).ToString('yyyy-MM-dd HH:mm') }
        function Row($Name, $Def, $Zustand = 'bereit') { [pscustomobject]@{ Name = $Name; Wann = 'taeglich 12:00'; Last = "$($Def.LastRun)"; Result = ''; Next = ''; Zustand = $Zustand; Def = $Def } }
    }
    It 'Zeitplaene: ohne Erfolg seit X Tagen, fehlgeschlagen, fehlende Aufgabe, alter Zeitplan ohne LastSuccess' {
        $rows = @(
            (Row 'Alt'    ([pscustomobject]@{ LastRun = (D 10); LastStatus = 'Error'; LastSuccess = (D 10) })),
            (Row 'Gut'    ([pscustomobject]@{ LastRun = (D 1); LastStatus = 'OK'; LastSuccess = (D 1) })),
            (Row 'Fehler' ([pscustomobject]@{ LastRun = (D 0); LastStatus = 'Error'; LastSuccess = (D 2) })),
            (Row 'Weg'    ([pscustomobject]@{ LastRun = (D 0); LastStatus = 'OK' }) 'fehlt'),
            (Row 'Frueher' ([pscustomobject]@{ LastRun = (D 3); LastStatus = 'Warning' })))
        $s = Get-HMStatusData -BsRows $rows -Now $script:Now -StaleDays 8
        ($s.Schedules | Where-Object Name -eq 'Alt').Level | Should -Be 'Error'
        ($s.Schedules | Where-Object Name -eq 'Gut').Level | Should -Be 'OK'
        ($s.Schedules | Where-Object Name -eq 'Fehler').Note | Should -Match 'fehlgeschlagen'
        ($s.Schedules | Where-Object Name -eq 'Weg').Note | Should -Match 'fehlt'
        ($s.Schedules | Where-Object Name -eq 'Frueher').Level | Should -Be 'OK'
        @($s.Warnings | Where-Object { $_.Text -match "'Alt'" }).Count | Should -Be 1
        (@($s.Warnings | Where-Object { $_.Text -match "'Alt'" })[0].Text) | Should -Match 'fehlgeschlagen|kein erfolgreicher'
    }
    It 'Server-Backup: Platte seit X Tagen nicht gesichert, Archiv faellig' {
        $p = [pscustomobject]@{ Name = 'Gym'; DiskPrefix = 'HUMIG-GYM'; Disks = 2; WarnDays = 14; ArchiveDisks = 1; ArchiveDays = 30 }
        $h = @([pscustomobject]@{ Date = (D 1); Profile = 'Gym'; Disk = 'HUMIG-GYM-1'; Status = 'OK' }, [pscustomobject]@{ Date = (D 20); Profile = 'Gym'; Disk = 'HUMIG-GYM-2'; Status = 'OK' }, [pscustomobject]@{ Date = (D 40); Profile = 'Gym'; Disk = 'HUMIG-GYM-A1'; Status = 'OK' })
        $s = Get-HMStatusData -SbProfiles @($p) -SbHistory $h -Now $script:Now
        $t = @($s.Warnings | ForEach-Object { $_.Text }) -join ' | '
        $t | Should -Match 'Platte HUMIG-GYM-2 seit 20 Tagen'
        $t | Should -Match 'Archiv-Sicherung faellig'
        $t | Should -Not -Match 'HUMIG-GYM-1 seit'
        $s.Server[0].Level | Should -Be 'OK'
    }
    It 'Backups: neuestes je PC/Benutzer, Massenloeschung als Hinweis; App-Updates mit Fehlern' {
        $b = @(
            [pscustomobject]@{ Computer = 'PC1'; Sid = 'S-1'; User = 'max'; Created = (D 5); Status = 'OK'; SizeBytes = 10; Manifest = $null },
            [pscustomobject]@{ Computer = 'PC1'; Sid = 'S-1'; User = 'max'; Created = (D 1); Status = 'Warning'; SizeBytes = 10; Manifest = [pscustomobject]@{ MassDeleteAlert = @('x') } },
            [pscustomobject]@{ Computer = 'PC2'; Sid = 'S-2'; User = 'eva'; Created = (D 2); Status = 'OK'; SizeBytes = 10; Manifest = $null })
        $a = @([pscustomobject]@{ Date = (D 1); Computer = 'PC1'; Name = '7-Zip'; Status = 'OK' }, [pscustomobject]@{ Date = (D 2); Computer = 'PC1'; Name = 'VLC'; Status = 'Error' }, [pscustomobject]@{ Date = (D 30); Computer = 'PC3'; Name = 'Alt'; Status = 'Error' })
        $s = Get-HMStatusData -Backups $b -AuHistory $a -Now $script:Now
        @($s.Backups).Count | Should -Be 2
        ($s.Backups | Where-Object Computer -eq 'PC1').Mass | Should -BeTrue
        @($s.Warnings | Where-Object { $_.Text -match 'Verschluesselungstrojaner' }).Count | Should -Be 1
        @($s.Apps).Count | Should -Be 1
        $s.Apps[0].Failed | Should -Be 1
        $s.Apps[0].FailedNames | Should -Contain 'VLC'
    }
}

Describe 'Restore: fehlende Programme zuerst, Programm-Module ohne Programm auslassen' {
    BeforeAll {
        . (Join-Path $script:Root 'Functions\Migration-Quality.ps1')
        . (Join-Path $script:Root 'Functions\UI-Apps.ps1')
        $script:Cat = @(
            [pscustomobject]@{ Id = 'App_KeePass'; Name = 'KeePass'; Detect = '^KeePass'; Package = 'keepass'; Items = @([pscustomobject]@{ Type = 'Folder'; Path = '{APPDATA}\KeePass' }) },
            [pscustomobject]@{ Id = 'App_Vlc'; Name = 'VLC'; Detect = '^VLC media player'; WingetId = 'VideoLAN.VLC'; Items = @([pscustomobject]@{ Type = 'Folder'; Path = '{APPDATA}\vlc' }) },
            [pscustomobject]@{ Id = 'App_Ohne'; Name = 'Ohne'; Detect = ''; Items = @([pscustomobject]@{ Type = 'Folder'; Path = '{APPDATA}\x' }) })
    }
    It 'Plan: Paket der Softwareverteilung vor WinGet, schon installierte (auch andere Version) nicht' {
        $src = @([pscustomobject]@{ Name = 'KeePass Password Safe 2.57'; Version = '2.57' }, [pscustomobject]@{ Name = 'VLC media player'; Version = '3.0' }, [pscustomobject]@{ Name = 'Notepad++ (64-bit x64)'; Version = '8.6' }, [pscustomobject]@{ Name = 'Unbekannt Tool'; Version = '1' })
        $pk = @([pscustomobject]@{ Id = 'keepass-2.57'; Settings = [pscustomobject]@{ Name = 'KeePass'; DetectName = '' } })
        $p = Get-HMMissingAppPlan -Src $src -Have @('Notepad++ (64-bit x64)') -Packages $pk -Catalog $script:Cat
        @($p.Rows).Count | Should -Be 3
        $p.Packages.ContainsKey('keepass-2.57') | Should -BeTrue
        $p.Winget.ContainsKey('winget:VideoLAN.VLC') | Should -BeTrue
        $p.NoPkg | Should -Be 1
        $p.Installable | Should -Be 2
    }
    It 'Luecke: Programm-Module, deren Programm am Ziel fehlt; ohne Erkennung nie auslassen' {
        $mods = @([pscustomobject]@{ Id = 'App_KeePass'; Catalog = $true; AppId = 'App_KeePass' }, [pscustomobject]@{ Id = 'App_Vlc'; Catalog = $true; AppId = 'App_Vlc' }, [pscustomobject]@{ Id = 'App_Ohne'; Catalog = $true; AppId = 'App_Ohne' }, [pscustomobject]@{ Id = 'Desktop'; Scope = 'User' })
        $g = @(Get-HMRestoreAppGap -Modules $mods -Software @([pscustomobject]@{ Name = 'VLC media player'; Version = '3.0' }) -Catalog $script:Cat)
        @($g).Count | Should -Be 1
        $g[0].Id | Should -Be 'App_KeePass'
        $g[0].Name | Should -Be 'KeePass'
    }
}

Describe 'Kontrolle nach dem Restore (fehlende Dateien am Ziel)' {
    BeforeAll {
        . (Join-Path $script:Root 'Functions\Migration-Engine.ps1')
        function New-HMTestFile([string]$Path) { $d = Split-Path $Path -Parent; if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }; [System.IO.File]::WriteAllText($Path, 'x') }
    }
    It 'findet Dateien, die im Backup liegen, am Ziel aber fehlen - Zielpfade in der Liste' {
        $src = Join-Path $TestDrive 'BK\Dokumente'; $dst = Join-Path $TestDrive 'Ziel\Dokumente'
        New-HMTestFile "$src\a.txt"; New-HMTestFile "$src\sub\b.txt"; New-HMTestFile "$src\c.txt"
        New-HMTestFile "$dst\a.txt"; New-HMTestFile "$dst\extra.txt"
        $ctx = @{ MissingAfter = (New-Object System.Collections.Generic.List[string]) }
        $r = Test-HMRestoredItem -Ctx $ctx -Job $null -Src $src -Dst $dst -DstLocal 'C:\Users\max\Documents'
        $r.Error | Should -BeNullOrEmpty
        $r.Missing | Should -Be 2
        $ctx.MissingAfter | Should -Contain 'C:\Users\max\Documents\c.txt'
        $ctx.MissingAfter | Should -Contain 'C:\Users\max\Documents\sub\b.txt'
    }
}

Describe 'Plattenzustand (SMART) der Server-Backup-Platten' {
    It 'Bewertung: gut, ohne Detailwerte, Warnung, Defekt, steigende Fehler' {
        (Get-HMSbHealthVerdict ([pscustomobject]@{ Health = 'Healthy'; Counters = $true; Temperature = 35; PowerOnHours = 1200 })).Level | Should -Be 'OK'
        $v = Get-HMSbHealthVerdict ([pscustomobject]@{ Health = 'Healthy'; Counters = $false })
        $v.Level | Should -Be 'OK'; $v.Text | Should -Match 'keine Detailwerte'
        (Get-HMSbHealthVerdict ([pscustomobject]@{ Health = 'Unknown'; Counters = $false })).Level | Should -Be 'Unknown'
        (Get-HMSbHealthVerdict ([pscustomobject]@{ Health = 'Warning' })).Level | Should -Be 'Warning'
        (Get-HMSbHealthVerdict ([pscustomobject]@{ Health = 'Unhealthy' })).Level | Should -Be 'Error'
        (Get-HMSbHealthVerdict ([pscustomobject]@{ Health = 'Healthy'; Counters = $true; ReadErrorsUncorrected = 3 })).Level | Should -Be 'Warning'
        (Get-HMSbHealthVerdict ([pscustomobject]@{ Health = 'Healthy'; Counters = $true; ReadErrorsUncorrected = 5 }) ([pscustomobject]@{ ReadErrorsUncorrected = 3 })).Level | Should -Be 'Error'
        (Get-HMSbHealthVerdict ([pscustomobject]@{ Health = 'Healthy'; Counters = $true; Temperature = 62 })).Text | Should -Match 'zu warm'
        ConvertTo-HMSbHealthText 2 | Should -Be 'Unhealthy'
    }
    It 'Messwerte je Platte merken (hoechstens 30) und letzte Messung bewerten' {
        $f = Join-Path $TestDrive 'ServerBackup\disk-health.json'
        foreach ($i in 1..32) { Add-HMSbHealthStore $f 'HUMIG-GYM-1' ([pscustomobject]@{ Date = "2026-10-$('{0:D2}' -f [Math]::Min(28, $i)) 10:00"; Health = 'Healthy'; Counters = $true; ReadErrorsUncorrected = $(if ($i -eq 32) { 1 } else { 0 }) }) }
        Add-HMSbHealthStore $f 'HUMIG-GYM-2' ([pscustomobject]@{ Date = '2026-10-01 10:00'; Health = 'Unhealthy' })
        $st = Read-HMSbHealthStore $f
        @($st['HUMIG-GYM-1']).Count | Should -Be 30
        $sum = Get-HMSbHealthSummary $st
        $sum['HUMIG-GYM-1'].Verdict.Level | Should -Be 'Error'   # Fehler gestiegen (0 -> 1)
        $sum['HUMIG-GYM-2'].Verdict.Level | Should -Be 'Error'
    }
    It 'Startseite: Plattenzustand als Hinweis und in der Stufe' {
        . (Join-Path $script:Root 'Functions\UI-Status.ps1')
        $now = [datetime]'2026-10-20 10:00'
        $p = [pscustomobject]@{ Name = 'Gym'; DiskPrefix = 'HUMIG-GYM'; Disks = 2; WarnDays = 14; ArchiveDisks = 0; ArchiveDays = 30 }
        $h = @([pscustomobject]@{ Date = '2026-10-19 10:00'; Profile = 'Gym'; Disk = 'HUMIG-GYM-1'; Status = 'OK' }, [pscustomobject]@{ Date = '2026-10-18 10:00'; Profile = 'Gym'; Disk = 'HUMIG-GYM-2'; Status = 'OK' })
        $hs = @{ 'HUMIG-GYM-2' = [pscustomobject]@{ Last = $null; Verdict = [pscustomobject]@{ Level = 'Warning'; Text = '3 nicht behebbare Lese-/Schreibfehler'; Detail = '' } } }
        $s = Get-HMStatusData -SbProfiles @($p) -SbHistory $h -Now $now -SbHealth $hs
        $s.Server[0].Level | Should -Be 'Warning'
        @($s.Warnings | Where-Object { $_.Text -match 'HUMIG-GYM-2 - 3 nicht behebbare' }).Count | Should -Be 1
        ($s.Server[0].Disks | Where-Object Label -eq 'HUMIG-GYM-2').Health | Should -Be 'Warning'
    }
}

Describe 'Fortlaufendes Backup: herausgenommene Ordner und neu ausgeschlossene Pfade' {
    BeforeAll {
        . (Join-Path $script:Root 'Functions\Migration-Engine.ps1')
        function New-HMTestFile([string]$Path) { $d = Split-Path $Path -Parent; if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }; [System.IO.File]::WriteAllText($Path, 'x') }
    }
    It 'Zusaetzliche Ordner behalten ihre Nummer; neue bekommen eine nie benutzte, herausgenommene werden erkannt' {
        $bk = Join-Path $TestDrive 'BK1'; $d = Join-Path $bk 'ExtraFolders'; New-Item -ItemType Directory -Path $d -Force | Out-Null
        '[{"Index":1,"Path":"C:\\A"},{"Index":2,"Path":"C:\\B"},{"Index":3,"Path":"C:\\C\\"}]' | Set-Content -LiteralPath (Join-Path $d 'folders.json') -Encoding UTF8
        '[{"Index":4,"Path":"C:\\D","Removed":"2026-10-01 10:00"}]' | Set-Content -LiteralPath (Join-Path $d 'folders-alt.json') -Encoding UTF8
        $m = Get-HMExtraFolderMap $bk @('C:\A', 'c:\c', 'C:\E')
        ($m.Map | Where-Object Path -eq 'C:\A').Index | Should -Be 1
        ($m.Map | Where-Object Path -eq 'c:\c').Index | Should -Be 3
        ($m.Map | Where-Object Path -eq 'C:\E').Index | Should -Be 5
        @($m.Removed).Count | Should -Be 1
        $m.Removed[0].Path | Should -Be 'C:\B'
        # ohne vorhandenes Backup: 1..n
        $m2 = Get-HMExtraFolderMap (Join-Path $TestDrive 'leer') @('C:\X', 'C:\Y')
        @($m2.Map | ForEach-Object { $_.Index }) -join ',' | Should -Be '1,2'
    }
    It 'neu ausgeschlossener Pfad wird beiseitegelegt, schon frueher ausgeschlossener und unbekannte Vorgabe bleiben' {
        $bk = Join-Path $TestDrive 'BK2'; $dst = Join-Path $bk 'Profil'
        New-HMTestFile "$dst\Gross\a.bin"; New-HMTestFile "$dst\Gross\sub\b.bin"; New-HMTestFile "$dst\Alt\x.txt"; New-HMTestFile "$dst\bleibt.txt"
        $ctx = @{ BackupPath = $bk; PrevExcludePaths = @('C:\Users\max\Alt'); Options = @{ ExcludePaths = @('C:\Users\max\Alt', 'C:\Users\max\Gross\') } }
        $r = Move-HMNewlyExcluded $ctx 'C:\Users\max' $dst
        $r.Files | Should -Be 2
        Test-Path -LiteralPath "$dst\Gross" | Should -BeFalse
        Test-Path -LiteralPath "$($ctx.DeletedDir)\Profil\Gross\sub\b.bin" | Should -BeTrue
        Test-Path -LiteralPath "$dst\Alt\x.txt" | Should -BeTrue
        Test-Path -LiteralPath "$dst\bleibt.txt" | Should -BeTrue
        $ctx2 = @{ BackupPath = $bk; PrevExcludePaths = $null; Options = @{ ExcludePaths = @('C:\Users\max\Alt') } }
        (Move-HMNewlyExcluded $ctx2 'C:\Users\max' $dst).Files | Should -Be 0
        Test-Path -LiteralPath "$dst\Alt\x.txt" | Should -BeTrue
    }
}

Describe 'Browser vor Backup/Restore schliessen' {
    BeforeAll { . (Join-Path $script:Root 'Functions\Migration-Engine.ps1') }
    It 'Edge, Chrome, Firefox fragen nach dem Schliessen; ohne Abfrage wird trotzdem kopiert' {
        $j = Get-Content -LiteralPath (Join-Path $script:Root 'Config\modules.default.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $mods = @($j.Modules)
        foreach ($x in @(@('Edge', 'msedge'), @('Chrome', 'chrome'), @('Firefox', 'firefox'))) {
            $m = @($mods | Where-Object { $_.Id -eq $x[0] })[0]
            @($m.CloseProcess) | Should -Contain $x[1]
            $m.CloseDefault | Should -Be 'Copy'
        }
    }
    It 'Entscheidung: ohne Abfrage kopieren (CloseDefault), Ueberspringen und ohne CloseDefault auslassen' {
        Mock Get-HMRunningProcs { @([pscustomobject]@{ Name = 'msedge'; Id = 42 }) }
        $job = @{ Log = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue)); Cancel = $false }
        $m = [pscustomobject]@{ Id = 'Edge'; Name = 'Edge-Profil'; CloseProcess = @('msedge'); CloseDefault = 'Copy' }
        $r = Enter-HMModule @{ ProcDecisions = @{}; UserSid = 'S-1-5-21-1' } $job $m @{} 'Backup'
        $r.Skip | Should -BeFalse
        $r.ProcAction | Should -Be 'trotzdem kopiert'
        # Browser trotzdem kopiert: nur Hinweis, gesperrte Dateien kein Fehler
        $r.LockedHint | Should -BeTrue
        @($r.Warn).Count | Should -Be 0
        @($r.Info).Count | Should -Be 1
        # Restore oder Programm ohne CloseDefault Copy: weiter Warnung
        $rr = Enter-HMModule @{ ProcDecisions = @{}; UserSid = 'S-1-5-21-1' } $job $m @{} 'Restore'
        $rr.LockedHint | Should -BeFalse
        @($rr.Warn).Count | Should -Be 1
        $mo = [pscustomobject]@{ Id = 'Outlook'; Name = 'Outlook'; CloseProcess = @('msedge') }
        $ro = Enter-HMModule @{ ProcDecisions = @{ Outlook = 'Copy' }; UserSid = 'S-1-5-21-1' } $job $mo @{} 'Backup'
        $ro.LockedHint | Should -BeFalse
        @($ro.Warn).Count | Should -Be 1
        $r2 = Enter-HMModule @{ ProcDecisions = @{ Edge = 'Skip' }; UserSid = 'S-1-5-21-1' } $job $m @{} 'Backup'
        $r2.Skip | Should -BeTrue
        $m3 = [pscustomobject]@{ Id = 'App_X'; Name = 'X'; CloseProcess = @('x') }
        (Enter-HMModule @{ ProcDecisions = @{}; UserSid = 'S-1-5-21-1' } $job $m3 @{} 'Backup').Skip | Should -BeTrue
    }
}

Describe 'Protokolle direkt mit dem Browser oeffnen' {
    BeforeAll { . (Join-Path $script:Root 'Functions\UI-Common.ps1') }
    It 'baut die Befehlszeile richtig (Chrome/Edge --single-argument, Firefox mit Anfuehrungszeichen, ohne Platzhalter)' {
        Mock Test-Path { $true }
        Mock Start-Process { $script:LastArgs = "$ArgumentList"; $script:LastExe = "$FilePath" }
        $f = 'E:\HUMig\BACKUPS\a b\Bericht_Backup.html'
        Start-HMCommandWithFile '"C:\Program Files\Google\Chrome\Application\chrome.exe" --single-argument %1' $f | Should -BeTrue
        $script:LastExe | Should -Be 'C:\Program Files\Google\Chrome\Application\chrome.exe'
        $script:LastArgs | Should -Be "--single-argument $f"
        Start-HMCommandWithFile '"C:\Program Files\Mozilla Firefox\firefox.exe" -osint -url "%1"' $f | Should -BeTrue
        $script:LastArgs | Should -Be "-osint -url `"$f`""
        Start-HMCommandWithFile '"C:\x\browser.exe"' $f | Should -BeTrue
        $script:LastArgs | Should -Be "`"$f`""
        Start-HMCommandWithFile '' $f | Should -BeFalse
    }
}

Describe 'Umzugs-Assistent: Stand und Ablauf' {
    BeforeAll {
        function Out-Console { param($m, $l) }
        . (Join-Path $script:Root 'Functions\UI-Wizard.ps1')
        $script:WizFile = Join-Path $TestDrive 'umzug.json'
    }
    It 'speichert den Stand, liest ihn wieder (fortsetzbar) und ignoriert abgeschlossene' {
        $script:WizState = New-HMWizState
        $script:WizState.Source = [pscustomobject]@{ Computer = 'PC-ALT'; Account = 'SCHULE\max'; Folder = 'max'; SID = 'S-1-5-21-1'; NoProfile = $false }
        Set-HMWizDone 1; $script:WizState.Step = 2
        Save-HMWizState
        $r = Read-HMWizState
        $r.Step | Should -Be 2
        @($r.Done) | Should -Contain 1
        $r.Source.Computer | Should -Be 'PC-ALT'
        $script:WizState.Finished = '2026-10-11 12:00'; Save-HMWizState
        Read-HMWizState | Should -BeNullOrEmpty
    }
    It 'Backup und Restore melden ihr Ende: weiter zum naechsten Schritt, nur wenn erwartet' {
        $script:Wiz = $null
        $script:WizState = New-HMWizState; $script:WizState.Step = 3
        $script:WizWaitFor = ''
        Update-HMWizardAfterJob 'Backup' @{ Cancel = $false; Result = [pscustomobject]@{ Status = 'OK' } } 'E:\B\1'
        $script:WizState.Step | Should -Be 3          # nicht vom Assistenten gestartet
        $script:WizWaitFor = 'Backup'
        Update-HMWizardAfterJob 'Backup' @{ Cancel = $false; Result = [pscustomobject]@{ Status = 'Error' } } 'E:\B\1'
        $script:WizState.Step | Should -Be 3          # fehlgeschlagen: bleibt
        $script:WizWaitFor = 'Backup'
        Update-HMWizardAfterJob 'Backup' @{ Cancel = $false; Result = [pscustomobject]@{ Status = 'Warning' } } 'E:\B\2'
        $script:WizState.Step | Should -Be 4
        $script:WizState.BackupPath | Should -Be 'E:\B\2'
        $script:WizState.Step = 5; $script:WizWaitFor = 'Restore'
        Update-HMWizardAfterJob 'Restore' @{ Cancel = $false; Result = [pscustomobject]@{ Status = 'OK'; Report = 'E:\B\2\Bericht_Restore.html' } }
        $script:WizState.Step | Should -Be 6
        $script:WizState.RestoreReport | Should -Be 'E:\B\2\Bericht_Restore.html'
        @($script:WizState.Done) -join ',' | Should -Be '3,5'
    }
}

Describe 'Listen-Rueckgaben (return ,@()) erst zuweisen' {
    It 'Get-HMSbAllHistory / Read-HMSbHistory werden nie direkt in @() oder einer Pipeline verwendet' {
        # die Funktionen geben die Liste als EIN Objekt zurueck - @(Aufruf) bzw. Aufruf | Where-Object sehen nur 1 Element
        $bad = @()
        foreach ($f in @(Get-ChildItem -Path (Join-Path $script:Root 'Functions'), $script:Root -Filter *.ps1 -File)) {
            $n = 0
            foreach ($l in @(Get-Content -LiteralPath $f.FullName -Encoding UTF8)) {
                $n++
                if ($l -match '@\(\s*(Get-HMSbAllHistory|Read-HMSbHistory)\b' -or $l -match '(Get-HMSbAllHistory|Read-HMSbHistory)\b[^|;)]*\|') { $bad += "$($f.Name):$n" }
            }
        }
        $bad | Should -BeNullOrEmpty
    }
    It 'Startseite zaehlt Laeufe aus einer Liste korrekt (Regression Status "noch keine erfolgreiche Sicherung")' {
        . (Join-Path $script:Root 'Functions\UI-Status.ps1')
        function Get-HMTestList { return ,@([pscustomobject]@{ Date = '2026-10-19 10:00'; Profile = 'Gym'; Disk = 'HUMIG-GYM-1'; Status = 'OK' }, [pscustomobject]@{ Date = '2026-10-18 10:00'; Profile = 'Gym'; Disk = 'HUMIG-GYM-2'; Status = 'OK' }) }
        $tmp = Get-HMTestList
        $p = [pscustomobject]@{ Name = 'Gym'; DiskPrefix = 'HUMIG-GYM'; Disks = 2; WarnDays = 14; ArchiveDisks = 0; ArchiveDays = 30 }
        $s = Get-HMStatusData -SbProfiles @($p) -SbHistory @($tmp) -Now ([datetime]'2026-10-20 10:00')
        $s.Server[0].Runs | Should -Be 2
        $s.Server[0].Level | Should -Be 'OK'
    }
}

Describe 'Teams-Benachrichtigung (Workflow-Webhook)' {
    BeforeAll { . (Join-Path $script:Root 'Functions\Core-Notify.ps1') }
    It 'prueft die Adresse: https, keine alte Connector-Adresse' {
        Test-HMTeamsWebhookUrl '' | Should -Not -BeNullOrEmpty
        Test-HMTeamsWebhookUrl 'http://prod-01.westeurope.logic.azure.com/x' | Should -Match 'https'
        Test-HMTeamsWebhookUrl 'https://schule.webhook.office.com/webhookb2/x' | Should -Match 'Connector'
        Test-HMTeamsWebhookUrl 'https://prod-01.westeurope.logic.azure.com:443/workflows/abc/triggers/manual/paths/invoke?sig=x' | Should -BeNullOrEmpty
        Test-HMTeamsWebhookHostKnown 'https://default123.environment.api.powerplatform.com/powerautomate/x' | Should -BeTrue
        Test-HMTeamsWebhookHostKnown 'https://example.org/x' | Should -BeFalse
    }
    It 'Nachricht ist eine Adaptive Card im Format der Workflows-Vorlage' {
        $j = New-HMTeamsPayload -Title 'Server-Backup FEHLGESCHLAGEN' -Lines @('Platte: X-1', '', 'Hinweis: y') -Level 'Error' -Source 'SRV'
        $o = $j | ConvertFrom-Json
        $o.type | Should -Be 'message'
        $a = @($o.attachments)
        $a.Count | Should -Be 1
        $a[0].contentType | Should -Be 'application/vnd.microsoft.card.adaptive'
        $a[0].content.type | Should -Be 'AdaptiveCard'
        $b = @($a[0].content.body)
        $b[0].text | Should -Be 'Server-Backup FEHLGESCHLAGEN'
        $b[0].color | Should -Be 'Attention'
        $b.Count | Should -Be 4   # Titel, 2 Zeilen (leere entfaellt), Fusszeile
        $b[3].text | Should -Match '^SRV'
    }
    It 'Senden ohne eingetragene Adresse: kein Fehler, nur Hinweis' {
        Mock Get-HMNotifyConfig { [pscustomobject]@{ Url = ''; OnSuccess = $false; Configured = $false; Error = '' } }
        Send-HMNotify -Title 't' -Level 'Error' | Should -BeNullOrEmpty
        Send-HMTeamsMessage -Title 't' | Should -Match 'kein Teams-Webhook'
    }
    It 'Kategorien: Standardwerte, unbekannte Kategorie = ein, Konfiguration ueberschreibt' {
        $d = Get-HMNotifyDefaultCats
        $d['SbError'] | Should -BeTrue
        $d['SbOK'] | Should -BeFalse
        $d['MassDelete'] | Should -BeTrue
        $d.Keys.Count | Should -Be $script:HMNotifyCats.Count
        Test-HMNotifyCat $null 'SbOK' | Should -BeFalse
        Test-HMNotifyCat $null 'GibtEsNicht' | Should -BeTrue
        $cfg = [pscustomobject]@{ Cats = @{ SbOK = $true; Health = $false } }
        Test-HMNotifyCat $cfg 'SbOK' | Should -BeTrue
        Test-HMNotifyCat $cfg 'Health' | Should -BeFalse
        Test-HMNotifyCat ([pscustomobject]@{ Url = '' }) 'Reminder' | Should -BeTrue
    }
    It 'ausgeschaltete Kategorie sendet nichts' {
        Mock Get-HMNotifyConfig { [pscustomobject]@{ Url = 'https://localhost:1/x'; OnSuccess = $false; Cats = @{ MassDelete = $false }; Configured = $true; Error = '' } }
        Send-HMNotify -Title 't' -Level 'Error' -Category 'MassDelete' | Should -BeNullOrEmpty
    }
    It 'mehrere Ziele: jede Meldung nur an Ziele mit eingeschalteter Kategorie' {
        $a = Get-HMNotifyDefaultCats; $a['SbOK'] = $true
        $b = Get-HMNotifyDefaultCats; $b['MassDelete'] = $false
        Mock Get-HMNotifyConfig { [pscustomobject]@{ Configured = $true; Error = ''; Url = 'https://x.logic.azure.com/a'; Cats = $a
            Targets = @([pscustomobject]@{ Id = 'a'; Name = 'nur ich'; Url = 'https://x.logic.azure.com/a'; Cats = $a }, [pscustomobject]@{ Id = 'b'; Name = 'Kanal'; Url = 'https://x.logic.azure.com/b'; Cats = $b }) } }
        Mock Send-HMTeamsMessage { '' }
        Send-HMNotify -Title 't' -Level 'Error' -Category 'MassDelete' | Should -Be 'Teams-Benachrichtigung: nur ich: gesendet'
        Should -Invoke Send-HMTeamsMessage -Times 1 -Exactly -ParameterFilter { $Url -like '*/a' }
        Send-HMNotify -Title 't' -Level 'OK' | Should -Match '^Teams-Benachrichtigung: nur ich: gesendet$'
        Send-HMNotify -Title 't' -Level 'Error' -Category 'SbError' | Should -Match 'nur ich: gesendet; Kanal: gesendet'
    }
    It 'Ziele pruefen: Name, doppelte Namen, Adresse, Hoechstzahl' {
        $u = 'https://x.logic.azure.com/a'
        Test-HMNotifyTargets @() | Should -BeNullOrEmpty
        Test-HMNotifyTargets @(@{ Name = 'A'; Url = $u }, @{ Name = 'B'; Url = $u }) | Should -BeNullOrEmpty
        Test-HMNotifyTargets @(@{ Name = ''; Url = $u }) | Should -Match 'keinen Namen'
        Test-HMNotifyTargets @(@{ Name = 'A'; Url = $u }, @{ Name = 'a'; Url = $u }) | Should -Match 'doppelt'
        Test-HMNotifyTargets @(@{ Name = 'A'; Url = '' }) | Should -Match "Ziel 'A'"
        Test-HMNotifyTargets @(1..11 | ForEach-Object { @{ Name = "Z$_"; Url = $u } }) | Should -Match 'hoechstens'
    }
    It 'Kategorien aus gelesener Liste: unbekannte ignoriert, fehlende = Standard' {
        $c = ConvertTo-HMNotifyCats ([pscustomobject]@{ SbOK = $true; Health = $false; Unsinn = $true })
        $c['SbOK'] | Should -BeTrue
        $c['Health'] | Should -BeFalse
        $c['SbError'] | Should -BeTrue
        $c.ContainsKey('Unsinn') | Should -BeFalse
        (ConvertTo-HMNotifyCats @{ Space = $false })['Space'] | Should -BeFalse
    }
    It 'Einstellungsfenster erkennt Aenderungen an den Zielen' {
        . (Join-Path $script:Root 'Functions\UI-Settings.ps1')
        $l1 = @(@{ Id = 'a'; Name = 'Kanal'; Url = 'https://x/a'; Cats = (Get-HMNotifyDefaultCats) })
        $k1 = Get-HMTeamsListKey $l1
        $l1[0].Cats['SbOK'] = $true
        Get-HMTeamsListKey $l1 | Should -Not -Be $k1
        Get-HMTeamsListKey @() | Should -Be ''
    }
    It 'gibt die Adresse nie in Fehlermeldungen aus' {
        $r = Send-HMTeamsMessage -Title 't' -Url 'https://localhost:1/workflows/geheim?sig=GEHEIM'
        $r | Should -Match 'fehlgeschlagen'
        $r | Should -Not -Match 'GEHEIM'
    }
}

Describe 'Teams-Meldung Server-Backup (Kategorien, eine Karte je Lauf)' {
    BeforeAll {
        . (Join-Path $script:Root 'Functions\Core-Notify.ps1')
        $script:AllOn = Get-HMNotifyDefaultCats; foreach ($k in @($script:AllOn.Keys)) { $script:AllOn[$k] = $true }
        function New-TestRes([string]$St = 'OK', [string[]]$Notes = @(), [string]$Health = 'OK', [switch]$Low) {
            [pscustomobject]@{ Status = $St; Notes = $Notes; Health = $Health; HealthText = "Zustand $Health"; Report = 'E:\HUMig-ServerBackup\2026-10-11_Gym'
                Minutes = 42; SizeBytes = [long]200GB; FreeBytes = $(if ($Low) { [long]50GB } else { [long]1500GB }); TotalBytes = [long]2000GB; LowSpace = [bool]$Low
                VersionCount = 12; OldestVersion = '01.09.2026 22:00'; NewestVersion = '11.10.2026 22:00'; VMs = 'DC1, FS1'; Volumes = ''; HostSystem = 'ja' }
        }
    }
    It 'Speicherplatz knapp: weniger frei als benoetigt oder unter 10 %' {
        Test-HMSbLowSpace -Free 50GB -Total 2000GB -Need 200GB | Should -BeTrue
        Test-HMSbLowSpace -Free 150GB -Total 2000GB -Need 100GB | Should -BeTrue
        Test-HMSbLowSpace -Free 1500GB -Total 2000GB -Need 200GB | Should -BeFalse
        Test-HMSbLowSpace -Free 0 -Total 0 -Need 0 | Should -BeFalse
    }
    It 'Erfolg mit Standard-Kategorien: keine Meldung' {
        New-HMSbNotifyMessage -Result (New-TestRes) -ProfileName 'Gym' -Disk 'HUMIG-GYM-1' -Cats (Get-HMNotifyDefaultCats) | Should -BeNullOrEmpty
    }
    It 'Erfolg mit SbOK: Details mit Stand und Speicher' {
        $m = New-HMSbNotifyMessage -Result (New-TestRes) -ProfileName 'Gym' -Disk 'HUMIG-GYM-1' -Cats $script:AllOn -Computer 'HV1'
        $m.Level | Should -Be 'OK'
        $m.Title | Should -Be "Server-Backup 'Gym' auf HV1 erfolgreich"
        ($m.Lines -join '|') | Should -Match 'Versionen auf der Platte: 12'
        ($m.Lines -join '|') | Should -Match 'frei von'
        ($m.Lines -join '|') | Should -Match 'Dauer 42 min'
        ($m.Lines -join '|') | Should -Match 'VMs: DC1, FS1'
        ($m.Lines -join '|') | Should -Match 'Bericht\.html'
    }
    It 'Details aus: nur Platte und Bericht' {
        $c = $script:AllOn.Clone(); $c['Details'] = $false
        $m = New-HMSbNotifyMessage -Result (New-TestRes) -ProfileName 'Gym' -Disk 'D1' -Cats $c
        ($m.Lines -join '|') | Should -Not -Match 'Versionen'
        @($m.Lines).Count | Should -Be 2
    }
    It 'Fehler wird gemeldet, auch wenn Erfolg aus ist' {
        $m = New-HMSbNotifyMessage -Result (New-TestRes -St 'Error' -Notes @('Fehler: x')) -ProfileName 'Gym' -Disk 'D1' -Cats (Get-HMNotifyDefaultCats)
        $m.Level | Should -Be 'Error'
        $m.Title | Should -Match 'FEHLGESCHLAGEN'
        ($m.Lines -join '|') | Should -Match 'Hinweis: Fehler: x'
    }
    It 'nur Plattenzustand auffaellig: Warnung ueber Kategorie Health, abschaltbar' {
        $r = New-TestRes -St 'Warning' -Notes @('Platte: Warnung') -Health 'Warning'
        $c = Get-HMNotifyDefaultCats
        $m = New-HMSbNotifyMessage -Result $r -ProfileName 'Gym' -Disk 'D1' -Cats $c
        $m.Level | Should -Be 'Warning'
        ($m.Lines -join '|') | Should -Match 'Plattenzustand: Zustand Warning'
        ($m.Lines -join '|') | Should -Not -Match 'Hinweis: Platte'
        $c['Health'] = $false
        New-HMSbNotifyMessage -Result $r -ProfileName 'Gym' -Disk 'D1' -Cats $c | Should -BeNullOrEmpty
    }
    It 'Erinnerung und Speicherplatz als eigene Kategorien' {
        $c = Get-HMNotifyDefaultCats
        $m = New-HMSbNotifyMessage -Result (New-TestRes -Low) -ProfileName 'Gym' -Disk 'D1' -Reminders @('Plattenwechsel faellig') -Cats $c
        $m.Level | Should -Be 'Warning'
        ($m.Lines -join '|') | Should -Match 'Erinnerung: Plattenwechsel'
        ($m.Lines -join '|') | Should -Match 'Speicherplatz knapp'
        $c['Reminder'] = $false; $c['Space'] = $false
        New-HMSbNotifyMessage -Result (New-TestRes -Low) -ProfileName 'Gym' -Disk 'D1' -Reminders @('x') -Cats $c | Should -BeNullOrEmpty
    }
}

Describe 'Teams-Meldung geplanter Profil-Backups (Weitergabe als SYSTEM)' {
    BeforeAll {
        . (Join-Path $script:Root 'Functions\Core-Notify.ps1')
        $env:HUMIG_RELAY_NORUN = '1'
        . (Join-Path $script:Root 'Functions\Notify-Relay.ps1')
        function New-TestState([string]$St = 'OK', [switch]$Mass) {
            [pscustomobject]@{ Key = 'S-1-5-21-1|abcdefgh'; Name = 'Taeglich'; Account = 'SCHULE\lehrer1'; Computer = 'NB001'; LastRun = '2026-10-11 12:00'
                LastStatus = $St; LastMessage = '1,2 GB, Dauer 3 min'; LastBackup = 'E:\Backups\2026-10-11_1200_NB001_lehrer1'; LastMassDelete = [bool]$Mass }
        }
    }
    AfterAll { Remove-Item Env:\HUMIG_RELAY_NORUN -ErrorAction SilentlyContinue }
    It 'Standard: Fehler, uebersprungen, Warnung melden - Erfolg nicht' {
        $c = Get-HMNotifyDefaultCats
        (New-HMProfileNotifyMessage -State (New-TestState 'Error') -Cats $c).Level | Should -Be 'Error'
        (New-HMProfileNotifyMessage -State (New-TestState 'Skipped') -Cats $c).Title | Should -Match 'uebersprungen'
        (New-HMProfileNotifyMessage -State (New-TestState 'Warning') -Cats $c).Level | Should -Be 'Warning'
        New-HMProfileNotifyMessage -State (New-TestState 'OK') -Cats $c | Should -BeNullOrEmpty
    }
    It 'Erfolg mit PbOK: Titel mit Zeitplan, Benutzer, PC; Details mit Backup-Ordner' {
        $c = Get-HMNotifyDefaultCats; $c['PbOK'] = $true
        $m = New-HMProfileNotifyMessage -State (New-TestState 'OK') -Cats $c
        $m.Title | Should -Be "Profil-Backup 'Taeglich' von SCHULE\lehrer1 an NB001: erfolgreich"
        $m.Level | Should -Be 'OK'
        ($m.Lines -join '|') | Should -Match 'Backup: E:\\Backups'
        $c['Details'] = $false
        ((New-HMProfileNotifyMessage -State (New-TestState 'OK') -Cats $c).Lines -join '|') | Should -Not -Match 'Backup:'
    }
    It 'Massenloeschung wird als Fehler gemeldet, auch wenn Erfolg/Warnung aus sind' {
        $c = Get-HMNotifyDefaultCats; $c['PbWarning'] = $false
        $m = New-HMProfileNotifyMessage -State (New-TestState 'Warning' -Mass) -Cats $c
        $m.Level | Should -Be 'Error'
        $m.Title | Should -Match 'MASSENLOESCHUNG'
        $c['MassDelete'] = $false
        New-HMProfileNotifyMessage -State (New-TestState 'Warning' -Mass) -Cats $c | Should -BeNullOrEmpty
    }
    It 'Text aus der Benutzer-Datei wird entschaerft (Steuerzeichen, Links, Laenge)' {
        ConvertTo-HMNotifySafeText "a`tb[Link](https://x)" | Should -Be 'a bLink(https :// x)'
        (ConvertTo-HMNotifySafeText ('x' * 1000)).Length | Should -BeLessThan 410
    }
    It 'Weitergabe nur noetig, wenn ein Ziel Profil-Backup-Kategorien oder Massenloeschung hat' {
        $c = Get-HMNotifyDefaultCats
        Test-HMNotifyRelayNeeded @([pscustomobject]@{ Cats = $c }) | Should -BeTrue
        foreach ($n in @('PbError', 'PbSkipped', 'PbWarning', 'PbOK')) { $c[$n] = $false }
        Test-HMNotifyRelayNeeded @([pscustomobject]@{ Cats = $c }) | Should -BeTrue
        $c['MassDelete'] = $false
        Test-HMNotifyRelayNeeded @([pscustomobject]@{ Cats = $c }) | Should -BeFalse
        Test-HMNotifyRelayNeeded @() | Should -BeFalse
    }
    It 'meldet nur neue, junge Laeufe und hoechstens alle 10 Minuten je Zeitplan' {
        $now = [datetime]'2026-10-11 12:05'
        $r = New-TestState
        Test-HMRelayDue $r $null $now | Should -BeTrue
        Test-HMRelayDue $r ([pscustomobject]@{ Run = '2026-10-11 12:00'; Sent = '' }) $now | Should -BeFalse
        Test-HMRelayDue $r ([pscustomobject]@{ Run = '2026-10-11 11:00'; Sent = '2026-10-11 12:01:00' }) $now | Should -BeFalse
        Test-HMRelayDue $r ([pscustomobject]@{ Run = '2026-10-11 11:00'; Sent = '2026-10-11 11:01:00' }) $now | Should -BeTrue
        Test-HMRelayDue $r $null ([datetime]'2026-10-11 15:00') | Should -BeFalse
        $r.LastRun = 'Unsinn'; Test-HMRelayDue $r $null $now | Should -BeFalse
    }
    It 'zusammengesetztes SYSTEM-Skript ist fehlerfrei' {
        $t = Get-HMNotifyRelayText
        $e = $null; [void][System.Management.Automation.Language.Parser]::ParseInput($t, [ref]$null, [ref]$e)
        @($e).Count | Should -Be 0
        $t | Should -Match 'function Invoke-HMNotifyRelay'
        $t | Should -Match 'function Send-HMTeamsMessage'
    }
}

Describe 'VM-Export (Hyper-V Export-VM) und Teams-Ziele je Server-Backup-Profil' {
    BeforeAll { . (Join-Path $script:Root 'Functions\Core-Notify.ps1') }
    It 'Ziel: Platte (Ordner HUMig-Export) oder eigener Ordner' {
        Get-HMSbExportBase '' 'e' | Should -Be 'E:\HUMig-Export'
        Get-HMSbExportBase '' 'F:\' | Should -Be 'F:\HUMig-Export'
        Get-HMSbExportBase '\\nas\vm\' 'E' | Should -Be '\\nas\vm'
        Get-HMSbExportBase '' '' | Should -Be ''
        Get-HMSbFreeBytes '\\nas\vm' | Should -Be -1
    }
    It 'vorhandene Exporte: nur fertige Ordner mit Kennung dieser VM, aeltester zuerst' {
        $b = Join-Path $TestDrive 'Exp'
        $d = Get-HMSbExportVmDir $b 'DC 1'
        $mk = @{ '2026-10-02_2200' = 'id-1'; '2026-10-01_2200' = 'id-1'; '2026-10-02_2200.unvollstaendig' = 'id-1'; 'Notizen' = 'id-1'; '2026-10-03_220015' = 'id-1'; '2026-10-04_2200' = 'id-2'; '2026-10-05_2200' = '' }
        foreach ($n in $mk.Keys) {
            New-Item -ItemType Directory -Path (Join-Path $d $n) -Force | Out-Null
            if ($mk[$n]) { Set-Content -LiteralPath (Join-Path (Join-Path $d $n) '.humig-export') -Value @($mk[$n], 'DC 1') }
        }
        $l = @(Get-HMSbExports $b 'DC 1' 'id-1')
        $l.Count | Should -Be 3
        $l[0].Name | Should -Be '2026-10-01_2200'
        $l[2].Name | Should -Be '2026-10-03_220015'
        @(Get-HMSbExports $b 'DC 1').Count | Should -Be 4
        @(Get-HMSbExports $b 'DC 1' 'id-1' -Temp).Name | Should -Be '2026-10-02_2200.unvollstaendig'
        @(Get-HMSbExports $b 'GibtEsNicht').Count | Should -Be 0
    }
    It 'Loeschen eines Export-Ordners entfernt nur den Ordner' {
        $x = Join-Path $TestDrive 'Del\2026-10-01_2200'
        New-Item -ItemType Directory -Path (Join-Path $x 'VM\Virtual Hard Disks') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $x 'VM\Virtual Hard Disks\a.vhdx') -Value 'x'
        Remove-HMSbExportDir $x | Should -BeNullOrEmpty
        Test-Path -LiteralPath $x | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $TestDrive 'Del') | Should -BeTrue
        Remove-HMSbExportDir (Join-Path $TestDrive 'GibtEsNicht') | Should -BeNullOrEmpty
    }
    It 'Profil: Export-Einstellungen mit Standardwerten, nach der Sicherung nur mit VMs' {
        $p = ConvertTo-HMSbProfile ([pscustomobject]@{ Name = 'Gym' })
        $p.ExportAfter | Should -BeFalse
        $p.ExportKeep | Should -Be 1
        @($p.ExportVMs).Count | Should -Be 0
        Get-HMSbExportOptions $p | Should -BeNullOrEmpty
        $p2 = ConvertTo-HMSbProfile ([pscustomobject]@{ Name = 'Gym'; ExportAfter = $true; ExportVMs = @('DC1', ' ', 'FS1'); ExportKeep = 25; ExportFolder = ' \\nas\vm ' })
        $o = Get-HMSbExportOptions $p2
        @($o.VMs) -join ',' | Should -Be 'DC1,FS1'
        $o.Keep | Should -Be 1
        $o.Folder | Should -Be '\\nas\vm'
        Get-HMSbExportOptions (ConvertTo-HMSbProfile ([pscustomobject]@{ Name = 'X'; ExportAfter = $true })) | Should -BeNullOrEmpty
    }
    It 'Teams-Meldung: Export-Fehler ueber eigene Kategorie, Sicherung selbst bleibt OK' {
        $r = [pscustomobject]@{ Status = 'Warning'; Notes = @('Export: DC1 fehlgeschlagen'); Health = 'OK'; HealthText = 'OK'; Report = 'E:\HUMig-ServerBackup\x'
            Minutes = 10; SizeBytes = [long]10GB; FreeBytes = [long]900GB; TotalBytes = [long]1000GB; LowSpace = $false; VersionCount = 2; OldestVersion = 'a'; NewestVersion = 'b'
            VMs = 'DC1'; Volumes = ''; HostSystem = ''; Export = 'DC1 -> E:\HUMig-Export (FEHLER)'; ExportStatus = 'Error' }
        $c = Get-HMNotifyDefaultCats
        $m = New-HMSbNotifyMessage -Result $r -ProfileName 'Gym' -Disk 'D1' -Cats $c
        $m.Level | Should -Be 'Error'
        ($m.Lines -join '|') | Should -Match 'VM-Export FEHLGESCHLAGEN'
        ($m.Lines -join '|') | Should -Match 'Hinweis: DC1 fehlgeschlagen'
        $c['SbExport'] = $false
        New-HMSbNotifyMessage -Result $r -ProfileName 'Gym' -Disk 'D1' -Cats $c | Should -BeNullOrEmpty
        $c['SbExport'] = $true; $c['SbOK'] = $true
        $ok = $r.PSObject.Copy(); $ok.Status = 'OK'; $ok.Notes = @(); $ok.ExportStatus = 'OK'; $ok.Export = 'DC1 -> E:\HUMig-Export'
        $m2 = New-HMSbNotifyMessage -Result $ok -ProfileName 'Gym' -Disk 'D1' -Cats $c
        $m2.Level | Should -Be 'OK'
        ($m2.Lines -join '|') | Should -Match 'VM-Export: DC1'
    }
    It 'Ziel gilt fuer alle oder ausgewaehlte Server-Backup-Profile' {
        $all = [pscustomobject]@{ Name = 'A'; SbProfiles = @() }
        $gym = [pscustomobject]@{ Name = 'B'; SbProfiles = @('Gym', ' gym ', '') }
        Test-HMNotifySbProfile $all 'EUGym' | Should -BeTrue
        Test-HMNotifySbProfile ([pscustomobject]@{ Name = 'alt' }) 'EUGym' | Should -BeTrue
        Test-HMNotifySbProfile $gym 'GYM' | Should -BeTrue
        Test-HMNotifySbProfile $gym 'EUGym' | Should -BeFalse
        Test-HMNotifySbProfile $gym '' | Should -BeTrue
        @(ConvertTo-HMNotifySbProfiles $gym.SbProfiles).Count | Should -Be 1
    }
    It 'Send-HMNotify -SbProfile: nur an Ziele dieses Profils' {
        $a = Get-HMNotifyDefaultCats
        Mock Get-HMNotifyConfig { [pscustomobject]@{ Configured = $true; Error = ''; Url = 'https://x.logic.azure.com/a'; Cats = $a
            Targets = @([pscustomobject]@{ Id = 'a'; Name = 'Gym-Kanal'; Url = 'https://x.logic.azure.com/a'; Cats = $a; SbProfiles = @('Gym') }, [pscustomobject]@{ Id = 'b'; Name = 'alle'; Url = 'https://x.logic.azure.com/b'; Cats = $a; SbProfiles = @() }) } }
        Mock Send-HMTeamsMessage { '' }
        Send-HMNotify -Title 't' -Level 'Error' -Category 'SbError' -SbProfile 'EUGym' | Should -Be 'Teams-Benachrichtigung: alle: gesendet'
        Send-HMNotify -Title 't' -Level 'Error' -Category 'SbError' -SbProfile 'Gym' | Should -Match 'Gym-Kanal: gesendet; alle: gesendet'
        Send-HMNotify -Title 't' -Level 'Error' -Category 'SbError' | Should -Match 'Gym-Kanal: gesendet; alle: gesendet'
    }
    It 'Einstellungsfenster erkennt Aenderung der Profil-Auswahl' {
        . (Join-Path $script:Root 'Functions\UI-Settings.ps1')
        $l = @(@{ Id = 'a'; Name = 'K'; Url = 'https://x/a'; Cats = (Get-HMNotifyDefaultCats); SbProfiles = @() })
        $k = Get-HMTeamsListKey $l
        $l[0].SbProfiles = @('Gym')
        Get-HMTeamsListKey $l | Should -Not -Be $k
    }
}
