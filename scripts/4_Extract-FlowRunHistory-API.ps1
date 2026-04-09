<#
.SYNOPSIS
    Alternative extraction method using the Power Automate Management API directly.
    Use this if the PowerShell connector modules are unavailable or you prefer REST.

.DESCRIPTION
    Calls the Power Automate Management REST API to list flow runs and download
    each run's action details. Requires an Azure AD access token.

.PARAMETER EnvironmentId
    The Power Platform environment ID.

.PARAMETER FlowId
    The flow ID (GUID).

.PARAMETER StartDate
    Earliest run date (default: 28 days ago).

.PARAMETER EndDate
    Latest run date (default: today).

.PARAMETER OutputFolder
    Destination for exported files.

.EXAMPLE
    .\4_Extract-FlowRunHistory-API.ps1 `
        -EnvironmentId "00000000-0000-0000-0000-000000000000" `
        -FlowId        "11111111-1111-1111-1111-111111111111" `
        -OutputFolder  "C:\FlowRunExport"
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$EnvironmentId,

    [Parameter(Mandatory = $true)]
    [string]$FlowId,

    [Parameter(Mandatory = $false)]
    [datetime]$StartDate = (Get-Date).AddDays(-28),

    [Parameter(Mandatory = $false)]
    [datetime]$EndDate = (Get-Date),

    [Parameter(Mandatory = $false)]
    [string]$OutputFolder = ".\FlowRunExport"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Authentication ─────────────────────────────────────────────────────────────
Write-Host "Authenticating..." -ForegroundColor Cyan

$token = $null

try {
    if (Get-Module -ListAvailable -Name Az.Accounts) {
        Import-Module Az.Accounts -ErrorAction Stop
        if (-not (Get-AzContext)) { Connect-AzAccount }
        $tokenObj = Get-AzAccessToken -ResourceUrl "https://service.flow.microsoft.com"
        $token = $tokenObj.Token
    }
} catch {
    Write-Warning "Az module auth failed: $_"
}

if (-not $token) {
    try {
        if (-not (Get-Module -ListAvailable -Name MSAL.PS)) {
            Install-Module -Name MSAL.PS -Scope CurrentUser -Force -AcceptLicense
        }
        Import-Module MSAL.PS

        $msalToken = Get-MsalToken -ClientId "51f81489-12ee-4a9e-aaae-a2591f45987d" `
                                    -Scopes "https://service.flow.microsoft.com/.default" `
                                    -Interactive
        $token = $msalToken.AccessToken
    } catch {
        throw "Could not authenticate. Ensure Az.Accounts or MSAL.PS is installed."
    }
}

$headers = @{
    "Authorization" = "Bearer $token"
    "Content-Type"  = "application/json"
}

# ── Prepare output ─────────────────────────────────────────────────────────────
foreach ($dir in @($OutputFolder, (Join-Path $OutputFolder "RunDetails"))) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

$runDetailsFolder = Join-Path $OutputFolder "RunDetails"

# ── API base URL ───────────────────────────────────────────────────────────────
$baseUrl = "https://api.flow.microsoft.com"
$apiVersion = "2016-11-01"

# ── List flow runs ────────────────────────────────────────────────────────────
Write-Host "`nFetching flow runs..." -ForegroundColor Cyan

$startFilter = $StartDate.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$endFilter   = $EndDate.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

$runsUrl = "$baseUrl/providers/Microsoft.ProcessSimple/environments/$EnvironmentId/flows/$FlowId/runs?api-version=$apiVersion&`$filter=startTime ge $startFilter and startTime le $endFilter"

$allRuns = @()
$nextLink = $runsUrl

while ($nextLink) {
    $response = Invoke-RestMethod -Uri $nextLink -Headers $headers -Method Get
    if ($response.value) {
        $allRuns += $response.value
    }
    $nextLink = $response.nextLink
}

Write-Host "Retrieved $($allRuns.Count) runs." -ForegroundColor Green

# ── Get details for each run ──────────────────────────────────────────────────
$summary = [System.Collections.ArrayList]::new()

foreach ($run in $allRuns) {
    $runId     = $run.name
    $runStart  = $run.properties.startTime
    $runStatus = $run.properties.status

    Write-Host "  Processing $runId ($runStart)..." -ForegroundColor Gray

    try {
        # Get actions for this run
        $actionsUrl = "$baseUrl/providers/Microsoft.ProcessSimple/environments/$EnvironmentId/flows/$FlowId/runs/$runId/actions?api-version=$apiVersion"
        $actionsResp = Invoke-RestMethod -Uri $actionsUrl -Headers $headers -Method Get
        $actions = $actionsResp.value

        $runExport = [ordered]@{
            RunId     = $runId
            StartTime = $runStart
            EndTime   = $run.properties.endTime
            Status    = $runStatus
            Trigger   = $run.properties.trigger
            Actions   = @()
        }

        foreach ($action in $actions) {
            $actionObj = [ordered]@{
                Name      = $action.name
                Type      = $action.properties.type
                Status    = $action.properties.status
                StartTime = $action.properties.startTime
                EndTime   = $action.properties.endTime
                Code      = $action.properties.code
                Error     = $action.properties.error
            }

            # Download input content
            if ($action.properties.inputsLink.uri) {
                try {
                    $actionObj.InputsContent = Invoke-RestMethod -Uri $action.properties.inputsLink.uri -Method Get
                } catch { $actionObj.InputsContent = $null }
            }

            # Download output content
            if ($action.properties.outputsLink.uri) {
                try {
                    $actionObj.OutputsContent = Invoke-RestMethod -Uri $action.properties.outputsLink.uri -Method Get
                } catch { $actionObj.OutputsContent = $null }
            }

            $runExport.Actions += $actionObj
        }

        $jsonPath = Join-Path $runDetailsFolder "$runId.json"
        $runExport | ConvertTo-Json -Depth 20 | Out-File -FilePath $jsonPath -Encoding UTF8

        [void]$summary.Add([PSCustomObject]@{
            RunId     = $runId
            StartTime = $runStart
            EndTime   = $run.properties.endTime
            Status    = $runStatus
            Actions   = ($actions | Measure-Object).Count
            JsonFile  = $jsonPath
        })
    } catch {
        Write-Warning "Error processing run $runId : $_"
    }

    Start-Sleep -Milliseconds 100
}

# ── Summary ────────────────────────────────────────────────────────────────────
$csvPath = Join-Path $OutputFolder "FlowRunSummary.csv"
$summary | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

Write-Host "`n=== Export complete ===" -ForegroundColor Green
Write-Host "  JSON files : $runDetailsFolder"
Write-Host "  Summary    : $csvPath"
Write-Host "  Total runs : $($summary.Count)"
