#Requires -Version 5.1
<#
.SYNOPSIS
    Benachrichtigung ueber Teams-Workflows (Workflows-App, Vorlage "Webhookbenachrichtigungen an einen Chat/Kanal").
    Die alten Office-365-Connectors sind abgeschaltet.
.DESCRIPTION
    Mehrere Ziele (Chat/Kanal) je PC, jedes mit Name und eigenen Kategorien - z.B. Fehler an den Kanal des Teams,
    Erfolgsmeldungen nur an einen selbst. Webhook-Adressen sind Geheimnisse (wer sie kennt, kann dort schreiben). Sie werden
    darum nur auf dem PC gespeichert, auf dem sie eingetragen werden: HKLM:\SOFTWARE\HUMig\Notify (Wert Targets), mit DPAPI
    (Computer) verschluesselt, Schluessel nur fuer SYSTEM + Administratoren lesbar. Nie im Tool-Ordner, in settings.json,
    Logs oder Support-Paketen. Gesendet wird darum nur aus Vorgaengen mit Administrator-/SYSTEM-Rechten (geplantes
    Server-Backup, Vorgaenge in HUMig als Administrator) - geplante Profil-Backups im Benutzerkonto melden sich lokal.
.NOTES
    Zielmaschine: der PC, auf dem HUMig bzw. die geplante Aufgabe laeuft. Ohne Abhaengigkeiten (auch in Aufgaben geladen).
#>

$script:HMNotifyKey = 'HKLM:\SOFTWARE\HUMig\Notify'
$script:HMNotifyEntropy = [System.Text.Encoding]::UTF8.GetBytes('HUMig-Notify-v1')
# Kategorien (je Ziel einzeln ein-/ausschaltbar). Wert: Text, Standard
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

$script:HMNotifyMaxTargets = 10

# Kategorien aus einem gelesenen Objekt/Hashtable uebernehmen (unbekannte Namen ignorieren, fehlende = Standard)
function ConvertTo-HMNotifyCats($Src) {
    $c = Get-HMNotifyDefaultCats
    if ($null -eq $Src) { return $c }
    if ($Src -is [System.Collections.IDictionary]) { foreach ($n in @($c.Keys)) { if ($Src.Contains($n)) { $c[$n] = [bool]$Src[$n] } } }
    else { foreach ($p in @($Src.PSObject.Properties)) { if ($c.ContainsKey($p.Name)) { $c[$p.Name] = [bool]$p.Value } } }
    return $c
}

# Einstellungen lesen. Targets = Ziele (Id, Name, Url entschluesselt, Cats). Url/Cats/OnSuccess = erstes Ziel (aeltere Aufrufer)
function Get-HMNotifyConfig {
    $r = [pscustomobject]@{ Url = ''; OnSuccess = $false; Cats = (Get-HMNotifyDefaultCats); Targets = @(); Configured = $false; Error = '' }
    try {
        if (-not (Test-Path -LiteralPath $script:HMNotifyKey)) { return $r }
        $k = Get-ItemProperty -LiteralPath $script:HMNotifyKey -ErrorAction Stop
        $list = @()
        if ("$($k.Targets)") {
            $j = (Unprotect-HMNotifyText "$($k.Targets)") | ConvertFrom-Json   # erst zuweisen (PS 5.1: Liste kommt als EIN Objekt)
            foreach ($t in @($j | ForEach-Object { $_ } | Where-Object { $_ })) {
                if (-not "$($t.Url)") { continue }
                $list += [pscustomobject]@{ Id = "$($t.Id)"; Name = "$($t.Name)"; Url = "$($t.Url)"; Cats = (ConvertTo-HMNotifyCats $t.Cats) }
            }
        } else {
            # bis 2.0.115: eine Adresse (TeamsUrl), Kategorien Cat_<Name>, davor nur OnSuccess
            $c = Get-HMNotifyDefaultCats
            $c['SbOK'] = [bool]([int]"0$($k.OnSuccess)")
            foreach ($n in @($c.Keys)) { $v = $k.PSObject.Properties["Cat_$n"]; if ($v) { $c[$n] = [bool]([int]"0$($v.Value)") } }
            $r.Cats = $c
            if ("$($k.TeamsUrl)") { $list += [pscustomobject]@{ Id = 'standard'; Name = 'Standard'; Url = (Unprotect-HMNotifyText "$($k.TeamsUrl)"); Cats = $c } }
        }
        $r.Targets = @($list)
        if ($list.Count) { $r.Configured = $true; $r.Url = $list[0].Url; $r.Cats = $list[0].Cats }
        $r.OnSuccess = [bool]$r.Cats['SbOK']
    } catch { $r.Error = "$($_.Exception.Message)"; $r.Url = ''; $r.Targets = @(); $r.Configured = $false }
    return $r
}

# Ist die Kategorie eingeschaltet? $Cfg = Konfiguration oder Ziel (mit .Cats). Unbekannte Kategorie = ein
function Test-HMNotifyCat($Cfg, [string]$Name) {
    if (-not $Name) { return $true }
    $c = $null
    if ($Cfg) { $c = $Cfg.Cats }
    if ($c -and $c.ContainsKey($Name)) { return [bool]$c[$Name] }
    if ($script:HMNotifyCats.Contains($Name)) { return [bool]$script:HMNotifyCats[$Name][1] }
    return $true
}

