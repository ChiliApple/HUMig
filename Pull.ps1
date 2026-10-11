#Requires -Version 5.1
<#
.SYNOPSIS
    HUMig Pull - laedt eine HUMig-Version von GitHub (Release), prueft sie und startet das Tool neu.
.DESCRIPTION
    Zielordner:
      1. -Target angegeben                          -> gewinnt immer
      2. Pull.ps1 liegt in einer HUMig-Installation -> Update an Ort und Stelle (USB-Laufwerk, Desktop, Share ...)
      3. Pull.ps1 liegt allein                      -> $env:USERPROFILE\Desktop\HUMig

    Welche Version:
      -Version 2.0.53     -> genau diese Version (auch aelter = "Vorversion")
      sonst Kanal         -> -Channel oder Config\update.json "Channel": Stable (freigegebene Releases, Standard) / Test (auch Vorab-Releases)
      -Branch / UseBranch -> Entwicklungsstand eines Branches statt Release (ohne Pruefsumme, nur ohne Signaturpflicht)

    Sicherheit:
      - jedes Release enthaelt HUMig-files.sha256 (SHA256 aller Dateien, erstellt von den automatischen Tests auf GitHub)
      - zuerst werden ALLE Dateien geladen und geprueft, erst dann ersetzt - bei einer Abweichung bleibt alles unveraendert
      - Signatur: nur Releases mit gueltiger Signatur HUMig-files.sha256.p7s des Herausgeber-Zertifikats werden angenommen
        (offizielle Quelle: Fingerabdruck eingebaut; eigene Quelle: Config\update.json "SignerThumbprint").
        Abschalten nur bewusst mit Config\update.json "AllowUnsigned": true (Einstellungen > Update).

    Lokale Daten bleiben unangetastet: BACKUPS\, Logs\, BIN\USMT\, Softwareverteilung\, Treiberverteilung\, HUMig.exe, Config\settings.json, exceptions.json, modules.json, update.json.
    Token nur fuer private Repos: Umgebungsvariable HUMIG_GITHUB_TOKEN oder Config\GitHubToken_<DOMAIN>_<USER>.xml (DPAPI).
.NOTES
    Manuell: powershell -ExecutionPolicy Bypass -File Pull.ps1 [-Version 2.0.53] [-Channel Test]
    Zielmaschine: der PC / das Laufwerk, auf dem HUMig liegt.
#>
param(
    [string]$Target,
    [int]$WaitPid = 0,
    [switch]$NoStart,
    [string]$Owner,
    [string]$Repo,
    [string]$Branch,
    [ValidateSet('', 'Stable', 'Test')][string]$Channel = '',
    [string]$Version = '',
    [switch]$NonInteractive
)
$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

#region HMUpdateLib
# Gemeinsame Update-Funktionen - identisch in Pull.ps1 und Functions\Core-Update.ps1 (die automatischen Tests pruefen das)
$script:HMManifestName  = 'HUMig-files.sha256'
$script:HMSignatureName = 'HUMig-files.sha256.p7s'
# Offizielle Update-Quelle und Fingerabdruck des Zertifikats, mit dem ihre Releases signiert werden (oeffentlich, kein Geheimnis)
$script:HMDefaultOwner  = 'ChiliApple'
$script:HMDefaultRepo   = 'HUMig'
$script:HMDefaultSigner = '1B669AE240DA1A91043C4576763D9F8E0BF762FA'
$script:HMUserAgent     = 'HUMig'

