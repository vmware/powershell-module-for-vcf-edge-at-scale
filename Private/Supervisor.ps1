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
Function Write-ClusterEsxiNodeHealthReport {

    <#
        .SYNOPSIS
        Logs ESX host connection and power state for a vSphere cluster after deployment checks.

        .DESCRIPTION
        Emits a single summary line when all hosts are healthy (ConnectionState=Connected and
        PowerState=PoweredOn). When one or more hosts are unhealthy, logs a header and lists only
        the unhealthy hosts at WARNING severity so operators can triage without scrolling past
        noise for healthy hosts.

        .PARAMETER ClusterName
        The vCenter cluster display name.
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName
    )

    try {
        $clusterObject = Get-Cluster -Name $ClusterName -Server $Script:vCenterName -ErrorAction Stop
        $vmHosts = @(Get-VMHost -Location $clusterObject -Server $Script:vCenterName -ErrorAction Stop | Sort-Object -Property Name)
        $unhealthyHosts = @($vmHosts | Where-Object { $_.ConnectionState -ne "Connected" -or $_.PowerState -ne "PoweredOn" })
        if ($unhealthyHosts.Count -eq 0) {
            Write-LogMessage -Type INFO -Message "ESX node health for cluster `"$ClusterName`" ($($vmHosts.Count) host(s)): all Connected/PoweredOn."
            return
        }
        Write-LogMessage -Type WARNING -Message "ESX node health for cluster `"$ClusterName`" ($($vmHosts.Count) host(s)): $($unhealthyHosts.Count) not Connected/PoweredOn."
        foreach ($vmHost in $unhealthyHosts) {
            Write-LogMessage -Type WARNING -Message "  $($vmHost.Name): ConnectionState=$($vmHost.ConnectionState), PowerState=$($vmHost.PowerState)."
        }
    } catch {
        Write-LogMessage -Type WARNING -Message "Could not list ESX host health for cluster `"$ClusterName`": $($_.Exception.Message)"
    }
}
Function Write-SupervisorHealthReport {

    <#
        .SYNOPSIS
        Logs a concise supervisor health summary after deployment, surfacing only non-healthy findings.

        .DESCRIPTION
        Queries the supervisor summary via Invoke-GetSupervisorNamespaceManagementSummary (and
        conditions via Invoke-GetSupervisorNamespaceManagementConditions when available) and logs a
        single INFO line when the supervisor is healthy (ConfigStatus=RUNNING, KubernetesStatus=READY,
        no ERROR/WARNING summary messages, all conditions Status=True). When any check is not
        healthy, delegates to Write-SupervisorKubernetesDiagnosticReport for the full diagnostic
        output. Non-fatal if the API is unavailable.

        .PARAMETER ClusterName
        The vCenter cluster display name (for log context).

        .PARAMETER SupervisorId
        Supervisor resource identifier.
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorId
    )

    $cmdSummary = Get-Command Invoke-GetSupervisorNamespaceManagementSummary -ErrorAction SilentlyContinue
    if (-not $cmdSummary) {
        Write-LogMessage -Type DEBUG -Message "Write-SupervisorHealthReport: Invoke-GetSupervisorNamespaceManagementSummary is not available; skipping post-deployment supervisor health report."
        return
    }

    try {
        $summary = Invoke-GetSupervisorNamespaceManagementSummary -Supervisor $SupervisorId -ErrorAction Stop
    } catch {
        Write-LogMessage -Type WARNING -Message "Could not read supervisor health for cluster `"$ClusterName`" (supervisor `"$SupervisorId`"): $($_.Exception.Message)"
        return
    }

    $configStatus = $summary.ConfigStatus
    $kubernetesStatus = $summary.KubernetesStatus
    $summaryMessages = @($summary.Messages)
    $nonInfoMessages = @($summaryMessages | Where-Object {
        $severityText = if ($null -ne $_.Severity) { $_.Severity.ToString() } else { "" }
        $severityText -match "^(ERROR|CRITICAL|WARNING|WARN)$"
    })

    $nonTrueConditions = @()
    $cmdConditions = Get-Command Invoke-GetSupervisorNamespaceManagementConditions -ErrorAction SilentlyContinue
    if ($cmdConditions) {
        try {
            $conditions = @(Invoke-GetSupervisorNamespaceManagementConditions -Supervisor $SupervisorId -ErrorAction Stop)
            $nonTrueConditions = @($conditions | Where-Object { $_.Status -ne "True" -and -not [String]::IsNullOrWhiteSpace($_.Status) })
        } catch {
            Write-LogMessage -Type DEBUG -Message "Supervisor conditions API failed for cluster `"$ClusterName`" (supervisor `"$SupervisorId`"): $($_.Exception.Message)"
        }
    }

    $isHealthy = ($configStatus -eq "RUNNING") -and ($kubernetesStatus -eq "READY") -and ($nonInfoMessages.Count -eq 0) -and ($nonTrueConditions.Count -eq 0)
    if ($isHealthy) {
        Write-LogMessage -Type INFO -Message "Supervisor health for cluster `"$ClusterName`" (supervisor `"$SupervisorId`"): ConfigStatus=RUNNING, KubernetesStatus=READY, no outstanding messages or conditions."
        return
    }

    # Delegate to the full diagnostic report so operators can see summary messages and condition details.
    Write-SupervisorKubernetesDiagnosticReport -ClusterName $ClusterName -Context "post-deployment health (ConfigStatus=$configStatus, KubernetesStatus=$kubernetesStatus)" -SupervisorId $SupervisorId
}
Function Write-VsanClusterHealthReport {

    <#
        .SYNOPSIS
        Logs a concise vSAN cluster health summary after deployment, surfacing only non-green findings.

        .DESCRIPTION
        Calls Get-VsanClusterHealthSummaryViaView with FetchFromCache=$true so the latest cached
        result (refreshed by Invoke-VsanClusterHealthRetestAfterDeployment) is reported. Logs a
        single INFO line when overallHealth is green; otherwise logs a header plus the non-green
        group/test entries at WARNING severity. Non-fatal when the vSAN Health API is unavailable.

        .PARAMETER ClusterName
        The vSAN cluster name.
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName
    )

    $healthSummary = Get-VsanClusterHealthSummaryViaView -ClusterName $ClusterName -FetchFromCache $true
    if (-not $healthSummary) {
        Write-LogMessage -Type WARNING -Message "vSAN health for cluster `"$ClusterName`": summary not available from vCenter. Check vSAN Health in the UI."
        return
    }

    $overallHealth = $healthSummary.overallHealth
    if ($overallHealth -eq "green") {
        Write-LogMessage -Type INFO -Message "vSAN health for cluster `"$ClusterName`": overallHealth=green."
        return
    }

    $overallDescription = $healthSummary.overallHealthDescription
    $headerLine = "vSAN health for cluster `"$ClusterName`": overallHealth=$overallHealth"
    if (-not [String]::IsNullOrWhiteSpace($overallDescription)) {
        $headerLine += " ($overallDescription)"
    }
    $headerLine += "."
    Write-LogMessage -Type WARNING -Message $headerLine

    # List only non-green tests so Connected/healthy checks are not shown.
    $healthGroups = $healthSummary.groups
    if (-not $healthGroups) {
        return
    }
    foreach ($healthGroup in @($healthGroups)) {
        $groupName = $healthGroup.PSObject.Properties["groupName"].Value
        $groupTests = $healthGroup.PSObject.Properties["tests"].Value
        if (-not $groupTests) {
            continue
        }
        foreach ($test in @($groupTests)) {
            $testHealth = $test.PSObject.Properties["health"].Value
            if (-not $testHealth -or $testHealth -eq "green") {
                continue
            }
            $testName = $test.PSObject.Properties["testName"].Value
            Write-LogMessage -Type WARNING -Message "  [$testHealth] $groupName / $testName"
        }
    }
}
Function Write-SupervisorKubernetesDiagnosticReport {

    <#
        .SYNOPSIS
        Logs supervisor Kubernetes status messages and conditions from the vCenter namespace-management APIs.

        .DESCRIPTION
        Surfaces the same class of information shown under Kubernetes Status in the vCenter UI (summary
        messages such as workload network IP pool utilization, plus supervisor conditions when the API is available).

        .PARAMETER ClusterName
        Cluster name for log context.

        .PARAMETER Context
        Short phrase describing why diagnostics are being shown (for example timeout or Harbor failure).

        .PARAMETER SupervisorId
        Supervisor resource identifier passed to Invoke-GetSupervisorNamespaceManagementSummary.
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [String]$Context,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorId
    )

    $cmdSummary = Get-Command Invoke-GetSupervisorNamespaceManagementSummary -ErrorAction SilentlyContinue
    if (-not $cmdSummary) {
        Write-LogMessage -Type DEBUG -Message "Write-SupervisorKubernetesDiagnosticReport: Invoke-GetSupervisorNamespaceManagementSummary is not available."
        return
    }

    $headerSuffix = "cluster `"$ClusterName`", supervisor `"$SupervisorId`""
    $header = if ([String]::IsNullOrWhiteSpace($Context)) {
        "Supervisor Kubernetes diagnostics ($headerSuffix)"
    } else {
        "Supervisor Kubernetes diagnostics — $Context ($headerSuffix)"
    }
    Write-LogMessage -Type INFO -Message "======== $header ========"
    Write-LogMessage -Type INFO -Message "Kubernetes Status in the UI indicates whether the Supervisor is operable; messages below mirror the supervisor summary API."

    try {
        $summary = Invoke-GetSupervisorNamespaceManagementSummary -Supervisor $SupervisorId -ErrorAction Stop
    } catch {
        Write-LogMessage -Type WARNING -Message "Could not read supervisor summary from vCenter: $($_.Exception.Message)"
        Write-LogMessage -Type INFO -Message "======== End supervisor Kubernetes diagnostics ========"
        return
    }

    Write-LogMessage -Type INFO -Message "ConfigStatus: $($summary.ConfigStatus); KubernetesStatus: $($summary.KubernetesStatus)."

    if ($null -ne $summary.Stats) {
        $st = $summary.Stats
        # Render utilization as percentages at INFO (easy to parse); keep absolute values at DEBUG.
        $cpuPercent = if ($st.CpuCapacity -gt 0) { [Math]::Round(($st.CpuUsed / $st.CpuCapacity) * 100, 1) } else { 0 }
        $memoryPercent = if ($st.MemoryCapacity -gt 0) { [Math]::Round(($st.MemoryUsed / $st.MemoryCapacity) * 100, 1) } else { 0 }
        $storagePercent = if ($st.StorageCapacity -gt 0) { [Math]::Round(($st.StorageUsed / $st.StorageCapacity) * 100, 1) } else { 0 }
        Write-LogMessage -Type INFO -Message "Summary utilization: CPU=$cpuPercent% Memory=$memoryPercent% Storage=$storagePercent%."
        Write-LogMessage -Type DEBUG -Message "Summary stats (absolute): CpuUsed=$($st.CpuUsed) CpuCapacity=$($st.CpuCapacity) MemoryUsed=$($st.MemoryUsed) MemoryCapacity=$($st.MemoryCapacity) StorageUsed=$($st.StorageUsed) StorageCapacity=$($st.StorageCapacity)."
    }

    $summaryMessages = @($summary.Messages)
    if ($summaryMessages.Count -gt 0) {
        Write-LogMessage -Type INFO -Message "Supervisor summary messages ($($summaryMessages.Count)):"
        foreach ($msg in $summaryMessages) {
            $severityText = if (-not [String]::IsNullOrWhiteSpace($msg.Severity)) { $msg.Severity.ToString() } else { "" }

            # Details is a VapiStdLocalizableMessage object; prefer the localized string, fall back to the default message.
            $detailsText = ""
            if ($null -ne $msg.Details) {
                $detailsText = $msg.Details.Localized
                if ([String]::IsNullOrWhiteSpace($detailsText)) {
                    $detailsText = $msg.Details.DefaultMessage
                }
            }

            # vCenter may return message text in AdditionalProperties when the typed Details object is null or empty.
            # Common field names observed: "message", "detail", "text", "description".
            if ([String]::IsNullOrWhiteSpace($detailsText) -and $null -ne $msg.AdditionalProperties) {
                $apDict = [System.Collections.Generic.IDictionary[string, object]]$msg.AdditionalProperties
                foreach ($apKey in @("message", "detail", "text", "description")) {
                    $apVal = $null
                    if ($apDict.TryGetValue($apKey, [ref]$apVal) -and -not [String]::IsNullOrWhiteSpace($apVal)) {
                        if ([String]::IsNullOrWhiteSpace($detailsText)) {
                            $detailsText = $apVal.ToString()
                        } elseif ($apKey -ne "message") {
                            # Append secondary detail field (e.g. "detail") as a suffix.
                            $detailsText += " Details: '$($apVal.ToString())'."
                        }
                    }
                }
                # Also pull severity from AdditionalProperties if the typed field was empty.
                if ([String]::IsNullOrWhiteSpace($severityText)) {
                    $apSev = $null
                    if ($apDict.TryGetValue("severity", [ref]$apSev) -and -not [String]::IsNullOrWhiteSpace($apSev)) {
                        $severityText = $apSev.ToString()
                    }
                }
            }

            if ([String]::IsNullOrWhiteSpace($detailsText)) {
                $detailsText = "(no details)"
            }
            $messageId = $msg.Id
            $detailsId = if ($null -ne $msg.Details) { $msg.Details.Id } else { $null }
            $kbLink = $msg.KbArticleLink
            $logType = switch -Regex ($severityText) {
                "^(ERROR|CRITICAL)$" {
                    "ERROR"
                    break
                }
                "^(WARNING|WARN)$" {
                    "WARNING"
                    break
                }
                default {
                    "INFO"
                }
            }
            $line = "  [$severityText] $detailsText"
            $idText = if (-not [String]::IsNullOrWhiteSpace($messageId)) { $messageId } else { $detailsId }
            if (-not [String]::IsNullOrWhiteSpace($idText)) {
                $line += " (id: $idText)"
            }
            if (-not [String]::IsNullOrWhiteSpace($kbLink)) {
                $line += " KB: $kbLink"
            }
            Write-LogMessage -Type $logType -Message $line
            # Surface actionable guidance for known message patterns.
            switch -Regex ($detailsText) {
                "IPPool.*utilization|utilization.*IPPool|low on free IP" {
                    Write-LogMessage -Type WARNING -Message "  ^ IP pool utilization is high. If a supervisor service (Harbor or Argo CD) subsequently fails with 'exhausted all IP addresses in requested IPPools', increase `"siteSpec[N].primaryWorkloadNetwork.primaryWorkloadNetworkIPCount`" in supervisor.json and redeploy."
                    break
                }
            }
        }
    } else {
        Write-LogMessage -Type INFO -Message "No summary messages from the API (check Workload Management in the UI if status is not READY)."
    }

    $cmdConditions = Get-Command Invoke-GetSupervisorNamespaceManagementConditions -ErrorAction SilentlyContinue
    if ($cmdConditions) {
        try {
            $conditions = @(Invoke-GetSupervisorNamespaceManagementConditions -Supervisor $SupervisorId -ErrorAction Stop)
            if ($conditions.Count -gt 0) {
                Write-LogMessage -Type INFO -Message "Supervisor conditions ($($conditions.Count)):"
                foreach ($c in $conditions) {
                    $descriptionText = $c.Description
                    if ($descriptionText -and $descriptionText.Length -gt 400) {
                        $descriptionText = $descriptionText.Substring(0, 400) + "..."
                    }
                    $conditionMessages = $c.Messages
                    $joinedMessages = if ($conditionMessages -and $conditionMessages.Count -gt 0) {
                        ($conditionMessages | ForEach-Object { $_.ToString() }) -join "; "
                    } else {
                        ""
                    }
                    Write-LogMessage -Type INFO -Message "  Type=$($c.Type) Status=$($c.Status) Severity=$($c.Severity) Reason=$($c.Reason) Description=$descriptionText Messages=$joinedMessages"
                    if ($c.Status -ne "True" -and -not [String]::IsNullOrWhiteSpace($c.Status)) {
                        Write-LogMessage -Type WARNING -Message "  ^ Condition Status is not True; see Reason/Description/Messages above."
                    }
                }
            }
        } catch {
            Write-LogMessage -Type DEBUG -Message "Supervisor conditions API failed: $($_.Exception.Message)"
        }
    }

    Write-LogMessage -Type INFO -Message "======== End supervisor Kubernetes diagnostics ========"
}
Function Invoke-SupervisorOnlyRollback {

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
Function Invoke-ArgoCDOnlyRollback {
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
Function Wait-HarborServiceNamespaceTermination {

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

    # Run diagnostics against each stuck namespace to identify the blocker.
    foreach ($stuckNs in $stillPresent) {
        Write-LogMessage -Type WARNING -Message "--- Diagnostics for stuck namespace: `"$stuckNs`" ---"

        # Check for namespace-level finalizers (the most common cause of a stuck Terminating namespace).
        $finalizersOutput = $null
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

        # Check for stuck PVCs — bound PVCs with a Retain reclaim policy can block namespace termination.
        try {
            $pvcOutput = & $Script:KubectlCmd get pvc -n "$stuckNs" --no-headers 2>&1
            if ($LASTEXITCODE -eq 0 -and -not [String]::IsNullOrWhiteSpace($pvcOutput) -and $pvcOutput -notmatch "No resources found") {
                Write-LogMessage -Type WARNING -Message "Stuck PVCs in `"$stuckNs`" (Retain reclaim policy may block namespace termination):"
                $pvcOutput -split "`n" | Where-Object { -not [String]::IsNullOrWhiteSpace($_) } | ForEach-Object {
                    Write-LogMessage -Type WARNING -Message "  $_"
                }
                Write-LogMessage -Type WARNING -Message "Delete PVCs manually if present: kubectl delete pvc --all -n $stuckNs"
            }
        } catch {
            Write-LogMessage -Type DEBUG -Message "Could not query PVCs for `"$stuckNs`": $($_.Exception.Message)"
        }

        # Check for stuck pods — pods with long termination grace periods or missing nodes can block namespace GC.
        try {
            $podOutput = & $Script:KubectlCmd get pods -n "$stuckNs" --no-headers 2>&1
            if ($LASTEXITCODE -eq 0 -and -not [String]::IsNullOrWhiteSpace($podOutput) -and $podOutput -notmatch "No resources found") {
                Write-LogMessage -Type WARNING -Message "Stuck pods in `"$stuckNs`" (pods in Terminating state can delay namespace GC):"
                $podOutput -split "`n" | Where-Object { -not [String]::IsNullOrWhiteSpace($_) } | ForEach-Object {
                    Write-LogMessage -Type WARNING -Message "  $_"
                }
                Write-LogMessage -Type WARNING -Message "Force-delete stuck pods: kubectl delete pod --all -n $stuckNs --force --grace-period=0"
            }
        } catch {
            Write-LogMessage -Type DEBUG -Message "Could not query pods for `"$stuckNs`": $($_.Exception.Message)"
        }
    }

    $stuckList = $stillPresent -join ", "
    Write-LogMessage -Type WARNING -Message "Manual resolution — run the following for each stuck namespace (`"$stuckList`"):"
    Write-LogMessage -Type WARNING -Message "  1. Inspect:           kubectl get namespace <ns> -o yaml"
    Write-LogMessage -Type WARNING -Message "  2. Delete PVCs:       kubectl delete pvc --all -n <ns>"
    Write-LogMessage -Type WARNING -Message "  3. Force-delete pods: kubectl delete pod --all -n <ns> --force --grace-period=0"
    Write-LogMessage -Type WARNING -Message "  4. Remove finalizers (last resort; may leave orphaned NSX-T/LB resources):"
    Write-LogMessage -Type WARNING -Message "     kubectl patch namespace <ns> -p '{`"metadata`":{`"finalizers`":null}}' --type=merge"
    Write-LogMessage -Type WARNING -Message "Once all stuck namespaces are gone, re-run: Start-VcfEdgeAtScale -CleanUp Harbor -EdgeSite <site>"
}
Function Remove-HarborContainerImageRegistry {

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
Function Remove-HarborSupervisorService {

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
Function Invoke-HarborOnlyRollback {

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
Function Test-SupervisorDeployedOnCluster {

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
        $configDisabled = [string]::IsNullOrEmpty($configStatus) -or ($configStatus -eq "DISABLED")
        $kubeNotInstalled = [string]::IsNullOrEmpty($kubeStatus) -or ($kubeStatus -eq "NOT_INSTALLED")
        return -not ($configDisabled -and $kubeNotInstalled)
    } catch {
        Write-LogMessage -Type DEBUG -Message "Test-SupervisorDeployedOnCluster: query failed for `"$ClusterName`": $($_.Exception.Message)"
        return $false
    }
}
Function Disable-SupervisorOnCluster {

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

    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(1, [int]::MaxValue)] [Int]$CheckInterval = 10,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterId,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [Switch]$SuppressConfirm,
        [Parameter(Mandatory = $false)] [String]$SupervisorId,
        [Parameter(Mandatory = $false)] [ValidateRange(1, [int]::MaxValue)] [Int]$TimeoutSeconds = 3600
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

        $clusterObject = Get-Cluster -Name $ClusterName -Server $Script:vCenterName -ErrorAction Stop
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

        $elapsedTime = 0
        do {
            $wcpList = @(Invoke-ListNamespaceManagementClusters -ErrorAction SilentlyContinue | Where-Object { $_.clusterName -eq $clusterObject })
            $wcpEntry = $wcpList | Select-Object -First 1
            $configStatus = if ($wcpEntry) { $wcpEntry.ConfigStatus } else { $null }
            $kubeStatus = if ($wcpEntry) { $wcpEntry.KubernetesStatus } else { $null }

            $configDisabled = [string]::IsNullOrEmpty($configStatus) -or ($configStatus -eq "DISABLED")
            $kubeNotInstalled = [string]::IsNullOrEmpty($kubeStatus) -or ($kubeStatus -eq "NOT_INSTALLED")
            if ($configDisabled -and $kubeNotInstalled) {
                Write-Progress -Activity "Waiting for supervisor deactivation" -Status "Complete" -PercentComplete 100 -Completed
                [Console]::Out.Flush()
                Write-LogMessage -Type INFO -CompletePending -Message "fully deactivated after $elapsedTime seconds. You can retry deployment."
                return [PSCustomObject]@{
                    Success = $true
                    ErrorMessage = $null
                }
            }

            $percentComplete = if ($TimeoutSeconds -gt 0) { [Math]::Min(99, [int](($elapsedTime / $TimeoutSeconds) * 100)) } else { 0 }
            $statusMessage = "Elapsed: $elapsedTime s - ConfigStatus: $configStatus, KubernetesStatus: $kubeStatus"
            Write-Progress -Activity "Waiting for supervisor deactivation on `"$ClusterName`"" -Status $statusMessage -PercentComplete $percentComplete
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
    } catch {
        $errorMessage = $_.Exception.Message
        Write-LogMessage -Type ERROR -CompletePending -Message "failed to deactivate supervisor on cluster `"$ClusterName`": $errorMessage"
        return [PSCustomObject]@{
            Success = $false
            ErrorMessage = $errorMessage
        }
    }
}
Function Wait-SupervisorReady {

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

    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(1, [int]::MaxValue)] [Int]$CheckInterval = 5,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorId,
        [Parameter(Mandatory = $false)] [ValidateRange(1, [int]::MaxValue)] [Int]$TotalWaitTime = 1800
    )

    Write-LogMessage -Type DEBUG -Message "Entered Wait-SupervisorReady function..."
    # Clear any lingering progress bar so only one progress bar is visible. PowerCLI vLCM uses "Task created by VMware vSphere Lifecycle Manager"; close it if still visible.
    Write-Progress -Activity "Task created by VMware vSphere Lifecycle Manager" -Completed
    Write-Progress -Activity "Waiting for Supervisor services to become available" -Completed
    [Console]::Out.Flush()

    $elapsedTime = 0
    $currentCheck = 0

    try {
        $consecutive503Errors = 0
        $first503ErrorTime = $null
        $crashDetectionThreshold = 300  # 5 minutes of continuous 503s may indicate a crash
        $maxPersistent503Threshold = 600  # 10 minutes of continuous 503s - exit early
        $warningShown = $false  # Track if we've already shown the warning messages

        do {
            $currentCheck++

            try {
                # Suppress error output from VCF PowerCLI cmdlet to prevent 503 errors from cluttering console.
                # These errors are expected during supervisor initialization and are handled in the catch block.
                $supervisorStatus = Invoke-GetSupervisorNamespaceManagementSummary -Supervisor $SupervisorId -ErrorAction SilentlyContinue 2>$null

                # If cmdlet returned null due to error, check the error variable.
                if ($null -eq $supervisorStatus) {
                    throw "Service unavailable - supervisor services are still initializing."
                }

                # If we got a valid response, reset 503 error tracking.
                if ($supervisorStatus) {
                    $consecutive503Errors = 0
                    $first503ErrorTime = $null
                }
            } catch {
                $errorMsg = $_.Exception.Message

                # Check for common transient network/API errors.
                # SERVICE_UNAVAILABLE (503) is a transient error that occurs when supervisor services are still initializing.
                # However, persistent 503 errors over an extended period may indicate a supervisor crash.

                if ($errorMsg -match "An error occurred while sending the request|The operation has timed out|SERVICE_UNAVAILABLE|Service unavailable|503") {
                    # Track consecutive 503 errors to detect potential crashes.
                    if ($null -eq $first503ErrorTime) {
                        $first503ErrorTime = Get-Date
                    }
                    $consecutive503Errors++
                    $timeSinceFirst503 = (Get-Date) - $first503ErrorTime

                    # Check if 503 errors have persisted beyond the crash detection threshold.
                    if ($timeSinceFirst503.TotalSeconds -ge $crashDetectionThreshold) {
                        # Show warning messages only once.
                        if (-not $warningShown) {
                            Write-LogMessage -Type WARNING -Message "Persistent 503 errors detected for $([int]$timeSinceFirst503.TotalSeconds) seconds ($consecutive503Errors consecutive failures). This may indicate the supervisor service has crashed rather than still initializing."
                            Write-LogMessage -Type WARNING -Message "Attempting to verify supervisor cluster status via alternative method..."

                            # Try to check supervisor cluster status directly via PowerCLI as an alternative diagnostic.
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

                            Write-Host ""
                            Write-LogMessage -Type WARNING -Message "RECOMMENDED ACTIONS:"
                            Write-LogMessage -Type WARNING -Message "  1. Check vCenter UI: Menu > Workload Management > Supervisor Clusters"
                            Write-LogMessage -Type WARNING -Message "  2. Look for error messages or failed state indicators"
                            Write-LogMessage -Type WARNING -Message "  3. Check supervisor control plane VM status and logs"
                            Write-LogMessage -Type WARNING -Message "  4. Review vCenter events for the supervisor cluster"
                            Write-LogMessage -Type WARNING -Message "  5. If supervisor has crashed, you may need to delete and recreate it"
                            Write-Host ""
                            $warningShown = $true
                        }

                        # If persistent 503 errors exceed maximum threshold, exit early.
                        if ($timeSinceFirst503.TotalSeconds -ge $maxPersistent503Threshold) {
                            Write-Progress -Activity "Waiting for Supervisor services to become available" -Status "Failed" -Completed
                            [Console]::Out.Flush()
                            Write-LogMessage -Type ERROR -Message "Persistent 503 errors have exceeded maximum threshold ($maxPersistent503Threshold seconds). Exiting early to prevent infinite loop."
                            Write-LogMessage -Type ERROR -Message "The supervisor service appears to have crashed or vCenter is unreadable. Deployment cannot continue."
                            Write-Host ""
                            Write-LogMessage -Type ERROR -Message "Check the supervisor status in vCenter UI: Menu > Workload Management > Supervisor Clusters"
                            try {
                                Write-SupervisorKubernetesDiagnosticReport -ClusterName $ClusterName -Context "persistent supervisor API errors (503) exceeded early-exit threshold" -SupervisorId $SupervisorId
                            } catch {
                                Write-LogMessage -Type DEBUG -Message "Supervisor Kubernetes diagnostics (503 early exit): $($_.Exception.Message)"
                            }
                            return [PSCustomObject]@{
                                Success = $false
                                ElapsedSeconds = $elapsedTime
                            }
                        }
                    } else {
                        Write-LogMessage -Type DEBUG -Message "Transient API error during supervisor status check (attempt $currentCheck): Service temporarily unavailable. This is expected during supervisor initialization."
                    }

                    # Continue waiting if we haven't exceeded total wait time and haven't hit max persistent 503 threshold.

                    if ($elapsedTime -lt $TotalWaitTime) {
                        $percentComplete = [Math]::Min(99, [int](($elapsedTime / $TotalWaitTime) * 100))
                        if ($timeSinceFirst503.TotalSeconds -ge $crashDetectionThreshold) {
                            $statusMessage = "Elapsed Time: $elapsedTime seconds - Status: CONFIGURING (WARNING: Persistent 503 errors - supervisor may have crashed)"
                        } else {
                            $statusMessage = "Elapsed Time: $elapsedTime seconds - Status: CONFIGURING (API service initializing, 503 errors are expected)"
                        }
                        Write-Progress -Activity "Waiting for Supervisor services to become available" -Status $statusMessage -PercentComplete $percentComplete
                        [Console]::Out.Flush()
                        Start-Sleep $CheckInterval
                        $elapsedTime += $CheckInterval
                        continue
                    }
                    else {
                        # Timeout reached.
                        Write-Progress -Activity "Waiting for Supervisor services to become available" -Status "Timeout" -Completed
                        [Console]::Out.Flush()
                        Write-LogMessage -Type ERROR -Message "Timeout waiting for supervisor services API to respond on cluster `"$ClusterName`" after $TotalWaitTime seconds."
                        if ($timeSinceFirst503.TotalSeconds -ge $crashDetectionThreshold) {
                            Write-LogMessage -Type ERROR -Message "Persistent 503 errors for $([int]$timeSinceFirst503.TotalSeconds) seconds suggest the supervisor service may have crashed."
                        } else {
                            Write-LogMessage -Type ERROR -Message "The supervisor may still be initializing. Check vCenter UI for current status."
                        }
                        Write-Host ""
                        Write-LogMessage -Type ERROR -Message "Check the supervisor status in vCenter UI: Menu > Workload Management > Supervisor Clusters"
                        try {
                            Write-SupervisorKubernetesDiagnosticReport -ClusterName $ClusterName -Context "supervisor summary API unavailable until the wait window expired" -SupervisorId $SupervisorId
                        } catch {
                            Write-LogMessage -Type DEBUG -Message "Supervisor Kubernetes diagnostics (API timeout path): $($_.Exception.Message)"
                        }
                        return [PSCustomObject]@{
                            Success = $false
                            ElapsedSeconds = $elapsedTime
                        }
                    }
                }
                else {
                    # Non-transient error, re-throw.
                    throw
                }
            }

            if ((($supervisorStatus).ConfigStatus -eq "RUNNING") -and (($supervisorStatus).KubernetesStatus -eq "READY")) {
                Write-Progress -Activity "Waiting for Supervisor services to become available" -Status "Complete" -PercentComplete 100 -Completed
                [Console]::Out.Flush()
                Write-LogMessage -Type INFO -Message "Supervisor services on cluster `"$ClusterName`" were successfully configured in $elapsedTime seconds."
                return [PSCustomObject]@{
                    Success = $true
                    ElapsedSeconds = $elapsedTime
                }
            } else {
                $percentComplete = [Math]::Min(99, [int](($elapsedTime / $TotalWaitTime) * 100))
                $statusMessage = "Elapsed Time: $elapsedTime seconds - Status: $($supervisorStatus.ConfigStatus)"
                $currentStatus = "Kubernetes Status: $($supervisorStatus.KubernetesStatus)"
                Write-Progress -Activity "Waiting for Supervisor services to become available" -Status $statusMessage -CurrentOperation $currentStatus -PercentComplete $percentComplete
                [Console]::Out.Flush()
                Start-Sleep $CheckInterval
                $elapsedTime += $CheckInterval
            }
        } while ($elapsedTime -lt $TotalWaitTime)

        # If we exit the loop without success, log timeout and clear progress.

        Write-Progress -Activity "Waiting for Supervisor services to become available" -Status "Timeout" -Completed
        [Console]::Out.Flush()
        Write-LogMessage -Type ERROR -Message "Timeout waiting for supervisor services to become ready on cluster `"$ClusterName`" after $TotalWaitTime seconds ($elapsedTime seconds elapsed)."
        try {
            Write-SupervisorKubernetesDiagnosticReport -ClusterName $ClusterName -Context "supervisor did not reach RUNNING with Kubernetes READY within the wait window" -SupervisorId $SupervisorId
        } catch {
            Write-LogMessage -Type DEBUG -Message "Supervisor Kubernetes diagnostics (readiness timeout): $($_.Exception.Message)"
        }
        return [PSCustomObject]@{
            Success = $false
            ElapsedSeconds = $elapsedTime
        }
    } catch {
        # Log exception with context, then return failure with elapsed time.

        Write-Progress -Activity "Waiting for Supervisor services to become available" -Status "Error" -Completed
        [Console]::Out.Flush()
        Write-LogMessage -Type ERROR -Message "Error checking supervisor services status on cluster `"$ClusterName`": $($_.Exception.Message)"
        Write-Host ""
        Write-LogMessage -Type ERROR -Message "This may indicate:"
        Write-LogMessage -Type ERROR -Message "  1. Network connectivity issues between the client and vCenter."
        Write-LogMessage -Type ERROR -Message "  2. vCenter API temporarily unavailable."
        Write-LogMessage -Type ERROR -Message "  3. Supervisor is in a failed state."
        Write-Host ""
        Write-LogMessage -Type ERROR -Message "Check the supervisor status in vCenter UI: Menu > Workload Management > Supervisors."
        try {
            Write-SupervisorKubernetesDiagnosticReport -ClusterName $ClusterName -Context "exception during supervisor readiness polling" -SupervisorId $SupervisorId
        } catch {
            Write-LogMessage -Type DEBUG -Message "Supervisor Kubernetes diagnostics (readiness exception path): $($_.Exception.Message)"
        }
        return [PSCustomObject]@{
            Success = $false
            ElapsedSeconds = $elapsedTime
        }
    }
}
Function Get-SupervisorUpgradeInfo {

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

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterId
    )

    Write-LogMessage -Type DEBUG -Message "Entered Get-SupervisorUpgradeInfo function..."

    try {
        Write-LogMessage -Type DEBUG -Message "Querying available supervisor upgrade versions for cluster: $ClusterId"

        # Query all software clusters to find upgrade information for this cluster.
        $softwareClusters = Invoke-ListNamespaceManagementSoftwareClusters -ErrorAction Stop

        # Find the cluster matching our cluster ID.
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

        # Extract version information.
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

        # Return success result.
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

        # Return failure result.
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
Function Invoke-SupervisorUpgrade {

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

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterId,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DesiredVersion,
        [Parameter(Mandatory = $false)] [Switch]$IgnorePrecheckWarnings
    )

    Write-LogMessage -Type DEBUG -Message "Entered Invoke-SupervisorUpgrade function..."

    try {
        Write-LogMessage -Type INFO -Message "Initiating supervisor upgrade for cluster $ClusterId to version $DesiredVersion..."

        # Initialize upgrade specification (VCF PowerCLI 9.0 / 9.1 may expose NamespaceManagement or VcenterNamespaceManagement cmdlet names).
        # Convert Switch parameter to Boolean for the cmdlet.
        $ignorePrecheckWarningsBool = [bool]$IgnorePrecheckWarnings
        $upgradeSpecCmd = Get-VcfSdkInitializeCommand -NameCandidates @(
            "Initialize-NamespaceManagementSoftwareClustersUpgradeSpec",
            "Initialize-VcenterNamespaceManagementSoftwareClustersUpgradeSpec"
        )
        if ($null -eq $upgradeSpecCmd) {
            Write-LogMessage -Type ERROR -Message "Required cmdlet for supervisor upgrade spec was not found (Initialize-NamespaceManagementSoftwareClustersUpgradeSpec or Initialize-VcenterNamespaceManagementSoftwareClustersUpgradeSpec)."
            throw [VcfDeploymentException]::new("Required cmdlet for supervisor upgrade spec was not found (Initialize-NamespaceManagementSoftwareClustersUpgradeSpec or Initialize-VcenterNamespaceManagementSoftwareClustersUpgradeSpec).")
        }

        $upgradeSpec = & $upgradeSpecCmd -DesiredVersion $DesiredVersion -IgnorePrecheckWarnings $ignorePrecheckWarningsBool

        # Invoke the upgrade.
        Invoke-UpgradeCluster `
            -Cluster $ClusterId `
            -VcenterNamespaceManagementSoftwareClustersUpgradeSpec $upgradeSpec `
            -Confirm:$false `
            -ErrorAction Stop | Out-Null

        Write-LogMessage -Type INFO -Message "Supervisor upgrade initiated successfully for cluster $ClusterId to version $DesiredVersion."

        # Return success result.
        return [PSCustomObject]@{
            Success = $true
            ErrorMessage = $null
        }
    } catch {
        $errorMessage = $_.Exception.Message
        Write-LogMessage -Type ERROR -Message "Failed to initiate supervisor upgrade for cluster $ClusterId - $errorMessage"

        # Return failure result.
        return [PSCustomObject]@{
            Success = $false
            ErrorMessage = $errorMessage
        }
    }
}
Function Get-SupervisorUpgradeStatus {

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

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterId
    )

    Write-LogMessage -Type DEBUG -Message "Entered Get-SupervisorUpgradeStatus function..."

    try {
        Write-LogMessage -Type DEBUG -Message "Querying supervisor upgrade status for cluster: $ClusterId"

        # Query cluster-specific software information.
        # Note: The API may return invalid data (empty severity strings) in upgrade_prechecks,
        # causing deserialization errors. We catch and handle these gracefully.
        $clusterSoftware = Invoke-GetClusterNamespaceManagementSoftware -Cluster $ClusterId -ErrorAction Stop

        # Extract version information.
        $currentVersion = $clusterSoftware.CurrentVersion
        $desiredVersion = $clusterSoftware.UpgradeStatus.DesiredVersion
        $availableVersions = @()
        if ($clusterSoftware.AvailableVersions) {
            $availableVersions = $clusterSoftware.AvailableVersions
        }

        # Determine if upgrade is in progress.
        $isUpgrading = $false
        if ($desiredVersion -and $currentVersion -ne $desiredVersion) {
            $isUpgrading = $true
            Write-LogMessage -Type DEBUG -Message "Upgrade in progress - Current version $currentVersion, Desired version $desiredVersion"
        }

        # Extract upgrade progress information.
        $upgradeProgress = $clusterSoftware.UpgradeStatus.Progress
        $messages = [System.Collections.ArrayList]::new()
        if ($clusterSoftware.Messages) {
            if ($clusterSoftware.Messages -is [Array]) {
                $null = $messages.AddRange($clusterSoftware.Messages)
            } else {
                $null = $messages.Add($clusterSoftware.Messages)
            }
        }
        if ($clusterSoftware.UpgradeStatus.Messages) {
            if ($clusterSoftware.UpgradeStatus.Messages -is [Array]) {
                $null = $messages.AddRange($clusterSoftware.UpgradeStatus.Messages)
            } else {
                $null = $messages.Add($clusterSoftware.UpgradeStatus.Messages)
            }
        }

        # Return success result.
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

                    # Determine if upgrade is in progress.
                    $isUpgrading = $false
                    if ($desiredVersion -and $currentVersion -ne $desiredVersion) {
                        $isUpgrading = $true
                    }

                    # Return partial success result with available information.
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

        # Return failure result. For known API issues, use a simplified error message to avoid cluttering logs.
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
Function Wait-SupervisorUpgradeComplete {

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

    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(1, [int]::MaxValue)] [Int]$CheckInterval = 5,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterId,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DesiredVersion,
        [Parameter(Mandatory = $false)] [String]$SupervisorId,
        [Parameter(Mandatory = $false)] [ValidateRange(1, [int]::MaxValue)] [Int]$TotalWaitTime = 3600
    )

    Write-LogMessage -Type DEBUG -Message "Entered Wait-SupervisorUpgradeComplete function..."

    $elapsedTime = 0

    try {
        Write-LogMessage -Type INFO -Message "Waiting for supervisor upgrade to complete on cluster `"$ClusterName`" (timeout: $TotalWaitTime seconds)..."
        Write-LogMessage -Type INFO -Message "Target version: $DesiredVersion"

        do {
            # Query upgrade status.
            $upgradeStatus = Get-SupervisorUpgradeStatus -ClusterId $ClusterId

            if (-not $upgradeStatus.Success) {
                # Only log WARNING if it's not the known API deserialization issue (which is logged as DEBUG in Get-SupervisorUpgradeStatus).
                if ($upgradeStatus.ErrorMessage -notmatch "API deserialization error.*known issue") {
                    Write-LogMessage -Type WARNING -Message "Failed to query upgrade status: $($upgradeStatus.ErrorMessage). Retrying..."
                } else {
                    Write-LogMessage -Type DEBUG -Message "Known API deserialization issue detected. Retrying upgrade status query..."
                }
                Start-Sleep $CheckInterval
                $elapsedTime += $CheckInterval
                continue
            }

            # Check if upgrade is complete.
            $isComplete = ($upgradeStatus.CurrentVersion -eq $upgradeStatus.DesiredVersion) -and ($upgradeStatus.State -eq "READY")

            if ($isComplete) {
                Write-Progress -Activity "Waiting for supervisor upgrade to complete" -Status "Complete" -PercentComplete 100 -Completed
                [Console]::Out.Flush()
                Write-LogMessage -Type INFO -Message "Supervisor upgrade completed successfully on cluster `"$ClusterName`" in $elapsedTime seconds."
                Write-LogMessage -Type INFO -Message "Final version: $($upgradeStatus.CurrentVersion), State: $($upgradeStatus.State)"
                return [PSCustomObject]@{
                    Success = $true
                    ElapsedSeconds = $elapsedTime
                    FinalVersion = $upgradeStatus.CurrentVersion
                }
            }

            # Upgrade still in progress - show progress.
            $percentComplete = [Math]::Min(99, [int](($elapsedTime / $TotalWaitTime) * 100))
            $statusMessage = "Elapsed: $elapsedTime seconds - Current: $($upgradeStatus.CurrentVersion)"
            $currentOperation = "Desired: $($upgradeStatus.DesiredVersion) - State: $($upgradeStatus.State)"

            # Show upgrade progress if available.
            if ($upgradeStatus.UpgradeProgress) {
                $currentOperation += " - Progress: $($upgradeStatus.UpgradeProgress)"
            }

            Write-Progress -Activity "Waiting for supervisor upgrade to complete" -Status $statusMessage -CurrentOperation $currentOperation -PercentComplete $percentComplete
            [Console]::Out.Flush()

            # Status is shown via progress indicator above. No need for periodic INFO messages.

            Start-Sleep $CheckInterval
            $elapsedTime += $CheckInterval

        } while ($elapsedTime -lt $TotalWaitTime)

        # Timeout reached.
        Write-Progress -Activity "Waiting for supervisor upgrade to complete" -Status "Timeout" -Completed
        [Console]::Out.Flush()
        Write-LogMessage -Type ERROR -Message "Timeout waiting for supervisor upgrade to complete on cluster `"$ClusterName`" after $TotalWaitTime seconds ($elapsedTime seconds elapsed)."

        # Get final status for error reporting.
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
Function Get-SupervisorNetworkVanityDisplayName {

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
    #>

    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(1, 253)] [Int]$MaxTotalLength = 80,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$PortGroupName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VanityPrefix
    )

    $normalizedPrefix = $VanityPrefix.Trim().ToLowerInvariant()
    $combined = "${normalizedPrefix}${PortGroupName}"
    if ($combined.Length -gt $MaxTotalLength) {
        Write-LogMessage -Type ERROR -Message "Supervisor network vanity name exceeds max length $MaxTotalLength (prefix + port group name): $combined."
        throw [VcfDeploymentException]::new("Supervisor network vanity name exceeds max length $MaxTotalLength (prefix + port group name): $combined.")
    }

    return $combined
}
Function Get-ManagementNetworkConfig {

    <#
        .SYNOPSIS
        Extracts and validates management network configuration from supervisor specification.

        .DESCRIPTION
        Parses management network configuration from the supervisor component specification and resolves port group IDs. IP assignment mode is supplied by the caller (expected STATIC).

        .PARAMETER DisableSupervisorNetworkVanityPrefix
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

    Param (
        [Parameter(Mandatory = $false)] [Switch]$DisableSupervisorNetworkVanityPrefix,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Gateway,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$MgmtNetworkVanityPrefix = "tmn",
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [PSCustomObject]$Spec
    )

    Write-LogMessage -Type DEBUG -Message "Entered Get-ManagementNetworkConfig function..."

    try {
        $ipAssignmentMode = $Spec.mgmtIpAssignmentMode
        Write-LogMessage -Type DEBUG -Message "  IP assignment mode: $ipAssignmentMode"

        # Resolve port group ID.
        $networkName = $Spec.mgmtNetworkName
        Write-LogMessage -Type DEBUG -Message "  Resolving port group ID for management network: $networkName"
        $portgroupID = Get-PortGroupId -PortGroupName $networkName

        if ([string]::IsNullOrEmpty($portgroupID)) {
            Write-LogMessage -Type ERROR -Message "Failed to resolve port group ID for management network: $networkName."
            throw [VcfDeploymentException]::new("Failed to resolve port group ID for management network: $networkName.")
        }

        $displayName = if ($DisableSupervisorNetworkVanityPrefix) {
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
        Write-LogMessage -Type ERROR -Message "Failed to extract management network configuration: $($_.Exception.Message)"
        throw [VcfDeploymentException]::new("Failed to extract management network configuration: $($_.Exception.Message)")
    }
}
Function Get-WorkloadNetworkConfig {

    <#
        .SYNOPSIS
        Extracts and validates workload network configuration from supervisor specification.

        .DESCRIPTION
        Parses workload network configuration from the supervisor component specification and resolves port group IDs. IP assignment mode is supplied by the caller (expected STATIC).

        .PARAMETER DisableSupervisorNetworkVanityPrefix
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

    Param (
        [Parameter(Mandatory = $false)] [Switch]$DisableSupervisorNetworkVanityPrefix,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Gateway,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$PrimaryWorkloadNetworkVanityPrefix = "pwn",
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [PSCustomObject]$Spec
    )

    Write-LogMessage -Type DEBUG -Message "Entered Get-WorkloadNetworkConfig function..."

    try {
        $ipAssignmentMode = $Spec.primaryWorkloadIpAssignmentMode
        Write-LogMessage -Type DEBUG -Message "  IP assignment mode: $ipAssignmentMode."

        # Resolve port group ID.
        $networkName = $Spec.primaryWorkloadNetworkName
        Write-LogMessage -Type DEBUG -Message "  Resolving port group ID for workload network: $networkName."
        $portgroupID = Get-PortGroupId -PortGroupName $networkName

        if ([string]::IsNullOrEmpty($portgroupID)) {
            Write-LogMessage -Type ERROR -Message "Failed to resolve port group ID for workload network: $networkName."
            throw [VcfDeploymentException]::new("Failed to resolve port group ID for workload network: $networkName.")
        }

        $displayName = if ($DisableSupervisorNetworkVanityPrefix) {
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
        Write-LogMessage -Type ERROR -Message "Failed to extract workload network configuration: $($_.Exception.Message)"
        throw [VcfDeploymentException]::new("Failed to extract workload network configuration: $($_.Exception.Message)")
    }
}
Function Get-FLBNetworkConfig {

    <#
        .SYNOPSIS
        Extracts Foundation Load Balancer network configuration.

        .DESCRIPTION
        Parses FLB network configuration (management or virtual server network) and resolves port group IDs.

        .PARAMETER DisableSupervisorNetworkVanityPrefix
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

    Param (
        [Parameter(Mandatory = $false)] [Switch]$DisableSupervisorNetworkVanityPrefix,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Gateway,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [PSCustomObject]$NetworkSpec,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VanityPrefix
    )

    Write-LogMessage -Type DEBUG -Message "Entered Get-FLBNetworkConfig function..."

    try {
        # Resolve port group ID.
        $networkName = $NetworkSpec.flbNetworkName
        Write-LogMessage -Type DEBUG -Message "  Resolving port group ID for FLB network: $networkName"
        $portGroupID = Get-PortGroupId -PortGroupName $networkName

        if ([string]::IsNullOrEmpty($portGroupID)) {
            Write-LogMessage -Type ERROR -Message "Failed to resolve port group ID for FLB network: $networkName."
            throw [VcfDeploymentException]::new("Failed to resolve port group ID for FLB network: $networkName.")
        }

        $displayName = if ($DisableSupervisorNetworkVanityPrefix) {
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
        Write-LogMessage -Type ERROR -Message "Failed to extract FLB network configuration: $($_.Exception.Message)"
        throw [VcfDeploymentException]::new("Failed to extract FLB network configuration: $($_.Exception.Message)")
    }
}
Function Get-LoadBalancerConfig {

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

        .PARAMETER DisableSupervisorNetworkVanityPrefix
        When set, FLB API-facing network names match port group labels (legacy behavior).

        .OUTPUTS
        PSCustomObject with complete FLB configuration

        .EXAMPLE
        $flbConfig = Get-LoadBalancerConfig -Spec $supervisorDetails.supervisorComponentSpec.foundationLoadBalancerComponents -FlbMgmtNetworkGateway "10.30.11.1/24" -FlbVirtualServerNetworkGateway "10.30.12.1/24"
    #>

    Param (
        [Parameter(Mandatory = $false)] [Switch]$DisableSupervisorNetworkVanityPrefix,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$FlbManagementNetworkVanityPrefix = "fmn",
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$FlbMgmtNetworkGateway,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$FlbVirtualServerNetworkGateway,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$FlbVirtualServerNetworkVanityPrefix = "fvsn",
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [PSCustomObject]$Spec
    )

    Write-LogMessage -Type DEBUG -Message "Entered Get-LoadBalancerConfig function..."

    try {
        Write-LogMessage -Type DEBUG -Message "Extracting Foundation Load Balancer configuration..."

        # Extract management and virtual server network configurations (with gateways from infrastructure JSON).
        $mgmtNetwork = Get-FLBNetworkConfig -DisableSupervisorNetworkVanityPrefix:$DisableSupervisorNetworkVanityPrefix -Gateway $FlbMgmtNetworkGateway -NetworkSpec $Spec.flbManagementNetwork -VanityPrefix $FlbManagementNetworkVanityPrefix
        $vsNetwork = Get-FLBNetworkConfig -DisableSupervisorNetworkVanityPrefix:$DisableSupervisorNetworkVanityPrefix -Gateway $FlbVirtualServerNetworkGateway -NetworkSpec $Spec.flbVirtualServerNetwork -VanityPrefix $FlbVirtualServerNetworkVanityPrefix

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
        Write-LogMessage -Type ERROR -Message "Failed to extract Foundation Load Balancer configuration: $($_.Exception.Message)"
        throw [VcfDeploymentException]::new("Failed to extract Foundation Load Balancer configuration: $($_.Exception.Message)")
    }
}
Function Get-SupervisorConfigurationFromJson {

    <#
        .SYNOPSIS
        Parses supervisor JSON configuration into a structured configuration object.

        .DESCRIPTION
        Extracts and validates all supervisor configuration parameters from the input JSON file,
        returning a PSCustomObject with organized sections for control plane, networks, and FLB.
        This function delegates to specialized parsers for each configuration section.
        Merges commonSupervisorSpec (shared config) with siteSpec (site-specific config) based on edgeSite.

        .PARAMETER DisableSupervisorNetworkVanityPrefix
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

    Param (
        [Parameter(Mandatory = $false)] [Switch]$DisableSupervisorNetworkVanityPrefix,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EdgeSite,
        [Parameter(Mandatory = $false)] [ValidateSet("STATIC")] [String]$FlbNetworkIpAssignmentMode = "STATIC",
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$FlbMgmtNetworkPersona = "MANAGEMENT",
        [Parameter(Mandatory = $false)] [ValidateSet("VSPHERE_FOUNDATION")] [String]$FlbProvider = "VSPHERE_FOUNDATION",
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [Array]$FlbVirtualServerNetworkPersona = @("FRONTEND", "WORKLOAD"),
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$JsonFilePath,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Array]$NetworkSegments,
        [Parameter(Mandatory = $false)] [ValidateSet("STATIC")] [String]$MgmtIpAssignmentMode = "STATIC",
        [Parameter(Mandatory = $false)] [ValidateSet("STATIC")] [String]$PrimaryWorkloadIpAssignmentMode = "STATIC"
    )

    Write-LogMessage -Type DEBUG -Message "Entered Get-SupervisorConfigurationFromJson function..."

    try {
        Write-LogMessage -Type DEBUG -Message "Parsing supervisor configuration from JSON file..."

        # Parse JSON file.
        $supervisorDetails = ConvertFrom-JsonSafely -JsonFilePath $JsonFilePath

        if ($null -eq $supervisorDetails) {
            Write-LogMessage -Type ERROR -Message "Failed to parse JSON file or file is empty."
            throw [VcfDeploymentException]::new("Failed to parse JSON file or file is empty.")
        }

        # Extract common supervisor specification (shared config).
        Write-LogMessage -Type DEBUG -Message "Extracting common supervisor specification..."
        $commonSpec = $supervisorDetails.commonSupervisorSpec
        if (-not $commonSpec) {
            Write-LogMessage -Type ERROR -Message "commonSupervisorSpec not found in supervisor JSON"
            throw [VcfDeploymentException]::new("commonSupervisorSpec not found in supervisor JSON")
        }

        # Find matching site-specific specification by edgeSite.
        Write-LogMessage -Type DEBUG -Message "Finding matching site specification for edgeSite: $EdgeSite."
        $siteSpec = $supervisorDetails.siteSpec | Where-Object { $_.edgeSite -eq $EdgeSite } | Select-Object -First 1
        if (-not $siteSpec) {
            Write-LogMessage -Type ERROR -Message "No matching siteSpec found for edgeSite: $EdgeSite."
            throw [VcfDeploymentException]::new("No matching siteSpec found for edgeSite: $EdgeSite.")
        }

        # Build network name to gateway mapping from infrastructure JSON (case-sensitive).
        $networkGatewayMap = @{}
        foreach ($networkSegment in $NetworkSegments) {
            if ($networkSegment.name -and $networkSegment.gateway) {
                $networkGatewayMap[$networkSegment.name] = $networkSegment.gateway
            }
        }

        function Get-GatewayFromNetworkName {
            param([String]$NetworkName)
            if ($networkGatewayMap.ContainsKey($NetworkName)) {
                return $networkGatewayMap[$NetworkName]
            }
            Write-LogMessage -Type ERROR -Message "Gateway not found for network name: $NetworkName."
            throw [VcfDeploymentException]::new("Gateway not found for network name: $NetworkName.")
        }

        # Extract control plane configuration (from commonSupervisorSpec).
        Write-LogMessage -Type DEBUG -Message "Extracting control plane configuration..."
        $controlPlane = [PSCustomObject]@{
            VMCount = $commonSpec.controlPlaneVMCount
            Size = $commonSpec.controlPlaneSize
        }

        Write-LogMessage -Type DEBUG -Message "Extracting network configurations..."

        $mgmtNetworkName = $siteSpec.mgmtNetworkSpec.mgmtNetworkName
        $mgmtNetworkGateway = Get-GatewayFromNetworkName -NetworkName $mgmtNetworkName

        # Merge common and site-specific configs for management network.
        $mgmtNetworkSpec = [PSCustomObject]@{
            mgmtIpAssignmentMode = $MgmtIpAssignmentMode
            mgmtNetworkName = $siteSpec.mgmtNetworkSpec.mgmtNetworkName
            mgmtNetworkStartingIp = $siteSpec.mgmtNetworkSpec.mgmtNetworkStartingIp
            mgmtNetworkIPCount = $siteSpec.mgmtNetworkSpec.mgmtNetworkIPCount
            mgmtNetworkDnsServers = $commonSpec.dnsServers
            mgmtNetworkNtpServers = $commonSpec.networkNtpServers
            mgmtNetworkSearchDomains = $commonSpec.networkSearchDomains
        }
        $mgmtNetwork = Get-ManagementNetworkConfig -DisableSupervisorNetworkVanityPrefix:$DisableSupervisorNetworkVanityPrefix -Gateway $mgmtNetworkGateway -Spec $mgmtNetworkSpec

        $workloadNetworkName = $siteSpec.primaryWorkloadNetwork.primaryWorkloadNetworkName
        $workloadNetworkGateway = Get-GatewayFromNetworkName -NetworkName $workloadNetworkName

        # Merge common and site-specific configs for workload network.
        $workloadNetworkSpec = [PSCustomObject]@{
            primaryWorkloadIpAssignmentMode = $PrimaryWorkloadIpAssignmentMode
            primaryWorkloadNetworkName = $siteSpec.primaryWorkloadNetwork.primaryWorkloadNetworkName
            primaryWorkloadNetworkStartingIp = $siteSpec.primaryWorkloadNetwork.primaryWorkloadNetworkStartingIp
            primaryWorkloadNetworkIPCount = $siteSpec.primaryWorkloadNetwork.primaryWorkloadNetworkIPCount
            workloadDnsServers = $commonSpec.dnsServers
            workloadNtpServers = $commonSpec.networkNtpServers
            primaryWorkloadNetworkSearchDomains = $commonSpec.networkSearchDomains
            workloadServiceStartIp = $siteSpec.primaryWorkloadNetwork.workloadServiceStartIp
            workloadServiceCount = $siteSpec.primaryWorkloadNetwork.workloadServiceCount
        }
        $workloadNetwork = Get-WorkloadNetworkConfig -DisableSupervisorNetworkVanityPrefix:$DisableSupervisorNetworkVanityPrefix -Gateway $workloadNetworkGateway -Spec $workloadNetworkSpec

        $flbMgmtNetworkName = $siteSpec.foundationLoadBalancerComponents.flbManagementNetwork.flbNetworkName
        $flbMgmtNetworkGateway = Get-GatewayFromNetworkName -NetworkName $flbMgmtNetworkName
        $flbVsNetworkName = $siteSpec.foundationLoadBalancerComponents.flbVirtualServerNetwork.flbNetworkName
        $flbVsNetworkGateway = Get-GatewayFromNetworkName -NetworkName $flbVsNetworkName

        # Merge common and site-specific configs for FLB.
        $flbSpec = [PSCustomObject]@{
            flbName = $siteSpec.foundationLoadBalancerComponents.flbName
            flbSize = $commonSpec.flbSize
            flbAvailability = $commonSpec.flbAvailability
            flbVipStartIP = $siteSpec.foundationLoadBalancerComponents.flbVipStartIP
            flbVipIPCount = $siteSpec.foundationLoadBalancerComponents.flbVipIPCount
            flbProvider = $FlbProvider
            flbDnsServers = $commonSpec.dnsServers
            flbNtpServers = $commonSpec.networkNtpServers
            flbSearchDomains = $commonSpec.networkSearchDomains
            flbManagementNetwork = [PSCustomObject]@{
                flbNetworkIpAssignmentMode = $FlbNetworkIpAssignmentMode
                flbNetworkName = $siteSpec.foundationLoadBalancerComponents.flbManagementNetwork.flbNetworkName
                flbNetworkType = $commonSpec.flbNetworkType
                flbNetworkIpAddressStartingIp = $siteSpec.foundationLoadBalancerComponents.flbManagementNetwork.flbNetworkIpAddressStartingIp
                flbNetworkIpAddressCount = $siteSpec.foundationLoadBalancerComponents.flbManagementNetwork.flbNetworkIpAddressCount
                flbNetworkPersona = $FlbMgmtNetworkPersona
            }
            flbVirtualServerNetwork = [PSCustomObject]@{
                flbNetworkIpAssignmentMode = $FlbNetworkIpAssignmentMode
                flbNetworkName = $siteSpec.foundationLoadBalancerComponents.flbVirtualServerNetwork.flbNetworkName
                flbNetworkType = $commonSpec.flbNetworkType
                flbNetworkIpAddressStartingIp = $siteSpec.foundationLoadBalancerComponents.flbVirtualServerNetwork.flbNetworkIpAddressStartingIp
                flbNetworkIpAddressCount = $siteSpec.foundationLoadBalancerComponents.flbVirtualServerNetwork.flbNetworkIpAddressCount
                flbNetworkPersona = $FlbVirtualServerNetworkPersona
            }
        }
        $loadBalancer = Get-LoadBalancerConfig -DisableSupervisorNetworkVanityPrefix:$DisableSupervisorNetworkVanityPrefix -FlbMgmtNetworkGateway $flbMgmtNetworkGateway -FlbVirtualServerNetworkGateway $flbVsNetworkGateway -Spec $flbSpec

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
        Write-LogMessage -Type ERROR -Message "Failed to parse supervisor configuration from JSON: $($_.Exception.Message)"
        throw [VcfDeploymentException]::new("Failed to parse supervisor configuration from JSON: $($_.Exception.Message)")
    }
}
Function Test-SupervisorConfiguration {

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
            Write-LogMessage -Type ERROR -Message "Configuration validation failed."
            throw [VcfDeploymentException]::new("Configuration validation failed.")
        }

        .NOTES
        This function logs detailed information about validation failures to aid troubleshooting.
        All validation errors are logged but the function returns a simple boolean result.

        Validation Responsibilities:
        • Test-JsonNullValues: Null value checks (runs first during JSON validation)
        • Test-JsonDeeperValidation: Format, range, and business rule validation
        • Test-SupervisorConfiguration: Runtime structural validation (this function)
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSCustomObject]$Config,
        [Parameter(Mandatory = $false)] [ValidateRange(1, [int]::MaxValue)] [Int]$MinimumServiceCount = 16
    )

    Write-LogMessage -Type DEBUG -Message "Entered Test-SupervisorConfiguration function..."

    $validationPassed = $true

    try {
        Write-LogMessage -Type DEBUG -Message "Validating supervisor configuration..."

        # Validate management network configuration.
        # Note: Null value checks for management network properties are handled by Test-JsonNullValues
        if (-not $Config.ManagementNetwork) {
            Write-LogMessage -Type ERROR -Message "Validation failed: Management network configuration is missing."
            $validationPassed = $false
        } else {
            Write-LogMessage -Type DEBUG -Message "  Validating management network..."
            # Runtime validation passed - null value validation already performed by Test-JsonNullValues.

        }

        # Validate workload network configuration.
        # Note: Null value checks for workload network properties are handled by Test-JsonNullValues
        if (-not $Config.WorkloadNetwork) {
            Write-LogMessage -Type ERROR -Message "Validation failed: Workload network configuration is missing."
            $validationPassed = $false
        } else {
            Write-LogMessage -Type DEBUG -Message "  Validating workload network..."
            # Runtime validation passed - null value validation already performed by Test-JsonNullValues.

            # Note: Workload network IP count minimum (2) is validated in Test-JsonDeeperValidation

            if ($Config.WorkloadNetwork.ServiceCount -lt $MinimumServiceCount) {
                Write-LogMessage -Type WARNING -Message "    Workload network service count ($($Config.WorkloadNetwork.ServiceCount)) is low (recommended minimum $MinimumServiceCount)"
            }
        }

        # Validate control plane configuration.
        # Note: Control plane size and VM count are validated in Test-JsonDeeperValidation
        if (-not $Config.ControlPlane) {
            Write-LogMessage -Type ERROR -Message "Validation failed: Control plane configuration is missing."
            $validationPassed = $false
        } else {
            Write-LogMessage -Type DEBUG -Message "  Validating control plane..."
            # Runtime validation passed - JSON validation already checked size and VM count.

        }

        # Validate load balancer configuration.
        # Note: Load balancer availability mode is validated in Test-JsonDeeperValidation
        if (-not $Config.LoadBalancer) {
            Write-LogMessage -Type ERROR -Message "Validation failed: Load balancer configuration is missing."
            $validationPassed = $false
        } else {
            Write-LogMessage -Type DEBUG -Message "  Validating load balancer..."

            if (-not $Config.LoadBalancer.ManagementNetwork) {
                Write-LogMessage -Type ERROR -Message "    Load balancer management network is missing."
                $validationPassed = $false
            }
            # Note: FLB management network IP count minimum (2) is validated in Test-JsonDeeperValidation

            if (-not $Config.LoadBalancer.VirtualServerNetwork) {
                Write-LogMessage -Type ERROR -Message "    Load balancer virtual server network is missing."
                $validationPassed = $false
            }
            # Note: FLB virtual server network IP count minimum (2) is validated in Test-JsonDeeperValidation
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
Function New-SupervisorControlPlaneSpec {

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
        Write-LogMessage -Type ERROR -Message "Failed to build control plane specification: $($_.Exception.Message)"
        throw [VcfDeploymentException]::new("Failed to build control plane specification: $($_.Exception.Message)")
    }
}
Function New-SupervisorWorkloadSpec {

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
        Write-LogMessage -Type ERROR -Message "Failed to build workload network specification: $($_.Exception.Message)"
        throw [VcfDeploymentException]::new("Failed to build workload network specification: $($_.Exception.Message)")
    }
}
Function New-SupervisorLoadBalancerSpec {

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
    Param (
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$FlbMgmtNetworkPersona = "MANAGEMENT",
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [Array]$FlbWorkloadNetworkPersona = @("FRONTEND", "WORKLOAD"),
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

        # Build deployment target.
        $deploymentTarget = Initialize-VcenterNamespaceManagementNetworksEdgesFoundationDeploymentTarget `
            -StoragePolicy $StoragePolicyId `
            -DeploymentSize $LoadBalancerConfig.Size `
            -Availability $LoadBalancerConfig.Availability

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

        $mgmtNetworkInterface = Initialize-VcenterNamespaceManagementNetworksEdgesFoundationNetworkInterface `
            -Personas $mgmtPersonaArray `
            -Network $mgmtNetwork

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

        $vsNetworkInterface = Initialize-VcenterNamespaceManagementNetworksEdgesFoundationNetworkInterface `
            -Personas $workloadPersonaArray `
            -Network $vsNetwork

        $flbDns = Initialize-VcenterNamespaceManagementNetworksEdgesFoundationDNS `
            -Servers $LoadBalancerConfig.DNSServers `
            -SearchDomains $LoadBalancerConfig.SearchDomains

        $flbNtp = Initialize-VcenterNamespaceManagementNetworksEdgesFoundationNTP `
            -Servers $LoadBalancerConfig.NTPServers

        $networkServices = Initialize-VcenterNamespaceManagementNetworksEdgesFoundationNetworkServices `
            -Dns $flbDns `
            -Ntp $flbNtp

        # Build foundation configuration.
        $foundationConfig = Initialize-VcenterNamespaceManagementNetworksEdgesVsphereFoundationConfig `
            -DeploymentTarget $deploymentTarget `
            -Interfaces $mgmtNetworkInterface, $vsNetworkInterface `
            -NetworkServices $networkServices

        # Build VIP address range.
        $vipRange = Initialize-VcenterNamespaceManagementNetworksIPRange `
            -Address $LoadBalancerConfig.VipStartIP `
            -Count $LoadBalancerConfig.VipIPCount

        # Build edge specification.
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
        Write-LogMessage -Type ERROR -Message "Failed to build Foundation Load Balancer specification: $($_.Exception.Message)"
        throw [VcfDeploymentException]::new("Failed to build Foundation Load Balancer specification: $($_.Exception.Message)")
    }
}
Function Invoke-SupervisorCreation {

    <#
        .SYNOPSIS
        Invokes the VCF PowerCLI 9 API to create a supervisor on a compute cluster.

        .DESCRIPTION
        Wraps the Invoke-EnableOnComputeClusterClusterSupervisors cmdlet with proper error handling,
        JSON serialization, temporary file management, and idempotent behavior for existing supervisors.

        This function handles the complete API invocation workflow:
        • Serializes supervisor specification to JSON with proper depth and count conversion
        • Creates and manages temporary JSON files for API communication
        • Invokes the VCF PowerCLI 9 supervisor enablement cmdlet
        • Handles "already exists" scenarios by retrieving existing supervisor ID
        • Ensures proper cleanup of temporary files in all code paths
        • Provides structured result object with success status and supervisor ID

        Based on VCF PowerCLI 9 API patterns for supervisor enablement.

        .PARAMETER ClusterId
        vSphere cluster MoRef ID where supervisor will be enabled (e.g., "domain-c8").

        .PARAMETER ClusterName
        Human-readable cluster name for logging and error messages.

        .PARAMETER SupervisorName
        Name for the supervisor cluster. Used for both creation and existing supervisor lookup.

        .PARAMETER SupervisorSpec
        Complete supervisor specification object from Initialize-VcenterNamespaceManagementSupervisorsEnableOnComputeClusterSpec.
        This object must include control plane, and workloads.

        .PARAMETER VcenterCredential
        Optional PSCredential for REST when resolving an existing supervisor ID (used when supervisor already exists).
        Defaults to $Script:VcenterCredential when not supplied (standard deployment flow).

        .PARAMETER InsecureTls
        Switch to bypass SSL certificate validation for vCenter REST API connections.

        .OUTPUTS
        PSCustomObject with the following properties:
        • Success (Boolean): Indicates if operation succeeded
        • SupervisorId (String): Supervisor MoRef ID if successful, $null if failed
        • IsExisting (Boolean): $true if supervisor already existed, $false if newly created
        • ErrorMessage (String): Error details if Success is $false, $null if successful

        .EXAMPLE
        $result = Invoke-SupervisorCreation -ClusterId "domain-c8" -ClusterName "Cluster01" -SupervisorName "supervisor-01" -SupervisorSpec $spec -VcenterCredential $cred
        if ($result.Success) {
            Write-LogMessage -Type INFO -Message "Supervisor ID: $($result.SupervisorId)"
        }

        .EXAMPLE
        $result = Invoke-SupervisorCreation -ClusterId $ClusterId -ClusterName $ClusterName -SupervisorName $SupervisorName -SupervisorSpec $spec -VcenterCredential $cred -InsecureTls
        if ($result.IsExisting) {
            Write-LogMessage -Type INFO -Message "Using existing supervisor: $($result.SupervisorId)"
        }

        .NOTES
        VCF PowerCLI 9 Requirements:
        • Uses Invoke-EnableOnComputeClusterClusterSupervisors cmdlet
        • Requires JSON serialization with depth 10 for complex nested objects
        • Count properties must be converted to integers (PowerShell quirk)
        • Temporary JSON files are created in system temp directory with unique names

        Error Handling:
        • "already has Workloads enabled" error triggers existing supervisor lookup
        • Temporary files are cleaned up in finally block
        • Returns structured object instead of throwing exceptions
        • Follows script-wide pattern of using exit/return instead of throw

        When retrieving an existing supervisor ID, this function uses $Script:VCenterUser (set from input by the main deployment).
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterId,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [Switch]$InsecureTls,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSCustomObject]$SupervisorSpec,
        [Parameter(Mandatory = $false)] [PSCredential]$VcenterCredential
    )

    Write-LogMessage -Type DEBUG -Message "Entered Invoke-SupervisorCreation function..."
    # Initialize temporary file path variable for cleanup in finally block.
    $tempJsonPath = $null

    try {
        Write-LogMessage -Type DEBUG -Message "   Invoking supervisor creation on cluster `"$ClusterName`" (ID: $ClusterId)..."

        # Create temporary JSON file with timestamp to avoid collisions.
        $timestamp = Get-Date -Format 'yyyyMMddHHmmss'
        $tempPath = [System.IO.Path]::GetTempPath()
        $tempJsonPath = Join-Path $tempPath "supervisor_spec_${timestamp}.json"

        Write-LogMessage -Type DEBUG -Message "Serializing supervisor specification to JSON..."

        # Step 1: Serialize supervisor spec to JSON using VCF PowerCLI 9 ToJson() method.
        $SupervisorSpec.ToJson() | Set-Content -Path $tempJsonPath -Encoding UTF8

        # Step 2: Read back and convert to PSCustomObject for manipulation.
        $jsonFilePath = Get-Content -Path $tempJsonPath -Raw -Encoding UTF8
        $obj = $jsonFilePath | ConvertFrom-Json

        # Step 3: Convert count properties to integers (VCF PowerCLI 9 requirement).
        # PowerShell may serialize numeric properties as strings, but VCF API requires integers.
        Convert-CountToInt $obj

        # Step 4: Serialize back to JSON with proper depth for complex nested objects.
        $jsonFilePathPayload = $obj | ConvertTo-Json -Depth 10

        # Invoke the VCF PowerCLI 9 cmdlet to enable supervisor on cluster.
        $supervisorId = Invoke-EnableOnComputeClusterClusterSupervisors `
            -Cluster $ClusterId `
            -vcenterNamespaceManagementSupervisorsEnableOnComputeClusterSpec $jsonFilePathPayload `
            -Confirm:$false `
            -ErrorAction Stop

        Write-LogMessage -Type DEBUG -Message "Successfully initiated supervisor creation. Supervisor ID: $supervisorId"

        # Return success result with newly created supervisor ID.
        return [PSCustomObject]@{
            Success = $true
            SupervisorId = $supervisorId
            IsExisting = $false
            ErrorMessage = $null
        }
    } catch {
        $errorMessage = $_.Exception.Message
        Write-LogMessage -Type DEBUG -Message "Supervisor creation API full error: $errorMessage"

        # Handle "already has Workloads enabled" scenario (idempotent operation).
        if ($errorMessage -match "already has Workloads enabled") {
            Write-LogMessage -Type INFO -Message "Cluster `"$ClusterName`" already has supervisor enabled. Retrieving existing supervisor ID..."

            # Build parameters for Get-SupervisorId. Use script-scoped credential when set (main deployment flow).
            $effectiveCredential = if ($null -ne $Script:VcenterCredential) { $Script:VcenterCredential } else { $VcenterCredential }
            $getSupervisorParams = @{
                supervisorName = $SupervisorName
                VcenterUser = $Script:VCenterUser
                VcenterCredential = $effectiveCredential
                silence = $true
            }

            # Add InsecureTls if specified.
            if ($InsecureTls) {
                $getSupervisorParams.insecureTls = $true
            }

            # Attempt to retrieve existing supervisor ID.
            $existingSupervisorId = Get-SupervisorId @getSupervisorParams

            if ($existingSupervisorId) {
                Write-LogMessage -Type INFO -Message "Found existing supervisor with ID: $existingSupervisorId"

                # Return success result with existing supervisor ID.
                return [PSCustomObject]@{
                    Success = $true
                    SupervisorId = $existingSupervisorId
                    IsExisting = $true
                    ErrorMessage = $null
                }
            }
            else {
                Write-LogMessage -Type ERROR -Message "Failed to retrieve existing supervisor ID for `"$SupervisorName`""

                # Return failure result.
                return [PSCustomObject]@{
                    Success = $false
                    SupervisorId = $null
                    IsExisting = $false
                    ErrorMessage = "Failed to retrieve existing supervisor ID for `"$SupervisorName`""
                }
            }
        }
        else {
            # Unexpected error occurred - provide helpful context based on error type.

            # Extract clean error message from JSON error response.
            $cleanErrorMessage = Get-CleanErrorMessage -ErrorMessage $errorMessage

            # Check for creation failures.
            switch -Regex ($errorMessage) {
                "500.*Internal server error" {
                    Write-LogMessage -Type ERROR -Message "Failed to create supervisor on cluster `"$ClusterName`": vCenter API internal server error."
                    Write-LogMessage -Type ERROR -Message "Error details: $cleanErrorMessage."
                }
                "Foundation Load Balancer.*persona|persona.*Foundation" {
                    Write-LogMessage -Type ERROR -Message "Failed to create supervisor on cluster `"$ClusterName`": $cleanErrorMessage"
                    Write-LogMessage -Type ERROR -Message "FLB network interface persona error: the API expects uppercase persona values (e.g. MANAGEMENT for mgmt, FRONTEND and WORKLOAD for workload). Check VCF PowerCLI/vCenter docs for allowed values; ensure supervisor/infrastructure JSON FLB network names and port group IDs match existing DPGs."
                }
                default {
                    # Generic unexpected error - show clean message.
                    Write-LogMessage -Type ERROR -Message "Failed to create supervisor on cluster `"$ClusterName`": $cleanErrorMessage"
                }
            }

            # Return failure result with original error details for programmatic use.
            return [PSCustomObject]@{
                Success = $false
                SupervisorId = $null
                IsExisting = $false
                ErrorMessage = $errorMessage
            }
        }
    }
    finally {
        # Cleanup temporary JSON file in all code paths (success, failure, existing).
        if ($tempJsonPath -and (Test-Path $tempJsonPath)) {
            Write-LogMessage -Type DEBUG -Message "Cleaning up temporary JSON file: $tempJsonPath."
            Remove-Item -Path $tempJsonPath -Force -ErrorAction SilentlyContinue
        }
    }
}
Function Get-VlcmDesiredBaseImageVersionFromSpec {

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
        Caller can use the returned version with [version]::TryParse for comparison. Used by
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
            return [string]$baseImage.Version
        }
    }

    # Fallback: parse "BaseImage: Version: <value>" from string representation.
    $specStr = $spec.ToString()
    if (-not [String]::IsNullOrWhiteSpace($specStr) -and $specStr -match 'BaseImage:\s*Version:\s*([^,\s]+)') {
        return $Matches[1].Trim()
    }

    return $null
}
Function Invoke-VlcmClusterComplianceAndRemediate {

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
    #>

    Param (
        [Parameter(Mandatory = $false)] [Switch]$AcceptBadCheckResults,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName
    )

    Write-LogMessage -Type DEBUG -Message "Entered Invoke-VlcmClusterComplianceAndRemediate for cluster `"$ClusterName`"."

    $clusterObject = Get-Cluster -Name $ClusterName -Server $Script:vCenterName -ErrorAction SilentlyContinue
    if (-not $clusterObject) {
        Write-LogMessage -Type ERROR -Message "Cluster `"$ClusterName`" not found. Cannot check vLCM compliance."
        throw [VcfDeploymentException]::new("Cluster `"$ClusterName`" not found. Cannot check vLCM compliance.")
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
    $nonCompliantCount = $nonCompliantHosts.Count
    $nonCompliantHostNames = @()
    $index = 0
    # Resolve a display name for each non-compliant host. vLCM/API may expose Host, VMHost, Entity, Name, or HostName; use first available non-empty value so logs list host names instead of indices only.
    foreach ($item in $nonCompliantHosts) {
        $index++
        $displayName = $null
        if ($null -ne $item) {
            $displayName = switch ($true) {
                { $item.PSObject.Properties['Host'] -and $null -ne $item.Host -and -not [String]::IsNullOrWhiteSpace($item.Host.Name) } { $item.Host.Name }
                { $item.PSObject.Properties['VMHost'] -and $null -ne $item.VMHost -and -not [String]::IsNullOrWhiteSpace($item.VMHost.Name) } { $item.VMHost.Name }
                { $item.PSObject.Properties['Entity'] -and $null -ne $item.Entity -and -not [String]::IsNullOrWhiteSpace($item.Entity.Name) } { $item.Entity.Name }
                { $item.PSObject.Properties['Name'] -and -not [String]::IsNullOrWhiteSpace($item.Name) } { $item.Name }
                { $item.PSObject.Properties['HostName'] -and -not [String]::IsNullOrWhiteSpace($item.HostName) } { $item.HostName }
                default { $null }
            }
            if ([String]::IsNullOrWhiteSpace($displayName) -or $displayName -match '^\s*Vmware\.') {
                $displayName = "Host $index"
            }
        } else {
            $displayName = "Host $index"
        }
        if (-not [String]::IsNullOrWhiteSpace($displayName)) {
            $nonCompliantHostNames += $displayName
        }
    }
    $hostNamesStr = if ($nonCompliantHostNames.Count -gt 0) { $nonCompliantHostNames -join ", " } else { "($nonCompliantCount host(s))" }
    Write-LogMessage -Type INFO -Message "Cluster `"$ClusterName`" is not compliant to the vLCM image (Status: $($complianceResult.Status); NonCompliantHosts: $nonCompliantCount - $hostNamesStr). Remediating..."

    # Warn when the vLCM desired base image version differs from a host's current ESX version (upgrade or downgrade).
    # In VCF PowerCLI 9, Get-Cluster returns the desired image on .BaseImage.Version (Broadcom: "Creating and Managing vLCM Clusters with VCF PowerCLI").
    $baseImageVersion = $null
    $hasBaseImage = $clusterObject.PSObject.Properties['BaseImage'] -and $null -ne $clusterObject.BaseImage
    $hasBaseImageVersion = $hasBaseImage -and $clusterObject.BaseImage.PSObject.Properties['Version'] -and -not [String]::IsNullOrWhiteSpace($clusterObject.BaseImage.Version)
    if ($hasBaseImageVersion) {
        $baseImageVersion = [string]$clusterObject.BaseImage.Version
    }

    if (-not [String]::IsNullOrWhiteSpace($baseImageVersion)) {
        foreach ($item in $nonCompliantHosts) {
            $displayName = $null
            $vmHost = $null

            # Resolve host display name and VMHost from compliance item (API may expose Host, VMHost, Entity, Name, or HostName).
            if ($null -ne $item) {
                $displayName = switch ($true) {
                    { $item.PSObject.Properties['Host'] -and $null -ne $item.Host -and -not [String]::IsNullOrWhiteSpace($item.Host.Name) } { $item.Host.Name }
                    { $item.PSObject.Properties['VMHost'] -and $null -ne $item.VMHost -and -not [String]::IsNullOrWhiteSpace($item.VMHost.Name) } { $item.VMHost.Name }
                    { $item.PSObject.Properties['Entity'] -and $null -ne $item.Entity -and -not [String]::IsNullOrWhiteSpace($item.Entity.Name) } { $item.Entity.Name }
                    { $item.PSObject.Properties['Name'] -and -not [String]::IsNullOrWhiteSpace($item.Name) } { $item.Name }
                    { $item.PSObject.Properties['HostName'] -and -not [String]::IsNullOrWhiteSpace($item.HostName) } { $item.HostName }
                    default { $null }
                }
                if ($item.PSObject.Properties['Host'] -and $null -ne $item.Host) { $vmHost = $item.Host }
                elseif ($item.PSObject.Properties['VMHost'] -and $null -ne $item.VMHost) { $vmHost = $item.VMHost }
            }

            if ([String]::IsNullOrWhiteSpace($displayName)) { continue }
            if (-not $vmHost) {
                $vmHost = Get-VMHost -Name $displayName -Server $Script:vCenterName -ErrorAction SilentlyContinue
            }
            if (-not $vmHost) { continue }

            # Get host ESX version and build for full comparison to vLCM image (e.g. 9.0.0.0.12345678). Same sources as Set-VsanWitness.
            $hostVersion = $null
            $hostBuild = $null
            if ($vmHost.PSObject.Properties['Version'] -and -not [String]::IsNullOrWhiteSpace($vmHost.Version)) {
                $hostVersion = [string]$vmHost.Version
            }
            if ([String]::IsNullOrWhiteSpace($hostVersion) -and $vmHost.ExtensionData -and $vmHost.ExtensionData.Config -and $vmHost.ExtensionData.Config.Product -and -not [String]::IsNullOrWhiteSpace($vmHost.ExtensionData.Config.Product.Version)) {
                $hostVersion = [string]$vmHost.ExtensionData.Config.Product.Version
            }
            if ($vmHost.PSObject.Properties['Build'] -and -not [String]::IsNullOrWhiteSpace($vmHost.Build)) {
                $hostBuild = [string]$vmHost.Build
            }
            if ([String]::IsNullOrWhiteSpace($hostBuild) -and $vmHost.ExtensionData -and $vmHost.ExtensionData.Config -and $vmHost.ExtensionData.Config.Product -and -not [String]::IsNullOrWhiteSpace($vmHost.ExtensionData.Config.Product.Build)) {
                $hostBuild = [string]$vmHost.ExtensionData.Config.Product.Build
            }

            if ([String]::IsNullOrWhiteSpace($hostVersion)) { continue }

            # Build full host version string (e.g. 9.0.0.0.12345678) to match vLCM base image format. Use Version + ".0." + Build when Version has 3 components.
            $fullHostVersion = $hostVersion
            $hostParts = $hostVersion.Trim() -split '\.'
            if ($hostParts.Count -eq 3 -and -not [String]::IsNullOrWhiteSpace($hostBuild)) {
                $fullHostVersion = "$hostVersion.0.$hostBuild"
            } elseif ($hostParts.Count -ge 4) {
                $fullHostVersion = $hostVersion
            }

            if ($fullHostVersion -eq $baseImageVersion) { continue }
            if ($hostVersion -eq $baseImageVersion) { continue }

            # Determine whether this is an upgrade, downgrade, or unparseable version mismatch (using first 3 components for comparison).
            $direction = "version mismatch"
            $imageParts = $baseImageVersion.Trim() -split '\.'
            $normalizedImage = if ($imageParts.Count -ge 3) { ($imageParts[0..2] -join '.') } else { $baseImageVersion }
            $normalizedHost = if ($hostParts.Count -ge 3) { ($hostParts[0..2] -join '.') } else { $hostVersion }
            $baseVer = $null
            $hostVer = $null
            if ([version]::TryParse($normalizedImage, [ref]$baseVer) -and [version]::TryParse($normalizedHost, [ref]$hostVer)) {
                if ($baseVer -gt $hostVer) { $direction = "upgrade" }
                elseif ($baseVer -lt $hostVer) { $direction = "downgrade" }
            }

            Write-LogMessage -Type WARNING -Message "vLCM image base version differs from host ESX version. Host: `"$displayName`". Current ESX version: $fullHostVersion. vLCM image base version: $baseImageVersion. This is an $direction."
        }
    }

    Write-LogMessage -Type INFO -Message "Running vLCM remediation for cluster `"$ClusterName`"."
    try {
        $clusterObject | Set-Cluster -Remediate -AcceptEULA -Confirm:$false -Server $Script:vCenterName -ErrorAction Stop | Out-Null
        Write-LogMessage -Type INFO -Message "vLCM remediation completed for cluster `"$ClusterName`"."
        # Report if a reboot is required or if still non-compliant after remediation.
        $postRemediationCompliance = $null
        try {
            $postRemediationCompliance = $clusterObject | Test-LcmClusterCompliance -ErrorAction SilentlyContinue
        } catch {
            Write-LogMessage -Type DEBUG -Message "Could not re-check vLCM compliance after remediation: $($_.Exception.GetType().FullName): $($_.Exception.Message)."
        }
        if ($postRemediationCompliance) {
            $stillNonCompliant = $postRemediationCompliance.PSObject.Properties['Status'] -and $postRemediationCompliance.Status -ne 'Compliant'
            if ($stillNonCompliant) {
                Write-LogMessage -Type WARNING -Message "Cluster `"$ClusterName`" is still not compliant to the vLCM image after remediation (Status: $($postRemediationCompliance.Status)). Check vCenter Lifecycle Manager and reboot hosts if required."
            }
            $rebootRequired = $false
            if ($postRemediationCompliance.PSObject.Properties['Impact'] -and -not [string]::IsNullOrWhiteSpace($postRemediationCompliance.Impact) -and $postRemediationCompliance.Impact -match 'Reboot|reboot') {
                $rebootRequired = $true
            }
            if ($postRemediationCompliance.PSObject.Properties['RebootRequired'] -and $postRemediationCompliance.RebootRequired -eq $true) {
                $rebootRequired = $true
            }
            if ($rebootRequired) {
                Write-LogMessage -Type INFO -Message "A reboot is required on one or more hosts in cluster `"$ClusterName`" to complete vLCM remediation. Check vCenter Lifecycle Manager (cluster image compliance) for host status and reboot when appropriate."
            }
        }
    } catch {
        $remediationError = $_.Exception.Message
        $failedHost = $null
        if ($remediationError -match "Health Check for '([^']+)' failed") {
            $failedHost = $Matches[1]
        }
        if ($failedHost) {
            Write-LogMessage -Type ERROR -Message "vLCM remediation failed for cluster `"$ClusterName`": Health Check for '$failedHost' failed. Check that host in vCenter (Lifecycle Manager / cluster image compliance) and resolve pre-remediation issues, then re-run or proceed at your own risk."
        } else {
            Write-LogMessage -Type ERROR -Message "vLCM remediation failed for cluster `"$ClusterName`": $remediationError"
        }
        Write-LogMessage -Type DEBUG -Message "vLCM remediation full error: $remediationError"
        switch -Regex ($remediationError) {
            "Health Check for '([^']+)' failed" {
                $summary = "Health Check for '$($Matches[1])' failed."
                break
            }
            "'default_message':\s*([^,}]+)" {
                $summary = $Matches[1].Trim()
                break
            }
            default {
                $summary = $remediationError
            }
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
                Write-LogMessage -Type ERROR -Message "Deployment failed. Cluster must be compliant to the vLCM image before supervisor creation. vLCM reported: $summary"
                throw [VcfDeploymentException]::new("Deployment failed. Cluster must be compliant to the vLCM image before supervisor creation. vLCM reported: $summary")
            }
            Write-LogMessage -Type WARNING -Message "Invalid response. Please enter Y or N."
        } while ($true)
    }
}
Function Add-Supervisor {

    <#
        .SYNOPSIS
        Creates a new vSphere Supervisor cluster with comprehensive configuration and monitoring, or retrieves an existing supervisor ID.

        .DESCRIPTION
        The Add-Supervisor function deploys a new vSphere Supervisor cluster on a specified vSphere cluster
        using the provided JSON configuration. This function handles the complete supervisor deployment process
        including configuration validation, supervisor creation, status monitoring with progress tracking, and
        intelligent handling of pre-existing supervisors.

        The function performs the following operations:
        1. Loads and validates the supervisor configuration from the provided JSON file
        2. Extracts supervisor specifications including control plane settings, and network configurations
        3. Parses network settings for management, workload, and Foundation Load Balancer (FLB) components
        4. Configures control plane VMs with specified size, count, and storage policy
        5. Sets up network management with DHCP or static IP allocation based on configuration
        6. Deploys Foundation Load Balancer with management and virtual server networks
        7. Attempts to create the supervisor cluster using the vSphere Namespace Management API
        8. If supervisor already exists on the cluster, retrieves the existing supervisor ID instead
        9. Monitors the supervisor deployment progress with a comprehensive progress indicator
        10. Waits for both ConfigStatus (RUNNING) and KubernetesStatus (READY) before completion
        11. Provides detailed logging throughout the deployment process

        The function includes intelligent error handling:
        - If a supervisor already exists on the cluster, it retrieves and returns the existing supervisor ID
        - Uses Get-SupervisorId to query for existing supervisors with optional TLS certificate validation bypass
        - Exits with code 1 if supervisor creation fails for reasons other than pre-existence
        - Provides timeout protection with configurable wait time and check intervals

        Progress tracking includes elapsed time, current status information, and Kubernetes readiness state.
        The monitoring phase uses configurable timeout and check interval parameters to provide flexible
        control over the waiting period.

        .PARAMETER InfrastructureJson
        Specifies the full path to the JSON configuration file containing supervisor deployment details.
        This file must contain all required supervisor specifications including control plane
        configuration, network settings, and supervisor component specifications. The JSON structure must match
        the expected supervisor configuration schema.

        .PARAMETER StoragePolicyId
        Specifies the unique identifier of the vSphere storage policy to be used for the supervisor cluster.
        This storage policy will be applied to supervisor control plane VMs and determines the storage
        characteristics and placement rules for supervisor components.

        .PARAMETER ClusterId
        Specifies the unique identifier of the vSphere cluster where the supervisor will be deployed.
        This cluster must be properly configured with distributed switches, storage policies, and
        appropriate resource allocations before supervisor deployment.

        .PARAMETER ClusterName
        Specifies the name of the vSphere cluster for logging and identification purposes.
        This parameter is used primarily for enhanced logging messages and progress tracking
        to provide clear context about which cluster is being configured.

        .PARAMETER DisableSupervisorNetworkVanityPrefix
        When set, passes through to Get-SupervisorConfigurationFromJson so WCP API network vanity names match distributed port group labels (legacy behavior).

        .PARAMETER TotalWaitTime
        Specifies the maximum time in seconds to wait for the supervisor to become ready.
        The function will monitor supervisor status and wait for both ConfigStatus (RUNNING)
        and KubernetesStatus (READY) before completion. Default value is 3600 seconds (1 hour).
        If the supervisor does not become ready within this time, the function throws a terminating error.

        .PARAMETER CheckInterval
        Specifies the interval in seconds between status checks while waiting for the supervisor
        to become ready. The function will check supervisor status every CheckInterval seconds
        during the monitoring phase. Default value is 5 seconds. Shorter intervals provide
        more frequent updates but may increase API load, while longer intervals reduce API calls
        but provide less frequent progress updates.

        .PARAMETER InsecureTls
        Optional switch parameter that bypasses SSL certificate validation for vCenter REST API connections.
        When specified, the function will pass this flag to Get-SupervisorId when checking for existing
        supervisors, which disables SSL certificate validation for all REST API calls to vCenter.

        This parameter is useful in development and lab environments where:
        - Self-signed certificates are in use
        - Certificate chains are not properly configured
        - Certificate names don't match the vCenter FQDN

        When omitted, certificate validation follows vCenter and PowerCLI defaults.

        .PARAMETER SingleSite
        When set, the rollback prompt on supervisor timeout shows only Y/N (no A=always), since there is no next site.

        .EXAMPLE
        Add-Supervisor -infrastructureJson "./config/supervisor.json" -storagePolicyId "aa6d5a82-1c88-45da-85d3-3d74b91a5bad" -clusterId "domain-c8" -clusterName "cl02"

        Creates a new supervisor on cluster "cl02" using the configuration from supervisor.json
        with the specified storage policy and cluster identifiers. Uses default timeout of 3600 seconds
        and check interval of 15 seconds. SSL certificate validation is enforced (secure default).

        .EXAMPLE
        $supervisorId = Add-Supervisor -ClusterId $ClusterId -ClusterName $ClusterName -InfrastructureJson $SupervisorJson -StoragePolicyId $policyId -VcenterCredential $cred

        Creates a supervisor and captures the returned supervisor ID for use in subsequent operations
        such as namespace creation or ArgoCD deployment. Includes vCenter credential to handle cases where
        a supervisor already exists on the cluster. If supervisor exists, retrieves and returns its ID.

        .EXAMPLE
        Add-Supervisor -CheckInterval 30 -ClusterId "domain-c8" -ClusterName "cl02" -InfrastructureJson "./config/supervisor.json" -StoragePolicyId "aa6d5a82-1c88-45da-85d3-3d74b91a5bad" -TotalWaitTime 7200

        Creates a new supervisor with custom timeout of 7200 seconds (2 hours) and check interval of 30 seconds.
        This is useful for larger deployments that may take longer to become ready or when you want less
        frequent status updates to reduce API load.

        .EXAMPLE
        $supervisorId = Add-Supervisor -ClusterId $ClusterId -ClusterName $ClusterName -InfrastructureJson $SupervisorJson -InsecureTls -StoragePolicyId $policyId -VcenterCredential $cred

        Creates a supervisor in a lab environment with SSL certificate validation bypassed. The -InsecureTls
        flag is passed to Get-SupervisorId when checking for existing supervisors. This is useful for
        development environments with self-signed certificates but should NOT be used in production.

        .EXAMPLE
        try {
            $supervisorId = Add-Supervisor -ClusterId $cluster -ClusterName $name -InfrastructureJson $config -StoragePolicyId $policy -VcenterCredential $cred
        } catch {
            Write-LogMessage -Type ERROR -Message "Failed to create supervisor: $($_.Exception.Message)"
        }

        Demonstrates proper error handling when creating a supervisor. The function returns the supervisor ID
        whether it creates a new one or retrieves an existing one, making it safe to call repeatedly.

        .OUTPUTS
        System.String
        Returns the unique identifier (ID) of the successfully created or retrieved supervisor cluster.
        The ID format is typically "domain-cNNN" where NNN is a numeric identifier (e.g., "domain-c8").
        This ID can be used for subsequent operations such as creating namespaces, deploying services,
        or configuring ArgoCD instances.

        .NOTES
        Prerequisites:
        - Requires vSphere 7.0 U1 or later with vSphere with Tanzu enabled
        - The target cluster must have distributed switches properly configured
        - Storage policies must be created and associated with appropriate datastores
        - Network port groups must exist for management, workload, and FLB networks
        - Sufficient cluster resources (CPU, memory, storage) for supervisor control plane VMs
        - PowerCLI module VMware.VimAutomation.Core must be loaded

        Behavior:
        - Function uses script-scoped variables for vCenter connection details ($Script:vCenterName, $Script:VCenterUser)
        - Progress monitoring uses a do-while loop with configurable timeout (default 3600 seconds/1 hour)
        - Status checks occur at configurable intervals (default 5 seconds) during the monitoring phase
        - Idempotent: If supervisor already exists, retrieves and returns existing supervisor ID
        - Throws a terminating error if supervisor creation fails (except for pre-existence, which is idempotent)
        - All operations are logged using Write-LogMessage for consistent logging format
        - Temporary JSON files are created in the system temp directory and cleaned up automatically

        Performance Considerations:
        - Timeout and check interval parameters allow customization of monitoring behavior
        - Shorter check intervals provide more frequent updates but may increase API load
        - Longer timeouts are useful for large deployments that may take longer to become ready
        - Initial supervisor creation typically takes 15-30 minutes depending on environment
        - Existing supervisor ID retrieval typically completes in under 10 seconds

        .LINK
        Get-SupervisorId
        Get-OrCreateSupervisor
        Invoke-EnableOnComputeClusterClusterSupervisors
        Invoke-GetSupervisorNamespaceManagementSummary
        Add-ArgoCDNamespace
    #>

    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(1, [int]::MaxValue)] [Int]$CheckInterval=5,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterId,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [Switch]$DisableSupervisorNetworkVanityPrefix,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EdgeSite,
        [Parameter(Mandatory = $false)] [ValidateSet("STATIC")] [String]$FlbNetworkIpAssignmentMode="STATIC",
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$FlbMgmtNetworkPersona = "MANAGEMENT",
        [Parameter(Mandatory = $false)] [ValidateSet("VSPHERE_FOUNDATION")] [String]$FlbProvider="VSPHERE_FOUNDATION",
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [Array]$FlbWorkloadNetworkPersona=@("FRONTEND", "WORKLOAD"),
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$InfrastructureJson,
        [Parameter(Mandatory = $false)] [Switch]$InsecureTls,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Array]$NetworkSegments,
        [Parameter(Mandatory = $false)] [Switch]$SingleSite,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$StoragePolicyId,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorName,
        [Parameter(Mandatory = $false)] [ValidateSet("STATIC")] [String]$MgmtIpAssignmentMode="STATIC",
        [Parameter(Mandatory = $false)] [ValidateSet("STATIC")] [String]$PrimaryWorkloadIpAssignmentMode="STATIC",
        [Parameter(Mandatory = $false)] [ValidateRange(1, [int]::MaxValue)] [Int]$TotalWaitTime=3600,
        [Parameter(Mandatory = $false)] [PSCredential]$VcenterCredential
    )

    Write-LogMessage -Type DEBUG -Message "Entered Add-Supervisor function..."

    Write-LogMessage -Type INFO -Message "Beginning Supervisor deployment to cluster `"$ClusterName`"..."

    try {
        # ========================================================================
        # STEP 1: Parse Configuration from JSON.
        # ========================================================================
        Write-Progress -Activity "Supervisor Deployment" -Status "Parsing configuration from JSON..." -PercentComplete 10
        Write-LogMessage -Type DEBUG -Message "[Step 1/5] Parsing supervisor configuration from JSON..."
        $config = Get-SupervisorConfigurationFromJson -DisableSupervisorNetworkVanityPrefix:$DisableSupervisorNetworkVanityPrefix -EdgeSite $EdgeSite -FlbNetworkIpAssignmentMode $FlbNetworkIpAssignmentMode -FlbMgmtNetworkPersona $FlbMgmtNetworkPersona -FlbProvider $FlbProvider -FlbVirtualServerNetworkPersona $FlbWorkloadNetworkPersona -JsonFilePath $InfrastructureJson -NetworkSegments $NetworkSegments -MgmtIpAssignmentMode $MgmtIpAssignmentMode -PrimaryWorkloadIpAssignmentMode $PrimaryWorkloadIpAssignmentMode

        # Validate configuration before proceeding.
        if (-not (Test-SupervisorConfiguration -Config $config)) {
            Write-LogMessage -Type ERROR -Message "Supervisor configuration validation failed."
            throw [VcfDeploymentException]::new("Supervisor configuration validation failed.")
        }

        # ========================================================================
        # STEP 2: Build VCF PowerCLI 9 Specifications.
        # ========================================================================
        Write-Progress -Activity "Supervisor Deployment" -Status "Building Supervisor specifications..." -PercentComplete 30
        Write-LogMessage -Type DEBUG -Message "[Step 2/5] Building Supervisor specifications..."

        $controlPlaneParams = @{
            ControlPlaneConfig = $config.ControlPlane
            ManagementNetworkConfig = $config.ManagementNetwork
            StoragePolicyId = $StoragePolicyId
        }
        $controlPlaneSpec = New-SupervisorControlPlaneSpec @controlPlaneParams

        $workloadNetworkParams = @{
            WorkloadNetworkConfig = $config.WorkloadNetwork
        }
        $workloadNetworkSpec = New-SupervisorWorkloadSpec @workloadNetworkParams

        $loadBalancerParams = @{
            LoadBalancerConfig = $config.LoadBalancer
            StoragePolicyId = $StoragePolicyId
            FlbMgmtNetworkPersona = $FlbMgmtNetworkPersona
            FlbWorkloadNetworkPersona = $FlbWorkloadNetworkPersona
        }
        $edgeSpec = New-SupervisorLoadBalancerSpec @loadBalancerParams

        # ========================================================================
        # STEP 3: Assemble Complete Supervisor Specification.
        # ========================================================================
        Write-Progress -Activity "Supervisor Deployment" -Status "Assembling complete supervisor specification..." -PercentComplete 50
        Write-LogMessage -Type DEBUG -Message "[Step 3/5] Assembling complete supervisor specification..."

        $kubeApiServerOptions = Initialize-VcenterNamespaceManagementSupervisorsKubeAPIServerOptions
        $workloadsSpec = Initialize-VcenterNamespaceManagementSupervisorsWorkloads `
            -Network $workloadNetworkSpec `
            -Edge $edgeSpec `
            -KubeApiServerOptions $kubeApiServerOptions
        $supervisorSpec = Initialize-VcenterNamespaceManagementSupervisorsEnableOnComputeClusterSpec `
            -Name $SupervisorName `
            -ControlPlane $controlPlaneSpec `
            -Workloads $workloadsSpec

        # ========================================================================
        # STEP 4: Invoke Supervisor Creation.
        # ========================================================================
        Write-Progress -Activity "Supervisor Deployment" -Status "Invoking supervisor creation API..." -PercentComplete 70
        Write-LogMessage -Type DEBUG -Message "[Step 4/5] Invoking supervisor creation API..."

        $creationParams = @{
            ClusterId = $ClusterId
            ClusterName = $ClusterName
            SupervisorName = $SupervisorName
            SupervisorSpec = $supervisorSpec
            VcenterCredential = $VcenterCredential
            InsecureTls = $InsecureTls
        }
        $creationResult = Invoke-SupervisorCreation @creationParams

        # Check if creation was successful.
        if (-not $creationResult.Success) {
            # Extract clean error message from the API response.

            $errorMsg = $creationResult.ErrorMessage

            # Extract clean error message from JSON error response.
            $cleanError = Get-CleanErrorMessage -ErrorMessage $errorMsg
            Write-LogMessage -Type ERROR -Message "Supervisor creation failed: $cleanError."
            throw [VcfDeploymentException]::new("Supervisor creation failed: $cleanError.")
        }

        $supervisorId = $creationResult.SupervisorId
        Write-LogMessage -Type DEBUG -Message "[Step 4/5] Supervisor API invocation completed. ID: $supervisorId"

        # If supervisor already existed, skip waiting and return immediately.
        if ($creationResult.IsExisting) {
            Write-LogMessage -Type DEBUG -Message "[Step 5/5] Supervisor already exists, skipping status monitoring."
            Write-LogMessage -Type INFO -Message "Using existing supervisor ID: $supervisorId."
            return $supervisorId
        }

        # ========================================================================
        # STEP 5: Monitor Supervisor Deployment Status.
        # ========================================================================
        # Clear any lingering progress bar (vLCM task uses "Task created by VMware vSphere Lifecycle Manager") before showing our status so only one progress bar is visible.
        Write-Progress -Activity "Task created by VMware vSphere Lifecycle Manager" -Completed
        Write-Progress -Activity "Supervisor Deployment" -Completed
        Write-Progress -Activity "Supervisor Deployment" -Status "Monitoring supervisor deployment status..." -PercentComplete 85
        [Console]::Out.Flush()
        Write-LogMessage -Type DEBUG -Message "[Step 5/5] Monitoring supervisor deployment status..."

        # Monitor supervisor readiness using parameter splatting.
        $waitParams = @{
            supervisorId = $supervisorId
            clusterName = $ClusterName
            checkInterval = $CheckInterval
            totalWaitTime = $TotalWaitTime
        }
        $waitResult = Wait-SupervisorReady @waitParams

        if (-not $waitResult.Success) {
            Write-LogMessage -Type ERROR -Message "Supervisor did not become ready within $TotalWaitTime seconds."
            $deactivateDecision = Invoke-PauseBeforeRollbackIfRequested -ForcePrompt -RollbackContext "supervisor deactivation (cluster `"$ClusterName`") - deactivate supervisor to leave cluster in a clean state for retry" -SingleSite:$SingleSite.IsPresent
            if ($deactivateDecision -eq "DoNotRollback") {
                throw [RollbackSkippedException]::new()
            }
            Write-LogMessage -Type INFO -Message "Deactivating supervisor on cluster `"$ClusterName`" to leave cluster in a clean state for retry."
            $disableResult = Disable-SupervisorOnCluster -ClusterId $ClusterId -ClusterName $ClusterName -SupervisorId $supervisorId -SuppressConfirm
            if ($disableResult.Success) {
                Write-LogMessage -Type INFO -Message "Supervisor fully deactivated. You may retry deployment."
                $deleteClusterPrompt = "Do you want to delete the compute cluster as well? (Y/N; press Enter for N)"
                try {
                    $response = $null
                    do {
                        $response = Read-Host $deleteClusterPrompt
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
            Write-LogMessage -Type ERROR -Message "Supervisor deployment failed for cluster `"$ClusterName`": $($disableResult.ErrorMessage). Check logs for details."
            throw [VcfDeploymentException]::new("Supervisor deployment failed for cluster `"$ClusterName`": $($disableResult.ErrorMessage). Check logs for details.")
        }

        Write-LogMessage -Type DEBUG -Message "[Step 5/5] Supervisor is ready (elapsed: $($waitResult.ElapsedSeconds) seconds)"
        Write-LogMessage -Type INFO -Message "Supervisor deployment completed successfully. Supervisor ID: $supervisorId"

        # ========================================================================
        # STEP 6: Check for Supervisor Upgrades and Wait for Completion.
        # ========================================================================
        Write-LogMessage -Type INFO -Message "Checking for available supervisor upgrade versions..."
        $upgradeInfo = Get-SupervisorUpgradeInfo -ClusterId $ClusterId

        if (-not $upgradeInfo.Success) {
            Write-LogMessage -Type WARNING -Message "Failed to query supervisor upgrade information: $($upgradeInfo.ErrorMessage). Skipping upgrade check."
        } elseif ($upgradeInfo.HasUpgradeAvailable) {
            Write-LogMessage -Type INFO -Message "Supervisor upgrade available for cluster `"$ClusterName`" (ID: $ClusterId):"
            Write-LogMessage -Type INFO -Message "  Current version: $($upgradeInfo.CurrentVersion)"
            Write-LogMessage -Type INFO -Message "  Latest available version: $($upgradeInfo.LatestVersion)"
            Write-LogMessage -Type INFO -Message "  Available versions: $($upgradeInfo.AvailableVersions -join ', ')"

            # Perform the upgrade to the latest available version.
            Write-LogMessage -Type INFO -Message "Initiating supervisor upgrade to version $($upgradeInfo.LatestVersion)..."
            $upgradeResult = Invoke-SupervisorUpgrade -ClusterId $ClusterId -DesiredVersion $upgradeInfo.LatestVersion

            if ($upgradeResult.Success) {
                Write-LogMessage -Type INFO -Message "Supervisor upgrade initiated successfully. Waiting for upgrade to complete..."

                # Wait for upgrade to complete with progress monitoring.
                $upgradeWaitParams = @{
                    CheckInterval = $CheckInterval
                    ClusterId = $ClusterId
                    ClusterName = $ClusterName
                    DesiredVersion = $upgradeInfo.LatestVersion
                    SupervisorId = $supervisorId
                    TotalWaitTime = $TotalWaitTime
                }
                $upgradeWaitResult = Wait-SupervisorUpgradeComplete @upgradeWaitParams

                if ($upgradeWaitResult.Success) {
                    Write-LogMessage -Type INFO -Message "Supervisor upgrade completed successfully. Final version: $($upgradeWaitResult.FinalVersion)"
                } else {
                    Write-LogMessage -Type ERROR -Message "Supervisor upgrade did not complete within $TotalWaitTime seconds."
                    Write-LogMessage -Type ERROR -Message "The upgrade may still be in progress. Check the supervisor status in vCenter UI."
                    throw [VcfDeploymentException]::new("The upgrade may still be in progress. Check the supervisor status in vCenter UI.")
                }
            } else {
                Write-LogMessage -Type ERROR -Message "Failed to initiate supervisor upgrade: $($upgradeResult.ErrorMessage)."
                Write-LogMessage -Type ERROR -Message "Supervisor upgrade is required for deployment to proceed."
                throw [VcfDeploymentException]::new("Supervisor upgrade is required for deployment to proceed.")
            }
        } else {
            Write-LogMessage -Type INFO -Message "No supervisor upgrade available. Current version $($upgradeInfo.CurrentVersion) is up to date."
        }

        Write-Progress -Activity "Supervisor Deployment" -Status "Completed" -PercentComplete 100 -Completed

        return $supervisorId
    } catch [VcfDeploymentException] {
        throw  # already logged and typed — propagate without re-wrapping
    } catch {
        Write-LogMessage -Type ERROR -Message "Failed to create a Supervisor on cluster `"$ClusterName`" attached to vCenter `"$Script:vCenterName`": $($_.Exception.Message)"
        throw [VcfDeploymentException]::new("Failed to create a Supervisor on cluster `"$ClusterName`" attached to vCenter `"$Script:vCenterName`": $($_.Exception.Message)")
    }
}
Function Get-ManagementVSwitchInfo {

    <#
        .SYNOPSIS
        Returns the standard vSwitch that has the management VMkernel (vmk0) and its physical NIC(s).

        .DESCRIPTION
        Used to verify a host uses a single-NIC standard switch for management before vSS-to-vDS migration.
        Returns $null if vmk0 is not found or is not on a standard switch, or if the switch has more than one pNIC.

        .PARAMETER VMHost
        The VMHost object (from Get-VMHost).

        .OUTPUTS
        PSCustomObject with StandardSwitch, ManagementVmkernel, PnicNames (array of one pNIC name), ManagementPortGroupVlanId (VLAN ID of the port group vmk0 is on, or 0 if not determinable), or $null.

        .NOTES
        Caller should require exactly one pNIC for migration (host using just one NIC).
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [PSObject]$VMHost
    )

    $vmk0 = Get-VmkernelAdaptersOnHost -VMHost $VMHost -Server $Script:vCenterName | Where-Object { $_.Name -eq "vmk0" }
    if (-not $vmk0) {
        return $null
    }
    $stdSwitches = Get-VirtualSwitchesOnHost -VMHost $VMHost -Server $Script:vCenterName
    foreach ($vSwitch in $stdSwitches) {
        $portGroups = Get-VirtualPortGroupsOnSwitch -VirtualSwitch $vSwitch -Server $Script:vCenterName
        foreach ($pg in $portGroups) {
            $vmkernelsOnPg = Get-VmkernelOnPortGroup -VMHost $VMHost -PortGroup $pg -Server $Script:vCenterName
            if ($vmkernelsOnPg | Where-Object { $_.Name -eq "vmk0" }) {
                $pnics = Get-PhysicalNicsOnVdsForHost -VMHost $VMHost -VDSwitch $vSwitch -Server $Script:vCenterName
                $pnicNames = @($pnics | ForEach-Object { $_.Name })
                $mgmtVlanId = 0
                if ($pg.PSObject.Properties["VLanID"]) {
                    $mgmtVlanId = [int]$pg.VLanID
                } elseif ($pg.PSObject.Properties["VlanId"]) {
                    $mgmtVlanId = [int]$pg.VlanId
                } elseif ($null -ne $pg.ExtensionData -and $null -ne $pg.ExtensionData.Spec -and $null -ne $pg.ExtensionData.Spec.VlanId) {
                    $mgmtVlanId = [int]$pg.ExtensionData.Spec.VlanId
                }
                return [PSCustomObject]@{
                    ManagementPortGroupVlanId = $mgmtVlanId
                    ManagementVmkernel       = $vmk0
                    PnicNames                = $pnicNames
                    StandardSwitch           = $vSwitch
                }
            }
        }
    }
    return $null
}
Function Get-FirstUnusedNicFromNicList {

    <#
        .SYNOPSIS
        Returns the first NIC name from the given list that is not assigned to any switch on the host.

        .DESCRIPTION
        Used to choose which pNIC to attach to the VDS first during vSS-to-vDS migration.

        .PARAMETER VMHost
        The VMHost object.

        .PARAMETER NicNames
        Array of pNIC names (e.g. from common.nicList).

        .OUTPUTS
        First unassigned NIC name, or $null if all are assigned.
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [PSObject]$VMHost,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String[]]$NicNames
    )

    $assigned = @()
    $stdSwitches = Get-VirtualSwitchesOnHost -VMHost $VMHost -Server $Script:vCenterName
    foreach ($sw in $stdSwitches) {
        $pnics = Get-PhysicalNicsOnVdsForHost -VMHost $VMHost -VDSwitch $sw -Server $Script:vCenterName
        if ($pnics) {
            $assigned += @($pnics | ForEach-Object { $_.Name })
        }
    }
    $allVds = Get-VDSwitch -Server $Script:vCenterName -ErrorAction SilentlyContinue
    foreach ($vds in $allVds) {
        $pnics = Get-PhysicalNicsOnVdsForHost -VMHost $VMHost -VDSwitch $vds -Server $Script:vCenterName
        if ($pnics) {
            $assigned += @($pnics | ForEach-Object { $_.Name })
        }
    }
    $assigned = $assigned | Select-Object -Unique
    foreach ($nicName in $NicNames) {
        if ($assigned -notcontains $nicName) {
            return $nicName
        }
    }
    return $null
}
Function Invoke-MigrateHostManagementToVds {

    <#
        .SYNOPSIS
        Migrates the host management VMkernel (vmk0) from a single-NIC standard switch to the VDS with same IP, then reclaims the pNIC.

        .DESCRIPTION
        Ensures the host uses exactly one pNIC for management on a standard switch. Adds the first unused NIC from NicList to the VDS,
        creates a management distributed port group, migrates vmk0 to it (same IP), removes the standard switch after confirming no
        VMs (or only VM Network with no VMs), adds the reclaimed pNIC to the VDS, and sets active/passive teaming.

        .PARAMETER VMHost
        The VMHost object.

        .PARAMETER VdsName
        Name of the VDS (must already exist; host must already be added to the VDS).

        .PARAMETER NicList
        Array of NIC config objects (e.g. from common.nicList with Name property). Only the first unused is used for initial attach; the reclaimed pNIC is then added.

        .PARAMETER ManagementPortGroupName
        Name for the management distributed port group. Default "mgmt".

        .PARAMETER ManagementVlanId
        Fallback VLAN ID for the management port group when the host's current vmk0 port group VLAN cannot be read. Default 0. The VLAN used when creating the DPG is normally sourced from the host's existing management port group (Get-ManagementVSwitchInfo) so the host is not disconnected by a VLAN change.

        .NOTES
        Throws if host does not have exactly one pNIC on the management vSwitch or migration fails.
        PowerCLI deprecation warning for VmwareVDPortgroup.VirtualSwitch (replacement is .VDSwitch) is suppressed at DPG-related cmdlet calls (-WarningAction SilentlyContinue) because the warning originates inside PowerCLI cmdlets when they receive or return DPG objects.
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [PSObject]$VMHost,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VdsName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [System.Object[]]$NicList,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$ManagementPortGroupName = "mgmt",
        [Parameter(Mandatory = $false)] [int]$ManagementVlanId = 0
    )

    $hostDisplay = $VMHost.Name
    $nicNames = @()
    foreach ($item in $NicList) {
        $name = if ($item -is [String]) { $item.Trim() } else { $item.Name }
        if (-not [String]::IsNullOrWhiteSpace($name)) { $nicNames += $name }
    }
    if ($nicNames.Count -eq 0) {
        Write-LogMessage -Type ERROR -Message "Deployment failed. NicList is empty for host `"$hostDisplay`"."
        throw [VcfDeploymentException]::new("Deployment failed. NicList is empty for host `"$hostDisplay`".")
    }

    $prevWarningPreference = $WarningPreference
    $WarningPreference = 'SilentlyContinue'
    try {
    # If vmk0 is already on the target VDS, skip migration (idempotent). Required for re-runs (e.g. -Force) when cluster and VDS already exist.
    $vdsObject = Get-VDSwitch -Name $VdsName -Server $Script:vCenterName -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
    if ($vdsObject) {
        $vmk0 = Get-VMHostNetworkAdapter -VMHost $VMHost -VMKernel -Server $Script:vCenterName -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq "vmk0" }
        if ($vmk0) {
            $vmk0OnTargetVds = $false
            $vmk0Network = $vmk0.ExtensionData.Spec.PortGroup
            if ($vmk0Network) {
                $pgIdValue = if ($vmk0Network.Value) { $vmk0Network.Value } else { $vmk0Network }
                $dpg = Get-VDPortgroup -Id $pgIdValue -Server $Script:vCenterName -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
                if ($dpg -and $dpg.VDSwitch.Name -eq $VdsName) {
                    $vmk0OnTargetVds = $true
                }
            }
            if (-not $vmk0OnTargetVds) {
                # Fallback: some PowerCLI/vSphere return MoRef or Id in a form Get-VDPortgroup -Id does not accept. Check each DPG on the target VDS for vmk0. -WarningAction suppresses VmwareVDPortgroup.VirtualSwitch deprecation.
                $vdPgs = Get-VDPortgroup -VDSwitch $vdsObject -Server $Script:vCenterName -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
                foreach ($dpg in $vdPgs) {
                    $vmkernelsOnDpg = Get-VMHostNetworkAdapter -VMHost $VMHost -VMKernel -PortGroup $dpg -Server $Script:vCenterName -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
                    if ($vmkernelsOnDpg | Where-Object { $_.Name -eq "vmk0" }) {
                        $vmk0OnTargetVds = $true
                        break
                    }
                }
            }
            if ($vmk0OnTargetVds) {
                Write-LogMessage -Type INFO -Message "Host `"$hostDisplay`" management (vmk0) is already on VDS `"$VdsName`". Skipping migration."
                $currentMtu = $null
                if ($vmk0.PSObject.Properties["Mtu"]) { $currentMtu = $vmk0.Mtu }
                if ($null -ne $currentMtu -and [int]$currentMtu -ne 1500) {
                    try {
                        $null = Set-VMHostNetworkAdapter -VirtualNic $vmk0 -Mtu 1500 -Confirm:$false -ErrorAction Stop
                        Write-LogMessage -Type DEBUG -Message "Set vmk0 MTU to 1500 on host `"$hostDisplay`" (was $currentMtu)."
                    } catch {
                        Write-LogMessage -Type WARNING -Message "Could not set vmk0 MTU to 1500 on host `"$hostDisplay`": $($_.Exception.Message)."
                    }
                }
                return
            }
        }
    }

    $mgmtInfo = Get-ManagementVSwitchInfo -VMHost $VMHost
    if (-not $mgmtInfo -or $mgmtInfo.PnicNames.Count -ne 1) {
        $pnicCount = if ($mgmtInfo) { $mgmtInfo.PnicNames.Count } else { 0 }
        Write-LogMessage -Type ERROR -Message "Host `"$hostDisplay`" must use exactly one NIC for management (vmk0 on a standard switch). Found: $pnicCount pNIC(s)."
        throw [VcfDeploymentException]::new("Deployment failed. Host `"$hostDisplay`" must have management on a single-NIC standard switch. Check logs for details.")
    }

    # Use the VLAN from the host's current management port group so the DPG matches and we do not disconnect the host.
    $effectiveMgmtVlanId = if ($null -ne $mgmtInfo.PSObject.Properties["ManagementPortGroupVlanId"]) { $mgmtInfo.ManagementPortGroupVlanId } else { $ManagementVlanId }
    $reclaimedPnicName = $mgmtInfo.PnicNames[0]
    $firstUnused = Get-FirstUnusedNicFromNicList -VMHost $VMHost -NicNames $nicNames
    $vdsObject = Get-VDSwitch -Name $VdsName -Server $Script:vCenterName -WarningAction SilentlyContinue -ErrorAction Stop
    $hostAlreadyHasPnicOnVds = $false
    if (-not $firstUnused) {
        $pnicsOnTargetVds = @(Get-VMHostNetworkAdapter -VMHost $VMHost -Physical -VirtualSwitch $vdsObject -Server $Script:vCenterName -WarningAction SilentlyContinue -ErrorAction SilentlyContinue)
        if ($pnicsOnTargetVds -and $pnicsOnTargetVds.Count -gt 0) {
            $hostAlreadyHasPnicOnVds = $true
            Write-LogMessage -Type INFO -Message "Host `"$hostDisplay`" has no unused NIC from NicList (all assigned); at least one pNIC is already on VDS `"$VdsName`". Proceeding to migrate vmk0 only."
        } else {
            Write-LogMessage -Type ERROR -Message "No unused NIC from NicList found on host `"$hostDisplay`". All of [$($nicNames -join ', ')] are already assigned."
            throw [VcfDeploymentException]::new("Deployment failed. No unused NIC for VDS on host `"$hostDisplay`". Check logs for details.")
        }
    }

    $mgmtPortGroup = Get-VDPortgroup -Name $ManagementPortGroupName -VDSwitch $vdsObject -Server $Script:vCenterName -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
    if (-not $mgmtPortGroup) {
        $mgmtPortGroup = Get-VDPortgroup -Name $ManagementPortGroupName -VDSwitch $vdsObject -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
    }
    if (-not $mgmtPortGroup) {
        $mgmtPgAttempt = 1
        $mgmtPgRetryDelaySeconds = 10
        $mgmtPgMaxAttempts = 3
        do {
            try {
                Write-LogMessage -Type INFO -Message "Creating management port group `"$ManagementPortGroupName`" on VDS `"$VdsName`" (VLAN $effectiveMgmtVlanId)."
                New-VDPortgroup -Name $ManagementPortGroupName -VDSwitch $vdsObject -VlanId $effectiveMgmtVlanId -NumPorts 128 -PortBinding Static -Server $Script:vCenterName -WarningAction SilentlyContinue -ErrorAction Stop | Out-Null
                $mgmtPortGroup = Get-VDPortgroup -Name $ManagementPortGroupName -VDSwitch $vdsObject -Server $Script:vCenterName -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
                if (-not $mgmtPortGroup) { $mgmtPortGroup = Get-VDPortgroup -Name $ManagementPortGroupName -VDSwitch $vdsObject -WarningAction SilentlyContinue -ErrorAction Stop }
                break
            } catch {
                $pgErr = $_.Exception.Message
                # Port group may have been created on server despite error (same as VDS). Re-query first.
                $mgmtPortGroup = Get-VDPortgroup -Name $ManagementPortGroupName -VDSwitch $vdsObject -Server $Script:vCenterName -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
                if (-not $mgmtPortGroup) { $mgmtPortGroup = Get-VDPortgroup -Name $ManagementPortGroupName -VDSwitch $vdsObject -WarningAction SilentlyContinue -ErrorAction SilentlyContinue }
                if ($null -ne $mgmtPortGroup) {
                    Write-LogMessage -Type INFO -Message "Management port group `"$ManagementPortGroupName`" exists on VDS `"$VdsName`" after New-VDPortgroup reported error; using existing."
                    break
                }
                if ($pgErr -match "already exists") {
                    Write-LogMessage -Type INFO -Message "Management port group `"$ManagementPortGroupName`" already exists on VDS `"$VdsName`"; resolving existing port group."
                    $mgmtPortGroup = Get-VDPortgroup -Name $ManagementPortGroupName -VDSwitch $vdsObject -Server $Script:vCenterName -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
                    if (-not $mgmtPortGroup) { $mgmtPortGroup = Get-VDPortgroup -Name $ManagementPortGroupName -VDSwitch $vdsObject -WarningAction SilentlyContinue -ErrorAction SilentlyContinue }
                    $getPgAttempt = 0
                    $getPgMaxAttempts = 3
                    $getPgDelaySeconds = 3
                    while (-not $mgmtPortGroup -and $getPgAttempt -lt $getPgMaxAttempts) {
                        $getPgAttempt++
                        Write-LogMessage -Type DEBUG -Message "Management port group not found yet (attempt $getPgAttempt of $getPgMaxAttempts); waiting $getPgDelaySeconds s for vCenter consistency."
                        Start-Sleep -Seconds $getPgDelaySeconds
                        $mgmtPortGroup = Get-VDPortgroup -Name $ManagementPortGroupName -VDSwitch $vdsObject -Server $Script:vCenterName -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
                        if (-not $mgmtPortGroup) { $mgmtPortGroup = Get-VDPortgroup -Name $ManagementPortGroupName -VDSwitch $vdsObject -WarningAction SilentlyContinue -ErrorAction SilentlyContinue }
                    }
                    if (-not $mgmtPortGroup) {
                        Write-LogMessage -Type ERROR -Message "Management port group `"$ManagementPortGroupName`" was reported as already existing on VDS `"$VdsName`" but could not be found. Check the VDS in vCenter and retry, or remove the conflicting port group if it exists on another switch."
                        throw [VcfDeploymentException]::new("Management port group `"$ManagementPortGroupName`" was reported as already existing on VDS `"$VdsName`" but could not be found. Check the VDS in vCenter and retry, or remove the conflicting port group if it exists on another switch.")
                    }
                    break
                }
                if ($pgErr -match "Operation is not valid due to the current state of the object" -and $mgmtPgAttempt -lt $mgmtPgMaxAttempts) {
                    Write-LogMessage -Type WARNING -Message "Management port group creation failed (attempt $mgmtPgAttempt of $mgmtPgMaxAttempts): $pgErr. Waiting $mgmtPgRetryDelaySeconds s before retry."
                    Start-Sleep -Seconds $mgmtPgRetryDelaySeconds
                    $mgmtPgAttempt++
                } else {
                    throw
                }
            }
        } while ($mgmtPgAttempt -le $mgmtPgMaxAttempts)
    }
    if (-not $mgmtPortGroup) {
        Write-LogMessage -Type ERROR -Message "Deployment failed. Could not get or create management port group `"$ManagementPortGroupName`" on VDS `"$VdsName`"."
        throw [VcfDeploymentException]::new("Deployment failed. Could not get or create management port group `"$ManagementPortGroupName`" on VDS `"$VdsName`".")
    }

    if (-not $hostAlreadyHasPnicOnVds) {
        # Add first unused NIC to VDS (so we have connectivity before moving vmk0).
        $pnicToAdd = Get-VMHostNetworkAdapter -VMHost $VMHost -Physical -Name $firstUnused -Server $Script:vCenterName -ErrorAction Stop
        $null = $vdsObject | Add-VDSwitchPhysicalNetworkAdapter -VMHostPhysicalNic $pnicToAdd -Server $Script:vCenterName -Confirm:$false -ErrorAction Stop
        Write-LogMessage -Type DEBUG -Message "Added pNIC `"$firstUnused`" to VDS `"$VdsName`" on host `"$hostDisplay`"."
    }

    # Migrate vmk0 to the distributed port group (same IP preserved by PowerCLI). VCF PowerCLI 9 does not support -Server on Set-VMHostNetworkAdapter. Use -Confirm:$false to avoid interactive prompt. -WarningAction SilentlyContinue suppresses VmwareVDPortgroup.VirtualSwitch deprecation.
    $vmk0 = $mgmtInfo.ManagementVmkernel
    Set-VMHostNetworkAdapter -VirtualNic $vmk0 -PortGroup $mgmtPortGroup -Confirm:$false -WarningAction SilentlyContinue -ErrorAction Stop | Out-Null
    $Script:DidMigrateVmk0ToVdsThisRun = $true
    Write-LogMessage -Type DEBUG -Message "Migrated management (vmk0) to VDS `"$VdsName`" port group `"$ManagementPortGroupName`" on host `"$hostDisplay`"."
    $mgmtMtu = 1500
    $currentMtu = $null
    if ($vmk0.PSObject.Properties["Mtu"]) { $currentMtu = $vmk0.Mtu }
    if ($null -ne $currentMtu -and [int]$currentMtu -ne $mgmtMtu) {
        try {
            $null = Set-VMHostNetworkAdapter -VirtualNic $vmk0 -Mtu $mgmtMtu -Confirm:$false -ErrorAction Stop
            Write-LogMessage -Type DEBUG -Message "Set vmk0 MTU to $mgmtMtu on host `"$hostDisplay`" (was $currentMtu; mgmt is always 1500)."
        } catch {
            Write-LogMessage -Type WARNING -Message "Could not set vmk0 MTU to $mgmtMtu on host `"$hostDisplay`": $($_.Exception.Message)."
        }
    }

    # Ensure vmk0 is management-only (no vMotion, vSAN, or vSAN witness traffic). Prefer single Set-VMHostNetworkAdapter call (VCF PowerCLI 9 supports -VMotionEnabled, -VsanTrafficEnabled, -VsanWitnessEnabled). Some builds reject all three parameters together; fallback tries VMotion+Vsan then Witness, then each flag in its own try/catch so one failure does not prevent others.
    try {
        $vmk0Cleared = $false
        try {
            Set-VMHostNetworkAdapter -VirtualNic $vmk0 -VMotionEnabled $false -VsanTrafficEnabled $false -VsanWitnessEnabled $false -Confirm:$false -ErrorAction Stop | Out-Null
            $vmk0Cleared = $true
        } catch {
            if ($_.Exception.Message -notmatch "Parameter set cannot be resolved|cannot be used together|insufficient number of parameters|parameter cannot be found") {
                throw
            }
            Write-LogMessage -Type DEBUG -Message "Set-VMHostNetworkAdapter with all three traffic flags failed; trying fallbacks: $($_.Exception.Message)."
        }
        if (-not $vmk0Cleared) {
            try {
                Set-VMHostNetworkAdapter -VirtualNic $vmk0 -VMotionEnabled $false -VsanTrafficEnabled $false -Confirm:$false -ErrorAction Stop | Out-Null
                $vmk0Cleared = $true
            } catch {
                Write-LogMessage -Type DEBUG -Message "Set-VMHostNetworkAdapter VMotion+Vsan false failed: $($_.Exception.Message)."
            }
        }
        if (-not $vmk0Cleared) {
            try {
                Set-VMHostNetworkAdapter -VirtualNic $vmk0 -VsanWitnessEnabled $false -Confirm:$false -ErrorAction Stop | Out-Null
            } catch {
                Write-LogMessage -Type DEBUG -Message "Set-VMHostNetworkAdapter VsanWitnessEnabled false failed: $($_.Exception.Message)."
            }
            try {
                Set-VMHostNetworkAdapter -VirtualNic $vmk0 -VMotionEnabled $false -Confirm:$false -ErrorAction Stop | Out-Null
            } catch {
                Write-LogMessage -Type DEBUG -Message "Set-VMHostNetworkAdapter VMotionEnabled false failed: $($_.Exception.Message)."
            }
            try {
                Set-VMHostNetworkAdapter -VirtualNic $vmk0 -VsanTrafficEnabled $false -Confirm:$false -ErrorAction Stop | Out-Null
            } catch {
                Write-LogMessage -Type DEBUG -Message "Set-VMHostNetworkAdapter VsanTrafficEnabled false failed: $($_.Exception.Message)."
            }
        }
        Write-LogMessage -Type DEBUG -Message "Ensured vmk0 is management-only (vMotion/vSAN/vSAN witness disabled) on host `"$hostDisplay`"."
    } catch {
        Write-LogMessage -Type WARNING -Message "Could not clear vMotion/vSAN from vmk0 on host `"$hostDisplay`" (non-fatal): $($_.Exception.Message)."
    }

    # Confirm standard switch has no VMs (or only VM Network with no VMs), then remove it.
    $stdSwitch = $mgmtInfo.StandardSwitch
    $portGroupsOnSwitch = Get-VirtualPortGroup -VirtualSwitch $stdSwitch -Server $Script:vCenterName -ErrorAction SilentlyContinue
    foreach ($pg in $portGroupsOnSwitch) {
        $vmsOnPg = Get-VM -Server $Script:vCenterName -Location $VMHost -ErrorAction SilentlyContinue | Where-Object {
            $_.NetworkAdapters | Where-Object { $_.Network -and ($_.Network.Name -eq $pg.Name) }
        }
        if ($vmsOnPg -and @($vmsOnPg).Count -gt 0) {
            $vmNames = @($vmsOnPg) | Select-Object -ExpandProperty Name
            Write-LogMessage -Type ERROR -Message "Cannot remove standard switch `"$($stdSwitch.Name)`" on host `"$hostDisplay`": port group `"$($pg.Name)`" has $($vmNames.Count) VM(s): $($vmNames -join ', ')."
            throw [VcfDeploymentException]::new("Deployment failed. Migrate or power off VMs on port group `"$($pg.Name)`" before retrying. Check logs for details.")
        }
    }
    Remove-VirtualSwitch -VirtualSwitch $stdSwitch -Server $Script:vCenterName -Confirm:$false -ErrorAction Stop
    Write-LogMessage -Type DEBUG -Message "Removed standard switch `"$($stdSwitch.Name)`" from host `"$hostDisplay`"."

    # Add second uplink: prefer the other NIC from NicList (so VDS uses user-specified NICs, e.g. vmnic0 and vmnic1). After a deploy-then-cleanup cycle, management is on vSwitch0-restore with the pNIC that was removed from the VDS during restore (often alphabetically last, e.g. vmnic2); that pNIC would otherwise be "reclaimed" and added here. Preferring the second from NicList ensures correct uplinks on re-deploy. Fall back to reclaimed pNIC if NicList has only one or the second is unavailable.
    $secondFromNicList = @($nicNames | Where-Object { $_ -ne $firstUnused })[0]
    $pnicToAddAsSecond = $null
    if (-not [String]::IsNullOrWhiteSpace($secondFromNicList)) {
        try {
            $candidatePnic = Get-VMHostNetworkAdapter -VMHost $VMHost -Physical -Name $secondFromNicList -Server $Script:vCenterName -ErrorAction Stop
            $pnicsAlreadyOnVds = @(Get-VMHostNetworkAdapter -VMHost $VMHost -Physical -VirtualSwitch $vdsObject -Server $Script:vCenterName -WarningAction SilentlyContinue -ErrorAction SilentlyContinue)
            $alreadyOnVds = @($pnicsAlreadyOnVds | Where-Object { $_.Name -eq $secondFromNicList })
            if (-not $alreadyOnVds -and $candidatePnic) {
                $pnicToAddAsSecond = $candidatePnic
            }
        } catch {
            Write-LogMessage -Type DEBUG -Message "Second NIC from NicList `"$secondFromNicList`" not available on host `"$hostDisplay`": $($_.Exception.Message). Using reclaimed pNIC."
        }
    }
    if ($null -eq $pnicToAddAsSecond) {
        $pnicToAddAsSecond = Get-VMHostNetworkAdapter -VMHost $VMHost -Physical -Name $reclaimedPnicName -Server $Script:vCenterName -ErrorAction Stop
        $null = $vdsObject | Add-VDSwitchPhysicalNetworkAdapter -VMHostPhysicalNic $pnicToAddAsSecond -Server $Script:vCenterName -Confirm:$false -ErrorAction Stop
        Write-LogMessage -Type DEBUG -Message "Added reclaimed pNIC `"$reclaimedPnicName`" to VDS `"$VdsName`" on host `"$hostDisplay`"."
    } else {
        try {
            $null = $vdsObject | Add-VDSwitchPhysicalNetworkAdapter -VMHostPhysicalNic $pnicToAddAsSecond -Server $Script:vCenterName -Confirm:$false -ErrorAction Stop
            Write-LogMessage -Type DEBUG -Message "Added pNIC `"$secondFromNicList`" to VDS `"$VdsName`" on host `"$hostDisplay`" (second from NicList)."
            if ($stdSwitch.Name -eq "vSwitch0-restore") {
                Write-LogMessage -Type DEBUG -Message "Management was on restore VSS; used second from NicList so VDS uplinks match NicList on re-deploy after cleanup."
            }
        } catch {
            Write-LogMessage -Type WARNING -Message "Could not add pNIC `"$secondFromNicList`" to VDS (e.g. already on another switch): $($_.Exception.Message). Adding reclaimed pNIC `"$reclaimedPnicName`"."
            $pnicToAddAsSecond = Get-VMHostNetworkAdapter -VMHost $VMHost -Physical -Name $reclaimedPnicName -Server $Script:vCenterName -ErrorAction Stop
            $null = $vdsObject | Add-VDSwitchPhysicalNetworkAdapter -VMHostPhysicalNic $pnicToAddAsSecond -Server $Script:vCenterName -Confirm:$false -ErrorAction Stop
            Write-LogMessage -Type DEBUG -Message "Added reclaimed pNIC `"$reclaimedPnicName`" to VDS `"$VdsName`" on host `"$hostDisplay`"."
        }
    }

    # Set active/passive: first uplink active, others standby. Set-VDUplinkTeamingPolicy requires -Policy (from Get-VDUplinkTeamingPolicy) and uses -StandbyUplinkPort (not -VDPortgroup or -PassiveUplinkPort) in VCF PowerCLI 9. VCF PowerCLI 9 does not support -Server on Get-VDPortgroup, Get-VDUplinkTeamingPolicy, or Set-VDUplinkTeamingPolicy.
    $vdpg = Get-VDPortgroup -VDSwitch $vdsObject -WarningAction SilentlyContinue -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike "*DVUplinks*" } | Select-Object -First 1
    if ($vdpg) {
        $policy = $vdpg | Get-VDUplinkTeamingPolicy -ErrorAction SilentlyContinue
        if ($policy) {
            $allUplinkNames = @($vdsObject.ExtensionData.Config.UplinkPortPolicy.UplinkPortName)
            if ($allUplinkNames.Count -ge 2) {
                $activeUplinks = @($allUplinkNames[0])
                $standbyUplinks = @($allUplinkNames[1..($allUplinkNames.Count - 1)])
                $null = Set-VDUplinkTeamingPolicy -Policy $policy -ActiveUplinkPort $activeUplinks -StandbyUplinkPort $standbyUplinks -ErrorAction SilentlyContinue
                Write-LogMessage -Type DEBUG -Message "Set active/passive teaming on VDS `"$VdsName`" for host `"$hostDisplay`"."
            }
        }
    }
    } finally {
        $WarningPreference = $prevWarningPreference
    }
}
Function Invoke-VDSCreation {

    <#
        .SYNOPSIS
        Creates a Virtual Distributed Switch or retrieves an existing one.

        .DESCRIPTION
        This helper function creates a new Virtual Distributed Switch with the specified
        configuration or retrieves an existing VDS if it already exists. The function
        handles idempotent VDS creation for safe re-execution.

        .PARAMETER VdsName
        The name of the Virtual Distributed Switch to create or retrieve.

        .PARAMETER DatacenterObject
        The datacenter object where the VDS will be created.

        .PARAMETER NumUplinks
        The number of uplink ports to configure on the VDS.


        .PARAMETER VdsCreationRetryCount
        When New-VDSwitch fails with "Operation is not valid due to the current state of the object", number of retries. Default is 5.

        .PARAMETER VdsCreationRetryDelaySeconds
        Seconds to wait between New-VDSwitch retries when vCenter reports invalid state. Default is 15.

        .PARAMETER Mtu
        Maximum Transmission Unit for the VDS (1500-9190). Used for vMotion/vSAN traffic; mgmt and vSAN Witness VMkernels are always 1500. Default is 9000. Override via common.vSanvMotionVmKernelMtuValue in infrastructure JSON (validated 1500-9190).

        .OUTPUTS
        VDS object (VMware.VimAutomation.Vds.Types.V1.VmwareVDSwitch)

        .EXAMPLE
        $vds = Invoke-VDSCreation -VdsName "Production-VDS" -DatacenterObject $dc -NumUplinks "2"

        .NOTES
        Error Handling: Helper function. Returns VDS object on success. Returns structured error
        object via Write-ErrorAndReturn on failure. Caller should check result type and handle
        errors appropriately (typically by throwing a terminating error in main workflow functions).
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [PSObject]$DatacenterObject,
        [Parameter(Mandatory = $false)] [ValidateRange(1500, 9190)] [Int]$Mtu = 9000,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$NumUplinks,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VdsName,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 10)] [Int]$VdsCreationRetryCount = 5,
        [Parameter(Mandatory = $false)] [ValidateRange(5, 120)] [Int]$VdsCreationRetryDelaySeconds = 15
    )

    Write-LogMessage -Type DEBUG -Message "Entered Invoke-VDSCreation function..."

    $connectionTest = Test-VcenterConnection
    if (-not $connectionTest.IsConnected) {
        Write-LogMessage -Type ERROR -Message "Not connected to vCenter `"$Script:vCenterName`": $($connectionTest.ErrorMessage)"
        throw [VcfDeploymentException]::new("Not connected to vCenter `"$Script:vCenterName`": $($connectionTest.ErrorMessage)")
    }

    $numUplinksInt = [int]$NumUplinks
    try {
        # Check if VDS already exists.
        $vdsObject = Get-VDSwitch -Name $VdsName -Server $Script:vCenterName -ErrorAction SilentlyContinue

        if ($null -ne $vdsObject) {
            # If existing VDS has 0 uplinks (e.g. from a previous run with wrong parameter type), fix it so Add-VDSwitchPhysicalNetworkAdapter does not fail with "no free uplink ports".
            $currentUplinkNames = $vdsObject.ExtensionData.Config.UplinkPortPolicy.UplinkPortName
            $currentUplinkCount = if ($currentUplinkNames) { $currentUplinkNames.Count } else { 0 }
            if ($currentUplinkCount -lt $numUplinksInt) {
                Write-LogMessage -Type INFO -Message "VDS `"$VdsName`" has $currentUplinkCount uplink port(s); setting to $numUplinksInt so pNICs can be added."
                Set-VDSwitch -VDSwitch $vdsObject -NumUplinkPorts $numUplinksInt -ErrorAction Stop | Out-Null
            }
            Write-LogMessage -Type INFO -Message "VDS `"$VdsName`" is already present. Skipping VDS creation."
            return $vdsObject
        }


        # Create new VDS (version is determined by vCenter; no need to specify). NumUplinkPorts must be Int32. MTU set for consistency with VMkernel adapters (avoids vSAN/vMotion MTU health check failures). Retry when vCenter reports "Operation is not valid due to the current state of the object".
        Write-LogMessage -Type INFO -NoNewline -Message "Creating VDS `"$VdsName`" on vCenter `"$Script:vCenterName`"... "
        $createAttempt = 1
        $vdsCreated = $false
        do {
            try {
                New-VDSwitch -Name $VdsName -Location $DatacenterObject -Mtu $Mtu -NumUplinkPorts $numUplinksInt -WarningAction SilentlyContinue -ErrorAction Stop | Out-Null
                $vdsCreated = $true
                break
            } catch {
                $createErr = $_.Exception.Message
                # vCenter may create the VDS but return an error to the client (e.g. "current state of the object" or DuplicateName on retry). If the VDS exists, treat as success.
                $existingVds = Get-VDSwitch -Name $VdsName -Server $Script:vCenterName -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
                if ($null -ne $existingVds) {
                    Write-LogMessage -Type INFO -Message "VDS `"$VdsName`" exists after New-VDSwitch reported error (creation may have completed on server). Using existing VDS."
                    $vdsCreated = $true
                    break
                }
                if ($createErr -match "Operation is not valid due to the current state of the object") {
                    if ($createAttempt -lt $VdsCreationRetryCount) {
                        Write-LogMessage -Type WARNING -Message "VDS creation failed (attempt $createAttempt of $VdsCreationRetryCount): $createErr. Waiting $VdsCreationRetryDelaySeconds s before retry (cluster/datacenter may be in transitional state)."
                        Start-Sleep -Seconds $VdsCreationRetryDelaySeconds
                        $createAttempt++
                    } else {
                        Write-LogMessage -Type ERROR -CompletePending -Message " Failed."
                        throw [VcfDeploymentException]::new("VDS `"$VdsName`" creation failed after $VdsCreationRetryCount attempt(s): $createErr")
                    }
                } else {
                    Write-LogMessage -Type ERROR -CompletePending -Message " Failed."
                    throw
                }
            }
        } while ($createAttempt -le $VdsCreationRetryCount -and -not $vdsCreated)

        # Retrieve newly created VDS. -WarningAction SilentlyContinue suppresses deprecation warnings from PowerCLI (e.g. VmwareVDPortgroup.VirtualSwitch when switch has port groups).
        $vdsObject = Get-VDSwitch -Name $VdsName -Server $Script:vCenterName -WarningAction SilentlyContinue -ErrorAction SilentlyContinue

        if ($null -ne $vdsObject) {
            Write-LogMessage -Type INFO -CompletePending -Message " Success"
            return $vdsObject
        } else {
            Write-LogMessage -Type ERROR -Message "Failed to retrieve VDS `"$VdsName`" after creation."
            throw [VcfDeploymentException]::new("Failed to retrieve VDS `"$VdsName`" after creation.")
        }
    } catch [VcfDeploymentException] {
        throw  # already logged and typed — propagate without re-wrapping
    } catch {
        if ($null -ne $Script:LogMessagePending) {
            Write-LogMessage -Type ERROR -CompletePending -Message " Failed."
        }
        Write-LogMessage -Type ERROR -Message "Failed to create VDS `"$VdsName`": $($_.Exception.Message)"
        throw [VcfDeploymentException]::new("Failed to create VDS `"$VdsName`": $($_.Exception.Message)")
    }
}
Function Add-HostToVDS {

    <#
        .SYNOPSIS
        Adds an ESX host to a Virtual Distributed Switch.

        .DESCRIPTION
        This helper function adds an ESX host to the specified VDS. If the host is already
        attached to the VDS, the function logs a warning and continues gracefully.

        .PARAMETER Hostname
        The ESX host object to add to the VDS.

        .PARAMETER VdsName
        The name of the Virtual Distributed Switch.

        .EXAMPLE
        Add-HostToVDS -Hostname $EsxHost -VdsName "Production-VDS"

        .NOTES
        Error Handling: Helper function. Returns structured error object via Write-ErrorAndReturn
        on unexpected failures. Caller should check $result.Success and handle errors accordingly.
        Expected errors (host already attached) are handled gracefully with warnings.
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [PSObject]$Hostname,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VdsName
    )

    Write-LogMessage -Type DEBUG -Message "Entered Add-HostToVDS function..."

    $prevWarningPreference = $WarningPreference
    try {
        $WarningPreference = 'SilentlyContinue'
        Add-VDSwitchVMHost -VMHost $Hostname -VDSwitch $VdsName -Server $Script:vCenterName -ErrorAction Stop | Out-Null
    } catch {
        $errMsg = $_.Exception.Message

        if ($errMsg -match "is already added to VDSwitch") {
            Write-LogMessage -Type INFO -Message "The ESX host `"$Hostname`" is already attached to VDS `"$VdsName`". Skipping attachment."
        } elseif ($errMsg -match "already exists") {
            Write-LogMessage -Type INFO -Message "The ESX host `"$Hostname`" is already associated with VDS `"$VdsName`" (already exists). Skipping attachment."
        } else {
            $WarningPreference = $prevWarningPreference
            return Write-ErrorAndReturn -ErrorMessage "Unexpected error adding ESX host `"$Hostname`" to VDS `"$VdsName`": $_" -ErrorCode "ERR_VDS_UNEXPECTED"
        }
    } finally {
        $WarningPreference = $prevWarningPreference
    }
}
Function New-VDSPortGroups {

    <#
        .SYNOPSIS
        Creates distributed port groups on a Virtual Distributed Switch.

        .DESCRIPTION
        This helper function creates multiple distributed port groups with VLAN configuration.
        It checks for existing port groups and handles idempotent creation. The function
        detects duplicate port groups and validates port group existence before creation.

        .PARAMETER VdsName
        The name of the Virtual Distributed Switch where port groups will be created.

        .PARAMETER PortGroups
        An array of objects containing port group configuration (Name, VlanId properties).

        .EXAMPLE
        $portGroups = @(
            @{ Name = "Management"; VlanId = 100 },
            @{ Name = "vMotion"; VlanId = 200 }
        )
        New-VDSPortGroups -VdsName "Production-VDS" -PortGroups $portGroups

        .NOTES
        Error Handling: Helper function. Returns structured error object via Write-ErrorAndReturn
        on unexpected failures. Caller should check $result.Success and handle errors accordingly.
        Expected errors (port group already exists) are handled gracefully with warnings.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [System.Object[]]$PortGroups,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VdsName
    )

    Write-LogMessage -Type DEBUG -Message "Entered New-VDSPortGroups function..."

    $connectionTest = Test-VcenterConnection
    if (-not $connectionTest.IsConnected) {
        Write-LogMessage -Type ERROR -Message "Not connected to vCenter `"$Script:vCenterName`": $($connectionTest.ErrorMessage)"
        throw [VcfDeploymentException]::new("Not connected to vCenter `"$Script:vCenterName`": $($connectionTest.ErrorMessage)")
    }

    foreach ($portGroup in $PortGroups) {
        try {
            # Check if port group already exists before attempting to create it. -WarningAction SilentlyContinue suppresses VmwareVDPortgroup.VirtualSwitch deprecation.
            $existingPortGroup = Get-VDPortgroup -Name $($portGroup.Name) -Server $Script:vCenterName -WarningAction SilentlyContinue -ErrorAction SilentlyContinue

            if ($existingPortGroup) {
                # Handle case where multiple port groups with same name exist.
                if ($existingPortGroup.GetType() -eq [System.Object[]]) {
                    Write-LogMessage -Type ERROR -Message "Two or more port groups named `"$($portGroup.Name)`" were found in vCenter `"$Script:vCenterName`". Please delete the duplicate port groups or update your configuration."
                    throw [VcfDeploymentException]::new("Two or more port groups named `"$($portGroup.Name)`" were found in vCenter `"$Script:vCenterName`". Please delete the duplicate port groups or update your configuration.")
                }

                # Check if it's on the same VDS.
                if ($existingPortGroup.VDSwitch.Name -eq $VdsName) {
                    try {
                        $existingVlanId = $existingPortGroup.ExtensionData.Config.DefaultPortConfig.Vlan.VlanId
                    } catch {
                        $existingVlanId = "Unknown"
                    }
                    Write-LogMessage -Type INFO -Message "Port group `"$($portGroup.Name)`" already exists on VDS `"$VdsName`" with VLAN ID $existingVlanId. Skipping creation."
                } else {
                    try {
                        $existingVlanId = $existingPortGroup.ExtensionData.Config.DefaultPortConfig.Vlan.VlanId
                    } catch {
                        $existingVlanId = "Unknown"
                    }
                    Write-LogMessage -Type WARNING -Message "Port group `"$($portGroup.Name)`" already exists on VDS `"$($existingPortGroup.VDSwitch.Name)`" with VLAN ID $existingVlanId but not on target VDS `"$VdsName`". Skipping creation to avoid conflicts."
                }
            } else {
                # Port group doesn't exist, create it.
                Write-LogMessage -Type INFO -NoNewline -Message "Creating port group `"$($portGroup.Name)`" on VDS `"$VdsName`" with VLAN ID $($portGroup.VlanId)... "
                New-VDPortgroup -Server $Script:vCenterName -Name $($portGroup.Name) -VDSwitch $VdsName -VlanId $($portGroup.VlanId) -NumPorts 128 -PortBinding Static -WarningAction SilentlyContinue -ErrorAction Stop | Out-Null
                Write-LogMessage -Type INFO -CompletePending -Message "Success"
            }
        } catch {
            if ($null -ne $Script:LogMessagePending) {
                Write-LogMessage -Type WARNING -CompletePending -Message " Failed."
            }
            $errMsg = $_.Exception.Message
            switch -Regex ($errMsg) {
                "Operation is not valid due to the current state of the object" {
                    Write-LogMessage -Type WARNING -Message "The port group `"$($portGroup.Name)`" is already attached to distributed switch `"$VdsName`"."
                    break
                }
                "already exists" {
                    Write-LogMessage -Type WARNING -Message "The port group `"$($portGroup.Name)`" is already present."
                    break
                }
                default {
                    return Write-ErrorAndReturn -ErrorMessage "Unexpected error creating port group $($portGroup.Name): $_" -ErrorCode "ERR_PORTGROUP_UNEXPECTED"
                }
            }
        }
    }
}
Function Set-VDSUplinkTeamingActiveStandby {

    <#
        .SYNOPSIS
        Configures the VDS so physical NICs use active/standby teaming (first uplink active, second uplink standby).

        .DESCRIPTION
        Sets the default uplink teaming policy on the distributed switch to ExplicitFailover with the first uplink active and the second standby. When the VDS has two uplinks (e.g. Uplink 1, Uplink 2), traffic uses the first until it fails, then fails over to the second. EnableFailback is enabled so when the active link recovers it is restored. Port groups inherit the switch default unless overridden.

        .PARAMETER VdsName
        Name of the Virtual Distributed Switch to configure.

        .PARAMETER Server
        vCenter server name. Defaults to $Script:vCenterName.

        .NOTES
        Requires at least two uplinks on the VDS. If the VDS has only one uplink, the function logs and returns without error. Non-fatal errors (e.g. policy not supported) are logged as warnings.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VdsName,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$Server = $Script:vCenterName
    )

    Write-LogMessage -Type DEBUG -Message "Entered Set-VDSUplinkTeamingActiveStandby for VDS `"$VdsName`"."

    $vdsObject = Get-VDSwitch -Name $VdsName -Server $Server -ErrorAction SilentlyContinue
    if (-not $vdsObject) {
        Write-LogMessage -Type WARNING -Message "Set-VDSUplinkTeamingActiveStandby: VDS `"$VdsName`" not found; skipping active/standby teaming."
        return
    }

    $uplinkNames = @()
    try {
        $uplinkNames = @($vdsObject.ExtensionData.Config.UplinkPortPolicy.UplinkPortName)
    } catch {
        Write-LogMessage -Type DEBUG -Message "Set-VDSUplinkTeamingActiveStandby: Could not read uplink names from VDS `"$VdsName`": $($_.Exception.Message)."
    }

    if ($uplinkNames.Count -lt 2) {
        Write-LogMessage -Type DEBUG -Message "Set-VDSUplinkTeamingActiveStandby: VDS `"$VdsName`" has fewer than 2 uplinks ($($uplinkNames.Count)); skipping active/standby."
        return
    }

    $activeUplink = $uplinkNames[0]
    $standbyUplink = $uplinkNames[1]

    try {
        $policy = Get-VDSwitch -Name $VdsName -Server $Server -ErrorAction Stop | Get-VDUplinkTeamingPolicy -ErrorAction Stop
        if (-not $policy) {
            Write-LogMessage -Type WARNING -Message "Set-VDSUplinkTeamingActiveStandby: Could not retrieve uplink teaming policy for VDS `"$VdsName`"; skipping."
            return
        }
        # Idempotent: skip if already configured as active/standby with same uplinks and failback.
        $currentActive = $null
        $currentStandby = $null
        if ($policy.PSObject.Properties['ActiveUplinkPort']) { $currentActive = @($policy.ActiveUplinkPort) }
        if ($policy.PSObject.Properties['StandbyUplinkPort']) { $currentStandby = @($policy.StandbyUplinkPort) }
        $activeMatch = $currentActive -and ($currentActive -contains $activeUplink -or $currentActive -eq $activeUplink)
        $standbyMatch = $currentStandby -and ($currentStandby -contains $standbyUplink -or $currentStandby -eq $standbyUplink)
        $lbMatch = (-not $policy.PSObject.Properties['LoadBalancingPolicy']) -or $policy.LoadBalancingPolicy -eq 'ExplicitFailover'
        $failbackMatch = (-not $policy.PSObject.Properties['EnableFailback']) -or $policy.EnableFailback -eq $true
        if ($activeMatch -and $standbyMatch -and $lbMatch -and $failbackMatch) {
            Write-LogMessage -Type DEBUG -Message "VDS `"$VdsName`" already has active/standby teaming (active: $activeUplink, standby: $standbyUplink). Skipping teaming policy update."
            return
        }
        Set-VDUplinkTeamingPolicy -Policy $policy -ActiveUplinkPort $activeUplink -StandbyUplinkPort $standbyUplink -LoadBalancingPolicy ExplicitFailover -EnableFailback $true -ErrorAction Stop | Out-Null
        Write-LogMessage -Type INFO -Message "VDS `"$VdsName`": configured active/standby teaming (active: $activeUplink, standby: $standbyUplink, failback enabled)."
    } catch {
        Write-LogMessage -Type WARNING -Message "Set-VDSUplinkTeamingActiveStandby: Could not set active/standby on VDS `"$VdsName`": $($_.Exception.Message)."
    }
}
Function Add-PhysicalAdaptersToVDS {

    <#
        .SYNOPSIS
        Assigns physical network adapters to Virtual Distributed Switch uplinks.

        .DESCRIPTION
        This helper function assigns physical network adapters (vmnics) to VDS uplinks.
        It checks for existing adapter assignments and handles idempotent configuration.
        The function retrieves currently assigned adapters from the VDS to prevent duplicate assignments.

        .PARAMETER VdsObject
        The Virtual Distributed Switch object to which adapters will be added.

        .PARAMETER VdsName
        The name of the Virtual Distributed Switch (used for logging).

        .PARAMETER Hostname
        The ESX host object containing the physical network adapters.

        .PARAMETER NicList
        Array of physical network adapter names. Each element may be a string (e.g. "vmnic1") or an object with a Name property (e.g. { Name = "vmnic1" }). Multiple NICs are supported. Each is validated on the host (must exist and be unassigned) before adding.

        .EXAMPLE
        $nicList = @(
            @{ Name = "vmnic0" },
            @{ Name = "vmnic1" }
        )
        Add-PhysicalAdaptersToVDS -VdsObject $vds -VdsName "Production-VDS" -Hostname $EsxHost -NicList $nicList

        .NOTES
        Error Handling: Helper function. Returns structured error object via Write-ErrorAndReturn
        on configuration failures. Caller should check $result.Success and handle errors accordingly.
        Validates that each NIC exists on the host and is not already assigned to any other switch before adding; fails the workflow if validation fails.
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [PSObject]$Hostname,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [System.Object[]]$NicList,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VdsName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [PSObject]$VdsObject
    )

    Write-LogMessage -Type DEBUG -Message "Entered Add-PhysicalAdaptersToVDS function..."

    $connectionTest = Test-VcenterConnection
    if (-not $connectionTest.IsConnected) {
        Write-LogMessage -Type ERROR -Message "Not connected to vCenter `"$Script:vCenterName`": $($connectionTest.ErrorMessage)"
        throw [VcfDeploymentException]::new("Not connected to vCenter `"$Script:vCenterName`": $($connectionTest.ErrorMessage)")
    }

    try {
        # Normalize NicList to adapter names (support object with .Name or string). Fail if any entry has no name.
        $nicNames = @()
        foreach ($item in $NicList) {
            $name = if ($item -is [String]) { $item.Trim() } else { $item.Name }
            if ([String]::IsNullOrWhiteSpace($name)) {
                Write-LogMessage -Type ERROR -Message "NicList contains an entry with no Name. Each entry must be a string or an object with a Name property."
                throw [VcfDeploymentException]::new("Deployment failed. Invalid NicList: entry missing Name. Check logs for details.")
            }
            $nicNames += $name
        }

        $hostDisplay = if ($Hostname.Name) { $Hostname.Name } else { [String]$Hostname }

        # Validate each NIC exists on the host.
        foreach ($nicName in $nicNames) {
            $adapter = Get-VMHostNetworkAdapter -VMHost $Hostname -Physical -Name $nicName -Server $Script:vCenterName -ErrorAction SilentlyContinue
            if (-not $adapter) {
                Write-LogMessage -Type ERROR -Message "Network adapter `"$nicName`" does not exist on host `"$hostDisplay`"."
                throw [VcfDeploymentException]::new("Deployment failed. NIC `"$nicName`" is not valid on host `"$hostDisplay`". Check logs for details.")
            }
        }

        # Build set of pNIC names already assigned to any switch (standard or VDS) other than the current VDS.
        $assignedToOtherSwitches = @()
        $stdSwitches = Get-VirtualSwitch -VMHost $Hostname -Standard -Server $Script:vCenterName -ErrorAction SilentlyContinue
        foreach ($sw in $stdSwitches) {
            $pnics = Get-VMHostNetworkAdapter -VMHost $Hostname -Physical -VirtualSwitch $sw -Server $Script:vCenterName -ErrorAction SilentlyContinue
            if ($pnics) {
                $assignedToOtherSwitches += @($pnics | ForEach-Object { $_.Name })
            }
        }
        $otherVds = Get-VDSwitch -Server $Script:vCenterName -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne $VdsName }
        foreach ($vds in $otherVds) {
            $pnics = Get-VMHostNetworkAdapter -VMHost $Hostname -Physical -VirtualSwitch $vds -Server $Script:vCenterName -ErrorAction SilentlyContinue
            if ($pnics) {
                $assignedToOtherSwitches += @($pnics | ForEach-Object { $_.Name })
            }
        }
        $assignedToOtherSwitches = $assignedToOtherSwitches | Select-Object -Unique

        foreach ($nicName in $nicNames) {
            if ($assignedToOtherSwitches -contains $nicName) {
                Write-LogMessage -Type ERROR -Message "Network adapter `"$nicName`" on host `"$hostDisplay`" is already assigned to another switch. Unassign it before adding to VDS `"$VdsName`"."
                throw [VcfDeploymentException]::new("Deployment failed. NIC `"$nicName`" is already assigned to a switch on host `"$hostDisplay`". Check logs for details.")
            }
        }

        # Get currently assigned physical adapters on this VDS for this host (for idempotent skip).
        $assignedAdapters = @()
        try {
            $vdsHostConfig = $VdsObject.ExtensionData.Config.Host | Where-Object { $_.Host.Value -eq $Hostname.ExtensionData.MoRef.Value }
            if ($vdsHostConfig -and $vdsHostConfig.Config.Backing.PnicSpec) {
                $assignedAdapters = $vdsHostConfig.Config.Backing.PnicSpec | ForEach-Object { $_.PnicDevice }
            }
        } catch {
            Write-LogMessage -Type DEBUG -Message "ExtensionData path for assigned adapters failed; trying Get-VMHostNetworkAdapter -VirtualSwitch."
        }
        if ($assignedAdapters.Count -eq 0) {
            $pnicsOnThisVds = Get-VMHostNetworkAdapter -VMHost $Hostname -Physical -VirtualSwitch $VdsObject -Server $Script:vCenterName -ErrorAction SilentlyContinue
            if ($pnicsOnThisVds) {
                $assignedAdapters = @($pnicsOnThisVds | ForEach-Object { $_.Name })
                Write-LogMessage -Type DEBUG -Message "Retrieved $($assignedAdapters.Count) adapter(s) already on VDS `"$VdsName`" for host `"$hostDisplay`" via Get-VMHostNetworkAdapter."
            }
        }

        # Add each physical adapter to the VDS.
        foreach ($nicName in $nicNames) {
            if ($assignedAdapters -contains $nicName) {
                Write-LogMessage -Type DEBUG -Message "Network adapter `"$nicName`" is already attached to VDS `"$VdsName`" on host `"$hostDisplay`"; skipping."
            } else {
                try {
                    $vmhostNetworkAdapter = Get-VMHostNetworkAdapter -VMHost $Hostname -Physical -Name $nicName -Server $Script:vCenterName -ErrorAction Stop
                    $VdsObject | Add-VDSwitchPhysicalNetworkAdapter -VMHostPhysicalNic $vmhostNetworkAdapter -Server $Script:vCenterName -Confirm:$false
                } catch {
                    $errMsg = $_.Exception.Message
                    if ($errMsg -match "no free uplink ports") {
                        Write-LogMessage -Type INFO -Message "VDS `"$VdsName`" has no free uplink ports (adapters may already be attached). Skipping add of `"$nicName`" on host `"$hostDisplay`"."
                    } else {
                        throw
                    }
                }
            }
        }
    } catch {
        Write-LogMessage -Type ERROR -Message "Failed to configure network adapters for VDS `"$VdsName`": $($_.Exception.Message)"
        return Write-ErrorAndReturn -ErrorMessage "Network adapter configuration failed" -ErrorCode "ERR_NIC_CONFIG"
    }
}
Function Get-VmkernelTrafficVdsNameForLayout {
    <#
        .SYNOPSIS
        Resolves the distributed switch name used for a VMkernel traffic role given uplink count.

        .DESCRIPTION
        Centralizes the mapping from base VDS name and uplink layout to the actual VDS object name.
        Today only two- and four-uplink layouts are supported: with four uplinks, vMotion and vSAN
        VMkernel port groups use the second segment switch (BaseVdsName-sw2) and vSAN Witness uses
        the first (BaseVdsName-sw1). Additional uplink counts or extra switches can be added as new
        switch cases without scattering string concatenation through VMkernel creation code.

        .PARAMETER BaseVdsName
        Base VDS name from infrastructure JSON (for example VDS-site1).

        .PARAMETER NumUplinks
        Total uplinks for the layout (2 or 4).

        .PARAMETER TrafficRole
        VmotionVsan for vMotion and vSAN services; Witness for vSAN Witness only.

        .OUTPUTS
        [String] VDS name to pass to Get-VDSwitch / New-VDSPortGroups.
    #>
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$BaseVdsName,
        [Parameter(Mandatory = $true)] [ValidateSet(2, 4)] [Int]$NumUplinks,
        [Parameter(Mandatory = $true)] [ValidateSet("VmotionVsan", "Witness")] [String]$TrafficRole
    )
    switch ($NumUplinks) {
        2 { return $BaseVdsName }
        4 {
            switch ($TrafficRole) {
                "VmotionVsan" { return "$BaseVdsName-sw2" }
                "Witness" { return "$BaseVdsName-sw1" }
            }
        }
        default { return $BaseVdsName }
    }
}
Function Add-VmkernelInterfacesFromNetworkingConfig {
    <#
        .SYNOPSIS
        Creates vMotion, vSAN, and optionally vSAN Witness distributed port groups on the VDS and adds VMkernel adapters on each host using networkingVmKernelInterfaces configuration.

        .DESCRIPTION
        When storage is vSAN-ESA or vSAN-OSA, clusters.networking.networkingVmKernelInterfaces defines at least vMotion and vSAN (required); vSAN Witness is optional. When vSAN Witness is not defined, mgmt (vmk0) is tagged with vSAN witness traffic in addition to mgmt (no separate vmk3). When vSAN Witness is defined, a dedicated witness VMkernel (vmk3) is created. Each entry has service, vlanId, netmask, ipList (one IP per host). Optional **gateway** on the vSAN Witness entry is applied with esxcli after the VMkernel exists. Mgmt (vmk0) is never modified by this function; vmk0 always retains mgmt traffic.

        .PARAMETER ClusterName
        Name of the cluster.

        .PARAMETER EsxHostNames
        Array of ESX host names in the same order as ipList in networkingVmKernelInterfaces (ipList[0] = first host, ipList[1] = second host).

        .PARAMETER NetworkingVmKernelInterfaces
        Array of at least two entries: vMotion, vSAN (required). Optional third entry: vSAN Witness. Each has service, vlanId, netmask, ipList (two IPs). Only the vSAN Witness entry uses **gateway** in JSON; when present, the default gateway is applied on the host with **esxcli network ip interface ipv4 set** (VCF PowerCLI does not set VMkernel default gateway on create).

        .PARAMETER NumUplinks
        Number of uplinks (2 or 4). When 4, vMotion and vSAN vmkernel port groups are created on the second VDS (VdsName-sw2); vSAN Witness (dedicated vmk3) port groups are created on the first VDS (VdsName-sw1) so witness traffic stays on the first distributed switch. VDS names per role come from Get-VmkernelTrafficVdsNameForLayout so additional layouts stay in one place.

        .PARAMETER VmkernelMtu
        MTU for vMotion and vSAN VMkernel adapters only (1500-9190). vSAN Witness and mgmt (vmk0) are always 1500. Default is 9000. Override via common.vSanvMotionVmKernelMtuValue in infrastructure JSON (validated 1500-9190).

        .PARAMETER Server
        vCenter server name.

        .PARAMETER VdsName
        Base VDS name (e.g. VDS-site2). For 4 NICs, vMotion and vSAN vmkernel port groups use VdsName-sw2; vSAN Witness uses VdsName-sw1. For 2 NICs all vmkernel port groups use this VDS name.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [System.Object[]]$EsxHostNames,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [System.Object[]]$NetworkingVmKernelInterfaces,
        [Parameter(Mandatory = $true)] [ValidateSet(2, 4)] [int]$NumUplinks,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$Server = $Script:vCenterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VdsName,
        [Parameter(Mandatory = $false)] [ValidateRange(1500, 9190)] [Int]$VmkernelMtu = 9000
    )
    if (-not $NetworkingVmKernelInterfaces -or $NetworkingVmKernelInterfaces.Count -lt 2) {
        Write-LogMessage -Type DEBUG -Message "Add-VmkernelInterfacesFromNetworkingConfig: networkingVmKernelInterfaces has fewer than 2 entries (vMotion and vSAN required); skipping."
        return
    }
    $vmotionVsanVdsName = Get-VmkernelTrafficVdsNameForLayout -BaseVdsName $VdsName -NumUplinks $NumUplinks -TrafficRole "VmotionVsan"
    $witnessVmkernelVdsName = Get-VmkernelTrafficVdsNameForLayout -BaseVdsName $VdsName -NumUplinks $NumUplinks -TrafficRole "Witness"
    $edgeSuffix = ($VdsName -replace '^VDS-', '') -replace '-sw[12]$', ''
    $vmkernelPortGroupSpecsVmotionVsan = @()
    $vmkernelPortGroupSpecsWitness = @()
    foreach ($vmk in $NetworkingVmKernelInterfaces) {
        $serviceName = if ($vmk.service) { [string]$vmk.service.Trim() } else { "" }
        if ([String]::IsNullOrWhiteSpace($serviceName)) { continue }
        $pgName = ($serviceName.ToLower().Replace(" ", "")) + "-" + $edgeSuffix
        $vlanId = 0
        if ($null -ne $vmk.vlanId) {
            if ($vmk.vlanId -is [int]) {
                $vlanId = $vmk.vlanId
            } else {
                $parsed = 0
                if ([int]::TryParse([string]$vmk.vlanId, [ref]$parsed)) { $vlanId = $parsed }
            }
        }
        $specEntry = @{ Name = $pgName; VlanId = $vlanId }
        if ($serviceName -eq "vSAN Witness") {
            $vmkernelPortGroupSpecsWitness += $specEntry
        } else {
            $vmkernelPortGroupSpecsVmotionVsan += $specEntry
        }
    }
    if (($vmkernelPortGroupSpecsVmotionVsan.Count -eq 0) -and ($vmkernelPortGroupSpecsWitness.Count -eq 0)) {
        Write-LogMessage -Type DEBUG -Message "Add-VmkernelInterfacesFromNetworkingConfig: no valid port group specs; skipping."
        return
    }
    if ($vmkernelPortGroupSpecsVmotionVsan.Count -gt 0) {
        $vmotionVsanPgResult = New-VDSPortGroups -PortGroups $vmkernelPortGroupSpecsVmotionVsan -VdsName $vmotionVsanVdsName
        if ($vmotionVsanPgResult -and -not $vmotionVsanPgResult.Success) {
            Write-LogMessage -Type ERROR -Message "Add-VmkernelInterfacesFromNetworkingConfig: failed to create vMotion/vSAN vmkernel port groups on VDS `"$vmotionVsanVdsName`"."
            throw [VcfDeploymentException]::new("Deployment failed. Could not create vMotion/vSAN port groups. Check logs for details.")
        }
    }
    if ($vmkernelPortGroupSpecsWitness.Count -gt 0) {
        if ($NumUplinks -eq 4) {
            Write-LogMessage -Type DEBUG -Message "Add-VmkernelInterfacesFromNetworkingConfig: vSAN Witness vmkernel port group(s) are created on the first VDS (`"$witnessVmkernelVdsName`") for four-uplink layouts."
        }
        $witnessPgResult = New-VDSPortGroups -PortGroups $vmkernelPortGroupSpecsWitness -VdsName $witnessVmkernelVdsName
        if ($witnessPgResult -and -not $witnessPgResult.Success) {
            Write-LogMessage -Type ERROR -Message "Add-VmkernelInterfacesFromNetworkingConfig: failed to create vSAN Witness vmkernel port groups on VDS `"$witnessVmkernelVdsName`"."
            throw [VcfDeploymentException]::new("Deployment failed. Could not create vSAN Witness port groups. Check logs for details.")
        }
    }
    $vdsObjectVmotionVsan = Get-VDSwitch -Name $vmotionVsanVdsName -Server $Server -ErrorAction SilentlyContinue
    if (-not $vdsObjectVmotionVsan) {
        Write-LogMessage -Type WARNING -Message "Add-VmkernelInterfacesFromNetworkingConfig: VDS `"$vmotionVsanVdsName`" not found; skipping VMkernel creation."
        return
    }
    $vdsObjectWitness = $null
    if ($vmkernelPortGroupSpecsWitness.Count -gt 0) {
        if ($witnessVmkernelVdsName -eq $vmotionVsanVdsName) {
            $vdsObjectWitness = $vdsObjectVmotionVsan
        } else {
            $vdsObjectWitness = Get-VDSwitch -Name $witnessVmkernelVdsName -Server $Server -ErrorAction SilentlyContinue
        }
        if (-not $vdsObjectWitness) {
            Write-LogMessage -Type WARNING -Message "Add-VmkernelInterfacesFromNetworkingConfig: VDS `"$witnessVmkernelVdsName`" not found; skipping VMkernel creation."
            return
        }
    }
    $clusterObject = Get-Cluster -Name $ClusterName -Server $Server -ErrorAction SilentlyContinue
    if (-not $clusterObject) {
        Write-LogMessage -Type WARNING -Message "Add-VmkernelInterfacesFromNetworkingConfig: cluster `"$ClusterName`" not found; skipping VMkernel creation."
        return
    }
    $hostsOrdered = @()
    foreach ($hName in $EsxHostNames) {
        $vmhost = Get-VMHost -Name $hName -Server $Server -ErrorAction SilentlyContinue
        if ($vmhost) { $hostsOrdered += $vmhost }
    }
    if ($hostsOrdered.Count -eq 0) {
        Write-LogMessage -Type WARNING -Message "Add-VmkernelInterfacesFromNetworkingConfig: no hosts resolved from EsxHostNames; skipping VMkernel creation."
        return
    }
    foreach ($vmk in $NetworkingVmKernelInterfaces) {
        $serviceName = if ($vmk.service) { [string]$vmk.service.Trim() } else { "" }
        if ([String]::IsNullOrWhiteSpace($serviceName)) { continue }
        $pgName = ($serviceName.ToLower().Replace(" ", "")) + "-" + $edgeSuffix
        $ipList = @($vmk.ipList)
        $netmask = if ($vmk.netmask) { [string]$vmk.netmask.Trim() } else { "255.255.255.0" }
        $vdsObjectForService = if ($serviceName -eq "vSAN Witness") { $vdsObjectWitness } else { $vdsObjectVmotionVsan }
        $dpg = Get-VDPortgroup -Name $pgName -VDSwitch $vdsObjectForService -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
        if (-not $dpg) {
            Write-LogMessage -Type WARNING -Message "Add-VmkernelInterfacesFromNetworkingConfig: port group `"$pgName`" not found on VDS `"$($vdsObjectForService.Name)`"; skipping VMkernel creation for service `"$serviceName`"."
            continue
        }
        for ($hostIndex = 0; $hostIndex -lt $hostsOrdered.Count; $hostIndex++) {
            $vmhost = $hostsOrdered[$hostIndex]
            $ip = if ($hostIndex -lt $ipList.Count) { [string]$ipList[$hostIndex].Trim() } else { $null }
            if ([String]::IsNullOrWhiteSpace($ip)) {
                Write-LogMessage -Type WARNING -Message "Add-VmkernelInterfacesFromNetworkingConfig: no IP for host index $hostIndex (service `"$serviceName`"); skipping."
                continue
            }
            $hostName = $vmhost.Name
            $existingVmk = Get-VMHostNetworkAdapter -VMHost $vmhost -VMKernel -PortGroup $dpg -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
            if ($existingVmk) {
                if ($serviceName -eq "vSAN Witness") {
                    $gwRawExisting = if ($vmk.gateway) { [string]$vmk.gateway.Trim() } else { "" }
                    if (-not [String]::IsNullOrWhiteSpace($gwRawExisting)) {
                        $exIp = $null
                        $exMask = $null
                        if ($existingVmk | Get-Member -Name IP -MemberType Properties -ErrorAction SilentlyContinue) {
                            $exIp = [string]$existingVmk.IP
                        }
                        if ($existingVmk | Get-Member -Name SubnetMask -MemberType Properties -ErrorAction SilentlyContinue) {
                            $exMask = [string]$existingVmk.SubnetMask
                        }
                        if ($exIp -and $exMask) {
                            Set-VmkernelIpv4StaticGatewayViaEsxcli -GatewayAddress $gwRawExisting -Ipv4Address $exIp -Server $Server -SubnetMask $exMask -VMHost $vmhost -VmkernelName $existingVmk.Name
                        }
                        else {
                            Write-LogMessage -Type WARNING -Message "Add-VmkernelInterfacesFromNetworkingConfig: witness gateway is set in JSON but IP/SubnetMask could not be read from existing VMkernel `"$($existingVmk.Name)`" on `"$hostName`"; set the default gateway on that VMkernel manually if witness traffic requires it."
                        }
                    }
                }
                Write-LogMessage -Type DEBUG -Message "Host `"$hostName`" already has a VMkernel on port group `"$pgName`"; skipping create for service `"$serviceName`"."
                continue
            }
            $createParams = @{
                VMHost                 = $vmhost
                PortGroup             = $pgName
                IP                    = $ip
                SubnetMask            = $netmask
                VirtualSwitch         = $vdsObjectForService
                Confirm               = $false
                ErrorAction           = 'Stop'
            }
            if ($serviceName -eq "vMotion") {
                $createParams["VMotionEnabled"] = $true
            }
            if ($serviceName -eq "vSAN") {
                $createParams["VsanTrafficEnabled"] = $true
            }
            # vSAN = vmk2 with vSAN traffic only. vSAN Witness = vmk3 with vSAN witness traffic only (no vSAN traffic on witness VMkernel).
            try {
                $newVmk = $null
                try {
                    $newVmk = New-VMHostNetworkAdapter @createParams -WarningAction SilentlyContinue
                } catch {
                    if ($serviceName -eq "vSAN" -and $_.Exception.Message -match "Parameter set cannot be resolved|cannot be used together|insufficient number of parameters") {
                        $createParamsWithoutVsan = @{
                            VMHost         = $vmhost
                            PortGroup      = $pgName
                            IP             = $ip
                            SubnetMask     = $netmask
                            VirtualSwitch  = $vdsObjectForService
                            Confirm        = $false
                            ErrorAction    = 'Stop'
                        }
                        $newVmk = New-VMHostNetworkAdapter @createParamsWithoutVsan -WarningAction SilentlyContinue
                        $null = Set-VMHostNetworkAdapter -VirtualNic $newVmk -VsanTrafficEnabled $true -Confirm:$false -ErrorAction Stop
                    } else {
                        throw
                    }
                }
                if ($serviceName -eq "vSAN Witness" -and $newVmk) {
                    try {
                        $null = Set-VMHostNetworkAdapter -VirtualNic $newVmk -VsanWitnessEnabled $true -Confirm:$false -ErrorAction Stop
                    } catch {
                        if ($_.Exception.Message -match "Parameter set cannot be resolved|cannot be used together|VsanWitnessEnabled|VsanWitnessTrafficEnabled|parameter cannot be found") {
                            Add-VsanWitnessTrafficToVmkViaEsxcli -VMHost $vmhost -VmkernelName $newVmk.Name -WitnessOnly | Out-Null
                        } else { throw }
                    }
                }
                if ($newVmk) {
                    $mtuForThisVmk = if ($serviceName -eq "vSAN Witness") { 1500 } else { $VmkernelMtu }
                    try {
                        $null = Set-VMHostNetworkAdapter -VirtualNic $newVmk -Mtu $mtuForThisVmk -Confirm:$false -ErrorAction Stop
                    } catch {
                        Write-LogMessage -Type WARNING -Message "Could not set MTU $mtuForThisVmk on VMkernel `"$($newVmk.Name)`" on host `"$hostName`": $($_.Exception.Message). vSAN/vMotion health checks may report MTU or connectivity failures if MTU is inconsistent."
                    }
                    if ($serviceName -eq "vSAN Witness") {
                        $gwRawNew = if ($vmk.gateway) { [string]$vmk.gateway.Trim() } else { "" }
                        if (-not [String]::IsNullOrWhiteSpace($gwRawNew)) {
                            Set-VmkernelIpv4StaticGatewayViaEsxcli -GatewayAddress $gwRawNew -Ipv4Address $ip -Server $Server -SubnetMask $netmask -VMHost $vmhost -VmkernelName $newVmk.Name
                        }
                    }
                }
                Write-LogMessage -Type INFO -Message "Created VMkernel for `"$serviceName`" on host `"$hostName`" (port group `"$pgName`", IP $ip, MTU $(if ($serviceName -eq 'vSAN Witness') { 1500 } else { $VmkernelMtu }))."
            } catch [VcfDeploymentException] {
                throw  # already logged and typed — propagate without re-wrapping
            } catch {
                Write-LogMessage -Type ERROR -Message "Failed to create VMkernel for `"$serviceName`" on host `"$hostName`": $($_.Exception.Message)"
                throw [VcfDeploymentException]::new("Deployment failed. Could not create $serviceName VMkernel on host `"$hostName`". Check logs for details.")
            }
        }
    }
}
Function Test-PhysicalNicConnected {
    <#
        .SYNOPSIS
        Returns whether a physical NIC on a host has link connected (link up).

        .DESCRIPTION
        Uses the host physical NIC's ExtensionData.LinkSpeed from the vSphere API. If LinkSpeed is not set, the link is down. If SpeedMb is present and zero, the link is treated as down.

        .PARAMETER NicName
        Physical network adapter name (e.g. vmnic0).

        .PARAMETER Server
        vCenter server to query.

        .PARAMETER VMHost
        The ESX host to check.

        .OUTPUTS
        Boolean: $true if the pNIC reports link connected; $false otherwise.
    #>
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$NicName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Server,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [PSObject]$VMHost
    )
    $adapter = Get-VMHostNetworkAdapter -VMHost $VMHost -Physical -Name $NicName -Server $Server -ErrorAction SilentlyContinue
    if (-not $adapter) {
        return $false
    }
    try {
        if (-not $adapter.ExtensionData -or -not $adapter.ExtensionData.LinkSpeed) {
            return $false
        }
        $speedMb = $adapter.ExtensionData.LinkSpeed.SpeedMb
        if ($null -ne $speedMb -and [int]$speedMb -eq 0) {
            return $false
        }
        return $true
    } catch {
        return $false
    }
}
Function Set-VirtualDistributedSwitch {

       <#
        .SYNOPSIS
        Creates and configures a vSphere Virtual Distributed Switch (VDS) with port groups and physical network adapters.

        .DESCRIPTION
        The Set-VirtualDistributedSwitch function creates and configures a complete vSphere Virtual Distributed Switch
        infrastructure including the switch itself, distributed port groups, and physical network adapter assignments.
        This function provides comprehensive VDS deployment automation for vSphere environments, handling all aspects
        of distributed switching configuration in a single operation.

        The function performs the following key operations:
        • Creates a new Virtual Distributed Switch with specified version and uplink configuration
        • Adds ESX hosts from the target cluster to the VDS for distributed network management
        • Creates multiple distributed port groups with VLAN configuration and static port binding
        • Assigns physical network adapters (vmnic) to the VDS uplinks for network connectivity
        • Provides comprehensive error handling and proactive duplicate resource detection
        • Integrates with vSphere cluster infrastructure for automated network deployment

        This function is designed for use in automated vSphere infrastructure deployments where consistent
        network configuration across multiple hosts is required. It handles existing resource detection
        gracefully, making it safe to run multiple times against the same infrastructure. The function
        proactively validates port group names to prevent conflicts and detects duplicate port groups.

        Key features:
        - Automated VDS creation with version and uplink port specification
        - Cluster-wide host integration with distributed switching
        - Multiple port group creation with VLAN and binding configuration
        - Proactive port group conflict detection and validation
        - Physical adapter assignment with duplicate detection
        - Comprehensive error handling for authorization and timeout scenarios
        - Integration with vSphere datacenter and cluster objects

        .PARAMETER VdsName
        The name of the Virtual Distributed Switch to create. This name must be unique within the
        datacenter and should follow standard vSphere naming conventions. The VDS name is used
        for identification and management operations throughout the vSphere environment.

        .PARAMETER DatacenterName
        The name of the vSphere datacenter where the VDS will be created. The datacenter must
        already exist and be accessible through the current vCenter connection. This parameter
        determines the scope and location of the distributed switch within the vSphere inventory.

        .PARAMETER NumUplinks
        The number of uplink ports to configure on the Virtual Distributed Switch. This determines
        how many physical network adapters can be connected to the switch for external connectivity.
        Common values are 2, 4, or 8 depending on the physical network configuration and redundancy
        requirements. Must be specified as a string value.

        .PARAMETER ClusterName
        The name of the vSphere cluster whose hosts will be added to the Virtual Distributed Switch.
        All hosts in the specified cluster will be configured to use the VDS for distributed
        network management. The cluster must exist and contain ESX hosts for the operation to succeed.

        .PARAMETER PortGroups
        An array of objects containing port group configuration information. Each object should contain
        at minimum 'Name' and 'VlanId' properties. The function creates distributed port groups with
        128 static ports and the specified VLAN configuration. Port groups provide network segmentation
        and traffic isolation for virtual machines and infrastructure services.

        .PARAMETER NicList
        An array of objects containing physical network adapter names; each object must have a 'Name' property
        (e.g. { "name": "vmnic1" }, { "name": "vmnic2" }). Multiple NICs are supported. Each adapter is validated
        on the target host: it must exist and must not be assigned to any other switch; if validation fails, the workflow fails.

        .EXAMPLE
        $portGroups = @(
            @{ Name = "Management"; VlanId = 100 },
            @{ Name = "vMotion"; VlanId = 200 },
            @{ Name = "Storage"; VlanId = 300 }
        )
        $nicList = @(
            @{ Name = "vmnic0" },
            @{ Name = "vmnic1" }
        )
        Set-VirtualDistributedSwitch -ClusterName "Cluster1" -DatacenterName "Datacenter1" -NicList $nicList -NumUplinks "2" -PortGroups $portGroups -VdsName "Production-VDS"

        Creates a production VDS with 2 uplinks, three port groups with different VLANs,
        and assigns two physical adapters to provide network connectivity. The function will check for
        existing port groups and skip creation if they already exist on the target VDS.

        .EXAMPLE
        Set-VirtualDistributedSwitch -ClusterName "Lab-Cluster" -DatacenterName "Lab-DC" -NicList $nicConfig -NumUplinks "4" -PortGroups $pgConfig -VdsName "Lab-VDS"

        Creates a lab environment VDS with 4 uplinks, utilizing pre-configured
        port group and NIC arrays for flexible deployment scenarios. Existing port groups will be detected
        and skipped to prevent conflicts.

        .EXAMPLE
        $vdsParams = @{
            clusterName = $InputData.common.clusterName
            datacenterName = $InputData.common.datacenterName
            nicList = $InputData.common.virtualDistributedSwitch.nicList
            numUplinks = $InputData.common.virtualDistributedSwitch.numUplinks
            portGroups = $InputData.common.virtualDistributedSwitch.portGroups
            vdsName = $InputData.common.virtualDistributedSwitch.vdsName
        }
        Set-VirtualDistributedSwitch @vdsParams

        Deploys VDS infrastructure using configuration parameters from input data with parameter splatting,
        enabling dynamic deployment scenarios based on configuration files.

        .OUTPUTS
        None
        This function does not return objects but performs infrastructure configuration with side effects.
        Success is indicated by the absence of exceptions and the creation of VDS infrastructure components.
        All operations are logged for audit trail and troubleshooting purposes.

        .NOTES
        Prerequisites:
        • Active PowerCLI connection to vCenter with administrative privileges
        • Target datacenter and cluster must exist and be accessible
        • ESX hosts in the cluster must be in a connected state
        • Physical network adapters specified in nicList must exist on target hosts
        • Sufficient network uplink capacity for the specified configuration

        Behavior:
        • Detects and skips creation of existing VDS, port groups, and adapter assignments
        • Proactively checks for existing port groups before attempting creation to prevent conflicts
        • Validates port group name uniqueness and detects multiple port groups with same name
        • Creates distributed port groups with 128 static ports and specified VLAN configuration
        • Assigns physical adapters to VDS uplinks in the order specified in nicList
        • Provides warning messages for existing resources rather than errors
        • Throws a terminating error if critical operations fail or duplicate port groups found

        Network Configuration:
        • Port groups are created with static port binding for predictable VM network assignment
        • VLAN configuration is applied based on the VlanId property in port group objects
        • Physical adapters are assigned to uplinks to provide external network connectivity
        Error Handling:
        • Main workflow function: Throws a terminating error on critical failures
        • Calls helper functions that return structured error objects via Write-ErrorAndReturn
        • Checks $result.Success from helper functions and exits on failure
        • Comprehensive exception handling for authorization, timeout, and general errors
        • Graceful handling of duplicate resource scenarios with warning messages
        • Proactive detection of multiple port groups with same name (terminates with error)
        • Detailed error logging for troubleshooting network configuration issues
        • Script termination on critical failures to prevent partial configurations
        • Helper functions (Invoke-VDSCreation, Add-HostToVDS, New-VDSPortGroups, Add-PhysicalAdaptersToVDS)
          return error objects; this function decides to exit on their failures

        Performance Considerations:
        • Operations are performed sequentially to ensure proper dependency handling
        • Large numbers of port groups or NICs may increase deployment time
        • Network adapter assignment requires host communication and may be affected by network latency

        .LINK
        New-VDSwitch
        Add-VDSwitchVMHost
        New-VDPortgroup
        Add-VDSwitchPhysicalNetworkAdapter
        Get-VMHostNetworkAdapter
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DatacenterName,
        [Parameter(Mandatory = $false)] [ValidateRange(1500, 9190)] [Int]$Mtu = 9000,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [System.Object[]]$NicList,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$NumUplinks,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [System.Object[]]$PortGroups,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VdsName
    )

    Write-LogMessage -Type DEBUG -Message "Entered Set-VirtualDistributedSwitch function..."

    $connectionTest = Test-VcenterConnection
    if (-not $connectionTest.IsConnected) {
        Write-LogMessage -Type ERROR -Message "Not connected to vCenter `"$Script:vCenterName`": $($connectionTest.ErrorMessage)"
        throw [VcfDeploymentException]::new("Not connected to vCenter `"$Script:vCenterName`": $($connectionTest.ErrorMessage)")
    }

    $numUplinksInt = [int]$NumUplinks
    if ($numUplinksInt -ne 2 -and $numUplinksInt -ne 4) {
        Write-LogMessage -Type ERROR -Message "Set-VirtualDistributedSwitch requires NumUplinks 2 or 4. Got: $NumUplinks."
        throw [VcfDeploymentException]::new("Deployment failed. NumUplinks must be 2 or 4. Check logs for details.")
    }

    # Derive edge suffix from VdsName (e.g. VDS-VMFS -> VMFS, VDS-VMFS-sw1 -> VMFS) so management and port group names are unique per edge.
    $edgeSuffixFromVds = ($VdsName -replace '^VDS-', '') -replace '-sw[12]$', ''
    $managementPortGroupName = "mgmt-" + $edgeSuffixFromVds

    try {

        # Get datacenter, cluster, and host objects.
        $datacenterObject = Get-Datacenter -Name $DatacenterName -Server $Script:vCenterName
        $clusterObject = Get-Cluster -Name $ClusterName -Server $Script:vCenterName
        $hosts = @(Get-VMHost -Location $clusterObject -Server $Script:vCenterName)
        if (-not $hosts -or $hosts.Count -eq 0) {
            Write-LogMessage -Type ERROR -Message "Cluster `"$ClusterName`" has no hosts."
            throw [VcfDeploymentException]::new("Cluster `"$ClusterName`" has no hosts.")
        }

        # Normalize NicList to adapter names.
        $allNicNames = @()
        foreach ($item in $NicList) {
            $name = if ($item -is [String]) { $item.Trim() } else { $item.Name }
            if (-not [String]::IsNullOrWhiteSpace($name)) {
                $allNicNames += $name
            }
        }
        if (-not $allNicNames -or $allNicNames.Count -eq 0) {
            Write-LogMessage -Type ERROR -Message "NicList is empty or has no valid adapter names."
            throw [VcfDeploymentException]::new("Deployment failed. NicList must specify at least one physical NIC. Check logs for details.")
        }

        # Ensure NICs that will be connected to the VDS are link-connected before creating the VDS. Fail fast with a clear error.
        foreach ($vmHost in $hosts) {
            $hostDisplay = if ($vmHost.Name) { $vmHost.Name } else { [String]$vmHost }
            if ($numUplinksInt -eq 2) {
                $disconnected = @($allNicNames | Where-Object { -not (Test-PhysicalNicConnected -NicName $_ -Server $Script:vCenterName -VMHost $vmHost) })
                if ($disconnected.Count -gt 0) {
                    $nicListStr = $disconnected -join ", "
                    Write-LogMessage -Type ERROR -Message "Cannot create VDS `"$VdsName`": physical NIC(s) $nicListStr on host `"$hostDisplay`" are not connected (link down). Connect the cable(s) or fix the link before creating the VDS."
                    throw [VcfDeploymentException]::new("Deployment failed. VDS `"$VdsName`" requires connected NIC(s) on each host. Host `"$hostDisplay`" has disconnected NIC(s): $nicListStr. Check logs for details.")
                }
            } else {
                $nicListFirstTwo = @($allNicNames | Select-Object -First 2)
                $nicListLastTwo = @($allNicNames | Select-Object -Skip 2 -First 2)
                $disconnectedSw1 = @($nicListFirstTwo | Where-Object { -not (Test-PhysicalNicConnected -NicName $_ -Server $Script:vCenterName -VMHost $vmHost) })
                $disconnectedSw2 = @($nicListLastTwo | Where-Object { -not (Test-PhysicalNicConnected -NicName $_ -Server $Script:vCenterName -VMHost $vmHost) })
                if ($disconnectedSw1.Count -gt 0) {
                    $nicListStr = $disconnectedSw1 -join ", "
                    Write-LogMessage -Type ERROR -Message "Cannot create VDS `"$VdsName-sw1`": physical NIC(s) $nicListStr on host `"$hostDisplay`" are not connected (link down). Connect the cable(s) or fix the link before creating the VDS."
                    throw [VcfDeploymentException]::new("Deployment failed. VDS `"$VdsName-sw1`" requires connected NIC(s) on each host. Host `"$hostDisplay`" has disconnected NIC(s): $nicListStr. Check logs for details.")
                }
                if ($disconnectedSw2.Count -gt 0) {
                    $nicListStr = $disconnectedSw2 -join ", "
                    Write-LogMessage -Type ERROR -Message "Cannot create VDS `"$VdsName-sw2`": physical NIC(s) $nicListStr on host `"$hostDisplay`" are not connected (link down). Connect the cable(s) or fix the link before creating the VDS."
                    throw [VcfDeploymentException]::new("Deployment failed. VDS `"$VdsName-sw2`" requires connected NIC(s) on each host. Host `"$hostDisplay`" has disconnected NIC(s): $nicListStr. Check logs for details.")
                }
            }
        }

        if ($numUplinksInt -eq 2) {
            # One VDS: create, add hosts, migrate mgmt from vSS to VDS per host, then create port groups.
            $null = Invoke-VDSCreation -DatacenterObject $datacenterObject -Mtu $Mtu -NumUplinks "2" -VdsName $VdsName
            foreach ($vmHost in $hosts) {
                $result = Add-HostToVDS -Hostname $vmHost -VdsName $VdsName
                if ($result -and -not $result.Success) {
                    Write-LogMessage -Type ERROR -Message "Failed to add host `"$vmHost`" to VDS `"$VdsName`": $($result.ErrorMessage)"
                    throw [VcfDeploymentException]::new("Failed to add host `"$vmHost`" to VDS `"$VdsName`": $($result.ErrorMessage)")
                }
            }
            Write-LogMessage -Type INFO -NoNewline -Message "Migrating management (vmk0) to VDS `"$VdsName`" for $($hosts.Count) host(s)... "
            foreach ($vmHost in $hosts) {
                Invoke-MigrateHostManagementToVds -VMHost $vmHost -VdsName $VdsName -NicList $NicList -ManagementPortGroupName $managementPortGroupName
            }
            Write-LogMessage -Type INFO -CompletePending -Message "Done"
            $result = New-VDSPortGroups -PortGroups $PortGroups -VdsName $VdsName
            if ($result -and -not $result.Success) {
                Write-LogMessage -Type ERROR -Message "Failed to create VDS port groups on `"$VdsName`": $($result.ErrorMessage)"
                throw [VcfDeploymentException]::new("Failed to create VDS port groups on `"$VdsName`": $($result.ErrorMessage)")
            }
            Set-VDSUplinkTeamingActiveStandby -VdsName $VdsName
        } else {
            # Four NICs: two VDS (-sw1, -sw2). First VDS gets mgmt + guest; second gets remaining two NICs (for vMotion/vSAN later).
            $vdsNameSw1 = "$VdsName-sw1"
            $vdsNameSw2 = "$VdsName-sw2"
            $null = Invoke-VDSCreation -DatacenterObject $datacenterObject -Mtu $Mtu -NumUplinks "2" -VdsName $vdsNameSw1
            $vdsObjectSw2 = Invoke-VDSCreation -DatacenterObject $datacenterObject -Mtu $Mtu -NumUplinks "2" -VdsName $vdsNameSw2
            foreach ($vmHost in $hosts) {
                $result = Add-HostToVDS -Hostname $vmHost -VdsName $vdsNameSw1
                if ($result -and -not $result.Success) {
                    Write-LogMessage -Type ERROR -Message "Failed to add host `"$vmHost`" to VDS `"$vdsNameSw1`": $($result.ErrorMessage)"
                    throw [VcfDeploymentException]::new("Failed to add host `"$vmHost`" to VDS `"$vdsNameSw1`": $($result.ErrorMessage)")
                }
                $result = Add-HostToVDS -Hostname $vmHost -VdsName $vdsNameSw2
                if ($result -and -not $result.Success) {
                    Write-LogMessage -Type ERROR -Message "Failed to add host `"$vmHost`" to VDS `"$vdsNameSw2`": $($result.ErrorMessage)"
                    throw [VcfDeploymentException]::new("Failed to add host `"$vmHost`" to VDS `"$vdsNameSw2`": $($result.ErrorMessage)")
                }
            }
            $nicListFirstTwo = @($NicList | Select-Object -First 2)
            Write-LogMessage -Type INFO -NoNewline -Message "Migrating management (vmk0) to VDS `"$vdsNameSw1`" for $($hosts.Count) host(s)... "
            foreach ($vmHost in $hosts) {
                Invoke-MigrateHostManagementToVds -VMHost $vmHost -VdsName $vdsNameSw1 -NicList $nicListFirstTwo -ManagementPortGroupName $managementPortGroupName
            }
            Write-LogMessage -Type INFO -CompletePending -Message "Done"
            $nicListLastTwo = @($NicList | Select-Object -Skip 2 -First 2)
            foreach ($vmHost in $hosts) {
                $result = Add-PhysicalAdaptersToVDS -Hostname $vmHost -NicList $nicListLastTwo -VdsName $vdsNameSw2 -VdsObject $vdsObjectSw2
                if ($result -and -not $result.Success) {
                    Write-LogMessage -Type ERROR -Message "Failed to add physical adapters for host `"$vmHost`" to VDS `"$vdsNameSw2`": $($result.ErrorMessage)"
                    throw [VcfDeploymentException]::new("Failed to add physical adapters for host `"$vmHost`" to VDS `"$vdsNameSw2`": $($result.ErrorMessage)")
                }
            }
            # Network segment (guest) port groups on first VDS only.
            $result = New-VDSPortGroups -PortGroups $PortGroups -VdsName $vdsNameSw1
            if ($result -and -not $result.Success) {
                Write-LogMessage -Type ERROR -Message "Failed to create VDS port groups on `"$vdsNameSw1`": $($result.ErrorMessage)"
                throw [VcfDeploymentException]::new("Failed to create VDS port groups on `"$vdsNameSw1`": $($result.ErrorMessage)")
            }
            Set-VDSUplinkTeamingActiveStandby -VdsName $vdsNameSw1
            Set-VDSUplinkTeamingActiveStandby -VdsName $vdsNameSw2
        }
    } catch [System.UnauthorizedAccessException] {
        Write-LogMessage -Type ERROR -Message "Cannot configure distributed switch `"$VdsName`" due to authorization issues: $($_.Exception.Message)"
        throw [VcfDeploymentException]::new("Cannot configure distributed switch `"$VdsName`" due to authorization issues: $($_.Exception.Message)")
    } catch [System.TimeoutException] {
        Write-LogMessage -Type ERROR -Message "Cannot configure distributed switch `"$VdsName`" due to network/timeout issues: $($_.Exception.Message)"
        throw [VcfDeploymentException]::new("Cannot configure distributed switch `"$VdsName`" due to network/timeout issues: $($_.Exception.Message)")
    } catch [VcfDeploymentException] {
        throw  # already logged and typed — propagate without re-wrapping
    } catch {
        Write-LogMessage -Type ERROR -Message "Failed to configure distributed switch `"$VdsName`": $($_.Exception.Message)"
        throw [VcfDeploymentException]::new("Failed to configure distributed switch `"$VdsName`": $($_.Exception.Message)")
    }
}
Function Set-StoragePolicy {

    <#
        .SYNOPSIS
        Creates a tag-based storage policy for VMFS, vSAN-OSA, or vSAN-ESA datastores.

        .DESCRIPTION
        This function creates or updates a VMware Storage Policy-Based Management (SPBM) storage policy
        for VMFS, vSAN-OSA, or vSAN-ESA datastores using tag-based rules. For VMFS storage, it configures
        volume allocation rules combined with vSphere tag requirements. For vSAN storage types (OSA and ESA),
        it creates tag-based placement rules only (vSAN policies do not use volume allocation rules).
        The function checks if the policy already exists and if the specified tag is already present.
        If the policy exists but the tag is missing, the function will add the tag to the existing policy
        without removing existing tags. This allows multiple tags to be added to a single storage policy
        over time. The function includes comprehensive error handling for authorization and network timeout scenarios.

        For VMFS storage, the policy will have both volume allocation capabilities and tag-based placement rules.
        For vSAN storage, the policy will have tag-based placement rules only.

        .EXAMPLE
        Set-StoragePolicy -PolicyName "VMFS-Storage-Policy" -StorageType "VMFS" -RuleValue "Conserve space when possible" -TagName "Production" -TagCatalog "Environment"

        Creates a VMFS storage policy named "VMFS-Storage-Policy" with space conservation rule and Production tag requirement.

        .EXAMPLE
        Set-StoragePolicy -PolicyName "vSAN-ESA-Policy" -StorageType "vSAN-ESA" -TagName "Production" -TagCatalog "Environment"

        Creates a vSAN ESA storage policy named "vSAN-ESA-Policy" with Production tag requirement (no volume allocation rule).

        .EXAMPLE
        Set-StoragePolicy -PolicyName "vSAN-OSA-Policy" -StorageType "vSAN-OSA" -TagName "Site1" -TagCatalog "Location"

        Creates a vSAN OSA storage policy named "vSAN-OSA-Policy" with Site1 tag requirement.

        .EXAMPLE
        Set-StoragePolicy -PolicyName "VMFS-Storage-Policy" -StorageType "VMFS" -TagName "test-sn2" -TagCatalog "Site"

        Adds an additional tag "test-sn2" from catalog "Site" to the existing "VMFS-Storage-Policy" policy. VMFS uses default rule "Fully initialized".

        .PARAMETER PolicyName
        The name of the storage policy to create. Must be a non-empty string.

        .PARAMETER RuleValue
        The volume allocation rule for VMFS storage type only. Default is "Fully initialized" (thick eager-zeroed). Optional; valid values: "Conserve space when possible", "Fully initialized", "Reserve space".

        .PARAMETER StorageType
        The type of storage policy to create. Valid values are: "VMFS", "vSAN-OSA", "vSAN-ESA".

        .PARAMETER TagCatalog
        The name of the vSphere tag catalog/category that contains the required tag. The catalog must exist and contain the specified tag.

        .PARAMETER TagName
        The name of the vSphere tag that must be associated with storage for this policy. The tag must exist in the specified tag catalog.

        .NOTES
        - Requires connection to vCenter via PowerCLI
        - Uses VMware Storage Policy-Based Management (SPBM) cmdlets
        - Requires vSphere tags to be configured and assigned to storage resources
        - The specified tag and tag catalog must exist before running this function
        - For VMFS storage, RuleValue defaults to "Fully initialized" if not specified; for vSAN it is not used.
        - Logs all operations and errors using Write-LogMessage function
        - VMFS storage policy combines volume allocation rule and tag-based placement; vSAN uses tag-based placement only.
        - When updating an existing policy, tag rules that reference deleted tags (vSphere shows as " (missing)") are normalized: the suffix is stripped and the real tag is looked up by name and category; empty or stale references are skipped.
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

    $connectionTest = Test-VcenterConnection
    if (-not $connectionTest.IsConnected) {
        Write-LogMessage -Type ERROR -Message "Not connected to vCenter `"$Script:vCenterName`": $($connectionTest.ErrorMessage)"
        throw [VcfDeploymentException]::new("Not connected to vCenter `"$Script:vCenterName`": $($connectionTest.ErrorMessage)")
    }

    try {
        # Get the tag object first, as we need it for both checking and creating.
        $tagObject = Get-Tag -Name $TagName -Category $TagCatalog -Server $Script:vCenterName -ErrorAction Stop

        # Check if the policy already exists.
        $policy = Get-SpbmStoragePolicy -Name $PolicyName -Server $Script:vCenterName -ErrorAction SilentlyContinue

        if ($policy) {
            # Policy exists, check if the tag is already in the policy.
            $policyWithTag = Get-SpbmStoragePolicy -Name $PolicyName -Tag $tagObject -Server $Script:vCenterName -ErrorAction SilentlyContinue

            if ($policyWithTag) {
                Write-LogMessage -Type DEBUG -Message "Storage policy `"$PolicyName`" already contains tag `"$TagName`" from catalog `"$TagCatalog`". Skipping tag add."
                return
            }

            # Tag doesn't exist in policy, so we need to add it.
            Write-LogMessage -Type INFO -Message "Storage policy `"$PolicyName`" exists but does not contain tag `"$TagName`". Adding tag to existing policy."

            # Get the volume allocation capability only for VMFS storage type.
            $volumeAllocationCapability = $null
            if ($StorageType -eq "VMFS") {
                $volumeAllocationCapability = Get-SpbmCapability -Name "com.vmware.storage.volumeallocation.VolumeAllocationType" -Server $Script:vCenterName -ErrorAction Stop
            }

            # Create a new tag rule for the tag we want to add.
            $newTagRule = New-SpbmRule -AnyOfTags $tagObject -Server $Script:vCenterName -ErrorAction Stop

            # Extract existing rule sets from the policy.
            $existingRuleSets = $policy.AnyOfRuleSets
            $updatedRuleSets = [System.Collections.Generic.List[object]]::new()

            # Check if policy has any rule sets.
            if (-not $existingRuleSets -or $existingRuleSets.Count -eq 0) {
                Write-LogMessage -Type DEBUG -Message "Policy `"$PolicyName`" has no existing rule sets. Creating new rule set with tag."
                # If no rule sets exist, create appropriate rules based on storage type.
                if ($StorageType -eq "VMFS") {
                    # For VMFS, include volume allocation capability rule.
                    $capabilityRule = New-SpbmRule -Capability $volumeAllocationCapability -Value $RuleValue -Server $Script:vCenterName -ErrorAction Stop
                    $ruleSet = New-SpbmRuleSet -AllOfRules $capabilityRule, $newTagRule -ErrorAction Stop
                } else {
                    # For vSAN, use tag rule only.
                    $ruleSet = New-SpbmRuleSet -AllOfRules $newTagRule -ErrorAction Stop
                }
                $updatedRuleSets.Add($ruleSet)
            } else {
                # Process each existing rule set.
                foreach ($ruleSet in $existingRuleSets) {
                    if (-not $ruleSet -or -not $ruleSet.AllOfRules) {
                        Write-LogMessage -Type WARNING -Message "Rule set in policy `"$PolicyName`" has no AllOfRules. Skipping this rule set."
                        continue
                    }
                    $existingRules = $ruleSet.AllOfRules
                    $updatedRules = [System.Collections.Generic.List[object]]::new()
                    $tagRules = [System.Collections.Generic.List[object]]::new()
                    $existingCapabilityRuleValue = $null

                    # Separate capability rules from tag rules.
                    # Extract the existing capability rule value to preserve it.
                    foreach ($rule in $existingRules) {
                        if (-not $rule) {
                            Write-LogMessage -Type DEBUG -Message "Skipping null rule in policy `"$PolicyName`"."
                            continue
                        }
                        if ($rule.Capability -and $rule.Capability.Name -eq "com.vmware.storage.volumeallocation.VolumeAllocationType") {
                            # Extract the existing capability rule value to preserve it.
                            $existingCapabilityRuleValue = $rule.Value
                        }
                        elseif ($rule.AnyOfTags) {
                            # Collect existing tag rules - we'll extract tags from these and recreate the rule.
                            $tagRules.Add($rule)
                        }
                        else {
                            # For other rule types, we need to recreate them to avoid format issues.
                            # Extract the capability and value, then recreate the rule.
                            if ($rule.Capability -and $rule.Value) {
                                try {
                                    $recreatedRule = New-SpbmRule -Capability $rule.Capability -Value $rule.Value -Server $Script:vCenterName -ErrorAction Stop
                                    $updatedRules.Add($recreatedRule)
                                } catch {
                                    Write-LogMessage -Type WARNING -Message "Could not recreate rule with capability `"$($rule.Capability.Name)`". Skipping this rule."
                                }
                            }
                        }
                    }

                    # Recreate the capability rule only for VMFS storage type.
                    if ($StorageType -eq "VMFS" -and $volumeAllocationCapability) {
                        $capabilityRuleValue = $existingCapabilityRuleValue
                        if (-not $capabilityRuleValue) {
                            $capabilityRuleValue = $RuleValue
                        }
                        $capabilityRule = New-SpbmRule -Capability $volumeAllocationCapability -Value $capabilityRuleValue -Server $Script:vCenterName -ErrorAction Stop
                        $updatedRules.Add($capabilityRule)
                    }

                    # Combine existing tag rules with the new tag rule.
                    if ($tagRules.Count -gt 0) {
                        # Extract all tags from existing tag rules and combine with new tag.
                        $allTags = [System.Collections.Generic.List[object]]::new()
                        $existingTagIds = [System.Collections.Generic.HashSet[string]]::new()  # Track tag IDs to avoid duplicates by reference

                        foreach ($tagRule in $tagRules) {
                            # Add all tags from this rule to our collection.
                            # Handle both single tag and array of tags.
                            # IMPORTANT: Extract tag names and retrieve fresh tag objects to ensure proper format.
                            if ($tagRule.AnyOfTags) {
                                $tagsToProcess = if ($tagRule.AnyOfTags -is [Array]) { $tagRule.AnyOfTags } else { @($tagRule.AnyOfTags) }

                                foreach ($tag in $tagsToProcess) {
                                    if ($tag) {
                                        # Extract tag name and category from the extracted tag object.
                                        $extractedTagName = $null
                                        $extractedTagCategory = $null

                                        if ($tag.Name) {
                                            # Strip vSphere " (missing)" suffix used for deleted/orphaned tag references so we look up the real tag name.
                                            $extractedTagName = ($tag.Name -replace ' \(missing\)$', '').Trim()
                                        }

                                        if ($tag.Category) {
                                            if ($tag.Category.Name) {
                                                $extractedTagCategory = ($tag.Category.Name -replace ' \(missing\)$', '').Trim()
                                            } elseif ($tag.Category -is [string]) {
                                                $extractedTagCategory = ($tag.Category -replace ' \(missing\)$', '').Trim()
                                            }
                                        }

                                        # Skip stale references: tag name or category became empty after stripping "(missing)".
                                        if ([String]::IsNullOrWhiteSpace($extractedTagName)) {
                                            Write-LogMessage -Type DEBUG -Message "Skipping tag rule with empty or stale (missing) tag name in policy `"$PolicyName`"."
                                            continue
                                        }

                                        # If we have both name and category, retrieve a fresh tag object to ensure proper format.
                                        if ($extractedTagName -and $extractedTagCategory) {
                                            try {
                                                $freshTag = Get-Tag -Name $extractedTagName -Category $extractedTagCategory -Server $Script:vCenterName -ErrorAction Stop
                                                if ($freshTag) {
                                                    # Use tag ID for comparison to handle different object instances of the same tag.
                                                    $tagIdentifier = $null
                                                    if ($freshTag.Id) {
                                                        $tagIdentifier = $freshTag.Id
                                                    } elseif ($freshTag.Name -and $freshTag.Category) {
                                                        $tagIdentifier = "$($freshTag.Category.Name):$($freshTag.Name)"
                                                    } elseif ($freshTag.Name) {
                                                        $tagIdentifier = $freshTag.Name
                                                    }

                                                    if ($tagIdentifier -and $existingTagIds.Add($tagIdentifier)) {
                                                        $allTags.Add($freshTag)
                                                    }
                                                }
                                            } catch {
                                                Write-LogMessage -Type WARNING -Message "Could not retrieve fresh tag object for `"$extractedTagName`" in category `"$extractedTagCategory`": $($_.Exception.Message)"
                                            }
                                        } elseif ($extractedTagName) {
                                            # Fallback: try to find tag by name only (less reliable).
                                            try {
                                                $freshTag = Get-Tag -Name $extractedTagName -Server $Script:vCenterName -ErrorAction Stop
                                                if ($freshTag) {
                                                    $tagIdentifier = if ($freshTag.Id) { $freshTag.Id } else { $freshTag.Name }
                                                    if ($tagIdentifier -and $existingTagIds.Add($tagIdentifier)) {
                                                        $allTags.Add($freshTag)
                                                    }
                                                }
                                            } catch {
                                                Write-LogMessage -Type WARNING -Message "Could not retrieve tag `"$extractedTagName`" by name: $($_.Exception.Message)"
                                            }
                                        } else {
                                            Write-LogMessage -Type WARNING -Message "Skipping tag with missing name or category information."
                                        }
                                    }
                                }
                            }
                        }
                        # Add the new tag if it's not already in the collection (by ID or Name+Category).
                        $newTagIdentifier = $null
                        if ($tagObject.Id) {
                            $newTagIdentifier = $tagObject.Id
                        } elseif ($tagObject.Name -and $tagObject.Category) {
                            $newTagIdentifier = "$($tagObject.Category.Name):$($tagObject.Name)"
                        } elseif ($tagObject.Name) {
                            $newTagIdentifier = $tagObject.Name
                        }

                        if ($newTagIdentifier -and $existingTagIds.Add($newTagIdentifier)) {
                            $allTags.Add($tagObject)
                        }

                        # SPBM requires all tags in a rule to be from the same category. Keep only tags in the same category as the tag we are adding.
                        $targetCategoryName = $null
                        if ($tagObject.Category) {
                            $targetCategoryName = if ($tagObject.Category.Name) { $tagObject.Category.Name } else { $tagObject.Category }
                        }
                        if ($targetCategoryName) {
                            $allTagsSameCategory = @($allTags | Where-Object {
                                $cat = $_.Category
                                $catName = if ($cat.Name) { $cat.Name } else { $cat }
                                $catName -eq $targetCategoryName
                            })
                            if ($allTagsSameCategory.Count -lt $allTags.Count) {
                                Write-LogMessage -Type DEBUG -Message "Filtered tag rule to same category `"$targetCategoryName`" ($($allTagsSameCategory.Count) tag(s)); omitted $($allTags.Count - $allTagsSameCategory.Count) tag(s) from other categories."
                            }
                            $allTags = [System.Collections.Generic.List[object]]$allTagsSameCategory
                        }

                        # Only create combined rule if we have tags (all same category).
                        if ($allTags.Count -gt 0) {
                            try {
                                # Create combined tag rule with all unique tags (same category).
                                $combinedTagRule = New-SpbmRule -AnyOfTags $allTags -Server $Script:vCenterName -ErrorAction Stop
                                $updatedRules.Add($combinedTagRule)
                            } catch [VcfDeploymentException] {
                                throw  # already logged and typed — propagate without re-wrapping
                            } catch {
                                Write-LogMessage -Type ERROR -Message "Failed to create combined tag rule with $($allTags.Count) tag(s): $($_.Exception.Message)"
                                $tagDetailsList = $allTags | ForEach-Object { "Name=$($_.Name), Id=$($_.Id), Category=$($_.Category.Name)" }
                                $tagDetailsString = $tagDetailsList -join '; '
                                Write-LogMessage -Type ERROR -Message "Tag details: $tagDetailsString"
                                throw [VcfDeploymentException]::new("Tag details: $tagDetailsString")
                            }
                        } else {
                            Write-LogMessage -Type WARNING -Message "No valid tags found in existing tag rules (same category). Adding new tag rule separately."
                            $updatedRules.Add($newTagRule)
                        }
                    }
                    else {
                        # No existing tag rules, just add the new one.
                        $updatedRules.Add($newTagRule)
                    }

                    # Only create rule set if we have rules.
                    if ($updatedRules.Count -gt 0) {
                        try {
                            # Create updated rule set with all rules.
                            $updatedRuleSet = New-SpbmRuleSet -AllOfRules $updatedRules -ErrorAction Stop
                            $updatedRuleSets.Add($updatedRuleSet)
                        } catch [VcfDeploymentException] {
                            throw  # already logged and typed — propagate without re-wrapping
                        } catch {
                            Write-LogMessage -Type ERROR -Message "Failed to create rule set with $($updatedRules.Count) rule(s): $($_.Exception.Message)"
                            $ruleDetailsList = $updatedRules | ForEach-Object { "Type=$($_.GetType().FullName), Capability=$($_.Capability), AnyOfTags=$($_.AnyOfTags)" }
                            $ruleDetailsString = $ruleDetailsList -join '; '
                            Write-LogMessage -Type ERROR -Message "Rule details: $ruleDetailsString"
                            throw [VcfDeploymentException]::new("Rule details: $ruleDetailsString")
                        }
                    } else {
                        Write-LogMessage -Type WARNING -Message "No rules to add to rule set in policy `"$PolicyName`". Skipping this rule set."
                    }
                }
            }

            # If no rule sets were created/updated (e.g., all were skipped or policy had none), create a new one.
            if ($updatedRuleSets.Count -eq 0) {
                try {
                    if ($StorageType -eq "VMFS" -and $volumeAllocationCapability) {
                        # For VMFS, include both capability rule and tag rule.
                        $capabilityRule = New-SpbmRule -Capability $volumeAllocationCapability -Value $RuleValue -Server $Script:vCenterName -ErrorAction Stop
                        $ruleSet = New-SpbmRuleSet -AllOfRules $capabilityRule, $newTagRule -ErrorAction Stop
                    } else {
                        # For vSAN, use tag rule only.
                        $ruleSet = New-SpbmRuleSet -AllOfRules $newTagRule -ErrorAction Stop
                    }
                    $updatedRuleSets.Add($ruleSet)
                } catch [VcfDeploymentException] {
                    throw  # already logged and typed — propagate without re-wrapping
                } catch {
                    Write-LogMessage -Type ERROR -Message "Failed to create new rule set: $($_.Exception.Message)"
                    throw [VcfDeploymentException]::new("Failed to create new rule set: $($_.Exception.Message)")
                }
            }

            # Update the policy with the modified rule sets.
            try {
                $null = Set-SpbmStoragePolicy -StoragePolicy $policy -AnyOfRuleSets $updatedRuleSets -Server $Script:vCenterName -ErrorAction Stop
                Write-LogMessage -Type INFO -Message "Successfully added tag `"$TagName`" from catalog `"$TagCatalog`" to storage policy `"$PolicyName`"."
            } catch {
                $errorMessage = $_.Exception.Message
                Write-LogMessage -Type ERROR -Message "Failed to update storage policy `"$PolicyName`": $errorMessage"

                if ($errorMessage -match "invalid format") {
                    Write-LogMessage -Type ERROR -Message "Invalid format error detected. Diagnostic information:"
                    Write-LogMessage -Type ERROR -Message "  - Number of rule sets: $($updatedRuleSets.Count)"
                    Write-LogMessage -Type ERROR -Message "  - Tag being added: `"$TagName`" from catalog `"$TagCatalog`""
                    Write-LogMessage -Type ERROR -Message "  - Tag object type: $($tagObject.GetType().FullName)"
                    Write-LogMessage -Type ERROR -Message "  - Tag object properties: Name=$($tagObject.Name), Id=$($tagObject.Id), Category=$($tagObject.Category.Name)"
                    Write-Host ""
                    Write-LogMessage -Type ERROR -Message "This error typically occurs when:"
                    Write-LogMessage -Type ERROR -Message "  1. Tag objects are not properly formatted or are missing required properties."
                    Write-LogMessage -Type ERROR -Message "  2. Rule objects cannot be reused and must be recreated."
                    Write-LogMessage -Type ERROR -Message "  3. Rule sets contain incompatible rule combinations."
                    Write-Host ""
                    Write-LogMessage -Type ERROR -Message "SOLUTION:"
                    Write-LogMessage -Type ERROR -Message "  1. Check the existing storage policy in vCenter UI: Menu > Policies and Profiles > VM Storage Policies"
                    Write-LogMessage -Type ERROR -Message "  2. Verify the policy's tag rules are valid."
                    Write-LogMessage -Type ERROR -Message "  3. Check that tag `"$TagName`" exists in catalog `"$TagCatalog`""
                    Write-LogMessage -Type ERROR -Message "  4. Consider manually adding the tag to the policy via vCenter UI"
                    Write-LogMessage -Type ERROR -Message "  5. Alternatively, delete and recreate the storage policy."
                    throw [VcfDeploymentException]::new("  5. Alternatively, delete and recreate the storage policy.")
                } else {
                    throw
                }
            }
        }
        else {
            # Policy doesn't exist, create a new one.
            $tagRule = New-SpbmRule -AnyOfTags $tagObject -Server $Script:vCenterName -ErrorAction Stop

            # Create rule set based on storage type.
            if ($StorageType -eq "VMFS") {
                # For VMFS, include volume allocation capability rule (default "Fully initialized").
                $volumeAllocationCapability = Get-SpbmCapability -Name "com.vmware.storage.volumeallocation.VolumeAllocationType" -Server $Script:vCenterName -ErrorAction Stop
                $capabilityRule = New-SpbmRule -Capability $volumeAllocationCapability -Value $RuleValue -Server $Script:vCenterName -ErrorAction Stop
                $ruleSet = New-SpbmRuleSet -AllOfRules $capabilityRule, $tagRule -ErrorAction Stop
                $description = "$StorageType with $RuleValue"
            } else {
                # For vSAN, use tag rule only.
                $ruleSet = New-SpbmRuleSet -AllOfRules $tagRule -ErrorAction Stop
                $description = "$StorageType tag-based policy"
            }

            # Create policy.
            New-SpbmStoragePolicy -Name $PolicyName `
                -Description $description `
                -AnyOfRuleSets $ruleSet -Server $Script:vCenterName | Out-Null

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
        Write-LogMessage -Type ERROR -Message "Cannot create storage policy `"$PolicyName`" due to authorization issues: $($_.Exception.Message)"
        throw [VcfDeploymentException]::new("Cannot create storage policy `"$PolicyName`" due to authorization issues: $($_.Exception.Message)")
    }
    catch [System.TimeoutException] {
        Write-LogMessage -Type ERROR -Message "Cannot create storage policy `"$PolicyName`" due to network/timeout issues: $($_.Exception.Message)"
        throw [VcfDeploymentException]::new("Cannot create storage policy `"$PolicyName`" due to network/timeout issues: $($_.Exception.Message)")
    } catch [VcfDeploymentException] {
        throw  # already logged and typed — propagate without re-wrapping
    } catch {
        Write-LogMessage -Type ERROR -Message "Failed to create storage policy `"$PolicyName`": $($_.Exception.Message)"
        throw [VcfDeploymentException]::new("Failed to create storage policy `"$PolicyName`": $($_.Exception.Message)")
    }
}
Function Get-SupervisorControlPlaneIp {

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

    Param (
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$ClusterName
    )
    Write-LogMessage -Type DEBUG -Message "Entered Get-SupervisorControlPlaneIp function..."

    $connectionTest = Test-VcenterConnection
    if (-not $connectionTest.IsConnected) {
        Write-LogMessage -Type ERROR -Message "Not connected to vCenter `"$Script:vCenterName`": $($connectionTest.ErrorMessage)"
        throw [VcfDeploymentException]::new("Not connected to vCenter `"$Script:vCenterName`": $($connectionTest.ErrorMessage)")
    }

    try {
        # Get all Supervisor Control Plane VMs in the given cluster.
        $controlPlaneVMs = Get-Cluster -Name $ClusterName -Server $Script:vCenterName |
        Get-VM |
        Where-Object { $_.Name -like "*SupervisorControlPlane*" }  # Adjust pattern if needed

        # Ensure we have exactly one VM.
        $controlPlaneVMsArray = @($controlPlaneVMs)
        if ($controlPlaneVMsArray.Count -eq 0) {
            Write-LogMessage -Type ERROR -Message "No Supervisor Control Plane VM found in cluster `"$ClusterName`""
            throw [VcfDeploymentException]::new("No Supervisor Control Plane VM found in cluster `"$ClusterName`"")
        }
        if ($controlPlaneVMsArray.Count -gt 1) {
            Write-LogMessage -Type WARNING -Message "Multiple Supervisor Control Plane VMs found in cluster `"$ClusterName`" ($($controlPlaneVMsArray.Count)). Using the first one: $($controlPlaneVMsArray[0].Name)"
        }
        $controlPlaneVM = $controlPlaneVMsArray[0]

        $vmView = Get-View $controlPlaneVM.Id

        # Get IPv4 address - ensure we only return a single IP address.
        # Force $ipAddresses to be an array to handle single-item results correctly.
        $ipAddresses = @($vmView.Guest.IPAddress | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' })
        if ($ipAddresses.Count -eq 0) {
            Write-LogMessage -Type ERROR -Message "No IPv4 address found for Supervisor Control Plane VM `"$($controlPlaneVM.Name)`" in cluster `"$ClusterName`""
            throw [VcfDeploymentException]::new("No IPv4 address found for Supervisor Control Plane VM `"$($controlPlaneVM.Name)`" in cluster `"$ClusterName`"")
        }
        if ($ipAddresses.Count -gt 1) {
            Write-LogMessage -Type WARNING -Message "Supervisor Control Plane VM `"$($controlPlaneVM.Name)`" has multiple IPv4 addresses: $($ipAddresses -join ', '). Using the first one: $($ipAddresses[0])"
        }
        $ip = $ipAddresses[0]
        Write-LogMessage -Type DEBUG -Message "Selected Supervisor Control Plane IP: $ip"
        return $ip

    } catch [System.UnauthorizedAccessException] {
        Write-LogMessage -Type ERROR -Message "Cannot fetch Supervisor Control Plane VM details on cluster `"$ClusterName`" attached to vCenter `"$Script:vCenterName`" due to authorization issues: $($_.Exception.Message)"
        throw [VcfDeploymentException]::new("Cannot fetch Supervisor Control Plane VM details on cluster `"$ClusterName`" attached to vCenter `"$Script:vCenterName`" due to authorization issues: $($_.Exception.Message)")
    }
    catch [System.TimeoutException] {
        Write-LogMessage -Type ERROR -Message "Cannot fetch Supervisor Control Plane VM details on cluster `"$ClusterName`" attached to vCenter `"$Script:vCenterName`" due to network/timeout issues: $($_.Exception.Message)"
        throw [VcfDeploymentException]::new("Cannot fetch Supervisor Control Plane VM details on cluster `"$ClusterName`" attached to vCenter `"$Script:vCenterName`" due to network/timeout issues: $($_.Exception.Message)")
    } catch [VcfDeploymentException] {
        throw  # already logged and typed — propagate without re-wrapping
    } catch {
        Write-LogMessage -Type ERROR -Message "Supervisor Control Plane VM details on cluster `"$ClusterName`" attached to vCenter `"$Script:vCenterName`" could not be fetched: $($_.Exception.Message)"
        throw [VcfDeploymentException]::new("Supervisor Control Plane VM details on cluster `"$ClusterName`" attached to vCenter `"$Script:vCenterName`" could not be fetched: $($_.Exception.Message)")
    }
}
Function Set-VCFContextCreate {

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
    Write-LogMessage -Type DEBUG -Message "Context name: `"$ContextName`""
    Write-LogMessage -Type DEBUG -Message "Endpoint: `"$Endpoint`""
    Write-LogMessage -Type DEBUG -Message "SSO username: `"$SsoUsername`""
    if (-not [String]::IsNullOrWhiteSpace($Namespace)) {
        Write-LogMessage -Type DEBUG -Message "Namespace (for context switch): `"$Namespace`""
    }

    try {
        # Step 1: Always delete the context (VCF CLI handles "not found" gracefully).
        Write-LogMessage -Type DEBUG -Message "Deleting VCF context `"$ContextName`" (if it exists)..."
        $deleteArgs = @("context", "delete", $ContextName, "-y")
        Write-LogMessage -Type DEBUG -Message "VCF CLI delete command: $($Script:VcfCmd) $($deleteArgs -join ' ')"
        $deleteOutput = & $Script:VcfCmd $deleteArgs 2>&1
        $deleteExitCode = $LASTEXITCODE
        Write-LogMessage -Type DEBUG -Message "Context delete exit code: $deleteExitCode"
        if ($deleteOutput) {
            $deleteOutputText = ($deleteOutput | Where-Object { $_ -is [string] }) -join "`n"
            if ($deleteOutputText) {
                Write-LogMessage -Type DEBUG -Message "Context delete output: $deleteOutputText"
            }
        }

        # Verify the context is actually deleted by checking vcf context list.
        Start-Sleep -Seconds $RetryDelaySeconds
        $contextListOutput = & $Script:VcfCmd context list -o json 2>&1
        if ($LASTEXITCODE -eq 0 -and $contextListOutput) {
            $contextListJson = ($contextListOutput | Where-Object { $_ -is [string] }) -join "`n" | ConvertFrom-Json

            $existingContext = $contextListJson | Where-Object { $_.name -eq $ContextName } | Select-Object -First 1
            if ($existingContext) {
                Write-LogMessage -Type WARNING -Message "Context `"$ContextName`" still exists after deletion. Attempting force deletion..."
                $forceDeleteOutput = & $Script:VcfCmd context delete $ContextName -y 2>&1
                $forceDeleteExitCode = $LASTEXITCODE
                Write-LogMessage -Type DEBUG -Message "Force delete exit code: $forceDeleteExitCode"
                if ($forceDeleteOutput) {
                    $forceDeleteOutputText = ($forceDeleteOutput | Where-Object { $_ -is [string] }) -join "`n"
                    if ($forceDeleteOutputText) {
                        Write-LogMessage -Type DEBUG -Message "Force delete output: $forceDeleteOutputText"
                    }
                }
                Start-Sleep -Seconds $RetryDelaySeconds
            } else {
                Write-LogMessage -Type DEBUG -Message "Context `"$ContextName`" verified as deleted."
            }
        } else {
            Write-LogMessage -Type DEBUG -Message "Could not verify context deletion (exit code: $LASTEXITCODE). Assuming deletion succeeded."
        }

        # Step 2: Create VCF context with specified endpoint.
        Write-LogMessage -Type INFO -Message "Creating VCF context `"$ContextName`" with endpoint `"$Endpoint`"..."
        $createArgs = @(
            "context", "create", $ContextName,
            "--endpoint", $Endpoint,
            "--username", $SsoUsername
        )

        if ($InsecureTls) {
            $createArgs += "--insecure-skip-tls-verify"
        }

        Write-LogMessage -Type DEBUG -Message "VCF CLI command: $($Script:VcfCmd) $($createArgs -join ' ')"

        $errorOutput = $null
        $createOutputText = ""
        $createOutput = & $Script:VcfCmd $createArgs 2>&1 | Tee-Object -Variable errorOutput
        $createExitCode = $LASTEXITCODE
        Write-LogMessage -Type DEBUG -Message "VCF CLI context create exit code: $createExitCode"

        if ($createOutput) {
            $createOutputText = ($createOutput | Where-Object { $_ -is [string] }) -join "`n"
            if ($createOutputText) {
                Write-LogMessage -Type DEBUG -Message "VCF CLI context create output: $createOutputText"
            }
        }

        if ($createExitCode -ne 0) {
            $errorMessage = ($errorOutput | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] -or ($_ -is [string] -and $_ -match "error|unable") }) -join " "
            if ($errorMessage -match "unable to identify the context type") {
                Write-LogMessage -Type ERROR -Message "Unable to create VCF context `"$ContextName`". The supervisor endpoint `"$Endpoint`" may not be available."
                throw [VcfDeploymentException]::new("Deployment failed. Supervisor endpoint may not be available. Check logs for details.")
            } else {
                Write-LogMessage -Type ERROR -Message "Failed to create VCF context `"$ContextName`": $errorMessage"
                throw [VcfDeploymentException]::new("Failed to create VCF context `"$ContextName`": $errorMessage")
            }
        }

        # VCF CLI may return exit code 0 even when authentication partially failed (e.g. supervisor
        # cluster login failed but the base context name was still registered). Detect this by
        # inspecting the output for the partial-login failure message and treat it as a hard error,
        # because namespace-scoped contexts (e.g. ContextName:argocd-c35) will not be available.
        if ($createOutputText -match "Not all cluster/workload sessions were established" -or
            $createOutputText -match "Login failed for the following") {
            Write-LogMessage -Type ERROR -Message "VCF CLI context `"$ContextName`" was partially created but authentication to the supervisor cluster at `"$Endpoint`" failed. Check network connectivity and credentials."
            Write-LogMessage -Type DEBUG -Message "Partial login failure output:`n$createOutputText"
            throw [VcfDeploymentException]::new("Deployment failed. Supervisor authentication failed. Check logs for details.")
        }

        # Step 3: Verify context was created.
        Write-LogMessage -Type DEBUG -Message "Verifying VCF context `"$ContextName`" was created..."
        $listOutput = & $Script:VcfCmd context list -o json 2>&1

        if ($LASTEXITCODE -eq 0) {
            $jsonObject = ($listOutput | Where-Object { $_ -is [string] }) -join "`n" | ConvertFrom-Json

            $contextFound = $false
            foreach ($context in $jsonObject) {
                if ($context.name -eq $ContextName) {
                    Write-LogMessage -Type INFO -Message "VCF context `"$ContextName`" created successfully."
                    $contextFound = $true
                    break
                }
            }

            if (-not $contextFound) {
                Write-LogMessage -Type ERROR -Message "VCF context `"$ContextName`" creation failed - context not found after creation."
                throw [VcfDeploymentException]::new("Deployment failed. Supervisor endpoint may not be available. Check logs for details.")
            }
        } else {
            Write-LogMessage -Type ERROR -Message "Failed to list VCF contexts to verify creation (exit code: $LASTEXITCODE)."
            throw [VcfDeploymentException]::new("Failed to list VCF contexts to verify creation (exit code: $LASTEXITCODE).")
        }

        # Step 4: Switch to the context (use same TLS option as context create so switch succeeds).
        # When Namespace is provided, try namespace-scoped context first (e.g. vcf-context-01:argocd-c180);
        # some VCF CLI versions require a namespace when multiple contexts exist. Log full output for diagnosis.
        $contextUseTarget = if (-not [String]::IsNullOrWhiteSpace($Namespace)) {
            "${ContextName}:$Namespace"
        } else {
            $ContextName
        }
        Write-LogMessage -Type INFO -Message "Switching to VCF context `"$contextUseTarget`"..."
        if ($InsecureTls) {
            $contextUseOutput = & $Script:VcfCmd context use $contextUseTarget --insecure-skip-tls-verify 2>&1
        } else {
            $contextUseOutput = & $Script:VcfCmd context use $contextUseTarget 2>&1
        }
        $contextUseExitCode = $LASTEXITCODE
        Write-LogMessage -Type DEBUG -Message "Context use exit code: $contextUseExitCode"
        $contextUseOutputText = ($contextUseOutput | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.ToString() } else { [string]$_ }
        }) -join "`n"
        if (-not [String]::IsNullOrWhiteSpace($contextUseOutputText)) {
            Write-LogMessage -Type DEBUG -Message "Context use output: $contextUseOutputText"
        }

        if ($contextUseExitCode -ne 0 -and -not [String]::IsNullOrWhiteSpace($Namespace)) {
            $contextUseTarget = $ContextName
            Write-LogMessage -Type DEBUG -Message "Namespace-scoped context switch failed. Trying base context `"$contextUseTarget`"..."
            if ($InsecureTls) {
                $contextUseOutput = & $Script:VcfCmd context use $contextUseTarget --insecure-skip-tls-verify 2>&1
            } else {
                $contextUseOutput = & $Script:VcfCmd context use $contextUseTarget 2>&1
            }
            $contextUseExitCode = $LASTEXITCODE
            Write-LogMessage -Type DEBUG -Message "Context use (base) exit code: $contextUseExitCode"
            $contextUseOutputText = ($contextUseOutput | ForEach-Object {
                if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.ToString() } else { [string]$_ }
            }) -join "`n"
            if (-not [String]::IsNullOrWhiteSpace($contextUseOutputText)) {
                Write-LogMessage -Type DEBUG -Message "Context use (base) output: $contextUseOutputText"
            }
        }

        if ($contextUseExitCode -ne 0) {
            # VCF CLI may return exit code 1 even when context activated, if ClusterDomainResolutionEntry
            # is missing in the cluster (e.g. edge or minimal supervisor). Output still contains "Successfully activated".
            $contextActuallyActivated = $contextUseOutputText -match "Successfully activated"
            if ($contextActuallyActivated) {
                Write-LogMessage -Type INFO -Message "VCF context `"$contextUseTarget`" activated successfully."
                Write-LogMessage -Type DEBUG -Message (
                    "VCF context `"$contextUseTarget`" activated (output shows Successfully activated) but CLI returned exit code $contextUseExitCode. " +
                    "This can occur when ClusterDomainResolutionEntry is not present in the cluster."
                )
            } else {
                $contextUseError = ($contextUseOutput | ForEach-Object {
                    if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.ToString() } else { [string]$_ }
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

        Write-LogMessage -Type DEBUG -Message "Set-VCFContextCreate completed successfully."

    } catch [VcfDeploymentException] {
        throw  # already logged and typed — propagate without re-wrapping
    } catch {
        Write-LogMessage -Type ERROR -Message "Failed to create or configure VCF context `"$ContextName`": $($_.Exception.Message)"
        throw [VcfDeploymentException]::new("Failed to create or configure VCF context `"$ContextName`": $($_.Exception.Message)")
    }
}
Function Test-WebhookServiceReady {

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
    #>

    Param (
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$ServiceName = "argocd-service-webhook-service",
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ServiceNamespace
    )

    try {
        # Check if the webhook service exists.
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

        # Check if endpoints have subsets with addresses.
        # Kubernetes endpoints structure: { "subsets": [ { "addresses": [...] } ] }
        if (-not $webhookEndpoints.subsets -or $webhookEndpoints.subsets.Count -eq 0) {
            Write-LogMessage -Type DEBUG -Message "Webhook service `"$ServiceName`" exists but has no subsets (no pod endpoints yet)."
            return $false
        }

        $totalAddresses = 0
        foreach ($subset in $webhookEndpoints.subsets) {
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
    } catch {
        Write-LogMessage -Type DEBUG -Message "Error checking webhook service: $($_.Exception.Message). Continuing to wait..."
        return $false
    }
}
Function Wait-WebhookServiceReady {

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
    #>

    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(1, [int]::MaxValue)] [Int]$CheckInterval = 5,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$ServiceName = "argocd-service-webhook-service",
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ServiceNamespace,
        [Parameter(Mandatory = $false)] [ValidateRange(1, [int]::MaxValue)] [Int]$TimeoutSeconds = 1200
    )

    Write-LogMessage -Type INFO -Message "Waiting for ArgoCD operator webhook service to be ready (timeout: $TimeoutSeconds seconds)..."

    # Verify kubectl can access the cluster before starting the wait loop.
    Write-LogMessage -Type DEBUG -Message "Pre-flight check: Verifying kubectl can access cluster..."
    $preflightCheck = & $Script:KubectlCmd cluster-info 2>&1
    if ($LASTEXITCODE -ne 0) {
        $preflightError = ($preflightCheck | Where-Object { $_ -is [string] }) -join " "
        Write-LogMessage -Type WARNING -Message "Pre-flight check failed: kubectl cluster-info returned error (exit code: $LASTEXITCODE): $preflightError"
        Write-LogMessage -Type WARNING -Message "This may indicate the kubectl context is not properly configured. The webhook check will proceed but may fail."
    } else {
        Write-LogMessage -Type DEBUG -Message "Pre-flight check passed: kubectl can access cluster."
    }

    $webhookWaitStartTime = Get-Date
    $webhookReady = $false

    do {
        $webhookReady = Test-WebhookServiceReady -ServiceNamespace $ServiceNamespace -ServiceName $ServiceName

        if (-not $webhookReady) {
            $currentElapsed = ((Get-Date) - $webhookWaitStartTime).TotalSeconds
            $percentComplete = [Math]::Min(99, [int](($currentElapsed / $TimeoutSeconds) * 100))
            $statusMessage = "Elapsed: $([math]::Floor($currentElapsed)) seconds - Checking webhook service..."

            Write-Progress -Activity "Waiting for ArgoCD operator webhook service to be ready" -Status $statusMessage -PercentComplete $percentComplete
            [Console]::Out.Flush()

            Start-Sleep $CheckInterval
        }

        # Timeout check using actual elapsed time.
        $currentElapsed = ((Get-Date) - $webhookWaitStartTime).TotalSeconds
        if ($currentElapsed -ge $TimeoutSeconds -and -not $webhookReady) {
            Write-Progress -Activity "Waiting for ArgoCD operator webhook service to be ready" -Status "Timeout" -Completed
            [Console]::Out.Flush()
            Write-LogMessage -Type ERROR -Message "Timeout waiting for ArgoCD operator webhook service after $TimeoutSeconds seconds."
            Write-LogMessage -Type ERROR -Message "The webhook service may not be properly installed in namespace `"$ServiceNamespace`"."

            # Provide diagnostic information.
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
                }
                else {
                    Write-LogMessage -Type ERROR -Message "No pods found in namespace `"$ServiceNamespace`". The operator may not have been installed successfully."
                }
            } else {
                $podsError = ($operatorPodsOutput | Where-Object { $_ -is [string] }) -join " "
                Write-LogMessage -Type WARNING -Message "Could not retrieve pods from namespace `"$ServiceNamespace`": $podsError. This may indicate kubectl context issues."
            }

            # Check if the namespace itself exists.
            Write-LogMessage -Type INFO -Message "Diagnostic: Verifying namespace `"$ServiceNamespace`" exists..."
            $namespaceCheck = & $Script:KubectlCmd get namespace "$ServiceNamespace" -o json 2>$null | ConvertFrom-Json
            if (-not $namespaceCheck) {
                Write-LogMessage -Type ERROR -Message "Namespace `"$ServiceNamespace`" does not exist. The ArgoCD operator installation failed."
            }
            else {
                Write-LogMessage -Type INFO -Message "Namespace `"$ServiceNamespace`" exists."
            }

            $totalElapsedTime = (Get-Date) - $webhookWaitStartTime
            Write-LogMessage -Type DEBUG -Message "Wait-WebhookServiceReady completed after $($totalElapsedTime.TotalSeconds.ToString('F3')) seconds (timeout reached)."
            return Write-ErrorAndReturn -ErrorMessage "ArgoCD operator webhook service not ready after $TimeoutSeconds seconds" -ErrorCode "ERR_WEBHOOK_TIMEOUT"
        }

        # Safety check: if we've been waiting too long (beyond timeout), break out of loop.
        $currentElapsed = ((Get-Date) - $webhookWaitStartTime).TotalSeconds
        if ($currentElapsed -ge $TimeoutSeconds) {
            # Timeout reached - break out and handle error below.
            break
        }

    } while (-not $webhookReady)

    # Check if we exited the loop due to timeout or success.
    if (-not $webhookReady) {
        # Loop exited due to timeout (safety break), not because webhook became ready.
        Write-Progress -Activity "Waiting for ArgoCD operator webhook service to be ready" -Status "Timeout" -Completed
        [Console]::Out.Flush()
        $totalElapsedTime = (Get-Date) - $webhookWaitStartTime
        Write-LogMessage -Type ERROR -Message "Timeout waiting for ArgoCD operator webhook service after $($totalElapsedTime.TotalSeconds.ToString('F2')) seconds."
        Write-LogMessage -Type ERROR -Message "The webhook service may not be properly installed in namespace `"$ServiceNamespace`"."

        # Provide diagnostic information.
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
            }
            else {
                Write-LogMessage -Type ERROR -Message "No pods found in namespace `"$ServiceNamespace`". The operator may not have been installed successfully."
            }
        } else {
            $podsError = ($operatorPodsOutput | Where-Object { $_ -is [string] }) -join " "
            Write-LogMessage -Type WARNING -Message "Could not retrieve pods from namespace `"$ServiceNamespace`": $podsError. This may indicate kubectl context issues."
        }

        # Check if the namespace itself exists.
        Write-LogMessage -Type INFO -Message "Diagnostic: Verifying namespace `"$ServiceNamespace`" exists..."
        $namespaceCheck = & $Script:KubectlCmd get namespace "$ServiceNamespace" -o json 2>$null | ConvertFrom-Json
        if (-not $namespaceCheck) {
            Write-LogMessage -Type ERROR -Message "Namespace `"$ServiceNamespace`" does not exist. The ArgoCD operator installation failed."
        }
        else {
            Write-LogMessage -Type INFO -Message "Namespace `"$ServiceNamespace`" exists."
        }

        return Write-ErrorAndReturn -ErrorMessage "ArgoCD operator webhook service not ready after $TimeoutSeconds seconds" -ErrorCode "ERR_WEBHOOK_TIMEOUT"
    }

    # Webhook became ready successfully.
    Write-Progress -Activity "Waiting for ArgoCD operator webhook service to be ready" -Status "Complete" -PercentComplete 100 -Completed
    [Console]::Out.Flush()
    $totalElapsedTime = (Get-Date) - $webhookWaitStartTime
    Write-LogMessage -Type DEBUG -Message "Wait-WebhookServiceReady completed successfully in $($totalElapsedTime.TotalSeconds.ToString('F3')) seconds."

    return @{
        Success = $true
        ErrorMessage = $null
        ErrorCode = $null
    }
}
Function Get-PodReadinessStatus {

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

    #>

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
Function Wait-ArgoCDPodsReady {

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
    #>

    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(1, [int]::MaxValue)] [Int]$CheckInterval = 5,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Namespace,
        [Parameter(Mandatory = $false)] [ValidateRange(1, [int]::MaxValue)] [Int]$TimeoutSeconds = 1800
    )

    $elapsedTime = 0
    $loggedReadyPods = @()
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

            Start-Sleep $CheckInterval
            $elapsedTime += $CheckInterval

            # Timeout check.
            if ($elapsedTime -ge $TimeoutSeconds) {
                Write-Progress -Activity "Waiting for ArgoCD pods to be created" -Status "Timeout" -Completed
                [Console]::Out.Flush()
                Write-LogMessage -Type ERROR -Message "Timeout waiting for ArgoCD pods to be created after $TimeoutSeconds seconds. Only $totalPods pod(s) found."
                throw [VcfDeploymentException]::new("Timeout waiting for ArgoCD pods to be created after $TimeoutSeconds seconds. Only $totalPods pod(s) found.")
            }
            continue
        }

        # Transition from "pods created" phase to "pods ready" phase.
        if ($podsCreatedPhase) {
            Write-Progress -Activity "Waiting for ArgoCD pods to be created" -Status "Completed" -Completed
            [Console]::Out.Flush()
            $podsCreatedPhase = $false
        }

        # Log ready pods only once.
        foreach ($pod in $podStatus.ReadyPodObjects) {
            if ($pod.metadata.name -notin $loggedReadyPods) {
                Write-LogMessage -Type DEBUG -Message "ArgoCD pod `"$($pod.metadata.name)`" is now in status $($pod.status.phase)."
                $loggedReadyPods += $pod.metadata.name
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
                Write-LogMessage -Type ERROR -Message "Timeout waiting for ArgoCD pods after $TimeoutSeconds seconds. Ready: $readyPods/$totalPods."
                throw [VcfDeploymentException]::new("Timeout waiting for ArgoCD pods after $TimeoutSeconds seconds. Ready: $readyPods/$totalPods.")
            }
        }

    } while (-not $allPodsReady)

    # Clear progress indicator when all pods are ready.
    Write-Progress -Activity "Waiting for ArgoCD pods to be ready" -Status "Completed" -Completed
    [Console]::Out.Flush()
    Write-LogMessage -Type INFO -Message "All $totalPods ArgoCD pods are ready."
}
Function Update-YamlNamespace {

    [OutputType([String])]
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
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$NewNamespace,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$YamlFilePath
    )

    Write-LogMessage -Type DEBUG -Message "Entered Update-YamlNamespace function..."
    Write-LogMessage -Type DEBUG -Message "Update-YamlNamespace: Source YAML file: `"$YamlFilePath`", New namespace value: `"$NewNamespace`""

    if (-not (Test-Path -Path $YamlFilePath)) {
        Write-LogMessage -Type ERROR -Message "YAML file not found: $YamlFilePath."
        throw [VcfDeploymentException]::new("YAML file not found: $YamlFilePath.")
    }

    try {
        # Create a temporary file for the modified YAML.
        # Use a GUID-suffixed name to avoid the GetTempFileName+ChangeExtension pattern that leaves an
        # orphaned zero-byte .tmp file and introduces a brief window before the .yml path is locked.
        $tempYamlFile = Join-Path ([System.IO.Path]::GetTempPath()) "argocd-ns-update-$([Guid]::NewGuid().ToString('N')).yml"
        Write-LogMessage -Type DEBUG -Message "Created temporary YAML file: `"$tempYamlFile`""

        # Read the original YAML content.
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

        # Verify the replacement worked and spec section is preserved.
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
            Write-LogMessage -Type ERROR -Message "This will cause the operator to not process the Custom Resource and no pods will be created."
            throw [VcfDeploymentException]::new("Deployment failed. spec section was removed during namespace replacement in YAML file `"$YamlFilePath`". Check logs for details.")
        }

        # Write the updated content to the temporary file.
        Set-Content -Path $tempYamlFile -Value $updatedContent -Encoding UTF8 -NoNewline

        # Verify the file was written correctly and log its contents.
        if (Test-Path -Path $tempYamlFile) {
            $verifyContent = Get-Content -Path $tempYamlFile -Raw -Encoding UTF8
            Write-LogMessage -Type DEBUG -Message "Full contents of temporary YAML file `"$tempYamlFile`":"
            Write-LogMessage -Type DEBUG -Message "--- BEGIN TEMP YAML FILE CONTENTS ---"
            Write-LogMessage -Type DEBUG -Message $verifyContent
            Write-LogMessage -Type DEBUG -Message "--- END TEMP YAML FILE CONTENTS ---"
        } else {
            Write-LogMessage -Type ERROR -Message "Temporary file was not created successfully: $tempYamlFile."
            throw [VcfDeploymentException]::new("Temporary file was not created successfully: $tempYamlFile.")
        }

        Write-LogMessage -Type DEBUG -Message "Updated namespace in YAML file. Temporary file: $tempYamlFile"

        return $tempYamlFile
    } catch [VcfDeploymentException] {
        throw  # already logged and typed — propagate without re-wrapping
    } catch {
        Write-LogMessage -Type ERROR -Message "Failed to update namespace in YAML file `"$YamlFilePath`": $($_.Exception.Message)"
        throw [VcfDeploymentException]::new("Failed to update namespace in YAML file `"$YamlFilePath`": $($_.Exception.Message)")
    }
}
Function Get-KubectlNamespaceNamesMatchingPattern {

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
    #>

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
Function Get-ArgoCDOperatorServiceNamespace {

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
    #>

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
Function Add-ArgoCDInstance {

    <#
        .SYNOPSIS
        Deploys an ArgoCD instance to a vSphere Supervisor namespace using kubectl and VCF CLI integration.

        .DESCRIPTION
        The Add-ArgoCDInstance function creates and configures an ArgoCD instance within a specified vSphere Supervisor
        namespace by applying Kubernetes YAML manifests through kubectl commands and VCF CLI context management.
        This function is designed to work as part of the vSphere with Tanzu ecosystem for GitOps-based application
        deployment and lifecycle management.

        The function performs the following key operations:
        • Updates the namespace value in the ArgoCD deployment YAML file to match the dynamically constructed namespace
        • Establishes VCF CLI context for the target namespace with configurable TLS verification
        • Applies the ArgoCD deployment manifest using kubectl to create the instance resources
        • Waits for ArgoCD pods to become ready with configurable timeout (default: 600 seconds)
        • Configures kubectl context to use the ArgoCD namespace for subsequent operations
        • Verifies the Custom Resource was created with required spec.version field

        This function integrates with the broader vSphere with Tanzu deployment workflow, requiring proper
        authentication context, an existing supervisor namespace, and a pre-installed ArgoCD operator.
        The deployment process includes comprehensive error handling and will terminate script execution
        if critical operations fail.

        Key features:
        - Native integration with vSphere Supervisor clusters and VCF CLI
        - Automated YAML content management and UTF-8 encoding
        - Context-aware kubectl operations with namespace switching
        - Built-in deployment verification and service discovery
        - Comprehensive error handling with detailed logging
        - Configurable TLS verification for both development and production environments

        .PARAMETER ArgoCdNamespace
        The name of the vSphere Supervisor namespace where the ArgoCD instance will be deployed.
        This namespace must already exist and be properly configured with storage policies, VM classes,
        and the ArgoCD operator. The namespace serves as both the deployment target and the kubectl
        context for all operations performed by this function. Must follow Kubernetes naming conventions.

        .PARAMETER ArgoCdDeploymentYamlPath
        The file system path where the ArgoCD deployment YAML configuration will be written and applied.
        This parameter is optional with a default value that can be provided by calling functions.
        The function expects the $yamlContent variable to be available in the calling scope containing
        valid ArgoCD deployment YAML. The file will be created or overwritten with UTF-8 encoding.

        .PARAMETER ContextName
        The name of the VCF CLI context to use for the deployment. This context must be previously
        created using Set-VCFContextCreate and should correspond to the target supervisor cluster
        where the ArgoCD instance will be deployed.

        .PARAMETER ClusterId
        The vCenter cluster MoRef identifier (e.g., "domain-c462") where the supervisor is enabled.
        This is used to dynamically construct the service namespace for webhook validation checks.
        The cluster ID is obtained from Get-ClusterId and is required because the service namespace
        format is "svc-<service>-<cluster-id>", not "svc-<service>-<supervisor-uuid>".

        .PARAMETER Service
        The service identifier (reference name) for the ArgoCD operator supervisor service.
        This is used to dynamically construct the service namespace for webhook validation checks.
        Should match the format "argocd-service.vsphere.vmware.com" or similar naming convention.

        .PARAMETER InsecureTls
        When specified, enables insecure TLS verification for VCF CLI operations by adding the
        --insecure-skip-tls-verify flag. This is useful for development and lab environments
        with self-signed certificates. When not specified, uses secure TLS verification suitable
        for production environments.

        .PARAMETER TimeoutConfig
        Hashtable containing timeout and interval configuration for various operations.
        If not provided, default values will be used. Supported keys:
        - AuthCheckInterval: Interval between kubectl authentication retry attempts, in seconds (default: 5)
        - AuthTimeoutSeconds: Maximum time to wait for kubectl authentication, in seconds (default: 60)
        - PodReadyCheckInterval: Interval between pod status checks, in seconds (default: 5)
        - PodReadyTimeoutSeconds: Maximum time to wait for all ArgoCD pods to become ready, in seconds (default: 600)
        - WebhookReadyCheckInterval: Interval between webhook service availability checks, in seconds (default: 5)
        - WebhookReadyTimeoutSeconds: Maximum time to wait for webhook service to become ready, in seconds (default: 1200)
        - WebhookRetryTimeoutSeconds: Timeout for webhook re-check before retrying YAML apply after webhook timeout, in seconds (default: 60)

        .EXAMPLE
        Add-ArgoCDInstance -ArgoCdNamespace "argocd-system" -ArgoCdDeploymentYamlPath "./configs/argocd-deployment.yaml" -ContextName "prod-context" -ClusterId "domain-c462" -Service "argocd-service.vsphere.vmware.com"

        Deploys an ArgoCD instance to the "argocd-system" namespace using secure TLS verification.
        The function writes the YAML content and applies it using kubectl, then verifies the deployment.

        .EXAMPLE
        $tempPath = [System.IO.Path]::GetTempPath()
        $yamlPath = Join-Path $tempPath "argocd-dev-config.yaml"
        Add-ArgoCDInstance -ArgoCdNamespace "dev-argocd" -ArgoCdDeploymentYamlPath $yamlPath -ContextName "dev-context" -ClusterId "domain-c462" -Service "argocd-service.vsphere.vmware.com" -InsecureTls

        Creates an ArgoCD instance in the "dev-argocd" namespace with insecure TLS verification,
        suitable for development and testing environments with self-signed certificates.

        .EXAMPLE
        $timeoutConfig = @{
            AuthTimeoutSeconds = 120
            PodReadyTimeoutSeconds = 900
            WebhookReadyTimeoutSeconds = 180
        }
        Add-ArgoCDInstance -ArgoCdNamespace "argocd-system" -ArgoCdDeploymentYamlPath "C:\configs\argocd-deployment.yaml" -ContextName "prod-context" -ClusterId "domain-c462" -Service "argocd-service.vsphere.vmware.com" -TimeoutConfig $timeoutConfig

        Deploys an ArgoCD instance with custom timeout configuration for authentication (120s), pod readiness (900s), and webhook readiness (180s).

        .EXAMPLE
        $deploymentParams = @{
            ArgoCdDeploymentYamlPath = $InputData.common.argoCD.argoCdDeploymentYamlPath
            ArgoCdNamespace = $InputData.common.argoCD.nameSpace
            ContextName = $InputData.common.argoCD.contextName
            ClusterId = $clusterId
            Service = $argoServiceName
            InsecureTls = $true
        }
        Add-ArgoCDInstance @deploymentParams

        Deploys ArgoCD using configuration parameters from input data with parameter splatting,
        enabling dynamic deployment scenarios based on configuration files with insecure TLS for lab environments.

        .OUTPUTS
        None
        This function does not return objects but performs deployment operations with side effects.
        Success is indicated by the absence of exceptions and the successful display of services
        in the target namespace. All operations are logged for audit trail and troubleshooting.

        .NOTES
        Prerequisites:
        • VCF CLI must be installed and accessible in the system PATH
        • kubectl must be installed and configured for Kubernetes operations
        • Target vSphere Supervisor namespace must exist with proper configuration
        • ArgoCD operator must be installed and running in the supervisor cluster
        • $yamlContent variable must be defined in calling scope with valid YAML content

        Behavior:
        • Uses configurable TLS verification for VCF CLI operations based on the InsecureTls parameter
        • Implements retry logic for kubectl authentication with configurable timeout (default: 60 seconds) and check interval
        • Automatically attempts to re-authenticate using vcf context if authentication fails
        • Waits for ArgoCD pods to become ready with configurable timeout (default: 600 seconds) and check interval (default: 5 seconds)
        • Switches kubectl context to the ArgoCD namespace if available, otherwise uses namespace flag -n
        • Creates temporary YAML file with updated namespace and cleans it up after deployment
        • Verifies the Custom Resource has required spec.version field after creation
        • Terminates script execution if any deployment steps fail or authentication times out

        Security Considerations:
        • Use secure TLS verification (default) for production environments
        • Insecure TLS verification should only be used in development/lab environments with self-signed certificates
        • ArgoCD deployment includes service accounts with potentially elevated permissions
        • Network policies may need configuration for proper ArgoCD access
        • TLS certificate validation is configurable via the InsecureTls parameter

        Performance Notes:
        • Pod readiness timeout is configurable (default: 600 seconds) and may need adjustment based on cluster performance
        • Large YAML files are loaded entirely into memory during processing
        • kubectl operations are synchronous and may block on slow cluster responses

        .LINK
        Set-VCFContextCreate
        Add-ArgoCDNamespace
        Get-ArgoCDOperatorServiceNamespace
        Install-ArgoCDOperator
        Get-SupervisorControlPlaneIp
    #>

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

    # Extract timeout configuration with defaults and validation.
    $authCheckInterval = if ($TimeoutConfig -and $TimeoutConfig.ContainsKey("AuthCheckInterval") -and $TimeoutConfig.AuthCheckInterval -is [Int] -and $TimeoutConfig.AuthCheckInterval -gt 0) {
        $TimeoutConfig.AuthCheckInterval
    } else {
        5
    }
    $authTimeoutSeconds = if ($TimeoutConfig -and $TimeoutConfig.ContainsKey("AuthTimeoutSeconds") -and $TimeoutConfig.AuthTimeoutSeconds -is [Int] -and $TimeoutConfig.AuthTimeoutSeconds -gt 0) {
        $TimeoutConfig.AuthTimeoutSeconds
    } else {
        $Script:ArgoCDAuthTimeoutSeconds
    }
    $podReadyCheckInterval = if ($TimeoutConfig -and $TimeoutConfig.ContainsKey("PodReadyCheckInterval") -and $TimeoutConfig.PodReadyCheckInterval -is [Int] -and $TimeoutConfig.PodReadyCheckInterval -gt 0) {
        $TimeoutConfig.PodReadyCheckInterval
    } else {
        $Script:ArgoCDPodReadyCheckIntervalSeconds
    }
    $podReadyTimeoutSeconds = if ($TimeoutConfig -and $TimeoutConfig.ContainsKey("PodReadyTimeoutSeconds") -and $TimeoutConfig.PodReadyTimeoutSeconds -is [Int] -and $TimeoutConfig.PodReadyTimeoutSeconds -gt 0) {
        $TimeoutConfig.PodReadyTimeoutSeconds
    } else {
        $Script:ArgoCDPodReadyTimeoutSeconds
    }
    $webhookReadyCheckInterval = if ($TimeoutConfig -and $TimeoutConfig.ContainsKey("WebhookReadyCheckInterval") -and $TimeoutConfig.WebhookReadyCheckInterval -is [Int] -and $TimeoutConfig.WebhookReadyCheckInterval -gt 0) {
        $TimeoutConfig.WebhookReadyCheckInterval
    } else {
        $Script:ArgoCDWebhookReadyCheckIntervalSeconds
    }
    $webhookReadyTimeoutSeconds = if ($TimeoutConfig -and $TimeoutConfig.ContainsKey("WebhookReadyTimeoutSeconds") -and $TimeoutConfig.WebhookReadyTimeoutSeconds -is [Int] -and $TimeoutConfig.WebhookReadyTimeoutSeconds -gt 0) {
        $TimeoutConfig.WebhookReadyTimeoutSeconds
    } else {
        $Script:ArgoCDWebhookReadyTimeoutSeconds
    }
    $webhookRetryTimeoutSeconds = if ($TimeoutConfig -and $TimeoutConfig.ContainsKey("WebhookRetryTimeoutSeconds") -and $TimeoutConfig.WebhookRetryTimeoutSeconds -is [Int] -and $TimeoutConfig.WebhookRetryTimeoutSeconds -gt 0) {
        $TimeoutConfig.WebhookRetryTimeoutSeconds
    } else {
        $Script:ArgoCDWebhookRetryTimeoutSeconds
    }

    try {
        # Switch to VCF context for subsequent operations (required before kubectl lookup).
        # Prefer namespace-scoped context (ContextName:ArgoCdNamespace) when available so kubectl targets the ArgoCD namespace.
        $contextToUse = if (-not [String]::IsNullOrWhiteSpace($ArgoCdNamespace)) { "${ContextName}:$ArgoCdNamespace" } else { $ContextName }
        if ($InsecureTls) {
            $contextUseOutput = & $Script:VcfCmd context use $contextToUse --insecure-skip-tls-verify 2>&1
        } else {
            $contextUseOutput = & $Script:VcfCmd context use $contextToUse 2>&1
        }
        $contextUseExitCode = $LASTEXITCODE
        if ($contextUseExitCode -ne 0 -and $contextToUse -ne $ContextName) {
            Write-LogMessage -Type DEBUG -Message "Namespace-scoped context switch failed; trying base context `"$ContextName`"..."
            if ($InsecureTls) {
                $contextUseOutput = & $Script:VcfCmd context use $ContextName --insecure-skip-tls-verify 2>&1
            } else {
                $contextUseOutput = & $Script:VcfCmd context use $ContextName 2>&1
            }
            $contextUseExitCode = $LASTEXITCODE
        }
        $contextUseOutputText = ($contextUseOutput | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.ToString() } else { [string]$_ }
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

        # Ensure kubectl is using the correct context for this site before namespace lookup and webhook check.
        Write-LogMessage -Type DEBUG -Message "Verifying kubectl can access cluster after VCF context switch..."
        $null = & $Script:KubectlCmd cluster-info 2>&1 | Out-Null
        switch ($LASTEXITCODE) {
            0 { Write-LogMessage -Type DEBUG -Message "kubectl cluster access verified after context switch." }
            default {
                Write-LogMessage -Type WARNING -Message "kubectl cluster-info failed after context switch (exit code: $LASTEXITCODE). This may indicate the context needs time to initialize. Continuing with webhook check..."
            }
        }

        # Resolve operator namespace by lookup
        $serviceSlug = $Service -replace '\.vsphere\.vmware\.com$', ''
        $constructedNamespace = "svc-$serviceSlug-$ClusterId"
        $resolvedOperatorNs = Get-ArgoCDOperatorServiceNamespace -Service $Service
        $serviceNamespace = if (-not [String]::IsNullOrWhiteSpace($resolvedOperatorNs)) { $resolvedOperatorNs } else { $constructedNamespace }
        $namespaceSource = if (-not [String]::IsNullOrWhiteSpace($resolvedOperatorNs)) { "resolved" } else { "fallback constructed" }
        Write-LogMessage -Type DEBUG -Message "Using $namespaceSource service namespace: `"$serviceNamespace`""

        # Wait for ArgoCD operator webhook service to be ready before applying YAML.
        $webhookResult = Wait-WebhookServiceReady -CheckInterval $webhookReadyCheckInterval -ServiceName "argocd-service-webhook-service" -ServiceNamespace $serviceNamespace -TimeoutSeconds $webhookReadyTimeoutSeconds
        if (-not $webhookResult.Success) {
            return $webhookResult
        }

        # Copy YAML file to temporary location and update namespace value to match the dynamically constructed namespace.
        Write-LogMessage -Type DEBUG -Message "Updating YAML file namespace from original file `"$ArgoCdDeploymentYamlPath`" to namespace value: `"$ArgoCdNamespace`""
        $tempYamlPath = Update-YamlNamespace -YamlFilePath $ArgoCdDeploymentYamlPath -NewNamespace $ArgoCdNamespace

        try {
            Write-LogMessage -Type DEBUG -Message "Applying temporary ArgoCD deployment YAML file to the namespace `"$ArgoCdNamespace`"..."
            $applyErrorOutput = $null
            $applySuccessOutput = $null
            & $Script:KubectlCmd apply -f $tempYamlPath 2>&1 | Tee-Object -Variable applyOutput | Out-Null
            $applyOutput = $applyOutput | Where-Object { $_ -is [string] -or $_ -is [System.Management.Automation.ErrorRecord] }

            if ($LASTEXITCODE -eq 0) {
                # YAML applied successfully - log the output.
                $applySuccessOutput = $applyOutput
                $successMessage = ($applySuccessOutput | Where-Object { $_ -is [string] }) -join " "
                $logSuffix = if ([String]::IsNullOrWhiteSpace($successMessage)) { "" } else { " Output: $successMessage" }
                Write-LogMessage -Type DEBUG -Message "Successfully applied ArgoCD deployment YAML to namespace `"$ArgoCdNamespace`".$logSuffix"

                # Verify the resource was created and has required spec section.
                try {
                    $argocdResources = & $Script:KubectlCmd get argocd -n $ArgoCdNamespace -o json 2>&1
                    if ($LASTEXITCODE -eq 0 -and $argocdResources) {
                        $argocdResourcesJson = $argocdResources | ConvertFrom-Json
                        if ($argocdResourcesJson.items) {
                            foreach ($resource in $argocdResourcesJson.items) {
                                switch ($true) {
                                    { -not $resource.spec } {
                                        Write-LogMessage -Type ERROR -Message "CRITICAL: Spec section is MISSING from the Custom Resource! The ArgoCD operator requires spec.version to process the Custom Resource."
                                    }
                                    { -not $resource.spec.version } {
                                        Write-LogMessage -Type ERROR -Message "CRITICAL: Spec.version is MISSING! The ArgoCD operator requires spec.version to process the Custom Resource."
                                    }
                                }
                            }
                        }
                    }
                } catch {
                    Write-LogMessage -Type WARNING -Message "Exception while verifying ArgoCD resource: $($_.Exception.Message)"
                }
            } else {
                $applyErrorOutput = $applyOutput
                $errorMessage = ($applyErrorOutput | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] -or ($_ -is [string]) }) -join " "
                Write-LogMessage -Type ERROR -Message "kubectl apply failed with exit code: $LASTEXITCODE"
                Write-LogMessage -Type ERROR -Message "Error message: $errorMessage."

                $isWebhookTimeout = $errorMessage -match "context deadline exceeded" -or $errorMessage -match "webhook.*timeout"
                if (-not $isWebhookTimeout) {
                    return Write-ErrorAndReturn -ErrorMessage "Failed to apply ArgoCD deployment YAML file `"$tempYamlPath`": $errorMessage" -ErrorCode "ERR_KUBECTL_APPLY"
                }

                Write-LogMessage -Type ERROR -Message "Webhook timeout error when applying ArgoCD deployment YAML. The webhook service may have become unavailable after initial readiness check."
                Write-LogMessage -Type INFO -Message "Attempting to re-verify webhook service readiness before retrying..."

                $webhookRetryResult = Wait-WebhookServiceReady -CheckInterval $webhookReadyCheckInterval -ServiceName "argocd-service-webhook-service" -ServiceNamespace $serviceNamespace -TimeoutSeconds $webhookRetryTimeoutSeconds
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
            }
        } finally {
            # Clean up temporary YAML file.
            if (Test-Path -Path $tempYamlPath) {
                Remove-Item -Path $tempYamlPath -Force -ErrorAction SilentlyContinue
                Write-LogMessage -Type DEBUG -Message "Cleaned up temporary YAML file: $tempYamlPath."
            }
        }

        $vksNs = $ContextName+":"+$ArgoCdNamespace

        # Check if the kubectl context exists before trying to use it.
        # The context may not exist immediately after namespace creation.
        # VCF CLI creates contexts dynamically, and namespace-specific contexts may not exist yet.
        Write-LogMessage -Type DEBUG -Message "Checking if kubectl context `"$vksNs`" exists..."
        $contextExists = $false
        try {
            $contextCheckOutput = & $Script:KubectlCmd config get-contexts -o name 2>&1 | Where-Object { $_ -is [string] -and $_ -notmatch "^error:" }
            if ($LASTEXITCODE -eq 0 -and $contextCheckOutput) {
                $contextList = $contextCheckOutput | Where-Object { $_ -is [string] -and $_.Trim() -ne "" }
                $contextExists = $contextList -contains $vksNs
            }
        } catch {
            Write-LogMessage -Type DEBUG -Message "Error checking kubectl contexts: $_. Continuing without context switch."
        }

        switch ($contextExists) {
            $true {
                Write-LogMessage -Type DEBUG -Message "kubectl context `"$vksNs`" exists. Switching to it..."
                $null = & $Script:KubectlCmd config use-context "$vksNs" 2>&1
                switch ($LASTEXITCODE) {
                    0 { Write-LogMessage -Type DEBUG -Message "Successfully switched to kubectl context `"$vksNs`"." }
                    default { Write-LogMessage -Type WARNING -Message "Failed to switch to kubectl context `"$vksNs`", but continuing with namespace flag `-n` instead." }
                }
            }
            default {
                Write-LogMessage -Type INFO -Message "kubectl context `"$vksNs`" does not exist. This is expected if the namespace was just created. Continuing with namespace flag `-n` for kubectl operations."
            }
        }

        # Wait for kubectl authentication with retry logic.
        Write-LogMessage -Type DEBUG -Message "Verifying kubectl authentication for namespace `"$ArgoCdNamespace`" (timeout: $authTimeoutSeconds seconds)..."

        $elapsedTime = 0
        $authSuccess = $false

        do {
            try {
                # Check if we have permission to get pods in ArgoCD namespace.
                $canGetPods = & $Script:KubectlCmd auth can-i get pods -n $ArgoCdNamespace 2>&1
                $authExitCode = $LASTEXITCODE

                if ($authExitCode -eq 0 -and $canGetPods -eq "yes") {
                    # Authentication successful.
                    $authSuccess = $true
                    Write-LogMessage -Type DEBUG -Message "kubectl authentication verified for namespace `"$ArgoCdNamespace`" after $elapsedTime seconds"
                    break
                }

                # Authentication failed - try to re-authenticate.
                if ($elapsedTime -eq 0) {
                    Write-LogMessage -Type WARNING -Message "kubectl authentication failed: $canGetPods."
                    Write-LogMessage -Type INFO -Message "Attempting to re-authenticate using: vcf context use $ContextName."
                }

                # Re-authenticate using vcf context (use same TLS option as initial context switch).
                if ($InsecureTls) {
                    $null = & $Script:VcfCmd context use $ContextName --insecure-skip-tls-verify 2>&1
                } else {
                    $null = & $Script:VcfCmd context use $ContextName 2>&1
                }

                # Update progress.
                $statusMessage = "Waiting for authentication (exit code: $authExitCode)"
                $currentOperation = "Elapsed: $elapsedTime seconds"
                Write-Progress -Activity "Waiting for kubectl authentication" -Status $statusMessage -CurrentOperation $currentOperation

                # Wait before next check.
                Start-Sleep $authCheckInterval
                $elapsedTime += $authCheckInterval

            } catch {
                $errorMessage = $_.Exception.Message
                Write-LogMessage -Type ERROR -Message "Error during kubectl authentication check: $errorMessage."
                Write-Progress -Activity "Waiting for kubectl authentication" -Status "Error" -Completed
                throw [VcfDeploymentException]::new("kubectl authentication failed: $errorMessage")
            }
        } while ($elapsedTime -lt $authTimeoutSeconds)

        # Check if authentication succeeded.
        if (-not $authSuccess) {
            Write-Progress -Activity "Waiting for kubectl authentication" -Status "Timeout" -Completed
            Write-LogMessage -Type ERROR -Message "kubectl authentication failed after $authTimeoutSeconds seconds."
            Write-LogMessage -Type ERROR -Message "You may need to manually re-authenticate using: vcf context use $ContextName."
            throw [VcfDeploymentException]::new("You may need to manually re-authenticate using: vcf context use $ContextName.")
        }

        Write-Progress -Activity "Waiting for kubectl authentication" -Status "Authenticated" -Completed

        # Wait for all ArgoCD pods to be ready.
        Wait-ArgoCDPodsReady -Namespace $ArgoCdNamespace -CheckInterval $podReadyCheckInterval -TimeoutSeconds $podReadyTimeoutSeconds

        Write-LogMessage -Type DEBUG -Message "ArgoCD namespace `"$vksNs`" is now available with all pods ready."

    } catch [VcfDeploymentException] {
        throw  # already logged and typed — propagate without re-wrapping
    } catch {
        Write-LogMessage -Type ERROR -Message "Failed to add ArgoCD instance: $($_.Exception.Message)"
        throw [VcfDeploymentException]::new("Failed to add ArgoCD instance: $($_.Exception.Message)")
    }
}
Function Show-ArgoCDInstanceDetails {

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

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ArgoCdNamespace,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$ContextName,
        [Parameter(Mandatory = $false)] [Switch]$InsecureTls,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 60)] [Int]$RetryDelaySeconds = 2
    )

    # Derive IP address from external load balancer for ArgoCD namespace.
    $svcErrorOutput = $null
    $svcOutput = & $Script:KubectlCmd get svc argocd-server -n $ArgoCdNamespace -o json 2>&1 | Tee-Object -Variable svcErrorOutput

    if ($LASTEXITCODE -ne 0) {
        $svcErrorMessage = ($svcErrorOutput | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] -or ($_ -is [string]) }) -join " "

        # Check if this is a kubectl context issue (pointing to localhost:8080).
        if ($svcErrorMessage -match "localhost:8080|dial tcp.*8080|\[::1\]:8080|Unable to connect to the server.*dial tcp") {
            Write-LogMessage -Type WARNING -Message "kubectl appears to be pointing to localhost:8080 instead of the cluster. Attempting to fix kubectl context..."

            # Try to fix the kubectl context if we have a context name. Prefer namespace-scoped context to match deployment.
            if ($ContextName) {
                try {
                    $contextToUse = "${ContextName}:$ArgoCdNamespace"
                    Write-LogMessage -Type DEBUG -Message "Re-switching to VCF context `"$contextToUse`" to fix kubectl configuration..."
                    if ($InsecureTls) {
                        $contextUseOutput = & $Script:VcfCmd context use $contextToUse --insecure-skip-tls-verify 2>&1
                    } else {
                        $contextUseOutput = & $Script:VcfCmd context use $contextToUse 2>&1
                    }
                    $contextUseExitCode = $LASTEXITCODE
                    if ($contextUseExitCode -ne 0) {
                        Write-LogMessage -Type DEBUG -Message "Namespace-scoped context failed; trying base context `"$ContextName`"..."
                        if ($InsecureTls) {
                            $contextUseOutput = & $Script:VcfCmd context use $ContextName --insecure-skip-tls-verify 2>&1
                        } else {
                            $contextUseOutput = & $Script:VcfCmd context use $ContextName 2>&1
                        }
                        $contextUseExitCode = $LASTEXITCODE
                    }

                    $contextUseOutputText = ($contextUseOutput | ForEach-Object {
                        if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.ToString() } else { [string]$_ }
                    }) -join "`n"
                    $contextActuallyActivated = $contextUseOutputText -match "Successfully activated"
                    if ($contextUseExitCode -ne 0 -and $contextActuallyActivated) {
                        Write-LogMessage -Type DEBUG -Message "VCF context use returned exit code $contextUseExitCode but output shows Successfully activated; treating as success (ClusterDomainResolutionEntry may be absent)."
                    }

                    if ($contextUseExitCode -eq 0 -or $contextActuallyActivated) {
                        Write-LogMessage -Type INFO -Message "Successfully re-established VCF context. Retrying kubectl operation..."
                        Start-Sleep -Seconds $RetryDelaySeconds

                        # Retry the kubectl command.
                        $svcErrorOutput = $null
                        $svcOutput = & $Script:KubectlCmd get svc argocd-server -n $ArgoCdNamespace -o json 2>&1 | Tee-Object -Variable svcErrorOutput

                        if ($LASTEXITCODE -eq 0) {
                            Write-LogMessage -Type INFO -Message "kubectl context fixed successfully. Continuing with ArgoCD instance details retrieval."
                            # Continue with processing below.
                        } else {
                            $retryErrorMessage = ($svcErrorOutput | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] -or ($_ -is [string]) }) -join " "
                            Write-LogMessage -Type WARNING -Message "kubectl operation still failing after context fix: $retryErrorMessage"
                            Write-LogMessage -Type INFO -Message "The ArgoCD instance may still be deploying. Please check the namespace status and try again later."
                            return
                        }
                    } else {
                        $contextUseError = ($contextUseOutput | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] -or ($_ -is [string] -and $_ -match "error|Error|ERROR|Unable|unable|UNABLE|cannot|Cannot|CANNOT") }) -join " "
                        if ($contextUseError) {
                            Write-LogMessage -Type WARNING -Message "Failed to re-establish VCF context: $contextUseError"
                        } else {
                            Write-LogMessage -Type WARNING -Message "Failed to re-establish VCF context (exit code: $contextUseExitCode)."
                        }
                        Write-LogMessage -Type INFO -Message "The ArgoCD instance may still be deploying. Please check the namespace status and try again later."
                        return
                    }
                } catch {
                    Write-LogMessage -Type WARNING -Message "Error attempting to fix kubectl context: $($_.Exception.Message)"
                    Write-LogMessage -Type INFO -Message "The ArgoCD instance may still be deploying. Please check the namespace status and try again later."
                    return
                }
            } else {
                Write-LogMessage -Type WARNING -Message "kubectl context issue detected but no context name provided. Cannot automatically fix."
                Write-LogMessage -Type INFO -Message "The ArgoCD instance may still be deploying. Please check the namespace status and try again later."
                return
            }
        } else {
            Write-LogMessage -Type WARNING -Message "ArgoCD server service not found in namespace `"$ArgoCdNamespace`": $svcErrorMessage"
            Write-LogMessage -Type INFO -Message "The ArgoCD instance may still be deploying. Please check the namespace status and try again later."
            return
        }
    }

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

    # Retrieve initial admin password from Kubernetes secret.
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
        Write-LogMessage -Type ERROR -Message "Failed to decode initial admin password for ArgoCD in namespace `"$ArgoCdNamespace`": $($_.Exception.Message)."
        throw [VcfDeploymentException]::new("Failed to decode initial admin password for ArgoCD in namespace `"$ArgoCdNamespace`": $($_.Exception.Message).")
    }
    if ([String]::IsNullOrWhiteSpace($decodedPassword)) {
        Write-LogMessage -Type ERROR -Message "Failed to decode initial admin password for ArgoCD in namespace `"$ArgoCdNamespace`"."
        throw [VcfDeploymentException]::new("Failed to decode initial admin password for ArgoCD in namespace `"$ArgoCdNamespace`".")
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
Function Show-HarborInstanceDetails {

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

    # Resolve admin password in priority order:
    # 1. $env:HARBOR_ADMIN_PASSWORD
    # 2. harborConfiguration.harborAdminPassword from infrastructure JSON (supports $env: references)
    # 3. harborAdminPassword key grepped from the rendered YAML file (covers template-default passwords)
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
    if ([String]::IsNullOrWhiteSpace($adminPassword)) {
        $adminPassword = "[not configured]"
    }

    # Use kubectl to find the svc-harbor-* namespace. Invoke-ListNamespacesInstances only surfaces
    # user namespace instances and cannot see the system namespaces created by Supervisor Services.
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

    # Query kubectl for the LoadBalancer service external IP.
    $svcErrorOutput = $null
    $svcOutput = & $Script:KubectlCmd get svc -n $harborNamespace -o json 2>&1 | Tee-Object -Variable svcErrorOutput

    if ($LASTEXITCODE -ne 0) {
        $svcErrorMessage = ($svcErrorOutput | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] -or ($_ -is [string]) }) -join " "

        if ($svcErrorMessage -match "localhost:8080|dial tcp.*8080|\[::1\]:8080|Unable to connect to the server.*dial tcp") {
            Write-LogMessage -Type WARNING -Message "kubectl appears to be pointing to localhost:8080. Attempting to fix VCF context..."
            if (-not [String]::IsNullOrWhiteSpace($ContextName)) {
                try {
                    if ($InsecureTls) {
                        $null = & $Script:VcfCmd context use $ContextName --insecure-skip-tls-verify 2>&1
                    } else {
                        $null = & $Script:VcfCmd context use $ContextName 2>&1
                    }
                    Start-Sleep -Seconds $RetryDelaySeconds
                    $svcOutput = & $Script:KubectlCmd get svc -n $harborNamespace -o json 2>&1 | Tee-Object -Variable svcErrorOutput
                    if ($LASTEXITCODE -ne 0) {
                        Write-LogMessage -Type WARNING -Message "kubectl still failing after context fix for Harbor namespace `"$harborNamespace`"."
                        $svcOutput = $null
                    }
                } catch {
                    Write-LogMessage -Type WARNING -Message "Failed to fix kubectl context for Harbor details: $($_.Exception.Message)"
                    $svcOutput = $null
                }
            } else {
                Write-LogMessage -Type WARNING -Message "kubectl context issue detected but no context name provided. Cannot automatically fix."
                $svcOutput = $null
            }
        } else {
            Write-LogMessage -Type WARNING -Message "kubectl get svc -n `"$harborNamespace`" failed: $svcErrorMessage"
            $svcOutput = $null
        }
    }

    $lbIp = $null
    if ($null -ne $svcOutput) {
        try {
            $svcJson = $svcOutput | ConvertFrom-Json
            foreach ($item in $svcJson.items) {
                if ($item.spec.type -eq "LoadBalancer" -and $item.status.loadBalancer.ingress) {
                    $candidateIp = $item.status.loadBalancer.ingress[0].ip
                    if (-not [String]::IsNullOrWhiteSpace($candidateIp)) {
                        $lbIp = $candidateIp
                        break
                    }
                }
            }
        } catch {
            Write-LogMessage -Type DEBUG -Message "Show-HarborInstanceDetails: Failed to parse kubectl svc output. $($_.Exception.Message)"
        }
    }

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
Function Get-Base64FromYml {

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

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Path
    )

    Write-LogMessage -Type DEBUG -Message "Entered Get-Base64FromYml function..."

    try {
        if (-not (Test-Path -Path $Path)) {
            Write-LogMessage -Type ERROR -Message "YAML file not found: $Path"
            throw [VcfDeploymentException]::new("YAML file not found: $Path")
        }

        $raw = Get-Content -Path $Path -Raw -ErrorAction Stop
        $base64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($raw))

        return $base64
    } catch [VcfDeploymentException] {
        throw  # already logged and typed — propagate without re-wrapping
    } catch {
        Write-LogMessage -Type ERROR -Message "Get-Base64FromYml: Failed to read or encode YAML file `"$Path`": $($_.Exception.Message)."
        throw [VcfDeploymentException]::new("Get-Base64FromYml: Failed to read or encode YAML file `"$Path`": $($_.Exception.Message).")
    }
}
Function Set-ArgoCDService {

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
            Write-LogMessage -Type ERROR -Message "Required cmdlet for Supervisor Services CreateSpec was not found (Initialize-NamespaceManagementSupervisorServicesCreateSpec or Initialize-VcenterNamespaceManagementSupervisorServicesCreateSpec)."
            throw [VcfDeploymentException]::new("Required cmdlet for Supervisor Services CreateSpec was not found (Initialize-NamespaceManagementSupervisorServicesCreateSpec or Initialize-VcenterNamespaceManagementSupervisorServicesCreateSpec).")
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
            Write-LogMessage -Type ERROR -Message "ArgoCD service `"$argoServiceName`" version `"$argoServiceVersion`" creation failed: $($_.Exception.Message)"
            throw [VcfDeploymentException]::new("ArgoCD service `"$argoServiceName`" version `"$argoServiceVersion`" creation failed: $($_.Exception.Message)")
        }
    }
}
Function Set-HarborService {

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
            Write-LogMessage -Type ERROR -Message "Required cmdlet for Supervisor Services CreateSpec was not found (Initialize-NamespaceManagementSupervisorServicesCreateSpec or Initialize-VcenterNamespaceManagementSupervisorServicesCreateSpec)."
            throw [VcfDeploymentException]::new("Required cmdlet for Supervisor Services CreateSpec was not found (Initialize-NamespaceManagementSupervisorServicesCreateSpec or Initialize-VcenterNamespaceManagementSupervisorServicesCreateSpec).")
        }
        $vcenterNamespaceManagementSupervisorServicesCheckContentRequest = & $createSpecCmd -CarvelSpec $vcenterNamespaceManagementSupervisorServicesCarvelCreateSpec
        Invoke-CreateNamespaceManagementSupervisorServices -vcenterNamespaceManagementSupervisorServicesCreateSpec $vcenterNamespaceManagementSupervisorServicesCheckContentRequest -Confirm:$false -ErrorAction Stop | Out-Null
        Write-LogMessage -Type INFO -Message "Successfully registered Harbor service `"$harborServiceName`" version `"$harborServiceVersion`"."
    } catch {
        $errMsg = $_.Exception.Message
        if ($errMsg -match "an instance of Supervisor Service with the same identifier already exists") {
            Write-LogMessage -Type INFO -Message "Harbor service `"$harborServiceName`" version `"$harborServiceVersion`" is already registered globally on this vCenter. Skipping re-registration."
        } else {
            Write-LogMessage -Type ERROR -Message "Harbor service `"$harborServiceName`" version `"$harborServiceVersion`" registration failed: $($_.Exception.Message)"
            throw [VcfDeploymentException]::new("Harbor service `"$harborServiceName`" version `"$harborServiceVersion`" registration failed: $($_.Exception.Message)")
        }
    }
}
Function Add-HarborContainerImageRegistry {

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

    # Resolve admin password: env var > JSON config (supports $env: ref) > YAML file grep.
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
    if ([String]::IsNullOrWhiteSpace($adminPassword)) {
        Write-LogMessage -Type WARNING -Message "Add-HarborContainerImageRegistry: Harbor admin password could not be resolved. Skipping container image registry registration."
        return
    }

    # Discover svc-harbor-* namespace via kubectl.
    $harborDiscovery = Get-KubectlNamespaceNamesMatchingPattern -DebugLogPrefix "Add-HarborContainerImageRegistry" -NameLike "svc-harbor*" -SortNames
    $harborNamespace = $null
    if ($harborDiscovery.KubectlSucceeded -and $harborDiscovery.Names.Count -gt 0) {
        $harborNamespace = $harborDiscovery.Names[-1]
    }

    # Discover Harbor load balancer IP.
    $lbIp = $null
    if (-not [String]::IsNullOrWhiteSpace($harborNamespace)) {
        $svcErrorOutput = $null
        $svcOutput = & $Script:KubectlCmd get svc -n $harborNamespace -o json 2>&1 | Tee-Object -Variable svcErrorOutput
        if ($LASTEXITCODE -ne 0) {
            $svcErrorMessage = ($svcErrorOutput | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] -or ($_ -is [string]) }) -join " "
            if ($svcErrorMessage -match "localhost:8080|dial tcp.*8080|\[::1\]:8080|Unable to connect to the server.*dial tcp") {
                Write-LogMessage -Type WARNING -Message "kubectl appears to be pointing to localhost:8080 during Harbor registry registration. Attempting to fix VCF context..."
                if (-not [String]::IsNullOrWhiteSpace($ContextName)) {
                    try {
                        if ($InsecureTls) {
                            $null = & $Script:VcfCmd context use $ContextName --insecure-skip-tls-verify 2>&1
                        } else {
                            $null = & $Script:VcfCmd context use $ContextName 2>&1
                        }
                        Start-Sleep -Seconds $RetryDelaySeconds
                        $svcOutput = & $Script:KubectlCmd get svc -n $harborNamespace -o json 2>&1
                        if ($LASTEXITCODE -ne 0) { $svcOutput = $null }
                    } catch {
                        $svcOutput = $null
                    }
                } else {
                    $svcOutput = $null
                }
            } else {
                $svcOutput = $null
            }
        }
        if ($null -ne $svcOutput) {
            try {
                $svcJson = $svcOutput | ConvertFrom-Json
                foreach ($item in $svcJson.items) {
                    if ($item.spec.type -eq "LoadBalancer" -and $item.status.loadBalancer.ingress) {
                        $candidateIp = $item.status.loadBalancer.ingress[0].ip
                        if (-not [String]::IsNullOrWhiteSpace($candidateIp)) {
                            $lbIp = $candidateIp
                            break
                        }
                    }
                }
            } catch {
                Write-LogMessage -Type DEBUG -Message "Add-HarborContainerImageRegistry: Failed to parse kubectl svc output. $($_.Exception.Message)"
            }
        }
    }

    $registryEndpoint = if (-not [String]::IsNullOrWhiteSpace($lbIp)) { $lbIp } else { $HarborConfig.hostname }
    Write-LogMessage -Type DEBUG -Message "Add-HarborContainerImageRegistry: using endpoint `"$registryEndpoint`"$(if ([String]::IsNullOrWhiteSpace($lbIp)) { ' (hostname fallback; LB IP not discoverable)' })."

    # Read CA certificate from the file path specified in HarborConfig.
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

    # Idempotency check: if a registry with this name already exists, inspect its endpoint.
    # Same endpoint → stale registration from an incomplete cleanup; unregister then re-register.
    # Different endpoint → a different Harbor instance is registered; leave it alone.
    try {
        $existingRegistries = Invoke-ListSupervisorNamespaceManagementContainerImageRegistries -Supervisor $SupervisorId -ErrorAction Stop
        $existingEntry = @($existingRegistries) | Where-Object { $_.name -eq $RegistryName } | Select-Object -First 1
        if ($null -ne $existingEntry) {
            $existingHostname = $existingEntry.imageRegistry.hostname
            if (-not [String]::IsNullOrWhiteSpace($existingHostname) -and $existingHostname -ne $registryEndpoint) {
                Write-LogMessage -Type INFO -Message "Harbor container image registry `"$RegistryName`" is already registered on supervisor `"$SupervisorId`" with a different endpoint (`"$existingHostname`"). Skipping re-registration."
                return
            }
            Write-LogMessage -Type INFO -Message "Harbor container image registry `"$RegistryName`" already exists on supervisor `"$SupervisorId`" (endpoint: `"$existingHostname`"). Removing stale entry before re-registration..."
            try {
                Invoke-DeleteSupervisorContainerImageRegistryNamespaceManagementContainerImageRegistries -Supervisor $SupervisorId -ContainerImageRegistry $existingEntry.id -Confirm:$false -ErrorAction Stop | Out-Null
                Write-LogMessage -Type DEBUG -Message "Stale container image registry `"$RegistryName`" removed from supervisor `"$SupervisorId`"."
            } catch {
                Write-LogMessage -Type WARNING -Message "Add-HarborContainerImageRegistry: Could not remove stale registry `"$RegistryName`" (id: `"$($existingEntry.id)`"): $($_.Exception.Message). Skipping re-registration."
                return
            }
        }
    } catch {
        Write-LogMessage -Type WARNING -Message "Add-HarborContainerImageRegistry: Could not list existing container image registries; proceeding with registration attempt. $($_.Exception.Message)"
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
Function Install-HarborSupervisorService {

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
        [Parameter(Mandatory = $false)] [ValidateRange(1, [int]::MaxValue)] [Int]$CheckInterval = 5,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterId,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Service,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorId,
        [Parameter(Mandatory = $false)] [ValidateRange(1, [int]::MaxValue)] [Int]$TotalWaitTime = 600,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Version,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$YamlServiceConfig
    )

    Write-LogMessage -Type DEBUG -Message "Entered Install-HarborSupervisorService: cluster=`"$ClusterName`", supervisor=`"$SupervisorId`", service=`"$Service`", version=`"$Version`"."
    # Strip the last DNS label suffix (e.g. ".tanzu.vmware.com" or ".vsphere.vmware.com") to produce
    # a short slug for the diagnostic namespace hint shown to the user when the service is stuck.
    $serviceSlug = $Service -replace '\.[^.]+\.[^.]+\.[^.]+$', ''
    $serviceNamespace = "svc-$serviceSlug-$ClusterId"

    # Normalize CRLF → LF before encoding. On Windows, Get-Content -Raw may return CRLF even
    # after Update-HarborYamlContent normalizes to LF, because Set-Content re-introduces CRLF
    # on Windows when writing the temp file. This ensures the API always receives LF-only YAML.
    $normalizedYaml = $YamlServiceConfig -replace '\r\n', "`n"

    # The vCenter API requires YamlServiceConfig to be base64 encoded.
    $yamlBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($normalizedYaml))

    try {
        $spec = Initialize-VcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec -SupervisorService $Service -Version $Version -YamlServiceConfig $yamlBase64
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
                    Write-Host ""
                    Write-LogMessage -Type ERROR -Message "SOLUTION: Wait for the namespace to finish deleting, then re-run this script. To check status: kubectl get namespace $terminatingNamespace"
                    throw [VcfDeploymentException]::new("SOLUTION: Wait for the namespace to finish deleting, then re-run this script. To check status: kubectl get namespace $terminatingNamespace")
                }
                "Supervisor Service is not in activated state" {
                    Write-LogMessage -Type ERROR -Message "Harbor service `"$Service`" version `"$Version`" is not in activated state on supervisor `"$SupervisorId`"."
                    Write-Host ""
                    Write-LogMessage -Type ERROR -Message "SOLUTION: In vCenter UI go to Menu > Supervisor Management > Services, find `"$Service`", and either deactivate then delete the service, then re-run this script."
                    Write-LogMessage -Type WARNING -Message "If the service is stuck: kubectl delete namespace $serviceNamespace"
                    throw [VcfDeploymentException]::new("Harbor service `"$Service`" version `"$Version`" is not in activated state on supervisor `"$SupervisorId`". Check logs for details.")
                }
                "Signature verification result for Service Version ([0-9.-]+) not found" {
                    $requestedVersion = $matches[1]
                    $cleanErrorMessage = Get-CleanErrorMessage -ErrorMessage $errMsg
                    if ($cleanErrorMessage -eq $errMsg) {
                        $cleanErrorMessage = "Harbor service version $requestedVersion is not available on this supervisor."
                    }
                    Write-LogMessage -Type ERROR -Message "Harbor installation failed: $cleanErrorMessage."
                    Write-Host ""
                    Write-LogMessage -Type ERROR -Message "SOLUTION: Upgrade your supervisor to a version that supports Harbor service $requestedVersion, or update supervisorServices.harborServiceYamlFileName (and parentDirectory) to a compatible Carvel package file."
                    throw [VcfDeploymentException]::new("SOLUTION: Upgrade your supervisor to a version that supports Harbor service $requestedVersion, or update supervisorServices.harborServiceYamlFileName (and parentDirectory) to a compatible Carvel package file.")
                }
                default {
                    $cleanMessage = Get-CleanErrorMessage -ErrorMessage $errMsg
                    # When the API reports a YAML parse error at a specific line, surface the
                    # context lines immediately so the user can correlate with the preserved temp file.
                    if ($errMsg -match 'yaml: line (\d+):') {
                        $errorLineNum = [int]$Matches[1]
                        $yamlLines = $normalizedYaml -split "`n"
                        $startLine = [Math]::Max(1, $errorLineNum - 3)
                        $endLine = [Math]::Min($yamlLines.Count, $errorLineNum + 3)
                        Write-LogMessage -Type WARNING -Message "YAML parse error at line $errorLineNum. Lines $startLine-$endLine of the submitted YAML (see preserved temp file for full content):"
                        for ($i = $startLine; $i -le $endLine; $i++) {
                            $marker = if ($i -eq $errorLineNum) { ">>> " } else { "    " }
                            Write-LogMessage -Type WARNING -Message "$marker$i : $($yamlLines[$i - 1])"
                        }
                    }
                    if ($cleanMessage -ne $errMsg) {
                        Write-LogMessage -Type ERROR -Message "Harbor installation failed: $cleanMessage."
                    } else {
                        Write-LogMessage -Type ERROR -Message "Unexpected error in Install-HarborSupervisorService: $errMsg."
                    }
                    throw [VcfDeploymentException]::new("Harbor installation failed: $cleanMessage")
                }
            }
        }

        # Poll for CONFIGURED status.
        $elapsedSeconds = 0
        $progressActivity = "Waiting for Harbor service `"$Service`" to reach CONFIGURED status"
        while ($elapsedSeconds -lt $TotalWaitTime) {
            $percentComplete = [Math]::Min(100, [int](($elapsedSeconds / $TotalWaitTime) * 100))
            Write-Progress -Activity $progressActivity -Status "Polling (${elapsedSeconds}s / ${TotalWaitTime}s)..." -PercentComplete $percentComplete
            [Console]::Out.Flush()
            Start-Sleep -Seconds $CheckInterval
            $elapsedSeconds += $CheckInterval
            try {
                $svcStatus = Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesGet -supervisor $SupervisorId -supervisorService $Service -ErrorAction Stop
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
                    # Try to surface any error message from the service status object.
                    $svcErrorDetail = $null
                    foreach ($prop in @("Message", "ErrorMessage", "Reason", "Description", "StatusDetails")) {
                        $val = $svcStatus.$prop
                        if (-not [String]::IsNullOrWhiteSpace($val)) {
                            $svcErrorDetail = $val
                            break
                        }
                    }
                    if (-not [String]::IsNullOrWhiteSpace($svcErrorDetail)) {
                        Write-LogMessage -Type ERROR -Message "Harbor service `"$Service`" entered ERROR state on supervisor `"$SupervisorId`": $svcErrorDetail"
                    } else {
                        Write-LogMessage -Type ERROR -Message "Harbor service `"$Service`" entered ERROR state on supervisor `"$SupervisorId`"."
                    }
                    Write-Host ""
                    # Discover actual Harbor namespaces via kubectl. The computed name (svc-harbor-$ClusterId)
                    # uses the cluster MoRef value but the Supervisor Services controller may use a different
                    # suffix — kubectl is the authoritative source for what actually exists on the Supervisor.
                    $harborDiagDiscovery = Get-KubectlNamespaceNamesMatchingPattern -DebugLogPrefix "Install-HarborSupervisorService" -NameLike "svc-harbor*"
                    $harborNamespaces = if ($harborDiagDiscovery.KubectlSucceeded) { @($harborDiagDiscovery.Names) } else { @() }
                    $diagnosticNamespace = if ($harborNamespaces.Count -gt 0) { $harborNamespaces[0] } else { $serviceNamespace }
                    $namespacesToCheck = if ($harborNamespaces.Count -gt 0) { $harborNamespaces } else { @($serviceNamespace) }

                    # Gather Kubernetes events from all Harbor namespaces now, before diagnosis.
                    # Only retain Warning-type events — Normal events are high-volume and not actionable.
                    $harborAllEventsParts = [System.Collections.Generic.List[string]]::new()
                    $harborWarningEventsParts = [System.Collections.Generic.List[string]]::new()
                    foreach ($ns in $namespacesToCheck) {
                        try {
                            $nsEventsOutput = & $Script:KubectlCmd get events -n $ns --sort-by=".lastTimestamp" 2>&1
                            if ($LASTEXITCODE -eq 0 -and -not [String]::IsNullOrWhiteSpace($nsEventsOutput)) {
                                $nsEventsStr = ($nsEventsOutput | Out-String).Trim()
                                $harborAllEventsParts.Add($nsEventsStr)
                                # Keep the header line plus all Warning-type event lines for concise display.
                                $nsLines = $nsEventsStr -split "`n"
                                $headerLine = $nsLines | Select-Object -First 1
                                $warnLines = $nsLines | Where-Object { $_ -match "\s+Warning\s+" }
                                if ($warnLines.Count -gt 0) {
                                    $harborWarningEventsParts.Add($headerLine + "`n" + ($warnLines -join "`n"))
                                }
                            }
                        } catch {
                            Write-LogMessage -Type DEBUG -Message "Could not pre-fetch events from `"$ns`": $($_.Exception.Message)"
                        }
                    }
                    $harborAllEventsText = $harborAllEventsParts -join "`n"
                    $harborWarningEventsText = $harborWarningEventsParts -join "`n"

                    # IP exhaustion check runs against events regardless of what the vCenter API reported.
                    # The vCenter service status may say "OCI Registry" while the real cause is IP exhaustion.
                    $ipExhaustionDetected = $harborAllEventsText -match "exhausted all IP addresses in requested IPPools|has 0 free ips which is less than"
                    if ($ipExhaustionDetected) {
                        $svcApiReport = if ([String]::IsNullOrWhiteSpace($svcErrorDetail)) { "no detail" } else { "`"$svcErrorDetail`"" }
                        Write-LogMessage -Type ERROR -Message "ROOT CAUSE — workload network IP pool exhausted: pods could not get IP addresses. The vCenter service API reported $svcApiReport but the underlying cause is visible in Kubernetes events."
                        Write-LogMessage -Type ERROR -Message "DIAGNOSIS: The supervisor workload network IP pool has no free addresses. Harbor pods were scheduled but their network interfaces could not be realized."
                        Write-LogMessage -Type ERROR -Message "SOLUTION: Increase the pool size in supervisor.json: raise `"siteSpec[N].primaryWorkloadNetwork.primaryWorkloadNetworkIPCount`" to allocate more addresses, then roll back (Y) and redeploy. As a guide, Harbor needs one IP per pod (~9 pods); add at least 16 to the current count to leave headroom."
                        $ipExhaustionLines = $harborAllEventsText -split "`n" | Where-Object { $_ -match "exhausted|has 0 free ips|NetworkInterfaceRealizationFailed" }
                        if ($ipExhaustionLines.Count -gt 0) {
                            Write-LogMessage -Type ERROR -Message "IP exhaustion events:"
                            $ipExhaustionLines | Select-Object -Unique | ForEach-Object { Write-LogMessage -Type INFO -Message "  $($_.Exception.Message)" }
                        }
                    }

                    switch -Regex ($svcErrorDetail) {
                        "OCI Registry|registry" {
                            if (-not $ipExhaustionDetected) {
                                Write-LogMessage -Type ERROR -Message "DIAGNOSIS: The OCI Registry component failed to initialize. Possible causes: (A) Stale PVCs from a prior installation hold data encrypted with different secrets — the registry pod cannot read its PVC if registry.secret changed. (B) The new deployment started before namespace `"$diagnosticNamespace`" from a prior rollback had fully terminated, leaving stale endpoint or secret objects. (C) A Harbor data values configuration error (e.g. malformed or missing registry.secret, invalid storageClass, incorrect YAML structure). If the PVCs below show a recent AGE (seconds or a few minutes), they were created by the current install — cause (A) does not apply."
                                Write-LogMessage -Type ERROR -Message "SOLUTION: (1) Roll back (choose Y) to remove this service. (2) Wait for namespace `"$diagnosticNamespace`" to terminate fully: kubectl get namespace $diagnosticNamespace (must be gone, not Terminating). (3) Confirm all PVCs are deleted: kubectl get pvc -n $diagnosticNamespace (should return 'No resources found'). (4) If PVCs were stale: re-run using the SAME secrets, OR use -CleanUp Harbor first. If PVCs were fresh (new install): check the registry pod logs below for the specific error, then verify registry.secret, storageClass, and vCenter Events on the supervisor."
                            }
                            # Check PVCs in all discovered Harbor namespaces to surface stale state.
                            foreach ($ns in $namespacesToCheck) {
                                try {
                                    $pvcOutput = & $Script:KubectlCmd get pvc -n $ns 2>&1
                                    if ($LASTEXITCODE -eq 0 -and -not [String]::IsNullOrWhiteSpace($pvcOutput)) {
                                        Write-LogMessage -Type ERROR -Message "PVCs found in `"$ns`" (check AGE — if recent, these are from the current install and are not stale):"
                                        ($pvcOutput | Out-String).Trim() -split "`n" | ForEach-Object {
                                            Write-LogMessage -Type INFO -Message "  $($_.Exception.Message)"
                                        }
                                    } elseif ($LASTEXITCODE -eq 0) {
                                        Write-LogMessage -Type INFO -Message "No PVCs found in `"$ns`". The namespace itself may still be Terminating — wait for it to disappear before redeploying."
                                    }
                                } catch {
                                    Write-LogMessage -Type DEBUG -Message "Could not list PVCs in `"$ns`": $($_.Exception.Message)"
                                }
                                # Fetch registry pod logs to surface the actual startup error.
                                try {
                                    $registryLogOutput = & $Script:KubectlCmd logs -n $ns -l "app=registry" --tail=40 --prefix 2>&1
                                    $registryLogText = ($registryLogOutput | Out-String).Trim()
                                    if ($LASTEXITCODE -eq 0 -and -not [String]::IsNullOrWhiteSpace($registryLogText) -and $registryLogText -notmatch "^No resources found") {
                                        Write-LogMessage -Type ERROR -Message "OCI Registry pod logs (last 40 lines, namespace `"$ns`") — look for the startup error:"
                                        $registryLogText -split "`n" | ForEach-Object {
                                            Write-LogMessage -Type INFO -Message "  $($_.Exception.Message)"
                                        }
                                    } else {
                                        Write-LogMessage -Type WARNING -Message "No OCI Registry pods found in `"$ns`" (label app=registry). Pod may not have been scheduled. Showing all pods:"
                                        try {
                                            $allPodsOutput = & $Script:KubectlCmd get pods -n $ns -o wide 2>&1
                                            if ($LASTEXITCODE -eq 0 -and -not [String]::IsNullOrWhiteSpace($allPodsOutput)) {
                                                ($allPodsOutput | Out-String).Trim() -split "`n" | ForEach-Object { Write-LogMessage -Type INFO -Message "  $($_.Exception.Message)" }
                                            } else {
                                                Write-LogMessage -Type INFO -Message "  (no pods found in namespace `"$ns`")"
                                            }
                                        } catch {
                                            Write-LogMessage -Type DEBUG -Message "Could not list pods in `"$ns`": $($_.Exception.Message)"
                                        }
                                        if (-not $ipExhaustionDetected -and -not [String]::IsNullOrWhiteSpace($harborWarningEventsText)) {
                                            Write-LogMessage -Type WARNING -Message "Warning events in `"$ns`":"
                                            $harborWarningEventsText -split "`n" | ForEach-Object { Write-LogMessage -Type INFO -Message "  $($_.Exception.Message)" }
                                            if ($harborAllEventsText -match "FailedScheduling.*(?:Insufficient resources.*vSphere HA|failover level for vSphere|admission control)") {
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
                        "already exists|already registered|duplicate" {
                            Write-LogMessage -Type ERROR -Message "DIAGNOSIS: vCenter's async Harbor setup tried to re-register the service globally and found it already present. This is a vCenter-side conflict; the service must be deleted from the supervisor before retrying."
                            Write-LogMessage -Type ERROR -Message "SOLUTION: Roll back (choose Y), then re-run. If this error repeats, in vCenter UI go to Menu > Supervisor Management > Services, delete `"$Service`" entirely, then re-run this script."
                        }
                        default {
                            if (-not $ipExhaustionDetected) {
                                Write-LogMessage -Type ERROR -Message "DIAGNOSIS: Harbor service configuration failed. Check vCenter Events for supervisor `"$SupervisorId`" for additional error details. Roll back (choose Y), correct the issue, and re-run."
                                if (-not [String]::IsNullOrWhiteSpace($harborWarningEventsText)) {
                                    Write-LogMessage -Type WARNING -Message "Warning events from Harbor namespaces:"
                                    $harborWarningEventsText -split "`n" | ForEach-Object { Write-LogMessage -Type INFO -Message "  $($_.Exception.Message)" }
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
        Write-LogMessage -Type ERROR -Message "Deployment failed. Harbor service configuration timed out. Check logs."
        throw [VcfDeploymentException]::new("Deployment failed. Harbor service configuration timed out. Check logs.")
    } catch [VcfDeploymentException] {
        throw  # already logged and typed — propagate without re-wrapping
    } catch {
        if ($_.Exception.Message -match "Deployment failed") { throw }
        Write-LogMessage -Type ERROR -Message "Install-HarborSupervisorService unexpected error: $($_.Exception.Message)"
        throw [VcfDeploymentException]::new("Install-HarborSupervisorService unexpected error: $($_.Exception.Message)")
    }
}
Function Test-YamlPropertyConsistency {

    <#
        .SYNOPSIS
        Validates that specified property values in a YAML file match expected values using customizable validation logic.

        .DESCRIPTION
        The Test-YamlPropertyConsistency function provides a flexible framework for parsing YAML files and validating
        property values against expected criteria. It supports custom validation logic through scriptblocks, making it
        suitable for various validation scenarios including namespace consistency, version validation, configuration
        validation, and other property-based checks.

        The function uses the native PowerShell YAML parser to process multi-document YAML files and:
        - Handles YAML files that contain multiple documents separated by '---'
        - Searches for properties using customizable path specifications
        - Applies custom validation logic through scriptblock parameters
        - Provides detailed logging of validation results and any mismatches found
        - Returns boolean result indicating whether all validations passed
        - Supports complex nested property paths and multiple validation criteria

        This function serves as a general-purpose YAML validation framework that can be adapted for various
        deployment validation scenarios including Kubernetes manifests, configuration files, and service definitions.

        .PARAMETER YamlFilePath
        The full path to the YAML file to validate. This file should contain valid YAML content that needs
        to be validated against specified criteria.

        .PARAMETER PropertyPaths
        An array of property paths to search for in the YAML documents. Each path can be:
        - Simple property name (e.g., "namespace")
        - Nested property path using dot notation (e.g., "metadata.namespace")
        - Multiple paths for comprehensive validation
        Property paths are case-sensitive and follow standard PowerShell object property access patterns.

        .PARAMETER ExpectedValues
        An array of expected values corresponding to the property paths. The validation will check if found
        property values match these expected values. The array should have the same length as PropertyPaths,
        or provide a single value to validate against all properties.

        .PARAMETER ValidationScriptBlock
        Optional custom validation logic as a scriptblock. The scriptblock receives the following parameters:
        - $foundValue: The actual value found in the YAML
        - $expectedValue: The expected value for comparison
        - $propertyPath: The property path being validated
        - $documentIndex: The document number being processed
        The scriptblock should return $true for valid values, $false for invalid values.

        .PARAMETER ValidationName
        A descriptive name for the validation operation, used in logging messages to provide context
        about what type of validation is being performed (e.g., "namespace consistency", "version validation").

        .PARAMETER AllowMissingProperties
        Switch parameter that controls behavior when properties are not found. When specified, missing
        properties are treated as acceptable and logged as warnings rather than errors.

        .EXAMPLE
        Test-YamlPropertyConsistency -YamlFilePath "/path/to/deployment.yml" -PropertyPaths @("metadata.namespace") -ExpectedValues @("argocd") -ValidationName "namespace consistency"

        Validates that all metadata.namespace values in the YAML file match "argocd".

        .EXAMPLE
        $validationScript = {
            param($documentIndex, $expectedValue, $foundValue, $propertyPath)
            return $foundValue -eq $expectedValue -and $foundValue -match '^[a-z0-9-]+$'
        }
        Test-YamlPropertyConsistency -YamlFilePath $yamlPath -PropertyPaths @("metadata.namespace", "spec.namespace") -ExpectedValues @("production") -ValidationScriptBlock $validationScript -ValidationName "namespace format validation"

        Uses custom validation logic to check both value equality and format compliance.

        .EXAMPLE
        Test-YamlPropertyConsistency -YamlFilePath $configFile -PropertyPaths @("spec.version", "metadata.labels.version") -ExpectedValues @("1.0.0", "1.0.0") -ValidationName "version consistency" -AllowMissingProperties

        Validates version consistency across multiple properties, treating missing properties as acceptable.

        .OUTPUTS
        System.Boolean
        Returns $true if all property validations pass, $false if any validations fail or if the file cannot be processed.

        .NOTES
        Prerequisites:
        - Requires the YAML file to be accessible and contain valid YAML content
        - Uses native PowerShell YAML parsing (ConvertFrom-Yaml function must be available)
        - Handles both single and multi-document YAML files

        Behavior:
        - Processes each document in multi-document YAML files independently
        - Supports nested property access using dot notation (e.g., "metadata.namespace")
        - Provides detailed logging for each property found and validation result
        - Custom validation script blocks enable complex validation scenarios
        - Property path matching is case-sensitive

        Error Handling:
        - Returns $false if the YAML file cannot be read or parsed
        - Logs detailed error information for troubleshooting
        - Handles missing properties based on allowMissingProperties parameter
        - Comprehensive exception handling for file access and YAML parsing errors

        Performance:
        - Efficient single-pass processing of YAML documents
        - Minimal memory footprint for large YAML files
        - Optimized property path resolution using hashtable key access

        Integration:
        - Integrates with VCF PowerShell Toolbox logging infrastructure
        - Designed for use in automated deployment and validation scenarios
        - Compatible with existing YAML processing workflows in the codebase
    #>

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
        # Validate that the YAML file exists.

        if (-not (Test-Path -Path $YamlFilePath -PathType Leaf)) {
            $currentDir = Get-Location
            # Detect if path is a Windows absolute path (starts with drive letter like C:\ or C:/)
            $isWindowsAbsolutePath = $YamlFilePath -match '^[A-Za-z]:[\\/]'
            # Detect if path is Unix absolute path (starts with /)
            $isUnixAbsolutePath = $YamlFilePath -match '^/'
            # Detect if path is absolute (either Windows or Unix style)
            $isAbsolutePath = $isWindowsAbsolutePath -or $isUnixAbsolutePath

            Write-LogMessage -Type ERROR -Message "YAML file not found for $ValidationName validation."
            Write-LogMessage -Type ERROR -Message "  Specified path: `"$YamlFilePath`""

            if ($isWindowsAbsolutePath) {
                Write-LogMessage -Type ERROR -Message "  Note: The specified path is a Windows absolute path. On non-Windows systems, please update your configuration file (infrastructure.json) to use a relative path or a Unix-style absolute path."
            } elseif (-not $isAbsolutePath) {
                # Only show resolved path for relative paths.

                $resolvedPath = Join-Path $currentDir $YamlFilePath
                Write-LogMessage -Type ERROR -Message "  Resolved path: `"$resolvedPath`""
            }

            Write-LogMessage -Type ERROR -Message "  Current working directory: `"$currentDir`""
            Write-LogMessage -Type ERROR -Message "  Please verify the file path in your configuration file (infrastructure.json) and ensure the file exists."
            return $false
        }

        # Validate parameter consistency
        if ($ExpectedValues.Count -ne 1 -and $ExpectedValues.Count -ne $PropertyPaths.Count) {
            Write-LogMessage -Type ERROR -Message "Expected values count must be 1 (for all properties) or match property paths count. PropertyPaths: $($PropertyPaths.Count), ExpectedValues: $($ExpectedValues.Count)"
            return $false
        }

        Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Starting $ValidationName validation for YAML file: `"$YamlFilePath`""
        Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Property paths to validate: $($PropertyPaths -join ', ')"
        Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Expected values: $($ExpectedValues -join ', ')"

        $yamlContent = Get-Content -Raw -Path $YamlFilePath

        # Split multi-document YAML by --- separator.

        # Use regex to handle different line endings (Unix: \n, Windows: \r\n)
        $documents = $yamlContent -split '(?m)^---\s*$'

        $config = @()
        foreach ($docContent in $documents) {
            $docContent = $docContent.Trim()
            if ($docContent) {
                $doc = ConvertFrom-Yaml -YamlContent $docContent

                if ($doc -is [hashtable]) {
                    # YAML parser returned a hashtable directly.

                    $config += $doc
                } elseif ($doc.Count -gt 0 -and $null -ne $doc[0]) {
                    # YAML parser returned an array with hashtable.

                    $config += $doc[0]
                }
            }
        }

        $validationFailed = $false
        $documentsChecked = 0
        $propertiesFound = 0
        $validationResults = [System.Collections.ArrayList]::new()

        # Check each document for the specified properties.

        foreach ($doc in $config) {
            if ($null -eq $doc) { continue }
            $documentsChecked++

            for ($pathIndex = 0; $pathIndex -lt $PropertyPaths.Count; $pathIndex++) {
                $propertyPath = $PropertyPaths[$pathIndex]
                $expectedValue = if ($ExpectedValues.Count -eq 1) { $ExpectedValues[0] } else { $ExpectedValues[$pathIndex] }

                # Navigate to the property using dot notation.

                $foundValue = $null
                $propertyFound = $false
                $currentObject = $doc
                $pathParts = $propertyPath -split '\.'

                foreach ($part in $pathParts) {
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

                    # Apply validation logic
                    $isValid = $false
                    if ($null -ne $ValidationScriptBlock) {
                        # Use custom validation scriptblock.

                        try {
                            $isValid = & $ValidationScriptBlock -foundValue $foundValue -expectedValue $expectedValue -propertyPath $propertyPath -documentIndex $documentsChecked
                        } catch {
                            Write-LogMessage -Type ERROR -Message "Custom validation scriptblock failed for property `"$propertyPath`" in document $documentsChecked : $($_.Exception.Message)"
                            $isValid = $false
                        }
                    } else {
                        # Use default equality validation.

                        $isValid = ($foundValue -eq $expectedValue)
                    }

                    if (-not $isValid) {
                        Write-LogMessage -Type ERROR -Message "$ValidationName validation failed in file `"$YamlFilePath`" for property `"$propertyPath`". Expected: `"$expectedValue`", Found: `"$foundValue`"."
                        $validationFailed = $true
                    } else {
                        Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "$ValidationName validation on YAML file `"$YamlFilePath`": for property `"$propertyPath`"."
                    }

                    $null = $validationResults.Add(@{
                        DocumentIndex = $documentsChecked
                        PropertyPath = $propertyPath
                        FoundValue = $foundValue
                        ExpectedValue = $expectedValue
                        IsValid = $isValid
                    })
                } else {
                    # Property not found
                    $message = "Property `"$propertyPath`" not found in document $documentsChecked"
                    if ($AllowMissingProperties) {
                        Write-LogMessage -Type WARNING -Message "$message - treating as acceptable due to allowMissingProperties flag."
                    } else {
                        Write-LogMessage -Type ERROR -Message "$message - this is considered a validation failure."
                        $validationFailed = $true
                    }

                    $null = $validationResults.Add(@{
                        DocumentIndex = $documentsChecked
                        PropertyPath = $propertyPath
                        FoundValue = $null
                        ExpectedValue = $expectedValue
                        IsValid = $AllowMissingProperties
                    })
                }
            }
        }

        Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "$ValidationName validation completed - Documents checked: $documentsChecked, Properties found: $propertiesFound."

        if ($propertiesFound -eq 0 -and -not $AllowMissingProperties) {
            Write-LogMessage -Type ERROR -Message "No properties matching the specified paths were found in the YAML file."
            return $false
        }

        if ($validationFailed) {
            Write-LogMessage -Type ERROR -Message "$ValidationName validation failed - One or more property values did not meet the validation criteria."
            return $false
        } else {
            Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "$ValidationName validation successful - All property values passed validation."
            return $true
        }

    } catch {
        Write-LogMessage -Type ERROR -Message "Failed to perform $ValidationName validation on YAML file `"$YamlFilePath`": $($_.Exception.Message)"
        return $false
    }
}
Function Get-ArgoCDServiceDetail {

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

        $config = @()
        foreach ($docContent in $documents) {
            $docContent = $docContent.Trim()
            if ($docContent) {
                $doc = ConvertFrom-Yaml -YamlContent $docContent

                if ($doc -is [hashtable]) {
                    # YAML parser returned a hashtable directly.

                    $config += $doc
                    Write-LogMessage -Type DEBUG -Message "Parsed document as hashtable with keys: $($doc.Keys -join ', ')"
                } elseif ($doc.Count -gt 0 -and $null -ne $doc[0]) {
                    # YAML parser returned an array with hashtable.

                    $config += $doc[0]
                    Write-LogMessage -Type DEBUG -Message "Parsed document as array, extracted first element with keys: $($doc[0].Keys -join ', ')"
                }
            }
        }

        Write-LogMessage -Type DEBUG -Message "Total parsed YAML documents: $($config.Count)"
    } catch [VcfDeploymentException] {
        throw  # already logged and typed — propagate without re-wrapping
    } catch {
        Write-LogMessage -Type ERROR -Message "Failed to convert YAML file to JSON: $($_.Exception.Message)"
        throw [VcfDeploymentException]::new("Failed to convert YAML file to JSON: $($_.Exception.Message)")
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
Function Get-ContentLibraryId {

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

    # Get the content library id from the content library name.
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$LibraryName
    )
    Write-LogMessage -Type DEBUG -Message "Entered Get-ContentLibraryId function..."

    $connectionTest = Test-VcenterConnection
    if (-not $connectionTest.IsConnected) {
        Write-LogMessage -Type ERROR -Message "Not connected to vCenter `"$Script:vCenterName`": $($connectionTest.ErrorMessage)"
        throw [VcfDeploymentException]::new("Not connected to vCenter `"$Script:vCenterName`": $($connectionTest.ErrorMessage)")
    }

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
        Write-LogMessage -Type ERROR -Message "Failed to retrieve content library `"$LibraryName`" from `"$Script:vCenterName`": $($_.Exception.Message)"
        throw [VcfDeploymentException]::new("Failed to retrieve content library `"$LibraryName`" from `"$Script:vCenterName`": $($_.Exception.Message)")
    }
}
Function New-VCenterRestApiSession {

    <#
        .SYNOPSIS
        Creates an authenticated REST API session with vCenter.

        .DESCRIPTION
        Establishes a REST API session with vCenter using Basic authentication.
        This function handles credential encoding, session creation, and returns session
        headers that can be used for subsequent API calls.

        The function performs Basic authentication with Base64 encoding of credentials
        and creates a session token that can be reused for multiple API operations,
        reducing the need for repeated authentication.

        Based on vCenter REST API authentication patterns.

        .PARAMETER VcenterUser
        Username for vCenter authentication. Must have sufficient privileges
        to access the required API endpoints.

        .PARAMETER VcenterInsecurePassword
        Password as a string for Basic authentication.

        .PARAMETER VcenterPassword
        Password as SecureString for Basic authentication. Takes precedence over VcenterInsecurePassword when both are supplied.
        At least one of VcenterPassword or VcenterInsecurePassword must yield a non-empty value.

        .PARAMETER InsecureTls
        Switch to bypass SSL certificate validation for vCenter connections.
        When specified, certificate validation is skipped. If not specified, the function
        will check PowerCLI's configuration for InvalidCertificateAction = 4 (ignore) and
        automatically enable insecure TLS if the user has configured PowerCLI to ignore
        certificate validation failures.

        .OUTPUTS
        PSCustomObject with the following properties:
        • Success (Boolean): Indicates if session creation succeeded
        • SessionHeaders (Hashtable): Headers for API calls with session ID
        • SessionId (String): The session ID token
        • ErrorMessage (String): Error details if Success is $false

        .EXAMPLE
        $session = New-VCenterRestApiSession -VcenterUser "admin@vsphere.local" -VcenterInsecurePassword "password"
        if ($session.Success) {
            $response = Invoke-RestMethod -Uri "https://vcenter/api/endpoint" -Headers $session.SessionHeaders
        }

        .EXAMPLE
        $secure = Read-Host -AsSecureString -Prompt "vCenter password"
        $session = New-VCenterRestApiSession -VcenterUser "admin@vsphere.local" -VcenterPassword $secure -InsecureTls

        .EXAMPLE
        $sessionParams = @{
            VcenterUser = $Script:VCenterUser
            VcenterInsecurePassword = $password
            InsecureTls = $true
        }
        $session = New-VCenterRestApiSession @sessionParams

        .NOTES
        API Endpoint: POST /rest/com/vmware/cis/session

        Authentication Method: Basic authentication with Base64 encoding

        Error Handling:
        • Returns structured object instead of throwing exceptions
        • Follows script-wide pattern of using return instead of throw
        • Detailed error logging for troubleshooting

        IMPORTANT - Password validation:
        • Supply VcenterPassword (SecureString), VcenterCredential (PSCredential), or VcenterInsecurePassword (String). Priority: VcenterPassword > VcenterCredential > VcenterInsecurePassword. If all are missing or empty, the function returns Success = $false (no Basic auth "user:" call).
        • A null or empty effective password would produce Basic auth "user:" and cause 401 from vCenter; that case is rejected before Invoke-RestMethod.
    #>

    [CmdletBinding()]
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
        # Initialize InsecureTls based on whether it was explicitly provided.
        $insecureTlsValue = $false
        if ($PSBoundParameters.ContainsKey('InsecureTls')) {
            $insecureTlsValue = $InsecureTls
            Write-LogMessage -Type DEBUG -Message "InsecureTls explicitly provided: $insecureTlsValue"
        } else {
            # If InsecureTls not explicitly provided, check PowerCLI configuration for user's certificate validation preference.
            # PowerCLI InvalidCertificateAction = 4 means "ignore" (connect without warnings, completely ignoring certificate validation failure).
            try {
                $powerCliConfig = Get-PowerCLIConfiguration -ErrorAction Stop
                if ($powerCliConfig) {
                    Write-LogMessage -Type DEBUG -Message "Retrieved PowerCLI configuration. Checking for InvalidCertificateAction = 4..."

                    # Check scopes in order of precedence: Session (1), User (2), AllUsers (4).
                    # Use the first scope that has InvalidCertificateAction = 4.
                    $sessionConfig = $powerCliConfig | Where-Object { $_.Scope -eq 1 -and $null -ne $_.InvalidCertificateAction } | Select-Object -First 1
                    $userConfig = $powerCliConfig | Where-Object { $_.Scope -eq 2 -and $null -ne $_.InvalidCertificateAction } | Select-Object -First 1
                    $allUsersConfig = $powerCliConfig | Where-Object { $_.Scope -eq 4 -and $null -ne $_.InvalidCertificateAction } | Select-Object -First 1

                    Write-LogMessage -Type DEBUG -Message "Session scope (1) config: InvalidCertificateAction = $($sessionConfig.InvalidCertificateAction)" -SuppressOutputToScreen
                    Write-LogMessage -Type DEBUG -Message "User scope (2) config: InvalidCertificateAction = $($userConfig.InvalidCertificateAction)" -SuppressOutputToScreen
                    Write-LogMessage -Type DEBUG -Message "AllUsers scope (4) config: InvalidCertificateAction = $($allUsersConfig.InvalidCertificateAction)" -SuppressOutputToScreen

                    $configToCheck = $null
                    if ($sessionConfig) {
                        $configToCheck = $sessionConfig
                        Write-LogMessage -Type DEBUG -Message "Using Session scope (1) configuration for certificate validation preference."
                    } elseif ($userConfig) {
                        $configToCheck = $userConfig
                        Write-LogMessage -Type DEBUG -Message "Using User scope (2) configuration for certificate validation preference."
                    } elseif ($allUsersConfig) {
                        $configToCheck = $allUsersConfig
                        Write-LogMessage -Type DEBUG -Message "Using AllUsers scope (4) configuration for certificate validation preference."
                    }

                    if ($configToCheck) {
                        Write-LogMessage -Type DEBUG -Message "Found PowerCLI configuration with InvalidCertificateAction = $($configToCheck.InvalidCertificateAction)"
                        if ($configToCheck.InvalidCertificateAction -eq 4) {
                            $insecureTlsValue = $true
                            Write-LogMessage -Type DEBUG -Message "PowerCLI configuration has InvalidCertificateAction = 4 (ignore). Automatically enabling insecure TLS for REST API session."
                        } else {
                            Write-LogMessage -Type DEBUG -Message "PowerCLI configuration has InvalidCertificateAction = $($configToCheck.InvalidCertificateAction) (not 4). Using secure TLS (certificate validation enabled)."
                        }
                    } else {
                        Write-LogMessage -Type DEBUG -Message "No PowerCLI configuration found with InvalidCertificateAction set. Using secure TLS (certificate validation enabled)."
                    }
                } else {
                    Write-LogMessage -Type DEBUG -Message "Get-PowerCLIConfiguration returned null or empty. Using secure TLS (certificate validation enabled)."
                }
            } catch {
                Write-LogMessage -Type DEBUG -Message "Could not retrieve PowerCLI configuration: $($_.Exception.Message). Assuming secure TLS (certificate validation enabled)."
            }
        }

        $plainForAuth = Get-VcenterRestApiPlainPassword -VcenterPassword $VcenterPassword -VcenterCredential $VcenterCredential -VcenterInsecurePassword $VcenterInsecurePassword
        if ([string]::IsNullOrWhiteSpace($plainForAuth)) {
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

        # Create session with vCenter REST API.
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

        # Return success result with session information.
        return [PSCustomObject]@{
            Success = $true
            SessionHeaders = $authHeaders
            SessionId = $sessionId
            ErrorMessage = $null
        }
    } catch {
        $errorMessage = $_.Exception.Message
        $innerException = $_.Exception.InnerException

        # Classify error and log appropriate message (first match wins).
        switch -Regex ($errorMessage) {
            "401|Unauthorized" {
                Write-LogMessage -Type ERROR -Message "Failed to create REST API session: authentication failed (401 Unauthorized). vCenter rejected the credentials for user `"$VcenterUser`"."
                if ($innerException) {
                    Write-LogMessage -Type DEBUG -Message "Inner exception: $($innerException.Message)"
                }
                Write-LogMessage -Type WARNING -Message "Verify the vCenter username and password in your input (common.vCenterUser and the password you entered). Ensure the account has privileges to use the vCenter REST API and namespace management."
                Write-LogMessage -Type WARNING -Message "Common causes: wrong password (use the vCenter SSO password for this user, not the ESX host password); account locked or expired; or user lacks Administrator / REST API / namespace management role."
                break
            }
            "SSL|certificate|TLS|The SSL connection could not be established" {
                Write-LogMessage -Type ERROR -Message "Failed to create REST API session due to SSL certificate validation error: $errorMessage."
                if ($innerException) {
                    Write-LogMessage -Type DEBUG -Message "Inner exception details: $($innerException.Message)"
                }
                Write-Host ""
                Write-LogMessage -Type WARNING -Message "SSL certificate validation failed when connecting to vCenter REST API."
                Write-LogMessage -Type WARNING -Message "This typically occurs when:"
                Write-LogMessage -Type WARNING -Message "  1. vCenter uses a self-signed certificate (common in lab environments)"
                Write-LogMessage -Type WARNING -Message "  2. Certificate chain is incomplete or expired"
                Write-LogMessage -Type WARNING -Message "  3. Certificate name doesn't match the vCenter hostname"
                Write-Host ""
                Write-LogMessage -Type WARNING -Message "SOLUTION: For lab environments with self-signed certificates, you can:"
                Write-LogMessage -Type WARNING -Message "  1. Import the vCenter certificate to the trusted certificate store"
                Write-LogMessage -Type WARNING -Message "  2. Use a properly signed certificate for vCenter"
                Write-LogMessage -Type WARNING -Message "  3. Note: The content library association will be skipped, but deployment will continue"
                Write-Host ""
                break
            }
            default {
                Write-LogMessage -Type ERROR -Message "Failed to create REST API session: $errorMessage."
                if ($innerException) {
                    Write-LogMessage -Type DEBUG -Message "Inner exception: $($innerException.Message)"
                }
            }
        }

        # Return failure result.
        return [PSCustomObject]@{
            Success = $false
            SessionHeaders = $null
            SessionId = $null
            ErrorMessage = $errorMessage
        }
    }
}
Function Find-SupervisorByName {

    <#
        .SYNOPSIS
        Searches for a supervisor cluster by name using vCenter REST API.

        .DESCRIPTION
        Queries the vCenter namespace management API to find a supervisor cluster
        by its name. This function retrieves all supervisor summaries and searches
        for a match by name (case-insensitive; PowerShell -eq is case-insensitive for strings).

        If the supervisor is found, returns the supervisor ID. If not found,
        returns $null (this is not considered an error - the supervisor may
        not have been created yet).

        Based on vCenter namespace management API patterns.

        .PARAMETER SupervisorName
        Name of the supervisor cluster to search for. Search is case-insensitive
        (PowerShell -eq); "supervisor-OSA" and "supervisor-osa" both match the same object.

        .PARAMETER SessionHeaders
        Hashtable containing authenticated session headers from New-VCenterRestApiSession.
        Must include "vmware-api-session-id" header.

        .PARAMETER InsecureTls
        Switch to bypass SSL certificate validation for vCenter API calls.

        .OUTPUTS
        PSCustomObject with the following properties:
        • Success (Boolean): Indicates if API query succeeded
        • SupervisorId (String): Supervisor cluster ID if found, $null if not found
        • Found (Boolean): $true if supervisor exists, $false if not found
        • ErrorMessage (String): Error details if Success is $false

        .EXAMPLE
        $result = Find-SupervisorByName -SupervisorName "prod-supervisor" -SessionHeaders $session.SessionHeaders
        if ($result.Success -and $result.Found) {
            Write-LogMessage -Type INFO -Message "Found supervisor: $($result.SupervisorId)"
        }

        .EXAMPLE
        $findParams = @{
            SupervisorName = $SupervisorName
            SessionHeaders = $session.SessionHeaders
            InsecureTls = $true
        }
        $result = Find-SupervisorByName @findParams

        .NOTES
        API Endpoint: GET /api/vcenter/namespace-management/supervisors/summaries

        Behavior:
        • Queries all supervisor summaries (may be slow with many supervisors)
        • Performs case-insensitive name matching (PowerShell -eq default)
        • Returns $null for SupervisorId if not found (not an error condition)
        • Success=$true even if supervisor not found (query succeeded)

        Error Handling:
        • Returns structured object instead of throwing exceptions
        • API failures return Success=$false
        • Not found returns Success=$true, Found=$false
    #>

    Param (
        [Parameter(Mandatory = $false)] [Switch]$InsecureTls,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Hashtable]$SessionHeaders
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

            # Return success with found supervisor.
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

        # Return failure result.
        return [PSCustomObject]@{
            Success = $false
            SupervisorId = $null
            Found = $false
            ErrorMessage = $errorMessage
        }
    }
}
Function Wait-SupervisorDiscoverable {

    <#
        .SYNOPSIS
        Waits for a supervisor cluster to become discoverable and reach READY status.

        .DESCRIPTION
        Polls the vCenter namespace management API until the supervisor cluster becomes
        available and reaches READY kubernetes_status. This function implements a
        configurable timeout and check interval pattern with progress tracking.

        The function continuously queries the supervisor status until either:
        • Supervisor reaches READY status (success)
        • Timeout is reached (failure)
        • Supervisor disappears during wait (failure)

        Based on polling patterns similar to Wait-SupervisorReady.

        .PARAMETER SupervisorName
        Name of the supervisor cluster to wait for. Used for status queries and logging.

        .PARAMETER SessionHeaders
        Hashtable containing authenticated session headers from New-VCenterRestApiSession.

        .PARAMETER TimeoutSeconds
        Maximum time to wait for supervisor to become ready, in seconds.
        Defaults to 3600 seconds (1 hour).

        .PARAMETER CheckInterval
        Interval between status checks, in seconds. Defaults to 5 seconds.
        Lower values provide more frequent updates but increase API load.

        .PARAMETER InsecureTls
        Switch to bypass SSL certificate validation for vCenter API calls.

        .OUTPUTS
        PSCustomObject with the following properties:
        • Success (Boolean): $true if supervisor reached READY status
        • SupervisorId (String): Supervisor ID if found, $null otherwise
        • ElapsedSeconds (Int): Total time waited
        • LastStatus (String): Last kubernetes_status observed
        • ErrorMessage (String): Error details if Success is $false

        .EXAMPLE
        $waitResult = Wait-SupervisorDiscoverable -SupervisorName "prod-supervisor" -SessionHeaders $session.SessionHeaders -TimeoutSeconds 600
        if ($waitResult.Success) {
            Write-LogMessage -Type INFO -Message "Supervisor ready after $($waitResult.ElapsedSeconds) seconds"
        }

        .EXAMPLE
        $waitParams = @{
            SupervisorName = $name
            SessionHeaders = $headers
            TimeoutSeconds = 1800
            CheckInterval = 30
            InsecureTls = $true
        }
        $result = Wait-SupervisorDiscoverable @waitParams

        .NOTES
        API Endpoint: GET /api/vcenter/namespace-management/supervisors/summaries

        Polling Pattern:
        • Checks status every CheckInterval seconds
        • Uses Write-Progress for visual feedback
        • Terminates on timeout or supervisor ready
        • Fails if supervisor disappears during wait

        Performance Considerations:
        • Network latency affects check responsiveness
        • Lower check intervals increase API call frequency
        • Consider timeout based on environment provisioning time

        Error Handling:
        • Returns structured object instead of throwing exceptions
        • Timeout is considered a failure (Success=$false)
        • Provides last known status for troubleshooting
    #>

    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(1, [int]::MaxValue)] [Int]$CheckInterval = 5,
        [Parameter(Mandatory = $false)] [Switch]$InsecureTls,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Hashtable]$SessionHeaders,
        [Parameter(Mandatory = $false)] [ValidateRange(1, [int]::MaxValue)] [Int]$TimeoutSeconds = 3600
    )

    Write-LogMessage -Type DEBUG -Message "Entered Wait-SupervisorDiscoverable function..."

    Write-LogMessage -Type DEBUG -Message "  Waiting for supervisor `"$SupervisorName`" to become ready (timeout: $TimeoutSeconds seconds)..."

    $elapsedTime = 0
    $lastStatus = "UNKNOWN"
    $supervisorId = $null

    do {
        try {
            # Query supervisor summaries to get current status.
            $response = Invoke-RestMethod -Method GET `
                -Uri "https://$Script:vCenterName/api/vcenter/namespace-management/supervisors/summaries" `
                -Headers $SessionHeaders `
                -SkipCertificateCheck:$InsecureTls `
                -ErrorAction Stop

            # Find the matching supervisor instance.
            $supervisorInstance = $response.items | Where-Object { $_.info.name -eq $SupervisorName }

            if (-not $supervisorInstance) {
                Write-LogMessage -Type ERROR -Message "  Supervisor `"$SupervisorName`" disappeared during wait"
                Write-Progress -Activity "Waiting for Supervisor `"$SupervisorName`"" -Status "Error: Supervisor disappeared" -Completed

                # Return failure - supervisor disappeared.
                return [PSCustomObject]@{
                    Success = $false
                    SupervisorId = $null
                    ElapsedSeconds = $elapsedTime
                    LastStatus = $lastStatus
                    ErrorMessage = "Supervisor disappeared during wait"
                }
            }

            # Get current status and supervisor ID.
            $lastStatus = $supervisorInstance.info.kubernetes_status
            $supervisorId = $supervisorInstance.supervisor.ToString()

            # Check if supervisor is ready.
            if ($lastStatus -eq "READY") {
                Write-Progress -Activity "Waiting for Supervisor `"$SupervisorName`"" -Status "Ready" -Completed
                Write-LogMessage -Type DEBUG -Message "  Supervisor `"$SupervisorName`" reached READY status after $elapsedTime seconds"

                # Return success.
                return [PSCustomObject]@{
                    Success = $true
                    SupervisorId = $supervisorId
                    ElapsedSeconds = $elapsedTime
                    LastStatus = $lastStatus
                    ErrorMessage = $null
                }
            }

            # If status is ERROR or other non-ready states, query Conditions endpoint for detailed error information.
            if ($lastStatus -eq "ERROR" -or ($lastStatus -ne "READY" -and $lastStatus -ne "CREATING" -and $lastStatus -ne "CONFIGURING")) {
                try {
                    $conditionsResponse = Invoke-RestMethod -Method GET `
                        -Uri "https://$Script:vCenterName/api/vcenter/namespace-management/supervisors/$supervisorId/conditions" `
                        -Headers $SessionHeaders `
                        -SkipCertificateCheck:$InsecureTls `
                        -ErrorAction Stop

                    if ($conditionsResponse -and $conditionsResponse.items) {
                        $errorDetails = @()
                        foreach ($condition in $conditionsResponse.items) {
                            if ($condition.type -and $condition.message) {
                                $errorDetails += "$($condition.type): $($condition.message)"
                            } elseif ($condition.message) {
                                $errorDetails += $condition.message
                            }
                        }
                        if ($errorDetails.Count -gt 0) {
                            # Log error details at INFO level for ERROR status, DEBUG for other non-ready states.
                            $logLevel = if ($lastStatus -eq "ERROR") { "INFO" } else { "DEBUG" }
                            Write-LogMessage -Type $logLevel -Message "  Supervisor `"$SupervisorName`" ($lastStatus) error details: $($errorDetails -join '; ')"
                        }
                    }
                } catch {
                    # If Conditions endpoint fails, log available info from summary.
                    Write-LogMessage -Type DEBUG -Message "  Unable to retrieve detailed error conditions for supervisor `"$SupervisorName`": $($_.Exception.Message)"
                }

                # Also check if there are any other error-related fields in the info object.
                if ($supervisorInstance.info.PSObject.Properties['config_status']) {
                    $configStatus = $supervisorInstance.info.config_status
                    if ($configStatus -and $configStatus -ne "RUNNING") {
                        Write-LogMessage -Type DEBUG -Message "  Supervisor `"$SupervisorName`" config_status: $configStatus"
                    }
                }
            }

            # Update progress with current status.
            $statusMessage = "Status: $lastStatus"
            $currentOperation = "Elapsed: $elapsedTime seconds"
            Write-Progress -Activity "Waiting for Supervisor `"$SupervisorName`"" -Status $statusMessage -CurrentOperation $currentOperation

            # Wait before next check.
            Start-Sleep $CheckInterval
            $elapsedTime += $CheckInterval
        } catch {
            $errorMessage = $_.Exception.Message
            Write-LogMessage -Type ERROR -Message "  Error during supervisor status check: $errorMessage."
            Write-Progress -Activity "Waiting for Supervisor `"$SupervisorName`"" -Status "Error" -Completed

            # Return failure.
            return [PSCustomObject]@{
                Success = $false
                SupervisorId = $null
                ElapsedSeconds = $elapsedTime
                LastStatus = $lastStatus
                ErrorMessage = $errorMessage
            }
        }
    } while ($elapsedTime -lt $TimeoutSeconds)

    # Timeout reached without supervisor becoming ready. Query Conditions endpoint for error details if supervisor ID is available.
    if ($supervisorId -and $lastStatus -ne "READY") {
        try {
            $conditionsResponse = Invoke-RestMethod -Method GET `
                -Uri "https://$Script:vCenterName/api/vcenter/namespace-management/supervisors/$supervisorId/conditions" `
                -Headers $SessionHeaders `
                -SkipCertificateCheck:$InsecureTls `
                -ErrorAction Stop

            if ($conditionsResponse -and $conditionsResponse.items) {
                $errorDetails = @()
                foreach ($condition in $conditionsResponse.items) {
                    if ($condition.type -and $condition.message) {
                        $errorDetails += "$($condition.type): $($condition.message)"
                    } elseif ($condition.message) {
                        $errorDetails += $condition.message
                    }
                }
                if ($errorDetails.Count -gt 0) {
                    Write-LogMessage -Type ERROR -Message "  Supervisor `"$SupervisorName`" error details: $($errorDetails -join '; ')"
                }
            }
        } catch {
            # If Conditions endpoint fails, continue with timeout message.
            Write-LogMessage -Type DEBUG -Message "  Unable to retrieve detailed error conditions for supervisor `"$SupervisorName`" on timeout: $($_.Exception.Message)"
        }
    }

    Write-Progress -Activity "Waiting for Supervisor `"$SupervisorName`"" -Status "Timeout" -Completed
    Write-LogMessage -Type ERROR -Message "  Supervisor `"$SupervisorName`" did not become ready after $TimeoutSeconds seconds (last status: $lastStatus)"

    # Return failure - timeout.
    return [PSCustomObject]@{
        Success = $false
        SupervisorId = $supervisorId
        ElapsedSeconds = $elapsedTime
        LastStatus = $lastStatus
        ErrorMessage = "Timeout waiting for supervisor to become ready (last status: $lastStatus)"
    }
}
Function Get-SupervisorId {

    <#
        .SYNOPSIS
        Retrieves the unique identifier of a vSphere Supervisor cluster using vCenter REST API authentication.

        .DESCRIPTION
        The Get-SupervisorId function queries the vSphere Supervisor cluster infrastructure using vCenter
        REST APIs to retrieve the unique identifier of a specified supervisor cluster. This function performs
        direct REST API authentication and namespace management queries to locate supervisor clusters by name
        and return their corresponding identifiers.

        The function performs the following key operations:
        • Establishes REST API session with vCenter using Basic authentication
        • Queries the namespace management supervisors API endpoint for cluster summaries
        • Searches through supervisor instances to match the specified supervisor name
        • Waits for the supervisor instance to become available (READY status) with configurable timeout
        • Returns the unique supervisor identifier for use in subsequent Kubernetes operations
        • Provides comprehensive error handling for authentication and API communication failures

        This function is essential for vSphere with Tanzu operations as supervisor IDs are required for
        namespace creation, service installation, and other Kubernetes management tasks within the
        vSphere Supervisor cluster ecosystem. The function uses direct REST API calls rather than
        PowerCLI cmdlets for more granular control over authentication and error handling.

        Key features:
        - Direct vCenter REST API integration with session-based authentication
        - Comprehensive supervisor cluster discovery and identification
        - Configurable wait for supervisor readiness with progress indication
        - Basic authentication with Base64 encoding for vCenter access
        - Certificate validation bypass for development and lab environments
        - Detailed error logging with context-specific troubleshooting information
        - Integration with vSphere namespace management infrastructure
        - Optional silent mode to suppress informational log messages
        - Configurable timeout and check interval parameters for flexible operation

        .PARAMETER Silence
        Optional switch parameter that suppresses informational log messages when the supervisor
        becomes ready. When specified, the function will only output error messages and not success
        messages. Useful for silent operations or when integrating with automated workflows where
        verbose output is not desired.

        .PARAMETER SupervisorName
        The name of the vSphere Supervisor cluster for which to retrieve the unique identifier.
        This should match the supervisor cluster name as configured in vCenter and must
        correspond to an existing, properly configured supervisor cluster. The name is case-sensitive
        and must match exactly as it appears in the vCenter inventory.

        .PARAMETER VcenterUser
        The username for vCenter authentication with sufficient privileges to access namespace
        management APIs. This user must have permissions to query supervisor cluster information and
        access the vCenter REST API endpoints. Typically requires administrator-level privileges or
        specific RBAC permissions for namespace management operations.

        .PARAMETER VcenterInsecurePassword
        Password as a string for REST Basic auth. Not read when Script:VcenterInsecurePassword is set.

        .PARAMETER VcenterPassword
        Optional SecureString for REST Basic auth when Script:VcenterInsecurePassword is not set.
        Takes precedence over VcenterInsecurePassword when both parameters are supplied.

        .PARAMETER TotalWaitTime
        Optional integer parameter specifying the maximum time to wait for the supervisor to become
        ready, in seconds. Defaults to 3600 seconds (1 hour) if not specified. The function will
        continuously check the supervisor status at the specified CheckInterval until either the
        supervisor becomes ready or this timeout is reached. Setting this to a lower value will
        cause the function to fail faster if the supervisor takes longer than expected to become ready.

        .PARAMETER CheckInterval
        Optional integer parameter specifying the interval between status checks, in seconds.
        Defaults to 5 seconds if not specified. The function will query the supervisor status
        every CheckInterval seconds during the wait period. Lower values provide more frequent
        updates but may increase API load, while higher values reduce API calls but provide
        less frequent status updates.

        .PARAMETER InsecureTls
        Optional switch that skips SSL certificate validation for the vCenter connection (typical lab or self-signed setups).

        .EXAMPLE
        $vcPass = Read-Host -AsSecureString -Prompt "vCenter password"
        Get-SupervisorId -SupervisorName "Production-Supervisor" -VcenterUser "administrator@vsphere.local" -VcenterPassword $vcPass -InsecureTls

        Same as the string-password example but passes a SecureString into the REST path.

        .EXAMPLE
        Get-SupervisorId -SupervisorName "Production-Supervisor" -VcenterUser "administrator@vsphere.local" -VcenterInsecurePassword "VMware1!"

        Retrieves the unique identifier for the supervisor cluster named "Production-Supervisor" using
        administrator credentials. The function will authenticate with vCenter and return the supervisor ID
        if the cluster exists and is accessible.

        .EXAMPLE
        $supervisorId = Get-SupervisorId -supervisorName $Script:SupervisorName -VcenterUser $Script:VCenterUser -VcenterInsecurePassword $VcenterInsecurePassword

        Uses script-scoped variables to retrieve the supervisor ID, demonstrating integration with
        larger deployment workflows where credentials and names are managed centrally.

        .EXAMPLE
        if ($supervisorId = Get-SupervisorId -supervisorName "Test-Supervisor" -VcenterUser $VcenterUser -VcenterInsecurePassword $vcenterPass) {
            Write-LogMessage -Type INFO -Message "Found supervisor with ID: $supervisorId"
        }

        Demonstrates conditional supervisor ID retrieval with immediate usage, useful for validation
        scenarios where supervisor existence needs to be verified before proceeding with operations.

        .EXAMPLE
        $supervisorId = Get-SupervisorId -supervisorName "Test-Supervisor" -VcenterUser $VcenterUser -VcenterInsecurePassword $vcenterPass -silence

        Retrieves the supervisor ID in silent mode, suppressing informational log messages. The function
        will still display progress indicators and error messages, but won't log success messages when
        the supervisor becomes ready. Useful in automated workflows or when reducing log verbosity.

        .EXAMPLE
        $supervisorId = Get-SupervisorId -supervisorName "Production-Supervisor" -VcenterUser "admin@vsphere.local" -VcenterInsecurePassword "VMware1!" -totalWaitTime 7200 -checkInterval 30

        Retrieves the supervisor ID with custom timeout and check interval settings. This example waits
        up to 2 hours (7200 seconds) for the supervisor to become ready, checking status every 30 seconds
        instead of the default 5 seconds. Useful for environments where supervisors take longer to
        provision or when you want to reduce API call frequency.

        .EXAMPLE
        $supervisorId = Get-SupervisorId -supervisorName "Quick-Test" -VcenterUser $VcenterUser -VcenterInsecurePassword $vcenterPass -totalWaitTime 300 -checkInterval 5

        Uses a shorter timeout (5 minutes) and more frequent checks (every 5 seconds) for testing
        scenarios where you want faster feedback on supervisor readiness. This is useful for
        development environments or when you know the supervisor should be ready quickly.

        .OUTPUTS
        System.String
        Returns the unique identifier (ID) of the specified vSphere Supervisor cluster as a string.
        The ID format is typically "domain-c" followed by a numeric identifier (e.g., "domain-c123").
        This ID is used for subsequent vSphere with Tanzu operations including namespace management,
        service installation, and Kubernetes cluster operations.

        .NOTES
        Prerequisites:
        • vCenter must be accessible via HTTPS on the standard port (443)
        • Target supervisor cluster must exist and be properly configured
        • User account must have sufficient privileges for namespace management API access
        • Network connectivity must allow REST API communication with vCenter

        Technical notes:
        • Uses HTTP Basic authentication to vCenter REST.
        • When Script:VcenterInsecurePassword is set, it supplies the REST password unless parameters override via Get-VcenterRestApiPlainPassword.
        • InsecureTls maps to SkipCertificateCheck on Invoke-RestMethod where applicable.

        API Endpoints Used:
        • POST /rest/com/vmware/cis/session - Session authentication
        • GET /api/vcenter/namespace-management/supervisors/summaries - Supervisor discovery

        Behavior:
        • Establishes new vCenter session for each function call
        • Searches all supervisor instances for name match (case-sensitive)
        • Waits for supervisor to reach READY status with progress indication (configurable intervals)
        • Configurable maximum wait time for supervisor readiness (default: 1 hour)
        • Returns supervisor ID immediately once supervisor reaches READY status
        • Throws a terminating error if supervisor not found or errors occur
        • Provides detailed error logging for troubleshooting API communication issues
        • Shows simplified status updates during wait period via Write-Progress

        Error Handling:
        • Authentication failures: Invalid credentials or insufficient permissions
        • Network errors: Connection timeouts, SSL issues, or network connectivity problems
        • API errors: vCenter service unavailability or API endpoint changes
        • Not found scenarios: Supervisor name doesn't match any existing clusters
        • Timeout scenarios: Supervisor doesn't reach READY status within configured timeout period
        • General exceptions: Comprehensive error logging with context information

        Performance Considerations:
        • Creates new authentication session for each call (no session reuse)
        • Queries all supervisor summaries (may be slow with many supervisors)
        • Waits up to configurable timeout for supervisor readiness with configurable check intervals
        • Network latency affects overall function execution time
        • Consider caching supervisor IDs for repeated operations
        • Long execution times possible when waiting for supervisor provisioning
        • Check interval affects API call frequency and responsiveness

        IMPORTANT - Password source for REST API (do not revert):
        When called from the main deployment, Script:VcenterInsecurePassword is set from the same PSCredential
        that succeeded for Connect-Vcenter, using Marshal (SecureStringToCoTaskMemUnicode/PtrToStringUni).
        This function MUST use that script-scoped value when set; do not rely only on the parameter, as
        GetNetworkCredential().Password can return empty or wrong encoding and cause 401 Unauthorized. See PASSWORD_HANDLING.md.
        When Script:VcenterInsecurePassword is not set, supply VcenterPassword or VcenterInsecurePassword for New-VCenterRestApiSession.

        .LINK
        Add-Supervisor
        Get-OrCreateSupervisor
        Add-ArgoCDNamespace
        Install-ArgoCDOperator
        Invoke-RestMethod
    #>

    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingUsernameAndPasswordParams', '')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('UsePSCredentialType', '')]
    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(1, [int]::MaxValue)] [Int]$CheckInterval=5,
        [Parameter(Mandatory = $false)] [Switch]$InsecureTls,
        [Parameter(Mandatory = $false)] [Switch]$Silence,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorName,
        [Parameter(Mandatory = $false)] [ValidateRange(1, [int]::MaxValue)] [Int]$TotalWaitTime=3600,
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
        # ========================================================================
        # STEP 1: Validate Parameters.
        # ========================================================================
        if ($TotalWaitTime -le 0) {
            Write-LogMessage -Type ERROR -Message "totalWaitTime must be greater than 0, got: $TotalWaitTime."
            return $null
        }
        if ($CheckInterval -le 0) {
            Write-LogMessage -Type ERROR -Message "checkInterval must be greater than 0, got: $CheckInterval."
            return $null
        }
        if ($CheckInterval -ge $TotalWaitTime) {
            Write-LogMessage -Type ERROR -Message "checkInterval ($CheckInterval) must be less than totalWaitTime ($TotalWaitTime)"
            return $null
        }

        # Use script-scoped credential when set (main deployment flow). That value was derived via Marshal from the
        # PSCredential that succeeded for Connect-Vcenter. Do NOT use GetNetworkCredential().Password—it can return
        # empty or wrong encoding on some platforms and cause 401 Unauthorized. See PASSWORD_HANDLING.md.
        $effectiveCredential = if ($null -ne $Script:VcenterCredential) { $Script:VcenterCredential } else { $VcenterCredential }
        $hasCredential = ($null -ne $effectiveCredential)
        if (-not $hasCredential) {
            $resolvedPlain = Get-VcenterRestApiPlainPassword -VcenterPassword $VcenterPassword -VcenterInsecurePassword $VcenterInsecurePassword
            if ([String]::IsNullOrWhiteSpace($resolvedPlain)) {
                Write-LogMessage -Type ERROR -Message "No vCenter password available for REST API session. Set Script:VcenterCredential from Connect-Vcenter, or pass -VcenterCredential (PSCredential), -VcenterPassword (SecureString), or -VcenterInsecurePassword."
                return $null
            }
        }

        # ========================================================================
        # STEP 2: Create REST API Session.
        # ========================================================================
        Write-LogMessage -Type DEBUG -Message "[Step 1/3] Creating REST API session..."
        Write-LogMessage -Type DEBUG -Message "Calling New-VCenterRestApiSession for vCenter `"$Script:vCenterName`", user `"$VcenterUser`", InsecureTls = $InsecureTls."

        $sessionParams = @{
            InsecureTls = $InsecureTls
            VcenterUser = $VcenterUser
        }
        if ($hasCredential) {
            $sessionParams.VcenterCredential = $effectiveCredential
        }
        elseif ($null -ne $VcenterPassword) {
            $sessionParams.VcenterPassword = $VcenterPassword
        }
        else {
            $sessionParams.VcenterInsecurePassword = $VcenterInsecurePassword
        }

        $session = New-VCenterRestApiSession @sessionParams

        if (-not $session.Success) {
            Write-LogMessage -Type ERROR -Message "Failed to create REST API session: $($session.ErrorMessage)"
            throw [VcfDeploymentException]::new("Failed to create REST API session: $($session.ErrorMessage)")
        }

        # ========================================================================
        # STEP 3: Search for Supervisor and Wait for Ready.
        # ========================================================================
        Write-LogMessage -Type DEBUG -Message "[Step 2/3] Searching for supervisor cluster..."

        $findParams = @{
            SupervisorName = $SupervisorName
            SessionHeaders = $session.SessionHeaders
            InsecureTls = $InsecureTls
        }
        $findResult = Find-SupervisorByName @findParams

        if (-not $findResult.Success) {
            Write-LogMessage -Type ERROR -Message "Failed to query supervisors: $($findResult.ErrorMessage)"
            throw [VcfDeploymentException]::new("Failed to query supervisors: $($findResult.ErrorMessage)")
        }

        # If supervisor not found, return null (may not be created yet).
        if (-not $findResult.Found) {
            Write-LogMessage -Type DEBUG -Message "[Step 3/3] Supervisor instance `"$SupervisorName`" not found. Proceeding to create it."
            return $null
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
            Write-LogMessage -Type ERROR -Message "Supervisor did not become ready: $($waitResult.ErrorMessage)"
            throw [VcfDeploymentException]::new("Supervisor did not become ready: $($waitResult.ErrorMessage)")
        }

        # Supervisor is ready.
        if (-not $Silence) {
            Write-LogMessage -Type INFO -Message "Supervisor instance `"$SupervisorName`" reported status ready, after waiting for $($waitResult.ElapsedSeconds) seconds."
        }

        return $waitResult.SupervisorId

    } catch [VcfDeploymentException] {
        throw  # already logged and typed — propagate without re-wrapping
    } catch {
        Write-LogMessage -Type ERROR -Message "Unable to fetch supervisor ID for `"$SupervisorName`": $($_.Exception.Message)"
        throw [VcfDeploymentException]::new("Unable to fetch supervisor ID for `"$SupervisorName`": $($_.Exception.Message)")
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
Function Get-StoragePolicyId {

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

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$StoragePolicyName
    )

    Write-LogMessage -Type DEBUG -Message "Entered Get-StoragePolicyId function..."

    $connectionTest = Test-VcenterConnection
    if (-not $connectionTest.IsConnected) {
        Write-LogMessage -Type ERROR -Message "Not connected to vCenter `"$Script:vCenterName`": $($connectionTest.ErrorMessage)"
        throw [VcfDeploymentException]::new("Not connected to vCenter `"$Script:vCenterName`": $($connectionTest.ErrorMessage)")
    }

    # Get storage policy id from the storage policy name.
    try {
        $policy = Get-SpbmStoragePolicy -Name $StoragePolicyName -Server $Script:vCenterName
        $storagePolicyId = $($policy.Id)
        return $storagePolicyId
    } catch {
        Write-LogMessage -Type "ERROR" -Message "Unable to fetch storage policy id `"$StoragePolicyName`" on `"$Script:vCenterName`": $($_.Exception.Message)"
        throw [VcfDeploymentException]::new("Unable to fetch storage policy id `"$StoragePolicyName`" on `"$Script:vCenterName`": $($_.Exception.Message)")
    }
}
Function Get-OrCreateSupervisor {

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

        .PARAMETER DisableSupervisorNetworkVanityPrefix
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

    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingUsernameAndPasswordParams', '')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('UsePSCredentialType', '')]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterId,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [Switch]$DisableSupervisorNetworkVanityPrefix,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EdgeSite,
        [Parameter(Mandatory = $false)] [Switch]$InsecureTls,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Array]$NetworkSegments,
        [Parameter(Mandatory = $false)] [Switch]$SingleSite,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$StoragePolicyId,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorJson,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorName,
        [Parameter(Mandatory = $false)] [PSCredential]$VcenterCredential,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [String]$VcenterInsecurePassword
    )

    Write-LogMessage -Type DEBUG -Message "Entered Get-OrCreateSupervisor function..."

    # Use script-scoped credential when set (main deployment flow). Same reason as Get-SupervisorId—avoids 401 from wrong encoding. See PASSWORD_HANDLING.md.
    $effectiveCredential = if ($null -ne $Script:VcenterCredential) { $Script:VcenterCredential } else { $VcenterCredential }

    # Check if supervisor already exists, if not create it.
    if ($InsecureTls) {
        if (-not (Get-SupervisorId -supervisorName $SupervisorName -VcenterUser $Script:VCenterUser -VcenterCredential $effectiveCredential -insecureTls)) {
            $supervisorId = Add-Supervisor -infrastructureJson $SupervisorJson -storagePolicyId $StoragePolicyId -clusterId $ClusterId -clusterName $ClusterName -supervisorName $SupervisorName -VcenterCredential $effectiveCredential -edgeSite $EdgeSite -networkSegments $NetworkSegments -SingleSite:$SingleSite.IsPresent -insecureTls -DisableSupervisorNetworkVanityPrefix:$DisableSupervisorNetworkVanityPrefix
        } else {
            $supervisorId = Get-SupervisorId -supervisorName $SupervisorName -VcenterUser $Script:VCenterUser -VcenterCredential $effectiveCredential -silence -insecureTls
        }
    } else {
        if (-not (Get-SupervisorId -supervisorName $SupervisorName -VcenterUser $Script:VCenterUser -VcenterCredential $effectiveCredential)) {
            $supervisorId = Add-Supervisor -infrastructureJson $SupervisorJson -storagePolicyId $StoragePolicyId -clusterId $ClusterId -clusterName $ClusterName -supervisorName $SupervisorName -VcenterCredential $effectiveCredential -edgeSite $EdgeSite -networkSegments $NetworkSegments -SingleSite:$SingleSite.IsPresent -DisableSupervisorNetworkVanityPrefix:$DisableSupervisorNetworkVanityPrefix
        } else {
            $supervisorId = Get-SupervisorId -supervisorName $SupervisorName -VcenterUser $Script:VCenterUser -VcenterCredential $effectiveCredential -silence
        }
    }

    return $supervisorId
}
Function Get-AvailableVmClassNames {

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
    #>

    Write-LogMessage -Type DEBUG -Message "Entered Get-AvailableVmClassNames..."
    $vmClassNames = @()
    try {
        $list = Invoke-ListNamespaceManagementVirtualMachineClasses -ErrorAction Stop
        if ($list) {
            foreach ($item in $list) {
                $name = $null
                if ($null -ne $item.PSObject.Properties["Id"]) { $name = $item.Id }
                elseif ($null -ne $item.PSObject.Properties["Name"]) { $name = $item.Name }
                if (-not [String]::IsNullOrWhiteSpace($name)) {
                    $vmClassNames += $name.Trim()
                }
            }
        }
    } catch {
        Write-LogMessage -Type DEBUG -Message "Get-AvailableVmClassNames: Invoke-ListNamespaceManagementVirtualMachineClasses failed: $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -Message "Could not list VM classes from vCenter. Set clusters[].supervisorServices.vmClass in infrastructure.json to an array of VM class names (e.g. best-effort-small, best-effort-medium)."
        throw [VcfDeploymentException]::new("Could not list VM classes from vCenter. Set clusters[].supervisorServices.vmClass in infrastructure.json to an array of VM class names (e.g. best-effort-small, best-effort-medium).")
    }
    if ($vmClassNames.Count -eq 0) {
        Write-LogMessage -Type ERROR -Message "Could not list VM classes from vCenter. Set clusters[].supervisorServices.vmClass in infrastructure.json to an array of VM class names (e.g. best-effort-small, best-effort-medium)."
        throw [VcfDeploymentException]::new("Could not list VM classes from vCenter. Set clusters[].supervisorServices.vmClass in infrastructure.json to an array of VM class names (e.g. best-effort-small, best-effort-medium).")
    }
    Write-LogMessage -Type INFO -Message "Using all available VM classes for ArgoCD namespace."
    return $vmClassNames
}
Function Add-ArgoCDNamespace {

    <#
        .SYNOPSIS
        Creates and configures a vSphere Supervisor namespace specifically optimized for ArgoCD deployment and management.

        .DESCRIPTION
        The Add-ArgoCDNamespace function creates a dedicated vSphere Supervisor namespace designed specifically for
        ArgoCD deployment within a vSphere Supervisor environment. This function handles the complete
        namespace provisioning lifecycle including resource allocation, storage configuration, and VM service setup.

        The function performs the following comprehensive operations:
        1. Validates that the specified namespace doesn't already exist to prevent conflicts
        2. Creates a new Supervisor namespace on the specified supervisor cluster using vCenter APIs
        3. Configures unlimited storage specifications with the specified storage policy for ArgoCD persistence
        4. Sets up VM service specifications linking VM classes for workload deployment
        5. Applies complete namespace configuration to enable ArgoCD operator and instance deployment
        6. Implements proper initialization delays to ensure stable namespace provisioning

        Key configuration details:
        - Storage Policy: Applied to all persistent volumes created within the namespace
        - VM Classes: Define compute resource specifications (CPU, memory) for ArgoCD pods
        - Storage Limit: Set to unlimited (0) to prevent resource constraints during ArgoCD operations
        - Namespace Isolation: Provides dedicated environment for ArgoCD resources and configurations

        This function integrates with vSphere with Tanzu infrastructure and serves as a foundational step
        for ArgoCD deployment, ensuring proper resource allocation and configuration for GitOps workflows.

        .PARAMETER SupervisorId
        The unique identifier of the vSphere Supervisor cluster where the namespace will be created.
        This ID is typically obtained from the Get-SupervisorId function or supervisor creation process.
        The supervisor cluster must be in a ready state and properly configured for namespace creation.
        Format example: "domain-c123" or similar vCenter managed object reference.

        .PARAMETER ArgoCdNamespace
        The name for the ArgoCD namespace to be created. This name must follow Kubernetes namespace
        naming conventions (lowercase alphanumeric characters and hyphens only, maximum 63 characters).
        The namespace provides resource isolation and serves as the deployment target for ArgoCD
        operator and instance resources. Common examples: "argocd", "argocd-prod", "gitops-system".

        .PARAMETER StoragePolicyId
        The unique identifier of the vSphere storage policy to be applied to the namespace.
        This policy defines storage characteristics including performance tier, availability requirements,
        and placement rules for all persistent volumes created within the ArgoCD namespace.
        The storage policy must exist and be compatible with the target datastore infrastructure.

        .PARAMETER VmClasses
        Array of VM class names that define compute resource specifications (CPU cores, memory allocation,
        storage capacity) for virtual machines and pods running within the ArgoCD namespace.
        VM classes control resource allocation and performance characteristics for ArgoCD workloads.
        VM class names must conform to RFC1123 naming conventions (lowercase alphanumeric with hyphens, max 80 chars).
        The API validates that each VM class exists in vCenter inventory during namespace configuration.
        Common examples: "best-effort-small", "guaranteed-medium", "best-effort-2xlarge".
        Supports both single string and array input formats.

        .EXAMPLE
        Add-ArgoCDNamespace -SupervisorId "domain-c123" -ArgoCdNamespace "argocd" -StoragePolicyId "policy-456" -VmClasses @("best-effort-medium")

        Creates an ArgoCD namespace named "argocd" on supervisor cluster "domain-c123" with a single VM class.
        Uses storage policy "policy-456" for persistent volumes.

        .EXAMPLE
        Add-ArgoCDNamespace -SupervisorId $SupervisorId -ArgoCdNamespace "argocd-production" -StoragePolicyId $StoragePolicyId -VmClasses @("guaranteed-large", "best-effort-2xlarge")

        Creates a production ArgoCD namespace with multiple VM classes to support different workload types.
        The namespace can deploy pods using either guaranteed or best-effort resource allocation.

        .EXAMPLE
        $namespaceParams = @{
            SupervisorId = Get-SupervisorId -SupervisorName $SupervisorName
            ArgoCdNamespace = $InputData.common.argoCD.nameSpace
            StoragePolicyId = Get-StoragePolicyId -StoragePolicyName $InputData.common.storagePolicy.storagePolicyName
            VmClasses = $InputData.common.argoCD.vmClass
        }
        Add-ArgoCDNamespace @namespaceParams

        Creates ArgoCD namespace using parameter splatting with dynamic ID resolution from configuration data.
        This approach enables flexible deployment scenarios with centralized configuration management.

        .OUTPUTS
        None
        This function creates namespace infrastructure and logs status messages but does not return objects.
        Success is indicated by informational log messages and absence of script termination.

        .NOTES
        Prerequisites:
        - Active vCenter connection with Supervisor Services administration privileges
        - Target supervisor cluster must be in ready/running state with proper Tanzu configuration
        - Specified storage policy must exist and be compatible with the target infrastructure
        - VM classes must exist in vCenter inventory and be available for assignment
        - VM class names must conform to RFC1123 naming conventions (validated in JSON validation phase)
        - Sufficient cluster resources (CPU, memory, storage) to accommodate the namespace requirements

        Behavior:
        - Function returns early with warning message if namespace already exists (idempotent operation)
        - Uses unlimited storage allocation (limit = 0) to prevent ArgoCD operational constraints
        - Implements 5-second initialization delays after namespace creation and configuration for stability
        - Passes VM classes as array to API (List<string>) for individual class validation
        - Exits script with code 1 on any critical errors to prevent incomplete deployments
        - Creates namespace with both storage specifications and VM service configurations in single operation
        - Automatically deletes namespace if VM class configuration fails to maintain clean state

        Error Handling:
        - Comprehensive error handling for namespace creation, storage configuration, and VM service setup
        - Extracts clean error messages from API JSON responses for user-friendly output
        - Automatic namespace cleanup on VM class configuration failure prevents orphaned resources
        - Detailed error logging with specific failure context including which VM class is invalid
        - Script termination on critical errors prevents proceeding with invalid namespace configuration
        - Graceful handling of duplicate namespace scenarios with informational logging

        Performance:
        - Efficient single-pass namespace creation with complete configuration application
        - Minimal API calls through batched configuration operations
        - Built-in delays ensure proper resource initialization before function completion
        - Optimized for large-scale deployment scenarios with reliable namespace provisioning

        Integration:
        - Integrates with VCF PowerShell Toolbox logging infrastructure for consistent audit trails
        - Compatible with vSphere with Tanzu namespace management workflows
        - Designed for use in automated ArgoCD deployment pipelines and configuration management
        - Supports both interactive and scripted deployment scenarios with comprehensive logging

        Security:
        - Namespace isolation provides security boundary for ArgoCD resources and configurations
        - Storage policy enforcement ensures data protection and compliance requirements
        - VM class restrictions prevent resource abuse and maintain cluster stability
        - Integration with vSphere RBAC for proper access control and authorization

        .LINK
        Get-SupervisorId
        Get-StoragePolicyId
        Install-ArgoCDOperator
        Add-ArgoCDInstance
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ArgoCdNamespace,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$StoragePolicyId,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorId,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Array]$VmClasses,
        [Parameter(Mandatory = $false)] [ValidateRange(1, [int]::MaxValue)] [Int]$NamespaceStabilizationDelaySeconds = 5
    )
    Write-LogMessage -Type DEBUG -Message "Entered Add-ArgoCDNamespace function..."
    Write-LogMessage -Type DEBUG -Message "Add-ArgoCDNamespace received namespace parameter: `"$ArgoCdNamespace`""

    # Reject VM class names that contain '$' to avoid triggering bugs in VCF PowerCLI that re-evaluate such strings.
    $invalidVmClasses = @($VmClasses | Where-Object { [string]$_ -match '\$' })
    if ($invalidVmClasses.Count -gt 0) {
        $invalidList = $invalidVmClasses -join ', '
        Write-LogMessage -Type ERROR -Message "Invalid VM class name(s): $invalidList. VM class names must not contain '$' (dollar sign)."
        throw [VcfDeploymentException]::new("Invalid VM class name(s): $invalidList. VM class names must not contain '$' (dollar sign).")
    }

    try {
        if ((Invoke-ListNamespacesInstances).Namespace -contains $ArgoCdNamespace) {
            Write-LogMessage -Type INFO -Message "The ArgoCD namespace `"$ArgoCdNamespace`" already exists on vCenter `"$Script:vCenterName`" Skipping namespace creation."
            return
        }

        # Create the namespace on the supervisor.
        Write-LogMessage -Type DEBUG -Message "Creating namespace `"$ArgoCdNamespace`" on supervisor `"$SupervisorId`"..."
        try {
            $vcenterNamespacesInstancesCreateSpecV2 = Initialize-VcenterNamespacesInstancesCreateSpecV2 -supervisor $SupervisorId -Namespace $ArgoCdNamespace
            Invoke-CreateNamespacesInstancesV2 -VcenterNamespacesInstancesCreateSpecV2 $vcenterNamespacesInstancesCreateSpecV2 -Confirm:$false -ErrorAction Stop | Out-Null
            Write-LogMessage -Type DEBUG -Message "Namespace creation initiated successfully."
        } catch {
            # Extract clean error message from API response.
            $errorMessage = $_.Exception.Message

            # Try to extract error details from JSON error response.
            if ($errorMessage -match '"error_type":"([^"]+)"') {
                $errorType = $matches[1]
                Write-LogMessage -Type ERROR -Message "Failed to create namespace `"$ArgoCdNamespace`": Error type: $errorType"
            }
            else {
                Write-LogMessage -Type ERROR -Message "Failed to create namespace `"$ArgoCdNamespace`""
            }

            # Extract clean error message from JSON error response.
            $cleanMessage = Get-CleanErrorMessage -ErrorMessage $errorMessage
            Write-LogMessage -Type ERROR -Message "Reason: $cleanMessage"

            Write-LogMessage -Type ERROR -Message "Supervisor ID: $SupervisorId"
            Write-LogMessage -Type ERROR -Message "Namespace: $ArgoCdNamespace"

            # Provide helpful context based on error type.
            if ($errorMessage -match 'NOT_ALLOWED_IN_CURRENT_STATE') {
                Write-LogMessage -Type ERROR -Message ""
                Write-LogMessage -Type ERROR -Message "TROUBLESHOOTING: The supervisor cluster is not in a valid state for namespace creation."
                Write-LogMessage -Type ERROR -Message "Possible causes:"
                Write-LogMessage -Type ERROR -Message "  - Workloads are being enabled or disabled on the supervisor."
                Write-LogMessage -Type ERROR -Message "  - Supervisor is in a transitional state."
                Write-LogMessage -Type ERROR -Message "  - Another operation is in progress."
                Write-LogMessage -Type ERROR -Message "Resolution: Wait for the supervisor to reach a stable state and retry."
            }

            throw [VcfDeploymentException]::new("Supervisor update failed; supervisor did not reach stable state. Check logs for details.")
        }
        Start-Sleep $NamespaceStabilizationDelaySeconds

        # Set the storage limit to unlimited (by not specifying -Limit parameter)
        Write-LogMessage -Type DEBUG -Message "Initializing storage specification with policy ID: $StoragePolicyId"
        $vcenterNamespacesInstancesStorageSpec = Initialize-VcenterNamespacesInstancesStorageSpec -Policy $StoragePolicyId -ErrorAction Stop
        Write-LogMessage -Type DEBUG -Message "Storage specification initialized successfully."

        # Pass VM classes as array (API expects List<string>, not comma-separated string).
        # Build a new array with foreach (no pipeline) to avoid triggering a bug in the VCF cmdlet
        # that can cause '"$_"' to be evaluated when the parameter is bound from a piped array.
        Write-LogMessage -Type DEBUG -Message "Configuring VM classes ($($VmClasses.Count)): $($VmClasses -join ', ')"
        $vmClassesArray = [System.Collections.ArrayList]::new()
        foreach ($className in $VmClasses) {
            [void]$vmClassesArray.Add([string]$className)
        }
        $vmClassesToPass = $vmClassesArray.ToArray()
        Write-LogMessage -Type DEBUG -Message "VM classes array: $($vmClassesToPass -join ', ')"

        # Initialize the VM service specification (without content library)
        Write-LogMessage -Type DEBUG -Message "Attempting to initialize VM service specification with VM classes..."
        try {
            $vcenterNamespacesInstancesVMServiceSpec = Initialize-VcenterNamespacesInstancesVMServiceSpec -VmClasses $vmClassesToPass -ErrorAction Stop
            Write-LogMessage -Type DEBUG -Message "VM service specification initialized successfully."
        } catch [VcfDeploymentException] {
            throw  # already logged and typed — propagate without re-wrapping
        } catch {
            Write-LogMessage -Type ERROR -Message "Failed to initialize VM service specification."
            Write-LogMessage -Type ERROR -Message "Error details: $($_.Exception.Message)"
            Write-LogMessage -Type ERROR -Message "VM classes attempted: $($VmClasses -join ', ')"
            throw [VcfDeploymentException]::new("VM classes attempted: $($VmClasses -join ', ')")
        }

        # Initialize the namespace set specification (with storage and VM service specifications)
        Write-LogMessage -Type DEBUG -Message "Initializing namespace set specification..."
        try {
            $vcenterNamespacesInstancesSetSpec = Initialize-VcenterNamespacesInstancesSetSpec -StorageSpecs $vcenterNamespacesInstancesStorageSpec -VmServiceSpec $vcenterNamespacesInstancesVMServiceSpec -ErrorAction Stop
            Write-LogMessage -Type DEBUG -Message "Namespace set specification initialized successfully."
        } catch [VcfDeploymentException] {
            throw  # already logged and typed — propagate without re-wrapping
        } catch {
            Write-LogMessage -Type ERROR -Message "Failed to initialize namespace set specification."
            Write-LogMessage -Type ERROR -Message "Error details: $($_.Exception.Message)"
            throw [VcfDeploymentException]::new("Error details: $($_.Exception.Message)")
        }

        # Apply the namespace configuration (this is where VM classes are actually assigned)
        Write-LogMessage -Type DEBUG -Message "Applying namespace configuration to `"$argocdNameSpace`"..."
        Write-LogMessage -Type DEBUG -Message "This step assigns VM classes: $($VmClasses -join ', ')"
        try {
            Invoke-SetNamespaceInstances -Namespace $argocdNameSpace -VcenterNamespacesInstancesSetSpec $vcenterNamespacesInstancesSetSpec -Confirm:$false -ErrorAction Stop | Out-Null
            Write-LogMessage -Type DEBUG -Message "Namespace configuration applied successfully."
        } catch {
            # Extract clean error message from API response.
            $errorMessage = $_.Exception.Message

            # Extract clean error message from JSON error response.
            $cleanMessage = Get-CleanErrorMessage -ErrorMessage $errorMessage
            Write-LogMessage -Type ERROR -Message "Failed to apply namespace configuration: $cleanMessage."

            Write-LogMessage -Type ERROR -Message "VM classes attempted: $($VmClasses -join ', ')"
            Write-LogMessage -Type ERROR -Message "Namespace: $argocdNameSpace"

            # Clean up: Delete the namespace since configuration failed.

            Write-LogMessage -Type INFO -Message "Cleaning up: Deleting namespace `"$argocdNameSpace`" due to configuration failure..."
            try {
                Invoke-DeleteNamespaceInstances -Namespace $argocdNameSpace -Confirm:$false -ErrorAction Stop | Out-Null
                Write-LogMessage -Type INFO -Message "Namespace `"$argocdNameSpace`" deleted successfully."
            } catch {
                Write-LogMessage -Type WARNING -Message "Failed to delete namespace `"$argocdNameSpace`": $($_.Exception.Message)"
                Write-LogMessage -Type WARNING -Message "You may need to manually delete the namespace."
            }

            Write-LogMessage -Type ERROR -Message "ArgoCD namespace `"$argocdNameSpace`" could not be deleted. Check logs for details."
            throw [VcfDeploymentException]::new("ArgoCD namespace `"$argocdNameSpace`" could not be deleted. Check logs for details.")
        }

        Start-Sleep $NamespaceStabilizationDelaySeconds
        Write-LogMessage -Type INFO -Message "The ArgoCD namespace `"$ArgoCdNamespace`" was created successfully with $($VmClasses.Count) VM classes assigned: $($VmClasses -join ', ')"
    } catch {
        $namespaceError = $_.Exception.Message
        Write-LogMessage -Type "ERROR" -Message "The namespace could not be created: $namespaceError"
        throw [VcfDeploymentException]::new("The namespace could not be created: $namespaceError")
    }
}
Function Install-ArgoCDOperator {

    <#
        .SYNOPSIS
        Installs and configures the ArgoCD operator as a supervisor service on a vSphere Supervisor cluster.

        .DESCRIPTION
        The Install-ArgoCDOperator function deploys the ArgoCD operator as a supervisor service on a specified
        vSphere Supervisor cluster using the vCenter namespace management APIs. This function handles the complete
        installation lifecycle including service creation, configuration monitoring, and error handling for various
        deployment scenarios.

        The function performs the following key operations:
        • Creates a supervisor service specification for the ArgoCD operator with specified version
        • Deploys the ArgoCD operator service to the target supervisor cluster
        • Monitors the configuration status with real-time progress tracking and timeout handling
        • Handles duplicate service scenarios gracefully with appropriate warnings
        • Provides comprehensive error handling for compatibility, cluster state, and general deployment issues
        • Implements intelligent retry logic with configurable timeout (300 seconds default)

        This function is designed to work within the vSphere with Tanzu ecosystem and serves as a prerequisite
        for ArgoCD instance deployment. The operator manages ArgoCD custom resources and provides the foundation
        for GitOps workflows in Kubernetes environments running on vSphere Supervisor clusters.

        Key features:
        - Automated supervisor service creation using vCenter namespace management APIs
        - Real-time configuration status monitoring with progress indicators
        - Intelligent duplicate service detection and handling
        - Comprehensive error handling for compatibility and cluster state issues
        - Configurable timeout with 30-second polling intervals
        - Integration with vSphere Supervisor cluster infrastructure
        - Support for version-specific ArgoCD operator deployments

        .PARAMETER ClusterId
        The vCenter cluster MoRef identifier (e.g., "domain-c462") where the supervisor is enabled.
        This is used to dynamically construct the service namespace for error messages and diagnostics.
        The cluster ID is obtained from Get-ClusterId.

        .PARAMETER ClusterName
        The vSphere cluster display name used when logging supervisor Kubernetes diagnostics on failure.

        .PARAMETER SupervisorId
        The unique identifier of the vSphere Supervisor cluster where the ArgoCD operator will be installed.
        This should be the supervisor cluster ID obtained from supervisor creation or discovery operations.
        The supervisor cluster must be in a running state and have the necessary prerequisites configured
        including storage policies, content libraries, and network configurations. This is used for the
        actual API call to create the supervisor service.

        .PARAMETER Service
        The service identifier (reference name) for the ArgoCD operator supervisor service. This is typically
        extracted from the ArgoCD service YAML package file and identifies the specific service to be deployed.
        The service identifier must match the spec.refName from the ArgoCD service package definition and
        should follow the format "argocd-service.vsphere.vmware.com" or similar naming convention.

        .PARAMETER Version
        The version of the ArgoCD operator service to install. This should match the spec.version from the
        ArgoCD service package definition and determines the specific operator version and capabilities.
        Version format typically follows semantic versioning with build identifiers (e.g., "1.0.0-24815986").
        The version must be compatible with the supervisor cluster version and capabilities.

        .EXAMPLE
        Install-ArgoCDOperator -ClusterId "domain-c462" -ClusterName "MyCluster" -SupervisorId "domain-s123" -Service "argocd-service.vsphere.vmware.com" -Version "1.0.0-24815986"

        Installs the ArgoCD operator version 1.0.0-24815986 on supervisor cluster "domain-s123" using the
        standard ArgoCD service identifier. The function will monitor the installation progress and report
        success or failure with detailed status information.

        .EXAMPLE
        $argoServiceName, $argoServiceVersion = Get-ArgoCDServiceDetail -Path $argoCDyaml
        Install-ArgoCDOperator -clusterId $ClusterId -supervisorId $SupervisorId -service $argoServiceName -version $argoServiceVersion

        Installs the ArgoCD operator using service details extracted from a YAML package file, demonstrating
        integration with service discovery functions for dynamic deployment scenarios.

        .EXAMPLE
        Install-ArgoCDOperator -clusterId $ClusterId -supervisorId $SupervisorId -service $ServiceName -version $ServiceVersion
        # Function will handle existing service gracefully and monitor configuration status.


        Shows the function's ability to handle existing services and provide appropriate feedback for
        various deployment states including already configured services.

        .OUTPUTS
        None
        This function does not return objects but performs supervisor service installation with side effects.
        Success is indicated by the absence of exceptions and successful configuration status messages.
        All operations are logged for audit trail and troubleshooting purposes.

        .NOTES
        Prerequisites:
        • Active vCenter connection with administrative privileges for supervisor service management
        • Target supervisor cluster must be in running state with proper configuration
        • ArgoCD service package must be available and properly configured
        • Supervisor cluster must meet minimum version requirements (9.0.0.0-0100-24847555 or higher)
        • Sufficient resources and network connectivity for ArgoCD operator deployment

        Behavior:
        • Monitors configuration status with 30-second polling intervals
        • Implements 300-second (5-minute) timeout for configuration completion
        • Handles existing services with warning messages rather than errors
        • Provides detailed error messages for troubleshooting deployment issues
        • Throws a terminating error on critical failures

        Configuration States:
        • CONFIGURING: Service is being configured (monitored with progress updates)
        • CONFIGURED: Service successfully installed and ready for use
        • ERROR: Service configuration failed with detailed error messages

        Error Handling:
        • Compatibility errors: Provides specific supervisor version upgrade guidance
        • Cluster state errors: Indicates supervisor cluster is not running with remediation steps
        • Duplicate service errors: Graceful handling with configuration status verification
        • Timeout errors: Clear indication of configuration timeout with troubleshooting guidance
        • General errors: Comprehensive error logging with exception details

        Performance Considerations:
        • Initial 30-second delay after service creation for proper initialization
        • 30-second polling intervals balance responsiveness with system load
        • 300-second timeout provides sufficient time for most deployment scenarios
        • Configuration monitoring continues until success, failure, or timeout

        Integration:
        • Works with vSphere with Tanzu supervisor clusters
        • Integrates with ArgoCD service package management
        • Supports GitOps workflow preparation and ArgoCD instance deployment
        • Compatible with vCenter namespace management infrastructure

        .LINK
        Set-ArgoCDService
        Get-ArgoCDServiceDetail
        Add-ArgoCDNamespace
        Add-ArgoCDInstance
        Initialize-VcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec
        Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesCreate
    #>

    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(1, [int]::MaxValue)] [Int]$CheckInterval = 5,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterId,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Service,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorId,
        [Parameter(Mandatory = $false)] [ValidateRange(1, [int]::MaxValue)] [Int]$TotalWaitTime = 600,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Version
    )

    Write-LogMessage -Type DEBUG -Message "Entered Install-ArgoCDOperator function for cluster `"$ClusterName`"..."

    # Construct the service namespace (format: svc-<service-slug>-<cluster-id>).
    # The service slug is derived from the service name by removing the domain suffix.
    # The cluster ID (e.g., domain-c462) is used, NOT the supervisor UUID.
    $serviceSlug = $Service -replace '\.vsphere\.vmware\.com$', ''
    $serviceNamespace = "svc-$serviceSlug-$ClusterId"

    try {
        $vcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec = Initialize-VcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec -SupervisorService $Service -Version $Version
        try {
            Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesCreate -supervisor $SupervisorId -vcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec $vcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec -Confirm:$false -ErrorAction Stop
            Write-LogMessage -Type DEBUG -Message "The ArgoCD operator was successfully created.  Waiting for configuration tasks to complete."
            Start-Sleep $CheckInterval
        } catch {
            $errMsg = $_.Exception.Message

            switch -Regex ($errMsg) {
                "Supervisor Service.*already exists|an instance.*Supervisor Service.*already exists" {
                    Write-LogMessage -Type INFO -Message "ArgoCD service already exists. Verifying configuration status..."
                }
                "Supervisor Service is not in activated state" {
                    # Service exists but is in a non-activated state (likely failed previous installation).
                    Write-LogMessage -Type ERROR -Message "ArgoCD operator installation failed: Failed to create Supervisor Service ($Service) version ($Version) on cluster ($SupervisorId). Supervisor Service is not in activated state."
                    Write-Host ""
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
                    Write-Host ""
                    Write-LogMessage -Type WARNING -Message "If the service is stuck and cannot be deleted via UI:"
                    Write-LogMessage -Type WARNING -Message "  Use kubectl to manually clean up the namespace: kubectl delete namespace $serviceNamespace"
                    Write-LogMessage -Type WARNING -Message "  List namespaces with: kubectl get namespaces"
                    Write-LogMessage -Type WARNING -Message "  Then manually remove the service via vCenter REST API or contact VMware support."
                    throw [VcfDeploymentException]::new("ArgoCD service is not in activated state on supervisor `"$SupervisorId`". Check logs for details.")
                }
                "Signature verification result for Service Version ([0-9.-]+) not found" {
                    # Service version not available on this supervisor (signature verification failed)
                    $requestedVersion = $matches[1]

                    # Extract clean error message.
                    $cleanErrorMessage = Get-CleanErrorMessage -ErrorMessage $errMsg
                    if ($cleanErrorMessage -eq $errMsg) {
                        # No clean message found, use default message.
                        $cleanErrorMessage = "ArgoCD service version $requestedVersion is not available on this supervisor."
                    }

                    Write-LogMessage -Type ERROR -Message "ArgoCD operator installation failed: $cleanErrorMessage."
                    Write-Host ""
                    Write-LogMessage -Type ERROR -Message "SOLUTION: Either upgrade your supervisor to a version that includes ArgoCD service $requestedVersion,"
                    Write-LogMessage -Type ERROR -Message "         or modify your infrastructure.json to specify a different ArgoCD service version that is available."
                    Write-Host ""
                    Write-LogMessage -Type ERROR -Message "To list available ArgoCD service versions, use the vSphere API or vCenter UI:"
                    Write-LogMessage -Type ERROR -Message "  Menu > Supervisor Management > Supervisors > ArgoCD Service > Manager Versions"
                    throw [VcfDeploymentException]::new("  Menu > Supervisor Management > Supervisors > ArgoCD Service > Manager Versions")
                }
                "Supervisor Service \(argocd-service\.vsphere\.vmware\.com\) version \(([^)]+)\) has not been found" {
                    # Generic "version not found" error.
                    $requestedVersion = $matches[1]
                    Write-LogMessage -Type ERROR -Message "ArgoCD operator installation failed: ArgoCD service version $requestedVersion is not available on this supervisor."
                    Write-Host ""
                    Write-LogMessage -Type ERROR -Message "SOLUTION: Either upgrade your supervisor to a version that includes ArgoCD service $requestedVersion,"
                    Write-LogMessage -Type ERROR -Message "         or modify your infrastructure.json to specify a different ArgoCD service version that is available."
                    Write-Host ""
                    Write-LogMessage -Type ERROR -Message "To list available ArgoCD service versions, use the vSphere API or vCenter UI:"
                    Write-LogMessage -Type ERROR -Message "  Menu > Supervisor Management > Supervisors > ArgoCD Service > Manager Versions"
                    throw [VcfDeploymentException]::new("  Menu > Supervisor Management > Supervisors > ArgoCD Service > Manager Versions")
                }
                "Failed to run compatibility check for Supervisor Service" {
                    # Only catch compatibility check errors that are NOT about version availability.

                    # Extract clean error message from JSON response.
                    $cleanErrorMessage = Get-CleanErrorMessage -ErrorMessage $errMsg

                    Write-LogMessage -Type ERROR -Message "ArgoCD operator installation failed: $cleanErrorMessage."
                    Write-Host ""
                    Write-LogMessage -Type ERROR -Message "SOLUTION: Upgrade your supervisor to version 9.0.0.0-0100-24847555 or higher and try again."
                    Write-LogMessage -Type ERROR -Message "This error indicates the supervisor version is too old to verify the ArgoCD service signature."
                    throw [VcfDeploymentException]::new("This error indicates the supervisor version is too old to verify the ArgoCD service signature.")
                }
                default {
                    # Extract clean error message from JSON response.
                    $cleanMessage = Get-CleanErrorMessage -ErrorMessage $errMsg

                    if ($cleanMessage -ne $errMsg) {
                        Write-LogMessage -Type ERROR -Message "ArgoCD operator installation failed: $cleanMessage."
                    }
                    else {
                        Write-LogMessage -Type ERROR -Message "Unexpected error in Install-ArgoCDOperator: $errMsg."
                    }

                    throw [VcfDeploymentException]::new("ArgoCD operator installation failed: $errMsg")
                }
            }
        }

        # Verify the service was actually created before waiting for configuration.
        Write-LogMessage -Type DEBUG -Message "Verifying ArgoCD operator service exists on supervisor `"$SupervisorId`" before waiting for configuration..."
        try {
            $verifyService = Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesGet -supervisor $SupervisorId -supervisorService $Service -ErrorAction Stop
            Write-LogMessage -Type DEBUG -Message "Service verified. Current config status: $($verifyService.ConfigStatus)"
        } catch {
            $verifyError = $_.Exception.Message
            if ($verifyError -match "not found|does not exist") {
                Write-LogMessage -Type ERROR -Message "ArgoCD operator service was not created successfully on supervisor `"$SupervisorId`"."
                Write-LogMessage -Type ERROR -Message "The service creation may have failed silently. Error: $verifyError"
                Write-Host ""
                Write-LogMessage -Type ERROR -Message "SOLUTION:"
                Write-LogMessage -Type ERROR -Message "  1. Verify the supervisor ID `"$SupervisorId`" is correct for this cluster."
                Write-LogMessage -Type ERROR -Message "  2. Check vCenter UI: Menu > Workload Management > Supervisor Clusters"
                Write-LogMessage -Type ERROR -Message "  3. Verify the supervisor cluster is in `"Running`" state."
                Write-LogMessage -Type ERROR -Message "  4. Check for any error messages in the supervisor cluster status."
                Write-Host ""
                throw [VcfDeploymentException]::new("Deployment failed. ArgoCD operator service was not created. Check logs for details.")
            } else {
                # Service might exist but API call failed - continue to monitoring loop.
                Write-LogMessage -Type DEBUG -Message "Could not verify service existence (may be initializing): $verifyError"
            }
        }

        $elapsedTime = 0

        do {
            try {
                $serviceOutput = Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesGet -supervisor $SupervisorId -supervisorService $Service
            } catch {
                $errorMessage = $_.Exception.Message

                # Handle service not found errors - this indicates the service was never created.
                if ($errorMessage -match "not found|does not exist") {
                    Write-Progress -Activity "Waiting for ArgoCD operator configuration" -Status "Error" -Completed
                    Write-LogMessage -Type ERROR -Message "ArgoCD operator service does not exist on supervisor `"$SupervisorId`"."
                    Write-LogMessage -Type ERROR -Message "The service creation failed or the service was created on a different supervisor."
                    Write-Host ""
                    Write-LogMessage -Type ERROR -Message "SOLUTION:"
                    Write-LogMessage -Type ERROR -Message "  1. Verify the supervisor ID `"$SupervisorId`" matches the correct supervisor cluster."
                    Write-LogMessage -Type ERROR -Message "  2. Check vCenter UI: Menu > Workload Management > Supervisor Clusters"
                    Write-LogMessage -Type ERROR -Message "  3. Look for the ArgoCD service in the Services section of the supervisor cluster."
                    Write-LogMessage -Type ERROR -Message "  4. If the service exists on a different supervisor, verify the cluster ID and supervisor ID are correct."
                    Write-Host ""
                    throw [VcfDeploymentException]::new("Deployment failed. ArgoCD operator service does not exist. Check logs for details.")
                }
                # Handle JSON deserialization errors when config_status is empty or invalid.
                elseif ($errorMessage -match "Error converting value.*config_status") {
                    Write-LogMessage -Type DEBUG -Message "Supervisor service status not yet available (empty config_status). Waiting..."
                    $statusMessage = "Elapsed Time: $elapsedTime seconds - Status: Initializing (config status not yet available)"
                    Write-Progress -Activity "Waiting for ArgoCD operator configuration" -Status $statusMessage
                    Start-Sleep $CheckInterval
                    $elapsedTime += $CheckInterval
                    continue
                }
                # Handle supervisor cluster not running errors - exit early with clear guidance.
                elseif ($errorMessage -match "cluster.not_running|not in running state") {
                    Write-Progress -Activity "Waiting for ArgoCD operator configuration" -Status "Error" -Completed
                    $cleanMessage = Get-CleanErrorMessage -ErrorMessage $errorMessage
                    Write-LogMessage -Type ERROR -Message "The supervisor cluster is not in a running state. ArgoCD operator installation cannot proceed."
                    Write-LogMessage -Type ERROR -Message "Error details: $cleanMessage."
                    Write-Host ""
                    Write-LogMessage -Type ERROR -Message "SOLUTION: Verify and ensure the supervisor cluster is running:"
                    Write-LogMessage -Type ERROR -Message "  1. Login to vCenter `"$Script:vCenterName`""
                    Write-LogMessage -Type ERROR -Message "  2. Navigate to: Menu > Workload Management > Supervisor Clusters"
                    Write-LogMessage -Type ERROR -Message "  3. Check the status of the supervisor cluster (should show as `"Running`")"
                    Write-LogMessage -Type ERROR -Message "  4. If the cluster is not running, check for errors in the cluster configuration."
                    Write-LogMessage -Type ERROR -Message "  5. Wait for the supervisor cluster to reach `"Running`" state before retrying"
                    Write-Host ""
                    throw [VcfDeploymentException]::new("Deployment failed. Supervisor cluster is not running. Check logs for details.")
                }
                else {
                    # Re-throw unexpected errors
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

                    # Extract error messages for analysis.
                    $errorMessages = $serviceOutput.Messages

                    # Extract clean error message for user-friendly display.
                    $cleanErrorMessage = Get-CleanServiceErrorMessage -ErrorMessage $errorMessages

                    # Pre-fetch kubectl events from the ArgoCD service namespace so every branch can
                    # pattern-match against them, even when the vCenter API message is empty.
                    $argoCDEventsText = ""
                    try {
                        $argoCDEventsOutput = & $Script:KubectlCmd get events -n $serviceNamespace --sort-by=".lastTimestamp" 2>&1
                        if ($LASTEXITCODE -eq 0 -and -not [String]::IsNullOrWhiteSpace($argoCDEventsOutput)) {
                            $argoCDEventsText = ($argoCDEventsOutput | Out-String).Trim()
                        }
                    } catch {
                        Write-LogMessage -Type DEBUG -Message "Could not pre-fetch events from `"$serviceNamespace`": $($_.Exception.Message)"
                    }

                    # IP exhaustion check runs against kubectl events regardless of what the vCenter API reported.
                    $argoCDIpExhaustionDetected = $argoCDEventsText -match "exhausted all IP addresses in requested IPPools|has 0 free ips which is less than"
                    if ($argoCDIpExhaustionDetected) {
                        Write-LogMessage -Type ERROR -Message "ROOT CAUSE — workload network IP pool exhausted: pods could not get IP addresses."
                        Write-LogMessage -Type ERROR -Message "DIAGNOSIS: The supervisor workload network IP pool has no free addresses. ArgoCD pods were scheduled but their network interfaces could not be realized."
                        Write-LogMessage -Type ERROR -Message "SOLUTION: Increase the pool size in supervisor.json: raise `"siteSpec[N].primaryWorkloadNetwork.primaryWorkloadNetworkIPCount`" to allocate more addresses, then roll back (Y) and redeploy. Add at least 8-16 to the current count to leave headroom."
                        $argoCDIpLines = $argoCDEventsText -split "`n" | Where-Object { $_ -match "exhausted|has 0 free ips|NetworkInterfaceRealizationFailed" }
                        if ($argoCDIpLines.Count -gt 0) {
                            Write-LogMessage -Type ERROR -Message "IP exhaustion events:"
                            $argoCDIpLines | Select-Object -Unique | ForEach-Object { Write-LogMessage -Type INFO -Message "  $($_.Exception.Message)" }
                        }
                    }

                    # Check for specific reconciliation failures that indicate leftover resources.
                    switch -Regex ($errorMessages) {
                        "ReconcileFailed|already exists|AlreadyExists" {
                            # Check if this is a namespace not found error (different issue than conflicting resources).
                            if ($errorMessages -match 'namespaces\s+"([^"]*)"\s+not found') {
                                $missingNamespace = $matches[1]
                                if ([String]::IsNullOrWhiteSpace($missingNamespace)) {
                                    Write-LogMessage -Type ERROR -Message "ArgoCD operator installation failed: supervisor service reported a required namespace is empty or missing."
                                    Write-LogMessage -Type ERROR -Message "This can occur when the ArgoCD workload namespace did not exist when the operator was created. This script now creates the namespace before installing the operator."
                                    Write-Host ""
                                    Write-LogMessage -Type ERROR -Message "SOLUTION: Delete the ArgoCD service and re-run so the namespace is created first:"
                                    Write-LogMessage -Type ERROR -Message "  1. In vCenter UI: Menu > Supervisor Management > Services."
                                    Write-LogMessage -Type ERROR -Message "  2. Delete or deactivate the ArgoCD service if it is in ERROR state."
                                    Write-LogMessage -Type ERROR -Message "  3. Re-run this script; it will create the ArgoCD namespace before installing the operator."
                                } else {
                                    Write-LogMessage -Type ERROR -Message "ArgoCD operator installation failed: Required namespace `"$missingNamespace`" does not exist."
                                    Write-LogMessage -Type ERROR -Message "This may indicate the supervisor service namespace was not created properly or was deleted."
                                    Write-Host ""
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
                                Write-Host ""
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
                                Write-LogMessage -Type WARNING -Message "  Use kubectl to manually clean up the namespace: kubectl delete namespace $serviceNamespace"
                                Write-LogMessage -Type WARNING -Message "  List namespaces with: kubectl get namespaces"
                            }
                        }
                        default {
                            Write-LogMessage -Type ERROR -Message "ArgoCD operator installation failed: $cleanErrorMessage"
                        }
                    }
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
        Write-LogMessage -Type ERROR -Message "The service install request has timed out after $TotalWaitTime seconds. Please check the service logs for more information."
        throw [VcfDeploymentException]::new("The service install request has timed out after $TotalWaitTime seconds. Please check the service logs for more information.")
    } catch {
        # Try to extract clean error message from JSON response.

        $errMsg = $_.Exception.Message

        # Extract clean error message from JSON response.
        $cleanMessage = Get-CleanErrorMessage -ErrorMessage $errMsg

        if ($cleanMessage -ne $errMsg) {
            Write-LogMessage -Type ERROR -Message "ArgoCD operator installation failed: $cleanMessage"
        }
        else {
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
        throw [VcfDeploymentException]::new("ArgoCD operator deployment failed. Check logs for details.")
    }
}
Function Resolve-HarborSecretValue {

    <#
        .SYNOPSIS
        Resolves a Harbor configuration secret value, expanding $env: references.

        .DESCRIPTION
        If Value starts with "$env:", extracts the environment variable name and returns its current
        value from the process environment. If the environment variable is not set or is empty, the
        user is prompted to enter the value interactively (masked input). The entered value is then
        stored in the process-scoped environment variable so that subsequent calls within the same
        run resolve consistently without prompting again. Otherwise returns Value as-is, treating
        it as a plain-text secret.

        When RequiredLength is specified and the resolved value does not match that length, the
        function does not return the invalid value. Instead it logs an error and asks:
        "Would you like to re-enter harborConfiguration.<FieldName>? (Y/N)"
        - Y: re-prompts interactively for a corrected value (loop repeats on each wrong-length entry).
        - N: logs an error and throws, aborting deployment.

        This applies in two situations:
        - Pre-set environment variable with wrong length: the Y/N prompt is shown immediately, and
          on Y the cached variable is cleared before interactive prompting begins.
        - Interactive input that is the wrong length: the Y/N prompt is shown after each bad entry.

        Only values explicitly specified as "$env:<VARNAME>" in harborConfiguration trigger prompting.
        Plain-text values in the JSON are returned as-is without any interactive prompt; their
        constraints are validated separately (e.g. Test-JsonHarborConfiguration).

        .PARAMETER FieldName
        The harborConfiguration field name; used in prompt and log messages.

        .PARAMETER RequiredLength
        When greater than zero, the resolved value must be exactly this many characters. A value of
        the wrong length triggers an error followed by a Y/N prompt; Y re-prompts interactively,
        N throws and aborts deployment. Default: 0 (no length constraint).

        .PARAMETER Value
        The secret value from harborConfiguration in infrastructure.json. May be a plain-text string
        or a "$env:<VARNAME>" reference to an environment variable.

        .OUTPUTS
        [String] The resolved secret value, guaranteed to satisfy RequiredLength when specified.

        .EXAMPLE
        $password = Resolve-HarborSecretValue -FieldName "harborAdminPassword" -Value '$env:HARBOR_ADMIN_PW'

        If HARBOR_ADMIN_PW is set, returns its value. If unset, prompts the user to enter it,
        stores the entered value in HARBOR_ADMIN_PW, and returns it.

        .EXAMPLE
        $key = Resolve-HarborSecretValue -FieldName "secretKey" -Value '$env:SECRET_KEY' -RequiredLength 16

        If SECRET_KEY is set and is 16 characters, returns it. If it is set but is the wrong length,
        logs an error and asks "Would you like to re-enter...? (Y/N)". Y clears the cached value
        and prompts interactively; N throws and aborts deployment. If the variable is not set,
        prompts immediately. Wrong-length interactive input also triggers the Y/N prompt.

        .EXAMPLE
        $password = Resolve-HarborSecretValue -FieldName "harborAdminPassword" -Value "MyP@ssw0rd"

        Returns the plain-text value as-is without prompting.
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$FieldName,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 1024)] [Int]$RequiredLength = 0,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Value
    )

    # A value that looks like a broken env var reference must fail explicitly rather than silently
    # being used as a literal password (which would be passed to Harbor undetected).
    if ($Value -match '^\$env:') {
        if (-not ($Value -match '^\$env:([A-Za-z_][A-Za-z0-9_]*)$')) {
            Write-LogMessage -Type ERROR -Message "Resolve-HarborSecretValue: harborConfiguration.$FieldName value `"$Value`" starts with `$env:` but the variable name is not valid. Use `$env:VARNAME format where VARNAME starts with a letter or underscore and contains only letters, digits, and underscores."
            throw [VcfDeploymentException]::new("harborConfiguration.$FieldName has a malformed environment variable reference: `"$Value`".")
        }
    } else {
        return $Value
    }

    $envVarName = $Matches[1]
    $envValue = [System.Environment]::GetEnvironmentVariable($envVarName)

    if (-not [String]::IsNullOrEmpty($envValue)) {
        if ($RequiredLength -eq 0 -or $envValue.Length -eq $RequiredLength) {
            Write-LogMessage -Type DEBUG -Message "Resolve-HarborSecretValue: Resolved harborConfiguration.$FieldName from environment variable `"$envVarName`"."
            return $envValue
        }

        # Pre-set value has wrong length: ask the user if they want to re-enter.
        Write-LogMessage -Type ERROR -Message "Environment variable `"$envVarName`" (harborConfiguration.$FieldName) has $($envValue.Length) character(s) but must be exactly $RequiredLength."
        $retryResponse = $null
        while ($retryResponse -ne "Y" -and $retryResponse -ne "N") {
            $retryResponse = Read-Host "Would you like to re-enter harborConfiguration.$FieldName? (Y/N)"
            $retryResponse = $retryResponse.Trim().ToUpper()
        }
        if ($retryResponse -eq "N") {
            Write-LogMessage -Type ERROR -Message "User chose not to re-enter harborConfiguration.$FieldName. Aborting deployment."
            throw [VcfDeploymentException]::new("Deployment aborted: harborConfiguration.$FieldName must be exactly $RequiredLength character(s).")
        }

        # User chose Y: clear the invalid cached value and fall through to interactive prompting.
        [System.Environment]::SetEnvironmentVariable($envVarName, $null)
        Write-LogMessage -Type WARNING -Message "Prompting for corrected value for harborConfiguration.$FieldName (env:$envVarName)."
    } else {
        Write-LogMessage -Type WARNING -Message "Environment variable `"$envVarName`" (harborConfiguration.$FieldName) is not set. Prompting for interactive input."
    }

    # Prompt the user until a non-empty value satisfying RequiredLength is entered.
    # Wrong-length input triggers a Y/N prompt: Y re-prompts, N throws and aborts.
    $envValue = $null
    while ($null -eq $envValue) {
        $secureInput = Read-Host -Prompt "Enter value for harborConfiguration.$FieldName (env:$envVarName)" -AsSecureString
        if ($secureInput.Length -eq 0) {
            continue
        }

        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureInput)
        try {
            $candidate = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        } finally {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }

        if ($RequiredLength -gt 0 -and $candidate.Length -ne $RequiredLength) {
            Write-LogMessage -Type ERROR -Message "harborConfiguration.$FieldName must be exactly $RequiredLength character(s) but the entered value is $($candidate.Length) character(s)."
            $retryResponse = $null
            while ($retryResponse -ne "Y" -and $retryResponse -ne "N") {
                $retryResponse = Read-Host "Would you like to re-enter harborConfiguration.$FieldName? (Y/N)"
                $retryResponse = $retryResponse.Trim().ToUpper()
            }
            if ($retryResponse -eq "N") {
                Write-LogMessage -Type ERROR -Message "User chose not to re-enter harborConfiguration.$FieldName. Aborting deployment."
                throw [VcfDeploymentException]::new("Deployment aborted: harborConfiguration.$FieldName must be exactly $RequiredLength character(s).")
            }
            continue
        }

        $envValue = $candidate
    }

    # Persist in the process environment so subsequent calls resolve without re-prompting.
    # Security note: storing a plaintext secret in a process environment variable is a known
    # trade-off. The value is scoped to the current process, cleared when the process exits,
    # and is accessible to other code running in the same PowerShell session. It is not written
    # to disk. The caller (New-HarborDataValuesFile) expands it immediately and the YAML it
    # produces is cleaned up in a finally block.
    [System.Environment]::SetEnvironmentVariable($envVarName, $envValue)
    Write-LogMessage -Type DEBUG -Message "Stored interactive input in environment variable `"$envVarName`" for harborConfiguration.$FieldName."
    return $envValue
}
Function ConvertTo-YamlLiteralBlock {

    <#
        .SYNOPSIS
        Converts a file's contents into an indented YAML literal block scalar string.

        .DESCRIPTION
        Reads the file at FilePath, normalizes line endings to LF, trims trailing whitespace,
        and returns a YAML literal block scalar in the form:

          <KeyIndent><KeyName>: |
          <KeyIndent>  <line 1>
          <KeyIndent>  <line 2>
          ...

        This format is suitable for embedding PEM certificate and private key content into a YAML
        configuration file, as required by the Harbor tlsCertificate block.

        .PARAMETER FilePath
        Full path to the file whose contents will form the YAML literal block value.

        .PARAMETER KeyIndentSpaces
        Number of leading spaces for the key line. Content lines receive two additional spaces of
        indentation (e.g., 2 spaces for the key means 4 spaces for each content line).

        .PARAMETER KeyName
        The YAML key name to emit (e.g., "tls.crt", "tls.key", "ca.crt").

        .OUTPUTS
        [String] The YAML literal block scalar string, including a trailing newline.

        .EXAMPLE
        $block = ConvertTo-YamlLiteralBlock -FilePath "/etc/ssl/tls.crt" -KeyName "tls.crt" -KeyIndentSpaces 2

        Returns a string such as:
          tls.crt: |
            -----BEGIN CERTIFICATE-----
            MIIByTCCAW6g...
            -----END CERTIFICATE-----
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$FilePath,
        [Parameter(Mandatory = $true)] [ValidateRange(0, 20)] [Int]$KeyIndentSpaces,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$KeyName
    )

    $fileContent = Get-Content -Path $FilePath -Raw
    # Normalize line endings to LF and remove trailing whitespace.
    $fileContent = ($fileContent -replace '\r\n', "`n").TrimEnd()
    $keyIndent = " " * $KeyIndentSpaces
    $contentIndent = " " * ($KeyIndentSpaces + 2)
    $lines = $fileContent -split '\n'
    $indentedLines = $lines | ForEach-Object { $contentIndent + $_ }
    return $keyIndent + $KeyName + ": |`n" + ($indentedLines -join "`n") + "`n"
}
Function Update-HarborYamlContent {

    <#
        .SYNOPSIS
        Applies all cluster-specific substitutions to a Harbor data values YAML content string.

        .DESCRIPTION
        Performs regex-based replacements on the raw Harbor data values YAML string to set
        hostname, enableNginxLoadBalancer, enableContourHttpProxy, storageClass, optional PVC
        sizes, optional secrets, and optional TLS certificate content. Logs warnings if any
        mandatory substitutions are not found after replacement. Returns the modified YAML string.

        .PARAMETER CaCrtPath
        Optional. Full path to a PEM-encoded CA certificate file.

        .PARAMETER CoreSecret
        Optional. Replacement value for core.secret. "$env:" prefix resolves from environment.

        .PARAMETER DatabasePassword
        Optional. Replacement value for database.password. "$env:" prefix resolves from environment.

        .PARAMETER DatabaseVolumeSize
        Optional. Replacement size for the database PVC (e.g. "10Gi").

        .PARAMETER HarborAdminPassword
        Optional. Replacement value for harborAdminPassword. "$env:" prefix resolves from environment.

        .PARAMETER Hostname
        Required. The DNS-compatible FQDN set as the top-level hostname in the YAML.

        .PARAMETER JobserviceSecret
        Optional. Replacement value for jobservice.secret. "$env:" prefix resolves from environment.

        .PARAMETER JobserviceVolumeSize
        Optional. Replacement size for the jobservice jobLog PVC (e.g. "1Gi").

        .PARAMETER RedisVolumeSize
        Optional. Replacement size for the redis PVC (e.g. "1Gi").

        .PARAMETER RegistrySecret
        Optional. Replacement value for registry.secret. "$env:" prefix resolves from environment.

        .PARAMETER RegistryVolumeSize
        Optional. Replacement size for the registry PVC (e.g. "10Gi").

        .PARAMETER SecretKey
        Optional. Replacement value for secretKey. "$env:" prefix resolves from environment.

        .PARAMETER StorageClassName
        Required. The lowercased storage class name (e.g. "supervisor-osa"). The Supervisor creates
        StorageClasses from policy names by lowercasing them; New-HarborDataValuesFile derives this
        from StoragePolicyName before calling this function.

        .PARAMETER TlsCrtPath
        Optional. Full path to a PEM-encoded TLS certificate file.

        .PARAMETER TlsKeyPath
        Optional. Full path to a PEM-encoded TLS private key file.

        .PARAMETER TrivyVolumeSize
        Optional. Replacement size for the trivy PVC (e.g. "5Gi").

        .PARAMETER YamlContent
        Required. The raw Harbor data values YAML string read from the template file.

        .OUTPUTS
        System.String. The fully substituted YAML content string.

        .EXAMPLE
        $updated = Update-HarborYamlContent -YamlContent $raw -Hostname "harbor.example.com" -StorageClassName "supervisor-osa"
    #>

    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '')]
    Param (
        [Parameter(Mandatory = $false)] [String]$CaCrtPath,
        [Parameter(Mandatory = $false)] [String]$CoreSecret,
        [Parameter(Mandatory = $false)] [String]$DatabasePassword,
        [Parameter(Mandatory = $false)] [String]$DatabaseVolumeSize,
        [Parameter(Mandatory = $false)] [String]$HarborAdminPassword,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Hostname,
        [Parameter(Mandatory = $false)] [String]$JobserviceSecret,
        [Parameter(Mandatory = $false)] [String]$JobserviceVolumeSize,
        [Parameter(Mandatory = $false)] [String]$RedisVolumeSize,
        [Parameter(Mandatory = $false)] [String]$RegistrySecret,
        [Parameter(Mandatory = $false)] [String]$RegistryVolumeSize,
        [Parameter(Mandatory = $false)] [String]$SecretKey,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$StorageClassName,
        [Parameter(Mandatory = $false)] [String]$TlsCrtPath,
        [Parameter(Mandatory = $false)] [String]$TlsKeyPath,
        [Parameter(Mandatory = $false)] [String]$TrivyVolumeSize,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$YamlContent
    )

    # Normalize Windows CRLF to LF before all regex substitutions. Without this, .*$ in
    # multiline mode consumes the trailing \r from each replaced line, producing mixed line
    # endings that go-yaml v3 (used by the Supervisor API) rejects with a parse error.
    $YamlContent = $YamlContent -replace '\r\n', "`n"

    # Set hostname; remove any leading # comment marker on the key line.
    $YamlContent = $YamlContent -replace '(?m)^(?:#\s*)?hostname:.*$', ('hostname: ' + $Hostname)

    # Set enableNginxLoadBalancer to true; remove any leading # comment marker on the key line.
    $YamlContent = $YamlContent -replace '(?m)^(?:#\s*)?(enableNginxLoadBalancer:)\s*.*$', 'enableNginxLoadBalancer: true'

    # Set enableContourHttpProxy to false; remove any leading # comment marker on the key line.
    $YamlContent = $YamlContent -replace '(?m)^(?:#\s*)?(enableContourHttpProxy:)\s*.*$', 'enableContourHttpProxy: false'

    # Replace all storageClass values; preserve indentation by capturing the key prefix.
    $YamlContent = $YamlContent -replace '(?m)^(\s+storageClass:\s*).*$', ('$1"' + $StorageClassName + '"')

    # Replace optional PVC sizes when specified; each section is targeted by its YAML path.
    # NOTE: replacement uses '${1}' not '$1' to prevent .NET regex greedy-digit parsing:
    # '$1' + '10Gi' concatenates to '$110Gi' which the engine parses as group 110 (empty),
    # collapsing the entire captured multi-line block. '${1}' explicitly delimits the group.
    if (-not [String]::IsNullOrWhiteSpace($RegistryVolumeSize)) {
        $YamlContent = $YamlContent -replace '(?m)(^    registry:\r?\n(?:      [^\n]*\r?\n)*?      size:\s*)\S+', ('${1}' + $RegistryVolumeSize)
    }
    if (-not [String]::IsNullOrWhiteSpace($JobserviceVolumeSize)) {
        # Jobservice size is nested under jobLog (persistence.persistentVolumeClaim.jobservice.jobLog.size).
        $YamlContent = $YamlContent -replace '(?m)(^    jobservice:\r?\n      jobLog:\r?\n(?:        [^\n]*\r?\n)*?        size:\s*)\S+', ('${1}' + $JobserviceVolumeSize)
    }
    if (-not [String]::IsNullOrWhiteSpace($DatabaseVolumeSize)) {
        $YamlContent = $YamlContent -replace '(?m)(^    database:\r?\n(?:      [^\n]*\r?\n)*?      size:\s*)\S+', ('${1}' + $DatabaseVolumeSize)
    }
    if (-not [String]::IsNullOrWhiteSpace($RedisVolumeSize)) {
        $YamlContent = $YamlContent -replace '(?m)(^    redis:\r?\n(?:      [^\n]*\r?\n)*?      size:\s*)\S+', ('${1}' + $RedisVolumeSize)
    }
    if (-not [String]::IsNullOrWhiteSpace($TrivyVolumeSize)) {
        $YamlContent = $YamlContent -replace '(?m)(^    trivy:\r?\n(?:      [^\n]*\r?\n)*?      size:\s*)\S+', ('${1}' + $TrivyVolumeSize)
    }
    # Replace optional top-level secret values; $env: references are resolved from the environment.
    if (-not [String]::IsNullOrWhiteSpace($HarborAdminPassword)) {
        $resolvedSecret = Resolve-HarborSecretValue -FieldName "harborAdminPassword" -Value $HarborAdminPassword
        $YamlContent = $YamlContent -replace '(?m)^(?:#\s*)?harborAdminPassword:.*$', ('harborAdminPassword: ' + $resolvedSecret.Replace('$', '$$'))
    }
    if (-not [String]::IsNullOrWhiteSpace($SecretKey)) {
        # RequiredLength enforces Y/N-gated re-prompting for $env: references (normally already
        # resolved correctly by Invoke-HarborEnvVarPreflight). For plain-text values that somehow
        # bypassed Test-JsonHarborConfiguration pre-flight validation, the throw below acts as
        # a safety net.
        $resolvedSecret = Resolve-HarborSecretValue -FieldName "secretKey" -Value $SecretKey -RequiredLength 16
        if ($resolvedSecret.Length -ne 16) {
            Write-LogMessage -Type ERROR -Message "Harbor secretKey must be exactly 16 characters but the resolved value is $($resolvedSecret.Length) character(s). Update the `"SECRET_KEY`" environment variable (or harborConfiguration.secretKey) to a 16-character string."
            throw [VcfDeploymentException]::new("Harbor secretKey must be exactly 16 characters but the resolved value is $($resolvedSecret.Length) character(s). Update the `"SECRET_KEY`" environment variable (or harborConfiguration.secretKey) to a 16-character string.")
        }
        $YamlContent = $YamlContent -replace '(?m)^(?:#\s*)?secretKey:.*$', ('secretKey: ' + $resolvedSecret.Replace('$', '$$'))
    }
    # Replace optional nested secret values; each section is anchored by its top-level YAML key.
    # Uses '${1}' (not '$1') to prevent .NET regex greedy-digit group number ambiguity.
    if (-not [String]::IsNullOrWhiteSpace($DatabasePassword)) {
        $resolvedSecret = Resolve-HarborSecretValue -FieldName "databasePassword" -Value $DatabasePassword
        $YamlContent = $YamlContent -replace '(?m)(^database:\r?\n(?:  [^\n]*\r?\n)*?  password:\s*).*$', ('${1}' + $resolvedSecret.Replace('$', '$$'))
    }
    if (-not [String]::IsNullOrWhiteSpace($CoreSecret)) {
        $resolvedSecret = Resolve-HarborSecretValue -FieldName "coreSecret" -Value $CoreSecret
        $YamlContent = $YamlContent -replace '(?m)(^core:\r?\n(?:  [^\n]*\r?\n)*?  secret:\s*).*$', ('${1}' + $resolvedSecret.Replace('$', '$$'))
    }
    if (-not [String]::IsNullOrWhiteSpace($JobserviceSecret)) {
        $resolvedSecret = Resolve-HarborSecretValue -FieldName "jobserviceSecret" -Value $JobserviceSecret
        $YamlContent = $YamlContent -replace '(?m)(^jobservice:\r?\n(?:  [^\n]*\r?\n)*?  secret:\s*).*$', ('${1}' + $resolvedSecret.Replace('$', '$$'))
    }
    if (-not [String]::IsNullOrWhiteSpace($RegistrySecret)) {
        $resolvedSecret = Resolve-HarborSecretValue -FieldName "registrySecret" -Value $RegistrySecret
        $YamlContent = $YamlContent -replace '(?m)(^registry:\r?\n(?:  [^\n]*\r?\n)*?  secret:\s*).*$', ('${1}' + $resolvedSecret.Replace('$', '$$'))
    }
    # Inject TLS certificate PEM content when TlsCrtPath and TlsKeyPath are provided.
    if (-not [String]::IsNullOrWhiteSpace($TlsCrtPath)) {
        $tlsInsertBlock = ConvertTo-YamlLiteralBlock -FilePath $TlsCrtPath -KeyName "tls.crt" -KeyIndentSpaces 2
        $tlsInsertBlock += ConvertTo-YamlLiteralBlock -FilePath $TlsKeyPath -KeyName "tls.key" -KeyIndentSpaces 2
        if (-not [String]::IsNullOrWhiteSpace($CaCrtPath)) {
            $tlsInsertBlock += ConvertTo-YamlLiteralBlock -FilePath $CaCrtPath -KeyName "ca.crt" -KeyIndentSpaces 2
        }
        # Insert the TLS block immediately after the tlsSecretLabels line in the tlsCertificate section.
        $YamlContent = $YamlContent -replace '(?m)(  tlsSecretLabels:[^\n]*\r?\n)', ('$1' + $tlsInsertBlock.Replace('$', '$$'))
    }
    # Warn if mandatory substitutions are not reflected in the output.
    if ($YamlContent -notmatch ('(?m)^hostname:\s*' + [regex]::Escape($Hostname))) {
        Write-LogMessage -Type WARNING -Message "Update-HarborYamlContent: hostname `"$Hostname`" not found after replacement. Verify the template format."
    }
    if ($YamlContent -notmatch '(?m)^enableNginxLoadBalancer:\s*true') {
        Write-LogMessage -Type WARNING -Message "Update-HarborYamlContent: enableNginxLoadBalancer: true not found after replacement. Verify the template format."
    }
    if ($YamlContent -notmatch '(?m)^enableContourHttpProxy:\s*false') {
        Write-LogMessage -Type WARNING -Message "Update-HarborYamlContent: enableContourHttpProxy: false not found after replacement. Verify the template format."
    }
    if ($YamlContent -notmatch ('(?m)^\s+storageClass:\s*"?' + [regex]::Escape($StorageClassName) + '"?')) {
        Write-LogMessage -Type WARNING -Message "Update-HarborYamlContent: Storage class `"$StorageClassName`" not found after replacement. Verify the template format."
    }
    return $YamlContent
}
Function New-HarborDataValuesFile {

    <#
        .SYNOPSIS
        Creates a temporary Harbor data values YAML file configured for a specific cluster.

        .DESCRIPTION
        Reads the provided Harbor data values YAML template, applies the following cluster-specific
        changes, and writes the result to a new temporary file:

        - Sets hostname to the provided value. Uncomments the key if preceded by a # marker.
        - Sets enableNginxLoadBalancer to true, unconditionally. Uncomments the key if preceded by #.
        - Sets enableContourHttpProxy to false, unconditionally. Uncomments the key if preceded by #.
        - Replaces every storageClass value in the persistence section with the storage policy name
          (StoragePolicyName), which matches the Kubernetes StorageClass automatically created by the
          Supervisor for this policy (e.g., "supervisor-OSA"). This is the same name as the tag applied
          to the datastore during vSAN/VMFS setup (supervisorNamePrefix + edgeSite).
        - Optionally replaces individual PVC sizes for registry, jobservice, database, redis, and
          trivy when the corresponding volume size parameter is provided.
        - Optionally replaces secret values (harborAdminPassword, secretKey, database.password,
          core.secret, jobservice.secret, registry.secret). Any value prefixed with "$env:" is
          resolved from the named environment variable at runtime instead of using the literal string,
          so secrets are never persisted in infrastructure.json.
        - When TlsCrtPath and TlsKeyPath are provided, their PEM file contents are injected as YAML
          literal block scalars (tls.crt and tls.key) under the tlsCertificate key. CaCrtPath may
          optionally be included as ca.crt in the same block.

        The temporary file is created in the system temp directory. The caller is responsible for
        cleaning it up after use.

        .PARAMETER CaCrtPath
        Optional. Full path to a PEM-encoded CA certificate file. When provided, its contents are
        injected as ca.crt under tlsCertificate in the YAML. Only valid when TlsCrtPath and
        TlsKeyPath are also provided.

        .PARAMETER CoreSecret
        Optional. Replacement value for core.secret in the YAML. If prefixed with "$env:", the
        value is read from the named environment variable at runtime.

        .PARAMETER DatabasePassword
        Optional. Replacement value for database.password in the YAML. If prefixed with "$env:",
        the value is read from the named environment variable at runtime.

        .PARAMETER DatabaseVolumeSize
        Optional. New size for the database PVC (persistence.persistentVolumeClaim.database.size).
        Must be a positive integer followed by "Gi" (e.g. "10Gi"). Omit to retain the template value.

        .PARAMETER EdgeSite
        The edge site identifier for this cluster (e.g., "ESA", "site1"). Used in the temporary
        file name for traceability.

        .PARAMETER HarborAdminPassword
        Optional. Replacement value for harborAdminPassword in the YAML. If prefixed with "$env:",
        the value is read from the named environment variable at runtime.

        .PARAMETER HarborTemplateFilePath
        Full path to the Harbor data values YAML template file. Typically the value of
        common.supervisorServices.harborDataTemplateYamlFileName (with parentDirectory) from infrastructure.json.

        .PARAMETER Hostname
        The DNS-compatible FQDN (or IP) that Harbor will be accessed at (e.g. "harbor.example.com").
        Sets the top-level hostname key; uncomments the key if it is preceded by a # marker.

        .PARAMETER JobserviceSecret
        Optional. Replacement value for jobservice.secret in the YAML. If prefixed with "$env:",
        the value is read from the named environment variable at runtime.

        .PARAMETER JobserviceVolumeSize
        Optional. New size for the jobservice PVC
        (persistence.persistentVolumeClaim.jobservice.jobLog.size).
        Must be a positive integer followed by "Gi" (e.g. "1Gi"). Omit to retain the template value.

        .PARAMETER RedisVolumeSize
        Optional. New size for the redis PVC (persistence.persistentVolumeClaim.redis.size).
        Must be a positive integer followed by "Gi" (e.g. "1Gi"). Omit to retain the template value.

        .PARAMETER RegistrySecret
        Optional. Replacement value for registry.secret in the YAML. If prefixed with "$env:",
        the value is read from the named environment variable at runtime.

        .PARAMETER RegistryVolumeSize
        Optional. New size for the registry PVC (persistence.persistentVolumeClaim.registry.size).
        Must be a positive integer followed by "Gi" (e.g. "10Gi"). Omit to retain the template value.

        .PARAMETER SecretKey
        Optional. Replacement value for secretKey in the YAML (used for encryption; must be 16 chars).
        If prefixed with "$env:", the value is read from the named environment variable at runtime.

        .PARAMETER StoragePolicyName
        The storage policy name for this cluster (e.g., "supervisor-OSA"). The Supervisor creates a
        Kubernetes StorageClass from this name by lowercasing it and replacing spaces with dashes
        (e.g., "supervisor-osa"). Equals supervisorNamePrefix concatenated with the edge site.

        .PARAMETER TlsCrtPath
        Optional. Full path to a PEM-encoded TLS certificate file. When provided (together with
        TlsKeyPath), its contents are injected as tls.crt under tlsCertificate in the YAML.
        Must be specified together with TlsKeyPath.

        .PARAMETER TlsKeyPath
        Optional. Full path to a PEM-encoded TLS private key file. When provided (together with
        TlsCrtPath), its contents are injected as tls.key under tlsCertificate in the YAML.
        Must be specified together with TlsCrtPath.

        .PARAMETER TrivyVolumeSize
        Optional. New size for the trivy PVC (persistence.persistentVolumeClaim.trivy.size).
        Must be a positive integer followed by "Gi" (e.g. "5Gi"). Omit to retain the template value.

        .OUTPUTS
        System.String. The full path to the temporary Harbor data values YAML file.

        .EXAMPLE
        $harborValuesPath = New-HarborDataValuesFile -EdgeSite "site1" -HarborTemplateFilePath "harbor-data-values-v2.14.2.yml" -Hostname "harbor.site1.example.com" -StoragePolicyName "supervisor-OSA"

        Creates a temporary Harbor data values file with hostname "harbor.site1.example.com",
        storageClass "supervisor-OSA", enableNginxLoadBalancer true, enableContourHttpProxy false,
        and all PVC sizes and secrets unchanged from the template.

        .EXAMPLE
        $harborValuesPath = New-HarborDataValuesFile -EdgeSite "site2" -HarborTemplateFilePath "harbor-data-values-v2.14.2.yml" -Hostname "harbor.site2.example.com" -StoragePolicyName "supervisor-site2" -RegistryVolumeSize "50Gi" -HarborAdminPassword '$env:HARBOR_ADMIN_PW' -TlsCrtPath "C:\certs\harbor.crt" -TlsKeyPath "C:\certs\harbor.key" -CaCrtPath "C:\certs\ca.crt"

        Creates a Harbor data values file with a custom hostname, overridden registry PVC size, an
        admin password resolved from the HARBOR_ADMIN_PW environment variable, and a custom TLS
        certificate with CA injected from the specified PEM files.

        .NOTES
        - The temporary file must be cleaned up by the caller after use (Remove-Item).
        - StoragePolicyName is lowercased (and spaces replaced with dashes) to derive the Kubernetes
          StorageClass name (e.g., policy "supervisor-OSA" -> StorageClass "supervisor-osa").
          Per Broadcom docs: the Supervisor converts policy names to lower case when creating StorageClasses.
        - Both enableNginxLoadBalancer and enableContourHttpProxy are set unconditionally, regardless
          of the template values, and any # comment prefix on those keys is removed.
        - All storageClass occurrences in the persistence.persistentVolumeClaim section are replaced.
        - Jobservice PVC size is nested at persistence.persistentVolumeClaim.jobservice.jobLog.size.
        - Secret values prefixed with "$env:" are resolved from environment variables at runtime,
          preventing plain-text secrets from being stored in infrastructure.json.
        - TlsCrtPath and TlsKeyPath must always be specified together. CaCrtPath is optional and
          only valid when both TLS file parameters are present. File existence is validated during
          the JSON deep check phase before deployment begins.
    #>

    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '')]
    Param (
        [Parameter(Mandatory = $false)] [String]$CaCrtPath,
        [Parameter(Mandatory = $false)] [String]$CoreSecret,
        [Parameter(Mandatory = $false)] [String]$DatabasePassword,
        [Parameter(Mandatory = $false)] [String]$DatabaseVolumeSize,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EdgeSite,
        [Parameter(Mandatory = $false)] [String]$HarborAdminPassword,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$HarborTemplateFilePath,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Hostname,
        [Parameter(Mandatory = $false)] [String]$JobserviceSecret,
        [Parameter(Mandatory = $false)] [String]$JobserviceVolumeSize,
        [Parameter(Mandatory = $false)] [String]$RedisVolumeSize,
        [Parameter(Mandatory = $false)] [String]$RegistrySecret,
        [Parameter(Mandatory = $false)] [String]$RegistryVolumeSize,
        [Parameter(Mandatory = $false)] [String]$SecretKey,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$StoragePolicyName,
        [Parameter(Mandatory = $false)] [String]$TlsCrtPath,
        [Parameter(Mandatory = $false)] [String]$TlsKeyPath,
        [Parameter(Mandatory = $false)] [String]$TrivyVolumeSize
    )

    Write-LogMessage -Type DEBUG -Message "Entered New-HarborDataValuesFile function..."

    if (-not (Test-Path -Path $HarborTemplateFilePath)) {
        Write-LogMessage -Type ERROR -Message "Harbor data values template file not found: `"$HarborTemplateFilePath`"."
        throw [VcfDeploymentException]::new("Harbor data values template file not found: `"$HarborTemplateFilePath`".")
    }

    # Kubernetes StorageClasses use a lowercase, dash-separated form of the storage policy name.
    # The Supervisor derives this automatically; we replicate the same transform here.
    $storageClassName = ($StoragePolicyName.ToLower() -replace ' ', '-')
    Write-LogMessage -Type DEBUG -Message "New-HarborDataValuesFile: hostname: `"$Hostname`", storageClass: `"$storageClassName`""

    $tempYamlFile = $null
    try {
        $tempPath = [System.IO.Path]::GetTempPath()
        # Use a GUID suffix rather than a timestamp so the filename is unpredictable to local processes.
        $tempYamlFile = Join-Path $tempPath "harbor-data-values-$EdgeSite-$([Guid]::NewGuid().ToString('N')).yml"
        Write-LogMessage -Type DEBUG -Message "New-HarborDataValuesFile: Temporary file path: `"$tempYamlFile`""

        # Read the template and apply all cluster-specific YAML substitutions via helper.
        $rawYaml = Get-Content -Path $HarborTemplateFilePath -Raw -Encoding UTF8
        $updateParams = @{
            CaCrtPath           = $CaCrtPath
            CoreSecret          = $CoreSecret
            DatabasePassword    = $DatabasePassword
            DatabaseVolumeSize  = $DatabaseVolumeSize
            HarborAdminPassword = $HarborAdminPassword
            Hostname            = $Hostname
            JobserviceSecret    = $JobserviceSecret
            JobserviceVolumeSize = $JobserviceVolumeSize
            RedisVolumeSize     = $RedisVolumeSize
            RegistrySecret      = $RegistrySecret
            RegistryVolumeSize  = $RegistryVolumeSize
            SecretKey           = $SecretKey
            StorageClassName    = $storageClassName
            TlsCrtPath          = $TlsCrtPath
            TlsKeyPath          = $TlsKeyPath
            TrivyVolumeSize     = $TrivyVolumeSize
            YamlContent         = $rawYaml
        }
        $yamlContent = Update-HarborYamlContent @updateParams

        # Pre-validate YAML structure before writing; catches problems before the server does.
        # ConvertFrom-Yaml won't catch every go-yaml edge case, but will catch gross structural
        # errors (missing colons, bad indentation, etc.). Log line-numbered content so any
        # server-reported line number (e.g. "line 222") maps directly to a visible log entry.
        try {
            $null = ConvertFrom-Yaml -YamlContent $yamlContent
        } catch {
            Write-LogMessage -Type WARNING -Message "New-HarborDataValuesFile: YAML pre-validation failed: $($_.Exception.Message). Logging numbered content for diagnostics."
            $inSecretBlockPre = $false
            $secretBlockMinIndentPre = 0
            $lineNumPre = 0
            $yamlContent -split "`n" | ForEach-Object {
                $lineNumPre++
                $logLinePre = $_
                if ($inSecretBlockPre -and $logLinePre -match "^(\s+)\S" -and $matches[1].Length -ge $secretBlockMinIndentPre) {
                    $logLinePre = $logLinePre -replace '\S.*$', '[REDACTED]'
                } elseif ($logLinePre -match '^(\s*)(?:tls\.key|ca\.key):\s*\|') {
                    $inSecretBlockPre = $true
                    $secretBlockMinIndentPre = $matches[1].Length + 1
                } else {
                    $inSecretBlockPre = $false
                    $logLinePre = $logLinePre -replace '^(\s*(?:harborAdminPassword|secretKey|password|secret):\s+)\S.*$', '$1[REDACTED]'
                }
                Write-LogMessage -Type DEBUG -Message "YAML line $($lineNumPre.ToString().PadLeft(4)): $logLinePre"
            }
            Write-LogMessage -Type ERROR -Message "Deployment failed. Generated Harbor YAML is structurally invalid. Check DEBUG logs for the full numbered content."
            throw [VcfDeploymentException]::new("Deployment failed. Generated Harbor YAML is structurally invalid. Check DEBUG logs for the full numbered content.")
        }

        # Write secrets file with owner-only permissions to prevent other OS users from reading secrets.
        $yamlBytes = [System.Text.Encoding]::UTF8.GetBytes($yamlContent)
        $fileStream = [System.IO.File]::Open($tempYamlFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $fileStream.Write($yamlBytes, 0, $yamlBytes.Length)
        } finally {
            $fileStream.Dispose()
        }
        # Restrict file to owner-only to prevent other OS users from reading secrets.
        if (-not $IsWindows) {
            & chmod 600 $tempYamlFile
            if ($LASTEXITCODE -ne 0) {
                Write-LogMessage -Type WARNING -Message "New-HarborDataValuesFile: chmod 600 failed (exit $LASTEXITCODE) on `"$tempYamlFile`". Harbor secrets file may be readable by other OS users."
            }
        } else {
            try {
                $acl = Get-Acl -Path $tempYamlFile
                $acl.SetAccessRuleProtection($true, $false)
                $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
                $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
                    $currentUser,
                    [System.Security.AccessControl.FileSystemRights]::FullControl,
                    [System.Security.AccessControl.InheritanceFlags]::None,
                    [System.Security.AccessControl.PropagationFlags]::None,
                    [System.Security.AccessControl.AccessControlType]::Allow
                )
                $acl.AddAccessRule($rule)
                Set-Acl -Path $tempYamlFile -AclObject $acl
            } catch {
                Write-LogMessage -Type WARNING -Message "New-HarborDataValuesFile: Could not restrict ACL on Harbor secrets file `"$tempYamlFile`": $($_.Exception.Message). File may be readable by other OS users."
            }
        }

        if (-not (Test-Path -Path $tempYamlFile)) {
            Write-LogMessage -Type ERROR -Message "New-HarborDataValuesFile: Temporary file was not created: `"$tempYamlFile`"."
            throw [VcfDeploymentException]::new("New-HarborDataValuesFile: Temporary file was not created: `"$tempYamlFile`".")
        }

        # Log numbered content at DEBUG level so any server-reported line number maps directly.
        # Secret scalar fields and private key PEM blocks are replaced with [REDACTED].
        Write-LogMessage -Type DEBUG -Message "--- BEGIN HARBOR DATA VALUES (numbered, `"$tempYamlFile`") ---"
        $inSecretBlock = $false
        $secretBlockMinIndent = 0
        $lineNum = 0
        $yamlContent -split "`n" | ForEach-Object {
            $lineNum++
            $logLine = $_

            if ($inSecretBlock -and $logLine -match "^(\s+)\S" -and $matches[1].Length -ge $secretBlockMinIndent) {
                # Inside a private key PEM literal block: redact every content line.
                $logLine = $logLine -replace '\S.*$', '[REDACTED]'
            } elseif ($logLine -match '^(\s*)(?:tls\.key|ca\.key):\s*\|') {
                # Opening line of a private key literal block: keep the key name, redact content below.
                $inSecretBlock = $true
                $secretBlockMinIndent = $matches[1].Length + 1
            } else {
                # Outside a PEM block: reset flag, then redact scalar password/secret fields.
                $inSecretBlock = $false
                $logLine = $logLine -replace '^(\s*(?:harborAdminPassword|secretKey|password|secret):\s+)\S.*$', '$1[REDACTED]'
            }

            Write-LogMessage -Type DEBUG -Message "YAML line $($lineNum.ToString().PadLeft(4)): $logLine"
        }
        Write-LogMessage -Type DEBUG -Message "--- END HARBOR DATA VALUES ---"

        Write-LogMessage -Type INFO -Message "Created temporary Harbor data values file for edge site `"$EdgeSite`" (hostname: `"$Hostname`", storageClass: `"$storageClassName`")"
        return $tempYamlFile
    } catch {
        Write-LogMessage -Type ERROR -Message "New-HarborDataValuesFile: Failed to create Harbor data values file from template `"$HarborTemplateFilePath`": $($_.Exception.Message)"
        if ($tempYamlFile -and (Test-Path -Path $tempYamlFile)) {
            Remove-Item -Path $tempYamlFile -Force -ErrorAction SilentlyContinue
        }
        throw [VcfDeploymentException]::new("New-HarborDataValuesFile: Failed to create Harbor data values file from template `"$HarborTemplateFilePath`": $($_.Exception.Message)")
    }
}
Function Convert-CountToInt {

    <#
        .SYNOPSIS
        Recursively converts 'count' properties from floating-point numbers to integers in PowerShell objects.

        .DESCRIPTION
        The Convert-CountToInt function traverses PowerShell objects (PSCustomObjects, hashtables, arrays)
        and converts any property named 'count' from floating-point numbers (double, single, decimal) or
        numeric strings to integer values. This is particularly useful when working with JSON data that
        may contain count values as floating-point numbers but should be integers for proper API consumption.

        The function performs recursive traversal of nested objects and collections, ensuring that all
        'count' properties throughout the entire object hierarchy are converted. It handles various data
        types including PSCustomObjects, hashtables, and enumerable collections while preserving the
        original object structure.

        Key features:
        - Recursive processing of nested objects and collections
        - Case-insensitive matching of 'count' property names
        - Support for PSCustomObjects, hashtables, and enumerable collections
        - Conversion from double, single, decimal, and numeric string values
        - Culture-invariant string parsing for consistent results
        - Truncation toward zero for floating-point to integer conversion

        .PARAMETER Item
        The PowerShell object to process. This can be any type of object including:
        - PSCustomObject with properties that may contain 'count' fields
        - Hashtable or IDictionary with 'count' keys
        - Arrays or other enumerable collections containing objects with 'count' properties
        - Individual values (which will be returned unchanged if not a container type)

        The parameter accepts pipeline input, allowing for easy processing of multiple objects.

        .EXAMPLE
        $jsonFilePathObject = @{
            name = "example"
            count = 5.0
            items = @(
                @{ count = "10.0"; value = "item1" },
                @{ count = 3.14; value = "item2" }
            )
        }
        Convert-CountToInt $jsonFilePathObject

        Converts the floating-point 'count' values to integers throughout the nested structure.
        After conversion: count = 5, items[0].count = 10, items[1].count = 3

        .EXAMPLE
        $pscustomObject = [PSCustomObject]@{
            Count = 7.5
            Details = [PSCustomObject]@{
                ItemCount = 12.0
                Count = "15.0"
            }
        }
        Convert-CountToInt $pscustomObject

        Processes a PSCustomObject with nested objects, converting all 'count' properties to integers.
        Case-insensitive matching ensures both 'Count' and 'count' properties are converted.

        .EXAMPLE
        $data | Convert-CountToInt

        Processes pipeline input, useful for converting multiple objects or JSON data imported from files.

        .NOTES
        - The function modifies objects in-place rather than creating copies
        - Uses culture-invariant parsing for consistent string-to-number conversion across different locales
        - Truncates floating-point values toward zero when converting to integers (5.9 becomes 5, -3.7 becomes -3)
        - Only processes properties specifically named 'count' (case-insensitive)
        - Handles circular references gracefully by processing each object only once per call
        - Designed for use with JSON data structures that may contain numeric count fields as floating-point values

        .INPUTS
        System.Object
        Any PowerShell object that may contain 'count' properties requiring integer conversion.

        .OUTPUTS
        None
        The function modifies input objects in-place and does not return values.

        .LINK
        ConvertFrom-Json
        ConvertTo-Json
    #>

    Param (
        [Parameter(ValueFromPipeline = $true)] $Item
    )

    process {
        # Return immediately if the input item is null to avoid processing null values.
        if ($null -eq $Item) { return }

        # Process enumerable collections (arrays, lists, etc.) but exclude strings.
        # Recursively call Convert-CountToInt on each element in the collection.
        if ($Item -is [System.Collections.IEnumerable] -and $Item -isnot [string]) {
            foreach ($elem in $Item) { Convert-CountToInt $elem }
            return
        }

        # Process PSCustomObject properties.
        # Walk through all properties and convert any named 'count' from numeric types to integers.
        if ($Item -is [pscustomobject]) {
            foreach ($prop in $Item.PSObject.Properties) {
                # Case-insensitive check for 'count' property name.

                if ($prop.Name -ieq 'count') {
                    $val = $prop.Value
                    # Convert floating-point numbers (double, single, decimal) to integers
                    if ($val -is [double] -or $val -is [single] -or $val -is [decimal]) {
                        $prop.Value = [int][double]$val       # Truncate toward zero
                    }
                    # Convert numeric strings to integers using culture-invariant parsing.

                    elseif ($val -is [string]) {
                        $parsed = 0.0
                        if ([double]::TryParse(
                            $val,
                            [System.Globalization.NumberStyles]::Float,
                            [System.Globalization.CultureInfo]::InvariantCulture,
                            [ref] $parsed
                        )) {
                            $prop.Value = [int][double]$parsed  # Convert "1.0" -> 1
                        }
                    }
                }
                # Recursively process nested property values.

                Convert-CountToInt $prop.Value
            }
            return
        }

        # Process hashtables and other dictionary types (IDictionary interface)
        # This provides support for hashtables created with -AsHashtable parameter in ConvertFrom-Json.
        if ($Item -is [System.Collections.IDictionary]) {
            # Create a copy of keys to avoid modification during enumeration.

            foreach ($key in @($Item.Keys)) {
                # Case-insensitive check for 'count' key in hashtables.

                if ($key -is [string] -and $key.Equals('count',[System.StringComparison]::OrdinalIgnoreCase)) {
                    $val = $Item[$key]
                    # Convert floating-point numbers to integers.

                    if ($val -is [double] -or $val -is [single] -or $val -is [decimal]) {
                        $Item[$key] = [int][double]$val
                    }
                    # Convert numeric strings to integers using culture-invariant parsing.

                    elseif ($val -is [string]) {
                        $parsed = 0.0
                        if ([double]::TryParse($val,
                            [System.Globalization.NumberStyles]::Float,
                            [System.Globalization.CultureInfo]::InvariantCulture,
                            [ref] $parsed)) {
                            $Item[$key] = [int][double]$parsed
                        }
                    }
                }
                # Recursively process nested dictionary values.

                Convert-CountToInt $Item[$key]
            }
        }
    }
}
Function Get-InteractiveInput {

    <#
        .SYNOPSIS
        Prompts the user for input with validation to ensure a non-empty value is provided.

        .DESCRIPTION
        The Get-InteractiveInput function provides a way to collect user input
        with optional validation that prevents empty responses. By default the function
        repeatedly prompts until a non-empty value is entered. When AllowEmpty is specified
        (e.g. for ESX root with no password), a single prompt is used and empty input is accepted.

        The function supports both standard text input and secure string input for
        sensitive information like passwords. When using secure string mode, the input
        is masked and returned as a SecureString object for enhanced security handling.

        This function is essential for interactive scripts that require user input and
        cannot proceed without valid data, providing a consistent user experience across
        the VCF PowerShell Toolbox.

        .PARAMETER AllowEmpty
        When specified, empty input is accepted and returned (e.g. for null/empty ESX root password).
        The prompt is shown once; pressing Enter without typing returns an empty string or empty SecureString.

        .PARAMETER AsSecureString
        When specified, the input will be collected as a secure string with masked
        characters (asterisks) displayed instead of the actual input. This is
        recommended for passwords and other sensitive information. The returned
        value will be a System.Security.SecureString object.

        .PARAMETER PromptMessage
        The message displayed to the user when requesting input. This should be a clear,
        descriptive prompt that explains what information is being requested. The message
        will be displayed repeatedly until valid input is provided.
        When specified, the input will be collected as a secure string with masked
        characters (asterisks) displayed instead of the actual input. This is
        recommended for passwords and other sensitive information. The returned
        value will be a System.Security.SecureString object.

        .EXAMPLE
        $domain = Get-InteractiveInput -PromptMessage "Enter your domain (or press Enter for default)"

        .EXAMPLE
        $esxPass = Get-InteractiveInput -PromptMessage "Enter ESX root password (or press Enter for no password): " -AsSecureString -AllowEmpty
        Collects ESX password interactively; empty input is accepted for null root password.

    #>

    Param (
        [Parameter(Mandatory = $false)] [Switch]$AllowEmpty,
        [Parameter(Mandatory = $false)] [Switch]$AsSecureString,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$PromptMessage
    )

    Write-LogMessage -Type DEBUG -Message "Entered Get-InteractiveInput function..."

    do {
        if ($AsSecureString) {
            $value = Read-Host $PromptMessage -asSecureString
        } else {
            $value = Read-Host $PromptMessage
        }
    } while ((-not $AllowEmpty) -and ($value.Length -eq 0))

    return $value
}
Function Get-JsonDataWithValidation {

    <#
        .SYNOPSIS
        Loads and validates JSON file existence and parseability with consistent error handling.

        .DESCRIPTION
        Common helper function for JSON validation functions that handles file existence checking
        and JSON parsing with consistent error handling and logging. This function eliminates
        code duplication across Test-JsonMissingProperties and Test-JsonNullValues by centralizing
        the common file validation and parsing logic.

        The function performs two critical validations:
        1. Verifies the JSON file exists at the specified path
        2. Attempts to parse the JSON file using ConvertFrom-JsonSafely

        If either validation fails, the function updates the provided ValidationResult object
        with appropriate error information and returns $null. On success, it returns the parsed
        JSON data and stores it in the ValidationResult.JsonData property.

        .PARAMETER JsonFilePath
        Path to the JSON file to load and validate.

        .PARAMETER JsonObjectName
        Name of the JSON object for error messages and logging (e.g., "InputConfiguration", "SupervisorConfiguration").
        This name is used to provide context in error messages.

        .PARAMETER ValidationResult
        Reference to the validation result object to update on error. The function will set
        IsValid, ErrorCount, and Summary properties on validation failure.

        .OUTPUTS
        PSCustomObject - Parsed JSON data on success, or $null if validation failed.

        .EXAMPLE
        $jsonFilePathData = Get-JsonDataWithValidation -JsonFilePath $JsonFilePath -JsonObjectName $JsonObjectName -ValidationResult ([ref]$validationResult)
        if ($null -eq $jsonFilePathData) {
            return $validationResult
        }

        Loads JSON data and returns early if validation fails.

        .NOTES
        This function is a helper for Test-JsonMissingProperties and Test-JsonNullValues.

        Error Handling:
        • Updates ValidationResult object with error details
        • Logs errors using Write-LogMessage
        • Returns $null on any validation failure
        • Preserves parsed JSON data in ValidationResult.JsonData on success
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$JsonFilePath,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$JsonObjectName,
        [Parameter(Mandatory = $true)] [ref]$ValidationResult
    )

    Write-LogMessage -Type DEBUG -Message "Validating and loading JSON file: $JsonFilePath"

    # Validate that the JSON file exists.
    if (-not (Test-Path -Path $JsonFilePath -PathType Leaf)) {
        $ValidationResult.Value.IsValid = $false
        $ValidationResult.Value.ErrorCount = 1
        $ValidationResult.Value.Summary = "$JsonObjectName validation failed: File $JsonFilePath does not exist."
        Write-LogMessage -Type ERROR -Message $ValidationResult.Value.Summary
        return $null
    }

    # Load and parse the JSON file.
    try {
        $jsonFilePathData = ConvertFrom-JsonSafely -JsonFilePath $JsonFilePath
        $ValidationResult.Value.JsonData = $jsonFilePathData
        return $jsonFilePathData
    } catch {
        $ValidationResult.Value.IsValid = $false
        $ValidationResult.Value.ErrorCount = 1
        $ValidationResult.Value.Summary = "$JsonObjectName validation failed: Unable to parse JSON file $JsonFilePath. Error: $_"
        Write-LogMessage -Type ERROR -Message $ValidationResult.Value.Summary
        return $null
    }
}
Function Test-JsonFile {

    <#
        .SYNOPSIS
        Validates JSON file existence and content with proper resource management and comprehensive error handling.

        .DESCRIPTION
        The Test-JsonFile function provides robust validation of JSON files by checking both file existence
        and JSON content validity. It uses the .NET System.Text.Json.JsonDocument class for efficient
        parsing and implements proper resource disposal to prevent memory leaks.

        Key features:
        - File existence validation with detailed error reporting
        - Strict JSON parsing using System.Text.Json.JsonDocument
        - Proper resource disposal using try/finally blocks
        - Comprehensive error handling with specific exception types
        - Integration with the script's logging system
        - Performance optimized for large JSON files

        The function will return $true if the file exists and contains valid JSON, $false otherwise.
        All errors are logged using the Write-LogMessage system for consistent error reporting.

        .EXAMPLE
        Test-JsonFile -JsonFilePath "./config/settings.json"
        Returns $true if the file exists and contains valid JSON, $false otherwise.

        .EXAMPLE
        if (Test-JsonFile -JsonFilePath $configPath) {
            Write-LogMessage -Type INFO -Message "Configuration file is valid"
            $config = Get-Content $configPath | ConvertFrom-Json
        }

        .PARAMETER JsonFilePath
        The absolute path to the JSON file to be validated. This parameter is mandatory and must
        point to an existing file. The path can be either a local file path or a UNC path.

        .OUTPUTS
        System.Boolean
        Returns $true if the file exists and contains valid JSON content, $false otherwise.

        .NOTES
        - Uses System.Text.Json.JsonDocument for efficient JSON validation
        - Implements proper resource disposal to prevent memory leaks
        - All validation errors are logged using Write-LogMessage
        - Function is optimized for performance with large JSON files
        - Requires PowerShell 7.4 or later (same as the module manifest).
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateScript({ if ([string]::IsNullOrWhiteSpace($_)) { throw "JSON file path cannot be null, empty, or contain only whitespace characters." }; if ($_.Length -gt 260) { throw "JSON file path cannot exceed 260 characters. Current length: $($_.Length)" }; if ($_ -match '[<>"|?*]') { throw "JSON file path contains invalid characters: $($matches[0])" }; return $true })] [ValidateNotNullOrEmpty()] [String]$JsonFilePath
    )

    Write-LogMessage -Type DEBUG -Message "Entered Test-JsonFile function..."

    # Validate file existence first.
    if (-not (Test-Path -Path $JsonFilePath -PathType Leaf)) {
        Write-LogMessage -Type ERROR -Message "JSON file not found: `"$JsonFilePath`""
        return $false
    }

    # Validate file is actually a file (not a directory)
    $fileInfo = Get-Item -Path $JsonFilePath -ErrorAction SilentlyContinue
    if ($fileInfo -and $fileInfo.PSIsContainer) {
        Write-LogMessage -Type ERROR -Message "Specified path is a directory, not a file: `"$JsonFilePath`""
        return $false
    }

    # Check if file is readable.
    try {
        $null = Get-Content -Path $JsonFilePath -TotalCount 1 -ErrorAction Stop
    } catch [System.UnauthorizedAccessException] {
        Write-LogMessage -Type ERROR -Message "Access denied reading JSON file: `"$JsonFilePath`". Please check file permissions."
        return $false
    } catch [System.IO.IOException] {
        Write-LogMessage -Type ERROR -Message "I/O error reading JSON file: `"$JsonFilePath`". File may be locked or corrupted."
        return $false
    } catch {
        Write-LogMessage -Type ERROR -Message "Unexpected error reading JSON file: `"$JsonFilePath`": $($_.Exception.Message)"
        return $false
    }

    # Validate JSON content.
    $jsonFilePathDocument = $null
    try {
        Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Validating JSON content in file: `"$JsonFilePath`""

        # Read file content
        $content = Get-Content -Path $JsonFilePath -Raw -ErrorAction Stop

        # Check for empty file.

        if ([string]::IsNullOrWhiteSpace($content)) {
            Write-LogMessage -Type ERROR -Message "JSON file is empty or contains only whitespace: `"$JsonFilePath`""
            return $false
        }

        # Load and validate JSON using System.Text.Json for strict parsing.

        Add-Type -AssemblyName System.Text.Json -ErrorAction Stop

        # Parse JSON with strict validation.

        $jsonFilePathDocument = [System.Text.Json.JsonDocument]::Parse($content)

        # If we reach here, JSON is valid.

        Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "JSON file validation successful: `"$JsonFilePath`""
        return $true

    } catch [System.Text.Json.JsonException] {
        # Handle JSON parsing errors specifically.

        Write-LogMessage -Type ERROR -Message "Invalid JSON format in file: `"$JsonFilePath`""
        Write-LogMessage -Type ERROR -Message "JSON parsing error: $($_.Exception.Message)"
        return $false
    } catch [System.ArgumentException] {
        # Handle argument exceptions (e.g., invalid UTF-8 encoding)
        Write-LogMessage -Type ERROR -Message "Invalid content encoding in JSON file: `"$JsonFilePath`""
        Write-LogMessage -Type ERROR -Message "Encoding error: $($_.Exception.Message)"
        return $false
    } catch [System.IO.FileNotFoundException] {
        # Handle case where file was deleted between existence check and read.

        Write-LogMessage -Type ERROR -Message "JSON file was deleted during validation: `"$JsonFilePath`""
        return $false
    } catch [System.OutOfMemoryException] {
        # Handle very large files that exceed memory limits.

        Write-LogMessage -Type ERROR -Message "JSON file too large to process: `"$JsonFilePath`". File may exceed available memory."
        return $false
    } catch {
        # Handle any other unexpected exceptions.

        Write-LogMessage -Type ERROR -Message "Unexpected error during JSON validation for file: `"$JsonFilePath`""
        Write-LogMessage -Type ERROR -Message "Error details: $($_.Exception.Message)"
        return $false
    } finally {
        # Ensure proper resource disposal.

        if ($jsonFilePathDocument) {
            try {
                $jsonFilePathDocument.Dispose()
                Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "JSON document resources properly disposed for: `"$JsonFilePath`""
            } catch {
                Write-LogMessage -Type WARNING -SuppressOutputToScreen -Message "Warning: Could not dispose JSON document resources for: `"$JsonFilePath`": $($_.Exception.Message)"
            }
        }
    }
}
Function ConvertFrom-JsonSafely {

    <#
        .SYNOPSIS
        Safely loads and validates JSON content from a file with comprehensive error handling.

        .DESCRIPTION
        The ConvertFrom-JsonSafely function provides a robust way to load JSON files with
        built-in validation and error handling. The function reads the file content, removes
        empty lines that could cause JSON parsing issues, and converts the content to a
        PowerShell object. If JSON validation fails, the function logs detailed error
        information including the file path and specific parsing error, then throws so the caller can handle the error and prevent further execution with invalid data.

        This function standardizes JSON loading across the VCF PowerShell Toolbox and
        ensures consistent error reporting for troubleshooting.

        .PARAMETER JsonFilePath
        The full path to the JSON file to load and parse. The file must exist and
        contain valid JSON content.

        .EXAMPLE
        $config = ConvertFrom-JsonSafely -JsonFilePath "./configs/settings.json"
        Loads application settings from a JSON file with error handling.

        .NOTES
        This function throws if JSON parsing fails so the caller can handle the error.
        Empty lines are automatically filtered out before JSON parsing to handle
        files that may have formatting issues.
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$JsonFilePath
    )

    Write-LogMessage -Type DEBUG -Message "Entered ConvertFrom-JsonSafely function..."

    try {
        # Read file content, filter out empty lines, and convert from JSON.

        # Read the file as a single string and strip blank lines before JSON parsing.
        # Using -Raw avoids building a per-line array; the regex removes blank lines that ConvertFrom-Json cannot handle.
        $rawContent = Get-Content -Path $JsonFilePath -Raw -Encoding UTF8 -ErrorAction Stop
        $cleanedContent = $rawContent -replace '(?m)^\s*$\n', ''
        return $cleanedContent | ConvertFrom-Json -ErrorVariable ErrorMessage

    } catch {
        # Handle JSON parsing errors with detailed, user-friendly logging.
        $errorMessage = $_.Exception.Message

        Write-LogMessage -Type ERROR -Message "JSON validation failed for file: $JsonFilePath."

        switch -Regex ($errorMessage) {
            "Bad JSON escape sequence: \\([A-Za-z])\..*'([^']+)'.*line (\d+).*position (\d+)" {
                $badChar = $Matches[1]
                $jsonFilePathPath = $Matches[2]
                $lineNum = $Matches[3]
                $position = $Matches[4]
                Write-LogMessage -Type ERROR -Message "Invalid escape sequence: `"\$badChar`" in JSON property `"$jsonFilePathPath`""
                Write-LogMessage -Type ERROR -Message "Location: Line $lineNum, Position $position"
                Write-LogMessage -Type ERROR -Message "Common causes:"
                Write-LogMessage -Type ERROR -Message "  1. Windows file paths must use forward slashes (/) or escaped backslashes (\\\\)"
                Write-LogMessage -Type ERROR -Message "     Example: `"C:/Users/Admin/file.yml`" or `"C:\\\\Users\\\\Admin\\\\file.yml`""
                Write-LogMessage -Type ERROR -Message "  2. Backslash (\) is a special character in JSON and must be escaped"
                Write-LogMessage -Type ERROR -Message "Please correct the JSON syntax in `"$JsonFilePath`" at line $lineNum and try again."
                break
            }
            "Conversion from JSON failed with error: (.+?)\. Path '([^']+)'.*line (\d+).*position (\d+)" {
                $jsonFilePathError = $Matches[1]
                $jsonFilePathPath = $Matches[2]
                $lineNum = $Matches[3]
                $position = $Matches[4]
                Write-LogMessage -Type ERROR -Message "JSON parsing error: $jsonFilePathError."
                Write-LogMessage -Type ERROR -Message "Property: `"$jsonFilePathPath`""
                Write-LogMessage -Type ERROR -Message "Location: Line $lineNum, Position $position"
                Write-LogMessage -Type ERROR -Message "Please correct the JSON syntax in `"$JsonFilePath`" and try again."
                break
            }
            default {
                # Do not append a period — exception messages may already end with one.
                Write-LogMessage -Type ERROR -Message "JSON parsing error: $errorMessage"
            }
        }

        Write-LogMessage -Type ERROR -Message "JSON validation failed for `"$JsonFilePath`": $errorMessage"
        throw [VcfDeploymentException]::new("JSON validation failed for `"$JsonFilePath`": $errorMessage")
    }
}
Function Test-CommandAvailability {

    <#
        .SYNOPSIS
        Tests if a specified command/utility is available in the system PATH.

        .DESCRIPTION
        This function checks whether a given command or executable is available and accessible
        through the system PATH. It can be used to verify that required tools or utilities
        are installed before attempting to use them in the script. If the command is not found,
        the function logs an error and throws a terminating error.

        .EXAMPLE
        Test-CommandAvailability -Command $Script:VcfCmd -Description "vcf-cli"

        .PARAMETER Command
        The name of the command or executable to test for availability

        .PARAMETER Description
        A human-readable description of the command for use in error messages
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Command,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Description
    )

    Write-LogMessage -Type DEBUG -Message "Entered Test-CommandAvailability function..."

    if (Get-Command $Command -ErrorAction SilentlyContinue) {
        Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Executable $Command found in PATH. Proceeding."
    } else {
        Write-LogMessage -Type ERROR -Message "Executable `"$Command`" not found in PATH.  $Description is required for the script to proceed. Exiting"
        throw [VcfDeploymentException]::new("Executable `"$Command`" not found in PATH.  $Description is required for the script to proceed. Exiting")
    }
}
Function Test-Filepath {

    <#
        .SYNOPSIS
        Tests if a specified file exists at the given file path.

        .DESCRIPTION
        The function Test-Filepath validates whether a file exists at the specified path.
        If the file exists, it logs a success message. If the file does not exist,
        it logs an error message and throws a terminating error.

        .EXAMPLE
        Test-Filepath -FilePath "./argocd.yml" -Description "ArgoCD configuration"

        .PARAMETER FilePath
        The absolute path to the file that needs to be validated for existence.

        .PARAMETER Description
        A descriptive name for the file being tested, used in log messages.

    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$FilePath,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Description
    )

    Write-LogMessage -Type DEBUG -Message "Entered Test-Filepath function..."

    if (Test-Path -Path $FilePath -PathType Leaf) {
        Write-LogMessage -Type INFO -Message "Found the `"$Description`" file on disk: `"$FilePath`"."
    } else {
        Write-LogMessage -Type ERROR -Message "Failed to find `"$Description`" file on disk: `"$FilePath`" not found. Exiting."
        throw [VcfDeploymentException]::new("Failed to find `"$Description`" file on disk: `"$FilePath`" not found. Exiting.")
    }
}
Function Test-JsonMissingProperties {

    <#
        .SYNOPSIS
        Validates JSON file content for missing required properties with support for nested properties.

        .DESCRIPTION
        The Test-JsonMissingProperties function provides comprehensive validation of JSON files
        to ensure all required properties are present. It supports nested property validation
        using dot notation (e.g., "common.vCenter.name") and provides detailed reporting of
        missing properties with their expected structure.

        This function is particularly useful for validating configuration files, API payloads,
        or any JSON data that must conform to a specific schema. It integrates with the VCF
        PowerShell Toolbox logging infrastructure for consistent error reporting.

        .PARAMETER JsonFilePath
        The full path to the JSON file to validate. The file must exist and contain valid JSON content.

        .PARAMETER RequiredProperties
        An array of property names (using dot notation for nested properties) that must be present
        in the JSON object. Examples: "name", "config.database.host", "settings.security.enabled"

        .PARAMETER JsonObjectName
        A descriptive name for the JSON object being validated, used in error messages and
        logging to help identify the source of validation failures.

        .PARAMETER StopOnFirstError
        When specified, the function will stop validation and return immediately upon
        finding the first missing property, rather than validating all properties.

        .PARAMETER ShowExpectedStructure
        When specified, the function will include the expected JSON structure for missing
        properties in the validation results, helpful for troubleshooting and documentation.

        .OUTPUTS
        System.Management.Automation.PSCustomObject
        Returns an object with the following properties:
        - IsValid: Boolean indicating if all validations passed
        - MissingProperties: Array of missing property paths
        - ExpectedStructure: Suggested JSON structure for missing properties (if ShowExpectedStructure is used)
        - ErrorCount: Total number of missing properties
        - Summary: Human-readable summary of validation results
        - JsonData: The loaded JSON object (if validation passes)

        .EXAMPLE
        $validationResult = Test-JsonMissingProperties -JsonFilePath "config.json" -RequiredProperties @("database.host", "database.port", "api.key") -JsonObjectName "Configuration"

        if (-not $validationResult.IsValid) {
            Write-LogMessage -Type ERROR -Message "Validation failed: $($validationResult.Summary)"
            return
        }
        $config = $validationResult.JsonData

        .EXAMPLE
        $requiredProps = @(
            "common.vCenterName",
            "common.VcenterUser",
            "common.esxHost",
            "common.argoCD.argoCdOperatorYamlPath",
            "common.datastore.lunId"
        )
        $result = Test-JsonMissingProperties -JsonFilePath "infrastructure.json" -RequiredProperties $requiredProps -JsonObjectName "InputConfiguration" -ShowExpectedStructure

        .NOTES
        This function uses the existing ConvertFrom-JsonSafely function for safe JSON loading
        and integrates with the VCF PowerShell Toolbox logging infrastructure. Nested properties
        are accessed using dot notation, and the function provides detailed error reporting
        for missing properties at any depth in the JSON structure.
    #>

    Param (
        [Parameter(Mandatory = $false)] [Switch]$StopOnFirstError,
        [Parameter(Mandatory = $false)] [Switch]$ShowExpectedStructure,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$JsonFilePath,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String[]]$RequiredProperties,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$JsonObjectName
    )

    Write-LogMessage -Type DEBUG -Message "Entered Test-JsonMissingProperties function..."

    # Initialize validation result object.
    $validationResult = [PSCustomObject]@{
        IsValid = $true
        MissingProperties = @()
        ExpectedStructure = @{}
        ErrorCount = 0
        Summary = ""
        JsonData = $null
    }

    Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Validating $($RequiredProperties.Count) required properties: $($RequiredProperties -join ', ')"

    # Load and validate the JSON file using helper function.
    $jsonFilePathData = Get-JsonDataWithValidation -JsonFilePath $JsonFilePath -JsonObjectName $JsonObjectName -ValidationResult ([ref]$validationResult)
    if ($null -eq $jsonFilePathData) {
        return $validationResult
    }

    # Helper function to check if a nested property exists using dot notation.
    Function Test-NestedProperty {
        <#
            .SYNOPSIS
            Tests whether a nested property exists in an object using dot notation path.

            .DESCRIPTION
            This function traverses a nested object structure to verify if a property path exists.
            It supports both PowerShell custom objects (PSObject) and hashtables, following
            a dot-separated property path (e.g., "config.database.host") to determine if the
            entire path is valid and accessible.

            The function performs deep traversal of the object hierarchy, checking each level
            of the specified path. It handles different object types:
            - Hashtables: Uses ContainsKey() method to check for property existence
            - PSObjects: Uses PSObject.Properties collection to verify property existence

            This is particularly useful for validating JSON configuration objects or
            complex nested data structures before attempting to access their properties.

            .PARAMETER Object
            The root object to search within. Can be a PowerShell custom object, hashtable,
            or any object that supports property access.

            .PARAMETER PropertyPath
            A string representing the property path using dot notation (e.g., "level1.level2.property").
            Each segment separated by dots represents a nested level in the object hierarchy.

            .EXAMPLE
            Test-NestedProperty -Object $JsonFilePathConfig -PropertyPath "database.connection.host"

            Tests if the $JsonFilePathConfig object contains the nested property path database.connection.host.
            Returns $true if the entire path exists, $false otherwise.

            .EXAMPLE
            $config = @{
                server = @{
                    network = @{
                        port = 8080
                    }
                }
            }
            Test-NestedProperty -Object $config -propertyPath "server.network.port"

            Returns $true because the complete path exists in the hashtable structure.

            .EXAMPLE
            Test-NestedProperty -Object $config -propertyPath "server.network.timeout"

            Returns $false if the 'timeout' property doesn't exist under server.network.

            .OUTPUTS
            System.Boolean
            Returns $true if the complete property path exists, $false if any part of the path is missing.

            .NOTES
            - The function performs case-sensitive property matching
            - Works with mixed object types (hashtables and PSObjects) in the same hierarchy
            - Stops traversal and returns $false as soon as any part of the path is not found
            - Does not throw exceptions for missing properties, always returns a boolean result
        #>

        param($Object, $PropertyPath)

        # Split the property path into individual segments using dot as delimiter.
        $properties = $PropertyPath -split '\.'
        # Start traversal from the root object.
        $currentObject = $Object

        # Iterate through each property segment in the path.
        for ($propertyIndex = 0; $propertyIndex -lt $properties.Count; $propertyIndex++) {
            $Property = $properties[$propertyIndex]
            $isArrayNotation = $Property -match '^(.+)\[\]$'

            if ($isArrayNotation) {
                # Handle array notation (e.g., "clusters[]").
                $arrayPropertyName = $matches[1]

                # Check if the array property exists.
                $arrayExists = $false
                if ($currentObject -is [System.Collections.Hashtable]) {
                    $arrayExists = $currentObject.ContainsKey($arrayPropertyName)
                    if ($arrayExists) {
                        $arrayObject = $currentObject[$arrayPropertyName]
                    }
                }
                elseif ($currentObject.PSObject.Properties[$arrayPropertyName]) {
                    $arrayExists = $true
                    $arrayObject = $currentObject.$arrayPropertyName
                }

                if (-not $arrayExists) {
                    return $false
                }

                # Check if it's actually an array.
                if ($arrayObject -isnot [Array] -and $arrayObject -isnot [System.Collections.ArrayList]) {
                    return $false
                }

                # If this is the last property in the path, just check that the array exists and has at least one element.
                if ($propertyIndex -eq ($properties.Count - 1)) {
                    return ($arrayObject.Count -gt 0)
                }

                # For array notation, recursively check if at least one element in the array has the remaining path.
                $remainingPath = $properties[($propertyIndex + 1)..($properties.Count - 1)] -join '.'
                $foundInAnyElement = $false

                foreach ($element in $arrayObject) {
                    if (Test-NestedProperty -Object $element -PropertyPath $remainingPath) {
                        $foundInAnyElement = $true
                        break
                    }
                }

                if (-not $foundInAnyElement) {
                    return $false
                }

                # Array notation validation complete - the remaining path was validated recursively.
                return $true
            }
            else {
                # Handle regular property access (non-array).
                if ($currentObject -is [System.Collections.Hashtable]) {
                    if (-not $currentObject.ContainsKey($Property)) {
                        return $false
                    }
                    # Move to the next level in the hierarchy.
                    $currentObject = $currentObject[$Property]
                }
                # Handle PowerShell custom objects - check PSObject.Properties collection.
                elseif ($currentObject.PSObject.Properties[$Property]) {
                    # Move to the next level in the hierarchy.
                    $currentObject = $currentObject.$Property
                }
                # Property doesn't exist in current object - path is invalid.
                else {
                    return $false
                }
            }
        }

        # Successfully traversed the entire path.
        return $true
    }

    # Helper function to generate expected JSON structure for missing properties.
Function Get-ExpectedStructure {

        <#
            .SYNOPSIS
            Generates a nested JSON structure template for a missing property path.

            .DESCRIPTION
            This helper function creates a hierarchical hashtable structure that represents
            the expected JSON format for a missing property specified using dot notation.
            It builds nested objects for each level in the property path and adds a
            placeholder value for the final property.

            The function is used internally by Test-JsonMissingProperties to provide
            users with concrete examples of what structure their JSON should have
            when properties are missing.

            .PARAMETER PropertyPath
            A string representing the property path using dot notation (e.g., "config.database.host").
            Each segment separated by dots becomes a nested level in the resulting structure.

            .EXAMPLE
            Get-ExpectedStructure -PropertyPath "config.database.host"

            Returns:
            @{
                config = @{
                    database = @{
                        host = "<value>"
                    }
                }
            }

            .EXAMPLE
            Get-ExpectedStructure -PropertyPath "name"

            Returns:
            @{
                name = "<value>"
            }

            .OUTPUTS
            System.Collections.Hashtable
            Returns a nested hashtable representing the expected JSON structure with
            placeholder values ("<value>") for the final property in the path.

            .NOTES
            - This is an internal helper function within Test-JsonMissingProperties
            - The placeholder value "<value>" indicates where actual data should be provided
            - The structure can be converted to JSON for display purposes
            - Supports unlimited nesting depth based on the property path provided
        #>

        Param (
            [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$PropertyPath
        )

    Write-LogMessage -Type DEBUG -Message "Entered Get-ExpectedStructure function..."

        # Split the property path into individual property names.
        $properties = $PropertyPath -split '\.'

        # Initialize the root structure as an empty hashtable.
        $structure = @{}

        # Keep a reference to the current level for building nested structure.
        $currentLevel = $structure

        # Build the nested structure by iterating through each property in the path.
        for ($propertyIndex = 0; $propertyIndex -lt $properties.Count; $propertyIndex++) {
            $property = $properties[$propertyIndex]
            $isArrayNotation = $property -match '^(.+)\[\]$'

            if ($isArrayNotation) {
                # Handle array notation (e.g., "clusters[]").
                $arrayPropertyName = $matches[1]

                # Create an array with one element containing the nested structure.
                $arrayElement = @{}
                $currentLevel[$arrayPropertyName] = @($arrayElement)
                $currentLevel = $arrayElement

                # If this is the last property, the array itself is what's required.
                if ($propertyIndex -eq ($properties.Count - 1)) {
                    # Array exists, validation passes if array has elements.
                    return $structure
                }
            }
            else {
                if ($propertyIndex -eq ($properties.Count - 1)) {
                    # Last property in the path - add placeholder value to indicate expected data.
                    $currentLevel[$property] = "<value>"
                }
                else {
                    # Intermediate property - create nested hashtable and move reference deeper.
                    $currentLevel[$property] = @{}
                    $currentLevel = $currentLevel[$property]
                }
            }
        }

        # Return the complete nested structure.
        return $structure
    }

    # Validate each required property.
    foreach ($property in $RequiredProperties) {
        $propertyExists = Test-NestedProperty -Object $JsonFilePathData -PropertyPath $property

        if (-not $propertyExists) {
            $validationResult.IsValid = $false
            $validationResult.MissingProperties += $property
            $validationResult.ErrorCount++

            Write-LogMessage -Type ERROR -Message "$JsonObjectName (in JSON file $JsonFilePath) is missing required property: $property"

            # Generate expected structure if requested.

            if ($ShowExpectedStructure) {
                $expectedStructure = Get-ExpectedStructure -PropertyPath $property
                $validationResult.ExpectedStructure[$property] = $expectedStructure
            }

            # Stop on first error if requested.
            if ($StopOnFirstError) {
                break
            }
        }
    }

    # Generate summary message.
    if ($validationResult.IsValid) {
        $validationResult.Summary = "$JsonObjectName validation passed. All $($RequiredProperties.Count) required properties are present."
        Write-LogMessage -Type INFO -Message $validationResult.Summary -SuppressOutputToScreen
    }
    else {
        $validationResult.Summary = "$JsonObjectName validation failed. $($validationResult.ErrorCount) of $($RequiredProperties.Count) required properties are missing: $($validationResult.MissingProperties -join ', ')"
        Write-LogMessage -Type ERROR -Message $validationResult.Summary

        # Log expected structure if available.

        if ($ShowExpectedStructure -and $validationResult.ExpectedStructure.Count -gt 0) {
            Write-LogMessage -Type INFO -Message "Expected JSON structure for missing properties:"
            foreach ($missingProp in $validationResult.MissingProperties) {
                $structureJson = $validationResult.ExpectedStructure[$missingProp] | ConvertTo-Json -Depth 10
                Write-LogMessage -Type INFO -Message "Property `"$missingProp`" expected structure: $structureJson"
            }
        }
    }

    return $validationResult
}
Function Test-JsonNullValues {

    <#
        .SYNOPSIS
        Validates that specified JSON properties are not null.

        .DESCRIPTION
        The Test-JsonNullValues function checks whether specified properties in a JSON file
        contain null values. This is a complementary validation to Test-JsonMissingProperties,
        which only checks if keys exist. This function ensures that existing keys also have
        non-null values.

        This validation is critical because PowerShell's JSON parsing will include properties
        with null values in the object structure, making them technically "present" but unusable.
        Configuration files must have actual values, not nulls, for deployment to succeed.

        .PARAMETER JsonFilePath
        The full path to the JSON file to validate. The file must exist and contain valid JSON content.

        .PARAMETER RequiredProperties
        An array of property names (using dot notation for nested properties) that must have
        non-null values. Examples: "name", "config.database.host", "settings.security.enabled"

        .PARAMETER JsonObjectName
        A descriptive name for the JSON object being validated, used in error messages and
        logging to help identify the source of validation failures.

        .PARAMETER StopOnFirstError
        When specified, the function will stop validation and return immediately upon
        finding the first null value, rather than validating all properties.

        .OUTPUTS
        System.Management.Automation.PSCustomObject
        Returns an object with the following properties:
        - IsValid: Boolean indicating if all validations passed (no null values found)
        - NullProperties: Array of property paths that contain null values
        - ErrorCount: Total number of properties with null values
        - Summary: Human-readable summary of validation results
        - JsonData: The loaded JSON object (if validation passes)

        .EXAMPLE
        $validationResult = Test-JsonNullValues -JsonFilePath "config.json" -RequiredProperties @("database.host", "database.port", "api.key") -JsonObjectName "Configuration"

        if (-not $validationResult.IsValid) {
            Write-LogMessage -Type ERROR -Message "Validation failed: $($validationResult.Summary)"
            return
        }

        .EXAMPLE
        $requiredProps = @(
            "common.vCenterName",
            "common.VcenterUser",
            "common.esxHost"
        )
        $result = Test-JsonNullValues -JsonFilePath "infrastructure.json" -RequiredProperties $requiredProps -JsonObjectName "InputConfiguration"

        .NOTES
        - This function is designed to work in conjunction with Test-JsonMissingProperties
        - First check if keys exist (Test-JsonMissingProperties), then check if values are non-null (Test-JsonNullValues)
        - Uses Get-JsonPropertyValue to retrieve nested property values
        - Integrates with VCF PowerShell Toolbox logging infrastructure
        - Null values in arrays or objects are also detected

        Error Handling: Main workflow function. Throws a terminating error on critical
        validation failures when properties contain null values.
    #>

    Param (
        [Parameter(Mandatory = $false)] [Switch]$StopOnFirstError,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$JsonFilePath,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String[]]$RequiredProperties,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$JsonObjectName
    )

    Write-LogMessage -Type DEBUG -Message "Entered Test-JsonNullValues function..."

    # Initialize validation result object.
    $validationResult = [PSCustomObject]@{
        IsValid = $true
        NullProperties = @()
        ErrorCount = 0
        Summary = ""
        JsonData = $null
    }

    Write-LogMessage -Type DEBUG -Message "Checking $($RequiredProperties.Count) properties for null values: $($RequiredProperties -join ', ')"

    # Load and validate the JSON file using helper function.
    $jsonFilePathData = Get-JsonDataWithValidation -JsonFilePath $JsonFilePath -JsonObjectName $JsonObjectName -ValidationResult ([ref]$validationResult)
    if ($null -eq $jsonFilePathData) {
        return $validationResult
    }

    # Validate each property for null values.
    foreach ($Property in $RequiredProperties) {
        # Check if this property path contains array notation.
        $hasArrayNotation = $Property -match '\[\]'

        if ($hasArrayNotation) {
            # Handle array notation - check all elements in the array.
            $arrayPathParts = $Property -split '\.'
            $arrayPropertyIndex = -1
            $arrayPropertyName = $null

            # Find the array property in the path.
            for ($partIndex = 0; $partIndex -lt $arrayPathParts.Count; $partIndex++) {
                if ($arrayPathParts[$partIndex] -match '^(.+)\[\]$') {
                    $arrayPropertyIndex = $partIndex
                    $arrayPropertyName = $matches[1]
                    break
                }
            }

            if ($arrayPropertyIndex -ge 0) {
                # Navigate to the array property.
                $currentObject = $jsonFilePathData
                for ($navIndex = 0; $navIndex -lt $arrayPropertyIndex; $navIndex++) {
                    $part = $arrayPathParts[$navIndex]
                    if ($currentObject -is [PSCustomObject]) {
                        $currentObject = $currentObject.$part
                    } elseif ($currentObject -is [Hashtable]) {
                        $currentObject = $currentObject[$part]
                    } else {
                        $currentObject = $currentObject.$part
                    }
                }

                # Get the array.
                if ($currentObject -is [PSCustomObject]) {
                    $arrayObject = $currentObject.$arrayPropertyName
                } elseif ($currentObject -is [Hashtable]) {
                    $arrayObject = $currentObject[$arrayPropertyName]
                } else {
                    $arrayObject = $currentObject.$arrayPropertyName
                }

                if ($null -eq $arrayObject -or ($arrayObject -isnot [Array] -and $arrayObject -isnot [System.Collections.ArrayList])) {
                    $validationResult.IsValid = $false
                    $validationResult.NullProperties += $Property
                    $validationResult.ErrorCount++
                    Write-LogMessage -Type ERROR -Message "$JsonObjectName (in JSON file $JsonFilePath) property `"$Property`" array `"$arrayPropertyName`" is null or not an array. Please provide a valid value."
                    if ($StopOnFirstError) {
                        break
                    }
                    continue
                }

                # Build the remaining path after the array notation.
                $remainingPathParts = $arrayPathParts[($arrayPropertyIndex + 1)..($arrayPathParts.Count - 1)]

                # Check each element in the array for null values.
                $elementIndex = 0
                foreach ($element in $arrayObject) {
                    # Use recursive helper function to check nested arrays.
                    # The function returns $true if null is found, $false if value is valid.
                    $nullFound = Test-ArrayPropertyNullValue -Object $element -PathParts $remainingPathParts -PropertyPath $Property

                    if ($nullFound) {
                        $validationResult.IsValid = $false
                        # Only add to NullProperties if not already added (to avoid duplicates)
                        if ($Property -notin $validationResult.NullProperties) {
                            $validationResult.NullProperties += $Property
                        }
                        $validationResult.ErrorCount++
                        Write-LogMessage -Type ERROR -Message "$JsonObjectName (in JSON file $JsonFilePath) property `"$Property`" has a null value at array index $elementIndex. Please provide a valid value."
                        if ($StopOnFirstError) {
                            break
                        }
                    }
                    $elementIndex++
                }

                if ($StopOnFirstError -and -not $validationResult.IsValid) {
                    break
                }
            }
        }
        else {
            # Handle regular (non-array) property validation.
            $propertyValue = Get-JsonPropertyValue -InputData $jsonFilePathData -PropertyPath $Property

            # Check if the value is null.
            if ($null -eq $propertyValue -or ($propertyValue -is [String] -and $propertyValue -eq "")) {
                $validationResult.IsValid = $false
                $validationResult.NullProperties += $Property
                $validationResult.ErrorCount++

                Write-LogMessage -Type ERROR -Message "$JsonObjectName (in JSON file $JsonFilePath) property `"$Property`" has a null value. Please provide a valid value."

                # Stop on first error if requested.
                if ($StopOnFirstError) {
                    break
                }
            }
        }
    }

    # Generate summary message.
    if ($validationResult.IsValid) {
        $validationResult.Summary = "$JsonObjectName null value validation passed. All $($RequiredProperties.Count) required properties have non-null values."
        Write-LogMessage -Type DEBUG -Message $validationResult.Summary
    }
    else {
        $validationResult.Summary = "$JsonObjectName null value validation failed. $($validationResult.ErrorCount) of $($RequiredProperties.Count) required properties have null values: $($validationResult.NullProperties -join ', ')"
        Write-LogMessage -Type ERROR -Message $validationResult.Summary
    }

    return $validationResult
}
Function Test-ArrayPropertyNullValue {
    <#
        .SYNOPSIS
        Iteratively checks for null values in nested array properties.

        .DESCRIPTION
        Helper function that iteratively navigates through object properties and arrays
        to check for null values. Handles nested array notation like clusters[].networking.networkSegments[].name.

        .PARAMETER Object
        The object to check for null values.

        .PARAMETER PathParts
        Array of path parts remaining to navigate.

        .PARAMETER PropertyPath
        The full property path for error reporting.

        .OUTPUTS
        Boolean - Returns $true if a null value is found, $false otherwise.
    #>
    Param (
        [Parameter(Mandatory = $true)] [AllowNull()] [Object]$Object,
        [Parameter(Mandatory = $true)] [Array]$PathParts,
        [Parameter(Mandatory = $true)] [String]$PropertyPath
    )

    # If no path parts remain, check if the final value is null or empty string.
    if ($PathParts.Count -eq 0) {
        # Check if the object itself is null.
        if ($null -eq $Object) {
            return $true
        }
        # For string values, also check for empty strings.
        if ($Object -is [String]) {
            return [String]::IsNullOrEmpty($Object)
        }
        # For arrays, check if empty.
        if ($Object -is [Array] -or $Object -is [System.Collections.ArrayList]) {
            return ($Object.Count -eq 0)
        }
        # For other types (objects, numbers, etc.), if not null, it's valid.
        return $false
    }

    # If object is null, we can't navigate further.
    if ($null -eq $Object) {
        return $true
    }

    # Simplified iterative approach: use recursion for arrays, iteration for regular properties
    $currentObject = $Object
    $currentPathParts = $PathParts

    while ($true) {
        # If no path parts remain, check if the final value is null or empty string.
        if ($currentPathParts.Count -eq 0) {
            if ($null -eq $currentObject) {
                return $true
            }
            if ($currentObject -is [String] -and [String]::IsNullOrEmpty($currentObject)) {
                return $true
            }
            if (($currentObject -is [Array] -or $currentObject -is [System.Collections.ArrayList]) -and $currentObject.Count -eq 0) {
                return $true
            }
            return $false
        }

        # If object is null, we can't navigate further.
        if ($null -eq $currentObject) {
            return $true
        }

        $currentPart = $currentPathParts[0]
        # Correctly handle array slicing - if only one element, remaining is empty
        if ($currentPathParts.Count -eq 1) {
            $remainingParts = @()
        } else {
            $remainingParts = $currentPathParts[1..($currentPathParts.Count - 1)]
        }
        $isArrayNotation = $currentPart -match '^(.+)\[\]$'

        if ($isArrayNotation) {
            # Handle array notation - use recursion for simplicity.
            $arrayPropertyName = $matches[1]

            # Navigate to the array property.
            $arrayObject = $null
            if ($currentObject -is [PSCustomObject]) {
                if (-not $currentObject.PSObject.Properties[$arrayPropertyName]) {
                    return $true
                }
                $arrayObject = $currentObject.$arrayPropertyName
            } elseif ($currentObject -is [Hashtable]) {
                if (-not $currentObject.ContainsKey($arrayPropertyName)) {
                    return $true
                }
                $arrayObject = $currentObject[$arrayPropertyName]
            } else {
                try {
                    $arrayObject = $currentObject.$arrayPropertyName
                } catch {
                    return $true
                }
            }

            # Check if array is null or not an array.
            if ($null -eq $arrayObject -or ($arrayObject -isnot [Array] -and $arrayObject -isnot [System.Collections.ArrayList])) {
                return $true
            }

            # Check if array is empty.
            if ($arrayObject.Count -eq 0) {
                return $true
            }

            # Recursively check each element - if any has a null, return true.
            foreach ($element in $arrayObject) {
                if (Test-ArrayPropertyNullValue -Object $element -PathParts $remainingParts -PropertyPath $PropertyPath) {
                    return $true
                }
            }

            # All elements are valid.
            return $false
        }
        else {
            # Handle regular property navigation - iterate to next property.
            $nextObject = $null
            $propertyExists = $false

            if ($currentObject -is [PSCustomObject]) {
                $prop = $currentObject.PSObject.Properties[$currentPart]
                if ($null -ne $prop) {
                    $propertyExists = $true
                    $nextObject = $currentObject.$currentPart
                }
            } elseif ($currentObject -is [Hashtable]) {
                if ($currentObject.ContainsKey($currentPart)) {
                    $propertyExists = $true
                    $nextObject = $currentObject[$currentPart]
                }
            } else {
                try {
                    $prop = $currentObject | Get-Member -Name $currentPart -ErrorAction SilentlyContinue
                    if ($null -ne $prop) {
                        $propertyExists = $true
                        $nextObject = $currentObject.$currentPart
                    }
                } catch {
                    Write-LogMessage -Type DEBUG -Message "Property access failed: $($_.Exception.Message)"
                }
            }

            if (-not $propertyExists) {
                return $true
            }

            # Move to next property in the path.
            $currentObject = $nextObject
            $currentPathParts = $remainingParts
        }
    }
}
Function Get-EdgeSitesFromParameter {

    <#
        .SYNOPSIS
        Parses the comma-delimited -EdgeSite parameter and returns validated edge site names.

        .DESCRIPTION
        Splits the -EdgeSite string by comma, trims each value, and validates that every name
        exists in the infrastructure JSON clusters array. Fails if an invalid delimiter (e.g. semicolon)
        is used or if any specified site is not defined in the infrastructure.

        .PARAMETER EdgeSite
        Comma-delimited list of edge site names (e.g. "site1,site2"). Only comma is allowed as separator.

        .PARAMETER InfrastructureJson
        Path to the infrastructure JSON file. Used to load clusters when InputData is not provided.

        .PARAMETER InputData
        Parsed infrastructure JSON object. When provided, avoids re-reading the file.

        .OUTPUTS
        String array of edge site names in the order specified. Empty array when EdgeSite is null or whitespace.

        .NOTES
        Caller must pass either InputData or InfrastructureJson when EdgeSite is specified.
    #>

    [OutputType([System.Object[]])]
    Param (
        [Parameter(Mandatory = $false)] [String]$EdgeSite,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$InfrastructureJson,
        [Parameter(Mandatory = $false)] [Object]$InputData
    )

    if ([String]::IsNullOrWhiteSpace($EdgeSite)) {
        return @()
    }

    # Reject invalid delimiters. Only comma is allowed.
    $invalidDelimiters = @(';', '|')
    foreach ($delim in $invalidDelimiters) {
        if ($EdgeSite.IndexOf($delim) -ge 0) {
            Write-LogMessage -Type ERROR -Message "Invalid delimiter in -EdgeSite. Use only comma to separate edge site names (e.g. -EdgeSite site1,site2)."
            throw [VcfDeploymentException]::new("Deployment failed. Invalid delimiter in -EdgeSite. Use only comma to separate edge site names (e.g. -EdgeSite site1,site2). Check logs for details.")
        }
    }

    $requestedSites = @($EdgeSite -split ',' | ForEach-Object { $_.Trim() } | Where-Object { -not [String]::IsNullOrWhiteSpace($_) })
    if ($requestedSites.Count -eq 0) {
        Write-LogMessage -Type ERROR -Message "No valid edge site names in -EdgeSite after splitting by comma."
        throw [VcfDeploymentException]::new("Deployment failed. No valid edge site names in -EdgeSite. Use comma to separate names (e.g. -EdgeSite site1,site2). Check logs for details.")
    }

    if (-not $InputData -and -not $InfrastructureJson) {
        Write-LogMessage -Type ERROR -Message "Get-EdgeSitesFromParameter requires InputData or InfrastructureJson when EdgeSite is specified."
        throw [VcfDeploymentException]::new("Get-EdgeSitesFromParameter requires InputData or InfrastructureJson when EdgeSite is specified.")
    }

    if (-not $InputData) {
        $InputData = ConvertFrom-JsonSafely -JsonFilePath $InfrastructureJson
    }

    $validSites = @($InputData.clusters | ForEach-Object { $_.edgeSite } | Where-Object { -not [String]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    $invalidSites = @($requestedSites | Where-Object { $_ -notin $validSites })
    if ($invalidSites.Count -gt 0) {
        $validList = if ($validSites.Count -gt 0) { $validSites -join ", " } else { "(none defined)" }
        Write-LogMessage -Type ERROR -Message "EdgeSite value(s) not defined in infrastructure JSON: $($invalidSites -join ', '). Valid edgeSite values in clusters[].edgeSite are: $validList"
        throw [VcfDeploymentException]::new("Deployment failed. Invalid -EdgeSite: $($invalidSites -join ', '). Valid values: $validList. Check logs for details.")
    }

    return $requestedSites
}
Function Get-EffectiveNicListForCluster {

    <#
        .SYNOPSIS
        Returns the effective nicList for a cluster (cluster override or common).

        .DESCRIPTION
        Cluster nicList takes precedence over common.nicList. If the cluster has nicList
        defined and it has 2 or 4 elements, that is returned; otherwise common.nicList
        is returned. Used for VDS uplink configuration and rollback.

        .PARAMETER Cluster
        Cluster object from infrastructure JSON (clusters[] element).

        .PARAMETER CommonNicList
        common.nicList from infrastructure JSON.

        .OUTPUTS
        Array of NIC config objects (2 or 4 elements). Caller must validate count separately when required.
    #>

    Param (
        [Parameter(Mandatory = $true)] [Object]$Cluster,
        [Parameter(Mandatory = $false)] [Object]$CommonNicList
    )

    $clusterNicList = $null
    if ($Cluster -and $Cluster.PSObject.Properties["nicList"] -and $null -ne $Cluster.nicList -and $Cluster.nicList -is [Array]) {
        $clusterNicList = @($Cluster.nicList)
    }
    if ($clusterNicList -and ($clusterNicList.Count -eq 2 -or $clusterNicList.Count -eq 4)) {
        return $clusterNicList
    }
    return $CommonNicList
}
Function Test-InfrastructureNicListEffective {

    <#
        .SYNOPSIS
        Validates that every cluster has an effective nicList (cluster or common) with 2 or 4 NICs.

        .DESCRIPTION
        At least one definition of nicList is mandatory per cluster: either common.nicList
        or clusters[].nicList. Cluster nicList overrides common. Effective list must have
        exactly 2 or 4 NICs (one VDS or two VDS). Throws if any cluster has no effective
        nicList or invalid count.

        .PARAMETER InputData
        Parsed infrastructure JSON object.

        .PARAMETER Clusters
        Array of cluster objects to validate (e.g. all clusters or filtered by EdgeSite).
    #>

    Param (
        [Parameter(Mandatory = $true)] [Object]$InputData,
        [Parameter(Mandatory = $true)] [Object[]]$Clusters
    )

    $commonNicList = $null
    if ($InputData.common -and $InputData.common.PSObject.Properties["nicList"] -and $null -ne $InputData.common.nicList -and $InputData.common.nicList -is [Array]) {
        $commonNicList = @($InputData.common.nicList)
    }

    foreach ($cluster in $Clusters) {
        $effective = Get-EffectiveNicListForCluster -Cluster $cluster -CommonNicList $commonNicList
        $edgeSite = if ($cluster.edgeSite) { $cluster.edgeSite } else { "(unknown)" }
        if (-not $effective -or $effective -isnot [Array] -or $effective.Count -eq 0) {
            Write-LogMessage -Type ERROR -Message "Cluster edgeSite `"$edgeSite`": nicList must be defined at common or at cluster level. Define common.nicList or clusters[].nicList with 2 or 4 NICs."
            throw [VcfDeploymentException]::new("Deployment failed. Cluster `"$edgeSite`" has no effective nicList. Define common.nicList or clusters[].nicList (2 or 4 NICs). Check logs for details.")
        }
        if ($effective.Count -ne 2 -and $effective.Count -ne 4) {
            Write-LogMessage -Type ERROR -Message "Cluster edgeSite `"$edgeSite`": effective nicList must contain exactly 2 or 4 NICs. Found $($effective.Count)."
            throw [VcfDeploymentException]::new("Deployment failed. Cluster `"$edgeSite`" effective nicList must have 2 or 4 NICs (found $($effective.Count)). Check logs for details.")
        }
    }
}
Function Test-EdgeSiteMatching {

    <#
        .SYNOPSIS
        Validates that all edgeSite values in infrastructure JSON have matching entries in supervisor JSON.

        .DESCRIPTION
        This function validates that every edgeSite value in the infrastructure JSON clusters array
        has a corresponding entry in the supervisor JSON siteSpec array, and vice versa.
        This ensures proper linking between infrastructure and supervisor configurations.

        .PARAMETER InfrastructureJson
        Full path to the infrastructure JSON configuration file.

        .PARAMETER SupervisorJson
        Full path to the supervisor JSON configuration file.

        .OUTPUTS
        PSCustomObject with the following properties:
        - IsValid: Boolean indicating if all edgeSite values match
        - ErrorMessage: String containing details about any validation failures

        .EXAMPLE
        $result = Test-EdgeSiteMatching -InfrastructureJson "infrastructure.json" -SupervisorJson "supervisor.json"
        if (-not $result.IsValid) {
            Write-Error $result.ErrorMessage
        }
    #>

    Param (
        [Parameter(Mandatory = $false)] [String]$EdgeSite,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$InfrastructureJson,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorJson
    )

    Write-LogMessage -Type DEBUG -Message "Entered Test-EdgeSiteMatching function..."

    $validationResult = @{
        IsValid = $true
        ErrorMessage = ""
    }

    try {
        $infrastructureData = ConvertFrom-JsonSafely -JsonFilePath $InfrastructureJson
        $supervisorData = ConvertFrom-JsonSafely -JsonFilePath $SupervisorJson

        # Collect edgeSite values from infrastructure JSON.
        $infrastructureEdgeSites = @()
        if ($infrastructureData.clusters) {
            foreach ($cluster in $infrastructureData.clusters) {
                if ($cluster.edgeSite) {
                    # If EdgeSite is specified, only include matching clusters.
                    if (-not $EdgeSite -or $cluster.edgeSite -eq $EdgeSite) {
                        $infrastructureEdgeSites += $cluster.edgeSite
                    }
                }
            }
        }

        # Collect edgeSite values from supervisor JSON.
        $supervisorEdgeSites = @()
        if ($supervisorData.siteSpec) {
            foreach ($siteSpec in $supervisorData.siteSpec) {
                if ($siteSpec.edgeSite) {
                    # If EdgeSite is specified, only include matching site specs.
                    if (-not $EdgeSite -or $siteSpec.edgeSite -eq $EdgeSite) {
                        $supervisorEdgeSites += $siteSpec.edgeSite
                    }
                }
            }
        }

        # Check for duplicates within each JSON file.
        $infrastructureDuplicates = $infrastructureEdgeSites | Group-Object | Where-Object { $_.Count -gt 1 }
        if ($infrastructureDuplicates) {
            $duplicateSites = $infrastructureDuplicates | ForEach-Object { $_.Name }
            $validationResult.IsValid = $false
            $validationResult.ErrorMessage = "Duplicate edgeSite values found in infrastructure JSON: $($duplicateSites -join ', ')"
            Write-LogMessage -Type ERROR -Message $validationResult.ErrorMessage
            return $validationResult
        }

        $supervisorDuplicates = $supervisorEdgeSites | Group-Object | Where-Object { $_.Count -gt 1 }
        if ($supervisorDuplicates) {
            $duplicateSites = $supervisorDuplicates | ForEach-Object { $_.Name }
            $validationResult.IsValid = $false
            $validationResult.ErrorMessage = "Duplicate edgeSite values found in supervisor JSON: $($duplicateSites -join ', ')"
            Write-LogMessage -Type ERROR -Message $validationResult.ErrorMessage
            return $validationResult
        }

        # Check that all infrastructure edgeSites have matching supervisor entries.
        $missingInSupervisor = @()
        foreach ($edgeSite in $infrastructureEdgeSites) {
            if ($edgeSite -notin $supervisorEdgeSites) {
                $missingInSupervisor += $edgeSite
            }
        }

        if ($missingInSupervisor.Count -gt 0) {
            $validationResult.IsValid = $false
            $validationResult.ErrorMessage = "EdgeSite values in infrastructure JSON without matching supervisor entries: $($missingInSupervisor -join ', ')"
            Write-LogMessage -Type ERROR -Message $validationResult.ErrorMessage
            return $validationResult
        }

        # Check that all supervisor edgeSites have matching infrastructure entries.
        $missingInInfrastructure = @()
        foreach ($edgeSite in $supervisorEdgeSites) {
            if ($edgeSite -notin $infrastructureEdgeSites) {
                $missingInInfrastructure += $edgeSite
            }
        }

        if ($missingInInfrastructure.Count -gt 0) {
            $validationResult.IsValid = $false
            $validationResult.ErrorMessage = "EdgeSite values in supervisor JSON without matching infrastructure entries: $($missingInInfrastructure -join ', ')"
            Write-LogMessage -Type ERROR -Message $validationResult.ErrorMessage
            return $validationResult
        }

        Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "EdgeSite matching validation passed. All edgeSite values match between infrastructure and supervisor JSONs."
    } catch {
        $validationResult.IsValid = $false
        $validationResult.ErrorMessage = "Error during edgeSite matching validation: $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -Message $validationResult.ErrorMessage
    }

    return $validationResult
}
Function Test-JsonShallowValidation {

    <#
        .SYNOPSIS
        Validates infrastructure.json and supervisor.json configuration files to ensure all required properties are present and non-null.

        .DESCRIPTION
        Performs two-phase shallow validation of the two JSON configuration files used by this module:
        1. infrastructure.json — vCenter, ESX host, storage, and networking details.
        2. supervisor.json — supervisor components, load balancer, and network specifications.

        Validation phases:
        - Test-JsonMissingProperties: checks that all required keys exist in the JSON structure.
        - Test-JsonNullValues: checks that all required keys have non-null values.

        Both phases must pass for deployment to proceed. Any failure throws a terminating error.

        .EXAMPLE
        Test-JsonShallowValidation -InfrastructureJson "./config/infrastructure.json" -SupervisorJson "./config/supervisor.json"

        Validates both configuration files before deployment.

        .EXAMPLE
        Test-JsonShallowValidation -InfrastructureJson $InfrastructureJson -SupervisorJson $SupervisorJson

        Called during the initialization phase to validate configuration files before proceeding with deployment.

        .PARAMETER ComputeOnly
        When set, skips supervisor.json checks and infrastructure/supervisor edgeSite pairing, and does not require common.contextName.

        .PARAMETER EdgeSite
        When set, scopes cluster-derived checks (for example supervisor service requirements and nicList) to the listed edge sites.

        .PARAMETER InfrastructureJson
        Full path to infrastructure.json. Must contain all required infrastructure configuration properties including
        vCenter details, ESX host information, storage configuration, and networking. Must be valid JSON.

        .PARAMETER SupervisorJson
        Full path to supervisor.json. Must contain all required supervisor cluster configuration properties including
        supervisor specifications, foundation load balancer components, and network configurations. Ignored when
        -ComputeOnly is set. Must be valid JSON.

        .NOTES
        - When every cluster in scope has both supervisorServices.disableArgoCD and supervisorServices.disableHarbor
          set to true, common.contextName is omitted from the required infrastructure property list (the VCF CLI
          context is not used when all supervisor services are disabled).
        - supervisor.json is not read when -ComputeOnly is set.
        - Performs two-phase validation: missing-key check then null-value check.
        - Throws a terminating error if any validation phase fails.
        - Validation includes deep property path checking using dot notation (e.g. "siteSpec[].mgmtNetworkSpec.mgmtNetworkName").
        - Missing properties are reported with expected structure detail for troubleshooting.
        - Null values are reported with clear error messages indicating which properties need values.

        Validation order:
        1. Parse and scope infrastructure.json; resolve edge-site filter.
        2. Validate supervisor.json for missing properties (skipped with -ComputeOnly).
        3. Validate infrastructure.json for missing properties.
        4. Validate supervisor.json for null values (skipped with -ComputeOnly).
        5. Validate infrastructure.json for null values.
        6. Validate edgeSite matching between the two files (skipped with -ComputeOnly).
        7. Validate nicList, esxHosts format, boolean flags, and service YAML paths.
    #>

    # Define required properties for input.json validation.
    # This array contains all mandatory property paths that must exist in the input.json configuration file.
    # Properties are organized by functional areas: ArgoCD, Infrastructure, Storage, Content Library, and Networking.

    Param (
        [Parameter(Mandatory = $false)] [Switch]$ComputeOnly,
        [Parameter(Mandatory = $false)] [String]$EdgeSite,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$InfrastructureJson,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorJson
    )

    Write-LogMessage -Type DEBUG -Message "Entered Test-JsonShallowValidation function..."

    $shallowValidationFunctionStartTime = Get-Date

    # Parse infrastructure.json once; all subsequent blocks reuse $inputData.
    $inputData = ConvertFrom-JsonSafely -JsonFilePath $InfrastructureJson

    # If EdgeSite is specified, resolve to list (validates delimiter and site names; throws if invalid).
    $edgeSitesArray = @()
    if ($EdgeSite) {
        $edgeSitesArray = Get-EdgeSitesFromParameter -EdgeSite $EdgeSite -InputData $inputData
        $siteList = $edgeSitesArray -join '", "'
        Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Validating only edgeSite(s) `"$siteList`" configuration..."
    }

    # Resolve scope-filtered cluster collection used throughout validation.
    $clustersInScope = if ($inputData.clusters) { Get-ClustersInScope -EdgeSitesArray $edgeSitesArray -InputData $inputData } else { @() }

    # contextName is required whenever any supervisor service (ArgoCD or Harbor) is active for any
    # cluster in scope. Both services use the VCF CLI context to interact with the supervisor.
    $requireContextName = $false
    if (-not $ComputeOnly) {
        foreach ($clusterRow in $clustersInScope) {
            $argoEnabled = -not (Get-EffectiveSupervisorServiceFlag -Cluster $clusterRow -CommonData $inputData.common -FlagName "disableArgoCD")
            $harborEnabled = -not (Get-EffectiveSupervisorServiceFlag -Cluster $clusterRow -CommonData $inputData.common -FlagName "disableHarbor")
            if ($argoEnabled -or $harborEnabled) {
                $requireContextName = $true
                break
            }
        }
    }

    $infrastructureJsonRequiredProperties = @(
        # Common Infrastructure Configuration Properties
        "common.datacenterName",                    # Name of the vSphere datacenter
        "common.vCenterName",                       # FQDN/IP of the vCenter
        "common.vCenterUser",                       # Username for vCenter authentication
        "common.contextName",                       # VCF CLI context name for all supervisor services (ArgoCD and Harbor)

        # Cluster Configuration Properties (per cluster)
        "clusters",                                 # Array of cluster configurations
        "clusters[].edgeSite",                      # Edge site identifier for cluster
        "clusters[].esxHosts",                      # Array of ESX host FQDNs/IPs
        "clusters[].networking",                    # Networking configuration
        "clusters[].networking.networkSegments",    # Array of network segment configurations
        "clusters[].networking.networkSegments[].name",    # Network segment name
        "clusters[].networking.networkSegments[].vlanId",  # VLAN ID for network segment
        "clusters[].networking.networkSegments[].gateway", # Gateway for network segment
        "clusters[].storagePolicy",                 # Storage policy configuration
        "clusters[].storagePolicy.storageType"      # Type of storage (e.g., VMFS, vSAN-ESA, vSAN-OSA)
    )

    if (-not $requireContextName) {
        $infrastructureJsonRequiredProperties = @($infrastructureJsonRequiredProperties | Where-Object { $_ -ne "common.contextName" })
    }

    # Define required properties for supervisor.json validation.
    # This array contains all mandatory property paths for supervisor cluster configuration.
    # Properties cover supervisor specs, load balancer components, and network configurations.

    $supervisorJsonRequiredProperties = @(
        # Common Supervisor Specification Properties
        "commonSupervisorSpec.controlPlaneVMCount",       # Number of control plane VMs
        "commonSupervisorSpec.controlPlaneSize",          # Size specification for control plane VMs
        "commonSupervisorSpec.flbAvailability",          # FLB availability configuration
        "commonSupervisorSpec.flbSize",                  # FLB size (small/medium/large)
        "commonSupervisorSpec.flbNetworkType",           # FLB network type
        "commonSupervisorSpec.networkSearchDomains",     # Network search domains (shared)
        "commonSupervisorSpec.networkNtpServers",        # Network NTP servers (shared)
        "commonSupervisorSpec.dnsServers",               # DNS servers (shared)

        # Site-Specific Supervisor Configuration
        "siteSpec",                                  # Array of site-specific configurations
        "siteSpec[].edgeSite",                       # Edge site identifier
        "siteSpec[].foundationLoadBalancerComponents.flbName",           # Load balancer name
        "siteSpec[].foundationLoadBalancerComponents.flbVipStartIP",     # Starting IP for VIP range
        "siteSpec[].foundationLoadBalancerComponents.flbVipIPCount",     # Number of VIP addresses
        "siteSpec[].foundationLoadBalancerComponents.flbManagementNetwork.flbNetworkName",                # Management network name
        "siteSpec[].foundationLoadBalancerComponents.flbManagementNetwork.flbNetworkIpAddressStartingIp", # Starting IP for management network
        "siteSpec[].foundationLoadBalancerComponents.flbManagementNetwork.flbNetworkIpAddressCount",      # Number of IPs in management network range
        "siteSpec[].foundationLoadBalancerComponents.flbVirtualServerNetwork.flbNetworkName",                # Virtual server network name
        "siteSpec[].foundationLoadBalancerComponents.flbVirtualServerNetwork.flbNetworkIpAddressStartingIp", # Starting IP for virtual server network
        "siteSpec[].foundationLoadBalancerComponents.flbVirtualServerNetwork.flbNetworkIpAddressCount",      # Number of IPs in virtual server network range
        "siteSpec[].mgmtNetworkSpec.mgmtNetworkName",            # Name of the supervisor management network
        "siteSpec[].mgmtNetworkSpec.mgmtNetworkStartingIp",      # Starting IP address for supervisor management network
        "siteSpec[].mgmtNetworkSpec.mgmtNetworkIPCount",         # Number of IP addresses for supervisor management network
        "siteSpec[].primaryWorkloadNetwork.primaryWorkloadNetworkName",             # Name of the primary workload network
        "siteSpec[].primaryWorkloadNetwork.primaryWorkloadNetworkStartingIp",       # Starting IP address for primary workload network
        "siteSpec[].primaryWorkloadNetwork.primaryWorkloadNetworkIPCount",          # Number of IP addresses for primary workload network
        "siteSpec[].primaryWorkloadNetwork.workloadServiceStartIp",                 # Starting IP for workload services
        "siteSpec[].primaryWorkloadNetwork.workloadServiceCount"                    # Number of service IP addresses for workloads
    )

    if ($ComputeOnly) {
        Write-LogMessage -Type INFO -Message "ComputeOnly: skipping supervisor.json shallow validation."
        $supervisorDataValidationResult = [PSCustomObject]@{ IsValid = $true; Summary = "skipped (ComputeOnly)" }
        $supervisorNullValidationResult = [PSCustomObject]@{ IsValid = $true; Summary = "skipped (ComputeOnly)" }
    } else {
        # Validate supervisor.json against required properties schema.
        Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Validating $SupervisorJson configuration file..."
        $supervisorDataValidationResult = Test-JsonMissingProperties -JsonFilePath $SupervisorJson -RequiredProperties $supervisorJsonRequiredProperties -JsonObjectName "SupervisorConfiguration" -ShowExpectedStructure

        # Validate supervisor.json for null values.
        Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Validating $SupervisorJson for null values..."
        $supervisorNullValidationResult = Test-JsonNullValues -JsonFilePath $SupervisorJson -RequiredProperties $supervisorJsonRequiredProperties -JsonObjectName "SupervisorConfiguration"
    }

    # Validate input.json against required properties schema.
    Write-LogMessage -Type INFO -SuppressOutputToScreen  -Message "Validating $InfrastructureJson configuration file..."
    $inputDataValidationResult = Test-JsonMissingProperties -JsonFilePath $InfrastructureJson -RequiredProperties $infrastructureJsonRequiredProperties -JsonObjectName "InputConfiguration" -ShowExpectedStructure

    # Check input.json validation results and handle accordingly.
    if (-not $inputDataValidationResult.IsValid) {
        Write-LogMessage -Type ERROR -Message "Input JSON validation failed: $($inputDataValidationResult.Summary)"
        Write-LogMessage -Type ERROR -Message "Deployment cannot proceed with incomplete input configuration. Please fix the missing properties and try again."
        throw [VcfDeploymentException]::new("Deployment cannot proceed with incomplete input configuration. Please fix the missing properties and try again.")
    } else {
        Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Input JSON validation passed: $($inputDataValidationResult.Summary)"
    }

    # Check supervisor.json validation results and handle accordingly.
    if (-not $supervisorDataValidationResult.IsValid) {
        Write-LogMessage -Type ERROR -Message "Supervisor JSON validation failed: $($supervisorDataValidationResult.Summary)"
        Write-LogMessage -Type ERROR -Message "Deployment cannot proceed with incomplete supervisor configuration. Please fix the missing properties and try again."
        throw [VcfDeploymentException]::new("Deployment cannot proceed with incomplete supervisor configuration. Please fix the missing properties and try again.")
    } else {
        Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Supervisor JSON validation passed: $($supervisorDataValidationResult.Summary)"
    }

    # Validate input.json for null values.
    Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Validating $InfrastructureJson for null values..."
    $inputNullValidationResult = Test-JsonNullValues -JsonFilePath $InfrastructureJson -RequiredProperties $infrastructureJsonRequiredProperties -JsonObjectName "InputConfiguration"

    # Check input.json null value validation results.
    if (-not $inputNullValidationResult.IsValid) {
        Write-LogMessage -Type ERROR -Message "Input JSON null value validation failed: $($inputNullValidationResult.Summary)"
        Write-LogMessage -Type ERROR -Message "Deployment cannot proceed with null values in input configuration. Please provide valid values for all required properties."
        throw [VcfDeploymentException]::new("Deployment cannot proceed with null values in input configuration. Please provide valid values for all required properties.")
    } else {
        Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Input JSON null value validation passed: $($inputNullValidationResult.Summary)"
    }

    # Check supervisor.json null value validation results.
    if (-not $supervisorNullValidationResult.IsValid) {
        Write-LogMessage -Type ERROR -Message "Supervisor JSON null value validation failed: $($supervisorNullValidationResult.Summary)"
        Write-LogMessage -Type ERROR -Message "Deployment cannot proceed with null values in supervisor configuration. Please provide valid values for all required properties."
        throw [VcfDeploymentException]::new("Deployment cannot proceed with null values in supervisor configuration. Please provide valid values for all required properties.")
    } else {
        Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Supervisor JSON null value validation passed: $($supervisorNullValidationResult.Summary)"
    }

    if ($ComputeOnly) {
        $edgeSiteValidationResult = [PSCustomObject]@{ IsValid = $true; ErrorMessage = $null }
    } else {
        # Validate edgeSite matching between infrastructure and supervisor JSONs.
        Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Validating edgeSite matching between infrastructure and supervisor JSONs..."
        $edgeSiteValidationResult = Test-EdgeSiteMatching -InfrastructureJson $InfrastructureJson -SupervisorJson $SupervisorJson
        if (-not $edgeSiteValidationResult.IsValid) {
            Write-LogMessage -Type ERROR -Message "EdgeSite matching validation failed: $($edgeSiteValidationResult.ErrorMessage)"
            throw [VcfDeploymentException]::new("EdgeSite matching validation failed: $($edgeSiteValidationResult.ErrorMessage)")
        }
    }

    # Validate nicList: at least one definition (common or per-cluster) mandatory; cluster overrides common; 2 or 4 NICs.
    Test-InfrastructureNicListEffective -InputData $inputData -Clusters $clustersInScope
    Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Infrastructure nicList validation passed (cluster override or common; 2 or 4 NICs per cluster)."

    # Validate esxHosts is an array (not singular esxHost).
    Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Validating esxHosts format in infrastructure JSON..."
    if ($inputData.clusters) {
        foreach ($cluster in $inputData.clusters) {
            if ($cluster.PSObject.Properties.Name -contains "esxHost") {
                Write-LogMessage -Type ERROR -Message "Cluster with edgeSite '$($cluster.edgeSite)' uses deprecated 'esxHost' (singular). Use 'esxHosts' (plural) array instead."
                throw [VcfDeploymentException]::new("Cluster with edgeSite '$($cluster.edgeSite)' uses deprecated 'esxHost' (singular). Use 'esxHosts' (plural) array instead.")
            }
            if (-not $cluster.esxHosts) {
                Write-LogMessage -Type ERROR -Message "Cluster with edgeSite '$($cluster.edgeSite)' is missing 'esxHosts' array."
                throw [VcfDeploymentException]::new("Cluster with edgeSite '$($cluster.edgeSite)' is missing 'esxHosts' array.")
            }
            if ($cluster.esxHosts -isnot [Array]) {
                Write-LogMessage -Type ERROR -Message "Cluster with edgeSite '$($cluster.edgeSite)' has 'esxHosts' that is not an array."
                throw [VcfDeploymentException]::new("Cluster with edgeSite '$($cluster.edgeSite)' has 'esxHosts' that is not an array.")
            }
            if ($cluster.esxHosts.Count -eq 0) {
                Write-LogMessage -Type ERROR -Message "Cluster with edgeSite '$($cluster.edgeSite)' has empty 'esxHosts' array."
                throw [VcfDeploymentException]::new("Cluster with edgeSite '$($cluster.edgeSite)' has empty 'esxHosts' array.")
            }
        }
    }

    # Validate common.esxUniquePasswordPerHost when present: must be boolean true or false.
    if ($inputData.common -and $null -ne $inputData.common.PSObject.Properties["esxUniquePasswordPerHost"]) {
        $esxUniquePasswordPerHostValue = $inputData.common.esxUniquePasswordPerHost
        if ($esxUniquePasswordPerHostValue -isnot [bool]) {
            Write-LogMessage -Type ERROR -Message "common.esxUniquePasswordPerHost must be true or false (boolean). Current value type: $($esxUniquePasswordPerHostValue.GetType().Name). Fix the value in $InfrastructureJson and re-run."
            throw [VcfDeploymentException]::new("Deployment failed. common.esxUniquePasswordPerHost must be true or false (boolean). Check logs for details.")
        }
    }

    # Validate common.nonInteractivePassword when present: must be boolean true or false.
    if ($inputData.common -and $null -ne $inputData.common.PSObject.Properties["nonInteractivePassword"]) {
        $nonInteractivePasswordValue = $inputData.common.nonInteractivePassword
        if ($nonInteractivePasswordValue -isnot [bool]) {
            Write-LogMessage -Type ERROR -Message "common.nonInteractivePassword must be true or false (boolean). Current value type: $($nonInteractivePasswordValue.GetType().Name). Fix the value in $InfrastructureJson and re-run."
            throw [VcfDeploymentException]::new("Deployment failed. common.nonInteractivePassword must be true or false (boolean). Check logs for details.")
        }
    }

    # Validate common.autoUpdate when present: must be boolean true or false.
    if ($inputData.common -and $null -ne $inputData.common.PSObject.Properties["autoUpdate"]) {
        $autoUpdateValue = $inputData.common.autoUpdate
        if ($autoUpdateValue -isnot [bool]) {
            Write-LogMessage -Type ERROR -Message "common.autoUpdate must be true or false (boolean). Current value type: $($autoUpdateValue.GetType().Name). Fix the value in $InfrastructureJson and re-run."
            throw [VcfDeploymentException]::new("Deployment failed. common.autoUpdate must be true or false (boolean). Check logs for details.")
        }
    }

    # Validate common.preserveAutoGeneratedKeyCertPair when present: must be boolean true or false.
    if ($inputData.common -and $null -ne $inputData.common.PSObject.Properties["preserveAutoGeneratedKeyCertPair"]) {
        $preserveKeyCertValue = $inputData.common.preserveAutoGeneratedKeyCertPair
        if ($preserveKeyCertValue -isnot [bool]) {
            Write-LogMessage -Type ERROR -Message "common.preserveAutoGeneratedKeyCertPair must be true or false (boolean). Current value type: $($preserveKeyCertValue.GetType().Name). Fix the value in $InfrastructureJson and re-run."
            throw [VcfDeploymentException]::new("Deployment failed. common.preserveAutoGeneratedKeyCertPair must be true or false (boolean). Check logs for details.")
        }
    }

    if (-not $ComputeOnly) {
        Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Validating supervisor service YAML and Harbor TLS paths (shallow check)..."
        # Resolve referenced file paths so relative paths in infrastructure.json are expanded before validation.
        Update-InfrastructureJsonReferencedFilePaths -InfrastructureJsonPath $InfrastructureJson -InputData $inputData
        $shallowPathFailures = Test-JsonShallowSupervisorServicesPathConfiguration -ClustersToValidate $clustersInScope -InputData $inputData
        if ($shallowPathFailures -gt 0) {
            Write-LogMessage -Type ERROR -Message "JSON configuration validation found $shallowPathFailures file path error(s). Verify all referenced paths exist and re-run."
            throw [VcfDeploymentException]::new("JSON configuration validation found $shallowPathFailures file path error(s). Verify all referenced paths exist and re-run.")
        }
        Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Supervisor service YAML and Harbor TLS shallow path validation passed."
    }

    # If all validation results are valid, write a success message.
    if ($inputDataValidationResult.IsValid -and $supervisorDataValidationResult.IsValid -and $inputNullValidationResult.IsValid -and $supervisorNullValidationResult.IsValid -and $edgeSiteValidationResult.IsValid) {
        $siteIndication = if (-not $EdgeSite) { "all sites" } elseif ($null -ne $edgeSitesArray -and $edgeSitesArray.Count -gt 0) { "edgeSite(s) `"$($edgeSitesArray -join '", "')`"" } else { "edgeSite `"$EdgeSite`"" }
        Write-LogMessage -Type DEBUG -Message "JSON configuration file validation completed successfully for $siteIndication."
    }

    $shallowValidationFunctionElapsed = (Get-Date) - $shallowValidationFunctionStartTime
    $siteIndication = if (-not $EdgeSite) { "all sites" } elseif ($null -ne $edgeSitesArray -and $edgeSitesArray.Count -gt 0) { "edgeSite(s) `"$($edgeSitesArray -join '", "')`"" } else { "edgeSite `"$EdgeSite`"" }
    Write-LogMessage -Type DEBUG -Message "Test-JsonShallowValidation completed all validation calls for $siteIndication in $($shallowValidationFunctionElapsed.TotalSeconds.ToString('F3')) seconds."
}
Function ConvertTo-IpInt {

    <#
        .SYNOPSIS
        Converts a dotted-quad IPv4 address string to a 32-bit integer.

        .PARAMETER IpString
        The IPv4 address string to convert (e.g. "192.168.1.1").

        .OUTPUTS
        Int64
        The address as a 32-bit unsigned value stored in an Int64.

        .NOTES
        Helper for Test-IpAddressInCidrRange. Input is assumed to be a valid dotted-quad string;
        validate with Test-ValidIPv4Address before calling.
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$IpString
    )

    $octets = $IpString.Split('.')
    return ([int64]$octets[0] -shl 24) -bor ([int64]$octets[1] -shl 16) -bor ([int64]$octets[2] -shl 8) -bor [int64]$octets[3]
}
Function Test-IpAddressInCidrRange {

    <#
        .SYNOPSIS
        Tests if an IP address falls within a specified CIDR network range.

        .DESCRIPTION
        The Test-IpAddressInCidrRange function validates whether a given IP address
        is contained within a specified CIDR network range. This is useful for validating
        that starting IP addresses, gateway addresses, or other IP configurations fall
        within expected network boundaries.

        The function performs the following validation:
        1. Validates the format of both the IP address and CIDR notation
        2. Parses the CIDR range to extract network address and subnet mask
        3. Converts both IP addresses to binary format for comparison
        4. Applies the subnet mask to determine network membership
        5. Returns true if the IP is within the range, false otherwise

        .PARAMETER IpAddress
        The IP address to test (e.g., "192.168.1.100"). Must be a valid IPv4 address.

        .PARAMETER CidrRange
        The CIDR network range (e.g., "192.168.1.0/24"). Must be in valid CIDR notation
        with format: IP/prefix where prefix is 0-32.

        .EXAMPLE
        Test-IpAddressInCidrRange -IpAddress "192.168.1.100" -CidrRange "192.168.1.0/24"
        Returns $true because 192.168.1.100 is within the 192.168.1.0/24 network.

        .EXAMPLE
        Test-IpAddressInCidrRange -IpAddress "10.0.0.5" -CidrRange "192.168.1.0/24"
        Returns $false because 10.0.0.5 is not within the 192.168.1.0/24 network.

        .EXAMPLE
        Test-IpAddressInCidrRange -IpAddress "172.16.50.1" -CidrRange "172.16.0.0/16"
        Returns $true because 172.16.50.1 is within the 172.16.0.0/16 network.

        .OUTPUTS
        Boolean
        Returns $true if the IP address is within the CIDR range, $false otherwise.

        .NOTES
        This function only supports IPv4 addresses and CIDR notation.
        The function validates input formats before performing range checks.

    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$IpAddress,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$CidrRange

    )

    Write-LogMessage -Type DEBUG -Message "Entered Test-IpAddressInCidrRange function..."

    try {
        # Validate IP address format.

        if ($IpAddress -notmatch '^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$') {
            Write-LogMessage -Type ERROR -Message "Invalid IP address format: $IpAddress"
            return $false
        }

        # Validate CIDR range format.

        if ($CidrRange -notmatch '^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\/([0-9]|[1-2][0-9]|3[0-2])$') {
            Write-LogMessage -Type ERROR -Message "Invalid CIDR range format: $CidrRange"
            return $false
        }

        # Split CIDR into network address and prefix length.

        $cidrParts = $CidrRange.Split('/')
        $networkAddress = $cidrParts[0]
        $prefixLength = [int]$cidrParts[1]

        # Calculate subnet mask from prefix length.

        if ($prefixLength -eq 0) {
            $subnetMask = 0
        } else {
            $subnetMask = [int64][Math]::Pow(2, 32) - [int64][Math]::Pow(2, (32 - $prefixLength))
        }

        # Convert addresses to integers.

        $ipInt = ConvertTo-IpInt -IpString $IpAddress
        $networkInt = ConvertTo-IpInt -IpString $networkAddress

        # Apply subnet mask to both addresses.

        $ipNetwork = $ipInt -band $subnetMask
        $cidrNetwork = $networkInt -band $subnetMask

        # Check if the IP is in the same network.

        $isInRange = ($ipNetwork -eq $cidrNetwork)

        if ($isInRange) {
            Write-LogMessage -Type DEBUG -Message "IP address $IpAddress is within CIDR range $CidrRange"
        } else {
            Write-LogMessage -Type DEBUG -Message "IP address $IpAddress is NOT within CIDR range $CidrRange"
        }

        return $isInRange
    } catch {
        Write-LogMessage -Type ERROR -Message "Error checking IP address range: $($_.Exception.Message)"
        return $false
    }
}
Function Get-JsonPropertyValue {

    <#
        .SYNOPSIS
        Extracts a property value from a JSON object using dot-notation path.

        .DESCRIPTION
        The Get-JsonPropertyValue function navigates nested JSON objects, PSCustomObjects, or Hashtables
        using a dot-notation property path (e.g., "parent.child.property") and returns the value as a string.
        This helper function separates the concern of property extraction from validation logic.

        .PARAMETER InputData
        The input data object (JSON, PSCustomObject, Hashtable, or String) to extract the value from.

        .PARAMETER PropertyPath
        Optional. The dot-notation path to the property (e.g., "common.vCenterName"). If not specified
        and InputData is a string, returns the string directly. If not specified and InputData is an
        object, converts the entire object to a string.

        .OUTPUTS
        System.String
        Returns the extracted property value as a string, or $null if extraction fails.

        .EXAMPLE
        $value = Get-JsonPropertyValue -InputData $config -PropertyPath "common.vCenterName"
        Extracts the vCenterName property from the common section of the config object.

        .NOTES
        This is a helper function used by Test-JsonPropertyFormat to separate property extraction
        from validation logic, improving testability and maintainability.
    #>

    Param (
        [Parameter(Mandatory = $true)] [AllowNull()] [AllowEmptyString()] [Object]$InputData,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [String]$PropertyPath
    )

    try {
        # Handle null input
        if ($null -eq $InputData) {
            Write-LogMessage -Type ERROR -SuppressOutputToScreen -Message "Input data is null"
            return $null
        }

        # If inputData is already a string, return it directly.

        if ($InputData -is [String]) {
            return $InputData
        }

        # If propertyPath is specified and not empty, extract the property value.
        if ($PropertyPath -and $PropertyPath.Trim() -ne "") {

            # Split property path by dots to navigate nested properties.
            $pathParts = $PropertyPath.Split('.')
            $currentObject = $InputData

            for ($pathPartIndex = 0; $pathPartIndex -lt $pathParts.Count; $pathPartIndex++) {
                $part = $pathParts[$pathPartIndex]
                $isArrayNotation = $part -match '^(.+)\[\]$'

                if ($null -eq $currentObject) {
                    Write-LogMessage -Type ERROR -SuppressOutputToScreen -Message "Property path '$PropertyPath' contains null value at '$part'"
                    return $null
                }

                if ($isArrayNotation) {
                    # Handle array notation (e.g., "clusters[]").
                    $arrayPropertyName = $matches[1]

                    # Get the array property.
                    if ($currentObject -is [PSCustomObject]) {
                        $arrayObject = $currentObject.$arrayPropertyName
                    } elseif ($currentObject -is [Hashtable]) {
                        $arrayObject = $currentObject[$arrayPropertyName]
                    } else {
                        try {
                            $arrayObject = $currentObject.$arrayPropertyName
                        } catch {
                            Write-LogMessage -Type ERROR -SuppressOutputToScreen -Message "Cannot access array property '$arrayPropertyName' in path '$PropertyPath': $($_.Exception.Message)"
                            return $null
                        }
                    }

                    if ($null -eq $arrayObject) {
                        Write-LogMessage -Type ERROR -SuppressOutputToScreen -Message "Array property '$arrayPropertyName' is null in path '$PropertyPath'"
                        return $null
                    }

                    if ($arrayObject -isnot [Array] -and $arrayObject -isnot [System.Collections.ArrayList]) {
                        Write-LogMessage -Type ERROR -SuppressOutputToScreen -Message "Property '$arrayPropertyName' is not an array in path '$PropertyPath'"
                        return $null
                    }

                    # If this is the last part, return the array itself (as string representation).
                    if ($pathPartIndex -eq ($pathParts.Count - 1)) {
                        $result = if ($arrayObject.Count -eq 0) { "" } else { $arrayObject.ToString() }
                        return $result
                    }

                    # For array notation with remaining path, check if any element has the remaining path.
                    # This is used for validation - we'll check the first element that has the property.
                    # Correctly handle array slicing - if no remaining parts, use empty array
                    if ($pathPartIndex + 1 -ge $pathParts.Count) {
                        $remainingPath = ""
                    } else {
                        $remainingPath = $pathParts[($pathPartIndex + 1)..($pathParts.Count - 1)] -join '.'
                    }
                    $found = $false

                    foreach ($element in $arrayObject) {
                        # Only call Get-JsonPropertyValue if we have a remaining path, otherwise return the element itself
                        if ($remainingPath -and $remainingPath.Trim() -ne "") {
                            $elementValue = Get-JsonPropertyValue -InputData $element -PropertyPath $remainingPath
                        } else {
                            $elementValue = $element
                        }
                        if ($null -ne $elementValue) {
                            $result = $elementValue
                            $found = $true
                            break
                        }
                    }

                    if (-not $found) {
                        Write-LogMessage -Type ERROR -SuppressOutputToScreen -Message "No element in array '$arrayPropertyName' has the remaining path '$remainingPath'"
                        return $null
                    }

                    return $result
                }
                else {
                    # Handle regular property access (non-array).
                    if ($currentObject -is [PSCustomObject]) {
                        $currentObject = $currentObject.$part
                    } elseif ($currentObject -is [Hashtable]) {
                        $currentObject = $currentObject[$part]
                    } else {
                        try {
                            $currentObject = $currentObject.$part
                        } catch {
                            Write-LogMessage -Type ERROR -SuppressOutputToScreen -Message "Cannot access property '$part' in path '$PropertyPath': $($_.Exception.Message)"
                            return $null
                        }
                    }
                }
            }

            # Convert the final property value to string.
            $result = if ($null -eq $currentObject) { "" } else { $currentObject.ToString() }
            return $result
        }
        # If no propertyPath specified, convert entire object to string.

        else {
            $result = $InputData.ToString()
            return $result
        }
    } catch {
        Write-LogMessage -Type ERROR -SuppressOutputToScreen -Message "Error extracting property value: $($_.Exception.Message)"
        return $null
    }
}
Function Get-ValidationPresetRules {

    <#
        .SYNOPSIS
        Returns validation rules for predefined validation presets.

        .DESCRIPTION
        The Get-ValidationPresetRules function maps validation preset names to their corresponding
        validation rules (allowed characters, regex patterns, etc.). This separates preset definition
        logic from the main validation orchestration, improving maintainability and extensibility.

        .PARAMETER ValidationPreset
        The name of the validation preset to retrieve rules for.

        .OUTPUTS
        System.Collections.Hashtable
        Returns a hashtable containing validation rules with keys:
        - AllowedCharacters: String of allowed characters (if applicable)
        - DisallowedCharacters: String of disallowed characters (if applicable)
        - RegexPattern: Regular expression pattern (if applicable)

        .EXAMPLE
        $rules = Get-ValidationPresetRules -ValidationPreset "IpAddress"
        Returns rules for IP address validation including the regex pattern.

        .NOTES
        This is a helper function used by Test-JsonPropertyFormat to separate preset logic
        from validation execution, making it easier to add or modify presets.
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateSet("AlphaNumeric", "AlphaNumericDash", "Numeric", "FileName", "UserName", "DomainName", "IpAddress", "IpAddressOrFqdn", "IpAddressWithCidr", "IpAddressOrDomainNameWithPort", "Email", "lowerCaseRfc1123PortGroup", "FilePath", "vSphereObject80Characters", "Url")] [String]$ValidationPreset
    )

    Write-LogMessage -Type DEBUG -Message "Entered Get-ValidationPresetRules function..."

    $rules = @{
        AllowedCharacters = $null
        DisallowedCharacters = $null
        RegexPattern = $null
    }

    switch ($ValidationPreset) {
        "AlphaNumeric" {
            $rules.AllowedCharacters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        }
        "AlphaNumericDash" {
            $rules.AllowedCharacters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
        }
        "Numeric" {
            $rules.AllowedCharacters = "0123456789"
        }
        "FileName" {
            $rules.DisallowedCharacters = '<>:"/\|?*'
        }
        "UserName" {
            $rules.AllowedCharacters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"
        }
        "DomainName" {
            $rules.RegexPattern = '^[a-zA-Z0-9][a-zA-Z0-9\-\.]*[a-zA-Z0-9]$'
        }
        "IpAddressOrDomainNameWithPort" {
            $rules.RegexPattern = '^(?:(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)|(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)*[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?):(?:[1-9][0-9]{0,3}|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5])$'
        }
        "IpAddress" {
            $rules.RegexPattern = '^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$'
        }
        "IpAddressOrFqdn" {
            # IPv4 dotted quad OR FQDN (e.g. for ESX host or vCenter name).
            $rules.RegexPattern = '^(?:(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)|[a-zA-Z0-9]([a-zA-Z0-9\-_\.]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-_\.]*[a-zA-Z0-9])?)*)$'
        }
        "IpAddressWithCidr" {
            $rules.RegexPattern = '^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\/([0-9]|[1-2][0-9]|3[0-2])$'
        }
        "Email" {
            $rules.RegexPattern = '^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'
        }
        "lowerCaseRfc1123PortGroup" {
            $rules.RegexPattern = '^(?=.{1,80}$)[a-z0-9]([-a-z0-9]*[a-z0-9])?$'
        }
        "FilePath" {
            # Cross-platform file path regex supporting Windows, Linux, and macOS.
            $rules.RegexPattern = '^(?:(?:[a-zA-Z]:)?[\\\/]|\.{0,2}[\\\/]|\\\\[^\\\/\s]+[\\\/][^\\\/\s]+[\\\/])?(?:[^<>:"|?*\x00-\x1f\\\/]+[\\\/])*[^<>:"|?*\x00-\x1f\\\/]*$'
        }
        "vSphereObject80Characters" {
            # vSphere object name validation: alphanumeric, hyphen, underscore, plus sign, spaces, parentheses
            $rules.RegexPattern = '^[a-zA-Z0-9\s_+\-()]{1,80}$'
        }
        "Url" {
            # URL validation: https://www.example.com/path/to/resource
            # Supports: http/https, multiple subdomains, modern TLDs (2-63 chars), paths, query strings, fragments
            $rules.RegexPattern = '^https?:\/\/([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}([\/\w\-\.~!*''();:@&=+$,?#\[\]]*)?$'
        }
    }

    Write-LogMessage -Type DEBUG -Message "Retrieved validation rules for preset '$ValidationPreset'"
    return $rules
}
Function Test-StringAgainstAllowlist {

    <#
        .SYNOPSIS
        Validates that a string contains only allowed characters.

        .DESCRIPTION
        The Test-StringAgainstAllowlist function checks each character in the input string
        against an allowlist of permitted characters. This implements a secure allowlist
        validation approach.

        .PARAMETER InputText
        The string to validate.

        .PARAMETER AllowedCharacters
        A string containing all characters that are permitted in the input.

        .OUTPUTS
        System.Boolean
        Returns $true if all characters in InputText are in the allowlist, $false otherwise.

        .EXAMPLE
        $isValid = Test-StringAgainstAllowlist -InputText "Server01" -AllowedCharacters "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        Validates that Server01 contains only alphanumeric characters.

        .NOTES
        This is a helper function used by Test-JsonPropertyFormat to separate allowlist
        validation logic from orchestration.
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$InputText,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$AllowedCharacters
    )

    Write-LogMessage -Type DEBUG -Message "Entered Test-StringAgainstAllowlist function..."

    Write-LogMessage -Type DEBUG -Message "Validating string against allowed characters allowlist"

    foreach ($char in $InputText.ToCharArray()) {
        if ($AllowedCharacters.IndexOf($char.ToString()) -eq -1) {
            Write-LogMessage -Type ERROR -Message "Character '$char' is not in the allowed character set"
            return $false
        }
    }

    Write-LogMessage -Type DEBUG -Message "Allowlist validation passed"
    return $true
}
Function Test-StringAgainstDenylist {

    <#
        .SYNOPSIS
        Validates that a string does not contain forbidden characters.

        .DESCRIPTION
        The Test-StringAgainstDenylist function checks that the input string does not
        contain any characters from a denylist of forbidden characters.

        .PARAMETER InputText
        The string to validate.

        .PARAMETER DisallowedCharacters
        A string containing characters that are not permitted in the input.

        .OUTPUTS
        System.Boolean
        Returns $true if no forbidden characters are found, $false otherwise.

        .EXAMPLE
        $isValid = Test-StringAgainstDenylist -InputText "MyFile.txt" -DisallowedCharacters '<>:"/\|?*'
        Validates that the filename doesn't contain filesystem-unsafe characters.

        .NOTES
        This is a helper function used by Test-JsonPropertyFormat to separate denylist
        validation logic from orchestration.
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$InputText,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DisallowedCharacters
    )

    Write-LogMessage -Type DEBUG -Message "Entered Test-StringAgainstDenylist function..."

    Write-LogMessage -Type DEBUG -Message "Validating string against disallowed characters denylist"

    foreach ($char in $InputText.ToCharArray()) {
        if ($DisallowedCharacters.IndexOf($char.ToString()) -ne -1) {
            Write-LogMessage -Type ERROR -Message "Character '$char' is not allowed (found in disallowed character set)"
            return $false
        }
    }

    Write-LogMessage -Type DEBUG -Message "Denylist validation passed"
    return $true
}
Function Test-AcceptableStrings {

    <#
        .SYNOPSIS
        Validates that a string matches one of the acceptable values.

        .DESCRIPTION
        The Test-AcceptableStrings function checks if the input string exactly matches
        one of the strings in an acceptable values list. This implements enumerated
        value validation for controlled vocabularies.

        .PARAMETER InputText
        The string to validate.

        .PARAMETER AcceptableStrings
        An array of strings that are considered acceptable values.

        .PARAMETER PropertyPath
        Optional. The property path for error messages.

        .OUTPUTS
        System.Boolean
        Returns $true if the input matches one of the acceptable strings, $false otherwise.

        .EXAMPLE
        $isValid = Test-AcceptableStrings -inputText "SMALL" -acceptableStrings @("TINY", "SMALL", "MEDIUM", "LARGE")
        Validates that the control plane size is one of the acceptable values.

        .NOTES
        This is a helper function used by Test-JsonPropertyFormat to separate acceptable
        strings validation logic from orchestration. Uses ordinal comparison for consistency.

    #>

    Param (
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [String]$PropertyPath,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [String]$InputText,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [String[]]$AcceptableStrings
    )

    Write-LogMessage -Type DEBUG -Message "Entered Test-AcceptableStrings function..."

    Write-LogMessage -Type DEBUG -Message "Validating against list of acceptable strings: $($AcceptableStrings -join ', ')"

    $stringComparison = [System.StringComparison]::Ordinal
    foreach ($acceptableString in $AcceptableStrings) {
        if ([String]::Equals($InputText, $acceptableString, $stringComparison)) {
            Write-LogMessage -Type DEBUG -Message "Matched acceptable string: '$acceptableString'"
            return $true
        }
    }

    # Build error message with optional property path.
    $pathInfo = if ($PropertyPath) { " for JSON property `"$PropertyPath`"" } else { "" }
    Write-LogMessage -Type ERROR -Message "Validation failed for input value `"$InputText`"${pathInfo}. It should be one of: $($AcceptableStrings -join ', ')"
    return $false
}
Function Test-NumericRange {

    <#
        .SYNOPSIS
        Validates that a numeric value falls within a specified range.

        .DESCRIPTION
        The Test-NumericRange function converts a string to a numeric value and validates
        that it falls within specified minimum and maximum bounds. Supports validation
        against minimum only, maximum only, or both.

        .PARAMETER InputText
        The string representation of the numeric value to validate.

        .PARAMETER MinValue
        Optional. The minimum acceptable value.

        .PARAMETER MaxValue
        Optional. The maximum acceptable value.

        .PARAMETER PropertyPath
        Optional. The property path for error messages.

        .OUTPUTS
        System.Boolean
        Returns $true if the value is numeric and within the specified range, $false otherwise.

        .EXAMPLE
        $isValid = Test-NumericRange -InputText "5" -MinValue 1 -MaxValue 10
        Validates that the value is between 1 and 10.

        .NOTES
        This is a helper function used by Test-JsonPropertyFormat to separate numeric
        range validation logic from orchestration.

    #>

    Param (
        [Parameter(Mandatory = $false)] [Double]$MaxValue,
        [Parameter(Mandatory = $false)] [Double]$MinValue,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [String]$PropertyPath,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$InputText
    )

    Write-LogMessage -Type DEBUG -Message "Entered Test-NumericRange function..."

    Write-LogMessage -Type DEBUG -Message "Validating numeric range for value: '$InputText'"

    # Attempt to convert input to numeric.
    $numericValue = $null
    $isNumeric = [Double]::TryParse($InputText, [ref]$numericValue)

    if (-not $isNumeric) {
        $pathInfo = if ($PropertyPath) { " for property `"$PropertyPath`"" } else { "" }
        Write-LogMessage -Type ERROR -Message "Numeric validation failed${pathInfo}: Value `"$InputText`" is not a valid number"
        return $false
    }

    # Check minimum value.
    if ($PSBoundParameters.ContainsKey('MinValue') -and $numericValue -lt $MinValue) {
        $pathInfo = if ($PropertyPath) { " for property `"$PropertyPath`"" } else { "" }
        Write-LogMessage -Type ERROR -Message "Numeric validation failed${pathInfo}: Value $numericValue is below minimum $MinValue."
        return $false
    }

    # Check maximum value.
    if ($PSBoundParameters.ContainsKey('MaxValue') -and $numericValue -gt $MaxValue) {
        $pathInfo = if ($PropertyPath) { " for property `"$PropertyPath`"" } else { "" }
        Write-LogMessage -Type ERROR -Message "Numeric validation failed${pathInfo}: Value $numericValue exceeds maximum $MaxValue."
        return $false
    }

    Write-LogMessage -Type DEBUG -Message "Numeric range validation passed for value: $numericValue"
    return $true
}
Function Test-ValidCidrRange {

    <#
        .SYNOPSIS
        Validates that an IP count corresponds to a valid CIDR block range.

        .DESCRIPTION
        The Test-ValidCidrRange function checks if a given IP address count corresponds to a valid
        CIDR range (/8 to /32). The value must be a power of 2 AND within the valid range.
        This ensures IP address counts correspond to complete, valid CIDR blocks.

        Valid CIDR ranges (IPv4):
        - 1 IP = 2^0 = /32 (single host)
        - 2 IPs = 2^1 = /31 (point-to-point)
        - 4 IPs = 2^2 = /30
        - 8 IPs = 2^3 = /29
        - 16 IPs = 2^4 = /28
        - 32 IPs = 2^5 = /27
        - 64 IPs = 2^6 = /26
        - 128 IPs = 2^7 = /25
        - 256 IPs = 2^8 = /24
        - 512 IPs = 2^9 = /23
        - 1024 IPs = 2^10 = /22
        - ... up to ...
        - 16,777,216 IPs = 2^24 = /8 (maximum)

        Values larger than 16,777,216 (e.g., 2^25 = 33,554,432) are powers of 2 but correspond
        to CIDR prefixes smaller than /8, which are invalid.

        .PARAMETER InputText
        The value to validate as a power of 2.

        .PARAMETER PropertyPath
        Optional. The property path for error messages.

        .OUTPUTS
        System.Boolean
        Returns $true if the value is a power of 2, $false otherwise.

        .EXAMPLE
        $isValid = Test-ValidCidrRange -InputText "512"
        Validates that "512" corresponds to a valid CIDR range (/23).
        Returns: $true

        .EXAMPLE
        $isValid = Test-ValidCidrRange -InputText "511"
        Validates that "511" corresponds to a valid CIDR range.
        Returns: $false (511 is not a power of 2)

        .EXAMPLE
        $isValid = Test-ValidCidrRange -InputText "33554432"
        Validates that "33554432" corresponds to a valid CIDR range.
        Returns: $false (would be /7, outside valid range)

        .NOTES
        The function uses bitwise AND operation to check if a number is a power of 2.
        A power of 2 in binary has exactly one bit set (e.g., 8 = 1000, 16 = 10000).
        The check (n & (n-1)) == 0 returns true only for powers of 2.
    #>

    Param (
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [String]$PropertyPath,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$InputText
    )

    Write-LogMessage -Type DEBUG -Message "Entered Test-ValidCidrRange function..."

    Write-LogMessage -Type DEBUG -Message "Validating CIDR range for IP count: '$InputText'"

    # Attempt to parse as integer.
    $number = $null
    $isInteger = [int]::TryParse($InputText, [ref]$number)

    if (-not $isInteger) {
        $pathInfo = if ($PropertyPath) { " for property `"$PropertyPath`"" } else { "" }
        Write-LogMessage -Type ERROR -Message "CIDR range validation failed${pathInfo}: Value `"$InputText`" is not a valid integer"
        return $false
    }

    # Check if number is positive.
    if ($number -le 0) {
        $pathInfo = if ($PropertyPath) { " for property `"$PropertyPath`"" } else { "" }
        Write-LogMessage -Type ERROR -Message "CIDR range validation failed${pathInfo}: Value $number must be positive."
        return $false
    }

    # Check if number is a power of 2 using bitwise AND.
    # A power of 2 has only one bit set in binary representation.
    # Example: 8 = 1000, 8-1 = 0111, 1000 & 0111 = 0000.
    # Non-power: 7 = 0111, 7-1 = 0110, 0111 & 0110 = 0110 (not zero)
    $isPowerOfTwo = ($number -band ($number - 1)) -eq 0

    if (-not $isPowerOfTwo) {
        $pathInfo = if ($PropertyPath) { " for property `"$PropertyPath`"" } else { "" }

        # Calculate what CIDR block this would be if it were valid.

        $nearestLower = [Math]::Pow(2, [Math]::Floor([Math]::Log($number, 2)))
        $nearestUpper = [Math]::Pow(2, [Math]::Ceiling([Math]::Log($number, 2)))

        Write-LogMessage -Type ERROR -Message "CIDR range validation failed${pathInfo}: Value $number is not a power of 2 (not a complete CIDR block). Nearest valid values: $nearestLower or $nearestUpper"
        return $false
    }

    # Calculate equivalent CIDR prefix.
    $cidrPrefix = 32 - [Math]::Log($number, 2)

    # Validate that this corresponds to a valid CIDR range (/8 to /32)
    # /32 = 1 IP, /31 = 2 IPs, /30 = 4 IPs, ... /8 = 16,777,216 IPs
    if ($cidrPrefix -lt 8 -or $cidrPrefix -gt 32) {
        $pathInfo = if ($PropertyPath) { " for property `"$PropertyPath`"" } else { "" }
        Write-LogMessage -Type ERROR -Message "CIDR range validation failed${pathInfo}: Value $number corresponds to /$cidrPrefix which is outside valid CIDR range (/8 to /32). Valid IP counts: 1 to 16,777,216"
        return $false
    }

    Write-LogMessage -Type DEBUG -Message "CIDR range validation passed for value: $number (equivalent to /$cidrPrefix CIDR block)"
    return $true
}
Function Test-JsonPropertyFormat {

    <#
        .SYNOPSIS
        Validates input from JSON properties or text against specified character sets and patterns to ensure only valid characters are present.

        .DESCRIPTION
        The Test-JsonPropertyFormat function provides comprehensive input validation by checking JSON property values
        or direct text input against defined character sets, regular expressions, or predefined validation presets.
        This function helps ensure data integrity and security by preventing invalid characters from being processed
        by the application.

        The function supports multiple validation modes including allowlist character validation,
        denylist character exclusion, regular expression pattern matching, and common preset
        validations for typical use cases like filenames, usernames, and system identifiers.

        This function is essential for validating JSON configuration data and user input before processing
        it in scripts that interact with file systems, network resources, or other components that may be
        sensitive to special characters or injection attacks.

        .PARAMETER InputData
        The input data to validate. This parameter accepts either:
        - A JSON object/PSCustomObject with properties to validate
        - A string value to validate directly
        - A hashtable with key-value pairs to validate
        The function will extract string values from JSON properties or validate the string directly
        according to the validation rules provided.

        .PARAMETER PropertyPath
        Optional. When InputData is a JSON object, specifies the dot-notation path to the property to validate.
        For example: "common.vCenterName" or "supervisorSpec.controlPlaneSize". If not specified and InputData
        is an object, the function will attempt to convert the entire object to a string for validation.

        .PARAMETER AllowedCharacters
        A string containing all characters that are permitted in the input. When specified,
        the function will validate that the input contains only characters present in this set.
        This is a allowlist approach where only explicitly allowed characters pass validation.
        Example: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"

        .PARAMETER DisallowedCharacters
        A string containing characters that are not permitted in the input. When specified,
        the function will fail validation if any of these characters are found in the input.
        This is a denylist approach where specific characters are explicitly forbidden.
        Example: "<>:\"/\\|?*" (common filesystem-unsafe characters)

        .PARAMETER RegexPattern
        A regular expression pattern that the input must match. When specified, the entire
        input string must match this pattern for validation to succeed. This provides
        flexible pattern-based validation for complex requirements.
        Example: "^[a-zA-Z0-9][a-zA-Z0-9\-_.]*[a-zA-Z0-9]$" (valid hostname pattern)

        .PARAMETER ValidationPreset
        A predefined validation preset that applies common validation rules. Available presets:
        - AlphaNumeric: Letters and numbers only
        - AlphaNumericDash: Letters, numbers, hyphens, and underscores
        - Numeric: Numbers only (0-9)
        - FileName: Safe characters for file names (excludes filesystem-unsafe characters)
        - UserName: Common username format (alphanumeric, dots, hyphens, underscores)
        - DomainName: Valid domain name characters
        - IpAddress: Valid IP address format (IPv4)
        - IpAddressOrFqdn: Valid IPv4 address or FQDN (e.g. ESX host or vCenter name)
        - IpAddressWithCidr: Valid IP address format with CIDR mask (IPv4/subnet)
        - Email: Basic email address format validation
        - lowerCaseRfc1123PortGroup: Valid RFC1123 hostname format (lowercase only)
        - FilePath: Cross-platform file path validation (Windows, Linux, macOS compatible)

        .PARAMETER MinLength
        The minimum required length for the input string. If specified, validation will fail
        if the input is shorter than this value. Defaults to 1 if not specified.

        .PARAMETER MaxLength
        The maximum allowed length for the input string. If specified, validation will fail
        if the input is longer than this value. No maximum limit if not specified.

        .PARAMETER CaseSensitive
        When specified, character validation will be case-sensitive. By default, validation
        is case-insensitive for character set matching. This parameter affects AllowedCharacters,
        DisallowedCharacters, and AcceptableStrings validation but not regular expression patterns.

        .PARAMETER AcceptableStrings
        An array of strings that are considered acceptable input values. When specified,
        the input must exactly match one of the strings in this array for validation to succeed.
        This provides a simple allowlist approach for validating against a predefined set of
        acceptable values. The comparison respects the CaseSensitive parameter.
        Example: @("Development", "Testing", "Production")

        .PARAMETER ValidationLabel
        Optional. Human-readable label for the field used in error messages when PropertyPath is not
        specified (e.g. when validating a direct string). When validation fails, this label is shown
        instead of "input value". Example: "ESX host", "common.vCenterName".

        .OUTPUTS
        System.Boolean
        Returns $true if the input passes all specified validation criteria, or $false if
        any validation rule fails. The function logs detailed information about validation
        failures for troubleshooting purposes.

        .EXAMPLE
        $isValid = Test-JsonPropertyFormat -InputData "MyFileName123" -ValidationPreset "FileName"
        Validates that the input string contains only characters safe for use in file names.

        .EXAMPLE
        $isValid = Test-JsonPropertyFormat -InputData "12345" -ValidationPreset "Numeric"
        Validates that the input string contains only numeric characters (0-9).

        .EXAMPLE
        $isValid = Test-JsonPropertyFormat -InputData $JsonFilePathConfig -PropertyPath "common.vCenterName" -ValidationPreset "DomainName"
        Validates that the vCenter name from JSON configuration follows domain name format rules.

        .EXAMPLE
        $isValid = Test-JsonPropertyFormat -InputData $InputData -PropertyPath "common.esxHost" -ValidationPreset "IpAddressOrDomainNameWithPort"
        Validates that the ESX host property from JSON contains a valid IP address or domain name with optional port.

        .EXAMPLE
        $isValid = Test-JsonPropertyFormat -InputData "ServerName-01" -AllowedCharacters "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_" -MinLength 3 -MaxLength 15
        Validates server name string with specific character allowlist and length constraints.

        .EXAMPLE
        $isValid = Test-JsonPropertyFormat -InputData $config -PropertyPath "datastore.datastoreName" -DisallowedCharacters "<>:\"/\\|?*" -MaxLength 50
        Validates datastore name from JSON by excluding filesystem-unsafe characters with a maximum length limit.

        .EXAMPLE
        $isValid = Test-JsonPropertyFormat -InputData $supervisorConfig -PropertyPath "supervisorComponentSpec.foundationLoadBalancerComponents.flbVipStartIP" -ValidationPreset "IpAddress"
        Validates that the load balancer VIP start IP from JSON is a properly formatted IPv4 address.

        .EXAMPLE
        $isValid = Test-JsonPropertyFormat -InputData "192.168.1.0/24" -ValidationPreset "IpAddressWithCidr"
        Validates that the input string is a properly formatted IPv4 address with CIDR notation (e.g., 192.168.1.0/24).

        .EXAMPLE
        $isValid = Test-JsonPropertyFormat -InputData $esxHost -ValidationPreset "IpAddressOrFqdn" -ValidationLabel "ESX host"
        Validates that an ESX host string is either a valid IPv4 address or FQDN; error messages show "ESX host" as the field name.

        .EXAMPLE
        $isValid = Test-JsonPropertyFormat -InputData "my-domain-name.local" -RegexPattern "^[a-zA-Z0-9][a-zA-Z0-9\-\.]*[a-zA-Z0-9]$" -MinLength 4
        Validates input string against a custom regular expression pattern with minimum length requirement.

        .EXAMPLE
        $isValid = Test-JsonPropertyFormat -InputData $config -PropertyPath "supervisorSpec.controlPlaneSize" -AcceptableStrings @("TINY", "SMALL", "MEDIUM", "LARGE")
        Validates that the control plane size from JSON matches one of the acceptable string values.

        .EXAMPLE
        $isValid = Test-JsonPropertyFormat -InputData "TINY" -AcceptableStrings @("tiny", "small", "medium", "large") -CaseSensitive
        Validates input against acceptable strings with case-sensitive matching.

        .EXAMPLE
        $isValid = Test-JsonPropertyFormat -inputData "C:\Program Files\VMware\vCenter" -validationPreset "FilePath"
        Validates that the input string is a valid cross-platform file path (supports Windows, Linux, and macOS formats).

        .NOTES
        This function provides comprehensive logging of validation attempts and failures for
        troubleshooting purposes. When validation fails, specific details about which criteria
        failed are logged to help identify the issue. The function handles edge cases such as
        empty input, null values, and conflicting validation parameters gracefully.

        The function supports flexible input types:
        - Direct string validation: Pass a string directly to inputData
        - JSON property validation: Pass a JSON object/PSCustomObject to inputData with a propertyPath
        - Hashtable validation: Pass a hashtable to inputData with a propertyPath using dot notation

        Property path navigation supports nested objects using dot notation (e.g., "common.vCenterName"
        or "supervisorSpec.controlPlaneSize"). The function automatically handles PSCustomObject and
        Hashtable property access patterns.

        For security-sensitive applications, consider using the most restrictive validation
        approach appropriate for your use case. allowlist validation (allowedCharacters or
        acceptableStrings) is generally more secure than denylist validation (disallowedCharacters).

        The acceptableStrings parameter provides a simple and secure way to validate against
        a predefined set of acceptable values, which is particularly useful for configuration
        parameters, environment names, or other controlled vocabularies.
    #>

    Param (
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String[]]$AcceptableStrings,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$AllowedCharacters,
        [Parameter(Mandatory = $false)] [Switch]$CaseSensitive,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$DisallowedCharacters,
        [Parameter(Mandatory = $true)] [AllowNull()] [AllowEmptyString()] [Object]$InputData,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 10000)] [Int]$MaxLength,
        [Parameter(Mandatory = $false)] [Double]$MaxValue,
        [Parameter(Mandatory = $false)] [ValidateRange(0, 1000)] [Int]$MinLength,
        [Parameter(Mandatory = $false)] [Double]$MinValue,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [String]$PropertyPath,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [String]$RegexPattern,
        [Parameter(Mandatory = $false)] [ValidateSet("AlphaNumeric", "AlphaNumericDash", "Numeric", "FileName", "UserName", "DomainName", "IpAddress", "IpAddressOrFqdn", "IpAddressWithCidr", "IpAddressOrDomainNameWithPort", "Email", "lowerCaseRfc1123PortGroup", "FilePath", "vSphereObject80Characters", "Url")] [String]$ValidationPreset,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [String]$ValidationLabel
    )

    # Step 1: Extract the property value from input data using helper function.
    # Only call Get-JsonPropertyValue if PropertyPath is provided and not empty
    if ($PropertyPath -and $PropertyPath.Trim() -ne "") {
        $inputText = Get-JsonPropertyValue -InputData $InputData -PropertyPath $PropertyPath
    } else {
        # If no PropertyPath, treat InputData as the value itself
        if ($InputData -is [String]) {
            $inputText = $InputData
        } elseif ($null -eq $InputData) {
            $inputText = $null
        } else {
            $inputText = $InputData.ToString()
        }
    }

    if ($null -eq $inputText) {
        Write-LogMessage -Type ERROR -SuppressOutputToScreen -Message "Input validation failed: Could not extract property value."
        return $false
    }

    # Log the input value being validated for better debugging.
    $pathInfo = if ($PropertyPath) { " for property `"$PropertyPath`"" } else { "" }
    $presetInfo = if ($ValidationPreset) { " using preset `"$ValidationPreset`"" } else { "" }
    Write-LogMessage -Type DEBUG -SuppressOutputToScreen -Message "Validating input value: `"$inputText`"${pathInfo}${presetInfo}."

    # Step 2: Apply validation preset rules if specified.
    if ($ValidationPreset) {
        $presetRules = Get-ValidationPresetRules -ValidationPreset $ValidationPreset

        # Merge preset rules with explicitly provided parameters (explicit parameters take precedence)
        if (-not $AllowedCharacters -and $presetRules.AllowedCharacters) {
            $AllowedCharacters = $presetRules.AllowedCharacters
        }
        if (-not $DisallowedCharacters -and $presetRules.DisallowedCharacters) {
            $DisallowedCharacters = $presetRules.DisallowedCharacters
        }
        if (-not $RegexPattern -and $presetRules.RegexPattern) {
            $RegexPattern = $presetRules.RegexPattern
        }
    }

    # Step 3: Validate against acceptable strings (enumerated values) if specified.
    if ($AcceptableStrings -and $AcceptableStrings.Count -gt 0) {
        $isValid = Test-AcceptableStrings -InputText $inputText -AcceptableStrings $AcceptableStrings -PropertyPath $PropertyPath
        if (-not $isValid) {
            return $false
        }

        # If only acceptable strings validation was requested, return early.

        if (-not $AllowedCharacters -and -not $DisallowedCharacters -and -not $RegexPattern -and -not $MinLength -and -not $MaxLength -and -not $PSBoundParameters.ContainsKey('MinValue') -and -not $PSBoundParameters.ContainsKey('MaxValue')) {
            return $true
        }
    }

    # Step 4: Validate numeric range if specified.
    if ($PSBoundParameters.ContainsKey('MinValue') -or $PSBoundParameters.ContainsKey('MaxValue')) {

        # Build parameter hashtable for Test-NumericRange.
        $numericParams = @{
            InputText = $inputText
            PropertyPath = $PropertyPath
        }
        if ($PSBoundParameters.ContainsKey('MinValue')) {
            $numericParams.MinValue = $MinValue
        }
        if ($PSBoundParameters.ContainsKey('MaxValue')) {
            $numericParams.MaxValue = $MaxValue
        }

        $isValid = Test-NumericRange @numericParams
        if (-not $isValid) {
            return $false
        }
    }

    # Step 5: Validate string length constraints.
    if ($MinLength -and $inputText.Length -lt $MinLength) {
        Write-LogMessage -Type ERROR -Message "Input validation failed: Input length $($inputText.Length) is less than minimum required length $MinLength."
        return $false
    }

    if ($MaxLength -and $inputText.Length -gt $MaxLength) {
        Write-LogMessage -Type ERROR -Message "Input validation failed: Input length $($inputText.Length) exceeds maximum allowed length $MaxLength."
        return $false
    }

    # Step 6: Validate against regular expression pattern if specified.
    if ($RegexPattern) {
        # Use case-sensitive matching for all regex validation.

        if (-not ($inputText -cmatch $RegexPattern)) {
            $presetInfo = if ($ValidationPreset) { " ($ValidationPreset)" } else { "" }
            $fieldDisplay = if ($PropertyPath -and $PropertyPath.Trim() -ne "") { $PropertyPath } elseif ($ValidationLabel -and $ValidationLabel.Trim() -ne "") { $ValidationLabel } else { "input value" }
            Write-LogMessage -Type ERROR -Message "Validation failed for `"$fieldDisplay`" with value `"$inputText`". It does not match the required pattern${presetInfo}: $RegexPattern"
            return $false
        }
    }

    # Step 7: Validate against allowed characters (allowlist) if specified.
    if ($AllowedCharacters) {
        $isValid = Test-StringAgainstAllowlist -InputText $inputText -AllowedCharacters $AllowedCharacters
        if (-not $isValid) {
            return $false
        }
    }

    # Step 8: Validate against disallowed characters (denylist) if specified.
    if ($DisallowedCharacters) {
        $isValid = Test-StringAgainstDenylist -InputText $inputText -DisallowedCharacters $DisallowedCharacters
        if (-not $isValid) {
            return $false
        }
    }

    # All validations passed.
    return $true
}
Function Test-TagCatalogCategory {

    <#
        .SYNOPSIS
        Tests for the existence of a vSphere tag catalog category and creates it if it doesn't exist.

        .DESCRIPTION
        The Test-TagCatalogCategory function checks if a specified tag catalog category exists
        in the connected vCenter. If the tag catalog category is not found, it creates
        a new one with a predefined description for edge-node greenfield deployments.

        This function is designed for greenfield deployments and uses a hardcoded description.
        The function throws a terminating error if any errors occur during the lookup
        or creation process.

        .PARAMETER TagCatalog
        The name of the tag catalog category to test for existence or create.
        This parameter is mandatory and cannot be null or empty.

        .EXAMPLE
        Test-TagCatalogCategory -tagCatalog "EdgeNodePolicy"
        Tests for the existence of the "EdgeNodePolicy" tag catalog category and creates it if it doesn't exist.

        .EXAMPLE
        Test-TagCatalogCategory -tagCatalog $InputData.common.storagePolicy.storagePolicyTagCatalog
        Tests for the tag catalog specified in the input configuration data.

        .NOTES
        - This function requires a valid connection to vCenter via the $Script:vCenterName variable
        - The function uses hardcoded description: "Tag catalog for edge-node greenfield deployment"
        - The function throws a terminating error if errors occur
        - Designed specifically for greenfield deployments; may need revision for brownfield scenarios
        - Uses Write-LogMessage for error logging

        .OUTPUTS
        None. This function does not return any objects but may create a new tag catalog category.

        .LINK
        Get-TagCategory
        New-TagCategory
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$TagCatalog
    )

    Write-LogMessage -Type DEBUG -Message "Entered Test-TagCatalogCategory function..."

    $connectionTest = Test-VcenterConnection
    if (-not $connectionTest.IsConnected) {
        Write-LogMessage -Type ERROR -Message "Not connected to vCenter `"$Script:vCenterName`": $($connectionTest.ErrorMessage)"
        throw [VcfDeploymentException]::new("Not connected to vCenter `"$Script:vCenterName`": $($connectionTest.ErrorMessage)")
    }

    try {
        $tagFoundCategory = Get-TagCategory -Name $TagCatalog -Server $Script:vCenterName -ErrorAction SilentlyContinue
    } catch {
        Write-LogMessage -Type DEBUG -Message "Error retrieving tag category `"$TagCatalog`" (non-critical): $($_.Exception.Message)"
    }

    if (-not $tagFoundCategory) {
        # Hard coded description for the tag category assuming greenfield. Can revisit for non-greenfield.
        try {
            New-TagCategory -Name $TagCatalog -Description "Tag catalog for edge-node greenfield deployment" -Server $Script:vCenterName -Confirm:$false -ErrorAction Stop | Out-Null
            Write-LogMessage -Type INFO -Message "Successfully created tag catalog `"$TagCatalog`" on `"$Script:vCenterName`"."
        } catch {
            $errorMessage = $_.Exception.Message

            # Check for SSO authentication failure which is commonly caused by clock sync issues.

            if ($errorMessage -match "vSphere single sign-on failed for connection") {
                Write-LogMessage -Type ERROR -Message "Error creating tag catalog `"$TagCatalog`" on `"$Script:vCenterName`": SSO authentication failure."
                Write-LogMessage -Type ERROR -Message "This is commonly caused by clock synchronization issues between the client and vCenter Server."
                Write-LogMessage -Type ERROR -Message "Troubleshooting steps:"
                Write-LogMessage -Type ERROR -Message "  1. Verify NTP is configured and synchronized on this host (client)."
                Write-LogMessage -Type ERROR -Message "  2. Verify NTP is configured and synchronized on vCenter Server `"$Script:vCenterName`"."
                Write-LogMessage -Type ERROR -Message "  3. Check that time drift is less than 5 minutes between client and vCenter."
                Write-LogMessage -Type ERROR -Message "Full error details: $errorMessage"
            } else {
                Write-LogMessage -Type ERROR -Message "Error creating tag catalog `"$TagCatalog`" on `"$Script:vCenterName`": $errorMessage"
            }
            throw [VcfDeploymentException]::new("Error creating tag catalog `"$TagCatalog`" on `"$Script:vCenterName`": $errorMessage")
        }

    } else {
        Write-LogMessage -Type INFO -Message "Tag catalog `"$TagCatalog`" already exists on vCenter `"$Script:vCenterName`". Skipping tag catalog creation."
    }
}
Function Test-Tag {

    <#
        .SYNOPSIS
        Tests for the existence of a vSphere tag within a specified tag catalog category and creates it if it doesn't exist.

        .DESCRIPTION
        The Test-Tag function checks if a specified tag exists within a given tag catalog category
        in the connected vCenter. If the tag is not found, it creates a new tag with a
        predefined description for edge-node greenfield deployments.

        This function is designed for greenfield deployments and uses a hardcoded description.
        The function throws a terminating error if any errors occur during the lookup
        or creation process.

        .PARAMETER TagCatalog
        The name of the tag catalog category that should contain the tag.
        This parameter is mandatory and cannot be null or empty.

        .PARAMETER TagName
        The name of the tag to test for existence or create within the specified tag catalog category.
        This parameter is mandatory and cannot be null or empty.

        .EXAMPLE
        Test-Tag -tagCatalog "EdgeNodePolicy" -tagName "SupervisorCluster01"
        Tests for the existence of the "SupervisorCluster01" tag in the "EdgeNodePolicy" catalog category
        and creates it if it doesn't exist.

        .EXAMPLE
        Test-Tag -tagCatalog $storagePolicyTagCatalog -tagName $SupervisorName
        Tests for the tag specified by variables, commonly used with configuration data.

        .NOTES
        - This function requires a valid connection to vCenter via the $Script:vCenterName variable
        - The function uses hardcoded description: "New Tag for supervisor instance {tagName} for edge-node greenfield deployment"
        - The function throws a terminating error if errors occur during tag catalog lookup or tag creation
        - Designed specifically for greenfield deployments; may need revision for brownfield scenarios
        - Uses Write-LogMessage for error logging
        - The tag catalog category must exist before calling this function (use Test-TagCatalogCategory first)

        .OUTPUTS
        None. This function does not return any output but may create a new tag if it doesn't exist.

        .LINK
        Test-TagCatalogCategory
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$TagCatalog,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$TagName
    )

    Write-LogMessage -Type DEBUG -Message "Entered Test-Tag function..."

    $connectionTest = Test-VcenterConnection
    if (-not $connectionTest.IsConnected) {
        Write-LogMessage -Type ERROR -Message "Not connected to vCenter `"$Script:vCenterName`": $($connectionTest.ErrorMessage)"
        throw [VcfDeploymentException]::new("Not connected to vCenter `"$Script:vCenterName`": $($connectionTest.ErrorMessage)")
    }

    # Create tagCategoy object.
    try {
        $tagCatalogObject = Get-TagCategory -Name $TagCatalog -Server $Script:vCenterName -ErrorAction SilentlyContinue}
    catch {
        Write-LogMessage -Type ERROR -Message "Error looking up tag catalog `"$TagCatalog`" on vCenter `"$Script:vCenterName`" $($_.Exception.Message)"
        throw [VcfDeploymentException]::new("Error looking up tag catalog `"$TagCatalog`" on vCenter `"$Script:vCenterName`" $($_.Exception.Message)")
    }

    # Look to see if tag has already been created.
    try {
        $foundTagName = Get-Tag -Name $TagName -Category $tagCatalogObject -Server $Script:vCenterName -ErrorAction SilentlyContinue
    } catch [VcfDeploymentException] {
        throw  # already logged and typed — propagate without re-wrapping
    } catch {
        Write-LogMessage -Type ERROR -Message "Error looking up tag `"$TagName`" in tag catalog `"$TagCatalog`" on vCenter `"$Script:vCenterName`" $($_.Exception.Message)"
        throw [VcfDeploymentException]::new("Error looking up tag `"$TagName`" in tag catalog `"$TagCatalog`" on vCenter `"$Script:vCenterName`" $($_.Exception.Message)")
    }

    # If tag has not been created, create it.
    if (-not $foundTagName) {
        try {
            $tagCategoryObject = Get-TagCategory $tagCatalogObject -ErrorAction Stop
            $taskId = New-Tag -Name $TagName -Category $tagCategoryObject -Description "New Tag for supervisor instance $TagName for edge-node greenfield deployment" -Server $Script:vCenterName -Confirm:$false -ErrorAction Stop
            Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "New Tag creation TaskId: $($taskId.Value)"
            Write-LogMessage -Type INFO -Message "Successfully created tag name `"$TagName`" on `"$TagCatalog`"."
        } catch [VcfDeploymentException] {
            throw  # already logged and typed — propagate without re-wrapping
        } catch {
            Write-LogMessage -Type ERROR -Message "Error creating tag name `"$TagName`" on `"$TagCatalog`": $($_.Exception.Message)"
            throw [VcfDeploymentException]::new("Error creating tag name `"$TagName`" on `"$TagCatalog`": $($_.Exception.Message)")
        }
    } else {
        Write-LogMessage -Type INFO -Message "Tag name `"$TagName`" already exists on `"$TagCatalog`". Skipping tag creation."
    }
}
#Test-JsonDeeperValidation Helper Functions
Function Test-ValidIPv4Address {
    <#
        .SYNOPSIS
        Returns $true when the supplied string is a valid dotted-decimal IPv4 address; $false otherwise.
        .PARAMETER IpAddress
        The string to test. Null, empty, and whitespace-only values return $false.
    #>
    Param ([Parameter(Mandatory = $false)] [String]$IpAddress = "")
    if ([String]::IsNullOrWhiteSpace($IpAddress)) { return $false }
    return $IpAddress -match '^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$'
}
Function Test-ValidNetmask {
    <#
        .SYNOPSIS
        Returns $true when the supplied string is a valid contiguous IPv4 subnet mask (e.g. 255.255.255.0); $false otherwise.
        .DESCRIPTION
        A valid netmask must be a dotted-decimal IPv4 address whose binary representation is all 1s followed by all 0s (contiguous).
        .PARAMETER Netmask
        The string to test. Null, empty, whitespace-only, and non-contiguous masks return $false.
    #>
    Param ([Parameter(Mandatory = $false)] [String]$Netmask = "")
    if ([String]::IsNullOrWhiteSpace($Netmask)) { return $false }
    if (-not (Test-ValidIPv4Address -IpAddress $Netmask)) { return $false }
    $octets = $Netmask -split '\.'
    if ($octets.Count -ne 4) { return $false }
    $binary = ($octets | ForEach-Object { [Convert]::ToString([int]$_, 2).PadLeft(8, '0') }) -join ''
    if ($binary -notmatch '^1*0*$') { return $false }
    return $true
}
Function Test-IpInSubnet {
    <#
        .SYNOPSIS
        Returns $true when IpAddress falls within the subnet defined by ReferenceIp and SubnetMask.
        .PARAMETER IpAddress
        The IP address to test.
        .PARAMETER ReferenceIp
        Any IP address within the reference subnet (typically the network address or gateway).
        .PARAMETER SubnetMask
        The subnet mask in dotted-decimal notation (e.g. 255.255.255.0).
        .OUTPUTS
        [Boolean] $false when any argument is an invalid IPv4 address or netmask.
    #>
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$IpAddress,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ReferenceIp,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SubnetMask
    )
    if (-not (Test-ValidIPv4Address -IpAddress $IpAddress) -or -not (Test-ValidIPv4Address -IpAddress $ReferenceIp) -or -not (Test-ValidNetmask -Netmask $SubnetMask)) {
        return $false
    }
    $ipOctets = $IpAddress -split '\.' | ForEach-Object { [int]$_ }
    $refOctets = $ReferenceIp -split '\.' | ForEach-Object { [int]$_ }
    $maskOctets = $SubnetMask -split '\.' | ForEach-Object { [int]$_ }
    $ipInt = 0; foreach ($octet in $ipOctets) { $ipInt = ($ipInt -shl 8) + $octet }
    $refInt = 0; foreach ($octet in $refOctets) { $refInt = ($refInt -shl 8) + $octet }
    $maskInt = 0; foreach ($octet in $maskOctets) { $maskInt = ($maskInt -shl 8) + $octet }
    return ($ipInt -band $maskInt) -eq ($refInt -band $maskInt)
}
Function Test-TcpPortReachable {
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$IpAddress,
        [Parameter(Mandatory = $false)] [int]$Port = 443,
        [Parameter(Mandatory = $false)] [int]$TimeoutMilliseconds = 3000
    )
    $tcpClient = $null
    try {
        $tcpClient = New-Object System.Net.Sockets.TcpClient
        $asyncResult = $tcpClient.BeginConnect($IpAddress, $Port, $null, $null)
        $waitResult = $asyncResult.AsyncWaitHandle.WaitOne($TimeoutMilliseconds, $false)
        if (-not $waitResult) {
            $tcpClient.Close()
            return $false
        }
        try { $tcpClient.EndConnect($asyncResult) } catch { $tcpClient.Close(); return $false }
        $tcpClient.Close()
        return $true
    } catch {
        if ($tcpClient) { $tcpClient.Close() }
        return $false
    }
}
Function Test-VcenterAndEsxReachability {

    <#
        .SYNOPSIS
        Verifies TCP port reachability for vCenter and a list of ESX hosts; throws if any target is unreachable.

        .DESCRIPTION
        Used by Initialize-VcfEdgeAtScale to fail fast before credential prompts when vCenter or ESX hosts are unreachable on the given port (default 443).
        .PARAMETER VcenterName
        vCenter hostname or IP to test.
        .PARAMETER EsxHosts
        Array of ESX hostnames or IPs to test (may be empty).
        .PARAMETER Port
        TCP port to test. Default 443.
        .NOTES
        Logs DEBUG per target; throws with a clear message listing unreachable targets.
    #>

    Param (
        [Parameter(Mandatory = $false)] [String[]]$EsxHosts = @(),
        [Parameter(Mandatory = $false)] [ValidateRange(1, 65535)] [int]$Port = 443,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VcenterName
    )
    $failedTargets = @()
    $vcenterReachable = Test-TcpPortReachable -IpAddress $VcenterName -Port $Port
    if (-not $vcenterReachable) {
        $failedTargets += "vCenter `"$VcenterName`""
    }
    Write-LogMessage -Type DEBUG -Message "Reachability (TCP $Port): vCenter `"$VcenterName`": $(if ($vcenterReachable) { 'OK' } else { 'unreachable' })."
    foreach ($esx in $EsxHosts) {
        if ([String]::IsNullOrWhiteSpace($esx)) { continue }
        $esxReachable = Test-TcpPortReachable -IpAddress $esx -Port $Port
        if (-not $esxReachable) {
            $failedTargets += "ESX `"$esx`""
        }
        Write-LogMessage -Type DEBUG -Message "Reachability (TCP $Port): ESX `"$esx`": $(if ($esxReachable) { 'OK' } else { 'unreachable' })."
    }
    if ($failedTargets.Count -gt 0) {
        Write-LogMessage -Type ERROR -Message "Reachability failed: $($failedTargets -join '; '). Ensure targets are powered on and port $Port is open, then retry."
        throw [VcfDeploymentException]::new("Reachability check failed. $($failedTargets.Count) target(s) unreachable (TCP $Port): $($failedTargets -join ', '). Check logs and retry.")
    }
    $reachSummary = if ($EsxHosts.Count -eq 0) { "vCenter OK" } else { "all targets OK (vCenter and $($EsxHosts.Count) ESX host(s))" }
    Write-LogMessage -Type INFO -Message "Reachability: $reachSummary."
}
Function Test-JsonNetworkingVmKernelAndTemporaryIp {
    <#
        .SYNOPSIS
        Validates networking.networkingVmKernelInterfaces and VLAN IDs for each cluster in a deep-validation pass.
        .DESCRIPTION
        Checks that each cluster's networkSegments have valid vlanId values (0-4095), that vSAN-ESA and vSAN-OSA
        clusters declare at least vMotion and vSAN VMkernel interfaces, that interface service names are from the
        allowed set (vMotion, vSAN, vSAN Witness), and that temporary management IP fields are properly formed when present.
        .PARAMETER ClustersToValidate
        Array of cluster objects from the parsed infrastructure JSON.
        .OUTPUTS
        [Int] Number of validation failures found. 0 = all checks passed.
    #>
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSCustomObject[]]$ClustersToValidate
    )
    $validationFailures = 0
    $allowedServices = @("vMotion", "vSAN", "vSAN Witness")
    foreach ($cluster in $ClustersToValidate) {
        $currentEdgeSite = $cluster.edgeSite
        $networking = $cluster.networking
        if (-not $networking) { continue }

        if ($networking.networkSegments) {
            foreach ($segment in $networking.networkSegments) {
                $vlanIdStr = $segment.vlanId
                if ($null -ne $vlanIdStr) {
                    $vlanId = $vlanIdStr -as [int]
                    if ($null -eq $vlanId -or $vlanId -lt 0 -or $vlanId -gt 4095) {
                        Write-LogMessage -Type ERROR -Message "Cluster `"$currentEdgeSite`" networking.networkSegments has invalid vlanId `"$vlanIdStr`". Must be 0-4095 inclusive."
                        $validationFailures++
                    }
                }
            }
        }

        # networkingVmKernelInterfaces is mandatory only for vSAN-ESA and vSAN-OSA (not VMFS).
        $storageType = $cluster.storagePolicy.storageType
        $requireVmKernelInterfaces = ($storageType -eq "vSAN-ESA" -or $storageType -eq "vSAN-OSA")
        $vmKernelIfs = $networking.networkingVmKernelInterfaces
        if (-not $requireVmKernelInterfaces) {
            if ($vmKernelIfs -and $vmKernelIfs.Count -gt 0) {
                Write-LogMessage -Type DEBUG -Message "Cluster `"$currentEdgeSite`" has networkingVmKernelInterfaces but storage type is `"$storageType`"; validating format only."
            }
        } elseif (-not $vmKernelIfs -or $vmKernelIfs.Count -eq 0) {
            Write-LogMessage -Type ERROR -Message "Cluster `"$currentEdgeSite`" storage type is `"$storageType`"; networking.networkingVmKernelInterfaces is required (at least vMotion and vSAN; vSAN Witness optional)."
            $validationFailures++
        }
        if (-not $vmKernelIfs -or $vmKernelIfs.Count -eq 0) { continue }

        if ($vmKernelIfs.Count -lt 2) {
            Write-LogMessage -Type ERROR -Message "Cluster `"$currentEdgeSite`" networking.networkingVmKernelInterfaces must contain at least two entries (vMotion, vSAN). Found $($vmKernelIfs.Count)."
            $validationFailures++
        }
        $serviceNamesSeen = @()
        foreach ($vmk in $vmKernelIfs) {
            $service = $vmk.service
            if ([String]::IsNullOrWhiteSpace($service)) {
                Write-LogMessage -Type ERROR -Message "Cluster `"$currentEdgeSite`" networking.networkingVmKernelInterfaces has an entry with missing or empty service."
                $validationFailures++
            } else {
                $serviceNormalized = $service.Trim()
                $canonical = $allowedServices | Where-Object { $_ -eq $serviceNormalized } | Select-Object -First 1
                if (-not $canonical) {
                    Write-LogMessage -Type ERROR -Message "Cluster `"$currentEdgeSite`" networking.networkingVmKernelInterfaces has invalid service `"$service`". Allowed: vMotion, vSAN, vSAN Witness."
                    $validationFailures++
                } else {
                    $serviceNamesSeen += $canonical
                }
            }

            if ($null -ne $vmk.vlanId) {
                $vlanId = $vmk.vlanId -as [int]
                if ($null -eq $vlanId -or $vlanId -lt 0 -or $vlanId -gt 4095) {
                    Write-LogMessage -Type ERROR -Message "Cluster `"$currentEdgeSite`" networking.networkingVmKernelInterfaces entry (service `"$($vmk.service)`") has invalid vlanId. Must be 0-4095 inclusive."
                    $validationFailures++
                }
            }

            if ($vmk.PSObject.Properties["netmask"] -and -not [String]::IsNullOrWhiteSpace($vmk.netmask)) {
                if (-not (Test-ValidNetmask -Netmask $vmk.netmask)) {
                    Write-LogMessage -Type ERROR -Message "Cluster `"$currentEdgeSite`" networking.networkingVmKernelInterfaces entry (service `"$($vmk.service)`") has invalid netmask `"$($vmk.netmask)`"."
                    $validationFailures++
                }
            }

            $ipList = $vmk.ipList
            if (-not $ipList -or $ipList -isnot [Array]) {
                Write-LogMessage -Type ERROR -Message "Cluster `"$currentEdgeSite`" networking.networkingVmKernelInterfaces entry (service `"$($vmk.service)`") must have ipList as an array."
                $validationFailures++
            } else {
                if ($ipList.Count -ne 2) {
                    Write-LogMessage -Type ERROR -Message "Cluster `"$currentEdgeSite`" networking.networkingVmKernelInterfaces entry (service `"$($vmk.service)`") ipList must contain exactly two entries (found $($ipList.Count))."
                    $validationFailures++
                } else {
                    $ip0 = if ($ipList[0] -is [String]) { $ipList[0].Trim() } else { [String]$ipList[0] }
                    $ip1 = if ($ipList[1] -is [String]) { $ipList[1].Trim() } else { [String]$ipList[1] }
                    if (-not (Test-ValidIPv4Address -IpAddress $ip0)) {
                        Write-LogMessage -Type ERROR -Message "Cluster `"$currentEdgeSite`" networking.networkingVmKernelInterfaces entry (service `"$($vmk.service)`") ipList[0] `"$ip0`" is not a valid IPv4 address."
                        $validationFailures++
                    }
                    if (-not (Test-ValidIPv4Address -IpAddress $ip1)) {
                        Write-LogMessage -Type ERROR -Message "Cluster `"$currentEdgeSite`" networking.networkingVmKernelInterfaces entry (service `"$($vmk.service)`") ipList[1] `"$ip1`" is not a valid IPv4 address."
                        $validationFailures++
                    }
                    if ($ip0 -eq $ip1) {
                        Write-LogMessage -Type ERROR -Message "Cluster `"$currentEdgeSite`" networking.networkingVmKernelInterfaces entry (service `"$($vmk.service)`") ipList entries must be unique."
                        $validationFailures++
                    }
                }
            }
        }

        $requiredServices = @("vMotion", "vSAN")
        foreach ($req in $requiredServices) {
            if ($serviceNamesSeen -notcontains $req) {
                Write-LogMessage -Type ERROR -Message "Cluster `"$currentEdgeSite`" networking.networkingVmKernelInterfaces must contain vMotion and vSAN. Missing: $req."
                $validationFailures++
            }
        }
        # When vSAN Witness is present, gateway is required on that entry only (VMkernel interfaces are not configured with a gateway by the script).
        foreach ($vmk in $vmKernelIfs) {
            $svc = if ($vmk.service) { [string]$vmk.service.Trim() } else { "" }
            if ($svc -eq "vSAN Witness" -and ($null -eq $vmk.PSObject.Properties["gateway"] -or [String]::IsNullOrWhiteSpace($vmk.gateway))) {
                Write-LogMessage -Type ERROR -Message "Cluster `"$currentEdgeSite`" networking.networkingVmKernelInterfaces entry for service `"vSAN Witness`" must have gateway (VMkernel interfaces are not configured with a gateway; gateway is for validation/documentation)."
                $validationFailures++
            }
        }
    }
    return $validationFailures
}
Function Test-JsonPrefixFormats {

    <#
        .SYNOPSIS
        Validates prefix format properties in infrastructure JSON.

        .DESCRIPTION
        Validates that all prefix properties (clusterNamePrefix, datastoreNamePrefix, vdsNamePrefix, supervisorNamePrefix) conform to vSphere object naming requirements (80 characters max).

        .PARAMETER InputData
        The parsed infrastructure JSON data object.

        .OUTPUTS
        [Int] The number of validation failures found.
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSCustomObject]$InputData
    )

    $validationFailures = 0

    Write-LogMessage -Type DEBUG -Message "Validating prefix formats in infrastructure JSON (only when defined)..."
    $prefixProperties = @(
        "common.clusterNamePrefix",
        "common.datastoreNamePrefix",
        "common.vdsNamePrefix",
        "common.supervisorNamePrefix"
    )
    foreach ($prefixProperty in $prefixProperties) {
        $value = Get-JsonPropertyValue -InputData $InputData -PropertyPath $prefixProperty
        if ($null -ne $value -and -not [String]::IsNullOrWhiteSpace($value)) {
            $isValid = Test-JsonPropertyFormat -InputData $InputData -PropertyPath $prefixProperty -ValidationPreset "vSphereObject80Characters"
            if (-not $isValid) {
                $validationFailures++
            }
        }
    }

    return $validationFailures
}
Function Test-JsonNetworkSegmentGateways {

    <#
        .SYNOPSIS
        Validates network segment gateways and network name matching per cluster.

        .DESCRIPTION
        Validates that network segment gateways are in correct IP address with CIDR format, and that supervisor network names exist in infrastructure network segments (case-sensitive matching).

        .PARAMETER ClustersToValidate
        Array of cluster objects to validate.

        .PARAMETER SupervisorData
        The parsed supervisor JSON data object.

        .OUTPUTS
        [Int] The number of validation failures found.
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Array]$ClustersToValidate,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSCustomObject]$SupervisorData
    )

    $validationFailures = 0

    foreach ($cluster in $ClustersToValidate) {
        $currentEdgeSite = $cluster.edgeSite
        if (-not $currentEdgeSite) {
            Write-LogMessage -Type ERROR -Message "Cluster is missing edgeSite identifier."
            $validationFailures++
            continue
        }

        # Find matching supervisor site spec.
        $matchingSiteSpec = $SupervisorData.siteSpec | Where-Object { $_.edgeSite -eq $currentEdgeSite } | Select-Object -First 1
        if (-not $matchingSiteSpec) {
            Write-LogMessage -Type ERROR -Message "No matching supervisor site spec found for edgeSite '$currentEdgeSite'."
            $validationFailures++
            continue
        }

        # Validate network segment gateways.
        if ($cluster.networking -and $cluster.networking.networkSegments) {
            foreach ($networkSegment in $cluster.networking.networkSegments) {
                if ($networkSegment.gateway) {
                    $isValid = Test-JsonPropertyFormat -InputData $networkSegment -PropertyPath "gateway" -ValidationPreset "IpAddressWithCidr"
                    if (-not $isValid) {
                        Write-LogMessage -Type ERROR -Message "Invalid gateway format for network segment '$($networkSegment.name)' in cluster '$currentEdgeSite': $($networkSegment.gateway)"
                        $validationFailures++
                    }
                } else {
                    Write-LogMessage -Type ERROR -Message "Network segment '$($networkSegment.name)' in cluster '$currentEdgeSite' is missing gateway."
                    $validationFailures++
                }
            }
        }

        # Validate that supervisor network names exist in infrastructure network segments (case-sensitive).
        $vksNetworks = @()
        if ($matchingSiteSpec.mgmtNetworkSpec -and $matchingSiteSpec.mgmtNetworkSpec.mgmtNetworkName) {
            $vksNetworks += $matchingSiteSpec.mgmtNetworkSpec.mgmtNetworkName
        }
        if ($matchingSiteSpec.foundationLoadBalancerComponents -and $matchingSiteSpec.foundationLoadBalancerComponents.flbManagementNetwork -and $matchingSiteSpec.foundationLoadBalancerComponents.flbManagementNetwork.flbNetworkName) {
            $vksNetworks += $matchingSiteSpec.foundationLoadBalancerComponents.flbManagementNetwork.flbNetworkName
        }
        if ($matchingSiteSpec.primaryWorkloadNetwork -and $matchingSiteSpec.primaryWorkloadNetwork.primaryWorkloadNetworkName) {
            $vksNetworks += $matchingSiteSpec.primaryWorkloadNetwork.primaryWorkloadNetworkName
        }
        if ($matchingSiteSpec.foundationLoadBalancerComponents -and $matchingSiteSpec.foundationLoadBalancerComponents.flbVirtualServerNetwork -and $matchingSiteSpec.foundationLoadBalancerComponents.flbVirtualServerNetwork.flbNetworkName) {
            $vksNetworks += $matchingSiteSpec.foundationLoadBalancerComponents.flbVirtualServerNetwork.flbNetworkName
        }

        # Check if each VKS network exists in infrastructure network segments (case-sensitive matching).
        if ($cluster.networking -and $cluster.networking.networkSegments) {
            foreach ($vksNetwork in $vksNetworks) {
                $foundNetwork = $false
                foreach ($networkSegment in $cluster.networking.networkSegments) {
                    if ($vksNetwork -ceq $networkSegment.name) {
                        $foundNetwork = $true
                        break
                    }
                }
                if (-not $foundNetwork) {
                    Write-LogMessage -Type ERROR -Message "VKS network `"$vksNetwork`" in supervisor JSON (edgeSite: $currentEdgeSite) does not exist in infrastructure JSON network segments (case-sensitive matching)."
                    $validationFailures++
                }
            }
        }
    }

    return $validationFailures
}
Function Test-JsonStoragePolicyFormats {
    <#
        .SYNOPSIS
        Validates storage policy format properties per cluster.

        .DESCRIPTION
        Validates that storage policy tag catalog and name properties conform to vSphere object naming requirements (80 characters max).

        .PARAMETER ClustersToValidate
        Array of cluster objects to validate.

        .OUTPUTS
        [Int] The number of validation failures found.
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Array]$ClustersToValidate
    )

    $validationFailures = 0

    foreach ($cluster in $ClustersToValidate) {
        $currentEdgeSite = $cluster.edgeSite
        if ($cluster.storagePolicy) {
            $storagePolicyTagCatalog = $cluster.storagePolicy.storagePolicyTagCatalog
            if ($storagePolicyTagCatalog) {
                $isValid = Test-JsonPropertyFormat -InputData $storagePolicyTagCatalog -ValidationPreset "vSphereObject80Characters"
                if (-not $isValid) {
                    Write-LogMessage -Type ERROR -Message "Invalid storagePolicyTagCatalog format in cluster '$currentEdgeSite'."
                    $validationFailures++
                }
            }
            $storagePolicyName = $cluster.storagePolicy.storagePolicyName
            if ($storagePolicyName) {
                $isValid = Test-JsonPropertyFormat -InputData $storagePolicyName -ValidationPreset "vSphereObject80Characters"
                if (-not $isValid) {
                    Write-LogMessage -Type ERROR -Message "Invalid storagePolicyName format in cluster '$currentEdgeSite'."
                    $validationFailures++
                }
            }
        }
    }

    return $validationFailures
}
Function Test-JsonNumericPropertiesWithRanges {
    <#
        .SYNOPSIS
        Validates numeric properties with minimum value requirements per site.

        .DESCRIPTION
        Validates that numeric properties (IP counts, VIP counts) meet their minimum value requirements.

        .PARAMETER SiteSpecsToValidate
        Array of site specification objects to validate.

        .OUTPUTS
        [Int] The number of validation failures found.
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Array]$SiteSpecsToValidate
    )

    $validationFailures = 0

    foreach ($siteSpec in $SiteSpecsToValidate) {
        $currentEdgeSite = $siteSpec.edgeSite
        $numericPropertiesWithRanges = @(
            @{Path = "foundationLoadBalancerComponents.flbVipIPCount"; Min = 1; SiteSpec = $siteSpec},
            @{Path = "foundationLoadBalancerComponents.flbManagementNetwork.flbNetworkIpAddressCount"; Min = 2; SiteSpec = $siteSpec},
            @{Path = "mgmtNetworkSpec.mgmtNetworkIPCount"; Min = 5; SiteSpec = $siteSpec},
            @{Path = "primaryWorkloadNetwork.primaryWorkloadNetworkIPCount"; Min = 2; SiteSpec = $siteSpec}
        )

        foreach ($prop in $numericPropertiesWithRanges) {
            $propertyValue = Get-JsonPropertyValue -InputData $prop.SiteSpec -PropertyPath $prop.Path
            if ($null -ne $propertyValue) {
                $params = @{
                    InputData = $propertyValue
                    ValidationPreset = "Numeric"
                    MinValue = $prop.Min
                }
                $isValid = Test-JsonPropertyFormat @params
                if (-not $isValid) {
                    Write-LogMessage -Type ERROR -Message "Invalid numeric value for property `"$($prop.Path)`" in edgeSite `"$currentEdgeSite`"."
                    $validationFailures++
                }
            }
        }
    }

    return $validationFailures
}
Function Test-JsonLbVirtualServerIpCount {

    <#
        .SYNOPSIS
        Warns when the LB virtual server network IP count is below the recommended minimum.

        .DESCRIPTION
        For each site, reads foundationLoadBalancerComponents.flbVirtualServerNetwork.flbNetworkIpAddressCount
        and emits a WARNING when the value is below 20. The check never fails validation; it is advisory only.
        The exact number of IPs required depends on which services are deployed, but fewer than 20 may not
        be sufficient to deploy all services.

        .PARAMETER ClustersToValidate
        Unused; retained for call-site compatibility.

        .PARAMETER InputData
        Unused; retained for call-site compatibility.

        .PARAMETER SiteSpecsToValidate
        Array of site specification objects from the supervisor JSON.

        .OUTPUTS
        [Int] Always returns 0 (warnings do not count as failures).
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Array]$ClustersToValidate,
        [Parameter(Mandatory = $true)] [AllowNull()] [PSObject]$InputData,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Array]$SiteSpecsToValidate
    )

    $floatingIpWarningThreshold = 20
    $propertyPath = "foundationLoadBalancerComponents.flbVirtualServerNetwork.flbNetworkIpAddressCount"

    foreach ($siteSpec in $SiteSpecsToValidate) {
        $currentEdgeSite = $siteSpec.edgeSite
        $propertyValue = Get-JsonPropertyValue -InputData $siteSpec -PropertyPath $propertyPath
        if ($null -ne $propertyValue) {
            $ipCount = [Int]$propertyValue
            if ($ipCount -lt $floatingIpWarningThreshold) {
                Write-LogMessage -Type WARNING -Message "LB virtual server network IP count for edgeSite `"$currentEdgeSite`" is $ipCount. Fewer than $floatingIpWarningThreshold floating IPs may not be enough to deploy all services. Consider increasing $propertyPath."
            }
        }
    }

    return 0
}
Function Test-JsonRfc1123NetworkNames {

    <#
        .SYNOPSIS
        Validates that network names conform to RFC1123 format per site.

        .DESCRIPTION
        Validates that supervisor network names (FLB management, FLB virtual server, supervisor management, primary workload) conform to lowercase RFC1123 hostname format for WCP compliance.

        .PARAMETER SiteSpecsToValidate
        Array of site specification objects to validate.

        .OUTPUTS
        [Int] The number of validation failures found.
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Array]$SiteSpecsToValidate
    )

    $validationFailures = 0

    foreach ($siteSpec in $SiteSpecsToValidate) {
        $currentEdgeSite = $siteSpec.edgeSite
        $vksNetworkNameProperties = @(
            @{Path = "foundationLoadBalancerComponents.flbManagementNetwork.flbNetworkName"; SiteSpec = $siteSpec},
            @{Path = "foundationLoadBalancerComponents.flbVirtualServerNetwork.flbNetworkName"; SiteSpec = $siteSpec},
            @{Path = "primaryWorkloadNetwork.primaryWorkloadNetworkName"; SiteSpec = $siteSpec},
            @{Path = "mgmtNetworkSpec.mgmtNetworkName"; SiteSpec = $siteSpec}
        )
        foreach ($vksNetworkNameProperty in $vksNetworkNameProperties) {
            $networkName = Get-JsonPropertyValue -InputData $vksNetworkNameProperty.SiteSpec -PropertyPath $vksNetworkNameProperty.Path
            if ($null -ne $networkName) {
                $isValid = Test-JsonPropertyFormat -InputData $networkName -ValidationPreset "lowerCaseRfc1123PortGroup"
                if (-not $isValid) {
                    Write-LogMessage -Type ERROR -Message "Network name `"$networkName`" in edgeSite `"$currentEdgeSite`" does not conform to RFC1123 format."
                    $validationFailures++
                }
            }
        }
    }

    return $validationFailures
}
Function Test-JsonRfc1123NetworkSegments {
    <#
        .SYNOPSIS
        Validates that network segment names conform to RFC1123 format.

        .DESCRIPTION
        Validates that all network segment names in clusters conform to lowercase RFC1123 format (lowercase alphanumeric with hyphens, max 80 chars) for WCP/Kubernetes compatibility.

        .PARAMETER ClustersToValidate
        Array of cluster objects to validate.

        .OUTPUTS
        [Int] The number of validation failures found.
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Array]$ClustersToValidate
    )

    $validationFailures = 0

    # Pattern validates: lowercase letters, numbers, hyphens (not at start/end), max 80 chars.
    $lowerCaseRfc1123RegexPattern = '^(?=.{1,80}$)[a-z0-9]([-a-z0-9]*[a-z0-9])?$'

    foreach ($cluster in $ClustersToValidate) {
        $currentEdgeSite = $cluster.edgeSite
        if ($cluster.networking -and $cluster.networking.networkSegments) {
            foreach ($networkSegment in $cluster.networking.networkSegments) {
                if ($networkSegment.name -cnotmatch $lowerCaseRfc1123RegexPattern) {
                    Write-LogMessage -Type ERROR -Message "Network segment name `"$($networkSegment.name)`" in cluster '$currentEdgeSite' does not conform to RFC1123 (lowercase alphanumeric with hyphens only)."
                    $validationFailures++
                }
            }
        }
    }

    return $validationFailures
}
Function Test-JsonRfc1123VmClassNames {

    <#
        .SYNOPSIS
        Validates that VM class names conform to RFC1123 format per cluster.

        .DESCRIPTION
        Validates that VM class names conform to lowercase RFC1123 format for Kubernetes compatibility.

        .PARAMETER ClustersToValidate
        Array of cluster objects to validate.

        .OUTPUTS
        [Int] The number of validation failures found.
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Array]$ClustersToValidate
    )

    $validationFailures = 0

    # Pattern validates: lowercase letters, numbers, hyphens (not at start/end), max 80 chars.
    $lowerCaseRfc1123RegexPattern = '^(?=.{1,80}$)[a-z0-9]([-a-z0-9]*[a-z0-9])?$'

    foreach ($cluster in $ClustersToValidate) {
        $currentEdgeSite = $cluster.edgeSite
        if ($cluster.supervisorServices -and $cluster.supervisorServices.vmClass) {
            $vmClassValue = $cluster.supervisorServices.vmClass
            $vmClassList = if ($vmClassValue -is [Array]) { $vmClassValue } else { @($vmClassValue) }

            foreach ($vmClassName in $vmClassList) {
                if ($vmClassName -cnotmatch $lowerCaseRfc1123RegexPattern) {
                    Write-LogMessage -Type ERROR -Message "VM class name `"$vmClassName`" in cluster '$currentEdgeSite' does not conform to RFC1123 (lowercase alphanumeric with hyphens only, max 80 chars)."
                    $validationFailures++
                }
            }
        }
    }

    return $validationFailures
}
Function Test-JsonDnsServers {
    <#
        .SYNOPSIS
        Validates DNS server configuration from commonSupervisorSpec.

        .DESCRIPTION
        Validates that DNS servers array has 1-3 servers and each server is a valid IPv4 address.

        .PARAMETER SupervisorData
        The parsed supervisor JSON data object.

        .OUTPUTS
        [Int] The number of validation failures found.
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSCustomObject]$SupervisorData
    )

    $validationFailures = 0

    $ipv4regexPattern = '^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$'
    if ($SupervisorData.commonSupervisorSpec -and $SupervisorData.commonSupervisorSpec.dnsServers) {
        $dnsServers = $SupervisorData.commonSupervisorSpec.dnsServers
        $dnsServerCount = $dnsServers.Count
        if ($dnsServerCount -eq 0 -or $dnsServerCount -gt 3) {
            Write-LogMessage -Type ERROR -Message "DNS server array 'commonSupervisorSpec.dnsServers' must have at least 1 server and at most 3 servers. Current count: $dnsServerCount."
            $validationFailures++
        } else {
            foreach ($dnsServerEntry in $dnsServers) {
                if ($dnsServerEntry -notmatch $ipv4regexPattern) {
                    Write-LogMessage -Type ERROR -Message "DNS server `"$dnsServerEntry`" in commonSupervisorSpec.dnsServers is not a valid IPv4 address."
                    $validationFailures++
                }
            }
        }
    }

    return $validationFailures
}
Function Test-JsonFlbConfiguration {

    <#
        .SYNOPSIS
        Validates Foundation Load Balancer configuration from commonSupervisorSpec.

        .DESCRIPTION
        Validates FLB size, network type, and availability mode values.

        .PARAMETER SupervisorData
        The parsed supervisor JSON data object.

        .OUTPUTS
        [Int] The number of validation failures found.
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSCustomObject]$SupervisorData
    )

    $validationFailures = 0

    # Foundation Load Balancer size must be one of the following: SMALL, MEDIUM, LARGE, X-LARGE.
    if ($SupervisorData.commonSupervisorSpec -and $SupervisorData.commonSupervisorSpec.flbSize) {
        $isValid = Test-JsonPropertyFormat -InputData $SupervisorData.commonSupervisorSpec.flbSize -AcceptableStrings @("SMALL", "MEDIUM", "LARGE", "X-LARGE")
        if (-not $isValid) {
            Write-LogMessage -Type ERROR -Message "Invalid flbSize in commonSupervisorSpec. Must be one of: SMALL, MEDIUM, LARGE, X-LARGE."
            $validationFailures++
        }
    }

    # Only DVPG is supported for foundation load balancer networks.
    if ($SupervisorData.commonSupervisorSpec -and $SupervisorData.commonSupervisorSpec.flbNetworkType) {
        $isValid = Test-JsonPropertyFormat -InputData $SupervisorData.commonSupervisorSpec.flbNetworkType -AcceptableStrings @("DVPG")
        if (-not $isValid) {
            Write-LogMessage -Type ERROR -Message "Invalid flbNetworkType in commonSupervisorSpec. Must be 'DVPG'."
            $validationFailures++
        }
    }

    # flbAvailability must be either SINGLE_NODE or ACTIVE_PASSIVE.
    if ($SupervisorData.commonSupervisorSpec -and $SupervisorData.commonSupervisorSpec.flbAvailability) {
        $isValid = Test-JsonPropertyFormat -InputData $SupervisorData.commonSupervisorSpec.flbAvailability -AcceptableStrings @("SINGLE_NODE", "ACTIVE_PASSIVE")
        if (-not $isValid) {
            Write-LogMessage -Type ERROR -Message "Invalid flbAvailability in commonSupervisorSpec. Must be 'SINGLE_NODE' or 'ACTIVE_PASSIVE'."
            $validationFailures++
        }
    }

    return $validationFailures
}
Function Test-JsonControlPlaneConfiguration {
    <#
        .SYNOPSIS
        Validates control plane configuration from commonSupervisorSpec.

        .DESCRIPTION
        Validates control plane size and VM count values.

        .PARAMETER SupervisorData
        The parsed supervisor JSON data object.

        .OUTPUTS
        [Int] The number of validation failures found.
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSCustomObject]$SupervisorData
    )

    $validationFailures = 0

    # Supervisor control plane size must be one of the following: TINY, SMALL, MEDIUM, LARGE.
    if ($SupervisorData.commonSupervisorSpec -and $SupervisorData.commonSupervisorSpec.controlPlaneSize) {
        $isValid = Test-JsonPropertyFormat -InputData $SupervisorData.commonSupervisorSpec.controlPlaneSize -AcceptableStrings @("TINY", "SMALL", "MEDIUM", "LARGE")
        if (-not $isValid) {
            Write-LogMessage -Type ERROR -Message "Invalid controlPlaneSize in commonSupervisorSpec. Must be one of: TINY, SMALL, MEDIUM, LARGE."
            $validationFailures++
        }
    }

    # Ensure the control plane VM count is either 1 or 3.
    if ($SupervisorData.commonSupervisorSpec -and $SupervisorData.commonSupervisorSpec.controlPlaneVMCount) {
        $controlPlaneVMCount = $SupervisorData.commonSupervisorSpec.controlPlaneVMCount
        if ($controlPlaneVMCount -ne 1 -and $controlPlaneVMCount -ne 3) {
            Write-LogMessage -Type ERROR -Message "Invalid controlPlaneVMCount in commonSupervisorSpec. Must be 1 or 3. Current value: $controlPlaneVMCount."
            $validationFailures++
        }
    }

    return $validationFailures
}
Function Test-JsonStartingIpAddresses {

    <#
        .SYNOPSIS
        Validates starting IP address properties per site.

        .DESCRIPTION
        Validates that starting IP addresses for FLB networks, supervisor networks, VIP, and workload service IPs are in valid IP address format.

        .PARAMETER SiteSpecsToValidate
        Array of site specification objects to validate.

        .OUTPUTS
        [Int] The number of validation failures found.
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Array]$SiteSpecsToValidate
    )

    $validationFailures = 0

    foreach ($siteSpec in $SiteSpecsToValidate) {
        $currentEdgeSite = $siteSpec.edgeSite
        $startingIpAddressProperties = @(
            @{Path = "foundationLoadBalancerComponents.flbManagementNetwork.flbNetworkIpAddressStartingIp"; SiteSpec = $siteSpec},
            @{Path = "foundationLoadBalancerComponents.flbVirtualServerNetwork.flbNetworkIpAddressStartingIp"; SiteSpec = $siteSpec},
            @{Path = "mgmtNetworkSpec.mgmtNetworkStartingIp"; SiteSpec = $siteSpec},
            @{Path = "primaryWorkloadNetwork.primaryWorkloadNetworkStartingIp"; SiteSpec = $siteSpec},
            @{Path = "foundationLoadBalancerComponents.flbVipStartIP"; SiteSpec = $siteSpec},
            @{Path = "primaryWorkloadNetwork.workloadServiceStartIp"; SiteSpec = $siteSpec}
        )
        foreach ($startingIpAddressProperty in $startingIpAddressProperties) {
            $ipAddress = Get-JsonPropertyValue -InputData $startingIpAddressProperty.SiteSpec -PropertyPath $startingIpAddressProperty.Path
            if ($null -ne $ipAddress) {
                $isValid = Test-JsonPropertyFormat -InputData $ipAddress -ValidationPreset "IpAddress"
                if (-not $isValid) {
                    Write-LogMessage -Type ERROR -Message "Invalid IP address format for property `"$($startingIpAddressProperty.Path)`" in edgeSite `"$currentEdgeSite`"."
                    $validationFailures++
                }
            }
        }
    }

    return $validationFailures
}
Function Test-JsonIpAddressesInCidrRanges {
    <#
        .SYNOPSIS
        Validates that starting IP addresses are within their respective CIDR ranges.

        .DESCRIPTION
        Validates that starting IP addresses for networks match their gateway CIDR ranges by matching network names between supervisor JSON and infrastructure JSON.

        .PARAMETER ClustersToValidate
        Array of cluster objects to validate.

        .PARAMETER SupervisorData
        The parsed supervisor JSON data object.

        .OUTPUTS
        [Int] The number of validation failures found.
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Array]$ClustersToValidate,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSCustomObject]$SupervisorData
    )

    $validationFailures = 0

    Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Validating starting IP addresses are within their respective CIDR ranges..."

    foreach ($cluster in $ClustersToValidate) {
        $currentEdgeSite = $cluster.edgeSite
        $matchingSiteSpec = $SupervisorData.siteSpec | Where-Object { $_.edgeSite -eq $currentEdgeSite } | Select-Object -First 1
        if (-not $matchingSiteSpec -or -not $cluster.networking -or -not $cluster.networking.networkSegments) {
            continue
        }

        $networkGatewayMap = @{}
        foreach ($networkSegment in $cluster.networking.networkSegments) {
            if ($networkSegment.name -and $networkSegment.gateway) {
                $networkGatewayMap[$networkSegment.name] = $networkSegment.gateway
            }
        }

        # Define IP-to-Network-Name mappings for validation.
        $ipToNetworkMappings = @(
            @{
                IpPath = "foundationLoadBalancerComponents.flbManagementNetwork.flbNetworkIpAddressStartingIp"
                NetworkNamePath = "foundationLoadBalancerComponents.flbManagementNetwork.flbNetworkName"
                Description = "FLB Management Network Starting IP"
                SiteSpec = $matchingSiteSpec
            },
            @{
                IpPath = "foundationLoadBalancerComponents.flbVirtualServerNetwork.flbNetworkIpAddressStartingIp"
                NetworkNamePath = "foundationLoadBalancerComponents.flbVirtualServerNetwork.flbNetworkName"
                Description = "FLB Virtual Server Network Starting IP"
                SiteSpec = $matchingSiteSpec
            },
            @{
                IpPath = "mgmtNetworkSpec.mgmtNetworkStartingIp"
                NetworkNamePath = "mgmtNetworkSpec.mgmtNetworkName"
                Description = "Supervisor Management Network Starting IP"
                SiteSpec = $matchingSiteSpec
            },
            @{
                IpPath = "primaryWorkloadNetwork.primaryWorkloadNetworkStartingIp"
                NetworkNamePath = "primaryWorkloadNetwork.primaryWorkloadNetworkName"
                Description = "Primary Workload Network Starting IP"
                SiteSpec = $matchingSiteSpec
            }
        )

        foreach ($mapping in $ipToNetworkMappings) {
            $ipValue = Get-JsonPropertyValue -InputData $mapping.SiteSpec -PropertyPath $mapping.IpPath
            $networkName = Get-JsonPropertyValue -InputData $mapping.SiteSpec -PropertyPath $mapping.NetworkNamePath

            if ($null -ne $ipValue -and $null -ne $networkName) {
                # Find gateway from infrastructure JSON by matching network name (case-sensitive).
                if ($networkGatewayMap.ContainsKey($networkName)) {
                    $gatewayValue = $networkGatewayMap[$networkName]
                    Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Checking $($mapping.Description) in edgeSite '$currentEdgeSite': $ipValue against gateway $gatewayValue"

                    $isInRange = Test-IpAddressInCidrRange -IpAddress $ipValue -CidrRange $gatewayValue

                    if (-not $isInRange) {
                        Write-LogMessage -Type ERROR -Message "$($mapping.Description) ($ipValue) in edgeSite '$currentEdgeSite' is NOT within the gateway CIDR range ($gatewayValue)"
                        $validationFailures++
                    } else {
                        Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "$($mapping.Description) ($ipValue) in edgeSite '$currentEdgeSite' is within the gateway CIDR range ($gatewayValue)"
                    }
                } else {
                    Write-LogMessage -Type ERROR -Message "Network '$networkName' referenced in supervisor JSON (edgeSite: $currentEdgeSite) not found in infrastructure JSON network segments."
                    $validationFailures++
                }
            }
        }
    }

    return $validationFailures
}
Function Test-JsonShallowSupervisorServicesPathConfiguration {

    <#
        .SYNOPSIS
        Verifies that Argo CD, Harbor Carvel YAML, and Harbor TLS paths resolve to existing files after path expansion.

        .DESCRIPTION
        Intended for shallow validation after Update-InfrastructureJsonReferencedFilePaths. Uses
        Get-EffectiveSupervisorServicesYamlPath for Argo and Harbor supervisor YAMLs (parentDirectory
        + *YamlFileName or legacy *YamlPath). For Harbor TLS entries present on clusters where Harbor
        is enabled, checks Test-Path on clusters[].harborConfiguration paths already expanded by Update.

        .PARAMETER ClustersToValidate
        Cluster objects from the same InputData instance passed to Update-InfrastructureJsonReferencedFilePaths.

        .PARAMETER InputData
        Parsed infrastructure JSON (Harbor TLS paths must already be expanded by Update-InfrastructureJsonReferencedFilePaths).

        .OUTPUTS
        [Int] The number of validation failures found.
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Array]$ClustersToValidate,
        [Parameter(Mandatory = $true)] [AllowNull()] [PSObject]$InputData
    )

    $validationFailures = 0

    foreach ($cluster in $ClustersToValidate) {
        $currentEdgeSite = $cluster.edgeSite

        if (-not (Get-EffectiveSupervisorServiceFlag -Cluster $cluster -CommonData $InputData.common -FlagName "disableArgoCD")) {
            foreach ($logicalName in @("argoCdOperatorYamlPath", "argoCdDeploymentYamlPath")) {
                $resolvedPath = Get-EffectiveSupervisorServicesYamlPath -Cluster $cluster -CommonData $InputData.common -LogicalYamlPathPropertyName $logicalName
                if ([String]::IsNullOrWhiteSpace($resolvedPath)) {
                    Write-LogMessage -Type ERROR -Message "Could not resolve $logicalName for edgeSite `"$currentEdgeSite`". Configure supervisorServices.parentDirectory with the matching *YamlFileName at cluster or common level, or set the legacy supervisorServices.$logicalName property."
                    $validationFailures++
                    continue
                }
                if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
                    Write-LogMessage -Type ERROR -Message "File not found for $logicalName at `"$resolvedPath`" (edgeSite `"$currentEdgeSite`")."
                    $validationFailures++
                }
            }
        }

        if (-not (Get-EffectiveSupervisorServiceFlag -Cluster $cluster -CommonData $InputData.common -FlagName "disableHarbor")) {
            foreach ($logicalName in @("harborDataTemplateYamlPath", "harborServiceYamlPath")) {
                $resolvedPath = Get-EffectiveSupervisorServicesYamlPath -Cluster $cluster -CommonData $InputData.common -LogicalYamlPathPropertyName $logicalName
                if ([String]::IsNullOrWhiteSpace($resolvedPath)) {
                    Write-LogMessage -Type ERROR -Message "Could not resolve $logicalName for edgeSite `"$currentEdgeSite`". Configure supervisorServices.parentDirectory with the matching *YamlFileName at cluster or common level, or set the legacy supervisorServices.$logicalName property."
                    $validationFailures++
                    continue
                }
                if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
                    Write-LogMessage -Type ERROR -Message "File not found for $logicalName at `"$resolvedPath`" (edgeSite `"$currentEdgeSite`")."
                    $validationFailures++
                }
            }

            $hc = $cluster.harborConfiguration
            if ($hc) {
                foreach ($tlsProperty in @("tlsCrt", "tlsKey", "caCrt")) {
                    if ($null -eq $hc.PSObject.Properties[$tlsProperty]) {
                        continue
                    }
                    $tlsPath = [String]$hc.$tlsProperty
                    if ([String]::IsNullOrWhiteSpace($tlsPath)) {
                        continue
                    }
                    if (-not (Test-Path -LiteralPath $tlsPath -PathType Leaf)) {
                        Write-LogMessage -Type ERROR -Message "clusters[].harborConfiguration.$tlsProperty file not found: `"$tlsPath`" for edgeSite `"$currentEdgeSite`". Use parentDirectory plus file name, or a resolvable full path."
                        $validationFailures++
                    }
                }
            }
        }
    }

    return $validationFailures
}
Function Test-JsonYamlFilePaths {

    <#
        .SYNOPSIS
        Validates supervisor service YAML paths resolved from parentDirectory + file names or legacy *YamlPath keys.

        .DESCRIPTION
        For each Argo-enabled cluster, resolves argoCdOperatorYamlPath and argoCdDeploymentYamlPath via
        Get-EffectiveSupervisorServicesYamlPath (cluster-over-common): either supervisorServices.parentDirectory
        with the matching *YamlFileName, or legacy supervisorServices.argoCdOperatorYamlPath /
        argoCdDeploymentYamlPath. The same applies to Harbor Carvel YAMLs when Harbor is enabled.
        Resolved paths must match the FilePath validation preset.

        .PARAMETER ClustersToValidate
        Array of cluster objects to validate.

        .PARAMETER InputData
        Full parsed infrastructure JSON (for common.supervisorServices fallback).

        .OUTPUTS
        [Int] The number of validation failures found.
    #>

    Param (
        [Parameter(Mandatory = $true)] [AllowNull()] [PSObject]$InputData,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Array]$ClustersToValidate
    )

    $validationFailures = 0

    foreach ($logicalName in @("argoCdOperatorYamlPath", "argoCdDeploymentYamlPath")) {
        foreach ($cluster in $ClustersToValidate) {
            if (Get-EffectiveSupervisorServiceFlag -Cluster $cluster -CommonData $InputData.common -FlagName "disableArgoCD") {
                continue
            }
            $resolvedPath = Get-EffectiveSupervisorServicesYamlPath -Cluster $cluster -CommonData $InputData.common -LogicalYamlPathPropertyName $logicalName
            if ([String]::IsNullOrWhiteSpace($resolvedPath)) {
                Write-LogMessage -Type ERROR -Message "Could not resolve $logicalName for edgeSite `"$($cluster.edgeSite)`". Configure supervisorServices.parentDirectory with the matching *YamlFileName at cluster or common level, or set the legacy supervisorServices.$logicalName property."
                $validationFailures++
                continue
            }
            if (-not (Test-JsonPropertyFormat -InputData $resolvedPath -ValidationPreset "FilePath")) {
                Write-LogMessage -Type ERROR -Message "Invalid resolved path for $logicalName in cluster '$($cluster.edgeSite)': `"$resolvedPath`"."
                $validationFailures++
            }
        }
    }

    $harborClusters = @($ClustersToValidate | Where-Object { -not (Get-EffectiveSupervisorServiceFlag -Cluster $_ -CommonData $InputData.common -FlagName "disableHarbor") })
    foreach ($logicalName in @("harborDataTemplateYamlPath", "harborServiceYamlPath")) {
        foreach ($cluster in $harborClusters) {
            $resolvedPath = Get-EffectiveSupervisorServicesYamlPath -Cluster $cluster -CommonData $InputData.common -LogicalYamlPathPropertyName $logicalName
            if ([String]::IsNullOrWhiteSpace($resolvedPath)) {
                Write-LogMessage -Type ERROR -Message "Could not resolve $logicalName for edgeSite `"$($cluster.edgeSite)`". Configure supervisorServices.parentDirectory with the matching *YamlFileName at cluster or common level, or set the legacy supervisorServices.$logicalName property."
                $validationFailures++
                continue
            }
            if (-not (Test-JsonPropertyFormat -InputData $resolvedPath -ValidationPreset "FilePath")) {
                Write-LogMessage -Type ERROR -Message "Invalid resolved path for $logicalName in cluster '$($cluster.edgeSite)': `"$resolvedPath`"."
                $validationFailures++
            }
        }
    }

    return $validationFailures
}
Function Test-JsonWorkloadServiceCount {
    <#
        .SYNOPSIS
        Validates workloadServiceCount as a valid CIDR range per site.

        .DESCRIPTION
        Validates that workloadServiceCount represents a valid CIDR block (/8 to /32). This represents the number of service IP addresses to allocate for workloads.

        .PARAMETER SiteSpecsToValidate
        Array of site specification objects to validate.

        .OUTPUTS
        [Int] The number of validation failures found.
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Array]$SiteSpecsToValidate
    )

    $validationFailures = 0

    Write-LogMessage -Type DEBUG -Message "Validating workloadServiceCount as valid CIDR range."
    foreach ($siteSpec in $SiteSpecsToValidate) {
        $currentEdgeSite = $siteSpec.edgeSite
        $serviceCountValue = Get-JsonPropertyValue -InputData $siteSpec -PropertyPath "primaryWorkloadNetwork.workloadServiceCount"
        if ($null -ne $serviceCountValue) {
            $isValid = Test-ValidCidrRange -InputText $serviceCountValue -PropertyPath "siteSpec[$currentEdgeSite].primaryWorkloadNetwork.workloadServiceCount"
            if (-not $isValid) {
                Write-LogMessage -Type ERROR -Message "Invalid workloadServiceCount value in edgeSite `"$currentEdgeSite`"."
                $validationFailures++
            }
        } else {
            Write-LogMessage -Type ERROR -Message "Property `"primaryWorkloadNetwork.workloadServiceCount`" is missing or null in edgeSite `"$currentEdgeSite`"."
            $validationFailures++
        }
    }

    return $validationFailures
}
Function Test-JsonStoragePolicyTypes {
    <#
        .SYNOPSIS
        Validates storage policy type per cluster.

        .DESCRIPTION
        Validates that storage policy type is one of: VMFS, vSAN-OSA, vSAN-ESA.

        .PARAMETER ClustersToValidate
        Array of cluster objects to validate.

        .OUTPUTS
        [Int] The number of validation failures found.
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Array]$ClustersToValidate
    )

    $validationFailures = 0

    foreach ($cluster in $ClustersToValidate) {
        $currentEdgeSite = $cluster.edgeSite
        if ($cluster.storagePolicy -and $cluster.storagePolicy.storageType) {
            $isValid = Test-JsonPropertyFormat -InputData $cluster.storagePolicy.storageType -AcceptableStrings @("VMFS", "vSAN-OSA", "vSAN-ESA")
            if (-not $isValid) {
                Write-LogMessage -Type ERROR -Message "Invalid storageType in cluster '$currentEdgeSite'. Must be one of: VMFS, vSAN-OSA, vSAN-ESA."
                $validationFailures++
            }
        }
    }

    return $validationFailures
}
Function Test-JsonEsxHostCountByStoragePolicyType {

    <#
        .SYNOPSIS
        Validates ESX host count per cluster based on storage policy type.

        .DESCRIPTION
        Validates that ESX host count matches storage policy type requirements:
        - VMFS requires exactly 1 ESX host
        - vSAN-OSA requires exactly 2 ESX hosts
        - vSAN-ESA requires exactly 2 ESX hosts

        .PARAMETER ClustersToValidate
        Array of cluster objects to validate.

        .OUTPUTS
        [Int] The number of validation failures found.
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Array]$ClustersToValidate
    )

    $validationFailures = 0

    foreach ($cluster in $ClustersToValidate) {
        $currentEdgeSite = $cluster.edgeSite
        $esxHostCount = 0
        if ($cluster.esxHosts -and $cluster.esxHosts.Count) {
            $esxHostCount = $cluster.esxHosts.Count
        }

        if ($cluster.storagePolicy -and $cluster.storagePolicy.storageType) {
            $storageType = $cluster.storagePolicy.storageType
            switch ($storageType) {
                "VMFS" {
                    if ($esxHostCount -ne 1) {
                        Write-LogMessage -Type ERROR -Message "Cluster '$currentEdgeSite' with storageType 'VMFS' must have exactly 1 ESX host. Found $esxHostCount host(s)."
                        $validationFailures++
                    }
                }
                "vSAN-OSA" {
                    if ($esxHostCount -ne 2) {
                        Write-LogMessage -Type ERROR -Message "Cluster '$currentEdgeSite' with storageType 'vSAN-OSA' must have exactly 2 ESX hosts. Found $esxHostCount host(s)."
                        $validationFailures++
                    }
                }
                "vSAN-ESA" {
                    if ($esxHostCount -ne 2) {
                        Write-LogMessage -Type ERROR -Message "Cluster '$currentEdgeSite' with storageType 'vSAN-ESA' must have exactly 2 ESX hosts. Found $esxHostCount host(s)."
                        $validationFailures++
                    }
                }
            }
        }
    }

    return $validationFailures
}
Function Test-JsonEsxHostFormats {

    <#
        .SYNOPSIS
        Validates ESX host format per cluster.

        .DESCRIPTION
        Validates that each ESX host is either a valid IPv4 address (dotted quad) or a valid FQDN.
        FQDN validation allows alphanumeric characters, hyphens, dots, and underscores.

        .PARAMETER ClustersToValidate
        Array of cluster objects to validate.

        .OUTPUTS
        [Int] The number of validation failures found.
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Array]$ClustersToValidate
    )

    $validationFailures = 0

    foreach ($cluster in $ClustersToValidate) {
        $currentEdgeSite = $cluster.edgeSite
        if ($cluster.esxHosts -and $cluster.esxHosts.Count -gt 0) {
            foreach ($esxHost in $cluster.esxHosts) {
                $isValid = Test-JsonPropertyFormat -InputData $esxHost -ValidationPreset "IpAddressOrFqdn" -ValidationLabel "ESX host"
                if (-not $isValid) {
                    Write-LogMessage -Type ERROR -Message "ESX host '$esxHost' in cluster '$currentEdgeSite' is not a valid IPv4 address (dotted quad) or FQDN."
                    $validationFailures++
                }
            }
        }
    }

    return $validationFailures
}
Function Test-JsonvSanWitnessVmName {
    <#
        .SYNOPSIS
        Validates vSAN witness FQDN when storage type is VSAN-OSA or VSAN-ESA.

        .DESCRIPTION
        Validates that vSanWitnessVmName is defined and is either a valid IPv4 address (dotted quad) or a valid FQDN
        when any cluster has storage type VSAN-OSA or VSAN-ESA. The validation checks both cluster-level (edgeSite)
        and common-level definitions, with cluster-level taking priority when both are defined.

        .PARAMETER ClustersToValidate
        Array of cluster objects to validate.

        .PARAMETER InputData
        The parsed infrastructure JSON data object.

        .OUTPUTS
        [Int] The number of validation failures found.
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Array]$ClustersToValidate,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSCustomObject]$InputData
    )

    $validationFailures = 0

    foreach ($cluster in $ClustersToValidate) {
        $currentEdgeSite = $cluster.edgeSite
        $storagePolicyType = $null

        # Check if this cluster uses VSAN-OSA or VSAN-ESA storage type.
        if ($cluster.storagePolicy -and $cluster.storagePolicy.storageType) {
            $storagePolicyType = $cluster.storagePolicy.storageType
            if ($storagePolicyType -ne "vSAN-OSA" -and $storagePolicyType -ne "vSAN-ESA") {
                continue
            }
        } else {
            continue
        }

        # Determine which vSanWitnessVmName to use: cluster root, then common.
        $vSanWitnessVmName = $null
        $vSanWitnessVmNameSource = $null

        if (-not [String]::IsNullOrWhiteSpace($cluster.vSanWitnessVmName)) {
            $vSanWitnessVmName = $cluster.vSanWitnessVmName
            $vSanWitnessVmNameSource = "cluster-level (clusters[].vSanWitnessVmName)"
        } elseif (-not [String]::IsNullOrWhiteSpace($InputData.common.vSanWitnessVmName)) {
            $vSanWitnessVmName = $InputData.common.vSanWitnessVmName
            $vSanWitnessVmNameSource = "common-level (common.vSanWitnessVmName)"
        }

        # Validate that vSanWitnessVmName is defined.
        if ([String]::IsNullOrWhiteSpace($vSanWitnessVmName)) {
            Write-LogMessage -Type ERROR -Message "vSanWitnessVmName is required for cluster '$currentEdgeSite' with storage type '$storagePolicyType', but it is missing at cluster-level (clusters[].vSanWitnessVmName) and common-level (common.vSanWitnessVmName)."
            $validationFailures++
            continue
        }

        # Check if it's a valid FQDN first (more common for witness hosts).
        # This pattern allows: hostname.domain.com, host-name.domain.local, etc.
        # Use direct regex match to avoid error logging from Test-JsonPropertyFormat.
        $fqdnPattern = '^[a-zA-Z0-9]([a-zA-Z0-9\-_\.]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-_\.]*[a-zA-Z0-9])?)*$'
        $isValidFqdn = $vSanWitnessVmName -cmatch $fqdnPattern
        if ($isValidFqdn) {
            continue
        }

        # Check if it's a valid IP address (dotted quad) using direct regex match to avoid error logging.
        $ipAddressPattern = '^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$'
        $isValidIp = $vSanWitnessVmName -cmatch $ipAddressPattern
        if (-not $isValidIp) {
            Write-LogMessage -Type ERROR -Message "vSanWitnessVmName value '$vSanWitnessVmName' for cluster '$currentEdgeSite' (from $vSanWitnessVmNameSource) is not a valid IPv4 address (dotted quad) or FQDN. Required when storage type is '$storagePolicyType'."
            $validationFailures++
        }
    }

    return $validationFailures
}
Function Test-JsonHaPolicy {

    <#
        .SYNOPSIS
        Validates common.haPolicy and clusters[].haPolicy when the key is present.

        .DESCRIPTION
        When haPolicy is defined, the value must be exactly slotBased, reservationBased, or disabled (non-empty string).

        .PARAMETER ClustersToValidate
        Cluster objects from infrastructure JSON.

        .PARAMETER InputData
        Parsed infrastructure JSON (common.haPolicy).

        .OUTPUTS
        Int. Number of validation failures (0 if all valid).
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Array]$ClustersToValidate,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSCustomObject]$InputData
    )

    $validationFailures = 0
    $allowedDisplay = "disabled, reservationBased, slotBased"

    if ($InputData.common -and $null -ne $InputData.common.PSObject.Properties["haPolicy"]) {
        $rawCommon = $InputData.common.haPolicy
        if ($rawCommon -isnot [String]) {
            Write-LogMessage -Type ERROR -Message "common.haPolicy must be a string (one of: $allowedDisplay) when the key is defined. Current type: $($rawCommon.GetType().Name)."
            $validationFailures++
        } else {
            $trimmedCommon = $rawCommon.Trim()
            if ([String]::IsNullOrWhiteSpace($trimmedCommon)) {
                Write-LogMessage -Type ERROR -Message "common.haPolicy cannot be empty or whitespace when the key is defined."
                $validationFailures++
            } elseif ($trimmedCommon -notin @("disabled", "reservationBased", "slotBased")) {
                Write-LogMessage -Type ERROR -Message "common.haPolicy must be one of: $allowedDisplay. Current value: '$trimmedCommon'."
                $validationFailures++
            }
        }
    }

    foreach ($cluster in $ClustersToValidate) {
        if (-not $cluster -or $null -eq $cluster.PSObject.Properties["haPolicy"]) {
            continue
        }
        $currentEdgeSite = $cluster.edgeSite
        $rawCluster = $cluster.haPolicy
        if ($rawCluster -isnot [String]) {
            Write-LogMessage -Type ERROR -Message "clusters[].haPolicy must be a string (one of: $allowedDisplay) when defined for edgeSite '$currentEdgeSite'. Current type: $($rawCluster.GetType().Name)."
            $validationFailures++
            continue
        }
        $trimmedCluster = $rawCluster.Trim()
        if ([String]::IsNullOrWhiteSpace($trimmedCluster)) {
            Write-LogMessage -Type ERROR -Message "clusters[].haPolicy cannot be empty or whitespace when defined for edgeSite '$currentEdgeSite'."
            $validationFailures++
        } elseif ($trimmedCluster -notin @("disabled", "reservationBased", "slotBased")) {
            Write-LogMessage -Type ERROR -Message "clusters[].haPolicy for edgeSite '$currentEdgeSite' must be one of: $allowedDisplay. Current value: '$trimmedCluster'."
            $validationFailures++
        }
    }

    return $validationFailures
}
Function Get-CommonLabEnvironmentEnabled {
    <#
        .SYNOPSIS
        Returns whether infrastructure JSON enables lab mode (common.labenvironment true).

        .PARAMETER InputData
        Parsed infrastructure JSON root object.
    #>
    Param (
        [Parameter(Mandatory = $true)] [AllowNull()] [PSObject]$InputData
    )
    if (-not $InputData -or -not $InputData.common) {
        return $false
    }
    $labProp = $InputData.common.PSObject.Properties | Where-Object { $_.Name -ieq "labenvironment" } | Select-Object -First 1
    if ($null -eq $labProp) {
        return $false
    }
    return ($labProp.Value -eq $true)
}
Function Get-HarborHostnameFromDataValuesTemplateFile {
    <#
        .SYNOPSIS
        Reads the top-level hostname value from a Harbor data values YAML template.

        .PARAMETER HarborTemplateFilePath
        Full path to the Harbor data values template (e.g. harbor-data-values-v2.14.2.yml).
    #>
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$HarborTemplateFilePath
    )
    if (-not (Test-Path -LiteralPath $HarborTemplateFilePath -PathType Leaf)) {
        return $null
    }
    $raw = Get-Content -LiteralPath $HarborTemplateFilePath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if ([String]::IsNullOrWhiteSpace($raw)) {
        return $null
    }
    # Anchor to start of line so we read the real top-level Harbor data-values hostname, not a nested key.
    # Allow an optional YAML comment marker before hostname (some templates comment the sample line).
    if ($raw -match '(?m)^(?:#\s*)?hostname:\s*(.+)\s*$') {
        $candidate = $Matches[1].Trim().Trim('"').Trim("'")
        if ([String]::IsNullOrWhiteSpace($candidate)) {
            return $null
        }
        # Return raw template text here; callers validate with Test-JsonPropertyFormat -ValidationPreset IpAddressOrFqdn (DNS host or IPv4).
        return $candidate
    }
    return $null
}
Function Get-EffectiveHarborHostnameForInfrastructureCluster {
    <#
        .SYNOPSIS
        Resolves the Harbor hostname for YAML and validation (JSON hostname or lab template fallback).

        .DESCRIPTION
        When clusters[].harborConfiguration.hostname is set, returns the trimmed value. When lab mode is
        enabled and both tlsCrt and tlsKey are omitted (including when the entire harborConfiguration
        stanza is omitted), reads hostname from the Harbor data values template file resolved via
        supervisorServices. Returns null if the hostname cannot be resolved.
    #>
    Param (
        [Parameter(Mandatory = $true)] [AllowNull()] [PSObject]$Cluster,
        [Parameter(Mandatory = $true)] [AllowNull()] [PSObject]$CommonData,
        [Parameter(Mandatory = $false)] [bool]$LabEnvironmentEnabled = $false
    )
    $hc = $Cluster.harborConfiguration
    if ($hc) {
        $rawHostname = if ($hc.PSObject.Properties["hostname"]) { [string]$hc.hostname } else { "" }
        if (-not [String]::IsNullOrWhiteSpace($rawHostname)) {
            return $rawHostname.Trim()
        }
        $hasTlsCrt = ($null -ne $hc.PSObject.Properties["tlsCrt"]) -and -not [String]::IsNullOrWhiteSpace([string]$hc.tlsCrt)
        $hasTlsKey = ($null -ne $hc.PSObject.Properties["tlsKey"]) -and -not [String]::IsNullOrWhiteSpace([string]$hc.tlsKey)
    } else {
        if (-not $LabEnvironmentEnabled) {
            return $null
        }
        $hasTlsCrt = $false
        $hasTlsKey = $false
    }
    # Lab-only fallback when JSON does not carry a hostname and no customer TLS PEM paths are set: read hostname from the Harbor Carvel data-values YAML (same file deploy uses).
    if ($LabEnvironmentEnabled -and -not $hasTlsCrt -and -not $hasTlsKey) {
        $templatePath = Get-EffectiveSupervisorServicesYamlPath -Cluster $Cluster -CommonData $CommonData -LogicalYamlPathPropertyName "harborDataTemplateYamlPath"
        if ([String]::IsNullOrWhiteSpace($templatePath) -or -not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
            return $null
        }
        $fromTemplate = Get-HarborHostnameFromDataValuesTemplateFile -HarborTemplateFilePath $templatePath
        if ([String]::IsNullOrWhiteSpace($fromTemplate)) {
            return $null
        }
        return $fromTemplate.Trim()
    }
    return $null
}
Function New-LabHarborSelfSignedTlsMaterialFiles {
    <#
        .SYNOPSIS
        Creates temporary PEM files for a Harbor TLS certificate (self-signed, RSA).

        .DESCRIPTION
        Uses .NET CertificateRequest so key material generation works on Windows, macOS, and Linux
        without OpenSSL. Writes tls.crt, tls.key, and ca.crt (same certificate as CA for self-signed)
        under the system temp directory. The caller must delete the files when finished.

        .PARAMETER DnsName
        Subject CN and SAN (DNS or IP).

        .PARAMETER EdgeSite
        Used only for unique temporary file names.

        .PARAMETER RsaKeySize
        RSA key size in bits. Default 2048.
    #>
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DnsName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EdgeSite,
        [Parameter(Mandatory = $false)] [ValidateRange(2048, 8192)] [Int]$RsaKeySize = 2048
    )

    $rsa = [System.Security.Cryptography.RSA]::Create($RsaKeySize)
    try {
        $distinguishedName = "CN=$DnsName"
        $dnObj = [System.Security.Cryptography.X509Certificates.X500DistinguishedName]::new($distinguishedName)
        $req = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
            $dnObj,
            $rsa,
            [System.Security.Cryptography.HashAlgorithmName]::SHA256,
            [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
        )
        $sanBuilder = [System.Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new()
        $parsedIp = $null
        if ([System.Net.IPAddress]::TryParse($DnsName, [ref]$parsedIp)) {
            $null = $sanBuilder.AddIpAddress($parsedIp)
        } else {
            $null = $sanBuilder.AddDnsName($DnsName)
        }
        $null = $req.CertificateExtensions.Add($sanBuilder.Build())
        $notBefore = [DateTimeOffset]::UtcNow.AddMinutes(-5)
        $notAfter = $notBefore.AddYears(1)
        $cert = $req.CreateSelfSigned($notBefore, $notAfter)
        try {
            $certPem = $cert.ExportCertificatePem()
            # Export the key from the same RSA instance passed to CertificateRequest (.NET 10+ may not expose GetRSAPrivateKey on the cert).
            $keyPem = $rsa.ExportPkcs8PrivateKeyPem()
        } finally {
            $cert.Dispose()
        }
    } finally {
        $rsa.Dispose()
    }

    $tempBase = Join-Path ([System.IO.Path]::GetTempPath()) ("harbor-lab-tls-" + ($EdgeSite -replace '[^\w\-]', '_') + "-" + [Guid]::NewGuid().ToString("N"))
    $crtPath = "$tempBase.crt.pem"
    $keyPath = "$tempBase.key.pem"
    $caPath = "$tempBase.ca.pem"
    [System.IO.File]::WriteAllText($crtPath, $certPem, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($keyPath, $keyPem, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($caPath, $certPem, [System.Text.UTF8Encoding]::new($false))
    Write-LogMessage -Type INFO -Message "Lab mode: wrote self-signed Harbor TLS material for `"$DnsName`" (edge site `"$EdgeSite`") to temporary PEM files under the system temp directory."
    return [ordered]@{
        CaCrtPath  = $caPath
        TlsCrtPath = $crtPath
        TlsKeyPath = $keyPath
    }
}
Function Test-JsonHarborConfiguration {

    <#
        .SYNOPSIS
        Validates cluster-level harborConfiguration stanza when Harbor is not disabled.

        .DESCRIPTION
        For each cluster where Harbor is not disabled (disableHarbor is not true at cluster or common
        level), performs both shallow presence checks and deep format validation:

        Shallow checks:
        - harborConfiguration stanza must exist at the cluster level unless common.labenvironment is
          true (lab: the stanza may be omitted; hostname is read from the Harbor data values template and
          TLS is generated at deploy time).
        - harborConfiguration.hostname must be present and non-empty unless common.labenvironment is
          true and both tlsCrt and tlsKey are omitted (hostname is then read from the Harbor data values
          template).

        Deep checks:
        - Resolved hostname (JSON or lab template fallback) must be a valid DNS-compatible FQDN or IP address.
        - Any optional volume size key (registryVolumeSize, jobserviceVolumeSize, databaseVolumeSize,
          redisVolumeSize, trivyVolumeSize) that is present must be a positive integer followed by
          "Gi" (e.g. "10Gi", "100Gi").
        - secretKey, when specified as a plain-text literal (not a $env: reference), must be exactly
          16 characters (Harbor uses it as an AES-128 encryption key). Omitted secretKey leaves the
          Harbor data-values template defaults. $env: references are validated at pre-flight by
          Invoke-HarborEnvVarPreflight via Resolve-HarborSecretValue (skipped when Start-VcfEdgeAtScale
          is run with -ComputeOnly).
        - tlsCrt and tlsKey must both be defined together or both omitted. caCrt is only valid when
          both tlsCrt and tlsKey are defined. When harborConfiguration.parentDirectory is set, tlsCrt,
          tlsKey, and caCrt are file names (or relative path fragments) under that directory; when
          parentDirectory is omitted, use full paths (legacy). Update-InfrastructureJsonReferencedFilePaths
          expands paths before existence and PEM type checks. When common.labenvironment is true and
          both tlsCrt and tlsKey are omitted, TLS files are generated at deploy time (not validated here).

        .PARAMETER ClustersToValidate
        Array of cluster objects to validate.

        .PARAMETER InputData
        The parsed infrastructure JSON data object (for common-level flag fallback).

        .OUTPUTS
        [Int] The number of validation failures found.
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Array]$ClustersToValidate,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSCustomObject]$InputData
    )

    $validationFailures = 0
    $volumeSizePattern = '^[1-9]\d*Gi$'
    $envVarPattern = '^\$env:[A-Za-z_][A-Za-z0-9_]*$'
    $volumeSizeKeys = @("registryVolumeSize", "jobserviceVolumeSize", "databaseVolumeSize", "redisVolumeSize", "trivyVolumeSize")
    $labEnvironment = Get-CommonLabEnvironmentEnabled -InputData $InputData

    foreach ($cluster in $ClustersToValidate) {
        $currentEdgeSite = $cluster.edgeSite

        # Skip clusters where Harbor is explicitly disabled.
        if (Get-EffectiveSupervisorServiceFlag -Cluster $cluster -CommonData $InputData.common -FlagName "disableHarbor") {
            Write-LogMessage -Type DEBUG -Message "Harbor is disabled for edgeSite `"$currentEdgeSite`"; skipping harborConfiguration validation."
            continue
        }

        # (Shallow) Require harborConfiguration stanza unless lab mode (synthesized at deploy time).
        if (-not $cluster.harborConfiguration) {
            if ($labEnvironment) {
                Write-LogMessage -Type DEBUG -Message "Harbor: clusters[].harborConfiguration omitted for edgeSite `"$currentEdgeSite`"; lab mode will synthesize an empty stanza at deploy (hostname from Harbor data values template, self-signed TLS)."
                $effectiveHostnameOnly = Get-EffectiveHarborHostnameForInfrastructureCluster -Cluster $cluster -CommonData $InputData.common -LabEnvironmentEnabled $labEnvironment
                if ([String]::IsNullOrWhiteSpace($effectiveHostnameOnly)) {
                    Write-LogMessage -Type ERROR -Message "clusters[].harborConfiguration is omitted for edgeSite `"$currentEdgeSite`" while Harbor is enabled in lab mode; the Harbor hostname could not be read from the data values template (hostname: key). Add harborConfiguration with hostname, or fix supervisorServices harbor template path and template content, or set supervisorServices.disableHarbor to true."
                    $validationFailures++
                } else {
                    # Same bar as JSON hostname: Test-JsonPropertyFormat IpAddressOrFqdn allowlists safe DNS labels / IPv4 (see function help for preset rules).
                    $hostOk = Test-JsonPropertyFormat -InputData $effectiveHostnameOnly -ValidationPreset "IpAddressOrFqdn" -ValidationLabel "harborConfiguration.hostname (resolved from template)"
                    if (-not $hostOk) {
                        Write-LogMessage -Type ERROR -Message "Resolved Harbor hostname from template `"$effectiveHostnameOnly`" for edgeSite `"$currentEdgeSite`" is not a valid DNS-compatible FQDN or IP address."
                        $validationFailures++
                    }
                }
                continue
            }
            Write-LogMessage -Type ERROR -Message "clusters[].harborConfiguration is required for edgeSite `"$currentEdgeSite`" because Harbor is not disabled. Add a harborConfiguration stanza, enable common.labenvironment to omit it in lab, or set supervisorServices.disableHarbor to true to skip Harbor."
            $validationFailures++
            continue
        }

        $hasTlsCrt = ($null -ne $cluster.harborConfiguration.PSObject.Properties["tlsCrt"]) -and -not [String]::IsNullOrWhiteSpace($cluster.harborConfiguration.tlsCrt)
        $hasTlsKey = ($null -ne $cluster.harborConfiguration.PSObject.Properties["tlsKey"]) -and -not [String]::IsNullOrWhiteSpace($cluster.harborConfiguration.tlsKey)
        if ($hasTlsCrt -xor $hasTlsKey) {
            Write-LogMessage -Type ERROR -Message "clusters[].harborConfiguration.tlsCrt and tlsKey must both be defined together for edgeSite `"$currentEdgeSite`". Define both PEM paths, omit both (when common.labenvironment is true, both omitted triggers a generated self-signed certificate), or do not set exactly one of them."
            $validationFailures++
        }


        $effectiveHostname = Get-EffectiveHarborHostnameForInfrastructureCluster -Cluster $cluster -CommonData $InputData.common -LabEnvironmentEnabled $labEnvironment
        if ([String]::IsNullOrWhiteSpace($effectiveHostname)) {
            if ($labEnvironment -and -not $hasTlsCrt -and -not $hasTlsKey) {
                Write-LogMessage -Type ERROR -Message "clusters[].harborConfiguration.hostname is missing for edgeSite `"$currentEdgeSite`" and could not be read from the Harbor data values template (hostname: key). Set hostname in JSON or fix the template file referenced by supervisorServices (harborDataTemplateYamlFileName / harborDataTemplateYamlPath)."
                $validationFailures++
            } elseif ($hasTlsCrt -and $hasTlsKey) {
                Write-LogMessage -Type ERROR -Message "clusters[].harborConfiguration.hostname is required for edgeSite `"$currentEdgeSite`" when tlsCrt and tlsKey are supplied."
                $validationFailures++
            } else {
                Write-LogMessage -Type ERROR -Message "clusters[].harborConfiguration.hostname is required for edgeSite `"$currentEdgeSite`" and must not be empty (or enable common.labenvironment and omit tlsCrt/tlsKey to use the template hostname)."
                $validationFailures++
            }
        } else {
            # Resolved string is either JSON hostname, trimmed, or lab template hostname; reject invalid DNS/IP before deploy or TLS generation.
            $isValid = Test-JsonPropertyFormat -InputData $effectiveHostname -ValidationPreset "IpAddressOrFqdn" -ValidationLabel "harborConfiguration.hostname (resolved)"
            if (-not $isValid) {
                Write-LogMessage -Type ERROR -Message "Resolved Harbor hostname `"$effectiveHostname`" for edgeSite `"$currentEdgeSite`" is not a valid DNS-compatible FQDN or IP address."
                $validationFailures++
            }
        }

        # (Deep) Validate optional volume size keys when present.
        foreach ($key in $volumeSizeKeys) {
            $value = $cluster.harborConfiguration.$key
            if ($null -ne $value -and -not [String]::IsNullOrWhiteSpace([string]$value)) {
                if ([string]$value -notmatch $volumeSizePattern) {
                    Write-LogMessage -Type ERROR -Message "clusters[].harborConfiguration.$key value `"$value`" in edgeSite `"$currentEdgeSite`" is not valid. Must be a positive integer followed by `"Gi`" (e.g. `"10Gi`", `"50Gi`")."
                    $validationFailures++
                }
            }
        }

        # (Deep) Validate secretKey — env var references must be well-formed; plain-text literals
        # must be exactly 16 characters (AES-128 key). $env: references are further validated at
        # pre-flight by Invoke-HarborEnvVarPreflight via Resolve-HarborSecretValue.
        $secretKeyValue = $cluster.harborConfiguration.secretKey
        if (-not [String]::IsNullOrWhiteSpace($secretKeyValue)) {
            if ($secretKeyValue -match '^\$env:') {
                if ($secretKeyValue -notmatch $envVarPattern) {
                    Write-LogMessage -Type ERROR -Message "clusters[].harborConfiguration.secretKey for edgeSite `"$currentEdgeSite`" has a malformed environment variable reference `"$secretKeyValue`". Use the format `$env:VARNAME where VARNAME starts with a letter or underscore and contains only letters, digits, and underscores."
                    $validationFailures++
                }
            } elseif ($secretKeyValue.Length -ne 16) {
                Write-LogMessage -Type ERROR -Message "clusters[].harborConfiguration.secretKey for edgeSite `"$currentEdgeSite`" must be exactly 16 characters but is $($secretKeyValue.Length) character(s). Harbor uses it as an AES-128 encryption key."
                $validationFailures++
            }
        }

        # (Deep) Validate all other Harbor secret/password fields: any value beginning with '$'
        # must be a well-formed $env:VARNAME reference; plain-text secrets are accepted as-is.
        foreach ($secretField in @("harborAdminPassword", "databasePassword", "coreSecret", "jobserviceSecret", "registrySecret")) {
            $fieldValue = $cluster.harborConfiguration.$secretField
            if (-not [String]::IsNullOrWhiteSpace($fieldValue) -and $fieldValue -match '^\$env:' -and $fieldValue -notmatch $envVarPattern) {
                Write-LogMessage -Type ERROR -Message "clusters[].harborConfiguration.$secretField for edgeSite `"$currentEdgeSite`" has a malformed environment variable reference `"$fieldValue`". Use the format `$env:VARNAME where VARNAME starts with a letter or underscore and contains only letters, digits, and underscores."
                $validationFailures++
            }
        }

        $hasCaCrt = ($null -ne $cluster.harborConfiguration.PSObject.Properties["caCrt"]) -and -not [String]::IsNullOrWhiteSpace($cluster.harborConfiguration.caCrt)
        if ($hasCaCrt -and -not ($hasTlsCrt -and $hasTlsKey)) {
            Write-LogMessage -Type ERROR -Message "clusters[].harborConfiguration.caCrt can only be defined when both tlsCrt and tlsKey are also defined for edgeSite `"$currentEdgeSite`"."
            $validationFailures++
        }

        # (Deep) Verify TLS certificate files exist and contain the correct PEM type (skipped in lab when both tls paths are omitted; PEMs are generated at deploy time).
        # tlsCrt and caCrt must begin with "-----BEGIN CERTIFICATE-----".
        # tlsKey must begin with "-----BEGIN" but must NOT begin with "-----BEGIN CERTIFICATE-----"
        # (accepts PRIVATE KEY, ENCRYPTED PRIVATE KEY, RSA PRIVATE KEY, EC PRIVATE KEY, etc.).
        $skipTlsFileChecks = ($labEnvironment -and -not $hasTlsCrt -and -not $hasTlsKey)
        foreach ($tlsEntry in @(
            [PSCustomObject]@{ Field = "tlsCrt"; HasValue = $hasTlsCrt; ExpectCertificate = $true  },
            [PSCustomObject]@{ Field = "tlsKey"; HasValue = $hasTlsKey; ExpectCertificate = $false },
            [PSCustomObject]@{ Field = "caCrt";  HasValue = $hasCaCrt;  ExpectCertificate = $true  }
        )) {
            if ($skipTlsFileChecks) { continue }
            if (-not $tlsEntry.HasValue) { continue }
            $filePath = $cluster.harborConfiguration.($tlsEntry.Field)
            if (-not (Test-Path -LiteralPath $filePath)) {
                Write-LogMessage -Type ERROR -Message "clusters[].harborConfiguration.$($tlsEntry.Field) file not found: `"$filePath`" for edgeSite `"$currentEdgeSite`". Use parentDirectory plus file name, or a resolvable full path."
                $validationFailures++
                continue
            }
            $pemFirstLine = (Get-Content -LiteralPath $filePath -TotalCount 1 -ErrorAction SilentlyContinue) -replace '\r', ''
            if ($tlsEntry.ExpectCertificate) {
                if ($pemFirstLine -ne "-----BEGIN CERTIFICATE-----") {
                    Write-LogMessage -Type ERROR -Message "clusters[].harborConfiguration.$($tlsEntry.Field) must contain a PEM certificate (-----BEGIN CERTIFICATE-----) but the file at `"$filePath`" begins with `"$pemFirstLine`" for edgeSite `"$currentEdgeSite`". Check that tlsCrt and tlsKey paths are not swapped."
                    $validationFailures++
                }
            } else {
                if ($pemFirstLine -notlike "-----BEGIN*" -or $pemFirstLine -like "-----BEGIN CERTIFICATE-----") {
                    Write-LogMessage -Type ERROR -Message "clusters[].harborConfiguration.$($tlsEntry.Field) must contain a PEM private key (e.g. -----BEGIN PRIVATE KEY-----) but the file at `"$filePath`" begins with `"$pemFirstLine`" for edgeSite `"$currentEdgeSite`". Check that tlsCrt and tlsKey paths are not swapped."
                    $validationFailures++
                }
            }
        }
    }

    # Cross-cluster duplicate hostname warning (does not fail validation; each site must have a unique hostname
    # so DNS can point each harborConfiguration.hostname to the correct load balancer IP).
    $harborHostnames = @()
    foreach ($cluster in $ClustersToValidate) {
        if (-not (Get-EffectiveSupervisorServiceFlag -Cluster $cluster -CommonData $InputData.common -FlagName "disableHarbor")) {
            $resolvedHost = Get-EffectiveHarborHostnameForInfrastructureCluster -Cluster $cluster -CommonData $InputData.common -LabEnvironmentEnabled $labEnvironment
            if (-not [String]::IsNullOrWhiteSpace($resolvedHost)) {
                $harborHostnames += $resolvedHost
            }
        }
    }
    $duplicateHostnames = $harborHostnames | Group-Object | Where-Object { $_.Count -gt 1 }
    foreach ($dup in $duplicateHostnames) {
        $affectedSites = ($ClustersToValidate | Where-Object {
            -not (Get-EffectiveSupervisorServiceFlag -Cluster $_ -CommonData $InputData.common -FlagName "disableHarbor") -and
            (Get-EffectiveHarborHostnameForInfrastructureCluster -Cluster $_ -CommonData $InputData.common -LabEnvironmentEnabled $labEnvironment) -eq $dup.Name
        } | ForEach-Object { $_.edgeSite }) -join ", "
        Write-LogMessage -Type WARNING -Message "Multiple clusters share harborConfiguration.hostname `"$($dup.Name)`" (edgeSite(s): $affectedSites). Each Harbor instance needs a unique DNS name; both clusters will register to the same hostname, causing DNS conflicts."
    }

    return $validationFailures
}
Function Get-ClustersInScope {

    <#
        .SYNOPSIS
        Returns the subset of clusters from InputData that fall within the given edge-site scope.

        .DESCRIPTION
        When EdgeSitesArray is non-empty, filters InputData.clusters to only those whose edgeSite
        property is in the array. When EdgeSitesArray is empty (all-sites run), returns all clusters.
        Used by Test-JsonDeeperValidation to replace the repeated inline filter pattern.

        .PARAMETER EdgeSitesArray
        Array of edgeSite names to include. Pass an empty array to include all clusters.

        .PARAMETER InputData
        The parsed infrastructure JSON object.

        .OUTPUTS
        Object[]. Array of cluster objects in scope; may be empty.
    #>

    Param (
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [Array]$EdgeSitesArray,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$InputData
    )

    if ($EdgeSitesArray.Count -gt 0) {
        return @($InputData.clusters | Where-Object { $_.edgeSite -in $EdgeSitesArray })
    }
    return @($InputData.clusters)
}
Function Get-SiteSpecsInScope {

    <#
        .SYNOPSIS
        Returns the subset of supervisor siteSpec entries that fall within the given edge-site scope.

        .DESCRIPTION
        When EdgeSitesArray is non-empty, filters SupervisorData.siteSpec to only those whose edgeSite
        property is in the array. When EdgeSitesArray is empty (all-sites run), returns all site specs.
        Used by Test-JsonDeeperValidation to replace the repeated inline filter pattern.

        .PARAMETER EdgeSitesArray
        Array of edgeSite names to include. Pass an empty array to include all site specs.

        .PARAMETER SupervisorData
        The parsed supervisor JSON object.

        .OUTPUTS
        Object[]. Array of siteSpec objects in scope; may be empty.
    #>

    Param (
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [Array]$EdgeSitesArray,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$SupervisorData
    )

    if ($EdgeSitesArray.Count -gt 0) {
        return @($SupervisorData.siteSpec | Where-Object { $_.edgeSite -in $EdgeSitesArray })
    }
    return @($SupervisorData.siteSpec)
}
Function Test-JsonDeeperValidation {

    <#
        .SYNOPSIS
        Validates JSON file content against specified validation rules.

        .DESCRIPTION
        The Test-JsonDeeperValidation function provides comprehensive validation of JSON files
        against specified validation rules. It supports nested property validation
        using dot notation (e.g., "common.vCenter.name") and provides detailed reporting of
        validation failures.

        .PARAMETER ComputeOnly
        When set, does not load supervisor.json and skips deeper rules that require supervisor, Argo CD, Harbor, or supervisor site data.

        .PARAMETER EdgeSite
        Optional comma-separated edge sites; validation is limited to those clusters where applicable.

        .PARAMETER InfrastructureJson
        Path to infrastructure JSON.

        .PARAMETER SupervisorJson
        Path to supervisor JSON (ignored when -ComputeOnly is set).
    #>

    Param (
        [Parameter(Mandatory = $false)] [Switch]$ComputeOnly,
        [Parameter(Mandatory = $false)] [String]$EdgeSite,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$InfrastructureJson,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorJson
    )

    Write-LogMessage -Type DEBUG -Message "Entered Test-JsonDeeperValidation function..."

    $deeperValidationFunctionStartTime = Get-Date

    $inputData = ConvertFrom-JsonSafely -JsonFilePath $InfrastructureJson
    Update-InfrastructureJsonReferencedFilePaths -InfrastructureJsonPath $InfrastructureJson -InputData $inputData
    if ($ComputeOnly) {
        Write-LogMessage -Type INFO -Message "ComputeOnly: skipping supervisor.json load and deeper checks that require supervisor, Argo CD, or Harbor."
        $supervisorData = $null
    } else {
        $supervisorData = ConvertFrom-JsonSafely -JsonFilePath $SupervisorJson
    }

    # If EdgeSite is specified, resolve to list and validate (throws if invalid delimiter or unknown site).
    $edgeSitesArray = @()
    if ($EdgeSite) {
        $edgeSitesArray = Get-EdgeSitesFromParameter -EdgeSite $EdgeSite -InputData $inputData
        $siteList = $edgeSitesArray -join '", "'
        Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Validating edgeSite(s) `"$siteList`" configuration..."
    }

    # Resolve scope-filtered collections used throughout validation.
    $clustersInScope = if ($inputData.clusters) { Get-ClustersInScope -EdgeSitesArray $edgeSitesArray -InputData $inputData } else { @() }
    $siteSpecsInScope = if (-not $ComputeOnly -and $supervisorData -and $supervisorData.siteSpec) { Get-SiteSpecsInScope -EdgeSitesArray $edgeSitesArray -SupervisorData $supervisorData } else { @() }

    $anyArgoEnabledForScope = $false
    $anyHarborEnabledForScope = $false
    if (-not $ComputeOnly) {
        foreach ($clusterFlagRow in $clustersInScope) {
            if (-not (Get-EffectiveSupervisorServiceFlag -Cluster $clusterFlagRow -CommonData $inputData.common -FlagName "disableArgoCD")) {
                $anyArgoEnabledForScope = $true
            }
            if (-not (Get-EffectiveSupervisorServiceFlag -Cluster $clusterFlagRow -CommonData $inputData.common -FlagName "disableHarbor")) {
                $anyHarborEnabledForScope = $true
            }
            if ($anyArgoEnabledForScope -and $anyHarborEnabledForScope) {
                break
            }
        }
    }

    $validationFailures = 0

    # Validate prefix formats in infrastructure JSON.
    $validationFailures += Test-JsonPrefixFormats -InputData $inputData

    # Validate common.vCenterName is IPv4 (dotted quad) or FQDN.
    if ($inputData.common -and -not [String]::IsNullOrWhiteSpace($inputData.common.vCenterName)) {
        $vCenterName = $inputData.common.vCenterName
        $isValid = Test-JsonPropertyFormat -InputData $vCenterName -ValidationPreset "IpAddressOrFqdn" -ValidationLabel "common.vCenterName"
        if (-not $isValid) {
            Write-LogMessage -Type ERROR -Message "common.vCenterName value '$vCenterName' is not a valid IPv4 address (dotted quad) or FQDN."
            $validationFailures++
        }
    }

    # Validate common.vCenterUser format (alphanumeric, @, ., -, _ for UPN or local user).
    if ($inputData.common -and -not [String]::IsNullOrWhiteSpace($inputData.common.vCenterUser)) {
        $vCenterUserPattern = '^[a-zA-Z0-9._@\-]{1,256}$'
        $isValid = Test-JsonPropertyFormat -InputData $inputData -PropertyPath "common.vCenterUser" -RegexPattern $vCenterUserPattern
        if (-not $isValid) {
            Write-LogMessage -Type ERROR -Message "common.vCenterUser must contain only letters, digits, and the characters . _ @ - (max 256 characters)."
            $validationFailures++
        }
    }

    # Validate common.contextName (VCF CLI context: lowercase RFC1123) when any cluster deploys any supervisor service (ArgoCD or Harbor).
    if (($anyArgoEnabledForScope -or $anyHarborEnabledForScope) -and $inputData.common -and -not [String]::IsNullOrWhiteSpace($inputData.common.contextName)) {
        $isValid = Test-JsonPropertyFormat -InputData $inputData -PropertyPath "common.contextName" -ValidationPreset "lowerCaseRfc1123PortGroup"
        if (-not $isValid) {
            Write-LogMessage -Type ERROR -Message "common.contextName must be lowercase RFC1123 compliant (e.g. lowercase alphanumeric and hyphens, 1-80 characters)."
            $validationFailures++
        }
    }

    # Validate Supervisor content library subscription URL only when the key is present (optional; default applied at runtime when datastore key is present).
    if ($inputData.common -and $null -ne $inputData.common.PSObject.Properties["supervisorContentLibrarySubscriptionUrl"]) {
        Write-LogMessage -Type DEBUG -Message "Validating Supervisor content library subscription URL..."
        $isValid = Test-JsonPropertyFormat -InputData $inputData -PropertyPath "common.supervisorContentLibrarySubscriptionUrl" -ValidationPreset "Url"
        if (-not $isValid) {
            $validationFailures++
        }
    }

    # Validate network segment gateways and network name matching per cluster (requires supervisor.json).
    if (-not $ComputeOnly -and $clustersInScope.Count -gt 0 -and $siteSpecsInScope.Count -gt 0) {
        $validationFailures += Test-JsonNetworkSegmentGateways -ClustersToValidate $clustersInScope -SupervisorData $supervisorData
    }

    # VMware object character validation (per cluster).
    if ($clustersInScope.Count -gt 0) {
        $validationFailures += Test-JsonStoragePolicyFormats -ClustersToValidate $clustersInScope
    }

    # Validate other vSphere objects (datacenter always; content library datastore only when defined).
    Write-LogMessage -Type DEBUG -Message "Validating datacenter/contentlibrary datastore formats in infrastructure JSON..."
    $vSphereObjectProperties = @("common.datacenterName")
    if ($inputData.common -and $null -ne $inputData.common.PSObject.Properties["supervisorContentLibraryDatastore"]) {
        $vSphereObjectProperties += "common.supervisorContentLibraryDatastore"
    }
    foreach ($vSphereObjectProperty in $vSphereObjectProperties) {
        $isValid = Test-JsonPropertyFormat -InputData $inputData -PropertyPath $vSphereObjectProperty -ValidationPreset "vSphereObject80Characters"
        if (-not $isValid) {
            $validationFailures++
        }
    }

    # Validate common.labenvironment when defined: must be boolean true or false.
    if ($inputData.common -and $null -ne $inputData.common.PSObject.Properties["labenvironment"]) {
        $labEnvVal = $inputData.common.labenvironment
        if (-not ($labEnvVal -is [bool])) {
            Write-LogMessage -Type ERROR -Message "Invalid common.labenvironment. When defined, value must be true or false (boolean). Current type: $($labEnvVal.GetType().Name)."
            $validationFailures++
        }
    }

    # Validate common.preserveAutoGeneratedKeyCertPair when defined: must be boolean true or false.
    if ($inputData.common -and $null -ne $inputData.common.PSObject.Properties["preserveAutoGeneratedKeyCertPair"]) {
        $preserveKeyCertVal = $inputData.common.preserveAutoGeneratedKeyCertPair
        if (-not ($preserveKeyCertVal -is [bool])) {
            Write-LogMessage -Type ERROR -Message "Invalid common.preserveAutoGeneratedKeyCertPair. When defined, value must be true or false (boolean). Current type: $($preserveKeyCertVal.GetType().Name)."
            $validationFailures++
        }
    }

    # Validate common.vSanvMotionVmKernelMtuValue when defined: numbers only, 1500-9190 (overrides default vMotion/vSAN VMkernel and VDS MTU of 9000; mgmt and vSAN Witness are always 1500).
    if ($inputData.common -and $null -ne $inputData.common.PSObject.Properties["vSanvMotionVmKernelMtuValue"]) {
        Write-LogMessage -Type DEBUG -Message "Validating common.vSanvMotionVmKernelMtuValue (1500-9190, numbers only)..."
        $isValid = Test-JsonPropertyFormat -InputData $inputData -PropertyPath "common.vSanvMotionVmKernelMtuValue" -ValidationPreset "Numeric" -MinValue 1500 -MaxValue 9190
        if (-not $isValid) {
            Write-LogMessage -Type ERROR -Message "Invalid common.vSanvMotionVmKernelMtuValue. When defined, value must be a number between 1500 and 9190 (numbers only)."
            $validationFailures++
        }
    }

    # Validate vLcmImageName format when present (common and per-cluster; edge overrides common at runtime).
    if ($inputData.common -and $null -ne $inputData.common.PSObject.Properties["vLcmImageName"] -and -not [String]::IsNullOrWhiteSpace($inputData.common.vLcmImageName)) {
        Write-LogMessage -Type DEBUG -Message "Validating common.vLcmImageName format..."
        $isValid = Test-JsonPropertyFormat -InputData $inputData -PropertyPath "common.vLcmImageName" -ValidationPreset "vSphereObject80Characters"
        if (-not $isValid) {
            Write-LogMessage -Type ERROR -Message "Invalid common.vLcmImageName format. Value must conform to vSphere object naming (e.g. up to 80 characters, alphanumeric, spaces, hyphens, underscores, parentheses)."
            $validationFailures++
        }
    }
    foreach ($cluster in $clustersInScope) {
        $currentEdgeSite = $cluster.edgeSite
        if ($null -eq $cluster.PSObject.Properties["vLcmImageName"] -or [String]::IsNullOrWhiteSpace($cluster.vLcmImageName)) {
            continue
        }
        Write-LogMessage -Type DEBUG -Message "Validating vLcmImageName format for cluster edgeSite `"$currentEdgeSite`"..."
        $isValid = Test-JsonPropertyFormat -InputData $cluster.vLcmImageName -ValidationPreset "vSphereObject80Characters"
        if (-not $isValid) {
            Write-LogMessage -Type ERROR -Message "Invalid vLcmImageName format in cluster `"$currentEdgeSite`". Value must conform to vSphere object naming (e.g. up to 80 characters, alphanumeric, spaces, hyphens, underscores, parentheses)."
            $validationFailures++
        }
    }

    # Test supervisor service YAML path resolution (per cluster). Argo paths when Argo is enabled; Harbor Carvel YAML paths when Harbor is enabled. Skipped when ComputeOnly or both services disabled for all clusters in scope.
    if (-not $ComputeOnly -and $clustersInScope.Count -gt 0 -and ($anyArgoEnabledForScope -or $anyHarborEnabledForScope)) {
        $validationFailures += Test-JsonYamlFilePaths -InputData $inputData -ClustersToValidate $clustersInScope
    }

    # Per-site validations: numeric ranges, workload service CIDR, and RFC1123 network names.
    # All three require supervisor siteSpec data; share one guard.
    if ($siteSpecsInScope.Count -gt 0) {
        $validationFailures += Test-JsonNumericPropertiesWithRanges -SiteSpecsToValidate $siteSpecsInScope
        # Validate workloadServiceCount as a valid CIDR range (/8 to /32).
        $validationFailures += Test-JsonWorkloadServiceCount -SiteSpecsToValidate $siteSpecsInScope
        # Require lowercase RFC1123 network names for WCP compliance (vcenter.wcp.dns.name.noncompliant).
        $validationFailures += Test-JsonRfc1123NetworkNames -SiteSpecsToValidate $siteSpecsInScope
    }

    # Warn when the LB virtual server network IP count is below the recommended minimum of 30.
    if (-not $ComputeOnly -and $clustersInScope.Count -gt 0 -and $siteSpecsInScope.Count -gt 0) {
        $validationFailures += Test-JsonLbVirtualServerIpCount -ClustersToValidate $clustersInScope -InputData $inputData -SiteSpecsToValidate $siteSpecsInScope
    }

    # Require that all network segments be lowercase RFC1123 compliant for WCP/Kubernetes compatibility.
    # vcenter.wcp.dns.name.noncompliant error will be thrown by vCenter if not compliant.
    if ($clustersInScope.Count -gt 0) {
        $validationFailures += Test-JsonRfc1123NetworkSegments -ClustersToValidate $clustersInScope
    }

    # Validate networking: networkingVmKernelInterfaces (ipList exactly two unique IPv4s, valid netmask, VLAN 0-4095, services exactly vMotion/vSAN/vSAN Witness), networkSegments VLAN 0-4095.
    if ($clustersInScope.Count -gt 0) {
        $validationFailures += Test-JsonNetworkingVmKernelAndTemporaryIp -ClustersToValidate $clustersInScope
    }

    # Validate VM class names follow RFC1123 format (per cluster). Used for Argo CD namespace VM classes when specified.
    if ($anyArgoEnabledForScope -and $clustersInScope.Count -gt 0) {
        $validationFailures += Test-JsonRfc1123VmClassNames -ClustersToValidate $clustersInScope
    }

    # Validate DNS servers from commonSupervisorSpec (shared across all networks).
    if (-not $ComputeOnly) {
        $validationFailures += Test-JsonDnsServers -SupervisorData $supervisorData
    }

    # Storage policy type validation (per cluster).
    if ($clustersInScope.Count -gt 0) {
        $validationFailures += Test-JsonStoragePolicyTypes -ClustersToValidate $clustersInScope
    }

    # vSAN witness FQDN validation (required when storage type is VSAN-OSA or VSAN-ESA).
    if ($clustersInScope.Count -gt 0) {
        $validationFailures += Test-JsonvSanWitnessVmName -ClustersToValidate $clustersInScope -InputData $inputData
    }

    # haPolicy (optional): when defined at common or cluster root, must be slotBased, reservationBased, or disabled.
    if ($clustersInScope.Count -gt 0) {
        $validationFailures += Test-JsonHaPolicy -ClustersToValidate $clustersInScope -InputData $inputData
    }

    # ESX host count validation based on storage policy type (per cluster).
    if ($clustersInScope.Count -gt 0) {
        $validationFailures += Test-JsonEsxHostCountByStoragePolicyType -ClustersToValidate $clustersInScope
    }

    # ESX host format validation (IP address or FQDN) (per cluster).
    if ($clustersInScope.Count -gt 0) {
        $validationFailures += Test-JsonEsxHostFormats -ClustersToValidate $clustersInScope
    }

    # Harbor configuration validation (per cluster: required stanza when Harbor not disabled, hostname format, optional volume sizes).
    if (-not $ComputeOnly -and $clustersInScope.Count -gt 0) {
        $validationFailures += Test-JsonHarborConfiguration -ClustersToValidate $clustersInScope -InputData $inputData
    }

    # Foundation Load Balancer configuration validation (size, provider, network type, availability).
    if (-not $ComputeOnly) {
        $validationFailures += Test-JsonFlbConfiguration -SupervisorData $supervisorData
    }

    # Supervisor control plane configuration validation (size, VM count).
    if (-not $ComputeOnly) {
        $validationFailures += Test-JsonControlPlaneConfiguration -SupervisorData $supervisorData
    }

    # Starting IP address property validation (per site).
    if ($siteSpecsInScope.Count -gt 0) {
        $validationFailures += Test-JsonStartingIpAddresses -SiteSpecsToValidate $siteSpecsInScope
    }

    # Validate that starting IP addresses are within their respective CIDR ranges.
    if (-not $ComputeOnly -and $clustersInScope.Count -gt 0 -and $siteSpecsInScope.Count -gt 0) {
        $validationFailures += Test-JsonIpAddressesInCidrRanges -ClustersToValidate $clustersInScope -SupervisorData $supervisorData
    }

    if ($validationFailures -gt 0) {
        Write-LogMessage -Type ERROR -prependNewLine -Message "JSON parameter validation failed with $validationFailures error(s)."
        throw [VcfDeploymentException]::new("JSON parameter validation failed with $validationFailures error(s).")
    } else {
        Write-LogMessage -Type DEBUG -Message "JSON parameter validation passed."
    }

    $deeperValidationFunctionElapsed = (Get-Date) - $deeperValidationFunctionStartTime
    $siteIndication = if ($edgeSitesArray.Count -gt 0) { "edgeSite(s) `"$($edgeSitesArray -join '", "')`"" } else { "all sites" }
    Write-LogMessage -Type DEBUG -Message "Test-JsonDeeperValidation completed all validation calls for $siteIndication in $($deeperValidationFunctionElapsed.TotalSeconds.ToString('F3')) seconds."
}
Function Find-Datastore {

    <#
        .SYNOPSIS
        Locates a datastore on an ESX host or selects the largest available unformatted disk for VMFS creation.

        .DESCRIPTION
        The Find-Datastore function searches for a specified datastore on an ESX host and validates its configuration.
        If the datastore is not found, the function selects the largest available unformatted disk by capacity (then
        CanonicalName) for VMFS datastore creation. No interactive disk selection; the only deployment option for VMFS
        is to use the largest free disk.

        The function performs the following operations:
        1. Checks if the specified datastore exists and is mounted on the ESX host
        2. If found, validates that the datastore is VMFS formatted and reports its status
        3. If not found, scans for available unformatted disks and selects the largest by capacity
        4. Returns the canonical name of the selected or existing disk for subsequent datastore creation

        Key features:
        - Validates existing datastore mount status and VMFS formatting
        - When datastore is not found, automatically selects the largest unformatted disk (no menu or prompt)
        - Returns canonical disk name for programmatic use in datastore creation workflows
        - Exits with error if no valid datastore or no unformatted disks are available

        .PARAMETER EsxHostName
        The hostname or IP address of the ESX host to scan. This parameter is mandatory.
        Requires an active direct connection to the ESX host.

        .PARAMETER DatastoreName
        The name of the datastore to locate on the ESX host. This parameter is mandatory.
        If the datastore is not found, the function selects the largest available unformatted disk.

        .EXAMPLE
        Find-Datastore -EsxHostName "esx01.example.com" -DatastoreName "datastore1"

        Searches for "datastore1" on the specified ESX host.
        If found and VMFS formatted, reports the datastore status.
        If not found, selects the largest available unformatted disk and returns its canonical name.

        .EXAMPLE
        $diskCanonicalName = Find-Datastore -EsxHostName $EsxHost -DatastoreName $requiredDatastore
        Set-NewDatastore -EsxHost $EsxHost -DiskCanonicalName $diskCanonicalName -DatastoreName $requiredDatastore

        Uses the function within a deployment workflow to locate or select storage (largest free disk only).

        .OUTPUTS
        String. Returns the canonical name of either the largest unformatted disk (when datastore does not exist)
        or the existing datastore's underlying disk canonical name. Throws if no valid selection or unexpected type.

        .NOTES
        - Requires an active direct connection to the ESX host
        - VMFS deployment uses only the largest available unformatted disk; no interactive selection
        - If datastore exists but is not VMFS formatted, the function throws an exception
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DatastoreName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EsxHostName
    )
    Write-LogMessage -Type DEBUG -Message "Entered Find-Datastore function..."

    # Step 1: Check if specific datastore exists.
    $getDatastoreParams = @{
        esxHostName = $EsxHostName
        datastoreName = $DatastoreName
        silence = $true
    }
    $result = Get-EsxDatastoreInfo @getDatastoreParams

    if (-not $result.MountedDatastoreStatus.IsMounted) {
        # Step 2: Datastore NOT found. Select largest unformatted disk by capacity then CanonicalName.
        Write-LogMessage -Type INFO -Message "Datastore `"$DatastoreName`" not found on ESX host `"$EsxHostName`"."
        $unformattedOnlyParams = @{
            EsxHostName = $EsxHostName
            Silence = $true
        }
        $unformattedResult = Get-EsxDatastoreInfo @unformattedOnlyParams
        $unformattedDisks = $unformattedResult.UnformattedDisks
        if (-not $unformattedDisks -or $unformattedDisks.Count -eq 0) {
            Write-LogMessage -Type ERROR -Message "No unformatted disks found on ESX host `"$EsxHostName`". Cannot create VMFS datastore `"$DatastoreName`"."
            throw [VcfDeploymentException]::new("Deployment failed. No unformatted disks available on host `"$EsxHostName`". Check logs for details.")
        }
        $selectedDisk = $unformattedDisks | Sort-Object -Property @{ Expression = { [double]$_.CapacityGB }; Descending = $true }, @{ Expression = { $_.CanonicalName }; Ascending = $true } | Select-Object -First 1
        Write-LogMessage -Type INFO -Message "Selected largest available drive for VMFS (CapacityGB=$($selectedDisk.CapacityGB), CanonicalName=$($selectedDisk.CanonicalName))."
        return $selectedDisk.CanonicalName
    }
    else {
        # Datastore found - verify it's VMFS and healthy.
        if ($result.MountedDatastoreStatus.IsVMFS) {
            Write-LogMessage -Type INFO -Message "Datastore `"$DatastoreName`" is already mounted on ESX host `"$EsxHostName`" and has $($result.MountedDatastoreStatus.FreeSpaceGB) GB free space."
            Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "$DatastoreName UUID is $($result.MountedDatastoreStatus.UUID)"
            # Datastore already exists - return its canonical name from the result object.

            if ($result.MountedDatastoreStatus.CanonicalName) {
                Write-LogMessage -Type INFO -Message "Retrieved canonical name for existing datastore `"$DatastoreName`": $($result.MountedDatastoreStatus.CanonicalName)."
                return $result.MountedDatastoreStatus.CanonicalName
            }
            else {
                Write-LogMessage -Type ERROR -Message "Could not retrieve canonical name for datastore `"$DatastoreName`""
                throw [VcfDeploymentException]::new("Could not retrieve canonical name for datastore `"$DatastoreName`"")
            }
        }
        else {
            Write-LogMessage -Type ERROR -Message "Datastore `"$DatastoreName`" is mounted, but in unexpected type: (Type: $($result.MountedDatastoreStatus.Type)). Cannot proceed."
            throw [VcfDeploymentException]::new("Datastore `"$DatastoreName`" is mounted, but in unexpected type: (Type: $($result.MountedDatastoreStatus.Type)). Cannot proceed.")
        }
    }
}
Function Find-VlcmImage {

    <#
        .SYNOPSIS
        Locates a vLCM image on the attached vCenter or prompts for interactive selection.

        .DESCRIPTION
        The Find-VlcmImage function retrieves available vLCM images from the attached vCenter using
        Invoke-EsxSettingsRepositorySoftwareList and presents them for user selection. The function
        displays each image's DisplayName and non-null SoftwareSpec components, allowing the user
        to choose an appropriate image for deployment.

        The function performs the following operations:
        1. Retrieves all available vLCM images from the attached vCenter using Invoke-EsxSettingsRepositorySoftwareList
        2. Displays each image's DisplayName and SoftwareSpec details in a formatted table with proper spacing
        3. Prompts the user to select an image by number (selection cannot be skipped)
        4. Returns the selected image's ID for use in subsequent operations (typically passed to Get-LcmSoftwareSpecification)

        Key features:
        - Interactive image selection with detailed SoftwareSpec information
        - Shows BaseImage (always present) and other non-null SoftwareSpec components as separate columns
        - Formatted output with blank line separation between table and prompt for improved readability
        - Validates user input and provides clear error messages
        - Returns image ID string for programmatic use in deployment workflows
        - User must select an image or enter 'c' to cancel (which throws an exception)

        .PARAMETER None
        This function requires no parameters. It uses the currently attached vCenter connection.

        .EXAMPLE
        $imageId = Find-VlcmImage

        Retrieves available vLCM images and prompts for user selection, returning the selected image ID.

        .EXAMPLE
        # Within a deployment workflow.

        $selectedImageId = Find-VlcmImage
        if ($selectedImageId) {
            Write-LogMessage -Type INFO -Message "Selected image ID: $selectedImageId"
            # Proceed with deployment using $selectedImageId.

        }

        Uses the function as part of an automated deployment workflow to select a vLCM image.

        .OUTPUTS
        String. Returns the ID of the selected vLCM image (e.g., "software-spec-1").
        Throws an exception if the user enters 'c' to cancel.

        .NOTES
        - Requires an active vCenter connection (Connect-VIServer)
        - Requires PowerCLI modules to be installed (VMware.VimAutomation.Core)
        - Uses Invoke-EsxSettingsRepositorySoftwareList internally for image discovery
        - Interactive selection requires user input and cannot be fully automated
        - Selection cannot be skipped - user must select an image (1-N) or cancel ('c')
        - If user cancels, the function throws an exception to stop deployment
        - Uses Write-LogMessage for consistent logging throughout the script
        - Follows the error handling patterns of the VcfEdgeAtScale module

        .PARAMETER VlcmImageName
        Optional. When specified (e.g. from infrastructure JSON), the function attempts to find an image
        whose Id or DisplayName matches this value. If found, that image is displayed and its Id is returned
        without prompting. If not found, a warning is logged and the function falls back to interactive selection.
    #>

    Param (
        [Parameter(Mandatory = $false)] [AllowNull()] [String]$VlcmImageName
    )

    Write-LogMessage -Type DEBUG -Message "Entered Find-VlcmImage function..."

    # Step 1: Retrieve available vLCM images from vCenter.
    if ([string]::IsNullOrWhiteSpace($VlcmImageName)) {
        Write-LogMessage -Type INFO -PrependNewLine -Message "Retrieving list of vLCM images from vCenter's Image Catalog..."
    }
    try {
        $imageList = Invoke-EsxSettingsRepositorySoftwareList -ErrorAction Stop
    } catch [VcfDeploymentException] {
        throw  # already logged and typed — propagate without re-wrapping
    } catch {
        Write-LogMessage -Type ERROR -Message "Failed to retrieve vLCM images: $($_.Exception.Message)"
        throw [VcfDeploymentException]::new("Failed to retrieve vLCM images: $($_.Exception.Message)")
    }

    # Check if no images are available and exit if none found.
    $imageCount = 0
    if ($null -ne $imageList -and $null -ne $imageList.Records) {
        $imageCount = $imageList.Records.Count
    }

    if ($imageCount -eq 0) {
        Write-LogMessage -Type INFO -Message "Available vLCM images:"
        Write-Host ""
        Write-LogMessage -Type ERROR -Message "No vLCM images found in the repository. Cannot proceed with deployment."
        throw [VcfDeploymentException]::new("Deployment failed. No vLCM images available. Check logs for details.")
    }

    Write-LogMessage -Type DEBUG -Message "Found $($imageList.Records.Count) vLCM image(s) available."

    # Step 2: Helper function to extract SoftwareSpec components as a hashtable.
    function Get-SoftwareSpecComponents {
        param (
            [Parameter(Mandatory = $true)] [AllowNull()] [PSObject]$SoftwareSpec
        )

        # Define the keys we care about and how they should be handled.
        $fieldMap = @(
            @{ Key = "AlternativeImages"; Label = "AlternativeImages"; IsCollection = $true },
            @{ Key = "AddOn";             Label = "AddOn" },
            @{ Key = "BaseImage";         Label = "BaseImage"; IsVersion = $true },
            @{ Key = "Components";        Label = "Components"; IsCollection = $true },
            @{ Key = "HardwareSupport";   Label = "HardwareSupport" },
            @{ Key = "RemovedComponents"; Label = "RemovedComponents"; IsCollection = $true },
            @{ Key = "Solutions";         Label = "Solutions"; IsCollection = $true }
        )

        # Initialize result with nulls.
        $results = [ordered]@{ }
        foreach ($field in $fieldMap) {
            $results[$field.Key] = $null
        }

        if ($null -eq $SoftwareSpec) {
            return $results
        }

        # Case 1: SoftwareSpec is an Object (PSObject/Dictionary/etc).
        if ($SoftwareSpec -isnot [string]) {
            foreach ($field in $fieldMap) {
                $val = $SoftwareSpec.$($field.Key)

                if ($null -ne $val) {
                    if ($field.IsVersion -and $null -ne $val.Version) {
                        $results[$field.Key] = $val.Version
                    }
                    elseif ($field.IsCollection -and $val.Count -gt 0) {
                        $results[$field.Key] = $val.Keys -join ", "
                    }
                    elseif ($val -ne "") {
                        $results[$field.Key] = $val
                    }
                }
            }
        }
        else {
            # Case 2: SoftwareSpec is a string - parse it to extract components.
            $softwareSpecString = $SoftwareSpec.ToString()

            foreach ($field in $fieldMap) {
                if ($field.IsVersion) {
                    # BaseImage has special format: "BaseImage: Version: <value>".

                    if ($softwareSpecString -match "$($field.Label):\s*Version:\s*([^,]+)") {
                        $extractedValue = $matches[1].Trim()
                        if ($extractedValue -and $extractedValue -ne "") {
                            $results[$field.Key] = $extractedValue
                        }
                    }
                }
                else {
                    # Other fields use format: "Label: <value>".

                    if ($softwareSpecString -match "$($field.Label):\s*([^,]+)") {
                        $extractedValue = $matches[1].Trim()
                        if ($extractedValue -and $extractedValue -ne "") {
                            $results[$field.Key] = $extractedValue
                        }
                    }
                }
            }
        }

        return $results
    }

    # Step 3: First pass - determine which columns are needed across all records.
    $availableColumns = @{
        BaseImage = $false
        AddOn = $false
        Components = $false
        Solutions = $false
        HardwareSupport = $false
        RemovedComponents = $false
        AlternativeImages = $false
    }

    # Create a copy of keys to avoid enumeration modification error.
    $columnKeys = @('BaseImage', 'AddOn', 'Components', 'Solutions', 'HardwareSupport', 'RemovedComponents', 'AlternativeImages')

    foreach ($record in $imageList.Records) {
        $specComponents = Get-SoftwareSpecComponents -SoftwareSpec $record.SoftwareSpec
        foreach ($key in $columnKeys) {
            if ($null -ne $specComponents[$key] -and $specComponents[$key] -ne "") {
                $availableColumns[$key] = $true
            }
        }
    }

    # Step 4: Build column list (BaseImage always included, others only if found).
    $columnList = [System.Collections.Generic.List[string]]@('ID', 'DisplayName', 'BaseImage')
    foreach ($key in @('AddOn', 'Components', 'Solutions', 'HardwareSupport', 'RemovedComponents', 'AlternativeImages')) {
        if ($availableColumns[$key]) {
            $columnList.Add($key)
        }
    }

    # Step 5: Prepare image data for display with individual columns.
    $imageSelectionList = [System.Collections.Generic.List[PSCustomObject]]::new()
    $index = 1

    foreach ($record in $imageList.Records) {
        $specComponents = Get-SoftwareSpecComponents -SoftwareSpec $record.SoftwareSpec

        # Build hashtable with required columns.
        $imageHash = @{
            ID = $index
            DisplayName = $record.DisplayName
            BaseImage = if ($specComponents.BaseImage) { $specComponents.BaseImage } else { "(not available)" }
            ImageId = $record.Id
        }

        # Add other columns only if they're available across any record.
        if ($availableColumns.AddOn) {
            $imageHash['AddOn'] = if ($specComponents.AddOn) { $specComponents.AddOn } else { "" }
        }
        if ($availableColumns.Components) {
            $imageHash['Components'] = if ($specComponents.Components) { $specComponents.Components } else { "" }
        }
        if ($availableColumns.Solutions) {
            $imageHash['Solutions'] = if ($specComponents.Solutions) { $specComponents.Solutions } else { "" }
        }
        if ($availableColumns.HardwareSupport) {
            $imageHash['HardwareSupport'] = if ($specComponents.HardwareSupport) { $specComponents.HardwareSupport } else { "" }
        }
        if ($availableColumns.RemovedComponents) {
            $imageHash['RemovedComponents'] = if ($specComponents.RemovedComponents) { $specComponents.RemovedComponents } else { "" }
        }
        if ($availableColumns.AlternativeImages) {
            $imageHash['AlternativeImages'] = if ($specComponents.AlternativeImages) { $specComponents.AlternativeImages } else { "" }
        }

        $imageSelectionList.Add([PSCustomObject]$imageHash)
        $index++
    }

    # When VlcmImageName is specified, try to match by Id or DisplayName; if found, display and return without prompting.
    if (-not [String]::IsNullOrWhiteSpace($VlcmImageName)) {
        $matchedRecord = $imageList.Records | Where-Object { $_.Id -eq $VlcmImageName -or $_.DisplayName -eq $VlcmImageName } | Select-Object -First 1
        if ($matchedRecord) {
            $specComponents = Get-SoftwareSpecComponents -SoftwareSpec $matchedRecord.SoftwareSpec
            $baseImageValue = if ($specComponents.BaseImage) { $specComponents.BaseImage } else { "(not available)" }
            $oneRow = [PSCustomObject]@{
                DisplayName = $matchedRecord.DisplayName
                BaseImage   = $baseImageValue
            }
            Write-LogMessage -Type INFO -Message "Using vLCM image from configuration: `"$VlcmImageName`"."
            # This must be a write-host otherwise the table doesn't render
            $oneRow | Format-Table -AutoSize | Out-String | ForEach-Object { $_.TrimEnd() } | Write-Host
            Write-LogMessage -Type DEBUG -Message "Find-VlcmImage: matched image Id=$($matchedRecord.Id), DisplayName=$($matchedRecord.DisplayName)."
            return $matchedRecord.Id
        }
        Write-LogMessage -Type WARNING -Message "Specified vLcmImageName `"$VlcmImageName`" was not found in vCenter image library. Showing available images for selection."
    }

    # Step 6: Display formatted table of available images.
    Write-LogMessage -Type INFO -Message "Available vLCM images:"
    $selectionTable = $imageSelectionList | Select-Object $columnList
    $tableOutput = $selectionTable | Format-Table -AutoSize | Out-String
    # Remove trailing newlines from Out-String, then write table and add one blank line before prompt.
    $tableOutput = $tableOutput.TrimEnd()
    # Table and blank line use Write-Host so interactive table renders correctly; Write-Output can introduce regression.
    Write-Host $tableOutput
    Write-Host ""

    # Step 7: Prompt user for selection.
    $validSelection = $false
    $selectedId = $null

    while (-not $validSelection) {
        Write-Host "Enter the ID of the image to select (1-$($imageSelectionList.Count)) or `"c`" to cancel: " -NoNewline
        $userInput = Read-Host

        # Check for cancel option.
        if ($userInput -eq 'c' -or $userInput -eq 'C') {
            Write-Host ""
            Write-LogMessage -Type WARNING -Message "User cancelled vLCM image selection."
            Write-LogMessage -Type ERROR -Message "vLCM image selection cancelled. Cannot proceed with deployment."
            throw [VcfDeploymentException]::new("vLCM image selection cancelled. Cannot proceed with deployment.")
        }
        elseif ($userInput -match '^\d+$') {
            $selectedId = [int]$userInput

            if ($selectedId -ge 1 -and $selectedId -le $imageSelectionList.Count) {
                $selectedImage = $imageSelectionList | Where-Object { $_.ID -eq $selectedId }
                Write-Host ""
                Write-LogMessage -Type DEBUG -Message "Selected image: $($selectedImage.DisplayName) - ID: $($selectedImage.ImageId)"
                # Return the image's ID.
                return $selectedImage.ImageId
            }
            else {
                Write-LogMessage -Type WARNING -Message "Invalid selection. Please enter a number between 1 and $($imageSelectionList.Count), or `"c`" to cancel."
            }
        }
        else {
            Write-LogMessage -Type WARNING -Message "Invalid input. Please enter a number between 1 and $($imageSelectionList.Count), or `"c`" to cancel."
        }
    }
}

#endregion
