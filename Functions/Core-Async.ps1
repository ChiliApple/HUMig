#Requires -Version 5.1
<#
.SYNOPSIS
    Asynchrone Ausfuehrung ohne UI-Freeze.
    - Invoke-AsyncCommand : kurze Aufgaben im RunspacePool (Timeout, OnComplete wird IMMER aufgerufen)
    - Start-LongJob       : lange Aufgaben (Backup/Restore) in eigenem Runspace mit Live-Log, Fortschritt, Abbruch
#>

$script:RunspacePool = $null
# laufende Hintergrund-Aufgaben je Kennung ('*' = alle) - fuer die pulsierenden Anzeige-Punkte
$script:AsyncBusy = @{}
$script:AsyncBusyText = @{}
function Set-HMAsyncBusy([string]$Tag, [int]$Delta, [string]$Text = '') {
    foreach ($k in @('*', $Tag)) {
        if (-not $k) { continue }
        $n = [int]$script:AsyncBusy[$k] + $Delta; if ($n -lt 0) { $n = 0 }
        $script:AsyncBusy[$k] = $n
        if ($Delta -gt 0 -and $Text) { $script:AsyncBusyText[$k] = $Text }
        if ($n -eq 0) { $script:AsyncBusyText[$k] = '' }
    }
    if (Get-Command Update-HMBusyUi -ErrorAction SilentlyContinue) { try { Update-HMBusyUi } catch { } }
}

function Initialize-AsyncPool {
    param([int]$PoolSize = 6)
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $script:RunspacePool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, $PoolSize, $iss, $Host)
    $script:RunspacePool.ApartmentState = [System.Threading.ApartmentState]::STA
    $script:RunspacePool.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::UseNewThread
    $script:RunspacePool.Open()
}

function Invoke-AsyncCommand {
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [object[]]$ArgumentList,
        [scriptblock]$OnComplete,
        [object]$State = $null,
        [int]$TimeoutSec = 120,
        [string]$BusyTag = '',
        [string]$BusyText = ''
    )
    if (-not $script:RunspacePool) { Write-Host '[ASYNC] RunspacePool nicht initialisiert' -ForegroundColor Red; return }

    $ps = [PowerShell]::Create()
    $ps.RunspacePool = $script:RunspacePool
    [void]$ps.AddScript($ScriptBlock.ToString())
    if ($null -ne $ArgumentList) { foreach ($arg in $ArgumentList) { [void]$ps.AddArgument($arg) } }

    $handle    = $ps.BeginInvoke()
    $startTime = Get-Date
    # Anzeige "laeuft": die Timer-Closure sieht keine Skript-Funktionen -> Funktion als Scriptblock mitgeben
    $busyFn  = ${function:Set-HMAsyncBusy}
    $busyTag = $BusyTag
    try { & $busyFn $busyTag 1 $BusyText } catch { }
    $completed = [ref]$false
    $timeout   = $TimeoutSec
    $stateObj  = $State
    $stopState = @{ Handle = $null }

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(250)
    $timer.Add_Tick({
        if ($completed.Value) {
            if ($stopState.Handle -and $stopState.Handle.IsCompleted) {
                $timer.Stop()
                try { $ps.EndStop($stopState.Handle) } catch { }
                try { $ps.Dispose() } catch { }
                $stopState.Handle = $null
            }
            return
        }
        if ($handle.IsCompleted) {
            $timer.Stop()
            $completed.Value = $true
            try { & $busyFn $busyTag -1 } catch { }
            $result = $null
            try {
                $raw = $ps.EndInvoke($handle)
                # Objekte unveraendert weitergeben (kein Out-String)
                if ($raw -and $raw.Count -eq 1) { $result = $raw[0] } elseif ($raw -and $raw.Count -gt 1) { $result = @($raw) }
                if ($null -eq $result -and $ps.Streams.Error.Count -gt 0) {
                    $errs = @($ps.Streams.Error | ForEach-Object { $_.ToString() } | Where-Object { $_ } | Select-Object -Unique)
                    $result = 'FEHLER: ' + ($errs -join ' | ')
                }
            } catch {
                $msg = $_.Exception.Message
                if ($_.Exception.InnerException) { $msg = $_.Exception.InnerException.Message }
                $result = "FEHLER: $msg"
            } finally { try { $ps.Dispose() } catch { } }
            if ($OnComplete) {
                try { & $OnComplete $result $stateObj }
                catch { Write-Host "[ASYNC OnComplete] $($_.Exception.Message)" -ForegroundColor Red }
            }
        } elseif (((Get-Date) - $startTime).TotalSeconds -gt $timeout) {
            $completed.Value = $true
            try { & $busyFn $busyTag -1 } catch { }
            try { $stopState.Handle = $ps.BeginStop($null, $null) } catch { $stopState.Handle = $null }
            if ($OnComplete) {
                try { & $OnComplete "FEHLER: Timeout - keine Antwort nach $timeout Sekunden (abgebrochen)" $stateObj }
                catch { Write-Host "[ASYNC OnComplete] $($_.Exception.Message)" -ForegroundColor Red }
            }
            if (-not $stopState.Handle) { $timer.Stop(); try { $ps.Dispose() } catch { } }
        }
    }.GetNewClosure())
    $timer.Start()
}