function Get-HMDefaultSigner([string]$Owner, [string]$Repo) {
    if ($Owner -eq $script:HMDefaultOwner -and $Repo -eq $script:HMDefaultRepo) { return $script:HMDefaultSigner }
    return ''
}
# Update-Einstellungen aus Config\update.json (fehlt die Datei: offizielle Quelle, Kanal Stabil, nur signierte Releases)
#   Signaturpflicht gilt, sobald ein Fingerabdruck bekannt ist (offizielle Quelle: eingebaut) - ausser "AllowUnsigned": true.
#   Mit Signaturpflicht gibt es keinen Branch-Modus (ein Branch-Stand ist nicht signiert).
function Get-HMUpdateConfig([string]$ConfigDir) {
    $c = [ordered]@{ Owner = $script:HMDefaultOwner; Repo = $script:HMDefaultRepo; Branch = 'main'; UseBranch = $false; Channel = 'Stable'; AllowUnsigned = $false; SignerThumbprint = ''; DefaultSigner = $false; RequireSignature = $false }
    $f = Join-Path $ConfigDir 'update.json'
    if (Test-Path -LiteralPath $f) {
        try {
            $u = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($k in @('Owner', 'Repo', 'Branch', 'SignerThumbprint')) { if ($u.PSObject.Properties[$k] -and "$($u.$k)".Trim()) { $c[$k] = "$($u.$k)".Trim() } }
            if ($u.PSObject.Properties['Channel'] -and "$($u.Channel)" -match '^(Stable|Test)$') { $c.Channel = "$($u.Channel)" }
            if ($u.PSObject.Properties['UseBranch']) { $c.UseBranch = ($u.UseBranch -eq $true) }
            if ($u.PSObject.Properties['AllowUnsigned']) { $c.AllowUnsigned = ($u.AllowUnsigned -eq $true) }
        } catch { }
    }
    $c.SignerThumbprint = ("$($c.SignerThumbprint)" -replace '[^0-9A-Fa-f]', '').ToUpper()
    if (-not $c.SignerThumbprint) {
        $d = Get-HMDefaultSigner $c.Owner $c.Repo
        if ($d) { $c.SignerThumbprint = $d; $c.DefaultSigner = $true }
    }
    $c.RequireSignature = ([bool]$c.SignerThumbprint -and -not $c.AllowUnsigned)
    if ($c.RequireSignature) { $c.UseBranch = $false }
    return [pscustomobject]$c
}
function ConvertTo-HMVersion([string]$Tag) {
    $v = "$Tag".Trim() -replace '^[vV]', ''
    $o = $null
    if ($v -match '^\d+(\.\d+){1,3}$' -and [Version]::TryParse($v, [ref]$o)) { return $o }
    return $null
}
# GitHub-Releases -> Liste (neueste zuerst): Version, Tag, Prerelease (= Kanal Test), Datum, Notizen, Pruefsummen-/Signatur-Datei
function ConvertTo-HMReleaseList($Raw) {
    $out = @()
    foreach ($r in @($Raw)) {
        if (-not $r -or $r.draft -eq $true) { continue }
        $ver = ConvertTo-HMVersion "$($r.tag_name)"
        if (-not $ver) { continue }
        $assets = @($r.assets | Where-Object { $_ })
        $man = @($assets | Where-Object { "$($_.name)" -eq $script:HMManifestName })[0]
        $sig = @($assets | Where-Object { "$($_.name)" -eq $script:HMSignatureName })[0]
        $d = ''
        try { $d = ([datetime]$r.published_at).ToLocalTime().ToString('dd.MM.yyyy HH:mm') } catch { $d = "$($r.published_at)" }
        $out += [pscustomobject]@{
            Version = $ver; Tag = "$($r.tag_name)"; Prerelease = ($r.prerelease -eq $true); Date = $d; Notes = "$($r.body)"
            ManifestUrl = $(if ($man) { "$($man.browser_download_url)" } else { '' }); ManifestApi = $(if ($man) { "$($man.url)" } else { '' })
            SignatureUrl = $(if ($sig) { "$($sig.browser_download_url)" } else { '' }); SignatureApi = $(if ($sig) { "$($sig.url)" } else { '' })
        }
    }
    return @($out | Sort-Object Version -Descending)
}
function Get-HMReleases([string]$Owner, [string]$Repo, [string]$Token) {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    $h = @{ Accept = 'application/vnd.github+json'; 'User-Agent' = $script:HMUserAgent }
    if ($Token) { $h.Authorization = "token $Token" }
    # GitHub liefert die Liste mit "Cache-Control: max-age=60" - Proxys/Zwischenspeicher wuerden z.B. eine gerade
    # angehaengte Signatur bis zu 1 Minute nicht zeigen. Darum: no-cache + eindeutige Adresse je Abfrage
    $h['Cache-Control'] = 'no-cache'
    $raw = Invoke-RestMethod "https://api.github.com/repos/$Owner/$Repo/releases?per_page=100&nocache=$([DateTime]::UtcNow.Ticks)" -Headers $h -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
    return @(ConvertTo-HMReleaseList $raw)
}
# Kanal Stabil = nur freigegebene Releases, Test = auch Vorab-Releases; jeweils die hoechste Version
# -SignedOnly: nur Releases mit Pruefsummen- UND Signatur-Datei (bei Signaturpflicht)
function Select-HMRelease($Releases, [string]$Channel, [switch]$SignedOnly) {
    $l = @($Releases | Where-Object { $_ -and $_.Version })
    if ($Channel -ne 'Test') { $l = @($l | Where-Object { -not $_.Prerelease }) }
    if ($SignedOnly) { $l = @($l | Where-Object { $_.ManifestUrl -and $_.SignatureUrl }) }
    return (@($l | Sort-Object Version -Descending) | Select-Object -First 1)
}
# Release-Datei (Pruefsummen/Signatur) als Bytes laden - mit Token ueber die API (private Repos).
# Ausweichweg: liefert der Download-Link von github.com einen Fehler (z.B. 503), wird dieselbe Datei ueber die API geladen
# (gleicher Inhalt; die Echtheit sichert ohnehin die Signatur/Pruefsumme)
function Get-HMReleaseAsset([string]$Url, [string]$ApiUrl, [string]$Token) {
    $tries = @()
    if ($Token -and $ApiUrl) { $tries += , @($ApiUrl, @{ Accept = 'application/octet-stream'; 'User-Agent' = $script:HMUserAgent; Authorization = "token $Token" }) }
    if ($Url) { $tries += , @($Url, @{ 'User-Agent' = $script:HMUserAgent }) }
    if ($ApiUrl) { $tries += , @($ApiUrl, @{ Accept = 'application/octet-stream'; 'User-Agent' = $script:HMUserAgent }) }
    $last = $null
    foreach ($t in $tries) {
        $tmp = [System.IO.Path]::GetTempFileName()
        try {
            Invoke-WebRequest $t[0] -Headers $t[1] -UseBasicParsing -TimeoutSec 60 -OutFile $tmp -ErrorAction Stop
            return ,([System.IO.File]::ReadAllBytes($tmp))
        } catch { $last = $_ }
        finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
    if ($last) { throw $last }
    throw 'keine Download-Adresse'
}
# Pruefsummen-Datei (sha256sum-Format: "<hash>  <pfad>") -> Hashtable Pfad -> Hash (klein). Andere Zeilen (z.B. die
# Versionszeile "# HUMig-Release <Tag>") werden ignoriert.
function ConvertFrom-HMManifest([string]$Text) {
    $m = @{}
    foreach ($ln in ("$Text" -split "`r?`n")) {
        if ($ln -match '^([0-9a-fA-F]{64}) [ \*](.+?)\s*$') { $m[$Matches[2]] = $Matches[1].ToLower() }
    }
    return $m
}
# Versionszeile der (signierten) Pruefsummen-Datei: "# HUMig-Release <Tag>" in der ersten Zeile.
# Verhindert, dass die signierte Pruefsummen-Datei eines anderen Releases (mit dessen Dateien) untergeschoben wird.
# Rueckgabe: '' = passt, sonst Grund. Ohne Versionszeile nur fuer Releases vor 2.0.121 zulaessig.
function Test-HMManifestRelease([string]$Text, $Version) {
    $want = ConvertTo-HMVersion "$Version"
    if (-not $want) { return "Version unbekannt ($Version)" }
    $first = @("$Text".TrimStart([char]0xFEFF) -split "`r?`n")[0]
    if ($first -match '^#\s*HUMig-Release\s+(\S+)\s*$') {
        $tag = $Matches[1]
        $have = ConvertTo-HMVersion $tag
        if (-not $have -or $have -ne $want) { return "Signierte Pruefsummen-Datei gehoert zu $tag, nicht zu $want - Update abgelehnt." }
        return ''
    }
    if ($want -ge [Version]'2.0.121') { return "Signierte Pruefsummen-Datei ohne Versionszeile (Pflicht ab 2.0.121) - Update abgelehnt." }
    return ''
}
function Get-HMFileSha256([string]$Path) {
    $s = [System.Security.Cryptography.SHA256]::Create()
    $fs = [System.IO.File]::OpenRead($Path)
    try { return (-join ($s.ComputeHash($fs) | ForEach-Object { $_.ToString('x2') })) } finally { $fs.Dispose(); $s.Dispose() }
}
# Signatur (PKCS#7/CMS, abgetrennt) der Pruefsummen-Datei pruefen. Rueckgabe: '' = gueltig, sonst Grund.
# Geprueft werden die Signatur selbst und der Fingerabdruck des Zertifikats (fest eingestellt) - keine Online-Sperrlistenpruefung.
function Test-HMManifestSignature([byte[]]$Manifest, [byte[]]$Signature, [string]$Thumbprint) {
    $want = ("$Thumbprint" -replace '[^0-9A-Fa-f]', '').ToUpper()
    if (-not $want) { return 'kein Fingerabdruck (Thumbprint) des Signatur-Zertifikats eingestellt' }
    if (-not $Signature -or -not $Signature.Length) { return 'keine Signatur-Datei im Release' }
    try {
        try { Add-Type -AssemblyName System.Security -ErrorAction Stop } catch { }
        $ci = New-Object System.Security.Cryptography.Pkcs.ContentInfo -ArgumentList (, [byte[]]$Manifest)
        $cms = New-Object System.Security.Cryptography.Pkcs.SignedCms -ArgumentList $ci, $true
        $cms.Decode($Signature)
        $cms.CheckSignature($true)
        $tps = @(foreach ($si in $cms.SignerInfos) { if ($si.Certificate) { "$($si.Certificate.Thumbprint)".ToUpper() } })
        if (-not $tps.Count) { return 'Signatur ohne Zertifikat' }
        if ($tps -notcontains $want) { return "signiert mit einem anderen Zertifikat ($($tps -join ', '))" }
        return ''
    } catch { return "Signatur ungueltig: $($_.Exception.Message)" }
}
#endregion HMUpdateLib

# Ordnerrechte des Programmordners (gleiche Absicherung wie HUMig beim Start) - nur eingebaute Befehle
#region HMAppAcl
# Ordnerrechte des Programmordners - identisch in HUMig.ps1 und Pull.ps1 (die automatischen Tests pruefen das)
# Darf jemand ausser Administratoren/SYSTEM/TrustedInstaller/Ersteller-Besitzer hier schreiben oder anlegen?
# Rueckgabe: '' = sicher, sonst Text (Konto: Recht). Gleiche Regeln wie Get-HMWritableByNonAdmins (Migration-Engine).
# Mitglieder der lokalen Gruppe Administratoren (SIDs) - einmal je Lauf abgefragt (auch ein Fehler wird gemerkt:
# dann zaehlt ein einzelnes Konto wie bisher als Nicht-Administrator und wird gemeldet)
function Get-HMAppAdminSids {
    if ($null -eq $script:HMAppAdmSids) {
        $c = @{ Ok = $false; M = @() }
        try { $c = @{ Ok = $true; M = @(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop | ForEach-Object { "$($_.SID)" }) } } catch { }
        $script:HMAppAdmSids = $c
    }
    return @($script:HMAppAdmSids.M)
}
function Get-HMAppWritable([string]$Path) {
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    $safe = @('S-1-5-18', 'S-1-5-32-544', 'S-1-3-0', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    $w = [System.Security.AccessControl.FileSystemRights]'WriteData, AppendData, WriteExtendedAttributes, WriteAttributes, Delete, ChangePermissions, TakeOwnership'
    $out = @()
    foreach ($r in @($acl.Access)) {
        if ("$($r.AccessControlType)" -ne 'Allow') { continue }
        if (([int]$r.FileSystemRights -band [int]$w) -eq 0) { continue }
        $sid = ''
        try { $sid = $r.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value } catch { $sid = "$($r.IdentityReference)" }
        if ($safe -contains $sid) { continue }
        # einzelnes Konto, das selbst Administrator ist (z.B. der Installierende), ist unkritisch
        try { $nt = $r.IdentityReference.Translate([System.Security.Principal.NTAccount]).Value } catch { $nt = "$($r.IdentityReference)" }
        if ($sid -like 'S-1-5-21-*' -and $sid -notmatch '-(513|515|545)$') {
            if (@(Get-HMAppAdminSids) -contains $sid) { continue }
        }
        $out += "$nt`: $($r.FileSystemRights)"
    }
    return (@($out | Select-Object -Unique) -join '; ')
}
# Wurzel und die Ordner, deren Inhalt HUMig als Administrator laedt/liest/startet (Config, Functions, XAML, BIN, Tools).
# Logs und Backup-Ordner sind absichtlich fuer den Benutzer-Modus beschreibbar und werden nicht geprueft.
# Rueckgabe: '' = sicher, sonst je Ordner eine Zeile "<Ordner>: <Konto: Recht>". Wurzel nicht lesbar (z.B. FAT/exFAT): Fehler.
function Get-HMAppAclFindings([string]$Root) {
    $rt = $Root.TrimEnd('\')
    $out = @()
    $w = Get-HMAppWritable $rt
    if ($w) { $out += "${rt}: $w" }
    foreach ($n in @('Config', 'Functions', 'XAML', 'BIN', 'Tools')) {
        $p = Join-Path $rt $n
        if (-not (Test-Path -LiteralPath $p -PathType Container)) { continue }
        $w = ''
        try { $w = Get-HMAppWritable $p } catch { $w = "Rechte nicht lesbar ($($_.Exception.Message))" }
        if ($w) { $out += "${p}: $w" }
    }
    return ($out -join "`n")
}
# "AclCheckOff" in Config\settings.json (nie mehr fragen) gilt nur, wenn die Datei Administratoren, SYSTEM oder dem
# angemeldeten Konto gehoert UND Nicht-Administratoren sie nicht aendern duerfen - sonst koennte jemand, der dort schreiben
# kann, die Pruefung selbst abschalten
function Test-HMAclCheckOff([string]$ConfigDir) {
    $f = Join-Path $ConfigDir 'settings.json'
    try {
        if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { return $false }
        $own = "$((Get-Acl -LiteralPath $f -ErrorAction Stop).GetOwner([System.Security.Principal.SecurityIdentifier]).Value)"
        $me = ''
        try { $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch { }
        if (-not $own -or @(@('S-1-5-32-544', 'S-1-5-18', $me) | Where-Object { $_ }) -notcontains $own) { return $false }
        if (Get-HMAppWritable $f) { return $false }
        $j = Get-Content -LiteralPath $f -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
        return [bool]($j -and $j.PSObject.Properties['AclCheckOff'] -and [bool]$j.AclCheckOff)
    } catch { return $false }
}
# Backup-Ordner laut Einstellungen (wie Get-BackupRoot: settings.json ueber settings.default.json, aktives Standort-Profil)
function Get-HMAppBackupRoot([string]$Root) {
    $br = ''; $ap = ''; $pr = @()
    foreach ($n in @('settings.default.json', 'settings.json')) {
        $f = Join-Path $Root "Config\$n"
        if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { continue }
        try {
            $j = Get-Content -LiteralPath $f -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
            if (-not $j) { continue }
            if ($j.PSObject.Properties['BackupRoot'] -and $null -ne $j.BackupRoot) { $br = "$($j.BackupRoot)".Trim() }
            if ($j.PSObject.Properties['ActiveProfile'] -and $null -ne $j.ActiveProfile) { $ap = "$($j.ActiveProfile)".Trim() }
            if ($j.PSObject.Properties['Profiles'] -and $null -ne $j.Profiles) { $pr = @($j.Profiles) }
        } catch { }
    }
    if ($ap) {
        $p = @($pr | Where-Object { $_ -and "$($_.Name)" -eq $ap })[0]
        if ($p -and "$($p.BackupRoot)".Trim()) { $br = "$($p.BackupRoot)".Trim() }
    }
    if (-not $br) { $br = Join-Path $Root 'BACKUPS' }
    return $br
}
# Backup-Ordner schon "privat"? (Vererbung aus, Benutzer-Gruppen ohne vererbbare Rechte = sehen fremde Backups nicht)
function Test-HMAppBackupPrivate([string]$Dir) {
    try {
        $a = Get-Acl -LiteralPath $Dir -ErrorAction Stop
        if (-not $a.AreAccessRulesProtected) { return $false }
        foreach ($r in @($a.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]))) {
            if ("$($r.AccessControlType)" -ne 'Allow') { continue }
            if (@('S-1-5-32-545', 'S-1-1-0', 'S-1-5-11', 'S-1-5-4') -contains $r.IdentityReference.Value -and "$($r.InheritanceFlags)" -ne 'None') { return $false }
        }
        return $true
    } catch { return $false }
}
# Absichern: Wurzel Vererbung aus, Administratoren + SYSTEM Vollzugriff, Benutzer Lesen. Code/Einstellungen: nur geerbte Rechte,
# Besitzer Administratoren (ein anderer Besitzer koennte die Rechte selbst wieder aendern).
# Daten-Ordner: Logs (Benutzer legen eigene Dateien an) und Backup-Ordner im Programmordner (Benutzer legen eigene
# Backup-Ordner an und lesen nur diese, Administratoren alle). $BackupDirs: eingestellte Backup-Ordner (werden angelegt).
# -BackupsOnly: nur Schritt 4 (Backup-Ordner privat), Wurzel/Code/Logs bleiben unveraendert (Pull.ps1 nach dem Update).
# Rueckgabe: Meldungen (Text, Level). Wurzel nicht aenderbar: Fehler.
function Protect-HMAppFolder([string]$Root, [string[]]$BackupDirs = @(), [switch]$BackupsOnly) {
    $sep = [System.IO.Path]::DirectorySeparatorChar
    $rt = [System.IO.Path]::GetFullPath($Root).TrimEnd($sep)
    $pre = $rt + $sep
    $msgs = New-Object System.Collections.Generic.List[object]
    $code = @('Config', 'Functions', 'XAML', 'Tools', 'Assets', 'BIN', 'Docs')
    $logs = Join-Path $rt 'Logs'
    # Backup-Ordner: nur innerhalb des Programmordners und nie ein Code-Ordner (Schutz vor manipulierten Einstellungen)
    $bk = New-Object System.Collections.Generic.List[object]
    foreach ($d in @(@($BackupDirs | ForEach-Object { @{ P = "$_"; New = $true } }) + @(@{ P = (Join-Path $rt 'BACKUPS'); New = $false }))) {
        $x = "$($d.P)".Trim()
        if (-not $x) { continue }
        try { $x = [System.IO.Path]::GetFullPath($x).TrimEnd($sep) } catch { continue }
        if (-not $x.StartsWith($pre, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $top = $x.Substring($pre.Length).Split($sep)[0]
        if ($code -contains $top -or $top -ieq 'Logs') { continue }
        if (@($bk | Where-Object { $_.P -ieq $x }).Count) { continue }
        $bk.Add(@{ P = $x; New = $d.New; Top = $top })
    }
    if (-not $BackupsOnly) {
        # 1. Wurzel: Vererbung aus, Administratoren + SYSTEM Vollzugriff, Benutzer Lesen/Ausfuehren, Besitzer Administratoren
        $o1 = & icacls.exe "$rt" /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' 2>&1
        if ($LASTEXITCODE -ne 0) { throw "icacls: $($o1 -join ' ')" }
        $o1 = & icacls.exe "$rt" /setowner '*S-1-5-32-544' /C /Q 2>&1
        if ($LASTEXITCODE -ne 0) { $msgs.Add([pscustomobject]@{ Text = "Besitzer ${rt}: $(@($o1) -join ' ')"; Level = 'Warning' }) }
        # 2. Code und Einstellungen: nur noch die geerbten Rechte (entfernt auch Rechte auf Dateien, die Benutzer angelegt haben),
        #    Besitzer Administratoren. Daten-Ordner werden ausgelassen (grosse Backup-Ordner wuerden sonst lange dauern, kein Code).
        $skip = @(@($bk | ForEach-Object { $_.P.ToLower() }) + $logs.ToLower())
        $nested = @($bk | Where-Object { $_.P -ine (Join-Path $rt $_.Top) } | ForEach-Object { $_.Top.ToLower() })
        foreach ($c in @(Get-ChildItem -LiteralPath $rt -Force -ErrorAction SilentlyContinue)) {
            if ($skip -contains $c.FullName.TrimEnd($sep).ToLower()) { continue }
            $o2 = if ($c.PSIsContainer) { & icacls.exe "$($c.FullName)" /reset /T /C /Q 2>&1 } else { & icacls.exe "$($c.FullName)" /reset /C /Q 2>&1 }
            if ($LASTEXITCODE -ne 0) { $msgs.Add([pscustomobject]@{ Text = "Ordnerrechte $($c.Name): $(@($o2) -join ' ')"; Level = 'Warning' }) }
            # Ordner mit einem Backup-Ordner darin: Besitzer nicht aendern (Benutzer-Backups behalten ihren Besitzer)
            if ($nested -contains $c.Name.ToLower()) { continue }
            $o3 = if ($c.PSIsContainer) { & icacls.exe "$($c.FullName)" /setowner '*S-1-5-32-544' /T /C /Q 2>&1 } else { & icacls.exe "$($c.FullName)" /setowner '*S-1-5-32-544' /C /Q 2>&1 }
            if ($LASTEXITCODE -ne 0) { $msgs.Add([pscustomobject]@{ Text = "Besitzer $($c.Name): $(@($o3) -join ' ')"; Level = 'Warning' }) }
        }
        # 3. Protokolle: Benutzer-Modus legt dort eigene Dateien an (Ersteller-Besitzer), lesen duerfen alle (wie bisher)
        try {
            if (-not (Test-Path -LiteralPath $logs)) { New-Item -ItemType Directory -Path $logs -Force | Out-Null }
            $null = & icacls.exe "$logs" /setowner '*S-1-5-32-544' /C /Q 2>&1
            $o4 = & icacls.exe "$logs" /grant '*S-1-5-32-545:(CI)(AD)' '*S-1-5-32-545:(CI)(WD)' '*S-1-3-0:(OI)(CI)(IO)F' 2>&1
            if ($LASTEXITCODE -ne 0) { $msgs.Add([pscustomobject]@{ Text = "Ordnerrechte ${logs}: $(@($o4) -join ' ')"; Level = 'Warning' }) }
            else { $msgs.Add([pscustomobject]@{ Text = "   Daten-Ordner fuer Benutzer-Modus beschreibbar (nur eigene Dateien): $logs"; Level = 'Info' }) }
        } catch { $msgs.Add([pscustomobject]@{ Text = "Ordnerrechte ${logs}: $($_.Exception.Message)"; Level = 'Warning' }) }
    }
    # 4. Backup-Ordner: Vererbung aus; Benutzer duerfen nur den Ordner selbst auflisten und darin Unterordner anlegen
    #    (ohne Vererbung) - ihre eigenen Backups erreichen sie ueber Ersteller-Besitzer, fremde nicht. Administratoren/SYSTEM alles.
    foreach ($d in $bk) {
        try {
            if (-not (Test-Path -LiteralPath $d.P)) {
                if (-not $d.New) { continue }
                New-Item -ItemType Directory -Path $d.P -Force | Out-Null
            }
            $null = & icacls.exe "$($d.P)" /setowner '*S-1-5-32-544' /C /Q 2>&1
            if (Test-HMAppBackupPrivate $d.P) { $msgs.Add([pscustomobject]@{ Text = "   Backup-Ordner: jeder Benutzer sieht nur seine eigenen Backups (Administratoren alle): $($d.P)"; Level = 'Info' }); continue }
            $o5 = & icacls.exe "$($d.P)" /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-545:(RD,AD,X,RA,REA,RC,S)' '*S-1-3-0:(OI)(CI)(IO)F' 2>&1
            if ($LASTEXITCODE -ne 0) { $msgs.Add([pscustomobject]@{ Text = "Ordnerrechte $($d.P): $(@($o5) -join ' ')"; Level = 'Warning' }); continue }
            foreach ($g in @('*S-1-1-0', '*S-1-5-11', '*S-1-5-4')) { $null = & icacls.exe "$($d.P)" /remove:g $g 2>&1 }
            $msgs.Add([pscustomobject]@{ Text = "   Backup-Ordner: jeder Benutzer sieht nur seine eigenen Backups (Administratoren alle): $($d.P)"; Level = 'Info' })
        } catch { $msgs.Add([pscustomobject]@{ Text = "Ordnerrechte $($d.P): $($_.Exception.Message)"; Level = 'Warning' }) }
    }
    if ($BackupsOnly) { return $msgs }
    $rest = ''
    try { $rest = Get-HMAppAclFindings $rt } catch { $rest = "$($_.Exception.Message)" }
    if ($rest) { $msgs.Add([pscustomobject]@{ Text = "Ordnerrechte: noch beschreibbar fuer $($rest -replace "`n", ' | ')"; Level = 'Warning' }) }
    else { $msgs.Add([pscustomobject]@{ Text = "Ordnerrechte abgesichert: $rt (Administratoren + SYSTEM Vollzugriff, Benutzer nur Lesen)"; Level = 'Success' }) }
    return $msgs
}
#endregion HMAppAcl

function Stop-HMPull([string]$Msg) {
    Write-Host "[FEHLER] $Msg" -ForegroundColor Red
    if (-not $NonInteractive) { Read-Host 'Enter zum Beenden' | Out-Null }
    exit 1
}

if (-not $Target) {
    $here = $PSScriptRoot
    if ($here -and ((Test-Path (Join-Path $here 'HUMig.ps1')) -or (Test-Path (Join-Path $here 'Functions')))) { $Target = $here; $mode = 'Update (an Ort und Stelle)' }
    else { $Target = Join-Path $env:USERPROFILE 'Desktop\HUMig'; $mode = 'Erstinstallation (Desktop)' }
} else { $mode = 'Ziel per -Target' }
$Target = $Target.TrimEnd('\')
# Erstinstallation (noch kein HUMig im Zielordner)? Fuer die Ordnerrechte am Ende (Schritt 7)
$pullFirst = -not (Test-Path -LiteralPath (Join-Path $Target 'HUMig.ps1'))

$cfgDir = Join-Path $Target 'Config'
# abgebrochenes Update (Journal vorhanden): bisherige Dateien aus *.pullold zuruecksetzen
$jr = Join-Path $cfgDir 'pull-journal.json'
if (Test-Path -LiteralPath $jr) {
    Write-Host '[WARN] Letztes Update wurde abgebrochen - stelle bisherige Dateien wieder her...' -ForegroundColor Yellow
    # Erst zuweisen, dann durchlaufen: PS 5.1 gibt ein JSON-Array aus ConvertFrom-Json als EIN Objekt aus -
    # "foreach ($x in @(... | ConvertFrom-Json))" liefe nur einmal mit allen Pfaden zusammen und stellte nichts zurueck
    $jl = $null
    try { $jl = Get-Content -LiteralPath $jr -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { Stop-HMPull "Journal $jr nicht lesbar ($($_.Exception.Message)) - bitte *.pullold im Programmordner pruefen." }
    $jbad = 0
    foreach ($jp in @($jl)) {
        if (-not "$jp") { continue }
        $jo = "$jp.pullold"
        if (Test-Path -LiteralPath $jo) {
            try { Move-Item -LiteralPath $jo -Destination "$jp" -Force -ErrorAction Stop; Write-Host "  zurueckgestellt: $jp" -ForegroundColor DarkGray }
            catch { $jbad++; Write-Host "  [WARN] $($jp): $($_.Exception.Message)" -ForegroundColor Yellow }
        }
        Remove-Item -LiteralPath "$jp.pulltmp" -Force -ErrorAction SilentlyContinue
    }
    # Journal nur loeschen, wenn alles zurueckgestellt ist (sonst bleibt die Start-Sperre bestehen)
    if ($jbad) { Stop-HMPull "$jbad Datei(en) konnten nicht zurueckgestellt werden (gesperrt?) - Programm schliessen und Pull erneut ausfuehren." }
    Remove-Item -LiteralPath $jr -Force -ErrorAction SilentlyContinue
}
$cfg = Get-HMUpdateConfig $cfgDir
if (-not $Owner) { $Owner = $cfg.Owner }
if (-not $Repo)  { $Repo = $cfg.Repo }
# andere Quelle per Parameter: eingebauter Fingerabdruck gilt nur fuer die offizielle Quelle
if ($cfg.DefaultSigner -and ($Owner -ne $cfg.Owner -or $Repo -ne $cfg.Repo)) {
    $cfg.SignerThumbprint = Get-HMDefaultSigner $Owner $Repo
    $cfg.RequireSignature = ([bool]$cfg.SignerThumbprint -and -not $cfg.AllowUnsigned)
}
if ($Branch -and $cfg.RequireSignature) { Stop-HMPull "Branch-Stand ist nicht signiert - nur moeglich, wenn 'Nur signierte Updates' ausgeschaltet ist (Einstellungen > Update)." }
if (-not $Channel) { $Channel = $cfg.Channel }
$useBranch = [bool]$Branch -or ($cfg.UseBranch -and -not $Version)
if (-not $Branch) { $Branch = $cfg.Branch }

$tokFile = Join-Path $cfgDir ('GitHubToken_{0}.xml' -f ("$($env:USERDOMAIN)_$($env:USERNAME)" -replace '[^\w\.\-]', '_'))
$Token = "$env:HUMIG_GITHUB_TOKEN".Trim()
if (-not $Token -and (Test-Path -LiteralPath $tokFile)) {
    try { $c = Import-Clixml -Path $tokFile; if ($c -is [System.Management.Automation.PSCredential]) { $Token = $c.GetNetworkCredential().Password.Trim() } }
    catch { Write-Host '[WARN] Gespeicherter GitHub-Token nicht lesbar (anderer Benutzer?)' -ForegroundColor Yellow }
}

Write-Host '=== HUMig Pull ===' -ForegroundColor Cyan
Write-Host "Zielordner: $Target" -ForegroundColor Gray
Write-Host "Modus:      $mode" -ForegroundColor Gray
Write-Host "Quelle:     $Owner/$Repo$(if ($Token) { ' (mit Token)' })" -ForegroundColor Gray
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
} catch { Stop-HMPull "Kein Schreibzugriff auf '$Target'. PowerShell als Administrator starten." }

function New-GHHeaders([string]$Accept) {
    $h = @{ Accept = $Accept; 'User-Agent' = 'HUMig-Pull' }
    if ($script:Token) { $h['Authorization'] = "token $($script:Token)" }
    return $h
}
$ProgressPreference = 'SilentlyContinue'

# --- 1. Version waehlen (Release) bzw. Branch
$ref = $null; $rel = $null; $manifest = $null; $verified = 'ohne Pruefsumme'; $newCred = $null; $triedNoToken = $false
for ($attempt = 1; $attempt -le 3 -and -not $ref; $attempt++) {
    try {
        if ($useBranch) {
            $r = Invoke-RestMethod "https://api.github.com/repos/$Owner/$Repo/git/refs/heads/$Branch" -Headers (New-GHHeaders 'application/vnd.github.v3+json') -UseBasicParsing
            $ref = "$($r.object.sha)"
        } else {
            $list = @(Get-HMReleases $Owner $Repo $Token)
            if ($Version) {
                $want = ConvertTo-HMVersion $Version
                $rel = @($list | Where-Object { $want -and $_.Version -eq $want })[0]
                if (-not $rel) { Stop-HMPull "Version $Version gibt es nicht als Release ($Owner/$Repo)." }
            } else {
                $rel = Select-HMRelease $list $Channel -SignedOnly:$cfg.RequireSignature
                if (-not $rel) { Stop-HMPull "Kein $(if ($cfg.RequireSignature) { 'signiertes ' })Release im Kanal $(if ($Channel -eq 'Test') { 'Test' } else { 'Stabil' }) gefunden ($Owner/$Repo)." }
            }
            # Tag -> Commit (funktioniert auch bei annotierten Tags)
            $cm = Invoke-RestMethod "https://api.github.com/repos/$Owner/$Repo/commits/$($rel.Tag)" -Headers (New-GHHeaders 'application/vnd.github.v3+json') -UseBasicParsing
            $ref = "$($cm.sha)"
        }
    } catch {
        $code = 0; try { $code = [int]$_.Exception.Response.StatusCode } catch { }
        # Gespeicherter Token abgelaufen/widerrufen, Repo oeffentlich -> einmal ohne Token versuchen
        if ($Token -and -not $newCred -and -not $triedNoToken -and $code -eq 401) {
            Write-Host '[INFO] Token wird abgelehnt (HTTP 401) - versuche ohne Token...' -ForegroundColor Yellow
            $Token = ''; $triedNoToken = $true
            continue
        }
        if (-not $newCred -and -not $NonInteractive -and $code -in 401, 403, 404) {
            Write-Host "[INFO] $Owner/$Repo ist $(if ($Token) { 'mit dem Token' } else { 'ohne Token' }) nicht erreichbar (HTTP $code) - privates Repo?" -ForegroundColor Yellow
            Write-Host 'Read-only GitHub-Token eingeben (Fine-grained PAT, Contents: Read) - leer = Abbruch:' -ForegroundColor Yellow
            $sec = Read-Host -AsSecureString
            if ($sec -and $sec.Length -gt 0) {
                $newCred = New-Object System.Management.Automation.PSCredential ('github', $sec)
                $Token = $newCred.GetNetworkCredential().Password.Trim()
                continue
            }
        }
        Stop-HMPull "GitHub nicht erreichbar: $($_.Exception.Message)"
    }
}
if (-not $ref) { Stop-HMPull 'Version nicht ermittelbar' }
if ($newCred) {
    try { if (-not (Test-Path -LiteralPath $cfgDir)) { New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null }; $newCred | Export-Clixml -Path $tokFile -Force; Write-Host "GitHub-Token gespeichert (DPAPI): $tokFile" -ForegroundColor Green }
    catch { Write-Host "[WARN] Token nicht gespeichert: $($_.Exception.Message)" -ForegroundColor Yellow }
}
if ($useBranch) { Write-Host "Version:    Entwicklungsstand Branch '$Branch' ($($ref.Substring(0, [Math]::Min(12, $ref.Length))))" -ForegroundColor Yellow }
else { Write-Host "Version:    $($rel.Tag)  ($(if ($rel.Prerelease) { 'Test' } else { 'Stabil' }), $($rel.Date))" -ForegroundColor Gray }

# --- 2. Pruefsumme und Signatur
if (-not $useBranch) {
    $manBytes = $null
    if ($rel.ManifestUrl) {
        try { $manBytes = Get-HMReleaseAsset $rel.ManifestUrl $rel.ManifestApi $Token } catch { Stop-HMPull "Pruefsummen-Datei nicht ladbar: $($_.Exception.Message)" }
        $manifest = ConvertFrom-HMManifest ([System.Text.Encoding]::UTF8.GetString($manBytes))
        if (-not $manifest.Count) { Stop-HMPull 'Pruefsummen-Datei ist leer oder beschaedigt.' }
        $verified = 'Pruefsumme (SHA256)'
    }
    if ($cfg.RequireSignature) {
        if (-not $manBytes) { Stop-HMPull "Nur signierte Updates erlaubt - $($rel.Tag) hat keine Pruefsummen-Datei." }
        $sigBytes = $null
        if ($rel.SignatureUrl) { try { $sigBytes = Get-HMReleaseAsset $rel.SignatureUrl $rel.SignatureApi $Token } catch { Stop-HMPull "Signatur nicht ladbar: $($_.Exception.Message)" } }
        $why = Test-HMManifestSignature $manBytes $sigBytes $cfg.SignerThumbprint
        if ($why) { Stop-HMPull "Nur signierte Updates erlaubt - $($rel.Tag): $why" }
        # die signierte Datei muss zu genau diesem Release gehoeren (Versionszeile) - keine Downgrade-Sperre (Kanalwechsel)
        $why = Test-HMManifestRelease ([System.Text.Encoding]::UTF8.GetString($manBytes)) $rel.Version
        if ($why) { Stop-HMPull $why }
        $verified = "Pruefsumme + Signatur ($($cfg.SignerThumbprint.Substring(0, [Math]::Min(8, $cfg.SignerThumbprint.Length)))...)"
        Write-Host 'Signatur:   gueltig' -ForegroundColor Green
    }
    if (-not $manifest) {
        Write-Host "[WARN] $($rel.Tag) hat keine Pruefsummen-Datei (Versionen bis 2.0.52 oder die automatischen Tests sind noch nicht fertig/fehlgeschlagen)." -ForegroundColor Yellow
        if ($NonInteractive) { Stop-HMPull 'ohne Pruefsumme nicht erlaubt (-NonInteractive)' }
        $a = Read-Host 'Trotzdem ohne Pruefung laden? (j/N)'
        if ("$a".Trim() -notmatch '^[jJyY]') { Stop-HMPull 'abgebrochen' }
    }
}
Write-Host "Pruefung:   $verified" -ForegroundColor Gray

# --- 3. Dateiliste
try { $tree = Invoke-RestMethod "https://api.github.com/repos/$Owner/$Repo/git/trees/${ref}?recursive=1" -Headers (New-GHHeaders 'application/vnd.github.v3+json') -UseBasicParsing }
catch { Stop-HMPull "Dateiliste nicht lesbar: $($_.Exception.Message)" }
$files = @($tree.tree | Where-Object { $_.type -eq 'blob' -and "$($_.path)" -notlike '.github/*' })
if (-not $files.Count) { Stop-HMPull 'Repo-Inhalt leer' }
Write-Host "$($files.Count) Dateien`n" -ForegroundColor Gray

# --- 4. alles laden und pruefen (noch nichts ersetzen)
$staged = New-Object System.Collections.Generic.List[object]
$fail = 0
foreach ($f in $files) {
    $local = Join-Path $Target ($f.path -replace '/', '\')
    $dir = Split-Path $local -Parent
    try { if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null } } catch { Write-Host "  $($f.path): Ordner nicht anlegbar" -ForegroundColor Red; $fail++; continue }
    Write-Host ('  {0,-48} ... ' -f $f.path) -NoNewline
    $tmp = "$local.pulltmp"
    $done = $false; $lastErr = ''
    for ($try = 1; $try -le 5 -and -not $done; $try++) {
        try {
            $enc = (($f.path -split '/') | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
            if ($Token) { Invoke-WebRequest "https://api.github.com/repos/$Owner/$Repo/contents/${enc}?ref=$ref" -Headers (New-GHHeaders 'application/vnd.github.v3.raw') -UseBasicParsing -OutFile $tmp }
            else { Invoke-WebRequest "https://raw.githubusercontent.com/$Owner/$Repo/$ref/$enc" -Headers @{ 'User-Agent' = 'HUMig-Pull' } -UseBasicParsing -OutFile $tmp }
            $done = $true
        } catch { $lastErr = $_.Exception.Message; Start-Sleep -Seconds 1 }
    }
    if (-not $done) { Write-Host "FEHLER: $lastErr" -ForegroundColor Red; $fail++; continue }
    if ($manifest) {
        $want = $manifest[$f.path]
        $have = Get-HMFileSha256 $tmp
        if (-not $want) { Write-Host 'FEHLER: nicht in der Pruefsummen-Datei' -ForegroundColor Red; $fail++; $staged.Add(@($tmp, $local)); continue }
        if ($have -ne $want) { Write-Host 'FEHLER: Pruefsumme stimmt nicht' -ForegroundColor Red; $fail++; $staged.Add(@($tmp, $local)); continue }
        Write-Host 'OK (geprueft)' -ForegroundColor Green
    } else { Write-Host "OK ($((Get-Item -LiteralPath $tmp -Force).Length) bytes)" -ForegroundColor Green }
    $staged.Add(@($tmp, $local))
}
if ($fail) {
    foreach ($s in $staged) { Remove-Item -LiteralPath $s[0] -Force -ErrorAction SilentlyContinue }
    Stop-HMPull "$fail Datei(en) nicht geladen oder Pruefsumme falsch - es wurde NICHTS veraendert, HUMig bleibt auf der bisherigen Version."
}

# --- 5. ersetzen - mit Ruecksicherung: jede bisherige Datei wird erst zu *.pullold umbenannt;
#        scheitert ein Schritt, wird alles zurueckgestellt (nie halb aktualisiert).
#        Bricht Pull mittendrin ab (Absturz, Strom), stellt der naechste Start anhand des Journals zurueck.
$journal = Join-Path $cfgDir 'pull-journal.json'
$moved = New-Object System.Collections.Generic.List[object]   # @(Ziel, Sicherung oder '')
$repl = 0; $lastErr = ''
try { if (-not (Test-Path -LiteralPath $cfgDir)) { New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null } } catch { }
try { ConvertTo-Json -InputObject @($staged | ForEach-Object { "$($_[1])" }) | Set-Content -LiteralPath $journal -Encoding UTF8 -ErrorAction Stop }
catch {
    foreach ($s in $staged) { Remove-Item -LiteralPath $s[0] -Force -ErrorAction SilentlyContinue }
    Stop-HMPull "Journal nicht schreibbar ($($_.Exception.Message)) - es wurde NICHTS veraendert."
}
foreach ($s in $staged) {
    $old = "$($s[1]).pullold"
    $done = $false
    $had = Test-Path -LiteralPath $s[1]      # einmal vor den Wiederholungen bestimmen
    $backedUp = $false                       # bisherige Datei liegt gerade als *.pullold
    for ($try = 1; $try -le 5 -and -not $done; $try++) {
        try {
            if ($had -and -not $backedUp) { Move-Item -LiteralPath $s[1] -Destination $old -Force; $backedUp = $true }
            try { Move-Item -LiteralPath $s[0] -Destination $s[1] -Force }
            catch { if ($backedUp) { try { Move-Item -LiteralPath $old -Destination $s[1] -Force; $backedUp = $false } catch { } }; throw }
            $moved.Add(@($s[1], $(if ($had) { $old } else { '' })))
            $done = $true
        } catch { $lastErr = $_.Exception.Message; Start-Sleep -Seconds 1 }
    }
    if (-not $done) {
        if ($backedUp) { try { Move-Item -LiteralPath $old -Destination $s[1] -Force } catch { Write-Host "  [WARN] $($s[1]): Sicherung nicht zurueckgestellt ($($_.Exception.Message))" -ForegroundColor Yellow } }
        Write-Host "  $($s[1]): nicht ersetzbar ($lastErr)" -ForegroundColor Red; $repl++; break
    }
}
if ($repl) {
    # zurueckstellen (umgekehrte Reihenfolge): neue Dateien entfernen, Sicherungen zurueck
    for ($k = $moved.Count - 1; $k -ge 0; $k--) {
        $m = $moved[$k]
        try { if ($m[1]) { Move-Item -LiteralPath $m[1] -Destination $m[0] -Force } else { Remove-Item -LiteralPath $m[0] -Force } }
        catch { Write-Host "  [WARN] $($m[0]): nicht zurueckgestellt ($($_.Exception.Message))" -ForegroundColor Yellow }
    }
    foreach ($s in $staged) { Remove-Item -LiteralPath $s[0] -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $journal -Force -ErrorAction SilentlyContinue
    Stop-HMPull "Eine Datei war gesperrt ($lastErr) - alles wurde zurueckgestellt, HUMig bleibt auf der bisherigen Version. HUMig schliessen und erneut versuchen."
}
# Abschluss: zuerst das Journal loeschen (ab hier gilt der neue Stand), dann die Sicherungen.
# Umgekehrt koennte ein Abbruch beim Aufraeumen einen Mischstand aus alt und neu herstellen.
Remove-Item -LiteralPath $journal -Force -ErrorAction SilentlyContinue
foreach ($m in $moved) {
    try { Unblock-File -LiteralPath $m[0] -ErrorAction SilentlyContinue } catch { }
    if ($m[1]) { Remove-Item -LiteralPath $m[1] -Force -ErrorAction SilentlyContinue }
}
$ok = $moved.Count

# --- 6. Dateien entfernen, die es im neuen Stand nicht mehr gibt - nur solche, die frueher per Pull installiert wurden
#        (Liste in installed.json). Eigene Dateien und Arbeitsordner bleiben immer unberuehrt.
$newFiles = @($files | ForEach-Object { "$($_.path)" })
$instFile = Join-Path $cfgDir 'installed.json'
$prevFiles = @()
try { if (Test-Path -LiteralPath $instFile) { $pi = Get-Content -LiteralPath $instFile -Raw -Encoding UTF8 | ConvertFrom-Json; if ($pi.PSObject.Properties['FileList']) { $prevFiles = @($pi.FileList) } } } catch { }
$removedOld = 0
$keepDirs = '^(Config|Logs|BACKUPS|BIN|Softwareverteilung|Treiberverteilung)/'
$rootFull = [IO.Path]::GetFullPath($Target).TrimEnd('\') + '\'
foreach ($oldPath in @($prevFiles | ForEach-Object { "$_" } | Where-Object { $_ -and $newFiles -notcontains $_ -and $_ -notmatch $keepDirs -and $_ -notmatch '(^|/)\.\.(/|$)' -and $_ -notmatch '^[\\/]|:' })) {
    $p = [IO.Path]::GetFullPath((Join-Path $Target ($oldPath -replace '/', '\')))
    if (-not $p.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) { continue }
    if (Test-Path -LiteralPath $p -PathType Leaf) {
        try { Remove-Item -LiteralPath $p -Force; $removedOld++; Write-Host "  entfernt (nicht mehr im Programm): $oldPath" -ForegroundColor DarkGray } catch { }
    }
}
try {
    [pscustomobject][ordered]@{
        Version = $(if ($useBranch) { "Branch $Branch" } else { "$($rel.Version)" }); Ref = "$ref"; Channel = $(if ($useBranch) { 'Branch' } elseif ($rel.Prerelease) { 'Test' } else { 'Stable' })
        Check = $verified; Date = (Get-Date).ToString('yyyy-MM-dd HH:mm'); Files = $ok; FileList = $newFiles
    } | ConvertTo-Json | Set-Content -LiteralPath $instFile -Encoding UTF8
} catch { }
# --- 7. Ordnerrechte: mit Administratorrechten, lokal und NTFS nur den Backup-Ordner privat machen (jeder Benutzer sieht nur
#        seine eigenen Backups) - und nur, wenn der Programmordner schon abgesichert ist oder bei einer Erstinstallation.
#        Den Programmordner selbst sichert Pull NICHT still ab: das fragt HUMig beim naechsten Start als Administrator.
#        Nicht bei "nie mehr fragen" (AclCheckOff in settings.json). Ohne Administratorrechte: nichts tun.
#        icacls meldet Fehler auf stderr - mit $ErrorActionPreference 'Stop' waere das ein Abbruch, darum hier 'Continue'
$eapPull = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    $elev = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $tFull = [IO.Path]::GetFullPath($Target).TrimEnd('\')
    $fsType = ''
    if ($elev -and $tFull -notlike '\\*') { try { $fsType = (New-Object System.IO.DriveInfo ([IO.Path]::GetPathRoot($tFull))).DriveFormat } catch { $fsType = '' } }
    if ($elev -and $tFull -notlike '\\*' -and $fsType -eq 'NTFS' -and -not (Test-HMAclCheckOff (Join-Path $tFull 'Config'))) {
        $aclNeed = ''; $aclOk = $true
        try { $aclNeed = Get-HMAppAclFindings $tFull } catch { $aclNeed = ''; $aclOk = $false }
        if ($aclNeed) { Write-Host "Ordnerrechte: $($aclNeed -replace "`n", ' | ') - HUMig fragt beim naechsten Start als Administrator nach dem Absichern." -ForegroundColor Yellow }
        if ($aclOk -and (-not $aclNeed -or $pullFirst)) {
            $aclBr = Get-HMAppBackupRoot $tFull
            $aclPub = @(@($aclBr, (Join-Path $tFull 'BACKUPS')) | Where-Object { $_ -and "$_".StartsWith($tFull + '\', [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $_) -and -not (Test-HMAppBackupPrivate $_) })
            if ($aclPub.Count -or $pullFirst) {
                Write-Host 'Ordnerrechte: Backup-Ordner wird privat gemacht ...' -ForegroundColor Gray
                foreach ($x in @(Protect-HMAppFolder $tFull @($aclBr) -BackupsOnly)) {
                    Write-Host "  $($x.Text)" -ForegroundColor $(switch ("$($x.Level)") { 'Success' { 'Green' } 'Warning' { 'Yellow' } 'Error' { 'Red' } default { 'Gray' } })
                }
            }
        }
    }
} catch { Write-Host "[WARN] Ordnerrechte nicht gesetzt: $($_.Exception.Message)" -ForegroundColor Yellow }
finally { $ErrorActionPreference = $eapPull }
Write-Host "`n=== Pull fertig === $ok Dateien ($verified)$(if ($removedOld) { " | $removedOld alte entfernt" })" -ForegroundColor Cyan
if ($NoStart) { if ($repl) { exit 1 } else { exit 0 } }
if ($repl -eq 0) {
    $exe = Join-Path $Target 'HUMig.exe'
    $cmd = Join-Path $Target 'Start.cmd'
    if (Test-Path $exe) { Start-Process -FilePath $exe -WorkingDirectory $Target }
    elseif (Test-Path $cmd) { Start-Process -FilePath $cmd -WorkingDirectory $Target -WindowStyle Hidden }
    else { Start-Process powershell.exe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$(Join-Path $Target 'HUMig.ps1')`"" -WorkingDirectory $Target -Verb RunAs }
    exit 0
}
Stop-HMPull 'Einzelne Dateien konnten nicht ersetzt werden (gesperrt?) - HUMig wird NICHT automatisch gestartet. Pull erneut ausfuehren.'
