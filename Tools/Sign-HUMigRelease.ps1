#Requires -Version 5.1
<#
.SYNOPSIS
    HUMig-Release signieren (Herausgeber) - Kommandozeilen-Variante von HUMig: Rechtsklick auf "Update" > "Release signieren".
.DESCRIPTION
    1. Laedt HUMig-files.sha256 des Releases (SHA256 aller Dateien, wird von den automatischen Tests auf GitHub erstellt).
    2. Signiert sie mit dem Signatur-Zertifikat aus "Eigene Zertifikate" (CurrentUser\My, mit privatem Schluessel)
       -> HUMig-files.sha256.p7s (PKCS#7/CMS, abgetrennte Signatur) und prueft die Signatur.
    3. Mit -UploadToken: haengt die Signatur an das Release. Ohne: Datei liegt in -OutDir und wird auf GitHub
       (Releases > Version > Bearbeiten) von Hand angehaengt.

    Der private Schluessel verlaesst den PC nie. Die Pruefsummen-Datei selbst wird nicht veraendert.
.PARAMETER Version
    Release-Version, z.B. 2.0.55. Ohne Angabe (nur mit -UploadToken): alle Releases mit Pruefsumme, die noch nicht signiert sind.
.PARAMETER Thumbprint
    Fingerabdruck des Signatur-Zertifikats. Standard: wie in HUMig eingestellt (Einstellungen > Update).
.PARAMETER UploadToken
    GitHub-Token mit Schreibrecht (Fine-grained PAT, Contents: Read and write) - zum Hochladen.
.NOTES
    Aufruf: powershell -ExecutionPolicy Bypass -File Tools\Sign-HUMigRelease.ps1 -Version 2.0.55 -UploadToken <token>
    Zielmaschine: PC des Herausgebers (dort liegt das Signatur-Zertifikat mit privatem Schluessel).
#>
param(
    [string]$Version = '',
    [string]$Thumbprint = '',
    [string]$Owner = '',
    [string]$Repo = '',
    [string]$OutDir = '',
    [string]$UploadToken = ''
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'Functions\Core-Update.ps1')
$cfg = Get-HMUpdateConfig (Join-Path $root 'Config')
if (-not $Owner) { $Owner = $cfg.Owner }
if (-not $Repo) { $Repo = $cfg.Repo }
if (-not $Thumbprint) { $Thumbprint = $cfg.SignerThumbprint }
if (-not $Thumbprint) { $Thumbprint = Get-HMDefaultSigner $Owner $Repo }
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

$cert = Get-HMSigningCert $Thumbprint
if (-not $cert) { throw "Signatur-Zertifikat '$Thumbprint' mit privatem Schluessel ist auf diesem PC nicht vorhanden (CurrentUser\My) oder abgelaufen." }
Write-Host "Zertifikat: $($cert.Subject)  ($($cert.Thumbprint), gueltig bis $($cert.NotAfter.ToString('dd.MM.yyyy')))" -ForegroundColor Cyan

if ($UploadToken) {
    $tags = @()
    if ($Version) {
        $rel = @(Get-HMReleases $Owner $Repo $UploadToken | Where-Object { $_.Version -eq (ConvertTo-HMVersion $Version) })[0]
        if (-not $rel) { throw "Release $Version nicht gefunden ($Owner/$Repo)." }
        $tags = @($rel.Tag)
    }
    $res = @(Invoke-HMReleaseSigning $Owner $Repo $cert.Thumbprint $UploadToken $tags)
    if (-not $res.Count) { Write-Host 'Nichts zu signieren - alle Releases mit Pruefsumme sind signiert.' -ForegroundColor Green }
    foreach ($x in $res) { Write-Host "$($x.Tag): $($x.Text)" -ForegroundColor $(if ($x.Ok) { 'Green' } else { 'Red' }) }
    if (@($res | Where-Object { -not $_.Ok }).Count) { exit 1 }
    exit 0
}

# ohne Token: nur Datei erstellen
if (-not $Version) { throw 'Ohne -UploadToken bitte -Version angeben.' }
if (-not $OutDir) { $OutDir = Join-Path $env:TEMP 'HUMig-Signatur' }
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$rel = @(Get-HMReleases $Owner $Repo '' | Where-Object { $_.Version -eq (ConvertTo-HMVersion $Version) })[0]
if (-not $rel) { throw "Release $Version nicht gefunden ($Owner/$Repo)." }
if (-not $rel.ManifestUrl) { throw "Release $($rel.Tag) hat noch keine HUMig-files.sha256 (automatische Tests noch nicht fertig oder fehlgeschlagen)." }
$man = Get-HMReleaseAsset $rel.ManifestUrl $rel.ManifestApi ''
$sig = New-HMManifestSignature $man $cert
$why = Test-HMManifestSignature $man $sig $cert.Thumbprint
if ($why) { throw "Signatur-Pruefung fehlgeschlagen: $why" }
$sigFile = Join-Path $OutDir $script:HMSignatureName
[System.IO.File]::WriteAllBytes($sigFile, $sig)
Write-Host "Signatur erstellt und geprueft: $sigFile" -ForegroundColor Green
Write-Host "Jetzt auf GitHub: Releases > $($rel.Tag) > Bearbeiten > die Datei $($script:HMSignatureName) anhaengen > Speichern." -ForegroundColor Yellow
