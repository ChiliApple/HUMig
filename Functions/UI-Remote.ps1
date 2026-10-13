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
    return [pscustomobject]@{ AutoStart = [bool]($r -and $r.AutoStart); Port = $port; Minutes = $min; Networks = @($(if ($r) { @($r.Networks) } else { @() }) | Where-Object { "$_".Trim() } | ForEach-Object { "$_".Trim() }) }
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
    if ($S.DevDirty) { $S.DevDirty = $false; try { Save-HMRemoteDevices $S.Devices } catch { } }
    if ($script:HMRemoteDlg) { try { Update-HMRemoteDialog } catch { } }
}

# Push-Meldung (ohne Inhalt) an alle Handys mit eingeschalteten Meldungen - nach dem Ende eines Vorgangs.
# Gesendet wird im Hintergrund (Oberflaeche blockiert nicht); Ergebnis wertet Update-HMRemotePushRuns aus.
$script:HMPushRuns = New-Object System.Collections.ArrayList
function Send-HMRemotePush {
    $r = $script:HMRemote
    if (-not $r -or -not $script:HMPushVapid) { return }
    $S = $r.S
    # Stand sofort bereitstellen - das Handy fragt gleich nach dem Anklopfen nach
    try { $S.JobJson = ConvertTo-HMRemoteJobJson $script:CurrentJob "$($script:JobTitle)" $script:HMRemoteLast -Mon $script:MonSnap } catch { }
    $reqs = @(Get-HMRemotePushRequests $S.Devices $script:HMPushVapid)
    if (-not $reqs.Count) { return }
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript($script:HMPushSendScript).AddArgument($reqs)
    [void]$script:HMPushRuns.Add(@{ PS = $ps; Handle = $ps.BeginInvoke(); Started = (Get-Date) })
}
function Update-HMRemotePushRuns([switch]$Final) {
    foreach ($run in @($script:HMPushRuns)) {
        $late = ((Get-Date) - $run.Started).TotalSeconds -gt 90
        if (-not $run.Handle.IsCompleted -and -not $late -and -not $Final) { continue }
        $res = @()
        try {
            if ($run.Handle.IsCompleted) { $res = @($run.PS.EndInvoke($run.Handle)); $run.PS.Dispose() }
            else { [void]$run.PS.BeginStop($null, $null) }   # nicht auf das laufende Senden warten (Oberflaeche bleibt frei)
        } catch { }
        $script:HMPushRuns.Remove($run)
        $S = if ($script:HMRemote) { $script:HMRemote.S } else { $null }
        foreach ($x in $res) {
            if (-not $x) { continue }
            $c = [int]$x.Code
            if ($c -ge 200 -and $c -lt 300) { continue }
            if ($c -in @(401, 403, 404, 410) -and $S -and $S.Devices[$x.Hash]) {
                # Abo abgelaufen/abgemeldet (App/Browserdaten geloescht) bzw. passt nicht mehr zum Schluessel dieses PCs (401/403)
                if ("$($S.Devices[$x.Hash].PushEndpoint)" -eq "$($x.Url)") { $S.Devices[$x.Hash].PushEndpoint = ''; $S.DevDirty = $true }
                Out-Console "Fernbedienung: Push-Meldungen fuer '$($x.Name)' nicht mehr gueltig (HTTP $c) - am Handy unter Mehr wieder einschalten" 'Warning'
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
    $acc = ''
    try { $acc = "$((Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).UserName)" } catch { }
    $su = Read-HMRemoteSetup
    $F.txtRemoteUser.Text = if ($su) { "$($su.Account)" } else { $acc }
    $F.lblRemoteSetup.Text = Get-HMRemoteSetupText
    $adm = Test-HMRemoteAdmin
    foreach ($x in @($F.btnRemoteSetup, $F.btnRemoteUnsetup, $F.txtRemoteUser)) { $x.IsEnabled = $adm }
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
    return [ordered]@{ AutoStart = [bool]$F.chkRemoteAuto.IsChecked; Port = $p; Minutes = $min; Networks = $nets }
}

# ----------------------------------------------------------------------------
# Fenster "Handy": Ein/Aus, QR-Code, Code, gekoppelte Handys
# ----------------------------------------------------------------------------
function Show-HMRemoteDialog {
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="HUMig - Handy-Fernbedienung" Width="820" Height="640" MinWidth="700" MinHeight="560" WindowStartupLocation="CenterOwner"
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
          <ComboBox x:Name="cmbIp"/>
        </StackPanel>
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
