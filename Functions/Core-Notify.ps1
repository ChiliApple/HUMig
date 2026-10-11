#Requires -Version 5.1
<#
.SYNOPSIS
    Benachrichtigung ueber einen Teams-Workflow (Workflows-App: "Bei Eingang einer Teams-Webhookanforderung"
    bzw. Vorlage "Send webhook alerts to a channel"). Die alten Office-365-Connectors sind abgeschaltet.
.DESCRIPTION
    Die Webhook-Adresse ist ein Geheimnis (wer sie kennt, kann in den Kanal schreiben). Sie wird darum nur auf dem PC
    gespeichert, auf dem sie eingetragen wird: HKLM:\SOFTWARE\HUMig\Notify, mit DPAPI (Computer) verschluesselt,
    Schluessel nur fuer SYSTEM + Administratoren lesbar. Nie im Tool-Ordner, in settings.json, Logs oder Support-Paketen.
    Gesendet wird darum nur aus Vorgaengen mit Administrator-/SYSTEM-Rechten (geplantes Server-Backup, Vorgaenge in HUMig
    als Administrator) - geplante Profil-Backups im Benutzerkonto melden sich lokal (Windows-Hinweis, Startseite).
.NOTES
    Zielmaschine: der PC, auf dem HUMig bzw. die geplante Aufgabe laeuft. Ohne Abhaengigkeiten (auch in Aufgaben geladen).
#>

$script:HMNotifyKey = 'HKLM:\SOFTWARE\HUMig\Notify'
$script:HMNotifyEntropy = [System.Text.Encoding]::UTF8.GetBytes('HUMig-Notify-v1')
# Kategorien (einzeln ein-/ausschaltbar, Registry-Wert Cat_<Name> als DWORD). Wert: Text, Standard
$script:HMNotifyCats = [ordered]@{
    SbError    = @('Server-Backup fehlgeschlagen / abgebrochen', $true)
    SbWarning  = @('Server-Backup mit Warnungen', $true)
    SbOK       = @('Server-Backup erfolgreich', $false)
    Health     = @('Plattenzustand (SMART) auffaellig', $true)
    Reminder   = @('Erinnerungen: Plattenwechsel / Archiv-Platte', $true)
    Space      = @('Speicherplatz auf der Backup-Platte knapp', $true)
    MassDelete = @('Massenloeschung erkannt (Verdacht auf Verschluesselungstrojaner)', $true)
    Details    = @('Details mitsenden: Dauer, Datenmenge, freier Platz, Versionen auf der Platte', $true)
}

