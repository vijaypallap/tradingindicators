<#
.SYNOPSIS
    Parses extracted flow run JSON files to identify which security roles
    were removed from which users.

.DESCRIPTION
    Reads the JSON files produced by 1_Extract-FlowRunHistory.ps1, locates
    the Dataverse "Disassociate" or "Remove" actions, and extracts:
      - SystemUser ID / email / name
      - Security Role ID / name
      - Timestamp of removal
    Produces a CSV (RolesRemoved.csv) that serves as input for the restore script.

.PARAMETER InputFolder
    Folder containing the RunDetails JSON files.

.PARAMETER OutputFile
    Path for the output CSV. Default: RolesRemoved.csv in the InputFolder parent.

.PARAMETER ActionNamePatterns
    Array of action-name substrings that indicate a role-removal step.
    Defaults cover common naming conventions.

.EXAMPLE
    .\2_Parse-RemovedSecurityRoles.ps1 -InputFolder "C:\FlowRunExport\RunDetails"
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$InputFolder,

    [Parameter(Mandatory = $false)]
    [string]$OutputFile,

    [Parameter(Mandatory = $false)]
    [string[]]$ActionNamePatterns = @(
        "Disassociate",
        "Remove",
        "Unrelate",
        "RemoveSecurityRole",
        "Remove_Security_Role",
        "RemoveRole",
        "Delete_Role",
        "UnassignRole"
    )
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not $OutputFile) {
    $OutputFile = Join-Path (Split-Path $InputFolder -Parent) "RolesRemoved.csv"
}

$jsonFiles = Get-ChildItem -Path $InputFolder -Filter "*.json"
Write-Host "Found $($jsonFiles.Count) run JSON files to parse." -ForegroundColor Cyan

$removals = [System.Collections.ArrayList]::new()

foreach ($file in $jsonFiles) {
    $run = Get-Content $file.FullName -Raw | ConvertFrom-Json

    foreach ($action in $run.Actions) {
        $actionName = $action.Name
        $matched = $false

        foreach ($pattern in $ActionNamePatterns) {
            if ($actionName -like "*$pattern*") {
                $matched = $true
                break
            }
        }

        if (-not $matched) { continue }
        if ($action.Status -ne "Succeeded") { continue }

        $userId      = $null
        $userEmail   = $null
        $userName    = $null
        $roleId      = $null
        $roleName    = $null
        $timestamp   = $action.StartTime

        # --- Extract from InputsContent (Dataverse connector payloads) ---
        $inputs = $action.InputsContent
        if ($inputs) {
            # Dataverse "Disassociate" action typically has:
            #   parameters.entityName, parameters.recordId (user)
            #   parameters.associationEntityRelationship
            #   parameters.relatedEntityId (role)
            if ($inputs.parameters) {
                $p = $inputs.parameters

                if ($p.recordId)        { $userId  = $p.recordId }
                if ($p.relatedEntityId) { $roleId  = $p.relatedEntityId }

                # Alternative field names used by some connector versions
                if ($p.item -and -not $userId)  { $userId = $p.item }
                if ($p."item/id" -and -not $userId) { $userId = $p."item/id" }
            }

            # HTTP-style actions that call the Web API directly
            if ($inputs.uri -and -not $userId) {
                $uri = $inputs.uri
                # Pattern: systemusers(GUID)/systemuserroles_association/$ref
                if ($uri -match "systemusers\(([0-9a-fA-F\-]+)\)") {
                    $userId = $Matches[1]
                }
                if ($uri -match "roles\(([0-9a-fA-F\-]+)\)") {
                    $roleId = $Matches[1]
                }
            }

            # Body-based payloads
            if ($inputs.body) {
                $body = $inputs.body
                if ($body.systemuserid -and -not $userId) { $userId = $body.systemuserid }
                if ($body.roleid -and -not $roleId)       { $roleId = $body.roleid }
                if ($body.fullname)                        { $userName = $body.fullname }
                if ($body.internalemailaddress)             { $userEmail = $body.internalemailaddress }
                if ($body.name)                            { $roleName = $body.name }
            }
        }

        # --- Extract from OutputsContent for additional metadata ---
        $outputs = $action.OutputsContent
        if ($outputs -and $outputs.body) {
            if ($outputs.body.fullname -and -not $userName)           { $userName  = $outputs.body.fullname }
            if ($outputs.body.internalemailaddress -and -not $userEmail) { $userEmail = $outputs.body.internalemailaddress }
            if ($outputs.body.name -and -not $roleName)               { $roleName  = $outputs.body.name }
        }

        # --- Look for preceding "Get" actions in the same run for context ---
        if (-not $userName -or -not $roleName) {
            foreach ($otherAction in $run.Actions) {
                if ($otherAction.Name -like "*Get*User*" -and $otherAction.OutputsContent) {
                    $o = $otherAction.OutputsContent
                    if ($o.body) {
                        if ($o.body.systemuserid -eq $userId) {
                            if (-not $userName)  { $userName  = $o.body.fullname }
                            if (-not $userEmail) { $userEmail = $o.body.internalemailaddress }
                        }
                    }
                }
                if ($otherAction.Name -like "*Get*Role*" -and $otherAction.OutputsContent) {
                    $o = $otherAction.OutputsContent
                    if ($o.body -and $o.body.roleid -eq $roleId) {
                        if (-not $roleName) { $roleName = $o.body.name }
                    }
                }
            }
        }

        if ($userId -or $roleId) {
            [void]$removals.Add([PSCustomObject]@{
                RunId        = $run.RunId
                RunStartTime = $run.StartTime
                ActionName   = $actionName
                Timestamp    = $timestamp
                UserId       = $userId
                UserEmail    = $userEmail
                UserName     = $userName
                RoleId       = $roleId
                RoleName     = $roleName
                JsonFile     = $file.Name
            })
        }
    }
}

$removals | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8

Write-Host "`n=== Parsing complete ===" -ForegroundColor Green
Write-Host "  Role removals found : $($removals.Count)"
Write-Host "  Output CSV          : $OutputFile"

if ($removals.Count -gt 0) {
    Write-Host "`n--- Summary by User ---" -ForegroundColor Cyan
    $removals | Group-Object UserEmail | ForEach-Object {
        Write-Host "  $($_.Name): $($_.Count) role(s) removed"
    }

    Write-Host "`n--- Summary by Role ---" -ForegroundColor Cyan
    $removals | Group-Object RoleName | ForEach-Object {
        Write-Host "  $($_.Name): removed from $($_.Count) user(s)"
    }
}
