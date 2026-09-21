[CmdletBinding()]
param(
    [string]$ConfigPath = "project_settings.json",
    [string]$Clock = "07:00",
    [int]$Weekday = 0,
    [string]$YoloSource = "testVideo.mov",
    [string]$SumoBinary = "sumo-gui",
    [string]$DashboardUrl = "http://127.0.0.1:5173/",
    [string]$SecondaryUrl = "http://127.0.0.1:5173/raw",
    [int]$PrimaryWindowX = 0,
    [int]$PrimaryWindowY = 0,
    [int]$SecondaryWindowX = 1920,
    [int]$SecondaryWindowY = 0,
    [int]$WindowWidth = 1600,
    [int]$WindowHeight = 900
)

$ErrorActionPreference = "Stop"

$ScriptRoot = Split-Path -Parent $PSCommandPath
$ProjectRoot = (Resolve-Path -LiteralPath $ScriptRoot).Path
$YoloRoot = Join-Path -Path $ProjectRoot -ChildPath "yolo v8"
$DashboardRoot = Join-Path -Path $YoloRoot -ChildPath "web-dashboard"
$StateDir = Join-Path -Path $ProjectRoot -ChildPath "data\generated"
$StateFile = Join-Path -Path $StateDir -ChildPath "launcher_state.json"

function Get-PythonLauncher {
    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($python) {
        try {
            & $python.Source -c "import sys" *> $null
            if ($LASTEXITCODE -eq 0) {
                return @{
                    FilePath = $python.Source
                    Prefix   = @()
                }
            }
        } catch {
            # Fall through to py.exe below.
        }
    }

    $py = Get-Command py -ErrorAction SilentlyContinue
    if ($py) {
        try {
            & $py.Source -3 -c "import sys" *> $null
            if ($LASTEXITCODE -eq 0) {
                return @{
                    FilePath = $py.Source
                    Prefix   = @("-3")
                }
            }
        } catch {
            # Handled below with a clearer error.
        }
    }

    throw "A usable Python installation was not found. Install Python 3 or make py.exe point to an installed Python, then run the launcher again."
}

function Get-NpmLauncher {
    foreach ($candidate in @("npm.cmd", "npm.exe")) {
        $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($cmd) {
            return $cmd.Source
        }
    }

    $npm = Get-Command npm -ErrorAction SilentlyContinue
    if ($npm) {
        if ($npm.Source -match '\.ps1$') {
            $candidatePath = [System.IO.Path]::ChangeExtension($npm.Source, ".cmd")
            if (Test-Path -LiteralPath $candidatePath) {
                return $candidatePath
            }
        }
        return $npm.Source
    }

    throw "npm was not found on PATH."
}

function Get-BrowserLauncher {
    foreach ($name in @("msedge", "msedge.exe", "chrome", "chrome.exe")) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) {
            return $cmd.Source
        }
    }

    return $null
}

function Stop-ProcessTree {
    param(
        [int]$ProcessId
    )

    if ($ProcessId -le 0) {
        return
    }

    try {
        & taskkill /PID $ProcessId /T /F *> $null
    } catch {
        Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
    }
}

function Save-LauncherState {
    param(
        [hashtable]$State
    )

    New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
    $State | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $StateFile -Encoding utf8
}

function Register-Process {
    param(
        [hashtable]$State,
        [string]$Name,
        [System.Diagnostics.Process]$ProcessObject
    )

    if ($null -ne $ProcessObject) {
        $State.processes[$Name] = [int]$ProcessObject.Id
        Save-LauncherState -State $State
    }
}

