#Requires -Version 5.1
<#
.SYNOPSIS
    HUMig-Release signieren (in Vorbereitung) - signiert die Pruefsummen-Datei eines Releases mit dem eigenen Code-Signatur-Zertifikat.
.DESCRIPTION
    1. Laedt HUMig-files.sha256 des Releases (SHA256 aller Dateien, wird von den automatischen Tests auf GitHub erstellt).
    2. Signiert sie mit einem Zertifikat aus "Eigene Zertifikate" (CurrentUser\My) mit privatem Schluessel -> HUMig-files.sha256.p7s
       (PKCS#7/CMS, abgetrennte Signatur).
    3. Prueft die Signatur und zeigt den Fingerabdruck, der in HUMig unter Einstellungen > Update eingetragen wird.
    4. Optional (-UploadToken): laedt die Signatur als Datei zum Release hoch. Sonst: auf GitHub > Releases > Version > Bearbeiten
       die Datei HUMig-files.sha256.p7s anhaengen.

    Der private Schluessel verlaesst den PC nie. Die Pruefsummen-Datei selbst wird nicht veraendert.
.PARAMETER Version
    Release-Version, z.B. 2.0.53
.PARAMETER Thumbprint
    Fingerabdruck des Code-Signatur-Zertifikats. Ohne Angabe: das einzige passende Zertifikat in CurrentUser\My.
.PARAMETER UploadToken
    GitHub-Token mit Schreibrecht (Contents: Read and write) - nur fuer das automatische Hochladen.
.NOTES
    Aufruf: powershell -ExecutionPolicy Bypass -File Tools\Sign-HUMigRelease.ps1 -Version 2.0.53
    Zielmaschine: PC des Administrators mit dem Code-Signatur-Zertifikat (z.B. von der eigenen Zertifizierungsstelle).
#>
param(
    [Parameter(Mandatory)][string]$Version,
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
if (-not $OutDir) { $OutDir = Join-Path $env:TEMP 'HUMig-Signatur' }
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
Add-Type -AssemblyName System.Security

# Zertifikat
$certs = @(Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date) -and @($_.EnhancedKeyUsageList | Where-Object { "$($_.ObjectId)" -eq '1.3.6.1.5.5.7.3.3' }).Count })
if ($Thumbprint) {
    $tp = ($Thumbprint -replace '[^0-9A-Fa-f]', '').ToUpper()
    $cert = @(Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Thumbprint -eq $tp -and $_.HasPrivateKey })[0]
    if (-not $cert) { throw "Zertifikat $tp mit privatem Schluessel nicht in CurrentUser\My gefunden." }
} elseif ($certs.Count -eq 1) { $cert = $certs[0] }
elseif (-not $certs.Count) { throw 'Kein gueltiges Code-Signatur-Zertifikat (Zweck "Codesignatur") mit privatem Schluessel in CurrentUser\My gefunden.' }
else {
    $certs | ForEach-Object { Write-Host ("  {0}  {1}  bis {2:dd.MM.yyyy}" -f $_.Thumbprint, $_.Subject, $_.NotAfter) }
    throw 'Mehrere Code-Signatur-Zertifikate - mit -Thumbprint eines auswaehlen.'
}
Write-Host "Zertifikat: $($cert.Subject)  ($($cert.Thumbprint), gueltig bis $($cert.NotAfter.ToString('dd.MM.yyyy')))" -ForegroundColor Cyan

# Release + Pruefsummen-Datei
$rel = @(Get-HMReleases $Owner $Repo $UploadToken | Where-Object { $_.Version -eq (ConvertTo-HMVersion $Version) })[0]
if (-not $rel) { throw "Release $Version nicht gefunden ($Owner/$Repo)." }
if (-not $rel.ManifestUrl) { throw "Release $($rel.Tag) hat noch keine HUMig-files.sha256 (automatische Tests noch nicht fertig oder fehlgeschlagen)." }
$man = Get-HMReleaseAsset $rel.ManifestUrl $rel.ManifestApi $UploadToken
$manFile = Join-Path $OutDir $script:HMManifestName
[System.IO.File]::WriteAllBytes($manFile, $man)
Write-Host "Pruefsummen-Datei: $((ConvertFrom-HMManifest ([System.Text.Encoding]::UTF8.GetString($man))).Count) Eintraege" -ForegroundColor Gray

# Signieren (abgetrennte CMS-Signatur)
$ci = New-Object System.Security.Cryptography.Pkcs.ContentInfo -ArgumentList (, [byte[]]$man)
$cms = New-Object System.Security.Cryptography.Pkcs.SignedCms -ArgumentList $ci, $true
$signer = New-Object System.Security.Cryptography.Pkcs.CmsSigner -ArgumentList $cert
$signer.IncludeOption = [System.Security.Cryptography.X509Certificates.X509IncludeOption]::EndCertOnly
$cms.ComputeSignature($signer, $false)
$sig = $cms.Encode()
$sigFile = Join-Path $OutDir $script:HMSignatureName
[System.IO.File]::WriteAllBytes($sigFile, $sig)
$why = Test-HMManifestSignature $man $sig $cert.Thumbprint
if ($why) { throw "Signatur-Pruefung fehlgeschlagen: $why" }
Write-Host "Signatur erstellt und geprueft: $sigFile" -ForegroundColor Green

if ($UploadToken) {
    $h = @{ Authorization = "token $UploadToken"; Accept = 'application/vnd.github+json'; 'User-Agent' = 'HUMig' }
    $id = (Invoke-RestMethod "https://api.github.com/repos/$Owner/$Repo/releases/tags/$($rel.Tag)" -Headers $h -UseBasicParsing).id
    $old = @((Invoke-RestMethod "https://api.github.com/repos/$Owner/$Repo/releases/$id/assets" -Headers $h -UseBasicParsing) | Where-Object { $_.name -eq $script:HMSignatureName })
    foreach ($o in $old) { Invoke-RestMethod "https://api.github.com/repos/$Owner/$Repo/releases/assets/$($o.id)" -Method Delete -Headers $h -UseBasicParsing | Out-Null }
    Invoke-RestMethod "https://uploads.github.com/repos/$Owner/$Repo/releases/$id/assets?name=$($script:HMSignatureName)" -Method Post -Headers $h -ContentType 'application/octet-stream' -InFile $sigFile -UseBasicParsing | Out-Null
    Write-Host "Signatur zum Release $($rel.Tag) hochgeladen." -ForegroundColor Green
} else {
    Write-Host "`nJetzt auf GitHub: Releases > $($rel.Tag) > Bearbeiten > die Datei $($script:HMSignatureName) anhaengen > Speichern." -ForegroundColor Yellow
}
Write-Host "`nIn HUMig (Einstellungen > Update) als Fingerabdruck eintragen:  $($cert.Thumbprint)" -ForegroundColor Cyan
