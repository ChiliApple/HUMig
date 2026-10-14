#Requires -Version 5.1
<#
.SYNOPSIS
    Handy-Fernbedienung (Kern): QR-Code, Kopplung, Zertifikate, Webserver-Anfragen - ohne Oberflaeche.
.DESCRIPTION
    Wird von UI-Remote.ps1 (Oberflaeche) und im Hintergrund-Runspace des Webservers geladen. Kein WPF-Code hier.
    - QR-Code (Byte-Modus, Fehlerkorrektur M, Version 1-10) ohne fremde Bibliothek
    - Geraete-Token (256 Bit, gespeichert wird nur der SHA256-Hash), Kopplungscode (6 Ziffern)
    - eigene CA je PC mit Namensbeschraenkung (nur dieser PC und private IP-Bereiche), Server-Zertifikat
    - Anfragen beantworten (Get-HMRemoteResponse) und Webserver-Schleife (Start-HMRemoteListenerLoop)
.NOTES
    Zielmaschine: der PC, auf dem HUMig laeuft.
#>

# ============================================================================
# QR-CODE (ISO/IEC 18004): Byte-Modus, Fehlerkorrektur M, Version 1-10
# ============================================================================
# je Version: Bloecke Gruppe 1 (Anzahl, Datenwoerter), Gruppe 2 (Anzahl, Datenwoerter), Korrekturwoerter je Block
$script:HMQrM = @{
    1 = @(1, 16, 0, 0, 10); 2 = @(1, 28, 0, 0, 16); 3 = @(1, 44, 0, 0, 26); 4 = @(2, 32, 0, 0, 18); 5 = @(2, 43, 0, 0, 24)
    6 = @(4, 27, 0, 0, 16); 7 = @(4, 31, 0, 0, 18); 8 = @(2, 38, 2, 39, 22); 9 = @(3, 36, 2, 37, 22); 10 = @(4, 43, 1, 44, 26)
}
$script:HMQrAlign = @{ 1 = @(); 2 = @(6, 18); 3 = @(6, 22); 4 = @(6, 26); 5 = @(6, 30); 6 = @(6, 34); 7 = @(6, 22, 38); 8 = @(6, 24, 42); 9 = @(6, 26, 46); 10 = @(6, 28, 50) }

# Galois-Feld 256 (Polynom 0x11D): Exponent- und Logarithmus-Tabellen
function Get-HMQrGf {
    if (-not $script:HMQrGfExp) {
        $exp = New-Object int[] 512
        $log = New-Object int[] 256
        $x = 1
        for ($i = 0; $i -lt 255; $i++) {
            $exp[$i] = $x; $log[$x] = $i
            $x = $x -shl 1
            if ($x -band 0x100) { $x = $x -bxor 0x11D }
        }
        for ($i = 255; $i -lt 512; $i++) { $exp[$i] = $exp[$i - 255] }
        $script:HMQrGfExp = $exp; $script:HMQrGfLog = $log
    }
}

# Reed-Solomon-Korrekturwoerter fuer einen Datenblock
function Get-HMQrEcc([byte[]]$Data, [int]$Count) {
    Get-HMQrGf
    $exp = $script:HMQrGfExp; $log = $script:HMQrGfLog
    # Generatorpolynom (x - a^0)(x - a^1)...(x - a^(Count-1)), Koeffizienten hoechster Grad zuerst
    $g = New-Object int[] ($Count + 1)
    $g[0] = 1
    for ($i = 0; $i -lt $Count; $i++) {
        for ($j = $i + 1; $j -ge 1; $j--) {
            $v = 0
            if ($g[$j - 1] -ne 0) { $v = $exp[$log[$g[$j - 1]] + $i] }
            $g[$j] = $g[$j] -bxor $v
        }
    }
    $rem = New-Object int[] $Count
    foreach ($d in $Data) {
        $f = ([int]$d) -bxor $rem[0]
        for ($k = 0; $k -lt $Count - 1; $k++) { $rem[$k] = $rem[$k + 1] }
        $rem[$Count - 1] = 0
        if ($f -ne 0) {
            $lf = $log[$f]
            for ($k = 0; $k -lt $Count; $k++) { if ($g[$k + 1] -ne 0) { $rem[$k] = $rem[$k] -bxor $exp[$lf + $log[$g[$k + 1]]] } }
        }
    }
    $out = New-Object byte[] $Count
    for ($k = 0; $k -lt $Count; $k++) { $out[$k] = [byte]$rem[$k] }
    return , $out
}

# Maskenmuster (x = Spalte, y = Zeile)
function Test-HMQrMask([int]$Mask, [int]$X, [int]$Y) {
    switch ($Mask) {
        0 { return (($X + $Y) % 2 -eq 0) }
        1 { return ($Y % 2 -eq 0) }
        2 { return ($X % 3 -eq 0) }
        3 { return (($X + $Y) % 3 -eq 0) }
        4 { return (([Math]::Floor($X / 3) + [Math]::Floor($Y / 2)) % 2 -eq 0) }
        5 { return ((($X * $Y) % 2 + ($X * $Y) % 3) -eq 0) }
        6 { return (((($X * $Y) % 2 + ($X * $Y) % 3) % 2) -eq 0) }
        default { return (((($X + $Y) % 2 + ($X * $Y) % 3) % 2) -eq 0) }
    }
}

# Strafpunkte einer fertigen Matrix (Regeln 1-4 der Norm), kleiner = besser lesbar
function Get-HMQrPenalty([byte[]]$M, [int]$N) {
    $p = 0
    $lines = New-Object System.Collections.Generic.List[string]
    $sb = New-Object System.Text.StringBuilder
    for ($a = 0; $a -lt $N; $a++) {
        [void]$sb.Clear(); for ($b = 0; $b -lt $N; $b++) { [void]$sb.Append([char](48 + $M[$a * $N + $b])) }; $lines.Add($sb.ToString())
        [void]$sb.Clear(); for ($b = 0; $b -lt $N; $b++) { [void]$sb.Append([char](48 + $M[$b * $N + $a])) }; $lines.Add($sb.ToString())
    }
    foreach ($l in $lines) {
        # Regel 1: 5 und mehr gleiche Module in Folge
        foreach ($rm in [regex]::Matches($l, '0{5,}|1{5,}')) { $p += 3 + ($rm.Length - 5) }
        # Regel 3: 1011101 mit 4 hellen Modulen davor oder danach (ausserhalb der Matrix = hell)
        $pd = '0000' + $l + '0000'
        $i = $pd.IndexOf('1011101')
        while ($i -ge 0) {
            if ($pd.Substring($i - 4, 4) -eq '0000' -or ($i + 11 -le $pd.Length -and $pd.Substring($i + 7, 4) -eq '0000')) { $p += 40 }
            $i = $pd.IndexOf('1011101', $i + 1)
        }
    }
    # Regel 2: 2x2-Bloecke gleicher Farbe
    for ($y = 0; $y -lt $N - 1; $y++) {
        for ($x = 0; $x -lt $N - 1; $x++) {
            $k = $y * $N + $x; $c = $M[$k]
            if ($c -eq $M[$k + 1] -and $c -eq $M[$k + $N] -and $c -eq $M[$k + $N + 1]) { $p += 3 }
        }
    }
    # Regel 4: Anteil dunkler Module
    $dark = 0; foreach ($v in $M) { $dark += $v }
    $pct = $dark * 100.0 / ($N * $N)
    $p += [int][Math]::Floor([Math]::Abs($pct - 50) / 5) * 10
    return $p
}

