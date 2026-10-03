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
