# Copyright (c) 2026 Broadcom. All Rights Reserved.
# Broadcom Confidential. The term "Broadcom" refers to Broadcom Inc.
# and/or its subsidiaries.
#
# =============================================================================
#
# SOFTWARE LICENSE AGREEMENT
#
# Copyright (c) CA, Inc. All rights reserved.
#
# You are hereby granted a non-exclusive, worldwide, royalty-free license
# under CA, Inc.'s copyrights to use, copy, modify, and distribute this
# software in source code or binary form for use in connection with CA, Inc.
# products.
#
# This copyright notice shall be included in all copies or substantial
# portions of the software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
# DEALINGS IN THE SOFTWARE.
#
# =============================================================================
#
# PowerShell Module: VcfEdgeAtScale
# Module Version: see VcfEdgeAtScale.psd1
# Last modified: 2026-05-19
#
# Private implementation files (dot-sourced below):
#   Private/Logging.ps1     — logging, vCenter connectivity (Test-VcenterConnection, Assert-VcenterConnected), content library, witness prep
#   Private/Cluster.ps1     — cluster, datastore, vSAN, VMFS, disk operations, vLCM helpers
#   Private/Networking.ps1  — VDS, VMkernel cleanup, management restore, IP/network primitives
#   Private/Supervisor.ps1  — supervisor, Harbor, Argo CD, workload networking
#   Private/Yaml.ps1        — YAML serialization and deserialization
#   Private/Validation.ps1  — deployment phase helpers, validation
#   Private/Deployment.ps1  — cleanup orchestration, Initialize-VcfEdgeAtScale deployment entry point
#   Private/EntryPoints.ps1 — Start-VcfEdgeAtScale, configuration help, UI sync (exported)
#

# Module-scope initialization helpers. These are private functions defined before the script-scope
# variable block so they can be called during initialization and remain available to dot-sourced
# private files. try/catch at raw module scope triggers PSScriptAnalyzer LSP false positives in
# some editors; extracting into named functions avoids those false positives while retaining proper
# error handling and user-visible warnings. Read-VcfEdgeAtScaleManifestVersion is removed from the
# Function: drive after use (one-shot helper). Get-VcfEdgeAtScaleVcfCmd is kept as a private
# lazy-resolver callable by the dot-sourced private files.
function Read-VcfEdgeAtScaleManifestVersion {

    <#
    .SYNOPSIS
        Reads the module version string from a PowerShell manifest file.

    .DESCRIPTION
        Imports the .psd1 manifest at ManifestPath and returns its ModuleVersion string.
        On any error (file missing, parse failure) emits a Warning and returns "unknown".
        This function is removed from the Function: drive immediately after module
        initialization and must not be called after that point.

    .PARAMETER ManifestPath
        Full path to the .psd1 manifest file to read.

    .EXAMPLE
        $version = Read-VcfEdgeAtScaleManifestVersion -ManifestPath "$PSScriptRoot/VcfEdgeAtScale.psd1"

    .OUTPUTS
        String. The ModuleVersion value from the manifest, or "unknown" on error.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ManifestPath
    )

    try {
        # -ErrorAction Stop converts the non-terminating file-not-found error into a catchable exception.
        return (Import-PowerShellDataFile -Path $ManifestPath -ErrorAction Stop).ModuleVersion
    } catch {
        Write-Warning "VcfEdgeAtScale: Could not read module version from '$ManifestPath' — $($_.Exception.Message). Version will be reported as 'unknown'."
        return "unknown"
    }
}
function Get-VcfEdgeAtScaleVcfCmd {

    <#
        .SYNOPSIS
        Returns the VCF CLI executable name, resolving and caching it on first call.

        .DESCRIPTION
        Performs the VCF CLI PATH scan (Get-Command -CommandType Application) lazily — only
        on first invocation — and caches the result in $Script:VcfCmd. Subsequent calls return
        the cached value immediately with no I/O. Deferring the scan from module-load time to
        first use avoids ~1-2 seconds of PATH scan latency on every new shell startup (macOS).

        .EXAMPLE
        $vcfCmd = Get-VcfEdgeAtScaleVcfCmd

        .OUTPUTS
        String. The resolved VCF CLI command name (e.g. "vcf" or "vcf.exe").

        .NOTES
        Sets $Script:VcfCmd as a side-effect. Many call sites in Private/Supervisor.ps1 reference
        $Script:VcfCmd directly rather than calling this function. They are safe because
        Get-EnvironmentSetup (called at the start of every Start-VcfEdgeAtScale run via New-LogFile)
        invokes this function first. Any code path that bypasses Get-EnvironmentSetup must call
        this function explicitly before using $Script:VcfCmd.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param ()

    if ($null -ne $Script:VcfCmd) {
        return $Script:VcfCmd
    }

    try {
        $candidates = if ($IsWindows) { @("vcf.exe", "vcf") } else { @("vcf") }
        foreach ($name in $candidates) {
            if (Get-Command -Name $name -CommandType Application -ErrorAction SilentlyContinue) {
                $Script:VcfCmd = $name
                return $name
            }
        }
    } catch {
        $defaultName = if ($IsWindows) { "vcf.exe" } else { "vcf" }
        Write-Warning "VcfEdgeAtScale: VCF CLI auto-detection failed — $($_.Exception.Message). Defaulting to '$defaultName'."
    }

    # No candidate found on PATH; fall back to the platform default name.
    $Script:VcfCmd = if ($IsWindows) { "vcf.exe" } else { "vcf" }
    return $Script:VcfCmd
}