# Text -> QR-Matrix. Rueckgabe: @{ Size; Version; Mask; Modules (byte[], Zeile fuer Zeile, 1 = dunkel) }
# -Mask 0..7 erzwingt eine Maske (Tests), sonst die mit den wenigsten Strafpunkten
function ConvertTo-HMQrMatrix {
    param([Parameter(Mandatory)][string]$Text, [int]$Mask = -1)
    $data = [Text.Encoding]::UTF8.GetBytes($Text)
    $ver = 0
    for ($v = 1; $v -le 10; $v++) {
        $b = $script:HMQrM[$v]
        $cap = $b[0] * $b[1] + $b[2] * $b[3]
        $ccBits = if ($v -le 9) { 8 } else { 16 }
        if (4 + $ccBits + 8 * $data.Length -le 8 * $cap) { $ver = $v; break }
    }
    if (-not $ver) { throw "Text zu lang fuer den QR-Code ($($data.Length) Bytes)" }
    $blk = $script:HMQrM[$ver]
    $cap = $blk[0] * $blk[1] + $blk[2] * $blk[3]
    $ccBits = if ($ver -le 9) { 8 } else { 16 }

    # Bitstrom: Modus 0100, Laenge, Daten, Abschluss, Fuellbytes
    $bits = New-Object System.Collections.Generic.List[byte]
    $add = { param([int]$Val, [int]$Len) for ($i = $Len - 1; $i -ge 0; $i--) { $bits.Add([byte](($Val -shr $i) -band 1)) } }
    & $add 4 4
    & $add $data.Length $ccBits
    foreach ($d in $data) { & $add ([int]$d) 8 }
    $max = 8 * $cap
    $t = [Math]::Min(4, $max - $bits.Count); & $add 0 $t
    while ($bits.Count % 8) { $bits.Add(0) }
    $pad = @(0xEC, 0x11); $pi = 0
    while ($bits.Count -lt $max) { & $add $pad[$pi % 2] 8; $pi++ }
    $cw = New-Object byte[] $cap
    for ($i = 0; $i -lt $cap; $i++) { $x = 0; for ($k = 0; $k -lt 8; $k++) { $x = ($x -shl 1) -bor $bits[$i * 8 + $k] }; $cw[$i] = [byte]$x }

    # Bloecke + Korrektur, verschraenkt
    $blocks = New-Object System.Collections.Generic.List[object]
    $eccs = New-Object System.Collections.Generic.List[object]
    $pos = 0
    foreach ($g in @(@($blk[0], $blk[1]), @($blk[2], $blk[3]))) {
        for ($i = 0; $i -lt $g[0]; $i++) {
            $part = New-Object byte[] $g[1]
            [Array]::Copy($cw, $pos, $part, 0, $g[1]); $pos += $g[1]
            $blocks.Add($part)
            $eccs.Add((Get-HMQrEcc $part $blk[4]))
        }
    }
    $final = New-Object System.Collections.Generic.List[byte]
    $maxLen = 0; foreach ($p in $blocks) { if ($p.Length -gt $maxLen) { $maxLen = $p.Length } }
    for ($i = 0; $i -lt $maxLen; $i++) { foreach ($p in $blocks) { if ($i -lt $p.Length) { $final.Add($p[$i]) } } }
    for ($i = 0; $i -lt $blk[4]; $i++) { foreach ($e in $eccs) { $final.Add($e[$i]) } }

    # Funktionsmuster
    $n = 17 + 4 * $ver
    $base = New-Object byte[] ($n * $n)
    $fn = New-Object bool[] ($n * $n)
    $set = { param([int]$X, [int]$Y, [int]$Dark) if ($X -ge 0 -and $Y -ge 0 -and $X -lt $n -and $Y -lt $n) { $base[$Y * $n + $X] = [byte]$Dark; $fn[$Y * $n + $X] = $true } }
    foreach ($o in @(@(0, 0), @(($n - 7), 0), @(0, ($n - 7)))) {
        for ($dy = -1; $dy -le 7; $dy++) {
            for ($dx = -1; $dx -le 7; $dx++) {
                $in = ($dx -ge 0 -and $dx -le 6 -and $dy -ge 0 -and $dy -le 6)
                $dark = 0
                if ($in) { $dist = [Math]::Max([Math]::Abs($dx - 3), [Math]::Abs($dy - 3)); if ($dist -ne 2 -and $dist -ne 4) { $dark = 1 } }
                & $set ($o[0] + $dx) ($o[1] + $dy) $dark
            }
        }
    }
    for ($i = 8; $i -lt $n - 8; $i++) { $d = if ($i % 2 -eq 0) { 1 } else { 0 }; & $set $i 6 $d; & $set 6 $i $d }
    $al = @($script:HMQrAlign[$ver])
    foreach ($ay in $al) {
        foreach ($ax in $al) {
            if (($ax -eq 6 -and $ay -eq 6) -or ($ax -eq 6 -and $ay -eq $al[-1]) -or ($ax -eq $al[-1] -and $ay -eq 6)) { continue }
            for ($dy = -2; $dy -le 2; $dy++) { for ($dx = -2; $dx -le 2; $dx++) { $d = if ([Math]::Max([Math]::Abs($dx), [Math]::Abs($dy)) -eq 1) { 0 } else { 1 }; & $set ($ax + $dx) ($ay + $dy) $d } }
        }
    }
    # Formatbereich reservieren (wird je Maske geschrieben), dunkles Modul
    for ($i = 0; $i -le 8; $i++) { if ($i -ne 6) { & $set 8 $i 0; & $set $i 8 0 } }
    for ($i = 0; $i -lt 8; $i++) { & $set ($n - 1 - $i) 8 0 }
    for ($i = 0; $i -lt 7; $i++) { & $set 8 ($n - 1 - $i) 0 }
    & $set 8 ($n - 8) 1
    # Versionsinformation (ab Version 7)
    if ($ver -ge 7) {
        $rem = $ver
        for ($i = 0; $i -lt 12; $i++) { $rem = ($rem -shl 1) -bxor ((($rem -shr 11) -band 1) * 0x1F25) }
        $vb = ($ver -shl 12) -bor $rem
        for ($i = 0; $i -lt 18; $i++) {
            $bit = ($vb -shr $i) -band 1
            $a = $n - 11 + ($i % 3); $b = [Math]::Floor($i / 3)
            & $set $a $b $bit; & $set $b $a $bit
        }
    }

    # Daten im Zickzack von unten rechts (Spalte 6 = Taktmuster wird uebersprungen)
    $total = $final.Count * 8
    $idx = 0
    $right = $n - 1
    while ($right -ge 1) {
        if ($right -eq 6) { $right = 5 }
        for ($vert = 0; $vert -lt $n; $vert++) {
            for ($j = 0; $j -lt 2; $j++) {
                $x = $right - $j
                $up = ((($right + 1) -band 2) -eq 0)
                $y = if ($up) { $n - 1 - $vert } else { $vert }
                if (-not $fn[$y * $n + $x] -and $idx -lt $total) {
                    $base[$y * $n + $x] = [byte](($final[$idx -shr 3] -shr (7 - ($idx -band 7))) -band 1)
                    $idx++
                }
            }
        }
        $right -= 2
    }

    # Maske anwenden + Formatinformation (Fehlerkorrektur M = 00)
    $build = {
        param([int]$Mk)
        $m = [byte[]]$base.Clone()
        for ($y = 0; $y -lt $n; $y++) {
            for ($x = 0; $x -lt $n; $x++) {
                $k = $y * $n + $x
                if ($fn[$k]) { continue }
                $inv = switch ($Mk) {
                    0 { ($x + $y) % 2 -eq 0 }
                    1 { $y % 2 -eq 0 }
                    2 { $x % 3 -eq 0 }
                    3 { ($x + $y) % 3 -eq 0 }
                    4 { (([Math]::Floor($x / 3) + [Math]::Floor($y / 2)) % 2) -eq 0 }
                    5 { ((($x * $y) % 2) + (($x * $y) % 3)) -eq 0 }
                    6 { (((($x * $y) % 2) + (($x * $y) % 3)) % 2) -eq 0 }
                    default { (((($x + $y) % 2) + (($x * $y) % 3)) % 2) -eq 0 }
                }
                if ($inv) { $m[$k] = [byte](1 - $m[$k]) }
            }
        }
        $d5 = (0 -shl 3) -bor $Mk
        $r = $d5
        for ($i = 0; $i -lt 10; $i++) { $r = ($r -shl 1) -bxor ((($r -shr 9) -band 1) * 0x537) }
        $fb = (($d5 -shl 10) -bor $r) -bxor 0x5412
        $put = { param([int]$X, [int]$Y, [int]$Bit) $m[$Y * $n + $X] = [byte]$Bit }
        for ($i = 0; $i -le 5; $i++) { & $put 8 $i (($fb -shr $i) -band 1) }
        & $put 8 7 (($fb -shr 6) -band 1)
        & $put 8 8 (($fb -shr 7) -band 1)
        & $put 7 8 (($fb -shr 8) -band 1)
        for ($i = 9; $i -lt 15; $i++) { & $put (14 - $i) 8 (($fb -shr $i) -band 1) }
        for ($i = 0; $i -lt 8; $i++) { & $put ($n - 1 - $i) 8 (($fb -shr $i) -band 1) }
        for ($i = 8; $i -lt 15; $i++) { & $put 8 ($n - 15 + $i) (($fb -shr $i) -band 1) }
        & $put 8 ($n - 8) 1
        return , $m
    }
    $best = $null; $bestMask = 0; $bestPen = [int]::MaxValue
    $masks = if ($Mask -ge 0 -and $Mask -le 7) { @($Mask) } else { 0..7 }
    foreach ($mk in $masks) {
        $m = & $build $mk
        $pen = if (@($masks).Count -gt 1) { Get-HMQrPenalty $m $n } else { 0 }
        if ($pen -lt $bestPen) { $bestPen = $pen; $best = $m; $bestMask = $mk }
    }
    return [pscustomobject]@{ Size = $n; Version = $ver; Mask = $bestMask; Modules = $best }
}

# ============================================================================
# GRUNDWERTE
# ============================================================================
$script:HMRemoteAppId    = '{2e99e3ca-a9bd-4634-8f4c-3cf57952321e}'   # Kennung der HTTPS-Bindung (netsh http ... appid)
$script:HMRemoteCaName   = 'HUMig Fernbedienung CA'
$script:HMRemoteCertName = 'HUMig Fernbedienung'
$script:HMRemoteRuleTemp = 'HUMig-Remote'          # Firewall-Regel solange die Fernbedienung laeuft
$script:HMRemoteRuleSetup = 'HUMig-Remote-Setup'   # dauerhafte Regel (fuer den Benutzer-Modus eingerichtet)
$script:HMRemoteMaxDevices = 10
$script:HMRemoteMaxBody  = 4096
$script:HMRemoteMaxLines = 300
$script:HMRemotePairMinutes = 10
$script:HMRemotePrivateNets = @(@('10.0.0.0', '255.0.0.0'), @('172.16.0.0', '255.240.0.0'), @('192.168.0.0', '255.255.0.0'))

