#Requires -Version 5.1
<#
.SYNOPSIS
    Automatische Pruefungen fuer HUMig (GitHub Actions, Windows PowerShell 5.1) - blockierend.
.DESCRIPTION
    1. Syntax aller PowerShell-Dateien (Parser), UTF-8-BOM
    2. XAML-Fenster laden; alle im Code verwendeten Steuerelemente vorhanden ($ui-Liste HUMig.ps1, Einstellungsfenster)
    3. Konfigurationsdateien (JSON) lesbar
    4. Update-Bibliothek in Pull.ps1 und Functions\Core-Update.ps1 identisch
    5. PSScriptAnalyzer: keine Fehler (Schweregrad Error)
    6. Pester-Tests (.github\tests\*.Tests.ps1)
.NOTES
    Aufruf (auch lokal): powershell -NoProfile -ExecutionPolicy Bypass -File .github\tests\Invoke-CITests.ps1
    Zielmaschine: Windows-PC / GitHub-Runner mit Internet (PSScriptAnalyzer, Pester werden bei Bedarf installiert).
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$fail = New-Object System.Collections.Generic.List[string]
function Step([string]$Name, [scriptblock]$Do) {
    Write-Host "== $Name" -ForegroundColor Cyan
    try { $r = & $Do; if ($r) { Write-Host "   $r" -ForegroundColor Green } else { Write-Host '   OK' -ForegroundColor Green } }
    catch { $fail.Add("$Name : $($_.Exception.Message)"); Write-Host "   FEHLER: $($_.Exception.Message)" -ForegroundColor Red }
}
Write-Host "HUMig CI - PowerShell $($PSVersionTable.PSVersion) - $([Environment]::OSVersion.VersionString)"

# 1. Syntax + BOM
Step 'Syntax und UTF-8-BOM aller .ps1' {
    $bad = @()
    $files = @(Get-ChildItem -Path $root -Recurse -File -Filter *.ps1 | Where-Object { $_.FullName -notmatch '\\(BACKUPS|BIN|\.git)\\' })
    foreach ($f in $files) {
        $t = $null; $e = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$t, [ref]$e)
        if ($e.Count) { $bad += "$($f.Name): " + (($e | Select-Object -First 2 | ForEach-Object { "Zeile $($_.Extent.StartLineNumber) $($_.Message)" }) -join ' | ') }
        $b = [System.IO.File]::ReadAllBytes($f.FullName)
        if (-not ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)) { $bad += "$($f.Name): kein UTF-8-BOM" }
    }
    if ($bad.Count) { throw ($bad -join '; ') }
    "$($files.Count) Dateien"
}

# 2. XAML + Steuerelemente
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
function Get-HMNameList([string]$File, [string]$Pattern) {
    $txt = Get-Content -LiteralPath $File -Raw -Encoding UTF8
    $m = [regex]::Match($txt, $Pattern, 'Singleline')
    if (-not $m.Success) { throw "Liste in $(Split-Path $File -Leaf) nicht gefunden" }
    return @([regex]::Matches($m.Groups[1].Value, "'([A-Za-z0-9_]+)'") | ForEach-Object { $_.Groups[1].Value })
}
$script:Main = $null
Step 'XAML Hauptfenster + alle Steuerelemente aus HUMig.ps1' {
    [xml]$x = Get-Content (Join-Path $root 'XAML\MainWindow.xaml') -Raw -Encoding UTF8
    $script:Main = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $x))
    $names = Get-HMNameList (Join-Path $root 'HUMig.ps1') 'foreach \(\$n in @\((.+?)\)\) \{ \$ui\[\$n\] = Get-UI \$n \}'
    $miss = @($names | Where-Object { -not $script:Main.FindName($_) })
    if ($miss.Count) { throw "fehlt im XAML: $($miss -join ', ')" }
    "$($names.Count) Steuerelemente"
}
Step 'XAML Einstellungsfenster + alle Steuerelemente aus UI-Settings.ps1' {
    [xml]$y = Get-Content (Join-Path $root 'XAML\SettingsWindow.xaml') -Raw -Encoding UTF8
    $w = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $y))
    if ($script:Main) { $w.Resources.MergedDictionaries.Add($script:Main.Resources) }
    $names = Get-HMNameList (Join-Path $root 'Functions\UI-Settings.ps1') 'foreach \(\$n in @\((.+?)\)\) \{ \$f\[\$n\] = \$w\.FindName\(\$n\) \}'
    $miss = @($names | Where-Object { -not $w.FindName($_) })
    if ($miss.Count) { throw "fehlt im XAML: $($miss -join ', ')" }
    "$($names.Count) Steuerelemente"
}

