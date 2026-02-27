<#
.SYNOPSIS
    Configures Azure Update Manager for patching in a greenfield Azure Government environment.

.DESCRIPTION
    This script performs end-to-end configuration of Azure Update Manager including:
    - Authentication to Azure Government (interactive user login or SPN)
    - Optional resource provider registration across subscriptions under a management group
    - Azure Policy assignments (periodic assessment, patch mode prerequisites, scheduled updates) per OS
    - Maintenance configuration creation with full options (classifications, KB/package filters, reboot, pre/post tasks)
    - Dynamic scope assignments for cross-subscription patching
    - Identity report for managed identity RBAC handoff to identity team
    - Optional policy remediation tasks for existing non-compliant VMs
    
    Supports two modes:
    - Interactive wizard (default): Guides the user through menus for each setting
    - Non-interactive: All settings provided via a JSON config file (-ConfigFile parameter)

.PARAMETER ManagementGroupName
    Name of the management group for policy assignments. Prompted if not supplied.

.PARAMETER SubscriptionId
    Subscription ID hosting the maintenance configurations. Prompted if not supplied.

.PARAMETER ResourceGroupName
    Resource group name for maintenance configurations. Prompted if not supplied.

.PARAMETER TenantId
    Azure AD tenant ID. Prompted if not supplied.

.PARAMETER AppId
    SPN Application (client) ID. Required only when using SPN authentication.

.PARAMETER AppSecret
    SPN client secret as a SecureString. Required only when using SPN authentication.

.PARAMETER Location
    Azure region for maintenance configurations (e.g., usgovvirginia). Prompted if not supplied.

.PARAMETER ConfigFile
    Optional path to a JSON configuration file for non-interactive mode.

.PARAMETER RegisterProviders
    Switch to enable resource provider registration (Microsoft.Maintenance, Microsoft.GuestConfiguration)
    across all subscriptions under the management group. Skipped by default.

.PARAMETER RunRemediation
    Switch to trigger policy remediation tasks after assignments are created.
    Skipped by default because managed identity RBAC must be assigned first by the identity team.

.EXAMPLE
    # Interactive mode with user login
    .\Configure-AzureUpdateManager.ps1

.EXAMPLE
    # Interactive mode with SPN
    .\Configure-AzureUpdateManager.ps1 -TenantId "xxx" -AppId "yyy"

.EXAMPLE
    # Non-interactive mode
    .\Configure-AzureUpdateManager.ps1 -ConfigFile ".\config.json"

.EXAMPLE
    # With optional provider registration and remediation
    .\Configure-AzureUpdateManager.ps1 -RegisterProviders -RunRemediation
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$ManagementGroupName,

    [Parameter()]
    [string]$SubscriptionId,

    [Parameter()]
    [string]$ResourceGroupName,

    [Parameter()]
    [string]$TenantId,

    [Parameter()]
    [string]$AppId,

    [Parameter()]
    [System.Security.SecureString]$AppSecret,

    [Parameter()]
    [string]$Location,

    [Parameter()]
    [string]$ConfigFile,

    [Parameter()]
    [switch]$RegisterProviders,

    [Parameter()]
    [switch]$RunRemediation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#region ── Helper Functions ──

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO","WARN","ERROR","SUCCESS")]
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "INFO"    { "Cyan" }
        "WARN"    { "Yellow" }
        "ERROR"   { "Red" }
        "SUCCESS" { "Green" }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

function Show-Banner {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║       Azure Update Manager — Greenfield Configuration       ║" -ForegroundColor Cyan
    Write-Host "║                    Azure Government                         ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
}

function Show-Menu {
    param(
        [string]$Title,
        [string[]]$Options,
        [string]$Prompt = "Select an option"
    )
    Write-Host ""
    Write-Host "  $Title" -ForegroundColor Yellow
    Write-Host "  $('-' * $Title.Length)" -ForegroundColor DarkGray
    for ($i = 0; $i -lt $Options.Count; $i++) {
        Write-Host "    [$($i + 1)] $($Options[$i])"
    }
    Write-Host ""
    do {
        $input_val = Read-Host "  $Prompt"
        $selection = 0
        if ([int]::TryParse($input_val, [ref]$selection) -and $selection -ge 1 -and $selection -le $Options.Count) {
            return $selection
        }
        Write-Host "  Invalid selection. Please enter a number between 1 and $($Options.Count)." -ForegroundColor Red
    } while ($true)
}

function Read-MultiSelect {
    param(
        [string]$Title,
        [string[]]$Options,
        [string]$Prompt = "Select options (comma-separated numbers, or 'A' for all)"
    )
    Write-Host ""
    Write-Host "  $Title" -ForegroundColor Yellow
    Write-Host "  $('-' * $Title.Length)" -ForegroundColor DarkGray
    for ($i = 0; $i -lt $Options.Count; $i++) {
        Write-Host "    [$($i + 1)] $($Options[$i])"
    }
    Write-Host "    [A] All of the above"
    Write-Host ""
    do {
        $input_val = Read-Host "  $Prompt"
        if ($input_val -eq 'A' -or $input_val -eq 'a') {
            return $Options
        }
        $indices = $input_val -split ',' | ForEach-Object { $_.Trim() }
        $selected = @()
        $valid = $true
        foreach ($idx in $indices) {
            $num = 0
            if ([int]::TryParse($idx, [ref]$num) -and $num -ge 1 -and $num -le $Options.Count) {
                $selected += $Options[$num - 1]
            } else {
                $valid = $false
                break
            }
        }
        if ($valid -and $selected.Count -gt 0) {
            return $selected
        }
        Write-Host "  Invalid selection. Use comma-separated numbers (1-$($Options.Count)) or 'A' for all." -ForegroundColor Red
    } while ($true)
}

function Read-OptionalInput {
    param(
        [string]$Prompt,
        [string]$Default = ""
    )
    $val = Read-Host "  $Prompt"
    if ([string]::IsNullOrWhiteSpace($val)) { return $Default }
    return $val.Trim()
}

function Read-RequiredInput {
    param([string]$Prompt)
    do {
        $val = Read-Host "  $Prompt"
        if (-not [string]::IsNullOrWhiteSpace($val)) { return $val.Trim() }
        Write-Host "  This field is required." -ForegroundColor Red
    } while ($true)
}