# Schluessel anlegen, nur SYSTEM + Administratoren (Vererbung aus) - Benutzer koennen die Adressen nicht lesen
function Initialize-HMNotifyKey {
    if (-not (Test-Path -LiteralPath $script:HMNotifyKey)) { New-Item -Path $script:HMNotifyKey -Force -ErrorAction Stop | Out-Null }
    $acl = New-Object System.Security.AccessControl.RegistrySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner((New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    foreach ($s in @('S-1-5-18', 'S-1-5-32-544')) {
        $acl.AddAccessRule((New-Object System.Security.AccessControl.RegistryAccessRule((New-Object System.Security.Principal.SecurityIdentifier($s)), 'FullControl', 'ContainerInherit', 'None', 'Allow')))
    }
    Set-Acl -LiteralPath $script:HMNotifyKey -AclObject $acl -ErrorAction Stop
}

# Ziele pruefen. Rueckgabe: '' = in Ordnung, sonst Grund
function Test-HMNotifyTargets([object[]]$Targets) {
    $l = @($Targets | Where-Object { $_ })
    if ($l.Count -gt $script:HMNotifyMaxTargets) { return "hoechstens $($script:HMNotifyMaxTargets) Ziele" }
    $names = @{}
    foreach ($t in $l) {
        $n = "$($t.Name)".Trim()
        if (-not $n) { return 'ein Ziel hat keinen Namen' }
        if ($names.ContainsKey($n.ToLower())) { return "Name '$n' doppelt" }
        $names[$n.ToLower()] = 1
        $why = Test-HMTeamsWebhookUrl "$($t.Url)"
        if ($why) { return "Ziel '$n': Webhook-Adresse $why" }
    }
    return ''
}

# Ziele speichern (Administrator): alle Ziele als eine mit DPAPI verschluesselte Liste. Leere Liste = alles entfernen
function Set-HMNotifyTargets {
    param([object[]]$Targets = @())
    $why = Test-HMNotifyTargets $Targets
    if ($why) { throw "Teams-Ziele ungueltig: $why" }
    Initialize-HMNotifyKey
    $list = @(foreach ($t in @($Targets | Where-Object { $_ })) {
        $id = "$($t.Id)".Trim(); if (-not $id) { $id = [guid]::NewGuid().ToString('N').Substring(0, 8) }
        $c = ConvertTo-HMNotifyCats $t.Cats
        $co = [ordered]@{}; foreach ($n in $script:HMNotifyCats.Keys) { $co[$n] = [bool]$c[$n] }
        [ordered]@{ Id = $id; Name = "$($t.Name)".Trim(); Url = "$($t.Url)".Trim(); Cats = $co }
    })
    if ($list.Count) {
        $json = ConvertTo-Json -InputObject @($list) -Depth 5 -Compress
        Set-ItemProperty -LiteralPath $script:HMNotifyKey -Name 'Targets' -Value (Protect-HMNotifyText $json) -Type String -ErrorAction Stop
    } else { Remove-ItemProperty -LiteralPath $script:HMNotifyKey -Name 'Targets' -ErrorAction SilentlyContinue }
    # Werte bis 2.0.115 (eine Adresse) entfernen - sind jetzt in der Liste
    foreach ($v in @(@('TeamsUrl', 'OnSuccess') + @($script:HMNotifyCats.Keys | ForEach-Object { "Cat_$_" }))) { Remove-ItemProperty -LiteralPath $script:HMNotifyKey -Name $v -ErrorAction SilentlyContinue }
}

# Ein Ziel sofort entfernen (nur dieses, die anderen bleiben)
function Remove-HMNotifyTarget([string]$Id) {
    $c = Get-HMNotifyConfig
    if ($c.Error) { throw "Teams-Ziele nicht lesbar: $($c.Error)" }
    Set-HMNotifyTargets -Targets @(@($c.Targets) | Where-Object { "$($_.Id)" -ne $Id })
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

# Meldung an alle Ziele, bei denen die Kategorie eingeschaltet ist; Ergebnis als Text fuer das Protokoll
# ('' = nichts zu melden / nicht eingerichtet / Kategorie ueberall aus). Ohne Kategorie: OK nur an Ziele mit 'Server-Backup erfolgreich'
function Send-HMNotify {
    param([string]$Title, [string[]]$Lines = @(), [string]$Level = 'Info', [string]$Source = '', [string]$Category = '')
    $c = Get-HMNotifyConfig
    if (-not $c.Configured) { return '' }
    $out = @()
    foreach ($t in @($c.Targets | Where-Object { $_ })) {
        if ($Category) { if (-not (Test-HMNotifyCat $t $Category)) { continue } }
        elseif ($Level -eq 'OK' -and -not (Test-HMNotifyCat $t 'SbOK')) { continue }
        $r = Send-HMTeamsMessage -Title $Title -Lines $Lines -Level $Level -Url $t.Url -Source $Source
        $out += "$($t.Name): $(if ($r) { $r } else { 'gesendet' })"
    }
    if (-not $out.Count) { return '' }
    return "Teams-Benachrichtigung: $($out -join '; ')"
}
