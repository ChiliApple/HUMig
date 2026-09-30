#Requires -Version 5.1
<#
.SYNOPSIS
    Windows-Integration: Starter HUMig.exe (mit Logo, ohne Konsolenfenster), Desktop-Verknuepfung,
    Fenstergroesse/-position merken.
.NOTES
    Wird im UI-Thread geladen (dot-source aus HUMig.ps1). Zielmaschine: der PC, auf dem HUMig laeuft.
#>

# ----------------------------------------------------------------------------
# Starter HUMig.exe: wird lokal aus C#-Quelltext erzeugt (nicht im Repo, kein fremdes Programm).
# Startet powershell.exe unsichtbar (SW_HIDE) mit Administratorrechten -> kein aufblitzendes Konsolenfenster.
# Heisst die Datei *-Benutzer.exe (HUMig-Benutzer.exe): ohne Administratorrechte im Benutzer-Modus.
# ----------------------------------------------------------------------------
$script:LauncherSource = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

public static class HUMigLauncher
{
    [STAThread]
    public static int Main(string[] args)
    {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string ps1 = Path.Combine(dir, "HUMig.ps1");
        if (!File.Exists(ps1))
        {
            MessageBox.Show("HUMig.ps1 nicht gefunden in:\n" + dir + "\n\nPull.ps1 ausfuehren, um die Dateien zu laden.", "HUMig", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
        bool user = Path.GetFileNameWithoutExtension(Application.ExecutablePath).EndsWith("-Benutzer", StringComparison.OrdinalIgnoreCase);
        string ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
        ProcessStartInfo psi = new ProcessStartInfo(ps, "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + ps1 + "\" -HideConsole" + (user ? " -UserMode" : ""));
        psi.UseShellExecute = true;
        if (!user) psi.Verb = "runas";
        psi.WindowStyle = ProcessWindowStyle.Hidden;
        psi.WorkingDirectory = dir;
        try { Process.Start(psi); }
        catch (System.ComponentModel.Win32Exception) { return 2; }
        return 0;
    }
}
'@

function New-HMLauncher {
    param([switch]$Force, [string]$Name = 'HUMig.exe')
    $exe = Join-Path $script:AppRoot $Name
    $ico = Join-Path $script:AppRoot 'Assets\icon.ico'
    if ((Test-Path -LiteralPath $exe) -and -not $Force) { return $true }
    try {
        if (Test-Path -LiteralPath $exe) { Remove-Item -LiteralPath $exe -Force -ErrorAction Stop }
        $cp = New-Object System.CodeDom.Compiler.CompilerParameters
        $cp.GenerateExecutable = $true
        $cp.GenerateInMemory = $false
        $cp.OutputAssembly = $exe
        $cp.CompilerOptions = '/target:winexe /optimize+' + $(if (Test-Path -LiteralPath $ico) { " /win32icon:`"$ico`"" } else { '' })
        [void]$cp.ReferencedAssemblies.Add('System.dll')
        [void]$cp.ReferencedAssemblies.Add('System.Windows.Forms.dll')
        # eindeutiger Typname: mehrere Starter in einer Sitzung erzeugen (HUMig.exe + HUMig-Benutzer.exe)
        $src = $script:LauncherSource -replace 'HUMigLauncher', ('HUMigLauncher' + [guid]::NewGuid().ToString('N'))
        Add-Type -TypeDefinition $src -Language CSharp -CompilerParameters $cp -ErrorAction Stop
        return (Test-Path -LiteralPath $exe)
    } catch {
        Write-Host "[WARN] Starter HUMig.exe nicht erstellt: $($_.Exception.Message)" -ForegroundColor Yellow
        return $false
    }
}

function New-HMDesktopShortcut {
    $exe = Join-Path $script:AppRoot 'HUMig.exe'
    if (-not (Test-Path -LiteralPath $exe)) { [void](New-HMLauncher) }
    $target = if (Test-Path -LiteralPath $exe) { $exe } else { Join-Path $script:AppRoot 'Start.cmd' }
    $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'HUMig.lnk'
    $sh = New-Object -ComObject WScript.Shell
    $s = $sh.CreateShortcut($lnk)
    $s.TargetPath = $target
    $s.WorkingDirectory = $script:AppRoot
    $s.IconLocation = "$(Join-Path $script:AppRoot 'Assets\icon.ico'),0"
    $s.Description = 'HUMig v2 - Benutzerprofil-Migration'
    $s.Save()
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($sh)
    return $lnk
}

# ----------------------------------------------------------------------------
# Fenstergroesse / -position (Config\WindowState.json, lokal)
# ----------------------------------------------------------------------------
# Pulsierender Punkt: Hintergrund-Aufgaben laufen (Statusleiste = alle, Server-Backup-Reiter = Kennung 'Sb')
$script:HMPulse = $null
function Set-HMBusyDot($Dot, [bool]$On) {
    if (-not $Dot) { return }
    if ($On) {
        if ("$($Dot.Visibility)" -ne 'Visible') {
            $Dot.Visibility = 'Visible'
            if (-not $script:HMPulse) {
                $a = New-Object System.Windows.Media.Animation.DoubleAnimation
                $a.From = 1.0; $a.To = 0.15; $a.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(650))
                $a.AutoReverse = $true; $a.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
                $script:HMPulse = $a
            }
            $Dot.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $script:HMPulse)
        }
    } elseif ("$($Dot.Visibility)" -eq 'Visible') {
        $Dot.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
        $Dot.Visibility = 'Collapsed'
    }
}
function Update-HMBusyUi {
    if (-not $ui) { return }
    $all = [int]$script:AsyncBusy['*']; $sb = [int]$script:AsyncBusy['Sb']
    if ($ui.dotBusy) { Set-HMBusyDot $ui.dotBusy ($all -gt 0); $ui.dotBusy.ToolTip = "Im Hintergrund laufen $all Aufgabe(n)" }
    if ($ui.dotSbBusy) { Set-HMBusyDot $ui.dotSbBusy ($sb -gt 0) }
    if ($ui.lblSbBusy) {
        $ui.lblSbBusy.Text = $(if ($sb -gt 0) { $t = "$($script:AsyncBusyText['Sb'])"; if ($t) { $t } else { 'wird geladen ...' } } else { '' })
        $ui.lblSbBusy.Visibility = $(if ($sb -gt 0) { 'Visible' } else { 'Collapsed' })
    }
}

function Save-HMWindowState {
    try {
        $w = $script:Window
        $isMax = ($w.WindowState -eq [System.Windows.WindowState]::Maximized)
        $rb = if ($isMax) { $w.RestoreBounds } else { New-Object System.Windows.Rect $w.Left, $w.Top, $w.Width, $w.Height }
        $o = [ordered]@{ Left = $rb.Left; Top = $rb.Top; Width = $rb.Width; Height = $rb.Height; Maximized = $isMax; ConsoleHeight = $null }
        if ($script:RowConsole) { $o.ConsoleHeight = $script:RowConsole.ActualHeight }
        Write-JsonFile (Join-Path $script:ConfigDir 'WindowState.json') ([pscustomobject]$o)
    } catch { }
}
function Restore-HMWindowState {
    $w = $script:Window
    $wa = [System.Windows.SystemParameters]::WorkArea
    $s = Read-JsonFile (Join-Path $script:ConfigDir 'WindowState.json')
    $ok = $false
    if ($s) {
        $vl = [System.Windows.SystemParameters]::VirtualScreenLeft; $vt = [System.Windows.SystemParameters]::VirtualScreenTop
        $vw = [System.Windows.SystemParameters]::VirtualScreenWidth; $vh = [System.Windows.SystemParameters]::VirtualScreenHeight
        $ok = ($s.Width -ge 700) -and ($s.Height -ge 450) -and ($s.Left -ge $vl - 50) -and ($s.Left -lt $vl + $vw - 100) -and ($s.Top -ge $vt - 50) -and ($s.Top -lt $vt + $vh - 100)
        if ($ok) {
            $w.WindowStartupLocation = [System.Windows.WindowStartupLocation]::Manual
            $w.Left = [double]$s.Left; $w.Top = [double]$s.Top; $w.Width = [double]$s.Width; $w.Height = [Math]::Min([double]$s.Height, [double]$vh)
            if ($s.Maximized) { $w.WindowState = [System.Windows.WindowState]::Maximized }
            if ($s.ConsoleHeight -and $script:RowConsole -and [double]$s.ConsoleHeight -ge 90) { $script:RowConsole.Height = New-Object System.Windows.GridLength ([double]$s.ConsoleHeight) }
        }
    }
    if (-not $ok) {
        # Erststart: gross (ca. 90 % des Arbeitsbereichs), zentriert
        $w.WindowStartupLocation = [System.Windows.WindowStartupLocation]::Manual
        $w.Width = [Math]::Max([Math]::Min(1500, $wa.Width * 0.9), [Math]::Min($w.MinWidth, $wa.Width))
        $w.Height = [Math]::Max([Math]::Min(1000, $wa.Height * 0.92), [Math]::Min($w.MinHeight, $wa.Height))
        $w.Left = $wa.Left + ($wa.Width - $w.Width) / 2
        $w.Top = $wa.Top + ($wa.Height - $w.Height) / 2
    }
}

# ----------------------------------------------------------------------------
# Anzeige-Groesse (Text + Oberflaeche skalieren, fuer kleine Bildschirme / bessere Lesbarkeit)
# Einstellung UiScale: 0 = automatisch (passt sich an kleine Bildschirme an), sonst 0.7 - 1.6
# Strg + Mausrad, Strg + Plus/Minus, Strg + 0 = automatisch
# ----------------------------------------------------------------------------
$script:UiScale = 1.0
function Get-HMAutoScale {
    $wa = [System.Windows.SystemParameters]::WorkArea
    $f = [Math]::Min($wa.Width / 1280.0, $wa.Height / 860.0)
    return [Math]::Round([Math]::Max(0.7, [Math]::Min(1.0, $f)), 2)
}
function Set-HMWindowScale($W) {
    try {
        $s = [double]$script:UiScale
        if (-not $W -or -not $W.Content -or [Math]::Abs($s - 1.0) -lt 0.01) { return }
        $W.Content.LayoutTransform = New-Object System.Windows.Media.ScaleTransform ($s, $s)
        $wa = [System.Windows.SystemParameters]::WorkArea
        if (-not [double]::IsNaN($W.Width) -and $W.Width -gt 0) { $W.Width = [Math]::Min($W.Width * $s, $wa.Width) }
        if ($W.SizeToContent -eq 'Manual' -and -not [double]::IsNaN($W.Height) -and $W.Height -gt 0) { $W.Height = [Math]::Min($W.Height * $s, $wa.Height) }
        if ($W.MinWidth -gt 0) { $W.MinWidth = [Math]::Min($W.MinWidth * $s, $wa.Width) }
        if ($W.MinHeight -gt 0) { $W.MinHeight = [Math]::Min($W.MinHeight * $s, $wa.Height) }
    } catch { }
}
function Set-HMUiScale([double]$Scale, [switch]$Quiet) {
    $s = [Math]::Round([Math]::Max(0.7, [Math]::Min(1.6, $Scale)), 2)
    $script:UiScale = $s
    $w = $script:Window
    if (-not $w -or -not $w.Content) { return }
    $w.Content.LayoutTransform = $(if ([Math]::Abs($s - 1.0) -lt 0.01) { $null } else { New-Object System.Windows.Media.ScaleTransform ($s, $s) })
    $wa = [System.Windows.SystemParameters]::WorkArea
    $w.MinWidth = [Math]::Min(900 * $s, $wa.Width); $w.MinHeight = [Math]::Min(600 * $s, $wa.Height)
    if (-not $Quiet) { Set-Status ("Anzeige {0:N0} %  (Strg + Mausrad / Strg + Plus/Minus, Strg + 0 = automatisch)" -f ($s * 100)) '#FF89B4FA' }
}
function Initialize-HMUiScale {
    $v = 0.0
    try { $v = [double]$script:Settings.UiScale } catch { $v = 0.0 }
    $script:UiScaleAuto = ($v -le 0)
    Set-HMUiScale $(if ($v -le 0) { Get-HMAutoScale } else { $v }) -Quiet
    $script:Window.Add_PreviewMouseWheel({
        param($s, $e)
        if ([System.Windows.Input.Keyboard]::Modifiers -ne [System.Windows.Input.ModifierKeys]::Control) { return }
        $script:UiScaleAuto = $false
        Set-HMUiScale ($script:UiScale + $(if ($e.Delta -gt 0) { 0.05 } else { -0.05 }))
        $e.Handled = $true
    })
    $script:Window.Add_PreviewKeyDown({
        param($s, $e)
        if ([System.Windows.Input.Keyboard]::Modifiers -ne [System.Windows.Input.ModifierKeys]::Control) { return }
        switch ("$($e.Key)") {
            { $_ -in 'OemPlus', 'Add' } { $script:UiScaleAuto = $false; Set-HMUiScale ($script:UiScale + 0.05); $e.Handled = $true }
            { $_ -in 'OemMinus', 'Subtract' } { $script:UiScaleAuto = $false; Set-HMUiScale ($script:UiScale - 0.05); $e.Handled = $true }
            { $_ -in 'D0', 'NumPad0' } { $script:UiScaleAuto = $true; Set-HMUiScale (Get-HMAutoScale); $e.Handled = $true }
        }
    })
}
# beim Beenden merken (0 = automatisch)
function Get-HMUiScaleSetting { if ($script:UiScaleAuto) { return 0 } else { return [double]$script:UiScale } }

