#Requires -Version 5.1
<#
.SYNOPSIS
    App-Updates (WinGet): Status pruefen, WinGet einrichten, verfuegbare Updates lesen, Programme aktualisieren.
.DESCRIPTION
    Verwendet das offizielle PowerShell-Modul Microsoft.WinGet.Client (Objekte statt Textausgabe von winget.exe -
    dort sind Spalten uebersetzt und Paket-IDs gekuerzt). Das Modul laeuft unter Windows PowerShell 5.1.
    Laeuft im Hintergrund-Runspace (Invoke-AsyncCommand / Start-LongJob) - kein WPF-Code hier.
.NOTES
    Zielmaschine: dieser PC, HUMig als Administrator (Modul fuer alle Benutzer installieren, Programme fuer alle Benutzer aktualisieren).
    Programme, die nur fuer einen anderen Benutzer installiert sind, sieht WinGet in diesem Konto nicht.
#>

$script:HMAuModule = 'Microsoft.WinGet.Client'
$script:HMAuAppInstaller = 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe'

# ----------------------------------------------------------------------------
# Reine Hilfsfunktionen (auch fuer die automatischen Tests)
# ----------------------------------------------------------------------------
# Ausnahme: Muster (Platzhalter * ?) passt auf Paket-ID oder Programmname. Rueckgabe: passender Eintrag oder $null
function Find-HMAuExclusion($Item, $Exclusions) {
    foreach ($e in @($Exclusions | Where-Object { $_ -and "$($_.Pattern)".Trim() })) {
        $p = "$($e.Pattern)".Trim()
        if ("$($Item.Id)" -like $p -or "$($Item.Name)" -like $p) { return $e }
    }
    return $null
}
# Ergebnis von Update-WinGetPackage lesbar machen
function Format-HMAuResult([string]$Status, $InstallerCode, $ExtendedCode, [bool]$Reboot) {
    $t = switch ($Status) {
        'Ok' { 'aktualisiert' }
        'NoApplicableUpgrade' { 'kein passendes Update (schon aktuell oder andere Variante installiert)' }
        'NoApplicableInstallers' { 'kein passender Installer (Architektur/Bereich)' }
        'BlockedByPolicy' { 'durch Richtlinie blockiert' }
        'DownloadError' { 'Download fehlgeschlagen (Netz/Proxy oder Hersteller blockiert WinGet)' }
        'InstallError' { 'Installer meldet Fehler' }
        'ManifestError' { 'Paketbeschreibung fehlerhaft' }
        'CatalogError' { 'Quelle nicht erreichbar' }
        'PackageAgreementsNotAccepted' { 'Lizenzvereinbarung nicht angenommen' }
        'InvalidOptions' { 'ungueltige Optionen' }
        'InternalError' { 'interner WinGet-Fehler' }
        default { "$Status" }
    }
    $code = 0; try { $code = [int64]$InstallerCode } catch { }
    $wgc = $false; try { $wgc = ('{0:X8}' -f [uint32](($code + 4294967296) % 4294967296)) -like '8A15*' } catch { }
    if ($code -and $Status -ne 'Ok' -and $wgc) {
        # WinGet-Fehlercode (HRESULT) statt Installer-Code -> Klartext wie bei winget.exe
        $t += " - $((Format-HMAuCliResult $code '').Text)"
    } elseif ($code -and $Status -ne 'Ok') {
        $c = switch ($code) { 1602 { ' - vom Benutzer abgebrochen' } 1603 { ' - schwerer Fehler beim Installieren (oft: Programm laeuft noch)' } 1618 { ' - andere Installation laeuft gerade' } 1638 { ' - andere Version bereits installiert' } default { '' } }
        $t += " (Code $code$c)"
    }
    if ($Reboot) { $t += ' - Neustart noetig' }
    return $t
}
# Ausgabe-Code von winget.exe (als SYSTEM) -> Status/Text. Rueckgabe: @{ Ok; Reboot; Text }
function Format-HMAuCliResult([int64]$Code, [string]$Out) {
    if ($Code -eq 0) { return @{ Ok = $true; Reboot = $false; Text = 'aktualisiert' } }
    $u = if ($Code -lt 0) { [uint32]($Code + 4294967296) } else { [uint32]$Code }   # negativer Exitcode = HRESULT
    $hex = '0x{0:X8}' -f $u
    $t = switch ($hex) {
        '0x8A150109' { return @{ Ok = $true; Reboot = $true; Text = 'aktualisiert - Neustart noetig' } }
        '0x8A15002B' { 'kein passendes Update (schon aktuell oder andere Variante installiert)' }
        '0x8A15004F' { 'neue Version ist nicht neuer als die installierte' }
        '0x8A150014' { 'kein installiertes Paket gefunden (nur fuer einen Benutzer installiert?)' }
        '0x8A15010A' { 'Neustart noetig, dann erneut versuchen' }
        '0x8A150101' { 'Programm laeuft noch - schliessen und erneut versuchen' }
        '0x8A150102' { 'andere Installation laeuft gerade' }
        '0x8A150104' { 'Abhaengigkeit fehlt' }
        '0x8A150106' { 'zu wenig Speicher' }
        '0x8A150008' { 'Download fehlgeschlagen (Netz/Proxy oder Hersteller blockiert WinGet)' }
        '0x8A15003A' { 'durch Gruppenrichtlinie blockiert' }
        '0x8A150019' { 'braucht Administratorrechte' }
        '0x8A150115' { 'Installer meldet Fehler' }
        '0x8A150006' { 'Installer meldet Fehler (Programm offen, Neustart ausstehend oder Installer defekt)' }
        '0x8A150010' { 'kein passender Installer fuer alle Benutzer bzw. diesen PC (nur pro Benutzer installierbar?)' }
        '0x8A150061' { 'schon installiert' }
        '0x8A15010D' { 'andere Version ist schon installiert' }
        '0x8A150003' { 'Befehl fehlgeschlagen (oft: Datei oder Programm in Benutzung - Programm schliessen und erneut versuchen)' }
        '0x8A150103' { 'Datei in Benutzung - Programm schliessen und erneut versuchen' }
        '0x8A150011' { 'Pruefsumme des Installers passt nicht (Hersteller hat die Datei getauscht, Paketliste noch nicht nachgezogen) - aus Sicherheitsgruenden nicht installiert, in einigen Tagen erneut versuchen' }
        default { 'Fehler' }
    }
    return @{ Ok = $false; Reboot = $false; Text = "$t ($hex)$(if ("$Out".Trim() -and $t -eq 'Fehler') { ": $Out" })" }
}
# Windows-Version fuer WinGet: Win10 1809+ / Win11 (Client), Windows Server 2025
function Test-HMAuOsSupported {
    $b = [Environment]::OSVersion.Version.Build
    $isServer = $false
    try { $isServer = ([int](Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).ProductType -ne 1) } catch { }
    if ($isServer) { return ($b -ge 26100) }
    return ($b -ge 17763)
}