function Read-YesNo {
    param(
        [string]$Prompt,
        [bool]$Default = $false
    )
    $defaultHint = if ($Default) { "[Y/n]" } else { "[y/N]" }
    do {
        $val = Read-Host "  $Prompt $defaultHint"
        if ([string]::IsNullOrWhiteSpace($val)) { return $Default }
        if ($val -match '^[Yy]') { return $true }
        if ($val -match '^[Nn]') { return $false }
        Write-Host "  Please enter Y or N." -ForegroundColor Red
    } while ($true)
}

function Read-CommaSeparated {
    param(
        [string]$Prompt
    )
    $val = Read-Host "  $Prompt"
    if ([string]::IsNullOrWhiteSpace($val)) { return @() }
    return ($val -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}

#endregion

#region ── Module Checks ──

function Assert-RequiredModules {
    $requiredModules = @('Az.Accounts', 'Az.Resources', 'Az.Maintenance', 'Az.PolicyInsights')
    $missing = @()
    foreach ($mod in $requiredModules) {
        if (-not (Get-Module -ListAvailable -Name $mod)) {
            $missing += $mod
        }
    }
    if ($missing.Count -gt 0) {
        Write-Log "Missing required PowerShell modules: $($missing -join ', ')" -Level ERROR
        Write-Log "Install them with: Install-Module -Name $($missing -join ',') -Force -Scope CurrentUser" -Level ERROR
        throw "Missing required modules: $($missing -join ', ')"
    }
    foreach ($mod in $requiredModules) {
        Import-Module $mod -ErrorAction Stop
    }
    Write-Log "All required modules loaded: $($requiredModules -join ', ')" -Level SUCCESS
}

#endregion

#region ── Authentication ──

function Connect-AzureGov {
    param(
        [string]$TenantId,
        [string]$AppId,
        [System.Security.SecureString]$AppSecret
    )

    if ($AppId -and $AppSecret) {
        if (-not $TenantId) {
            throw "TenantId is required when using SPN authentication."
        }
        Write-Log "Authenticating to Azure Government with SPN..."
        $credential = New-Object System.Management.Automation.PSCredential($AppId, $AppSecret)
        $connectParams = @{
            Environment      = 'AzureUSGovernment'
            ServicePrincipal = $true
            TenantId         = $TenantId
            Credential       = $credential
            WarningAction    = 'SilentlyContinue'
        }
        Connect-AzAccount @connectParams | Out-Null
    } else {
        Write-Log "Authenticating to Azure Government with interactive user login..."
        $connectParams = @{
            Environment   = 'AzureUSGovernment'
            WarningAction = 'SilentlyContinue'
        }
        if ($TenantId) { $connectParams['TenantId'] = $TenantId }
        Connect-AzAccount @connectParams | Out-Null
    }

    $ctx = Get-AzContext
    Write-Log "Authenticated as '$($ctx.Account.Id)' in tenant '$($ctx.Tenant.Id)'" -Level SUCCESS
}

#endregion

#region ── Resource Provider Registration ──

function Register-RequiredProviders {
    param([string]$ManagementGroupName)

    Write-Log "Enumerating subscriptions under management group '$ManagementGroupName'..."
    $mgSubs = Get-AzManagementGroupSubscription -GroupId $ManagementGroupName -ErrorAction Stop
    $subIds = $mgSubs | ForEach-Object {
        if ($_.Id -match '/subscriptions/(.+)$') { $Matches[1] }
    }

    if ($subIds.Count -eq 0) {
        Write-Log "No subscriptions found under management group '$ManagementGroupName'." -Level WARN
        return @()
    }

    Write-Log "Found $($subIds.Count) subscription(s). Registering resource providers..."
    $providers = @('Microsoft.Maintenance', 'Microsoft.GuestConfiguration')
    $results = @()

    foreach ($subId in $subIds) {
        try {
            Set-AzContext -SubscriptionId $subId -WarningAction SilentlyContinue | Out-Null
            foreach ($provider in $providers) {
                $reg = Get-AzResourceProvider -ProviderNamespace $provider -ErrorAction SilentlyContinue
                if ($reg.RegistrationState -eq 'Registered') {
                    Write-Log "  [$subId] $provider already registered." -Level INFO
                } else {
                    Register-AzResourceProvider -ProviderNamespace $provider | Out-Null
                    Write-Log "  [$subId] $provider registration initiated." -Level INFO
                }
                $results += [PSCustomObject]@{
                    SubscriptionId = $subId
                    Provider       = $provider
                    Status         = "Initiated"
                }
            }
        } catch {
            Write-Log "  [$subId] Failed to register providers: $_" -Level ERROR
            $results += [PSCustomObject]@{
                SubscriptionId = $subId
                Provider       = "ALL"
                Status         = "FAILED: $_"
            }
        }
    }

    # Wait for registration to complete
    Write-Log "Waiting for resource provider registrations to complete..."
    $maxWait = 300  # seconds
    $interval = 15
    $elapsed = 0
    $allRegistered = $false

    while (-not $allRegistered -and $elapsed -lt $maxWait) {
        Start-Sleep -Seconds $interval
        $elapsed += $interval
        $allRegistered = $true

        foreach ($subId in $subIds) {
            Set-AzContext -SubscriptionId $subId -WarningAction SilentlyContinue | Out-Null
            foreach ($provider in $providers) {
                $reg = Get-AzResourceProvider -ProviderNamespace $provider -ErrorAction SilentlyContinue
                if ($reg.RegistrationState -ne 'Registered') {
                    $allRegistered = $false
                }
            }
        }
        if (-not $allRegistered) {
            Write-Log "  Still waiting... ($elapsed/$maxWait seconds)" -Level INFO
        }
    }

    if ($allRegistered) {
        Write-Log "All resource providers registered successfully." -Level SUCCESS
    } else {
        Write-Log "Some resource providers did not complete registration within $maxWait seconds. They may still be registering." -Level WARN
    }

    return $results
}

#endregion

#region ── Interactive Wizard ──

function New-ScheduleWizard {
    $schedules = @()

    do {
        Write-Host ""
        Write-Host "  ═══════════════════════════════════════" -ForegroundColor Cyan
        Write-Host "      New Maintenance Schedule Wizard     " -ForegroundColor Cyan
        Write-Host "  ═══════════════════════════════════════" -ForegroundColor Cyan

        $schedule = @{}

        # Step 1: Name
        $schedule.Name = Read-RequiredInput "Enter a name for this maintenance configuration"

        # Step 2: Maintenance Scope
        $scopeChoice = Show-Menu -Title "Maintenance Scope" -Options @(
            "Guest (Recommended — in-guest OS patching for VMs via Azure Update Manager)",
            "Host (Platform updates for isolated VMs, isolated scale sets, dedicated hosts)",
            "OS image (OS image upgrades for virtual machine scale sets)",
            "Resource (Network gateways, network security, and other Azure resources)"
        )
        $schedule.MaintenanceScope = @("InGuestPatch", "Host", "OSImage", "Resource")[$scopeChoice - 1]

        # Steps 3-6 are only relevant for InGuestPatch scope
        if ($schedule.MaintenanceScope -eq "InGuestPatch") {
            # Step 3: OS Type
            $osChoice = Show-Menu -Title "Target OS Type" -Options @("Windows", "Linux")
            $schedule.OsType = @("Windows", "Linux")[$osChoice - 1]

            # Step 4: Classifications
            if ($schedule.OsType -eq "Windows") {
                $winClassifications = @("Critical", "Security", "UpdateRollup", "FeaturePack", "ServicePack", "Definition", "Tools", "Updates")
                $schedule.Classifications = Read-MultiSelect -Title "Update Classifications (Windows)" -Options $winClassifications
            } else {
                $linuxClassifications = @("Critical", "Security", "Other")
                $schedule.Classifications = Read-MultiSelect -Title "Update Classifications (Linux)" -Options $linuxClassifications
            }

            # Step 5: KB / Package Filters
            if ($schedule.OsType -eq "Windows") {
                $schedule.KbInclude = Read-CommaSeparated "Enter KB numbers to INCLUDE (comma-separated, or press Enter to skip)"
                $schedule.KbExclude = Read-CommaSeparated "Enter KB numbers to EXCLUDE (comma-separated, or press Enter to skip)"
                $schedule.ExcludeKbRequiringReboot = Read-YesNo "Exclude KBs that require reboot?"
            } else {
                $schedule.PackageInclude = Read-CommaSeparated "Enter package name masks to INCLUDE (comma-separated, or press Enter to skip)"
                $schedule.PackageExclude = Read-CommaSeparated "Enter package name masks to EXCLUDE (comma-separated, or press Enter to skip)"
            }

            # Step 6: Reboot Setting
            $rebootChoice = Show-Menu -Title "Reboot Setting After Patching" -Options @(
                "IfRequired (Recommended — reboot only when needed)",
                "Always (reboot after every patch installation)",
                "Never (do not reboot after patching)"
            )
            $schedule.RebootSetting = @("IfRequired", "Always", "Never")[$rebootChoice - 1]
        } else {
            Write-Host ""
            Write-Host "  Note: Scope '$($schedule.MaintenanceScope)' does not use OS patching options" -ForegroundColor DarkGray
            Write-Host "  (classifications, KB/package filters, and reboot settings are skipped)." -ForegroundColor DarkGray
            $schedule.OsType = "Windows"  # default; not used for non-InGuestPatch scopes
            $schedule.Classifications = @()
            $schedule.RebootSetting = "IfRequired"
        }

        # Step 7: Recurrence
        $recurChoice = Show-Menu -Title "Recurrence Pattern" -Options @("Daily", "Weekly", "Monthly")
        switch ($recurChoice) {
            1 { $schedule.RecurEvery = "Day" }
            2 {
                $days = Read-MultiSelect -Title "Day(s) of Week" -Options @(
                    "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"
                )
                $schedule.RecurEvery = "Week $($days -join ',')"
            }
            3 {
                $weekChoice = Show-Menu -Title "Week of Month" -Options @("First", "Second", "Third", "Fourth", "Last")
                $weekName = @("First", "Second", "Third", "Fourth", "Last")[$weekChoice - 1]
                $dayChoice = Show-Menu -Title "Day of Week" -Options @(
                    "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"
                )
                $dayName = @("Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday")[$dayChoice - 1]
                $schedule.RecurEvery = "Month $weekName $dayName"
            }
        }

        $schedule.StartDateTime = Read-RequiredInput "Enter start date and time (YYYY-MM-DD HH:MM)"
        $schedule.Duration = Read-RequiredInput "Enter maintenance window duration (HH:MM, e.g., 03:00)"
        $schedule.Timezone = Read-RequiredInput "Enter timezone (e.g., Eastern Standard Time, UTC)"

        # Step 8: Dynamic Scopes
        $schedule.DynamicScopes = @()
        if (Read-YesNo "Would you like to add dynamic scopes for this schedule?") {
            do {
                $scope = @{}
                $scope.Subscriptions = Read-CommaSeparated "Enter target subscription ID(s) (comma-separated)"
                if ($scope.Subscriptions.Count -eq 0) {
                    Write-Host "  At least one subscription ID is required for a dynamic scope." -ForegroundColor Red
                    continue
                }
                $scope.ResourceGroups = Read-CommaSeparated "Filter by resource groups? (comma-separated, or Enter to skip)"
                $scope.Locations = Read-CommaSeparated "Filter by locations? (comma-separated, or Enter to skip)"

                $osFilterChoice = Show-Menu -Title "Filter by OS Type" -Options @("Windows", "Linux", "Both", "Skip (no OS filter)")
                switch ($osFilterChoice) {
                    1 { $scope.OsTypes = @("Windows") }
                    2 { $scope.OsTypes = @("Linux") }
                    3 { $scope.OsTypes = @("Windows", "Linux") }
                    4 { $scope.OsTypes = @() }
                }

                $tagInput = Read-CommaSeparated "Filter by tags? (key=value pairs, comma-separated, or Enter to skip)"
                $scope.Tags = @{}
                foreach ($pair in $tagInput) {
                    if ($pair -match '^(.+?)=(.+)$') {
                        $key = $Matches[1].Trim()
                        $val = $Matches[2].Trim()
                        if ($scope.Tags.ContainsKey($key)) {
                            $scope.Tags[$key] += $val
                        } else {
                            $scope.Tags[$key] = @($val)
                        }
                    }
                }

                if ($scope.Tags.Count -gt 0) {
                    $opChoice = Show-Menu -Title "Tag Filter Operator" -Options @("Any (match any filter)", "All (match all filters)")
                    $scope.TagOperator = @("Any", "All")[$opChoice - 1]
                } else {
                    $scope.TagOperator = "Any"
                }

                $schedule.DynamicScopes += $scope
            } while (Read-YesNo "Add another dynamic scope?")
        } else {
            Write-Host ""
            Write-Host "  ⚠  No dynamic scope selected. VMs must be assigned to this maintenance" -ForegroundColor Yellow
            Write-Host "     configuration manually (static assignment) via the Azure portal, CLI," -ForegroundColor Yellow
            Write-Host "     or a separate script before patching will occur." -ForegroundColor Yellow
            Write-Host ""
        }

        # Step 9: Pre/Post Tasks
        $schedule.PreTask = Read-OptionalInput "Enter a pre-patching task (script URI or press Enter to skip)"
        $schedule.PostTask = Read-OptionalInput "Enter a post-patching task (script URI or press Enter to skip)"

        $schedules += $schedule

        Write-Log "Schedule '$($schedule.Name)' ($($schedule.OsType)) configured." -Level SUCCESS

    } while (Read-YesNo "Add another maintenance schedule?" -Default $false)

    return $schedules
}

#endregion

#region ── Config File Mode ──

function Import-ConfigFile {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        throw "Config file not found: $Path"
    }

    Write-Log "Loading configuration from '$Path'..."
    $config = Get-Content -Path $Path -Raw | ConvertFrom-Json -ErrorAction Stop

    # Validate required top-level fields
    $required = @('ManagementGroupName', 'SubscriptionId', 'ResourceGroupName', 'Location', 'MaintenanceSchedules')
    foreach ($field in $required) {
        if (-not $config.PSObject.Properties[$field]) {
            throw "Config file missing required field: '$field'"
        }
    }

    if ($config.MaintenanceSchedules.Count -eq 0) {
        throw "Config file must contain at least one entry in 'MaintenanceSchedules'."
    }

    # Convert JSON objects to hashtable-friendly format for schedules
    $schedules = @()
    foreach ($s in $config.MaintenanceSchedules) {
        $schedule = @{
            Name              = $s.Name
            MaintenanceScope  = if ($s.PSObject.Properties['MaintenanceScope']) { $s.MaintenanceScope } else { "InGuestPatch" }
            OsType            = $s.OsType
            Classifications   = @($s.Classifications)
            RebootSetting     = $s.RebootSetting
            RecurEvery        = $s.RecurEvery
            StartDateTime     = $s.StartDateTime
            Duration          = $s.Duration
            Timezone          = $s.Timezone
            PreTask           = if ($s.PSObject.Properties['PreTask']) { $s.PreTask } else { "" }
            PostTask          = if ($s.PSObject.Properties['PostTask']) { $s.PostTask } else { "" }
            DynamicScopes     = @()
        }

        # OS-specific filters
        if ($s.OsType -eq "Windows") {
            $schedule.KbInclude = if ($s.PSObject.Properties['KbInclude']) { @($s.KbInclude) } else { @() }
            $schedule.KbExclude = if ($s.PSObject.Properties['KbExclude']) { @($s.KbExclude) } else { @() }
            $schedule.ExcludeKbRequiringReboot = if ($s.PSObject.Properties['ExcludeKbRequiringReboot']) { $s.ExcludeKbRequiringReboot } else { $false }
        } else {
            $schedule.PackageInclude = if ($s.PSObject.Properties['PackageInclude']) { @($s.PackageInclude) } else { @() }
            $schedule.PackageExclude = if ($s.PSObject.Properties['PackageExclude']) { @($s.PackageExclude) } else { @() }
        }

        # Dynamic scopes
        if ($s.PSObject.Properties['DynamicScopes']) {
            foreach ($ds in $s.DynamicScopes) {
                $scope = @{
                    Subscriptions  = @($ds.Subscriptions)
                    ResourceGroups = if ($ds.PSObject.Properties['ResourceGroups']) { @($ds.ResourceGroups) } else { @() }
                    Locations      = if ($ds.PSObject.Properties['Locations']) { @($ds.Locations) } else { @() }
                    OsTypes        = if ($ds.PSObject.Properties['OsTypes']) { @($ds.OsTypes) } else { @() }
                    Tags           = @{}
                    TagOperator    = if ($ds.PSObject.Properties['TagOperator']) { $ds.TagOperator } else { "Any" }
                }
                if ($ds.PSObject.Properties['Tags']) {
                    foreach ($prop in $ds.Tags.PSObject.Properties) {
                        $scope.Tags[$prop.Name] = @($prop.Value)
                    }
                }
                $schedule.DynamicScopes += $scope
            }
        }

        $schedules += $schedule
    }

    Write-Log "Loaded $($schedules.Count) maintenance schedule(s) from config file." -Level SUCCESS

    return @{
        ManagementGroupName  = $config.ManagementGroupName
        SubscriptionId       = $config.SubscriptionId
        ResourceGroupName    = $config.ResourceGroupName
        TenantId             = if ($config.PSObject.Properties['TenantId']) { $config.TenantId } else { "" }
        AppId                = if ($config.PSObject.Properties['AppId']) { $config.AppId } else { "" }
        AppSecret            = if ($config.PSObject.Properties['AppSecret']) { $config.AppSecret } else { "" }
        Location             = $config.Location
        Schedules            = $schedules
        CreateResourceGroup  = if ($config.PSObject.Properties['CreateResourceGroup']) { $config.CreateResourceGroup } else { $false }
        RegisterProviders    = if ($config.PSObject.Properties['RegisterProviders']) { $config.RegisterProviders } else { $false }
        RunRemediation       = if ($config.PSObject.Properties['RunRemediation']) { $config.RunRemediation } else { $false }
    }
}

