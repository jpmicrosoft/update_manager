# Azure Update Manager — Greenfield Configuration Script

Automated end-to-end configuration of Azure Update Manager for patching in **Azure Government** environments. This PowerShell script handles SPN authentication, resource provider registration, Azure Policy assignments, maintenance configuration creation with full patching options, dynamic scoping, and policy remediation — all through an interactive wizard or a JSON config file.

---

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [How-To Guide](#how-to-guide)
  - [Quick Start (Interactive Mode)](#quick-start-interactive-mode)
  - [Non-Interactive Mode (JSON Config)](#non-interactive-mode-json-config)
  - [SPN Authentication](#spn-authentication)
  - [Creating Maintenance Schedules](#creating-maintenance-schedules)
  - [Dynamic Scopes](#dynamic-scopes)
  - [Re-running the Script](#re-running-the-script)
- [Parameter Reference](#parameter-reference)
- [Maintenance Config Options Reference](#maintenance-config-options-reference)
- [JSON Config File Schema](#json-config-file-schema)
- [Examples](#examples)
- [Troubleshooting](#troubleshooting)

---

## Overview

This script configures the following Azure Update Manager components:

1. **Resource Provider Registration** — Registers `Microsoft.Maintenance` and `Microsoft.GuestConfiguration` across all subscriptions under a management group
2. **Azure Policy Assignments** (6 total, per OS):
   - **Periodic Assessment** — Enables automatic checking for missing updates (Windows + Linux)
   - **Patch Mode Prerequisites** — Sets VM patch orchestration to `AutomaticByPlatform` (Windows + Linux)
   - **Schedule Recurring Updates** — Links maintenance configurations to VMs via policy (Windows + Linux)
3. **Maintenance Configurations** — Patch schedules with full control over classifications, KB/package filters, reboot behavior, recurrence, and pre/post tasks
4. **Dynamic Scope Assignments** — Cross-subscription targeting of VMs by subscription, resource group, location, OS type, and tags
5. **Policy Remediation Tasks** — Applies settings to existing non-compliant VMs

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

### Azure Requirements

- **Azure Government subscription(s)** under a management group
- **Service Principal (SPN)** with the following RBAC roles assigned at the **management group** scope:
  - `Contributor` — to create maintenance configs, register providers, manage policy identities
  - `Resource Policy Contributor` — to create and manage policy assignments
- **Management Group** containing the target subscriptions

### Network Requirements

- Outbound connectivity to Azure Government endpoints (`*.usgovcloudapi.net`)
- VMs must have connectivity to Windows Update or Linux package repositories

---

## Installation

Install the required Az PowerShell modules:

```powershell
# Install all required modules
Install-Module -Name Az.Accounts -Force -Scope CurrentUser
Install-Module -Name Az.Resources -Force -Scope CurrentUser
Install-Module -Name Az.Maintenance -Force -Scope CurrentUser

# Verify installation
Get-Module -ListAvailable -Name Az.Accounts, Az.Resources, Az.Maintenance | 
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
.\Configure-AzureUpdateManager.ps1 `
    -TenantId "your-tenant-id" `
    -AppId "your-spn-app-id" `
    -ManagementGroupName "MyManagementGroup" `
    -SubscriptionId "sub-id-for-configs" `
    -ResourceGroupName "rg-update-manager" `
    -Location "usgovvirginia"
```

The script will:
1. Authenticate with your SPN
2. Register resource providers across all subscriptions
3. Launch the **interactive wizard** to build maintenance schedules
4. Create all policies, configs, dynamic scopes, and remediation tasks
5. Print a summary

### Non-Interactive Mode (JSON Config)

For automation or repeatable deployments, provide a JSON config file:

```powershell
.\Configure-AzureUpdateManager.ps1 -ConfigFile ".\my-config.json"
```

See [JSON Config File Schema](#json-config-file-schema) for the full format.

### SPN Authentication

The script authenticates to Azure Government using a Service Principal:

```
Connect-AzAccount -Environment AzureUSGovernment -ServicePrincipal
```

**Required RBAC roles at the management group scope:**

| Role | Purpose |
|---|---|
| `Contributor` | Create maintenance configs, register providers, manage resources |
| `Resource Policy Contributor` | Create/manage policy assignments and remediation tasks |

**To verify your SPN has the right roles:**

```powershell
# Check role assignments
Get-AzRoleAssignment -ServicePrincipalName "your-app-id" `
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
    [2] AlwaysReboot
    [3] NeverReboot
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

### Re-running the Script

The script is **idempotent** — safe to re-run:

- **Maintenance configs**: Checks if a config with the same name exists before creating
- **Policy assignments**: Checks if an assignment with the same name exists before creating
- **Resource providers**: Checks registration state before re-registering
- **Resource group**: Creates only if it doesn't exist

---

## Parameter Reference

| Parameter | Type | Required | Description |
|---|---|---|---|
| `ManagementGroupName` | String | Yes* | Management group name for policy scope |
| `SubscriptionId` | String | Yes* | Subscription ID for maintenance configs |
| `ResourceGroupName` | String | Yes* | Resource group for maintenance configs |
| `TenantId` | String | Yes* | Azure AD tenant ID |
| `AppId` | String | Yes* | SPN Application (Client) ID |
| `AppSecret` | SecureString | Yes* | SPN Client Secret |
| `Location` | String | Yes* | Azure Gov region (e.g., `usgovvirginia`) |
| `ConfigFile` | String | No | Path to JSON config for non-interactive mode |

*\*Prompted interactively if not supplied (unless using `-ConfigFile`)*

---

## Maintenance Config Options Reference

### Maintenance Scopes

| Portal Name | PowerShell Value | Description |
|---|---|---|
| **Guest** | `InGuestPatch` | In-guest OS patching for VMs and Azure Arc-enabled servers via Azure Update Manager. Requires `AutomaticByPlatform` patch orchestration mode. Max window: 3h 55m. Min recurrence: 6 hours. |
| **Host** | `Host` | Platform updates for isolated VMs, isolated VM scale sets, and dedicated hosts. Updates don't require a restart. Min window: 2 hours. Schedules up to 35 days out. |
| **OS image** | `OSImage` | OS image upgrades for VM scale sets with automatic OS upgrades enabled. Min window: 5 hours. Max recurrence: 7 days. |

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
| `AlwaysReboot` | Always reboot after patching |
| `NeverReboot` | Never reboot (patches requiring reboot may not take effect) |

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
  "AppSecret": "your-client-secret-here",
  "Location": "usgovvirginia",
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
| `TenantId` | string | ✓ | Azure AD tenant ID |
| `AppId` | string | ✓ | SPN Application ID |
| `AppSecret` | string | ✓ | SPN Client Secret |
| `Location` | string | ✓ | Azure Gov region |
| `MaintenanceSchedules` | array | ✓ | Array of schedule objects |
| `MaintenanceSchedules[].Name` | string | ✓ | Schedule name |
| `MaintenanceSchedules[].MaintenanceScope` | string | | `InGuestPatch` (default, portal: "Guest"), `Host`, or `OSImage` |
| `MaintenanceSchedules[].OsType` | string | ✓ | `Windows` or `Linux` |
| `MaintenanceSchedules[].Classifications` | string[] | ✓ | Update classifications |
| `MaintenanceSchedules[].KbInclude` | string[] | | KB numbers to include (Windows) |
| `MaintenanceSchedules[].KbExclude` | string[] | | KB numbers to exclude (Windows) |
| `MaintenanceSchedules[].ExcludeKbRequiringReboot` | boolean | | Exclude KBs needing reboot (Windows) |
| `MaintenanceSchedules[].PackageInclude` | string[] | | Package masks to include (Linux) |
| `MaintenanceSchedules[].PackageExclude` | string[] | | Package masks to exclude (Linux) |
| `MaintenanceSchedules[].RebootSetting` | string | ✓ | `IfRequired`, `AlwaysReboot`, `NeverReboot` |
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
# Edit my-config.json with your actual subscription IDs, SPN credentials, etc.

# Run the script
.\Configure-AzureUpdateManager.ps1 -ConfigFile .\my-config.json
```

### Interactive mode example

```powershell
# Run with minimal parameters — the wizard handles the rest
.\Configure-AzureUpdateManager.ps1 `
    -TenantId "your-tenant-id" `
    -AppId "your-app-id" `
    -ManagementGroupName "Contoso-Gov" `
    -SubscriptionId "sub-for-configs" `
    -ResourceGroupName "rg-update-manager" `
    -Location "usgovvirginia"

# The wizard will prompt you to build each maintenance schedule interactively
```

---

## Troubleshooting

### Common Errors

| Error | Cause | Resolution |
|---|---|---|
| `Missing required modules` | Az modules not installed | Run `Install-Module -Name Az.Accounts,Az.Resources,Az.Maintenance -Force` |
| `AADSTS7000215: Invalid client secret` | Wrong or expired SPN secret | Regenerate the SPN secret in Azure AD |
| `AuthorizationFailed` | SPN lacks required RBAC roles | Assign `Contributor` + `Resource Policy Contributor` at management group scope |
| `ResourceProviderNotRegistered` | Provider not registered in subscription | The script handles this automatically; if it persists, manually register via portal |
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
