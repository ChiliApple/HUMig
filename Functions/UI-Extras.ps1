#Requires -Version 5.1
<#
.SYNOPSIS
    Oberflaechen-Ergaenzungen: Benachrichtigung (Windows-Hinweis + Ton + Taskleiste), Fortschritt im Taskleisten-Symbol,
    Sicherheit des Backup-Laufwerks (USB/BitLocker To Go) inkl. Verschluesselungsdialog.
.NOTES
    Wird im UI-Thread geladen (dot-source aus HUMig.ps1). Zielmaschine: der PC, auf dem HUMig laeuft.
#>

# ----------------------------------------------------------------------------
# Taskleiste: Fortschritt im Symbol + Blinken
# ----------------------------------------------------------------------------
function Initialize-HMTaskbar {
    try {
        if (-not $script:Window.TaskbarItemInfo) { $script:Window.TaskbarItemInfo = New-Object System.Windows.Shell.TaskbarItemInfo }
        $script:Window.TaskbarItemInfo.Description = 'HUMig'
    } catch { }
    if (-not ('HMWin.Flash' -as [type])) {
        try {
            Add-Type -Namespace HMWin -Name Flash -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)]
public struct FLASHWINFO { public uint cbSize; public System.IntPtr hwnd; public uint dwFlags; public uint uCount; public uint dwTimeout; }
[DllImport("user32.dll")] public static extern bool FlashWindowEx(ref FLASHWINFO pwfi);
public static void Start(System.IntPtr h) {
    FLASHWINFO f = new FLASHWINFO(); f.cbSize = (uint)Marshal.SizeOf(typeof(FLASHWINFO)); f.hwnd = h;
    f.dwFlags = 3 | 12; f.uCount = 5; f.dwTimeout = 0; FlashWindowEx(ref f);
}
'@
        } catch { }
    }
}
function Set-HMTaskbarProgress([double]$Value, [string]$State = 'Normal') {
    try {
        $t = $script:Window.TaskbarItemInfo
        if (-not $t) { return }
        $t.ProgressState = [System.Windows.Shell.TaskbarItemProgressState]::$State
        if ($State -ne 'None') { $t.ProgressValue = [Math]::Max(0, [Math]::Min(1, $Value)) }
    } catch { }
}

# ----------------------------------------------------------------------------
# Benachrichtigung am Ende langer Vorgaenge
# ----------------------------------------------------------------------------
function Show-HMNotification {
    param([string]$Title, [string]$Text, [ValidateSet('Info', 'Warning', 'Error')][string]$Kind = 'Info')
    if ($script:Settings.Notify -eq $false) { return }
    try {
        switch ($Kind) { 'Error' { [System.Media.SystemSounds]::Hand.Play() } 'Warning' { [System.Media.SystemSounds]::Exclamation.Play() } default { [System.Media.SystemSounds]::Asterisk.Play() } }
    } catch { }
    try {
        if (-not $script:Window.IsActive) {
            $h = (New-Object System.Windows.Interop.WindowInteropHelper $script:Window).Handle
            if ('HMWin.Flash' -as [type]) { [HMWin.Flash]::Start($h) }
        }
    } catch { }
    try {
        if (-not $script:TrayIcon) {
            Add-Type -AssemblyName System.Drawing
            $script:TrayIcon = New-Object System.Windows.Forms.NotifyIcon
            $ico = Join-Path $script:AppRoot 'Assets\icon.ico'
            $script:TrayIcon.Icon = if (Test-Path -LiteralPath $ico) { New-Object System.Drawing.Icon $ico } else { [System.Drawing.SystemIcons]::Information }
            $script:TrayIcon.Text = 'HUMig'
            $script:TrayIcon.Add_BalloonTipClicked({ try { $script:Window.Activate() } catch { } })
            $script:TrayIcon.Add_MouseClick({ try { $script:Window.Activate() } catch { } })
        }
        $script:TrayIcon.Visible = $true
        $ti = switch ($Kind) { 'Error' { [System.Windows.Forms.ToolTipIcon]::Error } 'Warning' { [System.Windows.Forms.ToolTipIcon]::Warning } default { [System.Windows.Forms.ToolTipIcon]::Info } }
        $script:TrayIcon.ShowBalloonTip(10000, $Title, $(if ($Text) { $Text } else { ' ' }), $ti)
        # Symbol nach einer Minute wieder ausblenden
        if (-not $script:TrayTimer) {
            $script:TrayTimer = New-Object System.Windows.Threading.DispatcherTimer
            $script:TrayTimer.Interval = [TimeSpan]::FromSeconds(60)
            $script:TrayTimer.Add_Tick({ $script:TrayTimer.Stop(); if ($script:TrayIcon) { $script:TrayIcon.Visible = $false } })
        }
        $script:TrayTimer.Stop(); $script:TrayTimer.Start()
    } catch { }
}
function Remove-HMNotification {
    try { if ($script:TrayIcon) { $script:TrayIcon.Visible = $false; $script:TrayIcon.Dispose(); $script:TrayIcon = $null } } catch { }
}