function Get-DisplayLayout {
    $manualLayoutRequested = (
        $PrimaryWindowX -ne 0 -or
        $PrimaryWindowY -ne 0 -or
        $SecondaryWindowX -ne 1920 -or
        $SecondaryWindowY -ne 0 -or
        $WindowWidth -ne 1600 -or
        $WindowHeight -ne 900
    )

    if ($manualLayoutRequested) {
        return [pscustomobject]@{
            Dashboard = [pscustomobject]@{
                X      = $PrimaryWindowX
                Y      = $PrimaryWindowY
                Width  = $WindowWidth
                Height = $WindowHeight
            }
            Secondary = [pscustomobject]@{
                X      = $SecondaryWindowX
                Y      = $SecondaryWindowY
                Width  = $WindowWidth
                Height = $WindowHeight
            }
        }
    }

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $screens = [System.Windows.Forms.Screen]::AllScreens | Sort-Object { $_.Bounds.Left }
    } catch {
        $screens = @()
    }

    if (-not $screens -or $screens.Count -eq 0) {
        return [pscustomobject]@{
            Dashboard = [pscustomobject]@{
                X      = $PrimaryWindowX
                Y      = $PrimaryWindowY
                Width  = $WindowWidth
                Height = $WindowHeight
            }
            Secondary = [pscustomobject]@{
                X      = $SecondaryWindowX
                Y      = $SecondaryWindowY
                Width  = $WindowWidth
                Height = $WindowHeight
            }
        }
    }

    $dashboardScreen = $screens[-1].WorkingArea
    $secondaryScreen = if ($screens.Count -gt 1) { $screens[0].WorkingArea } else { $dashboardScreen }

    return [pscustomobject]@{
        Dashboard = [pscustomobject]@{
            X      = [int]$dashboardScreen.Left
            Y      = [int]$dashboardScreen.Top
            Width  = [int]$dashboardScreen.Width
            Height = [int]$dashboardScreen.Height
        }
        Secondary = [pscustomobject]@{
            X      = [int]$secondaryScreen.Left
            Y      = [int]$secondaryScreen.Top
            Width  = [int]$secondaryScreen.Width
            Height = [int]$secondaryScreen.Height
        }
    }
}

function Wait-ForPort {
    param(
        [string]$HostName,
        [int]$Port,
        [int]$TimeoutSeconds,
        [string]$Label
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $client = [System.Net.Sockets.TcpClient]::new()
        try {
            $iar = $client.BeginConnect($HostName, $Port, $null, $null)
            if ($iar.AsyncWaitHandle.WaitOne(500, $false) -and $client.Connected) {
                $client.EndConnect($iar)
                Write-Host "$Label is ready on ${HostName}:$Port"
                return
            }
        } catch {
            # Retry until the service is up.
        } finally {
            $client.Close()
        }

        Start-Sleep -Milliseconds 500
    }

    throw "Timed out waiting for $Label on ${HostName}:$Port"
}

function Start-BrowserWindow {
    param(
        [string]$Url,
        [int]$X,
        [int]$Y,
        [int]$Width,
        [int]$Height,
        [string]$Label
    )

    $browser = Get-BrowserLauncher
    if ($browser) {
        $args = @(
            "--app=$Url",
            "--window-position=$X,$Y",
            "--window-size=$Width,$Height"
        )
        Write-Host "Opening $Label in app mode..."
        return Start-Process -FilePath $browser -ArgumentList $args -PassThru
    }

    Write-Host "Opening $Label with the default browser..."
    Start-Process $Url | Out-Null
    return $null
}

function Start-DetachedProcess {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$WorkingDirectory,
        [string]$Label
    )

    Write-Host "Starting $Label..."
    return Start-Process -FilePath $FilePath -ArgumentList $Arguments -WorkingDirectory $WorkingDirectory -PassThru
}

$pythonLauncher = Get-PythonLauncher
$npmLauncher = Get-NpmLauncher
$layout = Get-DisplayLayout

$sessionState = [ordered]@{
    launcher_pid = [int]$PID
    started_at   = (Get-Date).ToString("o")
    processes    = [ordered]@{}
    urls         = [ordered]@{
        dashboard = $DashboardUrl
        raw       = $SecondaryUrl
    }
}

Save-LauncherState -State $sessionState

$backendProcesses = @()
$browserProcesses = @()

