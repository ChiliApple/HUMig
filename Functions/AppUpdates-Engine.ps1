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
    if ($code -and $Status -ne 'Ok') {
        $c = switch ($code) { 1602 { ' - vom Benutzer abgebrochen' } 1603 { ' - schwerer Fehler beim Installieren (oft: Programm laeuft noch)' } 1618 { ' - andere Installation laeuft gerade' } 1638 { ' - andere Version bereits installiert' } default { '' } }
        $t += " (Code $code$c)"
    }
    if ($Reboot) { $t += ' - Neustart noetig' }
    return $t
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
    $a = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$dir\worker.ps1`" -Dir `"$dir`""
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
                $seen = $lines.Count
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
# Listen zusammenfuehren: was auch SYSTEM sieht = fuer alle Benutzer installiert (Machine), sonst nur fuer den Benutzer (User)
function Merge-HMAuLists($UserItems, $SysItems, [bool]$SysOk = $true) {
    $sys = @{}; foreach ($i in @($SysItems | Where-Object { $_ })) { $sys["$($i.Id)"] = $i }
    $out = @(); $done = @{}
    foreach ($i in @($UserItems | Where-Object { $_ })) {
        $sc = if ($sys.ContainsKey("$($i.Id)") -or -not $SysOk) { if ($SysOk) { 'Machine' } else { 'User' } } else { 'User' }
        $out += [pscustomobject]@{ Id = "$($i.Id)"; Name = "$($i.Name)"; Installed = "$($i.Installed)"; Available = "$($i.Available)"; Source = "$($i.Source)"; Unknown = [bool]$i.Unknown; Scope = $sc }
        $done["$($i.Id)"] = $true
    }
    foreach ($i in @($SysItems | Where-Object { $_ -and -not $done.ContainsKey("$($_.Id)") })) {
        $out += [pscustomobject]@{ Id = "$($i.Id)"; Name = "$($i.Name)"; Installed = "$($i.Installed)"; Available = "$($i.Available)"; Source = "$($i.Source)"; Unknown = [bool]$i.Unknown; Scope = 'Machine' }
    }
    return @($out | Sort-Object Name)
}
# Verfuegbare Updates: als SYSTEM (fuer alle Benutzer) und - wenn angemeldet - als Benutzer (auch nur fuer ihn installierte)
function Get-HMAuUpdates([string[]]$Sources, [bool]$IncludeUnknown, [string]$UserAccount = '', [string]$UserSid = '') {
    $req = @{ Mode = 'List'; Sources = @($Sources); IncludeUnknown = $IncludeUnknown }
    $loggedOn = ($UserSid -and (Test-HMAuUserLoggedOn $UserSid))
    $hs = $null; $hu = $null; $errors = @()
    try { $hs = Start-HMAuTask 'SYSTEM' '' $req } catch { $errors += "SYSTEM: $($_.Exception.Message)" }
    if ($loggedOn) { try { $hu = Start-HMAuTask $UserAccount $UserSid $req } catch { $errors += "${UserAccount}: $($_.Exception.Message)" } }
    $rs = if ($hs) { Wait-HMAuTask $hs 600 } else { $null }
    $ru = if ($hu) { Wait-HMAuTask $hu 600 } else { $null }
    foreach ($r in @($rs, $ru)) { if ($r) { $errors += @($r.Errors | Where-Object { $_ }) } }
    $sysOk = [bool]($rs -and -not @($rs.Errors | Where-Object { $_ -like 'WinGet*' }).Count)
    $items = Merge-HMAuLists $(if ($ru) { @($ru.Items) } else { @() }) $(if ($rs) { @($rs.Items) } else { @() }) $sysOk
    $src = if ($ru -and @($ru.Sources).Count) { @($ru.Sources) } elseif ($rs) { @($rs.Sources) } else { @() }
    return [pscustomobject]@{ Items = @($items); Errors = @($errors); UserRead = [bool]$ru; LoggedOn = [bool]$loggedOn; SysOk = $sysOk; Sources = @($src | Where-Object { $_ }) }
}