#region Script scope variables
$local:manifestPath = Join-Path -Path $PSScriptRoot -ChildPath "VcfEdgeAtScale.psd1"
$Script:ModuleVersion = if (Test-Path -LiteralPath $local:manifestPath) {
    Read-VcfEdgeAtScaleManifestVersion -ManifestPath $local:manifestPath
} else {
    Write-Warning "VcfEdgeAtScale: Module manifest not found at '$local:manifestPath'. Version will be reported as 'unknown'."
    "unknown"
}

# Root directory of this module; used by private files that need to locate the manifest at runtime
# (e.g. Invoke-VcfEdgeAtScaleModuleVersionStalenessCheck).
$Script:ModuleRoot = $PSScriptRoot

# Set platform-specific command names for cross-platform compatibility.
$Script:ArgocdCmd = if ($IsWindows) { "argocd.exe" } else { "argocd" }
$Script:KubectlCmd = if ($IsWindows) { "kubectl.exe" } else { "kubectl" }

# VCF CLI command name: resolved lazily on first use via Get-VcfEdgeAtScaleVcfCmd to avoid a
# PATH scan (Get-Command -CommandType Application) at module-load time. Deferred initialization
# keeps profile load time fast; the scan runs once when the user first invokes a VCF CLI operation.
$Script:VcfCmd = $null

# Remove the one-shot manifest-version helper from the Function: drive; it must not appear in Get-Command -Module VcfEdgeAtScale.
# Get-VcfEdgeAtScaleVcfCmd is intentionally kept — it is a private lazy-resolver used by the dot-sourced private files.
Remove-Item -Path Function:\Read-VcfEdgeAtScaleManifestVersion -ErrorAction SilentlyContinue

# Define log level hierarchy (lower number = lower priority, higher number = higher priority).
$Script:LogLevelHierarchy = @{
    "DEBUG" = 0
    "INFO" = 1
    "ADVISORY" = 2
    "WARNING" = 3
    "EXCEPTION" = 4
    "ERROR" = 5
}

