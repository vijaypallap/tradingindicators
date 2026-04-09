# Power Automate Flow Run History Extractor & Dynamics 365 CE Security Role Restorer

Toolkit to extract Power Automate flow run history (logs and JSON payloads), identify security roles that were removed from Dynamics 365 CE users, and restore those roles.

## Problem

A Power Automate flow has been removing security roles from Dynamics 365 CE users based on expiration dates. The flow has been running daily, and the last 3 weeks of removals need to be analyzed and reverted.

## Solution Overview

This toolkit provides a 5-step process:

| Step | Script | Purpose |
|------|--------|---------|
| 1 | `1_Extract-FlowRunHistory.ps1` | Extract flow run history using PowerShell modules |
| 2 | `2_Parse-RemovedSecurityRoles.ps1` | Parse JSON logs to identify removed roles per user |
| 3 | `3_Restore-SecurityRoles.ps1` | Restore security roles (with dry-run support) |
| 4 | `4_Extract-FlowRunHistory-API.ps1` | Alternative extraction using REST API directly |
| 5 | `5_Verify-RestoredRoles.ps1` | Verify roles were successfully restored |

## Prerequisites

- **PowerShell 5.1+** (or PowerShell 7+)
- One of the following authentication modules:
  - `Az.Accounts` (recommended; pre-installed in Azure Cloud Shell)
  - `MSAL.PS` (alternative; will be auto-installed if needed)
- **Power Platform admin** permissions (for extracting flow run history)
- **Dynamics 365 System Administrator** or **Security Role Manager** role (for restoring roles)
- You need your **Environment ID** and **Flow ID** from Power Automate

### Finding Your Environment ID and Flow ID

1. Open [Power Automate](https://make.powerautomate.com)
2. Select the correct **Environment** from the top-right dropdown
3. Navigate to **My flows** and open the flow
4. The URL contains both IDs:
   ```
   https://make.powerautomate.com/environments/{EnvironmentId}/flows/{FlowId}/details
   ```

## Usage

### Step 1: Extract Flow Run History

Choose **one** of the two extraction methods.

**Option A: PowerShell Module Method** (simpler, uses built-in cmdlets)

```powershell
.\scripts\1_Extract-FlowRunHistory.ps1 `
    -EnvironmentId "your-environment-id" `
    -FlowId        "your-flow-id" `
    -StartDate     "2026-03-19" `
    -EndDate       "2026-04-09" `
    -OutputFolder  "C:\FlowRunExport"
```

**Option B: REST API Method** (no module dependencies, more control)

```powershell
.\scripts\4_Extract-FlowRunHistory-API.ps1 `
    -EnvironmentId "your-environment-id" `
    -FlowId        "your-flow-id" `
    -StartDate     "2026-03-19" `
    -EndDate       "2026-04-09" `
    -OutputFolder  "C:\FlowRunExport"
```

**Output:**
```
FlowRunExport/
  FlowRunSummary.csv          # Summary of all runs
  RunDetails/
    <run-id-1>.json           # Full details for each run
    <run-id-2>.json
    ...
```

### Step 2: Parse Removed Security Roles

```powershell
.\scripts\2_Parse-RemovedSecurityRoles.ps1 `
    -InputFolder "C:\FlowRunExport\RunDetails"
```

**Output:** `FlowRunExport\RolesRemoved.csv` with columns:
- `RunId`, `RunStartTime`, `ActionName`, `Timestamp`
- `UserId`, `UserEmail`, `UserName`
- `RoleId`, `RoleName`

Review this CSV carefully before proceeding to restoration.

### Step 3: Restore Security Roles

**Always start with a dry run:**

```powershell
.\scripts\3_Restore-SecurityRoles.ps1 `
    -InputCsv "C:\FlowRunExport\RolesRemoved.csv" `
    -OrgUrl   "https://yourorg.crm.dynamics.com" `
    -DryRun
```

**Execute the restore (remove `-DryRun` flag):**

```powershell
.\scripts\3_Restore-SecurityRoles.ps1 `
    -InputCsv "C:\FlowRunExport\RolesRemoved.csv" `
    -OrgUrl   "https://yourorg.crm.dynamics.com"
```

**Filter to specific users or roles:**

```powershell
.\scripts\3_Restore-SecurityRoles.ps1 `
    -InputCsv    "C:\FlowRunExport\RolesRemoved.csv" `
    -OrgUrl      "https://yourorg.crm.dynamics.com" `
    -FilterUsers "user1@company.com","user2@company.com" `
    -FilterRoles "Salesperson","Customer Service Representative"
```

### Step 4: Verify Restoration

```powershell
.\scripts\5_Verify-RestoredRoles.ps1 `
    -InputCsv "C:\FlowRunExport\RolesRemoved.csv" `
    -OrgUrl   "https://yourorg.crm.dynamics.com"
```

## Important Notes

### Before Restoring

1. **Disable the Power Automate flow** before restoring roles, otherwise it may immediately re-remove them
2. **Review the `RolesRemoved.csv`** to confirm the data looks correct
3. **Run in dry-run mode first** to preview what will be changed
4. **Back up current role assignments** for the affected users

### Handling Edge Cases

- **Users who were intentionally removed**: Filter them out using `-FilterUsers` to exclude specific emails
- **Roles that have been renamed or deleted**: The script uses Role IDs (GUIDs), so renames are handled. Deleted roles will produce errors in the restore log
- **Duplicate assignments**: The restore script automatically deduplicates user-role pairs
- **Already-restored roles**: The script checks if a user already has a role before assigning and skips duplicates

### Rate Limiting

The restore script includes a 200ms delay between API calls to avoid throttling. For large-scale restores (hundreds of assignments), the Dataverse API may still throttle. The script handles this gracefully and logs any errors.

### Stopping the Flow

To prevent the flow from continuing to remove roles while you restore them:

```powershell
# Via Power Automate portal:
# My flows > Select the flow > Turn off

# Or via PowerShell:
Disable-Flow -EnvironmentName "your-env-id" -FlowName "your-flow-id"
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| "Could not obtain an access token" | Run `Connect-AzAccount` or install `MSAL.PS` |
| Empty `RolesRemoved.csv` | Check the `ActionNamePatterns` parameter; your flow may use different action names |
| 403 errors during restore | Ensure you have System Administrator role in D365 |
| Flow run data missing | Power Automate retains run history for 28 days by default |

## File Structure

```
scripts/
  1_Extract-FlowRunHistory.ps1       # Extract via PowerShell modules
  2_Parse-RemovedSecurityRoles.ps1   # Parse JSON to find removals
  3_Restore-SecurityRoles.ps1        # Restore roles (dry-run + live)
  4_Extract-FlowRunHistory-API.ps1   # Extract via REST API (alternative)
  5_Verify-RestoredRoles.ps1         # Verify restoration
```
