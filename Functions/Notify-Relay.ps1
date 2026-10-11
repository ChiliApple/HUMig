#Requires -Version 5.1
<#
.SYNOPSIS
    Teams-Meldung geplanter Profil-Backups (laeuft als SYSTEM, ausgeloest durch das Ereignis HUMig 1100-1103 im Anwendungsprotokoll).
.DESCRIPTION
    Geplante Profil-Backups laufen im Konto des Benutzers und duerfen die Webhook-Adressen (HKLM, nur Administratoren/SYSTEM)
    nicht lesen. Sie schreiben darum nur ein Ereignis. Diese Aufgabe nimmt das Ereignis nur als Anstoss: den Inhalt liest sie
    aus den Zeitplan-Dateien der Benutzer (%LOCALAPPDATA%\HUMig\Zeitplaene\<Id>.json im jeweiligen Profil) - neue Laeufe
    (juenger als 2 Stunden, noch nicht gemeldet) gehen an alle Teams-Ziele, bei denen die Kategorie eingeschaltet ist.
    Je Zeitplan und Ziel hoechstens eine Meldung in 10 Minuten, je Benutzer hoechstens 10 gemeldete Laeufe pro Stunde
    (darueber eine Sammelkarte). Stand: %ProgramData%\HUMig\Notify\relay-state.json, Protokoll relay.log.
    Wird von HUMig mit Functions\Core-Notify.ps1 zu %ProgramData%\HUMig\Notify\relay.ps1 zusammengesetzt (Update-HMNotifyRelay).
.NOTES
    Zielmaschine: PC mit geplanten Profil-Backups (Aufgabe \HUMig\Teams-Meldung Profil-Backups, als SYSTEM).
#>

$ErrorActionPreference = 'Stop'
$script:RelayDir = Join-Path $(if ($env:ProgramData) { $env:ProgramData } else { [Environment]::GetFolderPath('CommonApplicationData') }) 'HUMig\Notify'
$script:RelayState = Join-Path $script:RelayDir 'relay-state.json'
$script:RelayLog = Join-Path $script:RelayDir 'relay.log'

function Write-HMRelayLog([string]$Msg) {
    try {
        if ((Test-Path -LiteralPath $script:RelayLog) -and (Get-Item -LiteralPath $script:RelayLog).Length -gt 512KB) { Move-Item -LiteralPath $script:RelayLog -Destination "$($script:RelayLog).old" -Force }
        Add-Content -LiteralPath $script:RelayLog -Value ('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Msg) -Encoding UTF8
    } catch { $null = $_ }
}

# Stand aller Zeitplaene auf diesem PC (aus den Profilen gelesen; nur Dateien, die zum Profil-Besitzer gehoeren)
function Get-HMRelayScheduleStates {
    $out = @()
    $profs = @(Get-CimInstance -ClassName Win32_UserProfile -Filter 'Special=False' -ErrorAction Stop)
    foreach ($p in $profs) {
        $lp = "$($p.LocalPath)"
        if (-not $lp) { continue }
        $d = Join-Path $lp 'AppData\Local\HUMig\Zeitplaene'
        if (-not (Test-Path -LiteralPath $d)) { continue }
        $acct = "$($p.SID)"
        try { $acct = (New-Object System.Security.Principal.SecurityIdentifier("$($p.SID)")).Translate([System.Security.Principal.NTAccount]).Value } catch { $null = $_ }
        # nur kuerzlich geschriebene Dateien (Meldung nur bis 2 h nach dem Lauf), neueste zuerst, hoechstens 10 je Profil
        $lim = (Get-Date).AddMinutes(-130)
        $files = @(Get-ChildItem -LiteralPath $d -Filter '*.json' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.BaseName -match '^[A-Za-z0-9]{8,40}$' -and $_.Length -le 256KB -and $_.LastWriteTime -gt $lim } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 10)
        foreach ($f in $files) {
            try {
                $j = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                if ("$($j.Sid)" -and "$($j.Sid)" -ne "$($p.SID)") { continue }
                $out += [pscustomobject]@{
                    Key = "$($p.SID)|$($f.BaseName)"; Sid = "$($p.SID)"; Name = "$($j.Name)"; Account = $acct; Computer = $env:COMPUTERNAME
                    LastRun = "$($j.LastRun)"; LastStatus = "$($j.LastStatus)"; LastMessage = "$($j.LastMessage)"; LastBackup = "$($j.LastBackup)"; LastMassDelete = [bool]$j.LastMassDelete
                }
            } catch { Write-HMRelayLog "Zeitplan $($f.FullName) nicht lesbar: $($_.Exception.Message)" }
        }
    }
    return ,$out
}

