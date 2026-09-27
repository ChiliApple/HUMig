#Requires -Version 5.1
<#
.SYNOPSIS
    Backup-Qualitaet: Pruefsummen-Katalog (SHA-256) im Backup, spaetere Pruefung, Vergleich zweier Backups,
    Restore-Vorschau (was wuerde am Ziel neu angelegt / ueberschrieben).
.DESCRIPTION
    Laeuft im Hintergrund-Runspace (zusammen mit Migration-Engine.ps1) - kein WPF-Code hier.
    Katalog-Datei im Backup-Ordner: Pruefsummen.tsv  (Zeilen: SHA256 <TAB> Groesse <TAB> Aenderungszeit-Ticks-UTC <TAB> relativer Pfad)
    Erfasst werden alle Dateien in den Modul-Unterordnern, nicht die Protokolle im Hauptordner.
#>

$script:HMCatalogName = 'Pruefsummen.tsv'

# Alle Dateien der Modul-Unterordner (relativ zum Backup-Ordner), ohne Reparse-Punkte
function Get-HMBackupFiles([string]$BackupPath) {
    $root = $BackupPath.TrimEnd('\')
    $list = New-Object System.Collections.Generic.List[object]
    $stack = New-Object System.Collections.Generic.Stack[string]
    foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue)) { $stack.Push($d.FullName) }
    while ($stack.Count) {
        $dir = $stack.Pop()
        try {
            foreach ($i in (New-Object System.IO.DirectoryInfo $dir).EnumerateFileSystemInfos()) {
                if ($i.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
                if ($i -is [System.IO.DirectoryInfo]) { $stack.Push($i.FullName); continue }
                $list.Add([pscustomobject]@{ Rel = $i.FullName.Substring($root.Length + 1); Size = [long]$i.Length; Ticks = [long]$i.LastWriteTimeUtc.Ticks; Full = $i.FullName })
            }
        } catch { }
    }
    return $list
}

function Read-HMCatalog([string]$BackupPath) {
    $f = Join-Path $BackupPath $script:HMCatalogName
    $h = @{}
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    foreach ($line in [System.IO.File]::ReadLines($f, [System.Text.Encoding]::UTF8)) {
        if (-not $line -or $line.StartsWith('#')) { continue }
        $p = $line.Split("`t", 4)
        if ($p.Count -lt 4) { continue }
        $h[$p[3].ToLowerInvariant()] = [pscustomobject]@{ Hash = $p[0]; Size = [long]$p[1]; Ticks = [long]$p[2]; Rel = $p[3] }
    }
    return $h
}

function Get-HMFileHash([string]$Path, $Sha) {
    $fs = New-Object System.IO.FileStream ($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite, 1048576, [System.IO.FileOptions]::SequentialScan)
    try { return ([BitConverter]::ToString($Sha.ComputeHash($fs)) -replace '-', '') } finally { $fs.Dispose() }
}

# Katalog erstellen/aktualisieren (inkrementell: unveraenderte Dateien behalten ihre Pruefsumme)
function Update-HMChecksumCatalog {
    param([string]$BackupPath, $Job, [switch]$Quiet)
    $old = Read-HMCatalog $BackupPath
    if (-not $old) { $old = @{} }
    $files = Get-HMBackupFiles $BackupPath
    $total = [long]0; foreach ($f in $files) { $total += $f.Size }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("# HUMig Pruefsummen-Katalog v1 | SHA256 | $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) | Spalten: SHA256, Groesse, Aenderungszeit (Ticks UTC), Pfad")
    $done = [long]0; $n = 0; $new = 0; $errors = 0
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        foreach ($f in $files) {
            if (Test-HMCancel $Job) { break }
            $n++
            $o = $old[$f.Rel.ToLowerInvariant()]
            $hash = $null
            if ($o -and $o.Size -eq $f.Size -and $o.Ticks -eq $f.Ticks -and $o.Hash) { $hash = $o.Hash }
            else {
                try { $hash = Get-HMFileHash $f.Full $sha; $new++ } catch { $errors++; continue }
            }
            [void]$sb.AppendLine(("{0}`t{1}`t{2}`t{3}" -f $hash, $f.Size, $f.Ticks, $f.Rel))
            $done += $f.Size
            if ($Job -and ($n % 200 -eq 0 -or $sw.ElapsedMilliseconds -gt 1000)) {
                $Job.Status = "Pruefsummen: $n / $($files.Count) Dateien - Abbrechen moeglich, das Backup ist schon fertig"
                if ($total -gt 0) { $Job.Progress = [int](100 * $done / $total) }
                $sw.Restart()
            }
        }
    } finally { $sha.Dispose() }
    if (Test-HMCancel $Job) { return $null }
    [System.IO.File]::WriteAllText((Join-Path $BackupPath $script:HMCatalogName), $sb.ToString(), (New-Object System.Text.UTF8Encoding $false))
    return [pscustomobject]@{ Files = $files.Count; Bytes = $total; Hashed = $new; Errors = $errors; Created = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); Algorithm = 'SHA256'; File = $script:HMCatalogName }
}

