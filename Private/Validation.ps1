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
#region Private — cleanup, deployment bootstrap, validation, vLCM helpers
function Get-ArgoCDNamespaceFromCluster {

    <#
        .SYNOPSIS
        Derives the ArgoCD supervisor namespace name for a given cluster object and cluster spec.

        .DESCRIPTION
        Combines the nameSpacePrefix (from cluster.supervisorServices.nameSpacePrefix, defaulting to "argocd")
        with the cluster MoRef ID (ExtensionData.MoRef.Value with "domain" stripped) to produce the
        namespace string used by ArgoCD cleanup and deployment. Extracted from three identical inline
        blocks in Invoke-VcfEdgeAtScaleCleanup and the main deployment workflow.

        .PARAMETER ClusterObject
        vSphere cluster object (output of Get-Cluster) with ExtensionData.MoRef.Value populated.

        .PARAMETER ClusterSpec
        The cluster element from infrastructure JSON (may have supervisorServices.nameSpacePrefix).

        .OUTPUTS
        [string] The derived ArgoCD namespace name.

        .EXAMPLE
        $ns = Get-ArgoCDNamespaceFromCluster -ClusterObject $clusterObj -ClusterSpec $cluster
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [System.Object]$ClusterObject,
        [Parameter(Mandatory = $false)] [AllowNull()] [PSObject]$ClusterSpec
    )

    $moRefFull = $ClusterObject.ExtensionData.MoRef.Value
    $moRefId = $moRefFull.Replace("domain", "")
    $prefix = "argocd"
    if ($ClusterSpec -and $ClusterSpec.supervisorServices -and -not [String]::IsNullOrWhiteSpace($ClusterSpec.supervisorServices.nameSpacePrefix)) {
        $prefix = $ClusterSpec.supervisorServices.nameSpacePrefix.Trim()
    }
    return ($prefix + "-" + $moRefId) -replace "--", "-"
}
function Invoke-VcfEdgeAtScaleCleanup {
    <#
        .SYNOPSIS
        Runs the cleanup workflow for one or more edge clusters (Supervisor-only, Compute-only, All, or ArgoCD). Used by Initialize-VcfEdgeAtScale when -CleanUp is set.

        .DESCRIPTION
        Sets Script:CleanUpOnly, then for each cluster: validates supervisor state, prompts for confirmation (unless labEnvironment and -Force), performs Supervisor-only, ArgoCD-only, Harbor-only, or Compute/All cleanup. For All cleanup the teardown order is: (1) remove Harbor Supervisor Service (PVCs must be gone before storage teardown), (2) remove ArgoCD namespace, (3) disable supervisor, (4) remove VMkernel interfaces, restore management to VSS, remove VDS, remove vSAN/VMFS and cluster. Throws if any cluster cleanup fails so the caller can exit without deploying.

        .PARAMETER ArgoCDNamespaceDeletePollIntervalSeconds
        When deleting the ArgoCD namespace (CleanUp ArgoCD), seconds between each check that the namespace is gone. Default is 5.

        .PARAMETER ArgoCDNamespaceDeleteTimeoutSeconds
        When deleting the ArgoCD namespace (CleanUp ArgoCD), maximum seconds to wait for the namespace to disappear before logging a warning and continuing. Default is 120.

        .PARAMETER CleanUp
        Scope: Supervisor, Compute, All, ArgoCD, or Harbor.

        .PARAMETER HarborServiceDeletePollIntervalSeconds
        When removing the Harbor service (CleanUp Harbor), seconds between each check that the service is gone. Default is 10.

        .PARAMETER HarborServiceDeleteTimeoutSeconds
        When removing the Harbor service (CleanUp Harbor), maximum seconds to wait for the service to disappear before logging a warning and continuing. Default is 180.

        .PARAMETER HarborServiceYamlPath
        Path to the harbor-service-x.xx.x.yml file. Required when CleanUp is Harbor; used to determine the Harbor service identifier. When omitted or the file is not found, Harbor cleanup is skipped for that cluster with a warning.

        .PARAMETER ClusterExistenceCheckDelaySeconds
        Seconds to wait after Remove-Cluster throws before re-checking if the cluster still exists (allows vCenter to update). Used only when cluster removal reports an error; if the cluster is gone after the delay, cleanup does not treat it as a failure.

        .PARAMETER ClusterExistenceCheckRetryDelaySeconds
        When the cluster still exists after the first existence check, wait this many seconds and check again before setting cleanupHadErrors. vCenter may remove the cluster asynchronously; a second check reduces false failures when the first check ran too soon. Use 0 to disable the retry (only one existence check). Default is 10.

        .PARAMETER ClusterNamePrefix
        Common cluster name prefix (e.g. from common.clusterNamePrefix).

        .PARAMETER ClustersToProcess
        Array of cluster objects from infrastructure JSON (filtered by EdgeSite when applicable).

        .PARAMETER DatastoreNamePrefix
        Common datastore name prefix (e.g. from common.datastoreNamePrefix).

        .PARAMETER Force
        When true and LabEnvironment is true, bypasses the cleanup confirmation prompt.

        .PARAMETER InputData
        Full infrastructure JSON object (for common.nicList, witness names, etc.).

        .PARAMETER LabEnvironment
        When true, lab mode messaging is logged; when true with Force, confirmation prompt is skipped.

        .PARAMETER SupervisorNamePrefix
        Common supervisor name prefix (e.g. from common.supervisorNamePrefix).

        .PARAMETER VdsNamePrefix
        Common VDS name prefix (e.g. from common.vdsNamePrefix).

        .OUTPUTS
        None. Throws if cleanup had errors; otherwise returns and caller exits without deploying.

        .NOTES
        Caller must ensure vCenter is connected and Script:vCenterName is set before calling.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(1, 60)] [Int]$ArgoCDNamespaceDeletePollIntervalSeconds = 5,
        [Parameter(Mandatory = $false)] [ValidateRange(10, 600)] [Int]$ArgoCDNamespaceDeleteTimeoutSeconds = 120,
        [Parameter(Mandatory = $true)] [ValidateSet("All", "ArgoCD", "Compute", "Harbor", "Supervisor")] [String]$CleanUp,
        [Parameter(Mandatory = $false)] [ValidateRange(0, 60)] [Int]$ClusterExistenceCheckDelaySeconds = 2,
        [Parameter(Mandatory = $false)] [ValidateRange(0, 60)] [Int]$ClusterExistenceCheckRetryDelaySeconds = 10,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterNamePrefix,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [System.Object[]]$ClustersToProcess,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DatastoreNamePrefix,
        [Parameter(Mandatory = $false)] [Switch]$Force,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 60)] [Int]$HarborServiceDeletePollIntervalSeconds = 10,
        [Parameter(Mandatory = $false)] [ValidateRange(10, 600)] [Int]$HarborServiceDeleteTimeoutSeconds = 180,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [String]$HarborServiceYamlPath,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSCustomObject]$InputData,
        [Parameter(Mandatory = $true)] [bool]$LabEnvironment,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorNamePrefix,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VdsNamePrefix
    )

    $Script:CleanUpOnly = $true
    if ($LabEnvironment) {
        Write-LogMessage -Type ADVISORY -Message "Running in lab mode (common.labenvironment is true in infrastructure JSON)."
    }
    $forceBypassPrompt = $Force -and $LabEnvironment
    if ($Force -and -not $LabEnvironment) {
        Write-LogMessage -Type ADVISORY -Message "-Force bypasses the cleanup confirmation only when common.labenvironment is true in infrastructure JSON. Lab is not enabled; you will be prompted to confirm."
    }
    $cleanupScope = $CleanUp
    $cleanupHadErrors = $false
    Write-LogMessage -Type INFO -Message "CleanUp is set to `"$cleanupScope`". Cleaning up per scope, then exiting without deploying."
    foreach ($cluster in $ClustersToProcess) {
        $currentEdgeSite = $cluster.edgeSite
        $clusterName = Get-EffectiveClusterName -Cluster $cluster -ClusterNamePrefix $ClusterNamePrefix -EdgeSite $currentEdgeSite
        $storagePolicyType = $null
        $storagePolicyTagCatalog = $null
        if ($cluster.storagePolicy) {
            $storagePolicyType = $cluster.storagePolicy.storageType
            $storagePolicyTagCatalog = $cluster.storagePolicy.storagePolicyTagCatalog
            if ([String]::IsNullOrWhiteSpace($storagePolicyTagCatalog)) {
                $storagePolicyTagCatalog = $storagePolicyType + "-Storage-TagCatalog"
            }
        }
        $clusterObjectForCleanup = Get-ClusterByName -Name $clusterName -Server $Script:vCenterName
        $wcpList = @()
        if ($clusterObjectForCleanup) {
            $clusterMoNameForWcp = $clusterObjectForCleanup.Name
            $wcpList = @(Invoke-ListNamespaceManagementClusters -ErrorAction SilentlyContinue | Where-Object {
                $null -ne $_.clusterName -and ($_.clusterName -eq $clusterMoNameForWcp -or $_.clusterName -eq $clusterName)
            })
        }
        $wcpEntry = $wcpList | Select-Object -First 1
        $configStatus = if ($wcpEntry) { $wcpEntry.ConfigStatus } else { $null }
        $kubeStatus = if ($wcpEntry) { $wcpEntry.KubernetesStatus } else { $null }
        $configDisabled = [string]::IsNullOrEmpty($configStatus) -or ($configStatus -eq "DISABLED")
        $kubeNotInstalled = [string]::IsNullOrEmpty($kubeStatus) -or ($kubeStatus -eq "NOT_INSTALLED")
        $supervisorEnabled = $wcpEntry -and -not ($configDisabled -and $kubeNotInstalled)

        if ($cleanupScope -eq "Compute" -and $supervisorEnabled) {
            Write-LogMessage -Type ERROR -Message "Supervisor is deployed on cluster `"$clusterName`" (edgeSite `"$currentEdgeSite`"). Cannot cleanup only compute when supervisor is deployed. Use -CleanUp Supervisor to remove the supervisor first, or -CleanUp All to remove both."
            throw [VcfDeploymentException]::new()
        }

        $promptType = $cleanupScope.ToLower()
        $expectedPromptText = "delete $promptType for $currentEdgeSite"
        $datastoreNameForPrompt = Get-DatastoreNameFromPrefix -DatastoreNamePrefix $DatastoreNamePrefix -EdgeSite $currentEdgeSite
        $argocdNamespaceForPrompt = $null
        if ($cleanupScope -eq "ArgoCD" -and $clusterObjectForCleanup) {
            $argocdNamespaceForPrompt = Get-ArgoCDNamespaceFromCluster -ClusterObject $clusterObjectForCleanup -ClusterSpec $cluster
        }
        if (-not $forceBypassPrompt) {
            Write-Host ""
            switch ($cleanupScope) {
                "Supervisor" {
                    Write-LogMessage -Type ADVISORY -Message "The cleanup process for supervisor will remove all the VMware vSphere Kubernetes Service (VKS) applications in cluster `"$clusterName`". Please backup your data before proceeding."
                }
                "ArgoCD" {
                    $argocdNameInMessage = if ($argocdNamespaceForPrompt) { "`"$argocdNamespaceForPrompt`"" } else { "(namespace name unknown)" }
                    Write-LogMessage -Type ADVISORY -Message "The cleanup process will remove only the ArgoCD namespace $argocdNameInMessage for cluster `"$clusterName`" (edgeSite `"$currentEdgeSite`"). No supervisor deactivation or compute removal. Please backup your data before proceeding."
                }
                "Harbor" {
                    Write-LogMessage -Type ADVISORY -Message "The cleanup process will remove only the Harbor Supervisor Service from the supervisor for cluster `"$clusterName`" (edgeSite `"$currentEdgeSite`"). No supervisor deactivation or compute removal. Please backup your data before proceeding."
                }
                default {
                    Write-LogMessage -Type ADVISORY -Message "The cleanup process will remove all resources on edgeSite `"$currentEdgeSite`" including cluster `"$clusterName`" and datastore `"$datastoreNameForPrompt`". Please backup your data before proceeding."
                }
            }
            Write-Output "To confirm cleanup, type exactly (or copy/paste): $expectedPromptText"
            $userInput = Read-Host
            $userInputNormalized = if ($userInput) { $userInput.Trim() } else { "" }
            if ($userInputNormalized -ne $expectedPromptText) {
                Write-LogMessage -Type ERROR -Message "Cleanup confirmation failed. Expected: `"$expectedPromptText`". Got: `"$userInputNormalized`". Script will terminate."
                throw [VcfDeploymentException]::new()
            }
        } else {
            Write-LogMessage -Type ADVISORY -Message "Skipping cleanup confirmation (labEnvironment=true and -Force)."
        }
        Write-LogMessage -Type DEBUG -Message "Cleanup confirmation passed. Proceeding with cleanup."
        switch ($cleanupScope) {
        "Supervisor" {
            if ($supervisorEnabled) {
                $clusterIdForCleanup = $clusterObjectForCleanup.ExtensionData.MoRef.Value
                if (-not $clusterIdForCleanup) { $clusterIdForCleanup = $clusterObjectForCleanup.Id -replace "^ClusterComputeResource-", "" }
                $disableResult = Disable-SupervisorOnCluster -ClusterId $clusterIdForCleanup -ClusterName $clusterName -SuppressConfirm
                if ($disableResult.Success) {
                    Write-LogMessage -Type INFO -Message "Supervisor deactivated on cluster `"$clusterName`". Compute (VDS, vSAN/VMFS, cluster) remains."
                } else {
                    Write-LogMessage -Type ERROR -Message "Supervisor deactivation failed: $($disableResult.ErrorMessage)."
                    throw [VcfDeploymentException]::new()
                }
            } else {
                Write-LogMessage -Type INFO -Message "No supervisor enabled on cluster `"$clusterName`". Nothing to remove for Supervisor-only cleanup."
            }
            continue
        }
        "ArgoCD" {
            Write-LogMessage -Type DEBUG -Message "ArgoCD cleanup: removing only the ArgoCD supervisor namespace for this cluster (no supervisor deactivation or compute removal)."
            if (-not $clusterObjectForCleanup) {
                Write-LogMessage -Type WARNING -Message "Cluster `"$clusterName`" not found; cannot resolve ArgoCD namespace name. Skipping ArgoCD cleanup for edgeSite `"$currentEdgeSite`"."
                continue
            }
            $argocdNamespace = Get-ArgoCDNamespaceFromCluster -ClusterObject $clusterObjectForCleanup -ClusterSpec $cluster
            $namespaceExists = (Invoke-ListNamespacesInstances -ErrorAction SilentlyContinue).Namespace -contains $argocdNamespace
            if ($namespaceExists) {
                $progressActivity = "Waiting for ArgoCD namespace `"$argocdNamespace`" to be removed"
                try {
                    Invoke-DeleteNamespaceInstances -Namespace $argocdNamespace -Confirm:$false -ErrorAction Stop | Out-Null
                    $elapsedSeconds = 0
                    while ($elapsedSeconds -lt $ArgoCDNamespaceDeleteTimeoutSeconds) {
                        $percentComplete = [Math]::Min(100, [int](($elapsedSeconds / $ArgoCDNamespaceDeleteTimeoutSeconds) * 100))
                        $statusMessage = "Polling (${elapsedSeconds}s / ${ArgoCDNamespaceDeleteTimeoutSeconds}s)..."
                        Write-Progress -Activity $progressActivity -Status $statusMessage -PercentComplete $percentComplete
                        [Console]::Out.Flush()
                        Start-Sleep -Seconds $ArgoCDNamespaceDeletePollIntervalSeconds
                        $elapsedSeconds += $ArgoCDNamespaceDeletePollIntervalSeconds
                        $stillExists = $true
                        try {
                            $namespaceList = (Invoke-ListNamespacesInstances -ErrorAction Stop).Namespace
                            if ($null -ne $namespaceList) {
                                $stillExists = $namespaceList -contains $argocdNamespace
                            }
                        } catch {
                            Write-LogMessage -Type DEBUG -Message "Invoke-ListNamespacesInstances failed during poll; treating namespace as still present. $($_.Exception.Message)"
                        }
                        if (-not $stillExists) {
                            Write-Progress -Activity $progressActivity -Status "Complete" -PercentComplete 100 -Completed
                            [Console]::Out.Flush()
                            Write-LogMessage -Type INFO -Message "ArgoCD namespace `"$argocdNamespace`" deleted successfully for cluster `"$clusterName`"."
                            break
                        }
                        Write-LogMessage -Type DEBUG -Message "ArgoCD namespace `"$argocdNamespace`" still present; waiting (elapsed ${elapsedSeconds}s, timeout ${ArgoCDNamespaceDeleteTimeoutSeconds}s)."
                    }
                    if ($elapsedSeconds -ge $ArgoCDNamespaceDeleteTimeoutSeconds) {
                        $stillExistsAfterWait = $true
                        try {
                            $namespaceListAfterWait = (Invoke-ListNamespacesInstances -ErrorAction Stop).Namespace
                            if ($null -ne $namespaceListAfterWait) {
                                $stillExistsAfterWait = $namespaceListAfterWait -contains $argocdNamespace
                            }
                        } catch {
                            Write-LogMessage -Type DEBUG -Message "Invoke-ListNamespacesInstances failed at timeout check; assuming namespace still present. $($_.Exception.Message)"
                        }
                        if ($stillExistsAfterWait) {
                            Write-Progress -Activity $progressActivity -Status "Timeout" -Completed
                            [Console]::Out.Flush()
                            Write-LogMessage -Type WARNING -Message "ArgoCD namespace `"$argocdNamespace`" still exists after ${ArgoCDNamespaceDeleteTimeoutSeconds}s. Delete was initiated; verify in vCenter that the namespace is removed."
                        } else {
                            Write-Progress -Activity $progressActivity -Status "Complete" -PercentComplete 100 -Completed
                            [Console]::Out.Flush()
                            Write-LogMessage -Type INFO -Message "ArgoCD namespace `"$argocdNamespace`" deleted successfully for cluster `"$clusterName`"."
                        }
                    }
                } catch {
                    Write-Progress -Activity $progressActivity -Status "Error" -Completed
                    [Console]::Out.Flush()
                    $cleanupHadErrors = $true
                    Write-LogMessage -Type ERROR -Message "Failed to delete ArgoCD namespace `"$argocdNamespace`" for cluster `"$clusterName`": $($_.Exception.Message). Continuing to next cluster."
                }
            } else {
                Write-LogMessage -Type INFO -Message "ArgoCD namespace `"$argocdNamespace`" does not exist for cluster `"$clusterName`". Nothing to remove."
            }
            continue
        }
        "Harbor" {
            Write-LogMessage -Type DEBUG -Message "Harbor cleanup: removing only the Harbor Supervisor Service from the supervisor for this cluster (no supervisor deactivation or compute removal)."
            if (-not $clusterObjectForCleanup) {
                Write-LogMessage -Type WARNING -Message "Cluster `"$clusterName`" not found; cannot determine supervisor ID. Skipping Harbor cleanup for edgeSite `"$currentEdgeSite`"."
                continue
            }

            # Resolve supervisor ID and Harbor service identifier.
            $harborSupervisorId = $null
            try {
                $harborSupervisorId = Get-SupervisorId -supervisorName (Get-SupervisorNameFromPrefix -SupervisorNamePrefix $SupervisorNamePrefix -EdgeSite $currentEdgeSite) -VcenterUser $Script:VCenterUser -VcenterCredential $Script:VcenterCredential -InsecureTls -Silence -ErrorAction Stop
            } catch {
                Write-LogMessage -Type WARNING -Message "Could not determine supervisor ID for cluster `"$clusterName`" (edgeSite `"$currentEdgeSite`"): $($_.Exception.Message). Skipping Harbor cleanup."
                continue
            }
            if ([String]::IsNullOrWhiteSpace($harborSupervisorId)) {
                Write-LogMessage -Type WARNING -Message "Supervisor ID not found for cluster `"$clusterName`". Skipping Harbor cleanup."
                continue
            }

            # Determine the Harbor service identifier from the harbor-service YAML (same Carvel Package format as ArgoCD).
            $harborServiceIdentifier = $null
            if (-not [String]::IsNullOrWhiteSpace($HarborServiceYamlPath) -and (Test-Path -Path $HarborServiceYamlPath)) {
                $harborServiceIdentifier, $null = Get-ArgoCDServiceDetail -Path $HarborServiceYamlPath
            } else {
                Write-LogMessage -Type WARNING -Message "Harbor service YAML not provided or file not found; cannot determine Harbor service identifier for cluster `"$clusterName`". Provide -HarborServiceYamlPath or set supervisorServices.parentDirectory and harborServiceYamlFileName in infrastructure.json."
            }
            if ([String]::IsNullOrWhiteSpace($harborServiceIdentifier)) {
                Write-LogMessage -Type WARNING -Message "Could not determine Harbor service identifier for cluster `"$clusterName`". Skipping Harbor cleanup."
                continue
            }

            try {
                Remove-HarborSupervisorService -ClusterName $clusterName -DeletePollIntervalSeconds $HarborServiceDeletePollIntervalSeconds -DeleteTimeoutSeconds $HarborServiceDeleteTimeoutSeconds -Service $harborServiceIdentifier -SupervisorId $harborSupervisorId
            } catch {
                $cleanupHadErrors = $true
                Write-LogMessage -Type ERROR -Message "Harbor cleanup failed for cluster `"$clusterName`": $($_.Exception.Message). Continuing to next cluster."
            }
            continue
        }
        } # end switch ($cleanupScope) — Supervisor/ArgoCD/Harbor handled above

        # Compute and All cleanup: handled outside the switch due to compound brace nesting.
        if ($cleanupScope -eq "Compute" -or $cleanupScope -eq "All") {
            if ($cleanupScope -eq "All" -and $supervisorEnabled) {
                # Remove supervisor services before deactivating — Harbor first (owns PVCs), then ArgoCD.
                $allSupervisorId = $null
                try {
                    $allSupervisorId = Get-SupervisorId -supervisorName (Get-SupervisorNameFromPrefix -SupervisorNamePrefix $SupervisorNamePrefix -EdgeSite $currentEdgeSite) -VcenterUser $Script:VCenterUser -VcenterCredential $Script:VcenterCredential -InsecureTls -Silence -ErrorAction Stop
                } catch {
                    Write-LogMessage -Type WARNING -Message "All cleanup: could not resolve supervisor ID for `"$clusterName`" (edgeSite `"$currentEdgeSite`"): $($_.Exception.Message). Skipping service pre-removal."
                }

                if (-not [String]::IsNullOrWhiteSpace($allSupervisorId)) {
                    # Remove Harbor service so its PVCs are gone before vSAN/VMFS is torn down.
                    $allHarborSvcId = $null
                    if (-not [String]::IsNullOrWhiteSpace($HarborServiceYamlPath) -and (Test-Path -Path $HarborServiceYamlPath)) {
                        $allHarborSvcId, $null = Get-ArgoCDServiceDetail -Path $HarborServiceYamlPath
                    }
                    if (-not [String]::IsNullOrWhiteSpace($allHarborSvcId)) {
                        try {
                            Remove-HarborSupervisorService -ClusterName $clusterName -DeletePollIntervalSeconds $HarborServiceDeletePollIntervalSeconds -DeleteTimeoutSeconds $HarborServiceDeleteTimeoutSeconds -Service $allHarborSvcId -SupervisorId $allSupervisorId
                        } catch {
                            Write-LogMessage -Type WARNING -Message "All cleanup: Harbor service removal failed for cluster `"$clusterName`": $($_.Exception.Message). Continuing with supervisor deactivation."
                        }
                    } else {
                        Write-LogMessage -Type DEBUG -Message "All cleanup: HarborServiceYamlPath not provided or Harbor service identifier not found; skipping Harbor pre-removal for cluster `"$clusterName`"."
                    }

                    # Remove the ArgoCD namespace before disabling the supervisor.
                    $allArgocdNs = Get-ArgoCDNamespaceFromCluster -ClusterObject $clusterObjectForCleanup -ClusterSpec $cluster
                    $allArgocdExists = $false
                    try {
                        $allArgocdExists = (Invoke-ListNamespacesInstances -ErrorAction Stop).Namespace -contains $allArgocdNs
                    } catch {
                        Write-LogMessage -Type DEBUG -Message "All cleanup: could not check ArgoCD namespace existence: $($_.Exception.Message)."
                    }
                    if ($allArgocdExists) {
                        try {
                            Invoke-DeleteNamespaceInstances -Namespace $allArgocdNs -Confirm:$false -ErrorAction Stop | Out-Null
                            Write-LogMessage -Type INFO -NoNewline -Message "All cleanup: ArgoCD namespace `"$allArgocdNs`" deletion initiated for cluster `"$clusterName`"... "
                            $allArgocdElapsed = 0
                            $allArgocdStillExists = $true
                            while ($allArgocdElapsed -lt $ArgoCDNamespaceDeleteTimeoutSeconds) {
                                Start-Sleep -Seconds $ArgoCDNamespaceDeletePollIntervalSeconds
                                $allArgocdElapsed += $ArgoCDNamespaceDeletePollIntervalSeconds
                                try {
                                    $allNsList = (Invoke-ListNamespacesInstances -ErrorAction Stop).Namespace
                                    if ($null -ne $allNsList) { $allArgocdStillExists = $allNsList -contains $allArgocdNs }
                                } catch {
                                    Write-LogMessage -Type DEBUG -Message "All cleanup: namespace poll failed during ArgoCD wait. $($_.Exception.Message)"
                                }
                                if (-not $allArgocdStillExists) {
                                    Write-LogMessage -Type INFO -CompletePending -Message "deleted after $allArgocdElapsed seconds."
                                    break
                                }
                            }
                            if ($allArgocdStillExists) {
                                Write-LogMessage -Type WARNING -CompletePending -Message "still present after ${ArgoCDNamespaceDeleteTimeoutSeconds}s. Supervisor deactivation will proceed."
                            }
                        } catch {
                            Write-LogMessage -Type WARNING -CompletePending -Message "deletion failed for cluster `"$clusterName`": $($_.Exception.Message). Continuing with supervisor deactivation."
                        }
                    } else {
                        Write-LogMessage -Type DEBUG -Message "All cleanup: ArgoCD namespace `"$allArgocdNs`" not found for cluster `"$clusterName`". Nothing to remove."
                    }
                }

                $clusterIdForCleanup = $clusterObjectForCleanup.ExtensionData.MoRef.Value
                if (-not $clusterIdForCleanup) { $clusterIdForCleanup = $clusterObjectForCleanup.Id -replace "^ClusterComputeResource-", "" }
                $disableResult = Disable-SupervisorOnCluster -ClusterId $clusterIdForCleanup -ClusterName $clusterName -SuppressConfirm
                if (-not $disableResult.Success) {
                    Write-LogMessage -Type ERROR -Message "Supervisor deactivation did not complete: $($disableResult.ErrorMessage). Skipping compute cleanup for `"$clusterName`"."
                    continue
                }
            }
        }

        if (($cleanupScope -eq "Compute" -or $cleanupScope -eq "All") -and ($storagePolicyType -eq "vSAN-ESA" -or $storagePolicyType -eq "vSAN-OSA" -or $storagePolicyType -eq "VMFS")) {
            $Script:SupervisorName = Get-SupervisorNameFromPrefix -SupervisorNamePrefix $SupervisorNamePrefix -EdgeSite $currentEdgeSite
            $rollbackParams = $null
            if ($storagePolicyType -eq "vSAN-ESA" -or $storagePolicyType -eq "vSAN-OSA") {
                $rollbackParams = @{ ClusterName = $clusterName; StoragePolicyType = $storagePolicyType }
                if ($storagePolicyTagCatalog) {
                    $rollbackParams["StoragePolicyTagCatalog"] = $storagePolicyTagCatalog
                    $rollbackParams["StoragePolicyTagName"] = $Script:SupervisorName
                }
                if ($cluster.esxHosts -and $cluster.esxHosts.Count -gt 0) { $rollbackParams["EsxHostNames"] = @($cluster.esxHosts) }
                $witnessName = $null
                if (-not [String]::IsNullOrWhiteSpace($cluster.vSanWitnessVmName)) { $witnessName = $cluster.vSanWitnessVmName }
                elseif ($InputData.common -and -not [String]::IsNullOrWhiteSpace($InputData.common.vSanWitnessVmName)) { $witnessName = $InputData.common.vSanWitnessVmName }
                if ($witnessName) { $rollbackParams["WitnessHostName"] = $witnessName }
                $rollbackParams["SkipClusterRemoval"] = $true
            }
            $vdsName = Get-VdsNameFromPrefix -VdsNamePrefix $VdsNamePrefix -EdgeSite $currentEdgeSite
            $nicListForRestore = Get-EffectiveNicListForCluster -Cluster $cluster -CommonNicList $InputData.common.nicList
            if (-not $nicListForRestore -or $nicListForRestore.Count -eq 0) {
                $nicListForRestore = $InputData.common.nicList
            }
            $nicListCountForRestore = if ($nicListForRestore -and $nicListForRestore.Count -eq 4) { 4 } else { 2 }
            $vdsNamesForCleanup = @($vdsName, "$vdsName-sw1", "$vdsName-sw2")
            try {
                Remove-NonVmk0VmkernelInterfacesFromVds -ClusterName $clusterName -VdsNames $vdsNamesForCleanup
            } catch {
                Write-LogMessage -Type WARNING -Message "Non-vmk0 VMkernel removal had errors for cluster `"$clusterName`" (non-fatal): $($_.Exception.Message)."
            }
            try {
                $restoreResult = Invoke-ManagementRestoreForCleanupWithTopologyFallback -ClusterName $clusterName -NicListCount $nicListCountForRestore -VdsName $vdsName
            } catch {
                $cleanupHadErrors = $true
                throw
            }
            if ($restoreResult.RestoreAttempted -and -not $restoreResult.Success) {
                $cleanupHadErrors = $true
                Write-LogMessage -Type ERROR -Message "Management was not moved back to VSS for cluster `"$clusterName`". $($restoreResult.Message) Move vmk0 off the VDS manually on each host, then retry cleanup. Skipping VDS and cluster removal for this cluster."
            } else {
                $vdsRemovalSucceeded = $true
                if ($storagePolicyType -eq "VMFS") {
                    Write-LogMessage -Type INFO -NoNewline -Message "Removing VDS(es) for cluster `"$clusterName`"... "
                    try { Remove-EdgeClusterDistributedSwitch -ClusterName $clusterName -VdsName $vdsName }
                    catch { $vdsRemovalSucceeded = $false; Write-LogMessage -Type WARNING -Message "Could not remove VDS `"$vdsName`" for cluster `"$clusterName`": $($_.Exception.Message)." }
                    try { Remove-EdgeClusterDistributedSwitch -ClusterName $clusterName -VdsName "$vdsName-sw1" }
                    catch { $vdsRemovalSucceeded = $false; Write-LogMessage -Type WARNING -Message "Could not remove VDS `"$vdsName-sw1`" for cluster `"$clusterName`": $($_.Exception.Message)." }
                    try { Remove-EdgeClusterDistributedSwitch -ClusterName $clusterName -VdsName "$vdsName-sw2" }
                    catch { $vdsRemovalSucceeded = $false; Write-LogMessage -Type WARNING -Message "Could not remove VDS `"$vdsName-sw2`" for cluster `"$clusterName`": $($_.Exception.Message)." }
                    if ($vdsRemovalSucceeded) {
                        Write-LogMessage -Type INFO -CompletePending -Message "Done"
                        $vmfsDatastoreName = Get-DatastoreNameFromPrefix -DatastoreNamePrefix $DatastoreNamePrefix -EdgeSite $currentEdgeSite
                        Remove-VmfsDatastoreForCluster -ClusterName $clusterName -DatastoreName $vmfsDatastoreName
                        try { Remove-ClusterSafely -ClusterName $clusterName }
                        catch {
                            Write-LogMessage -Type DEBUG -Message "Remove-Cluster threw for `"$clusterName`"; waiting $ClusterExistenceCheckDelaySeconds s then re-checking if cluster still exists (vCenter may have removed it despite the error)."
                            Start-Sleep -Seconds $ClusterExistenceCheckDelaySeconds
                            $clusterStillExists = Get-ClusterByName -Name $clusterName -Server $Script:vCenterName
                            if ($clusterStillExists -and $ClusterExistenceCheckRetryDelaySeconds -gt 0) {
                                Write-LogMessage -Type DEBUG -Message "Cluster still reported after first check; waiting $ClusterExistenceCheckRetryDelaySeconds s then re-checking (vCenter may be removing asynchronously)."
                                Start-Sleep -Seconds $ClusterExistenceCheckRetryDelaySeconds
                                $clusterStillExists = Get-ClusterByName -Name $clusterName -Server $Script:vCenterName
                            }
                            if (-not $clusterStillExists) {
                                Write-LogMessage -Type INFO -Message "Cluster `"$clusterName`" was removed (vCenter reported an error but the cluster is no longer present)."
                            } else {
                                Write-LogMessage -Type DEBUG -Message "Get-Cluster still returned a cluster for `"$clusterName`" (Id: $($clusterStillExists.Id)). Treating as removal failure."
                                $cleanupHadErrors = $true
                                Write-LogMessage -Type WARNING -Message "Could not remove cluster `"$clusterName`" after VMFS cleanup: $($_.Exception.Message). Remove the cluster manually if desired."
                            }
                        }
                    } else {
                        $cleanupHadErrors = $true
                        Write-LogMessage -Type WARNING -CompletePending -Message "Partial (see warnings above)"
                        Write-LogMessage -Type WARNING -Message "Skipping VMFS datastore and cluster removal for `"$clusterName`" because VDS removal failed. Move VMkernel adapters and VMs off the VDS port groups, then remove the VDS and cluster manually or retry cleanup."
                    }
                } else {
                    Invoke-VsanDeploymentRollback @rollbackParams
                    Write-LogMessage -Type INFO -NoNewline -Message "Removing VDS(es) for cluster `"$clusterName`"... "
                    try { Remove-EdgeClusterDistributedSwitch -ClusterName $clusterName -VdsName $vdsName }
                    catch { $vdsRemovalSucceeded = $false; Write-LogMessage -Type WARNING -Message "Could not remove VDS `"$vdsName`" for cluster `"$clusterName`": $($_.Exception.Message)." }
                    try { Remove-EdgeClusterDistributedSwitch -ClusterName $clusterName -VdsName "$vdsName-sw1" }
                    catch { $vdsRemovalSucceeded = $false; Write-LogMessage -Type WARNING -Message "Could not remove VDS `"$vdsName-sw1`" for cluster `"$clusterName`": $($_.Exception.Message)." }
                    try { Remove-EdgeClusterDistributedSwitch -ClusterName $clusterName -VdsName "$vdsName-sw2" }
                    catch { $vdsRemovalSucceeded = $false; Write-LogMessage -Type WARNING -Message "Could not remove VDS `"$vdsName-sw2`" for cluster `"$clusterName`": $($_.Exception.Message)." }
                    if ($vdsRemovalSucceeded) {
                        Write-LogMessage -Type INFO -CompletePending -Message "Done"
                        try { Remove-ClusterSafely -ClusterName $clusterName }
                        catch {
                            Write-LogMessage -Type DEBUG -Message "Remove-Cluster threw for `"$clusterName`"; waiting $ClusterExistenceCheckDelaySeconds s then re-checking if cluster still exists (vCenter may have removed it despite the error)."
                            Start-Sleep -Seconds $ClusterExistenceCheckDelaySeconds
                            $clusterStillExists = Get-ClusterByName -Name $clusterName -Server $Script:vCenterName
                            if ($clusterStillExists -and $ClusterExistenceCheckRetryDelaySeconds -gt 0) {
                                Write-LogMessage -Type DEBUG -Message "Cluster still reported after first check; waiting $ClusterExistenceCheckRetryDelaySeconds s then re-checking (vCenter may be removing asynchronously)."
                                Start-Sleep -Seconds $ClusterExistenceCheckRetryDelaySeconds
                                $clusterStillExists = Get-ClusterByName -Name $clusterName -Server $Script:vCenterName
                            }
                            if (-not $clusterStillExists) {
                                Write-LogMessage -Type INFO -Message "Cluster `"$clusterName`" was removed (vCenter reported an error but the cluster is no longer present)."
                            } else {
                                Write-LogMessage -Type DEBUG -Message "Get-Cluster still returned a cluster for `"$clusterName`" (Id: $($clusterStillExists.Id)). Treating as removal failure."
                                $cleanupHadErrors = $true
                                Write-LogMessage -Type WARNING -Message "Could not remove cluster `"$clusterName`" after vSAN/VDS cleanup: $($_.Exception.Message). Remove the cluster manually if desired."
                            }
                        }
                    } else {
                        $cleanupHadErrors = $true
                        Write-LogMessage -Type WARNING -CompletePending -Message "Partial (see warnings above)"
                        Write-LogMessage -Type WARNING -Message "Skipping cluster removal for `"$clusterName`" because VDS removal failed. Move VMkernel adapters and VMs off the VDS port groups, then remove the VDS and cluster manually or retry cleanup."
                    }
                }
            }
        } elseif ($storagePolicyType -ne "vSAN-ESA" -and $storagePolicyType -ne "vSAN-OSA" -and $storagePolicyType -ne "VMFS") {
            Write-LogMessage -Type DEBUG -Message "Skipping compute cleanup for cluster `"$clusterName`" (storage type `"$storagePolicyType`" is not ESA/OSA/VMFS)."
        }
        } # end if Compute/All
    if ($cleanupHadErrors) {
        Write-LogMessage -Type ERROR -Message "CleanUp ($cleanupScope) did not complete successfully. One or more clusters had errors (e.g. management restore failed, VDS or cluster removal failed). Review the log and resolve the issues, then retry cleanup or remove resources manually."
        throw [VcfDeploymentException]::new()
    }
}
function Get-VsanWitnessNameForCluster {

    <#
        .SYNOPSIS
        Resolves the vSAN witness host name for a cluster from cluster root or common.

        .DESCRIPTION
        Returns the first non-empty value from cluster.vSanWitnessVmName or InputData.common.vSanWitnessVmName. Used by Initialize-VcfEdgeAtScale for vSAN clusters only; callers must check whether the cluster storage type requires a witness before acting on the return value (e.g. non-vSAN clusters should ignore a non-null result).
        .PARAMETER Cluster
        Cluster object from infrastructure JSON (may have vSanWitnessVmName at the cluster root).
        .PARAMETER InputData
        Full parsed infrastructure JSON (for common.vSanWitnessVmName).
        .OUTPUTS
        [string] or $null if no witness name is configured.
    #>

    Param (
        [Parameter(Mandatory = $true)] [AllowNull()] [PSObject]$Cluster,
        [Parameter(Mandatory = $true)] [AllowNull()] [PSObject]$InputData
    )

    if (-not $Cluster) { return $null }
    if (-not [String]::IsNullOrWhiteSpace($Cluster.vSanWitnessVmName)) {
        return $Cluster.vSanWitnessVmName
    }
    if ($InputData -and $InputData.common -and -not [String]::IsNullOrWhiteSpace($InputData.common.vSanWitnessVmName)) {
        return $InputData.common.vSanWitnessVmName
    }
    return $null
}
function Get-EffectiveHaPolicyForCluster {

    <#
        .SYNOPSIS
        Resolves HA admission policy for vSAN-OSA / vSAN-ESA clusters from cluster root or common.

        .DESCRIPTION
        Returns clusters[].haPolicy when set to a valid value; otherwise common.haPolicy when set; otherwise reservationBased.
        Invalid values are rejected by Test-JsonHaPolicy during deeper JSON validation.
        Used only for two-or-more-node vSAN clusters when calling Update-Cluster / Invoke-ReconfigureClusterHA.

        .PARAMETER Cluster
        Cluster object from infrastructure JSON (optional clusters[].haPolicy).

        .PARAMETER InputData
        Parsed infrastructure JSON (optional common.haPolicy).

        .OUTPUTS
        String: slotBased, reservationBased, or disabled.
    #>

    Param (
        [Parameter(Mandatory = $true)] [AllowNull()] [PSObject]$Cluster,
        [Parameter(Mandatory = $true)] [AllowNull()] [PSObject]$InputData
    )

    $allowed = @("slotBased", "reservationBased", "disabled")
    if ($Cluster -and $Cluster.PSObject.Properties["haPolicy"] -and $null -ne $Cluster.haPolicy -and -not [String]::IsNullOrWhiteSpace([String]$Cluster.haPolicy)) {
        $v = ([String]$Cluster.haPolicy).Trim()
        if ($v -in $allowed) {
            return $v
        }
    }
    if ($InputData -and $InputData.common -and $InputData.common.PSObject.Properties["haPolicy"] -and $null -ne $InputData.common.haPolicy -and -not [String]::IsNullOrWhiteSpace([String]$InputData.common.haPolicy)) {
        $v = ([String]$InputData.common.haPolicy).Trim()
        if ($v -in $allowed) {
            return $v
        }
    }
    return "reservationBased"
}
function Test-EdgeSiteNameValid {

    <#
        .SYNOPSIS
        Returns $true when a string is a valid edgeSite name.

        .DESCRIPTION
        A valid edgeSite name is 1–80 characters, lowercase letters, digits, and hyphens only,
        and must not start or end with a hyphen. Matches the JavaScript _isValidRfc1123 function in
        veas-ui.html and the Python RFC1123_RE constant in veas-json-generator.py.

        .PARAMETER Name
        The candidate edgeSite name to test.

        .OUTPUTS
        Boolean - $true when valid; $false when the name is missing, too long, or contains invalid characters.

        .EXAMPLE
        Test-EdgeSiteNameValid -Name "site1"
        # Returns: $true.

        .EXAMPLE
        Test-EdgeSiteNameValid -Name "-bad"
        # Returns: $false.
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [String]$Name
    )

    if ([String]::IsNullOrWhiteSpace($Name)) {
        return $false
    }
    return $Name -cmatch '^[a-z0-9]([a-z0-9-]{0,78}[a-z0-9])?$'
}
function Get-EffectiveClusterName {

    <#
        .SYNOPSIS
        Resolves the vSphere cluster name for an edge site.

        .DESCRIPTION
        Returns clusters[].overrideClusterName when it is present and non-empty, after validating that the
        value conforms to vSphere object name constraints (1-80 characters; alphanumeric, spaces, _, +, -, (), .).
        Falls back to the generated name when the key is absent or empty.

        .PARAMETER Cluster
        Cluster object from infrastructure JSON (may have overrideClusterName).

        .PARAMETER ClusterNamePrefix
        Common cluster name prefix used when generating the default name.

        .PARAMETER EdgeSite
        Edge site identifier used when generating the default name.

        .OUTPUTS
        String: the effective vSphere cluster name for this edge site.

        .EXAMPLE
        $clusterName = Get-EffectiveClusterName -Cluster $cluster -ClusterNamePrefix "cl0" -EdgeSite "site1"
        # Returns "cl0-site1" when overrideClusterName is absent, or the override value when set.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$Cluster,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterNamePrefix,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EdgeSite
    )

    if ($Cluster.PSObject.Properties["overrideClusterName"] -and -not [String]::IsNullOrWhiteSpace($Cluster.overrideClusterName)) {
        $overrideName = ([String]$Cluster.overrideClusterName).Trim()
        if ($overrideName -notmatch '^[a-zA-Z0-9 _+\-().]{1,80}$') {
            Write-LogMessage -Type ERROR -Message "clusters[$EdgeSite].overrideClusterName `"$overrideName`": must be 1-80 characters, alphanumeric with spaces, _, +, -, (), ."
            throw [VcfDeploymentException]::new("clusters[$EdgeSite].overrideClusterName failed validation. See log for details.")
        }
        Write-LogMessage -Type DEBUG -Message "Using overrideClusterName `"$overrideName`" for edgeSite `"$EdgeSite`" (overrides prefix+site formula)."
        return $overrideName
    }
    return Get-ClusterNameFromPrefix -ClusterNamePrefix $ClusterNamePrefix -EdgeSite $EdgeSite
}
function Get-EffectiveSupervisorServicesYamlPath {

    <#
        .SYNOPSIS
        Resolves the full path to a supervisor service YAML file from parentDirectory and file name keys.

        .DESCRIPTION
        When **parentDirectory** (cluster then common) and the matching **\*YamlFileName** are both
        set, builds Join-Path(parent, fileName) and passes it through
        Resolve-InfrastructureReferencedFilePath. Otherwise falls back to legacy
        **supervisorServices.argoCdOperatorYamlPath**, **argoCdDeploymentYamlPath**,
        **harborDataTemplateYamlPath**, and **harborServiceYamlPath** (cluster over common), i.e.
        fully qualified or resolvable paths as before.

        .PARAMETER Cluster
        Cluster object from infrastructure JSON (optional cluster-level supervisorServices overrides).

        .PARAMETER CommonData
        The common section of infrastructure JSON (supervisorServices defaults).

        .PARAMETER LogicalYamlPathPropertyName
        Logical key matching deployment usage: argoCdDeploymentYamlPath, argoCdOperatorYamlPath,
        harborDataTemplateYamlPath, or harborServiceYamlPath (maps to *YamlFileName properties).

        .OUTPUTS
        [string] Resolved full path when the new or legacy configuration resolves; otherwise $null.

        .EXAMPLE
        $p = Get-EffectiveSupervisorServicesYamlPath -Cluster $cluster -CommonData $inputData.common -LogicalYamlPathPropertyName "argoCdDeploymentYamlPath"
    #>

    Param (
        [Parameter(Mandatory = $true)] [AllowNull()] [PSObject]$Cluster,
        [Parameter(Mandatory = $true)] [AllowNull()] [PSObject]$CommonData,
        [Parameter(Mandatory = $true)] [ValidateSet("argoCdDeploymentYamlPath", "argoCdOperatorYamlPath", "harborDataTemplateYamlPath", "harborServiceYamlPath")] [String]$LogicalYamlPathPropertyName
    )

    $fileNamePropertyName = switch ($LogicalYamlPathPropertyName) {
        "argoCdDeploymentYamlPath"   { "argoCdDeploymentYamlFileName" }
        "argoCdOperatorYamlPath"     { "argoCdOperatorYamlFileName" }
        "harborDataTemplateYamlPath" { "harborDataTemplateYamlFileName" }
        "harborServiceYamlPath"      { "harborServiceYamlFileName" }
    }

    $commonSvc = if ($CommonData -and $CommonData.supervisorServices) { $CommonData.supervisorServices } else { $null }
    $clusterSvc = if ($Cluster -and $Cluster.supervisorServices) { $Cluster.supervisorServices } else { $null }

    $parentRaw = $null
    if ($clusterSvc -and $clusterSvc.PSObject.Properties["parentDirectory"] -and -not [String]::IsNullOrWhiteSpace([String]$clusterSvc.parentDirectory)) {
        $parentRaw = [String]$clusterSvc.parentDirectory
    } elseif ($commonSvc -and $commonSvc.PSObject.Properties["parentDirectory"] -and -not [String]::IsNullOrWhiteSpace([String]$commonSvc.parentDirectory)) {
        $parentRaw = [String]$commonSvc.parentDirectory
    }

    $fileRaw = $null
    if ($clusterSvc -and $clusterSvc.PSObject.Properties[$fileNamePropertyName] -and -not [String]::IsNullOrWhiteSpace([String]$clusterSvc.$fileNamePropertyName)) {
        $fileRaw = [String]$clusterSvc.$fileNamePropertyName
    } elseif ($commonSvc -and $commonSvc.PSObject.Properties[$fileNamePropertyName] -and -not [String]::IsNullOrWhiteSpace([String]$commonSvc.$fileNamePropertyName)) {
        $fileRaw = [String]$commonSvc.$fileNamePropertyName
    }

    if (-not [String]::IsNullOrWhiteSpace($parentRaw) -and -not [String]::IsNullOrWhiteSpace($fileRaw)) {
        $combined = $null
        try {
            $combined = [System.IO.Path]::GetFullPath((Join-Path -Path $parentRaw.Trim() -ChildPath $fileRaw.Trim()))
        } catch {
            Write-LogMessage -Type DEBUG -Message "Get-EffectiveSupervisorServicesYamlPath: could not combine parent and file name for $LogicalYamlPathPropertyName : $($_.Exception.Message)"
            $combined = $null
        }
        if (-not [String]::IsNullOrWhiteSpace($combined)) {
            return Resolve-InfrastructureReferencedFilePath -FilePath $combined -InfrastructureJsonDirectory $Script:InfrastructureJsonParentForPathResolution
        }
    }

    $legacyPath = $null
    if ($clusterSvc -and $clusterSvc.PSObject.Properties[$LogicalYamlPathPropertyName] -and -not [String]::IsNullOrWhiteSpace([String]$clusterSvc.$LogicalYamlPathPropertyName)) {
        $legacyPath = [String]$clusterSvc.$LogicalYamlPathPropertyName
    } elseif ($commonSvc -and $commonSvc.PSObject.Properties[$LogicalYamlPathPropertyName] -and -not [String]::IsNullOrWhiteSpace([String]$commonSvc.$LogicalYamlPathPropertyName)) {
        $legacyPath = [String]$commonSvc.$LogicalYamlPathPropertyName
    }
    if (-not [String]::IsNullOrWhiteSpace($legacyPath)) {
        return Resolve-InfrastructureReferencedFilePath -FilePath $legacyPath.Trim() -InfrastructureJsonDirectory $Script:InfrastructureJsonParentForPathResolution
    }

    return $null
}
function Get-EffectiveArgoCdYamlPath {

    <#
        .SYNOPSIS
        Resolves the effective Argo CD operator or deployment YAML file path for a cluster.

        .DESCRIPTION
        Delegates to Get-EffectiveSupervisorServicesYamlPath (parentDirectory + file names, or legacy
        argoCdOperatorYamlPath / argoCdDeploymentYamlPath).

        .PARAMETER Cluster
        Cluster object from infrastructure JSON (may have supervisorServices overrides).

        .PARAMETER CommonData
        The common section of infrastructure JSON (for supervisorServices fallback).

        .PARAMETER PropertyName
        argoCdOperatorYamlPath or argoCdDeploymentYamlPath (logical names).

        .OUTPUTS
        [string] or $null if neither the new (parent + file name) nor legacy path is configured.

        .EXAMPLE
        $path = Get-EffectiveArgoCdYamlPath -Cluster $cluster -CommonData $inputData.common -PropertyName "argoCdOperatorYamlPath"
    #>

    Param (
        [Parameter(Mandatory = $true)] [AllowNull()] [PSObject]$Cluster,
        [Parameter(Mandatory = $true)] [AllowNull()] [PSObject]$CommonData,
        [Parameter(Mandatory = $true)] [ValidateSet("argoCdOperatorYamlPath", "argoCdDeploymentYamlPath")] [String]$PropertyName
    )

    return Get-EffectiveSupervisorServicesYamlPath -Cluster $Cluster -CommonData $CommonData -LogicalYamlPathPropertyName $PropertyName
}
function Resolve-InfrastructureReferencedFilePath {

    <#
        .SYNOPSIS
        Resolves a filesystem path referenced from infrastructure JSON.

        .DESCRIPTION
        When the path is already absolute or relative and the file exists as given, returns the full
        normalized path. When the path is relative and not found yet, tries the current PowerShell
        location (working directory), then the directory containing infrastructure.json (when
        provided). If no file is found, returns the trimmed original string so callers can surface
        it in validation errors. Works on Windows, macOS, and Linux.

        .PARAMETER FilePath
        Path from JSON (absolute or relative).

        .PARAMETER InfrastructureJsonDirectory
        Optional directory of the infrastructure JSON file (parent folder). Used as a fallback
        base for relative paths (for example YAML and certificate files stored next to the JSON).

        .OUTPUTS
        [String] Full path to an existing file, or the original path string when not resolved.

        .EXAMPLE
        Resolve-InfrastructureReferencedFilePath -FilePath "tls.crt.pem" -InfrastructureJsonDirectory "/path/to/config"
    #>

    Param (
        [Parameter(Mandatory = $true)] [String]$FilePath,
        [Parameter(Mandatory = $false)] [AllowNull()] [String]$InfrastructureJsonDirectory
    )

    if ([String]::IsNullOrWhiteSpace($FilePath)) {
        return $FilePath
    }

    $trimmed = $FilePath.Trim()
    if (Test-Path -LiteralPath $trimmed -PathType Leaf) {
        return (Get-Item -LiteralPath $trimmed).FullName
    }

    if ([System.IO.Path]::IsPathRooted($trimmed)) {
        try {
            $normalizedRooted = [System.IO.Path]::GetFullPath($trimmed)
            if (Test-Path -LiteralPath $normalizedRooted -PathType Leaf) {
                return (Get-Item -LiteralPath $normalizedRooted).FullName
            }
        } catch {
            Write-LogMessage -Type DEBUG -Message "Resolve-InfrastructureReferencedFilePath: could not normalize rooted path `"$trimmed`": $($_.Exception.Message)"
        }
        return $trimmed
    }

    $cwd = (Get-Location).ProviderPath
    $candidates = [System.Collections.Generic.List[string]]::new()
    try {
        [void]$candidates.Add([System.IO.Path]::GetFullPath((Join-Path -Path $cwd -ChildPath $trimmed)))
    } catch {
        Write-LogMessage -Type DEBUG -Message "Resolve-InfrastructureReferencedFilePath: could not combine CWD with `"$trimmed`": $($_.Exception.Message)"
    }
    if (-not [String]::IsNullOrWhiteSpace($InfrastructureJsonDirectory)) {
        try {
            [void]$candidates.Add([System.IO.Path]::GetFullPath((Join-Path -Path $InfrastructureJsonDirectory -ChildPath $trimmed)))
        } catch {
            Write-LogMessage -Type DEBUG -Message "Resolve-InfrastructureReferencedFilePath: could not combine infrastructure JSON directory with `"$trimmed`": $($_.Exception.Message)"
        }
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Get-Item -LiteralPath $candidate).FullName
        }
    }

    return $trimmed
}
function Update-InfrastructureJsonReferencedFilePaths {

    <#
        .SYNOPSIS
        Sets script scope for path resolution and expands Harbor TLS file names into full paths.

        .DESCRIPTION
        Resolves the parent folder of the infrastructure JSON file and assigns
        $Script:InfrastructureJsonParentForPathResolution so Get-EffectiveSupervisorServicesYamlPath
        can resolve combined supervisorServices paths. For each cluster.harborConfiguration, when
        parentDirectory is set, rewrites tlsCrt, tlsKey, and caCrt from file names under that
        directory to full paths; when parentDirectory is omitted, resolves each value as a full path
        (legacy) with Resolve-InfrastructureReferencedFilePath. Argo CD and Harbor supervisor YAML
        paths are resolved at read time from parentDirectory + *YamlFileName or legacy *YamlPath keys.

        .PARAMETER InfrastructureJsonPath
        Path to the infrastructure JSON file (used to locate the parent directory for relative paths).

        .PARAMETER InputData
        Parsed infrastructure JSON object (modified in place for Harbor TLS paths only).

        .OUTPUTS
        None.
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$InfrastructureJsonPath,
        [Parameter(Mandatory = $true)] [AllowNull()] [PSObject]$InputData
    )

    $Script:InfrastructureJsonParentForPathResolution = $null

    if (-not $InputData) {
        return
    }

    $infrastructureJsonDirectory = $null
    try {
        if (Test-Path -LiteralPath $InfrastructureJsonPath -PathType Leaf) {
            $infrastructureJsonDirectory = Split-Path -Parent (Resolve-Path -LiteralPath $InfrastructureJsonPath).Path
        }
    } catch {
        Write-LogMessage -Type DEBUG -Message "Update-InfrastructureJsonReferencedFilePaths: could not resolve directory for `"$InfrastructureJsonPath`": $($_.Exception.Message)"
    }

    $Script:InfrastructureJsonParentForPathResolution = $infrastructureJsonDirectory

    if (-not $InputData.clusters) {
        return
    }

    foreach ($cluster in @($InputData.clusters)) {
        if (-not $cluster -or -not $cluster.harborConfiguration) {
            continue
        }
        $hc = $cluster.harborConfiguration
        $hasHarborParent = $hc.PSObject.Properties["parentDirectory"] -and -not [String]::IsNullOrWhiteSpace([String]$hc.parentDirectory)
        foreach ($propertyName in @("caCrt", "tlsCrt", "tlsKey")) {
            if ($null -eq $hc.PSObject.Properties[$propertyName]) {
                continue
            }
            $namePart = [String]$hc.$propertyName
            if ([String]::IsNullOrWhiteSpace($namePart)) {
                continue
            }
            if ($hasHarborParent) {
                $parentRaw = [String]$hc.parentDirectory.Trim()
                $combined = $null
                try {
                    $combined = [System.IO.Path]::GetFullPath((Join-Path -Path $parentRaw -ChildPath $namePart.Trim()))
                } catch {
                    Write-LogMessage -Type DEBUG -Message "Update-InfrastructureJsonReferencedFilePaths: could not combine harborConfiguration.parentDirectory with $propertyName for edgeSite `"$($cluster.edgeSite)`": $($_.Exception.Message)"
                    continue
                }
                $resolved = Resolve-InfrastructureReferencedFilePath -FilePath $combined -InfrastructureJsonDirectory $infrastructureJsonDirectory
                if ($resolved -ne $namePart) {
                    Write-LogMessage -Type DEBUG -Message "Resolved clusters[].harborConfiguration.$propertyName (edgeSite `"$($cluster.edgeSite)`") from `"$namePart`" under parentDirectory to `"$resolved`"."
                }
                $hc.$propertyName = $resolved
            } else {
                $resolved = Resolve-InfrastructureReferencedFilePath -FilePath $namePart.Trim() -InfrastructureJsonDirectory $infrastructureJsonDirectory
                if ($resolved -ne $namePart) {
                    Write-LogMessage -Type DEBUG -Message "Resolved clusters[].harborConfiguration.$propertyName (edgeSite `"$($cluster.edgeSite)`", legacy path) from `"$namePart`" to `"$resolved`"."
                }
                $hc.$propertyName = $resolved
            }
        }
    }
}
function Get-EffectiveSupervisorServiceFlag {

    <#
        .SYNOPSIS
        Resolves a boolean supervisor service disable flag with cluster-level override over common-level.

        .DESCRIPTION
        Returns the cluster-level flag value (clusters[].supervisorServices.[FlagName]) when defined,
        otherwise falls back to the common-level value (common.supervisorServices.[FlagName]).
        Returns $false when the flag is absent at both levels, making all services enabled by default.
        Cluster-level always takes priority when both are defined.

        Supported flags:
        - disableArgoCD: When true, skips ArgoCD deployment after supervisor creation.
        - disableHarbor: When true, will skip Harbor deployment (wiring pending).

        .PARAMETER Cluster
        Cluster object from infrastructure JSON (may have supervisorServices.[FlagName]).

        .PARAMETER CommonData
        The common section of infrastructure JSON (for supervisorServices fallback).

        .PARAMETER FlagName
        The boolean flag property name to resolve. Valid values are derived from
        $Script:SupervisorServiceRegistry — currently: disableArgoCD, disableHarbor.
        Add new entries to the registry in VcfEdgeAtScale.psm1 to extend the valid set.

        .OUTPUTS
        [bool] $true if the service should be skipped; $false if enabled (default when unset).

        .EXAMPLE
        $disableArgoCD = Get-EffectiveSupervisorServiceFlag -Cluster $cluster -CommonData $inputData.common -FlagName "disableArgoCD"

        Returns $true if disableArgoCD is set to true at the cluster or common level; $false otherwise.

        .NOTES
        Place "disableArgoCD": true in common.supervisorServices to disable for all clusters, or in
        clusters[].supervisorServices to override for a specific cluster only.
    #>

    Param (
        [Parameter(Mandatory = $true)] [AllowNull()] [PSObject]$Cluster,
        [Parameter(Mandatory = $true)] [AllowNull()] [PSObject]$CommonData,
        [Parameter(Mandatory = $true)] [ValidateScript({
            $validFlags = $Script:SupervisorServiceRegistry.Values | ForEach-Object { $_.DisableFlag }
            if ($_ -in $validFlags) { $true }
            else { throw "FlagName must be one of: $($validFlags -join ', '). Got: '$_'." }
        })] [String]$FlagName
    )

    if ($Cluster -and $Cluster.supervisorServices -and $null -ne $Cluster.supervisorServices.$FlagName) {
        return [bool]$Cluster.supervisorServices.$FlagName
    }
    if ($CommonData -and $CommonData.supervisorServices -and $null -ne $CommonData.supervisorServices.$FlagName) {
        return [bool]$CommonData.supervisorServices.$FlagName
    }
    return $false
}
function Get-EffectiveVmkernelMtu {

    <#
        .SYNOPSIS
        Resolves the effective MTU for VDS and for vMotion/vSAN VMkernel adapters from common.vSanvMotionVmKernelMtuValue.

        .DESCRIPTION
        common.vSanvMotionVmKernelMtuValue in infrastructure JSON is the source for vMotion and vSAN VMkernel and VDS MTU (default 9000). Mgmt (vmk0) and vSAN Witness (vmk3) interfaces are always 1500 and are not set from this function. Precedence (first defined and in range wins):

        1. common.vSanvMotionVmKernelMtuValue – validated at JSON load (1500-9190). Use for VDS and vMotion/vSAN VMkernels only.
        2. common.vmkernelMtu – legacy key; used only when common.vSanvMotionVmKernelMtuValue is not set.
        3. DefaultMtu parameter – when no override is present or parseable in range.

        .PARAMETER DefaultMtu
        MTU used when no valid override is present. Must be between MinMtu and MaxMtu.

        .PARAMETER InputData
        Full parsed infrastructure JSON (common.vSanvMotionVmKernelMtuValue, common.vmkernelMtu).

        .PARAMETER MaxMtu
        Maximum allowed MTU; values above this are ignored. Must align with JSON validation and VDS/VMkernel limits.

        .PARAMETER MinMtu
        Minimum allowed MTU; values below this are ignored. Must align with JSON validation.

        .OUTPUTS
        [int] MTU in the range MinMtu to MaxMtu (for VDS and vMotion/vSAN VMkernels only).

        .NOTES
        Mgmt and vSAN Witness VMkernels are always 1500. This function returns the value for vMotion/vSAN and VDS only.
    #>

    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(1500, 9190)] [int]$DefaultMtu = 9000,
        [Parameter(Mandatory = $true)] [AllowNull()] [PSObject]$InputData,
        [Parameter(Mandatory = $false)] [ValidateRange(1500, 9190)] [int]$MaxMtu = 9190,
        [Parameter(Mandatory = $false)] [ValidateRange(1500, 9190)] [int]$MinMtu = 1500
    )

    $parsed = 0

    if ($InputData -and $InputData.common -and $null -ne $InputData.common.PSObject.Properties["vSanvMotionVmKernelMtuValue"]) {
        if ([int]::TryParse([string]$InputData.common.vSanvMotionVmKernelMtuValue, [ref]$parsed) -and $parsed -ge $MinMtu -and $parsed -le $MaxMtu) {
            return $parsed
        }
    }
    if ($InputData -and $InputData.common -and $null -ne $InputData.common.vmkernelMtu) {
        if ([int]::TryParse([string]$InputData.common.vmkernelMtu, [ref]$parsed) -and $parsed -ge $MinMtu -and $parsed -le $MaxMtu) {
            return $parsed
        }
    }
    return $DefaultMtu
}
function Invoke-HarborDeploymentPhase {
    <#
        .SYNOPSIS
        Deploys the Harbor Supervisor Service for a single edge site.

        .DESCRIPTION
        Extracted from Initialize-VcfEdgeAtScale to reduce function size.
        Handles the full Harbor deployment sequence: resolving YAML paths, attaching a synthetic
        harborConfiguration for lab mode, resolving the effective hostname, building the data values
        file (with optional lab self-signed TLS), registering the service definition, installing the
        Supervisor Service, showing instance details, and registering the container image registry.
        Temp file cleanup (including redacted diagnostics on failure) and lab TLS key/cert preservation
        are handled in try/finally blocks so secrets are never left on disk after a failure.

        .PARAMETER Context
        Hashtable containing all per-site deployment state required for the Harbor phase:
          Cluster, ClusterId, ClusterName, ContextName, CurrentEdgeSite, InputData,
          InsecureTls, LabEnvironment, PreserveAutoGeneratedKeyCert, SaveHarborYaml,
          StoragePolicyName, SupervisorId.

        .OUTPUTS
        [String] The Harbor service name extracted from the service YAML, or $null when installation fails.

        .NOTES
        Sets $Script:HarborPhaseStarted = $true before any installation step so the rollback logic in
        Initialize-VcfEdgeAtScale can choose Harbor-only rollback on failure.
        Throws on any deployment failure; the caller is responsible for rollback.
        The $cluster object may be mutated (harborConfiguration attached for lab mode; hostname set).
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Hashtable]$Context
    )

    $requiredKeys = @("Cluster", "ClusterId", "ClusterName", "ContextName", "CurrentEdgeSite", "InputData", "StoragePolicyName", "SupervisorId")
    foreach ($key in $requiredKeys) {
        if (-not $Context.ContainsKey($key) -or $null -eq $Context[$key]) {
            Write-LogMessage -Type ERROR -Message "Invoke-HarborDeploymentPhase: required context key '$key' is missing or null."
            throw [VcfDeploymentException]::new()
        }
    }

    $Script:HarborPhaseStarted = $true
    $cluster                      = $Context.Cluster
    $clusterId                    = $Context.ClusterId
    $clusterName                  = $Context.ClusterName
    $contextName                  = $Context.ContextName
    $currentEdgeSite              = $Context.CurrentEdgeSite
    $inputData                    = $Context.InputData
    $insecureTls                  = if ($Context.ContainsKey("InsecureTls")) { [bool]$Context.InsecureTls } else { $true }
    $labEnvironment               = if ($Context.ContainsKey("LabEnvironment")) { [bool]$Context.LabEnvironment } else { $false }
    $preserveAutoGeneratedKeyCert = if ($Context.ContainsKey("PreserveAutoGeneratedKeyCert")) { [bool]$Context.PreserveAutoGeneratedKeyCert } else { $false }
    $saveHarborYaml               = if ($Context.ContainsKey("SaveHarborYaml")) { [bool]$Context.SaveHarborYaml } else { $false }
    $storagePolicyName            = $Context.StoragePolicyName
    $supervisorId                 = $Context.SupervisorId

    $harborServiceYamlPath        = Get-EffectiveSupervisorServicesYamlPath -Cluster $cluster -CommonData $inputData.common -LogicalYamlPathPropertyName "harborServiceYamlPath"
    $harborDataValuesTemplatePath = Get-EffectiveSupervisorServicesYamlPath -Cluster $cluster -CommonData $inputData.common -LogicalYamlPathPropertyName "harborDataTemplateYamlPath"

    if ($labEnvironment -and -not $cluster.harborConfiguration) {
        $syntheticHarborConfiguration = [PSCustomObject]@{}
        $cluster | Add-Member -NotePropertyName harborConfiguration -NotePropertyValue $syntheticHarborConfiguration -Force
        Write-LogMessage -Type INFO -Message "Lab mode: clusters[].harborConfiguration was omitted for edge site `"$currentEdgeSite`"; attached an empty object for Harbor deploy (hostname from the Harbor data values template; self-signed TLS when tlsCrt and tlsKey are omitted)."
    }
    $harborConfig = $cluster.harborConfiguration
    $harborTempYamlPath = $null
    $harborYamlSaveDir = $null
    $harborUsedLabGeneratedTls = $false
    $labHarborSelfSignedPaths = $null
    $harborServiceName = $null

    if ($saveHarborYaml) {
        # Use the module root (ModuleBase) rather than $PSScriptRoot so HarborYaml/ is created
        # at the module install root, not inside Private/. $PSScriptRoot in a dot-sourced helper
        # resolves to the directory of the file being dot-sourced (Private/), not the module root.
        $harborYamlModuleBase = if ($MyInvocation.MyCommand.Module.ModuleBase) {
            $MyInvocation.MyCommand.Module.ModuleBase
        } else {
            # Fallback for edge cases (e.g. direct script execution): go up one level from Private/.
            Split-Path -Path $PSScriptRoot -Parent
        }
        $harborYamlSaveDir = Join-Path -Path $harborYamlModuleBase -ChildPath "HarborYaml"
        if (-not (Test-Path -Path $harborYamlSaveDir)) {
            try {
                New-Item -ItemType Directory -Path $harborYamlSaveDir -Force -ErrorAction Stop | Out-Null
                Write-LogMessage -Type DEBUG -Message "Created HarborYaml save directory: `"$harborYamlSaveDir`"."
            } catch [VcfDeploymentException] {
                throw  # already logged and typed — propagate without re-wrapping
            } catch {
                Write-LogMessage -Type ERROR -Message "Cannot create HarborYaml directory `"$harborYamlSaveDir`": $($_.Exception.Message)"
                throw [VcfDeploymentException]::new()
            }
        }
    }

    try {
        $harborInstallSucceeded = $false
        # Build per-site Harbor data values file from harborConfiguration stanza.
        # StoragePolicyName is the VM storage policy name; New-HarborDataValuesFile lowercases
        # and replaces spaces with dashes to match the Kubernetes StorageClass naming convention.
        $effectiveHarborHostname = Get-EffectiveHarborHostnameForInfrastructureCluster -Cluster $cluster -CommonData $inputData.common -LabEnvironmentEnabled $labEnvironment
        if ([String]::IsNullOrWhiteSpace($effectiveHarborHostname)) {
            Write-LogMessage -Type ERROR -Message "Could not resolve Harbor hostname for edge site `"$currentEdgeSite`". Set clusters[].harborConfiguration.hostname or use lab mode with a Harbor data values template that defines hostname."
            throw [VcfDeploymentException]::new()
        }
        if (-not (Test-JsonPropertyFormat -InputData $effectiveHarborHostname -ValidationPreset "IpAddressOrFqdn" -ValidationLabel "harborConfiguration.hostname (deploy)")) {
            Write-LogMessage -Type ERROR -Message "Resolved Harbor hostname `"$effectiveHarborHostname`" for edge site `"$currentEdgeSite`" is not a valid DNS-compatible FQDN or IP address (deploy-time check)."
            throw [VcfDeploymentException]::new()
        }
        if ($harborConfig.PSObject.Properties["hostname"]) {
            $harborConfig.hostname = $effectiveHarborHostname
        } else {
            $harborConfig | Add-Member -NotePropertyName hostname -NotePropertyValue $effectiveHarborHostname -Force
        }

        $hasTlsCrtPath = ($null -ne $harborConfig.PSObject.Properties["tlsCrt"]) -and -not [String]::IsNullOrWhiteSpace([string]$harborConfig.tlsCrt)
        $hasTlsKeyPath = ($null -ne $harborConfig.PSObject.Properties["tlsKey"]) -and -not [String]::IsNullOrWhiteSpace([string]$harborConfig.tlsKey)
        if ($labEnvironment -and -not $hasTlsCrtPath -and -not $hasTlsKeyPath) {
            $labHarborSelfSignedPaths = New-LabHarborSelfSignedTlsMaterialFiles -DnsName $effectiveHarborHostname -EdgeSite $currentEdgeSite
            $harborDataValuesParams = @{
                CaCrtPath              = $labHarborSelfSignedPaths.CaCrtPath
                EdgeSite               = $currentEdgeSite
                HarborTemplateFilePath = $harborDataValuesTemplatePath
                Hostname               = $effectiveHarborHostname
                StoragePolicyName      = $storagePolicyName
                TlsCrtPath             = $labHarborSelfSignedPaths.TlsCrtPath
                TlsKeyPath             = $labHarborSelfSignedPaths.TlsKeyPath
            }
            if ($harborConfig.PSObject.Properties["caCrt"]) {
                $harborConfig.caCrt = $labHarborSelfSignedPaths.CaCrtPath
            } else {
                $harborConfig | Add-Member -NotePropertyName caCrt -NotePropertyValue $labHarborSelfSignedPaths.CaCrtPath -Force
            }
            $harborUsedLabGeneratedTls = $true
            Write-LogMessage -Type INFO -Message "Lab mode: using generated self-signed TLS for Harbor on edge site `"$currentEdgeSite`" (hostname `"$effectiveHarborHostname`")."
        } else {
            $harborDataValuesParams = @{
                EdgeSite               = $currentEdgeSite
                HarborTemplateFilePath = $harborDataValuesTemplatePath
                Hostname               = $effectiveHarborHostname
                StoragePolicyName      = $storagePolicyName
            }
            if (-not [String]::IsNullOrWhiteSpace($harborConfig.tlsCrt))  { $harborDataValuesParams["TlsCrtPath"]  = $harborConfig.tlsCrt }
            if (-not [String]::IsNullOrWhiteSpace($harborConfig.tlsKey))  { $harborDataValuesParams["TlsKeyPath"]  = $harborConfig.tlsKey }
            if (-not [String]::IsNullOrWhiteSpace($harborConfig.caCrt))   { $harborDataValuesParams["CaCrtPath"]   = $harborConfig.caCrt }
        }
        if (-not [String]::IsNullOrWhiteSpace($harborConfig.registryVolumeSize))  { $harborDataValuesParams["RegistryVolumeSize"]  = $harborConfig.registryVolumeSize }
        if (-not [String]::IsNullOrWhiteSpace($harborConfig.jobserviceVolumeSize)) { $harborDataValuesParams["JobserviceVolumeSize"] = $harborConfig.jobserviceVolumeSize }
        if (-not [String]::IsNullOrWhiteSpace($harborConfig.databaseVolumeSize))  { $harborDataValuesParams["DatabaseVolumeSize"]   = $harborConfig.databaseVolumeSize }
        if (-not [String]::IsNullOrWhiteSpace($harborConfig.redisVolumeSize))     { $harborDataValuesParams["RedisVolumeSize"]       = $harborConfig.redisVolumeSize }
        if (-not [String]::IsNullOrWhiteSpace($harborConfig.trivyVolumeSize))     { $harborDataValuesParams["TrivyVolumeSize"]       = $harborConfig.trivyVolumeSize }
        if (-not [String]::IsNullOrWhiteSpace($harborConfig.harborAdminPassword)) { $harborDataValuesParams["HarborAdminPassword"]   = $harborConfig.harborAdminPassword }
        if (-not [String]::IsNullOrWhiteSpace($harborConfig.secretKey))           { $harborDataValuesParams["SecretKey"]             = $harborConfig.secretKey }
        if (-not [String]::IsNullOrWhiteSpace($harborConfig.databasePassword))    { $harborDataValuesParams["DatabasePassword"]      = $harborConfig.databasePassword }
        if (-not [String]::IsNullOrWhiteSpace($harborConfig.coreSecret))          { $harborDataValuesParams["CoreSecret"]            = $harborConfig.coreSecret }
        if (-not [String]::IsNullOrWhiteSpace($harborConfig.jobserviceSecret))    { $harborDataValuesParams["JobserviceSecret"]      = $harborConfig.jobserviceSecret }
        if (-not [String]::IsNullOrWhiteSpace($harborConfig.registrySecret))      { $harborDataValuesParams["RegistrySecret"]        = $harborConfig.registrySecret }

        $harborTempYamlPath = New-HarborDataValuesFile @harborDataValuesParams
        # Read back from file; CRLF normalization is applied again in Install-HarborSupervisorService
        # before encoding, because Set-Content on Windows may re-introduce CRLF endings.
        $harborYamlContent = Get-Content -Path $harborTempYamlPath -Raw -Encoding UTF8

        # Register the service definition (idempotent: no-op if already registered on this vCenter).
        Set-HarborService -Path $harborServiceYamlPath
        # Get-ArgoCDServiceDetail is a generic Carvel Package YAML parser; it works for any supervisor service, including Harbor.
        $harborServiceName, $harborServiceVersion = Get-ArgoCDServiceDetail -Path $harborServiceYamlPath
        Write-LogMessage -Type DEBUG -Message "Harbor service: name=`"$harborServiceName`", version=`"$harborServiceVersion`"."

        Install-HarborSupervisorService -ClusterId $clusterId -ClusterName $clusterName -SupervisorId $supervisorId -Service $harborServiceName -Version $harborServiceVersion -YamlServiceConfig $harborYamlContent
        $harborInstallSucceeded = $true
        Write-LogMessage -Type INFO -Message "Harbor Supervisor Service installed successfully for edge site `"$currentEdgeSite`" (hostname: `"$($harborConfig.hostname)`")."
        Show-HarborInstanceDetails -ClusterName $clusterName -ContextName $contextName -HarborConfig $harborConfig -InsecureTls:$insecureTls -LabGeneratedSelfSignedTls:$harborUsedLabGeneratedTls -SupervisorId $supervisorId -YamlFilePath $harborTempYamlPath
        Add-HarborContainerImageRegistry -ClusterName $clusterName -ContextName $contextName -HarborConfig $harborConfig -InsecureTls:$insecureTls -SupervisorId $supervisorId -YamlFilePath $harborTempYamlPath
    } catch {
        throw
    } finally {
        if ($labHarborSelfSignedPaths) {
            if ($preserveAutoGeneratedKeyCert -and $harborInstallSucceeded) {
                $harborKeyCertSaveDir = $null
                $rootDir = $env:VcfEdgeAtScaleRootDirectory
                if (-not [String]::IsNullOrWhiteSpace($rootDir) -and (Test-Path -LiteralPath $rootDir)) {
                    $harborKeyCertSaveDir = Join-Path -Path $rootDir -ChildPath (Join-Path -Path "HarborKeyCerts" -ChildPath $currentEdgeSite)
                }
                if ($harborKeyCertSaveDir) {
                    try {
                        if (-not (Test-Path -LiteralPath $harborKeyCertSaveDir)) {
                            New-Item -ItemType Directory -Path $harborKeyCertSaveDir -Force -ErrorAction Stop | Out-Null
                            Write-LogMessage -Type DEBUG -Message "Created HarborKeyCerts directory: `"$harborKeyCertSaveDir`"."
                        }
                        $destKeyPath = Join-Path $harborKeyCertSaveDir "$currentEdgeSite.key"
                        $destCrtPath = Join-Path $harborKeyCertSaveDir "$currentEdgeSite.crt"
                        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
                        # On non-Windows: create the key file and lock it to owner-only BEFORE writing
                        # any content to eliminate the TOCTOU window where the key would briefly be
                        # world-readable between WriteAllText and a post-write chmod.
                        if (-not $IsWindows) {
                            $keyStream = [System.IO.File]::Open($destKeyPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                            $keyStream.Close()
                            & chmod 0600 $destKeyPath 2>&1 | Out-Null
                            if ($LASTEXITCODE -ne 0) {
                                Write-LogMessage -Type WARNING -Message "Could not set owner-only permissions on Harbor key file `"$destKeyPath`" (chmod exit code $LASTEXITCODE). File may have world-readable permissions — restrict it manually."
                            }
                        }
                        # Write files directly (not Copy-Item) so we control encoding and do not inherit the temp file's ACL/mode.
                        [System.IO.File]::WriteAllText($destKeyPath, [System.IO.File]::ReadAllText($labHarborSelfSignedPaths.TlsKeyPath, $utf8NoBom), $utf8NoBom)
                        [System.IO.File]::WriteAllText($destCrtPath, [System.IO.File]::ReadAllText($labHarborSelfSignedPaths.TlsCrtPath, $utf8NoBom), $utf8NoBom)
                        if (-not $IsWindows) {
                            & chmod 0644 $destCrtPath 2>&1 | Out-Null
                            if ($LASTEXITCODE -ne 0) {
                                Write-LogMessage -Type WARNING -Message "Could not set permissions on Harbor certificate file `"$destCrtPath`" (chmod exit code $LASTEXITCODE)."
                            }
                        }
                        Write-LogMessage -Type INFO -Message "Lab mode: preserved auto-generated Harbor key/cert for edge site `"$currentEdgeSite`": `"$destKeyPath`", `"$destCrtPath`"."
                    } catch {
                        Write-LogMessage -Type WARNING -Message "Could not save Harbor key/cert pair for edge site `"$currentEdgeSite`": $($_.Exception.Message)."
                    }
                } else {
                    Write-LogMessage -Type WARNING -Message "preserveAutoGeneratedKeyCertPair is true but `$env:VcfEdgeAtScaleRootDirectory is not set or does not exist. Key/cert pair for edge site `"$currentEdgeSite`" will not be saved."
                }
            }
            foreach ($labTlsPath in @($labHarborSelfSignedPaths.TlsCrtPath, $labHarborSelfSignedPaths.TlsKeyPath, $labHarborSelfSignedPaths.CaCrtPath)) {
                if (-not [String]::IsNullOrWhiteSpace($labTlsPath) -and (Test-Path -LiteralPath $labTlsPath)) {
                    Remove-Item -LiteralPath $labTlsPath -Force -ErrorAction SilentlyContinue
                    Write-LogMessage -Type DEBUG -Message "Removed lab-generated Harbor TLS temp file: `"$labTlsPath`"."
                }
            }
        }
        if (-not [String]::IsNullOrWhiteSpace($harborTempYamlPath) -and (Test-Path -Path $harborTempYamlPath)) {
            if ($harborInstallSucceeded) {
                if ($harborYamlSaveDir) {
                    $harborYamlDestPath = Join-Path -Path $harborYamlSaveDir -ChildPath (Split-Path -Path $harborTempYamlPath -Leaf)
                    Move-Item -Path $harborTempYamlPath -Destination $harborYamlDestPath -Force -ErrorAction SilentlyContinue
                    Write-LogMessage -Type INFO -Message "Harbor data values file saved (contains unredacted secrets): `"$harborYamlDestPath`". A redacted copy is in the deployment log."
                } else {
                    Remove-Item -Path $harborTempYamlPath -Force -ErrorAction SilentlyContinue
                    Write-LogMessage -Type DEBUG -Message "Cleaned up temporary Harbor data values file: `"$harborTempYamlPath`"."
                }
            } else {
                # On failure, write a redacted copy for diagnostics and remove the original secrets file.
                # To verify the storage class exists: kubectl get storageclass (in supervisor context).
                try {
                    $harborRedactedPath = [System.IO.Path]::ChangeExtension($harborTempYamlPath, ".redacted.yml")
                    $harborRawYaml = Get-Content -Path $harborTempYamlPath -Raw -Encoding UTF8 -ErrorAction Stop
                    $harborRedactedYaml = $harborRawYaml -replace '(?m)^(\s*(?:harborAdminPassword|secretKey|password|secret|tls\.key|ca\.key):\s+)\S.*$', '$1[REDACTED]'
                    Set-Content -Path $harborRedactedPath -Value $harborRedactedYaml -Encoding UTF8 -ErrorAction SilentlyContinue
                    Write-LogMessage -Type WARNING -Message "Harbor deployment failed. A redacted copy of the data values file is preserved for diagnostics: `"$harborRedactedPath`"."
                } catch {
                    Write-LogMessage -Type WARNING -Message "Harbor deployment failed. Could not write redacted diagnostics file: $($_.Exception.Message)."
                } finally {
                    Remove-Item -Path $harborTempYamlPath -Force -ErrorAction SilentlyContinue
                    Write-LogMessage -Type DEBUG -Message "Removed secrets Harbor data values file: `"$harborTempYamlPath`"."
                }
            }
        }
        # Clear Harbor credentials that were resolved into process environment by Resolve-HarborSecretValue.
        [System.Environment]::SetEnvironmentVariable("HARBOR_ADMIN_PASSWORD", $null)
        [System.Environment]::SetEnvironmentVariable("SECRET_KEY", $null)
        Write-LogMessage -Type DEBUG -Message "Cleared Harbor credential environment variables from process scope."
    }

    return $harborServiceName
}
function Invoke-ArgoCDDeploymentPhase {
    <#
        .SYNOPSIS
        Deploys the Argo CD Supervisor Service for a single edge site.

        .DESCRIPTION
        Extracted from Initialize-VcfEdgeAtScale to reduce function size.
        Sets and clears VCF_CLI_VSPHERE_PASSWORD and KUBECTL_VSPHERE_PASSWORD environment variables in a
        try/finally block, installs the ArgoCD service definition, creates the workload namespace, installs
        the operator, creates a VCF context, and deploys the ArgoCD instance.

        .PARAMETER Context
        Hashtable containing all per-site deployment state required for the ArgoCD phase:
          ArgoCdDeploymentYamlPath, ArgoCDyaml, ArgocdNameSpace, ArgocdVmClass,
          ClusterId, ClusterName, ContextName, StoragePolicyId, SupervisorId.

        .OUTPUTS
        [Array] The resolved ArgocdVmClass list (may be populated by Get-AvailableVmClassNames when not pre-set).

        .NOTES
        Sets $Script:ArgoCDPhaseStarted = $true before any installation step so the rollback logic in
        Initialize-VcfEdgeAtScale can choose ArgoCD-only rollback on failure.
        Throws on any deployment failure; the caller is responsible for rollback.
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Hashtable]$Context
    )

    # Validate required keys upfront so a typo in the caller fails with a clear message
    # rather than a cryptic null-value error deep inside the deployment sequence.
    $requiredKeys = @("ArgoCdDeploymentYamlPath", "ArgoCDyaml", "ArgocdNameSpace", "ClusterId", "ClusterName", "ContextName", "StoragePolicyId", "SupervisorId", "VcenterCredential")
    foreach ($key in $requiredKeys) {
        if (-not $Context.ContainsKey($key) -or $null -eq $Context[$key]) {
            Write-LogMessage -Type ERROR -Message "Invoke-ArgoCDDeploymentPhase: required context key '$key' is missing or null."
            throw [VcfDeploymentException]::new()
        }
    }

    $Script:ArgoCDPhaseStarted = $true
    $argoCdDeploymentYamlPath = $Context.ArgoCdDeploymentYamlPath
    $argoCDyaml               = $Context.ArgoCDyaml
    $argocdNameSpace          = $Context.ArgocdNameSpace
    $argocdVmClass            = $Context.ArgocdVmClass
    $clusterId                = $Context.ClusterId
    $clusterName              = $Context.ClusterName
    $contextName              = $Context.ContextName
    $storagePolicyId             = $Context.StoragePolicyId
    $supervisorId                = $Context.SupervisorId
    $vcenterCredential           = $Context.VcenterCredential
    # InsecureTls: currently always $true in the ArgoCD deployment path (unlike Harbor which respects the parameter).
    # Defaults to $true when the key is absent so omitting it from the context preserves current behaviour rather
    # than silently disabling TLS and causing authentication failures with a self-signed vCenter certificate.
    $insecureTlsArgoCD = if ($Context.ContainsKey("InsecureTls")) { [bool]$Context.InsecureTls } else { $true }

    # Clear existing environment variables first to prevent conflicts with previous runs.
    Remove-Item env:\VCF_CLI_VSPHERE_PASSWORD -ErrorAction SilentlyContinue
    Remove-Item env:\KUBECTL_VSPHERE_PASSWORD -ErrorAction SilentlyContinue

    try {
        $env:VCF_CLI_VSPHERE_PASSWORD = Get-VcenterRestApiPlainPassword -VcenterCredential $vcenterCredential
        $env:KUBECTL_VSPHERE_PASSWORD = $env:VCF_CLI_VSPHERE_PASSWORD
        Write-LogMessage -Type DEBUG -Message "Set environment variables for VCF CLI and kubectl password-less access."
        # Create ArgoCD Operator. Create the ArgoCD workload namespace before installing the operator
        # so reconciliation can find it (avoids "Required namespace does not exist" when the operator
        # expects the namespace to exist).
        Set-ArgoCDService -Path $argoCDyaml
        $argoServiceName, $argoServiceVersion = Get-ArgoCDServiceDetail -Path $argoCDyaml
        if ($null -eq $argocdVmClass -or $argocdVmClass.Count -eq 0) {
            $argocdVmClass = Get-AvailableVmClassNames
        }
        Write-LogMessage -Type DEBUG -Message "Calling Add-ArgoCDNamespace with namespace: `"$argocdNameSpace`""
        Add-ArgoCDNamespace -SupervisorId $supervisorId -ArgoCdNamespace $argocdNameSpace -StoragePolicyId $storagePolicyId -VmClasses $argocdVmClass
        Install-ArgoCDOperator -ClusterId $clusterId -ClusterName $clusterName -SupervisorId $supervisorId -Service $argoServiceName -Version $argoServiceVersion

        $supervisorControlPlaneVmIp = Get-SupervisorControlPlaneIp -ClusterName $clusterName
        $ctxResult = Set-VCFContextCreate -ContextName $contextName -Endpoint $supervisorControlPlaneVmIp -Namespace $argocdNameSpace -SsoUsername $Script:VCenterUser -InsecureTls:$insecureTlsArgoCD
        # Note: $Script:VCenterUser is still read from script scope — it is the SSO username, not a secret.
        # VcenterCredential is passed through the context object; the plain password is extracted only at env-var assignment.
        if ($ctxResult -and -not $ctxResult.Success) {
            Write-LogMessage -Type ERROR -Message "Deployment failed. VCF context switch failed. Check logs for details."
            throw [VcfDeploymentException]::new()
        }
        Write-LogMessage -Type DEBUG -Message "Calling Add-ArgoCDInstance with namespace: `"$argocdNameSpace`", YAML path: `"$argoCdDeploymentYamlPath`"."
        Add-ArgoCDInstance -ArgoCdNamespace $argocdNameSpace -ArgoCdDeploymentYamlPath $argoCdDeploymentYamlPath -ContextName $contextName -ClusterId $clusterId -Service $argoServiceName -InsecureTls:$insecureTlsArgoCD

        Show-ArgoCDInstanceDetails -ArgoCdNamespace $argocdNameSpace -ContextName $contextName -InsecureTls:$insecureTlsArgoCD
    } finally {
        # Always cleanup environment variables, even on errors.
        Remove-Item env:\VCF_CLI_VSPHERE_PASSWORD -ErrorAction SilentlyContinue
        Remove-Item env:\KUBECTL_VSPHERE_PASSWORD -ErrorAction SilentlyContinue
        # $vcenterCredential is a local reference only; $Script:VcenterCredential is cleared
        # at the end of the full deployment run in Initialize-VcfEdgeAtScale's finally block.
    }

    return $argocdVmClass
}
function Initialize-VcfEdgeAtScale {

    <#
        .SYNOPSIS
        Initializes and runs the full VcfEdgeAtScale edge deployment workflow against vCenter.

        .DESCRIPTION
        This function performs a comprehensive initialization of the edge deployment environment.
        It reads configuration data from input JSON files and performs the following operations:

        - Extracts configuration variables for vCenter, ESX host, cluster, supervisor, datacenter, datastore, storage policies, virtual distributed switch, content library, and ArgoCD
        - Prompts for and securely stores vCenter and ESX host credentials
        - Establishes connections to vCenter and validates ESX host connectivity
        - Creates and configures a vSphere cluster with HA, DRS, and admission control settings
        - Adds the ESX host to the cluster
        - Creates VMFS datastore and storage policies
        - Sets up virtual distributed switch with port groups and uplinks

        .NOTES
        MAINTAINABILITY: This function is ~4,500 lines and should be refactored into named helper functions:
        - Invoke-VcfEdgeAtScalePreDeployValidation  (JSON validation + YAML pre-flight)
        - Invoke-VcfEdgeAtScaleClusterDeployment    (per-cluster deploy loop body, ~3,000 lines)
        - Invoke-VcfEdgeAtScalePostDeployReport     (post-deploy health reports)
        Tracked as code review item C3. Defer until a dedicated refactor sprint.
        - Creates and configures Kubernetes supervisor cluster
        - Installs ArgoCD operator and creates ArgoCD service
        - Creates local content library for VM templates
        - Sets up ArgoCD namespace with appropriate storage policies and VM classes
        - Creates ArgoCD instance with proper context configuration
        - Manages environment variables for password-less access
        - Properly disconnects from vCenter upon completion

        .PARAMETER AcceptBadCheckResults
        When set, proceeds without prompting when triggered alarms remain red (vSAN health, vLCM remediation, vSAN HCL). Mirrors the same-named switch on **Start-VcfEdgeAtScale** and is forwarded when this function is invoked from the entry point. Pass explicitly when calling this function directly (otherwise the red-alarm prompt appears even if the operator set the switch on the parent call).

        .PARAMETER DelayBeforeAddingNextHostSeconds
        Seconds to pause after each ESX host add (from the second host onward) so the cluster can settle. Default **0** (no delay). Mirrors the same-named parameter on **Start-VcfEdgeAtScale**.

        .PARAMETER MaximumSupervisorsPerVcenter
        Maximum number of supervisors allowed on the target vCenter before this run (default **50**, per vCenter 9 guidance). Override only for lab or vendor-directed scenarios.

        .NOTES
        This function loads **`InfrastructureJson`** and **`SupervisorJson`** from disk; callers do not need to pre-populate script-scope **`inputData`**.

        The function performs interactive credential prompts and establishes persistent vCenter connections.
        All operations are logged and the function handles cleanup of connections upon completion.

        .EXAMPLE
        Initialize-VcfEdgeAtScale -InfrastructureJson "infrastructure.json" -SupervisorJson "supervisor.json"

        Starts the full edge deployment workflow using the specified configuration files.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [Switch]$AcceptBadCheckResults,
        [Parameter(Mandatory = $false)] [ValidateSet("All", "ArgoCD", "Compute", "Harbor", "Supervisor")] [String]$CleanUp,
        [Parameter(Mandatory = $false)] [Switch]$ComputeOnly,
        [Parameter(Mandatory = $false)] [ValidateRange(0, 300)] [Int]$DelayBeforeAddingNextHostSeconds = 0,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$EdgeSite,
        [Parameter(Mandatory = $false)] [Switch]$Force,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$InfrastructureJson,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 128)] [Int]$MaximumSupervisorsPerVcenter = 50,
        [Parameter(Mandatory = $false)] [Switch]$SaveHarborYaml,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorJson
    )

    Write-LogMessage -Type DEBUG -Message "Entered Initialize-VcfEdgeAtScale function..."

    if ($SaveHarborYaml) {
        Write-LogMessage -Type WARNING -Message "-SaveHarborYaml is set: the completed Harbor data values YAML file (containing all passwords and secrets in plain text) will be saved to the HarborYaml subdirectory. Treat this location like a credential store and ensure access is appropriately restricted."
    }

    Write-LogMessage -Type DEBUG -Message "TLS certificate verification is disabled for vCenter REST API calls in this deployment. Ensure this is intentional (e.g., lab environment with self-signed certificates). In production, use a CA-signed certificate and review InsecureTls usage."

    try {
        $inputData = ConvertFrom-JsonSafely -JsonFilePath $InfrastructureJson
        Update-InfrastructureJsonReferencedFilePaths -InfrastructureJsonPath $InfrastructureJson -InputData $inputData

        $Script:vCenterName = $inputData.common.vCenterName
        $Script:VCenterUser = $inputData.common.vCenterUser
        $labEnvironment = $false
        if ($inputData.common) {
            $labEnvProp = $inputData.common.PSObject.Properties | Where-Object { $_.Name -ieq "labenvironment" } | Select-Object -First 1
            if ($null -ne $labEnvProp) {
                $labEnvironment = ($labEnvProp.Value -eq $true)
            }
        }
        # esxUniquePasswordPerHost: when false or not specified (default), one password for all hosts; when true, prompt per host. Internal $esxUniquePassword (true = one for all) inverts for existing logic.
        $esxUniquePassword = $true
        if ($inputData.common -and $null -ne $inputData.common.PSObject.Properties["esxUniquePasswordPerHost"]) {
            $esxUniquePassword = -not [bool]$inputData.common.esxUniquePasswordPerHost
        }
        # nonInteractivePassword: when omitted or false, use normal password prompts. When true, try VCENTER_COMMON_PASSWORD / ESX_COMMON_PASSWORD env vars first and fall back to prompt on auth failure. ESX_COMMON_PASSWORD when defined but empty means null root password.
        $nonInteractivePassword = $false
        if ($inputData.common -and $null -ne $inputData.common.PSObject.Properties["nonInteractivePassword"] -and $inputData.common.nonInteractivePassword -eq $true) {
            $nonInteractivePassword = $true
        }
        # preserveAutoGeneratedKeyCertPair: when true and lab mode auto-generates TLS material, save the key and cert to HarborKeyCerts under the deployment root.
        $preserveAutoGeneratedKeyCertPair = $false
        if ($inputData.common -and $null -ne $inputData.common.PSObject.Properties["preserveAutoGeneratedKeyCertPair"] -and $inputData.common.preserveAutoGeneratedKeyCertPair -eq $true) {
            $preserveAutoGeneratedKeyCertPair = $true
        }
        $datacenterName = $inputData.common.datacenterName
        # nicList is resolved per-cluster (cluster.nicList overrides common.nicList); validation ensured 2 or 4 NICs per cluster.
        $contextName = $inputData.common.contextName
        # Supervisor content library: optional. Workflow runs only when the key supervisorContentLibraryDatastore is present (key removed = skip). When present, subscription URL defaults to VMware lib.json unless supervisorContentLibrarySubscriptionUrl key is defined.
        $supervisorContentLibraryDatastoreKeyPresent = $inputData.common -and $null -ne $inputData.common.PSObject.Properties["supervisorContentLibraryDatastore"]
        $supervisorContentLibraryDatastore = if ($supervisorContentLibraryDatastoreKeyPresent) { $inputData.common.supervisorContentLibraryDatastore } else { $null }
        $defaultSupervisorContentLibrarySubscriptionUrl = "https://wp-content.vmware.com/supervisor/v1/latest/lib.json"
        $supervisorContentLibrarySubscriptionUrl = if ($supervisorContentLibraryDatastoreKeyPresent) { if ($inputData.common -and $null -ne $inputData.common.PSObject.Properties["supervisorContentLibrarySubscriptionUrl"]) { $inputData.common.supervisorContentLibrarySubscriptionUrl } else { $defaultSupervisorContentLibrarySubscriptionUrl } } else { $null }

        # Extract prefixes (optional; defaults per project guidelines).
        $clusterNamePrefix = if ($inputData.common.clusterNamePrefix) { $inputData.common.clusterNamePrefix } else { "cluster" }
        $datastoreNamePrefix = if ($inputData.common.datastoreNamePrefix) { $inputData.common.datastoreNamePrefix } else { "datastore" }
        $vdsNamePrefix = if ($inputData.common.vdsNamePrefix) { $inputData.common.vdsNamePrefix } else { "VDS" }
        $supervisorNamePrefix = if ($inputData.common.supervisorNamePrefix) { $inputData.common.supervisorNamePrefix } else { "supervisor" }
        $esxUser = if ($inputData.common.esxUser) { $inputData.common.esxUser } else { "root" }

        $clustersToProcess = @()
        if ($inputData.clusters) {
            if ($EdgeSite) {
                $edgeSitesArray = Get-EdgeSitesFromParameter -EdgeSite $EdgeSite -InputData $inputData
                $clustersToProcess = @($edgeSitesArray | ForEach-Object {
                    $site = $_
                    $inputData.clusters | Where-Object { $_.edgeSite -eq $site } | Select-Object -First 1
                } | Where-Object { $null -ne $_ })
                Write-LogMessage -Type INFO -Message "Processing $($clustersToProcess.Count) edge site(s): $($edgeSitesArray -join ', ')..."
            } else {
                $clustersToProcess = $inputData.clusters
                Write-LogMessage -Type INFO -Message "Processing all $($clustersToProcess.Count) edge site(s)..."
            }
        } else {
            Write-LogMessage -Type ERROR -Message "No clusters found in infrastructure JSON."
            throw [VcfDeploymentException]::new()
        }

        # Ensure VcfCmd is resolved even when today's log file already existed at startup
        # (New-LogFile only calls Get-EnvironmentSetup on first creation of the daily log file).
        $null = Get-VcfEdgeAtScaleVcfCmd
        Test-CommandAvailability -Command $Script:VcfCmd -Description "vcf-cli"
        Test-CommandAvailability -Command $Script:KubectlCmd -Description "kubectl"

        if ($clustersToProcess.Count -eq 1) {
            $firstEdgeSite = $clustersToProcess[0].edgeSite
            Write-LogMessage -Type INFO -Message "Beginning workflow for edgeSite: `"$firstEdgeSite`"."
        } else {
            $firstEdgeSite = $clustersToProcess[0].edgeSite
            Write-LogMessage -Type INFO -Message "Beginning workflow for $($clustersToProcess.Count) edge site(s), starting with edgeSite: `"$firstEdgeSite`"."
        }

        # Fail-fast reachability checks: run all TCP 443 probes before prompting for any credentials
        # so the user learns about unreachable infrastructure immediately.
        Write-LogMessage -Type INFO -Message "Performing vCenter reachability check (TCP 443)..."
        Test-VcenterAndEsxReachability -EsxHosts @() -Port 443 -VcenterName $Script:vCenterName

        # Build the unique list of ESX hosts across all clusters for reachability and pre-flight checks.
        $seenEsxHosts = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $allEsxHosts = [System.Collections.Generic.List[object]]::new()
        foreach ($cluster in $clustersToProcess) {
            if ($cluster.esxHosts) {
                foreach ($esxHost in $cluster.esxHosts) {
                    if (-not [String]::IsNullOrWhiteSpace($esxHost) -and $seenEsxHosts.Add($esxHost)) {
                        $allEsxHosts.Add($esxHost)
                    }
                }
            }
        }
        $seenEsxHosts = $null

        if ($allEsxHosts.Count -gt 0) {
            Write-LogMessage -Type INFO -Message "Performing ESX reachability check (TCP 443) for $($allEsxHosts.Count) host(s)..."
            Test-VcenterAndEsxReachability -EsxHosts $allEsxHosts -Port 443 -VcenterName $Script:vCenterName
        }

        # Get the password for the vCenter: when nonInteractivePassword is true and VCENTER_COMMON_PASSWORD is set, try it first; on auth failure fall back to prompt.
        $vCenterCredential = $null
        if ($nonInteractivePassword -and -not [String]::IsNullOrWhiteSpace($env:VCENTER_COMMON_PASSWORD)) {
            try {
                $vCenterPassFromEnv = ConvertTo-SecureStringForCredential -PlainText $env:VCENTER_COMMON_PASSWORD
                $vCenterCredential = New-Object System.Management.Automation.PSCredential($Script:VCenterUser, $vCenterPassFromEnv)
                Disconnect-Vcenter -AllServers -Silence
                Connect-Vcenter -ServerName $Script:vCenterName -ServerCredential $vCenterCredential -ServerType "vCenter"
                Write-LogMessage -Type DEBUG -Message "Authenticated to vCenter using VCENTER_COMMON_PASSWORD environment variable."
            } catch {
                $errorMessage = $_.Exception.Message
                if ($errorMessage -match "incorrect user name or password|authentication|credentials") {
                    Write-LogMessage -Type WARNING -Message "vCenter authentication with VCENTER_COMMON_PASSWORD failed; falling back to password prompt."
                    $vCenterCredential = $null
                } else {
                    throw
                }
            }
        }
        if (-not $vCenterCredential) {
            $vCenterPass = Get-InteractiveInput -PromptMessage "`nEnter the password for the user `"$Script:VCenterUser`" on vCenter `"$Script:vCenterName`" " -asSecureString
            $vCenterCredential = New-Object System.Management.Automation.PSCredential($Script:VCenterUser, $vCenterPass)
            Disconnect-Vcenter -AllServers -Silence
            Connect-Vcenter -ServerName $Script:vCenterName -ServerCredential $vCenterCredential -ServerType "vCenter"
        }

        # Check if the vCenter version is supported.
        $result = Test-VCenterVersion -MinimumVersion "9.0.0"
        if (-not $result.Success) {
            Write-LogMessage -Type ERROR -Message "vCenter version check failed: $($result.ErrorMessage)"
            throw [VcfDeploymentException]::new()
        }

        # Enforce vCenter 9 supervisor limit (default 50 per vCenter per product guidance); fail if already at limit so we cannot add another.
        $supervisorCountResult = Get-VcenterSupervisorCount -ErrorAction SilentlyContinue
        if ($null -ne $supervisorCountResult) {
            $currentSupervisorCount = $supervisorCountResult.Count
            Write-LogMessage -Type DEBUG -Message "vCenter `"$Script:vCenterName`" has $currentSupervisorCount supervisor(s). Maximum allowed before this deployment: $MaximumSupervisorsPerVcenter."
            if ($currentSupervisorCount -ge $MaximumSupervisorsPerVcenter) {
                Write-LogMessage -Type ERROR -Message "vCenter `"$Script:vCenterName`" has $currentSupervisorCount supervisor(s). vCenter 9 supports a maximum of $MaximumSupervisorsPerVcenter supervisors per vCenter."
                Write-LogMessage -Type ERROR -Message "Deploy your new edge cluster to a different vCenter, or remove existing supervisors from this vCenter before re-running."
                throw [VcfDeploymentException]::new()
            }
        }

        Set-ScriptVcenterCredential -Credential $vCenterCredential

        # When -CleanUp is set, run the cleanup workflow and exit without deploying.
        if ($CleanUp -in @("Supervisor", "Compute", "All", "ArgoCD", "Harbor")) {
            $cleanupParams = @{
                CleanUp            = $CleanUp
                ClusterNamePrefix  = $clusterNamePrefix
                ClustersToProcess  = $clustersToProcess
                DatastoreNamePrefix = $datastoreNamePrefix
                Force              = $Force
                InputData          = $inputData
                LabEnvironment     = $labEnvironment
                SupervisorNamePrefix = $supervisorNamePrefix
                VdsNamePrefix      = $vdsNamePrefix
            }
            if ($CleanUp -eq "Harbor") {
                $harborCleanupYamlPath = $null
                foreach ($c in $clustersToProcess) {
                    if (-not (Get-EffectiveSupervisorServiceFlag -Cluster $c -CommonData $inputData.common -FlagName "disableHarbor")) {
                        $harborCleanupYamlPath = Get-EffectiveSupervisorServicesYamlPath -Cluster $c -CommonData $inputData.common -LogicalYamlPathPropertyName "harborServiceYamlPath"
                        break
                    }
                }
                if ($harborCleanupYamlPath) {
                    $cleanupParams["HarborServiceYamlPath"] = $harborCleanupYamlPath
                }
            }
            Invoke-VcfEdgeAtScaleCleanup @cleanupParams
            Write-LogMessage -Type INFO -Message "CleanUp ($CleanUp) completed. Exiting without deployment."
            return
        }

        if ($PSBoundParameters.ContainsKey("Force") -and $Force) {
            Write-LogMessage -Type INFO -Message "-Force is ignored when not performing cleanup."
        }

        # Verify all vSAN witness hosts are present in vCenter inventory before prompting for ESX credentials.
        # This ensures the site is fully ready to provision before asking the user for more input.
        # For non-vSAN (e.g. VMFS) clusters, a configured witness is not required; if the witness
        # FQDN is missing from inventory it is logged at DEBUG only and does not block deployment.
        foreach ($clusterForWitnessCheck in $clustersToProcess) {
            $witnessNameForCheck = Get-VsanWitnessNameForCluster -Cluster $clusterForWitnessCheck -InputData $inputData
            if (-not [String]::IsNullOrWhiteSpace($witnessNameForCheck)) {
                $storageTypeForWitnessCheck = $clusterForWitnessCheck.storagePolicy.storageType
                $isVsanClusterForWitnessCheck = ($storageTypeForWitnessCheck -eq "vSAN-ESA" -or $storageTypeForWitnessCheck -eq "vSAN-OSA")
                $witnessHostForCheck = Get-VMHost -Name $witnessNameForCheck -Server $Script:vCenterName -ErrorAction SilentlyContinue
                if (-not $witnessHostForCheck) {
                    if ($isVsanClusterForWitnessCheck) {
                        Write-LogMessage -Type ERROR -Message "vSAN witness host `"$witnessNameForCheck`" is not present in vCenter inventory. Add the witness host to vCenter before creating the cluster to avoid cleanup."
                        throw [VcfDeploymentException]::new()
                    } else {
                        Write-LogMessage -Type DEBUG -Message "vSAN witness `"$witnessNameForCheck`" is configured for edgeSite `"$($clusterForWitnessCheck.edgeSite)`" but is not in vCenter inventory; ignoring — witness is not required for `"$storageTypeForWitnessCheck`" deployments."
                    }
                } else {
                    Write-LogMessage -Type DEBUG -Message "vSAN witness host `"$witnessNameForCheck`" is present in vCenter inventory for edgeSite `"$($clusterForWitnessCheck.edgeSite)`"; proceeding."
                }
            }
        }

        # Collect ESX credentials: when esxUniquePasswordPerHost is false or omitted (default), one password for all hosts ($esxUniquePassword true); when true, prompt per host when needed.
        $esxPasswords = @{}
        $esxUsedEnvPassword = $false
        if ($esxUniquePassword -and $allEsxHosts.Count -gt 0) {
            if ($nonInteractivePassword -and (Test-Path Env:ESX_COMMON_PASSWORD)) {
                $esxPassFromEnv = ConvertTo-SecureStringForCredential -PlainText $env:ESX_COMMON_PASSWORD
                foreach ($esxHost in $allEsxHosts) {
                    $esxPasswords[$esxHost] = New-Object System.Management.Automation.PSCredential($esxUser, $esxPassFromEnv)
                }
                $esxUsedEnvPassword = $true
                if ([String]::IsNullOrEmpty($env:ESX_COMMON_PASSWORD)) {
                    Write-LogMessage -Type DEBUG -Message "Using ESX_COMMON_PASSWORD (empty) for null root password on ESX hosts."
                } else {
                    Write-LogMessage -Type DEBUG -Message "Using ESX_COMMON_PASSWORD environment variable for ESX authentication (esxUniquePasswordPerHost is false)."
                }
            } else {
                $hostList = $allEsxHosts -join ", "
                $esxPassword = Get-InteractiveInput -PromptMessage "`nEnter the password for the user `"$esxUser`" on ESX Host(s): $hostList" -AsSecureString -AllowEmpty
                foreach ($esxHost in $allEsxHosts) {
                    $esxPasswords[$esxHost] = New-Object System.Management.Automation.PSCredential($esxUser, $esxPassword)
                }
            }
        }

        # Track which ESX hosts have been version-checked (9.0.0 minimum) so we only check once per host.
        $esxVersionChecked = @{}

        # ESX pre-flight version check across every unique host, before we touch any cluster.
        # Catches unsupported ESX versions across all clusters up-front so we do not create
        # clusters 1..N-1 only to fail on cluster N. Authentication failures are tolerated here
        # (the per-cluster Connect-Vcenter in the deployment loop has the env-var + interactive
        # retry/fallback logic); only version mismatches fail fast.
        if ($allEsxHosts.Count -gt 0) {
            Write-LogMessage -Type INFO -Message "Pre-flight checking ESX version (9.0.0 minimum) across $($allEsxHosts.Count) host(s)..."
            foreach ($esxHost in $allEsxHosts) {
                if ($esxVersionChecked[$esxHost]) { continue }
                if (-not $esxPasswords[$esxHost]) { continue }
                $preflightConnected = $false
                try {
                    Connect-Vcenter -ServerName $esxHost -ServerCredential $esxPasswords[$esxHost] -ServerType "ESX" -SkipRetryPrompt
                    $preflightConnected = $true
                    $esxVerResult = Test-ESXVersion -ServerName $esxHost -MinimumVersion "9.0.0"
                    if (-not $esxVerResult.Success) {
                        Write-LogMessage -Type ERROR -Message $esxVerResult.ErrorMessage
                        throw [VcfDeploymentException]::new()
                    }
                    $esxVersionChecked[$esxHost] = $true
                } catch {
                    $errorMessage = $_.Exception.Message
                    if ($errorMessage -match "Authentication failed|incorrect user name or password") {
                        Write-LogMessage -Type DEBUG -Message "ESX pre-flight auth failed for host `"$esxHost`"; deferring to per-cluster retry logic."
                    } else {
                        throw
                    }
                } finally {
                    if ($preflightConnected) {
                        Disconnect-Vcenter -ServerName $esxHost -ServerType "ESX" -Silence
                    }
                }
            }
            $preflightCheckedCount = @($esxVersionChecked.Values | Where-Object { $_ -eq $true }).Count
            if ($preflightCheckedCount -eq $allEsxHosts.Count) {
                Write-LogMessage -Type INFO -Message "ESX pre-flight version check passed for all $($allEsxHosts.Count) host(s)."
            } else {
                Write-LogMessage -Type INFO -Message "ESX pre-flight version check passed for $preflightCheckedCount of $($allEsxHosts.Count) host(s); remaining host(s) will be version-checked during deployment (auth retry required)."
            }
        }

        $clusterIndex = 0
        foreach ($cluster in $clustersToProcess) {
            try {
            $Script:RollbackAttempted = $false
            $Script:RollbackFailed = $false
            $Script:ArgoCDPhaseStarted = $false
            $Script:HarborPhaseStarted = $false
            $Script:DidMigrateVmk0ToVdsThisRun = $false
            $supervisorId = $null
            $clusterIndex++
            $currentEdgeSite = $cluster.edgeSite

            # Inform user when starting a new site (after the first one).
            if ($clusterIndex -gt 1) {
                Write-Host ""
                Write-LogMessage -Type INFO -Message "Starting deployment for edgeSite: `"$currentEdgeSite`" (site $clusterIndex of $($clustersToProcess.Count))."
                Write-Host ""
            }

            $clusterName = Get-EffectiveClusterName -Cluster $cluster -ClusterNamePrefix $clusterNamePrefix -EdgeSite $currentEdgeSite
            $datastoreName = Get-DatastoreNameFromPrefix -DatastoreNamePrefix $datastoreNamePrefix -EdgeSite $currentEdgeSite
            $vdsName = Get-VdsNameFromPrefix -VdsNamePrefix $vdsNamePrefix -EdgeSite $currentEdgeSite
            $Script:SupervisorName = Get-SupervisorNameFromPrefix -SupervisorNamePrefix $supervisorNamePrefix -EdgeSite $currentEdgeSite

            $esxHosts = $cluster.esxHosts

            # Extract networking (networkSegments instead of portGroups). Edge site suffix is applied only to VMkernel port groups (mgmt, vmotion, vsan, vsanwitness) in Set-VirtualDistributedSwitch and Add-VmkernelInterfacesFromNetworkingConfig; FLB and supervisor network segments keep their configured names.
            $networkSegments = $null
            if ($cluster.networking -and $cluster.networking.networkSegments) {
                $networkSegments = $cluster.networking.networkSegments
            } else {
                Write-LogMessage -Type ERROR -Message "Cluster with edgeSite `"$currentEdgeSite`" has no network segments specified."
                throw [VcfDeploymentException]::new()
            }

            # Extract supervisor services (ArgoCD configuration). Cluster level takes priority over common.
            $argoCDyaml = Get-EffectiveArgoCdYamlPath -Cluster $cluster -CommonData $inputData.common -PropertyName "argoCdOperatorYamlPath"
            $argoCdDeploymentYamlPath = Get-EffectiveArgoCdYamlPath -Cluster $cluster -CommonData $inputData.common -PropertyName "argoCdDeploymentYamlPath"
            $argocdNameSpacePrefix = "argocd"
            $argocdVmClass = $null
            if ($cluster.supervisorServices) {
                if (-not [String]::IsNullOrWhiteSpace($cluster.supervisorServices.nameSpacePrefix)) {
                    $argocdNameSpacePrefix = $cluster.supervisorServices.nameSpacePrefix.Trim()
                }
                if ($null -ne $cluster.supervisorServices.vmClass -and $cluster.supervisorServices.vmClass.Count -gt 0) {
                    $argocdVmClass = if ($cluster.supervisorServices.vmClass -is [Array]) { @($cluster.supervisorServices.vmClass) } else { @($cluster.supervisorServices.vmClass) }
                }
            }

            # Resolve supervisor service disable flags. Cluster level takes priority over common-level.
            $disableArgoCD = Get-EffectiveSupervisorServiceFlag -Cluster $cluster -CommonData $inputData.common -FlagName "disableArgoCD"
            $disableHarbor = Get-EffectiveSupervisorServiceFlag -Cluster $cluster -CommonData $inputData.common -FlagName "disableHarbor"

            # Extract storage policy. VMFS uses default rule "Fully initialized" in Set-StoragePolicy; vSAN does not use a volume allocation rule.
            $storagePolicyName = $null
            $storagePolicyTagCatalog = $null
            $storagePolicyType = $null
            if ($cluster.storagePolicy) {
                $storagePolicyType = $cluster.storagePolicy.storageType
                $storagePolicyTagCatalog = $cluster.storagePolicy.storagePolicyTagCatalog
                if ([String]::IsNullOrWhiteSpace($storagePolicyTagCatalog)) {
                    $storagePolicyTagCatalog = $storagePolicyType + "-Storage-TagCatalog"
                    Write-LogMessage -Type DEBUG -Message "storagePolicyTagCatalog not defined; using default: `"$storagePolicyTagCatalog`""
                }
                Write-LogMessage -Type DEBUG -Message "Extracted storage policy type for cluster `"$currentEdgeSite`": `"$storagePolicyType`""
                # Generate storage policy name from prefix (if not provided, use supervisor name).
                if ($cluster.storagePolicy.storagePolicyName) {
                    $storagePolicyName = $cluster.storagePolicy.storagePolicyName
                } else {
                    $storagePolicyName = $Script:SupervisorName
                }
            } else {
                Write-LogMessage -Type DEBUG -Message "No storage policy configuration found for cluster `"$currentEdgeSite`"."
            }

            # Multi-host HA admission after VDS: vSAN OSA/ESA use common/clusters haPolicy (default reservationBased when omitted).
            # VMFS is always single-host; Update-Cluster ignores HaPolicy for single-host clusters and always sets
            # HAAdmissionControlEnabled=$false (disabled). Pass "disabled" explicitly so the value is semantically correct.
            $effectiveMultiHostHaPolicy = if ($storagePolicyType -eq "vSAN-ESA" -or $storagePolicyType -eq "vSAN-OSA") {
                Get-EffectiveHaPolicyForCluster -Cluster $cluster -InputData $inputData
            } else {
                "disabled"
            }
            Write-LogMessage -Type DEBUG -Message "Multi-host HA admission policy for edgeSite `"$currentEdgeSite`" (storage type `"$($storagePolicyType)`"): $effectiveMultiHostHaPolicy."

            # Resolve nicList for this cluster (cluster.nicList overrides common.nicList); validation already ensured 2 or 4 NICs.
            $nicList = Get-EffectiveNicListForCluster -Cluster $cluster -CommonNicList $inputData.common.nicList
            $numUplinks = $nicList.Count

            # Connect to all ESX hosts to validate connection and find datastore (only for VMFS storage policy types).
            # For vSAN-ESA and vSAN-OSA, we still validate credentials but skip datastore finding.
            $diskCanonicalNames = @{}
            $esxConnectionFailed = $false
            if ($storagePolicyType -ne "vSAN-ESA" -and $storagePolicyType -ne "vSAN-OSA") {
                foreach ($esxHost in $esxHosts) {
                    if (-not $esxPasswords[$esxHost]) {
                        $esxPassword = Get-InteractiveInput -PromptMessage "`nEnter the password for the user `"$esxUser`" on ESX Host: $esxHost" -AsSecureString -AllowEmpty
                        $esxPasswords[$esxHost] = New-Object System.Management.Automation.PSCredential($esxUser, $esxPassword)
                    }
                    try {
                        Connect-Vcenter -ServerName $esxHost -ServerCredential $esxPasswords[$esxHost] -ServerType "ESX"
                        if (-not $esxVersionChecked[$esxHost]) {
                            $esxVerResult = Test-ESXVersion -ServerName $esxHost -MinimumVersion "9.0.0"
                            if (-not $esxVerResult.Success) {
                                Write-LogMessage -Type ERROR -Message $esxVerResult.ErrorMessage
                                throw [VcfDeploymentException]::new()
                            }
                            $esxVersionChecked[$esxHost] = $true
                        }
                        $diskCanonicalName = Find-Datastore -DatastoreName $datastoreName -EsxHostName $esxHost
                        if ($diskCanonicalName) {
                            $diskCanonicalNames[$esxHost] = $diskCanonicalName
                        }
                    } catch {
                        $errorMessage = $_.Exception.Message
                        if ($errorMessage -match "Authentication failed" -and $esxUsedEnvPassword) {
                            Write-LogMessage -Type WARNING -Message "ESX authentication with ESX_COMMON_PASSWORD failed; falling back to password prompt."
                            $hostList = $esxHosts -join ", "
                            $esxPassword = Get-InteractiveInput -PromptMessage "`nEnter the password for the user `"$esxUser`" on ESX Host(s): $hostList" -AsSecureString -AllowEmpty
                            foreach ($esxHostName in $esxHosts) {
                                $esxPasswords[$esxHostName] = New-Object System.Management.Automation.PSCredential($esxUser, $esxPassword)
                            }
                            $esxUsedEnvPassword = $false
                            try {
                                Connect-Vcenter -ServerName $esxHost -ServerCredential $esxPasswords[$esxHost] -ServerType "ESX"
                                if (-not $esxVersionChecked[$esxHost]) {
                                    $esxVerResult = Test-ESXVersion -ServerName $esxHost -MinimumVersion "9.0.0"
                                    if (-not $esxVerResult.Success) {
                                        Write-LogMessage -Type ERROR -Message $esxVerResult.ErrorMessage
                                        throw [VcfDeploymentException]::new()
                                    }
                                    $esxVersionChecked[$esxHost] = $true
                                }
                                $diskCanonicalName = Find-Datastore -DatastoreName $datastoreName -EsxHostName $esxHost
                                if ($diskCanonicalName) {
                                    $diskCanonicalNames[$esxHost] = $diskCanonicalName
                                }
                            } catch {
                                $esxConnectionFailed = $true
                            }
                        } elseif ($errorMessage -match "Authentication failed") {
                            $esxConnectionFailed = $true
                            continue
                        } else {
                            Write-LogMessage -Type ERROR -Message "ESX host `"$esxHost`" could not be reached or datastore `"$datastoreName`" not found: $errorMessage"
                            $esxConnectionFailed = $true
                        }
                    }
                    finally {
                        # Always disconnect ESX (if connected), even on errors.
                        Disconnect-Vcenter -ServerName $esxHost -ServerType "ESX" -Silence
                    }
                }

                if ($esxConnectionFailed) {
                    Write-LogMessage -Type ERROR -Message "One or more ESX hosts could not be connected or verified. Check logs for details."
                    throw [VcfDeploymentException]::new()
                }
            }
            elseif ($storagePolicyType -eq "vSAN-ESA" -or $storagePolicyType -eq "vSAN-OSA") {
                Write-LogMessage -Type DEBUG -Message "Skipping datastore finding for storage policy type `"$storagePolicyType`" (vSAN workflows use different disk selection)."
                # Still validate ESX credentials for vSAN clusters to catch authentication issues early.
                Write-LogMessage -Type DEBUG -Message "Validating ESX host credentials for vSAN cluster..."
                $validationRetryCount = 0
                $maxValidationRetries = 3
                while ($validationRetryCount -lt $maxValidationRetries) {
                    $esxConnectionFailed = $false
                    $authenticationFailed = $false
                    $failedAuthHosts = @()
                    foreach ($esxHost in $esxHosts) {
                        if (-not $esxPasswords[$esxHost]) {
                            $esxPassword = Get-InteractiveInput -PromptMessage "`nEnter the password for the user `"$esxUser`" on ESX Host: $esxHost" -AsSecureString -AllowEmpty
                            $esxPasswords[$esxHost] = New-Object System.Management.Automation.PSCredential($esxUser, $esxPassword)
                        }
                        try {
                            Connect-Vcenter -ServerName $esxHost -ServerCredential $esxPasswords[$esxHost] -ServerType "ESX" -SkipRetryPrompt
                            if (-not $esxVersionChecked[$esxHost]) {
                                $esxVerResult = Test-ESXVersion -ServerName $esxHost -MinimumVersion "9.0.0"
                                if (-not $esxVerResult.Success) {
                                    Write-LogMessage -Type ERROR -Message $esxVerResult.ErrorMessage
                                    throw [VcfDeploymentException]::new()
                                }
                                $esxVersionChecked[$esxHost] = $true
                            }
                            Write-LogMessage -Type DEBUG -Message "Successfully validated credentials for ESX host `"$esxHost`"."
                        } catch {
                            # Connect-Vcenter already logged the failure; avoid duplicating long error text.
                            $errorMessage = $_.Exception.Message
                            if ($errorMessage -match "Authentication failed|incorrect user name or password") {
                                $authenticationFailed = $true
                                $esxConnectionFailed = $true
                                if ($failedAuthHosts -notcontains $esxHost) {
                                    $failedAuthHosts += $esxHost
                                }
                            } else {
                                Write-LogMessage -Type DEBUG -Message "ESX host `"$esxHost`" credential validation failed: $errorMessage"
                                Write-LogMessage -Type ERROR -Message "ESX host `"$esxHost`" could not be reached (see previous error)."
                                $esxConnectionFailed = $true
                            }
                        }
                        finally {
                            # Always disconnect ESX (if connected), even on errors.
                            Disconnect-Vcenter -ServerName $esxHost -ServerType "ESX" -Silence
                        }
                    }

                    if (-not $esxConnectionFailed) {
                        break
                    }

                    # If we get here, at least one host failed.
                    if ($authenticationFailed -and $validationRetryCount -lt ($maxValidationRetries - 1)) {
                        # Authentication failed - re-prompt for password(s).
                        Write-Host ""
                        $retryResponse = $null
                        while ($retryResponse -ne "Y" -and $retryResponse -ne "N") {
                            $retryResponse = Read-Host "Would you like to re-enter your password? (Y/N)"
                            $retryResponse = $retryResponse.Trim().ToUpper()
                        }
                        if ($retryResponse -ne "Y") {
                            Write-LogMessage -Type ERROR -Message "User chose not to retry. Exiting."
                            throw [VcfDeploymentException]::new()
                        }
                        Write-Host ""
                        if ($esxUniquePassword) {
                            $hostList = $esxHosts -join ", "
                            $promptMessage = "Enter the password for the user `"$esxUser`" on ESX `"$hostList`" (or press Enter for no password): "
                            $promptMessage = $promptMessage.TrimEnd(": ")
                            $newEsxPassword = Get-InteractiveInput -PromptMessage $promptMessage -AsSecureString -AllowEmpty
                            Write-Host ""
                            foreach ($esxHost in $esxHosts) {
                                $esxPasswords[$esxHost] = New-Object System.Management.Automation.PSCredential($esxUser, $newEsxPassword)
                            }
                            $esxUsedEnvPassword = $false
                        } else {
                            foreach ($esxHost in $failedAuthHosts) {
                                $promptMessage = "Enter the password for the user `"$esxUser`" on ESX Host: $esxHost (or press Enter for no password): "
                                $newEsxPassword = Get-InteractiveInput -PromptMessage $promptMessage -AsSecureString -AllowEmpty
                                Write-Host ""
                                $esxPasswords[$esxHost] = New-Object System.Management.Automation.PSCredential($esxUser, $newEsxPassword)
                            }
                        }
                        $validationRetryCount++
                        Write-LogMessage -Type INFO -Message "Retrying credential validation with new password..."
                    } else {
                        Write-LogMessage -Type ERROR -Message "Maximum retry attempts reached or non-authentication error occurred."
                        throw [VcfDeploymentException]::new()
                    }
                }
            }

            # Initialize content library for supervisor enablement/upgrades only when the key common.supervisorContentLibraryDatastore is present (removal of the key = skip workflow).
            if ($supervisorContentLibraryDatastoreKeyPresent) {
                Initialize-SupervisorContentLibrary -DatastoreName $supervisorContentLibraryDatastore -LibraryName $Script:SupervisorName -SubscriptionUrl $supervisorContentLibrarySubscriptionUrl
            } else {
                Write-LogMessage -Type DEBUG -Message "Supervisor content library skipped (common.supervisorContentLibraryDatastore key not defined)."
            }

            # Use the first host's canonical name for datastore creation (all hosts should have access to same storage).
            $diskCanonicalName = if ($diskCanonicalNames.Count -gt 0) { ($diskCanonicalNames.Values | Select-Object -First 1) } else { $null }

            # Create cluster with HAEnabled, DrsEnabled, AdmissionControlDisabled are by default.
            # Enable vSAN ESA if storage policy type is vSAN-ESA; enable vSAN OSA if vSAN-OSA.
            $enableVsanEsa = ($storagePolicyType -eq "vSAN-ESA")
            $enableVsanOsa = ($storagePolicyType -eq "vSAN-OSA")
            # Resolve vLcmImageName: edge (cluster) overrides common when both are defined.
            $vLcmImageName = $null
            if (-not [String]::IsNullOrWhiteSpace($cluster.vLcmImageName)) {
                $vLcmImageName = $cluster.vLcmImageName.Trim()
            } elseif ($inputData.common -and -not [String]::IsNullOrWhiteSpace($inputData.common.vLcmImageName)) {
                $vLcmImageName = $inputData.common.vLcmImageName.Trim()
            }
            Add-Cluster -ClusterName $clusterName -DataCenterName $datacenterName -VsanEsaEnabled:$enableVsanEsa -VsanOsaEnabled:$enableVsanOsa -VlcmImageName $vLcmImageName

            # Add all ESX hosts to cluster. Delay before 2nd+ hosts so the cluster can settle and first Add-VMHost attempt is more likely to succeed.
            $hostAddIndex = 0
            foreach ($esxHost in $esxHosts) {
                if ($hostAddIndex -ge 1 -and $DelayBeforeAddingNextHostSeconds -gt 0) {
                    Write-LogMessage -Type INFO -Message "Waiting $DelayBeforeAddingNextHostSeconds seconds before adding next host (cluster may still be settling from previous add)."
                    Start-Sleep -Seconds $DelayBeforeAddingNextHostSeconds
                }
                if (-not $esxPasswords[$esxHost]) {
                    $esxPassword = Get-InteractiveInput -PromptMessage "`nEnter the password for the user `"$esxUser`" on ESX Host: $esxHost" -AsSecureString -AllowEmpty
                    $esxPasswords[$esxHost] = New-Object System.Management.Automation.PSCredential($esxUser, $esxPassword)
                }
                Add-HostToCluster -ClusterName $clusterName -EsxCredential $esxPasswords[$esxHost] -EsxHostName $esxHost -NicList $nicList -StoragePolicyType $storagePolicyType
                $hostAddIndex++
            }

            # When using per-host passwords, destroy stored credentials for this cluster's hosts after use.
            if (-not $esxUniquePassword) {
                foreach ($esxHost in $esxHosts) {
                    $esxPasswords.Remove($esxHost)
                }
            }

            # Resolve MTU for VDS and vMotion/vSAN VMkernels from common.vSanvMotionVmKernelMtuValue (or legacy, then default 9000). Mgmt and vSAN Witness are always 1500.
            $vmkernelMtu = Get-EffectiveVmkernelMtu -InputData $inputData
            # VDS MTU must match the maximum of VMkernel interfaces on the switch: for VMFS there are no vMotion/vSAN VMkernels, so use 1500; for vSAN use the same as vMotion/vSAN VMkernels.
            $vdsMtu = if ($storagePolicyType -eq "VMFS") { 1500 } else { $vmkernelMtu }

            # Create VDS and migrate host management (vmk0) from vSS to vDS as soon as hosts are in the cluster.
            # Two NICs = one VDS; four NICs = two VDS (-sw1, -sw2). Management port group is suffixed with edge site (mgmt-VMFS); network segment port groups use configured names.
            Set-VirtualDistributedSwitch -ClusterName $clusterName -DatacenterName $datacenterName -Mtu $vdsMtu -NicList $nicList -NumUplinks $numUplinks -PortGroups $networkSegments -VdsName $vdsName

            # Create vMotion, vSAN, and optionally vSAN Witness VMkernel interfaces on the VDS when networkingVmKernelInterfaces is configured (vSAN-ESA / vSAN-OSA). At least vMotion and vSAN required; vSAN Witness optional. Mgmt (vmk0) must not carry vSAN; vmk0 may carry vSAN witness only when there is no dedicated vmk3.
            if (($storagePolicyType -eq "vSAN-ESA" -or $storagePolicyType -eq "vSAN-OSA") -and $cluster.networking.networkingVmKernelInterfaces -and $cluster.networking.networkingVmKernelInterfaces.Count -ge 2) {
                Add-VmkernelInterfacesFromNetworkingConfig -ClusterName $clusterName -EsxHostNames $esxHosts -NetworkingVmKernelInterfaces $cluster.networking.networkingVmKernelInterfaces -NumUplinks ([int]$numUplinks) -VdsName $vdsName -VmkernelMtu $vmkernelMtu
            }

            # Ensure vSAN and vSAN witness traffic; vmk0 is mgmt + vSAN witness only (no vSAN). Clear only vSAN from vmk0; add witness to vmk0 when no dedicated vSAN Witness VMkernel.
            $vsanRecheckInitialDelaySeconds = 10
            $vsanRecheckDelaySeconds = 5
            $vsanRecheckRetryCount = 3
            $hasDedicatedVsanWitness = if ($cluster.networking.networkingVmKernelInterfaces) { $cluster.networking.networkingVmKernelInterfaces | Where-Object { $_.service -eq "vSAN Witness" } } else { $null }
            if ($storagePolicyType -eq "vSAN-ESA" -or $storagePolicyType -eq "vSAN-OSA") {
                $clusterHostsForVsan = @(Get-VMHost -Location (Get-Cluster -Name $clusterName -Server $Script:vCenterName -ErrorAction Stop) -Server $Script:vCenterName -ErrorAction Stop)
                foreach ($dataHost in $clusterHostsForVsan) {
                    $dataHostName = $dataHost.Name
                    $vmk0 = Get-VMHostNetworkAdapter -VMHost $dataHost -VMKernel -Server $Script:vCenterName -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq "vmk0" }
                    if ($vmk0) {
                        if ($vmk0.PSObject.Properties["VsanTrafficEnabled"] -and $vmk0.VsanTrafficEnabled -eq $true) {
                            try {
                                Set-VMHostNetworkAdapter -VirtualNic $vmk0 -VsanTrafficEnabled $false -Confirm:$false -ErrorAction Stop | Out-Null
                                Write-LogMessage -Type INFO -Message "Cleared vSAN traffic from mgmt (vmk0) on host `"$dataHostName`" (post-VDS; vmk0 is mgmt + vSAN witness only)."
                            } catch {
                                Write-LogMessage -Type WARNING -Message "Could not clear vSAN from vmk0 on host `"$dataHostName`": $($_.Exception.Message). Clear manually if needed."
                            }
                        }
                        $vmk0WitnessProp = $vmk0.PSObject.Properties["VsanWitnessEnabled"] -or $vmk0.PSObject.Properties["VsanWitnessTrafficEnabled"]
                        $vmk0WitnessOn = if ($vmk0.PSObject.Properties["VsanWitnessEnabled"]) { $vmk0.VsanWitnessEnabled -eq $true } elseif ($vmk0.PSObject.Properties["VsanWitnessTrafficEnabled"]) { $vmk0.VsanWitnessTrafficEnabled -eq $true } else { $false }
                        if (-not $hasDedicatedVsanWitness -and (-not $vmk0WitnessProp -or -not $vmk0WitnessOn)) {
                            try {
                                Set-VMHostNetworkAdapter -VirtualNic $vmk0 -VsanWitnessEnabled $true -Confirm:$false -ErrorAction Stop | Out-Null
                                Write-LogMessage -Type INFO -Message "Enabled vSAN witness traffic on vmk0 on host `"$dataHostName`" (no dedicated vSAN Witness VMkernel)."
                            } catch {
                                $useEsxcliFallback = $_.Exception.Message -match "parameter cannot be found.*VsanWitness|VsanWitnessEnabled|VsanWitnessTrafficEnabled.*parameter|Parameter set cannot be resolved|cannot be used together"
                                if ($useEsxcliFallback) {
                                    try {
                                        Add-VsanWitnessTrafficToVmkViaEsxcli -VMHost $dataHost -VmkernelName "vmk0" -WitnessOnly | Out-Null
                                    } catch {
                                        Write-LogMessage -Type WARNING -Message "Could not enable vSAN witness on vmk0 on host `"$dataHostName`" (PowerCLI and esxcli failed): $($_.Exception.Message)."
                                    }
                                } else {
                                    Write-LogMessage -Type WARNING -Message "Could not enable vSAN witness on vmk0 on host `"$dataHostName`": $($_.Exception.Message)."
                                }
                            }
                        }
                    }
                    $vsanCheck = Test-VmkernelVsanAndWitnessTraffic -VMHost $dataHost
                    if (-not $vsanCheck.HasCompliantInterface) {
                        Write-LogMessage -Type DEBUG -Message "Post-VDS: no compliant vSAN/witness interface on host `"$dataHostName`" yet; retrying compliance check (API may lag after VMkernel creation)."
                        Start-Sleep -Seconds $vsanRecheckInitialDelaySeconds
                        $vsanCheck = Test-VmkernelVsanAndWitnessTraffic -VMHost $dataHost
                        $retryIdx = 1
                        while (-not $vsanCheck.HasCompliantInterface -and $retryIdx -le $vsanRecheckRetryCount) {
                            Write-LogMessage -Type DEBUG -Message "Post-VDS vSAN/witness re-check $retryIdx of $vsanRecheckRetryCount for host `"$dataHostName`"; waiting $vsanRecheckDelaySeconds seconds."
                            Start-Sleep -Seconds $vsanRecheckDelaySeconds
                            $vsanCheck = Test-VmkernelVsanAndWitnessTraffic -VMHost $dataHost
                            $retryIdx++
                        }
                        if (-not $vsanCheck.HasCompliantInterface) {
                            Write-LogMessage -Type ERROR -Message "No VMkernel with vSAN and vSAN witness traffic found on host `"$dataHostName`" (post-VDS). Use networkingVmKernelInterfaces for vMotion and vSAN (e.g. vmk2); vmk0 may carry vSAN witness only when there is no dedicated vmk3."
                            throw [VcfDeploymentException]::new()
                        }
                    }
                }
            }

            # Create the tag catalog category.
            Test-TagCatalogCategory -TagCatalog $storagePolicyTagCatalog

            # Create the tag name.
            Test-Tag -TagCatalog $storagePolicyTagCatalog -TagName $Script:SupervisorName

            # Reconfigure HA only when we moved vmk0 to the VDS this run so vCenter uses the management network for HA heartbeats.
            if ($Script:DidMigrateVmk0ToVdsThisRun) {
                Write-LogMessage -Type DEBUG -Message "Reconfiguring $clusterName for HA after moving vmk0 to vDS..."
                Invoke-ReconfigureClusterHA -ClusterName $clusterName -DelaySeconds $Script:HaNetworkStabilizationDelaySeconds -HaPolicy $effectiveMultiHostHaPolicy
            } else {
                Write-LogMessage -Type DEBUG -Message "No vmk0 migration performed this run for cluster `"$clusterName`". Skipping HA reconfiguration (idempotent)."
            }

            # Extract vSAN witness host (vSanWitnessVmName; cluster root overrides common).
            # For non-vSAN clusters (e.g. VMFS), any configured witness is discarded here so
            # downstream vSAN branches never receive an irrelevant witness name.
            $vSanWitnessVmName = $null
            if (-not [String]::IsNullOrWhiteSpace($cluster.vSanWitnessVmName)) {
                $vSanWitnessVmName = $cluster.vSanWitnessVmName
            } elseif (-not [String]::IsNullOrWhiteSpace($InputData.common.vSanWitnessVmName)) {
                $vSanWitnessVmName = $InputData.common.vSanWitnessVmName
            }
            if ($vSanWitnessVmName -and ($storagePolicyType -ne "vSAN-ESA" -and $storagePolicyType -ne "vSAN-OSA")) {
                Write-LogMessage -Type DEBUG -Message "vSAN witness `"$vSanWitnessVmName`" is configured for edgeSite `"$currentEdgeSite`" but is not required for `"$storagePolicyType`"; ignoring."
                $vSanWitnessVmName = $null
            }

            # Handle storage configuration based on storage policy type.
            # $storageAlreadyProvisioned is set to $true in vSAN branches when the datastore tag
            # already existed, indicating a fully idempotent re-run; used to skip vLCM below.
            $storageAlreadyProvisioned = $false
            Write-LogMessage -Type DEBUG -Message "Storage policy type for cluster `"$clusterName`": `"$storagePolicyType`""
            if ($storagePolicyType -eq "vSAN-ESA" -or $storagePolicyType -eq "vSAN-OSA") {
                Enable-VsanAutomaticDiskClaimIfSupported -ClusterName $clusterName | Out-Null
                # Idempotent: only run rebalance/reapply when not already at desired state (rebalance 30%, advCfgSync in sync).
                $vsanHealthSummary = Get-VsanClusterHealthSummaryViaView -ClusterName $clusterName -FetchFromCache $false
                # When health summary is null (API unavailable), treat as in-sync so we skip reapply (idempotent).
                $advCfgInSync = if ($vsanHealthSummary) { Test-VsanClusterAdvCfgSyncInSync -HealthSummary $vsanHealthSummary } else { $true }
                $rebalanceAt30 = Test-VsanAutomaticRebalanceAtThreshold -ClusterName $clusterName -ExpectedThresholdPercent 30
                $needRebalance = -not $rebalanceAt30
                $needReapply = -not $advCfgInSync
                if (-not $vsanHealthSummary) {
                    Write-LogMessage -Type DEBUG -Message "vSAN health summary unavailable for cluster `"$clusterName`"; treating advCfgSync as in-sync and skipping re-apply."
                }
                if ($needRebalance -or $needReapply) {
                    Write-LogMessage -Type DEBUG -Message "Ensuring vSAN configuration is applied to all hosts in cluster `"$clusterName`"."
                    if ($needRebalance) {
                        Enable-VsanAutomaticRebalance -ClusterName $clusterName -AutomaticRebalanceThreshold 30 | Out-Null
                    } else {
                        Write-LogMessage -Type DEBUG -Message "vSAN automatic rebalancing already at 30% for cluster `"$clusterName`". Skipping rebalance enablement."
                    }
                    if ($needReapply) {
                        $vsanReapplySucceeded = Invoke-VsanClusterConfigReapply -ClusterName $clusterName
                        if (-not $vsanReapplySucceeded) {
                            Write-LogMessage -Type WARNING -Message "Could not re-apply vSAN cluster configuration for cluster `"$clusterName`". Proceeding with storage configuration; if hosts report vSAN disabled, check vCenter connectivity and retry."
                        }
                    } else {
                        Write-LogMessage -Type DEBUG -Message "vSAN advanced config already in sync for cluster `"$clusterName`". Skipping re-apply."
                    }
                } else {
                    Write-LogMessage -Type DEBUG -Message "vSAN configuration already applied (rebalance at 30%, advCfg in sync) for cluster `"$clusterName`". Skipping."
                }
            }
            if ($storagePolicyType -eq "vSAN-ESA") {
                # Configure vSAN ESA storage pools.
                Write-LogMessage -Type DEBUG -Message "Configuring vSAN ESA storage pools for cluster `"$clusterName`"."
                if ($vSanWitnessVmName) {
                    Add-VsanEsaStoragePoolDisk -AcceptBadCheckResults:$AcceptBadCheckResults.IsPresent -ClusterName $clusterName -DatastoreName $datastoreName -LabEnvironment $labEnvironment -PreferredFaultDomainName $currentEdgeSite -vSanWitnessVmName $vSanWitnessVmName
                } else {
                    Add-VsanEsaStoragePoolDisk -AcceptBadCheckResults:$AcceptBadCheckResults.IsPresent -ClusterName $clusterName -DatastoreName $datastoreName -LabEnvironment $labEnvironment
                }
                # Tag the vSAN ESA datastore with the same tag (name and catalog) used by the storage policy so SPBM can match it.
                try {
                    $vsanDatastoreObject = Get-Datastore -Name $datastoreName -Server $Script:vCenterName -ErrorAction Stop
                } catch [VcfDeploymentException] {
                    throw  # already logged and typed — propagate without re-wrapping
                } catch {
                    Write-LogMessage -Type ERROR -Message "Get-Datastore failed for vSAN ESA datastore `"$datastoreName`": $($_.Exception.Message)."
                    throw [VcfDeploymentException]::new()
                }
                $storagePolicyTagObject = Get-Tag -Name $Script:SupervisorName -Category $storagePolicyTagCatalog -Server $Script:vCenterName -ErrorAction Stop
                $existingTagAssignment = Get-TagAssignment -Entity $vsanDatastoreObject -Server $Script:vCenterName -ErrorAction SilentlyContinue | Where-Object { $_.Tag.Id -eq $storagePolicyTagObject.Id }
                if ($existingTagAssignment) {
                    Write-LogMessage -Type INFO -Message "vSAN ESA datastore `"$datastoreName`" already has tag `"$Script:SupervisorName`" (catalog `"$storagePolicyTagCatalog`") assigned. Skipping tag assignment."
                    $storageAlreadyProvisioned = $true
                } else {
                    New-TagAssignment -Tag $storagePolicyTagObject -Entity $vsanDatastoreObject -Server $Script:vCenterName -ErrorAction Stop | Out-Null
                    Write-LogMessage -Type INFO -Message "Successfully tagged vSAN ESA datastore `"$datastoreName`" with tag `"$Script:SupervisorName`" (catalog `"$storagePolicyTagCatalog`")."
                }
            }
            elseif ($storagePolicyType -eq "vSAN-OSA") {
                # Configure vSAN OSA disk groups (cache + capacity per host), then witness and health check.
                Write-LogMessage -Type DEBUG -Message "Configuring vSAN OSA disk groups for cluster `"$clusterName`"."
                if ($vSanWitnessVmName) {
                    Add-VsanOsaDiskGroupToCluster -AcceptBadCheckResults:$AcceptBadCheckResults.IsPresent -ClusterName $clusterName -DatastoreName $datastoreName -LabEnvironment $labEnvironment -PreferredFaultDomainName $currentEdgeSite -vSanWitnessVmName $vSanWitnessVmName
                } else {
                    Add-VsanOsaDiskGroupToCluster -AcceptBadCheckResults:$AcceptBadCheckResults.IsPresent -ClusterName $clusterName -DatastoreName $datastoreName -LabEnvironment $labEnvironment
                }
                # Tag the vSAN OSA datastore with the same tag (name and catalog) used by the storage policy so SPBM can match it.
                try {
                    $vsanDatastoreObject = Get-Datastore -Name $datastoreName -Server $Script:vCenterName -ErrorAction Stop
                } catch [VcfDeploymentException] {
                    throw  # already logged and typed — propagate without re-wrapping
                } catch {
                    Write-LogMessage -Type ERROR -Message "Get-Datastore failed for vSAN OSA datastore `"$datastoreName`": $($_.Exception.Message)."
                    throw [VcfDeploymentException]::new()
                }
                $storagePolicyTagObject = Get-Tag -Name $Script:SupervisorName -Category $storagePolicyTagCatalog -Server $Script:vCenterName -ErrorAction Stop
                $existingTagAssignment = Get-TagAssignment -Entity $vsanDatastoreObject -Server $Script:vCenterName -ErrorAction SilentlyContinue | Where-Object { $_.Tag.Id -eq $storagePolicyTagObject.Id }
                if ($existingTagAssignment) {
                    Write-LogMessage -Type INFO -Message "vSAN OSA datastore `"$datastoreName`" already has tag `"$Script:SupervisorName`" (catalog `"$storagePolicyTagCatalog`") assigned. Skipping tag assignment."
                    $storageAlreadyProvisioned = $true
                } else {
                    New-TagAssignment -Tag $storagePolicyTagObject -Entity $vsanDatastoreObject -Server $Script:vCenterName -ErrorAction Stop | Out-Null
                    Write-LogMessage -Type INFO -Message "Successfully tagged vSAN OSA datastore `"$datastoreName`" with tag `"$Script:SupervisorName`" (catalog `"$storagePolicyTagCatalog`")."
                }
            }
            else {
                # Create VMFS Datastore on the first ESX host (all hosts should have access).
                $firstEsxHost = $esxHosts[0]
                try {
                    $esxHostObject = Get-VMHost -Name $firstEsxHost -Server $Script:vCenterName -ErrorAction SilentlyContinue
                } catch [VcfDeploymentException] {
                    throw  # already logged and typed — propagate without re-wrapping
                } catch {
                    Write-LogMessage -Type ERROR -Message "Failed to get the ESX host `"$firstEsxHost`" on vCenter `"$Script:vCenterName`": $($_.Exception.Message)"
                    throw [VcfDeploymentException]::new()
                }
                $storageAlreadyProvisioned = Set-NewDatastore -DatastoreName $datastoreName -EsxHost $esxHostObject -DiskCanonicalName $diskCanonicalName -TagName $Script:SupervisorName
            }

            # Create storage policy for all storage types (tag-based placement; datastore must have the tag). VMFS uses default RuleValue "Fully initialized" in Set-StoragePolicy.
            $setStoragePolicyParams = @{
                PolicyName = $storagePolicyName
                StorageType = $storagePolicyType
                TagCatalog = $storagePolicyTagCatalog
                TagName = $Script:SupervisorName
            }
            Set-StoragePolicy @setStoragePolicyParams

            # Ensure cluster is compliant to the vLCM image before checking vSAN alarms; remediate
            # if not. Skipped when storage was already provisioned ($storageAlreadyProvisioned),
            # meaning this is a fully idempotent re-run where vLCM was already verified previously.
            if (-not $storageAlreadyProvisioned) {
                Invoke-VlcmClusterComplianceAndRemediate -AcceptBadCheckResults:$AcceptBadCheckResults.IsPresent -ClusterName $clusterName
                Write-Progress -Activity "Task created by VMware vSphere Lifecycle Manager" -Completed
                [Console]::Out.Flush()
            } else {
                Write-LogMessage -Type DEBUG -Message "Skipping vLCM compliance check for cluster `"$clusterName`": storage was already provisioned in a prior run."
            }

            # Always enable vSAN performance service for vSAN clusters; then query alarms and fix fixable ones (e.g. advanced config sync). "vSphere HA host status" is auto-remediated by re-applying HA/DRS when detected.
            if ($storagePolicyType -eq "vSAN-ESA" -or $storagePolicyType -eq "vSAN-OSA") {
                Enable-VsanPerformanceService -ClusterName $clusterName
                Invoke-VsanClusterAlarmCheckAndRemediate -AcceptBadCheckResults:$AcceptBadCheckResults.IsPresent -ClusterName $clusterName -HaPolicy $effectiveMultiHostHaPolicy -LabEnvironment $labEnvironment
            }

            # Verify at least one datastore is compatible with the storage policy before enabling supervisor (avoids "No compatible datastore" for Default Kubernetes Content Library).
            $storagePolicyObject = Get-SpbmStoragePolicy -Name $storagePolicyName -Server $Script:vCenterName -ErrorAction Stop
            try {
                $compatibleStorage = Get-SpbmCompatibleStorage -StoragePolicy $storagePolicyObject -Server $Script:vCenterName -ErrorAction Stop
            } catch {
                $errMsg = $_.Exception.Message
                if ($_.Exception.InnerException) {
                    Write-LogMessage -Type ERROR -Message "Get-SpbmCompatibleStorage failed for storage policy `"$storagePolicyName`": $errMsg Inner: $($_.Exception.InnerException.Message)."
                } else {
                    Write-LogMessage -Type ERROR -Message "Get-SpbmCompatibleStorage failed for storage policy `"$storagePolicyName`": $errMsg"
                }
                throw [VcfDeploymentException]::new()
            }
            if (-not $compatibleStorage -or $compatibleStorage.Count -eq 0) {
                Write-LogMessage -Type ERROR -Message "No compatible datastore found for storage policy `"$storagePolicyName`" (required for supervisor Default Kubernetes Content Library)."
                Write-LogMessage -Type ERROR -Message "Ensure a datastore is tagged with tag `"$Script:SupervisorName`" from catalog `"$storagePolicyTagCatalog`" (same tag used by the policy)."
                throw [VcfDeploymentException]::new()
            }
            Write-LogMessage -Type DEBUG -Message "Storage policy `"$storagePolicyName`" has $($compatibleStorage.Count) compatible datastore(s). Proceeding with supervisor enablement."

            # VDS and network segment port groups were created right after adding hosts (Set-VirtualDistributedSwitch).

            # Get the cluster MoRef ID.
            $clusterId = Get-ClusterId -ClusterName $clusterName

            $storagePolicyId = Get-StoragePolicyId -StoragePolicyName $storagePolicyName

            if ($ComputeOnly) {
                Write-LogMessage -Type INFO -Message "ComputeOnly is set. Pre-supervisor steps complete for cluster `"$clusterName`". Skipping supervisor, Argo CD, Harbor, and other post-supervisor steps."
                if ($storagePolicyType -eq "vSAN-ESA" -or $storagePolicyType -eq "vSAN-OSA") {
                    Invoke-VsanClusterHealthRetestAfterDeployment -ClusterName $clusterName
                    Write-VsanClusterHealthReport -ClusterName $clusterName
                }
                Write-ClusterEsxiNodeHealthReport -ClusterName $clusterName
                continue
            }

            # Initialize $argocdNameSpace to $null before the ArgoCD block. When ArgoCD is disabled the variable
            # stays $null, which the rollback catch block checks with IsNullOrWhiteSpace to skip ArgoCD rollback.
            # Without this initialization, a stale value from a prior cluster iteration could cause incorrect rollback.
            $argocdNameSpace = $null
            if (-not $disableArgoCD) {
                $originalArgoCdNameSpace = $argocdNameSpacePrefix
                Write-LogMessage -Type DEBUG -Message "Original ArgoCD namespace prefix from JSON: `"$originalArgoCdNameSpace`""

                $clusterObject = Get-Cluster -Name $clusterName -Server $Script:vCenterName -ErrorAction Stop
                $argocdNameSpace = Get-ArgoCDNamespaceFromCluster -ClusterObject $clusterObject -ClusterSpec $cluster
                Write-LogMessage -Type DEBUG -Message "Forming ArgoCD namespace name `"$argocdNameSpace`" from prefix `"$argocdNameSpacePrefix`" and cluster MoRef (domain stripped) to ensure uniqueness."

                Write-LogMessage -Type DEBUG -Message "Checking if the namespace value specified in `"$InfrastructureJson`" is consistent with the namespace value specified in the ArgoCD deployment yaml file."
                $isValid = Test-YamlPropertyConsistency -yamlFilePath $argoCdDeploymentYamlPath -allowMissingProperties @("metadata.namespace") -expectedValues @($originalArgoCdNameSpace) -validationName "namespace consistency"
                if (-not $isValid) {
                    Write-LogMessage -Type ERROR -Message "ArgoCD deployment YAML file validation failed. Please check the error messages above for details."
                    Write-LogMessage -Type ERROR -Message "Common issues:"
                    Write-LogMessage -Type ERROR -Message "  - The file path specified in infrastructure.json may be incorrect"
                    Write-LogMessage -Type ERROR -Message "  - The file may not exist at the specified location"
                    Write-LogMessage -Type ERROR -Message "  - If using a relative path, ensure you're running from the correct directory"
                    throw [VcfDeploymentException]::new()
                } else {
                    Write-LogMessage -Type DEBUG -Message "The namespace specified in $InfrastructureJson is consistent in the ArgoCD deployment yaml file."
                }
            }

            $supervisorCreatedThisSite = $false
            $supervisorCreationAttemptedThisSite = $false
            # Get or create supervisor using the new function (with EdgeSite and network segments for gateway mapping).
            # Pass Script:VcenterCredential so REST API always uses the PSCredential that succeeded for Connect-Vcenter.
            # See PASSWORD_HANDLING.md.
            $supervisorCreationAttemptedThisSite = $true
            $supervisorId = Get-OrCreateSupervisor -StoragePolicyId $storagePolicyId -SupervisorName $Script:SupervisorName -VcenterCredential $Script:VcenterCredential -SupervisorJson $SupervisorJson -ClusterId $clusterId -ClusterName $clusterName -EdgeSite $currentEdgeSite -NetworkSegments $networkSegments -SingleSite:($clustersToProcess.Count -eq 1) -InsecureTls
            $supervisorCreatedThisSite = $true

            # Deploy ArgoCD — extracted to Invoke-ArgoCDDeploymentPhase for readability.
            if (-not $disableArgoCD) {
                $argoCDContext = @{
                    ArgoCdDeploymentYamlPath = $argoCdDeploymentYamlPath
                    ArgoCDyaml               = $argoCDyaml
                    ArgocdNameSpace          = $argocdNameSpace
                    ArgocdVmClass            = $argocdVmClass
                    ClusterId                = $clusterId
                    ClusterName              = $clusterName
                    ContextName              = $contextName
                    InsecureTls              = $true  # ArgoCD path is currently always InsecureTls; stored for forward compatibility
                    StoragePolicyId          = $storagePolicyId
                    SupervisorId             = $supervisorId
                    VcenterCredential        = $Script:VcenterCredential
                }
                $argocdVmClass = Invoke-ArgoCDDeploymentPhase -Context $argoCDContext
            } else {
                Write-LogMessage -Type INFO -Message "ArgoCD deployment skipped for edge site `"$currentEdgeSite`" (disableArgoCD is set in infrastructure JSON)."
            }

            # Harbor Supervisor Service deployment — extracted to Invoke-HarborDeploymentPhase for readability.
            $harborServiceName = $null
            if (-not $disableHarbor) {
                $harborContext = @{
                    Cluster                      = $cluster
                    ClusterId                    = $clusterId
                    ClusterName                  = $clusterName
                    ContextName                  = $contextName
                    CurrentEdgeSite              = $currentEdgeSite
                    InputData                    = $inputData
                    InsecureTls                  = $true
                    LabEnvironment               = $labEnvironment
                    PreserveAutoGeneratedKeyCert = $preserveAutoGeneratedKeyCertPair
                    SaveHarborYaml               = $SaveHarborYaml
                    StoragePolicyName            = $storagePolicyName
                    SupervisorId                 = $supervisorId
                }
                $harborServiceName = Invoke-HarborDeploymentPhase -Context $harborContext
            } else {
                Write-LogMessage -Type INFO -Message "Harbor deployment skipped for edge site `"$currentEdgeSite`" (disableHarbor is set in infrastructure JSON)."
            }

            Write-LogMessage -Type INFO -Message "Completed deployment for cluster with edgeSite: $currentEdgeSite"
            Write-ClusterEsxiNodeHealthReport -ClusterName $clusterName
            if (-not [String]::IsNullOrWhiteSpace($supervisorId)) {
                Write-SupervisorHealthReport -ClusterName $clusterName -SupervisorId $supervisorId
            }
            if ($storagePolicyType -eq "vSAN-ESA" -or $storagePolicyType -eq "vSAN-OSA") {
                Invoke-VsanClusterHealthRetestAfterDeployment -ClusterName $clusterName
                Write-VsanClusterHealthReport -ClusterName $clusterName
            }
            # Note: We do NOT disconnect from vCenter between clusters when they share the same vCenter FQDN
            # (all clusters use $Script:vCenterName from common.vCenterName). Disconnection only occurs in the
            # finally block, which handles: final cluster, single cluster (EdgeSite specified), and error cases.
            } catch [RollbackSkippedException] {
                Write-LogMessage -Type WARNING -Message "Skipping rollback for edgeSite `"$currentEdgeSite`"; leaving site in current state. Continuing to next site."
                continue
            } catch {
                if ($Script:RollbackFailed) {
                    Write-LogMessage -Type ERROR -Message "Rollback failed for edgeSite `"$currentEdgeSite`"; exiting with failure (no second rollback prompt)."
                    throw
                }
                if ($Script:RollbackAttempted) {
                    Write-LogMessage -Type INFO -Message "Rollback was already attempted for this failure; rethrowing without prompting again."
                    throw
                }
                if ($supervisorCreatedThisSite) {
                    # Harbor phase failure: Harbor-only rollback (remove service, supervisor + ArgoCD left intact).
                    # ArgoCD phase failure: ArgoCD-only rollback (remove namespace, supervisor left intact).
                    # Post-supervisor but pre-ArgoCD/Harbor failure: supervisor-only rollback.
                    if ($Script:HarborPhaseStarted) {
                        if (-not [String]::IsNullOrWhiteSpace($harborServiceName)) {
                            # Service was registered before the failure; remove it.
                            Write-LogMessage -Type INFO -Message "Harbor deployment failure for edgeSite `"$currentEdgeSite`"; rollback decision required (Harbor-only: remove service, supervisor and ArgoCD left intact for idempotent retry)."
                            try {
                                Invoke-HarborOnlyRollback -ClusterName $clusterName -Service $harborServiceName -SingleSite:($clustersToProcess.Count -eq 1) -SupervisorId $supervisorId
                            } catch [RollbackSkippedException] {
                                Write-LogMessage -Type WARNING -Message "Skipping rollback for edgeSite `"$currentEdgeSite`"; leaving site in current state. Continuing to next site."
                                continue
                            } catch {
                                throw
                            }
                        } else {
                            # Harbor phase started but failed before the service was registered; nothing to remove.
                            Write-LogMessage -Type INFO -Message "Harbor deployment failure for edgeSite `"$currentEdgeSite`" (failure before service registration; no Harbor service to remove). Supervisor and ArgoCD left intact for idempotent retry."
                        }
                    } elseif ($Script:ArgoCDPhaseStarted -and -not [String]::IsNullOrWhiteSpace($argocdNameSpace)) {
                        Write-LogMessage -Type INFO -Message "ArgoCD deployment failure for edgeSite `"$currentEdgeSite`"; rollback decision required (ArgoCD-only: remove namespace, supervisor left intact for idempotent retry)."
                        try {
                            Invoke-ArgoCDOnlyRollback -ArgoCDNamespace $argocdNameSpace -ClusterName $clusterName -SupervisorId $supervisorId
                        } catch [RollbackSkippedException] {
                            Write-LogMessage -Type WARNING -Message "Skipping rollback for edgeSite `"$currentEdgeSite`"; leaving site in current state. Continuing to next site."
                            continue
                        } catch {
                            throw
                        }
                    } else {
                        Write-LogMessage -Type INFO -Message "Supervisor deployment failure for edgeSite `"$currentEdgeSite`"; running supervisor-only rollback (compute/vSAN/VDS left intact)."
                        try {
                            Invoke-SupervisorOnlyRollback -ClusterId $clusterId -ClusterName $clusterName -SingleSite:($clustersToProcess.Count -eq 1) -SupervisorId $supervisorId
                        } catch [RollbackSkippedException] {
                            Write-LogMessage -Type WARNING -Message "Skipping rollback for edgeSite `"$currentEdgeSite`"; leaving site in current state. Continuing to next site."
                            continue
                        } catch {
                            throw
                        }
                    }
                } elseif ($supervisorCreationAttemptedThisSite) {
                    # Supervisor creation failed (e.g. API error or timeout; user may have already deactivated in Get-OrCreateSupervisor). If RollbackAttempted was set there, we skip this block via the check above.
                    Write-LogMessage -Type INFO -Message "Supervisor creation failed for edgeSite `"$currentEdgeSite`" (compute passed); running supervisor-only rollback (compute/vSAN/VDS left intact)."
                    try {
                        Invoke-SupervisorOnlyRollback -ClusterId $clusterId -ClusterName $clusterName -SingleSite:($clustersToProcess.Count -eq 1) -SupervisorId $supervisorId
                    } catch [RollbackSkippedException] {
                        Write-LogMessage -Type WARNING -Message "Skipping rollback for edgeSite `"$currentEdgeSite`"; leaving site in current state. Continuing to next site."
                        continue
                    } catch {
                        throw
                    }
                } else {
                    # Pre-supervisor failure: offer rollback so user can tear down partial deployment. Full teardown only when no supervisor was created this run (do not tear down compute if a supervisor is running).
                    if ($storagePolicyType -eq "vSAN-ESA" -or $storagePolicyType -eq "vSAN-OSA") {
                        $rollbackDecision = Invoke-PauseBeforeRollbackIfRequested -ForcePrompt -RollbackContext "vSAN deployment failure (edgeSite `"$currentEdgeSite`")" -SingleSite:($clustersToProcess.Count -eq 1)
                        if ($rollbackDecision -eq "DoNotRollback") {
                            Write-LogMessage -Type WARNING -Message "Rollback skipped for edgeSite `"$currentEdgeSite`"; leaving site in current state. Continuing to next site."
                            continue
                        }
                        $deploymentFailureMessage = $_.Exception.Message
                        $vsanRollbackCompleted = $false
                        try {
                            $rollbackParams = @{ ClusterName = $clusterName; StoragePolicyType = $storagePolicyType; SkipClusterRemoval = $true; SuppressPrompt = $true }
                            if ($storagePolicyTagCatalog) {
                                $rollbackParams["StoragePolicyTagCatalog"] = $storagePolicyTagCatalog
                                $rollbackParams["StoragePolicyTagName"] = $Script:SupervisorName
                            }
                            if ($esxHosts -and $esxHosts.Count -gt 0) { $rollbackParams["EsxHostNames"] = @($esxHosts) }
                            $witnessName = $null
                            if (-not [String]::IsNullOrWhiteSpace($cluster.vSanWitnessVmName)) { $witnessName = $cluster.vSanWitnessVmName }
                            elseif ($inputData.common -and -not [String]::IsNullOrWhiteSpace($inputData.common.vSanWitnessVmName)) { $witnessName = $inputData.common.vSanWitnessVmName }
                            if ($witnessName) { $rollbackParams["WitnessHostName"] = $witnessName }
                            # Complete rollback: same sequence as cleanup (VMkernel removal, management restore, vSAN teardown, VDS removal, cluster removal). No supervisor was created this run.
                            Write-LogMessage -Type INFO -Message "Running complete rollback for edgeSite `"$currentEdgeSite`" (full teardown: VMkernel, management restore, vSAN, VDS, cluster)."
                            $nicListForRestore = Get-EffectiveNicListForCluster -Cluster $cluster -CommonNicList $inputData.common.nicList
                            if (-not $nicListForRestore -or $nicListForRestore.Count -eq 0) { $nicListForRestore = $inputData.common.nicList }
                            $nicListCountForRestore = if ($nicListForRestore -and $nicListForRestore.Count -eq 4) { 4 } else { 2 }
                            $vdsNamesForCleanup = @($vdsName, "$vdsName-sw1", "$vdsName-sw2")
                            try {
                                Remove-NonVmk0VmkernelInterfacesFromVds -ClusterName $clusterName -VdsNames $vdsNamesForCleanup
                            } catch {
                                Write-LogMessage -Type WARNING -Message "Non-vmk0 VMkernel removal had errors during vSAN rollback (non-fatal): $($_.Exception.Message)."
                            }
                            try {
                                $restoreResult = Invoke-ManagementRestoreForCleanupWithTopologyFallback -ClusterName $clusterName -NicListCount $nicListCountForRestore -VdsName $vdsName
                            } catch {
                                $Script:RollbackFailed = $true
                                Write-LogMessage -Type ERROR -Message "Management restore during vSAN rollback failed: $($_.Exception.Message). Remove VDS and cluster manually if needed."
                                throw
                            }
                            if ($restoreResult.RestoreAttempted -and -not $restoreResult.Success) {
                                $Script:RollbackFailed = $true
                                Write-LogMessage -Type ERROR -Message "Management was not moved back to VSS for cluster `"$clusterName`" during rollback. $($restoreResult.Message) Move vmk0 off the VDS manually on each host, then retry cleanup or rollback. Skipping VDS and cluster removal."
                                throw [VcfDeploymentException]::new()
                            }
                            Invoke-VsanDeploymentRollback @rollbackParams
                            # Guard: a supervisor from a prior deployment may still be running. Attempting VDS
                            # removal while supervisor port groups are in use will fail. Check before proceeding.
                            if (Test-SupervisorDeployedOnCluster -ClusterName $clusterName) {
                                $Script:RollbackFailed = $true
                                Write-LogMessage -Type ERROR -Message "Supervisor is active on cluster `"$clusterName`" from a prior deployment. VDS and cluster cannot be removed while the supervisor is running. Deactivate it first with -CleanUp Supervisor, then remove compute with -CleanUp Compute."
                                throw [VcfDeploymentException]::new()
                            }
                            $vdsRemovalSucceeded = $true
                            Write-LogMessage -Type INFO -NoNewline -Message "Removing VDS(es) for cluster `"$clusterName`"... "
                            try { Remove-EdgeClusterDistributedSwitch -ClusterName $clusterName -VdsName $vdsName } catch { $vdsRemovalSucceeded = $false; Write-LogMessage -Type WARNING -Message "Could not remove VDS `"$vdsName`" during rollback: $($_.Exception.Message)." }
                            try { Remove-EdgeClusterDistributedSwitch -ClusterName $clusterName -VdsName "$vdsName-sw1" } catch { $vdsRemovalSucceeded = $false }
                            try { Remove-EdgeClusterDistributedSwitch -ClusterName $clusterName -VdsName "$vdsName-sw2" } catch { $vdsRemovalSucceeded = $false }
                            if ($vdsRemovalSucceeded) {
                                Write-LogMessage -Type INFO -CompletePending -Message "Done"
                                try {
                                    Remove-ClusterSafely -ClusterName $clusterName
                                } catch {
                                    $clusterErrMsg = $_.Exception.Message
                                    $existenceCheckDelaySec = 2
                                    Write-LogMessage -Type DEBUG -Message "Remove-Cluster threw for `"$clusterName`"; waiting $existenceCheckDelaySec s then re-checking if cluster still exists (vCenter may have removed it despite the error)."
                                    Start-Sleep -Seconds $existenceCheckDelaySec
                                    $clusterStillExists = Get-ClusterByName -Name $clusterName -Server $Script:vCenterName
                                    if (-not $clusterStillExists) {
                                        Write-LogMessage -Type INFO -Message "Cluster `"$clusterName`" was removed (vCenter reported an error but the cluster is no longer present)."
                                    } else {
                                        $Script:RollbackFailed = $true
                                        Write-LogMessage -Type ERROR -Message "Rollback failed: could not remove cluster `"$clusterName`" after vSAN/VDS cleanup: $clusterErrMsg. Remove the cluster manually if desired; script will exit with failure."
                                        throw
                                    }
                                }
                            } else {
                                $Script:RollbackFailed = $true
                                Write-LogMessage -Type WARNING -CompletePending -Message "Partial (see warnings above)"
                                Write-LogMessage -Type ERROR -Message "VDS removal failed during vSAN rollback; could not remove cluster. Remove VMkernel adapters and VDS manually, then remove the cluster. Script will exit with failure."
                                throw [VcfDeploymentException]::new()
                            }
                            Write-LogMessage -Type INFO -Message "Complete rollback finished for edgeSite `"$currentEdgeSite`" (VDS and cluster removed)."
                            $vsanRollbackCompleted = $true
                        } catch [RollbackSkippedException] {
                            Write-LogMessage -Type WARNING -Message "Skipping rollback for edgeSite `"$currentEdgeSite`"; leaving site in current state. Continuing to next site."
                            continue
                        } catch {
                            throw
                        }
                        # Rollback succeeded; log what failed and signal clean failure.
                        if ($vsanRollbackCompleted) {
                            Write-LogMessage -Type ERROR -Message "Deployment failed for edgeSite `"$currentEdgeSite`" (rollback completed). $deploymentFailureMessage"
                            throw [VcfDeploymentException]::new()
                        }
                    } elseif ($storagePolicyType -eq "VMFS") {
                        $rollbackDecision = Invoke-PauseBeforeRollbackIfRequested -ForcePrompt -RollbackContext "deployment failure (edgeSite `"$currentEdgeSite`"); compute rollback" -SingleSite:($clustersToProcess.Count -eq 1)
                        $restoreResult = $null
                        if ($rollbackDecision -eq "DoNotRollback") {
                            Write-LogMessage -Type WARNING -Message "Rollback skipped for edgeSite `"$currentEdgeSite`"; leaving site in current state. Continuing to next site."
                            continue
                        }
                        Write-LogMessage -Type INFO -Message "Running complete rollback for edgeSite `"$currentEdgeSite`" (VMFS: remove VDS, datastore, cluster)."
                        $nicListForRestore = Get-EffectiveNicListForCluster -Cluster $cluster -CommonNicList $inputData.common.nicList
                        if (-not $nicListForRestore -or $nicListForRestore.Count -eq 0) { $nicListForRestore = $inputData.common.nicList }
                        $nicListCountForRestore = if ($nicListForRestore -and $nicListForRestore.Count -eq 4) { 4 } else { 2 }
                        $vdsNamesForCleanup = @($vdsName, "$vdsName-sw1", "$vdsName-sw2")
                        try {
                            Remove-NonVmk0VmkernelInterfacesFromVds -ClusterName $clusterName -VdsNames $vdsNamesForCleanup
                        } catch {
                            Write-LogMessage -Type WARNING -Message "Non-vmk0 VMkernel removal had errors during rollback (non-fatal): $($_.Exception.Message)."
                        }
                        try {
                            $restoreResult = Invoke-ManagementRestoreForCleanupWithTopologyFallback -ClusterName $clusterName -NicListCount $nicListCountForRestore -VdsName $vdsName
                        } catch {
                            Write-LogMessage -Type WARNING -Message "Management restore during rollback failed: $($_.Exception.Message). Remove VDS and cluster manually if needed."
                        }
                        if ($restoreResult -and $restoreResult.RestoreAttempted -and -not $restoreResult.Success) {
                            Write-LogMessage -Type WARNING -Message "Management was not moved to VSS; VDS removal may fail. Move vmk0 off the VDS manually if needed."
                        }
                        # Guard: a supervisor from a prior deployment may still be running. Attempting VDS
                        # removal while supervisor port groups are in use will fail. Check before proceeding.
                        if (Test-SupervisorDeployedOnCluster -ClusterName $clusterName) {
                            $Script:RollbackFailed = $true
                            Write-LogMessage -Type ERROR -Message "Supervisor is active on cluster `"$clusterName`" from a prior deployment. VDS and cluster cannot be removed while the supervisor is running. Deactivate it first with -CleanUp Supervisor, then remove compute with -CleanUp Compute."
                            throw [VcfDeploymentException]::new()
                        }
                        $vdsRemovalSucceeded = $true
                        Write-LogMessage -Type INFO -NoNewline -Message "Removing VDS(es) for cluster `"$clusterName`"... "
                        try { Remove-EdgeClusterDistributedSwitch -ClusterName $clusterName -VdsName $vdsName -SkipPortGroupInUseRestoreFallback } catch { $vdsRemovalSucceeded = $false; Write-LogMessage -Type WARNING -Message "Could not remove VDS `"$vdsName`" during rollback: $($_.Exception.Message)." }
                        try { Remove-EdgeClusterDistributedSwitch -ClusterName $clusterName -VdsName "$vdsName-sw1" -SkipPortGroupInUseRestoreFallback } catch { $vdsRemovalSucceeded = $false }
                        try { Remove-EdgeClusterDistributedSwitch -ClusterName $clusterName -VdsName "$vdsName-sw2" -SkipPortGroupInUseRestoreFallback } catch { $vdsRemovalSucceeded = $false }
                        if ($vdsRemovalSucceeded) {
                            Write-LogMessage -Type INFO -CompletePending -Message "Done"
                            try {
                                Remove-VmfsDatastoreForCluster -ClusterName $clusterName -DatastoreName $datastoreName
                            } catch {
                                Write-LogMessage -Type WARNING -Message "Could not remove VMFS datastore during rollback: $($_.Exception.Message)."
                            }
                            try { Remove-ClusterSafely -ClusterName $clusterName } catch { Write-LogMessage -Type WARNING -Message "Could not remove cluster during rollback: $($_.Exception.Message)." }
                        } else {
                            Write-LogMessage -Type WARNING -CompletePending -Message "Partial (see warnings above)"
                            Write-LogMessage -Type WARNING -Message "VDS removal failed during rollback; skipping VMFS datastore and cluster removal. Move VMkernel adapters and VMs off the VDS port groups, then remove the VDS, datastore, and cluster manually if desired."
                        }
                        Write-LogMessage -Type INFO -Message "Compute rollback completed for edgeSite `"$currentEdgeSite`"."
                    }
                }
                throw [VcfDeploymentException]::new()
            }
        }
        if ($ComputeOnly) {
            Write-LogMessage -Type INFO -Message "ComputeOnly completed. All pre-supervisor steps finished. Exiting without enabling supervisor."
            return
        }
    } finally {
        # Always cleanup vCenter connections on ANY exit (normal, error, or Ctrl+C)
        # This ensures no leaked connections regardless of how the function exits.
        Disconnect-Vcenter -AllServers -Silence

        # Clear ESX credential cache from memory on any exit (normal, error, or interrupt).
        if ($null -ne $esxPasswords) {
            $esxPasswords.Clear()
        }

        # Clear the stored vCenter credential so it does not persist beyond this run.
        $Script:VcenterCredential = $null
    }
}
function ConvertFrom-Yaml {

    <#
    .SYNOPSIS
        Converts YAML content to PowerShell objects using native PowerShell parsing.

    .DESCRIPTION
        The ConvertFrom-Yaml function parses YAML content and converts it into PowerShell hashtables
        and arrays. This is a native PowerShell implementation that doesn't require external dependencies.
        It returns an array containing hashtables representing the parsed YAML structure.

        Key features:
        - Native PowerShell implementation (no external dependencies)
        - Supports nested objects and arrays
        - Handles multi-document YAML (separated by ---)
        - Returns structured PowerShell objects for easy property access
        - Comprehensive error handling with detailed error messages

    .PARAMETER YamlContent
        The YAML content as a string to be parsed. This can be single or multi-document YAML.

    .EXAMPLE
        $yaml = @"
        name: John Doe
        age: 30
        address:
          street: 123 Main St
          city: New York
        "@
        $result = ConvertFrom-Yaml -YamlContent $yaml
        $result[0].name  # Returns: John Doe

    .OUTPUTS
        System.Array
        Returns an array containing hashtables representing the parsed YAML structure.

    .NOTES
        This function is designed to work with the internal ConvertFrom-YamlInternal function
        which handles the actual parsing logic. The function uses PowerShell's pipeline
        capabilities for efficient processing of YAML content.

    #>

    [OutputType([System.Object[]])]
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)] [AllowEmptyString()] [string]$YamlContent
    )

    begin {
        $yamlLines = [System.Collections.Generic.List[String]]::new()
    }

    process {
        # Split the YAML content into individual lines for processing.

        # This handles both Windows (\r\n) and Unix (\n) line endings
        # Split on \n and then trim \r from each line to handle cross-platform line endings.

        $lines = $YamlContent -split "`n"

        foreach ($line in $lines) {
            $yamlLines.Add($line.TrimEnd("`r"))
        }
    }

    end {
        try {
            # Filter out null and empty lines before parsing.
            # This prevents validation errors when passing to ConvertFrom-YamlInternal.
            $validLines = @()
            foreach ($line in $yamlLines) {
                if ($null -ne $line -and $line.Trim() -ne "") {
                    $validLines += $line
                }
            }

            # If no valid lines were found, return empty array instead of attempting to parse.
            if ($validLines.Count -eq 0) {
                Write-LogMessage -Type DEBUG -Message "YAML content contains no valid lines. Returning empty array."
                return @()
            }

            # Call the internal YAML parsing function with collected lines.
            # This returns an array containing hashtables representing the YAML structure.
            return ConvertFrom-YamlInternal -YamlLines $validLines
        } catch {
            # Provide detailed error information for troubleshooting YAML parsing issues.

            Write-LogMessage -Type ERROR -Message "Failed to parse YAML: $($_.Exception.Message)"
            return Write-ErrorAndReturn -ErrorMessage "YAML parsing failed: $($_.Exception.Message)" -ErrorCode "ERR_YAML_PARSE"
        }
    }
}
function ConvertTo-Yaml {

    <#
    .SYNOPSIS
        Converts a PowerShell object to YAML format.

    .DESCRIPTION
        The ConvertTo-Yaml function converts PowerShell objects (hashtables, arrays, PSCustomObjects)
        into YAML format. It supports nested objects, arrays, and various data types including
        strings, numbers, booleans, and null values.

    .PARAMETER InputObject
        The PowerShell object to be converted to YAML format. This can be a hashtable,
        PSCustomObject, array, or any other PowerShell object.

    .PARAMETER IndentSize
        The number of spaces to use for indentation in the YAML output. Default is 2.

    .EXAMPLE
        $object = @{
            name = "John Doe"
            age = 30
            skills = @("PowerShell", "Python")
            address = @{
                street = "123 Main St"
                city = "New York"
            }
        }
        ConvertTo-Yaml -InputObject $object

    .EXAMPLE
        $array = @("item1", "item2", "item3")
        ConvertTo-Yaml -InputObject $array -IndentSize 4

    .OUTPUTS
        System.String
        Returns the YAML representation of the input object.

    .NOTES
        Author: PowerShell YAML Parser
        Version: 1.0.0

    #>

    [CmdletBinding()]
    Param (
        [Parameter()] [ValidateRange(1, [int]::MaxValue)] [int]$IndentSize = 2,
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)] [object]$InputObject
    )

    begin {
        Write-LogMessage -Type DEBUG -Message "Entered ConvertTo-Yaml function..."

        $yamlContent = [System.Collections.Generic.List[String]]::new()
    }

    process {
        $lines = ConvertTo-YamlInternal -InputObject $InputObject -IndentSize $IndentSize -CurrentIndent 0
        foreach ($line in $lines) {
            $yamlContent.Add($line)
        }
    }

    end {
        return $yamlContent -join "`n"
    }
}
function ConvertFrom-YamlInternal {

    <#
    .SYNOPSIS
        Internal function that parses YAML lines into a PowerShell array.

    .DESCRIPTION
        The ConvertFrom-YamlInternal function is an internal helper function that processes
        an array of YAML lines and converts them into a PowerShell array containing a hashtable. It handles
        nested objects, arrays, and various YAML structures using a stack-based approach
        to maintain proper indentation levels.

    .PARAMETER YamlLines
        An array of strings representing the YAML content, where each string is a line
        from the YAML document.

    .EXAMPLE
        $yamlLines = @(
            "name: John Doe",
            "age: 30",
            "address:",
            "  street: 123 Main St",
            "  city: New York"
        )
        $result = ConvertFrom-YamlInternal -YamlLines $yamlLines

    .OUTPUTS
        System.Array
        Returns an array containing a hashtable representing the parsed YAML structure.

    .NOTES
        This is an internal function used by ConvertFrom-Yaml. It should not be called
        directly in most scenarios.
    #>

    Param (
        [ValidateNotNullOrEmpty()] [string[]]$YamlLines
    )

    $result = @{}
    $stack = [System.Collections.Generic.List[Hashtable]]::new()
    $currentObject = $result
    $lineNumber = 0

    foreach ($line in $YamlLines) {
        $lineNumber++
        $trimmedLine = $line.TrimEnd()

        # Skip empty lines and comments.

        if ([string]::IsNullOrWhiteSpace($trimmedLine) -or $trimmedLine.StartsWith('#')) {
            continue
        }

        # Calculate indentation level
        $currentIndentLevel = ($line.Length - $line.TrimStart().Length) / 2

        # Remove processed items from stack that are at same or higher level.

        while ($stack.Count -gt 0) {
            $lastItem = $stack[$stack.Count - 1]
            if ($lastItem.IndentLevel -ge $currentIndentLevel) {
                $stack.RemoveAt($stack.Count - 1)
            } else {
                break
            }
        }

        # Parse the line
        $parsedItem = Get-YamlLine -Line $trimmedLine

        if ($null -ne $parsedItem) {
            # Set the current object based on stack.

            if ($stack.Count -eq 0) {
                $currentObject = $result
            } else {
                $currentObject = $stack[$stack.Count - 1].Object
            }

            # Handle different types of YAML structures.

            if ($parsedItem.Type -eq "KeyValue") {
                Add-ObjectProperty -Object $currentObject -Path $parsedItem.Key -Value $parsedItem.Value
            }
            elseif ($parsedItem.Type -eq "ArrayItem") {
                if (-not $currentObject.ContainsKey($parsedItem.Key)) {
                    $currentObject[$parsedItem.Key] = [System.Collections.Generic.List[Object]]::new()
                }
                $currentObject[$parsedItem.Key].Add($parsedItem.Value)
            }
            elseif ($parsedItem.Type -eq "ObjectStart") {
                $newObject = @{}
                Add-ObjectProperty -Object $currentObject -Path $parsedItem.Key -Value $newObject
                $stack.Add(@{
                    Object = $newObject
                    IndentLevel = $currentIndentLevel
                })
            }
            elseif ($parsedItem.Type -eq "ArrayStart") {
                $newArray = [System.Collections.Generic.List[Object]]::new()
                Add-ObjectProperty -Object $currentObject -Path $parsedItem.Key -Value $newArray
                $stack.Add(@{
                    Object = $newArray
                    IndentLevel = $currentIndentLevel
                    IsArray = $true
                })
            }
        }
    }

    # Return the hashtable wrapped in an array.
    $array = New-Object System.Object[] 1
    $array[0] = $result
    return $array
}
function Get-YamlLine {

    <#
    .SYNOPSIS
        Parses a single YAML line and returns a structured object representing its content.

    .DESCRIPTION
        The Get-YamlLine function analyzes a single YAML line and determines its type
        (key-value pair, array item, object start, or array start). It returns a hashtable
        with type information and parsed values that can be used by the YAML parser.

    .PARAMETER Line
        The YAML line to be parsed. Should be trimmed of leading/trailing whitespace.

    .EXAMPLE
        $result = Get-YamlLine -Line "name: John Doe"
        # Returns: @{ Type = "KeyValue"; Key = "name"; Value = "John Doe" }

    .EXAMPLE
        $result = Get-YamlLine -Line "- item1"
        # Returns: @{ Type = "ArrayItem"; Key = ""; Value = "item1" }

    .EXAMPLE
        $result = Get-YamlLine -Line "address:"
        # Returns: @{ Type = "ObjectStart"; Key = "address"; Value = $null }

    .OUTPUTS
        System.Collections.Hashtable
        Returns a hashtable with the following possible properties:
        - Type: "KeyValue", "ArrayItem", "ObjectStart", or "ArrayStart"
        - Key: The key name (empty for array items)
        - Value: The parsed value (null for object/array starts)

    .NOTES
        This is an internal function used by ConvertFrom-YamlInternal. It should not be
        called directly in most scenarios.
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string]$Line
    )

    # Handle array items (starting with -)
    if ($Line.StartsWith('- ')) {
        $value = $Line.Substring(2).Trim()
        return @{
            Type = "ArrayItem"
            Key = ""
            Value = ConvertFrom-YamlValue -Value $value
        }
    }

    # Handle key-value pairs.
    if ($Line.Contains(':')) {
        $colonIndex = $Line.IndexOf(':')
        $key = $Line.Substring(0, $colonIndex).Trim()
        $value = $Line.Substring($colonIndex + 1).Trim()

        # Check if this is an object or array start.

        if ([string]::IsNullOrWhiteSpace($value)) {
            # Check next non-empty line to determine if it's an object or array.

            return @{
                Type = "ObjectStart"
                Key = $key
                Value = $null
            }
        }
        elseif ($value -eq '[]') {
            return @{
                Type = "ArrayStart"
                Key = $key
                Value = $null
            }
        }
        else {
            return @{
                Type = "KeyValue"
                Key = $key
                Value = ConvertFrom-YamlValue -Value $value
            }
        }
    }

    return $null
}
function ConvertFrom-YamlValue {

    <#
    .SYNOPSIS
        Converts a YAML value string to its appropriate PowerShell data type.

    .DESCRIPTION
        The ConvertFrom-YamlValue function takes a YAML value string and converts it to
        the appropriate PowerShell data type. It handles strings, numbers, booleans, null
        values, and removes quotes when appropriate.

    .PARAMETER Value
        The YAML value string to be converted to a PowerShell object.

    .EXAMPLE
        $result = ConvertFrom-YamlValue -Value "John Doe"
        # Returns: "John Doe" (string)

    .EXAMPLE
        $result = ConvertFrom-YamlValue -Value "30"
        # Returns: 30 (integer)

    .EXAMPLE
        $result = ConvertFrom-YamlValue -Value "true"
        # Returns: $true (boolean)

    .EXAMPLE
        $result = ConvertFrom-YamlValue -Value "null"
        # Returns: $null

    .EXAMPLE
        $result = ConvertFrom-YamlValue -Value '"quoted string"'
        # Returns: "quoted string" (unquoted string)

    .OUTPUTS
        System.Object
        Returns the converted value as the appropriate PowerShell data type:
        - String (unquoted)
        - Integer (for numeric strings)
        - Double (for decimal strings)
        - Boolean (for true/false values)
        - Null (for null/empty values)

    .NOTES
        This is an internal function used by Get-YamlLine. It should not be called
        directly in most scenarios.
    #>

    Param (
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    # Remove quotes if present.
    if (($Value.StartsWith('"') -and $Value.EndsWith('"')) -or
        ($Value.StartsWith("'") -and $Value.EndsWith("'"))) {
        return $Value.Substring(1, $Value.Length - 2)
    }

    # Try to parse as number (first match wins).
    switch -Regex ($Value) {
        '^-?\d+$' { return [int]$Value }
        '^-?\d+\.\d+$' { return [double]$Value }
    }

    # Try to parse as boolean.
    if ($Value -eq 'true' -or $Value -eq 'True' -or $Value -eq 'TRUE') {
        return $true
    }
    elseif ($Value -eq 'false' -or $Value -eq 'False' -or $Value -eq 'FALSE') {
        return $false
    }

    # Try to parse as null.
    if ($Value -eq 'null' -or $Value -eq 'Null' -or $Value -eq 'NULL' -or $Value -eq '~') {
        return $null
    }

    # Return as string.
    return $Value
}
function Add-ObjectProperty {

    <#
    .SYNOPSIS
        Adds a property to a hashtable object with the specified key and value.

    .DESCRIPTION
        The Add-ObjectProperty function adds a property to a hashtable object using the
        specified key (path) and value. This is a simple helper function used internally
        by the YAML parser to set properties on objects during parsing.

    .PARAMETER Object
        The hashtable object to which the property will be added.

    .PARAMETER Path
        The key name for the property to be added to the object.

    .PARAMETER Value
        The value to be assigned to the property.

    .EXAMPLE
        $obj = @{}
        Add-ObjectProperty -Object $obj -Path "name" -Value "John Doe"
        # $obj now contains: @{ name = "John Doe" }

    .EXAMPLE
        $obj = @{}
        Add-ObjectProperty -Object $obj -Path "age" -Value 30
        # $obj now contains: @{ age = 30 }

    .EXAMPLE
        $obj = @{}
        Add-ObjectProperty -Object $obj -Path "address" -Value @{ street = "123 Main St" }
        # $obj now contains: @{ address = @{ street = "123 Main St" } }

    .OUTPUTS
        None
        This function modifies the input object in place and does not return a value.

    .NOTES
        This is an internal function used by ConvertFrom-YamlInternal. It should not be
        called directly in most scenarios.
    #>

    Param (
        [hashtable]$Object,
        [string]$Path,
        [object]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    $Object[$Path] = $Value
}
function ConvertTo-YamlInternal {

    <#
    .SYNOPSIS
        Internal helper function that recursively converts PowerShell objects to YAML format with proper indentation.

    .DESCRIPTION
        The ConvertTo-YamlInternal function is an internal helper that performs recursive conversion of PowerShell
        objects (hashtables, PSCustomObjects, arrays, and primitive types) into properly formatted YAML lines
        with appropriate indentation. This function is the core engine behind the ConvertTo-Yaml cmdlet and
        handles the complex logic of traversing nested object structures while maintaining proper YAML formatting.

        The function processes different object types as follows:
        - Hashtables and PSCustomObjects: Converts properties to key-value pairs with nested indentation
        - Arrays and ArrayLists: Converts items to YAML list format with dash prefixes
        - Nested objects: Recursively processes with increased indentation levels
        - Primitive values: Delegates to ConvertTo-YamlValue for proper type conversion

        The function maintains proper YAML indentation by calculating spaces based on the current nesting level
        and the specified indent size, ensuring the output conforms to YAML specification standards.

    .PARAMETER InputObject
        The PowerShell object to be converted to YAML format. This can be any type of object including:
        - Hashtables containing key-value pairs
        - PSCustomObjects with properties
        - Arrays or ArrayLists containing multiple items
        - Primitive types (strings, numbers, booleans)
        - Nested combinations of the above types

    .PARAMETER IndentSize
        The number of spaces to use for each level of indentation in the YAML output.
        This parameter controls the visual formatting and nesting structure of the generated YAML.
        Common values are 2 or 4 spaces per indentation level to match YAML conventions.

    .PARAMETER CurrentIndent
        The current indentation level for the object being processed. This parameter is used
        internally during recursive calls to maintain proper nesting depth. The actual number
        of spaces used for indentation is calculated as (CurrentIndent * IndentSize).
        This parameter starts at 0 for root-level objects and increments for each nesting level.

    .EXAMPLE
        # This function is typically called internally by ConvertTo-Yaml.

        $hashtable = @{
            name = "John Doe"
            age = 30
            skills = @("PowerShell", "Python")
            address = @{
                street = "123 Main St"
                city = "New York"
            }
        }
        $yamlLines = ConvertTo-YamlInternal -InputObject $hashtable -IndentSize 2 -CurrentIndent 0

        This example would produce YAML lines with proper indentation:
        name: John Doe
        age: 30
        skills:
          - PowerShell
          - Python
        address:
          street: 123 Main St
          city: New York

    .EXAMPLE
        # Processing an array at indentation level 1.

        $array = @("item1", "item2", "item3")
        $yamlLines = ConvertTo-YamlInternal -InputObject $array -IndentSize 2 -CurrentIndent 1

        This would produce:
          - item1
          - item2
          - item3

    .OUTPUTS
        System.Collections.Generic.List[String]
        Returns a List[String] where each string represents a line of YAML output
        with appropriate indentation. The caller can join these lines with newline characters to
        create the final YAML document.

    .NOTES
        - This is an internal function used by ConvertTo-Yaml and should not be called directly in most scenarios
        - The function uses recursive calls to handle nested object structures
        - Proper YAML formatting is maintained through careful indentation management
        - The function delegates primitive value conversion to ConvertTo-YamlValue for consistency
        - The function handles both hashtables and PSCustomObjects uniformly through PSObject.Properties

        Author: PowerShell YAML Parser
        Version: 1.0.0
        Dependencies: ConvertTo-YamlValue function for primitive type conversion

    #>

    Param (
        [int]$CurrentIndent,
        [int]$IndentSize,
        [object]$InputObject
    )

    Write-LogMessage -Type DEBUG -Message "Entered ConvertTo-YamlInternal function..."

    $yamlLines = [System.Collections.Generic.List[String]]::new()
    $indent = " " * ($CurrentIndent * $IndentSize)

    if ($InputObject -is [hashtable] -or $InputObject -is [PSCustomObject]) {
        foreach ($property in $InputObject.PSObject.Properties) {
            $key = $property.Name
            $value = $property.Value

            if ($value -is [array] -or $value -is [System.Collections.IList]) {
                $yamlLines.Add("$indent$key`:")
                foreach ($item in $value) {
                    $yamlLines.Add("$indent  - $(ConvertTo-YamlValue -Value $item -IndentSize $IndentSize -CurrentIndent $CurrentIndent + 1)")
                }
            }
            elseif ($value -is [hashtable] -or $value -is [PSCustomObject]) {
                $yamlLines.Add("$indent$key`:")
                $subLines = ConvertTo-YamlInternal -InputObject $value -IndentSize $IndentSize -CurrentIndent $CurrentIndent + 1
                foreach ($line in $subLines) {
                    $yamlLines.Add($line)
                }
            }
            else {
                $yamlLines.Add("$indent$key`: $(ConvertTo-YamlValue -Value $value -IndentSize $IndentSize -CurrentIndent $CurrentIndent)")
            }
        }
    }
    elseif ($InputObject -is [array] -or $InputObject -is [System.Collections.IList]) {
        foreach ($item in $InputObject) {
            $yamlLines.Add("$indent- $(ConvertTo-YamlValue -Value $item -IndentSize $IndentSize -CurrentIndent $CurrentIndent)")
        }
    }
    else {
        $yamlLines.Add("$indent$(ConvertTo-YamlValue -Value $InputObject -IndentSize $IndentSize -CurrentIndent $CurrentIndent)")
    }

    return $yamlLines
}
function ConvertTo-YamlValue {

    <#
    .SYNOPSIS
        Converts a PowerShell object to its YAML string representation.

    .DESCRIPTION
        The ConvertTo-YamlValue function converts a PowerShell object to its appropriate
        YAML string representation. It handles various data types including strings,
        numbers, booleans, null values, hashtables, arrays, and complex objects.

    .PARAMETER Value
        The PowerShell object to be converted to YAML format.

    .PARAMETER IndentSize
        The number of spaces to use for indentation in nested structures.

    .PARAMETER CurrentIndent
        The current indentation level for proper formatting.

    .EXAMPLE
        $result = ConvertTo-YamlValue -Value "Hello World" -IndentSize 2 -CurrentIndent 0
        # Returns: "Hello World"

    .EXAMPLE
        $result = ConvertTo-YamlValue -Value 42 -IndentSize 2 -CurrentIndent 0
        # Returns: "42"

    .EXAMPLE
        $result = ConvertTo-YamlValue -Value $true -IndentSize 2 -CurrentIndent 0
        # Returns: "true"

    .EXAMPLE
        $result = ConvertTo-YamlValue -Value $null -IndentSize 2 -CurrentIndent 0
        # Returns: "null"

    .EXAMPLE
        $result = ConvertTo-YamlValue -Value @("item1", "item2") -IndentSize 2 -CurrentIndent 0
        # Returns: Multi-line YAML array representation.


    .OUTPUTS
        System.String
        Returns the YAML string representation of the input object.

    .NOTES
        This is an internal function used by ConvertTo-YamlInternal. It should not be
        called directly in most scenarios.

    #>

    Param (
        [int]$CurrentIndent,
        [int]$IndentSize,
        [object]$Value
    )

    Write-LogMessage -Type DEBUG -Message "Entered ConvertTo-YamlValue function..."

    if ($null -eq $Value) {
        return "null"
    }
    elseif ($Value -is [bool]) {
        return $Value.ToString().ToLower()
    }
    elseif ($Value -is [string]) {
        # Escape special characters and add quotes if necessary.

        if ($Value.Contains(':') -or $Value.Contains('"') -or $Value.Contains("'") -or
            $Value.StartsWith(' ') -or $Value.EndsWith(' ') -or
            $Value -match '^[0-9]' -or $Value -match '^(true|false|null)$') {
            return "`"$($Value.Replace('"', '\"'))`""
        }
        return $Value
    }
    elseif ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) {
        return $Value.ToString()
    }
    elseif ($Value -is [hashtable] -or $Value -is [PSCustomObject]) {
        $subYaml = ConvertTo-YamlInternal -InputObject $Value -IndentSize $IndentSize -CurrentIndent $CurrentIndent + 1
        return "`n$subYaml"
    }
    elseif ($Value -is [array] -or $Value -is [System.Collections.IList]) {
        $arrayItems = [System.Collections.Generic.List[String]]::new()
        foreach ($item in $Value) {
            $itemValue = ConvertTo-YamlValue -Value $item -IndentSize $IndentSize -CurrentIndent $CurrentIndent
            $arrayItems.Add($itemValue)
        }
        return "`n$($arrayItems -join "`n")"
    }
    else {
        return $Value.ToString()
    }
}
function Test-EsxHostUniqueness {

    <#
        .SYNOPSIS
        Validates that no ESX host (FQDN or IP) appears in more than one edge site in infrastructure.json.

        .DESCRIPTION
        Iterates all clusters[].esxHosts entries and checks for duplicate values across clusters.
        Each physical ESX host must belong to exactly one edge site; sharing a host between sites
        indicates a misconfiguration that would cause vCenter and vSAN operations to fail.

        .PARAMETER InputData
        The parsed infrastructure.json data object containing cluster configurations.

        .EXAMPLE
        $inputData = ConvertFrom-JsonSafely -JsonFilePath "infrastructure.json"
        $result = Test-EsxHostUniqueness -InputData $inputData
        if (-not $result.IsValid) {
            Write-Error "ESX host uniqueness validation failed: $($result.ErrorMessage)"
        }

        .OUTPUTS
        PSCustomObject with properties:
        - IsValid      : Boolean — $true when all ESX hosts are unique across sites.
        - ErrorMessage : String — details about any duplicate hosts found.
        - DuplicateHosts : Array of duplicate ESX host names.

        .NOTES
        Private helper. Called from Initialize-VcfEdgeAtScale before deployment begins.
        Comparison is case-insensitive to catch duplicates that differ only in case.
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Object]$InputData
    )

    $validationResult = [PSCustomObject]@{
        IsValid        = $true
        ErrorMessage   = $null
        DuplicateHosts = @()
    }

    Write-LogMessage -Type DEBUG -Message "Entered Test-EsxHostUniqueness function..."

    try {
        $hostSiteMap = @{}
        $duplicateHosts = [System.Collections.Generic.List[String]]::new()

        foreach ($cluster in @($InputData.clusters)) {
            if (-not $cluster -or -not $cluster.esxHosts) {
                continue
            }
            $site = $cluster.edgeSite
            foreach ($esxHostName in @($cluster.esxHosts)) {
                if ([String]::IsNullOrWhiteSpace([String]$esxHostName)) {
                    continue
                }
                $hostKey = ([String]$esxHostName).ToLowerInvariant()
                if ($hostSiteMap.ContainsKey($hostKey)) {
                    $firstSite = $hostSiteMap[$hostKey]
                    if (-not $duplicateHosts.Contains($hostKey)) {
                        $duplicateHosts.Add($hostKey)
                    }
                    Write-LogMessage -Type ERROR -Message "Duplicate ESX host found: '$esxHostName' appears in both edgeSite '$firstSite' and '$site'. Each ESX host must be unique across all edge sites."
                } else {
                    $hostSiteMap[$hostKey] = $site
                }
            }
        }

        if ($duplicateHosts.Count -gt 0) {
            $validationResult.IsValid = $false
            $validationResult.DuplicateHosts = $duplicateHosts.ToArray()
            $validationResult.ErrorMessage = "Found $($duplicateHosts.Count) duplicate ESX host(s): $($duplicateHosts -join ', '). Each ESX host must appear in exactly one edge site."
            Write-LogMessage -Type ERROR -SuppressOutputToScreen -Message "ESX host uniqueness validation failed: $($validationResult.ErrorMessage)"
        } else {
            Write-LogMessage -Type DEBUG -Message "ESX host uniqueness validation passed."
        }
    } catch {
        $validationResult.IsValid = $false
        $validationResult.ErrorMessage = "Error during ESX host uniqueness validation: $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -Message $validationResult.ErrorMessage
    }

    return $validationResult
}
function Get-NetworkSegmentDetailsFromInputData {
    <#
        .SYNOPSIS
        Collects network segment details (Name, VlanId, EdgeSite) from infrastructure.json input data.

        .DESCRIPTION
        Iterates over InputData.clusters (optionally filtered by EdgeSitesArray), reads networking.networkSegments,
        and returns an array of PSCustomObject with Name, VlanId, EdgeSite. Used by Test-NetworkSegmentNameUniqueness.
        Logs each segment at INFO with SuppressOutputToScreen.

        .PARAMETER InputData
        Parsed infrastructure JSON object (must have clusters array).

        .PARAMETER EdgeSitesArray
        Optional array of edge site names. When non-empty, only clusters whose edgeSite is in this array are included.

        .OUTPUTS
        PSCustomObject[]. Array of objects with Name, VlanId, EdgeSite.
    #>
    Param (
        [Parameter(Mandatory = $true)] [Object]$InputData,
        [Parameter(Mandatory = $false)] [Array]$EdgeSitesArray = @()
    )

    $networkSegmentDetails = @()
    if (-not $InputData.clusters) {
        return $networkSegmentDetails
    }

    $clustersToValidate = if ($EdgeSitesArray -and $EdgeSitesArray.Count -gt 0) {
        $InputData.clusters | Where-Object { $_.edgeSite -in $EdgeSitesArray }
    } else {
        $InputData.clusters
    }

    foreach ($cluster in $clustersToValidate) {
        $currentEdgeSite = $cluster.edgeSite
        if ($cluster.networking -and $cluster.networking.networkSegments) {
            foreach ($networkSegment in $cluster.networking.networkSegments) {
                if ($networkSegment.name) {
                    $networkSegmentDetails += [PSCustomObject]@{
                        Name = $networkSegment.name
                        VlanId = $networkSegment.vlanId
                        EdgeSite = $currentEdgeSite
                    }
                    Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Found network segment: '$($networkSegment.name)' (VLAN: $($networkSegment.vlanId), EdgeSite: $currentEdgeSite)"
                }
            }
        }
    }

    return $networkSegmentDetails
}
function Get-DuplicateNetworkSegmentGroups {
    <#
        .SYNOPSIS
        Returns Group-Object groups for network segment names that appear more than once.

        .DESCRIPTION
        Given an array of network segment details (Name, VlanId, EdgeSite), groups by Name
        and returns only groups where Count -gt 1. Used by Test-NetworkSegmentNameUniqueness
        to detect duplicate segment names and report them.

        .PARAMETER NetworkSegmentDetails
        Array of PSCustomObject with at least Name (and optionally VlanId, EdgeSite).

        .OUTPUTS
        Microsoft.PowerShell.Commands.GroupInfo[]
        Zero or more groups, each representing a duplicate name.
    #>
    [OutputType([System.Object[]])]
    Param (
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [AllowNull()] [Array]$NetworkSegmentDetails
    )
    if (-not $NetworkSegmentDetails -or $NetworkSegmentDetails.Count -eq 0) {
        return @()
    }
    $groupedNames = $NetworkSegmentDetails | Group-Object -Property Name
    return $groupedNames | Where-Object { $_.Count -gt 1 }
}
function Test-NetworkSegmentNameUniqueness {

    <#
        .SYNOPSIS
        Validates that all network segment names are unique within infrastructure.json.

        .DESCRIPTION
        This function performs validation to ensure that all network segment names defined in
        infrastructure.json (clusters[].networking.networkSegments[].name) are unique across
        all clusters. The function checks for duplicates within the network segment names
        and provides detailed error reporting if any duplicates are found, including
        the VLAN IDs associated with conflicting network segments.

        .PARAMETER InputData
        The parsed infrastructure.json data object containing network segment configurations.

        .EXAMPLE
        $inputData = ConvertFrom-JsonSafely -JsonFilePath "infrastructure.json"
        $result = Test-NetworkSegmentNameUniqueness -InputData $inputData
        if (-not $result.IsValid) {
            Write-Error "Network segment name validation failed: $($result.ErrorMessage)"
        }

        .OUTPUTS
        PSCustomObject
        Returns an object with the following properties:
        - IsValid: Boolean indicating if all network segment names are unique
        - ErrorMessage: String containing details about any validation failures
        - DuplicateNames: Array of duplicate network segment names found
        - AllNetworkSegmentNames: Array of all network segment names collected for validation

        .NOTES
        This function is case-sensitive for network segment name comparisons. Network segment names must be
        exactly identical to be considered duplicates. When duplicates are found, the function
        also reports the VLAN IDs associated with the conflicting network segments. The function logs
        validation progress and results using the Write-LogMessage function.
    #>

    Param (
        [Parameter(Mandatory = $false)] [String]$EdgeSite,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Object]$InputData
    )

    Write-LogMessage -Type DEBUG -Message "Entered Test-NetworkSegmentNameUniqueness function..."

    $edgeSitesArray = @()
    if ($EdgeSite) {
        $edgeSitesArray = Get-EdgeSitesFromParameter -EdgeSite $EdgeSite -InputData $InputData
        Write-LogMessage -Type DEBUG -Message "Validating network segment name uniqueness for edgeSite(s) `"$($edgeSitesArray -join '", "')`" only..."
    } else {
        Write-LogMessage -Type DEBUG -Message "Starting network segment name uniqueness validation across all clusters."
    }

    $duplicateNames = @()
    $validationResult = @{
        IsValid = $true
        ErrorMessage = ""
        DuplicateNames = @()
        AllNetworkSegmentNames = @()
    }

    try {
        $networkSegmentDetails = Get-NetworkSegmentDetailsFromInputData -InputData $InputData -EdgeSitesArray $edgeSitesArray

        # Check for duplicates within network segment names across all clusters.
        $duplicateGroups = Get-DuplicateNetworkSegmentGroups -NetworkSegmentDetails $networkSegmentDetails
        foreach ($group in $duplicateGroups) {
            $duplicateNames += $group.Name
            $edgeSites = $group.Group | ForEach-Object { $_.EdgeSite }
            $vlanIds = $group.Group | ForEach-Object { $_.VlanId }
            $edgeSiteList = $edgeSites -join ', '
            $vlanIdList = $vlanIds -join ', '
            Write-LogMessage -Type ERROR -Message "Duplicate network segment name found: '$($group.Name)' (appears $($group.Count) times) in edgeSites: $edgeSiteList with VLAN IDs: $vlanIdList."
        }

        # Set validation result
        if ($duplicateNames.Count -gt 0) {
            $validationResult.IsValid = $false
            $validationResult.ErrorMessage = "Found $($duplicateNames.Count) duplicate network segment name(s): $($duplicateNames -join ', ')"
            $validationResult.DuplicateNames = $duplicateNames
            Write-LogMessage -Type ERROR -SuppressOutputToScreen -Message "Network segment name uniqueness validation failed: $($validationResult.ErrorMessage)"
        } else {
            Write-LogMessage -Type DEBUG -Message "Network segment name uniqueness validation passed. All $($networkSegmentDetails.Count) network segment names are unique."
        }

        $validationResult.AllNetworkSegmentNames = $networkSegmentDetails | ForEach-Object { $_.Name }

    } catch {
        $validationResult.IsValid = $false
        $validationResult.ErrorMessage = "Error during network segment name validation: $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -Message $validationResult.ErrorMessage
    }

    return $validationResult
}
function Invoke-HarborEnvVarPreflight {

    <#
        .SYNOPSIS
        Resolves all $env: Harbor secret references before deployment begins.

        .DESCRIPTION
        Scans every cluster in InputData where Harbor is not disabled and calls
        Resolve-HarborSecretValue for each secret field that carries a "$env:" reference.
        Any environment variable that is not currently set triggers an interactive masked
        prompt, storing the entered value in the process environment so it is available
        for the rest of the run. This ensures the user is prompted once at start-up rather
        than mid-deployment when a partially-completed deployment would require rollback.

        Fields with format constraints (e.g. secretKey must be exactly 16 characters) have
        those constraints enforced at prompt time via RequiredLength. If an environment
        variable is already set but the value does not satisfy the constraint, the user is
        prompted to supply a corrected value rather than failing later during deployment.

        Only fields explicitly set to a "$env:<VARNAME>" value in harborConfiguration are
        evaluated. Plain-text values and omitted fields are skipped entirely.

        .PARAMETER EdgeSite
        When specified, only the cluster matching this edgeSite value is checked.

        .PARAMETER InputData
        Parsed infrastructure JSON data object (output of ConvertFrom-JsonSafely).

        .EXAMPLE
        Invoke-HarborEnvVarPreflight -InputData $inputData

        Resolves all Harbor $env: secrets across every enabled cluster, prompting for any that are unset.

        .EXAMPLE
        Invoke-HarborEnvVarPreflight -InputData $inputData -EdgeSite "OSA"

        Resolves Harbor $env: secrets for the OSA cluster only.

        .NOTES
        Start-VcfEdgeAtScale does not call this function when -ComputeOnly is set, so a cluster may keep
        harborConfiguration entries with $env: references for a later supervisor or Harbor deployment without
        defining those environment variables during compute-only preparation.
    #>

    Param (
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$EdgeSite,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSCustomObject]$InputData
    )

    $secretFields = @("coreSecret", "databasePassword", "harborAdminPassword", "jobserviceSecret", "registrySecret", "secretKey")

    # Length constraints enforced at prompt time; user is re-prompted rather than failing later.
    $secretLengthConstraints = @{ "secretKey" = 16 }

    foreach ($cluster in $InputData.clusters) {
        if (-not [String]::IsNullOrWhiteSpace($EdgeSite) -and $cluster.edgeSite -ne $EdgeSite) {
            continue
        }
        if (Get-EffectiveSupervisorServiceFlag -Cluster $cluster -CommonData $InputData.common -FlagName "disableHarbor") {
            continue
        }
        $harborConfig = $cluster.harborConfiguration
        if (-not $harborConfig) {
            continue
        }
        foreach ($fieldName in $secretFields) {
            $fieldValue = $harborConfig.$fieldName
            if ([String]::IsNullOrWhiteSpace($fieldValue) -or $fieldValue -notmatch '^\$env:') {
                continue
            }
            $resolveParams = @{
                FieldName = $fieldName
                Value     = $fieldValue
            }
            if ($secretLengthConstraints.ContainsKey($fieldName)) {
                $resolveParams.RequiredLength = $secretLengthConstraints[$fieldName]
            }
            $null = Resolve-HarborSecretValue @resolveParams
        }
    }
}
function Get-VcfEdgeAtScaleConfigUiVersion {

    <#
        .SYNOPSIS
        Returns the UI_VERSION string embedded in a veas-json-generator.py file.

        .DESCRIPTION
        Reads the first line matching the pattern UI_VERSION = "..." in the specified file and returns
        the quoted version value. Returns $null when the file is unreadable or contains no matching line.

        .PARAMETER FilePath
        Full path to the veas-json-generator.py file to inspect.

        .OUTPUTS
        [String] Version string (e.g. "1.0.3.1004"), or $null if not found.

        .EXAMPLE
        Get-VcfEdgeAtScaleConfigUiVersion -FilePath "C:\Users\Admin\VCFEdgeAtScale\Tools\veas-json-generator.py"

        Returns the UI_VERSION value from the specified file.

        .NOTES
        Private helper. Used by Sync-VcfEdgeAtScaleConfigUiTool to compare source and destination
        Python tool versions before deciding whether to copy.
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$FilePath
    )

    try {
        $lineMatch = Select-String -LiteralPath $FilePath -Pattern 'UI_VERSION\s*=\s*"([^"]+)"' -ErrorAction Stop
        if ($null -ne $lineMatch) {
            return $lineMatch.Matches[0].Groups[1].Value
        }
    } catch {
        Write-LogMessage -Type DEBUG -Message "Get-VcfEdgeAtScaleConfigUiVersion: could not read '${FilePath}': $($_.Exception.Message)"
    }
    return $null
}
function Sync-VcfEdgeAtScaleConfigUiTool {

    <#
        .SYNOPSIS
        Copies the config UI tool from the newly installed module to the deployment root Tools directory when the versions differ.

        .DESCRIPTION
        After a module upgrade, locates the newest installed VcfEdgeAtScale module via Get-Module -ListAvailable,
        reads the UI_VERSION from its veas-json-generator.py, and compares it to the UI_VERSION in the user's
        deployment root Tools directory. If they differ the new file is copied automatically with no user prompt.

        The sync is silently skipped when:
        - UserBaseDirectory is not set or does not exist.
        - The tool is absent from the deployment root (the user has not run -Initialize yet).
        - The source file is missing from the newly installed module.

        .PARAMETER UserBaseDirectory
        Path to the operator's deployment base directory (typically $env:VcfEdgeAtScaleRootDirectory).
        Pass an empty string or omit to skip the sync.

        .EXAMPLE
        Sync-VcfEdgeAtScaleConfigUiTool -UserBaseDirectory $env:VcfEdgeAtScaleRootDirectory

        Checks whether the deployed config UI tool matches the installed module version and copies it if not.

        .NOTES
        Private helper. Invoked from Invoke-VcfEdgeAtScaleUpdateCheck after a successful Update-Module call.
        Uses Write-Host for user-visible output because the caller assigns function output to $null.
    #>

    Param (
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$UserBaseDirectory
    )

    $configUiFileName = "veas-json-generator.py"

    $latestInstalledModule = Get-Module -ListAvailable -Name "VcfEdgeAtScale" |
        Sort-Object -Property Version -Descending |
        Select-Object -First 1
    if ($null -eq $latestInstalledModule) {
        Write-LogMessage -Type DEBUG -Message "Config UI sync skipped: VcfEdgeAtScale module not found via Get-Module -ListAvailable."
        return
    }

    $moduleToolsPath = Join-Path -Path $latestInstalledModule.ModuleBase -ChildPath "Tools"
    $sourcePath = Join-Path -Path $moduleToolsPath -ChildPath $configUiFileName
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        Write-LogMessage -Type DEBUG -Message "Config UI sync skipped: source not found at $sourcePath."
        return
    }

    if ([String]::IsNullOrWhiteSpace($UserBaseDirectory) -or -not (Test-Path -LiteralPath $UserBaseDirectory -PathType Container)) {
        Write-LogMessage -Type DEBUG -Message "Config UI sync skipped: deployment root is not set or does not exist."
        return
    }

    $deploymentToolsPath = Join-Path -Path $UserBaseDirectory -ChildPath "Tools"
    $destPath = Join-Path -Path $deploymentToolsPath -ChildPath $configUiFileName
    if (-not (Test-Path -LiteralPath $destPath -PathType Leaf)) {
        Write-LogMessage -Type DEBUG -Message "Config UI tool not present in deployment root; skipping auto-sync. Run Start-VcfEdgeAtScale -Initialize to install it."
        return
    }

    $sourceVersion = Get-VcfEdgeAtScaleConfigUiVersion -FilePath $sourcePath
    $destVersion = Get-VcfEdgeAtScaleConfigUiVersion -FilePath $destPath
    if ($sourceVersion -eq $destVersion) {
        Write-LogMessage -Type DEBUG -Message "Config UI tool is current (version $sourceVersion); no sync needed."
        return
    }

    Write-LogMessage -Type INFO -Message "Updating config UI tool: version $destVersion → $sourceVersion."
    try {
        Copy-Item -LiteralPath $sourcePath -Destination $destPath -Force -ErrorAction Stop
        Write-LogMessage -Type INFO -Message "Config UI tool updated to $sourceVersion at $destPath."
        Write-Host "  Config UI tool updated: $configUiFileName ($destVersion → $sourceVersion)" -ForegroundColor Green
    } catch {
        Write-LogMessage -Type WARNING -Message "Config UI tool sync failed: $($_.Exception.Message)"
        Write-Host "  Config UI tool could not be auto-updated. To copy manually, run:" -ForegroundColor Yellow
        Write-Host "    Copy-Item -LiteralPath '$sourcePath' -Destination '$destPath' -Force" -ForegroundColor Cyan
    }
}
function Get-VcfEdgeAtScaleUiTemplateVersion {

    <#
        .SYNOPSIS
        Returns the VEAS-UI-VERSION string embedded in a veas-ui.html file.

        .DESCRIPTION
        Reads the first line matching the pattern <!-- VEAS-UI-VERSION: ... --> in the specified
        file and returns the version value. Returns $null when the file is unreadable or contains
        no matching line.

        .PARAMETER FilePath
        Full path to the veas-ui.html file to inspect.

        .OUTPUTS
        [String] Version string (e.g. "1.0.3.1004"), or $null if not found.

        .EXAMPLE
        Get-VcfEdgeAtScaleUiTemplateVersion -FilePath "C:\VCFEdgeAtScale\Tools\veas-ui.html"

        Returns the VEAS-UI-VERSION value from the specified file.

        .NOTES
        Private helper. Used by Sync-VcfEdgeAtScaleUiTemplate to compare source and destination
        HTML template versions before deciding whether to copy.
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$FilePath
    )

    try {
        $lineMatch = Select-String -LiteralPath $FilePath -Pattern 'VEAS-UI-VERSION:\s*([\d.]+)' -ErrorAction Stop
        if ($null -ne $lineMatch) {
            return $lineMatch.Matches[0].Groups[1].Value
        }
    } catch {
        Write-LogMessage -Type DEBUG -Message "Get-VcfEdgeAtScaleUiTemplateVersion: could not read '${FilePath}': $($_.Exception.Message)"
    }
    return $null
}
function Sync-VcfEdgeAtScaleUiTemplate {

    <#
        .SYNOPSIS
        Copies the UI HTML template from the newly installed module to the deployment root Tools directory when the versions differ.

        .DESCRIPTION
        After a module upgrade, locates the newest installed VcfEdgeAtScale module via Get-Module -ListAvailable,
        reads the VEAS-UI-VERSION from its veas-ui.html, and compares it to the version in the user's
        deployment root Tools directory. If they differ the new file is copied automatically with no user prompt.

        The sync is silently skipped when:
        - UserBaseDirectory is not set or does not exist.
        - The template is absent from the deployment root (the user has not run -Initialize yet).
        - The source file is missing from the newly installed module.

        Unlike veas-json-generator.py, the HTML template is always silently overwritten because it
        is a versioned UI asset that is not edited by the operator.

        .PARAMETER UserBaseDirectory
        Path to the operator's deployment base directory (typically $env:VcfEdgeAtScaleRootDirectory).
        Pass an empty string or omit to skip the sync.

        .EXAMPLE
        Sync-VcfEdgeAtScaleUiTemplate -UserBaseDirectory $env:VcfEdgeAtScaleRootDirectory

        Checks whether the deployed UI template matches the installed module version and copies it if not.

        .NOTES
        Private helper. Invoked from Invoke-VcfEdgeAtScaleUpdateCheck after a successful Update-Module call.
        Uses Write-Host for user-visible output because the caller assigns function output to $null.
    #>

    Param (
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$UserBaseDirectory
    )

    $uiTemplateFileName = "veas-ui.html"

    $latestInstalledModule = Get-Module -ListAvailable -Name "VcfEdgeAtScale" |
        Sort-Object -Property Version -Descending |
        Select-Object -First 1
    if ($null -eq $latestInstalledModule) {
        Write-LogMessage -Type DEBUG -Message "UI template sync skipped: VcfEdgeAtScale module not found via Get-Module -ListAvailable."
        return
    }

    $moduleToolsPath = Join-Path -Path $latestInstalledModule.ModuleBase -ChildPath "Tools"
    $sourcePath = Join-Path -Path $moduleToolsPath -ChildPath $uiTemplateFileName
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        Write-LogMessage -Type DEBUG -Message "UI template sync skipped: source not found at $sourcePath."
        return
    }

    if ([String]::IsNullOrWhiteSpace($UserBaseDirectory) -or -not (Test-Path -LiteralPath $UserBaseDirectory -PathType Container)) {
        Write-LogMessage -Type DEBUG -Message "UI template sync skipped: deployment root is not set or does not exist."
        return
    }

    $deploymentToolsPath = Join-Path -Path $UserBaseDirectory -ChildPath "Tools"
    $destPath = Join-Path -Path $deploymentToolsPath -ChildPath $uiTemplateFileName
    if (-not (Test-Path -LiteralPath $destPath -PathType Leaf)) {
        Write-LogMessage -Type DEBUG -Message "UI template not present in deployment root; skipping auto-sync. Run Start-VcfEdgeAtScale -Initialize to install it."
        return
    }

    $sourceVersion = Get-VcfEdgeAtScaleUiTemplateVersion -FilePath $sourcePath
    $destVersion = Get-VcfEdgeAtScaleUiTemplateVersion -FilePath $destPath
    if ($sourceVersion -eq $destVersion) {
        Write-LogMessage -Type DEBUG -Message "UI template is current (version $sourceVersion); no sync needed."
        return
    }

    Write-LogMessage -Type INFO -Message "Updating UI template: version $destVersion → $sourceVersion."
    try {
        Copy-Item -LiteralPath $sourcePath -Destination $destPath -Force -ErrorAction Stop
        Write-LogMessage -Type INFO -Message "UI template updated to $sourceVersion at $destPath."
        Write-Host "  UI template updated: $uiTemplateFileName ($destVersion → $sourceVersion)" -ForegroundColor Green
    } catch {
        Write-LogMessage -Type WARNING -Message "UI template sync failed: $($_.Exception.Message)"
        Write-Host "  UI template could not be auto-updated. To copy manually, run:" -ForegroundColor Yellow
        Write-Host "    Copy-Item -LiteralPath '$sourcePath' -Destination '$destPath' -Force" -ForegroundColor Cyan
    }
}
function Invoke-VcfEdgeAtScaleUpdateCheck {

    <#
        .SYNOPSIS
        Checks PSGallery for a newer version of the VcfEdgeAtScale module and optionally installs it.

        .DESCRIPTION
        Queries the PowerShell Gallery for the latest published version of VcfEdgeAtScale and compares it
        to the currently running version. The check runs regardless of how the module was installed.

        When a newer version is found:
        - If the module was installed via PSGallery (Get-InstalledModule shows Repository = PSGallery), the
          user is offered the option to run Update-Module automatically (default Y).
        - If the module was installed manually (cloned/copied), the new version is announced and the manual
          update steps are shown; no automatic install is attempted.

        The check is skipped silently when:
        - PSGallery cannot be reached (network error, proxy, air-gap). All PSGallery errors are non-fatal.
        - The infrastructure JSON is loaded and common.autoUpdate is explicitly set to false.

        Auto-checks triggered by New-LogFile (once-per-day) are quiet when no update is found; only a new
        version produces visible output. Manual invocation (called from Start-VcfEdgeAtScale -CheckForUpdates)
        always reports the outcome, including "already up to date."

        .PARAMETER Quiet
        When set, suppress output when the module is already up to date. Used for the daily auto-check.

        .PARAMETER InputData
        Optional parsed infrastructure JSON object. When supplied, common.autoUpdate is read to respect
        an operator override that disables auto-checks.

        .EXAMPLE
        Invoke-VcfEdgeAtScaleUpdateCheck

        Checks for an available update and prompts to install if one is found (PSGallery installs) or
        shows manual update steps (manually installed copies).

        .EXAMPLE
        Invoke-VcfEdgeAtScaleUpdateCheck -Quiet -InputData $inputData

        Daily auto-check; silent when already at the latest version, respects common.autoUpdate override.

        .NOTES
        Requires network access to the PowerShell Gallery. All PSGallery errors are non-fatal and logged
        at DEBUG; the check is silently skipped rather than surfacing an error to the operator.
    #>

    Param (
        [Parameter(Mandatory = $false)] [Object]$InputData,
        [Parameter(Mandatory = $false)] [Switch]$Quiet
    )

    # Respect common.autoUpdate = false override when infrastructure JSON is loaded.
    if ($null -ne $InputData -and $null -ne $InputData.common -and $null -ne $InputData.common.PSObject.Properties["autoUpdate"]) {
        $autoUpdateValue = $InputData.common.autoUpdate
        if ($autoUpdateValue -is [bool] -and -not $autoUpdateValue) {
            Write-LogMessage -Type DEBUG -Message "Update check skipped: common.autoUpdate is false in infrastructure JSON."
            return
        } elseif ($autoUpdateValue -isnot [bool]) {
            Write-LogMessage -Type DEBUG -Message "Update check: common.autoUpdate value is not a boolean ($($autoUpdateValue.GetType().Name)); treating as enabled."
        }
    }

    # Determine the current running version and whether this was a PSGallery install.
    # Get-InstalledModule only knows about modules registered by Install-Module/Update-Module;
    # manually installed copies will return $null.
    $installedModule = Get-InstalledModule -Name "VcfEdgeAtScale" -ErrorAction SilentlyContinue
    $isGalleryInstall = $null -ne $installedModule -and $installedModule.Repository -eq "PSGallery"

    # Use the running module's version as the baseline for the comparison regardless of
    # install source; Get-Module is always available even for manual installs.
    $runningModule = Get-Module -Name "VcfEdgeAtScale" -ErrorAction SilentlyContinue
    if ($null -eq $runningModule) {
        Write-LogMessage -Type DEBUG -Message "Update check skipped: VcfEdgeAtScale is not currently loaded."
        return
    }
    $currentVersion = [Version]$runningModule.Version

    # Query PSGallery. Any failure (network, proxy, air-gap) is non-fatal and silently skipped.
    try {
        $galleryModule = Find-Module -Name "VcfEdgeAtScale" -Repository "PSGallery" -ErrorAction Stop
    } catch {
        Write-LogMessage -Type DEBUG -Message "Update check skipped: could not reach PSGallery. $($_.Exception.Message)"
        return
    }

    $latestVersion = [Version]$galleryModule.Version

    if ($latestVersion -le $currentVersion) {
        if (-not $Quiet) {
            Write-LogMessage -Type INFO -Message "VcfEdgeAtScale is up to date (version $currentVersion)."
        }
        return
    }

    Write-LogMessage -Type ADVISORY -Message "A new version of VcfEdgeAtScale is available: $latestVersion (you have $currentVersion)." -PrependNewLine

    if (-not $isGalleryInstall) {
        # Module was installed manually — cannot use Update-Module; show manual steps.
        Write-Host ""
        Write-Host "This module was not installed from PSGallery. To update, pull the latest source and re-run the installer:" -ForegroundColor Yellow
        Write-Host "  git pull" -ForegroundColor Cyan
        Write-Host "  .\VcfEdgeAtScale\Install-VcfEdgeAtScaleModule.ps1" -ForegroundColor Cyan
        Write-Host ""
        return
    }

    # PSGallery install — prompt to update automatically. Default is Y.
    Write-Host ""
    $installChoice = Read-Host "Install update now? [Y/n]"
    if ([String]::IsNullOrWhiteSpace($installChoice)) {
        $installChoice = "Y"
    }

    if ($installChoice -notmatch '^[Yy]') {
        Write-Host ""
        Write-Host "To update manually, run:" -ForegroundColor Yellow
        Write-Host "  Update-Module -Name VcfEdgeAtScale" -ForegroundColor Cyan
        Write-Host ""
        return
    }

    Write-LogMessage -Type INFO -Message "Installing VcfEdgeAtScale $latestVersion from PSGallery..."
    try {
        Update-Module -Name "VcfEdgeAtScale" -ErrorAction Stop
        Write-LogMessage -Type INFO -Message "VcfEdgeAtScale $latestVersion installed successfully."
        Sync-VcfEdgeAtScaleConfigUiTool -UserBaseDirectory $env:VcfEdgeAtScaleRootDirectory
        Sync-VcfEdgeAtScaleUiTemplate -UserBaseDirectory $env:VcfEdgeAtScaleRootDirectory
        Write-Host ""
        Write-Host "Update complete. Open a new PowerShell window to use the new version." -ForegroundColor Green
        Write-Host ""
    } catch {
        Write-LogMessage -Type ERROR -Message "Update failed: $($_.Exception.Message)"
        Write-Host ""
        Write-Host "To update manually, run:" -ForegroundColor Yellow
        Write-Host "  Update-Module -Name VcfEdgeAtScale" -ForegroundColor Cyan
        Write-Host ""
    }
}

#endregion