#endregion

#region ── Policy Assignments ──

function New-PolicyAssignmentAtMG {
    param(
        [string]$ManagementGroupName,
        [string]$PolicyDefinitionId,
        [string]$AssignmentName,
        [string]$DisplayName,
        [hashtable]$Parameters = @{},
        [string]$Description = "",
        [string]$ManagedIdentityLocation
    )

    $mgScope = "/providers/Microsoft.Management/managementGroups/$ManagementGroupName"

    # Check for existing assignment
    $existing = Get-AzPolicyAssignment -Name $AssignmentName -Scope $mgScope -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Log "  Policy assignment '$AssignmentName' already exists. Skipping." -Level INFO
        return $existing
    }

    Write-Log "  Creating policy assignment '$AssignmentName'..."

    $policyDef = Get-AzPolicyDefinition -Id "/providers/Microsoft.Authorization/policyDefinitions/$PolicyDefinitionId" -ErrorAction SilentlyContinue
    if (-not $policyDef) {
        Write-Log "  Policy definition ID '$PolicyDefinitionId' not found in this Azure environment." -Level ERROR
        Write-Log "  This policy may not be available in Azure Government. Verify at https://aka.ms/AzGovPolicy" -Level ERROR
        throw "Policy definition '$PolicyDefinitionId' not found. It may not be available in this Azure cloud."
    }

    $assignParams = @{
        Name                   = $AssignmentName
        DisplayName            = $DisplayName
        Scope                  = $mgScope
        PolicyDefinition       = $policyDef
        Location               = $ManagedIdentityLocation
        IdentityType           = 'SystemAssigned'
        Description            = $Description
    }

    if ($Parameters.Count -gt 0) {
        $assignParams['PolicyParameterObject'] = $Parameters
    }

    $assignment = New-AzPolicyAssignment @assignParams -ErrorAction Stop
    Write-Log "  Policy assignment '$AssignmentName' created." -Level SUCCESS

    return $assignment
}