# ----------------------------------------------------------------------------
# Status / Einrichten
# ----------------------------------------------------------------------------
function Get-HMAuState {
    $s = [ordered]@{ OsOk = (Test-HMAuOsSupported); Module = ''; ModuleAllUsers = $false; AppInstaller = ''; WinGet = ''; Ready = $false; Problem = '' }
    try { $m = @(Get-Module -ListAvailable -Name $script:HMAuModule | Sort-Object Version -Descending)[0]; if ($m) { $s.Module = "$($m.Version)" } } catch { }
    # SYSTEM und andere Benutzer finden das Modul nur, wenn es fuer alle Benutzer installiert ist (Programme\WindowsPowerShell\Modules)
    $s.ModuleAllUsers = (Test-Path -LiteralPath (Join-Path $env:ProgramFiles "WindowsPowerShell\Modules\$($script:HMAuModule)"))
    try { $a = @(Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' -ErrorAction Stop)[0]; if ($a) { $s.AppInstaller = "$($a.Version)" } } catch { }
    if (-not $s.OsOk) { $s.Problem = 'WinGet wird auf dieser Windows-Version nicht unterstuetzt (Windows 10 1809+/11, Windows Server 2025).' }
    elseif (-not $s.Module) { $s.Problem = "PowerShell-Modul $($script:HMAuModule) fehlt - 'WinGet einrichten'." }
    elseif (-not $s.ModuleAllUsers) { $s.Problem = "PowerShell-Modul $($script:HMAuModule) ist nur fuer einzelne Benutzer installiert - SYSTEM und andere Benutzer finden es nicht. 'WinGet einrichten' installiert es fuer alle Benutzer." }
    else {
        try {
            Import-Module $script:HMAuModule -ErrorAction Stop
            $s.WinGet = "$(Get-WinGetVersion -ErrorAction Stop)"
            $s.Ready = $true
        } catch { $s.Problem = "WinGet nicht bereit ($($_.Exception.Message)) - 'WinGet einrichten'." }
    }
    return [pscustomobject]$s
}
# Modul aus der PowerShell Gallery (alle Benutzer) + WinGet fuer dieses Konto registrieren/reparieren
function Install-HMAuWinGet($Job) {
    $log = { param($m, $l) if ($Job -and $Job.Log) { $Job.Log.Enqueue(@{ Msg = $m; Lvl = $l }) } }
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    $ok = $true
    # 1. App Installer fuer dieses Konto registrieren (neues Konto / Store gesperrt)
    try {
        if (-not @(Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' -ErrorAction SilentlyContinue).Count) {
            & $log 'App Installer (WinGet) fuer dieses Konto registrieren ...' 'Info'
            Add-AppxPackage -RegisterByFamilyName -MainPackage $script:HMAuAppInstaller -ErrorAction Stop
        }
    } catch { & $log "App Installer nicht registrierbar: $($_.Exception.Message)" 'Warning' }
    # 2. NuGet-Anbieter + Modul (alle Benutzer)
    try {
        $nu = @(Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue | Where-Object { $_.Version -ge [version]'2.8.5.201' })
        if (-not $nu.Count) {
            & $log 'NuGet-Anbieter installieren (PowerShell Gallery) ...' 'Info'
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers -ErrorAction Stop | Out-Null
        }
        & $log "Modul $($script:HMAuModule) installieren/aktualisieren (fuer alle Benutzer) ..." 'Info'
        Install-Module -Name $script:HMAuModule -Repository PSGallery -Scope AllUsers -Force -AllowClobber -ErrorAction Stop
        Import-Module $script:HMAuModule -Force -ErrorAction Stop
        & $log "Modul $($script:HMAuModule) $(@(Get-Module $script:HMAuModule)[0].Version) bereit" 'Success'
    } catch {
        $ok = $false
        & $log "Modul nicht installierbar: $($_.Exception.Message)" 'Error'
        & $log 'Moegliche Ursachen: kein Internet / Proxy, Firewall mit SSL-Pruefung (www.powershellgallery.com, psg-prod-eastus.azureedge.net), PowerShell nicht als Administrator.' 'Warning'
    }
    # 3. WinGet pruefen, sonst reparieren (laedt den App Installer von GitHub)
    if ($ok) {
        $ready = $false
        try { Assert-WinGetPackageManager -ErrorAction Stop; $ready = $true } catch { & $log "WinGet nicht bereit: $($_.Exception.Message) - wird repariert ..." 'Warning' }
        if (-not $ready) {
            try { Repair-WinGetPackageManager -Latest -Force -ErrorAction Stop; Assert-WinGetPackageManager -ErrorAction Stop; $ready = $true; & $log 'WinGet repariert' 'Success' }
            catch { $ok = $false; & $log "WinGet-Reparatur fehlgeschlagen: $($_.Exception.Message)" 'Error' }
        }
        if ($ready) { try { & $log "WinGet $(Get-WinGetVersion) bereit" 'Success' } catch { } }
    }
    if ($Job) { $Job.Result = [pscustomobject]@{ Status = $(if ($ok) { 'OK' } else { 'Error' }) } }
    return $ok
}

# ----------------------------------------------------------------------------
# Quellen
# ----------------------------------------------------------------------------
# Quellen aendern als SYSTEM (Administratorrechte) - die Liste der Quellen kommt mit der Suche (Benutzerkonto)
function Add-HMAuSource([string]$Name, [string]$Argument, [string]$Type) {
    $r = Invoke-HMAuTaskRun 'SYSTEM' '' @{ Mode = 'SourceAdd'; Name = $Name; Argument = $Argument; Type = $Type } 300
    if (@($r.Errors | Where-Object { $_ }).Count) { throw (@($r.Errors) -join ' | ') }
}
function Remove-HMAuSource([string]$Name) {
    $r = Invoke-HMAuTaskRun 'SYSTEM' '' @{ Mode = 'SourceRemove'; Name = $Name } 300
    if (@($r.Errors | Where-Object { $_ }).Count) { throw (@($r.Errors) -join ' | ') }
}

# ----------------------------------------------------------------------------
# WinGet als angemeldeter Benutzer / als SYSTEM (einmalige geplante Aufgabe, Austausch-Ordner in ProgramData)
# ----------------------------------------------------------------------------
$script:HMAuWorker = Join-Path $PSScriptRoot 'AppUpdates-Worker.ps1'
# Schutz von %ProgramData%\HUMig (Functions\Core-Protect.ps1) - lokal geladen und als Text fuer die Ziel-PCs
$script:HMAuProtectText = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Core-Protect.ps1')) -replace '(?m)^#Requires.*$', ''
. ([scriptblock]::Create($script:HMAuProtectText))

# Ist der Benutzer (SID) gerade angemeldet? (Besitzer eines explorer.exe-Prozesses)
function Test-HMAuUserLoggedOn([string]$Sid) {
    if (-not $Sid) { return $false }
    foreach ($p in @(Get-CimInstance -ClassName Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue)) {
        try { if ("$((Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid -ErrorAction Stop).Sid)" -eq $Sid) { return $true } } catch { }
    }
    return $false
}
# Aufgabe anlegen und starten. $Account = 'SYSTEM' oder Benutzer (DOMAENE\Name) mit $Sid
function Start-HMAuTask([string]$Account, [string]$Sid, $Request) {
    [void](Protect-HMDataDir)
    $id = [guid]::NewGuid().ToString('N')
    $dir = Join-Path $env:ProgramData "HUMig\AppUpdates\run_$id"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Copy-Item -LiteralPath $script:HMAuWorker -Destination (Join-Path $dir 'worker.ps1') -Force
    $Request | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $dir 'request.json') -Encoding UTF8
    $sys = ($Account -eq 'SYSTEM')
    if (-not $sys) {
        if (-not $Sid) { $Sid = (New-Object System.Security.Principal.NTAccount($Account)).Translate([System.Security.Principal.SecurityIdentifier]).Value }
        & icacls.exe "$dir" /grant "*${Sid}:(OI)(CI)M" | Out-Null
    }
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $psArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$dir\worker.ps1`" -Dir `"$dir`""
    if ($sys) { $a = New-ScheduledTaskAction -Execute $ps -Argument $psArgs }   # SYSTEM: Sitzung 0, kein Fenster
    else {
        # im Benutzerkonto ohne sichtbares Fenster (Windows 11 oeffnet sonst trotz -WindowStyle Hidden ein leeres Terminal):
        # conhost --headless; aeltere Windows-Versionen ueber ein WSH-Startskript (Fenster 0 = versteckt)
        if ([Environment]::OSVersion.Version.Build -ge 19041) {
            $a = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\conhost.exe') -Argument "--headless `"$ps`" $psArgs"
        } else {
            $vbs = Join-Path $dir 'start.vbs'
            ('CreateObject("WScript.Shell").Run """' + $ps + '"" ' + ($psArgs -replace '"', '""') + '", 0, True') | Set-Content -LiteralPath $vbs -Encoding ASCII
            $a = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\wscript.exe') -Argument "//B //NoLogo `"$vbs`""
        }
    }
    $s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 3) -MultipleInstances IgnoreNew
    $name = "HUMig_AppUpdates_$id"
    $ok = $false; $err = ''
    $uids = if ($sys) { @('NT AUTHORITY\SYSTEM') } else { @($Account, $Sid) | Where-Object { $_ } }
    foreach ($uid in $uids) {
        try {
            $pr = if ($sys) { New-ScheduledTaskPrincipal -UserId $uid -LogonType ServiceAccount -RunLevel Highest } else { New-ScheduledTaskPrincipal -UserId $uid -LogonType Interactive -RunLevel Limited }
            Register-ScheduledTask -TaskName $name -TaskPath '\' -Action $a -Principal $pr -Settings $s -Force -ErrorAction Stop | Out-Null
            $ok = $true; break
        } catch { $err = $_.Exception.Message }
    }
    if (-not $ok) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue; throw "Aufgabe fuer $Account nicht anlegbar: $err" }
    Start-ScheduledTask -TaskPath '\' -TaskName $name
    return [pscustomobject]@{ Dir = $dir; TaskName = $name; Account = $Account }
}
# Auf das Ergebnis warten. $OnLine: param($line) fuer jede neue Zeile aus log.txt. Raeumt Aufgabe und Ordner immer auf.
function Wait-HMAuTask($Handle, [int]$TimeoutSec, $Job = $null, [scriptblock]$OnLine = $null) {
    $t0 = Get-Date; $seen = 0; $cancelSent = $false; $doneAt = $null
    $rf = Join-Path $Handle.Dir 'result.json'; $lf = Join-Path $Handle.Dir 'log.txt'
    try {
        while ($true) {
            if (Test-Path -LiteralPath $lf) {
                $lines = @(Get-Content -LiteralPath $lf -Encoding UTF8 -ErrorAction SilentlyContinue)
                for ($i = $seen; $i -lt $lines.Count; $i++) { if ($OnLine) { & $OnLine $lines[$i] } }
                # nur weiterzaehlen: ist die Datei gerade gesperrt (Lesen liefert nichts/weniger), nicht von vorne anfangen
                if ($lines.Count -gt $seen) { $seen = $lines.Count }
            }
            if (Test-Path -LiteralPath $rf) { return (Get-Content -LiteralPath $rf -Raw -Encoding UTF8 | ConvertFrom-Json) }
            if ($Job -and $Job.Cancel -and -not $cancelSent) { try { New-Item -ItemType File -Path (Join-Path $Handle.Dir 'cancel') -Force | Out-Null } catch { }; $cancelSent = $true }
            $st = ''; try { $st = "$((Get-ScheduledTask -TaskPath '\' -TaskName $Handle.TaskName -ErrorAction Stop).State)" } catch { }
            if ($st -and $st -ne 'Running' -and $st -ne 'Queued') {
                if (-not $doneAt) { $doneAt = Get-Date } elseif (((Get-Date) - $doneAt).TotalSeconds -gt 10) {
                    $lr = ''; try { $lr = "$((Get-ScheduledTaskInfo -TaskPath '\' -TaskName $Handle.TaskName).LastTaskResult)" } catch { }
                    return [pscustomobject]@{ Account = $Handle.Account; Items = @(); Results = @(); Errors = @("Aufgabe als $($Handle.Account) ohne Ergebnis beendet (Rueckgabe $lr) - ist der Benutzer angemeldet?") }
                }
            }
            if (((Get-Date) - $t0).TotalSeconds -gt $TimeoutSec) {
                try { Stop-ScheduledTask -TaskPath '\' -TaskName $Handle.TaskName -ErrorAction SilentlyContinue } catch { }
                return [pscustomobject]@{ Account = $Handle.Account; Items = @(); Results = @(); Errors = @("Zeitueberschreitung nach $TimeoutSec s (als $($Handle.Account))") }
            }
            Start-Sleep -Milliseconds 1500
        }
    } finally {
        try { Unregister-ScheduledTask -TaskPath '\' -TaskName $Handle.TaskName -Confirm:$false -ErrorAction SilentlyContinue } catch { }
        Remove-Item -LiteralPath $Handle.Dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
function Invoke-HMAuTaskRun([string]$Account, [string]$Sid, $Request, [int]$TimeoutSec, $Job = $null, [scriptblock]$OnLine = $null) {
    try { $h = Start-HMAuTask $Account $Sid $Request } catch { return [pscustomobject]@{ Account = $Account; Items = @(); Results = @(); Errors = @("$($_.Exception.Message)") } }
    return (Wait-HMAuTask $h $TimeoutSec $Job $OnLine)
}
# ----------------------------------------------------------------------------
# Ziel-PCs: AppUpdates-Target.ps1 lokal (&) oder per Invoke-Command (mehrere PCs parallel)
#   Rueckgabe: Hashtable PC-Schluessel (Name wie angegeben, gross) -> Ergebnisobjekt (immer mit Errors)
#   $OnLine: param($pc, $line) je Protokollzeile (Zeilen der Hilfsaufgabe beginnen mit '#'), $OnResult: param($pc, $v)
# ----------------------------------------------------------------------------
$script:HMAuTargetFile = Join-Path $PSScriptRoot 'AppUpdates-Target.ps1'
$script:HMAuAutoFile = Join-Path $PSScriptRoot 'AppUpdates-Auto.ps1'
function Get-HMAuPcKey([string]$Computer) {
    if (Test-HMAuLocal $Computer) { return "$env:COMPUTERNAME".ToUpper() }
    return "$Computer".Trim().ToUpper()
}
function Test-HMAuLocal([string]$Computer) {
    if (Get-Command Test-HMIsLocal -ErrorAction SilentlyContinue) { return [bool](Test-HMIsLocal $Computer) }
    $c = "$Computer".Trim().ToUpper()
    return (-not $c -or $c -in @('.', 'LOCALHOST', '127.0.0.1', "$env:COMPUTERNAME".ToUpper()) -or $c -like "$("$env:COMPUTERNAME".ToUpper()).*")
}
function Invoke-HMAuTarget([string[]]$Computers, [string]$Op, [hashtable]$Payload, $Credential = $null, [scriptblock]$OnLine = $null, $Job = $null, [scriptblock]$OnResult = $null, [int]$Throttle = 16) {
    $txt = [System.IO.File]::ReadAllText($script:HMAuTargetFile) -replace '(?m)^#Requires.*$', ''
    # Schutz-Funktion direkt nach dem param()-Block einfuegen (param muss am Anfang stehen)
    $pi = $txt.IndexOf('param([string]$Op')
    if ($pi -lt 0) { throw 'AppUpdates-Target.ps1: param-Block nicht gefunden' }
    $pe = $txt.IndexOf("`n", $pi)
    $txt = $txt.Substring(0, $pe + 1) + $script:HMAuProtectText + "`r`n" + $txt.Substring($pe + 1)
    $sb = [scriptblock]::Create($txt)
    $wt = [System.IO.File]::ReadAllText($script:HMAuWorker)
    $at = [System.IO.File]::ReadAllText($script:HMAuAutoFile)
    $out = @{}
    $all = @($Computers | ForEach-Object { "$_".Trim() } | Where-Object { $_ } | Select-Object -Unique)
    $loc = @($all | Where-Object { Test-HMAuLocal $_ } | Select-Object -First 1)
    $rem = @($all | Where-Object { -not (Test-HMAuLocal $_) })
    $handle = {
        param($o, [string]$Key)
        if (-not $o -or -not $o.PSObject.Properties['HMAu']) { return }
        if ("$($o.HMAu)" -eq 'R') {
            $v = $null
            try { $v = "$($o.J)" | ConvertFrom-Json } catch { $v = [pscustomobject]@{ Errors = @("Ergebnis nicht lesbar: $($_.Exception.Message)") } }
            if (-not $v.PSObject.Properties['Errors']) { $v | Add-Member -NotePropertyName Errors -NotePropertyValue @() }
            $out[$Key] = $v
            if ($OnResult) { & $OnResult $Key $v }
        }
        elseif ($OnLine) { & $OnLine $Key "$($o.V)" }
    }
    # entfernte PCs als Hintergrundauftrag starten, waehrenddessen den eigenen PC bearbeiten
    $rj = $null
    if ($rem.Count) {
        $p = @{ ComputerName = $rem; ScriptBlock = $sb; ArgumentList = @($Op, $Payload, $wt, $at); ThrottleLimit = $Throttle; AsJob = $true; ErrorAction = 'Stop' }
        if ($Credential) { $p.Credential = $Credential }
        try { $rj = Invoke-Command @p } catch { foreach ($c in $rem) { $out[$c.ToUpper()] = [pscustomobject]@{ Errors = @("nicht erreichbar: $($_.Exception.Message)") } } }
    }
    if ($loc.Count) {
        $lk = "$env:COMPUTERNAME".ToUpper()
        $lp = $Payload.Clone(); $lp.Job = $Job   # Abbruch lokal ueber $Job.Cancel
        try { & $sb $Op $lp $wt $at | ForEach-Object { & $handle $_ $lk } }
        catch { if (-not $out.ContainsKey($lk)) { $out[$lk] = [pscustomobject]@{ Errors = @("Fehler: $($_.Exception.Message)") } } }
    }
    if ($rj) {
        $stopped = $false
        while ($true) {
            $fin = ("$($rj.State)" -notin @('Running', 'NotStarted'))
            foreach ($o in @(Receive-Job -Job $rj -ErrorAction SilentlyContinue)) { & $handle $o "$($o.PSComputerName)".ToUpper() }
            if ($fin) { break }
            if (-not $stopped -and $Job -and $Job.Cancel) { Stop-Job -Job $rj -ErrorAction SilentlyContinue; $stopped = $true }
            Start-Sleep -Milliseconds 700
        }
        foreach ($cj in @($rj.ChildJobs)) {
            $k = "$($cj.Location)".ToUpper()
            if ($out.ContainsKey($k)) { continue }
            $why = ''
            try { $why = "$($cj.JobStateInfo.Reason.Message)" } catch { }
            if (-not $why) { try { $why = "$(@($cj.Error)[0])" } catch { } }
            $txt2 = if ($stopped) { 'abgebrochen' } elseif ($why) { "nicht erreichbar: $($why.Trim())" } else { 'kein Ergebnis' }
            $out[$k] = [pscustomobject]@{ Errors = @($txt2) }
        }
        Remove-Job -Job $rj -Force -ErrorAction SilentlyContinue
    }
    foreach ($c in $all) { $k = Get-HMAuPcKey $c; if (-not $out.ContainsKey($k)) { $out[$k] = [pscustomobject]@{ Errors = @($(if ($Job -and $Job.Cancel) { 'abgebrochen' } else { 'kein Ergebnis' })) } } }
    return $out
}

# ----------------------------------------------------------------------------
# Suchen (Start-LongJob): $Ctx.Computers, Sources, IncludeUnknown, UserSid + SidPc (gewaehlter Benutzer am oberen PC), Credential
#   $Job.Result.ByPc: PC -> Items, Sources, Errors, ReadAs, UserSid, UserAccount
# ----------------------------------------------------------------------------
function Start-HMAuSearchJob([hashtable]$Ctx, $Job) {
    $pcs = @($Ctx.Computers | Where-Object { "$_".Trim() })
    Write-HMLog $Job "App-Updates: Updates suchen auf $($pcs.Count) PC(s)$(if ($pcs.Count -le 5) { ': ' + ($pcs -join ', ') })" 'Header'
    $byPc = @{}
    foreach ($c in $pcs) {
        $k = Get-HMAuPcKey $c
        $byPc[$k] = @{ Sources = @($Ctx.Sources); IncludeUnknown = [bool]$Ctx.IncludeUnknown; UserSid = $(if ($Ctx.SidPc -and $k -eq (Get-HMAuPcKey "$($Ctx.SidPc)")) { "$($Ctx.UserSid)" } else { '' }); InstallPwsh = $true }
    }
    $st = @{ Job = $Job; Done = 0; Total = [Math]::Max(1, $pcs.Count) }
    $on = { param($pc, $ln) if (-not "$ln".StartsWith('#')) { Write-HMLog $st.Job "  [$pc] $ln" 'Info' } }
    $onR = {
        param($pc, $v)
        $st.Done++
        $st.Job.Progress = [int]($st.Done * 100 / $st.Total)
        $st.Job.Status = "$($st.Done)/$($st.Total) PCs"
        foreach ($e in @($v.Errors | Where-Object { $_ })) { Write-HMLog $st.Job "  [$pc] $e" 'Warning' }
        if ($v.PSObject.Properties['Items'] -and "$($v.ReadAs)") { Write-HMLog $st.Job "  [$pc] $(@($v.Items | Where-Object { $_ }).Count) Update(s) (gelesen als $($v.ReadAs))" 'Success' }
        elseif ($v.PSObject.Properties['Items']) { Write-HMLog $st.Job "  [$pc] NICHT gelesen" 'Error' }
    }
    $r = Invoke-HMAuTarget $pcs 'Search' @{ ByPc = $byPc } $Ctx.Credential $on $Job $onR
    foreach ($k in @($r.Keys)) { if (-not $r[$k].PSObject.Properties['Items']) { foreach ($e in @($r[$k].Errors)) { Write-HMLog $Job "  [$k] $e" 'Error' } } }
    $Job.Progress = 100
    $Job.Result = [pscustomobject]@{ Status = $(if ($Job.Cancel) { 'Cancelled' } else { 'OK' }); ByPc = $r }
}

# Laufende Programme zu Paketen finden: Installationsordner aus der Registry (Deinstallations-Eintraege), Prozesse darin.
# Heuristik - findet nicht jedes Programm (fehlender Installationsordner, abweichender Name).
function Get-HMAuRunning($Items) {
    $keys = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')
    $reg = @(foreach ($k in $keys) { Get-ItemProperty -Path $k -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName } })
    $procs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path })
    # Art je Prozess: Dienst (Win32_Service), Fenster, Hintergrund (ohne Fenster, z.B. Infobereich). Fenster sind nur in der eigenen
    # Sitzung erkennbar - Prozesse anderer Sitzungen gelten als 'Fenster' (hoeflich schliessen, wie bisher).
    $svc = @{}
    foreach ($x in @(Get-CimInstance -ClassName Win32_Service -Filter "State='Running'" -ErrorAction SilentlyContinue)) { if ([int]$x.ProcessId -gt 0) { $svc[[int]$x.ProcessId] = @($svc[[int]$x.ProcessId]) + @("$($x.Name)") | Where-Object { $_ } } }
    $mySess = -1; try { $mySess = (Get-Process -Id $PID).SessionId } catch { }
    $kindOf = {
        param($pr)
        if ($svc.ContainsKey([int]$pr.Id)) { return 'Service' }
        if ([int]$pr.SessionId -ne $mySess) { return 'Window' }
        if ([int64]$pr.MainWindowHandle -ne 0) { return 'Window' }
        return 'Background'
    }
    $ownerOf = {
        param($id)
        try { $w = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$id" -ErrorAction Stop; $o = Invoke-CimMethod -InputObject $w -MethodName GetOwner -ErrorAction Stop; if ($o.User) { return "$($o.Domain)\$($o.User)" } } catch { }
        return ''
    }
    $bad = @("$env:SystemRoot", "$env:ProgramFiles", "${env:ProgramFiles(x86)}", "$env:ProgramData", "$env:SystemDrive\") | Where-Object { $_ } | ForEach-Object { "$_".TrimEnd('\').ToLower() }
    foreach ($it in @($Items)) {
        $n = "$($it.Name)".Trim()
        if (-not $n) { continue }
        $cand = @(foreach ($r in @($reg | Where-Object { "$($_.DisplayName)" -eq $n -or "$($_.DisplayName)" -like "$n *" })) {
                $d = "$($r.InstallLocation)".Trim().Trim('"')
                if (-not $d -and "$($r.DisplayIcon)") { try { $d = Split-Path ("$($r.DisplayIcon)" -replace ',\s*-?\d+$', '').Trim('"') -Parent } catch { $d = '' } }
                if ($d) { $d.TrimEnd('\') }
            })
        $dirs = @($cand | Where-Object { $_ -and $bad -notcontains $_.ToLower() -and $_.Length -gt 3 } | Select-Object -Unique)
        if (-not $dirs.Count) { continue }
        $run = @($procs | Where-Object { $pp = "$($_.Path)".ToLower(); @($dirs | Where-Object { $pp.StartsWith($_.ToLower() + '\') }).Count })
        if ($run.Count) {
            $pl = @($run | ForEach-Object {
                    $k = & $kindOf $_
                    [pscustomobject]@{ Name = "$($_.ProcessName)"; Id = [int]$_.Id; SessionId = [int]$_.SessionId; Kind = $k; Path = "$($_.Path)"
                        Services = @($(if ($k -eq 'Service') { $svc[[int]$_.Id] })); Owner = $(if ($k -eq 'Background') { & $ownerOf ([int]$_.Id) } else { '' }) }
                })
            $kt = @{ Service = 'Dienst'; Window = 'Fenster'; Background = 'Hintergrund' }
            [pscustomobject]@{
                Id = "$($it.Id)"; Name = $n; Running = (@($pl | ForEach-Object { "$($_.Name) ($($_.Id), $($kt[$_.Kind])$(if ($_.Kind -eq 'Service') { ': ' + (@($_.Services) -join ',') }))" }) -join ', ')
                Procs = $pl
            }
        }
    }
}

# Laufendes Programm vor dem Update beenden - je nach Art (nur am eigenen PC):
#   Fenster: hoeflich schliessen (wie der Benutzer, ungespeicherte Arbeit fragt das Programm), notfalls beenden nur bei CloseForce
#   Hintergrund (kein Fenster, z.B. Infobereich): direkt beenden - nichts zu speichern; nach dem Update im Konto des Besitzers neu starten
#   Dienst: Dienst stoppen; nach dem Update wieder starten, falls der Installer das nicht selbst getan hat
# Rueckgabe: Ids, die noch laufen
function Stop-HMAuRunning([hashtable]$Pc, $Job, $Item, [object[]]$Procs, [bool]$Force, [hashtable]$Restart) {
    $win = @($Procs | Where-Object { "$($_.Kind)" -ne 'Service' -and "$($_.Kind)" -ne 'Background' })
    $bg = @($Procs | Where-Object { "$($_.Kind)" -eq 'Background' })
    $sv = @($Procs | Where-Object { "$($_.Kind)" -eq 'Service' })
    $left = @()
    foreach ($n in @($sv | ForEach-Object { @($_.Services) } | Where-Object { $_ } | Select-Object -Unique)) {
        try {
            Stop-Service -Name $n -Force -ErrorAction Stop
            Write-HMLog $Job "      Dienst $n gestoppt (wird nach dem Update wieder gestartet)" 'Info'
            if (-not $Restart.Services.Contains($n)) { $Restart.Services.Add($n) }
        } catch { Write-HMLog $Job "      Dienst $n nicht stoppbar: $($_.Exception.Message)" 'Warning' }
    }
    foreach ($p in $bg) {
        try {
            Stop-Process -Id ([int]$p.Id) -Force -ErrorAction Stop
            Write-HMLog $Job "      $($p.Name) ($($p.Id)) beendet - Hintergrundprogramm ohne Fenster" 'Info'
            if ($p.Path -and $p.Owner -and -not @($Restart.Apps | Where-Object { $_.Path -eq $p.Path -and $_.Owner -eq $p.Owner }).Count) { $Restart.Apps.Add([pscustomobject]@{ Path = "$($p.Path)"; Owner = "$($p.Owner)"; Name = "$($p.Name)" }) }
        } catch { }
    }
    if ($win.Count) { $left += @(Close-HMProcs $Pc $Job $win $Force 20) }
    if ($bg.Count -or $sv.Count) {
        Start-Sleep -Seconds 2
        $left += @(foreach ($p in @($bg + $sv)) { if (Get-Process -Id ([int]$p.Id) -ErrorAction SilentlyContinue) { [int]$p.Id } })
    }
    return @($left | Select-Object -Unique)
}
# Nach dem Update: gestoppte Dienste und beendete Hintergrundprogramme wieder starten (nur, wenn sie nicht schon laufen)
function Restart-HMAuStopped($Job, [hashtable]$Restart) {
    foreach ($n in @($Restart.Services)) {
        try {
            $s = Get-Service -Name $n -ErrorAction Stop
            if ("$($s.Status)" -ne 'Running') { Start-Service -Name $n -ErrorAction Stop; Write-HMLog $Job "  Dienst $n wieder gestartet" 'Success' }
        } catch { Write-HMLog $Job "  Dienst $n nicht startbar: $($_.Exception.Message)" 'Warning' }
    }
    foreach ($a in @($Restart.Apps)) {
        if (@(Get-Process -ErrorAction SilentlyContinue | Where-Object { "$($_.Path)" -ieq $a.Path }).Count) { continue }   # Installer hat es schon gestartet
        if (-not (Test-Path -LiteralPath $a.Path)) { Write-HMLog $Job "  $($a.Name) nicht neu gestartet: $($a.Path) gibt es nach dem Update nicht mehr" 'Warning'; continue }
        $n = 'HUMig_Restart_' + [guid]::NewGuid().ToString('N')
        try {
            $act = New-ScheduledTaskAction -Execute $a.Path
            $pr = New-ScheduledTaskPrincipal -UserId $a.Owner -LogonType Interactive -RunLevel Limited
            $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Seconds 0)
            Register-ScheduledTask -TaskName $n -TaskPath '\' -Action $act -Principal $pr -Settings $set -Force -ErrorAction Stop | Out-Null
            Start-ScheduledTask -TaskPath '\' -TaskName $n
            Start-Sleep -Seconds 3
            Write-HMLog $Job "  $($a.Name) fuer $($a.Owner) wieder gestartet" 'Success'
        } catch { Write-HMLog $Job "  $($a.Name) nicht neu gestartet: $($_.Exception.Message)" 'Warning' }
        finally { Unregister-ScheduledTask -TaskPath '\' -TaskName $n -Confirm:$false -ErrorAction SilentlyContinue }
    }
}

# ----------------------------------------------------------------------------
# Aktualisieren / Installieren (Start-LongJob): $Ctx.Op = Update | Install, $Ctx.ByPc: PC -> @{ Items; UserSid; UserAccount }
#   Items: Id, Name, Source, Installed, Available, Unknown, Scope (Machine/User). $Ctx.Credential
#   Nur am eigenen PC: $Ctx.Running (Get-HMAuRunning), $Ctx.ProcDecisions (Id -> Close/CloseForce/Skip/Run)
#   Am Ziel-PC: Machine -> als SYSTEM (winget.exe), User -> als angemeldeter Benutzer
# ----------------------------------------------------------------------------
function Start-HMAppUpdate([hashtable]$Ctx, $Job) {
    $op = if ("$($Ctx.Op)" -eq 'Install') { 'Install' } else { 'Update' }
    $verb = if ($op -eq 'Install') { 'installiert' } else { 'aktualisiert' }
    $lk = "$env:COMPUTERNAME".ToUpper()
    $pcs = @($Ctx.ByPc.Keys)
    $n = 0; foreach ($k in $pcs) { $n += @($Ctx.ByPc[$k].Items).Count }
    Write-HMLog $Job "App-Updates: $n Programm(e) $(if ($op -eq 'Install') { 'installieren' } else { 'aktualisieren' }) an $($pcs.Count) PC(s)$(if ($pcs.Count -le 5) { ': ' + ($pcs -join ', ') })" 'Header'
    $res = @()
    $new = { param($pc, $it) [ordered]@{ Date = (Get-Date).ToString('yyyy-MM-dd HH:mm'); Computer = $pc; Id = "$($it.Id)"; Name = "$($it.Name)"; From = "$($it.Installed)"; To = "$($it.Available)"; Source = "$($it.Source)"; Scope = "$($it.Scope)"; Status = ''; Text = ''; Reboot = $false } }
    $byPc = @{}; $names = @{}
    $restart = @{ Services = [System.Collections.Generic.List[string]]::new(); Apps = [System.Collections.Generic.List[object]]::new() }   # nach dem Update wieder starten
    foreach ($k in $pcs) {
        $todo = @()
        foreach ($it in @($Ctx.ByPc[$k].Items | Where-Object { $_ })) {
            # laufende Programme (nur am eigenen PC geprueft)
            if ($k -eq $lk) {
                $dec = if ($Ctx.ProcDecisions) { "$($Ctx.ProcDecisions["$($it.Id)"])" } else { '' }
                $run = @(@($Ctx.Running) | Where-Object { "$($_.Id)" -eq "$($it.Id)" })[0]
                if ($run -and $dec -eq 'Skip') {
                    $e = & $new $k $it; $e.Status = 'Skipped'; $e.Text = "uebersprungen - laeuft ($($run.Running))"
                    Write-HMLog $Job "  $($it.Name): $($e.Text)" 'Warning'; $res += [pscustomobject]$e; continue
                }
                if ($run -and $dec -match '^Close') {
                    Write-HMLog $Job "  $($it.Name): Programm schliessen ($($run.Running)) ..." 'Info'
                    $pc = @{ Computer = $env:COMPUTERNAME; IsRemote = $false; Credential = $null; Account = "$($Ctx.ByPc[$k].UserAccount)" }
                    $left = @(Stop-HMAuRunning $pc $Job $it @($run.Procs) ($dec -eq 'CloseForce') $restart)
                    if ($left.Count) {
                        $e = & $new $k $it; $e.Status = 'Skipped'; $e.Text = 'uebersprungen - Programm liess sich nicht schliessen'
                        Write-HMLog $Job "  $($it.Name): $($e.Text)" 'Warning'; $res += [pscustomobject]$e; continue
                    }
                }
            }
            $todo += $it
            $names["$k|$($it.Id)"] = $it
        }
        if ($todo.Count) {
            $byPc[$k] = @{ UserSid = "$($Ctx.ByPc[$k].UserSid)"; Items = @($todo | ForEach-Object { @{ Id = "$($_.Id)"; Source = "$($_.Source)"; Unknown = [bool]$_.Unknown; Scope = "$($_.Scope)" } }) }
        }
    }
    $st = @{ Job = $Job; Names = $names; Done = 0; Total = [Math]::Max(1, $names.Count); Logged = @{}; Multi = ($pcs.Count -gt 1); Verb = $verb }
    $on = {
        param($pc, $ln)
        $pre = if ($st.Multi) { "[$pc] " } else { '' }
        if (-not "$ln".StartsWith('#')) { Write-HMLog $st.Job "$pre$ln" 'Info'; return }
        $p = "$ln".Substring(1).Split('|')
        $x = $st.Names["$pc|$($p[1])"]
        if (-not $x) { return }
        if ($p[0] -eq 'START') {
            # zweiter Versuch desselben Programms (z.B. im Benutzerkonto nach SYSTEM): Ergebnis wieder anzeigen
            if ($st.Logged.ContainsKey("$pc|$($p[1])")) { $st.Logged.Remove("$pc|$($p[1])"); if ($st.Done -gt 0) { $st.Done-- } }
            $st.Job.Status = "$($st.Done + 1)/$($st.Total): $($x.Name)$(if ($st.Multi) { " ($pc)" })"
            $st.Job.Progress = [int]($st.Done * 100 / $st.Total)
            Write-HMLog $st.Job "  $pre$($x.Name) ($($x.Id))$(if ($x.Installed -or $x.Available) { ": $($x.Installed) -> $($x.Available)" }) ..." 'Info'
        } elseif ($p[0] -eq 'DONE') {
            if ($st.Logged.ContainsKey("$pc|$($p[1])")) { return }   # Zeile schon verarbeitet
            $st.Done++
            # Ergebnis sofort zeigen (DONE|Id|Status|Code|InstallerCode|ExtendedCode|Reboot)
            $c = $null
            if ($p.Count -ge 7) {
                if ($p[2] -eq 'Cli') { $c = Format-HMAuCliResult ([int64]$p[3]) '' }
                elseif ($p[2] -ne 'Exception') { $t = Format-HMAuResult $p[2] $p[4] $p[5] ($p[6] -eq 'True'); $c = @{ Ok = ($p[2] -eq 'Ok'); Text = $t } }
            }
            if ($c) {
                $txt = if ($c.Ok -and $c.Text -eq 'aktualisiert') { $st.Verb } else { $c.Text }
                Write-HMLog $st.Job "  $pre$($x.Name): $txt" $(if ($c.Ok) { 'Success' } else { 'Error' })
                $st.Logged["$pc|$($p[1])"] = $true
            }
        }
    }
    $r = @{}
    if ($byPc.Count -and -not (Test-HMCancel $Job)) { $r = Invoke-HMAuTarget @($byPc.Keys) $op @{ ByPc = $byPc } $Ctx.Credential $on $Job }
    foreach ($k in @($byPc.Keys)) {
        $v = $r[$k]
        foreach ($er in @($v.Errors | Where-Object { $_ })) { Write-HMLog $Job "  $(if ($st.Multi) { "[$k] " })$er" 'Error' }
        foreach ($it in @($Ctx.ByPc[$k].Items | Where-Object { $_ -and $names.ContainsKey("$k|$($_.Id)") })) {
            $e = & $new $k $it
            $x = $null; if ($v -and $v.PSObject.Properties['Results']) { $x = @(@($v.Results) | Where-Object { "$($_.Id)" -eq "$($it.Id)" })[0] }
            if (-not $x) {
                $cn = [bool](Test-HMCancel $Job)
                $e.Status = $(if ($cn) { 'Skipped' } else { 'Error' })
                $e.Text = $(if ($cn) { 'abgebrochen' } elseif (@($v.Errors).Count) { "nicht ausgefuehrt: $(@($v.Errors)[0])" } else { 'kein Ergebnis' })
            } elseif ("$($x.Status)" -eq 'Exception') { $e.Status = 'Error'; $e.Text = "$($x.Text)" }
            elseif ("$($x.Status)" -eq 'Cli') {
                $c = Format-HMAuCliResult ([int64]$x.Code) "$($x.Text)"
                $e.Status = $(if ($c.Ok) { 'OK' } else { 'Error' }); $e.Reboot = [bool]$c.Reboot
                $e.Text = $(if ($c.Ok -and $c.Text -eq 'aktualisiert') { $verb } else { $c.Text })
            } else {
                $e.Status = $(if ("$($x.Status)" -eq 'Ok') { 'OK' } else { 'Error' })
                $e.Reboot = [bool]$x.Reboot
                $e.Text = Format-HMAuResult "$($x.Status)" $x.InstallerErrorCode $x.ExtendedErrorCode ([bool]$x.Reboot)
            }
            if (-not $st.Logged.ContainsKey("$k|$($it.Id)") -or $e.Status -ne 'OK') {
                if (-not $st.Logged.ContainsKey("$k|$($it.Id)")) { Write-HMLog $Job "  $(if ($st.Multi) { "[$k] " })$($it.Name): $($e.Text)" $(if ($e.Status -eq 'OK') { 'Success' } elseif ($e.Status -eq 'Skipped') { 'Warning' } else { 'Error' }) }
            }
            $res += [pscustomobject]$e
        }
    }
    Restart-HMAuStopped $Job $restart
    $Job.Progress = 100
    $ok = @($res | Where-Object { $_.Status -eq 'OK' }).Count
    $err = @($res | Where-Object { $_.Status -eq 'Error' }).Count
    $skip = @($res | Where-Object { $_.Status -eq 'Skipped' }).Count
    $reb = @($res | Where-Object { $_.Reboot }).Count
    Write-HMLog $Job "App-Updates fertig: $ok $verb, $err Fehler, $skip uebersprungen$(if ($reb) { ", $reb brauchen einen Neustart" })" $(if ($err) { 'Warning' } else { 'Success' })
    $Job.Result = [pscustomobject]@{ Status = $(if ($Job.Cancel) { 'Cancelled' } elseif ($err) { 'Warning' } else { 'OK' }); Items = $res; Reboot = ($reb -gt 0) }
}

# ----------------------------------------------------------------------------
# Zeitplan (Start-LongJob): $Ctx.Op = ScheduleSet | ScheduleGet | ScheduleRemove, $Ctx.Computers, $Ctx.Payload, $Ctx.Credential
#   $Job.Result.ByPc: PC -> Ergebnis
# ----------------------------------------------------------------------------
function Start-HMAuScheduleJob([hashtable]$Ctx, $Job) {
    $pcs = @($Ctx.Computers | Where-Object { "$_".Trim() })
    $what = switch ("$($Ctx.Op)") { 'ScheduleSet' { 'anlegen' } 'ScheduleRemove' { 'entfernen' } default { 'lesen' } }
    Write-HMLog $Job "App-Updates: Zeitplan $what an $($pcs.Count) PC(s)$(if ($pcs.Count -le 5) { ': ' + ($pcs -join ', ') })" 'Header'
    $st = @{ Job = $Job; Done = 0; Total = [Math]::Max(1, $pcs.Count); Op = "$($Ctx.Op)" }
    $on = { param($pc, $ln) if (-not "$ln".StartsWith('#')) { Write-HMLog $st.Job "  [$pc] $ln" 'Info' } }
    $onR = {
        param($pc, $v)
        $st.Done++; $st.Job.Progress = [int]($st.Done * 100 / $st.Total); $st.Job.Status = "$($st.Done)/$($st.Total) PCs"
        foreach ($e in @($v.Errors | Where-Object { $_ })) { Write-HMLog $st.Job "  [$pc] $e" 'Warning' }
        if ($st.Op -eq 'ScheduleGet') { Write-HMLog $st.Job "  [$pc] $(if ($v.Exists) { "Zeitplan $($v.When), naechster Lauf $($v.Next)" } else { 'kein Zeitplan' })" 'Info' }
    }
    $p = @{}; if ($Ctx.Payload) { $p = $Ctx.Payload.Clone() }
    $r = Invoke-HMAuTarget $pcs "$($Ctx.Op)" $p $Ctx.Credential $on $Job $onR
    foreach ($k in @($r.Keys)) { if (-not $r[$k].PSObject.Properties['Ok'] -and -not $r[$k].PSObject.Properties['Exists']) { foreach ($e in @($r[$k].Errors)) { Write-HMLog $Job "  [$k] $e" 'Error' } } }
    $bad = @($r.Keys | Where-Object { @($r[$_].Errors | Where-Object { $_ }).Count -and -not ($r[$_].PSObject.Properties['Ok'] -and $r[$_].Ok) -and -not $r[$_].PSObject.Properties['Exists'] }).Count
    $Job.Progress = 100
    Write-HMLog $Job "Zeitplan $what fertig: $($pcs.Count - $bad) ok$(if ($bad) { ", $bad Fehler" })" $(if ($bad) { 'Warning' } else { 'Success' })
    $Job.Result = [pscustomobject]@{ Status = $(if ($Job.Cancel) { 'Cancelled' } elseif ($bad) { 'Warning' } else { 'OK' }); ByPc = $r }
}