# Backup gegen seinen Katalog pruefen (Ctx.Backup.Path). Ergebnis in Job.Result, Protokoll im Backup-Ordner
function Test-HMBackupCatalog {
    param([hashtable]$Ctx, $Job)
    $path = $Ctx.Backup.Path
    Write-HMLog $Job "BACKUP PRUEFEN  $path" 'Header'
    $cat = Read-HMCatalog $path
    if (-not $cat) {
        if ($Ctx.CreateCatalog) {
            Write-HMLog $Job 'Kein Pruefsummen-Katalog vorhanden - wird jetzt erstellt (Stand: heute, nicht Stand des Backups)' 'Warning'
            $c = Update-HMChecksumCatalog $path $Job
            if ($c) { Write-HMLog $Job ("Katalog erstellt: {0} Dateien, {1}" -f $c.Files, (Format-HMSize $c.Bytes)) 'Success'; Set-HMManifestValue $path 'Catalog' $c }
            $Job.Result = [pscustomobject]@{ Status = 'Created'; Problems = @() }
            return
        }
        Write-HMLog $Job 'Kein Pruefsummen-Katalog in diesem Backup (erst ab v0.0.5 bzw. Option deaktiviert)' 'Warning'
        $Job.Result = [pscustomobject]@{ Status = 'NoCatalog'; Problems = @() }
        return
    }
    $files = Get-HMBackupFiles $path
    $byRel = @{}; foreach ($f in $files) { $byRel[$f.Rel.ToLowerInvariant()] = $f }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $ok = 0; $bad = New-Object System.Collections.Generic.List[object]; $n = 0
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        foreach ($k in @($cat.Keys)) {
            if (Test-HMCancel $Job) { break }
            $n++
            $e = $cat[$k]; $f = $byRel[$k]
            if (-not $f) { $bad.Add([pscustomobject]@{ Status = 'FEHLT'; Pfad = $e.Rel; Detail = 'Datei fehlt im Backup' }); continue }
            $h = $null
            try { $h = Get-HMFileHash $f.Full $sha } catch { $bad.Add([pscustomobject]@{ Status = 'NICHT LESBAR'; Pfad = $e.Rel; Detail = $_.Exception.Message }); continue }
            if ($h -ne $e.Hash) { $bad.Add([pscustomobject]@{ Status = 'BESCHAEDIGT'; Pfad = $e.Rel; Detail = "Pruefsumme weicht ab (Groesse $($e.Size) -> $($f.Size))" }) }
            else { $ok++ }
            if ($n % 200 -eq 0 -or $sw.ElapsedMilliseconds -gt 1000) { $Job.Status = "Pruefe $n / $($cat.Count)"; $Job.Progress = [int](100 * $n / [Math]::Max(1, $cat.Count)); $sw.Restart() }
        }
    } finally { $sha.Dispose() }
    $extra = @($files | Where-Object { -not $cat.ContainsKey($_.Rel.ToLowerInvariant()) })
    foreach ($x in ($extra | Select-Object -First 500)) { $bad.Add([pscustomobject]@{ Status = 'ZUSAETZLICH'; Pfad = $x.Rel; Detail = 'nicht im Katalog (spaeter hinzugekommen)' }) }
    $cancel = Test-HMCancel $Job
    $st = if ($cancel) { 'Cancelled' } elseif (@($bad | Where-Object { $_.Status -ne 'ZUSAETZLICH' }).Count) { 'Error' } else { 'OK' }
    $sum = "{0} Dateien geprueft: {1} OK, {2} beschaedigt/fehlend, {3} zusaetzlich" -f $n, $ok, @($bad | Where-Object { $_.Status -ne 'ZUSAETZLICH' }).Count, $extra.Count
    Write-HMLog $Job "PRUEFUNG $st - $sum" $(if ($st -eq 'OK') { 'Success' } else { 'Error' })
    try {
        $rep = Join-Path $path ("Pruefung_{0}.txt" -f (Get-Date -Format 'yyyyMMdd_HHmm'))
        (@("HUMig Backup-Pruefung $(Get-Date -Format 'yyyy-MM-dd HH:mm') - $st", $sum, '') + @($bad | ForEach-Object { "$($_.Status)`t$($_.Pfad)`t$($_.Detail)" })) | Set-Content -LiteralPath $rep -Encoding UTF8
        if (-not $cancel) { Set-HMManifestValue $path 'LastCheck' ([pscustomobject]@{ Date = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); Status = $st; Checked = $n; Ok = $ok; Problems = @($bad | Where-Object { $_.Status -ne 'ZUSAETZLICH' }).Count }) }
    } catch { }
    $Job.Progress = 100
    $Job.Result = [pscustomobject]@{ Status = $st; Summary = $sum; Problems = $bad.ToArray() }
}

