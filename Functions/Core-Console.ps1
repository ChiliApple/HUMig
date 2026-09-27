#Requires -Version 5.1
<#
.SYNOPSIS
    Konsolen-Ausgabe fuer die WPF-RichTextBox (Catppuccin Mocha) + Spiegelung in die Log-Datei.
#>

$script:ConsoleColors = @{
    Info      = '#FF89B4FA'
    Warning   = '#FFF9E2AF'
    Error     = '#FFF38BA8'
    Success   = '#FFA6E3A1'
    Debug     = '#FF6C7086'
    Header    = '#FFCDD6F4'
    Default   = '#FFCDD6F4'
    Separator = '#FF89B4FA'
}
$script:ConsoleLogFile = $null
$script:BrushCache = @{}

function Get-ConsoleBrush([string]$HexColor) {
    if ($script:BrushCache.ContainsKey($HexColor)) { return $script:BrushCache[$HexColor] }
    try {
        $b = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString($HexColor))
    } catch {
        $b = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Colors]::White)
    }
    $b.Freeze()
    $script:BrushCache[$HexColor] = $b
    return $b
}

function Set-ConsoleLogFile([string]$Path) { $script:ConsoleLogFile = $Path }

function Write-ConsoleOutput {
    param(
        [AllowEmptyString()][string]$Message = '',
        [ValidateSet('Info', 'Warning', 'Error', 'Success', 'Debug', 'Header', 'Separator')][string]$Level = 'Info',
        [Parameter(Mandatory = $true)]$Window
    )
    $ts = (Get-Date).ToString('HH:mm:ss')
    if ($script:ConsoleLogFile) {
        try { Add-Content -LiteralPath $script:ConsoleLogFile -Value ('{0} [{1}] {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Level.ToUpper(), $Message) -Encoding UTF8 } catch { }
    }
    try {
        $action = {
            $rtb = $Window.FindName('rtbConsole')
            if (-not $rtb) { return }
            $doc = $rtb.Document
            $brush = Get-ConsoleBrush $script:ConsoleColors[$Level]
            $para = [System.Windows.Documents.Paragraph]::new()
            if ($Level -eq 'Header') {
                $para.Margin = [System.Windows.Thickness]::new(0, 6, 0, 2)
                $run = [System.Windows.Documents.Run]::new($Message)
                $run.Foreground = $brush
                $run.FontWeight = [System.Windows.FontWeights]::Bold
                $run.TextDecorations = [System.Windows.TextDecorations]::Underline
                $para.Inlines.Add($run)
            } elseif ($Level -eq 'Separator') {
                $para.Margin = [System.Windows.Thickness]::new(0, 2, 0, 2)
                $run = [System.Windows.Documents.Run]::new(([string][char]0x2500) * 50)
                $run.Foreground = $brush
                $para.Inlines.Add($run)
            } else {
                $para.Margin = [System.Windows.Thickness]::new(0, 1, 0, 1)
                $tsRun = [System.Windows.Documents.Run]::new("[$ts] ")
                $tsRun.Foreground = Get-ConsoleBrush '#FF6C7086'
                $para.Inlines.Add($tsRun)
                $msgRun = [System.Windows.Documents.Run]::new($Message)
                $msgRun.Foreground = $brush
                $para.Inlines.Add($msgRun)
            }
            $doc.Blocks.Add($para)
            # Konsole nicht endlos wachsen lassen
            while ($doc.Blocks.Count -gt 5000) { [void]$doc.Blocks.Remove($doc.Blocks.FirstBlock) }
            $rtb.ScrollToEnd()
        }
        if ($Window.Dispatcher.CheckAccess()) { & $action } else { $Window.Dispatcher.Invoke($action) }
    } catch {
        Write-Host "[Console-Output ERROR] $_" -ForegroundColor Red
    }
}

function Clear-ConsoleOutput {
    param([Parameter(Mandatory = $true)]$Window)
    try {
        $rtb = $Window.FindName('rtbConsole')
        if ($rtb) { $rtb.Document.Blocks.Clear() }
    } catch { Write-Host "[Console-Output ERROR] Clear: $_" -ForegroundColor Red }
}

function Get-ConsoleContent {
    param([Parameter(Mandatory = $true)]$Window)
    try {
        $rtb = $Window.FindName('rtbConsole')
        if (-not $rtb) { return '' }
        $range = [System.Windows.Documents.TextRange]::new($rtb.Document.ContentStart, $rtb.Document.ContentEnd)
        return $range.Text
    } catch { return '' }
}