# ----------------------------------------------------------------------------
# Backup-Laufwerk: extern (USB/SD)? BitLocker-Status?  (laeuft asynchron, braucht Administratorrechte)
# ----------------------------------------------------------------------------
$script:RS_DriveSecurity = {
    param($l)
    $o = [ordered]@{ Letter = $l; External = $false; Bus = ''; Protection = -1; Conversion = -1; Percent = $null; Error = '' }
    try { $di = New-Object System.IO.DriveInfo ($l); if ("$($di.DriveType)" -eq 'Removable') { $o.External = $true } } catch { }
    try {
        $disk = Get-Partition -DriveLetter $l -ErrorAction Stop | Get-Disk -ErrorAction Stop
        $o.Bus = "$($disk.BusType)"
        if ($o.Bus -in @('USB', 'SD', 'MMC', '7', '12', '13')) { $o.External = $true }
    } catch { }
    try {
        $v = Get-CimInstance -Namespace 'root/cimv2/Security/MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -Filter "DriveLetter='$($l):'" -ErrorAction Stop
        if ($v) {
            $ps = Invoke-CimMethod -InputObject $v -MethodName GetProtectionStatus -ErrorAction SilentlyContinue
            if ($ps) { $o.Protection = [int]$ps.ProtectionStatus }
            $cs = Invoke-CimMethod -InputObject $v -MethodName GetConversionStatus -ErrorAction SilentlyContinue
            if ($cs) { $o.Conversion = [int]$cs.ConversionStatus; $o.Percent = $cs.EncryptionPercentage }
        } else { $o.Protection = 0; $o.Conversion = 0 }
    } catch { $o.Error = $_.Exception.Message }
    [pscustomobject]$o
}

function Update-BackupDriveSecurity {
    $script:BackupDriveInfo = $null
    if ($ui.btnBitLocker) { $ui.btnBitLocker.Visibility = 'Collapsed' }
    $root = Get-BackupRoot
    if ($root -notmatch '^([A-Za-z]):') { return }
    $letter = $Matches[1].ToUpper()
    if ($letter -eq "$env:SystemDrive".Substring(0, 1).ToUpper()) { return }
    Invoke-AsyncCommand -ScriptBlock $script:RS_DriveSecurity -ArgumentList @($letter) -TimeoutSec 30 -State @{ Root = $root } -OnComplete {
        param($r, $st)
        if (-not $r -or "$r" -like 'FEHLER*' -or $st.Root -ne (Get-BackupRoot)) { return }
        $script:BackupDriveInfo = $r
        if (-not $r.External) { return }
        $txt = "$($ui.lblFree.Text)"
        if ($r.Conversion -eq 1 -or ($r.Protection -eq 1)) {
            $ui.lblFree.Text = "$txt  |  USB, BitLocker an"
        } elseif ($r.Conversion -eq 2) {
            $ui.lblFree.Text = "$txt  |  USB, BitLocker: wird verschluesselt ($([int]$r.Percent) %)"
        } elseif ($r.Protection -eq 0 -or $r.Conversion -eq 0) {
            $ui.lblFree.Text = "$txt  |  USB UNVERSCHLUESSELT"
            $ui.lblFree.Foreground = Get-ConsoleBrush '#FFF38BA8'
            $ui.lblFree.ToolTip = 'Auf dem Laufwerk liegen Benutzerdaten (Dokumente, Browser, WLAN-Profile). Empfehlung: mit BitLocker To Go verschluesseln.'
            if ($ui.btnBitLocker) { $ui.btnBitLocker.Visibility = 'Visible'; $ui.btnBitLocker.Tag = $r.Letter }
        } elseif ($r.Error) {
            $ui.lblFree.Text = "$txt  |  USB, BitLocker-Status unbekannt"
        }
    }
}

