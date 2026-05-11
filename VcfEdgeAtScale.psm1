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
# Last modified: 2026-05-10
#
# Private implementation files (dot-sourced below):
#   Private/Logging.ps1     — logging, vCenter connectivity, content library, witness prep
#   Private/Cluster.ps1     — cluster, datastore, vSAN, VMFS, disk operations
#   Private/Networking.ps1  — VDS, VMkernel cleanup, management restore
#   Private/Supervisor.ps1  — supervisor, Harbor, Argo CD, workload networking
#   Private/Validation.ps1  — cleanup, deployment bootstrap, validation, vLCM helpers
#   Private/EntryPoints.ps1 — Start-VcfEdgeAtScale, configuration help (exported)
#

#region Script scope variables
$local:manifestPath = Join-Path -Path $PSScriptRoot -ChildPath "VcfEdgeAtScale.psd1"
$Script:ModuleVersion = if (Test-Path -LiteralPath $local:manifestPath) {
    (Import-PowerShellDataFile -Path $local:manifestPath).ModuleVersion
} else {
    "unknown"
}

# Set platform-specific command names for cross-platform compatibility.
$Script:ArgocdCmd = if ($IsWindows) { "argocd.exe" } else { "argocd" }
$Script:KubectlCmd = if ($IsWindows) { "kubectl.exe" } else { "kubectl" }

# VCF CLI: on Windows, Broadcom ships `vcf.exe`; some environments expose the same binary as `vcf`. Prefer the first name found on PATH.
$Script:VcfCmd = $null
$local:vcfCliCandidates = if ($IsWindows) { @("vcf.exe", "vcf") } else { @("vcf") }
foreach ($vcfCliName in $local:vcfCliCandidates) {
    if (Get-Command -Name $vcfCliName -ErrorAction SilentlyContinue) {
        $Script:VcfCmd = $vcfCliName
        break
    }
}
if (-not $Script:VcfCmd) {
    $Script:VcfCmd = if ($IsWindows) { "vcf.exe" } else { "vcf" }
}

# Define log level hierarchy (lower number = lower priority, higher number = higher priority)
$Script:LogLevelHierarchy = @{
    "DEBUG" = 0
    "INFO" = 1
    "ADVISORY" = 2
    "WARNING" = 3
    "EXCEPTION" = 4
    "ERROR" = 5
}

# Initialize log level (will be set by Start-VcfEdgeAtScale)
$Script:ConfiguredLogLevel = "INFO"
# When $true, Invoke-PauseBeforeRollbackIfRequested will skip its prompt (cleanup confirmation is sufficient). Set during -CleanUp cleanup.
$Script:CleanUpOnly = $false
# Rollback on failure: $null = prompt (Y/N/Always), $true = always rollback (unattended), $false = never rollback (leave site broken, continue to next). Set by Start-VcfEdgeAtScale -RollbackOnFailure.
$Script:RollbackOnFailurePreference = $null
# When user chooses "Always" at the prompt, no further prompts for remaining sites; always rollback. Reset at start of each run.
$Script:RollbackAlwaysFromPrompt = $false
# Exception message thrown when user chooses No (or preference is never); caught by main loop to continue to next site.
$Script:RollbackSkippedContinueToNextSiteMessage = "Rollback skipped by user; continue to next site."
# Set when Invoke-VsanDeploymentRollback (or other rollback) is entered so the main catch does not prompt/run rollback again.
$Script:RollbackAttempted = $false
# Set when rollback fails (e.g. Remove-Cluster failed); main catch rethrows immediately so the script fails exit.
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
# ADDING A NEW SUPERVISOR SERVICE (e.g. "Velero", "Cert-Manager")
# When adding a third supervisor service alongside ArgoCD and Harbor, touch ALL of:
#   1. VcfEdgeAtScale.psm1      — Add $Script:<Service>PhaseStarted = $false here
#   2. Private/Validation.ps1   — Get-EffectiveSupervisorServiceFlag ValidateSet: add "disable<Service>"
#   3. Private/Validation.ps1   — Get-EffectiveSupervisorServicesYamlPath ValidateSet: add YAML path property names
#   4. Private/Validation.ps1   — Invoke-VcfEdgeAtScaleCleanup ValidateSet: add "<Service>" cleanup scope
#   5. Private/Validation.ps1   — Initialize-VcfEdgeAtScale: add deployment block and rollback branch
#   6. Private/EntryPoints.ps1  — Start-VcfEdgeAtScale ValidateSet: add "<Service>" to -CleanUp
#   7. Private/EntryPoints.ps1  — Start-VcfEdgeAtScale: add YAML preflight validation for new service
#   8. VcfEdgeAtScale.psm1      — Add $Script:ArgoCD<Service>*TimeoutSeconds constants if timeouts are configurable
# =============================================================================

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

# Enforce minimum engine version (must match PowerShellVersion in VcfEdgeAtScale.psd1).
if ($PSVersionTable.PSVersion -lt [Version]"7.4") {
    throw "VcfEdgeAtScale requires PowerShell 7.4 or later. Current version is $($PSVersionTable.PSVersion). Install a newer pwsh and retry."
}

#endregion

# Dot-source private implementation files in dependency order.
# Logging.ps1 is first because every other file calls Write-LogMessage.
. (Join-Path -Path $PSScriptRoot -ChildPath "Private/Logging.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "Private/Cluster.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "Private/Networking.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "Private/Supervisor.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "Private/Validation.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "Private/EntryPoints.ps1")
