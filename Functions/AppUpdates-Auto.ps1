#Requires -Version 7.0
<#
.SYNOPSIS
    App-Updates nach Zeitplan: Programme fuer alle Benutzer ueber WinGet aktualisieren (Ausnahmen beachtet).
.DESCRIPTION
    Wird von HUMig nach %ProgramData%\HUMig\AppUpdates\auto\ kopiert und von der geplanten Aufgabe "HUMig App-Updates"
    als SYSTEM mit PowerShell 7 gestartet (das Modul Microsoft.WinGet.Client laeuft als SYSTEM nur dort).
    Lesen: Modul (nur Programme fuer alle Benutzer sichtbar). Aktualisieren: winget.exe.
    Ergebnis: history.json (je Programm), last.json (Zusammenfassung), log.txt (letzte Laeufe).
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
    switch ($hex) {
        '0x8A150109' { return @{ Ok = $true; Reboot = $true; Text = 'aktualisiert - Neustart noetig' } }
        '0x8A15002B' { return @{ Ok = $false; Reboot = $false; Text = "kein passendes Update ($hex)" } }
        '0x8A150101' { return @{ Ok = $false; Reboot = $false; Text = "Programm laeuft noch ($hex)" } }
        '0x8A150008' { return @{ Ok = $false; Reboot = $false; Text = "Download fehlgeschlagen ($hex)" } }
        '0x8A150011' { return @{ Ok = $false; Reboot = $false; Text = "Pruefsumme passt nicht - nicht installiert ($hex)" } }
        default { return @{ Ok = $false; Reboot = $false; Text = "Fehler ($hex)" } }
    }
}
Write-ALog '=== Start'
$hist = @(); $ok = 0; $err = 0; $excl = 0; $found = 0
try {
    # Log kurz halten (letzte 2000 Zeilen)
    try { $lf = Join-Path $Dir 'log.txt'; if ((Get-Item -LiteralPath $lf -ErrorAction Stop).Length -gt 400KB) { Get-Content -LiteralPath $lf -Tail 2000 | Set-Content -LiteralPath $lf -Encoding UTF8 } } catch { }
    $cfg = Get-Content -LiteralPath (Join-Path $Dir 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Import-Module Microsoft.WinGet.Client -ErrorAction Stop
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
    foreach ($t in $todo) {
        $out = @(& $wg upgrade --id $t.Id --exact --source $t.Source --silent --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1 | ForEach-Object { "$_" })
        $r = Format-ACode ([int64]$LASTEXITCODE)
        if ($r.Ok) { $ok++ } else { $err++ }
        Write-ALog "$($t.Name) $($t.From) -> $($t.To): $($r.Text)"
        $hist += [pscustomobject]@{ Date = (Get-Date).ToString('yyyy-MM-dd HH:mm'); Computer = $PC; Id = $t.Id; Name = $t.Name; From = $t.From; To = $t.To; Source = $t.Source; Scope = 'Machine'; Status = $(if ($r.Ok) { 'OK' } else { 'Error' }); Text = "$($r.Text) (Zeitplan)"; Reboot = [bool]$r.Reboot }
    }
} catch { $err++; Write-ALog "FEHLER: $($_.Exception.Message)" }
try {
    $hf = Join-Path $Dir 'history.json'
    $old = @(); if (Test-Path -LiteralPath $hf) { $old = @(Get-Content -LiteralPath $hf -Raw -Encoding UTF8 | ConvertFrom-Json | ForEach-Object { $_ }) }
    ConvertTo-Json -InputObject @(@($old) + @($hist) | Select-Object -Last 1000) -Depth 4 | Set-Content -LiteralPath $hf -Encoding UTF8
    [pscustomobject]@{ Date = (Get-Date).ToString('yyyy-MM-dd HH:mm'); Found = $found; Ok = $ok; Err = $err; Excluded = $excl } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Dir 'last.json') -Encoding UTF8
} catch { Write-ALog "Verlauf nicht speicherbar: $($_.Exception.Message)" }
Write-ALog "=== Ende: $ok aktualisiert, $err Fehler"
