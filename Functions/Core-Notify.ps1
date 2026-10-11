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
    PbError    = @('Geplantes Profil-Backup fehlgeschlagen', $true)
    PbSkipped  = @('Geplantes Profil-Backup uebersprungen (Ziel nicht erreichbar, z.B. USB nicht angesteckt)', $true)
    PbWarning  = @('Geplantes Profil-Backup mit Warnungen', $true)
    PbOK       = @('Geplantes Profil-Backup erfolgreich', $false)
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
$script:HMNotifySelfDir = $PSScriptRoot
# Weitergabe der geplanten Profil-Backups (laufen im Benutzerkonto, duerfen die Adressen nicht lesen): das Backup schreibt
# ein Ereignis (Anwendung, Quelle HUMig, 1100-1103), eine Aufgabe unter SYSTEM reagiert darauf und meldet nach Teams.
$script:HMNotifyRelayTask = 'Teams-Meldung Profil-Backups'
$script:HMNotifyRelayPath = '\HUMig\'
$script:HMNotifyRelayCats = @('PbError', 'PbSkipped', 'PbWarning', 'PbOK', 'MassDelete')
$script:HMNotifyRelayQuery = "<QueryList><Query Id=`"0`" Path=`"Application`"><Select Path=`"Application`">*[System[Provider[@Name='HUMig'] and (EventID=1100 or EventID=1101 or EventID=1102 or EventID=1103)]]</Select></Query></QueryList>"

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

# Text aus einer Datei des Benutzers fuer die Karte: Steuer-/Richtungszeichen, Markdown (Links, Fett, HTML) und
# klickbare Adressen entschaerfen, Laenge begrenzen. '_' und '~' bleiben (Backup-Ordner, Konten, 8.3-Pfade)
function ConvertTo-HMNotifySafeText([string]$Text, [int]$Max = 400) {
    $t = ("$Text" -replace '[\x00-\x1F\x7F\u200B-\u200F\u202A-\u202E\u2066-\u2069]', ' ' -replace '[\[\]\*`<>]', '' -replace '(?i)\b(https?|ftp|file)://', '$1 :// ' -replace '(?i)\bwww\.', 'www .').Trim()
    if ($t.Length -gt $Max) {
        $n = $Max
        if ($n -gt 0 -and [char]::IsHighSurrogate($t[$n - 1])) { $n-- }   # Ersatzpaar (z.B. Emoji) nicht zerschneiden
        $t = $t.Substring(0, $n) + ' ...'
    }
    return $t
}

# Teams-Meldung eines geplanten Profil-Backups (Stand aus der Zeitplan-Datei des Benutzers) nach den Kategorien eines Ziels.
# $State: Name, Account, Computer, LastRun, LastStatus (OK|Warning|Skipped|Error), LastMessage, LastBackup, LastMassDelete
# Rueckgabe: Title, Lines, Level - oder $null, wenn keine eingeschaltete Kategorie betroffen ist
function New-HMProfileNotifyMessage {
    param($State, $Cats = $null)
    $on = { param($n) if ($Cats -and $Cats.ContainsKey($n)) { [bool]$Cats[$n] } else { Test-HMNotifyCat $null $n } }
    $st = "$($State.LastStatus)"
    $cat = switch ($st) { 'OK' { 'PbOK' } 'Warning' { 'PbWarning' } 'Skipped' { 'PbSkipped' } default { 'PbError' } }
    $lv = switch ($st) { 'OK' { 'OK' } 'Warning' { 'Warning' } 'Skipped' { 'Warning' } default { 'Error' } }
    $mass = [bool]$State.LastMassDelete -and (& $on 'MassDelete')
    $main = & $on $cat
    if (-not $main -and -not $mass) { return $null }
    if ($mass) { $lv = 'Error' }
    $stTxt = switch ($st) { 'OK' { 'erfolgreich' } 'Warning' { 'mit Warnungen' } 'Skipped' { 'uebersprungen' } default { 'FEHLGESCHLAGEN' } }
    if ($mass) { $stTxt = 'MASSENLOESCHUNG ERKANNT' }
    $who = ConvertTo-HMNotifySafeText "$($State.Account)" 80
    $pc = ConvertTo-HMNotifySafeText "$($State.Computer)" 40
    $lines = New-Object System.Collections.Generic.List[string]
    if ($mass) { $lines.Add('An der Quelle sind auf einmal ungewoehnlich viele Dateien verschwunden - typisches Zeichen fuer einen Verschluesselungstrojaner. PC pruefen!') }
    $m = ConvertTo-HMNotifySafeText "$($State.LastMessage)"
    if ($m) { $lines.Add($m) }
    if (& $on 'Details') {
        if ("$($State.LastRun)") { $lines.Add("Zeitpunkt: $(ConvertTo-HMNotifySafeText "$($State.LastRun)" 20)") }
        if ("$($State.LastBackup)") { $lines.Add("Backup: $(ConvertTo-HMNotifySafeText "$($State.LastBackup)" 260)") }
    }
    return [pscustomobject]@{ Title = "Profil-Backup '$(ConvertTo-HMNotifySafeText "$($State.Name)" 80)' von $who an ${pc}: $stTxt"; Lines = @($lines.ToArray()); Level = $lv }
}

