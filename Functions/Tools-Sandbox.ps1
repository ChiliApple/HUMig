#Requires -Version 5.1
<#
.SYNOPSIS
    Testinstallation in der Windows Sandbox fuer Pakete der Softwareverteilung: Einrichtung/Aktivierung,
    Spiegeln der Quelle, Start, Fortschritt, Auswertung mit Vorschlag fuer Erkennung/Deinstallation,
    Fensterverwaltung des Sandbox-Fensters und winget-Download.
.DESCRIPTION
    Ablauf: Quelle wird nach %LOCALAPPDATA%\HUMig\Sandbox\<Id>\src gespiegelt (nur bei Aenderung) und
    schreibgeschuetzt als C:\HMSource eingebunden; der Arbeitsordner <Id>\test ist C:\HMTest (beschreibbar).
    In der Sandbox laeuft HMTest.ps1: Abhaengigkeiten, Vorher-Schnappschuss, Installation mit GENAU dem Code
    der Verteilung (install.ps1 aus Get-SwInstallJob), Fenster-/Verknuepfungsbeobachtung, Nachher-Vergleich,
    optional Deinstallationstest, Protokolle, result.json, danach Herunterfahren (ausser "offen lassen").
    winget: neueste Version, Suche, Installer herunterladen (am PC, auf dem HUMig laeuft).
.NOTES
    Wird im UI-Thread geladen (dot-source aus HUMig.ps1). Nutzt Get-SwInstallJob, Get-SwUninstallJob,
    Get-SwPackageSignature und Get-SwPackages aus Tools-Software.ps1.
    Zielmaschine: der PC, auf dem HUMig laeuft (Windows 10/11 Pro, Education oder Enterprise);
    HMTest.ps1 laeuft in der Windows Sandbox unter Windows PowerShell 5.1.
#>

# ----------------------------------------------------------------------------
# Grundlagen
# ----------------------------------------------------------------------------
# nur Prozesse einer laufenden Sandbox (Fenster/Client). WindowsSandboxServer bleibt ab Windows 11 24H2 auch ohne
# offene Sandbox im Hintergrund aktiv und zaehlt daher nicht (sonst gilt die Sandbox dauerhaft als belegt)
$script:HMSandboxProcNames = @('WindowsSandbox', 'WindowsSandboxClient', 'WindowsSandboxRemoteSession')
$script:HMSandboxWatch = @{}   # je Ergebnisdatei: Sandbox schon gesehen / bereits geschlossen
$script:HMSbxWinTimer = $null  # StrictMode: vor dem ersten Lesen setzen
$script:HMSbxWin = $null

function Write-HMSandboxLog([string]$Text, [string]$Level = 'Info') {
    if (Get-Command Out-Console -ErrorAction SilentlyContinue) { try { Out-Console $Text $Level } catch { } }
    else { Write-Verbose $Text }
}

function Get-HMSandboxRoot {
    $base = $env:LOCALAPPDATA
    if (-not $base) { $base = [Environment]::GetFolderPath('LocalApplicationData') }
    $p = Join-Path (Join-Path $base 'HUMig') 'Sandbox'
    if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    return $p
}

# Paket-Id ("setup.msi" bzw. "Ordner\") -> Ordnername ohne Sonderzeichen
function ConvertTo-HMSandboxSafeId([string]$Id) {
    $s = ("$Id".Trim().TrimEnd('\', '/') -replace '[^\w\-\.]', '_').Trim('.', '_')
    if (-not $s) { $s = 'Paket' }
    if ($s.Length -gt 60) {
        $sha = [Security.Cryptography.SHA256]::Create()
        $h = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes("$Id")))).Replace('-', '').Substring(0, 8)
        $s = $s.Substring(0, 51) + '_' + $h
    }
    return $s
}

function Get-HMSandboxValue($Obj, [string]$Name, $Default = '') {
    if ($null -eq $Obj) { return $Default }
    if ($Obj -is [System.Collections.IDictionary]) { if ($Obj.Contains($Name) -and $null -ne $Obj[$Name]) { return $Obj[$Name] }; return $Default }
    $p = $Obj.PSObject.Properties[$Name]
    if ($p -and $null -ne $p.Value) { return $p.Value }
    return $Default
}

function Get-HMSandboxPackagePath($Package) {
    $p = "$(Get-HMSandboxValue $Package 'SrcPath' '')"
    if (-not $p) { $p = "$(Get-HMSandboxValue $Package 'Path' '')" }
    return $p
}

# Installer-Art fuer stille Deinstallationsschalter (aus Get-SwInstallerInfo)
function Get-HMSandboxInstallerType($Package) {
    $fw = "$(Get-HMSandboxValue (Get-HMSandboxValue $Package 'Info' $null) 'Framework' '')"
    if ($fw -match '(?i)^Inno') { return 'Inno Setup' }
    if ($fw -match '(?i)NSIS|Nullsoft') { return 'NSIS' }
    return ''
}

function Get-HMSandboxProcess {
    return @(Get-Process -Name $script:HMSandboxProcNames -ErrorAction SilentlyContinue)
}

function Test-HMSandboxAvailable {
    $win = $env:windir
    if (-not $win) { return $false }
    return (Test-Path -LiteralPath (Join-Path $win 'System32\WindowsSandbox.exe'))
}

function Test-HMSandboxBusy { return [bool](@(Get-HMSandboxProcess).Count) }

# Edition: Home kennt keine Sandbox
function Get-HMSandboxEdition {
    $caption = ''
    try { $caption = "$((Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).Caption)" } catch { }
    return [pscustomobject]@{ Caption = $caption; Supported = -not ($caption -match '(?i)\bHome\b') }
}

# Virtualisierung (nur Hinweis): Hypervisor laeuft schon oder im BIOS/UEFI eingeschaltet
function Get-HMSandboxVirtualization {
    try {
        if ((Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).HypervisorPresent) { return 'aktiv' }
        $cpu = @(Get-CimInstance Win32_Processor -ErrorAction Stop)[0]
        if ($cpu.VirtualizationFirmwareEnabled) { return 'im BIOS/UEFI eingeschaltet' }
        return 'im BIOS/UEFI ausgeschaltet?'
    } catch { return 'unbekannt' }
}

function Enable-HMSandbox {
    $cmd = 'Enable-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM -All -NoRestart; Write-Host ""; Write-Host "Fertig - bitte Windows neu starten." -ForegroundColor Green; Start-Sleep -Seconds 8'
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $cmd
}

# Dialog "Windows Sandbox einrichten" (Edition pruefen, Feature per erhoehtem Prozess aktivieren, Neustart-Hinweis)
function Show-HMSandboxSetup {
    param([object]$Owner = $null)
    $own = $Owner
    if (-not $own) { $own = Get-Variable -Name Window -Scope Script -ValueOnly -ErrorAction SilentlyContinue }
    $ed = Get-HMSandboxEdition
    if (-not $ed.Supported) {
        $msg = "Die Testinstallation laeuft in der Windows Sandbox - die gibt es nicht in '$($ed.Caption)'.`n`nNoetig ist Windows 10/11 Pro, Education oder Enterprise."
        if ($own) { [void][System.Windows.MessageBox]::Show($own, $msg, 'Windows Sandbox', 'OK', 'Warning') } else { [void][System.Windows.MessageBox]::Show($msg, 'Windows Sandbox', 'OK', 'Warning') }
        return
    }
    if (Test-HMSandboxAvailable) {
        $msg = 'Die Windows Sandbox ist bereits eingerichtet.'
        if ($own) { [void][System.Windows.MessageBox]::Show($own, $msg, 'Windows Sandbox', 'OK', 'Information') } else { [void][System.Windows.MessageBox]::Show($msg, 'Windows Sandbox', 'OK', 'Information') }
        return
    }
    $virt = Get-HMSandboxVirtualization
    $x = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Windows Sandbox einrichten" Width="560" SizeToContent="Height" ResizeMode="NoResize" WindowStartupLocation="CenterOwner" Background="#FF1E1E2E" ShowInTaskbar="False">
  <StackPanel Margin="16">
    <TextBlock Text="Testinstallation braucht die Windows Sandbox" Foreground="#FFCBA6F7" FontSize="15" FontWeight="SemiBold" Margin="0,0,0,10"/>
    <TextBlock Foreground="#FFCDD6F4" TextWrapping="Wrap" Margin="0,0,0,10">Die Sandbox ist ein Wegwerf-Windows: das Paket wird dort mit demselben Ablauf wie bei der Verteilung installiert, HUMig liest Erkennung und Deinstallation aus, danach verschwindet alles. Dieser PC bleibt sauber.</TextBlock>
    <TextBlock Text="So geht's" Foreground="#FF89B4FA" FontWeight="SemiBold" Margin="0,0,0,4"/>
    <TextBlock Foreground="#FFCDD6F4" TextWrapping="Wrap" LineHeight="20">1. Unten auf "Sandbox jetzt aktivieren" klicken und die Windows-Abfrage (Administrator) bestaetigen.<LineBreak/>2. Warten, bis das blaue Fenster "Fertig" meldet.<LineBreak/>3. Windows neu starten - danach funktioniert die Testinstallation.</TextBlock>
    <TextBlock x:Name="info" Foreground="#FFA6ADC8" TextWrapping="Wrap" Margin="0,10,0,0"/>
    <TextBlock Foreground="#FFA6ADC8" TextWrapping="Wrap" Margin="0,6,0,0">Voraussetzungen: Windows 10/11 Pro, Education oder Enterprise und eingeschaltete Virtualisierung im BIOS/UEFI. Klappt es nicht: Systemsteuerung &gt; Windows-Features &gt; 'Windows-Sandbox' anhaken.</TextBlock>
    <TextBlock x:Name="err" Foreground="#FFF38BA8" TextWrapping="Wrap" Margin="0,8,0,0"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,14,0,0">
      <Button x:Name="help" Content="Anleitung (Microsoft)" Width="150" Height="28" Background="#FF45475A" Foreground="#FFCDD6F4" Margin="0,0,6,0"/>
      <Button x:Name="ok" Content="Sandbox jetzt aktivieren" Width="170" Height="28" Background="#FFCBA6F7" Foreground="#FF1E1E2E" FontWeight="SemiBold" Margin="0,0,6,0" IsDefault="True"/>
      <Button x:Name="cancel" Content="Schliessen" Width="100" Height="28" Background="#FF45475A" Foreground="#FFCDD6F4" IsCancel="True"/>
    </StackPanel>
  </StackPanel>
</Window>
"@
    $w = [System.Windows.Markup.XamlReader]::Parse($x)
    $icon = Get-Variable -Name AppIcon -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if ($icon) { $w.Icon = $icon }
    if ($own) { try { $w.Owner = $own } catch { $w.WindowStartupLocation = 'CenterScreen' } } else { $w.WindowStartupLocation = 'CenterScreen' }
    if (Get-Command Set-HMWindowScale -ErrorAction SilentlyContinue) { Set-HMWindowScale $w }
    $w.FindName('info').Text = "Dieser PC: $(if ($ed.Caption) { $ed.Caption } else { 'Windows' }) - Virtualisierung: $virt"
    $er = $w.FindName('err')
    $w.FindName('help').Add_Click({
            $u = 'https://learn.microsoft.com/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-install'
            if (Get-Command Open-HMUrl -ErrorAction SilentlyContinue) { Open-HMUrl $u } else { try { Start-Process -FilePath $u } catch { } }
        })
    $w.FindName('ok').Add_Click({
            try {
                Enable-HMSandbox
                Write-HMSandboxLog 'Windows Sandbox wird aktiviert - danach Windows neu starten.' 'Success'
                $w.DialogResult = $true
            } catch { $er.Text = "Nicht gestartet (Administrator-Abfrage abgelehnt?): $($_.Exception.Message)" }
        })
    [void]$w.ShowDialog()
}

# ----------------------------------------------------------------------------
# Quelle spiegeln: Signatur aus Pfad + Get-SwPackageSignature (Groesse/Zeit), unveraendert -> nichts kopieren
# Rueckgabe: @{ Folder; SetupFile; Signature; Copied }
# ----------------------------------------------------------------------------
function Get-HMSandboxSignature($Package) {
    $src = Get-HMSandboxPackagePath $Package
    $isDir = [bool](Get-HMSandboxValue $Package 'IsDir' $false)
    $raw = ''
    if (Get-Command Get-SwPackageSignature -ErrorAction SilentlyContinue) { $raw = "$(Get-SwPackageSignature -Package $Package)" }
    if (-not $raw) {
        $files = if ($isDir) { @(Get-ChildItem -LiteralPath $src -Recurse -File -Force -ErrorAction SilentlyContinue | Sort-Object FullName) } else { @(Get-Item -LiteralPath $src -ErrorAction SilentlyContinue) }
        $base = if ($isDir) { $src.TrimEnd('\', '/') } else { Split-Path $src -Parent }
        $raw = (@(foreach ($f in $files) { '{0}|{1}|{2}' -f $f.FullName.Substring([Math]::Min($base.Length, $f.FullName.Length)), $f.Length, $f.LastWriteTimeUtc.Ticks }) -join "`n")
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes("$src|$isDir|$raw")))).Replace('-', '')
}

# Spiegel aktuell? (Ordner vorhanden und .sig passt)
function Test-HMSandboxMirror([string]$Destination, [string]$Signature) {
    $sigFile = "$($Destination.TrimEnd('\', '/')).sig"
    return ((Test-Path -LiteralPath $Destination) -and (Test-Path -LiteralPath $sigFile) -and "$(Get-Content -LiteralPath $sigFile -Raw)".Trim() -eq $Signature)
}

