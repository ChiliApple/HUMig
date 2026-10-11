#Requires -Version 5.1
<#
.SYNOPSIS
    Live-Anzeige waehrend Backup/Restore/Server-Backup: Lesen/Schreiben des Kopiervorgangs (MB/s), CPU- und RAM-Auslastung,
    jeweils mit Verlauf der letzten 60 Sekunden. Steht in den Reitern Backup und Restore unter den Modulen, im Reiter
    Server-Backup unter den VMs.
.DESCRIPTION
    Durchsatz = E/A-Zaehler der Kopierprozesse (Robocopy, USMT ScanState/LoadState, Windows Server-Sicherung wbengine) ueber GetProcessIoCounters -
    stimmt damit auch bei Netzwerkzielen (Freigabe), wo ein Laufwerkszaehler nichts zeigen wuerde.
    CPU ueber GetSystemTimes, RAM ueber GlobalMemoryStatusEx - sprachunabhaengig, keine Leistungsindikatoren noetig.
.NOTES
    Dot-Source aus HUMig.ps1. Zielmaschine: der PC, auf dem HUMig laeuft (CPU/RAM sind die Werte DIESES PCs, auch wenn
    ein anderer PC ueber das Netzwerk gesichert wird).
#>

$script:MonCs = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
public static class HMMon {
    [StructLayout(LayoutKind.Sequential)] struct FILETIME { public uint Low; public uint High; }
    [StructLayout(LayoutKind.Sequential)] struct IO_COUNTERS { public ulong ReadOps, WriteOps, OtherOps, ReadBytes, WriteBytes, OtherBytes; }
    [StructLayout(LayoutKind.Sequential)] class MEMORYSTATUSEX {
        public uint dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX)); public uint dwMemoryLoad; public ulong ullTotalPhys; public ulong ullAvailPhys;
        public ulong ullTotalPageFile; public ulong ullAvailPageFile; public ulong ullTotalVirtual; public ulong ullAvailVirtual; public ulong ullAvailExtendedVirtual; }
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetSystemTimes(out FILETIME idle, out FILETIME kernel, out FILETIME user);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GlobalMemoryStatusEx([In, Out] MEMORYSTATUSEX m);
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetProcessIoCounters(IntPtr h, out IO_COUNTERS c);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CloseHandle(IntPtr h);
    static ulong U(FILETIME f) { return ((ulong)f.High << 32) | f.Low; }
    static ulong lIdle, lKernel, lUser; static bool haveCpu;
    static Dictionary<int, ulong[]> last = new Dictionary<int, ulong[]>();
    // CPU-Auslastung in Prozent seit dem letzten Aufruf (-1 beim ersten Aufruf)
    public static double Cpu() {
        FILETIME i, k, u;
        if (!GetSystemTimes(out i, out k, out u)) return -1;
        ulong idle = U(i), kern = U(k), user = U(u);
        double r = -1;
        if (haveCpu) {
            ulong di = idle - lIdle, dk = kern - lKernel, du = user - lUser, tot = dk + du;   // Kernel-Zeit enthaelt Leerlauf
            if (tot > 0) r = Math.Max(0, Math.Min(100, (double)(tot - di) * 100.0 / tot));
        }
        lIdle = idle; lKernel = kern; lUser = user; haveCpu = true;
        return r;
    }
    // { gesamt, frei } in Bytes
    public static ulong[] Mem() {
        MEMORYSTATUSEX m = new MEMORYSTATUSEX();
        if (!GlobalMemoryStatusEx(m)) return new ulong[] { 0, 0 };
        return new ulong[] { m.ullTotalPhys, m.ullAvailPhys };
    }
    // { gelesen, geschrieben, Prozesse } in Bytes seit dem letzten Aufruf - Summe ueber alle Prozesse mit diesen Namen.
    // Neue Prozesse zaehlen ab dem ersten Messpunkt (kein Sprung durch bereits Kopiertes).
    public static ulong[] Io(string[] names) {
        ulong rd = 0, wr = 0, n = 0;
        Dictionary<int, ulong[]> now = new Dictionary<int, ulong[]>();
        foreach (string name in names) {
            Process[] ps;
            try { ps = Process.GetProcessesByName(name); } catch { continue; }
            foreach (Process p in ps) {
                try {
                    IntPtr h = OpenProcess(0x1000, false, p.Id);   // PROCESS_QUERY_LIMITED_INFORMATION
                    if (h == IntPtr.Zero) continue;
                    IO_COUNTERS c;
                    bool ok = GetProcessIoCounters(h, out c);
                    CloseHandle(h);
                    if (!ok) continue;
                    n++;
                    now[p.Id] = new ulong[] { c.ReadBytes, c.WriteBytes };
                    ulong[] prev;
                    if (last.TryGetValue(p.Id, out prev)) {
                        if (c.ReadBytes >= prev[0]) rd += c.ReadBytes - prev[0];
                        if (c.WriteBytes >= prev[1]) wr += c.WriteBytes - prev[1];
                    }
                } catch { } finally { p.Dispose(); }
            }
        }
        last = now;
        return new ulong[] { rd, wr, n };
    }
}
'@

