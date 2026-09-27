#Requires -Version 5.1
<#
.SYNOPSIS
    HUMig Pull - laedt alle aktuellen Dateien aus dem GitHub-Repo und startet das Tool neu.
.DESCRIPTION
    Zielordner:
      1. -Target angegeben                          -> gewinnt immer
      2. Pull.ps1 liegt in einer HUMig-Installation -> Update an Ort und Stelle (USB-Laufwerk, Desktop, Share ...)
      3. Pull.ps1 liegt allein                      -> $env:USERPROFILE\Desktop\HUMig

    Lokale Daten bleiben unangetastet: BACKUPS\, Logs\, BIN\USMT\, Softwareverteilung\, HUMig.exe, Config\settings.json, exceptions.json, modules.json.
    Jede Datei wird zuerst als *.pulltmp geladen und dann ersetzt (5 Versuche bei Sperre).
    -WaitPid <PID>: vom Update-Button uebergeben - wartet bis HUMig beendet ist.

    Quelle: -Owner/-Repo/-Branch, sonst Config\update.json, sonst Standard-Repo.
    Token nur fuer private Repos: Umgebungsvariable HUMIG_GITHUB_TOKEN oder Config\GitHubToken_<DOMAIN>_<USER>.xml (DPAPI).
.NOTES
    Manuell: powershell -ExecutionPolicy Bypass -File Pull.ps1
    Zielmaschine: der PC / das Laufwerk, auf dem HUMig liegt.
#>
param(
    [string]$Target,
    [int]$WaitPid = 0,
    [switch]$NoStart,
    [string]$Owner,
    [string]$Repo,
    [string]$Branch
)
$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

