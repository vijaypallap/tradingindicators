<#
.SYNOPSIS
    Verifies that security roles were successfully restored to users.

.DESCRIPTION
    Reads the RolesRemoved.csv and queries Dynamics 365 CE to confirm
    each user now has the expected security role. Produces a verification report.

.PARAMETER InputCsv
    Path to the RolesRemoved.csv file.

.PARAMETER OrgUrl
    Dynamics 365 CE organization URL.

.PARAMETER OutputFile
    Path for the verification report CSV.

.EXAMPLE
    .\5_Verify-RestoredRoles.ps1 `
        -InputCsv "C:\FlowRunExport\RolesRemoved.csv" `
        -OrgUrl   "https://yourorg.crm.dynamics.com"
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$InputCsv,

    [Parameter(Mandatory = $true)]
    [string]$OrgUrl,

    [Parameter(Mandatory = $false)]
    [string]$OutputFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$OrgUrl = $OrgUrl.TrimEnd("/")
$apiUrl = "$OrgUrl/api/data/v9.2"

if (-not $OutputFile) {
    $OutputFile = $InputCsv -replace "\.csv$", "_VerificationReport.csv"
}

# ── Authenticate ───────────────────────────────────────────────────────────────
$token = $null
try {
    Import-Module Az.Accounts -ErrorAction Stop
    if (-not (Get-AzContext)) { Connect-AzAccount }
    $tokenObj = Get-AzAccessToken -ResourceUrl $OrgUrl
    $token = $tokenObj.Token
} catch {
    try {
        Import-Module MSAL.PS -ErrorAction Stop
        $msalToken = Get-MsalToken -ClientId "51f81489-12ee-4a9e-aaae-a2591f45987d" `
                                    -Scopes "$OrgUrl/.default" `
                                    -Interactive
        $token = $msalToken.AccessToken
    } catch {
        throw "Authentication failed."
    }
}

$headers = @{
    "Authorization"    = "Bearer $token"
    "OData-MaxVersion" = "4.0"
    "OData-Version"    = "4.0"
    "Accept"           = "application/json"
    "Prefer"           = "odata.include-annotations=*"
}

# ── Load data ──────────────────────────────────────────────────────────────────
$removals = Import-Csv -Path $InputCsv -Encoding UTF8
$uniquePairs = $removals | Sort-Object UserId, RoleId -Unique | Where-Object { $_.UserId -and $_.RoleId }

Write-Host "`n=== Verifying $($uniquePairs.Count) user-role assignments ===" -ForegroundColor Cyan

$report = [System.Collections.ArrayList]::new()
$verified = 0
$missing  = 0
$checkErrors = 0

foreach ($pair in $uniquePairs) {
    $userId = $pair.UserId
    $roleId = $pair.RoleId
    $desc   = "$($pair.UserEmail) / $($pair.RoleName)"

    Write-Host "  Checking $desc ..." -NoNewline

    try {
        $checkUrl = "$apiUrl/systemusers($userId)/systemuserroles_association?`$filter=roleid eq $roleId"
        $result = Invoke-RestMethod -Uri $checkUrl -Headers $headers -Method Get

        if ($result.value.Count -gt 0) {
            Write-Host " [OK]" -ForegroundColor Green
            $verified++
            $status = "Verified"
        } else {
            Write-Host " [MISSING]" -ForegroundColor Red
            $missing++
            $status = "Missing"
        }

        [void]$report.Add([PSCustomObject]@{
            UserId    = $userId
            UserEmail = $pair.UserEmail
            UserName  = $pair.UserName
            RoleId    = $roleId
            RoleName  = $pair.RoleName
            Status    = $status
            Error     = ""
        })
    } catch {
        Write-Host " [ERROR]" -ForegroundColor Red
        $checkErrors++
        [void]$report.Add([PSCustomObject]@{
            UserId    = $userId
            UserEmail = $pair.UserEmail
            UserName  = $pair.UserName
            RoleId    = $roleId
            RoleName  = $pair.RoleName
            Status    = "Error"
            Error     = $_.ToString()
        })
    }

    Start-Sleep -Milliseconds 100
}

$report | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8

Write-Host "`n=== Verification Summary ===" -ForegroundColor Green
Write-Host "  Verified : $verified"
Write-Host "  Missing  : $missing"
Write-Host "  Errors   : $checkErrors"
Write-Host "  Report   : $OutputFile"

if ($missing -gt 0) {
    Write-Host "`n  WARNING: $missing role assignments are still missing!" -ForegroundColor Red
    Write-Host "  Review the report and re-run the restore script for missing items."
}
