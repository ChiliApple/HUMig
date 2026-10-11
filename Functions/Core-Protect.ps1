#Requires -Version 5.1
<#
.SYNOPSIS
    Schutz des Arbeitsordners %ProgramData%\HUMig am Ziel-PC und Pruefung von Profil-Sicherungen.
.DESCRIPTION
    %ProgramData% erlaubt Standardbenutzern, Dateien und Ordner anzulegen (und gibt ihnen Vollzugriff auf alles, was sie selbst
    anlegen). Liegen dort Skripte, die als SYSTEM/Administrator laufen (App-Update-Zeitplan) oder Dateien, die HUMig mit Adminrechten
    ausfuehrt/importiert (Profil-Sicherungen), koennte ein Benutzer sie austauschen. Darum:
      Protect-HMDataDir   - %ProgramData%\HUMig: Besitzer Administratoren, nur SYSTEM + Administratoren schreiben, Benutzer lesen.
                            Verknuepfungen (Junction/Symlink) im Ordner werden entfernt (nur der Link, nie das Ziel).
                            Was sicher einem Nicht-Administrator gehoert (auch die Wurzel selbst), wird nicht uebernommen,
                            sondern nach %ProgramData%\HUMig.unsicher_<Zeit> verschoben. Ist der Besitzer nicht feststellbar
                            (Besitzer nicht lesbar oder Mitglieder der Gruppe Administratoren nicht abfragbar), wird wie
                            frueher uebernommen und eine Warnung zurueckgegeben.
      Test-HMProfileBackup - prueft eine Profil-Sicherung (Profil_<SID>_<Zeit>.json) vor dem Zurueckholen.
    Die Datei wird als Text an entfernte PCs uebergeben (Invoke-Command) - deshalb ohne Abhaengigkeiten.
.NOTES
    Zielmaschine: der jeweilige PC (lokal oder per WinRM), als Administrator oder SYSTEM.
#>