# Initialize log level (will be set by Start-VcfEdgeAtScale).
$Script:ConfiguredLogLevel = "INFO"
# When $true, Invoke-PauseBeforeRollbackIfRequested will skip its prompt (cleanup confirmation is sufficient). Set during -CleanUp cleanup.
$Script:CleanUpOnly = $false
# Rollback on failure: $null = prompt (Y/N/Always), $true = always rollback (unattended), $false = never rollback (leave site broken, continue to next). Set by Start-VcfEdgeAtScale -RollbackOnFailure.
$Script:RollbackOnFailurePreference = $null
# When user chooses "Always" at the prompt, no further prompts for remaining sites; always rollback. Reset at start of each run.
$Script:RollbackAlwaysFromPrompt = $false
# Typed exception thrown when user chooses No (or preference is never); caught by main loop to continue to next site.
# Using a class instead of a string sentinel makes the control flow refactor-safe and type-checkable.
class RollbackSkippedException : System.Exception {
    RollbackSkippedException() : base("Rollback skipped by user; continue to next site.") {}
}
# Typed exception for known deployment failures that have already been logged via Write-LogMessage -Type ERROR.
# Caught by the top-level catch in Start-VcfEdgeAtScale, which shows the friendly footer without rethrowing the
# raw exception — suppressing the scary "Exception: file:line" block that appears after user-readable [ERROR] output.
class VcfDeploymentException : System.Exception {
    VcfDeploymentException() : base("Deployment failed.") {}
    VcfDeploymentException([string]$message) : base($message) {}
    VcfDeploymentException([string]$message, [System.Exception]$inner) : base($message, $inner) {}
}
# Set when Invoke-VsanDeploymentRollback (or other rollback) is entered so the main catch does not prompt/run rollback again.
$Script:RollbackAttempted = $false
# Set when rollback fails (e.g. Remove-Cluster failed); main catch rethrows immediately so the script exits with a non-zero status.
$Script:RollbackFailed = $false
# Set when we enter the ArgoCD deployment try block (Set-ArgoCDService, Add-ArgoCDNamespace, etc.); cleared at start of each cluster. Used to choose ArgoCD-only rollback (remove namespace, keep supervisor) vs supervisor-only rollback when deployment fails after supervisor is enabled.
$Script:ArgoCDPhaseStarted = $false
# Set when we enter the Harbor deployment block (Set-HarborService, Install-HarborSupervisorService, etc.); cleared at start of each cluster. Used to choose Harbor-only rollback vs ArgoCD or supervisor rollback when Harbor deployment fails.
$Script:HarborPhaseStarted = $false
# Highest installed VCF.PowerCLI version after Initialize-ScriptVcfPowerCliModuleVersion (used for 9.0 vs 9.1 compatibility gates).
$Script:VcfPowerCliModuleVersion = $null
# Parent directory of the infrastructure JSON file; set by Update-InfrastructureJsonReferencedFilePaths for Resolve-InfrastructureReferencedFilePath when combining supervisorServices parentDirectory with file names.
$Script:InfrastructureJsonParentForPathResolution = $null
# Set to $true by New-LogFile when a new daily log file is created; used by Start-VcfEdgeAtScale to trigger the once-per-day PSGallery update check.
$Script:NewLogFileCreatedThisSession = $false

# =============================================================================
# SUPERVISOR SERVICE REGISTRY
# Central definition of all supervisor services. When adding a new service (e.g. "Velero"),
# add an entry here and update the functions listed in each property's inline comment.
# This replaces the previous 8-step manual checklist.
#
# Properties per service:
#   DisableFlag      — string used in infrastructure JSON and Get-EffectiveSupervisorServiceFlag ValidateSet
#   YamlPathProperty — logical YAML path property name for Get-EffectiveSupervisorServicesYamlPath ValidateSet
#   CleanupScope     — scope name used in Invoke-VcfEdgeAtScaleCleanup and Start-VcfEdgeAtScale ValidateSet
#   PhaseStarted     — script-scope boolean flag name (see companion $Script: declarations above)
#
# Wiring status: DisableFlag, YamlPathProperty, CleanupScope, PhaseStarted are currently read by
# per-service code paths. Tracked as code review item C3 — future refactor will drive all
# dispatch loops from this table to fully eliminate the per-service boilerplate.
# =============================================================================
$Script:SupervisorServiceRegistry = [ordered]@{
    ArgoCD = @{
        DisableFlag      = "disableArgoCD"
        YamlPathProperty = "argoCDDeploymentYamlPath"
        CleanupScope     = "ArgoCD"
        PhaseStarted     = "ArgoCDPhaseStarted"
    }
    Harbor = @{
        DisableFlag      = "disableHarbor"
        YamlPathProperty = "harborServiceYamlPath"
        CleanupScope     = "Harbor"
        PhaseStarted     = "HarborPhaseStarted"
    }
}

