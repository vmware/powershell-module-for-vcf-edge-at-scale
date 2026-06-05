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
#region Private — deployment cleanup orchestration and deployment entry point
function Assert-ContextKeys {

    <#
        .SYNOPSIS
        Validates that all required keys are present and non-null in a context hashtable.

        .DESCRIPTION
        Iterates the required key list. Throws VcfDeploymentException on the first missing or null
        key, logging an ERROR with the caller name and missing key names. Used at the top of every
        function that accepts a [Hashtable]$Context to surface caller typos or missing keys
        immediately — before any deployment work begins — rather than failing silently deep inside
        the function with a null-dereference.

        Optional keys (those accessed with a ContainsKey guard in the function body) must NOT be
        included in RequiredKeys.

        .PARAMETER CallerName
        Name of the calling function. Used in the error log message so the source of the failure
        is immediately identifiable.

        .PARAMETER Context
        The context hashtable to validate.

        .PARAMETER RequiredKeys
        Array of key names that must be present and non-null in Context.

        .EXAMPLE
        Assert-ContextKeys -CallerName "Invoke-StorageProvisioningPhase" -Context $Context `
            -RequiredKeys @("ClusterName", "StoragePolicyType", "EsxHosts")

        .NOTES
        Throws [VcfDeploymentException]; never returns $false. The caller does not need to check
        the return value — a missing key is always fatal.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$CallerName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Hashtable]$Context,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [String[]]$RequiredKeys
    )

    $missing = $RequiredKeys | Where-Object { -not $Context.ContainsKey($_) -or $null -eq $Context[$_] }
    if ($missing.Count -gt 0) {
        $errorMsg = "$CallerName : missing required context key(s): $($missing -join ', ')."
        Write-LogMessage -Type ERROR -Message $errorMsg
        throw [VcfDeploymentException]::new($errorMsg)
    }
}
function Confirm-CleanupForCluster {

    <#
        .SYNOPSIS
        Prompts the operator to confirm cleanup for a single cluster or bypasses the prompt when forced.

        .DESCRIPTION
        When ForceBypassPrompt is set, logs the bypass reason and returns immediately.
        Otherwise displays a scope-specific advisory message and requires the operator to type an exact
        confirmation phrase before cleanup proceeds. Throws VcfDeploymentException when the input does
        not match, ensuring no accidental deletions.

        .PARAMETER ArgoCDNamespace
        The ArgoCD namespace for the cluster. Used in the advisory message when CleanUpScope is ArgoCD.
        May be empty or null when not applicable.

        .PARAMETER CleanUpScope
        Cleanup scope: All, ArgoCD, Compute, Harbor, or Supervisor.

        .PARAMETER ClusterName
        Display name of the cluster being cleaned up. Used in advisory messages.

        .PARAMETER DatastoreName
        The datastore name for the edge site. Used in the advisory message for All and Compute scopes.

        .PARAMETER EdgeSite
        Edge site identifier for the cluster. Used in the confirmation phrase and advisory messages.

        .PARAMETER ForceBypassPrompt
        When set, skips the confirmation prompt and logs an advisory that confirmation was bypassed.

        .OUTPUTS
        None. Returns on confirmed input; throws VcfDeploymentException on rejection.

        .EXAMPLE
        Confirm-CleanupForCluster -CleanUpScope "All" -ClusterName $clusterName -DatastoreName $datastoreName -EdgeSite $edgeSite

        .NOTES
        Write-Host is the primary output mechanism in this function; all Write-Host calls are
        intentional interactive console output (blank-line spacing before the advisory).
        Use Write-LogMessage for diagnostic logging.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [String]$ArgoCDNamespace,
        [Parameter(Mandatory = $true)] [ValidateSet("All", "ArgoCD", "Compute", "Harbor", "Supervisor")] [String]$CleanUpScope,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DatastoreName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EdgeSite,
        [Parameter(Mandatory = $false)] [Switch]$ForceBypassPrompt
    )

    if ($ForceBypassPrompt) {
        Write-LogMessage -Type ADVISORY -Message "Skipping cleanup confirmation (labEnvironment=true and -Force)."
        Write-LogMessage -Type DEBUG -Message "Cleanup confirmation bypassed via -Force. Proceeding with cleanup."
        return
    }

    $expectedPromptText = "delete $($CleanUpScope.ToLower()) for $EdgeSite"

    Write-Host ""
    switch ($CleanUpScope) {
        "Supervisor" {
            Write-LogMessage -Type ADVISORY -Message "The cleanup process for supervisor will remove the Harbor Supervisor Service, the ArgoCD namespace, and then deactivate the VMware vSphere Kubernetes Service (VKS) supervisor on cluster `"$ClusterName`". Compute (VDS, vSAN/VMFS, cluster) remains. Please backup your data before proceeding."
        }
        "ArgoCD" {
            $argocdNameInMessage = if (-not [String]::IsNullOrWhiteSpace($ArgoCDNamespace)) { "`"$ArgoCDNamespace`"" } else { "(namespace name unknown)" }
            Write-LogMessage -Type ADVISORY -Message "The cleanup process will remove only the ArgoCD namespace $argocdNameInMessage for cluster `"$ClusterName`" (edgeSite `"$EdgeSite`"). No supervisor deactivation or compute removal. Please backup your data before proceeding."
        }
        "Harbor" {
            Write-LogMessage -Type ADVISORY -Message "The cleanup process will remove only the Harbor Supervisor Service from the supervisor for cluster `"$ClusterName`" (edgeSite `"$EdgeSite`"). No supervisor deactivation or compute removal. Please backup your data before proceeding."
        }
        default {
            Write-LogMessage -Type ADVISORY -Message "The cleanup process will remove all resources on edgeSite `"$EdgeSite`" including cluster `"$ClusterName`" and datastore `"$DatastoreName`". Please backup your data before proceeding."
        }
    }

    Write-LogMessage -Type INFO -Message "Cleanup confirmation required. Copy and paste exactly: $expectedPromptText"
    $userInput = Read-Host -Prompt "Copy/paste to confirm: $expectedPromptText"
    $userInputNormalized = if ($userInput) { $userInput.Trim() } else { "" }
    if ($userInputNormalized -ne $expectedPromptText) {
        $gotDescription = if ([String]::IsNullOrEmpty($userInputNormalized)) { "(empty input)" } else { "`"$userInputNormalized`"" }
        $errorMsg = "Cleanup confirmation failed. Expected: `"$expectedPromptText`". Got: $gotDescription. Script will terminate."
        Write-LogMessage -Type ERROR -Message $errorMsg
        throw [VcfDeploymentException]::new($errorMsg)
    }
    Write-LogMessage -Type DEBUG -Message "Cleanup confirmation passed. Proceeding with cleanup."
}
function Invoke-VdsTrioRemoval {

    <#
    .SYNOPSIS
        Attempts to remove a primary VDS and its two software-uplink variants for one cluster.

    .DESCRIPTION
        Calls Remove-EdgeClusterDistributedSwitch for VdsName, VdsName-sw1, and VdsName-sw2.
        All three removals are attempted even when one fails; each failure is logged as a warning.
        Returns $true on full success so the caller can branch directly on the return value.

    .PARAMETER ClusterName
        vCenter cluster name; used only for log messages.

    .PARAMETER VdsName
        Base VDS name. The function also attempts to remove VdsName-sw1 and VdsName-sw2.

    .OUTPUTS
        [Bool]. Returns $true when all three removals succeeded; $false if any removal failed.

    .EXAMPLE
        $vdsRemoved = Invoke-VdsTrioRemoval -ClusterName "cluster-vsan-edge1" -VdsName "vds-edge1"
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VdsName
    )

    $allSucceeded = $true
    foreach ($name in @($VdsName, "$VdsName-sw1", "$VdsName-sw2")) {
        try {
            Remove-EdgeClusterDistributedSwitch -ClusterName $ClusterName -VdsName $name
        } catch {
            $allSucceeded = $false
            Write-LogMessage -Type WARNING -Message "Could not remove VDS `"$name`" for cluster `"$ClusterName`": $($_.Exception.Message)."
        }
    }
    return $allSucceeded
}
function Remove-ClusterWithExistenceRetry {

    <#
    .SYNOPSIS
        Calls Remove-ClusterSafely and treats a vCenter false-negative as success via re-check.

    .DESCRIPTION
        vCenter occasionally reports an error on Remove-Cluster even when the cluster was actually
        removed (async deletion). When Remove-ClusterSafely throws, this function waits
        ClusterExistenceCheckDelaySeconds then re-queries. If the cluster is gone, the outcome is
        treated as success. If it still exists after an optional second wait of
        ClusterExistenceCheckRetryDelaySeconds, the failure is recorded as an error.
        Returns $true when removal failure was confirmed; $false when removal succeeded (either
        immediately or after the re-check showed the cluster was gone).

    .PARAMETER ClusterExistenceCheckDelaySeconds
        Seconds to wait after Remove-Cluster throws before re-querying cluster existence. Default 2.

    .PARAMETER ClusterExistenceCheckRetryDelaySeconds
        When cluster still exists after the first check, seconds to wait before checking again. Default 10.

    .PARAMETER ClusterName
        vCenter cluster name.

    .PARAMETER StoragePolicyType
        Storage type (vSAN-ESA, vSAN-OSA, or VMFS); used to tailor the warning message.

    .OUTPUTS
        [Bool]. Returns $true when cluster removal failed (caller should set $hadErrors); $false on success.

    .EXAMPLE
        if (Remove-ClusterWithExistenceRetry -ClusterName "cluster-vsan-edge1" -StoragePolicyType "vSAN-ESA") {
            $hadErrors = $true
        }
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(0, 60)] [Int]$ClusterExistenceCheckDelaySeconds = 2,
        [Parameter(Mandatory = $false)] [ValidateRange(0, 60)] [Int]$ClusterExistenceCheckRetryDelaySeconds = 10,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateSet("vSAN-ESA", "vSAN-OSA", "VMFS")] [String]$StoragePolicyType
    )

    try {
        Remove-ClusterSafely -ClusterName $ClusterName
        return $false
    } catch {
        Write-LogMessage -Type DEBUG -Message "Remove-Cluster threw for `"$ClusterName`"; waiting $ClusterExistenceCheckDelaySeconds s then re-checking if cluster still exists (vCenter may have removed it despite the error)."
        Start-Sleep -Seconds $ClusterExistenceCheckDelaySeconds
        $clusterStillExists = Get-ClusterByName -Name $ClusterName -Server $Script:vCenterName
        if ($clusterStillExists -and $ClusterExistenceCheckRetryDelaySeconds -gt 0) {
            Write-LogMessage -Type DEBUG -Message "Cluster still reported after first check; waiting $ClusterExistenceCheckRetryDelaySeconds s then re-checking (vCenter may be removing asynchronously)."
            Start-Sleep -Seconds $ClusterExistenceCheckRetryDelaySeconds
            $clusterStillExists = Get-ClusterByName -Name $ClusterName -Server $Script:vCenterName
        }
        if (-not $clusterStillExists) {
            Write-LogMessage -Type INFO -Message "Cluster `"$ClusterName`" was removed (vCenter reported an error but the cluster is no longer present)."
            return $false
        }
        $contextLabel = if ($StoragePolicyType -eq "VMFS") { "VMFS cleanup" } else { "vSAN/VDS cleanup" }
        Write-LogMessage -Type DEBUG -Message "Get-Cluster still returned a cluster for `"$ClusterName`" (Id: $($clusterStillExists.Id)). Treating as removal failure."
        Write-LogMessage -Type WARNING -Message "Could not remove cluster `"$ClusterName`" after $contextLabel`: $($_.Exception.Message). Remove the cluster manually if desired."
        return $true
    }
}
function Invoke-ClusterRollbackPhase {

    <#
        .SYNOPSIS
        Removes VDS networking, restores management to VSS, and tears down storage and cluster resources for one edge cluster during cleanup.

        .DESCRIPTION
        Handles the compute-rollback phase for Compute and All cleanup scopes. Sets $Script:SupervisorName
        for downstream vSAN helpers, builds vSAN rollback parameters (ESA/OSA only), resolves the NIC list
        and VDS names, removes non-vmk0 VMkernel interfaces, restores management networking to VSS, then
        removes VDS(es), cluster, and storage according to the storage type: VMFS removes cluster then
        datastore; vSAN-ESA/OSA runs Invoke-VsanDeploymentRollback then runs a second VMkernel removal pass
        (vSAN traffic vmkernels can only be removed after vSAN cluster leave) before removing VDS and cluster.

        .PARAMETER ClusterExistenceCheckDelaySeconds
        Seconds to wait after Remove-Cluster throws before re-checking if the cluster still exists. Default is 2.

        .PARAMETER ClusterExistenceCheckRetryDelaySeconds
        When the cluster still exists after the first existence check, seconds to wait before checking again. Default is 10.

        .PARAMETER ClusterName
        vCenter cluster name.

        .PARAMETER ClusterSpec
        JSON cluster specification object from infrastructure.json (for esxHosts and vSanWitnessVmName).

        .PARAMETER DatastoreNamePrefix
        Datastore name prefix; used to derive the VMFS datastore name during VMFS cleanup.

        .PARAMETER EdgeSite
        Edge site identifier for the cluster.

        .PARAMETER InputData
        Full infrastructure JSON object (for common.nicList and common.vSanWitnessVmName).

        .PARAMETER StoragePolicyTagCatalog
        Tag catalog name for vSAN storage policy tag removal. Pass $null or empty to skip tag removal.

        .PARAMETER StoragePolicyType
        Storage type: vSAN-ESA, vSAN-OSA, or VMFS. Controls the rollback path.

        .PARAMETER SupervisorNamePrefix
        Common supervisor name prefix; used to derive $Script:SupervisorName for vSAN rollback tag resolution.

        .PARAMETER VdsNamePrefix
        VDS name prefix; used to derive VDS names for removal.

        .OUTPUTS
        [Bool]. Returns $true if cleanup encountered errors; $false on full success.

        .EXAMPLE
        $hadErrors = Invoke-ClusterRollbackPhase -ClusterName $clusterName -ClusterSpec $cluster `
            -DatastoreNamePrefix $DatastoreNamePrefix -EdgeSite $currentEdgeSite -InputData $InputData `
            -StoragePolicyType "vSAN-ESA" -SupervisorNamePrefix $SupervisorNamePrefix `
            -VdsNamePrefix $VdsNamePrefix

        .NOTES
        Caller must ensure $Script:vCenterName is set before calling.
        Sets $Script:SupervisorName as a side effect so downstream tag-resolution helpers
        (Set-StoragePolicyTag) can resolve the correct supervisor name without an extra parameter.
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(0, 60)] [Int]$ClusterExistenceCheckDelaySeconds = 2,
        [Parameter(Mandatory = $false)] [ValidateRange(0, 60)] [Int]$ClusterExistenceCheckRetryDelaySeconds = 10,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSCustomObject]$ClusterSpec,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DatastoreNamePrefix,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EdgeSite,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSCustomObject]$InputData,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [String]$StoragePolicyTagCatalog,
        [Parameter(Mandatory = $true)] [ValidateSet("vSAN-ESA", "vSAN-OSA", "VMFS")] [String]$StoragePolicyType,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorNamePrefix,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VdsNamePrefix
    )

    $hadErrors = $false
    $Script:SupervisorName = Get-SupervisorNameFromPrefix -SupervisorNamePrefix $SupervisorNamePrefix -EdgeSite $EdgeSite
    $rollbackParams = $null
    if ($StoragePolicyType -eq "vSAN-ESA" -or $StoragePolicyType -eq "vSAN-OSA") {
        $rollbackParams = @{ ClusterName = $ClusterName; StoragePolicyType = $StoragePolicyType }
        if ($StoragePolicyTagCatalog) {
            $rollbackParams["StoragePolicyTagCatalog"] = $StoragePolicyTagCatalog
            $rollbackParams["StoragePolicyTagName"] = $Script:SupervisorName
        }
        if ($ClusterSpec.esxHosts -and $ClusterSpec.esxHosts.Count -gt 0) { $rollbackParams["EsxHostNames"] = @($ClusterSpec.esxHosts) }
        $witnessName = $null
        if (-not [String]::IsNullOrWhiteSpace($ClusterSpec.vSanWitnessVmName)) { $witnessName = $ClusterSpec.vSanWitnessVmName }
        elseif ($InputData.common -and -not [String]::IsNullOrWhiteSpace($InputData.common.vSanWitnessVmName)) { $witnessName = $InputData.common.vSanWitnessVmName }
        if ($witnessName) { $rollbackParams["WitnessHostName"] = $witnessName }
        $rollbackParams["SkipClusterRemoval"] = $true
    }
    $vdsName = Get-VdsNameFromPrefix -VdsNamePrefix $VdsNamePrefix -EdgeSite $EdgeSite
    $nicListForRestore = Get-EffectiveNicListForCluster -Cluster $ClusterSpec -CommonNicList $InputData.common.nicList
    if (-not $nicListForRestore -or $nicListForRestore.Count -eq 0) {
        $nicListForRestore = $InputData.common.nicList
    }
    $nicListCountForRestore = if ($nicListForRestore -and $nicListForRestore.Count -eq 4) { 4 } else { 2 }
    $vdsNamesForCleanup = @($vdsName, "$vdsName-sw1", "$vdsName-sw2")
    try {
        Remove-NonVmk0VmkernelInterfacesFromVds -ClusterName $ClusterName -VdsNames $vdsNamesForCleanup
    } catch {
        Write-LogMessage -Type WARNING -Message "Non-vmk0 VMkernel removal had errors for cluster `"$ClusterName`" (non-fatal): $($_.Exception.Message)."
    }
    try {
        $restoreResult = Invoke-ManagementRestoreForCleanupWithTopologyFallback -ClusterName $ClusterName -NicListCount $nicListCountForRestore -VdsName $vdsName
    } catch {
        $hadErrors = $true
        throw
    }
    if ($restoreResult.RestoreAttempted -and -not $restoreResult.Success) {
        $hadErrors = $true
        Write-LogMessage -Type ERROR -Message "Management was not moved back to VSS for cluster `"$ClusterName`". $($restoreResult.Message) Move vmk0 off the VDS manually on each host, then retry cleanup. Skipping VDS and cluster removal for this cluster."
    } else {
        if ($StoragePolicyType -eq "VMFS") {
            Write-LogMessage -Type INFO -Message "Removing VDS(es) for cluster `"$ClusterName`"..."
            $vdsRemovalSucceeded = Invoke-VdsTrioRemoval -ClusterName $ClusterName -VdsName $vdsName
            if ($vdsRemovalSucceeded) {
                $vmfsDatastoreName = Get-DatastoreNameFromPrefix -DatastoreNamePrefix $DatastoreNamePrefix -EdgeSite $EdgeSite
                # Remove the cluster first; cluster removal releases vCenter's cluster-level management
                # locks on the VMFS datastore (HA heartbeat config, swap datastore registration) that
                # cause "The resource is in use" when attempting datastore removal beforehand.
                if (Remove-ClusterWithExistenceRetry -ClusterName $ClusterName -StoragePolicyType $StoragePolicyType `
                        -ClusterExistenceCheckDelaySeconds $ClusterExistenceCheckDelaySeconds `
                        -ClusterExistenceCheckRetryDelaySeconds $ClusterExistenceCheckRetryDelaySeconds) {
                    $hadErrors = $true
                }
                Remove-VmfsDatastoreForCluster -ClusterName $ClusterName -DatastoreName $vmfsDatastoreName
            } else {
                $hadErrors = $true
                Write-LogMessage -Type WARNING -Message "Skipping VMFS datastore and cluster removal for `"$ClusterName`" because VDS removal failed. Move VMkernel adapters and VMs off the VDS port groups, then remove the VDS and cluster manually or retry cleanup."
            }
        } else {
            Invoke-VsanDeploymentRollback @rollbackParams
            # After vSAN cluster leave, vmkernels that were serving active vSAN traffic (e.g. vsan-*,
            # vmotion-*) can now be removed. The first pass (above) ran while vSAN was still active
            # and may have failed silently for those adapters; this pass frees the VDS port groups so
            # VDS removal succeeds.
            try {
                Remove-NonVmk0VmkernelInterfacesFromVds -ClusterName $ClusterName -VdsNames $vdsNamesForCleanup
            } catch {
                Write-LogMessage -Type WARNING -Message "Post-vSAN-rollback VMkernel removal had errors for cluster `"$ClusterName`" (non-fatal): $($_.Exception.Message)."
            }
            Write-LogMessage -Type INFO -Message "Removing VDS(es) for cluster `"$ClusterName`"..."
            $vdsRemovalSucceeded = Invoke-VdsTrioRemoval -ClusterName $ClusterName -VdsName $vdsName
            if ($vdsRemovalSucceeded) {
                if (Remove-ClusterWithExistenceRetry -ClusterName $ClusterName -StoragePolicyType $StoragePolicyType `
                        -ClusterExistenceCheckDelaySeconds $ClusterExistenceCheckDelaySeconds `
                        -ClusterExistenceCheckRetryDelaySeconds $ClusterExistenceCheckRetryDelaySeconds) {
                    $hadErrors = $true
                }
            } else {
                $hadErrors = $true
                Write-LogMessage -Type WARNING -Message "Skipping cluster removal for `"$ClusterName`" because VDS removal failed. Move VMkernel adapters and VMs off the VDS port groups, then remove the VDS and cluster manually or retry cleanup."
            }
        }
    }
    return $hadErrors
}
function Invoke-AllSupervisorPreRemoval {

    <#
    .SYNOPSIS
    Removes Harbor and ArgoCD supervisor services then deactivates the supervisor during a full (All) cleanup.

    .DESCRIPTION
    Executes the All-scope supervisor pre-removal sequence in order: (1) resolves the supervisor ID — if
    unreachable, skips service pre-removal but continues to deactivation; (2) removes the Harbor Supervisor
    Service so PVCs are gone before storage teardown; (3) removes the ArgoCD namespace and polls until gone
    or timeout; (4) calls Disable-SupervisorOnCluster. Returns ShouldSkipCluster = $true when supervisor
    deactivation fails so the caller can continue to the next cluster without attempting compute cleanup.

    .PARAMETER Context
    Hashtable with keys: ArgoCDNamespaceDeletePollIntervalSeconds, ArgoCDNamespaceDeleteTimeoutSeconds,
    ClusterName, ClusterObjectForCleanup, ClusterSpec, CurrentEdgeSite, HarborServiceDeletePollIntervalSeconds,
    HarborServiceDeleteTimeoutSeconds, HarborServiceYamlPath, LabEnvironment, SupervisorNamePrefix.

    .EXAMPLE
    $ctx = @{ ClusterName = "cl0-edge1"; ClusterSpec = $cluster; ... }
    $result = Invoke-AllSupervisorPreRemoval -Context $ctx
    if ($result.ShouldSkipCluster) { continue }

    .NOTES
    Uses $Script:VCenterUser and $Script:VcenterCredential for supervisor ID resolution.
    Caller must check ShouldSkipCluster and continue to the next cluster if true.
    #>

    [CmdletBinding()]
    [OutputType([System.Collections.Hashtable])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [System.Collections.Hashtable]$Context
    )

    Assert-ContextKeys -CallerName "Invoke-AllSupervisorPreRemoval" -Context $Context `
        -RequiredKeys @("ArgoCDNamespaceDeletePollIntervalSeconds", "ArgoCDNamespaceDeleteTimeoutSeconds",
            "ClusterName", "ClusterSpec", "CurrentEdgeSite",
            "HarborServiceDeletePollIntervalSeconds", "HarborServiceDeleteTimeoutSeconds",
            "LabEnvironment", "SupervisorNamePrefix")

    $clusterName            = $Context.ClusterName
    $currentEdgeSite        = $Context.CurrentEdgeSite
    $clusterObject          = $Context.ClusterObjectForCleanup
    $clusterSpec            = $Context.ClusterSpec
    $supervisorNamePrefix   = $Context.SupervisorNamePrefix
    $harborServiceYamlPath  = $Context.HarborServiceYamlPath
    $harborDeletePollSec    = $Context.HarborServiceDeletePollIntervalSeconds
    $harborDeleteTimeoutSec = $Context.HarborServiceDeleteTimeoutSeconds
    $argoCDDeletePollSec    = $Context.ArgoCDNamespaceDeletePollIntervalSeconds
    $argoCDDeleteTimeoutSec = $Context.ArgoCDNamespaceDeleteTimeoutSeconds
    $labEnvironment         = $Context.LabEnvironment

    # -SkipReadyWait: the supervisor may be in an error state during cleanup; waiting for Ready would block indefinitely.
    $supervisorId = $null
    try {
        $supervisorId = Get-SupervisorId `
            -supervisorName (Get-SupervisorNameFromPrefix -SupervisorNamePrefix $supervisorNamePrefix -EdgeSite $currentEdgeSite) `
            -VcenterUser $Script:VCenterUser -VcenterCredential $Script:VcenterCredential `
            -InsecureTls -Silence -SkipReadyWait -ErrorAction Stop
        } catch {
            Write-LogMessage -Type WARNING -Message "All cleanup: could not resolve supervisor ID for `"$clusterName`" (edgeSite `"$currentEdgeSite`"): $($_.Exception.Message). Skipping service pre-removal."
        }

    if (-not [String]::IsNullOrWhiteSpace($supervisorId)) {
        Invoke-AllCleanupServicePreRemoval `
            -ArgoCDDeletePollSec     $argoCDDeletePollSec `
            -ArgoCDDeleteTimeoutSec  $argoCDDeleteTimeoutSec `
            -ClusterName             $clusterName `
            -ClusterObject           $clusterObject `
            -ClusterSpec             $clusterSpec `
            -HarborDeletePollSec     $harborDeletePollSec `
            -HarborDeleteTimeoutSec  $harborDeleteTimeoutSec `
            -HarborServiceYamlPath   $harborServiceYamlPath `
            -SupervisorId            $supervisorId
    }

    $clusterIdForDisable = $clusterObject.ExtensionData.MoRef.Value
    if (-not $clusterIdForDisable) { $clusterIdForDisable = $clusterObject.Id -replace "^ClusterComputeResource-", "" }
    $disableResult = Disable-SupervisorOnCluster -ClusterId $clusterIdForDisable -ClusterName $clusterName -SuppressConfirm
    if (-not $disableResult.Success) {
        Write-LogMessage -Type ERROR -Message "Supervisor deactivation did not complete: $($disableResult.ErrorMessage). Skipping compute cleanup for `"$clusterName`"."
        return @{ ShouldSkipCluster = $true }
    }
    return @{ ShouldSkipCluster = $false }
}
function Invoke-AllCleanupServicePreRemoval {

    <#
        .SYNOPSIS
        Removes Harbor and ArgoCD supervisor services before cluster supervisor deactivation.

        .DESCRIPTION
        In the "All" cleanup path, removes the Harbor Supervisor Service (so its PVCs are gone before
        storage teardown) and the ArgoCD namespace. Both removals are non-fatal: failures are logged at
        WARNING and supervisor deactivation continues.

        .PARAMETER ArgoCDDeletePollSec
        Seconds between ArgoCD namespace-list polls. Default is 5.

        .PARAMETER ArgoCDDeleteTimeoutSec
        Maximum seconds to wait for the ArgoCD namespace to disappear. Default is 120.

        .PARAMETER ClusterName
        Cluster display name used in log messages.

        .PARAMETER ClusterObject
        Resolved cluster VMware object (used to retrieve ArgoCD namespace name).

        .PARAMETER ClusterSpec
        Cluster spec from the infrastructure JSON (used to retrieve ArgoCD namespace name).

        .PARAMETER HarborDeletePollSec
        Seconds between Harbor service-status polls. Default is 10.

        .PARAMETER HarborDeleteTimeoutSec
        Maximum seconds to wait for the Harbor service to be removed. Default is 300.

        .PARAMETER HarborServiceYamlPath
        Path to the Harbor supervisor service YAML. When blank or non-existent, Harbor pre-removal is skipped.

        .PARAMETER SupervisorId
        Resolved supervisor ID used by Harbor and ArgoCD removal calls.

        .EXAMPLE
        Invoke-AllCleanupServicePreRemoval -ClusterName "cl0-edge1" -ClusterObject $clusterObj -ClusterSpec $spec `
            -HarborServiceYamlPath $yamlPath -SupervisorId $supId `
            -HarborDeletePollSec 10 -HarborDeleteTimeoutSec 300 `
            -ArgoCDDeletePollSec 5  -ArgoCDDeleteTimeoutSec 120

        .NOTES
        Called by Invoke-AllSupervisorPreRemoval only when a valid supervisor ID has been resolved.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(1, 60)] [Int]$ArgoCDDeletePollSec = 5,
        [Parameter(Mandatory = $false)] [ValidateRange(10, 600)] [Int]$ArgoCDDeleteTimeoutSec = 120,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$ClusterObject,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$ClusterSpec,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 60)] [Int]$HarborDeletePollSec = 10,
        [Parameter(Mandatory = $false)] [ValidateRange(10, 600)] [Int]$HarborDeleteTimeoutSec = 300,
        [Parameter(Mandatory = $false)] [String]$HarborServiceYamlPath,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorId
    )

    # Remove Harbor service so its PVCs are gone before vSAN/VMFS is torn down.
    $harborSvcId = $null
    if (-not [String]::IsNullOrWhiteSpace($HarborServiceYamlPath) -and (Test-Path -Path $HarborServiceYamlPath)) {
        # Multi-assignment: first return value is the service ID; second is discarded via $null.
        $harborSvcId, $null = Get-ArgoCDServiceDetail -Path $HarborServiceYamlPath
    }
    if (-not [String]::IsNullOrWhiteSpace($harborSvcId)) {
        try {
            Remove-HarborSupervisorService -ClusterName $ClusterName -DeletePollIntervalSeconds $HarborDeletePollSec `
                -DeleteTimeoutSeconds $HarborDeleteTimeoutSec -Service $harborSvcId -SupervisorId $SupervisorId
        } catch {
            Write-LogMessage -Type WARNING -Message "All cleanup: Harbor service removal failed for cluster `"$ClusterName`": $($_.Exception.Message). Continuing with supervisor deactivation."
        }
    } else {
        Write-LogMessage -Type INFO -Message "All cleanup: Harbor service not found or YAML path not provided for cluster `"$ClusterName`"; skipping Harbor pre-removal."
    }

    # Remove the ArgoCD namespace before disabling the supervisor.
    $argocdNs = Get-ArgoCDNamespaceFromCluster -ClusterObject $ClusterObject -ClusterSpec $ClusterSpec
    $argocdExists = $false
    try {
        $argocdExists = (Invoke-ListNamespacesInstances -ErrorAction Stop).Namespace -contains $argocdNs
    } catch {
        Write-LogMessage -Type DEBUG -Message "All cleanup: could not check ArgoCD namespace existence: $($_.Exception.Message)."
    }
    if ($argocdExists) {
        Invoke-ArgoCDNamespaceDeleteAndPoll `
            -ArgoCDNamespace                         $argocdNs `
            -ArgoCDNamespaceDeletePollIntervalSeconds $ArgoCDDeletePollSec `
            -ArgoCDNamespaceDeleteTimeoutSeconds      $ArgoCDDeleteTimeoutSec `
            -ClusterName                             $ClusterName
    } else {
        Write-LogMessage -Type DEBUG -Message "All cleanup: ArgoCD namespace `"$argocdNs`" not found for cluster `"$ClusterName`". Nothing to remove."
    }
}
function Invoke-ArgoCDNamespaceCleanupForCluster {

    <#
        .SYNOPSIS
        Deletes the ArgoCD supervisor namespace for one edge cluster during cleanup.

        .DESCRIPTION
        Resolves the ArgoCD namespace name from the cluster object, checks whether the namespace exists,
        issues a deletion request, and polls until the namespace disappears or the timeout is reached.
        Errors during deletion are non-fatal: the function sets HadErrors in its return value instead
        of throwing, so the caller can continue to the next cluster.

        .PARAMETER ArgoCDNamespaceDeletePollIntervalSeconds
        Seconds between each poll for namespace deletion. Default is 5.

        .PARAMETER ArgoCDNamespaceDeleteTimeoutSeconds
        Maximum seconds to wait for namespace deletion before logging a warning. Default is 120.

        .PARAMETER ClusterName
        vCenter cluster name (for log messages).

        .PARAMETER ClusterObject
        vCenter cluster object used to resolve the ArgoCD namespace.

        .PARAMETER ClusterSpec
        JSON cluster specification object from infrastructure.json.

        .PARAMETER CurrentEdgeSite
        Edge site identifier for log messages.

        .OUTPUTS
        [Hashtable]. @{ HadErrors = [bool] } — $true when the deletion threw; $false otherwise.

        .EXAMPLE
        $result = Invoke-ArgoCDNamespaceCleanupForCluster `
            -ArgoCDNamespaceDeletePollIntervalSeconds 5 `
            -ArgoCDNamespaceDeleteTimeoutSeconds 120 `
            -ClusterName "cl0" -ClusterObject $clusterObj `
            -ClusterSpec $cluster -CurrentEdgeSite "edge1"
        if ($result.HadErrors) { $cleanupHadErrors = $true }
    #>

    [CmdletBinding()]
    [OutputType([Hashtable])]
    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(1, 60)]  [Int]$ArgoCDNamespaceDeletePollIntervalSeconds = 5,
        [Parameter(Mandatory = $false)] [ValidateRange(10, 600)] [Int]$ArgoCDNamespaceDeleteTimeoutSeconds = 120,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$ClusterObject,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSCustomObject]$ClusterSpec,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$CurrentEdgeSite
    )

    $argocdNamespace = Get-ArgoCDNamespaceFromCluster -ClusterObject $ClusterObject -ClusterSpec $ClusterSpec
    $namespaceExists = (Invoke-ListNamespacesInstances -ErrorAction SilentlyContinue).Namespace -contains $argocdNamespace
    if (-not $namespaceExists) {
        Write-LogMessage -Type INFO -Message "ArgoCD namespace `"$argocdNamespace`" does not exist for cluster `"$ClusterName`". Nothing to remove."
        return @{ HadErrors = $false }
    }

    $progressActivity = "Waiting for ArgoCD namespace `"$argocdNamespace`" to be removed"
    try {
        Invoke-DeleteNamespaceInstances -Namespace $argocdNamespace -Confirm:$false -ErrorAction Stop | Out-Null
        $elapsedSeconds = 0
        while ($elapsedSeconds -lt $ArgoCDNamespaceDeleteTimeoutSeconds) {
            $percentComplete = [Math]::Min(100, [int](($elapsedSeconds / $ArgoCDNamespaceDeleteTimeoutSeconds) * 100))
            Write-Progress -Activity $progressActivity -Status "Polling (${elapsedSeconds}s / ${ArgoCDNamespaceDeleteTimeoutSeconds}s)..." -PercentComplete $percentComplete
            [Console]::Out.Flush()
            Start-Sleep -Seconds $ArgoCDNamespaceDeletePollIntervalSeconds
            $elapsedSeconds += $ArgoCDNamespaceDeletePollIntervalSeconds
            $stillExists = $true
            try {
                $namespaceList = (Invoke-ListNamespacesInstances -ErrorAction Stop).Namespace
                if ($null -ne $namespaceList) { $stillExists = $namespaceList -contains $argocdNamespace }
            } catch {
                Write-LogMessage -Type DEBUG -Message "Invoke-ListNamespacesInstances failed during poll; treating namespace as still present. $($_.Exception.Message)"
            }
            if (-not $stillExists) {
                Write-Progress -Activity $progressActivity -Status "Complete" -PercentComplete 100 -Completed
                [Console]::Out.Flush()
                Write-LogMessage -Type INFO -Message "ArgoCD namespace `"$argocdNamespace`" deleted successfully for cluster `"$ClusterName`"."
                break
            }
            Write-LogMessage -Type DEBUG -Message "ArgoCD namespace `"$argocdNamespace`" still present; waiting (elapsed ${elapsedSeconds}s, timeout ${ArgoCDNamespaceDeleteTimeoutSeconds}s)."
        }
        if ($elapsedSeconds -ge $ArgoCDNamespaceDeleteTimeoutSeconds) {
            $stillExistsAfterWait = $true
            try {
                $namespaceListAfterWait = (Invoke-ListNamespacesInstances -ErrorAction Stop).Namespace
                if ($null -ne $namespaceListAfterWait) { $stillExistsAfterWait = $namespaceListAfterWait -contains $argocdNamespace }
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
                Write-LogMessage -Type INFO -Message "ArgoCD namespace `"$argocdNamespace`" deleted successfully for cluster `"$ClusterName`"."
            }
        }
    } catch {
        Write-Progress -Activity $progressActivity -Status "Error" -Completed
        [Console]::Out.Flush()
        Write-LogMessage -Type ERROR -Message "Failed to delete ArgoCD namespace `"$argocdNamespace`" for cluster `"$ClusterName`": $($_.Exception.Message). Continuing to next cluster."
        return @{ HadErrors = $true }
    }
    return @{ HadErrors = $false }
}
function Invoke-HarborServiceCleanupForCluster {

    <#
        .SYNOPSIS
        Removes the Harbor Supervisor Service for one edge cluster during cleanup.

        .DESCRIPTION
        Resolves the supervisor ID (skipping the Ready wait since cleanup may run on a degraded
        supervisor), determines the Harbor service identifier from the harbor-service YAML, and
        calls Remove-HarborSupervisorService. Errors are non-fatal: the function sets HadErrors
        in its return value so the caller can continue to the next cluster.

        .PARAMETER ClusterName
        vCenter cluster name (for log messages and supervisor ID resolution).

        .PARAMETER CurrentEdgeSite
        Edge site identifier for log messages and supervisor name resolution.

        .PARAMETER HarborServiceDeletePollIntervalSeconds
        Seconds between each poll while waiting for the Harbor service to be removed. Default is 10.

        .PARAMETER HarborServiceDeleteTimeoutSeconds
        Maximum seconds to wait for the Harbor service to disappear. Default is 180.

        .PARAMETER HarborServiceYamlPath
        Path to the harbor-service YAML file. When empty or not found, Harbor cleanup is skipped.

        .PARAMETER LabEnvironment
        When true, TLS certificate verification is skipped for vCenter REST API calls (labenvironment=true in infrastructure JSON). Defaults to $false (TLS verification active).

        .PARAMETER SupervisorNamePrefix
        Common supervisor name prefix; used to resolve the supervisor name from the edge site.

        .OUTPUTS
        [Hashtable]. @{ HadErrors = [bool] } — $true when an error occurred; $false otherwise.

        .EXAMPLE
        $result = Invoke-HarborServiceCleanupForCluster `
            -ClusterName "cl0" -CurrentEdgeSite "edge1" `
            -HarborServiceDeletePollIntervalSeconds 10 -HarborServiceDeleteTimeoutSeconds 180 `
            -HarborServiceYamlPath "/data/harbor-service.yml" -LabEnvironment:$false -SupervisorNamePrefix "sup"
        if ($result.HadErrors) { $cleanupHadErrors = $true }
    #>

    [CmdletBinding()]
    [OutputType([Hashtable])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$CurrentEdgeSite,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 60)]   [Int]$HarborServiceDeletePollIntervalSeconds = 10,
        [Parameter(Mandatory = $false)] [ValidateRange(10, 600)] [Int]$HarborServiceDeleteTimeoutSeconds = 180,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [String]$HarborServiceYamlPath,
        [Parameter(Mandatory = $false)] [Switch]$LabEnvironment,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorNamePrefix
    )

    # -SkipReadyWait: during cleanup the supervisor may be in a degraded or error state and will
    # never reach Ready — waiting for it would block cleanup indefinitely.
    $harborSupervisorId = $null
    try {
        $harborSupervisorId = Get-SupervisorId `
            -supervisorName (Get-SupervisorNameFromPrefix -SupervisorNamePrefix $SupervisorNamePrefix -EdgeSite $CurrentEdgeSite) `
            -VcenterUser $Script:VCenterUser -VcenterCredential $Script:VcenterCredential `
            -InsecureTls -Silence -SkipReadyWait -ErrorAction Stop
    } catch {
        Write-LogMessage -Type WARNING -Message "Could not determine supervisor ID for cluster `"$ClusterName`" (edgeSite `"$CurrentEdgeSite`"): $($_.Exception.Message). Skipping Harbor cleanup."
        return @{ HadErrors = $false }
    }
    if ([String]::IsNullOrWhiteSpace($harborSupervisorId)) {
        Write-LogMessage -Type WARNING -Message "Supervisor ID not found for cluster `"$ClusterName`". Skipping Harbor cleanup."
        return @{ HadErrors = $false }
    }

    if ([String]::IsNullOrWhiteSpace($HarborServiceYamlPath)) {
        # Harbor was not configured for this cluster — this is normal and expected.
        Write-LogMessage -Type DEBUG -Message "Harbor service YAML path not configured for cluster `"$ClusterName`"; skipping Harbor pre-removal."
        return @{ HadErrors = $false }
    }
    if (-not (Test-Path -Path $HarborServiceYamlPath)) {
        Write-LogMessage -Type WARNING -Message "Harbor service YAML file not found at `"$HarborServiceYamlPath`" for cluster `"$ClusterName`". Skipping Harbor cleanup. Verify supervisorServices.parentDirectory and harborServiceYamlFileName in infrastructure.json."
        return @{ HadErrors = $false }
    }
    $harborServiceIdentifier, $null = Get-ArgoCDServiceDetail -Path $HarborServiceYamlPath
    if ([String]::IsNullOrWhiteSpace($harborServiceIdentifier)) {
        Write-LogMessage -Type WARNING -Message "Could not read Harbor service identifier from `"$HarborServiceYamlPath`" for cluster `"$ClusterName`". Skipping Harbor cleanup."
        return @{ HadErrors = $false }
    }

    try {
        Remove-HarborSupervisorService `
            -ClusterName $ClusterName `
            -DeletePollIntervalSeconds $HarborServiceDeletePollIntervalSeconds `
            -DeleteTimeoutSeconds $HarborServiceDeleteTimeoutSeconds `
            -Service $harborServiceIdentifier `
            -SupervisorId $harborSupervisorId
    } catch {
        Write-LogMessage -Type ERROR -Message "Harbor cleanup failed for cluster `"$ClusterName`": $($_.Exception.Message). Continuing to next cluster."
        return @{ HadErrors = $true }
    }
    return @{ HadErrors = $false }
}
function Get-ClusterCleanupState {

    <#
        .SYNOPSIS
        Resolves cleanup state for a single cluster: effective name, storage policy, cluster object, and supervisor status.

        .DESCRIPTION
        Derives the effective cluster name, storage policy type and tag catalog, vCenter cluster object, WCP
        supervisor status, and whether the supervisor is currently enabled. Guards against the invalid case of
        Compute-only cleanup when a supervisor is already deployed on the cluster.

        .PARAMETER Cluster
        Cluster spec object from infrastructure.json.

        .PARAMETER CleanUpScope
        Cleanup scope (Supervisor, Compute, All, ArgoCD, Harbor). Used to guard the Compute-scope +
        supervisor-deployed conflict.

        .PARAMETER ClusterNamePrefix
        Common cluster name prefix (e.g. from common.clusterNamePrefix).

        .PARAMETER DatastoreNamePrefix
        Common datastore name prefix (e.g. from common.datastoreNamePrefix).

        .EXAMPLE
        $clusterState = Get-ClusterCleanupState -Cluster $cluster -CleanUpScope "All" -ClusterNamePrefix "edge-" -DatastoreNamePrefix "ds-"
        $clusterState.ClusterName
        $clusterState.SupervisorEnabled

        .NOTES
        Called by Invoke-VcfEdgeAtScaleCleanup for each cluster before dispatching cleanup.
        Throws [VcfDeploymentException] when Compute scope is requested but supervisor is deployed.
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateSet("All", "ArgoCD", "Compute", "Harbor", "Supervisor")] [String]$CleanUpScope,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSCustomObject]$Cluster,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterNamePrefix,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DatastoreNamePrefix
    )

    $currentEdgeSite = $Cluster.edgeSite
    $clusterName = Get-EffectiveClusterName -Cluster $Cluster -ClusterNamePrefix $ClusterNamePrefix -EdgeSite $currentEdgeSite
    $storagePolicyType = $null
    $storagePolicyTagCatalog = $null
    if ($Cluster.storagePolicy) {
        $storagePolicyType = $Cluster.storagePolicy.storageType
        $storagePolicyTagCatalog = $Cluster.storagePolicy.storagePolicyTagCatalog
        if ([String]::IsNullOrWhiteSpace($storagePolicyTagCatalog)) {
            $storagePolicyTagCatalog = "$storagePolicyType-Storage-TagCatalog"
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
    $configDisabled = [String]::IsNullOrEmpty($configStatus) -or ($configStatus -eq "DISABLED")
    $kubeNotInstalled = [String]::IsNullOrEmpty($kubeStatus) -or ($kubeStatus -eq "NOT_INSTALLED")
    $supervisorEnabled = $wcpEntry -and -not ($configDisabled -and $kubeNotInstalled)
    if ($CleanUpScope -eq "Compute" -and $supervisorEnabled) {
        $errorMsg = "Supervisor is deployed on cluster `"$clusterName`" (edgeSite `"$currentEdgeSite`"). Cannot cleanup only compute when supervisor is deployed. Use -CleanUp Supervisor to remove the supervisor first, or -CleanUp All to remove both."
        Write-LogMessage -Type ERROR -Message $errorMsg
        throw [VcfDeploymentException]::new($errorMsg)
    }
    return [PSCustomObject]@{
        ClusterName             = $clusterName
        CurrentEdgeSite         = $currentEdgeSite
        StoragePolicyType       = $storagePolicyType
        StoragePolicyTagCatalog = $storagePolicyTagCatalog
        ClusterObject           = $clusterObjectForCleanup
        SupervisorEnabled       = $supervisorEnabled
    }
}
function Invoke-NamedServiceScopedCleanup {

    <#
        .SYNOPSIS
        Dispatches Supervisor, ArgoCD, or Harbor scope cleanup for a single cluster; returns Handled=$false for Compute and All scopes.

        .DESCRIPTION
        Handles the three named-service cleanup scopes — Supervisor, ArgoCD, and Harbor — and returns a result
        object with Handled=$true when the scope was processed. Returns Handled=$false for Compute and All scopes
        so the caller can delegate to Invoke-ComputeCleanupForCluster.

        For the Supervisor scope, the teardown order mirrors -CleanUp All: (1) remove Harbor Supervisor Service,
        (2) remove ArgoCD namespace, (3) disable supervisor. Harbor and ArgoCD removal errors are non-fatal
        (logged as WARNING); supervisor deactivation failure throws VcfDeploymentException.

        .PARAMETER Context
        Cleanup context hashtable (built by Invoke-VcfEdgeAtScaleCleanup). Required keys: CleanUpScope,
        ArgoCDNamespaceDeletePollIntervalSeconds, ArgoCDNamespaceDeleteTimeoutSeconds,
        HarborServiceDeletePollIntervalSeconds, HarborServiceDeleteTimeoutSeconds, HarborServiceYamlPath,
        LabEnvironment, SupervisorNamePrefix.

        .PARAMETER CleanupState
        State object from Get-ClusterCleanupState (ClusterName, CurrentEdgeSite, ClusterObject, SupervisorEnabled).

        .PARAMETER ClusterSpec
        Cluster spec object from infrastructure.json. Passed to ArgoCD namespace lookup.

        .EXAMPLE
        $result = Invoke-NamedServiceScopedCleanup -Context $cleanupCtx -CleanupState $clusterState -ClusterSpec $cluster
        if ($result.Handled) { return $result }

        .NOTES
        Called by Invoke-ClusterScopedCleanup. For the Supervisor scope, throws [VcfDeploymentException] on
        deactivation failure; for ArgoCD and Harbor scopes, propagates HadErrors from the underlying helpers.
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSCustomObject]$CleanupState,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSCustomObject]$ClusterSpec,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Hashtable]$Context
    )

    Assert-ContextKeys -CallerName "Invoke-NamedServiceScopedCleanup" -Context $Context `
        -RequiredKeys @("ArgoCDNamespaceDeletePollIntervalSeconds", "ArgoCDNamespaceDeleteTimeoutSeconds",
            "CleanUpScope", "HarborServiceDeletePollIntervalSeconds", "HarborServiceDeleteTimeoutSeconds",
            "LabEnvironment", "SupervisorNamePrefix")

    $clusterName = $CleanupState.ClusterName
    $currentEdgeSite = $CleanupState.CurrentEdgeSite
    $clusterObject = $CleanupState.ClusterObject
    $supervisorEnabled = $CleanupState.SupervisorEnabled
    $cleanupScope = $Context.CleanUpScope
    switch ($cleanupScope) {
        "Supervisor" {
            if ($supervisorEnabled) {
                # Remove Harbor and ArgoCD before disabling the supervisor, matching the -CleanUp All teardown order:
                # Harbor first (PVCs gone before any storage teardown), then ArgoCD, then supervisor deactivation.
                Invoke-HarborServiceCleanupForCluster `
                    -ClusterName $clusterName `
                    -CurrentEdgeSite $currentEdgeSite `
                    -HarborServiceDeletePollIntervalSeconds $Context.HarborServiceDeletePollIntervalSeconds `
                    -HarborServiceDeleteTimeoutSeconds $Context.HarborServiceDeleteTimeoutSeconds `
                    -HarborServiceYamlPath $Context.HarborServiceYamlPath `
                    -LabEnvironment:$Context.LabEnvironment `
                    -SupervisorNamePrefix $Context.SupervisorNamePrefix | Out-Null
                Invoke-ArgoCDNamespaceCleanupForCluster `
                    -ArgoCDNamespaceDeletePollIntervalSeconds $Context.ArgoCDNamespaceDeletePollIntervalSeconds `
                    -ArgoCDNamespaceDeleteTimeoutSeconds $Context.ArgoCDNamespaceDeleteTimeoutSeconds `
                    -ClusterName $clusterName `
                    -ClusterObject $clusterObject `
                    -ClusterSpec $ClusterSpec `
                    -CurrentEdgeSite $currentEdgeSite | Out-Null
                $clusterId = $clusterObject.ExtensionData.MoRef.Value
                if (-not $clusterId) { $clusterId = $clusterObject.Id -replace "^ClusterComputeResource-", "" }
                $disableResult = Disable-SupervisorOnCluster -ClusterId $clusterId -ClusterName $clusterName -SuppressConfirm
                if ($disableResult.Success) {
                    Write-LogMessage -Type INFO -Message "Supervisor deactivated on cluster `"$clusterName`". Compute (VDS, vSAN/VMFS, cluster) remains."
                } else {
                    $errorMsg = "Supervisor deactivation failed: $($disableResult.ErrorMessage)."
                    Write-LogMessage -Type ERROR -Message $errorMsg
                    throw [VcfDeploymentException]::new($errorMsg)
                }
            } else {
                Write-LogMessage -Type INFO -Message "No supervisor enabled on cluster `"$clusterName`". Nothing to remove for Supervisor-only cleanup."
            }
            return [PSCustomObject]@{ Handled = $true; HadErrors = $false }
        }
        "ArgoCD" {
            Write-LogMessage -Type DEBUG -Message "ArgoCD cleanup: removing only the ArgoCD supervisor namespace for this cluster (no supervisor deactivation or compute removal)."
            if (-not $clusterObject) {
                Write-LogMessage -Type WARNING -Message "Cluster `"$clusterName`" not found; cannot resolve ArgoCD namespace name. Skipping ArgoCD cleanup for edgeSite `"$currentEdgeSite`"."
                return [PSCustomObject]@{ Handled = $true; HadErrors = $false }
            }
            $argoCDResult = Invoke-ArgoCDNamespaceCleanupForCluster `
                -ArgoCDNamespaceDeletePollIntervalSeconds $Context.ArgoCDNamespaceDeletePollIntervalSeconds `
                -ArgoCDNamespaceDeleteTimeoutSeconds $Context.ArgoCDNamespaceDeleteTimeoutSeconds `
                -ClusterName $clusterName `
                -ClusterObject $clusterObject `
                -ClusterSpec $ClusterSpec `
                -CurrentEdgeSite $currentEdgeSite
            return [PSCustomObject]@{ Handled = $true; HadErrors = $argoCDResult.HadErrors }
        }
        "Harbor" {
            Write-LogMessage -Type DEBUG -Message "Harbor cleanup: removing only the Harbor Supervisor Service from the supervisor for this cluster (no supervisor deactivation or compute removal)."
            if (-not $clusterObject) {
                Write-LogMessage -Type WARNING -Message "Cluster `"$clusterName`" not found; cannot determine supervisor ID. Skipping Harbor cleanup for edgeSite `"$currentEdgeSite`"."
                return [PSCustomObject]@{ Handled = $true; HadErrors = $false }
            }
            $harborResult = Invoke-HarborServiceCleanupForCluster `
                -ClusterName $clusterName `
                -CurrentEdgeSite $currentEdgeSite `
                -HarborServiceDeletePollIntervalSeconds $Context.HarborServiceDeletePollIntervalSeconds `
                -HarborServiceDeleteTimeoutSeconds $Context.HarborServiceDeleteTimeoutSeconds `
                -HarborServiceYamlPath $Context.HarborServiceYamlPath `
                -LabEnvironment:$Context.LabEnvironment `
                -SupervisorNamePrefix $Context.SupervisorNamePrefix
            return [PSCustomObject]@{ Handled = $true; HadErrors = $harborResult.HadErrors }
        }
    }
    return [PSCustomObject]@{ Handled = $false; HadErrors = $false }
}
function Invoke-ComputeCleanupForCluster {

    <#
        .SYNOPSIS
        Runs Compute or All scope compute-teardown for a single cluster: supervisor pre-removal (All only) then cluster rollback.

        .DESCRIPTION
        For All scope with supervisor enabled, runs Invoke-AllSupervisorPreRemoval first; if that signals
        ShouldSkipCluster, returns without running compute teardown. Then runs Invoke-ClusterRollbackPhase
        for known storage types (vSAN-ESA, vSAN-OSA, VMFS); skips with a debug log for other types.

        .PARAMETER Context
        Cleanup context hashtable (built by Invoke-VcfEdgeAtScaleCleanup). Required keys: CleanUpScope,
        ArgoCDNamespaceDeletePollIntervalSeconds, ArgoCDNamespaceDeleteTimeoutSeconds,
        ClusterExistenceCheckDelaySeconds, ClusterExistenceCheckRetryDelaySeconds, DatastoreNamePrefix,
        HarborServiceDeletePollIntervalSeconds, HarborServiceDeleteTimeoutSeconds, HarborServiceYamlPath,
        InputData, SupervisorNamePrefix, VdsNamePrefix.

        .PARAMETER CleanupState
        State object from Get-ClusterCleanupState.

        .PARAMETER ClusterSpec
        Cluster spec object from infrastructure.json.

        .EXAMPLE
        $computeResult = Invoke-ComputeCleanupForCluster -Context $cleanupCtx -CleanupState $clusterState -ClusterSpec $cluster
        if ($computeResult.HadErrors) { $cleanupHadErrors = $true }

        .NOTES
        Called by Invoke-ClusterScopedCleanup. Re-throws from Invoke-ClusterRollbackPhase so the caller can
        set cleanupHadErrors and propagate the exception.
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSCustomObject]$CleanupState,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSCustomObject]$ClusterSpec,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Hashtable]$Context
    )

    Assert-ContextKeys -CallerName "Invoke-ComputeCleanupForCluster" -Context $Context `
        -RequiredKeys @("ArgoCDNamespaceDeletePollIntervalSeconds", "ArgoCDNamespaceDeleteTimeoutSeconds",
            "CleanUpScope", "ClusterExistenceCheckDelaySeconds", "ClusterExistenceCheckRetryDelaySeconds",
            "DatastoreNamePrefix", "HarborServiceDeletePollIntervalSeconds",
            "HarborServiceDeleteTimeoutSeconds", "InputData", "LabEnvironment",
            "SupervisorNamePrefix", "VdsNamePrefix")

    if ($Context.CleanUpScope -eq "All" -and $CleanupState.SupervisorEnabled) {
        $allPreRemovalCtx = @{
            ArgoCDNamespaceDeletePollIntervalSeconds = $Context.ArgoCDNamespaceDeletePollIntervalSeconds
            ArgoCDNamespaceDeleteTimeoutSeconds      = $Context.ArgoCDNamespaceDeleteTimeoutSeconds
            ClusterName                              = $CleanupState.ClusterName
            ClusterObjectForCleanup                  = $CleanupState.ClusterObject
            ClusterSpec                              = $ClusterSpec
            CurrentEdgeSite                          = $CleanupState.CurrentEdgeSite
            HarborServiceDeletePollIntervalSeconds   = $Context.HarborServiceDeletePollIntervalSeconds
            HarborServiceDeleteTimeoutSeconds        = $Context.HarborServiceDeleteTimeoutSeconds
            HarborServiceYamlPath                    = $Context.HarborServiceYamlPath
            LabEnvironment                           = $Context.LabEnvironment
            SupervisorNamePrefix                     = $Context.SupervisorNamePrefix
        }
        $allPreRemovalResult = Invoke-AllSupervisorPreRemoval -Context $allPreRemovalCtx
        if ($allPreRemovalResult.ShouldSkipCluster) { return [PSCustomObject]@{ HadErrors = $false } }
    }
    $knownStorageTypes = @("vSAN-ESA", "vSAN-OSA", "VMFS")
    if ($CleanupState.StoragePolicyType -in $knownStorageTypes) {
        try {
            if (Invoke-ClusterRollbackPhase `
                -ClusterExistenceCheckDelaySeconds $Context.ClusterExistenceCheckDelaySeconds `
                -ClusterExistenceCheckRetryDelaySeconds $Context.ClusterExistenceCheckRetryDelaySeconds `
                -ClusterName $CleanupState.ClusterName `
                -ClusterSpec $ClusterSpec `
                -DatastoreNamePrefix $Context.DatastoreNamePrefix `
                -EdgeSite $CleanupState.CurrentEdgeSite `
                -InputData $Context.InputData `
                -StoragePolicyTagCatalog $CleanupState.StoragePolicyTagCatalog `
                -StoragePolicyType $CleanupState.StoragePolicyType `
                -SupervisorNamePrefix $Context.SupervisorNamePrefix `
                -VdsNamePrefix $Context.VdsNamePrefix) {
                return [PSCustomObject]@{ HadErrors = $true }
            }
        } catch {
            throw
        }
    } else {
        Write-LogMessage -Type DEBUG -Message "Skipping compute cleanup for cluster `"$($CleanupState.ClusterName)`" (storage type `"$($CleanupState.StoragePolicyType)`" is not ESA/OSA/VMFS)."
    }
    return [PSCustomObject]@{ HadErrors = $false }
}
function Invoke-ClusterScopedCleanup {

    <#
        .SYNOPSIS
        Orchestrates cleanup for a single cluster: confirms intent, then delegates to named-service or compute-teardown helpers.

        .DESCRIPTION
        Before prompting for confirmation, performs a pre-flight existence check: if the cluster
        object is absent, the supervisor is not enabled, and none of the three VDS candidates
        (primary, -sw1, -sw2) exist in vCenter, logs that nothing was found and returns immediately
        without prompting the operator.

        When resources are found, prompts for cleanup confirmation (via Confirm-CleanupForCluster),
        then dispatches to Invoke-NamedServiceScopedCleanup for Supervisor/ArgoCD/Harbor scopes or
        Invoke-ComputeCleanupForCluster for Compute/All scopes.

        .PARAMETER Context
        Cleanup context hashtable from Invoke-VcfEdgeAtScaleCleanup containing all poll intervals,
        timeouts, scope, and shared parameters.

        .PARAMETER CleanupState
        State object from Get-ClusterCleanupState (cluster name, object, storage policy, supervisor state).

        .PARAMETER ClusterSpec
        Cluster spec object from infrastructure.json.

        .EXAMPLE
        $result = Invoke-ClusterScopedCleanup -Context $cleanupCtx -CleanupState $clusterState -ClusterSpec $cluster
        if ($result.HadErrors) { $cleanupHadErrors = $true }

        .NOTES
        Called by Invoke-VcfEdgeAtScaleCleanup inside the per-cluster loop. Returns [PSCustomObject]@{ HadErrors = $bool }.
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSCustomObject]$CleanupState,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSCustomObject]$ClusterSpec,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Hashtable]$Context
    )

    Assert-ContextKeys -CallerName "Invoke-ClusterScopedCleanup" -Context $Context `
        -RequiredKeys @("CleanUpScope", "DatastoreNamePrefix", "VdsNamePrefix")

    if ($null -eq $CleanupState.ClusterObject -and -not $CleanupState.SupervisorEnabled) {
        $vdsBaseName = Get-VdsNameFromPrefix -VdsNamePrefix $Context.VdsNamePrefix -EdgeSite $CleanupState.CurrentEdgeSite
        $anyVds = @($vdsBaseName, "$vdsBaseName-sw1", "$vdsBaseName-sw2") | Where-Object {
            $null -ne (Get-VDSwitch -Name $_ -Server $Script:vCenterName -WarningAction SilentlyContinue -ErrorAction SilentlyContinue)
        } | Select-Object -First 1
        if (-not $anyVds) {
            Write-LogMessage -Type INFO -Message "No resources found for cluster `"$($CleanupState.ClusterName)`" (edgeSite `"$($CleanupState.CurrentEdgeSite)`"); already cleaned up or never deployed. Skipping."
            return [PSCustomObject]@{ HadErrors = $false }
        }
    }
    $datastoreNameForPrompt = Get-DatastoreNameFromPrefix -DatastoreNamePrefix $Context.DatastoreNamePrefix -EdgeSite $CleanupState.CurrentEdgeSite
    $argocdNamespaceForPrompt = $null
    if ($Context.CleanUpScope -eq "ArgoCD" -and $CleanupState.ClusterObject) {
        $argocdNamespaceForPrompt = Get-ArgoCDNamespaceFromCluster -ClusterObject $CleanupState.ClusterObject -ClusterSpec $ClusterSpec
    }
    Confirm-CleanupForCluster `
        -ArgoCDNamespace $argocdNamespaceForPrompt `
        -CleanUpScope $Context.CleanUpScope `
        -ClusterName $CleanupState.ClusterName `
        -DatastoreName $datastoreNameForPrompt `
        -EdgeSite $CleanupState.CurrentEdgeSite `
        -ForceBypassPrompt:$Context.ForceBypassPrompt
    $namedScopeResult = Invoke-NamedServiceScopedCleanup -Context $Context -CleanupState $CleanupState -ClusterSpec $ClusterSpec
    if ($namedScopeResult.Handled) { return $namedScopeResult }
    return Invoke-ComputeCleanupForCluster -Context $Context -CleanupState $CleanupState -ClusterSpec $ClusterSpec
}
function Invoke-VcfEdgeAtScaleCleanup {

    <#
        .SYNOPSIS
        Runs the cleanup workflow for one or more edge clusters (Supervisor-only, Compute-only, All, or ArgoCD). Used by Initialize-VcfEdgeAtScale when -CleanUp is set.

        .DESCRIPTION
        Sets Script:CleanUpOnly, then for each cluster: validates supervisor state, prompts for confirmation (unless labEnvironment and -Force), performs Supervisor-only, ArgoCD-only, Harbor-only, or Compute/All cleanup. For Supervisor and All cleanup the teardown order is: (1) remove Harbor Supervisor Service (PVCs must be gone before storage teardown), (2) remove ArgoCD namespace, (3) disable supervisor. All cleanup continues with: (4) remove VMkernel interfaces, restore management to VSS, remove VDS, remove vSAN/VMFS and cluster. Throws if any cluster cleanup fails so the caller can exit without deploying.

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
        Sets $Script:CleanUpOnly = $true on entry so downstream functions know they are running
        in cleanup-only mode rather than a fresh deployment.

        Write-Host is the primary output mechanism in this function; all Write-Host calls are
        intentional interactive console output (confirmation prompts and blank-line spacing).
        Use Write-LogMessage for diagnostic logging.
    
        .EXAMPLE
        Invoke-VcfEdgeAtScaleCleanup -CleanUp "value" -ClusterNamePrefix "edge-cluster-1" -ClustersToProcess $inputObject -DatastoreNamePrefix "resource-name"
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
        [Parameter(Mandatory = $true)] [Bool]$LabEnvironment,
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
    $cleanupCtx = @{
        ArgoCDNamespaceDeletePollIntervalSeconds = $ArgoCDNamespaceDeletePollIntervalSeconds
        ArgoCDNamespaceDeleteTimeoutSeconds      = $ArgoCDNamespaceDeleteTimeoutSeconds
        CleanUpScope                             = $cleanupScope
        ClusterExistenceCheckDelaySeconds        = $ClusterExistenceCheckDelaySeconds
        ClusterExistenceCheckRetryDelaySeconds   = $ClusterExistenceCheckRetryDelaySeconds
        DatastoreNamePrefix                      = $DatastoreNamePrefix
        ForceBypassPrompt                        = $forceBypassPrompt
        HarborServiceDeletePollIntervalSeconds   = $HarborServiceDeletePollIntervalSeconds
        HarborServiceDeleteTimeoutSeconds        = $HarborServiceDeleteTimeoutSeconds
        HarborServiceYamlPath                    = $HarborServiceYamlPath
        InputData                                = $InputData
        LabEnvironment                           = $LabEnvironment
        SupervisorNamePrefix                     = $SupervisorNamePrefix
        VdsNamePrefix                            = $VdsNamePrefix
    }
    foreach ($cluster in $ClustersToProcess) {
        $clusterState = Get-ClusterCleanupState `
            -Cluster $cluster `
            -CleanUpScope $cleanupScope `
            -ClusterNamePrefix $ClusterNamePrefix `
            -DatastoreNamePrefix $DatastoreNamePrefix
        $result = Invoke-ClusterScopedCleanup -Context $cleanupCtx -CleanupState $clusterState -ClusterSpec $cluster
        if ($result.HadErrors) { $cleanupHadErrors = $true }
    }
    if ($cleanupHadErrors) {
        $errorMsg = "CleanUp ($cleanupScope) did not complete successfully. One or more clusters had errors (e.g. management restore failed, VDS or cluster removal failed). Review the log and resolve the issues, then retry cleanup or remove resources manually."
        Write-LogMessage -Type ERROR -Message $errorMsg
        throw [VcfDeploymentException]::new($errorMsg)
    }
}
function Invoke-PostSupervisorDeploymentActions {

    <#
    .SYNOPSIS
        Runs ArgoCD deployment, Harbor deployment, and cluster health reports after supervisor creation.
    .DESCRIPTION
        Dispatches the ArgoCD and Harbor deployment phases (unless disabled via the Context flags),
        then logs post-deployment health reports for the cluster. Returns the Harbor service name
        (or $null when Harbor is disabled or not yet registered).
    .PARAMETER ArgocdNameSpace
        Resolved ArgoCD namespace for this cluster.
    .PARAMETER ClusterId
        vSphere cluster MoRef.
    .PARAMETER ClusterName
        Cluster display name.
    .PARAMETER Context
        Deployment context hashtable shared with Invoke-SupervisorDeploymentPhase.
    .PARAMETER CurrentEdgeSite
        Edge site name used in log messages.
    .PARAMETER SkipArgoCDDeployment
        Skips ArgoCD deployment when set.
    .PARAMETER SkipHarborDeployment
        Skips Harbor deployment when set.
    .PARAMETER IsSingleSite
        Passed to child phases to allow single-site-specific behaviour.
    .PARAMETER SupervisorId
        Supervisor ID assigned by the supervisor creation step.
    .EXAMPLE
        $harborName = Invoke-PostSupervisorDeploymentActions -ArgocdNameSpace $ns -ClusterId $id -ClusterName $name -Context $ctx -CurrentEdgeSite $site -SupervisorId $svId
    .NOTES
        Called by Invoke-SupervisorDeploymentPhase. Mutates $Context.ArgocdVmClass on the ArgoCD path.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $false)] [AllowNull()] [String]$ArgocdNameSpace,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterId,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Hashtable]$Context,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$CurrentEdgeSite,
        [Parameter(Mandatory = $false)] [Switch]$IsSingleSite,
        [Parameter(Mandatory = $false)] [Switch]$SkipArgoCDDeployment,
        [Parameter(Mandatory = $false)] [Switch]$SkipHarborDeployment,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorId
    )

    Assert-ContextKeys -CallerName "Invoke-PostSupervisorDeploymentActions" -Context $Context `
        -RequiredKeys @("ArgoCdDeploymentYamlPath", "ArgoCDyaml", "Cluster", "ContextName",
            "InputData", "LabEnvironment", "PreserveAutoGeneratedKeyCert", "SaveHarborYaml",
            "StoragePolicyId", "StoragePolicyName", "StoragePolicyType", "VcenterCredential")

    $harborServiceName = $null
    if (-not $SkipArgoCDDeployment) {
        $Context.ArgocdVmClass = Invoke-ArgoCDDeploymentPhase -Context @{
            ArgoCdDeploymentYamlPath = $Context.ArgoCdDeploymentYamlPath
            ArgoCDyaml               = $Context.ArgoCDyaml
            ArgocdNameSpace          = $ArgocdNameSpace
            ArgocdVmClass            = $Context.ArgocdVmClass
            ClusterId                = $ClusterId
            ClusterName              = $ClusterName
            ContextName              = $Context.ContextName
            InsecureTls              = $true
            StoragePolicyId          = $Context.StoragePolicyId
            SupervisorId             = $SupervisorId
            VcenterCredential        = $Context.VcenterCredential
        }
    } else {
        Write-LogMessage -Type INFO -Message "ArgoCD deployment skipped for edge site `"$CurrentEdgeSite`" (disableArgoCD is set in infrastructure JSON)."
    }
    if (-not $SkipHarborDeployment) {
        $harborServiceName = Invoke-HarborDeploymentPhase -Context @{
            Cluster                      = $Context.Cluster
            ClusterId                    = $ClusterId
            ClusterName                  = $ClusterName
            ContextName                  = $Context.ContextName
            CurrentEdgeSite              = $CurrentEdgeSite
            InputData                    = $Context.InputData
            InsecureTls                  = $true
            LabEnvironment               = $Context.LabEnvironment
            PreserveAutoGeneratedKeyCert = $Context.PreserveAutoGeneratedKeyCert
            SaveHarborYaml               = $Context.SaveHarborYaml
            StoragePolicyName            = $Context.StoragePolicyName
            SupervisorId                 = $SupervisorId
        }
    } else {
        Write-LogMessage -Type INFO -Message "Harbor deployment skipped for edge site `"$CurrentEdgeSite`" (disableHarbor is set in infrastructure JSON)."
    }
    Write-LogMessage -Type INFO -Message "Completed deployment for cluster with edgeSite: $CurrentEdgeSite"
    Write-ClusterEsxiNodeHealthReport -ClusterName $ClusterName
    if (-not [String]::IsNullOrWhiteSpace($SupervisorId)) {
        Write-SupervisorHealthReport -ClusterName $ClusterName -SupervisorId $SupervisorId
    }
    if ($Context.StoragePolicyType -eq "vSAN-ESA" -or $Context.StoragePolicyType -eq "vSAN-OSA") {
        Invoke-VsanClusterHealthRetestAfterDeployment -ClusterName $ClusterName
        Write-VsanClusterHealthReport -ClusterName $ClusterName
    }
    return $harborServiceName
}
function Invoke-SupervisorPhaseRollback {

    <#
    .SYNOPSIS
        Handles the rollback decision and execution when Invoke-SupervisorDeploymentPhase fails.
    .DESCRIPTION
        Inspects $Script:RollbackFailed, $Script:RollbackAttempted, and the phase flags to determine
        the correct rollback action: Harbor-only, ArgoCD-only, supervisor-only, or rethrow. Returns
        $true when the caller should skip to the next site (RollbackSkippedException caught), or throws
        VcfDeploymentException when rollback completes and the caller should propagate failure.
    .PARAMETER ArgocdNameSpace
        Resolved ArgoCD namespace; used to select ArgoCD-only rollback.
    .PARAMETER ClusterId
        vSphere cluster MoRef.
    .PARAMETER ClusterName
        Cluster display name.
    .PARAMETER CurrentEdgeSite
        Edge site name used in log messages.
    .PARAMETER HarborServiceName
        Registered Harbor service name; empty/null means Harbor phase started but failed before registration.
    .PARAMETER IsSingleSite
        Passed to rollback helpers.
    .PARAMETER SupervisorCreatedThisSite
        True when the supervisor was successfully created this iteration.
    .PARAMETER SupervisorCreationAttemptedThisSite
        True when supervisor creation was attempted (may have failed).
    .PARAMETER SupervisorId
        Supervisor ID, passed to rollback helpers.
    .EXAMPLE
        return Invoke-SupervisorPhaseRollback -ArgocdNameSpace $ns -ClusterId $id -ClusterName $name -CurrentEdgeSite $site -HarborServiceName $harborName -SupervisorId $svId
    .NOTES
        Called only from the catch block of Invoke-SupervisorDeploymentPhase. Uses $Script:RollbackFailed,
        $Script:RollbackAttempted, $Script:HarborPhaseStarted, $Script:ArgoCDPhaseStarted.
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $false)] [AllowNull()] [String]$ArgocdNameSpace,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterId,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$CurrentEdgeSite,
        [Parameter(Mandatory = $false)] [AllowNull()] [String]$HarborServiceName,
        [Parameter(Mandatory = $false)] [Switch]$IsSingleSite,
        [Parameter(Mandatory = $false)] [Switch]$SupervisorCreatedThisSite,
        [Parameter(Mandatory = $false)] [Switch]$SupervisorCreationAttemptedThisSite,
        [Parameter(Mandatory = $false)] [AllowNull()] [String]$SupervisorId
    )

    if ($Script:RollbackFailed) {
        Write-LogMessage -Type ERROR -Message "Rollback failed for edgeSite `"$CurrentEdgeSite`"; exiting with failure (no second rollback prompt)."
        throw
    }
    if ($Script:RollbackAttempted) {
        Write-LogMessage -Type INFO -Message "Rollback was already attempted for this failure; rethrowing without prompting again."
        throw
    }
    if ($SupervisorCreatedThisSite) {
        if ($Script:HarborPhaseStarted) {
            if (-not [String]::IsNullOrWhiteSpace($HarborServiceName)) {
                Write-LogMessage -Type INFO -Message "Harbor deployment failure for edgeSite `"$CurrentEdgeSite`"; rollback decision required (Harbor-only: remove service, supervisor and ArgoCD left intact for idempotent retry)."
                try { Invoke-HarborOnlyRollback -ClusterName $ClusterName -Service $HarborServiceName -SingleSite:$IsSingleSite.IsPresent -SupervisorId $SupervisorId }
                catch [RollbackSkippedException] { Write-LogMessage -Type WARNING -Message "Skipping rollback for edgeSite `"$CurrentEdgeSite`"; leaving site in current state. Continuing to next site."; return $true }
            } else {
                Write-LogMessage -Type INFO -Message "Harbor deployment failure for edgeSite `"$CurrentEdgeSite`" (failure before service registration; no Harbor service to remove). Supervisor and ArgoCD left intact for idempotent retry."
            }
        } elseif ($Script:ArgoCDPhaseStarted -and -not [String]::IsNullOrWhiteSpace($ArgocdNameSpace)) {
            Write-LogMessage -Type INFO -Message "ArgoCD deployment failure for edgeSite `"$CurrentEdgeSite`"; rollback decision required (ArgoCD-only: remove namespace, supervisor left intact for idempotent retry)."
            try { Invoke-ArgoCDOnlyRollback -ArgoCDNamespace $ArgocdNameSpace -ClusterName $ClusterName -SupervisorId $SupervisorId }
            catch [RollbackSkippedException] { Write-LogMessage -Type WARNING -Message "Skipping rollback for edgeSite `"$CurrentEdgeSite`"; leaving site in current state. Continuing to next site."; return $true }
        } else {
            Write-LogMessage -Type INFO -Message "Supervisor deployment failure for edgeSite `"$CurrentEdgeSite`"; running supervisor-only rollback (compute/vSAN/VDS left intact)."
            try { Invoke-SupervisorOnlyRollback -ClusterId $ClusterId -ClusterName $ClusterName -SingleSite:$IsSingleSite.IsPresent -SupervisorId $SupervisorId }
            catch [RollbackSkippedException] { Write-LogMessage -Type WARNING -Message "Skipping rollback for edgeSite `"$CurrentEdgeSite`"; leaving site in current state. Continuing to next site."; return $true }
        }
    } elseif ($SupervisorCreationAttemptedThisSite) {
        Write-LogMessage -Type INFO -Message "Supervisor creation failed for edgeSite `"$CurrentEdgeSite`" (compute passed); running supervisor-only rollback (compute/vSAN/VDS left intact)."
        try { Invoke-SupervisorOnlyRollback -ClusterId $ClusterId -ClusterName $ClusterName -SingleSite:$IsSingleSite.IsPresent -SupervisorId $SupervisorId }
        catch [RollbackSkippedException] { Write-LogMessage -Type WARNING -Message "Skipping rollback for edgeSite `"$CurrentEdgeSite`"; leaving site in current state. Continuing to next site."; return $true }
    } else {
        throw
    }
    throw [VcfDeploymentException]::new($CurrentEdgeSite)
}
function Invoke-SupervisorDeploymentPhase {

    <#
        .SYNOPSIS
        Deploys the vSphere Supervisor, ArgoCD, and Harbor for a single edge site within the deployment loop.

        .DESCRIPTION
        Handles the supervisor deployment sub-phase within the per-cluster deployment loop in
        Initialize-VcfEdgeAtScale. Performs these operations in order:

        - Validates the ArgoCD deployment YAML namespace consistency (when ArgoCD is not disabled).
        - Creates or retrieves the vSphere Supervisor for the cluster.
        - Conditionally invokes Invoke-ArgoCDDeploymentPhase (when Context.SkipArgoCDDeployment is false).
        - Conditionally invokes Invoke-HarborDeploymentPhase (when Context.SkipHarborDeployment is false).
        - Writes cluster and supervisor health reports.

        Rollback for supervisor, ArgoCD, and Harbor failures is handled internally. Returns $true
        when rollback completed and the caller should continue to the next site. Failures that occur
        before supervisor creation is attempted (e.g. ArgoCD YAML validation failure) are re-thrown
        so the caller's catch block can perform compute-level rollback.

        .PARAMETER Context
        Hashtable containing all state variables for the supervisor deployment sub-phase.
        Required keys:
          ArgoCdDeploymentYamlPath      - Path to the ArgoCD deployment YAML file.
          ArgoCDyaml                    - Path to the ArgoCD operator YAML file.
          ArgocdNameSpacePrefix         - Namespace prefix for ArgoCD (e.g. "argocd").
          ArgocdVmClass                 - VM class list for ArgoCD namespaces (or $null).
          Cluster                       - Cluster spec object from infrastructure.json.
          ClusterId                     - Cluster MoRef ID string.
          ClusterName                   - Effective cluster name.
          ClustersToProcessCount        - Total cluster count for this run (used for SingleSite detection).
          ContextName                   - VCF context name.
          CurrentEdgeSite               - Edge site identifier string.
          SkipArgoCDDeployment                 - Boolean: skip ArgoCD deployment when $true.
          SkipHarborDeployment                 - Boolean: skip Harbor deployment when $true.
          InfrastructureJson            - Path to infrastructure.json (used in YAML consistency error messages).
          InputData                     - Parsed infrastructure.json object.
          LabEnvironment                - Boolean: lab environment flag.
          NetworkSegments               - Network segments array for supervisor gateway mapping.
          PreserveAutoGeneratedKeyCert  - Boolean: save auto-generated key/cert pair to disk.
          SaveHarborYaml                - Boolean: save rendered Harbor data-values YAML after install.
          StoragePolicyId               - Storage policy MoRef ID.
          StoragePolicyName             - Storage policy display name.
          StoragePolicyType             - Storage policy type (vSAN-ESA, vSAN-OSA, VMFS).
          SupervisorJson                - Path to supervisor.json.
          VcenterCredential             - PSCredential used for vCenter REST API calls.

        .EXAMPLE
        $supervisorPhaseContext = @{
            ArgoCdDeploymentYamlPath = $argoCdDeploymentYamlPath
            ArgoCDyaml               = $argoCDyaml
            ArgocdNameSpacePrefix    = $argocdNameSpacePrefix
            # ... (all required keys)
        }
        $continueToNextSite = Invoke-SupervisorDeploymentPhase -Context $supervisorPhaseContext
        if ($continueToNextSite) { continue }

        .NOTES
        Internal helper for Initialize-VcfEdgeAtScale. Not intended for direct consumer use.
        Returns $true when rollback completed and the caller's foreach loop should continue to the
        next site. Returns $false on success. Throws VcfDeploymentException on unrecoverable failure.
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Hashtable]$Context
    )

    Assert-ContextKeys -CallerName "Invoke-SupervisorDeploymentPhase" -Context $Context `
        -RequiredKeys @("ArgoCdDeploymentYamlPath", "ArgocdNameSpacePrefix", "Cluster",
            "ClusterId", "ClusterName", "ClustersToProcessCount", "CurrentEdgeSite",
            "SkipArgoCDDeployment", "SkipHarborDeployment", "InfrastructureJson", "LabEnvironment",
            "NetworkSegments", "StoragePolicyId", "SupervisorJson", "VcenterCredential")

    $argocdNameSpace = $null
    $currentEdgeSite = $Context.CurrentEdgeSite
    $clusterName     = $Context.ClusterName
    $clusterId       = $Context.ClusterId
    $disableArgoCD   = $Context.SkipArgoCDDeployment
    $disableHarbor   = $Context.SkipHarborDeployment
    $isSingleSite    = $Context.ClustersToProcessCount -eq 1

    $supervisorCreatedThisSite           = $false
    $supervisorCreationAttemptedThisSite = $false
    $supervisorId      = $null
    $harborServiceName = $null

    try {
        # Initialize $argocdNameSpace to $null before the ArgoCD block. When ArgoCD is disabled the variable
        # stays $null, which the rollback catch block checks with IsNullOrWhiteSpace to skip ArgoCD rollback.
        # Without this initialization, a stale value from a prior cluster iteration could cause incorrect rollback.
        if (-not $disableArgoCD) {
            $argocdNameSpacePrefix    = $Context.ArgocdNameSpacePrefix
            $argoCdDeploymentYamlPath = $Context.ArgoCdDeploymentYamlPath
            $originalArgoCdNameSpace  = $argocdNameSpacePrefix
            Write-LogMessage -Type DEBUG -Message "Original ArgoCD namespace prefix from JSON: `"$originalArgoCdNameSpace`""

            $clusterObject    = Get-Cluster -Name $clusterName -Server $Script:vCenterName -ErrorAction Stop
            $argocdNameSpace  = Get-ArgoCDNamespaceFromCluster -ClusterObject $clusterObject -ClusterSpec $Context.Cluster
            Write-LogMessage -Type DEBUG -Message "Forming ArgoCD namespace name `"$argocdNameSpace`" from prefix `"$argocdNameSpacePrefix`" and cluster MoRef (domain stripped) to ensure uniqueness."

            Write-LogMessage -Type DEBUG -Message "Checking if the namespace value specified in `"$($Context.InfrastructureJson)`" is consistent with the namespace value specified in the ArgoCD deployment yaml file."
            $isValid = Test-YamlPropertyConsistency -yamlFilePath $argoCdDeploymentYamlPath -allowMissingProperties @("metadata.namespace") -expectedValues @($originalArgoCdNameSpace) -validationName "namespace consistency"
            if (-not $isValid) {
                Write-LogMessage -Type ERROR -Message "ArgoCD deployment YAML file validation failed. Please check the error messages above for details."
                Write-LogMessage -Type ERROR -Message "Common issues:"
                Write-LogMessage -Type ERROR -Message "  - The file path specified in infrastructure.json may be incorrect"
                Write-LogMessage -Type ERROR -Message "  - The file may not exist at the specified location"
                $errorMsg = "  - If using a relative path, ensure you're running from the correct directory"
                Write-LogMessage -Type ERROR -Message $errorMsg
                throw [VcfDeploymentException]::new($errorMsg)
            } else {
                Write-LogMessage -Type DEBUG -Message "The namespace specified in $($Context.InfrastructureJson) is consistent in the ArgoCD deployment yaml file."
            }
        }

        # Pass Context.VcenterCredential so the REST API always uses the credential that succeeded for Connect-Vcenter. See PASSWORD_HANDLING.md.
        $supervisorCreationAttemptedThisSite = $true
        $supervisorId = Get-OrCreateSupervisor `
            -StoragePolicyId $Context.StoragePolicyId `
            -SupervisorName  $Script:SupervisorName `
            -VcenterCredential $Context.VcenterCredential `
            -SupervisorJson  $Context.SupervisorJson `
            -ClusterId       $clusterId `
            -ClusterName     $clusterName `
            -EdgeSite        $currentEdgeSite `
            -NetworkSegments $Context.NetworkSegments `
            -SingleSite:$isSingleSite `
            -InsecureTls
        $supervisorCreatedThisSite = $true

        $harborServiceName = Invoke-PostSupervisorDeploymentActions `
            -ArgocdNameSpace $argocdNameSpace `
            -ClusterId $clusterId `
            -ClusterName $clusterName `
            -Context $Context `
            -CurrentEdgeSite $currentEdgeSite `
            -SkipArgoCDDeployment:$disableArgoCD `
            -SkipHarborDeployment:$disableHarbor `
            -IsSingleSite:$isSingleSite `
            -SupervisorId $supervisorId

        return $false
    } catch [RollbackSkippedException] {
        Write-LogMessage -Type WARNING -Message "Skipping rollback for edgeSite `"$currentEdgeSite`"; leaving site in current state. Continuing to next site."
        return $true
    } catch {
        return Invoke-SupervisorPhaseRollback `
            -ArgocdNameSpace $argocdNameSpace `
            -ClusterId $clusterId `
            -ClusterName $clusterName `
            -CurrentEdgeSite $currentEdgeSite `
            -HarborServiceName $harborServiceName `
            -IsSingleSite:$isSingleSite `
            -SupervisorCreatedThisSite:$supervisorCreatedThisSite `
            -SupervisorCreationAttemptedThisSite:$supervisorCreationAttemptedThisSite `
            -SupervisorId $supervisorId
    }
}
function Set-VsanDatastoreTagIfMissing {

    <#
    .SYNOPSIS
        Tags a vSAN datastore with the supervisor tag if the tag is not already assigned.
    .DESCRIPTION
        Gets the datastore by name, retrieves the tag from the specified catalog, and assigns it
        when absent. Returns $true when the tag was already present (fully idempotent re-run),
        $false when it was newly assigned. Throws VcfDeploymentException on datastore access failure.
    .PARAMETER DatastoreName
        Name of the vSAN datastore to tag.
    .PARAMETER StoragePolicyTagCatalog
        Tag category name for the storage policy tag.
    .PARAMETER StorageType
        Storage type string ("vSAN-ESA" or "vSAN-OSA") used for log context only.
    .EXAMPLE
        $alreadyProvisioned = Set-VsanDatastoreTagIfMissing -DatastoreName "vsanDatastore" -StoragePolicyTagCatalog "vSAN-ESA-Storage-TagCatalog" -StorageType "vSAN-ESA"
    .OUTPUTS
        [Bool] $true when tag was already present; $false when newly assigned.
    .NOTES
        Accesses $Script:vCenterName and $Script:SupervisorName. Called by Invoke-StorageProvisioningPhase.
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DatastoreName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$StoragePolicyTagCatalog,
        [Parameter(Mandatory = $true)] [ValidateSet("vSAN-ESA", "vSAN-OSA")] [String]$StorageType
    )

    try {
        $vsanDatastoreObject = Get-Datastore -Name $DatastoreName -Server $Script:vCenterName -ErrorAction Stop
    } catch [VcfDeploymentException] {
        throw
    } catch {
        $errorMsg = "Get-Datastore failed for $StorageType datastore `"$DatastoreName`": $($_.Exception.Message)."
        Write-LogMessage -Type ERROR -Message $errorMsg
        throw [VcfDeploymentException]::new($errorMsg)
    }
    $storagePolicyTagObject = Get-Tag -Name $Script:SupervisorName -Category $StoragePolicyTagCatalog -Server $Script:vCenterName -ErrorAction Stop
    $existingTagAssignment = Get-TagAssignment -Entity $vsanDatastoreObject -Server $Script:vCenterName -ErrorAction SilentlyContinue | Where-Object { $_.Tag.Id -eq $storagePolicyTagObject.Id }
    if ($existingTagAssignment) {
        Write-LogMessage -Type INFO -Message "$StorageType datastore `"$DatastoreName`" already has tag `"$Script:SupervisorName`" (catalog `"$StoragePolicyTagCatalog`") assigned. Skipping tag assignment."
        return $true
    }
    New-TagAssignment -Tag $storagePolicyTagObject -Entity $vsanDatastoreObject -Server $Script:vCenterName -ErrorAction Stop | Out-Null
    Write-LogMessage -Type INFO -Message "Successfully tagged $StorageType datastore `"$DatastoreName`" with tag `"$Script:SupervisorName`" (catalog `"$StoragePolicyTagCatalog`")."
    return $false
}
function Invoke-VsanPreProvisioningConfig {

    <#
    .SYNOPSIS
        Ensures vSAN cluster configuration is applied before storage provisioning.
    .DESCRIPTION
        Enables automatic disk claim when supported, then checks whether the vSAN automatic
        rebalance threshold is already at 30% and whether advanced configuration is in sync.
        Re-enables rebalancing and re-applies cluster config only when needed, reducing
        unnecessary vSAN churn on idempotent re-runs.
    .PARAMETER ClusterName
        Name of the cluster to check and configure.
    .EXAMPLE
        Invoke-VsanPreProvisioningConfig -ClusterName "cluster-site1"
    .NOTES
        Called by Invoke-StorageProvisioningPhase for vSAN-ESA and vSAN-OSA storage types.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName
    )

    Enable-VsanAutomaticDiskClaimIfSupported -ClusterName $ClusterName | Out-Null
    # Idempotent: only run rebalance/reapply when not already at desired state.
    $vsanHealthSummary = Get-VsanClusterHealthSummaryViaView -ClusterName $ClusterName -FetchFromCache:$false
    # When health summary is null (API unavailable), treat as in-sync so we skip reapply (idempotent).
    $advCfgInSync = if ($vsanHealthSummary) { Test-VsanClusterAdvCfgSyncInSync -HealthSummary $vsanHealthSummary } else { $true }
    $rebalanceAt30 = Test-VsanAutomaticRebalanceAtThreshold -ClusterName $ClusterName -ExpectedThresholdPercent 30
    $needRebalance = -not $rebalanceAt30
    $needReapply = -not $advCfgInSync
    if (-not $vsanHealthSummary) { Write-LogMessage -Type DEBUG -Message "vSAN health summary unavailable for cluster `"$ClusterName`"; treating advCfgSync as in-sync and skipping re-apply." }
    if ($needRebalance -or $needReapply) {
        Write-LogMessage -Type DEBUG -Message "Ensuring vSAN configuration is applied to all hosts in cluster `"$ClusterName`"."
        if ($needRebalance) {
            Enable-VsanAutomaticRebalance -ClusterName $ClusterName -AutomaticRebalanceThreshold 30 | Out-Null
        } else {
            Write-LogMessage -Type DEBUG -Message "vSAN automatic rebalancing already at 30% for cluster `"$ClusterName`". Skipping rebalance enablement."
        }
        if ($needReapply) {
            $vsanReapplySucceeded = Invoke-VsanClusterConfigReapply -ClusterName $ClusterName
            if (-not $vsanReapplySucceeded) { Write-LogMessage -Type WARNING -Message "Could not re-apply vSAN cluster configuration for cluster `"$ClusterName`". Proceeding with storage configuration; if hosts report vSAN disabled, check vCenter connectivity and retry." }
        } else {
            Write-LogMessage -Type DEBUG -Message "vSAN advanced config already in sync for cluster `"$ClusterName`". Skipping re-apply."
        }
    } else {
        Write-LogMessage -Type DEBUG -Message "vSAN configuration already applied (rebalance at 30%, advCfg in sync) for cluster `"$ClusterName`". Skipping."
    }
}
function Assert-StoragePolicyReady {

    <#
    .SYNOPSIS
        Verifies at least one datastore is compatible with the storage policy before supervisor enablement.
    .DESCRIPTION
        Calls Get-SpbmStoragePolicy and Get-SpbmCompatibleStorage to confirm the policy has at least
        one compatible datastore. Throws VcfDeploymentException when none exist so supervisor
        enablement does not proceed with an empty content library placement target.
    .PARAMETER StoragePolicyName
        Name of the storage policy to check.
    .PARAMETER StoragePolicyTagCatalog
        Tag catalog name for inclusion in the error message.
    .EXAMPLE
        Assert-StoragePolicyReady -StoragePolicyName "supervisor-site1" -StoragePolicyTagCatalog "vSAN-ESA-Storage-TagCatalog"
    .NOTES
        Called by Invoke-StorageProvisioningPhase.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$StoragePolicyName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$StoragePolicyTagCatalog
    )

    $storagePolicyObject = Get-SpbmStoragePolicy -Name $StoragePolicyName -Server $Script:vCenterName -ErrorAction Stop
    try {
        $compatibleStorage = Get-SpbmCompatibleStorage -StoragePolicy $storagePolicyObject -Server $Script:vCenterName -ErrorAction Stop
    } catch {
        $errMsg = $_.Exception.Message
        if ($_.Exception.InnerException) {
            Write-LogMessage -Type ERROR -Message "Get-SpbmCompatibleStorage failed for storage policy `"$StoragePolicyName`": $errMsg Inner: $($_.Exception.InnerException.Message)."
        } else {
            $errorMsg = "Get-SpbmCompatibleStorage failed for storage policy `"$StoragePolicyName`": $errMsg"
            Write-LogMessage -Type ERROR -Message $errorMsg
        }
        throw [VcfDeploymentException]::new($errorMsg)
    }
    if (-not $compatibleStorage -or $compatibleStorage.Count -eq 0) {
        Write-LogMessage -Type ERROR -Message "No compatible datastore found for storage policy `"$StoragePolicyName`" (required for supervisor Default Kubernetes Content Library)."
        $errorMsg = "Ensure a datastore is tagged with tag `"$Script:SupervisorName`" from catalog `"$StoragePolicyTagCatalog`" (same tag used by the policy)."
        Write-LogMessage -Type ERROR -Message $errorMsg
        throw [VcfDeploymentException]::new($errorMsg)
    }
    Write-LogMessage -Type DEBUG -Message "Storage policy `"$StoragePolicyName`" has $($compatibleStorage.Count) compatible datastore(s). Proceeding with supervisor enablement."
}
function Invoke-StorageProvisioningPhase {

    <#
        .SYNOPSIS
        Provisions storage for a cluster edge site and validates readiness before supervisor
        enablement.

        .DESCRIPTION
        Encapsulates all per-cluster storage steps that occur between VDS/networking setup and
        supervisor enablement. Handles three storage paths (vSAN-ESA, vSAN-OSA, VMFS), tags the
        target datastore, creates the storage policy, runs vLCM compliance remediation, enables the
        vSAN performance service and alarm check for vSAN clusters, then asserts the storage policy
        has at least one compatible datastore so the Default Kubernetes Content Library can bind.

        Returns $true when the datastore tag already existed, indicating a fully idempotent re-run
        where vLCM was already verified in a prior deployment. Returns $false when storage was
        created or updated this run.

        .PARAMETER Context
        Hashtable containing all per-cluster storage context keys:
          AcceptBadCheckResults   [Bool]   Pass $true to treat failed health checks as warnings.
          ClusterName             [String] Name of the vSphere cluster.
          CurrentEdgeSite         [String] Edge site identifier (used as preferred fault domain name).
          DatastoreName           [String] Target datastore name.
          DiskCanonicalName       [String] Canonical disk name for VMFS creation; $null for vSAN.
          EffectiveHaPolicy       [String] HA admission policy to pass to vSAN alarm remediation.
          EsxHosts                [Array]  List of ESX host names; first entry used for VMFS lookup.
          LabEnvironment          [Bool]   $true when operating in a lab environment.
          StoragePolicyName       [String] Name of the storage policy to create or update.
          StoragePolicyTagCatalog [String] Tag category name for the storage policy tag.
          StoragePolicyType       [String] Storage type: "vSAN-ESA", "vSAN-OSA", or "VMFS".
          VsanWitnessVmName       [String] vSAN witness VM name; $null for non-witness deployments.

        .EXAMPLE
        $storageContext = @{
            AcceptBadCheckResults   = $false
            ClusterName             = "cluster-vsan-edge1"
            CurrentEdgeSite         = "vsan-edge1"
            DatastoreName           = "datastore-vsan-edge1"
            DiskCanonicalName       = $null
            EffectiveHaPolicy       = "reservationBased"
            EsxHosts                = @("esx1.lab.local")
            LabEnvironment          = $false
            StoragePolicyName       = "supervisor-vsan-edge1"
            StoragePolicyTagCatalog = "vSAN-OSA-Storage-TagCatalog"
            StoragePolicyType       = "vSAN-OSA"
            VsanWitnessVmName       = "witness-vsan-edge1"
        }
        $storageAlreadyProvisioned = Invoke-StorageProvisioningPhase -Context $storageContext

        .NOTES
        Accesses $Script:SupervisorName and $Script:vCenterName as module-level variables.
        Throws [VcfDeploymentException] on unrecoverable failure.
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Hashtable]$Context
    )

    Assert-ContextKeys -CallerName "Invoke-StorageProvisioningPhase" -Context $Context `
        -RequiredKeys @("AcceptBadCheckResults", "ClusterName", "CurrentEdgeSite", "DatastoreName",
            "EffectiveHaPolicy", "EsxHosts", "LabEnvironment", "StoragePolicyName",
            "StoragePolicyTagCatalog", "StoragePolicyType")

    $storageAlreadyProvisioned = $false
    Write-LogMessage -Type DEBUG -Message "Storage policy type for cluster `"$($Context.ClusterName)`": `"$($Context.StoragePolicyType)`""
    if ($Context.StoragePolicyType -eq "vSAN-ESA" -or $Context.StoragePolicyType -eq "vSAN-OSA") {
        Invoke-VsanPreProvisioningConfig -ClusterName $Context.ClusterName
    }
    if ($Context.StoragePolicyType -eq "vSAN-ESA") {
        Write-LogMessage -Type DEBUG -Message "Configuring vSAN ESA storage pools for cluster `"$($Context.ClusterName)`"."
        if ($Context.VsanWitnessVmName) {
            Add-VsanEsaStoragePoolDisk -AcceptBadCheckResults:$Context.AcceptBadCheckResults -ClusterName $Context.ClusterName -DatastoreName $Context.DatastoreName -LabEnvironment:$Context.LabEnvironment -PreferredFaultDomainName $Context.CurrentEdgeSite -vSanWitnessVmName $Context.VsanWitnessVmName
        } else {
            Add-VsanEsaStoragePoolDisk -AcceptBadCheckResults:$Context.AcceptBadCheckResults -ClusterName $Context.ClusterName -DatastoreName $Context.DatastoreName -LabEnvironment:$Context.LabEnvironment
        }
        # Tag the vSAN ESA datastore with the supervisor tag so SPBM can match it.
        $storageAlreadyProvisioned = Set-VsanDatastoreTagIfMissing -DatastoreName $Context.DatastoreName -StoragePolicyTagCatalog $Context.StoragePolicyTagCatalog -StorageType "vSAN-ESA"
    }
    elseif ($Context.StoragePolicyType -eq "vSAN-OSA") {
        Write-LogMessage -Type DEBUG -Message "Configuring vSAN OSA disk groups for cluster `"$($Context.ClusterName)`"."
        if ($Context.VsanWitnessVmName) {
            Add-VsanOsaDiskGroupToCluster -AcceptBadCheckResults:$Context.AcceptBadCheckResults -ClusterName $Context.ClusterName -DatastoreName $Context.DatastoreName -LabEnvironment:$Context.LabEnvironment -PreferredFaultDomainName $Context.CurrentEdgeSite -vSanWitnessVmName $Context.VsanWitnessVmName
        } else {
            Add-VsanOsaDiskGroupToCluster -AcceptBadCheckResults:$Context.AcceptBadCheckResults -ClusterName $Context.ClusterName -DatastoreName $Context.DatastoreName -LabEnvironment:$Context.LabEnvironment
        }
        # Tag the vSAN OSA datastore with the supervisor tag so SPBM can match it.
        $storageAlreadyProvisioned = Set-VsanDatastoreTagIfMissing -DatastoreName $Context.DatastoreName -StoragePolicyTagCatalog $Context.StoragePolicyTagCatalog -StorageType "vSAN-OSA"
    }
    else {
        # Create VMFS Datastore on the first ESX host (all hosts should have access).
        $firstEsxHost = $Context.EsxHosts[0]
        try {
            $esxHostObject = Get-VMHost -Name $firstEsxHost -Server $Script:vCenterName -ErrorAction SilentlyContinue
        } catch [VcfDeploymentException] {
            throw  # already logged and typed — propagate without re-wrapping
        } catch {
            $errorMsg = "Failed to get the ESX host `"$firstEsxHost`" on vCenter `"$Script:vCenterName`": $($_.Exception.Message)"
            Write-LogMessage -Type ERROR -Message $errorMsg
            throw [VcfDeploymentException]::new($errorMsg)
        }
        $storageAlreadyProvisioned = Set-NewDatastore -DatastoreName $Context.DatastoreName -EsxHost $esxHostObject -DiskCanonicalName $Context.DiskCanonicalName -TagName $Script:SupervisorName
    }

    # Create storage policy for all storage types (tag-based placement; datastore must have the tag). VMFS uses default RuleValue "Fully initialized" in Set-StoragePolicy.
    $setStoragePolicyParams = @{
        PolicyName  = $Context.StoragePolicyName
        StorageType = $Context.StoragePolicyType
        TagCatalog  = $Context.StoragePolicyTagCatalog
        TagName     = $Script:SupervisorName
    }
    Set-StoragePolicy @setStoragePolicyParams

    # Skipped when storage was already provisioned, meaning this is a fully idempotent re-run where
    # vLCM was already verified previously.
    if (-not $storageAlreadyProvisioned) {
        Invoke-VlcmClusterComplianceAndRemediate -AcceptBadCheckResults:$Context.AcceptBadCheckResults -ClusterName $Context.ClusterName
        Write-Progress -Activity "Task created by VMware vSphere Lifecycle Manager" -Completed
        [Console]::Out.Flush()
    } else {
        Write-LogMessage -Type DEBUG -Message "Skipping vLCM compliance check for cluster `"$($Context.ClusterName)`": storage was already provisioned in a prior run."
    }

    # Always enable vSAN performance service for vSAN clusters; then query alarms and fix fixable ones (e.g. advanced config sync). "vSphere HA host status" is auto-remediated by re-applying HA/DRS when detected.
    if ($Context.StoragePolicyType -eq "vSAN-ESA" -or $Context.StoragePolicyType -eq "vSAN-OSA") {
        Enable-VsanPerformanceService -ClusterName $Context.ClusterName
        Invoke-VsanClusterAlarmCheckAndRemediate -AcceptBadCheckResults:$Context.AcceptBadCheckResults -ClusterName $Context.ClusterName -HaPolicy $Context.EffectiveHaPolicy -LabEnvironment:$Context.LabEnvironment
    }

    # Verify at least one compatible datastore exists before enabling supervisor.
    Assert-StoragePolicyReady -StoragePolicyName $Context.StoragePolicyName -StoragePolicyTagCatalog $Context.StoragePolicyTagCatalog
    return $storageAlreadyProvisioned
}
function Invoke-VmfsEsxDiscovery {

    <#
        .SYNOPSIS
        Connects to each VMFS ESX host, checks the ESX version, and discovers the target datastore.

        .DESCRIPTION
        Iterates Context.EsxHosts, connects to each host, validates the ESX version (minimum 9.0.0),
        and calls Find-Datastore to locate the target VMFS datastore. Includes a one-shot retry that
        re-prompts the operator when the ESX_COMMON_PASSWORD environment variable was used and
        authentication fails. EsxPasswords and EsxVersionChecked are reference-typed hashtables and
        are mutated in place so the caller sees updated credentials after this function returns.
        Throws VcfDeploymentException when any host cannot be reached or version check fails.

        .PARAMETER Context
        Hashtable with DatastoreName, EsxHosts, EsxPasswords, EsxUser, EsxVersionChecked keys (see
        Invoke-EsxCredentialAndDatastoreSetup for full schema).

        .PARAMETER EsxPasswords
        Per-host credential map. Mutated in place with any re-prompted credentials.

        .PARAMETER EsxUsedEnvPassword
        Whether ESX_COMMON_PASSWORD was used. Set to $false in the returned hashtable when the
        operator re-enters the password at the fallback prompt.

        .PARAMETER EsxVersionChecked
        Per-host version-check state. Mutated in place.

        .EXAMPLE
        $vmfsResult = Invoke-VmfsEsxDiscovery -Context $ctx -EsxPasswords $esxPasswords -EsxVersionChecked $esxVersionChecked -EsxUsedEnvPassword:$false

        .NOTES
        Deployment helper — throws VcfDeploymentException on failure.
        Write-Host is the primary output mechanism in this function; all Write-Host calls are
        intentional interactive console output. Use Write-LogMessage for diagnostic logging.
    #>

    [CmdletBinding()]
    [OutputType([Hashtable])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Hashtable]$Context,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Hashtable]$EsxPasswords,
        [Parameter(Mandatory = $false)] [Switch]$EsxUsedEnvPassword,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Hashtable]$EsxVersionChecked
    )

    Assert-ContextKeys -CallerName "Invoke-VmfsEsxDiscovery" -Context $Context `
        -RequiredKeys @("DatastoreName", "EsxHosts", "EsxUser")

    $diskCanonicalNames = @{}
    $esxConnectionFailed = $false

    foreach ($esxHost in $Context.EsxHosts) {
        if (-not $EsxPasswords[$esxHost]) {
            $esxPassword = Get-InteractiveInput -PromptMessage "`nEnter the password for the user `"$($Context.EsxUser)`" on ESX Host: $esxHost" -AsSecureString -AllowEmpty
            $EsxPasswords[$esxHost] = New-Object System.Management.Automation.PSCredential($Context.EsxUser, $esxPassword)
        }
        try {
            Connect-Vcenter -ServerName $esxHost -ServerCredential $EsxPasswords[$esxHost] -ServerType "ESX"
            if (-not $EsxVersionChecked[$esxHost]) {
                $esxVerResult = Test-ESXVersion -ServerName $esxHost -MinimumVersion "9.0.0"
                if (-not $esxVerResult.Success) {
                    Write-LogMessage -Type ERROR -Message $esxVerResult.ErrorMessage
                    throw [VcfDeploymentException]::new($esxVerResult.ErrorMessage)
                }
                $EsxVersionChecked[$esxHost] = $true
            }
            $foundName = Find-Datastore -DatastoreName $Context.DatastoreName -EsxHostName $esxHost
            if ($foundName) { $diskCanonicalNames[$esxHost] = $foundName }
        } catch {
            $errorMessage = $_.Exception.Message
            if ($errorMessage -match "Authentication failed" -and $EsxUsedEnvPassword) {
                Write-LogMessage -Type WARNING -Message "ESX authentication with ESX_COMMON_PASSWORD failed; falling back to password prompt."
                $hostList = $Context.EsxHosts -join ", "
                $esxPassword = Get-InteractiveInput -PromptMessage "`nEnter the password for the user `"$($Context.EsxUser)`" on ESX Host(s): $hostList" -AsSecureString -AllowEmpty
                foreach ($esxHostName in $Context.EsxHosts) {
                    $EsxPasswords[$esxHostName] = New-Object System.Management.Automation.PSCredential($Context.EsxUser, $esxPassword)
                }
                $EsxUsedEnvPassword = $false
                try {
                    Connect-Vcenter -ServerName $esxHost -ServerCredential $EsxPasswords[$esxHost] -ServerType "ESX"
                    if (-not $EsxVersionChecked[$esxHost]) {
                        $esxVerResult = Test-ESXVersion -ServerName $esxHost -MinimumVersion "9.0.0"
                        if (-not $esxVerResult.Success) {
                            Write-LogMessage -Type ERROR -Message $esxVerResult.ErrorMessage
                            throw [VcfDeploymentException]::new($esxVerResult.ErrorMessage)
                        }
                        $EsxVersionChecked[$esxHost] = $true
                    }
                    $foundName = Find-Datastore -DatastoreName $Context.DatastoreName -EsxHostName $esxHost
                    if ($foundName) { $diskCanonicalNames[$esxHost] = $foundName }
                } catch {
                    $esxConnectionFailed = $true
                }
            } elseif ($errorMessage -match "Authentication failed") {
                $esxConnectionFailed = $true
                continue
            } else {
                Write-LogMessage -Type ERROR -Message "ESX host `"$esxHost`" could not be reached or datastore `"$($Context.DatastoreName)`" not found: $errorMessage"
                $esxConnectionFailed = $true
            }
        }
        finally {
            # Always disconnect ESX (if connected), even on errors.
            Disconnect-Vcenter -ServerName $esxHost -ServerType "ESX" -Silence
        }
    }

    if ($esxConnectionFailed) {
        $errorMsg = "One or more ESX hosts could not be connected or verified. Check logs for details."
        Write-LogMessage -Type ERROR -Message $errorMsg
        throw [VcfDeploymentException]::new($errorMsg)
    }

    $diskCanonicalName = if ($diskCanonicalNames.Count -gt 0) { ($diskCanonicalNames.Values | Select-Object -First 1) } else { $null }
    return @{ DiskCanonicalName = $diskCanonicalName; EsxUsedEnvPassword = $EsxUsedEnvPassword }
}
function Invoke-EsxPasswordReprompt {

    <#
        .SYNOPSIS
        Prompts the operator to re-enter ESX credentials after an authentication failure.

        .DESCRIPTION
        Asks the operator whether they want to retry, then collects a new password — either a single
        shared password (when Context.EsxUniquePassword is $true) or per-host passwords for each
        failed host. Updates EsxPasswords in place. Throws VcfDeploymentException when the operator
        declines to retry.

        .PARAMETER Context
        Hashtable with EsxHosts, EsxUniquePassword, and EsxUser keys.

        .PARAMETER EsxPasswords
        Per-host credential map. Mutated in place with the new credentials.

        .PARAMETER FailedAuthHosts
        Array of host names whose authentication failed in this validation pass.

        .EXAMPLE
        Invoke-EsxPasswordReprompt -Context $ctx -EsxPasswords $esxPasswords -FailedAuthHosts $failedAuthHosts

        .NOTES
        Deployment helper — throws VcfDeploymentException when the operator declines to retry.
        Write-Host is the primary output mechanism in this function; all Write-Host calls are
        intentional interactive console output. Use Write-LogMessage for diagnostic logging.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Hashtable]$Context,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Hashtable]$EsxPasswords,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object[]]$FailedAuthHosts
    )

    Assert-ContextKeys -CallerName "Invoke-EsxPasswordReprompt" -Context $Context `
        -RequiredKeys @("EsxHosts", "EsxUniquePassword", "EsxUser")

    Write-Host ""
    $retryResponse = $null
    while ($retryResponse -ne "Y" -and $retryResponse -ne "N") {
        $retryResponse = Read-Host "Would you like to re-enter your password? (Y/N)"
        $retryResponse = $retryResponse.Trim().ToUpper()
    }
    if ($retryResponse -ne "Y") {
        $errorMsg = "User chose not to retry. Exiting."
        Write-LogMessage -Type ERROR -Message $errorMsg
        throw [VcfDeploymentException]::new($errorMsg)
    }
    Write-Host ""
    if ($Context.EsxUniquePassword) {
        $hostList = $Context.EsxHosts -join ", "
        $promptMessage = ("Enter the password for the user `"$($Context.EsxUser)`" on ESX `"$hostList`" (or press Enter for no password): ").TrimEnd(": ")
        $newEsxPassword = Get-InteractiveInput -PromptMessage $promptMessage -AsSecureString -AllowEmpty
        Write-Host ""
        foreach ($esxHost in $Context.EsxHosts) {
            $EsxPasswords[$esxHost] = New-Object System.Management.Automation.PSCredential($Context.EsxUser, $newEsxPassword)
        }
    } else {
        foreach ($esxHost in $FailedAuthHosts) {
            $promptMessage = "Enter the password for the user `"$($Context.EsxUser)`" on ESX Host: $esxHost (or press Enter for no password): "
            $newEsxPassword = Get-InteractiveInput -PromptMessage $promptMessage -AsSecureString -AllowEmpty
            Write-Host ""
            $EsxPasswords[$esxHost] = New-Object System.Management.Automation.PSCredential($Context.EsxUser, $newEsxPassword)
        }
    }
}
function Invoke-VsanEsxCredentialValidation {

    <#
        .SYNOPSIS
        Validates ESX host credentials for vSAN clusters with interactive retry on authentication failure.

        .DESCRIPTION
        Runs up to MaxValidationRetries credential validation passes against all hosts in Context.EsxHosts.
        On authentication failure, prompts the operator to re-enter the password (shared or per-host)
        and retries. Non-authentication errors (host unreachable) are treated as terminal. Throws
        VcfDeploymentException when validation cannot complete successfully.

        .PARAMETER Context
        Hashtable with EsxHosts, EsxPasswords, EsxUniquePassword, EsxUser, and EsxVersionChecked keys
        (see Invoke-EsxCredentialAndDatastoreSetup for full schema).

        .PARAMETER EsxPasswords
        Per-host credential map. Mutated in place with any re-prompted credentials.

        .PARAMETER EsxVersionChecked
        Per-host version-check state. Mutated in place.

        .PARAMETER MaxValidationRetries
        Maximum number of credential validation retry loops before throwing.

        .EXAMPLE
        $esxUsedEnvPassword = Invoke-VsanEsxCredentialValidation -Context $ctx -EsxPasswords $esxPasswords -EsxVersionChecked $esxVersionChecked -MaxValidationRetries 3

        .NOTES
        Deployment helper — throws VcfDeploymentException on failure.
        Write-Host is the primary output mechanism in this function; all Write-Host calls are
        intentional interactive console output. Use Write-LogMessage for diagnostic logging.
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Hashtable]$Context,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Hashtable]$EsxPasswords,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Hashtable]$EsxVersionChecked,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 10)] [Int]$MaxValidationRetries = 3
    )

    Assert-ContextKeys -CallerName "Invoke-VsanEsxCredentialValidation" -Context $Context `
        -RequiredKeys @("EsxHosts", "EsxUser", "StoragePolicyType")

    Write-LogMessage -Type DEBUG -Message "Skipping datastore finding for storage policy type `"$($Context.StoragePolicyType)`" (vSAN workflows use different disk selection)."
    Write-LogMessage -Type DEBUG -Message "Validating ESX host credentials for vSAN cluster..."

    $esxUsedEnvPassword = $false
    $validationRetryCount = 0

    while ($validationRetryCount -lt $MaxValidationRetries) {
        $esxConnectionFailed = $false
        $authenticationFailed = $false
        $failedAuthHosts = [System.Collections.Generic.List[String]]::new()

        foreach ($esxHost in $Context.EsxHosts) {
            if (-not $EsxPasswords[$esxHost]) {
                $esxPassword = Get-InteractiveInput -PromptMessage "`nEnter the password for the user `"$($Context.EsxUser)`" on ESX Host: $esxHost" -AsSecureString -AllowEmpty
                $EsxPasswords[$esxHost] = New-Object System.Management.Automation.PSCredential($Context.EsxUser, $esxPassword)
            }
            try {
                Connect-Vcenter -ServerName $esxHost -ServerCredential $EsxPasswords[$esxHost] -ServerType "ESX" -SkipRetryPrompt
                if (-not $EsxVersionChecked[$esxHost]) {
                    $esxVerResult = Test-ESXVersion -ServerName $esxHost -MinimumVersion "9.0.0"
                    if (-not $esxVerResult.Success) {
                        Write-LogMessage -Type ERROR -Message $esxVerResult.ErrorMessage
                        throw [VcfDeploymentException]::new($esxVerResult.ErrorMessage)
                    }
                    $EsxVersionChecked[$esxHost] = $true
                }
                Write-LogMessage -Type DEBUG -Message "Successfully validated credentials for ESX host `"$esxHost`"."
            } catch {
                $errorMessage = $_.Exception.Message
                if ($errorMessage -match "Authentication failed|incorrect user name or password") {
                    Write-LogMessage -Type ERROR -Message "Failed to connect to ESX `"$esxHost`": Authentication failed."
                    $authenticationFailed = $true
                    $esxConnectionFailed = $true
                    if ($failedAuthHosts -notcontains $esxHost) { $failedAuthHosts.Add($esxHost) }
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

        if (-not $esxConnectionFailed) { break }

        if ($authenticationFailed -and $validationRetryCount -lt ($MaxValidationRetries - 1)) {
            Invoke-EsxPasswordReprompt -Context $Context -EsxPasswords $EsxPasswords -FailedAuthHosts $failedAuthHosts
            $validationRetryCount++
            Write-LogMessage -Type INFO -Message "Retrying credential validation with new password..."
        } else {
            $errorMsg = "Maximum retry attempts reached or non-authentication error occurred."
            Write-LogMessage -Type ERROR -Message $errorMsg
            throw [VcfDeploymentException]::new($errorMsg)
        }
    }

    return $esxUsedEnvPassword
}
function Invoke-EsxCredentialAndDatastoreSetup {

    <#
        .SYNOPSIS
        Validates ESX host credentials and discovers the target VMFS datastore (or validates
        vSAN credentials only) for a single cluster edge site before cluster creation.

        .DESCRIPTION
        Encapsulates the per-cluster ESX host connect/disconnect loop that runs immediately before
        cluster creation in the deployment workflow. For VMFS clusters, delegates to
        Invoke-VmfsEsxDiscovery; for vSAN clusters, delegates to Invoke-VsanEsxCredentialValidation.

        Returns a hashtable with two keys:
          DiskCanonicalName   — the first discovered disk canonical name for VMFS clusters; $null
                                for vSAN clusters where no datastore discovery is performed.
          EsxUsedEnvPassword  — the (possibly updated) flag indicating whether the ESX_COMMON_PASSWORD
                                environment variable was used. Set to $false when a fallback prompt
                                replaces the env-variable credential.

        $EsxPasswords and $EsxVersionChecked are hashtable references passed in via the $Context
        parameter and are modified in place; the caller sees the updated credentials and version
        check results after this function returns.

        .PARAMETER Context
        Hashtable containing all per-cluster ESX setup context keys:
          DatastoreName       [String]    Target datastore name (VMFS clusters only).
          EsxHosts            [Array]     List of ESX host names to connect to.
          EsxPasswords        [Hashtable] Per-host credential map; modified in place with any newly
                                          prompted credentials.
          EsxUniquePassword   [Bool]      When $true, all hosts share one password; when $false, each
                                          host is prompted individually on auth failure.
          EsxUsedEnvPassword  [Bool]      $true when ESX_COMMON_PASSWORD was used to pre-fill
                                          credentials; $false otherwise.
          EsxUser             [String]    ESX user account name for credential prompts.
          EsxVersionChecked   [Hashtable] Per-host version-check state; modified in place.
          MaxValidationRetries[Int]       Maximum credential retry loops for vSAN clusters. Default 3.
          StoragePolicyType   [String]    Storage type: "vSAN-ESA", "vSAN-OSA", or "VMFS".

        .EXAMPLE
        $esxContext = @{
            DatastoreName        = "datastore-vmfs-edge1"
            EsxHosts             = @("esx1.lab.local", "esx2.lab.local")
            EsxPasswords         = $esxPasswords
            EsxUniquePassword    = $true
            EsxUsedEnvPassword   = $false
            EsxUser              = "root"
            EsxVersionChecked    = $esxVersionChecked
            MaxValidationRetries = 3
            StoragePolicyType    = "VMFS"
        }
        $esxSetupResult = Invoke-EsxCredentialAndDatastoreSetup -Context $esxContext
        $diskCanonicalName  = $esxSetupResult.DiskCanonicalName
        $esxUsedEnvPassword = $esxSetupResult.EsxUsedEnvPassword

        .NOTES
        Throws [VcfDeploymentException] when any ESX host cannot be reached, fails version checks,
        or exhausts all credential retry attempts.
        Write-Host is the primary output mechanism in this function; all Write-Host calls are
        intentional interactive console output. Use Write-LogMessage for diagnostic logging.
    #>

    [CmdletBinding()]
    [OutputType([Hashtable])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Hashtable]$Context
    )

    Assert-ContextKeys -CallerName "Invoke-EsxCredentialAndDatastoreSetup" -Context $Context `
        -RequiredKeys @("EsxHosts", "EsxPasswords", "EsxUniquePassword", "EsxUsedEnvPassword",
            "EsxVersionChecked", "StoragePolicyType")

    $esxPasswords         = $Context.EsxPasswords      # hashtable ref — mutations visible to caller
    $esxVersionChecked    = $Context.EsxVersionChecked # hashtable ref — mutations visible to caller
    $esxUsedEnvPassword   = $Context.EsxUsedEnvPassword
    $maxValidationRetries = if ($Context.ContainsKey("MaxValidationRetries")) { $Context.MaxValidationRetries } else { 3 }

    if ($Context.StoragePolicyType -ne "vSAN-ESA" -and $Context.StoragePolicyType -ne "vSAN-OSA") {
        $vmfsResult = Invoke-VmfsEsxDiscovery `
            -Context             $Context `
            -EsxPasswords        $esxPasswords `
            -EsxVersionChecked   $esxVersionChecked `
            -EsxUsedEnvPassword:$esxUsedEnvPassword
        return @{
            DiskCanonicalName  = $vmfsResult.DiskCanonicalName
            EsxUsedEnvPassword = $vmfsResult.EsxUsedEnvPassword
        }
    }

    $esxUsedEnvPassword = Invoke-VsanEsxCredentialValidation `
        -Context              $Context `
        -EsxPasswords         $esxPasswords `
        -EsxVersionChecked    $esxVersionChecked `
        -MaxValidationRetries $maxValidationRetries
    return @{
        DiskCanonicalName  = $null
        EsxUsedEnvPassword = $esxUsedEnvPassword
    }
}
function Invoke-ClusterPreSupervisorPhase {

    <#
        .SYNOPSIS
        Runs all per-cluster steps that must complete between host networking and supervisor
        enablement: tag catalog, HA reconfiguration, storage provisioning, ID resolution, and
        the ComputeOnly early-exit path.

        .DESCRIPTION
        Executes the post-networking, pre-supervisor phase for a single cluster edge site:
          1. Creates the storage tag catalog category and tag via Test-TagCatalogCategory and Test-Tag.
          2. Reconfigures HA (via Invoke-ReconfigureClusterHA) only when vmk0 was migrated to the VDS
             during this run ($Script:DidMigrateVmk0ToVdsThisRun is true).
          3. Resolves the vSAN witness VM name (cluster level overrides common; ignored for VMFS).
          4. Invokes Invoke-StorageProvisioningPhase to set up vSAN-ESA/OSA/VMFS storage, create the
             storage policy, validate vLCM compliance, and assert storage policy compatibility.
          5. Retrieves the cluster MoRef ID and storage policy ID.
          6. When Context.ComputeOnly is true, runs health reports and signals the caller to skip to
             the next site (returns ShouldContinue = $true).

        .PARAMETER Context
        Hashtable containing all inputs for this phase:
          AcceptBadCheckResults — pass-through to Invoke-StorageProvisioningPhase
          Cluster               — cluster PSCustomObject (for vSanWitnessVmName resolution)
          ClusterName           — resolved cluster name string
          ComputeOnly           — when $true, health reports run and ShouldContinue is returned $true
          CurrentEdgeSite       — edge site label for log messages
          DatastoreName         — resolved datastore name
          DiskCanonicalName     — VMFS canonical name from Invoke-EsxCredentialAndDatastoreSetup (null for vSAN)
          EffectiveHaPolicy     — HA admission policy string (e.g. "reservationBased" or "disabled")
          EsxHosts              — ordered array of ESX host FQDNs/IPs for this cluster
          InputData             — parsed infrastructure.json PSCustomObject (for common.vSanWitnessVmName)
          LabEnvironment        — $true when labenvironment=true (passed to storage phase)
          StoragePolicyName     — resolved storage policy name (null when no storage policy configured)
          StoragePolicyTagCatalog — resolved tag catalog name
          StoragePolicyType     — "vSAN-ESA", "vSAN-OSA", or "VMFS"
          SupervisorName        — resolved supervisor name (used as tag name in Test-Tag)

        .EXAMPLE
        $preSupervisorCtx = @{
            AcceptBadCheckResults = $false
            Cluster               = $cluster
            ClusterName           = $clusterName
            ComputeOnly           = $false
            CurrentEdgeSite       = "vsan-edge1"
            DatastoreName         = "datastore-vsan-edge1"
            DiskCanonicalName     = $null
            EffectiveHaPolicy     = "reservationBased"
            EsxHosts              = @("esx1.lab.local")
            InputData             = $inputData
            LabEnvironment        = $false
            StoragePolicyName     = "supervisor-vsan-edge1"
            StoragePolicyTagCatalog = "vSAN-OSA-Storage-TagCatalog"
            StoragePolicyType     = "vSAN-OSA"
            SupervisorName        = "supervisor-vsan-edge1"
        }
        $preSupervisorResult = Invoke-ClusterPreSupervisorPhase -Context $preSupervisorCtx
        if ($preSupervisorResult.ShouldContinue) { continue }
        $clusterId      = $preSupervisorResult.ClusterId
        $storagePolicyId = $preSupervisorResult.StoragePolicyId

        .NOTES
        Returns a hashtable with:
          ClusterId        — cluster MoRef ID string (may be $null when ComputeOnly is true and
                             the ID was not needed)
          StoragePolicyId  — storage policy ID string (may be $null when ComputeOnly or no policy)
          ShouldContinue   — $true when ComputeOnly triggered; caller must then call 'continue' to
                             skip to the next cluster
        Reads $Script:DidMigrateVmk0ToVdsThisRun from module scope to decide whether to run HA
        reconfiguration; reads $Script:HaNetworkStabilizationDelaySeconds for the reconfigure delay.
        Sets $Script:SupervisorName as a side effect so downstream storage tag helpers resolve
        the correct name without requiring an additional parameter pass-through.
    #>

    [CmdletBinding()]
    [OutputType([Hashtable])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Hashtable]$Context
    )

    Assert-ContextKeys -CallerName "Invoke-ClusterPreSupervisorPhase" -Context $Context `
        -RequiredKeys @("AcceptBadCheckResults", "Cluster", "ClusterName", "ComputeOnly",
            "CurrentEdgeSite", "DatastoreName", "EffectiveHaPolicy",
            "EsxHosts", "InputData", "LabEnvironment", "StoragePolicyName",
            "StoragePolicyTagCatalog", "StoragePolicyType", "SupervisorName")

    $acceptBadCheckResults  = $Context.AcceptBadCheckResults
    $cluster                = $Context.Cluster
    $clusterName            = $Context.ClusterName
    $computeOnly            = $Context.ComputeOnly
    $currentEdgeSite        = $Context.CurrentEdgeSite
    $datastoreName          = $Context.DatastoreName
    $diskCanonicalName      = $Context.DiskCanonicalName
    $effectiveHaPolicy      = $Context.EffectiveHaPolicy
    $esxHosts               = $Context.EsxHosts
    $inputData              = $Context.InputData
    $labEnvironment         = $Context.LabEnvironment
    $storagePolicyName      = $Context.StoragePolicyName
    $storagePolicyTagCatalog = $Context.StoragePolicyTagCatalog
    $storagePolicyType      = $Context.StoragePolicyType
    $supervisorName         = $Context.SupervisorName

    Test-TagCatalogCategory -TagCatalog $storagePolicyTagCatalog
    Test-Tag -TagCatalog $storagePolicyTagCatalog -TagName $supervisorName

    # Reconfigure HA only when we moved vmk0 to the VDS this run so vCenter uses the management network for HA heartbeats.
    if ($Script:DidMigrateVmk0ToVdsThisRun) {
        Write-LogMessage -Type DEBUG -Message "Reconfiguring $clusterName for HA after moving vmk0 to vDS..."
        Invoke-ReconfigureClusterHA -ClusterName $clusterName -DelaySeconds $Script:HaNetworkStabilizationDelaySeconds -HaPolicy $effectiveHaPolicy
    } else {
        Write-LogMessage -Type DEBUG -Message "No vmk0 migration performed this run for cluster `"$clusterName`". Skipping HA reconfiguration (idempotent)."
    }

    # Extract vSAN witness host (vSanWitnessVmName; cluster root overrides common).
    # For non-vSAN clusters (e.g. VMFS), any configured witness is discarded here so
    # downstream vSAN branches never receive an irrelevant witness name.
    $vSanWitnessVmName = $null
    if (-not [String]::IsNullOrWhiteSpace($cluster.vSanWitnessVmName)) {
        $vSanWitnessVmName = $cluster.vSanWitnessVmName
    } elseif (-not [String]::IsNullOrWhiteSpace($inputData.common.vSanWitnessVmName)) {
        $vSanWitnessVmName = $inputData.common.vSanWitnessVmName
    }
    if ($vSanWitnessVmName -and ($storagePolicyType -ne "vSAN-ESA" -and $storagePolicyType -ne "vSAN-OSA")) {
        Write-LogMessage -Type DEBUG -Message "vSAN witness `"$vSanWitnessVmName`" is configured for edgeSite `"$currentEdgeSite`" but is not required for `"$storagePolicyType`"; ignoring."
        $vSanWitnessVmName = $null
    }

    # Provision storage (vSAN-ESA/OSA/VMFS), create storage policy, validate vLCM compliance,
    # and assert storage policy compatibility before supervisor enablement.
    $storageProvisioningContext = @{
        AcceptBadCheckResults   = $acceptBadCheckResults
        ClusterName             = $clusterName
        CurrentEdgeSite         = $currentEdgeSite
        DatastoreName           = $datastoreName
        DiskCanonicalName       = $diskCanonicalName
        EffectiveHaPolicy       = $effectiveHaPolicy
        EsxHosts                = $esxHosts
        LabEnvironment          = $labEnvironment
        StoragePolicyName       = $storagePolicyName
        StoragePolicyTagCatalog = $storagePolicyTagCatalog
        StoragePolicyType       = $storagePolicyType
        VsanWitnessVmName       = $vSanWitnessVmName
    }
    $null = Invoke-StorageProvisioningPhase -Context $storageProvisioningContext

    $clusterId = Get-ClusterId -ClusterName $clusterName

    $storagePolicyId = Get-StoragePolicyId -StoragePolicyName $storagePolicyName

    if ($computeOnly) {
        Write-LogMessage -Type INFO -Message "ComputeOnly is set. Pre-supervisor steps complete for cluster `"$clusterName`". Skipping supervisor, Argo CD, Harbor, and other post-supervisor steps."
        if ($storagePolicyType -eq "vSAN-ESA" -or $storagePolicyType -eq "vSAN-OSA") {
            Invoke-VsanClusterHealthRetestAfterDeployment -ClusterName $clusterName
            Write-VsanClusterHealthReport -ClusterName $clusterName
        }
        Write-ClusterEsxiNodeHealthReport -ClusterName $clusterName
        return @{ ClusterId = $clusterId; StoragePolicyId = $storagePolicyId; ShouldContinue = $true }
    }

    return @{ ClusterId = $clusterId; StoragePolicyId = $storagePolicyId; ShouldContinue = $false }
}
function Set-VsanTrafficOnClusterHosts {

    <#
    .SYNOPSIS
        Clears vSAN traffic from vmk0 and ensures vSAN witness traffic on all data hosts post-VDS.
    .DESCRIPTION
        For each data host in the cluster: removes vSAN (not witness) traffic from vmk0 when present,
        enables vSAN witness on vmk0 when no dedicated vSAN Witness VMkernel exists, then retries the
        vSAN/witness compliance check until the interface is compliant or retries are exhausted.
        Throws VcfDeploymentException when a host remains non-compliant.
    .PARAMETER ClusterName
        Name of the cluster whose hosts are being configured.
    .PARAMETER HasDedicatedVsanWitness
        Non-null/non-empty when a dedicated vSAN Witness VMkernel is configured; controls whether
        witness traffic is added to vmk0.
    .PARAMETER VsanRecheckDelaySeconds
        Seconds to wait between re-check attempts after the initial delay.
    .PARAMETER VsanRecheckInitialDelaySeconds
        Seconds to wait before the first re-check when the compliance check initially fails.
    .PARAMETER VsanRecheckRetryCount
        Maximum number of re-check retries after the initial delay.
    .EXAMPLE
        Set-VsanTrafficOnClusterHosts -ClusterName "cl1" -HasDedicatedVsanWitness $null -VsanRecheckDelaySeconds 5 -VsanRecheckInitialDelaySeconds 10 -VsanRecheckRetryCount 3
    .NOTES
        Uses $Script:vCenterName. Throws VcfDeploymentException on unrecoverable non-compliance.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] $HasDedicatedVsanWitness,
        [Parameter(Mandatory = $true)] [ValidateRange(1, 300)] [Int]$VsanRecheckDelaySeconds,
        [Parameter(Mandatory = $true)] [ValidateRange(1, 300)] [Int]$VsanRecheckInitialDelaySeconds,
        [Parameter(Mandatory = $true)] [ValidateRange(0, 20)] [Int]$VsanRecheckRetryCount
    )

    $clusterHostsForVsan = @(Get-VMHost -Location (Get-Cluster -Name $ClusterName -Server $Script:vCenterName -ErrorAction Stop) -Server $Script:vCenterName -ErrorAction Stop)
    foreach ($dataHost in $clusterHostsForVsan) {
        $dataHostName = $dataHost.Name
        $vmk0 = Get-VMHostNetworkAdapter -VMHost $dataHost -VMKernel -Server $Script:vCenterName -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq "vmk0" }
        if ($vmk0) {
            if ($vmk0.PSObject.Properties["VsanTrafficEnabled"] -and $vmk0.VsanTrafficEnabled -eq $true) {
                try {
                    Set-VMHostNetworkAdapter -VirtualNic $vmk0 -VsanTrafficEnabled $false -Confirm:$false -WarningAction SilentlyContinue -ErrorAction Stop | Out-Null
                    Write-LogMessage -Type INFO -Message "Cleared vSAN traffic from mgmt (vmk0) on host `"$dataHostName`" (post-VDS; vmk0 is mgmt + vSAN witness only)."
                } catch {
                    Write-LogMessage -Type WARNING -Message "Could not clear vSAN from vmk0 on host `"$dataHostName`": $($_.Exception.Message). Clear manually if needed."
                }
            }
            $vmk0WitnessProp = $vmk0.PSObject.Properties["VsanWitnessEnabled"] -or $vmk0.PSObject.Properties["VsanWitnessTrafficEnabled"]
            $vmk0WitnessOn = if ($vmk0.PSObject.Properties["VsanWitnessEnabled"]) { $vmk0.VsanWitnessEnabled -eq $true } elseif ($vmk0.PSObject.Properties["VsanWitnessTrafficEnabled"]) { $vmk0.VsanWitnessTrafficEnabled -eq $true } else { $false }
            if (-not $HasDedicatedVsanWitness -and (-not $vmk0WitnessProp -or -not $vmk0WitnessOn)) {
                try {
                    Set-VMHostNetworkAdapter -VirtualNic $vmk0 -VsanWitnessEnabled $true -Confirm:$false -WarningAction SilentlyContinue -ErrorAction Stop | Out-Null
                    Write-LogMessage -Type INFO -Message "Enabled vSAN witness traffic on vmk0 on host `"$dataHostName`" (no dedicated vSAN Witness VMkernel)."
                } catch {
                    $useEsxcliFallback = $_.Exception.Message -match "parameter cannot be found.*VsanWitness|VsanWitnessEnabled|VsanWitnessTrafficEnabled.*parameter|Parameter set cannot be resolved|cannot be used together"
                    if ($useEsxcliFallback) {
                        try { Add-VsanWitnessTrafficToVmkViaEsxcli -VMHost $dataHost -VmkernelName "vmk0" -WitnessOnly | Out-Null } catch {
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
            Start-Sleep -Seconds $VsanRecheckInitialDelaySeconds
            $vsanCheck = Test-VmkernelVsanAndWitnessTraffic -VMHost $dataHost
            $retryIdx = 1
            while (-not $vsanCheck.HasCompliantInterface -and $retryIdx -le $VsanRecheckRetryCount) {
                Write-LogMessage -Type DEBUG -Message "Post-VDS vSAN/witness re-check $retryIdx of $VsanRecheckRetryCount for host `"$dataHostName`"; waiting $VsanRecheckDelaySeconds seconds."
                Start-Sleep -Seconds $VsanRecheckDelaySeconds
                $vsanCheck = Test-VmkernelVsanAndWitnessTraffic -VMHost $dataHost
                $retryIdx++
            }
            if (-not $vsanCheck.HasCompliantInterface) {
                $errorMsg = "No VMkernel with vSAN and vSAN witness traffic found on host `"$dataHostName`" (post-VDS). Use networkingVmKernelInterfaces for vMotion and vSAN (e.g. vmk2); vmk0 may carry vSAN witness only when there is no dedicated vmk3."
                Write-LogMessage -Type ERROR -Message $errorMsg
                throw [VcfDeploymentException]::new($errorMsg)
            }
        }
    }
}
function Invoke-ClusterHostAdditionPhase {

    <#
        .SYNOPSIS
        Adds all ESX hosts to a newly created cluster, then configures networking (VDS, VMkernel
        interfaces, and vSAN witness traffic on vmk0).

        .DESCRIPTION
        Performs the host-addition and network-setup phase for a single cluster edge site:
          1. Iterates ESX hosts; adds each to the cluster via Add-HostToCluster (with an optional
             inter-host delay). Prompts for any credential not yet in EsxPasswords.
          2. Removes per-host EsxPasswords entries after all hosts are added when EsxUniquePassword
             is false (single shared password — credentials can be discarded once used).
          3. Resolves VDS and VMkernel MTU from common.vSanvMotionVmKernelMtuValue.
          4. Creates the VDS and migrates host management (vmk0) via Set-VirtualDistributedSwitch.
          5. Creates vMotion/vSAN VMkernel interfaces when networkingVmKernelInterfaces is configured.
          6. Ensures compliant vSAN and vSAN witness traffic on all data hosts (clears vSAN from vmk0
             if set; adds witness to vmk0 when no dedicated vSAN Witness VMkernel exists).
        All changes are made directly against vCenter; the function produces no return value.
        Context.EsxPasswords is a hashtable reference — entries for this cluster's hosts may be
        removed in place when Context.EsxUniquePassword is false.

        .PARAMETER Context
        Hashtable containing all inputs for this phase:
          Cluster                          — cluster PSCustomObject from infrastructure.json
          ClusterName                      — resolved cluster name string
          DatacenterName                   — vCenter datacenter name
          DelayBeforeAddingNextHostSeconds — seconds to wait between host additions (0 = no delay)
          EsxHosts                         — ordered array of ESX host FQDNs/IPs for this cluster
          EsxPasswords                     — hashtable of [hostname → PSCredential]; mutated
          EsxUniquePassword                — $true when one password covers all hosts; $false = per-host
          EsxUser                          — ESX user name (e.g. "root")
          InputData                        — parsed infrastructure.json PSCustomObject (for MTU)
          NetworkSegments                  — networking.networkSegments array for this cluster
          NicList                          — array of NIC names for this cluster
          NumUplinks                       — number of uplinks (matches NicList.Count)
          StoragePolicyType                — "vSAN-ESA", "vSAN-OSA", or "VMFS"
          VdsName                          — resolved VDS name for this cluster

        .EXAMPLE
        $ctx = @{
            Cluster                          = $cluster
            ClusterName                      = $clusterName
            DatacenterName                   = $datacenterName
            DelayBeforeAddingNextHostSeconds = 30
            EsxHosts                         = @("esx1.lab.local", "esx2.lab.local")
            EsxPasswords                     = $esxPasswords
            EsxUniquePassword                = $true
            EsxUser                          = "root"
            InputData                        = $inputData
            NetworkSegments                  = $networkSegments
            NicList                          = @("vmnic0", "vmnic1")
            NumUplinks                       = 2
            StoragePolicyType                = "vSAN-ESA"
            VdsName                          = "VDS-vsan-edge1-sw1"
        }
        Invoke-ClusterHostAdditionPhase -Context $ctx

        .NOTES
        Requires an active vCenter connection via $Script:vCenterName.
        vSAN witness traffic verification retries up to 3 times with a 10-second initial delay and
        5-second retry intervals; throws VcfDeploymentException if no compliant interface is found
        after all retries.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Hashtable]$Context
    )

    Assert-ContextKeys -CallerName "Invoke-ClusterHostAdditionPhase" -Context $Context `
        -RequiredKeys @("Cluster", "ClusterName", "DatacenterName", "DelayBeforeAddingNextHostSeconds",
            "EsxHosts", "EsxPasswords", "EsxUniquePassword", "EsxUser", "InputData",
            "NetworkSegments", "NicList", "NumUplinks", "StoragePolicyType", "VdsName")

    $cluster                          = $Context.Cluster
    $clusterName                      = $Context.ClusterName
    $datacenterName                   = $Context.DatacenterName
    $delayBeforeAddingNextHostSeconds = $Context.DelayBeforeAddingNextHostSeconds
    $esxHosts                         = $Context.EsxHosts
    $esxPasswords                     = $Context.EsxPasswords
    $esxUniquePassword                = $Context.EsxUniquePassword
    $esxUser                          = $Context.EsxUser
    $inputData                        = $Context.InputData
    $networkSegments                  = $Context.NetworkSegments
    $nicList                          = $Context.NicList
    $numUplinks                       = $Context.NumUplinks
    $storagePolicyType                = $Context.StoragePolicyType
    $vdsName                          = $Context.VdsName

    # Add all ESX hosts to cluster. Delay before 2nd+ hosts so the cluster can settle and first Add-VMHost attempt is more likely to succeed.
    $hostAddIndex = 0
    foreach ($esxHost in $esxHosts) {
        if ($hostAddIndex -ge 1 -and $delayBeforeAddingNextHostSeconds -gt 0) {
            Write-LogMessage -Type INFO -Message "Waiting $delayBeforeAddingNextHostSeconds seconds before adding next host (cluster may still be settling from previous add)."
            Start-Sleep -Seconds $delayBeforeAddingNextHostSeconds
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
        Add-VmkernelInterfacesFromNetworkingConfig -ClusterName $clusterName -EsxHostNames $esxHosts -NetworkingVmKernelInterfaces $cluster.networking.networkingVmKernelInterfaces -NumUplinks ([Int]$numUplinks) -VdsName $vdsName -VmkernelMtu $vmkernelMtu
    }

    # Ensure vSAN and vSAN witness traffic; vmk0 is mgmt + vSAN witness only (no vSAN). Clear only vSAN from vmk0; add witness to vmk0 when no dedicated vSAN Witness VMkernel.
    $hasDedicatedVsanWitness = if ($cluster.networking.networkingVmKernelInterfaces) { $cluster.networking.networkingVmKernelInterfaces | Where-Object { $_.service -eq "vSAN Witness" } } else { $null }
    if ($storagePolicyType -eq "vSAN-ESA" -or $storagePolicyType -eq "vSAN-OSA") {
        Set-VsanTrafficOnClusterHosts `
            -ClusterName $clusterName `
            -HasDedicatedVsanWitness $hasDedicatedVsanWitness `
            -VsanRecheckDelaySeconds 5 `
            -VsanRecheckInitialDelaySeconds 10 `
            -VsanRecheckRetryCount 3
    }
}
function Resolve-ClusterStoragePolicy {

    <#
        .SYNOPSIS
        Resolves the effective storage policy type, tag catalog, and name for a cluster.

        .DESCRIPTION
        Reads cluster.storagePolicy and returns the resolved StoragePolicyType,
        StoragePolicyTagCatalog (defaulting to "<Type>-Storage-TagCatalog" when blank), and
        StoragePolicyName (defaulting to the supervisor name when not explicitly configured).
        Returns $null for all three fields when no storagePolicy block is present.

        .PARAMETER Cluster
        The cluster object from the clustersToProcess array.

        .PARAMETER EdgeSite
        Edge site name used in DEBUG log messages.

        .PARAMETER SupervisorName
        Resolved supervisor name; used as the default StoragePolicyName when not configured.

        .EXAMPLE
        $policy = Resolve-ClusterStoragePolicy -Cluster $cluster -EdgeSite $edgeSite -SupervisorName $supervisorName

        .NOTES
        Called by Invoke-ClusterPerSiteVariables.
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$Cluster,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EdgeSite,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorName
    )

    $storagePolicyName       = $null
    $storagePolicyTagCatalog = $null
    $storagePolicyType       = $null

    if ($Cluster.storagePolicy) {
        $storagePolicyType       = $Cluster.storagePolicy.storageType
        $storagePolicyTagCatalog = $Cluster.storagePolicy.storagePolicyTagCatalog
        if ([String]::IsNullOrWhiteSpace($storagePolicyTagCatalog)) {
            $storagePolicyTagCatalog = "$storagePolicyType-Storage-TagCatalog"
            Write-LogMessage -Type DEBUG -Message "storagePolicyTagCatalog not defined; using default: `"$storagePolicyTagCatalog`""
        }
        Write-LogMessage -Type DEBUG -Message "Extracted storage policy type for cluster `"$EdgeSite`": `"$storagePolicyType`""
        $storagePolicyName = if ($Cluster.storagePolicy.storagePolicyName) { $Cluster.storagePolicy.storagePolicyName } else { $SupervisorName }
    } else {
        Write-LogMessage -Type DEBUG -Message "No storage policy configuration found for cluster `"$EdgeSite`"."
    }

    return [PSCustomObject]@{
        StoragePolicyName       = $storagePolicyName
        StoragePolicyTagCatalog = $storagePolicyTagCatalog
        StoragePolicyType       = $storagePolicyType
    }
}
function Invoke-ClusterPerSiteVariables {

    <#
    .SYNOPSIS
    Resolves all per-cluster, per-edge-site variables at the start of the Initialize-VcfEdgeAtScale deployment loop.

    .DESCRIPTION
    Extracts and resolves names, networking, ArgoCD, supervisor service flags, storage policy, HA policy, and NIC list
    for one cluster entry at the start of the Initialize-VcfEdgeAtScale foreach loop. Throws if the cluster has no
    networking.networkSegments. Does not assign $Script:SupervisorName; the caller must do so from the returned
    SupervisorName key.

    .PARAMETER Cluster
    The cluster object from the clustersToProcess array parsed from infrastructure JSON.

    .PARAMETER ClusterNamePrefix
    Common cluster name prefix resolved from common.clusterNamePrefix.

    .PARAMETER DatastoreNamePrefix
    Common datastore name prefix resolved from common.datastoreNamePrefix.

    .PARAMETER InputData
    The full parsed infrastructure JSON object; used to pass common-level fields to effective-value helpers.

    .PARAMETER SupervisorNamePrefix
    Common supervisor name prefix resolved from common.supervisorNamePrefix.

    .PARAMETER VdsNamePrefix
    Common VDS name prefix resolved from common.vdsNamePrefix.

    .EXAMPLE
    $siteVars = Invoke-ClusterPerSiteVariables -Cluster $cluster -ClusterNamePrefix "cluster" `
        -DatastoreNamePrefix "datastore" -InputData $inputData `
        -SupervisorNamePrefix "supervisor" -VdsNamePrefix "VDS"
    $Script:SupervisorName = $siteVars.SupervisorName

    .NOTES
    Returns a hashtable: ArgoCDYaml, ArgoCdDeploymentYamlPath, ArgocdNameSpacePrefix, ArgocdVmClass, ClusterName,
    DatastoreName, SkipArgoCDDeployment, SkipHarborDeployment, EdgeSite, EffectiveMultiHostHaPolicy, EsxHosts, NetworkSegments,
    NicList, NumUplinks, StoragePolicyName, StoragePolicyTagCatalog, StoragePolicyType, SupervisorName, VdsName.
    Throws VcfDeploymentException if networking.networkSegments is absent for the cluster.
    #>

    [CmdletBinding()]
    [OutputType([System.Collections.Hashtable])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$Cluster,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterNamePrefix,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DatastoreNamePrefix,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$InputData,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorNamePrefix,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VdsNamePrefix
    )

    $edgeSite       = $Cluster.edgeSite
    $clusterName    = Get-EffectiveClusterName -Cluster $Cluster -ClusterNamePrefix $ClusterNamePrefix -EdgeSite $edgeSite
    $datastoreName  = Get-DatastoreNameFromPrefix -DatastoreNamePrefix $DatastoreNamePrefix -EdgeSite $edgeSite
    $vdsName        = Get-VdsNameFromPrefix -VdsNamePrefix $VdsNamePrefix -EdgeSite $edgeSite
    $supervisorName = Get-SupervisorNameFromPrefix -SupervisorNamePrefix $SupervisorNamePrefix -EdgeSite $edgeSite
    $esxHosts       = $Cluster.esxHosts

    # Edge site suffix is applied only to VMkernel port groups (mgmt, vmotion, vsan, vsanwitness) in Set-VirtualDistributedSwitch
    # and Add-VmkernelInterfacesFromNetworkingConfig; FLB and supervisor network segments keep their configured names.
    if (-not ($Cluster.networking -and $Cluster.networking.networkSegments)) {
        $errorMsg = "Cluster with edgeSite `"$edgeSite`" has no network segments specified."
        Write-LogMessage -Type ERROR -Message $errorMsg
        throw [VcfDeploymentException]::new($errorMsg)
    }
    $networkSegments = $Cluster.networking.networkSegments

    # Supervisor services (ArgoCD configuration). Cluster level takes priority over common.
    $argoCDyaml               = Get-EffectiveArgoCdYamlPath -Cluster $Cluster -CommonData $InputData.common -PropertyName "argoCdOperatorYamlPath"
    $argoCdDeploymentYamlPath = Get-EffectiveArgoCdYamlPath -Cluster $Cluster -CommonData $InputData.common -PropertyName "argoCdDeploymentYamlPath"
    $argocdNameSpacePrefix    = "argocd"
    $argocdVmClass            = $null
    if ($Cluster.supervisorServices) {
        if (-not [String]::IsNullOrWhiteSpace($Cluster.supervisorServices.nameSpacePrefix)) {
            $argocdNameSpacePrefix = $Cluster.supervisorServices.nameSpacePrefix.Trim()
        }
        if ($null -ne $Cluster.supervisorServices.vmClass -and $Cluster.supervisorServices.vmClass.Count -gt 0) {
            $argocdVmClass = if ($Cluster.supervisorServices.vmClass -is [Array]) { @($Cluster.supervisorServices.vmClass) } else { @($Cluster.supervisorServices.vmClass) }
        }
    }

    # Supervisor service disable flags. Cluster level takes priority over common-level.
    $disableArgoCD = Get-EffectiveSupervisorServiceFlag -Cluster $Cluster -CommonData $InputData.common -FlagName "disableArgoCD"
    $disableHarbor = Get-EffectiveSupervisorServiceFlag -Cluster $Cluster -CommonData $InputData.common -FlagName "disableHarbor"

    # Storage policy. VMFS uses "Fully initialized" in Set-StoragePolicy; vSAN does not use a volume allocation rule.
    $storagePolicyResult     = Resolve-ClusterStoragePolicy -Cluster $Cluster -EdgeSite $edgeSite -SupervisorName $supervisorName
    $storagePolicyName       = $storagePolicyResult.StoragePolicyName
    $storagePolicyTagCatalog = $storagePolicyResult.StoragePolicyTagCatalog
    $storagePolicyType       = $storagePolicyResult.StoragePolicyType

    # Multi-host HA admission. vSAN OSA/ESA use common/cluster haPolicy; VMFS is always single-host → "disabled".
    $effectiveMultiHostHaPolicy = if ($storagePolicyType -eq "vSAN-ESA" -or $storagePolicyType -eq "vSAN-OSA") {
        Get-EffectiveHaPolicyForCluster -Cluster $Cluster -InputData $InputData
    } else {
        "disabled"
    }
    Write-LogMessage -Type DEBUG -Message "Multi-host HA admission policy for edgeSite `"$edgeSite`" (storage type `"$storagePolicyType`"): $effectiveMultiHostHaPolicy."

    # NIC list. cluster.nicList overrides common.nicList; validation already ensured 2 or 4 NICs.
    $nicList    = Get-EffectiveNicListForCluster -Cluster $Cluster -CommonNicList $InputData.common.nicList
    $numUplinks = $nicList.Count

    return @{
        ArgoCDYaml               = $argoCDyaml
        ArgoCdDeploymentYamlPath = $argoCdDeploymentYamlPath
        ArgocdNameSpacePrefix    = $argocdNameSpacePrefix
        ArgocdVmClass            = $argocdVmClass
        ClusterName              = $clusterName
        DatastoreName            = $datastoreName
        SkipArgoCDDeployment            = $disableArgoCD
        SkipHarborDeployment            = $disableHarbor
        EdgeSite                 = $edgeSite
        EffectiveMultiHostHaPolicy = $effectiveMultiHostHaPolicy
        EsxHosts                 = $esxHosts
        NetworkSegments          = $networkSegments
        NicList                  = $nicList
        NumUplinks               = $numUplinks
        StoragePolicyName        = $storagePolicyName
        StoragePolicyTagCatalog  = $storagePolicyTagCatalog
        StoragePolicyType        = $storagePolicyType
        SupervisorName           = $supervisorName
        VdsName                  = $vdsName
    }
}
function Invoke-ClusterCreationPhase {

    <#
    .SYNOPSIS
    Creates the vSphere cluster and applies the appropriate vSAN mode and vLCM image.

    .DESCRIPTION
    Resolves the vLCM image name (cluster-level overrides common when both are defined), derives the
    vSAN ESA/OSA enable flags from StoragePolicyType, and calls Add-Cluster. Encapsulates the
    cluster creation step that precedes host addition in the Initialize-VcfEdgeAtScale deployment loop.

    .PARAMETER Cluster
    The cluster object from the clustersToProcess array; used to resolve the cluster-level vLcmImageName.

    .PARAMETER ClusterName
    Resolved cluster name to pass to Add-Cluster.

    .PARAMETER DatacenterName
    vCenter datacenter name in which the cluster is created.

    .PARAMETER InputData
    Full parsed infrastructure JSON object; used for common.vLcmImageName fallback.

    .PARAMETER StoragePolicyType
    Storage policy type string (e.g. "vSAN-ESA", "vSAN-OSA", "VMFS") used to set vSAN flags.

    .EXAMPLE
    Invoke-ClusterCreationPhase -Cluster $cluster -ClusterName "cluster-edge1" `
        -DatacenterName "DC" -InputData $inputData -StoragePolicyType "vSAN-ESA"

    .NOTES
    Cluster-level vLcmImageName takes priority over common.vLcmImageName. When neither is defined,
    vLCM image is not applied and the cluster uses the default ESX image.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$Cluster,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DatacenterName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$InputData,
        [Parameter(Mandatory = $true)] [ValidateSet("vSAN-ESA", "vSAN-OSA", "VMFS")] [String]$StoragePolicyType
    )

    $enableVsanEsa = ($StoragePolicyType -eq "vSAN-ESA")
    $enableVsanOsa = ($StoragePolicyType -eq "vSAN-OSA")

    # Cluster-level vLcmImageName overrides common when both are defined.
    $vLcmImageName = $null
    if (-not [String]::IsNullOrWhiteSpace($Cluster.vLcmImageName)) {
        $vLcmImageName = $Cluster.vLcmImageName.Trim()
    } elseif ($InputData.common -and -not [String]::IsNullOrWhiteSpace($InputData.common.vLcmImageName)) {
        $vLcmImageName = $InputData.common.vLcmImageName.Trim()
    }

    # ESX connect/disconnect in Invoke-EsxCredentialAndDatastoreSetup can disrupt the vCenter
    # session in VCF PowerCLI 9. Reconnect before the first vCenter API call if needed.
    Invoke-VcenterReconnectIfNeeded
    Add-Cluster -ClusterName $ClusterName -DataCenterName $DatacenterName `
        -VsanEsaEnabled:$enableVsanEsa -VsanOsaEnabled:$enableVsanOsa -VlcmImageName $vLcmImageName
}
function Invoke-EsxCredentialCollection {

    <#
    .SYNOPSIS
    Collects ESX host credentials, preferring the ESX_COMMON_PASSWORD environment variable in non-interactive mode.

    .DESCRIPTION
    When EsxUniquePassword is true and AllEsxHosts is non-empty, attempts to source credentials from the
    ESX_COMMON_PASSWORD environment variable (when NonInteractivePassword is true and the variable is set);
    falls back to an interactive password prompt via Get-InteractiveInput. When EsxUniquePassword is false
    (per-host prompting is enabled), returns empty EsxPasswords — each host will be prompted individually
    later during deployment. Returns EsxPasswords (hashtable of host → PSCredential) and EsxUsedEnvPassword
    (true when the env var was used).

    .PARAMETER AllEsxHosts
    Ordered list of all unique ESX host FQDNs or IPs across all clusters to deploy.

    .PARAMETER EsxUniquePassword
    When true, one shared password is collected up-front for all hosts. When false, each host
    prompts individually during deployment — this function returns an empty EsxPasswords hashtable.

    .PARAMETER EsxUser
    ESX user name (typically "root") used when creating PSCredential objects.

    .PARAMETER NonInteractivePassword
    When true, ESX_COMMON_PASSWORD environment variable is tried before prompting interactively.

    .EXAMPLE
    $result = Invoke-EsxCredentialCollection -AllEsxHosts $allEsxHosts -EsxUniquePassword $esxUniquePassword -EsxUser $esxUser -NonInteractivePassword $nonInteractivePassword
    $esxPasswords       = $result.EsxPasswords
    $esxUsedEnvPassword = $result.EsxUsedEnvPassword

    .NOTES
    An empty ESX_COMMON_PASSWORD is accepted and represents a null root password on ESX hosts.
    #>

    [CmdletBinding()]
    [OutputType([System.Collections.Hashtable])]
    Param (
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [ValidateNotNull()] [System.Collections.Generic.List[object]]$AllEsxHosts,
        [Parameter(Mandatory = $true)] [Bool]$EsxUniquePassword,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EsxUser,
        [Parameter(Mandatory = $true)] [Bool]$NonInteractivePassword
    )

    $esxPasswords       = @{}
    $esxUsedEnvPassword = $false

    if ($EsxUniquePassword -and $AllEsxHosts.Count -gt 0) {
        if ($NonInteractivePassword -and (Test-Path Env:ESX_COMMON_PASSWORD)) {
            $esxPassFromEnv = ConvertTo-SecureStringForCredential -PlainText $env:ESX_COMMON_PASSWORD
            foreach ($esxHost in $AllEsxHosts) {
                $esxPasswords[$esxHost] = New-Object System.Management.Automation.PSCredential($EsxUser, $esxPassFromEnv)
            }
            $esxUsedEnvPassword = $true
            if ([String]::IsNullOrEmpty($env:ESX_COMMON_PASSWORD)) {
                Write-LogMessage -Type DEBUG -Message "Using ESX_COMMON_PASSWORD (empty) for null root password on ESX hosts."
            } else {
                Write-LogMessage -Type DEBUG -Message "Using ESX_COMMON_PASSWORD environment variable for ESX authentication (esxUniquePasswordPerHost is false)."
            }
        } else {
            $hostList   = $AllEsxHosts -join ", "
            $esxPassword = Get-InteractiveInput -PromptMessage "`nEnter the password for the user `"$EsxUser`" on ESX Host(s): $hostList" -AsSecureString -AllowEmpty
            foreach ($esxHost in $AllEsxHosts) {
                $esxPasswords[$esxHost] = New-Object System.Management.Automation.PSCredential($EsxUser, $esxPassword)
            }
        }
    }
    return @{ EsxPasswords = $esxPasswords; EsxUsedEnvPassword = $esxUsedEnvPassword }
}
function Invoke-WitnessHostPreflightCheck {

    <#
    .SYNOPSIS
    Verifies that every configured vSAN witness host is present in vCenter inventory before cluster creation begins.

    .DESCRIPTION
    Iterates all clusters in ClustersToProcess. For each cluster that has a configured witness host
    (via Get-VsanWitnessNameForCluster), queries vCenter inventory. For vSAN clusters (vSAN-ESA or
    vSAN-OSA), a missing witness throws VcfDeploymentException so the operator can add the host before
    any clusters are created. For non-vSAN clusters, a missing witness is logged at DEBUG only and does
    not block deployment.

    .PARAMETER ClustersToProcess
    Array of cluster objects from the infrastructure JSON to check.

    .PARAMETER InputData
    Full infrastructure JSON PSCustomObject (for common.vSanWitnessVmName resolution).

    .EXAMPLE
    Invoke-WitnessHostPreflightCheck -ClustersToProcess $clustersToProcess -InputData $inputData

    .NOTES
    Uses $Script:vCenterName for inventory queries. Must be called after vCenter authentication.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object[]]$ClustersToProcess,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$InputData
    )

    foreach ($clusterForWitnessCheck in $ClustersToProcess) {
        $witnessNameForCheck = Get-VsanWitnessNameForCluster -Cluster $clusterForWitnessCheck -InputData $InputData
        if (-not [String]::IsNullOrWhiteSpace($witnessNameForCheck)) {
            $storageTypeForWitnessCheck    = $clusterForWitnessCheck.storagePolicy.storageType
            $isVsanClusterForWitnessCheck  = ($storageTypeForWitnessCheck -eq "vSAN-ESA" -or $storageTypeForWitnessCheck -eq "vSAN-OSA")
            $witnessHostForCheck = Get-VMHost -Name $witnessNameForCheck -Server $Script:vCenterName -ErrorAction SilentlyContinue
            if (-not $witnessHostForCheck) {
                if ($isVsanClusterForWitnessCheck) {
                    $errorMsg = "vSAN witness host `"$witnessNameForCheck`" is not present in vCenter inventory. Add the witness host to vCenter before creating the cluster to avoid cleanup."
                    Write-LogMessage -Type ERROR -Message $errorMsg
                    throw [VcfDeploymentException]::new($errorMsg)
                } else {
                    Write-LogMessage -Type DEBUG -Message "vSAN witness `"$witnessNameForCheck`" is configured for edgeSite `"$($clusterForWitnessCheck.edgeSite)`" but is not in vCenter inventory; ignoring — witness is not required for `"$storageTypeForWitnessCheck`" deployments."
                }
            } else {
                Write-LogMessage -Type DEBUG -Message "vSAN witness host `"$witnessNameForCheck`" is present in vCenter inventory for edgeSite `"$($clusterForWitnessCheck.edgeSite)`"; proceeding."
            }
        }
    }
}
function Invoke-EsxPreFlightVersionCheck {

    <#
    .SYNOPSIS
    Performs a pre-flight ESX version check (9.0.0 minimum) across all unique ESX hosts before cluster creation begins.

    .DESCRIPTION
    Connects to each host in AllEsxHosts that has an entry in EsxPasswords, checks that its ESX version
    meets the 9.0.0 minimum requirement, and disconnects after each check. Hosts where authentication
    fails are skipped with a DEBUG log entry — they will be version-checked during per-cluster deployment
    via the normal credential retry flow. Throws VcfDeploymentException immediately when any reachable
    host reports an unsupported version so the operator is informed before any cluster is created.
    Returns a hashtable of hostname → $true for every host whose version was successfully verified.

    .PARAMETER AllEsxHosts
    Ordered list of all unique ESX host FQDNs or IPs across all clusters to deploy.

    .PARAMETER EsxPasswords
    Hashtable mapping ESX hostname to PSCredential. Hosts absent from this hashtable are skipped.

    .EXAMPLE
    $esxVersionChecked = Invoke-EsxPreFlightVersionCheck -AllEsxHosts $allEsxHosts -EsxPasswords $esxPasswords

    .NOTES
    Authentication failures are intentionally tolerated — only version mismatches cause a fail-fast throw.
    The returned hashtable is passed to Invoke-EsxCredentialAndDatastoreSetup to avoid rechecking hosts
    that were already verified here.
    #>

    [CmdletBinding()]
    [OutputType([System.Collections.Hashtable])]
    Param (
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [ValidateNotNull()] [System.Collections.Generic.List[object]]$AllEsxHosts,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [System.Collections.Hashtable]$EsxPasswords
    )

    $esxVersionChecked = @{}

    if ($AllEsxHosts.Count -gt 0) {
        Write-LogMessage -Type INFO -Message "Pre-flight checking ESX version (9.0.0 minimum) across $($AllEsxHosts.Count) host(s)..."
        foreach ($esxHost in $AllEsxHosts) {
            if ($esxVersionChecked[$esxHost]) { continue }
            if (-not $EsxPasswords[$esxHost]) { continue }
            $preflightConnected = $false
            try {
                Connect-Vcenter -ServerName $esxHost -ServerCredential $EsxPasswords[$esxHost] -ServerType "ESX" -SkipRetryPrompt
                $preflightConnected = $true
                $esxVerResult = Test-ESXVersion -ServerName $esxHost -MinimumVersion "9.0.0"
                if (-not $esxVerResult.Success) {
                    Write-LogMessage -Type ERROR -Message $esxVerResult.ErrorMessage
                    throw [VcfDeploymentException]::new($esxVerResult.ErrorMessage)
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
        if ($preflightCheckedCount -eq $AllEsxHosts.Count) {
            Write-LogMessage -Type INFO -Message "ESX pre-flight version check passed for all $($AllEsxHosts.Count) host(s)."
        } else {
            Write-LogMessage -Type INFO -Message "ESX pre-flight version check passed for $preflightCheckedCount of $($AllEsxHosts.Count) host(s); remaining host(s) will be version-checked during deployment (auth retry required)."
        }
    }
    return $esxVersionChecked
}
function Invoke-VcenterConnectionAndValidation {

    <#
        .SYNOPSIS
        Acquires vCenter credentials and establishes a verified connection.

        .DESCRIPTION
        Attempts to authenticate to vCenter using the VCENTER_COMMON_PASSWORD environment variable when
        NonInteractivePassword is true and the variable is set; on authentication failure the function
        falls back to an interactive prompt. After connecting, validates the vCenter version (minimum
        9.0.0) and enforces the supervisor count limit. On success, the credential is stored via
        Set-ScriptVcenterCredential.

        .PARAMETER MaximumSupervisorsPerVcenter
        Maximum supervisors permitted on the target vCenter before this deployment. Default is 50.

        .PARAMETER NonInteractivePassword
        When true and VCENTER_COMMON_PASSWORD is set, tries the env-var password before prompting.

        .PARAMETER VcenterName
        FQDN or IP address of the target vCenter.

        .PARAMETER VcenterUser
        Username to authenticate against vCenter.

        .OUTPUTS
        [PSCredential]. The credential used to authenticate.

        .EXAMPLE
        $credential = Invoke-VcenterConnectionAndValidation `
            -MaximumSupervisorsPerVcenter 50 `
            -NonInteractivePassword $false `
            -VcenterName "vc01.lab" `
            -VcenterUser "administrator@vsphere.local"

        .NOTES
        Caller must set $Script:vCenterName and $Script:VCenterUser before calling. On success,
        $Script:VcenterCredential is set via Set-ScriptVcenterCredential so downstream functions
        that reference $Script:VcenterCredential receive the authenticated credential.
    #>

    [CmdletBinding()]
    [OutputType([PSCredential])]
    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(1, 128)] [Int]$MaximumSupervisorsPerVcenter = 50,
        [Parameter(Mandatory = $true)] [Bool]$NonInteractivePassword,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VcenterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VcenterUser
    )

    $vCenterCredential = $null
    if ($NonInteractivePassword -and -not [String]::IsNullOrWhiteSpace($env:VCENTER_COMMON_PASSWORD)) {
        try {
            $vCenterPassFromEnv = ConvertTo-SecureStringForCredential -PlainText $env:VCENTER_COMMON_PASSWORD
            $vCenterCredential = New-Object System.Management.Automation.PSCredential($VcenterUser, $vCenterPassFromEnv)
            Disconnect-Vcenter -AllServers -Silence
            Connect-Vcenter -ServerName $VcenterName -ServerCredential $vCenterCredential -ServerType "vCenter"
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
        $vCenterPass = Get-InteractiveInput -PromptMessage "`nEnter the password for the user `"$VcenterUser`" on vCenter `"$VcenterName`" " -asSecureString
        $vCenterCredential = New-Object System.Management.Automation.PSCredential($VcenterUser, $vCenterPass)
        Disconnect-Vcenter -AllServers -Silence
        Connect-Vcenter -ServerName $VcenterName -ServerCredential $vCenterCredential -ServerType "vCenter"
    }

    $versionResult = Test-VCenterVersion -MinimumVersion "9.0.0"
    if (-not $versionResult.Success) {
        $errorMsg = "vCenter version check failed: $($versionResult.ErrorMessage)"
        Write-LogMessage -Type ERROR -Message $errorMsg
        throw [VcfDeploymentException]::new($errorMsg)
    }

    $supervisorCountResult = Get-VcenterSupervisorCount -ErrorAction SilentlyContinue
    if ($null -ne $supervisorCountResult) {
        $currentSupervisorCount = $supervisorCountResult.Count
        Write-LogMessage -Type DEBUG -Message "vCenter `"$VcenterName`" has $currentSupervisorCount supervisor(s). Maximum allowed before this deployment: $MaximumSupervisorsPerVcenter."
        if ($currentSupervisorCount -ge $MaximumSupervisorsPerVcenter) {
            Write-LogMessage -Type ERROR -Message "vCenter `"$VcenterName`" has $currentSupervisorCount supervisor(s). vCenter 9 supports a maximum of $MaximumSupervisorsPerVcenter supervisors per vCenter."
            $errorMsg = "Deploy your new edge cluster to a different vCenter, or remove existing supervisors from this vCenter before re-running."
            Write-LogMessage -Type ERROR -Message $errorMsg
            throw [VcfDeploymentException]::new($errorMsg)
        }
    }

    Set-ScriptVcenterCredential -Credential $vCenterCredential
    return $vCenterCredential
}
function Invoke-VsanPreSupervisorRollbackCore {

    <#
    .SYNOPSIS
        Executes the vSAN/VDS/cluster teardown for a failed pre-supervisor compute deployment.
    .DESCRIPTION
        Clears non-vmk0 VMkernels, restores management to VSS, runs vSAN rollback, removes VDS
        and cluster. Returns $true when rollback completes successfully so the caller can emit the
        final failure message.
    .PARAMETER Cluster
        Cluster object from the Context, used to resolve the vSAN witness VM name.
    .PARAMETER ClusterName
        Cluster display name.
    .PARAMETER CurrentEdgeSite
        Edge site name used in log messages.
    .PARAMETER EsxHosts
        Optional array of ESX host names to pass to Invoke-VsanDeploymentRollback.
    .PARAMETER InputData
        Root input data object; used to resolve the vSAN witness VM name when absent from $Cluster.
    .PARAMETER IsSingleSite
        Passed to rollback helpers.
    .PARAMETER NicListCountForRestore
        Number of NICs for management restore (2 or 4).
    .PARAMETER StoragePolicyTagCatalog
        Optional storage policy tag catalog; when set, tag cleanup is included in vSAN rollback.
    .PARAMETER StoragePolicyType
        Storage type: "vSAN-ESA" or "vSAN-OSA".
    .PARAMETER VdsName
        Primary VDS name for the cluster.
    .PARAMETER VdsNamesForCleanup
        Array of VDS names to clean up (primary + sw1 + sw2 variants).
    .EXAMPLE
        $done = Invoke-VsanPreSupervisorRollbackCore -Cluster $cluster -ClusterName "cl1" -CurrentEdgeSite "site1" -InputData $data -NicListCountForRestore 2 -StoragePolicyType "vSAN-ESA" -VdsName "cl1-vds" -VdsNamesForCleanup $vdsNames
    .NOTES
        Called by Invoke-ComputePreSupervisorRollback. Mutates $Script:RollbackFailed.
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$Cluster,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$CurrentEdgeSite,
        [Parameter(Mandatory = $false)] [Object[]]$EsxHosts,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$InputData,
        [Parameter(Mandatory = $false)] [Switch]$IsSingleSite,
        [Parameter(Mandatory = $true)] [ValidateRange(1, 4)] [Int]$NicListCountForRestore,
        [Parameter(Mandatory = $false)] [AllowNull()] [String]$StoragePolicyTagCatalog,
        [Parameter(Mandatory = $true)] [ValidateSet("vSAN-ESA", "vSAN-OSA")] [String]$StoragePolicyType,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VdsName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object[]]$VdsNamesForCleanup
    )

    $rollbackParams = @{ ClusterName = $ClusterName; StoragePolicyType = $StoragePolicyType; SkipClusterRemoval = $true; SuppressPrompt = $true }
    if ($StoragePolicyTagCatalog) { $rollbackParams["StoragePolicyTagCatalog"] = $StoragePolicyTagCatalog; $rollbackParams["StoragePolicyTagName"] = $Script:SupervisorName }
    if ($EsxHosts -and $EsxHosts.Count -gt 0) { $rollbackParams["EsxHostNames"] = @($EsxHosts) }
    $witnessName = $null
    if (-not [String]::IsNullOrWhiteSpace($Cluster.vSanWitnessVmName)) { $witnessName = $Cluster.vSanWitnessVmName }
    elseif ($InputData.common -and -not [String]::IsNullOrWhiteSpace($InputData.common.vSanWitnessVmName)) { $witnessName = $InputData.common.vSanWitnessVmName }
    if ($witnessName) { $rollbackParams["WitnessHostName"] = $witnessName }
    Write-LogMessage -Type INFO -Message "Running complete rollback for edgeSite `"$CurrentEdgeSite`" (full teardown: VMkernel, management restore, vSAN, VDS, cluster)."
    try { Remove-NonVmk0VmkernelInterfacesFromVds -ClusterName $ClusterName -VdsNames $VdsNamesForCleanup } catch { Write-LogMessage -Type WARNING -Message "Non-vmk0 VMkernel removal had errors during vSAN rollback (non-fatal): $($_.Exception.Message)." }
    try { $restoreResult = Invoke-ManagementRestoreForCleanupWithTopologyFallback -ClusterName $ClusterName -NicListCount $NicListCountForRestore -VdsName $VdsName }
    catch { $Script:RollbackFailed = $true; Write-LogMessage -Type ERROR -Message "Management restore during vSAN rollback failed: $($_.Exception.Message). Remove VDS and cluster manually if needed."; throw }
    if ($restoreResult.RestoreAttempted -and -not $restoreResult.Success) {
        $Script:RollbackFailed = $true
        $errorMsg = "Management was not moved back to VSS for cluster `"$ClusterName`" during rollback. $($restoreResult.Message) Move vmk0 off the VDS manually on each host, then retry cleanup or rollback. Skipping VDS and cluster removal."
        Write-LogMessage -Type ERROR -Message $errorMsg
        throw [VcfDeploymentException]::new($errorMsg)
    }
    Invoke-VsanDeploymentRollback @rollbackParams
    try { Remove-NonVmk0VmkernelInterfacesFromVds -ClusterName $ClusterName -VdsNames $VdsNamesForCleanup } catch { Write-LogMessage -Type WARNING -Message "Post-vSAN-rollback VMkernel removal had errors (non-fatal): $($_.Exception.Message)." }
    if (Test-SupervisorDeployedOnCluster -ClusterName $ClusterName) {
        $Script:RollbackFailed = $true
        $errorMsg = "Supervisor is active on cluster `"$ClusterName`" from a prior deployment. VDS and cluster cannot be removed while the supervisor is running. Deactivate it first with -CleanUp Supervisor, then remove compute with -CleanUp Compute."
        Write-LogMessage -Type ERROR -Message $errorMsg
        throw [VcfDeploymentException]::new($errorMsg)
    }
    $vdsRemovalSucceeded = $true
    Write-LogMessage -Type INFO -Message "Removing VDS(es) for cluster `"$ClusterName`"..."
    try { Remove-EdgeClusterDistributedSwitch -ClusterName $ClusterName -VdsName $VdsName } catch { $vdsRemovalSucceeded = $false; Write-LogMessage -Type WARNING -Message "Could not remove VDS `"$VdsName`" during rollback: $($_.Exception.Message)." }
    try { Remove-EdgeClusterDistributedSwitch -ClusterName $ClusterName -VdsName "$VdsName-sw1" } catch { $vdsRemovalSucceeded = $false; Write-LogMessage -Type WARNING -Message "Could not remove VDS `"$VdsName-sw1`" during rollback: $($_.Exception.Message)." }
    try { Remove-EdgeClusterDistributedSwitch -ClusterName $ClusterName -VdsName "$VdsName-sw2" } catch { $vdsRemovalSucceeded = $false; Write-LogMessage -Type WARNING -Message "Could not remove VDS `"$VdsName-sw2`" during rollback: $($_.Exception.Message)." }
    if ($vdsRemovalSucceeded) {
        try { Remove-ClusterSafely -ClusterName $ClusterName } catch {
            $clusterErrMsg = $_.Exception.Message
            # Allow vCenter's inventory cache to propagate the deletion before re-checking.
            $vCenterStatePropagationDelaySeconds = 2
            Start-Sleep -Seconds $vCenterStatePropagationDelaySeconds
            if (Get-ClusterByName -Name $ClusterName -Server $Script:vCenterName) {
                $Script:RollbackFailed = $true
                Write-LogMessage -Type ERROR -Message "Rollback failed: could not remove cluster `"$ClusterName`" after vSAN/VDS cleanup: $clusterErrMsg. Remove the cluster manually if desired; script will exit with failure."
                throw
            }
            Write-LogMessage -Type INFO -Message "Cluster `"$ClusterName`" was removed (vCenter reported an error but the cluster is no longer present)."
        }
    } else {
        $Script:RollbackFailed = $true
        $errorMsg = "VDS removal failed during vSAN rollback; could not remove cluster. Remove VMkernel adapters and VDS manually, then remove the cluster. Script will exit with failure."
        Write-LogMessage -Type ERROR -Message $errorMsg
        throw [VcfDeploymentException]::new($errorMsg)
    }
    Write-LogMessage -Type INFO -Message "Complete rollback finished for edgeSite `"$CurrentEdgeSite`" (VDS and cluster removed)."
    return $true
}
function Remove-VdsTrioAndCluster {

    <#
    .SYNOPSIS
        Removes the primary, -sw1, and -sw2 VDS variants for a cluster, then removes the cluster if all VDS removals succeeded.
    .PARAMETER ClusterName
        Cluster display name.
    .PARAMETER VdsNamesForCleanup
        Array of VDS names to attempt removal for (typically primary, sw1, sw2 variants).
    .OUTPUTS
        [Bool] $true when all VDS removals succeeded; $false when any VDS removal failed (cluster removal is skipped in that case).
    .NOTES
        Called by Invoke-VmfsPreSupervisorRollbackCore. Non-fatal: logs warnings for individual failures.
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object[]]$VdsNamesForCleanup
    )

    $vdsRemovalSucceeded = $true
    Write-LogMessage -Type INFO -Message "Removing VDS(es) for cluster `"$ClusterName`"..."
    foreach ($vdsNameItem in $VdsNamesForCleanup) {
        try { Remove-EdgeClusterDistributedSwitch -ClusterName $ClusterName -VdsName $vdsNameItem -SkipPortGroupInUseRestoreFallback }
        catch { $vdsRemovalSucceeded = $false; Write-LogMessage -Type WARNING -Message "Could not remove VDS `"$vdsNameItem`" during rollback: $($_.Exception.Message)." }
    }
    if ($vdsRemovalSucceeded) {
        try { Remove-ClusterSafely -ClusterName $ClusterName } catch { Write-LogMessage -Type WARNING -Message "Could not remove cluster during rollback: $($_.Exception.Message)." }
    } else {
        Write-LogMessage -Type WARNING -Message "VDS removal failed during rollback; skipping cluster removal. Move VMkernel adapters and VMs off the VDS port groups, then remove the VDS and cluster manually if desired."
    }
    return $vdsRemovalSucceeded
}
function Remove-DatastoreByName {

    <#
    .SYNOPSIS
        Removes a VMFS datastore by name, logging a warning on failure (non-fatal).
    .PARAMETER ClusterName
        Cluster display name.
    .PARAMETER DatastoreName
        VMFS datastore name to remove.
    .NOTES
        Thin wrapper over Remove-VmfsDatastoreForCluster enabling unit tests to mock this step independently.
        Called by Invoke-VmfsPreSupervisorRollbackCore when VDS removal succeeded.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DatastoreName
    )

    try { Remove-VmfsDatastoreForCluster -ClusterName $ClusterName -DatastoreName $DatastoreName }
    catch { Write-LogMessage -Type WARNING -Message "Could not remove VMFS datastore during rollback: $($_.Exception.Message)." }
}
function Invoke-VmfsPreSupervisorRollbackCore {

    <#
    .SYNOPSIS
        Executes the VMFS VDS/cluster/datastore teardown for a failed pre-supervisor compute deployment.
    .DESCRIPTION
        Clears non-vmk0 VMkernels, restores management to VSS, removes VDS, cluster, and VMFS datastore.
        Does not throw — logs warnings for non-fatal failures.
    .PARAMETER ClusterName
        Cluster display name.
    .PARAMETER CurrentEdgeSite
        Edge site name used in log messages.
    .PARAMETER DatastoreName
        VMFS datastore name to remove.
    .PARAMETER NicListCountForRestore
        Number of NICs for management restore (2 or 4).
    .PARAMETER VdsName
        Primary VDS name.
    .PARAMETER VdsNamesForCleanup
        Array of VDS names to clean (primary + sw1 + sw2 variants).
    .EXAMPLE
        Invoke-VmfsPreSupervisorRollbackCore -ClusterName "cl1" -CurrentEdgeSite "site1" -DatastoreName "ds1" -NicListCountForRestore 2 -VdsName "cl1-vds" -VdsNamesForCleanup $names
    .NOTES
        Called by Invoke-ComputePreSupervisorRollback. Mutates $Script:RollbackFailed.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$CurrentEdgeSite,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DatastoreName,
        [Parameter(Mandatory = $true)] [ValidateRange(1, 4)] [Int]$NicListCountForRestore,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VdsName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object[]]$VdsNamesForCleanup
    )

    Write-LogMessage -Type INFO -Message "Running complete rollback for edgeSite `"$CurrentEdgeSite`" (VMFS: remove VDS, datastore, cluster)."
    try { Remove-NonVmk0VmkernelInterfacesFromVds -ClusterName $ClusterName -VdsNames $VdsNamesForCleanup } catch { Write-LogMessage -Type WARNING -Message "Non-vmk0 VMkernel removal had errors during rollback (non-fatal): $($_.Exception.Message)." }
    $restoreResult = $null
    try { $restoreResult = Invoke-ManagementRestoreForCleanupWithTopologyFallback -ClusterName $ClusterName -NicListCount $NicListCountForRestore -VdsName $VdsName }
    catch { Write-LogMessage -Type WARNING -Message "Management restore during rollback failed: $($_.Exception.Message). Remove VDS and cluster manually if needed." }
    if ($restoreResult -and $restoreResult.RestoreAttempted -and -not $restoreResult.Success) {
        Write-LogMessage -Type WARNING -Message "Management was not moved to VSS; VDS removal may fail. Move vmk0 off the VDS manually if needed."
    }
    if (Test-SupervisorDeployedOnCluster -ClusterName $ClusterName) {
        $Script:RollbackFailed = $true
        $errorMsg = "Supervisor is active on cluster `"$ClusterName`" from a prior deployment. VDS and cluster cannot be removed while the supervisor is running. Deactivate it first with -CleanUp Supervisor, then remove compute with -CleanUp Compute."
        Write-LogMessage -Type ERROR -Message $errorMsg
        throw [VcfDeploymentException]::new($errorMsg)
    }
    $vdsClusterSucceeded = Remove-VdsTrioAndCluster -ClusterName $ClusterName -VdsNamesForCleanup $VdsNamesForCleanup
    if ($vdsClusterSucceeded) {
        Remove-DatastoreByName -ClusterName $ClusterName -DatastoreName $DatastoreName
    } else {
        Write-LogMessage -Type WARNING -Message "VDS removal failed during rollback; skipping VMFS datastore removal. Remove the datastore manually if desired."
    }
    Write-LogMessage -Type INFO -Message "Compute rollback completed for edgeSite `"$CurrentEdgeSite`"."
}
function Invoke-ComputePreSupervisorRollback {

    <#
        .SYNOPSIS
        Performs compute-level rollback after a pre-supervisor deployment failure.

        .DESCRIPTION
        Handles the compute teardown when Initialize-VcfEdgeAtScale fails before supervisor creation.
        Prompts for rollback confirmation, then removes VMkernel interfaces, restores management
        networking to VSS, and tears down storage and cluster resources based on storage type:
        - vSAN-ESA/OSA: removes VMkernel interfaces, restores management, runs Invoke-VsanDeploymentRollback,
          removes VDS(es), removes cluster, then throws VcfDeploymentException to signal clean failure.
        - VMFS: removes VMkernel interfaces, restores management, removes VDS(es), removes cluster and
          datastore, returns ShouldContinue = $false so the caller throws VcfDeploymentException.
        When the operator declines rollback or a RollbackSkippedException is raised, returns
        ShouldContinue = $true so the caller continues to the next cluster site.

        .PARAMETER Context
        Hashtable with the following keys:
          Cluster                — PSCustomObject cluster spec from infrastructure.json
          ClusterName            — vCenter cluster name
          ClustersToProcessCount — total number of clusters in this run (for SingleSite determination)
          CurrentEdgeSite        — edge site identifier for log messages
          DatastoreName          — VMFS datastore name (used for VMFS rollback only)
          EsxHosts               — array of ESX host names in this cluster
          InputData              — full infrastructure JSON object
          StoragePolicyTagCatalog — tag catalog name for vSAN storage policy tag removal; $null to skip
          StoragePolicyType      — vSAN-ESA, vSAN-OSA, or VMFS
          VdsName                — base VDS name (sw1 and sw2 variants derived automatically)

        .OUTPUTS
        [Hashtable]. Returns @{ ShouldContinue = $true } when the caller should continue to the
        next cluster site (operator declined rollback or RollbackSkippedException). Never returns
        @{ ShouldContinue = $false } — for completed rollbacks the function throws directly.

        .EXAMPLE
        $rollbackResult = Invoke-ComputePreSupervisorRollback -Context @{
            Cluster = $cluster; ClusterName = $clusterName; ClustersToProcessCount = 2
            CurrentEdgeSite = "edge1"; DatastoreName = "datastore-edge1"; EsxHosts = @()
            InputData = $inputData; StoragePolicyTagCatalog = $null
            StoragePolicyType = "vSAN-ESA"; VdsName = "VDS-edge1-sw1"
        }
        if ($rollbackResult.ShouldContinue) { continue }

        .NOTES
        Sets $Script:RollbackFailed = $true when a critical rollback step fails, preventing a
        second rollback attempt if the exception is caught again.
    #>

    [CmdletBinding()]
    [OutputType([Hashtable])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Hashtable]$Context
    )

    Assert-ContextKeys -CallerName "Invoke-ComputePreSupervisorRollback" -Context $Context `
        -RequiredKeys @("Cluster", "ClusterName", "ClustersToProcessCount", "CurrentEdgeSite",
            "DatastoreName", "EsxHosts", "InputData", "StoragePolicyTagCatalog",
            "StoragePolicyType", "VdsName")

    $cluster                = $Context.Cluster
    $clusterName            = $Context.ClusterName
    $isSingleSite           = ($Context.ClustersToProcessCount -eq 1)
    $currentEdgeSite        = $Context.CurrentEdgeSite
    $datastoreName          = $Context.DatastoreName
    $esxHosts               = $Context.EsxHosts
    $inputData              = $Context.InputData
    $storagePolicyTagCatalog = $Context.StoragePolicyTagCatalog
    $storagePolicyType      = $Context.StoragePolicyType
    $vdsName                = $Context.VdsName

    $nicListForRestore = Get-EffectiveNicListForCluster -Cluster $cluster -CommonNicList $inputData.common.nicList
    if (-not $nicListForRestore -or $nicListForRestore.Count -eq 0) { $nicListForRestore = $inputData.common.nicList }
    $nicListCountForRestore = if ($nicListForRestore -and $nicListForRestore.Count -eq 4) { 4 } else { 2 }
    $vdsNamesForCleanup = @($vdsName, "$vdsName-sw1", "$vdsName-sw2")

    if ($storagePolicyType -eq "vSAN-ESA" -or $storagePolicyType -eq "vSAN-OSA") {
        $rollbackDecision = Invoke-PauseBeforeRollbackIfRequested -ForcePrompt -RollbackContext "vSAN deployment failure (edgeSite `"$currentEdgeSite`")" -SingleSite:$isSingleSite
        if ($rollbackDecision -eq "DoNotRollback") {
            Write-LogMessage -Type WARNING -Message "Rollback skipped for edgeSite `"$currentEdgeSite`"; leaving site in current state. Continuing to next site."
            return @{ ShouldContinue = $true }
        }
        $deploymentFailureMessage = $_.Exception.Message
        try {
            $vsanCompleted = Invoke-VsanPreSupervisorRollbackCore `
                -Cluster $cluster `
                -ClusterName $clusterName `
                -CurrentEdgeSite $currentEdgeSite `
                -EsxHosts $esxHosts `
                -InputData $inputData `
                -IsSingleSite:$isSingleSite `
                -NicListCountForRestore $nicListCountForRestore `
                -StoragePolicyTagCatalog $storagePolicyTagCatalog `
                -StoragePolicyType $storagePolicyType `
                -VdsName $vdsName `
                -VdsNamesForCleanup $vdsNamesForCleanup
        } catch [RollbackSkippedException] {
            Write-LogMessage -Type WARNING -Message "Skipping rollback for edgeSite `"$currentEdgeSite`"; leaving site in current state. Continuing to next site."
            return @{ ShouldContinue = $true }
        } catch { throw }
        if ($vsanCompleted) {
            $errorMsg = "Deployment failed for edgeSite `"$currentEdgeSite`" (rollback completed). $deploymentFailureMessage"
            Write-LogMessage -Type ERROR -Message $errorMsg
            throw [VcfDeploymentException]::new($errorMsg)
        }
    } elseif ($storagePolicyType -eq "VMFS") {
        $rollbackDecision = Invoke-PauseBeforeRollbackIfRequested -ForcePrompt -RollbackContext "deployment failure (edgeSite `"$currentEdgeSite`"); compute rollback" -SingleSite:$isSingleSite
        if ($rollbackDecision -eq "DoNotRollback") {
            Write-LogMessage -Type WARNING -Message "Rollback skipped for edgeSite `"$currentEdgeSite`"; leaving site in current state. Continuing to next site."
            return @{ ShouldContinue = $true }
        }
        Invoke-VmfsPreSupervisorRollbackCore `
            -ClusterName $clusterName `
            -CurrentEdgeSite $currentEdgeSite `
            -DatastoreName $datastoreName `
            -NicListCountForRestore $nicListCountForRestore `
            -VdsName $vdsName `
            -VdsNamesForCleanup $vdsNamesForCleanup
    }
    return @{ ShouldContinue = $false }
}
function Get-InitializationConfigFromJson {

    <#
        .SYNOPSIS
        Reads the infrastructure JSON and extracts all deployment configuration flags, prefixes, and cluster list.

        .DESCRIPTION
        Parses the infrastructure JSON file via ConvertFrom-JsonSafely, resolves referenced file paths, sets the
        module-level vCenter name and user, and returns a flat hashtable of all configuration values consumed by
        Initialize-VcfEdgeAtScale. Throws VcfDeploymentException when no clusters are defined.

        .PARAMETER EdgeSite
        Optional. When specified, only clusters whose edgeSite matches one of the comma-separated values are
        returned in ClustersToProcess.

        .PARAMETER InfrastructureJson
        Absolute path to the infrastructure.json file.

        .EXAMPLE
        $config = Get-InitializationConfigFromJson -InfrastructureJson $InfrastructureJson
        $clustersToProcess = $config.ClustersToProcess

        .NOTES
        Sets $Script:vCenterName and $Script:VCenterUser as side effects so that callers and all downstream
        functions that reference those module-level variables see the correct values immediately.
    #>

    [CmdletBinding()]
    [OutputType([Hashtable])]
    Param (
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$EdgeSite,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$InfrastructureJson
    )

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
        $esxUniquePassword = -not [Bool]$inputData.common.esxUniquePasswordPerHost
    }
    # nonInteractivePassword: when omitted or false, use normal password prompts. When true, try VCENTER_COMMON_PASSWORD / ESX_COMMON_PASSWORD env vars first and fall back to prompt on auth failure.
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
    $contextName    = $inputData.common.contextName
    # Supervisor content library: optional. Workflow runs only when key supervisorContentLibraryDatastore is present (key removed = skip).
    $supervisorContentLibraryDatastoreKeyPresent = $inputData.common -and $null -ne $inputData.common.PSObject.Properties["supervisorContentLibraryDatastore"]
    $supervisorContentLibraryDatastore = if ($supervisorContentLibraryDatastoreKeyPresent) { $inputData.common.supervisorContentLibraryDatastore } else { $null }
    $defaultSupervisorContentLibrarySubscriptionUrl = "https://wp-content.vmware.com/supervisor/v1/latest/lib.json"
    $supervisorContentLibrarySubscriptionUrl = if ($supervisorContentLibraryDatastoreKeyPresent) { if ($inputData.common -and $null -ne $inputData.common.PSObject.Properties["supervisorContentLibrarySubscriptionUrl"]) { $inputData.common.supervisorContentLibrarySubscriptionUrl } else { $defaultSupervisorContentLibrarySubscriptionUrl } } else { $null }

    # Extract prefixes; defaults per project guidelines when key is absent.
    $clusterNamePrefix   = if ($inputData.common.clusterNamePrefix)   { $inputData.common.clusterNamePrefix }   else { "cluster" }
    $datastoreNamePrefix = if ($inputData.common.datastoreNamePrefix) { $inputData.common.datastoreNamePrefix } else { "datastore" }
    $vdsNamePrefix       = if ($inputData.common.vdsNamePrefix)       { $inputData.common.vdsNamePrefix }       else { "VDS" }
    $supervisorNamePrefix = if ($inputData.common.supervisorNamePrefix) { $inputData.common.supervisorNamePrefix } else { "supervisor" }
    $esxUser             = if ($inputData.common.esxUser)             { $inputData.common.esxUser }             else { "root" }

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
        $errorMsg = "No clusters found in infrastructure JSON."
        Write-LogMessage -Type ERROR -Message $errorMsg
        throw [VcfDeploymentException]::new($errorMsg)
    }

    return @{
        ClusterNamePrefix                        = $clusterNamePrefix
        ClustersToProcess                        = $clustersToProcess
        ContextName                              = $contextName
        DatacenterName                           = $datacenterName
        DatastoreNamePrefix                      = $datastoreNamePrefix
        EsxUniquePassword                        = $esxUniquePassword
        EsxUser                                  = $esxUser
        InputData                                = $inputData
        LabEnvironment                           = $labEnvironment
        NonInteractivePassword                   = $nonInteractivePassword
        PreserveAutoGeneratedKeyCertPair         = $preserveAutoGeneratedKeyCertPair
        SupervisorContentLibraryDatastore        = $supervisorContentLibraryDatastore
        SupervisorContentLibraryDatastorePresent = $supervisorContentLibraryDatastoreKeyPresent
        SupervisorContentLibrarySubscriptionUrl  = $supervisorContentLibrarySubscriptionUrl
        SupervisorNamePrefix                     = $supervisorNamePrefix
        VdsNamePrefix                            = $vdsNamePrefix
    }
}
function Invoke-ClusterPhaseSequence {

    <#
    .SYNOPSIS
        Runs all deployment phases for one cluster iteration.

    .DESCRIPTION
        Called by Invoke-ClusterDeploymentIteration inside a try block. Executes in order:
        ESX credential/datastore setup, optional supervisor content library initialization,
        cluster creation, host addition, pre-supervisor setup, and supervisor deployment.

        Returns early with ShouldContinue=$true when a phase requests skip-to-next-site.
        No try/catch — all exceptions propagate so the caller can handle typed exceptions
        (RollbackSkippedException, generic errors) in one place.

    .PARAMETER Context
        Full deployment context hashtable, same structure as Invoke-ClusterDeploymentIteration.

    .PARAMETER SiteVars
        Per-site resolved variables returned by Invoke-ClusterPerSiteVariables.

    .OUTPUTS
        [Hashtable] with keys ShouldContinue and EsxUsedEnvPassword.

    .EXAMPLE
        try {
            $phaseResult = Invoke-ClusterPhaseSequence -Context $ctx -SiteVars $siteVars
        } catch [RollbackSkippedException] { ... }

    .NOTES
        $Script:SupervisorName must be set by the caller before invoking this function.
        $Script:VcenterCredential is consumed directly as a module-scope variable.
    #>

    [CmdletBinding()]
    [OutputType([Hashtable])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Hashtable]$Context,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSCustomObject]$SiteVars
    )

    # $Context.EsxPasswords and $Context.EsxVersionChecked are hashtable refs; mutations propagate to caller.
    $esxSetupResult = Invoke-EsxCredentialAndDatastoreSetup -Context @{
        DatastoreName      = $SiteVars.DatastoreName
        EsxHosts           = $SiteVars.EsxHosts
        EsxPasswords       = $Context.EsxPasswords
        EsxUniquePassword  = $Context.EsxUniquePassword
        EsxUsedEnvPassword = $Context.EsxUsedEnvPassword
        EsxUser            = $Context.EsxUser
        EsxVersionChecked  = $Context.EsxVersionChecked
        StoragePolicyType  = $SiteVars.StoragePolicyType
    }
    $diskCanonicalName  = $esxSetupResult.DiskCanonicalName
    $esxUsedEnvPassword = $esxSetupResult.EsxUsedEnvPassword

    if ($Context.SupervisorContentLibraryDatastorePresent) {
        Initialize-SupervisorContentLibrary `
            -DatastoreName $Context.SupervisorContentLibraryDatastore `
            -LibraryName $Script:SupervisorName `
            -SubscriptionUrl $Context.SupervisorContentLibrarySubscriptionUrl
    } else {
        Write-LogMessage -Type DEBUG -Message "Supervisor content library skipped (common.supervisorContentLibraryDatastore key not defined)."
    }

    Invoke-ClusterCreationPhase -Cluster $Context.Cluster -ClusterName $SiteVars.ClusterName `
        -DatacenterName $Context.DatacenterName -InputData $Context.InputData `
        -StoragePolicyType $SiteVars.StoragePolicyType

    Invoke-ClusterHostAdditionPhase -Context @{
        Cluster                          = $Context.Cluster
        ClusterName                      = $SiteVars.ClusterName
        DatacenterName                   = $Context.DatacenterName
        DelayBeforeAddingNextHostSeconds = $Context.DelayBeforeAddingNextHostSeconds
        EsxHosts                         = $SiteVars.EsxHosts
        EsxPasswords                     = $Context.EsxPasswords
        EsxUniquePassword                = $Context.EsxUniquePassword
        EsxUser                          = $Context.EsxUser
        InputData                        = $Context.InputData
        NetworkSegments                  = $SiteVars.NetworkSegments
        NicList                          = $SiteVars.NicList
        NumUplinks                       = $SiteVars.NumUplinks
        StoragePolicyType                = $SiteVars.StoragePolicyType
        VdsName                          = $SiteVars.VdsName
    }

    $preSupervisorResult = Invoke-ClusterPreSupervisorPhase -Context @{
        AcceptBadCheckResults   = $Context.AcceptBadCheckResults
        Cluster                 = $Context.Cluster
        ClusterName             = $SiteVars.ClusterName
        ComputeOnly             = $Context.ComputeOnly
        CurrentEdgeSite         = $SiteVars.EdgeSite
        DatastoreName           = $SiteVars.DatastoreName
        DiskCanonicalName       = $diskCanonicalName
        EffectiveHaPolicy       = $SiteVars.EffectiveMultiHostHaPolicy
        EsxHosts                = $SiteVars.EsxHosts
        InputData               = $Context.InputData
        LabEnvironment          = $Context.LabEnvironment
        StoragePolicyName       = $SiteVars.StoragePolicyName
        StoragePolicyTagCatalog = $SiteVars.StoragePolicyTagCatalog
        StoragePolicyType       = $SiteVars.StoragePolicyType
        SupervisorName          = $Script:SupervisorName
    }
    if ($preSupervisorResult.ShouldContinue) {
        return @{ ShouldContinue = $true; EsxUsedEnvPassword = $esxUsedEnvPassword }
    }

    # Supervisor/ArgoCD/Harbor-specific rollback is handled inside the phase function.
    # We do NOT disconnect from vCenter between clusters when they share the same vCenter FQDN.
    $continueToNextSite = Invoke-SupervisorDeploymentPhase -Context @{
        ArgoCdDeploymentYamlPath     = $SiteVars.ArgoCdDeploymentYamlPath
        ArgoCDyaml                   = $SiteVars.ArgoCDYaml
        ArgocdNameSpacePrefix        = $SiteVars.ArgocdNameSpacePrefix
        ArgocdVmClass                = $SiteVars.ArgocdVmClass
        Cluster                      = $Context.Cluster
        ClusterId                    = $preSupervisorResult.ClusterId
        ClusterName                  = $SiteVars.ClusterName
        ClustersToProcessCount       = $Context.ClustersToProcessCount
        ContextName                  = $Context.ContextName
        CurrentEdgeSite              = $SiteVars.EdgeSite
        SkipArgoCDDeployment                = $SiteVars.SkipArgoCDDeployment
        SkipHarborDeployment                = $SiteVars.SkipHarborDeployment
        InfrastructureJson           = $Context.InfrastructureJson
        InputData                    = $Context.InputData
        LabEnvironment               = $Context.LabEnvironment
        NetworkSegments              = $SiteVars.NetworkSegments
        PreserveAutoGeneratedKeyCert = $Context.PreserveAutoGeneratedKeyCertPair
        SaveHarborYaml               = $Context.SaveHarborYaml
        StoragePolicyId              = $preSupervisorResult.StoragePolicyId
        StoragePolicyName            = $SiteVars.StoragePolicyName
        StoragePolicyType            = $SiteVars.StoragePolicyType
        SupervisorJson               = $Context.SupervisorJson
        VcenterCredential            = $Script:VcenterCredential
    }
    return @{ ShouldContinue = $continueToNextSite; EsxUsedEnvPassword = $esxUsedEnvPassword }
}
function Invoke-ClusterDeploymentIteration {

    <#
    .SYNOPSIS
        Executes one per-cluster deployment iteration, including all phases and rollback handling.

    .DESCRIPTION
        Encapsulates the body of the per-cluster deployment loop in Initialize-VcfEdgeAtScale.
        Resets rollback flags, resolves site variables, then delegates to Invoke-ClusterPhaseSequence
        for the happy-path deployment. Handles RollbackSkippedException and compute-level error
        rollback, returning a ShouldContinue flag so the caller can issue the correct foreach continue.

    .PARAMETER Context
        Hashtable carrying all per-iteration inputs. Required keys:
            AcceptBadCheckResults, Cluster, ClusterIndex, ClusterNamePrefix, ClustersToProcessCount,
            ComputeOnly, ContextName, DatacenterName, DatastoreNamePrefix,
            DelayBeforeAddingNextHostSeconds, EsxPasswords (hashtable ref, mutations propagate),
            EsxUniquePassword, EsxUsedEnvPassword, EsxUser,
            EsxVersionChecked (hashtable ref, mutations propagate), InfrastructureJson, InputData,
            LabEnvironment, PreserveAutoGeneratedKeyCertPair, SaveHarborYaml,
            SupervisorContentLibraryDatastore, SupervisorContentLibraryDatastorePresent,
            SupervisorContentLibrarySubscriptionUrl, SupervisorJson, SupervisorNamePrefix,
            VdsNamePrefix.

    .OUTPUTS
        [Hashtable] with keys:
            ShouldContinue     — $true when the caller should issue a foreach continue.
            EsxUsedEnvPassword — updated flag reflecting whether the env-var password was used.

    .EXAMPLE
        $iterResult = Invoke-ClusterDeploymentIteration -Context $ctx
        $esxUsedEnvPassword = $iterResult.EsxUsedEnvPassword
        if ($iterResult.ShouldContinue) { continue }

    .NOTES
        $Script:RollbackAttempted, $Script:RollbackFailed, $Script:ArgoCDPhaseStarted,
        $Script:HarborPhaseStarted, $Script:DidMigrateVmk0ToVdsThisRun, and
        $Script:SupervisorName are set as module-scope side effects; callers rely on these values
        after the iteration completes.

        Write-Host is the primary output mechanism in this function; all Write-Host calls are
        intentional interactive console output. Use Write-LogMessage for diagnostic logging.
    #>

    [CmdletBinding()]
    [OutputType([Hashtable])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Hashtable]$Context
    )

    Assert-ContextKeys -CallerName "Invoke-ClusterDeploymentIteration" -Context $Context `
        -RequiredKeys @("AcceptBadCheckResults", "Cluster", "ClusterIndex", "ClusterNamePrefix",
            "ClustersToProcessCount", "ComputeOnly", "ContextName", "DatacenterName",
            "DatastoreNamePrefix", "DelayBeforeAddingNextHostSeconds", "EsxPasswords",
            "EsxUniquePassword", "EsxUsedEnvPassword", "EsxUser", "EsxVersionChecked",
            "InfrastructureJson", "InputData", "LabEnvironment", "PreserveAutoGeneratedKeyCertPair",
            "SaveHarborYaml", "SupervisorContentLibraryDatastorePresent", "SupervisorJson",
            "SupervisorNamePrefix", "VdsNamePrefix")

    $Script:RollbackAttempted = $false
    $Script:RollbackFailed = $false
    $Script:ArgoCDPhaseStarted = $false
    $Script:HarborPhaseStarted = $false
    $Script:DidMigrateVmk0ToVdsThisRun = $false

    $siteVars = Invoke-ClusterPerSiteVariables `
        -Cluster $Context.Cluster -ClusterNamePrefix $Context.ClusterNamePrefix `
        -DatastoreNamePrefix $Context.DatastoreNamePrefix -InputData $Context.InputData `
        -SupervisorNamePrefix $Context.SupervisorNamePrefix -VdsNamePrefix $Context.VdsNamePrefix
    $Script:SupervisorName = $siteVars.SupervisorName
    $currentEdgeSite       = $siteVars.EdgeSite
    $clusterName           = $siteVars.ClusterName

    if ($Context.ClusterIndex -gt 1) {
        Write-Host ""
        Write-LogMessage -Type INFO -Message "Starting deployment for edgeSite: `"$currentEdgeSite`" (site $Context.ClusterIndex of $Context.ClustersToProcessCount)."
        Write-Host ""
    }

    try {
        return Invoke-ClusterPhaseSequence -Context $Context -SiteVars $siteVars
    } catch [RollbackSkippedException] {
        Write-LogMessage -Type WARNING -Message "Skipping rollback for edgeSite `"$currentEdgeSite`"; leaving site in current state. Continuing to next site."
        return @{ ShouldContinue = $true; EsxUsedEnvPassword = $Context.EsxUsedEnvPassword }
    } catch {
        if ($Script:RollbackFailed) {
            Write-LogMessage -Type ERROR -Message "Rollback failed for edgeSite `"$currentEdgeSite`"; exiting with failure (no second rollback prompt)."
            throw
        }
        if ($Script:RollbackAttempted) {
            Write-LogMessage -Type INFO -Message "Rollback was already attempted for this failure; rethrowing without prompting again."
            throw
        }
        # Pre-supervisor failure — compute-level rollback (supervisor/ArgoCD/Harbor rollback is handled inside Invoke-SupervisorDeploymentPhase).
        $rollbackResult = Invoke-ComputePreSupervisorRollback -Context @{
            Cluster                 = $Context.Cluster
            ClusterName             = $clusterName
            ClustersToProcessCount  = $Context.ClustersToProcessCount
            CurrentEdgeSite         = $currentEdgeSite
            DatastoreName           = $siteVars.DatastoreName
            EsxHosts                = $siteVars.EsxHosts
            InputData               = $Context.InputData
            StoragePolicyTagCatalog = $siteVars.StoragePolicyTagCatalog
            StoragePolicyType       = $siteVars.StoragePolicyType
            VdsName                 = $siteVars.VdsName
        }
        if ($rollbackResult.ShouldContinue) {
            return @{ ShouldContinue = $true; EsxUsedEnvPassword = $Context.EsxUsedEnvPassword }
        }
        throw [VcfDeploymentException]::new("Deployment iteration failed for edgeSite `"$currentEdgeSite`" and rollback did not request continuation.")
    }
}
function Get-AllEsxHostsFromClusters {

    <#
        .SYNOPSIS
        Returns a de-duplicated ordered list of all ESX host strings from a collection of cluster config objects.

        .DESCRIPTION
        Iterates $ClustersToProcess, reads each cluster's esxHosts array, and adds each non-empty FQDN or IP
        string to the result exactly once (case-insensitive de-duplication). Used to build the unique host list
        for TCP reachability probes and pre-flight version checks before any cluster is created.

        .PARAMETER ClustersToProcess
        Array of cluster configuration objects, each expected to have an esxHosts property.

        .EXAMPLE
        $allHosts = Get-AllEsxHostsFromClusters -ClustersToProcess $clustersToProcess

        .NOTES
        Returns an empty list when no clusters contain esxHosts entries. Does not throw.
    #>

    [CmdletBinding()]
    [OutputType([System.Collections.Generic.List[object]])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [AllowEmptyCollection()] [Object[]]$ClustersToProcess
    )

    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($cluster in $ClustersToProcess) {
        if ($cluster.esxHosts) {
            foreach ($esxHost in $cluster.esxHosts) {
                if (-not [String]::IsNullOrWhiteSpace($esxHost) -and $seen.Add($esxHost)) {
                    $result.Add($esxHost)
                }
            }
        }
    }
    return $result
}
function Invoke-PreDeployCleanupIfRequested {

    <#
        .SYNOPSIS
        Runs the cleanup workflow when the $CleanUp parameter is set and returns $true to signal the caller to exit.

        .DESCRIPTION
        Resolves the Harbor YAML path for "All" and "Harbor" cleanup scopes (Harbor PVCs must be removed before
        storage teardown), then calls Invoke-VcfEdgeAtScaleCleanup and logs completion. Returns $true when
        cleanup was performed so the caller (Initialize-VcfEdgeAtScale) can return without deploying.
        Returns $false when $CleanUp is not in the supported set (caller continues with deployment).

        .PARAMETER CleanUp
        Cleanup scope: one of All, ArgoCD, Compute, Harbor, Supervisor.

        .PARAMETER ClusterNamePrefix
        Cluster name prefix, forwarded to Invoke-VcfEdgeAtScaleCleanup.

        .PARAMETER ClustersToProcess
        Array of cluster config objects used to resolve the Harbor YAML path.

        .PARAMETER DatastoreNamePrefix
        Datastore name prefix, forwarded to Invoke-VcfEdgeAtScaleCleanup.

        .PARAMETER Force
        When set, bypasses the cleanup confirmation prompt (requires labEnvironment=true).

        .PARAMETER InputData
        Parsed infrastructure JSON object, used to resolve supervisor service flags and YAML paths.

        .PARAMETER LabEnvironment
        When $true, TLS certificate verification is disabled for REST API calls during cleanup.

        .PARAMETER SupervisorNamePrefix
        Supervisor name prefix, forwarded to Invoke-VcfEdgeAtScaleCleanup.

        .PARAMETER VdsNamePrefix
        VDS name prefix, forwarded to Invoke-VcfEdgeAtScaleCleanup.

        .EXAMPLE
        if (Invoke-PreDeployCleanupIfRequested -CleanUp $CleanUp -ClusterNamePrefix $clusterNamePrefix ...) { return }

        .NOTES
        Returns [Bool]: $true when cleanup was performed, $false otherwise.
        Interactive function — does not throw; logs errors and returns $false on unexpected failures.
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$CleanUp,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterNamePrefix,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [AllowEmptyCollection()] [Object[]]$ClustersToProcess,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DatastoreNamePrefix,
        [Parameter(Mandatory = $false)] [Switch]$Force,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSCustomObject]$InputData,
        [Parameter(Mandatory = $false)] [Switch]$LabEnvironment,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorNamePrefix,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VdsNamePrefix
    )

    if ($CleanUp -notin @("Supervisor", "Compute", "All", "ArgoCD", "Harbor")) {
        return $false
    }

    $cleanupParams = @{
        CleanUp             = $CleanUp
        ClusterNamePrefix   = $ClusterNamePrefix
        ClustersToProcess   = $ClustersToProcess
        DatastoreNamePrefix = $DatastoreNamePrefix
        Force               = $Force
        InputData           = $InputData
        LabEnvironment      = $LabEnvironment
        SupervisorNamePrefix = $SupervisorNamePrefix
        VdsNamePrefix       = $VdsNamePrefix
    }
    if ($CleanUp -in @("All", "Harbor", "Supervisor")) {
        # Resolve Harbor YAML path for Harbor, All, and Supervisor scopes: all three remove the Harbor
        # Supervisor Service before deactivating the supervisor so PVCs are gone before storage teardown.
        $harborCleanupYamlPath = $null
        foreach ($c in $ClustersToProcess) {
            if (-not (Get-EffectiveSupervisorServiceFlag -Cluster $c -CommonData $InputData.common -FlagName "disableHarbor")) {
                $harborCleanupYamlPath = Get-EffectiveSupervisorServicesYamlPath -Cluster $c -CommonData $InputData.common -LogicalYamlPathPropertyName "harborServiceYamlPath"
                break
            }
        }
        if ($harborCleanupYamlPath) {
            $cleanupParams["HarborServiceYamlPath"] = $harborCleanupYamlPath
        }
    }
    Invoke-VcfEdgeAtScaleCleanup @cleanupParams
    Write-LogMessage -Type INFO -Message "CleanUp ($CleanUp) completed. Exiting without deployment."
    return $true
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

        Write-Host is the primary output mechanism in this function; all Write-Host calls are
        intentional interactive console output (status displays, progress separators, prompts).
        Use Write-LogMessage for diagnostic logging.

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

    try {
        $initConfig = Get-InitializationConfigFromJson -EdgeSite $EdgeSite -InfrastructureJson $InfrastructureJson
        $inputData                                   = $initConfig.InputData
        $labEnvironment                              = $initConfig.LabEnvironment
        $esxUniquePassword                           = $initConfig.EsxUniquePassword
        $nonInteractivePassword                      = $initConfig.NonInteractivePassword
        $preserveAutoGeneratedKeyCertPair            = $initConfig.PreserveAutoGeneratedKeyCertPair
        $datacenterName                              = $initConfig.DatacenterName
        $contextName                                 = $initConfig.ContextName
        $supervisorContentLibraryDatastoreKeyPresent = $initConfig.SupervisorContentLibraryDatastorePresent
        $supervisorContentLibraryDatastore           = $initConfig.SupervisorContentLibraryDatastore
        $supervisorContentLibrarySubscriptionUrl     = $initConfig.SupervisorContentLibrarySubscriptionUrl
        $clusterNamePrefix                           = $initConfig.ClusterNamePrefix
        $datastoreNamePrefix                         = $initConfig.DatastoreNamePrefix
        $vdsNamePrefix                               = $initConfig.VdsNamePrefix
        $supervisorNamePrefix                        = $initConfig.SupervisorNamePrefix
        $esxUser                                     = $initConfig.EsxUser
        $clustersToProcess                           = $initConfig.ClustersToProcess
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

        $allEsxHosts = Get-AllEsxHostsFromClusters -ClustersToProcess $clustersToProcess

        if ($allEsxHosts.Count -gt 0) {
            Write-LogMessage -Type INFO -Message "Performing ESX reachability check (TCP 443) for $($allEsxHosts.Count) host(s)..."
            Test-VcenterAndEsxReachability -EsxHosts $allEsxHosts -Port 443 -VcenterName $Script:vCenterName
        }

        # Acquire vCenter credentials (env-var-first when nonInteractivePassword; interactive fallback), connect, and verify
        # version and supervisor count. Sets $Script:VcenterCredential as a side effect via Set-ScriptVcenterCredential.
        Invoke-VcenterConnectionAndValidation `
            -MaximumSupervisorsPerVcenter $MaximumSupervisorsPerVcenter `
            -NonInteractivePassword $nonInteractivePassword `
            -VcenterName $Script:vCenterName `
            -VcenterUser $Script:VCenterUser | Out-Null

        # When -CleanUp is set, run the cleanup workflow and exit without deploying.
        # Guard with ContainsKey: $CleanUp is optional and empty string fails ValidateNotNullOrEmpty
        # on the helper's parameter when the caller omits -CleanUp entirely.
        if ($PSBoundParameters.ContainsKey("CleanUp") -and (Invoke-PreDeployCleanupIfRequested `
                -CleanUp $CleanUp `
                -ClusterNamePrefix $clusterNamePrefix `
                -ClustersToProcess $clustersToProcess `
                -DatastoreNamePrefix $datastoreNamePrefix `
                -Force:$Force.IsPresent `
                -InputData $inputData `
                -LabEnvironment:$labEnvironment `
                -SupervisorNamePrefix $supervisorNamePrefix `
                -VdsNamePrefix $vdsNamePrefix)) {
            return
        }

        if ($PSBoundParameters.ContainsKey("Force") -and $Force) {
            Write-LogMessage -Type INFO -Message "-Force is ignored when not performing cleanup."
        }

        # Fail-fast: vSAN witness hosts must be in vCenter inventory before any cluster is created.
        Invoke-WitnessHostPreflightCheck -ClustersToProcess $clustersToProcess -InputData $inputData

        # Collect ESX credentials (env var first when nonInteractivePassword; interactive fallback).
        $esxCredResult      = Invoke-EsxCredentialCollection -AllEsxHosts $allEsxHosts -EsxUniquePassword $esxUniquePassword -EsxUser $esxUser -NonInteractivePassword $nonInteractivePassword
        $esxPasswords       = $esxCredResult.EsxPasswords
        $esxUsedEnvPassword = $esxCredResult.EsxUsedEnvPassword

        # ESX pre-flight version check: fail-fast before any cluster is created; auth failures deferred.
        $esxVersionChecked = Invoke-EsxPreFlightVersionCheck -AllEsxHosts $allEsxHosts -EsxPasswords $esxPasswords

        $clusterIndex = 0
        foreach ($cluster in $clustersToProcess) {
            $clusterIndex++
            $iterContext = @{
                AcceptBadCheckResults                    = $AcceptBadCheckResults.IsPresent
                Cluster                                  = $cluster
                ClusterIndex                             = $clusterIndex
                ClusterNamePrefix                        = $clusterNamePrefix
                ClustersToProcessCount                   = $clustersToProcess.Count
                ComputeOnly                              = $ComputeOnly.IsPresent
                ContextName                              = $contextName
                DatacenterName                           = $datacenterName
                DatastoreNamePrefix                      = $datastoreNamePrefix
                DelayBeforeAddingNextHostSeconds         = $DelayBeforeAddingNextHostSeconds
                EsxPasswords                             = $esxPasswords
                EsxUniquePassword                        = $esxUniquePassword
                EsxUsedEnvPassword                       = $esxUsedEnvPassword
                EsxUser                                  = $esxUser
                EsxVersionChecked                        = $esxVersionChecked
                InfrastructureJson                       = $InfrastructureJson
                InputData                                = $inputData
                LabEnvironment                           = $labEnvironment
                PreserveAutoGeneratedKeyCertPair         = $preserveAutoGeneratedKeyCertPair
                SaveHarborYaml                           = $SaveHarborYaml.IsPresent
                SupervisorContentLibraryDatastore        = $supervisorContentLibraryDatastore
                SupervisorContentLibraryDatastorePresent = $supervisorContentLibraryDatastoreKeyPresent
                SupervisorContentLibrarySubscriptionUrl  = $supervisorContentLibrarySubscriptionUrl
                SupervisorJson                           = $SupervisorJson
                SupervisorNamePrefix                     = $supervisorNamePrefix
                VdsNamePrefix                            = $vdsNamePrefix
            }
            $iterResult = Invoke-ClusterDeploymentIteration -Context $iterContext
            $esxUsedEnvPassword = $iterResult.EsxUsedEnvPassword
            if ($iterResult.ShouldContinue) { continue }
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
