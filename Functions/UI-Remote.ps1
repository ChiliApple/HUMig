#Requires -Version 5.1
<#
.SYNOPSIS
    Handy-Fernbedienung (Oberflaeche): Ein/Aus, QR-Code und Kopplung, gekoppelte Geraete, Einstellungen, Benutzer-Modus.
.DESCRIPTION
    Der Webserver laeuft in einem eigenen Runspace (Remote-Core.ps1: Start-HMRemoteListenerLoop) und liest nur einen
    Schnappschuss, den die Oberflaeche jede Sekunde ablegt (Status-Daten, laufender Vorgang, Konsolenzeilen). Aktionen
    vom Handy (Abbrechen, Aktualisieren) setzt der Webserver als Markierung, die Oberflaeche fuehrt sie aus.
    Als Administrator legt HUMig Zertifikat, HTTPS-Bindung und Firewall-Regel an und entfernt sie beim Beenden wieder.
    Im Benutzer-Modus muss ein Administrator die Fernbedienung einmal vorbereiten (Einstellungen > Handy).
.NOTES
    Dot-Source aus HUMig.ps1. Zielmaschine: der PC, auf dem HUMig laeuft.
#>

$script:HMRemote = $null       # laufende Fernbedienung
$script:HMRemoteLast = $null   # letzter Vorgang: @{ Title; Result; Time }
$script:HMRemoteDlg = $null