function Close-AsyncPool {
    if ($script:RunspacePool) {
        try { $script:RunspacePool.Close(); $script:RunspacePool.Dispose() } catch { }
        $script:RunspacePool = $null
    }
}

# ----------------------------------------------------------------------------
# Lange Jobs: eigener Runspace, Kommunikation ueber synchronisierte Hashtable
#   $Job.Log      : Queue von @{ Msg; Lvl }
#   $Job.Progress : 0..100, $Job.Status : Text
#   $Job.Cancel   : $true -> Engine bricht beim naechsten Schritt ab (laufendes Robocopy wird beendet)
#   $Job.Done     : $true wenn fertig, $Job.Result : Ergebnisobjekt
# ----------------------------------------------------------------------------
function New-JobState {
    $q = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue))
    return [hashtable]::Synchronized(@{
        Log = $q; Progress = 0; Status = ''; Cancel = $false; Done = $false; Result = $null
        Process = $null; Error = $null; Started = (Get-Date)
    })
}

function Start-LongJob {
    param(
        [Parameter(Mandatory)][string[]]$ScriptFiles,   # werden im Runspace dot-sourced
        [Parameter(Mandatory)][string]$Command,          # z.B. 'Start-HMBackup -Ctx $Ctx -Job $Job'
        [Parameter(Mandatory)][hashtable]$Ctx,
        [Parameter(Mandatory)][hashtable]$Job,
        [scriptblock]$OnTick,                            # param($Job) - alle 300 ms im UI-Thread
        [scriptblock]$OnDone                             # param($Job)
    )
    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.ApartmentState = [System.Threading.ApartmentState]::STA
    $rs.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::UseNewThread
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('Ctx', $Ctx)
    $rs.SessionStateProxy.SetVariable('Job', $Job)
    $ps = [PowerShell]::Create()
    $ps.Runspace = $rs
    $sb = New-Object System.Text.StringBuilder
    foreach ($f in $ScriptFiles) { [void]$sb.AppendLine(". '" + ($f -replace "'", "''") + "'") }
    [void]$sb.AppendLine('try { ' + $Command + ' } catch { $Job.Error = $_.Exception.Message; $Job.Log.Enqueue(@{ Msg = "FEHLER (Abbruch): $($_.Exception.Message)"; Lvl = "Error" }) } finally { $Job.Done = $true }')
    [void]$ps.AddScript($sb.ToString())
    $handle = $ps.BeginInvoke()

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(300)
    $timer.Add_Tick({
        if ($OnTick) { try { & $OnTick $Job } catch { Write-Host "[LongJob OnTick] $_" -ForegroundColor Red } }
        if ($Job.Done -and $handle.IsCompleted) {
            $timer.Stop()
            try { $ps.EndInvoke($handle) | Out-Null } catch { }
            foreach ($e in @($ps.Streams.Error)) { $Job.Log.Enqueue(@{ Msg = "FEHLER: $e"; Lvl = 'Error' }) }
            try { $ps.Dispose(); $rs.Close(); $rs.Dispose() } catch { }
            if ($OnTick) { try { & $OnTick $Job } catch { } }
            if ($OnDone) { try { & $OnDone $Job } catch { Write-Host "[LongJob OnDone] $_" -ForegroundColor Red } }
        }
    }.GetNewClosure())
    $timer.Start()
}
