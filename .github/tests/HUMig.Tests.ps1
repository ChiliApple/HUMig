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
    It 'WinGet-Modul im eigenen Prozess: Ausgabe, Ergebnis, Fehler, Absturz, Zeitlimit (HUMig bleibt offen)' -Skip:([Environment]::OSVersion.Platform -ne 'Win32NT') {
        $lines = New-Object System.Collections.Generic.List[string]
        $r = Invoke-HMAuIsolated "L 'Info' 'eins'; L 'Success' 'zwei|drei'; [Console]::Out.WriteLine('R|1.2.3')" 60 { param($m, $l) $lines.Add("$l=$m") }
        $r.Ok | Should -BeTrue
        $r.Result | Should -Be '1.2.3'
        @($lines) | Should -Be @('Info=eins', 'Success=zwei|drei')
        $r = Invoke-HMAuIsolated "throw 'kaputt'" 60
        $r.Ok | Should -BeFalse; $r.Crashed | Should -BeFalse; $r.Error | Should -Be 'kaputt'
        $r = Invoke-HMAuIsolated "[Environment]::FailFast('Test')" 60
        $r.Ok | Should -BeFalse; $r.Crashed | Should -BeTrue
        (Format-HMAuCrash $r) | Should -Match 'abgestuerzt \(Code 0x[0-9A-F]{8}\)'
        $r = Invoke-HMAuIsolated 'Start-Sleep -Seconds 60' 2
        $r.TimedOut | Should -BeTrue; $r.Crashed | Should -BeFalse
        $r = Invoke-HMAuIsolated 'Start-Sleep -Seconds 60' 60 -Job @{ Cancel = $true }
        $r.Cancelled | Should -BeTrue; $r.Ok | Should -BeFalse
    }
    It 'WinGet-Modul wird nie im HUMig-Prozess geladen (Status, Einrichten, Ziel-PC)' {
        $eng = Get-Content (Join-Path $script:Root 'Functions\AppUpdates-Engine.ps1') -Raw -Encoding UTF8
        $st = [regex]::Match($eng, '(?s)function Get-HMAuState \{.*?\n\}').Value
        $st | Should -Not -BeNullOrEmpty
        $st | Should -Not -Match '(?m)^\s*Import-Module \$script:HMAuModule'
        $st | Should -Match 'Invoke-HMAuIsolated'
        $in = [regex]::Match($eng, '(?s)function Install-HMAuWinGet\(\$Job\) \{.*?(?=\r?\n# ---|\r?\nfunction )').Value
        $in | Should -Match 'Invoke-HMAuIsolated'
        $in = $in -replace '(?s)@".*?\n"@', ''   # Skript fuer den eigenen Prozess (Here-String) zaehlt nicht
        $in | Should -Not -Match '(?m)^\s*(Import-Module|Repair-WinGetPackageManager|Assert-WinGetPackageManager)\b'
        $tg = Get-Content (Join-Path $script:Root 'Functions\AppUpdates-Target.ps1') -Raw -Encoding UTF8
        $tw = [regex]::Match($tg, '(?s)function Install-TWinGet \{.*?\n\}').Value
        $tw | Should -Match 'EncodedCommand'
        $tw | Should -Not -Match '(?m)^\s*(Import-Module|Repair-WinGetPackageManager)\b'
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

Describe 'Fortschritt nach Datenmenge (Backup)' {
    BeforeAll { . (Join-Path $script:Root 'Functions\Migration-Engine.ps1') }
    It 'Gewicht auch fuer Eintraege ueber 2 GiB (long statt int), ohne Plan 4 MB' {
        $m = [pscustomobject]@{ Id = 'Docs' }; $i = [pscustomobject]@{ Type = 'Folder'; Name = 'DOCS'; Path = 'C:\x'; Handler = '' }
        $p = @{ (Get-HMPlanKey $m $i) = [long]3GB }
        Get-HMPlanWeight $p $m $i | Should -Be ([double](3GB + 4MB))
        $p[(Get-HMPlanKey $m $i)] = [long]900GB
        Get-HMPlanWeight $p $m $i | Should -Be ([double]900GB + [double]4MB)
        Get-HMPlanWeight @{} $m $i | Should -Be ([double]4MB)
        Get-HMPlanWeight $null $m $i | Should -Be ([double]4MB)
    }
}

Describe 'Listen-Rueckgaben (return ,@()) erst zuweisen' {
    It 'keine Funktion mit "return ,..." wird in @() gewickelt oder in eine Pipeline gegeben (alle Skripte)' {
        $files = @(Get-ChildItem -Path $script:Root -Filter *.ps1 -File -Recurse | Where-Object { $_.FullName -notmatch '[\\/]\.github[\\/]' })
        $names = @(); $asts = @{}
        foreach ($f in $files) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
            $asts[$f.FullName] = $ast
            foreach ($fd in $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
                $rets = $fd.Body.FindAll({ param($a) $a -is [System.Management.Automation.Language.ReturnStatementAst] -and $a.Pipeline -and $a.Pipeline.Extent.Text -match '^\s*,' }, $false)
                # auch "..., $x" als letzte Anweisung ohne return
                $last = $null; if ($fd.Body.EndBlock -and $fd.Body.EndBlock.Statements.Count) { $last = $fd.Body.EndBlock.Statements[$fd.Body.EndBlock.Statements.Count - 1] }
                if (@($rets).Count -or ($last -is [System.Management.Automation.Language.PipelineAst] -and $last.Extent.Text -match '^\s*,')) { $names += $fd.Name }
            }
        }
        $names = @($names | Select-Object -Unique)
        $names | Should -Contain 'Get-HMRemotePushRequests'
        $names | Should -Contain 'Get-HMHUPilotRisk'
        # Verwendung per AST: Aufruf in einer Pipeline mit mehreren Gliedern oder als einziger Inhalt von @(...)
        $bad = @()
        foreach ($k in $asts.Keys) {
            $calls = $asts[$k].FindAll({ param($a) $a -is [System.Management.Automation.Language.CommandAst] -and $names -contains $a.GetCommandName() }, $true)
            foreach ($c in $calls) {
                $p = $c.Parent
                if ($p -is [System.Management.Automation.Language.PipelineAst]) {
                    $isBad = $p.PipelineElements.Count -gt 1
                    $sb = $p.Parent
                    if ($sb -is [System.Management.Automation.Language.StatementBlockAst] -and $sb.Parent -is [System.Management.Automation.Language.ArrayExpressionAst] -and $sb.Statements.Count -eq 1) { $isBad = $true }
                    if ($isBad) { $bad += "$([IO.Path]::GetFileName($k)):$($c.Extent.StartLineNumber)" }
                }
            }
        }
        $bad | Should -BeNullOrEmpty
        # Gegenprobe: der Test erkennt die Fehlverwendung auch ueber Zeilenumbrueche
        $probe = [System.Management.Automation.Language.Parser]::ParseInput("`$x = @(`n Get-HMRemotePushRequests `$a)`nGet-HMHUPilotRisk `$a (`$b) | Where-Object { `$_ }", [ref]$null, [ref]$null)
        $pc = $probe.FindAll({ param($a) $a -is [System.Management.Automation.Language.CommandAst] -and $names -contains $a.GetCommandName() }, $true)
        @($pc | Where-Object { ($_.Parent.PipelineElements.Count -gt 1) -or ($_.Parent.Parent.Parent -is [System.Management.Automation.Language.ArrayExpressionAst]) }).Count | Should -Be 2
    }
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

Describe 'HUPilot: Ordner finden und Hashes uebergeben' {
    BeforeAll {
        function Out-Console { param($m, $l) }
        function Confirm-Action { param($m, $t) $false }
        function Read-JsonFile([string]$Path) { if (Test-Path -LiteralPath $Path) { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json } }
        . (Join-Path $script:Root 'Functions\Tools-School.ps1')
        $script:HP = Join-Path $TestDrive 'Stick'
        New-Item -ItemType Directory -Path (Join-Path $script:HP 'HUPilot\Setup') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:HP 'HUPilot\Setup\HUPilot-Setup.ps1') -Value '#'
        Set-Content -LiteralPath (Join-Path $script:HP 'HUPilot-Setup.cmd') -Value '@echo off'
    }
    It 'findet den HUPilot-Ordner ueber Stick-Ordner, cmd, ps1 und HUPilot-Ordner' {
        $want = (Resolve-Path -LiteralPath (Join-Path $script:HP 'HUPilot')).ProviderPath
        Resolve-HMHUPilotDir $script:HP | Should -Be $want
        Resolve-HMHUPilotDir (Join-Path $script:HP 'HUPilot-Setup.cmd') | Should -Be $want
        Resolve-HMHUPilotDir (Join-Path $script:HP 'HUPilot\Setup\HUPilot-Setup.ps1') | Should -Be $want
        Resolve-HMHUPilotDir (Join-Path $script:HP 'HUPilot') | Should -Be $want
        Resolve-HMHUPilotDir (Join-Path $TestDrive 'GibtEsNicht') | Should -Be ''
        Resolve-HMHUPilotDir '' | Should -Be ''
    }
    It 'ohne eingetragenes HUPilot wird nichts geschrieben' {
        $script:ConfigDir = Join-Path $TestDrive 'CfgLeer'
        Add-HMHUPilotHashes @([pscustomobject]@{ Serial = 'SN1'; Hash = 'AAA'; Tag = '' })
        Test-Path -LiteralPath (Join-Path $script:HP 'HUPilot\logs\hashes.csv') | Should -BeFalse
    }
    It 'warnt vor dem Start als Administrator, wenn normale Benutzer die Datei aendern duerfen' -Skip:([Environment]::OSVersion.Platform -ne 'Win32NT') {
        $f = Join-Path $TestDrive 'Risk\HUPilot\Setup\HUPilot-Setup.ps1'
        New-Item -ItemType Directory -Path (Split-Path $f -Parent) -Force | Out-Null
        Set-Content -LiteralPath $f -Value '#'
        # nur eigenes Konto, SYSTEM und Administratoren (Vererbung aus)
        $acl = Get-Acl -LiteralPath $f
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($sid in @('S-1-5-18', 'S-1-5-32-544', ([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value))) {
            $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule((New-Object System.Security.Principal.SecurityIdentifier($sid)), 'FullControl', 'Allow')))
        }
        Set-Acl -LiteralPath $f -AclObject $acl
        $d = Get-Acl -LiteralPath (Split-Path $f -Parent)
        $d.SetAccessRuleProtection($true, $false)
        foreach ($sid in @('S-1-5-18', 'S-1-5-32-544', ([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value))) {
            $d.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule((New-Object System.Security.Principal.SecurityIdentifier($sid)), 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow')))
        }
        Set-Acl -LiteralPath (Split-Path $f -Parent) -AclObject $d
        $rk = Get-HMHUPilotRisk $f
        @($rk | Where-Object { $_ -match 'duerfen|nicht lesbar' }).Count | Should -Be 0
        foreach ($x in $rk) { $x | Should -BeOfType [string] }
        # Benutzer duerfen lesen: keine Warnung
        $acl = Get-Acl -LiteralPath $f
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule((New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')), 'ReadAndExecute', 'Allow')))
        Set-Acl -LiteralPath $f -AclObject $acl
        $rk = Get-HMHUPilotRisk $f
        @($rk | Where-Object { $_ -match 'normale Benutzer' }).Count | Should -Be 0
        # Benutzer duerfen aendern: Warnung
        $acl = Get-Acl -LiteralPath $f
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule((New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')), 'Modify', 'Allow')))
        Set-Acl -LiteralPath $f -AclObject $acl
        $rk = Get-HMHUPilotRisk $f
        @($rk | Where-Object { $_ -match 'normale Benutzer duerfen die Datei' }).Count | Should -Be 1
        # anderes einzelnes Konto mit Schreibrecht (z. B. Ordner im Profil eines Standardbenutzers): ebenfalls Warnung
        $f2 = Join-Path (Split-Path $f -Parent) 'B.ps1'; Set-Content -LiteralPath $f2 -Value '#'
        $a2 = Get-Acl -LiteralPath $f2
        $a2.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule((New-Object System.Security.Principal.SecurityIdentifier('S-1-5-21-1-2-3-1001')), 'Modify', 'Allow')))
        Set-Acl -LiteralPath $f2 -AclObject $a2
        $rk = Get-HMHUPilotRisk $f2
        @($rk | Where-Object { $_ -match 'duerfen die Datei' }).Count | Should -Be 1
    }
}

Describe 'Testinstallation (Sandbox): Installation ins Benutzerprofil erkennen' {
    BeforeAll {
        . (Join-Path $script:Root 'Functions\Tools-Sandbox.ps1')
        function New-HMSbxRes($Entries, $UserFolders) {
            [pscustomobject]@{ ExitCode = 0; InstallStatus = 'OK'; InstallText = 'installiert'; Seconds = 10; NewEntries = @($Entries); NewFolders = @(); UserFolders = @($UserFolders); SelectedKey = ''
                DesktopLinks = @(); DesktopLinksLeft = @(); InstallWindows = @(); UninstallWindows = @(); Deps = @(); UninstallTested = $false; InstallLog = ''; UninstallLog = ''; Error = '' }
        }
    }
    It 'Programme-Ordner fuer alle Benutzer (HKLM) + AppData\Local\Programs\Common: kein Benutzerprofil-Hinweis (Greenshot)' {
        $e = [pscustomobject]@{ Key = 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Greenshot_is1'; DisplayName = 'Greenshot 1.3.323'; DisplayVersion = '1.3.323'; Publisher = 'Greenshot'
            UninstallString = '"C:\Program Files\Greenshot\unins000.exe"'; QuietUninstallString = '"C:\Program Files\Greenshot\unins000.exe" /SILENT'; InstallLocation = 'C:\Program Files\Greenshot\'; DisplayIcon = 'C:\Program Files\Greenshot\Greenshot.exe' }
        $uf = @('C:\Users\WDAGUtilityAccount\AppData\Local\Programs\Common', 'C:\Users\WDAGUtilityAccount\AppData\Roaming\Greenshot', 'C:\Users\WDAGUtilityAccount\AppData\Local\Greenshot')
        $s = Get-HMSandboxSummary -Result (New-HMSbxRes @($e) $uf) -Settings ([pscustomobject]@{ Name = 'Greenshot 1.3.323' })
        $s.Proposal.RunAsUser | Should -BeFalse
        $s.SandboxInfo.UserProfile | Should -BeFalse
        @($s.Proposal.Warnings | Where-Object { $_ -match 'Benutzerprofil' }).Count | Should -Be 0
        $s.Proposal.DetectName | Should -Be 'Greenshot*'
    }
    It 'Eintrag in HKCU bzw. nur neuer Ordner in AppData\Local\Programs: Benutzerprofil' {
        $e = [pscustomobject]@{ Key = 'HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Uninstall\App_is1'; DisplayName = 'App 1.0'; DisplayVersion = '1.0'; Publisher = 'X'
            UninstallString = '"C:\Users\WDAGUtilityAccount\AppData\Local\Programs\App\unins000.exe"'; QuietUninstallString = ''; InstallLocation = 'C:\Users\WDAGUtilityAccount\AppData\Local\Programs\App\'; DisplayIcon = '' }
        (Get-HMSandboxSummary -Result (New-HMSbxRes @($e) @()) -Settings ([pscustomobject]@{ Name = 'App' })).Proposal.RunAsUser | Should -BeTrue
        (Get-HMSandboxSummary -Result (New-HMSbxRes @() @('C:\Users\WDAGUtilityAccount\AppData\Local\Programs\App')) -Settings ([pscustomobject]@{ Name = 'App' })).Proposal.RunAsUser | Should -BeTrue
    }
}

Describe 'Handy-Fernbedienung: QR-Code, Kopplung, Anfragen' {
    BeforeAll {
        . (Join-Path $script:Root 'Functions\Remote-Core.ps1')
        . (Join-Path $script:Root 'Functions\Remote-Web.ps1')
        function New-HMRemTestState {
            $S = New-HMRemoteState
            $S.Pc = 'TESTPC'; $S.Version = '9.9.9'
            $S.Static = Get-HMRemoteWebFiles -Version '9.9.9' -Pc 'TESTPC' -Icon192 ([byte[]](1, 2)) -Icon512 ([byte[]](3, 4)) -Ca ([byte[]](48, 1, 0))
            return $S
        }
        function Invoke-HMRemTest($S, [string]$Method, [string]$Path, $Body = $null, [string]$Token = '', [string]$Ip = '10.0.0.9', [string]$Origin = '', [hashtable]$Query = @{}) {
            $b = if ($null -ne $Body) { $Body | ConvertTo-Json -Compress } else { '' }
            $a = if ($Token) { "Bearer $Token" } else { '' }
            return (Get-HMRemoteResponse $S @{ Method = $Method; Path = $Path; Query = $Query; Auth = $a; Origin = $Origin; Host = '10.0.0.5:8443'; Body = $b; Ip = $Ip; Now = (Get-Date) })
        }
        function Get-HMRemTestMd5([string]$s) {
            $m = [System.Security.Cryptography.MD5]::Create()
            try { return ([BitConverter]::ToString($m.ComputeHash([Text.Encoding]::ASCII.GetBytes($s))) -replace '-', '') } finally { $m.Dispose() }
        }
    }
    It 'QR-Code: Version, Groesse und Module wie die Referenz (Python qrcode, Byte-Modus, Fehlerkorrektur M)' {
        $q = ConvertTo-HMQrMatrix 'https://10.1.1.5:8443/#c=123456' -Mask 2
        $q.Version | Should -Be 3; $q.Size | Should -Be 29
        Get-HMRemTestMd5 (-join $q.Modules) | Should -Be '29844F505C3044CEB3D5A597B7FE6CBB'
        $q = ConvertTo-HMQrMatrix 'https://192.168.178.200:65535/#c=987654' -Mask 5
        Get-HMRemTestMd5 (-join $q.Modules) | Should -Be 'C4A16335056A9538C86C93805DEE6648'
        (ConvertTo-HMQrMatrix ('x' * 200)).Version | Should -Be 10
        { ConvertTo-HMQrMatrix ('x' * 300) } | Should -Throw
    }
    It 'Token und Code: zufaellig, Format, nur Hash vergleichbar' {
        $t1 = New-HMRemoteToken; $t2 = New-HMRemoteToken
        $t1 | Should -Match '^[A-Za-z0-9_-]{43}$'; $t1 | Should -Not -Be $t2
        New-HMRemotePairCode | Should -Match '^\d{6}$'
        Test-HMRemoteEqual '123456' '123456' | Should -BeTrue
        Test-HMRemoteEqual '123456' '123457' | Should -BeFalse
        ConvertTo-HMRemoteDeviceName "<b>Max</b>`n" | Should -Be 'bMax/b'
        ConvertTo-HMRemoteDeviceName '' | Should -Be 'Handy'
        (ConvertTo-HMRemoteDeviceName ('a' * 80)).Length | Should -Be 40
    }
    It 'Seite: statische Dateien, keine Inline-Skripte, kein innerHTML' {
        $S = New-HMRemTestState
        $r = Invoke-HMRemTest $S 'GET' '/'
        $r.Code | Should -Be 200; $r.Type | Should -Match 'text/html'
        $html = [Text.Encoding]::UTF8.GetString($r.Bytes)
        $html | Should -Match '<script src="/app.js" defer></script>'
        $html | Should -Not -Match '<script>'
        $html | Should -Not -Match '\son[a-z]+='
        $html | Should -Not -Match '\sstyle='
        [Text.Encoding]::UTF8.GetString($S.Static['/app.js'].Bytes) | Should -Not -Match 'innerHTML|outerHTML|insertAdjacentHTML|eval\('
        [Text.Encoding]::UTF8.GetString($S.Static['/sw.js'].Bytes) | Should -Match "humig-9\.9\.9"
        ([Text.Encoding]::UTF8.GetString($S.Static['/manifest.webmanifest'].Bytes) | ConvertFrom-Json).name | Should -Be 'HUMig TESTPC'
        (Invoke-HMRemTest $S 'GET' '/ca.cer').Headers['Content-Disposition'] | Should -Match 'HUMig-CA.cer'
        (Invoke-HMRemTest $S 'GET' '/gibtsnicht').Code | Should -Be 404
        (Invoke-HMRemTest $S 'POST' '/').Code | Should -Be 405
        $script:HMRemoteHeaders['Content-Security-Policy'] | Should -Match "script-src 'self'"
        $script:HMRemoteHeaders['Content-Security-Policy'] | Should -Match "frame-ancestors 'none'"
    }
    It 'Koppeln: nur offen, falscher Code zaehlt, nach 5 Fehlversuchen gesperrt' {
        $S = New-HMRemTestState
        (Invoke-HMRemTest $S 'POST' '/api/pair' @{ code = '123456'; name = 'A' }).Code | Should -Be 409
        $code = Open-HMRemotePairing $S
        $bad = if ($code -eq '000000') { '111111' } else { '000000' }
        for ($i = 1; $i -le 5; $i++) { (Invoke-HMRemTest $S 'POST' '/api/pair' @{ code = $bad } -Ip "10.0.0.$i").Code | Should -Be 403 }
        $S.Pair.Locked | Should -BeTrue
        (Invoke-HMRemTest $S 'POST' '/api/pair' @{ code = $code } -Ip '10.0.0.50').Code | Should -Be 409
        $S.Devices.Count | Should -Be 0
    }
    It 'Koppeln: richtiger Code -> Token, gespeichert wird nur der Hash; danach Zugriff, Entfernen wirkt sofort' {
        $S = New-HMRemTestState
        $code = Open-HMRemotePairing $S
        $r = Invoke-HMRemTest $S 'POST' '/api/pair' @{ code = $code; name = 'Pixel' }
        $r.Code | Should -Be 200
        $j = $r.Text | ConvertFrom-Json
        $j.token | Should -Match '^[A-Za-z0-9_-]{43}$'
        $S.Devices.ContainsKey($j.token) | Should -BeFalse
        $S.Devices.ContainsKey((Get-HMRemoteHash $j.token)) | Should -BeTrue
        $r.Log | Should -Not -Match ([regex]::Escape($j.token))
        $S.Events.Dequeue().Kind | Should -Be 'Paired'
        # Code gilt nur einmal - fuer das naechste Handy gibt es einen neuen
        $S.Pair.Code | Should -Not -Be $code
        $S.Pair.Code | Should -Match '^\d{6}$'
        (Invoke-HMRemTest $S 'POST' '/api/pair' @{ code = $code; name = 'Zweit' } -Ip '10.0.0.77').Code | Should -Be 403
        (Invoke-HMRemTest $S 'POST' '/api/pair' @{ code = $S.Pair.Code; name = 'Zweit' } -Ip '10.0.0.78').Code | Should -Be 200
        (Invoke-HMRemTest $S 'GET' '/api/state' -Token $j.token).Code | Should -Be 200
        $S.Devices.Clear()
        (Invoke-HMRemTest $S 'GET' '/api/state' -Token $j.token).Code | Should -Be 401
    }
    It 'Ohne gueltiges Token: 401, nach 10 Fehlversuchen von einer Adresse 429' {
        $S = New-HMRemTestState
        for ($i = 0; $i -lt 10; $i++) { (Invoke-HMRemTest $S 'GET' '/api/state' -Token ('x' * 43) -Ip '10.9.9.9').Code | Should -Be 401 }
        (Invoke-HMRemTest $S 'GET' '/api/state' -Token ('x' * 43) -Ip '10.9.9.9').Code | Should -Be 429
        (Invoke-HMRemTest $S 'GET' '/api/state' -Ip '10.9.9.8').Code | Should -Be 401
    }
    It 'Status: gueltiges JSON mit Startseite, Vorgang und neuen Konsolenzeilen' {
        $S = New-HMRemTestState
        $code = Open-HMRemotePairing $S
        $tok = ((Invoke-HMRemTest $S 'POST' '/api/pair' @{ code = $code; name = 'P' }).Text | ConvertFrom-Json).token
        $data = [pscustomobject]@{ Time = (Get-Date '2026-10-13 08:00'); Warnings = @([pscustomobject]@{ Level = 'Error'; Area = 'Zeitplan'; Text = 'Plan <x> "1"' }); Schedules = @(); Backups = @(); Server = @(); Apps = @() }
        $S.StatusJson = ConvertTo-HMRemoteStatusJson $data
        $job = @{ Started = (Get-Date).AddSeconds(-65); Progress = 42; Status = 'kopiere'; Cancel = $false }
        $S.JobJson = ConvertTo-HMRemoteJobJson $job 'Backup PC1'
        Add-HMRemoteLineTo $S 'eins' 'Info'; Add-HMRemoteLineTo $S 'zwei' 'Error'
        $j = (Invoke-HMRemTest $S 'GET' '/api/state' -Token $tok -Query @{ since = '1' }).Text | ConvertFrom-Json
        $j.ok | Should -BeTrue; $j.pc | Should -Be 'TESTPC'; $j.device | Should -Be 'P'
        $j.status.warnings[0].text | Should -Be 'Plan <x> "1"'
        $j.job.running | Should -BeTrue; $j.job.progress | Should -Be 42; $j.job.title | Should -Be 'Backup PC1'
        @($j.lines).Count | Should -Be 1; $j.lines[0].t | Should -Be 'zwei'; $j.seq | Should -Be 2
        (ConvertTo-HMRemoteJobJson $null '' @{ Title = 'X'; Result = 'erfolgreich'; Time = '13.10. 08:00' } | ConvertFrom-Json).lastTitle | Should -Be 'X'
        for ($i = 0; $i -lt 350; $i++) { Add-HMRemoteLineTo $S "z$i" 'Info' }
        $S.Lines.Count | Should -Be 300
    }
    It 'Live-Anzeige (Durchsatz, CPU, RAM) im Vorgang: Texte und Verlauf, Werte gerundet, ohne Anzeige kein Feld' {
        function Format-HMSize($b) { "$b" }; function Format-HMDuration($d) { 'x' }
        . (Join-Path $script:Root 'Functions\UI-Monitor.ps1')
        $h = @{ Wr = New-Object System.Collections.Generic.List[double]; Rd = New-Object System.Collections.Generic.List[double]; Cpu = New-Object System.Collections.Generic.List[double]; Ram = New-Object System.Collections.Generic.List[double] }
        $h.Wr.Add(3MB); $h.Wr.Add(1572864.0); $h.Cpu.Add(12.345)
        $m = New-HMMonSnap $h '1,0 MB/s  /  3,0 MB/s' 'Durchschnitt' '12 %' '8 logische Prozessoren' '86 %' '13,5 von 15,7 GB belegt' $false
        $job = @{ Started = (Get-Date).AddSeconds(-5); Progress = 10; Status = 'kopiere'; Cancel = $false }
        $j = ConvertTo-HMRemoteJobJson $job 'Backup' -Mon $m | ConvertFrom-Json
        $j.mon.cpu | Should -Be '12 %'; $j.mon.ram | Should -Be '86 %'
        @($j.mon.wr) | Should -Be @(3, 1.5); @($j.mon.cpuH) | Should -Be @(12.3); @($j.mon.rd).Count | Should -Be 0
        $j.mon.done | Should -BeFalse
        (ConvertTo-HMRemoteJobJson $null '' -Mon $m | ConvertFrom-Json).mon.io | Should -Be '1,0 MB/s  /  3,0 MB/s'
        (ConvertTo-HMRemoteJobJson $job 'Backup' | ConvertFrom-Json).PSObject.Properties.Name | Should -Not -Contain 'mon'
        $f = Get-HMRemoteWebFiles -Version '1' -Pc 'PC'
        $html = [Text.Encoding]::UTF8.GetString($f['/index.html'].Bytes); $js = [Text.Encoding]::UTF8.GetString($f['/app.js'].Bytes)
        $html | Should -Match 'id="jMon"'; $js | Should -Match 'function renderMon'
        $js | Should -Not -Match 'innerHTML'
    }
    It 'Abbrechen nur mit Bestaetigung und Token, fremde Herkunft abgelehnt; Entkoppeln' {
        $S = New-HMRemTestState
        $code = Open-HMRemotePairing $S
        $tok = ((Invoke-HMRemTest $S 'POST' '/api/pair' @{ code = $code; name = 'P' }).Text | ConvertFrom-Json).token
        (Invoke-HMRemTest $S 'POST' '/api/cancel' @{ } -Token $tok).Code | Should -Be 400
        $S.CancelReq | Should -BeNullOrEmpty
        (Invoke-HMRemTest $S 'POST' '/api/cancel' @{ confirm = $true } -Token $tok -Origin 'https://boese.example').Code | Should -Be 403
        (Invoke-HMRemTest $S 'POST' '/api/cancel' @{ confirm = $true } -Token $tok -Origin 'https://10.0.0.5:8443').Code | Should -Be 202
        $S.CancelReq.By | Should -Be 'P'
        (Invoke-HMRemTest $S 'POST' '/api/cancel' @{ confirm = $true }).Code | Should -Be 401
        (Invoke-HMRemTest $S 'POST' '/api/unpair' @{ } -Token $tok).Code | Should -Be 200
        $S.Devices.Count | Should -Be 0
    }
    It 'Geraete-Datei: speichern und lesen (nur Hashes), kaputte Eintraege ignoriert' {
        $f = Join-Path $TestDrive 'dev.json'
        $d = [hashtable]::Synchronized(@{}); $d[(Get-HMRemoteHash 'abc')] = @{ Id = '1'; Name = 'A'; Created = 'x'; LastSeen = 'y'; LastIp = '10.0.0.1' }
        Save-HMRemoteDevices $d $f
        (Get-Content $f -Raw) | Should -Not -Match '"abc"'
        $r = Read-HMRemoteDevices $f
        $r.Count | Should -Be 1; $r[(Get-HMRemoteHash 'abc')].Name | Should -Be 'A'
        Set-Content $f '{"Devices":[{"Hash":"kaputt","Name":"X"}]}'
        (Read-HMRemoteDevices $f).Count | Should -Be 0
    }
    It 'Netz: private Adressen, Firewall-Gegenstellen, Reihenfolge der Adressen' {
        Test-HMRemotePrivateIp '10.1.1.5' | Should -BeTrue
        Test-HMRemotePrivateIp '172.31.0.1' | Should -BeTrue
        Test-HMRemotePrivateIp '172.32.0.1' | Should -BeFalse
        Test-HMRemotePrivateIp '203.0.113.50' | Should -BeFalse
        @(Get-HMRemoteFirewallRemote @('10.20.0.0/16', 'quatsch', '300.1.1.1', '192.168.1.7')) | Should -Be @('LocalSubnet', '10.20.0.0/16', '192.168.1.7')
        $l = Select-HMRemoteIPs @([pscustomobject]@{ IP = '172.20.1.1'; Gateway = $false; Private = $true }, [pscustomobject]@{ IP = '10.1.1.5'; Gateway = $true; Private = $true }, [pscustomobject]@{ IP = '193.1.1.1'; Gateway = $true; Private = $false })
        $l[0].IP | Should -Be '10.1.1.5'; $l[1].IP | Should -Be '193.1.1.1'
    }
    It 'Zertifikat: Namensbeschraenkung, SAN lesen, Bindung erkennen' {
        $t = Get-HMRemoteNameConstraintText @('pc1', 'pc1.schule.local')
        $t | Should -Match '^2\.5\.29\.30=\{critical\}\{text\}subtree=include&DNS=pc1&DNS=pc1\.schule\.local&IPAddress=10\.0\.0\.0,255\.0\.0\.0&IPAddress=172\.16\.0\.0,255\.240\.0\.0&IPAddress=192\.168\.0\.0,255\.255\.0\.0$'
        # SEQUENCE { dNSName "pc1", iPAddress 10.1.1.5 }
        $raw = [byte[]](0x30, 0x0B, 0x82, 0x03, 0x70, 0x63, 0x31, 0x87, 0x04, 10, 1, 1, 5)
        $s = Get-HMRemoteSan $raw
        $s.Dns | Should -Be @('pc1'); $s.IPs | Should -Be @('10.1.1.5')
        $g = $script:HMRemoteAppId.Trim('{}')
        (ConvertFrom-HMRemoteSslShow "IP:port : 0.0.0.0:8443`n Certificate Hash : 0123456789abcdef0123456789abcdef01234567`n Application ID : {$g}").State | Should -Be 'Ours'
        (ConvertFrom-HMRemoteSslShow "IP:port : 0.0.0.0:8443`n Certificate Hash : 0123456789abcdef0123456789abcdef01234567`n Application ID : {11111111-2222-3333-4444-555555555555}").State | Should -Be 'Foreign'
        (ConvertFrom-HMRemoteSslShow 'Das System kann die angegebene Datei nicht finden.').State | Should -Be 'None'
    }
}

Describe 'Handy-Fernbedienung: Push-Meldungen (ohne Inhalt)' {
    BeforeAll {
        . (Join-Path $script:Root 'Functions\Remote-Core.ps1')
        . (Join-Path $script:Root 'Functions\Remote-Web.ps1')
        function New-HMPushTestState {
            $S = New-HMRemoteState
            $S.Pc = 'TESTPC'; $S.Version = '9.9.9'; $S.PushKey = 'BPUBKEY'
            return $S
        }
        function Invoke-HMPushTest($S, [string]$Method, [string]$Path, $Body = $null, [string]$Token = '') {
            $b = if ($null -ne $Body) { $Body | ConvertTo-Json -Compress } else { '' }
            return (Get-HMRemoteResponse $S @{ Method = $Method; Path = $Path; Query = @{}; Auth = $(if ($Token) { "Bearer $Token" } else { '' }); Origin = ''; Host = '10.0.0.5:8443'; Body = $b; Ip = '10.0.0.9'; Now = (Get-Date) })
        }
    }
    It 'nimmt nur Adressen der Push-Dienste an (kein Senden an beliebige Adressen)' {
        foreach ($ok in @('https://fcm.googleapis.com/fcm/send/abc:def', 'https://web.push.apple.com/QGx', 'https://updates.push.services.mozilla.com/wpush/v2/x', 'https://db5p.notify.windows.com/w/?token=x', 'https://api.push.apple.com/3/x')) {
            Test-HMRemotePushEndpoint $ok | Should -BeTrue -Because $ok
        }
        foreach ($bad in @('', 'http://fcm.googleapis.com/x', 'https://fcm.googleapis.com:8443/x', 'https://fcm.googleapis.com.evil.example/x', 'https://evil.example/fcm.googleapis.com',
                'https://10.0.0.1/x', 'https://localhost/x', 'https://user:pw@fcm.googleapis.com/x', 'https://notify.windows.com/x', 'https://push.apple.com/x', 'file:///c:/x', ('https://fcm.googleapis.com/' + ('a' * 1100)))) {
            Test-HMRemotePushEndpoint $bad | Should -BeFalse -Because $bad
        }
    }
    It 'Ein/Aus nur mit Token; Adresse wird geprueft und mit dem Handy gespeichert' {
        $S = New-HMPushTestState
        $code = Open-HMRemotePairing $S
        $tok = ((Invoke-HMPushTest $S 'POST' '/api/pair' @{ code = $code; name = 'P' }).Text | ConvertFrom-Json).token
        (Invoke-HMPushTest $S 'GET' '/api/push').Code | Should -Be 401
        $j = (Invoke-HMPushTest $S 'GET' '/api/push' -Token $tok).Text | ConvertFrom-Json
        $j.key | Should -Be 'BPUBKEY'; $j.on | Should -BeFalse
        (Invoke-HMPushTest $S 'POST' '/api/push' @{ endpoint = 'https://192.168.1.10/hook' } -Token $tok).Code | Should -Be 400
        (Invoke-HMPushTest $S 'POST' '/api/push' @{ endpoint = 'https://fcm.googleapis.com/fcm/send/xyz' } -Token $tok).Code | Should -Be 200
        ((Invoke-HMPushTest $S 'GET' '/api/push' -Token $tok).Text | ConvertFrom-Json).on | Should -BeTrue
        $S.Devices[(Get-HMRemoteHash $tok)].PushEndpoint | Should -Be 'https://fcm.googleapis.com/fcm/send/xyz'
        $f = Join-Path $TestDrive 'dev.json'
        Save-HMRemoteDevices $S.Devices $f
        (Read-HMRemoteDevices $f)[(Get-HMRemoteHash $tok)].PushEndpoint | Should -Be 'https://fcm.googleapis.com/fcm/send/xyz'
        # manipulierte Datei: fremde Adresse wird beim Lesen verworfen
        (Get-Content -LiteralPath $f -Raw) -replace 'https://fcm.googleapis.com/fcm/send/xyz', 'https://10.0.0.1/x' | Set-Content -LiteralPath $f -Encoding UTF8
        (Read-HMRemoteDevices $f)[(Get-HMRemoteHash $tok)].PushEndpoint | Should -Be ''
        (Invoke-HMPushTest $S 'POST' '/api/push/off' @{} -Token $tok).Code | Should -Be 200
        $S.Devices[(Get-HMRemoteHash $tok)].PushEndpoint | Should -Be ''
        # ohne Schluessel am PC: Einschalten abgelehnt
        $S.PushKey = ''
        (Invoke-HMPushTest $S 'POST' '/api/push' @{ endpoint = 'https://fcm.googleapis.com/fcm/send/xyz' } -Token $tok).Code | Should -Be 409
    }
    It 'Seite und Service Worker: Ein/Aus im Reiter Mehr, Meldung ohne Inhalt, Klick oeffnet die App' {
        $f = Get-HMRemoteWebFiles -Version '1' -Pc 'PC'
        $js = [Text.Encoding]::UTF8.GetString($f['/app.js'].Bytes); $sw = [Text.Encoding]::UTF8.GetString($f['/sw.js'].Bytes)
        [Text.Encoding]::UTF8.GetString($f['/index.html'].Bytes) | Should -Match 'id="nBtn"'
        $js | Should -Match 'function pushToggle'; $js | Should -Match 'userVisibleOnly: true'
        $sw | Should -Match "addEventListener\('push'"; $sw | Should -Match "addEventListener\('notificationclick'"
        $sw | Should -Match 'showNotification'
        $sw | Should -Not -Match 'e\.data'   # kein Inhalt aus der Push-Nachricht
    }
    It 'VAPID: Schluessel DPAPI-geschuetzt, gleich nach Neuladen, JWT ES256 pruefbar (Windows)' -Skip:([Environment]::OSVersion.Platform -ne 'Win32NT') {
        $p = Join-Path $TestDrive 'push.json'
        $v = Get-HMRemoteVapid $p
        $v.Public | Should -Match '^[A-Za-z0-9_-]{87}$'   # 65 Byte b64url
        (Get-Content -LiteralPath $p -Raw) | Should -Not -Match ([regex]::Escape($v.Public))
        (Get-HMRemoteVapid $p).Public | Should -Be $v.Public
        $jwt = New-HMRemoteVapidJwt $v 'https://fcm.googleapis.com' (Get-Date '2026-10-13 12:00')
        $parts = $jwt.Split('.'); $parts.Count | Should -Be 3
        $dec = { param($s) $s = $s.Replace('-', '+').Replace('_', '/'); while ($s.Length % 4) { $s += '=' }; [Convert]::FromBase64String($s) }
        $claims = [Text.Encoding]::UTF8.GetString((& $dec $parts[1])) | ConvertFrom-Json
        $claims.aud | Should -Be 'https://fcm.googleapis.com'; $claims.sub | Should -Match '^https://'
        $claims.exp | Should -Be ([int64]((Get-Date '2026-10-13 12:00').ToUniversalTime() - [datetime]'1970-01-01').TotalSeconds + 43200)
        $sig = & $dec $parts[2]; $sig.Length | Should -Be 64
        $ec = New-Object System.Security.Cryptography.ECDsaCng($v.Key); $ec.HashAlgorithm = [System.Security.Cryptography.CngAlgorithm]::Sha256
        $ec.VerifyData([Text.Encoding]::UTF8.GetBytes("$($parts[0]).$($parts[1])"), $sig) | Should -BeTrue
        $d = [hashtable]::Synchronized(@{}); $d[('a' * 64)] = @{ Name = 'P'; PushEndpoint = 'https://web.push.apple.com/abc' }; $d[('b' * 64)] = @{ Name = 'Q'; PushEndpoint = '' }
        $d[('c' * 64)] = @{ Name = 'R'; PushEndpoint = 'https://fcm.googleapis.com/fcm/send/x' }
        $rq = Get-HMRemotePushRequests $d $v   # wie in UI-Remote: direkt zuweisen
        $rq.Count | Should -Be 2
        foreach ($q in $rq) { $q.Url | Should -BeOfType [string]; $q.Auth | Should -Match ('^vapid t=[^,]+, k=' + [regex]::Escape($v.Public) + '$') }
        # Anmeldung je Dienst zwischengespeichert (Apple: hoechstens stuendlich neu)
        $rq2 = Get-HMRemotePushRequests $d $v
        (@($rq2 | Where-Object { $_.Url -like '*apple*' })[0].Auth) | Should -Be (@($rq | Where-Object { $_.Url -like '*apple*' })[0].Auth)
        $none = Get-HMRemotePushRequests ([hashtable]::Synchronized(@{})) $v
        $none.Count | Should -Be 0
    }
}

Describe 'Handy-Fernbedienung: Restzeit, Verlauf mit Bericht, Zusatzanzeigen' {
    BeforeAll {
        . (Join-Path $script:Root 'Functions\Remote-Core.ps1')
        . (Join-Path $script:Root 'Functions\Remote-Web.ps1')
        . (Join-Path $script:Root 'Functions\UI-Remote.ps1')
        function Invoke-HMHistTest($S, [string]$Method, [string]$Path, $Body = $null, [string]$Token = '') {
            $b = if ($null -ne $Body) { $Body | ConvertTo-Json -Compress } else { '' }
            return (Get-HMRemoteResponse $S @{ Method = $Method; Path = $Path; Query = @{}; Auth = $(if ($Token) { "Bearer $Token" } else { '' }); Origin = ''; Host = '10.0.0.5:8443'; Body = $b; Ip = '10.0.0.9'; Now = (Get-Date) })
        }
    }
    It 'Pruefung v2.1.1: Verlauf tolerant, Meldungsalter vom PC, Netzpfad, Datentraeger aus dem Hintergrund' {
        # N-4: ein defekter Eintrag leert nicht den ganzen Verlauf
        $S = New-HMRemoteState
        Set-HMRemoteHistory $S @([pscustomobject]@{ Id = 'abcdef01'; Title = 'A'; Result = 'ok'; Level = 'OK'; Time = 't'; Seconds = 'abc'; Bytes = 1e30; Report = '' }, [pscustomobject]@{ Id = 'abcdef02'; Title = 'B'; Result = 'ok'; Level = 'OK'; Time = 't'; Seconds = 5; Bytes = 10; Report = '' })
        $h = @($S.HistJson | ConvertFrom-Json | ForEach-Object { $_ })   # 5.1: Array aus ConvertFrom-Json erst entpacken
        $h.Count | Should -Be 2; $h[1].sec | Should -Be 5
        # N-3: Alter nach der Uhr des PCs
        $S.Notice = @{ Json = '{"t":1,"text":"x"}'; At = [datetime]::UtcNow.AddSeconds(-30); Text = 'x' }
        $n = Get-HMRemoteNoticeJson $S | ConvertFrom-Json
        $n.text | Should -Be 'x'; $n.age | Should -BeGreaterOrEqual 29; $n.age | Should -BeLessThan 40
        $S.Notice = $null; Get-HMRemoteNoticeJson $S | Should -Be 'null'
        # B5: Netzpfade (z. B. aus altem Verlauf) gehen nie an den Webserver
        Set-HMRemoteHistory $S @([pscustomobject]@{ Id = 'abcdef03'; Title = 'A'; Result = 'ok'; Level = 'OK'; Time = 't'; Seconds = 1; Bytes = 1; Report = '\\srv\s\Bericht.html' })
        $S.Reports.ContainsKey('abcdef03') | Should -BeFalse
        @($S.HistJson | ConvertFrom-Json | ForEach-Object { $_ })[0].report | Should -BeFalse
        # N-2: Netzpfad erkennen
        Test-HMRemoteNetPath '\\srv\share\Bericht.html' | Should -BeTrue
        Test-HMRemoteNetPath '' | Should -BeFalse
        # N-5: Datentraeger aus dem letzten Hintergrund-Lauf, ohne neue Abfrage
        $script:StatusData = [pscustomobject]@{ Server = @([pscustomobject]@{ Name = 'Gym'; ArchiveAge = 1; Disks = @([pscustomobject]@{ Label = 'H-1'; Age = 0 }) }) }
        $script:HMRemoteVols = @([pscustomobject]@{ FileSystemLabel = 'H-1'; DriveLetter = 'E'; SizeRemaining = [long]5; Size = [long]10 })
        $x = Get-HMRemoteExtra -NoQuery
        $x.sb[0].conn[0].drive | Should -Be 'E:'; [long]$x.sb[0].conn[0].free | Should -Be 5
        $script:HMRemoteVols = $null; $script:StatusData = $null
    }
    It 'Hintergrund-Arbeiten: Ergebnis abholen, haengende abbrechen ohne neue zu starten, Kopien aufraeumen nur eigene Namen' {
        $script:HMRemoteBg.Clear()
        [void](Start-HMRemoteBg 'Vol' { @([pscustomobject]@{ FileSystemLabel = 'X'; DriveLetter = 'E'; SizeRemaining = [long]1; Size = [long]2 }) } @() @{} 60)
        for ($i = 0; $i -lt 50 -and -not $script:HMRemoteBg[0].Handle.IsCompleted; $i++) { Start-Sleep -Milliseconds 100 }
        Receive-HMRemoteBg | Should -BeTrue
        $script:HMRemoteVols[0].DriveLetter | Should -Be 'E'
        $script:HMRemoteBg.Count | Should -Be 0
        # haengt: nach Zeitlimit Abbruch, solange er laeuft gilt die Art als belegt (keine weitere Abfrage -> kein Leck)
        [void](Start-HMRemoteBg 'Vol' { Start-Sleep -Seconds 30 } @() @{} 0)
        Start-Sleep -Milliseconds 200
        Receive-HMRemoteBg | Should -BeFalse
        Test-HMRemoteBgBusy 'Vol' | Should -BeTrue
        for ($i = 0; $i -lt 50 -and $script:HMRemoteBg.Count; $i++) { Start-Sleep -Milliseconds 100; [void](Receive-HMRemoteBg) }
        $script:HMRemoteBg.Count | Should -Be 0
        # B7: Abfrage scheitert -> zuletzt bekannte Platten bleiben
        $script:HMRemoteVols = @([pscustomobject]@{ FileSystemLabel = 'H-1'; DriveLetter = 'E'; SizeRemaining = [long]1; Size = [long]2 })
        [void](Start-HMRemoteBg 'Vol' { throw 'Zeitlimit' } @() @{} 60)
        for ($i = 0; $i -lt 50 -and -not $script:HMRemoteBg[0].Handle.IsCompleted; $i++) { Start-Sleep -Milliseconds 100 }
        Receive-HMRemoteBg | Should -BeFalse
        @($script:HMRemoteVols).Count | Should -Be 1
        [void](Start-HMRemoteBg 'Vol' { Write-Error 'Speicherdienst'; @() } @() @{} 60)
        for ($i = 0; $i -lt 50 -and -not $script:HMRemoteBg[0].Handle.IsCompleted; $i++) { Start-Sleep -Milliseconds 100 }
        Receive-HMRemoteBg | Should -BeFalse
        @($script:HMRemoteVols).Count | Should -Be 1
        $script:HMRemoteVols = $null
        # Aufraeumen: nur <8 hex>.html, die nicht mehr im Verlauf stehen
        $old = $env:LOCALAPPDATA
        try {
            $env:LOCALAPPDATA = Join-Path $TestDrive 'lad'
            $d = Get-HMRemoteReportDir -Create
            $d | Should -Not -BeNullOrEmpty
            foreach ($n in 'aaaaaaaa.html', 'bbbbbbbb.html', 'fremd.html') { Set-Content -LiteralPath (Join-Path $d $n) -Value 'x' }
            Clear-HMRemoteReportCopies @([pscustomobject]@{ Id = 'aaaaaaaa' })
            (Test-Path (Join-Path $d 'aaaaaaaa.html')) | Should -BeTrue
            (Test-Path (Join-Path $d 'bbbbbbbb.html')) | Should -BeFalse
            (Test-Path (Join-Path $d 'fremd.html')) | Should -BeTrue
        } finally { $env:LOCALAPPDATA = $old }
    }
    It 'Zeitplaene vom Handy: nur mit Einmal-Bestaetigung (Geraet, Kennung, 30 s), eine Anfrage zur Zeit' {
        $S = New-HMRemoteState; $S.Pc = 'PC'; $S.Version = '1'
        $code = Open-HMRemotePairing $S
        $tok = ((Invoke-HMHistTest $S 'POST' '/api/pair' @{ code = $code; name = 'A' }).Text | ConvertFrom-Json).token
        $code2 = $S.Pair.Code
        $tok2 = ((Invoke-HMHistTest $S 'POST' '/api/pair' @{ code = $code2; name = 'B' }).Text | ConvertFrom-Json).token
        $S.SchedMap['0123456789abcdef'] = @{ Key = 'S|\HUMig\|Server-Backup - X'; Kind = 'Server'; Title = 'X'; Confirm = 'Server-Backup X starten?' }
        # unbekannte/ungueltige Kennung
        (Invoke-HMHistTest $S 'POST' '/api/schedule/prepare' @{ id = '../x' } -Token $tok).Code | Should -Be 404
        (Invoke-HMHistTest $S 'POST' '/api/schedule/prepare' @{ id = 'ffffffffffffffff' } -Token $tok).Code | Should -Be 404
        # ohne Bestaetigung kein Start
        (Invoke-HMHistTest $S 'POST' '/api/schedule/run' @{ id = '0123456789abcdef'; nonce = ('a' * 32) } -Token $tok).Code | Should -Be 403
        $p = (Invoke-HMHistTest $S 'POST' '/api/schedule/prepare' @{ id = '0123456789abcdef' } -Token $tok).Text | ConvertFrom-Json
        $p.ok | Should -BeTrue; $p.nonce | Should -Match '^[0-9a-f]{32}$'; $p.text | Should -Be 'Server-Backup X starten?'
        # Bestaetigung gilt nur fuer dieses Geraet
        (Invoke-HMHistTest $S 'POST' '/api/schedule/run' @{ id = '0123456789abcdef'; nonce = $p.nonce } -Token $tok2).Code | Should -Be 403
        $p = (Invoke-HMHistTest $S 'POST' '/api/schedule/prepare' @{ id = '0123456789abcdef' } -Token $tok).Text | ConvertFrom-Json
        $r = Invoke-HMHistTest $S 'POST' '/api/schedule/run' @{ id = '0123456789abcdef'; nonce = $p.nonce } -Token $tok
        $r.Code | Should -Be 202
        $S.SchedReq.Entry.Key | Should -Be 'S|\HUMig\|Server-Backup - X'; $S.SchedReq.By | Should -Be 'A'
        # einmalig verbraucht
        (Invoke-HMHistTest $S 'POST' '/api/schedule/run' @{ id = '0123456789abcdef'; nonce = $p.nonce } -Token $tok).Code | Should -Be 403
        # solange eine Anfrage offen ist, keine zweite
        $p = (Invoke-HMHistTest $S 'POST' '/api/schedule/prepare' @{ id = '0123456789abcdef' } -Token $tok).Text | ConvertFrom-Json
        (Invoke-HMHistTest $S 'POST' '/api/schedule/run' @{ id = '0123456789abcdef'; nonce = $p.nonce } -Token $tok).Code | Should -Be 409
        # abgelaufen
        $S.SchedReq = $null
        $p = (Invoke-HMHistTest $S 'POST' '/api/schedule/prepare' @{ id = '0123456789abcdef' } -Token $tok).Text | ConvertFrom-Json
        $S.SchedNonce[$p.nonce].Exp = (Get-Date).AddSeconds(-1)
        (Invoke-HMHistTest $S 'POST' '/api/schedule/run' @{ id = '0123456789abcdef'; nonce = $p.nonce } -Token $tok).Code | Should -Be 403
        # je Handy hoechstens 3 offene Bestaetigungen - ein anderes Handy ist davon nicht betroffen
        $S.SchedNonce.Clear()
        1..3 | ForEach-Object { (Invoke-HMHistTest $S 'POST' '/api/schedule/prepare' @{ id = '0123456789abcdef' } -Token $tok).Code | Should -Be 200 }
        (Invoke-HMHistTest $S 'POST' '/api/schedule/prepare' @{ id = '0123456789abcdef' } -Token $tok).Code | Should -Be 429
        (Invoke-HMHistTest $S 'POST' '/api/schedule/prepare' @{ id = '0123456789abcdef' } -Token $tok2).Code | Should -Be 200
        $S.SchedNonce.Clear()
        # Liste fuer das Handy: nur Kennung und Text, keine Pfade; nicht startbare ohne Kennung
        Set-HMRemoteSchedList $S @{ Wb = $false; Items = @(
                @{ Kind = 'Server'; Title = 'Gym - taeglich'; TaskPath = '\HUMig\'; TaskName = 'Server-Backup - Gym'; Problem = ''; As = 'SYSTEM'; Key = 'S|\HUMig\|Server-Backup - Gym'; Info = @{ Running = $false; Disabled = $false; Next = '15.10. 22:00'; Last = '14.10. 22:00'; Result = 0 } },
                @{ Kind = 'Au'; Title = 'App-Updates dieses PCs'; TaskPath = '\HUMig\'; TaskName = 'HUMig App-Updates'; Problem = 'Aufgabe veraendert - am PC pruefen'; As = 'SYSTEM'; Key = 'A|\HUMig\|HUMig App-Updates'; Info = $null }) }
        $l = @($S.SchedJson | ConvertFrom-Json | ForEach-Object { $_ })
        $l.Count | Should -Be 2
        $l[0].id | Should -Match '^[0-9a-f]{16}$'; $l[0].ok | Should -BeTrue; $l[0].sub | Should -Match 'erfolgreich'
        $l[1].id | Should -Be ''; $l[1].ok | Should -BeFalse; $l[1].note | Should -Match 'veraendert'
        $S.SchedJson | Should -Not -Match 'HUMig\\\\|Server-Backup - Gym'
        $S.SchedMap.Count | Should -Be 1
        $S.SchedMap[$l[0].id].Key | Should -Be 'S|\HUMig\|Server-Backup - Gym'
        # Kennung bleibt bei neuem Listenaufbau gleich (laufende Bestaetigung scheitert nicht)
        $id1 = $l[0].id
        Set-HMRemoteSchedList $S @{ Wb = $false; Items = @(@{ Kind = 'Server'; Title = 'Gym - taeglich'; TaskPath = '\HUMig\'; TaskName = 'Server-Backup - Gym'; Problem = ''; As = 'SYSTEM'; Key = 'S|\HUMig\|Server-Backup - Gym'; Info = @{ Running = $false; Disabled = $false; Next = ''; Last = ''; Result = $null } }) }
        @($S.SchedJson | ConvertFrom-Json | ForEach-Object { $_ })[0].id | Should -Be $id1
        (Invoke-HMHistTest $S 'GET' '/api/state' -Token $tok).Text | ConvertFrom-Json | ForEach-Object { @($_.sched).Count } | Should -Be 1
    }
    It 'Zeitplaene vom Handy: Grenzen im UI (ausgeschaltet, 1/min je Aufgabe, 5 in 10 min), Ende erst nach dem Lauf' {
        $S = New-HMRemoteState
        $script:HMSchedRate.Clear(); $script:HMSchedWatch.Clear(); $script:HMRemoteBg.Clear()
        $script:UserMode = $false
        $script:Settings = [pscustomobject]@{ Remote = [pscustomobject]@{ SchedServer = $false } }
        function Start-HMRemoteBg { param($Kind, $Script, $Arguments, $Data, $LimitSec) $script:BgStarts += , @($Kind, $Arguments[4]); return $true }
        function Out-Console { param($t, $l) }
        $script:BgStarts = @()
        $e = @{ Key = 'S|\HUMig\|Server-Backup - X'; Kind = 'Server'; Title = 'X' }
        $S.SchedReq = @{ Entry = $e; By = 'A'; DevId = 'd1'; Ip = '10.0.0.9'; At = (Get-Date) }
        Invoke-HMRemoteSchedReq $S
        $script:BgStarts.Count | Should -Be 0
        ($S.SchedMsg | ConvertFrom-Json).text | Should -Match 'ausgeschaltet'
        $script:Settings.Remote.SchedServer = $true
        $S.SchedReq = @{ Entry = $e; By = 'A'; DevId = 'd1'; Ip = '10.0.0.9'; At = (Get-Date) }
        Invoke-HMRemoteSchedReq $S
        $script:BgStarts.Count | Should -Be 1; $script:BgStarts[0][1] | Should -Be 'S|\HUMig\|Server-Backup - X'
        $S.SchedReq = @{ Entry = $e; By = 'A'; DevId = 'd1'; Ip = '10.0.0.9'; At = (Get-Date) }
        Invoke-HMRemoteSchedReq $S
        $script:BgStarts.Count | Should -Be 1
        ($S.SchedMsg | ConvertFrom-Json).text | Should -Match 'einmal pro Minute'
        foreach ($i in 2..6) { $S.SchedReq = @{ Entry = @{ Key = "K$i"; Kind = 'Server'; Title = "T$i" }; By = 'A'; DevId = 'd1'; Ip = '10.0.0.9'; At = (Get-Date) }; Invoke-HMRemoteSchedReq $S }
        $script:BgStarts.Count | Should -Be 5
        ($S.SchedMsg | ConvertFrom-Json).text | Should -Match '5 Starts'
        # Benutzer-Modus: Server-Backup und App-Updates nie
        $script:UserMode = $true
        (Get-HMRemoteSchedKinds).Server | Should -BeFalse
        $script:UserMode = $false
        # Ende: erst wenn LastRunTime >= Start und nicht mehr laufend; 267009 (laeuft) zaehlt nicht
        Remove-Item function:\Start-HMRemoteBg; Remove-Item function:\Out-Console
        $script:Pushes = @()
        function Send-HMRemotePush { param($Text) $script:Pushes += $Text }
        $at = (Get-Date).AddSeconds(-30)
        [void]$script:HMSchedWatch.Add(@{ Key = 'K'; Kind = 'Server'; What = "Server-Backup 'X'"; At = $at })
        function Out-Console { param($t, $l) }
        Update-HMRemoteSchedWatch @{ Items = @(@{ Key = 'K'; Info = @{ Running = $true; LastRun = $at.AddSeconds(2); Result = 267009 } }) }
        $script:Pushes.Count | Should -Be 0
        Update-HMRemoteSchedWatch @{ Items = @(@{ Key = 'K'; Info = @{ Running = $false; LastRun = $at.AddMinutes(-60); Result = 0 } }) }
        $script:Pushes.Count | Should -Be 0
        Update-HMRemoteSchedWatch @{ Items = @(@{ Key = 'K'; Info = @{ Running = $false; LastRun = $at.AddSeconds(2); Result = 1 } }) }
        $script:Pushes.Count | Should -Be 1; $script:Pushes[0] | Should -Match 'mit Warnungen'
        $script:HMSchedWatch.Count | Should -Be 0
        # nicht angefangen: nach 2 Minuten Meldung statt stundenlang zu warten
        $at2 = (Get-Date).AddMinutes(-3)
        [void]$script:HMSchedWatch.Add(@{ Key = 'K'; Kind = 'Server'; What = "Server-Backup 'X'"; At = $at2 })
        Update-HMRemoteSchedWatch @{ Items = @(@{ Key = 'K'; Info = @{ Running = $false; LastRun = $at2.AddHours(-20); Result = 0 } }) }
        $script:Pushes.Count | Should -Be 2; $script:Pushes[1] | Should -Match 'nicht gelaufen'
        $script:HMSchedWatch.Count | Should -Be 0
        Remove-Item function:\Send-HMRemotePush; Remove-Item function:\Out-Console
        $script:HMSchedRate.Clear(); $script:Settings = $null
    }
    It 'Push-Meldung: Kurzform mit Menge und Dauer' {
        if (-not (Get-Command Format-HMSize -ErrorAction SilentlyContinue)) { . (Join-Path $script:Root 'Functions\Migration-Engine.ps1') }
        $d = [char]0x00B7
        New-HMRemotePushText 'Backup' 'erfolgreich' 312 8600000000 | Should -Match ('^Backup - erfolgreich ' + $d + ' 8[.,]01 GB ' + $d + ' 5 min 12 s$')
        New-HMRemotePushText 'App-Updates' 'mit Fehlern' 420 0 | Should -Be ('App-Updates - mit Fehlern ' + $d + ' 7 min')
        New-HMRemotePushText 'Backup' 'abgebrochen' $null $null | Should -Be 'Backup - abgebrochen'
    }
    It 'Vorgang: Menge (geplant/geschrieben) und geschaetzte Restzeit' {
        $job = @{ Started = (Get-Date).AddSeconds(-60); Progress = 25; Status = 'x'; Cancel = $false; PlanTotal = [long]4GB; DoneBytes = [long]1GB; CurBytes = [long]512MB }
        $j = ConvertTo-HMRemoteJobJson $job 'Backup' | ConvertFrom-Json
        [long]$j.bytesTotal | Should -Be ([long]4GB); [long]$j.bytesDone | Should -Be ([long]1.5GB)
        $j.eta | Should -BeGreaterThan 170; $j.eta | Should -BeLessThan 190   # 60 s fuer 25 % -> ca. 180 s
        $job2 = @{ Started = (Get-Date).AddSeconds(-5); Progress = 1; Status = 'x'; Cancel = $false }
        $j2 = ConvertTo-HMRemoteJobJson $job2 'Backup' | ConvertFrom-Json
        $j2.PSObject.Properties.Name | Should -Not -Contain 'eta'
        $j2.PSObject.Properties.Name | Should -Not -Contain 'bytesTotal'
    }
    It 'Verlauf: hoechstens 10, Anzeige ohne Pfade; Bericht nur ueber Einmal-Adresse (60 s), mit eigener Richtlinie' {
        $oldAppData = $env:APPDATA; $oldLocal = $env:LOCALAPPDATA
        $env:APPDATA = Join-Path $TestDrive 'appdata'; $env:LOCALAPPDATA = Join-Path $TestDrive 'localappdata'   # echte Berichtskopien nie anfassen
        try {
        $S = New-HMRemoteState; $S.Pc = 'PC'; $S.Version = '1'
        $code = Open-HMRemotePairing $S
        $tok = ((Invoke-HMHistTest $S 'POST' '/api/pair' @{ code = $code; name = 'P' }).Text | ConvertFrom-Json).token
        $script:HMRemote = @{ S = $S }
        $rep = Join-Path $TestDrive 'Bericht_Backup.html'; Set-Content -LiteralPath $rep -Value '<html><body><h1>Bericht</h1><script>alert(1)</script></body></html>' -Encoding UTF8
        $script:JobReport = $rep
        for ($i = 0; $i -lt 12; $i++) { Add-HMRemoteHistory @{ Started = (Get-Date).AddSeconds(-90); DoneBytes = [long]0 } "Backup $i" 'erfolgreich' 'OK' ([pscustomobject]@{ SizeBytes = [long]2GB }) }
        $h = $S.HistJson | ConvertFrom-Json
        @($h).Count | Should -Be 10
        $h[0].title | Should -Be 'Backup 11'; $h[0].report | Should -BeTrue; [long]$h[0].bytes | Should -Be ([long]2GB)
        $S.HistJson | Should -Not -Match ([regex]::Escape('Bericht_Backup.html'))
        $st = (Invoke-HMHistTest $S 'GET' '/api/state' -Token $tok).Text | ConvertFrom-Json
        @($st.hist).Count | Should -Be 10
        (Invoke-HMHistTest $S 'POST' '/api/report' @{ id = $h[0].id }).Code | Should -Be 401
        (Invoke-HMHistTest $S 'POST' '/api/report' @{ id = 'deadbeef' } -Token $tok).Code | Should -Be 404
        (Invoke-HMHistTest $S 'POST' '/api/report' @{ id = '../../x' } -Token $tok).Code | Should -Be 404
        $r = (Invoke-HMHistTest $S 'POST' '/api/report' @{ id = $h[0].id } -Token $tok).Text | ConvertFrom-Json
        $r.url | Should -Match '^/report/[A-Za-z0-9_-]{43}$'
        $g = Invoke-HMHistTest $S 'GET' $r.url
        $g.Code | Should -Be 200
        [Text.Encoding]::UTF8.GetString($g.Bytes) | Should -Match 'Bericht'
        $g.Headers['Content-Security-Policy'] | Should -Match 'sandbox'
        $g.Headers['Content-Security-Policy'] | Should -Not -Match 'script-src'
        (Invoke-HMHistTest $S 'GET' $r.url).Code | Should -Be 404   # nur einmal
        # Bericht ist keine HTML-Datei: nicht ausliefern
        $S.Reports['abcdef01'] = (Join-Path $TestDrive 'x.txt'); Set-Content -LiteralPath (Join-Path $TestDrive 'x.txt') -Value 'geheim'
        $r2 = (Invoke-HMHistTest $S 'POST' '/api/report' @{ id = 'abcdef01' } -Token $tok).Text | ConvertFrom-Json
        (Invoke-HMHistTest $S 'GET' $r2.url).Code | Should -Be 404
        } finally { $env:APPDATA = $oldAppData; $env:LOCALAPPDATA = $oldLocal; $script:HMRemote = $null; $script:JobReport = $null }
    }
    It 'Bericht-Pfad: Restore-Datei bzw. Server-Backup-Ordner (Bericht.html)' {
        $script:JobReport = $null
        Get-HMRemoteReportPath @{ Result = [pscustomobject]@{ Report = 'E:\B\Bericht_Restore_PC_1.html' } } | Should -Be 'E:\B\Bericht_Restore_PC_1.html'
        Get-HMRemoteReportPath @{ Result = [pscustomobject]@{ Report = 'G:\HUMig-ServerBackup\2026-10-13_1302_EUGym' } } | Should -Match 'Bericht\.html$'
        Get-HMRemoteReportPath @{ Result = [pscustomobject]@{ Status = 'OK' } } | Should -Be ''
    }
    It 'Zusatzanzeigen: naechste Platte laut Rotation, App-Updates je PC mit Fehlern; Push-Text nur vom PC' {
        $script:UserMode = $false
        $script:AuHistFile = Join-Path $TestDrive 'auhist.json'
        $now = (Get-Date).ToString('yyyy-MM-dd HH:mm')
        ConvertTo-Json -InputObject @(@{ Date = $now; Computer = 'PC1'; Name = 'App A'; Status = 'OK'; Text = '' }, @{ Date = $now; Computer = 'PC1'; Name = 'App B'; Status = 'Error'; Text = 'Installer 1603' }) | Set-Content -LiteralPath $script:AuHistFile -Encoding UTF8
        $script:AuLastSearch = @{ Time = '13.10. 10:00'; ByPc = @{ 'PC1' = 3 } }
        $script:AuSchedData = @{}
        $script:StatusData = [pscustomobject]@{ Server = @([pscustomobject]@{ Name = 'Gym'; ArchiveAge = 40; Disks = @([pscustomobject]@{ Label = 'H-1'; Age = 0 }, [pscustomobject]@{ Label = 'H-2'; Age = 9 }, [pscustomobject]@{ Label = 'H-3'; Age = 4 }, [pscustomobject]@{ Label = 'H-A1'; Age = 50; Archive = $true }) }) }
        $x = Get-HMRemoteExtra
        $pc1 = @($x.apps | Where-Object { $_.pc -eq 'PC1' })[0]
        $pc1.ok | Should -Be 1; $pc1.failed | Should -Be 1; $pc1.found | Should -Be 3
        $pc1.fails[0].name | Should -Be 'App B'; $pc1.fails[0].text | Should -Be 'Installer 1603'
        $x.sb[0].next | Should -Be 'H-2'
        $script:StatusData.Server[0].Disks[2].Age = $null
        (Get-HMRemoteExtra).sb[0].next | Should -Be 'H-3'   # nie gesichert zuerst
        $j = ConvertTo-Json -Compress -Depth 6 -InputObject $x
        { $j | ConvertFrom-Json } | Should -Not -Throw
        $f = Get-HMRemoteWebFiles -Version '1' -Pc 'PC'
        $sw = [Text.Encoding]::UTF8.GetString($f['/sw.js'].Bytes)
        $sw | Should -Match 'nt\.text'; $sw | Should -Not -Match 'e\.data'
        $js = [Text.Encoding]::UTF8.GetString($f['/app.js'].Bytes)
        $js | Should -Match 'function renderHist'; $js | Should -Match 'function openReport'; $js | Should -Not -Match 'innerHTML'
    }
}

Describe 'Handy-Fernbedienung: Zeitplaene vom Handy - echte Aufgabenplanung (Windows, Administrator)' {
    It 'Zeitplaene vom Handy: echte Aufgaben pruefen - unveraendert startbar, veraendert/fremd gesperrt' -Skip:(-not (([Environment]::OSVersion.Platform -eq 'Win32NT') -and ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))) {
        . (Join-Path $script:Root 'Functions\Remote-Core.ps1')
        . (Join-Path $script:Root 'Functions\Remote-Web.ps1')
        . (Join-Path $script:Root 'Functions\UI-Remote.ps1')
        $app = Join-Path $TestDrive 'app'
        New-Item -ItemType Directory -Path (Join-Path $app 'Functions'), (Join-Path $app 'Config') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $app 'Functions\ServerBackup-Task.ps1') -Value '# Test'
        '{"Profiles":[{"Name":"CITest"}],"Renames":[]}' | Set-Content -LiteralPath (Join-Path $app 'Config\serverbackup.json')
        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $pr = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $trg = New-ScheduledTaskTrigger -Once -At (Get-Date).AddYears(5)
        $good = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$app\Functions\ServerBackup-Task.ps1`" -ProfileName `"CITest`" -Explicit"
        $more = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$app\Functions\ServerBackup-Task.ps1`" -ProfileName `"CITest`" -Command `"x`""
        $evil = New-ScheduledTaskAction -Execute 'C:\Windows\System32\cmd.exe' -Argument '/c echo x'
        try {
            Register-ScheduledTask -TaskPath '\HUMig\' -TaskName 'Server-Backup - CITest - ok' -Action $good -Principal $pr -Trigger $trg -Force | Out-Null
            Register-ScheduledTask -TaskPath '\HUMig\' -TaskName 'Server-Backup - CITest - zwei' -Action @($good, $evil) -Principal $pr -Trigger $trg -Force | Out-Null
            Register-ScheduledTask -TaskPath '\HUMig\' -TaskName 'Server-Backup - CITest - fremd' -Action $evil -Principal $pr -Trigger $trg -Force | Out-Null
            Register-ScheduledTask -TaskPath '\HUMig\' -TaskName 'Server-Backup - CITest - mehr' -Action $more -Principal $pr -Trigger $trg -Force | Out-Null
            $adm = @(); try { $adm = @(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop | ForEach-Object { "$($_.SID)" }) } catch { }
            $res = & $script:HMSchedScript 'List' @{ Backup = $false; Server = $true; Au = $false } $app $true '' ([string[]]$adm)
            $mine = @($res.Items | Where-Object { $_.TaskName -like 'Server-Backup - CITest*' })
            $mine.Count | Should -Be 4
            (@($mine | Where-Object { $_.TaskName -like '*mehr' })[0]).Problem | Should -Match 'veraendert'
            (@($mine | Where-Object { $_.TaskName -like '*ok' })[0]).Problem | Should -BeIn @('', 'Programmordner fuer Benutzer beschreibbar - Start vom Handy gesperrt')
            (@($mine | Where-Object { $_.TaskName -like '*zwei' })[0]).Problem | Should -Match 'veraendert'
            (@($mine | Where-Object { $_.TaskName -like '*fremd' })[0]).Problem | Should -Match 'veraendert'
            # Start einer veraenderten Aufgabe wird abgelehnt (vor Start-ScheduledTask)
            $r = & $script:HMSchedScript 'Run' @{ Backup = $false; Server = $true; Au = $false } $app $true 'S|\HUMig\|Server-Backup - CITest - zwei'
            $r.Ok | Should -BeFalse; $r.Text | Should -Match 'veraendert'
            # Benutzer-Modus: keine SYSTEM-Aufgaben
            $res2 = & $script:HMSchedScript 'List' @{ Backup = $false; Server = $true; Au = $false } $app $false ''
            @($res2.Items).Count | Should -Be 0
            # abgesicherter Programmordner, aber im uebergeordneten Ordner duerfen Benutzer aendern (umbenennen) -> gesperrt
            $open = Join-Path $TestDrive 'offen'; $app2 = Join-Path $open 'app'
            New-Item -ItemType Directory -Path (Join-Path $app2 'Functions'), (Join-Path $app2 'Config') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $app2 'Functions\ServerBackup-Task.ps1') -Value '# Test'
            '{"Profiles":[{"Name":"CITest"}],"Renames":[]}' | Set-Content -LiteralPath (Join-Path $app2 'Config\serverbackup.json')
            & icacls.exe $app2 /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' /Q | Out-Null
            & icacls.exe $app2 /setowner '*S-1-5-32-544' /T /Q | Out-Null
            & icacls.exe $open /grant '*S-1-5-32-545:(OI)(CI)M' /Q | Out-Null
            $a2 = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$app2\Functions\ServerBackup-Task.ps1`" -ProfileName `"CITest`""
            Register-ScheduledTask -TaskPath '\HUMig\' -TaskName 'Server-Backup - CITest - offen' -Action $a2 -Principal $pr -Trigger $trg -Force | Out-Null
            $res3 = & $script:HMSchedScript 'List' @{ Backup = $false; Server = $true; Au = $false } $app2 $true '' ([string[]]$adm)
            (@($res3.Items | Where-Object { $_.TaskName -eq 'Server-Backup - CITest - offen' })[0]).Problem | Should -Match 'Programmordner'
        } finally {
            foreach ($n in 'ok', 'zwei', 'fremd', 'mehr', 'offen') { Unregister-ScheduledTask -TaskPath '\HUMig\' -TaskName "Server-Backup - CITest - $n" -Confirm:$false -ErrorAction SilentlyContinue }
        }
    }
}

Describe 'Handy-Fernbedienung: echtes HTTPS mit eigener CA (Windows, Administrator)' {
    BeforeAll {
        . (Join-Path $script:Root 'Functions\Remote-Core.ps1')
        . (Join-Path $script:Root 'Functions\Remote-Web.ps1')
        $script:RemOk = ([Environment]::OSVersion.Platform -eq 'Win32NT') -and ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    It 'CA mit Namensbeschraenkung, Server-Zertifikat, Bindung, Webserver: Seite laden und koppeln' -Skip:(-not (([Environment]::OSVersion.Platform -eq 'Win32NT') -and ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))) {
        $port = Get-HMRemoteFreePort 18442
        $port | Should -BeGreaterThan 0
        $ca = $null; $cert = $null; $S = $null; $ps = $null; $rs = $null
        try {
            $ca = New-HMRemoteCa
            $ca.HasPrivateKey | Should -BeTrue
            @($ca.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.30' -and $_.Critical }).Count | Should -Be 1
            @($ca.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.19' }).Count | Should -Be 1
            (Get-HMRemoteCa).Thumbprint | Should -Be $ca.Thumbprint
            # Inhalt der Namensbeschraenkung: Hostname + private Bereiche
            $nc = (@($ca.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.30' })[0]).Format($true)
            $nc | Should -Match ([regex]::Escape((Get-HMRemoteHostNames)[0]))
            $nc | Should -Match '10\.0\.0\.0'
            $nc | Should -Match '192\.168\.0\.0'
            # Firewall-Regel nur fuer http.sys (Programm System)
            Set-HMRemoteFirewall 'HUMig-Remote-CI' $port @('LocalSubnet')
            try { "$((Get-NetFirewallRule -Name 'HUMig-Remote-CI' | Get-NetFirewallApplicationFilter).Program)" | Should -Be 'System' }
            finally { Remove-HMRemoteFirewall 'HUMig-Remote-CI' }
            $cert = New-HMRemoteServerCert $ca @('127.0.0.1', '10.1.1.5')
            Test-HMRemoteServerCert $cert $ca @('10.1.1.5') | Should -BeTrue
            Test-HMRemoteServerCert $cert $ca @('10.1.1.6') | Should -BeFalse
            (Get-HMRemoteCertSan $cert).IPs | Should -Contain '10.1.1.5'
            # Kette baut nur mit der eigenen CA (als vertrauenswuerdig behandelt)
            $ch = New-Object System.Security.Cryptography.X509Certificates.X509Chain
            $ch.ChainPolicy.RevocationMode = 'NoCheck'
            $ch.ChainPolicy.VerificationFlags = 'AllowUnknownCertificateAuthority'
            [void]$ch.ChainPolicy.ExtraStore.Add($ca)
            [void]$ch.Build($cert)
            $ch.ChainElements.Count | Should -Be 2
            $ch.ChainElements[1].Certificate.Thumbprint | Should -Be $ca.Thumbprint
            # Webserver (127.0.0.1 ist kein privater Bereich der Namensbeschraenkung - daher eigene Pruefung ohne Namensabgleich)
            Set-HMRemoteBinding $port $cert.Thumbprint
            (Get-HMRemoteBinding $port).State | Should -Be 'Ours'
            $S = New-HMRemoteState
            $S.Port = $port; $S.Pc = 'CI'; $S.Version = '9.9.9'
            $S.Static = Get-HMRemoteWebFiles -Version '9.9.9' -Pc 'CI' -Icon192 ([byte[]](1)) -Icon512 ([byte[]](2)) -Ca $ca.RawData
            $code = Open-HMRemotePairing $S
            $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace(); $rs.Open()
            $rs.SessionStateProxy.SetVariable('S', $S)
            $ps = [PowerShell]::Create(); $ps.Runspace = $rs
            $core = (Join-Path $script:Root 'Functions\Remote-Core.ps1') -replace "'", "''"
            [void]$ps.AddScript(". '$core'`nStart-HMRemoteListenerLoop `$S")
            $h = $ps.BeginInvoke()
            for ($i = 0; $i -lt 50 -and -not $S.Listening -and -not $S.Error; $i++) { Start-Sleep -Milliseconds 100 }
            $S.Error | Should -BeNullOrEmpty
            $S.Listening | Should -BeTrue
            $caTp = $ca.Thumbprint
            $old = [Net.ServicePointManager]::ServerCertificateValidationCallback
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            $caObj = $ca
            # Kette selbst mit der eigenen CA bauen (nicht im Speicher 'Vertrauenswuerdige Stammzertifizierungsstellen')
            [Net.ServicePointManager]::ServerCertificateValidationCallback = {
                param($s, $c, $chain, $err)
                $x = New-Object System.Security.Cryptography.X509Certificates.X509Chain
                $x.ChainPolicy.RevocationMode = 'NoCheck'
                $x.ChainPolicy.VerificationFlags = 'AllowUnknownCertificateAuthority'
                [void]$x.ChainPolicy.ExtraStore.Add($caObj)
                [void]$x.Build((New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $c))
                return ($x.ChainElements.Count -ge 2 -and $x.ChainElements[1].Certificate.Thumbprint -eq $caTp)
            }.GetNewClosure()
            try {
                $wc = New-Object System.Net.WebClient
                $html = $wc.DownloadString("https://127.0.0.1:$port/")
                $html | Should -Match 'Mit HUMig koppeln'
                $wc.ResponseHeaders['Content-Security-Policy'] | Should -Match "default-src 'none'"
                $wc.ResponseHeaders['X-Frame-Options'] | Should -Be 'DENY'
                $wc2 = New-Object System.Net.WebClient
                $wc2.Headers['Content-Type'] = 'application/json'
                $res = $wc2.UploadString("https://127.0.0.1:$port/api/pair", 'POST', (@{ code = $code; name = 'CI' } | ConvertTo-Json -Compress)) | ConvertFrom-Json
                $res.ok | Should -BeTrue
                $wc3 = New-Object System.Net.WebClient
                $wc3.Headers['Authorization'] = "Bearer $($res.token)"
                ($wc3.DownloadString("https://127.0.0.1:$port/api/state") | ConvertFrom-Json).pc | Should -Be 'CI'
                $wc4 = New-Object System.Net.WebClient
                $e = $null; try { [void]$wc4.DownloadString("https://127.0.0.1:$port/api/state") } catch { $e = $_ }
                "$e" | Should -Match '401'
            } finally { [Net.ServicePointManager]::ServerCertificateValidationCallback = $old }
        } finally {
            if ($S) { $S.Run = $false; for ($i = 0; $i -lt 30 -and $S.Listening; $i++) { Start-Sleep -Milliseconds 100 } }
            try { if ($ps) { $ps.Dispose() }; if ($rs) { $rs.Dispose() } } catch { }
            Remove-HMRemoteBinding $port
            foreach ($c in @($cert, $ca)) { if ($c) { Remove-Item -LiteralPath "Cert:\LocalMachine\My\$($c.Thumbprint)" -DeleteKey -ErrorAction SilentlyContinue } }
        }
        (Get-HMRemoteBinding $port).State | Should -Be 'None'
    }
    It 'Namensbeschraenkung greift: Zertifikat fuer eine oeffentliche Adresse wird abgelehnt' -Skip:(-not (([Environment]::OSVersion.Platform -eq 'Win32NT') -and ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))) {
        $ca = $null; $bad = $null; $good = $null; $root = $null; $res = ''
        try {
            $ca = New-HMRemoteCa
            # Die Kette wird nur bei vertrauter Stammstelle vollstaendig geprueft - CA voruebergehend vertrauen (nur auf dem CI-Rechner)
            $root = New-Object System.Security.Cryptography.X509Certificates.X509Store('Root', 'LocalMachine')
            $root.Open('ReadWrite'); $root.Add((New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(, $ca.RawData)))
            $bad = New-SelfSignedCertificate -Type Custom -Subject 'CN=HUMig Test' -Signer $ca -KeyExportPolicy NonExportable -CertStoreLocation 'Cert:\LocalMachine\My' -TextExtension @('2.5.29.17={text}IPAddress=8.8.8.8', '2.5.29.37={text}1.3.6.1.5.5.7.3.1')
            $good = New-HMRemoteServerCert $ca @('10.1.1.5')
            $st = {
                param($c)
                $ch = New-Object System.Security.Cryptography.X509Certificates.X509Chain
                $ch.ChainPolicy.RevocationMode = 'NoCheck'
                [void]$ch.Build($c)
                @($ch.ChainStatus | ForEach-Object { "$($_.Status)" }) -join ','
            }
            $res = & $st $bad
            (& $st $good) | Should -Not -Match 'NameConstraint|UntrustedRoot'
        } finally {
            if ($root) { try { $root.Remove((New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(, $ca.RawData))) } catch { }; $root.Close() }
            foreach ($c in @($bad, $good, $ca)) { if ($c) { Remove-Item -LiteralPath "Cert:\LocalMachine\My\$($c.Thumbprint)" -DeleteKey -ErrorAction SilentlyContinue } }
        }
        Write-Host "Kettenstatus 8.8.8.8: '$res'"
        $res | Should -Match 'NotPermittedNameConstraint|HasNotPermittedNameConstraint|InvalidNameConstraints'
    }
}

Describe 'Update: GitHub-Abfragegrenze erkennen' {
    It 'erkennt "rate limit" in der Antwort, sonst leer; ohne Kopfzeile eine Stunde' {
        $e = [System.Management.Automation.ErrorRecord]::new([Exception]::new('Der Remoteserver hat einen Fehler zurueckgegeben: (403) Unzulaessig.'), 'x', 'NotSpecified', $null)
        $e.ErrorDetails = [System.Management.Automation.ErrorDetails]::new('{"message":"API rate limit exceeded for 203.0.113.10."}')
        $r = Get-HMGitHubRateLimit $e
        $r | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$'
        ([datetime]$r - (Get-Date)).TotalMinutes | Should -BeGreaterThan 50
        $n = [System.Management.Automation.ErrorRecord]::new([Exception]::new('Not Found'), 'x', 'NotSpecified', $null)
        Get-HMGitHubRateLimit $n | Should -BeNullOrEmpty
    }
    It 'Pull.ps1 Zielordner: Update in einer Installation, Erstinstallation im leeren Ordner, sonst Desktop' {
        $code = [regex]::Match((Get-Content (Join-Path $script:Root 'Pull.ps1') -Raw -Encoding UTF8), '(?s)function Resolve-HMPullTarget\(\[string\]\$Here\) \{.*?\r?\n\}').Value
        $code | Should -Not -BeNullOrEmpty
        . ([scriptblock]::Create($code))
        $oldUp = $env:USERPROFILE
        try {
            $env:USERPROFILE = Join-Path $TestDrive 'profil'
            $desk = Join-Path $env:USERPROFILE 'Desktop\HUMig'
            # leer bis auf Pull.ps1 -> genau dort
            $e = Join-Path $TestDrive 'leer'; New-Item -ItemType Directory -Path $e -Force | Out-Null; Set-Content -LiteralPath (Join-Path $e 'Pull.ps1') -Value '#'
            (Resolve-HMPullTarget $e).Target | Should -Be ([IO.Path]::GetFullPath($e).TrimEnd('\'))
            # weitere Dateien daneben (z.B. Downloads) -> Desktop
            Set-Content -LiteralPath (Join-Path $e 'anderes.txt') -Value 'x'
            (Resolve-HMPullTarget $e).Target | Should -Be $desk
            # HUMig-Installation -> Update dort
            $i = Join-Path $TestDrive 'inst'; New-Item -ItemType Directory -Path (Join-Path $i 'Functions') -Force | Out-Null
            $r = Resolve-HMPullTarget $i
            $r.Target | Should -Be $i; $r.Mode | Should -Match 'Update'
            # Downloads-Ordner selbst nie, auch wenn leer
            $dl = Join-Path $env:USERPROFILE 'Downloads'; New-Item -ItemType Directory -Path $dl -Force | Out-Null; Set-Content -LiteralPath (Join-Path $dl 'Pull.ps1') -Value '#'
            (Resolve-HMPullTarget $dl).Target | Should -Be $desk
            # ohne Ordner -> Desktop
            (Resolve-HMPullTarget '').Target | Should -Be $desk
        } finally { $env:USERPROFILE = $oldUp }
    }
    It 'Install.ps1: nur ASCII, laedt Pull.ps1 aus dem freigegebenen Release und prueft die Pruefsumme' {
        $f = Join-Path $script:Root 'Install.ps1'
        $b = [IO.File]::ReadAllBytes($f)
        @($b[3..($b.Length - 1)] | Where-Object { $_ -gt 127 }).Count | Should -Be 0
        $t = Get-Content -LiteralPath $f -Raw -Encoding UTF8
        $t | Should -Match 'releases/latest/download'
        $t | Should -Match 'Get-FileHash'
        $t | Should -Match '-Target \$t'
        $t | Should -Not -Match '(?m)^#Requires'
    }
    It 'Pull.ps1 erkennt die Abfragegrenze genauso (gleiche Funktion wie Core-Update.ps1)' {
        $re = '(?s)function Get-HMGitHubRateLimit\(\$Err\) \{.*?\r?\n\}'
        $a = [regex]::Match((Get-Content (Join-Path $script:Root 'Pull.ps1') -Raw -Encoding UTF8), $re).Value -replace "`r`n", "`n"
        $b = [regex]::Match((Get-Content (Join-Path $script:Root 'Functions\Core-Update.ps1') -Raw -Encoding UTF8), $re).Value -replace "`r`n", "`n"
        $a | Should -Not -BeNullOrEmpty
        $a | Should -Be $b
    }
}

Describe 'Pruefung 2.0.137: Formatierung, Quelle, Ausnahmen, Profil, Port-Freigabe' {
    BeforeAll {
        . (Join-Path $script:Root 'Functions\AppUpdates-Engine.ps1')
        . (Join-Path $script:Root 'Functions\Remote-Core.ps1')
        . (Join-Path $script:Root 'Functions\Tools-Sandbox.ps1')
    }
    It 'kein "-f" mit zu wenigen Argumenten (z.B. "+" mitten in der Argumentliste) in allen Skripten' {
        $bad = @()
        foreach ($f in @(Get-ChildItem -LiteralPath $script:Root -Recurse -Filter *.ps1 | Where-Object { $_.FullName -notmatch '[\\/]\.github[\\/]' })) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
            foreach ($h in $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.BinaryExpressionAst] -and $a.Operator -eq 'Format' -and ($a.Left -is [System.Management.Automation.Language.StringConstantExpressionAst] -or $a.Left -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) }, $true)) {
                $idx = @([regex]::Matches($h.Left.Value, '(?<!\{)\{(\d+)(,[-\d]+)?(:[^}]*)?\}') | ForEach-Object { [int]$_.Groups[1].Value })
                if (-not $idx.Count) { continue }
                $max = ($idx | Measure-Object -Maximum).Maximum
                $r = $h.Right
                if ($r -is [System.Management.Automation.Language.VariableExpressionAst] -or $r -is [System.Management.Automation.Language.SubExpressionAst] -or $r -is [System.Management.Automation.Language.ParenExpressionAst] -or $r -is [System.Management.Automation.Language.ArrayExpressionAst]) { continue }
                $n = if ($r -is [System.Management.Automation.Language.ArrayLiteralAst]) { $r.Elements.Count } else { 1 }
                if ($n -le $max) { $bad += "$($f.Name):$($h.Extent.StartLineNumber) braucht $($max + 1), hat $n" }
            }
            foreach ($h in $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.BinaryExpressionAst] -and $a.Operator -in 'Plus', 'Minus' -and $a.Left -is [System.Management.Automation.Language.BinaryExpressionAst] -and $a.Left.Operator -eq 'Format' -and $a.Right -is [System.Management.Automation.Language.ArrayLiteralAst] }, $true)) { $bad += "$($f.Name):$($h.Extent.StartLineNumber) '+' trennt die Argumentliste von -f" }
        }
        $bad | Should -BeNullOrEmpty
    }
    It 'Ereignistext der Server-Sicherung laesst sich formatieren (mit und ohne VM-Export)' {
        $eng = Get-Content (Join-Path $script:Root 'Functions\ServerBackup-Engine.ps1') -Raw -Encoding UTF8
        $m = [regex]::Match($eng, '(?m)^\s*Write-HMSbEvent \$status (\(.+\))\s*$')
        $m.Success | Should -BeTrue
        $Ctx = @{ Profile = 'P'; DiskLabel = 'HV-1'; HostSystem = $true; Version = '9' }; $status = 'OK'; $vms = @('DC1'); $vols = @(); $hostSysOk = $true; $notes = @(); $rep = 'C:\R'; $dur = [TimeSpan]::FromMinutes(5)
        function Format-HMDuration($d) { '5 min' }
        foreach ($exp in @('', '1 VM exportiert')) {
            $res = @{ Export = $exp }
            $txt = Invoke-Expression $m.Groups[1].Value
            $txt | Should -Match 'Dauer: 5 min'
            if ($exp) { $txt | Should -Match 'VM-Export: 1 VM exportiert' }
        }
    }
    It 'Ausnahme mit ungueltigem Platzhalter bricht nicht ab' {
        { Find-HMAuExclusion ([pscustomobject]@{ Id = 'X.Y'; Name = 'Tool' }) @([pscustomobject]@{ Pattern = 'Tool [Beta' }) } | Should -Not -Throw
        (Find-HMAuExclusion ([pscustomobject]@{ Id = 'X.Y'; Name = 'Tool [Beta' }) @([pscustomobject]@{ Pattern = 'Tool [Beta' })).Pattern | Should -Be 'Tool [Beta'
    }
    It 'Paket-ID und Quelle an winget.exe: nur unauffaellige Zeichen (Ziel, Worker, Zeitplan)' {
        foreach ($f in 'AppUpdates-Target.ps1', 'AppUpdates-Worker.ps1', 'AppUpdates-Auto.ps1') {
            (Get-Content (Join-Path $script:Root "Functions\$f") -Raw -Encoding UTF8) | Should -Match ([regex]::Escape("-notmatch '^(?=.{1,64}\z)[A-Za-z0-9._](?:[A-Za-z0-9._ -]*[A-Za-z0-9._-])?\z'"))
        }
        'winget' -match '^(?=.{1,64}\z)[A-Za-z0-9._](?:[A-Za-z0-9._ -]*[A-Za-z0-9._-])?\z' | Should -BeTrue
        'winget" --override "x' -match '^(?=.{1,64}\z)[A-Za-z0-9._](?:[A-Za-z0-9._ -]*[A-Za-z0-9._-])?\z' | Should -BeFalse
        # Leerzeichen im Namen erlaubt (eigene Quellen wie "Firma Intern"), aber kein fuehrendes - / Leerzeichen, kein \ oder "
        foreach ($ok in 'Firma Intern', 'msstore', 'a.b_c-d') { $ok -match '^(?=.{1,64}\z)[A-Za-z0-9._](?:[A-Za-z0-9._ -]*[A-Za-z0-9._-])?\z' | Should -BeTrue -Because $ok }
        foreach ($bad in '-x', ' x', 'x ', 'x\', 'a"b', ('a' * 65), '', "winget`n") { $bad -match '^(?=.{1,64}\z)[A-Za-z0-9._](?:[A-Za-z0-9._ -]*[A-Za-z0-9._-])?\z' | Should -BeFalse -Because $bad }
        '7zip.7zip' -match '^[^\s\-"][^\s"]{0,254}\z' | Should -BeTrue
        'a"b' -match '^[^\s\-"][^\s"]{0,254}\z' | Should -BeFalse
        "7zip.7zip`n" -match '^[^\s\-"][^\s"]{0,254}\z' | Should -BeFalse
    }
    It 'Testinstallation: C:\Users\Public ist kein Benutzerprofil' {
        $e = [pscustomobject]@{ Key = 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\X'; DisplayName = 'X 1.0'; DisplayVersion = '1.0'; Publisher = 'P'; UninstallString = '"C:\Users\Public\X\unins000.exe"'; QuietUninstallString = ''; InstallLocation = 'C:\Users\Public\X\'; DisplayIcon = '' }
        $r = [pscustomobject]@{ ExitCode = 0; InstallStatus = 'OK'; InstallText = 'ok'; Seconds = 1; NewEntries = @($e); NewFolders = @(); UserFolders = @(); SelectedKey = ''; DesktopLinks = @(); DesktopLinksLeft = @(); InstallWindows = @(); UninstallWindows = @(); Deps = @(); UninstallTested = $false; InstallLog = ''; UninstallLog = ''; Error = '' }
        (Get-HMSandboxSummary -Result $r -Settings ([pscustomobject]@{ Name = 'X' })).Proposal.RunAsUser | Should -BeFalse
    }
    It 'Fernbedienung: fremde Port-Freigabe wird erkannt, Fingerabdruck in Vierergruppen' {
        $sid = 'S-1-5-21-1-2-3-1001'
        Test-HMRemoteUrlAclOurs 'Die Datei wurde nicht gefunden.' 8443 $sid | Should -BeTrue
        Test-HMRemoteUrlAclOurs "Reservierte URL : https://+:8443/`n SDDL: D:(A;;GX;;;$sid)(A;;GX;;;BA)" 8443 $sid | Should -BeTrue
        Test-HMRemoteUrlAclOurs "Reserved URL : https://+:8443/`n SDDL: D:(A;;GX;;;S-1-5-20)" 8443 $sid | Should -BeFalse
        $c = [pscustomobject]@{ RawData = [byte[]](1, 2, 3) }
        Get-HMRemoteFingerprint $c | Should -Match '^([0-9A-F]{4} ){15}[0-9A-F]{4}$'
    }
}

Describe 'Ordnerrechte: Ordner ueber dem HUMig-Ordner (Windows, Administrator)' {
    It 'Ordner darueber mit Standardrechten von C:\ wird erkannt, ein Benutzer kann ihn umbenennen; nach dem Absichern nicht mehr, Unterordner unveraendert' -Skip:(-not (([Environment]::OSVersion.Platform -eq 'Win32NT') -and ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))) {
        $code = [regex]::Match((Get-Content (Join-Path $script:Root 'HUMig.ps1') -Raw -Encoding UTF8), '(?s)#region HMAppAcl.*?#endregion HMAppAcl').Value
        . ([scriptblock]::Create($code))
        if (-not ('HMCiLogon' -as [type])) {
            Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class HMCiLogon { [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)] public static extern bool LogonUser(string u, string d, string p, int t, int v, out IntPtr h); [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h); }'
        }
        $rnd = -join ((48..57) + (97..102) | Get-Random -Count 6 | ForEach-Object { [char]$_ })
        $top = "C:\HMCi_$rnd"; $tools = Join-Path $top 'Tools'; $app = Join-Path $tools 'HUMig'; $other = Join-Path $tools 'Anderes'
        $user = "hmci_$rnd"; $pwPlain = 'Ci!' + [guid]::NewGuid().ToString('N').Substring(0, 16) + 'aA9'
        $tok = [IntPtr]::Zero
        # als Testbenutzer versuchen, $From in $To umzubenennen (und zurueck); Rueckgabe: $true = ging
        $tryRename = {
            param($From, $To)
            $ctx = [Security.Principal.WindowsIdentity]::Impersonate($tok)
            $ok = $false
            try { [IO.Directory]::Move($From, $To); $ok = $true } catch { $ok = $false } finally { $ctx.Undo() }
            if ($ok) { [IO.Directory]::Move($To, $From) }
            return $ok
        }
        # als Testbenutzer eine Datei in $Dir anlegen und wieder loeschen; Rueckgabe: $true = ging
        $tryWrite = {
            param($Dir, $Name)
            $ctx = [Security.Principal.WindowsIdentity]::Impersonate($tok)
            $ok = $false
            try { $fp = Join-Path $Dir $Name; [IO.File]::WriteAllText($fp, 'x'); [IO.File]::Delete($fp); $ok = $true } catch { $ok = $false } finally { $ctx.Undo() }
            return $ok
        }
        try {
            New-Item -ItemType Directory -Path (Join-Path $app 'Functions'), $other -Force | Out-Null
            & icacls.exe $app /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' /Q | Out-Null
            & icacls.exe $app /setowner '*S-1-5-32-544' /T /Q | Out-Null
            # wie C:\Tools mit den Standardrechten von C:\ (unabhaengig von den Rechten auf C:\ des Testrechners)
            & icacls.exe $top /grant '*S-1-5-11:(OI)(CI)M' /Q | Out-Null
            $pw = New-Object System.Security.SecureString
            foreach ($ch in $pwPlain.ToCharArray()) { $pw.AppendChar($ch) }
            New-LocalUser -Name $user -Password $pw -AccountNeverExpires -PasswordNeverExpires | Out-Null
            Add-LocalGroupMember -SID 'S-1-5-32-545' -Member $user
            $ok = [HMCiLogon]::LogonUser($user, '.', $pwPlain, 2, 0, [ref]$tok)
            if (-not $ok) { $ok = [HMCiLogon]::LogonUser($user, '.', $pwPlain, 3, 0, [ref]$tok) }
            $ok | Should -BeTrue
            # vorher: beide Ordner darueber gemeldet, Benutzer kann Tools umbenennen
            $f = @(Get-HMAppParentFindings $app | Where-Object { $_.Path -eq $tools -or $_.Path -eq $top })
            @($f | Where-Object { $_.Path -eq $tools -and -not $_.Profile }).Count | Should -Be 1
            @($f | Where-Object { $_.Path -eq $top -and -not $_.Profile }).Count | Should -Be 1
            (& $tryRename $tools "$tools-weg") | Should -BeTrue
            (& $tryWrite $other 'a.txt') | Should -BeTrue
            (& $tryWrite (Join-Path $app 'Functions') 'a.txt') | Should -BeFalse
            $sddlOther = (Get-Acl -LiteralPath $other).Sddl
            # absichern (nur die beiden Testordner, nie C:\ des Testrechners)
            foreach ($x in $f) { Protect-HMAppParent $x.Path | Should -Be '' }
            @(Get-HMAppParentFindings $app | Where-Object { $_.Path -eq $tools -or $_.Path -eq $top }).Count | Should -Be 0
            (& $tryRename $tools "$tools-weg") | Should -BeFalse
            (& $tryRename $top "$top-weg") | Should -BeFalse
            # Unterordner anderer Programme: Benutzer duerfen dort weiter schreiben wie vorher
            (& $tryWrite $other 'b.txt') | Should -BeTrue
            (& $tryWrite $tools 'c.txt') | Should -BeTrue
            # nur die Rechteliste des Ordners selbst geschrieben - Unterordner nicht angefasst
            (Get-Acl -LiteralPath $other).Sddl | Should -Be $sddlOther
            # Eintrag mit allgemeinen Rechten (GENERIC_ALL, vererbbar) wird umgerechnet statt abzubrechen
            $g = Join-Path $top 'Gen'; New-Item -ItemType Directory -Path (Join-Path $g 'HUMig') -Force | Out-Null
            & icacls.exe $g /grant '*S-1-5-11:(OI)(CI)(GA)' /Q | Out-Null
            @(Get-HMAppParentFindings (Join-Path $g 'HUMig') | Where-Object { $_.Path -eq $g }).Count | Should -Be 1
            Protect-HMAppParent $g | Should -Be ''
            @(Get-HMAppParentFindings (Join-Path $g 'HUMig') | Where-Object { $_.Path -eq $g }).Count | Should -Be 0
            (& $tryWrite $g 'd.txt') | Should -BeTrue
            (& $tryRename $g "$g-weg") | Should -BeFalse
            # Verknuepfung im Pfad: gemeldet, nie geaendert
            $j = Join-Path $top 'Link'
            cmd.exe /c "mklink /J `"$j`" `"$tools`" >nul 2>&1"
            @(Get-HMAppParentFindings (Join-Path $j 'HUMig') | Where-Object { $_.Link }).Count | Should -BeGreaterThan 0
            Protect-HMAppParent $j | Should -Match 'Verknuepfung'
            cmd.exe /c "rmdir `"$j`""
            # Laufwerkswurzel: Loeschen zaehlt nicht (Standard eines Datenlaufwerks: Authentifizierte Benutzer Aendern)
            $ds = New-Object System.Security.AccessControl.DirectorySecurity
            $ds.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule((New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-11'), 'Modify, Synchronize', 'ContainerInherit, ObjectInherit', 'None', 'Allow')))
            @(Get-HMAppParentRisk $ds (Get-HMAppParentMask -DriveRoot)).Count | Should -Be 0
            @(Get-HMAppParentRisk $ds (Get-HMAppParentMask)).Count | Should -Be 1
            # Ordner unter C:\Users werden nie geaendert
            Test-HMAppInProfile (Join-Path $env:PUBLIC 'x') | Should -BeTrue
            Protect-HMAppParent $env:PUBLIC | Should -Match 'Benutzerprofil'
        } finally {
            if ($tok -ne [IntPtr]::Zero) { [void][HMCiLogon]::CloseHandle($tok) }
            Remove-LocalUser -Name $user -ErrorAction SilentlyContinue
            foreach ($p in $top, "$top-weg") { if (Test-Path -LiteralPath $p) { cmd.exe /c "icacls `"$p`" /reset /T /C /Q >nul 2>&1"; Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue } }
        }
    }
}