function Protect-HMDataDir {
    if (-not "$env:ProgramData".Trim() -or -not [System.IO.Path]::IsPathRooted($env:ProgramData)) { throw 'ProgramData-Pfad unbekannt' }
    $root = Join-Path $env:ProgramData 'HUMig'
    $admSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $okSids = @('S-1-5-18', 'S-1-5-32-544')
    $badRights = [long][System.Security.AccessControl.FileSystemRights]'WriteData, AppendData, WriteExtendedAttributes, WriteAttributes, Delete, DeleteSubdirectoriesAndFiles, ChangePermissions, TakeOwnership'
    $badRights = $badRights -bor 0x50000000L   # GENERIC_WRITE, GENERIC_ALL
    $rp = [System.IO.FileAttributes]::ReparsePoint
    # Besitzer, die HUMig-Daten haben koennen: SYSTEM, Administratoren, das ausfuehrende (Administrator-)Konto selbst und
    # andere Konten, die direkt in der lokalen Gruppe Administratoren sind (je nach Richtlinie ist der Ersteller Besitzer)
    $meSid = ''
    try { $meSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch { }
    $ownOk = @($okSids + $meSid | Where-Object { $_ })
    # Mitglieder der Gruppe Administratoren: einmal je Aufruf abfragen; Fehler merken (dann wird nichts verschoben)
    $admCache = @{ Done = $false; Ok = $false; M = @() }
    # Besitzer einordnen: 'ok' = SYSTEM/Administratoren/eigenes Konto/direktes Mitglied der Administratoren,
    # 'foreign' = sicher kein Administrator (Abfrage erfolgreich, nicht enthalten) -> verschieben,
    # 'unknown' = Besitzer nicht lesbar oder Abfrage fehlgeschlagen -> konservativ uebernehmen (wie frueher) + Warnung
    $ownerState = {
        param([string]$Sid)
        if (-not $Sid) { return 'unknown' }
        if ($ownOk -contains $Sid) { return 'ok' }
        if (-not $admCache.Done) {
            $admCache.Done = $true
            try { $admCache.M = @(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop | ForEach-Object { "$($_.SID)" }); $admCache.Ok = $true } catch { $admCache.Ok = $false }
        }
        if (-not $admCache.Ok) { return 'unknown' }
        if (@($admCache.M) -contains $Sid) { return 'ok' }
        return 'foreign'
    }
    $warn = New-Object System.Collections.Generic.List[string]
    $getOwner = {
        param([string]$Path, [bool]$Dir)
        try {
            $s0 = if ($Dir) { [System.IO.Directory]::GetAccessControl($Path, [System.Security.AccessControl.AccessControlSections]::Owner) } else { [System.IO.File]::GetAccessControl($Path, [System.Security.AccessControl.AccessControlSections]::Owner) }
            return $s0.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
        } catch { return '' }
    }
    # Beiseite-Ordner fuer fremde Inhalte (Benutzer-Besitz): neben der Wurzel, erst bei Bedarf angelegt
    $aside = "$root.unsicher_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    $moved = 0
    # Fertige Rechte fuer die Wurzel: Besitzer Administratoren, Vererbung aus, SYSTEM + Administratoren Vollzugriff, Benutzer Lesen
    $sec = New-Object System.Security.AccessControl.DirectorySecurity
    $sec.SetOwner($admSid)
    $sec.SetAccessRuleProtection($true, $false)
    foreach ($x in @(@('S-1-5-18', 'FullControl'), @('S-1-5-32-544', 'FullControl'), @('S-1-5-32-545', 'ReadAndExecute'))) {
        $sec.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule((New-Object System.Security.Principal.SecurityIdentifier($x[0])), [System.Security.AccessControl.FileSystemRights]$x[1], 'ContainerInherit, ObjectInherit', 'None', 'Allow')))
    }
    # 1. Wurzel: Verknuepfung -> nur den Link entfernen. Gehoert sie nicht SYSTEM/Administratoren (z. B. von einem Benutzer
    #    vorab angelegt - ProgramData erlaubt das), wird sie NICHT uebernommen, sondern beiseitegeschoben. Fehlt sie danach:
    #    mit den fertigen Rechten anlegen (kein Moment, in dem ein Benutzer darin etwas anlegen koennte).
    $fresh = $false
    for ($i = 1; $i -le 3; $i++) {
        if (-not [System.IO.Directory]::Exists($root)) {
            if ([System.IO.File]::Exists($root)) { [System.IO.File]::Move($root, "$aside.datei"); continue }   # Datei statt Ordner
            $di = New-Object System.IO.DirectoryInfo $root
            # Windows PowerShell 5.1 (.NET Framework): DirectoryInfo.Create(DirectorySecurity). pwsh 7 (.NET) kennt das nicht ->
            # FileSystemAclExtensions.Create, sonst normal anlegen (Rechte setzt dann Schritt 3 wie bisher)
            try {
                if ($di.GetType().GetMethod('Create', [type[]]@([System.Security.AccessControl.DirectorySecurity]))) { $di.Create($sec); $fresh = $true }
                elseif ('System.IO.FileSystemAclExtensions' -as [type]) { [System.IO.FileSystemAclExtensions]::Create($di, $sec); $fresh = $true }
                else { $di.Create() }
            } catch { if (-not [System.IO.Directory]::Exists($root)) { $di.Create() }; $fresh = $false }
            continue
        }
        if (([System.IO.File]::GetAttributes($root) -band $rp) -ne 0) { [System.IO.Directory]::Delete($root, $false); $fresh = $false; continue }
        $os = & $ownerState (& $getOwner $root $true)
        if ($os -ne 'foreign') { break }
        [System.IO.Directory]::Move($root, $aside); $moved++; $fresh = $false
    }
    if (-not [System.IO.Directory]::Exists($root) -or (([System.IO.File]::GetAttributes($root) -band $rp) -ne 0)) {
        throw "$root konnte nicht sicher angelegt werden (wird gerade von jemand anderem angelegt?)"
    }
    $os = & $ownerState (& $getOwner $root $true)
    if ($os -eq 'foreign') { throw "$root konnte nicht sicher angelegt werden (wird gerade von jemand anderem angelegt?)" }
    if ($os -eq 'unknown') { $warn.Add("Besitzer von $root nicht sicher feststellbar - uebernommen statt verschoben") }
    # 2. schon geschuetzt? (Vererbung aus, Besitzer Administratoren/SYSTEM, niemand sonst mit Schreibrecht)
    $isSafe = {
        try {
            $acl = [System.IO.Directory]::GetAccessControl($root)
            if (-not $acl.AreAccessRulesProtected) { return $false }
            if ($okSids -notcontains $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value) { return $false }
            foreach ($r in $acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])) {
                if ("$($r.AccessControlType)" -eq 'Allow' -and $okSids -notcontains $r.IdentityReference.Value -and (([long]$r.FileSystemRights -band $badRights) -ne 0)) { return $false }
            }
            return $true
        } catch { return $false }
    }
    if (& $isSafe) {
        if ($fresh -or $moved) { return "$root abgesichert (nur Administratoren/SYSTEM duerfen schreiben)$(if ($moved) { " - fremder Inhalt verschoben nach $aside" })" }
        return
    }
    # Warnungen fuer die Rueckgabe (am Ende angehaengt)
    $warnText = { if ($warn.Count) { " - Warnung: $(@($warn | Select-Object -First 5) -join '; ')$(if ($warn.Count -gt 5) { " (+$($warn.Count - 5) weitere)" })" } else { '' } }
    # Besitz uebernehmen: icacls setzt den Besitzer auch ohne Zugriffsrecht (Wiederherstellungsrecht der Administratoren)
    $takeOver = {
        param([string]$Path)
        $o = & icacls.exe "$Path" /setowner '*S-1-5-32-544' /C /Q 2>&1
        if ($LASTEXITCODE -ne 0) { $o2 = & takeown.exe /F "$Path" /A 2>&1; if ($LASTEXITCODE -ne 0) { throw "Besitz von $Path nicht uebernehmbar: $o $o2" } }
    }
    # 3. Wurzel absichern: Besitzer Administratoren, Vererbung aus, SYSTEM + Administratoren Vollzugriff, Benutzer Lesen
    #    (Wurzel gehoert hier schon SYSTEM/Administratoren/dem eigenen Konto oder der Besitzer war nicht feststellbar -
    #    HUMig-Daten darin bleiben erhalten)
    & $takeOver $root
    [System.IO.Directory]::SetAccessControl($root, $sec)
    # 4. Inhalt: Verknuepfungen entfernen (nur den Link). Eintraege, die einem Benutzer gehoeren, werden nicht uebernommen,
    #    sondern in den Beiseite-Ordner verschoben (Umbenennen folgt keiner Verknuepfung). Alles andere: Besitzer
    #    Administratoren, nur geerbte Rechte (auch bei nicht feststellbarem Besitzer, dann mit Warnung).
    #    Eigener Durchlauf statt icacls /T: folgt keinen Verknuepfungen.
    #    Zweimal, falls waehrenddessen etwas angelegt wurde.
    for ($pass = 1; $pass -le 2; $pass++) {
        $stack = New-Object System.Collections.Generic.Stack[string]
        $stack.Push($root)
        while ($stack.Count) {
            $d = $stack.Pop()
            $entries = $null
            try { $entries = [System.IO.Directory]::GetFileSystemEntries($d) }
            catch { & $takeOver $d; $null = & icacls.exe "$d" /reset /C /Q 2>&1; $entries = [System.IO.Directory]::GetFileSystemEntries($d) }
            foreach ($e in $entries) {
                $a = [System.IO.File]::GetAttributes($e)
                if (($a -band $rp) -ne 0) {
                    # Junction/Symlink: nur den Link entfernen. Andere Reparse-Punkte (z. B. komprimierte Dateien) bleiben,
                    # Ordner dieser Art werden nicht durchlaufen.
                    $lt = "$((Get-Item -LiteralPath $e -Force -ErrorAction SilentlyContinue).LinkType)"
                    $isDir = (($a -band [System.IO.FileAttributes]::Directory) -ne 0)
                    if ($lt -in @('Junction', 'SymbolicLink')) {
                        if ($isDir) { [System.IO.Directory]::Delete($e, $false) }
                        else { [System.IO.File]::Delete($e) }
                        continue
                    }
                    if ($isDir) { continue }
                }
                $isD = (($a -band [System.IO.FileAttributes]::Directory) -ne 0)
                $os = & $ownerState (& $getOwner $e $isD)
                if ($os -eq 'unknown' -and $pass -eq 1) { $warn.Add("Besitzer von $e nicht sicher feststellbar - uebernommen statt verschoben") }
                if ($os -eq 'foreign') {
                    $rel = $e.Substring($root.Length).TrimStart('\')
                    $dst = Join-Path $aside $rel
                    $dp = Split-Path $dst -Parent
                    if (-not [System.IO.Directory]::Exists($dp)) { [void][System.IO.Directory]::CreateDirectory($dp) }
                    if ($isD) { [System.IO.Directory]::Move($e, $dst) } else { [System.IO.File]::Move($e, $dst) }
                    $moved++
                    continue
                }
                if ($pass -eq 1) {
                    & $takeOver $e
                    $o = & icacls.exe "$e" /reset /C /Q 2>&1
                    if ($LASTEXITCODE -ne 0) { throw "Rechte von $e nicht zuruecksetzbar: $o" }
                }
                if (($a -band [System.IO.FileAttributes]::Directory) -ne 0) { $stack.Push($e) }
            }
        }
    }
    if (-not (& $isSafe)) { throw "$root konnte nicht abgesichert werden" }
    return "$root abgesichert (nur Administratoren/SYSTEM duerfen schreiben)$(if ($moved) { " - fremder Inhalt verschoben nach $aside" })$(& $warnText)"
}