function Test-HMRemoteAdmin {
    try { return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { return $false }
}
# Einstellungen (settings.json > Remote) mit Standardwerten
function Get-HMRemoteConfig {
    $r = $null; try { $r = $script:Settings.Remote } catch { }
    $port = 8443; try { if ($r -and [int]$r.Port -ge 1025 -and [int]$r.Port -le 65535) { $port = [int]$r.Port } } catch { }
    $min = 0; try { if ($r -and [int]$r.Minutes -gt 0) { $min = [int]$r.Minutes } } catch { }
    return [pscustomobject]@{ AutoStart = [bool]($r -and $r.AutoStart); Port = $port; Minutes = $min; Networks = @($(if ($r) { @($r.Networks) } else { @() }) | Where-Object { "$_".Trim() } | ForEach-Object { "$_".Trim() })
        # Zeitplaene vom Handy starten - je Art einzeln, Standard aus
        SchedBackup = [bool]($r -and $r.SchedBackup -eq $true); SchedServer = [bool]($r -and $r.SchedServer -eq $true); SchedAu = [bool]($r -and $r.SchedAu -eq $true) }
}
function Get-HMRemoteSetupFile { return (Join-Path $script:ConfigDir 'remote-setup.json') }
function Get-HMRemoteTempFile { return (Join-Path $script:ConfigDir 'remote-temp.json') }
function Read-HMRemoteSetup {
    $f = Get-HMRemoteSetupFile
    try { if (Test-Path -LiteralPath $f) { $j = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json; if ($j -and [int]$j.Port -gt 0 -and "$($j.Sid)") { return $j } } } catch { }
    return $null
}
function Write-HMRemoteJson([string]$Path, $Obj) {
    [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $Obj -Depth 4), (New-Object Text.UTF8Encoding $false))
}
# Zugriffsprotokoll Logs\Remote\Remote_<Monat>.log. Logs ist fuer Benutzer beschreibbar: ist Logs\Remote oder die Datei eine
# Verknuepfung (Junction/Symlink), wird nicht geschrieben (sonst schriebe HUMig als Administrator an ein fremdes Ziel)
function Get-HMRemoteLogFile {
    $d = Join-Path $script:LogDir 'Remote'
    try {
        foreach ($x in @($script:LogDir, $d)) { if ((Test-Path -LiteralPath $x) -and ((Get-Item -LiteralPath $x -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { return '' } }
        if (-not (Test-Path -LiteralPath $d)) { [void](New-Item -ItemType Directory -Path $d -Force) }
        $f = Join-Path $d ("Remote_{0}.log" -f (Get-Date -Format 'yyyy-MM'))
        if ((Test-Path -LiteralPath $f) -and ((Get-Item -LiteralPath $f -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { return '' }
        return $f
    } catch { return '' }
}
# App-Icon fuer das Handy (Logo auf dunklem Grund, Rand fuer runde/maskierte Icons)
function New-HMRemoteIconPng([int]$Size) {
    try {
        $dv = New-Object System.Windows.Media.DrawingVisual
        $dc = $dv.RenderOpen()
        $dc.DrawRectangle((New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0x1E, 0x1E, 0x2E))), $null, [System.Windows.Rect]::new(0, 0, $Size, $Size))
        if ($script:LogoImage) { $m = [Math]::Round($Size * 0.14); $dc.DrawImage($script:LogoImage, [System.Windows.Rect]::new($m, $m, $Size - 2 * $m, $Size - 2 * $m)) }
        $dc.Close()
        $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($Size, $Size, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
        $rtb.Render($dv)
        $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
        $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
        $ms = New-Object System.IO.MemoryStream
        $enc.Save($ms)
        return , $ms.ToArray()
    } catch { return $null }
}
# QR-Code als Bild (8 Pixel je Modul, 4 Module Rand)
function ConvertTo-HMRemoteQrImage([string]$Text) {
    $q = ConvertTo-HMQrMatrix $Text
    $sc = 8; $qz = 4; $n = $q.Size; $w = ($n + 2 * $qz) * $sc
    $px = New-Object byte[] ($w * $w)
    for ($i = 0; $i -lt $px.Length; $i++) { $px[$i] = 255 }
    $row = New-Object byte[] $w
    for ($y = 0; $y -lt $n; $y++) {
        for ($i = 0; $i -lt $w; $i++) { $row[$i] = 255 }
        for ($x = 0; $x -lt $n; $x++) { if ($q.Modules[$y * $n + $x]) { $o = ($x + $qz) * $sc; for ($k = 0; $k -lt $sc; $k++) { $row[$o + $k] = 0 } } }
        for ($k = 0; $k -lt $sc; $k++) { [Array]::Copy($row, 0, $px, (($y + $qz) * $sc + $k) * $w, $w) }
    }
    $bmp = [System.Windows.Media.Imaging.BitmapSource]::Create($w, $w, 96, 96, [System.Windows.Media.PixelFormats]::Gray8, $null, $px, $w)
    $bmp.Freeze()
    return $bmp
}
# Konsolenzeile an das Handy weitergeben (aus Out-Console)
function Add-HMRemoteLine([string]$Msg, [string]$Lvl) { if ($script:HMRemote) { try { Add-HMRemoteLineTo $script:HMRemote.S $Msg $Lvl } catch { } } }
function Show-HMRemoteMsg([string]$Text, [string]$Level = 'Warning', [switch]$Quiet, $Owner = $null) {
    Out-Console "Fernbedienung: $Text" $Level
    if (-not $Quiet) {
        $own = if ($Owner) { $Owner } else { $script:Window }
        $ic = switch ($Level) { 'Error' { 'Error' } 'Success' { 'Information' } 'Info' { 'Information' } default { 'Warning' } }
        [void][System.Windows.MessageBox]::Show($own, $Text, 'Handy-Fernbedienung', 'OK', $ic)
    }
}

# ----------------------------------------------------------------------------
# Zertifikat + Bindung (Administrator)
# ----------------------------------------------------------------------------
# CA und Server-Zertifikat fuer alle privaten IPv4-Adressen dieses PCs sicherstellen. Rueckgabe: @{ Ca; Cert; New }
function Initialize-HMRemoteCert([string[]]$Ips) {
    $ca = Get-HMRemoteCa
    if (-not $ca) { Out-Console 'Fernbedienung: eigene Zertifizierungsstelle (CA) fuer diesen PC wird angelegt ...' 'Info'; $ca = New-HMRemoteCa }
    $cert = Get-HMRemoteServerCert $ca $Ips
    $new = $false
    if (-not $cert) { $cert = New-HMRemoteServerCert $ca $Ips; $new = $true; Out-Console "Fernbedienung: Server-Zertifikat fuer $($Ips -join ', ') ausgestellt" 'Info' }
    return [pscustomobject]@{ Ca = $ca; Cert = $cert; New = $new }
}
# CA (oeffentlicher Teil) zum Server-Zertifikat - auch ohne Adminrechte lesbar
function Get-HMRemoteCaPublic($Cert) {
    if (-not $Cert) { return $null }
    return @(Get-ChildItem -Path 'Cert:\LocalMachine\My' -ErrorAction SilentlyContinue | Where-Object { $_.Subject -eq $Cert.Issuer -and $_.FriendlyName -eq $script:HMRemoteCaName } | Sort-Object NotAfter -Descending)[0]
}
# Reste eines abgestuerzten Laufs entfernen (Firewall-Regel, Bindung) - nur Administrator
function Clear-HMRemoteLeftovers {
    if (-not (Test-HMRemoteAdmin)) { return }
    $tf = Get-HMRemoteTempFile
    if (-not (Test-Path -LiteralPath $tf)) { return }
    try {
        $t = Get-Content -LiteralPath $tf -Raw -Encoding UTF8 | ConvertFrom-Json
        # laeuft die HUMig-Instanz noch, die den Vermerk geschrieben hat (z.B. andere RDP-Sitzung)? Dann nichts anfassen
        if ([int]$t.Pid -gt 0 -and [int]$t.Pid -ne $PID) {
            $pr = Get-Process -Id ([int]$t.Pid) -ErrorAction SilentlyContinue
            if ($pr -and "$($pr.ProcessName)" -match '^(powershell|pwsh|HUMig)' -and ("$($t.ProcStart)" -eq '' -or "$($pr.StartTime.ToString('s'))" -eq "$($t.ProcStart)")) { Out-Console "Fernbedienung: laeuft bereits in einer anderen HUMig-Instanz (Port $($t.Port))" 'Info'; return }
        }
        Remove-HMRemoteFirewall $script:HMRemoteRuleTemp
        $su = Read-HMRemoteSetup
        if ($t.TempBinding -and [int]$t.Port -gt 0 -and -not ($su -and [int]$su.Port -eq [int]$t.Port)) { Remove-HMRemoteBinding ([int]$t.Port) }
        Out-Console 'Fernbedienung: Reste eines frueheren Laufs entfernt (Firewall-Regel, HTTPS-Bindung)' 'Info'
    } catch { }
    Remove-Item -LiteralPath $tf -Force -ErrorAction SilentlyContinue
}

# ----------------------------------------------------------------------------
# Ein / Aus
# ----------------------------------------------------------------------------
function Start-HMRemote([switch]$Quiet, $Owner = $null) {
    if ($script:HMRemote) { return $true }
    $cfg = Get-HMRemoteConfig
    $adm = Test-HMRemoteAdmin
    $setup = Read-HMRemoteSetup
    $port = $cfg.Port
    if (-not $adm) {
        $me = ''; try { $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch { }
        if (-not $setup -or "$($setup.Sid)" -ne $me) { Show-HMRemoteMsg "Ohne Administratorrechte muss ein Administrator die Fernbedienung einmal fuer dieses Benutzerkonto einrichten (HUMig als Administrator > Einstellungen > Handy > Fuer Benutzer-Modus einrichten)." 'Warning' -Quiet:$Quiet -Owner $Owner; return $false }
        $port = [int]$setup.Port
    }
    $persist = [bool]($setup -and [int]$setup.Port -eq $port)
    # Adressen und Netzwerkprofil
    $ips = @(Get-HMRemoteIPv4List | Where-Object { $_.Private })
    if (-not $ips.Count) { Show-HMRemoteMsg 'Keine private IPv4-Adresse gefunden (10.x, 172.16-31.x, 192.168.x) - die Fernbedienung laeuft nur im lokalen Netz.' 'Warning' -Quiet:$Quiet -Owner $Owner; return $false }
    $cat = Get-HMRemoteNetCategory $ips[0].Index
    if ($cat -eq 'Public') { Show-HMRemoteMsg "Das Netzwerk '$($ips[0].Alias)' ist als 'Oeffentlich' eingestuft - dort startet die Fernbedienung nicht (z.B. fremdes WLAN). Im Firmen-/Schulnetz: Netzwerkprofil 'Privat' oder Domaene." 'Warning' -Quiet:$Quiet -Owner $Owner; return $false }
    # Port frei?
    if (-not (Test-HMRemotePortFree $port)) {
        $fp = Get-HMRemoteFreePort $port
        Show-HMRemoteMsg "Port $port ist bereits belegt (anderes Programm).$(if ($fp) { " Freier Port z.B. $fp - in Einstellungen > Handy eintragen." })" 'Warning' -Quiet:$Quiet -Owner $Owner
        return $false
    }
    $tempBind = $false; $tempFw = $false; $cert = $null; $caPub = $null
    try {
        if ($adm) {
            $b = Get-HMRemoteBinding $port
            if ($b.State -eq 'Foreign') { throw "Port $port hat bereits eine HTTPS-Bindung eines anderen Programms - anderen Port waehlen (Einstellungen > Handy)" }
            $ci = Initialize-HMRemoteCert @($ips | ForEach-Object { $_.IP })
            $cert = $ci.Cert; $caPub = $ci.Ca
            if (-not $persist) { $tempBind = $true }
            $ps0 = ''; try { $ps0 = (Get-Process -Id $PID).StartTime.ToString('s') } catch { }
            Write-HMRemoteJson (Get-HMRemoteTempFile) ([ordered]@{ Port = $port; TempBinding = $tempBind; Started = (Get-Date).ToString('yyyy-MM-dd HH:mm'); Pid = $PID; ProcStart = $ps0 })
            Set-HMRemoteBinding $port $cert.Thumbprint
            if ($persist -and "$($setup.Thumb)" -ne $cert.Thumbprint) { try { $setup.Thumb = $cert.Thumbprint; Write-HMRemoteJson (Get-HMRemoteSetupFile) $setup } catch { } }
            Remove-HMRemoteOldCerts $cert.Thumbprint -BoundPorts @($(if ($setup) { [int]$setup.Port } else { 0 }))
            if (-not $persist -or -not (Get-NetFirewallRule -Name $script:HMRemoteRuleSetup -ErrorAction SilentlyContinue)) {
                Set-HMRemoteFirewall $script:HMRemoteRuleTemp $port (Get-HMRemoteFirewallRemote $cfg.Networks); $tempFw = $true
            }
        } else {
            $b = Get-HMRemoteBinding $port
            if ($b.State -ne 'Ours') { throw 'Die HTTPS-Bindung der Fernbedienung fehlt - ein Administrator muss sie neu einrichten (Einstellungen > Handy)' }
            $cert = @(Get-ChildItem -Path 'Cert:\LocalMachine\My' -ErrorAction SilentlyContinue | Where-Object { $_.Thumbprint -eq $b.Thumb })[0]
            $caPub = Get-HMRemoteCaPublic $cert
            if ($cert) {
                $san = Get-HMRemoteCertSan $cert
                if ($san.IPs -notcontains $ips[0].IP) { Out-Console "Fernbedienung: das Zertifikat passt nicht zur aktuellen Adresse $($ips[0].IP) - HUMig einmal als Administrator starten (erneuert es automatisch)." 'Warning' }
            }
        }
    } catch {
        if ($adm) { if ($tempFw) { Remove-HMRemoteFirewall $script:HMRemoteRuleTemp }; if ($tempBind) { Remove-HMRemoteBinding $port }; Remove-Item -LiteralPath (Get-HMRemoteTempFile) -Force -ErrorAction SilentlyContinue }
        Show-HMRemoteMsg "Nicht gestartet: $($_.Exception.Message)" 'Error' -Quiet:$Quiet -Owner $Owner
        return $false
    }
    # Zustand fuer den Webserver
    $S = New-HMRemoteState
    $S.Port = $port; $S.Version = "$($script:Version)"; $S.UserMode = -not $adm
    if ($cfg.Minutes -gt 0) { $S.StopAt = (Get-Date).AddMinutes($cfg.Minutes) }
    $S.Devices = Read-HMRemoteDevices
    try { Set-HMRemoteHistory $S (Read-HMRemoteHistory) } catch { }
    # Push-Meldungen: Schluessel dieses Kontos (privat bleibt in der Oberflaeche, der Webserver kennt nur den oeffentlichen)
    $script:HMPushVapid = $null
    try { $script:HMPushVapid = Get-HMRemoteVapid; $S.PushKey = $script:HMPushVapid.Public } catch { Write-Host "[Fernbedienung] Push nicht verfuegbar: $($_.Exception.Message)" -ForegroundColor Yellow }
    $S.LogFile = Get-HMRemoteLogFile
    $S.Static = Get-HMRemoteWebFiles -Version "$($script:Version)" -Pc "$env:COMPUTERNAME" -Icon192 (New-HMRemoteIconPng 192) -Icon512 (New-HMRemoteIconPng 512) -Ca $(if ($caPub) { $caPub.RawData } else { $null })
    $core = (Join-Path $script:AppRoot 'Functions\Remote-Core.ps1') -replace "'", "''"
    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('S', $S)
    $ps = [PowerShell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript(". '$core'`nStart-HMRemoteListenerLoop `$S")
    $h = $ps.BeginInvoke()
    $script:HMRemote = @{ S = $S; PS = $ps; RS = $rs; Handle = $h; Port = $port; CaFp = (Get-HMRemoteFingerprint $caPub); Ips = @($ips | ForEach-Object { $_.IP }); Ip = $ips[0].IP; TempFw = $tempFw; TempBind = $tempBind; Admin = $adm
        StatusObj = $null; LastRefresh = [datetime]::MinValue; Started = (Get-Date); Timer = $null }
    # kurz warten: startet der Webserver nicht (z.B. Port-Freigabe fehlt), sofort melden
    for ($i = 0; $i -lt 30 -and -not $S.Listening -and $S.Run; $i++) { Start-Sleep -Milliseconds 100 }
    if (-not $S.Listening) {
        $err = if ($S.Error) { $S.Error } else { 'Webserver antwortet nicht' }
        Stop-HMRemote -Silent
        Show-HMRemoteMsg "Nicht gestartet: $err" 'Error' -Quiet:$Quiet -Owner $Owner
        return $false
    }
    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromSeconds(1)
    $t.Add_Tick({ try { Update-HMRemoteTick } catch { Write-Host "[Fernbedienung] $_" -ForegroundColor Red } })
    $script:HMRemote.Timer = $t
    Update-HMRemoteTick
    $t.Start()
    Out-Console "Fernbedienung aktiv: https://$($ips[0].IP):$port$(if ($S.StopAt) { " (bis $(([datetime]$S.StopAt).ToString('HH:mm')))" } else { ' (solange HUMig laeuft)' }) - Knopf 'Handy' unten rechts zeigt den QR-Code" 'Success'
    if (-not $script:StatusData) { $S.RefreshReq = $true }
    Update-HMRemoteButton
    return $true
}
function Stop-HMRemote([string]$Why = '', [switch]$Silent) {
    $r = $script:HMRemote
    if (-not $r) { return }
    $script:HMRemote = $null
    try { if ($r.Timer) { $r.Timer.Stop() } } catch { }
    $r.S.Run = $false
    for ($i = 0; $i -lt 30 -and $r.S.Listening; $i++) { Start-Sleep -Milliseconds 100 }
    try { if ($r.Handle.IsCompleted) { [void]$r.PS.EndInvoke($r.Handle) } } catch { }
    try { $r.PS.Dispose() } catch { }
    try { $r.RS.Dispose() } catch { }
    try { if ($r.S.DevDirty) { Save-HMRemoteDevices $r.S.Devices } } catch { }
    try { Update-HMRemotePushRuns -Final } catch { }
    try { [void](Receive-HMRemoteBg -Final) } catch { }
    if ($r.Admin) {
        if ($r.TempFw) { Remove-HMRemoteFirewall $script:HMRemoteRuleTemp }
        if ($r.TempBind) { Remove-HMRemoteBinding $r.Port }
        Remove-Item -LiteralPath (Get-HMRemoteTempFile) -Force -ErrorAction SilentlyContinue
    }
    if (-not $Silent) { Out-Console "Fernbedienung beendet$(if ($Why) { " ($Why)" })" 'Info' }
    Update-HMRemoteButton
    if ($script:HMRemoteDlg) { try { Update-HMRemoteDialog } catch { } }
}

# jede Sekunde (Oberflaeche): Schnappschuss ablegen, Aktionen vom Handy ausfuehren
function Update-HMRemoteTick {
    $r = $script:HMRemote; if (-not $r) { return }
    $S = $r.S
    if (-not $S.Listening -and $S.Error) { $e = $S.Error; Stop-HMRemote -Silent; Out-Console "Fernbedienung beendet: $e" 'Error'; return }
    if ($S.StopAt -and (Get-Date) -ge [datetime]$S.StopAt) { Stop-HMRemote 'eingestellte Laufzeit abgelaufen'; return }
    # Ereignisse vom Webserver
    while ($S.Events.Count -gt 0) {
        $ev = $S.Events.Dequeue()
        switch ("$($ev.Kind)") {
            'Paired' { Out-Console "Fernbedienung: Handy '$($ev.Name)' gekoppelt ($($ev.Ip))" 'Success' }
            'PairLocked' { Out-Console 'Fernbedienung: Kopplung gesperrt - 5 falsche Codes. Im Fenster Handy einen neuen Code erzeugen.' 'Warning' }
            'Unpaired' { Out-Console "Fernbedienung: Handy '$($ev.Name)' hat sich entkoppelt" 'Info' }
        }
    }
    if ($S.Pair -and $S.Pair.Until -lt (Get-Date)) { Close-HMRemotePairing $S }
    # Abbrechen vom Handy (dort bestaetigt)
    $cr = $S.CancelReq
    if ($cr) {
        $S.CancelReq = $null
        if ($script:CurrentJob) { Out-Console "Abbruch vom Handy '$($cr.By)' ($($cr.Ip))" 'Warning'; Invoke-HMJobCancel -Confirmed }
    }
    # Startseite neu berechnen (hoechstens alle 30 s)
    if ($S.RefreshReq) {
        $S.RefreshReq = $false
        if (((Get-Date) - $r.LastRefresh).TotalSeconds -ge 30) {
            $r.LastRefresh = Get-Date
            [void]$script:Window.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{ try { Update-HMStatusPage } catch { } })
        }
    }
    if ($script:StatusData -and -not [object]::ReferenceEquals($script:StatusData, $r.StatusObj)) {
        $r.StatusObj = $script:StatusData
        try { $S.StatusJson = ConvertTo-HMRemoteStatusJson $script:StatusData } catch { }
    }
    $S.JobJson = ConvertTo-HMRemoteJobJson $script:CurrentJob "$($script:JobTitle)" $script:HMRemoteLast -Mon $script:MonSnap
    try { Update-HMRemotePushRuns } catch { }
    # Zeitplaene vom Handy: Anfrage ausfuehren, Liste regelmaessig im Hintergrund lesen (bei beobachteten Laeufen oefter)
    try { Invoke-HMRemoteSchedReq $S } catch { Out-Console "Zeitplan-Start vom Handy: $($_.Exception.Message)" 'Warning' }
    if (Test-HMRemoteSchedAny) {
        $iv = if (@($script:HMSchedWatch | Where-Object { $_.At -gt (Get-Date).AddMinutes(-10) }).Count) { 20 } elseif ($script:HMSchedWatch.Count) { 60 } else { 120 }
        if (-not $r.SchedAt -or ((Get-Date) - $r.SchedAt).TotalSeconds -ge $iv) { $r.SchedAt = Get-Date; try { Start-HMRemoteSchedScan } catch { } }
    } elseif ("$($S.SchedJson)" -ne '[]') { $S.SchedMap = [hashtable]::Synchronized(@{}); $S.SchedJson = '[]' }
    # Zusatzanzeigen (App-Updates je PC, Server-Backup-Kachel) hoechstens alle 2 Minuten bzw. nach neuem Status
    $volNew = $false; try { $volNew = Receive-HMRemoteBg } catch { }
    if ($volNew) {
        # neue Datentraeger-Daten: nur die Zusatzanzeige neu (ohne neue Abfrage und ohne den 2-Minuten-Takt zu verschieben)
        try { $S.ExtraJson = ConvertTo-Json -Compress -Depth 6 -InputObject (Get-HMRemoteExtra -NoQuery) } catch { }
    }
    if (-not $r.ExtraAt -or ((Get-Date) - $r.ExtraAt).TotalSeconds -ge 120 -or -not [object]::ReferenceEquals($script:StatusData, $r.ExtraObj)) {
        $r.ExtraAt = Get-Date; $r.ExtraObj = $script:StatusData
        try { $S.ExtraJson = ConvertTo-Json -Compress -Depth 6 -InputObject (Get-HMRemoteExtra) } catch { }
        try { Test-HMRemoteAuSchedule } catch { }
    }
    if ($S.DevDirty) { $S.DevDirty = $false; try { Save-HMRemoteDevices $S.Devices } catch { } }
    if ($script:HMRemoteDlg) { try { Update-HMRemoteDialog } catch { } }
}

# ----------------------------------------------------------------------------
# Verlauf der letzten Vorgaenge (Handy): %APPDATA%\HUMig\remote-history.json, hoechstens 10
# ----------------------------------------------------------------------------
function Get-HMRemoteHistFile { return (Join-Path $env:APPDATA 'HUMig\remote-history.json') }
function Read-HMRemoteHistory {
    try {
        $f = Get-HMRemoteHistFile
        if (Test-Path -LiteralPath $f -PathType Leaf) { return @(Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json | ForEach-Object { $_ } | Where-Object { $_ } | Select-Object -First 10) }
    } catch { }
    return @()
}
# Bericht zu einem Vorgang: von OnFinished gesetzt ($script:JobReport) oder aus dem Ergebnis (Restore: Datei, Server-Backup: Ordner)
function Get-HMRemoteReportPath($Job) {
    if ($script:JobReport) { return "$($script:JobReport)" }
    $rp = "$($Job.Result.Report)"
    if (-not $rp) { return '' }
    if ($rp -match '\.html?$') { return $rp }
    return ("$($rp.TrimEnd('\'))\Bericht.html")   # ohne Join-Path: Platte evtl. schon ausgeworfen
}
# Ordner fuer lokale Kopien von Berichten (Profil des Kontos). HUMig laeuft meist erhoeht, der Ordner ist fuer das Konto auch
# ohne Erhoehung beschreibbar: ist ein Teil des Pfads eine Verknuepfung (Junction/Symlink), wird nichts kopiert oder geloescht.
function Get-HMRemoteReportDir([switch]$Create) {
    if (-not $env:LOCALAPPDATA) { return '' }
    $b = "$($env:LOCALAPPDATA)\HUMig"; $d = "$b\remote-reports"
    try {
        if ($Create -and -not (Test-Path -LiteralPath $d)) { [void](New-Item -ItemType Directory -Path $d -Force) }
        foreach ($x in @($b, $d)) {
            if (-not (Test-Path -LiteralPath $x)) { return '' }
            if ((Get-Item -LiteralPath $x -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { return '' }
        }
        return $d
    } catch { return '' }
}
# lokale Kopien entfernen, die nicht mehr im Verlauf stehen (nur eigene Namen <8 hex>.html, keine Verknuepfungen)
function Clear-HMRemoteReportCopies($List) {
    try {
        $ld = Get-HMRemoteReportDir
        if (-not $ld) { return }
        $keep = @($List | Where-Object { $_ } | ForEach-Object { "$($_.Id).html" })
        foreach ($x in @(Get-ChildItem -LiteralPath $ld -Filter '*.html' -File -Force -ErrorAction SilentlyContinue)) {
            if ($x.Name -notmatch '^[0-9a-f]{8}\.html$' -or $keep -contains $x.Name) { continue }
            if ($x.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            # Ordner kann zwischenzeitlich getauscht worden sein: Datei muss noch im geprueften Ordner liegen
            if (-not (Get-HMRemoteReportDir) -or (([IO.Path]::GetDirectoryName($x.FullName) -replace '[\\/]+', '\').TrimEnd('\') -ne ($ld -replace '[\\/]+', '\').TrimEnd('\'))) { return }
            Remove-Item -LiteralPath $x.FullName -Force -ErrorAction SilentlyContinue
        }
    } catch { }
}
# Netzpfad (UNC oder verbundenes Netzlaufwerk)?
function Test-HMRemoteNetPath([string]$Path) {
    if ($Path -match '^\\\\') { return $true }
    if ($Path -match '^([A-Za-z]):') { try { return ((New-Object IO.DriveInfo($Matches[1])).DriveType -eq [IO.DriveType]::Network) } catch { return $false } }
    return $false
}
function Add-HMRemoteHistory($Job, [string]$Title, [string]$Result, [string]$Code, $Res) {
    $lvl = switch ($Code) { 'OK' { 'OK' } 'Created' { 'OK' } 'Warning' { 'Warning' } 'NoCatalog' { 'Warning' } 'Cancelled' { 'Info' } default { 'Error' } }
    $rb = Get-HMRemoteRandomBytes 4   # liefert ,@() - erst zuweisen
    $bytes = [long]0
    try { if ($Res -and $Res.SizeBytes) { $bytes = [long]$Res.SizeBytes } elseif ($Res -and $Res.Total) { $bytes = [long]$Res.Total } elseif ($Job.DoneBytes) { $bytes = [long]$Job.DoneBytes } } catch { }
    $e = [pscustomobject][ordered]@{
        Id = (-join ($rb | ForEach-Object { $_.ToString('x2') })); Title = $Title; Result = $Result; Level = $lvl
        Time = (Get-Date).ToString('yyyy-MM-dd HH:mm'); Seconds = [int]($(if ($Job.Ended) { [datetime]$Job.Ended } else { Get-Date }) - $Job.Started).TotalSeconds; Bytes = $bytes; Report = (Get-HMRemoteReportPath $Job)
    }
    # Bericht auf Netzpfad: hier NICHT anfassen (Freigabe evtl. weg - Oberflaeche wuerde haengen). Bei laufender Fernbedienung
    # im Hintergrund lokal kopieren und danach eintragen; der Webserver liest nie von einer Freigabe.
    $netSrc = ''
    if ($e.Report -and (Test-HMRemoteNetPath $e.Report)) { $netSrc = "$($e.Report)"; $e.Report = '' }
    $list = @(@($e) + @(Read-HMRemoteHistory) | Select-Object -First 10)
    Clear-HMRemoteReportCopies $list
    if ($netSrc -and $script:HMRemote) {
        $ld = Get-HMRemoteReportDir -Create
        if ($ld) {
            [void](Start-HMRemoteBg 'Copy' {
                    param($src, $dst)
                    # unmittelbar vor dem Kopieren nochmals: Zielordner und HUMig-Ordner keine Verknuepfung
                    $dd = [IO.Path]::GetDirectoryName($dst)
                    foreach ($x in @([IO.Path]::GetDirectoryName($dd), $dd)) { if ((Get-Item -LiteralPath $x -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { return 'NO' } }
                    $fi = New-Object IO.FileInfo($src)
                    if (-not $fi.Exists -or $fi.Length -gt 10MB -or $fi.Extension -notin @('.html', '.htm')) { return 'NO' }
                    [IO.File]::Copy($fi.FullName, $dst, $true)
                    return 'OK'
                } @($netSrc, "$ld\$($e.Id).html") @{ Id = "$($e.Id)"; Dst = "$ld\$($e.Id).html" } 120)
        }
    }
    try {
        $f = Get-HMRemoteHistFile; $d = Split-Path $f -Parent
        if (-not (Test-Path -LiteralPath $d)) { [void](New-Item -ItemType Directory -Path $d -Force) }
        [IO.File]::WriteAllText($f, (ConvertTo-Json -InputObject @($list) -Depth 3), (New-Object Text.UTF8Encoding $false))
    } catch { }
    if ($script:HMRemote) { Set-HMRemoteHistory $script:HMRemote.S $list }
}
# Verlauf an den Webserver geben: Anzeige ohne Pfade, Pfade nur in der Zuordnung Kennung -> Bericht
function Set-HMRemoteHistory($S, $List) {
    $map = [hashtable]::Synchronized(@{})   # neu aufbauen und dann tauschen (Webserver liest gleichzeitig)
    $out = @()
    foreach ($x in @($List | Where-Object { $_ })) {
        # Netzpfade (z. B. Verlauf aus 2.1.1) nie an den Webserver - er wuerde bei getrennter Freigabe haengen
        $has = [bool]("$($x.Report)" -and "$($x.Id)" -match '^[0-9a-f]{8}$' -and -not (Test-HMRemoteNetPath "$($x.Report)"))
        if ($has) { $map["$($x.Id)"] = "$($x.Report)" }
        $sec = 0; $by = [long]0
        try { $sec = [int]$x.Seconds } catch { }; try { $by = [long]$x.Bytes } catch { }   # defekter Eintrag soll nicht den ganzen Verlauf leeren
        $out += [ordered]@{ id = "$($x.Id)"; title = "$($x.Title)"; result = "$($x.Result)"; level = "$($x.Level)"; time = "$($x.Time)"; sec = $sec; bytes = $by; report = $has }
    }
    $S.Reports = $map
    $S.HistJson = ConvertTo-Json -Compress -Depth 3 -InputObject @($out)
}

# ----------------------------------------------------------------------------
# Zusatzanzeigen fuer das Handy: App-Updates je PC, Server-Backup-Kachel
# ----------------------------------------------------------------------------
function Get-HMRemoteExtra([switch]$NoQuery) {
    $o = [ordered]@{ apps = @(); sb = @() }
    if ($script:UserMode) { return $o }
    # --- App-Updates: Verlauf (letzte 7 Tage), letzte Suche (diese Sitzung), Zeitplan (gelesen bzw. dieser PC)
    $h = @()
    try { if ($script:AuHistFile -and (Test-Path -LiteralPath $script:AuHistFile)) { $h = @(Get-Content -LiteralPath $script:AuHistFile -Raw -Encoding UTF8 | ConvertFrom-Json | ForEach-Object { $_ }) } } catch { }
    # Zeitplan-Laeufe dieses PCs direkt dazu (auch wenn noch nicht in den Verlauf uebernommen) - doppelte Eintraege auslassen
    $have = @{}; foreach ($x in @($h | Where-Object { $_ })) { $have["$($x.Date)|$("$($x.Computer)".ToUpperInvariant())|$($x.Id)"] = $true }
    foreach ($x in @(Read-HMRemoteLocalAuHistory)) { $hk = "$($x.Date)|$("$($x.Computer)".ToUpperInvariant())|$($x.Id)"; if (-not $have.ContainsKey($hk)) { $have[$hk] = $true; $h += $x } }
    $since = (Get-Date).AddDays(-7).ToString('yyyy-MM-dd HH:mm')
    $pcs = @{}
    foreach ($x in @($h | Where-Object { $_ -and "$($_.Date)" -ge $since })) { $k = "$($x.Computer)".ToUpperInvariant(); if (-not $pcs[$k]) { $pcs[$k] = @() }; $pcs[$k] += $x }
    if ($script:AuLastSearch) { foreach ($k in @($script:AuLastSearch.ByPc.Keys)) { if (-not $pcs.ContainsKey("$k".ToUpperInvariant())) { $pcs["$k".ToUpperInvariant()] = @() } } }
    if ($script:AuSchedData) { foreach ($k in @($script:AuSchedData.Keys)) { if (-not $pcs.ContainsKey("$k".ToUpperInvariant())) { $pcs["$k".ToUpperInvariant()] = @() } } }
    $loc = Read-HMRemoteLocalAuLast
    if ($loc -and -not $pcs.ContainsKey("$env:COMPUTERNAME".ToUpperInvariant())) { $pcs["$env:COMPUTERNAME".ToUpperInvariant()] = @() }
    foreach ($k in @($pcs.Keys | Sort-Object)) {
        $g = @($pcs[$k])
        # offene Fehler: spaeter erfolgreich aktualisierte bzw. laut letzter Suche nicht mehr anstehende Apps fallen weg
        $bad = @(Get-HMAuOpenFailures $g $script:AuLastSearch | Sort-Object Date -Descending)
        $e = [ordered]@{ pc = $k; ok = @($g | Where-Object { "$($_.Status)" -eq 'OK' }).Count; failed = $bad.Count; last = "$(@($g | Sort-Object Date -Descending | Select-Object -First 1).Date)"
            fails = @($bad | Select-Object -First 5 | ForEach-Object { [ordered]@{ name = "$($_.Name)"; text = "$($_.Text)"; date = "$($_.Date)" } }) }
        if ($script:AuLastSearch -and $script:AuLastSearch.ByPc.ContainsKey($k)) { $e.found = [int]$script:AuLastSearch.ByPc[$k]; $e.foundAt = "$($script:AuLastSearch.Time)" }
        $sd = $null; if ($script:AuSchedData) { foreach ($sk in @($script:AuSchedData.Keys)) { if ("$sk".ToUpperInvariant() -eq $k) { $sd = $script:AuSchedData[$sk] } } }
        if ($sd -and $sd.PSObject.Properties['Exists'] -and $sd.Exists) { $e.sched = [ordered]@{ when = "$($sd.When)"; next = "$($sd.Next)"; last = "$($sd.Last)"; result = "$($sd.Summary)" } }
        elseif ($k -eq "$env:COMPUTERNAME".ToUpperInvariant() -and $loc) { $e.sched = [ordered]@{ when = ''; next = ''; last = "$($loc.Date)"; result = ("{0} gefunden, {1} OK, {2} Fehler" -f [int]$loc.Found, [int]$loc.Ok, [int]$loc.Err) } }
        $o.apps += $e
    }
    # --- Server-Backup: naechste Platte laut Rotation, angesteckte Platten (Bezeichnung, frei)
    # nur mit Server-Backup-Profilen; Abfrage im Hintergrund (schlafende USB-Platte haelt die Oberflaeche nicht an), Ergebnis des letzten Laufs
    $vols = @()
    if (@($script:StatusData.Server | Where-Object { $_ }).Count) {
        if ($script:HMRemoteVols) { $vols = @($script:HMRemoteVols) }
        if (-not $NoQuery -and -not (Test-HMRemoteBgBusy 'Vol')) {
            [void](Start-HMRemoteBg 'Vol' {
                    @(Get-CimInstance -Namespace 'root/Microsoft/Windows/Storage' -ClassName MSFT_Volume -OperationTimeoutSec 5 -ErrorAction Stop |
                        Where-Object { "$($_.FileSystemLabel)" -and "$($_.DriveLetter)" -match '^[A-Za-z]$' } |
                        ForEach-Object { [pscustomobject]@{ FileSystemLabel = "$($_.FileSystemLabel)"; DriveLetter = "$($_.DriveLetter)"; SizeRemaining = [long]$_.SizeRemaining; Size = [long]$_.Size } })
                } @() @{} 60)
        }
    }
    foreach ($p in @($script:StatusData.Server | Where-Object { $_ })) {
        $rot = @($p.Disks | Where-Object { $_ -and -not $_.Archive })
        $nx = @($rot | Where-Object { $null -eq $_.Age })[0]
        if (-not $nx) { $nx = @($rot | Sort-Object { [int]$_.Age } -Descending)[0] }
        $conn = @()
        foreach ($d in @($p.Disks | Where-Object { $_ })) {
            $v = @($vols | Where-Object { "$($_.FileSystemLabel)" -eq "$($d.Label)" })[0]
            if ($v) { $conn += [ordered]@{ label = "$($d.Label)"; drive = "$($v.DriveLetter):"; free = [long]$v.SizeRemaining; size = [long]$v.Size } }
        }
        $o.sb += [ordered]@{ name = "$($p.Name)"; next = "$(if ($nx) { $nx.Label })"; conn = @($conn); archiveAge = $p.ArchiveAge }
    }
    return $o
}
# Hintergrund-Arbeiten der Fernbedienung (Datentraeger lesen, Bericht kopieren) - die Oberflaeche wartet nie darauf.
# Abholung im UI-Timer (Receive-HMRemoteBg); haengt eine Arbeit, wird sie abgebrochen und erst nach Ende des Abbruchs entsorgt.
$script:HMRemoteBg = New-Object System.Collections.ArrayList
function Start-HMRemoteBg([string]$Kind, [scriptblock]$Script, [object[]]$Arguments, [hashtable]$Data, [int]$LimitSec) {
    try {
        $ps = [powershell]::Create()
        [void]$ps.AddScript($Script)
        foreach ($a in @($Arguments)) { [void]$ps.AddArgument($a) }
        [void]$script:HMRemoteBg.Add(@{ Kind = $Kind; PS = $ps; Handle = $ps.BeginInvoke(); Started = Get-Date; Limit = $LimitSec; Data = $Data; StopH = $null })
        return $true
    } catch { return $false }
}
# laeuft (oder wird gerade abgebrochen) eine Arbeit dieser Art? Dann keine neue starten
function Test-HMRemoteBgBusy([string]$Kind) { return [bool](@($script:HMRemoteBg | Where-Object { $_.Kind -eq $Kind }).Count) }
# Ergebnisse uebernehmen; $true wenn die Zusatzanzeige neu berechnet werden soll. -Final: beim Ausschalten nicht warten
function Receive-HMRemoteBg([switch]$Final) {
    $refresh = $false
    foreach ($run in @($script:HMRemoteBg)) {
        if ($run.StopH) {
            if ($run.StopH.IsCompleted) { try { $run.PS.EndStop($run.StopH) } catch { }; try { $run.PS.Dispose() } catch { }; $script:HMRemoteBg.Remove($run) }
            elseif ($Final) { $script:HMRemoteBg.Remove($run) }
            continue
        }
        if (-not $run.Handle.IsCompleted) {
            if ($Final -or ((Get-Date) - $run.Started).TotalSeconds -ge $run.Limit) {
                try { $run.StopH = $run.PS.BeginStop($null, $null) } catch { try { $run.PS.Dispose() } catch { }; $script:HMRemoteBg.Remove($run); continue }
                if ($Final) { $script:HMRemoteBg.Remove($run) }
            }
            continue
        }
        $res = @(); $ok = $true; $endOk = $true
        try { $res = @($run.PS.EndInvoke($run.Handle)) } catch { $ok = $false; $endOk = $false }
        try { if ($run.PS.HadErrors) { $ok = $false } } catch { }
        try { $run.PS.Dispose() } catch { }
        $script:HMRemoteBg.Remove($run)
        switch ($run.Kind) {
            # nur bei Erfolg uebernehmen - sonst bleiben die zuletzt bekannten Platten stehen (z. B. schlafende Platte, Zeitlimit)
            'Vol' { if ($ok) { $script:HMRemoteVols = $res; $refresh = $true } }
            'Copy' { if ($ok -and "$($res | Select-Object -Last 1)" -eq 'OK') { Set-HMRemoteHistoryReport $run.Data.Id $run.Data.Dst } }
            'SchedScan' {
                $sr = @($res | Where-Object { $_ -is [hashtable] })[0]
                # Zeitplan-Skript faengt eigene Fehler ab: Ergebnis zaehlt, wenn es geliefert wurde (HadErrors kann durch abgefangene Fehler gesetzt sein)
                if ($endOk -and $sr -and $script:HMRemote) { Set-HMRemoteSchedList $script:HMRemote.S $sr; Update-HMRemoteSchedWatch $sr }
            }
            'SchedRun' { if ($script:HMRemote) { Receive-HMRemoteSchedRun $script:HMRemote.S $res $endOk $run.Data } }
        }
    }
    return $refresh
}
# Kopie fertig: Bericht beim Eintrag nachtragen (nur wenn der Eintrag noch im Verlauf steht)
function Set-HMRemoteHistoryReport([string]$Id, [string]$Path) {
    $list = @(Read-HMRemoteHistory)
    $hit = $false
    foreach ($x in $list) { if ($x -and "$($x.Id)" -eq $Id) { $x.Report = $Path; $hit = $true } }
    if (-not $hit) { return }
    try { [IO.File]::WriteAllText((Get-HMRemoteHistFile), (ConvertTo-Json -InputObject @($list) -Depth 3), (New-Object Text.UTF8Encoding $false)) } catch { }
    if ($script:HMRemote) { Set-HMRemoteHistory $script:HMRemote.S $list }
}
# ----------------------------------------------------------------------------
# Zeitplaene vom Handy starten (Einstellungen > Handy, je Art einzeln, Standard aus)
# Liste und Pruefung laufen im Hintergrund (Aufgabenplanung kann haengen). Gestartet wird nur eine Aufgabe, die
# exakt dem entspricht, was HUMig selbst anlegt: Ordner, Konto, genau eine Aktion mit HUMigs eigenem Skript.
# Das Handy kennt nur eine zufaellige Kennung je Listenaufbau - Pfade/Namen/Optionen kommen nie vom Handy.
# ----------------------------------------------------------------------------
$script:HMSchedScript = {
    param([string]$Mode, [hashtable]$Kinds, [string]$AppRoot, [bool]$Admin, [string]$Key, [string[]]$AdminSids = @())
    $ErrorActionPreference = 'Stop'
    $sysPs = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    function Get-SidOf([string]$u) {
        if ($u -match '^S-1-') { return $u }
        try { return (New-Object Security.Principal.NTAccount($u)).Translate([Security.Principal.SecurityIdentifier]).Value } catch { return '' }
    }
    # Ordner/Datei duerfen nur SYSTEM, Administratoren, TrustedInstaller, CREATOR OWNER und Konten, die selbst Administrator
    # sind, veraendern (Freigabeliste wie die Pruefung des Programmordners beim Start); Besitzer ebenso. Sonst: nicht sicher.
    $safe = @('S-1-5-18', 'S-1-5-32-544', 'S-1-3-0', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464') + @($AdminSids | Where-Object { $_ })
    function Test-NoUserWrite([string]$p) {
        if (-not (Test-Path -LiteralPath $p)) { return $false }
        $mask = 0x2 -bor 0x4 -bor 0x40 -bor 0x100 -bor 0x10 -bor 0x10000 -bor 0x40000 -bor 0x80000 -bor 0x10000000 -bor 0x40000000
        try {
            $acl = Get-Acl -LiteralPath $p
            $own = ''; try { $own = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value } catch { return $false }
            if ($safe -notcontains $own) { return $false }
            foreach ($a in @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))) {
                if ("$($a.AccessControlType)" -ne 'Allow') { continue }
                if (-not (([int64][int]$a.FileSystemRights) -band $mask)) { continue }
                if ($safe -notcontains "$($a.IdentityReference.Value)") { return $false }
            }
            return $true
        } catch { return $false }
    }
    # Uebergeordnete Ordner bis zum Laufwerk: niemand ausser der Freigabeliste darf sie umbenennen/ersetzen
    # (Loeschen, Unterordner loeschen, Rechte/Besitzer aendern, Vollzugriff; Besitzer ebenso) - sonst koennte ein
    # Benutzer den abgesicherten Ordner wegbenennen und einen eigenen gleichen Namens hinlegen
    function Test-ParentsSafe([string]$p) {
        try {
            $d = [IO.DirectoryInfo]$p
            if ($d.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $false }   # Verknuepfung: Kette dahinter unbekannt
            $d = $d.Parent
            while ($d) {
                if ($d.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $false }
                # Laufwerkswurzel laesst sich nicht umbenennen: dort zaehlt Loeschen nicht (D:\ hat standardmaessig "Aendern")
                $mask = 0x40 -bor 0x40000 -bor 0x80000 -bor 0x10000000
                if ($d.Parent) { $mask = $mask -bor 0x10000 }
                $acl = Get-Acl -LiteralPath $d.FullName
                $own = ''; try { $own = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value } catch { return $false }
                if ($safe -notcontains $own) { return $false }
                foreach ($a in @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))) {
                    if ("$($a.AccessControlType)" -ne 'Allow') { continue }
                    if (([int]$a.PropagationFlags) -band 2) { continue }   # InheritOnly: gilt nicht fuer diesen Ordner selbst
                    if (-not (([int64][int]$a.FileSystemRights) -band $mask)) { continue }
                    if ($safe -notcontains "$($a.IdentityReference.Value)") { return $false }
                }
                $d = $d.Parent
            }
            return $true
        } catch { return $false }
    }
    function Test-SafeName([string]$n) { return ($n -and $n -notmatch '[*?\[\]]') }
    # genau eine Aktion, erwartetes Programm, Argumente genau so, wie HUMig sie anlegt (verankert, kein -Command, kein zweites -File)
    function Test-Act($t, [string[]]$Exe, [string]$ArgRx) {
        $acts = @($t.Actions)
        if ($acts.Count -ne 1) { return $false }
        $x = "$($acts[0].Execute)".Trim('"')
        if (-not @($Exe | Where-Object { $_ -and [string]::Equals($_, $x, [StringComparison]::OrdinalIgnoreCase) }).Count) { return $false }
        return ("$($acts[0].Arguments)".Trim() -match $ArgRx)   # Muster ist verankert (^...$): nichts davor/danach erlaubt
    }
    $hd = '(?i)^-NoProfile -ExecutionPolicy Bypass (-WindowStyle Hidden )?-File "'
    function Get-Info($t) {
        $o = @{ Running = ("$($t.State)" -in @('Running', 'Queued')); Disabled = ("$($t.State)" -eq 'Disabled'); Next = ''; Last = ''; LastRun = $null; Result = $null }
        try {
            $i = Get-ScheduledTaskInfo -TaskPath $t.TaskPath -TaskName $t.TaskName
            if ($i.NextRunTime) { $o.Next = $i.NextRunTime.ToString('dd.MM. HH:mm') }
            if ($i.LastRunTime -and $i.LastRunTime.Year -gt 2000) { $o.Last = $i.LastRunTime.ToString('dd.MM. HH:mm'); $o.LastRun = $i.LastRunTime; $o.Result = [int64]$i.LastTaskResult }
        } catch { }
        return $o
    }
    $out = New-Object System.Collections.ArrayList
    # --- Profil-Backups dieses Kontos (nur ohne Adminrechte angelegte - RunLevel Limited)
    if ($Kinds.Backup) { try {
        $cur = [Security.Principal.WindowsIdentity]::GetCurrent()
        $me = $cur.User.Value; $meName = "$($cur.Name)"; $meShort = ($meName -split '\\')[-1]
        $dir = Join-Path $env:LOCALAPPDATA 'HUMig\Zeitplaene'
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
            $d = $null; try { $d = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
            if (-not $d -or "$($d.Id)" -notmatch '^[A-Za-z0-9]{8,40}$' -or -not (Test-SafeName "$($d.TaskName)") -or -not (Test-SafeName "$($d.TaskPath)")) { continue }
            $o = @{ Kind = 'Backup'; Title = "$($d.Name)"; TaskPath = "$($d.TaskPath)"; TaskName = "$($d.TaskName)"; Problem = ''; As = 'Benutzer' }
            $t = $null
            if ("$($d.TaskPath)" -match '^\\') { try { $t = Get-ScheduledTask -TaskPath "$($d.TaskPath)" -TaskName "$($d.TaskName)" -ErrorAction Stop } catch { $t = $null } }
            if (-not $t) { $o.Problem = 'Aufgabe fehlt' }
            elseif ([bool]$d.Elevated -or "$($t.Principal.RunLevel)" -ne 'Limited') { continue }   # mit Adminrechten angelegt: vom Handy vorerst nicht
            elseif ("$($d.Computer)" -ne "$env:COMPUTERNAME" -or "$($d.Sid)" -ne $me) { $o.Problem = 'Aufgabe gehoert nicht zu diesem Konto' }
            elseif ((Get-SidOf "$($t.Principal.UserId)") -ne $me -and -not [string]::Equals("$($t.Principal.UserId)", $meName, [StringComparison]::OrdinalIgnoreCase) -and -not [string]::Equals("$($t.Principal.UserId)", $meShort, [StringComparison]::OrdinalIgnoreCase)) { $o.Problem = 'Aufgabe gehoert nicht zu diesem Konto' }   # Vergleich nur mit dem angemeldeten Konto (nicht mit der Zeitplan-Datei)
            elseif (-not (Test-Act $t @($sysPs) ($hd + [regex]::Escape("$AppRoot\Functions\Backup-Task.ps1") + '" -Id ' + [regex]::Escape("$($d.Id)") + '\z'))) { $o.Problem = 'Aufgabe veraendert - am PC pruefen' }
            if ($t) { $o.Info = Get-Info $t; $o.Task = $t }
            $o.Key = "B|$($o.TaskPath)|$($o.TaskName)"
            [void]$out.Add($o)
        }
    } catch { } }
    # --- Server-Backup (SYSTEM) und App-Updates dieses PCs (SYSTEM): nur als Administrator
    $wb = $false; try { $wb = ("$((Get-Service -Name wbengine -ErrorAction Stop).Status)" -eq 'Running') } catch { }
    if ($Admin -and $Kinds.Server) { try {
        $progOk = (Test-NoUserWrite $AppRoot) -and (Test-NoUserWrite "$AppRoot\Functions") -and (Test-NoUserWrite "$AppRoot\Config") -and (Test-ParentsSafe $AppRoot)
        if ($progOk -and (Test-Path -LiteralPath "$AppRoot\Config\ServerBackup") -and -not (Test-NoUserWrite "$AppRoot\Config\ServerBackup")) { $progOk = $false }
        if ($progOk) { foreach ($x in @(Get-ChildItem -LiteralPath "$AppRoot\Functions" -Filter '*.ps1' -File)) { if (-not (Test-NoUserWrite $x.FullName)) { $progOk = $false; break } } }
        if ($progOk -and (Test-Path -LiteralPath "$AppRoot\Config\serverbackup.json") -and -not (Test-NoUserWrite "$AppRoot\Config\serverbackup.json")) { $progOk = $false }
        $cfg = $null; try { $cfg = Get-Content -LiteralPath "$AppRoot\Config\serverbackup.json" -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
        $tasks = @(); try { $tasks = @(Get-ScheduledTask -TaskPath '\HUMig\' -ErrorAction Stop | Where-Object { $_.TaskName -like 'Server-Backup*' }) } catch { }
        foreach ($t in $tasks) {
            $o = @{ Kind = 'Server'; Title = "$($t.TaskName)"; TaskPath = "$($t.TaskPath)"; TaskName = "$($t.TaskName)"; Problem = ''; As = 'SYSTEM'; Info = (Get-Info $t); Task = $t }
            $prof = ''
            if ("$(@($t.Actions)[0].Arguments)" -match '-ProfileName "([^"]+)"') {
                $n = $Matches[1]
                for ($i = 0; $i -lt 20 -and $cfg; $i++) { $r = @(@($cfg.Renames) | Where-Object { $_ -and "$($_.Old)" -eq $n })[0]; if (-not $r) { break }; $n = "$($r.New)" }
                if ($cfg -and @(@($cfg.Profiles) | Where-Object { $_ -and "$($_.Name)" -eq $n }).Count) { $prof = $n }
            }
            if ("$($t.TaskPath)" -ne '\HUMig\' -or (Get-SidOf "$($t.Principal.UserId)") -ne 'S-1-5-18') { $o.Problem = 'Aufgabe veraendert - am PC pruefen' }
            elseif (-not (Test-SafeName "$($t.TaskName)") -or -not (Test-Act $t @($sysPs) ($hd + [regex]::Escape("$AppRoot\Functions\ServerBackup-Task.ps1") + '" -ProfileName "[^"]+"( -VMs "[^"]*")?( -Volumes "[^"]*")?( -HostConfig)?( -HostSystem)?( -NoVerify)?( -Explicit)?( -DiskLabel "[A-Za-z0-9_\-]{1,32}")?\z'))) { $o.Problem = 'Aufgabe veraendert - am PC pruefen' }
            elseif (-not $prof) { $o.Problem = 'Profil nicht gefunden' }
            elseif (-not $progOk) { $o.Problem = 'Programmordner fuer Benutzer beschreibbar - Start vom Handy gesperrt' }
            $o.Title = ("$($t.TaskName)" -replace '^Server-Backup - ', '')
            $o.Server = $true
            $o.Key = "S|$($o.TaskPath)|$($o.TaskName)"
            [void]$out.Add($o)
        }
    } catch { } }
    if ($Admin -and $Kinds.Au) { try {
        $t = $null; try { $t = Get-ScheduledTask -TaskPath '\HUMig\' -TaskName 'HUMig App-Updates' -ErrorAction Stop } catch { $t = $null }
        if ($t) {
            $auDir = Join-Path $env:ProgramData 'HUMig\AppUpdates\auto'
            $pw7 = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
            $pwH = Join-Path $env:ProgramFiles 'HUMig\PowerShell7\pwsh.exe'
            $o = @{ Kind = 'Au'; Title = 'App-Updates dieses PCs'; TaskPath = "$($t.TaskPath)"; TaskName = "$($t.TaskName)"; Problem = ''; As = 'SYSTEM'; Info = (Get-Info $t); Task = $t }
            if ((Get-SidOf "$($t.Principal.UserId)") -ne 'S-1-5-18' -or -not (Test-Act $t @($pw7, $pwH, $sysPs) ('(?i)^-NoProfile -ExecutionPolicy Bypass -File "' + [regex]::Escape("$auDir\auto.ps1") + '"\z'))) { $o.Problem = 'Aufgabe veraendert - am PC pruefen' }
            else {
                $x = "$(@($t.Actions)[0].Execute)".Trim('"')
                foreach ($p in @($auDir, "$auDir\auto.ps1", "$auDir\config.json", (Split-Path $x -Parent), $x)) { if ((Test-Path -LiteralPath $p) -and -not (Test-NoUserWrite $p)) { $o.Problem = 'Ordner fuer Benutzer beschreibbar - Start vom Handy gesperrt'; break } }
                if (-not $o.Problem -and (-not (Test-ParentsSafe $auDir) -or -not (Test-ParentsSafe (Split-Path $x -Parent)))) { $o.Problem = 'Ordner fuer Benutzer beschreibbar - Start vom Handy gesperrt' }
            }
            $o.Key = "A|$($o.TaskPath)|$($o.TaskName)"
            [void]$out.Add($o)
        }
    } catch { } }
    if ($Mode -ne 'Run') { return @{ Items = @($out); Wb = $wb } }
    # --- Start: dieselbe Aufgabe frisch gefunden und unveraendert?
    $hit = @($out | Where-Object { $_.Key -eq $Key })[0]
    if (-not $hit) { return @{ Ok = $false; Text = 'Zeitplan nicht mehr vorhanden' } }
    if ($hit.Problem) { return @{ Ok = $false; Text = "$($hit.Problem)" } }
    if ($hit.Info.Running) { return @{ Ok = $false; Text = 'laeuft bereits' } }
    if ($hit.Info.Disabled) { return @{ Ok = $false; Text = 'Aufgabe ist deaktiviert' } }
    if ($hit.Kind -eq 'Server') {
        if ($wb) { return @{ Ok = $false; Text = 'eine Server-Sicherung laeuft gerade (Windows Server-Sicherung)' } }
        if (@($out | Where-Object { $_.Kind -eq 'Server' -and $_.Info.Running }).Count) { return @{ Ok = $false; Text = 'ein anderes Server-Backup laeuft gerade' } }
        $busy = @(); try { $busy = @(Get-ScheduledTask -TaskPath '\HUMig\' -ErrorAction Stop | Where-Object { "$($_.State)" -in @('Running', 'Queued') }) } catch { }
        if ($busy.Count) { return @{ Ok = $false; Text = "ein anderer HUMig-Zeitplan laeuft gerade ($($busy[0].TaskName))" } }
    }
    $at = Get-Date
    # Start ueber das eben gepruefte Objekt. Start-ScheduledTask loest dabei Ordner+Name erneut auf - eine Aenderung in
    # dieser kurzen Luecke kann nur, wer die Aufgabe ohnehin aendern darf (Besitzer der Benutzer-Aufgabe bzw. Administrator)
    try { $hit.Task | Start-ScheduledTask -ErrorAction Stop } catch { return @{ Ok = $false; Text = "Start nicht moeglich: $($_.Exception.Message)" } }
    return @{ Ok = $true; Text = 'gestartet'; At = $at; Title = "$($hit.Title)"; Kind = "$($hit.Kind)" }
}
$script:HMSchedWatch = New-Object System.Collections.ArrayList
$script:HMSchedRate = New-Object System.Collections.ArrayList
$script:HMSchedIds = @{}
$script:HMSchedKindName = @{ Backup = 'Profil-Backup'; Server = 'Server-Backup'; Au = 'App-Updates' }
function Get-HMRemoteSchedWhat([string]$Kind, [string]$Title) { if ($Kind -eq 'Au') { return $Title }; return "$($script:HMSchedKindName[$Kind]) '$Title'" }
# Freigeschaltete Arten (Einstellungen); Server-Backup und App-Updates nur als Administrator
function Get-HMRemoteSchedKinds {
    $c = Get-HMRemoteConfig
    $adm = -not $script:UserMode
    return @{ Backup = [bool]$c.SchedBackup; Server = ($adm -and [bool]$c.SchedServer); Au = ($adm -and [bool]$c.SchedAu) }
}
function Test-HMRemoteSchedAny { $k = Get-HMRemoteSchedKinds; return ($k.Backup -or $k.Server -or $k.Au) }
# Konten, die selbst Administrator sind (fuer die Rechtepruefung des Programmordners wie beim Start von HUMig)
function Get-HMRemoteSchedAdminSids { try { if (Get-Command Get-HMAppAdminSids -ErrorAction SilentlyContinue) { return @(Get-HMAppAdminSids) } } catch { }; return @() }
function Start-HMRemoteSchedScan {
    if (Test-HMRemoteBgBusy 'SchedScan') { return }
    [void](Start-HMRemoteBg 'SchedScan' $script:HMSchedScript @('List', (Get-HMRemoteSchedKinds), "$($script:AppRoot)", (-not $script:UserMode), '', [string[]]@(Get-HMRemoteSchedAdminSids)) @{} 60)
}
# Liste fuer das Handy: Kennung (zufaellig, je Aufbau neu) -> Eintrag nur am PC
function Set-HMRemoteSchedList($S, $Res) {
    $map = [hashtable]::Synchronized(@{})
    $list = @()
    foreach ($o in @($Res.Items | Where-Object { $_ })) {
        # zufaellige Kennung je Aufgabe, fuer die Sitzung gleich (sonst scheitert eine Bestaetigung, wenn die Liste dazwischen neu aufgebaut wird)
        $id = "$($script:HMSchedIds["$($o.Key)"])"
        if ($id -notmatch '^[0-9a-f]{16}$') {
            $rb = Get-HMRemoteRandomBytes 8   # liefert ,@() - erst zuweisen
            $id = -join ($rb | ForEach-Object { $_.ToString('x2') })
            $script:HMSchedIds["$($o.Key)"] = $id
        }
        $kn = $script:HMSchedKindName["$($o.Kind)"]
        $i = $o.Info
        $run = [bool]($i -and $i.Running)
        $sub = @()
        if ($run) { $sub += 'laeuft gerade' }
        elseif ($i) { if ($i.Last) { $sub += "zuletzt $($i.Last)$(if ($null -ne $i.Result -and $i.Result -ne 267011) { ' (' + (Format-HMRemoteSchedResult $o.Kind $i.Result) + ')' })" }; if ($i.Next) { $sub += "naechster $($i.Next)" } }
        $note = "$($o.Problem)"
        if (-not $note -and $o.Kind -eq 'Server' -and $Res.Wb -and -not $run) { $note = 'Server-Sicherung laeuft gerade' }
        $ok = (-not $note -and -not $run -and -not ($i -and $i.Disabled))
        if ($i -and $i.Disabled -and -not $note) { $note = 'deaktiviert' }
        if ($ok) {
            $map[$id] = @{ Key = "$($o.Key)"; Kind = "$($o.Kind)"; Title = "$($o.Title)"
                Confirm = "$(Get-HMRemoteSchedWhat "$($o.Kind)" "$($o.Title)") am PC $($S.Pc) jetzt starten? Laeuft im Hintergrund als $($o.As)$(if ($o.Kind -eq 'Server') { ' - VMs werden gesichert, die Platte danach evtl. ausgeworfen' })." }
        }
        $list += [ordered]@{ id = $(if ($ok) { $id } else { '' }); kind = "$kn"; title = "$($o.Title)"; sub = ($sub -join ' · '); running = $run; ok = $ok; note = $note }
    }
    $S.SchedMap = $map
    $S.SchedJson = ConvertTo-Json -Compress -Depth 3 -InputObject @($list)
}
function Format-HMRemoteSchedResult([string]$Kind, $Code) {
    $c = [int64]$Code
    if ($c -eq 0) { return 'erfolgreich' }
    if ($Kind -ne 'Au' -and $c -eq 1) { return 'mit Warnungen' }
    if ($c -eq 267009) { return 'laeuft' }
    if ($Kind -ne 'Au' -and $c -eq 2) { return 'mit Fehlern' }
    return ('Fehler 0x{0:X}' -f $c)
}
function Set-HMRemoteSchedMsg($S, [bool]$Ok, [string]$Text) {
    $S.SchedMsg = ConvertTo-Json -Compress -InputObject ([ordered]@{ t = [int64](([datetime]::UtcNow - [datetime]'1970-01-01').TotalMilliseconds); ok = $Ok; text = $Text })
}
# Anfrage vom Handy (im UI-Timer): Grenzen pruefen, dann Start im Hintergrund (dort erneute Pruefung der Aufgabe)
function Invoke-HMRemoteSchedReq($S) {
    $q = $S.SchedReq
    if (-not $q) { return }
    $S.SchedReq = $null
    $e = $q.Entry
    $now = Get-Date
    $msg = ''
    if (-not (Test-HMRemoteSchedAny) -or -not (Get-HMRemoteSchedKinds)["$($e.Kind)"]) { $msg = 'Start vom Handy ist fuer diese Art ausgeschaltet' }
    elseif (Test-HMRemoteBgBusy 'SchedRun') { $msg = 'Ein Start laeuft gerade - kurz warten' }
    elseif ("$($e.Kind)" -eq 'Server' -and $script:CurrentJob) { $msg = "In HUMig laeuft gerade ein Vorgang ($($script:JobTitle))" }
    else {
        foreach ($x in @($script:HMSchedRate)) { if ($x.At -lt $now.AddMinutes(-10)) { $script:HMSchedRate.Remove($x) } }
        if (@($script:HMSchedRate | Where-Object { $_.Dev -eq $q.DevId -and $_.Key -eq $e.Key -and $_.At -gt $now.AddSeconds(-60) }).Count) { $msg = 'Diesen Zeitplan hoechstens einmal pro Minute starten' }
        elseif (@($script:HMSchedRate).Count -ge 5) { $msg = 'Hoechstens 5 Starts in 10 Minuten' }
    }
    $what = Get-HMRemoteSchedWhat "$($e.Kind)" "$($e.Title)"
    if ($msg) {
        Set-HMRemoteSchedMsg $S $false "$what nicht gestartet: $msg"
        Write-HMRemoteLog $S "$($q.Ip)  Zeitplan-Start abgelehnt: $($e.Key) ($($q.By)) - $msg"
        Out-Console "Handy '$($q.By)': $what nicht gestartet - $msg" 'Warning'
        return
    }
    [void]$script:HMSchedRate.Add(@{ At = $now; Dev = "$($q.DevId)"; Key = "$($e.Key)" })
    [void](Start-HMRemoteBg 'SchedRun' $script:HMSchedScript @('Run', (Get-HMRemoteSchedKinds), "$($script:AppRoot)", (-not $script:UserMode), "$($e.Key)", [string[]]@(Get-HMRemoteSchedAdminSids)) @{ Entry = $e; By = "$($q.By)"; Ip = "$($q.Ip)" } 60)
}
# Ergebnis eines Starts; beobachten bis zum Ende (Push-Meldung)
function Receive-HMRemoteSchedRun($S, $Res, [bool]$Ok, $Data) {
    $e = $Data.Entry
    $what = Get-HMRemoteSchedWhat "$($e.Kind)" "$($e.Title)"
    $r = @($Res | Where-Object { $_ -is [hashtable] })[0]
    if (-not $Ok -or -not $r) { $r = @{ Ok = $false; Text = 'Pruefung/Start nicht moeglich' } }
    if ($r.Ok) {
        Set-HMRemoteSchedMsg $S $true "$what gestartet"
        Write-HMRemoteLog $S "$($Data.Ip)  Zeitplan gestartet: $($e.Key) ($($Data.By))"
        Out-Console "Zeitplan vom Handy '$($Data.By)' gestartet: $what (laeuft im Hintergrund)" 'Success'
        [void]$script:HMSchedWatch.Add(@{ Key = "$($e.Key)"; Kind = "$($e.Kind)"; What = $what; At = [datetime]$r.At })
    } else {
        Set-HMRemoteSchedMsg $S $false "$what nicht gestartet: $($r.Text)"
        Write-HMRemoteLog $S "$($Data.Ip)  Zeitplan-Start abgelehnt: $($e.Key) ($($Data.By)) - $($r.Text)"
        Out-Console "Handy '$($Data.By)': $what nicht gestartet - $($r.Text)" 'Warning'
    }
    $script:HMRemote.SchedAt = $null   # Liste gleich neu lesen
}
# nach einer Listen-Abfrage: vom Handy gestartete Laeufe fertig? (erst wenn LastRunTime >= Start und nicht mehr laufend)
function Update-HMRemoteSchedWatch($Res) {
    foreach ($w in @($script:HMSchedWatch)) {
        $o = @($Res.Items | Where-Object { $_ -and $_.Key -eq $w.Key })[0]
        if ((Get-Date) -gt $w.At.AddHours(24)) { $script:HMSchedWatch.Remove($w); continue }
        if (-not $o) { if ((Get-Date) -gt $w.At.AddMinutes(10)) { $script:HMSchedWatch.Remove($w) }; continue }   # Liste kurz unvollstaendig: abwarten
        $i = $o.Info
        if ($i -and -not $i.Running -and (-not $i.LastRun -or $i.LastRun -lt $w.At.AddSeconds(-5)) -and (Get-Date) -gt $w.At.AddMinutes(2)) {
            # Aufgabe hat nicht angefangen (z. B. Bedingungen der Aufgabe) - melden statt stundenlang zu warten
            $script:HMSchedWatch.Remove($w)
            $t = "Zeitplan $($w.What) - nicht gelaufen (am PC pruefen)"
            Out-Console $t 'Warning'; try { Send-HMRemotePush -Text $t } catch { }
            continue
        }
        if (-not $i -or $i.Running -or -not $i.LastRun -or $i.LastRun -lt $w.At.AddSeconds(-5) -or $null -eq $i.Result -or $i.Result -in @(267009, 267011)) { continue }
        $script:HMSchedWatch.Remove($w)
        $t = "Zeitplan $($w.What) - $(Format-HMRemoteSchedResult $w.Kind $i.Result)"
        Out-Console $t $(if ($i.Result -eq 0) { 'Success' } else { 'Warning' })
        try { Send-HMRemotePush -Text $t } catch { }
    }
}
# Ergebnis des App-Updates-Zeitplans auf DIESEM PC (falls eingerichtet): %ProgramData%\HUMig\AppUpdates\auto\last.json
# Verlauf des App-Updates-Zeitplans auf diesem PC (je Programm, nur Eintraege mit Datum und Paket-ID)
function Read-HMRemoteLocalAuHistory {
    try {
        $f = Join-Path $env:ProgramData 'HUMig\AppUpdates\auto\history.json'
        if (Test-Path -LiteralPath $f -PathType Leaf) { return @(Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json | ForEach-Object { $_ } | Where-Object { $_ -and "$($_.Date)" -and "$($_.Id)" }) }
    } catch { }
    return @()
}
function Read-HMRemoteLocalAuLast {
    try {
        $f = Join-Path $env:ProgramData 'HUMig\AppUpdates\auto\last.json'
        if (Test-Path -LiteralPath $f -PathType Leaf) { return (Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json) }
    } catch { }
    return $null
}
# Push, wenn der App-Updates-Zeitplan auf diesem PC mit Fehlern gelaufen ist (nur solange HUMig offen ist)
function Test-HMRemoteAuSchedule {
    $l = Read-HMRemoteLocalAuLast
    if (-not $l -or -not "$($l.Date)") { if ($null -eq $script:HMRemoteAuSeen) { $script:HMRemoteAuSeen = '' }; return }   # noch kein Lauf: der erste wird gemeldet
    $key = "$($l.Date)|$($l.Err)"
    if ($null -eq $script:HMRemoteAuSeen) { $script:HMRemoteAuSeen = $key; return }   # Stand beim Start nicht melden
    if ($key -eq $script:HMRemoteAuSeen) { return }
    $script:HMRemoteAuSeen = $key
    if ([int]$l.Err -gt 0) { Send-HMRemotePush -Text ("App-Updates-Zeitplan auf {0}: {1} fehlgeschlagen ({2} OK)" -f $env:COMPUTERNAME, [int]$l.Err, [int]$l.Ok) }
}

# Push-Meldung (ohne Inhalt) an alle Handys mit eingeschalteten Meldungen - nach dem Ende eines Vorgangs.
# Gesendet wird im Hintergrund (Oberflaeche blockiert nicht); Ergebnis wertet Update-HMRemotePushRuns aus.
$script:HMPushRuns = New-Object System.Collections.ArrayList
# Kurzform fuer die Push-Meldung: "Backup - erfolgreich · 8,01 GB · 5 min 12 s" (Menge nur wenn bekannt)
function New-HMRemotePushText([string]$Title, [string]$Result, $Seconds, $Bytes) {
    $p = @("$Title - $Result")
    try { if ($Bytes -and [long]$Bytes -gt 0) { $p += Format-HMSize ([double]$Bytes) } } catch { }
    try { if ($null -ne $Seconds -and [double]$Seconds -ge 0) { $p += Format-HMDuration ([TimeSpan]::FromSeconds([double]$Seconds)) } } catch { }
    $sep = ' ' + [char]0x00B7 + ' '
    return ($p -join $sep)
}
function Send-HMRemotePush([string]$Text = '') {
    $r = $script:HMRemote
    if (-not $r -or -not $script:HMPushVapid) { return }
    $S = $r.S
    # Text der Meldung: holt das Handy nach dem Anklopfen ab (nie im Push selbst)
    if ($Text) {
        try {
            # mehrere Meldungen kurz hintereinander: Texte sammeln (hoechstens 3), statt den vorigen zu ueberschreiben
            $now = [datetime]::UtcNow
            $txt = $Text
            $old = $S.Notice
            if ($old -and $old.At -and ($now - [datetime]$old.At).TotalSeconds -lt 120 -and $old.Text) { $txt = (@(@("$($old.Text)" -split "`n") + $Text) | Select-Object -Last 3) -join "`n" }
            $js = ConvertTo-Json -Compress -InputObject ([ordered]@{ t = [int64](($now - [datetime]'1970-01-01').TotalMilliseconds); text = $txt })
            $S.Notice = @{ Json = $js; At = $now; Text = $txt }   # ein Tausch (Webserver liest gleichzeitig)
        } catch { }
    }
    # Stand sofort bereitstellen - das Handy fragt gleich nach dem Anklopfen nach
    try { $S.JobJson = ConvertTo-HMRemoteJobJson $script:CurrentJob "$($script:JobTitle)" $script:HMRemoteLast -Mon $script:MonSnap } catch { }
    $reqs = Get-HMRemotePushRequests $S.Devices $script:HMPushVapid   # liefert ,@() - nicht in @() wickeln
    if (-not $reqs -or -not $reqs.Count) { return }
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript($script:HMPushSendScript).AddArgument($reqs)
    # Zeitlimit nach Anzahl (je Handy bis 15 s): danach Abbruch im Hintergrund und Meldung
    [void]$script:HMPushRuns.Add(@{ PS = $ps; Handle = $ps.BeginInvoke(); Started = (Get-Date); Limit = (30 + 20 * $reqs.Count); StopH = $null; Names = @($reqs | ForEach-Object { $_.Name }) })
}
function Update-HMRemotePushRuns([switch]$Final) {
    foreach ($run in @($script:HMPushRuns)) {
        # laeuft ein Abbruch: erst nach dessen Ende aufraeumen (blockiert die Oberflaeche nicht)
        if ($run.StopH) {
            if ($run.StopH.IsCompleted) { try { $run.PS.EndStop($run.StopH) } catch { }; try { $run.PS.Dispose() } catch { }; $script:HMPushRuns.Remove($run) }
            elseif ($Final) { $script:HMPushRuns.Remove($run) }   # beim Ausschalten nicht auf den haengenden Versand warten
            continue
        }
        $late = ((Get-Date) - $run.Started).TotalSeconds -gt [int]$run.Limit
        if (-not $run.Handle.IsCompleted -and -not $late -and -not $Final) { continue }
        $res = @()
        if ($run.Handle.IsCompleted) {
            try { $res = @($run.PS.EndInvoke($run.Handle)) } catch { }
            try { $run.PS.Dispose() } catch { }
            $script:HMPushRuns.Remove($run)
        } else {
            try { $run.StopH = $run.PS.BeginStop($null, $null) } catch { try { $run.PS.Dispose() } catch { }; $script:HMPushRuns.Remove($run) }
            if (-not $Final) { Out-Console "Fernbedienung: Push-Meldungen nicht alle zugestellt (Zeitueberschreitung, Push-Dienst nicht erreichbar? Proxy/Firewall pruefen) - $(@($run.Names) -join ', ')" 'Warning' }
            continue
        }
        $S = if ($script:HMRemote) { $script:HMRemote.S } else { $null }
        foreach ($x in $res) {
            if (-not $x) { continue }
            $c = [int]$x.Code
            $dv = if ($S) { $S.Devices[$x.Hash] } else { $null }
            if ($c -ge 200 -and $c -lt 300) { if ($dv) { $dv.PushFail = 0 }; continue }
            if ($c -in @(404, 410) -and $dv) {
                # Abo abgelaufen/abgemeldet (App oder Browserdaten geloescht)
                if ("$($dv.PushEndpoint)" -eq "$($x.Url)") { $dv.PushEndpoint = ''; $S.DevDirty = $true }
                Out-Console "Fernbedienung: Push-Meldungen fuer '$($x.Name)' abgelaufen (HTTP $c) - am Handy unter Mehr wieder einschalten" 'Warning'
            } elseif ($c -in @(401, 403) -and $dv) {
                # Anmeldung abgelehnt: oft falsche PC-Uhr (Gueltigkeit der Anmeldung) oder neuer Schluessel - erst nach 3 Ablehnungen in Folge austragen
                $dv.PushFail = [int]$dv.PushFail + 1
                if ($dv.PushFail -ge 3 -and "$($dv.PushEndpoint)" -eq "$($x.Url)") { $dv.PushEndpoint = ''; $dv.PushFail = 0; $S.DevDirty = $true; Out-Console "Fernbedienung: Push-Meldungen fuer '$($x.Name)' ausgetragen (3x abgelehnt, HTTP $c) - am Handy unter Mehr wieder einschalten" 'Warning' }
                else { Out-Console "Fernbedienung: Push-Dienst lehnt die Anmeldung ab (HTTP $c) fuer '$($x.Name)' - PC-Uhrzeit pruefen" 'Warning' }
            } else {
                Out-Console "Fernbedienung: Push-Meldung an '$($x.Name)' nicht zugestellt ($(if ($c) { "HTTP $c" } else { $x.Error }))" 'Warning'
            }
        }
    }
}
function Update-HMRemoteButton {
    if (-not $ui.btnRemote) { return }
    if ($script:HMRemote) {
        $ui.btnRemote.Content = 'Handy  ●'
        $ui.btnRemote.Foreground = New-Brush '#FFA6E3A1'
        $ui.btnRemote.ToolTip = "Fernbedienung aktiv: https://$($script:HMRemote.Ip):$($script:HMRemote.Port) - QR-Code, Kopplung, gekoppelte Handys"
    } else {
        $ui.btnRemote.Content = 'Handy'
        $ui.btnRemote.Foreground = New-Brush '#FFCDD6F4'
        $ui.btnRemote.ToolTip = 'Handy-Fernbedienung: Status und laufende Vorgaenge am Handy ansehen (im selben Netz)'
    }
}

# Beim Start von HUMig: Reste aufraeumen, Zertifikat der Einrichtung fuer den Benutzer-Modus erneuern, ggf. automatisch starten
function Initialize-HMRemote {
    try { Clear-HMRemoteLeftovers } catch { }
    if (Test-HMRemoteAdmin) {
        $su = Read-HMRemoteSetup
        if ($su) {
            try {
                $ips = @(Get-HMRemoteIPv4List | Where-Object { $_.Private } | ForEach-Object { $_.IP })
                if ($ips.Count) {
                    $ci = Initialize-HMRemoteCert $ips
                    if ($ci.New -or (Get-HMRemoteBinding ([int]$su.Port)).Thumb -ne $ci.Cert.Thumbprint) {
                        Set-HMRemoteBinding ([int]$su.Port) $ci.Cert.Thumbprint
                        $su.Thumb = $ci.Cert.Thumbprint; Write-HMRemoteJson (Get-HMRemoteSetupFile) $su
                        Remove-HMRemoteOldCerts $ci.Cert.Thumbprint
                        Out-Console 'Fernbedienung (Benutzer-Modus): Zertifikat an die aktuellen Adressen angepasst' 'Info'
                    }
                }
            } catch { Out-Console "Fernbedienung (Benutzer-Modus): Zertifikat nicht erneuert - $($_.Exception.Message)" 'Warning' }
        }
    }
    Update-HMRemoteButton
    if ((Get-HMRemoteConfig).AutoStart) { [void](Start-HMRemote -Quiet) }
}

# ----------------------------------------------------------------------------
# Einrichtung fuer den Benutzer-Modus (Administrator, dauerhaft)
# ----------------------------------------------------------------------------
function Install-HMRemoteUserSetup([string]$Account, [int]$Port, $Networks) {
    if (-not (Test-HMRemoteAdmin)) { throw 'Nur als Administrator moeglich' }
    $sid = (New-Object System.Security.Principal.NTAccount($Account)).Translate([System.Security.Principal.SecurityIdentifier]).Value
    if ($script:HMRemote -and $script:HMRemote.Port -eq $Port) { throw 'Die Fernbedienung laeuft gerade auf diesem Port - zuerst ausschalten' }
    $old = Read-HMRemoteSetup
    if ($old -and [int]$old.Port -ne $Port) { Uninstall-HMRemoteUserSetup }
    if ((Get-HMRemoteBinding $Port).State -eq 'Foreign') { throw "Port $Port hat bereits eine HTTPS-Bindung eines anderen Programms" }
    if (-not (Test-HMRemotePortFree $Port)) { throw "Port $Port ist belegt" }
    $ips = @(Get-HMRemoteIPv4List | Where-Object { $_.Private } | ForEach-Object { $_.IP })
    if (-not $ips.Count) { throw 'Keine private IPv4-Adresse gefunden' }
    $ci = Initialize-HMRemoteCert $ips
    Set-HMRemoteBinding $Port $ci.Cert.Thumbprint
    Set-HMRemoteUrlAcl $Port $sid $(if ($old -and [int]$old.Port -eq $Port) { "$($old.Sid)" } else { '' })
    Set-HMRemoteFirewall $script:HMRemoteRuleSetup $Port (Get-HMRemoteFirewallRemote $Networks)
    Remove-HMRemoteOldCerts $ci.Cert.Thumbprint -BoundPorts @($(if ($script:HMRemote) { [int]$script:HMRemote.Port } else { 0 }))
    Write-HMRemoteJson (Get-HMRemoteSetupFile) ([ordered]@{ Port = $Port; Sid = $sid; Account = $Account; Thumb = $ci.Cert.Thumbprint; Created = (Get-Date).ToString('yyyy-MM-dd HH:mm') })
    Out-Console "Fernbedienung fuer den Benutzer-Modus eingerichtet: Konto $Account, Port $Port (Firewall-Regel und HTTPS-Bindung bleiben dauerhaft)" 'Success'
}
function Uninstall-HMRemoteUserSetup {
    $su = Read-HMRemoteSetup
    if ($su) {
        $p = [int]$su.Port
        if (-not ($script:HMRemote -and $script:HMRemote.Port -eq $p)) { Remove-HMRemoteBinding $p }
        Remove-HMRemoteUrlAcl $p "$($su.Sid)"
    }
    Remove-HMRemoteFirewall $script:HMRemoteRuleSetup
    Remove-Item -LiteralPath (Get-HMRemoteSetupFile) -Force -ErrorAction SilentlyContinue
    Out-Console 'Fernbedienung: Einrichtung fuer den Benutzer-Modus entfernt' 'Info'
}
function Get-HMRemoteSetupText {
    $su = Read-HMRemoteSetup
    if (-not $su) { return 'Nicht eingerichtet - im Benutzer-Modus ist die Fernbedienung dann nicht verfuegbar.' }
    $fw = [bool](Get-NetFirewallRule -Name $script:HMRemoteRuleSetup -ErrorAction SilentlyContinue)
    $b = (Get-HMRemoteBinding ([int]$su.Port)).State
    return "Eingerichtet fuer $($su.Account), Port $($su.Port) (seit $($su.Created))$(if (-not $fw -or $b -ne 'Ours') { ' - UNVOLLSTAENDIG (Firewall-Regel oder Bindung fehlt): neu einrichten' })"
}

# ----------------------------------------------------------------------------
# Einstellungen > Handy (aus Show-SettingsDialog)
# ----------------------------------------------------------------------------
$script:HMRemoteTimes = @(@(0, 'solange HUMig laeuft'), @(15, '15 Minuten'), @(30, '30 Minuten'), @(60, '1 Stunde'), @(120, '2 Stunden'), @(240, '4 Stunden'), @(480, '8 Stunden'))
function Initialize-HMRemoteSettingsTab($F) {
    $c = Get-HMRemoteConfig
    $F.chkRemoteAuto.IsChecked = $c.AutoStart
    $F.txtRemotePort.Text = "$($c.Port)"
    $F.cmbRemoteTime.Items.Clear()
    $sel = 0
    for ($i = 0; $i -lt $script:HMRemoteTimes.Count; $i++) { [void]$F.cmbRemoteTime.Items.Add($script:HMRemoteTimes[$i][1]); if ($script:HMRemoteTimes[$i][0] -eq $c.Minutes) { $sel = $i } }
    if ($c.Minutes -gt 0 -and -not @($script:HMRemoteTimes | Where-Object { $_[0] -eq $c.Minutes }).Count) { [void]$F.cmbRemoteTime.Items.Add("$($c.Minutes) Minuten"); $sel = $F.cmbRemoteTime.Items.Count - 1 }
    $F.cmbRemoteTime.SelectedIndex = $sel
    $F.txtRemoteNets.Text = (@($c.Networks) -join "`r`n")
    $F.chkSchedBackup.IsChecked = $c.SchedBackup; $F.chkSchedServer.IsChecked = $c.SchedServer; $F.chkSchedAu.IsChecked = $c.SchedAu
    $acc = ''
    try { $acc = "$((Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).UserName)" } catch { }
    $su = Read-HMRemoteSetup
    $F.txtRemoteUser.Text = if ($su) { "$($su.Account)" } else { $acc }
    $F.lblRemoteSetup.Text = Get-HMRemoteSetupText
    $adm = Test-HMRemoteAdmin
    foreach ($x in @($F.btnRemoteSetup, $F.btnRemoteUnsetup, $F.txtRemoteUser, $F.chkSchedServer, $F.chkSchedAu)) { $x.IsEnabled = $adm }
    if (-not $adm) { $F.lblRemoteSetup.Text += '  (nur als Administrator einstellbar)' }
    $F.btnRemoteSetup.Add_Click({
        $F2 = $script:SetDlg.F; $W2 = $script:SetDlg.Win
        $acc2 = "$($F2.txtRemoteUser.Text)".Trim()
        $p2 = 0
        if (-not [int]::TryParse("$($F2.txtRemotePort.Text)".Trim(), [ref]$p2) -or $p2 -lt 1025 -or $p2 -gt 65535) { [void][System.Windows.MessageBox]::Show($W2, 'Port: Zahl von 1025 bis 65535', 'Handy', 'OK', 'Warning'); return }
        if (-not $acc2) { [void][System.Windows.MessageBox]::Show($W2, 'Benutzerkonto eintragen (z.B. SCHULE\max), das HUMig ohne Adminrechte startet.', 'Handy', 'OK', 'Warning'); return }
        $m = "Fernbedienung fuer den Benutzer-Modus einrichten?`n`nKonto: $acc2`nPort: $p2`n`nDauerhaft angelegt werden: Firewall-Regel (nur Domaenen-/private Netze, lokales Subnetz + eingetragene Netze), HTTPS-Bindung mit dem Zertifikat dieses PCs und die Port-Freigabe fuer dieses Konto. Sie bleiben, auch wenn HUMig geschlossen ist (dann antwortet auf dem Port niemand)."
        if ("$([System.Windows.MessageBox]::Show($W2, $m, 'Handy', 'YesNo', 'Question'))" -ne 'Yes') { return }
        try { Install-HMRemoteUserSetup $acc2 $p2 @(ConvertFrom-HMLines $F2.txtRemoteNets.Text) } catch { [void][System.Windows.MessageBox]::Show($W2, "Nicht eingerichtet: $($_.Exception.Message)", 'Handy', 'OK', 'Error') }
        $F2.lblRemoteSetup.Text = Get-HMRemoteSetupText
    })
    $F.btnRemoteUnsetup.Add_Click({
        $F2 = $script:SetDlg.F; $W2 = $script:SetDlg.Win
        if (-not (Read-HMRemoteSetup)) { [void][System.Windows.MessageBox]::Show($W2, 'Es ist nichts eingerichtet.', 'Handy', 'OK', 'Information'); return }
        if ("$([System.Windows.MessageBox]::Show($W2, 'Einrichtung fuer den Benutzer-Modus entfernen (Firewall-Regel, HTTPS-Bindung, Port-Freigabe)?', 'Handy', 'YesNo', 'Question'))" -ne 'Yes') { return }
        try { Uninstall-HMRemoteUserSetup } catch { [void][System.Windows.MessageBox]::Show($W2, "Fehler: $($_.Exception.Message)", 'Handy', 'OK', 'Error') }
        $F2.lblRemoteSetup.Text = Get-HMRemoteSetupText
    })
}
# Werte aus dem Reiter. Rueckgabe: Hashtable fuer settings.json (Remote) oder $null bei ungueltiger Eingabe
function Get-HMRemoteSettingsFromTab($F, $W) {
    $p = 0
    if (-not [int]::TryParse("$($F.txtRemotePort.Text)".Trim(), [ref]$p) -or $p -lt 1025 -or $p -gt 65535) { [void][System.Windows.MessageBox]::Show($W, 'Handy-Fernbedienung: Port von 1025 bis 65535', 'Einstellungen', 'OK', 'Warning'); return $null }
    $nets = @(ConvertFrom-HMLines $F.txtRemoteNets.Text)
    $bad = @($nets | Where-Object { @(Get-HMRemoteFirewallRemote @($_)).Count -lt 2 })
    if ($bad.Count) { [void][System.Windows.MessageBox]::Show($W, "Handy-Fernbedienung: Netz ungueltig: $($bad[0]) (Schreibweise 10.20.0.0/16 oder einzelne Adresse)", 'Einstellungen', 'OK', 'Warning'); return $null }
    $i = $F.cmbRemoteTime.SelectedIndex
    $min = 0
    if ($i -ge 0 -and $i -lt $script:HMRemoteTimes.Count) { $min = $script:HMRemoteTimes[$i][0] }
    elseif ("$($F.cmbRemoteTime.SelectedItem)" -match '^(\d+)') { $min = [int]$Matches[1] }
    $su = Read-HMRemoteSetup
    if ($su -and [int]$su.Port -ne $p) { Out-Console "Fernbedienung: Port geaendert - die Einrichtung fuer den Benutzer-Modus nutzt weiter Port $($su.Port) (dort neu einrichten, wenn gewuenscht)." 'Warning' }
    if ($script:HMRemote -and $script:HMRemote.Port -ne $p) { Out-Console 'Fernbedienung: neuer Port gilt nach Aus- und Einschalten.' 'Info' }
    $sch = @(@('SchedBackup', $F.chkSchedBackup, 'Profil-Backups'), @('SchedServer', $F.chkSchedServer, 'Server-Backups'), @('SchedAu', $F.chkSchedAu, 'App-Updates') | Where-Object { [bool]$_[1].IsChecked })
    $old = Get-HMRemoteConfig
    foreach ($x in $sch) { if (-not $old."$($x[0])") { Out-Console "Fernbedienung: $($x[2]) duerfen jetzt vom Handy gestartet werden (gekoppelte Handys, mit Bestaetigung; im Zugriffsprotokoll)." 'Warning' } }
    return [ordered]@{ AutoStart = [bool]$F.chkRemoteAuto.IsChecked; Port = $p; Minutes = $min; Networks = $nets
        SchedBackup = [bool]$F.chkSchedBackup.IsChecked; SchedServer = [bool]$F.chkSchedServer.IsChecked; SchedAu = [bool]$F.chkSchedAu.IsChecked }
}

# ----------------------------------------------------------------------------
# Fenster "Handy": Ein/Aus, QR-Code, Code, gekoppelte Handys
# ----------------------------------------------------------------------------
function Show-HMRemoteDialog {
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="HUMig - Handy-Fernbedienung" Width="840" Height="720" MinWidth="700" MinHeight="600" WindowStartupLocation="CenterOwner"
        Background="#FF1E1E2E" Foreground="#FFCDD6F4" FontFamily="Segoe UI" FontSize="12">
  <DockPanel Margin="14">
    <DockPanel DockPanel.Dock="Top" Margin="0,0,0,10">
      <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
        <Button x:Name="btnOn" Content="Einschalten" Style="{DynamicResource BtnGreen}" Padding="16,6" FontWeight="SemiBold"/>
        <Button x:Name="btnOff" Content="Ausschalten" Style="{DynamicResource BtnRed}" Padding="16,6"/>
      </StackPanel>
      <StackPanel>
        <TextBlock x:Name="lblState" FontSize="17" FontWeight="Bold"/>
        <TextBox x:Name="txtUrl" IsReadOnly="True" BorderThickness="0" Background="Transparent" Foreground="#FF89B4FA" FontSize="13" Margin="0,2,0,0"/>
        <TextBox x:Name="txtFp" IsReadOnly="True" BorderThickness="0" Background="Transparent" Foreground="#FFA6ADC8" FontSize="11" FontFamily="Consolas" Margin="0,2,0,0" TextWrapping="Wrap" ToolTip="SHA-256-Fingerabdruck der Zertifizierungsstelle dieses PCs - am Handy in den Zertifikatsdetails vergleichen"/>
      </StackPanel>
    </DockPanel>
    <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,10,0,0">
      <Button x:Name="btnLog" Content="Zugriffsprotokoll" Style="{DynamicResource BtnDefault}" Padding="12,5"/>
      <Button x:Name="btnClose" Content="Schliessen" Style="{DynamicResource BtnDefault}" Padding="16,5" IsCancel="True"/>
    </StackPanel>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="320"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <Border Background="#FF181825" CornerRadius="10" Padding="14" Margin="0,0,12,0">
        <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
        <StackPanel>
          <Border Background="White" CornerRadius="8" Width="270" Height="270" HorizontalAlignment="Center">
            <Grid>
              <Image x:Name="imgQr" Width="262" Height="262" RenderOptions.BitmapScalingMode="NearestNeighbor"/>
              <TextBlock x:Name="lblQrOff" Text="Fernbedienung ist aus" Foreground="#FF6C7086" FontSize="14" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Grid>
          </Border>
          <TextBlock Text="KOPPLUNGSCODE" Foreground="#FF6C7086" FontWeight="Bold" FontSize="11" Margin="0,12,0,0" HorizontalAlignment="Center"/>
          <TextBlock x:Name="lblCode" Text="--- ---" FontSize="38" FontFamily="Consolas" FontWeight="Bold" HorizontalAlignment="Center" Foreground="#FFF9E2AF"/>
          <TextBlock x:Name="lblPair" Foreground="#FFA6ADC8" HorizontalAlignment="Center" TextWrapping="Wrap" TextAlignment="Center"/>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,8,0,0">
            <Button x:Name="btnNewCode" Content="Neuer Code" Style="{DynamicResource BtnBlue}" Padding="12,5"/>
          </StackPanel>
          <TextBlock Text="Adresse fuer den QR-Code:" Foreground="#FFA6ADC8" Margin="0,10,0,2"/>
          <ComboBox x:Name="cmbIp" Height="26" Padding="6,3" ToolTip="Hat der PC mehrere Adressen (z. B. LAN und WLAN): die waehlen, die das Handy erreicht"/>
        </StackPanel>
        </ScrollViewer>
      </Border>
      <DockPanel Grid.Column="1">
        <TextBlock DockPanel.Dock="Top" Text="SO GEHT'S" Foreground="#FF6C7086" FontWeight="Bold" FontSize="11"/>
        <TextBlock DockPanel.Dock="Top" x:Name="lblSteps" TextWrapping="Wrap" Margin="0,4,0,10" LineHeight="18"/>
        <TextBlock DockPanel.Dock="Top" Text="GEKOPPELTE HANDYS" Foreground="#FF6C7086" FontWeight="Bold" FontSize="11"/>
        <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" Margin="0,6,0,0">
          <Button x:Name="btnDel" Content="Entfernen" Style="{DynamicResource BtnRed}" Padding="12,5"/>
          <TextBlock x:Name="lblDev" Foreground="#FFA6ADC8" VerticalAlignment="Center" Margin="8,0,0,0" TextWrapping="Wrap"/>
        </StackPanel>
        <ListBox x:Name="lstDev" Background="#FF181825" Foreground="#FFCDD6F4" BorderBrush="#FF45475A" Margin="0,4,0,0"/>
      </DockPanel>
    </Grid>
  </DockPanel>
</Window>
'@
    $w = [System.Windows.Markup.XamlReader]::Parse($x)
    $w.Resources.MergedDictionaries.Add($script:Window.Resources)
    if ($script:AppIcon) { $w.Icon = $script:AppIcon }
    $w.Owner = $script:Window
    try { Set-HMWindowScale $w } catch { }
    $d = @{ W = $w; Ips = @(); DevKeys = @(); LastKey = ''; Loading = $false }
    foreach ($n in @('btnOn', 'btnOff', 'lblState', 'txtUrl', 'txtFp', 'btnLog', 'btnClose', 'imgQr', 'lblQrOff', 'lblCode', 'lblPair', 'btnNewCode', 'cmbIp', 'lblSteps', 'lstDev', 'btnDel', 'lblDev')) { $d[$n] = $w.FindName($n) }
    $d.lblSteps.Text = "1. Handy im selben Netz (WLAN): QR-Code mit der Kamera scannen.`n2. Die Warnung zum Zertifikat einmal bestaetigen, auf der Seite 'Zertifikat laden' und installieren (Anleitung fuer Android/iPhone steht dort).`n3. Seite neu laden - der Code ist schon eingetragen - 'Koppeln'.`n4. Als App: Android 'App installieren', iPhone Teilen > 'Zum Home-Bildschirm' (in der App den Code noch einmal eingeben).`n`nSicherheit: am Handy in den Details des installierten Zertifikats den SHA-256-Fingerabdruck mit dem oben angezeigten vergleichen (Android: Einstellungen > Sicherheit > Vertrauenswuerdige Anmeldedaten > Nutzer; iPhone: Profil > Mehr Details). Stimmt er nicht, Zertifikat sofort entfernen - dann hat jemand im Netz eine fremde Seite untergeschoben.`n`nGekoppelte Handys sehen den Status und laufende Vorgaenge und koennen sie abbrechen (mit Bestaetigung am Handy). Nur im lokalen Netz, solange HUMig offen ist. Einstellungen: Einstellungen > Handy."
    $script:HMRemoteDlg = $d
    $d.btnClose.Add_Click({ $script:HMRemoteDlg.W.Close() })
    $d.btnOn.Add_Click({ if (Start-HMRemote -Owner $script:HMRemoteDlg.W) { Open-HMRemotePairing $script:HMRemote.S | Out-Null; $script:HMRemoteDlg.LastKey = '' }; Update-HMRemoteDialog })
    $d.btnOff.Add_Click({ Stop-HMRemote 'von Hand'; Update-HMRemoteDialog })
    $d.btnNewCode.Add_Click({ if ($script:HMRemote) { Open-HMRemotePairing $script:HMRemote.S | Out-Null; $script:HMRemoteDlg.LastKey = ''; Update-HMRemoteDialog } })
    $d.cmbIp.Add_SelectionChanged({ if (-not $script:HMRemoteDlg.Loading) { $script:HMRemoteDlg.LastKey = ''; Update-HMRemoteDialog } })
    $d.btnLog.Add_Click({ $lf = Get-HMRemoteLogFile; if ($lf -and (Test-Path -LiteralPath $lf)) { Start-Process notepad.exe -ArgumentList "`"$lf`"" } else { [void][System.Windows.MessageBox]::Show($script:HMRemoteDlg.W, 'Noch kein Zugriffsprotokoll vorhanden.', 'Handy', 'OK', 'Information') } })
    $d.btnDel.Add_Click({
        $D2 = $script:HMRemoteDlg
        $i = $D2.lstDev.SelectedIndex
        if ($i -lt 0 -or $i -ge $D2.DevKeys.Count) { [void][System.Windows.MessageBox]::Show($D2.W, 'Bitte ein Handy in der Liste waehlen.', 'Handy', 'OK', 'Information'); return }
        $k = $D2.DevKeys[$i]
        $devs = if ($script:HMRemote) { $script:HMRemote.S.Devices } else { Read-HMRemoteDevices }
        $nm = if ($devs[$k]) { $devs[$k].Name } else { '' }
        if ("$([System.Windows.MessageBox]::Show($D2.W, "Handy '$nm' entfernen? Es hat danach sofort keinen Zugriff mehr.", 'Handy', 'YesNo', 'Question'))" -ne 'Yes') { return }
        $devs.Remove($k)
        try { Save-HMRemoteDevices $devs } catch { }
        Out-Console "Fernbedienung: Handy '$nm' entfernt" 'Info'
        Update-HMRemoteDialog
    })
    # eigener Takt nur fuer "aus" (laeuft die Fernbedienung, aktualisiert Update-HMRemoteTick das Fenster)
    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromSeconds(2)
    $t.Add_Tick({ if ($script:HMRemoteDlg -and -not $script:HMRemote) { try { Update-HMRemoteDialog } catch { } } })
    $d.Timer = $t
    # Schliessen: Kopplung zu (ohne GetNewClosure - eine Closure saehe die Skript-Variablen von HUMig nicht)
    $w.Add_Closed({ try { $script:HMRemoteDlg.Timer.Stop() } catch { }; if ($script:HMRemote) { Close-HMRemotePairing $script:HMRemote.S }; $script:HMRemoteDlg = $null })
    if ($script:HMRemote) { Open-HMRemotePairing $script:HMRemote.S | Out-Null }
    Update-HMRemoteDialog
    $t.Start()
    [void]$w.ShowDialog()
}
function Update-HMRemoteDialog {
    $d = $script:HMRemoteDlg; if (-not $d) { return }
    $r = $script:HMRemote
    $on = [bool]$r
    $d.btnOn.Visibility = $(if ($on) { 'Collapsed' } else { 'Visible' })
    $d.btnOff.Visibility = $(if ($on) { 'Visible' } else { 'Collapsed' })
    $d.btnNewCode.IsEnabled = $on
    if ($on) {
        $S = $r.S
        # Adressen (alle privaten, die im Zertifikat stehen)
        $ipNow = (@($r.Ips) -join ','); $ipWas = (@($d.Ips) -join ',')
        if ($ipNow -ne $ipWas) {
            $d.Loading = $true; $d.cmbIp.Items.Clear(); foreach ($ip in $r.Ips) { [void]$d.cmbIp.Items.Add($ip) }; $d.cmbIp.SelectedIndex = 0; $d.Ips = @($r.Ips); $d.Loading = $false
        }
        $ip = if ($d.cmbIp.SelectedItem) { "$($d.cmbIp.SelectedItem)" } else { $r.Ip }
        $url = "https://$($ip):$($r.Port)/"
        $d.lblState.Text = "Fernbedienung ist an$(if ($S.StopAt) { " - bis $(([datetime]$S.StopAt).ToString('HH:mm'))" } else { ' - solange HUMig laeuft' })$(if ($S.UserMode) { ' (Benutzer-Modus)' })"
        $d.lblState.Foreground = New-Brush '#FFA6E3A1'
        $d.txtUrl.Text = $url
        $d.txtFp.Text = $(if ($r.CaFp) { "Zertifikat (SHA-256): $($r.CaFp)" } else { '' })
        $pr = $S.Pair
        if ($pr -and -not $pr.Locked -and $pr.Until -gt (Get-Date)) {
            $key = "$url|$($pr.Code)"
            if ($d.LastKey -ne $key) { $d.imgQr.Source = ConvertTo-HMRemoteQrImage "$($url)#c=$($pr.Code)"; $d.LastKey = $key }
            $d.lblQrOff.Visibility = 'Collapsed'
            $d.lblCode.Text = "$($pr.Code.Substring(0, 3)) $($pr.Code.Substring(3))"
            $rest = $pr.Until - (Get-Date)
            $d.lblPair.Text = "Kopplung offen noch {0}:{1:D2} min - solange dieses Fenster offen ist" -f [int][Math]::Floor($rest.TotalMinutes), $rest.Seconds
            $d.lblPair.Foreground = New-Brush '#FFA6ADC8'
        } else {
            $d.imgQr.Source = $null; $d.LastKey = ''
            $d.lblQrOff.Visibility = 'Visible'
            $d.lblQrOff.Text = if ($pr -and $pr.Locked) { 'Gesperrt (5 falsche Codes)' } else { 'Code abgelaufen' }
            $d.lblCode.Text = '--- ---'
            $d.lblPair.Text = "$(if ($pr -and $pr.Locked) { 'Kopplung gesperrt - ' } else { '' })'Neuer Code' oeffnet die Kopplung wieder (10 Minuten)."
            $d.lblPair.Foreground = New-Brush '#FFFAB387'
        }
        $devs = $S.Devices
    } else {
        $d.lblState.Text = 'Fernbedienung ist aus'
        $d.lblState.Foreground = New-Brush '#FFCDD6F4'
        $c = Get-HMRemoteConfig
        $d.txtUrl.Text = "Port $($c.Port)$(if (-not (Test-HMRemoteAdmin)) { ' - ohne Adminrechte nur nach Einrichtung durch einen Administrator' })"
        $d.txtFp.Text = ''
        $d.imgQr.Source = $null; $d.lblQrOff.Visibility = 'Visible'; $d.lblQrOff.Text = 'Fernbedienung ist aus'
        $d.lblCode.Text = '--- ---'; $d.lblPair.Text = "'Einschalten' startet die Fernbedienung und zeigt den QR-Code."
        $d.lblPair.Foreground = New-Brush '#FFA6ADC8'
        if (-not $d.Ips.Count) { $d.Loading = $true; $d.cmbIp.Items.Clear(); $d.Loading = $false }
        $devs = Read-HMRemoteDevices
    }
    # Geraeteliste (nur neu zeichnen, wenn sich etwas geaendert hat)
    $keys = @($devs.Keys | Sort-Object { "$($devs[$_].Name)" })
    $txt = @($keys | ForEach-Object { $v = $devs[$_]; "$($v.Name)   -   zuletzt $($v.LastSeen)$(if ($v.LastIp) { " von $($v.LastIp)" })   (gekoppelt $($v.Created))" })
    $sig = $txt -join '|'
    if ($sig -ne "$($d.DevSig)") {
        $sel = $d.lstDev.SelectedIndex
        $d.lstDev.Items.Clear(); foreach ($l in $txt) { [void]$d.lstDev.Items.Add($l) }
        if ($sel -ge 0 -and $sel -lt $txt.Count) { $d.lstDev.SelectedIndex = $sel }
        $d.DevKeys = $keys; $d.DevSig = $sig
    }
    $d.lblDev.Text = "$($keys.Count) von $($script:HMRemoteMaxDevices) Handys"
}
