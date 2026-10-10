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
