# HUMig - Erstinstallation in einer Zeile. Aufruf in PowerShell als Administrator:
#   irm https://github.com/ChiliApple/HUMig/releases/latest/download/Install.ps1 | iex
# Was passiert:
#   1. Zielordner abfragen (Vorschlag: C:\Program Files\HUMig - dort koennen normale Benutzer nichts veraendern)
#   2. Pull.ps1 aus demselben freigegebenen Release laden und gegen HUMig-files.sha256 pruefen
#   3. Pull.ps1 ausfuehren: laedt HUMig, prueft jede Datei (Pruefsumme und Signatur) und startet es
# Abbrechen jederzeit mit Strg+C. Nur ASCII-Zeichen (wird per irm | iex ausgefuehrt; im Release ohne BOM).
& {
    $ErrorActionPreference = 'Stop'
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    Write-Host "`n=== HUMig - Erstinstallation ===" -ForegroundColor Cyan
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $admin) { Write-Host 'Bitte PowerShell als Administrator starten und die Zeile erneut ausfuehren.' -ForegroundColor Yellow; return }
    $def = Join-Path $env:ProgramFiles 'HUMig'
    $t = (Read-Host "Zielordner (Enter = $def)").Trim().Trim('"')
    if (-not $t) { $t = $def }
    try { $t = [IO.Path]::GetFullPath($t).TrimEnd('\') } catch { Write-Host "Ungueltiger Ordner: $t" -ForegroundColor Red; return }
    if ($t -eq [IO.Path]::GetPathRoot($t).TrimEnd('\')) { Write-Host 'Bitte einen Ordner angeben, nicht ein ganzes Laufwerk.' -ForegroundColor Red; return }
    if ((Test-Path -LiteralPath $t) -and @(Get-ChildItem -LiteralPath $t -Force -ErrorAction SilentlyContinue).Count -and -not (Test-Path -LiteralPath (Join-Path $t 'HUMig.ps1'))) {
        Write-Host "$t ist nicht leer und enthaelt kein HUMig - bitte einen leeren oder neuen Ordner angeben." -ForegroundColor Red; return
    }
    $base = 'https://github.com/ChiliApple/HUMig/releases/latest/download'
    $tmp = Join-Path $env:TEMP ('HUMig-Setup-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        Write-Host 'Lade Pull.ps1 aus dem freigegebenen Release ...' -ForegroundColor Gray
        Invoke-WebRequest -Uri "$base/Pull.ps1" -OutFile (Join-Path $tmp 'Pull.ps1') -UseBasicParsing
        Invoke-WebRequest -Uri "$base/HUMig-files.sha256" -OutFile (Join-Path $tmp 'HUMig-files.sha256') -UseBasicParsing
        $want = ''
        foreach ($l in [IO.File]::ReadAllLines((Join-Path $tmp 'HUMig-files.sha256'))) { if ($l -match '^([0-9a-fA-F]{64})  Pull\.ps1$') { $want = $Matches[1].ToLower() } }
        $have = (Get-FileHash -LiteralPath (Join-Path $tmp 'Pull.ps1') -Algorithm SHA256).Hash.ToLower()
        if (-not $want -or $want -ne $have) { Write-Host 'Pruefsumme von Pull.ps1 passt nicht zum Release - abgebrochen, nichts installiert.' -ForegroundColor Red; return }
        Write-Host "Pull.ps1 geprueft. Installiere nach $t ..." -ForegroundColor Gray
        & (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -ExecutionPolicy Bypass -File (Join-Path $tmp 'Pull.ps1') -Target $t
    } catch {
        Write-Host "Fehler: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host 'Alternative: Pull.ps1 herunterladen und mit -Target starten (siehe INSTALL.md).' -ForegroundColor Yellow
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
