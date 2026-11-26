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
    Op: Search | Running | Update | Install | ScheduleSet | ScheduleGet | ScheduleRemove
.NOTES
    Zielmaschine: der jeweilige PC (Administratorrechte; per Fernzugriff ueber WinRM).
#>
param([string]$Op, $Payload, [string]$WorkerText, [string]$AutoText)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$PC = "$env:COMPUTERNAME".ToUpper()
# Fernsitzung (WinRM): Ausfuehrungsrichtlinie nur fuer diese Sitzung lockern - sonst laedt z. B. PackageManagement auf PCs mit
# "Restricted" (Windows-Standard ohne Richtlinie) nicht. Aendert nichts an der Einstellung des PCs.
if ($PSSenderInfo) { try { Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force -ErrorAction Stop } catch { } }
$Base = Join-Path $env:ProgramData 'HUMig\AppUpdates'
$ModName = 'Microsoft.WinGet.Client'
# PowerShell 7: installiert (MSI) oder eigene Kopie von HUMig (ZIP von Microsoft, nur fuer HUMig) - die Store-/MSIX-Variante
# (winget ab 7.6 Standard) laeuft als SYSTEM nicht verlaesslich und liegt nicht unter Programme\PowerShell\7
$PwshMsi = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
$PwshDir = Join-Path $env:ProgramFiles 'HUMig\PowerShell7'
function Get-TPwsh { foreach ($p in @($PwshMsi, (Join-Path $PwshDir 'pwsh.exe'))) { if (Test-Path -LiteralPath $p) { return $p } }; return '' }
# Feste Fassung aus dem Auftrag (Payload.Tools aus Config\tools.json von HUMig) fuer diese Architektur; $null = keine gueltige Angabe
function Select-TPwshPackage($Tools, [string]$Arch) {
    if (-not $Tools -or -not $Tools.Pwsh -or -not $Tools.Pwsh.Pakete) { return $null }
    $v = "$($Tools.Pwsh.Version)"
    if ($v -notmatch '^\d+\.\d+\.\d+$') { return $null }
    $a = if ("$Arch" -eq 'ARM64') { 'arm64' } else { 'x64' }
    $p = $Tools.Pwsh.Pakete[$a]
    if (-not $p) { return $null }
    $url = "$($p.Url)"; $sha = "$($p.Sha256)"
    if ($url -notmatch '^https://' -or $url -match '(?i)latest' -or -not $url.Contains($v) -or $sha -notmatch '^[0-9a-fA-F]{64}$') { return $null }
    return @{ Version = $v; Datei = "$($p.Datei)"; Url = $url; Sha256 = $sha.ToUpperInvariant() }
}
# vorhandene Version (Text aus humig-pwsh.json oder ProductVersion von pwsh.exe, z. B. "7.4.6 SHA: ...") mit der festen vergleichen:
# -1 aelter (auch Vorabversion derselben Nummer), 0 gleich, 1 neuer, $null nicht lesbar
function Compare-TPwshVersion([string]$Have, [string]$Want) {
    $m = [regex]::Match("$Have", '^\s*v?(\d+)\.(\d+)\.(\d+)(-[0-9A-Za-z\.]+)?')
    if (-not $m.Success -or "$Want" -notmatch '^\d+\.\d+\.\d+$') { return $null }
    $h = [version]('{0}.{1}.{2}' -f $m.Groups[1].Value, $m.Groups[2].Value, $m.Groups[3].Value)
    $c = $h.CompareTo([version]$Want)
    if ($c -eq 0 -and $m.Groups[4].Success) { return -1 }
    return [Math]::Sign($c)
}
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
# Zeitlimit je Programm fuer Laeufe als SYSTEM (Minuten); haengt ein Installer laenger, wird die Aufgabe beendet und mit dem Rest weitergemacht
$SysItemMin = 120; $simTmp = 0; if ([int]::TryParse("$($Payload.ItemTimeoutMin)", [ref]$simTmp) -and $simTmp -gt 0) { $SysItemMin = $simTmp }
function Get-TLoggedOnSids {
    @(foreach ($p in @(Get-CimInstance -ClassName Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue)) {
            try { "$((Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid -ErrorAction Stop).Sid)" } catch { }
        }) | Where-Object { $_ -and ($_ -like 'S-1-5-21-*' -or $_ -like 'S-1-12-*') } | Select-Object -Unique
}
function Get-TAccount([string]$Sid) { try { return (New-Object System.Security.Principal.SecurityIdentifier($Sid)).Translate([System.Security.Principal.NTAccount]).Value } catch { return $Sid } }
function Test-TModule { return (Test-Path -LiteralPath (Join-Path $env:ProgramFiles "WindowsPowerShell\Modules\$ModName")) }

