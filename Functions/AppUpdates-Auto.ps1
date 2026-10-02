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
        default { 'Fehler' }
    }
    return @{ Ok = $false; Reboot = $false; Text = "$t ($hex)" }
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
$ok = 0; $err = 0; $excl = 0; $found = 0; $i = 0; $todo = @()
try {
    # Log kurz halten (letzte 2000 Zeilen)
    try { $lf = Join-Path $Dir 'log.txt'; if ((Get-Item -LiteralPath $lf -ErrorAction Stop).Length -gt 400KB) { Get-Content -LiteralPath $lf -Tail 2000 | Set-Content -LiteralPath $lf -Encoding UTF8 } } catch { }
    $cfg = Get-Content -LiteralPath (Join-Path $Dir 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    try { Import-Module Microsoft.WinGet.Client -ErrorAction Stop } catch { Import-Module (Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules\Microsoft.WinGet.Client') -ErrorAction Stop }
    $wg = Get-AWingetExe
    if (-not $wg) { throw 'winget.exe nicht gefunden' }
    $seen = @{}
    $todo = @()
    foreach ($src in @($cfg.Sources | Where-Object { $_ })) {
        try {
            foreach ($p in @(Get-WinGetPackage -Source "$src" -ErrorAction Stop | Where-Object { $_.IsUpdateAvailable })) {
                if ($seen.ContainsKey("$($p.Id)")) { continue }
                $seen["$($p.Id)"] = $true
                $found++
                $ex = @($cfg.Exclude | Where-Object { $_ -and "$($_.Pattern)".Trim() -and ("$($p.Id)" -like "$($_.Pattern)".Trim() -or "$($p.Name)" -like "$($_.Pattern)".Trim()) })[0]
                if ($ex) { $excl++; Write-ALog "Ausnahme: $($p.Name) ($($ex.Pattern))"; continue }
                $todo += [pscustomobject]@{ Id = "$($p.Id)"; Name = "$($p.Name)"; From = "$($p.InstalledVersion)"; To = "$(@($p.AvailableVersions)[0])"; Source = "$src" }
            }
        } catch { Write-ALog "Quelle ${src}: $($_.Exception.Message)" }
    }
    Write-ALog "$found Update(s), $excl Ausnahme(n), $($todo.Count) zu aktualisieren"
    $i = 0
    foreach ($t in $todo) {
        Set-AProgress $true $i $todo.Count "$($t.Name)" $ok $err
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
    [pscustomobject]@{ Date = (Get-Date).ToString('yyyy-MM-dd HH:mm'); Found = $found; Ok = $ok; Err = $err; Excluded = $excl } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Dir 'last.json') -Encoding UTF8
} catch { Write-ALog "Bericht nicht speicherbar: $($_.Exception.Message)" }
Write-ALog "=== Ende: $ok aktualisiert, $err Fehler"
