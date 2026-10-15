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
    return (Invoke-HMTargetProtected $Ctx $code @($Ctx.Account, (Get-HMDesktopIconsCode 'Save' '%DATA%' '%RESULT%')) -Soft)
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
            if (bad.Count == 0) { int e = RemoveDir(root); if (e != 0) bad.Add("(Backup-Ordner) " + Err(e)); }
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
                    // nur echte Verknuepfungen (Junction 0xA0000003, Symlink 0xA000000C) als Link behandeln - OneDrive-/Cloud-Ordner
                    // tragen ebenfalls das Reparse-Attribut (Tag 0x9000xx1A), sind aber normale Ordner mit Inhalt
                    bool reparse = (fd.dwFileAttributes & 0x400) != 0 && (fd.r0 == 0xA0000003u || fd.r0 == 0xA000000Cu);
                    if (isDir && !reparse)
                    {
                        Walk(full, rootLen, bad, max, delete);
                        if (delete && bad.Count == 0)
                        {
                            SetFileAttributesW(L(full), 0x10);
                            int e = RemoveDir(full); if (e != 0) bad.Add(Rel(full, rootLen) + @"\ (" + Err(e) + ")");
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
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern uint GetFileAttributesW(string n);
        // Ordner entfernen; OneDrive/Virenscanner halten einen gerade geleerten Ordner oft kurz offen (Zugriff verweigert) -> bis ca. 5 s wiederholen.
        // Ist der Ordner danach weg (Loeschen war nur vorgemerkt), gilt das als Erfolg. Rueckgabe: 0 = OK, sonst Win32-Fehler
        static int RemoveDir(string full)
        {
            int err = 0;
            SetFileAttributesW(L(full), 0x10);   // Schreibschutz-Attribut weg (OneDrive setzt es auf Ordnern) - sonst Zugriff verweigert
            for (int i = 0; i < 20; i++)
            {
                if (RemoveDirectoryW(L(full))) return 0;
                err = Marshal.GetLastWin32Error();
                if (err == 2 || err == 3) return 0;
                if (err != 5 && err != 32 && err != 145) return err;
                System.Threading.Thread.Sleep(250);
            }
            if (GetFileAttributesW(L(full)) == 0xFFFFFFFFu) return 0;
            return err;
        }
        static string Rel(string p, int rootLen) { return p.Length > rootLen ? p.Substring(rootLen).TrimStart('\\') : p; }
    }
}
'@
function Initialize-HMFs { if (-not ('HMFs.Tree' -as [type])) { Add-Type -TypeDefinition $script:HMFsCs -ErrorAction Stop } }