# Profil-Sicherung pruefen (Werkzeug "Profil zurueckholen"). Rueckgabe: '' = in Ordnung, sonst Grund.
# Akzeptiert nur, was "Profil erneuern" selbst anlegt: SID eines Kontos, Profilordner direkt im Profilverzeichnis,
# gesicherter Ordner <Profilordner>.alt_<Zeit>, .reg aus dem Sicherungsordner, die NUR den ProfileList-Eintrag dieser SID
# enthaelt und deren ProfileImagePath auf den Profilordner zeigt.
function Test-HMProfileBackup {
    param($Backup, [string]$File, [string]$BackupDir, [string]$ProfilesDir)
    $sid = "$($Backup.Sid)"
    if ($sid -notmatch '^S-1-(5-21|12-1)-\d+-\d+-\d+-\d+$') { return 'SID ungueltig' }
    if ((Split-Path $File -Leaf) -notmatch ('^Profil_' + [regex]::Escape($sid) + '_\d{8}_\d{6}\.json$')) { return 'Dateiname passt nicht zur SID' }
    $path = "$($Backup.Path)".TrimEnd('\')
    $pd = "$ProfilesDir".TrimEnd('\')
    if (-not $path -or -not $pd -or (Split-Path $path -Parent) -ne $pd) { return "Profilordner liegt nicht direkt unter $pd" }
    if ("$($Backup.AltPath)" -notmatch ('^' + [regex]::Escape($path) + '\.alt_\d{8}_\d{6}$')) { return 'gesicherter Ordner passt nicht zum Profilordner' }
    $reg = "$($Backup.Reg)"
    if ((Split-Path $reg -Parent).TrimEnd('\') -ne "$BackupDir".TrimEnd('\') -or (Split-Path $reg -Leaf) -notmatch ('^ProfileList_' + [regex]::Escape($sid) + '_\d{8}_\d{6}\.reg$')) { return '.reg-Datei stammt nicht aus der Profil-Sicherung' }
    if (-not (Test-Path -LiteralPath $reg)) { return ".reg-Datei fehlt: $reg" }
    $key = "[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid]"
    # Zeilen lesen, Fortsetzungszeilen (Zeilenende \) zusammenfuegen
    $lines = New-Object System.Collections.Generic.List[string]
    $cur = ''
    foreach ($ln in @(Get-Content -LiteralPath $reg -ErrorAction Stop)) {
        $t = "$ln".Trim()
        if ($t.EndsWith('\')) { $cur += $t.Substring(0, $t.Length - 1); continue }
        $lines.Add($cur + $t); $cur = ''
    }
    if ($cur) { $lines.Add($cur) }
    $img = $null
    foreach ($l in $lines) {
        if ($l.StartsWith('[')) { if ($l -ine $key) { return '.reg enthaelt andere Registry-Schluessel' }; continue }
        if ($l -match '^"ProfileImagePath"=hex\(2\):([0-9a-fA-F,]*)$') {
            $bytes = [byte[]]@($Matches[1].Split(',') | Where-Object { $_ } | ForEach-Object { [Convert]::ToByte($_, 16) })
            $img = [System.Text.Encoding]::Unicode.GetString($bytes).TrimEnd([char]0)
        } elseif ($l -match '^"ProfileImagePath"="(.*)"$') { $img = $Matches[1] -replace '\\\\', '\' }
    }
    if (-not $img) { return '.reg ohne ProfileImagePath' }
    if ([Environment]::ExpandEnvironmentVariables($img).TrimEnd('\') -ine $path) { return ".reg zeigt auf einen anderen Ordner ($img)" }
    return ''
}