# Einzelnen Wert im manifest.json setzen (Backups ohne Manifest: nichts tun)
function Set-HMManifestValue([string]$BackupPath, [string]$Name, $Value) {
    $mf = Join-Path $BackupPath 'manifest.json'
    if (-not (Test-Path -LiteralPath $mf)) { return }
    try {
        $m = Get-Content -LiteralPath $mf -Raw -Encoding UTF8 | ConvertFrom-Json
        $m | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
        $m | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $mf -Encoding UTF8 -Force
    } catch { }
}

# ----------------------------------------------------------------------------
# Vergleich zweier Backups (A = aelter, B = neuer): Pruefsummen, wenn beide Kataloge haben, sonst Groesse + Zeit
# ----------------------------------------------------------------------------
function Compare-HMBackups {
    param([hashtable]$Ctx, $Job)
    $a = $Ctx.CompareA; $b = $Ctx.CompareB
    Write-HMLog $Job "VERGLEICH  $(Split-Path $a -Leaf)  <->  $(Split-Path $b -Leaf)" 'Header'
    $ca = Read-HMCatalog $a; $cb = Read-HMCatalog $b
    $useHash = [bool]($ca -and $cb)
    $Job.Status = 'Dateien lesen (A)'
    $fa = @{}; foreach ($f in (Get-HMBackupFiles $a)) { $fa[$f.Rel.ToLowerInvariant()] = $f }
    $Job.Status = 'Dateien lesen (B)'
    $fb = @{}; foreach ($f in (Get-HMBackupFiles $b)) { $fb[$f.Rel.ToLowerInvariant()] = $f }
    $rows = New-Object System.Collections.Generic.List[object]
    $same = 0
    foreach ($k in $fa.Keys) {
        $x = $fa[$k]; $y = $fb[$k]
        if (-not $y) { $rows.Add([pscustomobject]@{ Status = 'nur in A (fehlt in B)'; Pfad = $x.Rel; GroesseA = $x.Size; GroesseB = $null; ZeitA = [DateTime]::new($x.Ticks, 'Utc').ToLocalTime(); ZeitB = $null }); continue }
        $diff = $false
        if ($useHash -and $ca[$k] -and $cb[$k]) { $diff = ($ca[$k].Hash -ne $cb[$k].Hash) } else { $diff = ($x.Size -ne $y.Size -or [Math]::Abs($x.Ticks - $y.Ticks) -gt 20000000) }
        if ($diff) { $rows.Add([pscustomobject]@{ Status = 'geaendert'; Pfad = $x.Rel; GroesseA = $x.Size; GroesseB = $y.Size; ZeitA = [DateTime]::new($x.Ticks, 'Utc').ToLocalTime(); ZeitB = [DateTime]::new($y.Ticks, 'Utc').ToLocalTime() }) } else { $same++ }
    }
    foreach ($k in $fb.Keys) {
        if ($fa.ContainsKey($k)) { continue }
        $y = $fb[$k]
        $rows.Add([pscustomobject]@{ Status = 'nur in B (neu)'; Pfad = $y.Rel; GroesseA = $null; GroesseB = $y.Size; ZeitA = $null; ZeitB = [DateTime]::new($y.Ticks, 'Utc').ToLocalTime() })
    }
    $cnt = @{}; foreach ($r in $rows) { $cnt[$r.Status] = 1 + [int]$cnt[$r.Status] }
    $sum = "{0} gleich, {1} geaendert, {2} nur in A, {3} nur in B ({4})" -f $same, [int]$cnt['geaendert'], [int]$cnt['nur in A (fehlt in B)'], [int]$cnt['nur in B (neu)'], $(if ($useHash) { 'Vergleich per Pruefsumme' } else { 'Vergleich per Groesse/Zeit' })
    Write-HMLog $Job "VERGLEICH: $sum" 'Success'
    $Job.Progress = 100
    $Job.Result = [pscustomobject]@{ Summary = $sum; Rows = $rows.ToArray() }
}