function Set-AllPolicyAssignments {
    param(
        [string]$ManagementGroupName,
        [string]$Location,
        [array]$Schedules
    )

    Write-Log "Creating Azure Policy assignments at management group scope..."

    $assignments = @()

    # ── Periodic Assessment Policies ──
    $assessmentPolicyId = "59efceea-0c96-497e-a4a1-4eb2290dac15"

    # Windows assessment
    $assignments += New-PolicyAssignmentAtMG `
        -ManagementGroupName $ManagementGroupName `
        -PolicyDefinitionId $assessmentPolicyId `
        -AssignmentName "aum-assess-windows" `
        -DisplayName "AUM: Periodic Assessment - Windows" `
        -Description "Configures periodic checking for missing system updates on Windows VMs." `
        -Parameters @{ osType = "Windows"; assessmentMode = "AutomaticByPlatform" } `
        -ManagedIdentityLocation $Location

    # Linux assessment
    $assignments += New-PolicyAssignmentAtMG `
        -ManagementGroupName $ManagementGroupName `
        -PolicyDefinitionId $assessmentPolicyId `
        -AssignmentName "aum-assess-linux" `
        -DisplayName "AUM: Periodic Assessment - Linux" `
        -Description "Configures periodic checking for missing system updates on Linux VMs." `
        -Parameters @{ osType = "Linux"; assessmentMode = "AutomaticByPlatform" } `
        -ManagedIdentityLocation $Location

    # ── Patch Mode Prerequisites Policies ──
    $prereqWindowsPolicyId = "9905ca54-1471-49c6-8291-7582c04cd4d4"
    $prereqLinuxPolicyId   = "9905ca54-1471-49c6-8291-7582c04cd4d4"

    # Windows prerequisites
    $assignments += New-PolicyAssignmentAtMG `
        -ManagementGroupName $ManagementGroupName `
        -PolicyDefinitionId $prereqWindowsPolicyId `
        -AssignmentName "aum-prereq-windows" `
        -DisplayName "AUM: Patch Prerequisites - Windows" `
        -Description "Sets prerequisites for scheduling recurring updates on Windows VMs." `
        -Parameters @{ operatingSystemTypes = @("Windows") } `
        -ManagedIdentityLocation $Location

    # Linux prerequisites
    $assignments += New-PolicyAssignmentAtMG `
        -ManagementGroupName $ManagementGroupName `
        -PolicyDefinitionId $prereqLinuxPolicyId `
        -AssignmentName "aum-prereq-linux" `
        -DisplayName "AUM: Patch Prerequisites - Linux" `
        -Description "Sets prerequisites for scheduling recurring updates on Linux VMs." `
        -Parameters @{ operatingSystemTypes = @("Linux") } `
        -ManagedIdentityLocation $Location

    # ── Schedule Recurring Updates Policies ──
    $schedulePolicyId = "ba0df93e-e4ac-479a-aac2-134bbae39a1a"

    # Collect maintenance config IDs per OS
    $windowsConfigIds = @()
    $linuxConfigIds = @()
    foreach ($s in $Schedules) {
        if ($s._ConfigResourceId) {
            if ($s.OsType -eq "Windows") {
                $windowsConfigIds += $s._ConfigResourceId
            } else {
                $linuxConfigIds += $s._ConfigResourceId
            }
        }
    }

    # Windows schedule
    if ($windowsConfigIds.Count -gt 0) {
        foreach ($configId in $windowsConfigIds) {
            $configName = ($configId -split '/')[-1]
            $assignments += New-PolicyAssignmentAtMG `
                -ManagementGroupName $ManagementGroupName `
                -PolicyDefinitionId $schedulePolicyId `
                -AssignmentName "aum-sched-win-$($configName.Substring(0, [Math]::Min(20, $configName.Length)))" `
                -DisplayName "AUM: Schedule Updates - Windows ($configName)" `
                -Description "Schedules recurring updates for Windows VMs using maintenance config '$configName'." `
                -Parameters @{
                    maintenanceConfigurationResourceId = $configId
                    operatingSystemTypes = @("Windows")
                } `
                -ManagedIdentityLocation $Location
        }
    }

    # Linux schedule
    if ($linuxConfigIds.Count -gt 0) {
        foreach ($configId in $linuxConfigIds) {
            $configName = ($configId -split '/')[-1]
            $assignments += New-PolicyAssignmentAtMG `
                -ManagementGroupName $ManagementGroupName `
                -PolicyDefinitionId $schedulePolicyId `
                -AssignmentName "aum-sched-lnx-$($configName.Substring(0, [Math]::Min(20, $configName.Length)))" `
                -DisplayName "AUM: Schedule Updates - Linux ($configName)" `
                -Description "Schedules recurring updates for Linux VMs using maintenance config '$configName'." `
                -Parameters @{
                    maintenanceConfigurationResourceId = $configId
                    operatingSystemTypes = @("Linux")
                } `
                -ManagedIdentityLocation $Location
        }
    }

    Write-Log "Policy assignments complete. Created $($assignments.Count) assignment(s)." -Level SUCCESS
    return $assignments
}

