#Requires -Version 7.0
<#
.SYNOPSIS
    App-Updates nach Zeitplan: Programme fuer alle Benutzer ueber WinGet aktualisieren (Ausnahmen beachtet).
.DESCRIPTION
    Wird von HUMig nach %ProgramData%\HUMig\AppUpdates\auto\ kopiert und von der geplanten Aufgabe "HUMig App-Updates"
    als SYSTEM mit PowerShell 7 gestartet (das Modul Microsoft.WinGet.Client laeuft als SYSTEM nur dort).
    Lesen: Modul (nur Programme fuer alle Benutzer sichtbar). Aktualisieren: winget.exe.
    Ergebnis: history.json (je Programm, sofort), progress.json (Fortschritt), last.json (Zusammenfassung), log.txt (letzte Laeufe).
.NOTES
    Zielmaschine: der PC mit dem Zeitplan (SYSTEM, ohne Anmeldung).
#>
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Dir = $PSScriptRoot
$PC = "$env:COMPUTERNAME".ToUpper()
function Write-ALog([string]$m) { try { Add-Content -LiteralPath (Join-Path $Dir 'log.txt') -Value ('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) -Encoding UTF8 } catch { } }
function Get-AWingetExe {
    $c = @(Get-ChildItem -Path (Join-Path $env:ProgramFiles 'WindowsApps') -Filter 'Microsoft.DesktopAppInstaller_*_8wekyb3d8bbwe' -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'winget.exe') } |
        Sort-Object { try { [version](($_.Name -split '_')[1]) } catch { [version]'0.0' } } -Descending)
    if ($c.Count) { return (Join-Path $c[0].FullName 'winget.exe') }
    return ''
}
function Format-ACode([int64]$Code) {
    if ($Code -eq 0) { return @{ Ok = $true; Reboot = $false; Text = 'aktualisiert' } }
    $u = if ($Code -lt 0) { [uint32]($Code + 4294967296) } else { [uint32]$Code }
    $hex = '0x{0:X8}' -f $u
    if ($hex -eq '0x8A150109') { return @{ Ok = $true; Reboot = $true; Text = 'aktualisiert - Neustart noetig' } }
    $t = switch ($hex) {
        '0x8A15002B' { 'kein passendes Update' }
        '0x8A15004F' { 'neue Version nicht neuer als installierte' }
        '0x8A150014' { 'kein installiertes Paket gefunden' }
        '0x8A150010' { 'kein passender Installer' }
        '0x8A15010A' { 'Neustart noetig, dann erneut' }
        '0x8A150101' { 'Programm laeuft noch' }
        '0x8A150102' { 'andere Installation laeuft gerade' }
        '0x8A150104' { 'Abhaengigkeit fehlt' }
        '0x8A150106' { 'zu wenig Speicher' }
        '0x8A150008' { 'Download fehlgeschlagen' }
        '0x8A15003A' { 'durch Gruppenrichtlinie blockiert' }
        '0x8A150006' { 'Installer meldet Fehler' }
        '0x8A150115' { 'Installer meldet Fehler' }
        '0x8A150011' { 'Pruefsumme passt nicht - nicht installiert' }
        '0x8A15010C' { 'Installation abgebrochen - meist lief das Programm noch; evtl. unvollstaendig' }
        '0x8A15010B' { 'PC startet neu, um die Installation abzuschliessen' }
        '0x8A15010D' { 'andere Version ist schon installiert' }
        '0x8A15010E' { 'hoehere Version ist schon installiert' }
        '0x8A150103' { 'Datei in Benutzung' }
        '0x8A150105' { 'Datentraeger voll' }
        '0x8A150107' { 'Installer braucht eine Internetverbindung' }
        '0x8A150108' { 'Installer meldet Fehler (Hersteller kontaktieren)' }
        default { 'Fehler' }
    }
    return @{ Ok = $false; Reboot = $false; Text = "$t ($hex)" }
}
# Taugt ein Ordner als Programmordner fuer die Suche nach laufenden Prozessen? Nie der Windows-Ordner (samt Unterordnern -
# DisplayIcon zeigt manchmal auf System32\msiexec.exe), nie Sammelordner (Programme, Common Files, ProgramData, Laufwerk,
# Benutzer-, Profil- und AppData-Wurzeln) - sonst gaelten svchost, ctfmon usw. als "laeuft" (B50)
function Test-AAppDir([string]$Dir) {
    $d = "$Dir".Trim().Trim('"').TrimEnd('\')
    if ($d.Length -le 3 -or $d -notmatch '^[A-Za-z]:\\') { return $false }
    $l = $d.ToLower()
    $win = "$(if ("$env:SystemRoot") { $env:SystemRoot } else { $env:windir })".TrimEnd('\').ToLower()
    if ($win -and ($l -eq $win -or $l.StartsWith($win + '\'))) { return $false }
    $roots = @("$env:ProgramFiles", "${env:ProgramFiles(x86)}", "$env:ProgramW6432", "$env:ProgramData", "$env:SystemDrive\", "$env:CommonProgramFiles", "${env:CommonProgramFiles(x86)}", "$env:CommonProgramW6432", "$env:PUBLIC") |
        Where-Object { $_ } | ForEach-Object { "$_".TrimEnd('\').ToLower() }
    if ($roots -contains $l) { return $false }
    # Store-Apps (WindowsApps samt Unterordnern) und Benutzerordner wie Downloads/Desktop/Dokumente: nie als Programmordner (B54)
    foreach ($pf in @("$env:ProgramFiles", "${env:ProgramFiles(x86)}", "$env:ProgramW6432") | Where-Object { $_ }) {
        $wa = ("$pf".TrimEnd('\') + '\windowsapps').ToLower()
        if ($l -eq $wa -or $l.StartsWith($wa + '\')) { return $false }
    }
    if ($l -match '^[a-z]:\\(users|documents and settings)\\[^\\]+\\(downloads|desktop|documents|dokumente|pictures|bilder|videos|music|musik|onedrive[^\\]*)(\\|$)') { return $false }
    if ($l -match '^[a-z]:\\(users|documents and settings)(\\[^\\]+(\\appdata(\\(local|roaming|locallow)(\\(programs|temp|microsoft|packages))?)?)?)?$') { return $false }
    return $true
}
# Prozess-/Dienstpfad im Windows-Ordner? Dort beendet bzw. stoppt HUMig nie etwas (Absicherung zusaetzlich zu Test-AAppDir)
function Test-AWinPath([string]$Path) {
    $win = "$(if ("$env:SystemRoot") { $env:SystemRoot } else { $env:windir })".TrimEnd('\').ToLower()
    return [bool]($win -and "$Path".ToLower().StartsWith($win + '\'))
}
# Laeuft das Programm in einer Benutzersitzung? (Installationsordner aus den Deinstallations-Eintraegen, Prozesse darin, Sitzung > 0)
# Dann im Zeitplan nicht aktualisieren - der Installer bricht sonst oft ab und hinterlaesst ein halb entferntes Programm.
# Dienste (Sitzung 0) stoppen die Installer selbst. Rueckgabe: Text der laufenden Prozesse oder ''
function Get-ARunningText([string]$Name) {
    $n = "$Name".Trim()
    if (-not $n) { return '' }
    $dirs = @(foreach ($k in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
            foreach ($r in @(Get-ItemProperty -Path $k -ErrorAction SilentlyContinue | Where-Object { "$($_.DisplayName)" -eq $n -or "$($_.DisplayName)".StartsWith("$n ", [StringComparison]::OrdinalIgnoreCase) })) {
                $d = "$($r.InstallLocation)".Trim().Trim('"')
                if (-not $d -and "$($r.DisplayIcon)") { try { $d = Split-Path ("$($r.DisplayIcon)" -replace ',\s*-?\d+$', '').Trim('"') -Parent } catch { $d = '' } }
                if ($d) { $d.TrimEnd('\') }
            }
        }) | Where-Object { $_ -and (Test-AAppDir $_) } | Select-Object -Unique
    if (-not @($dirs).Count) { return '' }
    $run = @(Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue | Where-Object { [int]$_.SessionId -gt 0 -and $_.ExecutablePath -and -not (Test-AWinPath "$($_.ExecutablePath)") -and $(foreach ($d in $dirs) { if ("$($_.ExecutablePath)".ToLower().StartsWith($d.ToLower() + '\')) { $true; break } }) })
    return (@($run | ForEach-Object { "$($_.Name) ($($_.ProcessId))" }) -join ', ')
}
# Verlauf und Fortschritt nach jedem Programm speichern (HUMig > Zeitplaene ansehen liest beides auch waehrend des Laufs)
$hf = Join-Path $Dir 'history.json'
$pf = Join-Path $Dir 'progress.json'
function Add-AHistory($Entry) {
    try {
        $old = @(); if (Test-Path -LiteralPath $hf) { $old = @(Get-Content -LiteralPath $hf -Raw -Encoding UTF8 | ConvertFrom-Json | ForEach-Object { $_ }) }
        ConvertTo-Json -InputObject @(@($old) + @($Entry) | Select-Object -Last 1000) -Depth 4 | Set-Content -LiteralPath $hf -Encoding UTF8
    } catch { Write-ALog "Verlauf nicht speicherbar: $($_.Exception.Message)" }
}
function Set-AProgress([bool]$Running, [int]$Done, [int]$Total, [string]$Current, [int]$Ok, [int]$Err) {
    try { [pscustomobject]@{ Running = $Running; Started = $script:Started; Done = $Done; Total = $Total; Current = $Current; Ok = $Ok; Err = $Err; Updated = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') } | ConvertTo-Json | Set-Content -LiteralPath $pf -Encoding UTF8 } catch { }
}
$script:Started = (Get-Date).ToString('yyyy-MM-dd HH:mm')
Write-ALog '=== Start'
$ok = 0; $err = 0; $excl = 0; $skip = 0; $found = 0; $i = 0; $todo = @()
try {
    # Log kurz halten (letzte 2000 Zeilen)
    try { $lf = Join-Path $Dir 'log.txt'; if ((Get-Item -LiteralPath $lf -ErrorAction Stop).Length -gt 400KB) { Get-Content -LiteralPath $lf -Tail 2000 | Set-Content -LiteralPath $lf -Encoding UTF8 } } catch { }
    $cfg = Get-Content -LiteralPath (Join-Path $Dir 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    try { Import-Module Microsoft.WinGet.Client -ErrorAction Stop } catch { Import-Module (Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules\Microsoft.WinGet.Client') -ErrorAction Stop }
    $wg = Get-AWingetExe
    if (-not $wg) { throw 'winget.exe nicht gefunden' }
    # als SYSTEM fehlt sonst evtl. die Visual-C++-Laufzeit des App-Pakets (0xC0000135, z.B. Windows Server 2022)
    $arch = if ("$env:PROCESSOR_ARCHITECTURE" -eq 'ARM64') { 'arm64' } else { 'x64' }
    $vcl = @(Get-ChildItem -Path (Join-Path $env:ProgramFiles 'WindowsApps') -Filter "Microsoft.VCLibs.140.00.UWPDesktop_*_${arch}__8wekyb3d8bbwe" -Directory -ErrorAction SilentlyContinue |
        Sort-Object { try { [version](($_.Name -split '_')[1]) } catch { [version]'0.0' } } -Descending)
    foreach ($d in @(@($vcl | Select-Object -First 1 | ForEach-Object { $_.FullName }) + @(Split-Path $wg -Parent))) { if ($d -and "$env:PATH" -notlike "*$d*") { $env:PATH = "$d;$env:PATH" } }
    $seen = @{}
    $todo = @()
    foreach ($src in @($cfg.Sources | Where-Object { $_ })) {
        try {
            foreach ($p in @(Get-WinGetPackage -Source "$src" -ErrorAction Stop | Where-Object { $_.IsUpdateAvailable })) {
                if ($seen.ContainsKey("$($p.Id)")) { continue }
                $seen["$($p.Id)"] = $true
                $found++
                $ex = @($cfg.Exclude | Where-Object { $_ -and "$($_.Pattern)".Trim() -and $(try { "$($p.Id)" -like "$($_.Pattern)".Trim() -or "$($p.Name)" -like "$($_.Pattern)".Trim() } catch { "$($p.Id)" -eq "$($_.Pattern)".Trim() -or "$($p.Name)" -eq "$($_.Pattern)".Trim() }) })[0]
                if ($ex) { $excl++; Write-ALog "Ausnahme: $($p.Name) ($($ex.Pattern))"; continue }
                $todo += [pscustomobject]@{ Id = "$($p.Id)"; Name = "$($p.Name)"; From = "$($p.InstalledVersion)"; To = "$(@($p.AvailableVersions)[0])"; Source = "$src" }
            }
        } catch { Write-ALog "Quelle ${src}: $($_.Exception.Message)" }
    }
    Write-ALog "$found Update(s), $excl Ausnahme(n), $($todo.Count) zu aktualisieren"
    $i = 0
    foreach ($t in $todo) {
        Set-AProgress $true $i $todo.Count "$($t.Name)" $ok $err
        # Paket-ID pruefen (keine Optionen/Leerzeichen), sonst nicht an winget weitergeben
        if ("$($t.Id)" -notmatch '^[^\s\-"][^\s"]{0,254}\z' -or "$($t.Source)" -notmatch '^(?=.{1,64}\z)[A-Za-z0-9._](?:[A-Za-z0-9._ -]*[A-Za-z0-9._-])?\z') { $i++; $err++; Write-ALog "$($t.Name): ungueltige Paket-ID '$($t.Id)' bzw. Quelle '$($t.Source)' - uebersprungen"; continue }
        $rt = ''; try { $rt = Get-ARunningText $t.Name } catch { }
        if ($rt) {
            $i++; $skip++
            Write-ALog "$($t.Name): laeuft ($rt) - nicht aktualisiert, naechster Lauf versucht es erneut"
            Add-AHistory ([pscustomobject]@{ Date = (Get-Date).ToString('yyyy-MM-dd HH:mm'); Computer = $PC; Id = $t.Id; Name = $t.Name; From = $t.From; To = $t.To; Source = $t.Source; Scope = 'Machine'; Status = 'Skipped'; Text = "uebersprungen - laeuft ($rt) (Zeitplan)"; Reboot = $false })
            continue
        }
        $out = @(& $wg upgrade --id $t.Id --exact --source $t.Source --silent --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1 | ForEach-Object { "$_" })
        $r = Format-ACode ([int64]$LASTEXITCODE)
        $i++
        if ($r.Ok) { $ok++ } else { $err++ }
        $det = ''
        if (-not $r.Ok) { $det = @($out | Where-Object { "$_".Trim() -and "$_" -notmatch '^[\s\-\\|/]+$' -and "$_" -notmatch '[\u2580-\u259F]' } | Select-Object -Last 2) -join ' / ' }
        Write-ALog "$($t.Name) $($t.From) -> $($t.To): $($r.Text)$(if ($det) { " - $det" })"
        Add-AHistory ([pscustomobject]@{ Date = (Get-Date).ToString('yyyy-MM-dd HH:mm'); Computer = $PC; Id = $t.Id; Name = $t.Name; From = $t.From; To = $t.To; Source = $t.Source; Scope = 'Machine'; Status = $(if ($r.Ok) { 'OK' } else { 'Error' }); Text = "$($r.Text)$(if ($det) { ": $det" }) (Zeitplan)"; Reboot = [bool]$r.Reboot })
    }
} catch { $err++; Write-ALog "FEHLER: $($_.Exception.Message)" }
Set-AProgress $false $i $(if ($todo) { @($todo).Count } else { 0 }) '' $ok $err
try {
    [pscustomobject]@{ Date = (Get-Date).ToString('yyyy-MM-dd HH:mm'); Found = $found; Ok = $ok; Err = $err; Excluded = $excl; Skipped = $skip } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Dir 'last.json') -Encoding UTF8
} catch { Write-ALog "Bericht nicht speicherbar: $($_.Exception.Message)" }
Write-ALog "=== Ende: $ok aktualisiert, $err Fehler$(if ($skip) { ", $skip uebersprungen (lief)" })"