function Protect-HMNotifyText([string]$Text) {
    Add-Type -AssemblyName System.Security
    $b = [System.Security.Cryptography.ProtectedData]::Protect([System.Text.Encoding]::UTF8.GetBytes($Text), $script:HMNotifyEntropy, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
    return [Convert]::ToBase64String($b)
}
function Unprotect-HMNotifyText([string]$Cipher) {
    Add-Type -AssemblyName System.Security
    $b = [System.Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($Cipher), $script:HMNotifyEntropy, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
    return [System.Text.Encoding]::UTF8.GetString($b)
}

# Nur echte Workflow-/Power-Automate-Adressen (https). Rueckgabe: '' = in Ordnung, sonst Grund
function Test-HMTeamsWebhookUrl([string]$Url) {
    $u = "$Url".Trim()
    if (-not $u) { return 'leer' }
    $x = $null
    if (-not [uri]::TryCreate($u, [UriKind]::Absolute, [ref]$x) -or $x.Scheme -ne 'https') { return 'keine https-Adresse' }
    if ($x.Host -match '(?i)(^|\.)webhook\.office\.com$') { return 'alte Office-365-Connector-Adresse - die Connectors sind abgeschaltet, bitte einen Workflow anlegen' }
    return ''
}
# Hinweis (kein Fehler): Adresse stammt nicht erkennbar aus der Workflows-App / Power Automate
function Test-HMTeamsWebhookHostKnown([string]$Url) {
    $x = $null
    if (-not [uri]::TryCreate("$Url".Trim(), [UriKind]::Absolute, [ref]$x)) { return $false }
    return ($x.Host -match '(?i)(\.logic\.azure\.com|\.powerplatform\.com|\.powerautomate\.com|\.azure-apim\.net)$')
}

# Kategorien mit Standardwerten (Hashtable Name -> bool)
function Get-HMNotifyDefaultCats {
    $c = @{}
    foreach ($n in $script:HMNotifyCats.Keys) { $c[$n] = [bool]$script:HMNotifyCats[$n][1] }
    return $c
}

# Einstellungen lesen: Url (entschluesselt, '' wenn keine/nicht lesbar), OnSuccess, Cats, Configured, Error
function Get-HMNotifyConfig {
    $r = [pscustomobject]@{ Url = ''; OnSuccess = $false; Cats = (Get-HMNotifyDefaultCats); Configured = $false; Error = '' }
    try {
        if (-not (Test-Path -LiteralPath $script:HMNotifyKey)) { return $r }
        $k = Get-ItemProperty -LiteralPath $script:HMNotifyKey -ErrorAction Stop
        $r.OnSuccess = [bool]([int]"0$($k.OnSuccess)")
        $r.Cats['SbOK'] = $r.OnSuccess   # aeltere Versionen: nur der Haken 'auch bei Erfolg'
        foreach ($n in $script:HMNotifyCats.Keys) {
            $v = $k.PSObject.Properties["Cat_$n"]
            if ($v) { $r.Cats[$n] = [bool]([int]"0$($v.Value)") }
        }
        $r.OnSuccess = [bool]$r.Cats['SbOK']
        if ("$($k.TeamsUrl)") { $r.Configured = $true; $r.Url = Unprotect-HMNotifyText "$($k.TeamsUrl)" }
    } catch { $r.Error = "$($_.Exception.Message)"; $r.Url = '' }
    return $r
}

# Ist die Kategorie eingeschaltet? (unbekannte Kategorie = ein)
function Test-HMNotifyCat($Cfg, [string]$Name) {
    if (-not $Name) { return $true }
    $c = $null
    if ($Cfg) { $c = $Cfg.Cats }
    if ($c -and $c.ContainsKey($Name)) { return [bool]$c[$Name] }
    if ($script:HMNotifyCats.Contains($Name)) { return [bool]$script:HMNotifyCats[$Name][1] }
    return $true
}

# Speichern (Administrator). $Url = $null: Adresse unveraendert lassen, '' = Adresse entfernen
function Set-HMNotifyConfig {
    param($Url = $null, [bool]$OnSuccess = $false, [hashtable]$Cats = $null)
    if ($Cats -and $Cats.ContainsKey('SbOK')) { $OnSuccess = [bool]$Cats['SbOK'] }
    if (-not (Test-Path -LiteralPath $script:HMNotifyKey)) { New-Item -Path $script:HMNotifyKey -Force -ErrorAction Stop | Out-Null }
    # Schluessel nur fuer SYSTEM + Administratoren (Vererbung aus) - Benutzer koennen die Adresse nicht lesen
    $acl = New-Object System.Security.AccessControl.RegistrySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner((New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    foreach ($s in @('S-1-5-18', 'S-1-5-32-544')) {
        $acl.AddAccessRule((New-Object System.Security.AccessControl.RegistryAccessRule((New-Object System.Security.Principal.SecurityIdentifier($s)), 'FullControl', 'ContainerInherit', 'None', 'Allow')))
    }
    Set-Acl -LiteralPath $script:HMNotifyKey -AclObject $acl -ErrorAction Stop
    if ($null -ne $Url) {
        if ("$Url".Trim()) {
            $why = Test-HMTeamsWebhookUrl $Url
            if ($why) { throw "Webhook-Adresse ungueltig: $why" }
            Set-ItemProperty -LiteralPath $script:HMNotifyKey -Name 'TeamsUrl' -Value (Protect-HMNotifyText "$Url".Trim()) -Type String -ErrorAction Stop
        } else { Remove-ItemProperty -LiteralPath $script:HMNotifyKey -Name 'TeamsUrl' -ErrorAction SilentlyContinue }
    }
    Set-ItemProperty -LiteralPath $script:HMNotifyKey -Name 'OnSuccess' -Value ([int]$OnSuccess) -Type DWord -ErrorAction Stop
    if ($Cats) {
        foreach ($n in $script:HMNotifyCats.Keys) {
            if ($Cats.ContainsKey($n)) { Set-ItemProperty -LiteralPath $script:HMNotifyKey -Name "Cat_$n" -Value ([int][bool]$Cats[$n]) -Type DWord -ErrorAction Stop }
        }
    }
}

# Nachricht als Adaptive Card (Format der Workflows-Vorlage: attachments[].content). Level: OK | Warning | Error | Info
function New-HMTeamsPayload {
    param([string]$Title, [string[]]$Lines = @(), [string]$Level = 'Info', [string]$Source = '')
    $color = switch ($Level) { 'Error' { 'Attention' } 'Warning' { 'Warning' } 'OK' { 'Good' } default { 'Accent' } }
    $body = New-Object System.Collections.Generic.List[object]
    $body.Add([ordered]@{ type = 'TextBlock'; text = "$Title"; weight = 'Bolder'; size = 'Medium'; wrap = $true; color = $color })
    foreach ($l in @($Lines | Where-Object { "$_".Trim() })) { $body.Add([ordered]@{ type = 'TextBlock'; text = "$l"; wrap = $true; spacing = 'Small' }) }
    $foot = @("$(if ($Source) { $Source } else { $env:COMPUTERNAME })", (Get-Date).ToString('dd.MM.yyyy HH:mm'), 'HUMig') -join '  |  '
    $body.Add([ordered]@{ type = 'TextBlock'; text = $foot; isSubtle = $true; size = 'Small'; wrap = $true; spacing = 'Medium' })
    $card = [ordered]@{ '$schema' = 'http://adaptivecards.io/schemas/adaptive-card.json'; type = 'AdaptiveCard'; version = '1.4'; body = $body.ToArray() }
    $msg = [ordered]@{ type = 'message'; attachments = @([ordered]@{ contentType = 'application/vnd.microsoft.card.adaptive'; contentUrl = $null; content = $card }) }
    return ($msg | ConvertTo-Json -Depth 10 -Compress)
}

# Senden. Rueckgabe: '' = gesendet, sonst Grund (nie Ausnahme - Benachrichtigung darf keinen Vorgang stoeren)
function Send-HMTeamsMessage {
    param([string]$Title, [string[]]$Lines = @(), [string]$Level = 'Info', [string]$Url = '', [string]$Source = '')
    try {
        $u = "$Url".Trim()
        if (-not $u) { $c = Get-HMNotifyConfig; if ($c.Error) { return "Webhook nicht lesbar: $($c.Error)" }; $u = $c.Url }
        if (-not $u) { return 'kein Teams-Webhook eingetragen' }
        $why = Test-HMTeamsWebhookUrl $u
        if ($why) { return "Webhook-Adresse ungueltig: $why" }
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
        $json = New-HMTeamsPayload -Title $Title -Lines $Lines -Level $Level -Source $Source
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $null = Invoke-WebRequest -Uri $u -Method Post -Body $bytes -ContentType 'application/json; charset=utf-8' -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop
        return ''
    } catch {
        # Adresse nie in Meldungen ausgeben (enthaelt die Signatur)
        $m = "$($_.Exception.Message)" -replace 'https://\S+', '(Webhook)'
        return "Senden fehlgeschlagen: $m"
    }
}

# Meldung nur wenn eingetragen und die Kategorie eingeschaltet ist; Ergebnis als Text fuer das Protokoll
# ('' = nichts zu melden / nicht eingerichtet / Kategorie aus). Ohne Kategorie: OK nur mit 'Server-Backup erfolgreich'
function Send-HMNotify {
    param([string]$Title, [string[]]$Lines = @(), [string]$Level = 'Info', [string]$Source = '', [string]$Category = '')
    $c = Get-HMNotifyConfig
    if (-not $c.Configured) { return '' }
    if ($Category) { if (-not (Test-HMNotifyCat $c $Category)) { return '' } }
    elseif ($Level -eq 'OK' -and -not $c.OnSuccess) { return '' }
    $r = Send-HMTeamsMessage -Title $Title -Lines $Lines -Level $Level -Url $c.Url -Source $Source
    if ($r) { return "Teams-Benachrichtigung: $r" }
    return 'Teams-Benachrichtigung gesendet'
}