#endregion

#region ── Maintenance Configurations ──

function New-MaintenanceConfigurations {
    param(
        [string]$SubscriptionId,
        [string]$ResourceGroupName,
        [string]$Location,
        [array]$Schedules,
        [bool]$CreateResourceGroup = $false
    )

    Set-AzContext -SubscriptionId $SubscriptionId -WarningAction SilentlyContinue | Out-Null
    Write-Log "Creating maintenance configurations in subscription '$SubscriptionId', RG '$ResourceGroupName'..."

    # Validate or create resource group
    $rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
    if (-not $rg) {
        if ($CreateResourceGroup) {
            Write-Log "  Resource group '$ResourceGroupName' not found. Creating..." -Level INFO
            New-AzResourceGroup -Name $ResourceGroupName -Location $Location -ErrorAction Stop | Out-Null
            Write-Log "  Resource group '$ResourceGroupName' created." -Level SUCCESS
        } else {
            throw "Resource group '$ResourceGroupName' does not exist. Use 'Create new' option in the wizard or set 'CreateResourceGroup' to true in the config file."
        }
    } else {
        Write-Log "  Validated resource group '$ResourceGroupName' exists." -Level SUCCESS
    }

    $createdConfigs = @()

    foreach ($schedule in $Schedules) {
        $configName = $schedule.Name

        # Check for existing
        $existing = Get-AzMaintenanceConfiguration -ResourceGroupName $ResourceGroupName -Name $configName -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Log "  Maintenance config '$configName' already exists. Skipping creation." -Level INFO
            $schedule._ConfigResourceId = $existing.Id
            $createdConfigs += $existing
            continue
        }

        $params = @{
            ResourceGroupName        = $ResourceGroupName
            Name                     = $configName
            MaintenanceScope         = $schedule.MaintenanceScope
            Location                 = $Location
            Timezone                 = $schedule.Timezone
            StartDateTime            = $schedule.StartDateTime
            Duration                 = $schedule.Duration
            RecurEvery               = $schedule.RecurEvery
        }

        # InGuestPatch-specific params (reboot, classifications, KB/package filters)
        if ($schedule.MaintenanceScope -eq "InGuestPatch") {
            $params['InstallPatchRebootSetting'] = $schedule.RebootSetting
            $params['ExtensionProperty'] = @{ inGuestPatchMode = "User" }

            # OS-specific classification and filter params
            if ($schedule.OsType -eq "Windows") {
                $params['WindowParameterClassificationToInclude'] = $schedule.Classifications
                if ($schedule.KbInclude -and $schedule.KbInclude.Count -gt 0) {
                    $params['WindowParameterKbNumberToInclude'] = $schedule.KbInclude
                }
                if ($schedule.KbExclude -and $schedule.KbExclude.Count -gt 0) {
                    $params['WindowParameterKbNumberToExclude'] = $schedule.KbExclude
                }
                if ($schedule.ExcludeKbRequiringReboot) {
                    $params['WindowParameterExcludeKbRequiringReboot'] = $true
                }
            } else {
                $params['LinuxParameterClassificationToInclude'] = $schedule.Classifications
                if ($schedule.PackageInclude -and $schedule.PackageInclude.Count -gt 0) {
                    $params['LinuxParameterPackageNameMaskToInclude'] = $schedule.PackageInclude
                }
                if ($schedule.PackageExclude -and $schedule.PackageExclude.Count -gt 0) {
                    $params['LinuxParameterPackageNameMaskToExclude'] = $schedule.PackageExclude
                }
            }
        }

        Write-Log "  Creating maintenance config '$configName' ($($schedule.MaintenanceScope))..."
        $config = New-AzMaintenanceConfiguration @params -ErrorAction Stop
        $schedule._ConfigResourceId = $config.Id
        $createdConfigs += $config
        Write-Log "  Maintenance config '$configName' created." -Level SUCCESS
    }

    return $createdConfigs
}

