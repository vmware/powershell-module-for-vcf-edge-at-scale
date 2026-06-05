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
#region Private — supervisor, Harbor, Argo CD, workload networking
function Invoke-SupervisorOnlyRollback {

    <#
        .SYNOPSIS
        Rolls back only the supervisor (disables it) on a cluster without touching compute, vSAN, or VDS.

        .DESCRIPTION
        Use when a failure occurs after the supervisor was enabled (e.g. ArgoCD or post-supervisor step failed).
        Respects -RollbackOnFailure: prompts or skips per preference, then disables the supervisor via Disable-SupervisorOnCluster.
        Does not call Invoke-VsanDeploymentRollback; cluster, vSAN, and VDS are left intact.

        .PARAMETER ClusterId
        The vCenter cluster MoRef (e.g. domain-c22).

        .PARAMETER ClusterName
        The cluster name for logging.

        .PARAMETER SingleSite
        When set, the rollback prompt shows only Y/N (no A=always), since there is no next site.

        .PARAMETER SupervisorId
        When set, Kubernetes status diagnostics are logged if supervisor deactivation times out.

        .EXAMPLE
        Invoke-SupervisorOnlyRollback -ClusterId "domain-c22" -ClusterName "cl0-site1"

        Prompts (or skips per -RollbackOnFailure), then disables the supervisor on the cluster; compute, vSAN, and VDS are unchanged.

        .OUTPUTS
        None. Throws if user chooses DoNotRollback (so caller can continue to next site).

        .NOTES
        Sets $Script:RollbackAttempted = $true to signal that a rollback was performed;
        the deployment orchestrator checks this flag to determine the final run status.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterId,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [Switch]$SingleSite,
        [Parameter(Mandatory = $false)] [String]$SupervisorId
    )

    $rollbackDecision = Invoke-PauseBeforeRollbackIfRequested -RollbackContext "supervisor-only rollback (cluster `"$ClusterName`")" -SingleSite:$SingleSite.IsPresent
    if ($rollbackDecision -eq "DoNotRollback") {
        throw [RollbackSkippedException]::new()
    }
    $Script:RollbackAttempted = $true
    Write-LogMessage -Type INFO -Message "Starting supervisor-only rollback for cluster `"$ClusterName`" (disabling supervisor; compute/vSAN/VDS unchanged)."
    $disableSplat = @{
        ClusterId = $ClusterId
        ClusterName = $ClusterName
        SuppressConfirm = $true
    }
    if (-not [String]::IsNullOrWhiteSpace($SupervisorId)) {
        $disableSplat["SupervisorId"] = $SupervisorId
    }
    $disableResult = Disable-SupervisorOnCluster @disableSplat
    if ($disableResult.Success) {
        Write-LogMessage -Type INFO -Message "Supervisor-only rollback completed for cluster `"$ClusterName`"."
    } else {
        Write-LogMessage -Type WARNING -Message "Supervisor deactivation did not complete: $($disableResult.ErrorMessage). Disable the supervisor manually in vCenter if needed."
    }
}
function Invoke-ArgoCDNamespaceDeleteAndPoll {

    <#
        .SYNOPSIS
        Deletes an ArgoCD namespace via the supervisor API and polls until it disappears.

        .DESCRIPTION
        Issues Invoke-DeleteNamespaceInstances for the specified namespace, then polls
        Invoke-ListNamespacesInstances at the configured interval until the namespace is gone or
        the timeout is reached. Logs and continues on timeout (the deletion was initiated; the
        operator is expected to verify). Logs a warning when the delete call itself fails.
        When SupervisorId is provided, runs Write-SupervisorKubernetesDiagnosticReport on timeout
        or exception to surface additional Kubernetes diagnostic context.

        .PARAMETER ArgoCDNamespace
        The ArgoCD namespace to delete.

        .PARAMETER ArgoCDNamespaceDeletePollIntervalSeconds
        Seconds between each namespace-list poll. Default is 5.

        .PARAMETER ArgoCDNamespaceDeleteTimeoutSeconds
        Maximum seconds to wait for the namespace to disappear. Default is 120.

        .PARAMETER ClusterName
        Cluster name used in log and diagnostic messages.

        .PARAMETER SupervisorId
        When set, enables Kubernetes diagnostic reporting on timeout or delete exception.

        .EXAMPLE
        Invoke-ArgoCDNamespaceDeleteAndPoll -ArgoCDNamespace "argocd-c354" -ClusterName "cluster-vsan-edge1"

        .NOTES
        Called only by Invoke-ArgoCDOnlyRollback. Does not return a value; logs warnings and
        continues on timeout or delete failure so the caller can report and proceed.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ArgoCDNamespace,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 60)] [Int]$ArgoCDNamespaceDeletePollIntervalSeconds = 5,
        [Parameter(Mandatory = $false)] [ValidateRange(10, 600)] [Int]$ArgoCDNamespaceDeleteTimeoutSeconds = 120,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [String]$SupervisorId
    )

    $progressActivity = "Waiting for ArgoCD namespace `"$ArgoCDNamespace`" to be removed"
    try {
        Invoke-DeleteNamespaceInstances -Namespace $ArgoCDNamespace -Confirm:$false -ErrorAction Stop | Out-Null
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
                    $stillExists = $namespaceList -contains $ArgoCDNamespace
                }
            } catch {
                Write-LogMessage -Type DEBUG -Message "Invoke-ListNamespacesInstances failed during poll; treating namespace as still present. $($_.Exception.Message)"
            }
            if (-not $stillExists) {
                Write-Progress -Activity $progressActivity -Status "Complete" -PercentComplete 100 -Completed
                [Console]::Out.Flush()
                Write-LogMessage -Type INFO -Message "ArgoCD namespace `"$ArgoCDNamespace`" deleted successfully for cluster `"$ClusterName`". Supervisor intact; you can re-run deployment."
                return
            }
            Write-LogMessage -Type DEBUG -Message "ArgoCD namespace `"$ArgoCDNamespace`" still present; waiting (elapsed ${elapsedSeconds}s, timeout ${ArgoCDNamespaceDeleteTimeoutSeconds}s)."
        }
        $stillExistsAfterWait = $true
        try {
            $namespaceListAfterWait = (Invoke-ListNamespacesInstances -ErrorAction Stop).Namespace
            if ($null -ne $namespaceListAfterWait) {
                $stillExistsAfterWait = $namespaceListAfterWait -contains $ArgoCDNamespace
            }
        } catch {
            Write-LogMessage -Type DEBUG -Message "Invoke-ListNamespacesInstances failed at timeout check; assuming namespace still present. $($_.Exception.Message)"
        }
        if ($stillExistsAfterWait) {
            Write-Progress -Activity $progressActivity -Status "Timeout" -Completed
            [Console]::Out.Flush()
            Write-LogMessage -Type WARNING -Message "ArgoCD namespace `"$ArgoCDNamespace`" still exists after ${ArgoCDNamespaceDeleteTimeoutSeconds}s. Delete was initiated; verify in vCenter. Supervisor intact; you can re-run deployment."
            if (-not [String]::IsNullOrWhiteSpace($SupervisorId)) {
                try {
                    Write-SupervisorKubernetesDiagnosticReport -ClusterName $ClusterName -Context "Argo CD namespace removal did not complete within the wait window" -SupervisorId $SupervisorId
                } catch {
                    Write-LogMessage -Type DEBUG -Message "Supervisor Kubernetes diagnostics (Argo CD rollback timeout): $($_.Exception.Message)"
                }
            }
        } else {
            Write-Progress -Activity $progressActivity -Status "Complete" -PercentComplete 100 -Completed
            [Console]::Out.Flush()
            Write-LogMessage -Type INFO -Message "ArgoCD namespace `"$ArgoCDNamespace`" deleted successfully for cluster `"$ClusterName`". Supervisor intact; you can re-run deployment."
        }
    } catch {
        Write-Progress -Activity $progressActivity -Status "Error" -Completed
        [Console]::Out.Flush()
        Write-LogMessage -Type WARNING -Message "ArgoCD-only rollback could not delete namespace `"$ArgoCDNamespace`" for cluster `"$ClusterName`": $($_.Exception.Message). Remove the namespace manually (e.g. -CleanUp ArgoCD) or disable the supervisor if needed. Supervisor is still enabled."
        if (-not [String]::IsNullOrWhiteSpace($SupervisorId)) {
            try {
                Write-SupervisorKubernetesDiagnosticReport -ClusterName $ClusterName -Context "Argo CD namespace removal failed with an exception" -SupervisorId $SupervisorId
            } catch {
                Write-LogMessage -Type DEBUG -Message "Supervisor Kubernetes diagnostics (Argo CD rollback error): $($_.Exception.Message)"
            }
        }
    }
}
function Invoke-ArgoCDOnlyRollback {

    <#
        .SYNOPSIS
        Rolls back only the ArgoCD deployment by removing the ArgoCD namespace; supervisor and compute remain intact.

        .DESCRIPTION
        Use when ArgoCD deployment fails after the supervisor was enabled. Removes the ArgoCD supervisor namespace (same removal path as -CleanUp ArgoCD) and polls until the namespace is gone. Supervisor is left enabled so you can fix the issue and re-run deployment idempotently from a good supervisor state.
        Respects -RollbackOnFailure: prompts or skips per preference. Does not call Disable-SupervisorOnCluster or Invoke-VsanDeploymentRollback.

        .PARAMETER ArgoCDNamespace
        The ArgoCD namespace to remove (e.g. argocd-c354).

        .PARAMETER ArgoCDNamespaceDeletePollIntervalSeconds
        Seconds between each check that the namespace is gone. Default is 5.

        .PARAMETER ArgoCDNamespaceDeleteTimeoutSeconds
        Maximum seconds to wait for the namespace to disappear. Default is 120.

        .PARAMETER ClusterName
        The cluster name for logging.

        .PARAMETER SupervisorId
        When set, Kubernetes status diagnostics are logged if namespace removal times out or fails.

        .EXAMPLE
        Invoke-ArgoCDOnlyRollback -ClusterName "cluster-OSA" -ArgoCDNamespace "argocd-c467"

        Removes the ArgoCD namespace and leaves the supervisor intact for retry.

        .OUTPUTS
        None. Throws if user chooses DoNotRollback (so caller can continue to next site).

        .NOTES
        Sets $Script:RollbackAttempted = $true to signal that a rollback was performed;
        the deployment orchestrator checks this flag to determine the final run status.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ArgoCDNamespace,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 60)] [Int]$ArgoCDNamespaceDeletePollIntervalSeconds = 5,
        [Parameter(Mandatory = $false)] [ValidateRange(10, 600)] [Int]$ArgoCDNamespaceDeleteTimeoutSeconds = 120,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [String]$SupervisorId
    )

    $rollbackDecision = Invoke-PauseBeforeRollbackIfRequested -RollbackContext "ArgoCD-only rollback (cluster `"$ClusterName`")" -ForcePrompt
    if ($rollbackDecision -eq "DoNotRollback") {
        throw [RollbackSkippedException]::new()
    }
    $Script:RollbackAttempted = $true
    Write-LogMessage -Type INFO -Message "Starting ArgoCD-only rollback for cluster `"$ClusterName`" (removing namespace `"$ArgoCDNamespace`"; supervisor left intact)."
    $namespaceExists = $false
    try {
        $namespaceExists = (Invoke-ListNamespacesInstances -ErrorAction Stop).Namespace -contains $ArgoCDNamespace
    } catch {
        Write-LogMessage -Type WARNING -Message "Could not list namespaces; assuming ArgoCD namespace exists and attempting delete. $($_.Exception.Message)"
        $namespaceExists = $true
    }
    if (-not $namespaceExists) {
        Write-LogMessage -Type INFO -Message "ArgoCD namespace `"$ArgoCDNamespace`" does not exist for cluster `"$ClusterName`". Nothing to remove."
        return
    }
    Invoke-ArgoCDNamespaceDeleteAndPoll `
        -ArgoCDNamespace $ArgoCDNamespace `
        -ArgoCDNamespaceDeletePollIntervalSeconds $ArgoCDNamespaceDeletePollIntervalSeconds `
        -ArgoCDNamespaceDeleteTimeoutSeconds $ArgoCDNamespaceDeleteTimeoutSeconds `
        -ClusterName $ClusterName `
        -SupervisorId $SupervisorId
}
function Write-HarborNamespaceTerminationDiagnostic {

    <#
    .SYNOPSIS
        Logs kubectl-based diagnostics for stuck Harbor service namespaces after a termination timeout.
    .DESCRIPTION
        For each namespace still present after the wait timeout, runs kubectl get to check for
        active finalizers, stuck PVCs, and stuck pods — all common blockers for namespace termination.
        Logs actionable remediation commands for each finding. Ends with a summary of manual resolution
        steps. Does not throw.
    .PARAMETER ClusterName
        Cluster name, used in remediation guidance.
    .PARAMETER StillPresent
        Array of namespace names that are still in the Terminating state.
    .PARAMETER SupervisorId
        Supervisor ID, used in log messages.
    .PARAMETER TimeoutSeconds
        The wait timeout that elapsed, used in log messages.
    .EXAMPLE
        Write-HarborNamespaceTerminationDiagnostic -ClusterName "cl1" -StillPresent @("svc-harbor-abc") -SupervisorId "domain-c1" -TimeoutSeconds 300
    .NOTES
        Uses $Script:KubectlCmd. Does not throw.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object[]]$StillPresent,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorId,
        [Parameter(Mandatory = $true)] [ValidateRange(1, 86400)] [Int]$TimeoutSeconds
    )

    foreach ($stuckNs in $StillPresent) {
        Write-LogMessage -Type WARNING -Message "--- Diagnostics for stuck namespace: `"$stuckNs`" ---"
        try {
            $finalizersOutput = & $Script:KubectlCmd get namespace "$stuckNs" -o jsonpath="{.metadata.finalizers} {.spec.finalizers}" 2>&1
            if ($LASTEXITCODE -eq 0 -and -not [String]::IsNullOrWhiteSpace($finalizersOutput) -and $finalizersOutput.Trim() -ne " ") {
                Write-LogMessage -Type WARNING -Message "Namespace `"$stuckNs`" has active finalizers preventing deletion: $($finalizersOutput.Trim())"
                Write-LogMessage -Type WARNING -Message "To manually remove finalizers and force termination (may leave orphaned NSX-T/LB resources):"
                Write-LogMessage -Type WARNING -Message "  kubectl patch namespace $stuckNs -p '{`"metadata`":{`"finalizers`":null}}' --type=merge"
            } else {
                Write-LogMessage -Type DEBUG -Message "Namespace `"$stuckNs`": no active finalizers found (termination may be delayed by resource GC)."
            }
        } catch {
            Write-LogMessage -Type DEBUG -Message "Could not query finalizers for `"$stuckNs`": $($_.Exception.Message)"
        }
        try {
            $pvcOutput = & $Script:KubectlCmd get pvc -n "$stuckNs" --no-headers 2>&1
            if ($LASTEXITCODE -eq 0 -and -not [String]::IsNullOrWhiteSpace($pvcOutput) -and $pvcOutput -notmatch "No resources found") {
                Write-LogMessage -Type WARNING -Message "Stuck PVCs in `"$stuckNs`" (Retain reclaim policy may block namespace termination):"
                $pvcOutput -split "`n" | Where-Object { -not [String]::IsNullOrWhiteSpace($_) } | ForEach-Object { Write-LogMessage -Type WARNING -Message "  $_" }
                Write-LogMessage -Type WARNING -Message "Delete PVCs manually if present: kubectl delete pvc --all -n $stuckNs"
            }
        } catch {
            Write-LogMessage -Type DEBUG -Message "Could not query PVCs for `"$stuckNs`": $($_.Exception.Message)"
        }
        try {
            $podOutput = & $Script:KubectlCmd get pods -n "$stuckNs" --no-headers 2>&1
            if ($LASTEXITCODE -eq 0 -and -not [String]::IsNullOrWhiteSpace($podOutput) -and $podOutput -notmatch "No resources found") {
                Write-LogMessage -Type WARNING -Message "Stuck pods in `"$stuckNs`" (pods in Terminating state can delay namespace GC):"
                $podOutput -split "`n" | Where-Object { -not [String]::IsNullOrWhiteSpace($_) } | ForEach-Object { Write-LogMessage -Type WARNING -Message "  $_" }
                Write-LogMessage -Type WARNING -Message "Force-delete stuck pods: kubectl delete pod --all -n $stuckNs --force --grace-period=0"
            }
        } catch {
            Write-LogMessage -Type DEBUG -Message "Could not query pods for `"$stuckNs`": $($_.Exception.Message)"
        }
    }

    $stuckList = $StillPresent -join ", "
    Write-LogMessage -Type WARNING -Message "Manual resolution — run the following for each stuck namespace (`"$stuckList`"):"
    Write-LogMessage -Type WARNING -Message "  1. Inspect:           kubectl get namespace <ns> -o yaml"
    Write-LogMessage -Type WARNING -Message "  2. Delete PVCs:       kubectl delete pvc --all -n <ns>"
    Write-LogMessage -Type WARNING -Message "  3. Force-delete pods: kubectl delete pod --all -n <ns> --force --grace-period=0"
    Write-LogMessage -Type WARNING -Message "  4. Remove finalizers (last resort; may leave orphaned NSX-T/LB resources):"
    Write-LogMessage -Type WARNING -Message "     kubectl patch namespace <ns> -p '{`"metadata`":{`"finalizers`":null}}' --type=merge"
    Write-LogMessage -Type WARNING -Message "Once all stuck namespaces are gone, re-run: Start-VcfEdgeAtScale -CleanUp Harbor -EdgeSite <site>"
}
function Wait-HarborServiceNamespaceTermination {

    <#
        .SYNOPSIS
        Polls for any svc-harbor* namespace left on the supervisor after Harbor service deletion.

        .DESCRIPTION
        After the Harbor Supervisor Service is deleted, vCenter may leave a Kubernetes namespace
        (e.g. svc-harbor-albvy) in Terminating state on the Supervisor. Attempting to reinstall Harbor
        before that namespace is fully gone causes vCenter to reject the request with "namespace is in
        terminating status". This function uses kubectl to poll for any namespace whose name starts with
        svc-harbor and waits until none are found or the timeout is reached.

        PVC cleanup: all PVCs created by Harbor live inside the svc-harbor-* namespace. When the namespace
        terminates, Kubernetes garbage-collects all resources in it including PVCs; for vSphere StorageClasses
        with reclaimPolicy: Delete (the default), the underlying virtual disks are also deleted. Waiting for
        the namespace to disappear therefore implicitly confirms that PVCs and their backing storage are gone.

        If the namespace does not terminate within TimeoutSeconds, automated diagnostics run against each
        stuck namespace: metadata and spec finalizers, PVCs, and pods are queried via kubectl and logged
        as warnings. Specific kubectl commands to force termination are included in the output. When kubectl
        is unavailable (e.g. context not configured), MinWaitSeconds is used as a timed fallback instead.

        .PARAMETER ClusterName
        Cluster name used in log messages.

        .PARAMETER MinWaitSeconds
        Seconds to wait when kubectl is unavailable and namespace status cannot be determined. Used as a timed
        fallback (e.g. during -CleanUp Harbor when kubectl context is not set). Default is 60. Set to 0 to
        disable the fallback wait; has no effect when kubectl is available.

        .PARAMETER PollIntervalSeconds
        Seconds between each namespace-list check. Default is 15.

        .PARAMETER SupervisorId
        Supervisor UUID used in log messages.

        .PARAMETER TimeoutSeconds
        Maximum seconds to wait for all svc-harbor* namespaces to disappear. Default is 600. On timeout,
        automated diagnostics run against each stuck namespace: finalizers, PVCs, and pods are queried and
        logged as warnings with the manual kubectl commands needed to force termination.

        .EXAMPLE
        Wait-HarborServiceNamespaceTermination -SupervisorId $supervisorId -ClusterName "cluster-OSA"

        .OUTPUTS
        None. Does not throw; logs warnings with actionable diagnostics on timeout.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [ValidateRange(0, 300)] [Int]$MinWaitSeconds = 60,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 60)] [Int]$PollIntervalSeconds = 15,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorId,
        [Parameter(Mandatory = $false)] [ValidateRange(10, 600)] [Int]$TimeoutSeconds = 600
    )

    $progressActivity = "Waiting for Harbor service namespace to terminate"

    # Use kubectl to detect svc-harbor* namespaces. The Supervisor Services controller creates these
    # as Kubernetes system namespaces; Invoke-ListNamespacesInstances only surfaces user namespace
    # instances and cannot see them, making it an unreliable signal for namespace termination.
    $initialDiscovery = Get-KubectlNamespaceNamesMatchingPattern -DebugLogPrefix "Wait-HarborServiceNamespaceTermination" -NameLike "svc-harbor*"
    $kubectlAvailable = $initialDiscovery.KubectlSucceeded
    $initialNamespaces = @($initialDiscovery.Names)
    if (-not $kubectlAvailable) {
        Write-LogMessage -Type DEBUG -Message "Wait-HarborServiceNamespaceTermination: kubectl not available or failed; will use timed wait."
    }

    if (-not $kubectlAvailable) {
        if ($MinWaitSeconds -gt 0) {
            Write-LogMessage -Type INFO -Message "Harbor namespace wait: kubectl unavailable on supervisor `"$SupervisorId`"; waiting ${MinWaitSeconds}s for vCenter to finish deleting namespace and PVCs..."
            Start-Sleep -Seconds $MinWaitSeconds
            Write-LogMessage -Type INFO -Message "Harbor namespace wait complete on supervisor `"$SupervisorId`" for cluster `"$ClusterName`"."
        }
        return
    }

    if ($initialNamespaces.Count -eq 0) {
        Write-LogMessage -Type DEBUG -Message "Wait-HarborServiceNamespaceTermination: No svc-harbor* namespace found via kubectl on supervisor `"$SupervisorId`"; already terminated or not yet created."
        return
    }

    $namespaceNames = $initialNamespaces -join ", "
    Write-LogMessage -Type INFO -Message "Harbor service namespace(s) still present on supervisor `"$SupervisorId`" for cluster `"$ClusterName`": $namespaceNames. Waiting for termination before completing rollback..."

    $elapsedSeconds = 0
    while ($elapsedSeconds -lt $TimeoutSeconds) {
        $percentComplete = [Math]::Min(100, [int](($elapsedSeconds / $TimeoutSeconds) * 100))
        Write-Progress -Activity $progressActivity -Status "Polling (${elapsedSeconds}s / ${TimeoutSeconds}s)..." -PercentComplete $percentComplete
        [Console]::Out.Flush()
        Start-Sleep -Seconds $PollIntervalSeconds
        $elapsedSeconds += $PollIntervalSeconds

        $pollDiscovery = Get-KubectlNamespaceNamesMatchingPattern -DebugLogPrefix "Wait-HarborServiceNamespaceTermination" -NameLike "svc-harbor*"
        if (-not $pollDiscovery.KubectlSucceeded) {
            Write-LogMessage -Type DEBUG -Message "Wait-HarborServiceNamespaceTermination: kubectl error during poll; assuming namespace is gone."
            Write-Progress -Activity $progressActivity -Status "Complete" -PercentComplete 100 -Completed
            [Console]::Out.Flush()
            return
        }
        $stillPresent = @($pollDiscovery.Names)

        if ($stillPresent.Count -eq 0) {
            Write-Progress -Activity $progressActivity -Status "Complete" -PercentComplete 100 -Completed
            [Console]::Out.Flush()
            Write-LogMessage -Type INFO -Message "Harbor service namespace(s) terminated on supervisor `"$SupervisorId`" for cluster `"$ClusterName`". Ready for re-deployment."
            return
        }
        Write-LogMessage -Type DEBUG -Message "Wait-HarborServiceNamespaceTermination: namespace(s) still present: $($stillPresent -join ', ') (elapsed ${elapsedSeconds}s, timeout ${TimeoutSeconds}s)."
    }

    Write-Progress -Activity $progressActivity -Status "Timeout" -Completed
    [Console]::Out.Flush()
    Write-LogMessage -Type WARNING -Message "Harbor service namespace(s) on supervisor `"$SupervisorId`" still present after ${TimeoutSeconds}s. Diagnosing what is blocking termination..."
    Write-HarborNamespaceTerminationDiagnostic -ClusterName $ClusterName -StillPresent $stillPresent -SupervisorId $SupervisorId -TimeoutSeconds $TimeoutSeconds
}
function Remove-HarborContainerImageRegistry {

    <#
        .SYNOPSIS
        Removes the Harbor container image registry registration from a Supervisor. Best-effort; logs warnings on failure.

        .DESCRIPTION
        Lists all container image registries registered on the given Supervisor and removes any whose name matches
        RegistryName (default: "harbor"). This is called during Harbor cleanup and rollback to unregister Harbor from
        the Supervisor's container image registry list before the Harbor service itself is removed.

        Non-fatal: logs a warning if the removal fails but does not throw, so the caller can continue with other
        cleanup steps. If the named registry is not found, logs an informational message and returns.

        .PARAMETER ClusterName
        The cluster name for log messages.

        .PARAMETER RegistryName
        The name of the container image registry entry to remove. Default is "harbor".

        .PARAMETER SupervisorId
        The supervisor UUID where the container image registry is registered.

        .EXAMPLE
        Remove-HarborContainerImageRegistry -SupervisorId $supervisorId -ClusterName "cluster-OSA"

        .OUTPUTS
        None. Logs result; does not throw.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$RegistryName = "harbor",
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorId
    )

    Write-LogMessage -Type DEBUG -Message "Entered Remove-HarborContainerImageRegistry: supervisor=`"$SupervisorId`", cluster=`"$ClusterName`", registryName=`"$RegistryName`"."

    $existingRegistries = $null
    try {
        $existingRegistries = Invoke-ListSupervisorNamespaceManagementContainerImageRegistries -Supervisor $SupervisorId -ErrorAction Stop
    } catch {
        Write-LogMessage -Type WARNING -Message "Remove-HarborContainerImageRegistry: Could not list container image registries on supervisor `"$SupervisorId`": $($_.Exception.Message). Skipping container image registry cleanup."
        return
    }

    if ($null -eq $existingRegistries -or @($existingRegistries).Count -eq 0) {
        Write-LogMessage -Type INFO -Message "No container image registries found on supervisor `"$SupervisorId`" for cluster `"$ClusterName`". Nothing to remove."
        return
    }

    $registryEntry = @($existingRegistries) | Where-Object { $_.name -eq $RegistryName } | Select-Object -First 1
    if ($null -eq $registryEntry) {
        Write-LogMessage -Type INFO -Message "Container image registry `"$RegistryName`" not found on supervisor `"$SupervisorId`" for cluster `"$ClusterName`". Nothing to remove."
        return
    }

    $registryId = $registryEntry.id
    try {
        Invoke-DeleteSupervisorContainerImageRegistryNamespaceManagementContainerImageRegistries -Supervisor $SupervisorId -ContainerImageRegistry $registryId -Confirm:$false -ErrorAction Stop | Out-Null
        Write-LogMessage -Type INFO -Message "Harbor container image registry `"$RegistryName`" (id: `"$registryId`") removed from supervisor `"$SupervisorId`" for cluster `"$ClusterName`"."
    } catch {
        Write-LogMessage -Type WARNING -Message "Could not remove Harbor container image registry `"$RegistryName`" from supervisor `"$SupervisorId`": $($_.Exception.Message). Remove manually in vCenter (Supervisor → Configure → Container Registries)."
    }
}
function Remove-HarborSupervisorService {

    <#
        .SYNOPSIS
        Removes the Harbor Supervisor Service from a specific supervisor. Best-effort; logs warnings on failure.

        .DESCRIPTION
        Calls Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesDelete to remove Harbor from the
        specified supervisor, then polls until the service is no longer listed. After the service is confirmed
        gone, calls Wait-HarborServiceNamespaceTermination to poll for the auto-created svc-harbor* Kubernetes
        namespace to finish terminating. This ensures the next install attempt is not blocked by a lingering
        terminating namespace or stale PVC data. If the service is not found, skips the delete but still runs
        the namespace poll. Designed for use in rollback and cleanup workflows; does not throw on failure.

        PVC cleanup: all PVCs reside inside the svc-harbor-* namespace and are deleted when it terminates.
        Wait-HarborServiceNamespaceTermination waits for this; if the API cannot see the namespace, it sleeps
        for NamespaceMinWaitSeconds (default 60) to ensure vCenter finishes deleting PVCs before returning.

        .PARAMETER ClusterName
        The cluster name for log messages.

        .PARAMETER DeletePollIntervalSeconds
        Seconds between each poll checking that Harbor is gone. Default is 10.

        .PARAMETER DeleteTimeoutSeconds
        Maximum seconds to wait for the service to disappear after deletion. Default is 180.

        .PARAMETER NamespaceMinWaitSeconds
        Minimum seconds to wait even when no svc-harbor* namespace is visible through Invoke-ListNamespacesInstances,
        ensuring vCenter has time to delete PVCs and reclaim storage before the caller proceeds. Passed directly to
        Wait-HarborServiceNamespaceTermination. Default is 60. Set to 0 to disable (not recommended). See
        Wait-HarborServiceNamespaceTermination for details.

        .PARAMETER NamespacePollIntervalSeconds
        Seconds between each poll checking that the svc-harbor* namespace is gone. Default is 15.

        .PARAMETER NamespaceTimeoutSeconds
        Maximum seconds to wait for the svc-harbor* namespace to terminate after service deletion. Default is 600.
        Namespaces can remain in Terminating state for several minutes on busy environments or when NSX-T load balancer
        resources are being reclaimed; 600 seconds covers most cases. Increase if your environment is consistently slow.

        .PARAMETER Service
        The Harbor supervisor service identifier (e.g. "harbor-service.vsphere.vmware.com") extracted from
        the harbor-service YAML via Get-ArgoCDServiceDetail.

        .PARAMETER SupervisorId
        The supervisor UUID where Harbor is installed.

        .EXAMPLE
        Remove-HarborSupervisorService -SupervisorId $supervisorId -Service "harbor-service.vsphere.vmware.com" -ClusterName "cl0-site1"

        .OUTPUTS
        None. Logs success or warning; does not throw.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 60)] [Int]$DeletePollIntervalSeconds = 10,
        [Parameter(Mandatory = $false)] [ValidateRange(10, 600)] [Int]$DeleteTimeoutSeconds = 180,
        [Parameter(Mandatory = $false)] [ValidateRange(0, 300)] [Int]$NamespaceMinWaitSeconds = 60,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 60)] [Int]$NamespacePollIntervalSeconds = 15,
        [Parameter(Mandatory = $false)] [ValidateRange(10, 600)] [Int]$NamespaceTimeoutSeconds = 600,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Service,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorId
    )

    Write-LogMessage -Type DEBUG -Message "Entered Remove-HarborSupervisorService: supervisor=`"$SupervisorId`", service=`"$Service`", cluster=`"$ClusterName`"."

    # Unregister Harbor from the Supervisor's container image registry list before removing the service.
    Remove-HarborContainerImageRegistry -ClusterName $ClusterName -SupervisorId $SupervisorId

    $serviceExists = $true
    try {
        Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesGet -Supervisor $SupervisorId -SupervisorService $Service -ErrorAction Stop | Out-Null
    } catch {
        if ($_.Exception.Message -match "not found|does not exist|404") {
            $serviceExists = $false
        }
    }
    if (-not $serviceExists) {
        Write-LogMessage -Type INFO -Message "Harbor service `"$Service`" not found on supervisor `"$SupervisorId`"; nothing to remove for cluster `"$ClusterName`"."
        # Service may have been deleted by a previous rollback but its namespace is still terminating.
        Wait-HarborServiceNamespaceTermination -ClusterName $ClusterName -MinWaitSeconds $NamespaceMinWaitSeconds -PollIntervalSeconds $NamespacePollIntervalSeconds -SupervisorId $SupervisorId -TimeoutSeconds $NamespaceTimeoutSeconds
        return
    }
    $progressActivity = "Waiting for Harbor service `"$Service`" to be removed"
    try {
        Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesDelete -Supervisor $SupervisorId -SupervisorService $Service -Confirm:$false -ErrorAction Stop | Out-Null
        $elapsedSeconds = 0
        while ($elapsedSeconds -lt $DeleteTimeoutSeconds) {
            $percentComplete = [Math]::Min(100, [int](($elapsedSeconds / $DeleteTimeoutSeconds) * 100))
            Write-Progress -Activity $progressActivity -Status "Polling (${elapsedSeconds}s / ${DeleteTimeoutSeconds}s)..." -PercentComplete $percentComplete
            [Console]::Out.Flush()
            Start-Sleep -Seconds $DeletePollIntervalSeconds
            $elapsedSeconds += $DeletePollIntervalSeconds
            $stillExists = $true
            try {
                Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesGet -Supervisor $SupervisorId -SupervisorService $Service -ErrorAction Stop | Out-Null
            } catch {
                if ($_.Exception.Message -match "not found|does not exist|404") {
                    $stillExists = $false
                }
            }
            if (-not $stillExists) {
                Write-Progress -Activity $progressActivity -Status "Complete" -PercentComplete 100 -Completed
                [Console]::Out.Flush()
                Write-LogMessage -Type INFO -Message "Harbor service `"$Service`" removed from supervisor `"$SupervisorId`" for cluster `"$ClusterName`". Supervisor intact."
                Wait-HarborServiceNamespaceTermination -ClusterName $ClusterName -MinWaitSeconds $NamespaceMinWaitSeconds -PollIntervalSeconds $NamespacePollIntervalSeconds -SupervisorId $SupervisorId -TimeoutSeconds $NamespaceTimeoutSeconds
                return
            }
            Write-LogMessage -Type DEBUG -Message "Harbor service `"$Service`" still present; waiting (elapsed ${elapsedSeconds}s, timeout ${DeleteTimeoutSeconds}s)."
        }
        Write-Progress -Activity $progressActivity -Status "Timeout" -Completed
        [Console]::Out.Flush()
        Write-LogMessage -Type WARNING -Message "Harbor service `"$Service`" still exists on supervisor `"$SupervisorId`" after ${DeleteTimeoutSeconds}s. Delete was initiated; verify in vCenter. Supervisor intact."
        try {
            Write-SupervisorKubernetesDiagnosticReport -ClusterName $ClusterName -Context "Harbor supervisor service removal did not complete within the wait window" -SupervisorId $SupervisorId
        } catch {
            Write-LogMessage -Type DEBUG -Message "Supervisor Kubernetes diagnostics (Harbor remove timeout): $($_.Exception.Message)"
        }
    } catch {
        Write-Progress -Activity $progressActivity -Status "Error" -Completed
        [Console]::Out.Flush()
        Write-LogMessage -Type WARNING -Message "Could not remove Harbor service `"$Service`" from supervisor `"$SupervisorId`" for cluster `"$ClusterName`": $($_.Exception.Message). Remove manually (e.g. -CleanUp Harbor) or verify in vCenter. Supervisor is still enabled."
        try {
            Write-SupervisorKubernetesDiagnosticReport -ClusterName $ClusterName -Context "Harbor supervisor service removal failed with an exception" -SupervisorId $SupervisorId
        } catch {
            Write-LogMessage -Type DEBUG -Message "Supervisor Kubernetes diagnostics (Harbor remove error): $($_.Exception.Message)"
        }
    }
}
function Invoke-HarborOnlyRollback {

    <#
        .SYNOPSIS
        Rolls back only the Harbor deployment by removing the Harbor Supervisor Service; supervisor and ArgoCD remain intact.

        .DESCRIPTION
        Use when Harbor deployment fails after the supervisor (and optionally ArgoCD) was deployed. Removes the Harbor
        Supervisor Service from the specified supervisor and leaves the supervisor and any deployed ArgoCD namespace intact
        so the operator can fix the issue and re-run deployment idempotently.
        Respects -RollbackOnFailure: prompts or skips per preference.

        .PARAMETER ClusterName
        The cluster name for log messages.

        .PARAMETER DeletePollIntervalSeconds
        Seconds between polls checking that Harbor is gone. Default is 10.

        .PARAMETER DeleteTimeoutSeconds
        Maximum seconds to wait for Harbor to be removed. Default is 180.

        .PARAMETER Service
        The Harbor supervisor service identifier.

        .PARAMETER SingleSite
        When set, the rollback prompt is Y/N only (no A=always), since there is no next site to continue to.

        .PARAMETER SupervisorId
        The supervisor UUID where Harbor is installed.

        .EXAMPLE
        Invoke-HarborOnlyRollback -ClusterName "cl0-site1" -SupervisorId $supervisorId -Service "harbor-service.vsphere.vmware.com"

        .OUTPUTS
        None. Throws if user chooses DoNotRollback (so caller can continue to next site).

        .NOTES
        Sets $Script:RollbackAttempted = $true to signal that a rollback was performed;
        the deployment orchestrator checks this flag to determine the final run status.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 60)] [Int]$DeletePollIntervalSeconds = 10,
        [Parameter(Mandatory = $false)] [ValidateRange(10, 600)] [Int]$DeleteTimeoutSeconds = 180,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Service,
        [Parameter(Mandatory = $false)] [Switch]$SingleSite,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorId
    )

    $rollbackDecision = Invoke-PauseBeforeRollbackIfRequested -ForcePrompt -RollbackContext "Harbor-only rollback (cluster `"$ClusterName`")" -SingleSite:$SingleSite.IsPresent
    if ($rollbackDecision -eq "DoNotRollback") {
        throw [RollbackSkippedException]::new()
    }
    $Script:RollbackAttempted = $true
    Write-LogMessage -Type INFO -Message "Starting Harbor-only rollback for cluster `"$ClusterName`" (removing service `"$Service`" from supervisor; supervisor and Argo CD left intact)."
    Remove-HarborSupervisorService -ClusterName $ClusterName -DeletePollIntervalSeconds $DeletePollIntervalSeconds -DeleteTimeoutSeconds $DeleteTimeoutSeconds -Service $Service -SupervisorId $SupervisorId
}
function Test-SupervisorDeployedOnCluster {

    <#
        .SYNOPSIS
        Returns $true if a vSphere Supervisor is currently active on the named cluster.

        .DESCRIPTION
        Queries Invoke-ListNamespaceManagementClusters for the given cluster name and checks
        whether the ConfigStatus and KubernetesStatus indicate an active supervisor (i.e. not
        both DISABLED/NOT_INSTALLED). Returns $false when the cluster is not found, the WCP
        list is empty, or when the query throws. Intended for use before rollback VDS/cluster
        removal to prevent tearing down infrastructure that the supervisor is still using.

        .PARAMETER ClusterName
        The vCenter cluster name to check.

        .OUTPUTS
        System.Boolean. $true if supervisor is active; $false otherwise.

        .EXAMPLE
        if (Test-SupervisorDeployedOnCluster -ClusterName "cluster-OSA") { Write-Output "Supervisor active." }
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName
    )

    try {
        $clusterObj = Get-Cluster -Name $ClusterName -Server $Script:vCenterName -ErrorAction SilentlyContinue
        if (-not $clusterObj) {
            return $false
        }
        $wcpList = @(Invoke-ListNamespaceManagementClusters -ErrorAction SilentlyContinue | Where-Object {
            $_.clusterName -and (
                $_.clusterName.Id -eq $clusterObj.Id -or
                $_.clusterName -eq $clusterObj -or
                $_.clusterName -eq $ClusterName
            )
        })
        $wcpEntry = $wcpList | Select-Object -First 1
        if (-not $wcpEntry) {
            return $false
        }
        $configStatus = $wcpEntry.ConfigStatus
        $kubeStatus = $wcpEntry.KubernetesStatus
        $configDisabled = [String]::IsNullOrEmpty($configStatus) -or ($configStatus -eq "DISABLED")
        $kubeNotInstalled = [String]::IsNullOrEmpty($kubeStatus) -or ($kubeStatus -eq "NOT_INSTALLED")
        return -not ($configDisabled -and $kubeNotInstalled)
    } catch {
        Write-LogMessage -Type DEBUG -Message "Test-SupervisorDeployedOnCluster: query failed for `"$ClusterName`": $($_.Exception.Message)"
        return $false
    }
}
function Disable-SupervisorOnCluster {

    <#
        .SYNOPSIS
        Deactivates (disables) the vSphere Supervisor on a cluster.

        .DESCRIPTION
        The Disable-SupervisorOnCluster function disables namespace management (vSphere with Tanzu / WCP)
        on the specified vSphere cluster and polls until the supervisor is fully deactivated. Use this when
        a supervisor failed to deploy within the allotted time so the cluster is left in a clean state and
        can be retried. The operation uses VCF PowerCLI 9 Invoke-DisableCluster, then polls
        Invoke-ListNamespaceManagementClusters until ConfigStatus is DISABLED (or empty) and
        KubernetesStatus is NOT_INSTALLED (or empty), or the timeout is reached.

        .PARAMETER CheckInterval
        Interval in seconds between status checks while waiting for full deactivation. Default is 10.

        .PARAMETER ClusterId
        The vCenter cluster MoRef identifier (e.g., "domain-c22") where the supervisor is enabled.

        .PARAMETER ClusterName
        The name of the cluster. Used for status polling and logging.

        .PARAMETER SuppressConfirm
        When specified, suppresses the confirmation prompt (passes -Confirm:$false to Invoke-DisableCluster). Omit for interactive use.

        .PARAMETER SupervisorId
        When set, Kubernetes status diagnostics are logged if deactivation does not finish within the timeout.

        .PARAMETER TimeoutSeconds
        Maximum seconds to wait for full deactivation after initiating disable. Default is 3600 (1 hour).

        .OUTPUTS
        PSCustomObject with Success (Boolean) and ErrorMessage (String, when Success is $false).

        .EXAMPLE
        $result = Disable-SupervisorOnCluster -ClusterId "domain-c22" -ClusterName "edge-cluster-01" -SuppressConfirm
        if ($result.Success) { Write-LogMessage -Type INFO -Message "Supervisor disabled." }

        .NOTES
        Requires an active vCenter connection. Uses Invoke-DisableCluster and Invoke-ListNamespaceManagementClusters (VCF PowerCLI 9).
        Disabling removes workloads and namespaces on that supervisor; use only when deployment has failed.
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(1, [Int]::MaxValue)] [Int]$CheckInterval = 10,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterId,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [String]$SupervisorId,
        [Parameter(Mandatory = $false)] [Switch]$SuppressConfirm,
        [Parameter(Mandatory = $false)] [ValidateRange(1, [Int]::MaxValue)] [Int]$TimeoutSeconds = 3600
    )

    Write-LogMessage -Type DEBUG -Message "Entered Disable-SupervisorOnCluster function..."

    try {
        $connectionTest = Test-VcenterConnection
        if (-not $connectionTest.IsConnected) {
            Write-LogMessage -Type ERROR -Message "Not connected to vCenter `"$Script:vCenterName`": $($connectionTest.ErrorMessage)"
            return [PSCustomObject]@{
                Success = $false
                ErrorMessage = "Not connected to vCenter: $($connectionTest.ErrorMessage)"
            }
        }

        $confirmFlag = -not $SuppressConfirm.IsPresent
        Write-LogMessage -Type INFO -NoNewline -Message "Deactivating supervisor on cluster `"$ClusterName`" (ID: $ClusterId)... "
        try {
            Invoke-DisableCluster -Cluster $ClusterId -Confirm:$confirmFlag -ErrorAction Stop
        } catch {
            $disableErr = $_.Exception.Message
            if ($disableErr -match "does not have Workloads enabled|notfound|vcenter\.wcp\.cluster\.notfound") {
                Write-LogMessage -Type INFO -CompletePending -Message "already disabled (no Workloads enabled). Skipping."
                return [PSCustomObject]@{ Success = $true; ErrorMessage = $null }
            }
            throw
        }

        return Wait-ForSupervisorDeactivation `
            -CheckInterval  $CheckInterval `
            -ClusterId      $ClusterId `
            -ClusterName    $ClusterName `
            -SupervisorId   $SupervisorId `
            -TimeoutSeconds $TimeoutSeconds
    } catch {
        $errorMessage = $_.Exception.Message
        Write-LogMessage -Type ERROR -CompletePending -Message "failed to deactivate supervisor on cluster `"$ClusterName`": $errorMessage"
        return [PSCustomObject]@{
            Success = $false
            ErrorMessage = $errorMessage
        }
    }
}
function Wait-ForSupervisorDeactivation {

    <#
        .SYNOPSIS
        Polls vCenter until the supervisor on a cluster reaches the DISABLED/NOT_INSTALLED state.

        .DESCRIPTION
        Polls Invoke-ListNamespaceManagementClusters at CheckInterval intervals until both
        ConfigStatus is DISABLED (or absent) and KubernetesStatus is NOT_INSTALLED (or absent),
        or TimeoutSeconds is reached. Returns a PSCustomObject with Success and ErrorMessage.

        .PARAMETER CheckInterval
        Seconds between each poll. Default is 10.

        .PARAMETER ClusterId
        Cluster MoRef identifier used for matching against Invoke-ListNamespaceManagementClusters results.

        .PARAMETER ClusterName
        Cluster display name used for matching and log messages.

        .PARAMETER SupervisorId
        When set, enables Kubernetes diagnostic reporting on timeout.

        .PARAMETER TimeoutSeconds
        Maximum seconds to wait before returning a timeout failure. Default is 3600.

        .EXAMPLE
        $result = Wait-ForSupervisorDeactivation -ClusterId "domain-c22" -ClusterName "edge-cluster-01" -TimeoutSeconds 3600

        .NOTES
        Called by Disable-SupervisorOnCluster after Invoke-DisableCluster succeeds.
        Returns PSCustomObject with Success=$true on success, or Success=$false with ErrorMessage on timeout.
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(1, [Int]::MaxValue)] [Int]$CheckInterval = 10,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterId,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [String]$SupervisorId,
        [Parameter(Mandatory = $false)] [ValidateRange(1, [Int]::MaxValue)] [Int]$TimeoutSeconds = 3600
    )

    $elapsedTime = 0
    do {
        $wcpList = @(Invoke-ListNamespaceManagementClusters -ErrorAction SilentlyContinue | Where-Object {
            if (-not $_) { return $false }
            $nameMatch = ($_.clusterName -is [String]) -and ($_.clusterName -eq $ClusterName)
            $idMatch   = ($null -ne $ClusterId) -and
                         ($_.clusterName -isnot [String]) -and
                         ($null -ne $_.clusterName.Id) -and
                         ($_.clusterName.Id -eq $ClusterId)
            $nameMatch -or $idMatch
        })
        $wcpEntry       = $wcpList | Select-Object -First 1
        $configStatus   = if ($wcpEntry) { $wcpEntry.ConfigStatus } else { $null }
        $kubeStatus     = if ($wcpEntry) { $wcpEntry.KubernetesStatus } else { $null }
        $configDisabled = [String]::IsNullOrEmpty($configStatus) -or ($configStatus -eq "DISABLED")
        $kubeNotInstalled = [String]::IsNullOrEmpty($kubeStatus) -or ($kubeStatus -eq "NOT_INSTALLED")
        if ($configDisabled -and $kubeNotInstalled) {
            Write-Progress -Activity "Waiting for supervisor deactivation" -Status "Complete" -PercentComplete 100 -Completed
            [Console]::Out.Flush()
            Write-LogMessage -Type INFO -CompletePending -Message "fully deactivated after $elapsedTime seconds. You can retry deployment."
            return [PSCustomObject]@{ Success = $true; ErrorMessage = $null }
        }
        $percentComplete = if ($TimeoutSeconds -gt 0) { [Math]::Min(99, [int](($elapsedTime / $TimeoutSeconds) * 100)) } else { 0 }
        Write-Progress -Activity "Waiting for supervisor deactivation on `"$ClusterName`"" -Status "Elapsed: $elapsedTime s - ConfigStatus: $configStatus, KubernetesStatus: $kubeStatus" -PercentComplete $percentComplete
        [Console]::Out.Flush()
        Start-Sleep -Seconds $CheckInterval
        $elapsedTime += $CheckInterval
    } while ($elapsedTime -lt $TimeoutSeconds)

    Write-Progress -Activity "Waiting for supervisor deactivation" -Status "Timeout" -Completed
    [Console]::Out.Flush()
    Write-LogMessage -Type WARNING -CompletePending -Message "teardown did not complete within $TimeoutSeconds seconds (ConfigStatus: $configStatus, KubernetesStatus: $kubeStatus). You may retry deployment once teardown finishes."
    if (-not [String]::IsNullOrWhiteSpace($SupervisorId)) {
        try {
            Write-SupervisorKubernetesDiagnosticReport -ClusterName $ClusterName -Context "supervisor deactivation did not complete within the wait window" -SupervisorId $SupervisorId
        } catch {
            Write-LogMessage -Type DEBUG -Message "Supervisor Kubernetes diagnostics after deactivation timeout: $($_.Exception.Message)"
        }
    }
    return [PSCustomObject]@{
        Success = $false
        ErrorMessage = "Teardown did not complete within $TimeoutSeconds seconds. Check vCenter; retry deployment after cluster is fully disabled."
    }
}
function Invoke-SupervisorKubernetesDiagnosticSafe {

    <#
        .SYNOPSIS
        Calls Write-SupervisorKubernetesDiagnosticReport and suppresses non-critical failures.

        .DESCRIPTION
        Wraps Write-SupervisorKubernetesDiagnosticReport in a try/catch. Diagnostic failures are
        logged at DEBUG and do not propagate — supervisor readiness polling must never be blocked
        by a secondary diagnostic collection failure.

        .PARAMETER ClusterName
        Cluster display name for diagnostic output.

        .PARAMETER Context
        Short description of the triggering event, passed to Write-SupervisorKubernetesDiagnosticReport.

        .PARAMETER SupervisorId
        UUID of the supervisor being monitored.

        .EXAMPLE
        Invoke-SupervisorKubernetesDiagnosticSafe -ClusterName "cluster-edge1" -Context "supervisor timeout" -SupervisorId $supervisorId
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Context,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorId
    )

    try {
        Write-SupervisorKubernetesDiagnosticReport -ClusterName $ClusterName -Context $Context -SupervisorId $SupervisorId
    } catch {
        Write-LogMessage -Type DEBUG -Message "Supervisor Kubernetes diagnostics ($Context): $($_.Exception.Message)"
    }
}
function Write-Supervisor503PersistenceWarning {

    <#
        .SYNOPSIS
        Logs persistent-503 crash-risk warnings and performs a best-effort cluster status check.

        .DESCRIPTION
        Called once when 503 errors have persisted beyond the crash-detection threshold. Logs a
        structured warning with recommended operator actions and attempts to verify cluster
        reachability via Get-Cluster as an alternative diagnostic.

        .PARAMETER ClusterName
        Cluster display name used in log messages and the vCenter lookup.

        .PARAMETER Consecutive503Errors
        Count of consecutive 503 errors observed so far, used in the warning message.

        .PARAMETER TimeSinceFirst503Seconds
        Elapsed seconds since the first 503 error, used in the warning message.

        .EXAMPLE
        Write-Supervisor503PersistenceWarning -ClusterName "cluster-edge1" -Consecutive503Errors 12 -TimeSinceFirst503Seconds 320
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)]  [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [ValidateRange(0, [Int]::MaxValue)] [Int]$Consecutive503Errors = 0,
        [Parameter(Mandatory = $false)] [ValidateRange(0, [Double]::MaxValue)] [Double]$TimeSinceFirst503Seconds = 0
    )

    Write-LogMessage -Type WARNING -Message "Persistent 503 errors detected for $([Int]$TimeSinceFirst503Seconds) seconds ($Consecutive503Errors consecutive failures). This may indicate the supervisor service has crashed rather than still initializing."
    Write-LogMessage -Type WARNING -Message "Attempting to verify supervisor cluster status via alternative method..."

    $vcenterReachable = $false
    try {
        $clusterObject = Get-Cluster -Name $ClusterName -Server $Script:vCenterName -ErrorAction SilentlyContinue
        if ($clusterObject) {
            $vcenterReachable = $true
            $supervisorExtension = $clusterObject.ExtensionData | Select-Object -ExpandProperty Summary -ErrorAction SilentlyContinue
            if ($supervisorExtension) {
                Write-LogMessage -Type INFO -Message "Supervisor cluster `"$ClusterName`" exists in vCenter. Check vCenter UI for detailed status and any error messages."
            }
        }
    } catch {
        Write-LogMessage -Type DEBUG -Message "Could not retrieve cluster status via alternative method: $($_.Exception.Message)"
    }

    if (-not $vcenterReachable) {
        Write-LogMessage -Type WARNING -Message "vCenter appears to be unreachable. This may indicate a connectivity issue or vCenter service problem."
    }

    Write-LogMessage -Type INFO -Message ""
    Write-LogMessage -Type WARNING -Message "RECOMMENDED ACTIONS:"
    Write-LogMessage -Type WARNING -Message "  1. Check vCenter UI: Menu > Workload Management > Supervisor Clusters"
    Write-LogMessage -Type WARNING -Message "  2. Look for error messages or failed state indicators"
    Write-LogMessage -Type WARNING -Message "  3. Check supervisor control plane VM status and logs"
    Write-LogMessage -Type WARNING -Message "  4. Review vCenter events for the supervisor cluster"
    Write-LogMessage -Type WARNING -Message "  5. If supervisor has crashed, you may need to delete and recreate it"
    Write-LogMessage -Type INFO -Message ""
}
function Invoke-Supervisor503ErrorHandler {

    <#
        .SYNOPSIS
        Handles transient 503/service-unavailable errors during supervisor readiness polling.

        .DESCRIPTION
        Called from the inner catch block of the Wait-SupervisorReady poll loop when the supervisor
        status API returns a 503 or similar transient error. Tracks consecutive-error state via a
        shared hashtable, shows a crash-risk warning once the crash-detection threshold is exceeded,
        and either returns an early-exit result (on max threshold) or a sleep-continue signal.
        Returns a rethrow signal for non-transient errors so the caller can propagate them.

        .PARAMETER CheckInterval
        Seconds to sleep before the next poll attempt.

        .PARAMETER ClusterName
        Cluster display name for log messages and diagnostics.

        .PARAMETER CrashDetectionThreshold
        Seconds of continuous 503s before the crash-risk warning is shown. Default: 300.

        .PARAMETER ElapsedTime
        Elapsed seconds so far in the parent poll loop; used for timeout decisions.

        .PARAMETER ErrorMsg
        The exception message from the failed API call.

        .PARAMETER MaxPersistent503Threshold
        Seconds of continuous 503s before the poll loop exits early. Default: 600.

        .PARAMETER State503
        Shared hashtable with keys ConsecutiveErrors (Int), FirstErrorTime (DateTime?), WarningShown (Bool).
        The function mutates these in place across iterations.

        .PARAMETER SupervisorId
        UUID of the supervisor, forwarded to the diagnostic helper on early exit.

        .PARAMETER TotalWaitTime
        Maximum total wait seconds; used to distinguish sleep-continue from timeout-return.

        .EXAMPLE
        $result = Invoke-Supervisor503ErrorHandler -ClusterName $ClusterName -ElapsedTime $elapsed -ErrorMsg $msg -State503 $state503 -SupervisorId $supervisorId -TotalWaitTime 3600
        if ($result.Action -eq 'return') { return $result.Result }
        if ($result.Action -eq 'rethrow') { throw }
        $elapsedTime += $CheckInterval; continue

        .OUTPUTS
        Hashtable with key Action ('sleep-continue' | 'return' | 'rethrow') and optional key Result (PSCustomObject).
    #>

    [CmdletBinding()]
    [OutputType([Hashtable])]
    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(1, [Int]::MaxValue)] [Int]$CheckInterval = 5,
        [Parameter(Mandatory = $true)]  [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [ValidateRange(1, [Int]::MaxValue)] [Int]$CrashDetectionThreshold = 300,
        [Parameter(Mandatory = $false)] [ValidateRange(0, [Int]::MaxValue)] [Int]$ElapsedTime = 0,
        [Parameter(Mandatory = $true)]  [ValidateNotNullOrEmpty()] [String]$ErrorMsg,
        [Parameter(Mandatory = $false)] [ValidateRange(1, [Int]::MaxValue)] [Int]$MaxPersistent503Threshold = 600,
        [Parameter(Mandatory = $true)]  [ValidateNotNull()] [Hashtable]$State503,
        [Parameter(Mandatory = $true)]  [ValidateNotNullOrEmpty()] [String]$SupervisorId,
        [Parameter(Mandatory = $false)] [ValidateRange(1, [Int]::MaxValue)] [Int]$TotalWaitTime = 1800
    )

    if ($ErrorMsg -notmatch "An error occurred while sending the request|The operation has timed out|SERVICE_UNAVAILABLE|Service unavailable|503") {
        return @{ Action = 'rethrow' }
    }

    if ($null -eq $State503.FirstErrorTime) { $State503.FirstErrorTime = Get-Date }
    $State503.ConsecutiveErrors++
    $timeSinceFirst503 = (Get-Date) - $State503.FirstErrorTime

    if ($timeSinceFirst503.TotalSeconds -ge $CrashDetectionThreshold) {
        if (-not $State503.WarningShown) {
            Write-Supervisor503PersistenceWarning `
                -ClusterName $ClusterName `
                -Consecutive503Errors $State503.ConsecutiveErrors `
                -TimeSinceFirst503Seconds $timeSinceFirst503.TotalSeconds
            $State503.WarningShown = $true
        }
        if ($timeSinceFirst503.TotalSeconds -ge $MaxPersistent503Threshold) {
            Write-Progress -Activity "Waiting for Supervisor services to become available" -Status "Failed" -Completed
            [Console]::Out.Flush()
            Write-LogMessage -Type ERROR -Message "Persistent 503 errors have exceeded maximum threshold ($MaxPersistent503Threshold seconds). Exiting early to prevent infinite loop."
            Write-LogMessage -Type ERROR -Message "The supervisor service appears to have crashed or vCenter is unreadable. Deployment cannot continue."
            Write-LogMessage -Type INFO -Message ""
            Write-LogMessage -Type ERROR -Message "Check the supervisor status in vCenter UI: Menu > Workload Management > Supervisor Clusters"
            Invoke-SupervisorKubernetesDiagnosticSafe -ClusterName $ClusterName -Context "persistent supervisor API errors (503) exceeded early-exit threshold" -SupervisorId $SupervisorId
            return @{ Action = 'return'; Result = [PSCustomObject]@{ Success = $false; ElapsedSeconds = $ElapsedTime } }
        }
    } else {
        Write-LogMessage -Type DEBUG -Message "Transient API error during supervisor status check: Service temporarily unavailable. This is expected during supervisor initialization."
    }

    if ($ElapsedTime -lt $TotalWaitTime) {
        $percentComplete = [Math]::Min(99, [int](($ElapsedTime / $TotalWaitTime) * 100))
        $statusMessage = if ($timeSinceFirst503.TotalSeconds -ge $CrashDetectionThreshold) {
            "Elapsed Time: $ElapsedTime seconds - Status: CONFIGURING (WARNING: Persistent 503 errors - supervisor may have crashed)"
        } else {
            "Elapsed Time: $ElapsedTime seconds - Status: CONFIGURING (API service initializing, 503 errors are expected)"
        }
        Write-Progress -Activity "Waiting for Supervisor services to become available" -Status $statusMessage -PercentComplete $percentComplete
        [Console]::Out.Flush()
        Start-Sleep $CheckInterval
        return @{ Action = 'sleep-continue' }
    }

    Write-Progress -Activity "Waiting for Supervisor services to become available" -Status "Timeout" -Completed
    [Console]::Out.Flush()
    Write-LogMessage -Type ERROR -Message "Timeout waiting for supervisor services API to respond on cluster `"$ClusterName`" after $TotalWaitTime seconds."
    if ($timeSinceFirst503.TotalSeconds -ge $CrashDetectionThreshold) {
        Write-LogMessage -Type ERROR -Message "Persistent 503 errors for $([Int]$timeSinceFirst503.TotalSeconds) seconds suggest the supervisor service may have crashed."
    } else {
        Write-LogMessage -Type ERROR -Message "The supervisor may still be initializing. Check vCenter UI for current status."
    }
    Write-LogMessage -Type INFO -Message ""
    Write-LogMessage -Type ERROR -Message "Check the supervisor status in vCenter UI: Menu > Workload Management > Supervisor Clusters"
    Invoke-SupervisorKubernetesDiagnosticSafe -ClusterName $ClusterName -Context "supervisor summary API unavailable until the wait window expired" -SupervisorId $SupervisorId
    return @{ Action = 'return'; Result = [PSCustomObject]@{ Success = $false; ElapsedSeconds = $ElapsedTime } }
}
function Wait-SupervisorReady {

    <#
        .SYNOPSIS
        Waits for a Supervisor to become ready by monitoring its configuration and Kubernetes status.

        .DESCRIPTION
        The Wait-SupervisorReady function monitors a Supervisor's readiness by repeatedly checking its
        ConfigStatus and KubernetesStatus until both reach the desired state (RUNNING and READY) or
        until a timeout occurs. This function provides progress feedback and returns status to the caller.

        The function polls the Supervisor status at regular intervals and displays progress information
        including elapsed time, configuration status, and Kubernetes status. Returns $true on success
        or $false on timeout, allowing the calling function to handle cleanup and error processing.

        .PARAMETER SupervisorId
        The ID of the Supervisor to monitor. This parameter is mandatory.

        .PARAMETER ClusterName
        The name of the cluster where the Supervisor is deployed. Used for logging purposes.

        .PARAMETER CheckInterval
        The interval in seconds between status checks. Default is 5 seconds.

        .PARAMETER TotalWaitTime
        The maximum time in seconds to wait for the Supervisor to become ready. Default is 1800 seconds (30 minutes).

        .EXAMPLE
        $success = Wait-SupervisorReady -SupervisorId $supId -ClusterName "MyCluster"
        if (-not $success) {
            # Handle timeout/failure.
        }

        Waits for the specified Supervisor to become ready and checks the result.

        .EXAMPLE
        Wait-SupervisorReady -SupervisorId $supId -ClusterName "MyCluster" -CheckInterval 15 -TotalWaitTime 3600

        Waits up to 1 hour, checking every 15 seconds.

        .OUTPUTS
        PSCustomObject with properties:
        - Success: Boolean indicating if Supervisor became ready ($true) or timed out ($false)
        - ElapsedSeconds: Integer representing the elapsed time in seconds

        .NOTES
        - Requires an active vCenter connection
        - Uses Invoke-GetSupervisorNamespaceManagementSummary to check status
        - Returns object with success status and elapsed time
        - Does not exit script; allows graceful error handling by caller
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(1, [Int]::MaxValue)] [Int]$CheckInterval = 5,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorId,
        [Parameter(Mandatory = $false)] [ValidateRange(1, [Int]::MaxValue)] [Int]$TotalWaitTime = 1800
    )

    Write-LogMessage -Type DEBUG -Message "Entered Wait-SupervisorReady function..."
    # Clear any lingering progress bar. PowerCLI vLCM uses "Task created by VMware vSphere Lifecycle Manager"; close it if still visible.
    Write-Progress -Activity "Task created by VMware vSphere Lifecycle Manager" -Completed
    Write-Progress -Activity "Waiting for Supervisor services to become available" -Completed
    [Console]::Out.Flush()

    $elapsedTime = 0
    $state503 = @{ ConsecutiveErrors = 0; FirstErrorTime = $null; WarningShown = $false }

    try {
        do {
            try {
                # Suppress error output from the VCF PowerCLI cmdlet to prevent 503 errors from cluttering the console.
                $supervisorStatus = Invoke-GetSupervisorNamespaceManagementSummary -Supervisor $SupervisorId -ErrorAction SilentlyContinue 2>$null

                if ($null -eq $supervisorStatus) {
                    throw [VcfDeploymentException]::new("Service unavailable - supervisor services are still initializing.")
                }

                # Reset 503 tracking on successful API response.
                $state503.ConsecutiveErrors = 0
                $state503.FirstErrorTime = $null
            } catch {
                $handlerResult = Invoke-Supervisor503ErrorHandler `
                    -CheckInterval $CheckInterval `
                    -ClusterName $ClusterName `
                    -ElapsedTime $elapsedTime `
                    -ErrorMsg $_.Exception.Message `
                    -State503 $state503 `
                    -SupervisorId $SupervisorId `
                    -TotalWaitTime $TotalWaitTime

                if ($handlerResult.Action -eq 'return') { return $handlerResult.Result }
                if ($handlerResult.Action -eq 'rethrow') { throw }
                $elapsedTime += $CheckInterval
                continue
            }

            if (($supervisorStatus.ConfigStatus -eq "RUNNING") -and ($supervisorStatus.KubernetesStatus -eq "READY")) {
                Write-Progress -Activity "Waiting for Supervisor services to become available" -Status "Complete" -PercentComplete 100 -Completed
                [Console]::Out.Flush()
                Write-LogMessage -Type INFO -Message "Supervisor services on cluster `"$ClusterName`" were successfully configured in $elapsedTime seconds."
                return [PSCustomObject]@{ Success = $true; ElapsedSeconds = $elapsedTime }
            }

            $percentComplete = [Math]::Min(99, [int](($elapsedTime / $TotalWaitTime) * 100))
            $statusMessage = "Elapsed Time: $elapsedTime seconds - Status: $($supervisorStatus.ConfigStatus)"
            Write-Progress -Activity "Waiting for Supervisor services to become available" -Status $statusMessage -CurrentOperation "Kubernetes Status: $($supervisorStatus.KubernetesStatus)" -PercentComplete $percentComplete
            [Console]::Out.Flush()
            Start-Sleep $CheckInterval
            $elapsedTime += $CheckInterval
        } while ($elapsedTime -lt $TotalWaitTime)

        Write-Progress -Activity "Waiting for Supervisor services to become available" -Status "Timeout" -Completed
        [Console]::Out.Flush()
        Write-LogMessage -Type ERROR -Message "Timeout waiting for supervisor services to become ready on cluster `"$ClusterName`" after $TotalWaitTime seconds ($elapsedTime seconds elapsed)."
        Invoke-SupervisorKubernetesDiagnosticSafe -ClusterName $ClusterName -Context "supervisor did not reach RUNNING with Kubernetes READY within the wait window" -SupervisorId $SupervisorId
        return [PSCustomObject]@{ Success = $false; ElapsedSeconds = $elapsedTime }
    } catch {
        Write-Progress -Activity "Waiting for Supervisor services to become available" -Status "Error" -Completed
        [Console]::Out.Flush()
        Write-LogMessage -Type ERROR -Message "Error checking supervisor services status on cluster `"$ClusterName`": $($_.Exception.Message)"
        Write-LogMessage -Type INFO -Message ""
        Write-LogMessage -Type ERROR -Message "This may indicate:"
        Write-LogMessage -Type ERROR -Message "  1. Network connectivity issues between the client and vCenter."
        Write-LogMessage -Type ERROR -Message "  2. vCenter API temporarily unavailable."
        Write-LogMessage -Type ERROR -Message "  3. Supervisor is in a failed state."
        Write-LogMessage -Type INFO -Message ""
        Write-LogMessage -Type ERROR -Message "Check the supervisor status in vCenter UI: Menu > Workload Management > Supervisors."
        Invoke-SupervisorKubernetesDiagnosticSafe -ClusterName $ClusterName -Context "exception during supervisor readiness polling" -SupervisorId $SupervisorId
        return [PSCustomObject]@{ Success = $false; ElapsedSeconds = $elapsedTime }
    }
}
function Get-SupervisorUpgradeInfo {

    <#
        .SYNOPSIS
        Checks for available supervisor upgrade versions.

        .DESCRIPTION
        The Get-SupervisorUpgradeInfo function queries the namespace management software clusters
        API to determine if there are available upgrade versions for the supervisor cluster.
        It returns information about the current version, available versions, and whether an upgrade is recommended.

        .PARAMETER ClusterId
        The vCenter cluster MoRef identifier (e.g., "domain-c22") where the supervisor is enabled.

        .OUTPUTS
        PSCustomObject with the following properties:
        • Success (Boolean): Indicates if the query succeeded
        • HasUpgradeAvailable (Boolean): Indicates if an upgrade is available
        • CurrentVersion (String): Current supervisor Kubernetes version
        • AvailableVersions (Array): List of available upgrade versions
        • LatestVersion (String): Most recent available version (if any)
        • ClusterState (String): Current state of the cluster (e.g., "READY")
        • ErrorMessage (String): Error details if Success is $false

        .EXAMPLE
        $upgradeInfo = Get-SupervisorUpgradeInfo -ClusterId "domain-c22"
        if ($upgradeInfo.HasUpgradeAvailable) {
            Write-LogMessage -Type INFO -Message "Upgrade available from $($upgradeInfo.CurrentVersion) to $($upgradeInfo.LatestVersion)"
        }

        .NOTES
        API Endpoint: Invoke-ListNamespaceManagementSoftwareClusters

        Behavior:
        • Queries all software clusters and filters for the specified cluster ID
        • Extracts current version, available versions, and cluster state
        • Determines the latest available version from the AvailableVersions array
        • Returns structured object for easy decision-making

        Error Handling:
        • Returns structured object instead of throwing exceptions
        • API failures return Success=$false
    #>
    [OutputType([PSCustomObject])]

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterId
    )

    Write-LogMessage -Type DEBUG -Message "Entered Get-SupervisorUpgradeInfo function..."

    try {
        Write-LogMessage -Type DEBUG -Message "Querying available supervisor upgrade versions for cluster: $ClusterId"

        $softwareClusters = Invoke-ListNamespaceManagementSoftwareClusters -ErrorAction Stop
        $clusterInfo = $softwareClusters | Where-Object { $_.Cluster -eq $ClusterId }

        if (-not $clusterInfo) {
            Write-LogMessage -Type DEBUG -Message "No software cluster information found for cluster ID: $ClusterId"
            return [PSCustomObject]@{
                Success = $true
                HasUpgradeAvailable = $false
                CurrentVersion = $null
                AvailableVersions = @()
                LatestVersion = $null
                ClusterState = $null
                ErrorMessage = $null
            }
        }

        $currentVersion = $clusterInfo.CurrentVersion
        $availableVersions = @()
        $latestVersion = $null

        if ($clusterInfo.AvailableVersions -and $clusterInfo.AvailableVersions.Count -gt 0) {
            $availableVersions = $clusterInfo.AvailableVersions
            # Get the latest version (assuming versions are sorted, or take the first one).
            $latestVersion = $availableVersions[0]
            Write-LogMessage -Type DEBUG -Message "Found $($availableVersions.Count) available upgrade version(s). Latest: $latestVersion"
        }

        $hasUpgradeAvailable = ($availableVersions.Count -gt 0)
        $clusterState = $clusterInfo.State

        if ($hasUpgradeAvailable) {
            Write-LogMessage -Type INFO -Message "Supervisor upgrade available for cluster $ClusterId - Current version $currentVersion, Latest available $latestVersion"
        } else {
            Write-LogMessage -Type DEBUG -Message "No supervisor upgrade available for cluster $ClusterId. Current version $currentVersion"
        }

        return [PSCustomObject]@{
            Success = $true
            HasUpgradeAvailable = $hasUpgradeAvailable
            CurrentVersion = $currentVersion
            AvailableVersions = $availableVersions
            LatestVersion = $latestVersion
            ClusterState = $clusterState
            ErrorMessage = $null
        }
    } catch {
        $errorMessage = $_.Exception.Message
        Write-LogMessage -Type ERROR -Message "Failed to query supervisor upgrade information for cluster $ClusterId - $errorMessage"

        return [PSCustomObject]@{
            Success = $false
            HasUpgradeAvailable = $false
            CurrentVersion = $null
            AvailableVersions = @()
            LatestVersion = $null
            ClusterState = $null
            ErrorMessage = $errorMessage
        }
    }
}
function Invoke-SupervisorUpgrade {

    <#
        .SYNOPSIS
        Upgrades a supervisor cluster to a specified version.

        .DESCRIPTION
        The Invoke-SupervisorUpgrade function upgrades a supervisor cluster to a specified Kubernetes version.
        It performs pre-checks before upgrading and handles the upgrade process for both control plane VMs
        and worker plane hosts. The upgrade is performed as a rolling update to minimize downtime.

        .PARAMETER ClusterId
        The vCenter cluster MoRef identifier (e.g., "domain-c22") where the supervisor is enabled.

        .PARAMETER DesiredVersion
        The target Kubernetes version to upgrade to (e.g., "v1.30.10+vmware.1-fips-vsc9.0.0.0100-24845085").
        This should be one of the versions from the AvailableVersions array returned by Get-SupervisorUpgradeInfo.

        .PARAMETER IgnorePrecheckWarnings
        Switch to ignore precheck warnings and proceed with the upgrade. Default is $false.
        When set to $false, upgrades will not proceed if prechecks return WARNING severity messages.

        .OUTPUTS
        PSCustomObject with the following properties:
        • Success (Boolean): Indicates if upgrade was initiated successfully
        • ErrorMessage (String): Error details if Success is $false

        .EXAMPLE
        $upgradeResult = Invoke-SupervisorUpgrade -ClusterId "domain-c22" -DesiredVersion "v1.30.10+vmware.1-fips-vsc9.0.0.0100-24845085"
        if ($upgradeResult.Success) {
            Write-LogMessage -Type INFO -Message "Supervisor upgrade initiated successfully."
        }

        .NOTES
        API Endpoints:
        • Initialize-NamespaceManagementSoftwareClustersUpgradeSpec or Initialize-VcenterNamespaceManagementSoftwareClustersUpgradeSpec (resolved at runtime)
        • Invoke-UpgradeCluster (-VcenterNamespaceManagementSoftwareClustersUpgradeSpec receives the spec object)

        Behavior:
        • Creates upgrade specification with desired version
        • Performs pre-checks before upgrading
        • Upgrades control plane VMs first, then worker nodes
        • Uses rolling update model to minimize downtime

        Precheck Severity Levels:
        • ERROR: Upgrade does not proceed beyond precheck operation
        • WARNING: Upgrade proceeds only if IgnorePrecheckWarnings is $true
        • INFO: Upgrade proceeds uninterrupted

        Error Handling:
        • Returns structured object instead of throwing exceptions
        • API failures return Success=$false
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterId,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DesiredVersion,
        [Parameter(Mandatory = $false)] [Switch]$IgnorePrecheckWarnings
    )

    Write-LogMessage -Type DEBUG -Message "Entered Invoke-SupervisorUpgrade function..."

    try {
        Write-LogMessage -Type INFO -Message "Initiating supervisor upgrade for cluster $ClusterId to version $DesiredVersion..."

        # VCF PowerCLI 9.0 / 9.1 may expose NamespaceManagement or VcenterNamespaceManagement cmdlet names; resolve at runtime.
        $ignorePrecheckWarningsBool = [Bool]$IgnorePrecheckWarnings
        $upgradeSpecCmd = Get-VcfSdkInitializeCommand -NameCandidates @(
            "Initialize-NamespaceManagementSoftwareClustersUpgradeSpec",
            "Initialize-VcenterNamespaceManagementSoftwareClustersUpgradeSpec"
        )
        if ($null -eq $upgradeSpecCmd) {
            $err = "Required cmdlet for supervisor upgrade spec was not found (Initialize-NamespaceManagementSoftwareClustersUpgradeSpec or Initialize-VcenterNamespaceManagementSoftwareClustersUpgradeSpec)."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }

        $upgradeSpec = & $upgradeSpecCmd -DesiredVersion $DesiredVersion -IgnorePrecheckWarnings $ignorePrecheckWarningsBool

        Invoke-UpgradeCluster `
            -Cluster $ClusterId `
            -VcenterNamespaceManagementSoftwareClustersUpgradeSpec $upgradeSpec `
            -Confirm:$false `
            -ErrorAction Stop | Out-Null

        Write-LogMessage -Type INFO -Message "Supervisor upgrade initiated successfully for cluster $ClusterId to version $DesiredVersion."

        return [PSCustomObject]@{
            Success = $true
            ErrorMessage = $null
        }
    } catch {
        $errorMessage = $_.Exception.Message
        Write-LogMessage -Type ERROR -Message "Failed to initiate supervisor upgrade for cluster $ClusterId - $errorMessage"

        return [PSCustomObject]@{
            Success = $false
            ErrorMessage = $errorMessage
        }
    }
}
function Get-SupervisorUpgradeStatus {

    <#
        .SYNOPSIS
        Verifies the current upgrade status of a supervisor cluster.

        .DESCRIPTION
        The Get-SupervisorUpgradeStatus function queries the namespace management software API
        to check the current upgrade status of a supervisor cluster. It returns detailed information
        about the current version, desired version, upgrade progress, and any upgrade-related messages.

        .PARAMETER ClusterId
        The vCenter cluster MoRef identifier (e.g., "domain-c22") where the supervisor is enabled.

        .OUTPUTS
        PSCustomObject with the following properties:
        • Success (Boolean): Indicates if the query succeeded
        • State (String): Current state of the cluster (e.g., "READY", "UPGRADING")
        • CurrentVersion (String): Current supervisor Kubernetes version
        • DesiredVersion (String): Desired supervisor Kubernetes version (from UpgradeStatus)
        • AvailableVersions (Array): List of available upgrade versions
        • LastUpgradedDate (DateTime): Date of last successful upgrade (if any)
        • IsUpgrading (Boolean): Indicates if an upgrade is currently in progress
        • UpgradeProgress (Object): Upgrade progress information (if available)
        • Messages (Array): Any status or error messages
        • ErrorMessage (String): Error details if Success is $false

        .EXAMPLE
        $status = Get-SupervisorUpgradeStatus -ClusterId "domain-c22"
        if ($status.IsUpgrading) {
            Write-LogMessage -Type INFO -Message "Upgrade in progress. Current: $($status.CurrentVersion), Desired: $($status.DesiredVersion)"
        }

        .NOTES
        API Endpoint: Invoke-GetClusterNamespaceManagementSoftware

        Behavior:
        • Queries cluster-specific software information
        • Extracts upgrade status from UpgradeStatus object
        • Determines if upgrade is in progress by comparing CurrentVersion and DesiredVersion
        • Returns comprehensive status information for monitoring

        Error Handling:
        • Returns structured object instead of throwing exceptions
        • API failures return Success=$false
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterId
    )

    Write-LogMessage -Type DEBUG -Message "Entered Get-SupervisorUpgradeStatus function..."

    try {
        Write-LogMessage -Type DEBUG -Message "Querying supervisor upgrade status for cluster: $ClusterId"

        # The API may return invalid data (empty severity strings) in upgrade_prechecks during upgrade
        # transitions, causing deserialization errors. These are caught and handled in the catch block below.
        $clusterSoftware = Invoke-GetClusterNamespaceManagementSoftware -Cluster $ClusterId -ErrorAction Stop

        $currentVersion = $clusterSoftware.CurrentVersion
        $desiredVersion = $clusterSoftware.UpgradeStatus.DesiredVersion
        $availableVersions = @()
        if ($clusterSoftware.AvailableVersions) {
            $availableVersions = $clusterSoftware.AvailableVersions
        }

        $isUpgrading = $false
        if ($desiredVersion -and $currentVersion -ne $desiredVersion) {
            $isUpgrading = $true
            Write-LogMessage -Type DEBUG -Message "Upgrade in progress - Current version $currentVersion, Desired version $desiredVersion"
        }

        $upgradeProgress = $clusterSoftware.UpgradeStatus.Progress
        $messages = [System.Collections.Generic.List[Object]]::new()
        if ($clusterSoftware.Messages) {
            if ($clusterSoftware.Messages -is [Array]) {
                $messages.AddRange([Object[]]$clusterSoftware.Messages)
            } else {
                $messages.Add($clusterSoftware.Messages)
            }
        }
        if ($clusterSoftware.UpgradeStatus.Messages) {
            if ($clusterSoftware.UpgradeStatus.Messages -is [Array]) {
                $messages.AddRange([Object[]]$clusterSoftware.UpgradeStatus.Messages)
            } else {
                $messages.Add($clusterSoftware.UpgradeStatus.Messages)
            }
        }

        return [PSCustomObject]@{
            Success = $true
            State = $clusterSoftware.State
            CurrentVersion = $currentVersion
            DesiredVersion = $desiredVersion
            AvailableVersions = $availableVersions
            LastUpgradedDate = $clusterSoftware.LastUpgradedDate
            IsUpgrading = $isUpgrading
            UpgradeProgress = $upgradeProgress
            Messages = $messages
            ErrorMessage = $null
        }
    } catch {
        $errorMessage = $_.Exception.Message
        $innerException = $_.Exception.InnerException

        # Check if this is a deserialization error due to invalid API response data (empty severity in upgrade_prechecks).
        # This is a known API issue that can occur during upgrade transitions.
        $isKnownApiIssue = $false
        if ($errorMessage -match "Error converting value.*to type.*Severity" -or
            $errorMessage -match "upgrade_prechecks.*severity" -or
            ($innerException -and ($innerException.Message -match "severity"))) {
            $isKnownApiIssue = $true
            # Try fallback method using Invoke-ListNamespaceManagementSoftwareClusters which may not have the same issue.
            try {
                Write-LogMessage -Type DEBUG -Message "Attempting fallback query using Invoke-ListNamespaceManagementSoftwareClusters..."
                $softwareClusters = Invoke-ListNamespaceManagementSoftwareClusters -ErrorAction Stop
                $clusterInfo = $softwareClusters | Where-Object { $_.Cluster -eq $ClusterId }

                if ($clusterInfo) {
                    Write-LogMessage -Type DEBUG -Message "Fallback query successful. Retrieved basic upgrade status information."
                    $currentVersion = $clusterInfo.CurrentVersion
                    $desiredVersion = $clusterInfo.DesiredVersion
                    $availableVersions = @()
                    if ($clusterInfo.AvailableVersions) {
                        $availableVersions = $clusterInfo.AvailableVersions
                    }

                    $isUpgrading = $false
                    if ($desiredVersion -and $currentVersion -ne $desiredVersion) {
                        $isUpgrading = $true
                    }

                    return [PSCustomObject]@{
                        Success = $true
                        State = $clusterInfo.State
                        CurrentVersion = $currentVersion
                        DesiredVersion = $desiredVersion
                        AvailableVersions = $availableVersions
                        LastUpgradedDate = $clusterInfo.LastUpgradedDate
                        IsUpgrading = $isUpgrading
                        UpgradeProgress = $null
                        Messages = @()
                        ErrorMessage = $null
                    }
                } else {
                    Write-LogMessage -Type DEBUG -Message "Fallback query did not find cluster information for $ClusterId."
                }
            } catch {
                Write-LogMessage -Type DEBUG -Message "Fallback query also failed: $($_.Exception.Message)"
            }
        } else {
            Write-LogMessage -Type ERROR -Message "Failed to query supervisor upgrade status for cluster $ClusterId - $errorMessage"
        }

        $simplifiedErrorMessage = if ($isKnownApiIssue) {
            "API deserialization error (known issue during upgrade transitions). Will retry."
        } else {
            $errorMessage
        }

        return [PSCustomObject]@{
            Success = $false
            State = $null
            CurrentVersion = $null
            DesiredVersion = $null
            AvailableVersions = @()
            LastUpgradedDate = $null
            IsUpgrading = $false
            UpgradeProgress = $null
            Messages = @()
            ErrorMessage = $simplifiedErrorMessage
        }
    }
}
function Invoke-SupervisorUpgradePollLoop {

    <#
    .SYNOPSIS
        Polls vCenter until the supervisor upgrade on a cluster completes or times out.
    .DESCRIPTION
        Loops calling Get-SupervisorUpgradeStatus at CheckInterval-second intervals. Returns a
        success PSCustomObject when the upgrade reaches READY with the desired version. Returns
        $null when TotalWaitTime is exhausted without reaching that state (caller handles timeout).
    .PARAMETER CheckInterval
        Seconds between status checks.
    .PARAMETER ClusterId
        vCenter cluster MoRef ID, passed to Get-SupervisorUpgradeStatus.
    .PARAMETER ClusterName
        Cluster name, used in log and progress messages.
    .PARAMETER ElapsedTimeRef
        Reference to the calling function's elapsed-time counter; incremented inside the loop.
    .PARAMETER TotalWaitTime
        Maximum wait time in seconds before returning $null.
    .EXAMPLE
        $result = Invoke-SupervisorUpgradePollLoop -CheckInterval 30 -ClusterId $id -ClusterName "cl1" -ElapsedTimeRef ([Ref]$elapsed) -TotalWaitTime 3600
    .NOTES
        Returns [PSCustomObject]@{Success=$true; ElapsedSeconds; FinalVersion} on completion, $null on timeout.
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateRange(1, 300)] [Int]$CheckInterval,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$ClusterId,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Ref]$ElapsedTimeRef,
        [Parameter(Mandatory = $true)] [ValidateRange(1, 86400)] [Int]$TotalWaitTime
    )

    do {
        $upgradeStatus = Get-SupervisorUpgradeStatus -ClusterId $ClusterId

        if (-not $upgradeStatus.Success) {
            # Only log WARNING if it's not the known API deserialization issue (logged as DEBUG in Get-SupervisorUpgradeStatus).
            if ($upgradeStatus.ErrorMessage -notmatch "API deserialization error.*known issue") {
                Write-LogMessage -Type WARNING -Message "Failed to query upgrade status: $($upgradeStatus.ErrorMessage). Retrying..."
            } else {
                Write-LogMessage -Type DEBUG -Message "Known API deserialization issue detected. Retrying upgrade status query..."
            }
            Start-Sleep $CheckInterval
            $ElapsedTimeRef.Value += $CheckInterval
            continue
        }

        if (($upgradeStatus.CurrentVersion -eq $upgradeStatus.DesiredVersion) -and ($upgradeStatus.State -eq "READY")) {
            Write-Progress -Activity "Waiting for supervisor upgrade to complete" -Status "Complete" -PercentComplete 100 -Completed
            [Console]::Out.Flush()
            Write-LogMessage -Type INFO -Message "Supervisor upgrade completed successfully on cluster `"$ClusterName`" in $($ElapsedTimeRef.Value) seconds."
            Write-LogMessage -Type INFO -Message "Final version: $($upgradeStatus.CurrentVersion), State: $($upgradeStatus.State)"
            return [PSCustomObject]@{
                Success        = $true
                ElapsedSeconds = $ElapsedTimeRef.Value
                FinalVersion   = $upgradeStatus.CurrentVersion
            }
        }

        $percentComplete = [Math]::Min(99, [int](($ElapsedTimeRef.Value / $TotalWaitTime) * 100))
        $progressSuffix = if ($upgradeStatus.UpgradeProgress) { " - Progress: $($upgradeStatus.UpgradeProgress)" } else { "" }
        $currentOperation = "Desired: $($upgradeStatus.DesiredVersion) - State: $($upgradeStatus.State)$progressSuffix"
        Write-Progress -Activity "Waiting for supervisor upgrade to complete" -Status "Elapsed: $($ElapsedTimeRef.Value) seconds - Current: $($upgradeStatus.CurrentVersion)" -CurrentOperation $currentOperation -PercentComplete $percentComplete
        [Console]::Out.Flush()

        Start-Sleep $CheckInterval
        $ElapsedTimeRef.Value += $CheckInterval

    } while ($ElapsedTimeRef.Value -lt $TotalWaitTime)

    return $null
}
function Wait-SupervisorUpgradeComplete {

    <#
        .SYNOPSIS
        Waits for a supervisor upgrade to complete by monitoring version and state.

        .DESCRIPTION
        The Wait-SupervisorUpgradeComplete function monitors a supervisor cluster upgrade by repeatedly
        checking the current version, desired version, and cluster state until the upgrade completes
        (CurrentVersion equals DesiredVersion and State is READY) or until a timeout occurs.

        This function provides progress feedback with a progress bar showing elapsed time, current version,
        desired version, and cluster state. Returns success when upgrade is complete or failure on timeout.

        .PARAMETER ClusterId
        The vCenter cluster MoRef identifier (e.g., "domain-c22") where the supervisor is enabled.

        .PARAMETER ClusterName
        The name of the cluster where the supervisor is deployed. Used for logging purposes.

        .PARAMETER DesiredVersion
        The target Kubernetes version that the supervisor should be upgraded to.

        .PARAMETER CheckInterval
        The interval in seconds between status checks. Default is 5 seconds.

        .PARAMETER TotalWaitTime
        The maximum time in seconds to wait for the upgrade to complete. Default is 3600 seconds (60 minutes).

        .OUTPUTS
        PSCustomObject with properties:
        • Success (Boolean): Indicates if upgrade completed successfully ($true) or timed out ($false)
        • ElapsedSeconds (Int): Elapsed time in seconds
        • FinalVersion (String): Final version after upgrade (if successful)

        .EXAMPLE
        $result = Wait-SupervisorUpgradeComplete -ClusterId "domain-c22" -ClusterName "MyCluster" -DesiredVersion "v1.30.10+vmware.1-fips-vsc9.0.0.0100-24845085"
        if ($result.Success) {
            Write-LogMessage -Type INFO -Message "Upgrade completed to $($result.FinalVersion)"
        }

        .NOTES
        API Endpoint: Invoke-GetClusterNamespaceManagementSoftware

        Behavior:
        • Polls upgrade status at regular intervals
        • Checks that CurrentVersion equals DesiredVersion
        • Checks that State is "READY"
        • Displays progress bar with version information
        • Returns success only when both conditions are met

        Error Handling:
        • Returns structured object instead of throwing exceptions
        • Timeouts return Success=$false
        • API failures are logged and retried
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(1, [Int]::MaxValue)] [Int]$CheckInterval = 5,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterId,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DesiredVersion,
        [Parameter(Mandatory = $false)] [String]$SupervisorId,
        [Parameter(Mandatory = $false)] [ValidateRange(1, [Int]::MaxValue)] [Int]$TotalWaitTime = 3600
    )

    Write-LogMessage -Type DEBUG -Message "Entered Wait-SupervisorUpgradeComplete function..."

    $elapsedTime = 0

    try {
        Write-LogMessage -Type INFO -Message "Waiting for supervisor upgrade to complete on cluster `"$ClusterName`" (timeout: $TotalWaitTime seconds)..."
        Write-LogMessage -Type INFO -Message "Target version: $DesiredVersion"

        $pollResult = Invoke-SupervisorUpgradePollLoop `
            -CheckInterval $CheckInterval `
            -ClusterId $ClusterId `
            -ClusterName $ClusterName `
            -ElapsedTimeRef ([Ref]$elapsedTime) `
            -TotalWaitTime $TotalWaitTime
        if ($null -ne $pollResult) {
            return $pollResult
        }

        # Timeout reached.
        Write-Progress -Activity "Waiting for supervisor upgrade to complete" -Status "Timeout" -Completed
        [Console]::Out.Flush()
        Write-LogMessage -Type ERROR -Message "Timeout waiting for supervisor upgrade to complete on cluster `"$ClusterName`" after $TotalWaitTime seconds ($elapsedTime seconds elapsed)."

        $finalStatus = Get-SupervisorUpgradeStatus -ClusterId $ClusterId
        if ($finalStatus.Success) {
            Write-LogMessage -Type ERROR -Message "Final status - Current version: $($finalStatus.CurrentVersion), Desired version: $($finalStatus.DesiredVersion), State: $($finalStatus.State)"
        }
        if (-not [String]::IsNullOrWhiteSpace($SupervisorId)) {
            try {
                Write-SupervisorKubernetesDiagnosticReport -ClusterName $ClusterName -Context "supervisor upgrade did not complete within the wait window" -SupervisorId $SupervisorId
            } catch {
                Write-LogMessage -Type DEBUG -Message "Supervisor Kubernetes diagnostics (upgrade timeout): $($_.Exception.Message)"
            }
        }

        return [PSCustomObject]@{
            Success = $false
            ElapsedSeconds = $elapsedTime
            FinalVersion = $null
        }
    } catch {
        Write-Progress -Activity "Waiting for supervisor upgrade to complete" -Status "Error" -Completed
        [Console]::Out.Flush()
        Write-LogMessage -Type ERROR -Message "Error waiting for supervisor upgrade to complete on cluster `"$ClusterName`": $($_.Exception.Message)"
        if (-not [String]::IsNullOrWhiteSpace($SupervisorId)) {
            try {
                Write-SupervisorKubernetesDiagnosticReport -ClusterName $ClusterName -Context "exception during supervisor upgrade wait" -SupervisorId $SupervisorId
            } catch {
                Write-LogMessage -Type DEBUG -Message "Supervisor Kubernetes diagnostics (upgrade exception): $($_.Exception.Message)"
            }
        }
        return [PSCustomObject]@{
            Success = $false
            ElapsedSeconds = $elapsedTime
            FinalVersion = $null
        }
    }
}
function Get-SupervisorNetworkVanityDisplayName {

    <#
        .SYNOPSIS
        Combines a lowercase RFC1123 prefix with a distributed port group label for WCP supervisor API vanity names.

        .DESCRIPTION
        Port group names in supervisor JSON remain the vSphere DVPG labels used for MoRef resolution. WCP expects
        distinct logical network names in some fields; this helper prefixes the port group label so FLB management,
        FLB virtual-server, supervisor management, and primary workload vanity names cannot collide when they share the same DVPG name.

        .PARAMETER MaxTotalLength
        Maximum length for the combined string (default 80, aligned with supervisor port group name validation).

        .PARAMETER PortGroupName
        Distributed port group label from supervisor JSON (already lowercase RFC1123).

        .PARAMETER VanityPrefix
        Short lowercase prefix identifying the spec stanza (e.g. fmn for FLB management network).

        .OUTPUTS
        [String] Prefix plus port group label, still lowercase RFC1123 when inputs are valid.
    
        .EXAMPLE
        $supervisorNetworkVanityDisplayName = Get-SupervisorNetworkVanityDisplayName -PortGroupName "resource-name" -VanityPrefix "value"
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(1, 253)] [Int]$MaxTotalLength = 80,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$PortGroupName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VanityPrefix
    )

    $normalizedPrefix = $VanityPrefix.Trim().ToLowerInvariant()
    $combined = "${normalizedPrefix}${PortGroupName}"
    if ($combined.Length -gt $MaxTotalLength) {
        $err = "Supervisor network vanity name exceeds max length $MaxTotalLength (prefix + port group name): $combined."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }

    return $combined
}
function Get-ManagementNetworkConfig {

    <#
        .SYNOPSIS
        Extracts and validates management network configuration from supervisor specification.

        .DESCRIPTION
        Parses management network configuration from the supervisor component specification and resolves port group IDs. IP assignment mode is supplied by the caller (expected STATIC).

        .PARAMETER SuppressNetworkVanityPrefix
        When set, the API-facing Name matches the port group label (legacy behavior). When not set, Name is prefixed to avoid WCP vanity name collisions.

        .PARAMETER Gateway
        Gateway address for the management network from infrastructure JSON.

        .PARAMETER MgmtNetworkVanityPrefix
        Lowercase prefix for the supervisor management network vanity name (default tmn).

        .PARAMETER Spec
        Management network specification object from supervisorDetails.supervisorComponentSpec.mgmtNetworkSpec

        .OUTPUTS
        PSCustomObject with validated management network configuration

        .EXAMPLE
        $mgmtConfig = Get-ManagementNetworkConfig -Spec $supervisorDetails.supervisorComponentSpec.mgmtNetworkSpec -Gateway $gw
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Gateway,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$MgmtNetworkVanityPrefix = "tmn",
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [PSCustomObject]$Spec,
        [Parameter(Mandatory = $false)] [Switch]$SuppressNetworkVanityPrefix
    )

    Write-LogMessage -Type DEBUG -Message "Entered Get-ManagementNetworkConfig function..."

    try {
        $ipAssignmentMode = $Spec.mgmtIpAssignmentMode
        Write-LogMessage -Type DEBUG -Message "  IP assignment mode: $ipAssignmentMode"

        # Resolve port group ID.
        $networkName = $Spec.mgmtNetworkName
        Write-LogMessage -Type DEBUG -Message "  Resolving port group ID for management network: $networkName"
        $portgroupID = Get-PortGroupId -PortGroupName $networkName

        if ([String]::IsNullOrEmpty($portgroupID)) {
            $err = "Failed to resolve port group ID for management network: $networkName."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }

        $displayName = if ($SuppressNetworkVanityPrefix) {
            $networkName
        } else {
            Get-SupervisorNetworkVanityDisplayName -PortGroupName $networkName -VanityPrefix $MgmtNetworkVanityPrefix
        }

        $config = [PSCustomObject]@{
            Name = $displayName
            PortGroupID = $portgroupID
            PortGroupName = $networkName
            IPAssignmentMode = $ipAssignmentMode
            DHCPEnabled = $false
            StartingIP = $Spec.mgmtNetworkStartingIp
            IPCount = $Spec.mgmtNetworkIPCount
            Gateway = $Gateway
            DNSServers = $Spec.mgmtNetworkDnsServers
            NTPServers = $Spec.mgmtNetworkNtpServers
            SearchDomains = $Spec.mgmtNetworkSearchDomains
        }

        Write-LogMessage -Type DEBUG -Message "  Management network configuration extracted: $($config.Name) (port group: $($config.PortGroupName)) with $($config.IPCount) IPs"
        Write-LogMessage -Type DEBUG -Message "    Starting IP: $($config.StartingIP), Gateway: $($config.Gateway)."
        return $config
    } catch [VcfDeploymentException] {
        throw  # already logged and typed — propagate without re-wrapping
    } catch {
        $err = "Failed to extract management network configuration: $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
}
function Get-WorkloadNetworkConfig {

    <#
        .SYNOPSIS
        Extracts and validates workload network configuration from supervisor specification.

        .DESCRIPTION
        Parses workload network configuration from the supervisor component specification and resolves port group IDs. IP assignment mode is supplied by the caller (expected STATIC).

        .PARAMETER SuppressNetworkVanityPrefix
        When set, the API-facing Name matches the port group label (legacy behavior). When not set, Name is prefixed to avoid WCP vanity name collisions.

        .PARAMETER Gateway
        Gateway address for the workload network from infrastructure JSON.

        .PARAMETER PrimaryWorkloadNetworkVanityPrefix
        Lowercase prefix for the primary workload network vanity name (default pwn).

        .PARAMETER Spec
        Workload network specification object from supervisorDetails.supervisorComponentSpec.primaryWorkloadNetwork

        .OUTPUTS
        PSCustomObject with validated workload network configuration

        .EXAMPLE
        $workloadConfig = Get-WorkloadNetworkConfig -Spec $supervisorDetails.supervisorComponentSpec.primaryWorkloadNetwork -Gateway $gw
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Gateway,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$PrimaryWorkloadNetworkVanityPrefix = "pwn",
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [PSCustomObject]$Spec,
        [Parameter(Mandatory = $false)] [Switch]$SuppressNetworkVanityPrefix
    )

    Write-LogMessage -Type DEBUG -Message "Entered Get-WorkloadNetworkConfig function..."

    try {
        $ipAssignmentMode = $Spec.primaryWorkloadIpAssignmentMode
        Write-LogMessage -Type DEBUG -Message "  IP assignment mode: $ipAssignmentMode."

        # Resolve port group ID.
        $networkName = $Spec.primaryWorkloadNetworkName
        Write-LogMessage -Type DEBUG -Message "  Resolving port group ID for workload network: $networkName."
        $portgroupID = Get-PortGroupId -PortGroupName $networkName

        if ([String]::IsNullOrEmpty($portgroupID)) {
            $err = "Failed to resolve port group ID for workload network: $networkName."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }

        $displayName = if ($SuppressNetworkVanityPrefix) {
            $networkName
        } else {
            Get-SupervisorNetworkVanityDisplayName -PortGroupName $networkName -VanityPrefix $PrimaryWorkloadNetworkVanityPrefix
        }

        $config = [PSCustomObject]@{
            Name = $displayName
            PortGroupID = $portgroupID
            PortGroupName = $networkName
            IPAssignmentMode = $ipAssignmentMode
            DHCPEnabled = $false
            StartingIP = $Spec.primaryWorkloadNetworkStartingIp
            IPCount = $Spec.primaryWorkloadNetworkIPCount
            Gateway = $Gateway
            DNSServers = $Spec.workloadDnsServers
            NTPServers = $Spec.workloadNtpServers
            SearchDomains = $Spec.primaryWorkloadNetworkSearchDomains
            ServiceStartIP = $Spec.workloadServiceStartIp
            ServiceCount = $Spec.workloadServiceCount
        }

        Write-LogMessage -Type DEBUG -Message "  Workload network configuration extracted: $($config.Name) (port group: $($config.PortGroupName)) with $($config.IPCount) node IPs and $($config.ServiceCount) service IPs."
        Write-LogMessage -Type DEBUG -Message "    Node IP: $($config.StartingIP), Service IP: $($config.ServiceStartIP)."
        return $config
    } catch [VcfDeploymentException] {
        throw  # already logged and typed — propagate without re-wrapping
    } catch {
        $err = "Failed to extract workload network configuration: $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
}
function Get-FLBNetworkConfig {

    <#
        .SYNOPSIS
        Extracts Foundation Load Balancer network configuration.

        .DESCRIPTION
        Parses FLB network configuration (management or virtual server network) and resolves port group IDs.

        .PARAMETER SuppressNetworkVanityPrefix
        When set, the API-facing Name matches the port group label (legacy behavior). When not set, Name is prefixed to avoid WCP vanity name collisions.

        .PARAMETER Gateway
        Gateway CIDR for this FLB network from infrastructure JSON.

        .PARAMETER NetworkSpec
        FLB network specification from foundationLoadBalancerComponents

        .PARAMETER VanityPrefix
        Lowercase prefix for this FLB stanza (fmn for management, fvsn for virtual server network).

        .OUTPUTS
        PSCustomObject with FLB network configuration

        .EXAMPLE
        $flbMgmtNet = Get-FLBNetworkConfig -NetworkSpec $supervisorDetails.supervisorComponentSpec.foundationLoadBalancerComponents.flbManagementNetwork -Gateway $gw -VanityPrefix "fmn"
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Gateway,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [PSCustomObject]$NetworkSpec,
        [Parameter(Mandatory = $false)] [Switch]$SuppressNetworkVanityPrefix,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VanityPrefix
    )

    Write-LogMessage -Type DEBUG -Message "Entered Get-FLBNetworkConfig function..."

    try {
        # Resolve port group ID.
        $networkName = $NetworkSpec.flbNetworkName
        Write-LogMessage -Type DEBUG -Message "  Resolving port group ID for FLB network: $networkName"
        $portGroupID = Get-PortGroupId -PortGroupName $networkName

        if ([String]::IsNullOrEmpty($portGroupID)) {
            $err = "Failed to resolve port group ID for FLB network: $networkName."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }

        $displayName = if ($SuppressNetworkVanityPrefix) {
            $networkName
        } else {
            Get-SupervisorNetworkVanityDisplayName -PortGroupName $networkName -VanityPrefix $VanityPrefix
        }

        $config = [PSCustomObject]@{
            Name = $displayName
            PortGroupID = $portGroupID
            PortGroupName = $networkName
            Type = $NetworkSpec.flbNetworkType
            IPAssignmentMode = $NetworkSpec.flbNetworkIpAssignmentMode
            StartingIP = $NetworkSpec.flbNetworkIpAddressStartingIp
            IPCount = $NetworkSpec.flbNetworkIpAddressCount
            Gateway = $Gateway
        }
        if ($NetworkSpec.PSObject.Properties.Name -contains "flbNetworkPersona" -and $null -ne $NetworkSpec.flbNetworkPersona) {
            $config | Add-Member -NotePropertyName "Persona" -NotePropertyValue $NetworkSpec.flbNetworkPersona -Force
        }

        Write-LogMessage -Type DEBUG -Message "  FLB network configuration extracted: $($config.Name) (port group: $($config.PortGroupName)), Type: $($config.Type)"
        Write-LogMessage -Type DEBUG -Message "    IP Assignment: $($config.IPAssignmentMode), Count: $($config.IPCount)"
        return $config
    } catch [VcfDeploymentException] {
        throw  # already logged and typed — propagate without re-wrapping
    } catch {
        $err = "Failed to extract FLB network configuration: $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
}
function Get-LoadBalancerConfig {

    <#
        .SYNOPSIS
        Extracts Foundation Load Balancer configuration from supervisor specification.

        .DESCRIPTION
        Parses complete FLB configuration including both management and virtual server networks.
        Gateways are now provided from infrastructure JSON instead of supervisor JSON.

        .PARAMETER Spec
        Foundation Load Balancer specification from supervisorDetails.supervisorComponentSpec.foundationLoadBalancerComponents

        .PARAMETER FlbMgmtNetworkGateway
        Gateway CIDR for FLB management network from infrastructure JSON (e.g., "10.30.11.1/24")

        .PARAMETER FlbVirtualServerNetworkGateway
        Gateway CIDR for FLB virtual server network from infrastructure JSON (e.g., "10.30.12.1/24")

        .PARAMETER FlbManagementNetworkVanityPrefix
        Lowercase prefix for FLB management network vanity name (default fmn).

        .PARAMETER FlbVirtualServerNetworkVanityPrefix
        Lowercase prefix for FLB virtual server network vanity name (default fvsn).

        .PARAMETER SuppressNetworkVanityPrefix
        When set, FLB API-facing network names match port group labels (legacy behavior).

        .OUTPUTS
        PSCustomObject with complete FLB configuration

        .EXAMPLE
        $flbConfig = Get-LoadBalancerConfig -Spec $supervisorDetails.supervisorComponentSpec.foundationLoadBalancerComponents -FlbMgmtNetworkGateway "10.30.11.1/24" -FlbVirtualServerNetworkGateway "10.30.12.1/24"
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$FlbManagementNetworkVanityPrefix = "fmn",
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$FlbMgmtNetworkGateway,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$FlbVirtualServerNetworkGateway,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$FlbVirtualServerNetworkVanityPrefix = "fvsn",
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [PSCustomObject]$Spec,
        [Parameter(Mandatory = $false)] [Switch]$SuppressNetworkVanityPrefix
    )

    Write-LogMessage -Type DEBUG -Message "Entered Get-LoadBalancerConfig function..."

    try {
        Write-LogMessage -Type DEBUG -Message "Extracting Foundation Load Balancer configuration..."

        # Extract management and virtual server network configurations (with gateways from infrastructure JSON).
        $mgmtNetwork = Get-FLBNetworkConfig -SuppressNetworkVanityPrefix:$SuppressNetworkVanityPrefix -Gateway $FlbMgmtNetworkGateway -NetworkSpec $Spec.flbManagementNetwork -VanityPrefix $FlbManagementNetworkVanityPrefix
        $vsNetwork = Get-FLBNetworkConfig -SuppressNetworkVanityPrefix:$SuppressNetworkVanityPrefix -Gateway $FlbVirtualServerNetworkGateway -NetworkSpec $Spec.flbVirtualServerNetwork -VanityPrefix $FlbVirtualServerNetworkVanityPrefix

        $config = [PSCustomObject]@{
            Name = $Spec.flbName
            Size = $Spec.flbSize
            Availability = $Spec.flbAvailability
            VipStartIP = $Spec.flbVipStartIP
            VipIPCount = $Spec.flbVipIPCount
            Provider = $Spec.flbProvider
            DNSServers = $Spec.flbDnsServers
            NTPServers = $Spec.flbNtpServers
            SearchDomains = $Spec.flbSearchDomains
            ManagementNetwork = $mgmtNetwork
            VirtualServerNetwork = $vsNetwork
        }

        Write-LogMessage -Type DEBUG -Message "FLB configuration extracted: $($config.Name), Size: $($config.Size), VIPs: $($config.VipIPCount)"
        return $config
    } catch [VcfDeploymentException] {
        throw  # already logged and typed — propagate without re-wrapping
    } catch {
        $err = "Failed to extract Foundation Load Balancer configuration: $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
}
function Get-GatewayFromNetworkName {

    <#
        .SYNOPSIS
        Returns the gateway IP for a named network segment, throwing if the name is not found.

        .DESCRIPTION
        Looks up $NetworkName in $NetworkGatewayMap (a hashtable built from infrastructure JSON
        networkSegments). Throws a VcfDeploymentException when the name is absent so callers
        get an explicit error rather than a silent $null propagating into a VCF API spec.

        .PARAMETER NetworkGatewayMap
        Hashtable mapping network segment names to their gateway IPs. Build it from
        $NetworkSegments (infrastructure JSON) before calling this function.

        .PARAMETER NetworkName
        Network segment name to look up (case-sensitive, as stored in infrastructure JSON).

        .OUTPUTS
        System.String — the gateway IP for the named segment.

        .EXAMPLE
        $gw = Get-GatewayFromNetworkName -NetworkName "mgmt-net" -NetworkGatewayMap $networkGatewayMap
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Hashtable]$NetworkGatewayMap,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$NetworkName
    )

    if ($NetworkGatewayMap.ContainsKey($NetworkName)) {
        return $NetworkGatewayMap[$NetworkName]
    }
    $err = "Gateway not found for network name: $NetworkName."
    Write-LogMessage -Type ERROR -Message $err
    throw [VcfDeploymentException]::new($err)
}
function New-SupervisorMgmtNetworkSpec {

    <#
        .SYNOPSIS
        Builds the management network spec PSCustomObject from raw JSON values.

        .DESCRIPTION
        Constructs the management network specification used by Get-ManagementNetworkConfig from
        individual siteSpec and commonSupervisorSpec properties. This is a pure data-construction
        helper with no side effects.

        .PARAMETER CommonSpec
        The commonSupervisorSpec section from the parsed supervisor JSON.

        .PARAMETER MgmtIpAssignmentMode
        IP assignment mode for the management network. Default is STATIC.

        .PARAMETER SiteSpec
        The matching siteSpec entry from the parsed supervisor JSON.

        .EXAMPLE
        $spec = New-SupervisorMgmtNetworkSpec -SiteSpec $siteSpec -CommonSpec $commonSpec

        .NOTES
        Private helper for Get-SupervisorConfigurationFromJson.
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$CommonSpec,
        [Parameter(Mandatory = $false)] [ValidateSet("STATIC")] [String]$MgmtIpAssignmentMode = "STATIC",
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$SiteSpec
    )

    return [PSCustomObject]@{
        mgmtIpAssignmentMode        = $MgmtIpAssignmentMode
        mgmtNetworkName             = $SiteSpec.mgmtNetworkSpec.mgmtNetworkName
        mgmtNetworkStartingIp       = $SiteSpec.mgmtNetworkSpec.mgmtNetworkStartingIp
        mgmtNetworkIPCount          = $SiteSpec.mgmtNetworkSpec.mgmtNetworkIPCount
        mgmtNetworkDnsServers       = $CommonSpec.dnsServers
        mgmtNetworkNtpServers       = $CommonSpec.networkNtpServers
        mgmtNetworkSearchDomains    = $CommonSpec.networkSearchDomains
    }
}
function New-SupervisorWorkloadNetworkSpec {

    <#
        .SYNOPSIS
        Builds the primary workload network spec PSCustomObject from raw JSON values.

        .DESCRIPTION
        Constructs the workload network specification used by Get-WorkloadNetworkConfig from
        individual siteSpec and commonSupervisorSpec properties. This is a pure data-construction
        helper with no side effects.

        .PARAMETER CommonSpec
        The commonSupervisorSpec section from the parsed supervisor JSON.

        .PARAMETER PrimaryWorkloadIpAssignmentMode
        IP assignment mode for the primary workload network. Default is STATIC.

        .PARAMETER SiteSpec
        The matching siteSpec entry from the parsed supervisor JSON.

        .EXAMPLE
        $spec = New-SupervisorWorkloadNetworkSpec -SiteSpec $siteSpec -CommonSpec $commonSpec

        .NOTES
        Private helper for Get-SupervisorConfigurationFromJson.
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$CommonSpec,
        [Parameter(Mandatory = $false)] [ValidateSet("STATIC")] [String]$PrimaryWorkloadIpAssignmentMode = "STATIC",
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$SiteSpec
    )

    return [PSCustomObject]@{
        primaryWorkloadIpAssignmentMode        = $PrimaryWorkloadIpAssignmentMode
        primaryWorkloadNetworkName             = $SiteSpec.primaryWorkloadNetwork.primaryWorkloadNetworkName
        primaryWorkloadNetworkStartingIp       = $SiteSpec.primaryWorkloadNetwork.primaryWorkloadNetworkStartingIp
        primaryWorkloadNetworkIPCount          = $SiteSpec.primaryWorkloadNetwork.primaryWorkloadNetworkIPCount
        workloadDnsServers                     = $CommonSpec.dnsServers
        workloadNtpServers                     = $CommonSpec.networkNtpServers
        primaryWorkloadNetworkSearchDomains    = $CommonSpec.networkSearchDomains
        workloadServiceStartIp                 = $SiteSpec.primaryWorkloadNetwork.workloadServiceStartIp
        workloadServiceCount                   = $SiteSpec.primaryWorkloadNetwork.workloadServiceCount
    }
}
function New-SupervisorFlbSpec {

    <#
        .SYNOPSIS
        Builds the Foundation Load Balancer spec PSCustomObject from raw JSON values.

        .DESCRIPTION
        Constructs the FLB specification used by Get-LoadBalancerConfig from individual siteSpec
        and commonSupervisorSpec properties. This is a pure data-construction helper with no side
        effects.

        .PARAMETER CommonSpec
        The commonSupervisorSpec section from the parsed supervisor JSON.

        .PARAMETER FlbMgmtNetworkPersona
        FLB management network persona. Default is MANAGEMENT.

        .PARAMETER FlbNetworkIpAssignmentMode
        IP assignment mode for FLB networks. Default is STATIC.

        .PARAMETER FlbProvider
        Foundation Load Balancer provider. Default is VSPHERE_FOUNDATION.

        .PARAMETER FlbVirtualServerNetworkPersona
        FLB virtual server network persona(s). Default is FRONTEND and WORKLOAD.

        .PARAMETER SiteSpec
        The matching siteSpec entry from the parsed supervisor JSON.

        .EXAMPLE
        $flbSpec = New-SupervisorFlbSpec -SiteSpec $siteSpec -CommonSpec $commonSpec

        .NOTES
        Private helper for Get-SupervisorConfigurationFromJson.
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$CommonSpec,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$FlbMgmtNetworkPersona = "MANAGEMENT",
        [Parameter(Mandatory = $false)] [ValidateSet("STATIC")] [String]$FlbNetworkIpAssignmentMode = "STATIC",
        [Parameter(Mandatory = $false)] [ValidateSet("VSPHERE_FOUNDATION")] [String]$FlbProvider = "VSPHERE_FOUNDATION",
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [Object[]]$FlbVirtualServerNetworkPersona = @("FRONTEND", "WORKLOAD"),
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$SiteSpec
    )

    $flbComponents = $SiteSpec.foundationLoadBalancerComponents
    return [PSCustomObject]@{
        flbName              = $flbComponents.flbName
        flbSize              = $CommonSpec.flbSize
        flbAvailability      = $CommonSpec.flbAvailability
        flbVipStartIP        = $flbComponents.flbVipStartIP
        flbVipIPCount        = $flbComponents.flbVipIPCount
        flbProvider          = $FlbProvider
        flbDnsServers        = $CommonSpec.dnsServers
        flbNtpServers        = $CommonSpec.networkNtpServers
        flbSearchDomains     = $CommonSpec.networkSearchDomains
        flbManagementNetwork = [PSCustomObject]@{
            flbNetworkIpAssignmentMode    = $FlbNetworkIpAssignmentMode
            flbNetworkName                = $flbComponents.flbManagementNetwork.flbNetworkName
            flbNetworkType                = $CommonSpec.flbNetworkType
            flbNetworkIpAddressStartingIp = $flbComponents.flbManagementNetwork.flbNetworkIpAddressStartingIp
            flbNetworkIpAddressCount      = $flbComponents.flbManagementNetwork.flbNetworkIpAddressCount
            flbNetworkPersona             = $FlbMgmtNetworkPersona
        }
        flbVirtualServerNetwork = [PSCustomObject]@{
            flbNetworkIpAssignmentMode    = $FlbNetworkIpAssignmentMode
            flbNetworkName                = $flbComponents.flbVirtualServerNetwork.flbNetworkName
            flbNetworkType                = $CommonSpec.flbNetworkType
            flbNetworkIpAddressStartingIp = $flbComponents.flbVirtualServerNetwork.flbNetworkIpAddressStartingIp
            flbNetworkIpAddressCount      = $flbComponents.flbVirtualServerNetwork.flbNetworkIpAddressCount
            flbNetworkPersona             = $FlbVirtualServerNetworkPersona
        }
    }
}
function Get-SupervisorConfigurationFromJson {

    <#
        .SYNOPSIS
        Parses supervisor JSON configuration into a structured configuration object.

        .DESCRIPTION
        Extracts and validates all supervisor configuration parameters from the input JSON file,
        returning a PSCustomObject with organized sections for control plane, networks, and FLB.
        This function delegates to specialized parsers for each configuration section.
        Merges commonSupervisorSpec (shared config) with siteSpec (site-specific config) based on edgeSite.

        .PARAMETER SuppressNetworkVanityPrefix
        When set, WCP API vanity network names match distributed port group labels (legacy). When not set (default), names are prefixed per network role (fmn, fvsn, pwn, tmn) so logical names do not collide within a site.

        .PARAMETER EdgeSite
        Edge site identifier to match against siteSpec entries

        .PARAMETER FlbMgmtNetworkPersona
        FLB management network persona. Default is Management.

        .PARAMETER FlbNetworkIpAssignmentMode
        FLB network IP assignment mode. Default is STATIC (only supported value).

        .PARAMETER FlbProvider
        Foundation Load Balancer provider. Default is VSPHERE_FOUNDATION (only supported value).

        .PARAMETER FlbVirtualServerNetworkPersona
        FLB virtual server network persona(s). Default is FRONTEND and WORKLOAD.

        .PARAMETER JsonFilePath
        Full path to the JSON configuration file containing supervisor specifications

        .PARAMETER NetworkSegments
        Array of network segments from infrastructure JSON for gateway mapping

        .PARAMETER MgmtIpAssignmentMode
        Supervisor management network IP assignment mode. Default is STATIC (only supported value).

        .PARAMETER PrimaryWorkloadIpAssignmentMode
        Primary workload network IP assignment mode. Default is STATIC (only supported value).

        .OUTPUTS
        PSCustomObject with structured configuration:
        - ControlPlane: VM count and size
        - ManagementNetwork: Network configuration for control plane
        - WorkloadNetwork: Network configuration for workloads
        - LoadBalancer: FLB configuration including management and virtual server networks

        .EXAMPLE
        $config = Get-SupervisorConfigurationFromJson -JsonFilePath "./configs/supervisor.json" -EdgeSite "site1" -NetworkSegments $networkSegments
        Write-LogMessage -Type INFO -Message "Control Plane Size: $($config.ControlPlane.Size)"
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EdgeSite,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$FlbMgmtNetworkPersona = "MANAGEMENT",
        [Parameter(Mandatory = $false)] [ValidateSet("STATIC")] [String]$FlbNetworkIpAssignmentMode = "STATIC",
        [Parameter(Mandatory = $false)] [ValidateSet("VSPHERE_FOUNDATION")] [String]$FlbProvider = "VSPHERE_FOUNDATION",
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [Object[]]$FlbVirtualServerNetworkPersona = @("FRONTEND", "WORKLOAD"),
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$JsonFilePath,
        [Parameter(Mandatory = $false)] [ValidateSet("STATIC")] [String]$MgmtIpAssignmentMode = "STATIC",
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Object[]]$NetworkSegments,
        [Parameter(Mandatory = $false)] [ValidateSet("STATIC")] [String]$PrimaryWorkloadIpAssignmentMode = "STATIC",
        [Parameter(Mandatory = $false)] [Switch]$SuppressNetworkVanityPrefix
    )

    Write-LogMessage -Type DEBUG -Message "Entered Get-SupervisorConfigurationFromJson function..."

    try {
        Write-LogMessage -Type DEBUG -Message "Parsing supervisor configuration from JSON file..."

        $supervisorDetails = ConvertFrom-JsonSafely -JsonFilePath $JsonFilePath

        if ($null -eq $supervisorDetails) {
            $err = "Failed to parse JSON file or file is empty."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }

        Write-LogMessage -Type DEBUG -Message "Extracting common supervisor specification..."
        $commonSpec = $supervisorDetails.commonSupervisorSpec
        if (-not $commonSpec) {
            $err = "commonSupervisorSpec not found in supervisor JSON"
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }

        Write-LogMessage -Type DEBUG -Message "Finding matching site specification for edgeSite: $EdgeSite."
        $siteSpec = $supervisorDetails.siteSpec | Where-Object { $_.edgeSite -eq $EdgeSite } | Select-Object -First 1
        if (-not $siteSpec) {
            $err = "No matching siteSpec found for edgeSite: $EdgeSite."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }

        $networkGatewayMap = @{}
        foreach ($networkSegment in $NetworkSegments) {
            if ($networkSegment.name -and $networkSegment.gateway) {
                $networkGatewayMap[$networkSegment.name] = $networkSegment.gateway
            }
        }

        Write-LogMessage -Type DEBUG -Message "Extracting control plane configuration..."
        $controlPlane = [PSCustomObject]@{
            VMCount = $commonSpec.controlPlaneVMCount
            Size = $commonSpec.controlPlaneSize
        }

        Write-LogMessage -Type DEBUG -Message "Extracting network configurations..."

        $mgmtNetworkSpec = New-SupervisorMgmtNetworkSpec -SiteSpec $siteSpec -CommonSpec $commonSpec -MgmtIpAssignmentMode $MgmtIpAssignmentMode
        $mgmtNetworkGateway = Get-GatewayFromNetworkName -NetworkName $mgmtNetworkSpec.mgmtNetworkName -NetworkGatewayMap $networkGatewayMap
        $mgmtNetwork = Get-ManagementNetworkConfig -SuppressNetworkVanityPrefix:$SuppressNetworkVanityPrefix -Gateway $mgmtNetworkGateway -Spec $mgmtNetworkSpec

        $workloadNetworkSpec = New-SupervisorWorkloadNetworkSpec -SiteSpec $siteSpec -CommonSpec $commonSpec -PrimaryWorkloadIpAssignmentMode $PrimaryWorkloadIpAssignmentMode
        $workloadNetworkGateway = Get-GatewayFromNetworkName -NetworkName $workloadNetworkSpec.primaryWorkloadNetworkName -NetworkGatewayMap $networkGatewayMap
        $workloadNetwork = Get-WorkloadNetworkConfig -SuppressNetworkVanityPrefix:$SuppressNetworkVanityPrefix -Gateway $workloadNetworkGateway -Spec $workloadNetworkSpec

        $flbSpec = New-SupervisorFlbSpec -SiteSpec $siteSpec -CommonSpec $commonSpec `
            -FlbNetworkIpAssignmentMode $FlbNetworkIpAssignmentMode -FlbProvider $FlbProvider `
            -FlbMgmtNetworkPersona $FlbMgmtNetworkPersona -FlbVirtualServerNetworkPersona $FlbVirtualServerNetworkPersona
        $flbMgmtNetworkGateway = Get-GatewayFromNetworkName -NetworkName $flbSpec.flbManagementNetwork.flbNetworkName -NetworkGatewayMap $networkGatewayMap
        $flbVsNetworkGateway = Get-GatewayFromNetworkName -NetworkName $flbSpec.flbVirtualServerNetwork.flbNetworkName -NetworkGatewayMap $networkGatewayMap
        $loadBalancer = Get-LoadBalancerConfig -SuppressNetworkVanityPrefix:$SuppressNetworkVanityPrefix -FlbMgmtNetworkGateway $flbMgmtNetworkGateway -FlbVirtualServerNetworkGateway $flbVsNetworkGateway -Spec $flbSpec

        $config = [PSCustomObject]@{
            ControlPlane = $controlPlane
            ManagementNetwork = $mgmtNetwork
            WorkloadNetwork = $workloadNetwork
            LoadBalancer = $loadBalancer
        }

        Write-LogMessage -Type INFO -Message "Supervisor configuration parsed successfully for edgeSite: $EdgeSite."
        Write-LogMessage -Type DEBUG -Message "Control Plane: $($controlPlane.VMCount) x $($controlPlane.Size)"
        Write-LogMessage -Type DEBUG -Message "Management Network: $($mgmtNetwork.Name)"
        Write-LogMessage -Type DEBUG -Message "Workload Network: $($workloadNetwork.Name)"
        Write-LogMessage -Type DEBUG -Message "Load Balancer: $($loadBalancer.Name)"

        return $config
    } catch [VcfDeploymentException] {
        throw  # already logged and typed — propagate without re-wrapping
    } catch {
        $err = "Failed to parse supervisor configuration from JSON: $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
}
function Test-SupervisorConfiguration {

    <#
        .SYNOPSIS
        Validates supervisor configuration structure before deployment.

        .DESCRIPTION
        Performs runtime validation of supervisor configuration object structure to ensure all
        required configuration sections are present. This function validates:
        • Management network configuration object exists
        • Workload network configuration object exists
        • Foundation Load Balancer configuration object exists
        • Control plane configuration object exists
        • Workload service count meets recommended minimum (configurable via MinimumServiceCount parameter, default 16)

        This function performs STRUCTURAL validation only. Value-level validation is handled by:
        • Test-JsonNullValues: Validates all properties have non-null values
        • Test-JsonDeeperValidation: Validates property formats, ranges, and business rules

        .PARAMETER Config
        Complete supervisor configuration object from Get-SupervisorConfigurationFromJson.

        .PARAMETER MinimumServiceCount
        The minimum recommended service count for workload network. Default is 16.

        .OUTPUTS
        Boolean: $true if validation passes, $false if validation fails.

        .EXAMPLE
        $config = Get-SupervisorConfigurationFromJson -EdgeSite $EdgeSite -JsonFilePath $InfrastructureJson -NetworkSegments $NetworkSegments
        if (-not (Test-SupervisorConfiguration -Config $config)) {
            $err = "Configuration validation failed."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }

        .NOTES
        This function logs detailed information about validation failures to aid troubleshooting.
        All validation errors are logged but the function returns a simple boolean result.

        Validation Responsibilities:
        • Test-JsonNullValues: Null value checks (runs first during JSON validation)
        • Test-JsonDeeperValidation: Format, range, and business rule validation
        • Test-SupervisorConfiguration: Runtime structural validation (this function)
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSCustomObject]$Config,
        [Parameter(Mandatory = $false)] [ValidateRange(1, [Int]::MaxValue)] [Int]$MinimumServiceCount = 16
    )

    Write-LogMessage -Type DEBUG -Message "Entered Test-SupervisorConfiguration function..."

    $validationPassed = $true

    try {
        Write-LogMessage -Type DEBUG -Message "Validating supervisor configuration..."

        # Null value checks are handled by Test-JsonNullValues; this block checks structural presence only.
        if (-not $Config.ManagementNetwork) {
            Write-LogMessage -Type ERROR -Message "Validation failed: Management network configuration is missing."
            $validationPassed = $false
        } else {
            Write-LogMessage -Type DEBUG -Message "  Validating management network..."
        }

        if (-not $Config.WorkloadNetwork) {
            Write-LogMessage -Type ERROR -Message "Validation failed: Workload network configuration is missing."
            $validationPassed = $false
        } else {
            Write-LogMessage -Type DEBUG -Message "  Validating workload network..."
            # IP count minimum (2) is validated in Test-JsonDeeperValidation.
            if ($Config.WorkloadNetwork.ServiceCount -lt $MinimumServiceCount) {
                Write-LogMessage -Type WARNING -Message "    Workload network service count ($($Config.WorkloadNetwork.ServiceCount)) is low (recommended minimum $MinimumServiceCount)"
            }
        }

        if (-not $Config.ControlPlane) {
            Write-LogMessage -Type ERROR -Message "Validation failed: Control plane configuration is missing."
            $validationPassed = $false
        } else {
            Write-LogMessage -Type DEBUG -Message "  Validating control plane..."
        }

        if (-not $Config.LoadBalancer) {
            Write-LogMessage -Type ERROR -Message "Validation failed: Load balancer configuration is missing."
            $validationPassed = $false
        } else {
            Write-LogMessage -Type DEBUG -Message "  Validating load balancer..."

            # FLB IP count minimums (2) are validated in Test-JsonDeeperValidation.
            if (-not $Config.LoadBalancer.ManagementNetwork) {
                Write-LogMessage -Type ERROR -Message "    Load balancer management network is missing."
                $validationPassed = $false
            }

            if (-not $Config.LoadBalancer.VirtualServerNetwork) {
                Write-LogMessage -Type ERROR -Message "    Load balancer virtual server network is missing."
                $validationPassed = $false
            }
        }

        if ($validationPassed) {
            Write-LogMessage -Type INFO -Message "Configuration validation passed."
        } else {
            Write-LogMessage -Type ERROR -Message "Configuration validation failed - review errors above."
        }

        return $validationPassed
    } catch {
        Write-LogMessage -Type ERROR -Message "Configuration validation encountered an error: $($_.Exception.Message)"
        return $false
    }
}
function New-SupervisorControlPlaneSpec {

    <#
        .SYNOPSIS
        Creates VCF PowerCLI 9 control plane specification for supervisor deployment.

        .DESCRIPTION
        Builds the complete control plane specification using VCF PowerCLI 9 Initialize-* cmdlets.
        This function constructs the management network configuration including network backing,
        DNS/NTP services, IP management, and control plane settings required for supervisor enablement.

        Based on VCF PowerCLI 9 SDK patterns for supervisor namespace management.

        .PARAMETER ControlPlaneConfig
        Control plane configuration object containing VMCount and Size properties.

        .PARAMETER ManagementNetworkConfig
        Management network configuration object with network settings, DNS, NTP, and IP configuration.

        .PARAMETER StoragePolicyId
        Storage policy MoRef ID for control plane VMs.

        .OUTPUTS
        VCF PowerCLI 9 control plane specification object ready for supervisor enablement.

        .EXAMPLE
        $controlPlaneSpec = New-SupervisorControlPlaneSpec -ControlPlaneConfig $config.ControlPlane -ManagementNetworkConfig $config.ManagementNetwork -StoragePolicyId $policyId
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [PSCustomObject]$ControlPlaneConfig,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [PSCustomObject]$ManagementNetworkConfig,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$StoragePolicyId
    )

    Write-LogMessage -Type DEBUG -Message "Entered New-SupervisorControlPlaneSpec function..."

    try {
        Write-LogMessage -Type DEBUG -Message "   Building control plane specification..."

        $networkBacking = Initialize-VcenterNamespaceManagementSupervisorsNetworksManagementNetworkBacking `
            -Backing "NETWORK" `
            -Network $ManagementNetworkConfig.PortGroupID

        $dns = Initialize-VcenterNamespaceManagementNetworksServiceDNS `
            -Servers $ManagementNetworkConfig.DNSServers `
            -SearchDomains $ManagementNetworkConfig.SearchDomains
        $ntp = Initialize-VcenterNamespaceManagementNetworksServiceNTP `
            -Servers $ManagementNetworkConfig.NTPServers
        $services = Initialize-VcenterNamespaceManagementNetworksServices `
            -Dns $dns `
            -Ntp $ntp

        $ipRange = Initialize-VcenterNamespaceManagementNetworksIPRange `
            -Address $ManagementNetworkConfig.StartingIP `
            -Count $ManagementNetworkConfig.IPCount
        $ipAssignment = Initialize-VcenterNamespaceManagementNetworksIPAssignment `
            -Assignee "NODE" `
            -Ranges $ipRange
        $ipManagement = Initialize-VcenterNamespaceManagementNetworksIPManagement `
            -DhcpEnabled $ManagementNetworkConfig.DHCPEnabled `
            -GatewayAddress $ManagementNetworkConfig.Gateway `
            -IpAssignments $ipAssignment
        $managementNetwork = Initialize-VcenterNamespaceManagementSupervisorsNetworksManagementNetwork `
            -Network $ManagementNetworkConfig.PortGroupID `
            -Backing $networkBacking `
            -Services $services `
            -IpManagement $ipManagement

        $controlPlane = Initialize-VcenterNamespaceManagementSupervisorsControlPlane `
            -Network $managementNetwork `
            -LoginBanner "" `
            -Size $ControlPlaneConfig.Size `
            -StoragePolicy $StoragePolicyId `
            -Count $ControlPlaneConfig.VMCount

        Write-LogMessage -Type DEBUG -Message "   Control plane specification built successfully: Size=$($ControlPlaneConfig.Size), VMs=$($ControlPlaneConfig.VMCount)"
        return $controlPlane
    } catch [VcfDeploymentException] {
        throw  # already logged and typed — propagate without re-wrapping
    } catch {
        $err = "Failed to build control plane specification: $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
}
function New-SupervisorWorkloadSpec {

    <#
        .SYNOPSIS
        Creates VCF PowerCLI 9 workload specification for supervisor deployment.

        .DESCRIPTION
        Builds the complete workload network specification using VCF PowerCLI 9 Initialize-* cmdlets.
        This function constructs the workload network configuration including DNS/NTP services,
        IP management for both nodes and services, and vSphere network settings.

        Based on VCF PowerCLI 9 SDK patterns for supervisor workload configuration.

        .PARAMETER WorkloadNetworkConfig
        Workload network configuration object with network settings, DNS, NTP, and IP configuration.

        .OUTPUTS
        VCF PowerCLI 9 workload network specification object ready for supervisor enablement.

        .EXAMPLE
        $workloadSpec = New-SupervisorWorkloadSpec -WorkloadNetworkConfig $config.WorkloadNetwork
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [PSCustomObject]$WorkloadNetworkConfig
    )

    Write-LogMessage -Type DEBUG -Message "Entered New-SupervisorWorkloadSpec function..."

    try {
        Write-LogMessage -Type DEBUG -Message "Building workload network specification..."

        $dns = Initialize-VcenterNamespaceManagementNetworksServiceDNS `
            -Servers $WorkloadNetworkConfig.DNSServers `
            -SearchDomains $WorkloadNetworkConfig.SearchDomains
        $ntp = Initialize-VcenterNamespaceManagementNetworksServiceNTP `
            -Servers $WorkloadNetworkConfig.NTPServers
        $services = Initialize-VcenterNamespaceManagementNetworksServices `
            -Dns $dns `
            -Ntp $ntp

        $nodeIpRange = Initialize-VcenterNamespaceManagementNetworksIPRange `
            -Address $WorkloadNetworkConfig.StartingIP `
            -Count $WorkloadNetworkConfig.IPCount
        $serviceIpRange = Initialize-VcenterNamespaceManagementNetworksIPRange `
            -Address $WorkloadNetworkConfig.ServiceStartIP `
            -Count $WorkloadNetworkConfig.ServiceCount
        $serviceIpAssignment = Initialize-VcenterNamespaceManagementNetworksIPAssignment `
            -Assignee "SERVICE" `
            -Ranges $serviceIpRange
        $nodeIpAssignment = Initialize-VcenterNamespaceManagementNetworksIPAssignment `
            -Assignee "NODE" `
            -Ranges $nodeIpRange
        $ipManagement = Initialize-VcenterNamespaceManagementNetworksIPManagement `
            -DhcpEnabled $WorkloadNetworkConfig.DHCPEnabled `
            -GatewayAddress $WorkloadNetworkConfig.Gateway `
            -IpAssignments $serviceIpAssignment, $nodeIpAssignment
        $vsphereNetwork = Initialize-VcenterNamespaceManagementSupervisorsNetworksWorkloadVSphereNetwork `
            -Dvpg $WorkloadNetworkConfig.PortGroupID
        $workloadNetwork = Initialize-VcenterNamespaceManagementSupervisorsNetworksWorkloadNetwork `
            -Network $WorkloadNetworkConfig.Name `
            -NetworkType "VSPHERE" `
            -Vsphere $vsphereNetwork `
            -Services $services `
            -IpManagement $ipManagement

        Write-LogMessage -Type DEBUG -Message "   Workload network specification built successfully: $($WorkloadNetworkConfig.Name)"
        return $workloadNetwork
    } catch [VcfDeploymentException] {
        throw  # already logged and typed — propagate without re-wrapping
    } catch {
        $err = "Failed to build workload network specification: $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
}
function New-FlbMgmtNetworkInterface {

    <#
    .SYNOPSIS
        Builds the Foundation Load Balancer management network interface specification.
    .DESCRIPTION
        Assembles the management network IP range, IP config, DVPG network, and network interface
        objects required by Initialize-VcenterNamespaceManagementNetworksEdgesFoundationNetworkInterface.
    .PARAMETER LoadBalancerConfig
        Load balancer configuration object from Get-SupervisorConfigurationFromJson.
    .PARAMETER MgmtPersonaArray
        Management network persona array for the interface.
    .EXAMPLE
        $iface = New-FlbMgmtNetworkInterface -LoadBalancerConfig $config.LoadBalancer -MgmtPersonaArray @("MANAGEMENT")
    .NOTES
        Called by New-SupervisorLoadBalancerSpec.
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [PSCustomObject]$LoadBalancerConfig,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object[]]$MgmtPersonaArray
    )

    $mgmtIpRange = Initialize-VcenterNamespaceManagementNetworksEdgesFoundationFoundationIPRange `
        -Address $LoadBalancerConfig.ManagementNetwork.StartingIP `
        -Count $LoadBalancerConfig.ManagementNetwork.IPCount

    $mgmtIpConfig = Initialize-VcenterNamespaceManagementNetworksEdgesFoundationIPConfig `
        -IpRanges $mgmtIpRange `
        -Gateway $LoadBalancerConfig.ManagementNetwork.Gateway

    $mgmtDvpgNetwork = Initialize-VcenterNamespaceManagementNetworksEdgesFoundationDistributedPortGroupNetwork `
        -Name $LoadBalancerConfig.ManagementNetwork.Name `
        -Network $LoadBalancerConfig.ManagementNetwork.PortGroupID `
        -Ipam $LoadBalancerConfig.ManagementNetwork.IPAssignmentMode `
        -IpConfig $mgmtIpConfig

    $mgmtNetwork = Initialize-VcenterNamespaceManagementNetworksEdgesFoundationNetwork `
        -NetworkType $LoadBalancerConfig.ManagementNetwork.Type `
        -DvpgNetwork $mgmtDvpgNetwork

    return Initialize-VcenterNamespaceManagementNetworksEdgesFoundationNetworkInterface `
        -Personas $MgmtPersonaArray `
        -Network $mgmtNetwork
}
function New-FlbVsNetworkInterface {

    <#
    .SYNOPSIS
        Builds the Foundation Load Balancer virtual-server network interface specification.
    .DESCRIPTION
        Assembles the virtual-server network IP range, IP config, DVPG network, and network interface
        objects required by Initialize-VcenterNamespaceManagementNetworksEdgesFoundationNetworkInterface.
    .PARAMETER LoadBalancerConfig
        Load balancer configuration object from Get-SupervisorConfigurationFromJson.
    .PARAMETER WorkloadPersonaArray
        Workload network persona array for the interface.
    .EXAMPLE
        $iface = New-FlbVsNetworkInterface -LoadBalancerConfig $config.LoadBalancer -WorkloadPersonaArray @("FRONTEND","WORKLOAD")
    .NOTES
        Called by New-SupervisorLoadBalancerSpec.
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [PSCustomObject]$LoadBalancerConfig,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object[]]$WorkloadPersonaArray
    )

    $vsIpRange = Initialize-VcenterNamespaceManagementNetworksEdgesFoundationFoundationIPRange `
        -Address $LoadBalancerConfig.VirtualServerNetwork.StartingIP `
        -Count $LoadBalancerConfig.VirtualServerNetwork.IPCount

    $vsIpConfig = Initialize-VcenterNamespaceManagementNetworksEdgesFoundationIPConfig `
        -IpRanges $vsIpRange `
        -Gateway $LoadBalancerConfig.VirtualServerNetwork.Gateway

    $vsDvpgNetwork = Initialize-VcenterNamespaceManagementNetworksEdgesFoundationDistributedPortGroupNetwork `
        -Name $LoadBalancerConfig.VirtualServerNetwork.Name `
        -Network $LoadBalancerConfig.VirtualServerNetwork.PortGroupID `
        -Ipam $LoadBalancerConfig.VirtualServerNetwork.IPAssignmentMode `
        -IpConfig $vsIpConfig

    $vsNetwork = Initialize-VcenterNamespaceManagementNetworksEdgesFoundationNetwork `
        -NetworkType $LoadBalancerConfig.VirtualServerNetwork.Type `
        -DvpgNetwork $vsDvpgNetwork

    return Initialize-VcenterNamespaceManagementNetworksEdgesFoundationNetworkInterface `
        -Personas $WorkloadPersonaArray `
        -Network $vsNetwork
}
function New-SupervisorLoadBalancerSpec {

    <#
        .SYNOPSIS
        Creates VCF PowerCLI 9 Foundation Load Balancer specification for supervisor deployment.

        .DESCRIPTION
        Builds the complete Foundation Load Balancer (FLB) specification using VCF PowerCLI 9 Initialize-* cmdlets.
        This function constructs the FLB configuration including deployment target, management and virtual server
        network interfaces, network services (DNS/NTP), and load balancer address ranges.

        Based on VCF PowerCLI 9 SDK patterns for supervisor edge configuration.

        .PARAMETER LoadBalancerConfig
        Foundation Load Balancer configuration object with FLB settings and network configurations.

        .PARAMETER StoragePolicyId
        Storage policy MoRef ID for FLB deployment.

        .PARAMETER FlbMgmtNetworkPersona
        Management network persona (default: "MANAGEMENT"; API expects uppercase).

        .PARAMETER FlbWorkloadNetworkPersona
        Workload network personas (default: @("FRONTEND","WORKLOAD")).

        .OUTPUTS
        VCF PowerCLI 9 edge specification object ready for supervisor enablement.

        .EXAMPLE
        $flbSpec = New-SupervisorLoadBalancerSpec -LoadBalancerConfig $config.LoadBalancer -StoragePolicyId $policyId
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$FlbMgmtNetworkPersona = "MANAGEMENT",
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [Object[]]$FlbWorkloadNetworkPersona = @("FRONTEND", "WORKLOAD"),
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [PSCustomObject]$LoadBalancerConfig,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$StoragePolicyId
    )

    Write-LogMessage -Type DEBUG -Message "Entered New-SupervisorLoadBalancerSpec function..."

    try {
        # Use personas from config when present (gathered by Get-SupervisorConfigurationFromJson); otherwise use parameters.
        $mgmtPersona = if ($LoadBalancerConfig.ManagementNetwork.PSObject.Properties.Name -contains "Persona" -and $null -ne $LoadBalancerConfig.ManagementNetwork.Persona) {
            $LoadBalancerConfig.ManagementNetwork.Persona
        } else {
            $FlbMgmtNetworkPersona
        }
        $workloadPersona = if ($LoadBalancerConfig.VirtualServerNetwork.PSObject.Properties.Name -contains "Persona" -and $null -ne $LoadBalancerConfig.VirtualServerNetwork.Persona) {
            $LoadBalancerConfig.VirtualServerNetwork.Persona
        } else {
            $FlbWorkloadNetworkPersona
        }
        # Ensure both are arrays for -Personas (API expects array).
        $mgmtPersonaArray = @($mgmtPersona)
        $workloadPersonaArray = @($workloadPersona)
        Write-LogMessage -Type DEBUG -Message "Building Foundation Load Balancer specification..."
        Write-LogMessage -Type DEBUG -Message "FLB network personas: management=($($mgmtPersonaArray -join ", ")), workload=($($workloadPersonaArray -join ", "))."

        $deploymentTarget = Initialize-VcenterNamespaceManagementNetworksEdgesFoundationDeploymentTarget `
            -StoragePolicy $StoragePolicyId `
            -DeploymentSize $LoadBalancerConfig.Size `
            -Availability $LoadBalancerConfig.Availability

        $mgmtNetworkInterface = New-FlbMgmtNetworkInterface -LoadBalancerConfig $LoadBalancerConfig -MgmtPersonaArray $mgmtPersonaArray
        $vsNetworkInterface = New-FlbVsNetworkInterface -LoadBalancerConfig $LoadBalancerConfig -WorkloadPersonaArray $workloadPersonaArray

        $flbDns = Initialize-VcenterNamespaceManagementNetworksEdgesFoundationDNS `
            -Servers $LoadBalancerConfig.DNSServers `
            -SearchDomains $LoadBalancerConfig.SearchDomains

        $flbNtp = Initialize-VcenterNamespaceManagementNetworksEdgesFoundationNTP `
            -Servers $LoadBalancerConfig.NTPServers

        $networkServices = Initialize-VcenterNamespaceManagementNetworksEdgesFoundationNetworkServices `
            -Dns $flbDns `
            -Ntp $flbNtp

        $foundationConfig = Initialize-VcenterNamespaceManagementNetworksEdgesVsphereFoundationConfig `
            -DeploymentTarget $deploymentTarget `
            -Interfaces $mgmtNetworkInterface, $vsNetworkInterface `
            -NetworkServices $networkServices

        $vipRange = Initialize-VcenterNamespaceManagementNetworksIPRange `
            -Address $LoadBalancerConfig.VipStartIP `
            -Count $LoadBalancerConfig.VipIPCount

        $edge = Initialize-VcenterNamespaceManagementNetworksEdgesEdge `
            -Id $LoadBalancerConfig.Name `
            -LoadBalancerAddressRanges $vipRange `
            -Foundation $foundationConfig `
            -Provider $LoadBalancerConfig.Provider

        Write-LogMessage -Type DEBUG -Message "Foundation Load Balancer specification built successfully: $($LoadBalancerConfig.Name)"
        return $edge
    } catch [VcfDeploymentException] {
        throw  # already logged and typed — propagate without re-wrapping
    } catch {
        $err = "Failed to build Foundation Load Balancer specification: $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
}
function Resolve-SupervisorCreationError {

    <#
    .SYNOPSIS
        Handles errors from the supervisor creation API call.
    .DESCRIPTION
        Interprets the raw error message from Invoke-EnableOnComputeClusterClusterSupervisors. When the
        cluster already has a supervisor, retrieves and returns the existing supervisor ID. For unexpected
        errors, logs context-specific guidance and returns a failure result.
    .PARAMETER ClusterName
        Cluster display name, used in log messages.
    .PARAMETER ErrorMessage
        Raw exception message from the supervisor creation cmdlet.
    .PARAMETER InsecureTls
        Bypasses SSL certificate validation when looking up the existing supervisor ID.
    .PARAMETER SupervisorName
        Supervisor name used for the idempotency lookup via Get-SupervisorId.
    .PARAMETER VcenterCredential
        Optional PSCredential; falls back to $Script:VcenterCredential when not supplied.
    .EXAMPLE
        $result = Resolve-SupervisorCreationError -ClusterName "cl01" -ErrorMessage $_.Exception.Message -SupervisorName "sv-01"
    .OUTPUTS
        PSCustomObject: Success, SupervisorId, IsExisting, ErrorMessage.
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ErrorMessage,
        [Parameter(Mandatory = $false)] [Switch]$InsecureTls,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorName,
        [Parameter(Mandatory = $false)] [PSCredential]$VcenterCredential
    )

    Write-LogMessage -Type DEBUG -Message "Supervisor creation API full error: $ErrorMessage"

    if ($ErrorMessage -match "already has Workloads enabled") {
        Write-LogMessage -Type INFO -Message "Cluster `"$ClusterName`" already has supervisor enabled. Retrieving existing supervisor ID..."
        $effectiveCredential = if ($null -ne $Script:VcenterCredential) { $Script:VcenterCredential } else { $VcenterCredential }
        $getSupervisorParams = @{
            supervisorName    = $SupervisorName
            VcenterUser       = $Script:VCenterUser
            VcenterCredential = $effectiveCredential
            silence           = $true
        }
        if ($InsecureTls) { $getSupervisorParams.insecureTls = $true }
        $existingSupervisorId = Get-SupervisorId @getSupervisorParams
        if ($existingSupervisorId) {
            Write-LogMessage -Type INFO -Message "Found existing supervisor with ID: $existingSupervisorId"
            return [PSCustomObject]@{ Success = $true; SupervisorId = $existingSupervisorId; IsExisting = $true; ErrorMessage = $null }
        }
        Write-LogMessage -Type ERROR -Message "Failed to retrieve existing supervisor ID for `"$SupervisorName`""
        return [PSCustomObject]@{ Success = $false; SupervisorId = $null; IsExisting = $false; ErrorMessage = "Failed to retrieve existing supervisor ID for `"$SupervisorName`"" }
    }

    $cleanErrorMessage = Get-CleanErrorMessage -ErrorMessage $ErrorMessage
    switch -Regex ($ErrorMessage) {
        "500.*Internal server error" {
            Write-LogMessage -Type ERROR -Message "Failed to create supervisor on cluster `"$ClusterName`": vCenter API internal server error."
            Write-LogMessage -Type ERROR -Message "Error details: $cleanErrorMessage."
        }
        "Foundation Load Balancer.*persona|persona.*Foundation" {
            Write-LogMessage -Type ERROR -Message "Failed to create supervisor on cluster `"$ClusterName`": $cleanErrorMessage"
            Write-LogMessage -Type ERROR -Message "FLB network interface persona error: the API expects uppercase persona values (e.g. MANAGEMENT for mgmt, FRONTEND and WORKLOAD for workload). Check VCF PowerCLI/vCenter docs for allowed values; ensure supervisor/infrastructure JSON FLB network names and port group IDs match existing DPGs."
        }
        default {
            Write-LogMessage -Type ERROR -Message "Failed to create supervisor on cluster `"$ClusterName`": $cleanErrorMessage"
        }
    }
    return [PSCustomObject]@{ Success = $false; SupervisorId = $null; IsExisting = $false; ErrorMessage = $ErrorMessage }
}
function Invoke-SupervisorCreation {

    <#
        .SYNOPSIS
        Wraps the VCF PowerCLI 9 supervisor creation cmdlet with JSON serialization and idempotent handling.

        .DESCRIPTION
        Serializes SupervisorSpec to a temp JSON file, calls
        Invoke-EnableOnComputeClusterClusterSupervisors, and cleans up the temp file in all code paths.
        When the supervisor already exists, falls back to Get-SupervisorId and returns IsExisting=$true.

        .PARAMETER ClusterId
        vSphere cluster MoRef (e.g., "domain-c8").

        .PARAMETER ClusterName
        Cluster display name for logging.

        .PARAMETER SupervisorName
        Supervisor name — used for existing supervisor lookup on the idempotent path.

        .PARAMETER SupervisorSpec
        Complete spec object from Initialize-VcenterNamespaceManagementSupervisorsEnableOnComputeClusterSpec.

        .PARAMETER VcenterCredential
        PSCredential for REST when resolving an existing supervisor ID.
        Defaults to $Script:VcenterCredential when not supplied.

        .PARAMETER InsecureTls
        Bypasses SSL certificate validation for REST calls on the idempotent path.

        .EXAMPLE
        $creationResult = Invoke-SupervisorCreation -ClusterId "domain-c8" -ClusterName "cl01" -SupervisorName "sv-01" -SupervisorSpec $spec -VcenterCredential $cred
        if ($creationResult.Success) { $supervisorId = $creationResult.SupervisorId }

        .OUTPUTS
        PSCustomObject: Success (Bool), SupervisorId (String|null), IsExisting (Bool), ErrorMessage (String).
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterId,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [Switch]$InsecureTls,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSCustomObject]$SupervisorSpec,
        [Parameter(Mandatory = $false)] [PSCredential]$VcenterCredential
    )

    Write-LogMessage -Type DEBUG -Message "Entered Invoke-SupervisorCreation function..."
    $tempJsonPath = $null

    try {
        Write-LogMessage -Type DEBUG -Message "   Invoking supervisor creation on cluster `"$ClusterName`" (ID: $ClusterId)..."

        # Create temporary JSON file with timestamp to avoid collisions.
        $timestamp = Get-Date -Format 'yyyyMMddHHmmss'
        $tempPath = [System.IO.Path]::GetTempPath()
        $tempJsonPath = Join-Path -Path $tempPath -ChildPath "supervisor_spec_${timestamp}.json"

        Write-LogMessage -Type DEBUG -Message "Serializing supervisor specification to JSON..."

        # ToJson() is used here because VCF PowerCLI 9 SDK objects cannot be serialized
        # directly; writing to a temp file and reading back gives a plain PSCustomObject.
        $SupervisorSpec.ToJson() | Set-Content -Path $tempJsonPath -Encoding UTF8

        # Read back as a string so Convert-CountToInt can mutate it before re-serializing.
        $jsonContent = Get-Content -Path $tempJsonPath -Raw -Encoding UTF8
        $obj = $jsonContent | ConvertFrom-Json

        # VCF API requires integer count properties; PowerShell may serialize them as strings.
        Convert-CountToInt $obj

        $jsonPayload = $obj | ConvertTo-Json -Depth 10

        # Invoke the VCF PowerCLI 9 cmdlet to enable supervisor on cluster.
        $supervisorId = Invoke-EnableOnComputeClusterClusterSupervisors `
            -Cluster $ClusterId `
            -vcenterNamespaceManagementSupervisorsEnableOnComputeClusterSpec $jsonPayload `
            -Confirm:$false `
            -ErrorAction Stop

        Write-LogMessage -Type DEBUG -Message "Successfully initiated supervisor creation. Supervisor ID: $supervisorId"

        return [PSCustomObject]@{
            Success = $true
            SupervisorId = $supervisorId
            IsExisting = $false
            ErrorMessage = $null
        }
    } catch {
        return Resolve-SupervisorCreationError `
            -ClusterName $ClusterName `
            -ErrorMessage $_.Exception.Message `
            -InsecureTls:$InsecureTls.IsPresent `
            -SupervisorName $SupervisorName `
            -VcenterCredential $VcenterCredential
    }
    finally {
        # Cleanup temporary JSON file in all code paths (success, failure, existing).
        if ($tempJsonPath -and (Test-Path $tempJsonPath)) {
            Write-LogMessage -Type DEBUG -Message "Cleaning up temporary JSON file: $tempJsonPath."
            Remove-Item -Path $tempJsonPath -Force -ErrorAction SilentlyContinue
        }
    }
}
function Get-VlcmDesiredBaseImageVersionFromSpec {

    <#
        .SYNOPSIS
        Extracts the base image version string from a vLCM software spec object or API result.

        .DESCRIPTION
        Used when comparing the cluster desired image to host ESX versions. Accepts a software
        spec object (e.g. BaseImage.Version), an API result that may contain .Spec or .Desired,
        or a string in "BaseImage: Version: <value>" format. Returns the version string or $null.

        .PARAMETER SoftwareSpecOrResult
        A software spec object, API get result, or string from vLCM.

        .OUTPUTS
        System.String. The base image version or $null if not found.

        .EXAMPLE
        $version = Get-VlcmDesiredBaseImageVersionFromSpec -SoftwareSpecOrResult $clusterSoftware

        .NOTES
        Caller can use the returned version with [Version]::TryParse for comparison. Used by
        Invoke-VlcmClusterComplianceAndRemediate when parsing spec from repository records; the
        cluster's desired image in VCF PowerCLI 9 is read directly from Get-Cluster .BaseImage.Version.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [AllowNull()] [PSObject]$SoftwareSpecOrResult
    )

    if ($null -eq $SoftwareSpecOrResult) {
        return $null
    }

    # Resolve the inner spec: API results may wrap it in .Spec, .Desired, or .SoftwareSpec.
    $spec = $null
    if ($SoftwareSpecOrResult.PSObject.Properties['Spec'] -and $null -ne $SoftwareSpecOrResult.Spec) {
        $spec = $SoftwareSpecOrResult.Spec
    }
    elseif ($SoftwareSpecOrResult.PSObject.Properties['Desired'] -and $null -ne $SoftwareSpecOrResult.Desired) {
        $spec = $SoftwareSpecOrResult.Desired
    }
    elseif ($SoftwareSpecOrResult.PSObject.Properties['SoftwareSpec'] -and $null -ne $SoftwareSpecOrResult.SoftwareSpec) {
        $spec = $SoftwareSpecOrResult.SoftwareSpec
    }
    else {
        $spec = $SoftwareSpecOrResult
    }

    if ($null -eq $spec) {
        return $null
    }

    # Prefer BaseImage.Version when the spec is an object.
    if ($spec.PSObject.Properties['BaseImage'] -and $null -ne $spec.BaseImage) {
        $baseImage = $spec.BaseImage
        if ($baseImage.PSObject.Properties['Version'] -and -not [String]::IsNullOrWhiteSpace($baseImage.Version)) {
            return [String]$baseImage.Version
        }
    }

    # Fallback: parse "BaseImage: Version: <value>" from string representation.
    $specStr = $spec.ToString()
    if (-not [String]::IsNullOrWhiteSpace($specStr) -and $specStr -match 'BaseImage:\s*Version:\s*([^,\s]+)') {
        return $Matches[1].Trim()
    }

    return $null
}
function Get-VlcmComplianceItemInfo {

    <#
        .SYNOPSIS
        Resolves a display name and VMHost reference from a vLCM compliance item.

        .DESCRIPTION
        vLCM compliance result items may expose the host reference under different property names
        depending on the PowerCLI version and vCenter API level (Host, VMHost, Entity, Name, or HostName).
        This function encapsulates the fallback detection so callers do not repeat the same switch block.
        Returns a PSCustomObject with DisplayName (string) and VMHost (object or $null).

        .PARAMETER Item
        A single compliance result item from Test-LcmClusterCompliance output.

        .PARAMETER FallbackIndex
        Integer used as the fallback label ("Host N") when no property yields a usable name.

        .OUTPUTS
        [PSCustomObject] with DisplayName ([String]) and VMHost ([Object], may be $null).

        .EXAMPLE
        $info = Get-VlcmComplianceItemInfo -Item $complianceItem -FallbackIndex 1
        Write-LogMessage -Type INFO -Message "Host: $($info.DisplayName)"
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateRange(1, [Int]::MaxValue)] [Int]$FallbackIndex,
        [Parameter(Mandatory = $true)] [AllowNull()] [Object]$Item
    )

    $displayName = $null
    $vmHost = $null

    if ($null -ne $Item) {
        if ($Item.PSObject.Properties['Host'] -and $null -ne $Item.Host -and -not [String]::IsNullOrWhiteSpace($Item.Host.Name)) {
            $displayName = $Item.Host.Name
        } elseif ($Item.PSObject.Properties['VMHost'] -and $null -ne $Item.VMHost -and -not [String]::IsNullOrWhiteSpace($Item.VMHost.Name)) {
            $displayName = $Item.VMHost.Name
        } elseif ($Item.PSObject.Properties['Entity'] -and $null -ne $Item.Entity -and -not [String]::IsNullOrWhiteSpace($Item.Entity.Name)) {
            $displayName = $Item.Entity.Name
        } elseif ($Item.PSObject.Properties['Name'] -and -not [String]::IsNullOrWhiteSpace($Item.Name)) {
            $displayName = $Item.Name
        } elseif ($Item.PSObject.Properties['HostName'] -and -not [String]::IsNullOrWhiteSpace($Item.HostName)) {
            $displayName = $Item.HostName
        }

        if ([String]::IsNullOrWhiteSpace($displayName) -or $displayName -match '^\s*Vmware\.') {
            $displayName = "Host $FallbackIndex"
        }
        if ($Item.PSObject.Properties['Host'] -and $null -ne $Item.Host) { $vmHost = $Item.Host }
        elseif ($Item.PSObject.Properties['VMHost'] -and $null -ne $Item.VMHost) { $vmHost = $Item.VMHost }
    } else {
        $displayName = "Host $FallbackIndex"
    }

    return [PSCustomObject]@{ DisplayName = $displayName; VMHost = $vmHost }
}
function Get-VlcmNonCompliantHostNames {

    <#
        .SYNOPSIS
        Extracts display names from a vLCM compliance non-compliant host array.

        .DESCRIPTION
        Iterates over a NonCompliantHosts array from a Test-LcmClusterCompliance result and returns
        the display name for each item that has a non-empty name. Calls Get-VlcmComplianceItemInfo
        to abstract per-item name resolution.

        .PARAMETER NonCompliantHosts
        The array of non-compliant host items from Test-LcmClusterCompliance.

        .OUTPUTS
        [String[]] Display names of non-compliant hosts (empty array if none resolvable).

        .EXAMPLE
        $hostNames = Get-VlcmNonCompliantHostNames -NonCompliantHosts @($complianceResult.NonCompliantHosts)
        Write-LogMessage -Type INFO -Message "Non-compliant hosts: $($hostNames -join ', ')"
    #>

    [CmdletBinding()]
    [OutputType([String[]])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [AllowEmptyCollection()] [Object[]]$NonCompliantHosts
    )

    $names = [System.Collections.Generic.List[String]]::new()
    $index = 0
    foreach ($item in $NonCompliantHosts) {
        $index++
        $itemInfo = Get-VlcmComplianceItemInfo -Item $item -FallbackIndex $index
        if (-not [String]::IsNullOrWhiteSpace($itemInfo.DisplayName)) {
            $names.Add($itemInfo.DisplayName)
        }
    }
    return $names.ToArray()
}
function Write-VlcmVersionMismatchWarnings {

    <#
        .SYNOPSIS
        Logs a warning for each non-compliant host whose ESX version differs from the vLCM base image.

        .DESCRIPTION
        Iterates over NonCompliantHosts, resolves each host's current ESX version and build number,
        builds a full version string (e.g. 9.0.0.0.12345678), and compares it to the cluster's vLCM
        base image version. Emits a WARNING log indicating whether each divergence is an upgrade,
        downgrade, or version mismatch. Skips hosts where the version cannot be resolved.

        .PARAMETER BaseImageVersion
        The vLCM desired base image version string (e.g. "9.0.0.0.12345678") from the cluster object.

        .PARAMETER ClusterName
        The name of the vSphere cluster. Used in log messages.

        .PARAMETER NonCompliantHosts
        The array of non-compliant host items from Test-LcmClusterCompliance.

        .EXAMPLE
        Write-VlcmVersionMismatchWarnings -BaseImageVersion "9.0.0.0.12345678" -ClusterName "cl0" -NonCompliantHosts $nonCompliantHosts
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$BaseImageVersion,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [AllowEmptyCollection()] [Object[]]$NonCompliantHosts
    )

    $index = 0
    foreach ($item in $NonCompliantHosts) {
        $index++
        $itemInfo = Get-VlcmComplianceItemInfo -Item $item -FallbackIndex $index
        $displayName = $itemInfo.DisplayName
        $vmHost = $itemInfo.VMHost

        if ([String]::IsNullOrWhiteSpace($displayName)) { continue }
        if (-not $vmHost) {
            $vmHost = Get-VMHost -Name $displayName -Server $Script:vCenterName -ErrorAction SilentlyContinue
        }
        if (-not $vmHost) { continue }

        # Resolve host ESX version and build for full comparison to vLCM image (e.g. 9.0.0.0.12345678).
        $hostVersion = $null
        $hostBuild = $null
        if ($vmHost.PSObject.Properties['Version'] -and -not [String]::IsNullOrWhiteSpace($vmHost.Version)) {
            $hostVersion = [String]$vmHost.Version
        }
        if ([String]::IsNullOrWhiteSpace($hostVersion) -and $vmHost.ExtensionData -and $vmHost.ExtensionData.Config -and $vmHost.ExtensionData.Config.Product -and -not [String]::IsNullOrWhiteSpace($vmHost.ExtensionData.Config.Product.Version)) {
            $hostVersion = [String]$vmHost.ExtensionData.Config.Product.Version
        }
        if ($vmHost.PSObject.Properties['Build'] -and -not [String]::IsNullOrWhiteSpace($vmHost.Build)) {
            $hostBuild = [String]$vmHost.Build
        }
        if ([String]::IsNullOrWhiteSpace($hostBuild) -and $vmHost.ExtensionData -and $vmHost.ExtensionData.Config -and $vmHost.ExtensionData.Config.Product -and -not [String]::IsNullOrWhiteSpace($vmHost.ExtensionData.Config.Product.Build)) {
            $hostBuild = [String]$vmHost.ExtensionData.Config.Product.Build
        }

        if ([String]::IsNullOrWhiteSpace($hostVersion)) { continue }

        # Build full host version string (e.g. 9.0.0.0.12345678) to match vLCM base image format.
        # Use Version + ".0." + Build when Version has 3 components.
        $fullHostVersion = $hostVersion
        $hostParts = $hostVersion.Trim() -split '\.'
        if ($hostParts.Count -eq 3 -and -not [String]::IsNullOrWhiteSpace($hostBuild)) {
            $fullHostVersion = "$hostVersion.0.$hostBuild"
        }

        if ($fullHostVersion -eq $BaseImageVersion) { continue }
        if ($hostVersion -eq $BaseImageVersion) { continue }

        $direction = "version mismatch"
        $imageParts = $BaseImageVersion.Trim() -split '\.'
        $normalizedImage = if ($imageParts.Count -ge 3) { ($imageParts[0..2] -join '.') } else { $BaseImageVersion }
        $normalizedHost = if ($hostParts.Count -ge 3) { ($hostParts[0..2] -join '.') } else { $hostVersion }
        $baseVer = $null
        $hostVer = $null
        if ([Version]::TryParse($normalizedImage, [Ref]$baseVer) -and [Version]::TryParse($normalizedHost, [Ref]$hostVer)) {
            if ($baseVer -gt $hostVer) { $direction = "upgrade" }
            elseif ($baseVer -lt $hostVer) { $direction = "downgrade" }
        }

        Write-LogMessage -Type WARNING -Message "vLCM image base version differs from host ESX version. Host: `"$displayName`". Current ESX version: $fullHostVersion. vLCM image base version: $BaseImageVersion. This is an $direction."
    }
}
function Test-VlcmPostRemediationCompliance {

    <#
        .SYNOPSIS
        Checks vLCM cluster compliance after remediation and logs warnings if issues remain.

        .DESCRIPTION
        Runs Test-LcmClusterCompliance on the cluster after remediation. Logs a WARNING if the
        cluster is still not compliant, and an INFO message if a host reboot is required to
        complete the remediation. Silently continues if the compliance re-check fails.

        .PARAMETER ClusterName
        The name of the vSphere cluster. Used in log messages.

        .PARAMETER ClusterObject
        The cluster object returned by Get-Cluster.

        .EXAMPLE
        Test-VlcmPostRemediationCompliance -ClusterName "cl0" -ClusterObject $clusterObject
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$ClusterObject
    )

    $postRemediationCompliance = $null
    try {
        $postRemediationCompliance = $ClusterObject | Test-LcmClusterCompliance -ErrorAction SilentlyContinue
    } catch {
        Write-LogMessage -Type DEBUG -Message "Could not re-check vLCM compliance after remediation: $($_.Exception.GetType().FullName): $($_.Exception.Message)."
    }

    if (-not $postRemediationCompliance) { return }

    $stillNonCompliant = $postRemediationCompliance.PSObject.Properties['Status'] -and $postRemediationCompliance.Status -ne 'Compliant'
    if ($stillNonCompliant) {
        Write-LogMessage -Type WARNING -Message "Cluster `"$ClusterName`" is still not compliant to the vLCM image after remediation (Status: $($postRemediationCompliance.Status)). Check vCenter Lifecycle Manager and reboot hosts if required."
    }

    $rebootRequired = $false
    if ($postRemediationCompliance.PSObject.Properties['Impact'] -and -not [String]::IsNullOrWhiteSpace($postRemediationCompliance.Impact) -and $postRemediationCompliance.Impact -match 'Reboot|reboot') {
        $rebootRequired = $true
    }
    if ($postRemediationCompliance.PSObject.Properties['RebootRequired'] -and $postRemediationCompliance.RebootRequired -eq $true) {
        $rebootRequired = $true
    }
    if ($rebootRequired) {
        Write-LogMessage -Type INFO -Message "A reboot is required on one or more hosts in cluster `"$ClusterName`" to complete vLCM remediation. Check vCenter Lifecycle Manager (cluster image compliance) for host status and reboot when appropriate."
    }
}
function Invoke-VlcmRemediationFailureResponse {

    <#
        .SYNOPSIS
        Handles a vLCM remediation failure: logs the error and either auto-accepts or prompts the user.

        .DESCRIPTION
        Logs the remediation failure details, extracts a summary from the error message, and either
        auto-proceeds (when AcceptBadCheckResults is set) or prompts the user to proceed or abort.
        Throws VcfDeploymentException when the user responds N. Returns when AcceptBadCheckResults
        is set or when the user responds Y.

        .PARAMETER AcceptBadCheckResults
        When set, automatically proceeds without prompting despite the remediation failure.

        .PARAMETER ClusterName
        The name of the vSphere cluster. Used in log messages and the exception message.

        .PARAMETER RemediationError
        The error message string from the caught exception during Set-Cluster remediation.

        .EXAMPLE
        Invoke-VlcmRemediationFailureResponse -ClusterName "cl0" -RemediationError $_.Exception.Message -AcceptBadCheckResults:$AcceptBadCheckResults.IsPresent
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [Switch]$AcceptBadCheckResults,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$RemediationError
    )

    $failedHost = $null
    if ($RemediationError -match "Health Check for '([^']+)' failed") {
        $failedHost = $Matches[1]
    }
    if ($failedHost) {
        Write-LogMessage -Type ERROR -Message "vLCM remediation failed for cluster `"$ClusterName`": Health Check for '$failedHost' failed. Check that host in vCenter (Lifecycle Manager / cluster image compliance) and resolve pre-remediation issues, then re-run or proceed at your own risk."
    } else {
        Write-LogMessage -Type ERROR -Message "vLCM remediation failed for cluster `"$ClusterName`": $RemediationError"
    }
    Write-LogMessage -Type DEBUG -Message "vLCM remediation full error: $RemediationError"

    $summary = switch -Regex ($RemediationError) {
        "Health Check for '([^']+)' failed" { "Health Check for '$($Matches[1])' failed."; break }
        "'default_message':\s*([^,}]+)"     { $Matches[1].Trim(); break }
        default                             { $RemediationError }
    }

    if ($AcceptBadCheckResults.IsPresent) {
        Write-LogMessage -Type WARNING -Message "AcceptBadCheckResults is set; proceeding despite vLCM remediation failure for cluster `"$ClusterName`"."
        return
    }

    Write-LogMessage -Type WARNING -Message "vLCM remediation failed. You may proceed and accept the risk (cluster may not be compliant to the desired image), or exit to resolve issues first."
    $proceedPrompt = "Proceed anyway despite vLCM remediation failure? (Y/N)"
    do {
        $proceedResponse = Read-Host $proceedPrompt
        $proceedResponse = if ($proceedResponse) { $proceedResponse.Trim() } else { "" }
        if ($proceedResponse -match '^Y(es)?$') {
            Write-LogMessage -Type WARNING -Message "User chose to proceed despite vLCM remediation failure for cluster `"$ClusterName`". Accepting risk."
            return
        }
        if ($proceedResponse -match '^N(o)?$') {
            $err = "Deployment failed. Cluster must be compliant to the vLCM image before supervisor creation. vLCM reported: $summary"
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
        Write-LogMessage -Type WARNING -Message "Invalid response. Please enter Y or N."
    } while ($true)
}
function Invoke-VlcmClusterComplianceAndRemediate {

    <#
        .SYNOPSIS
        Ensures a cluster is compliant to its vLCM image and remediates if not.

        .DESCRIPTION
        Checks cluster compliance to the vSphere Lifecycle Manager (vLCM) desired state using
        Test-LcmClusterCompliance. If the cluster is not compliant (e.g. non-compliant or incompatible
        hosts), runs Set-Cluster -Remediate -AcceptEULA to apply the desired state to all hosts.
        Intended to be run before supervisor creation so the cluster is on the correct image.

        .PARAMETER AcceptBadCheckResults
        When specified, automatically proceed when vLCM remediation fails (no Y/N prompt). Equivalent to accepting the risk that the cluster may not be compliant to the desired image.

        .PARAMETER ClusterName
        The name of the vSphere cluster to check and remediate.

        .NOTES
        - Requires PowerCLI vLCM cmdlets (Test-LcmClusterCompliance, Set-Cluster -Remediate).
        - Remediation may reboot hosts; ensure the cluster has a vLCM desired state (e.g. from Add-Cluster).
        - If remediation fails (e.g. health check failure on a host), the user is prompted to proceed anyway (Y) or exit (N), unless AcceptBadCheckResults is set.
        - The vLCM desired image is set at cluster creation in Add-Cluster (New-Cluster with SoftwareSpecification from Find-VlcmImage / Get-LcmSoftwareSpecification). This function only checks compliance and runs Set-Cluster -Remediate to apply that same desired state to all hosts; it does not change the cluster's desired image.
    
        .EXAMPLE
        Invoke-VlcmClusterComplianceAndRemediate -ClusterName "edge-cluster-1"
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [Switch]$AcceptBadCheckResults,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName
    )

    Write-LogMessage -Type DEBUG -Message "Entered Invoke-VlcmClusterComplianceAndRemediate for cluster `"$ClusterName`"."

    $clusterObject = Get-Cluster -Name $ClusterName -Server $Script:vCenterName -ErrorAction SilentlyContinue
    if (-not $clusterObject) {
        $err = "Cluster `"$ClusterName`" not found. Cannot check vLCM compliance."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }

    $complianceResult = $null
    Write-LogMessage -Type INFO -Message "Running vLCM cluster compliance check for cluster `"$ClusterName`"."
    try {
        $complianceResult = $clusterObject | Test-LcmClusterCompliance -ErrorAction Stop
    } catch {
        $vlcmErrorMsg = $_.Exception.Message
        Write-LogMessage -Type DEBUG -Message "vLCM compliance check threw: $($_.Exception.GetType().FullName): $vlcmErrorMsg"
        if ($vlcmErrorMsg -match "Object reference not set|NullReferenceException") {
            Write-LogMessage -Type WARNING -Message "vLCM compliance check failed for cluster `"$ClusterName`": $vlcmErrorMsg. This can occur when the cluster has no vLCM desired image set, or a host is in an unexpected state. Verify in vCenter: Cluster > Configure > Lifecycle Manager (desired image). Proceeding without remediation."
        } else {
            Write-LogMessage -Type WARNING -Message "vLCM compliance check failed for cluster `"$ClusterName`": $vlcmErrorMsg. Proceeding without remediation."
        }
        return
    }

    if (-not $complianceResult) {
        Write-LogMessage -Type DEBUG -Message "No vLCM compliance result for cluster `"$ClusterName`". Proceeding without remediation."
        return
    }

    $isCompliant = ($complianceResult.Status -eq "Compliant")
    if ($isCompliant) {
        Write-LogMessage -Type INFO -Message "Cluster `"$ClusterName`" is compliant to the vLCM image. No remediation required."
        return
    }

    $nonCompliantHosts = @($complianceResult.NonCompliantHosts)
    $nonCompliantHostNames = Get-VlcmNonCompliantHostNames -NonCompliantHosts $nonCompliantHosts
    $hostNamesStr = if ($nonCompliantHostNames.Count -gt 0) { $nonCompliantHostNames -join ", " } else { "($($nonCompliantHosts.Count) host(s))" }
    Write-LogMessage -Type INFO -Message "Cluster `"$ClusterName`" is not compliant to the vLCM image (Status: $($complianceResult.Status); NonCompliantHosts: $($nonCompliantHosts.Count) - $hostNamesStr). Remediating..."

    # In VCF PowerCLI 9, Get-Cluster returns the desired image on .BaseImage.Version
    # (Broadcom: "Creating and Managing vLCM Clusters with VCF PowerCLI").
    $baseImageVersion = $null
    $hasBaseImage = $clusterObject.PSObject.Properties['BaseImage'] -and $null -ne $clusterObject.BaseImage
    $hasBaseImageVersion = $hasBaseImage -and $clusterObject.BaseImage.PSObject.Properties['Version'] -and -not [String]::IsNullOrWhiteSpace($clusterObject.BaseImage.Version)
    if ($hasBaseImageVersion) {
        $baseImageVersion = [String]$clusterObject.BaseImage.Version
    }

    if (-not [String]::IsNullOrWhiteSpace($baseImageVersion)) {
        Write-VlcmVersionMismatchWarnings -BaseImageVersion $baseImageVersion -ClusterName $ClusterName -NonCompliantHosts $nonCompliantHosts
    }

    Write-LogMessage -Type INFO -Message "Running vLCM remediation for cluster `"$ClusterName`"."
    try {
        $clusterObject | Set-Cluster -Remediate -AcceptEULA -Confirm:$false -Server $Script:vCenterName -ErrorAction Stop | Out-Null
        Write-LogMessage -Type INFO -Message "vLCM remediation completed for cluster `"$ClusterName`"."
        Test-VlcmPostRemediationCompliance -ClusterName $ClusterName -ClusterObject $clusterObject
    } catch {
        Invoke-VlcmRemediationFailureResponse -ClusterName $ClusterName -RemediationError $_.Exception.Message -AcceptBadCheckResults:$AcceptBadCheckResults.IsPresent
    }
}
function New-SupervisorDeploymentSpec {

    <#
        .SYNOPSIS
        Parses supervisor configuration from JSON and builds the complete API creation spec.

        .DESCRIPTION
        Calls Get-SupervisorConfigurationFromJson with all configuration parameters, validates the result
        via Test-SupervisorConfiguration, then builds and assembles the control plane, workload, and load
        balancer specifications into the final EnableOnComputeClusterSpec.

        .PARAMETER SuppressNetworkVanityPrefix
        Passed to Get-SupervisorConfigurationFromJson to disable vanity name prefix on network names.

        .PARAMETER EdgeSite
        The edge site name used to scope the JSON configuration lookup.

        .PARAMETER FlbMgmtNetworkPersona
        Management network persona for the front-end load balancer.

        .PARAMETER FlbNetworkIpAssignmentMode
        IP assignment mode for FLB networks.

        .PARAMETER FlbProvider
        Front-end load balancer provider.

        .PARAMETER FlbWorkloadNetworkPersona
        Workload network personas for the front-end load balancer.

        .PARAMETER InfrastructureJson
        Path to the infrastructure JSON configuration file.

        .PARAMETER MgmtIpAssignmentMode
        IP assignment mode for the management network.

        .PARAMETER NetworkSegments
        Network segments array for the supervisor.

        .PARAMETER PrimaryWorkloadIpAssignmentMode
        IP assignment mode for the primary workload network.

        .PARAMETER StoragePolicyId
        vSphere storage policy UUID for supervisor control plane VMs.

        .PARAMETER SupervisorName
        Display name for the supervisor.

        .EXAMPLE
        $spec = New-SupervisorDeploymentSpec -EdgeSite "edge1" -InfrastructureJson $jsonPath -NetworkSegments $segs -StoragePolicyId $policyId -SupervisorName "sup1"

        .NOTES
        Throws [VcfDeploymentException] if the parsed configuration fails Test-SupervisorConfiguration.
    #>

    [CmdletBinding()]
    [OutputType([Object])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EdgeSite,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$FlbMgmtNetworkPersona = "MANAGEMENT",
        [Parameter(Mandatory = $false)] [ValidateSet("STATIC")] [String]$FlbNetworkIpAssignmentMode = "STATIC",
        [Parameter(Mandatory = $false)] [ValidateSet("VSPHERE_FOUNDATION")] [String]$FlbProvider = "VSPHERE_FOUNDATION",
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [Object[]]$FlbWorkloadNetworkPersona = @("FRONTEND", "WORKLOAD"),
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$InfrastructureJson,
        [Parameter(Mandatory = $false)] [ValidateSet("STATIC")] [String]$MgmtIpAssignmentMode = "STATIC",
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Object[]]$NetworkSegments,
        [Parameter(Mandatory = $false)] [ValidateSet("STATIC")] [String]$PrimaryWorkloadIpAssignmentMode = "STATIC",
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$StoragePolicyId,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorName,
        [Parameter(Mandatory = $false)] [Switch]$SuppressNetworkVanityPrefix
    )

    $config = Get-SupervisorConfigurationFromJson `
        -SuppressNetworkVanityPrefix:$SuppressNetworkVanityPrefix.IsPresent `
        -EdgeSite $EdgeSite `
        -FlbNetworkIpAssignmentMode $FlbNetworkIpAssignmentMode `
        -FlbMgmtNetworkPersona $FlbMgmtNetworkPersona `
        -FlbProvider $FlbProvider `
        -FlbVirtualServerNetworkPersona $FlbWorkloadNetworkPersona `
        -JsonFilePath $InfrastructureJson `
        -MgmtIpAssignmentMode $MgmtIpAssignmentMode `
        -NetworkSegments $NetworkSegments `
        -PrimaryWorkloadIpAssignmentMode $PrimaryWorkloadIpAssignmentMode

    if (-not (Test-SupervisorConfiguration -Config $config)) {
        $err = "Supervisor configuration validation failed."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }

    $controlPlaneSpec = New-SupervisorControlPlaneSpec `
        -ControlPlaneConfig $config.ControlPlane `
        -ManagementNetworkConfig $config.ManagementNetwork `
        -StoragePolicyId $StoragePolicyId

    $workloadNetworkSpec = New-SupervisorWorkloadSpec -WorkloadNetworkConfig $config.WorkloadNetwork

    $edgeSpec = New-SupervisorLoadBalancerSpec `
        -FlbMgmtNetworkPersona $FlbMgmtNetworkPersona `
        -FlbWorkloadNetworkPersona $FlbWorkloadNetworkPersona `
        -LoadBalancerConfig $config.LoadBalancer `
        -StoragePolicyId $StoragePolicyId

    $kubeApiServerOptions = Initialize-VcenterNamespaceManagementSupervisorsKubeAPIServerOptions
    $workloadsSpec = Initialize-VcenterNamespaceManagementSupervisorsWorkloads `
        -Edge $edgeSpec `
        -KubeApiServerOptions $kubeApiServerOptions `
        -Network $workloadNetworkSpec

    return Initialize-VcenterNamespaceManagementSupervisorsEnableOnComputeClusterSpec `
        -ControlPlane $controlPlaneSpec `
        -Name $SupervisorName `
        -Workloads $workloadsSpec
}
function Invoke-SupervisorReadinessWait {

    <#
        .SYNOPSIS
        Waits for a newly-created supervisor to become ready, with rollback on timeout.

        .DESCRIPTION
        Polls Wait-SupervisorReady until the supervisor reaches ConfigStatus=RUNNING and
        KubernetesStatus=READY. On timeout, prompts to deactivate the supervisor and optionally
        delete the compute cluster, then throws VcfDeploymentException. Sets $Script:RollbackAttempted
        on the failure path.

        .PARAMETER CheckInterval
        Seconds between status polls.

        .PARAMETER ClusterId
        vSphere cluster MoRef used when deactivating the supervisor on rollback.

        .PARAMETER ClusterName
        Cluster display name used in log messages and the rollback confirmation prompt.

        .PARAMETER SingleSite
        When set, the rollback prompt shows only Y/N (no A=always).

        .PARAMETER SupervisorId
        UUID of the supervisor to monitor.

        .PARAMETER TotalWaitTime
        Maximum seconds to wait for readiness before triggering the rollback path.

        .EXAMPLE
        Invoke-SupervisorReadinessWait -SupervisorId $supervisorId -ClusterId $clusterId -ClusterName "cluster-edge1" -CheckInterval 5 -TotalWaitTime 3600
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(1, [Int]::MaxValue)] [Int]$CheckInterval = 5,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterId,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [Switch]$SingleSite,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorId,
        [Parameter(Mandatory = $false)] [ValidateRange(1, [Int]::MaxValue)] [Int]$TotalWaitTime = 3600
    )

    # Clear any lingering progress bar before showing our status so only one progress bar is visible.
    Write-Progress -Activity "Task created by VMware vSphere Lifecycle Manager" -Completed
    Write-Progress -Activity "Supervisor Deployment" -Completed
    Write-Progress -Activity "Supervisor Deployment" -Status "Monitoring supervisor deployment status..." -PercentComplete 85
    [Console]::Out.Flush()

    $waitResult = Wait-SupervisorReady `
        -supervisorId $SupervisorId `
        -clusterName $ClusterName `
        -checkInterval $CheckInterval `
        -totalWaitTime $TotalWaitTime

    if ($waitResult.Success) {
        return
    }

    Write-LogMessage -Type ERROR -Message "Supervisor did not become ready within $TotalWaitTime seconds."
    $deactivateDecision = Invoke-PauseBeforeRollbackIfRequested `
        -ForcePrompt `
        -RollbackContext "supervisor deactivation (cluster `"$ClusterName`") - deactivate supervisor to leave cluster in a clean state for retry" `
        -SingleSite:$SingleSite.IsPresent

    if ($deactivateDecision -eq "DoNotRollback") {
        throw [RollbackSkippedException]::new()
    }

    Write-LogMessage -Type INFO -Message "Deactivating supervisor on cluster `"$ClusterName`" to leave cluster in a clean state for retry."
    $disableResult = Disable-SupervisorOnCluster `
        -ClusterId $ClusterId `
        -ClusterName $ClusterName `
        -SupervisorId $SupervisorId `
        -SuppressConfirm

    if ($disableResult.Success) {
        Write-LogMessage -Type INFO -Message "Supervisor fully deactivated. You may retry deployment."
        try {
            $response = $null
            do {
                $response = Read-Host "Do you want to delete the compute cluster as well? (Y/N; press Enter for N)"
                $response = if ($response) { $response.Trim() } else { "" }
                if ($response -match '^[yY](es)?$') {
                    Write-LogMessage -Type INFO -Message "User chose to delete the compute cluster `"$ClusterName`"."
                    try {
                        Invoke-VcenterReconnectIfNeeded
                        Remove-ClusterSafely -ClusterName $ClusterName
                    } catch {
                        $removeError = $_.Exception.Message
                        if ($removeError -match "Not connected to vCenter|No active PowerCLI session") {
                            try {
                                Invoke-VcenterReconnectIfNeeded
                                Remove-ClusterSafely -ClusterName $ClusterName
                            } catch {
                                Write-LogMessage -Type WARNING -Message "Could not remove cluster `"$ClusterName`" after supervisor rollback: $($_.Exception.Message). Remove the cluster manually if desired."
                            }
                        } else {
                            Write-LogMessage -Type WARNING -Message "Could not remove cluster `"$ClusterName`" after supervisor rollback: $removeError. Remove the cluster manually if desired."
                        }
                    }
                    break
                }
                if ([String]::IsNullOrWhiteSpace($response) -or $response -match '^[nN](o)?$') {
                    Write-LogMessage -Type INFO -Message "User chose not to delete the compute cluster."
                    break
                }
                Write-LogMessage -Type WARNING -Message "Invalid response. Please enter Y or N (or press Enter for N)."
            } while ($true)
        } catch {
            Write-LogMessage -Type WARNING -Message "Read-Host failed (non-interactive?): $($_.Exception.Message). Skipping optional cluster deletion prompt."
        }
    } else {
        Write-LogMessage -Type WARNING -Message "Supervisor deactivation failed or did not complete in time: $($disableResult.ErrorMessage). Manually disable the supervisor in vCenter if needed."
    }

    $Script:RollbackAttempted = $true
    $err = "Supervisor deployment failed for cluster `"$ClusterName`": $($disableResult.ErrorMessage). Check logs for details."
    Write-LogMessage -Type ERROR -Message $err
    throw [VcfDeploymentException]::new($err)
}
function Invoke-SupervisorUpgradeIfAvailable {

    <#
        .SYNOPSIS
        Checks for available supervisor upgrades and applies the latest version if found.

        .DESCRIPTION
        Calls Get-SupervisorUpgradeInfo for the given cluster. If an upgrade is available,
        calls Invoke-SupervisorUpgrade then waits for completion via Wait-SupervisorUpgradeComplete.
        Logs the current and target versions. Throws VcfDeploymentException if initiation or wait fails.
        Returns without action if no upgrade is available or if the upgrade info query fails.

        .PARAMETER CheckInterval
        Seconds between upgrade status polls.

        .PARAMETER ClusterId
        vSphere cluster MoRef for the upgrade API call.

        .PARAMETER ClusterName
        Cluster display name for log messages.

        .PARAMETER SupervisorId
        UUID of the supervisor to upgrade.

        .PARAMETER TotalWaitTime
        Maximum seconds to wait for upgrade completion.

        .EXAMPLE
        Invoke-SupervisorUpgradeIfAvailable -ClusterId $ClusterId -ClusterName "cluster-edge1" -SupervisorId $supervisorId -CheckInterval 5 -TotalWaitTime 3600
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(1, [Int]::MaxValue)] [Int]$CheckInterval = 5,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterId,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorId,
        [Parameter(Mandatory = $false)] [ValidateRange(1, [Int]::MaxValue)] [Int]$TotalWaitTime = 3600
    )

    Write-LogMessage -Type INFO -Message "Checking for available supervisor upgrade versions..."
    $upgradeInfo = Get-SupervisorUpgradeInfo -ClusterId $ClusterId

    if (-not $upgradeInfo.Success) {
        Write-LogMessage -Type WARNING -Message "Failed to query supervisor upgrade information: $($upgradeInfo.ErrorMessage). Skipping upgrade check."
        return
    }

    if (-not $upgradeInfo.HasUpgradeAvailable) {
        Write-LogMessage -Type INFO -Message "No supervisor upgrade available. Current version $($upgradeInfo.CurrentVersion) is up to date."
        return
    }

    Write-LogMessage -Type INFO -Message "Supervisor upgrade available for cluster `"$ClusterName`" (ID: $ClusterId):"
    Write-LogMessage -Type INFO -Message "  Current version: $($upgradeInfo.CurrentVersion)"
    Write-LogMessage -Type INFO -Message "  Latest available version: $($upgradeInfo.LatestVersion)"
    Write-LogMessage -Type INFO -Message "  Available versions: $($upgradeInfo.AvailableVersions -join ', ')"

    Write-LogMessage -Type INFO -Message "Initiating supervisor upgrade to version $($upgradeInfo.LatestVersion)..."
    $upgradeResult = Invoke-SupervisorUpgrade -ClusterId $ClusterId -DesiredVersion $upgradeInfo.LatestVersion

    if (-not $upgradeResult.Success) {
        Write-LogMessage -Type ERROR -Message "Failed to initiate supervisor upgrade: $($upgradeResult.ErrorMessage)."
        $err = "Supervisor upgrade is required for deployment to proceed."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }

    Write-LogMessage -Type INFO -Message "Supervisor upgrade initiated successfully. Waiting for upgrade to complete..."
    $upgradeWaitResult = Wait-SupervisorUpgradeComplete `
        -CheckInterval $CheckInterval `
        -ClusterId $ClusterId `
        -ClusterName $ClusterName `
        -DesiredVersion $upgradeInfo.LatestVersion `
        -SupervisorId $SupervisorId `
        -TotalWaitTime $TotalWaitTime

    if ($upgradeWaitResult.Success) {
        Write-LogMessage -Type INFO -Message "Supervisor upgrade completed successfully. Final version: $($upgradeWaitResult.FinalVersion)"
        return
    }

    Write-LogMessage -Type ERROR -Message "Supervisor upgrade did not complete within $TotalWaitTime seconds."
    $err = "The upgrade may still be in progress. Check the supervisor status in vCenter UI."
    Write-LogMessage -Type ERROR -Message $err
    throw [VcfDeploymentException]::new($err)
}
function Add-Supervisor {

    <#
        .SYNOPSIS
        Deploys a new vSphere Supervisor on a compute cluster, or retrieves the ID of an existing one.

        .DESCRIPTION
        Reads supervisor configuration from InfrastructureJson, builds the API spec, calls
        Invoke-SupervisorCreation, then polls until ConfigStatus=RUNNING and KubernetesStatus=READY.
        If a supervisor already exists on the cluster, returns its ID. Throws on failure or timeout.

        .PARAMETER InfrastructureJson
        Path to the supervisor JSON configuration file.

        .PARAMETER StoragePolicyId
        vSphere storage policy UUID for supervisor control plane VMs.

        .PARAMETER ClusterId
        vSphere cluster MoRef (e.g., "domain-c8") where the supervisor will be enabled.

        .PARAMETER ClusterName
        Cluster display name used in log messages and progress tracking.

        .PARAMETER TotalWaitTime
        Maximum seconds to wait for supervisor readiness. Default: 3600.

        .PARAMETER CheckInterval
        Seconds between status polls. Default: 5.

        .PARAMETER InsecureTls
        Bypasses SSL certificate validation for REST API calls.

        .PARAMETER SuppressNetworkVanityPrefix
        Passed to Get-SupervisorConfigurationFromJson to disable vanity name prefix on network names.

        .PARAMETER SingleSite
        When set, the rollback prompt on supervisor timeout shows only Y/N (no A=always).

        .EXAMPLE
        $supId = Add-Supervisor -ClusterId $ClusterId -ClusterName $ClusterName -InfrastructureJson $jsonPath -StoragePolicyId $policyId -InsecureTls

        .OUTPUTS
        System.String — supervisor UUID of the created or pre-existing supervisor.

        .LINK
        Get-SupervisorId
        Invoke-SupervisorCreation
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(1, [Int]::MaxValue)] [Int]$CheckInterval = 5,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterId,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EdgeSite,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$FlbMgmtNetworkPersona = "MANAGEMENT",
        [Parameter(Mandatory = $false)] [ValidateSet("STATIC")] [String]$FlbNetworkIpAssignmentMode = "STATIC",
        [Parameter(Mandatory = $false)] [ValidateSet("VSPHERE_FOUNDATION")] [String]$FlbProvider = "VSPHERE_FOUNDATION",
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [Object[]]$FlbWorkloadNetworkPersona = @("FRONTEND", "WORKLOAD"),
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$InfrastructureJson,
        [Parameter(Mandatory = $false)] [Switch]$InsecureTls,
        [Parameter(Mandatory = $false)] [ValidateSet("STATIC")] [String]$MgmtIpAssignmentMode = "STATIC",
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Object[]]$NetworkSegments,
        [Parameter(Mandatory = $false)] [ValidateSet("STATIC")] [String]$PrimaryWorkloadIpAssignmentMode = "STATIC",
        [Parameter(Mandatory = $false)] [Switch]$SingleSite,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$StoragePolicyId,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorName,
        [Parameter(Mandatory = $false)] [Switch]$SuppressNetworkVanityPrefix,
        [Parameter(Mandatory = $false)] [ValidateRange(1, [Int]::MaxValue)] [Int]$TotalWaitTime = 3600,
        [Parameter(Mandatory = $false)] [PSCredential]$VcenterCredential
    )

    Write-LogMessage -Type DEBUG -Message "Entered Add-Supervisor function..."
    Write-LogMessage -Type INFO -Message "Beginning Supervisor deployment to cluster `"$ClusterName`"..."

    try {
        Write-Progress -Activity "Supervisor Deployment" -Status "Parsing and assembling supervisor specification..." -PercentComplete 10
        Write-LogMessage -Type DEBUG -Message "Parsing and assembling supervisor specification..."
        $supervisorSpec = New-SupervisorDeploymentSpec `
            -SuppressNetworkVanityPrefix:$SuppressNetworkVanityPrefix.IsPresent `
            -EdgeSite $EdgeSite `
            -FlbMgmtNetworkPersona $FlbMgmtNetworkPersona `
            -FlbNetworkIpAssignmentMode $FlbNetworkIpAssignmentMode `
            -FlbProvider $FlbProvider `
            -FlbWorkloadNetworkPersona $FlbWorkloadNetworkPersona `
            -InfrastructureJson $InfrastructureJson `
            -MgmtIpAssignmentMode $MgmtIpAssignmentMode `
            -NetworkSegments $NetworkSegments `
            -PrimaryWorkloadIpAssignmentMode $PrimaryWorkloadIpAssignmentMode `
            -StoragePolicyId $StoragePolicyId `
            -SupervisorName $SupervisorName

        Write-Progress -Activity "Supervisor Deployment" -Status "Invoking supervisor creation API..." -PercentComplete 50
        Write-LogMessage -Type DEBUG -Message "Invoking supervisor creation API..."
        $creationResult = Invoke-SupervisorCreation `
            -ClusterId $ClusterId `
            -ClusterName $ClusterName `
            -InsecureTls:$InsecureTls.IsPresent `
            -SupervisorName $SupervisorName `
            -SupervisorSpec $supervisorSpec `
            -VcenterCredential $VcenterCredential

        if (-not $creationResult.Success) {
            $cleanError = Get-CleanErrorMessage -ErrorMessage $creationResult.ErrorMessage
            $err = "Supervisor creation failed: $cleanError."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }

        $supervisorId = $creationResult.SupervisorId
        if ($creationResult.IsExisting) {
            Write-LogMessage -Type INFO -Message "Using existing supervisor ID: $supervisorId."
            return $supervisorId
        }

        Write-Progress -Activity "Supervisor Deployment" -Status "Monitoring supervisor readiness..." -PercentComplete 70
        Write-LogMessage -Type DEBUG -Message "Monitoring supervisor deployment status..."
        Invoke-SupervisorReadinessWait `
            -CheckInterval $CheckInterval `
            -ClusterId $ClusterId `
            -ClusterName $ClusterName `
            -SingleSite:$SingleSite.IsPresent `
            -SupervisorId $supervisorId `
            -TotalWaitTime $TotalWaitTime

        Write-LogMessage -Type DEBUG -Message "Supervisor is ready. Checking for available upgrades..."
        Invoke-SupervisorUpgradeIfAvailable `
            -CheckInterval $CheckInterval `
            -ClusterId $ClusterId `
            -ClusterName $ClusterName `
            -SupervisorId $supervisorId `
            -TotalWaitTime $TotalWaitTime

        return $supervisorId
    } catch [VcfDeploymentException] {
        throw  # already logged and typed — propagate without re-wrapping
    } catch {
        $err = "Failed to create a Supervisor on cluster `"$ClusterName`" attached to vCenter `"$Script:vCenterName`": $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    } finally {
        Write-Progress -Activity "Supervisor Deployment" -Completed
    }
}
function Resolve-StoragePolicyTagContext {

    <#
        .SYNOPSIS
        Looks up the tag object, the existing storage policy, and whether the tag is already present in that policy.

        .DESCRIPTION
        Queries vCenter for the tag and the named storage policy, then checks whether the tag is already a member of the policy.
        Centralises the three read-only vCenter lookups that Set-StoragePolicy needs before deciding whether to create, update, or
        skip. Throws when the tag is not found so that callers do not proceed with a missing tag.

        .PARAMETER PolicyName
        The name of the storage policy to look up.

        .PARAMETER Server
        vCenter server name.

        .PARAMETER TagCatalog
        The tag category name that contains the tag.

        .PARAMETER TagName
        The tag name to look up and check for.

        .OUTPUTS
        PSCustomObject with TagObject, ExistingPolicy (or $null), and TagAlreadyPresent (bool).

        .EXAMPLE
        $context = Resolve-StoragePolicyTagContext -PolicyName "VMFS-Policy" -Server $Script:vCenterName -TagCatalog "Site" -TagName "site1"
        if ($context.TagAlreadyPresent) { return }
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$PolicyName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Server,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$TagCatalog,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$TagName
    )

    $tagObject = Get-Tag -Name $TagName -Category $TagCatalog -Server $Server -ErrorAction Stop
    $existingPolicy = Get-SpbmStoragePolicy -Name $PolicyName -Server $Server -ErrorAction SilentlyContinue
    $tagAlreadyPresent = $false
    if ($existingPolicy) {
        $policyWithTag = Get-SpbmStoragePolicy -Name $PolicyName -Tag $tagObject -Server $Server -ErrorAction SilentlyContinue
        $tagAlreadyPresent = $null -ne $policyWithTag
    }
    return [PSCustomObject]@{
        TagObject         = $tagObject
        ExistingPolicy    = $existingPolicy
        TagAlreadyPresent = $tagAlreadyPresent
    }
}
function Build-SpbmUpdatedRuleSets {

    <#
    .SYNOPSIS
        Builds the updated SPBM rule-set list to include a new tag rule.
    .DESCRIPTION
        Iterates existing rule sets (or creates a fresh one when none exist) and merges the new tag
        into each. Capability rules (VMFS volume allocation) are preserved. Returns a generic list of
        updated rule-set objects for use with Set-SpbmStoragePolicy.
    .PARAMETER ExistingRuleSets
        The current AnyOfRuleSets from the SPBM storage policy, or $null/$empty when none exist.
    .PARAMETER NewTagRule
        The new SPBM tag rule object to add.
    .PARAMETER PolicyName
        Policy display name used in log messages.
    .PARAMETER RuleValue
        Volume allocation rule value for VMFS policies.
    .PARAMETER StorageType
        Storage type: "VMFS", "vSAN-OSA", or "vSAN-ESA".
    .PARAMETER TagObject
        Resolved tag object passed to Invoke-MergeTagRules.
    .PARAMETER VolumeAllocationCapability
        SPBM capability object for VMFS volume allocation; $null for non-VMFS storage types.
    .EXAMPLE
        $rulesets = Build-SpbmUpdatedRuleSets -ExistingRuleSets $policy.AnyOfRuleSets -NewTagRule $newRule -PolicyName "VMFS-Policy" -RuleValue "Fully initialized" -StorageType "VMFS" -TagObject $tag -VolumeAllocationCapability $cap
    .NOTES
        Called by Add-StoragePolicyTagRule. Throws VcfDeploymentException on rule-set build failures.
    #>

    [CmdletBinding()]
    [OutputType([System.Collections.Generic.List[object]])]
    Param (
        [Parameter(Mandatory = $false)] [Object]$ExistingRuleSets,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$NewTagRule,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$PolicyName,
        [Parameter(Mandatory = $false)] [ValidateSet("Conserve space when possible", "Fully initialized", "Reserve space")] [String]$RuleValue = "Fully initialized",
        [Parameter(Mandatory = $true)] [ValidateSet("VMFS", "vSAN-OSA", "vSAN-ESA")] [String]$StorageType,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$TagObject,
        [Parameter(Mandatory = $false)] [Object]$VolumeAllocationCapability
    )

    $updatedRuleSets = [System.Collections.Generic.List[object]]::new()
    if (-not $ExistingRuleSets -or $ExistingRuleSets.Count -eq 0) {
        Write-LogMessage -Type DEBUG -Message "Policy `"$PolicyName`" has no existing rule sets. Creating new rule set with tag."
        if ($StorageType -eq "VMFS") {
            $capabilityRule = New-SpbmRule -Capability $VolumeAllocationCapability -Value $RuleValue -Server $Script:vCenterName -ErrorAction Stop
            $updatedRuleSets.Add((New-SpbmRuleSet -AllOfRules $capabilityRule, $NewTagRule -ErrorAction Stop))
        } else {
            $updatedRuleSets.Add((New-SpbmRuleSet -AllOfRules $NewTagRule -ErrorAction Stop))
        }
        return $updatedRuleSets
    }
    foreach ($ruleSet in $ExistingRuleSets) {
        if (-not $ruleSet -or -not $ruleSet.AllOfRules) { Write-LogMessage -Type WARNING -Message "Rule set in policy `"$PolicyName`" has no AllOfRules. Skipping this rule set."; continue }
        $updatedRules = [System.Collections.Generic.List[object]]::new()
        $tagRules     = [System.Collections.Generic.List[object]]::new()
        $existingCapabilityRuleValue = $null
        foreach ($rule in $ruleSet.AllOfRules) {
            if (-not $rule) { Write-LogMessage -Type DEBUG -Message "Skipping null rule in policy `"$PolicyName`"."; continue }
            if ($rule.Capability -and $rule.Capability.Name -eq "com.vmware.storage.volumeallocation.VolumeAllocationType") {
                $existingCapabilityRuleValue = $rule.Value
            } elseif ($rule.AnyOfTags) {
                $tagRules.Add($rule)
            } elseif ($rule.Capability -and $rule.Value) {
                try { $updatedRules.Add((New-SpbmRule -Capability $rule.Capability -Value $rule.Value -Server $Script:vCenterName -ErrorAction Stop)) }
                catch { Write-LogMessage -Type WARNING -Message "Could not recreate rule with capability `"$($rule.Capability.Name)`". Skipping this rule." }
            }
        }
        if ($StorageType -eq "VMFS" -and $VolumeAllocationCapability) {
            $capabilityRuleValue = if ($existingCapabilityRuleValue) { $existingCapabilityRuleValue } else { $RuleValue }
            $updatedRules.Add((New-SpbmRule -Capability $VolumeAllocationCapability -Value $capabilityRuleValue -Server $Script:vCenterName -ErrorAction Stop))
        }
        $mergedTagRule = if ($tagRules.Count -gt 0) { Invoke-MergeTagRules -TagRules $tagRules -NewTagObject $TagObject -PolicyName $PolicyName } else { $NewTagRule }
        $updatedRules.Add($mergedTagRule)
        if ($updatedRules.Count -gt 0) {
            try { $updatedRuleSets.Add((New-SpbmRuleSet -AllOfRules $updatedRules -ErrorAction Stop)) }
            catch [VcfDeploymentException] { throw }
            catch {
                $ruleDetailsList = $updatedRules | ForEach-Object { "Type=$($_.GetType().FullName), Capability=$($_.Capability), AnyOfTags=$($_.AnyOfTags)" }
                $err = "Failed to create rule set with $($updatedRules.Count) rule(s): $($_.Exception.Message)"
                Write-LogMessage -Type ERROR -Message $err
                throw [VcfDeploymentException]::new($err)
            }
        } else {
            Write-LogMessage -Type WARNING -Message "No rules to add to rule set in policy `"$PolicyName`". Skipping this rule set."
        }
    }
    return $updatedRuleSets
}
function Add-StoragePolicyTagRule {

    <#
        .SYNOPSIS
        Adds a vSphere tag rule to an existing SPBM storage policy.

        .DESCRIPTION
        Rebuilds the rule sets of an existing storage policy to include a new tag in the AnyOfTags
        rule. Existing capability rules (e.g. VMFS volume allocation) are preserved. Orphaned tag
        references that vSphere marks as " (missing)" are stripped and the live tag is re-fetched so
        that the SPBM API receives a properly formatted object. After building the updated rule sets
        the function calls Set-SpbmStoragePolicy to persist the change.

        SPBM requires all tags inside a single AnyOfTags rule to belong to the same category. Tags
        from other categories that happen to be in the existing policy are omitted with a DEBUG log.

        .PARAMETER Policy
        The existing SPBM storage policy object returned by Get-SpbmStoragePolicy.

        .PARAMETER PolicyName
        The display name of the policy. Used only in log messages.

        .PARAMETER RuleValue
        The volume allocation rule value to preserve or set for VMFS policies.
        Ignored for vSAN-OSA and vSAN-ESA storage types.

        .PARAMETER StorageType
        The storage type that governs which rule kinds are valid: "VMFS", "vSAN-OSA", or "vSAN-ESA".

        .PARAMETER TagCatalog
        The tag category name. Used only in log messages.

        .PARAMETER TagName
        The tag name to add. Used only in log messages.

        .PARAMETER TagObject
        The resolved tag object returned by Get-Tag.

        .EXAMPLE
        $policy    = Get-SpbmStoragePolicy -Name "VMFS-Policy" -Server $Script:vCenterName
        $tagObject = Get-Tag -Name "site1" -Category "Site" -Server $Script:vCenterName
        Add-StoragePolicyTagRule -Policy $policy -PolicyName "VMFS-Policy" -StorageType "VMFS" `
            -RuleValue "Fully initialized" -TagCatalog "Site" -TagName "site1" -TagObject $tagObject

        .NOTES
        This is a private helper for Set-StoragePolicy. Call Set-StoragePolicy for the full
        idempotency-checked create-or-update workflow.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$Policy,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$PolicyName,
        [Parameter(Mandatory = $false)] [ValidateSet("Conserve space when possible", "Fully initialized", "Reserve space")] [String]$RuleValue = "Fully initialized",
        [Parameter(Mandatory = $true)] [ValidateSet("VMFS", "vSAN-OSA", "vSAN-ESA")] [String]$StorageType,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$TagCatalog,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$TagName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$TagObject
    )

    Write-LogMessage -Type INFO -Message "Storage policy `"$PolicyName`" exists but does not contain tag `"$TagName`". Adding tag to existing policy."

    $volumeAllocationCapability = $null
    if ($StorageType -eq "VMFS") {
        $volumeAllocationCapability = Get-SpbmCapability -Name "com.vmware.storage.volumeallocation.VolumeAllocationType" -Server $Script:vCenterName -ErrorAction Stop
    }

    $newTagRule = New-SpbmRule -AnyOfTags $TagObject -Server $Script:vCenterName -ErrorAction Stop

    # Build-SpbmUpdatedRuleSets returns a generic List; PowerShell pipeline unwraps empty collections to
    # $null, so reconstruct the List from @() to guarantee Count is always accessible.
    $updatedRuleSets = [System.Collections.Generic.List[object]]::new([object[]]@(Build-SpbmUpdatedRuleSets `
        -ExistingRuleSets $Policy.AnyOfRuleSets `
        -NewTagRule $newTagRule `
        -PolicyName $PolicyName `
        -RuleValue $RuleValue `
        -StorageType $StorageType `
        -TagObject $TagObject `
        -VolumeAllocationCapability $volumeAllocationCapability))

    if ($updatedRuleSets.Count -eq 0) {
        try {
            if ($StorageType -eq "VMFS" -and $volumeAllocationCapability) {
                $capabilityRule = New-SpbmRule -Capability $volumeAllocationCapability -Value $RuleValue -Server $Script:vCenterName -ErrorAction Stop
                $ruleSet = New-SpbmRuleSet -AllOfRules $capabilityRule, $newTagRule -ErrorAction Stop
            } else {
                $ruleSet = New-SpbmRuleSet -AllOfRules $newTagRule -ErrorAction Stop
            }
            $updatedRuleSets.Add($ruleSet)
        } catch [VcfDeploymentException] {
            throw
        } catch {
            $err = "Failed to create fallback rule set: $($_.Exception.Message)"
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
    }

    try {
        $null = Set-SpbmStoragePolicy -StoragePolicy $Policy -AnyOfRuleSets $updatedRuleSets -Server $Script:vCenterName -ErrorAction Stop
        Write-LogMessage -Type INFO -Message "Successfully added tag `"$TagName`" from catalog `"$TagCatalog`" to storage policy `"$PolicyName`"."
    } catch {
        $errorMessage = $_.Exception.Message
        Write-LogMessage -Type ERROR -Message "Failed to update storage policy `"$PolicyName`": $errorMessage"
        if ($errorMessage -match "invalid format") {
            Write-LogMessage -Type ERROR -Message "Invalid format error detected. Diagnostic information:"
            Write-LogMessage -Type ERROR -Message "  - Number of rule sets: $($updatedRuleSets.Count)"
            Write-LogMessage -Type ERROR -Message "  - Tag being added: `"$TagName`" from catalog `"$TagCatalog`""
            Write-LogMessage -Type ERROR -Message "  - Tag object type: $($TagObject.GetType().FullName)"
            Write-LogMessage -Type ERROR -Message "  - Tag object properties: Name=$($TagObject.Name), Id=$($TagObject.Id), Category=$($TagObject.Category.Name)"
            Write-LogMessage -Type INFO -Message ""
            Write-LogMessage -Type ERROR -Message "Typical causes: tag objects not properly formatted; rule objects cannot be reused; incompatible rule combinations."
            $err = "Resolution: verify the policy in vCenter UI (Policies and Profiles > VM Storage Policies); check that tag `"$TagName`" exists in catalog `"$TagCatalog`"."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        } else {
            throw
        }
    }
}
function Invoke-MergeTagRules {

    <#
        .SYNOPSIS
        Combines an existing set of SPBM tag rules with a new tag into a single AnyOfTags rule.

        .DESCRIPTION
        Extracts tag objects from each existing AnyOfTags rule, re-fetches each tag live from vCenter
        (to avoid stale SPBM object references), deduplicates by tag ID, filters to the same category
        as the new tag (SPBM requires intra-category AnyOfTags), appends the new tag, and returns a
        single New-SpbmRule result.

        Tags that vSphere marks as " (missing)" are stripped and re-fetched by name+category. Tags
        whose name is entirely empty after stripping are skipped silently.

        .PARAMETER NewTagObject
        The resolved tag object to add (already fetched by the caller via Get-Tag).

        .PARAMETER PolicyName
        The policy name, used only in log messages.

        .PARAMETER TagRules
        The list of existing AnyOfTags rule objects from the policy's rule set.

        .EXAMPLE
        $mergedRule = Invoke-MergeTagRules -TagRules $existingTagRules -NewTagObject $tagObject -PolicyName "VMFS-Policy"

        .NOTES
        This is a private helper for Add-StoragePolicyTagRule. Not intended for direct call.
    #>

    [CmdletBinding()]
    [OutputType([Object])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$NewTagObject,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$PolicyName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$TagRules
    )

    $allTags        = [System.Collections.Generic.List[object]]::new()
    $existingTagIds = [System.Collections.Generic.HashSet[string]]::new()

    foreach ($tagRule in $TagRules) {
        if (-not $tagRule.AnyOfTags) { continue }
        $tagsToProcess = if ($tagRule.AnyOfTags -is [Array]) { $tagRule.AnyOfTags } else { @($tagRule.AnyOfTags) }

        foreach ($tag in $tagsToProcess) {
            if (-not $tag) { continue }

            $extractedTagName     = if ($tag.Name)     { ($tag.Name     -replace ' \(missing\)$', '').Trim() } else { $null }
            $extractedTagCategory = if ($tag.Category) {
                if ($tag.Category.Name) { ($tag.Category.Name -replace ' \(missing\)$', '').Trim() }
                elseif ($tag.Category -is [string]) { ($tag.Category -replace ' \(missing\)$', '').Trim() }
                else { $null }
            } else { $null }

            if ([String]::IsNullOrWhiteSpace($extractedTagName)) {
                Write-LogMessage -Type DEBUG -Message "Skipping tag rule with empty or stale (missing) tag name in policy `"$PolicyName`"."
                continue
            }

            try {
                $freshTag = if ($extractedTagName -and $extractedTagCategory) {
                    Get-Tag -Name $extractedTagName -Category $extractedTagCategory -Server $Script:vCenterName -ErrorAction Stop
                } else {
                    Get-Tag -Name $extractedTagName -Server $Script:vCenterName -ErrorAction Stop
                }
                if ($freshTag) {
                    $tagId = if ($freshTag.Id) { $freshTag.Id }
                             elseif ($freshTag.Name -and $freshTag.Category) { "$($freshTag.Category.Name):$($freshTag.Name)" }
                             else { $freshTag.Name }
                    if ($tagId -and $existingTagIds.Add($tagId)) { $allTags.Add($freshTag) }
                }
            } catch {
                Write-LogMessage -Type WARNING -Message "Could not retrieve fresh tag object for `"$extractedTagName`": $($_.Exception.Message)"
            }
        }
    }

    # Append the new tag, deduplicating by ID.
    $newTagId = if ($NewTagObject.Id) { $NewTagObject.Id }
                elseif ($NewTagObject.Name -and $NewTagObject.Category) { "$($NewTagObject.Category.Name):$($NewTagObject.Name)" }
                else { $NewTagObject.Name }
    if ($newTagId -and $existingTagIds.Add($newTagId)) { $allTags.Add($NewTagObject) }

    # SPBM requires all tags in one AnyOfTags rule to be from the same category.
    $targetCategory = if ($NewTagObject.Category) {
        if ($NewTagObject.Category.Name) { $NewTagObject.Category.Name } else { $NewTagObject.Category }
    } else { $null }

    if ($targetCategory) {
        $filtered = @($allTags | Where-Object {
            $catName = if ($_.Category.Name) { $_.Category.Name } else { $_.Category }
            $catName -eq $targetCategory
        })
        if ($filtered.Count -lt $allTags.Count) {
            Write-LogMessage -Type DEBUG -Message "Filtered tag rule to category `"$targetCategory`" ($($filtered.Count) tag(s)); omitted $($allTags.Count - $filtered.Count) tag(s) from other categories."
        }
        $allTags = [System.Collections.Generic.List[object]]$filtered
    }

    if ($allTags.Count -gt 0) {
        try {
            return New-SpbmRule -AnyOfTags $allTags -Server $Script:vCenterName -ErrorAction Stop
        } catch [VcfDeploymentException] {
            throw
        } catch {
            Write-LogMessage -Type ERROR -Message "Failed to create combined tag rule with $($allTags.Count) tag(s): $($_.Exception.Message)"
            $details = $allTags | ForEach-Object { "Name=$($_.Name), Id=$($_.Id), Category=$($_.Category.Name)" }
            throw [VcfDeploymentException]::new("Failed to build combined tag rule. Tag details: $($details -join '; ')")
        }
    }

    # All existing tags were stale/filtered; fall back to the new tag rule only.
    Write-LogMessage -Type WARNING -Message "No valid tags found in existing tag rules (same category). Adding new tag rule separately."
    return New-SpbmRule -AnyOfTags $NewTagObject -Server $Script:vCenterName -ErrorAction Stop
}
function Set-StoragePolicy {

    <#
        .SYNOPSIS
        Creates or updates a tag-based storage policy for VMFS, vSAN-OSA, or vSAN-ESA datastores.

        .DESCRIPTION
        Idempotent create-or-update wrapper for VMware Storage Policy-Based Management (SPBM) policies.
        Resolves the tag and existing policy via Resolve-StoragePolicyTagContext, then takes one of
        three paths: (1) tag already present — returns immediately; (2) policy exists, tag absent —
        delegates to Add-StoragePolicyTagRule; (3) policy absent — creates the policy from scratch.

        For VMFS policies the rule set includes a volume allocation capability rule (default: "Fully
        initialized") combined with the tag rule. For vSAN-OSA and vSAN-ESA the rule set contains
        only the tag rule.

        .EXAMPLE
        Set-StoragePolicy -PolicyName "VMFS-Storage-Policy" -StorageType "VMFS" -RuleValue "Conserve space when possible" -TagName "Production" -TagCatalog "Environment"

        Creates a VMFS storage policy with a space conservation rule and Production tag requirement.

        .EXAMPLE
        Set-StoragePolicy -PolicyName "vSAN-ESA-Policy" -StorageType "vSAN-ESA" -TagName "Production" -TagCatalog "Environment"

        Creates a vSAN ESA storage policy with the Production tag requirement (no volume allocation rule).

        .EXAMPLE
        Set-StoragePolicy -PolicyName "VMFS-Storage-Policy" -StorageType "VMFS" -TagName "test-sn2" -TagCatalog "Site"

        Adds the tag "test-sn2" from catalog "Site" to the existing "VMFS-Storage-Policy" policy without removing existing tags.

        .PARAMETER PolicyName
        The name of the storage policy to create or update.

        .PARAMETER RuleValue
        Volume allocation rule for VMFS policies. Defaults to "Fully initialized". Ignored for vSAN.

        .PARAMETER StorageType
        Type of storage policy. Valid values: "VMFS", "vSAN-OSA", "vSAN-ESA".

        .PARAMETER TagCatalog
        Tag category name containing the required tag.

        .PARAMETER TagName
        Tag name to add. Must exist in TagCatalog before calling.

        .NOTES
        - Requires an active vCenter connection (validated via Test-VcenterConnection).
        - Tag and tag catalog must exist in vCenter before calling this function.
        - When updating an existing policy, stale " (missing)" tag references are normalized via Invoke-MergeTagRules.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$PolicyName,
        [Parameter(Mandatory = $false)] [ValidateSet("Conserve space when possible", "Fully initialized", "Reserve space")] [String]$RuleValue = "Fully initialized",
        [Parameter(Mandatory = $true)] [ValidateSet("VMFS", "vSAN-OSA", "vSAN-ESA")] [String]$StorageType,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$TagCatalog,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$TagName
    )

    Write-LogMessage -Type DEBUG -Message "Entered Set-StoragePolicy function..."

    # Storage policy creation runs after ESX and vLCM operations that can disrupt the vCenter
    # session. Reconnect first so transient session loss does not fail the policy creation step.
    Invoke-VcenterReconnectIfNeeded

    try {
        $context   = Resolve-StoragePolicyTagContext -PolicyName $PolicyName -Server $Script:vCenterName -TagCatalog $TagCatalog -TagName $TagName
        $tagObject = $context.TagObject
        $policy    = $context.ExistingPolicy

        if ($context.TagAlreadyPresent) {
            Write-LogMessage -Type DEBUG -Message "Storage policy `"$PolicyName`" already contains tag `"$TagName`" from catalog `"$TagCatalog`". Skipping tag add."
            return
        }

        if ($policy) {
            Add-StoragePolicyTagRule -PolicyName $PolicyName -StorageType $StorageType -RuleValue $RuleValue `
                -TagCatalog $TagCatalog -TagName $TagName -Policy $policy -TagObject $tagObject
        } else {
            $tagRule = New-SpbmRule -AnyOfTags $tagObject -Server $Script:vCenterName -ErrorAction Stop

            if ($StorageType -eq "VMFS") {
                $volumeAllocationCapability = Get-SpbmCapability -Name "com.vmware.storage.volumeallocation.VolumeAllocationType" -Server $Script:vCenterName -ErrorAction Stop
                $capabilityRule = New-SpbmRule -Capability $volumeAllocationCapability -Value $RuleValue -Server $Script:vCenterName -ErrorAction Stop
                $ruleSet        = New-SpbmRuleSet -AllOfRules $capabilityRule, $tagRule -ErrorAction Stop
                $description    = "$StorageType with $RuleValue"
            } else {
                $ruleSet     = New-SpbmRuleSet -AllOfRules $tagRule -ErrorAction Stop
                $description = "$StorageType tag-based policy"
            }

            New-SpbmStoragePolicy -Name $PolicyName -Description $description -AnyOfRuleSets $ruleSet -Server $Script:vCenterName | Out-Null

            $policyCreated = Get-SpbmStoragePolicy -Name $PolicyName -Server $Script:vCenterName -ErrorAction SilentlyContinue
            if ($policyCreated) {
                if ($StorageType -eq "VMFS") {
                    Write-LogMessage -Type INFO -Message "Successfully created storage policy `"$PolicyName`" for $StorageType with rule `"$RuleValue`"."
                } else {
                    Write-LogMessage -Type INFO -Message "Successfully created storage policy `"$PolicyName`" for $StorageType."
                }
            }
        }
    } catch [System.UnauthorizedAccessException] {
        $err = "Cannot create storage policy `"$PolicyName`" due to authorization issues: $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    } catch [System.TimeoutException] {
        $err = "Cannot create storage policy `"$PolicyName`" due to network/timeout issues: $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    } catch [VcfDeploymentException] {
        throw
    } catch {
        $err = "Failed to create storage policy `"$PolicyName`": $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
}
function Get-SupervisorControlPlaneIp {

    <#
        .SYNOPSIS
        Retrieves the IPv4 address of the Supervisor Control Plane VM in a specified cluster.

        .DESCRIPTION
        This function locates the Supervisor Control Plane VM within the specified vSphere cluster
        and returns its IPv4 address. The function searches for VMs with names containing
        "SupervisorControlPlane" and extracts the primary IPv4 address from the VM's guest information.

        .EXAMPLE
        Get-SupervisorControlPlaneIp -ClusterName "MyCluster"
        Returns the IPv4 address of the Supervisor Control Plane VM in the "MyCluster" cluster.

        .PARAMETER ClusterName
        The name of the vSphere cluster where the Supervisor Control Plane VM is hosted.
        This parameter is optional but recommended for targeted searches.

        .OUTPUTS
        System.String
        Returns the IPv4 address of the Supervisor Control Plane VM as a string.

        .NOTES
        - Requires an active connection to vCenter
        - The function will throw an exception if the VM cannot be found or accessed
        - Only returns IPv4 addresses (filters out IPv6 addresses)
        - If the VM has multiple IPv4 addresses, the function returns the first one and logs a warning
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$ClusterName
    )
    Write-LogMessage -Type DEBUG -Message "Entered Get-SupervisorControlPlaneIp function..."

    Assert-VcenterConnected

    try {
        $clusterObj = Get-Cluster -Name $ClusterName -Server $Script:vCenterName -ErrorAction Stop
        $controlPlaneVMs = Get-VmsFromCluster -ClusterObject $clusterObj |
            Where-Object { $_.Name -like "*SupervisorControlPlane*" }

        $controlPlaneVMsArray = @($controlPlaneVMs)
        if ($controlPlaneVMsArray.Count -eq 0) {
            $err = "No Supervisor Control Plane VM found in cluster `"$ClusterName`""
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
        if ($controlPlaneVMsArray.Count -gt 1) {
            Write-LogMessage -Type WARNING -Message "Multiple Supervisor Control Plane VMs found in cluster `"$ClusterName`" ($($controlPlaneVMsArray.Count)). Using the first one: $($controlPlaneVMsArray[0].Name)"
        }
        $controlPlaneVM = $controlPlaneVMsArray[0]

        $vmView = Get-VmViewForVm -VmObject $controlPlaneVM

        # @() forces an array so single-item results are not unwrapped by the pipeline.
        $ipAddresses = @($vmView.Guest.IPAddress | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' })
        if ($ipAddresses.Count -eq 0) {
            $err = "No IPv4 address found for Supervisor Control Plane VM `"$($controlPlaneVM.Name)`" in cluster `"$ClusterName`""
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
        if ($ipAddresses.Count -gt 1) {
            Write-LogMessage -Type WARNING -Message "Supervisor Control Plane VM `"$($controlPlaneVM.Name)`" has multiple IPv4 addresses: $($ipAddresses -join ', '). Using the first one: $($ipAddresses[0])"
        }
        $ip = $ipAddresses[0]
        Write-LogMessage -Type DEBUG -Message "Selected Supervisor Control Plane IP: $ip"
        return $ip

    } catch [System.UnauthorizedAccessException] {
        $err = "Cannot fetch Supervisor Control Plane VM details on cluster `"$ClusterName`" attached to vCenter `"$Script:vCenterName`" due to authorization issues: $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
    catch [System.TimeoutException] {
        $err = "Cannot fetch Supervisor Control Plane VM details on cluster `"$ClusterName`" attached to vCenter `"$Script:vCenterName`" due to network/timeout issues: $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    } catch [VcfDeploymentException] {
        throw  # already logged and typed — propagate without re-wrapping
    } catch {
        $err = "Supervisor Control Plane VM details on cluster `"$ClusterName`" attached to vCenter `"$Script:vCenterName`" could not be fetched: $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
}
function Invoke-VcfContextDelete {

    <#
        .SYNOPSIS
        Deletes a VCF CLI context, verifying deletion and force-retrying if the context persists.

        .DESCRIPTION
        Issues `vcf context delete`, waits RetryDelaySeconds, then queries `vcf context list` to
        confirm removal. If the context is still present, a second forced delete is issued and
        another sleep applied. Tolerates "not found" from the VCF CLI without error.

        .PARAMETER ContextName
        The VCF context name to delete.

        .PARAMETER RetryDelaySeconds
        Seconds to wait after the initial delete before checking the context list. Default is 1.

        .NOTES
        Helper extracted from Set-VCFContextCreate to satisfy the 80-line body limit.
    
        .EXAMPLE
        Invoke-VcfContextDelete -ContextName "resource-name"
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ContextName,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 60)] [Int]$RetryDelaySeconds = 1
    )

    Write-LogMessage -Type DEBUG -Message "Deleting VCF context `"$ContextName`" (if it exists)..."
    $deleteArgs = @("context", "delete", $ContextName, "-y")
    Write-LogMessage -Type DEBUG -Message "VCF CLI delete command: $($Script:VcfCmd) $($deleteArgs -join ' ')"
    $deleteOutput = & $Script:VcfCmd $deleteArgs 2>&1
    Write-LogMessage -Type DEBUG -Message "Context delete exit code: $LASTEXITCODE"
    $deleteOutputText = ($deleteOutput | Where-Object { $_ -is [string] }) -join "`n"
    if ($deleteOutputText) {
        Write-LogMessage -Type DEBUG -Message "Context delete output: $deleteOutputText"
    }

    Start-Sleep -Seconds $RetryDelaySeconds
    $listOutput = & $Script:VcfCmd context list -o json 2>&1
    if ($LASTEXITCODE -ne 0 -or -not $listOutput) {
        Write-LogMessage -Type DEBUG -Message "Could not verify context deletion (exit code: $LASTEXITCODE). Assuming deletion succeeded."
        return
    }
    $contextListJson = ($listOutput | Where-Object { $_ -is [string] }) -join "`n" | ConvertFrom-Json
    $existingContext = $contextListJson | Where-Object { $_.name -eq $ContextName } | Select-Object -First 1
    if (-not $existingContext) {
        Write-LogMessage -Type DEBUG -Message "Context `"$ContextName`" verified as deleted."
        return
    }
    Write-LogMessage -Type WARNING -Message "Context `"$ContextName`" still exists after deletion. Attempting force deletion..."
    $forceDeleteOutput = & $Script:VcfCmd context delete $ContextName -y 2>&1
    Write-LogMessage -Type DEBUG -Message "Force delete exit code: $LASTEXITCODE"
    $forceDeleteOutputText = ($forceDeleteOutput | Where-Object { $_ -is [string] }) -join "`n"
    if ($forceDeleteOutputText) {
        Write-LogMessage -Type DEBUG -Message "Force delete output: $forceDeleteOutputText"
    }
    Start-Sleep -Seconds $RetryDelaySeconds
}
function Invoke-VcfContextCreate {

    <#
        .SYNOPSIS
        Creates a VCF CLI context and throws if creation fails or authentication is partial.

        .DESCRIPTION
        Runs `vcf context create` with the specified endpoint and SSO username. Fails hard
        (throws VcfDeploymentException) on non-zero exit, on "unable to identify the context
        type" errors (supervisor unreachable), and on partial-login output ("Not all cluster/workload
        sessions were established"). On partial login, probes each failed supervisor IP on TCP 443
        via Test-TcpPortReachable and includes reachability data in the log.

        .PARAMETER ContextName
        The VCF context name to create.

        .PARAMETER Endpoint
        The Supervisor Control Plane IP or FQDN.

        .PARAMETER InsecureTls
        When set, appends --insecure-skip-tls-verify to the create command.

        .PARAMETER SsoUsername
        SSO username for authentication.

        .NOTES
        Helper extracted from Set-VCFContextCreate to satisfy the 80-line body limit.
    
        .EXAMPLE
        Invoke-VcfContextCreate -ContextName "resource-name" -Endpoint "value" -SsoUsername "resource-name"
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ContextName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Endpoint,
        [Parameter(Mandatory = $false)] [Switch]$InsecureTls,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SsoUsername
    )

    Write-LogMessage -Type INFO -Message "Creating VCF context `"$ContextName`" with endpoint `"$Endpoint`"..."
    $createArgs = @("context", "create", $ContextName, "--endpoint", $Endpoint, "--username", $SsoUsername)
    if ($InsecureTls) { $createArgs += "--insecure-skip-tls-verify" }
    Write-LogMessage -Type DEBUG -Message "VCF CLI command: $($Script:VcfCmd) $($createArgs -join ' ')"

    $errorOutput = $null
    $createOutput = & $Script:VcfCmd $createArgs 2>&1 | Tee-Object -Variable errorOutput
    $createExitCode = $LASTEXITCODE
    Write-LogMessage -Type DEBUG -Message "VCF CLI context create exit code: $createExitCode"
    $createOutputText = ($createOutput | Where-Object { $_ -is [string] }) -join "`n"
    if ($createOutputText) {
        Write-LogMessage -Type DEBUG -Message "VCF CLI context create output: $createOutputText"
    }

    if ($createExitCode -ne 0) {
        $errorMessage = ($errorOutput | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] -or ($_ -is [string] -and $_ -match "error|unable") }) -join " "
        if ($errorMessage -match "unable to identify the context type") {
            $err = "Unable to create VCF context `"$ContextName`". The supervisor endpoint `"$Endpoint`" may not be available."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
        $err = "Failed to create VCF context `"$ContextName`": $errorMessage"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }

    # Exit code 0 does not guarantee full login; detect partial-login output and fail hard.
    if ($createOutputText -match "Not all cluster/workload sessions were established" -or
        $createOutputText -match "Login failed for the following") {
        Write-LogMessage -Type ERROR -Message "VCF CLI context `"$ContextName`" was partially created but authentication to the supervisor cluster at `"$Endpoint`" failed. Check network connectivity and credentials."
        Write-LogMessage -Type DEBUG -Message "Partial login failure output:`n$createOutputText"
        $failedIpPattern = "Failed to login to supervisor cluster using\s+(\d{1,3}(?:\.\d{1,3}){3})"
        $reachabilityLines = [System.Collections.Generic.List[String]]::new()
        foreach ($match in [System.Text.RegularExpressions.Regex]::Matches($createOutputText, $failedIpPattern)) {
            $failedIp = $match.Groups[1].Value
            $reachable = Test-TcpPortReachable -IpAddress $failedIp -Port 443
            $status = if ($reachable) { "reachable (TCP 443 OK — may be a credentials issue)" } else { "UNREACHABLE on TCP 443 — check routing/firewall from this host" }
            $reachabilityLines.Add("  $failedIp : $status")
        }
        if ($reachabilityLines.Count -gt 0) {
            Write-LogMessage -Type WARNING -Message "Supervisor node reachability check:`n$($reachabilityLines -join "`n")"
        }
        throw [VcfDeploymentException]::new("Deployment failed. Supervisor authentication failed. Check logs for details.")
    }
}
function Invoke-VcfContextVerifyAndSwitch {

    <#
        .SYNOPSIS
        Verifies a VCF context appears in the context list then switches to it.

        .DESCRIPTION
        Queries `vcf context list` to confirm the named context was created, then issues
        `vcf context use`. When Namespace is provided, tries the namespace-scoped context
        (ContextName:Namespace) first and falls back to the base context on failure.
        VCF CLI may return exit code 1 even on successful activation when ClusterDomainResolutionEntry
        is absent; "Successfully activated" in the output is treated as success regardless of exit code.
        Returns a Write-ErrorAndReturn result (non-throwing) if the switch ultimately fails.

        .PARAMETER ContextName
        The VCF context name to verify and switch to.

        .PARAMETER InsecureTls
        When set, appends --insecure-skip-tls-verify to the context use command.

        .PARAMETER Namespace
        Optional. When provided, the function first attempts to switch to ContextName:Namespace,
        then falls back to the base ContextName.

        .NOTES
        Helper extracted from Set-VCFContextCreate to satisfy the 80-line body limit.
    
        .EXAMPLE
        Invoke-VcfContextVerifyAndSwitch -ContextName "resource-name"
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ContextName,
        [Parameter(Mandatory = $false)] [Switch]$InsecureTls,
        [Parameter(Mandatory = $false)] [String]$Namespace
    )

    Write-LogMessage -Type DEBUG -Message "Verifying VCF context `"$ContextName`" was created..."
    $listOutput = & $Script:VcfCmd context list -o json 2>&1
    if ($LASTEXITCODE -ne 0) {
        $err = "Failed to list VCF contexts to verify creation (exit code: $LASTEXITCODE)."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
    $jsonObject = ($listOutput | Where-Object { $_ -is [string] }) -join "`n" | ConvertFrom-Json
    $contextFound = $jsonObject | Where-Object { $_.name -eq $ContextName } | Select-Object -First 1
    if (-not $contextFound) {
        $err = "VCF context `"$ContextName`" creation failed - context not found after creation."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
    Write-LogMessage -Type INFO -Message "VCF context `"$ContextName`" created successfully."

    # Hoist flag computation above the context-switch calls so it is not repeated per call.
    $tlsArgs = @(if ($InsecureTls) { "--insecure-skip-tls-verify" })
    $contextUseTarget = if (-not [String]::IsNullOrWhiteSpace($Namespace)) { "${ContextName}:$Namespace" } else { $ContextName }
    Write-LogMessage -Type INFO -Message "Switching to VCF context `"$contextUseTarget`"..."
    $contextUseOutput = & $Script:VcfCmd context use $contextUseTarget @tlsArgs 2>&1
    $contextUseExitCode = $LASTEXITCODE
    $contextUseOutputText = ($contextUseOutput | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.ToString() } else { [String]$_ }
    }) -join "`n"
    if ($contextUseOutputText) { Write-LogMessage -Type DEBUG -Message "Context use output: $contextUseOutputText" }

    if ($contextUseExitCode -ne 0 -and -not [String]::IsNullOrWhiteSpace($Namespace)) {
        $contextUseTarget = $ContextName
        Write-LogMessage -Type DEBUG -Message "Namespace-scoped context switch failed. Trying base context `"$contextUseTarget`"..."
        $contextUseOutput = & $Script:VcfCmd context use $contextUseTarget @tlsArgs 2>&1
        $contextUseExitCode = $LASTEXITCODE
        $contextUseOutputText = ($contextUseOutput | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.ToString() } else { [String]$_ }
        }) -join "`n"
        if ($contextUseOutputText) { Write-LogMessage -Type DEBUG -Message "Context use (base) output: $contextUseOutputText" }
    }

    if ($contextUseExitCode -ne 0) {
        # VCF CLI may return exit code 1 but still activate when ClusterDomainResolutionEntry is absent.
        if ($contextUseOutputText -match "Successfully activated") {
            Write-LogMessage -Type INFO -Message "VCF context `"$contextUseTarget`" activated successfully."
            Write-LogMessage -Type DEBUG -Message "VCF context `"$contextUseTarget`" activated (output shows Successfully activated) but CLI returned exit code $contextUseExitCode. This can occur when ClusterDomainResolutionEntry is not present in the cluster."
            return
        }
        $contextUseError = ($contextUseOutput | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.ToString() } else { [String]$_ }
        } | Where-Object { $_ -match "error|unable|cannot" }) -join " "
        $errorMessage = if ($contextUseError) {
            "Failed to switch to VCF context `"$contextUseTarget`": $contextUseError"
        } else {
            "Failed to switch to VCF context `"$contextUseTarget`" (exit code: $contextUseExitCode). Check DEBUG log for context use output."
        }
        Write-LogMessage -Type ERROR -Message $errorMessage
        return Write-ErrorAndReturn -ErrorMessage "Failed to switch to VCF context `"$contextUseTarget`"" -ErrorCode "ERR_VCF_CONTEXT"
    }
}
function Set-VCFContextCreate {

    <#
        .SYNOPSIS
        Creates and configures a VCF CLI context for connecting to Supervisor Control Plane VM with SSO authentication.

        .DESCRIPTION
        The Set-VCFContextCreate function establishes a VCF CLI context to communicate with a Kubernetes
        Supervisor Control Plane VM using SSO authentication. For each site iteration, the context is
        deleted (if it exists) and recreated with the specified endpoint to ensure the correct endpoint is used.

        Key features:
        - Always deletes the context before creating (ensures correct endpoint for each site)
        - Creates VCF CLI context with SSO authentication
        - Supports optional TLS certificate verification bypass
        - Validates context creation through simple retry logic
        - Automatically switches to the new context after creation

        .PARAMETER ContextName
        The name of the VCF context to create.

        .PARAMETER Endpoint
        The IP address or FQDN of the Supervisor Control Plane VM.

        .PARAMETER SsoUsername
        The SSO username for authentication with the Supervisor Control Plane.

        .PARAMETER InsecureTls
        Optional switch parameter that bypasses TLS certificate verification.

        .PARAMETER Namespace
        Optional namespace (e.g. argocd-c180). If provided and switching to the base context fails,
        the function will try switching to the namespace-scoped context (ContextName:Namespace) so
        subsequent kubectl operations target the correct namespace.

        .PARAMETER RetryDelaySeconds
        Seconds to wait after deleting the old context before verifying its removal. Default is 1.

        .EXAMPLE
        Set-VCFContextCreate -ContextName "vcf-lab-ctx" -Endpoint "10.1.1.100" -SsoUsername "admin@vsphere.local"

        .NOTES
        - Requires VCF CLI tool to be installed and available in the system PATH
        - The context is always deleted before creation to ensure the correct endpoint is used
        - This pattern (delete -> create) is repeated for each site in multi-site deployments
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ContextName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Endpoint,
        [Parameter(Mandatory = $false)] [Switch]$InsecureTls,
        [Parameter(Mandatory = $false)] [String]$Namespace,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 60)] [Int]$RetryDelaySeconds = 1,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SsoUsername
    )

    Write-LogMessage -Type DEBUG -Message "Entered Set-VCFContextCreate function..."
    Write-LogMessage -Type DEBUG -Message "Context name: `"$ContextName`"; endpoint: `"$Endpoint`"; SSO username: `"$SsoUsername`""
    if (-not [String]::IsNullOrWhiteSpace($Namespace)) {
        Write-LogMessage -Type DEBUG -Message "Namespace (for context switch): `"$Namespace`""
    }

    try {
        Invoke-VcfContextDelete -ContextName $ContextName -RetryDelaySeconds $RetryDelaySeconds
        Invoke-VcfContextCreate -ContextName $ContextName -Endpoint $Endpoint -SsoUsername $SsoUsername -InsecureTls:$InsecureTls.IsPresent
        Invoke-VcfContextVerifyAndSwitch -ContextName $ContextName -Namespace $Namespace -InsecureTls:$InsecureTls.IsPresent
        Write-LogMessage -Type DEBUG -Message "Set-VCFContextCreate completed successfully."
    } catch [VcfDeploymentException] {
        throw  # already logged and typed — propagate without re-wrapping
    } catch {
        $err = "Failed to create or configure VCF context `"$ContextName`": $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
}
function Test-WebhookServiceReady {

    <#
        .SYNOPSIS
        Checks if the ArgoCD operator webhook service is ready with active endpoints.

        .DESCRIPTION
        The Test-WebhookServiceReady function checks if the webhook service exists and has
        active endpoints (pods backing it). This is used to verify the webhook service
        is ready before attempting to create ArgoCD instances. The function properly handles
        Kubernetes endpoints structure by iterating through subsets and counting addresses
        across all subsets, with comprehensive null checks at each level.

        .PARAMETER ServiceNamespace
        The Kubernetes namespace where the webhook service is deployed.

        .PARAMETER ServiceName
        The name of the webhook service. Defaults to "argocd-service-webhook-service".

        .OUTPUTS
        System.Boolean
        Returns $true if the webhook service exists and has active endpoints, $false otherwise.

        .NOTES
        This function uses kubectl to query the service and endpoints. Errors are caught
        and logged at DEBUG level, returning $false to allow retry logic. The function
        includes DEBUG-level diagnostic messages indicating why the service is not ready
        (endpoints resource missing, no subsets, or no addresses) to aid troubleshooting.
    
        .EXAMPLE
        Test-WebhookServiceReady -ServiceNamespace "argocd"
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$ServiceName = "argocd-service-webhook-service",
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ServiceNamespace
    )

    try {
        # Capture both stdout and stderr to detect connection/context errors.
        $webhookServiceOutput = & $Script:KubectlCmd get service "$ServiceName" -n "$ServiceNamespace" -o json 2>&1
        $kubectlExitCode = $LASTEXITCODE

        # Check for common errors that indicate context or connection issues.
        if ($kubectlExitCode -ne 0) {
            $errorText = ($webhookServiceOutput | Where-Object { $_ -is [string] }) -join " "
            switch -Regex ($errorText) {
                "context deadline exceeded|connection refused|no such host|Unable to connect|dial tcp.*connection refused|connection.*timed out|The connection to the server.*was refused|Unable to connect to the server" {
                    Write-LogMessage -Type WARNING -Message "kubectl connection error accessing service (exit code: $kubectlExitCode): $errorText. This may indicate kubectl context is not properly configured for this cluster or the cluster is not accessible."
                    break
                }
                "not found|does not exist|NotFound" {
                    Write-LogMessage -Type DEBUG -Message "Webhook service `"$ServiceName`" not found in namespace `"$ServiceNamespace`"."
                    break
                }
                default {
                    Write-LogMessage -Type DEBUG -Message "kubectl error checking webhook service (exit code: $kubectlExitCode): $errorText"
                }
            }
            return $false
        }

        $webhookService = $webhookServiceOutput | ConvertFrom-Json

        if (-not $webhookService) {
            return $false
        }

        # Service exists, now check if it has endpoints (pods backing it).
        $webhookEndpointsOutput = & $Script:KubectlCmd get endpoints "$ServiceName" -n "$ServiceNamespace" -o json 2>&1
        $endpointsExitCode = $LASTEXITCODE

        if ($endpointsExitCode -ne 0) {
            $errorText = ($webhookEndpointsOutput | Where-Object { $_ -is [string] }) -join " "
            switch -Regex ($errorText) {
                "context deadline exceeded|connection refused|no such host|Unable to connect|dial tcp.*connection refused|connection.*timed out|The connection to the server.*was refused|Unable to connect to the server" {
                    Write-LogMessage -Type WARNING -Message "kubectl connection error accessing endpoints (exit code: $endpointsExitCode): $errorText. This may indicate kubectl context is not properly configured for this cluster or the cluster is not accessible."
                    break
                }
                "not found|does not exist|NotFound" {
                    Write-LogMessage -Type DEBUG -Message "Webhook endpoints resource not found for service `"$ServiceName`" in namespace `"$ServiceNamespace`"."
                    break
                }
                default {
                    Write-LogMessage -Type DEBUG -Message "kubectl error checking webhook endpoints (exit code: $endpointsExitCode): $errorText"
                }
            }
            return $false
        }

        $webhookEndpoints = $webhookEndpointsOutput | ConvertFrom-Json

        if (-not $webhookEndpoints) {
            Write-LogMessage -Type DEBUG -Message "Webhook endpoints resource not found for service `"$ServiceName`" in namespace `"$ServiceNamespace`"."
            return $false
        }

        return Test-WebhookEndpointAddressCount -ServiceName $ServiceName -WebhookEndpoints $webhookEndpoints
    } catch {
        Write-LogMessage -Type DEBUG -Message "Error checking webhook service: $($_.Exception.Message). Continuing to wait..."
        return $false
    }
}
function Test-WebhookEndpointAddressCount {

    <#
        .SYNOPSIS
        Returns whether a kubectl endpoint object has at least one ready address across all subsets.

        .DESCRIPTION
        Iterates the subsets array of a Kubernetes endpoint object and sums ready addresses.
        Returns $true when any address is found, $false when subsets are absent or empty.

        .PARAMETER ServiceName
        Service display name used only in log messages.

        .PARAMETER WebhookEndpoints
        Kubernetes endpoint object returned by `kubectl get endpoints -o json | ConvertFrom-Json`.

        .EXAMPLE
        $ready = Test-WebhookEndpointAddressCount -ServiceName "argocd-service-webhook-service" -WebhookEndpoints $endpointsObj

        .NOTES
        Called by Test-WebhookServiceReady after the endpoint object is confirmed non-null.
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ServiceName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$WebhookEndpoints
    )

    if (-not $WebhookEndpoints.subsets -or $WebhookEndpoints.subsets.Count -eq 0) {
        Write-LogMessage -Type DEBUG -Message "Webhook service `"$ServiceName`" exists but has no subsets (no pod endpoints yet)."
        return $false
    }
    $totalAddresses = 0
    foreach ($subset in $WebhookEndpoints.subsets) {
        if ($subset.addresses -and $subset.addresses.Count -gt 0) {
            $totalAddresses += $subset.addresses.Count
        }
    }
    if ($totalAddresses -gt 0) {
        Write-LogMessage -Type INFO -Message "ArgoCD operator webhook service is ready with $totalAddresses endpoint(s)."
        return $true
    }
    Write-LogMessage -Type DEBUG -Message "Webhook service `"$ServiceName`" has subsets but no addresses (pods may not be ready yet)."
    return $false
}
function Invoke-WebhookPreflightCheck {

    <#
        .SYNOPSIS
        Verifies kubectl can access the cluster before starting the webhook readiness wait loop.

        .DESCRIPTION
        Runs kubectl cluster-info and logs a warning if the command fails or kubectl is unavailable.
        This is a non-fatal check — the caller proceeds regardless of the result.

        .EXAMPLE
        Invoke-WebhookPreflightCheck
    #>

    [CmdletBinding()]
    Param ()

    Write-LogMessage -Type DEBUG -Message "Pre-flight check: Verifying kubectl can access cluster..."
    try {
        $preflightCheck = & $Script:KubectlCmd cluster-info 2>&1
        if ($LASTEXITCODE -ne 0) {
            $preflightError = ($preflightCheck | Where-Object { $_ -is [string] }) -join " "
            Write-LogMessage -Type WARNING -Message "Pre-flight check failed: kubectl cluster-info returned error (exit code: $LASTEXITCODE): $preflightError"
            Write-LogMessage -Type WARNING -Message "This may indicate the kubectl context is not properly configured. The webhook check will proceed but may fail."
        } else {
            Write-LogMessage -Type DEBUG -Message "Pre-flight check passed: kubectl can access cluster."
        }
    } catch {
        Write-LogMessage -Type WARNING -Message "Pre-flight check: kubectl not found or not executable. The webhook readiness check will proceed without a cluster-info confirmation. Error: $($_.Exception.Message)"
    }
}
function Write-WebhookTimeoutDiagnostics {

    <#
        .SYNOPSIS
        Emits kubectl diagnostic output after a webhook readiness timeout.

        .DESCRIPTION
        Runs kubectl commands to gather context, cluster-info, pod list, and namespace existence
        in the operator namespace, logging each result. Called from both timeout paths in
        Invoke-WebhookReadinessPoll. Errors from kubectl being unavailable are caught and
        a single WARNING is logged instead.

        .PARAMETER ServiceNamespace
        The Kubernetes namespace to inspect for diagnostic output.

        .EXAMPLE
        Write-WebhookTimeoutDiagnostics -ServiceNamespace "argocd-operator"
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ServiceNamespace
    )

    try {
        Write-LogMessage -Type INFO -Message "Diagnostic: Checking kubectl context and cluster access..."
        $kubectlContext = & $Script:KubectlCmd config current-context 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-LogMessage -Type INFO -Message "Current kubectl context: $kubectlContext"
        } else {
            Write-LogMessage -Type WARNING -Message "Could not determine current kubectl context. This may indicate kubectl is not properly configured."
        }

        $clusterInfo = & $Script:KubectlCmd cluster-info 2>&1
        if ($LASTEXITCODE -eq 0) {
            $clusterInfoText = ($clusterInfo | Where-Object { $_ -is [string] }) -join " "
            Write-LogMessage -Type INFO -Message "kubectl cluster-info: $clusterInfoText"
        } else {
            $clusterError = ($clusterInfo | Where-Object { $_ -is [string] }) -join " "
            Write-LogMessage -Type WARNING -Message "kubectl cluster-info failed: $clusterError. This may indicate the kubectl context is not properly configured for this cluster."
        }

        Write-LogMessage -Type INFO -Message "Diagnostic: Checking pods in operator namespace `"$ServiceNamespace`"..."
        $operatorPodsOutput = & $Script:KubectlCmd get pods -n "$ServiceNamespace" -o json 2>&1
        if ($LASTEXITCODE -eq 0) {
            $operatorPods = $operatorPodsOutput | ConvertFrom-Json
            if ($operatorPods.items.Count -gt 0) {
                Write-LogMessage -Type INFO -Message "Found $($operatorPods.items.Count) pod(s) in namespace `"$ServiceNamespace`":"
                foreach ($pod in $operatorPods.items) {
                    Write-LogMessage -Type INFO -Message "  - Pod: $($pod.metadata.name), Phase: $($pod.status.phase)"
                }
            } else {
                Write-LogMessage -Type ERROR -Message "No pods found in namespace `"$ServiceNamespace`". The operator may not have been installed successfully."
            }
        } else {
            $podsError = ($operatorPodsOutput | Where-Object { $_ -is [string] }) -join " "
            Write-LogMessage -Type WARNING -Message "Could not retrieve pods from namespace `"$ServiceNamespace`": $podsError. This may indicate kubectl context issues."
        }

        Write-LogMessage -Type INFO -Message "Diagnostic: Verifying namespace `"$ServiceNamespace`" exists..."
        $namespaceCheck = & $Script:KubectlCmd get namespace "$ServiceNamespace" -o json 2>$null | ConvertFrom-Json
        if (-not $namespaceCheck) {
            Write-LogMessage -Type ERROR -Message "Namespace `"$ServiceNamespace`" does not exist. The ArgoCD operator installation failed."
        } else {
            Write-LogMessage -Type INFO -Message "Namespace `"$ServiceNamespace`" exists."
        }
    } catch {
        Write-LogMessage -Type WARNING -Message "Webhook timeout diagnostics skipped: kubectl not found or not executable. Error: $($_.Exception.Message)"
    }
}
function Invoke-WebhookReadinessPoll {

    <#
        .SYNOPSIS
        Polls the ArgoCD operator webhook service until it becomes ready or the timeout elapses.

        .DESCRIPTION
        Runs a do...while loop calling Test-WebhookServiceReady on each iteration. Shows Write-Progress
        during the wait. On timeout (either in-loop detection or post-loop safety break), emits
        Write-WebhookTimeoutDiagnostics and returns $false. Returns $true when the service
        becomes ready.

        .PARAMETER CheckInterval
        Seconds to sleep between readiness checks. Defaults to 5.

        .PARAMETER ServiceName
        Name of the webhook service to check.

        .PARAMETER ServiceNamespace
        Kubernetes namespace containing the webhook service.

        .PARAMETER TimeoutSeconds
        Maximum seconds to wait before returning $false. Defaults to 1200.

        .PARAMETER WaitStartTime
        The DateTime at which the outer wait loop began. Used to compute elapsed time and
        percentage complete for Write-Progress.

        .OUTPUTS
        Bool
        Returns $true when the service is ready, $false on timeout.

        .EXAMPLE
        $startTime = Get-Date
        $ready = Invoke-WebhookReadinessPoll -ServiceNamespace "argocd-operator" -ServiceName "argocd-service-webhook-service" -CheckInterval 5 -TimeoutSeconds 60 -WaitStartTime $startTime
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(1, [Int]::MaxValue)] [Int]$CheckInterval = 5,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ServiceName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ServiceNamespace,
        [Parameter(Mandatory = $false)] [ValidateRange(1, [Int]::MaxValue)] [Int]$TimeoutSeconds = 1200,
        [Parameter(Mandatory = $true)] [DateTime]$WaitStartTime
    )

    $webhookReady = $false
    do {
        $webhookReady = Test-WebhookServiceReady -ServiceNamespace $ServiceNamespace -ServiceName $ServiceName

        if (-not $webhookReady) {
            $currentElapsed = ((Get-Date) - $WaitStartTime).TotalSeconds
            $percentComplete = [Math]::Min(99, [int](($currentElapsed / $TimeoutSeconds) * 100))
            $statusMessage = "Elapsed: $([Math]::Floor($currentElapsed)) seconds - Checking webhook service..."
            Write-Progress -Activity "Waiting for ArgoCD operator webhook service to be ready" -Status $statusMessage -PercentComplete $percentComplete
            [Console]::Out.Flush()
            Start-Sleep $CheckInterval
        }

        $currentElapsed = ((Get-Date) - $WaitStartTime).TotalSeconds
        if ($currentElapsed -ge $TimeoutSeconds -and -not $webhookReady) {
            Write-Progress -Activity "Waiting for ArgoCD operator webhook service to be ready" -Status "Timeout" -Completed
            [Console]::Out.Flush()
            Write-LogMessage -Type ERROR -Message "Timeout waiting for ArgoCD operator webhook service after $TimeoutSeconds seconds."
            Write-LogMessage -Type ERROR -Message "The webhook service may not be properly installed in namespace `"$ServiceNamespace`"."
            Write-WebhookTimeoutDiagnostics -ServiceNamespace $ServiceNamespace
            $totalElapsedTime = (Get-Date) - $WaitStartTime
            Write-LogMessage -Type DEBUG -Message "Invoke-WebhookReadinessPoll completed after $($totalElapsedTime.TotalSeconds.ToString('F3')) seconds (in-loop timeout reached)."
            return $false
        }

        $currentElapsed = ((Get-Date) - $WaitStartTime).TotalSeconds
        if ($currentElapsed -ge $TimeoutSeconds) {
            break
        }
    } while (-not $webhookReady)

    if (-not $webhookReady) {
        Write-Progress -Activity "Waiting for ArgoCD operator webhook service to be ready" -Status "Timeout" -Completed
        [Console]::Out.Flush()
        $totalElapsedTime = (Get-Date) - $WaitStartTime
        Write-LogMessage -Type ERROR -Message "Timeout waiting for ArgoCD operator webhook service after $($totalElapsedTime.TotalSeconds.ToString('F2')) seconds."
        Write-LogMessage -Type ERROR -Message "The webhook service may not be properly installed in namespace `"$ServiceNamespace`"."
        Write-WebhookTimeoutDiagnostics -ServiceNamespace $ServiceNamespace
        return $false
    }

    Write-Progress -Activity "Waiting for ArgoCD operator webhook service to be ready" -Status "Ready" -Completed
    [Console]::Out.Flush()
    return $true
}
function Wait-WebhookServiceReady {

    <#
        .SYNOPSIS
        Waits for the ArgoCD operator webhook service to become ready.

        .DESCRIPTION
        The Wait-WebhookServiceReady function polls the webhook service until it becomes
        ready with active endpoints, or until a timeout is reached. This function provides
        diagnostic information if the timeout is reached.

        .PARAMETER ServiceNamespace
        The Kubernetes namespace where the webhook service is deployed.

        .PARAMETER ServiceName
        The name of the webhook service. Defaults to "argocd-service-webhook-service".

        .PARAMETER CheckInterval
        Interval between webhook service availability checks, in seconds. Defaults to 5 seconds.

        .PARAMETER TimeoutSeconds
        Maximum time to wait for webhook service readiness, in seconds. Defaults to 1200 seconds.

        .OUTPUTS
        PSCustomObject
        Returns an object with Success property indicating if the webhook service became ready.

        .NOTES
        This function will return an error result if the timeout is reached, including
        diagnostic information about pods and namespace status.
    
        .EXAMPLE
        Wait-WebhookServiceReady -ServiceNamespace "argocd"
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(1, [Int]::MaxValue)] [Int]$CheckInterval = 5,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$ServiceName = "argocd-service-webhook-service",
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ServiceNamespace,
        [Parameter(Mandatory = $false)] [ValidateRange(1, [Int]::MaxValue)] [Int]$TimeoutSeconds = 1200
    )

    Write-LogMessage -Type INFO -Message "Waiting for ArgoCD operator webhook service to be ready (timeout: $TimeoutSeconds seconds)..."
    Invoke-WebhookPreflightCheck
    $startTime = Get-Date
    $webhookReady = Invoke-WebhookReadinessPoll -ServiceNamespace $ServiceNamespace -ServiceName $ServiceName -CheckInterval $CheckInterval -TimeoutSeconds $TimeoutSeconds -WaitStartTime $startTime

    if (-not $webhookReady) {
        return Write-ErrorAndReturn -ErrorMessage "ArgoCD operator webhook service not ready after $TimeoutSeconds seconds" -ErrorCode "ERR_WEBHOOK_TIMEOUT"
    }

    Write-Progress -Activity "Waiting for ArgoCD operator webhook service to be ready" -Status "Complete" -PercentComplete 100 -Completed
    [Console]::Out.Flush()
    $totalElapsedTime = (Get-Date) - $startTime
    Write-LogMessage -Type DEBUG -Message "Wait-WebhookServiceReady completed successfully in $($totalElapsedTime.TotalSeconds.ToString('F3')) seconds."

    return [PSCustomObject]@{
        Success      = $true
        ErrorMessage = $null
        ErrorCode    = $null
    }
}
function Get-PodReadinessStatus {

    <#
        .SYNOPSIS
        Retrieves the readiness status of pods in a Kubernetes namespace.

        .DESCRIPTION
        The Get-PodReadinessStatus function queries kubectl to get pod status information
        and returns a structured object with total pod count, ready pod count, and readiness
        status. This function is used to monitor pod deployment progress.

        .PARAMETER Namespace
        The Kubernetes namespace to query for pods.

        .OUTPUTS
        PSCustomObject
        Returns an object with the following properties:
        - TotalPods: Total number of pods in the namespace
        - ReadyPods: Number of pods in Running or Succeeded state
        - AllReady: Boolean indicating if all pods are ready
        - ReadyPodObjects: Array of pod objects in Running or Succeeded state

        .NOTES
        Pods are considered ready if their phase is "Running" or "Succeeded".

    
        .EXAMPLE
        $podReadinessStatus = Get-PodReadinessStatus -Namespace "argocd"
    #>

    [CmdletBinding()]
    [OutputType([Hashtable])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Namespace
    )

    $emptyResult = @{ TotalPods = 0; ReadyPods = 0; AllReady = $false; ReadyPodObjects = @() }

    # Guard the kubectl call so a transient connectivity failure (wrong context, network blip, expired
    # kubeconfig) returns a safe empty result instead of propagating a ConvertFrom-Json ParseException
    # into the caller's poll loop and terminating the deployment.
    # Note: $LASTEXITCODE is only set by external executables (e.g. the real kubectl binary).
    # When $Script:KubectlCmd resolves to a .ps1 script (e.g. in tests), $LASTEXITCODE stays $null.
    # Use $null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0 to guard only real non-zero exit codes.
    $rawOutput = & $Script:KubectlCmd get pods -n "$Namespace" -o json 2>&1
    if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        $errorText = ($rawOutput | Where-Object { $_ -is [String] }) -join " "
        Write-LogMessage -Type WARNING -Message "kubectl get pods failed for namespace `"$Namespace`" (exit $LASTEXITCODE): $errorText"
        return $emptyResult
    }

    $jsonOutput = try {
        $rawOutput | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-LogMessage -Type WARNING -Message "kubectl get pods returned non-JSON output for namespace `"$Namespace`": $($_.Exception.Message)"
        return $emptyResult
    }

    if (-not $jsonOutput -or -not $jsonOutput.items) {
        return $emptyResult
    }

    # Count ready pods.
    $readyPods = @($jsonOutput.items | Where-Object {
        $_.status.phase -eq "Running" -or $_.status.phase -eq "Succeeded"
    })

    return @{
        TotalPods = $jsonOutput.items.Count
        ReadyPods = $readyPods.Count
        AllReady = ($jsonOutput.items.Count -gt 1 -and $readyPods.Count -eq $jsonOutput.items.Count)
        ReadyPodObjects = $readyPods
    }
}
function Invoke-ArgoCDNoPodsDiagnostic {

    <#
    .SYNOPSIS
        Checks the ArgoCD Custom Resource status when no pods are found in a namespace.
    .DESCRIPTION
        Issues a kubectl get argocd command and warns when any ArgoCD resource is missing
        spec.version, which would prevent pods from being created. Logs debug output for
        all other results. Intended to be called once per minute while waiting for pod
        creation so operators receive actionable guidance without log flooding.
    .PARAMETER Namespace
        The Kubernetes namespace to inspect.
    .EXAMPLE
        Invoke-ArgoCDNoPodsDiagnostic -Namespace "argocd-site1"
    .NOTES
        Uses $Script:KubectlCmd to invoke kubectl. Does not throw on error.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Namespace
    )

    Write-LogMessage -Type DEBUG -Message "No pods found in namespace `"$Namespace`". Checking ArgoCD Custom Resource status..."
    try {
        $argocdCheck = & $Script:KubectlCmd get argocd -n "$Namespace" -o json 2>&1
        if ($LASTEXITCODE -eq 0) {
            $argocdJson = $argocdCheck | ConvertFrom-Json
            if ($argocdJson.items) {
                foreach ($item in $argocdJson.items) {
                    if (-not $item.spec -or -not $item.spec.version) {
                        Write-LogMessage -Type WARNING -Message "ArgoCD Custom Resource `"$($item.metadata.name)`" is missing spec.version. This may prevent pods from being created."
                    }
                }
            }
        }
    } catch {
        Write-LogMessage -Type DEBUG -Message "Exception during pod diagnostics: $($_.Exception.Message)"
    }
}
function Wait-ArgoCDPodsReady {

    <#
        .SYNOPSIS
        Waits for all ArgoCD pods to become ready in a namespace.

        .DESCRIPTION
        The Wait-ArgoCDPodsReady function monitors pod status and waits for all ArgoCD pods
        to reach Running or Succeeded state. The function logs pod readiness progress and
        handles timeout scenarios.

        .PARAMETER Namespace
        The Kubernetes namespace where ArgoCD pods are deployed.

        .PARAMETER CheckInterval
        Interval between pod status checks, in seconds. Defaults to 5 seconds.

        .PARAMETER TimeoutSeconds
        Maximum time to wait for all pods to become ready, in seconds. Defaults to 1800 seconds.

        .OUTPUTS
        None
        This function throws an exception if the timeout is reached or if pods fail to become ready.

        .NOTES
        The function requires at least 2 pods to be present (more than just the secret-generation pod)
        before considering the deployment complete. Pods are logged only once when they become ready.
    
        .EXAMPLE
        Wait-ArgoCDPodsReady -Namespace "argocd"
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(1, [Int]::MaxValue)] [Int]$CheckInterval = 5,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Namespace,
        [Parameter(Mandatory = $false)] [ValidateRange(1, [Int]::MaxValue)] [Int]$TimeoutSeconds = 1800
    )

    $elapsedTime = 0
    $loggedReadyPods = [System.Collections.Generic.HashSet[String]]::new()
    $allPodsReady = $false
    $podsCreatedPhase = $true

    do {
        $podStatus = Get-PodReadinessStatus -Namespace $Namespace
        $totalPods = $podStatus.TotalPods
        $readyPods = $podStatus.ReadyPods
        $allPodsReady = $podStatus.AllReady

        # Wait for pods to be created (more than just the secret-generation pod).
        if ($totalPods -le 1) {
            $allPodsReady = $false
            $podsCreatedPhase = $true

            # Show progress indicator with elapsed time and pods found.
            $statusMessage = "Elapsed: $elapsedTime seconds - Found: $totalPods pod(s)"
            Write-Progress -Activity "Waiting for ArgoCD pods to be created" -Status $statusMessage
            [Console]::Out.Flush()

            # Add diagnostics when no pods are found (only on first check or every 60 seconds to reduce log volume).
            if ($totalPods -eq 0 -and ($elapsedTime -eq 0 -or ($elapsedTime % 60) -eq 0)) {
                Invoke-ArgoCDNoPodsDiagnostic -Namespace $Namespace
            }

            Start-Sleep $CheckInterval
            $elapsedTime += $CheckInterval

            # Timeout check.
            if ($elapsedTime -ge $TimeoutSeconds) {
                Write-Progress -Activity "Waiting for ArgoCD pods to be created" -Status "Timeout" -Completed
                [Console]::Out.Flush()
                $err = "Timeout waiting for ArgoCD pods to be created after $TimeoutSeconds seconds. Only $totalPods pod(s) found."
                Write-LogMessage -Type ERROR -Message $err
                throw [VcfDeploymentException]::new($err)
            }
            continue
        }

        # Transition from "pods created" phase to "pods ready" phase.
        if ($podsCreatedPhase) {
            Write-Progress -Activity "Waiting for ArgoCD pods to be created" -Status "Completed" -Completed
            [Console]::Out.Flush()
            $podsCreatedPhase = $false
        }

        foreach ($pod in $podStatus.ReadyPodObjects) {
            if ($loggedReadyPods.Add($pod.metadata.name)) {
                Write-LogMessage -Type DEBUG -Message "ArgoCD pod `"$($pod.metadata.name)`" is now in status $($pod.status.phase)."
            }
        }

        if (-not $allPodsReady) {
            # Show progress indicator with elapsed time and X of Y pods ready.
            $percentComplete = if ($totalPods -gt 0) { [Math]::Min(99, [int](($readyPods / $totalPods) * 100)) } else { 0 }
            $statusMessage = "Elapsed: $elapsedTime seconds - Ready: $readyPods of $totalPods"
            Write-Progress -Activity "Waiting for ArgoCD pods to be ready" -Status $statusMessage -PercentComplete $percentComplete
            [Console]::Out.Flush()

            Start-Sleep $CheckInterval
            $elapsedTime += $CheckInterval

            # Timeout check.
            if ($elapsedTime -ge $TimeoutSeconds) {
                Write-Progress -Activity "Waiting for ArgoCD pods to be ready" -Status "Timeout" -Completed
                [Console]::Out.Flush()
                $err = "Timeout waiting for ArgoCD pods after $TimeoutSeconds seconds. Ready: $readyPods/$totalPods."
                Write-LogMessage -Type ERROR -Message $err
                throw [VcfDeploymentException]::new($err)
            }
        }

    } while (-not $allPodsReady)

    # Clear progress indicator when all pods are ready.
    Write-Progress -Activity "Waiting for ArgoCD pods to be ready" -Status "Completed" -Completed
    [Console]::Out.Flush()
    Write-LogMessage -Type INFO -Message "All $totalPods ArgoCD pods are ready."
}
function Update-YamlNamespace {

    <#
        .SYNOPSIS
        Updates the namespace value in a YAML file using regex replacement.

        .DESCRIPTION
        The Update-YamlNamespace function copies a YAML file to a temporary location and updates
        the namespace value in the metadata.namespace field using regex pattern matching. This ensures
        the namespace value in the YAML file matches the dynamically constructed namespace value.

        .PARAMETER YamlFilePath
        The path to the source YAML file to be updated.

        .PARAMETER NewNamespace
        The new namespace value to set in the YAML file.

        .EXAMPLE
        $tempYaml = Update-YamlNamespace -YamlFilePath "./config/argocd-deployment.yml" -NewNamespace "argocd-c462"

        Updates the namespace in the YAML file and returns the path to the temporary file.

        .OUTPUTS
        System.String
        Returns the path to the temporary YAML file with the updated namespace value.

        .NOTES
        - Creates a temporary file in the system temp directory
        - Uses regex to match and replace the namespace value
        - Handles both quoted and unquoted namespace values
        - The regex pattern excludes newlines to prevent matching across multiple lines (critical for preserving spec section)
        - Verifies that the spec section is preserved after namespace replacement
        - The temporary file should be cleaned up by the caller after use
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$NewNamespace,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$YamlFilePath
    )

    Write-LogMessage -Type DEBUG -Message "Entered Update-YamlNamespace function..."
    Write-LogMessage -Type DEBUG -Message "Update-YamlNamespace: Source YAML file: `"$YamlFilePath`", New namespace value: `"$NewNamespace`""

    if (-not (Test-Path -Path $YamlFilePath)) {
        $err = "YAML file not found: $YamlFilePath."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }

    try {
        # GUID-suffixed name avoids the GetTempFileName+ChangeExtension pattern that leaves an
        # orphaned zero-byte .tmp file and introduces a brief window before the .yml path is locked.
        $tempYamlFile = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "argocd-ns-update-$([Guid]::NewGuid().ToString('N')).yml"
        Write-LogMessage -Type DEBUG -Message "Created temporary YAML file: `"$tempYamlFile`""

        $yamlContent = Get-Content -Path $YamlFilePath -Raw -Encoding UTF8

        # Use regex to replace the namespace value. Handles both quoted and unquoted values.
        # Pattern matches: namespace: "value" or namespace: value
        # Important: [^\r\n"'']+ excludes newlines to prevent matching across multiple lines.
        $namespacePattern = '(namespace:\s*)(["'']?)([^\r\n"'']+)(\2)'
        if ($yamlContent -match $namespacePattern) {
            $originalNamespaceInYaml = $matches[3]
            Write-LogMessage -Type DEBUG -Message "Found original namespace in YAML file: `"$originalNamespaceInYaml`""
        } else {
            Write-LogMessage -Type WARNING -Message "Could not find namespace pattern in YAML file. Will attempt replacement anyway."
        }

        $replacement = "`$1`$2$NewNamespace`$4"
        $updatedContent = $yamlContent -replace $namespacePattern, $replacement

        if ($updatedContent -match $namespacePattern) {
            $newNamespaceInYaml = $matches[3]
            if ($newNamespaceInYaml -ne $NewNamespace) {
                Write-LogMessage -Type WARNING -Message "Namespace replacement may not have worked correctly. Expected `"$NewNamespace`" but found `"$newNamespaceInYaml`""
            }
        } else {
            Write-LogMessage -Type WARNING -Message "Could not verify namespace replacement in updated YAML content."
        }

        # Verify that the spec section is still present after replacement.
        if (-not ($updatedContent -match '(?m)^spec:')) {
            Write-LogMessage -Type ERROR -Message "CRITICAL: spec section is MISSING from updated YAML content! The ArgoCD operator requires spec.version to process the Custom Resource."
            $err = "This will cause the operator to not process the Custom Resource and no pods will be created."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }

        Set-Content -Path $tempYamlFile -Value $updatedContent -Encoding UTF8 -NoNewline

        if (Test-Path -Path $tempYamlFile) {
            $verifyContent = Get-Content -Path $tempYamlFile -Raw -Encoding UTF8
            Write-LogMessage -Type DEBUG -Message "Full contents of temporary YAML file `"$tempYamlFile`":"
            Write-LogMessage -Type DEBUG -Message "--- BEGIN TEMP YAML FILE CONTENTS ---"
            Write-LogMessage -Type DEBUG -Message $verifyContent
            Write-LogMessage -Type DEBUG -Message "--- END TEMP YAML FILE CONTENTS ---"
        } else {
            $err = "Temporary file was not created successfully: $tempYamlFile."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }

        Write-LogMessage -Type DEBUG -Message "Updated namespace in YAML file. Temporary file: $tempYamlFile"

        return $tempYamlFile
    } catch [VcfDeploymentException] {
        throw  # already logged and typed — propagate without re-wrapping
    } catch {
        $err = "Failed to update namespace in YAML file `"$YamlFilePath`": $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
}
function Get-KubectlNamespaceNamesMatchingPattern {

    <#
        .SYNOPSIS
        Lists Kubernetes namespace names on the current kubectl context that match a wildcard pattern.

        .DESCRIPTION
        Runs kubectl get namespaces -o json, filters items where metadata.name matches -like NameLike, and returns
        whether kubectl succeeded plus the matching names. Consolidates discovery for Supervisor Services system
        namespaces (for example svc-harbor* and svc-<service-slug>-*) that the vCenter namespace-instances API does
        not surface. Callers use KubectlSucceeded to distinguish kubectl failure from an empty match list.

        .PARAMETER DebugLogPrefix
        Prefix for DEBUG log lines on failure (for example the calling function name).

        .PARAMETER NameLike
        Wildcard pattern for namespace names (for example svc-harbor*).

        .PARAMETER SortNames
        When present, Names are sorted ascending (callers may use the last element when a stable lexicographic choice is needed).

        .OUTPUTS
        PSCustomObject with properties KubectlSucceeded (Boolean) and Names (String[]).

        .NOTES
        Requires kubectl and a context that targets the intended cluster.
    
        .EXAMPLE
        $kubectlNamespaceNamesMatchingPattern = Get-KubectlNamespaceNamesMatchingPattern -NameLike "resource-name"
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$DebugLogPrefix = "Get-KubectlNamespaceNamesMatchingPattern",
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$NameLike,
        [Parameter(Mandatory = $false)] [Switch]$SortNames
    )

    $matchedNames = @()
    try {
        $nsOutput = & $Script:KubectlCmd get namespaces -o json 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-LogMessage -Type DEBUG -Message "${DebugLogPrefix}: kubectl get namespaces failed (exit $LASTEXITCODE)."
            return [PSCustomObject]@{ KubectlSucceeded = $false; Names = [string[]]@() }
        }
        $nsData = $nsOutput | ConvertFrom-Json
        $matchedNames = @($nsData.items | Where-Object { $_.metadata.name -like $NameLike } | ForEach-Object { $_.metadata.name })
        if ($SortNames) {
            $matchedNames = @($matchedNames | Sort-Object)
        }
        return [PSCustomObject]@{ KubectlSucceeded = $true; Names = $matchedNames }
    } catch {
        Write-LogMessage -Type DEBUG -Message "${DebugLogPrefix}: Could not list namespaces via kubectl. $($_.Exception.Message)"
        return [PSCustomObject]@{ KubectlSucceeded = $false; Names = [string[]]@() }
    }
}
function Get-ArgoCDOperatorServiceNamespace {

    <#
        .SYNOPSIS
        Resolves the ArgoCD operator (supervisor service) namespace for webhook and kubectl operations.

        .DESCRIPTION
        Resolves the ArgoCD operator (supervisor service) namespace by lookup: lists namespaces matching
        svc-<service-slug>-*. If exactly one match or a unique match containing the webhook
        service is found, that namespace is returned. Caller must have VCF context set so kubectl targets
        the correct cluster.

        .PARAMETER Service
        The supervisor service identifier (e.g. argocd-service.vsphere.vmware.com). Used to derive the service slug.

        .PARAMETER WebhookServiceName
        Name of the webhook service used to disambiguate when multiple matching namespaces exist. Default: argocd-service-webhook-service.

        .OUTPUTS
        System.String or $null. The resolved namespace name, or $null if discovery failed (caller may use constructed namespace).

        .NOTES
        Requires kubectl and VCF context to be set for the target supervisor cluster before calling.
    
        .EXAMPLE
        $argoCDOperatorServiceNamespace = Get-ArgoCDOperatorServiceNamespace -Service "value"
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Service,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$WebhookServiceName = "argocd-service-webhook-service"
    )

    $serviceSlug = $Service -replace '\.vsphere\.vmware\.com$', ''
    $prefix = "svc-$serviceSlug-"

    try {
        $discovery = Get-KubectlNamespaceNamesMatchingPattern -DebugLogPrefix "Get-ArgoCDOperatorServiceNamespace" -NameLike "${prefix}*"
        if (-not $discovery.KubectlSucceeded) {
            return $null
        }
        $matching = @($discovery.Names)
        if ($matching.Count -eq 0) {
            return $null
        }
        if ($matching.Count -eq 1) {
            Write-LogMessage -Type DEBUG -Message "Resolved operator namespace (lookup, single match): `"$($matching[0])`""
            return $matching[0]
        }
        foreach ($candidate in $matching) {
            $null = & $Script:KubectlCmd get service "$WebhookServiceName" -n "$candidate" -o json 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-LogMessage -Type DEBUG -Message "Resolved operator namespace (lookup, webhook in `"$candidate`"): `"$candidate`""
                return $candidate
            }
        }
        Write-LogMessage -Type DEBUG -Message "Resolved operator namespace (lookup, multiple matches; using first): `"$($matching[0])`""
        return $matching[0]
    } catch {
        Write-LogMessage -Type DEBUG -Message "Operator namespace lookup failed: $($_.Exception.Message)."
    }

    return $null
}
function Invoke-ArgoCDContextBind {

    <#
        .SYNOPSIS
        Switches the VCF CLI context, verifies kubectl cluster access, resolves the ArgoCD
        operator service namespace, and waits for the webhook service to be ready.

        .DESCRIPTION
        Extracted from Add-ArgoCDInstance. Performs the pre-flight sequence required before
        kubectl apply can succeed:
          1. Switch the VCF CLI context (namespace-scoped then base fallback).
          2. Verify kubectl can reach the cluster.
          3. Resolve the ArgoCD operator service namespace via Get-ArgoCDOperatorServiceNamespace,
             falling back to the constructed "svc-<slug>-<ClusterId>" pattern.
          4. Wait for the webhook service to report ready endpoints.

        Returns a PSCustomObject with Success=$true and the resolved ServiceNamespace on success,
        or Success=$false (from Write-ErrorAndReturn or the webhook result) on any failure.

        .PARAMETER ArgoCdNamespace
        Supervisor namespace where ArgoCD is deployed. Used to build the namespace-scoped
        context name (ContextName:ArgoCdNamespace).

        .PARAMETER ClusterId
        vCenter cluster MoRef value (e.g. "domain-c462"). Used to construct the fallback
        operator namespace when the live lookup returns nothing.

        .PARAMETER ContextName
        VCF CLI context name (from Set-VCFContextCreate) for the target supervisor.

        .PARAMETER InsecureTls
        Passes --insecure-skip-tls-verify to VCF CLI context use commands.

        .PARAMETER Service
        Supervisor Service reference name (e.g. "argocd-service.vsphere.vmware.com"). Used to
        derive the operator namespace slug.

        .PARAMETER WebhookCheckInterval
        Polling interval in seconds for webhook readiness checks. Defaults to 5.

        .PARAMETER WebhookTimeoutSeconds
        Maximum seconds to wait for the webhook service. Defaults to 1200.

        .OUTPUTS
        PSCustomObject with Success, ServiceNamespace (on success), or ErrorMessage/ErrorCode
        (on failure).

        .EXAMPLE
        $bindResult = Invoke-ArgoCDContextBind -ArgoCdNamespace "argocd-c42" -ClusterId "domain-c42" -ContextName "ctx-site1" -Service "argocd-service.vsphere.vmware.com"
        if (-not $bindResult.Success) { return $bindResult }
        $serviceNamespace = $bindResult.ServiceNamespace
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ArgoCdNamespace,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterId,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ContextName,
        [Parameter(Mandatory = $false)] [Switch]$InsecureTls,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Service,
        [Parameter(Mandatory = $false)] [ValidateRange(1, [Int]::MaxValue)] [Int]$WebhookCheckInterval = 5,
        [Parameter(Mandatory = $false)] [ValidateRange(1, [Int]::MaxValue)] [Int]$WebhookTimeoutSeconds = 1200
    )

    # Hoist flag computation above the context-switch calls so it is not repeated per call.
    $tlsArgs = @(if ($InsecureTls) { "--insecure-skip-tls-verify" })
    # Prefer namespace-scoped context (ContextName:ArgoCdNamespace) when available so kubectl targets the ArgoCD namespace.
    $contextToUse = if (-not [String]::IsNullOrWhiteSpace($ArgoCdNamespace)) { "${ContextName}:$ArgoCdNamespace" } else { $ContextName }
    $contextUseOutput = & $Script:VcfCmd context use $contextToUse @tlsArgs 2>&1
    $contextUseExitCode = $LASTEXITCODE
    if ($contextUseExitCode -ne 0 -and $contextToUse -ne $ContextName) {
        Write-LogMessage -Type DEBUG -Message "Namespace-scoped context switch failed; trying base context `"$ContextName`"..."
        $contextUseOutput = & $Script:VcfCmd context use $ContextName @tlsArgs 2>&1
        $contextUseExitCode = $LASTEXITCODE
    }
    $contextUseOutputText = ($contextUseOutput | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.ToString() } else { [String]$_ }
    }) -join "`n"
    $contextActuallyActivated = $contextUseOutputText -match "Successfully activated"
    if ($contextUseExitCode -ne 0 -and $contextActuallyActivated) {
        Write-LogMessage -Type DEBUG -Message (
            "VCF context activated (output shows Successfully activated) but CLI returned exit code $contextUseExitCode. " +
            "ClusterDomainResolutionEntry may be absent. Continuing with ArgoCD deployment."
        )
    }
    if ($contextUseExitCode -ne 0 -and -not $contextActuallyActivated) {
        return Write-ErrorAndReturn -ErrorMessage "Failed to switch to VCF context `"$contextToUse`"" -ErrorCode "ERR_VCF_CONTEXT"
    }

    # Verify kubectl can reach the cluster before namespace lookup and webhook check.
    Write-LogMessage -Type DEBUG -Message "Verifying kubectl can access cluster after VCF context switch..."
    $null = & $Script:KubectlCmd cluster-info 2>&1 | Out-Null
    switch ($LASTEXITCODE) {
        0 { Write-LogMessage -Type DEBUG -Message "kubectl cluster access verified after context switch." }
        default {
            Write-LogMessage -Type WARNING -Message "kubectl cluster-info failed after context switch (exit code: $LASTEXITCODE). This may indicate the context needs time to initialize. Continuing with webhook check..."
        }
    }

    # Resolve the operator service namespace — live lookup first, fallback to constructed name.
    $serviceSlug = $Service -replace '\.vsphere\.vmware\.com$', ''
    $constructedNamespace = "svc-$serviceSlug-$ClusterId"
    $resolvedOperatorNs = Get-ArgoCDOperatorServiceNamespace -Service $Service
    $serviceNamespace = if (-not [String]::IsNullOrWhiteSpace($resolvedOperatorNs)) { $resolvedOperatorNs } else { $constructedNamespace }
    $namespaceSource = if (-not [String]::IsNullOrWhiteSpace($resolvedOperatorNs)) { "resolved" } else { "fallback constructed" }
    Write-LogMessage -Type DEBUG -Message "Using $namespaceSource service namespace: `"$serviceNamespace`""

    $webhookResult = Wait-WebhookServiceReady -CheckInterval $WebhookCheckInterval -ServiceName "argocd-service-webhook-service" -ServiceNamespace $serviceNamespace -TimeoutSeconds $WebhookTimeoutSeconds
    if (-not $webhookResult.Success) {
        return $webhookResult
    }

    return [PSCustomObject]@{
        Success          = $true
        ServiceNamespace = $serviceNamespace
    }
}
function Resolve-ArgoCdTimeout {

    <#
        .SYNOPSIS
        Resolves a single ArgoCD timeout value from an overrides hashtable, falling back to a default.

        .DESCRIPTION
        Reads the specified key from TimeoutConfig. If the key is present, is an integer, and is
        greater than 0, the override value is returned; otherwise, the default is returned.

        .PARAMETER Default
        The fallback integer value to use when no valid override exists.

        .PARAMETER Key
        The key name to look up in TimeoutConfig.

        .PARAMETER TimeoutConfig
        Optional hashtable of timeout overrides. May be $null.

        .EXAMPLE
        $seconds = Resolve-ArgoCdTimeout -TimeoutConfig $overrides -Key "AuthTimeoutSeconds" -Default 60

        .NOTES
        Used exclusively by Get-ArgoCdTimeoutConfig to centralise override-or-default resolution.
    #>

    [CmdletBinding()]
    [OutputType([Int])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateRange(1, [Int]::MaxValue)] [Int]$Default,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Key,
        [Parameter(Mandatory = $false)] [Hashtable]$TimeoutConfig
    )

    if ($TimeoutConfig -and $TimeoutConfig.ContainsKey($Key) -and $TimeoutConfig[$Key] -is [Int] -and $TimeoutConfig[$Key] -gt 0) {
        return $TimeoutConfig[$Key]
    }
    return $Default
}
function Get-ArgoCdTimeoutConfig {

    <#
        .SYNOPSIS
        Builds a resolved ArgoCD timeout configuration from an optional override hashtable and module defaults.

        .DESCRIPTION
        Returns a PSCustomObject with all seven ArgoCD timeout values resolved from TimeoutConfig
        overrides where valid, or module-level Script: defaults otherwise.

        .PARAMETER TimeoutConfig
        Optional hashtable of timeout overrides. Keys: AuthCheckInterval, AuthTimeoutSeconds,
        PodReadyCheckInterval, PodReadyTimeoutSeconds, WebhookReadyCheckInterval,
        WebhookReadyTimeoutSeconds, WebhookRetryTimeoutSeconds.

        .EXAMPLE
        $timeouts = Get-ArgoCdTimeoutConfig -TimeoutConfig @{ AuthTimeoutSeconds = 120 }

        .NOTES
        Called by Add-ArgoCDInstance to centralise the seven repetitive timeout-resolution blocks.
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $false)] [Hashtable]$TimeoutConfig
    )

    return [PSCustomObject]@{
        AuthCheckInterval          = Resolve-ArgoCdTimeout -TimeoutConfig $TimeoutConfig -Key "AuthCheckInterval" -Default 5
        AuthTimeoutSeconds         = Resolve-ArgoCdTimeout -TimeoutConfig $TimeoutConfig -Key "AuthTimeoutSeconds" -Default $Script:ArgoCDAuthTimeoutSeconds
        PodReadyCheckInterval      = Resolve-ArgoCdTimeout -TimeoutConfig $TimeoutConfig -Key "PodReadyCheckInterval" -Default $Script:ArgoCDPodReadyCheckIntervalSeconds
        PodReadyTimeoutSeconds     = Resolve-ArgoCdTimeout -TimeoutConfig $TimeoutConfig -Key "PodReadyTimeoutSeconds" -Default $Script:ArgoCDPodReadyTimeoutSeconds
        WebhookReadyCheckInterval  = Resolve-ArgoCdTimeout -TimeoutConfig $TimeoutConfig -Key "WebhookReadyCheckInterval" -Default $Script:ArgoCDWebhookReadyCheckIntervalSeconds
        WebhookReadyTimeoutSeconds = Resolve-ArgoCdTimeout -TimeoutConfig $TimeoutConfig -Key "WebhookReadyTimeoutSeconds" -Default $Script:ArgoCDWebhookReadyTimeoutSeconds
        WebhookRetryTimeoutSeconds = Resolve-ArgoCdTimeout -TimeoutConfig $TimeoutConfig -Key "WebhookRetryTimeoutSeconds" -Default $Script:ArgoCDWebhookRetryTimeoutSeconds
    }
}
function Confirm-ArgoCdResourceSpec {

    <#
        .SYNOPSIS
        Verifies that every ArgoCD Custom Resource in a namespace has a spec.version field.

        .DESCRIPTION
        Runs kubectl get argocd in the specified namespace and logs a CRITICAL error for any
        resource missing the spec section or spec.version field. Does not throw on failure —
        this is a diagnostic check only.

        .PARAMETER ArgoCdNamespace
        The namespace to query for ArgoCD Custom Resources.

        .EXAMPLE
        Confirm-ArgoCdResourceSpec -ArgoCdNamespace "argocd"
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ArgoCdNamespace
    )

    try {
        $argocdResources = & $Script:KubectlCmd get argocd -n $ArgoCdNamespace -o json 2>&1
        if ($LASTEXITCODE -ne 0 -or -not $argocdResources) { return }
        $argocdResourcesJson = $argocdResources | ConvertFrom-Json
        if (-not $argocdResourcesJson.items) { return }
        foreach ($resource in $argocdResourcesJson.items) {
            if (-not $resource.spec) {
                Write-LogMessage -Type ERROR -Message "CRITICAL: Spec section is MISSING from the Custom Resource! The ArgoCD operator requires spec.version to process the Custom Resource."
            } elseif (-not $resource.spec.version) {
                Write-LogMessage -Type ERROR -Message "CRITICAL: Spec.version is MISSING! The ArgoCD operator requires spec.version to process the Custom Resource."
            }
        }
    } catch {
        Write-LogMessage -Type WARNING -Message "Exception while verifying ArgoCD resource: $($_.Exception.Message)"
    }
}
function Invoke-ArgoCdYamlApply {

    <#
        .SYNOPSIS
        Applies an ArgoCD deployment YAML to a Supervisor namespace, with webhook-timeout retry.

        .DESCRIPTION
        Copies the source YAML to a temporary file with the namespace updated, runs kubectl apply,
        verifies the created Custom Resource has spec.version, and on webhook deadline-exceeded
        errors waits for the webhook service to recover and retries once. Always cleans up the
        temporary file in a finally block.

        .PARAMETER ArgoCdDeploymentYamlPath
        Source YAML file path. A timestamped temporary copy is created with the namespace updated.

        .PARAMETER ArgoCdNamespace
        Supervisor namespace where ArgoCD is deployed.

        .PARAMETER ServiceNamespace
        The resolved ArgoCD operator service namespace (used for webhook retry).

        .PARAMETER WebhookCheckInterval
        Polling interval in seconds for webhook readiness during retry.

        .PARAMETER WebhookRetryTimeoutSeconds
        Maximum seconds to wait for the webhook service to recover before returning a failure result.

        .EXAMPLE
        $result = Invoke-ArgoCdYamlApply -ArgoCdDeploymentYamlPath $yamlPath -ArgoCdNamespace "argocd" -ServiceNamespace $svcNs -WebhookCheckInterval 5 -WebhookRetryTimeoutSeconds 60
        if (-not $result.Success) { return $result }

        .NOTES
        Returns a PSCustomObject with Success=$true on success, or a Write-ErrorAndReturn result on failure.
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ArgoCdDeploymentYamlPath,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ArgoCdNamespace,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ServiceNamespace,
        [Parameter(Mandatory = $true)] [ValidateRange(0, [Int]::MaxValue)] [Int]$WebhookCheckInterval,
        [Parameter(Mandatory = $true)] [ValidateRange(1, [Int]::MaxValue)] [Int]$WebhookRetryTimeoutSeconds
    )

    Write-LogMessage -Type DEBUG -Message "Updating YAML file namespace from original file `"$ArgoCdDeploymentYamlPath`" to namespace value: `"$ArgoCdNamespace`""
    $tempYamlPath = Update-YamlNamespace -YamlFilePath $ArgoCdDeploymentYamlPath -NewNamespace $ArgoCdNamespace

    try {
        Write-LogMessage -Type DEBUG -Message "Applying temporary ArgoCD deployment YAML file to the namespace `"$ArgoCdNamespace`"..."
        $applyOutput = $null
        & $Script:KubectlCmd apply -f $tempYamlPath 2>&1 | Tee-Object -Variable applyOutput | Out-Null
        $applyOutput = $applyOutput | Where-Object { $_ -is [string] -or $_ -is [System.Management.Automation.ErrorRecord] }

        if ($LASTEXITCODE -eq 0) {
            $successMessage = ($applyOutput | Where-Object { $_ -is [string] }) -join " "
            $logSuffix = if ([String]::IsNullOrWhiteSpace($successMessage)) { "" } else { " Output: $successMessage" }
            Write-LogMessage -Type DEBUG -Message "Successfully applied ArgoCD deployment YAML to namespace `"$ArgoCdNamespace`".$logSuffix"
            Confirm-ArgoCdResourceSpec -ArgoCdNamespace $ArgoCdNamespace
            return [PSCustomObject]@{ Success = $true }
        }

        $errorMessage = ($applyOutput | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] -or ($_ -is [string]) }) -join " "
        Write-LogMessage -Type ERROR -Message "kubectl apply failed with exit code: $LASTEXITCODE"
        Write-LogMessage -Type ERROR -Message "Error message: $errorMessage."

        $isWebhookTimeout = $errorMessage -match "context deadline exceeded" -or $errorMessage -match "webhook.*timeout"
        if (-not $isWebhookTimeout) {
            return Write-ErrorAndReturn -ErrorMessage "Failed to apply ArgoCD deployment YAML file `"$tempYamlPath`": $errorMessage" -ErrorCode "ERR_KUBECTL_APPLY"
        }

        Write-LogMessage -Type ERROR -Message "Webhook timeout error when applying ArgoCD deployment YAML. The webhook service may have become unavailable after initial readiness check."
        Write-LogMessage -Type INFO -Message "Attempting to re-verify webhook service readiness before retrying..."
        $webhookRetryResult = Wait-WebhookServiceReady -CheckInterval $WebhookCheckInterval -ServiceName "argocd-service-webhook-service" -ServiceNamespace $ServiceNamespace -TimeoutSeconds $WebhookRetryTimeoutSeconds
        if (-not $webhookRetryResult.Success) {
            return Write-ErrorAndReturn -ErrorMessage "Webhook service is not available. Failed to apply ArgoCD deployment YAML: $errorMessage" -ErrorCode "ERR_WEBHOOK_TIMEOUT"
        }

        Write-LogMessage -Type INFO -Message "Webhook service is ready. Retrying YAML application..."
        $retryApplyOutput = $null
        & $Script:KubectlCmd apply -f $tempYamlPath 2>&1 | Tee-Object -Variable retryApplyOutput | Out-Null
        $retryApplyOutput = $retryApplyOutput | Where-Object { $_ -is [string] -or $_ -is [System.Management.Automation.ErrorRecord] }

        if ($LASTEXITCODE -ne 0) {
            $retryErrorMessage = ($retryApplyOutput | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] -or ($_ -is [string]) }) -join " "
            return Write-ErrorAndReturn -ErrorMessage "Failed to apply ArgoCD deployment YAML file after webhook retry: $retryErrorMessage" -ErrorCode "ERR_KUBECTL_APPLY"
        }
        Write-LogMessage -Type DEBUG -Message "Successfully applied ArgoCD deployment YAML to namespace `"$ArgoCdNamespace`" after webhook retry."
        return [PSCustomObject]@{ Success = $true }
    } finally {
        if (Test-Path -Path $tempYamlPath) {
            Remove-Item -Path $tempYamlPath -Force -ErrorAction SilentlyContinue
            Write-LogMessage -Type DEBUG -Message "Cleaned up temporary YAML file: $tempYamlPath."
        }
    }
}
function Set-ArgoCdKubectlContext {

    <#
        .SYNOPSIS
        Switches the active kubectl context to a Supervisor namespace context if it exists.

        .DESCRIPTION
        Lists all kubectl contexts, checks whether the specified context name is present, and if so
        switches to it. If the context does not exist (normal immediately after namespace creation)
        the function logs an informational message and returns without error.

        .PARAMETER KubectlContextName
        The fully-qualified kubectl context name (e.g. "supervisor-context:argocd-namespace").

        .EXAMPLE
        Set-ArgoCdKubectlContext -KubectlContextName "$ContextName`:$ArgoCdNamespace"

        .NOTES
        A missing context is not an error — VCF CLI creates contexts asynchronously.
        kubectl operations after this call use the -n namespace flag as a fallback.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$KubectlContextName
    )

    Write-LogMessage -Type DEBUG -Message "Checking if kubectl context `"$KubectlContextName`" exists..."
    $contextExists = $false
    try {
        $contextCheckOutput = & $Script:KubectlCmd config get-contexts -o name 2>&1 | Where-Object { $_ -is [string] -and $_ -notmatch "^error:" }
        if ($LASTEXITCODE -eq 0 -and $contextCheckOutput) {
            $contextList = $contextCheckOutput | Where-Object { $_ -is [string] -and $_.Trim() -ne "" }
            $contextExists = $contextList -contains $KubectlContextName
        }
    } catch {
        Write-LogMessage -Type DEBUG -Message "Error checking kubectl contexts: $_. Continuing without context switch."
    }

    if ($contextExists) {
        Write-LogMessage -Type DEBUG -Message "kubectl context `"$KubectlContextName`" exists. Switching to it..."
        $null = & $Script:KubectlCmd config use-context "$KubectlContextName" 2>&1
        switch ($LASTEXITCODE) {
            0       { Write-LogMessage -Type DEBUG -Message "Successfully switched to kubectl context `"$KubectlContextName`"." }
            default { Write-LogMessage -Type WARNING -Message "Failed to switch to kubectl context `"$KubectlContextName`", but continuing with namespace flag `-n` instead." }
        }
    } else {
        Write-LogMessage -Type INFO -Message "kubectl context `"$KubectlContextName`" does not exist. This is expected if the namespace was just created. Continuing with namespace flag `-n` for kubectl operations."
    }
}
function Wait-ArgoCDAuthReady {

    <#
        .SYNOPSIS
        Polls kubectl until authentication to a Supervisor namespace is confirmed, re-authenticating via VCF CLI on each failed attempt.

        .DESCRIPTION
        Runs kubectl auth can-i get pods -n <namespace> in a loop. On the first failure,
        re-authenticates using vcf context use. Throws VcfDeploymentException if authentication
        is not confirmed before AuthTimeoutSeconds elapses.

        .PARAMETER ArgoCdNamespace
        The namespace to verify kubectl access against.

        .PARAMETER AuthCheckInterval
        Seconds to wait between authentication poll attempts.

        .PARAMETER AuthTimeoutSeconds
        Maximum seconds to wait before throwing VcfDeploymentException.

        .PARAMETER ContextName
        VCF CLI context name used for re-authentication.

        .PARAMETER InsecureTls
        Passes --insecure-skip-tls-verify to VCF CLI re-authentication.

        .EXAMPLE
        Wait-ArgoCDAuthReady -ArgoCdNamespace "argocd" -AuthCheckInterval 5 -AuthTimeoutSeconds 60 -ContextName $contextName

        .NOTES
        Write-Progress surfaces auth wait status for interactive runs.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ArgoCdNamespace,
        [Parameter(Mandatory = $true)] [ValidateRange(0, [Int]::MaxValue)] [Int]$AuthCheckInterval,
        [Parameter(Mandatory = $true)] [ValidateRange(1, [Int]::MaxValue)] [Int]$AuthTimeoutSeconds,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ContextName,
        [Parameter(Mandatory = $false)] [Switch]$InsecureTls
    )

    Write-LogMessage -Type DEBUG -Message "Verifying kubectl authentication for namespace `"$ArgoCdNamespace`" (timeout: $AuthTimeoutSeconds seconds)..."
    $elapsedTime = 0
    $authSuccess = $false
    # Hoist TLS flag outside the poll loop — its value depends only on the parameter.
    $tlsArgs = @(if ($InsecureTls) { "--insecure-skip-tls-verify" })

    do {
        try {
            $canGetPods  = & $Script:KubectlCmd auth can-i get pods -n $ArgoCdNamespace 2>&1
            $authExitCode = $LASTEXITCODE

            if ($authExitCode -eq 0 -and $canGetPods -eq "yes") {
                $authSuccess = $true
                Write-LogMessage -Type DEBUG -Message "kubectl authentication verified for namespace `"$ArgoCdNamespace`" after $elapsedTime seconds"
                break
            }

            if ($elapsedTime -eq 0) {
                Write-LogMessage -Type WARNING -Message "kubectl authentication failed: $canGetPods."
                Write-LogMessage -Type INFO -Message "Attempting to re-authenticate using: vcf context use $ContextName."
            }

            $null = & $Script:VcfCmd context use $ContextName @tlsArgs 2>&1

            Write-Progress -Activity "Waiting for kubectl authentication" -Status "Waiting for authentication (exit code: $authExitCode)" -CurrentOperation "Elapsed: $elapsedTime seconds"
            Start-Sleep $AuthCheckInterval
            $elapsedTime += $AuthCheckInterval
        } catch {
            $errorMessage = $_.Exception.Message
            Write-LogMessage -Type ERROR -Message "Error during kubectl authentication check: $errorMessage."
            Write-Progress -Activity "Waiting for kubectl authentication" -Status "Error" -Completed
            throw [VcfDeploymentException]::new("kubectl authentication failed: $errorMessage")
        }
    } while ($elapsedTime -lt $AuthTimeoutSeconds)

    if (-not $authSuccess) {
        Write-Progress -Activity "Waiting for kubectl authentication" -Status "Timeout" -Completed
        Write-LogMessage -Type ERROR -Message "kubectl authentication failed after $AuthTimeoutSeconds seconds."
        $err = "You may need to manually re-authenticate using: vcf context use $ContextName."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }

    Write-Progress -Activity "Waiting for kubectl authentication" -Status "Authenticated" -Completed
}
function Add-ArgoCDInstance {

    <#
        .SYNOPSIS
        Deploys an ArgoCD instance to a Supervisor namespace via kubectl and VCF CLI.

        .DESCRIPTION
        Updates the namespace field in the ArgoCD deployment YAML, establishes VCF CLI context,
        applies the manifest with kubectl, waits for pods to become ready, then verifies the
        Custom Resource has a spec.version field. Terminates on critical failures.

        .PARAMETER ArgoCdNamespace
        Supervisor namespace name where ArgoCD will be deployed.

        .PARAMETER ArgoCdDeploymentYamlPath
        Filesystem path for the YAML file to write and apply.

        .PARAMETER ContextName
        VCF CLI context name (from Set-VCFContextCreate) for the target supervisor.

        .PARAMETER ClusterId
        vCenter cluster MoRef (e.g., "domain-c462"). Used to derive the ArgoCD service namespace
        name (format: svc-<service-slug>-<cluster-id>).

        .PARAMETER Service
        Supervisor Service reference name (e.g., "argocd-service.vsphere.vmware.com").

        .PARAMETER InsecureTls
        Passes --insecure-skip-tls-verify to VCF CLI operations.

        .PARAMETER TimeoutConfig
        Hashtable overriding default timeouts (seconds). Keys and defaults:
        AuthCheckInterval (5), AuthTimeoutSeconds (60), PodReadyCheckInterval (5),
        PodReadyTimeoutSeconds (600), WebhookReadyCheckInterval (5),
        WebhookReadyTimeoutSeconds (1200), WebhookRetryTimeoutSeconds (60).

        .EXAMPLE
        Add-ArgoCDInstance -ArgoCdNamespace "argocd" -ArgoCdDeploymentYamlPath $yamlPath -ContextName $ctx -ClusterId $cid -Service $svcName -InsecureTls

        .LINK
        Set-VCFContextCreate
        Install-ArgoCDOperator
        Add-ArgoCDNamespace
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ArgoCdDeploymentYamlPath,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ArgoCdNamespace,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterId,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ContextName,
        [Parameter(Mandatory = $false)] [Switch]$InsecureTls,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Service,
        [Parameter(Mandatory = $false)] [Hashtable]$TimeoutConfig
    )

    Write-LogMessage -Type DEBUG -Message "Entered Add-ArgoCDInstance function..."
    Write-LogMessage -Type DEBUG -Message "Add-ArgoCDInstance received namespace parameter: `"$ArgoCdNamespace`""
    Write-LogMessage -Type DEBUG -Message "Add-ArgoCDInstance received YAML path parameter: `"$ArgoCdDeploymentYamlPath`""

    # Initialize the VCF CLI command if not already set. Normally this is done by Get-EnvironmentSetup
    # at the start of the full deployment flow; direct callers (including live tests) bypass that path.
    $null = Get-VcfEdgeAtScaleVcfCmd

    $timeouts = Get-ArgoCdTimeoutConfig -TimeoutConfig $TimeoutConfig

    try {
        $bindResult = Invoke-ArgoCDContextBind `
            -ArgoCdNamespace       $ArgoCdNamespace `
            -ClusterId             $ClusterId `
            -ContextName           $ContextName `
            -InsecureTls:$InsecureTls.IsPresent `
            -Service               $Service `
            -WebhookCheckInterval  $timeouts.WebhookReadyCheckInterval `
            -WebhookTimeoutSeconds $timeouts.WebhookReadyTimeoutSeconds
        if (-not $bindResult.Success) {
            return $bindResult
        }

        $yamlResult = Invoke-ArgoCdYamlApply `
            -ArgoCdDeploymentYamlPath   $ArgoCdDeploymentYamlPath `
            -ArgoCdNamespace            $ArgoCdNamespace `
            -ServiceNamespace           $bindResult.ServiceNamespace `
            -WebhookCheckInterval       $timeouts.WebhookReadyCheckInterval `
            -WebhookRetryTimeoutSeconds $timeouts.WebhookRetryTimeoutSeconds
        if (-not $yamlResult.Success) {
            return $yamlResult
        }

        Set-ArgoCdKubectlContext -KubectlContextName "$ContextName`:$ArgoCdNamespace"

        Wait-ArgoCDAuthReady `
            -ArgoCdNamespace    $ArgoCdNamespace `
            -AuthCheckInterval  $timeouts.AuthCheckInterval `
            -AuthTimeoutSeconds $timeouts.AuthTimeoutSeconds `
            -ContextName        $ContextName `
            -InsecureTls:$InsecureTls.IsPresent

        Wait-ArgoCDPodsReady -Namespace $ArgoCdNamespace -CheckInterval $timeouts.PodReadyCheckInterval -TimeoutSeconds $timeouts.PodReadyTimeoutSeconds

        Write-LogMessage -Type DEBUG -Message "ArgoCD namespace `"$ContextName`:$ArgoCdNamespace`" is now available with all pods ready."

    } catch [VcfDeploymentException] {
        throw  # already logged and typed — propagate without re-wrapping
    } catch {
        $err = "Failed to add ArgoCD instance: $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
}
function Invoke-KubectlWithContextFix {

    <#
        .SYNOPSIS
        Runs a kubectl command and, on localhost:8080 errors, re-establishes the VCF context and retries.

        .DESCRIPTION
        Executes $Script:KubectlCmd with the provided arguments. If the exit code is non-zero and the error
        matches the localhost:8080 context-mismatch pattern, attempts to re-establish the VCF context via
        $Script:VcfCmd context use (namespace-scoped first, then base context). Returns a result object
        with Success, Output (on success), WarningMessage, and IsContextError.

        .PARAMETER ContextName
        VCF context name for context re-establishment. If omitted and a localhost:8080 error occurs,
        the function returns Success=$false with an appropriate WarningMessage.

        .PARAMETER InsecureTls
        When set, passes --insecure-skip-tls-verify to the context use command.

        .PARAMETER KubectlArgs
        Array of arguments to pass to $Script:KubectlCmd (e.g. @("get", "svc", "-n", "ns", "-o", "json")).

        .PARAMETER Namespace
        Optional namespace for namespace-scoped context attempt (${ContextName}:$Namespace). Falls back to
        base context if namespace-scoped attempt fails.

        .PARAMETER RetryDelaySeconds
        Seconds to wait after fixing the context before retrying kubectl. Default is 2.

        .OUTPUTS
        PSCustomObject with Success=[Bool], Output=[Object[]], WarningMessage=[String], IsContextError=[Bool].

        .EXAMPLE
        $kubectlResult = Invoke-KubectlWithContextFix `
            -KubectlArgs       @("get", "svc", "argocd-server", "-n", $ArgoCdNamespace, "-o", "json") `
            -ContextName       $ContextName `
            -Namespace         $ArgoCdNamespace `
            -InsecureTls:$InsecureTls.IsPresent `
            -RetryDelaySeconds $RetryDelaySeconds
        if (-not $kubectlResult.Success) {
            Write-LogMessage -Type WARNING -Message $kubectlResult.WarningMessage
            return
        }
        $svcJson = $kubectlResult.Output | ConvertFrom-Json

        .NOTES
        Shared between Show-ArgoCDInstanceDetails and Get-HarborLoadBalancerIp to eliminate duplicate
        localhost:8080 recovery logic. IsContextError=$false indicates a non-context error (e.g. service not
        found); callers use this to format service-specific messages around the raw WarningMessage.
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $false)] [String]$ContextName,
        [Parameter(Mandatory = $false)] [Switch]$InsecureTls,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String[]]$KubectlArgs,
        [Parameter(Mandatory = $false)] [String]$Namespace,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 60)] [Int]$RetryDelaySeconds = 2
    )

    $tlsArgs = @(if ($InsecureTls) { "--insecure-skip-tls-verify" })
    $errorOutput = $null
    $output = & $Script:KubectlCmd @KubectlArgs 2>&1 | Tee-Object -Variable errorOutput

    if ($LASTEXITCODE -eq 0) {
        return [PSCustomObject]@{ Success = $true; Output = $output; WarningMessage = $null; IsContextError = $false }
    }

    $errorMessage = ($errorOutput | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] -or ($_ -is [string]) }) -join " "

    if ($errorMessage -notmatch "localhost:8080|dial tcp.*8080|\[::1\]:8080|Unable to connect to the server.*dial tcp") {
        return [PSCustomObject]@{ Success = $false; Output = $null; WarningMessage = $errorMessage; IsContextError = $false }
    }

    Write-LogMessage -Type WARNING -Message "kubectl is pointing to localhost:8080. Attempting to fix VCF context..."
    if ([String]::IsNullOrWhiteSpace($ContextName)) {
        return [PSCustomObject]@{ Success = $false; Output = $null; WarningMessage = "kubectl context issue detected but no context name provided. Cannot automatically fix."; IsContextError = $true }
    }

    try {
        $contextToUse = if ([String]::IsNullOrWhiteSpace($Namespace)) { $ContextName } else { "${ContextName}:$Namespace" }
        Write-LogMessage -Type DEBUG -Message "Re-switching to VCF context `"$contextToUse`"..."
        $contextUseOutput = & $Script:VcfCmd context use $contextToUse @tlsArgs 2>&1
        $contextUseExitCode = $LASTEXITCODE
        if ($contextUseExitCode -ne 0 -and -not [String]::IsNullOrWhiteSpace($Namespace)) {
            Write-LogMessage -Type DEBUG -Message "Namespace-scoped context failed; trying base context `"$ContextName`"..."
            $contextUseOutput = & $Script:VcfCmd context use $ContextName @tlsArgs 2>&1
            $contextUseExitCode = $LASTEXITCODE
        }
        $contextUseText = ($contextUseOutput | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.ToString() } else { [String]$_ }
        }) -join "`n"
        $contextActivated = $contextUseText -match "Successfully activated"
        if ($contextUseExitCode -ne 0 -and $contextActivated) {
            Write-LogMessage -Type DEBUG -Message "VCF context use returned non-zero but output shows 'Successfully activated'; treating as success."
        }
        if ($contextUseExitCode -ne 0 -and -not $contextActivated) {
            $contextError = ($contextUseOutput | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] -or ($_ -is [string] -and $_ -match "error|Error|Unable|Cannot") }) -join " "
            $warnMsg = if ($contextError) { "Failed to re-establish VCF context: $contextError" } else { "Failed to re-establish VCF context (exit code: $contextUseExitCode)." }
            return [PSCustomObject]@{ Success = $false; Output = $null; WarningMessage = $warnMsg; IsContextError = $true }
        }
        Write-LogMessage -Type INFO -Message "VCF context re-established. Retrying kubectl..."
        Start-Sleep -Seconds $RetryDelaySeconds
        $retryErrorOutput = $null
        $retryOutput = & $Script:KubectlCmd @KubectlArgs 2>&1 | Tee-Object -Variable retryErrorOutput
        if ($LASTEXITCODE -eq 0) {
            Write-LogMessage -Type INFO -Message "kubectl context fixed successfully."
            return [PSCustomObject]@{ Success = $true; Output = $retryOutput; WarningMessage = $null; IsContextError = $false }
        }
        $retryErrorMessage = ($retryErrorOutput | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] -or ($_ -is [string]) }) -join " "
        return [PSCustomObject]@{ Success = $false; Output = $null; WarningMessage = "kubectl still failing after context fix: $retryErrorMessage"; IsContextError = $true }
    } catch {
        return [PSCustomObject]@{ Success = $false; Output = $null; WarningMessage = "Error attempting to fix kubectl context: $($_.Exception.Message)"; IsContextError = $true }
    }
}
function Show-ArgoCDInstanceDetails {

    <#
        .SYNOPSIS
        Displays ArgoCD instance connection details including login URL and initial admin password.

        .DESCRIPTION
        The Show-ArgoCDInstanceDetails function retrieves and displays the ArgoCD instance connection information
        for a deployed ArgoCD service. It fetches the load balancer IP address from the argocd-server service
        and retrieves the initial admin password from the Kubernetes secret. The function then displays login
        instructions and provides the command to update the admin password.

        This function is typically called after successfully deploying an ArgoCD instance to provide the user
        with the necessary information to access and configure the ArgoCD web interface.

        .PARAMETER ArgoCdNamespace
        The Kubernetes namespace where the ArgoCD instance is deployed. This parameter is mandatory and cannot
        be null or empty.

        .PARAMETER ContextName
        Optional VCF context name used to re-establish kubectl context if it points to localhost:8080.

        .PARAMETER InsecureTls
        When set, passes --insecure-skip-tls-verify when re-establishing VCF context.

        .PARAMETER RetryDelaySeconds
        Seconds to wait before retrying kubectl after a context fix. Default is 2.

        .EXAMPLE
        Show-ArgoCDInstanceDetails -ArgoCdNamespace "vks-ns-12345"
        Displays the ArgoCD login URL and initial admin password for the instance in the specified namespace.

        .OUTPUTS
        None
        This function writes informational messages to the log but does not return any output.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ArgoCdNamespace,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$ContextName,
        [Parameter(Mandatory = $false)] [Switch]$InsecureTls,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 60)] [Int]$RetryDelaySeconds = 2
    )

    # TLS certificate verification is intentionally disabled: ArgoCD deployments run without CA-signed certs.
    $kubectlResult = Invoke-KubectlWithContextFix `
        -KubectlArgs       @("get", "svc", "argocd-server", "-n", $ArgoCdNamespace, "-o", "json") `
        -ContextName       $ContextName `
        -Namespace         $ArgoCdNamespace `
        -InsecureTls:$InsecureTls.IsPresent `
        -RetryDelaySeconds $RetryDelaySeconds

    if (-not $kubectlResult.Success) {
        if ($kubectlResult.IsContextError) {
            Write-LogMessage -Type WARNING -Message $kubectlResult.WarningMessage
        } else {
            Write-LogMessage -Type WARNING -Message "ArgoCD server service not found in namespace `"$ArgoCdNamespace`": $($kubectlResult.WarningMessage)"
        }
        Write-LogMessage -Type INFO -Message "The ArgoCD instance may still be deploying. Please check the namespace status and try again later."
        return
    }

    $svcOutput = $kubectlResult.Output
    $svcJson = $svcOutput | ConvertFrom-Json
    if ($null -eq $svcJson -or $null -eq $svcJson.status -or $null -eq $svcJson.status.loadBalancer -or $null -eq $svcJson.status.loadBalancer.ingress) {
        Write-LogMessage -Type WARNING -Message "ArgoCD server service exists but does not have a load balancer IP address yet. The service may still be provisioning."
        Write-LogMessage -Type INFO -Message "Please wait for the load balancer to be assigned and try again later."
        return
    }

    $ipAddr = $svcJson.status.loadBalancer.ingress[0].ip
    if ($null -eq $ipAddr) {
        Write-LogMessage -Type WARNING -Message "ArgoCD server service load balancer does not have an IP address assigned yet."
        Write-LogMessage -Type INFO -Message "The service may still be provisioning. Please check again later."
        return
    }

    $secretErrorOutput = $null
    $encodedPassword = & $Script:KubectlCmd get secret -n $ArgoCdNamespace argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>&1 | Tee-Object -Variable secretErrorOutput

    if ($LASTEXITCODE -ne 0 -or $null -eq $encodedPassword -or $encodedPassword -match "Error|error|ERROR|NotFound|not found") {
        $secretErrorMessage = ($secretErrorOutput | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] -or ($_ -is [string]) }) -join " "
        Write-LogMessage -Type WARNING -Message "Failed to retrieve initial admin password for ArgoCD in namespace `"$ArgoCdNamespace`": $secretErrorMessage"
        Write-LogMessage -Type INFO -Message "The ArgoCD instance may still be deploying. The secret will be available once the instance is fully created."
        return
    }

    # Decode initial admin password from Base64 encoded string.
    $decodedPassword = $null
    try {
        $decodedPassword = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($encodedPassword))
    } catch [VcfDeploymentException] {
        throw  # already logged and typed — propagate without re-wrapping
    } catch {
        $err = "Failed to decode initial admin password for ArgoCD in namespace `"$ArgoCdNamespace`": $($_.Exception.Message)."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
    if ([String]::IsNullOrWhiteSpace($decodedPassword)) {
        $err = "Failed to decode initial admin password for ArgoCD in namespace `"$ArgoCdNamespace`"."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
    Write-LogMessage -Type INFO -ForceToScreen -Message "╔═══════════════════════════════════════╗"
    Write-LogMessage -Type INFO -ForceToScreen -Message "  ArgoCD Login"
    Write-LogMessage -Type INFO -ForceToScreen -Message "   Go to https://${ipAddr}/"
    Write-LogMessage -Type INFO -ForceToScreen -SuppressOutputToFile -Message "   Login as user `"admin`" using temporary password: $decodedPassword"
    Write-LogMessage -Type INFO -ForceToScreen -Message "   To update your password run: `"$Script:ArgocdCmd account update-password --server $ipAddr --account admin --insecure`""
    Write-LogMessage -Type INFO -ForceToScreen -Message "╚═══════════════════════════════════════╝"

    # Cleanup credentials.
    $secretErrorOutput = $null
    Remove-Variable -Name secretErrorOutput -Force -ErrorAction SilentlyContinue
    Remove-Variable -Name decodedPassword -Force
    Remove-Variable -Name encodedPassword -Force
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
}
function Resolve-HarborAdminPassword {

    <#
        .SYNOPSIS
        Resolves the Harbor admin password from up to three sources in priority order.

        .DESCRIPTION
        Checks (1) $env:HARBOR_ADMIN_PASSWORD, (2) HarborConfig.harborAdminPassword (supporting
        "$env:VARNAME" references), and (3) the harborAdminPassword key in the rendered data-values
        YAML file at YamlFilePath. Returns the first non-empty value found, or $null if none.

        .PARAMETER HarborConfig
        The harborConfiguration object from the cluster stanza in infrastructure JSON.

        .PARAMETER YamlFilePath
        Optional path to the rendered harbor data-values YAML file used as a final fallback.

        .OUTPUTS
        System.String. The resolved password, or $null if no password could be resolved.

        .NOTES
        Helper shared between Show-HarborInstanceDetails and Add-HarborContainerImageRegistry.
    
        .EXAMPLE
        $harborAdminPassword = Resolve-HarborAdminPassword -HarborConfig "value"
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSCustomObject]$HarborConfig,
        [Parameter(Mandatory = $false)] [String]$YamlFilePath
    )

    $adminPassword = $env:HARBOR_ADMIN_PASSWORD
    if ([String]::IsNullOrWhiteSpace($adminPassword)) {
        $rawPassword = $HarborConfig.harborAdminPassword
        if (-not [String]::IsNullOrWhiteSpace($rawPassword)) {
            if ($rawPassword -match '^\$env:([A-Za-z_][A-Za-z0-9_]*)$') {
                $adminPassword = [System.Environment]::GetEnvironmentVariable($Matches[1])
            } else {
                $adminPassword = $rawPassword
            }
        }
    }
    if ([String]::IsNullOrWhiteSpace($adminPassword) -and -not [String]::IsNullOrWhiteSpace($YamlFilePath) -and (Test-Path -Path $YamlFilePath)) {
        $yamlContent = Get-Content -Path $YamlFilePath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($yamlContent -match '(?m)^harborAdminPassword:\s+(\S.*)$') {
            $adminPassword = $Matches[1].Trim()
        }
    }
    if ([String]::IsNullOrWhiteSpace($adminPassword)) { return $null }
    return $adminPassword
}
function Get-HarborLoadBalancerIp {

    <#
        .SYNOPSIS
        Discovers the Harbor load balancer external IP via kubectl get svc.

        .DESCRIPTION
        Runs "kubectl get svc -n HarborNamespace -o json" and extracts the first LoadBalancer ingress IP.
        On localhost:8080 kubectl errors, attempts to fix the VCF context using ContextName and retries once.
        Returns $null when the IP cannot be determined.

        .PARAMETER ContextName
        Optional VCF context name used to re-establish kubectl context on localhost:8080 errors.

        .PARAMETER HarborNamespace
        The svc-harbor-* namespace where the Harbor services reside.

        .PARAMETER InsecureTls
        When set, passes --insecure-skip-tls-verify to the context use command during the fix attempt.

        .PARAMETER RetryDelaySeconds
        Seconds to wait after fixing the context before retrying kubectl. Default is 2.

        .OUTPUTS
        System.String. The load balancer IP, or $null if not found.

        .NOTES
        Helper shared between Show-HarborInstanceDetails and Add-HarborContainerImageRegistry.
    
        .EXAMPLE
        $harborLoadBalancerIp = Get-HarborLoadBalancerIp -HarborNamespace "argocd"
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $false)] [String]$ContextName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$HarborNamespace,
        [Parameter(Mandatory = $false)] [Switch]$InsecureTls,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 60)] [Int]$RetryDelaySeconds = 2
    )

    # TLS certificate verification is intentionally disabled: Harbor deployments run without CA-signed certs.
    $kubectlResult = Invoke-KubectlWithContextFix `
        -KubectlArgs       @("get", "svc", "-n", $HarborNamespace, "-o", "json") `
        -ContextName       $ContextName `
        -InsecureTls:$InsecureTls.IsPresent `
        -RetryDelaySeconds $RetryDelaySeconds

    if (-not $kubectlResult.Success) {
        if ($kubectlResult.IsContextError -and -not [String]::IsNullOrWhiteSpace($kubectlResult.WarningMessage)) {
            Write-LogMessage -Type WARNING -Message $kubectlResult.WarningMessage
        }
        return $null
    }
    $svcOutput = $kubectlResult.Output
    try {
        $svcJson = $svcOutput | ConvertFrom-Json
        foreach ($item in $svcJson.items) {
            if ($item.spec.type -eq "LoadBalancer" -and $item.status.loadBalancer.ingress) {
                $candidateIp = $item.status.loadBalancer.ingress[0].ip
                if (-not [String]::IsNullOrWhiteSpace($candidateIp)) { return $candidateIp }
            }
        }
    } catch {
        Write-LogMessage -Type DEBUG -Message "Get-HarborLoadBalancerIp: Failed to parse kubectl svc output for namespace `"$HarborNamespace`": $($_.Exception.Message)"
    }
    return $null
}
function Invoke-HarborRegistryIdempotencyCheck {

    <#
        .SYNOPSIS
        Checks whether a Harbor container image registry already exists on the supervisor.

        .DESCRIPTION
        Lists existing container image registries and looks for one matching RegistryName.
        - Not found: returns $true (proceed with registration).
        - Found with a different endpoint: logs and returns $false (skip registration).
        - Found with the same endpoint (stale entry): removes the entry and returns $true (re-register).
        - Delete fails: logs and returns $false (skip).
        - Listing fails: logs a warning and returns $true (proceed anyway).

        .PARAMETER RegistryEndpoint
        The current Harbor load balancer IP or hostname for endpoint comparison.

        .PARAMETER RegistryName
        The name of the container image registry entry to check.

        .PARAMETER SupervisorId
        The supervisor UUID where the registry check is performed.

        .OUTPUTS
        System.Boolean. $true to proceed with registration; $false to skip.

        .NOTES
        Helper extracted from Add-HarborContainerImageRegistry to satisfy the 80-line body limit.
    
        .EXAMPLE
        Invoke-HarborRegistryIdempotencyCheck -RegistryEndpoint "value" -RegistryName "resource-name" -SupervisorId "domain-c123"
    #>

    [CmdletBinding()]
    [OutputType([Boolean])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$RegistryEndpoint,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$RegistryName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorId
    )

    try {
        $existingRegistries = Invoke-ListSupervisorNamespaceManagementContainerImageRegistries -Supervisor $SupervisorId -ErrorAction Stop
        $existingEntry = @($existingRegistries) | Where-Object { $_.name -eq $RegistryName } | Select-Object -First 1
        if ($null -eq $existingEntry) { return $true }
        $existingHostname = $existingEntry.imageRegistry.hostname
        if (-not [String]::IsNullOrWhiteSpace($existingHostname) -and $existingHostname -ne $RegistryEndpoint) {
            Write-LogMessage -Type INFO -Message "Harbor container image registry `"$RegistryName`" is already registered on supervisor `"$SupervisorId`" with a different endpoint (`"$existingHostname`"). Skipping re-registration."
            return $false
        }
        Write-LogMessage -Type INFO -Message "Harbor container image registry `"$RegistryName`" already exists on supervisor `"$SupervisorId`" (endpoint: `"$existingHostname`"). Removing stale entry before re-registration..."
        try {
            Invoke-DeleteSupervisorContainerImageRegistryNamespaceManagementContainerImageRegistries -Supervisor $SupervisorId -ContainerImageRegistry $existingEntry.id -Confirm:$false -ErrorAction Stop | Out-Null
            Write-LogMessage -Type DEBUG -Message "Stale container image registry `"$RegistryName`" removed from supervisor `"$SupervisorId`"."
        } catch {
            Write-LogMessage -Type WARNING -Message "Add-HarborContainerImageRegistry: Could not remove stale registry `"$RegistryName`" (id: `"$($existingEntry.id)`"): $($_.Exception.Message). Skipping re-registration."
            return $false
        }
        return $true
    } catch {
        Write-LogMessage -Type WARNING -Message "Add-HarborContainerImageRegistry: Could not list existing container image registries; proceeding with registration attempt. $($_.Exception.Message)"
        return $true
    }
}
function Show-HarborInstanceDetails {

    <#
        .SYNOPSIS
        Displays Harbor instance connection details after successful installation.

        .DESCRIPTION
        After Harbor is successfully installed as a Supervisor Service, this function:
        - Resolves the admin password using three sources in priority order: (1) $env:HARBOR_ADMIN_PASSWORD,
          (2) harborConfiguration.harborAdminPassword from the infrastructure JSON (supporting "$env:VARNAME"
          references), (3) the harborAdminPassword key read directly from the rendered harbor data-values
          YAML file at YamlFilePath. This last fallback covers the common case where the password is set
          only in the YAML template and not in the infrastructure JSON.
        - Discovers the svc-harbor-* namespace via kubectl (Invoke-ListNamespacesInstances cannot
          see the system namespaces created by the Supervisor Services controller).
        - Queries all LoadBalancer services in that namespace via kubectl and returns the first
          external IP found.
        - Logs the Harbor URL (https://<lb-ip>), username ("admin"), and resolved admin password
          (screen only; never written to the log file).
        - Advises the user to create a DNS record pointing harborConfiguration.hostname to the LB IP.
        When LabGeneratedSelfSignedTls is set, notes that TLS uses a lab-generated self-signed certificate.
        Best-effort: logs warnings rather than throwing on kubectl or namespace-discovery failures.

        .PARAMETER ClusterName
        The cluster name for log messages.

        .PARAMETER ContextName
        Optional VCF context name used to re-establish kubectl context if it points to localhost:8080.

        .PARAMETER HarborConfig
        The harborConfiguration object from the cluster stanza in infrastructure JSON.

        .PARAMETER InsecureTls
        When set, passes --insecure-skip-tls-verify when re-establishing VCF context.

        .PARAMETER LabGeneratedSelfSignedTls
        When set, Harbor TLS was generated in lab mode (common.labenvironment true with tlsCrt/tlsKey omitted).

        .PARAMETER RetryDelaySeconds
        Seconds to wait before retrying kubectl after a context fix. Default is 2.

        .PARAMETER SupervisorId
        The supervisor UUID; used for log messages.

        .PARAMETER YamlFilePath
        Optional. Path to the rendered harbor data-values YAML file. When the password is not
        resolvable from the environment or infrastructure JSON, this file is grepped for the
        harborAdminPassword key as a final fallback. Pass the temp YAML path produced by
        New-HarborDataValuesFile while it still exists (before the finally cleanup).

        .EXAMPLE
        Show-HarborInstanceDetails -ClusterName "cluster-OSA" -HarborConfig $harborConfig -SupervisorId $supervisorId -ContextName $contextName -YamlFilePath $harborTempYamlPath

        .OUTPUTS
        None. Logs connection info; does not throw.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [String]$ContextName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSCustomObject]$HarborConfig,
        [Parameter(Mandatory = $false)] [Switch]$InsecureTls,
        [Parameter(Mandatory = $false)] [Switch]$LabGeneratedSelfSignedTls,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 60)] [Int]$RetryDelaySeconds = 2,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorId,
        [Parameter(Mandatory = $false)] [String]$YamlFilePath
    )

    $resolvedPassword = Resolve-HarborAdminPassword -HarborConfig $HarborConfig -YamlFilePath $YamlFilePath
    $adminPassword = if (-not [String]::IsNullOrWhiteSpace($resolvedPassword)) { $resolvedPassword } else { "[not configured]" }

    # Invoke-ListNamespacesInstances only surfaces user namespaces; use kubectl to find the svc-harbor-* system namespace.
    $harborDiscovery = Get-KubectlNamespaceNamesMatchingPattern -DebugLogPrefix "Show-HarborInstanceDetails" -NameLike "svc-harbor*" -SortNames
    $harborNamespace = $null
    if ($harborDiscovery.KubectlSucceeded -and $harborDiscovery.Names.Count -gt 0) {
        $harborNamespace = $harborDiscovery.Names[-1]
    }

    Write-LogMessage -Type INFO -ForceToScreen -Message "╔═══════════════════════════════════════╗"
    Write-LogMessage -Type INFO -ForceToScreen -Message "  Harbor — $ClusterName"
    Write-LogMessage -Type INFO -ForceToScreen -Message "  Username : admin"
    Write-LogMessage -Type INFO -ForceToScreen -SuppressOutputToFile -Message "  Password : $adminPassword"

    if ([String]::IsNullOrWhiteSpace($harborNamespace)) {
        Write-LogMessage -Type WARNING -Message "Harbor namespace (svc-harbor-*) not found via kubectl on supervisor `"$SupervisorId`". Verify kubectl context, then run: kubectl get namespace"
        Write-LogMessage -Type INFO -ForceToScreen -Message "  Namespace: <unknown>   (run: kubectl get namespace | Select-String svc-harbor)"
        Write-LogMessage -Type INFO -ForceToScreen -Message "  URL      : https://<load-balancer-ip>   (find IP: kubectl get svc -n <svc-harbor-*-namespace>)"
        Write-LogMessage -Type INFO -ForceToScreen -Message "  DNS      : Create a record pointing `"$($HarborConfig.hostname)`" to the Harbor load balancer external IP."
        if ($LabGeneratedSelfSignedTls.IsPresent) {
            Write-LogMessage -Type INFO -ForceToScreen -Message "  TLS      : Self-signed certificate (lab mode: common.labenvironment true; tlsCrt/tlsKey were omitted). Browsers and clients will warn until you trust the certificate or replace TLS with your own PEM files."
        }
        Write-LogMessage -Type INFO -ForceToScreen -Message "╚═══════════════════════════════════════╝"
        Remove-Variable -Name adminPassword -Force -ErrorAction SilentlyContinue
        return
    }

    $lbIp = Get-HarborLoadBalancerIp -HarborNamespace $harborNamespace -ContextName $ContextName -InsecureTls:$InsecureTls.IsPresent -RetryDelaySeconds $RetryDelaySeconds

    Write-LogMessage -Type INFO -ForceToScreen -Message "  Namespace: $harborNamespace"
    if (-not [String]::IsNullOrWhiteSpace($lbIp)) {
        Write-LogMessage -Type INFO -ForceToScreen -Message "  URL      : https://$lbIp"
        Write-LogMessage -Type INFO -ForceToScreen -Message "  DNS      : Create a record pointing `"$($HarborConfig.hostname)`" to $lbIp (Harbor load balancer external IP)."
    } else {
        Write-LogMessage -Type INFO -ForceToScreen -Message "  URL      : https://<load-balancer-ip>   (find IP: kubectl get svc -n $harborNamespace)"
        Write-LogMessage -Type INFO -ForceToScreen -Message "  DNS      : Create a record pointing `"$($HarborConfig.hostname)`" to the Harbor load balancer external IP."
    }
    if ($LabGeneratedSelfSignedTls.IsPresent) {
        Write-LogMessage -Type INFO -ForceToScreen -Message "  TLS      : Self-signed certificate (lab mode: common.labenvironment true; tlsCrt/tlsKey were omitted). Browsers and clients will warn until you trust the certificate or replace TLS with your own PEM files."
    }
    Write-LogMessage -Type INFO -ForceToScreen -Message "╚═══════════════════════════════════════╝"

    Remove-Variable -Name adminPassword -Force -ErrorAction SilentlyContinue
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
}
function Get-Base64FromYml {

    <#
        .SYNOPSIS
        Converts a YAML file to Base64 encoded string format for supervisor service deployment.

        .DESCRIPTION
        The Get-Base64FromYml function reads a YAML file and converts its content to a Base64 encoded string.
        This encoding is required when creating supervisor service content through the vSphere APIs, as the
        service specifications must be provided in Base64 format. The function reads the entire file content
        as raw text, converts it to UTF-8 bytes, and then encodes it using Base64 encoding.

        This function is typically used in the context of deploying supervisor services like ArgoCD, where
        the service configuration YAML needs to be embedded in API requests as Base64 encoded content.

        .PARAMETER Path
        The full path to the YAML file that needs to be converted to Base64 format. The file must exist
        and be readable. This parameter is mandatory and cannot be null or empty.

        .EXAMPLE
        Get-Base64FromYml -Path "./configs/argocd-service.yml"
        Converts the ArgoCD service YAML file to Base64 encoded string.

        .EXAMPLE
        $base64Content = Get-Base64FromYml -Path $argoCDyaml
        Stores the Base64 encoded content of the YAML file in a variable for later use in API calls.

        .OUTPUTS
        System.String
        Returns a Base64 encoded string representation of the YAML file content.

        .NOTES
        - The function reads the entire file content into memory, so it may not be suitable for very large files
        - The encoding uses UTF-8 character encoding before Base64 conversion
        - This function is commonly used with Set-ArgoCDService to deploy supervisor services
        - The returned Base64 string can be directly used in vSphere supervisor service API calls

        .LINK
        Set-ArgoCDService
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Path
    )

    Write-LogMessage -Type DEBUG -Message "Entered Get-Base64FromYml function..."

    try {
        if (-not (Test-Path -Path $Path)) {
            $err = "YAML file not found: $Path"
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }

        $raw = Get-Content -Path $Path -Raw -ErrorAction Stop
        $base64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($raw))

        return $base64
    } catch [VcfDeploymentException] {
        throw  # already logged and typed — propagate without re-wrapping
    } catch {
        $err = "Get-Base64FromYml: Failed to read or encode YAML file `"$Path`": $($_.Exception.Message)."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
}
function Set-ArgoCDService {

    <#
        .SYNOPSIS
        The function creates the ArgoCD service using yml file.

        .DESCRIPTION
        The function creates the ArgoCD service using yml file. It converts Yaml into
        base64 encoding format and creates a carvel spec and using API to create the service.

        .EXAMPLE
        Set-ArgoCDService -Path <.yml file path>

        .PARAMETER -Path
        Location of the yaml file.

    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Path
    )

    Write-LogMessage -Type DEBUG -Message "Entered Set-ArgoCDService function..."

    try {
        $base64Content = Get-Base64FromYml -Path $Path
        $argoServiceName, $argoServiceVersion = Get-ArgoCDServiceDetail -Path $Path
        $vcenterNamespaceManagementSupervisorServicesVersionsCarvelCreateSpec = Initialize-VcenterNamespaceManagementSupervisorServicesVersionsCarvelCreateSpec -Content $base64Content
        $vcenterNamespaceManagementSupervisorServicesCarvelCreateSpec = Initialize-VcenterNamespaceManagementSupervisorServicesCarvelCreateSpec -VersionSpec $vcenterNamespaceManagementSupervisorServicesVersionsCarvelCreateSpec
        $createSpecCmd = Get-VcfSdkInitializeCommand -NameCandidates @(
            "Initialize-NamespaceManagementSupervisorServicesCreateSpec",
            "Initialize-VcenterNamespaceManagementSupervisorServicesCreateSpec"
        )
        if (-not $createSpecCmd) {
            $err = "Required cmdlet for Supervisor Services CreateSpec was not found (Initialize-NamespaceManagementSupervisorServicesCreateSpec or Initialize-VcenterNamespaceManagementSupervisorServicesCreateSpec)."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
        $vcenterNamespaceManagementSupervisorServicesCheckContentRequest = & $createSpecCmd -CarvelSpec $vcenterNamespaceManagementSupervisorServicesCarvelCreateSpec
        Invoke-CreateNamespaceManagementSupervisorServices -vcenterNamespaceManagementSupervisorServicesCreateSpec $vcenterNamespaceManagementSupervisorServicesCheckContentRequest -Confirm:$false -ErrorAction Stop | Out-Null
        Write-LogMessage -Type INFO -Message "Successfully created ArgoCD service `"$argoServiceName`" version `"$argoServiceVersion`"."
    } catch {
        $errMsg = $_.Exception.Message

        if ($errMsg -match "an instance of Supervisor Service with the same identifier already exists") {
            Write-LogMessage -Type DEBUG -Message "ArgoCD service `"$argoServiceName`" version `"$argoServiceVersion`" already. This is expected when deploying multiple supervisor clusters on the same vCenter."
        }
        else {
            $err = "ArgoCD service `"$argoServiceName`" version `"$argoServiceVersion`" creation failed: $($_.Exception.Message)"
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
    }
}
function Set-HarborService {

    <#
        .SYNOPSIS
        Registers the Harbor Supervisor Service definition using a harbor-service YAML file.

        .DESCRIPTION
        Reads the harbor-service-x.xx.x.yml Carvel package file, encodes it as base64, and registers
        it as a Supervisor Service in vCenter using Invoke-CreateNamespaceManagementSupervisorServices.
        If the service already exists (same version), the error is treated as a no-op since this is
        expected when deploying multiple supervisor clusters on the same vCenter.

        .PARAMETER Path
        Full path to the harbor-service-x.xx.x.yml Carvel package file downloaded from Broadcom.

        .EXAMPLE
        Set-HarborService -Path "/path/to/harbor-service-v2.14.2.yml"

        .OUTPUTS
        None. Throws on unrecoverable errors.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Path
    )

    Write-LogMessage -Type DEBUG -Message "Entered Set-HarborService function..."

    try {
        $base64Content = Get-Base64FromYml -Path $Path
        $harborServiceName, $harborServiceVersion = Get-ArgoCDServiceDetail -Path $Path
        $vcenterNamespaceManagementSupervisorServicesVersionsCarvelCreateSpec = Initialize-VcenterNamespaceManagementSupervisorServicesVersionsCarvelCreateSpec -Content $base64Content
        $vcenterNamespaceManagementSupervisorServicesCarvelCreateSpec = Initialize-VcenterNamespaceManagementSupervisorServicesCarvelCreateSpec -VersionSpec $vcenterNamespaceManagementSupervisorServicesVersionsCarvelCreateSpec
        $createSpecCmd = Get-VcfSdkInitializeCommand -NameCandidates @(
            "Initialize-NamespaceManagementSupervisorServicesCreateSpec",
            "Initialize-VcenterNamespaceManagementSupervisorServicesCreateSpec"
        )
        if (-not $createSpecCmd) {
            $err = "Required cmdlet for Supervisor Services CreateSpec was not found (Initialize-NamespaceManagementSupervisorServicesCreateSpec or Initialize-VcenterNamespaceManagementSupervisorServicesCreateSpec)."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
        $vcenterNamespaceManagementSupervisorServicesCheckContentRequest = & $createSpecCmd -CarvelSpec $vcenterNamespaceManagementSupervisorServicesCarvelCreateSpec
        Invoke-CreateNamespaceManagementSupervisorServices -vcenterNamespaceManagementSupervisorServicesCreateSpec $vcenterNamespaceManagementSupervisorServicesCheckContentRequest -Confirm:$false -ErrorAction Stop | Out-Null
        Write-LogMessage -Type INFO -Message "Successfully registered Harbor service `"$harborServiceName`" version `"$harborServiceVersion`"."
    } catch {
        $errMsg = $_.Exception.Message
        if ($errMsg -match "an instance of Supervisor Service with the same identifier already exists") {
            Write-LogMessage -Type INFO -Message "Harbor service `"$harborServiceName`" version `"$harborServiceVersion`" is already registered globally on this vCenter. Skipping re-registration."
        } else {
            $err = "Harbor service `"$harborServiceName`" version `"$harborServiceVersion`" registration failed: $($_.Exception.Message)"
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
    }
}
function Add-HarborContainerImageRegistry {

    <#
        .SYNOPSIS
        Registers Harbor as a container image registry on a Supervisor. Best-effort; logs warnings on failure.

        .DESCRIPTION
        After Harbor is successfully installed as a Supervisor Service, this function registers it as a container
        image registry on the Supervisor using the ContainerImageRegistries API. This enables the Supervisor to use
        Harbor as its default container image registry for Supervisor service and PodVM images.

        The Harbor load balancer IP is discovered via kubectl get namespaces / get svc (the same method used by
        Show-HarborInstanceDetails). If the LB IP cannot be discovered, the function falls back to the
        harborConfiguration.hostname value.

        Admin password is resolved in priority order: (1) $env:HARBOR_ADMIN_PASSWORD, (2) HarborConfig.harborAdminPassword
        (supporting "$env:VARNAME" references), (3) the harborAdminPassword key read from YamlFilePath.

        Idempotent with stale-entry recovery: if a registry named RegistryName already exists on the Supervisor
        and its endpoint matches the current Harbor load balancer IP, the old entry is unregistered and then
        re-registered (indicating cleanup did not remove it). If the existing entry has a different endpoint
        (a different Harbor instance), the function logs an informational message and returns without changes.

        Non-fatal: all API and kubectl errors are caught and logged as warnings. The Harbor deployment is considered
        successful regardless of whether this registration step succeeds.

        .PARAMETER ClusterName
        The cluster name for log messages.

        .PARAMETER ContextName
        Optional VCF context name used to re-establish kubectl context if it points to localhost:8080.

        .PARAMETER HarborConfig
        The harborConfiguration object from the cluster stanza in infrastructure JSON. Used to resolve the admin
        password and hostname, and to locate the CA certificate file.

        .PARAMETER InsecureTls
        When set, passes --insecure-skip-tls-verify when re-establishing VCF context.

        .PARAMETER RegistryName
        The name to assign to this container image registry entry. Default is "harbor".

        .PARAMETER RetryDelaySeconds
        Seconds to wait before retrying kubectl after a context fix. Default is 2.

        .PARAMETER SupervisorId
        The supervisor UUID where Harbor is installed and where the registry will be registered.

        .PARAMETER YamlFilePath
        Optional. Path to the rendered harbor data-values YAML file used as a final fallback for password
        resolution. Pass the temp YAML path produced by New-HarborDataValuesFile while it still exists.

        .EXAMPLE
        Add-HarborContainerImageRegistry -ClusterName "cluster-OSA" -ContextName $contextName -HarborConfig $harborConfig -InsecureTls -SupervisorId $supervisorId -YamlFilePath $harborTempYamlPath

        .OUTPUTS
        None. Logs result; does not throw.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [String]$ContextName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSCustomObject]$HarborConfig,
        [Parameter(Mandatory = $false)] [Switch]$InsecureTls,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$RegistryName = "harbor",
        [Parameter(Mandatory = $false)] [ValidateRange(1, 60)] [Int]$RetryDelaySeconds = 2,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorId,
        [Parameter(Mandatory = $false)] [String]$YamlFilePath
    )

    Write-LogMessage -Type DEBUG -Message "Entered Add-HarborContainerImageRegistry: supervisor=`"$SupervisorId`", cluster=`"$ClusterName`"."

    $adminPassword = Resolve-HarborAdminPassword -HarborConfig $HarborConfig -YamlFilePath $YamlFilePath
    if ([String]::IsNullOrWhiteSpace($adminPassword)) {
        Write-LogMessage -Type WARNING -Message "Add-HarborContainerImageRegistry: Harbor admin password could not be resolved. Skipping container image registry registration."
        return
    }

    $harborDiscovery = Get-KubectlNamespaceNamesMatchingPattern -DebugLogPrefix "Add-HarborContainerImageRegistry" -NameLike "svc-harbor*" -SortNames
    $harborNamespace = if ($harborDiscovery.KubectlSucceeded -and $harborDiscovery.Names.Count -gt 0) { $harborDiscovery.Names[-1] } else { $null }
    $lbIp = if (-not [String]::IsNullOrWhiteSpace($harborNamespace)) {
        Get-HarborLoadBalancerIp -HarborNamespace $harborNamespace -ContextName $ContextName -InsecureTls:$InsecureTls.IsPresent -RetryDelaySeconds $RetryDelaySeconds
    } else { $null }

    $registryEndpoint = if (-not [String]::IsNullOrWhiteSpace($lbIp)) { $lbIp } else { $HarborConfig.hostname }
    Write-LogMessage -Type DEBUG -Message "Add-HarborContainerImageRegistry: using endpoint `"$registryEndpoint`"$(if ([String]::IsNullOrWhiteSpace($lbIp)) { ' (hostname fallback; LB IP not discoverable)' })."

    $certChain = $null
    $caCrtPath = $HarborConfig.caCrt
    if (-not [String]::IsNullOrWhiteSpace($caCrtPath) -and (Test-Path -Path $caCrtPath -PathType Leaf)) {
        try {
            $certChain = Get-Content -Path $caCrtPath -Raw -Encoding UTF8
            Write-LogMessage -Type DEBUG -Message "Read CA certificate from `"$caCrtPath`" for Harbor container image registry registration."
        } catch {
            Write-LogMessage -Type WARNING -Message "Add-HarborContainerImageRegistry: Could not read CA certificate from `"$caCrtPath`": $($_.Exception.Message). Registering without certificate chain (TLS verification will be skipped by the Supervisor)."
        }
    }

    if (-not (Invoke-HarborRegistryIdempotencyCheck -SupervisorId $SupervisorId -RegistryName $RegistryName -RegistryEndpoint $registryEndpoint)) {
        return
    }

    Write-LogMessage -Type INFO -Message "Registering Harbor as container image registry `"$RegistryName`" on supervisor `"$SupervisorId`" for cluster `"$ClusterName`" (endpoint: `"$registryEndpoint`")..."

    $imageRegistryParams = @{
        Hostname = $registryEndpoint
        Password = $adminPassword
        Username = "admin"
    }
    if (-not [String]::IsNullOrWhiteSpace($certChain)) {
        $imageRegistryParams["CertificateChain"] = $certChain
    }

    try {
        $imageRegistry = Initialize-VcenterNamespaceManagementSupervisorsImageRegistry @imageRegistryParams
        $createSpec = Initialize-VcenterNamespaceManagementSupervisorsContainerImageRegistriesCreateSpec -DefaultRegistry $true -ImageRegistry $imageRegistry -Name $RegistryName
        $result = Invoke-CreateSupervisorNamespaceManagementContainerImageRegistries -Supervisor $SupervisorId -VcenterNamespaceManagementSupervisorsContainerImageRegistriesCreateSpec $createSpec -Confirm:$false -ErrorAction Stop
        Write-LogMessage -Type INFO -Message "Harbor container image registry `"$RegistryName`" registered on supervisor `"$SupervisorId`" for cluster `"$ClusterName`" (id: `"$($result.id)`", endpoint: `"$registryEndpoint`")."
    } catch {
        Write-LogMessage -Type WARNING -Message "Failed to register Harbor as container image registry on supervisor `"$SupervisorId`": $($_.Exception.Message). Harbor is still operational but is not configured as the Supervisor's container image registry. Register manually in vCenter (Supervisor → Configure → Container Registries)."
    } finally {
        Remove-Variable -Name adminPassword -Force -ErrorAction SilentlyContinue
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
    }
}
function Invoke-HarborServiceCreate {

    <#
        .SYNOPSIS
        Submits the Harbor Supervisor Service create request and handles the immediate API response.

        .DESCRIPTION
        Initializes the create spec, calls Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesCreate,
        and handles all immediate error cases returned by the API:
        - "already exists" — logs the idempotency message and returns normally so polling proceeds.
        - "terminating namespace" — logs a targeted remedy and throws.
        - "not activated" — logs a targeted remedy and throws.
        - "signature not found" — logs the version mismatch remedy and throws.
        - YAML parse error (default) — surfaces context lines around the error and throws.
        On a fresh install, logs the "submitted" message and sleeps CheckInterval seconds before
        returning so the polling loop in the caller does not race the initial API response.

        .PARAMETER CheckInterval
        Seconds to sleep after a successful (fresh) create request before returning.

        .PARAMETER NormalizedYaml
        The LF-only (CRLF-normalized) YAML content; used to display context lines when a YAML parse error occurs.

        .PARAMETER Service
        The Harbor supervisor service identifier (e.g. "harbor-service.vsphere.vmware.com").

        .PARAMETER ServiceNamespace
        Diagnostic namespace name computed from the service slug and cluster ID (e.g. "svc-harbor-domain-c1").

        .PARAMETER SupervisorId
        The supervisor UUID where Harbor will be created.

        .PARAMETER Version
        The Harbor service version string.

        .PARAMETER YamlBase64
        The base64-encoded YAML data values content for the create spec.

        .EXAMPLE
        Invoke-HarborServiceCreate -CheckInterval 5 -NormalizedYaml $normalizedYaml -Service "harbor-service.vsphere.vmware.com" -ServiceNamespace "svc-harbor-domain-c1" -SupervisorId "sv-001" -Version "2.12.0" -YamlBase64 $yamlBase64

        Submits the create request. Returns normally on success or "already exists"; throws on other errors.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateRange(1, [Int]::MaxValue)] [Int]$CheckInterval,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$NormalizedYaml,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Service,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ServiceNamespace,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorId,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Version,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$YamlBase64
    )

    $spec = Initialize-VcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec -SupervisorService $Service -Version $Version -YamlServiceConfig $YamlBase64
    try {
        Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesCreate -supervisor $SupervisorId -vcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec $spec -Confirm:$false -ErrorAction Stop
        Write-LogMessage -Type INFO -Message "Harbor service install request submitted. Waiting for configuration to complete."
        Start-Sleep $CheckInterval
    } catch {
        $errMsg = $_.Exception.Message
        switch -Regex ($errMsg) {
            "Supervisor Service.*already exists|an instance.*Supervisor Service.*already exists" {
                Write-LogMessage -Type INFO -Message "Harbor service already installed on supervisor `"$SupervisorId`". Verifying configuration status..."
            }
            "namespace \((\S+)\) is in terminating status" {
                $terminatingNamespace = $Matches[1]
                Write-LogMessage -Type ERROR -Message "Harbor installation failed: namespace `"$terminatingNamespace`" is still terminating on the Supervisor from a previous rollback."
                Write-LogMessage -Type INFO -Message ""
                $err = "SOLUTION: Wait for the namespace to finish deleting, then re-run this script. To check status: kubectl get namespace $terminatingNamespace"
                Write-LogMessage -Type ERROR -Message $err
                throw [VcfDeploymentException]::new($err)
            }
            "Supervisor Service is not in activated state" {
                $err = "Harbor service `"$Service`" version `"$Version`" is not in activated state on supervisor `"$SupervisorId`"."
                Write-LogMessage -Type ERROR -Message $err
                Write-LogMessage -Type INFO -Message ""
                Write-LogMessage -Type ERROR -Message "SOLUTION: In vCenter UI go to Menu > Supervisor Management > Services, find `"$Service`", and either deactivate then delete the service, then re-run this script."
                Write-LogMessage -Type WARNING -Message "If the service is stuck: kubectl delete namespace $ServiceNamespace"
                throw [VcfDeploymentException]::new($err)
            }
            "Signature verification result for Service Version \(([0-9.-]+)\) not found" {
                $requestedVersion = $matches[1]
                $cleanErrorMessage = Get-CleanErrorMessage -ErrorMessage $errMsg
                if ($cleanErrorMessage -eq $errMsg) {
                    $cleanErrorMessage = "Harbor service version $requestedVersion is not available on this supervisor."
                }
                $err = "Harbor installation failed: $cleanErrorMessage."
                Write-LogMessage -Type ERROR -Message $err
                Write-LogMessage -Type INFO -Message ""
                Write-LogMessage -Type ERROR -Message "SOLUTION: Upgrade your supervisor to a version that supports Harbor service $requestedVersion, or update supervisorServices.harborServiceYamlFileName (and parentDirectory) to a compatible Carvel package file."
                throw [VcfDeploymentException]::new($err)
            }
            default {
                $cleanMessage = Get-CleanErrorMessage -ErrorMessage $errMsg
                # When the API reports a YAML parse error at a specific line, surface the
                # context lines immediately so the user can correlate with the preserved temp file.
                if ($errMsg -match 'yaml: line (\d+):') {
                    $errorLineNum = [Int]$Matches[1]
                    $yamlLines = $NormalizedYaml -split "`n"
                    $startLine = [Math]::Max(1, $errorLineNum - 3)
                    $endLine = [Math]::Min($yamlLines.Count, $errorLineNum + 3)
                    Write-LogMessage -Type WARNING -Message "YAML parse error at line $errorLineNum. Lines $startLine-$endLine of the submitted YAML (see preserved temp file for full content):"
                    for ($i = $startLine; $i -le $endLine; $i++) {
                        $marker = if ($i -eq $errorLineNum) { ">>> " } else { "    " }
                        Write-LogMessage -Type WARNING -Message "$marker$i : $($yamlLines[$i - 1])"
                    }
                }
                $err = "Harbor installation failed: $cleanMessage"
                if ($cleanMessage -ne $errMsg) {
                    Write-LogMessage -Type ERROR -Message $err
                } else {
                    Write-LogMessage -Type ERROR -Message "Unexpected error in Install-HarborSupervisorService: $errMsg."
                }
                throw [VcfDeploymentException]::new($err)
            }
        }
    }
}
function Get-HarborEventTexts {

    <#
        .SYNOPSIS
        Gathers Kubernetes events from a list of namespaces and returns all-events and warning-only text.

        .DESCRIPTION
        Iterates over the provided namespaces, runs kubectl get events sorted by lastTimestamp,
        and builds two concatenated strings: one with all events and one with only Warning-type events.

        .PARAMETER NamespacesToCheck
        Array of Kubernetes namespace names to gather events from.

        .EXAMPLE
        $events = Get-HarborEventTexts -NamespacesToCheck @("svc-harbor-domain-c1")
        Write-LogMessage -Type INFO -Message $events.AllEventsText

        .NOTES
        Uses $Script:KubectlCmd to invoke kubectl. Errors from individual namespace event queries
        are logged at DEBUG level and do not propagate.
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [String[]]$NamespacesToCheck
    )

    $allParts  = [System.Collections.Generic.List[string]]::new()
    $warnParts = [System.Collections.Generic.List[string]]::new()
    foreach ($ns in $NamespacesToCheck) {
        try {
            $nsEventsOutput = & $Script:KubectlCmd get events -n $ns --sort-by=".lastTimestamp" 2>&1
            if ($LASTEXITCODE -eq 0 -and -not [String]::IsNullOrWhiteSpace($nsEventsOutput)) {
                $nsEventsStr = ($nsEventsOutput | Out-String).Trim()
                $allParts.Add($nsEventsStr)
                $nsLines    = $nsEventsStr -split "`n"
                $headerLine = $nsLines | Select-Object -First 1
                $warnLines  = $nsLines | Where-Object { $_ -match "\s+Warning\s+" }
                if ($warnLines.Count -gt 0) {
                    $warnParts.Add("$headerLine`n$($warnLines -join "`n")")
                }
            }
        } catch {
            Write-LogMessage -Type DEBUG -Message "Could not pre-fetch events from `"$ns`": $($_.Exception.Message)"
        }
    }
    return [PSCustomObject]@{
        AllEventsText     = $allParts -join "`n"
        WarningEventsText = $warnParts -join "`n"
    }
}
function Write-HarborOciRegistryDiagnostics {

    <#
        .SYNOPSIS
        Logs targeted remediation guidance and pod/PVC diagnostics when Harbor's OCI Registry component fails.

        .DESCRIPTION
        Inspects each Harbor namespace for PVCs and OCI Registry pod logs. Surfaces stale PVC
        AGE information, registry startup errors, and HA admission control warnings. Called when
        Harbor service ERROR status is paired with an "OCI Registry" error message.

        .PARAMETER DiagnosticNamespace
        The primary Harbor namespace name used in log messages and kubectl hints.

        .PARAMETER HarborAllEventsText
        Full concatenated events text for all Harbor namespaces, used for HA admission control detection.

        .PARAMETER HarborWarningEventsText
        Warning-only events text, shown when registry pods are not found and IpExhaustionDetected is false.

        .PARAMETER IpExhaustionDetected
        When true, suppresses OCI Registry diagnosis and solution messages because IP exhaustion is the root cause.

        .PARAMETER NamespacesToCheck
        Array of Harbor namespace names to inspect for PVCs and registry pod logs.

        .EXAMPLE
        Write-HarborOciRegistryDiagnostics -NamespacesToCheck @("svc-harbor-domain-c1") `
            -DiagnosticNamespace "svc-harbor-domain-c1" -IpExhaustionDetected $false `
            -HarborWarningEventsText "" -HarborAllEventsText ""

        .NOTES
        Uses $Script:KubectlCmd directly. Errors from individual kubectl calls are caught and logged at DEBUG.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]   $DiagnosticNamespace,
        [Parameter(Mandatory = $true)] [AllowEmptyString()]        [String]   $HarborAllEventsText,
        [Parameter(Mandatory = $true)] [AllowEmptyString()]        [String]   $HarborWarningEventsText,
        [Parameter(Mandatory = $true)] [ValidateNotNull()]         [Bool]     $IpExhaustionDetected,
        [Parameter(Mandatory = $true)] [ValidateNotNull()]         [String[]] $NamespacesToCheck
    )

    if (-not $IpExhaustionDetected) {
        Write-LogMessage -Type ERROR -Message "DIAGNOSIS: The OCI Registry component failed to initialize. Possible causes: (A) Stale PVCs from a prior installation hold data encrypted with different secrets — the registry pod cannot read its PVC if registry.secret changed. (B) The new deployment started before namespace `"$DiagnosticNamespace`" from a prior rollback had fully terminated, leaving stale endpoint or secret objects. (C) A Harbor data values configuration error (e.g. malformed or missing registry.secret, invalid storageClass, incorrect YAML structure). If the PVCs below show a recent AGE (seconds or a few minutes), they were created by the current install — cause (A) does not apply."
        Write-LogMessage -Type ERROR -Message "SOLUTION: (1) Roll back (choose Y) to remove this service. (2) Wait for namespace `"$DiagnosticNamespace`" to terminate fully: kubectl get namespace $DiagnosticNamespace (must be gone, not Terminating). (3) Confirm all PVCs are deleted: kubectl get pvc -n $DiagnosticNamespace (should return 'No resources found'). (4) If PVCs were stale: re-run using the SAME secrets, OR use -CleanUp Harbor first. If PVCs were fresh (new install): check the registry pod logs below for the specific error, then verify registry.secret, storageClass, and vCenter Events on the supervisor."
    }
    foreach ($ns in $NamespacesToCheck) {
        try {
            $pvcOutput = & $Script:KubectlCmd get pvc -n $ns 2>&1
            if ($LASTEXITCODE -eq 0 -and -not [String]::IsNullOrWhiteSpace($pvcOutput)) {
                Write-LogMessage -Type ERROR -Message "PVCs found in `"$ns`" (check AGE — if recent, these are from the current install and are not stale):"
                ($pvcOutput | Out-String).Trim() -split "`n" | ForEach-Object { Write-LogMessage -Type INFO -Message "  $_" }
            } elseif ($LASTEXITCODE -eq 0) {
                Write-LogMessage -Type INFO -Message "No PVCs found in `"$ns`". The namespace itself may still be Terminating — wait for it to disappear before redeploying."
            }
        } catch {
            Write-LogMessage -Type DEBUG -Message "Could not list PVCs in `"$ns`": $($_.Exception.Message)"
        }
        try {
            $registryLogOutput = & $Script:KubectlCmd logs -n $ns -l "app=registry" --tail=40 --prefix 2>&1
            $registryLogText   = ($registryLogOutput | Out-String).Trim()
            if ($LASTEXITCODE -eq 0 -and -not [String]::IsNullOrWhiteSpace($registryLogText) -and $registryLogText -notmatch "^No resources found") {
                Write-LogMessage -Type ERROR -Message "OCI Registry pod logs (last 40 lines, namespace `"$ns`") — look for the startup error:"
                $registryLogText -split "`n" | ForEach-Object { Write-LogMessage -Type INFO -Message "  $_" }
            } else {
                Write-LogMessage -Type WARNING -Message "No OCI Registry pods found in `"$ns`" (label app=registry). Pod may not have been scheduled. Showing all pods:"
                try {
                    $allPodsOutput = & $Script:KubectlCmd get pods -n $ns -o wide 2>&1
                    if ($LASTEXITCODE -eq 0 -and -not [String]::IsNullOrWhiteSpace($allPodsOutput)) {
                        ($allPodsOutput | Out-String).Trim() -split "`n" | ForEach-Object { Write-LogMessage -Type INFO -Message "  $_" }
                    } else {
                        Write-LogMessage -Type INFO -Message "  (no pods found in namespace `"$ns`")"
                    }
                } catch {
                    Write-LogMessage -Type DEBUG -Message "Could not list pods in `"$ns`": $($_.Exception.Message)"
                }
                if (-not $IpExhaustionDetected -and -not [String]::IsNullOrWhiteSpace($HarborWarningEventsText)) {
                    Write-LogMessage -Type WARNING -Message "Warning events in `"$ns`":"
                    $HarborWarningEventsText -split "`n" | ForEach-Object { Write-LogMessage -Type INFO -Message "  $_" }
                    if ($HarborAllEventsText -match "FailedScheduling.*(?:Insufficient resources.*vSphere HA|failover level for vSphere|admission control)") {
                        Write-LogMessage -Type ERROR -Message "ROOT CAUSE — vSphere HA admission control: pods are blocked from scheduling because the cluster does not have enough unreserved resources to satisfy the configured HA failover level. This is a resource constraint, not a Harbor configuration error."
                        Write-LogMessage -Type ERROR -Message "SOLUTION (HA admission control): (A) Add ESX hosts to increase cluster capacity. (B) Lower the admission control reservation: vCenter > cluster > Configure > vSphere Availability > Admission Control > reduce Percentage of cluster resources reserved. (C) In lab/dev environments, disable admission control entirely. After resolving capacity, roll back (Y) and redeploy."
                    }
                }
                Write-LogMessage -Type WARNING -Message "To check pod logs once a pod starts: kubectl logs -n $ns -l app=registry --previous"
            }
        } catch {
            Write-LogMessage -Type DEBUG -Message "Could not retrieve OCI Registry pod logs in `"$ns`": $($_.Exception.Message)"
        }
    }
}
function Invoke-HarborServiceErrorDiagnostics {

    <#
        .SYNOPSIS
        Surfaces diagnostic information and throws a VcfDeploymentException when Harbor reaches ERROR state.

        .DESCRIPTION
        Extracts the error detail from the service status object, discovers Harbor namespaces via kubectl,
        gathers Kubernetes events, performs IP exhaustion checks, logs targeted remediation guidance based
        on error type, runs the Supervisor Kubernetes diagnostic report, then throws a VcfDeploymentException.
        Always throws — does not return normally.

        .PARAMETER ClusterName
        The vSphere cluster display name for Kubernetes diagnostic logging.

        .PARAMETER Service
        The Harbor supervisor service identifier (e.g. "harbor-service.vsphere.vmware.com").

        .PARAMETER ServiceNamespace
        The computed Harbor service namespace (e.g. "svc-harbor-domain-c1"), used as a fallback
        when kubectl namespace discovery finds no matching namespaces.

        .PARAMETER SupervisorId
        The supervisor UUID where Harbor was being installed.

        .PARAMETER SvcStatus
        The service status object returned by Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesGet.

        .EXAMPLE
        Invoke-HarborServiceErrorDiagnostics -SvcStatus $svcStatus -ClusterName "cluster-edge1" `
            -SupervisorId "sv-01" -ServiceNamespace "svc-harbor-domain-c1" -Service "harbor.tanzu.vmware.com"

        .NOTES
        Always throws VcfDeploymentException. Does not return normally.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String] $ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String] $Service,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String] $ServiceNamespace,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String] $SupervisorId,
        [Parameter(Mandatory = $true)] [ValidateNotNull()]         [Object] $SvcStatus
    )

    $svcErrorDetail = $null
    foreach ($prop in @("Message", "ErrorMessage", "Reason", "Description", "StatusDetails")) {
        $val = $SvcStatus.$prop
        if (-not [String]::IsNullOrWhiteSpace($val)) { $svcErrorDetail = $val; break }
    }
    if (-not [String]::IsNullOrWhiteSpace($svcErrorDetail)) {
        Write-LogMessage -Type ERROR -Message "Harbor service `"$Service`" entered ERROR state on supervisor `"$SupervisorId`": $svcErrorDetail"
    } else {
        Write-LogMessage -Type ERROR -Message "Harbor service `"$Service`" entered ERROR state on supervisor `"$SupervisorId`"."
    }
    Write-LogMessage -Type INFO -Message ""
    # Discover actual Harbor namespaces via kubectl — the Supervisor Services controller may use a different
    # suffix than the computed name; kubectl is authoritative for what actually exists on the Supervisor.
    $harborDiagDiscovery  = Get-KubectlNamespaceNamesMatchingPattern -DebugLogPrefix "Install-HarborSupervisorService" -NameLike "svc-harbor*"
    $harborNamespaces     = if ($harborDiagDiscovery.KubectlSucceeded) { @($harborDiagDiscovery.Names) } else { @() }
    $diagnosticNamespace  = if ($harborNamespaces.Count -gt 0) { $harborNamespaces[0] } else { $ServiceNamespace }
    $namespacesToCheck    = if ($harborNamespaces.Count -gt 0) { $harborNamespaces } else { @($ServiceNamespace) }
    $events               = Get-HarborEventTexts -NamespacesToCheck $namespacesToCheck
    $ipExhaustionDetected = $events.AllEventsText -match "exhausted all IP addresses in requested IPPools|has 0 free ips which is less than"
    if ($ipExhaustionDetected) {
        $svcApiReport = if ([String]::IsNullOrWhiteSpace($svcErrorDetail)) { "no detail" } else { "`"$svcErrorDetail`"" }
        Write-LogMessage -Type ERROR -Message "ROOT CAUSE — workload network IP pool exhausted: pods could not get IP addresses. The vCenter service API reported $svcApiReport but the underlying cause is visible in Kubernetes events."
        Write-LogMessage -Type ERROR -Message "DIAGNOSIS: The supervisor workload network IP pool has no free addresses. Harbor pods were scheduled but their network interfaces could not be realized."
        Write-LogMessage -Type ERROR -Message "SOLUTION: Increase the pool size in supervisor.json: raise `"siteSpec[N].primaryWorkloadNetwork.primaryWorkloadNetworkIPCount`" to allocate more addresses, then roll back (Y) and redeploy. As a guide, Harbor needs one IP per pod (~9 pods); add at least 16 to the current count to leave headroom."
        $ipExhaustionLines = $events.AllEventsText -split "`n" | Where-Object { $_ -match "exhausted|has 0 free ips|NetworkInterfaceRealizationFailed" }
        if ($ipExhaustionLines.Count -gt 0) {
            Write-LogMessage -Type ERROR -Message "IP exhaustion events:"
            $ipExhaustionLines | Select-Object -Unique | ForEach-Object { Write-LogMessage -Type INFO -Message "  $_" }
        }
    }
    switch -Regex ($svcErrorDetail) {
        "OCI Registry|registry" {
            $ociParams = @{
                DiagnosticNamespace     = $diagnosticNamespace
                HarborAllEventsText     = $events.AllEventsText
                HarborWarningEventsText = $events.WarningEventsText
                IpExhaustionDetected    = $ipExhaustionDetected
                NamespacesToCheck       = $namespacesToCheck
            }
            Write-HarborOciRegistryDiagnostics @ociParams
        }
        "already exists|already registered|duplicate" {
            Write-LogMessage -Type ERROR -Message "DIAGNOSIS: vCenter's async Harbor setup tried to re-register the service globally and found it already present. This is a vCenter-side conflict; the service must be deleted from the supervisor before retrying."
            Write-LogMessage -Type ERROR -Message "SOLUTION: Roll back (choose Y), then re-run. If this error repeats, in vCenter UI go to Menu > Supervisor Management > Services, delete `"$Service`" entirely, then re-run this script."
        }
        default {
            if (-not $ipExhaustionDetected) {
                Write-LogMessage -Type ERROR -Message "DIAGNOSIS: Harbor service configuration failed. Check vCenter Events for supervisor `"$SupervisorId`" for additional error details. Roll back (choose Y), correct the issue, and re-run."
                if (-not [String]::IsNullOrWhiteSpace($events.WarningEventsText)) {
                    Write-LogMessage -Type WARNING -Message "Warning events from Harbor namespaces:"
                    $events.WarningEventsText -split "`n" | ForEach-Object { Write-LogMessage -Type INFO -Message "  $_" }
                }
            }
        }
    }
    try {
        Write-SupervisorKubernetesDiagnosticReport -ClusterName $ClusterName -Context "Harbor supervisor service entered ERROR state" -SupervisorId $SupervisorId
    } catch {
        Write-LogMessage -Type DEBUG -Message "Supervisor Kubernetes diagnostics (Harbor ERROR): $($_.Exception.Message)"
    }
    throw [VcfDeploymentException]::new("Deployment failed. Harbor service entered ERROR state. Check logs.")
}
function Install-HarborSupervisorService {

    <#
        .SYNOPSIS
        Installs Harbor as a Supervisor Service on a specific supervisor with customized data values.

        .DESCRIPTION
        Deploys Harbor onto the specified vSphere Supervisor cluster using
        Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesCreate. The YamlServiceConfig parameter
        receives the full content of the harbor-data-values YAML file (plain text); the function base64-encodes
        it before passing it to the API, which requires the value to be base64 encoded. This allows
        per-site configuration (hostname, storage class, TLS, secrets) to be applied during installation.
        Monitors configuration status with polling until CONFIGURED or timeout, with the same error handling
        and status-check logic used by Install-ArgoCDOperator.

        .PARAMETER CheckInterval
        Seconds between status polls. Default is 5.

        .PARAMETER ClusterId
        The vCenter cluster MoRef (e.g. domain-c462) used to construct the service namespace for log messages.

        .PARAMETER ClusterName
        The vSphere cluster display name for Kubernetes diagnostic logging.

        .PARAMETER Service
        The Harbor supervisor service identifier extracted from the harbor-service YAML
        (e.g. "harbor-service.vsphere.vmware.com").

        .PARAMETER SupervisorId
        The supervisor UUID where Harbor will be installed.

        .PARAMETER TotalWaitTime
        Maximum seconds to wait for Harbor to reach CONFIGURED status. Default is 600.

        .PARAMETER Version
        The Harbor service version string extracted from the harbor-service YAML.

        .PARAMETER YamlServiceConfig
        The raw (plain-text) YAML content of the per-site harbor-data-values file produced by
        New-HarborDataValuesFile. Base64-encoded internally before being passed to the vCenter API,
        which requires the value to be base64 encoded.

        .EXAMPLE
        $yamlContent = Get-Content -Path $harborYamlPath -Raw -Encoding UTF8
        Install-HarborSupervisorService -ClusterId $clusterId -ClusterName $clusterName -SupervisorId $supervisorId -Service $harborServiceName -Version $harborServiceVersion -YamlServiceConfig $yamlContent

        .OUTPUTS
        None. Throws on failure.

        .NOTES
        Harbor does not require a separate namespace or kubectl install step. The data values YAML is
        base64-encoded and applied directly via the vCenter Supervisor Services API (YamlServiceConfig
        parameter). The vCenter API requires YamlServiceConfig to be base64-encoded.
        See: https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vsphere-supervisor-services-and-standalone-components/latest/using-supervisor-services/installing-and-configuring-harbor-and-contour/install-harbor-as-a-supervisor-service.html
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(1, [Int]::MaxValue)] [Int]$CheckInterval = 5,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterId,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Service,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorId,
        [Parameter(Mandatory = $false)] [ValidateRange(1, [Int]::MaxValue)] [Int]$TotalWaitTime = 600,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Version,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$YamlServiceConfig
    )

    Write-LogMessage -Type DEBUG -Message "Entered Install-HarborSupervisorService: cluster=`"$ClusterName`", supervisor=`"$SupervisorId`", service=`"$Service`", version=`"$Version`"."
    # Strip the last DNS label suffix to produce a short slug for the diagnostic namespace hint.
    $serviceSlug      = $Service -replace '\.[^.]+\.[^.]+\.[^.]+$', ''
    $serviceNamespace = "svc-$serviceSlug-$ClusterId"
    # Normalize CRLF → LF (Windows Set-Content re-introduces CRLF); base64-encode for the vCenter API.
    $normalizedYaml = $YamlServiceConfig -replace '\r\n', "`n"
    $yamlBase64     = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($normalizedYaml))

    # Pre-flight idempotency check: query current status before submitting a create request.
    # The vCenter Supervisor Services API does not always reject duplicate installs with "already exists";
    # on some builds it accepts the request and triggers a full re-configuration (~600 s wait).
    # Checking status first makes idempotent re-runs return in seconds rather than minutes.
    $skipCreate = $false
    try {
        $preCheckStatus  = Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesGet -supervisor $SupervisorId -supervisorService $Service -ErrorAction Stop
        $preConfigStatus = $preCheckStatus.ConfigStatus
        if ($preConfigStatus -eq "CONFIGURED") {
            Write-LogMessage -Type INFO -Message "Harbor service `"$Service`" is already CONFIGURED on supervisor `"$SupervisorId`". Skipping install."
            return
        }
        if ($preConfigStatus -eq "CONFIGURING") {
            Write-LogMessage -Type INFO -Message "Harbor service `"$Service`" is already CONFIGURING on supervisor `"$SupervisorId`". Polling for CONFIGURED status without re-submitting the create request."
            $skipCreate = $true
        }
    } catch {
        # 404 / not-found or API error: the service is not yet installed; proceed with fresh install.
        Write-LogMessage -Type DEBUG -Message "Pre-flight status check found no existing Harbor service on supervisor `"$SupervisorId`"; proceeding with install. $($_.Exception.Message)"
    }

    try {
        if (-not $skipCreate) {
            Invoke-HarborServiceCreate -CheckInterval $CheckInterval -NormalizedYaml $normalizedYaml -Service $Service -ServiceNamespace $serviceNamespace -SupervisorId $SupervisorId -Version $Version -YamlBase64 $yamlBase64
        }
        $elapsedSeconds   = 0
        $progressActivity = "Waiting for Harbor service `"$Service`" to reach CONFIGURED status"
        while ($elapsedSeconds -lt $TotalWaitTime) {
            $percentComplete = [Math]::Min(100, [int](($elapsedSeconds / $TotalWaitTime) * 100))
            Write-Progress -Activity $progressActivity -Status "Polling (${elapsedSeconds}s / ${TotalWaitTime}s)..." -PercentComplete $percentComplete
            [Console]::Out.Flush()
            Start-Sleep -Seconds $CheckInterval
            $elapsedSeconds += $CheckInterval
            try {
                $svcStatus    = Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesGet -supervisor $SupervisorId -supervisorService $Service -ErrorAction Stop
                $configStatus = $svcStatus.ConfigStatus
                Write-LogMessage -Type DEBUG -Message "Harbor service status: $configStatus (elapsed ${elapsedSeconds}s)."
                if ($configStatus -eq "CONFIGURED") {
                    Write-Progress -Activity $progressActivity -Status "Configured" -PercentComplete 100 -Completed
                    [Console]::Out.Flush()
                    Write-LogMessage -Type INFO -Message "Harbor service `"$Service`" version `"$Version`" is CONFIGURED on supervisor `"$SupervisorId`"."
                    return
                }
                if ($configStatus -eq "ERROR") {
                    Write-Progress -Activity $progressActivity -Status "Error" -Completed
                    [Console]::Out.Flush()
                    Invoke-HarborServiceErrorDiagnostics -ClusterName $ClusterName -Service $Service -ServiceNamespace $serviceNamespace -SupervisorId $SupervisorId -SvcStatus $svcStatus
                }
            } catch {
                if ($_.Exception.Message -match "Deployment failed") { throw }
                Write-LogMessage -Type DEBUG -Message "Status poll failed; retrying. $($_.Exception.Message)"
            }
        }
        Write-Progress -Activity $progressActivity -Status "Timeout" -Completed
        [Console]::Out.Flush()
        Write-LogMessage -Type WARNING -Message "Harbor service `"$Service`" did not reach CONFIGURED status within ${TotalWaitTime}s. Verify in vCenter."
        try {
            Write-SupervisorKubernetesDiagnosticReport -ClusterName $ClusterName -Context "Harbor supervisor service configuration timed out" -SupervisorId $SupervisorId
        } catch {
            Write-LogMessage -Type DEBUG -Message "Supervisor Kubernetes diagnostics (Harbor timeout): $($_.Exception.Message)"
        }
        $err = "Deployment failed. Harbor service configuration timed out. Check logs."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    } catch [VcfDeploymentException] {
        throw  # already logged and typed — propagate without re-wrapping
    } catch {
        if ($_.Exception.Message -match "Deployment failed") { throw }
        $err = "Install-HarborSupervisorService unexpected error: $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
}
function Get-YamlMultiDocumentList {

    <#
        .SYNOPSIS
        Reads a YAML file and returns an array of parsed document objects.

        .DESCRIPTION
        Reads the raw content of a YAML file, splits on the YAML document separator (---),
        parses each non-empty document via ConvertFrom-Yaml, and returns the documents as
        an array of hashtables. Supports both Unix and Windows line endings.

        .PARAMETER YamlFilePath
        Path to the YAML file to read and parse.

        .EXAMPLE
        $docs = Get-YamlMultiDocumentList -YamlFilePath "/path/to/file.yaml"

        .OUTPUTS
        System.Array — Array of parsed YAML document hashtables.
    #>

    [CmdletBinding()]
    [OutputType([Object[]])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$YamlFilePath
    )

    $yamlContent = Get-Content -Raw -Path $YamlFilePath
    $documents = $yamlContent -split '(?m)^---\s*$'
    $config = [System.Collections.Generic.List[Object]]::new()
    foreach ($docContent in $documents) {
        $docContent = $docContent.Trim()
        if ($docContent) {
            $doc = ConvertFrom-Yaml -YamlContent $docContent
            if ($doc -is [hashtable]) {
                $config.Add($doc)
            } elseif ($doc.Count -gt 0 -and $null -ne $doc[0]) {
                $config.Add($doc[0])
            }
        }
    }
    return $config.ToArray()
}
function Invoke-YamlPropertyChecks {

    <#
        .SYNOPSIS
        Validates specified property paths across all parsed YAML documents.

        .DESCRIPTION
        Iterates each document in Config and each property path in PropertyPaths. Navigates
        dot-notation paths within hashtable documents, applies the validation (custom scriptblock
        or equality) and accumulates results. Returns a summary object with validation outcome.

        .PARAMETER AllowMissingProperties
        When set, missing properties log a WARNING instead of failing validation.

        .PARAMETER Config
        Array of parsed YAML document hashtables (from Get-YamlMultiDocumentList).

        .PARAMETER ExpectedValues
        Values corresponding 1:1 to PropertyPaths (or a single value applied to all paths).

        .PARAMETER PropertyPaths
        Dot-notation property paths to check (e.g., @("metadata.namespace")).

        .PARAMETER ValidationName
        Label used in log messages (e.g., "namespace consistency").

        .PARAMETER ValidationScriptBlock
        Optional scriptblock receiving (foundValue, expectedValue, propertyPath, documentIndex);
        returns $true/$false. Defaults to -eq when omitted.

        .PARAMETER YamlFilePath
        Used only in log/error messages to identify the file being validated.

        .EXAMPLE
        $result = Invoke-YamlPropertyChecks -Config $docs -PropertyPaths @("metadata.namespace") -ExpectedValues @("argocd") -ValidationName "ns" -YamlFilePath $path

        .OUTPUTS
        PSCustomObject with Failed=[Bool], PropertiesFound=[Int], DocumentsChecked=[Int].
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $false)] [Switch]$AllowMissingProperties,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object[]]$Config,
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [String[]]$ExpectedValues,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String[]]$PropertyPaths,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ValidationName,
        [Parameter(Mandatory = $false)] [ScriptBlock]$ValidationScriptBlock = $null,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$YamlFilePath
    )

    $validationFailed = $false
    $documentsChecked = 0
    $propertiesFound = 0

    foreach ($doc in $Config) {
        if ($null -eq $doc) { continue }
        $documentsChecked++

        for ($pathIndex = 0; $pathIndex -lt $PropertyPaths.Count; $pathIndex++) {
            $propertyPath = $PropertyPaths[$pathIndex]
            $expectedValue = if ($ExpectedValues.Count -eq 1) { $ExpectedValues[0] } else { $ExpectedValues[$pathIndex] }

            $foundValue = $null
            $propertyFound = $false
            $currentObject = $doc
            foreach ($part in ($propertyPath -split '\.')) {
                if ($currentObject -is [hashtable] -and $currentObject.ContainsKey($part)) {
                    $currentObject = $currentObject[$part]
                    $propertyFound = $true
                } else {
                    $propertyFound = $false
                    break
                }
            }

            if ($propertyFound) {
                $foundValue = $currentObject
                $propertiesFound++
                Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Found property `"$propertyPath`" in document $documentsChecked with value: `"$foundValue`""

                $isValid = $false
                if ($null -ne $ValidationScriptBlock) {
                    try {
                        $isValid = & $ValidationScriptBlock -foundValue $foundValue -expectedValue $expectedValue -propertyPath $propertyPath -documentIndex $documentsChecked
                    } catch {
                        Write-LogMessage -Type ERROR -Message "Custom validation scriptblock failed for property `"$propertyPath`" in document $documentsChecked : $($_.Exception.Message)"
                        $isValid = $false
                    }
                } else {
                    $isValid = ($foundValue -eq $expectedValue)
                }

                if (-not $isValid) {
                    Write-LogMessage -Type ERROR -Message "$ValidationName validation failed in file `"$YamlFilePath`" for property `"$propertyPath`". Expected: `"$expectedValue`", Found: `"$foundValue`"."
                    $validationFailed = $true
                } else {
                    Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "$ValidationName validation on YAML file `"$YamlFilePath`": for property `"$propertyPath`"."
                }
            } else {
                $message = "Property `"$propertyPath`" not found in document $documentsChecked"
                if ($AllowMissingProperties) {
                    Write-LogMessage -Type WARNING -Message "$message - treating as acceptable due to allowMissingProperties flag."
                } else {
                    Write-LogMessage -Type ERROR -Message "$message - this is considered a validation failure."
                    $validationFailed = $true
                }
            }
        }
    }

    Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "$ValidationName validation completed - Documents checked: $documentsChecked, Properties found: $propertiesFound."
    return [PSCustomObject]@{ Failed = $validationFailed; PropertiesFound = $propertiesFound; DocumentsChecked = $documentsChecked }
}
function Test-YamlPropertyConsistency {

    <#
        .SYNOPSIS
        Validates that properties in a YAML file match expected values using customizable logic.

        .DESCRIPTION
        Parses each document in a multi-document YAML file and checks specified property paths
        against expected values. A custom scriptblock enables non-equality comparisons.
        Returns $true only when all checked properties in all documents pass. Delegates YAML
        document parsing to Get-YamlMultiDocumentList and property checking to Invoke-YamlPropertyChecks.

        .PARAMETER AllowMissingProperties
        When set, missing properties log a warning instead of failing.

        .PARAMETER ExpectedValues
        Values corresponding 1:1 to PropertyPaths.

        .PARAMETER PropertyPaths
        Dot-notation property paths to check (e.g., @("metadata.namespace")).

        .PARAMETER ValidationName
        Label used in log messages (e.g., "namespace consistency").

        .PARAMETER ValidationScriptBlock
        Optional. Receives ($foundValue, $expectedValue, $propertyPath, $documentIndex); returns $true/$false.
        Defaults to -eq when omitted.

        .PARAMETER YamlFilePath
        Path to the YAML file to validate.

        .EXAMPLE
        Test-YamlPropertyConsistency -YamlFilePath $yamlPath -PropertyPaths @("metadata.namespace") -ExpectedValues @("argocd") -ValidationName "namespace"

        .OUTPUTS
        System.Boolean — $true if all validations pass.
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $false)] [Switch]$AllowMissingProperties,
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [String[]]$ExpectedValues,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String[]]$PropertyPaths,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ValidationName,
        [Parameter(Mandatory = $false)] [ScriptBlock]$ValidationScriptBlock = $null,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$YamlFilePath
    )

    Write-LogMessage -Type DEBUG -Message "Entered Test-YamlPropertyConsistency function..."

    try {
        if (-not (Test-Path -Path $YamlFilePath -PathType Leaf)) {
            $currentDir = Get-Location
            $isWindowsAbsolutePath = $YamlFilePath -match '^[A-Za-z]:[\\/]'
            $isUnixAbsolutePath = $YamlFilePath -match '^/'
            $isAbsolutePath = $isWindowsAbsolutePath -or $isUnixAbsolutePath
            Write-LogMessage -Type ERROR -Message "YAML file not found for $ValidationName validation."
            Write-LogMessage -Type ERROR -Message "  Specified path: `"$YamlFilePath`""
            if ($isWindowsAbsolutePath) {
                Write-LogMessage -Type ERROR -Message "  Note: The specified path is a Windows absolute path. On non-Windows systems, please update your configuration file (infrastructure.json) to use a relative path or a Unix-style absolute path."
            } elseif (-not $isAbsolutePath) {
                $resolvedPath = Join-Path -Path $currentDir -ChildPath $YamlFilePath
                Write-LogMessage -Type ERROR -Message "  Resolved path: `"$resolvedPath`""
            }
            Write-LogMessage -Type ERROR -Message "  Current working directory: `"$currentDir`""
            Write-LogMessage -Type ERROR -Message "  Please verify the file path in your configuration file (infrastructure.json) and ensure the file exists."
            return $false
        }

        if ($ExpectedValues.Count -ne 1 -and $ExpectedValues.Count -ne $PropertyPaths.Count) {
            Write-LogMessage -Type ERROR -Message "Expected values count must be 1 (for all properties) or match property paths count. PropertyPaths: $($PropertyPaths.Count), ExpectedValues: $($ExpectedValues.Count)"
            return $false
        }

        Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Starting $ValidationName validation for YAML file: `"$YamlFilePath`""
        Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Property paths to validate: $($PropertyPaths -join ', ')"
        Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Expected values: $($ExpectedValues -join ', ')"

        $config = Get-YamlMultiDocumentList -YamlFilePath $YamlFilePath

        $checksParams = @{
            AllowMissingProperties = $AllowMissingProperties
            Config                 = $config
            ExpectedValues         = $ExpectedValues
            PropertyPaths          = $PropertyPaths
            ValidationName         = $ValidationName
            ValidationScriptBlock  = $ValidationScriptBlock
            YamlFilePath           = $YamlFilePath
        }
        $checkResult = Invoke-YamlPropertyChecks @checksParams

        if ($checkResult.PropertiesFound -eq 0 -and -not $AllowMissingProperties) {
            Write-LogMessage -Type ERROR -Message "No properties matching the specified paths were found in the YAML file."
            return $false
        }
        if ($checkResult.Failed) {
            Write-LogMessage -Type ERROR -Message "$ValidationName validation failed - One or more property values did not meet the validation criteria."
            return $false
        }
        Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "$ValidationName validation successful - All property values passed validation."
        return $true

    } catch {
        Write-LogMessage -Type ERROR -Message "Failed to perform $ValidationName validation on YAML file `"$YamlFilePath`": $($_.Exception.Message)"
        return $false
    }
}
function Get-ArgoCDServiceDetail {

    <#
        .SYNOPSIS
        Extracts ArgoCD service name and version from a multi-document YAML package file.

        .DESCRIPTION
        The Get-ArgoCDServiceDetail function parses a multi-document YAML file (typically a Carvel package file)
        to extract the ArgoCD service reference name and version. The function handles YAML files that contain
        multiple documents separated by '---' and specifically looks for the Package document that contains
        the spec.refName and spec.version properties.

        The function uses a native PowerShell YAML parser to process the file and automatically handles:
        - Multi-document YAML files (documents separated by ---)
        - Package and PackageMetadata document types
        - Extraction of refName and version from the correct Package document
        - Error handling for malformed or missing YAML content

        This function is typically used during ArgoCD service deployment to identify the correct service
        name and version for supervisor service installation.

        .PARAMETER Path
        The full path to the YAML package file to parse. This file should contain Carvel package
        definitions with at least one Package document that includes spec.refName and spec.version properties.

        .EXAMPLE
        Get-ArgoCDServiceDetail -Path "/path/to/argocd-service.yml"

        Parses the specified YAML file and returns the ArgoCD service reference name and version.
        Returns: "argocd-service.vsphere.vmware.com", "1.0.0-24815986"

        .EXAMPLE
        $ServiceName, $serviceVersion = Get-ArgoCDServiceDetail -Path $argoCDyaml

        Extracts service details and assigns them to separate variables for use in service deployment.

        .OUTPUTS
        System.String[]
        Returns an array containing two strings:
        [0] - The service reference name (spec.refName)
        [1] - The service version (spec.version)

        .NOTES
        - Requires the YAML file to contain at least one Package document with spec.refName and spec.version
        - Uses native PowerShell YAML parsing (no external dependencies)
        - Handles both single and multi-document YAML files
        - Throws a terminating error if the required Package document is not found
        - The function specifically looks for Package documents, not PackageMetadata documents
    #>

    [CmdletBinding()]
    [OutputType([Object[]])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Path
    )

    Write-LogMessage -Type DEBUG -Message "Entered Get-ArgoCDServiceDetail function..."

    try {
        $yamlContent = Get-Content -Raw -Path $Path -ErrorAction Stop

        # Split multi-document YAML by --- separator.

        # Use regex to handle different line endings (Unix: \n, Windows: \r\n)
        $documents = $yamlContent -split '(?m)^---\s*$'

        Write-LogMessage -Type DEBUG -Message "Split YAML into $($documents.Count) document(s)"

        $config = [System.Collections.Generic.List[Object]]::new()
        foreach ($docContent in $documents) {
            $docContent = $docContent.Trim()
            if ($docContent) {
                $doc = ConvertFrom-Yaml -YamlContent $docContent

                if ($doc -is [hashtable]) {
                    # YAML parser returned a hashtable directly.
                    $config.Add($doc)
                    Write-LogMessage -Type DEBUG -Message "Parsed document as hashtable with keys: $($doc.Keys -join ', ')"
                } elseif ($doc.Count -gt 0 -and $null -ne $doc[0]) {
                    # YAML parser returned an array with hashtable.
                    $config.Add($doc[0])
                    Write-LogMessage -Type DEBUG -Message "Parsed document as array, extracted first element with keys: $($doc[0].Keys -join ', ')"
                }
            }
        }

        Write-LogMessage -Type DEBUG -Message "Total parsed YAML documents: $($config.Count)"
    } catch [VcfDeploymentException] {
        throw  # already logged and typed — propagate without re-wrapping
    } catch {
        $err = "Failed to convert YAML file to JSON: $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
    # Access properties from the parsed YAML documents.
    # Look for the first document that has a 'spec' with 'refName' and 'version' (Package document)
    $configHash = $null

    foreach ($doc in $config) {
        if ($null -ne $doc -and $doc.ContainsKey("spec")) {
            $spec = $doc["spec"]
            Write-LogMessage -Type DEBUG -Message "Examining document with spec keys: $($spec.Keys -join ', ')"
            # Check if this is a Package document (has refName and version)
            if ($spec.ContainsKey("refName") -and $spec.ContainsKey("version")) {
                $configHash = $doc
                Write-LogMessage -Type DEBUG -Message "Found Package document with refName: $($spec['refName']), version: $($spec['version'])"
                break
            }
        }
    }

    if ($null -ne $configHash -and $configHash.ContainsKey("spec")) {
        $spec = $configHash["spec"]
        $refName = if ($spec.ContainsKey("refName")) { $spec["refName"] } else { $null }
        $version = if ($spec.ContainsKey("version")) { $spec["version"] } else { $null }

        return $refName, $version
    } else {
        Write-LogMessage -Type ERROR -Message "Failed to find Package document with `"spec.refName`" and `"spec.version`" in YAML file. Available documents: $($config.Count)"
        if ($config.Count -gt 0) {
            foreach ($doc in $config) {
                $kind = if ($doc.ContainsKey("kind")) { $doc["kind"] } else { "Unknown" }
                $hasSpec = if ($doc.ContainsKey("spec")) { "Yes" } else { "No" }
                Write-LogMessage -Type ERROR -Message "  Document kind: $kind, has spec: $hasSpec"
                if ($doc.ContainsKey("spec")) {
                    $spec = $doc["spec"]
                    Write-LogMessage -Type ERROR -Message "    spec keys: $($spec.Keys -join ', ')"
                }
            }
        }
        throw [VcfDeploymentException]::new("ArgoCD service context key validation failed. Check logs for details.")
    }
}
function Get-ContentLibraryId {

    <#
        .SYNOPSIS
        Retrieves the unique identifier of a vSphere content library by name.

        .DESCRIPTION
        The Get-ContentLibraryId function searches for a content library on the specified vCenter
        by name and returns its unique identifier. This function queries all local content libraries
        available on the vCenter and performs a case-sensitive name match to locate the
        requested library.

        The function is commonly used in deployment scenarios where content library IDs are required
        for operations such as VM template deployment, supervisor cluster configuration, or other
        vSphere operations that reference content libraries by their unique identifiers.

        If the specified content library is not found, the function throws a terminating error
        to prevent subsequent operations from proceeding with invalid library references.

        .PARAMETER LibraryName
        The name of the content library for which to retrieve the unique identifier.
        This parameter is mandatory and performs a case-sensitive match against existing
        content library names on the vCenter.

        .EXAMPLE
        Get-ContentLibraryId -LibraryName "VCF-ContentLibrary"

        Retrieves the unique identifier for the content library named "VCF-ContentLibrary".

        .EXAMPLE
        $libraryId = Get-ContentLibraryId -LibraryName "Production-Templates"

        Stores the content library ID in a variable for use in subsequent operations.

        .EXAMPLE
        Get-ContentLibraryId -LibraryName $InputData.common.contentLibrary.libraryName

        Retrieves the content library ID using a name from configuration data.

        .OUTPUTS
        System.String
        Returns the unique identifier (ID) of the specified content library as a string.

        .NOTES
        - Requires an active PowerCLI connection to vCenter via the $Script:vCenterName variable
        - Uses Get-ContentLibrary cmdlet to search both local and subscribed content libraries
        - Performs case-sensitive name matching against content library names
        - Returns $null if the library is not found (caller should handle this case)
        - Searches both local and subscribed content libraries
        - The returned ID can be used with other vSphere APIs and PowerCLI cmdlets that require content library references

        .LINK
        Get-ContentLibrary
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$LibraryName
    )
    Write-LogMessage -Type DEBUG -Message "Entered Get-ContentLibraryId function..."

    Assert-VcenterConnected

    try {
        # Search both local and subscribed content libraries.
        $contentLibraries = Get-ContentLibrary -Server $Script:vCenterName -ErrorAction Stop
        foreach ($library in $contentLibraries) {
            if ($library.Name -eq $LibraryName) {
                return $library.Id
            }
        }

        # Library not found in either local or subscribed libraries.
        Write-LogMessage -Type DEBUG -Message "Content library `"$LibraryName`" not found on vCenter `"$Script:vCenterName`". Proceeding with library creation..."
        return $null
    } catch [VcfDeploymentException] {
        throw  # already logged and typed — propagate without re-wrapping
    } catch {
        $err = "Failed to retrieve content library `"$LibraryName`" from `"$Script:vCenterName`": $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
}
function New-VCenterRestApiSession {

    <#
        .SYNOPSIS
        Creates an authenticated vCenter REST API session.

        .DESCRIPTION
        Encodes credentials as Base64 and POSTs to /rest/com/vmware/cis/session.
        Returns a structured result — check .Success before using .SessionHeaders.
        A null/empty effective password returns Success=$false without calling vCenter.
        Password priority: VcenterPassword (SecureString) > VcenterInsecurePassword (String).

        .PARAMETER VcenterUser
        Username for Basic authentication.

        .PARAMETER VcenterInsecurePassword
        Password as a plain string.

        .PARAMETER VcenterPassword
        SecureString — takes precedence over VcenterInsecurePassword.

        .PARAMETER InsecureTls
        Bypasses SSL certificate validation. Also auto-enabled when PowerCLI is configured
        with InvalidCertificateAction = Ignore.

        .EXAMPLE
        $session = New-VCenterRestApiSession -VcenterUser $vcenterUser -VcenterInsecurePassword $vcenterPassword -InsecureTls
        if ($session.Success) { Invoke-RestMethod -Uri $url -Headers $session.SessionHeaders }

        .OUTPUTS
        PSCustomObject: Success (Bool), SessionHeaders (Hashtable), SessionId (String), ErrorMessage (String).
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingUsernameAndPasswordParams', '')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('UsePSCredentialType', '')]
    Param (
        [Parameter(Mandatory = $false)] [Switch]$InsecureTls,
        [Parameter(Mandatory = $false)] [PSCredential]$VcenterCredential,
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$VcenterInsecurePassword,
        [Parameter(Mandatory = $false)] [SecureString]$VcenterPassword,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VcenterUser
    )

    Write-LogMessage -Type DEBUG -Message "Entered New-VCenterRestApiSession function..."

    try {
        # PowerCLI InvalidCertificateAction = 4 means "ignore"; auto-detect when -InsecureTls is not explicit.
        $insecureTlsValue = $false
        if ($PSBoundParameters.ContainsKey('InsecureTls')) {
            $insecureTlsValue = $InsecureTls
            Write-LogMessage -Type DEBUG -Message "InsecureTls explicitly provided: $insecureTlsValue"
        } else {
            Write-LogMessage -Type DEBUG -Message "InsecureTls not explicitly provided. Checking PowerCLI configuration for InvalidCertificateAction = 4..."
            $insecureTlsValue = Get-InsecureTlsFromPowerCliConfig
        }

        $plainForAuth = Get-VcenterRestApiPlainPassword -VcenterPassword $VcenterPassword -VcenterCredential $VcenterCredential -VcenterInsecurePassword $VcenterInsecurePassword
        if ([String]::IsNullOrWhiteSpace($plainForAuth)) {
            Write-LogMessage -Type ERROR -Message "No vCenter password supplied to New-VCenterRestApiSession. Provide -VcenterCredential (PSCredential), -VcenterPassword (SecureString), or -VcenterInsecurePassword (String)."
            return [PSCustomObject]@{
                Success = $false
                SessionHeaders = $null
                SessionId = $null
                ErrorMessage = "No vCenter password supplied. Provide VcenterCredential, VcenterPassword, or VcenterInsecurePassword."
            }
        }

        Write-LogMessage -Type DEBUG -Message "  Creating REST API session with vCenter..."

        # Log target and user for troubleshooting (no password).
        Write-LogMessage -Type DEBUG -Message "Attempting REST API session with vCenter `"$Script:vCenterName`" and user `"$VcenterUser`"."

        # Encode credentials for Basic authentication.
        $pair = "$VcenterUser`:$plainForAuth"
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($pair)
        $encodedAuth = [Convert]::ToBase64String($bytes)
        $headers = @{ Authorization = "Basic $encodedAuth" }

        Write-LogMessage -Type DEBUG -Message "Creating REST API session with InsecureTls = $insecureTlsValue"
        $restUri = "https://$($Script:vCenterName)/rest/com/vmware/cis/session"
        $session = Invoke-RestMethod -Method POST `
            -Uri $restUri `
            -Headers $headers `
            -SkipCertificateCheck:$insecureTlsValue `
            -ErrorAction Stop

        $sessionId = $session.value
        $authHeaders = @{ "vmware-api-session-id" = $sessionId }

        Write-LogMessage -Type DEBUG -Message "  REST API session created successfully."

        return [PSCustomObject]@{
            Success = $true
            SessionHeaders = $authHeaders
            SessionId = $sessionId
            ErrorMessage = $null
        }
    } catch {
        $errorMessage = $_.Exception.Message
        Write-VCenterSessionErrorDetails -ErrorMessage $errorMessage -InnerException $_.Exception.InnerException -VcenterUser $VcenterUser
        return [PSCustomObject]@{ Success = $false; SessionHeaders = $null; SessionId = $null; ErrorMessage = $errorMessage }
    }
}
function Get-InsecureTlsFromPowerCliConfig {

    <#
    .SYNOPSIS
        Infers whether insecure TLS should be used from the PowerCLI InvalidCertificateAction setting.
    .DESCRIPTION
        Reads Get-PowerCLIConfiguration and returns $true when the highest-precedence scope has
        InvalidCertificateAction = 4 (Ignore). Returns $false on any error or when the setting is
        absent. Used by New-VCenterRestApiSession to auto-detect the TLS preference when -InsecureTls
        is not passed explicitly.
    .EXAMPLE
        $insecureTls = Get-InsecureTlsFromPowerCliConfig
    .OUTPUTS
        [Bool]
    .NOTES
        Scope precedence order: Session (1) > User (2) > AllUsers (4).
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param ()

    try {
        $powerCliConfig = Get-PowerCLIConfiguration -ErrorAction Stop
        if (-not $powerCliConfig) { return $false }
        $sessionConfig   = $powerCliConfig | Where-Object { $_.Scope -eq 1 -and $null -ne $_.InvalidCertificateAction } | Select-Object -First 1
        $userConfig      = $powerCliConfig | Where-Object { $_.Scope -eq 2 -and $null -ne $_.InvalidCertificateAction } | Select-Object -First 1
        $allUsersConfig  = $powerCliConfig | Where-Object { $_.Scope -eq 4 -and $null -ne $_.InvalidCertificateAction } | Select-Object -First 1
        Write-LogMessage -Type DEBUG -Message "Session scope (1) config: InvalidCertificateAction = $($sessionConfig.InvalidCertificateAction)" -SuppressOutputToScreen
        Write-LogMessage -Type DEBUG -Message "User scope (2) config: InvalidCertificateAction = $($userConfig.InvalidCertificateAction)" -SuppressOutputToScreen
        Write-LogMessage -Type DEBUG -Message "AllUsers scope (4) config: InvalidCertificateAction = $($allUsersConfig.InvalidCertificateAction)" -SuppressOutputToScreen
        $configToCheck = if ($sessionConfig) { $sessionConfig } elseif ($userConfig) { $userConfig } else { $allUsersConfig }
        if (-not $configToCheck) {
            Write-LogMessage -Type DEBUG -Message "No PowerCLI configuration found with InvalidCertificateAction set. Using secure TLS."
            return $false
        }
        if ($configToCheck.InvalidCertificateAction -eq 4) {
            Write-LogMessage -Type DEBUG -Message "PowerCLI configuration has InvalidCertificateAction = 4 (Ignore). Automatically enabling insecure TLS."
            return $true
        }
        Write-LogMessage -Type DEBUG -Message "PowerCLI configuration has InvalidCertificateAction = $($configToCheck.InvalidCertificateAction) (not 4). Using secure TLS."
        return $false
    } catch {
        Write-LogMessage -Type DEBUG -Message "Could not retrieve PowerCLI configuration: $($_.Exception.Message). Assuming secure TLS."
        return $false
    }
}
function Write-VCenterSessionErrorDetails {

    <#
    .SYNOPSIS
        Logs contextual guidance for a vCenter REST API session creation failure.
    .DESCRIPTION
        Classifies the error message (401, SSL/TLS, or generic) and emits appropriate
        Write-LogMessage entries. Called from the catch block of New-VCenterRestApiSession.
    .PARAMETER ErrorMessage
        The exception message from the failed Invoke-RestMethod call.
    .PARAMETER InnerException
        Inner exception object, if present. Used for additional DEBUG context.
    .PARAMETER VcenterUser
        vCenter username, included in user-facing guidance messages.
    .EXAMPLE
        Write-VCenterSessionErrorDetails -ErrorMessage $errorMessage -InnerException $_.Exception.InnerException -VcenterUser $VcenterUser
    .NOTES
        Called by New-VCenterRestApiSession.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ErrorMessage,
        [Parameter(Mandatory = $false)] [AllowNull()] [Object]$InnerException,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VcenterUser
    )

    switch -Regex ($ErrorMessage) {
        "401|Unauthorized" {
            Write-LogMessage -Type ERROR -Message "Failed to create REST API session: authentication failed (401 Unauthorized). vCenter rejected the credentials for user `"$VcenterUser`"."
            if ($InnerException) { Write-LogMessage -Type DEBUG -Message "Inner exception: $($InnerException.Message)" }
            Write-LogMessage -Type WARNING -Message "Verify the vCenter username and password in your input (common.vCenterUser and the password you entered). Ensure the account has privileges to use the vCenter REST API and namespace management."
            Write-LogMessage -Type WARNING -Message "Common causes: wrong password (use the vCenter SSO password for this user, not the ESX host password); account locked or expired; or user lacks Administrator / REST API / namespace management role."
            break
        }
        "SSL|certificate|TLS|The SSL connection could not be established" {
            Write-LogMessage -Type ERROR -Message "Failed to create REST API session due to SSL certificate validation error: $ErrorMessage."
            if ($InnerException) { Write-LogMessage -Type DEBUG -Message "Inner exception details: $($InnerException.Message)" }
            Write-LogMessage -Type INFO -Message ""
            Write-LogMessage -Type WARNING -Message "SSL certificate validation failed when connecting to vCenter REST API."
            Write-LogMessage -Type WARNING -Message "This typically occurs when:"
            Write-LogMessage -Type WARNING -Message "  1. vCenter uses a self-signed certificate (common in lab environments)"
            Write-LogMessage -Type WARNING -Message "  2. Certificate chain is incomplete or expired"
            Write-LogMessage -Type WARNING -Message "  3. Certificate name doesn't match the vCenter hostname"
            Write-LogMessage -Type INFO -Message ""
            Write-LogMessage -Type WARNING -Message "SOLUTION: For lab environments with self-signed certificates, you can:"
            Write-LogMessage -Type WARNING -Message "  1. Import the vCenter certificate to the trusted certificate store"
            Write-LogMessage -Type WARNING -Message "  2. Use a properly signed certificate for vCenter"
            Write-LogMessage -Type WARNING -Message "  3. Note: The content library association will be skipped, but deployment will continue"
            Write-LogMessage -Type INFO -Message ""
            break
        }
        default {
            Write-LogMessage -Type ERROR -Message "Failed to create REST API session: $ErrorMessage."
            if ($InnerException) { Write-LogMessage -Type DEBUG -Message "Inner exception: $($InnerException.Message)" }
        }
    }
}
function Find-SupervisorByName {

    <#
        .SYNOPSIS
        Searches for a Supervisor cluster by name via the vCenter REST API.

        .DESCRIPTION
        Queries GET /api/vcenter/namespace-management/supervisors/summaries and returns the
        matching supervisor ID. A missing supervisor returns Success=$true, Found=$false.
        API failures return Success=$false.

        .PARAMETER SupervisorName
        Name to search for. Match is case-insensitive.

        .PARAMETER SessionHeaders
        Session headers from New-VCenterRestApiSession.

        .PARAMETER InsecureTls
        Bypasses SSL certificate validation.

        .EXAMPLE
        $findResult = Find-SupervisorByName -SupervisorName "prod-sv" -SessionHeaders $session.SessionHeaders
        if ($findResult.Success -and $findResult.Found) { $supervisorId = $findResult.SupervisorId }

        .OUTPUTS
        PSCustomObject: Success (Bool), Found (Bool), SupervisorId (String|null), ErrorMessage (String).
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $false)] [Switch]$InsecureTls,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Hashtable]$SessionHeaders,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorName
    )

    Write-LogMessage -Type DEBUG -Message "Entered Find-SupervisorByName function..."

    try {
        Write-LogMessage -Type DEBUG -Message "  Searching for supervisor `"$SupervisorName`"..."

        # Query supervisor summaries from vCenter API.
        $response = Invoke-RestMethod -Method GET `
            -Uri "https://$Script:vCenterName/api/vcenter/namespace-management/supervisors/summaries" `
            -Headers $SessionHeaders `
            -SkipCertificateCheck:$InsecureTls `
            -ErrorAction Stop

        # Find the supervisor by name (case-insensitive: PowerShell -eq is case-insensitive for strings).
        $supervisorInstance = $response.items | Where-Object { $_.info.name -eq $SupervisorName }

        if ($supervisorInstance) {
            $supervisorId = $supervisorInstance.supervisor.ToString()
            Write-LogMessage -Type INFO -Message "  Found supervisor `"$SupervisorName`" with ID: $supervisorId."

            return [PSCustomObject]@{
                Success = $true
                SupervisorId = $supervisorId
                Found = $true
                ErrorMessage = $null
            }
        }
        else {
            Write-LogMessage -Type DEBUG -Message "  Supervisor `"$SupervisorName`" not found."

            # Return success but not found (not an error - may not be created yet).
            return [PSCustomObject]@{
                Success = $true
                SupervisorId = $null
                Found = $false
                ErrorMessage = $null
            }
        }
    } catch {
        $errorMessage = $_.Exception.Message
        Write-LogMessage -Type ERROR -Message "Failed to query supervisor summaries: $errorMessage."

        return [PSCustomObject]@{
            Success = $false
            SupervisorId = $null
            Found = $false
            ErrorMessage = $errorMessage
        }
    }
}
function Write-SupervisorConditionDiagnostics {

    <#
    .SYNOPSIS
        Queries the vCenter supervisor conditions endpoint and logs the details.
    .DESCRIPTION
        Calls GET /api/vcenter/namespace-management/supervisors/{id}/conditions and logs each
        condition's type and message at the specified log level. On error, logs a DEBUG message
        and returns silently so the caller can continue.
    .PARAMETER InsecureTls
        Bypasses SSL certificate validation on the REST call.
    .PARAMETER LogLevel
        Log level for condition details (e.g. "INFO" or "ERROR"). Passed to Write-LogMessage.
    .PARAMETER SessionHeaders
        Authentication headers from New-VCenterRestApiSession.
    .PARAMETER StatusText
        Current kubernetes_status string for inclusion in the log message.
    .PARAMETER SupervisorId
        Supervisor resource ID used in the API URL.
    .PARAMETER SupervisorName
        Supervisor name for log context.
    .EXAMPLE
        Write-SupervisorConditionDiagnostics -InsecureTls:$InsecureTls.IsPresent -LogLevel "ERROR" -SessionHeaders $SessionHeaders -StatusText $lastStatus -SupervisorId $supervisorId -SupervisorName $SupervisorName
    .NOTES
        Called by Invoke-SupervisorPollUntilReady and Wait-SupervisorDiscoverable.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [Switch]$InsecureTls,
        [Parameter(Mandatory = $true)] [ValidateSet("DEBUG", "INFO", "WARNING", "ERROR")] [String]$LogLevel,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Hashtable]$SessionHeaders,
        [Parameter(Mandatory = $false)] [String]$StatusText,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorId,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorName
    )

    try {
        $conditionsResponse = Invoke-RestMethod -Method GET `
            -Uri "https://$Script:vCenterName/api/vcenter/namespace-management/supervisors/$SupervisorId/conditions" `
            -Headers $SessionHeaders `
            -SkipCertificateCheck:$InsecureTls `
            -ErrorAction Stop
        if ($conditionsResponse -and $conditionsResponse.items) {
            $errorDetails = [System.Collections.Generic.List[String]]::new()
            foreach ($condition in $conditionsResponse.items) {
                if ($condition.type -and $condition.message) { $errorDetails.Add("$($condition.type): $($condition.message)") }
                elseif ($condition.message) { $errorDetails.Add($condition.message) }
            }
            if ($errorDetails.Count -gt 0) {
                $statusSuffix = if (-not [String]::IsNullOrWhiteSpace($StatusText)) { " ($StatusText)" } else { "" }
                Write-LogMessage -Type $LogLevel -Message "  Supervisor `"$SupervisorName`"$statusSuffix error details: $($errorDetails -join '; ')"
            }
        }
    } catch {
        Write-LogMessage -Type DEBUG -Message "  Unable to retrieve detailed error conditions for supervisor `"$SupervisorName`": $($_.Exception.Message)"
    }
}
function Invoke-SupervisorPollUntilReady {

    <#
    .SYNOPSIS
        Polls the vCenter supervisor summaries API until the named supervisor reaches READY status.
    .DESCRIPTION
        Runs the do-while polling loop for Wait-SupervisorDiscoverable. Returns a PSCustomObject
        result on early exit (supervisor found and READY, supervisor disappeared, or API error), or
        $null when the loop expires due to timeout so the caller can emit timeout diagnostics.
    .PARAMETER CheckInterval
        Seconds between polls.
    .PARAMETER InsecureTls
        Bypasses SSL certificate validation.
    .PARAMETER SessionHeaders
        Authentication headers from New-VCenterRestApiSession.
    .PARAMETER SupervisorName
        Name to wait for.
    .PARAMETER TimeoutSeconds
        Maximum total wait time in seconds.
    .EXAMPLE
        $pollResult = Invoke-SupervisorPollUntilReady -CheckInterval 5 -SessionHeaders $hdrs -SupervisorName $name -TimeoutSeconds 3600
        if ($pollResult) { return $pollResult }
    .OUTPUTS
        PSCustomObject on early exit; $null on loop timeout.
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(1, [Int]::MaxValue)] [Int]$CheckInterval = 5,
        [Parameter(Mandatory = $false)] [Switch]$InsecureTls,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Hashtable]$SessionHeaders,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorName,
        [Parameter(Mandatory = $false)] [ValidateRange(1, [Int]::MaxValue)] [Int]$TimeoutSeconds = 3600
    )

    $elapsedTime = 0
    $lastStatus = "UNKNOWN"
    $supervisorId = $null

    do {
        try {
            $response = Invoke-RestMethod -Method GET `
                -Uri "https://$Script:vCenterName/api/vcenter/namespace-management/supervisors/summaries" `
                -Headers $SessionHeaders `
                -SkipCertificateCheck:$InsecureTls `
                -ErrorAction Stop
            $supervisorInstance = $response.items | Where-Object { $_.info.name -eq $SupervisorName }
            if (-not $supervisorInstance) {
                Write-Progress -Activity "Waiting for Supervisor `"$SupervisorName`"" -Status "Error: Supervisor disappeared" -Completed
                return [PSCustomObject]@{ Success = $false; SupervisorId = $null; ElapsedSeconds = $elapsedTime; LastStatus = $lastStatus; ErrorMessage = "Supervisor disappeared during wait" }
            }
            $lastStatus = $supervisorInstance.info.kubernetes_status
            $supervisorId = $supervisorInstance.supervisor.ToString()
            if ($lastStatus -eq "READY") {
                Write-Progress -Activity "Waiting for Supervisor `"$SupervisorName`"" -Status "Ready" -Completed
                Write-LogMessage -Type DEBUG -Message "  Supervisor `"$SupervisorName`" reached READY status after $elapsedTime seconds"
                return [PSCustomObject]@{ Success = $true; SupervisorId = $supervisorId; ElapsedSeconds = $elapsedTime; LastStatus = $lastStatus; ErrorMessage = $null }
            }
            if ($lastStatus -eq "ERROR" -or ($lastStatus -ne "READY" -and $lastStatus -ne "CREATING" -and $lastStatus -ne "CONFIGURING")) {
                $logLevel = if ($lastStatus -eq "ERROR") { "INFO" } else { "DEBUG" }
                Write-SupervisorConditionDiagnostics -InsecureTls:$InsecureTls.IsPresent -LogLevel $logLevel -SessionHeaders $SessionHeaders -StatusText $lastStatus -SupervisorId $supervisorId -SupervisorName $SupervisorName
                if ($supervisorInstance.info.PSObject.Properties['config_status']) {
                    $configStatus = $supervisorInstance.info.config_status
                    if ($configStatus -and $configStatus -ne "RUNNING") { Write-LogMessage -Type DEBUG -Message "  Supervisor `"$SupervisorName`" config_status: $configStatus" }
                }
            }
            Write-Progress -Activity "Waiting for Supervisor `"$SupervisorName`"" -Status "Status: $lastStatus" -CurrentOperation "Elapsed: $elapsedTime seconds"
            Start-Sleep $CheckInterval
            $elapsedTime += $CheckInterval
        } catch {
            $errorMessage = $_.Exception.Message
            Write-LogMessage -Type ERROR -Message "  Error during supervisor status check: $errorMessage."
            Write-Progress -Activity "Waiting for Supervisor `"$SupervisorName`"" -Status "Error" -Completed
            return [PSCustomObject]@{ Success = $false; SupervisorId = $null; ElapsedSeconds = $elapsedTime; LastStatus = $lastStatus; ErrorMessage = $errorMessage }
        }
    } while ($elapsedTime -lt $TimeoutSeconds)

    return $null
}
function Wait-SupervisorDiscoverable {

    <#
        .SYNOPSIS
        Polls until a Supervisor cluster is discoverable and reaches READY kubernetes_status.

        .DESCRIPTION
        Calls Find-SupervisorByName at CheckInterval until the supervisor is found and READY,
        or TimeoutSeconds elapses. Returns Success=$false on timeout — does not throw.
        Fails if the supervisor disappears during the wait.

        .PARAMETER SupervisorName
        Name of the supervisor cluster to wait for.

        .PARAMETER SessionHeaders
        Session headers from New-VCenterRestApiSession.

        .PARAMETER TimeoutSeconds
        Maximum wait time in seconds. Default: 3600.

        .PARAMETER CheckInterval
        Seconds between polls. Default: 5.

        .PARAMETER InsecureTls
        Bypasses SSL certificate validation.

        .EXAMPLE
        $waitResult = Wait-SupervisorDiscoverable -SupervisorName $name -SessionHeaders $hdrs -TimeoutSeconds 1800
        if (-not $waitResult.Success) { throw [VcfDeploymentException]::new($waitResult.ErrorMessage) }

        .OUTPUTS
        PSCustomObject: Success (Bool), SupervisorId (String|null), ElapsedSeconds (Int), LastStatus (String), ErrorMessage (String).
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(1, [Int]::MaxValue)] [Int]$CheckInterval = 5,
        [Parameter(Mandatory = $false)] [Switch]$InsecureTls,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Hashtable]$SessionHeaders,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorName,
        [Parameter(Mandatory = $false)] [ValidateRange(1, [Int]::MaxValue)] [Int]$TimeoutSeconds = 3600
    )

    Write-LogMessage -Type DEBUG -Message "Entered Wait-SupervisorDiscoverable function..."
    Write-LogMessage -Type DEBUG -Message "  Waiting for supervisor `"$SupervisorName`" to become ready (timeout: $TimeoutSeconds seconds)..."

    $pollResult = Invoke-SupervisorPollUntilReady `
        -CheckInterval $CheckInterval `
        -InsecureTls:$InsecureTls.IsPresent `
        -SessionHeaders $SessionHeaders `
        -SupervisorName $SupervisorName `
        -TimeoutSeconds $TimeoutSeconds
    if ($pollResult) { return $pollResult }

    # Timeout — query conditions for diagnostics then return failure.
    $supervisorId = $null
    $elapsedTime = $TimeoutSeconds
    $lastStatus = "UNKNOWN"
    if ($null -eq $pollResult) {
        # Re-query to get the last known supervisor ID and status for the timeout result.
        try {
            $lastResponse = Invoke-RestMethod -Method GET `
                -Uri "https://$Script:vCenterName/api/vcenter/namespace-management/supervisors/summaries" `
                -Headers $SessionHeaders -SkipCertificateCheck:$InsecureTls -ErrorAction Stop
            $lastInstance = $lastResponse.items | Where-Object { $_.info.name -eq $SupervisorName }
            if ($lastInstance) { $supervisorId = $lastInstance.supervisor.ToString(); $lastStatus = $lastInstance.info.kubernetes_status }
        } catch { Write-LogMessage -Type DEBUG -Message "  Could not re-query supervisor status for timeout result: $($_.Exception.Message)" }
    }
    if ($supervisorId -and $lastStatus -ne "READY") {
        Write-SupervisorConditionDiagnostics -InsecureTls:$InsecureTls.IsPresent -LogLevel "ERROR" -SessionHeaders $SessionHeaders -StatusText $lastStatus -SupervisorId $supervisorId -SupervisorName $SupervisorName
    }
    Write-Progress -Activity "Waiting for Supervisor `"$SupervisorName`"" -Status "Timeout" -Completed
    Write-LogMessage -Type ERROR -Message "  Supervisor `"$SupervisorName`" did not become ready after $TimeoutSeconds seconds (last status: $lastStatus)"
    return [PSCustomObject]@{
        Success = $false
        SupervisorId = $supervisorId
        ElapsedSeconds = $elapsedTime
        LastStatus = $lastStatus
        ErrorMessage = "Timeout waiting for supervisor to become ready (last status: $lastStatus)"
    }
}
function Initialize-SupervisorIdSession {

    <#
        .SYNOPSIS
        Validates Get-SupervisorId parameters and creates a vCenter REST API session.

        .DESCRIPTION
        Validates TotalWaitTime and CheckInterval, resolves the effective credential from
        $Script:VcenterCredential or the supplied parameters, then calls New-VCenterRestApiSession.
        Returns the session object on success. Returns $null (after logging) on parameter-validation
        failure. Throws VcfDeploymentException when session creation fails.

        .PARAMETER CheckInterval
        Seconds between status polls. Must be less than TotalWaitTime.

        .PARAMETER InsecureTls
        When set, bypasses SSL certificate validation.

        .PARAMETER TotalWaitTime
        Maximum wait seconds for READY status. Must be greater than 0.

        .PARAMETER VcenterCredential
        Optional PSCredential. When $Script:VcenterCredential is set it takes precedence.

        .PARAMETER VcenterInsecurePassword
        Plain-text password fallback when no PSCredential is available.

        .PARAMETER VcenterPassword
        SecureString password. Takes precedence over VcenterInsecurePassword when both supplied.

        .PARAMETER VcenterUser
        Username for vCenter REST API authentication.

        .OUTPUTS
        PSCustomObject with Success, SessionHeaders, and ErrorMessage — or $null on parameter failure.

        .EXAMPLE
        $session = Initialize-SupervisorIdSession -CheckInterval 5 -TotalWaitTime 3600 -VcenterUser $vcUser
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingUsernameAndPasswordParams', '')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('UsePSCredentialType', '')]
    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(1, [Int]::MaxValue)] [Int]$CheckInterval = 5,
        [Parameter(Mandatory = $false)] [Switch]$InsecureTls,
        [Parameter(Mandatory = $false)] [ValidateRange(1, [Int]::MaxValue)] [Int]$TotalWaitTime = 3600,
        [Parameter(Mandatory = $false)] [PSCredential]$VcenterCredential,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [String]$VcenterInsecurePassword,
        [Parameter(Mandatory = $false)] [SecureString]$VcenterPassword,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VcenterUser
    )

    if ($TotalWaitTime -le 0) {
        Write-LogMessage -Type ERROR -Message "TotalWaitTime must be greater than 0, got: $TotalWaitTime."
        return $null
    }
    if ($CheckInterval -le 0) {
        Write-LogMessage -Type ERROR -Message "CheckInterval must be greater than 0, got: $CheckInterval."
        return $null
    }
    if ($CheckInterval -ge $TotalWaitTime) {
        Write-LogMessage -Type ERROR -Message "CheckInterval ($CheckInterval) must be less than TotalWaitTime ($TotalWaitTime)."
        return $null
    }

    # Use script-scoped credential when set (main deployment flow). Do NOT use GetNetworkCredential().Password — it can return empty or wrong encoding on some platforms and cause 401 Unauthorized. See PASSWORD_HANDLING.md.
    $effectiveCredential = if ($null -ne $Script:VcenterCredential) { $Script:VcenterCredential } else { $VcenterCredential }
    $hasCredential = ($null -ne $effectiveCredential)
    if (-not $hasCredential) {
        $resolvedPlain = Get-VcenterRestApiPlainPassword -VcenterPassword $VcenterPassword -VcenterInsecurePassword $VcenterInsecurePassword
        if ([String]::IsNullOrWhiteSpace($resolvedPlain)) {
            Write-LogMessage -Type ERROR -Message "No vCenter password available for REST API session. Set Script:VcenterCredential from Connect-Vcenter, or pass -VcenterCredential (PSCredential), -VcenterPassword (SecureString), or -VcenterInsecurePassword."
            return $null
        }
    }

    Write-LogMessage -Type DEBUG -Message "[Step 1/3] Creating REST API session..."
    Write-LogMessage -Type DEBUG -Message "Calling New-VCenterRestApiSession for vCenter `"$Script:vCenterName`", user `"$VcenterUser`", InsecureTls = $InsecureTls."

    $sessionParams = @{
        InsecureTls = $InsecureTls
        VcenterUser = $VcenterUser
    }
    if ($hasCredential) {
        $sessionParams.VcenterCredential = $effectiveCredential
    } elseif ($null -ne $VcenterPassword) {
        $sessionParams.VcenterPassword = $VcenterPassword
    } else {
        $sessionParams.VcenterInsecurePassword = $VcenterInsecurePassword
    }

    $session = New-VCenterRestApiSession @sessionParams

    if (-not $session.Success) {
        $err = "Failed to create REST API session: $($session.ErrorMessage)"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }

    return $session
}
function Get-SupervisorId {

    <#
        .SYNOPSIS
        Returns the supervisor UUID for a named Supervisor cluster, waiting for READY status by default.

        .DESCRIPTION
        Authenticates to the vCenter REST API, queries namespace-management/supervisors/summaries,
        and polls until the matching supervisor reaches READY kubernetes_status.
        Throws on auth failure, supervisor not found, or timeout.

        IMPORTANT: when $Script:VcenterInsecurePassword is set it is used for REST
        authentication rather than -VcenterInsecurePassword, because GetNetworkCredential()
        can return empty or wrong encoding and cause 401 Unauthorized. See PASSWORD_HANDLING.md.

        .PARAMETER SupervisorName
        Exact name of the supervisor cluster as it appears in vCenter (case-insensitive match).

        .PARAMETER VcenterUser
        Username for vCenter REST API authentication.

        .PARAMETER VcenterInsecurePassword
        Password as a plain string for REST Basic auth. Ignored when $Script:VcenterInsecurePassword is set.

        .PARAMETER VcenterPassword
        SecureString alternative to VcenterInsecurePassword. Takes precedence when both are supplied.

        .PARAMETER InsecureTls
        Bypasses SSL certificate validation. Use in lab/dev environments with self-signed certs only.

        .PARAMETER SkipReadyWait
        Return the supervisor ID immediately upon discovery without waiting for READY status.
        Use during cleanup when the supervisor may be in ERROR state and will never become Ready.

        .PARAMETER Silence
        Suppresses the INFO log on successful discovery.

        .PARAMETER TotalWaitTime
        Maximum seconds to wait for READY status. Default: 3600.

        .PARAMETER CheckInterval
        Seconds between status polls. Default: 5.

        .EXAMPLE
        $supervisorId = Get-SupervisorId -SupervisorName $Script:SupervisorName -VcenterUser $Script:VCenterUser -InsecureTls

        .OUTPUTS
        System.String — supervisor UUID (format: "domain-cNNN").

        .NOTES
        API endpoints:
        • POST /rest/com/vmware/cis/session
        • GET /api/vcenter/namespace-management/supervisors/summaries

        .LINK
        Add-Supervisor
        Get-OrCreateSupervisor
    #>

    [CmdletBinding()]
    [OutputType([String])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingUsernameAndPasswordParams', '')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('UsePSCredentialType', '')]
    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(1, [Int]::MaxValue)] [Int]$CheckInterval = 5,
        [Parameter(Mandatory = $false)] [Switch]$InsecureTls,
        [Parameter(Mandatory = $false)] [Switch]$Silence,
        [Parameter(Mandatory = $false)] [Switch]$SkipReadyWait,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorName,
        [Parameter(Mandatory = $false)] [ValidateRange(1, [Int]::MaxValue)] [Int]$TotalWaitTime = 3600,
        [Parameter(Mandatory = $false)] [PSCredential]$VcenterCredential,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [String]$VcenterInsecurePassword,
        [Parameter(Mandatory = $false)] [SecureString]$VcenterPassword,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VcenterUser
    )

    Write-LogMessage -Type DEBUG -Message "Entered Get-SupervisorId function..."

    Write-LogMessage -Type INFO -Message "Retrieving supervisor ID for `"$SupervisorName`" on vCenter `"$Script:vCenterName`"..."

    # Initialize session variable for cleanup in finally block.
    $session = $null

    try {
        $session = Initialize-SupervisorIdSession -CheckInterval $CheckInterval -InsecureTls:$InsecureTls.IsPresent -TotalWaitTime $TotalWaitTime -VcenterCredential $VcenterCredential -VcenterInsecurePassword $VcenterInsecurePassword -VcenterPassword $VcenterPassword -VcenterUser $VcenterUser
        if ($null -eq $session) { return $null }  # soft failure already logged by helper

        Write-LogMessage -Type DEBUG -Message "[Step 2/3] Searching for supervisor cluster..."

        $findParams = @{
            SupervisorName = $SupervisorName
            SessionHeaders = $session.SessionHeaders
            InsecureTls = $InsecureTls
        }
        $findResult = Find-SupervisorByName @findParams

        if (-not $findResult.Success) {
            $err = "Failed to query supervisors: $($findResult.ErrorMessage)"
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }

        # If supervisor not found, return null (may not be created yet).
        if (-not $findResult.Found) {
            Write-LogMessage -Type DEBUG -Message "[Step 3/3] Supervisor instance `"$SupervisorName`" not found. Proceeding to create it."
            return $null
        }

        # When called from cleanup, we only need the ID — the supervisor may be in ERROR state and
        # will never reach READY. Return immediately without blocking on readiness.
        if ($SkipReadyWait) {
            Write-LogMessage -Type DEBUG -Message "SkipReadyWait set; returning supervisor ID `"$($findResult.SupervisorId)`" without waiting for READY status."
            return $findResult.SupervisorId
        }

        # Supervisor found - now wait for it to become ready.
        Write-LogMessage -Type INFO -Message "Waiting for supervisor `"$SupervisorName`" to become ready..."

        $waitParams = @{
            SupervisorName = $SupervisorName
            SessionHeaders = $session.SessionHeaders
            TimeoutSeconds = $TotalWaitTime
            CheckInterval = $CheckInterval
            InsecureTls = $InsecureTls
        }
        $waitResult = Wait-SupervisorDiscoverable @waitParams

        if (-not $waitResult.Success) {
            $err = "Supervisor did not become ready: $($waitResult.ErrorMessage)"
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }

        # Supervisor is ready.
        if (-not $Silence) {
            Write-LogMessage -Type INFO -Message "Supervisor instance `"$SupervisorName`" reported status ready, after waiting for $($waitResult.ElapsedSeconds) seconds."
        }

        return $waitResult.SupervisorId

    } catch [VcfDeploymentException] {
        throw  # already logged and typed — propagate without re-wrapping
    } catch {
        $err = "Unable to fetch supervisor ID for `"$SupervisorName`": $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    } finally {
        # Cleanup the vCenter REST API session.
        if ($session -and $session.Success -and $session.SessionHeaders) {
            try {
                Invoke-RestMethod -Method DELETE `
                    -Uri "https://$Script:vCenterName/rest/com/vmware/cis/session" `
                    -Headers $session.SessionHeaders `
                    -SkipCertificateCheck:$InsecureTls `
                    -ErrorAction SilentlyContinue | Out-Null
            } catch {
                Write-LogMessage -Type DEBUG -Message "Suppressed during session cleanup: $($_.Exception.Message)"
            }
        }
    }
}
function Get-StoragePolicyId {

    <#
        .SYNOPSIS
        Retrieves the unique identifier of a vSphere Storage Policy-Based Management (SPBM) storage policy.

        .DESCRIPTION
        The Get-StoragePolicyId function queries the vCenter to retrieve the unique identifier
        of a specified storage policy by name. This function is essential for supervisor cluster
        configuration and other vSphere operations that require storage policy references.

        The function uses the VMware PowerCLI Get-SpbmStoragePolicy cmdlet to locate the storage
        policy and extract its ID property. The returned ID can be used in subsequent operations
        such as supervisor cluster creation, VM deployment, or storage configuration tasks.

        This function includes comprehensive error handling and will terminate script execution
        if the specified storage policy cannot be found or if any errors occur during the lookup
        process. All operations are logged using the Write-LogMessage system for consistent
        error reporting and troubleshooting.

        .PARAMETER StoragePolicyName
        The name of the storage policy for which to retrieve the unique identifier. This parameter
        is mandatory and must match an existing storage policy name in the connected vCenter.
        Common examples include "vSAN Default Storage Policy", "VM Storage Policy - Thick Provision",
        or custom storage policies created for specific deployment requirements.

        .EXAMPLE
        Get-StoragePolicyId -StoragePolicyName "vSAN Default Storage Policy"

        Retrieves the unique identifier for the default vSAN storage policy.

        .EXAMPLE
        $policyId = Get-StoragePolicyId -StoragePolicyName "VM Storage Policy - Thick Provision"

        Stores the storage policy ID in a variable for use in subsequent operations.

        .EXAMPLE
        Get-StoragePolicyId -StoragePolicyName $InputData.common.storagePolicy.storagePolicyName

        Retrieves the storage policy ID using a policy name from configuration data.

        .OUTPUTS
        System.String
        Returns the unique identifier (GUID) of the specified storage policy as a string.

        .NOTES
        - Requires an active PowerCLI connection to vCenter via the $Script:vCenterName variable
        - Uses the Get-SpbmStoragePolicy cmdlet from VMware PowerCLI
        - Throws a terminating error if the storage policy is not found or any errors occur
        - The returned ID is typically used for supervisor cluster configuration and VM deployment operations
        - Storage policy names are case-sensitive and must match exactly as they appear in vCenter
        - This function is commonly used in conjunction with supervisor cluster creation and supervisor configuration
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$StoragePolicyName
    )

    Write-LogMessage -Type DEBUG -Message "Entered Get-StoragePolicyId function..."

    Assert-VcenterConnected

    try {
        $policy = Get-SpbmStoragePolicy -Name $StoragePolicyName -Server $Script:vCenterName -ErrorAction SilentlyContinue
        if (-not $policy) {
            return $null
        }
        return $policy.Id
    } catch {
        $err = "Unable to fetch storage policy id `"$StoragePolicyName`" on `"$Script:vCenterName`": $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
}
function Get-OrCreateSupervisor {

    <#
        .SYNOPSIS
        Gets or creates a supervisor cluster and returns its ID.

        .DESCRIPTION
        This function retrieves the storage policy ID from the specified storage policy name, then checks
        if a supervisor with the given name already exists. If the supervisor exists, it returns the
        existing supervisor ID. If it doesn't exist, it creates a new supervisor using the provided
        JSON configuration and returns the new supervisor ID.

        The function uses script-level variables for vCenter connection details ($Script:vCenterName
        and $Script:VCenterUser) and requires the vCenter password to be passed as a parameter.

        The function supports optional TLS certificate validation bypass through the insecureTls parameter,
        which is passed through to both Get-SupervisorId and Add-Supervisor functions. When the insecureTls
        switch is not specified, TLS certificate validation is enforced (secure by default).

        .PARAMETER ClusterId
        The ID of the vSphere cluster where the supervisor should be created or verified to exist.
        Format example: "domain-c123" or similar vCenter managed object reference.

        .PARAMETER ClusterName
        The name of the vSphere cluster. This is used for logging and identification purposes
        when creating a supervisor. The cluster must exist and match the ClusterId.

        .PARAMETER SuppressNetworkVanityPrefix
        When set, passes through to Add-Supervisor so WCP API network vanity names match distributed port group labels (legacy behavior).

        .PARAMETER InsecureTls
        Optional switch parameter that bypasses SSL certificate validation for vCenter connections.
        When specified, this flag is passed to both Get-SupervisorId and Add-Supervisor functions,
        allowing operations in development and lab environments where valid certificates may not be
        available. If not specified, TLS certificate validation is enforced (secure by default).
        This parameter should not be used in production environments.

        .PARAMETER StoragePolicyId
        The id of the storage policy. This policy will be used for the supervisor configuration.
        The storage policy must exist and be compatible with the target cluster infrastructure.

        .PARAMETER SupervisorJson
        The JSON configuration file path or content for supervisor creation. This configuration is used
        when creating a new supervisor and must contain all required supervisor specifications including
        control plane configuration, network settings, and supervisor component specifications.

        .PARAMETER SupervisorName
        The name of the supervisor to check for existence or create if it doesn't exist. This name must
        follow vSphere supervisor naming conventions and should be unique within the vCenter environment.

        .PARAMETER VcenterInsecurePassword
        The decrypted password for vCenter authentication. Used to authenticate with vCenter when checking
        for existing supervisors and when creating new supervisors. This should be provided as a plain
        text string (decrypted from SecureString).

        .PARAMETER EdgeSite
        Edge site identifier to match against siteSpec entries in supervisor JSON.

        .PARAMETER NetworkSegments
        Array of network segments from infrastructure JSON for gateway mapping.

        .PARAMETER SingleSite
        When set, the rollback prompt on supervisor timeout shows only Y/N (no A=always), since there is no next site.

        .EXAMPLE
        Get-OrCreateSupervisor -StoragePolicyId "policy-123" -SupervisorName "supervisor-01" -VcenterInsecurePassword "VMware1!" -SupervisorJson $SupervisorJson -ClusterId "domain-c123" -ClusterName "Cluster-01"

        Checks if supervisor "supervisor-01" exists, creates it if it doesn't, and returns the supervisor ID.
        TLS certificate validation is enforced (secure mode).

        .EXAMPLE
        Get-OrCreateSupervisor -StoragePolicyId "policy-123" -SupervisorName "supervisor-01" -VcenterInsecurePassword "VMware1!" -SupervisorJson $SupervisorJson -ClusterId "domain-c123" -ClusterName "Cluster-01" -InsecureTls

        Checks if supervisor "supervisor-01" exists, creates it if it doesn't, and returns the supervisor ID.
        TLS certificate validation is bypassed for development/lab environments.

        .OUTPUTS
        System.String
        Returns the supervisor ID (either existing or newly created) as a string in the format "domain-cXXX".

        .NOTES
        Prerequisites:
        • Script-level variables $Script:vCenterName and $Script:VCenterUser must be set
        • vCenter must be accessible and credentials must be valid
        • Target cluster must exist and be properly configured
        • Storage policy must exist and be compatible with the cluster

        .LINK
        Get-SupervisorId
        Add-Supervisor
        Get-StoragePolicyId
    #>

    [CmdletBinding()]
    [OutputType([String])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingUsernameAndPasswordParams', '')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('UsePSCredentialType', '')]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterId,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EdgeSite,
        [Parameter(Mandatory = $false)] [Switch]$InsecureTls,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Object[]]$NetworkSegments,
        [Parameter(Mandatory = $false)] [Switch]$SingleSite,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$StoragePolicyId,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorJson,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorName,
        [Parameter(Mandatory = $false)] [Switch]$SuppressNetworkVanityPrefix,
        [Parameter(Mandatory = $false)] [PSCredential]$VcenterCredential,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [String]$VcenterInsecurePassword
    )

    Write-LogMessage -Type DEBUG -Message "Entered Get-OrCreateSupervisor function..."

    # Use script-scoped credential when set (main deployment flow). Same reason as Get-SupervisorId—avoids 401 from wrong encoding. See PASSWORD_HANDLING.md.
    $effectiveCredential = if ($null -ne $Script:VcenterCredential) { $Script:VcenterCredential } else { $VcenterCredential }

    # Probe for an existing supervisor without waiting for READY — we only need the ID to decide whether to create.
    $supervisorId = Get-SupervisorId `
        -SupervisorName      $SupervisorName `
        -VcenterUser         $Script:VCenterUser `
        -VcenterCredential   $effectiveCredential `
        -InsecureTls:$InsecureTls.IsPresent `
        -SkipReadyWait `
        -Silence `
        -ErrorAction         SilentlyContinue

    if (-not $supervisorId) {
        $supervisorId = Add-Supervisor `
            -InfrastructureJson                     $SupervisorJson `
            -StoragePolicyId                        $StoragePolicyId `
            -ClusterId                              $ClusterId `
            -ClusterName                            $ClusterName `
            -SupervisorName                         $SupervisorName `
            -VcenterCredential                      $effectiveCredential `
            -EdgeSite                               $EdgeSite `
            -NetworkSegments                        $NetworkSegments `
            -SingleSite:$SingleSite.IsPresent `
            -InsecureTls:$InsecureTls.IsPresent `
            -SuppressNetworkVanityPrefix:$SuppressNetworkVanityPrefix.IsPresent
    }

    return $supervisorId
}
function Get-AvailableVmClassNames {

    <#
        .SYNOPSIS
        Returns VM class names available in the connected vCenter for namespace assignment.

        .DESCRIPTION
        Queries vCenter (VCF PowerCLI 9) for VM classes available at the vCenter level via
        Invoke-ListNamespaceManagementVirtualMachineClasses. Used when infrastructure.json
        clusters[].supervisorServices.vmClass is not set to assign all available VM classes to the ArgoCD namespace.

        .OUTPUTS
        [String[]] Array of VM class names (e.g. Id or name property from API).

        .NOTES
        Requires an active connection to vCenter before calling. On failure, set clusters[].supervisorServices.vmClass in infrastructure.json to an array of VM class names.
    
        .EXAMPLE
        # Called inside a deployment orchestrator that has a top-level try/catch for VcfDeploymentException.
        $vmClasses = Get-AvailableVmClassNames
    #>

    [CmdletBinding()]
    [OutputType([String[]])]
    Param ()

    Write-LogMessage -Type DEBUG -Message "Entered Get-AvailableVmClassNames..."
    $noVmClassesErr = "Could not list VM classes from vCenter. Set clusters[].supervisorServices.vmClass in infrastructure.json to an array of VM class names (e.g. best-effort-small, best-effort-medium)."
    $vmClassNames = [System.Collections.Generic.List[String]]::new()
    try {
        $list = Invoke-ListNamespaceManagementVirtualMachineClasses -ErrorAction Stop
        if ($list) {
            foreach ($item in $list) {
                $name = $null
                if ($null -ne $item.PSObject.Properties["Id"]) { $name = $item.Id }
                elseif ($null -ne $item.PSObject.Properties["Name"]) { $name = $item.Name }
                if (-not [String]::IsNullOrWhiteSpace($name)) {
                    $vmClassNames.Add($name.Trim())
                }
            }
        }
    } catch {
        Write-LogMessage -Type DEBUG -Message "Get-AvailableVmClassNames: Invoke-ListNamespaceManagementVirtualMachineClasses failed: $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -Message $noVmClassesErr
        throw [VcfDeploymentException]::new($noVmClassesErr)
    }
    if ($vmClassNames.Count -eq 0) {
        Write-LogMessage -Type ERROR -Message $noVmClassesErr
        throw [VcfDeploymentException]::new($noVmClassesErr)
    }
    Write-LogMessage -Type INFO -Message "Using all available VM classes for ArgoCD namespace."
    return $vmClassNames.ToArray()
}
function Invoke-ArgoCDNamespaceCreate {

    <#
        .SYNOPSIS
        Creates a Supervisor namespace for ArgoCD and waits for it to stabilize.

        .DESCRIPTION
        Calls the VCF PowerCLI API to create the namespace on the given supervisor, handles
        structured error-type extraction from the error message, and emits troubleshooting guidance
        when the supervisor is in a transitional state (NOT_ALLOWED_IN_CURRENT_STATE). Throws
        VcfDeploymentException on any failure.

        .PARAMETER ArgoCdNamespace
        Kubernetes-compatible name for the namespace (lowercase alphanumeric and hyphens; max 63 chars).

        .PARAMETER NamespaceStabilizationDelaySeconds
        Seconds to wait after successful namespace creation for the API to stabilize.

        .PARAMETER SupervisorId
        Supervisor UUID on which the namespace will be created.

        .EXAMPLE
        Invoke-ArgoCDNamespaceCreate -ArgoCdNamespace "argocd" -NamespaceStabilizationDelaySeconds 5 -SupervisorId $supervisorId

        .NOTES
        Private helper for Add-ArgoCDNamespace. Callers testing Add-ArgoCDNamespace must stub
        Initialize-VcenterNamespacesInstancesCreateSpecV2 and Invoke-CreateNamespacesInstancesV2
        rather than mocking this helper directly. Throws VcfDeploymentException on any creation
        failure; the actual error details are logged before throwing.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ArgoCdNamespace,
        [Parameter(Mandatory = $false)] [ValidateRange(1, [Int]::MaxValue)] [Int]$NamespaceStabilizationDelaySeconds = 5,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorId
    )

    Write-LogMessage -Type DEBUG -Message "Creating namespace `"$ArgoCdNamespace`" on supervisor `"$SupervisorId`"..."
    try {
        $vcenterNamespacesInstancesCreateSpecV2 = Initialize-VcenterNamespacesInstancesCreateSpecV2 -supervisor $SupervisorId -Namespace $ArgoCdNamespace
        Invoke-CreateNamespacesInstancesV2 -VcenterNamespacesInstancesCreateSpecV2 $vcenterNamespacesInstancesCreateSpecV2 -Confirm:$false -ErrorAction Stop | Out-Null
        Write-LogMessage -Type DEBUG -Message "Namespace creation initiated successfully."
    } catch {
        $errorMessage = $_.Exception.Message
        if ($errorMessage -match '"error_type":"([^"]+)"') {
            $errorType = $matches[1]
            Write-LogMessage -Type ERROR -Message "Failed to create namespace `"$ArgoCdNamespace`": Error type: $errorType"
        } else {
            Write-LogMessage -Type ERROR -Message "Failed to create namespace `"$ArgoCdNamespace`""
        }
        $cleanMessage = Get-CleanErrorMessage -ErrorMessage $errorMessage
        Write-LogMessage -Type ERROR -Message "Reason: $cleanMessage"
        Write-LogMessage -Type ERROR -Message "Supervisor ID: $SupervisorId"
        Write-LogMessage -Type ERROR -Message "Namespace: $ArgoCdNamespace"
        if ($errorMessage -match 'NOT_ALLOWED_IN_CURRENT_STATE') {
            Write-LogMessage -Type ERROR -Message ""
            Write-LogMessage -Type ERROR -Message "TROUBLESHOOTING: The supervisor cluster is not in a valid state for namespace creation."
            Write-LogMessage -Type ERROR -Message "Possible causes:"
            Write-LogMessage -Type ERROR -Message "  - Workloads are being enabled or disabled on the supervisor."
            Write-LogMessage -Type ERROR -Message "  - Supervisor is in a transitional state."
            Write-LogMessage -Type ERROR -Message "  - Another operation is in progress."
            Write-LogMessage -Type ERROR -Message "Resolution: Wait for the supervisor to reach a stable state and retry."
        }
        throw [VcfDeploymentException]::new("Namespace `"$ArgoCdNamespace`" could not be created: $cleanMessage")
    }
    Start-Sleep -Seconds $NamespaceStabilizationDelaySeconds
}
function New-ArgoCDNamespaceSetSpec {

    <#
        .SYNOPSIS
        Builds the VcenterNamespacesInstancesSetSpec for an ArgoCD namespace.

        .DESCRIPTION
        Initializes the storage specification, builds a sanitized VM classes array (using foreach
        to avoid a VCF PowerCLI bug where pipeline-bound arrays may evaluate '$_' literals), and
        combines both into the namespace set specification. Throws VcfDeploymentException on any
        API initialization failure.

        .PARAMETER StoragePolicyId
        vSphere storage policy UUID to apply to all PVCs in the namespace.

        .PARAMETER VmClasses
        Array of VM class names. Each entry is explicitly cast to [String] to avoid the '$_'
        evaluation bug in some VCF PowerCLI versions when binding arrays via pipeline.

        .EXAMPLE
        $setSpec = New-ArgoCDNamespaceSetSpec -StoragePolicyId $policyId -VmClasses @("best-effort-small")

        .NOTES
        Private helper for Add-ArgoCDNamespace. Returns a VcenterNamespacesInstancesSetSpec for use
        with Invoke-SetNamespaceInstances. Throws VcfDeploymentException on any API initialization
        failure; callers should not re-wrap the exception.
    #>

    [CmdletBinding()]
    [OutputType([Object])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$StoragePolicyId,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Object[]]$VmClasses
    )

    Write-LogMessage -Type DEBUG -Message "Initializing storage specification with policy ID: $StoragePolicyId"
    $storageSpec = Initialize-VcenterNamespacesInstancesStorageSpec -Policy $StoragePolicyId -ErrorAction Stop
    Write-LogMessage -Type DEBUG -Message "Storage specification initialized successfully."

    # Pass VM classes as array (API expects List<string>, not comma-separated string).
    # Build a new array with foreach (no pipeline) to avoid triggering a bug in the VCF cmdlet
    # that can cause '"$_"' to be evaluated when the parameter is bound from a piped array.
    Write-LogMessage -Type DEBUG -Message "Configuring VM classes ($($VmClasses.Count)): $($VmClasses -join ', ')"
    $vmClassesArray = [System.Collections.Generic.List[String]]::new()
    foreach ($className in $VmClasses) { $vmClassesArray.Add([String]$className) }
    $vmClassesToPass = $vmClassesArray.ToArray()

    Write-LogMessage -Type DEBUG -Message "Initializing VM service specification with VM classes..."
    try {
        $vmServiceSpec = Initialize-VcenterNamespacesInstancesVMServiceSpec -VmClasses $vmClassesToPass -ErrorAction Stop
        Write-LogMessage -Type DEBUG -Message "VM service specification initialized successfully."
    } catch [VcfDeploymentException] {
        throw  # already logged and typed — propagate without re-wrapping
    } catch {
        Write-LogMessage -Type ERROR -Message "Failed to initialize VM service specification."
        Write-LogMessage -Type ERROR -Message "Error details: $($_.Exception.Message)"
        $err = "VM classes attempted: $($VmClasses -join ', ')"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }

    Write-LogMessage -Type DEBUG -Message "Initializing namespace set specification..."
    try {
        $setSpec = Initialize-VcenterNamespacesInstancesSetSpec -StorageSpecs $storageSpec -VmServiceSpec $vmServiceSpec -ErrorAction Stop
        Write-LogMessage -Type DEBUG -Message "Namespace set specification initialized successfully."
    } catch [VcfDeploymentException] {
        throw  # already logged and typed — propagate without re-wrapping
    } catch {
        Write-LogMessage -Type ERROR -Message "Failed to initialize namespace set specification."
        $err = "Error details: $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }

    return $setSpec
}
function Add-ArgoCDNamespace {

    <#
        .SYNOPSIS
        Creates and configures a Supervisor namespace for ArgoCD deployment.

        .DESCRIPTION
        Creates the namespace on the specified supervisor, applies unlimited storage with the given
        policy, and assigns VM classes. Returns early (idempotent) if the namespace already exists.
        Deletes the namespace if VM class configuration fails to avoid orphaned namespaces.
        Terminates on other critical errors.

        .PARAMETER SupervisorId
        Supervisor UUID where the namespace will be created (from Get-SupervisorId).

        .PARAMETER ArgoCdNamespace
        Kubernetes-compatible name (lowercase alphanumeric and hyphens; max 63 chars).

        .PARAMETER StoragePolicyId
        vSphere storage policy UUID applied to all PVCs in the namespace.

        .PARAMETER VmClasses
        Array of VM class names (e.g., @("best-effort-small")).
        Each class must exist in vCenter inventory.

        .EXAMPLE
        Add-ArgoCDNamespace -SupervisorId $supId -ArgoCdNamespace "argocd" -StoragePolicyId $policyId -VmClasses @("best-effort-medium")

        .LINK
        Get-SupervisorId
        Install-ArgoCDOperator
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ArgoCdNamespace,
        [Parameter(Mandatory = $false)] [ValidateRange(1, [Int]::MaxValue)] [Int]$NamespaceStabilizationDelaySeconds = 5,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$StoragePolicyId,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorId,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Object[]]$VmClasses
    )

    Write-LogMessage -Type DEBUG -Message "Entered Add-ArgoCDNamespace function..."
    Write-LogMessage -Type DEBUG -Message "Add-ArgoCDNamespace received namespace parameter: `"$ArgoCdNamespace`""

    # Reject VM class names that contain '$' to avoid triggering bugs in VCF PowerCLI that re-evaluate such strings.
    $invalidVmClasses = @($VmClasses | Where-Object { [String]$_ -match '\$' })
    if ($invalidVmClasses.Count -gt 0) {
        $invalidList = $invalidVmClasses -join ', '
        $err = "Invalid VM class name(s): $invalidList. VM class names must not contain '$' (dollar sign)."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }

    try {
        if ((Invoke-ListNamespacesInstances).Namespace -contains $ArgoCdNamespace) {
            Write-LogMessage -Type INFO -Message "The ArgoCD namespace `"$ArgoCdNamespace`" already exists on vCenter `"$Script:vCenterName`" Skipping namespace creation."
            return
        }

        Invoke-ArgoCDNamespaceCreate `
            -ArgoCdNamespace $ArgoCdNamespace `
            -NamespaceStabilizationDelaySeconds $NamespaceStabilizationDelaySeconds `
            -SupervisorId $SupervisorId
        $vcenterNamespacesInstancesSetSpec = New-ArgoCDNamespaceSetSpec `
            -StoragePolicyId $StoragePolicyId `
            -VmClasses $VmClasses

        Write-LogMessage -Type DEBUG -Message "Applying namespace configuration to `"$ArgoCdNamespace`"..."
        Write-LogMessage -Type DEBUG -Message "This step assigns VM classes: $($VmClasses -join ', ')"
        try {
            Invoke-SetNamespaceInstances -Namespace $ArgoCdNamespace -VcenterNamespacesInstancesSetSpec $vcenterNamespacesInstancesSetSpec -Confirm:$false -ErrorAction Stop | Out-Null
            Write-LogMessage -Type DEBUG -Message "Namespace configuration applied successfully."
        } catch {
            $errorMessage = $_.Exception.Message
            $cleanMessage = Get-CleanErrorMessage -ErrorMessage $errorMessage
            Write-LogMessage -Type ERROR -Message "Failed to apply namespace configuration: $cleanMessage."
            Write-LogMessage -Type ERROR -Message "VM classes attempted: $($VmClasses -join ', ')"
            Write-LogMessage -Type ERROR -Message "Namespace: $ArgoCdNamespace"
            Write-LogMessage -Type INFO -Message "Cleaning up: Deleting namespace `"$ArgoCdNamespace`" due to configuration failure..."
            $cleanupSucceeded = $false
            try {
                Invoke-DeleteNamespaceInstances -Namespace $ArgoCdNamespace -Confirm:$false -ErrorAction Stop | Out-Null
                $cleanupSucceeded = $true
                Write-LogMessage -Type INFO -Message "Namespace `"$ArgoCdNamespace`" deleted during configuration failure cleanup."
            } catch {
                Write-LogMessage -Type WARNING -Message "Failed to delete namespace `"$ArgoCdNamespace`" during cleanup: $($_.Exception.Message)"
                Write-LogMessage -Type WARNING -Message "Manual namespace deletion may be required."
            }
            $cleanupNote = if ($cleanupSucceeded) { "Namespace deleted during cleanup." } else { "Manual namespace deletion required." }
            throw [VcfDeploymentException]::new("Namespace configuration failed for `"$ArgoCdNamespace`": $cleanMessage. $cleanupNote")
        }

        Start-Sleep -Seconds $NamespaceStabilizationDelaySeconds
        Write-LogMessage -Type INFO -Message "The ArgoCD namespace `"$ArgoCdNamespace`" was created successfully with $($VmClasses.Count) VM classes assigned: $($VmClasses -join ', ')"
    } catch [VcfDeploymentException] {
        throw  # already logged and typed — propagate without re-wrapping
    } catch {
        $err = "Add-ArgoCDNamespace: unexpected failure: $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
}
function Invoke-ArgoCDServiceCreate {

    <#
        .SYNOPSIS
        Submits the ArgoCD Supervisor Service creation request and handles all expected error variants.

        .DESCRIPTION
        Calls Initialize-VcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec and then
        Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesCreate. Handles the following
        outcomes silently (does not throw): service already exists. Throws VcfDeploymentException for
        all unrecoverable errors (not-activated, version not found, compatibility check failure).

        .PARAMETER CheckInterval
        Seconds to sleep after a successful creation before the caller begins polling.

        .PARAMETER Service
        Supervisor Service reference name (e.g., "argocd-service.vsphere.vmware.com").

        .PARAMETER ServiceNamespace
        Pre-computed service namespace (format: svc-<slug>-<ClusterId>). Used in error messages.

        .PARAMETER SupervisorId
        Supervisor UUID on which the service is being installed.

        .PARAMETER Version
        Operator version string (e.g., "1.0.0-24815986").

        .OUTPUTS
        None. Throws on unrecoverable failure; returns normally on success or "already exists".

        .EXAMPLE
        Invoke-ArgoCDServiceCreate -Service "argocd-service.vsphere.vmware.com" -Version "1.0.0" -SupervisorId $supId -ServiceNamespace "svc-argocd-service-domain-c1" -CheckInterval 5
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(1, [Int]::MaxValue)] [Int]$CheckInterval = 5,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Service,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ServiceNamespace,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorId,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Version
    )

    $vcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec = Initialize-VcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec -SupervisorService $Service -Version $Version
    try {
        Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesCreate -supervisor $SupervisorId -vcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec $vcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec -Confirm:$false -ErrorAction Stop
        Write-LogMessage -Type DEBUG -Message "The ArgoCD operator was successfully created. Waiting for configuration tasks to complete."
        Start-Sleep $CheckInterval
    } catch {
        $errMsg = $_.Exception.Message

        switch -Regex ($errMsg) {
            "Supervisor Service.*already exists|an instance.*Supervisor Service.*already exists" {
                Write-LogMessage -Type INFO -Message "ArgoCD service already exists. Verifying configuration status..."
            }
            "Supervisor Service is not in activated state" {
                Write-LogMessage -Type ERROR -Message "ArgoCD operator installation failed: Failed to create Supervisor Service ($Service) version ($Version) on cluster ($SupervisorId). Supervisor Service is not in activated state."
                Write-LogMessage -Type INFO -Message ""
                Write-LogMessage -Type ERROR -Message "This error indicates the ArgoCD service already exists but is in a broken or deactivated state."
                Write-LogMessage -Type ERROR -Message "SOLUTION: Delete and recreate the ArgoCD operator service:"
                Write-LogMessage -Type ERROR -Message "  1. In vCenter UI, navigate to: Menu > Supervisor Management > Services."
                Write-LogMessage -Type ERROR -Message "  2. Find `"$Service`" in the list."
                Write-LogMessage -Type ERROR -Message "  3. Click the Actions dropdown menu for this service."
                Write-LogMessage -Type ERROR -Message "  4. If available, click `"Deactivate Service`" and wait for completion."
                Write-LogMessage -Type ERROR -Message "  5. Click the Actions dropdown menu again."
                Write-LogMessage -Type ERROR -Message "  6. Click `"Delete`" to remove the service."
                Write-LogMessage -Type ERROR -Message "  7. Wait for the service to be fully deleted."
                Write-LogMessage -Type ERROR -Message "  8. Re-run this script to install a clean ArgoCD operator."
                Write-LogMessage -Type INFO -Message ""
                Write-LogMessage -Type WARNING -Message "If the service is stuck and cannot be deleted via UI:"
                Write-LogMessage -Type WARNING -Message "  Use kubectl to manually clean up the namespace: kubectl delete namespace $ServiceNamespace"
                Write-LogMessage -Type WARNING -Message "  List namespaces with: kubectl get namespaces"
                Write-LogMessage -Type WARNING -Message "  Then manually remove the service via vCenter REST API or contact VMware support."
                throw [VcfDeploymentException]::new("ArgoCD service is not in activated state on supervisor `"$SupervisorId`". Check logs for details.")
            }
            "Signature verification result for Service Version \(([0-9.-]+)\) not found" {
                $requestedVersion = $matches[1]
                $cleanErrorMessage = Get-CleanErrorMessage -ErrorMessage $errMsg
                if ($cleanErrorMessage -eq $errMsg) {
                    $cleanErrorMessage = "ArgoCD service version $requestedVersion is not available on this supervisor."
                }
                Write-LogMessage -Type ERROR -Message "ArgoCD operator installation failed: $cleanErrorMessage."
                Write-LogMessage -Type INFO -Message ""
                Write-LogMessage -Type ERROR -Message "SOLUTION: Either upgrade your supervisor to a version that includes ArgoCD service $requestedVersion,"
                Write-LogMessage -Type ERROR -Message "         or modify your infrastructure.json to specify a different ArgoCD service version that is available."
                Write-LogMessage -Type INFO -Message ""
                Write-LogMessage -Type ERROR -Message "To list available ArgoCD service versions, use the vSphere API or vCenter UI:"
                $err = "  Menu > Supervisor Management > Supervisors > ArgoCD Service > Manager Versions"
                Write-LogMessage -Type ERROR -Message $err
                throw [VcfDeploymentException]::new($err)
            }
            "Supervisor Service \(argocd-service\.vsphere\.vmware\.com\) version \(([^)]+)\) has not been found" {
                $requestedVersion = $matches[1]
                $cleanErrorMessage = "ArgoCD service version $requestedVersion is not available on this supervisor."
                Write-LogMessage -Type ERROR -Message "ArgoCD operator installation failed: $cleanErrorMessage"
                Write-LogMessage -Type INFO -Message ""
                Write-LogMessage -Type ERROR -Message "SOLUTION: Either upgrade your supervisor to a version that includes ArgoCD service $requestedVersion,"
                Write-LogMessage -Type ERROR -Message "         or modify your infrastructure.json to specify a different ArgoCD service version that is available."
                Write-LogMessage -Type INFO -Message ""
                Write-LogMessage -Type ERROR -Message "To list available ArgoCD service versions, use the vSphere API or vCenter UI:"
                $err = "  Menu > Supervisor Management > Supervisors > ArgoCD Service > Manager Versions"
                Write-LogMessage -Type ERROR -Message $err
                throw [VcfDeploymentException]::new($err)
            }
            "Failed to run compatibility check for Supervisor Service" {
                $cleanErrorMessage = Get-CleanErrorMessage -ErrorMessage $errMsg
                Write-LogMessage -Type ERROR -Message "ArgoCD operator installation failed: $cleanErrorMessage."
                Write-LogMessage -Type INFO -Message ""
                Write-LogMessage -Type ERROR -Message "SOLUTION: Upgrade your supervisor to version 9.0.0.0-0100-24847555 or higher and try again."
                $err = "This error indicates the supervisor version is too old to verify the ArgoCD service signature."
                Write-LogMessage -Type ERROR -Message $err
                throw [VcfDeploymentException]::new($err)
            }
            default {
                $cleanMessage = Get-CleanErrorMessage -ErrorMessage $errMsg
                if ($cleanMessage -ne $errMsg) {
                    Write-LogMessage -Type ERROR -Message "ArgoCD operator installation failed: $cleanMessage."
                } else {
                    Write-LogMessage -Type ERROR -Message "Unexpected error in Invoke-ArgoCDServiceCreate: $errMsg."
                }
                throw [VcfDeploymentException]::new("ArgoCD operator installation failed: $errMsg")
            }
        }
    }
}
function Test-ArgoCDIpExhaustion {

    <#
        .SYNOPSIS
        Detects workload network IP pool exhaustion from kubectl event text and emits diagnostic guidance.

        .DESCRIPTION
        Inspects the pre-fetched kubectl event text from the ArgoCD service namespace for known IP
        exhaustion patterns. When detected, emits ERROR-level diagnostic messages describing the root
        cause and the corrective action. Returns $true when exhaustion is detected so the caller
        can skip redundant error reporting; returns $false otherwise.

        .PARAMETER EventsText
        Raw text output from "kubectl get events" in the ArgoCD service namespace. May be empty.

        .PARAMETER ServiceNamespace
        The ArgoCD service namespace name. Used only in log messages for context.

        .OUTPUTS
        [Bool] $true when IP exhaustion was detected and diagnostics were emitted; $false otherwise.

        .EXAMPLE
        $isExhausted = Test-ArgoCDIpExhaustion -EventsText $kubectlEventsOutput -ServiceNamespace $serviceNs
        if ($isExhausted) { throw [VcfDeploymentException]::new("IP pool exhausted.") }

        .NOTES
        Only call this from within the ArgoCD ERROR status handler after confirming the service is in
        an ERROR state. The EventsText must already be fetched by the caller.
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [String]$EventsText,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ServiceNamespace
    )

    if ([String]::IsNullOrWhiteSpace($EventsText)) {
        return $false
    }

    if ($EventsText -notmatch "exhausted all IP addresses in requested IPPools|has 0 free ips which is less than") {
        return $false
    }

    Write-LogMessage -Type ERROR -Message "ROOT CAUSE — workload network IP pool exhausted: pods could not get IP addresses."
    Write-LogMessage -Type ERROR -Message "DIAGNOSIS: The supervisor workload network IP pool in namespace `"$ServiceNamespace`" has no free addresses. ArgoCD pods were scheduled but their network interfaces could not be realized."
    Write-LogMessage -Type ERROR -Message "SOLUTION: Increase the pool size in supervisor.json: raise `"siteSpec[N].primaryWorkloadNetwork.primaryWorkloadNetworkIPCount`" to allocate more addresses, then roll back (Y) and redeploy. Add at least 8-16 to the current count to leave headroom."

    $ipLines = $EventsText -split "`n" | Where-Object { $_ -match "exhausted|has 0 free ips|NetworkInterfaceRealizationFailed" }
    if ($ipLines.Count -gt 0) {
        Write-LogMessage -Type ERROR -Message "IP exhaustion events:"
        $ipLines | Select-Object -Unique | ForEach-Object { Write-LogMessage -Type INFO -Message "  $_" }
    }

    return $true
}
function Assert-ArgoCDServiceExists {

    <#
        .SYNOPSIS
        Verifies that the ArgoCD Supervisor Service was created on the given supervisor.

        .DESCRIPTION
        Calls Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesGet. If the service is
        not found, logs a remediation guide and throws VcfDeploymentException. Non-"not-found"
        errors are treated as transient (service may be initializing) and are silently swallowed
        so the caller can proceed to the monitoring loop.

        .PARAMETER Service
        Supervisor Service reference name (e.g., "argocd-service.vsphere.vmware.com").

        .PARAMETER SupervisorId
        Supervisor UUID to query.

        .NOTES
        Helper extracted from Wait-ArgoCDOperatorConfigured to satisfy the 80-line body limit.
    
        .EXAMPLE
        Assert-ArgoCDServiceExists -Service "value" -SupervisorId "domain-c123"
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Service,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorId
    )

    Write-LogMessage -Type DEBUG -Message "Verifying ArgoCD operator service exists on supervisor `"$SupervisorId`" before waiting for configuration..."
    try {
        $verifyService = Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesGet -supervisor $SupervisorId -supervisorService $Service -ErrorAction Stop
        Write-LogMessage -Type DEBUG -Message "Service verified. Current config status: $($verifyService.ConfigStatus)"
    } catch {
        $verifyError = $_.Exception.Message
        if ($verifyError -match "not found|does not exist") {
            Write-LogMessage -Type ERROR -Message "ArgoCD operator service was not created successfully on supervisor `"$SupervisorId`"."
            Write-LogMessage -Type ERROR -Message "The service creation may have failed silently. Error: $verifyError"
            Write-LogMessage -Type INFO -Message ""
            Write-LogMessage -Type ERROR -Message "SOLUTION:"
            Write-LogMessage -Type ERROR -Message "  1. Verify the supervisor ID `"$SupervisorId`" is correct for this cluster."
            Write-LogMessage -Type ERROR -Message "  2. Check vCenter UI: Menu > Workload Management > Supervisor Clusters"
            Write-LogMessage -Type ERROR -Message "  3. Verify the supervisor cluster is in `"Running`" state."
            Write-LogMessage -Type ERROR -Message "  4. Check for any error messages in the supervisor cluster status."
            Write-LogMessage -Type INFO -Message ""
            throw [VcfDeploymentException]::new("Deployment failed. ArgoCD operator service was not created. Check logs for details.")
        }
        # Service might exist but API call failed — continue to monitoring loop.
        Write-LogMessage -Type DEBUG -Message "Could not verify service existence (may be initializing): $verifyError"
    }
}
function Write-ArgoCDPollNotFoundError {

    <#
        .SYNOPSIS
        Logs a remediation guide and throws when the ArgoCD service disappears during the poll loop.

        .DESCRIPTION
        Called from Wait-ArgoCDOperatorConfigured when the poll loop Get call returns
        a "not found" error, indicating the service was never created or was on a different supervisor.

        .PARAMETER SupervisorId
        Supervisor UUID used in diagnostic log messages.

        .NOTES
        Helper extracted from Wait-ArgoCDOperatorConfigured to satisfy the 80-line body limit.
    
        .EXAMPLE
        Write-ArgoCDPollNotFoundError -SupervisorId "domain-c123"
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorId
    )

    Write-Progress -Activity "Waiting for ArgoCD operator configuration" -Status "Error" -Completed
    Write-LogMessage -Type ERROR -Message "ArgoCD operator service does not exist on supervisor `"$SupervisorId`"."
    Write-LogMessage -Type ERROR -Message "The service creation failed or the service was created on a different supervisor."
    Write-LogMessage -Type INFO -Message ""
    Write-LogMessage -Type ERROR -Message "SOLUTION:"
    Write-LogMessage -Type ERROR -Message "  1. Verify the supervisor ID `"$SupervisorId`" matches the correct supervisor cluster."
    Write-LogMessage -Type ERROR -Message "  2. Check vCenter UI: Menu > Workload Management > Supervisor Clusters"
    Write-LogMessage -Type ERROR -Message "  3. Look for the ArgoCD service in the Services section of the supervisor cluster."
    Write-LogMessage -Type ERROR -Message "  4. If the service exists on a different supervisor, verify the cluster ID and supervisor ID are correct."
    Write-LogMessage -Type INFO -Message ""
    throw [VcfDeploymentException]::new("Deployment failed. ArgoCD operator service does not exist. Check logs for details.")
}
function Write-ArgoCDPollClusterNotRunningError {

    <#
        .SYNOPSIS
        Logs a remediation guide and throws when the supervisor cluster is not in a running state.

        .DESCRIPTION
        Called from Wait-ArgoCDOperatorConfigured when the poll loop Get call returns a
        "cluster.not_running" or "not in running state" error.

        .PARAMETER ErrorMessage
        The raw error message from the API exception used in the diagnostic log.

        .NOTES
        Helper extracted from Wait-ArgoCDOperatorConfigured to satisfy the 80-line body limit.
    
        .EXAMPLE
        Write-ArgoCDPollClusterNotRunningError -ErrorMessage "Operation failed."
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ErrorMessage
    )

    Write-Progress -Activity "Waiting for ArgoCD operator configuration" -Status "Error" -Completed
    $cleanMessage = Get-CleanErrorMessage -ErrorMessage $ErrorMessage
    Write-LogMessage -Type ERROR -Message "The supervisor cluster is not in a running state. ArgoCD operator installation cannot proceed."
    Write-LogMessage -Type ERROR -Message "Error details: $cleanMessage."
    Write-LogMessage -Type INFO -Message ""
    Write-LogMessage -Type ERROR -Message "SOLUTION: Verify and ensure the supervisor cluster is running:"
    Write-LogMessage -Type ERROR -Message "  1. Login to vCenter `"$Script:vCenterName`""
    Write-LogMessage -Type ERROR -Message "  2. Navigate to: Menu > Workload Management > Supervisor Clusters"
    Write-LogMessage -Type ERROR -Message "  3. Check the status of the supervisor cluster (should show as `"Running`")"
    Write-LogMessage -Type ERROR -Message "  4. If the cluster is not running, check for errors in the cluster configuration."
    Write-LogMessage -Type ERROR -Message "  5. Wait for the supervisor cluster to reach `"Running`" state before retrying"
    Write-LogMessage -Type INFO -Message ""
    throw [VcfDeploymentException]::new("Deployment failed. Supervisor cluster is not running. Check logs for details.")
}
function Write-ArgoCDConfigErrorMessages {

    <#
        .SYNOPSIS
        Logs diagnostic messages when the ArgoCD service config status is ERROR.

        .DESCRIPTION
        Fetches Kubernetes events from the service namespace, calls Test-ArgoCDIpExhaustion,
        then pattern-matches the service error messages to emit a specific remediation guide.
        Does not throw — the caller is responsible for throwing after this function returns.

        .PARAMETER ErrorMessages
        The raw Messages string from the service output used for pattern matching.

        .PARAMETER ServiceNamespace
        Namespace used for kubectl event fetching and inline remediation instructions.

        .NOTES
        Helper extracted from Wait-ArgoCDOperatorConfigured to satisfy the 80-line body limit.
    
        .EXAMPLE
        Write-ArgoCDConfigErrorMessages -ErrorMessages "Operation failed." -ServiceNamespace "argocd"
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ErrorMessages,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ServiceNamespace
    )

    $cleanErrorMessage = Get-CleanServiceErrorMessage -ErrorMessage $ErrorMessages
    $argoCDEventsText = ""
    try {
        $argoCDEventsOutput = & $Script:KubectlCmd get events -n $ServiceNamespace --sort-by=".lastTimestamp" 2>&1
        if ($LASTEXITCODE -eq 0 -and -not [String]::IsNullOrWhiteSpace($argoCDEventsOutput)) {
            $argoCDEventsText = ($argoCDEventsOutput | Out-String).Trim()
        }
    } catch {
        Write-LogMessage -Type DEBUG -Message "Could not pre-fetch events from `"$ServiceNamespace`": $($_.Exception.Message)"
    }

    $null = Test-ArgoCDIpExhaustion -EventsText $argoCDEventsText -ServiceNamespace $ServiceNamespace

    switch -Regex ($ErrorMessages) {
        "ReconcileFailed|already exists|AlreadyExists" {
            if ($ErrorMessages -match 'namespaces\s+"([^"]*)"\s+not found') {
                $missingNamespace = $matches[1]
                if ([String]::IsNullOrWhiteSpace($missingNamespace)) {
                    Write-LogMessage -Type ERROR -Message "ArgoCD operator installation failed: supervisor service reported a required namespace is empty or missing."
                    Write-LogMessage -Type ERROR -Message "This can occur when the ArgoCD workload namespace did not exist when the operator was created. This script now creates the namespace before installing the operator."
                    Write-LogMessage -Type INFO -Message ""
                    Write-LogMessage -Type ERROR -Message "SOLUTION: Delete the ArgoCD service and re-run so the namespace is created first:"
                    Write-LogMessage -Type ERROR -Message "  1. In vCenter UI: Menu > Supervisor Management > Services."
                    Write-LogMessage -Type ERROR -Message "  2. Delete or deactivate the ArgoCD service if it is in ERROR state."
                    Write-LogMessage -Type ERROR -Message "  3. Re-run this script; it will create the ArgoCD namespace before installing the operator."
                } else {
                    Write-LogMessage -Type ERROR -Message "ArgoCD operator installation failed: Required namespace `"$missingNamespace`" does not exist."
                    Write-LogMessage -Type ERROR -Message "This may indicate the supervisor service namespace was not created properly or was deleted."
                    Write-LogMessage -Type INFO -Message ""
                    Write-LogMessage -Type ERROR -Message "SOLUTION: Verify the supervisor service namespace exists and retry:"
                    Write-LogMessage -Type ERROR -Message "  1. Check if the namespace exists: kubectl get namespace $missingNamespace"
                    Write-LogMessage -Type ERROR -Message "  2. If the namespace is missing, the supervisor service may need to be recreated."
                    Write-LogMessage -Type ERROR -Message "  3. In vCenter UI, navigate to: Menu > Supervisor Management > Services."
                    Write-LogMessage -Type ERROR -Message "  4. Delete the ArgoCD service if it exists in ERROR state."
                    Write-LogMessage -Type ERROR -Message "  5. Re-run this script to create a fresh installation."
                }
            } else {
                Write-LogMessage -Type ERROR -Message "ArgoCD operator installation failed due to conflicting resources from a previous installation."
                Write-LogMessage -Type ERROR -Message "$cleanErrorMessage"
                Write-LogMessage -Type INFO -Message ""
                Write-LogMessage -Type ERROR -Message "SOLUTION: Clean up the existing ArgoCD operator and retry:"
                Write-LogMessage -Type ERROR -Message "  1. In vCenter UI, navigate to: Menu > Supervisor Management > Services."
                Write-LogMessage -Type ERROR -Message "  2. Find `"ArgoCD Service`" and the Actions dropdown menu."
                Write-LogMessage -Type ERROR -Message "  3. Click on Delete."
                Write-LogMessage -Type ERROR -Message "  4. Click on Deactivate Service."
                Write-LogMessage -Type ERROR -Message "  5. Click on Confirm."
                Write-LogMessage -Type ERROR -Message "  6. Click on Delete."
                Write-LogMessage -Type ERROR -Message "  7. Wait for the service to be deleted."
                Write-LogMessage -Type ERROR -Message "  8. Re-run this script to install a clean ArgoCD operator."
                Write-LogMessage -Type WARNING -Message "If the service is stuck in ERROR state and cannot be deleted via UI:"
                Write-LogMessage -Type WARNING -Message "  Use kubectl to manually clean up the namespace: kubectl delete namespace $ServiceNamespace"
                Write-LogMessage -Type WARNING -Message "  List namespaces with: kubectl get namespaces"
            }
        }
        default {
            Write-LogMessage -Type ERROR -Message "ArgoCD operator installation failed: $cleanErrorMessage"
        }
    }
}
function Wait-ArgoCDOperatorConfigured {

    <#
        .SYNOPSIS
        Verifies the ArgoCD Supervisor Service exists and polls until its ConfigStatus is CONFIGURED.

        .DESCRIPTION
        First verifies the service was created by calling Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesGet.
        Then polls ConfigStatus in a do-while loop until CONFIGURED, ERROR, or TotalWaitTime is exceeded.
        On ERROR, emits diagnostic information and throws. On timeout, throws.

        .PARAMETER CheckInterval
        Seconds between status polls. Default: 5.

        .PARAMETER ClusterName
        Cluster display name used in Write-SupervisorKubernetesDiagnosticReport on failure.

        .PARAMETER Service
        Supervisor Service reference name (e.g., "argocd-service.vsphere.vmware.com").

        .PARAMETER ServiceNamespace
        Pre-computed service namespace (format: svc-<slug>-<ClusterId>). Used in error messages.

        .PARAMETER SupervisorId
        Supervisor UUID to query.

        .PARAMETER TotalWaitTime
        Maximum seconds to wait. Default: 600.

        .OUTPUTS
        None. Returns after CONFIGURED is reached. Throws on ERROR or timeout.

        .EXAMPLE
        Wait-ArgoCDOperatorConfigured -SupervisorId $supId -Service "argocd-service.vsphere.vmware.com" -ServiceNamespace "svc-argocd-service-domain-c1" -ClusterName "cl01"
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(1, [Int]::MaxValue)] [Int]$CheckInterval = 5,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Service,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ServiceNamespace,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorId,
        [Parameter(Mandatory = $false)] [ValidateRange(1, [Int]::MaxValue)] [Int]$TotalWaitTime = 600
    )

    Assert-ArgoCDServiceExists -SupervisorId $SupervisorId -Service $Service

    $elapsedTime = 0

    do {
        try {
            $serviceOutput = Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesGet -supervisor $SupervisorId -supervisorService $Service
        } catch {
            $errorMessage = $_.Exception.Message
            if ($errorMessage -match "not found|does not exist") {
                Write-ArgoCDPollNotFoundError -SupervisorId $SupervisorId
            } elseif ($errorMessage -match "Error converting value.*config_status") {
                Write-LogMessage -Type DEBUG -Message "Supervisor service status not yet available (empty config_status). Waiting..."
                $statusMessage = "Elapsed Time: $elapsedTime seconds - Status: Initializing (config status not yet available)"
                Write-Progress -Activity "Waiting for ArgoCD operator configuration" -Status $statusMessage
                Start-Sleep $CheckInterval
                $elapsedTime += $CheckInterval
                continue
            } elseif ($errorMessage -match "cluster.not_running|not in running state") {
                Write-ArgoCDPollClusterNotRunningError -ErrorMessage $errorMessage
            } else {
                throw
            }
        }

        switch ($serviceOutput.ConfigStatus) {
            "CONFIGURED" {
                Write-Progress -Activity "Waiting for ArgoCD operator configuration" -Status "Complete" -Completed
                Write-LogMessage -Type INFO -Message "The ArgoCD operator has been successfully installed on vCenter `"$Script:vCenterName`". (Took $elapsedTime seconds)."
                return
            }
            "ERROR" {
                Write-Progress -Activity "Waiting for ArgoCD operator configuration" -Status "Error" -Completed
                $cleanErrorMessage = Get-CleanServiceErrorMessage -ErrorMessage $serviceOutput.Messages
                Write-ArgoCDConfigErrorMessages -ErrorMessages $serviceOutput.Messages -ServiceNamespace $ServiceNamespace
                throw [VcfDeploymentException]::new("ArgoCD operator installation failed: $cleanErrorMessage")
            }
            default {
                $statusMessage = "Elapsed Time: $elapsedTime seconds - Status: $($serviceOutput.ConfigStatus)"
                Write-Progress -Activity "Waiting for ArgoCD operator configuration" -Status $statusMessage
                Start-Sleep $CheckInterval
                $elapsedTime += $CheckInterval
            }
        }
    } while ($elapsedTime -lt $TotalWaitTime)

    Write-Progress -Activity "Waiting for ArgoCD operator configuration" -Status "Timeout" -Completed
    $err = "The service install request has timed out after $TotalWaitTime seconds. Please check the service logs for more information."
    Write-LogMessage -Type ERROR -Message $err
    throw [VcfDeploymentException]::new($err)
}
function Install-ArgoCDOperator {

    <#
        .SYNOPSIS
        Installs the ArgoCD operator as a Supervisor Service on a vSphere Supervisor cluster.

        .DESCRIPTION
        Creates the Supervisor Service spec via Initialize-VcenterNamespaceManagement...CreateSpec,
        submits it, then polls configuration status until CONFIGURED, ERROR, or timeout.
        Handles "already exists" gracefully. Throws on critical failures.

        .PARAMETER ClusterId
        vCenter cluster MoRef (e.g., "domain-c462"). Used to construct the service namespace name
        for error messages; not used in the creation API call itself.

        .PARAMETER ClusterName
        Cluster display name used when logging Kubernetes diagnostics on failure.

        .PARAMETER SupervisorId
        Supervisor UUID from Get-SupervisorId. The service is installed on this supervisor.

        .PARAMETER Service
        Supervisor Service reference name (e.g., "argocd-service.vsphere.vmware.com").

        .PARAMETER Version
        Operator version string (e.g., "1.0.0-24815986") from the ArgoCD service YAML package.

        .PARAMETER TotalWaitTime
        Maximum seconds to wait for CONFIGURED status. Default: 600.

        .PARAMETER CheckInterval
        Seconds between status polls. Default: 5.

        .EXAMPLE
        Install-ArgoCDOperator -ClusterId $ClusterId -ClusterName $ClusterName -SupervisorId $supId -Service $svcName -Version $svcVersion

        .NOTES
        Minimum supervisor version: 9.0.0.0-0100-24847555.
        The initial 30-second delay after service creation is intentional.

        .LINK
        Set-ArgoCDService
        Add-ArgoCDNamespace
        Add-ArgoCDInstance
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(1, [Int]::MaxValue)] [Int]$CheckInterval = 5,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterId,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Service,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorId,
        [Parameter(Mandatory = $false)] [ValidateRange(1, [Int]::MaxValue)] [Int]$TotalWaitTime = 600,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Version
    )

    Write-LogMessage -Type DEBUG -Message "Entered Install-ArgoCDOperator function for cluster `"$ClusterName`"..."

    # The service slug is derived from the service name by removing the domain suffix.
    # The cluster ID (e.g., domain-c462) is used, NOT the supervisor UUID.
    $serviceSlug = $Service -replace '\.vsphere\.vmware\.com$', ''
    $serviceNamespace = "svc-$serviceSlug-$ClusterId"

    try {
        Invoke-ArgoCDServiceCreate `
            -Service           $Service `
            -Version           $Version `
            -SupervisorId      $SupervisorId `
            -ServiceNamespace  $serviceNamespace `
            -CheckInterval     $CheckInterval

        Wait-ArgoCDOperatorConfigured `
            -Service           $Service `
            -SupervisorId      $SupervisorId `
            -ServiceNamespace  $serviceNamespace `
            -ClusterName       $ClusterName `
            -TotalWaitTime     $TotalWaitTime `
            -CheckInterval     $CheckInterval
    } catch [VcfDeploymentException] {
        # Inner function already logged the specific error — run K8s diagnostics then propagate.
        try {
            Write-SupervisorKubernetesDiagnosticReport -ClusterName $ClusterName -Context "Argo CD operator installation did not complete successfully" -SupervisorId $SupervisorId
        } catch {
            Write-LogMessage -Type DEBUG -Message "Supervisor Kubernetes diagnostics (Argo CD operator typed catch): $($_.Exception.Message)"
        }
        throw  # propagate without re-wrapping
    } catch {
        $errMsg = $_.Exception.Message
        $cleanMessage = Get-CleanErrorMessage -ErrorMessage $errMsg

        if ($cleanMessage -ne $errMsg) {
            Write-LogMessage -Type ERROR -Message "ArgoCD operator installation failed: $cleanMessage"
        } else {
            switch -Regex ($errMsg) {
                "vcenter.wcp.appplatform.supervisorservice.cluster.not_running" {
                    Write-LogMessage -Type ERROR -Message "The supervisor cluster is not running. Please login to vCenter `"$Script:vCenterName`" and verify its state."
                    break
                }
                default {
                    Write-LogMessage -Type ERROR -Message "The ArgoCD operator creation failed: $errMsg."
                }
            }
        }
        try {
            Write-SupervisorKubernetesDiagnosticReport -ClusterName $ClusterName -Context "Argo CD operator installation did not complete successfully" -SupervisorId $SupervisorId
        } catch {
            Write-LogMessage -Type DEBUG -Message "Supervisor Kubernetes diagnostics (Argo CD operator outer catch): $($_.Exception.Message)"
        }
        throw [VcfDeploymentException]::new("ArgoCD operator deployment failed: $cleanMessage. Check logs for details.")
    }
}