# Test fuer den Start eines Backups: unverschluesseltes USB-Ziel?
function Test-BackupDriveUnencrypted {
    $r = $script:BackupDriveInfo
    return [bool]($r -and $r.External -and $r.Protection -ne 1 -and $r.Conversion -in @(0) )
}

# ----------------------------------------------------------------------------
# BitLocker To Go: Kennwort-Dialog, Verschluesselung starten, Wiederherstellungsschluessel anzeigen/speichern
# ----------------------------------------------------------------------------
function Show-BitLockerDialog([string]$Letter) {
    if (-not $Letter) { return }
    $x = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="BitLocker To Go - Laufwerk $($Letter):" Width="520" SizeToContent="Height" ResizeMode="NoResize" WindowStartupLocation="CenterOwner" Background="#FF1E1E2E">
  <StackPanel Margin="16">
    <TextBlock Foreground="#FFCDD6F4" TextWrapping="Wrap" Margin="0,0,0,10">Das Laufwerk wird mit BitLocker To Go verschluesselt (im Hintergrund, es bleibt benutzbar). An jedem Windows-PC wird beim Anstecken das Kennwort abgefragt.</TextBlock>
    <TextBlock Foreground="#FFF9E2AF" TextWrapping="Wrap" Margin="0,0,0,10">Zusaetzlich wird ein Wiederherstellungsschluessel erzeugt - diesen sicher aufbewahren (nicht auf diesem Laufwerk!). Ohne Kennwort und Schluessel sind die Daten verloren.</TextBlock>
    <TextBlock Text="Kennwort (mind. 8 Zeichen):" Foreground="#FFA6ADC8" Margin="0,0,0,2"/>
    <PasswordBox x:Name="pw1" Background="#FF313244" Foreground="#FFCDD6F4" BorderBrush="#FF585B70" Padding="4,3" Margin="0,0,0,8"/>
    <TextBlock Text="Kennwort wiederholen:" Foreground="#FFA6ADC8" Margin="0,0,0,2"/>
    <PasswordBox x:Name="pw2" Background="#FF313244" Foreground="#FFCDD6F4" BorderBrush="#FF585B70" Padding="4,3" Margin="0,0,0,8"/>
    <TextBlock x:Name="err" Foreground="#FFF38BA8" TextWrapping="Wrap" Margin="0,0,0,8"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
      <Button x:Name="ok" Content="Verschluesseln" Width="130" Height="28" Background="#FFFAB387" Foreground="#FF1E1E2E" FontWeight="SemiBold" Margin="0,0,6,0" IsDefault="True"/>
      <Button x:Name="cancel" Content="Abbrechen" Width="100" Height="28" Background="#FF45475A" Foreground="#FFCDD6F4" IsCancel="True"/>
    </StackPanel>
  </StackPanel>
</Window>
"@
    $w = [System.Windows.Markup.XamlReader]::Parse($x)
    if ($script:AppIcon) { $w.Icon = $script:AppIcon }
    $w.Owner = $script:Window; Set-HMWindowScale $w
    $res = @{ Pw = $null }
    $p1 = $w.FindName('pw1'); $p2 = $w.FindName('pw2'); $er = $w.FindName('err')
    $w.FindName('ok').Add_Click({
        if ($p1.Password.Length -lt 8) { $er.Text = 'Mindestens 8 Zeichen.'; return }
        if ($p1.Password -cne $p2.Password) { $er.Text = 'Die Kennwoerter stimmen nicht ueberein.'; return }
        $res.Pw = $p1.SecurePassword
        $w.DialogResult = $true
    }.GetNewClosure())
    [void]$p1.Focus()
    if ($w.ShowDialog() -ne $true -or -not $res.Pw) { return }
    Out-Console "BitLocker To Go: Laufwerk $($Letter): wird verschluesselt ..." 'Info'
    Invoke-AsyncCommand -ScriptBlock {
        param($l, $sec)
        try {
            Import-Module BitLocker -ErrorAction Stop
            [void](Enable-BitLocker -MountPoint "$($l):" -PasswordProtector -Password $sec -UsedSpaceOnly -ErrorAction Stop)
            $v = Add-BitLockerKeyProtector -MountPoint "$($l):" -RecoveryPasswordProtector -ErrorAction Stop
            $k = @($v.KeyProtector | Where-Object { "$($_.KeyProtectorType)" -eq 'RecoveryPassword' }) | Select-Object -Last 1
            [pscustomobject]@{ Ok = $true; Id = "$($k.KeyProtectorId)"; Key = "$($k.RecoveryPassword)"; Msg = '' }
        } catch { [pscustomobject]@{ Ok = $false; Id = ''; Key = ''; Msg = $_.Exception.Message } }
    } -ArgumentList @($Letter, $res.Pw) -TimeoutSec 180 -State $Letter -OnComplete {
        param($r, $l)
        if (-not $r -or "$r" -like 'FEHLER*') { Out-Console "BitLocker: $r" 'Error'; return }
        if (-not $r.Ok) { Out-Console "BitLocker konnte nicht aktiviert werden: $($r.Msg)" 'Error'; return }
        Out-Console "BitLocker To Go aktiviert ($($l):) - Verschluesselung laeuft im Hintergrund." 'Success'
        Show-RecoveryKeyDialog $l $r.Id $r.Key
        Update-BackupRootInfo
    }
}

