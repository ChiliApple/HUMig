#Requires -Version 5.1
<#
.SYNOPSIS
    App-Updates: Code, der auf dem ZIEL-PC laeuft - lokal (&) oder per Invoke-Command (mehrere PCs parallel).
.DESCRIPTION
    WinGet ist pro Benutzer registriert. Gelesen wird deshalb ueber einmalige geplante Aufgaben:
      - ist ein Benutzer angemeldet: in seinem Konto (Windows PowerShell + Modul Microsoft.WinGet.Client) - sieht alle Programme
      - sonst als SYSTEM mit PowerShell 7 (das Modul laeuft als SYSTEM nur dort) - Programme fuer alle Benutzer
    Aktualisiert/installiert wird fuer alle Benutzer als SYSTEM ueber winget.exe, nur fuer den Benutzer installierte in seinem Konto.
    Ausgabe: Objekte { HMAu = 'L' (Protokollzeile, V) | 'R' (Ergebnis als JSON, J); PC }.
    Op: Search | Update | Install | ScheduleSet | ScheduleGet | ScheduleRemove
.NOTES
    Zielmaschine: der jeweilige PC (Administratorrechte; per Fernzugriff ueber WinRM).
#>
param([string]$Op, $Payload, [string]$WorkerText, [string]$AutoText)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$PC = "$env:COMPUTERNAME".ToUpper()
$Base = Join-Path $env:ProgramData 'HUMig\AppUpdates'
$ModName = 'Microsoft.WinGet.Client'
# PowerShell 7: installiert (MSI) oder eigene Kopie von HUMig (ZIP von Microsoft, nur fuer HUMig) - die Store-/MSIX-Variante
# (winget ab 7.6 Standard) laeuft als SYSTEM nicht verlaesslich und liegt nicht unter Programme\PowerShell\7
$PwshMsi = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
$PwshDir = Join-Path $env:ProgramFiles 'HUMig\PowerShell7'
function Get-TPwsh { foreach ($p in @($PwshMsi, (Join-Path $PwshDir 'pwsh.exe'))) { if (Test-Path -LiteralPath $p) { return $p } }; return '' }
$WinPs = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$AutoTask = 'HUMig App-Updates'
$script:TErr = @()
$script:TRes = $null
# eigener Teil bei mehreren PCs (ByPc[PCNAME])
# Schluessel = Name wie in HUMig angegeben (gross): Computername, voller DNS-Name oder IP-Adresse
$My = $Payload
if ($Payload -and $Payload.ByPc) {
    $My = $null
    $cand = @($PC)
    try { $cand += ("$PC.$((Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).Domain)").ToUpper() } catch { }
    try { $cand += @([System.Net.Dns]::GetHostAddresses($env:COMPUTERNAME) | ForEach-Object { "$_" }) } catch { }
    foreach ($k in $cand) { foreach ($bk in @($Payload.ByPc.Keys)) { if ("$bk".ToUpper() -eq $k) { $My = $Payload.ByPc[$bk]; break } }; if ($My) { break } }
    if (-not $My) { $My = @{ Items = @() } }
}

function Out-L([string]$t) { [pscustomobject]@{ HMAu = 'L'; PC = $PC; V = $t } }
# Ergebnis als JSON (Fernzugriff gibt verschachtelte Objekte sonst nur bis Tiefe 1 zurueck)
function Out-R($v) { [pscustomobject]@{ HMAu = 'R'; PC = $PC; J = (ConvertTo-Json -InputObject $v -Depth 8 -Compress) } }
function Get-TLoggedOnSids {
    @(foreach ($p in @(Get-CimInstance -ClassName Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue)) {
            try { "$((Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid -ErrorAction Stop).Sid)" } catch { }
        }) | Where-Object { $_ -and ($_ -like 'S-1-5-21-*' -or $_ -like 'S-1-12-*') } | Select-Object -Unique
}
function Get-TAccount([string]$Sid) { try { return (New-Object System.Security.Principal.SecurityIdentifier($Sid)).Translate([System.Security.Principal.NTAccount]).Value } catch { return $Sid } }
function Test-TModule { return (Test-Path -LiteralPath (Join-Path $env:ProgramFiles "WindowsPowerShell\Modules\$ModName")) }