# ----------------------------------------------------------------------------
# Restore-Vorschau: fuer die gewaehlten Module, was am Ziel neu / ueberschrieben / gleich waere
# ----------------------------------------------------------------------------
function Get-HMRestorePreview {
    param([hashtable]$Ctx, $Job)
    $Ctx.IsRemote = -not (Test-HMIsLocal $Ctx.Computer)
    if (-not $Ctx.IsRemote) { $Ctx.Computer = $env:COMPUTERNAME }
    Write-HMLog $Job "RESTORE-VORSCHAU  $($Ctx.Backup.Name)  ->  $($Ctx.Computer) \ $($Ctx.UserFolder)" 'Header'
    $rows = New-Object System.Collections.Generic.List[object]
    $cnt = @{ Neu = 0; Ueberschrieben = 0; ZielNeuer = 0; Gleich = 0 }
    $shareRoot = $null
    $Ctx.HiveReady = $false
    try {
        if ($Ctx.IsRemote -and $Ctx.Credential) { $shareRoot = "\\$($Ctx.Computer)\C$"; [void](Connect-HMShare $shareRoot $Ctx.Credential) }
        if ($Ctx.UserSid) { try { $Ctx.HiveReady = Mount-HMHive $Ctx $Job $Ctx.UserSid $Ctx.ProfilePath } catch { } }
        $tenv = Get-HMTargetEnv $Ctx $Ctx.UserSid $Ctx.ProfilePath
        $mf = $Ctx.Backup.Manifest
        foreach ($mod in @($Ctx.Modules)) {
            if (Test-HMCancel $Job) { break }
            $Job.Status = $mod.Name
            foreach ($it in @($mod.Items)) {
                if ($it.Type -eq 'Reg') {
                    $src = Get-HMRestoreSource $Ctx $mod $it
                    if ($src -and (Test-Path -LiteralPath $src)) { $rows.Add([pscustomobject]@{ Aktion = 'Registry-Import'; Modul = $mod.Name; Ziel = "$($it.Key)"; Groesse = $null; Backup = $null; Ziel_Datei = $null }) }
                    continue
                }
                if ($it.Type -eq 'Builtin') {
                    if ((Test-Path -LiteralPath (Join-Path $Ctx.Backup.Path $mod.Id)) -or $Ctx.Backup.Legacy) { $rows.Add([pscustomobject]@{ Aktion = 'Spezial-Wiederherstellung'; Modul = $mod.Name; Ziel = "$($it.Handler)"; Groesse = $null; Backup = $null; Ziel_Datei = $null }) }
                    continue
                }
                if ($null -eq $Ctx.UserSid -and $mod.Scope -eq 'User') { continue }
                $src = Get-HMRestoreSource $Ctx $mod $it
                if (-not $src -or -not (Test-Path -LiteralPath $src)) { continue }
                $dstLocal = Resolve-HMToken $tenv $it.Path
                $dst = Convert-HMPath $Ctx $dstLocal
                $skip = @()
                if ($mf -and $mf.SyncRoots) { foreach ($s in @($mf.SyncRoots | Where-Object { $_ -and $_.Rel -and $_.Item -eq "$($mod.Id)/$($it.Name)" })) { $skip += (Join-Path $src $s.Rel).TrimEnd('\') + '\' } }
                $pattern = if ($it.Type -eq 'Files') { @($it.Filter) } else { @('*') }
                $opt = if ($it.Type -eq 'Files') { [System.IO.SearchOption]::TopDirectoryOnly } else { [System.IO.SearchOption]::AllDirectories }
                $files = @()
                try { $files = @(foreach ($p in $pattern) { [System.IO.Directory]::EnumerateFiles($src, $p, $opt) }) } catch { }
                foreach ($f in $files) {
                    if (Test-HMCancel $Job) { break }
                    $isSkip = $false; foreach ($s in $skip) { if ($f.StartsWith($s, [StringComparison]::OrdinalIgnoreCase)) { $isSkip = $true; break } }
                    if ($isSkip) { continue }
                    $rel = $f.Substring($src.TrimEnd('\').Length).TrimStart('\')
                    $si = New-Object System.IO.FileInfo $f
                    $di = New-Object System.IO.FileInfo (Join-Path $dst $rel)
                    $target = Join-Path $dstLocal $rel
                    if (-not $di.Exists) { $cnt.Neu++; if ($rows.Count -lt 20000) { $rows.Add([pscustomobject]@{ Aktion = 'neu'; Modul = $mod.Name; Ziel = $target; Groesse = $si.Length; Backup = $si.LastWriteTime; Ziel_Datei = $null }) }; continue }
                    $d = $si.LastWriteTimeUtc.Ticks - $di.LastWriteTimeUtc.Ticks
                    if ($si.Length -eq $di.Length -and [Math]::Abs($d) -le 20000000) { $cnt.Gleich++; continue }
                    if ($d -lt -20000000) {
                        $cnt.ZielNeuer++
                        $a = if ($Ctx.Options.KeepNewer) { 'Ziel neuer - bleibt' } else { 'UEBERSCHREIBT neuere Zieldatei' }
                        $rows.Add([pscustomobject]@{ Aktion = $a; Modul = $mod.Name; Ziel = $target; Groesse = $si.Length; Backup = $si.LastWriteTime; Ziel_Datei = $di.LastWriteTime })
                    } else {
                        $cnt.Ueberschrieben++
                        $rows.Add([pscustomobject]@{ Aktion = 'ueberschreibt (Ziel aelter)'; Modul = $mod.Name; Ziel = $target; Groesse = $si.Length; Backup = $si.LastWriteTime; Ziel_Datei = $di.LastWriteTime })
                    }
                }
            }
        }
    } finally {
        try { Dismount-HMHive $Ctx $Job } catch { }
        if ($shareRoot) { Disconnect-HMShare $shareRoot }
    }
    $sum = "{0} neu, {1} ueberschreiben aeltere Zieldateien, {2} Zieldatei NEUER{3}, {4} gleich (werden uebersprungen)" -f $cnt.Neu, $cnt.Ueberschrieben, $cnt.ZielNeuer, $(if ($Ctx.Options.KeepNewer) { ' (bleibt wegen Option)' } else { ' (wuerde ueberschrieben!)' }), $cnt.Gleich
    Write-HMLog $Job "VORSCHAU: $sum" $(if ($cnt.ZielNeuer -and -not $Ctx.Options.KeepNewer) { 'Warning' } else { 'Success' })
    $Job.Progress = 100
    $Job.Result = [pscustomobject]@{ Summary = $sum; Rows = $rows.ToArray(); Counts = $cnt }
}

# Katalog fuer ein vorhandenes Backup erstellen/aktualisieren (Knopf "Backup pruefen", Rechtsklick)
function Start-HMCatalogUpdate {
    param([hashtable]$Ctx, $Job)
    $path = $Ctx.Backup.Path
    Write-HMLog $Job "PRUEFSUMMEN-KATALOG  $path" 'Header'
    $c = Update-HMChecksumCatalog $path $Job
    if (-not $c) { Write-HMLog $Job 'abgebrochen' 'Warning'; $Job.Result = [pscustomobject]@{ Status = 'Cancelled' }; return }
    Set-HMManifestValue $path 'Catalog' $c
    Write-HMLog $Job ("Katalog: {0} Dateien, {1} ({2} neu berechnet)" -f $c.Files, (Format-HMSize $c.Bytes), $c.Hashed) 'Success'
    $Job.Progress = 100
    $Job.Result = [pscustomobject]@{ Status = 'OK'; Catalog = $c }
}

# ============================================================================
# PROGRAMME: installierte Software am Quell-/Ziel-PC, Abgleich mit dem Programm-Katalog (Config\apps*.json)
# ============================================================================
# Laeuft am Ziel-PC (lokal oder Invoke-Command). Ausgabe: Objekte Name/Version/Publisher/Scope
$script:HMSoftwareScript = {
    param($sid)
    $roots = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')
    if ($sid) { $roots += "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\Uninstall" }
    $seen = @{}
    foreach ($root in $roots) {
        foreach ($k in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
            if (-not $p.DisplayName -or $p.SystemComponent -eq 1 -or $p.ParentKeyName) { continue }
            $key = "$($p.DisplayName)|$($p.DisplayVersion)"
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = 1
            [pscustomobject]@{ Name = "$($p.DisplayName)".Trim(); Version = "$($p.DisplayVersion)"; Publisher = "$($p.Publisher)"; Scope = $(if ($root -like '*HKEY_USERS*') { 'Benutzer' } else { 'Computer' }) }
        }
    }
}
function Get-HMInstalledSoftware([hashtable]$Ctx, [string]$Sid) {
    return @(Invoke-HMTarget $Ctx $script:HMSoftwareScript @($Sid) | ForEach-Object { [pscustomobject]@{ Name = "$($_.Name)"; Version = "$($_.Version)"; Publisher = "$($_.Publisher)"; Scope = "$($_.Scope)" } })
}
# Katalog-Eintraege, die zur Software-Liste passen (Detect = Regex auf den Anzeigenamen)
function Find-HMCatalogApps([object[]]$Software, [object[]]$Catalog) {
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($a in @($Catalog)) {
        if (-not $a -or -not "$($a.Detect)") { continue }
        $hit = $null
        foreach ($s in @($Software)) { try { if ("$($s.Name)" -match "$($a.Detect)") { $hit = $s; break } } catch { break } }
        if ($hit) { $out.Add([pscustomobject]@{ Id = "$($a.Id)"; Name = "$($a.Name)"; Version = "$($hit.Version)"; Found = "$($hit.Name)" }) }
    }
    return $out.ToArray()
}

# ============================================================================
# ORDNERFREIGABEN (SMB) mit Freigabe- und NTFS-Berechtigungen
# ============================================================================
# Liest alle Datei-Freigaben (ohne Admin-Freigaben C$/ADMIN$/IPC$ und print$). Konten mit SID (sprachunabhaengig)
$script:HMShareReadScript = {
    function Get-HUSid([string]$n) { try { (New-Object System.Security.Principal.NTAccount($n)).Translate([System.Security.Principal.SecurityIdentifier]).Value } catch { '' } }
    foreach ($s in @(Get-SmbShare -Special $false -ErrorAction SilentlyContinue | Where-Object { "$($_.ShareType)" -eq 'FileSystemDirectory' -and $_.Name -ne 'print$' })) {
        $acc = @(Get-SmbShareAccess -Name $s.Name -ErrorAction SilentlyContinue | ForEach-Object { [pscustomobject]@{ Account = "$($_.AccountName)"; Sid = (Get-HUSid "$($_.AccountName)"); Type = "$($_.AccessControlType)"; Right = "$($_.AccessRight)" } })
        $ntfs = @(); $sddl = ''
        try {
            $a = Get-Acl -LiteralPath $s.Path -ErrorAction Stop
            $sddl = $a.Sddl
            $ntfs = @($a.Access | ForEach-Object { [pscustomobject]@{ Account = "$($_.IdentityReference)"; Rights = "$($_.FileSystemRights)"; Type = "$($_.AccessControlType)"; Inherited = [bool]$_.IsInherited } })
        } catch { }
        [pscustomobject]@{ Name = "$($s.Name)"; Path = "$($s.Path)"; Description = "$($s.Description)"; FolderEnumerationMode = "$($s.FolderEnumerationMode)"; CachingMode = "$($s.CachingMode)"
            PathExists = (Test-Path -LiteralPath $s.Path); Access = $acc; Ntfs = $ntfs; Sddl = $sddl; Computer = $env:COMPUTERNAME }
    }
}
# Legt Freigaben an (vorhandene werden uebersprungen). $json = Array aus HMShareReadScript. $ntfs = NTFS-Rechte (SDDL) auf den Ordner setzen
$script:HMShareCreateScript = {
    param([string]$Json, [bool]$Ntfs)
    function Resolve-HUAcc($e) {
        if ($e.Sid) { try { return (New-Object System.Security.Principal.SecurityIdentifier($e.Sid)).Translate([System.Security.Principal.NTAccount]).Value } catch { } }
        try { [void](New-Object System.Security.Principal.NTAccount($e.Account)).Translate([System.Security.Principal.SecurityIdentifier]); return $e.Account } catch { return $null }
    }
    $arr = $Json | ConvertFrom-Json   # PS 5.1: Array als ein Objekt -> foreach ueber die Variable
    foreach ($s in $arr) {
        try {
            if (Get-SmbShare -Name $s.Name -ErrorAction SilentlyContinue) { "WARN $($s.Name): Freigabe existiert bereits - nicht veraendert"; continue }
            $new = $false
            if (-not (Test-Path -LiteralPath $s.Path)) { New-Item -ItemType Directory -Path $s.Path -Force -ErrorAction Stop | Out-Null; $new = $true }
            $full = @(); $chg = @(); $rd = @(); $deny = @(); $miss = @()
            foreach ($e in @($s.Access)) {
                $n = Resolve-HUAcc $e
                if (-not $n) { $miss += "$($e.Account)"; continue }
                if ("$($e.Type)" -eq 'Deny') { $deny += $n; continue }
                switch ("$($e.Right)") { 'Full' { $full += $n } 'Change' { $chg += $n } 'Read' { $rd += $n } }
            }
            if (-not ($full.Count + $chg.Count + $rd.Count)) { $full = @((New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')).Translate([System.Security.Principal.NTAccount]).Value) }
            $p = @{ Name = $s.Name; Path = $s.Path; ErrorAction = 'Stop' }
            if ($s.Description) { $p.Description = $s.Description }
            if ($s.FolderEnumerationMode -in 'AccessBased', 'Unrestricted') { $p.FolderEnumerationMode = $s.FolderEnumerationMode }
            if ($s.CachingMode -in 'None', 'Manual', 'Documents', 'Programs', 'BranchCache') { $p.CachingMode = $s.CachingMode }
            if ($full.Count) { $p.FullAccess = $full }
            if ($chg.Count) { $p.ChangeAccess = $chg }
            if ($rd.Count) { $p.ReadAccess = $rd }
            New-SmbShare @p | Out-Null
            foreach ($d in $deny) { try { Block-SmbShareAccess -Name $s.Name -AccountName $d -Force -ErrorAction Stop | Out-Null } catch { $miss += "$d (Verweigern)" } }
            $msg = "OK $($s.Name) -> $($s.Path)$(if ($new) { ' (Ordner neu angelegt)' })"
            if ($Ntfs -and $s.Sddl) {
                try { $acl = Get-Acl -LiteralPath $s.Path; $acl.SetSecurityDescriptorSddlForm($s.Sddl); Set-Acl -LiteralPath $s.Path -AclObject $acl -ErrorAction Stop; $msg += ', NTFS-Rechte gesetzt' }
                catch { $msg += ", NTFS-Rechte FEHLER: $($_.Exception.Message)" }
            }
            if ($miss.Count) { $msg = ($msg -replace '^OK ', 'WARN ') + " - Konten unbekannt: $($miss -join ', ')" }
            $msg
        } catch { "FEHLER $($s.Name): $($_.Exception.Message)" }
    }
}
# Freigabe-Rechte / NTFS-Rechte als lesbarer Text
function Format-HMShareAccess($Share) {
    return (@($Share.Access | ForEach-Object { "$($_.Account): $($_.Right)$(if ($_.Type -eq 'Deny') { ' VERWEIGERT' })" }) -join '; ')
}
function Format-HMNtfsAccess($Share) {
    $exp = @($Share.Ntfs | Where-Object { -not $_.Inherited } | ForEach-Object { "$($_.Account): $($_.Rights -replace ', Synchronize', '')$(if ($_.Type -eq 'Deny') { ' VERWEIGERT' })" })
    $inh = @($Share.Ntfs | Where-Object { $_.Inherited }).Count
    return (($exp -join '; ') + $(if ($inh) { "$(if ($exp.Count) { '; ' })+ $inh geerbt" } else { '' }))
}