# ============================================================================
# ZUFALL, TOKEN, HASH
# ============================================================================
function Get-HMRemoteRandomBytes([int]$Count) {
    $b = New-Object byte[] $Count
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($b) } finally { $rng.Dispose() }
    return , $b
}
# Geraete-Token: 256 Bit, Base64url (ohne = + /)
function New-HMRemoteToken {
    $b = Get-HMRemoteRandomBytes 32
    return ([Convert]::ToBase64String($b).TrimEnd('=').Replace('+', '-').Replace('/', '_'))
}
# Kopplungscode: 6 Ziffern, gleichverteilt (ohne Modulo-Verzerrung)
function New-HMRemotePairCode {
    while ($true) {
        $b = Get-HMRemoteRandomBytes 4
        $v = [BitConverter]::ToUInt32($b, 0)
        if ($v -lt 4294000000) { return ('{0:D6}' -f ($v % 1000000)) }
    }
}
function Get-HMRemoteHash([string]$Text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))) -replace '-', '').ToLowerInvariant() } finally { $sha.Dispose() }
}
# Vergleich in konstanter Zeit (verraet nicht, ab welcher Stelle sich zwei Werte unterscheiden)
function Test-HMRemoteEqual([string]$A, [string]$B) {
    $ha = Get-HMRemoteHash "$A"; $hb = Get-HMRemoteHash "$B"
    $d = 0
    for ($i = 0; $i -lt $ha.Length; $i++) { $d = $d -bor ([int][char]$ha[$i] -bxor [int][char]$hb[$i]) }
    return ($d -eq 0)
}
# Geraetename: nur druckbare Zeichen, hoechstens 40
function ConvertTo-HMRemoteDeviceName([string]$Name) {
    $n = ("$Name" -replace '[\x00-\x1F\x7F<>"`]', '').Trim()
    if ($n.Length -gt 40) { $n = $n.Substring(0, 40).Trim() }
    if (-not $n) { $n = 'Handy' }
    return $n
}

# ============================================================================
# GEKOPPELTE GERAETE (je Windows-Benutzer: %APPDATA%\HUMig\remote-devices.json, nur Hashes)
# ============================================================================
function Get-HMRemoteDeviceFile { return (Join-Path $env:APPDATA 'HUMig\remote-devices.json') }
# Rueckgabe: synchronisierte Hashtable Hash -> @{ Id; Name; Created; LastSeen; LastIp }
function Read-HMRemoteDevices([string]$Path = (Get-HMRemoteDeviceFile)) {
    $h = [hashtable]::Synchronized(@{})
    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $j = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($d in @($j.Devices)) {
                if (-not $d -or "$($d.Hash)" -notmatch '^[0-9a-f]{64}$') { continue }
                $pe = "$($d.PushEndpoint)"; if (-not (Test-HMRemotePushEndpoint $pe)) { $pe = '' }
                $h["$($d.Hash)"] = @{ Id = "$($d.Id)"; Name = (ConvertTo-HMRemoteDeviceName "$($d.Name)"); Created = "$($d.Created)"; LastSeen = "$($d.LastSeen)"; LastIp = "$($d.LastIp)"; PushEndpoint = $pe }
            }
        }
    } catch { }
    return , $h
}
function Save-HMRemoteDevices($Devices, [string]$Path = (Get-HMRemoteDeviceFile)) {
    $list = @()
    foreach ($k in @($Devices.Keys)) { $d = $Devices[$k]; if ($d) { $list += [pscustomobject]@{ Id = $d.Id; Name = $d.Name; Hash = $k; Created = $d.Created; LastSeen = $d.LastSeen; LastIp = $d.LastIp; PushEndpoint = "$($d.PushEndpoint)" } } }
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    $tmp = "$Path.tmp"
    [IO.File]::WriteAllText($tmp, ([pscustomobject]@{ Devices = $list } | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding $false))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

# ============================================================================
# PUSH-MELDUNGEN (Web Push ohne Inhalt, VAPID)
# ============================================================================
# Das Handy wird ueber den Push-Dienst seines Browsers (Google, Apple, Mozilla, Microsoft) "angeklopft" - ohne Inhalt,
# die Dienste sehen also nur den Zeitpunkt. Die App holt die Details danach selbst vom PC (im selben Netz).
# Nur Adressen dieser Dienste werden angenommen (kein Senden an beliebige Adressen im Netz).
$script:HMPushHosts = @('fcm.googleapis.com', 'android.googleapis.com', 'web.push.apple.com', 'updates.push.services.mozilla.com')
$script:HMPushSuffix = @('.push.apple.com', '.notify.windows.com', '.push.services.mozilla.com')
$script:HMPushSub = 'https://github.com/ChiliApple/HUMig'
function Test-HMRemotePushEndpoint([string]$Url) {
    if (-not $Url -or $Url.Length -gt 1024) { return $false }
    $u = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$u)) { return $false }
    if ($u.Scheme -ne 'https' -or -not $u.IsDefaultPort -or $u.UserInfo -or $u.HostNameType -ne 'Dns') { return $false }
    $h = $u.DnsSafeHost.ToLowerInvariant()
    if ($script:HMPushHosts -contains $h) { return $true }
    foreach ($s in $script:HMPushSuffix) { if ($h.EndsWith($s) -and $h.Length -gt $s.Length) { return $true } }
    return $false
}
function ConvertTo-HMB64Url([byte[]]$Bytes) { return ([Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')) }
function Get-HMRemotePushFile { return (Join-Path $env:APPDATA 'HUMig\remote-push.json') }
# VAPID-Schluessel dieses PCs/Kontos (ECDSA P-256): privat nur DPAPI-geschuetzt (aktuelles Konto), Rueckgabe @{ Key (CngKey); Public (b64url, 65 Byte) }
function Get-HMRemoteVapid([string]$Path = (Get-HMRemotePushFile), [switch]$NoCreate) {
    Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
    $ent = [Text.Encoding]::UTF8.GetBytes('HUMig-Push-VAPID')
    $key = $null
    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $j = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
            $blob = [System.Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String("$($j.Private)"), $ent, 'CurrentUser')
            $key = [System.Security.Cryptography.CngKey]::Import($blob, [System.Security.Cryptography.CngKeyBlobFormat]::EccPrivateBlob)
        }
    } catch { $key = $null }
    if (-not $key) {
        if ($NoCreate) { return $null }
        $p = New-Object System.Security.Cryptography.CngKeyCreationParameters
        $p.ExportPolicy = [System.Security.Cryptography.CngExportPolicies]::AllowPlaintextExport
        $key = [System.Security.Cryptography.CngKey]::Create([System.Security.Cryptography.CngAlgorithm]::ECDsaP256, $null, $p)
        $blob = $key.Export([System.Security.Cryptography.CngKeyBlobFormat]::EccPrivateBlob)
        $prot = [System.Security.Cryptography.ProtectedData]::Protect($blob, $ent, 'CurrentUser')
        $dir = Split-Path $Path -Parent
        if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
        [IO.File]::WriteAllText($Path, ([pscustomobject]@{ Private = [Convert]::ToBase64String($prot); Created = (Get-Date).ToString('yyyy-MM-dd HH:mm') } | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))
    }
    # oeffentlicher Schluessel: EccPublicBlob = 8 Byte Kopf + X (32) + Y (32) -> unkomprimierter Punkt 04|X|Y
    $pub = $key.Export([System.Security.Cryptography.CngKeyBlobFormat]::EccPublicBlob)
    $pt = New-Object byte[] 65; $pt[0] = 4; [Array]::Copy($pub, 8, $pt, 1, 64)
    return @{ Key = $key; Public = (ConvertTo-HMB64Url $pt) }
}
# VAPID-Anmeldung (JWT, ES256) fuer einen Push-Dienst: Aud = https://<host>, gilt 12 Stunden
function New-HMRemoteVapidJwt($Vapid, [string]$Aud, [datetime]$Now = (Get-Date)) {
    $exp = [int64](($Now.ToUniversalTime() - [datetime]'1970-01-01').TotalSeconds) + 12 * 3600
    $u8 = New-Object Text.UTF8Encoding $false
    $h = ConvertTo-HMB64Url ($u8.GetBytes('{"typ":"JWT","alg":"ES256"}'))
    $c = ConvertTo-HMB64Url ($u8.GetBytes((ConvertTo-Json -Compress -InputObject ([ordered]@{ aud = $Aud; exp = $exp; sub = $script:HMPushSub }))))
    $ec = New-Object System.Security.Cryptography.ECDsaCng($Vapid.Key)
    try {
        $ec.HashAlgorithm = [System.Security.Cryptography.CngAlgorithm]::Sha256
        $sig = $ec.SignData($u8.GetBytes("$h.$c"))   # IEEE P1363 (r|s, 64 Byte) - wie JWS verlangt
    } finally { $ec.Dispose() }
    return "$h.$c.$(ConvertTo-HMB64Url $sig)"
}
$script:HMPushJwtCache = @{}
# Anfragen fuer alle Handys mit Push-Abo: @{ Hash; Name; Url; Auth }
function Get-HMRemotePushRequests($Devices, $Vapid, [datetime]$Now = (Get-Date)) {
    $out = @()
    foreach ($k in @($Devices.Keys)) {
        $d = $Devices[$k]
        $ep = "$($d.PushEndpoint)"
        if (-not (Test-HMRemotePushEndpoint $ep)) { continue }
        $u = [Uri]$ep
        $aud = "https://$($u.DnsSafeHost)"
        # Anmeldung je Push-Dienst hoechstens stuendlich neu (Apple drosselt haeufigere Erneuerung)
        $ck = "$($Vapid.Public)|$aud"; $c = $script:HMPushJwtCache[$ck]
        if ($c -and $c.Made -le $Now -and ($Now - $c.Made).TotalMinutes -lt 60) { $jwt = $c.Jwt }
        else { $jwt = New-HMRemoteVapidJwt $Vapid $aud $Now; $script:HMPushJwtCache[$ck] = @{ Jwt = $jwt; Made = $Now } }
        $out += @{ Hash = $k; Name = "$($d.Name)"; Url = $ep; Auth = "vapid t=$jwt, k=$($Vapid.Public)" }
    }
    return ,@($out)
}
# Push senden (im Hintergrund-Runspace aufgerufen): leerer POST. Rueckgabe je Anfrage @{ Hash; Name; Code; Error }
$script:HMPushSendScript = {
    param($Reqs)
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    foreach ($q in @($Reqs)) {
        $code = 0; $err = ''
        try {
            $w = [System.Net.HttpWebRequest]::Create($q.Url)
            $w.Method = 'POST'; $w.Timeout = 15000; $w.ReadWriteTimeout = 15000; $w.AllowAutoRedirect = $false
            $w.Headers.Add('Authorization', $q.Auth)
            $w.Headers.Add('TTL', '21600')
            $w.Headers.Add('Urgency', 'high')
            $w.ContentLength = 0
            $resp = $w.GetResponse(); $code = [int]$resp.StatusCode; $resp.Close()
        } catch [System.Net.WebException] {
            if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode; try { $_.Exception.Response.Close() } catch { } } else { $err = "$($_.Exception.Message)" }
        } catch { $err = "$($_.Exception.Message)" }
        @{ Hash = $q.Hash; Name = $q.Name; Url = $q.Url; Code = $code; Error = $err }
    }
}

