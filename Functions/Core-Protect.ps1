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
    # 1. Wurzel: ist sie eine Verknuepfung, nur den Link entfernen; sonst anlegen
    if ([System.IO.Directory]::Exists($root) -and (([System.IO.File]::GetAttributes($root) -band $rp) -ne 0)) { [System.IO.Directory]::Delete($root, $false) }
    if (-not [System.IO.Directory]::Exists($root)) { [void][System.IO.Directory]::CreateDirectory($root) }
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
    if (& $isSafe) { return }
    # Besitz uebernehmen: icacls setzt den Besitzer auch ohne Zugriffsrecht (Wiederherstellungsrecht der Administratoren)
    $takeOver = {
        param([string]$Path)
        $o = & icacls.exe "$Path" /setowner '*S-1-5-32-544' /C /Q 2>&1
        if ($LASTEXITCODE -ne 0) { $o2 = & takeown.exe /F "$Path" /A 2>&1; if ($LASTEXITCODE -ne 0) { throw "Besitz von $Path nicht uebernehmbar: $o $o2" } }
    }
    # 3. Wurzel absichern: Besitzer Administratoren, Vererbung aus, SYSTEM + Administratoren Vollzugriff, Benutzer Lesen
    & $takeOver $root
    $sec = New-Object System.Security.AccessControl.DirectorySecurity
    $sec.SetOwner($admSid)
    $sec.SetAccessRuleProtection($true, $false)
    foreach ($x in @(@('S-1-5-18', 'FullControl'), @('S-1-5-32-544', 'FullControl'), @('S-1-5-32-545', 'ReadAndExecute'))) {
        $sec.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule((New-Object System.Security.Principal.SecurityIdentifier($x[0])), [System.Security.AccessControl.FileSystemRights]$x[1], 'ContainerInherit, ObjectInherit', 'None', 'Allow')))
    }
    [System.IO.Directory]::SetAccessControl($root, $sec)
    # 4. Inhalt: Verknuepfungen entfernen (nur den Link), alles andere: Besitzer Administratoren, nur geerbte Rechte.
    #    Eigener Durchlauf statt icacls /T: folgt keinen Verknuepfungen. Zweimal, falls waehrenddessen etwas angelegt wurde.
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
    return "$root abgesichert (nur Administratoren/SYSTEM duerfen schreiben)"
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