#endregion

#region ── Dynamic Scopes ──

function New-DynamicScopeAssignments {
    param(
        [array]$Schedules
    )

    Write-Log "Creating dynamic scope assignments..."
    $assignments = @()

    foreach ($schedule in $Schedules) {
        if (-not $schedule.DynamicScopes -or $schedule.DynamicScopes.Count -eq 0) {
            Write-Log "  Schedule '$($schedule.Name)': No dynamic scopes defined. Skipping." -Level INFO
            continue
        }

        $configId = $schedule._ConfigResourceId
        if (-not $configId) {
            Write-Log "  Schedule '$($schedule.Name)': No config resource ID found. Skipping dynamic scopes." -Level WARN
            continue
        }

        $scopeIndex = 0
        foreach ($scope in $schedule.DynamicScopes) {
            foreach ($subId in $scope.Subscriptions) {
                $scopeIndex++
                $assignmentName = "$($schedule.Name)-dyn-$scopeIndex"
                # Truncate to 64 chars max
                if ($assignmentName.Length -gt 64) {
                    $assignmentName = $assignmentName.Substring(0, 64)
                }

                try {
                    Set-AzContext -SubscriptionId $subId -WarningAction SilentlyContinue | Out-Null

                    $assignParams = @{
                        ConfigurationAssignmentName = $assignmentName
                        MaintenanceConfigurationId  = $configId
                        Location                    = "global"
                    }

                    # Apply filters
                    if ($scope.Locations -and $scope.Locations.Count -gt 0) {
                        $assignParams['FilterLocation'] = $scope.Locations
                    }
                    if ($scope.OsTypes -and $scope.OsTypes.Count -gt 0) {
                        $assignParams['FilterOsType'] = $scope.OsTypes
                    }
                    if ($scope.ResourceGroups -and $scope.ResourceGroups.Count -gt 0) {
                        $assignParams['FilterResourceGroup'] = $scope.ResourceGroups
                    }
                    if ($scope.Tags -and $scope.Tags.Count -gt 0) {
                        $tagJson = $scope.Tags | ConvertTo-Json -Compress
                        $assignParams['FilterTag'] = $tagJson
                    }
                    if ($scope.TagOperator) {
                        $assignParams['FilterOperator'] = $scope.TagOperator
                    }

                    Write-Log "    Creating dynamic scope '$assignmentName' in subscription '$subId'..."
                    $assignment = New-AzConfigurationAssignment @assignParams -ErrorAction Stop
                    $assignments += $assignment
                    Write-Log "    Dynamic scope '$assignmentName' created." -Level SUCCESS
                } catch {
                    Write-Log "    Failed to create dynamic scope '$assignmentName' in subscription '$subId': $_" -Level ERROR
                }
            }
        }
    }

    Write-Log "Dynamic scope assignments complete. Created $($assignments.Count) assignment(s)." -Level SUCCESS
    return $assignments
}

#endregion

#region ── Remediation ──