# ============================================================================
# NETZWERK
# ============================================================================
function ConvertTo-HMRemoteIpInt([string]$Ip) {
    $a = [Net.IPAddress]::Parse($Ip).GetAddressBytes()
    return ([uint32]$a[0] -shl 24) -bor ([uint32]$a[1] -shl 16) -bor ([uint32]$a[2] -shl 8) -bor [uint32]$a[3]
}
function Test-HMRemotePrivateIp([string]$Ip) {
    try {
        $v = ConvertTo-HMRemoteIpInt $Ip
        foreach ($n in $script:HMRemotePrivateNets) { $m = ConvertTo-HMRemoteIpInt $n[1]; if (($v -band $m) -eq ((ConvertTo-HMRemoteIpInt $n[0]) -band $m)) { return $true } }
    } catch { }
    return $false
}
# IPv4-Adressen dieses PCs: @{ IP; Alias; Index; Gateway; Private }. Reihenfolge: mit Standard-Gateway, private, Rest
function Get-HMRemoteIPv4List {
    $out = @()
    try {
        foreach ($nic in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            if ("$($nic.OperationalStatus)" -ne 'Up' -or "$($nic.NetworkInterfaceType)" -eq 'Loopback') { continue }
            $p = $nic.GetIPProperties()
            $gw = @($p.GatewayAddresses | Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' -and "$($_.Address)" -ne '0.0.0.0' }).Count -gt 0
            $idx = -1; try { $idx = $p.GetIPv4Properties().Index } catch { }
            foreach ($u in $p.UnicastAddresses) {
                if ($u.Address.AddressFamily -ne 'InterNetwork') { continue }
                $ip = "$($u.Address)"
                if ($ip -like '169.254.*' -or $ip -like '127.*') { continue }
                $out += [pscustomobject]@{ IP = $ip; Alias = "$($nic.Name)"; Index = $idx; Gateway = $gw; Private = (Test-HMRemotePrivateIp $ip) }
            }
        }
    } catch { }
    return @(Select-HMRemoteIPs $out)
}
function Select-HMRemoteIPs($List) {
    return @(@($List) | Where-Object { $_ } | Sort-Object @{ Expression = { -not $_.Gateway } }, @{ Expression = { -not $_.Private } }, @{ Expression = { $_.IP } })
}
# Netzwerkprofil (Domain/Private/Public) der Schnittstelle, leer = unbekannt
function Get-HMRemoteNetCategory([int]$Index) {
    try { return "$((Get-NetConnectionProfile -InterfaceIndex $Index -ErrorAction Stop | Select-Object -First 1).NetworkCategory)" } catch { return '' }
}
# Port frei? (auch Bindungen anderer Programme ueber http.sys zaehlen, die Liste braucht keine Adminrechte)
function Test-HMRemotePortFree([int]$Port) {
    try {
        foreach ($l in [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()) { if ($l.Port -eq $Port) { return $false } }
    } catch { }
    return $true
}
function Get-HMRemoteFreePort([int]$Start) {
    for ($p = [Math]::Max(1025, $Start + 1); $p -lt [Math]::Min(65535, $Start + 200); $p++) { if (Test-HMRemotePortFree $p) { return $p } }
    return 0
}
# Erlaubte Gegenstellen fuer die Firewall-Regel: lokales Subnetz + eingetragene Netze (a.b.c.d oder a.b.c.d/nn)
function Get-HMRemoteFirewallRemote($Networks) {
    $r = @('LocalSubnet')
    foreach ($n in @($Networks)) {
        $x = "$n".Trim()
        if ($x -match '^(\d{1,3}\.){3}\d{1,3}(/(\d|[12]\d|3[0-2]))?$') {
            $ip = ($x -split '/')[0]
            $okIp = $true; foreach ($o in $ip.Split('.')) { if ([int]$o -gt 255) { $okIp = $false } }
            if ($okIp -and $r -notcontains $x) { $r += $x }
        }
    }
    return $r
}

# ============================================================================
# ZERTIFIKATE (eigene CA je PC, nur als Administrator)
# ============================================================================
# Namen dieses PCs fuer Zertifikate (klein, ohne Doppelte): Kurzname + vollstaendiger Name
function Get-HMRemoteHostNames {
    $n = @("$env:COMPUTERNAME".ToLowerInvariant())
    try { $f = [System.Net.Dns]::GetHostEntry('localhost').HostName } catch { $f = '' }
    try { $d = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().DomainName; if ($d) { $f = "$env:COMPUTERNAME.$d" } } catch { }
    if ($f -and $f -match '\.' ) { $n += $f.ToLowerInvariant() }
    return @($n | Where-Object { $_ -match '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$' } | Select-Object -Unique)
}
# Textform der Namensbeschraenkung: CA darf nur fuer diese Namen und private IPv4-Bereiche ausstellen
function Get-HMRemoteNameConstraintText([string[]]$Names) {
    $p = @('subtree=include')
    foreach ($n in @($Names)) { $p += "DNS=$n" }
    foreach ($x in $script:HMRemotePrivateNets) { $p += "IPAddress=$($x[0]),$($x[1])" }
    return ('2.5.29.30={critical}{text}' + ($p -join '&'))
}
# IPv4-Adressen und DNS-Namen aus der Erweiterung "Alternativer Antragstellername" (DER, sprachunabhaengig)
function Get-HMRemoteSan([byte[]]$Raw) {
    $ips = @(); $dns = @()
    try {
        $i = 0
        if ($Raw[$i] -ne 0x30) { return [pscustomobject]@{ IPs = @(); Dns = @() } }
        $i++
        $len = [int]$Raw[$i]; $i++
        if ($len -band 0x80) { $nb = $len -band 0x7F; $len = 0; for ($k = 0; $k -lt $nb; $k++) { $len = ($len -shl 8) -bor $Raw[$i]; $i++ } }
        $end = $i + $len
        while ($i -lt $end) {
            $tag = $Raw[$i]; $i++
            $l = [int]$Raw[$i]; $i++
            if ($l -band 0x80) { $nb = $l -band 0x7F; $l = 0; for ($k = 0; $k -lt $nb; $k++) { $l = ($l -shl 8) -bor $Raw[$i]; $i++ } }
            if ($tag -eq 0x87 -and $l -eq 4) { $ips += ('{0}.{1}.{2}.{3}' -f $Raw[$i], $Raw[$i + 1], $Raw[$i + 2], $Raw[$i + 3]) }
            elseif ($tag -eq 0x82) { $dns += [Text.Encoding]::ASCII.GetString($Raw, $i, $l).ToLowerInvariant() }
            $i += $l
        }
    } catch { }
    return [pscustomobject]@{ IPs = $ips; Dns = $dns }
}
# SHA-256-Fingerabdruck eines Zertifikats in Vierergruppen (zum Vergleichen am Handy)
function Get-HMRemoteFingerprint($Cert) {
    if (-not $Cert) { return '' }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $h = ([BitConverter]::ToString($sha.ComputeHash($Cert.RawData))) -replace '-', '' } finally { $sha.Dispose() }
    return ((($h -split '(.{4})') | Where-Object { $_ }) -join ' ')
}
function Get-HMRemoteCertSan($Cert) {
    $e = @($Cert.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.17' })[0]
    if (-not $e) { return [pscustomobject]@{ IPs = @(); Dns = @() } }
    return (Get-HMRemoteSan $e.RawData)
}
function Get-HMRemoteCa([string]$Store = 'LocalMachine') {
    $names = Get-HMRemoteHostNames
    $c = @(Get-ChildItem -Path "Cert:\$Store\My" -ErrorAction SilentlyContinue | Where-Object {
            $_.FriendlyName -eq $script:HMRemoteCaName -and $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date).AddDays(60) -and $_.Subject -eq "CN=$($script:HMRemoteCaName) ($($names[0]))"
        } | Sort-Object NotAfter -Descending)
    return $c[0]
}
function New-HMRemoteCa([string]$Store = 'LocalMachine') {
    $names = Get-HMRemoteHostNames
    $p = @{
        Type = 'Custom'; Subject = "CN=$($script:HMRemoteCaName) ($($names[0]))"; FriendlyName = $script:HMRemoteCaName
        KeyUsage = @('CertSign', 'CRLSign', 'DigitalSignature'); KeyAlgorithm = 'RSA'; KeyLength = 2048; HashAlgorithm = 'SHA256'
        KeyExportPolicy = 'NonExportable'; NotAfter = (Get-Date).AddYears(10); CertStoreLocation = "Cert:\$Store\My"
        TextExtension = @('2.5.29.19={critical}{text}ca=1&pathlength=0', (Get-HMRemoteNameConstraintText $names), '2.5.29.37={text}1.3.6.1.5.5.7.3.1')
    }
    return (New-SelfSignedCertificate @p)
}
# Server-Zertifikat passt, wenn es von der CA stammt, noch 30 Tage gilt und alle Adressen + Namen enthaelt
function Test-HMRemoteServerCert($Cert, $Ca, [string[]]$Ips) {
    if (-not $Cert -or -not $Ca) { return $false }
    if ($Cert.Issuer -ne $Ca.Subject -or $Cert.NotAfter -lt (Get-Date).AddDays(30) -or -not $Cert.HasPrivateKey) { return $false }
    $san = Get-HMRemoteCertSan $Cert
    foreach ($ip in @($Ips)) { if ($san.IPs -notcontains $ip) { return $false } }
    foreach ($n in @(Get-HMRemoteHostNames)) { if ($san.Dns -notcontains $n) { return $false } }
    return $true
}
function Get-HMRemoteServerCert($Ca, [string[]]$Ips, [string]$Store = 'LocalMachine') {
    $c = @(Get-ChildItem -Path "Cert:\$Store\My" -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -eq $script:HMRemoteCertName } | Sort-Object NotAfter -Descending)
    foreach ($x in $c) { if (Test-HMRemoteServerCert $x $Ca $Ips) { return $x } }
    return $null
}
# Laufzeit hoechstens 800 Tage (Apple verlangt <= 825 Tage)
function New-HMRemoteServerCert($Ca, [string[]]$Ips, [string]$Store = 'LocalMachine') {
    $san = @(@(Get-HMRemoteHostNames) | ForEach-Object { "DNS=$_" }) + @(@($Ips) | Where-Object { Test-HMRemotePrivateIp $_ } | ForEach-Object { "IPAddress=$_" })
    $p = @{
        Type = 'Custom'; Subject = "CN=$($script:HMRemoteCertName)"; FriendlyName = $script:HMRemoteCertName; Signer = $Ca
        KeyUsage = @('DigitalSignature', 'KeyEncipherment'); KeyAlgorithm = 'RSA'; KeyLength = 2048; HashAlgorithm = 'SHA256'
        KeyExportPolicy = 'NonExportable'; NotAfter = (Get-Date).AddDays(800); CertStoreLocation = "Cert:\$Store\My"
        TextExtension = @(('2.5.29.17={text}' + ($san -join '&')), '2.5.29.37={text}1.3.6.1.5.5.7.3.1', '2.5.29.19={text}ca=0')
    }
    return (New-SelfSignedCertificate @p)
}
# Alte Server-Zertifikate der Fernbedienung entfernen (ausser $Keep)
# Zertifikate, die gerade an eine HTTPS-Bindung (z.B. Einrichtung fuer den Benutzer-Modus) gebunden sind, bleiben ($Keep: weitere)
function Remove-HMRemoteOldCerts([string[]]$Keep, [string]$Store = 'LocalMachine', [int[]]$BoundPorts = @()) {
    $k = @($Keep | Where-Object { $_ } | ForEach-Object { "$_".ToUpperInvariant() })
    foreach ($bp in @($BoundPorts | Where-Object { $_ -gt 0 })) { try { $b = Get-HMRemoteBinding $bp; if ($b.State -eq 'Ours' -and $b.Thumb) { $k += $b.Thumb } } catch { } }
    foreach ($c in @(Get-ChildItem -Path "Cert:\$Store\My" -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -eq $script:HMRemoteCertName -and $k -notcontains $_.Thumbprint.ToUpperInvariant() })) {
        try { Remove-Item -LiteralPath "Cert:\$Store\My\$($c.Thumbprint)" -DeleteKey -ErrorAction Stop } catch { try { Remove-Item -LiteralPath "Cert:\$Store\My\$($c.Thumbprint)" -ErrorAction SilentlyContinue } catch { } }
    }
}

