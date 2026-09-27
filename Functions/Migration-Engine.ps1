#Requires -Version 5.1
<#
.SYNOPSIS
    Migrations-Engine: Backup und Restore von Benutzerprofilen, lokal oder remote.
.DESCRIPTION
    Laeuft im Hintergrund-Runspace (Start-LongJob) - kein WPF-Code hier.
    Kommunikation mit der Oberflaeche ueber $Job (synchronisierte Hashtable, siehe Core-Async.ps1).

    Grundprinzip Backup:
      - Dateien      -> Robocopy (multithreaded) mit Ausnahmelisten
      - Einstellungen -> reg export aus HKU\<SID> (Hive wird geladen, wenn der Benutzer nicht angemeldet ist)
      - Windows-Einstellungen optional ueber USMT (ScanState/LoadState)
    Remote: Dateien ueber \\<PC>\<LW>$, Registry/Befehle ueber PowerShell-Remoting (WinRM).
    Jedes Backup bekommt eine manifest.json (Quelle, Benutzer, SID, Module, Ergebnis).
    Backups der Vorgaengerversion (ohne manifest.json) werden beim Restore erkannt (Legacy-Pfade im Modul-Katalog).
#>

# ============================================================================
# LOG / FORTSCHRITT
# ============================================================================
function Write-HMLog {
    param($Job, [string]$Msg, [ValidateSet('Info','Warning','Error','Success','Debug','Header','Separator')][string]$Lvl = 'Info')
    if ($Job -and $Job.Log) { $Job.Log.Enqueue(@{ Msg = $Msg; Lvl = $Lvl }) } else { Write-Host "[$Lvl] $Msg" }
    if ($Job -and $Job.LogFile) {
        try { Add-Content -LiteralPath $Job.LogFile -Value ('{0} [{1}] {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Lvl.ToUpper(), $Msg) -Encoding UTF8 } catch { }
    }
}

function Test-HMCancel($Job) { return ($Job -and $Job.Cancel) }

# Benutzer-Modus (ohne Administratorrechte): nur Module des eigenen Profils (+ Zusaetzliche Ordner)
function Test-HMModuleUserOk($Module) {
    if ($Module.Id -eq 'ExtraFolders') { return $true }
    return ($Module.Scope -eq 'User' -and $Module.Id -ne 'Usmt')
}
# ============================================================================
# DESKTOP-SYMBOLPOSITIONEN direkt vom laufenden Desktop (Shell IFolderView) - wie ReIcon in der Vorgaengerversion.
# Laeuft immer in der Sitzung des Benutzers (eigener Prozess / geplante Aufgabe als Benutzer), nie erhoeht.
# ============================================================================
$script:HMDesktopIconsCs = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace HMDesk
{
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
    [StructLayout(LayoutKind.Explicit, Size = 272)] public struct STRRET { [FieldOffset(0)] public uint uType; }

    [ComImport, Guid("85CB6900-4D95-11CF-960C-0080C7F4EE85"), InterfaceType(ComInterfaceType.InterfaceIsDual)]
    interface IShellWindows
    {
        int Count { get; }
        [return: MarshalAs(UnmanagedType.IDispatch)] object Item(object index);
        [return: MarshalAs(UnmanagedType.IUnknown)] object _NewEnum();
        void Register();          // Platzhalter (vtable)
        void RegisterPending();   // Platzhalter
        void Revoke();            // Platzhalter
        void OnNavigate();        // Platzhalter
        void OnActivated();       // Platzhalter
        [return: MarshalAs(UnmanagedType.IDispatch)]
        object FindWindowSW(ref object pvarLoc, ref object pvarLocRoot, int swClass, out int phwnd, int swfwOptions);
    }

    [ComImport, Guid("6D5140C1-7436-11CE-8034-00AA006009FA"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IHMServiceProvider
    {
        [PreserveSig] int QueryService(ref Guid guidService, ref Guid riid, [MarshalAs(UnmanagedType.IUnknown)] out object ppv);
    }

    [ComImport, Guid("000214E2-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IShellBrowser
    {
        void GetWindow(); void ContextSensitiveHelp();                                   // IOleWindow
        void InsertMenusSB(); void SetMenuSB(); void RemoveMenusSB(); void SetStatusTextSB();
        void EnableModelessSB(); void TranslateAcceleratorSB(); void BrowseObject();
        void GetViewStateStream(); void GetControlWindow(); void SendControlMsg();
        [PreserveSig] int QueryActiveShellView([MarshalAs(UnmanagedType.IUnknown)] out object ppshv);
    }

    [ComImport, Guid("CDE725B0-CCC9-4519-917E-325D72FAB4CE"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IFolderView
    {
        [PreserveSig] int GetCurrentViewMode(out uint pViewMode);
        [PreserveSig] int SetCurrentViewMode(uint ViewMode);
        [PreserveSig] int GetFolder(ref Guid riid, [MarshalAs(UnmanagedType.IUnknown)] out object ppv);
        [PreserveSig] int Item(int iItemIndex, out IntPtr ppidl);
        [PreserveSig] int ItemCount(uint uFlags, out int pcItems);
        [PreserveSig] int Items(uint uFlags, ref Guid riid, out IntPtr ppv);
        [PreserveSig] int GetSelectionMarkedItem(out int piItem);
        [PreserveSig] int GetFocusedItem(out int piItem);
        [PreserveSig] int GetItemPosition(IntPtr pidl, out POINT ppt);
        [PreserveSig] int GetSpacing(out POINT ppt);
        [PreserveSig] int GetDefaultSpacing(out POINT ppt);
        [PreserveSig] int GetAutoArrange();
        [PreserveSig] int SelectItem(int iItem, uint dwFlags);
        [PreserveSig] int SelectAndPositionItems(uint cidl, [MarshalAs(UnmanagedType.LPArray)] IntPtr[] apidl, [MarshalAs(UnmanagedType.LPArray)] POINT[] apt, uint dwFlags);
    }

    [ComImport, Guid("000214E6-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IShellFolder
    {
        void ParseDisplayName(); void EnumObjects(); void BindToObject(); void BindToStorage();
        void CompareIDs(); void CreateViewObject(); void GetAttributesOf(); void GetUIObjectOf();
        [PreserveSig] int GetDisplayNameOf(IntPtr pidl, uint uFlags, out STRRET pName);
    }

    public static class Icons
    {
        [DllImport("shlwapi.dll", CharSet = CharSet.Unicode)]
        static extern int StrRetToBSTR(ref STRRET pstr, IntPtr pidl, [MarshalAs(UnmanagedType.BStr)] out string pbstr);

        static IFolderView GetDesktopView()
        {
            Type t = Type.GetTypeFromCLSID(new Guid("9BA05972-F6A8-11CF-A442-00A0C90A8F39")); // ShellWindows
            IShellWindows sw = (IShellWindows)Activator.CreateInstance(t);
            object loc = 0;               // CSIDL_DESKTOP
            object root = null;
            int hwnd;
            object disp = sw.FindWindowSW(ref loc, ref root, 8 /* SWC_DESKTOP */, out hwnd, 1 /* SWFO_NEEDDISPATCH */);
            if (disp == null) throw new Exception("Desktop-Fenster nicht gefunden");
            Guid sid = new Guid("4C96BE40-915C-11CF-99D3-00AA004AE837");   // SID_STopLevelBrowser
            Guid iid = new Guid("000214E2-0000-0000-C000-000000000046");   // IID_IShellBrowser
            object sb;
            int hr = ((IHMServiceProvider)disp).QueryService(ref sid, ref iid, out sb);
            if (hr != 0) throw new Exception("QueryService 0x" + hr.ToString("X8"));
            object view;
            hr = ((IShellBrowser)sb).QueryActiveShellView(out view);
            if (hr != 0) throw new Exception("QueryActiveShellView 0x" + hr.ToString("X8"));
            return (IFolderView)view;
        }

        static string NameOf(IShellFolder sf, IntPtr pidl, uint flags)
        {
            STRRET r;
            if (sf.GetDisplayNameOf(pidl, flags, out r) != 0) return null;
            string s;
            return StrRetToBSTR(ref r, pidl, out s) == 0 ? s : null;
        }

        public static bool AutoArrange() { return GetDesktopView().GetAutoArrange() == 0; }

        // Zeilen: Name <TAB> X <TAB> Y
        public static string[] Get()
        {
            IFolderView fv = GetDesktopView();
            Guid iidSf = new Guid("000214E6-0000-0000-C000-000000000046");
            object o; fv.GetFolder(ref iidSf, out o);
            IShellFolder sf = (IShellFolder)o;
            int n; fv.ItemCount(2 /* SVGIO_ALLVIEW */, out n);
            List<string> list = new List<string>();
            for (int i = 0; i < n; i++)
            {
                IntPtr pidl;
                if (fv.Item(i, out pidl) != 0) continue;
                try
                {
                    POINT p; fv.GetItemPosition(pidl, out p);
                    string name = NameOf(sf, pidl, 0x8001 /* SHGDN_INFOLDER | SHGDN_FORPARSING */);
                    if (!string.IsNullOrEmpty(name)) list.Add(name + "\t" + p.X + "\t" + p.Y);
                }
                finally { Marshal.FreeCoTaskMem(pidl); }
            }
            return list.ToArray();
        }

        // Rueckgabe: Anzahl gesetzter Symbole
        public static int Set(string[] lines)
        {
            Dictionary<string, POINT> want = new Dictionary<string, POINT>(StringComparer.OrdinalIgnoreCase);
            foreach (string l in lines)
            {
                string[] f = l.Split('\t');
                if (f.Length < 3) continue;
                int x, y;
                if (int.TryParse(f[1], out x) && int.TryParse(f[2], out y)) { POINT p; p.X = x; p.Y = y; want[f[0]] = p; }
            }
            IFolderView fv = GetDesktopView();
            Guid iidSf = new Guid("000214E6-0000-0000-C000-000000000046");
            object o; fv.GetFolder(ref iidSf, out o);
            IShellFolder sf = (IShellFolder)o;
            int n; fv.ItemCount(2, out n);
            int done = 0;
            for (int i = 0; i < n; i++)
            {
                IntPtr pidl;
                if (fv.Item(i, out pidl) != 0) continue;
                try
                {
                    string name = NameOf(sf, pidl, 0x8001);
                    string disp = NameOf(sf, pidl, 0x1);   // SHGDN_INFOLDER (Anzeigename, z.B. ohne .lnk)
                    POINT p;
                    if ((name != null && want.TryGetValue(name, out p)) || (disp != null && want.TryGetValue(disp, out p)))
                    {
                        if (fv.SelectAndPositionItems(1, new IntPtr[] { pidl }, new POINT[] { p }, 0x80 /* SVSI_POSITIONITEM */) == 0) done++;
                    }
                }
                finally { Marshal.FreeCoTaskMem(pidl); }
            }
            return done;
        }
    }
}
'@

# PowerShell-Code fuer die Benutzersitzung: Save = Positionen in $DataFile schreiben, Load = aus Zeilen setzen (mit Wartezeit nach Explorer-Start)
function Get-HMDesktopIconsCode([string]$Mode, [string]$DataFile, [string]$ResultFile, [string[]]$Lines = @()) {
    $q = { param($s) "'" + ("$s" -replace "'", "''") + "'" }
    $c = "`$ErrorActionPreference = 'Stop'`r`ntry {`r`nAdd-Type -TypeDefinition @'`r`n$script:HMDesktopIconsCs`r`n'@`r`n"
    if ($Mode -eq 'Save') {
        $c += "`$l = [HMDesk.Icons]::Get(); Set-Content -LiteralPath $(& $q $DataFile) -Value `$l -Encoding UTF8`r`n"
        $c += "`$aa = if ([HMDesk.Icons]::AutoArrange()) { ' AUTO' } else { '' }`r`n"
        $c += "Set-Content -LiteralPath $(& $q $ResultFile) -Value (""OK `$(@(`$l).Count)`$aa"") -Encoding UTF8`r`n"
    } else {
        $data = ($Lines | ForEach-Object { "$_" -replace "'", "''" } | ForEach-Object { "'$_'" }) -join ",`r`n"
        $c += "`$lines = @(`r`n$data`r`n)`r`n"
        $c += "`$n = 0; for (`$i = 0; `$i -lt 25; `$i++) { try { `$n = [HMDesk.Icons]::Set(`$lines) } catch { `$n = 0 }; if (`$n -gt 0) { Start-Sleep -Seconds 3; try { `$n = [HMDesk.Icons]::Set(`$lines) } catch { }; break }; Start-Sleep -Seconds 2 }`r`n"
        if ($ResultFile) { $c += "Set-Content -LiteralPath $(& $q $ResultFile) -Value (""OK `$n"") -Encoding UTF8`r`n" }
    }
    $c += "} catch {`r`n"
    if ($ResultFile) { $c += "Set-Content -LiteralPath $(& $q $ResultFile) -Value (""FEHLER `$(`$_.Exception.Message)"") -Encoding UTF8`r`n" }
    $c += "}`r`n"
    return $c
}

# Symbolpositionen des angemeldeten Zielbenutzers lesen. Rueckgabe: @{ Status = OK|SKIP|FEHLER; Lines; Msg }
function Read-HMDesktopIconPositions([hashtable]$Ctx) {
    if ($Ctx.UserMode) {
        # eigener, nicht erhoehter Prozess in der eigenen Sitzung
        $d = Join-Path $env:TEMP ('HMicons_' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $d -Force | Out-Null
        try {
            $df = Join-Path $d 'pos.tsv'; $rf = Join-Path $d 'result.txt'; $sf = Join-Path $d 'icons.ps1'
            Set-Content -LiteralPath $sf -Value (Get-HMDesktopIconsCode 'Save' $df $rf) -Encoding UTF8
            Start-Process -FilePath powershell.exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$sf`"") -WindowStyle Hidden -Wait
            $r = if (Test-Path -LiteralPath $rf) { "$(Get-Content -LiteralPath $rf -Raw)".Trim() } else { 'FEHLER kein Ergebnis' }
            $lines = if (Test-Path -LiteralPath $df) { @(Get-Content -LiteralPath $df -Encoding UTF8) } else { @() }
            return @{ Status = $(if ($r -like 'OK*') { 'OK' } else { 'FEHLER' }); Lines = $lines; Msg = $r }
        } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
    if (-not $Ctx.Account) { return @{ Status = 'SKIP'; Lines = @(); Msg = 'Kontoname unbekannt' } }
    $code = { param($acct, $saveCode)
        $logged = @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue | ForEach-Object { try { $o = Invoke-CimMethod -InputObject $_ -MethodName GetOwner; "$($o.Domain)\$($o.User)" } catch { } })
        if ($logged -notcontains $acct) { return @{ Status = 'SKIP'; Lines = @(); Msg = 'Benutzer nicht angemeldet' } }
        $id = [guid]::NewGuid().ToString('N')
        $d = Join-Path $env:ProgramData "HUMig\Icons_$id"
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        $n = "HUMig_Icons_$id"
        try {
            & icacls.exe $d /grant "${acct}:(OI)(CI)M" | Out-Null
            $df = Join-Path $d 'pos.tsv'; $rf = Join-Path $d 'result.txt'; $sf = Join-Path $d 'icons.ps1'
            Set-Content -LiteralPath $sf -Value ($saveCode.Replace('%DATA%', $df).Replace('%RESULT%', $rf)) -Encoding UTF8
            $a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$sf`""
            $p = New-ScheduledTaskPrincipal -UserId $acct -LogonType Interactive -RunLevel Limited
            $s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
            Register-ScheduledTask -TaskName $n -Action $a -Principal $p -Settings $s -Force -ErrorAction Stop | Out-Null
            Start-ScheduledTask -TaskName $n
            $t0 = Get-Date
            while (-not (Test-Path -LiteralPath $rf) -and ((Get-Date) - $t0).TotalSeconds -lt 60) { Start-Sleep -Milliseconds 500 }
            Start-Sleep -Milliseconds 300
            $r = if (Test-Path -LiteralPath $rf) { "$(Get-Content -LiteralPath $rf -Raw)".Trim() } else { 'FEHLER keine Antwort aus der Benutzersitzung (Zeitueberschreitung)' }
            $lines = if (Test-Path -LiteralPath $df) { @(Get-Content -LiteralPath $df -Encoding UTF8) } else { @() }
            return @{ Status = $(if ($r -like 'OK*') { 'OK' } else { 'FEHLER' }); Lines = $lines; Msg = $r }
        } finally {
            Unregister-ScheduledTask -TaskName $n -Confirm:$false -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    return (Invoke-HMTarget $Ctx $code @($Ctx.Account, (Get-HMDesktopIconsCode 'Save' '%DATA%' '%RESULT%')))
}

# Positionen aus einem Backup lesen: positions.tsv (HUMig v2) oder IconLayouts.ini (Vorgaengerversion, ReIcon)
function Get-HMDesktopIconLines([string]$Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return @() }
    if ((Get-Item -LiteralPath $Path).PSIsContainer) {
        $f = Join-Path $Path 'positions.tsv'
        if (Test-Path -LiteralPath $f) { return @(Get-Content -LiteralPath $f -Encoding UTF8 | Where-Object { $_ -match "`t" }) }
        return @()
    }
    # ReIcon-INI: erste Sektion [Icon_Layout_*], Zeilen Name=X,Y
    $out = @(); $in = $false
    foreach ($l in @(Get-Content -LiteralPath $Path)) {
        if ($l -match '^\[Icon_Layout_') { if ($out.Count) { break }; $in = $true; continue }
        if ($l -match '^\[') { if ($in -and $out.Count) { break }; $in = $false; continue }
        if ($in -and $l -match '^([^:;][^=]*)=(-?\d+),(-?\d+)\s*$') { $out += ("{0}`t{1}`t{2}" -f $Matches[1], $Matches[2], $Matches[3]) }
    }
    return $out
}

# Dateisystem-Hilfen mit langen Pfaden (\\?\ - Backups koennen Pfade > 260 Zeichen enthalten, Robocopy legt sie an)
$script:HMFsCs = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace HMFs
{
    public static class Tree
    {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct WIN32_FIND_DATA
        {
            public uint dwFileAttributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME c, a, w;
            public uint nFileSizeHigh, nFileSizeLow, r0, r1;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string cFileName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 14)] public string cAlternateFileName;
        }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr FindFirstFileW(string n, out WIN32_FIND_DATA fd);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool FindNextFileW(IntPtr h, out WIN32_FIND_DATA fd);
        [DllImport("kernel32.dll")] static extern bool FindClose(IntPtr h);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr CreateFileW(string n, uint acc, uint share, IntPtr sa, uint disp, uint flags, IntPtr tmpl);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool SetFileAttributesW(string n, uint a);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool DeleteFileW(string n);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool RemoveDirectoryW(string n);

        static readonly IntPtr INVALID = new IntPtr(-1);
        static string L(string p)
        {
            if (p.StartsWith(@"\\?\")) return p;
            if (p.StartsWith(@"\\")) return @"\\?\UNC\" + p.Substring(2);
            return @"\\?\" + p;
        }
        static string Err(int c)
        {
            if (c == 5) return "Zugriff verweigert";
            if (c == 32) return "Datei geoeffnet";
            return "Fehler " + c;
        }

        // Prueft jede Datei/jeden Ordner auf Loeschrecht (DELETE + Attribute schreiben). Rueckgabe: Problemfaelle (max. 'max')
        public static string[] CheckDeletable(string root, int max)
        {
            root = root.TrimEnd('\\');
            List<string> bad = new List<string>();
            Walk(root, root.Length, bad, max, false);
            return bad.ToArray();
        }
        // Loescht den Ordner komplett (auch schreibgeschuetzte Dateien, lange Pfade). Rueckgabe: Problemfaelle
        public static string[] Delete(string root, int max)
        {
            root = root.TrimEnd('\\');
            List<string> bad = new List<string>();
            Walk(root, root.Length, bad, max, true);
            if (bad.Count == 0 && !RemoveDirectoryW(L(root))) bad.Add("(Backup-Ordner) " + Err(Marshal.GetLastWin32Error()));
            return bad.ToArray();
        }

        static void Walk(string dir, int rootLen, List<string> bad, int max, bool delete)
        {
            WIN32_FIND_DATA fd;
            IntPtr h = FindFirstFileW(L(dir) + @"\*", out fd);
            if (h == INVALID) { bad.Add(Rel(dir, rootLen) + @"\ (nicht lesbar: " + Err(Marshal.GetLastWin32Error()) + ")"); return; }
            try
            {
                do
                {
                    if (bad.Count >= max) return;
                    string n = fd.cFileName;
                    if (n == "." || n == "..") continue;
                    string full = dir + "\\" + n;
                    bool isDir = (fd.dwFileAttributes & 0x10) != 0;
                    bool reparse = (fd.dwFileAttributes & 0x400) != 0;
                    if (isDir && !reparse)
                    {
                        Walk(full, rootLen, bad, max, delete);
                        if (delete && bad.Count == 0)
                        {
                            SetFileAttributesW(L(full), 0x10);
                            if (!RemoveDirectoryW(L(full))) bad.Add(Rel(full, rootLen) + @"\ (" + Err(Marshal.GetLastWin32Error()) + ")");
                        }
                    }
                    else if (delete)
                    {
                        if (isDir) { if (!RemoveDirectoryW(L(full))) bad.Add(Rel(full, rootLen) + " (" + Err(Marshal.GetLastWin32Error()) + ")"); continue; }   // Verknuepfung (Junction) - nur den Link
                        if ((fd.dwFileAttributes & 0x7) != 0) SetFileAttributesW(L(full), 0x80);   // schreibgeschuetzt/versteckt/System aufheben
                        if (!DeleteFileW(L(full))) bad.Add(Rel(full, rootLen) + " (" + Err(Marshal.GetLastWin32Error()) + ")");
                    }
                    else
                    {
                        // DELETE (0x10000) + FILE_WRITE_ATTRIBUTES (0x100), alle Freigaben; Ordner-Links mit BACKUP_SEMANTICS
                        IntPtr fh = CreateFileW(L(full), 0x10100, 7, IntPtr.Zero, 3, isDir ? 0x02200000u : 0x00200000u, IntPtr.Zero);
                        if (fh == INVALID) bad.Add(Rel(full, rootLen) + " (" + Err(Marshal.GetLastWin32Error()) + ")");
                        else CloseHandle(fh);
                    }
                } while (FindNextFileW(h, out fd));
            }
            finally { FindClose(h); }
        }
        static string Rel(string p, int rootLen) { return p.Length > rootLen ? p.Substring(rootLen).TrimStart('\\') : p; }
    }
}
'@
function Initialize-HMFs { if (-not ('HMFs.Tree' -as [type])) { Add-Type -TypeDefinition $script:HMFsCs -ErrorAction Stop } }

# Backup-Ordner loeschen - nur ganz oder gar nicht: vorher fuer JEDE Datei pruefen, ob sie geloescht werden darf
# (Loeschrecht, nicht geoeffnet). Sonst bleibt ein halb geloeschtes, unbrauchbares Backup zurueck. Lange Pfade und schreibgeschuetzte Dateien werden unterstuetzt.
function Remove-HMBackupFolder([string]$Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return 'OK' }
    try { Initialize-HMFs } catch { return "FEHLER: nichts geloescht - Pruefung nicht moeglich: $($_.Exception.Message)" }
    $bad = @([HMFs.Tree]::CheckDeletable($Path, 5))
    if ($bad.Count) {
        return ("FEHLER: nichts geloescht - {0}{1}. Rechte des Backup-Ordners pruefen bzw. geoeffnete Dateien schliessen." -f ($bad -join '; '), $(if ($bad.Count -ge 5) { ' ...' } else { '' }))
    }
    $bad = @([HMFs.Tree]::Delete($Path, 5))
    if ($bad.Count) { return ("FEHLER: Loeschen unvollstaendig - {0}. Backup-Rest bitte noch einmal loeschen." -f ($bad -join '; ')) }
    return 'OK'
}

# Eintrag schreibt beim Restore ausserhalb des Profils (Programme, Windows, HKLM) -> braucht Administratorrechte
function Test-HMItemNeedsAdmin($Item) {
    switch ("$($Item.Type)") {
        'Reg' { return ("$($Item.Key)" -match '^HK(LM|EY_LOCAL_MACHINE)') }
        { $_ -in @('Folder', 'Files') } { return ("$($Item.Path)" -match '^\{(PROGRAMFILES\w*|PROGRAMDATA|WINDIR|SYSTEMDRIVE|PUBLIC)\}' -or "$($Item.Path)" -match '^[A-Za-z]:\\(Windows|Program Files|ProgramData)') }
        default { return $false }
    }
}

function Format-HMSize([double]$Bytes) {
    if ($Bytes -ge 1TB) { return ('{0:N2} TB' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ('{0:N0} B' -f $Bytes)
}

function ConvertTo-HMSafeName([string]$Text) { return (($Text -replace '[\\/:*?"<>|\s]+', '_').Trim('_')) }

# ============================================================================
# ZIEL-PC: REMOTE-AUSFUEHRUNG, PFADE, FREIGABEN
# ============================================================================
function Test-HMIsLocal([string]$Computer) {
    if ([string]::IsNullOrWhiteSpace($Computer)) { return $true }
    $c = $Computer.Trim().ToUpper()
    if ($c -in @('.', 'LOCALHOST', '127.0.0.1', $env:COMPUTERNAME.ToUpper())) { return $true }
    if ($c -like "$($env:COMPUTERNAME.ToUpper()).*") { return $true }
    return $false
}

# Scriptblock am Ziel-PC ausfuehren (lokal direkt, remote per Invoke-Command)
function Invoke-HMTarget {
    param([hashtable]$Ctx, [scriptblock]$Script, [object[]]$ArgumentList = @())
    if (-not $Ctx.IsRemote) { return (& $Script @ArgumentList) }
    $p = @{ ComputerName = $Ctx.Computer; ScriptBlock = $Script; ArgumentList = $ArgumentList; ErrorAction = 'Stop' }
    if ($Ctx.Credential) { $p.Credential = $Ctx.Credential }
    return (Invoke-Command @p)
}

# Lokalen Pfad des Ziel-PCs (C:\...) in einen erreichbaren Pfad umwandeln (remote: \\PC\C$\...)
function Convert-HMPath {
    param([hashtable]$Ctx, [string]$Path)
    if (-not $Ctx.IsRemote -or [string]::IsNullOrWhiteSpace($Path) -or $Path.StartsWith('\\')) { return $Path }
    if ($Path -match '^([A-Za-z]):\\?(.*)$') { return ('\\{0}\{1}$\{2}' -f $Ctx.Computer, $Matches[1].ToUpper(), $Matches[2]).TrimEnd('\') }
    return $Path
}

# SMB-Verbindung mit anderen Anmeldedaten (ohne Kennwort in einer Befehlszeile)
function Connect-HMShare {
    param([string]$UncRoot, [System.Management.Automation.PSCredential]$Credential)
    if (-not $Credential) { return $true }
    if (-not ('HMNet.Mpr' -as [type])) {
        Add-Type -Namespace HMNet -Name Mpr -MemberDefinition @'
[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public class NETRESOURCE { public int dwScope; public int dwType = 1; public int dwDisplayType; public int dwUsage;
  public string lpLocalName; public string lpRemoteName; public string lpComment; public string lpProvider; }
[DllImport("mpr.dll", CharSet = CharSet.Unicode)]
public static extern int WNetAddConnection2(NETRESOURCE nr, string password, string user, int flags);
[DllImport("mpr.dll", CharSet = CharSet.Unicode)]
public static extern int WNetCancelConnection2(string name, int flags, bool force);
'@
    }
    $nr = New-Object HMNet.Mpr+NETRESOURCE
    $nr.lpRemoteName = $UncRoot
    $rc = [HMNet.Mpr]::WNetAddConnection2($nr, $Credential.GetNetworkCredential().Password, $Credential.UserName, 0)
    # 0 = OK, 1219 = bereits mit anderen Daten verbunden (dann vorhandene Verbindung nutzen)
    return ($rc -eq 0 -or $rc -eq 1219)
}

function Disconnect-HMShare([string]$UncRoot) {
    if ('HMNet.Mpr' -as [type]) { try { [void][HMNet.Mpr]::WNetCancelConnection2($UncRoot, 0, $true) } catch { } }
}

# ============================================================================
# BENUTZERPROFILE / SID / HIVE
# ============================================================================
# Liefert die Profile des Ziel-PCs (auch fuer die Oberflaeche verwendet)
function Get-HMUserProfiles {
    param([string]$Computer, [System.Management.Automation.PSCredential]$Credential)
    $isLocal = Test-HMIsLocal $Computer
    # Nur echte Benutzerkonten (lokal/Domaene S-1-5-21, Entra ID S-1-12-1) - keine Dienstkonten (NT SERVICE, IIS ...).
    # Interactive = hat eine Desktop-Sitzung (explorer.exe), Loaded = nur Registry geladen (auch Dienste/getrennte Sitzungen)
    $sb = {
        $inter = @{}
        foreach ($pr in @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue)) {
            try { $o = Invoke-CimMethod -InputObject $pr -MethodName GetOwnerSid -ErrorAction Stop; if ($o.Sid) { $inter["$($o.Sid)"] = $true } } catch { }
        }
        $list = foreach ($p in @(Get-CimInstance Win32_UserProfile -ErrorAction Stop | Where-Object { -not $_.Special -and $_.LocalPath -and "$($_.SID)" -match '^S-1-(5-21|12-1)-' })) {
            $name = $null
            try { $name = (New-Object System.Security.Principal.SecurityIdentifier($p.SID)).Translate([System.Security.Principal.NTAccount]).Value } catch { }
            [pscustomobject]@{
                SID = $p.SID; LocalPath = $p.LocalPath; Folder = (Split-Path $p.LocalPath -Leaf)
                Account = $name; Loaded = [bool]$p.Loaded; Interactive = [bool]$inter["$($p.SID)"]
                LastUse = $(if ($p.LastUseTime) { $p.LastUseTime.ToString('yyyy-MM-dd HH:mm') } else { '' })
            }
        }
        $list | Sort-Object Folder
    }
    if ($isLocal) { return (& $sb) }
    # Remote: erst WinRM, sonst DCOM (funktioniert auch ohne WinRM)
    try {
        $p = @{ ComputerName = $Computer; ScriptBlock = $sb; ErrorAction = 'Stop' }
        if ($Credential) { $p.Credential = $Credential }
        return (Invoke-Command @p | Select-Object SID, LocalPath, Folder, Account, Loaded, Interactive, LastUse)
    } catch {
        $o = New-CimSessionOption -Protocol Dcom
        $sp = @{ ComputerName = $Computer; SessionOption = $o; ErrorAction = 'Stop' }
        if ($Credential) { $sp.Credential = $Credential }
        $cs = New-CimSession @sp
        try {
            $inter = @{}
            foreach ($pr in @(Get-CimInstance -CimSession $cs Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue)) {
                try { $o = Invoke-CimMethod -InputObject $pr -MethodName GetOwnerSid -ErrorAction Stop; if ($o.Sid) { $inter["$($o.Sid)"] = $true } } catch { }
            }
            foreach ($p in @(Get-CimInstance -CimSession $cs Win32_UserProfile -ErrorAction Stop | Where-Object { -not $_.Special -and $_.LocalPath -and "$($_.SID)" -match '^S-1-(5-21|12-1)-' } | Sort-Object LocalPath)) {
                $name = $null
                try { $name = (New-Object System.Security.Principal.SecurityIdentifier($p.SID)).Translate([System.Security.Principal.NTAccount]).Value } catch { }
                [pscustomobject]@{ SID = $p.SID; LocalPath = $p.LocalPath; Folder = (Split-Path $p.LocalPath -Leaf); Account = $name; Loaded = [bool]$p.Loaded; Interactive = [bool]$inter["$($p.SID)"]
                    LastUse = $(if ($p.LastUseTime) { $p.LastUseTime.ToString('yyyy-MM-dd HH:mm') } else { '' }) }
            }
        } finally { Remove-CimSession $cs -ErrorAction SilentlyContinue }
    }
}

function Test-HMHiveLoaded([hashtable]$Ctx, [string]$Sid) {
    return [bool](Invoke-HMTarget $Ctx { param($s) Test-Path -LiteralPath "Registry::HKEY_USERS\$s" } @($Sid))
}

# Hive des Benutzers unter HKU\<SID> verfuegbar machen (laden, wenn nicht angemeldet)
function Mount-HMHive {
    param([hashtable]$Ctx, $Job, [string]$Sid, [string]$ProfilePath)
    if (Test-HMHiveLoaded $Ctx $Sid) { Write-HMLog $Job "Benutzer-Registry ist geladen (Benutzer angemeldet)" 'Debug'; return $true }
    $r = Invoke-HMTarget $Ctx {
        param($s, $pp)
        $dat = Join-Path $pp 'NTUSER.DAT'
        if (-not (Test-Path -LiteralPath $dat)) { return "FEHLER: $dat nicht gefunden" }
        $out = & reg.exe load "HKU\$s" "$dat" 2>&1
        if ($LASTEXITCODE -ne 0) { return "FEHLER: reg load: $out" }
        return 'OK'
    } @($Sid, $ProfilePath)
    if ("$r" -eq 'OK') {
        $Ctx.HiveMountedBy = $Sid
        Write-HMLog $Job "Benutzer-Registry (NTUSER.DAT) geladen: HKU\$Sid" 'Debug'
        return $true
    }
    Write-HMLog $Job "Benutzer-Registry konnte nicht geladen werden: $r" 'Warning'
    return $false
}

function Dismount-HMHive {
    param([hashtable]$Ctx, $Job)
    if (-not $Ctx.HiveMountedBy) { return }
    $sid = $Ctx.HiveMountedBy
    $r = Invoke-HMTarget $Ctx {
        param($s)
        for ($i = 1; $i -le 5; $i++) {
            [GC]::Collect(); [GC]::WaitForPendingFinalizers()
            $out = & reg.exe unload "HKU\$s" 2>&1
            if ($LASTEXITCODE -eq 0) { return 'OK' }
            Start-Sleep -Seconds 2
        }
        return "FEHLER: $out"
    } @($sid)
    if ("$r" -eq 'OK') { Write-HMLog $Job "Benutzer-Registry wieder entladen" 'Debug'; $Ctx.HiveMountedBy = $null }
    else { Write-HMLog $Job "Benutzer-Registry konnte nicht entladen werden ($r) - Neustart des Ziel-PCs vor der naechsten Anmeldung empfohlen" 'Warning' }
}

# Platzhalter-Werte fuer den Ziel-PC/Benutzer ermitteln (beruecksichtigt umgeleitete AppData-Ordner)
function Get-HMTargetEnv {
    param([hashtable]$Ctx, [string]$Sid, [string]$ProfilePath)
    $r = Invoke-HMTarget $Ctx {
        param($s, $pp)
        $e = @{
            SYSTEMDRIVE = $env:SystemDrive; WINDIR = $env:windir; PROGRAMDATA = $env:ProgramData
            PROGRAMFILES = $env:ProgramFiles; PROGRAMFILESX86 = ${env:ProgramFiles(x86)}; PUBLIC = $env:PUBLIC
            PROFILE = $pp; APPDATA = (Join-Path $pp 'AppData\Roaming'); LOCALAPPDATA = (Join-Path $pp 'AppData\Local')
            APPDATA_REDIRECTED = $false
        }
        if ($s) {
            $usf = "Registry::HKEY_USERS\$s\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
            try {
                # Rohwert lesen (REG_EXPAND_SZ NICHT mit den Variablen des Admin-Kontos aufloesen) und fuer den Zielbenutzer aufloesen
                $k = Get-Item -LiteralPath $usf -ErrorAction Stop
                foreach ($pair in @(@('AppData', 'APPDATA'), @('Local AppData', 'LOCALAPPDATA'))) {
                    $v = [string]$k.GetValue($pair[0], $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                    if ($v) {
                        $v = [regex]::Replace($v, '%USERPROFILE%', $pp.Replace('$', '$$'), 'IgnoreCase')
                        $v = [Environment]::ExpandEnvironmentVariables($v)
                        if ($v -notmatch '%') { $e[$pair[1]] = $v; if ($v.StartsWith('\\')) { $e.APPDATA_REDIRECTED = $true } }
                    }
                }
            } catch { }
        }
        $e
    } @($Sid, $ProfilePath)
    $h = @{}
    foreach ($k in @('SYSTEMDRIVE','WINDIR','PROGRAMDATA','PROGRAMFILES','PROGRAMFILESX86','PUBLIC','PROFILE','APPDATA','LOCALAPPDATA','APPDATA_REDIRECTED')) { $h[$k] = $r.$k }
    if (-not $h.PROGRAMFILESX86) { $h.PROGRAMFILESX86 = $h.PROGRAMFILES }
    return $h
}

# {TOKEN} im Pfad ersetzen -> Pfad am Ziel-PC (lokale Schreibweise)
function Resolve-HMToken {
    param([hashtable]$TEnv, [string]$Path)
    $p = $Path
    foreach ($k in $TEnv.Keys) { if ($TEnv[$k] -is [string]) { $p = $p.Replace("{$k}", $TEnv[$k]) } }
    return $p
}

# HKCU -> HKU\<SID>, HKLM/HKU unveraendert, Kurzformen fuer reg.exe
function Resolve-HMRegKey {
    param([string]$Key, [string]$Sid)
    $k = $Key -replace '^HKEY_CURRENT_USER', 'HKCU' -replace '^HKEY_LOCAL_MACHINE', 'HKLM' -replace '^HKEY_USERS', 'HKU'
    if ($k -match '^HKCU\\?(.*)$') { $k = "HKU\$Sid" + $(if ($Matches[1]) { '\' + $Matches[1] } else { '' }) }
    return $k
}

# ============================================================================
# ROBOCOPY
# ============================================================================
function Get-HMRobocopySummary([string]$Text) {
    $s = [ordered]@{ FilesTotal = 0; FilesCopied = 0; FilesSkipped = 0; FilesFailed = 0; BytesTotal = [long]0; BytesCopied = [long]0; BytesSkipped = [long]0 }
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^\s*(Dateien|Files)\s*:\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)') {
            $s.FilesTotal = [int]$Matches[2]; $s.FilesCopied = [int]$Matches[3]; $s.FilesSkipped = [int]$Matches[4]; $s.FilesFailed = [int]$Matches[6]
        } elseif ($line -match '^\s*Bytes\s*:\s+(\d+)\s+(\d+)\s+(\d+)') {
            $s.BytesTotal = [long]$Matches[1]; $s.BytesCopied = [long]$Matches[2]; $s.BytesSkipped = [long]$Matches[3]
        }
    }
    return $s
}

function Invoke-HMRobocopy {
    param(
        $Job, [string]$Source, [string]$Dest, [string[]]$Files = @(), [string[]]$XD = @(), [string[]]$XF = @(),
        [switch]$NoHidden, [switch]$NoRecurse, [switch]$ListOnly, [int]$Threads = 16, [string]$LogFile,
        [switch]$ListFiles, $Stats, [string]$StatsRoot, [string]$StatsModule,  # ListFiles: Dateiliste fuer "Grosse Dateien" auswerten
        [switch]$ExcludeOlder                                                    # /XO: neuere Zieldateien nicht ueberschreiben
    )
    $q = { param($p) $p = $p.TrimEnd('\'); if ($p -match '^[A-Za-z]:$') { $p += '\.' }; '"' + $p + '"' }
    $a = New-Object System.Collections.Generic.List[string]
    $a.Add((& $q $Source)); $a.Add((& $q $Dest))
    foreach ($f in $Files) { $a.Add('"' + $f + '"') }
    if (-not $NoRecurse) { $a.Add('/E') }
    foreach ($o in @('/COPY:DAT', '/DCOPY:T', '/R:1', '/W:2', '/XJ', '/NP', '/NDL', '/BYTES')) { $a.Add($o) }
    if ($ListFiles -and $ListOnly) { $a.Add('/FP'); $a.Add('/NC') } else { $a.Add('/NFL') }
    $a.Add("/MT:$([Math]::Max(1, [Math]::Min(128, $Threads)))")
    # /XA:O: Dateien mit Attribut 'Offline' (Nur-Cloud-Platzhalter) nie lesen -> kein Download aus OneDrive/SharePoint o.ae.
    if ($NoHidden) { $a.Add('/XA:SHO') } else { $a.Add('/XA:O') }
    if ($ListOnly) { $a.Add('/L') }
    if ($ExcludeOlder) { $a.Add('/XO') }
    if ($XD.Count) { $a.Add('/XD'); foreach ($x in $XD) { $a.Add('"' + $x.TrimEnd('\') + '"') } }
    if ($XF.Count) { $a.Add('/XF'); foreach ($x in $XF) { $a.Add('"' + $x + '"') } }
    $tmpLog = [System.IO.Path]::Combine($env:TEMP, "HMrc_$([guid]::NewGuid().ToString('N')).log")
    $a.Add("/UNILOG:`"$tmpLog`"")

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $env:windir 'System32\Robocopy.exe'
    $psi.Arguments = ($a -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $Job.Process = $proc
    while (-not $proc.WaitForExit(400)) {
        if (Test-HMCancel $Job) { try { $proc.Kill() } catch { }; break }
    }
    $proc.WaitForExit()
    $Job.Process = $null
    $code = $proc.ExitCode
    $text = ''
    if (Test-Path -LiteralPath $tmpLog) {
        try { $text = [System.IO.File]::ReadAllText($tmpLog, [System.Text.Encoding]::Unicode) } catch { }
        if ($ListFiles -and $Stats) { try { Add-HMListStats $Stats $text $(if ($StatsRoot) { $StatsRoot } else { $Source }) $StatsModule } catch { } }
        if ($LogFile) { try { Add-Content -LiteralPath $LogFile -Value $text -Encoding UTF8 } catch { } }
        Remove-Item -LiteralPath $tmpLog -Force -ErrorAction SilentlyContinue
    }
    $sum = Get-HMRobocopySummary $text
    $lvl = if (Test-HMCancel $Job) { 'Cancel' } elseif ($code -ge 8) { 'Error' } elseif ($code -ge 4) { 'Warning' } else { 'OK' }
    return [pscustomobject]@{ ExitCode = $code; Level = $lvl; FilesTotal = $sum.FilesTotal; FilesCopied = $sum.FilesCopied
        FilesSkipped = $sum.FilesSkipped; FilesFailed = $sum.FilesFailed; BytesTotal = $sum.BytesTotal; BytesCopied = $sum.BytesCopied
        BytesSkipped = $sum.BytesSkipped; Args = $psi.Arguments }
}

# ============================================================================
# REGISTRY EXPORT / IMPORT
# ============================================================================
function Export-HMReg {
    param([hashtable]$Ctx, $Job, [string]$Key, [string]$OutFile)
    $full = Resolve-HMRegKey $Key $Ctx.UserSid
    $res = Invoke-HMTarget $Ctx {
        param($k, $tmpName)
        $pp = $k -replace '^HKU\\', 'HKEY_USERS\' -replace '^HKLM\\', 'HKEY_LOCAL_MACHINE\'
        if (-not (Test-Path -LiteralPath "Registry::$pp")) { return 'MISSING' }
        $f = Join-Path $env:windir "Temp\$tmpName"
        $o = & reg.exe export "$k" "$f" /y 2>&1
        if ($LASTEXITCODE -ne 0) { return "FEHLER: $o" }
        return $f
    } @($full, "HMreg_$([guid]::NewGuid().ToString('N')).reg")
    if ("$res" -eq 'MISSING') { return 'MISSING' }
    if ("$res" -like 'FEHLER*') { return "$res" }
    $src = Convert-HMPath $Ctx "$res"
    try {
        $dir = Split-Path $OutFile -Parent
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Copy-Item -LiteralPath $src -Destination $OutFile -Force -ErrorAction Stop
        Remove-Item -LiteralPath $src -Force -ErrorAction SilentlyContinue
        return 'OK'
    } catch { return "FEHLER: $($_.Exception.Message)" }
}

# .reg-Datei einlesen (UTF-16 oder ANSI)
function Read-HMRegFile([string]$Path) {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { return [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2) }
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { return [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3) }
    return [System.Text.Encoding]::Default.GetString($bytes)
}

# Schluesselpfade (alter SID / HKCU) und Profilpfade auf den Zielbenutzer umschreiben, dann importieren
function Convert-HMRegText {
    param([string]$Text, [string]$TargetSid, [string]$SourceSid, [string]$SourceProfile, [string]$TargetProfile)
    $t = [regex]::Replace($Text, '(?im)^(\[-?)HKEY_CURRENT_USER', ('${1}HKEY_USERS\' + $TargetSid))
    if ($SourceSid -and $SourceSid -ne $TargetSid) {
        $t = [regex]::Replace($t, '(?im)^(\[-?)HKEY_USERS\\' + [regex]::Escape($SourceSid), ('${1}HKEY_USERS\' + $TargetSid))
    }
    if ($SourceProfile -and $TargetProfile -and ($SourceProfile.TrimEnd('\') -ne $TargetProfile.TrimEnd('\'))) {
        $srcEsc = $SourceProfile.TrimEnd('\').Replace('\', '\\')
        $dstEsc = $TargetProfile.TrimEnd('\').Replace('\', '\\')
        $t = [regex]::Replace($t, [regex]::Escape($srcEsc) + '(?=\\\\|"|$)', $dstEsc.Replace('$', '$$'), 'IgnoreCase, Multiline')
    }
    return $t
}

function Import-HMReg {
    param([hashtable]$Ctx, $Job, [string]$File, [string]$SourceSid, [string]$SourceProfile)
    $text = Convert-HMRegText -Text (Read-HMRegFile $File) -TargetSid $Ctx.UserSid -SourceSid $SourceSid -SourceProfile $SourceProfile -TargetProfile $Ctx.ProfilePath
    $name = "HMimp_$([guid]::NewGuid().ToString('N')).reg"
    $env0 = Invoke-HMTarget $Ctx { $env:windir }
    $targetLocal = Join-Path $env0 "Temp\$name"
    $targetReach = Convert-HMPath $Ctx $targetLocal
    try {
        [System.IO.File]::WriteAllText($targetReach, $text, [System.Text.Encoding]::Unicode)
    } catch { return "FEHLER: Temp-Datei am Ziel nicht schreibbar: $($_.Exception.Message)" }
    $r = Invoke-HMTarget $Ctx {
        param($f)
        $o = & reg.exe import "$f" 2>&1
        $c = $LASTEXITCODE
        Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
        if ($c -ne 0) { return "FEHLER: $o" }
        'OK'
    } @($targetLocal)
    return "$r"
}

# ============================================================================
# MANIFEST / BACKUP-LISTE (auch von der Oberflaeche genutzt)
# ============================================================================
function Save-HMManifest([hashtable]$Manifest, [string]$BackupPath) {
    $Manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $BackupPath 'manifest.json') -Encoding UTF8 -Force
}

# Liest ein Backup (neu: manifest.json, alt: Ordnerstruktur der Vorgaengerversion)
function Read-HMBackupInfo {
    param([string]$Path, [object[]]$Modules)
    $mf = Join-Path $Path 'manifest.json'
    if (Test-Path -LiteralPath $mf) {
        try {
            $m = Get-Content -LiteralPath $mf -Raw -Encoding UTF8 | ConvertFrom-Json
            $mods = @($m.Modules | Where-Object { $_.Status -in @('OK', 'Warning') } | ForEach-Object { $_.Id })
            return [pscustomobject]@{ Path = $Path; Name = (Split-Path $Path -Leaf); Legacy = $false; Created = $m.Created
                Computer = $m.SourceComputer; User = $m.UserName; Account = $m.Account; Sid = $m.UserSid; ProfilePath = $m.ProfilePath
                Modules = $mods; SizeBytes = [long]$m.SizeBytes; Status = $m.Status; Manifest = $m }
        } catch { }
    }
    # Legacy-Erkennung
    $sidFile = Join-Path $Path 'SID.txt'
    $isLegacy = (Test-Path -LiteralPath $sidFile) -or (Test-Path -LiteralPath (Join-Path $Path 'USER')) -or (Test-Path -LiteralPath (Join-Path $Path 'DATA_C'))
    if (-not $isLegacy) { return $null }
    $leaf = Split-Path $Path -Leaf
    $user = if ($leaf -match '^\d{8}-(.+)$') { $Matches[1] } else { $leaf }
    $created = ''
    if ($leaf -match '^(\d{2})(\d{2})(\d{4})-') { $created = "$($Matches[3])-$($Matches[1])-$($Matches[2])" }
    $sid = ''
    if (Test-Path -LiteralPath $sidFile) { $sid = ((Get-Content -LiteralPath $sidFile -ErrorAction SilentlyContinue) -join ',').Split(',')[0].Trim() }
    $comp = ''
    $ipf = @(Get-ChildItem -LiteralPath $Path -Filter '05-IPAdress_*.txt' -ErrorAction SilentlyContinue)
    if ($ipf) { $comp = $ipf[0].BaseName -replace '^05-IPAdress_', '' }
    $rb = @(Get-ChildItem -LiteralPath $Path -Filter 'RemoteBackup_*.txt' -ErrorAction SilentlyContinue)
    if ($rb) { $comp = $rb[0].BaseName -replace '^RemoteBackup_', '' }
    $found = foreach ($mod in $Modules) {
        foreach ($it in @($mod.Items)) {
            if ($it.Legacy -and (Test-Path -LiteralPath (Join-Path $Path $it.Legacy))) { $mod.Id; break }
        }
    }
    if ((Test-Path -LiteralPath (Join-Path $Path 'FOLDER1')) -or (Test-Path -LiteralPath (Join-Path $Path 'FOLDER2'))) { $found = @($found) + 'ExtraFolders' }
    return [pscustomobject]@{ Path = $Path; Name = $leaf; Legacy = $true; Created = $created; Computer = $comp; User = $user; Account = $null
        Sid = $sid; ProfilePath = "C:\Users\$user"; Modules = @($found | Select-Object -Unique); SizeBytes = [long]0; Status = 'Legacy'; Manifest = $null }
}

function Get-HMBackupList {
    param([string]$Root, [object[]]$Modules)
    if (-not (Test-Path -LiteralPath $Root)) { return @() }
    $list = foreach ($d in @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue)) {
        $i = Read-HMBackupInfo -Path $d.FullName -Modules $Modules
        if ($i) { $i }
    }
    return @($list | Sort-Object { $_.Name } -Descending)
}

# ============================================================================
# HILFSFUNKTIONEN v0.0.3: freier Platz, Pfad-Rueckwandlung, Cloud-Ordner (OneDrive/SharePoint), Statistik
# ============================================================================
# Freier Platz fuer beliebige Pfade (Laufwerk oder UNC-Freigabe). -1 = unbekannt
function Get-HMFreeSpace([string]$Path) {
    if (-not ('HMNet.Disk' -as [type])) {
        Add-Type -Namespace HMNet -Name Disk -MemberDefinition @'
[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern bool GetDiskFreeSpaceEx(string lpDirectoryName, out ulong lpFreeBytesAvailable, out ulong lpTotalNumberOfBytes, out ulong lpTotalNumberOfFreeBytes);
'@
    }
    $p = $Path
    while ($p -and -not (Test-Path -LiteralPath $p)) { $p = Split-Path $p -Parent }
    if (-not $p) { return [long]-1 }
    if (-not $p.EndsWith('\')) { $p += '\' }
    $free = [uint64]0; $total = [uint64]0; $tfree = [uint64]0
    if ([HMNet.Disk]::GetDiskFreeSpaceEx($p, [ref]$free, [ref]$total, [ref]$tfree)) { return [long]$free }
    return [long]-1
}

# Erreichbaren Pfad (\\PC\C$\...) zurueck in die Schreibweise am Ziel-PC (C:\...) wandeln
function ConvertFrom-HMPath([string]$Path) {
    if ($Path -match '^\\\\[^\\]+\\([A-Za-z])\$(\\.*)?$') { return ($Matches[1].ToUpper() + ':' + $(if ($Matches[2]) { $Matches[2] } else { '\' })) }
    return $Path
}

# Pfad liegt in (oder ist) Ordner?
function Test-HMPathUnder([string]$Path, [string]$Parent) {
    if (-not $Path -or -not $Parent) { return $false }
    $p = $Path.TrimEnd('\'); $r = $Parent.TrimEnd('\')
    return ($p.Equals($r, [StringComparison]::OrdinalIgnoreCase) -or $p.StartsWith($r + '\', [StringComparison]::OrdinalIgnoreCase))
}

# Cloud-Synchronisationsordner des Benutzers (OneDrive, SharePoint-Bibliotheken, andere Cloud-Anbieter)
# Quellen: HKLM SyncRootManager (Cloud-Files-API, alle Anbieter), OneDrive-Konten im Benutzer-Hive, Profil\OneDrive*
function Get-HMSyncRoots {
    param([hashtable]$Ctx, [string]$Sid, [string]$ProfilePath)
    $r = Invoke-HMTarget $Ctx {
        param($s, $pp)
        $list = New-Object System.Collections.Generic.List[string]
        $base = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\SyncRootManager'
        foreach ($k in @(Get-ChildItem -LiteralPath $base -ErrorAction SilentlyContinue)) {
            $u = Get-ItemProperty -LiteralPath (Join-Path $k.PSPath 'UserSyncRoots') -ErrorAction SilentlyContinue
            if ($u -and $s -and $u.$s) { $list.Add([string]$u.$s) }
        }
        $acc = "Registry::HKEY_USERS\$s\Software\Microsoft\OneDrive\Accounts"
        if ($s -and (Test-Path -LiteralPath $acc)) {
            foreach ($a in @(Get-ChildItem -LiteralPath $acc -ErrorAction SilentlyContinue)) {
                $p = Get-ItemProperty -LiteralPath $a.PSPath -ErrorAction SilentlyContinue
                if ($p.UserFolder) { $list.Add([string]$p.UserFolder) }
                $mp = Get-ItemProperty -LiteralPath (Join-Path $a.PSPath 'ScopeIdToMountPointPathCache') -ErrorAction SilentlyContinue
                if ($mp) { foreach ($v in $mp.PSObject.Properties) { if ($v.Name -notlike 'PS*' -and "$($v.Value)" -match '^[A-Za-z]:\\') { $list.Add([string]$v.Value) } } }
            }
        }
        if ($pp -and (Test-Path -LiteralPath $pp)) {
            foreach ($d in @(Get-ChildItem -LiteralPath $pp -Directory -Force -Filter 'OneDrive*' -ErrorAction SilentlyContinue)) { $list.Add($d.FullName) }
        }
        @($list | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | ForEach-Object { $_.TrimEnd('\') })
    } @($Sid, $ProfilePath)
    # Doppelte und verschachtelte entfernen (aeusserster Ordner zaehlt)
    # erst Duplikate entfernen (ohne Gross/Klein), dann nach Laenge sortieren
    # (Sort-Object {Laenge} -Unique wuerde gleich lange, verschiedene Pfade verwerfen!)
    $seen = @{}
    $uniq = foreach ($x in @($r | Where-Object { $_ })) { $k = "$x".ToUpperInvariant(); if (-not $seen.ContainsKey($k)) { $seen[$k] = 1; "$x" } }
    $all = @($uniq | Sort-Object { $_.Length })
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($p in $all) {
        $nested = $false
        foreach ($o in $out) { if (Test-HMPathUnder $p $o) { $nested = $true; break } }
        if (-not $nested) { $out.Add($p) }
    }
    return @($out)
}

# Inhalt eines Cloud-Ordners am Ziel-PC auflisten: nur lokal vorhandene Dateien (nichts wird heruntergeladen)
# Nur-Cloud-Dateien (Platzhalter) haben RECALL_ON_DATA_ACCESS (0x400000), RECALL_ON_OPEN (0x40000) oder OFFLINE (0x1000).
function Get-HMCloudFolderContent {
    param([hashtable]$Ctx, [string]$Root)
    return (Invoke-HMTarget $Ctx {
        param($root)
        $files = New-Object System.Collections.Generic.List[string]
        $cloudN = 0; $cloudB = [long]0; $failDirs = 0
        $stack = New-Object System.Collections.Generic.Stack[object]
        $stack.Push(@($root, 0))
        while ($stack.Count -gt 0) {
            $e = $stack.Pop(); $d = [string]$e[0]; $lvl = [int]$e[1]
            if ($lvl -gt 60 -or $d.Length -gt 1000) { continue }
            try {
                foreach ($i in (New-Object System.IO.DirectoryInfo $d).EnumerateFileSystemInfos()) {
                    $a = [int]$i.Attributes
                    if ($a -band 0x10) { $stack.Push(@($i.FullName, ($lvl + 1))); continue }
                    if (($a -band 0x400000) -or ($a -band 0x40000) -or ($a -band 0x1000)) { $cloudN++; $cloudB += $i.Length; continue }
                    $files.Add(('{0}|{1}|{2}' -f $i.Length, $i.LastWriteTimeUtc.Ticks, $i.FullName.Substring($root.TrimEnd('\').Length).TrimStart('\')))
                }
            } catch { $failDirs++ }
        }
        [pscustomobject]@{ Files = $files.ToArray(); CloudCount = $cloudN; CloudBytes = $cloudB; FailedDirs = $failDirs }
    } @($Root))
}

# Nur lokal vorhandene Dateien eines Cloud-Ordners sichern (inkrementell: gleiche Groesse + Zeit = uebersprungen)
function Backup-HMCloudFolder {
    param([hashtable]$Ctx, $Job, [string]$RootLocal, [string]$Dest, [string[]]$XFPatterns = @(), [string]$ModuleName = '')
    $c = Get-HMCloudFolderContent $Ctx $RootLocal
    $srcReach = Convert-HMPath $Ctx $RootLocal
    $total = [long]0; $n = 0; $copyB = [long]0; $copyN = 0; $fail = 0; $skipPat = 0
    $leaf = Split-Path $RootLocal -Leaf
    foreach ($line in @($c.Files)) {
        if (Test-HMCancel $Job) { break }
        $p = $line.Split('|', 3)
        if ($p.Count -lt 3) { continue }
        $size = [long]$p[0]; $ticks = [long]$p[1]; $rel = $p[2]
        $name = [System.IO.Path]::GetFileName($rel)
        $hit = $false
        foreach ($pat in $XFPatterns) { if ($pat -and $name -like $pat) { $hit = $true; break } }
        if ($hit -or $name -like '~$*') { $skipPat++; continue }
        $total += $size; $n++
        if ($Ctx.MeasureStats) { Add-HMStatFile $Ctx.MeasureStats $size (Join-Path $srcReach $rel) $srcReach $ModuleName }
        $dstFile = Join-Path $Dest $rel
        $need = $true
        try {
            $fi = New-Object System.IO.FileInfo $dstFile
            # 2 s Toleranz (exFAT/FAT speichern Zeiten nur auf 2 s genau)
            if ($fi.Exists -and $fi.Length -eq $size -and [Math]::Abs($fi.LastWriteTimeUtc.Ticks - $ticks) -le 20000000) { $need = $false }
        } catch { }
        if (-not $need) { continue }
        $copyB += $size; $copyN++
        if ($Ctx.ListOnly) { continue }
        if ($copyN % 100 -eq 0) { $Job.Status = "$ModuleName - $leaf ($copyN Dateien)" }
        try {
            [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($dstFile))
            if ([System.IO.File]::Exists($dstFile)) { [System.IO.File]::SetAttributes($dstFile, [System.IO.FileAttributes]::Normal) }
            [System.IO.File]::Copy((Join-Path $srcReach $rel), $dstFile, $true)
            [System.IO.File]::SetLastWriteTimeUtc($dstFile, (New-Object DateTime ($ticks, [DateTimeKind]::Utc)))
        } catch {
            $fail++
            if ($Ctx.RoboLog) { try { Add-Content -LiteralPath $Ctx.RoboLog -Value "CLOUD-ORDNER FEHLER $srcReach\$rel : $($_.Exception.Message)" -Encoding UTF8 } catch { } }
        }
    }
    $st = if (Test-HMCancel $Job) { 'Cancel' } elseif ($fail -gt 0 -or $c.FailedDirs -gt 0) { 'Warning' } else { 'OK' }
    $msg = "{0}: {1} Dateien lokal ({2})" -f $leaf, $n, (Format-HMSize $total)
    if (-not $Ctx.ListOnly) { $msg += ", $copyN kopiert" }
    if ($c.CloudCount) { $msg += ", $($c.CloudCount) nur in der Cloud ($(Format-HMSize $c.CloudBytes)) nicht heruntergeladen" }
    if ($fail) { $msg += ", $fail FEHLGESCHLAGEN" }
    if ($c.FailedDirs) { $msg += ", $($c.FailedDirs) Ordner nicht lesbar (Cloud-Client am PC nicht aktiv?)" }
    return [pscustomobject]@{ Status = $st; Msg = $msg; Bytes = $total; BytesCopied = $copyB; Files = $n; CloudCount = $c.CloudCount; CloudBytes = $c.CloudBytes }
}

# --- Statistik fuer "Grosse Dateien / Ordner" (nur bei Groesse ermitteln) ---
function New-HMStats { return @{ Files = (New-Object System.Collections.Generic.List[object]); MinFile = [long]0; Folders = @{} } }
function Add-HMStatFile($Stats, [long]$Size, [string]$Path, [string]$RootReach, [string]$ModuleName) {
    if ($Size -ge $Stats.MinFile -and $Size -gt 0) {
        $Stats.Files.Add([pscustomobject]@{ Size = $Size; Path = $Path; Module = $ModuleName })
        if ($Stats.Files.Count -ge 600) {
            $keep = @($Stats.Files | Sort-Object Size -Descending | Select-Object -First 150)
            $Stats.Files.Clear(); foreach ($k in $keep) { $Stats.Files.Add($k) }
            $Stats.MinFile = $keep[-1].Size
        }
    }
    # Ordner bis 3 Ebenen unter dem Quellordner aufsummieren
    $ix = $Path.LastIndexOf('\')
    $dir = if ($ix -gt 0) { $Path.Substring(0, $ix) } else { '' }
    $root = $RootReach.TrimEnd('\')
    if (-not $dir -or -not $dir.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { return }
    $parts = $dir.Substring($root.Length + 1).Split('\')
    $key = $root
    for ($i = 0; $i -lt [Math]::Min(3, $parts.Count); $i++) {
        $key = $key + '\' + $parts[$i]
        $k2 = $key.ToLowerInvariant()
        if ($Stats.Folders.ContainsKey($k2)) { $Stats.Folders[$k2].Size += $Size } else { $Stats.Folders[$k2] = [pscustomobject]@{ Path = $key; Size = $Size; Module = $ModuleName } }
    }
}
# Robocopy-Dateiliste (/L /FP /NC /BYTES ohne /NFL) auswerten: Zeilen "<Groesse><Tab><Pfad>"
function Add-HMListStats($Stats, [string]$Text, [string]$RootReach, [string]$ModuleName) {
    if (-not $Text) { return }
    $rdr = New-Object System.IO.StringReader $Text
    $rx = [regex]'^\s+(\d+)\s+(\S.*)$'
    while ($null -ne ($line = $rdr.ReadLine())) {
        $m = $rx.Match($line)
        if (-not $m.Success) { continue }
        $path = $m.Groups[2].Value.Trim()
        if ($path.EndsWith('\') -or $path -notmatch '^(\\\\|[A-Za-z]:\\)') { continue }
        Add-HMStatFile $Stats ([long]$m.Groups[1].Value) $path $RootReach $ModuleName
    }
}

# ============================================================================
# PRUEFUNG NACH DEM BACKUP: Robocopy-Vergleich + Hash-Stichprobe
# ============================================================================
function Test-HMBackupIntegrity {
    param([hashtable]$Ctx, $Job, [object[]]$Map, [int]$Samples = 30)
    $diffFiles = 0; $diffBytes = [long]0
    $Ctx.ListOnly = $true
    try {
        foreach ($m in @($Map)) {
            if (Test-HMCancel $Job) { break }
            $Job.Status = "Pruefung: $($m.Module) / $($m.Name)"
            $rc = Invoke-HMRobocopy -Job $Job -Source $m.Src -Dest $m.Dst -Files $m.Files -XD $m.XD -XF $m.XF -NoHidden:$m.NoHidden -NoRecurse:$m.NoRecurse -ListOnly -Threads $Ctx.Threads
            $diffFiles += $rc.FilesCopied; $diffBytes += $rc.BytesCopied
        }
    } finally { $Ctx.ListOnly = $false }
    # Hash-Stichprobe: zufaellige Dateien (max. 50 MB je Datei, 500 MB gesamt) Backup <-> Quelle
    $cand = New-Object System.Collections.Generic.List[object]
    foreach ($m in @($Map)) {
        if (-not (Test-Path -LiteralPath $m.Dst)) { continue }
        $n = 0
        try {
            $opt = if ($m.NoRecurse) { [System.IO.SearchOption]::TopDirectoryOnly } else { [System.IO.SearchOption]::AllDirectories }
            foreach ($f in [System.IO.Directory]::EnumerateFiles($m.Dst, '*', $opt)) {
                $cand.Add([pscustomobject]@{ Dst = $f; Src = ($m.Src.TrimEnd('\') + $f.Substring($m.Dst.TrimEnd('\').Length)) }); $n++
                if ($n -ge 3000) { break }
            }
        } catch { }
    }
    $checked = 0; $bad = New-Object System.Collections.Generic.List[string]; $sum = [long]0
    if ($cand.Count) {
        $pick = @($cand | Get-Random -Count ([Math]::Min($cand.Count, $Samples * 3)))
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            foreach ($c in $pick) {
                if ($checked -ge $Samples -or $sum -gt 500MB -or (Test-HMCancel $Job)) { break }
                try {
                    $fi = New-Object System.IO.FileInfo $c.Dst
                    $fs = New-Object System.IO.FileInfo $c.Src
                    # nur Dateien, die sich seit dem Kopieren nicht geaendert haben (sonst ist ein Unterschied normal)
                    if ($fi.Length -gt 50MB -or -not $fs.Exists -or $fs.Length -ne $fi.Length -or [Math]::Abs($fs.LastWriteTimeUtc.Ticks - $fi.LastWriteTimeUtc.Ticks) -gt 20000000) { continue }
                    $h1 = $null; $h2 = $null
                    $s1 = [System.IO.File]::OpenRead($c.Dst); try { $h1 = [BitConverter]::ToString($sha.ComputeHash($s1)) } finally { $s1.Dispose() }
                    $s2 = [System.IO.File]::Open($c.Src, 'Open', 'Read', 'ReadWrite'); try { $h2 = [BitConverter]::ToString($sha.ComputeHash($s2)) } finally { $s2.Dispose() }
                    $checked++; $sum += $fi.Length
                    if ($h1 -ne $h2) { $bad.Add((ConvertFrom-HMPath $c.Src)) }
                } catch { }
            }
        } finally { $sha.Dispose() }
    }
    # Geaenderte/neue Dateien seit dem Kopieren sind normal (Benutzer aktiv) -> nur Hinweis; Hash-Abweichung = Warnung
    $st = if ($bad.Count) { 'Warning' } else { 'OK' }
    return [pscustomobject]@{ Status = $st; DiffFiles = $diffFiles; DiffBytes = $diffBytes; Sampled = $checked; HashMismatch = @($bad) }
}

# ============================================================================
# PROTOKOLL (HTML) - Backup und Restore
# ============================================================================
function ConvertTo-HMHtml([string]$Text) { return [System.Net.WebUtility]::HtmlEncode("$Text") }
function New-HMReport {
    param([hashtable]$Ctx, [ValidateSet('Backup', 'Restore')][string]$Kind, [string]$OutFile, [object[]]$Modules, [System.Collections.IDictionary]$Facts, [string[]]$Notes = @(), [string]$Status)
    try {
        $logo = ''
        $lp = Join-Path $Ctx.ToolRoot 'Assets\logo64.png'
        if (Test-Path -LiteralPath $lp) { $logo = '<img src="data:image/png;base64,' + [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($lp)) + '" alt="">' }
        $col = @{ OK = '#2e7d32'; Warning = '#b26a00'; Error = '#c62828'; Cancel = '#c62828'; Cancelled = '#c62828'; Skip = '#777'; NoSpace = '#c62828' }
        $stTxt = @{ OK = 'OK'; Warning = 'Warnung'; Error = 'Fehler'; Cancel = 'Abgebrochen'; Cancelled = 'Abgebrochen'; Skip = 'nicht vorhanden'; NoSpace = 'zu wenig Platz' }
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append('<!DOCTYPE html><html lang="de"><head><meta charset="utf-8"><title>HUMig ' + $Kind + '</title><style>')
        [void]$sb.Append('body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#222}h1{font-size:22px;margin:0}header{display:flex;gap:14px;align-items:center;border-bottom:2px solid #444;padding-bottom:10px;margin-bottom:14px}')
        [void]$sb.Append('table{border-collapse:collapse;width:100%;margin:8px 0 16px}td,th{border:1px solid #ccc;padding:4px 8px;text-align:left;vertical-align:top;font-size:13px}th{background:#eee}')
        [void]$sb.Append('.st{font-weight:600}.facts td:first-child{width:220px;font-weight:600;background:#f6f6f6}.sig{margin-top:40px;display:flex;gap:60px}.sig div{border-top:1px solid #444;width:260px;padding-top:4px;font-size:12px}small{color:#666}@media print{body{margin:10mm}}')
        [void]$sb.Append('</style></head><body><header>' + $logo + '<div><h1>HUMig - ' + $(if ($Kind -eq 'Backup') { 'Backup-Protokoll' } else { 'Restore-Protokoll' }) + '</h1>')
        $c = if ($col.ContainsKey($Status)) { $col[$Status] } else { '#222' }
        $t = if ($stTxt.ContainsKey($Status)) { $stTxt[$Status] } else { $Status }
        [void]$sb.Append('<div>Status: <span class="st" style="color:' + $c + '">' + (ConvertTo-HMHtml $t) + '</span></div></div></header>')
        [void]$sb.Append('<table class="facts">')
        foreach ($k in $Facts.Keys) { if ("$($Facts[$k])" -ne '') { [void]$sb.Append('<tr><td>' + (ConvertTo-HMHtml $k) + '</td><td>' + (ConvertTo-HMHtml $Facts[$k]) + '</td></tr>') } }
        [void]$sb.Append('</table><h2 style="font-size:16px">Module</h2><table><tr><th>Modul</th><th>Status</th><th>Details</th></tr>')
        foreach ($m in @($Modules)) {
            $mc = if ($col.ContainsKey("$($m.Status)")) { $col["$($m.Status)"] } else { '#222' }
            $mt = if ($stTxt.ContainsKey("$($m.Status)")) { $stTxt["$($m.Status)"] } else { "$($m.Status)" }
            $det = @(foreach ($i in @($m.Items)) { if ($i -and $i.Msg) { (ConvertTo-HMHtml "$($i.Name): $($i.Msg)") } }) -join '<br>'
            [void]$sb.Append('<tr><td>' + (ConvertTo-HMHtml $m.Name) + '</td><td class="st" style="color:' + $mc + '">' + (ConvertTo-HMHtml $mt) + '</td><td>' + $det + '</td></tr>')
        }
        [void]$sb.Append('</table>')
        if (@($Notes | Where-Object { $_ }).Count) {
            [void]$sb.Append('<h2 style="font-size:16px">Hinweise</h2><ul>')
            foreach ($n in @($Notes | Where-Object { $_ })) { [void]$sb.Append('<li>' + (ConvertTo-HMHtml $n) + '</li>') }
            [void]$sb.Append('</ul>')
        }
        [void]$sb.Append('<div class="sig"><div>Datum, Unterschrift Betreuung</div><div>Datum, Unterschrift Benutzer/in</div></div>')
        [void]$sb.Append('<p><small>Erstellt mit HUMig ' + (ConvertTo-HMHtml $Ctx.ToolVersion) + ' am ' + (Get-Date).ToString('dd.MM.yyyy HH:mm') + ' - Drucken: Strg+P (auch als PDF)</small></p></body></html>')
        [System.IO.File]::WriteAllText($OutFile, $sb.ToString(), (New-Object System.Text.UTF8Encoding $true))
        return $OutFile
    } catch { return $null }
}

# ============================================================================
# BACKUP
# ============================================================================
function Get-HMItemTargetPath([string]$BackupPath, $Module, $Item) {
    return (Join-Path (Join-Path $BackupPath $Module.Id) $Item.Name)
}

function Get-HMExceptionLists([hashtable]$Ctx, [string]$Which) {
    $ex = $Ctx.Exceptions
    if ($Which -eq 'Profile') {
        $xd = if ($Ctx.Options.MinimalProfileExceptions) { @($ex.MinimalProfileFolders) } else { @($ex.ProfileFolders) }
        $xf = if ($Ctx.Options.NoProfileFileExceptions) { @() } else { @($ex.ProfileFiles) }
    } else {
        $xd = if ($Ctx.Options.MinimalSystemExceptions) { @($ex.MinimalSystemFolders) } else { @($ex.SystemFolders) }
        $xf = if ($Ctx.Options.NoSystemFileExceptions) { @() } else { @($ex.SystemFiles) }
    }
    return @{ XD = @($xd | Where-Object { $_ }); XF = @($xf | Where-Object { $_ }) }
}

# Laeuft am Ziel-PC: Ordner mit Nur-Cloud-Platzhaltern finden (nichts wird geoeffnet oder heruntergeladen).
# Ordner mit Platzhalter-Attribut selbst (noch nicht aufgelistete Cloud-Ordner) werden nicht betreten.
$script:HMPlaceholderScan = {
    param([string]$Root, [string[]]$Skip, [int]$MaxSec)
    $mask = 0x400000 -bor 0x40000 -bor 0x1000   # RECALL_ON_DATA_ACCESS, RECALL_ON_OPEN, OFFLINE
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $skipN = @($Skip | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') + '\' })
    $hits = @{}
    $stack = New-Object System.Collections.Generic.Stack[string]; $stack.Push($Root)
    $timeout = $false
    while ($stack.Count) {
        if ($sw.Elapsed.TotalSeconds -gt $MaxSec) { $timeout = $true; break }
        $d = $stack.Pop()
        try {
            foreach ($i in (New-Object System.IO.DirectoryInfo $d).EnumerateFileSystemInfos()) {
                $a = [int]$i.Attributes
                if ($i -is [System.IO.DirectoryInfo]) {
                    if ($a -band [int][System.IO.FileAttributes]::ReparsePoint) { continue }
                    $fn = $i.FullName + '\'
                    if (@($skipN | Where-Object { $fn.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }).Count) { continue }
                    if ($a -band $mask) { $hits[$i.FullName] = 1 + [int]$hits[$i.FullName]; continue }
                    $stack.Push($i.FullName)
                } elseif ($a -band $mask) { $hits[$d] = 1 + [int]$hits[$d] }
            }
        } catch { }
    }
    # verschachtelte zusammenfassen (aeusserster Ordner zaehlt)
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($k in @($hits.Keys | Sort-Object { $_.Length })) {
        if (@($out | Where-Object { ($k + '\').StartsWith($_.Path + '\', [StringComparison]::OrdinalIgnoreCase) }).Count) { continue }
        $out.Add([pscustomobject]@{ Path = $k; Count = $hits[$k] })
    }
    [pscustomobject]@{ Dirs = $out.ToArray(); Timeout = $timeout }
}

function Backup-HMFolderItem {
    param([hashtable]$Ctx, $Job, $Module, $Item, [hashtable]$TEnv, [string]$DestOverride)
    $srcLocal = Resolve-HMToken $TEnv $Item.Path
    $src = Convert-HMPath $Ctx $srcLocal
    $dst = if ($DestOverride) { $DestOverride } else { Get-HMItemTargetPath $Ctx.BackupPath $Module $Item }
    $mk = { param($st, $msg) [pscustomobject]@{ Name = $Item.Name; Status = $st; Msg = $msg; Bytes = 0; BytesCopied = 0; Source = $srcLocal } }
    if (-not (Test-Path -LiteralPath $src)) { return (& $mk 'Skip' "nicht vorhanden: $srcLocal") }
    foreach ($p in @($Ctx.Options.ExcludePaths | Where-Object { $_ })) { if (Test-HMPathUnder $srcLocal $p) { return (& $mk 'Skip' "ausgeschlossen: $srcLocal") } }
    $roots = @($Ctx.SyncRoots | Where-Object { $_ })
    $xfPat = @()
    if ($Item.Exceptions -eq 'Profile') { $xfPat = @((Get-HMExceptionLists $Ctx 'Profile').XF) }

    # Quelle liegt selbst in einem Cloud-Ordner (z.B. zusaetzlicher Ordner in OneDrive): nur lokal vorhandene Dateien
    $inRoot = @($roots | Where-Object { Test-HMPathUnder $srcLocal $_ }) | Select-Object -First 1
    if ($inRoot -and $Item.Type -eq 'Folder') {
        $c = Backup-HMCloudFolder $Ctx $Job $srcLocal $dst $xfPat $Module.Name
        return [pscustomobject]@{ Name = $Item.Name; Status = $c.Status; Msg = "Cloud-Ordner - $($c.Msg)"; Bytes = $c.Bytes; BytesCopied = $c.BytesCopied; Source = $srcLocal }
    }

    $xd = @($Item.XD | Where-Object { $_ })
    $xf = @($Item.XF | Where-Object { $_ })
    if ($Item.Exceptions) {
        $l = Get-HMExceptionLists $Ctx $Item.Exceptions
        # Eintraege ohne Platzhalter nur direkt unter dem Quellordner ausschliessen (voller Pfad),
        # Eintraege mit * wirken wie bisher in jeder Ebene
        foreach ($x in $l.XD) { if ($x -match '[\*\?]') { $xd += $x } else { $xd += (Join-Path $src $x) } }
        $xf += $l.XF
        if ($Item.Exceptions -eq 'System') {
            # Backup-Ziel und Tool-Ordner nie mitkopieren, wenn sie auf dem Quelllaufwerk liegen
            foreach ($p in @($Ctx.BackupRoot, $Ctx.ToolRoot)) {
                if ($p -and -not $Ctx.IsRemote -and $p.StartsWith($srcLocal.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) { $xd += $p }
            }
        }
    }
    # Einzelne Pfade, die der Benutzer ausgeschlossen hat (Ordner oder Datei, Schreibweise am Quell-PC)
    foreach ($p in @($Ctx.Options.ExcludePaths | Where-Object { $_ })) {
        if (-not (Test-HMPathUnder $p $srcLocal)) { continue }
        $pr = Convert-HMPath $Ctx $p
        if (Test-Path -LiteralPath $pr -PathType Container) { $xd += $pr } else { $xf += $pr }
    }
    # Cloud-Ordner (OneDrive/SharePoint) nie ueber Robocopy lesen (wuerde Nur-Cloud-Dateien herunterladen)
    $subRoots = @($roots | Where-Object { (Test-HMPathUnder $_ $srcLocal) -and -not (Test-HMPathUnder $srcLocal $_) })
    # Cloud-Ordner, die ohnehin ausgeschlossen sind (z.B. C:\Users bei "Daten auf Systemlaufwerk"), nicht extra behandeln
    $fixedXd = @($xd | Where-Object { $_ -and $_ -notmatch '[\*\?]' })
    $subRoots = @($subRoots | Where-Object { $rr = Convert-HMPath $Ctx $_; -not @($fixedXd | Where-Object { Test-HMPathUnder $rr $_ }).Count })
    foreach ($r in $subRoots) { $xd += (Convert-HMPath $Ctx $r) }

    # Schutz gegen unbekannte Cloud-Anbieter: Quelle vor dem Kopieren nach Nur-Cloud-Platzhaltern durchsuchen
    # (Attribute RECALL_ON_DATA_ACCESS/RECALL_ON_OPEN/OFFLINE werden beim Auflisten gelesen, ohne etwas herunterzuladen).
    # Gefundene Ordner werden ausgelassen - Robocopy wuerde sonst einen Download ausloesen und koennte nicht abgebrochen werden.
    if (-not $Ctx.ListOnly -and $Item.Type -eq 'Folder') {
        $skipLocal = @($subRoots) + @($fixedXd | ForEach-Object { ConvertFrom-HMPath $_ })
        try {
            $cp = Invoke-HMTarget $Ctx $script:HMPlaceholderScan @($srcLocal, @($skipLocal), 120)
            foreach ($d in @($cp.Dirs | Where-Object { $_ })) {
                $xd += (Convert-HMPath $Ctx "$($d.Path)")
                Write-HMLog $Job ("   Nur-Cloud-Dateien gefunden (Cloud-Anbieter nicht erkannt) - ausgelassen: {0} ({1} Dateien)" -f $d.Path, $d.Count) 'Warning'
                if ($null -ne $Ctx.SyncRootLog) { $Ctx.SyncRootLog.Add([pscustomobject]@{ Path = "$($d.Path)"; Item = "$($Module.Id)/$($Item.Name)"; Rel = "$($d.Path)".Substring($srcLocal.TrimEnd('\').Length).TrimStart('\'); Mode = 'Skip' }) }
            }
            if ($cp.Timeout) { Write-HMLog $Job "   Pruefung auf Nur-Cloud-Dateien nach 120 s abgebrochen (sehr viele Dateien) - Robocopy ueberspringt 'Offline'-Dateien trotzdem" 'Debug' }
        } catch { Write-HMLog $Job "   Pruefung auf Nur-Cloud-Dateien nicht moeglich: $($_.Exception.Message)" 'Debug' }
    }

    $files = @()
    $noRec = $false
    if ($Item.Type -eq 'Files') { $files = @($Item.Filter); $noRec = $true }
    $rp = @{ Job = $Job; Source = $src; Dest = $dst; Files = $files; XD = $xd; XF = $xf; NoHidden = [bool]$Item.NoHidden; NoRecurse = $noRec
             ListOnly = [bool]$Ctx.ListOnly; Threads = $Ctx.Threads; LogFile = $Ctx.RoboLog }
    if ($Ctx.MeasureStats) { $rp.ListFiles = $true; $rp.Stats = $Ctx.MeasureStats; $rp.StatsRoot = $src; $rp.StatsModule = $Module.Name }
    # Leeres Ziel: Robocopy-"Uebersprungen" = nur absichtlich ausgeschlossene Dateien (Attribute/Muster) -> nicht zur Backup-Groesse zaehlen.
    # Vorhandenes Ziel (Backup ergaenzen): "Uebersprungen" mischt unveraenderte und ausgeschlossene Dateien.
    $fresh = $true
    if (-not $Ctx.ListOnly -and (Test-Path -LiteralPath $dst)) { $fresh = -not (Get-ChildItem -LiteralPath $dst -Force -ErrorAction SilentlyContinue | Select-Object -First 1) }
    $exWhy = if ($Item.NoHidden) { 'versteckt/System, Nur-Cloud, Ausschlussmuster' } else { 'Nur-Cloud, Ausschlussmuster' }
    $rc = Invoke-HMRobocopy @rp
    if (-not $Ctx.ListOnly -and $null -ne $Ctx.CopyMap) {
        $Ctx.CopyMap.Add([pscustomobject]@{ Module = $Module.Name; Name = $Item.Name; Src = $src; Dst = $dst; Files = $files; XD = $xd; XF = $xf; NoHidden = [bool]$Item.NoHidden; NoRecurse = $noRec })
    }
    $st = switch ($rc.Level) { 'OK' { 'OK' } 'Warning' { 'Warning' } 'Cancel' { 'Cancel' } default { 'Error' } }
    $bytesCopied = [long]$rc.BytesCopied
    if ($fresh) {
        $bytes = [Math]::Max([long]0, [long]$rc.BytesTotal - [long]$rc.BytesSkipped)
        $msg = "{0} Dateien, {1}" -f [Math]::Max(0, $rc.FilesTotal - $rc.FilesSkipped), (Format-HMSize $bytes)
        if ($rc.FilesSkipped -gt 0) { $msg += " | absichtlich ausgelassen: {0} Dateien, {1} ({2})" -f $rc.FilesSkipped, (Format-HMSize $rc.BytesSkipped), $exWhy }
    } else {
        $bytes = [long]$rc.BytesTotal
        $msg = "{0} Dateien, {1}" -f $rc.FilesTotal, (Format-HMSize $rc.BytesTotal)
        if ($rc.FilesCopied -lt $rc.FilesTotal) { $msg += " ($($rc.FilesCopied) neu/geaendert kopiert, $($rc.FilesSkipped) unveraendert oder ausgelassen: $exWhy)" }
    }
    if ($rc.FilesFailed -gt 0) { $msg += ", $($rc.FilesFailed) FEHLGESCHLAGEN (gesperrt/keine Rechte - siehe Robocopy-Log)" }
    if ($rc.Level -eq 'Error') { $msg += " (Robocopy-Code $($rc.ExitCode))" }

    # Cloud-Ordner innerhalb der Quelle: auslassen (Standard) oder nur lokal vorhandene Dateien sichern
    $skipped = @()
    foreach ($r in $subRoots) {
        if (Test-HMCancel $Job) { break }
        $rel = $r.Substring($srcLocal.TrimEnd('\').Length).TrimStart([char[]]'\/')
        if ($Ctx.Options.OneDriveLocal) {
            $c = Backup-HMCloudFolder $Ctx $Job $r (Join-Path $dst $rel) $xfPat $Module.Name
            $msg += " | Cloud-Ordner $($c.Msg)"
            $bytes += $c.Bytes; $bytesCopied += $c.BytesCopied
            if ($c.Status -eq 'Cancel') { $st = 'Cancel' } elseif ($c.Status -eq 'Warning' -and $st -eq 'OK') { $st = 'Warning' }
            $mode = 'Local'
        } else {
            $skipped += (Split-Path $r -Leaf)
            $mode = 'Skip'
        }
        if ($null -ne $Ctx.SyncRootLog -and -not $Ctx.ListOnly) { $Ctx.SyncRootLog.Add([pscustomobject]@{ Path = $r; Item = "$($Module.Id)/$($Item.Name)"; Rel = $rel; Mode = $mode }) }
    }
    if ($skipped.Count) { $msg += " | $($skipped.Count) Cloud-Ordner ausgelassen ($($skipped -join ', '))" }
    return [pscustomobject]@{ Name = $Item.Name; Status = $st; Msg = $msg; Bytes = $bytes; BytesCopied = $bytesCopied; Source = $srcLocal }
}

function Backup-HMRegItem {
    param([hashtable]$Ctx, $Job, $Module, $Item)
    if ($Item.Key -match '^HK(CU|EY_CURRENT_USER)' -and -not $Ctx.HiveReady) {
        return [pscustomobject]@{ Name = $Item.Name; Status = 'Error'; Msg = 'Benutzer-Registry nicht verfuegbar'; Bytes = 0; Source = $Item.Key }
    }
    $out = Join-Path (Join-Path $Ctx.BackupPath $Module.Id) "$($Item.Name).reg"
    $r = Export-HMReg $Ctx $Job $Item.Key $out
    if ($r -eq 'OK') { return [pscustomobject]@{ Name = $Item.Name; Status = 'OK'; Msg = 'Registry exportiert'; Bytes = (Get-Item -LiteralPath $out).Length; Source = $Item.Key } }
    if ($r -eq 'MISSING') { return [pscustomobject]@{ Name = $Item.Name; Status = 'Skip'; Msg = "Schluessel nicht vorhanden: $($Item.Key)"; Bytes = 0; Source = $Item.Key } }
    return [pscustomobject]@{ Name = $Item.Name; Status = 'Error'; Msg = $r; Bytes = 0; Source = $Item.Key }
}

# --- Builtin-Handler Backup ---
function Backup-HMBuiltin {
    param([hashtable]$Ctx, $Job, $Module, $Item, [hashtable]$TEnv)
    $dir = Join-Path $Ctx.BackupPath $Module.Id
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $res = { param($st, $msg, $b = 0) [pscustomobject]@{ Name = $Item.Handler; Status = $st; Msg = $msg; Bytes = $b; Source = '' } }
    switch ($Item.Handler) {

        'DesktopIconPositions' {
            $r = $null
            try { $r = Read-HMDesktopIconPositions $Ctx } catch { return (& $res 'Warning' "Symbolpositionen nicht lesbar: $($_.Exception.Message) - nur Registry-Anordnung gesichert") }
            if ($r.Status -eq 'SKIP') { return (& $res 'Skip' "Symbolpositionen: $($r.Msg) - nur Registry-Anordnung gesichert") }
            if ($r.Status -ne 'OK' -or -not @($r.Lines).Count) { return (& $res 'Warning' "Symbolpositionen: $($r.Msg) - nur Registry-Anordnung gesichert") }
            Set-Content -LiteralPath (Join-Path $dir 'positions.tsv') -Value @($r.Lines) -Encoding UTF8
            $msg = "$(@($r.Lines).Count) Symbolpositionen vom Desktop gelesen"
            if ("$($r.Msg)" -like '*AUTO*') { $msg += ' (Achtung: Symbole automatisch anordnen ist EIN - Positionen werden dann nicht verwendet)' }
            return (& $res 'OK' $msg)
        }

        'ExtraFolders' {
            $list = @($Ctx.Options.ExtraFolders | Where-Object { $_ })
            if (-not $list.Count) { return (& $res 'Skip' 'keine Ordner ausgewaehlt') }
            $idx = 0; $meta = @(); $bytes = [long]0; $worst = 'OK'
            foreach ($p in $list) {
                $idx++
                $fake = [pscustomobject]@{ Name = "FOLDER$idx"; Path = $p; Type = 'Folder' }
                $r = Backup-HMFolderItem $Ctx $Job $Module $fake $TEnv
                Write-HMLog $Job ("   Ordner {0}: {1} - {2}" -f $idx, $p, $r.Msg) $(if ($r.Status -eq 'OK') { 'Debug' } else { 'Warning' })
                $meta += [pscustomobject]@{ Index = $idx; Path = $p; Status = $r.Status }
                $bytes += $r.Bytes
                if ($r.Status -in @('Error', 'Cancel')) { $worst = $r.Status } elseif ($r.Status -eq 'Warning' -and $worst -eq 'OK') { $worst = 'Warning' }
            }
            $meta | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $dir 'folders.json') -Encoding UTF8
            return (& $res $worst "$($list.Count) Ordner, $(Format-HMSize $bytes)" $bytes)
        }

        'Wlan' {
            $r = Invoke-HMTarget $Ctx {
                param($clear)
                $svc = Get-Service WlanSvc -ErrorAction SilentlyContinue
                if (-not $svc -or $svc.Status -ne 'Running') { return 'NOWLAN' }
                $t = Join-Path $env:windir "Temp\HMwlan_$([guid]::NewGuid().ToString('N'))"
                New-Item -ItemType Directory -Path $t -Force | Out-Null
                if ($clear) { & netsh.exe wlan export profile "folder=$t" key=clear | Out-Null } else { & netsh.exe wlan export profile "folder=$t" | Out-Null }
                $t
            } @([bool]$Ctx.Settings.WlanExportClearKey)
            if ("$r" -eq 'NOWLAN') { return (& $res 'Skip' 'WLAN-Dienst laeuft nicht (kein WLAN-Adapter)') }
            $src = Convert-HMPath $Ctx "$r"
            $files = @(Get-ChildItem -LiteralPath $src -Filter *.xml -ErrorAction SilentlyContinue)
            foreach ($f in $files) { Copy-Item -LiteralPath $f.FullName -Destination $dir -Force }
            Remove-Item -LiteralPath $src -Recurse -Force -ErrorAction SilentlyContinue
            $hint = if ($Ctx.Settings.WlanExportClearKey) { ' (Schluessel im Klartext!)' } else { '' }
            return (& $res 'OK' "$($files.Count) Profile$hint")
        }

        'Shares' {
            $sh = @(Invoke-HMTarget $Ctx $script:HMShareReadScript)
            if (-not $sh.Count) { return (& $res 'Skip' 'keine Ordnerfreigaben') }
            $sh | Select-Object Name, Path, Description, FolderEnumerationMode, CachingMode, PathExists, Access, Ntfs, Sddl, Computer | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $dir 'shares.json') -Encoding UTF8
            $txt = foreach ($x in $sh) { "[$($x.Name)]  $($x.Path)"; "   Freigabe: $(Format-HMShareAccess $x)"; "   NTFS:     $(Format-HMNtfsAccess $x)"; '' }
            @($txt) | Set-Content -LiteralPath (Join-Path $dir 'Freigaben.txt') -Encoding UTF8
            return (& $res 'OK' "$($sh.Count) Freigaben: $((@($sh | ForEach-Object { $_.Name })) -join ', ')")
        }

        'PrinterConnections' {
            if (-not $Ctx.HiveReady) { return (& $res 'Error' 'Benutzer-Registry nicht verfuegbar') }
            $r = Invoke-HMTarget $Ctx {
                param($s)
                $con = @()
                $base = "Registry::HKEY_USERS\$s\Printers\Connections"
                if (Test-Path -LiteralPath $base) {
                    $con = @(Get-ChildItem -LiteralPath $base -ErrorAction SilentlyContinue | ForEach-Object { $_.PSChildName -replace ',', '\' })
                }
                $def = $null
                try { $def = (Get-ItemProperty -LiteralPath "Registry::HKEY_USERS\$s\Software\Microsoft\Windows NT\CurrentVersion\Windows" -ErrorAction Stop).Device } catch { }
                if ($def) { $def = $def.Split(',')[0] }
                [pscustomobject]@{ Connections = $con; Default = $def }
            } @($Ctx.UserSid)
            $obj = [pscustomobject]@{ Connections = @($r.Connections); Default = $r.Default }
            $obj | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $dir 'printers.json') -Encoding UTF8
            return (& $res 'OK' ("{0} Drucker{1}" -f @($r.Connections).Count, $(if ($r.Default) { ", Standard: $($r.Default)" } else { '' })))
        }

        'PrintersFull' {
            $r = Invoke-HMTarget $Ctx {
                $exe = Join-Path $env:windir 'System32\spool\tools\PrintBrm.exe'
                if (-not (Test-Path $exe)) { return 'FEHLER: PrintBrm.exe nicht vorhanden' }
                $f = Join-Path $env:windir "Temp\HMprn_$([guid]::NewGuid().ToString('N')).printerExport"
                $o = & $exe -b -f "$f" 2>&1
                if (-not (Test-Path $f)) { return "FEHLER: $($o -join ' ')" }
                $f
            }
            if ("$r" -like 'FEHLER*') { return (& $res 'Error' "$r") }
            $src = Convert-HMPath $Ctx "$r"
            $out = Join-Path $dir 'Printers.printerExport'
            Copy-Item -LiteralPath $src -Destination $out -Force
            Remove-Item -LiteralPath $src -Force -ErrorAction SilentlyContinue
            return (& $res 'OK' "PrintBrm-Export $(Format-HMSize (Get-Item -LiteralPath $out).Length)" (Get-Item -LiteralPath $out).Length)
        }

        'Fonts' {
            $map = Invoke-HMTarget $Ctx {
                $k = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
                $p = Get-ItemProperty -LiteralPath $k
                foreach ($n in $p.PSObject.Properties) {
                    if ($n.Name -like 'PS*') { continue }
                    [pscustomobject]@{ Name = $n.Name; File = [string]$n.Value }
                }
            }
            @($map) | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $dir 'fonts.json') -Encoding UTF8
            $src = Convert-HMPath $Ctx (Join-Path $TEnv.WINDIR 'Fonts')
            $rc = Invoke-HMRobocopy -Job $Job -Source $src -Dest (Join-Path $dir 'FONTS') -Files @('*.ttf', '*.ttc', '*.otf', '*.fon', '*.pfm', '*.pfb') -NoRecurse -Threads $Ctx.Threads -LogFile $Ctx.RoboLog
            $st = if ($rc.Level -eq 'OK') { 'OK' } elseif ($rc.Level -eq 'Warning') { 'Warning' } elseif ($rc.Level -eq 'Cancel') { 'Cancel' } else { 'Error' }
            return (& $res $st "$($rc.FilesTotal) Schriftdateien, $(Format-HMSize $rc.BytesTotal)" $rc.BytesTotal)
        }

        'Tasks' {
            $tasks = Invoke-HMTarget $Ctx {
                foreach ($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskPath -notlike '\Microsoft\*' -and $_.TaskName -notlike 'HUMig_*' })) {
                    try { [pscustomobject]@{ Path = $t.TaskPath; Name = $t.TaskName; Xml = (Export-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath) } } catch { }
                }
            }
            $idx = @()
            foreach ($t in @($tasks)) {
                $fn = (ConvertTo-HMSafeName ("$($t.Path)$($t.Name)")) + '.xml'
                Set-Content -LiteralPath (Join-Path $dir $fn) -Value $t.Xml -Encoding Unicode
                $idx += [pscustomobject]@{ Path = $t.Path; Name = $t.Name; File = $fn }
            }
            $idx | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $dir 'tasks.json') -Encoding UTF8
            return (& $res 'OK' "$($idx.Count) Aufgaben")
        }

        'Drivers' {
            $r = Invoke-HMTarget $Ctx {
                $t = Join-Path $env:windir "Temp\HMdrv_$([guid]::NewGuid().ToString('N'))"
                New-Item -ItemType Directory -Path $t -Force | Out-Null
                try {
                    $d = @(Export-WindowsDriver -Online -Destination $t -ErrorAction Stop)
                    $d | Select-Object Driver, OriginalFileName, ClassName, ProviderName, Date, Version | Format-List | Out-String -Width 250 | Set-Content -LiteralPath (Join-Path $t '_DriverInfo.txt') -Encoding UTF8
                    "OK|$t|$($d.Count)"
                } catch { "FEHLER: $($_.Exception.Message)" }
            }
            if ("$r" -notlike 'OK|*') { return (& $res 'Error' "$r") }
            $parts = "$r".Split('|')
            $src = Convert-HMPath $Ctx $parts[1]
            $rc = Invoke-HMRobocopy -Job $Job -Source $src -Dest (Join-Path $dir 'DRIVERS') -Threads $Ctx.Threads -LogFile $Ctx.RoboLog
            Remove-Item -LiteralPath $src -Recurse -Force -ErrorAction SilentlyContinue
            return (& $res $(if ($rc.Level -in @('OK', 'Warning')) { 'OK' } else { 'Error' }) "$($parts[2]) Treiber, $(Format-HMSize $rc.BytesTotal)" $rc.BytesTotal)
        }

        'Info' {
            $info = Invoke-HMTarget $Ctx {
                param($s)
                $sw = foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall', "Registry::HKEY_USERS\$s\Software\Microsoft\Windows\CurrentVersion\Uninstall")) {
                    foreach ($k in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
                        $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
                        if ($p.DisplayName -and $p.SystemComponent -ne 1 -and -not $p.ParentKeyName) {
                            [pscustomobject]@{ Name = $p.DisplayName; Version = $p.DisplayVersion; Publisher = $p.Publisher; InstallDate = $p.InstallDate; Scope = $(if ($root -like '*HKEY_USERS*') { 'Benutzer' } else { 'Computer' }) }
                        }
                    }
                }
                $admins = @()
                try { $admins = @(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop | ForEach-Object { $_.Name }) } catch {
                    try { $g = [ADSI]("WinNT://$env:COMPUTERNAME/" + (New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')).Translate([System.Security.Principal.NTAccount]).Value.Split('\')[1] + ',group')
                        $admins = @($g.Invoke('Members') | ForEach-Object { $_.GetType().InvokeMember('AdsPath', 'GetProperty', $null, $_, $null) -replace '^WinNT://', '' -replace '/', '\' }) } catch { }
                }
                $net = foreach ($c in @(Get-NetIPConfiguration -ErrorAction SilentlyContinue | Where-Object { $_.IPv4Address })) {
                    $dhcp = $null; try { $dhcp = (Get-NetIPInterface -InterfaceIndex $c.InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop).Dhcp } catch { }
                    [pscustomobject]@{ Adapter = $c.InterfaceAlias; IPv4 = ($c.IPv4Address.IPAddress -join ', '); Prefix = ($c.IPv4Address.PrefixLength -join ', ')
                        Gateway = ($c.IPv4DefaultGateway.NextHop -join ', '); DNS = ($c.DNSServer | Where-Object { $_.AddressFamily -eq 2 } | ForEach-Object { $_.ServerAddresses }) -join ', '
                        DHCP = "$dhcp"; MAC = $c.NetAdapter.MacAddress }
                }
                $groups = @()
                try {
                    $ds = New-Object System.DirectoryServices.DirectorySearcher("(&(objectCategory=computer)(sAMAccountName=$env:COMPUTERNAME`$))")
                    [void]$ds.PropertiesToLoad.Add('memberof')
                    $one = $ds.FindOne()
                    if ($one) { $groups = @($one.Properties['memberof'] | ForEach-Object { ($_ -split ',')[0] -replace '^CN=' }) }
                } catch { }
                $os = Get-CimInstance Win32_OperatingSystem
                $cs = Get-CimInstance Win32_ComputerSystem
                $prod = Get-CimInstance Win32_ComputerSystemProduct -ErrorAction SilentlyContinue
                $bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue
                [pscustomobject]@{
                    Software = @($sw | Sort-Object Name -Unique); Admins = $admins; Network = @($net); AdGroups = $groups
                    Env = @(Get-ChildItem Env: | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" })
                    OS = "$($os.Caption) $($os.Version) ($($os.OSArchitecture))"; OSVersion = $os.Version
                    Model = "$($cs.Manufacturer) $($prod.Version) $($cs.Model)".Trim(); Serial = $bios.SerialNumber; Domain = $cs.Domain
                }
            } @($Ctx.UserSid)
            @($info.Software) | Select-Object Name, Version, Publisher, InstallDate, Scope | Format-Table -AutoSize | Out-String -Width 300 | Set-Content -LiteralPath (Join-Path $dir '01-Software.txt') -Encoding UTF8
            @($info.Software) | Select-Object Name, Version, Publisher, InstallDate, Scope | Export-Csv -LiteralPath (Join-Path $dir '01-Software.csv') -NoTypeInformation -Delimiter ';' -Encoding UTF8
            @($info.Admins) | Set-Content -LiteralPath (Join-Path $dir '02-Administratoren.txt') -Encoding UTF8
            @($info.Env) | Set-Content -LiteralPath (Join-Path $dir '03-Umgebungsvariablen.txt') -Encoding UTF8
            @($info.AdGroups) | Set-Content -LiteralPath (Join-Path $dir '04-Computer-AD-Gruppen.txt') -Encoding UTF8
            @($info.Network) | Format-List | Out-String -Width 250 | Set-Content -LiteralPath (Join-Path $dir '05-Netzwerk.txt') -Encoding UTF8
            $Ctx.Manifest.Network = @($info.Network)
            $Ctx.Manifest.SourceOS = $info.OS
            $Ctx.Manifest.SourceOSVersion = $info.OSVersion
            $Ctx.Manifest.SourceModel = $info.Model
            $Ctx.Manifest.SourceSerial = $info.Serial
            $Ctx.Manifest.SourceDomain = $info.Domain
            return (& $res 'OK' "$(@($info.Software).Count) Programme, $(@($info.Admins).Count) Admins, $(@($info.Network).Count) Netzwerkadapter")
        }

        'Wallpaper' {
            if (-not $Ctx.HiveReady) { return (& $res 'Skip' 'Benutzer-Registry nicht verfuegbar') }
            $wp = Invoke-HMTarget $Ctx { param($s) try { (Get-ItemProperty -LiteralPath "Registry::HKEY_USERS\$s\Control Panel\Desktop" -ErrorAction Stop).WallPaper } catch { $null } } @($Ctx.UserSid)
            if (-not $wp) { return (& $res 'Skip' 'kein Hintergrundbild gesetzt') }
            $src = Convert-HMPath $Ctx "$wp"
            if (-not (Test-Path -LiteralPath $src)) { return (& $res 'Skip' "Bilddatei nicht gefunden: $wp") }
            $wdir = Join-Path $dir 'WALLPAPER_FILE'
            New-Item -ItemType Directory -Path $wdir -Force | Out-Null
            Copy-Item -LiteralPath $src -Destination $wdir -Force
            @{ Original = "$wp"; File = (Split-Path $wp -Leaf) } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $wdir 'wallpaper.json') -Encoding UTF8
            return (& $res 'OK' "Hintergrundbild: $(Split-Path $wp -Leaf)")
        }

        'Usmt' {
            return (Backup-HMUsmt $Ctx $Job $Module)
        }

        default { return (& $res 'Error' "Unbekannter Handler: $($Item.Handler)") }
    }
}

# --- USMT ---
# Bekannte Windows-Fehlercodes beim Start von ScanState/LoadState verstaendlich machen
function Get-HMUsmtCodeText([int]$Code, [string]$Version) {
    switch ($Code) {
        -1073741511 { return " = Einsprungpunkt nicht gefunden: diese USMT-Version passt nicht zum Windows des PCs$(if ($Version) { " (USMT $Version)" }). USMT aus dem ADK 10.1.26100.x verwenden (Werkzeuge > USMT einrichten)" }
        -1073741515 { return ' = DLL fehlt: USMT-Ordner unvollstaendig - neu einrichten (Werkzeuge > USMT einrichten)' }
        -1073741701 { return ' = falsche Architektur (amd64/arm64/x86 passt nicht zum PC)' }
        default { return '' }
    }
}

function Find-HMUsmt([hashtable]$Ctx) {
    $cands = @()
    if ($Ctx.Settings.UsmtPath) { $cands += $Ctx.Settings.UsmtPath }
    $cands += @(
        (Join-Path $Ctx.ToolRoot 'BIN\USMT\amd64'), (Join-Path $Ctx.ToolRoot 'BIN\USMT'),
        "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\User State Migration Tool\amd64"
    )
    foreach ($c in $cands) { if ($c -and (Test-Path -LiteralPath (Join-Path $c 'scanstate.exe'))) { return $c } }
    return $null
}

function Get-HMUsmtXmlArgs([string]$XmlDir) {
    return @('MigSettingsOnly.xml', 'ExcludeUserFolders.xml', 'ExcludeSystemFolders.xml', 'ExcludeOtherDrives.xml') |
        ForEach-Object { '/i:"' + (Join-Path $XmlDir $_) + '"' }
}

function Backup-HMUsmt {
    param([hashtable]$Ctx, $Job, $Module)
    $usmt = Find-HMUsmt $Ctx
    if (-not $usmt) { return [pscustomobject]@{ Name = 'Usmt'; Status = 'Error'; Msg = 'USMT nicht gefunden (Einstellungen > USMT-Pfad oder BIN\USMT\amd64, Windows ADK)'; Bytes = 0; Source = '' } }
    if (-not $Ctx.Account) { return [pscustomobject]@{ Name = 'Usmt'; Status = 'Error'; Msg = 'Kontoname des Benutzers unbekannt (SID nicht aufloesbar)'; Bytes = 0; Source = '' } }
    $xmlDir = Join-Path $Ctx.ToolRoot 'Config\USMT'
    $store = Join-Path (Join-Path $Ctx.BackupPath $Module.Id) 'STORE'
    $uver = ''; try { $uver = (Get-Item -LiteralPath (Join-Path $usmt 'scanstate.exe')).VersionInfo.ProductVersion } catch { }
    Write-HMLog $Job "   USMT: $usmt$(if ($uver) { " (Version $uver)" })" 'Debug'
    $remoteDir = $null
    if ($Ctx.IsRemote) {
        # USMT + XML auf den Ziel-PC kopieren und dort ausfuehren
        $remoteDir = Join-Path (Invoke-HMTarget $Ctx { $env:windir }) "Temp\HMusmt_$([guid]::NewGuid().ToString('N'))"
        $rReach = Convert-HMPath $Ctx $remoteDir
        [void](Invoke-HMRobocopy -Job $Job -Source $usmt -Dest (Join-Path $rReach 'BIN') -Threads 16)
        [void](Invoke-HMRobocopy -Job $Job -Source $xmlDir -Dest (Join-Path $rReach 'XML') -Threads 4)
        $exeDir = Join-Path $remoteDir 'BIN'; $xDir = Join-Path $remoteDir 'XML'; $sDir = Join-Path $remoteDir 'STORE'
    } else {
        $exeDir = $usmt; $xDir = $xmlDir; $sDir = $store
    }
    $scanArgs = @('"' + $sDir + '"') + (Get-HMUsmtXmlArgs $xDir) + @('/o', '/c', '/localonly', '/vsc', '/efs:copyraw', '/ue:*\*', ('/ui:"' + $Ctx.Account + '"'), ('/l:"' + (Join-Path $sDir 'scanstate.log') + '"'), '/v:5')
    $r = Invoke-HMTarget $Ctx {
        param($exe, $argString, $sd)
        New-Item -ItemType Directory -Path $sd -Force | Out-Null
        $p = Start-Process -FilePath (Join-Path $exe 'scanstate.exe') -ArgumentList $argString -WorkingDirectory $exe -WindowStyle Hidden -Wait -PassThru
        $p.ExitCode
    } @($exeDir, ($scanArgs -join ' '), $sDir)
    $code = [int]"$r"
    if ($Ctx.IsRemote) {
        [void](Invoke-HMRobocopy -Job $Job -Source (Join-Path $rReach 'STORE') -Dest $store -Threads $Ctx.Threads -LogFile $Ctx.RoboLog)
        Remove-Item -LiteralPath $rReach -Recurse -Force -ErrorAction SilentlyContinue
    }
    $mig = Get-ChildItem -LiteralPath $store -Filter 'USMT.MIG' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($code -eq 0 -and $mig) { return [pscustomobject]@{ Name = 'Usmt'; Status = 'OK'; Msg = "ScanState OK, $(Format-HMSize $mig.Length)"; Bytes = $mig.Length; Source = $usmt } }
    $why = Get-HMUsmtCodeText $code $uver
    if ($mig) { return [pscustomobject]@{ Name = 'Usmt'; Status = 'Warning'; Msg = "ScanState Code $code$why (Details: $store\scanstate.log)"; Bytes = $mig.Length; Source = $usmt } }
    return [pscustomobject]@{ Name = 'Usmt'; Status = 'Error'; Msg = "ScanState Code $code$why, kein USMT.MIG (Log: $store\scanstate.log)"; Bytes = 0; Source = $usmt }
}

# ----------------------------------------------------------------------------
# Hauptablauf Backup
# ----------------------------------------------------------------------------
function Start-HMBackup {
    param([hashtable]$Ctx, $Job)
    $start = Get-Date
    $Ctx.IsRemote = -not (Test-HMIsLocal $Ctx.Computer)
    if (-not $Ctx.IsRemote) { $Ctx.Computer = $env:COMPUTERNAME }
    $Ctx.CopyMap = New-Object System.Collections.Generic.List[object]
    $Ctx.SyncRootLog = New-Object System.Collections.Generic.List[object]
    $Ctx.SyncRoots = @()
    $Ctx.ListOnly = $false
    $target = $Ctx.BackupPath

    # Inkrementell: vorhandenes Backup desselben Benutzers weiterfuehren (Robocopy kopiert nur Neues/Geaendertes)
    $prev = $null
    if ($Ctx.ExistingBackup -and (Test-Path -LiteralPath (Join-Path $Ctx.ExistingBackup 'manifest.json'))) {
        try { $prev = Get-Content -LiteralPath (Join-Path $Ctx.ExistingBackup 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $prev = $null }
        if ($prev) { $Ctx.BackupPath = $Ctx.ExistingBackup }
    }
    Write-HMLog $Job "BACKUP  $($Ctx.Computer) \ $($Ctx.UserFolder)  ->  $target" 'Header'
    if ($prev) { Write-HMLog $Job "Inkrementell: vorhandenes Backup vom $($prev.Created) wird aktualisiert (nur neue/geaenderte Dateien)" 'Info' }

    $shareRoot = $null
    $allBytes = [long]0
    $verify = $null
    try {
        if ($Ctx.IsRemote -and $Ctx.Credential) {
            $shareRoot = "\\$($Ctx.Computer)\C$"
            if (-not (Connect-HMShare $shareRoot $Ctx.Credential)) { Write-HMLog $Job "Verbindung zu $shareRoot mit den angegebenen Anmeldedaten fehlgeschlagen" 'Warning' }
        }
        # Hive laden (Registry-Module, Handler mit Benutzer-Registry, Profil-Modul fuer OneDrive-Erkennung)
        $needHive = @($Ctx.Modules | ForEach-Object { $_.Items } | Where-Object {
            ($_.Type -eq 'Reg' -and $_.Key -match '^HK(CU|EY_CURRENT_USER)') -or ($_.Type -eq 'Builtin' -and $_.Handler -in @('PrinterConnections', 'Wallpaper')) -or ($_.Exceptions -eq 'Profile') }).Count -gt 0
        $Ctx.HiveReady = $false
        if ($needHive) {
            try { $Ctx.HiveReady = Mount-HMHive $Ctx $Job $Ctx.UserSid $Ctx.ProfilePath } catch { Write-HMLog $Job "Registry des Benutzers nicht verfuegbar: $($_.Exception.Message)" 'Warning' }
        }
        $tenv = Get-HMTargetEnv $Ctx $Ctx.UserSid $Ctx.ProfilePath
        if ($tenv.APPDATA_REDIRECTED) { Write-HMLog $Job "Hinweis: AppData ist umgeleitet ($($tenv.APPDATA)) - wird von dort gesichert" 'Warning' }
        try { $Ctx.SyncRoots = @(Get-HMSyncRoots $Ctx $Ctx.UserSid $Ctx.ProfilePath) } catch { $Ctx.SyncRoots = @() }
        # Installierte Programme merken (Programm-Katalog, Nacharbeiten, Neuinstallation am neuen PC)
        $Ctx.SoftwareList = @(); $Ctx.AppsFound = @()
        if (Get-Command Get-HMInstalledSoftware -ErrorAction SilentlyContinue) {
            try {
                $swl = @(Get-HMInstalledSoftware $Ctx $Ctx.UserSid)
                $Ctx.SoftwareList = @($swl | Sort-Object Name | ForEach-Object { "$($_.Name)|$($_.Version)|$($_.Publisher)|$($_.Scope)" })
                $Ctx.AppsFound = @(Find-HMCatalogApps $swl @($Ctx.AppCatalog))
                if ($Ctx.AppsFound.Count) { Write-HMLog $Job ("Programme mit Katalog-Eintrag: {0}" -f (@($Ctx.AppsFound | ForEach-Object { $_.Name }) -join ', ')) 'Info' }
            } catch { Write-HMLog $Job "Programmliste nicht lesbar: $($_.Exception.Message)" 'Debug' }
        }
        if ($Ctx.SyncRoots.Count) {
            $mode = if ($Ctx.Options.OneDriveLocal) { 'nur lokal vorhandene Dateien werden gesichert (kein Download)' } else { 'werden ausgelassen (Inhalt liegt in der Cloud)' }
            Write-HMLog $Job "Cloud-Ordner (OneDrive/SharePoint) - $mode" 'Info'
            foreach ($r in $Ctx.SyncRoots) { Write-HMLog $Job "   $r" 'Debug' }
        }

        # ---- Platzbedarf pruefen (Robocopy-Simulation gegen das Ziel: zaehlt nur, was wirklich kopiert wuerde) ----
        if (-not $Ctx.Options.SkipSpaceCheck) {
            Write-HMLog $Job 'Platzbedarf wird ermittelt ...' 'Info'
            $need = [long]0
            $Ctx.ListOnly = $true
            try {
                foreach ($mod in $Ctx.Modules) {
                    foreach ($it in @($mod.Items)) {
                        if (Test-HMCancel $Job) { break }
                        $Job.Status = "Platzbedarf: $($mod.Name)"
                        if ($it.Type -in @('Folder', 'Files')) {
                            $r = Backup-HMFolderItem $Ctx $Job $mod $it $tenv
                            $need += [long]$r.BytesCopied
                        } elseif ($it.Type -eq 'Builtin' -and $it.Handler -eq 'ExtraFolders') {
                            $idx = 0
                            foreach ($p in @($Ctx.Options.ExtraFolders | Where-Object { $_ })) {
                                $idx++
                                $r = Backup-HMFolderItem $Ctx $Job $mod ([pscustomobject]@{ Name = "FOLDER$idx"; Path = $p; Type = 'Folder' }) $tenv
                                $need += [long]$r.BytesCopied
                            }
                        }
                    }
                }
            } finally { $Ctx.ListOnly = $false }
            if (@($Ctx.Modules | Where-Object { $_.Id -eq 'Drivers' }).Count) { $need += 2GB }
            if (@($Ctx.Modules | Where-Object { $_.Id -eq 'Usmt' }).Count) { $need += 500MB }
            $need = [long]($need * 1.05) + 200MB
            $free = Get-HMFreeSpace $Ctx.BackupPath
            $Ctx.SpaceCheck = [ordered]@{ NeedBytes = $need; FreeBytes = $free }
            if (Test-HMCancel $Job) { $Job.Result = [pscustomobject]@{ Status = 'Cancelled' }; return }
            if ($free -ge 0 -and $need -gt $free) {
                Write-HMLog $Job ("ZU WENIG PLATZ: benoetigt ca. {0}, frei {1} - Backup nicht gestartet" -f (Format-HMSize $need), (Format-HMSize $free)) 'Error'
                $Job.Result = [pscustomobject]@{ Status = 'NoSpace'; Need = $need; Free = $free }
                return
            }
            Write-HMLog $Job ("Platzbedarf ca. {0} (neu/geaendert), frei {1}" -f (Format-HMSize $need), $(if ($free -ge 0) { Format-HMSize $free } else { 'unbekannt' })) 'Success'
        }

        # ---- Backup-Ordner vorbereiten ----
        if ($prev -and $Ctx.BackupPath.TrimEnd('\') -ne $target.TrimEnd('\')) {
            try { Rename-Item -LiteralPath $Ctx.BackupPath -NewName (Split-Path $target -Leaf) -ErrorAction Stop; $Ctx.BackupPath = $target }
            catch { Write-HMLog $Job "Backup-Ordner konnte nicht umbenannt werden ($($_.Exception.Message)) - alter Name bleibt" 'Warning' }
        }
        New-Item -ItemType Directory -Path $Ctx.BackupPath -Force | Out-Null
        $Job.LogFile = Join-Path $Ctx.BackupPath 'HUMig.log'
        $Ctx.RoboLog = Join-Path $Ctx.BackupPath 'Robocopy.log'
        try {
            Add-Content -LiteralPath $Ctx.RoboLog -Encoding UTF8 -Value @(
                "HUMig $($Ctx.ToolVersion) - Robocopy-Protokoll, Backup $($start.ToString('dd.MM.yyyy HH:mm'))",
                'Hinweis zur Spalte "Uebersprungen"/"Skipped": enthaelt absichtlich ausgeschlossene Dateien (versteckte/System-Dateien wie pagefile.sys,',
                'Nur-Cloud-Platzhalter, Ausschlussmuster) sowie beim Ergaenzen eines vorhandenen Backups unveraenderte Dateien. Das ist kein Fehler.',
                'Fehler stehen in der Spalte "Fehler"/"FAILED" und im HUMig.log.', '')
        } catch { }
        Write-HMLog $Job "BACKUP gestartet: $($Ctx.Computer) \ $($Ctx.UserFolder) -> $($Ctx.BackupPath)" 'Debug'

        $firstCreated = $start.ToString('yyyy-MM-dd HH:mm:ss'); $incs = @()
        if ($prev) {
            $firstCreated = if ($prev.FirstCreated) { "$($prev.FirstCreated)" } else { "$($prev.Created)" }
            $incs = @(@($prev.Increments) + @("$($prev.Created)") | Where-Object { $_ })
        }
        $Ctx.Manifest = [ordered]@{
            Tool = 'HUMig'; ToolVersion = $Ctx.ToolVersion; Format = 1; Created = $start.ToString('yyyy-MM-dd HH:mm:ss'); Finished = $null
            FirstCreated = $firstCreated; Increments = $incs; Incremental = [bool]$prev
            SourceComputer = $Ctx.Computer; Remote = $Ctx.IsRemote; CreatedBy = "$env:USERDOMAIN\$env:USERNAME"; CreatedOn = $env:COMPUTERNAME
            UserName = $Ctx.UserFolder; Account = $Ctx.Account; UserSid = $Ctx.UserSid; ProfilePath = $Ctx.ProfilePath
            SourceOS = $(if ($prev) { $prev.SourceOS }); SourceOSVersion = $(if ($prev) { $prev.SourceOSVersion }); SourceModel = $(if ($prev) { $prev.SourceModel })
            SourceSerial = $(if ($prev) { $prev.SourceSerial }); SourceDomain = $(if ($prev) { $prev.SourceDomain })
            Network = $(if ($prev) { @($prev.Network) } else { @() }); ExtraFolders = @($Ctx.Options.ExtraFolders); ExcludePaths = @($Ctx.Options.ExcludePaths)
            OneDriveMode = $(if ($Ctx.Options.OneDriveLocal) { 'Local' } else { 'Skip' }); SyncRoots = @(); SpaceCheck = $Ctx.SpaceCheck; Verify = $null
            Status = 'Running'; SizeBytes = 0; Duration = $null; Modules = @()
            Software = $(if (@($Ctx.SoftwareList).Count) { @($Ctx.SoftwareList) } elseif ($prev -and $prev.Software) { @($prev.Software) } else { @() })
            Apps = $(if (@($Ctx.SoftwareList).Count) { @($Ctx.AppsFound) } elseif ($prev -and $prev.Apps) { @($prev.Apps) } else { @() })
        }
        Save-HMManifest $Ctx.Manifest $Ctx.BackupPath

        $total = @($Ctx.Modules | ForEach-Object { @($_.Items).Count } | Measure-Object -Sum).Sum
        if (-not $total) { $total = 1 }
        $done = 0
        foreach ($mod in $Ctx.Modules) {
            if (Test-HMCancel $Job) { break }
            Write-HMLog $Job $mod.Name 'Info'
            $Job.Status = $mod.Name
            $mres = [ordered]@{ Id = $mod.Id; Name = $mod.Name; Status = 'OK'; Bytes = [long]0; Items = @() }
            foreach ($it in @($mod.Items)) {
                if (Test-HMCancel $Job) { break }
                try {
                    $r = switch ($it.Type) {
                        'Folder'  { Backup-HMFolderItem $Ctx $Job $mod $it $tenv }
                        'Files'   { Backup-HMFolderItem $Ctx $Job $mod $it $tenv }
                        'Reg'     { Backup-HMRegItem $Ctx $Job $mod $it }
                        'Builtin' { Backup-HMBuiltin $Ctx $Job $mod $it $tenv }
                        default   { [pscustomobject]@{ Name = $it.Name; Status = 'Error'; Msg = "Unbekannter Typ $($it.Type)"; Bytes = 0; Source = '' } }
                    }
                } catch {
                    $r = [pscustomobject]@{ Name = "$($it.Name)$($it.Handler)"; Status = 'Error'; Msg = $_.Exception.Message; Bytes = 0; Source = '' }
                }
                $lvl = switch ($r.Status) { 'OK' { 'Success' } 'Skip' { 'Debug' } 'Warning' { 'Warning' } default { 'Error' } }
                Write-HMLog $Job ("   {0}: {1}" -f $r.Name, $r.Msg) $lvl
                $mres.Items += [pscustomobject]@{ Name = $r.Name; Status = $r.Status; Msg = $r.Msg; Bytes = [long]$r.Bytes; Source = $r.Source }
                $mres.Bytes += [long]$r.Bytes
                if ($r.Status -in @('Error', 'Cancel')) { $mres.Status = 'Error' } elseif ($r.Status -eq 'Warning' -and $mres.Status -eq 'OK') { $mres.Status = 'Warning' }
                $done++
                $Job.Progress = [int](95 * $done / $total)
            }
            if (@($mres.Items | Where-Object { $_.Status -ne 'Skip' }).Count -eq 0) { $mres.Status = 'Skip' }
            $allBytes += $mres.Bytes
            $Ctx.Manifest.Modules += [pscustomobject]$mres
            $Ctx.Manifest.SyncRoots = $Ctx.SyncRootLog.ToArray()
            Save-HMManifest $Ctx.Manifest $Ctx.BackupPath
        }
        # Module aus frueheren Durchlaeufen, die diesmal nicht gewaehlt waren, bleiben im Backup erhalten
        if ($prev) {
            $now = @($Ctx.Manifest.Modules | ForEach-Object { $_.Id })
            foreach ($pm in @($prev.Modules | Where-Object { $_ -and $now -notcontains $_.Id })) {
                $pm | Add-Member -NotePropertyName FromPrevious -NotePropertyValue "$($prev.Created)" -Force
                $Ctx.Manifest.Modules += $pm
                $allBytes += [long]$pm.Bytes
            }
            $keep = @(foreach ($p0 in @($prev.SyncRoots | Where-Object { $_ })) {
                if (-not @($Ctx.SyncRootLog | Where-Object { $_.Item -eq $p0.Item -and $_.Rel -eq $p0.Rel }).Count) { $p0 }
            })
            $Ctx.Manifest.SyncRoots = @($Ctx.SyncRootLog.ToArray()) + @($keep)
        }

        # OneDrive-Hinweis (bekannte Ordner in OneDrive umgeleitet)
        if ($Ctx.HiveReady) {
            $od = Invoke-HMTarget $Ctx {
                param($s, $pp)
                $usf = "Registry::HKEY_USERS\$s\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
                $k = Get-Item -LiteralPath $usf -ErrorAction SilentlyContinue
                $names = @{ 'Desktop' = 'Desktop'; 'Personal' = 'Dokumente'; 'My Pictures' = 'Bilder'; '{374DE290-123F-4565-9164-39C4925E467B}' = 'Downloads' }
                $hit = foreach ($n in $names.Keys) {
                    $v = if ($k) { [string]$k.GetValue($n, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) } else { '' }
                    if ($v -and $v -match 'OneDrive') { "$($names[$n]) -> $([regex]::Replace($v, '%USERPROFILE%', $pp.Replace('$', '$$'), 'IgnoreCase'))" }
                }
                @($hit)
            } @($Ctx.UserSid, $Ctx.ProfilePath)
            if (@($od).Count) {
                $how = if ($Ctx.Options.OneDriveLocal) { 'lokal vorhandene Dateien sind gesichert' } else { 'werden ueber die Cloud synchronisiert, nicht im Backup' }
                Write-HMLog $Job "OneDrive: bekannte Ordner liegen in OneDrive ($how):" 'Warning'
                foreach ($l in @($od)) { Write-HMLog $Job "   $l" 'Warning' }
                $Ctx.Manifest.OneDriveFolders = @($od)
            }
        }

        # ---- Pruefung ----
        if ($Ctx.Options.Verify -and -not (Test-HMCancel $Job) -and $Ctx.CopyMap.Count) {
            Write-HMLog $Job 'Pruefung des Backups (Vergleich + Pruefsummen-Stichprobe) ...' 'Info'
            $Job.Progress = 96
            $n = 30
            if ($Ctx.Settings.Backup -and [int]$Ctx.Settings.Backup.VerifySamples -gt 0) { $n = [int]$Ctx.Settings.Backup.VerifySamples }
            try {
                $verify = Test-HMBackupIntegrity $Ctx $Job $Ctx.CopyMap $n
                $Ctx.Manifest.Verify = $verify
                Write-HMLog $Job ("   Pruefsummen: {0} Dateien verglichen, {1} Abweichung(en)" -f $verify.Sampled, @($verify.HashMismatch).Count) $(if (@($verify.HashMismatch).Count) { 'Warning' } else { 'Success' })
                foreach ($b in @($verify.HashMismatch | Select-Object -First 10)) { Write-HMLog $Job "      ABWEICHUNG: $b" 'Warning' }
                if ($verify.DiffFiles) { Write-HMLog $Job ("   Seit dem Kopieren neu/geaendert: {0} Dateien ({1}) - normal, wenn der Benutzer angemeldet ist" -f $verify.DiffFiles, (Format-HMSize $verify.DiffBytes)) 'Info' }
                else { Write-HMLog $Job '   Vergleich: Backup ist vollstaendig (keine fehlenden/abweichenden Dateien)' 'Success' }
            } catch { Write-HMLog $Job "   Pruefung fehlgeschlagen: $($_.Exception.Message)" 'Warning' }
        }

        # ---- Pruefsummen-Katalog (spaetere Pruefung des Backups moeglich) ----
        if ($Ctx.Options.Catalog -and -not (Test-HMCancel $Job) -and (Get-Command Update-HMChecksumCatalog -ErrorAction SilentlyContinue)) {
            Write-HMLog $Job 'Pruefsummen-Katalog (SHA-256) wird erstellt ...' 'Info'
            $Job.Progress = 98
            try {
                $cat = Update-HMChecksumCatalog $Ctx.BackupPath $Job
                if (-not $cat -and (Test-HMCancel $Job)) {
                    # Abbruch nur im Katalog: das Backup selbst ist vollstaendig -> nicht als abgebrochen werten
                    $Job.Cancel = $false
                    Write-HMLog $Job '   Katalog abgebrochen - das Backup selbst ist vollstaendig (Katalog spaeter: Reiter Restore, Rechtsklick auf "Backup pruefen")' 'Warning'
                }
                if ($cat) {
                    $Ctx.Manifest.Catalog = $cat
                    Write-HMLog $Job ("   Katalog: {0} Dateien, {1} ({2} neu berechnet{3})" -f $cat.Files, (Format-HMSize $cat.Bytes), $cat.Hashed, $(if ($cat.Errors) { ", $($cat.Errors) nicht lesbar" })) $(if ($cat.Errors) { 'Warning' } else { 'Success' })
                }
            } catch { Write-HMLog $Job "   Katalog fehlgeschlagen: $($_.Exception.Message)" 'Warning' }
        }
    } finally {
        try { Dismount-HMHive $Ctx $Job } catch { }
        if ($shareRoot) { Disconnect-HMShare $shareRoot }
    }

    $dur = (Get-Date) - $start
    $Ctx.Manifest.Finished = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $Ctx.Manifest.Duration = $dur.ToString('hh\:mm\:ss')
    $Ctx.Manifest.SizeBytes = $allBytes
    $errs = @($Ctx.Manifest.Modules | Where-Object { $_.Status -eq 'Error' -and -not $_.FromPrevious }).Count
    $warns = @($Ctx.Manifest.Modules | Where-Object { $_.Status -eq 'Warning' -and -not $_.FromPrevious }).Count
    if ($verify -and $verify.Status -ne 'OK') { $warns++ }
    $Ctx.Manifest.Status = if (Test-HMCancel $Job) { 'Cancelled' } elseif ($errs) { 'Error' } elseif ($warns) { 'Warning' } else { 'OK' }
    Save-HMManifest $Ctx.Manifest $Ctx.BackupPath
    $Job.Progress = 100
    $sumLvl = switch ($Ctx.Manifest.Status) { 'OK' { 'Success' } 'Warning' { 'Warning' } default { 'Error' } }
    Write-HMLog $Job ("BACKUP {0}: {1} in {2} - Fehler: {3}, Warnungen: {4}" -f $Ctx.Manifest.Status, (Format-HMSize $allBytes), $Ctx.Manifest.Duration, $errs, $warns) $sumLvl

    # ---- Protokoll ----
    $m = $Ctx.Manifest
    $facts = [ordered]@{
        'Computer (Quelle)' = $m.SourceComputer; 'Benutzer' = $m.UserName; 'Konto' = $m.Account; 'Profilpfad' = $m.ProfilePath
        'Backup-Ordner' = $Ctx.BackupPath; 'Gestartet' = $m.Created; 'Beendet' = $m.Finished; 'Dauer' = $m.Duration; 'Groesse' = (Format-HMSize $allBytes)
        'Inkrementell' = $(if ($m.Incremental) { "ja - erstes Backup $($m.FirstCreated), $(@($m.Increments).Count + 1). Durchlauf" } else { '' })
        'Betriebssystem' = $m.SourceOS; 'Modell' = $m.SourceModel; 'Seriennummer' = $m.SourceSerial; 'Domaene' = $m.SourceDomain
        'Cloud-Ordner' = $(if (@($m.SyncRoots).Count) { (@($m.SyncRoots | ForEach-Object { "$($_.Path) ($(if ($_.Mode -eq 'Local') { 'lokale Dateien gesichert' } else { 'ausgelassen' }))" }) -join '; ') } else { '' })
        'Pruefung' = $(if ($verify) { "$($verify.Sampled) Dateien per Pruefsumme verglichen, $(@($verify.HashMismatch).Count) Abweichung(en)" } else { '' })
        'Pruefsummen-Katalog' = $(if ($m.Catalog) { "$($m.Catalog.Files) Dateien (SHA-256) - spaeter pruefbar: Reiter Restore > Backup pruefen" } else { '' })
        'Erstellt von' = "$($m.CreatedBy) an $($m.CreatedOn)"
    }
    $notes = @()
    if ($m.OneDriveFolders) { $notes += 'Bekannte Ordner (Desktop/Dokumente/Bilder) liegen in OneDrive: ' + (@($m.OneDriveFolders) -join '; ') }
    if ($verify -and @($verify.HashMismatch).Count) { $notes += 'Pruefsummen-Abweichung: ' + (@($verify.HashMismatch | Select-Object -First 10) -join '; ') }
    foreach ($mm in @($m.Modules | Where-Object { $_.FromPrevious })) { $notes += "Modul '$($mm.Name)' stammt aus dem Durchlauf vom $($mm.FromPrevious)" }
    [void](New-HMReport -Ctx $Ctx -Kind Backup -OutFile (Join-Path $Ctx.BackupPath 'Bericht_Backup.html') -Modules @($m.Modules) -Facts $facts -Notes $notes -Status $m.Status)
    $Job.Result = $Ctx.Manifest
}

# ============================================================================
# GROESSE ERMITTELN (Robocopy /L - kopiert nichts)
# ============================================================================
function Measure-HMBackup {
    param([hashtable]$Ctx, $Job)
    $Ctx.IsRemote = -not (Test-HMIsLocal $Ctx.Computer)
    if (-not $Ctx.IsRemote) { $Ctx.Computer = $env:COMPUTERNAME }
    $Ctx.ListOnly = $true
    $Ctx.MeasureStats = New-HMStats
    $Ctx.SyncRoots = @()
    # Leeres Temp-Ziel: Robocopy listet dann alle Dateien (fuer Summen und "Grosse Dateien")
    $Ctx.BackupPath = Join-Path $env:TEMP "HMmeasure_$([guid]::NewGuid().ToString('N'))"
    Write-HMLog $Job "GROESSE  $($Ctx.Computer) \ $($Ctx.UserFolder) (nur Dateien, mit Ausnahmen)" 'Header'
    $shareRoot = $null
    $perMod = @{}
    $sum = [long]0
    try {
        if ($Ctx.IsRemote -and $Ctx.Credential) { $shareRoot = "\\$($Ctx.Computer)\C$"; [void](Connect-HMShare $shareRoot $Ctx.Credential) }
        $Ctx.HiveReady = $false
        if (@($Ctx.Modules | ForEach-Object { $_.Items } | Where-Object { $_.Exceptions -eq 'Profile' }).Count) {
            try { $Ctx.HiveReady = Mount-HMHive $Ctx $Job $Ctx.UserSid $Ctx.ProfilePath } catch { }
        }
        $tenv = Get-HMTargetEnv $Ctx $Ctx.UserSid $Ctx.ProfilePath
        try { $Ctx.SyncRoots = @(Get-HMSyncRoots $Ctx $Ctx.UserSid $Ctx.ProfilePath) } catch { }
        if ($Ctx.SyncRoots.Count) {
            Write-HMLog $Job ("Cloud-Ordner: {0} - {1}" -f (@($Ctx.SyncRoots | ForEach-Object { Split-Path $_ -Leaf }) -join ', '), $(if ($Ctx.Options.OneDriveLocal) { 'lokal vorhandene Dateien mitgezaehlt' } else { 'nicht mitgezaehlt (werden ausgelassen)' })) 'Info'
        }
        $items = @(foreach ($m in $Ctx.Modules) { foreach ($it in @($m.Items)) { if ($it.Type -in @('Folder', 'Files')) { [pscustomobject]@{ M = $m; I = $it } } } })
        if (@($Ctx.Modules | Where-Object { $_.Id -eq 'ExtraFolders' }).Count) {
            $mx = @($Ctx.Modules | Where-Object { $_.Id -eq 'ExtraFolders' })[0]
            $idx = 0
            foreach ($p in @($Ctx.Options.ExtraFolders | Where-Object { $_ })) { $idx++; $items += [pscustomobject]@{ M = $mx; I = [pscustomobject]@{ Name = "FOLDER$idx"; Type = 'Folder'; Path = $p } } }
        }
        $n = 0
        foreach ($x in $items) {
            if (Test-HMCancel $Job) { break }
            $n++; $Job.Progress = [int](100 * $n / [Math]::Max(1, $items.Count)); $Job.Status = $x.M.Name
            $r = Backup-HMFolderItem $Ctx $Job $x.M $x.I $tenv
            if ($r.Status -ne 'Skip') {
                Write-HMLog $Job ("   {0} / {1}: {2}" -f $x.M.Name, $x.I.Name, $r.Msg) 'Info'
                $sum += [long]$r.Bytes
                if ($perMod.ContainsKey($x.M.Id)) { $perMod[$x.M.Id] += [long]$r.Bytes } else { $perMod[$x.M.Id] = [long]$r.Bytes }
            } elseif (-not $perMod.ContainsKey($x.M.Id)) { $perMod[$x.M.Id] = [long]0 }
        }
        # Module ohne Datei-Eintraege (nur Registry/Spezial) -> 0 (vernachlaessigbar bzw. nicht schaetzbar)
        foreach ($m in $Ctx.Modules) { if (-not $perMod.ContainsKey($m.Id)) { $perMod[$m.Id] = [long]-1 } }
        Write-HMLog $Job "Summe: $(Format-HMSize $sum) (ohne Registry, USMT, Treiber, Schriftarten)" 'Success'
    } finally {
        try { Dismount-HMHive $Ctx $Job } catch { }
        if ($shareRoot) { Disconnect-HMShare $shareRoot }
        Remove-Item -LiteralPath $Ctx.BackupPath -Recurse -Force -ErrorAction SilentlyContinue
    }
    $st = $Ctx.MeasureStats
    $top = @($st.Files | Sort-Object Size -Descending | Select-Object -First 100 | ForEach-Object { [pscustomobject]@{ Kind = 'Datei'; Size = $_.Size; Path = (ConvertFrom-HMPath $_.Path); Module = $_.Module } })
    $fold = @($st.Folders.Values | Sort-Object Size -Descending | Select-Object -First 100 | ForEach-Object { [pscustomobject]@{ Kind = 'Ordner'; Size = $_.Size; Path = (ConvertFrom-HMPath $_.Path); Module = $_.Module } })
    $Job.Result = [pscustomobject]@{ Total = $sum; Modules = $perMod; Top = @($fold + $top); Computer = $Ctx.Computer; Sid = $Ctx.UserSid; Cancelled = [bool](Test-HMCancel $Job) }
}

# ============================================================================
# RESTORE
# ============================================================================
function Get-HMRestoreSource {
    param([hashtable]$Ctx, $Module, $Item)
    if ($Ctx.Backup.Legacy) {
        if (-not $Item.Legacy) { return $null }
        return (Join-Path $Ctx.Backup.Path $Item.Legacy)
    }
    if ($Item.Type -eq 'Reg') { return (Join-Path (Join-Path $Ctx.Backup.Path $Module.Id) "$($Item.Name).reg") }
    if ($Item.Type -eq 'Builtin') { return (Join-Path $Ctx.Backup.Path $Module.Id) }
    return (Get-HMItemTargetPath $Ctx.Backup.Path $Module $Item)
}

function Restore-HMFolderItem {
    param([hashtable]$Ctx, $Job, $Module, $Item, [hashtable]$TEnv, [string]$SourceOverride, [string]$DestOverride)
    $src = if ($SourceOverride) { $SourceOverride } else { Get-HMRestoreSource $Ctx $Module $Item }
    if (-not $src -or -not (Test-Path -LiteralPath $src)) { return [pscustomobject]@{ Name = $Item.Name; Status = 'Skip'; Msg = 'nicht im Backup' } }
    $dstLocal = if ($DestOverride) { $DestOverride } else { Resolve-HMToken $TEnv $Item.Path }
    $dst = Convert-HMPath $Ctx $dstLocal
    $files = @(); $noRec = $false
    if ($Item.Type -eq 'Files') { $files = @($Item.Filter); $noRec = $true }
    # Cloud-Ordner (OneDrive/SharePoint) aus dem Backup nie direkt in den Sync-Ordner schreiben (wuerde neuere Cloud-Versionen ueberschreiben)
    $xd = @(); $syncs = @()
    $mf = if ($Ctx.Backup) { $Ctx.Backup.Manifest } else { $null }
    if (-not $SourceOverride -and $mf -and $mf.SyncRoots) {
        $syncs = @($mf.SyncRoots | Where-Object { $_ -and $_.Rel -and $_.Item -eq "$($Module.Id)/$($Item.Name)" })
        foreach ($s in $syncs) { $xd += (Join-Path $src $s.Rel) }
    }
    $rc = Invoke-HMRobocopy -Job $Job -Source $src -Dest $dst -Files $files -XD $xd -NoRecurse:$noRec -ExcludeOlder:([bool]$Ctx.Options.KeepNewer) -Threads $Ctx.Threads -LogFile $Ctx.RoboLog
    $st = switch ($rc.Level) { 'OK' { 'OK' } 'Warning' { 'Warning' } 'Cancel' { 'Cancel' } default { 'Error' } }
    $msg = "{0} Dateien, {1} -> {2}" -f $rc.FilesTotal, (Format-HMSize $rc.BytesTotal), $dstLocal
    if ($Ctx.Options.KeepNewer -and $rc.FilesCopied -lt $rc.FilesTotal) { $msg += " ($($rc.FilesCopied) kopiert, neuere/gleiche am Ziel behalten)" }
    if ($rc.FilesFailed -gt 0) { $msg += ", $($rc.FilesFailed) FEHLGESCHLAGEN (Datei geoeffnet? siehe Robocopy-Log)" }
    foreach ($s in $syncs) {
        if (Test-HMCancel $Job) { break }
        $sp = Join-Path $src $s.Rel
        if (-not (Test-Path -LiteralPath $sp)) { continue }
        $leaf = Split-Path $s.Rel -Leaf
        if ($Ctx.Options.RestoreOneDrive -and $TEnv.PROFILE) {
            $dLocal = Join-Path $TEnv.PROFILE (Join-Path 'OneDrive-Wiederherstellung' $leaf)
            $rc2 = Invoke-HMRobocopy -Job $Job -Source $sp -Dest (Convert-HMPath $Ctx $dLocal) -ExcludeOlder:([bool]$Ctx.Options.KeepNewer) -Threads $Ctx.Threads -LogFile $Ctx.RoboLog
            $msg += " | Cloud-Ordner '$leaf': $($rc2.FilesTotal) Dateien -> $dLocal"
            if ($rc2.Level -in @('Error', 'Cancel')) { $st = 'Error' } elseif ($rc2.Level -eq 'Warning' -and $st -eq 'OK') { $st = 'Warning' }
        } else {
            $msg += " | Cloud-Ordner '$leaf' nicht zurueckgeschrieben (Inhalt kommt ueber die Cloud; bei Bedarf Option 'OneDrive-Dateien in eigenen Ordner')"
        }
    }
    return [pscustomobject]@{ Name = $Item.Name; Status = $st; Msg = $msg }
}

function Restore-HMRegItem {
    param([hashtable]$Ctx, $Job, $Module, $Item)
    $src = Get-HMRestoreSource $Ctx $Module $Item
    if (-not $src -or -not (Test-Path -LiteralPath $src)) { return [pscustomobject]@{ Name = $Item.Name; Status = 'Skip'; Msg = 'nicht im Backup' } }
    $isUser = $Item.Key -match '^HK(CU|EY_CURRENT_USER)'
    if ($isUser -and -not $Ctx.HiveReady) { return [pscustomobject]@{ Name = $Item.Name; Status = 'Error'; Msg = 'Benutzer-Registry am Ziel nicht verfuegbar' } }
    $r = Import-HMReg $Ctx $Job $src $Ctx.Backup.Sid $Ctx.Backup.ProfilePath
    if ($r -eq 'OK') { return [pscustomobject]@{ Name = $Item.Name; Status = 'OK'; Msg = 'Registry importiert' } }
    return [pscustomobject]@{ Name = $Item.Name; Status = 'Error'; Msg = $r }
}

# Aktionen, die erst bei der naechsten Anmeldung des Benutzers laufen koennen (Drucker, Explorer-Neustart ...)
function Add-HMLogonAction([hashtable]$Ctx, [string]$Code) { $Ctx.LogonActions += $Code }

function Register-HMLogonTask {
    param([hashtable]$Ctx, $Job)
    if (-not $Ctx.LogonActions -or $Ctx.LogonActions.Count -eq 0) { return }
    if ($Ctx.UserMode) {
        # Benutzer-Modus: der Benutzer ist angemeldet -> Aktionen sofort in seiner Sitzung ausfuehren (keine geplante Aufgabe noetig)
        try {
            $f = Join-Path $env:TEMP ('HUMig_Anmeldeaktionen_{0}.ps1' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
            Set-Content -LiteralPath $f -Encoding UTF8 -Value (($Ctx.LogonActions -join "`r`n") + "`r`nRemove-Item -LiteralPath `$MyInvocation.MyCommand.Path -Force -ErrorAction SilentlyContinue")
            Start-Process -FilePath powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$f`"")
            Write-HMLog $Job 'Anmelde-Aktionen (Drucker, Explorer) in der aktuellen Sitzung gestartet' 'Success'
        } catch { Write-HMLog $Job "Anmelde-Aktionen nicht moeglich: $($_.Exception.Message)" 'Warning' }
        return
    }
    if (-not $Ctx.Account) { Write-HMLog $Job 'Anmelde-Aktionen nicht moeglich: Kontoname unbekannt' 'Warning'; return }
    $name = 'HUMig_FirstLogon_' + (ConvertTo-HMSafeName $Ctx.UserFolder)
    # Schutz: Skript laeuft nur einmal (Marker), auch falls die Aufgabe nicht geloescht werden kann
    $runId = [guid]::NewGuid().ToString('N')
    $body = "`$ErrorActionPreference = 'Continue'`r`n`$marker = Join-Path `$env:LOCALAPPDATA 'HUMig_FirstLogon_$runId.done'`r`nif (Test-Path -LiteralPath `$marker) { Remove-Item -LiteralPath `$MyInvocation.MyCommand.Path -Force -ErrorAction SilentlyContinue; return }`r`nSet-Content -LiteralPath `$marker -Value (Get-Date) -ErrorAction SilentlyContinue`r`n`$log = Join-Path `$env:TEMP 'HUMig_FirstLogon.log'`r`nStart-Transcript -Path `$log -Append | Out-Null`r`n" +
        ($Ctx.LogonActions -join "`r`n") +
        "`r`nStop-Transcript | Out-Null`r`nUnregister-ScheduledTask -TaskName '$name' -Confirm:`$false -ErrorAction SilentlyContinue`r`nRemove-Item -LiteralPath `$MyInvocation.MyCommand.Path -Force -ErrorAction SilentlyContinue"
    $r = Invoke-HMTarget $Ctx {
        param($n, $acct, $code)
        $dir = Join-Path $env:ProgramData 'HUMig'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $f = Join-Path $dir "$n.ps1"
        Set-Content -LiteralPath $f -Value $code -Encoding UTF8
        # Benutzer darf das Skript lesen/ausfuehren
        try { $acl = Get-Acl $dir; $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($acct, 'ReadAndExecute,Delete', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))); Set-Acl $dir $acl } catch { }
        $a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$f`""
        $t = New-ScheduledTaskTrigger -AtLogOn -User $acct
        # Aufgabe laeuft max. 30 Tage und wird danach von Windows geloescht
        $t.EndBoundary = (Get-Date).AddDays(30).ToString('s')
        $p = New-ScheduledTaskPrincipal -UserId $acct -LogonType Interactive -RunLevel Limited
        $s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -DeleteExpiredTaskAfter (New-TimeSpan -Days 1)
        Register-ScheduledTask -TaskName $n -Action $a -Trigger $t -Principal $p -Settings $s -Force -ErrorAction Stop | Out-Null
        # Benutzer bereits angemeldet? -> sofort ausfuehren
        $logged = @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue | ForEach-Object { $o = Invoke-CimMethod -InputObject $_ -MethodName GetOwner; "$($o.Domain)\$($o.User)" })
        if ($logged -contains $acct) { Start-ScheduledTask -TaskName $n; return 'STARTED' }
        'OK'
    } @($name, $Ctx.Account, $body)
    if ("$r" -eq 'STARTED') { Write-HMLog $Job "Anmelde-Aktionen ausgefuehrt (Benutzer ist angemeldet)" 'Success' }
    else { Write-HMLog $Job "Anmelde-Aktionen werden bei der naechsten Anmeldung von $($Ctx.Account) ausgefuehrt (Aufgabe $name)" 'Info' }
}

function Restore-HMBuiltin {
    param([hashtable]$Ctx, $Job, $Module, $Item, [hashtable]$TEnv)
    $dir = Get-HMRestoreSource $Ctx $Module $Item
    $res = { param($st, $msg) [pscustomobject]@{ Name = $Item.Handler; Status = $st; Msg = $msg } }
    switch ($Item.Handler) {

        'DesktopIconPositions' {
            $lines = @(Get-HMDesktopIconLines $dir)
            if (-not $lines.Count) { return (& $res 'Skip' 'keine Symbolpositionen im Backup') }
            $Ctx.DesktopIconLines = $lines
            return (& $res 'OK' "$($lines.Count) Symbolpositionen werden nach dem Explorer-Neustart gesetzt")
        }

        'ExtraFolders' {
            $entries = @()
            if ($Ctx.Backup.Legacy) {
                foreach ($i in 1, 2) {
                    $sp = Join-Path $Ctx.Backup.Path "FOLDER$i"; $tf = Join-Path $Ctx.Backup.Path "FOLDER$i.txt"
                    if ((Test-Path -LiteralPath $sp) -and (Test-Path -LiteralPath $tf)) { $entries += [pscustomobject]@{ Src = $sp; Path = ((Get-Content -LiteralPath $tf | Where-Object { $_ })[-1]).Trim() } }
                }
            } else {
                $jf = Join-Path $dir 'folders.json'
                if (Test-Path -LiteralPath $jf) {
                    foreach ($e in @(Get-Content -LiteralPath $jf -Raw -Encoding UTF8 | ConvertFrom-Json)) { $entries += [pscustomobject]@{ Src = (Join-Path $dir "FOLDER$($e.Index)"); Path = $e.Path } }
                }
            }
            if (-not $entries.Count) { return (& $res 'Skip' 'keine Ordner im Backup') }
            $worst = 'OK'
            foreach ($e in $entries) {
                $fake = [pscustomobject]@{ Name = (Split-Path $e.Path -Leaf); Type = 'Folder'; Path = $e.Path }
                $r = Restore-HMFolderItem $Ctx $Job $Module $fake $TEnv -SourceOverride $e.Src -DestOverride $e.Path
                Write-HMLog $Job "   $($e.Path): $($r.Msg)" $(if ($r.Status -eq 'OK') { 'Debug' } else { 'Warning' })
                if ($r.Status -ne 'OK' -and $worst -eq 'OK') { $worst = $r.Status }
            }
            return (& $res $worst "$($entries.Count) Ordner")
        }

        'Wlan' {
            $files = @(Get-ChildItem -LiteralPath $dir -Filter *.xml -ErrorAction SilentlyContinue)
            if (-not $files.Count) { return (& $res 'Skip' 'keine WLAN-Profile im Backup') }
            $tmpL = Join-Path (Invoke-HMTarget $Ctx { $env:windir }) "Temp\HMwlan_$([guid]::NewGuid().ToString('N'))"
            $tmpR = Convert-HMPath $Ctx $tmpL
            New-Item -ItemType Directory -Path $tmpR -Force | Out-Null
            foreach ($f in $files) { Copy-Item -LiteralPath $f.FullName -Destination $tmpR -Force }
            $r = Invoke-HMTarget $Ctx {
                param($t)
                $ok = 0; $bad = @()
                foreach ($f in @(Get-ChildItem -LiteralPath $t -Filter *.xml)) {
                    $null = & netsh.exe wlan add profile "filename=$($f.FullName)" user=all 2>&1
                    if ($LASTEXITCODE -eq 0) { $ok++ } else { $bad += $f.BaseName }
                }
                Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction SilentlyContinue
                "$ok|$($bad -join ', ')"
            } @($tmpL)
            $p = "$r".Split('|')
            if ($p[1]) { return (& $res 'Warning' "$($p[0]) Profile importiert, fehlgeschlagen: $($p[1])") }
            return (& $res 'OK' "$($p[0]) Profile importiert")
        }

        'PrinterConnections' {
            $list = @(); $def = $null
            if ($Ctx.Backup.Legacy) {
                if (Test-Path -LiteralPath $dir) { $list = @(Get-Content -LiteralPath $dir | ForEach-Object { ($_ -split '\s{2,}')[0].Trim() } | Where-Object { $_ -match '^\\\\[^\\]+\\.+' } | Select-Object -Unique) }
            } else {
                $jf = Join-Path $dir 'printers.json'
                if (Test-Path -LiteralPath $jf) { $j = Get-Content -LiteralPath $jf -Raw -Encoding UTF8 | ConvertFrom-Json; $list = @($j.Connections | Where-Object { $_ }); $def = $j.Default }
            }
            if (-not $list.Count) { return (& $res 'Skip' 'keine Netzwerkdrucker im Backup') }
            $code = "# Netzwerkdrucker verbinden`r`n"
            foreach ($p in $list) { $pe = $p -replace "'", "''"; $code += "try { Add-Printer -ConnectionName '$pe' -ErrorAction Stop; Write-Output 'OK $pe' } catch { Write-Output ('FEHLER $pe : ' + `$_.Exception.Message) }`r`n" }
            if ($def) {
                $code += "try { Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Windows' -Name LegacyDefaultPrinterMode -Value 1 -Type DWord; `$pr = Get-CimInstance Win32_Printer | Where-Object { `$_.Name -eq '$($def -replace "'", "''")' }; if (`$pr) { Invoke-CimMethod -InputObject `$pr -MethodName SetDefaultPrinter | Out-Null } } catch { }`r`n"
            }
            Add-HMLogonAction $Ctx $code
            return (& $res 'OK' ("{0} Drucker werden bei der Anmeldung verbunden{1}" -f $list.Count, $(if ($def) { ", Standard: $def" } else { '' })))
        }

        'PrintersFull' {
            $f = if ($Ctx.Backup.Legacy) { $dir } else { Join-Path $dir 'Printers.printerExport' }
            if (-not (Test-Path -LiteralPath $f)) { return (& $res 'Skip' 'kein Drucker-Export im Backup') }
            $tmpL = Join-Path (Invoke-HMTarget $Ctx { $env:windir }) "Temp\HMprn_$([guid]::NewGuid().ToString('N')).printerExport"
            Copy-Item -LiteralPath $f -Destination (Convert-HMPath $Ctx $tmpL) -Force
            $r = Invoke-HMTarget $Ctx {
                param($t)
                $exe = Join-Path $env:windir 'System32\spool\tools\PrintBrm.exe'
                $o = & $exe -r -f "$t" 2>&1
                $c = $LASTEXITCODE
                Remove-Item -LiteralPath $t -Force -ErrorAction SilentlyContinue
                if ($c -ne 0) { "FEHLER: Code $c $($o | Select-Object -Last 3)" } else { 'OK' }
            } @($tmpL)
            if ("$r" -eq 'OK') { return (& $res 'OK' 'Drucker, Anschluesse und Treiber wiederhergestellt') }
            return (& $res 'Warning' "$r")
        }

        'Fonts' {
            $fdir = if ($Ctx.Backup.Legacy) { $dir } else { Join-Path $dir 'FONTS' }
            if (-not (Test-Path -LiteralPath $fdir)) { return (& $res 'Skip' 'keine Schriftarten im Backup') }
            $map = @{}
            $jf = Join-Path $dir 'fonts.json'
            if (-not $Ctx.Backup.Legacy -and (Test-Path -LiteralPath $jf)) { foreach ($e in @(Get-Content -LiteralPath $jf -Raw -Encoding UTF8 | ConvertFrom-Json)) { if ($e.File) { $map[(Split-Path $e.File -Leaf).ToLower()] = $e.Name } } }
            $existing = Invoke-HMTarget $Ctx { @(Get-ChildItem -LiteralPath (Join-Path $env:windir 'Fonts') -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Name.ToLower() }) }
            $ex = @{}; foreach ($e in @($existing)) { $ex[$e] = $true }
            $new = @(Get-ChildItem -LiteralPath $fdir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.ttf', '.ttc', '.otf', '.fon') -and -not $ex.ContainsKey($_.Name.ToLower()) })
            if (-not $new.Count) { return (& $res 'OK' 'alle Schriftarten bereits vorhanden') }
            $winFonts = Convert-HMPath $Ctx (Join-Path $TEnv.WINDIR 'Fonts')
            $reg = @()
            foreach ($f in $new) {
                try { Copy-Item -LiteralPath $f.FullName -Destination $winFonts -Force -ErrorAction Stop } catch { continue }
                $n = if ($map.ContainsKey($f.Name.ToLower())) { $map[$f.Name.ToLower()] } else { "$($f.BaseName) $(if ($f.Extension -eq '.otf') { '(OpenType)' } else { '(TrueType)' })" }
                $reg += [pscustomobject]@{ Name = $n; File = $f.Name }
            }
            [void](Invoke-HMTarget $Ctx {
                param($items)
                foreach ($i in $items) { New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts' -Name $i.Name -Value $i.File -PropertyType String -Force | Out-Null }
            } @(, $reg))
            return (& $res 'OK' "$($reg.Count) Schriftarten installiert (wirksam nach Neuanmeldung)")
        }

        'Tasks' {
            $files = @()
            if ($Ctx.Backup.Legacy) { $files = @(Get-ChildItem -LiteralPath $dir -Filter *.xml -ErrorAction SilentlyContinue | ForEach-Object { [pscustomobject]@{ Path = '\'; Name = $_.BaseName; File = $_.FullName } }) }
            else {
                $jf = Join-Path $dir 'tasks.json'
                if (Test-Path -LiteralPath $jf) { $files = @(Get-Content -LiteralPath $jf -Raw -Encoding UTF8 | ConvertFrom-Json | ForEach-Object { [pscustomobject]@{ Path = $_.Path; Name = $_.Name; File = (Join-Path $dir $_.File) } }) }
            }
            if (-not $files.Count) { return (& $res 'Skip' 'keine Aufgaben im Backup') }
            $payload = @($files | ForEach-Object { [pscustomobject]@{ Path = $_.Path; Name = $_.Name; Xml = (Get-Content -LiteralPath $_.File -Raw) } })
            $r = Invoke-HMTarget $Ctx {
                param($tasks)
                $ok = 0; $skip = 0; $bad = @()
                foreach ($t in $tasks) {
                    if (Get-ScheduledTask -TaskName $t.Name -TaskPath $t.Path -ErrorAction SilentlyContinue) { $skip++; continue }
                    try { Register-ScheduledTask -Xml $t.Xml -TaskName $t.Name -TaskPath $t.Path -ErrorAction Stop | Out-Null; $ok++ } catch { $bad += $t.Name }
                }
                "$ok|$skip|$($bad -join ', ')"
            } @(, $payload)
            $p = "$r".Split('|')
            $msg = "$($p[0]) importiert, $($p[1]) bereits vorhanden"
            if ($p[2]) { return (& $res 'Warning' "$msg, fehlgeschlagen (Kennwort noetig?): $($p[2])") }
            return (& $res 'OK' $msg)
        }

        'Drivers' {
            $ddir = if ($Ctx.Backup.Legacy) { $dir } else { Join-Path $dir 'DRIVERS' }
            if (-not (Test-Path -LiteralPath $ddir)) { return (& $res 'Skip' 'keine Treiber im Backup') }
            $tmpL = Join-Path (Invoke-HMTarget $Ctx { $env:windir }) "Temp\HMdrv_$([guid]::NewGuid().ToString('N'))"
            [void](Invoke-HMRobocopy -Job $Job -Source $ddir -Dest (Convert-HMPath $Ctx $tmpL) -Threads $Ctx.Threads)
            $r = Invoke-HMTarget $Ctx {
                param($t)
                $o = & pnputil.exe /add-driver "$t\*.inf" /subdirs /install 2>&1
                Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction SilentlyContinue
                ($o | Select-Object -Last 4) -join ' '
            } @($tmpL)
            return (& $res 'OK' "pnputil: $r")
        }

        'Wallpaper' {
            if ($Ctx.Backup.Legacy -or -not $Ctx.HiveReady) { return (& $res 'Skip' '') }
            $wdir = Join-Path $dir 'WALLPAPER_FILE'
            $jf = Join-Path $wdir 'wallpaper.json'
            if (-not (Test-Path -LiteralPath $jf)) { return (& $res 'Skip' 'kein Hintergrundbild im Backup') }
            $j = Get-Content -LiteralPath $jf -Raw -Encoding UTF8 | ConvertFrom-Json
            $orig = "$($j.Original)"
            if ($Ctx.Backup.ProfilePath -and $orig.StartsWith($Ctx.Backup.ProfilePath, [StringComparison]::OrdinalIgnoreCase)) { $orig = $Ctx.ProfilePath + $orig.Substring($Ctx.Backup.ProfilePath.Length) }
            $target = $orig
            if (-not (Test-Path -LiteralPath (Convert-HMPath $Ctx $orig))) {
                $target = Join-Path $Ctx.ProfilePath "Pictures\Hintergrund\$($j.File)"
                $tr = Convert-HMPath $Ctx $target
                New-Item -ItemType Directory -Path (Split-Path $tr -Parent) -Force | Out-Null
                Copy-Item -LiteralPath (Join-Path $wdir $j.File) -Destination $tr -Force
            }
            [void](Invoke-HMTarget $Ctx { param($s, $t) Set-ItemProperty -LiteralPath "Registry::HKEY_USERS\$s\Control Panel\Desktop" -Name WallPaper -Value $t } @($Ctx.UserSid, $target))
            Add-HMLogonAction $Ctx "# Hintergrund anwenden`r`n1..2 | ForEach-Object { & rundll32.exe 'user32.dll,UpdatePerUserSystemParameters' 1 True; Start-Sleep 1 }"
            return (& $res 'OK' "Hintergrundbild: $target")
        }

        'Usmt' { return [pscustomobject]@{ Name = 'Usmt'; Status = 'Skip'; Msg = 'wird vor den anderen Modulen ausgefuehrt' } }

        'Shares' {
            $f = Join-Path $dir 'shares.json'
            if (-not (Test-Path -LiteralPath $f)) { return (& $res 'Skip' 'keine Freigaben im Backup') }
            $json = Get-Content -LiteralPath $f -Raw -Encoding UTF8
            $r = @(Invoke-HMTarget $Ctx $script:HMShareCreateScript @($json, $false))
            foreach ($l in $r) { Write-HMLog $Job "      $l" $(if ("$l" -like 'OK*') { 'Success' } elseif ("$l" -like 'WARN*') { 'Warning' } else { 'Error' }) }
            $bad = @($r | Where-Object { "$_" -like 'FEHLER*' }).Count
            $warn = @($r | Where-Object { "$_" -like 'WARN*' }).Count
            return (& $res $(if ($bad) { 'Warning' } elseif ($warn) { 'Warning' } else { 'OK' }) "$(@($r | Where-Object { "$_" -like 'OK*' }).Count) Freigaben angelegt$(if ($warn) { ", $warn Hinweis(e)" })$(if ($bad) { ", $bad Fehler" }) - NTFS-Rechte: Werkzeug 'Freigaben'")
        }

        'Info' { return (& $res 'Skip' 'nur Information (Dateien im Backup-Ordner)') }

        default { return (& $res 'Error' "Unbekannter Handler: $($Item.Handler)") }
    }
}

function Restore-HMUsmt {
    param([hashtable]$Ctx, $Job)
    $usmt = Find-HMUsmt $Ctx
    if (-not $usmt) { Write-HMLog $Job 'USMT nicht gefunden - Windows-Einstellungen werden uebersprungen' 'Error'; return $false }
    $store = if ($Ctx.Backup.Legacy) { $Ctx.Backup.Path } else { Join-Path (Join-Path $Ctx.Backup.Path 'Usmt') 'STORE' }
    if (-not (Get-ChildItem -LiteralPath $store -Filter 'USMT.MIG' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1)) { Write-HMLog $Job "Kein USMT.MIG im Backup ($store)" 'Error'; return $false }
    $srcAcct = if ($Ctx.Backup.Account) { $Ctx.Backup.Account } else { $null }
    $xmlDir = Join-Path $Ctx.ToolRoot 'Config\USMT'
    if ($Ctx.IsRemote) {
        $rl = Join-Path (Invoke-HMTarget $Ctx { $env:windir }) "Temp\HMusmt_$([guid]::NewGuid().ToString('N'))"
        $rr = Convert-HMPath $Ctx $rl
        [void](Invoke-HMRobocopy -Job $Job -Source $usmt -Dest (Join-Path $rr 'BIN') -Threads 16)
        [void](Invoke-HMRobocopy -Job $Job -Source $xmlDir -Dest (Join-Path $rr 'XML') -Threads 4)
        [void](Invoke-HMRobocopy -Job $Job -Source $store -Dest (Join-Path $rr 'STORE') -Threads $Ctx.Threads)
        $exeDir = Join-Path $rl 'BIN'; $xDir = Join-Path $rl 'XML'; $sDir = Join-Path $rl 'STORE'
    } else { $exeDir = $usmt; $xDir = $xmlDir; $sDir = $store }
    $a = @('"' + $sDir + '"') + (Get-HMUsmtXmlArgs $xDir) + @('/c', '/ue:*\*', '/v:5', ('/l:"' + (Join-Path $env:TEMP 'HUMig_loadstate.log') + '"'))
    if ($srcAcct -and $Ctx.Account -and ($srcAcct -ne $Ctx.Account)) { $a += ('/mu:"' + $srcAcct + ':' + $Ctx.Account + '"'); $a += ('/ui:"' + $srcAcct + '"') }
    else { $a += ('/ui:"' + $(if ($Ctx.Account) { $Ctx.Account } else { $srcAcct }) + '"') }
    Write-HMLog $Job 'Windows-Einstellungen (USMT LoadState) ...' 'Info'
    $code = Invoke-HMTarget $Ctx {
        param($exe, $argString)
        (Start-Process -FilePath (Join-Path $exe 'loadstate.exe') -ArgumentList $argString -WorkingDirectory $exe -WindowStyle Hidden -Wait -PassThru).ExitCode
    } @($exeDir, ($a -join ' '))
    if ($Ctx.IsRemote) { Remove-Item -LiteralPath $rr -Recurse -Force -ErrorAction SilentlyContinue }
    if ([int]"$code" -eq 0) { Write-HMLog $Job '   LoadState OK' 'Success'; return $true }
    Write-HMLog $Job "   LoadState Code $code$(Get-HMUsmtCodeText $code '') (Log am Ziel-PC: %TEMP%\HUMig_loadstate.log)" 'Warning'
    return $true
}

function Invoke-HMPostRestore {
    param([hashtable]$Ctx, $Job)
    $o = $Ctx.PostOptions
    if (-not $o) { return }
    $r = Invoke-HMTarget $Ctx {
        param($o, $sid)
        $out = @()
        if ($o.DisableWUDrivers) {
            $k = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
            if (-not (Test-Path $k)) { New-Item -Path $k -Force | Out-Null }
            New-ItemProperty -Path $k -Name ExcludeWUDriversInQualityUpdate -Value 1 -PropertyType DWord -Force | Out-Null
            $out += 'OK Treiber ueber Windows Update deaktiviert'
        }
        if ($o.NumLockOn) {
            foreach ($h in @('Registry::HKEY_USERS\.DEFAULT', "Registry::HKEY_USERS\$sid")) {
                if (Test-Path -LiteralPath "$h\Control Panel\Keyboard") { Set-ItemProperty -LiteralPath "$h\Control Panel\Keyboard" -Name InitialKeyboardIndicators -Value '2' }
            }
            $out += 'OK NumLock beim Start aktiv'
        }
        if ($o.FastBootOff) {
            Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -Value 0 -Type DWord
            $out += 'OK Schnellstart deaktiviert'
        }
        if ($o.ExplorerFavorites -and $sid -and (Test-Path -LiteralPath "Registry::HKEY_USERS\$sid")) {
            $clsid = '{323CA680-C24D-4099-B94D-446DD2D7249E}'
            foreach ($base in @("Registry::HKEY_USERS\$sid\SOFTWARE\Classes\CLSID\$clsid", "Registry::HKEY_USERS\$sid\SOFTWARE\Classes\WOW6432Node\CLSID\$clsid")) {
                New-Item -Path $base -Force | Out-Null
                New-ItemProperty -LiteralPath $base -Name FolderValueFlags -Value 28 -PropertyType DWord -Force | Out-Null
                New-ItemProperty -LiteralPath $base -Name SortOrderIndex -Value 4 -PropertyType DWord -Force | Out-Null
                New-ItemProperty -LiteralPath $base -Name 'System.IsPinnedToNameSpaceTree' -Value 1 -PropertyType DWord -Force | Out-Null
                New-Item -Path "$base\DefaultIcon" -Force | Out-Null
                Set-ItemProperty -LiteralPath "$base\DefaultIcon" -Name '(default)' -Value '%SystemRoot%\system32\imageres.dll,-185'
                New-Item -Path "$base\ShellFolder" -Force | Out-Null
                New-ItemProperty -LiteralPath "$base\ShellFolder" -Name Attributes -Value 0x70010000 -PropertyType DWord -Force | Out-Null
            }
            New-Item -Path "Registry::HKEY_USERS\$sid\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\$clsid" -Force | Out-Null
            $hp = "Registry::HKEY_USERS\$sid\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel"
            if (-not (Test-Path -LiteralPath $hp)) { New-Item -Path $hp -Force | Out-Null }
            New-ItemProperty -LiteralPath $hp -Name $clsid -Value 1 -PropertyType DWord -Force | Out-Null
            $out += 'OK Explorer-Favoriten aktiviert'
        }
        if ($o.GpUpdate) {
            $g = @(& cmd.exe /c 'echo N| gpupdate.exe /force /wait:120' 2>&1 | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
            $out += 'OK gpupdate /force: ' + $(if ($g.Count) { $g[-1] } else { 'ausgefuehrt' })
        }
        $out
    } @($o, $Ctx.UserSid)
    foreach ($l in @($r)) { Write-HMLog $Job "   $l" 'Success' }
    if ($o.PostScript) {
        $ps = "$($o.PostScript)"
        if (Test-Path -LiteralPath $ps) {
            Write-HMLog $Job "   Nach-Skript: $ps" 'Info'
            try {
                $code = Get-Content -LiteralPath $ps -Raw
                $out = Invoke-HMTarget $Ctx { param($c) & ([scriptblock]::Create($c)) 2>&1 | Out-String } @($code)
                foreach ($l in ("$out" -split "`r?`n" | Where-Object { $_.Trim() })) { Write-HMLog $Job "      $l" 'Debug' }
            } catch { Write-HMLog $Job "   Nach-Skript FEHLER: $($_.Exception.Message)" 'Error' }
        } else { Write-HMLog $Job "   Nach-Skript nicht gefunden: $ps" 'Warning' }
    }
}

# ----------------------------------------------------------------------------
# Hauptablauf Restore
# ----------------------------------------------------------------------------
function Start-HMRestore {
    param([hashtable]$Ctx, $Job)
    $start = Get-Date
    $Ctx.IsRemote = -not (Test-HMIsLocal $Ctx.Computer)
    if (-not $Ctx.IsRemote) { $Ctx.Computer = $env:COMPUTERNAME }
    $Ctx.LogonActions = @()
    $Ctx.DesktopIconLines = @()
    $Job.LogFile = Join-Path $Ctx.Backup.Path ("Restore_{0}_{1}.log" -f (ConvertTo-HMSafeName $Ctx.Computer), $start.ToString('yyyyMMdd_HHmm'))
    $Ctx.RoboLog = Join-Path $Ctx.Backup.Path ("Restore_{0}_{1}_Robocopy.log" -f (ConvertTo-HMSafeName $Ctx.Computer), $start.ToString('yyyyMMdd_HHmm'))
    Write-HMLog $Job "RESTORE  $($Ctx.Backup.Name)  ->  $($Ctx.Computer) \ $($Ctx.UserFolder)" 'Header'
    if ($Ctx.Backup.Legacy) { Write-HMLog $Job 'Backup der Vorgaengerversion erkannt (ohne manifest.json)' 'Info' }

    $shareRoot = $null
    $results = @()
    try {
        if ($Ctx.IsRemote -and $Ctx.Credential) { $shareRoot = "\\$($Ctx.Computer)\C$"; [void](Connect-HMShare $shareRoot $Ctx.Credential) }

        # 1. USMT zuerst (legt ggf. das Profil an)
        $usmtMod = @($Ctx.Modules | Where-Object { $_.Id -eq 'Usmt' })
        if ($usmtMod.Count -and -not (Test-HMCancel $Job)) {
            [void](Restore-HMUsmt $Ctx $Job)
            # Profil neu ermitteln (LoadState kann es angelegt haben)
            if (-not $Ctx.ProfilePath -or -not $Ctx.UserSid) {
                $acc = $Ctx.Account
                $prof = @(Get-HMUserProfiles -Computer $Ctx.Computer -Credential $Ctx.Credential | Where-Object { $_.Account -eq $acc })
                if ($prof.Count) { $Ctx.UserSid = $prof[0].SID; $Ctx.ProfilePath = $prof[0].LocalPath; Write-HMLog $Job "Profil angelegt: $($Ctx.ProfilePath)" 'Success' }
            }
        }
        $userMods = @($Ctx.Modules | Where-Object { $_.Scope -eq 'User' -and $_.Id -ne 'Usmt' })
        if ($userMods.Count -and (-not $Ctx.ProfilePath -or -not $Ctx.UserSid)) {
            Write-HMLog $Job "Zielbenutzer hat am Ziel-PC noch kein Profil. Entweder einmal anmelden lassen oder das Modul 'Windows-Einstellungen (USMT)' mitwaehlen. Benutzer-Module werden uebersprungen." 'Error'
            $Ctx.Modules = @($Ctx.Modules | Where-Object { $_.Scope -ne 'User' })
        }
        $Ctx.HiveReady = $false
        if ($Ctx.UserSid) {
            try { $Ctx.HiveReady = Mount-HMHive $Ctx $Job $Ctx.UserSid $Ctx.ProfilePath } catch { Write-HMLog $Job "Registry des Zielbenutzers nicht verfuegbar: $($_.Exception.Message)" 'Warning' }
        }
        $tenv = Get-HMTargetEnv $Ctx $Ctx.UserSid $Ctx.ProfilePath

        $mods = @($Ctx.Modules | Where-Object { $_.Id -ne 'Usmt' })
        $total = @($mods | ForEach-Object { @($_.Items).Count } | Measure-Object -Sum).Sum
        if (-not $total) { $total = 1 }
        $done = 0
        foreach ($mod in $mods) {
            if (Test-HMCancel $Job) { break }
            Write-HMLog $Job $mod.Name 'Info'
            $Job.Status = $mod.Name
            $worst = 'OK'
            $itemLog = @()
            foreach ($it in @($mod.Items)) {
                if (Test-HMCancel $Job) { break }
                try {
                    $r = if ($Ctx.UserMode -and (Test-HMItemNeedsAdmin $it)) {
                        [pscustomobject]@{ Name = "$($it.Name)"; Status = 'Skip'; Msg = "uebersprungen: $($it.Path)$($it.Key) braucht Administratorrechte (Benutzer-Modus)" }
                    } else { switch ($it.Type) {
                        'Folder'  { Restore-HMFolderItem $Ctx $Job $mod $it $tenv }
                        'Files'   { Restore-HMFolderItem $Ctx $Job $mod $it $tenv }
                        'Reg'     { Restore-HMRegItem $Ctx $Job $mod $it }
                        'Builtin' { Restore-HMBuiltin $Ctx $Job $mod $it $tenv }
                        default   { [pscustomobject]@{ Name = $it.Name; Status = 'Error'; Msg = "Unbekannter Typ $($it.Type)" } }
                    } }
                } catch { $r = [pscustomobject]@{ Name = "$($it.Name)$($it.Handler)"; Status = 'Error'; Msg = $_.Exception.Message } }
                if ($r.Status -ne 'Skip' -or $r.Msg) {
                    $lvl = switch ($r.Status) { 'OK' { 'Success' } 'Skip' { 'Debug' } 'Warning' { 'Warning' } default { 'Error' } }
                    Write-HMLog $Job ("   {0}: {1}" -f $r.Name, $r.Msg) $lvl
                    $itemLog += [pscustomobject]@{ Name = $r.Name; Status = $r.Status; Msg = $r.Msg }
                }
                if ($r.Status -in @('Error', 'Cancel')) { $worst = 'Error' } elseif ($r.Status -eq 'Warning' -and $worst -eq 'OK') { $worst = 'Warning' }
                $done++
                $Job.Progress = [int](100 * $done / $total)
            }
            if (@($itemLog | Where-Object { $_.Status -ne 'Skip' }).Count -eq 0 -and $worst -eq 'OK') { $worst = 'Skip' }
            $results += [pscustomobject]@{ Id = $mod.Id; Name = $mod.Name; Status = $worst; Items = $itemLog }
        }

        # Explorer-/Taskleisten-Einstellungen greifen erst nach Explorer-Neustart
        if (@($mods | Where-Object { $_.Id -in @('TaskbarWallpaper', 'DesktopIcons', 'QuickAccess') }).Count) {
            Add-HMLogonAction $Ctx "# Explorer neu starten, damit Taskleiste/Symbole uebernommen werden`r`nStart-Sleep -Seconds 5; Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue"
        }
        if (@($Ctx.DesktopIconLines).Count) {
            Add-HMLogonAction $Ctx ("# Desktop-Symbolpositionen setzen (wartet, bis der Desktop wieder da ist)`r`nStart-Sleep -Seconds 4; if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }`r`n" + (Get-HMDesktopIconsCode 'Load' '' '' $Ctx.DesktopIconLines))
        }
        if (-not (Test-HMCancel $Job)) {
            if ($Ctx.HiveReady) { Register-HMLogonTask $Ctx $Job }
            Write-HMLog $Job 'Nacharbeiten' 'Info'
            Invoke-HMPostRestore $Ctx $Job
        }
    } finally {
        try { Dismount-HMHive $Ctx $Job } catch { }
        if ($shareRoot) { Disconnect-HMShare $shareRoot }
    }
    $dur = ((Get-Date) - $start).ToString('hh\:mm\:ss')
    $errs = @($results | Where-Object { $_.Status -eq 'Error' }).Count
    $warns = @($results | Where-Object { $_.Status -eq 'Warning' }).Count
    $st = if (Test-HMCancel $Job) { 'Cancelled' } elseif ($errs) { 'Error' } elseif ($warns) { 'Warning' } else { 'OK' }
    $Job.Progress = 100
    Write-HMLog $Job ("RESTORE {0} in {1} - Fehler: {2}, Warnungen: {3}. Empfehlung: Benutzer ab- und wieder anmelden bzw. Neustart." -f $st, $dur, $errs, $warns) $(if ($st -eq 'OK') { 'Success' } elseif ($st -eq 'Warning') { 'Warning' } else { 'Error' })
    $mf = $Ctx.Backup.Manifest
    $facts = [ordered]@{
        'Backup' = $Ctx.Backup.Name; 'Quelle' = "$($Ctx.Backup.Computer) \ $($Ctx.Backup.User)"; 'Backup erstellt' = $Ctx.Backup.Created
        'Ziel-Computer' = $Ctx.Computer; 'Ziel-Benutzer' = "$($Ctx.UserFolder)$(if ($Ctx.Account) { " ($($Ctx.Account))" })"; 'Profilpfad' = $Ctx.ProfilePath
        'Gestartet' = $start.ToString('yyyy-MM-dd HH:mm:ss'); 'Dauer' = $dur
        'Quell-Betriebssystem' = $(if ($mf) { $mf.SourceOS } else { '' }); 'Durchgefuehrt von' = "$env:USERDOMAIN\$env:USERNAME an $env:COMPUTERNAME"
    }
    $notes = @('Benutzer ab- und wieder anmelden bzw. Neustart, damit alle Einstellungen wirken.')
    if (@($Ctx.LogonActions).Count) { $notes += 'Einige Einstellungen werden bei der naechsten Anmeldung des Benutzers automatisch uebernommen (einmalige Aufgabe).' }
    $rep = New-HMReport -Ctx $Ctx -Kind Restore -OutFile (Join-Path $Ctx.Backup.Path ("Bericht_Restore_{0}_{1}.html" -f (ConvertTo-HMSafeName $Ctx.Computer), $start.ToString('yyyyMMdd_HHmm'))) -Modules $results -Facts $facts -Notes $notes -Status $st
    $Job.Result = [pscustomobject]@{ Status = $st; Duration = $dur; Modules = $results; Report = $rep }
}