function Start-PolicyRemediations {
    param(
        [string]$ManagementGroupName,
        [array]$PolicyAssignments
    )

    Write-Log "Triggering policy remediation tasks..."
    $remediations = @()

    foreach ($assignment in $PolicyAssignments) {
        if (-not $assignment) { continue }

        $remediationName = "remediation-$($assignment.Name)-$(Get-Date -Format 'yyyyMMddHHmmss')"
        # Truncate name to 64 chars
        if ($remediationName.Length -gt 64) {
            $remediationName = $remediationName.Substring(0, 64)
        }

        try {
            Write-Log "  Creating remediation '$remediationName' for assignment '$($assignment.Name)'..."
            $remediation = Start-AzPolicyRemediation `
                -Name $remediationName `
                -ManagementGroupName $ManagementGroupName `
                -PolicyAssignmentId $assignment.Id `
                -ErrorAction Stop
            $remediations += $remediation
            Write-Log "  Remediation '$remediationName' started." -Level SUCCESS
        } catch {
            Write-Log "  Failed to create remediation for '$($assignment.Name)': $_" -Level WARN
        }
    }

    Write-Log "Remediation tasks complete. Started $($remediations.Count) remediation(s)." -Level SUCCESS
    return $remediations
}

#endregion

#region ── Identity Report ──

function Export-IdentityReport {
    param(
        [array]$PolicyAssignments,
        [string]$ManagementGroupName,
        [string]$OutputPath = ".\identity-rbac-report.csv"
    )

    $mgScope = "/providers/Microsoft.Management/managementGroups/$ManagementGroupName"
    $report = @()

    foreach ($assignment in $PolicyAssignments) {
        if (-not $assignment -or -not $assignment.Identity -or -not $assignment.Identity.PrincipalId) {
            continue
        }
        $report += [PSCustomObject]@{
            AssignmentName  = $assignment.Name
            DisplayName     = $assignment.DisplayName
            PrincipalId     = $assignment.Identity.PrincipalId
            IdentityType    = "SystemAssigned"
            RequiredRole    = "Contributor"
            RoleDefinitionId = "b24988ac-6180-42a0-ab88-20f7382dd24c"
            Scope           = $mgScope
            Status          = "RBAC NOT ASSIGNED — identity team action required"
        }
    }

    if ($report.Count -eq 0) {
        Write-Log "No managed identities found in policy assignments." -Level WARN
        return @()
    }

    # Console output
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Magenta
    Write-Host "║              Identity Team RBAC Handoff Report              ║" -ForegroundColor Magenta
    Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Magenta
    Write-Host ""
    Write-Host "  The following managed identities were auto-created by Azure" -ForegroundColor Yellow
    Write-Host "  for DINE policy assignments. They require Contributor role" -ForegroundColor Yellow
    Write-Host "  at the management group scope to perform remediation." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Scope: $mgScope" -ForegroundColor Cyan
    Write-Host "  Required Role: Contributor (b24988ac-6180-42a0-ab88-20f7382dd24c)" -ForegroundColor Cyan
    Write-Host ""

    foreach ($entry in $report) {
        Write-Host "  ┌─ $($entry.DisplayName)" -ForegroundColor White
        Write-Host "  │  Assignment: $($entry.AssignmentName)" -ForegroundColor Gray
        Write-Host "  │  Principal ID: $($entry.PrincipalId)" -ForegroundColor Gray
        Write-Host "  └─ Status: $($entry.Status)" -ForegroundColor Yellow
        Write-Host ""
    }

    # Export CSV
    $report | Export-Csv -Path $OutputPath -NoTypeInformation -Force
    Write-Log "Identity report exported to '$OutputPath'" -Level SUCCESS
    Write-Host "  ⚠  Remediation tasks will fail until Contributor role is assigned." -ForegroundColor Yellow
    Write-Host "  ⚠  RBAC propagation typically takes 5-10 minutes after assignment." -ForegroundColor Yellow
    Write-Host ""

    return $report
}

#endregion

#region ── Validation Summary ──

function Show-ValidationSummary {
    param(
        [array]$ProviderResults,
        [array]$PolicyAssignments,
        [array]$MaintenanceConfigs,
        [array]$DynamicScopes,
        [array]$Remediations,
        [array]$IdentityReport
    )

    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Green
    Write-Host "║                    Configuration Summary                     ║" -ForegroundColor Green
    Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Green
    Write-Host ""

    # Resource Providers
    Write-Host "  Resource Provider Registrations:" -ForegroundColor Yellow
    if ($ProviderResults -and $ProviderResults.Count -gt 0) {
        foreach ($r in $ProviderResults) {
            Write-Host "    [$($r.SubscriptionId)] $($r.Provider): $($r.Status)"
        }
    } else {
        Write-Host "    Skipped (use -RegisterProviders to enable)"
    }
    Write-Host ""

    # Policy Assignments
    Write-Host "  Policy Assignments:" -ForegroundColor Yellow
    $validAssignments = $PolicyAssignments | Where-Object { $_ -ne $null }
    if ($validAssignments.Count -gt 0) {
        foreach ($a in $validAssignments) {
            Write-Host "    ✓ $($a.Name) — $($a.DisplayName)" -ForegroundColor Green
        }
    } else {
        Write-Host "    None created"
    }
    Write-Host ""

    # Maintenance Configurations
    Write-Host "  Maintenance Configurations:" -ForegroundColor Yellow
    if ($MaintenanceConfigs -and $MaintenanceConfigs.Count -gt 0) {
        foreach ($mc in $MaintenanceConfigs) {
            Write-Host "    ✓ $($mc.Name) — $($mc.Location)" -ForegroundColor Green
        }
    } else {
        Write-Host "    None created"
    }
    Write-Host ""

    # Dynamic Scopes
    Write-Host "  Dynamic Scope Assignments:" -ForegroundColor Yellow
    if ($DynamicScopes -and $DynamicScopes.Count -gt 0) {
        Write-Host "    Total: $($DynamicScopes.Count)" -ForegroundColor Green
    } else {
        Write-Host "    None created — VMs must be statically assigned to maintenance" -ForegroundColor Yellow
        Write-Host "    configurations via Azure portal, CLI, or a separate script." -ForegroundColor Yellow
    }
    Write-Host ""

    # Remediations
    Write-Host "  Policy Remediations:" -ForegroundColor Yellow
    if ($Remediations -and $Remediations.Count -gt 0) {
        foreach ($r in $Remediations) {
            Write-Host "    ✓ $($r.Name) — $($r.ProvisioningState)" -ForegroundColor Green
        }
    } else {
        Write-Host "    Skipped (use -RunRemediation to enable after RBAC is assigned)"
    }
    Write-Host ""

    # Identity Report
    Write-Host "  Managed Identity RBAC Handoff:" -ForegroundColor Yellow
    if ($IdentityReport -and $IdentityReport.Count -gt 0) {
        Write-Host "    $($IdentityReport.Count) managed identity(ies) require Contributor role" -ForegroundColor Yellow
        Write-Host "    See identity-rbac-report.csv for details" -ForegroundColor Cyan
    } else {
        Write-Host "    No managed identities created"
    }
    Write-Host ""
    Write-Host "  ════════════════════════════════════════════════════════════" -ForegroundColor Green
    Write-Log "Azure Update Manager configuration complete." -Level SUCCESS
}

