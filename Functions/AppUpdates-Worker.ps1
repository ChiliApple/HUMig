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
# Bereich aus der Registry: Deinstallations-Eintrag unter HKLM = fuer alle Benutzer, unter HKCU = nur dieser Benutzer
function Get-WScopeMap {
    $m = @{ Machine = @(); User = @() }
    foreach ($k in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')) { $m.Machine += @(Get-ItemProperty -Path $k -ErrorAction SilentlyContinue | ForEach-Object { "$($_.DisplayName)".Trim() } | Where-Object { $_ }) }
    $m.User += @(Get-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | ForEach-Object { "$($_.DisplayName)".Trim() } | Where-Object { $_ })
    return $m
}
function ConvertTo-WKey([string]$n) {
    # Vergleichsschluessel: ohne Klammerzusaetze (Sprache, Architektur), Versionsnummern und Sonderzeichen
    $k = ("$n" -replace '\([^)]*\)', ' ' -replace '\b(x64|x86|64-bit|32-bit|amd64|arm64)\b', ' ' -replace '\b\d+(\.\d+)+\b', ' ').ToLower()
    return ($k -replace '[^a-z0-9]', '')
}
function Get-WScope($Map, [string]$Name) {
    $n = "$Name".Trim()
    if (-not $n) { return 'User' }
    if ($Map.User -contains $n) { return 'User' }
    if ($Map.Machine -contains $n) { return 'Machine' }
    $k = ConvertTo-WKey $n
    if ($k.Length -lt 4) { return 'User' }
    $uk = @($Map.User | ForEach-Object { ConvertTo-WKey $_ })
    $mk = @($Map.Machine | ForEach-Object { ConvertTo-WKey $_ })
    if ($uk -contains $k) { return 'User' }
    if ($mk -contains $k) { return 'Machine' }
    # Teilname (z.B. "Adobe Acrobat Reader" <-> "Adobe Acrobat", "PuTTY" <-> "PuTTY release"): der kuerzere Name mind. 5 Zeichen
    $pre = { param($a, $b) $a.Length -ge 5 -and $b.Length -ge 5 -and ($a.StartsWith($b) -or $b.StartsWith($a)) }
    if (@($uk | Where-Object { & $pre $_ $k }).Count) { return 'User' }
    if (@($mk | Where-Object { & $pre $_ $k }).Count) { return 'Machine' }
    return 'User'   # nicht gefunden (z.B. MSIX-Apps wie Outlook) = im Benutzerkonto aktualisieren
}
# winget.exe fuer SYSTEM (dort nicht als Befehl registriert): aus dem App-Installer-Paketordner
function Get-WWingetExe {
    $c = @(Get-ChildItem -Path (Join-Path $env:ProgramFiles 'WindowsApps') -Filter 'Microsoft.DesktopAppInstaller_*_8wekyb3d8bbwe' -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'winget.exe') } |
        Sort-Object { try { [version](($_.Name -split '_')[1]) } catch { [version]'0.0' } } -Descending)
    if ($c.Count) { return (Join-Path $c[0].FullName 'winget.exe') }
    $g = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($g) { return $g.Source }
    return ''
}
$res = [ordered]@{ Account = [Security.Principal.WindowsIdentity]::GetCurrent().Name; Items = @(); Results = @(); Errors = @(); Sources = @() }
try {
    $req = Get-Content -LiteralPath (Join-Path $Dir 'request.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not [bool]$req.Cli) { Import-Module Microsoft.WinGet.Client -ErrorAction Stop }
    if ("$($req.Mode)" -eq 'SourceAdd') {
        $p = @{ Name = "$($req.Name)"; Argument = "$($req.Argument)"; ErrorAction = 'Stop' }
        if ("$($req.Type)") { $p.Type = "$($req.Type)" }
        try { Add-WinGetSource @p } catch { $res.Errors += "Quelle $($req.Name): $($_.Exception.Message)" }
    } elseif ("$($req.Mode)" -eq 'SourceRemove') {
        try { Remove-WinGetSource -Name "$($req.Name)" -ErrorAction Stop } catch { $res.Errors += "Quelle $($req.Name): $($_.Exception.Message)" }
    } elseif ("$($req.Mode)" -eq 'List') {
        try { $res.Sources = @(Get-WinGetSource -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ Name = "$($_.Name)"; Argument = "$($_.Argument)"; Type = "$($_.Type)" } }) } catch { $res.Errors += "Quellen: $($_.Exception.Message)" }
        $seen = @{}
        $smap = Get-WScopeMap
        foreach ($src in @($req.Sources | Where-Object { $_ })) {
            try {
                foreach ($p in @(Get-WinGetPackage -Source "$src" -ErrorAction Stop)) {
                    if (-not $p -or -not "$($p.Id)" -or $seen.ContainsKey("$($p.Id)")) { continue }
                    $avail = @($p.AvailableVersions | Where-Object { $_ })
                    $inst = "$($p.InstalledVersion)"
                    $unknown = (-not $inst -or $inst -eq 'Unknown')
                    if (-not [bool]$p.IsUpdateAvailable -and -not ([bool]$req.IncludeUnknown -and $unknown -and $avail.Count)) { continue }
                    $seen["$($p.Id)"] = $true
                    $res.Items += [pscustomobject]@{ Id = "$($p.Id)"; Name = "$($p.Name)"; Installed = $(if ($unknown) { 'unbekannt' } else { $inst }); Available = $(if ($avail.Count) { "$($avail[0])" } else { '' }); Source = "$src"; Unknown = $unknown; Scope = (Get-WScope $smap "$($p.Name)") }
                }
            } catch { $res.Errors += "Quelle ${src}: $($_.Exception.Message)" }
        }
    } elseif ([bool]$req.Cli) {
        # als SYSTEM: Modul geht unter Windows PowerShell nicht -> winget.exe direkt (nur Ausgabe-Code, keine Textauswertung)
        $wg = Get-WWingetExe
        if (-not $wg) { throw 'winget.exe nicht gefunden (App Installer fuer alle Benutzer?)' }
        foreach ($it in @($req.Items | Where-Object { $_ })) {
            if (Test-Path -LiteralPath (Join-Path $Dir 'cancel')) { Write-WLog 'CANCEL'; break }
            Write-WLog "START|$($it.Id)"
            $r = [ordered]@{ Id = "$($it.Id)"; Status = ''; InstallerErrorCode = 0; ExtendedErrorCode = 0; Reboot = $false; Text = ''; Code = 0 }
            try {
                $a = if ("$($req.Mode)" -eq 'Install') { @('install', '--id', "$($it.Id)", '--exact', '--source', "$($it.Source)", '--scope', 'machine') } else { @('upgrade', '--id', "$($it.Id)", '--exact', '--source', "$($it.Source)") }
                $a += @('--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
                if ([bool]$it.Unknown) { $a += '--include-unknown' }
                $out = @(& $wg @a 2>&1 | ForEach-Object { "$_" })
                $code = [int]$LASTEXITCODE
                $r.Code = $code
                $last = @($out | Where-Object { "$_".Trim() -and "$_" -notmatch '^[\s\-\\|/]+$' -and "$_" -notmatch '[\u2580-\u259F]' } | Select-Object -Last 2) -join ' / '
                $r.Status = 'Cli'; $r.Text = $last
            } catch { $r.Status = 'Exception'; $r.Text = "$($_.Exception.Message)" }
            $res.Results += [pscustomobject]$r
            Write-WLog "DONE|$($it.Id)|$($r.Status)|$($r.Code)|$($r.InstallerErrorCode)|$($r.ExtendedErrorCode)|$($r.Reboot)"
        }
    } else {
        foreach ($it in @($req.Items | Where-Object { $_ })) {
            if (Test-Path -LiteralPath (Join-Path $Dir 'cancel')) { Write-WLog 'CANCEL'; break }
            Write-WLog "START|$($it.Id)"
            $r = [ordered]@{ Id = "$($it.Id)"; Status = ''; InstallerErrorCode = 0; ExtendedErrorCode = 0; Reboot = $false; Text = ''; Code = 0 }
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
            Write-WLog "DONE|$($it.Id)|$($r.Status)|$($r.Code)|$($r.InstallerErrorCode)|$($r.ExtendedErrorCode)|$($r.Reboot)"
        }
    }
} catch { $res.Errors += "WinGet ($($res.Account)): $($_.Exception.Message)" }
$tmp = Join-Path $Dir 'result.tmp'
[pscustomobject]$res | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $tmp -Encoding UTF8
Move-Item -LiteralPath $tmp -Destination (Join-Path $Dir 'result.json') -Force
