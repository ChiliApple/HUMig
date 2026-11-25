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

    Vor dem Signieren: Liste der betroffenen Releases mit Rueckfrage, dann Abgleich der geladenen Pruefsummen-Datei mit dem
    lokalen Stand (-LocalRoot, Standard: dieser Programmordner; Version muss gleich sein). Bei Abweichung oder ohne Abgleich
    fragt das Werkzeug je Release nach (s = trotzdem signieren, Enter = auslassen) - nie still.

    Der private Schluessel verlaesst den PC nie. Die Pruefsummen-Datei selbst wird nicht veraendert.
.PARAMETER Version
    Release-Version, z.B. 2.0.55. Ohne Angabe (nur mit -UploadToken): alle Releases mit Pruefsumme, die noch nicht signiert sind.
.PARAMETER Thumbprint
    Fingerabdruck des Signatur-Zertifikats. Standard: wie in HUMig eingestellt (Einstellungen > Update).
.PARAMETER LocalRoot
    Programmordner mit genau der Version des Releases (z.B. die getestete Installation) fuer den Abgleich. Standard: der
    Programmordner, in dem dieses Werkzeug liegt.
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
    [string]$LocalRoot = '',
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
if (-not $LocalRoot) { $LocalRoot = $root }
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

$cert = Get-HMSigningCert $Thumbprint
if (-not $cert) { throw "Signatur-Zertifikat '$Thumbprint' mit privatem Schluessel ist auf diesem PC nicht vorhanden (CurrentUser\My) oder abgelaufen." }
Write-Host "Zertifikat: $($cert.Subject)  ($($cert.Thumbprint), gueltig bis $($cert.NotAfter.ToString('dd.MM.yyyy')))" -ForegroundColor Cyan

if ($UploadToken) {
    $all = @(Get-HMReleases $Owner $Repo $UploadToken)
    if ($Version) {
        $rel = @($all | Where-Object { $_.Version -eq (ConvertTo-HMVersion $Version) })[0]
        if (-not $rel) { throw "Release $Version nicht gefunden ($Owner/$Repo)." }
        $tags = @($rel.Tag)
    } else { $tags = @($all | Where-Object { $_.ManifestUrl -and -not $_.SignatureUrl } | ForEach-Object { $_.Tag }) }
    if (-not $tags.Count) { Write-Host 'Nichts zu signieren - alle Releases mit Pruefsumme sind signiert.' -ForegroundColor Green; exit 0 }
    # zuerst zeigen, welche Releases betroffen sind
    Write-Host "Zu signieren: $($tags -join ', ')" -ForegroundColor Cyan
    Write-Host "Lokaler Stand fuer den Abgleich: $LocalRoot" -ForegroundColor Gray
    if ("$((Read-Host 'Diese Releases signieren? (j/N)'))".Trim() -notmatch '^[jJyY]') { Write-Host 'Abgebrochen - nichts signiert.' -ForegroundColor Yellow; exit 1 }
    $res = @(Invoke-HMReleaseSigning $Owner $Repo $cert.Thumbprint $UploadToken $tags -LocalRoot $LocalRoot -OnMismatch Ask)
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
$why = Test-HMManifestRelease ([System.Text.Encoding]::UTF8.GetString($man)) $rel.Version
if ($why) { throw "Pruefsummen-Datei passt nicht zum Release: $why" }
# Abgleich mit dem lokalen Stand - bei Abweichung oder ohne Abgleich nachfragen
$cmp = Compare-HMReleaseManifest ([System.Text.Encoding]::UTF8.GetString($man)) $rel.Version $LocalRoot
if ($cmp.State -eq 'gleich') { Write-Host "Abgleich: $($cmp.Text)" -ForegroundColor Green }
elseif (-not (Confirm-HMSignMismatch $rel.Tag $cmp 'Ask')) { Write-Host "Nicht signiert: $($cmp.Text)" -ForegroundColor Yellow; exit 1 }
$sig = New-HMManifestSignature $man $cert
$why = Test-HMManifestSignature $man $sig $cert.Thumbprint
if ($why) { throw "Signatur-Pruefung fehlgeschlagen: $why" }
$sigFile = Join-Path $OutDir $script:HMSignatureName
[System.IO.File]::WriteAllBytes($sigFile, $sig)
Write-Host "Signatur erstellt und geprueft: $sigFile" -ForegroundColor Green
Write-Host "Jetzt auf GitHub: Releases > $($rel.Tag) > Bearbeiten > die Datei $($script:HMSignatureName) anhaengen > Speichern." -ForegroundColor Yellow