function Show-RecoveryKeyDialog([string]$Letter, [string]$Id, [string]$Key) {
    $x = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="BitLocker-Wiederherstellungsschluessel" Width="600" SizeToContent="Height" ResizeMode="NoResize" WindowStartupLocation="CenterOwner" Background="#FF1E1E2E">
  <StackPanel Margin="16">
    <TextBlock Foreground="#FFF9E2AF" TextWrapping="Wrap" Margin="0,0,0,10" FontWeight="SemiBold">Diesen Schluessel jetzt sicher aufbewahren (Passwort-Safe, Ausdruck, Netzlaufwerk) - NICHT auf dem verschluesselten Laufwerk.</TextBlock>
    <TextBlock x:Name="id" Foreground="#FFA6ADC8" Margin="0,0,0,4"/>
    <TextBox x:Name="key" IsReadOnly="True" FontFamily="Consolas" FontSize="15" Background="#FF313244" Foreground="#FFCDD6F4" BorderBrush="#FF585B70" Padding="6,4" Margin="0,0,0,12"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
      <Button x:Name="copy" Content="Kopieren" Width="100" Height="28" Background="#FF89B4FA" Foreground="#FF1E1E2E" FontWeight="SemiBold" Margin="0,0,6,0"/>
      <Button x:Name="save" Content="Als Datei speichern ..." Width="160" Height="28" Background="#FFA6E3A1" Foreground="#FF1E1E2E" FontWeight="SemiBold" Margin="0,0,6,0"/>
      <Button x:Name="close" Content="Schliessen" Width="100" Height="28" Background="#FF45475A" Foreground="#FFCDD6F4" IsCancel="True"/>
    </StackPanel>
  </StackPanel>
</Window>
"@
    $w = [System.Windows.Markup.XamlReader]::Parse($x)
    if ($script:AppIcon) { $w.Icon = $script:AppIcon }
    $w.Owner = $script:Window; Set-HMWindowScale $w
    $w.FindName('id').Text = "Laufwerk $($Letter):   Schluessel-ID: $Id"
    $w.FindName('key').Text = $Key
    $txt = "BitLocker-Wiederherstellungsschluessel`r`nLaufwerk: $($Letter):`r`nSchluessel-ID: $Id`r`nWiederherstellungsschluessel: $Key`r`nErstellt: $((Get-Date).ToString('dd.MM.yyyy HH:mm')) an $env:COMPUTERNAME`r`n"
    $w.FindName('copy').Add_Click({ [System.Windows.Clipboard]::SetText($txt) }.GetNewClosure())
    $w.FindName('save').Add_Click({
        $d = New-Object Microsoft.Win32.SaveFileDialog
        $d.Filter = 'Textdatei (*.txt)|*.txt'
        $d.FileName = "BitLocker-Wiederherstellung_$($Letter)_$($Id.Trim('{}').Split('-')[0]).txt"
        if ($d.ShowDialog() -eq $true) {
            if ($d.FileName.Substring(0, 1) -ieq $Letter) { [void][System.Windows.MessageBox]::Show($w, 'Nicht auf dem verschluesselten Laufwerk speichern!', 'BitLocker', 'OK', 'Warning'); return }
            [System.IO.File]::WriteAllText($d.FileName, $txt, [System.Text.Encoding]::UTF8)
            [void][System.Windows.MessageBox]::Show($w, "Gespeichert: $($d.FileName)", 'BitLocker', 'OK', 'Information')
        }
    }.GetNewClosure())
    [void]$w.ShowDialog()
}