# ============================================================================
# HTTPS-BINDUNG, PORT-FREIGABE, FIREWALL (netsh / NetSecurity)
# ============================================================================
# Ausgabe von "netsh http show sslcert" auswerten (sprachunabhaengig): None | Ours | Foreign, Fingerabdruck
function ConvertFrom-HMRemoteSslShow([string]$Text) {
    $th = ''
    $m = [regex]::Match("$Text", '(?i)\b([0-9a-f]{40})\b')
    if ($m.Success) { $th = $m.Groups[1].Value.ToUpperInvariant() }
    if (-not $th) { return [pscustomobject]@{ State = 'None'; Thumb = '' } }
    $ours = "$Text" -match [regex]::Escape($script:HMRemoteAppId.Trim('{}'))
    return [pscustomobject]@{ State = $(if ($ours) { 'Ours' } else { 'Foreign' }); Thumb = $th }
}
function Get-HMRemoteBinding([int]$Port) {
    $o = (& netsh.exe http show sslcert "ipport=0.0.0.0:$Port" 2>&1 | Out-String)
    return (ConvertFrom-HMRemoteSslShow $o)
}
function Set-HMRemoteBinding([int]$Port, [string]$Thumb) {
    $b = Get-HMRemoteBinding $Port
    if ($b.State -eq 'Foreign') { throw "Port $Port hat bereits eine HTTPS-Bindung eines anderen Programms (Fingerabdruck $($b.Thumb)) - anderen Port waehlen" }
    if ($b.State -eq 'Ours') {
        if ($b.Thumb -eq $Thumb.ToUpperInvariant()) { return }
        $o = & netsh.exe http delete sslcert "ipport=0.0.0.0:$Port" 2>&1
        if ($LASTEXITCODE -ne 0) { throw "HTTPS-Bindung nicht entfernbar: $(@($o) -join ' ')" }
    }
    $o = & netsh.exe http add sslcert "ipport=0.0.0.0:$Port" "certhash=$Thumb" "appid=$($script:HMRemoteAppId)" 'certstorename=MY' 2>&1
    if ($LASTEXITCODE -ne 0) { throw "HTTPS-Bindung nicht moeglich: $(@($o) -join ' ')" }
}
function Remove-HMRemoteBinding([int]$Port) {
    if ((Get-HMRemoteBinding $Port).State -ne 'Ours') { return }
    [void](& netsh.exe http delete sslcert "ipport=0.0.0.0:$Port" 2>&1)
}
# URL-Reservierung (Port-Freigabe) des Benutzer-Modus: das eingerichtete Konto + Administratoren (BA), damit die
# Fernbedienung auf diesem Port auch als Administrator startet. Eine fremde Reservierung wird nie geloescht.
function Get-HMRemoteUrlAclText([int]$Port) { return (& netsh.exe http show urlacl "url=https://+:$Port/" 2>&1 | Out-String) }
# Gehoert die Reservierung (falls vorhanden) uns? Text aus "netsh http show urlacl" (sprachunabhaengig ueber SID/SDDL)
function Test-HMRemoteUrlAclOurs([string]$Text, [int]$Port, [string]$Sid) {
    if ("$Text" -notmatch [regex]::Escape("https://+:$Port/")) { return $true }   # keine Reservierung
    return ($Sid -and "$Text" -match [regex]::Escape("D:(A;;GX;;;$Sid)"))
}
function Set-HMRemoteUrlAcl([int]$Port, [string]$Sid, [string]$OldSid = '') {
    if ($Sid -notmatch '^S-1-5-21-[\d-]+$') { throw "Benutzerkonto ungueltig ($Sid)" }
    $txt = Get-HMRemoteUrlAclText $Port
    if (-not (Test-HMRemoteUrlAclOurs $txt $Port $Sid) -and -not (Test-HMRemoteUrlAclOurs $txt $Port $OldSid)) { throw "Port $Port ist bereits fuer ein anderes Programm/Konto reserviert (netsh http show urlacl) - anderen Port waehlen" }
    if ("$txt" -match [regex]::Escape("https://+:$Port/")) { [void](& netsh.exe http delete urlacl "url=https://+:$Port/" 2>&1) }
    $o = & netsh.exe http add urlacl "url=https://+:$Port/" "sddl=D:(A;;GX;;;$Sid)(A;;GX;;;BA)" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Port-Freigabe fuer das Benutzerkonto nicht moeglich: $(@($o) -join ' ')" }
}
function Remove-HMRemoteUrlAcl([int]$Port, [string]$Sid) {
    $txt = Get-HMRemoteUrlAclText $Port
    if ($Sid -and "$txt" -match [regex]::Escape("https://+:$Port/") -and (Test-HMRemoteUrlAclOurs $txt $Port $Sid)) { [void](& netsh.exe http delete urlacl "url=https://+:$Port/" 2>&1) }
}
function Set-HMRemoteFirewall([string]$Name, [int]$Port, $Remote) {
    Remove-NetFirewallRule -Name $Name -ErrorAction SilentlyContinue
    $p = @{
        Name = $Name; DisplayName = "HUMig Fernbedienung (TCP $Port)"; Group = 'HUMig'; Direction = 'Inbound'; Action = 'Allow'
        Protocol = 'TCP'; LocalPort = "$Port"; Profile = @('Domain', 'Private'); RemoteAddress = @($Remote)
        Program = 'System'   # http.sys (Kernel) nimmt die Verbindungen an - ein anderes Programm auf dem Port bleibt gesperrt
        Description = 'HUMig: Handy-Fernbedienung (nur Domaenen- und private Netze). Wird von HUMig angelegt und entfernt.'
    }
    [void](New-NetFirewallRule @p -ErrorAction Stop)
}
function Remove-HMRemoteFirewall([string]$Name) { Remove-NetFirewallRule -Name $Name -ErrorAction SilentlyContinue }