$ModRoot = Join-Path $env:ProgramFiles "WindowsPowerShell\Modules\$ModName"
# feste Version des Moduls aus dem Auftrag (Payload.Tools, Config\tools.json von HUMig); $null = keine gueltige Angabe
function Get-TModFixed {
    $x = $null; if ($Payload -and $Payload.Tools) { $x = $Payload.Tools.WinGet }
    if (-not $x -or "$($x.Version)" -notmatch '^\d+\.\d+\.\d+$' -or "$($x.Name)" -ne $ModName -or "$($x.Herausgeber)" -notmatch '^, O=.+') { return $null }
    return @{ Version = "$($x.Version)"; Herausgeber = "$($x.Herausgeber)" }
}
# Modul fuer alle Benutzer (SYSTEM und andere Benutzer finden es nur dort), nur in der festen Version: neben einer vorhandenen
# anderen Version installiert (Install-Module -RequiredVersion), nie eine neuere aus der Galerie. Ist die feste schon da, kein
# erneutes Install-Module (dieselbe Version mit -Force scheitert an der Katalog-Signaturpruefung).
function Install-TModule {
    $fx = Get-TModFixed
    if ($fx -and (Test-Path -LiteralPath (Join-Path $ModRoot "$($fx.Version)\$ModName.psd1"))) { return }
    $had = Test-TModule
    if (-not $fx) {
        if ($had) { return }
        $script:TErr += 'WinGet-Modul nicht installierbar: keine gueltige feste Version (Config\tools.json von HUMig)'; return
    }
    Out-L "WinGet-Modul $($fx.Version) fuer alle Benutzer installieren (PowerShell Gallery, feste Version) ..."
    try {
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
        if (-not @(Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue | Where-Object { $_.Version -ge [version]'2.8.5.201' }).Count) {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers -ErrorAction Stop | Out-Null
        }
        Install-Module -Name $ModName -RequiredVersion $fx.Version -Repository PSGallery -Scope AllUsers -Force -AllowClobber -ErrorAction Stop
        Out-L "WinGet-Modul $($fx.Version) installiert"
    } catch {
        if ($had) { Out-L "Warnung: WinGet-Modul $($fx.Version) nicht installierbar ($($_.Exception.Message)) - die vorhandene Version wird verwendet" }
        else { $script:TErr += "WinGet-Modul nicht installierbar (Internet/Proxy?): $($_.Exception.Message)" }
    }
}
# Signaturen der Moduldateien (nur signierbare Dateitypen; Hilfe-XML und Texte haben keine Signatur)
function Get-TModuleSigFiles([string]$Dir) {
    return @(Get-ChildItem -LiteralPath $Dir -Recurse -File -ErrorAction Stop | Where-Object { @('.psd1', '.psm1', '.ps1', '.ps1xml', '.dll', '.winmd', '.cat') -contains $_.Extension.ToLowerInvariant() } |
        ForEach-Object { $s = Get-AuthenticodeSignature -LiteralPath $_.FullName; @{ Path = $_.FullName; Status = "$($s.Status)"; Subject = "$($s.SignerCertificate.Subject)" } })
}
# Signatur gueltig? (rein) $Sigs: @{ Path; Status; Subject } je Datei. Rueckgabe '' = gueltig, sonst Grund.
# Jede Datei gueltig signiert und Zertifikat-Subject endet auf den Herausgeber; die Modulbeschreibung (.psd1) muss dabei sein.
function Test-TModuleSignature($Sigs, [string]$Publisher) {
    $all = @($Sigs | Where-Object { $_ })
    if (-not $all.Count) { return 'keine signierten Dateien' }
    if (-not @($all | Where-Object { "$($_.Path)" -like '*.psd1' }).Count) { return 'Modulbeschreibung (.psd1) fehlt' }
    foreach ($s in $all) {
        if ("$($s.Status)" -ne 'Valid') { return "$(Split-Path "$($s.Path)" -Leaf): $($s.Status)" }
        if (-not $Publisher -or -not "$($s.Subject)".EndsWith($Publisher, [StringComparison]::OrdinalIgnoreCase)) { return "$(Split-Path "$($s.Path)" -Leaf): anderer Herausgeber" }
    }
    return ''
}
# welches Modul laden? Feste Version mit gueltiger Signatur, sonst die hoechste andere fuer alle Benutzer (mit Hinweis), sonst ''
# (dann wie bisher nach Namen). Rueckgabe @{ Path; Note } - gibt selbst nichts aus. Ungueltige Signatur: nicht laden, nichts loeschen.
function Get-TModuleLoad {
    $fx = Get-TModFixed
    $note = ''
    if ($fx) {
        $psd = Join-Path $ModRoot "$($fx.Version)\$ModName.psd1"
        if (Test-Path -LiteralPath $psd) {
            $why = 'nicht pruefbar'
            try { $why = Test-TModuleSignature (Get-TModuleSigFiles (Split-Path $psd -Parent)) $fx.Herausgeber } catch { $why = "nicht pruefbar ($($_.Exception.Message))" }
            if (-not $why) { return @{ Path = $psd; Note = '' } }
            $note = "Warnung: WinGet-Modul $($fx.Version) wird nicht geladen, Signatur ungueltig ($why)"
        }
    }
    $oth = @(Get-ChildItem -LiteralPath $ModRoot -Directory -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -match '^\d+(\.\d+){1,3}$' -and (-not $fx -or $_.Name -ne $fx.Version) -and (Test-Path -LiteralPath (Join-Path $_.FullName "$ModName.psd1")) } |
        Sort-Object { [version]$_.Name } -Descending)[0]
    if ($oth) {
        $why = if ($note) { $note } elseif ($fx) { "WinGet-Modul: feste Version $($fx.Version) fehlt" } else { 'WinGet-Modul: keine gueltige feste Version' }
        return @{ Path = (Join-Path $oth.FullName "$ModName.psd1"); Note = "$why - die vorhandene Version $($oth.Name) wird verwendet" }
    }
    return @{ Path = ''; Note = $note }
}
# einmal je Lauf bestimmen und den Hinweis ins Protokoll schreiben
$script:TModLoad = $null
function Resolve-TModuleLoad {
    if ($null -ne $script:TModLoad) { return }
    $script:TModLoad = Get-TModuleLoad
    if ($script:TModLoad.Note) { Out-L $script:TModLoad.Note }
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
    # Modul in der festen Version (Signatur geprueft), sonst wie bisher den Modulordner
    Resolve-TModuleLoad
    $mp = $(if ($script:TModLoad.Path) { $script:TModLoad.Path } else { Join-Path $env:ProgramFiles "WindowsPowerShell\Modules\$ModName" }) -replace "'", "''"
    # Ausnahme von den festen Versionen: Repair-WinGetPackageManager -Latest laedt den App Installer (WinGet) in der neuesten Fassung
    # von Microsoft. Der App Installer ist ein Windows-Bestandteil, den Microsoft selbst aktuell haelt; eine feste aeltere Fassung
    # passt oft nicht zum Windows-Stand. Laeuft nur, wenn WinGet fehlt oder nicht funktioniert.
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
        # Modul in der festen Version laden (Pfad), sonst wie bisher nach Namen
        Resolve-TModuleLoad
        if ($Request -is [hashtable] -and -not $Request.ContainsKey('ModulePath')) { $Request = $Request.Clone(); $Request.ModulePath = "$($script:TModLoad.Path)" }
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
        $t0 = Get-Date; $seen = 0; $doneAt = $null; $cancelSent = $false; $beat = Get-Date
        $rf = Join-Path $dir 'result.json'; $lf = Join-Path $dir 'log.txt'
        while ($true) {
            # Lebenszeichen fuer die Fernsitzung (WinRM/Firewalls beenden stille Verbindungen): alle 60 s eine Zeile, die HUMig nicht anzeigt
            if (((Get-Date) - $beat).TotalSeconds -ge 60) { Out-L "#WAIT|$($curId)|$([int]((Get-Date) - $t0).TotalSeconds)"; $beat = Get-Date }
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
    if ($script:TRes -and $script:TRes.PSObject.Properties['Notes']) { foreach ($n in @($script:TRes.Notes | Where-Object { $_ })) { Out-L "$n" } }
}

# PowerShell 7 (fuer das Lesen als SYSTEM und den Zeitplan): eigene Kopie von HUMig in Programme\HUMig\PowerShell7 (nur
# Administratoren duerfen schreiben), offizielles ZIP-Paket von GitHub (Microsoft) in genau der festen Fassung aus dem Auftrag
# (Payload.Tools, Config\tools.json von HUMig), SHA256 geprueft. Nie eine neuere Fassung von irgendwoher.
# Das per MSI installierte PowerShell 7 (Programme\PowerShell\7) wird verwendet und nie angefasst.
# Eine aeltere eigene Kopie wird ohne Rueckfrage ersetzt: in PowerShell7.neu entpacken, pruefen, umbenennen (alte ueber
# PowerShell7.alt), bei Fehlschlag zurueckbenennen. Scheitert etwas, bleibt die vorhandene Kopie und der Lauf geht mit ihr weiter.
# Zustand danach in $script:TPwshState: Msi | Vorhanden | Aktuell | Neuer | Laeuft | Neu | Ersetzt | Behalten | Fehlt
$PwshNeu = "$PwshDir.neu"
$PwshAlt = "$PwshDir.alt"
$PwshInfo = 'humig-pwsh.json'
# einzelne Schritte (ersetzbar in den Tests)
function Get-TPwshZip([string]$Url, [string]$OutFile) { Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -ErrorAction Stop }
function Get-TFileSha256([string]$Path) { return "$((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash)".ToUpperInvariant() }
function Expand-TPwshZip([string]$Zip, [string]$Dest) { Expand-Archive -LiteralPath $Zip -DestinationPath $Dest -Force }
function Move-TDir([string]$From, [string]$To) { Move-Item -LiteralPath $From -Destination $To -ErrorAction Stop }
function Remove-TDir([string]$Path) { if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop } }
function Get-TProcessPaths { return @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop | ForEach-Object { "$($_.ExecutablePath)" } | Where-Object { $_ }) }
function Get-TFileProductVersion([string]$Path) {
    $vi = (Get-Item -LiteralPath $Path -ErrorAction Stop).VersionInfo
    if ("$($vi.ProductVersion)".Trim()) { return "$($vi.ProductVersion)" }
    return "$($vi.FileVersion)"
}
# laeuft ein Programm aus einem dieser Ordner (oder darunter)? (rein)
function Test-TPathsInDirs([string[]]$Paths, [string[]]$Dirs) {
    foreach ($d in @($Dirs | Where-Object { $_ })) {
        $pre = "$d".TrimEnd('\') + '\'
        foreach ($p in @($Paths | Where-Object { $_ })) { if ("$p".StartsWith($pre, [StringComparison]::OrdinalIgnoreCase)) { return $true } }
    }
    return $false
}
# Prozessliste nicht lesbar: als "laeuft" werten (dann lieber nicht tauschen)
function Test-TPwshInUse([string[]]$Dirs) {
    try { $p = Get-TProcessPaths } catch { return $true }
    return (Test-TPathsInDirs $p $Dirs)
}
# Version der eigenen Kopie: humig-pwsh.json (schreibt HUMig beim Einrichten), sonst Produktversion von pwsh.exe; '' = nicht lesbar
function Get-TPwshOwnVersion([string]$Dir = $PwshDir) {
    try { $j = [System.IO.File]::ReadAllText((Join-Path $Dir $PwshInfo)) | ConvertFrom-Json; if ("$($j.version)" -match '^\d+\.\d+\.\d+$') { return "$($j.version)" } } catch { }
    try { return "$(Get-TFileProductVersion (Join-Path $Dir 'pwsh.exe'))".Trim() } catch { return '' }
}
# Reste eines abgebrochenen Tauschs: fehlt der Ordner ganz und hat PowerShell7.alt ein pwsh.exe, zurueckbenennen (nie loeschen);
# PowerShell7.neu und ein ueberzaehliges PowerShell7.alt entfernen, wenn nichts daraus laeuft
function Clear-TPwshLeftover {
    if (-not (Test-Path -LiteralPath $PwshDir) -and (Test-Path -LiteralPath (Join-Path $PwshAlt 'pwsh.exe'))) {
        try { Move-TDir $PwshAlt $PwshDir; Out-L 'PowerShell 7: abgebrochenen Tausch zurueckgenommen, vorige Fassung wiederhergestellt' }
        catch { Out-L "Warnung: PowerShell 7: vorige Fassung nicht wiederherstellbar ($($_.Exception.Message))" }
    }
    foreach ($d in @($PwshNeu, $PwshAlt)) {
        if (-not (Test-Path -LiteralPath $d)) { continue }
        if ($d -eq $PwshAlt -and -not (Test-Path -LiteralPath $PwshDir)) { continue }
        if (Test-TPwshInUse @($d)) { continue }
        try { Remove-TDir $d; Out-L "PowerShell 7: Rest eines abgebrochenen Tauschs entfernt ($(Split-Path $d -Leaf))" } catch { }
    }
}
# feste Fassung laden, pruefen und an die Stelle von PowerShell7 setzen. Rueckgabe '' = fertig, sonst Fehlertext (nichts ausgeben:
# das Ergebnis ist der Rueckgabewert). Die bisherige Kopie bleibt bei jedem Fehler erhalten.
function Install-TPwshPackage($Pk) {
    $tmp = Join-Path $Base "pwsh_$([guid]::NewGuid().ToString('N')).zip"
    $ok = $false
    try {
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
        New-Item -ItemType Directory -Path $Base -Force | Out-Null
        Remove-TDir $PwshNeu
        Get-TPwshZip "$($Pk.Url)" $tmp
        if ((Get-TFileSha256 $tmp) -ne "$($Pk.Sha256)".ToUpperInvariant()) { throw "Pruefsumme passt nicht ($($Pk.Datei))" }
        New-Item -ItemType Directory -Path $PwshNeu -Force | Out-Null
        Expand-TPwshZip $tmp $PwshNeu
        if (-not (Test-Path -LiteralPath (Join-Path $PwshNeu 'pwsh.exe'))) { throw 'pwsh.exe nach dem Entpacken nicht gefunden' }
        $info = ConvertTo-Json -Compress -InputObject ([ordered]@{ version = "$($Pk.Version)"; sha256 = "$($Pk.Sha256)"; datei = "$($Pk.Datei)" })
        [System.IO.File]::WriteAllText((Join-Path $PwshNeu $PwshInfo), $info, (New-Object System.Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $PwshDir) {
            Remove-TDir $PwshAlt
            Move-TDir $PwshDir $PwshAlt
            try { Move-TDir $PwshNeu $PwshDir }
            catch { $e = $_.Exception.Message; try { Move-TDir $PwshAlt $PwshDir } catch { }; throw "Tausch fehlgeschlagen ($e)" }
            try { Remove-TDir $PwshAlt } catch { }   # bleibt etwas liegen, raeumt es der naechste Lauf auf
        } else { Move-TDir $PwshNeu $PwshDir }
        $ok = $true
        return ''
    } catch { return "$($_.Exception.Message)" }
    finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        if (-not $ok) { try { Remove-TDir $PwshNeu } catch { } }
    }
}
function Install-TPwsh {
    $script:TPwshState = ''
    if (Test-Path -LiteralPath $PwshMsi) { $script:TPwshState = 'Msi'; return }
    $own = Join-Path $PwshDir 'pwsh.exe'
    if (-not $My.InstallPwsh) {
        if (Test-Path -LiteralPath $own) { $script:TPwshState = 'Vorhanden'; return }
        $script:TErr += 'PowerShell 7 fehlt (fuer das Lesen ohne angemeldeten Benutzer und den Zeitplan noetig)'; $script:TPwshState = 'Fehlt'; return
    }
    Clear-TPwshLeftover
    $have = Test-Path -LiteralPath $own
    $pk = Select-TPwshPackage $Payload.Tools "$env:PROCESSOR_ARCHITECTURE"
    if (-not $pk) {
        if ($have) { Out-L 'Warnung: keine gueltige feste Version fuer PowerShell 7 (Config\tools.json) - die vorhandene Fassung wird verwendet'; $script:TPwshState = 'Behalten'; return }
        $script:TErr += 'PowerShell 7 nicht installierbar: keine gueltige feste Version (Config\tools.json von HUMig)'; $script:TPwshState = 'Fehlt'; return
    }
    $cur = ''
    if ($have) {
        $cur = Get-TPwshOwnVersion
        $c = Compare-TPwshVersion $cur $pk.Version
        if ($c -eq 0) { $script:TPwshState = 'Aktuell'; return }
        if ($c -eq 1) { Out-L "PowerShell 7: eigene Fassung $cur ist neuer als die feste $($pk.Version) - bleibt"; $script:TPwshState = 'Neuer'; return }
        if (-not $cur) { $cur = 'unbekannter Version' }
        if (Test-TPwshInUse @($PwshDir)) { Out-L "PowerShell 7 $cur laeuft gerade (z. B. Zeitplan) - wird bei einem spaeteren Lauf durch $($pk.Version) ersetzt"; $script:TPwshState = 'Laeuft'; return }
        Out-L "PowerShell 7 $cur wird durch die feste Fassung $($pk.Version) ersetzt (ZIP von Microsoft/GitHub, nur fuer HUMig) ..."
    } else { Out-L "PowerShell 7 $($pk.Version) laden (ZIP von Microsoft/GitHub, nur fuer HUMig) ..." }
    $err = Install-TPwshPackage $pk
    if (-not $err) { Out-L "PowerShell $($pk.Version) bereit ($PwshDir)"; $script:TPwshState = $(if ($have) { 'Ersetzt' } else { 'Neu' }); return }
    if ($have -and (Test-Path -LiteralPath $own)) { Out-L "Warnung: PowerShell 7 $($pk.Version) nicht eingerichtet ($err) - die vorhandene Fassung $cur wird weiter verwendet"; $script:TPwshState = 'Behalten'; return }
    $script:TErr += "PowerShell 7 nicht installierbar: $err"; $script:TPwshState = 'Fehlt'
}
# Taugt ein Ordner als Programmordner fuer die Suche nach laufenden Prozessen? Nie der Windows-Ordner (samt Unterordnern -
# DisplayIcon zeigt manchmal auf System32\msiexec.exe), nie Sammelordner (Programme, Common Files, ProgramData, Laufwerk,
# Benutzer-, Profil- und AppData-Wurzeln) - sonst gaelten svchost, ctfmon usw. als "laeuft" (B50)
function Test-TAppDir([string]$Dir) {
    $d = "$Dir".Trim().Trim('"').TrimEnd('\')
    if ($d.Length -le 3 -or $d -notmatch '^[A-Za-z]:\\') { return $false }
    $l = $d.ToLower()
    $win = "$(if ("$env:SystemRoot") { $env:SystemRoot } else { $env:windir })".TrimEnd('\').ToLower()
    if ($win -and ($l -eq $win -or $l.StartsWith($win + '\'))) { return $false }
    $roots = @("$env:ProgramFiles", "${env:ProgramFiles(x86)}", "$env:ProgramW6432", "$env:ProgramData", "$env:SystemDrive\", "$env:CommonProgramFiles", "${env:CommonProgramFiles(x86)}", "$env:CommonProgramW6432", "$env:PUBLIC") |
        Where-Object { $_ } | ForEach-Object { "$_".TrimEnd('\').ToLower() }
    if ($roots -contains $l) { return $false }
    # Store-Apps (WindowsApps samt Unterordnern) und Benutzerordner wie Downloads/Desktop/Dokumente: nie als Programmordner (B54)
    if ($l -match '\\windowsapps(\\|$)') { return $false }
    if ($l -match '^[a-z]:\\(users|documents and settings)\\[^\\]+\\(downloads|desktop|documents|dokumente|pictures|bilder|videos|music|musik|onedrive[^\\]*)(\\|$)') { return $false }
    if ($l -match '^[a-z]:\\(users|documents and settings)(\\[^\\]+(\\appdata(\\(local|roaming|locallow)(\\(programs|temp|microsoft|packages))?)?)?)?$') { return $false }
    return $true
}
# Prozess-/Dienstpfad im Windows-Ordner? Dort beendet bzw. stoppt HUMig nie etwas (Absicherung zusaetzlich zu Test-TAppDir)
function Test-TWinPath([string]$Path) {
    $win = "$(if ("$env:SystemRoot") { $env:SystemRoot } else { $env:windir })".TrimEnd('\').ToLower()
    return [bool]($win -and "$Path".ToLower().StartsWith($win + '\'))
}
# Laufende Programme zu Paketen (wie Get-HMAuRunning in HUMig, hier fuer entfernte PCs - Fenster sind aus der Fernsitzung nicht
# erkennbar): Installationsordner aus den Deinstallations-Eintraegen (auch der angemeldeten Benutzer), Prozesse darin.
# Art: Service (Dienst), ServiceChild (Sitzung 0), App (in einer Benutzersitzung, mit Besitzer). Heuristik.
function Get-TRunning($Items) {
    $keys = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'Registry::HKEY_USERS\*\Software\Microsoft\Windows\CurrentVersion\Uninstall\*')
    $reg = @(foreach ($k in $keys) { Get-ItemProperty -Path $k -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName } })
    $procs = @(Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.ExecutablePath })
    $svc = @{}
    foreach ($x in @(Get-CimInstance -ClassName Win32_Service -Filter "State='Running'" -ErrorAction SilentlyContinue)) { if ([int]$x.ProcessId -gt 0) { $svc[[int]$x.ProcessId] = @(@($svc[[int]$x.ProcessId]) + @("$($x.Name)") | Where-Object { $_ }) } }
    foreach ($it in @($Items | Where-Object { $_ })) {
        $n = "$($it.Name)".Trim()
        if (-not $n) { continue }
        $cand = @(foreach ($r in @($reg | Where-Object { "$($_.DisplayName)" -eq $n -or "$($_.DisplayName)".StartsWith("$n ", [StringComparison]::OrdinalIgnoreCase) })) {
                $d = "$($r.InstallLocation)".Trim().Trim('"')
                if (-not $d -and "$($r.DisplayIcon)") { try { $d = Split-Path ("$($r.DisplayIcon)" -replace ',\s*-?\d+$', '').Trim('"') -Parent } catch { $d = '' } }
                if ($d) { $d.TrimEnd('\') }
            })
        $dirs = @($cand | Where-Object { $_ -and (Test-TAppDir $_) } | Select-Object -Unique)
        if (-not $dirs.Count) { continue }
        $run = @($procs | Where-Object { $pp = "$($_.ExecutablePath)".ToLower(); -not (Test-TWinPath $pp) -and @($dirs | Where-Object { $pp.StartsWith($_.ToLower() + '\') }).Count })
        if (-not $run.Count) { continue }
        $pl = @(foreach ($p in $run) {
                $pid2 = [int]$p.ProcessId
                $kind = if ($svc.ContainsKey($pid2)) { 'Service' } elseif ([int]$p.SessionId -eq 0) { 'ServiceChild' } else { 'App' }
                $own = ''; $osid = ''
                if ($kind -eq 'App') {
                    try { $o = Invoke-CimMethod -InputObject $p -MethodName GetOwner -ErrorAction Stop; if ($o.User) { $own = "$($o.Domain)\$($o.User)" } } catch { }
                    try { $osid = "$((Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid -ErrorAction Stop).Sid)" } catch { }
                }
                [pscustomobject]@{ Name = "$($p.Name)"; Id = $pid2; SessionId = [int]$p.SessionId; Kind = $kind; Path = "$($p.ExecutablePath)"; Services = @($(if ($kind -eq 'Service') { $svc[$pid2] })); Owner = $own; OwnerSid = $osid }
            })
        $kt = @{ Service = 'Dienst'; App = 'Programm'; ServiceChild = 'Dienst-Unterprozess' }
        [pscustomobject]@{
            Id = "$($it.Id)"; Name = $n; Procs = $pl
            Running = (@($pl | ForEach-Object { "$($_.Name) ($($_.Id), $($kt[$_.Kind])$(if ($_.Kind -eq 'Service') { ': ' + (@($_.Services) -join ',') } elseif ($_.Owner) { ': ' + $_.Owner }))" }) -join ', ')
        }
    }
}
# Laufendes Programm vor dem Update beenden (nur nach Entscheidung in HUMig): Dienste stoppen, Programme in Benutzersitzungen
# beenden (hart - aus der Fernsitzung laesst sich kein Fenster hoeflich schliessen). $Rs merkt, was danach wieder zu starten ist.
# Ergebnis in $script:TLeft (Prozess-Ids, die noch laufen) - NICHT als Rueckgabe: die Out-L-Zeilen der Funktion gehen in die
# Ausgabe-Pipeline, eine eingefangene Rueckgabe enthielte sie mit und saehe wie "laeuft noch" aus (Befund aus v2.1.13)
function Stop-TRunning($Run, [hashtable]$Rs) {
    $script:TLeft = @()
    # nie etwas aus dem Windows-Ordner anfassen (svchost, ctfmon ...) - auch wenn die Erkennung es faelschlich zuordnet (B50)
    $pl = @($Run.Procs | Where-Object { $_ -and -not (Test-TWinPath "$($_.Path)") })
    foreach ($x in @($Run.Procs | Where-Object { $_ -and (Test-TWinPath "$($_.Path)") })) { Out-L "  $($x.Name) ($($x.Id)) liegt im Windows-Ordner - wird nicht angefasst" }
    foreach ($sn in @($pl | Where-Object { "$($_.Kind)" -eq 'Service' } | ForEach-Object { @($_.Services) } | Where-Object { $_ } | Select-Object -Unique)) {
        try {
            # abhaengige Dienste stoppt -Force mit - merken und danach wieder starten (B53)
            $dep = @(@((Get-Service -Name $sn -ErrorAction Stop).DependentServices) | Where-Object { "$($_.Status)" -eq 'Running' } | ForEach-Object { "$($_.Name)" })
            Stop-Service -Name $sn -Force -ErrorAction Stop
            Out-L "  Dienst $sn gestoppt$(if ($dep.Count) { " (mit abhaengigen: $($dep -join ', '))" }) - wird nach dem Update wieder gestartet"
            if ($Rs.Services -notcontains $sn) { $Rs.Services += $sn }
            foreach ($dn in $dep) { if ($Rs.Services -notcontains $dn) { $Rs.Services += $dn } }
        } catch { Out-L "  Dienst $sn nicht stoppbar: $($_.Exception.Message)" }
    }
    foreach ($p in @($pl | Where-Object { "$($_.Kind)" -eq 'App' })) {
        try {
            Stop-Process -Id ([int]$p.Id) -Force -ErrorAction Stop
            Out-L "  $($p.Name) ($($p.Id)$(if ($p.Owner) { ", $($p.Owner)" })) beendet"
            if ($p.Path -and ($p.Owner -or $p.OwnerSid) -and -not @($Rs.Apps | Where-Object { $_.Path -eq $p.Path -and $_.Owner -eq $p.Owner -and "$($_.OwnerSid)" -eq "$($p.OwnerSid)" }).Count) { $Rs.Apps += [pscustomobject]@{ Path = "$($p.Path)"; Owner = "$($p.Owner)"; OwnerSid = "$($p.OwnerSid)"; Name = "$($p.Name)" } }
        } catch { if (Get-Process -Id ([int]$p.Id) -ErrorAction SilentlyContinue) { Out-L "  $($p.Name) ($($p.Id)) nicht beendbar: $($_.Exception.Message)" } else { Out-L "  $($p.Name) ($($p.Id)) schon beendet (mit dem Dienst)" } }
    }
    $ids = @($pl | ForEach-Object { [int]$_.Id })
    $t0 = Get-Date
    do { Start-Sleep -Seconds 1; $alive = @($ids | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue }) } while ($alive.Count -and ((Get-Date) - $t0).TotalSeconds -lt 20)
    foreach ($i in $alive) {
        if (@($pl | Where-Object { [int]$_.Id -eq $i -and "$($_.Kind)" -in @('Service', 'ServiceChild') }).Count) { try { Stop-Process -Id $i -Force -ErrorAction Stop; Out-L "  Prozess $i (zum gestoppten Dienst) beendet" } catch { } }
    }
    Start-Sleep -Seconds 1
    $script:TLeft = @($ids | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue } | Select-Object -Unique)
}
# Nach dem Update: gestoppte Dienste und beendete Programme wieder starten (Programme im Konto des Besitzers, wenn er noch
# angemeldet ist und der Installer es nicht schon gestartet hat)
function Restart-TStopped([hashtable]$Rs) {
    foreach ($sn in @($Rs.Services)) {
        try { $s = Get-Service -Name $sn -ErrorAction Stop; if ("$($s.Status)" -ne 'Running') { Start-Service -Name $sn -ErrorAction Stop; Out-L "Dienst $sn wieder gestartet" } }
        catch { $script:TErr += "Dienst $sn nicht startbar: $($_.Exception.Message)" }
    }
    $lsids = @(Get-TLoggedOnSids)
    $logged = @($lsids | ForEach-Object { Get-TAccount $_ })
    foreach ($a in @($Rs.Apps)) {
        if (@(Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue | Where-Object { "$($_.ExecutablePath)" -ieq $a.Path }).Count) { continue }
        # angemeldet? per SID (robust auch ohne DC-Verbindung), sonst per Kontoname
        $on = if ("$($a.OwnerSid)") { $lsids -contains "$($a.OwnerSid)" } else { $logged -contains "$($a.Owner)" }
        if (-not $on) { Out-L "$($a.Name) nicht neu gestartet: $(if ($a.Owner) { $a.Owner } else { $a.OwnerSid }) ist nicht mehr angemeldet"; continue }
        if (-not (Test-Path -LiteralPath $a.Path)) { Out-L "$($a.Name) nicht neu gestartet: $($a.Path) gibt es nach dem Update nicht mehr"; continue }
        $tn = 'HUMig_Restart_' + [guid]::NewGuid().ToString('N')
        try {
            # Arbeitsordner = Programmordner (sonst System32 - manche Programme finden ihre Dateien nicht, B52)
            $act = New-ScheduledTaskAction -Execute $a.Path -WorkingDirectory (Split-Path $a.Path -Parent)
            $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Seconds 0)
            $reg = $false; $rerr = ''
            foreach ($uid in @("$($a.Owner)", "$($a.OwnerSid)") | Where-Object { $_ }) {
                try { $pr = New-ScheduledTaskPrincipal -UserId $uid -LogonType Interactive -RunLevel Limited; Register-ScheduledTask -TaskName $tn -TaskPath '\' -Action $act -Principal $pr -Settings $set -Force -ErrorAction Stop | Out-Null; $reg = $true; break } catch { $rerr = $_.Exception.Message }
            }
            if (-not $reg) { throw $rerr }
            Start-ScheduledTask -TaskPath '\' -TaskName $tn
            Start-Sleep -Seconds 3
            Out-L "$($a.Name) fuer $(if ($a.Owner) { $a.Owner } else { $a.OwnerSid }) wieder gestartet"
        } catch { Out-L "$($a.Name) nicht neu gestartet: $($_.Exception.Message)" }
        finally { Unregister-ScheduledTask -TaskPath '\' -TaskName $tn -Confirm:$false -ErrorAction SilentlyContinue }
    }
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
        'Running' {
            Out-R ([pscustomobject]@{ Running = @(Get-TRunning @($My.Items | Where-Object { $_ })); Errors = $script:TErr })
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
                if ($iid -ieq 'Microsoft.AppInstaller') {
                    $res += [pscustomobject]@{ Id = $iid; Status = 'Skipped'; Code = 0; InstallerErrorCode = 0; ExtendedErrorCode = 0; Reboot = $false; Text = 'uebersprungen - App Installer tauscht winget waehrend des Laufs aus; er aktualisiert sich ueber den Microsoft Store' }
                    Out-L "App Installer: wird ueber App-Updates nicht aktualisiert (tauscht winget waehrend des Laufs aus) - aktualisiert sich ueber den Microsoft Store"
                    Out-L "#DONE|$iid|Skipped|0|0|0|False"
                    continue
                }
                if ($iid -notmatch '^[^\s\-"][^\s"]{0,254}\z' -or "$($it.Source)" -notmatch '^(?=.{1,64}\z)[A-Za-z0-9._](?:[A-Za-z0-9._ -]*[A-Za-z0-9._-])?\z') {
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
            # laufende Programme, die laut Entscheidung in HUMig beendet werden sollen (Proc = Stop): jetzt beenden - laesst sich eines
            # nicht beenden, wird es nicht aktualisiert (sonst bricht der Installer ab und hinterlaesst evtl. ein halb entferntes Programm)
            $rs = @{ Services = @(); Apps = @() }
            $stopIt = @($all | Where-Object { "$($_.Proc)" -eq 'Stop' })
            if ($stopIt.Count) {
                foreach ($rn in @(Get-TRunning $stopIt)) {
                    Out-L "$($rn.Name): laeuft ($($rn.Running)) - wird beendet ..."
                    Stop-TRunning $rn $rs
                    if (@($script:TLeft).Count) {
                        $res += [pscustomobject]@{ Id = "$($rn.Id)"; Status = 'Skipped'; Code = 0; InstallerErrorCode = 0; ExtendedErrorCode = 0; Reboot = $false; Text = 'uebersprungen - Programm liess sich nicht beenden' }
                        Out-L "$($rn.Name): liess sich nicht beenden - nicht aktualisiert"
                        Out-L "#DONE|$($rn.Id)|Skipped|0|0|0|False"
                        $all = @($all | Where-Object { "$($_.Id)" -ne "$($rn.Id)" })
                    }
                }
            }
            $mach = @($all | Where-Object { $Op -eq 'Install' -or "$($_.Scope)" -ne 'User' })
            $usr = @($all | Where-Object { $Op -ne 'Install' -and "$($_.Scope)" -eq 'User' })
            if ($mach.Count) {
                Out-L "$($mach.Count) Programm(e) fuer alle Benutzer (als SYSTEM) ..."
                # je Programm hoechstens $SysItemMin Minuten; haengt ein Installer, Aufgabe beenden und den Rest in einer neuen Aufgabe
                $todoM = @($mach)
                while ($todoM.Count) {
                    Invoke-TTask 'SYSTEM' @{ Mode = $Op; Cli = $true; Items = @($todoM | ForEach-Object { @{ Id = "$($_.Id)"; Source = "$($_.Source)"; Unknown = [bool]$_.Unknown } }) } $false 10800 $SysItemMin
                    if ($script:TRes) { $res += @($script:TRes.Results); break }
                    $gotM = @()
                    foreach ($d in @($script:TDone)) {
                        $res += [pscustomobject]@{ Id = "$($d[1])"; Status = "$($d[2])"; Code = $(if ($d.Count -gt 3) { $d[3] } else { 0 }); InstallerErrorCode = $(if ($d.Count -gt 4) { $d[4] } else { 0 }); ExtendedErrorCode = $(if ($d.Count -gt 5) { $d[5] } else { 0 }); Reboot = ($d.Count -gt 6 -and $d[6] -eq 'True'); Text = '' }
                        $gotM += "$($d[1])"
                    }
                    if (-not $script:TTimedOut) { break }
                    $res += [pscustomobject]@{ Id = "$($script:TTimedOut)"; Status = 'Exception'; Code = 0; InstallerErrorCode = 0; ExtendedErrorCode = 0; Reboot = $false; Text = "abgebrochen nach $SysItemMin min (Zeitlimit je Programm) - der Installer hing; am PC pruefen und erneut aktualisieren" }
                    Out-L "$($script:TTimedOut): nach $SysItemMin min abgebrochen (Zeitlimit je Programm) - weiter mit den uebrigen"
                    $gotM += "$($script:TTimedOut)"
                    $todoM = @($todoM | Where-Object { $gotM -notcontains "$($_.Id)" })
                }
            }
            $usid = "$($My.UserSid)"
            $fromSys = @()   # Pakete, die als SYSTEM nicht gefunden wurden und ins Benutzerkonto wanderten (kein zweiter SYSTEM-Versuch, B60)
            # 0x8A150014 als SYSTEM: Paket ist nur im Benutzerkonto sichtbar (z.B. WSL) -> im Benutzerkonto noch einmal versuchen
            if ($Op -eq 'Update' -and $res.Count) {
                $nf = @($res | Where-Object { "$($_.Status)" -eq 'Cli' -and "$($_.Code)" -eq '-1978335212' })
                if ($nf.Count) {
                    $rsid = Get-TUserSid
                    if ($rsid) {
                        $ids = @($nf | ForEach-Object { "$($_.Id)" })
                        $res = @($res | Where-Object { $ids -notcontains "$($_.Id)" })
                        $usr = @($usr) + @($mach | Where-Object { $ids -contains "$($_.Id)" })
                        $fromSys = @($ids)
                        if (-not $usid -or @(Get-TLoggedOnSids) -notcontains $usid) { $usid = $rsid }
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
            # interner WinGet-Fehler im Benutzerkonto (meist Store-/MSIX-Apps): einmal fuer alle Benutzer als SYSTEM versuchen (B57)
            if ($Op -eq 'Update') {
                $ie = @($res | Where-Object { "$($_.Status)" -eq 'InternalError' -and $fromSys -notcontains "$($_.Id)" })
                foreach ($x in @($res | Where-Object { "$($_.Status)" -eq 'InternalError' -and $fromSys -contains "$($_.Id)" })) {
                    $x.Status = 'Exception'; $x.Text = 'Store-App: fuer alle Benutzer nicht gefunden, im Benutzerkonto interner WinGet-Fehler - ueber den Microsoft Store aktualisieren'
                }
                if ($ie.Count) {
                    $ids2 = @($ie | ForEach-Object { "$($_.Id)" })
                    Out-L "$($ids2.Count) Programm(e) im Benutzerkonto gescheitert (interner WinGet-Fehler, meist Store-Apps) - neuer Versuch fuer alle Benutzer (als SYSTEM) ..."
                    $res = @($res | Where-Object { $ids2 -notcontains "$($_.Id)" })
                    $retry = @($all | Where-Object { $ids2 -contains "$($_.Id)" })
                    Invoke-TTask 'SYSTEM' @{ Mode = 'Update'; Cli = $true; Items = @($retry | ForEach-Object { @{ Id = "$($_.Id)"; Source = "$($_.Source)"; Unknown = [bool]$_.Unknown } }) } $false 10800
                    if ($script:TRes) {
                        foreach ($x in @($script:TRes.Results | Where-Object { $_ })) {
                            # auch als SYSTEM nicht gefunden: es ist eine Store-App - der Store-Hinweis ist hilfreicher als "nicht gefunden" (B60)
                            if ("$($x.Status)" -eq 'Cli' -and "$($x.Code)" -eq '-1978335212') { $x.Status = 'Exception'; $x.Text = 'Store-App: im Benutzerkonto interner WinGet-Fehler, fuer alle Benutzer nicht gefunden - ueber den Microsoft Store aktualisieren (oder am PC als Benutzer: winget upgrade --id ' + "$($x.Id)" + ')' }
                            $res += $x
                        }
                    }
                }
            }
            if ($rs.Services.Count -or $rs.Apps.Count) { Restart-TStopped $rs }
            Out-R ([pscustomobject]@{ Results = @($res | Where-Object { $_ }); Errors = $script:TErr })
        }
        'ScheduleSet' {
            Install-TModule
            Install-TPwsh
            if (-not (Test-TModule) -or -not (Get-TPwsh)) { Out-R ([pscustomobject]@{ Ok = $false; Errors = $script:TErr }); break }
            $dir = Join-Path $Base 'auto'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $dir 'auto.ps1'), $AutoText, (New-Object System.Text.UTF8Encoding($true)))
            Resolve-TModuleLoad
            [pscustomobject]@{ Sources = @($My.Sources); Exclude = @($My.Exclude); Location = "$($My.Location)"; Created = (Get-Date).ToString('yyyy-MM-dd HH:mm'); By = "$($My.By)"; ModulePath = "$($script:TModLoad.Path)" } |
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
            $o = [ordered]@{ Exists = [bool]$t; When = ''; Next = ''; Last = ''; LastResult = ''; LastErr = $null; Summary = ''; Running = $false; Progress = ''; Log = @(); History = @(); Errors = @() }
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
            if (Test-Path -LiteralPath $lf) { try { $l = Get-Content -LiteralPath $lf -Raw -Encoding UTF8 | ConvertFrom-Json; $o.LastErr = [int]"0$($l.Err)"; $o.Summary = "$($l.Date): $($l.Ok) aktualisiert, $($l.Err) Fehler, $($l.Excluded) Ausnahme(n)$(if ([int]"0$($l.Skipped)") { ", $($l.Skipped) uebersprungen (lief)" })" } catch { } }
            $pf = Join-Path $Base 'auto\progress.json'
            if ($o.Running -and (Test-Path -LiteralPath $pf)) { try { $g = Get-Content -LiteralPath $pf -Raw -Encoding UTF8 | ConvertFrom-Json; $o.Progress = "$($g.Done)/$($g.Total)$(if ($g.Current) { ": $($g.Current)" }) ($($g.Ok) ok, $($g.Err) Fehler)" } catch { } }
            $lg = Join-Path $Base 'auto\log.txt'
            # als reine Zeichenketten: Zeilen aus Get-Content tragen Zusatz-Eigenschaften (PSPath, PSDrive, PSProvider ...),
            # ConvertTo-Json -Depth 8 (Out-R) haengt damit praktisch endlos
            if (Test-Path -LiteralPath $lg) { try { $o.Log = @(Get-Content -LiteralPath $lg -Tail 80 -Encoding UTF8 | ForEach-Object { "$_" }) } catch { } }
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