# Soll der Lauf gemeldet werden? (neu, nicht zu alt, nicht zu haeufig)
function Test-HMRelayDue($Run, $Prev, [datetime]$Now) {
    if (-not "$($Run.LastRun)" -or -not "$($Run.LastStatus)") { return $false }
    if ($Prev -and "$($Prev.Run)" -eq "$($Run.LastRun)") { return $false }
    $t = [datetime]::MinValue
    if (-not [datetime]::TryParseExact("$($Run.LastRun)", 'yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$t)) { return $false }
    if ($t -lt $Now.AddHours(-2) -or $t -gt $Now.AddMinutes(10)) { return $false }
    if ($Prev -and "$($Prev.Sent)") {
        $s = [datetime]::MinValue
        if ([datetime]::TryParseExact("$($Prev.Sent)", 'yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$s) -and $s -gt $Now.AddMinutes(-10)) { return $false }
    }
    return $true
}

$script:RelayMaxTries = 3      # Sendeversuche je Lauf und Ziel bei voruebergehenden Fehlern
$script:RelayMaxPerHour = 10   # gesendete Laeufe je Benutzer (SID) und Stunde, darueber eine Sammelkarte je Stunde
$script:RelayInv = [System.Globalization.CultureInfo]::InvariantCulture

function ConvertTo-HMRelayTime([string]$Text, [string]$Format = 'yyyy-MM-dd HH:mm:ss') {
    $t = [datetime]::MinValue
    if ([datetime]::TryParseExact("$Text", $Format, $script:RelayInv, [System.Globalization.DateTimeStyles]::None, [ref]$t)) { return $t }
    return $null
}

# Stand je Lauf und Ziel: Run/Sent = zuletzt erledigter Lauf / zuletzt gesendet, Fail/Tries = fehlgeschlagene Versuche
function New-HMRelayMark([string]$Run, [string]$Sent, [string]$Fail = '', [int]$Tries = 0) {
    $m = [ordered]@{ Run = $Run; Sent = $Sent }
    if ($Fail) { $m.Fail = $Fail; $m.Tries = $Tries }
    return [pscustomobject]$m
}

# Laeufe an die Ziele melden, Stand je Ziel (Schluessel "<SID>|<Zeitplan>|<Ziel-Id>") in $State fortschreiben
function Invoke-HMRelayRuns {
    param([object[]]$Runs = @(), [object[]]$Targets = @(), [hashtable]$State, [datetime]$Now)
    $nowS = $Now.ToString('yyyy-MM-dd HH:mm:ss', $script:RelayInv)
    $tl = @($Targets | Where-Object { $_ })
    $supp = @{}   # SID -> unterdrueckte Laeufe (Anzahl, letzter Lauf fuer Konto/PC)
    foreach ($r in @($Runs | Where-Object { $_ })) {
        $old = $State["$($r.Key)"]   # Stand bis 2.0.120 (je Zeitplan, nicht je Ziel)
        $todo = @(); $quiet = $false
        foreach ($t in $tl) {
            $tid = "$($t.Id)"; if (-not $tid) { $tid = "$($t.Name)" }
            $tk = "$($r.Key)|$tid"
            $prev = $State[$tk]
            if (-not $prev) { $prev = $old }   # Uebergang: schon gemeldeter Lauf nicht noch einmal
            if (-not (Test-HMRelayDue $r $prev $Now)) { continue }
            $m = New-HMProfileNotifyMessage -State $r -Cats $t.Cats
            if (-not $m) { $State[$tk] = New-HMRelayMark "$($r.LastRun)" "$($prev.Sent)"; $quiet = $true; continue }
            $todo += [pscustomobject]@{ Target = $t; Key = $tk; Prev = $prev; Msg = $m }
        }
        if (-not $todo.Count) {
            if ($quiet) { Write-HMRelayLog "$($r.Key) $($r.LastStatus) $($r.LastRun): nichts zu melden (Kategorien ausgeschaltet)" }
            continue
        }
        # Flut begrenzen: hoechstens RelayMaxPerHour gesendete Laeufe je SID und Stunde
        $sid = "$($r.Sid)"; if (-not $sid) { $sid = ("$($r.Key)" -split '\|')[0] }
        $rk = "rate|$sid"
        $rs = $State[$rk]
        $times = @(@($rs.Times) | Where-Object { $x = ConvertTo-HMRelayTime "$_"; $x -and $x -gt $Now.AddHours(-1) })
        if ($times.Count -ge $script:RelayMaxPerHour) {
            foreach ($x in $todo) { $State[$x.Key] = New-HMRelayMark "$($r.LastRun)" "$($x.Prev.Sent)" }
            if (-not $supp.ContainsKey($sid)) { $supp[$sid] = [pscustomobject]@{ Num = 0; Run = $r } }
            $supp[$sid].Num++; $supp[$sid].Run = $r
            Write-HMRelayLog "$($r.Key) $($r.LastStatus) $($r.LastRun): nicht gesendet - mehr als $($script:RelayMaxPerHour) Meldungen in einer Stunde"
            continue
        }
        $sentAny = $false
        foreach ($x in $todo) {
            $t = $x.Target; $p = $x.Prev
            $res = Send-HMTeamsMessage -Title $x.Msg.Title -Lines $x.Msg.Lines -Level $x.Msg.Level -Url $t.Url
            $info = $(if ($res) { $res } else { 'gesendet' })
            if (-not $res) { $State[$x.Key] = New-HMRelayMark "$($r.LastRun)" $nowS; $sentAny = $true }
            elseif ($res -like 'kein Teams-Webhook*' -or $res -like 'Webhook-Adresse ungueltig*') {
                # dauerhafter Fehler: nicht wiederholen
                $State[$x.Key] = New-HMRelayMark "$($r.LastRun)" "$($p.Sent)"
            } else {
                $n = 1; if ($p -and "$($p.Fail)" -eq "$($r.LastRun)") { $n = [int]"0$($p.Tries)" + 1 }
                if ($n -ge $script:RelayMaxTries) { $State[$x.Key] = New-HMRelayMark "$($r.LastRun)" "$($p.Sent)"; $info += " (Versuch $n - aufgegeben)" }
                else { $State[$x.Key] = New-HMRelayMark "$($p.Run)" "$($p.Sent)" "$($r.LastRun)" $n; $info += " (Versuch $n von $($script:RelayMaxTries), wird beim naechsten Lauf wiederholt)" }
            }
            Write-HMRelayLog "$($r.Key) $($r.LastStatus) $($r.LastRun) -> '$($t.Name)': $info"
        }
        # Kontingent nur verbrauchen, wenn mindestens ein Ziel erfolgreich gesendet hat (Fehlversuche/Wiederholungen zaehlen nicht)
        if ($sentAny) { $State[$rk] = [pscustomobject]([ordered]@{ Times = @($times + $nowS); Notice = "$($rs.Notice)" }) }
    }
    # je SID und Stunde hoechstens eine Sammelkarte (an alle Ziele mit 'Profil-Backup fehlgeschlagen')
    foreach ($sid in @($supp.Keys)) {
        $rk = "rate|$sid"; $rs = $State[$rk]
        $last = ConvertTo-HMRelayTime "$($rs.Notice)"
        if ($last -and $last -gt $Now.AddHours(-1)) { Write-HMRelayLog "$sid`: $($supp[$sid].Num) Meldungen unterdrueckt (Sammelkarte in dieser Stunde schon gesendet)"; continue }
        $r = $supp[$sid].Run
        $title = "Viele Backup-Meldungen von $(ConvertTo-HMNotifySafeText "$($r.Account)" 80) auf $(ConvertTo-HMNotifySafeText "$($r.Computer)" 40)"
        $line = "$($supp[$sid].Num) weitere Meldungen unterdrueckt - bitte pruefen (moeglicher Missbrauch)"
        foreach ($t in $tl) {
            if (-not (Test-HMNotifyCat $t 'PbError')) { continue }
            $res = Send-HMTeamsMessage -Title $title -Lines @($line) -Level 'Error' -Url $t.Url
            Write-HMRelayLog "$sid Sammelkarte ($($supp[$sid].Num) unterdrueckt) -> '$($t.Name)': $(if ($res) { $res } else { 'gesendet' })"
        }
        $State[$rk] = [pscustomobject]([ordered]@{ Times = @(@($rs.Times) | Where-Object { "$_" }); Notice = $nowS })
    }
}

# Stand aufraeumen: Laeufe aelter als 3 Tage, abgelaufene Zaehler (relay-state.json waechst nicht)
function Remove-HMRelayOldState([hashtable]$State, [datetime]$Now) {
    foreach ($k in @($State.Keys)) {
        $v = $State[$k]
        if ("$k" -like 'rate|*') {
            $keep = @(@($v.Times) | Where-Object { $x = ConvertTo-HMRelayTime "$_"; $x -and $x -gt $Now.AddHours(-1) })
            $n = ConvertTo-HMRelayTime "$($v.Notice)"
            if (-not $keep.Count -and -not ($n -and $n -gt $Now.AddDays(-1))) { $State.Remove($k) }
            else { $State[$k] = [pscustomobject]([ordered]@{ Times = $keep; Notice = "$($v.Notice)" }) }
            continue
        }
        $d = $null
        foreach ($s in @("$($v.Run)", "$($v.Fail)")) { $x = ConvertTo-HMRelayTime $s 'yyyy-MM-dd HH:mm'; if ($x -and (-not $d -or $x -gt $d)) { $d = $x } }
        if (-not $d -or $d -lt $Now.AddDays(-3)) { $State.Remove($k) }
    }
}

function Invoke-HMNotifyRelay {
    Start-Sleep -Seconds 2   # Ereignis kommt direkt nach dem Schreiben der Zeitplan-Datei
    $cfg = Get-HMNotifyConfig
    if (-not $cfg.Configured) { if ($cfg.Error) { Write-HMRelayLog "Teams-Ziele nicht lesbar: $($cfg.Error)" }; return }
    $state = @{}
    if (Test-Path -LiteralPath $script:RelayState) {
        try { $j = Get-Content -LiteralPath $script:RelayState -Raw -Encoding UTF8 | ConvertFrom-Json; foreach ($p in @($j.PSObject.Properties)) { $state[$p.Name] = $p.Value } } catch { Write-HMRelayLog "Stand nicht lesbar - neu: $($_.Exception.Message)" }
    }
    $now = Get-Date
    $runs = Get-HMRelayScheduleStates
    Invoke-HMRelayRuns -Runs @($runs) -Targets @($cfg.Targets) -State $state -Now $now
    Remove-HMRelayOldState $state $now
    try {
        New-Item -ItemType Directory -Path $script:RelayDir -Force | Out-Null
        [pscustomobject]$state | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:RelayState -Encoding UTF8 -Force
    } catch { Write-HMRelayLog "Stand nicht gespeichert: $($_.Exception.Message)" }
}

# nur als Aufgabe ausfuehren (beim Laden in HUMig/Tests nicht)
if ($MyInvocation.InvocationName -ne '.' -and $env:HUMIG_RELAY_NORUN -ne '1') {
    try { Invoke-HMNotifyRelay } catch { Write-HMRelayLog "Fehler: $($_.Exception.Message)" }
}