# ============================================================================
# DATEN FUER DAS HANDY
# ============================================================================
# Startseiten-Daten (Get-HMStatusData) als JSON fuer die Webseite
function ConvertTo-HMRemoteStatusJson($Data) {
    if (-not $Data) { return 'null' }
    $fmt = { param($d) if ($d -is [datetime]) { $d.ToString('dd.MM.yyyy HH:mm') } else { "$d" } }
    $o = [ordered]@{
        time      = (& $fmt $Data.Time)
        warnings  = @(@($Data.Warnings) | Where-Object { $_ } | ForEach-Object { [ordered]@{ level = "$($_.Level)"; area = "$($_.Area)"; text = "$($_.Text)" } })
        schedules = @(@($Data.Schedules) | Where-Object { $_ } | ForEach-Object { [ordered]@{ name = "$($_.Name)"; when = "$($_.When)"; last = "$($_.Last)"; result = "$($_.Result)"; age = $_.SuccessAge; next = "$($_.Next)"; level = "$($_.Level)"; note = "$($_.Note)" } })
        backups   = @(@($Data.Backups) | Where-Object { $_ } | Select-Object -First 15 | ForEach-Object { [ordered]@{ pc = "$($_.Computer)"; user = "$($_.User)"; date = (& $fmt $_.Date); age = $_.Age; status = "$($_.Status)"; size = [long]$_.Size; level = "$($_.Level)"; mass = [bool]$_.Mass } })
        backupsMore = [Math]::Max(0, @($Data.Backups).Count - 15)
        server    = @(@($Data.Server) | Where-Object { $_ } | ForEach-Object { [ordered]@{ name = "$($_.Name)"; level = "$($_.Level)"; lastOk = "$($_.LastOk)"; lastDisk = "$($_.LastDisk)"; archiveDue = [bool]$_.ArchiveDue; disks = @(@($_.Disks) | Where-Object { $_ } | ForEach-Object { [ordered]@{ label = "$($_.Label)"; age = $_.Age; archive = [bool]$_.Archive; health = "$($_.Health)"; level = "$($_.Level)" } }) } })
        apps      = @(@($Data.Apps) | Where-Object { $_ } | ForEach-Object { [ordered]@{ pc = "$($_.Computer)"; ok = [int]$_.Ok; failed = [int]$_.Failed; failedNames = @($_.FailedNames | ForEach-Object { "$_" }); level = "$($_.Level)" } })
    }
    return (ConvertTo-Json -InputObject $o -Depth 6 -Compress)
}
# Laufender Vorgang als JSON. $Job: New-JobState-Hashtable oder $null; $Last: @{ Title; Result; Time } des letzten Vorgangs
# $Mon: Live-Anzeige (Durchsatz, CPU, RAM mit Verlauf) aus UI-Monitor.ps1 - bleibt nach dem Ende mit dem Durchschnitt stehen
function ConvertTo-HMRemoteJobJson($Job, [string]$Title, $Last = $null, [datetime]$Now = (Get-Date), $Mon = $null) {
    if ($Job) {
        $el = [int]($Now - $Job.Started).TotalSeconds
        $pr = [Math]::Max(0, [Math]::Min(100, [int]$Job.Progress))
        $o = [ordered]@{ running = $true; title = "$Title"; progress = $pr; status = "$($Job.Status)"; elapsed = $el; cancel = [bool]$Job.Cancel }
        # Menge (Backup mit Platzpruefung) und geschaetzte Restzeit aus dem bisherigen Tempo
        $tot = [long]$Job.PlanTotal
        if ($tot -gt 0) { $o.bytesTotal = $tot; $o.bytesDone = [Math]::Min($tot, [long]$Job.DoneBytes + [long]$Job.CurBytes) }
        if ($pr -ge 2 -and $pr -lt 100 -and $el -ge 15) { $o.eta = [int]($el * (100 - $pr) / $pr) }
    } else {
        $o = [ordered]@{ running = $false }
        if ($Last) { $o.lastTitle = "$($Last.Title)"; $o.lastResult = "$($Last.Result)"; $o.lastTime = "$($Last.Time)" }
    }
    if ($Mon) { $o.mon = $Mon }
    return (ConvertTo-Json -InputObject $o -Depth 4 -Compress)
}
# Konsolenzeile merken (Ringpuffer, Nummer laeuft weiter)
function Add-HMRemoteLineTo($S, [string]$Msg, [string]$Lvl) {
    if (-not $S) { return }
    if ($Lvl -eq 'Separator') { $Msg = ''; $Lvl = 'Info' }
    $t = "$Msg"; if ($t.Length -gt 400) { $t = $t.Substring(0, 400) + ' ...' }
    [System.Threading.Monitor]::Enter($S.Lines.SyncRoot)
    try {
        $S.LineSeq = [int]$S.LineSeq + 1
        [void]$S.Lines.Add(@{ n = [int]$S.LineSeq; t = $t; l = "$Lvl"; z = (Get-Date).ToString('HH:mm:ss') })
        while ($S.Lines.Count -gt $script:HMRemoteMaxLines) { $S.Lines.RemoveAt(0) }
    } finally { [System.Threading.Monitor]::Exit($S.Lines.SyncRoot) }
}
function New-HMRemoteState {
    return [hashtable]::Synchronized(@{
        Run = $true; Listening = $false; Error = ''; Port = 8443; Version = ''; Pc = "$env:COMPUTERNAME"; UserMode = $false
        Started = (Get-Date); StopAt = $null; Devices = [hashtable]::Synchronized(@{}); DevDirty = $false
        Pair = $null; StatusJson = 'null'; JobJson = '{"running":false}'
        Lines = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList)); LineSeq = 0
        CancelReq = $null; RefreshReq = $false; Static = @{}; FailIp = [hashtable]::Synchronized(@{}); LogFile = ''; PushKey = ''
        HistJson = '[]'; ExtraJson = 'null'; Notice = $null
        Reports = [hashtable]::Synchronized(@{}); Tickets = [hashtable]::Synchronized(@{})
        Events = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue))
    })
}
# Kopplung oeffnen (Code 6 Ziffern, 10 Minuten, 5 Fehlversuche)
function Open-HMRemotePairing($S, [int]$Minutes = $script:HMRemotePairMinutes) {
    $S.Pair = [hashtable]::Synchronized(@{ Code = (New-HMRemotePairCode); Until = (Get-Date).AddMinutes($Minutes); Fails = 0; Locked = $false })
    return $S.Pair.Code
}
function Close-HMRemotePairing($S) { $S.Pair = $null }

