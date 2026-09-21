[CmdletBinding()]
param(
    [string]$StateFile = "data/generated/launcher_state.json"
)

$ErrorActionPreference = "Stop"

$ScriptRoot = Split-Path -Parent $PSCommandPath
$ProjectRoot = (Resolve-Path -LiteralPath $ScriptRoot).Path
$ResolvedStateFile = Join-Path -Path $ProjectRoot -ChildPath $StateFile

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

function Stop-PortOwners {
    param(
        [int[]]$Ports
    )

    foreach ($port in $Ports) {
        try {
            $owners = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty OwningProcess -Unique
            foreach ($owner in $owners) {
                Stop-ProcessTree -ProcessId ([int]$owner)
            }
        } catch {
            # Ignore port lookup failures and continue with the state file.
        }
    }
}

$idsToStop = @()
if (Test-Path -LiteralPath $ResolvedStateFile) {
    try {
        $state = Get-Content -LiteralPath $ResolvedStateFile -Raw | ConvertFrom-Json
        if ($state.processes) {
            foreach ($prop in $state.processes.PSObject.Properties) {
                $idsToStop += [int]$prop.Value
            }
        }
        if ($state.launcher_pid) {
            $idsToStop += [int]$state.launcher_pid
        }
    } catch {
        Write-Host "Could not read launcher state file, falling back to port cleanup."
    }
}

$idsToStop = $idsToStop | Sort-Object -Unique
foreach ($pid in ($idsToStop | Sort-Object -Descending)) {
    Stop-ProcessTree -ProcessId $pid
}

Stop-PortOwners -Ports @(5173, 8000, 8765)

Remove-Item -LiteralPath $ResolvedStateFile -Force -ErrorAction SilentlyContinue
