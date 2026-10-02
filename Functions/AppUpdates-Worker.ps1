#Requires -Version 5.1
<#
.SYNOPSIS
    App-Updates: WinGet im Konto des angemeldeten Benutzers bzw. als SYSTEM ausfuehren (von HUMig als einmalige geplante Aufgabe gestartet).
.DESCRIPTION
    WinGet ist pro Benutzer registriert - Programme, die nur fuer einen Benutzer installiert sind, sieht es nur in dessen Konto.
    Programme fuer alle Benutzer werden als SYSTEM aktualisiert (Modul Microsoft.WinGet.Client, ohne UAC-Abfrage).
    Austausch ueber den Ordner -Dir: request.json (Auftrag), log.txt (Fortschritt), result.json (Ergebnis), cancel (Abbruch).
.NOTES
    Zielmaschine: der PC, an dem HUMig die Aufgabe anlegt. Laeuft ohne Oberflaeche.
#>
param([Parameter(Mandatory)][string]$Dir)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
function Write-WLog([string]$m) { try { Add-Content -LiteralPath (Join-Path $Dir 'log.txt') -Value $m -Encoding UTF8 } catch { } }
$res = [ordered]@{ Account = [Security.Principal.WindowsIdentity]::GetCurrent().Name; Items = @(); Results = @(); Errors = @(); Sources = @() }
try {
    $req = Get-Content -LiteralPath (Join-Path $Dir 'request.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Import-Module Microsoft.WinGet.Client -ErrorAction Stop
    if ("$($req.Mode)" -eq 'SourceAdd') {
        $p = @{ Name = "$($req.Name)"; Argument = "$($req.Argument)"; ErrorAction = 'Stop' }
        if ("$($req.Type)") { $p.Type = "$($req.Type)" }
        try { Add-WinGetSource @p } catch { $res.Errors += "Quelle $($req.Name): $($_.Exception.Message)" }
    } elseif ("$($req.Mode)" -eq 'SourceRemove') {
        try { Remove-WinGetSource -Name "$($req.Name)" -ErrorAction Stop } catch { $res.Errors += "Quelle $($req.Name): $($_.Exception.Message)" }
    } elseif ("$($req.Mode)" -eq 'List') {
        try { $res.Sources = @(Get-WinGetSource -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ Name = "$($_.Name)"; Argument = "$($_.Argument)"; Type = "$($_.Type)" } }) } catch { $res.Errors += "Quellen: $($_.Exception.Message)" }
        $seen = @{}
        foreach ($src in @($req.Sources | Where-Object { $_ })) {
            try {
                foreach ($p in @(Get-WinGetPackage -Source "$src" -ErrorAction Stop)) {
                    if (-not $p -or -not "$($p.Id)" -or $seen.ContainsKey("$($p.Id)")) { continue }
                    $avail = @($p.AvailableVersions | Where-Object { $_ })
                    $inst = "$($p.InstalledVersion)"
                    $unknown = (-not $inst -or $inst -eq 'Unknown')
                    if (-not [bool]$p.IsUpdateAvailable -and -not ([bool]$req.IncludeUnknown -and $unknown -and $avail.Count)) { continue }
                    $seen["$($p.Id)"] = $true
                    $res.Items += [pscustomobject]@{ Id = "$($p.Id)"; Name = "$($p.Name)"; Installed = $(if ($unknown) { 'unbekannt' } else { $inst }); Available = $(if ($avail.Count) { "$($avail[0])" } else { '' }); Source = "$src"; Unknown = $unknown }
                }
            } catch { $res.Errors += "Quelle ${src}: $($_.Exception.Message)" }
        }
    } else {
        foreach ($it in @($req.Items | Where-Object { $_ })) {
            if (Test-Path -LiteralPath (Join-Path $Dir 'cancel')) { Write-WLog 'CANCEL'; break }
            Write-WLog "START|$($it.Id)"
            $r = [ordered]@{ Id = "$($it.Id)"; Status = ''; InstallerErrorCode = 0; ExtendedErrorCode = 0; Reboot = $false; Text = '' }
            try {
                $up = @{ Id = "$($it.Id)"; Source = "$($it.Source)"; MatchOption = 'Equals'; Mode = 'Silent'; ErrorAction = 'Stop' }
                if ([bool]$it.Unknown) { $up.IncludeUnknown = $true }
                $u = Update-WinGetPackage @up
                $r.Status = "$($u.Status)"
                try { $r.InstallerErrorCode = [int64]$u.InstallerErrorCode } catch { }
                try { $r.ExtendedErrorCode = "$($u.ExtendedErrorCode)" } catch { }
                $r.Reboot = [bool]$u.RebootRequired
            } catch { $r.Status = 'Exception'; $r.Text = "$($_.Exception.Message)" }
            $res.Results += [pscustomobject]$r
            Write-WLog "DONE|$($it.Id)|$($r.Status)"
        }
    }
} catch { $res.Errors += "WinGet ($($res.Account)): $($_.Exception.Message)" }
$tmp = Join-Path $Dir 'result.tmp'
[pscustomobject]$res | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $tmp -Encoding UTF8
Move-Item -LiteralPath $tmp -Destination (Join-Path $Dir 'result.json') -Force