# ============================================================================
# ANFRAGEN BEANTWORTEN (ohne HttpListener testbar)
# ============================================================================
# $Req: @{ Method; Path; Query (Hashtable); Auth; Origin; Host; Body; Ip; Now }
# Rueckgabe: @{ Code; Type; Text oder Bytes; NoStore; Log; Headers }
function New-HMRemoteJson([int]$Code, $Obj, [string]$Log = '') {
    $t = if ($Obj -is [string]) { $Obj } else { ConvertTo-Json -InputObject $Obj -Depth 6 -Compress }
    return @{ Code = $Code; Type = 'application/json; charset=utf-8'; Text = $t; NoStore = $true; Log = $Log; Headers = @{} }
}
function Add-HMRemoteFail($S, [string]$Ip, [datetime]$Now) {
    $f = $S.FailIp[$Ip]
    if (-not $f -or $f.First -lt $Now.AddMinutes(-15)) { $f = @{ Count = 0; First = $Now; Until = [datetime]::MinValue } }
    $f.Count++
    if ($f.Count -ge 10) { $f.Until = $Now.AddMinutes(15) }
    $S.FailIp[$Ip] = $f
}
# Meldungstext fuer das Handy mit Alter in Sekunden nach der Uhr DIESES PCs (Handy-Uhr darf abweichen)
# Text und Zeitpunkt liegen in EINEM Objekt (wird als Ganzes getauscht) - nie alter Text mit neuem Zeitpunkt
function Get-HMRemoteNoticeJson($S) {
    $n = $S.Notice
    if (-not $n -or -not $n.At) { return 'null' }
    $nj = "$($n.Json)"
    if (-not $nj -or $nj -notmatch '^\{.*\}$') { return 'null' }
    try { $age = [int][Math]::Max([double]0, ([datetime]::UtcNow - [datetime]$n.At).TotalSeconds) } catch { return 'null' }
    return ($nj.Substring(0, $nj.Length - 1) + ',"age":' + $age + '}')
}
# Bericht ueber eine Einmal-Adresse ausliefern: nur .html bis 10 MB, eigene strenge Richtlinie (keine Skripte, sandbox)
function Get-HMRemoteReportResponse($S, [string]$Ticket, [datetime]$Now) {
    $tk = $S.Tickets[$Ticket]
    if ($tk) { $S.Tickets.Remove($Ticket) }
    $nf = @{ Code = 404; Type = 'text/plain; charset=utf-8'; Text = 'Bericht nicht (mehr) verfuegbar - in der App erneut antippen'; NoStore = $true; Log = 'Bericht: Adresse ungueltig/abgelaufen'; Headers = @{} }
    if (-not $tk -or $tk.Until -lt $Now) { return $nf }
    $p = "$($tk.Path)"
    try {
        if ([IO.Path]::GetExtension($p) -notin @('.html', '.htm')) { return $nf }
        $fi = New-Object IO.FileInfo($p)
        if (-not $fi.Exists) { $nf.Text = 'Bericht nicht erreichbar (z. B. Platte ausgeworfen oder Freigabe nicht verbunden)'; $nf.Log = 'Bericht: Datei fehlt'; return $nf }
        if ($fi.Length -gt 10MB) { $nf.Code = 413; $nf.Text = 'Bericht zu gross fuer das Handy - am PC oeffnen'; return $nf }
        $b = [IO.File]::ReadAllBytes($fi.FullName)
        return @{ Code = 200; Type = 'text/html; charset=utf-8'; Bytes = $b; NoStore = $true; Log = 'Bericht geladen'
            Headers = @{ 'Content-Security-Policy' = "default-src 'none'; style-src 'unsafe-inline'; img-src data:; sandbox; frame-ancestors 'none'; base-uri 'none'; form-action 'none'" } }
    } catch { $nf.Code = 500; $nf.Text = 'Bericht nicht lesbar'; $nf.Log = "Bericht: $($_.Exception.Message)"; return $nf }
}
function Get-HMRemoteResponse($S, $Req) {
    $now = if ($Req.Now) { [datetime]$Req.Now } else { Get-Date }
    $path = "$($Req.Path)"
    $method = "$($Req.Method)".ToUpperInvariant()
    # statische Dateien (Seite, Skript, Design, Icons, Manifest, Service Worker, CA-Zertifikat)
    if (-not $path.StartsWith('/api/')) {
        if ($method -ne 'GET' -and $method -ne 'HEAD') { return (New-HMRemoteJson 405 @{ ok = $false; error = 'Methode nicht erlaubt' }) }
        if ($path -match '^/report/([A-Za-z0-9_-]{43})$') { return (Get-HMRemoteReportResponse $S $Matches[1] $now) }
        $key = if ($path -eq '/' -or $path -eq '') { '/index.html' } else { $path }
        $f = $S.Static[$key]
        if (-not $f) { return @{ Code = 404; Type = 'text/plain; charset=utf-8'; Text = 'Nicht gefunden'; NoStore = $true; Log = ''; Headers = @{} } }
        $h = @{}
        if ($f.Disposition) { $h['Content-Disposition'] = $f.Disposition }
        return @{ Code = 200; Type = $f.Type; Bytes = $f.Bytes; NoStore = [bool]$f.NoStore; Log = $(if ($key -eq '/ca.cer') { 'CA-Zertifikat geladen' } else { '' }); Headers = $h }
    }
    # Sperre nach zu vielen Fehlversuchen von dieser Adresse
    $fi = $S.FailIp[$Req.Ip]
    if ($fi -and $fi.Until -gt $now) { return (New-HMRemoteJson 429 @{ ok = $false; error = 'Zu viele Fehlversuche - bitte 15 Minuten warten' } 'gesperrt (Fehlversuche)') }
    if ($method -ne 'GET' -and $method -ne 'POST') { return (New-HMRemoteJson 405 @{ ok = $false; error = 'Methode nicht erlaubt' }) }
    # Schreibende Anfragen nur von der eigenen Seite (Origin muss zum Host passen)
    if ($method -eq 'POST' -and "$($Req.Origin)" -and "$($Req.Origin)" -ne "https://$($Req.Host)") { return (New-HMRemoteJson 403 @{ ok = $false; error = 'Herkunft nicht erlaubt' } "abgelehnt (Origin $($Req.Origin))") }
    $body = $null
    if ($method -eq 'POST' -and "$($Req.Body)") { try { $body = "$($Req.Body)" | ConvertFrom-Json -ErrorAction Stop } catch { return (New-HMRemoteJson 400 @{ ok = $false; error = 'Ungueltige Anfrage' }) } }

    # --- Koppeln (ohne Token)
    if ($path -eq '/api/pair') {
        if ($method -ne 'POST') { return (New-HMRemoteJson 405 @{ ok = $false; error = 'Methode nicht erlaubt' }) }
        $pr = $S.Pair
        if (-not $pr -or $pr.Until -lt $now) { return (New-HMRemoteJson 409 @{ ok = $false; error = 'Kopplung ist nicht offen - in HUMig den Knopf Handy druecken' } 'Kopplung nicht offen') }
        if ($pr.Locked) { return (New-HMRemoteJson 409 @{ ok = $false; error = 'Kopplung gesperrt (zu viele falsche Codes) - in HUMig neuen Code erzeugen' } 'Kopplung gesperrt') }
        $code = "$($body.code)" -replace '\s', ''
        if ($code -notmatch '^\d{6}$' -or -not (Test-HMRemoteEqual $code $pr.Code)) {
            $pr.Fails++
            if ($pr.Fails -ge 5) { $pr.Locked = $true; $S.Events.Enqueue(@{ Kind = 'PairLocked' }) }
            Add-HMRemoteFail $S $Req.Ip $now
            return (New-HMRemoteJson 403 @{ ok = $false; error = $(if ($pr.Locked) { 'Falscher Code - Kopplung jetzt gesperrt' } else { "Falscher Code (noch $(5 - $pr.Fails) Versuche)" }) } 'falscher Kopplungscode')
        }
        if ($S.Devices.Count -ge $script:HMRemoteMaxDevices) { return (New-HMRemoteJson 409 @{ ok = $false; error = "Hoechstens $($script:HMRemoteMaxDevices) Handys - in HUMig eines entfernen" } 'zu viele Geraete') }
        $name = ConvertTo-HMRemoteDeviceName "$($body.name)"
        $tok = New-HMRemoteToken
        $id = ((Get-HMRemoteHash $tok).Substring(0, 8))
        $S.Devices[(Get-HMRemoteHash $tok)] = @{ Id = $id; Name = $name; Created = $now.ToString('yyyy-MM-dd HH:mm'); LastSeen = $now.ToString('yyyy-MM-dd HH:mm'); LastIp = "$($Req.Ip)" }
        $S.DevDirty = $true
        # Code gilt nur einmal: fuer ein weiteres Handy steht im Fenster sofort ein neuer Code (abfotografierter Code ist wertlos)
        $pr.Code = New-HMRemotePairCode; $pr.Fails = 0
        $S.Events.Enqueue(@{ Kind = 'Paired'; Name = $name; Ip = "$($Req.Ip)" })
        return (New-HMRemoteJson 200 @{ ok = $true; token = $tok; name = $name; pc = "$($S.Pc)" } "gekoppelt: $name")
    }

    # --- ab hier nur mit gueltigem Geraete-Token
    $dev = $null; $dh = ''
    if ("$($Req.Auth)" -match '^Bearer ([A-Za-z0-9_-]{20,100})$') { $dh = Get-HMRemoteHash $Matches[1]; $dev = $S.Devices[$dh] }
    if (-not $dev) {
        Add-HMRemoteFail $S $Req.Ip $now
        return (New-HMRemoteJson 401 @{ ok = $false; error = 'Nicht gekoppelt' } 'ohne gueltiges Token')
    }
    $seen = $now.ToString('yyyy-MM-dd HH:mm')
    if ($dev.LastSeen -ne $seen -or $dev.LastIp -ne "$($Req.Ip)") { $dev.LastSeen = $seen; $dev.LastIp = "$($Req.Ip)"; $S.DevDirty = $true }

    switch ($path) {
        '/api/state' {
            $since = 0; try { $since = [int]"$($Req.Query['since'])" } catch { $since = 0 }
            $lines = @()
            [System.Threading.Monitor]::Enter($S.Lines.SyncRoot)
            try { $lines = @($S.Lines | Where-Object { $_.n -gt $since } | ForEach-Object { [ordered]@{ n = $_.n; t = $_.t; l = $_.l; z = $_.z } }) } finally { [System.Threading.Monitor]::Exit($S.Lines.SyncRoot) }
            $until = if ($S.StopAt) { ([datetime]$S.StopAt).ToString('HH:mm') } else { '' }
            $head = [ordered]@{ ok = $true; pc = "$($S.Pc)"; version = "$($S.Version)"; userMode = [bool]$S.UserMode; device = "$($dev.Name)"; until = $until; seq = [int]$S.LineSeq; lines = $lines }
            $hj = ConvertTo-Json -InputObject $head -Depth 4 -Compress
            # Status und Vorgang sind fertiges JSON (von der Oberflaeche erzeugt)
            $txt = $hj.Substring(0, $hj.Length - 1) + ',"status":' + "$($S.StatusJson)" + ',"job":' + "$($S.JobJson)" + ',"hist":' + "$($S.HistJson)" + ',"extra":' + "$($S.ExtraJson)" + ',"notice":' + $(Get-HMRemoteNoticeJson $S) + '}'
            return (New-HMRemoteJson 200 $txt)
        }
        '/api/cancel' {
            if ($method -ne 'POST') { return (New-HMRemoteJson 405 @{ ok = $false; error = 'Methode nicht erlaubt' }) }
            if (-not ($body -and $body.confirm -eq $true)) { return (New-HMRemoteJson 400 @{ ok = $false; error = 'Bestaetigung fehlt' }) }
            $S.CancelReq = @{ By = "$($dev.Name)"; Ip = "$($Req.Ip)"; At = $now }
            return (New-HMRemoteJson 202 @{ ok = $true } "Abbrechen angefordert ($($dev.Name))")
        }
        '/api/refresh' {
            if ($method -ne 'POST') { return (New-HMRemoteJson 405 @{ ok = $false; error = 'Methode nicht erlaubt' }) }
            $S.RefreshReq = $true
            return (New-HMRemoteJson 202 @{ ok = $true })
        }
        '/api/push' {
            # Push-Meldungen (ohne Inhalt): GET = oeffentlicher Schluessel + Zustand, POST = Abo des Browsers eintragen
            if ($method -eq 'GET') { return (New-HMRemoteJson 200 @{ ok = $true; key = "$($S.PushKey)"; on = [bool]"$($dev.PushEndpoint)" }) }
            if (-not "$($S.PushKey)") { return (New-HMRemoteJson 409 @{ ok = $false; error = 'Push-Meldungen sind an diesem PC nicht verfuegbar' }) }
            $ep = "$($body.endpoint)"
            if (-not (Test-HMRemotePushEndpoint $ep)) { return (New-HMRemoteJson 400 @{ ok = $false; error = 'Push-Dienst nicht erlaubt' } 'Push-Abo abgelehnt (Adresse)') }
            $dev.PushEndpoint = $ep; $S.DevDirty = $true
            return (New-HMRemoteJson 200 @{ ok = $true; on = $true } "Push-Meldungen an: $($dev.Name)")
        }
        '/api/report' {
            # Bericht eines Vorgangs aus dem Verlauf: nur ueber die Kennung (Pfad legt HUMig fest), Einmal-Adresse fuer 60 s
            if ($method -ne 'POST') { return (New-HMRemoteJson 405 @{ ok = $false; error = 'Methode nicht erlaubt' }) }
            $rid = "$($body.id)"
            if ($rid -notmatch '^[0-9a-f]{8}$' -or -not $S.Reports.ContainsKey($rid)) { return (New-HMRemoteJson 404 @{ ok = $false; error = 'Bericht nicht gefunden' }) }
            foreach ($k in @($S.Tickets.Keys)) { if ($S.Tickets[$k].Until -lt $now) { $S.Tickets.Remove($k) } }
            $tk = New-HMRemoteToken
            $S.Tickets[$tk] = @{ Path = "$($S.Reports[$rid])"; Until = $now.AddSeconds(60) }
            return (New-HMRemoteJson 200 @{ ok = $true; url = "/report/$tk" } "Bericht angefordert ($($dev.Name))")
        }
        '/api/push/off' {
            if ($method -ne 'POST') { return (New-HMRemoteJson 405 @{ ok = $false; error = 'Methode nicht erlaubt' }) }
            $dev.PushEndpoint = ''; $S.DevDirty = $true
            return (New-HMRemoteJson 200 @{ ok = $true; on = $false } "Push-Meldungen aus: $($dev.Name)")
        }
        '/api/unpair' {
            if ($method -ne 'POST') { return (New-HMRemoteJson 405 @{ ok = $false; error = 'Methode nicht erlaubt' }) }
            $S.Devices.Remove($dh); $S.DevDirty = $true
            $S.Events.Enqueue(@{ Kind = 'Unpaired'; Name = "$($dev.Name)" })
            return (New-HMRemoteJson 200 @{ ok = $true } "entkoppelt: $($dev.Name)")
        }
    }
    return (New-HMRemoteJson 404 @{ ok = $false; error = 'Nicht gefunden' })
}

