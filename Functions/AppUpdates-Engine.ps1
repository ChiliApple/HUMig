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
    $s = [ordered]@{ OsOk = (Test-HMAuOsSupported); Module = ''; AppInstaller = ''; WinGet = ''; Ready = $false; Problem = '' }
    try { $m = @(Get-Module -ListAvailable -Name $script:HMAuModule | Sort-Object Version -Descending)[0]; if ($m) { $s.Module = "$($m.Version)" } } catch { }
    try { $a = @(Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' -ErrorAction Stop)[0]; if ($a) { $s.AppInstaller = "$($a.Version)" } } catch { }
    if (-not $s.OsOk) { $s.Problem = 'WinGet wird auf dieser Windows-Version nicht unterstuetzt (Windows 10 1809+/11, Windows Server 2025).' }
    elseif (-not $s.Module) { $s.Problem = "PowerShell-Modul $($script:HMAuModule) fehlt - 'WinGet einrichten'." }
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
function Get-HMAuSources {
    Import-Module $script:HMAuModule -ErrorAction Stop
    return @(Get-WinGetSource -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ Name = "$($_.Name)"; Argument = "$($_.Argument)"; Type = "$($_.Type)" } })
}
function Add-HMAuSource([string]$Name, [string]$Argument, [string]$Type) {
    Import-Module $script:HMAuModule -ErrorAction Stop
    $p = @{ Name = $Name; Argument = $Argument; ErrorAction = 'Stop' }
    if ($Type) { $p.Type = $Type }
    Add-WinGetSource @p
}
function Remove-HMAuSource([string]$Name) {
    Import-Module $script:HMAuModule -ErrorAction Stop
    Remove-WinGetSource -Name $Name -ErrorAction Stop
}

# ----------------------------------------------------------------------------
# Verfuegbare Updates
# ----------------------------------------------------------------------------
function Get-HMAuUpdates([string[]]$Sources, [bool]$IncludeUnknown) {
    Import-Module $script:HMAuModule -ErrorAction Stop
    $items = @{}
    $errors = @()
    foreach ($src in @($Sources | Where-Object { $_ })) {
        try {
            foreach ($p in @(Get-WinGetPackage -Source $src -ErrorAction Stop)) {
                if (-not $p -or -not "$($p.Id)") { continue }
                $avail = @($p.AvailableVersions | Where-Object { $_ })
                $inst = "$($p.InstalledVersion)"
                $unknown = (-not $inst -or $inst -eq 'Unknown')
                $upd = [bool]$p.IsUpdateAvailable
                if (-not $upd -and -not ($IncludeUnknown -and $unknown -and $avail.Count)) { continue }
                $k = "$($p.Id)"
                if ($items.ContainsKey($k)) { continue }
                $items[$k] = [pscustomobject]@{
                    Id = $k; Name = "$($p.Name)"; Installed = $(if ($unknown) { 'unbekannt' } else { $inst })
                    Available = $(if ($avail.Count) { "$($avail[0])" } else { '' }); Source = $src; Unknown = $unknown
                }
            }
        } catch { $errors += "Quelle ${src}: $($_.Exception.Message)" }
    }
    return [pscustomobject]@{ Items = @($items.Values | Sort-Object Name); Errors = $errors }
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
# Aktualisieren (Start-LongJob): $Ctx.Items = Id, Name, Source, Installed, Available; $Ctx.ProcDecisions/Running
# ----------------------------------------------------------------------------
function Start-HMAppUpdate([hashtable]$Ctx, $Job) {
    $items = @($Ctx.Items)
    $Job.Status = 'WinGet laden'
    Import-Module $script:HMAuModule -ErrorAction Stop
    Write-HMLog $Job "App-Updates: $($items.Count) Programm(e) an $env:COMPUTERNAME" 'Header'
    $res = @()
    $i = 0
    $pc = @{ Computer = $env:COMPUTERNAME; IsRemote = $false; Credential = $null; Account = "$($Ctx.Account)" }
    foreach ($it in $items) {
        if (Test-HMCancel $Job) { break }
        $i++
        $Job.Status = "$i/$($items.Count): $($it.Name)"
        $Job.Progress = [int](($i - 1) * 100 / [Math]::Max(1, $items.Count))
        $entry = [ordered]@{ Date = (Get-Date).ToString('yyyy-MM-dd HH:mm'); Computer = $env:COMPUTERNAME; Id = "$($it.Id)"; Name = "$($it.Name)"; From = "$($it.Installed)"; To = "$($it.Available)"; Source = "$($it.Source)"; Status = ''; Text = ''; Reboot = $false }
        # laufende Programme
        $dec = if ($Ctx.ProcDecisions) { "$($Ctx.ProcDecisions["$($it.Id)"])" } else { '' }
        $run = @(@($Ctx.Running) | Where-Object { "$($_.Id)" -eq "$($it.Id)" })[0]
        if ($run -and $dec -eq 'Skip') {
            $entry.Status = 'Skipped'; $entry.Text = "uebersprungen - laeuft ($($run.Running))"
            Write-HMLog $Job "  $($it.Name): $($entry.Text)" 'Warning'; $res += [pscustomobject]$entry; continue
        }
        if ($run -and $dec -match '^Close') {
            Write-HMLog $Job "  $($it.Name): Programm schliessen ($($run.Running)) ..." 'Info'
            $left = @(Close-HMProcs $pc $Job @($run.Procs) ($dec -eq 'CloseForce') 20)
            if ($left.Count) {
                $entry.Status = 'Skipped'; $entry.Text = 'uebersprungen - Programm liess sich nicht schliessen'
                Write-HMLog $Job "  $($it.Name): $($entry.Text)" 'Warning'; $res += [pscustomobject]$entry; continue
            }
        }
        Write-HMLog $Job "  $($it.Name) ($($it.Id)): $($it.Installed) -> $($it.Available) ..." 'Info'
        try {
            $up = @{ Id = "$($it.Id)"; Source = "$($it.Source)"; MatchOption = 'Equals'; Mode = 'Silent'; ErrorAction = 'Stop' }
            if ($it.Unknown) { $up.IncludeUnknown = $true }
            $r = Update-WinGetPackage @up
            $st = "$($r.Status)"
            $entry.Reboot = [bool]$r.RebootRequired
            $entry.Status = $(if ($st -eq 'Ok') { 'OK' } else { 'Error' })
            $entry.Text = Format-HMAuResult $st $r.InstallerErrorCode $r.ExtendedErrorCode ([bool]$r.RebootRequired)
        } catch {
            $entry.Status = 'Error'; $entry.Text = "$($_.Exception.Message)"
        }
        Write-HMLog $Job "  $($it.Name): $($entry.Text)" $(if ($entry.Status -eq 'OK') { 'Success' } else { 'Error' })
        $res += [pscustomobject]$entry
    }
    $Job.Progress = 100
    $ok = @($res | Where-Object { $_.Status -eq 'OK' }).Count
    $err = @($res | Where-Object { $_.Status -eq 'Error' }).Count
    $skip = @($res | Where-Object { $_.Status -eq 'Skipped' }).Count
    $reb = @($res | Where-Object { $_.Reboot }).Count
    Write-HMLog $Job "App-Updates fertig: $ok aktualisiert, $err Fehler, $skip uebersprungen$(if ($reb) { ", $reb brauchen einen Neustart" })" $(if ($err) { 'Warning' } else { 'Success' })
    $Job.Result = [pscustomobject]@{ Status = $(if ($Job.Cancel) { 'Cancelled' } elseif ($err) { 'Warning' } else { 'OK' }); Items = $res; Reboot = ($reb -gt 0) }
}