$script:MonViews = @()
$script:MonTimer = $null
$script:MonHist = $null
# wbengine = Dienst der Windows Server-Sicherung (liest/schreibt bei wbadmin die Daten), nur als Administrator messbar
$script:MonProcNames = [string[]]@('robocopy', 'scanstate', 'loadstate', 'wbengine')

function Initialize-HMMonitor {
    try { if (-not ('HMMon' -as [type])) { Add-Type -TypeDefinition $script:MonCs -ErrorAction Stop } } catch { Write-Host "[MONITOR] $($_.Exception.Message)" -ForegroundColor Yellow; return }
    $script:MonViews = @()
    foreach ($host0 in @($ui.brdMonBackup, $ui.brdMonRestore, $ui.brdMonServer)) {
        if (-not $host0) { continue }
        $g = New-Object System.Windows.Controls.Grid
        foreach ($i in 1..3) { $cd = New-Object System.Windows.Controls.ColumnDefinition; $cd.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star); $g.ColumnDefinitions.Add($cd) }
        $v = @{ Host = $host0 }
        $defs = @(
            @{ Key = 'Io'; Title = 'KOPIEREN (Lesen / Schreiben)'; Color = '#FF89B4FA'; Tip = 'Durchsatz des Kopiervorgangs (Robocopy, USMT bzw. Windows Server-Sicherung) - gilt auch fuer Netzwerkziele. Linie blau = Schreiben, grau = Lesen.' }
            @{ Key = 'Cpu'; Title = 'CPU'; Color = '#FFA6E3A1'; Tip = 'Prozessor-Auslastung dieses PCs (auf dem HUMig laeuft)' }
            @{ Key = 'Ram'; Title = 'ARBEITSSPEICHER'; Color = '#FFCBA6F7'; Tip = 'Belegter Arbeitsspeicher dieses PCs (auf dem HUMig laeuft)' }
        )
        for ($c = 0; $c -lt 3; $c++) {
            $d = $defs[$c]
            $sp = New-Object System.Windows.Controls.StackPanel
            $sp.Margin = [System.Windows.Thickness]::new($(if ($c) { 12 } else { 0 }), 0, 0, 0)
            $sp.ToolTip = $d.Tip
            $t = New-Object System.Windows.Controls.TextBlock; $t.Text = $d.Title; $t.FontSize = 10.5; $t.FontWeight = [System.Windows.FontWeights]::SemiBold; $t.Foreground = New-Brush '#FFA6ADC8'
            $val = New-Object System.Windows.Controls.TextBlock; $val.Text = '-'; $val.FontSize = 15; $val.FontWeight = [System.Windows.FontWeights]::SemiBold; $val.Foreground = New-Brush '#FFCDD6F4'
            $sub = New-Object System.Windows.Controls.TextBlock; $sub.Text = ''; $sub.FontSize = 10.5; $sub.Foreground = New-Brush '#FF6C7086'
            $cv = New-Object System.Windows.Controls.Canvas; $cv.Height = 30; $cv.Margin = [System.Windows.Thickness]::new(0, 3, 0, 0); $cv.Background = New-Brush '#FF181825'; $cv.ClipToBounds = $true
            $pl = New-Object System.Windows.Shapes.Polyline; $pl.Stroke = New-Brush $d.Color; $pl.StrokeThickness = 1.5
            [void]$cv.Children.Add($pl)
            $pl2 = $null
            if ($d.Key -eq 'Io') { $pl2 = New-Object System.Windows.Shapes.Polyline; $pl2.Stroke = New-Brush '#FF6C7086'; $pl2.StrokeThickness = 1; [void]$cv.Children.Insert(0, $pl2) }
            foreach ($e in @($t, $val, $sub, $cv)) { [void]$sp.Children.Add($e) }
            [System.Windows.Controls.Grid]::SetColumn($sp, $c)
            [void]$g.Children.Add($sp)
            $v[$d.Key] = @{ Val = $val; Sub = $sub; Canvas = $cv; Line = $pl; Line2 = $pl2 }
        }
        $host0.Child = $g
        $script:MonViews += $v
    }
}

function Format-HMRate([double]$Bps) {
    if ($Bps -ge 1GB) { return ('{0:N2} GB/s' -f ($Bps / 1GB)) }
    return ('{0:N1} MB/s' -f ($Bps / 1MB))
}
# Verlauf als Linie zeichnen (Werte 0..Max auf Hoehe des Canvas)
function Set-HMMonLine($Line, [double[]]$Values, [double]$Max, [double]$W, [double]$H) {
    $pc = New-Object System.Windows.Media.PointCollection
    if ($Max -le 0) { $Max = 1 }
    $n = $Values.Count
    for ($i = 0; $i -lt $n; $i++) {
        $x = if ($n -gt 1) { $W * $i / 59 } else { 0 }
        $y = $H - 1 - [Math]::Min(1.0, $Values[$i] / $Max) * ($H - 2)
        $pc.Add([System.Windows.Point]::new($x, $y))
    }
    $Line.Points = $pc
}