#endregion

#region ── Main Execution ──

try {
    Show-Banner
    Assert-RequiredModules

    $schedules = @()
    $createRG = $false

    if ($ConfigFile) {
        # ── Non-Interactive Mode ──
        $config = Import-ConfigFile -Path $ConfigFile
        $ManagementGroupName = $config.ManagementGroupName
        $SubscriptionId      = $config.SubscriptionId
        $ResourceGroupName   = $config.ResourceGroupName
        $TenantId            = $config.TenantId
        $AppId               = $config.AppId
        $Location            = $config.Location
        $schedules           = $config.Schedules
        $createRG            = $config.CreateResourceGroup

        if ($config.AppSecret) {
            $AppSecret = ConvertTo-SecureString $config.AppSecret -AsPlainText -Force
        }
        if ($config.RegisterProviders) { $RegisterProviders = [switch]::new($true) }
        if ($config.RunRemediation)    { $RunRemediation = [switch]::new($true) }
    } else {
        # ── Interactive Mode: prompt for missing parameters ──
        if (-not $ManagementGroupName) {
            $ManagementGroupName = Read-RequiredInput "Enter the Management Group name"
        }
        if (-not $SubscriptionId) {
            $SubscriptionId = Read-RequiredInput "Enter the Subscription ID for maintenance configurations"
        }

        # Resource Group: create new or use existing
        $rgChoice = Show-Menu -Title "Resource Group" -Options @(
            "Use an existing resource group",
            "Create a new resource group"
        )
        if ($rgChoice -eq 2) {
            $createRG = $true
            if (-not $ResourceGroupName) {
                $ResourceGroupName = Read-RequiredInput "Enter the new Resource Group name"
            }
        } else {
            if (-not $ResourceGroupName) {
                $ResourceGroupName = Read-RequiredInput "Enter the existing Resource Group name"
            }
        }

        # Authentication method
        $authChoice = Show-Menu -Title "Authentication Method" -Options @(
            "Interactive user login (browser-based)",
            "Service Principal (SPN)"
        )
        if ($authChoice -eq 2) {
            if (-not $TenantId) {
                $TenantId = Read-RequiredInput "Enter the Azure AD Tenant ID"
            }
            if (-not $AppId) {
                $AppId = Read-RequiredInput "Enter the SPN Application (Client) ID"
            }
            if (-not $AppSecret) {
                $AppSecret = Read-Host "  Enter the SPN Client Secret" -AsSecureString
            }
        } else {
            if (-not $TenantId) {
                Write-Host "  Tenant ID is optional for interactive login (Azure will prompt if needed)." -ForegroundColor Gray
                $tenantInput = Read-Host "  Enter the Azure AD Tenant ID (or press Enter to skip)"
                if ($tenantInput) { $TenantId = $tenantInput }
            }
        }

        if (-not $Location) {
            $locChoice = Show-Menu -Title "Azure Government Region" -Options @(
                "usgovvirginia",
                "usgovarizona",
                "usgovtexas",
                "usdodeast",
                "usdodcentral"
            )
            $Location = @("usgovvirginia", "usgovarizona", "usgovtexas", "usdodeast", "usdodcentral")[$locChoice - 1]
        }
    }

    # Phase 1: Authenticate
    Connect-AzureGov -TenantId $TenantId -AppId $AppId -AppSecret $AppSecret

    # Phase 2: Register Resource Providers (optional)
    $providerResults = @()
    if ($RegisterProviders) {
        $providerResults = Register-RequiredProviders -ManagementGroupName $ManagementGroupName
    } else {
        Write-Log "Skipping resource provider registration (use -RegisterProviders to enable)." -Level INFO
    }

    # Phase 3: Build schedules (interactive or already loaded from config)
    if (-not $ConfigFile) {
        $schedules = New-ScheduleWizard
    }

    # Phase 4: Create Maintenance Configurations
    $maintenanceConfigs = New-MaintenanceConfigurations `
        -SubscriptionId $SubscriptionId `
        -ResourceGroupName $ResourceGroupName `
        -Location $Location `
        -Schedules $schedules `
        -CreateResourceGroup $createRG

    # Phase 5: Create Dynamic Scopes
    $dynamicScopes = New-DynamicScopeAssignments -Schedules $schedules

    # Phase 6: Policy Assignments (needs maintenance config IDs)
    Set-AzContext -SubscriptionId $SubscriptionId -WarningAction SilentlyContinue | Out-Null
    $policyAssignments = Set-AllPolicyAssignments `
        -ManagementGroupName $ManagementGroupName `
        -Location $Location `
        -Schedules $schedules

    # Phase 7: Identity Report (always generated for identity team handoff)
    $identityReport = Export-IdentityReport `
        -PolicyAssignments $policyAssignments `
        -ManagementGroupName $ManagementGroupName

    # Phase 8: Trigger Remediations (optional — requires RBAC on managed identities)
    $remediations = @()
    if ($RunRemediation) {
        $remediations = Start-PolicyRemediations `
            -ManagementGroupName $ManagementGroupName `
            -PolicyAssignments $policyAssignments
    } else {
        Write-Log "Skipping remediation (use -RunRemediation after identity team assigns RBAC)." -Level INFO
    }

    # Phase 9: Validation Summary
    Show-ValidationSummary `
        -ProviderResults $providerResults `
        -PolicyAssignments $policyAssignments `
        -MaintenanceConfigs $maintenanceConfigs `
        -DynamicScopes $dynamicScopes `
        -Remediations $remediations `
        -IdentityReport $identityReport

} catch {
    Write-Log "FATAL: $_" -Level ERROR
    Write-Log "Stack trace: $($_.ScriptStackTrace)" -Level ERROR
    exit 1
}

#endregion
