<#
.SYNOPSIS
    Restores security roles to Dynamics 365 CE users based on the parsed removal data.

.DESCRIPTION
    Reads the CSV produced by 2_Parse-RemovedSecurityRoles.ps1 and re-assigns each
    security role to the corresponding user via the Dataverse Web API.

    Supports:
      - Dry-run mode (default) to preview changes without applying them
      - Selective restore by user or role filters
      - Duplicate-safe: skips users who already have the role

.PARAMETER InputCsv
    Path to the RolesRemoved.csv file.

.PARAMETER OrgUrl
    Dynamics 365 CE organization URL (e.g., https://yourorg.crm.dynamics.com).

.PARAMETER DryRun
    When set, only previews the changes without making any API calls.

.PARAMETER FilterUsers
    Optional list of user emails to limit the restore to.

.PARAMETER FilterRoles
    Optional list of role names to limit the restore to.

.PARAMETER BatchSize
    Number of requests per OData batch. Default: 50.

.EXAMPLE
    # Preview only
    .\3_Restore-SecurityRoles.ps1 `
        -InputCsv "C:\FlowRunExport\RolesRemoved.csv" `
        -OrgUrl   "https://yourorg.crm.dynamics.com" `
        -DryRun

    # Execute restore
    .\3_Restore-SecurityRoles.ps1 `
        -InputCsv "C:\FlowRunExport\RolesRemoved.csv" `
        -OrgUrl   "https://yourorg.crm.dynamics.com"
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param (
    [Parameter(Mandatory = $true)]
    [string]$InputCsv,

    [Parameter(Mandatory = $true)]
    [string]$OrgUrl,

    [Parameter(Mandatory = $false)]
    [switch]$DryRun = $true,

    [Parameter(Mandatory = $false)]
    [string[]]$FilterUsers,

    [Parameter(Mandatory = $false)]
    [string[]]$FilterRoles,

    [Parameter(Mandatory = $false)]
    [int]$BatchSize = 50
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$OrgUrl = $OrgUrl.TrimEnd("/")
$apiUrl = "$OrgUrl/api/data/v9.2"

# ── Load removal data ─────────────────────────────────────────────────────────
$removals = Import-Csv -Path $InputCsv -Encoding UTF8

if ($FilterUsers) {
    $removals = $removals | Where-Object { $_.UserEmail -in $FilterUsers }
}
if ($FilterRoles) {
    $removals = $removals | Where-Object { $_.RoleName -in $FilterRoles }
}

# Deduplicate: same user + role pair should only be restored once
$uniqueAssignments = $removals |
    Sort-Object UserId, RoleId -Unique |
    Where-Object { $_.UserId -and $_.RoleId }

Write-Host "`n=== Security Role Restore ===" -ForegroundColor Cyan
Write-Host "  Total removal records : $($removals.Count)"
Write-Host "  Unique user-role pairs: $($uniqueAssignments.Count)"
if ($DryRun) {
    Write-Host "  Mode                  : DRY RUN (no changes will be made)" -ForegroundColor Yellow
} else {
    Write-Host "  Mode                  : LIVE EXECUTION" -ForegroundColor Red
}

# ── Authenticate to Dataverse ──────────────────────────────────────────────────
Write-Host "`nAuthenticating to Dataverse..." -ForegroundColor Cyan

# Prefer the Az module token approach (works in Azure Cloud Shell, CI/CD, etc.)
$token = $null

# Method 1: Az module
try {
    if (Get-Module -ListAvailable -Name Az.Accounts) {
        Import-Module Az.Accounts -ErrorAction Stop
        $azContext = Get-AzContext
        if (-not $azContext) {
            Connect-AzAccount
        }
        $tokenObj = Get-AzAccessToken -ResourceUrl $OrgUrl
        $token = $tokenObj.Token
        Write-Host "  Authenticated via Az module." -ForegroundColor Green
    }
} catch {
    Write-Warning "Az module auth failed: $_"
}

# Method 2: MSAL.PS
if (-not $token) {
    try {
        if (-not (Get-Module -ListAvailable -Name MSAL.PS)) {
            Install-Module -Name MSAL.PS -Scope CurrentUser -Force -AcceptLicense
        }
        Import-Module MSAL.PS -ErrorAction Stop

        $msalToken = Get-MsalToken -ClientId "51f81489-12ee-4a9e-aaae-a2591f45987d" `
                                    -Scopes "$OrgUrl/.default" `
                                    -Interactive
        $token = $msalToken.AccessToken
        Write-Host "  Authenticated via MSAL.PS." -ForegroundColor Green
    } catch {
        Write-Warning "MSAL.PS auth failed: $_"
    }
}

if (-not $token) {
    throw "Could not obtain an access token. Please ensure Az.Accounts or MSAL.PS is available."
}

$headers = @{
    "Authorization" = "Bearer $token"
    "OData-MaxVersion" = "4.0"
    "OData-Version"    = "4.0"
    "Content-Type"     = "application/json"
    "Accept"           = "application/json"
    "Prefer"           = "odata.include-annotations=*"
}

# ── Helper: Check if user already has the role ─────────────────────────────────
function Test-UserHasRole {
    param ([string]$UserId, [string]$RoleId)

    $checkUrl = "$apiUrl/systemusers($UserId)/systemuserroles_association?`$filter=roleid eq $RoleId"
    try {
        $result = Invoke-RestMethod -Uri $checkUrl -Headers $headers -Method Get
        return ($result.value.Count -gt 0)
    } catch {
        return $false
    }
}

# ── Helper: Assign role to user ────────────────────────────────────────────────
function Add-SecurityRoleToUser {
    param ([string]$UserId, [string]$RoleId)

    $associateUrl = "$apiUrl/systemusers($UserId)/systemuserroles_association/`$ref"
    $body = @{
        "@odata.id" = "$apiUrl/roles($RoleId)"
    } | ConvertTo-Json

    Invoke-RestMethod -Uri $associateUrl -Headers $headers -Method Post -Body $body
}

# ── Process restorations ──────────────────────────────────────────────────────
$results = [System.Collections.ArrayList]::new()
$restored = 0
$skipped  = 0
$errors   = 0

foreach ($assignment in $uniqueAssignments) {
    $userId   = $assignment.UserId
    $roleId   = $assignment.RoleId
    $userDesc = if ($assignment.UserEmail) { $assignment.UserEmail } else { $userId }
    $roleDesc = if ($assignment.RoleName)  { $assignment.RoleName }  else { $roleId }

    Write-Host "  $userDesc  <--  $roleDesc" -NoNewline

    if ($DryRun) {
        Write-Host "  [DRY RUN - would restore]" -ForegroundColor Yellow
        [void]$results.Add([PSCustomObject]@{
            UserId    = $userId
            UserEmail = $assignment.UserEmail
            UserName  = $assignment.UserName
            RoleId    = $roleId
            RoleName  = $assignment.RoleName
            Status    = "DryRun"
            Error     = ""
        })
        $restored++
        continue
    }

    try {
        $alreadyHas = Test-UserHasRole -UserId $userId -RoleId $roleId
        if ($alreadyHas) {
            Write-Host "  [SKIPPED - already has role]" -ForegroundColor DarkGray
            $skipped++
            [void]$results.Add([PSCustomObject]@{
                UserId    = $userId
                UserEmail = $assignment.UserEmail
                UserName  = $assignment.UserName
                RoleId    = $roleId
                RoleName  = $assignment.RoleName
                Status    = "Skipped"
                Error     = "User already has this role"
            })
            continue
        }

        Add-SecurityRoleToUser -UserId $userId -RoleId $roleId
        Write-Host "  [RESTORED]" -ForegroundColor Green
        $restored++
        [void]$results.Add([PSCustomObject]@{
            UserId    = $userId
            UserEmail = $assignment.UserEmail
            UserName  = $assignment.UserName
            RoleId    = $roleId
            RoleName  = $assignment.RoleName
            Status    = "Restored"
            Error     = ""
        })
    } catch {
        Write-Host "  [ERROR] $_" -ForegroundColor Red
        $errors++
        [void]$results.Add([PSCustomObject]@{
            UserId    = $userId
            UserEmail = $assignment.UserEmail
            UserName  = $assignment.UserName
            RoleId    = $roleId
            RoleName  = $assignment.RoleName
            Status    = "Error"
            Error     = $_.ToString()
        })
    }

    # Throttle to avoid API rate limits
    Start-Sleep -Milliseconds 200
}

# ── Save results ───────────────────────────────────────────────────────────────
$resultCsv = $InputCsv -replace "\.csv$", "_RestoreResults.csv"
$results | Export-Csv -Path $resultCsv -NoTypeInformation -Encoding UTF8

Write-Host "`n=== Restore Summary ===" -ForegroundColor Green
Write-Host "  Restored : $restored"
Write-Host "  Skipped  : $skipped"
Write-Host "  Errors   : $errors"
Write-Host "  Results  : $resultCsv"
