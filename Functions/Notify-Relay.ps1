#Requires -Version 5.1
<#
.SYNOPSIS
    Teams-Meldung geplanter Profil-Backups (laeuft als SYSTEM, ausgeloest durch das Ereignis HUMig 1100-1103 im Anwendungsprotokoll).
.DESCRIPTION
    Geplante Profil-Backups laufen im Konto des Benutzers und duerfen die Webhook-Adressen (HKLM, nur Administratoren/SYSTEM)
    nicht lesen. Sie schreiben darum nur ein Ereignis. Diese Aufgabe nimmt das Ereignis nur als Anstoss: den Inhalt liest sie
    aus den Zeitplan-Dateien der Benutzer (%LOCALAPPDATA%\HUMig\Zeitplaene\<Id>.json im jeweiligen Profil) - neue Laeufe
    (juenger als 2 Stunden, noch nicht gemeldet) gehen an alle Teams-Ziele, bei denen die Kategorie eingeschaltet ist.
    Je Zeitplan hoechstens eine Meldung in 10 Minuten. Stand: %ProgramData%\HUMig\Notify\relay-state.json, Protokoll relay.log.
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
        foreach ($f in @(Get-ChildItem -LiteralPath $d -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
            if ($f.BaseName -notmatch '^[A-Za-z0-9]{8,40}$' -or $f.Length -gt 1MB) { continue }
            try {
                $j = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                if ("$($j.Sid)" -and "$($j.Sid)" -ne "$($p.SID)") { continue }
                $out += [pscustomobject]@{
                    Key = "$($p.SID)|$($f.BaseName)"; Name = "$($j.Name)"; Account = $acct; Computer = $env:COMPUTERNAME
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
    foreach ($r in @($runs)) {
        $prev = $state[$r.Key]
        if (-not (Test-HMRelayDue $r $prev $now)) { continue }
        $sent = $false
        foreach ($t in @($cfg.Targets | Where-Object { $_ })) {
            $m = New-HMProfileNotifyMessage -State $r -Cats $t.Cats
            if (-not $m) { continue }
            $res = Send-HMTeamsMessage -Title $m.Title -Lines $m.Lines -Level $m.Level -Url $t.Url
            Write-HMRelayLog "$($r.Key) $($r.LastStatus) $($r.LastRun) -> '$($t.Name)': $(if ($res) { $res } else { 'gesendet' })"
            $sent = $true
        }
        if (-not $sent) { Write-HMRelayLog "$($r.Key) $($r.LastStatus) $($r.LastRun): nichts zu melden (Kategorien ausgeschaltet)" }
        $state[$r.Key] = [ordered]@{ Run = "$($r.LastRun)"; Sent = $(if ($sent) { $now.ToString('yyyy-MM-dd HH:mm:ss') } else { "$($prev.Sent)" }) }
    }
    try {
        New-Item -ItemType Directory -Path $script:RelayDir -Force | Out-Null
        [pscustomobject]$state | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:RelayState -Encoding UTF8 -Force
    } catch { Write-HMRelayLog "Stand nicht gespeichert: $($_.Exception.Message)" }
}

# nur als Aufgabe ausfuehren (beim Laden in HUMig/Tests nicht)
if ($MyInvocation.InvocationName -ne '.' -and $env:HUMIG_RELAY_NORUN -ne '1') {
    try { Invoke-HMNotifyRelay } catch { Write-HMRelayLog "Fehler: $($_.Exception.Message)" }
}
