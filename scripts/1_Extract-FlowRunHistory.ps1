<#
.SYNOPSIS
    Extracts Power Automate flow run history including inputs/outputs for each action.

.DESCRIPTION
    Connects to the Power Platform environment, retrieves all flow runs within a
    specified date range, and exports the full run details (trigger data, action
    inputs/outputs) as JSON files. Also produces a consolidated CSV summary.

.PARAMETER EnvironmentId
    The Power Platform environment ID (GUID).

.PARAMETER FlowId
    The ID (GUID) of the Power Automate flow whose runs you want to extract.

.PARAMETER StartDate
    Earliest run date to include (default: 21 days ago).

.PARAMETER EndDate
    Latest run date to include (default: today).

.PARAMETER OutputFolder
    Folder where extracted JSON and CSV files will be saved.

.EXAMPLE
    .\1_Extract-FlowRunHistory.ps1 `
        -EnvironmentId "00000000-0000-0000-0000-000000000000" `
        -FlowId        "11111111-1111-1111-1111-111111111111" `
        -StartDate     "2026-03-19" `
        -EndDate       "2026-04-09" `
        -OutputFolder  "C:\FlowRunExport"
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$EnvironmentId,

    [Parameter(Mandatory = $true)]
    [string]$FlowId,

    [Parameter(Mandatory = $false)]
    [datetime]$StartDate = (Get-Date).AddDays(-21),

    [Parameter(Mandatory = $false)]
    [datetime]$EndDate = (Get-Date),

    [Parameter(Mandatory = $false)]
    [string]$OutputFolder = ".\FlowRunExport"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Ensure required modules ────────────────────────────────────────────────────
$requiredModules = @(
    "Microsoft.PowerApps.Administration.PowerShell",
    "Microsoft.PowerApps.PowerShell"
)

foreach ($mod in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        Write-Host "Installing module $mod ..." -ForegroundColor Yellow
        Install-Module -Name $mod -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module $mod -ErrorAction Stop
}

# ── Authenticate ───────────────────────────────────────────────────────────────
Write-Host "`n=== Authenticating to Power Platform ===" -ForegroundColor Cyan
Add-PowerAppsAccount

# ── Prepare output folder ──────────────────────────────────────────────────────
if (-not (Test-Path $OutputFolder)) {
    New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
}

$runDetailsFolder = Join-Path $OutputFolder "RunDetails"
if (-not (Test-Path $runDetailsFolder)) {
    New-Item -ItemType Directory -Path $runDetailsFolder -Force | Out-Null
}

# ── Retrieve flow runs ─────────────────────────────────────────────────────────
Write-Host "`n=== Retrieving flow runs from $($StartDate.ToString('yyyy-MM-dd')) to $($EndDate.ToString('yyyy-MM-dd')) ===" -ForegroundColor Cyan

$allRuns = @()
$pageToken = $null

do {
    $params = @{
        EnvironmentName = $EnvironmentId
        FlowName        = $FlowId
    }

    $page = Get-FlowRun @params
    if ($page) {
        $allRuns += $page
    }
    $pageToken = $null  # SDK handles paging internally
} while ($pageToken)

$filteredRuns = $allRuns | Where-Object {
    $runStart = [datetime]$_.Properties.startTime
    $runStart -ge $StartDate -and $runStart -le $EndDate
}

Write-Host "Found $($filteredRuns.Count) flow runs in the specified date range." -ForegroundColor Green

# ── Extract details for each run ───────────────────────────────────────────────
$summary = [System.Collections.ArrayList]::new()

foreach ($run in $filteredRuns) {
    $runId    = $run.FlowRunName
    $runStart = $run.Properties.startTime
    $runStatus = $run.Properties.status

    Write-Host "  Processing run $runId ($runStart) ..." -ForegroundColor Gray

    try {
        $runDetail = Get-FlowRun -EnvironmentName $EnvironmentId `
                                 -FlowName $FlowId `
                                 -FlowRunName $runId

        $actions = @()
        try {
            $actions = Get-FlowRunAction -EnvironmentName $EnvironmentId `
                                         -FlowName $FlowId `
                                         -FlowRunName $runId
        } catch {
            Write-Warning "  Could not retrieve actions for run $runId : $_"
        }

        $runExport = [ordered]@{
            RunId        = $runId
            StartTime    = $runStart
            EndTime      = $run.Properties.endTime
            Status       = $runStatus
            Trigger      = $run.Properties.trigger
            Actions      = @()
        }

        foreach ($action in $actions) {
            $actionDetail = [ordered]@{
                Name       = $action.Name
                Status     = $action.Properties.status
                StartTime  = $action.Properties.startTime
                EndTime    = $action.Properties.endTime
                Inputs     = $action.Properties.inputsLink
                Outputs    = $action.Properties.outputsLink
                Code       = $action.Properties.code
                Error      = $action.Properties.error
            }

            # Attempt to download actual input/output payloads via the content links
            if ($action.Properties.inputsLink.uri) {
                try {
                    $actionDetail.InputsContent = (Invoke-RestMethod -Uri $action.Properties.inputsLink.uri -Method Get)
                } catch { }
            }
            if ($action.Properties.outputsLink.uri) {
                try {
                    $actionDetail.OutputsContent = (Invoke-RestMethod -Uri $action.Properties.outputsLink.uri -Method Get)
                } catch { }
            }

            $runExport.Actions += $actionDetail
        }

        $jsonPath = Join-Path $runDetailsFolder "$runId.json"
        $runExport | ConvertTo-Json -Depth 20 | Out-File -FilePath $jsonPath -Encoding UTF8

        [void]$summary.Add([PSCustomObject]@{
            RunId     = $runId
            StartTime = $runStart
            EndTime   = $run.Properties.endTime
            Status    = $runStatus
            Actions   = ($actions | Measure-Object).Count
            JsonFile  = $jsonPath
        })
    } catch {
        Write-Warning "Error processing run $runId : $_"
    }
}

# ── Write summary CSV ──────────────────────────────────────────────────────────
$csvPath = Join-Path $OutputFolder "FlowRunSummary.csv"
$summary | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

Write-Host "`n=== Export complete ===" -ForegroundColor Green
Write-Host "  Run details : $runDetailsFolder"
Write-Host "  Summary CSV : $csvPath"
Write-Host "  Total runs  : $($summary.Count)"