if (-not $Target) {
    $here = $PSScriptRoot
    if ($here -and ((Test-Path (Join-Path $here 'HUMig.ps1')) -or (Test-Path (Join-Path $here 'Functions')))) { $Target = $here; $mode = 'Update (an Ort und Stelle)' }
    else { $Target = Join-Path $env:USERPROFILE 'Desktop\HUMig'; $mode = 'Erstinstallation (Desktop)' }
} else { $mode = 'Ziel per -Target' }
$Target = $Target.TrimEnd('\')

$cfgDir = Join-Path $Target 'Config'
$upd = $null
$updFile = Join-Path $cfgDir 'update.json'
if (Test-Path -LiteralPath $updFile) { try { $upd = Get-Content -LiteralPath $updFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { Write-Host '[WARN] Config\update.json nicht lesbar - Standardquelle' -ForegroundColor Yellow } }
if (-not $Owner)  { $Owner  = if ($upd -and "$($upd.Owner)".Trim())  { "$($upd.Owner)".Trim() }  else { 'ChiliApple' } }
if (-not $Repo)   { $Repo   = if ($upd -and "$($upd.Repo)".Trim())   { "$($upd.Repo)".Trim() }   else { 'HUMig' } }
if (-not $Branch) { $Branch = if ($upd -and "$($upd.Branch)".Trim()) { "$($upd.Branch)".Trim() } else { 'main' } }
$tokFile = Join-Path $cfgDir ('GitHubToken_{0}.xml' -f ("$($env:USERDOMAIN)_$($env:USERNAME)" -replace '[^\w\.\-]', '_'))
$Token = "$env:HUMIG_GITHUB_TOKEN".Trim()
if (-not $Token -and (Test-Path -LiteralPath $tokFile)) {
    try { $c = Import-Clixml -Path $tokFile; if ($c -is [System.Management.Automation.PSCredential]) { $Token = $c.GetNetworkCredential().Password.Trim() } }
    catch { Write-Host '[WARN] Gespeicherter GitHub-Token nicht lesbar (anderer Benutzer?)' -ForegroundColor Yellow }
}

Write-Host '=== HUMig Pull ===' -ForegroundColor Cyan
Write-Host "Zielordner: $Target" -ForegroundColor Gray
Write-Host "Modus:      $mode" -ForegroundColor Gray
Write-Host "Quelle:     $Owner/$Repo ($Branch)$(if ($Token) { ' mit Token' } else { ' ohne Token' })" -ForegroundColor Gray
Write-Host ''

if ($WaitPid -gt 0) {
    $proc = Get-Process -Id $WaitPid -ErrorAction SilentlyContinue
    if ($proc) {
        Write-Host "Warte bis HUMig (PID $WaitPid) beendet ist..." -ForegroundColor Yellow
        try { $null = $proc.WaitForExit(60000) } catch { }
        if (-not $proc.HasExited) { try { Stop-Process -Id $WaitPid -Force; $null = $proc.WaitForExit(10000) } catch { } }
    }
    Start-Sleep -Milliseconds 800
}

if (-not (Test-Path $Target)) { New-Item -ItemType Directory -Path $Target -Force | Out-Null }
try {
    $probe = Join-Path $Target ('.pullprobe_' + [Guid]::NewGuid().ToString('N'))
    [System.IO.File]::WriteAllText($probe, 'x'); Remove-Item $probe -Force
} catch {
    Write-Host "[FEHLER] Kein Schreibzugriff auf '$Target'. PowerShell als Administrator starten." -ForegroundColor Red
    Read-Host 'Enter zum Beenden' | Out-Null
    exit 1
}

function New-GHHeaders([string]$Accept) {
    $h = @{ Accept = $Accept; 'User-Agent' = 'HUMig-Pull' }
    if ($script:Token) { $h['Authorization'] = "token $($script:Token)" }
    return $h
}
$ProgressPreference = 'SilentlyContinue'
$sha = $null; $tree = $null; $newCred = $null
for ($attempt = 1; $attempt -le 3 -and -not $tree; $attempt++) {
    try {
        $ref  = Invoke-RestMethod "https://api.github.com/repos/$Owner/$Repo/git/refs/heads/$Branch" -Headers (New-GHHeaders 'application/vnd.github.v3+json') -UseBasicParsing
        $sha  = $ref.object.sha
        $tree = Invoke-RestMethod "https://api.github.com/repos/$Owner/$Repo/git/trees/${sha}?recursive=1" -Headers (New-GHHeaders 'application/vnd.github.v3+json') -UseBasicParsing
    } catch {
        $code = 0; try { $code = [int]$_.Exception.Response.StatusCode } catch { }
        if (-not $newCred -and $code -in 401, 403, 404) {
            Write-Host "[INFO] $Owner/$Repo nicht erreichbar (HTTP $code) - privates Repo?" -ForegroundColor Yellow
            Write-Host 'Read-only GitHub-Token eingeben (Fine-grained PAT, Contents: Read) - leer = Abbruch:' -ForegroundColor Yellow
            $sec = Read-Host -AsSecureString
            if ($sec -and $sec.Length -gt 0) {
                $newCred = New-Object System.Management.Automation.PSCredential ('github', $sec)
                $Token = $newCred.GetNetworkCredential().Password.Trim()
                continue
            }
        }
        Write-Host "[FEHLER] GitHub nicht erreichbar: $($_.Exception.Message)" -ForegroundColor Red
        Read-Host 'Enter zum Beenden' | Out-Null
        exit 1
    }
}
if (-not $tree) { Write-Host '[FEHLER] Repo-Inhalt nicht lesbar' -ForegroundColor Red; Read-Host 'Enter zum Beenden' | Out-Null; exit 1 }
Write-Host "Commit: $sha" -ForegroundColor Gray
if ($newCred) {
    try { if (-not (Test-Path -LiteralPath $cfgDir)) { New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null }; $newCred | Export-Clixml -Path $tokFile -Force; Write-Host "GitHub-Token gespeichert (DPAPI): $tokFile" -ForegroundColor Green }
    catch { Write-Host "[WARN] Token nicht gespeichert: $($_.Exception.Message)" -ForegroundColor Yellow }
}
$files = @($tree.tree | Where-Object { $_.type -eq 'blob' })
Write-Host "$($files.Count) Dateien`n" -ForegroundColor Gray

$ok = 0; $fail = 0
foreach ($f in $files) {
    $local = Join-Path $Target ($f.path -replace '/', '\')
    $dir = Split-Path $local -Parent
    try { if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null } } catch { $fail++; continue }
    Write-Host ('  {0,-48} ... ' -f $f.path) -NoNewline
    $tmp = "$local.pulltmp"
    $done = $false; $lastErr = ''
    for ($try = 1; $try -le 5 -and -not $done; $try++) {
        try {
            $enc = (($f.path -split '/') | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
            if ($Token) { Invoke-WebRequest "https://api.github.com/repos/$Owner/$Repo/contents/${enc}?ref=$sha" -Headers (New-GHHeaders 'application/vnd.github.v3.raw') -UseBasicParsing -OutFile $tmp }
            else { Invoke-WebRequest "https://raw.githubusercontent.com/$Owner/$Repo/$sha/$enc" -Headers @{ 'User-Agent' = 'HUMig-Pull' } -UseBasicParsing -OutFile $tmp }
            Move-Item -LiteralPath $tmp -Destination $local -Force
            try { Unblock-File -LiteralPath $local -ErrorAction SilentlyContinue } catch { }
            $done = $true
        } catch { $lastErr = $_.Exception.Message; Start-Sleep -Seconds 1 }
    }
    if ($done) { Write-Host "OK ($((Get-Item -LiteralPath $local -Force).Length) bytes)" -ForegroundColor Green; $ok++ }
    else { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue; Write-Host "FEHLER: $lastErr" -ForegroundColor Red; $fail++ }
}
Write-Host "`n=== Pull fertig === OK: $ok | Fehler: $fail" -ForegroundColor Cyan
if ($NoStart) { exit 0 }
if ($fail -eq 0) {
    $exe = Join-Path $Target 'HUMig.exe'
    $cmd = Join-Path $Target 'Start.cmd'
    if (Test-Path $exe) { Start-Process -FilePath $exe -WorkingDirectory $Target }
    elseif (Test-Path $cmd) { Start-Process -FilePath $cmd -WorkingDirectory $Target -WindowStyle Hidden }
    else { Start-Process powershell.exe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$(Join-Path $Target 'HUMig.ps1')`"" -WorkingDirectory $Target -Verb RunAs }
    exit 0
}
Write-Host 'Fehler aufgetreten - HUMig wird NICHT automatisch gestartet.' -ForegroundColor Red
Read-Host 'Enter zum Beenden' | Out-Null
exit 1