# Sicherheits-Kopfzeilen fuer jede Antwort
$script:HMRemoteHeaders = [ordered]@{
    'Content-Security-Policy' = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; manifest-src 'self'; worker-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'"
    'X-Content-Type-Options'  = 'nosniff'
    'X-Frame-Options'         = 'DENY'
    'Referrer-Policy'         = 'no-referrer'
    'Permissions-Policy'      = 'camera=(), microphone=(), geolocation=()'
    'Cross-Origin-Opener-Policy' = 'same-origin'
    'Cross-Origin-Resource-Policy' = 'same-origin'
}

# Zugriffsprotokoll (nie Token oder Codes)
function Write-HMRemoteLog($S, [string]$Text) {
    if (-not $S.LogFile) { return }
    try { [IO.File]::AppendAllText($S.LogFile, ("{0}  {1}`r`n" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Text), (New-Object Text.UTF8Encoding $false)) } catch { }
}

# Webserver-Schleife (im Hintergrund-Runspace). $S.Run = $false beendet sie.
function Start-HMRemoteListenerLoop($S) {
    $l = New-Object System.Net.HttpListener
    $l.Prefixes.Add("https://+:$($S.Port)/")
    try {
        $tm = $l.TimeoutManager
        $tm.HeaderWait = [TimeSpan]::FromSeconds(10); $tm.EntityBody = [TimeSpan]::FromSeconds(10)
        $tm.IdleConnection = [TimeSpan]::FromSeconds(60); $tm.DrainEntityBody = [TimeSpan]::FromSeconds(10)
    } catch { }
    try { $l.Start() } catch { $S.Error = "Webserver nicht gestartet: $($_.Exception.Message)"; $S.Run = $false; return }
    $S.Listening = $true
    Write-HMRemoteLog $S "Start: Port $($S.Port)"
    try {
        while ($S.Run) {
            $t = $l.GetContextAsync()
            while (-not $t.Wait(500)) { if (-not $S.Run) { break } }
            if (-not $S.Run) { break }
            $ctx = $null
            try { $ctx = $t.Result } catch { continue }
            $rq = $ctx.Request; $rs = $ctx.Response
            $ip = ''; try { $ip = "$($rq.RemoteEndPoint.Address)" } catch { }
            try {
                $body = ''
                if ($rq.HasEntityBody) {
                    if ($rq.ContentLength64 -gt $script:HMRemoteMaxBody -or $rq.ContentLength64 -lt 0) { throw [System.IO.InvalidDataException]::new('zu gross') }
                    $buf = New-Object byte[] ([int]$rq.ContentLength64)
                    $read = 0
                    while ($read -lt $buf.Length) { $n = $rq.InputStream.Read($buf, $read, $buf.Length - $read); if ($n -le 0) { break }; $read += $n }
                    $body = [Text.Encoding]::UTF8.GetString($buf, 0, $read)
                }
                $q = @{}
                foreach ($k in @($rq.QueryString.AllKeys)) { if ($k) { $q[$k] = $rq.QueryString[$k] } }
                $origin = "$($rq.Headers['Origin'])"
                $res = Get-HMRemoteResponse $S @{ Method = $rq.HttpMethod; Path = $rq.Url.AbsolutePath; Query = $q; Auth = "$($rq.Headers['Authorization'])"; Origin = $origin; Host = "$($rq.Url.Authority)"; Body = $body; Ip = $ip; Now = (Get-Date) }
            } catch [System.IO.InvalidDataException] {
                $res = New-HMRemoteJson 413 @{ ok = $false; error = 'Anfrage zu gross' } 'Anfrage zu gross'
            } catch {
                $res = New-HMRemoteJson 500 @{ ok = $false; error = 'Interner Fehler' } "Fehler: $($_.Exception.Message)"
            }
            try {
                $rs.StatusCode = [int]$res.Code
                $rs.ContentType = $res.Type
                foreach ($h in $script:HMRemoteHeaders.Keys) { $rs.Headers[$h] = $script:HMRemoteHeaders[$h] }
                $rs.Headers['Cache-Control'] = $(if ($res.NoStore) { 'no-store' } else { 'no-cache' })
                foreach ($h in @($res.Headers.Keys)) { $rs.Headers[$h] = $res.Headers[$h] }
                $bytes = if ($null -ne $res.Bytes) { [byte[]]$res.Bytes } else { [Text.Encoding]::UTF8.GetBytes("$($res.Text)") }
                $rs.ContentLength64 = $bytes.Length
                if ($rq.HttpMethod -ne 'HEAD') { $rs.OutputStream.Write($bytes, 0, $bytes.Length) }
            } catch { } finally { try { $rs.Close() } catch { } }
            if ($res.Log -or [int]$res.Code -ge 400) { Write-HMRemoteLog $S ("{0,-15} {1} {2} {3}{4}" -f $ip, $rq.HttpMethod, ($rq.Url.AbsolutePath -replace '^/report/.*$', '/report/...'), $res.Code, $(if ($res.Log) { " - $($res.Log)" } else { '' })) }
        }
    } finally {
        $S.Listening = $false
        try { $l.Stop() } catch { }
        try { $l.Close() } catch { }
        Write-HMRemoteLog $S 'Ende'
    }
}