# 3. JSON
Step 'Konfigurationsdateien (JSON)' {
    $n = 0
    foreach ($f in @(Get-ChildItem (Join-Path $root 'Config') -Filter *.json)) { [void](Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json); $n++ }
    "$n Dateien"
}

# 4. Update-Bibliothek identisch
Step 'Update-Bibliothek Pull.ps1 = Functions\Core-Update.ps1' {
    $re = '(?s)#region HMUpdateLib.*?#endregion HMUpdateLib'
    $a = [regex]::Match((Get-Content (Join-Path $root 'Pull.ps1') -Raw -Encoding UTF8), $re).Value -replace "`r`n", "`n"
    $b = [regex]::Match((Get-Content (Join-Path $root 'Functions\Core-Update.ps1') -Raw -Encoding UTF8), $re).Value -replace "`r`n", "`n"
    if (-not $a -or -not $b) { throw 'Bereich HMUpdateLib fehlt' }
    if ($a -ne $b) { throw 'Bereich HMUpdateLib unterscheidet sich - beide Dateien gleich halten' }
    "$(($a -split "`n").Count) Zeilen"
}

# 5. PSScriptAnalyzer
function Install-HMModule([string]$Name, [string]$Max = '') {
    if (Get-Module -ListAvailable -Name $Name | Where-Object { -not $Max -or $_.Version -le [Version]$Max } | Select-Object -First 1) { return }
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue)) { Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null }
    $p = @{ Name = $Name; Force = $true; Scope = 'CurrentUser'; SkipPublisherCheck = $true; AllowClobber = $true }
    if ($Max) { $p.MaximumVersion = $Max }
    Install-Module @p
}
Step 'PSScriptAnalyzer (Fehler)' {
    Install-HMModule 'PSScriptAnalyzer'
    Import-Module PSScriptAnalyzer
    $r = @(Invoke-ScriptAnalyzer -Path $root -Recurse -Severity Error)
    if ($r.Count) { throw (($r | Select-Object -First 10 | ForEach-Object { "$($_.ScriptName):$($_.Line) $($_.RuleName) $($_.Message)" }) -join ' | ') }
    'keine Fehler'
}

# 6. Pester
Step 'Pester-Tests' {
    Install-HMModule 'Pester' '5.99.99'
    Import-Module Pester -MaximumVersion 5.99.99 -Force
    $cfg = New-PesterConfiguration
    $cfg.Run.Path = $PSScriptRoot
    $cfg.Run.PassThru = $true
    $cfg.Output.Verbosity = 'Detailed'
    $res = Invoke-Pester -Configuration $cfg
    if ($res.FailedCount -gt 0) { throw "$($res.FailedCount) von $($res.TotalCount) Tests fehlgeschlagen" }
    "$($res.PassedCount) Tests bestanden"
}

Write-Host ''
if ($fail.Count) {
    Write-Host "FEHLGESCHLAGEN ($($fail.Count)):" -ForegroundColor Red
    $fail | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    if ($env:GITHUB_STEP_SUMMARY) { (@('### HUMig CI: FEHLGESCHLAGEN') + @($fail | ForEach-Object { "- $_" })) | Add-Content $env:GITHUB_STEP_SUMMARY }
    exit 1
}
Write-Host 'ALLE PRUEFUNGEN BESTANDEN' -ForegroundColor Green
if ($env:GITHUB_STEP_SUMMARY) { '### HUMig CI: alle Pruefungen bestanden' | Add-Content $env:GITHUB_STEP_SUMMARY }
exit 0
