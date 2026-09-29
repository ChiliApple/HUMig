#Requires -Version 5.1
<#
.SYNOPSIS
    HUMig - Benutzerprofil-Migration (Backup / Restore) fuer Windows 10/11, lokal oder ueber das Netzwerk.
.DESCRIPTION
    WPF-Oberflaeche (Catppuccin Mocha), Hintergrund-Engine ohne UI-Freeze, Modul-Katalog in Config\modules*.json.
    Laeuft portabel (z.B. vom USB-Laufwerk, Backups im Unterordner BACKUPS) oder auf jedem PC/Server im Netz.
    Start: Start.cmd (fordert Administratorrechte an) oder in einer Admin-PowerShell: .\HUMig.ps1
.NOTES
    Zielmaschine: der PC, auf dem das Tool gestartet wird (Windows PowerShell 5.1, als Administrator).
#>
param([switch]$HideConsole, [switch]$UserMode)   # UserMode: ohne Administratorrechte, nur eigenes Profil

# Eigene App-ID (Taskleiste zeigt das HUMig-Icon statt PowerShell) - muss VOR jeder Oberflaeche gesetzt werden
try {
    if (-not ('HMWin.Native' -as [type])) {
        Add-Type -Namespace HMWin -Name Native -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
[DllImport("shell32.dll", CharSet = CharSet.Unicode)] public static extern int SetCurrentProcessExplicitAppUserModelID(string AppID);
'@
    }
    [void][HMWin.Native]::SetCurrentProcessExplicitAppUserModelID('HUMig.Profilmigration')
    if ($HideConsole) { [void][HMWin.Native]::ShowWindow([HMWin.Native]::GetConsoleWindow(), 0) }
} catch { }

# ============================================================================
# GLOBALE VARIABLEN
# ============================================================================
$script:Version   = '2.0.38'
$script:AppName   = 'HUMig'
$script:AppRoot   = $PSScriptRoot
$script:ConfigDir = Join-Path $script:AppRoot 'Config'
$script:LogDir    = Join-Path $script:AppRoot 'Logs'
$script:Engine    = Join-Path $script:AppRoot 'Functions\Migration-Engine.ps1'
$script:EngineQuality = Join-Path $script:AppRoot 'Functions\Migration-Quality.ps1'
$script:JobRunning = $false
$script:CurrentJob = $null
$script:RemoteCred = $null
$script:Profiles   = @()
$script:BackupChecks  = @{}
$script:RestoreChecks = @{}
$script:SelectedBackup = $null
# Update-Quelle (anpassbar ueber Config\update.json: { "Owner": "...", "Repo": "...", "Branch": "main" })
$script:UpdateOwner  = 'ChiliApple'
$script:UpdateRepo   = 'HUMig'
$script:UpdateBranch = 'main'

# ============================================================================
# ADMIN-RECHTE
# ============================================================================
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, Microsoft.VisualBasic
$script:UserMode = [bool]$UserMode
if (-not $isAdmin -and -not $script:UserMode) {
    $a = [System.Windows.MessageBox]::Show("HUMig laeuft ohne Administratorrechte.`n`nJa = als Administrator neu starten (alle Funktionen)`nNein = Benutzer-Modus: eigenes Profil sichern und wiederherstellen, einzelne Dateien aus einem Backup holen", 'HUMig', 'YesNoCancel', 'Question')
    if ($a -eq 'No') { $script:UserMode = $true }
    if ($a -eq 'Yes') {
        Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$PSCommandPath`"", '-HideConsole') -WorkingDirectory $script:AppRoot
        exit
    }
    if ($a -ne 'No') { exit }
}

# ============================================================================
# STARTBILDSCHIRM (Logo)
# ============================================================================
function New-LogoImage([string]$File) {
    $p = Join-Path $script:AppRoot "Assets\$File"
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try {
        # ueber Bytes laden -> Datei bleibt nicht gesperrt (Update)
        $bytes = [System.IO.File]::ReadAllBytes($p)
        $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
        $bmp.BeginInit(); $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bmp.StreamSource = New-Object System.IO.MemoryStream (, $bytes); $bmp.EndInit(); $bmp.Freeze()
        return $bmp
    } catch { return $null }
}
$script:LogoImage = New-LogoImage 'logo.png'
$script:AppIcon = $null
try {
    $ip = Join-Path $script:AppRoot 'Assets\icon.ico'
    if (Test-Path -LiteralPath $ip) {
        $ms = New-Object System.IO.MemoryStream (, [System.IO.File]::ReadAllBytes($ip))
        $script:AppIcon = [System.Windows.Media.Imaging.BitmapFrame]::Create($ms, [System.Windows.Media.Imaging.BitmapCreateOptions]::None, [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
    }
} catch { }

$script:Splash = $null
try {
    $sx = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" WindowStyle="None" ResizeMode="NoResize" AllowsTransparency="True"
        Background="Transparent" Width="420" Height="300" WindowStartupLocation="CenterScreen" Topmost="True" ShowInTaskbar="False">
  <Border Background="#FF1E1E2E" CornerRadius="12" BorderBrush="#FFB9A88A" BorderThickness="2">
    <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center">
      <Image x:Name="img" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Width="120" Height="120" RenderOptions.BitmapScalingMode="HighQuality"/>
      <TextBlock Text="HUMig v2" FontSize="34" FontWeight="Bold" Foreground="#FFCDD6F4" HorizontalAlignment="Center" Margin="0,8,0,0"/>
      <TextBlock Text="Benutzerprofil-Migration" FontSize="15" Foreground="#FFA6ADC8" HorizontalAlignment="Center"/>
      <TextBlock Text="wird geladen ...  v$($script:Version)" FontSize="11" Foreground="#FF6C7086" HorizontalAlignment="Center" Margin="0,10,0,0"/>
    </StackPanel>
  </Border>
</Window>
"@
    $script:Splash = [System.Windows.Markup.XamlReader]::Parse($sx)
    if ($script:LogoImage) { $script:Splash.FindName('img').Source = $script:LogoImage }
    if ($script:AppIcon) { $script:Splash.Icon = $script:AppIcon }
    $script:Splash.Show()
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    [void][System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [System.Windows.Threading.DispatcherOperationCallback] { param($f) $f.Continue = $false; $null }, $frame)
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
} catch { $script:Splash = $null }
$script:SplashShown = Get-Date

# ============================================================================
# FUNKTIONEN LADEN
# ============================================================================
foreach ($mod in @('Core-Console.ps1', 'Core-Async.ps1', 'Migration-Engine.ps1', 'Migration-Quality.ps1', 'UI-Common.ps1', 'UI-Shell.ps1', 'UI-Settings.ps1', 'UI-Extras.ps1', 'UI-Quality.ps1', 'UI-Apps.ps1', 'UI-AppEditor.ps1', 'UI-AppWizard.ps1', 'UI-BackupSchedule.ps1', 'Tools-Software.ps1', 'Tools-Drivers.ps1', 'Tools-System.ps1', 'Tools-School.ps1', 'Tools-Multi.ps1', 'ServerBackup-Engine.ps1', 'UI-ServerBackup.ps1')) {
    $mp = Join-Path $script:AppRoot "Functions\$mod"
    try { . $mp } catch { [System.Windows.MessageBox]::Show("$mod konnte nicht geladen werden:`n$_", 'HUMig', 'OK', 'Error') | Out-Null; exit 1 }
}

# ============================================================================
# KONFIGURATION
# ============================================================================
function Read-JsonFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { Write-Host "[WARN] $Path fehlerhaft: $_" -ForegroundColor Yellow; $script:ConfigErrors += "$(Split-Path $Path -Leaf): $($_.Exception.Message)"; return $null }
}
function Write-JsonFile([string]$Path, $Data, [int]$Depth = 6) {
    try {
        $dir = Split-Path $Path -Parent
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $Data | ConvertTo-Json -Depth $Depth | Set-Content -LiteralPath $Path -Encoding UTF8 -Force
    } catch { Write-Host "[WARN] $Path nicht gespeichert: $_" -ForegroundColor Yellow }
}
# Lokale Werte ueber Standardwerte legen (rekursiv fuer Objekte, Arrays/Werte ersetzen)
function Merge-Config($Default, $Local) {
    if ($null -eq $Local) { return $Default }
    if ($null -eq $Default) { return $Local }
    if ($Default -is [System.Management.Automation.PSCustomObject] -and $Local -is [System.Management.Automation.PSCustomObject]) {
        $r = [ordered]@{}
        foreach ($p in $Default.PSObject.Properties) { $r[$p.Name] = $p.Value }
        foreach ($p in $Local.PSObject.Properties) {
            if ($r.Contains($p.Name)) { $r[$p.Name] = Merge-Config $r[$p.Name] $p.Value } else { $r[$p.Name] = $p.Value }
        }
        return [pscustomobject]$r
    }
    return $Local
}
$script:ConfigErrors = @()
function Import-AppConfig {
    $script:ConfigErrors = @()
    $script:Settings = Merge-Config (Read-JsonFile (Join-Path $script:ConfigDir 'settings.default.json')) (Read-JsonFile (Join-Path $script:ConfigDir 'settings.json'))
    # Standort-Profil: nicht-leere Werte des aktiven Profils ueberlagern die Grundwerte (Grundwerte bleiben fuer das Einstellungsfenster)
    $script:SettingsBase = $script:Settings
    $script:ActiveSchool = $null
    $an = "$($script:Settings.ActiveProfile)".Trim()
    if ($an) { $script:ActiveSchool = @($script:Settings.Profiles | Where-Object { $_ -and "$($_.Name)" -eq $an })[0] }
    if ($script:ActiveSchool) {
        $pr = $script:ActiveSchool
        $ov = [ordered]@{}
        foreach ($k in @('BackupRoot', 'SoftwareFolder', 'DriverFolder', 'UsmtPath', 'ADServer')) { if ("$($pr.$k)".Trim()) { $ov[$k] = "$($pr.$k)".Trim() } }
        $net = [ordered]@{}
        if ("$($pr.SubnetMask)".Trim()) { $net.SubnetMask = "$($pr.SubnetMask)".Trim() }
        if (@($pr.DnsServers | Where-Object { $_ }).Count) { $net.DnsServers = @($pr.DnsServers | Where-Object { $_ }) }
        if ($net.Count) { $ov.Network = [pscustomobject]$net }
        $script:Settings = Merge-Config $script:Settings ([pscustomobject]$ov)
    }
    $exLocal = Read-JsonFile (Join-Path $script:ConfigDir 'exceptions.json')
    $script:Exceptions = Merge-Config (Read-JsonFile (Join-Path $script:ConfigDir 'exceptions.default.json')) $exLocal
    $modDef = Read-JsonFile (Join-Path $script:ConfigDir 'modules.default.json')
    $modLoc = Read-JsonFile (Join-Path $script:ConfigDir 'modules.json')
    $mods = [System.Collections.Generic.List[object]]::new()
    foreach ($m in @($modDef.Modules)) { $mods.Add($m) }
    if ($modLoc -and $modLoc.Modules) {
        foreach ($m in @($modLoc.Modules)) {
            $idx = -1
            for ($i = 0; $i -lt $mods.Count; $i++) { if ($mods[$i].Id -eq $m.Id) { $idx = $i; break } }
            if ($idx -ge 0) { $mods[$idx] = $m } else { $mods.Add($m) }
        }
    }
    # Programm-Katalog (Config\apps*.json): Module fuer Programme, ausgeblendet bis zur Erkennung
    try { Import-HMAppCatalog $mods } catch { $script:ConfigErrors += "apps.json: $($_.Exception.Message)" }
    $script:Modules = @($mods)
    $script:DefaultModuleIds = @($modDef.Modules | ForEach-Object { $_.Id })
    # Originalwerte merken (fuer das Einstellungsfenster), dann Anzeige/Standard aus settings.json ueberlagern
    $script:ModuleCatalog = @($script:Modules | ForEach-Object { [pscustomobject]@{ Id = $_.Id; Show = $_.Show; Default = $_.Default } })
    $ov = $script:Settings.ModuleOverrides
    if ($ov) {
        foreach ($m in $script:Modules) {
            $o = $ov.($m.Id)
            if ($o) {
                if ($null -ne $o.Show) { $m | Add-Member -NotePropertyName Show -NotePropertyValue ([bool]$o.Show) -Force }
                if ($null -ne $o.Default) { $m | Add-Member -NotePropertyName Default -NotePropertyValue ([bool]$o.Default) -Force }
            }
        }
    }
    $script:Groups  = @($modDef.Groups)
    if ($modLoc -and $modLoc.Groups) { foreach ($g in @($modLoc.Groups)) { if ($script:Groups -notcontains $g) { $script:Groups += $g } } }
    foreach ($m in $script:Modules) { if ($script:Groups -notcontains $m.Group) { $script:Groups += $m.Group } }
    $script:Presets = @($modDef.Presets)
    if ($modLoc -and $modLoc.Presets) { $script:Presets = @($modLoc.Presets) + $script:Presets }
    $uc = Read-JsonFile (Join-Path $script:ConfigDir 'update.json')
    if ($uc) {
        if ("$($uc.Owner)".Trim())  { $script:UpdateOwner  = "$($uc.Owner)".Trim() }
        if ("$($uc.Repo)".Trim())   { $script:UpdateRepo   = "$($uc.Repo)".Trim() }
        if ("$($uc.Branch)".Trim()) { $script:UpdateBranch = "$($uc.Branch)".Trim() }
    }
}
function Save-LocalSetting([string]$Name, $Value) {
    $p = Join-Path $script:ConfigDir 'settings.json'
    $cur = Read-JsonFile $p
    $h = [ordered]@{}
    if ($cur) { foreach ($x in $cur.PSObject.Properties) { $h[$x.Name] = $x.Value } }
    $h[$Name] = $Value
    Write-JsonFile $p ([pscustomobject]$h)
    Import-AppConfig
}
Import-AppConfig

# ============================================================================
# XAML
# ============================================================================
try {
    [xml]$xamlDoc = Get-Content (Join-Path $script:AppRoot 'XAML\MainWindow.xaml') -Raw -Encoding UTF8
    $script:Window = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xamlDoc))
} catch {
    if ($script:Splash) { $script:Splash.Close() }
    [System.Windows.MessageBox]::Show("Oberflaeche (XAML) konnte nicht geladen werden:`n$_", 'HUMig', 'OK', 'Error') | Out-Null
    exit 1
}
$script:Window.Title = "HUMig v2  ($($script:Version))" + $(if ($script:UserMode) { '  -  Benutzer-Modus' } elseif (-not $isAdmin) { '  (ohne Administratorrechte - eingeschraenkt)' } else { '' })
if ($script:AppIcon) { $script:Window.Icon = $script:AppIcon }

function Get-UI([string]$n) { $e = $script:Window.FindName($n); if (-not $e) { Write-Host "[WARN] UI '$n' fehlt" -ForegroundColor Yellow }; return $e }
$ui = @{}
foreach ($n in @('imgLogo', 'lblTitle', 'lblSubTitle', 'btnUpdate', 'btnSettings', 'btnHelp', 'btnAbout', 'cmbComputer', 'btnConnect', 'btnLocal', 'cmbUser', 'lblSid',
    'txtBackupRoot', 'btnBrowseRoot', 'btnOpenRoot', 'lblFree', 'tabMain', 'cmbPreset', 'btnAllOn', 'btnAllOff', 'pnlBackupModules', 'lstExtra', 'btnExtraAdd',
    'btnExtraDel', 'chkMinProfileExc', 'chkNoProfileFileExc', 'chkMinSystemExc', 'chkNoSystemFileExc', 'btnEditExceptions', 'cmbThreads', 'btnPrecheck',
    'btnProfileSize', 'btnBackup', 'btnCancel', 'btnRefreshBackups', 'btnOpenBackup', 'btnDeleteBackup', 'btnCleanupBackups', 'dgBackups', 'lblRestoreInfo',
    'pnlRestoreModules', 'lblRestoreTarget', 'chkGpUpdate', 'chkWUDrivers', 'chkNumLock', 'chkFavorites', 'chkFastBoot', 'txtPostScript', 'btnPostScript',
    'btnRestore', 'btnCancelRestore', 'btnToolCredWiz', 'btnToolCredList', 'btnToolUserAppData', 'btnToolUserStartup', 'btnToolProfileFolder', 'pnlSysTools',
    'pnlLinks', 'rtbConsole', 'pbMain', 'lblStatus', 'lblElapsed', 'rowConsole', 'btnToolSoftDeploy', 'btnToolDrvDeploy', 'btnToolSoftList', 'lblSizeTotal', 'lstExclude',
    'btnExclAdd', 'btnExclDel', 'btnBigFiles', 'chkIncremental', 'lblIncremental', 'chkSpaceCheck', 'chkVerify', 'chkOneDriveLocal', 'btnBitLocker', 'btnReport',
    'chkRestoreOneDrive', 'pnlToolsComputer', 'pnlToolsProfile', 'pnlToolsDiag',
    'chkCatalog', 'btnVerifyBackup', 'btnCompare', 'btnOverview', 'chkKeepNewer', 'btnRestorePreview', 'btnChecklist', 'pnlSchool', 'cmbSchool', 'btnApps', 'btnReinstall', 'btnADDevices',
    'tabServerBackup', 'cmbSbProfile', 'btnSbProfileNew', 'btnSbProfileSave', 'btnSbProfileEdit', 'btnSbProfileDel', 'lblSbHost', 'cmbSbDrive', 'btnSbDrives',
    'btnSbDiskSetup', 'btnSbOpenDrive', 'btnSbEject', 'lblSbDiskInfo', 'lblSbSize', 'chkSbHostConfig', 'chkSbVerify', 'chkSbHostSystem', 'lblSbHostSystem', 'pnlSbVms',
    'lblSbDisks', 'dgSbHistory', 'btnSbBackup', 'btnSbCancel', 'btnSbOverview', 'btnSbVersions', 'btnSbHostOnly', 'btnSbRestore', 'btnSbFeature', 'btnSbSchedule', 'lblSbSchedule', 'btnBackupSchedule', 'lblBackupSchedule')) { $ui[$n] = Get-UI $n }