# Quelle in den Spiegelordner kopieren und .sig schreiben. Ohne andere Skript-Funktionen (laeuft auch im Hintergrund-Runspace).
# $Sync (optional, synchronisierte Hashtable): Done (Bytes) und File werden fortlaufend gesetzt.
function Copy-HMSandboxSource {
    param([Parameter(Mandatory)][string]$Source, [bool]$IsDir = $false, [Parameter(Mandatory)][string]$Destination, [string]$Signature = '', $Sync = $null)
    $sigFile = "$($Destination.TrimEnd('\', '/')).sig"
    if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Recurse -Force }
    if (Test-Path -LiteralPath $sigFile) { Remove-Item -LiteralPath $sigFile -Force }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $it = Get-Item -LiteralPath $Source -Force -ErrorAction Stop
    if ($IsDir) {
        $root = $it.FullName.TrimEnd('\', '/')
        foreach ($d in @(Get-ChildItem -LiteralPath $root -Recurse -Directory -Force -ErrorAction Stop)) {
            New-Item -ItemType Directory -Path (Join-Path $Destination $d.FullName.Substring($root.Length).TrimStart('\', '/')) -Force | Out-Null
        }
        $files = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction Stop)
    } else { $root = ''; $files = @($it) }
    $buf = New-Object byte[] (4MB)
    foreach ($f in $files) {
        $rel = if ($IsDir) { $f.FullName.Substring($root.Length).TrimStart('\', '/') } else { $f.Name }
        $t = Join-Path $Destination $rel
        if ($Sync) { $Sync.File = $f.Name }
        # in Bloecken kopieren -> Fortschritt auch bei grossen Einzeldateien
        $in = [IO.File]::Open($f.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            $out = [IO.File]::Create($t)
            try {
                while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
                    $out.Write($buf, 0, $n)
                    if ($Sync) { $Sync.Done = [long]$Sync.Done + $n }
                }
            } finally { $out.Dispose() }
        } finally { $in.Dispose() }
        try { [IO.File]::SetLastWriteTimeUtc($t, $f.LastWriteTimeUtc) } catch { }
    }
    [IO.File]::WriteAllText($sigFile, $Signature, (New-Object System.Text.UTF8Encoding $false))
}

# mehrere Quellen nacheinander kopieren (Eintraege: Source, IsDir, Destination, Signature)
function Copy-HMSandboxPlan {
    param([object[]]$Items, $Sync = $null)
    foreach ($i in @($Items | Where-Object { $_ })) { Copy-HMSandboxSource -Source "$($i.Source)" -IsDir ([bool]$i.IsDir) -Destination "$($i.Destination)" -Signature "$($i.Signature)" -Sync $Sync }
    return $true
}

function Sync-HMSandboxSource {
    param([Parameter(Mandatory)]$Package, [Parameter(Mandatory)][string]$Destination)
    $src = Get-HMSandboxPackagePath $Package
    if (-not $src -or -not (Test-Path -LiteralPath $src)) { throw "Paketquelle nicht gefunden: $src" }
    $isDir = [bool](Get-HMSandboxValue $Package 'IsDir' $false)
    $setup = if ($isDir) { "$(Get-HMSandboxValue (Get-HMSandboxValue $Package 'Settings' $null) 'Installer' '')" } else { Split-Path $src -Leaf }
    $sig = Get-HMSandboxSignature $Package
    if (Test-HMSandboxMirror $Destination $sig) {
        return [pscustomobject]@{ Folder = $Destination; SetupFile = $setup; Signature = $sig; Copied = $false }
    }
    Copy-HMSandboxSource -Source $src -IsDir $isDir -Destination $Destination -Signature $sig
    return [pscustomobject]@{ Folder = $Destination; SetupFile = $setup; Signature = $sig; Copied = $true }
}

# Spiegelordner eines Pakets: %LOCALAPPDATA%\HUMig\Sandbox\<sichere Id>\src
function Get-HMSandboxSourceDir($Package) {
    $rawId = "$(Get-HMSandboxValue $Package 'Id' '')"
    if (-not $rawId) { $rawId = [IO.Path]::GetFileName((Get-HMSandboxPackagePath $Package).TrimEnd('\', '/')) }
    return (Join-Path (Join-Path (Get-HMSandboxRoot) (ConvertTo-HMSandboxSafeId $rawId)) 'src')
}

# Abhaengigkeiten des Pakets (aus Settings.DependsOn und Get-SwPackages) -> @{ Packages; Missing }
function Get-HMSandboxDependencyList($Package, $Settings) {
    if (@(Get-HMSandboxValue $Settings 'DependsOn' @()).Count -and (Get-Command Get-SwPackages -ErrorAction SilentlyContinue)) {
        return (Resolve-HMSandboxDependencies -Settings $Settings -AllPackages @(Get-SwPackages) -SelfId "$(Get-HMSandboxValue $Package 'Id' '')")
    }
    return [pscustomobject]@{ Packages = @(); Missing = @() }
}

# Was muss vor dem Start noch gespiegelt werden (Paket + Abhaengigkeiten)? Liste @{ Name; Source; IsDir; Destination; Signature; Bytes }
# Leer = alles aktuell, Start-HMSandboxTest kopiert dann nichts.
function Get-HMSandboxSyncPlan {
    param([Parameter(Mandatory)]$Package, $Settings = $null, [object[]]$Dependencies = $null)
    if (-not $Settings) { $Settings = Get-HMSandboxValue $Package 'Settings' $null }
    if ($null -eq $Dependencies) { $Dependencies = @((Get-HMSandboxDependencyList $Package $Settings).Packages) }
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($p in @(@($Package) + @($Dependencies) | Where-Object { $_ })) {
        $src = Get-HMSandboxPackagePath $p
        if (-not $src -or -not (Test-Path -LiteralPath $src)) { continue }   # meldet Start-HMSandboxTest
        $dest = Get-HMSandboxSourceDir $p
        $sig = Get-HMSandboxSignature $p
        if (Test-HMSandboxMirror $dest $sig) { continue }
        $isDir = [bool](Get-HMSandboxValue $p 'IsDir' $false)
        $bytes = 0L
        if ($isDir) { $bytes = [long](@(Get-ChildItem -LiteralPath $src -Recurse -File -Force -ErrorAction SilentlyContinue) | Measure-Object Length -Sum).Sum }
        else { $fi = Get-Item -LiteralPath $src -Force -ErrorAction SilentlyContinue; if ($fi) { $bytes = [long]$fi.Length } }
        $out.Add([pscustomobject]@{ Name = "$(Get-HMSandboxValue (Get-HMSandboxValue $p 'Settings' $null) 'Name' (Get-HMSandboxValue $p 'Id' ''))"; Source = $src; IsDir = $isDir; Destination = $dest; Signature = $sig; Bytes = $bytes })
    }
    return $out.ToArray()
}

function New-HMSandboxSyncState([object[]]$Plan) {
    $total = 0L; foreach ($i in @($Plan | Where-Object { $_ })) { $total += [long]$i.Bytes }
    return [hashtable]::Synchronized(@{ Total = $total; Done = 0L; File = ''; Started = (Get-Date) })
}

# Fortschrittstext zum Kopieren, z. B. "120 von 800 MB (0:35)"
function Get-HMSandboxSyncText($Sync, [datetime]$Now = (Get-Date)) {
    if (-not $Sync) { return '' }
    $secs = [int]($Now - [datetime]$Sync.Started).TotalSeconds; if ($secs -lt 0) { $secs = 0 }
    $clock = "$([int][Math]::Floor($secs / 60)):$('{0:D2}' -f ($secs % 60))"
    $done = [Math]::Round([double]$Sync.Done / 1MB, 0); $tot = [Math]::Round([double]$Sync.Total / 1MB, 0)
    return "$done von $tot MB ($clock)$(if ("$($Sync.File)") { " - $($Sync.File)" })"
}

# Spiegeln im Hintergrund (Fenster bleibt bedienbar). OnComplete: param($result, $state) - Ergebnis mit ConvertTo-HMAsyncResult lesen.
function Start-HMSandboxSync {
    param([Parameter(Mandatory)][object[]]$Plan, $Sync = $null, [scriptblock]$OnComplete = $null, $State = $null, [switch]$NoAsync)
    if (-not $Sync) { $Sync = New-HMSandboxSyncState $Plan }
    $items = @($Plan | Where-Object { $_ } | ForEach-Object { @{ Source = "$($_.Source)"; IsDir = [bool]$_.IsDir; Destination = "$($_.Destination)"; Signature = "$($_.Signature)" } })
    return (Invoke-HMSandboxAsync -Command 'Copy-HMSandboxPlan' -Arguments @{ Items = $items; Sync = $Sync } -Functions @('Copy-HMSandboxSource', 'Copy-HMSandboxPlan') `
            -OnComplete $OnComplete -State $State -TimeoutSec 7200 -BusyText 'Paket fuer die Sandbox kopieren' -NoAsync:$NoAsync)
}

# ----------------------------------------------------------------------------
# Hintergrund-Ausfuehrung: Skript-Funktionen gibt es im Runspace nicht -> als Text mitgeben
# ----------------------------------------------------------------------------
function Get-HMSandboxFunctionText([string[]]$Names) {
    $t = foreach ($n in @($Names | Where-Object { $_ })) { "function $n {`r`n$((Get-Item "function:$n").ScriptBlock.ToString().Trim())`r`n}" }
    return (@($t) -join "`r`n`r`n")
}

$script:HMAsyncRunner = {
    param($fnText, $cmd, $argTable)
    try {
        . ([scriptblock]::Create($fnText))
        $v = & $cmd @argTable
        @{ Ok = $true; Value = @($v); Error = '' }
    } catch { @{ Ok = $false; Value = $null; Error = "$($_.Exception.Message)" } }
}

# Ergebnis von Invoke-HMSandboxAsync vereinheitlichen -> @{ Ok; Value; Error } (auch "FEHLER: ..." von Invoke-AsyncCommand)
function ConvertTo-HMAsyncResult($Result) {
    if ($null -eq $Result) { return [pscustomobject]@{ Ok = $false; Value = @(); Error = 'keine Antwort' } }
    $ok = Get-HMSandboxValue $Result 'Ok' $null
    if ($null -ne $ok) { return [pscustomobject]@{ Ok = [bool]$ok; Value = @(Get-HMSandboxValue $Result 'Value' @()); Error = "$(Get-HMSandboxValue $Result 'Error' '')" } }
    $s = "$Result"
    if ($s -match '^FEHLER:\s*(.*)$') { return [pscustomobject]@{ Ok = $false; Value = @(); Error = $Matches[1] } }
    return [pscustomobject]@{ Ok = $true; Value = @($Result); Error = '' }
}

# $Command mit $Arguments im Hintergrund (RunspacePool ueber Invoke-AsyncCommand); ohne Pool direkt (Warte-Cursor).
# Rueckgabe: $true = laeuft im Hintergrund, $false = bereits fertig (OnComplete wurde schon aufgerufen)
function Invoke-HMSandboxAsync {
    param([Parameter(Mandatory)][string]$Command, [hashtable]$Arguments = @{}, [string[]]$Functions = @(), [string]$Prelude = '',
        [scriptblock]$OnComplete = $null, $State = $null, [int]$TimeoutSec = 600, [string]$BusyText = '', [switch]$NoAsync)
    if (-not $NoAsync -and $script:RunspacePool -and (Get-Command Invoke-AsyncCommand -ErrorAction SilentlyContinue)) {
        $fnText = "$Prelude`r`n$(Get-HMSandboxFunctionText $Functions)"
        Invoke-AsyncCommand -ScriptBlock $script:HMAsyncRunner -ArgumentList @($fnText, $Command, $Arguments) -OnComplete $OnComplete -State $State -TimeoutSec $TimeoutSec -BusyText $BusyText
        return $true
    }
    $r = $null
    try { [System.Windows.Input.Mouse]::OverrideCursor = [System.Windows.Input.Cursors]::Wait } catch { }
    try { $v = & $Command @Arguments; $r = @{ Ok = $true; Value = @($v); Error = '' } }
    catch { $r = @{ Ok = $false; Value = $null; Error = "$($_.Exception.Message)" } }
    finally { try { [System.Windows.Input.Mouse]::OverrideCursor = $null } catch { } }
    if ($OnComplete) { & $OnComplete $r $State }
    return $false
}

# Abhaengigkeiten (DependsOn = Paket-Ids) in Installationsreihenfolge, ohne Schleifen
function Resolve-HMSandboxDependencies($Settings, [object[]]$AllPackages, [string]$SelfId = '') {
    $byId = @{}
    foreach ($p in @($AllPackages)) { if ($p) { $byId["$($p.Id)"] = $p } }
    $order = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    if ($SelfId) { $seen[$SelfId] = $true }
    $missing = New-Object System.Collections.Generic.List[string]
    $visit = $null
    $visit = {
        param($s)
        foreach ($d in @(Get-HMSandboxValue $s 'DependsOn' @())) {
            $id = "$d".Trim()
            if (-not $id -or $seen.ContainsKey($id)) { continue }
            $seen[$id] = $true
            if (-not $byId.ContainsKey($id)) { $missing.Add($id); continue }
            $dp = $byId[$id]
            & $visit (Get-HMSandboxValue $dp 'Settings' $null)
            $order.Add($dp)
        }
    }
    & $visit $Settings
    return [pscustomobject]@{ Packages = $order.ToArray(); Missing = $missing.ToArray() }
}

# ----------------------------------------------------------------------------
# Auswertung: Deinstallationsbefehl still machen, Uninstall-Eintrag waehlen und umsetzen
# (werden auch in die Sandbox mitgegeben - daher param()-Bloecke und nur PS 5.1)
# ----------------------------------------------------------------------------
function Add-HMSilentUninstall {
    param([string]$Cmd, [string]$InstallerType = '')
    $c = "$Cmd".Trim()
    if (-not $c -or $c -match '(?i)msiexec|^cmd(\.exe)?\s+/c\s|^powershell') { return $c }
    $inno = $c -match '(?i)unins\d{3}\.exe'
    # Schalter auch direkt vor einem schliessenden Anfuehrungszeichen ("...uninst.exe /S")
    if (-not $inno -and $c -match '(?i)(^|\s)(/S|/silent|/verysilent|/quiet|/qn|--silent|-s)(\s|"|$)') { return $c }
    if ($c.StartsWith('"')) {
        $q = $c.IndexOf('"', 1)
        if ($q -lt 0) { return $c }
        $exe = $c.Substring(1, $q - 1); $rest = $c.Substring($q + 1).Trim()
    } else {
        $m = [regex]::Match($c, '(?i)^(.+?\.exe)(.*)$')
        if (-not $m.Success) { return $c }
        $exe = $m.Groups[1].Value.Trim(); $rest = $m.Groups[2].Value.Trim()
    }
    $leaf = ($exe -split '[\\/]')[-1]
    # Inno-Deinstaller: /SILENT zeigt Fortschritt und Rueckfragen -> immer /VERYSILENT /SUPPRESSMSGBOXES /NORESTART
    if ($inno) { $rest = ($rest -replace '(?i)(^|\s)/(VERY)?SILENT\b|(^|\s)/SUPPRESSMSGBOXES\b|(^|\s)/NORESTART\b', ' ').Trim() }
    $sw = ''
    if ($leaf -match '(?i)^unins\d{3}\.exe$' -or $InstallerType -eq 'Inno Setup') { $sw = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' }
    elseif ($InstallerType -eq 'NSIS' -or $leaf -match '(?i)^(uninst|uninstall|uninstaller)\.exe$') { $sw = '/S' }
    if (-not $sw) { return $c }
    return ("`"$exe`" $rest $sw" -replace '\s+', ' ').Trim()
}

function ConvertFrom-HMSandboxEntry {
    param($Entry, [string]$InstallerType = '')
    $key = "$($Entry.Key)"
    $is32 = $key -match '\\WOW6432Node\\'
    $un = "$($Entry.QuietUninstallString)"
    if (-not $un) { $un = "$($Entry.UninstallString)" }
    if ($un -match '(?i)msiexec(\.exe)?\s+/[ix]\s*(\{[0-9A-F-]{36}\})') { $un = "msiexec /x $($Matches[2]) /qn /norestart" }
    elseif ($un) {
        $un = Add-HMSilentUninstall $un $InstallerType
        # laufende App vorher beenden (sonst fragt der Deinstaller nach) - Programm aus DisplayIcon, aber nur wenn es
        # im Installationsordner bzw. neben dem Deinstaller liegt, nicht unter Windows und kein System-/Browser-Prozess
        $icoPath = if ($Entry.PSObject.Properties['DisplayIcon']) { ("$($Entry.DisplayIcon)" -replace ',\s*-?\d+\s*$', '').Trim().Trim('"') } else { '' }
        $ico = ($icoPath -split '[\\/]')[-1]
        $raw = "$($Entry.QuietUninstallString)"; if (-not $raw) { $raw = "$($Entry.UninstallString)" }
        $raw = $raw.Trim()
        $unExe = if ($raw.StartsWith('"')) { $q = $raw.IndexOf('"', 1); if ($q -gt 1) { $raw.Substring(1, $q - 1) } else { '' } } elseif ($raw -match '(?i)^(.+?\.exe)') { $Matches[1] } else { '' }
        $dirs = @(("$($Entry.InstallLocation)".Trim().Trim('"')), $(if ($unExe -match '[\\/]') { $unExe -replace '[\\/][^\\/]*$', '' } else { '' })) | Where-Object { $_ -match '^[A-Za-z]:\\.' -or $_ -match '^\\\\' }
        $under = $false
        foreach ($d in $dirs) { if ($icoPath.StartsWith($d.TrimEnd('\', '/') + '\', [StringComparison]::OrdinalIgnoreCase)) { $under = $true } }
        $win = "$env:windir".TrimEnd('\'); if (-not $win) { $win = 'C:\Windows' }
        $inWin = $icoPath.StartsWith($win + '\', [StringComparison]::OrdinalIgnoreCase) -or $icoPath -match '(?i)^[A-Za-z]:\\Windows\\'
        $block = '(?i)^(explorer|cmd|powershell|powershell_ise|pwsh|conhost|svchost|java|javaw|javaws|msiexec|rundll32|dllhost|wscript|cscript|mshta|taskhostw|sihost|runtimebroker|chrome|msedge|msedgewebview2|firefox|iexplore|opera|brave|teams|ms-teams|outlook|winword|excel|powerpnt|onedrive|searchhost|searchapp|ctfmon|dwm|lsass|services|winlogon|csrss|smss|spoolsv|regsvr32|wmiprvse|python|pythonw|node|dotnet)\.exe$'
        if ($under -and -not $inWin -and $ico -match '(?i)^[^"&|<>]+\.exe$' -and $ico -notmatch '(?i)^unins|uninst' -and $ico -notmatch $block) { $un = "cmd.exe /c `"taskkill /f /im `"$ico`" >nul 2>&1 & $un`"" }
    }
    $leafKey = ($key -split '\\')[-1]
    $pc = if ($leafKey -match '^\{[0-9A-Fa-f-]{36}\}$') { $leafKey.ToUpper() } else { '' }
    $psKey = $key -replace '^HKEY_LOCAL_MACHINE\\', 'HKLM:\' -replace '^HKEY_CURRENT_USER\\', 'HKCU:\'
    # Name fuer DetectName: Version und Klammerzusatz am Ende weg, dann * (Platzhalter)
    $dn = "$($Entry.DisplayName)".Trim()
    $ver = "$($Entry.DisplayVersion)".Trim()
    $n = $dn
    # Version nur als ganzes Wort entfernen (nicht mitten in "App1" o. ae.)
    if ($ver) {
        $vm = [regex]::Match($n, '(?i)(?<![\p{L}\p{N}.])v?' + [regex]::Escape($ver) + '(?![\p{L}\p{N}])')
        if ($vm.Success) { $n = $n.Substring(0, $vm.Index).Trim() }
    }
    $n2 = ($n -replace '\s*\([^)]*\)\s*$', '').Trim()
    if ($n2) { $n = $n2 }
    # Versionsangabe im Namen (auch abweichend von DisplayVersion, z. B. "7-Zip 23.01" bei 23.01.00.0)
    $n2 = ($n -replace '\s+v?\d+(\.\d+)+\S*$', '').Trim()
    if ($n2) { $n = $n2 }
    $n = ($n -replace '[\s\-_,]+v?$', '').Trim()
    if (-not $n) { $n = $dn }
    $detName = if ($n) { [System.Management.Automation.WildcardPattern]::Escape($n) + '*' } else { '' }
    $minVer = if ($ver -match '^\d+(\.\d+){1,3}') { $Matches[0] } else { '' }
    $user = ($key -match '^HKEY_CURRENT_USER') -or ("$($Entry.InstallLocation)$($Entry.UninstallString)" -match '(?i)\\Users\\')
    return [pscustomobject]@{
        DisplayName = $dn; Version = $ver; Publisher = "$($Entry.Publisher)"; UninstallCmd = $un
        ProductCode = $pc; DetectKey = $psKey; DetectName = $detName; MinVersion = $minVer
        Is32 = $is32; HKCU = ($key -match '^HKEY_CURRENT_USER'); UserProfile = $user
    }
}

# Aus den neuen Uninstall-Eintraegen den passenden waehlen (Name aehnlich, sonst der mit Deinstallationsbefehl;
# Laufzeitbibliotheken/Redistributables abgewertet, Windows-/Office-Begleiter wie Edge/WebView2 deutlich abgewertet;
# nur in der Version geaenderte Eintraege (Changed) nie, wenn es einen wirklich neuen gibt)
function Select-HMSandboxEntry {
    param([object[]]$Entries, [string]$AppName = '')
    $list = @($Entries | Where-Object { $_ -and "$($_.DisplayName)" })
    if (-not $list.Count) { return $null }
    $fresh = @($list | Where-Object { -not ($_.PSObject.Properties['Changed'] -and $_.Changed -eq $true) })
    if ($fresh.Count) { $list = $fresh }
    $words = @(("$AppName" -split '[^\p{L}\p{N}]+') | Where-Object { $_.Length -ge 3 })
    $scored = foreach ($e in $list) {
        $n = 0; $hit = 0
        foreach ($w in $words) { if ("$($e.DisplayName)" -match [regex]::Escape($w)) { $n += 2; $hit++ } }
        if ("$($e.QuietUninstallString)$($e.UninstallString)") { $n += 1 }
        if ("$($e.DisplayName)" -match '(?i)redistributable|runtime|update for|webview2|\.net (desktop )?runtime') { $n -= 3 }
        # Begleiter, die Windows/Setups nebenbei aktualisieren - nur wenn der Paketname nicht ausdruecklich passt
        if (-not $hit -and "$($e.DisplayName)" -match '(?i)^Microsoft Edge\b|Edge Update|WebView2|Update Health Tools|Teams Machine-Wide|Teams Meeting Add-in|Microsoft OneDrive|PC Health Check|Microsoft Update Health|GameInput') { $n -= 10 }
        [pscustomobject]@{ E = $e; N = $n }
    }
    return (@($scored | Sort-Object N -Descending)[0].E)
}

# Pfad aus der Sandbox -> mit Umgebungsvariablen (gilt auf jedem PC)
function ConvertTo-HMSandboxEnvPath([string]$Path) {
    $p = "$Path"
    $map = @(
        @('^[A-Za-z]:\\Program Files \(x86\)', '%ProgramFiles(x86)%'),
        @('^[A-Za-z]:\\Program Files', '%ProgramFiles%'),
        @('^[A-Za-z]:\\ProgramData', '%ProgramData%'),
        @('^[A-Za-z]:\\Users\\[^\\]+\\AppData\\Local', '%LOCALAPPDATA%'),
        @('^[A-Za-z]:\\Users\\[^\\]+\\AppData\\Roaming', '%APPDATA%'),
        @('^[A-Za-z]:\\Users\\Public', '%PUBLIC%')
    )
    foreach ($m in $map) { if ($p -match $m[0]) { return ($p -replace $m[0], $m[1].Replace('$', '$$')) } }
    return $p
}

# ----------------------------------------------------------------------------
# Skript in der Sandbox (Windows PowerShell 5.1). #HM:FUNCTIONS# wird durch die Auswerte-Funktionen ersetzt.
# ----------------------------------------------------------------------------
$script:HMSandboxScriptBody = @'
$ErrorActionPreference = 'Continue'
$T = 'C:\HMTest'
$result = [ordered]@{
    Version = 1; Started = (Get-Date).ToString('s'); Finished = ''; ExitCode = $null; InstallStatus = ''; InstallText = ''; Seconds = 0
    NewEntries = @(); NewFolders = @(); UserFolders = @(); SelectedKey = ''; DesktopLinks = @(); DesktopLinksLeft = @()
    InstallWindows = @(); UninstallWindows = @(); Deps = @()
    UninstallTested = $false; UninstallSource = ''; UninstallCmd = ''; UninstallExitCode = $null; UninstallStatus = ''; UninstallText = ''; UninstallRemoved = $null
    InstallLog = ''; UninstallLog = ''; Error = ''
}
function Set-Phase([string]$Text) { try { [IO.File]::WriteAllText("$T\status.txt", $Text, (New-Object System.Text.UTF8Encoding $false)) } catch { } }
function Save-Result {
    $result.Finished = (Get-Date).ToString('s')
    # erst vollstaendig schreiben, dann umbenennen (HUMig liest sonst evtl. eine halbe Datei)
    $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$T\result.tmp" -Encoding UTF8
    Move-Item -LiteralPath "$T\result.tmp" -Destination "$T\result.json" -Force
}
$cfg = $null
try {
    $cfg = Get-Content -LiteralPath "$T\config.json" -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if (-not $cfg) { throw 'leer' }
} catch {
    # ohne Auftrag kein Test - Fehler an HUMig melden (HUMig schliesst die Sandbox)
    $result.Error = "config.json nicht lesbar: $($_.Exception.Message)"
    Save-Result
    Set-Phase 'Fertig'
    Write-Host $result.Error -ForegroundColor Red
    return
}

#HM:FUNCTIONS#

function Get-Snap {
    $l = @()
    foreach ($p in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall') {
        if (-not (Test-Path $p)) { continue }
        foreach ($k in Get-ChildItem $p -ErrorAction SilentlyContinue) {
            $v = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
            $l += [pscustomobject]@{ Key = $k.Name; DisplayName = "$($v.DisplayName)"; DisplayVersion = "$($v.DisplayVersion)"; Publisher = "$($v.Publisher)"
                UninstallString = "$($v.UninstallString)"; QuietUninstallString = "$($v.QuietUninstallString)"; InstallLocation = "$($v.InstallLocation)"; DisplayIcon = "$($v.DisplayIcon)" }
        }
    }
    $l
}
function Get-Dirs { @(Get-ChildItem $env:ProgramFiles, ${env:ProgramFiles(x86)}, "$env:ProgramData" -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }) }
# Profil-Installation: neue Ordner in AppData (Local\Programs zaehlt als Installation ins Benutzerprofil)
function Get-UserDirs {
    @(Get-ChildItem "$env:LOCALAPPDATA\Programs", $env:APPDATA, $env:LOCALAPPDATA -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch '^(Microsoft|Packages|Temp|PowerShell|D3DSCache|ConnectedDevicesPlatform|Programs|Comms|PeerDistRepub|Publishers|VirtualStore|CrashDumps)$' } | ForEach-Object { $_.FullName })
}

# Fenstergroesse pruefen: Inno/Delphi-Setups haben auch bei /VERYSILENT ein unsichtbares 0x0-Hauptfenster
try {
    Add-Type -Namespace HMSbx -Name Win -MemberDefinition @"
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
"@ -ErrorAction Stop
    $script:CanRect = $true
} catch { $script:CanRect = $false }
$script:LastRect = ''
function Test-RealWindow([IntPtr]$H) {
    if (-not $script:CanRect) { return $true }
    if (-not [HMSbx.Win]::IsWindowVisible($H)) { return $false }
    $r = New-Object HMSbx.Win+RECT
    if (-not [HMSbx.Win]::GetWindowRect($H, [ref]$r)) { return $true }
    $script:LastRect = "$($r.Right - $r.Left)x$($r.Bottom - $r.Top) @ $($r.Left),$($r.Top)"
    # zu klein oder ausserhalb des Bildschirms (z. B. -32000) -> kein echtes Fenster
    return (($r.Right - $r.Left) -ge 80 -and ($r.Bottom - $r.Top) -ge 40 -and $r.Right -gt 0 -and $r.Bottom -gt 0 -and $r.Left -gt -10000 -and $r.Top -gt -10000)
}
$script:SkipProc = '^(explorer|conhost|cmd|powershell|ShellExperienceHost|SearchHost|SearchApp|StartMenuExperienceHost|TextInputHost|ApplicationFrameHost|SystemSettings|LockApp)$'
$script:LnkDirs = @("$env:PUBLIC\Desktop", [Environment]::GetFolderPath('Desktop'))
$script:LnkBefore = @()
$script:LinksSeen = @{}
$script:Windows = @()
# einmal nachsehen: neue sichtbare Fenster und neue Desktop-Verknuepfungen
function Watch-Step($Base, $Seen) {
    foreach ($w in @(Get-Process | Where-Object { $Base -notcontains $_.Id -and $_.MainWindowHandle -ne [IntPtr]::Zero -and $_.MainWindowTitle -and $_.ProcessName -notmatch $script:SkipProc })) {
        $script:LastRect = ''
        if (-not (Test-RealWindow $w.MainWindowHandle)) { continue }
        $Seen["$($w.ProcessName): $($w.MainWindowTitle) [$($script:LastRect)]"] = $true
    }
    foreach ($l in @(Get-ChildItem -Path $script:LnkDirs -Filter *.lnk -Force -ErrorAction SilentlyContinue)) { if ($script:LnkBefore -notcontains $l.FullName) { $script:LinksSeen[$l.Name] = $true } }
}

# Parameter eines Verteil-Skripts nach Namen belegen (nur die, die es kennt)
function Get-ScriptArgs([string]$File, $Values) {
    $e = $null; $t = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($File, [ref]$t, [ref]$e)
    $names = @()
    if ($ast.ParamBlock) { $names = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) }
    if (-not $names.Count) { return @($Values.Values) }
    $h = @{}
    foreach ($k in $Values.Keys) { if ($names -contains $k) { $h[$k] = $Values[$k] } }
    return $h
}

# Verteil-Skript (install.ps1/uninstall.ps1) im eigenen Prozess starten; waehrenddessen Fenster/Verknuepfungen beobachten
function Invoke-PkgScript([string]$File, $ScriptArgs, [int]$Minutes, [string]$Tag) {
    New-Item -ItemType Directory -Path "$T\logs" -Force | Out-Null
    $base = @(Get-Process | ForEach-Object { $_.Id })
    $seen = @{}
    $job = Start-Job -ScriptBlock {
        param($f, $a)
        $ErrorActionPreference = 'Continue'
        $sb = [scriptblock]::Create([IO.File]::ReadAllText($f))
        if ($a -is [System.Collections.IDictionary]) { & $sb @a } else { $l = @($a); & $sb @l }
    } -ArgumentList $File, $ScriptArgs
    $end = (Get-Date).AddMinutes($Minutes)
    $timedOut = $false
    while ($job.State -eq 'Running' -or $job.State -eq 'NotStarted') {
        Watch-Step $base $seen
        if ((Get-Date) -gt $end) { $timedOut = $true; try { Stop-Job -Job $job } catch { }; break }
        Start-Sleep -Milliseconds 700
    }
    $je = $null
    $lines = @(Receive-Job -Job $job -ErrorAction SilentlyContinue -ErrorVariable je | ForEach-Object { "$_" })
    try { Remove-Job -Job $job -Force } catch { }
    $txt = @($lines) + @($je | Where-Object { $_ } | ForEach-Object { "FEHLERAUSGABE: $_" })
    try { Set-Content -LiteralPath "$T\logs\$Tag-ausgabe.txt" -Value $txt -Encoding UTF8 } catch { }
    $script:Windows = @($seen.Keys)
    return [pscustomobject]@{ Lines = $lines; TimedOut = $timedOut }
}

# Rueckmeldung der Verteil-Skripte: Zeilen "OK|...", "SKIP|...", "WARN|...", "FEHLER|..." (auch mit "RES:<Name>|" davor)
function Get-PkgStatus($Lines, [bool]$TimedOut, [int]$Minutes) {
    $st = ''; $txt = ''
    foreach ($l in @($Lines)) { if ("$l" -match '^\s*(?:RES:[^|]*\|)?(OK|SKIP|WARN|FEHLER)\|(.*)$') { $st = $Matches[1]; $txt = $Matches[2].Trim() } }
    if ($TimedOut) { return [pscustomobject]@{ Status = 'FEHLER'; Text = "Zeitlimit $Minutes min der Sandbox erreicht - abgebrochen"; Code = -999 } }
    if (-not $st) { return [pscustomobject]@{ Status = 'FEHLER'; Text = 'Keine Rueckmeldung: ' + ((@($Lines) | Select-Object -Last 3) -join ' / '); Code = -1 } }
    $code = $null
    if ($txt -match '(?i)\bTimeout\b') { $code = -999 }
    elseif ($txt -match 'ExitCode (-?\d+)') { $code = [int]$Matches[1] }
    elseif ($st -eq 'OK' -or $st -eq 'SKIP') { $code = 0 }
    else { $code = -1 }
    return [pscustomobject]@{ Status = $st; Text = $txt; Code = $code }
}

# Befehl direkt ausfuehren (Deinstallation aus dem neuen Eintrag); Ausgabe nach logs\<Tag>-ausgabe.txt, bei msiexec ein ausfuehrliches MSI-Protokoll
function Invoke-Cmd([string]$Line, [int]$Minutes, [string]$Tag) {
    New-Item -ItemType Directory -Path "$T\logs" -Force | Out-Null
    $run = $Line
    if ($run -match '(?i)\bmsiexec(\.exe)?\b' -and $run -notmatch '(?i)\s/l[\*a-z+!]*\s') { $run += " /l*v `"$T\logs\$Tag-msi.log`"" }
    # cmd.exe liest Batch-Dateien in der OEM-Codepage (Umlaute in Pfaden)
    $oem = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
    [IO.File]::WriteAllText("$T\__run.cmd", "@echo off`r`n$run > `"$T\logs\$Tag-ausgabe.txt`" 2>&1`r`nexit /b %errorlevel%`r`n", $oem)
    $base = @(Get-Process | ForEach-Object { $_.Id })
    $seen = @{}
    $p = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', "$T\__run.cmd" -WorkingDirectory 'C:\HMInstall' -PassThru -WindowStyle Hidden
    $end = (Get-Date).AddMinutes($Minutes)
    while (-not $p.HasExited) {
        Watch-Step $base $seen
        if ((Get-Date) -gt $end) { try { $p.Kill() } catch { }; $script:Windows = @($seen.Keys); return -999 }
        Start-Sleep -Milliseconds 700
    }
    $script:Windows = @($seen.Keys)
    return $p.ExitCode
}

# MSI-Protokoll der Verteilung (C:\Windows\Temp\HU_SW*.log o. ae.) in den logs-Ordner holen
function Copy-MsiLog([datetime]$Since, [string]$Tag, [string]$Text) {
    $f = $null
    if ("$Text" -match 'Log: ([^|]+?\.log)') { $f = $Matches[1].Trim() }
    if (-not $f -or -not (Test-Path -LiteralPath $f)) {
        $x = Get-ChildItem -LiteralPath "$env:windir\Temp" -Filter 'HU_SW*.log' -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $Since } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($x) { $f = $x.FullName }
    }
    if ($f -and (Test-Path -LiteralPath $f)) { try { Copy-Item -LiteralPath $f -Destination "$T\logs\$Tag-msi.log" -Force } catch { } }
}

# Protokolle seit $Since einsammeln: Ausgabe, MSI-Protokoll (Fehlerzeilen), neue Log-Dateien in TEMP, MSI-Ereignisse
function Get-LogText([datetime]$Since, [string]$Tag) {
    $parts = New-Object System.Collections.Generic.List[string]
    $out = "$T\logs\$Tag-ausgabe.txt"
    if ((Test-Path $out) -and (Get-Item $out).Length) { $parts.Add("[Ausgabe]`r`n" + ((Get-Content $out -Tail 40) -join "`r`n")) }
    $msi = "$T\logs\$Tag-msi.log"
    if (Test-Path $msi) {
        $all = @(Get-Content $msi -ErrorAction SilentlyContinue)
        $hits = @($all | Select-String -Pattern 'Return value 3|Fehler \d{4}|Error \d{4}|error code|CustomAction .* returned actual error' | Select-Object -First 15 | ForEach-Object { $_.Line })
        $parts.Add("[MSI-Protokoll $Tag-msi.log - Fehlerzeilen]`r`n" + $(if ($hits.Count) { $hits -join "`r`n" } else { '(keine Fehlerzeilen)' }) + "`r`n...`r`n" + (($all | Select-Object -Last 15) -join "`r`n"))
    }
    $logs = @(Get-ChildItem -Path $env:TEMP, "$env:windir\Temp" -Recurse -File -Include *.log, *.txt -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -ge $Since -and $_.Length -lt 20MB -and $_.FullName -notmatch '\\HMTest\\' -and $_.Name -notlike 'HU_SW*' } | Sort-Object LastWriteTime -Descending | Select-Object -First 3)
    foreach ($l in $logs) {
        try { Copy-Item -LiteralPath $l.FullName -Destination "$T\logs\$Tag-$($l.Name)" -Force } catch { }
        $parts.Add("[$($l.FullName)]`r`n" + ((Get-Content -LiteralPath $l.FullName -Tail 30 -ErrorAction SilentlyContinue) -join "`r`n"))
    }
    $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'MsiInstaller'; StartTime = $Since } -MaxEvents 8 -ErrorAction SilentlyContinue)
    if ($ev.Count) { $parts.Add("[Ereignisanzeige MsiInstaller]`r`n" + (@($ev | ForEach-Object { "$($_.TimeCreated.ToString('HH:mm:ss')) $($_.Id): $(($_.Message -replace '\s+', ' ').Trim())" }) -join "`r`n")) }
    $t = $parts -join "`r`n`r`n"
    if ($t.Length -gt 12000) { $t = $t.Substring(0, 12000) + "`r`n... (gekuerzt - vollstaendig im Ordner logs)" }
    return $t
}

try {
    $Host.UI.RawUI.WindowTitle = 'HUMig Testinstallation'
    Write-Host "HUMig Testinstallation: $($cfg.AppName)" -ForegroundColor Cyan
    Set-Phase 'Vorbereitung'
    New-Item -ItemType Directory -Path 'C:\HMInstall' -Force | Out-Null
    Copy-Item -Path 'C:\HMSource\*' -Destination 'C:\HMInstall' -Recurse -Force
    # Abhaengigkeiten zuerst - zaehlen nicht zum Vorher/Nachher-Vergleich
    $i = 0
    foreach ($d in @($cfg.Deps)) {
        if (-not $d) { continue }
        $i++
        Set-Phase "Abhaengigkeit $i - $($d.Name)"
        Write-Host "Abhaengigkeit: $($d.Name)" -ForegroundColor Yellow
        $dir = "C:\HMDep$i"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Copy-Item -Path "$($d.Source)\*" -Destination $dir -Recurse -Force
        $tm = [int]$d.TimeoutMin; if ($tm -lt 1) { $tm = 30 }
        $f = "$T\$($d.Script)"
        # wie bei der Verteilung: schon vorhandene Abhaengigkeit wird uebersprungen (Force aus)
        $r = Invoke-PkgScript $f (Get-ScriptArgs $f ([ordered]@{ Dir = $dir; PkgJson = "$($d.PkgJson)"; Force = $false })) ($tm + 5) "dep$i"
        $s = Get-PkgStatus $r.Lines $r.TimedOut ($tm + 5)
        $result.Deps += [pscustomobject]@{ Name = "$($d.Name)"; Status = $s.Status; Text = $s.Text; ExitCode = $s.Code }
        Write-Host "  $($s.Status): $($s.Text)" -ForegroundColor $(if ($s.Status -eq 'FEHLER') { 'Red' } else { 'Green' })
    }
    $before = @(Get-Snap); $dirsBefore = Get-Dirs; $userBefore = Get-UserDirs
    $script:LnkBefore = @(Get-ChildItem -Path $script:LnkDirs -Filter *.lnk -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    $script:LinksSeen = @{}
    Set-Phase 'Installation'
    Write-Host "Installiere: $($cfg.AppName)" -ForegroundColor Yellow
    $tmo = [int]$cfg.TimeoutMin; if ($tmo -lt 1) { $tmo = 30 }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $t0 = Get-Date
    $f = "$T\install.ps1"
    $r = Invoke-PkgScript $f (Get-ScriptArgs $f ([ordered]@{ Dir = 'C:\HMInstall'; PkgJson = "$($cfg.PkgJson)"; Force = [bool]$cfg.Force })) ($tmo + 5) 'install'
    $s = Get-PkgStatus $r.Lines $r.TimedOut ($tmo + 5)
    $result.ExitCode = $s.Code; $result.InstallStatus = $s.Status; $result.InstallText = $s.Text
    $result.InstallWindows = @($script:Windows)
    $result.Seconds = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
    Copy-MsiLog $t0 'install' $s.Text
    # manche Setups legen Verknuepfungen erst kurz nach dem Ende an
    for ($k = 0; $k -lt 8; $k++) { Watch-Step @() @{}; Start-Sleep -Milliseconds 700 }
    $result.InstallLog = Get-LogText $t0 'install'
    $keys = @($before | ForEach-Object { $_.Key })
    $after = @(Get-Snap)
    $result.NewEntries = @($after | Where-Object { $keys -notcontains $_.Key })
    $changed = @($after | Where-Object { $keys -contains $_.Key } | Where-Object { $kk = $_.Key; $b = $before | Where-Object { $_.Key -eq $kk } | Select-Object -First 1; $b.DisplayVersion -ne $_.DisplayVersion })
    # nur Version geaendert (z. B. Edge-Update nebenbei) - fuer die Auswahl markiert
    foreach ($c in $changed) { $c | Add-Member -NotePropertyName Changed -NotePropertyValue $true -Force }
    $result.NewEntries += $changed
    $result.NewFolders = @(Get-Dirs | Where-Object { $dirsBefore -notcontains $_ })
    $result.UserFolders = @(Get-UserDirs | Where-Object { $userBefore -notcontains $_ })
    $result.DesktopLinks = @($script:LinksSeen.Keys | Sort-Object)
    $result.DesktopLinksLeft = @(Get-ChildItem -Path $script:LnkDirs -Filter *.lnk -Force -ErrorAction SilentlyContinue | Where-Object { $script:LnkBefore -notcontains $_.FullName } | ForEach-Object { $_.Name })
    $sel = Select-HMSandboxEntry -Entries $result.NewEntries -AppName "$($cfg.AppName)"
    if ($sel) { $result.SelectedKey = "$($sel.Key)" }
    Write-Host "$($s.Status): $($s.Text)" -ForegroundColor $(if ($s.Status -eq 'FEHLER') { 'Red' } else { 'Green' })
    Write-Host "Neue Programme: $(@($result.NewEntries).Count)$(if (@($result.DesktopLinks).Count) { ', Desktop-Verknuepfungen: ' + (@($result.DesktopLinks) -join ', ') })" -ForegroundColor Green

    if ($cfg.TestUninstall) {
        Set-Phase 'Deinstallation'
        $t1 = Get-Date
        if ("$($cfg.UninstallScript)") {
            # gleicher Code wie die Deinstallation der Verteilung
            Write-Host "Deinstalliere (wie bei der Verteilung): $($cfg.UninstallCmd)" -ForegroundColor Yellow
            $result.UninstallTested = $true; $result.UninstallSource = 'Einstellungen'; $result.UninstallCmd = "$($cfg.UninstallCmd)"
            $f = "$T\$($cfg.UninstallScript)"
            $utm = [int]$cfg.UninstallTimeoutMin; if ($utm -lt 1) { $utm = 15 }
            $r = Invoke-PkgScript $f (Get-ScriptArgs $f ([ordered]@{ Dir = 'C:\HMInstall'; ArgsJson = "$($cfg.UninstallArgsJson)"; ItemsJson = "$($cfg.UninstallArgsJson)"; PkgJson = "$($cfg.PkgJson)"; Force = $true; TimeoutMin = $utm })) ($utm + 5) 'uninstall'
            $u = Get-PkgStatus $r.Lines $r.TimedOut ($utm + 5)
            $result.UninstallExitCode = $u.Code; $result.UninstallStatus = $u.Status; $result.UninstallText = $u.Text
            Copy-MsiLog $t1 'uninstall' $u.Text
        } elseif ($sel) {
            $conv = ConvertFrom-HMSandboxEntry -Entry $sel -InstallerType "$($cfg.InstallerType)"
            if ($conv.UninstallCmd) {
                Write-Host "Deinstalliere (aus dem neuen Eintrag): $($conv.UninstallCmd)" -ForegroundColor Yellow
                $result.UninstallTested = $true; $result.UninstallSource = 'Eintrag'; $result.UninstallCmd = $conv.UninstallCmd
                $result.UninstallExitCode = Invoke-Cmd $conv.UninstallCmd 15 'uninstall'
                $result.UninstallStatus = $(if ($result.UninstallExitCode -eq -999) { 'FEHLER' } else { 'OK' })
                $result.UninstallText = $(if ($result.UninstallExitCode -eq -999) { 'Zeitlimit 15 min - Deinstaller wartet vermutlich auf Eingabe' } else { "ExitCode $($result.UninstallExitCode)" })
            }
        }
        if ($result.UninstallTested) {
            $result.UninstallWindows = @($script:Windows)
            # manche Deinstaller (NSIS) starten eine Kopie und kehren sofort zurueck -> bis 2 Minuten auf das Entfernen warten
            $check = @(if ($sel) { "$($sel.Key)" } else { @($result.NewEntries | ForEach-Object { "$($_.Key)" }) })
            for ($k = 0; $k -lt 40; $k++) {
                if ($check.Count) {
                    $nowKeys = @(Get-Snap | ForEach-Object { $_.Key })
                    $result.UninstallRemoved = -not @($check | Where-Object { $nowKeys -contains $_ }).Count
                } else {
                    $result.UninstallRemoved = -not @($result.NewFolders | Where-Object { Test-Path -LiteralPath $_ }).Count
                }
                if ($result.UninstallRemoved) { break }
                Start-Sleep -Seconds 3
            }
            $result.UninstallLog = Get-LogText $t1 'uninstall'
            Write-Host "Deinstallation: $(if ($result.UninstallRemoved) { 'entfernt' } else { 'noch vorhanden' }) ($($result.UninstallText))" -ForegroundColor $(if ($result.UninstallRemoved) { 'Green' } else { 'Red' })
        } else { Write-Host 'Deinstallation nicht getestet (kein Befehl und kein neuer Eintrag).' -ForegroundColor Yellow }
    }
} catch { $result.Error = $_.Exception.Message }
Save-Result
Set-Phase 'Fertig'
Write-Host ''
Write-Host 'Fertig - Ergebnis steht in HUMig.' -ForegroundColor Green
# HUMig schliesst die Sandbox von aussen; nur falls das nicht klappt, hier nach 90 s herunterfahren
if (-not $cfg.KeepOpen) { Write-Host 'Sandbox wird von HUMig geschlossen ...'; Start-Sleep -Seconds 90; shutdown.exe /s /t 0 }
else { Write-Host 'Sandbox bleibt offen (zum Nachsehen). Schliessen mit dem X oben rechts.' -ForegroundColor Yellow }
'@

# vollstaendiger Text von HMTest.ps1 (mit den Auswerte-Funktionen)
function Get-HMSandboxScriptText {
    $fn = foreach ($n in 'Add-HMSilentUninstall', 'ConvertFrom-HMSandboxEntry', 'Select-HMSandboxEntry') {
        "function $n {`r`n$((Get-Item "function:$n").ScriptBlock.ToString().Trim())`r`n}"
    }
    return $script:HMSandboxScriptBody.Replace('#HM:FUNCTIONS#', ($fn -join "`r`n`r`n"))
}

# .wsb-Inhalt (XML): Quelle read-only -> C:\HMSource, Arbeitsordner -> C:\HMTest, Abhaengigkeiten -> C:\HMDepSrc<n>
function New-HMSandboxWsb {
    param([Parameter(Mandatory)][string]$SourceFolder, [Parameter(Mandatory)][string]$WorkFolder, [string[]]$DepFolders = @())
    $esc = { param($s) [System.Security.SecurityElement]::Escape("$s") }
    $maps = New-Object System.Collections.Generic.List[string]
    $maps.Add("    <MappedFolder><HostFolder>$(& $esc $SourceFolder)</HostFolder><SandboxFolder>C:\HMSource</SandboxFolder><ReadOnly>true</ReadOnly></MappedFolder>")
    $maps.Add("    <MappedFolder><HostFolder>$(& $esc $WorkFolder)</HostFolder><SandboxFolder>C:\HMTest</SandboxFolder><ReadOnly>false</ReadOnly></MappedFolder>")
    $n = 0
    foreach ($d in @($DepFolders | Where-Object { $_ })) { $n++; $maps.Add("    <MappedFolder><HostFolder>$(& $esc $d)</HostFolder><SandboxFolder>C:\HMDepSrc$n</SandboxFolder><ReadOnly>true</ReadOnly></MappedFolder>") }
    $cmd = 'cmd.exe /c start "HUMig Testinstallation" powershell.exe -NoExit -NoProfile -ExecutionPolicy Bypass -File C:\HMTest\HMTest.ps1'
    return @"
<Configuration>
  <Networking>Enable</Networking>
  <MappedFolders>
$($maps -join "`r`n")
  </MappedFolders>
  <LogonCommand><Command>$(& $esc $cmd)</Command></LogonCommand>
</Configuration>
"@
}

# ----------------------------------------------------------------------------
# Start / Stop / Fortschritt
# ----------------------------------------------------------------------------
# Minuten bis "Timeout" in Get-HMSandboxProgress: Abhaengigkeiten je Zeitlimit+5, Paket Zeitlimit+5,
# Deinstallation Zeitlimit+5, dazu 10 min fuer Start/Puffer; mindestens 50
function Get-HMSandboxDeadlineMin {
    param([int]$TimeoutMin = 30, [int[]]$DepTimeouts = @(), [bool]$TestUninstall = $false, [int]$UninstallTimeoutMin = 15)
    $t = $TimeoutMin; if ($t -lt 1) { $t = 30 }
    $sum = 10 + $t + 5
    foreach ($d in @($DepTimeouts)) { $x = [int]$d; if ($x -lt 1) { $x = 30 }; $sum += $x + 5 }
    if ($TestUninstall) { $u = $UninstallTimeoutMin; if ($u -lt 1) { $u = 15 }; $sum += $u + 5 }
    return [int][Math]::Max(50, $sum)
}

function Start-HMSandboxTest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Package,
        $Settings = $null,
        [switch]$TestUninstall,
        [switch]$KeepOpen,
        [object[]]$Dependencies = $null,   # Pakete, die vorher installiert werden; ohne Angabe aus Settings.DependsOn
        [switch]$NoLaunch                  # nur vorbereiten (Tests)
    )
    if (-not $Settings) { $Settings = Get-HMSandboxValue $Package 'Settings' $null }
    if (-not $NoLaunch) {
        if (-not (Test-HMSandboxAvailable)) { throw 'Windows Sandbox ist nicht aktiviert (Einrichten ueber "Sandbox einrichten").' }
        if (Test-HMSandboxBusy) { throw 'Es laeuft bereits eine Windows Sandbox - bitte zuerst schliessen (nur eine gleichzeitig moeglich).' }
    }
    $rawId = "$(Get-HMSandboxValue $Package 'Id' '')"
    if (-not $rawId) { $rawId = [IO.Path]::GetFileName((Get-HMSandboxPackagePath $Package).TrimEnd('\', '/')) }
    $id = ConvertTo-HMSandboxSafeId $rawId
    $root = Join-Path (Get-HMSandboxRoot) $id
    $src = Sync-HMSandboxSource -Package $Package -Destination (Join-Path $root 'src')
    if ($src.Copied) { Write-HMSandboxLog 'Paket in den lokalen Sandbox-Ordner kopiert' 'Info' }
    $work = Join-Path $root 'test'
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    $bom = New-Object System.Text.UTF8Encoding $true
    $noBom = New-Object System.Text.UTF8Encoding $false

    # Installation: genau der Code der Verteilung
    $job = Get-SwInstallJob -Package $Package -Settings $Settings
    [IO.File]::WriteAllText((Join-Path $work 'install.ps1'), "$(Get-HMSandboxValue $job 'ScriptText' '')", $bom)
    $force = Get-HMSandboxValue $job 'Force' $true

    # Deinstallation: hinterlegter Befehl (bzw. MSI-ProductCode) ueber den Verteil-Code, sonst in der Sandbox aus dem neuen Eintrag
    $unCmd = "$(Get-HMSandboxValue $Settings 'UninstallCmd' '')".Trim()
    $unScript = ''; $unArgs = ''; $unTmo = 15
    if ($TestUninstall) {
        $uj = Get-SwUninstallJob -Package $Package -Settings $Settings
        if ($uj -and "$(Get-HMSandboxValue $uj 'ScriptText' '')") {
            [IO.File]::WriteAllText((Join-Path $work 'uninstall.ps1'), "$(Get-HMSandboxValue $uj 'ScriptText' '')", $bom)
            $unScript = 'uninstall.ps1'; $unArgs = "$(Get-HMSandboxValue $uj 'ArgsJson' '')"
            $unTmo = [int](Get-HMSandboxValue $uj 'TimeoutMin' 15); if ($unTmo -lt 1) { $unTmo = 15 }
            $it = Get-HMSandboxValue $uj 'Item' $null
            if (-not $unCmd -and $it) { $unCmd = "$(Get-HMSandboxValue $it 'Cmd' '')".Trim() }
        }
    }

    # Abhaengigkeiten (eigene Spiegel, werden in der Sandbox zuerst installiert)
    $deps = @(); $depFolders = @(); $missing = @()
    if ($null -eq $Dependencies) {
        $res = Get-HMSandboxDependencyList $Package $Settings
        $Dependencies = $res.Packages; $missing = @($res.Missing)
    }
    $n = 0
    foreach ($dp in @($Dependencies | Where-Object { $_ })) {
        $n++
        $ds = Get-HMSandboxValue $dp 'Settings' $null
        $dsrc = Sync-HMSandboxSource -Package $dp -Destination (Get-HMSandboxSourceDir $dp)
        $dj = Get-SwInstallJob -Package $dp -Settings $ds
        $file = "dep$n-install.ps1"
        [IO.File]::WriteAllText((Join-Path $work $file), "$(Get-HMSandboxValue $dj 'ScriptText' '')", $bom)
        $depFolders += $dsrc.Folder
        $deps += [ordered]@{ Name = "$(Get-HMSandboxValue $ds 'Name' $dp.Id)"; Source = "C:\HMDepSrc$n"; Script = $file; PkgJson = "$(Get-HMSandboxValue $dj 'PkgJson' '')"; TimeoutMin = [int](Get-HMSandboxValue $ds 'TimeoutMin' 30) }
    }
    if ($missing.Count) { Write-HMSandboxLog "Abhaengigkeit nicht gefunden (wird in der Sandbox nicht installiert): $($missing -join ', ')" 'Warning' }

    [IO.File]::WriteAllText((Join-Path $work 'HMTest.ps1'), (Get-HMSandboxScriptText), $bom)
    $cfg = [ordered]@{
        AppName = "$(Get-HMSandboxValue $Settings 'Name' $id)"; InstallerType = (Get-HMSandboxInstallerType $Package)
        PkgJson = "$(Get-HMSandboxValue $job 'PkgJson' '')"; Force = [bool]$force; TimeoutMin = [int](Get-HMSandboxValue $Settings 'TimeoutMin' 30)
        TestUninstall = [bool]$TestUninstall; UninstallCmd = $unCmd; UninstallScript = $unScript; UninstallArgsJson = $unArgs; UninstallTimeoutMin = $unTmo
        KeepOpen = [bool]$KeepOpen; Deps = @($deps)
    }
    [IO.File]::WriteAllText((Join-Path $work 'config.json'), (ConvertTo-Json -InputObject $cfg -Depth 5), $noBom)
    $wsbFile = Join-Path $work 'HUMigTest.wsb'
    [IO.File]::WriteAllText($wsbFile, (New-HMSandboxWsb -SourceFolder $src.Folder -WorkFolder $work -DepFolders $depFolders), $noBom)
    $resultFile = Join-Path $work 'result.json'
    $script:HMSandboxWatch[$resultFile] = @{ Seen = $false }
    if (-not $NoLaunch) {
        Start-Process -FilePath $wsbFile
        Write-HMSandboxLog 'Windows Sandbox gestartet - die Installation laeuft dort sichtbar im eigenen Fenster.' 'Success'
        # Fenster-Lage merken/wiederherstellen, nur im UI-Thread (DispatcherTimer)
        try { if ([System.Windows.Threading.Dispatcher]::FromThread([System.Threading.Thread]::CurrentThread)) { Start-HMSandboxWindowKeeper } } catch { }
    }
    # Zeitlimit fuer die Ueberwachung aus den Zeitlimits in der Sandbox (statt fest 50 min)
    $limit = Get-HMSandboxDeadlineMin -TimeoutMin $cfg.TimeoutMin -DepTimeouts @($deps | ForEach-Object { $_.TimeoutMin }) -TestUninstall ([bool]$TestUninstall) -UninstallTimeoutMin $unTmo
    return @{ ResultFile = $resultFile; WorkDir = $work; Started = (Get-Date); KeepOpen = [bool]$KeepOpen; Signature = $src.Signature; TestUninstall = [bool]$TestUninstall; Id = $id; TimeoutMin = $limit }
}

# Laufende Windows Sandbox von aussen schliessen (ohne Rueckfrage/Fehlermeldung im Sandbox-Fenster).
# Ab Windows 11 24H2 ueber "wsb stop", sonst Sandbox-Prozesse beenden. Laeuft unsichtbar im Hintergrund.
function Stop-HMSandbox {
    $cmd = @'
$ErrorActionPreference = 'SilentlyContinue'
$wsb = Get-Command wsb.exe -ErrorAction SilentlyContinue
if ($wsb) {
    $ids = @([regex]::Matches(((& $wsb.Source list) -join ' '), '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}') | ForEach-Object { $_.Value } | Select-Object -Unique)
    foreach ($i in $ids) { & $wsb.Source stop --id $i | Out-Null }
    Start-Sleep -Seconds 3
}
Get-Process -Name 'WindowsSandboxRemoteSession', 'WindowsSandboxClient', 'WindowsSandbox' -ErrorAction SilentlyContinue | Stop-Process -Force
'@
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
    try { Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $enc -WindowStyle Hidden } catch { }
}

function Read-HMSandboxResult([string]$File) {
    if (-not $File -or -not (Test-Path -LiteralPath $File)) { return $null }
    try { return (Get-Content -LiteralPath $File -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

# Zustand fuer einen DispatcherTimer (alle 3 s): Waiting / Running / Done / Closed / NotStarted / Timeout
# Bei Done schliesst der Aufrufer die Sandbox (Stop-HMSandbox), wenn sie nicht offen bleiben soll.
function Get-HMSandboxProgress {
    param([Parameter(Mandatory)]$Job, [datetime]$Now = (Get-Date))
    $file = "$(Get-HMSandboxValue $Job 'ResultFile' '')"
    $started = Get-HMSandboxValue $Job 'Started' $Now
    if ($started -isnot [datetime]) { try { $started = [datetime]$started } catch { $started = $Now } }
    $secs = [int]($Now - $started).TotalSeconds
    if (-not $script:HMSandboxWatch.ContainsKey($file)) { $script:HMSandboxWatch[$file] = @{ Seen = $false } }
    $w = $script:HMSandboxWatch[$file]
    $phase = ''
    $wd = "$(Get-HMSandboxValue $Job 'WorkDir' '')"
    if ($wd) { $sf = Join-Path $wd 'status.txt'; if (Test-Path -LiteralPath $sf) { try { $phase = "$(Get-Content -LiteralPath $sf -Raw -ErrorAction Stop)".Trim() } catch { } } }
    $mk = { param($s, $r, $t) [pscustomobject]@{ State = $s; Result = $r; Seconds = $secs; Phase = $phase; Text = $t } }
    $res = Read-HMSandboxResult $file
    if ($res) { return (& $mk 'Done' $res 'Testinstallation fertig.') }
    $running = [bool](@(Get-HMSandboxProcess).Count)
    if ($running) { $w.Seen = $true }
    if ($w.Seen -and -not $running) { return (& $mk 'Closed' $null 'Sandbox wurde ohne Ergebnis geschlossen.') }
    if (-not $w.Seen -and $secs -gt 180) { return (& $mk 'NotStarted' $null 'Sandbox startet nicht - laeuft die Virtualisierung? (Task-Manager > Leistung > CPU > Virtualisierung: Aktiviert)') }
    $lim = [int](Get-HMSandboxValue $Job 'TimeoutMin' 50); if ($lim -lt 1) { $lim = 50 }
    if ($secs -gt $lim * 60) { return (& $mk 'Timeout' $null "Abbruch nach $lim Minuten ohne Ergebnis - Sandbox bitte von Hand schliessen.") }
    $clock = "$([int][Math]::Floor($secs / 60)):$('{0:D2}' -f ($secs % 60))"
    if (-not $w.Seen) { return (& $mk 'Waiting' $null "Sandbox startet ($clock) ...") }
    return (& $mk 'Running' $null "Sandbox laeuft ($clock)$(if ($phase) { " - $phase" }) - Installation im Sandbox-Fenster ...")
}

# ----------------------------------------------------------------------------
# Zusammenfassung, Bewertung und Vorschlag fuer die Paket-Einstellungen
# ----------------------------------------------------------------------------
function Get-HMSandboxSummary {
    param([Parameter(Mandatory)]$Result, $Package = $null, $Settings = $null, [string]$WorkDir = '')
    if (-not $Settings -and $Package) { $Settings = Get-HMSandboxValue $Package 'Settings' $null }
    $Res = $Result
    $name = "$(Get-HMSandboxValue $Settings 'Name' '')"
    $noDesk = [bool](Get-HMSandboxValue $Settings 'NoDesktop' $false)
    $curUn = "$(Get-HMSandboxValue $Settings 'UninstallCmd' '')".Trim()
    $itype = if ($Package) { Get-HMSandboxInstallerType $Package } else { '' }
    $lines = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]

    $code = $Res.ExitCode
    $okCodes = @(0, 1707, 3010, 1641) + @("$(Get-HMSandboxValue $Settings 'SuccessCodes' '0')" -split '[,;\s]+' | Where-Object { $_ -match '^-?\d+$' } | ForEach-Object { [int]$_ })
    $status = "$(Get-HMSandboxValue $Res 'InstallStatus' '')"
    $stText = "$(Get-HMSandboxValue $Res 'InstallText' '')"
    $codeOk = ($null -ne $code -and "$code" -match '^-?\d+$' -and $okCodes -contains [int]$code)
    # Exitcode ok, aber die Verteilung meldet FEHLER, weil die Erkennung das Programm danach nicht findet
    $detectMiss = ($status -eq 'FEHLER' -and $codeOk -and $stText -match '(?i)nicht gefunden')
    $ok = if ($status) { ($status -eq 'OK' -or $status -eq 'SKIP' -or $detectMiss) } else { $codeOk }
    if ("$($Res.Error)") { $lines.Add("Fehler im Testskript: $($Res.Error)") }
    foreach ($d in @($Res.Deps | Where-Object { $_ })) {
        $lines.Add("Abhaengigkeit $($d.Name): $($d.Status) - $($d.Text)")
        if ($d.Status -eq 'FEHLER') { $warnings.Add("Abhaengigkeit '$($d.Name)' liess sich nicht installieren.") }
    }
    $codeText = switch ("$code") {
        '-999' { 'Zeitlimit erreicht - wartet das Setup auf eine Eingabe? Parameter fuer die stille Installation pruefen.' }
        '3010' { 'erfolgreich, Neustart noetig (3010)' }
        '1641' { 'erfolgreich, Setup hat Neustart ausgeloest (1641)' }
        '0' { 'erfolgreich (0)' }
        '' { 'kein Exitcode' }
        default { "Exitcode $code" }
    }
    $lines.Add("Installation: $codeText nach $($Res.Seconds) s$(if ($stText) { " - Verteilung meldet: $status $stText" })")
    if ($detectMiss) { $warnings.Add('ACHTUNG: Setup lief durch, aber die Erkennung findet das Programm danach nicht - Vorschlag fuer die Erkennung uebernehmen.') }
    $winI = @($Res.InstallWindows | Where-Object { $_ })
    if ($winI.Count) {
        if ($ok) { $lines.Add("Info: waehrend der Installation war ein Fenster offen ($($winI -join '; ')), das Setup lief aber ohne Eingabe durch - unkritisch.") }
        else { $warnings.Add("ACHTUNG: Setup zeigte ein Fenster ($($winI -join '; ')) - bei der Verteilung laeuft es unsichtbar und haengt bis zum Zeitlimit. Parameter fuer die stille Installation pruefen.") }
    }
    $entries = @($Res.NewEntries | Where-Object { $_ })
    $links = @($Res.DesktopLinks | Where-Object { $_ })
    $left = if ($null -ne $Res.PSObject.Properties['DesktopLinksLeft']) { @($Res.DesktopLinksLeft | Where-Object { $_ }) } else { $links }
    if ($links.Count) {
        $gone = @($links | Where-Object { $left -notcontains $_ })
        if ($gone.Count) { $lines.Add("Desktop-Verknuepfung entfernt: $($gone -join ', ')") }
        if ($left.Count) {
            if ($noDesk) { $warnings.Add("ACHTUNG: Desktop-Verknuepfung(en) trotz 'Ohne Desktop-Verknuepfung' vorhanden: $($left -join ', ')") }
            else { $lines.Add("Desktop-Verknuepfung(en): $($left -join ', ')  -> 'Ohne Desktop-Verknuepfung' anhaken, wenn unerwuenscht") }
        }
    } elseif ($noDesk) { $lines.Add('Desktop-Verknuepfung: Setup hat keine angelegt') }
    $userFolders = @($Res.UserFolders | Where-Object { $_ -match '(?i)\\AppData\\Local\\Programs\\' })
    $userInst = (@($entries | Where-Object { "$($_.Key)" -match '^HKEY_CURRENT_USER' -or "$($_.InstallLocation)$($_.UninstallString)" -match '(?i)\\Users\\' }).Count -gt 0) -or $userFolders.Count -gt 0
    if ($userInst) {
        $warnings.Add("ACHTUNG: installiert ins Benutzerprofil - bei der Verteilung landet es im Profil des ausfuehrenden Kontos, nicht beim angemeldeten Benutzer. Schalter fuer 'alle Benutzer' verwenden (Inno: /ALLUSERS, MSI: ALLUSERS=1) oder als Benutzer ausfuehren.")
    }
    $lines.Add("Neue Programme in 'Apps & Features': $($entries.Count)$(if ($entries.Count) { ' - ' + (@($entries | Select-Object -First 4 | ForEach-Object { "$($_.DisplayName) $($_.DisplayVersion)".Trim() }) -join '; ') })")
    $unOk = $false
    if ($Res.UninstallTested) {
        $winU = @($Res.UninstallWindows | Where-Object { $_ })
        $unOk = [bool]$Res.UninstallRemoved -and -not $winU.Count -and "$($Res.UninstallExitCode)" -ne '-999'
        $src = if ("$($Res.UninstallSource)" -eq 'Eintrag') { ' (Befehl aus dem neuen Eintrag)' } else { '' }
        $txt = if ($unOk) { 'OK - Eintrag entfernt, ohne Fenster' }
        elseif ($winU.Count) { "zeigte ein Fenster ($($winU -join '; ')) - nicht still, bei der Verteilung wuerde sie haengen" }
        elseif ("$($Res.UninstallExitCode)" -eq '-999') { 'Zeitlimit erreicht - wartet der Deinstaller auf eine Eingabe?' }
        else { 'Eintrag noch vorhanden - Befehl pruefen' }
        $l = "Deinstallation$($src): $txt (Exitcode $($Res.UninstallExitCode))"
        if ($unOk) { $lines.Add($l) } else { $warnings.Add("ACHTUNG: $l") }
    } else { $lines.Add('Deinstallation nicht getestet.') }
    # ACHTUNG-Zeilen stehen nur in Proposal.Warnings (die Anzeige haengt sie an), nicht doppelt in Lines
    $warn = $warnings.Count -gt 0
    $level = if (-not $ok) { 'Fehler' } elseif ($warn) { 'Hinweise' } else { 'OK' }
    $lines.Add($(switch ($level) { 'Fehler' { 'Ergebnis: Installation fehlgeschlagen - so nicht verteilen.' } 'Hinweise' { 'Ergebnis: installiert, aber mit Hinweisen (siehe ACHTUNG) - vor dem Verteilen pruefen.' } default { 'Ergebnis: OK - bereit zum Verteilen.' } }))
    # Protokolle bei Problemen direkt zeigen (vollstaendig im Ordner logs)
    $badUn = $Res.UninstallTested -and -not $unOk
    foreach ($x in @(@{ Show = (-not $ok -or $winI.Count -or "$($Res.Error)"); Text = "$($Res.InstallLog)"; Title = 'Protokoll Installation' }, @{ Show = $badUn; Text = "$($Res.UninstallLog)"; Title = 'Protokoll Deinstallation' })) {
        if (-not $x.Show) { continue }
        $lines.Add("--- $($x.Title) ---")
        if ($x.Text.Trim()) { foreach ($ln in ($x.Text -split "`r?`n")) { $lines.Add($ln) } }
        else { $lines.Add('(keine Protokolldaten - das Setup schreibt kein Log; ggf. Log-Schalter in den Parametern ergaenzen)') }
    }
    if ($WorkDir) { $ld = Join-Path $WorkDir 'logs'; if (Test-Path -LiteralPath $ld) { $lines.Add("Alle Protokolle: $ld") } }

    # Vorschlag
    $prop = [ordered]@{ Available = $false; DetectProductCode = ''; DetectName = ''; MinVersion = ''; DetectKey = ''; DetectFile = ''; UninstallCmd = ''; RunAsUser = [bool]$userInst; Warnings = @($warnings); OfferNoDesktop = ($left.Count -gt 0 -and -not $noDesk); DisplayName = ''; Version = ''; Publisher = '' }
    if ($ok) {
        $sel = $null
        if ("$($Res.SelectedKey)") { $sel = @($entries | Where-Object { "$($_.Key)" -eq "$($Res.SelectedKey)" }) | Select-Object -First 1 }
        if (-not $sel) { $sel = Select-HMSandboxEntry -Entries $entries -AppName $name }
        if ($sel) {
            $c = ConvertFrom-HMSandboxEntry -Entry $sel -InstallerType $itype
            $prop.Available = $true
            # MSI: ProductCode; Benutzerprofil (HKCU): Schluessel (Namenssuche kennt nur HKLM); sonst Name + Mindestversion.
            # Bei der Verteilung muessen ALLE festgelegten Erkennungen zutreffen - daher nur eine vorschlagen.
            if ($c.ProductCode -and -not $c.HKCU) { $prop.DetectProductCode = $c.ProductCode }
            elseif ($c.HKCU) { $prop.DetectKey = $c.DetectKey }
            else { $prop.DetectName = $c.DetectName }
            $prop.MinVersion = $c.MinVersion
            $prop.DisplayName = $c.DisplayName; $prop.Version = $c.Version; $prop.Publisher = $c.Publisher
            if ($c.UserProfile) { $prop.RunAsUser = $true }
            $prop.UninstallCmd = $c.UninstallCmd
        } else {
            $f = @($Res.NewFolders | Where-Object { $_ -match '(?i)\\Program Files' } | Sort-Object Length) | Select-Object -First 1
            if (-not $f) { $f = @($userFolders | Sort-Object Length) | Select-Object -First 1 }
            if ($f) { $prop.Available = $true; $prop.DetectFile = ConvertTo-HMSandboxEnvPath $f }
        }
        # Deinstallation: getesteter Befehl hat Vorrang, funktionierender eigener Befehl bleibt
        if ($Res.UninstallTested -and $unOk) { $prop.UninstallCmd = $(if ("$($Res.UninstallSource)" -eq 'Eintrag') { "$($Res.UninstallCmd)" } else { $curUn }) }
        elseif ($curUn -and -not $Res.UninstallTested) {
            $fixed = Add-HMSilentUninstall $curUn $itype
            $prop.UninstallCmd = $fixed
            if ($fixed -ne $curUn) { $lines.Add("Deinstallationsbefehl fuer stilles Entfernen ergaenzt: $fixed") }
        }
        # Deinstallationsbefehl aus dem Sandbox-Profil passt auf keinem anderen PC
        if ($prop.UninstallCmd -match '(?i)\\Users\\WDAGUtilityAccount\\') { $prop.UninstallCmd = '' }
        if ($prop.Available) {
            $lines.Add("Vorschlag: Erkennung $(if ($prop.DetectProductCode) { "MSI-Produktcode $($prop.DetectProductCode)" } elseif ($prop.DetectName) { "Name '$($prop.DetectName)'$(if ($prop.MinVersion) { " ab Version $($prop.MinVersion)" })" } elseif ($prop.DetectKey) { "Schluessel $($prop.DetectKey)$(if ($prop.MinVersion) { " ab Version $($prop.MinVersion)" })" } else { "Ordner $($prop.DetectFile)" })$(if ($prop.UninstallCmd) { "; Deinstallation: $($prop.UninstallCmd)" })")
            if ($prop.UninstallCmd -and -not $Res.UninstallTested) { $lines.Add('Tipp: Testinstallation mit Deinstallationstest wiederholen, um die Deinstallation zu pruefen.') }
        } else { $lines.Add('Keine Aenderung gefunden, aus der sich eine Erkennung ableiten laesst - Erkennung bitte selbst festlegen.') }
    } else {
        $lines.Add('Installation nicht erfolgreich - Parameter pruefen. "Sandbox offen lassen" anhaken, um im Sandbox-Fenster nachzusehen.')
    }
    # ohne "ACHTUNG: " (wird bei der Anzeige davorgesetzt); Profil-Hinweis steckt in RunAsUser
    $prop.Warnings = @($warnings | Where-Object { -not ($prop.RunAsUser -and $_ -match 'Benutzerprofil') } | ForEach-Object { $_ -replace '^ACHTUNG:\s*', '' })
    $note = (@(@($lines | Where-Object { $_ -match '^(Installation|Deinstallation|Ergebnis)' }) + @($warnings)) -join ' | ')
    if ($note.Length -gt 600) { $note = $note.Substring(0, 597) + '...' }
    $info = [pscustomobject]@{
        Date = (Get-Date).ToString('yyyy-MM-dd HH:mm'); Result = $level; ExitCode = $code; Seconds = $Res.Seconds
        UninstallTested = [bool]$Res.UninstallTested; UninstallOk = [bool]$unOk; Windows = @($winI); DesktopLinks = @($links)
        UserProfile = [bool]$userInst; Note = $note
    }
    return [pscustomobject]@{ Level = $level; Lines = $lines.ToArray(); Proposal = [pscustomobject]$prop; SandboxInfo = $info }
}

# ----------------------------------------------------------------------------
# Sandbox-Fenster: Groesse und Position merken (window.json) und beim naechsten Start wiederherstellen
# ----------------------------------------------------------------------------
function Initialize-HMSandboxWin32 {
    if ('HM.SbWin' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
namespace HM {
    public static class SbWin {
        [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
        delegate bool EnumProc(IntPtr h, IntPtr l);
        [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
        [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
        [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
        [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int cx, int cy, bool repaint);
        [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
        [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
        [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
        // sichtbare Hauptfenster, deren Titel den Text enthaelt -> "hwnd|pid|titel|klasse"
        public static List<string> Find(string part) {
            var res = new List<string>();
            EnumWindows(delegate (IntPtr h, IntPtr l) {
                if (!IsWindowVisible(h)) return true;
                var t = new StringBuilder(256); GetWindowText(h, t, 256);
                if (t.ToString().IndexOf(part, StringComparison.OrdinalIgnoreCase) < 0) return true;
                var c = new StringBuilder(256); GetClassName(h, c, 256);
                uint pid; GetWindowThreadProcessId(h, out pid);
                res.Add(h.ToInt64() + "|" + pid + "|" + t + "|" + c);
                return true;
            }, IntPtr.Zero);
            return res;
        }
    }
}
'@
}

function Get-HMSandboxWindowState {
    $f = Join-Path (Get-HMSandboxRoot) 'window.json'
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    try { return (Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Save-HMSandboxWindowState($State) {
    try { [IO.File]::WriteAllText((Join-Path (Get-HMSandboxRoot) 'window.json'), ($State | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding $false)) } catch { }
}

# gemerkte Lage nur verwenden, wenn sie gross genug ist und auf dem (virtuellen) Bildschirm liegt
function Test-HMSandboxWindowPlacement($Saved, [int]$VisLeft, [int]$VisTop, [int]$VisRight, [int]$VisBottom) {
    if (-not $Saved) { return $false }
    $x = [int]$Saved.X; $y = [int]$Saved.Y; $w = [int]$Saved.W; $h = [int]$Saved.H
    return ($w -ge 400 -and $h -ge 300 -and $x -lt $VisRight - 50 -and $y -lt $VisBottom - 50 -and $x + $w -gt $VisLeft + 50 -and $y -gt $VisTop - 50)
}

# Sandbox-Fenster suchen: sichtbares Fenster mit "Sandbox" im Titel, das zu einem Sandbox-Prozess gehoert
function Get-HMSandboxWindow {
    $pids = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like 'WindowsSandbox*' -or $_.ProcessName -like 'vmconnect*' } | ForEach-Object { $_.Id })
    foreach ($e in @([HM.SbWin]::Find('Sandbox'))) {
        $f = $e -split '\|', 4
        if ($pids -contains [int]$f[1] -or $f[2] -match '^Windows[- ]Sandbox') {
            return [pscustomobject]@{ Hwnd = [IntPtr][long]$f[0]; Pid = [int]$f[1]; Title = $f[2]; Class = $f[3]; Proc = "$((Get-Process -Id ([int]$f[1]) -ErrorAction SilentlyContinue).ProcessName)" }
        }
    }
    return $null
}

function Start-HMSandboxWindowKeeper {
    try { Initialize-HMSandboxWin32 } catch { return }
    $script:HMSbxWin = @{ Started = Get-Date; Found = $null; Hwnd = [IntPtr]::Zero; Applied = 0; Last = '' }
    if (-not $script:HMSbxWinTimer) {
        $script:HMSbxWinTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:HMSbxWinTimer.Interval = [TimeSpan]::FromSeconds(1)
        $script:HMSbxWinTimer.Add_Tick({ try { Update-HMSandboxWindowKeeper } catch { $script:HMSbxWinTimer.Stop() } })
    }
    $script:HMSbxWinTimer.Start()
}

function Update-HMSandboxWindowKeeper {
    $s = $script:HMSbxWin
    if (-not $s) { $script:HMSbxWinTimer.Stop(); return }
    $wi = Get-HMSandboxWindow
    $h = if ($wi) { $wi.Hwnd } else { [IntPtr]::Zero }
    if ($h -eq [IntPtr]::Zero) {
        # noch nicht da (max. 3 Min. warten) bzw. geschlossen
        if ($s.Found) { $script:HMSbxWinTimer.Stop() }
        elseif (((Get-Date) - $s.Started).TotalMinutes -gt 3) { $script:HMSbxWinTimer.Stop() }
        return
    }
    if (-not $s.Found) { $s.Found = Get-Date; $s.Hwnd = $h }
    $age = ((Get-Date) - $s.Found).TotalSeconds
    $saved = Get-HMSandboxWindowState
    # die Sandbox passt ihr Fenster beim Hochfahren noch an - daher mehrmals setzen (sofort, nach 5 und nach 12 s)
    $due = @(0, 5, 12)
    if ($saved -and $s.Applied -lt $due.Count -and $age -ge $due[$s.Applied]) {
        $s.Applied++
        try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop } catch { }
        $vis = [System.Windows.Forms.SystemInformation]::VirtualScreen
        if (Test-HMSandboxWindowPlacement $saved $vis.Left $vis.Top $vis.Right $vis.Bottom) {
            if ($saved.Max) { [void][HM.SbWin]::ShowWindow($h, 3) }
            else {
                [void][HM.SbWin]::ShowWindow($h, 9)
                $ok = [HM.SbWin]::SetWindowPos($h, [IntPtr]::Zero, [int]$saved.X, [int]$saved.Y, [int]$saved.W, [int]$saved.H, 0x0014)
                if (-not $ok) { [void][HM.SbWin]::MoveWindow($h, [int]$saved.X, [int]$saved.Y, [int]$saved.W, [int]$saved.H, $true) }
            }
        }
        return
    }
    # danach die aktuelle Lage merken (auch wenn das Fenster verschoben wird)
    if ($age -lt 15 -or [HM.SbWin]::IsIconic($h)) { return }
    $max = [HM.SbWin]::IsZoomed($h)
    $r = New-Object HM.SbWin+RECT
    if (-not [HM.SbWin]::GetWindowRect($h, [ref]$r)) { return }
    $cur = [pscustomobject]@{ X = $r.Left; Y = $r.Top; W = $r.Right - $r.Left; H = $r.Bottom - $r.Top; Max = [bool]$max }
    if ($max -and $saved) { $cur.X = [int]$saved.X; $cur.Y = [int]$saved.Y; $cur.W = [int]$saved.W; $cur.H = [int]$saved.H }
    $key = "$($cur.X)|$($cur.Y)|$($cur.W)|$($cur.H)|$($cur.Max)"
    if ($key -ne $s.Last) { $s.Last = $key; Save-HMSandboxWindowState $cur }
}

# ----------------------------------------------------------------------------
# winget (am PC, auf dem HUMig laeuft): neueste Version, Suche, Installer laden
#   Bevorzugt das Modul Microsoft.WinGet.Client, sonst winget.exe (Textausgabe, Sprache egal). Quelle "winget".
# ----------------------------------------------------------------------------
# Versionen vergleichen: -1 (A aelter), 0 (gleich), 1 (A neuer). Ziffernbloecke numerisch, Rest als Text.
function Compare-HMWingetVersion([string]$A, [string]$B) {
    $A = ("$A" -split '\+')[0]; $B = ("$B" -split '\+')[0]
    $pa = @("$A".Trim() -replace '^[vV]', '' -split '[.\-_ ]' | Where-Object { $_ -ne '' })
    $pb = @("$B".Trim() -replace '^[vV]', '' -split '[.\-_ ]' | Where-Object { $_ -ne '' })
    $n = [Math]::Max($pa.Count, $pb.Count)
    for ($i = 0; $i -lt $n; $i++) {
        $x = if ($i -lt $pa.Count) { $pa[$i] } else { '0' }
        $y = if ($i -lt $pb.Count) { $pb[$i] } else { '0' }
        $nx = 0L; $ny = 0L
        $ix = [long]::TryParse($x, [ref]$nx); $iy = [long]::TryParse($y, [ref]$ny)
        if ($ix -and $iy) { if ($nx -ne $ny) { return $(if ($nx -lt $ny) { -1 } else { 1 }) }; continue }
        $c = [string]::Compare($x, $y, [StringComparison]::OrdinalIgnoreCase)
        if ($c -ne 0) { return [Math]::Sign($c) }
    }
    return 0
}

function Get-HMWingetExe {
    $c = Get-Command winget.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.Source }
    if ($env:LOCALAPPDATA) {
        $p = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

function Test-HMWingetModule { return [bool](Get-Command Find-WinGetPackage -ErrorAction SilentlyContinue) }

$script:HMWingetMissing = 'winget ist nicht installiert - "App-Installer" aus dem Microsoft Store installieren (ab Windows 10 1809).'

# winget.exe ausfuehren, Ausgabezeilen ohne Fortschrittsanzeigen
function Invoke-HMWinget([string[]]$Arguments) {
    $exe = Get-HMWingetExe
    if (-not $exe) { throw $script:HMWingetMissing }
    $old = $null
    try { $old = [Console]::OutputEncoding; [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
    try { $out = @(& $exe @Arguments 2>&1 | ForEach-Object { "$_" }) }
    finally { if ($old) { try { [Console]::OutputEncoding = $old } catch { } } }
    $lines = foreach ($l in $out) {
        $t = ($l -split "`r")[-1]
        $t = $t -replace '[\u2580-\u259F]', ''
        if ($t -match '^\s*[-\\|/]\s*$') { continue }
        if ($t -match '^\s*[\d.,]+\s*(KB|MB|GB)\s*/\s*[\d.,]+\s*(KB|MB|GB)\s*$') { continue }
        $t.TrimEnd()
    }
    return @($lines | Where-Object { $null -ne $_ })
}

# Tabelle aus "winget search" zerlegen (Spaltenpositionen aus der Kopfzeile, Sprache egal)
function ConvertFrom-HMWingetTable([string[]]$Lines) {
    $Lines = @($Lines)
    $sep = -1
    for ($i = 1; $i -lt $Lines.Count; $i++) { if ($Lines[$i] -match '^-{10,}\s*$') { $sep = $i; break } }
    if ($sep -lt 1) { return @() }
    $head = $Lines[$sep - 1]
    $starts = @([regex]::Matches($head, '(?<=^|\s)\S') | ForEach-Object { $_.Index })
    if ($starts.Count -lt 3) { return @() }
    $rows = foreach ($l in @($Lines | Select-Object -Skip ($sep + 1))) {
        if (-not "$l".Trim()) { continue }
        $col = for ($k = 0; $k -lt $starts.Count; $k++) {
            $s = $starts[$k]
            if ($s -ge $l.Length) { ''; continue }
            $e = if ($k + 1 -lt $starts.Count) { [Math]::Min($starts[$k + 1], $l.Length) } else { $l.Length }
            $l.Substring($s, $e - $s).Trim()
        }
        $col = @($col)
        if ($col.Count -ge 3 -and $col[1]) { [pscustomobject]@{ Name = $col[0]; Id = $col[1]; Version = $col[2] } }
    }
    return @($rows)
}

# Pakete suchen -> Liste @{ Id; Name; Version }
function Find-HMWingetId {
    param([Parameter(Mandatory)][string]$Name, [int]$Max = 10)
    if (-not "$Name".Trim()) { return @() }
    if (Test-HMWingetModule) {
        try {
            return @(Find-WinGetPackage -Query $Name -Source 'winget' -ErrorAction Stop | Select-Object -First $Max | ForEach-Object { [pscustomobject]@{ Id = "$($_.Id)"; Name = "$($_.Name)"; Version = "$($_.Version)" } })
        } catch { }
    }
    if (-not (Get-HMWingetExe)) { throw $script:HMWingetMissing }
    $lines = Invoke-HMWinget @('search', '--query', $Name, '--source', 'winget', '--accept-source-agreements', '--disable-interactivity')
    $out = foreach ($r in @(ConvertFrom-HMWingetTable $lines | Select-Object -First $Max)) {
        $id = "$($r.Id)"; $nm = "$($r.Name)"
        # schmale Konsole: winget kuerzt Spalten mit ... bzw. dem Auslassungszeichen -> ueber "winget show" nachschlagen, sonst weglassen
        if ($id -match '(\u2026|\.\.\.)$') {
            $full = Resolve-HMWingetId ($id -replace '(\u2026|\.\.\.)$', '')
            if (-not $full) { continue }
            $id = $full.Id
            if ($full.Name) { $nm = $full.Name }
        }
        [pscustomobject]@{ Id = $id; Name = ($nm -replace '(\u2026|\.\.\.)$', '').Trim(); Version = "$($r.Version)" }
    }
    return @($out)
}

# gekuerzte ID vervollstaendigen: "winget show --id <Anfang>" findet genau ein Paket -> @{ Id; Name }, sonst $null
function Resolve-HMWingetId([string]$Prefix) {
    $p = "$Prefix".Trim().TrimEnd('.')
    if ($p.Length -lt 2) { return $null }
    $lines = @(Invoke-HMWinget @('show', '--id', $p, '--source', 'winget', '--accept-source-agreements', '--disable-interactivity'))
    foreach ($l in $lines) {
        if ($l -match '^\s*\S+\s+(.+?)\s+\[([^\]\s]+)\]\s*$' -and $Matches[2].StartsWith($p, [StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{ Id = $Matches[2]; Name = $Matches[1].Trim() }
        }
    }
    return $null
}

# neueste Version einer winget-ID -> @{ Version; Name } (Version '' = nicht gefunden)
function Get-HMWingetLatest {
    param([Parameter(Mandatory)][string]$Id)
    $none = [pscustomobject]@{ Version = ''; Name = '' }
    if (-not "$Id".Trim()) { return $none }
    if (Test-HMWingetModule) {
        try {
            $p = Find-WinGetPackage -Id $Id -MatchOption Equals -Source 'winget' -ErrorAction Stop | Select-Object -First 1
            if ($p) { return [pscustomobject]@{ Version = "$($p.Version)"; Name = "$($p.Name)" } }
        } catch { }
    }
    if (-not (Get-HMWingetExe)) { throw $script:HMWingetMissing }
    $lines = Invoke-HMWinget @('show', '--id', $Id, '--exact', '--source', 'winget', '--accept-source-agreements', '--disable-interactivity')
    $ver = ''; $nm = ''
    foreach ($l in $lines) {
        if (-not $nm -and $l -match ('^\s*\S+\s+(.+?)\s+\[' + [regex]::Escape($Id) + '\]\s*$')) { $nm = $Matches[1] }
        if (-not $ver -and $l -match '^\s*Version\s*:\s*(\S+)') { $ver = $Matches[1] }
    }
    return [pscustomobject]@{ Version = $ver; Name = $nm }
}

# Werte aus dem heruntergeladenen Manifest (winget legt eine .yaml daneben)
function Get-HMWingetManifestInfo([string]$Folder) {
    $info = [pscustomobject]@{ Version = ''; Silent = ''; InstallerType = '' }
    $y = Get-ChildItem -LiteralPath $Folder -Filter *.yaml -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $y) { return $info }
    $txt = Get-Content -LiteralPath $y.FullName -Raw -Encoding UTF8
    $m = [regex]::Match($txt, '(?m)^\s*Silent:\s*(.+?)\s*$'); if ($m.Success) { $info.Silent = $m.Groups[1].Value.Trim().Trim("'", '"') }
    $m = [regex]::Match($txt, '(?m)^\s*PackageVersion:\s*(.+?)\s*$'); if ($m.Success) { $info.Version = $m.Groups[1].Value.Trim().Trim("'", '"') }
    $m = [regex]::Match($txt, '(?m)^\s*InstallerType:\s*(.+?)\s*$'); if ($m.Success) { $info.InstallerType = $m.Groups[1].Value.Trim().Trim("'", '"').ToLower() }
    return $info
}

# Standard-Schalter fuer die stille Installation je Installer-Art (wenn das Manifest keine nennt)
function Get-HMWingetDefaultSilent([string]$InstallerType) {
    switch -Regex ("$InstallerType".ToLower()) {
        '^(msi|wix)$' { return '/qn /norestart' }
        '^inno$' { return '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-' }
        '^nullsoft$' { return '/S' }
        '^burn$' { return '/quiet /norestart' }
        default { return '' }
    }
}

# Installer herunterladen -> @{ File; Version; Silent; InstallerType }. Datei landet in DestDir (gleichnamige wird ersetzt).
function Save-HMWingetInstaller {
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$DestDir, [string]$Version = '', [switch]$PreferMsi)
    if (-not (Get-HMWingetExe)) { throw $script:HMWingetMissing }
    if (-not (Test-Path -LiteralPath $DestDir)) { [void](New-Item -ItemType Directory -Path $DestDir -Force) }
    $tmpBase = $env:TEMP; if (-not $tmpBase) { $tmpBase = [IO.Path]::GetTempPath() }
    $tmp = Join-Path $tmpBase ('HUMig_winget_' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $tmp -Force)
    try {
        $base = @('download', '--id', $Id, '--exact', '--source', 'winget', '--download-directory', $tmp, '--accept-source-agreements', '--accept-package-agreements', '--disable-interactivity', '--skip-dependencies')
        if ($Version) { $base += @('--version', $Version) }
        $variants = @(
            (@('--architecture', 'x64', '--scope', 'machine') + $(if ($PreferMsi) { @('--installer-type', 'msi') } else { @() })),
            @('--architecture', 'x64', '--scope', 'machine'),
            @('--architecture', 'x64'),
            @()
        )
        $log = @()
        $pick = $null
        foreach ($v in $variants) {
            $log += @(Invoke-HMWinget ($base + $v))
            $files = @(Get-ChildItem -LiteralPath $tmp -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '(?i)^\.(msi|exe|msp)$' })
            if ($files.Count) {
                if ($PreferMsi) { $pick = $files | Where-Object { $_.Extension -eq '.msi' } | Sort-Object Length -Descending | Select-Object -First 1 }
                if (-not $pick) { $pick = $files | Sort-Object Length -Descending | Select-Object -First 1 }
                break
            }
        }
        if (-not $pick) { throw "Kein Installer heruntergeladen. winget: $((@($log | Where-Object { "$_".Trim() }) | Select-Object -Last 3) -join ' | ')" }
        $mi = Get-HMWingetManifestInfo $tmp
        $type = $mi.InstallerType
        if (-not $type) { $type = $(if ($pick.Extension -ieq '.msi') { 'msi' } else { 'exe' }) }
        $silent = $mi.Silent
        # MSI: HUMig ruft msiexec /i <Datei> <Parameter> auf -> eigene msiexec-Schalter
        if ($pick.Extension -ieq '.msi' -or $pick.Extension -ieq '.msp') { $silent = '/qn /norestart' }
        if (-not $silent) { $silent = Get-HMWingetDefaultSilent $type }
        $dest = Join-Path $DestDir $pick.Name
        Copy-Item -LiteralPath $pick.FullName -Destination $dest -Force -ErrorAction Stop
        $ver = $mi.Version; if (-not $ver) { $ver = $Version }
        return [pscustomobject]@{ File = $dest; Version = $ver; Silent = $silent; InstallerType = $type }
    } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

# winget-Aufruf im Hintergrund (Suche, neueste Version, Download), damit das Fenster bedienbar bleibt.
# $Command: Find-HMWingetId | Get-HMWingetLatest | Save-HMWingetInstaller. OnComplete: param($result, $state) -> ConvertTo-HMAsyncResult
function Invoke-HMWingetAsync {
    param([Parameter(Mandatory)][ValidateSet('Find-HMWingetId', 'Get-HMWingetLatest', 'Save-HMWingetInstaller')][string]$Command, [hashtable]$Arguments = @{},
        [scriptblock]$OnComplete = $null, $State = $null, [int]$TimeoutSec = 300, [switch]$NoAsync)
    $fns = @('Compare-HMWingetVersion', 'Get-HMWingetExe', 'Test-HMWingetModule', 'Invoke-HMWinget', 'ConvertFrom-HMWingetTable', 'Resolve-HMWingetId', 'Find-HMWingetId', 'Get-HMWingetLatest', 'Get-HMWingetManifestInfo', 'Get-HMWingetDefaultSilent', 'Save-HMWingetInstaller')
    $pre = "`$script:HMWingetMissing = '$("$script:HMWingetMissing".Replace("'", "''"))'"
    return (Invoke-HMSandboxAsync -Command $Command -Arguments $Arguments -Functions $fns -Prelude $pre -OnComplete $OnComplete -State $State -TimeoutSec $TimeoutSec -BusyText 'WinGet' -NoAsync:$NoAsync)
}