# Braucht eines der Ziele die Weitergabe der Profil-Backups?
function Test-HMNotifyRelayNeeded([object[]]$Targets) {
    foreach ($t in @($Targets | Where-Object { $_ })) { foreach ($n in $script:HMNotifyRelayCats) { if (Test-HMNotifyCat $t $n) { return $true } } }
    return $false
}

# Inhalt des Weitergabe-Skripts (dieses Modul + Functions\Notify-Relay.ps1, ohne Abhaengigkeiten)
function Get-HMNotifyRelayText {
    $a = [System.IO.File]::ReadAllText((Join-Path $script:HMNotifySelfDir 'Core-Notify.ps1')) -replace '(?m)^#Requires.*$', ''
    $b = [System.IO.File]::ReadAllText((Join-Path $script:HMNotifySelfDir 'Notify-Relay.ps1')) -replace '(?m)^#Requires.*$', ''
    return ("#Requires -Version 5.1`r`n# HUMig: Teams-Meldung geplanter Profil-Backups (erzeugt von HUMig, wird bei jedem Speichern/Start ersetzt)`r`n" + $a + "`r`n" + $b)
}

# Weitergabe einrichten/entfernen (Administrator). -RefreshOnly: nur ein vorhandenes Skript auf den Stand dieser Version bringen.
# Rueckgabe: Text fuer die Konsole ('' = nichts geaendert)
function Update-HMNotifyRelay {
    param([object[]]$Targets = $null, [switch]$RefreshOnly)
    $dir = Join-Path $env:ProgramData 'HUMig\Notify'
    $file = Join-Path $dir 'relay.ps1'
    $task = Get-ScheduledTask -TaskPath $script:HMNotifyRelayPath -TaskName $script:HMNotifyRelayTask -ErrorAction SilentlyContinue
    if ($RefreshOnly) {
        if (-not $task) { return '' }
        $txt = Get-HMNotifyRelayText
        if ((Test-Path -LiteralPath $file) -and [System.IO.File]::ReadAllText($file) -ceq $txt) { return '' }
        [void](Protect-HMDataDir)
        [System.IO.File]::WriteAllText($file, $txt, (New-Object System.Text.UTF8Encoding($true)))
        return 'Teams-Meldung Profil-Backups: Skript auf den Stand dieser Version gebracht'
    }
    if ($null -eq $Targets) { $Targets = @((Get-HMNotifyConfig).Targets) }
    if (-not (Test-HMNotifyRelayNeeded $Targets)) {
        if (-not $task) { return '' }
        Unregister-ScheduledTask -TaskPath $script:HMNotifyRelayPath -TaskName $script:HMNotifyRelayTask -Confirm:$false -ErrorAction Stop
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
        return 'Teams-Meldung Profil-Backups: ausgeschaltet (Aufgabe entfernt)'
    }
    # %ProgramData%\HUMig absichern: das Skript laeuft als SYSTEM, Benutzer duerfen es nicht austauschen
    [void](Protect-HMDataDir)
    New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
    [System.IO.File]::WriteAllText($file, (Get-HMNotifyRelayText), (New-Object System.Text.UTF8Encoding($true)))
    # Ereignisquelle anlegen (Benutzer duerfen ins Anwendungsprotokoll schreiben, aber keine Quelle anlegen)
    $ex = $false; try { $ex = [System.Diagnostics.EventLog]::SourceExists('HUMig') } catch { }
    if (-not $ex) { New-EventLog -LogName Application -Source 'HUMig' -ErrorAction Stop }
    $a = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$file`""
    $cls = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace 'Root/Microsoft/Windows/TaskScheduler'
    $trg = New-CimInstance -CimClass $cls -ClientOnly
    $trg.Enabled = $true
    $trg.Subscription = $script:HMNotifyRelayQuery
    $trgs = @($trg)
    # zusaetzlich stuendlich nachsehen (falls das Ereignis im Benutzerkonto nicht geschrieben werden konnte)
    try { $trgs += New-ScheduledTaskTrigger -Once -At ((Get-Date).Date.AddHours((Get-Date).Hour + 1)) -RepetitionInterval (New-TimeSpan -Hours 1) -ErrorAction Stop } catch { $null = $_ }
    $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -MultipleInstances Queue
    $pr = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $script:HMNotifyRelayTask -TaskPath $script:HMNotifyRelayPath -Action $a -Trigger $trgs -Principal $pr -Settings $set -Description 'HUMig: meldet geplante Profil-Backups (Ereignis HUMig 1100-1103, zusaetzlich stuendlich) an die Teams-Ziele dieses PCs. Verwalten: HUMig > Einstellungen > Allgemein > Teams-Benachrichtigung.' -Force -ErrorAction Stop | Out-Null
    return $(if ($task) { 'Teams-Meldung Profil-Backups: Aufgabe aktualisiert' } else { 'Teams-Meldung Profil-Backups: eingerichtet (Aufgabe \HUMig\Teams-Meldung Profil-Backups, laeuft als SYSTEM)' })
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