# ArgoCD deployment timeout defaults (used by Add-ArgoCDInstance when no TimeoutConfig key is supplied).
$Script:ArgoCDAuthTimeoutSeconds = 60
$Script:ArgoCDPodReadyTimeoutSeconds = 600
$Script:ArgoCDPodReadyCheckIntervalSeconds = 5
$Script:ArgoCDWebhookReadyTimeoutSeconds = 1200
$Script:ArgoCDWebhookReadyCheckIntervalSeconds = 5
$Script:ArgoCDWebhookRetryTimeoutSeconds = 60

# Service YAML basenames shipped under Templates; update this list when template versions change (used by Start-VcfEdgeAtScale -Initialize).
$Script:VcfEdgeAtScaleServiceYamlTemplateFileNames = @(
    "1.1.0-25100889.yml",
    "argocd-deployment.yml",
    "harbor-data-values-v2.14.2.yml",
    "legacy-harbor-svs-v2.14.2+vmware.2-vks.1-25220498.yml"
)

# Deployment layout directory names — single source of truth used by Initialize, CollectLogs, and tests.
$Script:DOCS_DIR_NAME                = "Docs"
$Script:LOGS_DIR_NAME                = "Logs"
$Script:SERVICES_YAML_DIR_NAME       = "ServicesYaml"
$Script:TOOLS_DIR_NAME               = "Tools"
$Script:DEPLOY_LAYOUT_SUBDIRECTORIES = @($Script:DOCS_DIR_NAME, $Script:LOGS_DIR_NAME, $Script:SERVICES_YAML_DIR_NAME, $Script:TOOLS_DIR_NAME)

# Configuration file names used by Initialize, CollectLogs, and help commands.
$Script:INFRA_JSON_FILENAME          = "infrastructure.json"
$Script:SUPERVISOR_JSON_FILENAME     = "supervisor.json"
$Script:INFRA_HELP_FILENAME          = "infrastructure-config-help.json"
$Script:SUPERVISOR_HELP_FILENAME     = "supervisor-config-help.json"

# Default deployment directory name under $HOME (Initialize default when no path is supplied).
$Script:DEFAULT_DEPLOY_DIR_NAME      = "VcfEdgeAtScale"

# Environment variable name that stores the active deployment root.
$Script:ENV_VAR_NAME                 = "VcfEdgeAtScaleRootDirectory"

# Enforce minimum engine version (must match PowerShellVersion in VcfEdgeAtScale.psd1).
if ($PSVersionTable.PSVersion -lt [Version]"7.4") {
    throw "VcfEdgeAtScale requires PowerShell 7.4 or later. Current version is $($PSVersionTable.PSVersion). Install a newer pwsh and retry."
}

# Backward compatibility: the env var was misspelled "VcfEdgeatScaleRootDirectory" (lowercase 't')
# before 1.0.3.1007. On Windows, env vars are case-insensitive so both names resolve identically.
# On macOS/Linux (case-sensitive), migrate the old value to the corrected name automatically
# so existing $PROFILE lines from earlier -Initialize runs continue to work without manual editing.
if (-not $IsWindows -and
    -not [String]::IsNullOrEmpty($env:VcfEdgeatScaleRootDirectory) -and
    [String]::IsNullOrEmpty($env:VcfEdgeAtScaleRootDirectory)) {
    $env:VcfEdgeAtScaleRootDirectory = $env:VcfEdgeatScaleRootDirectory
    Remove-Item Env:\VcfEdgeatScaleRootDirectory -ErrorAction SilentlyContinue
}