function Start-HMMonitor {
    if (-not $script:MonViews.Count) { return }
    $script:MonHist = @{ Rd = New-Object System.Collections.Generic.List[double]; Wr = New-Object System.Collections.Generic.List[double]; Cpu = New-Object System.Collections.Generic.List[double]; Ram = New-Object System.Collections.Generic.List[double]
        Last = [datetime]::Now; Start = [datetime]::Now; SumWr = [double]0; SumRd = [double]0; PeakWr = [double]0 }
    try { [void][HMMon]::Cpu(); [void][HMMon]::Io($script:MonProcNames) } catch { }
    foreach ($v in $script:MonViews) { $v.Host.Visibility = 'Visible' }
    if (-not $script:MonTimer) {
        $script:MonTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:MonTimer.Interval = [TimeSpan]::FromSeconds(1)
        $script:MonTimer.Add_Tick({ Update-HMMonitor })
    }
    $script:MonTimer.Start()
}
function Update-HMMonitor {
    $h = $script:MonHist
    if (-not $h) { return }
    try {
        $now = [datetime]::Now
        $sec = [Math]::Max(0.2, ($now - $h.Last).TotalSeconds); $h.Last = $now
        $io = [HMMon]::Io($script:MonProcNames)
        $rd = [double]$io[0] / $sec; $wr = [double]$io[1] / $sec; $np = [int]$io[2]
        $cpu = [HMMon]::Cpu()
        $mem = [HMMon]::Mem()
        $tot = [double]$mem[0]; $used = $tot - [double]$mem[1]
        $h.SumWr += [double]$io[1]; $h.SumRd += [double]$io[0]; if ($wr -gt $h.PeakWr) { $h.PeakWr = $wr }
        foreach ($p in @(@($h.Rd, $rd), @($h.Wr, $wr), @($h.Cpu, [Math]::Max(0, $cpu)), @($h.Ram, $(if ($tot) { 100 * $used / $tot } else { 0 })))) { $p[0].Add($p[1]); if ($p[0].Count -gt 60) { $p[0].RemoveAt(0) } }
        $maxIo = [Math]::Max(1MB, [Math]::Max(($h.Wr | Measure-Object -Maximum).Maximum, ($h.Rd | Measure-Object -Maximum).Maximum))
        $run = ($now - $h.Start).TotalSeconds
        foreach ($v in $script:MonViews) {
            $w = [Math]::Max(60, $v.Io.Canvas.ActualWidth); $ht = 30
            $v.Io.Val.Text = "$(Format-HMRate $rd)  /  $(Format-HMRate $wr)"
            $v.Io.Sub.Text = if ($np) { "Durchschnitt Schreiben $(Format-HMRate ($h.SumWr / [Math]::Max(1, $run)))  |  Spitze $(Format-HMRate $h.PeakWr)" } else { 'gerade kein Kopiervorgang (Pruefen, Registry, Einstellungen ...)' }
            Set-HMMonLine $v.Io.Line ([double[]]$h.Wr.ToArray()) $maxIo $w $ht
            Set-HMMonLine $v.Io.Line2 ([double[]]$h.Rd.ToArray()) $maxIo $w $ht
            $v.Cpu.Val.Text = if ($cpu -ge 0) { '{0:N0} %' -f $cpu } else { '-' }
            $v.Cpu.Sub.Text = "$([Environment]::ProcessorCount) logische Prozessoren"
            Set-HMMonLine $v.Cpu.Line ([double[]]$h.Cpu.ToArray()) 100 ([Math]::Max(60, $v.Cpu.Canvas.ActualWidth)) $ht
            $v.Ram.Val.Text = if ($tot) { '{0:N0} %' -f (100 * $used / $tot) } else { '-' }
            $v.Ram.Sub.Text = if ($tot) { '{0:N1} von {1:N1} GB belegt' -f ($used / 1GB), ($tot / 1GB) } else { '' }
            Set-HMMonLine $v.Ram.Line ([double[]]$h.Ram.ToArray()) 100 ([Math]::Max(60, $v.Ram.Canvas.ActualWidth)) $ht
        }
    } catch { }
}
# Ende: Timer aus, Anzeige bleibt mit Durchschnitt stehen
function Stop-HMMonitor {
    if ($script:MonTimer) { $script:MonTimer.Stop() }
    $h = $script:MonHist
    if (-not $h) { return }
    $run = [Math]::Max(1, ([datetime]::Now - $h.Start).TotalSeconds)
    foreach ($v in $script:MonViews) {
        $v.Io.Val.Text = "fertig - Durchschnitt $(Format-HMRate ($h.SumWr / $run)) Schreiben"
        $v.Io.Sub.Text = "gelesen $(Format-HMSize ([long]$h.SumRd)), geschrieben $(Format-HMSize ([long]$h.SumWr)) in $(Format-HMDuration ([datetime]::Now - $h.Start))  |  Spitze $(Format-HMRate $h.PeakWr)"
    }
    $script:MonHist = $null
}