Initialize-HMTaskbar
$script:RowConsole = $ui.rowConsole
if ($script:LogoImage) { $ui.imgLogo.Source = $script:LogoImage }
$ui.lblSubTitle.Text = "Benutzerprofil-Migration  v$($script:Version)"

# ============================================================================
# KONSOLE / LOG
# ============================================================================
if (-not (Test-Path -LiteralPath $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }
Set-ConsoleLogFile (Join-Path $script:LogDir ("HUMig_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss')))
function Out-Console([string]$Msg, [string]$Lvl = 'Info') { Write-ConsoleOutput -Message $Msg -Level $Lvl -Window $script:Window }
function Out-Separator { Out-Console '' 'Separator' }
function Set-Status([string]$Text, [string]$Color = '#FFA6E3A1') {
    $ui.lblStatus.Text = $Text
    $ui.lblStatus.Foreground = Get-ConsoleBrush $Color
}
function Confirm-Action([string]$Message, [string]$Title = 'HUMig') {
    return ([System.Windows.MessageBox]::Show($script:Window, $Message, $Title, 'YesNo', 'Warning') -eq 'Yes')
}
$ui.rtbConsole.Add_MouseRightButtonUp({ Clear-ConsoleOutput -Window $script:Window; $_.Handled = $true })

# Alte Sitzungs-Logs aufraeumen (> 60 Tage)
Get-ChildItem -LiteralPath $script:LogDir -Filter 'HUMig_*.log' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-60) } | Remove-Item -Force -ErrorAction SilentlyContinue

Initialize-AsyncPool -PoolSize 6

# ============================================================================
# BACKUP-ORDNER
# ============================================================================
function Get-BackupRoot {
    $r = "$($script:Settings.BackupRoot)".Trim()
    if (-not $r) { $r = Join-Path $script:AppRoot 'BACKUPS' }
    return $r
}
function Update-BackupRootInfo {
    $root = Get-BackupRoot
    $ui.txtBackupRoot.Text = $root
    $ui.lblFree.Text = ''
    try {
        if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
        if ($root -match '^([A-Za-z]):') {
            $d = New-Object System.IO.DriveInfo ($Matches[1])
            $ui.lblFree.Text = "frei: $(Format-HMSize $d.AvailableFreeSpace) von $(Format-HMSize $d.TotalSize)  ($($d.DriveFormat))"
            $ui.lblFree.Foreground = Get-ConsoleBrush $(if ($d.AvailableFreeSpace -lt 20GB) { '#FFF38BA8' } else { '#FFA6ADC8' })
        } else {
            $f = Get-HMFreeSpace $root
            $ui.lblFree.Text = "Netzwerkfreigabe$(if ($f -ge 0) { ", frei: $(Format-HMSize $f)" })"
            $ui.lblFree.Foreground = Get-ConsoleBrush '#FFA6ADC8'
        }
        $ui.lblFree.ToolTip = $null
        Update-BackupDriveSecurity
    } catch { $ui.lblFree.Text = "nicht erreichbar: $($_.Exception.Message)"; $ui.lblFree.Foreground = Get-ConsoleBrush '#FFF38BA8' }
    if ($ui.lblSizeTotal) { Update-SizeTotal }
}
$ui.btnBitLocker.Add_Click({ Show-BitLockerDialog "$($ui.btnBitLocker.Tag)" })
# Standort-Wert speichern (Backup-Ordner, AD-Server): bei aktivem Standort im Profil, sonst als Grundwert
function Set-SiteSetting([string]$Key, [string]$Value) {
    if ($script:ActiveSchool) {
        $name = "$($script:ActiveSchool.Name)"
        $list = @(foreach ($pr in @($script:SettingsBase.Profiles | Where-Object { $_ })) {
            $h = [ordered]@{}; foreach ($x in $pr.PSObject.Properties) { $h[$x.Name] = $x.Value }
            if ("$($pr.Name)" -eq $name) { $h[$Key] = $Value }
            [pscustomobject]$h
        })
        Save-LocalSetting 'Profiles' $list
    } else { Save-LocalSetting $Key $Value }
}
function Set-BackupRootSetting([string]$Path) { Set-SiteSetting 'BackupRoot' $Path }
$ui.btnBrowseRoot.Add_Click({
    $d = New-Object System.Windows.Forms.FolderBrowserDialog
    $d.Description = 'Ordner fuer Backups waehlen (z.B. USB-NVMe oder Netzwerkfreigabe)'
    $d.SelectedPath = Get-BackupRoot
    if ($d.ShowDialog() -eq 'OK') {
        Set-BackupRootSetting $d.SelectedPath
        Update-BackupRootInfo; Update-BackupList
        Out-Console "Backup-Ordner: $($d.SelectedPath)$(if ($script:ActiveSchool) { " (Standort $($script:ActiveSchool.Name))" })" 'Success'
    }
})
$ui.btnBrowseRoot.Add_MouseRightButtonUp({
    Set-BackupRootSetting ''
    Update-BackupRootInfo; Update-BackupList
    Out-Console "Backup-Ordner: Standard ($(Get-BackupRoot))" 'Success'
})
$ui.btnOpenRoot.Add_Click({ $r = Get-BackupRoot; if (Test-Path -LiteralPath $r) { Start-Process explorer.exe -ArgumentList "`"$r`"" } })

# ============================================================================
# MODUL-CHECKBOXEN
# ============================================================================
function New-Brush([string]$Hex) { return (Get-ConsoleBrush $Hex) }
$script:ModuleSizeLbl = @{}
function Build-ModulePanel {
    param($Panel, [hashtable]$Store, [switch]$Restore, [string[]]$Extra = @())
    $Panel.Children.Clear(); $Store.Clear()
    if (-not $Restore) { $script:ModuleSizeLbl = @{} }
    foreach ($g in $script:Groups) {
        $mods = @($script:Modules | Where-Object { $_.Group -eq $g -and ($_.Show -ne $false -or $Extra -contains $_.Id) -and (-not $script:UserMode -or (Test-HMModuleUserOk $_)) })
        if (-not $mods.Count) { continue }
        $b = New-Object System.Windows.Controls.Border
        $b.Background = New-Brush '#FF181825'; $b.CornerRadius = [System.Windows.CornerRadius]::new(6)
        $b.Padding = [System.Windows.Thickness]::new(8, 4, 8, 4); $b.Margin = [System.Windows.Thickness]::new(0, 0, 0, 4)
        $sp = New-Object System.Windows.Controls.StackPanel
        $h = New-Object System.Windows.Controls.TextBlock
        $h.Text = $g.ToUpper(); $h.FontSize = 10; $h.FontWeight = [System.Windows.FontWeights]::Bold
        $h.Foreground = New-Brush '#FFA6ADC8'; $h.Margin = [System.Windows.Thickness]::new(0, 0, 0, 2)
        [void]$sp.Children.Add($h)
        $wp = New-Object System.Windows.Controls.WrapPanel
        foreach ($m in $mods) {
            # Zeile: Checkbox (Name gekuerzt mit ...) | Groesse rechtsbuendig, Abstand zur naechsten Spalte
            $cb = New-Object System.Windows.Controls.CheckBox
            $nt = New-Object System.Windows.Controls.TextBlock
            $nt.Text = $m.Name; $nt.TextTrimming = 'CharacterEllipsis'
            $cb.Content = $nt; $cb.Tag = $m.Id; $cb.VerticalAlignment = 'Center'
            $cb.ToolTip = $(if ($m.Hint) { "$($m.Name)`n$($m.Hint)" } else { $m.Name })
            $row = New-Object System.Windows.Controls.Grid
            $row.Width = 300; $row.Margin = [System.Windows.Thickness]::new(0, 1, 14, 1)
            $c0 = New-Object System.Windows.Controls.ColumnDefinition; $c0.Width = [System.Windows.GridLength]::new(1, 'Star')
            $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = [System.Windows.GridLength]::Auto
            [void]$row.ColumnDefinitions.Add($c0); [void]$row.ColumnDefinitions.Add($c1)
            [System.Windows.Controls.Grid]::SetColumn($cb, 0)
            [void]$row.Children.Add($cb)
            if (-not $Restore) {
                $cb.IsChecked = [bool]$m.Default
                $cb.Add_Checked({ Update-SizeTotal }); $cb.Add_Unchecked({ Update-SizeTotal })
                $sl = New-Object System.Windows.Controls.TextBlock
                $sl.MinWidth = 62; $sl.FontSize = 10; $sl.TextAlignment = 'Right'; $sl.VerticalAlignment = 'Center'
                $sl.Foreground = New-Brush '#FF89B4FA'; $sl.Margin = [System.Windows.Thickness]::new(6, 0, 0, 0)
                [System.Windows.Controls.Grid]::SetColumn($sl, 1)
                [void]$row.Children.Add($sl)
                $script:ModuleSizeLbl[$m.Id] = $sl
            }
            [void]$wp.Children.Add($row)
            $Store[$m.Id] = $cb
        }
        [void]$sp.Children.Add($wp)
        $b.Child = $sp
        [void]$Panel.Children.Add($b)
    }
}
function Get-CheckedModules([hashtable]$Store) {
    # IsEnabled nur im Reiter Restore relevant (Module, die das Backup nicht enthaelt, sind dort gesperrt)
    $isRestore = [object]::ReferenceEquals($Store, $script:RestoreChecks)
    $ids = @($Store.Keys | Where-Object { $Store[$_].IsChecked -eq $true -and (-not $isRestore -or $Store[$_].IsEnabled) } | ForEach-Object { "$_" })
    return @($script:Modules | Where-Object { $ids -contains "$($_.Id)" })
}
function Write-ModuleDiag([hashtable]$Store) {
    $all = @($Store.Keys); $chk = @($all | Where-Object { $Store[$_].IsChecked -eq $true })
    $en = @($chk | Where-Object { $Store[$_].IsEnabled })
    $miss = @($chk | Where-Object { $k = "$_"; -not @($script:Modules | Where-Object { "$($_.Id)" -eq $k }).Count })
    Out-Console ("Diagnose Module: {0} Kaestchen, angehakt: {1} ({2}), davon aktiv: {3}, Module geladen: {4}, ohne Modul: {5}" -f $all.Count, $chk.Count, ($chk -join ','), $en.Count, @($script:Modules).Count, ($miss -join ',')) 'Debug'
}
# ---- Groessen je Modul (aus "Groesse ermitteln", gilt fuer Computer + Benutzer) ----
$script:SizeCache = $null
function Get-SizeKey {
    $p = Get-SelectedProfile
    if (-not $p -or -not $p.SID) { return '' }
    $c = Get-TargetComputer
    if (Test-HMIsLocal $c) { $c = $env:COMPUTERNAME }
    return ("{0}|{1}" -f $c, $p.SID).ToUpperInvariant()
}
function Test-SizeCacheValid { return [bool]($script:SizeCache -and $script:SizeCache.Key -and $script:SizeCache.Key -eq (Get-SizeKey)) }
function Get-BackupFree { try { return (Get-HMFreeSpace (Get-BackupRoot)) } catch { return [long]-1 } }
function Update-SizeTotal {
    if (-not $ui.lblSizeTotal) { return }
    if (-not (Test-SizeCacheValid)) { $ui.lblSizeTotal.Text = ''; return }
    $sum = [long]0; $unk = 0
    foreach ($m in (Get-CheckedModules $script:BackupChecks)) {
        if ($script:SizeCache.Modules.ContainsKey($m.Id)) { $v = [long]$script:SizeCache.Modules[$m.Id]; if ($v -gt 0) { $sum += $v } } else { $unk++ }
    }
    $txt = "Auswahl: $(Format-HMSize $sum)"
    if ($unk) { $txt += " (+$unk nicht gemessen)" }
    $free = Get-BackupFree
    $col = '#FFA6ADC8'
    if ($free -ge 0) { $txt += "  |  frei: $(Format-HMSize $free)"; if ($sum -gt $free) { $col = '#FFF38BA8'; $txt += '  - ZU WENIG PLATZ' } }
    $ui.lblSizeTotal.Text = $txt
    $ui.lblSizeTotal.Foreground = Get-ConsoleBrush $col
}
function Show-ModuleSizes {
    $valid = Test-SizeCacheValid
    foreach ($k in @($script:ModuleSizeLbl.Keys)) {
        $l = $script:ModuleSizeLbl[$k]; $l.Text = ''
        if ($valid -and $script:SizeCache.Modules.ContainsKey($k)) { $v = [long]$script:SizeCache.Modules[$k]; $l.Text = $(if ($v -lt 0) { '-' } else { Format-HMSize $v }) }
    }
    $ui.btnBigFiles.IsEnabled = [bool]($valid -and @($script:SizeCache.Top).Count)
    Update-SizeTotal
}

$script:RestoreExtraIds = @()
Build-ModulePanel $ui.pnlBackupModules $script:BackupChecks
Build-ModulePanel $ui.pnlRestoreModules $script:RestoreChecks -Restore

# Vorlagen (zuletzt gewaehlte wird gemerkt)
function Update-PresetList {
    $script:SuppressPresetSave = $true
    $ui.cmbPreset.Items.Clear()
    foreach ($p in $script:Presets) { [void]$ui.cmbPreset.Items.Add($p.Name) }
    $last = "$($script:Settings.LastPreset)"
    # umbenannte Vorlagen (ab v2.0.4)
    $renamed = @{ 'Lehrer-Notebook' = 'Notebook'; 'Verwaltungs-PC' = 'Buero-PC (mit Druckertreibern)'; 'Schueler-Geraet (Geraeteinitiative)' = 'Minimal' }
    if ($renamed.ContainsKey($last)) { $last = $renamed[$last] }
    if ($last -and @($script:Presets | Where-Object { $_.Name -eq $last }).Count) { $ui.cmbPreset.SelectedItem = $last }
    $script:SuppressPresetSave = $false
}
# Eingetragene Zusaetzliche Ordner -> Modul 'Zusaetzliche Ordner' bleibt angehakt (auch nach 'Keine' oder Vorlagenwechsel)
function Sync-ExtraFoldersCheck {
    if ($ui.lstExtra.Items.Count -and $script:BackupChecks.ContainsKey('ExtraFolders')) { $script:BackupChecks['ExtraFolders'].IsChecked = $true }
}
# Angehakte Backup-Module; sind Ordner eingetragen, gehoert 'Zusaetzliche Ordner' immer dazu
function Get-BackupModules {
    $mods = @(Get-CheckedModules $script:BackupChecks)
    if ($ui.lstExtra.Items.Count -and -not @($mods | Where-Object { $_.Id -eq 'ExtraFolders' }).Count) {
        $m = @($script:Modules | Where-Object { $_.Id -eq 'ExtraFolders' })[0]
        if ($m -and $script:BackupChecks.ContainsKey('ExtraFolders') -and $script:BackupChecks['ExtraFolders'].IsEnabled) {
            $script:BackupChecks['ExtraFolders'].IsChecked = $true
            $mods += $m
            Out-Console "Zusaetzliche Ordner sind eingetragen - Modul 'Zusaetzliche Ordner' wurde angehakt (nicht sichern: Ordner aus der Liste entfernen)" 'Info'
        }
    }
    return $mods
}
$ui.cmbPreset.Add_SelectionChanged({
    $p = @($script:Presets | Where-Object { $_.Name -eq $ui.cmbPreset.SelectedItem }) | Select-Object -First 1
    if (-not $p) { return }
    $all = @($p.Modules) -contains '*'
    foreach ($k in $script:BackupChecks.Keys) { $script:BackupChecks[$k].IsChecked = ($all -or (@($p.Modules) -contains $k)) }
    Sync-ExtraFoldersCheck
    if ($p.Hint) { $ui.cmbPreset.ToolTip = "$($p.Hint)" } else { $ui.cmbPreset.ToolTip = $null }
    if (-not $script:SuppressPresetSave) { Save-LocalSetting 'LastPreset' "$($p.Name)" }
})
Update-PresetList
$ui.btnAllOn.Add_Click({ foreach ($c in $script:BackupChecks.Values) { $c.IsChecked = $true } })
$ui.btnAllOff.Add_Click({ foreach ($c in $script:BackupChecks.Values) { $c.IsChecked = $false }; Sync-ExtraFoldersCheck })

foreach ($t in @(1, 4, 8, 16, 32, 64, 128)) { [void]$ui.cmbThreads.Items.Add("$t") }
$ui.cmbThreads.SelectedItem = "$([int]$script:Settings.Threads)"
if (-not $ui.cmbThreads.SelectedItem) { $ui.cmbThreads.SelectedItem = '32' }
$ui.cmbThreads.Add_SelectionChanged({ if ($ui.cmbThreads.SelectedItem -and -not $script:SuppressThreadSave) { Save-LocalSetting 'Threads' ([int]$ui.cmbThreads.SelectedItem) } })

# Zusaetzliche Ordner
$ui.btnExtraAdd.Add_Click({
    $d = New-Object System.Windows.Forms.FolderBrowserDialog
    $d.Description = 'Zusaetzlichen Ordner waehlen (bei Remote-Backup: Pfad am Quell-PC, z.B. D:\Daten)'
    if ($d.ShowDialog() -eq 'OK') {
        [void]$ui.lstExtra.Items.Add($d.SelectedPath)
        if ($script:BackupChecks.ContainsKey('ExtraFolders')) { $script:BackupChecks['ExtraFolders'].IsChecked = $true }
    }
})
$ui.btnExtraAdd.Add_MouseRightButtonUp({
    $p = [Microsoft.VisualBasic.Interaction]::InputBox('Pfad am Quell-PC eingeben (z.B. D:\Messdaten):', 'Zusaetzlicher Ordner', '')
    if ($p) { [void]$ui.lstExtra.Items.Add($p.Trim()); if ($script:BackupChecks.ContainsKey('ExtraFolders')) { $script:BackupChecks['ExtraFolders'].IsChecked = $true } }
})
$ui.btnExtraDel.Add_Click({ if ($ui.lstExtra.SelectedItem) { $ui.lstExtra.Items.Remove($ui.lstExtra.SelectedItem) } })

# Einzelne Pfade ausschliessen
function Add-ExcludePath([string]$Path) {
    $p = "$Path".Trim().Trim('"').TrimEnd('\')
    if (-not $p -or $p -notmatch '^[A-Za-z]:\\') { return $false }
    foreach ($i in @($ui.lstExclude.Items)) { if ("$i" -ieq $p) { return $false } }
    [void]$ui.lstExclude.Items.Add($p)
    return $true
}
$ui.btnExclAdd.Add_Click({
    $d = New-Object System.Windows.Forms.FolderBrowserDialog
    $d.Description = 'Ordner, der NICHT gesichert werden soll (bei Remote-Backup: Rechtsklick = Pfad am Quell-PC eintippen)'
    if ($d.ShowDialog() -eq 'OK') { [void](Add-ExcludePath $d.SelectedPath) }
})
$ui.btnExclAdd.Add_MouseRightButtonUp({
    $p = [Microsoft.VisualBasic.Interaction]::InputBox('Pfad am Quell-PC (Ordner oder Datei), z.B. C:\Users\max\Videos:', 'Pfad ausschliessen', '')
    if ($p -and -not (Add-ExcludePath $p)) { Out-Console "Ungueltiger oder doppelter Pfad: $p (vollstaendiger Pfad mit Laufwerk, z.B. C:\...)" 'Warning' }
})
$ui.btnExclDel.Add_Click({ if ($ui.lstExclude.SelectedItem) { $ui.lstExclude.Items.Remove($ui.lstExclude.SelectedItem) } })
$ui.btnBigFiles.Add_Click({
    if (-not (Test-SizeCacheValid)) { Out-Console 'Zuerst "Groesse ermitteln" fuer diesen Benutzer.' 'Warning'; return }
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($x in @($script:SizeCache.Top)) { $rows.Add(@($x.Kind, [Math]::Round(([double]$x.Size / 1MB), 1), $x.Path, $x.Module)) }
    Show-DataGridWindow -Title "Grosse Ordner und Dateien - $(Get-TargetComputer)" -Columns @('Art', 'MB', 'Pfad', 'Modul') -ColumnTypes @{ MB = [double] } -Rows $rows.ToArray() `
        -Sort 'MB DESC' -CountText "$($rows.Count) Eintraege (Ordner = Summe inkl. Unterordner)" -Width 1150 -Height 640 `
        -Actions @(@{ Text = 'Markierte ausschliessen'; Color = '#FFFAB387'; Handler = {
            param($rows, $win, $ctx)
            $n = 0
            foreach ($r in @($rows)) { if (Add-ExcludePath "$($r.Pfad)") { $n++ } }
            Out-Console "$n Pfad(e) ausgeschlossen - 'Groesse ermitteln' zeigt die neue Summe." 'Success'
            [void][System.Windows.MessageBox]::Show($win, "$n Pfad(e) in 'Pfade ausschliessen' eingetragen.", 'Ausschliessen', 'OK', 'Information')
        } })
})

# Optionen: Startwerte aus den Einstellungen, jede Aenderung wird sofort gespeichert
function Set-OptionDefaults {
    $b = $script:Settings.Backup
    $ui.chkIncremental.IsChecked   = ($null -eq $b -or $b.Incremental -ne $false)
    $ui.chkSpaceCheck.IsChecked    = ($null -eq $b -or $b.SpaceCheck -ne $false)
    $ui.chkVerify.IsChecked        = ($null -eq $b -or $b.Verify -ne $false)
    $ui.chkCatalog.IsChecked       = [bool]($b -and $b.Catalog)
    $ui.chkOneDriveLocal.IsChecked = [bool]($b -and $b.OneDriveLocal)
    $ui.chkMinProfileExc.IsChecked    = [bool]($b -and $b.MinimalProfileExceptions)
    $ui.chkNoProfileFileExc.IsChecked = [bool]($b -and $b.NoProfileFileExceptions)
    $ui.chkMinSystemExc.IsChecked     = [bool]($b -and $b.MinimalSystemExceptions)
    $ui.chkNoSystemFileExc.IsChecked  = [bool]($b -and $b.NoSystemFileExceptions)
}
function Save-BackupOptionSettings {
    $h = [ordered]@{}
    if ($script:Settings.Backup) { foreach ($x in $script:Settings.Backup.PSObject.Properties) { $h[$x.Name] = $x.Value } }
    $h.Incremental = [bool]$ui.chkIncremental.IsChecked
    $h.SpaceCheck = [bool]$ui.chkSpaceCheck.IsChecked
    $h.Verify = [bool]$ui.chkVerify.IsChecked
    $h.Catalog = [bool]$ui.chkCatalog.IsChecked
    $h.OneDriveLocal = [bool]$ui.chkOneDriveLocal.IsChecked
    $h.MinimalProfileExceptions = [bool]$ui.chkMinProfileExc.IsChecked
    $h.NoProfileFileExceptions = [bool]$ui.chkNoProfileFileExc.IsChecked
    $h.MinimalSystemExceptions = [bool]$ui.chkMinSystemExc.IsChecked
    $h.NoSystemFileExceptions = [bool]$ui.chkNoSystemFileExc.IsChecked
    Save-LocalSetting 'Backup' ([pscustomobject]$h)
}
Set-OptionDefaults
foreach ($c in @($ui.chkIncremental, $ui.chkSpaceCheck, $ui.chkVerify, $ui.chkCatalog, $ui.chkOneDriveLocal, $ui.chkMinProfileExc, $ui.chkNoProfileFileExc, $ui.chkMinSystemExc, $ui.chkNoSystemFileExc)) {
    $c.Add_Click({ Save-BackupOptionSettings; Update-IncrementalInfo })
}

# ============================================================================
# COMPUTER / BENUTZER
# ============================================================================
$script:ComputerHistoryFile = Join-Path $script:ConfigDir 'computer_history.json'
function Initialize-ComputerList {
    $ui.cmbComputer.Items.Clear()
    [void]$ui.cmbComputer.Items.Add($env:COMPUTERNAME)
    foreach ($c in @(Read-JsonFile $script:ComputerHistoryFile)) { if ($c -and $c -ne $env:COMPUTERNAME) { [void]$ui.cmbComputer.Items.Add("$c") } }
    $ui.cmbComputer.Text = $env:COMPUTERNAME
}
function Add-ComputerHistory([string]$Name) {
    if (-not $Name -or (Test-HMIsLocal $Name)) { return }
    $h = @(@($Name) + @(Read-JsonFile $script:ComputerHistoryFile | Where-Object { $_ -and $_ -ne $Name }) | Select-Object -First 25)
    Write-JsonFile $script:ComputerHistoryFile $h
    if (-not $ui.cmbComputer.Items.Contains($Name)) { $ui.cmbComputer.Items.Insert(1, $Name) }
}
function Get-TargetComputer {
    $c = "$($ui.cmbComputer.Text)".Trim()
    if (-not $c) { $c = $env:COMPUTERNAME }
    return $c
}
function Format-ProfileEntry($p) {
    $s = $p.Folder
    if ($p.Account -and ($p.Account.Split('\')[-1] -ne $p.Folder)) { $s += "  ($($p.Account))" } elseif ($p.Account) { $s += "  ($($p.Account.Split('\')[0]))" }
    if ($p.Interactive) { $s += '  [angemeldet]' } elseif ($p.Loaded) { $s += '  [aktiv]' }
    return $s
}
# Gewaehltes Profil (oder eingegebenes Konto ohne Profil)
function Get-SelectedProfile {
    $i = $ui.cmbUser.SelectedIndex
    $t = "$($ui.cmbUser.Text)".Trim()
    if ($i -ge 0 -and $i -lt $script:Profiles.Count -and (Format-ProfileEntry $script:Profiles[$i]) -eq $t) { return $script:Profiles[$i] }
    $hit = @($script:Profiles | Where-Object { $_.Folder -eq $t -or $_.Account -eq $t })
    if ($hit.Count) { return $hit[0] }
    if ($t) { return [pscustomobject]@{ SID = $null; LocalPath = $null; Folder = $t.Split('\')[-1]; Account = $t; Loaded = $false; LastUse = ''; NoProfile = $true } }
    return $null
}
function Update-SidLabel {
    $p = Get-SelectedProfile
    if (-not $p) { $ui.lblSid.Text = ''; return }
    if ($p.NoProfile) { $ui.lblSid.Text = 'kein Profil an diesem PC (nur Restore mit USMT)'; $ui.lblSid.Foreground = Get-ConsoleBrush '#FFF9E2AF' }
    else {
        $ui.lblSid.Text = "$($p.LocalPath)$(if ($p.LastUse) { "   zuletzt $($p.LastUse)" })$(if ($p.Interactive) { '   (angemeldet)' } elseif ($p.Loaded) { '   (aktiv - Registry geladen, z.B. getrennte Sitzung)' })"
        $ui.lblSid.Foreground = Get-ConsoleBrush $(if ($p.Loaded) { '#FFF9E2AF' } else { '#FFA6ADC8' })
    }
    $ui.lblSid.ToolTip = "Konto: $($p.Account)`nSID: $($p.SID)`nProfil: $($p.LocalPath)$(if ($p.LastUse) { "`nZuletzt verwendet: $($p.LastUse)" })`n`nKlick = SID kopieren"
    Update-RestoreTargetLabel
    Show-ModuleSizes
    Update-IncrementalInfo
}
$ui.lblSid.Add_MouseLeftButtonUp({ $p = Get-SelectedProfile; if ($p -and $p.SID) { [System.Windows.Clipboard]::SetText("$($p.SID)"); Out-Console "SID kopiert: $($p.SID)" 'Success' } })
$ui.cmbUser.Add_SelectionChanged({ $script:Window.Dispatcher.BeginInvoke([action]{ Update-SidLabel }) | Out-Null })
$ui.cmbUser.Add_KeyUp({ Update-SidLabel })

function Connect-Target {
    if ($script:UserMode) {
        # Benutzer-Modus: nur das eigene Profil auf diesem PC (keine Profil-Abfrage anderer Benutzer)
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $ui.cmbComputer.Text = $env:COMPUTERNAME; $script:RemoteCred = $null
        $script:Profiles = @([pscustomobject]@{ SID = $id.User.Value; LocalPath = $env:USERPROFILE; Folder = (Split-Path $env:USERPROFILE -Leaf)
            Account = $id.Name; Loaded = $true; Interactive = $true; LastUse = (Get-Date).ToString('yyyy-MM-dd HH:mm') })
        $ui.cmbUser.Items.Clear(); [void]$ui.cmbUser.Items.Add((Format-ProfileEntry $script:Profiles[0])); $ui.cmbUser.SelectedIndex = 0
        Out-Console "Benutzer-Modus: $($id.Name) auf $env:COMPUTERNAME - vor dem Backup/Restore offene Programme (Outlook, Browser, Office) schliessen" 'Info'
        Set-Status "Benutzer-Modus: $($id.Name)" '#FFA6E3A1'
        Update-SidLabel
        Start-HMAppDetect
        return
    }
    $comp = Get-TargetComputer
    Set-Status "Verbinde mit $comp ..." '#FFF9E2AF'
    Out-Console "Benutzerprofile von $comp laden ..." 'Info'
    $ui.cmbUser.Items.Clear(); $script:Profiles = @(); $ui.lblSid.Text = ''
    Invoke-AsyncCommand -ScriptBlock {
        param($eng, $comp, $cred)
        . $eng
        $out = [ordered]@{ Profiles = @(); Laptop = $false; Error = $null; Smb = $null; WinRM = $null }
        try { $out.Profiles = @(Get-HMUserProfiles -Computer $comp -Credential $cred) } catch { $out.Error = $_.Exception.Message }
        try {
            $sb = { [bool](@(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue).Count) -or [bool](@((Get-CimInstance Win32_SystemEnclosure -ErrorAction SilentlyContinue).ChassisTypes | Where-Object { $_ -in 8, 9, 10, 14, 30, 31, 32 }).Count) }
            if (Test-HMIsLocal $comp) { $out.Laptop = & $sb }
            else {
                $p = @{ ComputerName = $comp; ScriptBlock = $sb; ErrorAction = 'Stop' }; if ($cred) { $p.Credential = $cred }
                try { $out.Laptop = Invoke-Command @p; $out.WinRM = $true } catch { $out.WinRM = $false }
                $out.Smb = Test-Path -LiteralPath "\\$comp\C$\Windows"
            }
        } catch { }
        [pscustomobject]$out
    } -ArgumentList @($script:Engine, $comp, $script:RemoteCred) -TimeoutSec 90 -State $comp -OnComplete {
        param($r, $comp)
        if ($r -is [string]) { Out-Console "Verbindung zu ${comp}: $r" 'Error'; Set-Status 'Fehler' '#FFF38BA8'; return }
        if ($r.Error -and -not @($r.Profiles).Count) { Out-Console "Profile von $comp nicht lesbar: $($r.Error)" 'Error'; Set-Status 'Fehler' '#FFF38BA8'; return }
        $script:Profiles = @($r.Profiles)
        foreach ($p in $script:Profiles) { [void]$ui.cmbUser.Items.Add((Format-ProfileEntry $p)) }
        # Vorauswahl: angemeldeter Benutzer, sonst zuletzt verwendet
        # Vorauswahl: lokal der Benutzer, der das Tool startet (wenn angemeldet) - sonst angemeldeter Benutzer, sonst Registry geladen
        $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $sel = @()
        if (Test-HMIsLocal $comp) { $sel = @($script:Profiles | Where-Object { $_.SID -eq $me -and $_.Interactive } | Select-Object -First 1) }
        if (-not $sel) { $sel = @($script:Profiles | Where-Object { $_.Interactive } | Select-Object -First 1) }
        if (-not $sel) { $sel = @($script:Profiles | Where-Object { $_.Loaded } | Select-Object -First 1) }
        if (-not $sel) { $sel = @($script:Profiles | Sort-Object LastUse -Descending | Select-Object -First 1) }
        if ($sel) { $ui.cmbUser.SelectedIndex = [array]::IndexOf($script:Profiles, $sel[0]) }
        Out-Console "$($script:Profiles.Count) Benutzerprofile auf $comp" 'Success'
        if ($null -ne $r.WinRM) {
            Out-Console ("   Admin-Freigabe C`$: {0}   PowerShell-Remoting (WinRM): {1}" -f $(if ($r.Smb) { 'OK' } else { 'NICHT erreichbar' }), $(if ($r.WinRM) { 'OK' } else { 'NICHT erreichbar (Registry/USMT/Drucker/WLAN remote nicht moeglich) - Werkzeuge > Fernwartung aktivieren' })) $(if ($r.Smb -and $r.WinRM) { 'Success' } else { 'Warning' })
            Add-ComputerHistory $comp
        }
        if ($script:BackupChecks.ContainsKey('Wlan')) {
            $wm = @($script:Modules | Where-Object { $_.Id -eq 'Wlan' })[0]
            if ($wm.AutoOnLaptop) { $script:BackupChecks['Wlan'].IsChecked = [bool]$r.Laptop }
        }
        Set-Status "Verbunden: $comp" '#FFA6E3A1'
        Update-SidLabel
        # Programm-Katalog: installierte Programme erkennen, passende Module einblenden
        if ($null -eq $r.WinRM -or $r.WinRM) { Start-HMAppDetect }
    }
}
$ui.btnConnect.Add_Click({ Connect-Target })
$ui.btnConnect.Add_MouseRightButtonUp({
    $c = Get-Credential -Message "Anmeldedaten fuer $(Get-TargetComputer) (nur fuer diese Sitzung, leer/Abbrechen = eigene Anmeldung)"
    $script:RemoteCred = $c
    Out-Console $(if ($c) { "Remote-Anmeldedaten: $($c.UserName) (nur diese Sitzung)" } else { 'Remote-Anmeldedaten entfernt - eigene Anmeldung wird verwendet' }) 'Info'
})
$ui.btnLocal.Add_Click({ $ui.cmbComputer.Text = $env:COMPUTERNAME; $script:RemoteCred = $null; Connect-Target })
$ui.cmbComputer.Add_KeyDown({ if ($_.Key -eq 'Return') { Connect-Target } })
$ui.btnADDevices.Add_Click({ Show-HMMultiDialog })

# ============================================================================
# LANGE JOBS (Backup, Restore, Groesse)
# ============================================================================
function Set-JobUi([bool]$Running) {
    $script:JobRunning = $Running
    foreach ($b in @($ui.btnBackup, $ui.btnRestore, $ui.btnProfileSize, $ui.btnConnect, $ui.btnLocal, $ui.btnDeleteBackup, $ui.btnCleanupBackups, $ui.btnUpdate, $ui.btnPrecheck)) { $b.IsEnabled = -not $Running }
    $ui.btnCancel.IsEnabled = $Running
    $ui.btnCancelRestore.IsEnabled = $Running
    $ui.cmbComputer.IsEnabled = -not $Running -and -not $script:UserMode
    $ui.cmbUser.IsEnabled = -not $Running -and -not $script:UserMode
    if ($script:UserMode) { $ui.btnUpdate.IsEnabled = $false }
    foreach ($b in @($script:SbButtons)) { if ($b) { $b.IsEnabled = -not $Running } }
    if ($ui.btnSbCancel) { $ui.btnSbCancel.IsEnabled = $Running }
}
function Start-EngineJob {
    param([string]$Command, [hashtable]$Ctx, [string]$Title, [scriptblock]$OnFinished, [string[]]$ScriptFiles = @())
    if (-not @($ScriptFiles).Count) { $ScriptFiles = @($script:Engine, $script:EngineQuality) }
    $job = New-JobState
    $script:CurrentJob = $job
    Set-JobUi $true
    $ui.pbMain.Value = 0
    Set-Status "$Title ..." '#FFF9E2AF'
    $script:JobTitle = $Title
    $script:JobOnFinished = $OnFinished
    Start-LongJob -ScriptFiles $ScriptFiles -Command $Command -Ctx $Ctx -Job $job -OnTick {
        param($j)
        $n = 0
        while ($j.Log.Count -gt 0 -and $n -lt 200) { $e = $j.Log.Dequeue(); Out-Console $e.Msg $e.Lvl; $n++ }
        $ui.pbMain.Value = [Math]::Min(100, [int]$j.Progress)
        Set-HMTaskbarProgress ([double]$j.Progress / 100) 'Normal'
        if ($j.Status) { $ui.lblStatus.Text = "$($script:JobTitle) - $($j.Status)" }
        $ui.lblElapsed.Text = ((Get-Date) - $j.Started).ToString('hh\:mm\:ss')
    } -OnDone {
        param($j)
        Set-JobUi $false
        $script:CurrentJob = $null
        $ttl = $script:JobTitle
        if ($j.Cancel) { Set-Status "$ttl abgebrochen" '#FFF38BA8' }
        elseif ($j.Error) { Set-Status "$ttl mit Fehler beendet" '#FFF38BA8' }
        else { Set-Status "$ttl fertig" '#FFA6E3A1' }
        Set-HMTaskbarProgress 0 'None'
        if ($script:JobOnFinished) { & $script:JobOnFinished $j }
        # Benachrichtigung (Ton, Windows-Hinweis, Taskleiste blinkt) - bei laengeren Vorgaengen oder wenn das Fenster nicht aktiv ist
        $res = $j.Result
        $rs = if ($j.Cancel) { 'Cancelled' } elseif ($j.Error) { 'Error' } elseif ($res -and $res.Status) { "$($res.Status)" } else { 'OK' }
        $kind = switch ($rs) { 'OK' { 'Info' } 'Created' { 'Info' } 'Warning' { 'Warning' } 'NoCatalog' { 'Warning' } default { 'Error' } }
        $stTxt = switch ($rs) { 'OK' { 'erfolgreich' } 'Created' { 'erstellt' } 'NoCatalog' { 'ohne Katalog - nur Kurzpruefung' } 'Warning' { 'mit Warnungen' } 'NoSpace' { 'nicht gestartet - zu wenig Platz' } 'Cancelled' { 'abgebrochen' } default { 'mit Fehlern' } }
        $det = "Dauer $($ui.lblElapsed.Text)"
        if ($res -and $res.SizeBytes) { $det = "$(Format-HMSize ([long]$res.SizeBytes)), $det" } elseif ($res -and $res.Total) { $det = "$(Format-HMSize ([long]$res.Total)), $det" }
        $long = ((Get-Date) - $j.Started).TotalSeconds -gt 20
        if ($rs -eq 'NoSpace') { }
        elseif ($long -or -not $script:Window.IsActive) { Show-HMNotification "HUMig - $ttl $stTxt" $det $kind }
        elseif ($rs -eq 'OK') { [System.Media.SystemSounds]::Asterisk.Play() }
    }
}
$cancelAction = {
    if ($script:CurrentJob -and (Confirm-Action 'Laufenden Vorgang abbrechen? Bereits kopierte Daten bleiben erhalten.')) {
        $script:CurrentJob.Cancel = $true
        Stop-HMJobProcess $script:CurrentJob
        Out-Console 'Abbruch angefordert ...' 'Warning'
        # haengt Robocopy trotzdem (z.B. wartet Windows auf einen Cloud-Download), nach 15 s erneut beenden und Hinweis geben
        $script:CancelJob = $script:CurrentJob
        $t = New-Object System.Windows.Threading.DispatcherTimer
        $t.Interval = [TimeSpan]::FromSeconds(15)
        $t.Add_Tick({
            param($src)
            $src.Stop()
            $j = $script:CancelJob
            if ($j -and $script:CurrentJob -eq $j) {
                Stop-HMJobProcess $j
                Out-Console 'Vorgang reagiert noch nicht: Windows wartet evtl. auf einen Cloud-Download - in der Windows-Meldung "Automatische Dateidownloads" auf "Download abbrechen" klicken. Robocopy wurde erneut beendet.' 'Warning'
            }
        })
        $t.Start()
    }
}
# Robocopy-Prozess samt Unterprozessen hart beenden (taskkill /T /F), auch wenn Kill() nicht greift
function Stop-HMJobProcess($Job) {
    $p = $null
    try { $p = $Job.Process } catch { }
    if (-not $p) { return }
    try { if (-not $p.HasExited) { $p.Kill() } } catch { }
    try { if (-not $p.HasExited) { & taskkill.exe /PID $p.Id /T /F 2>&1 | Out-Null } } catch { }
}
$ui.btnCancel.Add_Click($cancelAction)
$ui.btnCancelRestore.Add_Click($cancelAction)

function Get-BackupOptions {
    return @{
        ExtraFolders = @($ui.lstExtra.Items | ForEach-Object { "$_" })
        MinimalProfileExceptions = [bool]$ui.chkMinProfileExc.IsChecked
        NoProfileFileExceptions  = [bool]$ui.chkNoProfileFileExc.IsChecked
        MinimalSystemExceptions  = [bool]$ui.chkMinSystemExc.IsChecked
        NoSystemFileExceptions   = [bool]$ui.chkNoSystemFileExc.IsChecked
        ExcludePaths             = @($ui.lstExclude.Items | ForEach-Object { "$_" })
        OneDriveLocal            = [bool]$ui.chkOneDriveLocal.IsChecked
        SkipSpaceCheck           = -not [bool]$ui.chkSpaceCheck.IsChecked
        Verify                   = [bool]$ui.chkVerify.IsChecked
        RestoreOneDrive          = [bool]$ui.chkRestoreOneDrive.IsChecked
        Catalog                  = [bool]$ui.chkCatalog.IsChecked
        KeepNewer                = [bool]$ui.chkKeepNewer.IsChecked
        VerifySamples            = $(if ($script:Settings.Backup -and $script:Settings.Backup.VerifySamples) { [int]$script:Settings.Backup.VerifySamples } else { 30 })
    }
}
function New-BaseCtx {
    $p = Get-SelectedProfile
    return @{
        ToolVersion = $script:Version; ToolRoot = $script:AppRoot; Computer = (Get-TargetComputer); Credential = $script:RemoteCred; UserMode = [bool]$script:UserMode
        UserSid = $p.SID; ProfilePath = $p.LocalPath; UserFolder = $p.Folder; Account = $p.Account
        Settings = $script:Settings; Exceptions = $script:Exceptions; Threads = [int]$ui.cmbThreads.SelectedItem
        BackupRoot = (Get-BackupRoot); Options = (Get-BackupOptions); AppCatalog = @($script:AppCatalog)
    }
}

# ============================================================================
# BACKUP
# ============================================================================
$ui.btnBackup.Add_Click({
    $p = Get-SelectedProfile
    if (-not $p -or $p.NoProfile) { Out-Console 'Bitte zuerst einen Benutzer mit Profil waehlen (Verbinden).' 'Warning'; return }
    $mods = @(Get-BackupModules)
    if (-not $mods.Count) { Out-Console 'Keine Module gewaehlt.' 'Warning'; Write-ModuleDiag $script:BackupChecks; return }
    if (@($mods | Where-Object { $_.Id -eq 'ExtraFolders' }).Count -and -not $ui.lstExtra.Items.Count) { Out-Console "Modul 'Zusaetzliche Ordner' gewaehlt, aber kein Ordner eingetragen." 'Warning' }
    $root = Get-BackupRoot
    if (-not (Test-Path -LiteralPath $root)) { try { New-Item -ItemType Directory -Path $root -Force | Out-Null } catch { Out-Console "Backup-Ordner nicht erreichbar: $root" 'Error'; return } }
    $ctx = New-BaseCtx
    $name = '{0}_{1}_{2}' -f (Get-Date -Format 'yyyy-MM-dd_HHmm'), (ConvertTo-HMSafeName $ctx.Computer), (ConvertTo-HMSafeName $p.Folder)
    $ctx.BackupPath = Join-Path $root $name
    if ($p.Loaded) {
        if (-not (Confirm-Action "$($p.Folder) ist an $($ctx.Computer) angemeldet.`n`nGeoeffnete Dateien (Outlook-PST, Browser-Profile ...) koennen nicht gesichert werden - bitte Programme schliessen oder Benutzer abmelden.`n`nTrotzdem starten?")) { return }
    }
    if (@($mods | Where-Object { $_.Id -eq 'Usmt' }).Count -and -not $isAdmin) { Out-Console 'USMT braucht Administratorrechte - Modul wird fehlschlagen.' 'Warning' }
    $ctx.Modules = $mods
    # Inkrementell: vorhandenes Backup dieses PCs/Benutzers weiterfuehren
    if ($ui.chkIncremental.IsChecked) {
        $prev = Find-PreviousBackup
        if ($prev) { $ctx.ExistingBackup = $prev.Path }
    }
    # Platz: ohne Pruefung im Engine wenigstens die gemessenen Werte vergleichen
    if (-not $ui.chkSpaceCheck.IsChecked -and (Test-SizeCacheValid)) {
        $sum = [long]0; foreach ($m in $mods) { $v = [long]$script:SizeCache.Modules[$m.Id]; if ($v -gt 0) { $sum += $v } }
        $free = Get-BackupFree
        if ($free -ge 0 -and $sum -gt $free -and -not (Confirm-Action "Die gemessene Auswahl ($(Format-HMSize $sum)) ist groesser als der freie Platz ($(Format-HMSize $free)).`n`nTrotzdem starten?")) { return }
    }
    if ((Test-BackupDriveUnencrypted) -and $script:Settings.Backup.WarnUnencryptedUsb -ne $false) {
        Out-Console 'Hinweis: Das Backup-Laufwerk (USB) ist NICHT verschluesselt - Benutzerdaten sind bei Verlust lesbar. Knopf "Verschluesseln ..." neben dem Backup-Ordner.' 'Warning'
    }
    Out-Separator
    # Katalog-Programme, die vorher geschlossen werden sollen: Sammelabfrage, danach Start-BackupJob
    Invoke-HMProcCheck -Ctx $ctx -Kind 'Backup'
})
function Start-BackupJob([hashtable]$Ctx) {
    $script:LastBackupCtx = $Ctx
    $script:LastBackupTarget = $Ctx.BackupPath
    Start-EngineJob -Command 'Start-HMBackup -Ctx $Ctx -Job $Job' -Ctx $Ctx -Title 'Backup' -OnFinished {
        param($j)
        if ($j.Result -and "$($j.Result.Status)" -eq 'NoSpace') {
            $msg = "Zu wenig Platz am Backup-Ziel:`n  benoetigt ca. $(Format-HMSize ([long]$j.Result.Need))`n  frei $(Format-HMSize ([long]$j.Result.Free))`n`nTipp: 'Groesse ermitteln' und 'Grosse Dateien ...' zeigen, was sich ausschliessen laesst.`n`nTrotzdem starten?"
            if (Confirm-Action $msg 'Zu wenig Platz') {
                $c = $script:LastBackupCtx
                $c.Options.SkipSpaceCheck = $true
                $c.BackupPath = $script:LastBackupTarget
                $script:Window.Dispatcher.BeginInvoke([action]{ Start-BackupJob $script:LastBackupCtx }) | Out-Null
            }
            return
        }
        Update-BackupList; Update-BackupRootInfo; Update-IncrementalInfo
        if ($script:Settings.OverviewAuto -ne $false) { Update-HMBackupOverview -Quiet }
        $rep = if ($j.Result -and $j.Result.Status -and $script:LastBackupCtx.BackupPath) { Join-Path $script:LastBackupCtx.BackupPath 'Bericht_Backup.html' } else { $null }
        if ($rep -and (Test-Path -LiteralPath $rep)) { Out-Console "Protokoll: $rep  (Reiter Restore > Protokoll)" 'Info' }
    }
}

# Letztes Backup dieses PCs/Benutzers (fuer inkrementelles Backup)
function Find-PreviousBackup {
    $p = Get-SelectedProfile
    if (-not $p -or -not $p.SID -or $p.NoProfile) { return $null }
    $c = Get-TargetComputer
    if (Test-HMIsLocal $c) { $c = $env:COMPUTERNAME }
    $cand = @($script:BackupInfos | Where-Object { -not $_.Legacy -and $_.Sid -eq $p.SID -and ("$($_.Computer)" -ieq $c -or "$($_.Computer)".Split('.')[0] -ieq $c.Split('.')[0]) } | Sort-Object Name -Descending)
    if ($cand.Count) { return $cand[0] }
    return $null
}
function Update-IncrementalInfo {
    if (-not $ui.lblIncremental) { return }
    $prev = Find-PreviousBackup
    if (-not $prev) { $ui.lblIncremental.Text = 'Kein frueheres Backup - es wird ein neues angelegt.'; return }
    $d = "$($prev.Created)"; if ($d.Length -gt 16) { $d = $d.Substring(0, 16) }
    $sz = if ($prev.SizeBytes) { ", $(Format-HMSize $prev.SizeBytes)" } else { '' }
    if ($ui.chkIncremental.IsChecked) { $ui.lblIncremental.Text = "Wird aktualisiert: Backup vom $d$sz" }
    else { $ui.lblIncremental.Text = "Neues Backup (vorhandenes vom $d bleibt unveraendert)" }
}

function Start-SizeMeasure([bool]$All) {
    $p = Get-SelectedProfile
    if (-not $p -or $p.NoProfile) { Out-Console 'Bitte zuerst einen Benutzer waehlen.' 'Warning'; return }
    $ctx = New-BaseCtx
    # @(...) um das if: sonst wird eine Auswahl mit genau einem Modul zum Einzelobjekt (PS 5.1: .Count fehlt -> 'Keine Module')
    $ctx.Modules = @(if ($All) { $script:Modules | Where-Object { $script:BackupChecks.ContainsKey($_.Id) } } else { Get-BackupModules })
    if (-not $ctx.Modules.Count) { Out-Console 'Keine Module gewaehlt.' 'Warning'; return }
    $script:MeasureKey = Get-SizeKey
    Start-EngineJob -Command 'Measure-HMBackup -Ctx $Ctx -Job $Job' -Ctx $ctx -Title 'Groesse ermitteln' -OnFinished {
        param($j)
        $r = $j.Result
        if (-not $r -or $r.Cancelled -or -not $r.Modules) { return }
        if (-not $script:SizeCache -or $script:SizeCache.Key -ne $script:MeasureKey) { $script:SizeCache = @{ Key = $script:MeasureKey; Modules = @{}; Top = @() } }
        foreach ($id in @($r.Modules.Keys)) { $script:SizeCache.Modules[$id] = [long]$r.Modules[$id] }
        $script:SizeCache.Top = @($r.Top)
        Show-ModuleSizes
        $free = Get-BackupFree
        if ($free -ge 0) {
            if ($free -lt [long]$r.Total) { Out-Console "ACHTUNG: Zu wenig Platz am Backup-Ziel ($(Format-HMSize $free) frei)!" 'Error' }
            else { Out-Console "Platz am Backup-Ziel reicht ($(Format-HMSize $free) frei)." 'Success' }
        }
        if (@($r.Top).Count) { Out-Console "Groesste Ordner/Dateien: Knopf 'Grosse Dateien ...' (dort direkt ausschliessen)" 'Info' }
    }
}
$ui.btnProfileSize.Add_Click({ Start-SizeMeasure $false })
$ui.btnProfileSize.Add_MouseRightButtonUp({ Start-SizeMeasure $true })

$ui.btnPrecheck.Add_Click({
    $p = Get-SelectedProfile
    $ctx = New-BaseCtx
    Out-Separator
    Out-Console "VORAB-PRUEFUNG  $($ctx.Computer)" 'Header'
    if ($script:UserMode) { Out-Console 'INFO Benutzer-Modus: nur eigenes Profil, Module mit Systemzugriff sind ausgeblendet' 'Info' }
    else { Out-Console $(if ($isAdmin) { 'OK Tool laeuft als Administrator' } else { 'WARN Tool laeuft NICHT als Administrator' }) $(if ($isAdmin) { 'Success' } else { 'Warning' }) }
    $u = Find-HMUsmt @{ Settings = $script:Settings; ToolRoot = $script:AppRoot }
    Out-Console $(if ($u) { "OK USMT gefunden: $u" } else { 'INFO USMT nicht gefunden (nur fuer das Modul Windows-Einstellungen noetig) - Windows ADK installieren oder nach BIN\USMT\amd64 kopieren' }) $(if ($u) { 'Success' } else { 'Debug' })
    # Katalog-Module, deren Programm vor dem Backup geschlossen werden soll
    $procSpec = @(foreach ($m in @(Get-CheckedModules $script:BackupChecks)) { $cp = @(@($m.CloseProcess) | Where-Object { "$_".Trim() }); if ($cp.Count) { [pscustomobject]@{ Name = "$($m.Name)"; Procs = $cp } } })
    Invoke-AsyncCommand -ScriptBlock {
        param($eng, $comp, $cred, $sid, $pp, $procSpec, $um)
        . $eng
        $o = @()
        $isL = Test-HMIsLocal $comp
        if (-not $isL) {
            $o += if (Test-Connection -ComputerName $comp -Count 1 -Quiet) { 'OK Ping' } else { 'WARN Ping ohne Antwort (Firewall?)' }
            $o += if (Test-Path -LiteralPath "\\$comp\C$\Windows") { 'OK Admin-Freigabe C$' } else { 'FEHLER Admin-Freigabe C$ nicht erreichbar (Datei-/Druckerfreigabe, Firewall, Rechte)' }
            try { $p = @{ ComputerName = $comp; ScriptBlock = { $env:COMPUTERNAME }; ErrorAction = 'Stop' }; if ($cred) { $p.Credential = $cred }; [void](Invoke-Command @p); $o += 'OK PowerShell-Remoting (WinRM)' }
            catch { $o += "FEHLER WinRM: $($_.Exception.Message.Split([char]10)[0]) - Abhilfe: Werkzeuge > Fernwartung aktivieren" }
        }
        if ($sid) {
            $ctx = @{ Computer = $comp; IsRemote = -not $isL; Credential = $cred }
            try {
                $r = Invoke-HMTarget $ctx {
                    param($s, $pp)
                    $res = @()
                    $loaded = Test-Path -LiteralPath "Registry::HKEY_USERS\$s"
                    $res += if ($loaded) { 'WARN Benutzer ist angemeldet - offene Programme schliessen' } else { 'OK Benutzer nicht angemeldet (Registry wird geladen)' }
                    if ($loaded) {
                        $usf = Get-Item -LiteralPath "Registry::HKEY_USERS\$s\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" -ErrorAction SilentlyContinue
                        $raw = { param($n) if ($usf) { [regex]::Replace([string]$usf.GetValue($n, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames), '%USERPROFILE%', $pp.Replace('$', '$$'), 'IgnoreCase') } }
                        foreach ($n in @('Desktop', 'Personal', 'My Pictures')) { $v = & $raw $n; if ($v -match 'OneDrive') { $res += "INFO OneDrive: $n -> $v" } }
                        $ad = & $raw 'AppData'
                        if ("$ad" -match '^\\\\') { $res += "WARN AppData umgeleitet: $ad" }
                    }
                    $pst = @(Get-ChildItem -LiteralPath (Join-Path $pp 'AppData\Local\Microsoft\Outlook') -Filter *.pst -ErrorAction SilentlyContinue)
                    if ($pst.Count) { $res += "INFO $($pst.Count) PST-Datei(en) in AppData\Local\Microsoft\Outlook" }
                    $sys = Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':')) -ErrorAction SilentlyContinue
                    if ($sys) { $res += "INFO Systemlaufwerk: $([math]::Round($sys.Used / 1GB, 1)) GB belegt, $([math]::Round($sys.Free / 1GB, 1)) GB frei" }
                    $res
                } @($sid, $pp)
                $o += @($r)
                # Cloud-Ordner wie im Backup erkennen (alle Anbieter, nicht nur OneDrive)
                foreach ($cr in @(Get-HMSyncRoots $ctx $sid $pp)) { $o += "INFO Cloud-Ordner: $cr - wird ausgelassen (mit Option 'OneDrive/SharePoint: lokale Dateien mitsichern' nur lokal vorhandene Dateien, ohne Download)" }
            } catch { $o += "FEHLER Pruefung am Ziel: $($_.Exception.Message)" }
        }
        foreach ($s in @($procSpec | Where-Object { $_ })) {
            try {
                $run = @(Get-HMRunningProcs @{ Computer = $comp; IsRemote = -not $isL; Credential = $cred; UserMode = [bool]$um } @($s.Procs) $sid)
                if ($run.Count) { $o += "WARN Programm laeuft: $($s.Name) ($(@($run | ForEach-Object { $_.Name } | Select-Object -Unique) -join ', ')) - beim Start wird gefragt: schliessen, ueberspringen oder trotzdem kopieren" }
            } catch { }
        }
        $o -join "`n"
    } -ArgumentList @($script:Engine, $ctx.Computer, $script:RemoteCred, $p.SID, $p.LocalPath, $procSpec, [bool]$script:UserMode) -TimeoutSec 90 -OnComplete {
        param($r)
        foreach ($l in ("$r" -split "`n")) {
            if (-not $l.Trim()) { continue }
            $lvl = if ($l -match '^(FEHLER)') { 'Error' } elseif ($l -match '^WARN') { 'Warning' } elseif ($l -match '^OK') { 'Success' } else { 'Info' }
            Out-Console $l $lvl
        }
        # Groesse des Backups (aus 'Groesse ermitteln') - fehlt sie, wird sie jetzt gemessen
        if (Test-SizeCacheValid) {
            Update-SizeTotal
            Out-Console "INFO Backup-Groesse (gewaehlte Module): $($ui.lblSizeTotal.Text)" $(if ("$($ui.lblSizeTotal.Text)" -match 'ZU WENIG') { 'Warning' } else { 'Info' })
            Out-Console 'Vorab-Pruefung fertig' 'Debug'
        } elseif (-not $script:JobRunning) {
            Out-Console 'Vorab-Pruefung fertig - Backup-Groesse wird jetzt ermittelt (Summe oben neben der Vorlage, je Modul neben dem Haken) ...' 'Info'
            Start-SizeMeasure $false
        } else { Out-Console 'Vorab-Pruefung fertig - Backup-Groesse: Knopf "Groesse ermitteln"' 'Info' }
    }
})

# ============================================================================
# RESTORE
# ============================================================================
$script:BackupInfos = @()
function Update-BackupList {
    $root = Get-BackupRoot
    $sel = if ($script:SelectedBackup) { $script:SelectedBackup.Path } else { $null }
    $script:BackupInfos = @(Get-HMBackupList -Root $root -Modules $script:Modules)
    if ($script:UserMode) {
        # Benutzer-Modus: nur eigene Backups anzeigen (gleiche SID oder gleicher Benutzername) - Zugriffsschutz regeln die Ordnerrechte
        $me = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $script:BackupInfos = @($script:BackupInfos | Where-Object {
            ($_.Sid -and $_.Sid -eq $me.User.Value) -or ("$($_.Account)" -split '\\')[-1] -ieq $env:USERNAME -or "$($_.User)" -ieq (Split-Path $env:USERPROFILE -Leaf) })
    }
    $rows = foreach ($b in $script:BackupInfos) {
        [pscustomobject]@{
            Datum = $(if ($b.Legacy) { $b.Created } else { "$($b.Created)".Substring(0, [Math]::Min(16, "$($b.Created)".Length)) })
            Computer = $b.Computer; Benutzer = $(if ($b.Account) { $b.Account } else { $b.User })
            Groesse = $(if ($b.SizeBytes) { Format-HMSize $b.SizeBytes } else { '' })
            Status = $b.Status; Anzahl = @($b.Modules).Count; Name = $b.Name; Info = $b
        }
    }
    $ui.dgBackups.ItemsSource = @($rows)
    if ($sel) { foreach ($r in @($rows)) { if ($r.Info.Path -eq $sel) { $ui.dgBackups.SelectedItem = $r } } }
    Update-IncrementalInfo
}
function Update-RestoreTargetLabel {
    $p = Get-SelectedProfile
    $c = Get-TargetComputer
    if (-not $p) { $ui.lblRestoreTarget.Text = "$c - kein Benutzer gewaehlt"; return }
    $t = "$c \ $($p.Folder)"
    if ($p.NoProfile) { $t += "`n(noch kein Profil - Modul 'Windows-Einstellungen (USMT)' legt es an)" }
    if ($script:SelectedBackup -and $script:SelectedBackup.User -and ($script:SelectedBackup.User -ne $p.Folder)) { $t += "`nACHTUNG: Backup stammt von '$($script:SelectedBackup.User)'" }
    $ui.lblRestoreTarget.Text = $t
}
$ui.dgBackups.Add_SelectionChanged({
    $row = $ui.dgBackups.SelectedItem
    if (-not $row) { $script:SelectedBackup = $null; return }
    $b = $row.Info
    $script:SelectedBackup = $b
    # Module im Backup, die ausgeblendet sind (Programm-Katalog, ausgeblendete Standardmodule) -> einblenden
    $known = @($script:Modules | ForEach-Object { $_.Id })
    $hidden = @(@($b.Modules) | Where-Object { $_ -and -not $script:RestoreChecks.ContainsKey($_) -and $known -contains $_ })
    if ($hidden.Count) {
        $script:RestoreExtraIds = @(@($script:RestoreExtraIds) + $hidden | Where-Object { $_ } | Select-Object -Unique)
        Build-ModulePanel $ui.pnlRestoreModules $script:RestoreChecks -Restore -Extra $script:RestoreExtraIds
    }
    foreach ($k in $script:RestoreChecks.Keys) {
        $has = @($b.Modules) -contains $k
        $script:RestoreChecks[$k].IsEnabled = $has
        $script:RestoreChecks[$k].IsChecked = ($has -and $k -notin @('Info', 'Drivers', 'Tasks', 'PrintersFull'))
    }
    $txt = "Backup: $($b.Name)"
    if ($b.Legacy) { $txt += '  |  Format der Vorgaengerversion' }
    if ($b.Manifest -and $b.Manifest.SourceOS) { $txt += "  |  Quelle: $($b.Manifest.SourceOS)" }
    if ($b.Manifest -and $b.Manifest.OneDriveFolders) { $txt += "  |  OneDrive-Ordner nicht enthalten" }
    $ui.lblRestoreInfo.Text = $txt
    Update-RestoreTargetLabel
})
$ui.btnRefreshBackups.Add_Click({ Update-BackupList; Update-BackupRootInfo })
$ui.btnOpenBackup.Add_Click({ if ($script:SelectedBackup) { Start-Process explorer.exe -ArgumentList "`"$($script:SelectedBackup.Path)`"" } })
$ui.btnReport.Add_Click({
    $b = $script:SelectedBackup
    if (-not $b) { Out-Console 'Bitte zuerst ein Backup waehlen.' 'Warning'; return }
    $reps = @(Get-ChildItem -LiteralPath $b.Path -Filter 'Bericht_*.html' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    if (-not $reps.Count) { Out-Console 'Kein Protokoll in diesem Backup (erst ab Version 0.0.3).' 'Info'; return }
    if ($reps.Count -eq 1) { Start-Process $reps[0].FullName; return }
    $m = New-Object System.Windows.Controls.ContextMenu
    foreach ($r in $reps) {
        $mi = New-Object System.Windows.Controls.MenuItem
        $mi.Header = "$($r.BaseName -replace '_', ' ')  ($($r.LastWriteTime.ToString('dd.MM.yyyy HH:mm')))"; $mi.Tag = $r.FullName
        $mi.Add_Click({ param($src) Start-Process "$($src.Tag)" })
        [void]$m.Items.Add($mi)
    }
    $m.PlacementTarget = $ui.btnReport; $m.IsOpen = $true
})
$ui.btnDeleteBackup.Add_Click({
    $b = $script:SelectedBackup
    if (-not $b) { return }
    if (-not (Confirm-Action "Backup '$($b.Name)' endgueltig loeschen?")) { return }
    Out-Console "Loesche $($b.Path) ..." 'Warning'
    Invoke-AsyncCommand -ScriptBlock { param($eng, $p) . $eng; Remove-HMBackupFolder $p } -ArgumentList @($script:Engine, $b.Path) -TimeoutSec 3600 -OnComplete {
        param($r) Out-Console $(if ($r -eq 'OK') { 'Backup geloescht' } else { "$r" }) $(if ($r -eq 'OK') { 'Success' } else { 'Error' }); $script:SelectedBackup = $null; Update-BackupList; Update-BackupRootInfo
    }
})
$ui.btnCleanupBackups.Add_Click({ Start-HMRetentionCleanup })
$ui.btnPostScript.Add_Click({
    $d = New-Object Microsoft.Win32.OpenFileDialog
    $d.Filter = 'PowerShell (*.ps1)|*.ps1'
    if ($d.ShowDialog() -eq $true) { $ui.txtPostScript.Text = $d.FileName; Save-RestoreOptionSettings }
})
function Set-RestoreDefaults {
    $ui.chkGpUpdate.IsChecked = [bool]$script:Settings.Restore.GpUpdate
    $ui.chkWUDrivers.IsChecked = [bool]$script:Settings.Restore.DisableWUDrivers
    $ui.chkNumLock.IsChecked = [bool]$script:Settings.Restore.NumLockOn
    $ui.chkFavorites.IsChecked = [bool]$script:Settings.Restore.ExplorerFavorites
    $ui.chkFastBoot.IsChecked = [bool]$script:Settings.Restore.FastBootOff
    $ui.txtPostScript.Text = "$($script:Settings.Restore.PostScript)"
    $ui.chkRestoreOneDrive.IsChecked = [bool]$script:Settings.Restore.OneDriveToFolder
    $ui.chkKeepNewer.IsChecked = [bool]$script:Settings.Restore.KeepNewer
    if ($script:UserMode) {
        # Benutzer-Modus: Nacharbeiten mit Systemzugriff nie ausfuehren
        foreach ($c in @($ui.chkGpUpdate, $ui.chkWUDrivers, $ui.chkNumLock, $ui.chkFastBoot)) { $c.IsChecked = $false }
        $ui.txtPostScript.Text = ''
    }
}
Set-RestoreDefaults
# Aenderungen im Reiter Restore sofort als Vorauswahl speichern (gleiche Werte wie Einstellungen > Restore)
function Save-RestoreOptionSettings {
    if ($script:UserMode) { return }   # Benutzer-Modus aendert die gemeinsamen Vorgaben nicht
    $h = [ordered]@{}
    if ($script:Settings.Restore) { foreach ($x in $script:Settings.Restore.PSObject.Properties) { $h[$x.Name] = $x.Value } }
    $h.GpUpdate = [bool]$ui.chkGpUpdate.IsChecked
    $h.DisableWUDrivers = [bool]$ui.chkWUDrivers.IsChecked
    $h.NumLockOn = [bool]$ui.chkNumLock.IsChecked
    $h.ExplorerFavorites = [bool]$ui.chkFavorites.IsChecked
    $h.FastBootOff = [bool]$ui.chkFastBoot.IsChecked
    $h.PostScript = "$($ui.txtPostScript.Text)".Trim()
    $h.OneDriveToFolder = [bool]$ui.chkRestoreOneDrive.IsChecked
    $h.KeepNewer = [bool]$ui.chkKeepNewer.IsChecked
    Save-LocalSetting 'Restore' ([pscustomobject]$h)
}
foreach ($c in @($ui.chkGpUpdate, $ui.chkWUDrivers, $ui.chkNumLock, $ui.chkFavorites, $ui.chkFastBoot, $ui.chkRestoreOneDrive, $ui.chkKeepNewer)) { $c.Add_Click({ Save-RestoreOptionSettings }) }
$ui.txtPostScript.Add_LostFocus({ if ("$($ui.txtPostScript.Text)".Trim() -ne "$($script:Settings.Restore.PostScript)".Trim()) { Save-RestoreOptionSettings } })

$ui.btnRestore.Add_Click({
    $b = $script:SelectedBackup
    if (-not $b) { Out-Console 'Bitte zuerst ein Backup waehlen.' 'Warning'; return }
    $p = Get-SelectedProfile
    if (-not $p) { Out-Console 'Bitte Zielbenutzer waehlen (oder DOMAENE\Benutzer eintragen).' 'Warning'; return }
    $mods = @(Get-CheckedModules $script:RestoreChecks)
    if (-not $mods.Count) { Out-Console 'Keine Module gewaehlt.' 'Warning'; return }
    $comp = Get-TargetComputer
    if ($p.NoProfile -and -not @($mods | Where-Object { $_.Id -eq 'Usmt' }).Count -and @($mods | Where-Object { $_.Scope -eq 'User' }).Count) {
        Out-Console "$($p.Account) hat an $comp noch kein Profil: Benutzer einmal anmelden lassen oder 'Windows-Einstellungen (USMT)' mitwaehlen." 'Warning'
        if (-not (Confirm-Action "Ohne Profil werden nur die Computer-Module wiederhergestellt. Fortfahren?")) { return }
    }
    $msg = "Restore von`n  $($b.Name)`nnach`n  $comp \ $($p.Folder)`n`nModule: $(($mods | ForEach-Object { $_.Name }) -join ', ')"
    if ($b.User -and $b.User -ne $p.Folder) { $msg += "`n`nACHTUNG: anderer Benutzer als im Backup ($($b.User))!" }
    if ($p.Loaded) { $msg += "`n`nDer Benutzer ist angemeldet: offene Programme schliessen, Einstellungen wirken nach Neuanmeldung." }
    if (-not (Confirm-Action ($msg + "`n`nStarten?") 'Restore')) { return }
    $ctx = New-HMRestoreCtx
    if (-not $ctx) { return }
    Out-Separator
    $script:RestoreBackupForChecklist = $b
    # Katalog-Programme am Ziel-PC, die vorher geschlossen werden sollen: Sammelabfrage, danach Start-RestoreJob
    Invoke-HMProcCheck -Ctx $ctx -Kind 'Restore'
})
function Start-RestoreJob([hashtable]$Ctx) {
    Start-EngineJob -Command 'Start-HMRestore -Ctx $Ctx -Job $Job' -Ctx $Ctx -Title 'Restore' -OnFinished {
        param($j)
        if ($j.Result -and $j.Result.Report) { Out-Console "Protokoll: $($j.Result.Report)  (Knopf 'Protokoll')" 'Info' }
        Connect-Target
        if ($script:Settings.OverviewAuto -ne $false) { Update-HMBackupOverview -Quiet }
        if (-not $j.Cancel -and $j.Result -and $j.Result.Report -and (Test-Path -LiteralPath "$($j.Result.Report)") -and $script:Settings.RestoreChecklistAuto -ne $false) {
            $extra = @()
            if (Get-Command Get-HMAppAfterSteps -ErrorAction SilentlyContinue) { try { $extra = @(Get-HMAppAfterSteps $script:RestoreBackupForChecklist) } catch { } }
            $script:PendingChecklist = @{ Report = "$($j.Result.Report)"; Extra = $extra }
            $script:Window.Dispatcher.BeginInvoke([action]{ $pc = $script:PendingChecklist; $script:PendingChecklist = $null; if ($pc) { Show-HMChecklist -ReportPath $pc.Report -Extra $pc.Extra } }) | Out-Null
        }
    }
}
$ui.btnRestorePreview.Add_Click({ if (-not $script:JobRunning) { Start-HMRestorePreviewUi } })
$ui.btnChecklist.Add_Click({ Show-HMChecklist })
$ui.btnVerifyBackup.Add_Click({ if (-not $script:JobRunning) { Start-HMVerifyBackup $false } })
$ui.btnVerifyBackup.Add_MouseRightButtonUp({ param($s, $e) $e.Handled = $true; if (-not $script:JobRunning) { Start-HMVerifyBackup $true } })
$ui.btnCompare.Add_Click({ if (-not $script:JobRunning) { Start-HMCompareBackups } })
$ui.btnOverview.Add_Click({ Update-HMBackupOverview -Open })
$ui.btnApps.Add_Click({ Start-HMAppDetect -Show })
$ui.btnBackupSchedule.Add_Click({ New-HMBackupSchedule })
$ui.btnBackupSchedule.Add_MouseRightButtonUp({ param($s, $e) $e.Handled = $true; Show-HMBackupSchedules })
$ui.btnApps.Add_MouseRightButtonUp({ param($s, $e) $e.Handled = $true; Show-HMAppCatalog })
$ui.btnReinstall.Add_Click({ Start-HMAppReinstall })

# ============================================================================
# WERKZEUGE
# ============================================================================
function Get-SelectedProfilePath([string]$Sub) {
    $p = Get-SelectedProfile
    if (-not $p -or -not $p.LocalPath) { Out-Console 'Kein Profil gewaehlt.' 'Warning'; return $null }
    $path = if ($Sub) { Join-Path $p.LocalPath $Sub } else { $p.LocalPath }
    $ctx = @{ Computer = (Get-TargetComputer); IsRemote = -not (Test-HMIsLocal (Get-TargetComputer)) }
    return (Convert-HMPath $ctx $path)
}
$ui.btnToolUserAppData.Add_Click({ $x = Get-SelectedProfilePath 'AppData'; if ($x) { Start-Process explorer.exe -ArgumentList "`"$x`"" } })
$ui.btnToolUserStartup.Add_Click({ $x = Get-SelectedProfilePath 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup'; if ($x) { Start-Process explorer.exe -ArgumentList "`"$x`"" } })
$ui.btnToolProfileFolder.Add_Click({ $x = Get-SelectedProfilePath ''; if ($x) { Start-Process explorer.exe -ArgumentList "`"$x`"" } })
$ui.btnToolCredWiz.Add_Click({
    Out-Console 'Assistent fuer Anmeldeinformationen (credwiz) - sichert/stellt die Anmeldedaten des ANGEMELDETEN Windows-Benutzers her. Sicherungsdatei am besten in den Backup-Ordner legen.' 'Info'
    Start-Process credwiz.exe
})
$ui.btnToolCredList.Add_Click({ Show-HMCredentials })

# Werkzeug-Knoepfe (Text, Stil, Tooltip, Linksklick, Rechtsklick)
function Add-ToolButton($Panel, [string]$Text, [string]$Style, [string]$Tip, [scriptblock]$Click, [scriptblock]$Right = $null) {
    $b = New-Object System.Windows.Controls.Button
    $b.Content = $Text; $b.Style = $script:Window.FindResource($Style); $b.ToolTip = $Tip
    $b.Tag = @{ Click = $Click; Right = $Right }
    $b.Add_Click({ param($src) if ($script:JobRunning -and $src.Tag.Busy) { return }; try { & $src.Tag.Click } catch { Out-Console "$($src.Content): $($_.Exception.Message)" 'Error' } })
    if ($Right) { $b.Add_MouseRightButtonUp({ param($src, $e) $e.Handled = $true; try { & $src.Tag.Right } catch { Out-Console "$($src.Content): $($_.Exception.Message)" 'Error' } }) }
    [void]$Panel.Children.Add($b)
}
$tc = $ui.pnlToolsComputer
Add-ToolButton $tc 'Fernwartung aktivieren' 'BtnGreen' 'Am gewaehlten PC WinRM, Remotedesktop, SMB/C$, Remoteregistrierung und Firewall-Regeln aktivieren - Start ueber WMI (Port 135), auch wenn WinRM noch aus ist' { Start-HMEnableRemote }
Add-ToolButton $tc 'Umbenennen' 'BtnPeach' 'Computernamen aendern (Domaenen-PC: Domaenen-Anmeldedaten), optional Neustart' { Start-HMRenameComputer }
Add-ToolButton $tc 'IP-Adresse / DHCP' 'BtnPeach' 'Statische IP oder DHCP - wird als SYSTEM-Aufgabe am Ziel ausgefuehrt (Verbindungsabbruch egal)' { Start-HMNetworkConfig }
Add-ToolButton $tc 'Lokale Gruppen' 'BtnBlue' 'Administratoren, Netzwerkkonfigurations-Operatoren, Remotedesktopbenutzer, Benutzer: anzeigen, hinzufuegen, entfernen' { Show-HMLocalGroups }
Add-ToolButton $tc 'Autologon' 'BtnDefault' 'Automatische Anmeldung setzen/aufheben/anzeigen (Kennwort als LSA-Geheimnis)' { Start-HMAutologon }
Add-ToolButton $tc 'Sperrbildschirm / Energie' 'BtnDefault' 'Links: Sperrbildschirm, automatisches Sperren, Bildschirm aus, Energiesparen, Schnellstart setzen | Rechts: aktuelle Werte' { Start-HMPowerSettings } { Show-HMPowerSettings }
Add-ToolButton $tc 'Firewall / Netzwerkprofil' 'BtnDefault' 'Firewall-Profile und Netzwerkkategorie (Privat/Oeffentlich) anzeigen und aendern' { Show-HMFirewall }
Add-ToolButton $tc 'Angemeldete Benutzer' 'BtnTeal' 'Wer ist angemeldet? Sitzungen abmelden (z.B. vor einem Backup)' { Show-HMSessions }
Add-ToolButton $tc 'Nachricht senden' 'BtnTeal' 'Nachricht an alle angemeldeten Benutzer' { Start-HMMessage }
Add-ToolButton $tc 'Neustart / Herunterfahren' 'BtnRed' 'Mit Wartezeit und Nachricht - oder geplanten Neustart abbrechen' { Start-HMShutdown }
Add-ToolButton $tc 'Netzwerktest' 'BtnDefault' 'Von diesem PC zum Ziel: DNS (vor/rueckwaerts), Ping, Ports 445/5985/135/3389, WinRM' { Start-HMNetTest }
Add-ToolButton $tc 'Geraete (AD) / Mehrfach' 'BtnGreen' 'PCs aus dem Active Directory (Filter, OU) anhaken und Aktionen parallel ausfuehren: Online-Check, Fernwartung, Inventar, Autopilot, Uebermittlungsoptimierung, Aufraeumen, Software, GPUpdate, Intune, Nachricht, Neustart' { Show-HMMultiDialog }
Add-ToolButton $tc 'Remote-PowerShell' 'BtnTeal' 'Links: PowerShell-Sitzung am gewaehlten PC (Enter-PSSession) | Rechts: CMD (winrs)' { Start-HMRemoteShell $false } { Start-HMRemoteShell $true }
Add-ToolButton $tc 'Uebermittlungsoptimierung' 'BtnDefault' 'Delivery Optimization: Updates zwischen PCs im Netz teilen (LAN/Gruppe) - lokale Richtlinie setzen und Status anzeigen' { Start-HMDeliveryOpt }
Add-ToolButton $tc 'Ordnerfreigaben' 'BtnBlue' 'Freigaben mit Freigabe- und NTFS-Rechten anzeigen, Freigaben aus einem Backup uebernehmen' { Show-HMShares }
Add-ToolButton $tc 'USMT einrichten (ADK)' 'BtnDefault' 'User State Migration Tool aus dem Windows ADK nach BIN\USMT kopieren - ohne ADK: nur USMT still installieren' { Start-HMUsmtSetup }
Add-ToolButton $tc 'Inventar (mehrere PCs)' 'BtnMauve' 'Links: Hardware, Windows, BitLocker, TPM, IP/MAC mehrerer PCs parallel (WinRM) - Tabelle + CSV im Backup-Ordner\Inventar | Rechts: zusaetzlich installierte Software' { Start-HMInventory $false } { Start-HMInventory $true }
Add-ToolButton $tc 'BitLocker-Schluessel' 'BtnBlue' 'Status und Schluesselschutz aller Laufwerke, Wiederherstellungskennwort in AD oder Entra ID sichern' { Show-HMBitLockerKeys }
Add-ToolButton $tc 'Autopilot-Hash' 'BtnDefault' 'Hardware-Hash fuer Intune/Autopilot als CSV (Backup-Ordner\Autopilot)' { Start-HMAutopilotHash }
Add-ToolButton $tc 'Wake-on-LAN' 'BtnDefault' 'PC aufwecken (MAC aus Inventar/Backup) - optional ueber einen PC im Zielnetz senden' { Start-HMWakeOnLan }
Add-ToolButton $tc 'Laufwerke (C$)' 'BtnBlue' 'Links: Laufwerk C: des gewaehlten PCs im Explorer oeffnen (remote \\PC\C$) | Rechts: Laufwerk oder Freigabe waehlen - auch USB-Sticks am Remote-PC. Der angemeldete Windows-Benutzer braucht Adminrechte am Ziel-PC.' { Open-HMAdminShare } { Show-HMDriveMenu }
$tp = $ui.pnlToolsProfile
Add-ToolButton $tp 'Profil erneuern (Test)' 'BtnPeach' 'Profilordner umbenennen + Registry-Eintrag sichern/entfernen: Benutzer bekommt beim Anmelden ein frisches Profil (z.B. bei defektem Profil). Rueckgaengig: Profil zurueckholen' { Start-HMProfileRenew }
Add-ToolButton $tp 'Profil zurueckholen' 'BtnGreen' 'Erneuerte Profile anzeigen und das alte Profil wiederherstellen (Test-Profil wird beiseitegelegt)' { Show-HMProfileRestore }
Add-ToolButton $tp 'Profilordner umbenennen' 'BtnDefault' 'Ordnernamen des Profils aendern (z.B. nach Namensaenderung) und ProfileList anpassen' { Start-HMProfileRename }
Add-ToolButton $tp 'Profil anderem Konto zuweisen' 'BtnMauve' 'Profil bleibt am Ort und gehoert danach einem anderen Konto (z.B. Domaene -> lokal): Rechte, Registry, ProfileList' { Start-HMProfileAssign }
Add-ToolButton $tp 'Windows-Apps neu registrieren' 'BtnDefault' 'Store-Apps, Startmenue, Einstellungen reparieren - im Kontext des Benutzers (sofort oder bei Anmeldung)' { Start-HMAppxReregister }
Add-ToolButton $tp 'Gruppenrichtlinien-Ergebnis' 'BtnDefault' 'gpresult als HTML fuer PC + gewaehlten Benutzer' { Start-HMGpResult }
Add-ToolButton $tp 'Aufgaben aus Backup importieren' 'BtnDefault' 'Geplante Aufgaben aus dem im Reiter Restore markierten Backup einzeln importieren' { Show-HMTaskImport }
Add-ToolButton $tp 'Alte Profile loeschen' 'BtnRed' 'Alle Profile mit letzter Anmeldung anzeigen, markierte sauber loeschen (Ordner + Registry)' { Show-HMOldProfiles }
Add-ToolButton $tp 'Wichtige Dateien suchen' 'BtnPeach' 'PST, KeePass, Access, OneNote, CAD ... ausserhalb der gesicherten Bereiche finden und als Zusaetzliche Ordner aufnehmen' { Start-HMFileSearch }
Add-ToolButton $tp 'Datenbanken suchen' 'BtnPeach' 'Lokale Datenbanken (SQLite, Access, KeePass, SQL Server, Firebird ...) und Datenbank-Dienste am PC finden - als Zusaetzliche Ordner oder als Katalog-Eintrag uebernehmen (Programm wird dann vor dem Backup geschlossen)' { Start-HMDbSearch }
Add-ToolButton $tp 'Im Backup suchen' 'BtnTeal' 'Dateien im markierten Backup suchen und einzeln herauskopieren' { Start-HMBackupSearch }
$td = $ui.pnlToolsDiag
Add-ToolButton $td 'Ereignisse (Fehler)' 'BtnBlue' 'Links: Fehler der letzten 3 Tage | Rechts: 14 Tage inkl. Warnungen' { Show-HMEventLog 3 $false } { Show-HMEventLog 14 $true }
Add-ToolButton $td 'Akku-Bericht' 'BtnDefault' 'Ladestand, Akku-Zustand in %, Ladezyklen + ausfuehrlicher Windows-Akku-Bericht (HTML)' { Start-HMBatteryReport }
Add-ToolButton $td 'Aktivierung' 'BtnDefault' 'Windows- und Office-Lizenzstatus (KMS, Abo)' { Show-HMActivation }
Add-ToolButton $td 'Entra ID / Intune' 'BtnDefault' 'Links: Status (dsregcmd, MDM-Registrierung) | Rechts: Intune-Synchronisierung anstossen' { Start-HMIntune $false } { Start-HMIntune $true }
Add-ToolButton $td 'Domaene / Zeit / Kerberos' 'BtnDefault' 'Vertrauensstellung pruefen/reparieren, Zeit synchronisieren, Kerberos-Tickets des Computers leeren' { Start-HMDomainRepair }
Add-ToolButton $td 'Druckwarteschlange leeren' 'BtnDefault' 'Druckspooler stoppen, haengende Auftraege loeschen, neu starten' { Start-HMSpoolerReset }
Add-ToolButton $td 'Speicher aufraeumen' 'BtnPeach' 'Temp, Windows-Update-Cache, Fehlerberichte, Papierkorb, Komponentenspeicher - mit Anzeige des freigegebenen Platzes' { Start-HMCleanup }
Add-ToolButton $td 'Systemdateien reparieren' 'BtnPeach' 'Links: DISM /RestoreHealth + SFC /scannow im Hintergrund starten | Rechts: Status/Ergebnis' { Start-HMSystemRepair $false } { Start-HMSystemRepair $true }
$sysTools = @(
    @('Taskmanager', 'taskmgr.exe', ''), @('Autostart-Apps', 'ms-settings:startupapps', ''), @('Netzwerkadapter', 'ncpa.cpl', ''),
    @('Systemsteuerung', 'control.exe', ''), @('Verwaltung', 'control.exe', 'admintools'), @('Firewall', 'firewall.cpl', ''),
    @('Ereignisanzeige', 'eventvwr.msc', ''), @('Maus', 'main.cpl', ''), @('Geraete-Manager', 'devmgmt.msc', ''), @('Dienste', 'services.msc', ''),
    @('Programme (alt)', 'appwiz.cpl', ''), @('Computerverwaltung', 'compmgmt.msc', ''), @('Lokale Sicherheit', 'secpol.msc', ''),
    @('Zertifikate (PC)', 'certlm.msc', ''), @('Zertifikate (Benutzer)', 'certmgr.msc', ''), @('Speicherdiagnose', 'mdsched.exe', ''),
    @('Treiberueberpruefung', 'verifiergui.exe', ''), @('Schrittaufzeichnung', 'psr.exe', ''), @('Datentraeger', 'diskmgmt.msc', ''), @('Registry', 'regedit.exe', '')
)
foreach ($t in $sysTools) {
    $b = New-Object System.Windows.Controls.Button
    $b.Content = $t[0]; $b.Style = $script:Window.FindResource('BtnDefault')
    $b.Tag = @($t[1], $t[2])
    $b.Add_Click({
        param($src)
        $cmd = $src.Tag[0]; $arg = $src.Tag[1]
        try { if ($arg) { Start-Process $cmd -ArgumentList $arg } else { Start-Process $cmd } } catch { Out-Console "$cmd : $($_.Exception.Message)" 'Error' }
    })
    [void]$ui.pnlSysTools.Children.Add($b)
}
$bx = New-Object System.Windows.Controls.Button
$bx.Content = '.exe als Admin starten'; $bx.Style = $script:Window.FindResource('BtnMauve')
$bx.Add_Click({ $d = New-Object Microsoft.Win32.OpenFileDialog; $d.Filter = 'Programme (*.exe;*.msi;*.cmd;*.bat)|*.exe;*.msi;*.cmd;*.bat'; if ($d.ShowDialog() -eq $true) { Start-Process -FilePath $d.FileName -Verb RunAs } })
[void]$ui.pnlSysTools.Children.Add($bx)
$bc = New-Object System.Windows.Controls.Button
$bc.Content = 'Alle offenen Programme schliessen'; $bc.Style = $script:Window.FindResource('BtnRed')
$bc.ToolTip = 'Schliesst alle Programme mit Fenster ohne Rueckfrage (ausser PowerShell/HUMig) - z.B. vor einem lokalen Backup'
$bc.Add_Click({
    if (-not (Confirm-Action 'Alle Programme mit Fenster OHNE Rueckfrage schliessen (nicht gespeicherte Daten gehen verloren)?')) { return }
    $n = 0
    foreach ($pr in @(Get-Process | Where-Object { $_.MainWindowTitle -and $_.Id -ne $PID -and $_.ProcessName -notmatch '^(powershell|pwsh|powershell_ise|explorer)$' })) { try { $pr.CloseMainWindow() | Out-Null; $n++ } catch { } }
    Out-Console "$n Programme zum Schliessen aufgefordert" 'Success'
})
[void]$ui.pnlSysTools.Children.Add($bc)

function Get-LocalSerial { try { return "$((Get-CimInstance Win32_BIOS).SerialNumber)".Trim() } catch { return '' } }
# Link oeffnen: {SERIAL}/{COMPUTER} vom GEWAEHLTEN Computer (remote: WinRM, sonst WMI/DCOM)
function Open-HMLinkNow([string]$Url, [bool]$CopySerial, [string]$Serial, [string]$Computer) {
    if ($CopySerial -and $Serial) { Set-Clipboard -Value $Serial; Out-Console "Seriennummer $Serial ($Computer) in die Zwischenablage kopiert" 'Info' }
    Start-Process ($Url.Replace('{SERIAL}', [uri]::EscapeDataString($Serial)).Replace('{COMPUTER}', $Computer))
}
function Open-HMLink([string]$Url, [bool]$CopySerial) {
    $comp = Get-TargetComputer
    $isLocal = ($comp -eq '.' -or $comp -ieq 'localhost' -or $comp -ieq $env:COMPUTERNAME -or $comp -ilike "$($env:COMPUTERNAME).*")
    if (-not $CopySerial -and $Url -notmatch '\{SERIAL\}') { Open-HMLinkNow $Url $false '' $comp; return }
    if ($isLocal) { Open-HMLinkNow $Url $CopySerial (Get-LocalSerial) $env:COMPUTERNAME; return }
    Out-Console "Seriennummer von $comp lesen ..." 'Info'
    Invoke-AsyncCommand -ScriptBlock {
        param($h, $cred)
        $err = @()
        try {
            $p = @{ ComputerName = $h; ScriptBlock = { "$((Get-CimInstance Win32_BIOS).SerialNumber)".Trim() }; ErrorAction = 'Stop'; SessionOption = (New-PSSessionOption -OpenTimeout 15000 -OperationTimeout 30000) }
            if ($cred) { $p.Credential = $cred }
            $sn = "$(Invoke-Command @p)".Trim()
            if ($sn) { return "OK|$sn" }
        } catch { $err += "WinRM: $($_.Exception.Message)" }
        $cs = $null
        try {
            $o = @{ ComputerName = $h; SessionOption = (New-CimSessionOption -Protocol Dcom); ErrorAction = 'Stop'; OperationTimeoutSec = 20 }
            if ($cred) { $o.Credential = $cred }
            $cs = New-CimSession @o
            $sn = "$((Get-CimInstance -CimSession $cs -ClassName Win32_BIOS -ErrorAction Stop).SerialNumber)".Trim()
            if ($sn) { return "OK|$sn" }
            $err += 'WMI: keine Seriennummer'
        } catch { $err += "WMI: $($_.Exception.Message)" }
        finally { if ($cs) { Remove-CimSession $cs -ErrorAction SilentlyContinue } }
        "FEHLER|$(($err -join ' / ') -replace '[\r\n]+', ' ')"
    } -ArgumentList @($comp, $script:RemoteCred) -TimeoutSec 90 -State @{ Url = $Url; Copy = $CopySerial; Comp = $comp } -OnComplete {
        param($r, $st)
        $t = "$r"
        if ($t -like 'OK|*') { Open-HMLinkNow $st.Url $st.Copy $t.Substring(3) $st.Comp; return }
        Out-Console "Seriennummer von $($st.Comp) nicht lesbar: $(Format-RemoteError ($t -replace '^FEHLER[|:]\s*', '')) - Link ohne Seriennummer geoeffnet" 'Warning'
        Open-HMLinkNow $st.Url $false '' $st.Comp
    }
}
function Build-LinksPanel {
$ui.pnlLinks.Children.Clear()
foreach ($l in @($script:Settings.Links)) {
    if (-not $l.Name -or -not $l.Url) { continue }
    $b = New-Object System.Windows.Controls.Button
    $b.Content = $l.Name; $b.Style = $script:Window.FindResource('BtnTeal')
    $b.ToolTip = "$($l.Url)"
    $b.Tag = @("$($l.Url)", [bool]$l.CopySerial)
    $b.Add_Click({
        param($src)
        Open-HMLink -Url $src.Tag[0] -CopySerial ([bool]$src.Tag[1])
    })
    [void]$ui.pnlLinks.Children.Add($b)
}
}
Build-LinksPanel

# Software
$ui.btnToolSoftDeploy.Add_Click({ Show-SoftwareWindow })
$ui.btnToolDrvDeploy.Add_Click({ Show-DriverWindow })
$ui.btnToolSoftList.Add_Click({ Show-InstalledSoftware (Get-TargetComputer) })

# ============================================================================
# EINSTELLUNGEN / AUSNAHMEN (JSON im Editor)
# ============================================================================
function Edit-ConfigFile([string]$Name, [string]$DefaultName) {
    $p = Join-Path $script:ConfigDir $Name
    if (-not (Test-Path -LiteralPath $p)) {
        $def = Read-JsonFile (Join-Path $script:ConfigDir $DefaultName)
        if ($Name -eq 'modules.json') { $def = [pscustomobject]@{ _Info = 'Eigene Module/Vorlagen. Gleiche Id wie in modules.default.json ueberschreibt das Standardmodul. Beispiele siehe modules.default.json.'; Modules = @(); Presets = @() } }
        Write-JsonFile $p $def 8
    }
    Out-Console "Bearbeite $p - nach dem Speichern und Schliessen des Editors wird neu geladen." 'Info'
    $script:EditProcs += [pscustomobject]@{ Proc = (Start-Process notepad.exe -ArgumentList "`"$p`"" -PassThru); Name = $Name }
    if (-not $script:EditTimer.IsEnabled) { $script:EditTimer.Start() }
}
$script:EditProcs = @()
$script:EditTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:EditTimer.Interval = [TimeSpan]::FromSeconds(1)
$script:EditTimer.Add_Tick({
    $closed = @($script:EditProcs | Where-Object { $_.Proc.HasExited })
    if (-not $closed.Count) { return }
    $script:EditProcs = @($script:EditProcs | Where-Object { -not $_.Proc.HasExited })
    if (-not $script:EditProcs.Count) { $script:EditTimer.Stop() }
    Import-AppConfig
    if ($script:ConfigErrors.Count) { foreach ($e in $script:ConfigErrors) { Out-Console "Konfigurationsfehler: $e" 'Error' } }
    else { foreach ($c in $closed) { Out-Console "$($c.Name) neu geladen" 'Success' } }
    Build-ModulePanel $ui.pnlBackupModules $script:BackupChecks -Extra $script:DetectedModuleIds
    Build-ModulePanel $ui.pnlRestoreModules $script:RestoreChecks -Restore -Extra $script:RestoreExtraIds
    Update-PresetList
    Show-ModuleSizes
    Update-BackupRootInfo
    Update-BackupList
})
function Update-UiFromConfig {
    Build-ModulePanel $ui.pnlBackupModules $script:BackupChecks -Extra $script:DetectedModuleIds
    Build-ModulePanel $ui.pnlRestoreModules $script:RestoreChecks -Restore -Extra $script:RestoreExtraIds
    Update-PresetList
    Set-OptionDefaults
    Show-ModuleSizes
    $script:SuppressThreadSave = $true
    $ui.cmbThreads.SelectedItem = "$([int]$script:Settings.Threads)"
    $script:SuppressThreadSave = $false
    Set-RestoreDefaults
    Build-LinksPanel
    Update-BackupRootInfo
    Update-BackupList
    if ($script:SelectedBackup) { $ui.dgBackups.SelectedItem = $null }
    Update-SchoolUi
}
# Standort-Profile (Kopfzeile)
function Update-SchoolUi {
    $names = @($script:SettingsBase.Profiles | Where-Object { $_ -and "$($_.Name)".Trim() } | ForEach-Object { "$($_.Name)".Trim() })
    $script:SuppressSchool = $true
    $ui.cmbSchool.Items.Clear()
    if ($names.Count) {
        [void]$ui.cmbSchool.Items.Add('(keine)')
        foreach ($n in $names) { [void]$ui.cmbSchool.Items.Add($n) }
        $ui.cmbSchool.SelectedItem = $(if ($script:ActiveSchool) { "$($script:ActiveSchool.Name)" } else { '(keine)' })
        $ui.pnlSchool.Visibility = 'Visible'
    } else { $ui.pnlSchool.Visibility = 'Collapsed' }
    $script:SuppressSchool = $false
    $ui.lblSubTitle.Text = "Benutzerprofil-Migration  v$($script:Version)" + $(if ($script:ActiveSchool) { "  -  $($script:ActiveSchool.Name)" } else { '' })
}
$ui.cmbSchool.Add_SelectionChanged({
    if ($script:SuppressSchool -or $null -eq $ui.cmbSchool.SelectedItem) { return }
    $n = "$($ui.cmbSchool.SelectedItem)"; if ($n -eq '(keine)') { $n = '' }
    if ($n -eq "$($script:SettingsBase.ActiveProfile)") { return }
    if ($script:JobRunning) { Out-Console 'Waehrend eines Vorgangs kann der Standort nicht gewechselt werden.' 'Warning'; Update-SchoolUi; return }
    Save-LocalSetting 'ActiveProfile' $n
    $script:SelectedBackup = $null
    Update-UiFromConfig
    Out-Console "Standort: $(if ($n) { $n } else { '(keiner - Grundeinstellungen)' }) - Backup-Ordner $(Get-BackupRoot)" 'Success'
})
function Open-Settings([string]$Tab = '') {
    if (Show-SettingsDialog -Tab $Tab) {
        Import-AppConfig
        $v = 0.0; try { $v = [double]$script:Settings.UiScale } catch { }
        $script:UiScaleAuto = ($v -le 0); Set-HMUiScale $(if ($v -le 0) { Get-HMAutoScale } else { $v }) -Quiet
        foreach ($e in $script:ConfigErrors) { Out-Console "Konfigurationsfehler: $e" 'Error' }
        Update-UiFromConfig
    }
}
$ui.btnEditExceptions.Add_Click({ Open-Settings 'Ausnahmen' })
$ui.btnSettings.Add_Click({ Open-Settings })
$ui.btnSettings.Add_MouseRightButtonUp({
    $m = New-Object System.Windows.Controls.ContextMenu
    foreach ($e in @(@('Einstellungen (settings.json)', 'settings.json', 'settings.default.json'), @('Ausnahmelisten (exceptions.json)', 'exceptions.json', 'exceptions.default.json'), @('Eigene Module (modules.json)', 'modules.json', 'modules.default.json'))) {
        $mi = New-Object System.Windows.Controls.MenuItem
        $mi.Header = $e[0]; $mi.Tag = @($e[1], $e[2])
        $mi.Add_Click({ param($src) Edit-ConfigFile $src.Tag[0] $src.Tag[1] })
        [void]$m.Items.Add($mi)
    }
    $mi = New-Object System.Windows.Controls.MenuItem; $mi.Header = 'Config-Ordner oeffnen'
    $mi.Add_Click({ Start-Process explorer.exe -ArgumentList "`"$($script:ConfigDir)`"" }); [void]$m.Items.Add($mi)
    $mi = New-Object System.Windows.Controls.MenuItem; $mi.Header = 'Log-Ordner oeffnen'
    $mi.Add_Click({ Start-Process explorer.exe -ArgumentList "`"$($script:LogDir)`"" }); [void]$m.Items.Add($mi)
    $m.PlacementTarget = $ui.btnSettings; $m.IsOpen = $true
})

# ============================================================================
# INFO
# ============================================================================
function Show-About {
    $x = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Info" Width="420" Height="360" WindowStartupLocation="CenterOwner" ResizeMode="NoResize" Background="#FF1E1E2E">
  <StackPanel Margin="20" HorizontalAlignment="Center">
    <Image x:Name="img" Width="110" Height="110" RenderOptions.BitmapScalingMode="HighQuality"/>
    <TextBlock Text="HUMig v2" FontSize="28" FontWeight="Bold" Foreground="#FFCDD6F4" HorizontalAlignment="Center" Margin="0,8,0,0"/>
    <TextBlock Text="Benutzerprofil-Migration" FontSize="14" Foreground="#FFA6ADC8" HorizontalAlignment="Center"/>
    <TextBlock x:Name="ver" FontSize="12" Foreground="#FF89B4FA" HorizontalAlignment="Center" Margin="0,8,0,0"/>
    <TextBlock x:Name="src" FontSize="11" Foreground="#FF89B4FA" HorizontalAlignment="Center" Margin="0,4,0,0" Cursor="Hand" TextDecorations="Underline" ToolTip="Projektseite im Browser oeffnen"/>
    <TextBlock x:Name="lic" Text="Nutzungslizenz - siehe LICENSE" FontSize="11" Foreground="#FF89B4FA" HorizontalAlignment="Center" Margin="0,2,0,0" Cursor="Hand" TextDecorations="Underline" ToolTip="Lizenz anzeigen"/>
  </StackPanel>
</Window>
"@
    $w = [System.Windows.Markup.XamlReader]::Parse($x)
    if ($script:LogoImage) { $w.FindName('img').Source = $script:LogoImage }
    if ($script:AppIcon) { $w.Icon = $script:AppIcon }
    $w.FindName('ver').Text = "Version $($script:Version)  |  PowerShell $($PSVersionTable.PSVersion)"
    $w.FindName('src').Text = "github.com/$($script:UpdateOwner)/$($script:UpdateRepo)"
    # ueber den Explorer oeffnen -> Browser laeuft als angemeldeter Benutzer, nicht erhoeht
    $w.FindName('src').Add_MouseLeftButtonUp({ try { Start-Process -FilePath explorer.exe -ArgumentList "https://github.com/$($script:UpdateOwner)/$($script:UpdateRepo)" } catch { } })
    $w.FindName('lic').Add_MouseLeftButtonUp({
        $lf = Join-Path $script:AppRoot 'LICENSE'
        try { if (Test-Path -LiteralPath $lf) { Start-Process -FilePath notepad.exe -ArgumentList "`"$lf`"" } else { Start-Process -FilePath explorer.exe -ArgumentList "https://github.com/$($script:UpdateOwner)/$($script:UpdateRepo)/blob/main/LICENSE" } } catch { }
    })
    $w.Owner = $script:Window; Set-HMWindowScale $w
    [void]$w.ShowDialog()
}
# Anleitung: immer aktuell aus dem Repo laden (Docs/Anleitung.html), sonst lokale Kopie
function Show-HMManual {
    # Ziele der Reihe nach: Kopie im Tool-Ordner (bleibt aktuell) -> sonst eine Ablage, die dem aktuellen Benutzer gehoert
    # (Benutzer-Modus: eigenes LocalAppData; Administrator: Oeffentliche Dokumente, lesbar fuer den angemeldeten Benutzer)
    $script:ManualLocal = Join-Path $script:AppRoot 'Docs\Anleitung.html'
    $alt = if ($script:UserMode) { Join-Path $env:LOCALAPPDATA 'HUMig\Anleitung.html' } else { Join-Path ([Environment]::GetFolderPath('CommonDocuments')) 'HUMig_Anleitung.html' }
    Out-Console 'Anleitung wird geladen ...' 'Debug'
    Invoke-AsyncCommand -ScriptBlock {
        param($token, $owner, $repo, $branch, $targets)
        $dl = Join-Path $env:TEMP ('HUMig_Anleitung_{0}.html' -f [guid]::NewGuid().ToString('N'))
        try {
            try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
            $rel = 'Docs/Anleitung.html'
            if ($token) {
                $h = @{ Accept = 'application/vnd.github.v3.raw'; 'User-Agent' = 'HUMig'; Authorization = "token $token" }
                Invoke-WebRequest "https://api.github.com/repos/$owner/$repo/contents/${rel}?ref=$branch" -Headers $h -UseBasicParsing -TimeoutSec 20 -OutFile $dl -ErrorAction Stop
            } else {
                Invoke-WebRequest "https://raw.githubusercontent.com/$owner/$repo/$branch/$rel" -Headers @{ 'User-Agent' = 'HUMig' } -UseBasicParsing -TimeoutSec 20 -OutFile $dl -ErrorAction Stop
            }
            if ((Get-Item -LiteralPath $dl).Length -lt 1000) { return 'ERR:Datei leer' }
            $why = ''
            foreach ($t in @($targets)) {
                try {
                    $d = Split-Path $t
                    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force -ErrorAction Stop | Out-Null }
                    # ueberschreiben (Inhalt ersetzen) statt verschieben: klappt auch, wenn die alte Datei einem anderen Konto gehoert
                    Copy-Item -LiteralPath $dl -Destination $t -Force -ErrorAction Stop
                    if ((Get-Item -LiteralPath $t).Length -eq (Get-Item -LiteralPath $dl).Length) { return "OK:$t" }
                } catch { $why = $_.Exception.Message }
            }
            return "ERR:nicht speicherbar ($why)"
        } catch { return "ERR:$($_.Exception.Message)" }
        finally { Remove-Item -LiteralPath $dl -Force -ErrorAction SilentlyContinue }
    } -ArgumentList @((Read-GitHubToken), $script:UpdateOwner, $script:UpdateRepo, $script:UpdateBranch, @($script:ManualLocal, $alt)) -TimeoutSec 30 -OnComplete {
        param($r)
        $f = $null
        if ("$r" -match '^OK:(.+)$') { $f = $Matches[1]; Out-Console 'Anleitung geoeffnet (aktuelle Fassung von GitHub)' 'Debug' }
        elseif (Test-Path -LiteralPath $script:ManualLocal) { $f = $script:ManualLocal; Out-Console "Aktuelle Anleitung nicht ladbar ($("$r" -replace '^ERR:', '')) - lokale Anleitung geoeffnet" 'Warning' }
        else { Out-Console "Anleitung nicht verfuegbar: $("$r" -replace '^ERR:', '')" 'Error'; return }
        # ueber den Explorer oeffnen: Browser startet im Kontext des angemeldeten Benutzers (nicht erhoeht)
        try { Start-Process -FilePath explorer.exe -ArgumentList "`"$f`"" } catch { Out-Console "Anleitung konnte nicht geoeffnet werden: $($_.Exception.Message)" 'Error' }
    }
}
$ui.btnAbout.Add_Click({ Show-About })
$ui.btnHelp.Add_Click({ Show-HMManual })
$script:Window.Add_PreviewKeyDown({ param($s, $e) if ("$($e.Key)" -eq 'F1') { $e.Handled = $true; Show-HMManual } })
$ui.imgLogo.Add_MouseLeftButtonUp({ Show-About })

# ============================================================================
# UPDATE (GitHub)
# ============================================================================
function Get-GitHubTokenFile { return (Join-Path $script:ConfigDir ('GitHubToken_{0}.xml' -f ("$($env:USERDOMAIN)_$($env:USERNAME)" -replace '[^\w\.\-]', '_'))) }
function Read-GitHubToken {
    if ("$env:HUMIG_GITHUB_TOKEN".Trim()) { return "$env:HUMIG_GITHUB_TOKEN".Trim() }
    $f = Get-GitHubTokenFile
    if (Test-Path -LiteralPath $f) { try { $c = Import-Clixml -Path $f; if ($c -is [System.Management.Automation.PSCredential]) { return $c.GetNetworkCredential().Password.Trim() } } catch { } }
    return ''
}
function Invoke-UpdateCheck {
    Invoke-AsyncCommand -ScriptBlock {
        param($token, $owner, $repo, $branch)
        try {
            try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
            $h = @{ Accept = 'application/vnd.github.v3.raw'; 'User-Agent' = 'HUMig' }
            if ($token) { $h.Authorization = "token $token" }
            $r = Invoke-WebRequest "https://api.github.com/repos/$owner/$repo/contents/HUMig.ps1?ref=$branch" -Headers $h -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop
            $text = if ($r.Content -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($r.Content) } else { [string]$r.Content }
            if ($text -match "\`$script:Version\s*=\s*'([0-9\.]+)'") { return "REMOTE:$($Matches[1])" }
            return 'NOMATCH'
        } catch {
            $code = 0; try { $code = [int]$_.Exception.Response.StatusCode } catch { }
            if ($code -in 401, 403, 404) { return "AUTH:$code" }
            return "ERR:$($_.Exception.Message)"
        }
    } -ArgumentList @((Read-GitHubToken), $script:UpdateOwner, $script:UpdateRepo, $script:UpdateBranch) -TimeoutSec 40 -OnComplete {
        param($r)
        $r = "$r"
        if ($r -match '^REMOTE:(.+)$') {
            $remote = $Matches[1]
            $cmp = 0; try { $cmp = ([Version]$remote).CompareTo([Version]$script:Version) } catch { }
            if ($cmp -gt 0) {
                Out-Console "UPDATE VERFUEGBAR: v$remote (aktuell v$($script:Version)) - Button 'Update' druecken" 'Warning'
                $ui.btnUpdate.Content = "Update v$remote"
                $ui.btnUpdate.Background = [System.Windows.Media.Brushes]::Gold
                $ui.btnUpdate.Foreground = Get-ConsoleBrush '#FF1E1E2E'
            } else { Out-Console "Version aktuell: v$($script:Version)" 'Debug' }
        } elseif ($r -match '^AUTH:') { Out-Console "Update-Check: Repo $($script:UpdateOwner)/$($script:UpdateRepo) nicht erreichbar (privat? Rechtsklick auf 'Update' = Token eingeben)" 'Debug' }
        else { Out-Console "Update-Check nicht moeglich: $($r -replace '^ERR:', '')" 'Debug' }
    }
}
$ui.btnUpdate.Add_Click({
    if ($script:JobRunning) { Out-Console 'Waehrend eines Backups/Restores kein Update.' 'Warning'; return }
    $pull = Join-Path $script:AppRoot 'Pull.ps1'
    if (-not (Test-Path -LiteralPath $pull)) { Out-Console 'Pull.ps1 fehlt im Tool-Ordner.' 'Error'; return }
    if (-not (Confirm-Action 'HUMig schliessen, aktuelle Version von GitHub laden und neu starten?')) { return }
    Start-Process powershell.exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$pull`"", '-WaitPid', $PID) -WorkingDirectory $script:AppRoot
    $script:Window.Close()
})
$ui.btnUpdate.Add_MouseRightButtonUp({
    $f = Get-GitHubTokenFile
    $a = [System.Windows.MessageBox]::Show($script:Window, "Update-Quelle: $($script:UpdateOwner)/$($script:UpdateRepo) ($($script:UpdateBranch))`nGespeicherter Token: $(if (Test-Path -LiteralPath $f) { 'vorhanden' } else { 'keiner' })`n`nNur fuer PRIVATE Repos noetig (Fine-grained PAT, nur 'Contents: Read').`n`nJa = Token eingeben`nNein = Token loeschen", 'GitHub-Token', 'YesNoCancel', 'Question')
    if ($a -eq 'Yes') {
        $c = Get-Credential -UserName 'github' -Message 'GitHub-Token als Kennwort eingeben (wird verschluesselt gespeichert)'
        if ($c) { $c | Export-Clixml -Path $f -Force; Out-Console 'GitHub-Token gespeichert (DPAPI)' 'Success'; Invoke-UpdateCheck }
    } elseif ($a -eq 'No') { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue; Out-Console 'GitHub-Token geloescht' 'Info' }
})

# ============================================================================
# BENUTZER-MODUS (ohne Administratorrechte): nur eigenes Profil auf diesem PC
# ============================================================================
function Set-HMUserModeUi {
    $hide = { param($c) if ($c) { $c.Visibility = 'Collapsed' } }
    # Kopfzeile / Ziel: fest dieser PC und der angemeldete Benutzer
    foreach ($c in @($ui.btnUpdate, $ui.btnSettings, $ui.btnConnect, $ui.btnLocal, $ui.btnADDevices, $ui.btnBitLocker, $ui.btnDeleteBackup)) { & $hide $c }
    $ui.cmbComputer.IsEnabled = $false; $ui.cmbUser.IsEnabled = $false
    # Backup / Restore: Funktionen mit Systemzugriff ausblenden
    foreach ($c in @($ui.btnEditExceptions, $ui.chkMinSystemExc, $ui.chkNoSystemFileExc, $ui.btnCleanupBackups, $ui.btnReinstall,
                     $ui.chkGpUpdate, $ui.chkWUDrivers, $ui.chkNumLock, $ui.chkFastBoot, $ui.txtPostScript, $ui.btnPostScript)) { & $hide $c }
    # Werkzeuge: nur Suche und Ordner/Anmeldedaten des eigenen Profils
    $keep = @('Im Backup suchen', 'Wichtige Dateien suchen', 'Datenbanken suchen')
    foreach ($b in @($ui.pnlToolsProfile.Children)) { if ($keep -notcontains "$($b.Content)") { $b.Visibility = 'Collapsed' } }
    foreach ($p in @($ui.pnlToolsComputer, $ui.pnlToolsDiag, $ui.pnlSysTools, $ui.btnToolSoftDeploy)) {
        # ganze Abschnitte (Border) ausblenden
        $e = $p
        while ($e -and -not ($e -is [System.Windows.Controls.Border])) { $e = $e.Parent }
        & $hide $(if ($e) { $e } else { $p })
    }
    Out-Console 'BENUTZER-MODUS: eigenes Profil sichern/wiederherstellen, Dateien im Backup suchen. Alle anderen Funktionen brauchen Administratorrechte.' 'Warning'
}

# ============================================================================
# START / ENDE
# ============================================================================
$script:Window.Add_Closing({
    param($s, $e)
    if ($script:JobRunning) {
        if (-not (Confirm-Action 'Ein Backup/Restore laeuft noch. Wirklich beenden (Vorgang wird abgebrochen)?')) { $e.Cancel = $true; return }
        if ($script:CurrentJob) { $script:CurrentJob.Cancel = $true; Stop-HMJobProcess $script:CurrentJob }
    }
    Save-HMWindowState
    try { $us = Get-HMUiScaleSetting; if ([double]$us -ne [double]$script:SettingsBase.UiScale) { Save-LocalSetting 'UiScale' $us } } catch { }
    Remove-HMNotification
    try { Close-AsyncPool } catch { }
})
$script:Window.Add_ContentRendered({
    if ($script:Splash) {
        $rest = 1500 - ((Get-Date) - $script:SplashShown).TotalMilliseconds
        if ($rest -gt 0) { Start-Sleep -Milliseconds ([int]$rest) }
        try { $script:Splash.Close() } catch { }
        $script:Splash = $null
    }
    $script:Window.Activate() | Out-Null
})

Initialize-HMUiScale
Restore-HMWindowState
Initialize-ComputerList
Update-SchoolUi
Update-BackupRootInfo
Out-Console "HUMig v$($script:Version) - $env:USERDOMAIN\$env:USERNAME auf $env:COMPUTERNAME$(if ($script:UserMode) { ' (Benutzer-Modus)' } elseif ($isAdmin) { ' (Administrator)' } else { ' (OHNE Administratorrechte)' })" 'Header'
foreach ($e in $script:ConfigErrors) { Out-Console "Konfigurationsfehler: $e" 'Error' }
if ($script:ActiveSchool) { Out-Console "Standort: $($script:ActiveSchool.Name) - Backup-Ordner $(Get-BackupRoot)" 'Info' }
if ($script:UserMode) { Set-HMUserModeUi }
Initialize-HMServerBackupTab -IsAdmin $isAdmin
try { Update-HMBsLabel } catch { }
Update-BackupList
Connect-Target
if (-not $script:UserMode) { Invoke-UpdateCheck }
if (-not (Test-Path -LiteralPath (Join-Path $script:AppRoot 'HUMig-Benutzer.exe'))) { [void](New-HMLauncher -Name 'HUMig-Benutzer.exe') }
if (-not $script:UserMode -and -not (Test-Path -LiteralPath (Join-Path $script:AppRoot 'HUMig.exe'))) {
    if (New-HMLauncher) { Out-Console 'Starter HUMig.exe mit Logo erstellt - in Zukunft damit starten (kein Konsolenfenster, an Taskleiste anheftbar).' 'Success' }
    else { Out-Console 'Starter HUMig.exe konnte nicht erstellt werden - Start.cmd verwenden (Details: Einstellungen > Allgemein > HUMig.exe neu erstellen).' 'Warning' }
}

[void]$script:Window.ShowDialog()