# =============================================================================
# MODULE-SCOPE STATE TIERS — contract for all $Script: variables in this module
#
# Tier 1 — Module constants (set above at load time, never mutate):
#   String constants, directory names, filename constants, configurable timeouts,
#   log-level hierarchy, ArgoCD timeouts, service YAML template names, rollback
#   exception classes, and the supervisor service registry.
#   These are safe to read from any function at any time.
#
# Tier 2 — Logging infrastructure (owned by Private/Logging.ps1):
#   LogFile, LogFolder, LogOnly, LogLevelHierarchy, ConfiguredLogLevel,
#   LogMessagePending, LogMessagePendingTimestamp, LogMessagePendingType,
#   NewLogFileCreatedThisSession.
#   Private to the logging subsystem; do not read or write from other files.
#
# Tier 3 — Deployment session state (set once per Initialize-VcfEdgeAtScale call):
#   Valid from the moment Initialize-VcfEdgeAtScale begins until its finally block
#   clears credentials. Not valid outside a deployment run — $null at load time.
#   Set by: Get-InitializationConfigFromJson (vCenterName, VCenterUser) and
#           Set-ScriptVcenterCredential / Connect-Vcenter (VcenterCredential).
#   Cleared by: the finally block in Initialize-VcfEdgeAtScale (VcenterCredential).
$Script:vCenterName           = $null  # vCenter FQDN; read by 548+ call sites via -Server parameter
$Script:VCenterUser           = $null  # vCenter username; read by Connect-Vcenter and REST helpers
$Script:VcenterCredential     = $null  # PSCredential; cleared in the finally block after each run
$Script:VcenterInsecurePassword = $null  # plain-text credential path, set when VCENTER_COMMON_PASSWORD env var is used

# Tier 4 — Per-cluster ephemeral flags (reset at the start of each cluster iteration):
#   Reset by Invoke-ClusterDeploymentIteration before each cluster loop.
#   Written by inner deployment, rollback, and service-install helpers.
#   Read by catch blocks in Invoke-ClusterDeploymentIteration and Invoke-ClusterRollbackPhase
#   to decide whether a rollback attempt is needed or has already been made.
#   Not valid across cluster boundaries — always reset before each cluster starts.
# (RollbackAttempted, RollbackFailed, ArgoCDPhaseStarted, HarborPhaseStarted declared above.)
$Script:SupervisorName              = $null  # supervisor FQDN for current cluster; used by vSAN tag helpers
$Script:DidMigrateVmk0ToVdsThisRun  = $false # $true when vmk0 has been migrated to VDS in this run; used by rollback to decide whether to restore VSS

# Tier 5 — Performance-tuning constants (set at load time in Private/Cluster.ps1):
#   VsanOsaEligibleDisksDelaySeconds, HaNetworkStabilizationDelaySeconds,
#   HaPostVsanStabilizationDelaySeconds, DatastoreRenameVerificationDelaySeconds,
#   DatastoreWaitLogIntervalSeconds, MinHostDiskRetrievalTimeoutSeconds,
#   MaxPowerCliTimeoutSeconds, PowerCliTimeoutBufferSeconds, VsanStoragePoolDiskType.
#   These are declared at module scope in Private/Cluster.ps1 (not here) because they
#   belong semantically to the cluster/storage subsystem. Treat them as read-only constants.
# =============================================================================

#endregion

# Dot-source private implementation files in dependency order.
# Logging.ps1 is first because every other file calls Write-LogMessage.
. (Join-Path -Path $PSScriptRoot -ChildPath "Private/Logging.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "Private/Cluster.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "Private/Networking.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "Private/Supervisor.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "Private/Yaml.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "Private/Validation.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "Private/Deployment.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "Private/EntryPoints.ps1")