# ============================================================================
# ARCHIV: Backup einfrieren
# ============================================================================
# Markierung = Datei im Backup-Ordner (keine Aenderung von Rechten oder Attributen - funktioniert auf USB, NAS, Freigabe).
# Ohne Schreibschutz: manche NAS bilden ihn als Dateirechte ab und lassen ihn danach von Windows aus nicht mehr entfernen.
# Ein Archiv wird nie fortlaufend weitergefuehrt (der naechste Lauf legt ein neues Backup an), nie von der Aufbewahrung
# vorgeschlagen oder geloescht, seine beiseitegelegten Dateien (_GELOESCHT) werden nie geleert. Loeschen erst nach Aufheben.
# Dateiname steht in den Funktionen selbst (auch einzeln geladen gueltig)
$script:HMArchiveFile = 'HUMig-Archiv.txt'
function Test-HMBackupArchived([string]$Path) {
    if (-not $Path) { return $false }
    try { return [System.IO.File]::Exists([System.IO.Path]::Combine($Path, 'HUMig-Archiv.txt')) } catch { return $false }
}
# Liegt der Pfad in einem Archiv (Backup-Ordner selbst oder darunter, z. B. _GELOESCHT\<Zeit>)? Prueft bis zu 3 Ebenen nach oben
function Test-HMInArchive([string]$Path) {
    $p = "$Path".TrimEnd('\')
    for ($i = 0; $i -lt 4 -and $p; $i++) {
        if (Test-HMBackupArchived $p) { return $true }
        try { $p = [System.IO.Path]::GetDirectoryName($p) } catch { $p = $null }
    }
    return $false
}
# Markierung setzen ($On) oder aufheben. Rueckgabe 'OK' oder 'FEHLER: ...'
function Set-HMBackupArchive([string]$Path, [bool]$On) {
    if (-not $Path -or -not [System.IO.Directory]::Exists($Path)) { return 'FEHLER: Backup-Ordner nicht gefunden' }
    try {
        if (([System.IO.File]::GetAttributes($Path) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return 'FEHLER: Backup-Ordner ist eine Verknuepfung - wird nicht markiert' }
        $f = [System.IO.Path]::Combine($Path, 'HUMig-Archiv.txt')
        if ($On) {
            if ([System.IO.File]::Exists($f)) { return 'OK' }
            $t = "Dieses Backup ist als ARCHIV markiert (HUMig) - seit $(Get-Date -Format 'dd.MM.yyyy HH:mm').`r`n`r`n" +
                "HUMig schreibt nicht mehr hinein (ein fortlaufendes Backup legt stattdessen ein neues an), schlaegt es bei der Aufbewahrung nicht vor, " +
                "loescht es nicht und leert die beiseitegelegten Dateien (_GELOESCHT) nicht.`r`n" +
                "Aufheben: HUMig > Restore > Backup markieren > Knopf 'Archiv aufheben' (oder diese Datei loeschen).`r`n"
            [System.IO.File]::WriteAllText($f, $t, (New-Object System.Text.UTF8Encoding($true)))
        } else {
            if (-not [System.IO.File]::Exists($f)) { return 'OK' }
            # Markierung aus 2.1.5 ist schreibgeschuetzt: Attribut entfernen versuchen (auf manchen NAS verweigert), dann loeschen
            try { if (([System.IO.File]::GetAttributes($f) -band [System.IO.FileAttributes]::ReadOnly) -ne 0) { [System.IO.File]::SetAttributes($f, [System.IO.FileAttributes]::Normal) } } catch { }
            try { [System.IO.File]::Delete($f) }
            catch { return "FEHLER: Markierung nicht entfernbar ($($_.Exception.Message)). Die Datei $f bitte direkt am Server bzw. NAS (als Administrator, z. B. ueber dessen Dateiverwaltung) loeschen - danach ist das Backup wieder normal." }
            if ([System.IO.File]::Exists($f)) { return "FEHLER: Markierung noch vorhanden - Datei $f bitte direkt am Server bzw. NAS loeschen." }
        }
        return 'OK'
    } catch { return "FEHLER: $($_.Exception.Message)" }
}

# Backup-Ordner loeschen - nur ganz oder gar nicht: vorher fuer JEDE Datei pruefen, ob sie geloescht werden darf
# (Loeschrecht, nicht geoeffnet). Sonst bleibt ein halb geloeschtes, unbrauchbares Backup zurueck. Lange Pfade und schreibgeschuetzte Dateien werden unterstuetzt.
# Archiv (oder Ordner darin, z. B. _GELOESCHT) wird nie geloescht - erst Markierung aufheben.
function Remove-HMBackupFolder([string]$Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return 'OK' }
    if (Test-HMInArchive $Path) { return 'FEHLER: nichts geloescht - Backup ist als Archiv markiert (zuerst Markierung aufheben: Restore > Archiv aufheben)' }
    # Backup-Ordner selbst ist eine Verknuepfung (Junction/Symlink): nur den Link entfernen, nie das Ziel durchlaufen
    try {
        $ra = [System.IO.File]::GetAttributes($Path)
        if (($ra -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            [System.IO.Directory]::Delete($Path, $false)
            return 'OK'
        }
    } catch { return "FEHLER: nichts geloescht - Verknuepfung nicht pruefbar/entfernbar: $($_.Exception.Message)" }
    try { Initialize-HMFs } catch { return "FEHLER: nichts geloescht - Pruefung nicht moeglich: $($_.Exception.Message)" }
    $bad = @([HMFs.Tree]::CheckDeletable($Path, 5))
    if ($bad.Count) {
        return ("FEHLER: nichts geloescht - {0}{1}. Rechte des Backup-Ordners pruefen bzw. geoeffnete Dateien schliessen." -f ($bad -join '; '), $(if ($bad.Count -ge 5) { ' ...' } else { '' }))
    }
    $bad = @([HMFs.Tree]::Delete($Path, 5))
    if ($bad.Count) { return ("FEHLER: Loeschen unvollstaendig - {0}. Backup-Rest bitte noch einmal loeschen." -f ($bad -join '; ')) }
    return 'OK'
}

# ============================================================================
# FORTLAUFENDES BACKUP: AN DER QUELLE GELOESCHTE DATEIEN BEISEITELEGEN
# ============================================================================
# Ein fortlaufendes Backup kopiert nur Neues/Geaendertes. Am Quell-PC geloeschte Dateien wuerden im Backup bleiben und beim
# Restore zurueckkommen. Sie werden deshalb nach <Backup>\_GELOESCHT\<Zeitpunkt>\<Modul>\... verschoben: nichts geht verloren
# (Im Backup suchen > "mit geloeschten"), der Restore bringt aber nur den aktuellen Stand. Nach X Tagen (Einstellung) entfernt.
$script:HMDeletedDirName = '_GELOESCHT'
$script:HMFsMoveCs = @'
using System;
using System.Runtime.InteropServices;

namespace HMFs
{
    public static class Mover
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
        [DllImport("kernel32.dll")] static extern bool FindClose(IntPtr h);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern uint GetFileAttributesW(string n);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool MoveFileExW(string a, string b, uint flags);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool CreateDirectoryW(string n, IntPtr sa);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool RemoveDirectoryW(string n);
        static readonly IntPtr INVALID = new IntPtr(-1);
        const uint NOATTR = 0xFFFFFFFFu;

        static string L(string p)
        {
            if (p.StartsWith(@"\\?\")) return p;
            if (p.StartsWith(@"\\")) return @"\\?\UNC\" + p.Substring(2);
            return @"\\?\" + p;
        }
        static string Parent(string p)
        {
            p = p.TrimEnd('\\');
            int i = p.LastIndexOf('\\');
            return i > 2 ? p.Substring(0, i) : null;
        }
        static bool Under(string p, string root)
        {
            return p.Length > root.Length && p.StartsWith(root + "\\", StringComparison.OrdinalIgnoreCase);
        }

        // Gibt es den Pfad an der Quelle? 1 = vorhanden, 0 = sicher nicht vorhanden (der naechste vorhandene Ordner darueber
        // ist lesbar), -1 = unsicher (kein Zugriff, Netzwerkfehler, ...). Nur bei 0 darf die Backup-Kopie beiseitegelegt werden.
        public static int Probe(string path, string stopAt)
        {
            stopAt = stopAt.TrimEnd('\\');
            path = path.TrimEnd('\\');
            if (!Under(path, stopAt)) return -1;
            if (GetFileAttributesW(L(path)) != NOATTR) return 1;
            int err = Marshal.GetLastWin32Error();
            if (err != 2 && err != 3) return -1;
            string d = Parent(path);
            while (d != null && d.Length >= stopAt.Length)
            {
                uint a = GetFileAttributesW(L(d));
                if (a != NOATTR)
                {
                    if ((a & 0x10) == 0) return -1;
                    WIN32_FIND_DATA fd;
                    IntPtr h = FindFirstFileW(L(d) + @"\*", out fd);
                    if (h == INVALID) return -1;
                    FindClose(h);
                    return 0;
                }
                int e = Marshal.GetLastWin32Error();
                if (e != 2 && e != 3) return -1;
                if (d.Length == stopAt.Length) return -1;   // nicht einmal der Quellordner ist erreichbar
                d = Parent(d);
            }
            return -1;
        }
        static void EnsureDir(string d)
        {
            if (d == null || GetFileAttributesW(L(d)) != NOATTR) return;
            EnsureDir(Parent(d));
            CreateDirectoryW(L(d), IntPtr.Zero);
        }
        // Datei verschieben (lange Pfade, schreibgeschuetzt ok, nie ueberschreiben). Rueckgabe 0 = OK, sonst Win32-Fehler
        public static int Move(string src, string dst)
        {
            EnsureDir(Parent(dst));
            if (MoveFileExW(L(src), L(dst), 0x8)) return 0;   // MOVEFILE_WRITE_THROUGH, kein REPLACE_EXISTING
            return Marshal.GetLastWin32Error();
        }
        // leere Ordner nach oben entfernen (nur unterhalb von stopAt; nicht leere bleiben - RemoveDirectory schlaegt dann fehl)
        public static void RemoveEmptyUp(string dir, string stopAt)
        {
            stopAt = stopAt.TrimEnd('\\');
            string d = dir.TrimEnd('\\');
            while (d != null && Under(d, stopAt))
            {
                if (!RemoveDirectoryW(L(d))) break;
                d = Parent(d);
            }
        }
    }
}
'@
function Initialize-HMFsMove { if (-not ('HMFs.Mover' -as [type])) { Add-Type -TypeDefinition $script:HMFsMoveCs -ErrorAction Stop } }

# Dateien im Backup finden, die es an der Quelle nicht (mehr) gibt: Robocopy in GEGENRICHTUNG (Backup -> Quelle), nur auflisten (/L).
# /XO /XN /XC schliessen an beiden Seiten vorhandene Dateien aus, /XX die nur an der Quelle vorhandenen - uebrig bleiben genau die
# Dateien, die nur im Backup liegen. Gleiche Ausschluesse wie beim Backup (Robocopy schuetzt per /XF und /XD ausgeschlossene Dateien
# auch auf der Gegenseite), damit Ausgeschlossenes, Nur-Cloud- und Cloud-Ordner nie als "geloescht" gelten.
# Ausgabe mit /FP /NC /NS: nur volle Pfade, ohne Klassen-Text -> unabhaengig von der Windows-Sprache.
function Find-HMDeletedInBackup {
    param([string]$Backup, [string]$Source, [string[]]$Files = @(), [string[]]$XD = @(), [string[]]$XF = @(), [switch]$NoRecurse, [switch]$NoHidden, $Job)
    $q = { param($p) $p = $p.TrimEnd('\'); if ($p -match '^[A-Za-z]:$') { $p += '\.' }; '"' + $p + '"' }
    $a = New-Object System.Collections.Generic.List[string]
    $a.Add((& $q $Backup)); $a.Add((& $q $Source))
    foreach ($f in $Files) { $a.Add('"' + $f + '"') }
    if (-not $NoRecurse) { $a.Add('/E') }
    foreach ($o in @('/L', '/XO', '/XN', '/XC', '/XX', '/XJ', '/R:0', '/W:0', '/NP', '/NDL', '/NJH', '/NJS', '/NC', '/NS', '/FP')) { $a.Add($o) }
    if ($NoHidden) { $a.Add('/XA:SHO') } else { $a.Add('/XA:O') }
    if (@($XD).Count) { $a.Add('/XD'); foreach ($x in $XD) { $a.Add('"' + "$x".TrimEnd('\') + '"') } }
    if (@($XF).Count) { $a.Add('/XF'); foreach ($x in $XF) { $a.Add('"' + $x + '"') } }
    $tmpLog = [System.IO.Path]::Combine($env:TEMP, "HMdel_$([guid]::NewGuid().ToString('N')).log")
    $a.Add("/UNILOG:`"$tmpLog`"")
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $env:windir 'System32\Robocopy.exe'
    $psi.Arguments = ($a -join ' ')
    if ($psi.Arguments.Length -gt 30000) { return [pscustomobject]@{ ExitCode = 16; Paths = @() } }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    while (-not $proc.WaitForExit(400)) { if ($Job -and (Test-HMCancel $Job)) { try { $proc.Kill() } catch { }; break } }
    $proc.WaitForExit()
    $code = $proc.ExitCode
    if ($Job -and (Test-HMCancel $Job)) { $code = 16 }
    $text = ''
    if (Test-Path -LiteralPath $tmpLog) {
        try { $text = [System.IO.File]::ReadAllText($tmpLog, [System.Text.Encoding]::Unicode) } catch { $code = 16 }
        Remove-Item -LiteralPath $tmpLog -Force -ErrorAction SilentlyContinue
    }
    $root = $Backup.TrimEnd('\') + '\'
    $paths = @(foreach ($line in ($text -split "`r?`n")) { $t = $line.Trim(); if ($t.Length -gt $root.Length -and $t.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { $t } })
    return [pscustomobject]@{ ExitCode = $code; Paths = $paths }
}

# An der Quelle geloeschte Dateien eines Eintrags im Backup beiseitelegen. Jede Datei wird vorher einzeln an der Quelle geprueft:
# nur wenn sie dort sicher fehlt (Ordner darueber lesbar), wird sie verschoben - bei jedem Zweifel bleibt sie liegen.
function Move-HMDeletedFromBackup {
    param([hashtable]$Ctx, $Job, [string]$Src, [string]$Dst, [string[]]$Files = @(), [string[]]$XD = @(), [string[]]$XF = @(), [switch]$NoRecurse, [switch]$NoHidden,
          [int]$TotalFiles = -1, [int]$MassPercent = 20, [int]$MassMin = 50)
    $res = [pscustomobject]@{ Moved = 0; Kept = 0; Failed = 0; Error = ''; Mass = $false; Count = 0; Total = 0 }
    try { Initialize-HMFsMove } catch { $res.Error = "Pruefung nicht moeglich: $($_.Exception.Message)"; return $res }
    $s0 = $Src.TrimEnd('\'); $d0 = $Dst.TrimEnd('\')
    # Ausschluesse mit vollem Quellpfad auf die Backup-Seite umschreiben (Namen/Muster gelten unveraendert)
    $map = {
        param($p)
        $t = "$p".TrimEnd('\')
        if ($t -notmatch '[\*\?]' -and ($t -ieq $s0 -or $t.StartsWith($s0 + '\', [StringComparison]::OrdinalIgnoreCase))) { return $d0 + $t.Substring($s0.Length) }
        return "$p"
    }
    $xd2 = @($XD | Where-Object { $_ } | ForEach-Object { & $map $_ })
    $xf2 = @($XF | Where-Object { $_ } | ForEach-Object { & $map $_ })
    $f = Find-HMDeletedInBackup -Backup $d0 -Source $s0 -Files $Files -XD $xd2 -XF $xf2 -NoRecurse:$NoRecurse -NoHidden:$NoHidden -Job $Job
    if ($f.ExitCode -ge 8) { $res.Error = "Vergleich mit der Quelle nicht moeglich (Robocopy-Code $($f.ExitCode))"; return $res }
    # Schutz vor Massenloeschung: fehlen auf einmal ungewoehnlich viele Dateien (typisch fuer Verschluesselungstrojaner, die Originale
    # durch verschluesselte Kopien mit neuem Namen ersetzen, oder fuer einen verschobenen Ordner), wird NICHTS beiseitegelegt
    $n = @($f.Paths).Count
    if ($TotalFiles -ge 0 -and $MassPercent -gt 0 -and $n -ge $MassMin) {
        $all = [Math]::Max(1, $TotalFiles + $n)
        if (($n * 100) -gt ($MassPercent * $all)) { $res.Mass = $true; $res.Count = $n; $res.Total = $all; return $res }
    }
    $bp = "$($Ctx.BackupPath)".TrimEnd('\')
    foreach ($p in @($f.Paths)) {
        if ($Job -and (Test-HMCancel $Job)) { break }
        $rel = $p.Substring($d0.Length).TrimStart('\')
        if (-not $rel -or -not $p.StartsWith($bp + '\', [StringComparison]::OrdinalIgnoreCase)) { $res.Kept++; continue }
        if ([HMFs.Mover]::Probe("$s0\$rel", $s0) -ne 0) { $res.Kept++; continue }
        if (-not $Ctx.DeletedDir) { $Ctx.DeletedDir = "$bp\$($script:HMDeletedDirName)\$(Get-Date -Format 'yyyyMMdd_HHmmss')" }
        $e = [HMFs.Mover]::Move($p, "$($Ctx.DeletedDir)\$($p.Substring($bp.Length + 1))")
        if ($e -eq 0) { $res.Moved++; [HMFs.Mover]::RemoveEmptyUp((Split-Path $p -Parent), $d0) } else { $res.Failed++ }
    }
    return $res
}

# Beiseitegelegte Dateien aelter als $Days Tage entfernen (0 = nie). Rueckgabe: Anzahl entfernter Laeufe bzw. Fehlertexte
function Remove-HMDeletedExpired([string]$BackupPath, [int]$Days) {
    $out = [pscustomobject]@{ Removed = 0; Errors = @() }
    if ($Days -le 0) { return $out }
    $g = Join-Path $BackupPath $script:HMDeletedDirName
    if (-not (Test-Path -LiteralPath $g)) { return $out }
    $limit = (Get-Date).AddDays(-$Days)
    foreach ($d in @(Get-ChildItem -LiteralPath $g -Directory -Force -ErrorAction SilentlyContinue)) {
        $t = [datetime]::MinValue
        if ($d.Name -notmatch '^\d{8}_\d{6}$' -or -not [datetime]::TryParseExact($d.Name, 'yyyyMMdd_HHmmss', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$t)) { continue }
        if ($t -ge $limit) { continue }
        $r = Remove-HMBackupFolder $d.FullName
        if ($r -eq 'OK') { $out.Removed++ } else { $out.Errors += "$($d.Name): $r" }
    }
    if (-not @(Get-ChildItem -LiteralPath $g -Force -ErrorAction SilentlyContinue).Count) { try { [System.IO.Directory]::Delete($g, $false) } catch { } }
    return $out
}

# Anzahl/Groesse der beiseitegelegten Dateien eines Backups (fuer Backup-Liste, Restore-Hinweis)
function Get-HMDeletedInfo([string]$BackupPath) {
    $g = Join-Path $BackupPath $script:HMDeletedDirName
    $n = 0; $s = [long]0
    if (Test-Path -LiteralPath $g) { foreach ($x in @(Get-ChildItem -LiteralPath $g -Recurse -File -Force -ErrorAction SilentlyContinue)) { $n++; $s += [long]$x.Length } }
    return [ordered]@{ Files = $n; Bytes = $s }
}
# Wert "Deleted" im manifest.json eines Backups neu zaehlen (nach "Geloeschte leeren"); $ClearAlert = Massenloeschungs-Hinweis entfernen
function Update-HMManifestDeleted([string]$BackupPath, [switch]$ClearAlert) {
    $mf = Join-Path $BackupPath 'manifest.json'
    if (-not (Test-Path -LiteralPath $mf)) { return }
    $m = Get-Content -LiteralPath $mf -Raw -Encoding UTF8 | ConvertFrom-Json
    $h = [ordered]@{}
    foreach ($p in $m.PSObject.Properties) { $h[$p.Name] = $p.Value }
    $h.Deleted = Get-HMDeletedInfo $BackupPath
    if ($ClearAlert -and $h.Contains('MassDeleteAlert')) { $h.Remove('MassDeleteAlert') }
    $tmp = "$mf.tmp"
    [System.IO.File]::WriteAllText($tmp, ([pscustomobject]$h | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($true)))
    Move-Item -LiteralPath $tmp -Destination $mf -Force
}

# Eintrag schreibt beim Restore ausserhalb des Profils (Programme, Windows, HKLM) -> braucht Administratorrechte
function Test-HMItemNeedsAdmin($Item) {
    switch ("$($Item.Type)") {
        'Reg' { return ("$($Item.Key)" -match '^HK(LM|EY_LOCAL_MACHINE)') }
        { $_ -in @('Folder', 'Files') } { return ("$($Item.Path)" -match '^\{(PROGRAMFILES\w*|PROGRAMDATA|WINDIR|SYSTEMDRIVE|PUBLIC)\}' -or "$($Item.Path)" -match '^[A-Za-z]:\\(Windows|Program Files|ProgramData)') }
        default { return $false }
    }
}

# Dauer lesbar: "45 s", "3 min 20 s", "12 min", "6 h 12 min" - Wert: TimeSpan oder Minuten (Zahl)
function Format-HMDuration($Value) {
    if ($null -eq $Value -or "$Value" -eq '') { return '' }
    try { $ts = if ($Value -is [TimeSpan]) { $Value } else { [TimeSpan]::FromMinutes([double]$Value) } } catch { return "$Value" }
    $s = [long][Math]::Round($ts.TotalSeconds)
    if ($s -lt 60) { return "$s s" }
    $h = [long][Math]::Floor($s / 3600); $m = [long][Math]::Floor(($s % 3600) / 60); $sec = $s % 60
    if ($h -gt 0) { return "$h h $m min" }
    if ($m -lt 10 -and $sec) { return "$m min $sec s" }
    return "$m min"
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
# Darf jemand ausser Administratoren/SYSTEM/TrustedInstaller/Ersteller-Besitzer hier schreiben oder anlegen?
# Rueckgabe: '' = sicher, sonst Text (Konto: Recht). Datei: Schreibrechte auf die Datei; Ordner: auch Anlegen von Dateien/Ordnern.
function Get-HMWritableByNonAdmins([string]$Path) {
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    $safe = @('S-1-5-18', 'S-1-5-32-544', 'S-1-3-0', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    $w = [System.Security.AccessControl.FileSystemRights]'WriteData, AppendData, WriteExtendedAttributes, WriteAttributes, Delete, ChangePermissions, TakeOwnership'
    $out = @()
    foreach ($r in @($acl.Access)) {
        if ("$($r.AccessControlType)" -ne 'Allow') { continue }
        if (([int]$r.FileSystemRights -band [int]$w) -eq 0) { continue }
        $sid = ''
        try { $sid = $r.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value } catch { $sid = "$($r.IdentityReference)" }
        if ($safe -contains $sid) { continue }
        # einzelnes Konto, das selbst Administrator ist (z.B. der Installierende), ist unkritisch
        try { $nt = $r.IdentityReference.Translate([System.Security.Principal.NTAccount]).Value } catch { $nt = "$($r.IdentityReference)" }
        if ($sid -like 'S-1-5-21-*' -and $sid -notmatch '-(513|515|545)$') {
            $isAdm = $false
            try { $isAdm = [bool](@(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop | Where-Object { "$($_.SID)" -eq $sid }).Count) } catch { }
            if ($isAdm) { continue }
        }
        $out += "$nt`: $($r.FileSystemRights)"
    }
    return (@($out | Select-Object -Unique) -join '; ')
}

function Test-HMIsLocal([string]$Computer) {
    if ([string]::IsNullOrWhiteSpace($Computer)) { return $true }
    $c = $Computer.Trim().ToUpper()
    if ($c -in @('.', 'LOCALHOST', '127.0.0.1', $env:COMPUTERNAME.ToUpper())) { return $true }
    if ($c -like "$($env:COMPUTERNAME.ToUpper()).*") { return $true }
    return $false
}

# Scriptblock am Ziel-PC ausfuehren (lokal direkt, remote per Invoke-Command)
# Schutz von %ProgramData%\HUMig am Ziel-PC (Functions\Core-Protect.ps1) - als Text, damit er auch per Invoke-Command laeuft
$script:HMProtectText = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Core-Protect.ps1')) -replace '(?m)^#Requires.*$', ''
. ([scriptblock]::Create($script:HMProtectText))
# Wie Invoke-HMTarget, sichert aber vorher %ProgramData%\HUMig am Ziel ab. Gelingt das nicht: Fehler (Standard) bzw. mit -Soft
# weiterlaufen - das Skript sieht dann $HMProtected = $false und darf dort nichts Sicherheitsrelevantes ablegen oder lesen.
# Benutzer-Modus: ohne Absicherung (keine Adminrechte; dort wird ProgramData\HUMig nicht beschrieben)
function Invoke-HMTargetProtected {
    param([hashtable]$Ctx, [scriptblock]$Script, [object[]]$ArgumentList = @(), [switch]$Soft)
    if ($Ctx -and $Ctx.UserMode) { return (Invoke-HMTarget $Ctx $Script $ArgumentList) }
    $pre = if ($Soft) { "try { [void](Protect-HMDataDir); `$HMProtected = `$true } catch { `$HMProtected = `$false; `$HMProtectError = `$_.Exception.Message }" } else { "[void](Protect-HMDataDir); `$HMProtected = `$true" }
    $sb = [scriptblock]::Create($script:HMProtectText + "`r`n" + $pre + "`r`n& {" + $Script.ToString() + "`r`n} @args")
    return (Invoke-HMTarget $Ctx $sb $ArgumentList)
}

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

# Vermerk fuer von HUMig geladene Benutzer-Registry (NTUSER.DAT): %ProgramData%\HUMig\HiveMounts\<SID>.txt am Ziel-PC
# (Rechner|PID|Startzeit des ladenden HUMig, Zeitpunkt). Wird HUMig hart beendet (Task-Manager, Absturz), bleibt der Hive geladen
# und der Benutzer bekommt bei der Anmeldung ein temporaeres Profil -> beim naechsten Start bzw. vor dem naechsten Laden entladen.
# Entladen nur, wenn: Vermerk vorhanden, Hive geladen, Benutzer NICHT angemeldet und das ladende HUMig nicht mehr laeuft.
$script:HMHiveCleanupText = @'
$md = Join-Path $env:ProgramData 'HUMig\HiveMounts'
if (-not (Test-Path -LiteralPath $md)) { return }
$logged = @(foreach ($p in @(Get-CimInstance -ClassName Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue)) {
        try { "$((Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid -ErrorAction Stop).Sid)" } catch { } })
foreach ($f in @(Get-ChildItem -LiteralPath $md -Filter '*.txt' -File -ErrorAction SilentlyContinue)) {
    $s = $f.BaseName
    if ($s -notmatch '^S-1-[0-9-]+$') { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue; continue }
    if (-not (Test-Path -LiteralPath "Registry::HKEY_USERS\$s")) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue; continue }
    if ($logged -contains $s) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue; "Benutzer-Registry ${s}: Benutzer angemeldet - bleibt geladen (gehoert jetzt der Anmeldung)"; continue }
    # laeuft das HUMig noch, das den Hive geladen hat? (Rechner|PID|Startzeit)
    $m = "$(Get-Content -LiteralPath $f.FullName -TotalCount 1 -ErrorAction SilentlyContinue)".Split('|')
    if ($m.Count -ge 3 -and $m[0] -ieq $env:COMPUTERNAME) {
        $pr = Get-Process -Id ([int]$m[1]) -ErrorAction SilentlyContinue
        if ($pr) { $st = ''; try { $st = $pr.StartTime.ToString('yyyyMMddHHmmss') } catch { }; if ($st -eq $m[2]) { continue } }
    } else {
        # von einem anderen PC aus geladen (Fernzugriff): ob dort HUMig noch laeuft, ist hier nicht pruefbar -> erst nach 24 h als verwaist behandeln
        if (((Get-Date) - $f.LastWriteTime).TotalHours -lt 24) { continue }
    }
    [GC]::Collect(); [GC]::WaitForPendingFinalizers()
    $o = & reg.exe unload "HKU\$s" 2>&1
    if ($LASTEXITCODE -eq 0) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue; "Benutzer-Registry $s war nach einem Abbruch noch geladen - jetzt entladen" }
    else { "Benutzer-Registry $s ist noch geladen (von einem abgebrochenen Vorgang), Entladen fehlgeschlagen: $o - Neustart des PCs vor der Anmeldung dieses Benutzers" }
}
'@
function Clear-HMStaleHives([hashtable]$Ctx) {
    $sb = [scriptblock]::Create($script:HMHiveCleanupText)
    if ($Ctx) {
        return @(Invoke-HMTargetProtected $Ctx { param($t)
                if (-not $HMProtected) { "ProgramData\HUMig nicht absicherbar ($HMProtectError) - verwaiste Benutzer-Registry wird nicht geprueft"; return }
                & ([scriptblock]::Create($t)) } @($script:HMHiveCleanupText) -Soft)
    }
    try { [void](Protect-HMDataDir) } catch { return @("ProgramData\HUMig nicht absicherbar ($($_.Exception.Message)) - verwaiste Benutzer-Registry wird nicht geprueft") }
    return @(& $sb)
}

function Test-HMHiveLoaded([hashtable]$Ctx, [string]$Sid) {
    return [bool](Invoke-HMTarget $Ctx { param($s) Test-Path -LiteralPath "Registry::HKEY_USERS\$s" } @($Sid))
}

# Hive des Benutzers unter HKU\<SID> verfuegbar machen (laden, wenn nicht angemeldet)
function Mount-HMHive {
    param([hashtable]$Ctx, $Job, [string]$Sid, [string]$ProfilePath)
    # zuerst verwaiste, von einem abgebrochenen HUMig geladene Hives entladen (sonst wuerde ein solcher als 'angemeldet' gelten)
    # Benutzer-Modus (ohne Adminrechte): ProgramData\HUMig ist nicht absicherbar und fremde Hives sind ohnehin nicht entladbar - nicht pruefen
    if (-not $Ctx.UserMode) { try { foreach ($l in @(Clear-HMStaleHives $Ctx | Where-Object { $_ })) { Write-HMLog $Job "$l" 'Warning' } } catch { } }
    if (Test-HMHiveLoaded $Ctx $Sid) { Write-HMLog $Job "Benutzer-Registry ist geladen (Benutzer angemeldet)" 'Debug'; return $true }
    $st0 = ''; try { $st0 = (Get-Process -Id $PID).StartTime.ToString('yyyyMMddHHmmss') } catch { }
    $mark = "$env:COMPUTERNAME|$PID|$st0|$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))"
    $r = Invoke-HMTargetProtected -Soft $Ctx {
        param($s, $pp, $mk)
        $dat = Join-Path $pp 'NTUSER.DAT'
        if (-not (Test-Path -LiteralPath $dat)) { return "FEHLER: $dat nicht gefunden" }
        $out = & reg.exe load "HKU\$s" "$dat" 2>&1
        if ($LASTEXITCODE -ne 0) { return "FEHLER: reg load: $out" }
        if ($HMProtected) { try {
            $md = Join-Path $env:ProgramData 'HUMig\HiveMounts'
            New-Item -ItemType Directory -Path $md -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $md "$s.txt") -Value $mk -Encoding ASCII
        } catch { } }
        return 'OK'
    } @($Sid, $ProfilePath, $mark)
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
            if ($LASTEXITCODE -eq 0) { Remove-Item -LiteralPath (Join-Path $env:ProgramData "HUMig\HiveMounts\$s.txt") -Force -ErrorAction SilentlyContinue; return 'OK' }
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
# PROGRAMM-KATALOG: Programm vorher schliessen (CloseProcess), Dienst stoppen (StopService), Datenbanken
# ============================================================================
# Laufende Prozesse (Namen ohne .exe) des Zielbenutzers am Ziel-PC. OwnSession = nur Prozesse der eigenen Sitzung (Benutzer-Modus)
$script:HMProcScript = {
    param([string[]]$Names, [string]$Sid, [bool]$OwnSession)
    $mySess = (Get-Process -Id $PID).SessionId
    foreach ($n in @($Names | Where-Object { $_ })) {
        foreach ($p in @(Get-Process -Name ("$n" -replace '\.exe$', '') -ErrorAction SilentlyContinue)) {
            $ok = $true
            if ($OwnSession) { $ok = ($p.SessionId -eq $mySess) }
            elseif ($Sid) {
                try {
                    $w = Get-CimInstance Win32_Process -Filter "ProcessId=$($p.Id)" -ErrorAction Stop
                    $o = Invoke-CimMethod -InputObject $w -MethodName GetOwnerSid -ErrorAction Stop
                    if ("$($o.Sid)") { $ok = ("$($o.Sid)" -eq $Sid) }
                } catch { $ok = $true }   # Besitzer nicht lesbar -> vorsichtshalber als "laeuft" werten
            }
            if ($ok) { [pscustomobject]@{ Name = "$($p.ProcessName)"; Id = [int]$p.Id; SessionId = [int]$p.SessionId; Title = "$($p.MainWindowTitle)" } }
        }
    }
}
function Get-HMRunningProcs([hashtable]$Ctx, [string[]]$Names, [string]$Sid) {
    $n = @($Names | Where-Object { "$_".Trim() } | ForEach-Object { "$_".Trim() -replace '\.exe$', '' } | Select-Object -Unique)
    if (-not $n.Count) { return @() }
    return @(Invoke-HMTarget $Ctx $script:HMProcScript @($n, $Sid, [bool]$Ctx.UserMode) | Where-Object { $_ })
}

# Programme sanft schliessen (Fenster schliessen wie der Benutzer), nach Timeout optional hart beenden.
# Gleiche Sitzung: CloseMainWindow direkt. Andere Sitzung/Remote: einmalige Aufgabe in der Sitzung des Benutzers.
$script:HMCloseInSessionScript = {
    param([string]$Acct, [int[]]$Ids)
    $mySess = (Get-Process -Id $PID).SessionId
    $direct = @(); $other = @()
    foreach ($i in $Ids) { $p = Get-Process -Id $i -ErrorAction SilentlyContinue; if ($p) { if ($p.SessionId -eq $mySess) { $direct += $p } else { $other += $i } } }
    foreach ($p in $direct) { try { [void]$p.CloseMainWindow() } catch { } }
    if ($other.Count -and $Acct) {
        $code = "foreach (`$i in @($($other -join ','))) { try { `$p = Get-Process -Id `$i -ErrorAction Stop; [void]`$p.CloseMainWindow() } catch { } }"
        $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
        $n = 'HUMig_Close_' + [guid]::NewGuid().ToString('N')
        try {
            $a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand $enc"
            $pr = New-ScheduledTaskPrincipal -UserId $Acct -LogonType Interactive -RunLevel Limited
            $s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
            Register-ScheduledTask -TaskName $n -Action $a -Principal $pr -Settings $s -Force -ErrorAction Stop | Out-Null
            Start-ScheduledTask -TaskName $n
            Start-Sleep -Seconds 3
        } catch { } finally { Unregister-ScheduledTask -TaskName $n -Confirm:$false -ErrorAction SilentlyContinue }
    }
}
function Close-HMProcs([hashtable]$Ctx, $Job, [object[]]$Procs, [bool]$Force, [int]$TimeoutSec = 20) {
    $ids = @($Procs | ForEach-Object { [int]$_.Id } | Select-Object -Unique)
    if (-not $ids.Count) { return @() }
    try { Invoke-HMTarget $Ctx $script:HMCloseInSessionScript @("$($Ctx.Account)", $ids) | Out-Null } catch { Write-HMLog $Job "      Schliessen nicht moeglich: $($_.Exception.Message)" 'Debug' }
    $left = $ids
    $t0 = Get-Date
    while ($left.Count -and ((Get-Date) - $t0).TotalSeconds -lt $TimeoutSec -and -not (Test-HMCancel $Job)) {
        Start-Sleep -Milliseconds 700
        $left = @(Invoke-HMTarget $Ctx { param($x) foreach ($i in $x) { if (Get-Process -Id $i -ErrorAction SilentlyContinue) { $i } } } @(, $ids) | Where-Object { $_ })
    }
    if ($left.Count -and $Force) {
        try { Invoke-HMTarget $Ctx { param($x) foreach ($i in $x) { Stop-Process -Id $i -Force -ErrorAction SilentlyContinue } } @(, $left) | Out-Null } catch { }
        Start-Sleep -Seconds 2
        $left = @(Invoke-HMTarget $Ctx { param($x) foreach ($i in $x) { if (Get-Process -Id $i -ErrorAction SilentlyContinue) { $i } } } @(, $left) | Where-Object { $_ })
    }
    return @($left)
}

# SQLite: zur Datenbankdatei gehoerende Begleitdateien (-wal, -shm, -journal) immer mitkopieren
function Add-HMDbCompanions([string[]]$Filter) {
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($f in @($Filter | Where-Object { $_ })) {
        if (-not $out.Contains($f)) { $out.Add($f) }
        if ($f -match '-(wal|shm|journal)$') { continue }
        foreach ($s in @('-wal', '-shm', '-journal')) { if (-not $out.Contains("$f$s")) { $out.Add("$f$s") } }
    }
    return $out.ToArray()
}
function Test-HMServiceItem($Item) { return ("$($Item.Role)" -eq 'Database' -and "$($Item.DbKind)" -eq 'Service') }

# Vor einem Modul: Programm schliessen, Dienste stoppen, Access-Sperrdateien pruefen.
# Rueckgabe: @{ Skip; Warn (Liste); Info (Hinweise); LockedHint; ProcAction; ServiceAction; Stopped (Dienste zum Wiederstarten); SkipServiceItems }
function Enter-HMModule([hashtable]$Ctx, $Job, $Module, [hashtable]$TEnv, [string]$Phase) {
    $st = @{ Skip = $false; Warn = @(); Info = @(); LockedHint = $false; ProcAction = ''; ServiceAction = ''; Stopped = @(); SkipServiceItems = $false }
    # --- Programm schliessen ---
    $names = @($Module.CloseProcess | Where-Object { "$_".Trim() })
    if ($names.Count) {
        $run = @()
        try { $run = @(Get-HMRunningProcs $Ctx $names $Ctx.UserSid) } catch { Write-HMLog $Job "   Laufende Programme nicht pruefbar: $($_.Exception.Message)" 'Debug' }
        if ($run.Count) {
            $pn = (@($run | ForEach-Object { $_.Name } | Select-Object -Unique) -join ', ')
            $dec = ''
            if ($Ctx.ProcDecisions -and $Ctx.ProcDecisions.ContainsKey("$($Module.Id)")) { $dec = "$($Ctx.ProcDecisions["$($Module.Id)"])" }
            # ohne Abfrage (geplantes Backup, Mehrfachaktion): Module mit CloseDefault = Copy (Browser) trotzdem kopieren statt auslassen -
            # Browser laufen oft dauerhaft im Hintergrund; gesperrte Dateien (z.B. Cookies) fehlen dann im Backup
            elseif ("$($Module.CloseDefault)" -eq 'Copy') { $dec = 'Copy' }
            # Restore eines Browsers: immer schliessen (notfalls beenden) - ein laufender Browser ueberschreibt die zurueckgespielten Dateien
            if ($Phase -eq 'Restore' -and (Test-HMBrowserModule $Module)) { $dec = 'CloseForce' }
            switch ($dec) {
                'Copy' {
                    $st.ProcAction = 'trotzdem kopiert'
                    if ($Phase -eq 'Backup' -and "$($Module.CloseDefault)" -eq 'Copy') {
                        # Browser: laufen oft dauerhaft - vom Programm gesperrte Dateien (Cookies, Sitzung) sind nur ein Hinweis, kein Fehler
                        $st.LockedHint = $true
                        $st.Info += "$pn lief - trotzdem kopiert; vom Programm gesperrte Dateien (z.B. Cookies, Sitzung) fehlen evtl. - fuer eine vollstaendige Sicherung vorher schliessen"
                    } else { $st.Warn += "$pn lief - trotzdem kopiert (Daten evtl. nicht aktuell/inkonsistent)" }
                }
                { $_ -in @('Close', 'CloseForce') } {
                    Write-HMLog $Job "   $pn wird geschlossen ..." 'Info'
                    $left = @(Close-HMProcs $Ctx $Job $run ($dec -eq 'CloseForce'))
                    if ($left.Count) {
                        $st.Skip = $true; $st.ProcAction = 'uebersprungen (liess sich nicht schliessen)'
                        $st.Warn += "$pn liess sich nicht schliessen - Modul uebersprungen"
                    } else {
                        $st.ProcAction = $(if ($dec -eq 'CloseForce') { 'geschlossen (notfalls beendet)' } else { 'geschlossen' })
                        Write-HMLog $Job "   $pn geschlossen" 'Success'
                    }
                }
                default {
                    # keine Entscheidung (geplantes Backup, Programm erst nach der Abfrage gestartet) oder "Ueberspringen": nie hart beenden
                    $st.Skip = $true; $st.ProcAction = 'uebersprungen (Programm lief)'
                    $st.Warn += "$pn laeuft - Modul uebersprungen (Programm vorher schliessen)"
                }
            }
        }
    }
    if ($st.Skip) { return $st }
    # --- Dienste stoppen (Dienst-Datenbanken) ---
    $svc = @($Module.StopService | Where-Object { "$_".Trim() } | ForEach-Object { "$_".Trim() })
    if ($svc.Count) {
        if ($Ctx.UserMode) {
            $st.SkipServiceItems = $true; $st.ServiceAction = 'nicht gestoppt (Benutzer-Modus)'
            $st.Warn += "Dienst-Datenbank nur als Administrator: $($svc -join ', ') nicht gestoppt, Datenbank-Dateien ausgelassen"
        } else {
            try {
                $r = @(Invoke-HMTarget $Ctx {
                    param([string[]]$Names)
                    foreach ($n in $Names) {
                        $s = Get-Service -Name $n -ErrorAction SilentlyContinue
                        if (-not $s) { [pscustomobject]@{ Name = $n; Result = 'Missing'; Msg = '' }; continue }
                        if ("$($s.Status)" -ne 'Running') { [pscustomobject]@{ Name = $n; Result = 'NotRunning'; Msg = "$($s.Status)" }; continue }
                        try {
                            Stop-Service -Name $n -Force -ErrorAction Stop
                            $s.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(60))
                            [pscustomobject]@{ Name = $n; Result = 'Stopped'; Msg = '' }
                        } catch { [pscustomobject]@{ Name = $n; Result = 'Failed'; Msg = $_.Exception.Message } }
                    }
                } @(, $svc))
                foreach ($x in $r) {
                    switch ("$($x.Result)") {
                        'Stopped'    { $st.Stopped += "$($x.Name)"; Write-HMLog $Job "   Dienst $($x.Name) gestoppt" 'Info' }
                        'NotRunning' { Write-HMLog $Job "   Dienst $($x.Name) laeuft nicht ($($x.Msg))" 'Debug' }
                        'Missing'    { Write-HMLog $Job "   Dienst $($x.Name) gibt es an $($Ctx.Computer) nicht" 'Debug' }
                        default      { $st.SkipServiceItems = $true; $st.Warn += "Dienst $($x.Name) liess sich nicht stoppen ($($x.Msg)) - Datenbank-Dateien ausgelassen" }
                    }
                }
                $st.ServiceAction = $(if ($st.Stopped.Count) { "gestoppt und wieder gestartet: $($st.Stopped -join ', ')" } elseif ($st.SkipServiceItems) { 'nicht gestoppt' } else { 'lief nicht' })
            } catch {
                $st.SkipServiceItems = $true; $st.ServiceAction = 'Fehler'
                $st.Warn += "Dienste nicht steuerbar: $($_.Exception.Message) - Datenbank-Dateien ausgelassen"
            }
        }
    }
    # --- Access-Datenbank geoeffnet? (Sperrdatei .laccdb/.ldb neben der Datenbank) ---
    if ($Phase -eq 'Backup' -and $TEnv) {
        foreach ($it in @($Module.Items | Where-Object { "$($_.Role)" -eq 'Database' -and "$($_.DbKind)" -ne 'Service' -and $_.Path })) {
            try {
                $p = Convert-HMPath $Ctx (Resolve-HMToken $TEnv $it.Path)
                if (-not (Test-Path -LiteralPath $p -PathType Container)) { continue }
                $lk = @(Get-ChildItem -LiteralPath $p -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.laccdb', '.ldb') } | Select-Object -First 3)
                if ($lk.Count) { $st.Warn += "Datenbank vermutlich geoeffnet (Sperrdatei $(@($lk | ForEach-Object { $_.Name }) -join ', ')) - Kopie evtl. inkonsistent" }
            } catch { }
        }
    }
    return $st
}
# Nach einem Modul: gestoppte Dienste immer wieder starten (auch bei Fehler/Abbruch)
function Exit-HMModule([hashtable]$Ctx, $Job, [hashtable]$State) {
    if (-not $State -or -not @($State.Stopped).Count) { return }
    try {
        $r = @(Invoke-HMTarget $Ctx {
            param([string[]]$Names)
            foreach ($n in $Names) {
                try { Start-Service -Name $n -ErrorAction Stop; [pscustomobject]@{ Name = $n; Ok = $true; Msg = '' } }
                catch { [pscustomobject]@{ Name = $n; Ok = $false; Msg = $_.Exception.Message } }
            }
        } @(, @($State.Stopped)))
        foreach ($x in $r) {
            if ($x.Ok) { Write-HMLog $Job "   Dienst $($x.Name) wieder gestartet" 'Info' }
            else { Write-HMLog $Job "   Dienst $($x.Name) konnte NICHT wieder gestartet werden: $($x.Msg) - bitte von Hand starten!" 'Error' }
        }
    } catch { Write-HMLog $Job "   Dienste NICHT wieder gestartet ($($_.Exception.Message)) - bitte von Hand starten: $(@($State.Stopped) -join ', ')" 'Error' }
}

# ============================================================================
# ROBOCOPY
# ============================================================================
# Win32-Fehlercodes der Robocopy-Fehlerzeilen, sprachneutral: "... ERROR 32 (0x00000020) ..." / "... FEHLER 5 (0x00000005) ..."
function Get-HMRobocopyErrorCodes([string]$Text) {
    if (-not $Text) { return @() }
    return @([regex]::Matches($Text, '\s\d+ \(0x([0-9A-Fa-f]{8})\)') | ForEach-Object { [Convert]::ToInt64($_.Groups[1].Value, 16) } | Select-Object -Unique)
}

function Get-HMRobocopySummary([string]$Text) {
    $s = [ordered]@{ FilesTotal = 0; FilesCopied = 0; FilesSkipped = 0; FilesFailed = 0; FilesExtra = 0; BytesTotal = [long]0; BytesCopied = [long]0; BytesSkipped = [long]0; DirsExtra = 0; HaveDirs = $false }
    foreach ($line in ($Text -split "`r?`n")) {
        # Ordner-Zeile (deutsch "Verzeich.:", englisch "Dirs :"), Spalte 6 = Extras (Ordner nur im Ziel)
        if ($line -match '^\s*(Verzeich\.?|Dirs)\s*:\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)(?:\s+(\d+))?') {
            $s.HaveDirs = $true
            if ($Matches[7]) { $s.DirsExtra = [int]$Matches[7] }
            continue
        }
        # Spalten: Gesamt, Kopiert, Uebersprungen, Keine Uebereinstimmung, FEHLER, Extras (Extras = nur am Ziel vorhanden)
        if ($line -match '^\s*(Dateien|Files)\s*:\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)(?:\s+(\d+))?') {
            $s.FilesTotal = [int]$Matches[2]; $s.FilesCopied = [int]$Matches[3]; $s.FilesSkipped = [int]$Matches[4]; $s.FilesFailed = [int]$Matches[6]
            if ($Matches[7]) { $s.FilesExtra = [int]$Matches[7] }
        } elseif ($line -match '^\s*Bytes\s*:\s+(\d+)\s+(\d+)\s+(\d+)') {
            $s.BytesTotal = [long]$Matches[1]; $s.BytesCopied = [long]$Matches[2]; $s.BytesSkipped = [long]$Matches[3]
        }
    }
    return $s
}

# Schluessel/Gewicht eines Backup-Eintrags fuer den Fortschritt nach Datenmenge
function Get-HMPlanKey($Mod, $It) { return "$($Mod.Id)|$($It.Type)|$($It.Name)|$($It.Path)|$($It.Handler)" }
function Get-HMPlanWeight($Plan, $Mod, $It) {
    $b = [long]0
    if ($Plan) { $k = Get-HMPlanKey $Mod $It; if ($Plan.ContainsKey($k)) { $b = [long]$Plan[$k] } }
    return ([double][Math]::Max([long]0, [long]$b) + [double]4MB)   # long-Ueberladung: Eintraege > 2 GiB
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
    # Windows begrenzt die Befehlszeile auf 32767 Zeichen - lieber klar abbrechen als still abgeschnittene Ausschluesse
    if ($psi.Arguments.Length -gt 30000) { throw "Robocopy-Befehlszeile zu lang ($($psi.Arguments.Length) Zeichen, sehr viele Ausschluesse) - Ausschlusslisten kuerzen" }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $Job.Process = $proc
    # Fortschritt innerhalb eines Eintrags (Backup): geschriebene Bytes von Robocopy gegen die geplante Menge
    $track = (-not $ListOnly) -and $Job -and ([long]$Job.ItemBytes -gt 0) -and [bool]('HMMon' -as [type])
    $wr = [long]0
    while (-not $proc.WaitForExit(400)) {
        if (Test-HMCancel $Job) { try { $proc.Kill() } catch { }; break }
        if ($track) {
            try {
                $w = [HMMon]::ProcWrite($proc.Handle)
                if ($w -ge 0) {
                    $wr = $w
                    $f = [Math]::Min(0.98, ([double]$Job.ItemDoneBytes + $w) / [double]$Job.ItemBytes)
                    $p = [int]([double]$Job.ItemBase + [double]$Job.ItemSpan * $f)
                    if ($p -gt [int]$Job.Progress) { $Job.Progress = $p }
                    $Job.CurBytes = [long]$Job.ItemDoneBytes + $w
                }
            } catch { $track = $false }
        }
    }
    $proc.WaitForExit()
    if ($track) { try { $w = [HMMon]::ProcWrite($proc.Handle); if ($w -ge 0) { $wr = $w } } catch { }; $Job.ItemDoneBytes = [long]$Job.ItemDoneBytes + $wr }
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
    # Fehlgeschlagene Dateien (gesperrt/keine Rechte): Fehlerzeilen stehen auch mit /NFL im Protokoll, z.B. "... ERROR 32 (0x00000020) Copying File C:\x\y.db"
    $failed = @()
    if ($sum.FilesFailed -gt 0) {
        $failed = @(foreach ($line in ($text -split "`r?`n")) {
            if ($line -match '\(0x[0-9A-Fa-f]{8}\)\s+.*?\s((?:[A-Za-z]:\\|\\\\).+?)\s*$') { $Matches[1] }
        }) | Select-Object -Unique | Select-Object -First 5
    }
    $errCodes = @(Get-HMRobocopyErrorCodes $text)
    $lvl = if (Test-HMCancel $Job) { 'Cancel' } elseif ($code -ge 8) { 'Error' } elseif ($code -ge 4) { 'Warning' } else { 'OK' }
    return [pscustomobject]@{ ExitCode = $code; Level = $lvl; FilesTotal = $sum.FilesTotal; FilesCopied = $sum.FilesCopied
        FilesSkipped = $sum.FilesSkipped; FilesFailed = $sum.FilesFailed; BytesTotal = $sum.BytesTotal; BytesCopied = $sum.BytesCopied
        BytesSkipped = $sum.BytesSkipped; FilesExtra = $sum.FilesExtra; DirsExtra = $sum.DirsExtra; HaveDirs = $sum.HaveDirs; Args = $psi.Arguments; FailedFiles = @($failed); ErrorCodes = $errCodes }
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
    $t = [regex]::Replace($Text, '(?im)^([ \t]*\[-?)HKEY_CURRENT_USER(?=\\|\])', ('${1}HKEY_USERS\' + $TargetSid))
    if ($SourceSid -and $SourceSid -ne $TargetSid) {
        # nur die ganze SID ersetzen (nicht ...-1001 in ...-10011)
        $t = [regex]::Replace($t, '(?im)^([ \t]*\[-?)HKEY_USERS\\' + [regex]::Escape($SourceSid) + '(?=\\|_Classes|\])', ('${1}HKEY_USERS\' + $TargetSid))
    }
    if ($SourceProfile -and $TargetProfile -and ($SourceProfile.TrimEnd('\') -ne $TargetProfile.TrimEnd('\'))) {
        $srcEsc = $SourceProfile.TrimEnd('\').Replace('\', '\\')
        $dstEsc = $TargetProfile.TrimEnd('\').Replace('\', '\\')
        $t = [regex]::Replace($t, [regex]::Escape($srcEsc) + '(?=\\\\|"|$)', $dstEsc.Replace('$', '$$'), 'IgnoreCase, Multiline')
    }
    return $t
}

# Schutz vor manipulierten .reg-Dateien im Backup: nach Convert-HMRegText darf jeder Abschnitt (auch [-...] = loeschen) nur
# unter HKEY_USERS\<ZielSID> (bzw. <ZielSID>_Classes) liegen, bei HKLM-Eintraegen zusaetzlich unter genau diesem Schluessel.
# Legacy = Backup der Vorgaengerversion: ganze Hive des Eintrags erlaubt. Rueckgabe: erster unzulaessiger Schluessel oder ''.
function Get-HMRegScopeViolation {
    param([string]$Text, [string]$TargetSid, [string]$ItemKey, [switch]$Legacy)
    $norm = {
        param($k)
        $k = "$k".Trim().TrimEnd('\')
        $k = $k -replace '^HKLM(?=\\|$)', 'HKEY_LOCAL_MACHINE' -replace '^HKU(?=\\|$)', 'HKEY_USERS' -replace '^HKCU(?=\\|$)', 'HKEY_CURRENT_USER' -replace '^HKCR(?=\\|$)', 'HKEY_CLASSES_ROOT'
        return $k
    }
    $allowed = New-Object System.Collections.Generic.List[string]
    if ("$TargetSid".Trim()) {
        $allowed.Add(('HKEY_USERS\' + "$TargetSid".Trim()))
        $allowed.Add(('HKEY_USERS\' + "$TargetSid".Trim() + '_Classes'))
    }
    $ik = & $norm $ItemKey
    if ($ik -match '^HKEY_LOCAL_MACHINE(\\|$)') {
        if ($Legacy) { $allowed.Add('HKEY_LOCAL_MACHINE') } else { $allowed.Add($ik) }
    }
    foreach ($line in ("$Text" -split "`r?`n")) {
        $l = $line.Trim()
        if (-not $l.StartsWith('[')) { continue }
        $k = $l.Substring(1)
        if ($k.StartsWith('-')) { $k = $k.Substring(1) }
        # bis zur LETZTEN ] der Zeile (Schluesselnamen duerfen ] enthalten)
        $e = $k.LastIndexOf(']'); if ($e -ge 0) { $k = $k.Substring(0, $e) }
        $k = & $norm $k
        $ok = $false
        foreach ($a in $allowed) {
            if ($k -ieq $a -or $k.StartsWith(($a + '\'), [StringComparison]::OrdinalIgnoreCase)) { $ok = $true; break }
        }
        if (-not $ok) { return $k }
    }
    return ''
}

function Import-HMReg {
    param([hashtable]$Ctx, $Job, [string]$File, [string]$SourceSid, [string]$SourceProfile, $Item)
    $text = Convert-HMRegText -Text (Read-HMRegFile $File) -TargetSid $Ctx.UserSid -SourceSid $SourceSid -SourceProfile $SourceProfile -TargetProfile $Ctx.ProfilePath
    $ik = if ($Item) { "$($Item.Key)" } else { '' }
    $bad = Get-HMRegScopeViolation -Text $text -TargetSid $Ctx.UserSid -ItemKey $ik -Legacy:([bool]($Ctx.Backup -and $Ctx.Backup.Legacy))
    if ($bad) { return "FEHLER: .reg enthaelt Schluessel ausserhalb von $(if ($ik) { $ik } else { 'HKEY_USERS\' + $Ctx.UserSid }): $bad - nicht importiert" }
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
# ---------------------------------------------------------------------------
# Katalog-Statistik: je Katalog-Programm und PC/Benutzer, ob die Pfade des Eintrags beim Backup Daten hatten.
# Liegt NUR lokal im Backup-Ordner (Katalog-Statistik.json) - es wird nichts gesendet. Belegt in der Praxis,
# ob ein (ungepruefter) Eintrag stimmt: "an 12 PCs gefunden" vs. "3x nicht vorhanden".
# ---------------------------------------------------------------------------
function Read-HMCatalogStats([string]$Root) {
    $data = @{}
    $f = Join-Path $Root 'Katalog-Statistik.json'
    if (-not $Root -or -not (Test-Path -LiteralPath $f)) { return $data }
    try {
        $j = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in @($j.Apps.PSObject.Properties)) {
            $h = @{}; foreach ($q in @($p.Value.PSObject.Properties)) { $h[$q.Name] = $q.Value }
            $data[$p.Name] = $h
        }
    } catch { }
    return $data
}
function Get-HMCatalogStatsSummary($Entries) {
    $v = @($Entries.Values)
    $o = [ordered]@{
        Found = @($v | Where-Object { "$($_.Result)" -eq 'gefunden' }).Count
        Partial = @($v | Where-Object { "$($_.Result)" -eq 'teilweise' }).Count
        Missing = @($v | Where-Object { "$($_.Result)" -eq 'nicht vorhanden' }).Count
        Last = "$(@($v | ForEach-Object { "$($_.Date)" } | Sort-Object -Descending)[0])"
    }
    $o.Text = if (-not $v.Count) { '' } else { "an $($o.Found) PC(s) gefunden$(if ($o.Partial) { ", $($o.Partial)x teilweise" })$(if ($o.Missing) { ", $($o.Missing)x nicht vorhanden" })" }
    return [pscustomobject]$o
}
function Update-HMCatalogStats([string]$Root, $Manifest) {
    if (-not $Root -or -not $Manifest) { return 0 }
    $mods = @($Manifest.Modules | Where-Object { $_ -and "$($_.Id)" -like 'App_*' -and -not $_.FromPrevious })
    if (-not $mods.Count) { return 0 }
    $data = Read-HMCatalogStats $Root
    $key = ("{0}|{1}" -f "$($Manifest.SourceComputer)", "$($Manifest.UserName)").ToUpperInvariant()
    $date = "$(if ($Manifest.Finished) { $Manifest.Finished } else { $Manifest.Created })"
    foreach ($m in $mods) {
        $items = @($m.Items | Where-Object { $_ -and "$($_.Name)" -ne 'Hinweis' })
        $found = @($items | Where-Object { "$($_.Status)" -in @('OK', 'Warning') }).Count
        $miss = @($items | Where-Object { "$($_.Status)" -eq 'Skip' -and "$($_.Msg)" -match 'nicht vorhanden' }).Count
        $res = if ($found -and -not $miss) { 'gefunden' } elseif ($found) { 'teilweise' } elseif ($miss) { 'nicht vorhanden' } else { 'unklar' }
        if (-not $data.ContainsKey("$($m.Id)")) { $data["$($m.Id)"] = @{} }
        $data["$($m.Id)"][$key] = [ordered]@{ Date = $date; Result = $res; Items = @($items | ForEach-Object { "$($_.Name)=$($_.Status)" }) }
    }
    $out = [ordered]@{}
    foreach ($k in @($data.Keys | Sort-Object)) { $e = [ordered]@{}; foreach ($k2 in @($data[$k].Keys | Sort-Object)) { $e[$k2] = $data[$k][$k2] }; $out[$k] = $e }
    $obj = [ordered]@{ _Info = 'HUMig Katalog-Statistik: je Katalog-Programm und PC|Benutzer das Ergebnis des letzten Backups (gefunden / teilweise / nicht vorhanden). Nur lokal, wird nicht gesendet.'; Updated = (Get-Date).ToString('yyyy-MM-dd HH:mm'); Apps = $out }
    $f = Join-Path $Root 'Katalog-Statistik.json'
    $tmp = "$f.tmp"
    [System.IO.File]::WriteAllText($tmp, ($obj | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($true)))
    Move-Item -LiteralPath $tmp -Destination $f -Force
    return $mods.Count
}
# Statistik aus allen vorhandenen Backups im Ordner neu einlesen (z.B. fuer Backups vor dieser Funktion)
function Import-HMCatalogStatsFromBackups([string]$Root) {
    $n = 0
    foreach ($d in @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $mf = Join-Path $d.FullName 'manifest.json'
        if (-not (Test-Path -LiteralPath $mf)) { continue }
        try { $m = Get-Content -LiteralPath $mf -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
        if ("$($m.Status)" -in @('Running', 'Cancelled')) { continue }
        if ((Update-HMCatalogStats $Root $m) -gt 0) { $n++ }
    }
    return $n
}

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
                Modules = $mods; SizeBytes = [long]$m.SizeBytes; Status = $m.Status; Manifest = $m; Archived = (Test-HMBackupArchived $Path) }
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
        Sid = $sid; ProfilePath = "C:\Users\$user"; Modules = @($found | Select-Object -Unique); SizeBytes = [long]0; Status = 'Legacy'; Manifest = $null; Archived = (Test-HMBackupArchived $Path) }
}

function Get-HMBackupList {
    param([string]$Root, [object[]]$Modules)
    if (-not (Test-Path -LiteralPath $Root)) { return @() }
    $list = foreach ($d in @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue)) {
        if (($d.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }   # Verknuepfungen nie als Backup behandeln
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
        # relativer Pfad wird beim Durchlaufen mitgefuehrt (robust auch bei 8.3-Kurznamen im Stammpfad)
        $stack.Push(@($root, 0, ''))
        while ($stack.Count -gt 0) {
            $e = $stack.Pop(); $d = [string]$e[0]; $lvl = [int]$e[1]; $pre = [string]$e[2]
            if ($lvl -gt 60 -or $d.Length -gt 1000) { continue }
            try {
                foreach ($i in (New-Object System.IO.DirectoryInfo $d).EnumerateFileSystemInfos()) {
                    $a = [int]$i.Attributes
                    $rel = if ($pre) { "$pre\$($i.Name)" } else { $i.Name }
                    if ($a -band 0x10) {
                        # Junction/symbolischer Link: nie folgen (wie Robocopy /XJ); andere Reparse-Ordner (OneDrive) normal durchlaufen.
                        # LinkType nicht ermittelbar -> wie normaler Ordner weiter (Tiefe/Pfadlaenge oben begrenzt)
                        if ($a -band 0x400) {
                            $lt = ''
                            try { $lt = "$((Get-Item -LiteralPath $i.FullName -Force -ErrorAction Stop).LinkType)" } catch { $lt = '' }
                            if ($lt -in @('Junction', 'SymbolicLink')) { continue }
                        }
                        $stack.Push(@($i.FullName, ($lvl + 1), $rel)); continue
                    }
                    if (($a -band 0x400000) -or ($a -band 0x40000) -or ($a -band 0x1000)) { $cloudN++; $cloudB += $i.Length; continue }
                    $files.Add(('{0}|{1}|{2}' -f $i.Length, $i.LastWriteTimeUtc.Ticks, $rel))
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
        [void]$sb.Append('<!DOCTYPE html><html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>HUMig ' + $Kind + '</title><style>')
        [void]$sb.Append('body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#222}h1{font-size:22px;margin:0}header{display:flex;gap:14px;align-items:center;border-bottom:2px solid #444;padding-bottom:10px;margin-bottom:14px}')
        [void]$sb.Append('table{border-collapse:collapse;width:100%;margin:8px 0 16px}td,th{border:1px solid #ccc;padding:4px 8px;text-align:left;vertical-align:top;font-size:13px}th{background:#eee}')
        [void]$sb.Append('.st{font-weight:600}.facts td:first-child{width:220px;font-weight:600;background:#f6f6f6}.sig{margin-top:40px;display:flex;gap:60px}.sig div{border-top:1px solid #444;width:260px;padding-top:4px;font-size:12px}small{color:#666}@media print{body{margin:10mm}}')
        # Handy: gleichmaessige Schrift (keine automatische Textvergroesserung), lange Pfade umbrechen
        [void]$sb.Append('html{-webkit-text-size-adjust:100%;text-size-adjust:100%}td{overflow-wrap:anywhere}@media screen and (max-width:700px){body{margin:12px}.facts td:first-child{width:38%}.sig{flex-direction:column;gap:28px}.sig div{width:auto}}')
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
            $det = @(foreach ($i in @($m.Items)) { if ($i -and $i.Msg) { (ConvertTo-HMHtml "$($i.Name): $($i.Msg)") -replace "`r?`n", '<br>&nbsp;&nbsp;&nbsp;' } }) -join '<br>'
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
    if ($Item.Type -eq 'Files') { $subRoots = @() }   # einzelne Dateien ohne Unterordner - Cloud-Unterordner spielen keine Rolle
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
    if ("$($Item.Role)" -eq 'Database' -and $files.Count) { $files = @(Add-HMDbCompanions $files) }
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
    $lockHint = $false
    if ($rc.FilesFailed -gt 0) {
        $fl = if (@($rc.FailedFiles).Count) { ': ' + (@($rc.FailedFiles | ForEach-Object { ConvertFrom-HMPath "$_" }) -join '; ') } else { '' }
        # nur Sperrfehler (32/33) und waehrend der Kopie verschwundene Dateien/Pfade (2/3, Browser raeumt Temp/Journal weg)
        # gelten als "vom laufenden Programm gesperrt"; ohne erkannte Codes wie bisher
        $onlyLocks = (@($rc.ErrorCodes).Count -eq 0) -or (@($rc.ErrorCodes | Where-Object { $_ -notin 2, 3, 32, 33 }).Count -eq 0)
        if ($Ctx.LockedHint -and $onlyLocks -and $st -ne 'Cancel' -and [int]$rc.ExitCode -lt 16) {
            # Browser lief (Modul mit CloseDefault Copy): gesperrte Dateien nur als Hinweis
            $lockHint = $true
            $msg += ", Hinweis: $($rc.FilesFailed) Datei(en) vom laufenden Programm gesperrt und nicht gesichert (z.B. Cookies, Sitzung - fuer eine vollstaendige Sicherung das Programm vorher schliessen)$fl"
            $st = if (([int]$rc.ExitCode -band 4) -ne 0) { 'Warning' } else { 'OK' }
        } else {
            $msg += ", $($rc.FilesFailed) FEHLGESCHLAGEN (gesperrt/keine Rechte - siehe Robocopy-Log)$fl"
            if ($st -ne 'Cancel') { $st = 'Error' }   # nicht gesicherte Dateien = Fehler (rot), nie nur Warnung
        }
    }
    # Backup ergaenzt: Dateien, die nur noch im Backup liegen (an der Quelle geloescht/verschoben) -> beiseitelegen (_GELOESCHT),
    # damit der Restore nur den aktuellen Stand bringt. Nur nach fehlerfreiem Kopieren; jede Datei wird an der Quelle nachgeprueft.
    $hasExtra = ([int]$rc.FilesExtra -gt 0 -or [int]$rc.DirsExtra -gt 0 -or -not $rc.HaveDirs)
    if (-not $fresh -and -not $Ctx.ListOnly -and $hasExtra -and $st -in @('OK', 'Warning') -and [int]$rc.ExitCode -lt 8 -and [int]$rc.FilesFailed -eq 0 -and -not (Test-HMCancel $Job)) {
        $mv = $null
        $mp = 20; $mm = 50
        if ($Ctx.Settings -and $null -ne $Ctx.Settings.DeletedMassPercent) { $mp = [int]$Ctx.Settings.DeletedMassPercent }
        if ($Ctx.Settings -and $null -ne $Ctx.Settings.DeletedMassMin) { $mm = [int]$Ctx.Settings.DeletedMassMin }
        try { $mv = Move-HMDeletedFromBackup -Ctx $Ctx -Job $Job -Src $src -Dst $dst -Files $files -XD $xd -XF $xf -NoRecurse:$noRec -NoHidden:([bool]$Item.NoHidden) -TotalFiles ([int]$rc.FilesTotal) -MassPercent $mp -MassMin $mm }
        catch { $mv = [pscustomobject]@{ Moved = 0; Kept = 0; Failed = 0; Error = "$($_.Exception.Message)"; Mass = $false; Count = 0; Total = 0 } }
        if ($mv.Mass) {
            $pct = [Math]::Round(100.0 * $mv.Count / [Math]::Max(1, $mv.Total))
            $alert = "$($Module.Name) - ${srcLocal}: $($mv.Count) von $($mv.Total) Dateien ($pct %) an der Quelle verschwunden"
            $msg += " | ACHTUNG MASSENLOESCHUNG: $($mv.Count) von $($mv.Total) Dateien ($pct %) fehlen an der Quelle - das ist ein typisches Zeichen fuer einen Verschluesselungstrojaner (oder der Ordner wurde verschoben/umbenannt). Nichts beiseitegelegt, die Dateien bleiben im Backup. Quell-PC pruefen!"
            if ($st -eq 'OK') { $st = 'Warning' }
            if ($null -eq $Ctx.MassAlerts) { $Ctx.MassAlerts = New-Object System.Collections.Generic.List[string] }
            [void]$Ctx.MassAlerts.Add($alert)
        }
        if ($mv.Moved) {
            $msg += " | $($mv.Moved) an der Quelle geloeschte Datei(en) beiseitegelegt ($($script:HMDeletedDirName)\$(Split-Path "$($Ctx.DeletedDir)" -Leaf) - werden nicht zurueckgespielt)"
            $Ctx.DeletedMoved = [int]$Ctx.DeletedMoved + [int]$mv.Moved
        }
        if ($mv.Error) { $msg += " | Geloeschte nicht beiseitegelegt: $($mv.Error)" }
        if ($mv.Kept + $mv.Failed -gt 0) { $msg += " | $($mv.Kept + $mv.Failed) Datei(en) nur noch im Backup, an der Quelle nicht sicher pruefbar - bleiben (Restore spielt sie ein)" }
    } elseif (-not $fresh -and -not $Ctx.ListOnly -and [int]$rc.FilesExtra -gt 0) {
        $msg += " | $($rc.FilesExtra) Datei(en) nur noch im Backup (an der Quelle geloescht/verschoben - nicht beiseitegelegt, weil das Kopieren nicht fehlerfrei war; Restore spielt sie ein)"
    }
    if ($rc.Level -eq 'Error' -and -not $lockHint) { $msg += " (Robocopy-Code $($rc.ExitCode))" }
    # Seit dem letzten Lauf neu ausgeschlossene Pfade: alten Stand beiseitelegen (wird sonst beim Restore wieder eingespielt)
    if (-not $fresh -and -not $Ctx.ListOnly -and $st -ne 'Cancel' -and -not (Test-HMCancel $Job) -and @($Ctx.Options.ExcludePaths).Count) {
        $nx = Move-HMNewlyExcluded $Ctx $srcLocal $dst
        foreach ($l in @($nx.Lines)) { $msg += " | $l" }
        if ($nx.Files) { $Ctx.DeletedMoved = [int]$Ctx.DeletedMoved + [int]$nx.Files }
    }

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

# Zusaetzliche Ordner: feste Nummer je Pfad (FOLDER<n>), damit ein herausgenommener Ordner nicht den Platz eines anderen bekommt.
# Grundlage: ExtraFolders\folders.json (aktuelle) und folders-alt.json (herausgenommene, Nummer wird nie wieder vergeben).
# Rueckgabe: Map (Index, Path) fuer $Paths, Removed (bisher gesicherte, jetzt nicht mehr gewaehlte), Alt (bisherige Liste herausgenommener)
function Get-HMExtraFolderMap([string]$BackupPath, [string[]]$Paths) {
    $dir = Join-Path $BackupPath 'ExtraFolders'
    $old = @(); $alt = @()
    foreach ($x in @(@{ F = 'folders.json'; V = 'old' }, @{ F = 'folders-alt.json'; V = 'alt' })) {
        $f = Join-Path $dir $x.F
        if (-not (Test-Path -LiteralPath $f)) { continue }
        try {
            $j = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json   # PS 5.1: erst zuweisen
            $l = @(@($j) | Where-Object { $_ -and "$($_.Path)" -and [int]$_.Index -gt 0 })
            if ($x.V -eq 'old') { $old = $l } else { $alt = $l }
        } catch { }
    }
    $norm = { param($p) "$p".Trim().TrimEnd('\').ToUpperInvariant() }
    $used = @(@($old) + @($alt) | ForEach-Object { [int]$_.Index })
    $next = 1; if ($used.Count) { $next = [int](($used | Measure-Object -Maximum).Maximum) + 1 }
    $map = New-Object System.Collections.Generic.List[object]
    foreach ($p in @($Paths | Where-Object { "$_".Trim() })) {
        $o = @($old | Where-Object { (& $norm $_.Path) -eq (& $norm $p) })[0]
        if ($o) { $i = [int]$o.Index } else { $i = $next; $next++ }
        $map.Add([pscustomobject]@{ Index = $i; Path = "$p" })
    }
    $cur = @($map | ForEach-Object { & $norm $_.Path })
    $removed = @($old | Where-Object { $cur -notcontains (& $norm $_.Path) })
    return [pscustomobject]@{ Map = $map.ToArray(); Removed = $removed; Alt = $alt }
}

# Fortlaufendes Backup: Pfade, die seit dem letzten Lauf neu ausgeschlossen sind, aus dem Backup beiseitelegen (_GELOESCHT),
# sonst spielte der Restore den alten Stand wieder ein. Rueckgabe: Anzahl verschobener Dateien, Texte fuer das Protokoll
function Move-HMNewlyExcluded([hashtable]$Ctx, [string]$SrcLocal, [string]$Dst) {
    $res = [pscustomobject]@{ Files = 0; Lines = @() }
    if ($null -eq $Ctx.PrevExcludePaths) { return $res }   # aeltere Backups ohne Angabe: nichts anfassen
    $norm = { param($p) "$p".Trim().TrimEnd('\').ToUpperInvariant() }
    $prevEx = @(@($Ctx.PrevExcludePaths) | ForEach-Object { & $norm $_ })
    $bp = "$($Ctx.BackupPath)".TrimEnd('\')
    $s0 = "$SrcLocal".TrimEnd('\')
    foreach ($p in @($Ctx.Options.ExcludePaths | Where-Object { "$_".Trim() })) {
        if ($prevEx -contains (& $norm $p)) { continue }
        if (-not (Test-HMPathUnder $p $s0) -or (& $norm $p) -eq (& $norm $s0)) { continue }
        $rel = "$p".TrimEnd('\').Substring($s0.Length).TrimStart('\')
        if (-not $rel) { continue }
        $b = Join-Path $Dst $rel
        if (-not $b.StartsWith($bp + '\', [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $b)) { continue }
        try {
            Initialize-HMFsMove
            $n = if (Test-Path -LiteralPath $b -PathType Container) { @(Get-ChildItem -LiteralPath $b -Recurse -File -Force -ErrorAction SilentlyContinue).Count } else { 1 }
            if (-not $Ctx.DeletedDir) { $Ctx.DeletedDir = "$bp\$($script:HMDeletedDirName)\$(Get-Date -Format 'yyyyMMdd_HHmmss')" }
            $e = [HMFs.Mover]::Move($b, "$($Ctx.DeletedDir)\$($b.Substring($bp.Length + 1))")
            if ($e -eq 0) { $res.Files += $n; $res.Lines += "neu ausgeschlossen, $n Datei(en) beiseitegelegt: $p" }
            else { $res.Lines += "neu ausgeschlossen, bleibt im Backup (Verschieben Fehler $e - Restore spielt den alten Stand ein): $p" }
        } catch { $res.Lines += "neu ausgeschlossen, bleibt im Backup ($($_.Exception.Message)): $p" }
    }
    return $res
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
            $meta = @(); $bytes = [long]0; $worst = 'OK'; $lines = @()
            $fm = Get-HMExtraFolderMap $Ctx.BackupPath $list
            # nicht mehr gewaehlte Ordner (fortlaufendes Backup): beiseitelegen, Nummer merken (folders-alt.json, nie wieder vergeben)
            $alt = @($fm.Alt)
            foreach ($r0 in @($fm.Removed)) {
                $od = Join-Path $dir "FOLDER$([int]$r0.Index)"
                $alt += [pscustomobject]@{ Index = [int]$r0.Index; Path = "$($r0.Path)"; Removed = (Get-Date).ToString('yyyy-MM-dd HH:mm') }
                if (-not (Test-Path -LiteralPath $od)) { continue }
                try {
                    Initialize-HMFsMove
                    $bp0 = "$($Ctx.BackupPath)".TrimEnd('\')
                    $n0 = @(Get-ChildItem -LiteralPath $od -Recurse -File -Force -ErrorAction SilentlyContinue).Count
                    if (-not $Ctx.DeletedDir) { $Ctx.DeletedDir = "$bp0\$($script:HMDeletedDirName)\$(Get-Date -Format 'yyyyMMdd_HHmmss')" }
                    $e0 = [HMFs.Mover]::Move($od, "$($Ctx.DeletedDir)\$($od.Substring($bp0.Length + 1))")
                    if ($e0 -eq 0) { $lines += "$($r0.Path) - nicht mehr ausgewaehlt: $n0 Datei(en) beiseitegelegt ($($script:HMDeletedDirName), werden nicht zurueckgespielt)"; $Ctx.DeletedMoved = [int]$Ctx.DeletedMoved + $n0 }
                    else { $lines += "$($r0.Path) - nicht mehr ausgewaehlt, alter Stand bleibt in FOLDER$([int]$r0.Index) (Verschieben Fehler $e0, wird nicht zurueckgespielt)" }
                } catch { $lines += "$($r0.Path) - nicht mehr ausgewaehlt, alter Stand bleibt ($($_.Exception.Message), wird nicht zurueckgespielt)" }
            }
            if (@($fm.Removed).Count) { try { ConvertTo-Json -InputObject @($alt) -Depth 3 | Set-Content -LiteralPath (Join-Path $dir 'folders-alt.json') -Encoding UTF8 } catch { } }
            foreach ($fx in @($fm.Map)) {
                $idx = [int]$fx.Index; $p = "$($fx.Path)"
                $fake = [pscustomobject]@{ Name = "FOLDER$idx"; Path = $p; Type = 'Folder' }
                $r = Backup-HMFolderItem $Ctx $Job $Module $fake $TEnv
                $meta += [pscustomobject]@{ Index = $idx; Path = $p; Status = $r.Status }
                $lines += "$p - $($r.Msg)"
                $bytes += $r.Bytes
                if ($r.Status -in @('Error', 'Cancel')) { $worst = $r.Status } elseif ($r.Status -eq 'Warning' -and $worst -eq 'OK') { $worst = 'Warning' }
            }
            if (-not $list.Count) {
                # keine Ordner mehr gewaehlt: Liste leeren (herausgenommene sind oben beiseitegelegt)
                if (@($fm.Removed).Count) { Set-Content -LiteralPath (Join-Path $dir 'folders.json') -Value '[]' -Encoding UTF8 }
                return (& $res 'Skip' ((@('keine Ordner ausgewaehlt') + $lines) -join "`n"))
            }
            ConvertTo-Json -InputObject @($meta) -Depth 3 | Set-Content -LiteralPath (Join-Path $dir 'folders.json') -Encoding UTF8
            # je Ordner eine Zeile im Protokoll (Pfad am Quell-PC, Dateien, Groesse)
            return (& $res $worst ("$($list.Count) Ordner, $(Format-HMSize $bytes)`n" + ($lines -join "`n")) $bytes)
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
    # eingetragener Ordner: direkt, oder (haeufig) der uebergeordnete Ordner - amd64 bzw. USMT\amd64 darunter
    if ($Ctx.Settings.UsmtPath) { $u0 = "$($Ctx.Settings.UsmtPath)".TrimEnd('\'); $cands += @($u0, "$u0\amd64", "$u0\USMT\amd64") }
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
    $Ctx.PlanBytes = $null
    $Ctx.IsRemote = -not (Test-HMIsLocal $Ctx.Computer)
    if (-not $Ctx.IsRemote) { $Ctx.Computer = $env:COMPUTERNAME }
    $Ctx.CopyMap = New-Object System.Collections.Generic.List[object]
    $Ctx.SyncRootLog = New-Object System.Collections.Generic.List[object]
    $Ctx.SyncRoots = @()
    $Ctx.ListOnly = $false
    $target = $Ctx.BackupPath

    # Inkrementell: vorhandenes Backup desselben Benutzers weiterfuehren (Robocopy kopiert nur Neues/Geaendertes)
    $prev = $null
    # Archiv nie weiterfuehren (auch wenn ein Aufrufer es uebergibt) - stattdessen neues Backup unter $Ctx.BackupPath
    $archSkip = $null
    if ($Ctx.ExistingBackup -and (Test-HMBackupArchived $Ctx.ExistingBackup)) { $archSkip = Split-Path "$($Ctx.ExistingBackup)" -Leaf; $Ctx.ExistingBackup = $null }
    if ($Ctx.ExistingBackup -and (Test-Path -LiteralPath (Join-Path $Ctx.ExistingBackup 'manifest.json'))) {
        try { $prev = Get-Content -LiteralPath (Join-Path $Ctx.ExistingBackup 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $prev = $null }
        if ($prev) { $Ctx.BackupPath = $Ctx.ExistingBackup }
    }
    # Ausschluesse des letzten Laufs (neu ausgeschlossene Pfade werden beiseitegelegt); $null = unbekannt (aeltere Backups)
    $Ctx.PrevExcludePaths = $null
    if ($prev -and $prev.PSObject.Properties['ExcludePaths']) { $Ctx.PrevExcludePaths = @($prev.ExcludePaths | Where-Object { $_ }) }
    Write-HMLog $Job "BACKUP  $($Ctx.Computer) \ $($Ctx.UserFolder)  ->  $target" 'Header'
    if ($archSkip) { Write-HMLog $Job "Fortlaufend: '$archSkip' ist als Archiv markiert und bleibt unveraendert - es wird ein neues Backup angelegt" 'Info' }
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
            # geplante Bytes je Eintrag - fuer einen Fortschritt nach Datenmenge (statt nach Anzahl der Eintraege)
            $Ctx.PlanBytes = @{}
            $Ctx.ListOnly = $true
            try {
                foreach ($mod in $Ctx.Modules) {
                    foreach ($it in @($mod.Items)) {
                        if (Test-HMCancel $Job) { break }
                        $Job.Status = "Platzbedarf: $($mod.Name)"
                        if ($it.Type -in @('Folder', 'Files')) {
                            $r = Backup-HMFolderItem $Ctx $Job $mod $it $tenv
                            $need += [long]$r.BytesCopied
                            $Ctx.PlanBytes[(Get-HMPlanKey $mod $it)] = [long]$r.BytesCopied
                        } elseif ($it.Type -eq 'Builtin' -and $it.Handler -eq 'ExtraFolders') {
                            $xb = [long]0
                            foreach ($fx in @((Get-HMExtraFolderMap $Ctx.BackupPath @($Ctx.Options.ExtraFolders | Where-Object { $_ })).Map)) {
                                $r = Backup-HMFolderItem $Ctx $Job $mod ([pscustomobject]@{ Name = "FOLDER$([int]$fx.Index)"; Path = "$($fx.Path)"; Type = 'Folder' }) $tenv
                                $need += [long]$r.BytesCopied; $xb += [long]$r.BytesCopied
                            }
                            $Ctx.PlanBytes[(Get-HMPlanKey $mod $it)] = $xb
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
        # Admin-Backup eines Benutzers: der Benutzer darf sein eigenes Backup lesen (BACKUPS ist sonst nur fuer den Ersteller lesbar)
        if (-not $Ctx.UserMode -and "$($Ctx.UserSid)" -match '^S-1-5-21-' -and "$($Ctx.BackupPath)" -notlike '\\*') {
            try { $null = & icacls.exe "$($Ctx.BackupPath)" /grant "*$($Ctx.UserSid):(OI)(CI)RX" /C /Q 2>&1 } catch { Write-HMLog $Job "Leserecht fuer den Benutzer nicht gesetzt: $($_.Exception.Message)" 'Debug' }
        }
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
            MachineGuid = (Get-HMMachineGuid $Ctx); Browsers = [ordered]@{}
            Software = $(if (@($Ctx.SoftwareList).Count) { @($Ctx.SoftwareList) } elseif ($prev -and $prev.Software) { @($prev.Software) } else { @() })
            Apps = $(if (@($Ctx.SoftwareList).Count) { @($Ctx.AppsFound) } elseif ($prev -and $prev.Apps) { @($prev.Apps) } else { @() })
        }
        Save-HMManifest $Ctx.Manifest $Ctx.BackupPath

        $total = @($Ctx.Modules | ForEach-Object { @($_.Items).Count } | Measure-Object -Sum).Sum
        if (-not $total) { $total = 1 }
        $done = 0
        # Fortschritt nach Datenmenge, wenn der Platzbedarf ermittelt wurde (jeder Eintrag zaehlt mind. 4 MB, damit auch Registry-Teile vorankommen)
        $plan = $Ctx.PlanBytes
        $wTotal = [double]0; $wDone = [double]0
        if ($plan -and $plan.Count) { foreach ($m0 in $Ctx.Modules) { foreach ($i0 in @($m0.Items)) { $wTotal += Get-HMPlanWeight $plan $m0 $i0 } } }
        # Menge fuer die Anzeige (Handy): geplant / bisher geschrieben
        $Job.PlanTotal = [long]0; $Job.DoneBytes = [long]0; $Job.CurBytes = [long]0
        if ($plan -and $plan.Count) { foreach ($v0 in @($plan.Values)) { $Job.PlanTotal = [long]$Job.PlanTotal + [long]$v0 } }
        foreach ($mod in $Ctx.Modules) {
            if (Test-HMCancel $Job) { break }
            Write-HMLog $Job $mod.Name 'Info'
            $Job.Status = $mod.Name
            $mres = [ordered]@{ Id = $mod.Id; Name = $mod.Name; Status = 'OK'; Bytes = [long]0; Items = @() }
            # Programm-Katalog: Programm schliessen / Dienst stoppen (Dienste werden im finally immer wieder gestartet)
            $pre = Enter-HMModule $Ctx $Job $mod $tenv 'Backup'
            foreach ($w in @($pre.Warn)) { Write-HMLog $Job "   $w" 'Warning'; $mres.Items += [pscustomobject]@{ Name = 'Hinweis'; Status = 'Warning'; Msg = $w; Bytes = [long]0; Source = '' } }
            foreach ($w in @($pre.Info)) { Write-HMLog $Job "   Hinweis: $w" 'Info'; $mres.Items += [pscustomobject]@{ Name = 'Hinweis'; Status = 'OK'; Msg = $w; Bytes = [long]0; Source = '' } }
            $Ctx.LockedHint = [bool]$pre.LockedHint
            if (@($pre.Warn).Count) { $mres.Status = 'Warning' }
            if ($pre.ProcAction) { $mres.Process = $pre.ProcAction }
            if ($pre.ServiceAction) { $mres.Service = $pre.ServiceAction }
            try {
            foreach ($it in @($mod.Items)) {
                if (Test-HMCancel $Job) { break }
                $wIt = if ($wTotal -gt 0) { Get-HMPlanWeight $plan $mod $it } else { 0 }
                if ($wTotal -gt 0 -and ($it.Type -in @('Folder', 'Files') -or ($it.Type -eq 'Builtin' -and $it.Handler -eq 'ExtraFolders'))) {
                    # waehrend Robocopy laeuft: Fortschritt innerhalb des Eintrags nach geschriebenen Bytes (Invoke-HMRobocopy)
                    $Job.ItemBase = 95 * $wDone / $wTotal; $Job.ItemSpan = 95 * $wIt / $wTotal; $Job.ItemBytes = [long]$plan[(Get-HMPlanKey $mod $it)]; $Job.ItemDoneBytes = [long]0
                }
                if ($pre.Skip) { $done++; $wDone += $wIt; $Job.ItemBytes = 0; continue }
                if ($pre.SkipServiceItems -and (Test-HMServiceItem $it)) {
                    $mres.Items += [pscustomobject]@{ Name = $it.Name; Status = 'Warning'; Msg = 'ausgelassen: Dienst-Datenbank (Dienst nicht gestoppt)'; Bytes = [long]0; Source = "$($it.Path)" }
                    $done++; $wDone += $wIt; $Job.ItemBytes = 0; continue
                }
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
                # Chromium-Browser: Lesezeichen zusaetzlich als HTML, Liste der Erweiterungen, Browser-Version ins Manifest
                if ($it.Type -eq 'Folder' -and $r.Status -in @('OK', 'Warning') -and (Test-HMChromiumItem $it)) {
                    try {
                        $ex = @(Save-HMBrowserExtras $Ctx $mod $it)
                        if ($ex.Count) { $r.Msg = "$($r.Msg)`n" + ($ex -join "`n") }
                        $ud = Get-HMItemTargetPath $Ctx.BackupPath $mod $it
                        if ("$($it.Chromium)") { $ud = Join-Path $ud "$($it.Chromium)" }
                        $bv = Get-HMChromiumVersion $ud
                        if ($bv) { $Ctx.Manifest.Browsers["$($mod.Id)"] = $bv }
                    } catch { Write-HMLog $Job "   Lesezeichen-Export: $($_.Exception.Message)" 'Warning' }
                }
                $lvl = switch ($r.Status) { 'OK' { 'Success' } 'Skip' { 'Debug' } 'Warning' { 'Warning' } default { 'Error' } }
                Write-HMLog $Job ("   {0}: {1}" -f $r.Name, ("$($r.Msg)" -replace "`r?`n", "`n      ")) $lvl
                $mres.Items += [pscustomobject]@{ Name = $r.Name; Status = $r.Status; Msg = $r.Msg; Bytes = [long]$r.Bytes; Source = $r.Source }
                $mres.Bytes += [long]$r.Bytes
                if ($r.Status -in @('Error', 'Cancel')) { $mres.Status = 'Error' } elseif ($r.Status -eq 'Warning' -and $mres.Status -eq 'OK') { $mres.Status = 'Warning' }
                $done++; $wDone += $wIt; $Job.ItemBytes = 0
                $Job.DoneBytes = [long]$Job.DoneBytes + [long]$r.Bytes; $Job.CurBytes = [long]0
                $p = if ($wTotal -gt 0) { [int](95 * [Math]::Min(1.0, $wDone / $wTotal)) } else { [int](95 * $done / $total) }
                if ($p -gt [int]$Job.Progress) { $Job.Progress = $p }
            }
            } finally { $Ctx.LockedHint = $false; Exit-HMModule $Ctx $Job $pre }
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

        # ---- Fortlaufend: Module, die diesmal nicht gesichert wurden (alter Stand bleibt im Backup-Ordner, wird nicht zurueckgespielt) ----
        if ($prev) {
            $curIds = @($Ctx.Modules | ForEach-Object { "$($_.Id)" })
            $sk = @()
            foreach ($pm in @(@($prev.Modules) + @($prev.SkippedModules) | Where-Object { $_ -and "$($_.Id)" })) {
                if ($curIds -contains "$($pm.Id)" -or @($sk | Where-Object { $_.Id -eq "$($pm.Id)" }).Count) { continue }
                if (-not (Test-Path -LiteralPath (Join-Path $Ctx.BackupPath "$($pm.Id)"))) { continue }
                $since = if ($pm.PSObject.Properties['Since'] -and "$($pm.Since)") { "$($pm.Since)" } else { "$($prev.Created)" }
                $sk += [pscustomobject]@{ Id = "$($pm.Id)"; Name = "$($pm.Name)"; Since = $since }
            }
            if ($sk.Count) {
                $Ctx.Manifest.SkippedModules = $sk
                Write-HMLog $Job "Fortlaufend: diesmal NICHT gesichert (nicht angehakt): $(@($sk | ForEach-Object { "$($_.Name) (Stand $($_.Since))" }) -join ', ') - der alte Stand bleibt im Backup-Ordner, wird beim Restore aber nicht zurueckgespielt. Wieder anhaken = beim naechsten Lauf aktualisiert." 'Warning'
            }
        }

        # ---- Beiseitegelegte (an der Quelle geloeschte) Dateien: Zusammenfassung, abgelaufene entfernen ----
        if ($Ctx.MassAlerts -and $Ctx.MassAlerts.Count) {
            Write-HMLog $Job 'ACHTUNG - MASSENLOESCHUNG ERKANNT: an der Quelle fehlen auf einmal ungewoehnlich viele Dateien. Das ist ein typisches Zeichen fuer einen Verschluesselungstrojaner (verschluesselte Kopien ersetzen die Originale) - oder ein Ordner wurde verschoben/umbenannt. HUMig hat dort nichts beiseitegelegt, die bisherigen Dateien bleiben im Backup. Quell-PC sofort pruefen (neue Dateiendungen, Erpresser-Hinweise), Netzwerk trennen, falls verdaechtig. War die Loeschung gewollt: Backup einmal mit "Neu" erstellen oder die Schwelle unter Einstellungen > Allgemein anpassen.' 'Error'
            foreach ($a in $Ctx.MassAlerts) { Write-HMLog $Job "   $a" 'Error' }
            $Ctx.Manifest.MassDeleteAlert = @($Ctx.MassAlerts.ToArray())
        }
        if ($prev -and -not (Test-HMCancel $Job)) {
            if ([int]$Ctx.DeletedMoved -gt 0) { Write-HMLog $Job "Fortlaufend: $($Ctx.DeletedMoved) an der Quelle geloeschte Datei(en) nach $($script:HMDeletedDirName)\$(Split-Path "$($Ctx.DeletedDir)" -Leaf) verschoben - werden beim Restore nicht zurueckgespielt (Im Backup suchen > mit geloeschten)" 'Info' }
            $kd = 90
            if ($Ctx.Settings -and $null -ne $Ctx.Settings.DeletedKeepDays) { $kd = [int]$Ctx.Settings.DeletedKeepDays }
            try {
                $ex = Remove-HMDeletedExpired $Ctx.BackupPath $kd
                if ($ex.Removed) { Write-HMLog $Job "Beiseitegelegte Dateien aelter als $kd Tage entfernt ($($ex.Removed) Lauf/Laeufe)" 'Info' }
                foreach ($er in @($ex.Errors)) { Write-HMLog $Job "   Beiseitegelegte nicht entfernt: $er" 'Warning' }
            } catch { Write-HMLog $Job "   Beiseitegelegte nicht entfernt: $($_.Exception.Message)" 'Warning' }
            try { $Ctx.Manifest.Deleted = Get-HMDeletedInfo $Ctx.BackupPath } catch { }
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
    $Ctx.Manifest.Duration = Format-HMDuration $dur
    $Ctx.Manifest.SizeBytes = $allBytes
    $errs = @($Ctx.Manifest.Modules | Where-Object { $_.Status -eq 'Error' -and -not $_.FromPrevious }).Count
    $warns = @($Ctx.Manifest.Modules | Where-Object { $_.Status -eq 'Warning' -and -not $_.FromPrevious }).Count
    if ($verify -and $verify.Status -ne 'OK') { $warns++ }
    $Ctx.Manifest.Status = if (Test-HMCancel $Job) { 'Cancelled' } elseif ($errs) { 'Error' } elseif ($warns) { 'Warning' } else { 'OK' }
    Save-HMManifest $Ctx.Manifest $Ctx.BackupPath
    $Job.Progress = 100
    $sumLvl = switch ($Ctx.Manifest.Status) { 'OK' { 'Success' } 'Warning' { 'Warning' } default { 'Error' } }
    Write-HMLog $Job ("BACKUP {0}: {1} in {2} - Fehler: {3}, Warnungen: {4}" -f $Ctx.Manifest.Status, (Format-HMSize $allBytes), $Ctx.Manifest.Duration, $errs, $warns) $sumLvl
    if (-not (Test-HMCancel $Job)) { try { Update-HMCatalogStats (Split-Path $Ctx.BackupPath -Parent) $Ctx.Manifest } catch { Write-HMLog $Job "Katalog-Statistik nicht aktualisiert: $($_.Exception.Message)" 'Debug' } }

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
            foreach ($fx in @((Get-HMExtraFolderMap $Ctx.BackupPath @($Ctx.Options.ExtraFolders | Where-Object { $_ })).Map)) { $items += [pscustomobject]@{ M = $mx; I = [pscustomobject]@{ Name = "FOLDER$([int]$fx.Index)"; Type = 'Folder'; Path = "$($fx.Path)" } } }
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
        Write-HMLog $Job "Summe: $(Format-HMSize $sum) - nur Dateien; Registry, Windows-Einstellungen (USMT), Treiber und Schriftarten werden mitgesichert, ihre Groesse ist vorab aber nicht messbar" 'Success'
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
# BROWSER (Chromium: Edge, Chrome, Brave, Vivaldi): Lesezeichen zuverlaessig uebertragen
# ============================================================================
# Kennwoerter, Cookies und Zahlungsdaten sind an Windows-Konto und PC gebunden (DPAPI, App-Bound Encryption) und werden
# bewusst weder entschluesselt noch auf einen anderen PC kopiert. Lesezeichen (Datei Bookmarks, Klartext-JSON) werden
# auf einem anderen PC ZUSAMMENGEFUEHRT: Ordner "Uebernommen von <PC> (<Datum>)" in der Lesezeichenleiste.
# Gleicher PC + gleiches Konto (Computer-ID + Computername + SID): kompletter Ordner wie bisher.
# Eintraege mit Eigenschaft Chromium (relativer Pfad zu "User Data", leer = Eintrag ist "User Data") nutzen diesen Weg.

# JSON lesen/schreiben ohne Groessen-/Tiefengrenze von ConvertFrom-Json (Windows PowerShell 5.1); Woerterbuecher + object[]
function New-HMJsonSerializer {
    Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop
    $js = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $js.MaxJsonLength = [int]::MaxValue; $js.RecursionLimit = 1000
    return $js
}
function ConvertFrom-HMJsonText([string]$Text) {
    if ($PSVersionTable.PSVersion.Major -ge 6) { return , (ConvertFrom-Json -InputObject $Text -AsHashtable -Depth 1000) }   # PowerShell 7
    return , (New-HMJsonSerializer).DeserializeObject($Text)
}
# Eigener JSON-Schreiber (C#, schnell auch bei grossen Lesezeichen-Dateien): JavaScriptSerializer scheitert an
# PowerShell-Huellen (PSObject) in Listen, ConvertTo-Json an der Tiefe. Woerterbuecher, Listen, Texte, Zahlen, true/false/null.
$script:HMJsonCs = @'
using System;
using System.Collections;
using System.Globalization;
using System.Text;
namespace HMJ {
    public static class Writer {
        public static string Write(object o) { var sb = new StringBuilder(); W(sb, o, 0); return sb.ToString(); }
        static void S(StringBuilder sb, string s) {
            sb.Append('"');
            foreach (char c in s) {
                if (c == '"') sb.Append("\\\"");
                else if (c == '\\') sb.Append("\\\\");
                else if (c < ' ') sb.Append("\\u").Append(((int)c).ToString("x4"));
                else sb.Append(c);
            }
            sb.Append('"');
        }
        static void W(StringBuilder sb, object v, int d) {
            if (d > 1000) throw new InvalidOperationException("JSON zu tief verschachtelt");
            var ps = v as System.Management.Automation.PSObject;
            if (ps != null) v = ps.BaseObject;
            if (v == null) { sb.Append("null"); return; }
            if (v is string || v is char || v is Guid) { S(sb, v.ToString()); return; }
            if (v is DateTime) { S(sb, ((DateTime)v).ToString("o", CultureInfo.InvariantCulture)); return; }
            if (v is bool) { sb.Append((bool)v ? "true" : "false"); return; }
            var dict = v as IDictionary;
            if (dict != null) {
                sb.Append('{'); bool first = true;
                foreach (DictionaryEntry e in dict) { if (!first) sb.Append(','); first = false; S(sb, Convert.ToString(e.Key, CultureInfo.InvariantCulture)); sb.Append(':'); W(sb, e.Value, d + 1); }
                sb.Append('}'); return;
            }
            var list = v as IEnumerable;
            if (list != null) {
                sb.Append('['); bool first = true;
                foreach (object x in list) { if (!first) sb.Append(','); first = false; W(sb, x, d + 1); }
                sb.Append(']'); return;
            }
            if (v is double || v is float) { sb.Append(Convert.ToDouble(v, CultureInfo.InvariantCulture).ToString("R", CultureInfo.InvariantCulture)); return; }
            var cv = v as IConvertible;
            if (cv != null) { sb.Append(cv.ToString(CultureInfo.InvariantCulture)); return; }
            S(sb, v.ToString());
        }
    }
}
'@
function ConvertTo-HMJsonText($Object) {
    if (-not ('HMJ.Writer' -as [type])) { Add-Type -TypeDefinition $script:HMJsonCs -ErrorAction Stop }
    return [HMJ.Writer]::Write($Object)
}
# Wert aus einem JSON-Woerterbuch (Gross-/Kleinschreibung exakt, fehlender Schluessel = $null)
function Get-HMJ($Dict, [string]$Key) {
    if ($null -eq $Dict -or -not ($Dict -is [System.Collections.IDictionary])) { return $null }
    foreach ($k in @($Dict.Keys)) { if ([string]$k -ceq $Key) { return $Dict[$k] } }
    return $null
}
# Datei lesen, auch wenn ein Programm sie offen haelt; $null bei Fehler/fehlend
function Read-HMSharedText([string]$Path) {
    if (-not $Path -or -not [System.IO.File]::Exists($Path)) { return $null }
    try {
        $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        try { $sr = New-Object System.IO.StreamReader($fs, (New-Object System.Text.UTF8Encoding($false)), $true); return $sr.ReadToEnd() } finally { $fs.Dispose() }
    } catch { return $null }
}
function Read-HMJsonFileSafe([string]$Path) {
    $t = Read-HMSharedText $Path
    if (-not $t) { return $null }
    try { return , (ConvertFrom-HMJsonText $t) } catch { return $null }
}

# Profile eines Chromium-"User Data"-Ordners: Ordner (Default, Profile N), Anzeigename, Konto (gaia_id/user_name)
function Get-HMChromiumProfiles([string]$UserData, $LocalState) {
    $out = New-Object System.Collections.Generic.List[object]
    if (-not $UserData -or -not [System.IO.Directory]::Exists($UserData)) { return $out.ToArray() }
    $cache = Get-HMJ (Get-HMJ $LocalState 'profile') 'info_cache'
    foreach ($d in @([System.IO.Directory]::GetDirectories($UserData))) {
        $f = [System.IO.Path]::GetFileName($d)
        if ($f -ne 'Default' -and $f -notmatch '^Profile \d+$') { continue }
        if (-not [System.IO.File]::Exists((Join-Path $d 'Preferences')) -and -not [System.IO.File]::Exists((Join-Path $d 'Bookmarks'))) { continue }
        $ci = Get-HMJ $cache $f
        $acct = "$(Get-HMJ $ci 'gaia_id')"
        $mail = "$(Get-HMJ $ci 'user_name')"
        $out.Add([pscustomobject]@{ Folder = $f; Name = "$(Get-HMJ $ci 'name')"; Gaia = $acct; User = $mail })
    }
    return $out.ToArray()
}

# Zuordnung Quellprofil -> Zielprofil (rein, testbar). Mode: Copy (Ziel hat noch kein Profil), Merge, SameAccount, None
# Regeln: gleiches Konto -> nichts einfuegen (kommt ueber die Synchronisierung); sonst gleicher Anzeigename; sonst einziges
# Zielprofil; sonst zuletzt benutztes; Ziel ohne Profil -> Hauptprofil der Quelle nach Default, weitere nur als HTML.
function Resolve-HMChromiumMap([object[]]$Source, [string]$SourceLastUsed, [object[]]$Target, [string]$TargetLastUsed) {
    $src = @($Source | Where-Object { $_ }); $dst = @($Target | Where-Object { $_ })
    $out = New-Object System.Collections.Generic.List[object]
    if (-not $src.Count) { return $out.ToArray() }
    $same = { param($a, $b) ("$a".Trim() -and "$b".Trim() -and "$a".Trim().ToLowerInvariant() -eq "$b".Trim().ToLowerInvariant()) }
    if (-not $dst.Count) {
        $main = @($src | Where-Object { $_.Folder -eq $SourceLastUsed })[0]
        if (-not $main) { $main = @($src | Where-Object { $_.Folder -eq 'Default' })[0] }
        if (-not $main) { $main = $src[0] }
        foreach ($s in $src) {
            if ($s -eq $main) { $out.Add([pscustomobject]@{ Src = $s; Dst = 'Default'; Mode = 'Copy'; Reason = 'Browser am Ziel noch ohne Profil' }) }
            else { $out.Add([pscustomobject]@{ Src = $s; Dst = ''; Mode = 'None'; Reason = 'weiteres Profil - Browser am Ziel hat noch kein Profil dafuer' }) }
        }
        return $out.ToArray()
    }
    foreach ($s in $src) {
        $hit = @($dst | Where-Object { (& $same $s.Gaia $_.Gaia) -or (& $same $s.User $_.User) })[0]
        if ($hit) { $out.Add([pscustomobject]@{ Src = $s; Dst = $hit.Folder; Mode = 'SameAccount'; Reason = 'gleiches Konto' }); continue }
        $hit = @($dst | Where-Object { & $same $s.Name $_.Name })[0]
        $why = 'gleicher Profilname'
        if (-not $hit -and $dst.Count -eq 1) { $hit = $dst[0]; $why = 'einziges Profil am Ziel' }
        if (-not $hit) { $hit = @($dst | Where-Object { $_.Folder -eq $TargetLastUsed })[0]; $why = 'zuletzt benutztes Profil am Ziel' }
        if (-not $hit) { $hit = @($dst | Where-Object { $_.Folder -eq 'Default' })[0]; $why = 'Standardprofil am Ziel' }
        if (-not $hit) { $hit = $dst[0]; $why = 'erstes Profil am Ziel' }
        $out.Add([pscustomobject]@{ Src = $s; Dst = $hit.Folder; Mode = 'Merge'; Reason = $why })
    }
    return $out.ToArray()
}

# Gleicher PC und gleiches Konto? Nur wenn Computer-ID (MachineGuid), Computername und Benutzer-SID alle stimmen
function Test-HMSameMachine($Manifest, [string]$TargetGuid, [string]$TargetComputer, [string]$TargetSid) {
    if (-not $Manifest) { return $false }
    $g = "$($Manifest.MachineGuid)".Trim(); $c = "$($Manifest.SourceComputer)".Trim(); $s = "$($Manifest.UserSid)".Trim()
    if (-not $g -or -not $c -or -not $s -or -not "$TargetGuid".Trim() -or -not "$TargetComputer".Trim() -or -not "$TargetSid".Trim()) { return $false }
    return ($g -ieq "$TargetGuid".Trim() -and $c.Split('.')[0] -ieq "$TargetComputer".Trim().Split('.')[0] -and $s -ieq "$TargetSid".Trim())
}
# Fall fuer den Bericht (rein, testbar): F1 = gleicher PC + gleiches Konto, sonst Grund
function Get-HMSameMachineText($Manifest, [string]$TargetGuid, [string]$TargetComputer, [string]$TargetSid) {
    if (Test-HMSameMachine $Manifest $TargetGuid $TargetComputer $TargetSid) { return 'gleicher PC und gleiches Konto (Computer-ID, Computername und Benutzer-SID stimmen)' }
    if (-not $Manifest) { return 'anderer PC angenommen: Backup ohne Manifest (Vorgaengerversion)' }
    if (-not "$($Manifest.MachineGuid)".Trim()) { return 'anderer PC angenommen: Backup ohne Computer-ID (mit aelterer HUMig-Version erstellt)' }
    if (-not "$TargetGuid".Trim()) { return 'anderer PC angenommen: Computer-ID des Ziel-PCs nicht lesbar' }
    $why = @()
    if ("$($Manifest.SourceComputer)".Trim().Split('.')[0] -ine "$TargetComputer".Trim().Split('.')[0]) { $why += 'anderer Computername' }
    if ("$($Manifest.MachineGuid)".Trim() -ine "$TargetGuid".Trim()) { $why += 'andere Computer-ID (anderer PC oder Windows neu installiert)' }
    if ("$($Manifest.UserSid)".Trim() -ine "$TargetSid".Trim()) { $why += 'anderes Benutzerkonto (SID)' }
    if (-not $why.Count) { $why = @('Angaben unvollstaendig') }
    return "anderer PC oder anderes Konto: $($why -join ', ')"
}
$script:HMMachineGuidScript = {
    try {
        $k = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
        $c = $k.OpenSubKey('SOFTWARE\Microsoft\Cryptography')
        if ($c) { "$($c.GetValue('MachineGuid'))" } else { '' }
    } catch { '' }
}
function Get-HMMachineGuid([hashtable]$Ctx) { try { return "$(@(Invoke-HMTarget $Ctx $script:HMMachineGuidScript)[0])" } catch { return '' } }
function Test-HMBrowserSameMachine([hashtable]$Ctx) {
    if ($null -eq $Ctx.BrowserSameMachine) {
        $mf = if ($Ctx.Backup) { $Ctx.Backup.Manifest } else { $null }
        $g = Get-HMMachineGuid $Ctx
        $Ctx.BrowserSameMachine = [bool](Test-HMSameMachine $mf $g "$($Ctx.Computer)" "$($Ctx.UserSid)")
        $Ctx.BrowserCase = Get-HMSameMachineText $mf $g "$($Ctx.Computer)" "$($Ctx.UserSid)"
    }
    return [bool]$Ctx.BrowserSameMachine
}
# Eintrag mit Eigenschaft Chromium (PSCustomObject aus JSON oder Hashtable)
function Test-HMChromiumItem($Item) {
    if ($null -eq $Item) { return $false }
    if ($Item -is [System.Collections.IDictionary]) { return (@($Item.Keys) -contains 'Chromium') }
    return ($null -ne $Item.PSObject.Properties['Chromium'])
}
function Test-HMBrowserModule($Module) {
    if ("$($Module.Group)" -eq 'Browser') { return $true }
    return (@($Module.Items | Where-Object { Test-HMChromiumItem $_ }).Count -gt 0)
}
# Browser-Version aus "User Data\Last Version" ('' wenn unbekannt)
function Get-HMChromiumVersion([string]$UserData) {
    $t = Read-HMSharedText (Join-Path $UserData 'Last Version')
    if ($t -and "$t".Trim() -match '^[\d.]{3,30}$') { return "$t".Trim() }
    return ''
}

# Lesezeichen-Baum: Anzahl Links, hoechste id
function Get-HMBookmarkStats($Bookmarks) {
    $st = [pscustomobject]@{ Urls = 0; MaxId = [long]0 }
    $stack = New-Object System.Collections.Generic.Stack[object]
    $roots = Get-HMJ $Bookmarks 'roots'
    if ($roots -is [System.Collections.IDictionary]) { foreach ($k in @($roots.Keys)) { if ($roots[$k] -is [System.Collections.IDictionary]) { $stack.Push($roots[$k]) } } }
    while ($stack.Count) {
        $n = $stack.Pop()
        $id = [long]0; if ([long]::TryParse("$(Get-HMJ $n 'id')", [ref]$id) -and $id -gt $st.MaxId) { $st.MaxId = $id }
        if ("$(Get-HMJ $n 'type')" -eq 'url') { $st.Urls++ }
        foreach ($c in @(Get-HMJ $n 'children')) { if ($c -is [System.Collections.IDictionary]) { $stack.Push($c) } }
    }
    return $st
}
function Get-HMWebKitNow { return [string][long](([DateTime]::UtcNow - (New-Object DateTime(1601, 1, 1, 0, 0, 0, [DateTimeKind]::Utc))).Ticks / 10) }

# Zusammenfuehren (rein, testbar): alte Lesezeichen als neuer Ordner in die Lesezeichenleiste des Ziels.
# Ziel ohne Lesezeichen -> Quelle 1:1 (ohne Sync-Metadaten). Neue ids/guids, keine meta_info/sync_metadata, checksum entfernt.
# Rueckgabe: Result (Woerterbuch oder $null = nichts schreiben), Added, Note
function Merge-HMChromiumBookmarks($Target, $Source, [string]$FolderName) {
    $res = [pscustomobject]@{ Result = $null; Added = 0; Note = '' }
    $ss = Get-HMBookmarkStats $Source
    if (-not $ss.Urls) { $res.Note = 'keine Lesezeichen im Backup'; return $res }
    $ts = if ($Target) { Get-HMBookmarkStats $Target } else { [pscustomobject]@{ Urls = 0; MaxId = [long]0 } }
    if (-not $Target -or -not $ts.Urls -or -not (Get-HMJ (Get-HMJ $Target 'roots') 'bookmark_bar')) {
        foreach ($k in @('checksum', 'sync_metadata')) { if ($null -ne (Get-HMJ $Source $k)) { [void]$Source.Remove($k) } }
        $res.Result = $Source; $res.Added = $ss.Urls; $res.Note = 'Ziel hatte noch keine Lesezeichen - uebernommen wie im Backup'
        return $res
    }
    $bar = Get-HMJ (Get-HMJ $Target 'roots') 'bookmark_bar'
    foreach ($c in @(Get-HMJ $bar 'children')) {
        if ($c -is [System.Collections.IDictionary] -and "$(Get-HMJ $c 'type')" -eq 'folder' -and "$(Get-HMJ $c 'name')" -eq $FolderName) { $res.Note = "Ordner '$FolderName' ist schon vorhanden - nicht noch einmal eingefuegt"; return $res }
    }
    $ctr = @{ N = [long]$ts.MaxId }   # Hashtable: in verschachtelten Scriptblocks gemeinsam hochgezaehlt
    $now = Get-HMWebKitNow
    $clone = $null
    $clone = {
        param($n)
        $ctr.N++
        $o = New-Object System.Collections.Specialized.OrderedDictionary
        foreach ($k in @('date_added', 'date_last_used', 'date_modified')) { $v = Get-HMJ $n $k; if ($null -ne $v) { $o[$k] = "$v" } }
        $o['guid'] = [guid]::NewGuid().ToString()
        $o['id'] = [string]$ctr.N
        $o['name'] = "$(Get-HMJ $n 'name')"
        $t = "$(Get-HMJ $n 'type')"
        if ($t -eq 'folder') {
            $kids = New-Object System.Collections.Generic.List[object]
            foreach ($c in @(Get-HMJ $n 'children')) { if ($c -is [System.Collections.IDictionary]) { $kids.Add((& $clone $c)) } }
            $o['children'] = $kids.ToArray()
            if ($null -eq $o['date_added']) { $o['date_added'] = $now }
            if ($null -eq $o['date_modified']) { $o['date_modified'] = $now }
            $o['type'] = 'folder'
        } else {
            $o['type'] = 'url'
            $o['url'] = "$(Get-HMJ $n 'url')"
            if ($null -eq $o['date_added']) { $o['date_added'] = $now }
        }
        return $o
    }
    $mkFolder = {
        param([string]$Name, [object[]]$Kids)
        $ctr.N++
        $f = New-Object System.Collections.Specialized.OrderedDictionary
        $f['children'] = @($Kids); $f['date_added'] = $now; $f['date_modified'] = $now
        $f['guid'] = [guid]::NewGuid().ToString(); $f['id'] = [string]$ctr.N; $f['name'] = $Name; $f['type'] = 'folder'
        return $f
    }
    $sr = Get-HMJ $Source 'roots'
    $top = New-Object System.Collections.Generic.List[object]
    foreach ($c in @(Get-HMJ (Get-HMJ $sr 'bookmark_bar') 'children')) { if ($c -is [System.Collections.IDictionary]) { $top.Add((& $clone $c)) } }
    foreach ($p in @(@('other', 'Weitere Lesezeichen'), @('synced', 'Mobile Lesezeichen'))) {
        $kids = New-Object System.Collections.Generic.List[object]
        foreach ($c in @(Get-HMJ (Get-HMJ $sr $p[0]) 'children')) { if ($c -is [System.Collections.IDictionary]) { $kids.Add((& $clone $c)) } }
        if ($kids.Count) { $top.Add((& $mkFolder $p[1] $kids.ToArray())) }
    }
    $folder = & $mkFolder $FolderName $top.ToArray()
    $bar['children'] = @(@(Get-HMJ $bar 'children') | Where-Object { $null -ne $_ }) + @($folder)
    if ($null -ne (Get-HMJ $Target 'checksum')) { [void]$Target.Remove('checksum') }
    $res.Result = $Target; $res.Added = $ss.Urls; $res.Note = "Ordner '$FolderName' mit $($ss.Urls) Lesezeichen eingefuegt"
    return $res
}

# Lesezeichen als HTML (Netscape-Format, von jedem Browser importierbar)
function ConvertTo-HMBookmarkHtml($Bookmarks, [string]$Title) {
    $enc = { param($s) [System.Net.WebUtility]::HtmlEncode("$s") }
    $unix = { param($w) $x = [long]0; if ([long]::TryParse("$w", [ref]$x) -and $x -gt 11644473600000000) { [string][long](($x / 1000000) - 11644473600) } else { '0' } }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<!DOCTYPE NETSCAPE-Bookmark-file-1>')
    [void]$sb.AppendLine('<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">')
    [void]$sb.AppendLine("<TITLE>$(& $enc $Title)</TITLE>")
    [void]$sb.AppendLine("<H1>$(& $enc $Title)</H1>")
    [void]$sb.AppendLine('<DL><p>')
    $walk = $null
    $walk = {
        param($n, [string]$Ind, [bool]$Bar)
        if ("$(Get-HMJ $n 'type')" -eq 'folder') {
            $attr = if ($Bar) { ' PERSONAL_TOOLBAR_FOLDER="true"' } else { '' }
            [void]$sb.AppendLine("$Ind<DT><H3 ADD_DATE=`"$(& $unix (Get-HMJ $n 'date_added'))`" LAST_MODIFIED=`"$(& $unix (Get-HMJ $n 'date_modified'))`"$attr>$(& $enc (Get-HMJ $n 'name'))</H3>")
            [void]$sb.AppendLine("$Ind<DL><p>")
            foreach ($c in @(Get-HMJ $n 'children')) { if ($c -is [System.Collections.IDictionary]) { & $walk $c ($Ind + '    ') $false } }
            [void]$sb.AppendLine("$Ind</DL><p>")
        } else {
            [void]$sb.AppendLine("$Ind<DT><A HREF=`"$(& $enc (Get-HMJ $n 'url'))`" ADD_DATE=`"$(& $unix (Get-HMJ $n 'date_added'))`">$(& $enc (Get-HMJ $n 'name'))</A>")
        }
    }
    $roots = Get-HMJ $Bookmarks 'roots'
    $first = $true
    foreach ($r in @('bookmark_bar', 'other', 'synced')) {
        $n = Get-HMJ $roots $r
        if (-not ($n -is [System.Collections.IDictionary])) { continue }
        if (-not @(Get-HMJ $n 'children').Count -and -not $first) { continue }
        & $walk $n '    ' $first
        $first = $false
    }
    [void]$sb.AppendLine('</DL><p>')
    return $sb.ToString()
}

# Erweiterungen eines Profils (Ordner Extensions\<id>\<Version>\manifest.json) -> Name + Store-Link
function Get-HMChromiumExtensions([string]$ProfileDir, [bool]$Edge) {
    $out = New-Object System.Collections.Generic.List[object]
    $ed = Join-Path $ProfileDir 'Extensions'
    if (-not [System.IO.Directory]::Exists($ed)) { return $out.ToArray() }
    foreach ($d in @([System.IO.Directory]::GetDirectories($ed))) {
        $id = [System.IO.Path]::GetFileName($d)
        if ($id -notmatch '^[a-p]{32}$') { continue }
        $ver = @([System.IO.Directory]::GetDirectories($d) | Sort-Object)[-1]
        if (-not $ver) { continue }
        $m = Read-HMJsonFileSafe (Join-Path $ver 'manifest.json')
        $name = "$(Get-HMJ $m 'name')"
        if ($name -match '^__MSG_(.+)__$') {
            $key = $Matches[1]; $loc = "$(Get-HMJ $m 'default_locale')"
            foreach ($l in @('de', $loc, 'en') | Where-Object { $_ }) {
                $msg = Read-HMJsonFileSafe (Join-Path $ver "_locales\$l\messages.json")
                if ($msg) { foreach ($k in @($msg.Keys)) { if ("$k" -ieq $key) { $name = "$(Get-HMJ $msg[$k] 'message')"; break } } }
                if ($name -notmatch '^__MSG_') { break }
            }
        }
        if (-not $name -or $name -match '^__MSG_') { $name = $id }
        $url = "$(Get-HMJ $m 'update_url')"
        $link = if ($Edge -and $url -notmatch 'google\.com') { "https://microsoftedge.microsoft.com/addons/detail/$id" } else { "https://chromewebstore.google.com/detail/$id" }
        $out.Add([pscustomobject]@{ Id = $id; Name = $name; Link = $link })
    }
    return $out.ToArray()
}

# Backup: je Profil Lesezeichen-HTML und Liste der Erweiterungen in den Backup-Ordner (Browser-Lesezeichen\...)
function Save-HMBrowserExtras([hashtable]$Ctx, $Module, $Item) {
    $lines = New-Object System.Collections.Generic.List[string]
    $ud = Get-HMItemTargetPath $Ctx.BackupPath $Module $Item
    if ("$($Item.Chromium)") { $ud = Join-Path $ud "$($Item.Chromium)" }
    if (-not [System.IO.Directory]::Exists($ud)) { return $lines.ToArray() }
    $out = Join-Path $Ctx.BackupPath 'Browser-Lesezeichen'
    $edge = ("$($Module.Id)" -eq 'Edge' -or "$($Item.Path)" -match '\\Microsoft\\Edge')
    $bname = if ($Module.Name) { "$($Module.Name)" -replace '-Profil$', '' } else { "$($Module.Id)" }
    foreach ($p in @(Get-HMChromiumProfiles $ud (Read-HMJsonFileSafe (Join-Path $ud 'Local State')))) {
        $pd = Join-Path $ud $p.Folder
        $label = if ($p.Name) { "$($p.Folder) ($($p.Name))" } else { $p.Folder }
        $base = ConvertTo-HMSafeName ("{0}_{1}" -f $Module.Id, $(if ($p.Name) { $p.Name } else { $p.Folder }))
        if (-not [System.IO.Directory]::Exists($out)) { [void][System.IO.Directory]::CreateDirectory($out) }
        $bm = Read-HMJsonFileSafe (Join-Path $pd 'Bookmarks')
        if (-not $bm) { $bm = Read-HMJsonFileSafe (Join-Path $pd 'Bookmarks.bak') }
        if ($bm) {
            $n = (Get-HMBookmarkStats $bm).Urls
            [System.IO.File]::WriteAllText((Join-Path $out "$base.html"), (ConvertTo-HMBookmarkHtml $bm "$bname - $label"), (New-Object System.Text.UTF8Encoding($false)))
            $lines.Add("Profil ${label}: $n Lesezeichen, zusaetzlich als Browser-Lesezeichen\$base.html (in jedem Browser importierbar)")
        }
        $ext = @(Get-HMChromiumExtensions $pd $edge)
        if ($ext.Count) {
            $sb = New-Object System.Text.StringBuilder
            [void]$sb.AppendLine("<!DOCTYPE html><html lang=`"de`"><head><meta charset=`"utf-8`"><title>Erweiterungen - $([System.Net.WebUtility]::HtmlEncode("$bname - $label"))</title></head><body>")
            [void]$sb.AppendLine("<h1>Erweiterungen - $([System.Net.WebUtility]::HtmlEncode("$bname - $label"))</h1><p>Am neuen PC ueber den Link neu installieren (oder per Synchronisierung).</p><ul>")
            foreach ($e in $ext) { [void]$sb.AppendLine("<li><a href=`"$([System.Net.WebUtility]::HtmlEncode($e.Link))`">$([System.Net.WebUtility]::HtmlEncode($e.Name))</a></li>") }
            [void]$sb.AppendLine('</ul></body></html>')
            [System.IO.File]::WriteAllText((Join-Path $out "${base}_Erweiterungen.html"), $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
            $lines.Add("Profil ${label}: $($ext.Count) Erweiterung(en) als Liste mit Links: Browser-Lesezeichen\${base}_Erweiterungen.html")
        }
    }
    return $lines.ToArray()
}

# Datei atomar schreiben (Temp-Datei, dann ersetzen); vorher Sicherung der alten Datei
# Verknuepfung (Symlink/Junction)? Im Benutzerprofil nie ueber eine Verknuepfung lesen/schreiben (HUMig laeuft als Administrator)
function Test-HMReparse([string]$Path) {
    try {
        if (-not [System.IO.File]::Exists($Path) -and -not [System.IO.Directory]::Exists($Path)) { return $false }
        return (([System.IO.File]::GetAttributes($Path) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
    } catch { return $true }
}
function Write-HMFileAtomic([string]$Path, [string]$Text, [string]$BackupName) {
    # zufaelliger Name + CreateNew: eine vom Benutzer vorbereitete Datei/Verknuepfung gleichen Namens wird nie benutzt
    $tmp = "$Path.humig-$([guid]::NewGuid().ToString('N')).tmp"
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($Text)
    $fs = New-Object System.IO.FileStream($tmp, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }
    if ([System.IO.File]::Exists($Path)) {
        # Sicherung nur beim ersten Mal (der Stand vor HUMig bleibt erhalten)
        if ($BackupName) { $bk = Join-Path ([System.IO.Path]::GetDirectoryName($Path)) $BackupName; if (-not [System.IO.File]::Exists($bk)) { [System.IO.File]::Copy($Path, $bk, $false) } }
        [System.IO.File]::Delete($Path)
    }
    [System.IO.File]::Move($tmp, $Path)
}

# Restore eines Chromium-Eintrags
function Restore-HMChromiumItem {
    param([hashtable]$Ctx, $Job, $Module, $Item, [string]$Src, [string]$DstLocal)
    $sub = "$($Item.Chromium)"
    $dst = Convert-HMPath $Ctx $DstLocal
    $udSrc = if ($sub) { Join-Path $Src $sub } else { $Src }
    $udDstLocal = if ($sub) { Join-Path $DstLocal $sub } else { $DstLocal }
    $udDst = Convert-HMPath $Ctx $udDstLocal
    $mk = { param($st, $msg) [pscustomobject]@{ Name = $Item.Name; Status = $st; Msg = $msg } }
    # unmittelbar vor dem Schreiben (in jedem Fall): Browser am Ziel darf nicht laufen - Hintergrundprozesse/Startup Boost schreiben sonst ihren Stand zurueck
    $names = @($Module.CloseProcess | Where-Object { "$_".Trim() })
    if ($names.Count) {
        $run = @(); try { $run = @(Get-HMRunningProcs $Ctx $names $Ctx.UserSid) } catch { }
        if ($run.Count) { $run = @(Close-HMProcs $Ctx $Job $run $true) }
        if ($run.Count) { return (& $mk 'Error' "$(@($names) -join ', ') laeuft am Ziel und liess sich nicht beenden - Browser nicht zurueckgespielt (sonst ueberschreibt er die Daten wieder). Browser schliessen und Restore fuer dieses Modul wiederholen") }
    }
    $same = Test-HMBrowserSameMachine $Ctx
    $case = "Erkannter Fall: $($Ctx.BrowserCase)"
    # F1 - gleicher PC und gleiches Konto: kompletter Ordner 1:1 (Kennwoerter/Cookies bleiben lesbar); nie /XO (gemischte Staende beschaedigen das Profil)
    if ($same) {
        $rc = Invoke-HMRobocopy -Job $Job -Source $Src -Dest $dst -Threads $Ctx.Threads -LogFile $Ctx.RoboLog
        if ($null -ne $Ctx.RestoredUserDirs) { [void]$Ctx.RestoredUserDirs.Add("$DstLocal") }
        $st = switch ($rc.Level) { 'OK' { 'OK' } 'Warning' { 'Warning' } 'Cancel' { 'Cancel' } default { 'Error' } }
        $m = "$case`n" + ("vollstaendig zurueckgespielt wie gesichert ({0} Dateien, {1}) - auch Kennwoerter, Anmeldungen und Einstellungen" -f $rc.FilesTotal, (Format-HMSize $rc.BytesTotal))
        if ($rc.FilesFailed -gt 0) { $m += ", $($rc.FilesFailed) FEHLGESCHLAGEN (Browser geoeffnet?)"; if ($st -ne 'Cancel') { $st = 'Error' } }
        return (& $mk $st $m)
    }
    if (-not [System.IO.Directory]::Exists($udSrc)) { return (& $mk 'Skip' 'keine Browser-Profile im Backup') }
    $lines = New-Object System.Collections.Generic.List[string]
    $st = 'OK'
    $lines.Add($case)
    $lines.Add('Uebernommen: Lesezeichen (zusammengefuehrt), bei neuem Browser-Profil auch Verlauf und Einstellungen')
    $lines.Add('Nicht uebertragbar (an Windows-Konto und PC gebunden, bewusst weggelassen): gespeicherte Kennwoerter, Anmeldungen (Cookies), Zahlungsdaten, Sync-Zustand, Local State, geschuetzte Einstellungen (PreferenceMACs) - so geht''s: siehe Hinweise unten')
    $srcLs = Read-HMJsonFileSafe (Join-Path $udSrc 'Local State')
    $dstLs = Read-HMJsonFileSafe (Join-Path $udDst 'Local State')
    $srcP = @(Get-HMChromiumProfiles $udSrc $srcLs)
    $dstP = @(Get-HMChromiumProfiles $udDst $dstLs)
    $map = @(Resolve-HMChromiumMap $srcP "$(Get-HMJ (Get-HMJ $srcLs 'profile') 'last_used')" $dstP "$(Get-HMJ (Get-HMJ $dstLs 'profile') 'last_used')")
    if (-not $map.Count) { return (& $mk 'Skip' 'keine Browser-Profile im Backup') }
    $pc = "$($Ctx.Backup.Computer)"; if (-not $pc -and $Ctx.Backup.Manifest) { $pc = "$($Ctx.Backup.Manifest.SourceComputer)" }
    if (-not $pc) { $pc = 'altem PC' }
    $bd = [datetime]::MinValue
    $date = if ([datetime]::TryParse("$($Ctx.Backup.Created)", [ref]$bd)) { $bd.ToString('dd.MM.yyyy') } else { (Get-Date).ToString('dd.MM.yyyy') }
    $multi = @($map | Where-Object { $_.Mode -in @('Merge', 'Copy') }).Count -gt 1
    foreach ($e in $map) {
        if (Test-HMCancel $Job) { $st = 'Cancel'; break }
        $sp = $e.Src
        $label = if ($sp.Name) { "$($sp.Folder) ($($sp.Name))" } else { $sp.Folder }
        $sDir = Join-Path $udSrc $sp.Folder
        try {
            switch ($e.Mode) {
                'SameAccount' { $lines.Add("Profil ${label}: am Ziel mit demselben Konto angemeldet ($($e.Dst)) - Lesezeichen kommen ueber die Synchronisierung, nichts eingefuegt") }
                'None' { $lines.Add("Profil ${label}: nicht zurueckgespielt ($($e.Reason)) - Lesezeichen liegen als HTML im Backup (Browser-Lesezeichen)") }
                'Copy' {
                    $dDirLocal = Join-Path $udDstLocal $e.Dst
                    $xf = @('Login Data*', 'Cookies*', 'Extension Cookies*', 'Safe Browsing Cookies*', 'Secure Preferences', 'Bookmarks.humig-*')
                    $xd = @((Join-Path $sDir 'Sync Data'), (Join-Path $sDir 'Network'), (Join-Path $sDir 'Extension State'))
                    $rc = Invoke-HMRobocopy -Job $Job -Source $sDir -Dest (Convert-HMPath $Ctx $dDirLocal) -XD $xd -XF $xf -Threads $Ctx.Threads -LogFile $Ctx.RoboLog
                    $bp = Join-Path (Convert-HMPath $Ctx $dDirLocal) 'Bookmarks'
                    $bm = if ((Test-HMReparse (Convert-HMPath $Ctx $dDirLocal)) -or (Test-HMReparse $bp)) { $null } else { Read-HMJsonFileSafe $bp }
                    if ($null -ne $Ctx.RestoredUserDirs) { [void]$Ctx.RestoredUserDirs.Add("$dDirLocal") }
                    if ($bm) {
                        foreach ($k in @('checksum', 'sync_metadata')) { if ($null -ne (Get-HMJ $bm $k)) { [void]$bm.Remove($k) } }
                        Write-HMFileAtomic $bp (ConvertTo-HMJsonText $bm) ''
                    }
                    $lines.Add("Profil ${label} -> $($e.Dst): $($rc.FilesTotal) Dateien (Lesezeichen, Verlauf, Einstellungen; ohne Kennwoerter/Cookies/Sync-Daten) - $($e.Reason)")
                    if ($rc.Level -in @('Error', 'Cancel')) { $st = 'Error' } elseif ($rc.Level -eq 'Warning' -and $st -eq 'OK') { $st = 'Warning' }
                }
                'Merge' {
                    # eigener Name: $src waere der [string]-Parameter $Src (Variablen ohne Gross-/Kleinschreibung)
                    $bmSrc = Read-HMJsonFileSafe (Join-Path $sDir 'Bookmarks')
                    if (-not $bmSrc) { $bmSrc = Read-HMJsonFileSafe (Join-Path $sDir 'Bookmarks.bak') }
                    if (-not $bmSrc) {
                        if ([System.IO.File]::Exists((Join-Path $sDir 'Bookmarks'))) { $lines.Add("Profil ${label}: Lesezeichen-Datei im Backup nicht lesbar - HTML im Backup verwenden"); if ($st -eq 'OK') { $st = 'Warning' } }
                        else { $lines.Add("Profil ${label}: keine Lesezeichen im Backup") }
                        continue
                    }
                    $dDir = Convert-HMPath $Ctx (Join-Path $udDstLocal $e.Dst)
                    $bp = Join-Path $dDir 'Bookmarks'
                    if ((Test-HMReparse $udDst) -or (Test-HMReparse $dDir) -or (Test-HMReparse $bp)) { $lines.Add("Profil ${label}: Zielordner oder Lesezeichen-Datei ist eine Verknuepfung - aus Sicherheitsgruenden nichts geaendert, HTML im Backup verwenden"); if ($st -eq 'OK') { $st = 'Warning' }; continue }
                    $tgt = $null
                    if ([System.IO.File]::Exists($bp)) {
                        $tgt = Read-HMJsonFileSafe $bp
                        if (-not $tgt) { $lines.Add("Profil ${label}: Lesezeichen-Datei am Ziel ($($e.Dst)) nicht lesbar - nichts geaendert, HTML im Backup verwenden"); if ($st -eq 'OK') { $st = 'Warning' }; continue }
                    }
                    $fname = "Uebernommen von $pc ($date)" + $(if ($multi) { " - $(if ($sp.Name) { $sp.Name } else { $sp.Folder })" } else { '' })
                    $r = Merge-HMChromiumBookmarks $tgt $bmSrc $fname
                    if ($r.Result) {
                        if (-not [System.IO.Directory]::Exists($dDir)) { [void][System.IO.Directory]::CreateDirectory($dDir) }
                        Write-HMFileAtomic $bp (ConvertTo-HMJsonText $r.Result) 'Bookmarks.humig-vorher'
                        if ($null -ne $Ctx.RestoredUserDirs) { [void]$Ctx.RestoredUserDirs.Add((Join-Path $udDstLocal $e.Dst)) }
                        $lines.Add("Profil ${label} -> $($e.Dst) ($($e.Reason)): $($r.Note)$(if ([System.IO.File]::Exists((Join-Path $dDir 'Bookmarks.humig-vorher'))) { '; vorheriger Stand: Bookmarks.humig-vorher' })")
                    } else { $lines.Add("Profil ${label} -> $($e.Dst): $($r.Note)") }
                }
            }
        } catch {
            $lines.Add("Profil ${label}: FEHLER $($_.Exception.Message)"); $st = 'Error'
        }
    }
    $lines.Add('Hinweis: Wird der Browser am neuen PC spaeter mit dem Konto des alten PCs angemeldet, kann der Ordner "Uebernommen von ..." doppelt erscheinen - dann einen davon loeschen')
    $lines.Add('Anmeldungen: auf den Webseiten neu anmelden; Erweiterungen: Liste mit Links im Backup (Browser-Lesezeichen\*_Erweiterungen.html) oder ueber die Browser-Synchronisierung')
    $lines.Add('Kennwoerter: am alten PC im Browser exportieren (Einstellungen > Kennwoerter) und am neuen PC importieren - die CSV-Datei ist Klartext und danach zu loeschen - oder die Browser-Synchronisierung nutzen')
    return (& $mk $st ($lines -join "`n"))
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

# Zielpfad unter Windows, Programme, ProgramData oder dem Tool-Ordner? Rueckgabe: getroffener Ordner oder ''.
# Ohne TEnv (z.B. Werkzeuge ohne Zielumgebung): Standardnamen auf jedem Laufwerk. Pfade mit . / .. / 8.3-Kurznamen /
# \\?\ / Admin-Freigaben (C$) gelten ebenfalls als geschuetzt (sonst waere die Pruefung umgehbar).
function Get-HMProtectedTargetRoot([string]$Path, [hashtable]$TEnv, [string]$AppRoot) {
    $p = "$Path".Trim().TrimEnd('\')
    if (-not $p) { return '' }
    if ($p -match '^\\\\[?.]\\') { return $p }
    if ($p -match '^\\\\[^\\]+\\[A-Za-z]\$(\\|$)') { return $p }
    if ($p -match '(^|\\)\.{1,2}(\\|$)') { return $p }
    # 8.3-Kurzname (z.B. PROGRA~1) koennte einen Systemordner verbergen -> wie Systemziel behandeln.
    # Nur echte 8.3-Segmente (max. 6 Zeichen vor ~), "Version~2" o.ae. bleibt normal
    foreach ($seg in $p.Split('\')) { if ($seg -match '^[^\\.~]{1,6}~\d{1,6}(\.[^\\.]{0,3})?$') { return $p } }
    $roots = New-Object System.Collections.Generic.List[string]
    if ($TEnv) { foreach ($k in 'WINDIR', 'PROGRAMFILES', 'PROGRAMFILESX86', 'PROGRAMDATA') { if ("$($TEnv[$k])".Trim()) { $roots.Add("$($TEnv[$k])".Trim().TrimEnd('\')) } } }
    if ("$AppRoot".Trim()) { $roots.Add("$AppRoot".Trim().TrimEnd('\')) }
    foreach ($r in $roots) {
        if ($p -ieq $r -or $p.StartsWith($r + '\', [StringComparison]::OrdinalIgnoreCase)) { return $r }
    }
    if ($p -match '^([A-Za-z]:\\(Windows|Program Files|Program Files \(x86\)|ProgramData))(\\|$)') { return $Matches[1] }
    return ''
}

# SIDs der direkten Mitglieder der lokalen Administratorgruppe (einmal je Sitzung ermittelt; Fehler -> leere Liste)
function Get-HMLocalAdminSids {
    if ($null -eq $script:HMLocalAdminSidCache) {
        $l = @()
        try { $l = @(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop | ForEach-Object { "$($_.SID)" } | Where-Object { $_ }) } catch { $l = @() }
        $script:HMLocalAdminSidCache = $l
    }
    return @($script:HMLocalAdminSidCache)
}

# Maschinen-Module, die Dateien aus dem Backup mit Administratorrechten verarbeiten (Aufgaben, Treiber, Drucker, ...):
# Besitzer dieser Dateien pruefen. Vertrauenswuerdig: Administratoren, SYSTEM, TrustedInstaller, das aktuelle Konto und
# direkte Mitglieder der lokalen Administratorgruppe. Zusaetzliche Ordner (ExtraFolders) werden nicht geprueft -
# Systemziele werden dort ohnehin umgeleitet (Get-HMProtectedTargetRoot).
# Rueckgabe: je betroffenem Modul Id, Name, Owner (Kontoname/SID), File. Ohne ACL (z.B. Linux) oder bei Fehlern: leere Liste.
function Get-HMUntrustedBackupItems($BackupPath, $Modules) {
    $out = New-Object System.Collections.Generic.List[object]
    try {
        if (-not "$BackupPath" -or -not (Test-Path -LiteralPath "$BackupPath")) { return @() }
        $trusted = @('S-1-5-32-544', 'S-1-5-18', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
        try { $trusted += [Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch { }
        $trusted += @(Get-HMLocalAdminSids)
        # Modul-Id -> Dateien/Ordner im Backup (neues Format und Vorgaengerversion)
        $legacyOf = @{ Tasks = 'TASKSHEDULLER'; Fonts = 'FONTS'; Drivers = 'DRIVERS'; PrintersFull = 'PRINTERScomplete.printerExport' }
        foreach ($m in @($Modules)) {
            if (-not $m) { continue }
            $id = if ($m -is [string]) { $m } else { "$($m.Id)" }
            $mname = if ($m -is [string]) { $m } elseif ("$($m.Name)") { "$($m.Name)" } else { $id }
            if ($id -notin @('Tasks', 'Fonts', 'Drivers', 'PrintersFull', 'Shares')) { continue }
            $dir = Join-Path "$BackupPath" $id
            $paths = New-Object System.Collections.Generic.List[string]
            $addDir = {
                param($d, [string]$filter, [switch]$Recurse)
                if (-not (Test-Path -LiteralPath $d)) { return }
                $paths.Add($d)
                foreach ($f in @(Get-ChildItem -LiteralPath $d -Filter $filter -File -Recurse:$Recurse -Force -ErrorAction SilentlyContinue | Select-Object -First 500)) { $paths.Add($f.FullName) }
            }
            switch ($id) {
                'Tasks'        { $paths.Add((Join-Path $dir 'tasks.json')); & $addDir $dir '*.xml' }
                'Fonts'        { $paths.Add((Join-Path $dir 'fonts.json')); & $addDir (Join-Path $dir 'FONTS') '*' }
                'Drivers'      { & $addDir (Join-Path $dir 'DRIVERS') '*.inf' -Recurse }
                'PrintersFull' { $paths.Add((Join-Path $dir 'Printers.printerExport')) }
                'Shares'       { $paths.Add((Join-Path $dir 'shares.json')) }
            }
            $lg = $legacyOf[$id]
            if ($lg) {
                $lp = Join-Path "$BackupPath" $lg
                if ($id -eq 'PrintersFull') { $paths.Add($lp) }
                elseif ($id -eq 'Tasks') { & $addDir $lp '*.xml' }
                elseif ($id -eq 'Drivers') { & $addDir $lp '*.inf' -Recurse }
                else { & $addDir $lp '*' }
            }
            foreach ($p in @($paths | Select-Object -Unique)) {
                if (-not (Test-Path -LiteralPath $p)) { continue }
                $sid = ''
                try { $sid = (Get-Acl -LiteralPath $p -ErrorAction Stop).GetOwner([Security.Principal.SecurityIdentifier]).Value } catch { continue }
                if (-not $sid -or $trusted -contains $sid) { continue }
                $who = $sid
                try { $who = (New-Object Security.Principal.SecurityIdentifier($sid)).Translate([Security.Principal.NTAccount]).Value } catch { }
                $out.Add([pscustomobject]@{ Id = $id; Name = $mname; Owner = $who; File = $p })
                break
            }
        }
    } catch { return @() }
    return $out.ToArray()
}

function Restore-HMFolderItem {
    param([hashtable]$Ctx, $Job, $Module, $Item, [hashtable]$TEnv, [string]$SourceOverride, [string]$DestOverride)
    $src = if ($SourceOverride) { $SourceOverride } else { Get-HMRestoreSource $Ctx $Module $Item }
    if (-not $src -or -not (Test-Path -LiteralPath $src)) { return [pscustomobject]@{ Name = $Item.Name; Status = 'Skip'; Msg = 'nicht im Backup' } }
    $dstLocal = if ($DestOverride) { $DestOverride } else { Resolve-HMToken $TEnv $Item.Path }
    $dst = Convert-HMPath $Ctx $dstLocal
    # Ziel-Laufwerk fehlt am Ziel-PC (z.B. D:\Daten, am neuen PC gibt es kein D:) -> verstaendlicher Hinweis statt Kopierfehler
    if ($dstLocal -match '^([A-Za-z]):') {
        $drv = $Matches[1].ToUpper()
        if (-not (Test-Path -LiteralPath (Convert-HMPath $Ctx "${drv}:\"))) {
            return [pscustomobject]@{ Name = $Item.Name; Status = 'Warning'; Msg = "Laufwerk ${drv}: gibt es an $($Ctx.Computer) nicht (oder nicht erreichbar) - $dstLocal nicht zurueckgeschrieben. Die Daten liegen im Backup: $src - bei Bedarf von Hand an einen anderen Ort kopieren oder Laufwerk anlegen und Restore wiederholen" }
        }
    }
    # Chromium-Browser: je nach Fall 1:1 (gleicher PC + Konto) oder Lesezeichen zusammenfuehren (Restore-HMChromiumItem)
    if ($Item.Type -eq 'Folder' -and -not $SourceOverride -and -not $DestOverride -and (Test-HMChromiumItem $Item)) {
        return (Restore-HMChromiumItem -Ctx $Ctx -Job $Job -Module $Module -Item $Item -Src $src -DstLocal $dstLocal)
    }
    $files = @(); $noRec = $false
    if ($Item.Type -eq 'Files') { $files = @($Item.Filter); $noRec = $true }
    if ("$($Item.Role)" -eq 'Database' -and $files.Count) { $files = @(Add-HMDbCompanions $files) }
    # Cloud-Ordner (OneDrive/SharePoint) aus dem Backup nie direkt in den Sync-Ordner schreiben (wuerde neuere Cloud-Versionen ueberschreiben)
    $xd = @(); $syncs = @()
    $mf = if ($Ctx.Backup) { $Ctx.Backup.Manifest } else { $null }
    if ($mf -and $mf.SyncRoots) {
        $syncs = @($mf.SyncRoots | Where-Object { $_ -and $_.Rel -and $_.Item -eq "$($Module.Id)/$($Item.Name)" })
        foreach ($s in $syncs) { $xd += (Join-Path $src $s.Rel) }
    }
    $rc = Invoke-HMRobocopy -Job $Job -Source $src -Dest $dst -Files $files -XD $xd -NoRecurse:$noRec -ExcludeOlder:([bool]$Ctx.Options.KeepNewer) -Threads $Ctx.Threads -LogFile $Ctx.RoboLog
    # wiederhergestellte Ordner im Profil des Zielbenutzers merken -> danach Besitzer auf den Benutzer setzen (Repair-HMRestoredOwner)
    if ($null -ne $Ctx.RestoredUserDirs -and $Ctx.ProfilePath -and "$dstLocal".StartsWith("$($Ctx.ProfilePath)".TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { [void]$Ctx.RestoredUserDirs.Add("$dstLocal") }
    $st = switch ($rc.Level) { 'OK' { 'OK' } 'Warning' { 'Warning' } 'Cancel' { 'Cancel' } default { 'Error' } }
    $msg = "{0} Dateien, {1} -> {2}" -f $rc.FilesTotal, (Format-HMSize $rc.BytesTotal), $dstLocal
    if ($Ctx.Options.KeepNewer -and $rc.FilesCopied -lt $rc.FilesTotal) { $msg += " ($($rc.FilesCopied) kopiert, neuere/gleiche am Ziel behalten)" }
    if ($rc.FilesFailed -gt 0) { $msg += ", $($rc.FilesFailed) FEHLGESCHLAGEN (Datei geoeffnet? siehe Robocopy-Log)"; if ($st -ne 'Cancel') { $st = 'Error' } }
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
    # Kontrolle: liegt jede Datei aus dem Backup jetzt am Ziel? (nur Liste, nichts wird kopiert - Robocopy /L)
    if ($Ctx.Options.VerifyAfter -and $st -ne 'Cancel' -and -not (Test-HMCancel $Job)) {
        $v = Test-HMRestoredItem -Ctx $Ctx -Job $Job -Src $src -Dst $dst -DstLocal $dstLocal -Files $files -XD $xd -NoRecurse:$noRec
        if ($v.Error) { $msg += " | Kontrolle nicht moeglich ($($v.Error))" }
        elseif ($v.Missing -gt 0) {
            $msg += " | KONTROLLE: $($v.Missing) Datei(en) fehlen am Ziel (Liste: Restore_*_Fehlende.txt)"
            if ($st -eq 'OK') { $st = 'Warning' }
        }
    }
    return [pscustomobject]@{ Name = $Item.Name; Status = $st; Msg = $msg }
}

# Kontrolle nach dem Restore: Dateien, die im Backup liegen, am Ziel aber fehlen (gleiche Auswahl wie beim Kopieren).
# Pfade werden fuer die Liste in $Ctx.MissingAfter gesammelt (Zielpfad, wie am Ziel-PC).
function Test-HMRestoredItem {
    param([hashtable]$Ctx, $Job, [string]$Src, [string]$Dst, [string]$DstLocal, [string[]]$Files = @(), [string[]]$XD = @(), [switch]$NoRecurse)
    $res = [pscustomobject]@{ Missing = 0; Error = '' }
    try {
        $f = Find-HMDeletedInBackup -Backup $Src -Source $Dst -Files $Files -XD $XD -NoRecurse:$NoRecurse -Job $Job
        if ($f.ExitCode -ge 8) { $res.Error = "Robocopy-Code $($f.ExitCode)"; return $res }
        $paths = @($f.Paths)
        $res.Missing = $paths.Count
        if ($paths.Count -and $null -ne $Ctx.MissingAfter) {
            $s0 = $Src.TrimEnd('\')
            foreach ($p in $paths) { if ($Ctx.MissingAfter.Count -lt 20000) { [void]$Ctx.MissingAfter.Add(("$DstLocal".TrimEnd('\') + $p.Substring($s0.Length))) } }
        }
    } catch { $res.Error = "$($_.Exception.Message)" }
    return $res
}

function Restore-HMRegItem {
    param([hashtable]$Ctx, $Job, $Module, $Item)
    $src = Get-HMRestoreSource $Ctx $Module $Item
    if (-not $src -or -not (Test-Path -LiteralPath $src)) { return [pscustomobject]@{ Name = $Item.Name; Status = 'Skip'; Msg = 'nicht im Backup' } }
    $isUser = $Item.Key -match '^HK(CU|EY_CURRENT_USER)'
    if ($isUser -and -not $Ctx.HiveReady) { return [pscustomobject]@{ Name = $Item.Name; Status = 'Error'; Msg = 'Benutzer-Registry am Ziel nicht verfuegbar' } }
    # an den PC gebunden (z.B. PreferenceMACs der Browser): nur am gleichen PC mit gleichem Konto zurueckspielen
    if ($Item.SameMachineOnly -and -not (Test-HMBrowserSameMachine $Ctx)) {
        return [pscustomobject]@{ Name = $Item.Name; Status = 'Skip'; Msg = "nicht zurueckgespielt - an PC und Konto gebunden, gilt nur am gleichen PC ($($Ctx.BrowserCase)); der Browser legt die Werte selbst neu an" }
    }
    $r = Import-HMReg $Ctx $Job $src $Ctx.Backup.Sid $Ctx.Backup.ProfilePath $Item
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
        "`r`nStop-Transcript | Out-Null`r`nUnregister-ScheduledTask -TaskName '$($name -replace "'", "''")' -Confirm:`$false -ErrorAction SilentlyContinue`r`nRemove-Item -LiteralPath `$MyInvocation.MyCommand.Path -Force -ErrorAction SilentlyContinue"
    try {
    $r = Invoke-HMTargetProtected $Ctx {
        param($n, $acct, $code, $rid)
        # eigener Ordner je Lauf: nur SYSTEM/Administratoren schreiben, nur dieses Konto darf lesen und ausfuehren
        $base = Join-Path $env:ProgramData 'HUMig\FirstLogon'
        New-Item -ItemType Directory -Path $base -Force | Out-Null
        # alte Laeufe (Aufgabe laeuft hoechstens 30 Tage) aufraeumen
        foreach ($o in @(Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-31) })) { Remove-Item -LiteralPath $o.FullName -Recurse -Force -ErrorAction SilentlyContinue }
        $dir = Join-Path $base $rid
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $ic = & icacls.exe "$dir" /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' "${acct}:(OI)(CI)RX" 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Rechte fuer $dir nicht setzbar: $ic" }
        $f = Join-Path $dir "$n.ps1"
        Set-Content -LiteralPath $f -Value $code -Encoding UTF8
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
    } @($name, $Ctx.Account, $body, $runId)
    } catch { Write-HMLog $Job "Anmelde-Aktionen nicht eingerichtet: $($_.Exception.Message)" 'Warning'; return }
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
                    if ((Test-Path -LiteralPath $sp) -and (Test-Path -LiteralPath $tf)) { $entries += [pscustomobject]@{ Src = $sp; Path = ((Get-Content -LiteralPath $tf | Where-Object { $_ })[-1]).Trim(); Key = '' } }
                }
            } else {
                $jf = Join-Path $dir 'folders.json'
                if (Test-Path -LiteralPath $jf) {
                    # erst zuweisen, dann durchlaufen: PS 5.1 gibt ein JSON-Array aus ConvertFrom-Json als EIN Objekt aus
                    $fj = Get-Content -LiteralPath $jf -Raw -Encoding UTF8 | ConvertFrom-Json
                    foreach ($e in @(@($fj) | Where-Object { $_ -and [int]$_.Index -gt 0 -and "$($_.Path)" })) { $entries += [pscustomobject]@{ Src = (Join-Path $dir "FOLDER$($e.Index)"); Path = $e.Path; Key = "FOLDER$($e.Index)" } }
                }
            }
            if (-not $entries.Count) { return (& $res 'Skip' 'keine Ordner im Backup') }
            $worst = 'OK'; $lines = @()
            # Sync-Ordner (OneDrive/SharePoint) des ZIELbenutzers am Ziel-PC - dorthin nie direkt schreiben
            $tRoots = @()
            try { $tRoots = @(Get-HMSyncRoots $Ctx $Ctx.UserSid $Ctx.ProfilePath | Where-Object { $_ }) } catch { Write-HMLog $Job "   OneDrive-Ordner am Ziel nicht ermittelbar: $($_.Exception.Message)" 'Debug' }
            $under = { param($p, $root) $r0 = "$root".TrimEnd('\'); return ($r0 -and ("$p".TrimEnd('\') -ieq $r0 -or "$p".StartsWith($r0 + '\', [StringComparison]::OrdinalIgnoreCase))) }
            $usersRoot = if ($Ctx.ProfilePath) { Split-Path "$($Ctx.ProfilePath)".TrimEnd('\') -Parent } else { '' }
            foreach ($e in $entries) {
                $dest = "$($e.Path)".TrimEnd('\'); $note = ''; $leaf = Split-Path $dest -Leaf
                # Pfad im Profil des Quell-Benutzers -> ins Profil des Zielbenutzers umschreiben (anderer Profilname/Benutzer)
                $srcProf = "$($Ctx.Backup.ProfilePath)".TrimEnd('\')
                if ($srcProf -and $Ctx.ProfilePath -and (& $under $dest $srcProf)) { $dest = "$($Ctx.ProfilePath)".TrimEnd('\') + $dest.Substring($srcProf.Length) }
                # liegt sonst im Profil EINES ANDEREN Benutzers -> nicht dorthin, sondern in das Profil des Zielbenutzers
                elseif ($usersRoot -and (& $under $dest $usersRoot) -and -not (& $under $dest $Ctx.ProfilePath)) {
                    $dest = Join-Path $Ctx.ProfilePath (Join-Path 'Zusaetzliche Ordner' $leaf)
                    $note = " (Originalpfad $($e.Path) liegt im Profil eines anderen Benutzers - stattdessen hierher)"
                }
                # Windows, Programme, ProgramData, Tool-Ordner: nie dorthin (Restore laeuft mit Adminrechten) -> ins Profil des Zielbenutzers
                $pr = Get-HMProtectedTargetRoot $dest $TEnv $(if (-not $Ctx.IsRemote) { "$($Ctx.ToolRoot)" } else { '' })
                if ($pr) {
                    if (-not $Ctx.ProfilePath) {
                        $lines += "$($e.Path) - nicht zurueckgeschrieben: Ziel liegt in einem Systemordner ($pr) und der Zielbenutzer hat kein Profil. Die Daten liegen im Backup: $($e.Src)"
                        if ($worst -eq 'OK') { $worst = 'Warning' }
                        continue
                    }
                    $lf = if ($leaf -and $leaf -notmatch '^\.+$' -and $leaf -notmatch '[:\\]') { $leaf } else { 'Ordner' }
                    $dest = Join-Path $Ctx.ProfilePath (Join-Path 'Zusaetzliche Ordner' $lf)
                    $note = " (Originalpfad $($e.Path) liegt in einem Systemordner ($pr) - aus Sicherheitsgruenden stattdessen hierher; bei Bedarf von Hand verschieben)"
                }
                # liegt im OneDrive-/SharePoint-Ordner des Zielbenutzers -> eigener Ordner, sonst wuerden neuere Cloud-Versionen ueberschrieben
                $hitRoot = @($tRoots | Where-Object { & $under $dest $_ })[0]
                if ($hitRoot -and $Ctx.ProfilePath) {
                    $dest = Join-Path $Ctx.ProfilePath (Join-Path 'OneDrive-Wiederherstellung' $leaf)
                    $note += " (Ziel liegt im Cloud-Ordner $hitRoot - nicht direkt hineingeschrieben, damit neuere Cloud-Versionen nicht ueberschrieben werden; bei Bedarf von Hand uebernehmen)"
                }
                $fake = [pscustomobject]@{ Name = $(if ($e.Key) { $e.Key } else { $leaf }); Type = 'Folder'; Path = $dest }
                $r = Restore-HMFolderItem $Ctx $Job $Module $fake $TEnv -SourceOverride $e.Src -DestOverride $dest
                if ($note -and $r.Status -eq 'OK') { $r.Status = 'Warning' }
                $lines += "$($e.Path) - $($r.Msg)$note"
                if ($r.Status -in @('Error', 'Cancel')) { $worst = $r.Status } elseif ($r.Status -ne 'OK' -and $worst -eq 'OK') { $worst = $r.Status }
            }
            return (& $res $worst ("$($entries.Count) Ordner`n" + ($lines -join "`n")))
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
            if (-not $Ctx.Backup.Legacy -and (Test-Path -LiteralPath $jf)) { $mj = Get-Content -LiteralPath $jf -Raw -Encoding UTF8 | ConvertFrom-Json; foreach ($e in @($mj)) { if ($e.File) { $map[(Split-Path $e.File -Leaf).ToLower()] = $e.Name } } }
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
                if (Test-Path -LiteralPath $jf) { $tj = Get-Content -LiteralPath $jf -Raw -Encoding UTF8 | ConvertFrom-Json; $files = @(@($tj) | ForEach-Object { [pscustomobject]@{ Path = $_.Path; Name = $_.Name; File = (Join-Path $dir $_.File) } }) }
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
        $unsafe = ''
        if (Test-Path -LiteralPath $ps) { $unsafe = Get-HMWritableByNonAdmins $ps }
        if ($unsafe) {
            Write-HMLog $Job "   Nach-Skript NICHT ausgefuehrt: $ps ist fuer Nicht-Administratoren beschreibbar ($unsafe) - wuerde mit Administratorrechten laufen. Datei an einen Ort legen, den nur Administratoren aendern koennen." 'Error'
        } elseif (Test-Path -LiteralPath $ps) {
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
# Nach dem Restore: Besitzer der wiederhergestellten Ordner im Profil auf den Zielbenutzer setzen (kopiert hat der Administrator -
# Besitzer waere sonst 'Administratoren'; stoert z.B. SSH StrictModes, manche Browser-Profile, Lizenzpruefungen). Rechte (ACL) bleiben
# unveraendert - kein pauschales Grant. Danach Schreibprobe ueber die ACL: Desktop, AppData\Roaming, ein wiederhergestellter Programm-Ordner.
# Links (Junction/symbolische Verknuepfung) unter $Root, deren Ziel ausserhalb von $Root liegt (icacls /T folgt Junctions).
# Links selbst werden nicht durchlaufen; andere Reparse-Ordner (OneDrive) schon. Eigenstaendig (wird auch am Ziel-PC
# per Definition ausgefuehrt). Rueckgabe: "<link> -> <ziel>" (hoechstens $Max).
# $Bound (optional): zusaetzlich erlaubte Grenze (z.B. Profilordner) - Links mit Ziel innerhalb $Root oder der Grenze sind ok;
# liegt das Ziel ausserhalb von $Root, wird es mit durchsucht, da icacls /T ihnen folgt.
function Find-HMOutsideLinks {
    param([string]$Root, [int]$Max = 20, [string]$Bound = '')
    $hits = New-Object System.Collections.Generic.List[string]
    if (-not $Root) { return @() }
    $isIn = {
        param([string]$p, [string]$r)
        $p = $p.TrimEnd('\', '/'); $r = $r.TrimEnd('\', '/')
        return ($p -ieq $r -or $p.StartsWith($r + '\', [StringComparison]::OrdinalIgnoreCase) -or $p.StartsWith($r + '/', [StringComparison]::OrdinalIgnoreCase))
    }
    $linkTarget = {
        param([string]$p)
        $it = Get-Item -LiteralPath $p -Force -ErrorAction Stop
        if ("$($it.LinkType)" -notin @('Junction', 'SymbolicLink')) { return $null }
        $t = "$(@($it.Target)[0])"
        if ($t.StartsWith('\??\')) { $t = $t.Substring(4) }
        if (-not $t) { return '?' }
        if ($t -match '^(Volume\{|\\\\\?\\)') { return $t }   # Laufwerks-Bereitstellungspunkt: immer ausserhalb
        try {
            if (-not [System.IO.Path]::IsPathRooted($t)) { $t = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($p.TrimEnd('\', '/')), $t) }
            $t = [System.IO.Path]::GetFullPath($t)
        } catch { }
        return $t
    }
    try { $rootFull = [System.IO.Path]::GetFullPath($Root) } catch { $rootFull = $Root }
    $boundFull = ''
    if ("$Bound".Trim()) { try { $boundFull = [System.IO.Path]::GetFullPath($Bound) } catch { $boundFull = $Bound } }
    $stack = New-Object System.Collections.Generic.Stack[string]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    # Wurzel selbst ein Link? (Ziel innerhalb der Grenze: Ziel durchsuchen)
    try {
        $t0 = & $linkTarget $Root
        if ($null -ne $t0) {
            if (-not $boundFull -or -not (& $isIn $t0 $boundFull)) { $hits.Add("$Root -> $t0"); return $hits.ToArray() }
            $rootFull = $t0
        }
    } catch { }
    [void]$seen.Add($rootFull.TrimEnd('\', '/'))
    $stack.Push($Root)
    while ($stack.Count -gt 0 -and $hits.Count -lt $Max) {
        $d = $stack.Pop()
        $subs = @()
        try { $subs = [System.IO.Directory]::GetDirectories($d) } catch { continue }
        foreach ($s in $subs) {
            $attr = 0
            try { $attr = [int][System.IO.File]::GetAttributes($s) } catch { continue }
            if (($attr -band 0x400) -eq 0) { $stack.Push($s); continue }
            $t = $null
            try { $t = & $linkTarget $s } catch { $hits.Add("$s -> ? ($($_.Exception.Message))"); if ($hits.Count -ge $Max) { break }; continue }
            if ($null -eq $t) { $stack.Push($s); continue }   # Reparse ohne Link (z.B. OneDrive): weiter durchlaufen
            if (& $isIn $t $rootFull) { continue }
            if (-not $boundFull -or -not (& $isIn $t $boundFull)) { $hits.Add("$s -> $t"); if ($hits.Count -ge $Max) { break }; continue }
            # Ziel innerhalb der Grenze, aber ausserhalb von $Root: dort ebenfalls suchen (je Ziel nur einmal, keine Schleifen)
            if ($seen.Add($t.TrimEnd('\', '/'))) { $stack.Push($t) }
        }
    }
    return $hits.ToArray()
}

function Repair-HMRestoredOwner([hashtable]$Ctx, $Job, [hashtable]$TEnv) {
    if ($Ctx.UserMode -or -not $Ctx.UserSid -or $null -eq $Ctx.RestoredUserDirs -or -not $Ctx.RestoredUserDirs.Count) { return }
    $dirs = @($Ctx.RestoredUserDirs | Select-Object -Unique | Sort-Object Length)
    $top = New-Object System.Collections.Generic.List[string]
    foreach ($d in $dirs) { if (-not @($top | Where-Object { $d.StartsWith($_.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or $d -ieq $_ }).Count) { $top.Add($d) } }
    $app = @($top | Where-Object { $TEnv.APPDATA -and $_.StartsWith("$($TEnv.APPDATA)".TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1)
    $probe = @((Join-Path $Ctx.ProfilePath 'Desktop'), "$($TEnv.APPDATA)") + $app | Where-Object { $_ } | Select-Object -Unique
    Write-HMLog $Job "Besitzer der wiederhergestellten Profil-Ordner auf $($Ctx.Account) setzen ($($top.Count) Ordner) ..." 'Info'
    $r = Invoke-HMTarget $Ctx {
        param($dirs, $sid, $acct, $probe, $linkDef, $prof)
        $who = if ("$acct".Trim()) { "$acct" } else { "*$sid" }
        $ok = 0; $bad = @()
        $findLinks = $null; try { $findLinks = [scriptblock]::Create($linkDef) } catch { }
        foreach ($d in @($dirs)) {
            if (-not (Test-Path -LiteralPath $d)) { continue }
            # icacls /T folgt Junctions: Ordner mit Link nach ausserhalb nicht anfassen
            if ($findLinks) {
                # Grenze = Profilordner: Links innerhalb des Profils (z.B. Documents\My Music -> Music) sind ok
                $lk = @(); try { $lk = @(& $findLinks $d 5 "$prof") } catch { }
                if ($lk.Count) { foreach ($x in $lk) { "OWNSKIP|Link nach ausserhalb ($x) - Besitzer nicht gesetzt: $d" }; continue }
            }
            $o = & icacls.exe "$d" /setowner "$who" /T /C /Q 2>&1
            if ($LASTEXITCODE -eq 0) { $ok++ } else { $bad += "${d}: $(@($o | Where-Object { "$_".Trim() }) | Select-Object -First 2)" }
        }
        "OWN|$ok|$(@($dirs).Count)"
        foreach ($b in $bad) { "OWNERR|$b" }
        # Schreibrecht des Benutzers laut ACL (eigene SID + Jeder, Authentifizierte, Interaktiv, Benutzer, Besitzerrechte); Verweigern hat Vorrang
        $grp = @($sid, 'S-1-1-0', 'S-1-5-11', 'S-1-5-4', 'S-1-5-32-545', 'S-1-3-4')
        foreach ($p in @($probe)) {
            if (-not (Test-Path -LiteralPath $p)) { "PROBE|$p|fehlt"; continue }
            $allow = $false; $deny = $false; $owner = ''
            try {
                $a = Get-Acl -LiteralPath $p
                try { $owner = (New-Object System.Security.Principal.NTAccount($a.Owner)).Translate([System.Security.Principal.SecurityIdentifier]).Value } catch { }
                foreach ($e in @($a.Access)) {
                    $es = ''; try { $es = $e.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value } catch { $es = "$($e.IdentityReference)" }
                    if ($grp -notcontains $es) { continue }
                    if (([int]$e.FileSystemRights -band 2) -eq 0) { continue }   # 2 = WriteData / Dateien erstellen
                    if ("$($e.AccessControlType)" -eq 'Deny') { $deny = $true } else { $allow = $true }
                }
            } catch { "PROBE|$p|nicht lesbar: $($_.Exception.Message)"; continue }
            "PROBE|$p|$(if ($allow -and -not $deny) { 'ja' } else { 'NEIN' })|$(if ($owner -eq $sid) { 'Besitzer ok' } else { 'Besitzer: ' + $a.Owner })"
        }
    } @($top.ToArray(), $Ctx.UserSid, "$($Ctx.Account)", $probe, "${function:Find-HMOutsideLinks}", "$($Ctx.ProfilePath)")
    $warn = $false
    foreach ($l in @($r | Where-Object { $_ })) {
        $x = "$l".Split('|')
        switch ($x[0]) {
            'OWN' { Write-HMLog $Job "   Besitzer gesetzt: $($x[1]) von $($x[2]) Ordner(n) (Rechte unveraendert)" $(if ([int]$x[1] -lt [int]$x[2]) { 'Warning' } else { 'Success' }) }
            'OWNERR' { $warn = $true; Write-HMLog $Job "   Besitzer nicht gesetzt: $($x[1..($x.Count - 1)] -join '|')" 'Warning' }
            'OWNSKIP' { $warn = $true; Write-HMLog $Job "   $($x[1..($x.Count - 1)] -join '|')" 'Warning' }
            'PROBE' {
                if ($x[2] -eq 'fehlt') { Write-HMLog $Job "   Schreibprobe $(ConvertFrom-HMPath $x[1]): Ordner fehlt" 'Debug'; break }
                if ($x[2] -eq 'NEIN') { $warn = $true }
                Write-HMLog $Job "   Schreibrecht des Benutzers $(ConvertFrom-HMPath $x[1]): $($x[2])$(if ($x.Count -gt 3) { " - $($x[3])" })" $(if ($x[2] -eq 'ja') { 'Success' } else { 'Warning' })
            }
        }
    }
    if ($warn) { Write-HMLog $Job '   Hinweis: Der Benutzer kann evtl. nicht in alle wiederhergestellten Ordner schreiben - Rechte pruefen (Eigenschaften > Sicherheit)' 'Warning' }
}

function Start-HMRestore {
    param([hashtable]$Ctx, $Job)
    $Ctx.RestoredUserDirs = New-Object System.Collections.Generic.List[string]
    $Ctx.MissingAfter = New-Object System.Collections.Generic.List[string]
    $start = Get-Date
    $Ctx.IsRemote = -not (Test-HMIsLocal $Ctx.Computer)
    if (-not $Ctx.IsRemote) { $Ctx.Computer = $env:COMPUTERNAME }
    $Ctx.LogonActions = @()
    $Ctx.DesktopIconLines = @()
    $Ctx.BrowserSameMachine = $null; $Ctx.BrowserCase = ''
    $Job.LogFile = Join-Path $Ctx.Backup.Path ("Restore_{0}_{1}.log" -f (ConvertTo-HMSafeName $Ctx.Computer), $start.ToString('yyyyMMdd_HHmm'))
    $Ctx.RoboLog = Join-Path $Ctx.Backup.Path ("Restore_{0}_{1}_Robocopy.log" -f (ConvertTo-HMSafeName $Ctx.Computer), $start.ToString('yyyyMMdd_HHmm'))
    Write-HMLog $Job "RESTORE  $($Ctx.Backup.Name)  ->  $($Ctx.Computer) \ $($Ctx.UserFolder)" 'Header'
    try {
        $dm = if ($Ctx.Backup.Manifest) { $Ctx.Backup.Manifest.Deleted } else { $null }
        if ($dm -and [int]$dm.Files -gt 0) { Write-HMLog $Job "$([int]$dm.Files) beiseitegelegte (am Quell-PC geloeschte) Datei(en) werden nicht zurueckgespielt - bei Bedarf: Im Backup suchen > Mit geloeschten" 'Info' }
        if ($Ctx.Backup.Manifest -and $Ctx.Backup.Manifest.MassDeleteAlert) { Write-HMLog $Job 'ACHTUNG: beim letzten Backup wurde eine Massenloeschung an der Quelle erkannt (typisches Zeichen fuer einen Verschluesselungstrojaner) - Backup-Stand vor dem Restore pruefen' 'Warning' }
    } catch { }
    if ($Ctx.Backup.Legacy) { Write-HMLog $Job 'Backup der Vorgaengerversion erkannt (ohne manifest.json)' 'Info' }
    $skipApps = @(@($Ctx.SkippedApps) | Where-Object { $_ } | ForEach-Object { "$($_.Name)" })
    if ($skipApps.Count) { Write-HMLog $Job "Programm-Einstellungen ausgelassen (Programm am Ziel nicht installiert): $($skipApps -join ', ') - nach der Installation Restore nur mit diesen Modulen wiederholen" 'Warning' }
    if ($Ctx.Options.VerifyAfter) { Write-HMLog $Job 'Nach jedem Ordner wird kontrolliert, ob alle Dateien aus dem Backup am Ziel liegen' 'Debug' }

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
            # Backup nicht von einem Administrator angelegt und Uebernahme nicht bestaetigt -> Modul mit Adminrechten auslassen
            if (@($Ctx.SkipUntrustedMachine) -contains "$($mod.Id)") {
                $sm = 'ausgelassen: Backup wurde nicht von einem Administrator angelegt (Uebernahme nicht bestaetigt)'
                Write-HMLog $Job "   $sm" 'Warning'
                $results += [pscustomobject]@{ Id = $mod.Id; Name = $mod.Name; Status = 'Warning'; Items = @([pscustomobject]@{ Name = 'Hinweis'; Status = 'Warning'; Msg = $sm }); Process = $null; Service = $null }
                $done += @($mod.Items).Count
                $Job.Progress = [int](100 * $done / $total)
                continue
            }
            $worst = 'OK'
            $itemLog = @()
            $pre = Enter-HMModule $Ctx $Job $mod $tenv 'Restore'
            foreach ($w in @($pre.Warn)) { Write-HMLog $Job "   $w" 'Warning'; $itemLog += [pscustomobject]@{ Name = 'Hinweis'; Status = 'Warning'; Msg = $w }; $worst = 'Warning' }
            try {
            foreach ($it in @($mod.Items)) {
                if (Test-HMCancel $Job) { break }
                if ($pre.Skip) { $done++; continue }
                if ($pre.SkipServiceItems -and (Test-HMServiceItem $it)) {
                    $itemLog += [pscustomobject]@{ Name = $it.Name; Status = 'Warning'; Msg = 'ausgelassen: Dienst-Datenbank (Dienst nicht gestoppt)' }
                    if ($worst -eq 'OK') { $worst = 'Warning' }
                    $done++; continue
                }
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
                    Write-HMLog $Job ("   {0}: {1}" -f $r.Name, ("$($r.Msg)" -replace "`r?`n", "`n      ")) $lvl
                    $itemLog += [pscustomobject]@{ Name = $r.Name; Status = $r.Status; Msg = $r.Msg }
                }
                if ($r.Status -in @('Error', 'Cancel')) { $worst = 'Error' } elseif ($r.Status -eq 'Warning' -and $worst -eq 'OK') { $worst = 'Warning' }
                $done++
                $Job.Progress = [int](100 * $done / $total)
            }
            } finally { Exit-HMModule $Ctx $Job $pre }
            if (@($itemLog | Where-Object { $_.Status -ne 'Skip' }).Count -eq 0 -and $worst -eq 'OK') { $worst = 'Skip' }
            $results += [pscustomobject]@{ Id = $mod.Id; Name = $mod.Name; Status = $worst; Items = $itemLog; Process = $pre.ProcAction; Service = $pre.ServiceAction }
        }

        # Explorer-/Taskleisten-Einstellungen greifen erst nach Explorer-Neustart
        if (@($mods | Where-Object { $_.Id -in @('TaskbarWallpaper', 'DesktopIcons', 'QuickAccess') }).Count) {
            Add-HMLogonAction $Ctx "# Explorer neu starten, damit Taskleiste/Symbole uebernommen werden`r`nStart-Sleep -Seconds 5; Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue"
        }
        if (@($Ctx.DesktopIconLines).Count) {
            Add-HMLogonAction $Ctx ("# Desktop-Symbolpositionen setzen (wartet, bis der Desktop wieder da ist)`r`nStart-Sleep -Seconds 4; if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }`r`n" + (Get-HMDesktopIconsCode 'Load' '' '' $Ctx.DesktopIconLines))
        }
        # Besitzer der wiederhergestellten Profil-Ordner = Zielbenutzer (auch nach Abbruch fuer das bereits Kopierte)
        try { Repair-HMRestoredOwner $Ctx $Job $tenv } catch { Write-HMLog $Job "Besitzer/Rechte: $($_.Exception.Message)" 'Warning' }
        if (-not (Test-HMCancel $Job)) {
            if ($Ctx.HiveReady) { Register-HMLogonTask $Ctx $Job }
            Write-HMLog $Job 'Nacharbeiten' 'Info'
            Invoke-HMPostRestore $Ctx $Job
        }
    } finally {
        try { Dismount-HMHive $Ctx $Job } catch { }
        if ($shareRoot) { Disconnect-HMShare $shareRoot }
    }
    $dur = Format-HMDuration ((Get-Date) - $start)
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
    if ($Ctx.BrowserCase) { $facts['Browser: erkannter Fall'] = $Ctx.BrowserCase }
    # Liste der am Ziel fehlenden Dateien (Kontrolle nach dem Restore)
    $missList = ''
    if ($Ctx.MissingAfter -and $Ctx.MissingAfter.Count) {
        $missList = Join-Path $Ctx.Backup.Path ("Restore_{0}_{1}_Fehlende.txt" -f (ConvertTo-HMSafeName $Ctx.Computer), $start.ToString('yyyyMMdd_HHmm'))
        try {
            $hdr = @("Kontrolle nach dem Restore $($start.ToString('yyyy-MM-dd HH:mm')) - $($Ctx.Backup.Name) -> $($Ctx.Computer)", 'Diese Dateien liegen im Backup, fehlen aber am Ziel (z.B. Datei war geoeffnet, Zugriff verweigert, Pfad zu lang). Restore wiederholen oder von Hand kopieren.', '')
            [System.IO.File]::WriteAllLines($missList, [string[]](@($hdr) + @($Ctx.MissingAfter)), (New-Object System.Text.UTF8Encoding($true)))
        } catch { $missList = '' }
        Write-HMLog $Job ("KONTROLLE: {0} Datei(en) aus dem Backup fehlen am Ziel{1}" -f $Ctx.MissingAfter.Count, $(if ($missList) { " - Liste: $missList" } else { '' })) 'Warning'
    } elseif ($Ctx.Options.VerifyAfter -and -not (Test-HMCancel $Job)) { Write-HMLog $Job 'Kontrolle: alle Dateien aus dem Backup liegen am Ziel' 'Success' }
    $notes = @('Benutzer ab- und wieder anmelden bzw. Neustart, damit alle Einstellungen wirken.')
    if ($Ctx.MissingAfter -and $Ctx.MissingAfter.Count) { $notes += "Kontrolle: $($Ctx.MissingAfter.Count) Datei(en) aus dem Backup fehlen am Ziel$(if ($missList) { " - Liste: $(Split-Path $missList -Leaf) im Backup-Ordner" })." }
    if ($skipApps.Count) { $notes += "Programm-Einstellungen ausgelassen (Programm fehlt am Ziel): $($skipApps -join ', ') - Programm installieren, dann Restore nur mit diesen Programm-Modulen wiederholen." }
    if (@($Ctx.LogonActions).Count) { $notes += 'Einige Einstellungen werden bei der naechsten Anmeldung des Benutzers automatisch uebernommen (einmalige Aufgabe).' }
    $rep = New-HMReport -Ctx $Ctx -Kind Restore -OutFile (Join-Path $Ctx.Backup.Path ("Bericht_Restore_{0}_{1}.html" -f (ConvertTo-HMSafeName $Ctx.Computer), $start.ToString('yyyyMMdd_HHmm'))) -Modules $results -Facts $facts -Notes $notes -Status $st
    $Job.Result = [pscustomobject]@{ Status = $st; Duration = $dur; Modules = $results; Report = $rep; MissingFiles = $(if ($Ctx.MissingAfter) { $Ctx.MissingAfter.Count } else { 0 }); MissingList = $missList }
}

# ============================================================================
# USB-Laufwerk nach dem geplanten Backup auswerfen (Schutz vor Verschluesselungstrojanern)
# Laeuft auch ohne Administratorrechte: Datentraeger ueber WMI, Auswerfen ueber CM_Request_Device_Eject
# ============================================================================
function Get-HMDriveDisk([string]$Letter) {
    $L = ("$Letter".TrimEnd(':', '\') + ':').ToUpper()
    $ld = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$L'" -ErrorAction Stop)[0]
    if (-not $ld) { throw "Laufwerk $L nicht gefunden" }
    $part = @(Get-CimAssociatedInstance -InputObject $ld -ResultClassName Win32_DiskPartition -ErrorAction Stop)[0]
    if (-not $part) { throw "Partition von $L nicht gefunden" }
    $dd = @(Get-CimAssociatedInstance -InputObject $part -ResultClassName Win32_DiskDrive -ErrorAction Stop)[0]
    if (-not $dd) { throw "Datentraeger von $L nicht gefunden" }
    $letters = @(foreach ($p in @(Get-CimAssociatedInstance -InputObject $dd -ResultClassName Win32_DiskPartition -ErrorAction SilentlyContinue)) {
            foreach ($l in @(Get-CimAssociatedInstance -InputObject $p -ResultClassName Win32_LogicalDisk -ErrorAction SilentlyContinue)) { "$($l.DeviceID)".ToUpper() } })
    $ext = ("$($dd.InterfaceType)" -eq 'USB') -or ("$($dd.MediaType)" -match 'External|Removable|Extern|Wechsel') -or ("$($dd.PNPDeviceID)" -like 'USBSTOR\*') -or ([int]$ld.DriveType -eq 2)
    return [pscustomobject]@{
        Letter = $L; Index = $dd.Index; Model = "$($dd.Model)"; PnpId = "$($dd.PNPDeviceID)"; Interface = "$($dd.InterfaceType)"; MediaType = "$($dd.MediaType)"
        External = [bool]$ext; System = ($letters -contains "$env:SystemDrive".ToUpper()); Letters = $letters
    }
}
# Veto-Grund von CM_Request_Device_Eject lesbar machen (PNP_VETO_TYPE)
function Format-HMEjectVeto([string]$Result) {
    if ($Result -notmatch 'Veto (\d+)') { return $Result }
    $t = switch ([int]$Matches[1]) {
        1 { 'Legacy-Geraet' } 2 { 'wird gerade geschlossen' } 3 { 'ein Programm verwendet das Laufwerk' } 4 { 'ein Dienst verwendet das Laufwerk' }
        5 { 'Dateien auf dem Laufwerk sind noch geoeffnet' } 6 { 'ein anderes Geraet verhindert es' } 7 { 'Treiber verhindert es' }
        9 { 'zu wenig Strom' } 10 { 'Geraet nicht abschaltbar' } 12 { 'fehlende Rechte' } 13 { 'bereits entfernt' } default { 'Grund unbekannt' }
    }
    return "$t ($Result)"
}
# Rueckgabe: '' = ausgeworfen, sonst Grund
function Invoke-HMDriveEject([string]$Letter, [int]$Tries = 3, [int]$WaitSec = 5) {
    $d = Get-HMDriveDisk $Letter
    if ($d.System) { return "$($d.Letter) liegt auf der Systemplatte - wird nicht ausgeworfen" }
    if (-not $d.External) { return "$($d.Letter) ist kein USB-/Wechsellaufwerk ($($d.Interface), $($d.MediaType)) - wird nicht ausgeworfen" }
    if (-not ('HMDriveEject' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class HMDriveEject {
    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)] static extern int CM_Locate_DevNodeW(out uint pdnDevInst, string pDeviceID, int ulFlags);
    [DllImport("cfgmgr32.dll")] static extern int CM_Get_Parent(out uint pdnDevInst, uint dnDevInst, int ulFlags);
    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)] static extern int CM_Request_Device_EjectW(uint dnDevInst, out int pVetoType, StringBuilder pszVetoName, int ulNameLength, int ulFlags);
    static string Request(uint inst) {
        StringBuilder sb = new StringBuilder(260);
        int veto;
        int cr = CM_Request_Device_EjectW(inst, out veto, sb, sb.Capacity, 0);
        if (cr == 0 && veto == 0) return "";
        return "CR " + cr + ", Veto " + veto + (sb.Length > 0 ? " " + sb.ToString() : "");
    }
    public static string Eject(string deviceId) {
        uint inst;
        int cr = CM_Locate_DevNodeW(out inst, deviceId, 0);
        if (cr != 0) return "Geraet nicht gefunden (CR " + cr + ")";
        string r1 = "kein uebergeordnetes Geraet";
        uint parent;
        if (CM_Get_Parent(out parent, inst, 0) == 0) { r1 = Request(parent); if (r1 == "") return ""; }
        string r2 = Request(inst);
        if (r2 == "") return "";
        return r1 + " / " + r2;
    }
}
'@
    }
    $r = ''
    for ($i = 1; $i -le $Tries; $i++) {
        $r = [HMDriveEject]::Eject($d.PnpId)
        if (-not $r) { return '' }
        if ($i -lt $Tries) { Start-Sleep -Seconds $WaitSec }
    }
    return (Format-HMEjectVeto $r)
}