# Laufende Programme zu Paketen finden: Installationsordner aus der Registry (Deinstallations-Eintraege), Prozesse darin.
# Heuristik - findet nicht jedes Programm (fehlender Installationsordner, abweichender Name).
function Get-HMAuRunning($Items) {
    $keys = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')
    $reg = @(foreach ($k in $keys) { Get-ItemProperty -Path $k -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName } })
    $procs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path })
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
            [pscustomobject]@{
                Id = "$($it.Id)"; Name = $n; Running = (@($run | ForEach-Object { "$($_.ProcessName) ($($_.Id))" }) -join ', ')
                Procs = @($run | ForEach-Object { [pscustomobject]@{ Name = "$($_.ProcessName)"; Id = [int]$_.Id; SessionId = [int]$_.SessionId } })
            }
        }
    }
}

# ----------------------------------------------------------------------------
# Aktualisieren (Start-LongJob): $Ctx.Items = Id, Name, Source, Installed, Available, Unknown, Scope (Machine/User)
#   $Ctx.UserAccount/UserSid, $Ctx.Running (Get-HMAuRunning), $Ctx.ProcDecisions (Id -> Close/CloseForce/Skip/Run)
#   Machine -> als SYSTEM, User -> als angemeldeter Benutzer
# ----------------------------------------------------------------------------
function Start-HMAppUpdate([hashtable]$Ctx, $Job) {
    $items = @($Ctx.Items)
    Write-HMLog $Job "App-Updates: $($items.Count) Programm(e) an $env:COMPUTERNAME" 'Header'
    $res = @()
    $pc = @{ Computer = $env:COMPUTERNAME; IsRemote = $false; Credential = $null; Account = "$($Ctx.UserAccount)" }
    $new = { param($it) [ordered]@{ Date = (Get-Date).ToString('yyyy-MM-dd HH:mm'); Computer = $env:COMPUTERNAME; Id = "$($it.Id)"; Name = "$($it.Name)"; From = "$($it.Installed)"; To = "$($it.Available)"; Source = "$($it.Source)"; Scope = "$($it.Scope)"; Status = ''; Text = ''; Reboot = $false } }
    # 1. laufende Programme
    $todo = @()
    foreach ($it in $items) {
        $dec = if ($Ctx.ProcDecisions) { "$($Ctx.ProcDecisions["$($it.Id)"])" } else { '' }
        $run = @(@($Ctx.Running) | Where-Object { "$($_.Id)" -eq "$($it.Id)" })[0]
        if ($run -and $dec -eq 'Skip') {
            $e = & $new $it; $e.Status = 'Skipped'; $e.Text = "uebersprungen - laeuft ($($run.Running))"
            Write-HMLog $Job "  $($it.Name): $($e.Text)" 'Warning'; $res += [pscustomobject]$e; continue
        }
        if ($run -and $dec -match '^Close') {
            Write-HMLog $Job "  $($it.Name): Programm schliessen ($($run.Running)) ..." 'Info'
            $left = @(Close-HMProcs $pc $Job @($run.Procs) ($dec -eq 'CloseForce') 20)
            if ($left.Count) {
                $e = & $new $it; $e.Status = 'Skipped'; $e.Text = 'uebersprungen - Programm liess sich nicht schliessen'
                Write-HMLog $Job "  $($it.Name): $($e.Text)" 'Warning'; $res += [pscustomobject]$e; continue
            }
        }
        $todo += $it
    }
    # 2. je Bereich eine Aufgabe (zuerst fuer alle Benutzer als SYSTEM, dann Benutzer) - nacheinander, Installer stoeren sich sonst
    $groups = @(
        @{ Scope = 'Machine'; Account = 'SYSTEM'; Sid = ''; Label = 'fuer alle Benutzer (als SYSTEM)' },
        @{ Scope = 'User'; Account = "$($Ctx.UserAccount)"; Sid = "$($Ctx.UserSid)"; Label = "nur fuer $($Ctx.UserAccount) (als dieser Benutzer)" })
    $done = 0; $total = [Math]::Max(1, $todo.Count)
    foreach ($g in $groups) {
        $list = @($todo | Where-Object { "$($_.Scope)" -eq $g.Scope })
        if (-not $list.Count) { continue }
        if (Test-HMCancel $Job) { break }
        if ($g.Scope -eq 'User' -and -not $g.Account) {
            foreach ($it in $list) { $e = & $new $it; $e.Status = 'Error'; $e.Text = 'kein angemeldeter Benutzer gewaehlt'; $res += [pscustomobject]$e }
            continue
        }
        Write-HMLog $Job "$($list.Count) Programm(e) $($g.Label) ..." 'Info'
        $names = @{}; foreach ($it in $list) { $names["$($it.Id)"] = $it }
        $state = @{ Job = $Job; Names = $names; Done = $done; Total = $total }
        $req = @{ Mode = 'Update'; Items = @($list | ForEach-Object { @{ Id = "$($_.Id)"; Source = "$($_.Source)"; Unknown = [bool]$_.Unknown } }) }
        $onLine = {
            param($ln)
            $p = "$ln".Split('|')
            if ($p[0] -eq 'START' -and $state.Names.ContainsKey($p[1])) {
                $x = $state.Names[$p[1]]
                $state.Job.Status = "$($state.Done + 1)/$($state.Total): $($x.Name)"
                $state.Job.Progress = [int]($state.Done * 100 / $state.Total)
                Write-HMLog $state.Job "  $($x.Name) ($($x.Id)): $($x.Installed) -> $($x.Available) ..." 'Info'
            } elseif ($p[0] -eq 'DONE') { $state.Done++ }
        }   # ohne GetNewClosure: $state wird ueber die Aufrufkette gefunden (Wait-HMAuTask ruft den Block auf)
        $r = Invoke-HMAuTaskRun $g.Account $g.Sid $req 10800 $Job $onLine
        $done = $state.Done
        foreach ($er in @($r.Errors | Where-Object { $_ })) { Write-HMLog $Job "  $er" 'Error' }
        foreach ($it in $list) {
            $e = & $new $it
            $x = @(@($r.Results) | Where-Object { "$($_.Id)" -eq "$($it.Id)" })[0]
            if (-not $x) {
                $e.Status = $(if (Test-HMCancel $Job) { 'Skipped' } else { 'Error' })
                $e.Text = $(if (Test-HMCancel $Job) { 'abgebrochen' } elseif (@($r.Errors).Count) { "nicht ausgefuehrt: $(@($r.Errors)[0])" } else { 'kein Ergebnis' })
            } elseif ("$($x.Status)" -eq 'Exception') { $e.Status = 'Error'; $e.Text = "$($x.Text)" }
            else {
                $e.Status = $(if ("$($x.Status)" -eq 'Ok') { 'OK' } else { 'Error' })
                $e.Reboot = [bool]$x.Reboot
                $e.Text = Format-HMAuResult "$($x.Status)" $x.InstallerErrorCode $x.ExtendedErrorCode ([bool]$x.Reboot)
            }
            Write-HMLog $Job "  $($it.Name): $($e.Text)" $(if ($e.Status -eq 'OK') { 'Success' } elseif ($e.Status -eq 'Skipped') { 'Warning' } else { 'Error' })
            $res += [pscustomobject]$e
        }
    }
    $Job.Progress = 100
    $ok = @($res | Where-Object { $_.Status -eq 'OK' }).Count
    $err = @($res | Where-Object { $_.Status -eq 'Error' }).Count
    $skip = @($res | Where-Object { $_.Status -eq 'Skipped' }).Count
    $reb = @($res | Where-Object { $_.Reboot }).Count
    Write-HMLog $Job "App-Updates fertig: $ok aktualisiert, $err Fehler, $skip uebersprungen$(if ($reb) { ", $reb brauchen einen Neustart" })" $(if ($err) { 'Warning' } else { 'Success' })
    $Job.Result = [pscustomobject]@{ Status = $(if ($Job.Cancel) { 'Cancelled' } elseif ($err) { 'Warning' } else { 'OK' }); Items = $res; Reboot = ($reb -gt 0) }
}
