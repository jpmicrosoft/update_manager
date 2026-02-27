# Azure Update Manager — Greenfield Configuration Script

Automated end-to-end configuration of Azure Update Manager for patching in **Azure Government** and **Azure Commercial** environments. This PowerShell script handles authentication (interactive user or SPN), Azure Policy assignments, maintenance configuration creation with full patching options, dynamic scoping, and managed identity RBAC reporting — all through an interactive wizard or a JSON config file.

---

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [How-To Guide](#how-to-guide)
  - [Quick Start (Interactive Mode)](#quick-start-interactive-mode)
  - [Non-Interactive Mode (JSON Config)](#non-interactive-mode-json-config)
  - [Authentication](#authentication)
  - [Creating Maintenance Schedules](#creating-maintenance-schedules)
  - [Dynamic Scopes](#dynamic-scopes)
  - [Identity Team RBAC Handoff](#identity-team-rbac-handoff)
  - [Running Remediation](#running-remediation)
  - [Re-running the Script](#re-running-the-script)
- [Parameter Reference](#parameter-reference)
- [Maintenance Config Options Reference](#maintenance-config-options-reference)
- [JSON Config File Schema](#json-config-file-schema)
- [Examples](#examples)
- [Troubleshooting](#troubleshooting)

---

## Overview

This script configures the following Azure Update Manager components:

1. **Authentication** — Interactive user login or SPN authentication to Azure Government or Azure Commercial
2. **Resource Provider Registration** *(optional)* — Registers `Microsoft.Maintenance` and `Microsoft.GuestConfiguration` across all subscriptions under a management group
3. **Azure Policy Assignments** (6 total, per OS):
   - **Periodic Assessment** — Enables automatic checking for missing updates (Windows + Linux)
   - **Patch Mode Prerequisites** — Sets VM patch orchestration to `AutomaticByPlatform` (Windows + Linux)
   - **Schedule Recurring Updates** — Links maintenance configurations to VMs via policy (Windows + Linux)
4. **Maintenance Configurations** — Patch schedules with full control over classifications, KB/package filters, reboot behavior, recurrence, and pre/post tasks
5. **Dynamic Scope Assignments** — Cross-subscription targeting of VMs by subscription, resource group, location, OS type, and tags
6. **Identity Report** — Exports managed identity principal IDs and required RBAC for identity team handoff
7. **Policy Remediation Tasks** *(optional)* — Applies settings to existing non-compliant VMs (requires managed identity RBAC first)

---

## Architecture

```
Management Group (policy scope)
├── Subscription A
│   ├── VMs (targeted by dynamic scopes + policies)
│   └── Resource Providers: Microsoft.Maintenance, Microsoft.GuestConfiguration
├── Subscription B
│   └── VMs (targeted by dynamic scopes + policies)
└── Subscription C (hosts maintenance configs)
    └── Resource Group
        ├── Maintenance Config: Patch-Windows-Weekly
        └── Maintenance Config: Patch-Linux-Monthly
```

**Policy flow:**
1. Periodic assessment policy → VMs check for missing updates every 24 hours
2. Prerequisites policy → VMs set to `AutomaticByPlatform` patch mode
3. Schedule policy → VMs linked to maintenance configurations for automated patching
4. Dynamic scopes → Filter which VMs are targeted per maintenance config

---

## Prerequisites

### Required Software

| Component | Minimum Version |
|---|---|
| PowerShell | 7.0+ (recommended) or Windows PowerShell 5.1 |
| Az.Accounts module | 2.0+ |
| Az.Resources module | 6.0+ |
| Az.Maintenance module | 1.0+ |
| Az.PolicyInsights module | 1.0+ |

### Azure Requirements

- **Azure Government or Azure Commercial subscription(s)** under a management group
- **Deploying identity** (user account or SPN) with the following RBAC roles at the **management group** scope:

  | Role | Role Definition ID | Purpose |
  |---|---|---|
  | `Resource Policy Contributor` | `36243c78-bf99-498c-9df9-86d9f8d28608` | Create/manage policy assignments and remediation tasks |
  | `Scheduled Patching Contributor` | `cd08ab90-6b14-449c-ad9a-8f8e549482c6` | Create maintenance configs and dynamic scope assignments |

  > **Note:** If creating a new resource group, the deploying identity also needs `Contributor` (or a role with `Microsoft.Resources/subscriptions/resourceGroups/write`) on the target subscription.

- **Management Group** containing the target subscriptions
- **Post-deployment:** The identity team must assign **Contributor** role to the auto-created policy managed identities (the script outputs the principal IDs). See [Identity Team RBAC Handoff](#identity-team-rbac-handoff).

### Network Requirements

- Outbound connectivity to Azure endpoints (`*.usgovcloudapi.net` for Gov, `*.azure.com` for Commercial)
- VMs must have connectivity to Windows Update or Linux package repositories

---

## Installation

Install the required Az PowerShell modules:

```powershell
# Install all required modules
Install-Module -Name Az.Accounts -Force -Scope CurrentUser
Install-Module -Name Az.Resources -Force -Scope CurrentUser
Install-Module -Name Az.Maintenance -Force -Scope CurrentUser
Install-Module -Name Az.PolicyInsights -Force -Scope CurrentUser

# Verify installation
Get-Module -ListAvailable -Name Az.Accounts, Az.Resources, Az.Maintenance, Az.PolicyInsights | 
    Select-Object Name, Version
```

---

## How-To Guide

### Quick Start (Interactive Mode)

The simplest way to run the script — it will prompt you for everything:

```powershell
.\Configure-AzureUpdateManager.ps1
```

Or provide some parameters upfront and let the wizard handle the rest:

```powershell
# Using interactive user login (Azure Gov)
.\Configure-AzureUpdateManager.ps1 `
    -AzureEnvironment AzureUSGovernment `
    -ManagementGroupName "MyManagementGroup" `
    -SubscriptionId "sub-id-for-configs" `
    -ResourceGroupName "rg-update-manager" `
    -Location "usgovvirginia"

# Using interactive user login (Azure Commercial)
.\Configure-AzureUpdateManager.ps1 `
    -AzureEnvironment AzureCloud `
    -ManagementGroupName "MyManagementGroup" `
    -SubscriptionId "sub-id-for-configs" `
    -ResourceGroupName "rg-update-manager" `
    -Location "eastus"

# Using SPN authentication
.\Configure-AzureUpdateManager.ps1 `
    -AzureEnvironment AzureUSGovernment `
    -TenantId "your-tenant-id" `
    -AppId "your-spn-app-id" `
    -ManagementGroupName "MyManagementGroup" `
    -SubscriptionId "sub-id-for-configs" `
    -ResourceGroupName "rg-update-manager" `
    -Location "usgovvirginia"
```

The script will:
1. Authenticate (browser-based login or SPN)
2. Prompt for resource group handling (create new or use existing)
3. Launch the **interactive wizard** to build maintenance schedules
4. Create all policies, configs, and dynamic scopes
5. Export an identity report (`identity-rbac-report.csv`) for the identity team
6. Print a summary

### Non-Interactive Mode (JSON Config)

For automation or repeatable deployments, provide a JSON config file:

```powershell
.\Configure-AzureUpdateManager.ps1 -ConfigFile ".\my-config.json"
```

See [JSON Config File Schema](#json-config-file-schema) for the full format.

### Authentication

The script supports two authentication methods to Azure Government:

**Option 1 — Interactive User Login (recommended for manual runs):**

The wizard prompts you to choose authentication method. For interactive login, a browser window opens for you to sign in. No SPN credentials needed.

```powershell
.\Configure-AzureUpdateManager.ps1
# Select "Interactive user login (browser-based)" when prompted
```

**Option 2 — Service Principal (recommended for automation):**

```powershell
.\Configure-AzureUpdateManager.ps1 -AzureEnvironment AzureUSGovernment -TenantId "xxx" -AppId "yyy"
# The script prompts for AppSecret securely via Read-Host -AsSecureString

# Or pass AppSecret programmatically (e.g., from a pipeline secret):
$secret = ConvertTo-SecureString "your-secret" -AsPlainText -Force
.\Configure-AzureUpdateManager.ps1 -AzureEnvironment AzureCloud -TenantId "xxx" -AppId "yyy" -AppSecret $secret
```

**Required RBAC roles at the management group scope (both methods):**

| Role | Role Definition ID | Purpose |
|---|---|---|
| `Resource Policy Contributor` | `36243c78-bf99-498c-9df9-86d9f8d28608` | Create/manage policy assignments and remediation tasks |
| `Scheduled Patching Contributor` | `cd08ab90-6b14-449c-ad9a-8f8e549482c6` | Create maintenance configs and dynamic scope assignments |

> **Additional role if creating a new resource group:** `Contributor` on the target subscription (or a role with `Microsoft.Resources/subscriptions/resourceGroups/write`).

**To verify your identity has the right roles:**

```powershell
# For SPN
Get-AzRoleAssignment -ServicePrincipalName "your-app-id" `
    -Scope "/providers/Microsoft.Management/managementGroups/YOUR-MG-NAME"

# For user
Get-AzRoleAssignment -SignInName "user@domain.com" `
    -Scope "/providers/Microsoft.Management/managementGroups/YOUR-MG-NAME"
```

### Creating Maintenance Schedules

The interactive wizard walks you through each schedule step by step:

**Step 1 — Schedule Name:**
```
Enter a name for this maintenance configuration: Patch-Windows-Weekly-Sat
```

**Step 2 — Maintenance Scope:**
```
  Maintenance Scope
  ─────────────────
    [1] Guest (Recommended — in-guest OS patching for VMs via Azure Update Manager)
    [2] Host (Platform updates for isolated VMs, isolated scale sets, dedicated hosts)
    [3] OS image (OS image upgrades for virtual machine scale sets)
    [4] Resource (Network gateways, network security, and other Azure resources)
```

**Step 3 — OS Type:**
```
  Target OS Type
  ──────────────
    [1] Windows
    [2] Linux
```

**Step 4 — Update Classifications (OS-specific multi-select):**

For Windows:
```
  Update Classifications (Windows)
  ────────────────────────────────
    [1] Critical
    [2] Security
    [3] UpdateRollup
    [4] FeaturePack
    [5] ServicePack
    [6] Definition
    [7] Tools
    [8] Updates
    [A] All of the above

  Select options (comma-separated numbers, or 'A' for all): 1,2,3
```

For Linux:
```
  Update Classifications (Linux)
  ──────────────────────────────
    [1] Critical
    [2] Security
    [3] Other
    [A] All of the above
```

**Step 5 — KB/Package Filters (optional):**

Windows:
```
Enter KB numbers to INCLUDE (comma-separated, or press Enter to skip):
Enter KB numbers to EXCLUDE (comma-separated, or press Enter to skip): 5034439
Exclude KBs that require reboot? [y/N]:
```

Linux:
```
Enter package name masks to INCLUDE (comma-separated, or press Enter to skip): kernel,lib
Enter package name masks to EXCLUDE (comma-separated, or press Enter to skip): curl
```

**Step 6 — Reboot Setting:**
```
  Reboot Setting After Patching
  ─────────────────────────────
    [1] IfRequired (Recommended — reboot only when needed)
    [2] Always (reboot after every patch installation)
    [3] Never (do not reboot after patching)
```

**Step 7 — Recurrence:**
```
  Recurrence Pattern
  ──────────────────
    [1] Daily
    [2] Weekly
    [3] Monthly

(Weekly example — select days:)
  Day(s) of Week
  ──────────────
    [1] Monday  [2] Tuesday  [3] Wednesday  [4] Thursday
    [5] Friday  [6] Saturday  [7] Sunday
    [A] All of the above

  Select options: 6

Enter start date and time (YYYY-MM-DD HH:MM): 2026-03-07 02:00
Enter maintenance window duration (HH:MM, e.g., 03:00): 03:00
Enter timezone (e.g., Eastern Standard Time, UTC): Eastern Standard Time
```

**Step 8 — Dynamic Scopes (optional):**
See [Dynamic Scopes](#dynamic-scopes) section below.

**Step 9 — Pre/Post Tasks (optional):**
```
Enter a pre-patching task (script URI or press Enter to skip):
Enter a post-patching task (script URI or press Enter to skip):
```

**The wizard then asks if you want to add another schedule.** Repeat as many times as needed.

### Dynamic Scopes

Dynamic scopes allow a single maintenance configuration to target VMs across multiple subscriptions using filters. The wizard prompts:

```
Would you like to add dynamic scopes for this schedule? [y/N]: y

Enter target subscription ID(s) (comma-separated): sub-id-1,sub-id-2

Filter by resource groups? (comma-separated, or Enter to skip): RG-Prod,RG-Staging

Filter by locations? (comma-separated, or Enter to skip): usgovvirginia

  Filter by OS Type
  ─────────────────
    [1] Windows
    [2] Linux
    [3] Both
    [4] Skip (no OS filter)

Filter by tags? (key=value pairs, comma-separated, or Enter to skip): Environment=Production,PatchGroup=GroupA

  Tag Filter Operator
  ───────────────────
    [1] Any (match any filter)
    [2] All (match all filters)

Add another dynamic scope? [y/N]:
```

**Filter options explained:**

| Filter | Description | Example |
|---|---|---|
| Subscriptions | Which subscriptions to target (required) | `sub-id-1,sub-id-2` |
| Resource Groups | Limit to specific resource groups | `RG-Prod,RG-Staging` |
| Locations | Azure regions | `usgovvirginia,usgovarizona` |
| OS Type | Target Windows, Linux, or both | Selection menu |
| Tags | Key=Value resource tag pairs | `Environment=Production` |
| Tag Operator | `Any` = match any filter; `All` = match all filters | Selection menu |

### Identity Team RBAC Handoff

After the script runs, it generates an **identity report** listing the system-assigned managed identities auto-created by Azure for DINE policy assignments. These identities require **Contributor** role to perform remediation.

The report is:
- **Displayed in the console** with assignment names, principal IDs, and required roles
- **Exported to `identity-rbac-report.csv`** for the identity team

**Sample CSV output:**

| AssignmentName | DisplayName | PrincipalId | RequiredRole | RoleDefinitionId | Scope |
|---|---|---|---|---|---|
| assess-win | Periodic Assessment - Windows | abc123... | Contributor | b24988ac-... | /providers/Microsoft.Management/managementGroups/MyMG |

**Why Contributor?** Microsoft hardcodes the Contributor role (`b24988ac-6180-42a0-ab88-20f7382dd24c`) in the `roleDefinitionIds` field of the DINE policy definitions. This cannot be changed to a lesser role.

**What works before RBAC is assigned:**
- ✅ Policy assignments are created and evaluating compliance
- ✅ Maintenance configurations and dynamic scopes are active
- ❌ Remediation tasks will fail with `AuthorizationFailed`

**After RBAC is assigned:** RBAC propagation typically takes 5–10 minutes (up to 30 minutes). After propagation, re-run with `-RunRemediation` or trigger remediation from the portal.

### Running Remediation

Remediation is **skipped by default** because the managed identities need RBAC first. After the identity team assigns Contributor:

```powershell
# Re-run with remediation enabled
.\Configure-AzureUpdateManager.ps1 -ConfigFile ".\my-config.json" -RunRemediation

# Or trigger remediation from the Azure portal:
# Policy → Assignments → select assignment → Create Remediation Task
```

### Re-running the Script

The script is **idempotent** — safe to re-run:

- **Maintenance configs**: Checks if a config with the same name exists before creating
- **Policy assignments**: Checks if an assignment with the same name exists before creating
- **Resource providers**: Checks registration state before re-registering (when `-RegisterProviders` is used)
- **Resource group**: Validates existing RG or creates new (based on wizard/config choice)

---

## Parameter Reference

| Parameter | Type | Required | Description |
|---|---|---|---|
| `ManagementGroupName` | String | Yes* | Management group name for policy scope |
| `SubscriptionId` | String | Yes* | Subscription ID for maintenance configs |
| `ResourceGroupName` | String | Yes* | Resource group for maintenance configs |
| `TenantId` | String | No* | Azure AD tenant ID (required for SPN, optional for user login) |
| `AppId` | String | No* | SPN Application (Client) ID (omit for user login) |
| `AppSecret` | SecureString | No* | SPN Client Secret (omit for user login) |
| `Location` | String | Yes* | Azure region (e.g., `usgovvirginia`, `eastus`) |
| `AzureEnvironment` | String | Yes* | `AzureUSGovernment` or `AzureCloud` |
| `ConfigFile` | String | No | Path to JSON config for non-interactive mode |
| `RegisterProviders` | Switch | No | Enable resource provider registration across subscriptions |
| `RunRemediation` | Switch | No | Trigger policy remediation tasks (requires managed identity RBAC) |

*\*Prompted interactively if not supplied (unless using `-ConfigFile`)*

---

## Maintenance Config Options Reference

### Maintenance Scopes

| Portal Name | PowerShell Value | Description |
|---|---|---|
| **Guest** | `InGuestPatch` | In-guest OS patching for VMs and Azure Arc-enabled servers via Azure Update Manager. Requires `AutomaticByPlatform` patch orchestration mode. Max window: 3h 55m. Min recurrence: 6 hours. |
| **Host** | `Host` | Platform updates for isolated VMs, isolated VM scale sets, and dedicated hosts. Updates don't require a restart. Min window: 2 hours. Schedules up to 35 days out. |
| **OS image** | `OSImage` | OS image upgrades for VM scale sets with automatic OS upgrades enabled. Min window: 5 hours. Max recurrence: 7 days. |
| **Resource** | `Resource` | Maintenance windows for network gateways (VPN Gateway, ExpressRoute), network security, and other Azure resources. Min window: 5 hours. |

### Update Classifications

| Classification | Windows | Linux | Description |
|---|:---:|:---:|---|
| Critical | ✓ | ✓ | High-impact reliability/security fixes |
| Security | ✓ | ✓ | CVE/vulnerability patches |
| UpdateRollup | ✓ | | Cumulative update bundles |
| FeaturePack | ✓ | | New feature additions |
| ServicePack | ✓ | | Collections of cumulative fixes |
| Definition | ✓ | | Anti-malware signature updates |
| Tools | ✓ | | Utility/tool updates |
| Updates | ✓ | | General updates |
| Other | | ✓ | Non-critical, non-security updates |

### Reboot Settings

| Setting | Description |
|---|---|
| `IfRequired` | Reboot only when an update requires it (recommended) |
| `Always` | Always reboot after patching |
| `Never` | Never reboot (patches requiring reboot may not take effect) |

### Recurrence Patterns

| Pattern | Format | Example |
|---|---|---|
| Daily | `Day` | Every day |
| Weekly | `Week <days>` | `Week Saturday` or `Week Monday,Wednesday` |
| Monthly | `Month <week> <day>` | `Month Third Saturday` or `Month Last Friday` |

### Dynamic Scope Filters

| Filter | Required | Description |
|---|:---:|---|
| Subscriptions | ✓ | Target subscription IDs |
| ResourceGroups | | Limit to specific resource groups |
| Locations | | Azure regions (e.g., `usgovvirginia`) |
| OsTypes | | `Windows`, `Linux`, or both |
| Tags | | Key=Value resource tag pairs |
| TagOperator | | `Any` (default) or `All` |

---

## JSON Config File Schema

Full example for non-interactive mode:

```json
{
  "ManagementGroupName": "MyManagementGroup",
  "SubscriptionId": "00000000-0000-0000-0000-000000000001",
  "ResourceGroupName": "rg-update-manager",
  "TenantId": "00000000-0000-0000-0000-000000000002",
  "AppId": "00000000-0000-0000-0000-000000000003",
  "AppSecret": "<YOUR_CLIENT_SECRET>",
  "Location": "usgovvirginia",
  "AzureEnvironment": "AzureUSGovernment",
  "CreateResourceGroup": false,
  "RegisterProviders": false,
  "RunRemediation": false,
  "MaintenanceSchedules": [
    {
      "Name": "Patch-Windows-Weekly-Sat",
      "MaintenanceScope": "InGuestPatch",
      "OsType": "Windows",
      "Classifications": ["Critical", "Security", "UpdateRollup"],
      "KbInclude": [],
      "KbExclude": ["5034439"],
      "ExcludeKbRequiringReboot": false,
      "RebootSetting": "IfRequired",
      "RecurEvery": "Week Saturday",
      "StartDateTime": "2026-03-07 02:00",
      "Duration": "03:00",
      "Timezone": "Eastern Standard Time",
      "PreTask": "",
      "PostTask": "",
      "DynamicScopes": [
        {
          "Subscriptions": [
            "00000000-0000-0000-0000-000000000010",
            "00000000-0000-0000-0000-000000000011"
          ],
          "ResourceGroups": ["RG-Prod"],
          "Locations": ["usgovvirginia"],
          "OsTypes": ["Windows"],
          "Tags": {
            "Environment": ["Production"],
            "PatchGroup": ["GroupA"]
          },
          "TagOperator": "Any"
        }
      ]
    },
    {
      "Name": "Patch-Linux-Monthly-3rdSat",
      "MaintenanceScope": "InGuestPatch",
      "OsType": "Linux",
      "Classifications": ["Critical", "Security", "Other"],
      "PackageInclude": ["kernel", "lib"],
      "PackageExclude": ["curl"],
      "RebootSetting": "IfRequired",
      "RecurEvery": "Month Third Saturday",
      "StartDateTime": "2026-03-21 03:00",
      "Duration": "02:00",
      "Timezone": "UTC",
      "DynamicScopes": [
        {
          "Subscriptions": [
            "00000000-0000-0000-0000-000000000010"
          ],
          "OsTypes": ["Linux"],
          "Tags": {
            "Environment": ["Production", "Staging"]
          },
          "TagOperator": "All"
        }
      ]
    }
  ]
}
```

### JSON Field Reference

| Field | Type | Required | Description |
|---|---|:---:|---|
| `ManagementGroupName` | string | ✓ | Management group name |
| `SubscriptionId` | string | ✓ | Subscription for maintenance configs |
| `ResourceGroupName` | string | ✓ | Resource group for maintenance configs |
| `TenantId` | string | | Azure AD tenant ID (required for SPN auth) |
| `AppId` | string | | SPN Application ID (omit for user login) |
| `AppSecret` | string | | SPN Client Secret (omit for user login) |
| `Location` | string | ✓ | Azure region |
| `AzureEnvironment` | string | | `AzureUSGovernment` (default) or `AzureCloud` |
| `CreateResourceGroup` | boolean | | `true` to create RG, `false` to use existing (default: `false`) |
| `RegisterProviders` | boolean | | Enable resource provider registration (default: `false`) |
| `RunRemediation` | boolean | | Trigger policy remediation tasks (default: `false`) |
| `MaintenanceSchedules` | array | ✓ | Array of schedule objects |
| `MaintenanceSchedules[].Name` | string | ✓ | Schedule name |
| `MaintenanceSchedules[].MaintenanceScope` | string | | `InGuestPatch` (default, portal: "Guest"), `Host`, `OSImage`, or `Resource` |
| `MaintenanceSchedules[].OsType` | string | ✓ | `Windows` or `Linux` |
| `MaintenanceSchedules[].Classifications` | string[] | ✓ | Update classifications |
| `MaintenanceSchedules[].KbInclude` | string[] | | KB numbers to include (Windows) |
| `MaintenanceSchedules[].KbExclude` | string[] | | KB numbers to exclude (Windows) |
| `MaintenanceSchedules[].ExcludeKbRequiringReboot` | boolean | | Exclude KBs needing reboot (Windows) |
| `MaintenanceSchedules[].PackageInclude` | string[] | | Package masks to include (Linux) |
| `MaintenanceSchedules[].PackageExclude` | string[] | | Package masks to exclude (Linux) |
| `MaintenanceSchedules[].RebootSetting` | string | ✓ | `IfRequired`, `Always`, `Never` |
| `MaintenanceSchedules[].RecurEvery` | string | ✓ | Recurrence pattern |
| `MaintenanceSchedules[].StartDateTime` | string | ✓ | `YYYY-MM-DD HH:MM` |
| `MaintenanceSchedules[].Duration` | string | ✓ | `HH:MM` |
| `MaintenanceSchedules[].Timezone` | string | ✓ | Windows timezone name |
| `MaintenanceSchedules[].PreTask` | string | | Pre-patching script URI |
| `MaintenanceSchedules[].PostTask` | string | | Post-patching script URI |
| `MaintenanceSchedules[].DynamicScopes` | array | | Dynamic scope definitions |

---

## Examples

The `examples/` folder contains ready-to-use JSON config files:

| File | Description |
|---|---|
| [`config-basic.json`](examples/config-basic.json) | Minimal setup — one Windows + one Linux weekly schedule with production tag filtering |
| [`config-advanced.json`](examples/config-advanced.json) | Multi-environment setup — 4 schedules (Prod + Dev/Test × Windows + Linux) with per-environment dynamic scopes, KB exclusions, package filters, pre/post tasks, and mixed recurrence patterns |

### Running with an example config

```powershell
# Copy and edit the example
Copy-Item .\examples\config-basic.json .\my-config.json
# Edit my-config.json with your actual subscription IDs, etc.

# Run with interactive user login (no SPN fields needed in config)
.\Configure-AzureUpdateManager.ps1 -ConfigFile .\my-config.json

# Run with optional provider registration
.\Configure-AzureUpdateManager.ps1 -ConfigFile .\my-config.json -RegisterProviders
```

### Interactive mode example

```powershell
# Run with no parameters — the wizard handles everything
.\Configure-AzureUpdateManager.ps1

# Or provide parameters to skip some prompts
.\Configure-AzureUpdateManager.ps1 `
    -ManagementGroupName "Contoso-Gov" `
    -SubscriptionId "sub-for-configs" `
    -ResourceGroupName "rg-update-manager" `
    -Location "usgovvirginia"

# The wizard will prompt for auth method, RG handling, and maintenance schedules
```

---

## Troubleshooting

### Common Errors

| Error | Cause | Resolution |
|---|---|---|
| `Missing required modules` | Az modules not installed | Run `Install-Module -Name Az.Accounts,Az.Resources,Az.Maintenance,Az.PolicyInsights -Force` |
| `AADSTS7000215: Invalid client secret` | Wrong or expired SPN secret | Regenerate the SPN secret in Entra ID |
| `AuthorizationFailed` on deployment | Deploying identity lacks RBAC | Assign `Resource Policy Contributor` + `Scheduled Patching Contributor` at management group scope |
| `AuthorizationFailed` on remediation | Policy managed identities lack RBAC | Identity team must assign `Contributor` to managed identities (see `identity-rbac-report.csv`) |
| `Resource group does not exist` | RG not found and `CreateResourceGroup` is false | Use an existing RG name or select "Create a new resource group" in the wizard |
| `ResourceProviderNotRegistered` | Provider not registered in subscription | Use `-RegisterProviders` switch or manually register via portal |
| `PolicyAssignmentNotFound` | Policy definition ID changed | The script uses well-known built-in IDs; verify they exist in Azure Gov |
| `MaintenanceConfigurationAlreadyExists` | Config already created | The script is idempotent — it skips existing configs |
| `InvalidMaintenanceScope` | Wrong scope parameter | Ensure `-MaintenanceScope InGuestPatch` is used |

### Logging

The script outputs timestamped, color-coded log messages:
- 🔵 **INFO** (Cyan) — Progress updates
- 🟡 **WARN** (Yellow) — Non-fatal issues
- 🔴 **ERROR** (Red) — Failures
- 🟢 **SUCCESS** (Green) — Completed operations

### Verifying the Configuration

After running the script, verify in the Azure Government portal:

1. **Policy → Assignments** — Check 6 policy assignments at the management group scope
2. **Update Manager → Maintenance Configurations** — Verify schedules and dynamic scopes
3. **Policy → Remediation** — Check remediation task status
4. **Subscriptions → Resource Providers** — Confirm `Microsoft.Maintenance` is registered