# Modul fuer alle Benutzer (SYSTEM und andere Benutzer finden es nur dort)
function Install-TModule {
    if (Test-TModule) { return }
    Out-L 'WinGet-Modul fuer alle Benutzer installieren (PowerShell Gallery) ...'
    try {
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
        if (-not @(Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue | Where-Object { $_.Version -ge [version]'2.8.5.201' }).Count) {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers -ErrorAction Stop | Out-Null
        }
        Install-Module -Name $ModName -Repository PSGallery -Scope AllUsers -Force -AllowClobber -ErrorAction Stop
        Out-L 'WinGet-Modul installiert'
    } catch { $script:TErr += "WinGet-Modul nicht installierbar (Internet/Proxy?): $($_.Exception.Message)" }
}

# WinGet (App Installer) fuer alle Benutzer vorhanden? winget.exe im Paketordner (Programme\WindowsApps)
function Test-TWinGet {
    return [bool](@(Get-ChildItem -Path (Join-Path $env:ProgramFiles 'WindowsApps') -Filter 'Microsoft.DesktopAppInstaller_*_8wekyb3d8bbwe' -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'winget.exe') }).Count)
}
# Windows-Version: Windows 10 1809+/11, Windows Server 2022 (eingeschraenkt) / 2025, Windows Server 2019 experimentell
# (Build 17763 wie Windows 10 1809 - von Microsoft nicht unterstuetzt)
function Test-TOsOk { return ([Environment]::OSVersion.Version.Build -ge 17763) }
function Test-TOsExperimental {
    $srv = $false; try { $srv = ([int](Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).ProductType -ne 1) } catch { }
    return ($srv -and [Environment]::OSVersion.Version.Build -lt 20348)
}
# Fehlt WinGet (z.B. Windows Server 2022 - dort nicht mitgeliefert), fuer alle Benutzer einrichten: Repair-WinGetPackageManager -AllUsers
# (laedt App Installer und Abhaengigkeiten von GitHub). Nur mit Modul; Fehler landen in $script:TErr
function Install-TWinGet {
    if (Test-TWinGet) { return }
    if (-not (Test-TOsOk)) { $script:TErr += 'WinGet wird auf dieser Windows-Version nicht unterstuetzt (Windows 10 1809+/11, Windows Server 2019 (experimentell)/2022/2025)'; return }
    if (Test-TOsExperimental) { Out-L 'Windows Server 2019: WinGet wird von Microsoft hier nicht unterstuetzt - Einrichtung wird trotzdem versucht (experimentell)' }
    Out-L 'WinGet (App Installer) fehlt - wird fuer alle Benutzer eingerichtet (Repair-WinGetPackageManager -AllUsers, Download von GitHub) ...'
    # im eigenen Prozess: das Modul kann auf nicht unterstuetzten Systemen (z.B. Windows Server 2019) abstuerzen und wuerde
    # sonst den aufrufenden Prozess (HUMig bzw. die Remote-Sitzung) mitreissen; keine Absturz-Dialoge (Fehlermodus wird vererbt)
    $mp = (Join-Path $env:ProgramFiles "WindowsPowerShell\Modules\$ModName") -replace "'", "''"
    $cmd = "`$ErrorActionPreference = 'Stop'; `$ProgressPreference = 'SilentlyContinue'; try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }; try { Import-Module '$mp'; Repair-WinGetPackageManager -AllUsers -Latest -Force | Out-Null; exit 0 } catch { [Console]::Out.WriteLine(`$_.Exception.Message); exit 1 }"
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
    $old = $null
    try {
        if (-not ('HMAuT.ErrMode' -as [type])) { Add-Type -Namespace 'HMAuT' -Name 'ErrMode' -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetErrorMode(uint mode);' }
        $old = [HMAuT.ErrMode]::SetErrorMode(0x8003)
    } catch { }
    $out = ''; $code = $null
    $eap = $ErrorActionPreference
    try {
        # stderr des Unterprozesses darf unter Windows PowerShell 5.1 (2>&1 bei EAP=Stop) nicht als Abbruch zaehlen - es zaehlt der Exitcode
        $ErrorActionPreference = 'Continue'
        $out = (@(& (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $enc 2>&1) | ForEach-Object { "$_" }) -join ' '
        $code = $LASTEXITCODE
    } catch { $out = $_.Exception.Message; $code = 1 }
    finally { $ErrorActionPreference = $eap; if ($null -ne $old) { try { [void][HMAuT.ErrMode]::SetErrorMode($old) } catch { } } }
    if ($code -eq 0) {
        if (Test-TWinGet) { Out-L 'WinGet eingerichtet' } else { $script:TErr += 'WinGet nach der Einrichtung nicht gefunden' }
    } elseif ($code -eq 1) {
        $script:TErr += "WinGet nicht einrichtbar: $("$out".Trim()) - am PC als Administrator: Repair-WinGetPackageManager -AllUsers -Latest -Force"
    } else {
        $script:TErr += ("WinGet-Modul beim Einrichten abgestuerzt (Code 0x{0:X8}){1}" -f [int]$code, $(if (Test-TOsExperimental) { ' - Windows Server 2019 wird von Microsoft fuer WinGet nicht unterstuetzt' } else { '' }))
    }
}

# einmalige Aufgabe: $Who = 'SYSTEM' oder Benutzer-SID. Setzt $script:TRes, gibt Protokollzeilen aus.
# $ItemTimeoutMin > 0: haengt ein Programm laenger (START ohne DONE), Aufgabe beenden -> $script:TTimedOut = Paket-Id;
# bereits fertige Programme stehen dann in $script:TDone (aus den DONE-Zeilen des Protokolls)
function Invoke-TTask([string]$Who, $Request, [bool]$UsePwsh, [int]$TimeoutSec, [int]$ItemTimeoutMin = 0) {
    $script:TRes = $null
    $script:TTimedOut = ''
    $script:TDone = @()
    $curId = ''; $curT = $null
    $id = [guid]::NewGuid().ToString('N')
    $dir = Join-Path $Base "run_$id"
    $name = "HUMig_AppUpdates_$id"
    $sys = ($Who -eq 'SYSTEM')
    try {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $dir 'worker.ps1'), $WorkerText, (New-Object System.Text.UTF8Encoding($true)))
        $Request | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $dir 'request.json') -Encoding UTF8
        if (-not $sys) { & icacls.exe "$dir" /grant "*${Who}:(OI)(CI)M" | Out-Null }
        $exe = if ($UsePwsh) { Get-TPwsh } else { $WinPs }
        $psArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$dir\worker.ps1`" -Dir `"$dir`""
        if ($sys) { $a = New-ScheduledTaskAction -Execute $exe -Argument $psArgs }
        elseif ([Environment]::OSVersion.Version.Build -ge 19041) { $a = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\conhost.exe') -Argument "--headless `"$exe`" $psArgs" }
        else {
            $vbs = Join-Path $dir 'start.vbs'
            ('CreateObject("WScript.Shell").Run """' + $exe + '"" ' + ($psArgs -replace '"', '""') + '", 0, True') | Set-Content -LiteralPath $vbs -Encoding ASCII
            $a = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\wscript.exe') -Argument "//B //NoLogo `"$vbs`""
        }
        $s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 3) -MultipleInstances IgnoreNew
        $pr = if ($sys) { New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest } else { New-ScheduledTaskPrincipal -UserId (Get-TAccount $Who) -LogonType Interactive -RunLevel Limited }
        Register-ScheduledTask -TaskName $name -TaskPath '\' -Action $a -Principal $pr -Settings $s -Force -ErrorAction Stop | Out-Null
        Start-ScheduledTask -TaskPath '\' -TaskName $name
        $t0 = Get-Date; $seen = 0; $doneAt = $null; $cancelSent = $false
        $rf = Join-Path $dir 'result.json'; $lf = Join-Path $dir 'log.txt'
        while ($true) {
            if (Test-Path -LiteralPath $lf) {
                $lines = @(Get-Content -LiteralPath $lf -Encoding UTF8 -ErrorAction SilentlyContinue)
                for ($i = $seen; $i -lt $lines.Count; $i++) {
                    Out-L "#$($lines[$i])"
                    $pp = "$($lines[$i])".Split('|')
                    if ($pp[0] -eq 'START') { $curId = $pp[1]; $curT = Get-Date }
                    elseif ($pp[0] -eq 'DONE') { $curId = ''; $script:TDone += , $pp }
                }
                # nur weiterzaehlen: ist die Datei gerade gesperrt (Lesen liefert nichts/weniger), nicht von vorne anfangen
                if ($lines.Count -gt $seen) { $seen = $lines.Count }
            }
            if (Test-Path -LiteralPath $rf) { $script:TRes = Get-Content -LiteralPath $rf -Raw -Encoding UTF8 | ConvertFrom-Json; break }
            if ($ItemTimeoutMin -gt 0 -and $curId -and $curT -and ((Get-Date) - $curT).TotalMinutes -ge $ItemTimeoutMin) {
                try { Stop-ScheduledTask -TaskPath '\' -TaskName $name -ErrorAction SilentlyContinue } catch { }
                $script:TTimedOut = $curId; break
            }
            if (-not $cancelSent -and $Payload.Job -and $Payload.Job.Cancel) { New-Item -ItemType File -Path (Join-Path $dir 'cancel') -Force | Out-Null; $cancelSent = $true }
            $st = ''; try { $st = "$((Get-ScheduledTask -TaskPath '\' -TaskName $name -ErrorAction Stop).State)" } catch { }
            if ($st -and $st -ne 'Running' -and $st -ne 'Queued') {
                if (-not $doneAt) { $doneAt = Get-Date } elseif (((Get-Date) - $doneAt).TotalSeconds -gt 10) {
                    $lr = ''; try { $lr = "$((Get-ScheduledTaskInfo -TaskPath '\' -TaskName $name).LastTaskResult)" } catch { }
                    $lh = ''; try { if ("$lr" -match '^-?\d+$') { $lv = [int64]"$lr"; if ($lv -lt 0) { $lv += 4294967296 }; $lh = ' = 0x{0:X8}' -f $lv } } catch { }
                    $why = if ("$lh" -match '800710E0') { ' - Windows hat den Start im Benutzerkonto abgelehnt' } else { '' }
                    $script:TErr += "Aufgabe als $(if ($sys) { 'SYSTEM' } else { Get-TAccount $Who }) ohne Ergebnis beendet (Rueckgabe $lr$lh)$why"; break
                }
            }
            if (((Get-Date) - $t0).TotalSeconds -gt $TimeoutSec) {
                try { Stop-ScheduledTask -TaskPath '\' -TaskName $name -ErrorAction SilentlyContinue } catch { }
                $script:TErr += "Zeitueberschreitung nach $TimeoutSec s"; break
            }
            Start-Sleep -Milliseconds 1500
        }
    } catch { $script:TErr += "Aufgabe nicht ausfuehrbar: $($_.Exception.Message)" }
    finally {
        try { Unregister-ScheduledTask -TaskPath '\' -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue } catch { }
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($script:TRes) { $script:TErr += @($script:TRes.Errors | Where-Object { $_ }) }
}

# PowerShell 7 (fuer das Lesen als SYSTEM und den Zeitplan): offizielles ZIP-Paket von GitHub (Microsoft),
# SHA256 aus den Release-Angaben geprueft, entpackt nach Programme\HUMig\PowerShell7 (nur Administratoren duerfen schreiben)
function Install-TPwsh {
    if (Get-TPwsh) { return }
    if (-not $My.InstallPwsh) { $script:TErr += 'PowerShell 7 fehlt (fuer das Lesen ohne angemeldeten Benutzer und den Zeitplan noetig)'; return }
    Out-L 'PowerShell 7 laden (ZIP von Microsoft/GitHub, nur fuer HUMig) ...'
    $tmp = Join-Path $Base "pwsh_$([guid]::NewGuid().ToString('N')).zip"
    try {
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
        New-Item -ItemType Directory -Path $Base -Force | Out-Null
        $arch = if ("$env:PROCESSOR_ARCHITECTURE" -eq 'ARM64') { 'arm64' } else { 'x64' }
        $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest' -Headers @{ 'User-Agent' = 'HUMig' } -UseBasicParsing -ErrorAction Stop
        $as = @($rel.assets | Where-Object { "$($_.name)" -match "^PowerShell-[\d\.]+-win-$arch\.zip$" })[0]
        if (-not $as) { throw "kein ZIP-Paket fuer $arch in $($rel.tag_name)" }
        $want = ''
        if ("$($as.digest)" -match '^sha256:([0-9a-fA-F]{64})$') { $want = $Matches[1] }
        if (-not $want) {
            $ha = @($rel.assets | Where-Object { "$($_.name)" -eq 'hashes.sha256' })[0]
            if ($ha) {
                $b = (Invoke-WebRequest -Uri $ha.browser_download_url -UseBasicParsing -ErrorAction Stop).RawContentStream.ToArray()
                $txt = if ($b.Length -ge 2 -and $b[0] -eq 0xFF -and $b[1] -eq 0xFE) { [Text.Encoding]::Unicode.GetString($b) } else { [Text.Encoding]::UTF8.GetString($b) }
                $m = [regex]::Match($txt, '([0-9a-fA-F]{64})\s+\*?' + [regex]::Escape("$($as.name)"))
                if ($m.Success) { $want = $m.Groups[1].Value }
            }
        }
        if (-not $want) { throw 'keine Pruefsumme zum Paket gefunden - nicht installiert' }
        Invoke-WebRequest -Uri $as.browser_download_url -OutFile $tmp -UseBasicParsing -ErrorAction Stop
        $got = (Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash
        if ($got -ne $want.ToUpper()) { throw "Pruefsumme passt nicht ($($as.name)) - nicht installiert" }
        if (Test-Path -LiteralPath $PwshDir) { Remove-Item -LiteralPath $PwshDir -Recurse -Force }
        New-Item -ItemType Directory -Path $PwshDir -Force | Out-Null
        Expand-Archive -LiteralPath $tmp -DestinationPath $PwshDir -Force
        if (-not (Test-Path -LiteralPath (Join-Path $PwshDir 'pwsh.exe'))) { throw 'pwsh.exe nach dem Entpacken nicht gefunden' }
        Out-L "PowerShell $("$($rel.tag_name)".TrimStart('v')) bereit ($PwshDir)"
    } catch { $script:TErr += "PowerShell 7 nicht installierbar: $($_.Exception.Message)" }
    finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}

# Benutzer fuer das Lesen: gewuenschter (wenn angemeldet), sonst der erste angemeldete
function Get-TUserSid {
    $sids = @(Get-TLoggedOnSids)
    if ($My.UserSid -and $sids -contains "$($My.UserSid)") { return "$($My.UserSid)" }
    if ($sids.Count) { return $sids[0] }
    return ''
}

try {
    # %ProgramData%\HUMig absichern: nur SYSTEM/Administratoren duerfen schreiben (hier liegen Skripte, die als SYSTEM laufen).
    # Protect-HMDataDir fuegt HUMig vor dem Start ein (Functions\Core-Protect.ps1)
    if (Get-Command Protect-HMDataDir -ErrorAction SilentlyContinue) {
        try { [void](Protect-HMDataDir) } catch { throw "ProgramData\HUMig nicht absicherbar - abgebrochen: $($_.Exception.Message)" }
    }
    # Zeitplan-Skript immer auf dem Stand dieser HUMig-Version halten (ersetzt auch ein veraendertes auto.ps1)
    $autoFile = Join-Path $Base 'auto\auto.ps1'
    if ($AutoText -and (Test-Path -LiteralPath $autoFile)) {
        if ([System.IO.File]::ReadAllText($autoFile) -cne $AutoText) { [System.IO.File]::WriteAllText($autoFile, $AutoText, (New-Object System.Text.UTF8Encoding($true))); Out-L 'Zeitplan-Skript auf den aktuellen Stand gebracht' }
    }
    switch ($Op) {
        'Search' {
            Install-TModule
            if (-not (Test-TModule)) { Out-R ([pscustomobject]@{ Items = @(); Sources = @(); Errors = $script:TErr; ReadAs = ''; UserSid = ''; UserAccount = '' }); break }
            Install-TWinGet
            $sid = Get-TUserSid
            $req = @{ Mode = 'List'; Sources = @($My.Sources); IncludeUnknown = [bool]$My.IncludeUnknown }
            $readAs = ''; $items = @()
            if ($sid) {
                $readAs = Get-TAccount $sid
                Out-L "lese als $readAs ..."
                Invoke-TTask $sid $req $false 900
                if ($script:TRes) { $items = @($script:TRes.Items) }
                else {
                    # im Benutzerkonto kein Ergebnis (z.B. Start abgelehnt): als SYSTEM lesen - dann nur Programme fuer alle Benutzer
                    Install-TPwsh
                    if (Get-TPwsh) {
                        Out-L "kein Ergebnis als $readAs - lese als SYSTEM (PowerShell 7, nur Programme fuer alle Benutzer) ..."
                        $readAs = 'SYSTEM (PowerShell 7)'
                        Invoke-TTask 'SYSTEM' $req $true 900
                        if ($script:TRes) { $items = @($script:TRes.Items | ForEach-Object { $_.Scope = 'Machine'; $_ }) }
                    }
                }
            } else {
                Install-TPwsh
                if (Get-TPwsh) {
                    $readAs = 'SYSTEM (PowerShell 7)'
                    Out-L 'niemand angemeldet - lese als SYSTEM (PowerShell 7) ...'
                    Invoke-TTask 'SYSTEM' $req $true 900
                    # als SYSTEM sind nur Programme fuer alle Benutzer sichtbar
                    if ($script:TRes) { $items = @($script:TRes.Items | ForEach-Object { $_.Scope = 'Machine'; $_ }) }
                }
            }
            # gar kein Ergebnis = nicht gelesen (nicht "0 Updates" melden)
            if (-not $script:TRes) { $readAs = '' }
            # keine Quelle lesbar (z.B. WinGet fehlt: "Klasse nicht registriert") = nicht gelesen - nicht "0 Updates" melden
            $srcBad = @(@($script:TErr) | Where-Object { "$_" -match '^Quelle ' }).Count
            if (-not @($items | Where-Object { $_ }).Count -and $srcBad -and $srcBad -ge [Math]::Max(1, @($My.Sources | Where-Object { $_ }).Count)) {
                $readAs = ''
                if (@($script:TErr) -match '80040154|REGDB_E_CLASSNOTREG') { $script:TErr += 'WinGet ist am PC nicht nutzbar (App Installer fehlt bzw. nicht registriert) - am PC als Administrator: Repair-WinGetPackageManager -AllUsers -Latest -Force' }
            }
            Out-R ([pscustomobject]@{ Items = @($items | Where-Object { $_ }); Sources = $(if ($script:TRes) { @($script:TRes.Sources) } else { @() }); Errors = $script:TErr; ReadAs = $readAs; UserSid = $sid; UserAccount = $(if ($sid) { Get-TAccount $sid } else { '' }) })
        }
        { $_ -in 'Update', 'Install' } {
            $all = @($My.Items | Where-Object { $_ })
            $res = @()
            # vor dem Weiterreichen an SYSTEM/Benutzer: Paket-ID pruefen (keine Optionen/Leerzeichen) und Ausnahmen des
            # Standorts erneut anwenden (Muster mit * ? auf Paket-ID oder Programmname, wie Find-HMAuExclusion)
            $exl = @(@($My.Exclude) | Where-Object { $_ -and "$($_.Pattern)".Trim() })
            $keepIt = @()
            foreach ($it in $all) {
                $iid = "$($it.Id)"
                # Paket-ID und Quelle kommen aus der Liste (gelesen im Benutzerkonto) und gehen an winget.exe als SYSTEM:
                # nur unauffaellige Zeichen zulassen (keine Leerzeichen/Anfuehrungszeichen, die weitere Argumente erzeugen koennten)
                if ($iid -notmatch '^[^\s\-"][^\s"]{0,254}$' -or "$($it.Source)" -notmatch '^(?=.{1,64}$)[A-Za-z0-9._](?:[A-Za-z0-9._ -]*[A-Za-z0-9._-])?$') {
                    $res += [pscustomobject]@{ Id = $iid; Status = 'Exception'; Code = 0; InstallerErrorCode = 0; ExtendedErrorCode = 0; Reboot = $false; Text = 'ungueltige Paket-ID oder Quelle - nicht ausgefuehrt' }
                    Out-L "ungueltige Paket-ID '$iid' bzw. Quelle '$($it.Source)' - nicht ausgefuehrt"
                    Out-L "#DONE|$iid|Exception|0|0|0|False"   # Fortschritt wie bei ausgefuehrten Programmen
                    continue
                }
                if ($Op -eq 'Update') {
                    $hit = $null
                    foreach ($xe in $exl) {
                        $xp = "$($xe.Pattern)".Trim(); $m = $false
                        try { $m = ($iid -like $xp -or "$($it.Name)" -like $xp) } catch { $m = ($iid -eq $xp -or "$($it.Name)" -eq $xp) }   # ungueltiges Muster bricht nicht ab
                        if ($m) { $hit = $xe; break }
                    }
                    if ($hit) {
                        $res += [pscustomobject]@{ Id = $iid; Status = 'Excluded'; Code = 0; InstallerErrorCode = 0; ExtendedErrorCode = 0; Reboot = $false; Text = 'Ausnahme - nicht aktualisiert' }
                        Out-L "$iid`: Ausnahme ($("$($hit.Pattern)".Trim())) - nicht aktualisiert"
                        Out-L "#DONE|$iid|Excluded|0|0|0|False"   # Fortschritt wie bei ausgefuehrten Programmen
                        continue
                    }
                }
                $keepIt += $it
            }
            $all = $keepIt
            $mach = @($all | Where-Object { $Op -eq 'Install' -or "$($_.Scope)" -ne 'User' })
            $usr = @($all | Where-Object { $Op -ne 'Install' -and "$($_.Scope)" -eq 'User' })
            if ($mach.Count) {
                Out-L "$($mach.Count) Programm(e) fuer alle Benutzer (als SYSTEM) ..."
                Invoke-TTask 'SYSTEM' @{ Mode = $Op; Cli = $true; Items = @($mach | ForEach-Object { @{ Id = "$($_.Id)"; Source = "$($_.Source)"; Unknown = [bool]$_.Unknown } }) } $false 10800
                if ($script:TRes) { $res += @($script:TRes.Results) }
            }
            $usid = "$($My.UserSid)"
            # 0x8A150014 als SYSTEM: Paket ist nur im Benutzerkonto sichtbar (z.B. WSL) -> im Benutzerkonto noch einmal versuchen
            if ($Op -eq 'Update' -and $res.Count) {
                $nf = @($res | Where-Object { "$($_.Status)" -eq 'Cli' -and "$($_.Code)" -eq '-1978335212' })
                if ($nf.Count) {
                    $rs = Get-TUserSid
                    if ($rs) {
                        $ids = @($nf | ForEach-Object { "$($_.Id)" })
                        $res = @($res | Where-Object { $ids -notcontains "$($_.Id)" })
                        $usr = @($usr) + @($mach | Where-Object { $ids -contains "$($_.Id)" })
                        if (-not $usid -or @(Get-TLoggedOnSids) -notcontains $usid) { $usid = $rs }
                        Out-L "$($ids.Count) Programm(e) als SYSTEM nicht gefunden - neuer Versuch im Benutzerkonto $(Get-TAccount $usid) ..."
                    }
                }
            }
            if ($usr.Count) {
                $sids = @(Get-TLoggedOnSids)
                $sid = $usid
                if (-not $sid -or $sids -notcontains $sid) { $script:TErr += "Programme nur fuer einen Benutzer: $(if ($sid) { Get-TAccount $sid } else { 'Benutzer' }) ist nicht (mehr) angemeldet" }
                else {
                    Out-L "$($usr.Count) Programm(e) nur fuer $(Get-TAccount $sid) (als dieser Benutzer) ..."
                    # je Programm hoechstens $lim Minuten: Installer im Benutzerkonto, die Adminrechte verlangen, warten sonst auf eine
                    # UAC-Bestaetigung, die niemand gibt -> abbrechen, Rest in einer neuen Aufgabe weiter
                    $lim = 15
                    $todo = @($usr)
                    while ($todo.Count) {
                        Invoke-TTask $sid @{ Mode = 'Update'; Items = @($todo | ForEach-Object { @{ Id = "$($_.Id)"; Source = "$($_.Source)"; Unknown = [bool]$_.Unknown } }) } $false 10800 $lim
                        if ($script:TRes) { $res += @($script:TRes.Results); break }
                        $got = @()
                        foreach ($d in @($script:TDone)) {
                            $res += [pscustomobject]@{ Id = "$($d[1])"; Status = "$($d[2])"; Code = $(if ($d.Count -gt 3) { $d[3] } else { 0 }); InstallerErrorCode = $(if ($d.Count -gt 4) { $d[4] } else { 0 }); ExtendedErrorCode = $(if ($d.Count -gt 5) { $d[5] } else { 0 }); Reboot = ($d.Count -gt 6 -and $d[6] -eq 'True'); Text = '' }
                            $got += "$($d[1])"
                        }
                        if (-not $script:TTimedOut) { break }
                        $res += [pscustomobject]@{ Id = "$($script:TTimedOut)"; Status = 'Exception'; Code = 0; InstallerErrorCode = 0; ExtendedErrorCode = 0; Reboot = $false; Text = "abgebrochen nach $lim min - wartet vermutlich auf eine Administrator-Bestaetigung (UAC) beim Benutzer; als Administrator fuer alle Benutzer installieren oder am PC bestaetigen" }
                        Out-L "$($script:TTimedOut): nach $lim min abgebrochen (wartet vermutlich auf Administrator-Bestaetigung)"
                        $got += "$($script:TTimedOut)"
                        $todo = @($todo | Where-Object { $got -notcontains "$($_.Id)" })
                    }
                }
            }
            Out-R ([pscustomobject]@{ Results = @($res | Where-Object { $_ }); Errors = $script:TErr })
        }
        'ScheduleSet' {
            Install-TModule
            Install-TPwsh
            if (-not (Test-TModule) -or -not (Get-TPwsh)) { Out-R ([pscustomobject]@{ Ok = $false; Errors = $script:TErr }); break }
            $dir = Join-Path $Base 'auto'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $dir 'auto.ps1'), $AutoText, (New-Object System.Text.UTF8Encoding($true)))
            [pscustomobject]@{ Sources = @($My.Sources); Exclude = @($My.Exclude); Location = "$($My.Location)"; Created = (Get-Date).ToString('yyyy-MM-dd HH:mm'); By = "$($My.By)" } |
                ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $dir 'config.json') -Encoding UTF8
            $at = [datetime]::ParseExact("$($My.Time)", 'HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
            $trg = if ("$($My.Mode)" -eq 'Weekly') { New-ScheduledTaskTrigger -Weekly -DaysOfWeek @($My.Days) -At $at } else { New-ScheduledTaskTrigger -Daily -At $at }
            $a = New-ScheduledTaskAction -Execute (Get-TPwsh) -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$dir\auto.ps1`""
            $s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 4) -MultipleInstances IgnoreNew -WakeToRun:([bool]$My.Wake)
            $pr = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
            $tp = '\HUMig\'
            try { Register-ScheduledTask -TaskName $AutoTask -TaskPath $tp -Action $a -Trigger $trg -Principal $pr -Settings $s -Description 'HUMig: Programme fuer alle Benutzer automatisch ueber WinGet aktualisieren (Ausnahmen beachtet). Verwalten: HUMig > App-Updates > Zeitplan.' -Force -ErrorAction Stop | Out-Null }
            catch { $tp = '\'; Register-ScheduledTask -TaskName $AutoTask -TaskPath $tp -Action $a -Trigger $trg -Principal $pr -Settings $s -Force -ErrorAction Stop | Out-Null }
            $next = ''; try { $next = (Get-ScheduledTaskInfo -TaskPath $tp -TaskName $AutoTask).NextRunTime.ToString('dd.MM.yyyy HH:mm') } catch { }
            Out-L "Zeitplan angelegt - naechster Lauf $next"
            Out-R ([pscustomobject]@{ Ok = $true; Next = $next; Errors = $script:TErr })
        }
        'ScheduleGet' {
            $t = @(Get-ScheduledTask -TaskName $AutoTask -ErrorAction SilentlyContinue)[0]
            $o = [ordered]@{ Exists = [bool]$t; When = ''; Next = ''; Last = ''; LastResult = ''; Summary = ''; Running = $false; Progress = ''; Log = @(); History = @(); Errors = @() }
            if ($t) { $o.Running = ("$($t.State)" -eq 'Running') }
            if ($t) {
                $tr = @($t.Triggers)[0]
                if ($tr) {
                    $tm = ''; try { $tm = ([datetime]"$($tr.StartBoundary)").ToString('HH:mm') } catch { }
                    $o.When = $(if ($tr.DaysOfWeek) { "woechentlich $tm" } else { "taeglich $tm" })
                }
                try { $i = Get-ScheduledTaskInfo -TaskPath $t.TaskPath -TaskName $t.TaskName; if ($i.NextRunTime) { $o.Next = $i.NextRunTime.ToString('dd.MM.yyyy HH:mm') }; if ($i.LastRunTime -and $i.LastRunTime.Year -gt 2000) { $o.Last = $i.LastRunTime.ToString('dd.MM.yyyy HH:mm') }; $o.LastResult = "$($i.LastTaskResult)" } catch { }
            }
            $lf = Join-Path $Base 'auto\last.json'
            if (Test-Path -LiteralPath $lf) { try { $l = Get-Content -LiteralPath $lf -Raw -Encoding UTF8 | ConvertFrom-Json; $o.Summary = "$($l.Date): $($l.Ok) aktualisiert, $($l.Err) Fehler, $($l.Excluded) Ausnahme(n)" } catch { } }
            $pf = Join-Path $Base 'auto\progress.json'
            if ($o.Running -and (Test-Path -LiteralPath $pf)) { try { $g = Get-Content -LiteralPath $pf -Raw -Encoding UTF8 | ConvertFrom-Json; $o.Progress = "$($g.Done)/$($g.Total)$(if ($g.Current) { ": $($g.Current)" }) ($($g.Ok) ok, $($g.Err) Fehler)" } catch { } }
            $lg = Join-Path $Base 'auto\log.txt'
            if (Test-Path -LiteralPath $lg) { try { $o.Log = @(Get-Content -LiteralPath $lg -Tail 80 -Encoding UTF8) } catch { } }
            $hf = Join-Path $Base 'auto\history.json'
            if (Test-Path -LiteralPath $hf) { try { $o.History = @(Get-Content -LiteralPath $hf -Raw -Encoding UTF8 | ConvertFrom-Json | ForEach-Object { $_ } | Select-Object -Last 200) } catch { } }
            Out-R ([pscustomobject]$o)
        }
        'ScheduleRemove' {
            foreach ($t in @(Get-ScheduledTask -TaskName $AutoTask -ErrorAction SilentlyContinue)) { Unregister-ScheduledTask -TaskPath $t.TaskPath -TaskName $t.TaskName -Confirm:$false -ErrorAction SilentlyContinue }
            Out-L 'Zeitplan entfernt (Verlauf bleibt erhalten)'
            Out-R ([pscustomobject]@{ Ok = $true; Errors = @() })
        }
        default { Out-R ([pscustomobject]@{ Errors = @("unbekannte Aktion $Op") }) }
    }
} catch { Out-R ([pscustomobject]@{ Items = @(); Results = @(); Errors = @($script:TErr + "Fehler: $($_.Exception.Message)") }) }