try {
    $traciArgs = @()
    $traciArgs += $pythonLauncher.Prefix
    $traciArgs += @(
        "traci_control.py",
        "--config",
        $ConfigPath,
        "--clock",
        $Clock,
        "--weekday",
        "$Weekday",
        "--sumo-binary",
        $SumoBinary
    )
    $traciProc = Start-DetachedProcess -FilePath $pythonLauncher.FilePath -Arguments $traciArgs -WorkingDirectory $ProjectRoot -Label "SUMO controller"
    $backendProcesses += $traciProc
    Register-Process -State $sessionState -Name "traci_control" -ProcessObject $traciProc

    Start-Sleep -Seconds 2
    if ($traciProc.HasExited) {
        throw "SUMO controller exited immediately with code $($traciProc.ExitCode). Check that Python 3, SUMO, and traci are installed and that SUMO_HOME points to a valid SUMO installation."
    }

    Wait-ForPort -HostName "127.0.0.1" -Port 8765 -TimeoutSeconds 90 -Label "SUMO HTTP bridge"

    $yoloArgs = @()
    $yoloArgs += $pythonLauncher.Prefix
    $yoloArgs += @(
        "main.py",
        "--source",
        $YoloSource
    )
    $yoloProc = Start-DetachedProcess -FilePath $pythonLauncher.FilePath -Arguments $yoloArgs -WorkingDirectory $YoloRoot -Label "YOLO server"
    $backendProcesses += $yoloProc
    Register-Process -State $sessionState -Name "yolo_server" -ProcessObject $yoloProc

    $dashboardArgs = @("run", "dev")
    $dashboardProc = Start-DetachedProcess -FilePath $npmLauncher -Arguments $dashboardArgs -WorkingDirectory $DashboardRoot -Label "Dashboard"
    $backendProcesses += $dashboardProc
    Register-Process -State $sessionState -Name "dashboard_dev_server" -ProcessObject $dashboardProc

    Wait-ForPort -HostName "127.0.0.1" -Port 8000 -TimeoutSeconds 120 -Label "YOLO server"
    Wait-ForPort -HostName "127.0.0.1" -Port 5173 -TimeoutSeconds 120 -Label "Dashboard"

    $dashboardBrowser = Start-BrowserWindow -Url $DashboardUrl -X $layout.Dashboard.X -Y $layout.Dashboard.Y -Width $layout.Dashboard.Width -Height $layout.Dashboard.Height -Label "dashboard"
    if ($dashboardBrowser) {
        $browserProcesses += $dashboardBrowser
        Register-Process -State $sessionState -Name "dashboard_browser" -ProcessObject $dashboardBrowser
    }

    $secondaryBrowser = Start-BrowserWindow -Url $SecondaryUrl -X $layout.Secondary.X -Y $layout.Secondary.Y -Width $layout.Secondary.Width -Height $layout.Secondary.Height -Label "raw stream"
    if ($secondaryBrowser) {
        $browserProcesses += $secondaryBrowser
        Register-Process -State $sessionState -Name "secondary_browser" -ProcessObject $secondaryBrowser
    }

    Write-Host ""
    Write-Host "Launcher is running."
    Write-Host "Dashboard   : $DashboardUrl"
    Write-Host "Raw stream  : $SecondaryUrl"
    Write-Host "Dashboard screen is placed on the right-most display."
    Write-Host "Press Ctrl+C in this window to stop the launcher and close the backends."
    Write-Host ""

    while ($true) {
        foreach ($proc in $backendProcesses) {
            if ($proc.HasExited) {
                throw "Backend process exited: PID $($proc.Id)"
            }
        }

        foreach ($proc in $browserProcesses) {
            if ($proc -and $proc.HasExited) {
                throw "Browser process exited unexpectedly: PID $($proc.Id)"
            }
        }

        Start-Sleep -Seconds 2
    }
} finally {
    if (Test-Path -LiteralPath $StateFile) {
        try {
            $state = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
            $idsToStop = @()
            if ($state.processes) {
                foreach ($prop in $state.processes.PSObject.Properties) {
                    $idsToStop += [int]$prop.Value
                }
            }

            $idsToStop = $idsToStop | Sort-Object -Unique
            foreach ($pid in ($idsToStop | Sort-Object -Descending)) {
                Stop-ProcessTree -ProcessId $pid
            }
        } catch {
            foreach ($proc in $browserProcesses + $backendProcesses) {
                if ($proc -and -not $proc.HasExited) {
                    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
                }
            }
        } finally {
            Remove-Item -LiteralPath $StateFile -Force -ErrorAction SilentlyContinue
        }
    } else {
        foreach ($proc in $browserProcesses + $backendProcesses) {
            if ($proc -and -not $proc.HasExited) {
                Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
