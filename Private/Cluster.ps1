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
#region Private — cluster, datastore, vSAN, VMFS, disk operations
Function Add-Cluster {

    <#
        .SYNOPSIS
        Creates a new vSphere cluster with DRS and HA enabled in a specified datacenter.

        .DESCRIPTION
        The Add-Cluster function creates a new vSphere compute cluster within a specified
        datacenter on a vCenter. The function includes comprehensive validation to
        ensure the target datacenter exists and prevents duplicate cluster creation. It
        automatically configures the cluster with Distributed Resource Scheduler (DRS)
        and High Availability (HA) enabled for optimal resource management and availability.

        The function prompts the user to interactively select a vLCM image from the
        vCenter's image catalog using Find-VlcmImage. The selected image's software
        specification is then retrieved using Get-LcmSoftwareSpecification and applied
        to the cluster during creation, ensuring the cluster is configured with the
        desired ESX image specification.

        Key features:
        - Pre-creation validation of datacenter existence
        - Duplicate cluster detection and prevention
        - Interactive vLCM image selection for cluster software specification
        - Automatic software specification object retrieval and validation
        - Automatic DRS and HA enablement
        - Comprehensive error handling and logging
        - Integration with VCF PowerShell Toolbox logging infrastructure

        The function will throw an exception if the target datacenter is not found, if
        the software specification cannot be retrieved, or if cluster creation fails,
        ensuring that subsequent operations don't proceed with invalid cluster configurations.

        .PARAMETER ClusterCreationDelaySeconds
        Seconds to wait after New-Cluster completes before verifying the cluster exists. Allows vCenter to stabilize before subsequent operations (e.g. adding hosts). Default is 5.

        .PARAMETER ClusterName
        The name of the new cluster to create. This name must be unique within the
        specified datacenter and should follow VMware naming conventions. The cluster
        name will be used for identification and management purposes.

        .PARAMETER DataCenterName
        The name of the datacenter where the cluster will be created. This datacenter
        must already exist in the specified vCenter. The function will validate
        the datacenter's existence before attempting cluster creation.

        .EXAMPLE
        Add-Cluster -ClusterName "Production-Cluster-01" -DataCenterName "Datacenter1"

        Creates a new cluster named "Production-Cluster-01" in "Datacenter1" on the specified vCenter.

        .EXAMPLE
        Add-Cluster -clusterName $clusterName -dataCenterName $datacenterName

        Creates a cluster using variables for dynamic cluster deployment scenarios.

        .NOTES
        This function requires an active PowerCLI connection to the specified vCenter.
        The function will throw an exception if critical errors occur, such as datacenter
        not found, software specification retrieval failure, or cluster creation failure.
        DRS is configured in fully automated mode, and HA is enabled with default settings.
        The function uses Find-VlcmImage to prompt the user for vLCM image selection and
        Get-LcmSoftwareSpecification to retrieve the software specification object for
        cluster creation.
    #>

    [CmdletBinding(SupportsShouldProcess)]
    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(0, [int]::MaxValue)] [Int]$ClusterCreationDelaySeconds = 5,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DataCenterName,
        [Parameter(Mandatory = $false)] [AllowNull()] [String]$VlcmImageName,
        [Parameter(Mandatory = $false)] [Switch]$VsanEsaEnabled,
        [Parameter(Mandatory = $false)] [Switch]$VsanOsaEnabled
    )
    Write-LogMessage -Type DEBUG -Message "Entered Add-Cluster function..."
    $vlcmImageNameParamDisplay = if ([String]::IsNullOrWhiteSpace($VlcmImageName)) { "(none)" } else { "`"$VlcmImageName`"" }
    Write-LogMessage -Type DEBUG -Message "Add-Cluster parameters: ClusterName=`"$ClusterName`", DataCenterName=`"$DataCenterName`", VsanEsaEnabled=$($VsanEsaEnabled.IsPresent), VsanOsaEnabled=$($VsanOsaEnabled.IsPresent), VlcmImageName=$vlcmImageNameParamDisplay."

    $connectionTest = Test-VcenterConnection
    if (-not $connectionTest.IsConnected) {
        Write-LogMessage -Type ERROR -Message "Not connected to vCenter `"$Script:vCenterName`": $($connectionTest.ErrorMessage)"
        throw [VcfDeploymentException]::new("Not connected to vCenter `"$Script:vCenterName`": $($connectionTest.ErrorMessage)")
    }

    try {
        $dataCenterFound = Get-Datacenter -Name $DataCenterName -Server $Script:vCenterName -ErrorAction Ignore
    } catch [System.UnauthorizedAccessException] {
        Write-LogMessage -Type ERROR -Message "Cannot perform Get-Datacenter operation for `"$DataCenterName`" due to authorization issues: $($_.Exception.Message)"
        throw [VcfDeploymentException]::new("Cannot perform Get-Datacenter operation for `"$DataCenterName`" due to authorization issues: $($_.Exception.Message)")
    }
    catch [System.TimeoutException] {
        Write-LogMessage -Type ERROR -Message "Cannot perform Get-Datacenter operation for `"$DataCenterName`" due to network/timeout issues: $($_.Exception.Message)"
        throw [VcfDeploymentException]::new("Cannot perform Get-Datacenter operation for `"$DataCenterName`" due to network/timeout issues: $($_.Exception.Message)")
    } catch [VcfDeploymentException] {
        throw  # already logged and typed — propagate without re-wrapping
    } catch {
        Write-LogMessage -Type ERROR -AppendNewLine -Message "Failed to perform Get-Datacenter operation on `"$DataCenterName`" : $($_.Exception.Message)"
        throw [VcfDeploymentException]::new("Failed to perform Get-Datacenter operation on `"$DataCenterName`" : $($_.Exception.Message)")
    }

    if (-not $dataCenterFound) {
        Write-LogMessage -Type ERROR -AppendNewLine -Message "The datacenter `"$DataCenterName`" could not be found on vCenter `"$Script:vCenterName`". Exiting."
        throw [VcfDeploymentException]::new("The datacenter `"$DataCenterName`" could not be found on vCenter `"$Script:vCenterName`". Exiting.")
    }
    Write-LogMessage -Type DEBUG -Message "Datacenter `"$DataCenterName`" found on vCenter `"$Script:vCenterName`"."

    $clusterFound = $null
    try {
        $clusterFound = Get-Cluster -Name $ClusterName -location $DataCenterName -ErrorAction Stop -Server $Script:vCenterName
    } catch {
        $clusterFound = $null
        Write-LogMessage -Type INFO -Message "No cluster named `"$ClusterName`" was found on vCenter `"$Script:vCenterName`". Proceeding with cluster creation."
    }
    if ($clusterFound) {
        Write-LogMessage -Type DEBUG -Message "Cluster `"$ClusterName`" already exists in datacenter `"$DataCenterName`" (Id: $($clusterFound.Id))."
    }
    if (-not $clusterFound) {
        try {
            # Resolve vLCM image: use VlcmImageName when provided (from infrastructure JSON); otherwise prompt for selection.
            $findVlcmParams = @{}
            if (-not [String]::IsNullOrWhiteSpace($VlcmImageName)) {
                $findVlcmParams["VlcmImageName"] = $VlcmImageName
            }
            $softwareSpecificationId = Find-VlcmImage @findVlcmParams
            Write-LogMessage -Type DEBUG -Message "Add-Cluster: selected vLCM image / software specification ID: $softwareSpecificationId."
            Write-LogMessage -Type DEBUG -Message "Retrieving software specification object for ID: $softwareSpecificationId."
            try {
                $softwareSpecification = Get-LcmSoftwareSpecification -Id $softwareSpecificationId -ErrorAction Stop
            } catch [VcfDeploymentException] {
                throw  # already logged and typed — propagate without re-wrapping
            } catch {
                Write-LogMessage -Type ERROR -Message "Failed to retrieve software specification with ID `"$softwareSpecificationId`": $($_.Exception.Message)"
                throw [VcfDeploymentException]::new("Failed to retrieve software specification with ID `"$softwareSpecificationId`": $($_.Exception.Message)")
            }
            if ($null -eq $softwareSpecification) {
                Write-LogMessage -Type ERROR -Message "Software specification with ID `"$softwareSpecificationId`" was not found."
                throw [VcfDeploymentException]::new("Software specification with ID `"$softwareSpecificationId`" was not found.")
            }
            $specId = if ($softwareSpecification.Id) { $softwareSpecification.Id } else { "N/A" }
            $specName = if ($softwareSpecification.Name) { $softwareSpecification.Name } else { "N/A" }
            Write-LogMessage -Type DEBUG -Message "Successfully retrieved software specification object (Id=$specId, Name=$specName)."

            $newClusterParams = @{
                Name = $ClusterName
                Location = $DataCenterName
                DrsEnabled = $true
                HAEnabled = $true
                SoftwareSpecification = $softwareSpecification
                Server = $Script:vCenterName
                ErrorAction = "Stop"
            }
            Write-LogMessage -Type DEBUG -Message "Add-Cluster: base cluster construct: Name=$ClusterName, Location=$DataCenterName, DrsEnabled=$true, HAEnabled=$true, Server=$Script:vCenterName, SoftwareSpecification=[Id=$specId]."

            # Add VsanEnabled and VsanEsaEnabled flags if specified.
            # vSAN must be enabled before vSAN ESA can be enabled. For OSA use VsanOsaEnabled; for ESA use VsanEsaEnabled (implies VsanEnabled).
            if ($VsanEsaEnabled) {
                $newClusterParams["VsanEnabled"] = $true
                $newClusterParams["VsanEsaEnabled"] = $true
                Write-LogMessage -Type DEBUG -Message "Enabling vSAN and vSAN ESA on cluster `"$ClusterName`"."
            }
            elseif ($VsanOsaEnabled) {
                $newClusterParams["VsanEnabled"] = $true
                Write-LogMessage -Type DEBUG -Message "Enabling vSAN OSA on cluster `"$ClusterName`"."
            }
            $vsanStatus = if ($newClusterParams["VsanEsaEnabled"]) { "vSAN ESA" } elseif ($newClusterParams["VsanEnabled"]) { "vSAN OSA" } else { "none" }
            Write-LogMessage -Type DEBUG -Message "Add-Cluster: full cluster construct: Name=$($newClusterParams.Name), Location=$($newClusterParams.Location), DrsEnabled=$($newClusterParams.DrsEnabled), HAEnabled=$($newClusterParams.HAEnabled), Vsan=$vsanStatus, SoftwareSpecification Id=$specId. Invoking New-Cluster."

            Write-LogMessage -Type INFO -PrependNewLine -NoNewline -Message "Creating the cluster `"$ClusterName`" on vCenter `"$Script:vCenterName`"... "
            if ($PSCmdlet.ShouldProcess("cluster `"$ClusterName`" on vCenter `"$Script:vCenterName`"", "New-Cluster")) {
                New-Cluster @newClusterParams | Out-Null
            }
            Write-LogMessage -Type DEBUG -Message "Add-Cluster: New-Cluster completed; verifying cluster exists."
            if ($ClusterCreationDelaySeconds -gt 0) {
                Write-LogMessage -Type DEBUG -Message "Add-Cluster: waiting $ClusterCreationDelaySeconds second(s) for vCenter to stabilize before verification."
                Start-Sleep -Seconds $ClusterCreationDelaySeconds
            }
            $clusterFound = Get-Cluster -Name $ClusterName -location $DataCenterName -ErrorAction Stop -Server $Script:vCenterName
            Write-LogMessage -Type DEBUG -Message "Add-Cluster: verification Get-Cluster succeeded; cluster Id=$($clusterFound.Id), Name=$($clusterFound.Name)."
            Set-VclsRetreatModeForCluster -ClusterName $ClusterName -Server $Script:vCenterName
        } catch [System.UnauthorizedAccessException] {
            Write-LogMessage -Type ERROR -CompletePending -Message " Failed (authorization)."
            throw [VcfDeploymentException]::new(" Failed (authorization).")
        }
        catch [System.TimeoutException] {
            Write-LogMessage -Type ERROR -CompletePending -Message " Failed (timeout)."
            throw [VcfDeploymentException]::new(" Failed (timeout).")
        } catch {
            Write-LogMessage -Type ERROR -CompletePending -Message " Failed."
            throw [VcfDeploymentException]::new(" Failed.")
        }
    } else {
        Write-LogMessage -Type INFO -Message "The cluster `"$ClusterName`" in datacenter `"$DataCenterName`" is already present. Skipping cluster creation."
        return
    }

    if ($clusterFound) {
        Write-LogMessage -Type INFO -CompletePending -Message " Success"
    } else {
        Write-LogMessage -Type ERROR -Message "Cluster `"$ClusterName`" was not found in datacenter `"$DataCenterName`" on vCenter `"$Script:vCenterName`" after creation attempt."
        throw [VcfDeploymentException]::new("Cluster `"$ClusterName`" was not found in datacenter `"$DataCenterName`" on vCenter `"$Script:vCenterName`" after creation attempt.")
    }
}
Function Remove-ClusterSafely {
    <#
        .SYNOPSIS
        Removes a vSphere cluster after verifying there are no running VMs.

        .DESCRIPTION
        Gets the cluster by name, checks that no VMs in the cluster are powered on
        (excluding vCLS VMs running VMware Photon CRX), then removes the cluster using
        Remove-Cluster. If any running VMs are found (other than excluded vCLS VMs),
        the function throws and does not delete the cluster.

        .PARAMETER ClusterName
        The name of the cluster to remove.

        .EXAMPLE
        Remove-ClusterSafely -ClusterName "cl0-site1"

        .NOTES
        Requires an active vCenter connection. Uses Get-Cluster, Get-VM, and Remove-Cluster.
        Running VMs whose name starts with "vCLS-" and whose guest OS (VMware Tools) is
        "VMware Photon CRX (64-bit)" are excluded from the check and do not block removal.
    #>

    [CmdletBinding(SupportsShouldProcess)]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName
    )

    Write-LogMessage -Type DEBUG -Message "Entered Remove-ClusterSafely for cluster `"$ClusterName`"."

    $connectionTest = Test-VcenterConnection
    if (-not $connectionTest.IsConnected) {
        Write-LogMessage -Type ERROR -Message "Not connected to vCenter `"$Script:vCenterName`": $($connectionTest.ErrorMessage)"
        throw [VcfDeploymentException]::new("Not connected to vCenter `"$Script:vCenterName`": $($connectionTest.ErrorMessage)")
    }

    $clusterObject = Get-Cluster -Name $ClusterName -Server $Script:vCenterName -ErrorAction SilentlyContinue
    if (-not $clusterObject) {
        Write-LogMessage -Type WARNING -Message "Cluster `"$ClusterName`" not found; nothing to remove."
        return
    }

    $vmsInCluster = Get-VM -Location $clusterObject -Server $Script:vCenterName -ErrorAction SilentlyContinue
    $runningVms = $null
    if ($vmsInCluster) {
        $runningVms = @($vmsInCluster | Where-Object { $_.PowerState -eq 'PoweredOn' })
    }
    $blockingVms = [System.Collections.ArrayList]::new()
    $vclsPhotonCrxGuestName = "VMware Photon CRX (64-bit)"
    if ($runningVms -and $runningVms.Count -gt 0) {
        foreach ($vm in @($runningVms)) {
            if ($vm.Name -notlike "vCLS-*") {
                [void]$blockingVms.Add($vm)
                continue
            }
            $guestFullName = $null
            try {
                if ($vm.PSObject.Properties['ExtensionData'] -and $vm.ExtensionData -and $vm.ExtensionData.PSObject.Properties['Guest'] -and $vm.ExtensionData.Guest -and $vm.ExtensionData.Guest.PSObject.Properties['GuestFullName']) {
                    $guestFullName = $vm.ExtensionData.Guest.GuestFullName
                }
                if (-not $guestFullName) {
                    $vmView = Get-View -Id $vm.Id -Server $Script:vCenterName -Property Guest -ErrorAction SilentlyContinue
                    if ($vmView -and $vmView.Guest -and $vmView.Guest.PSObject.Properties['GuestFullName']) {
                        $guestFullName = $vmView.Guest.GuestFullName
                    }
                }
            } catch {
                Write-LogMessage -Type DEBUG -Message "Could not read guest OS for VM `"$($vm.Name)`"; treating as blocking for cluster removal."
            }
            if ($guestFullName -eq $vclsPhotonCrxGuestName) {
                Write-LogMessage -Type DEBUG -Message "Excluding running VM `"$($vm.Name)`" (vCLS with guest $vclsPhotonCrxGuestName) from cluster-removal check."
                continue
            }
            [void]$blockingVms.Add($vm)
        }
    }
    if ($blockingVms.Count -gt 0) {
        $blockingNames = $blockingVms | Select-Object -ExpandProperty Name
        Write-LogMessage -Type ERROR -Message "Cannot remove cluster `"$ClusterName`": $($blockingVms.Count) running VM(s) found: $($blockingNames -join ', '). Power off or migrate VMs first."
        throw [VcfDeploymentException]::new("Deployment failed. Cluster `"$ClusterName`" has running VMs. Power them off or migrate before removing the cluster.")
    }

    Write-LogMessage -Type INFO -NoNewline -Message "Removing cluster `"$ClusterName`" (no running VMs)... "
    if ($PSCmdlet.ShouldProcess("cluster `"$ClusterName`" on vCenter `"$Script:vCenterName`"", "Remove-Cluster")) {
        Remove-Cluster -Cluster $clusterObject -Server $Script:vCenterName -Confirm:$false -ErrorAction Stop
    }
    Write-LogMessage -Type INFO -CompletePending -Message "Removed"
}
Function Update-Cluster {

    <#
        .SYNOPSIS
        Configures vSphere cluster settings for High Availability, DRS, and monitoring optimized for simple deployments.

        .DESCRIPTION
        This function applies cluster configuration for High Availability (HA) and Distributed Resource Scheduler (DRS)
        based on the number of ESX hosts in the cluster.

        Single-host clusters: HA is enabled with admission control disabled (no failover capacity). DRS remains
        enabled with fully automated level. Supervisor creation requires HA enabled even for one-host clusters.

        Multi-host clusters (2 or more ESX hosts): HA and DRS are enabled. Admission control follows -HaPolicy:
        slotBased (host failures the cluster tolerates = 1 via Set-Cluster -HAFailoverLevel), reservationBased
        (cluster CPU and memory percentage via VMware.Vim.ClusterFailoverResourcesAdmissionControlPolicy; percentage
        defaults to ceiling(100 / host count) unless -HaClusterResourceFailoverPercent is set), or disabled (HA on,
        admission control off; VM restart only, no capacity reservation). Host and VM monitoring are applied via
        ReconfigureComputeResource_Task where needed.

        The function performs the following configuration operations:
        1. Validates cluster existence and retrieves cluster objects and host count
        2. For 1 host: Enables HA and DRS; disables HA admission control (no failover capacity)
        3. For 2+ hosts: Applies DRS and HA admission behavior per -HaPolicy (Set-Cluster and/or ReconfigureComputeResource_Task)
        4. Applies configuration changes through Set-Cluster and ReconfigureComputeResource_Task

        Key configuration details:
        - DRS Automation Level: FullyAutomated (all clusters)
        - 1 host: HA enabled; admission control disabled (no failover capacity)
        - 2+ hosts: HA enabled; policy per -HaPolicy; HA Host Monitoring enabled; VM Monitoring vmMonitoringOnly

        .PARAMETER ClusterName
        Specifies the name of the vSphere cluster to be configured. The cluster must already exist
        in the vCenter environment specified by the global $Script:vCenterName variable.
        This parameter is mandatory and must reference a valid, existing cluster.

        .PARAMETER HaClusterResourceFailoverPercent
        For multi-host reservationBased only: CPU and memory failover percentage (1–100). Use 0 (default) to
        auto-compute ceiling(100 / host count).

        .PARAMETER HaPolicy
        Multi-host clusters only: reservationBased (default), slotBased, or disabled.

        .EXAMPLE
        Update-Cluster -ClusterName "cl02" -HaPolicy slotBased

        Configures the cluster "cl02". One host: HA enabled, admission control off. Two or more hosts: slot-style admission (one host failure).

        .EXAMPLE
        Update-Cluster -ClusterName "production-cluster" -HaPolicy reservationBased -HaClusterResourceFailoverPercent 50

        Applies reservation-based admission with 50% CPU and memory reserved for failover.

        .NOTES
        Prerequisites:
        - VMware PowerCLI must be installed and imported into the PowerShell session
        - Active connection to vCenter must be established (uses $Script:vCenterName global variable)
        - User account must have appropriate privileges to modify cluster configuration settings
        - Target cluster must already exist in the vCenter environment

        Behavior:
        - HA is enabled for all clusters; admission control disabled for single-host; multi-host behavior is driven by -HaPolicy

        Error Handling:
        - Comprehensive error handling for authorization, timeout, and general configuration failures
        - Throws exceptions on any critical configuration errors
        - Detailed error logging with specific error context for troubleshooting

        Performance:
        - Multi-host path: typically one Set-Cluster call plus zero or one ReconfigureComputeResource_Task
        - Single-host path only calls Set-Cluster; no DAS API reconfiguration

        Integration:
        - Integrates with VCF PowerShell Toolbox logging infrastructure for consistent audit trails
        - Uses global vCenter connection context for seamless integration with deployment workflows
        - Designed for use in automated deployment scenarios where reliable cluster configuration is critical
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [ValidateRange(0, 100)] [Int]$HaClusterResourceFailoverPercent = 0,
        [Parameter(Mandatory = $false)] [ValidateSet("disabled", "reservationBased", "slotBased")] [String]$HaPolicy = "reservationBased"
    )

    Write-LogMessage -Type DEBUG -Message "Entered Update-Cluster function..."

    $connectionTest = Test-VcenterConnection
    if (-not $connectionTest.IsConnected) {
        Write-LogMessage -Type ERROR -Message "Not connected to vCenter `"$Script:vCenterName`": $($connectionTest.ErrorMessage)"
        throw [VcfDeploymentException]::new("Not connected to vCenter `"$Script:vCenterName`": $($connectionTest.ErrorMessage)")
    }

    try {
        $cluster = Get-Cluster -Name $ClusterName -Server $Script:vCenterName -ErrorAction Stop
        if (-not $cluster) {
            Write-LogMessage -Type ERROR -Message "The cluster `"$ClusterName`" in vCenter `"$Script:vCenterName`" was not found."
            throw [VcfDeploymentException]::new("The cluster `"$ClusterName`" in vCenter `"$Script:vCenterName`" was not found.")
        } else {
            # VCF PowerCLI 9: Get-VMHost uses -Location for cluster (no -Cluster parameter). Suppress VMHost.DatastoreIdList deprecation when reading host count.
            $prevWarningPreference = $WarningPreference
            $WarningPreference = "SilentlyContinue"
            try {
            $hostCount = (Get-VMHost -Location $cluster -Server $Script:vCenterName -WarningAction SilentlyContinue -ErrorAction Stop).Count
            Write-LogMessage -Type DEBUG -Message "Update-Cluster: cluster `"$ClusterName`" has $hostCount host(s)."

            if ($hostCount -eq 1) {
                # Single-host cluster: enable HA with admission control disabled (no failover capacity). Supervisor requires HA enabled.
                $cluster | Set-Cluster -DrsEnabled:$true -HAEnabled:$true -HAAdmissionControlEnabled $false -DrsAutomationLevel FullyAutomated -Confirm:$false -Server $Script:vCenterName -ErrorAction Stop | Out-Null
                Write-LogMessage -Type INFO -Message "Cluster `"$ClusterName`" has one host; HA enabled (admission control disabled), DRS enabled."
            } else {
                switch ($HaPolicy) {
                    "slotBased" {
                        $haFailoverLevel = 1
                        $cluster | Set-Cluster -DrsEnabled:$true -HAEnabled:$true -DrsAutomationLevel FullyAutomated -HAAdmissionControlEnabled:$true -HAFailoverLevel $haFailoverLevel -Confirm:$false -Server $Script:vCenterName -ErrorAction Stop | Out-Null
                        $clusterView = Get-View $cluster.Id
                        $currentDas = $clusterView.ConfigurationEx.DasConfig
                        $currentVmMonitoring = if ($null -ne $currentDas.VmMonitoring) { $currentDas.VmMonitoring } else { $currentDas.VMMonitoring }
                        $needHostMonitoring = ($currentDas.HostMonitoring -ne "enabled")
                        $needVmMonitoring = ($currentVmMonitoring -ne "vmMonitoringOnly")
                        if ($needHostMonitoring -or $needVmMonitoring) {
                            $configSpecSb = New-Object VMware.Vim.ClusterConfigSpecEx
                            $configSpecSb.dasConfig = $clusterView.ConfigurationEx.DasConfig
                            $configSpecSb.dasConfig.HostMonitoring = "enabled"
                            $configSpecSb.dasConfig.VmMonitoring = "vmMonitoringOnly"
                            $clusterView.ReconfigureComputeResource_Task($configSpecSb, $true) | Out-Null
                        }
                        Write-LogMessage -Type DEBUG -Message "Cluster `"$ClusterName`" ($hostCount host(s)): HA admission control set to slot-based (host failures tolerated: $haFailoverLevel)."
                    }
                    "reservationBased" {
                        $cluster | Set-Cluster -DrsEnabled:$true -HAEnabled:$true -DrsAutomationLevel FullyAutomated -HAAdmissionControlEnabled:$false -Confirm:$false -Server $Script:vCenterName -ErrorAction Stop | Out-Null
                        $clusterView = Get-View $cluster.Id
                        if ($HaClusterResourceFailoverPercent -eq 0) {
                            $failoverResourcePercent = [int][Math]::Ceiling(100.0 / $hostCount)
                            if ($failoverResourcePercent -gt 100) {
                                $failoverResourcePercent = 100
                            }
                        } else {
                            $failoverResourcePercent = $HaClusterResourceFailoverPercent
                        }

                        $configSpec = New-Object VMware.Vim.ClusterConfigSpecEx
                        $configSpec.dasConfig = $clusterView.ConfigurationEx.DasConfig
                        $configSpec.dasConfig.HostMonitoring = "enabled"
                        $configSpec.dasConfig.VmMonitoring = "vmMonitoringOnly"
                        $configSpec.dasConfig.AdmissionControlEnabled = $true
                        $resourcePctPolicy = New-Object VMware.Vim.ClusterFailoverResourcesAdmissionControlPolicy
                        $resourcePctPolicy.CpuFailoverResourcesPercent = $failoverResourcePercent
                        $resourcePctPolicy.MemoryFailoverResourcesPercent = $failoverResourcePercent
                        $configSpec.dasConfig.AdmissionControlPolicy = $resourcePctPolicy
                        $clusterView.ReconfigureComputeResource_Task($configSpec, $true) | Out-Null
                        Write-LogMessage -Type DEBUG -Message "Cluster `"$ClusterName`" ($hostCount host(s)): HA admission control set to cluster resource percentage ($failoverResourcePercent% CPU and memory reserved for failover)."
                    }
                    "disabled" {
                        $cluster | Set-Cluster -DrsEnabled:$true -HAEnabled:$true -DrsAutomationLevel FullyAutomated -HAAdmissionControlEnabled:$false -Confirm:$false -Server $Script:vCenterName -ErrorAction Stop | Out-Null
                        $clusterView = Get-View $cluster.Id
                        $configSpecDis = New-Object VMware.Vim.ClusterConfigSpecEx
                        $configSpecDis.dasConfig = $clusterView.ConfigurationEx.DasConfig
                        $configSpecDis.dasConfig.HostMonitoring = "enabled"
                        $configSpecDis.dasConfig.VmMonitoring = "vmMonitoringOnly"
                        $configSpecDis.dasConfig.AdmissionControlEnabled = $false
                        $clusterView.ReconfigureComputeResource_Task($configSpecDis, $true) | Out-Null
                        Write-LogMessage -Type INFO -Message "Cluster `"$ClusterName`" ($hostCount host(s)): HA enabled with admission control disabled (VM restart only; no capacity reservation)."
                    }
                }
            }
            }
            finally {
                $WarningPreference = $prevWarningPreference
            }
        }
    } catch [System.UnauthorizedAccessException] {
        Write-LogMessage -Type ERROR -Message "Cannot update settings on cluster `"$ClusterName`" on `"$Script:vCenterName`" due to authorization issues: $($_.Exception.Message)"
        throw [VcfDeploymentException]::new("Cannot update settings on cluster `"$ClusterName`" on `"$Script:vCenterName`" due to authorization issues: $($_.Exception.Message)")
    }
    catch [System.TimeoutException] {
        Write-LogMessage -Type ERROR -Message "Cannot update settings on cluster `"$ClusterName`" on `"$Script:vCenterName`" due to network/timeout issues: $($_.Exception.Message)"
        throw [VcfDeploymentException]::new("Cannot update settings on cluster `"$ClusterName`" on `"$Script:vCenterName`" due to network/timeout issues: $($_.Exception.Message)")
    } catch [VcfDeploymentException] {
        throw  # already logged and typed — propagate without re-wrapping
    } catch {
        Write-LogMessage -Type ERROR -AppendNewLine -Message "Failed to update settings on cluster `"$ClusterName`" on `"$Script:vCenterName`" : $($_.Exception.Message)"
        throw [VcfDeploymentException]::new("Failed to update settings on cluster `"$ClusterName`" on `"$Script:vCenterName`" : $($_.Exception.Message)")
    }
}
Function Invoke-ReconfigureClusterHA {

    <#
        .SYNOPSIS
        Re-applies vSphere HA and DRS configuration on a cluster so that HA uses the current management network (e.g. after moving management to the vDS).

        .DESCRIPTION
        After reconfiguring hosts so that the management interface (vmk0) is on the vSphere Distributed Switch (vDS), vCenter may need to re-evaluate which port groups are used for HA heartbeats. This function waits an optional delay (allowing vCenter to see the management network on all hosts), then calls Update-Cluster to re-apply HA and DRS settings. Use this after you have completed moving management to the vDS so that HA picks up the new network.

        .PARAMETER ClusterName
        Name of the vSphere cluster to reconfigure. The cluster must exist and be accessible via the current vCenter connection ($Script:vCenterName).

        .PARAMETER DelaySeconds
        Seconds to wait before applying HA settings. Use when vCenter needs time to see the management network on all hosts (avoids "no port groups enabled for vSphere HA communication"). Default is 10; the module also uses $Script:HaNetworkStabilizationDelaySeconds during deployment.

        .PARAMETER HaPolicy
        Multi-host clusters only (ignored for single-host): reservationBased, slotBased, or disabled. Passed through to Update-Cluster. Deployment sets this from common/clusters haPolicy for vSAN-OSA and vSAN-ESA, and reservationBased for VMFS.

        .EXAMPLE
        Invoke-ReconfigureClusterHA -ClusterName "production-cluster"

        Waits 10 seconds then re-applies HA/DRS on "production-cluster" (default reservationBased for Update-Cluster when invoked alone).

        .EXAMPLE
        Invoke-ReconfigureClusterHA -ClusterName "production-cluster" -DelaySeconds 15 -HaPolicy reservationBased

        Waits 15 seconds then re-applies HA/DRS with percentage-based admission control.

        .NOTES
        Requires an active vCenter connection. Uses Test-VcenterConnection and Update-Cluster.
        If "vSphere HA host status" (red) or "Unable to apply DRS resource settings on host" alarms appear after deployment, run this function again with a longer delay (e.g. -DelaySeconds 30) so vCenter can re-evaluate the management network for HA heartbeats and DRS.
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [ValidateRange(0, 300)] [Int]$DelaySeconds = 10,
        [Parameter(Mandatory = $false)] [ValidateSet("disabled", "reservationBased", "slotBased")] [String]$HaPolicy = "reservationBased"
    )

    $connectionTest = Test-VcenterConnection
    if (-not $connectionTest.IsConnected) {
        Write-LogMessage -Type ERROR -Message "Not connected to vCenter `"$Script:vCenterName`": $($connectionTest.ErrorMessage)"
        throw [VcfDeploymentException]::new("Reconfigure HA failed. Connect to vCenter first.")
    }
    if ($DelaySeconds -gt 0) {
        Write-LogMessage -Type DEBUG -Message "Waiting $DelaySeconds seconds for vCenter to see management network on all hosts before applying HA settings."
        Start-Sleep -Seconds $DelaySeconds
    }
    Update-Cluster -ClusterName $ClusterName -HaPolicy $HaPolicy
}
Function Test-VmkernelVsanAndWitnessTraffic {

    <#
        .SYNOPSIS
        Checks whether at least one VMkernel interface on the host has vSAN and vSAN witness traffic enabled.

        .DESCRIPTION
        Returns a result object indicating if the host has a compliant VMkernel interface (both vSAN and
        vSAN witness traffic enabled, or only vSAN when RequireWitnessTraffic is $false) and the vmk0 adapter for optional remediation. Used before adding
        a host to a vSAN cluster to ensure networking is ready.

        .PARAMETER RequireWitnessTraffic
        When $true (default), at least one VMkernel must have both vSAN and vSAN witness traffic (for data hosts). When $false, only vSAN traffic is required (for the witness host; per Broadcom do not configure witness traffic type on the witness host).

        .PARAMETER VMHost
        The VMHost object to check (from Get-VMHost).

        .OUTPUTS
        PSCustomObject with HasCompliantInterface (bool), Vmk0Adapter (VMHostVirtualNic or null),
        PropertiesMissingOnAdapters (bool), and optionally MissingVsan (bool), MissingWitness (bool) for diagnostics.

        .NOTES
        - VsanWitnessTrafficEnabled may not be exposed in all PowerCLI versions; when absent, only VsanTrafficEnabled is checked.
        - When VsanTrafficEnabled or VsanWitnessTrafficEnabled are not present on VMkernel adapters, PropertiesMissingOnAdapters is true and callers should automatically enable them on vmk0 and inform the user.
    #>

    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $false)] [bool]$RequireWitnessTraffic = $true,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [VMware.VimAutomation.ViCore.Types.V1.Inventory.VMHost]$VMHost
    )

    $hostName = $VMHost.Name
    $trafficDesc = if ($RequireWitnessTraffic) { "vSAN and vSAN witness traffic" } else { "vSAN traffic only (witness host)" }
    Write-LogMessage -Type DEBUG -Message "Test-VmkernelVsanAndWitnessTraffic: Checking VMkernel interfaces on host `"$hostName`" for $trafficDesc."

    $vmkernelAdapters = Get-VMHostNetworkAdapter -VMHost $VMHost -VMKernel -ErrorAction SilentlyContinue
    $adapterCount = if ($vmkernelAdapters) { @($vmkernelAdapters).Count } else { 0 }
    Write-LogMessage -Type DEBUG -Message "Test-VmkernelVsanAndWitnessTraffic: Host `"$hostName`" has $adapterCount VMkernel adapter(s)."

    $hasVsanProperty = $false
    $hasWitnessProperty = $false
    $vmk0Adapter = $null
    $hasCompliantInterface = $false

    if ($vmkernelAdapters -and $vmkernelAdapters.Count -gt 0) {
        $firstAdapter = $vmkernelAdapters | Select-Object -First 1
        $hasVsanProperty = $null -ne (Get-Member -InputObject $firstAdapter -Name "VsanTrafficEnabled" -MemberType Property -ErrorAction SilentlyContinue)
        $hasWitnessProperty = $null -ne (Get-Member -InputObject $firstAdapter -Name "VsanWitnessTrafficEnabled" -MemberType Property -ErrorAction SilentlyContinue)
        Write-LogMessage -Type DEBUG -Message "Test-VmkernelVsanAndWitnessTraffic: VsanTrafficEnabled property available on API: $hasVsanProperty; VsanWitnessTrafficEnabled: $hasWitnessProperty."
    }

    $propertiesMissingOnAdapters = (-not $hasVsanProperty) -or (-not $hasWitnessProperty)

    foreach ($adapter in $vmkernelAdapters) {
        if ($adapter.Name -eq "vmk0") {
            $vmk0Adapter = $adapter
            Write-LogMessage -Type DEBUG -Message "Test-VmkernelVsanAndWitnessTraffic: Found management interface vmk0 on host `"$hostName`"."
        }
        $vsanEnabled = if ($hasVsanProperty) { $adapter.VsanTrafficEnabled -eq $true } else { $false }
        $witnessEnabled = if ($hasWitnessProperty) { $adapter.VsanWitnessTrafficEnabled -eq $true } else { -not $RequireWitnessTraffic }
        $witnessValue = if ($hasWitnessProperty) { $adapter.VsanWitnessTrafficEnabled } else { "N/A (property not returned for this adapter)" }
        Write-LogMessage -Type DEBUG -Message "Test-VmkernelVsanAndWitnessTraffic: Host `"$hostName`" adapter `"$($adapter.Name)`": VsanTrafficEnabled=$vsanEnabled, VsanWitnessTrafficEnabled=$witnessValue."
        if ($vsanEnabled -and ($witnessEnabled -or -not $RequireWitnessTraffic)) {
            $hasCompliantInterface = $true
            $compliantMsg = if ($RequireWitnessTraffic) { "both vSAN and vSAN witness traffic enabled" } else { "vSAN traffic enabled (witness host)" }
            Write-LogMessage -Type DEBUG -Message "Test-VmkernelVsanAndWitnessTraffic: Host `"$hostName`" has compliant interface: `"$($adapter.Name)`" has $compliantMsg."
            break
        }
    }

    $missingVsan = $false
    if ($hasVsanProperty) {
        $missingVsan = -not ($vmkernelAdapters | Where-Object { $_.VsanTrafficEnabled -eq $true })
    }
    $missingWitness = $false
    if ($hasWitnessProperty) {
        $missingWitness = -not ($vmkernelAdapters | Where-Object { $_.VsanWitnessTrafficEnabled -eq $true })
    }

    if (-not $hasCompliantInterface -and $RequireWitnessTraffic -and $hasVsanProperty -and $hasWitnessProperty -and -not $missingVsan -and -not $missingWitness) {
        $hasCompliantInterface = $true
        Write-LogMessage -Type DEBUG -Message "Test-VmkernelVsanAndWitnessTraffic: Host `"$hostName`" has at least one VMkernel with vSAN and at least one with vSAN witness (same or different); treating as compliant."
    }

    if ($hasCompliantInterface) {
        Write-LogMessage -Type DEBUG -Message "Test-VmkernelVsanAndWitnessTraffic: Host `"$hostName`" result: HasCompliantInterface=true; at least one VMkernel has both vSAN and vSAN witness traffic (or vSAN and witness on separate adapters)."
    }
    else {
        Write-LogMessage -Type DEBUG -Message "Test-VmkernelVsanAndWitnessTraffic: Host `"$hostName`" result: HasCompliantInterface=false; PropertiesMissingOnAdapters=$propertiesMissingOnAdapters, MissingVsan=$missingVsan, MissingWitness=$missingWitness. Vmk0Adapter present: $($null -ne $vmk0Adapter)."
    }

    # When PowerCLI does not report VsanTrafficEnabled/VsanWitnessTrafficEnabled (e.g. when configured via esxcli), fall back to esxcli vsan network list to detect traffic types.
    if (-not $hasCompliantInterface) {
        $esxcliCompliant = Test-VmkernelVsanTrafficViaEsxcli -VMHost $VMHost -RequireWitnessTraffic $RequireWitnessTraffic
        if ($esxcliCompliant) {
            $hasCompliantInterface = $true
            Write-LogMessage -Type DEBUG -Message "Test-VmkernelVsanAndWitnessTraffic: Host `"$hostName`" has vSAN and witness traffic per esxcli vsan network list (PowerCLI did not report it)."
        }
    }

    return [PSCustomObject]@{
        HasCompliantInterface       = $hasCompliantInterface
        Vmk0Adapter                 = $vmk0Adapter
        PropertiesMissingOnAdapters = $propertiesMissingOnAdapters
        MissingVsan                 = $missingVsan
        MissingWitness              = $missingWitness
    }
}
Function Test-VmkernelVsanTrafficViaEsxcli {

    <#
        .SYNOPSIS
        Returns whether the host has at least one VMkernel with required vSAN traffic types per esxcli vsan network list.

        .DESCRIPTION
        Runs esxcli vsan network list on the host and parses the output for Traffic Type (vsan, witness).
        Used as a fallback when Get-VMHostNetworkAdapter does not report VsanTrafficEnabled/VsanWitnessTrafficEnabled
        (e.g. when traffic was configured via esxcli or a different API path). Returns $true if at least one
        interface has vsan traffic and (when RequireWitnessTraffic) witness traffic.

        .PARAMETER VMHost
        The VMHost object (from Get-VMHost).

        .PARAMETER RequireWitnessTraffic
        When $true, the interface must have both vsan and witness traffic. When $false, only vsan is required (e.g. for witness host that only needs vsan on vmk0).

        .OUTPUTS
        Boolean. $true if esxcli shows the required traffic type(s) on at least one interface; $false otherwise or on error.

        .NOTES
        Best-effort; returns $false and logs at DEBUG if esxcli is unavailable or output cannot be parsed.
    #>

    [CmdletBinding()]
    [OutputType([System.Boolean])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [VMware.VimAutomation.ViCore.Types.V1.Inventory.VMHost]$VMHost,
        [Parameter(Mandatory = $false)] [bool]$RequireWitnessTraffic = $true
    )

    $hostName = $VMHost.Name
    try {
        $esxcli = Get-EsxCli -VMHost $VMHost -V2 -Server $Script:vCenterName -ErrorAction Stop
        $listCmd = $esxcli.vsan.network.list
        if (-not $listCmd) {
            Write-LogMessage -Type DEBUG -Message "Test-VmkernelVsanTrafficViaEsxcli: esxcli vsan network list not available on host `"$hostName`"."
            return $false
        }
        $result = $listCmd.Invoke()
        if (-not $result) {
            Write-LogMessage -Type DEBUG -Message "Test-VmkernelVsanTrafficViaEsxcli: vsan network list returned nothing on host `"$hostName`"."
            return $false
        }
        # Flatten: some hosts return a single wrapper object with a list property (e.g. a table/list inside).
        $items = @()
        if ($result -is [Array] -or ($result -is [System.Collections.IEnumerable] -and $result -isnot [string])) {
            $items = @($result)
        } else {
            $single = $result
            $listProp = $single.PSObject.Properties | Where-Object { $_.Value -is [Array] -or $_.Value -is [System.Collections.IEnumerable] } | Select-Object -First 1
            if ($listProp) {
                $items = @($listProp.Value)
            } else {
                $items = @($single)
            }
        }
        Write-LogMessage -Type DEBUG -Message "Test-VmkernelVsanTrafficViaEsxcli: Host `"$hostName`" vsan network list item count: $($items.Count)."
        # Aggregate traffic types per interface when possible (some hosts return one row per traffic type for the same interface).
        $trafficByInterface = @{}
        $itemIndex = 0
        foreach ($item in $items) {
            $trafficType = $null
            if ($item.PSObject.Properties['TrafficType']) {
                $trafficType = $item.TrafficType
            } elseif ($item.PSObject.Properties['traffictype']) {
                $trafficType = $item.traffictype
            } elseif ($item.PSObject.Properties['Traffic type']) {
                $trafficType = $item.'Traffic type'
            } else {
                $trafficType = $item.ToString()
            }
            # Normalize: API may return [string[]] for multiple traffic types on one interface.
            $trafficStr = if ($null -eq $trafficType) { "" } elseif ($trafficType -is [Array] -or $trafficType -is [System.Collections.IEnumerable]) {
                ($trafficType | ForEach-Object { [string]$_ }) -join ","
            } else {
                [string]$trafficType
            }
            if ([String]::IsNullOrWhiteSpace($trafficStr)) { $itemIndex++; continue }
            $ifaceKey = $null
            if ($item.PSObject.Properties['Interface']) { $ifaceKey = $item.Interface }
            elseif ($item.PSObject.Properties['interface']) { $ifaceKey = $item.interface }
            elseif ($item.PSObject.Properties['InterfaceName']) { $ifaceKey = $item.InterfaceName }
            elseif ($item.PSObject.Properties['interfacename']) { $ifaceKey = $item.interfacename }
            elseif ($item.PSObject.Properties['VmkNicName']) { $ifaceKey = $item.VmkNicName }
            elseif ($item.PSObject.Properties['vmknicname']) { $ifaceKey = $item.vmknicname }
            elseif ($item.PSObject.Properties['Name']) { $ifaceKey = $item.Name }
            if (-not $ifaceKey) { $ifaceKey = "item_$itemIndex" }
            $ifaceKey = [string]$ifaceKey
            if (-not $trafficByInterface[$ifaceKey]) { $trafficByInterface[$ifaceKey] = @() }
            $trafficByInterface[$ifaceKey] += $trafficStr
            $itemIndex++
        }
        $anyVsan = $false
        $anyWitness = $false
        foreach ($iface in $trafficByInterface.Keys) {
            $combined = ($trafficByInterface[$iface] | ForEach-Object { $_.Trim() }) -join ","
            if ([String]::IsNullOrWhiteSpace($combined)) { continue }
            $hasVsan = $combined -match 'vsan'
            $hasWitness = $combined -match 'witness'
            if ($hasVsan) { $anyVsan = $true }
            if ($hasWitness) { $anyWitness = $true }
            if ($hasVsan -and (-not $RequireWitnessTraffic -or $hasWitness)) {
                Write-LogMessage -Type DEBUG -Message "Test-VmkernelVsanTrafficViaEsxcli: Host `"$hostName`" has required vSAN traffic per esxcli (interface $iface): `"$combined`"."
                return $true
            }
        }
        if ($RequireWitnessTraffic -and $anyVsan -and $anyWitness) {
            Write-LogMessage -Type DEBUG -Message "Test-VmkernelVsanTrafficViaEsxcli: Host `"$hostName`" has vSAN on one interface and witness on another per esxcli; treating as compliant."
            return $true
        }
        # Fallback: parse result as text (e.g. when Invoke returns a single object or array that stringifies to CLI-style output with one or more "Traffic Type:" lines).
        $resultStr = $result | Out-String
        $trafficTypeMatches = [regex]::Matches($resultStr, 'Traffic Type:\s*([^\r\n]+)')
        foreach ($match in $trafficTypeMatches) {
            $trafficStr = $match.Groups[1].Value.Trim()
            if ([String]::IsNullOrWhiteSpace($trafficStr)) { continue }
            $hasVsan = $trafficStr -match 'vsan'
            $hasWitness = $trafficStr -match 'witness'
            if ($hasVsan) { $anyVsan = $true }
            if ($hasWitness) { $anyWitness = $true }
            if ($hasVsan -and (-not $RequireWitnessTraffic -or $hasWitness)) {
                Write-LogMessage -Type DEBUG -Message "Test-VmkernelVsanTrafficViaEsxcli: Host `"$hostName`" has required vSAN traffic per esxcli (parsed from text): `"$trafficStr`"."
                return $true
            }
        }
        if ($RequireWitnessTraffic -and $anyVsan -and $anyWitness) {
            Write-LogMessage -Type DEBUG -Message "Test-VmkernelVsanTrafficViaEsxcli: Host `"$hostName`" has vSAN and witness (text parse); treating as compliant."
            return $true
        }
        # Log a short sample of what we saw for troubleshooting (avoid logging full object).
        $sampleLog = "none"
        if ($items.Count -gt 0) {
            $first = $items[0]
            $keys = @($first.PSObject.Properties.Name)
            $firstCombined = ($trafficByInterface.Values | Select-Object -First 1) -join ","
            $sampleLog = "first item keys: $($keys -join ', '); combined traffic sample: $firstCombined"
        }
        Write-LogMessage -Type DEBUG -Message "Test-VmkernelVsanTrafficViaEsxcli: Host `"$hostName`" esxcli vsan network list did not show required traffic (RequireWitnessTraffic=$RequireWitnessTraffic). $sampleLog"
        return $false
    } catch {
        Write-LogMessage -Type DEBUG -Message "Test-VmkernelVsanTrafficViaEsxcli: Failed on host `"$hostName`": $($_.Exception.Message)."
        return $false
    }
}
Function Test-VsanTrafficVmkernelHasValidIp {
    <#
        .SYNOPSIS
        Returns whether the given host has at least one VMkernel with vSAN traffic enabled and a valid IPv4 or IPv6 address.

        .DESCRIPTION
        vCenter/vSAN requires that every host in a vSAN cluster has a VMkernel used for vSAN traffic with proper IP configuration.
        This function checks VMkernel adapters that have VsanTrafficEnabled and returns $true if any of them has a non-empty
        IP address (IPv4 or IPv6). Used before Set-VsanClusterConfiguration to avoid "Neither IPv4 nor IPv6 is properly
        configured for vSAN traffic on all hosts" errors.

        .PARAMETER VMHost
        The VMHost object to check (from Get-VMHost).

        .OUTPUTS
        Boolean. $true if at least one VMkernel with vSAN traffic has a valid IP; $false otherwise.

        .NOTES
        Reads VMkernel adapter .IP or .Address property when present. If no VMkernel has vSAN traffic enabled, returns $false.
    #>
    [OutputType([System.Boolean])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [VMware.VimAutomation.ViCore.Types.V1.Inventory.VMHost]$VMHost
    )
    $vmkernelAdapters = Get-VMHostNetworkAdapter -VMHost $VMHost -VMKernel -ErrorAction SilentlyContinue
    if (-not $vmkernelAdapters) { return $false }
    $hasVsanProperty = $null -ne (Get-Member -InputObject ($vmkernelAdapters | Select-Object -First 1) -Name "VsanTrafficEnabled" -MemberType Property -ErrorAction SilentlyContinue)
    if (-not $hasVsanProperty) { return $false }
    foreach ($adapter in $vmkernelAdapters) {
        if ($adapter.VsanTrafficEnabled -ne $true) { continue }
        $ip = $null
        if ($adapter.PSObject.Properties['IP']) { $ip = $adapter.IP }
        if ([string]::IsNullOrWhiteSpace($ip) -and $adapter.PSObject.Properties['Address']) { $ip = $adapter.Address }
        if (-not [string]::IsNullOrWhiteSpace($ip)) { return $true }
    }
    return $false
}
Function Add-VsanWitnessTrafficToVmkViaEsxcli {

    <#
        .SYNOPSIS
        Adds vSAN witness traffic type to a VMkernel adapter on a host via esxcli (when Set-VMHostNetworkAdapter does not support -VsanWitnessEnabled).

        .DESCRIPTION
        Configures a VMkernel to carry vSAN witness traffic via esxcli vsan network ip add -i <VmkernelName> -T witness.
        Use on each data host in the cluster to add witness traffic to the management (or dedicated) VMkernel. Do not
        run this on the witness host (per Broadcom: do not configure the witness traffic type on the witness host).

        .PARAMETER VMHost
        The VMHost object (from Get-VMHost).

        .PARAMETER PostSuccessDelaySeconds
        Seconds to wait after successfully adding witness traffic (add or set) so the host can update vSAN network configuration before the caller re-checks. Default is 5.

        .PARAMETER VmkernelName
        The VMkernel adapter name (e.g. vmk0). Default is vmk0. Use the management VMkernel or the one you want to carry witness traffic.

        .PARAMETER WitnessOnly
        When set, only vSAN witness traffic is configured on the VMkernel (e.g. vmk0 for mgmt + witness only, or dedicated vmk3). When not set, both vsan and witness traffic are configured (e.g. shared vSAN VMkernel for compliance).

        .OUTPUTS
        $true if witness traffic was added (or already present). Throws if esxcli is unavailable or all parameter variants fail; callers must treat as deployment failure and run rollback.

        .NOTES
        Requires Get-EsxCli. vSAN witness traffic is required for stretched clusters; on failure the function throws so the script fails and rollback runs.
        Configuration follows: https://techdocs.broadcom.com/us/en/vmware-cis/vsan/vsan/7-0/vsan-planning-and-deployment/working-with-virtual-san-stretched-cluster/configure-network-interface-for-witness-traffic.html
        (esxcli vsan network ip add -i vmkx -T witness on data hosts only; verify with esxcli vsan network list).
        CreateArgs() may return a Hashtable (keys = parameter names e.g. interfacename, traffictype); we use .Keys to get names and build a hashtable for Invoke(). Use -WitnessOnly for vmk0 (mgmt + witness only) or dedicated vmk3 so only witness traffic is set; by default we pass @("vsan", "witness") for a shared vSAN VMkernel that carries both.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(0, 300)] [Int]$PostSuccessDelaySeconds = 5,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [VMware.VimAutomation.ViCore.Types.V1.Inventory.VMHost]$VMHost,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$VmkernelName = "vmk0",
        [Parameter(Mandatory = $false)] [Switch]$WitnessOnly
    )

    $hostName = $VMHost.Name
    # vmk0 (mgmt + witness only) and dedicated vmk3 get only witness; shared vSAN VMkernel gets both vsan and witness for compliance.
    $trafficTypesVsanAndWitness = if ($WitnessOnly.IsPresent) { @("witness") } else { @("vsan", "witness") }
    try {
        $esxcli = Get-EsxCli -VMHost $VMHost -V2 -Server $Script:vCenterName -ErrorAction Stop
        # Idempotent: if this VMkernel already has witness traffic (per esxcli vsan network list), skip.
        $listCmd = $esxcli.vsan.network.list
        if ($listCmd) {
            try {
                $listResult = $listCmd.Invoke()
                $items = @()
                if ($listResult -is [Array] -or ($listResult -is [System.Collections.IEnumerable] -and $listResult -isnot [string])) { $items = @($listResult) }
                else {
                    $listProp = $listResult.PSObject.Properties | Where-Object { $_.Value -is [Array] -or $_.Value -is [System.Collections.IEnumerable] } | Select-Object -First 1
                    if ($listProp) { $items = @($listProp.Value) } else { $items = @($listResult) }
                }
                $trafficByInterface = @{}
                foreach ($item in $items) {
                    $trafficStr = if ($item.PSObject.Properties['TrafficType']) { $item.TrafficType } elseif ($item.PSObject.Properties['traffictype']) { $item.traffictype } else { $null }
                    $trafficStr = if ($null -eq $trafficStr) { "" } elseif ($trafficStr -is [Array]) { ($trafficStr | ForEach-Object { [string]$_ }) -join "," } else { [string]$trafficStr }
                    $ifaceKey = $null
                    if ($item.PSObject.Properties['Interface']) { $ifaceKey = $item.Interface }
                    elseif ($item.PSObject.Properties['interface']) { $ifaceKey = $item.interface }
                    elseif ($item.PSObject.Properties['InterfaceName']) { $ifaceKey = $item.InterfaceName }
                    elseif ($item.PSObject.Properties['interfacename']) { $ifaceKey = $item.interfacename }
                    elseif ($item.PSObject.Properties['VmkNicName']) { $ifaceKey = $item.VmkNicName }
                    elseif ($item.PSObject.Properties['vmknicname']) { $ifaceKey = $item.vmknicname }
                    if (-not $ifaceKey) { continue }
                    $ifaceKey = [string]$ifaceKey
                    if (-not $trafficByInterface[$ifaceKey]) { $trafficByInterface[$ifaceKey] = @() }
                    $trafficByInterface[$ifaceKey] += $trafficStr
                }
                $existing = if ($trafficByInterface[$VmkernelName]) { ($trafficByInterface[$VmkernelName] | ForEach-Object { $_ }) -join "," } else { "" }
                if ($existing -match 'witness') {
                    Write-LogMessage -Type DEBUG -Message "vSAN witness traffic already configured on $VmkernelName on host `"$hostName`". Skipping witness traffic add."
                    return $true
                }
            } catch {
                Write-LogMessage -Type DEBUG -Message "Add-VsanWitnessTrafficToVmkViaEsxcli: Could not check vsan network list for idempotency on `"$hostName`": $($_.Exception.Message). Proceeding to add."
            }
        }
        $addCmd = $esxcli.vsan.network.ip.add
        if (-not $addCmd) {
            Write-LogMessage -Type ERROR -Message "esxcli vsan network ip add not available on host `"$hostName`". vSAN witness traffic is required; deployment will roll back."
            throw [VcfDeploymentException]::new("vSAN witness traffic is required. esxcli vsan network ip add is not available on host `"$hostName`". Enable witness traffic on a VMkernel (e.g. in vCenter UI) or ensure the host supports the command. Deployment will roll back.")
        }

        # Prefer CreateArgs() so we use the host's exact parameter names (e.g. interfacename). Try setting properties on the args object and Invoke; if CreateArgs returns a collection, build a hashtable with those names.
        $invoked = $false
        $usedSetPath = $false
        $lastError = $null
        $addFailedWithAlreadyInUse = $false
        $createArgsArgNamesLog = $null
        try {
            $argsObj = $addCmd.CreateArgs()
            if ($null -eq $argsObj) {
                Write-LogMessage -Type DEBUG -Message "Add-VsanWitnessTrafficToVmkViaEsxcli: CreateArgs() returned null; trying fallback parameter sets."
            } else {
                $argNames = @()
                $isHashtable = $argsObj -is [System.Collections.Hashtable] -or $argsObj -is [System.Collections.IDictionary]
                $isCollection = -not $isHashtable -and $argsObj -is [System.Collections.IEnumerable] -and $argsObj -isnot [string]
                if ($isHashtable) {
                    $argNames = @($argsObj.Keys | ForEach-Object { $_ })
                } elseif ($isCollection) {
                    $argNames = @($argsObj | ForEach-Object { if ($_.PSObject.Properties['Name']) { $_.Name } elseif ($_.Key) { $_.Key } else { $_ } })
                } else {
                    $argNames = @($argsObj.PSObject.Properties | ForEach-Object { $_.Name })
                }
                $createArgsArgNamesLog = "CreateArgs parameter names: ($($argNames -join ', '))."
                $interfaceParam = $argNames | Where-Object { $_ -and $_ -match "interface|^i$" } | Select-Object -First 1
                $trafficParam = $argNames | Where-Object { $_ -and $_ -match "traffic|^T$" } | Select-Object -First 1
                if ($interfaceParam -and $trafficParam) {
                    if ($isHashtable -or $isCollection) {
                        $paramsFromCreateArgs = @{ $interfaceParam = $VmkernelName; $trafficParam = $trafficTypesVsanAndWitness }
                        $addCmd.Invoke($paramsFromCreateArgs) | Out-Null
                    } else {
                        $argsObj.$interfaceParam = $VmkernelName
                        $argsObj.$trafficParam = $trafficTypesVsanAndWitness
                        $addCmd.Invoke($argsObj) | Out-Null
                    }
                    $invoked = $true
                }
            }
        } catch {
            $lastError = $_.Exception.Message
            Write-LogMessage -Type DEBUG -Message "Add-VsanWitnessTrafficToVmkViaEsxcli: CreateArgs/Invoke path failed: $lastError"
            if ($lastError -match "already in use|Can't add again|use 'set' command") {
                $addFailedWithAlreadyInUse = $true
            }
        }

        if (-not $invoked) {
            # Fallback: try hash tables with known parameter name variants. Pass both vsan and witness so we do not replace vsan.
            $paramSets = @(
                @{ interfacename = $VmkernelName; traffictype = $trafficTypesVsanAndWitness },
                @{ "interface-name" = $VmkernelName; "traffic-type" = $trafficTypesVsanAndWitness },
                @{ interface_name = $VmkernelName; traffic_type = $trafficTypesVsanAndWitness },
                @{ i = $VmkernelName; T = $trafficTypesVsanAndWitness },
                @{ InterfaceName = $VmkernelName; TrafficType = $trafficTypesVsanAndWitness }
            )
            foreach ($params in $paramSets) {
                try {
                    $addCmd.Invoke($params) | Out-Null
                    $invoked = $true
                    break
                } catch {
                    $lastError = $_.Exception.Message
                    if ($lastError -match "already in use|Can't add again|use 'set' command") {
                        $addFailedWithAlreadyInUse = $true
                        Write-LogMessage -Type DEBUG -Message "Add-VsanWitnessTrafficToVmkViaEsxcli: Add reported interface already in use; trying vsan network ip set."
                    }
                    continue
                }
            }

            # If add failed because the interface is already in the vSAN network config, use "set" to add witness while keeping vsan (pass both traffic types).
            if (-not $invoked -and $addFailedWithAlreadyInUse) {
                $setCmd = $esxcli.vsan.network.ip.set
                if ($setCmd) {
                    $setParamSets = @(
                        @{ interfacename = $VmkernelName; traffictype = $trafficTypesVsanAndWitness },
                        @{ "interface-name" = $VmkernelName; "traffic-type" = $trafficTypesVsanAndWitness },
                        @{ interface_name = $VmkernelName; traffic_type = $trafficTypesVsanAndWitness },
                        @{ i = $VmkernelName; T = $trafficTypesVsanAndWitness },
                        @{ InterfaceName = $VmkernelName; TrafficType = $trafficTypesVsanAndWitness }
                    )
                    foreach ($setParams in $setParamSets) {
                        try {
                            $setCmd.Invoke($setParams) | Out-Null
                            $invoked = $true
                            $usedSetPath = $true
                            break
                        } catch {
                            $lastError = $_.Exception.Message
                            continue
                        }
                    }
                } else {
                    Write-LogMessage -Type DEBUG -Message "Add-VsanWitnessTrafficToVmkViaEsxcli: vsan network ip set command not available on host."
                }
            }
        }
        if (-not $invoked) {
            if ($lastError -match "already in use|Can't add again") {
                Write-LogMessage -Type DEBUG -Message "vSAN witness traffic already configured on $VmkernelName on host `"$hostName`" (esxcli reported already in use). Skipping witness traffic add."
                return $true
            }
            $summary = if ($createArgsArgNamesLog) { " $createArgsArgNamesLog" } else { " CreateArgs returned null or no usable params." }
            Write-LogMessage -Type ERROR -Message "Add-VsanWitnessTrafficToVmkViaEsxcli: All attempts failed.$summary Last error: $lastError"
            $detail = if ($lastError) { " Last error: $lastError" } else { "" }
            throw "Invoke failed with all parameter name variants.$detail"
        }
        Write-LogMessage -Type INFO -Message "Added vSAN witness traffic to $VmkernelName on host `"$hostName`"."
        if ($PostSuccessDelaySeconds -gt 0) {
            Start-Sleep -Seconds $PostSuccessDelaySeconds
        }
        if ($usedSetPath) {
            $listCmd = $esxcli.vsan.network.list
            if ($listCmd) {
                try {
                    $listResult = $listCmd.Invoke()
                    $listStr = if ($listResult) { ($listResult | Out-String).Trim() } else { "null" }
                    Write-LogMessage -Type DEBUG -Message "Add-VsanWitnessTrafficToVmkViaEsxcli: After set, vsan network list on `"$hostName`": $listStr"
                    # On some hosts set does not persist witness; list may show one row per traffic type (aggregated by VmkNicName in Test-VmkernelVsanTrafficViaEsxcli) or a single row. If list shows only vsan, try add with witness only to add the second traffic type to the existing interface.
                    $itemsAfterSet = @()
                    if ($listResult -is [Array] -or ($listResult -is [System.Collections.IEnumerable] -and $listResult -isnot [string])) {
                        $itemsAfterSet = @($listResult)
                    } else {
                        $single = $listResult
                        $listProp = $single.PSObject.Properties | Where-Object { $_.Value -is [Array] -or $_.Value -is [System.Collections.IEnumerable] } | Select-Object -First 1
                        if ($listProp) { $itemsAfterSet = @($listProp.Value) } else { $itemsAfterSet = @($single) }
                    }
                    $combinedTraffic = ""
                    foreach ($item in $itemsAfterSet) {
                        $trafficType = if ($item.PSObject.Properties['TrafficType']) { $item.TrafficType } elseif ($item.PSObject.Properties['traffictype']) { $item.traffictype } else { $null }
                        $trafficString = if ($null -eq $trafficType) { "" } elseif ($trafficType -is [Array]) { ($trafficType | ForEach-Object { [string]$_ }) -join "," } else { [string]$trafficType }
                        if (-not [String]::IsNullOrWhiteSpace($trafficString)) { $combinedTraffic += "," + $trafficString }
                    }
                    $combinedTraffic = $combinedTraffic.TrimStart(',')
                    if ($combinedTraffic -match 'vsan' -and $combinedTraffic -notmatch 'witness') {
                        Write-LogMessage -Type DEBUG -Message "Add-VsanWitnessTrafficToVmkViaEsxcli: List after set shows vsan but not witness; trying add with witness only."
                        $witnessOnly = @("witness")
                        $addWitnessParamSets = @(
                            @{ interfacename = $VmkernelName; traffictype = $witnessOnly },
                            @{ "interface-name" = $VmkernelName; "traffic-type" = $witnessOnly },
                            @{ InterfaceName = $VmkernelName; TrafficType = $witnessOnly }
                        )
                        foreach ($addParams in $addWitnessParamSets) {
                            try {
                                $addCmd.Invoke($addParams) | Out-Null
                                Write-LogMessage -Type INFO -Message "Added vSAN witness traffic to $VmkernelName on host `"$hostName`" via add (witness only) after set."
                                if ($PostSuccessDelaySeconds -gt 0) { Start-Sleep -Seconds $PostSuccessDelaySeconds }
                                break
                            } catch {
                                Write-LogMessage -Type DEBUG -Message "Add-VsanWitnessTrafficToVmkViaEsxcli: Add witness only failed: $($_.Exception.Message)"
                            }
                        }
                    }
                } catch {
                    Write-LogMessage -Type DEBUG -Message "Add-VsanWitnessTrafficToVmkViaEsxcli: Could not run vsan network list after set on `"$hostName`": $($_.Exception.Message)"
                }
            }
        }
        return $true
    } catch [VcfDeploymentException] {
        throw  # already logged and typed — propagate without re-wrapping
    } catch {
        Write-LogMessage -Type ERROR -Message "Could not add vSAN witness traffic to $VmkernelName on host `"$hostName`" via esxcli: $($_.Exception.Message). vSAN witness traffic is required; deployment will roll back."
        throw [VcfDeploymentException]::new("vSAN witness traffic is required. Could not add vSAN witness traffic to $VmkernelName on host `"$hostName`" via esxcli: $($_.Exception.Message). Enable witness traffic on a VMkernel (e.g. in vCenter UI) or retry. Deployment will roll back.")
    }
}
Function Set-VmkernelIpv4StaticGatewayViaEsxcli {

    <#
        .SYNOPSIS
        Applies static IPv4, netmask, and default gateway on a VMkernel using esxcli.

        .DESCRIPTION
        VCF PowerCLI 9 **Set-VMHostNetworkAdapter** does not expose a default-gateway parameter for VMkernel adapters.
        **New-VMHostNetworkAdapter** sets IP and mask only. For **vSAN Witness** VMkernels that need a default route (e.g. to reach the witness appliance), this function calls **esxcli network ip interface ipv4 set** so the gateway from **networkingVmKernelInterfaces** is actually configured on the host.

        .PARAMETER GatewayAddress
        IPv4 address of the default gateway (e.g. **10.30.12.1**). A **/prefix** suffix, if present, is stripped.

        .PARAMETER Ipv4Address
        Static IPv4 address already assigned to the VMkernel (same subnet as the gateway).

        .PARAMETER Server
        vCenter server name for **Get-EsxCli**.

        .PARAMETER SubnetMask
        IPv4 netmask for the VMkernel (e.g. **255.255.255.0**).

        .PARAMETER VMHost
        Target ESX host.

        .PARAMETER VmkernelName
        VMkernel device name (e.g. **vmk3**).

        .NOTES
        Uses **Get-EsxCli** V2. Non-fatal mismatches are not expected; failure throws so deployment can roll back or be retried after fixing networking.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$GatewayAddress,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Ipv4Address,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$Server = $Script:vCenterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SubnetMask,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] $VMHost,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VmkernelName
    )

    $hostName = if ($VMHost.Name) { $VMHost.Name } else { [string]$VMHost }
    $gw = $GatewayAddress.Trim()
    if ($gw -match "/") {
        $gw = ($gw -split "/")[0].Trim()
    }
    if (-not (Test-ValidIPv4Address -IpAddress $gw)) {
        Write-LogMessage -Type ERROR -Message "Set-VmkernelIpv4StaticGatewayViaEsxcli: gateway `"$gw`" is not a valid IPv4 address for host `"$hostName`"."
        throw [VcfDeploymentException]::new("Invalid gateway address for witness VMkernel gateway: `"$gw`".")
    }

    try {
        $esxcli = Get-EsxCli -VMHost $VMHost -V2 -Server $Server -ErrorAction Stop
    } catch {
        Write-LogMessage -Type ERROR -Message "Set-VmkernelIpv4StaticGatewayViaEsxcli: Get-EsxCli failed on `"$hostName`": $($_.Exception.Message)"
        throw
    }

    $setCmd = $null
    if ($esxcli.network -and $esxcli.network.ip -and $esxcli.network.ip.interface -and $esxcli.network.ip.interface.ipv4) {
        $setCmd = $esxcli.network.ip.interface.ipv4.set
    }
    if (-not $setCmd) {
        Write-LogMessage -Type ERROR -Message "Set-VmkernelIpv4StaticGatewayViaEsxcli: esxcli network ip interface ipv4 set is not available on host `"$hostName`"."
        throw [VcfDeploymentException]::new("Could not set VMkernel gateway: esxcli network ip interface ipv4 set is not available on host `"$hostName`".")
    }

    $lastError = $null
    try {
        $argsObj = $setCmd.CreateArgs()
        if ($null -ne $argsObj) {
            $argNames = @()
            $isHashtable = $argsObj -is [System.Collections.Hashtable] -or $argsObj -is [System.Collections.IDictionary]
            $isCollection = -not $isHashtable -and $argsObj -is [System.Collections.IEnumerable] -and $argsObj -isnot [string]
            if ($isHashtable) {
                $argNames = @($argsObj.Keys | ForEach-Object { $_ })
            }
            elseif ($isCollection) {
                $argNames = @($argsObj | ForEach-Object { if ($_.PSObject.Properties["Name"]) { $_.Name } elseif ($_.Key) { $_.Key } else { $_ } })
            }
            else {
                $argNames = @($argsObj.PSObject.Properties | ForEach-Object { $_.Name })
            }
            $ifaceParam = $argNames | Where-Object { $_ -and ($_ -match "^i$|^interfacename$|interface-name|interface_name") } | Select-Object -First 1
            $ipParam = $argNames | Where-Object { $_ -and ($_ -match "^ipv4$|^I$|^-I$") } | Select-Object -First 1
            $maskParam = $argNames | Where-Object { $_ -and ($_ -match "netmask|^N$") } | Select-Object -First 1
            $gwParam = $argNames | Where-Object { $_ -and ($_ -match "gateway|^g$") } | Select-Object -First 1
            $typeParam = $argNames | Where-Object { $_ -and ($_ -match "^type$|^t$") } | Select-Object -First 1
            if ($ifaceParam -and $ipParam -and $maskParam -and $typeParam) {
                if ($isHashtable -or $isCollection) {
                    $invokeTable = @{
                        $ifaceParam = $VmkernelName
                        $ipParam    = $Ipv4Address
                        $maskParam  = $SubnetMask
                        $typeParam  = "static"
                    }
                    if ($gwParam) {
                        $invokeTable[$gwParam] = $gw
                    }
                    $setCmd.Invoke($invokeTable) | Out-Null
                }
                else {
                    $argsObj.$ifaceParam = $VmkernelName
                    $argsObj.$ipParam = $Ipv4Address
                    $argsObj.$maskParam = $SubnetMask
                    if ($gwParam) {
                        $argsObj.$gwParam = $gw
                    }
                    $argsObj.$typeParam = "static"
                    $setCmd.Invoke($argsObj) | Out-Null
                }
                Write-LogMessage -Type INFO -Message "Set default gateway $gw on $VmkernelName on host `"$hostName`" (esxcli network ip interface ipv4 set)."
                return
            }
        }
    } catch {
        $lastError = $_.Exception.Message
        Write-LogMessage -Type DEBUG -Message "Set-VmkernelIpv4StaticGatewayViaEsxcli: CreateArgs path failed: $lastError"
    }

    $paramSets = @(
        @{ interfacename = $VmkernelName; ipv4 = $Ipv4Address; netmask = $SubnetMask; gateway = $gw; type = "static" },
        @{ "interface-name" = $VmkernelName; ipv4 = $Ipv4Address; netmask = $SubnetMask; gateway = $gw; type = "static" },
        @{ interface_name = $VmkernelName; ipv4 = $Ipv4Address; netmask = $SubnetMask; gateway = $gw; type = "static" }
    )
    foreach ($ps in $paramSets) {
        try {
            $setCmd.Invoke($ps) | Out-Null
            Write-LogMessage -Type INFO -Message "Set default gateway $gw on $VmkernelName on host `"$hostName`" (esxcli fallback parameter set)."
            return
        } catch {
            $lastError = $_.Exception.Message
            continue
        }
    }
    Write-LogMessage -Type ERROR -Message "Set-VmkernelIpv4StaticGatewayViaEsxcli: all attempts failed on `"$hostName`" for $VmkernelName. Last error: $lastError"
    throw [VcfDeploymentException]::new("Could not set default gateway on VMkernel `"$VmkernelName`" on host `"$hostName`" via esxcli. Last error: $lastError")
}
Function Invoke-AddHostToClusterRunningVmSafetyCheck {
    <#
        .SYNOPSIS
        Stops Add-HostToCluster when the host has powered-on VMs unless the operator confirms.

        .DESCRIPTION
        When the ESX host is already in vCenter inventory, lists powered-on VMs, logs which vCenter manages the host, and prompts Y/N (default N). Non-interactive sessions or any response other than Y aborts with a clear throw.

        .PARAMETER ClusterName
        Target cluster name (for prompt text).

        .PARAMETER EsxHostName
        Host name or IP (for prompt text).

        .PARAMETER Server
        vCenter server name (shown to the operator and used for Get-VM).

        .PARAMETER VMHost
        The VMHost object to query for VMs.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EsxHostName,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$Server = $Script:vCenterName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [VMware.VimAutomation.ViCore.Types.V1.Inventory.VMHost]$VMHost
    )

    $inventoryLocation = "n/a"
    try {
        if ($VMHost.Parent -and $VMHost.Parent.Name) {
            $inventoryLocation = [string]$VMHost.Parent.Name
        }
    } catch {
        $inventoryLocation = "(unknown)"
    }

    $runningVms = @(
        Get-VM -VMHost $VMHost -Server $Server -ErrorAction SilentlyContinue |
            Where-Object { "$($_.PowerState)" -eq "PoweredOn" }
    )

    if ($runningVms.Count -eq 0) {
        Write-LogMessage -Type DEBUG -Message "Add-HostToCluster running-VM safety: host `"$EsxHostName`" has no powered-on VMs on vCenter `"$Server`"."
        return
    }

    Write-LogMessage -Type WARNING -Message "Host `"$EsxHostName`" is managed by vCenter `"$Server`" (inventory parent: `"$inventoryLocation`"). Powered-on VM count: $($runningVms.Count)."
    foreach ($vm in ($runningVms | Sort-Object -Property Name)) {
        $guestOs = "n/a"
        try {
            if ($vm.Guest -and $vm.Guest.OSFullName) { $guestOs = [string]$vm.Guest.OSFullName }
        } catch {
            $guestOs = "n/a"
        }
        Write-LogMessage -Type WARNING -Message "  Running VM: Name=`"$($vm.Name)`", PowerState=$($vm.PowerState), GuestOS=$guestOs."
    }

    $continuePrompt = "Add host `"$EsxHostName`" to cluster `"$ClusterName`" anyway despite $($runningVms.Count) powered-on VM(s)? (Y/N; press Enter for N)"
    $continueAnyway = $false
    try {
        do {
            $response = Read-Host $continuePrompt
            $response = if ($response) { $response.Trim() } else { "" }
            if ($response -match '^[yY](es)?$') {
                $continueAnyway = $true
                Write-LogMessage -Type WARNING -Message "User chose to add host `"$EsxHostName`" to cluster `"$ClusterName`" despite $($runningVms.Count) powered-on VM(s). Proceeding."
                break
            }
            if ([String]::IsNullOrWhiteSpace($response) -or $response -match '^[nN](o)?$') {
                break
            }
            Write-LogMessage -Type WARNING -Message "Invalid response. Enter Y or N (or press Enter for N)."
        } while ($true)
    } catch {
        Write-LogMessage -Type WARNING -Message "Read-Host failed (non-interactive?): $($_.Exception.Message). Treating as N."
    }

    if (-not $continueAnyway) {
        throw "Deployment aborted. Host `"$EsxHostName`" has $($runningVms.Count) powered-on VM(s) on vCenter `"$Server`". Power off or migrate the VMs, then re-run."
    }
}
Function Add-HostToCluster {

    <#
        .SYNOPSIS
        Adds an ESX host to an existing vSphere cluster and verifies successful integration.

        .DESCRIPTION
        This function adds an ESX host to a specified vSphere cluster within a vCenter environment.
        It performs the following operations:
        1. Retrieves the target cluster object from vCenter
        2. If the host is already in vCenter inventory, checks for powered-on VMs; if any exist, logs them and the managing vCenter, then prompts Y/N (default N) before continuing
        3. Adds the ESX host to the cluster using the provided credentials
        4. Verifies that the host was successfully added by checking cluster membership
        5. Provides appropriate logging for success or failure scenarios

        The function uses the Force parameter to bypass confirmation prompts during host addition.

        .EXAMPLE
        Add-HostToCluster -ClusterName "cl02" -EsxHostName "esx01.example.com" -EsxCredential $EsxCredential

        This example adds the ESX host "esx01.example.com" to the cluster "cl02"
        in the vCenter "vcenter.example.com" using the provided ESX credentials.

        .PARAMETER ClusterName
        Specifies the name of the vSphere cluster where the ESX host will be added.
        The cluster must already exist in the specified vCenter.

        .PARAMETER EsxHostName
        Specifies the FQDN or IP address of the ESX host to be added to the cluster.

        .PARAMETER EsxCredential
        Specifies the PSCredential object containing the username and password for authenticating
        with the ESX host during the addition process.

        .NOTES
        - Requires VMware PowerCLI to be installed and imported
        - The user must have appropriate privileges in vCenter to add hosts to clusters
        - The ESX host should be accessible from the vCenter
        - Any existing host configuration will be preserved during cluster addition

        .PARAMETER StoragePolicyType
        Storage type for the cluster (VMFS, vSAN-ESA, vSAN-OSA). vSAN/vSAN witness VMkernel traffic is ensured in the main deployment after Set-VirtualDistributedSwitch (once mgmt vmk0 is on VDS), not in this function.

        .PARAMETER AddHostRetryCount
        When Add-VMHost fails with "current state of the object" or "already exists" and the host is not yet in the cluster, number of retries before failing. Default is 3.

        .PARAMETER AddHostRetryDelaySeconds
        Seconds to wait between Add-VMHost retries. Default is 10.

        .PARAMETER HostAppearanceRecheckDelaySeconds
        When Add-VMHost throws "already exists" or "current state of the object" and the host is not yet visible in the cluster, wait this many seconds and re-query before retrying. The add may have completed on vCenter but the host can appear in inventory shortly after. Default is 5.

        .PARAMETER HostStateChangeDelaySeconds
        Seconds to wait after Add-VMHost returns success before verifying host connection state. Default is 10.

        .PARAMETER WaitForAddHostTaskTimeoutSeconds
        When greater than 0, Add-VMHost is run with -RunAsync and the function polls for the host add task to complete (Get-Task) instead of waiting for the synchronous cmdlet. Ensures the add is complete before returning so the next host can be added without a fixed delay. Default is 300. Set to 0 to use synchronous Add-VMHost (previous behavior).

        .PARAMETER AddHostTaskPollIntervalSeconds
        When waiting for the Add-VMHost task (RunAsync), seconds between Get-Task polls. Default is 5.
    #>

    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(1, 60)] [Int]$AddHostTaskPollIntervalSeconds = 5,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 10)] [Int]$AddHostRetryCount = 3,
        [Parameter(Mandatory = $false)] [ValidateRange(5, 120)] [Int]$AddHostRetryDelaySeconds = 10,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [PSCredential]$EsxCredential,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EsxHostName,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 60)] [Int]$HostAppearanceRecheckDelaySeconds = 5,
        [Parameter(Mandatory = $false)] [ValidateRange(1, [int]::MaxValue)] [Int]$HostStateChangeDelaySeconds = 10,
        [Parameter(Mandatory = $false)] [ValidateRange(0, 900)] [Int]$WaitForAddHostTaskTimeoutSeconds = 300,
        [Parameter(Mandatory = $false)] [ValidateSet("VMFS", "vSAN-ESA", "vSAN-OSA")] [String]$StoragePolicyType = "VMFS"
    )

    Write-LogMessage -Type DEBUG -Message "Entered Add-HostToCluster function..."

    $connectionTest = Test-VcenterConnection
    if (-not $connectionTest.IsConnected) {
        Write-LogMessage -Type ERROR -Message "Not connected to vCenter `"$Script:vCenterName`": $($connectionTest.ErrorMessage)"
        throw [VcfDeploymentException]::new("Not connected to vCenter `"$Script:vCenterName`": $($connectionTest.ErrorMessage)")
    }

    try {
        # Retrieve the target cluster object from vCenter.
    try {
        $clusterObject = Get-Cluster -Name $ClusterName -Server $Script:vCenterName -ErrorAction Stop
    } catch [System.UnauthorizedAccessException] {
        Write-LogMessage -Type ERROR -Message "Cannot perform Get-Cluster operation for cluster `"$ClusterName`" on vCenter `"$Script:vCenterName`" due to authorization issues: $($_.Exception.Message)"
        throw [VcfDeploymentException]::new("Cannot perform Get-Cluster operation for cluster `"$ClusterName`" on vCenter `"$Script:vCenterName`" due to authorization issues: $($_.Exception.Message)")
    }
    catch [System.TimeoutException] {
        Write-LogMessage -Type ERROR -Message "Cannot perform Get-Cluster operation for cluster `"$ClusterName`" on vCenter `"$Script:vCenterName`" due to network/timeout issues: $($_.Exception.Message)"
        throw [VcfDeploymentException]::new("Cannot perform Get-Cluster operation for cluster `"$ClusterName`" on vCenter `"$Script:vCenterName`" due to network/timeout issues: $($_.Exception.Message)")
    }
    catch [VMware.VimAutomation.ViCore.Types.V1.ErrorHandling.InvalidLogin] {
        Write-LogMessage -Type ERROR -Message "vCenter session was logged out or expired. Do not log out the vCenter user session during deployment. Re-run the deployment to reconnect."
        throw [VcfDeploymentException]::new("vCenter session was logged out or expired. Do not log out the vCenter user session during deployment. Re-run the deployment to reconnect.")
    }
    catch [VMware.VimAutomation.Sdk.Types.V1.ErrorHandling.VimException.ViServerConnectionException] {
        Write-LogMessage -Type ERROR -Message "vCenter connection was lost (session logged out, vCenter restart, or network). Re-run the deployment to reconnect."
        throw [VcfDeploymentException]::new("vCenter connection was lost (session logged out, vCenter restart, or network). Re-run the deployment to reconnect.")
    } catch [VcfDeploymentException] {
        throw  # already logged and typed — propagate without re-wrapping
    } catch {
        Write-LogMessage -Type ERROR -AppendNewLine -Message "Failed to perform Get-Cluster operation for cluster `"$ClusterName`" on vCenter `"$Script:vCenterName`" : $($_.Exception.Message)"
        throw [VcfDeploymentException]::new("Failed to perform Get-Cluster operation for cluster `"$ClusterName`" on vCenter `"$Script:vCenterName`" : $($_.Exception.Message)")
    }

    # vSAN/vSAN witness VMkernel traffic is ensured after Set-VirtualDistributedSwitch (once mgmt vmk0 is on VDS). See post-VDS step in main deployment.

    # Check if the host is already in the cluster.
    try {
        $existingHost = $clusterObject | Get-VMHost -Name $EsxHostName -Server $Script:vCenterName -ErrorAction SilentlyContinue
    } catch {
        # If Get-VMHost fails, continue to add the host.
        $existingHost = $null
    }

    if ($existingHost) {
        Write-LogMessage -Type INFO -Message "Host `"$EsxHostName`" is already in cluster `"$ClusterName`". Skipping host add."
        return
    }

    $hostForRunningVmCheck = Get-VMHost -Name $EsxHostName -Server $Script:vCenterName -ErrorAction SilentlyContinue
    if ($hostForRunningVmCheck) {
        Invoke-AddHostToClusterRunningVmSafetyCheck -ClusterName $ClusterName -EsxHostName $EsxHostName -Server $Script:vCenterName -VMHost $hostForRunningVmCheck
    } else {
        Write-LogMessage -Type DEBUG -Message "Add-HostToCluster: host `"$EsxHostName`" not in vCenter inventory before add; skipping powered-on VM check (VMs are not enumerable until the host is managed by this vCenter)."
    }

    # Attempt to add the ESX host to the specified cluster. When WaitForAddHostTaskTimeoutSeconds > 0, use RunAsync and poll for task completion so the next host can be added without a fixed delay.
    Write-LogMessage -Type INFO -NoNewline -Message "Adding ESX host `"$EsxHostName`" to cluster `"$ClusterName`"... "
    $addHostAttempt = 1
    $addHostSucceeded = $false
    $savedProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        do {
            $errorMessage = $null
            $task = $null
            if ($WaitForAddHostTaskTimeoutSeconds -gt 0) {
                try {
                    $task = Add-VMHost -Name $EsxHostName -Credential $EsxCredential -Location $clusterObject -Force -Server $Script:vCenterName -RunAsync -ErrorAction Stop
                } catch [System.UnauthorizedAccessException] {
                    Write-LogMessage -Type ERROR -Message "Cannot add host `"$EsxHostName`" to cluster `"$ClusterName`" in vCenter `"$Script:vCenterName`" due to authorization issues: $($_.Exception.Message)"
                    throw [VcfDeploymentException]::new("Cannot add host `"$EsxHostName`" to cluster `"$ClusterName`" in vCenter `"$Script:vCenterName`" due to authorization issues: $($_.Exception.Message)")
                } catch [System.TimeoutException] {
                    Write-LogMessage -Type ERROR -Message "Cannot add host `"$EsxHostName`" to cluster `"$ClusterName`" in vCenter `"$Script:vCenterName`" due to network/timeout issues: $($_.Exception.Message)"
                    throw [VcfDeploymentException]::new("Cannot add host `"$EsxHostName`" to cluster `"$ClusterName`" in vCenter `"$Script:vCenterName`" due to network/timeout issues: $($_.Exception.Message)")
                } catch [VMware.VimAutomation.ViCore.Types.V1.ErrorHandling.InvalidLogin] {
                    Write-LogMessage -Type ERROR -Message "vCenter session was logged out or expired while adding host `"$EsxHostName`". Do not log out the vCenter user session while Add-VMHost or other deployment tasks are in progress. Re-run the deployment to reconnect and retry."
                    throw [VcfDeploymentException]::new("vCenter session was logged out or expired while adding host `"$EsxHostName`". Do not log out the vCenter user session while Add-VMHost or other deployment tasks are in progress. Re-run the deployment to reconnect and retry.")
                } catch [VMware.VimAutomation.Sdk.Types.V1.ErrorHandling.VimException.ViServerConnectionException] {
                    Write-LogMessage -Type ERROR -Message "vCenter connection was lost while adding host `"$EsxHostName`" (session logged out, vCenter restart, or network issue). Re-run the deployment to reconnect and retry."
                    throw [VcfDeploymentException]::new("vCenter connection was lost while adding host `"$EsxHostName`" (session logged out, vCenter restart, or network issue). Re-run the deployment to reconnect and retry.")
                } catch {
                    $errorMessage = $_.Exception.Message
                }
                if ($task -and -not $errorMessage) {
                    $deadline = (Get-Date).AddSeconds($WaitForAddHostTaskTimeoutSeconds)
                    while ((Get-Date) -lt $deadline) {
                        $currentTask = Get-Task -Id $task.Id -Server $Script:vCenterName -ErrorAction SilentlyContinue
                        if ($currentTask) {
                            $state = if ($currentTask.PSObject.Properties['State']) { $currentTask.State } else { $currentTask.Status }
                            if ($state -eq 'Success') {
                                $addHostSucceeded = $true
                                break
                            }
                            if ($state -eq 'Error') {
                                if ($currentTask.ExtensionData -and $currentTask.ExtensionData.Info -and $currentTask.ExtensionData.Info.Error) {
                                    if ($currentTask.ExtensionData.Info.Error.LocalizedMessage) {
                                        $errorMessage = $currentTask.ExtensionData.Info.Error.LocalizedMessage
                                    } elseif ($currentTask.ExtensionData.Info.Error.Fault) {
                                        $errorMessage = $currentTask.ExtensionData.Info.Error.Fault.ToString()
                                    } else {
                                        $errorMessage = "Add host task failed."
                                    }
                                } else {
                                    $errorMessage = "Add host task failed."
                                }
                                Write-LogMessage -Type DEBUG -Message "Add-VMHost task failed (attempt $addHostAttempt): $errorMessage"
                                break
                            }
                        }
                        Start-Sleep -Seconds $AddHostTaskPollIntervalSeconds
                    }
                    if (-not $addHostSucceeded -and -not $errorMessage) {
                        $errorMessage = "Add host task did not complete within $WaitForAddHostTaskTimeoutSeconds seconds."
                        Write-LogMessage -Type DEBUG -Message "Add-VMHost task timeout (attempt $addHostAttempt)."
                    }
                }
            } else {
                try {
                    Add-VMHost -Name $EsxHostName -Credential $EsxCredential -Location $clusterObject -Force -Server $Script:vCenterName -ErrorAction Stop | Out-Null
                    $addHostSucceeded = $true
                    break
                } catch [System.UnauthorizedAccessException] {
                    Write-LogMessage -Type ERROR -Message "Cannot add host `"$EsxHostName`" to cluster `"$ClusterName`" in vCenter `"$Script:vCenterName`" due to authorization issues: $($_.Exception.Message)"
                    throw [VcfDeploymentException]::new("Cannot add host `"$EsxHostName`" to cluster `"$ClusterName`" in vCenter `"$Script:vCenterName`" due to authorization issues: $($_.Exception.Message)")
                } catch [System.TimeoutException] {
                    Write-LogMessage -Type ERROR -Message "Cannot add host `"$EsxHostName`" to cluster `"$ClusterName`" in vCenter `"$Script:vCenterName`" due to network/timeout issues: $($_.Exception.Message)"
                    throw [VcfDeploymentException]::new("Cannot add host `"$EsxHostName`" to cluster `"$ClusterName`" in vCenter `"$Script:vCenterName`" due to network/timeout issues: $($_.Exception.Message)")
                } catch [VMware.VimAutomation.ViCore.Types.V1.ErrorHandling.InvalidLogin] {
                    Write-LogMessage -Type ERROR -Message "vCenter session was logged out or expired while adding host `"$EsxHostName`". Do not log out the vCenter user session while Add-VMHost or other deployment tasks are in progress. Re-run the deployment to reconnect and retry."
                    throw [VcfDeploymentException]::new("vCenter session was logged out or expired while adding host `"$EsxHostName`". Do not log out the vCenter user session while Add-VMHost or other deployment tasks are in progress. Re-run the deployment to reconnect and retry.")
                } catch [VMware.VimAutomation.Sdk.Types.V1.ErrorHandling.VimException.ViServerConnectionException] {
                    Write-LogMessage -Type ERROR -Message "vCenter connection was lost while adding host `"$EsxHostName`" (session logged out, vCenter restart, or network issue). Re-run the deployment to reconnect and retry."
                    throw [VcfDeploymentException]::new("vCenter connection was lost while adding host `"$EsxHostName`" (session logged out, vCenter restart, or network issue). Re-run the deployment to reconnect and retry.")
                } catch {
                    $errorMessage = $_.Exception.Message
                }
            }
            if ($addHostSucceeded) { break }
            if (-not $errorMessage) { $errorMessage = "Add host failed (no task or error details)." }
            if ($errorMessage -match "already being managed|already managed by this vSphere server") {
                Write-LogMessage -Type DEBUG -Message "Add-VMHost threw (attempt $addHostAttempt): $errorMessage"
                $hostInVc = Get-VMHost -Name $EsxHostName -Server $Script:vCenterName -ErrorAction SilentlyContinue
                if ($hostInVc -and $hostInVc.Parent.Name -eq $ClusterName -and $addHostAttempt -gt 1) {
                    Write-LogMessage -Type INFO -Message "Normal: Host `"$EsxHostName`" is in cluster `"$ClusterName`" (vCenter reported already managed on retry; likely added on previous attempt this run). Proceeding."
                    $addHostSucceeded = $true
                    break
                }
                if ($hostInVc -and $hostInVc.Parent.Name -eq $ClusterName -and $addHostAttempt -eq 1) {
                    Write-LogMessage -Type INFO -Message "Host `"$EsxHostName`" is already in cluster `"$ClusterName`" (vCenter reported already managed). Skipping host add (idempotent)."
                    $addHostSucceeded = $true
                    break
                }
                $otherCluster = if ($hostInVc) { $hostInVc.Parent.Name } else { "another cluster" }
                Write-LogMessage -Type ERROR -Message "Host `"$EsxHostName`" is already managed by vCenter `"$Script:vCenterName`" (in cluster: `"$otherCluster`"). Remove the host from that cluster in vCenter, or remove it from vCenter, then re-run the deployment."
                throw [VcfDeploymentException]::new("Host `"$EsxHostName`" is already managed by vCenter `"$Script:vCenterName`" (in cluster: `"$otherCluster`"). Remove the host from that cluster in vCenter, or remove it from vCenter, then re-run the deployment.")
            }
            if ($errorMessage -match "vSAN cluster UUID mismatch|vSAN host cannot be moved to the destination cluster") {
                Write-LogMessage -Type ERROR -Message "Host `"$EsxHostName`" belongs to a different vSAN cluster (vSAN cluster UUID mismatch). Remove the host from the other vSAN cluster in vCenter, or remove it from vCenter, then re-run the deployment. Moving a vSAN host between clusters requires removing it first."
                throw [VcfDeploymentException]::new("Host `"$EsxHostName`" belongs to a different vSAN cluster (vSAN cluster UUID mismatch). Remove the host from the other vSAN cluster in vCenter, or remove it from vCenter, then re-run the deployment. Moving a vSAN host between clusters requires removing it first.")
            }
            if ($errorMessage -match "already exists|current state of the object|did not complete within") {
                Write-LogMessage -Type DEBUG -Message "Add-VMHost threw (attempt $addHostAttempt): $errorMessage"
                $hostNowInCluster = $clusterObject | Get-VMHost -Name $EsxHostName -Server $Script:vCenterName -ErrorAction SilentlyContinue
                if ($hostNowInCluster) {
                    Write-LogMessage -Type INFO -Message "Host `"$EsxHostName`" is in cluster `"$ClusterName`" (add completed despite error; host may still be connecting). Proceeding."
                    $addHostSucceeded = $true
                    break
                }
                if ($addHostAttempt -lt $AddHostRetryCount) {
                    Write-LogMessage -Type WARNING -Message "Add-VMHost failed (attempt $addHostAttempt of $AddHostRetryCount). Error: $errorMessage. Waiting $HostAppearanceRecheckDelaySeconds seconds to recheck cluster, then retry."
                    Start-Sleep -Seconds $HostAppearanceRecheckDelaySeconds
                    $hostNowInCluster = $clusterObject | Get-VMHost -Name $EsxHostName -Server $Script:vCenterName -ErrorAction SilentlyContinue
                    if ($hostNowInCluster) {
                        Write-LogMessage -Type INFO -Message "Host `"$EsxHostName`" is in cluster `"$ClusterName`" after recheck (add completed on first attempt; host appeared in inventory). Proceeding."
                        $addHostSucceeded = $true
                        break
                    }
                    Write-LogMessage -Type WARNING -Message "Host not in cluster after recheck. Waiting $AddHostRetryDelaySeconds seconds before retry."
                    Start-Sleep -Seconds $AddHostRetryDelaySeconds
                    $addHostAttempt++
                    continue
                }
                Write-LogMessage -Type ERROR -Message "Add-VMHost failed after $AddHostRetryCount attempt(s). If the host is in another cluster, remove it from vCenter and re-run. Otherwise check vCenter logs and re-run."
                throw [VcfDeploymentException]::new("Add-VMHost failed after $AddHostRetryCount attempt(s). If the host is in another cluster, remove it from vCenter and re-run. Otherwise check vCenter logs and re-run.")
            }
            if ($errorMessage -match "session|logged out|expired|InvalidLogin|Authentication failed") {
                Write-LogMessage -Type ERROR -Message "The vCenter session may have been logged out during the operation. Do not log out the vCenter user session while deployment tasks are in progress. Re-run the deployment to reconnect."
                throw [VcfDeploymentException]::new("The vCenter session may have been logged out during the operation. Do not log out the vCenter user session while deployment tasks are in progress. Re-run the deployment to reconnect.")
            }
            Write-LogMessage -Type ERROR -Message "Failed to add host `"$EsxHostName`" to cluster `"$ClusterName`" in vCenter `"$Script:vCenterName`": $errorMessage"
            throw [VcfDeploymentException]::new("Failed to add host `"$EsxHostName`" to cluster `"$ClusterName`" in vCenter `"$Script:vCenterName`": $errorMessage")
        } while ($addHostAttempt -le $AddHostRetryCount -and -not $addHostSucceeded)
    } finally {
        $ProgressPreference = $savedProgress
    }

    if (-not $addHostSucceeded) {
        Write-LogMessage -Type ERROR -Message "Failed to add host `"$EsxHostName`" to cluster `"$ClusterName`" after $AddHostRetryCount attempt(s). Workflow will fail."
        throw [VcfDeploymentException]::new("Failed to add host `"$EsxHostName`" to cluster `"$ClusterName`" after $AddHostRetryCount attempt(s). Workflow will fail.")
    }

    # Verify that the host was successfully added.
    Start-Sleep $HostStateChangeDelaySeconds
    $connectionAfterAdd = Test-VcenterConnection
    if (-not $connectionAfterAdd.IsConnected) {
        Write-LogMessage -Type ERROR -Message "vCenter session is no longer valid after Add-VMHost (session may have been logged out while the task was in progress): $($connectionAfterAdd.ErrorMessage). Re-run the deployment to reconnect and verify the host was added."
        throw [VcfDeploymentException]::new("vCenter session is no longer valid after Add-VMHost (session may have been logged out while the task was in progress): $($connectionAfterAdd.ErrorMessage). Re-run the deployment to reconnect and verify the host was added.")
    }
    try {
        $verifyHost = Get-VMHost -Name $EsxHostName -Server $Script:vCenterName -ErrorAction Stop
    } catch [VMware.VimAutomation.ViCore.Types.V1.ErrorHandling.InvalidLogin] {
        Write-LogMessage -Type ERROR -Message "vCenter session was logged out or expired. Re-run the deployment to reconnect and verify host `"$EsxHostName`" was added."
        throw [VcfDeploymentException]::new("vCenter session was logged out or expired. Re-run the deployment to reconnect and verify host `"$EsxHostName`" was added.")
    } catch [VMware.VimAutomation.Sdk.Types.V1.ErrorHandling.VimException.ViServerConnectionException] {
        Write-LogMessage -Type ERROR -Message "vCenter connection was lost. Re-run the deployment to reconnect and verify host `"$EsxHostName`" was added."
        throw [VcfDeploymentException]::new("vCenter connection was lost. Re-run the deployment to reconnect and verify host `"$EsxHostName`" was added.")
    } catch [VcfDeploymentException] {
        throw  # already logged and typed — propagate without re-wrapping
    } catch {
        Write-LogMessage -Type ERROR -Message "Failed to verify host `"$EsxHostName`" in vCenter `"$Script:vCenterName`" : $($_.Exception.Message)"
        throw [VcfDeploymentException]::new("Failed to verify host `"$EsxHostName`" in vCenter `"$Script:vCenterName`" : $($_.Exception.Message)")
    }

    # Check if host is in the correct cluster.
    if ($verifyHost.Parent.Name -ne $ClusterName) {
        Write-LogMessage -Type ERROR -Message "Failed to add `"$EsxHostName`" to cluster `"$ClusterName`" in vCenter `"$Script:vCenterName`". Host is in cluster: `"$($verifyHost.Parent.Name)`""
        throw [VcfDeploymentException]::new("Failed to add `"$EsxHostName`" to cluster `"$ClusterName`" in vCenter `"$Script:vCenterName`". Host is in cluster: `"$($verifyHost.Parent.Name)`"")
    }

    # vSAN/vSAN witness VMkernel traffic is ensured after Set-VirtualDistributedSwitch (once mgmt vmk0 is on VDS). See post-VDS step in main deployment.

    # Only set to connected state if host is not already connected (error condition).
    if ($verifyHost.ConnectionState -ne "Connected") {
        Write-LogMessage -Type INFO -NoNewline -Message "Setting host `"$EsxHostName`" to connected state (current state: `"$($verifyHost.ConnectionState)`")... "
        try {
            Set-VMHost -VMHost $EsxHostName -Server $Script:vCenterName -State Connected -Confirm:$false -ErrorAction Stop | Out-Null
            Write-LogMessage -Type INFO -CompletePending -Message "Set"
        } catch [System.UnauthorizedAccessException] {
            Write-LogMessage -Type ERROR -CompletePending -Message " Failed."
            throw [VcfDeploymentException]::new(" Failed.")
        }
        catch [System.TimeoutException] {
            Write-LogMessage -Type ERROR -CompletePending -Message " Failed."
            throw [VcfDeploymentException]::new(" Failed.")
        }
        catch [VMware.VimAutomation.ViCore.Types.V1.ErrorHandling.InvalidLogin] {
            Write-LogMessage -Type ERROR -CompletePending -Message " Failed."
            throw [VcfDeploymentException]::new(" Failed.")
        }
        catch [VMware.VimAutomation.Sdk.Types.V1.ErrorHandling.VimException.ViServerConnectionException] {
            Write-LogMessage -Type ERROR -CompletePending -Message " Failed."
            throw [VcfDeploymentException]::new(" Failed.")
        } catch {
            Write-LogMessage -Type ERROR -CompletePending -Message " Failed."
            throw [VcfDeploymentException]::new(" Failed.")
        }
    }

        Write-LogMessage -Type INFO -CompletePending -Message "Success"
    } catch {
        Write-LogMessage -Type ERROR -CompletePending -Message " Failed."
        if ($StoragePolicyType -eq "vSAN-ESA" -or $StoragePolicyType -eq "vSAN-OSA") {
            Write-LogMessage -Type INFO -Message "vSAN witness traffic or host add failed for cluster `"$ClusterName`". You will be prompted whether to roll back (same sequence as cleanup: VMkernel removal, management restore, vSAN disk/leave/tags, VDS removal, cluster removal)."
        }
        throw
    }
}
Function Get-ClusterId {

    <#
        .SYNOPSIS
        Retrieves the MoRef identifier for a vSphere cluster.

        .DESCRIPTION
        The Get-ClusterId function queries the vCenter to find a vSphere cluster by name and returns its
        MoRef identifier (e.g., "domain-c2045"). This identifier is required by VCF PowerCLI 9 cmdlets such as
        Invoke-EnableOnComputeClusterClusterSupervisors for enabling vSphere Supervisor on a cluster.

        The function extracts the MoRef value from the cluster's ExtensionData, which is different from the
        cluster's .Id property that returns the full type-prefixed ID (e.g., "ClusterComputeResource-domain-c2045").

        The function will terminate the script with an error if the cluster is not found or if any other error
        occurs during the lookup.

        .PARAMETER ClusterName
        The name of the vSphere cluster for which to retrieve the MoRef identifier. This parameter is mandatory.

        .EXAMPLE
        Get-ClusterId -ClusterName "compute-cluster-01"
        Returns the MoRef identifier (e.g., "domain-c2045") for the cluster named "compute-cluster-01".

        .EXAMPLE
        $clusterId = Get-ClusterId -ClusterName "edge-cluster"
        Stores the cluster MoRef ID in a variable for use with VCF PowerCLI 9 supervisor enablement cmdlets.

        .OUTPUTS
        System.String
        Returns the MoRef identifier for the cluster (e.g., "domain-c2045").

        .NOTES
        - Requires an active connection to vCenter (uses $Script:vCenterName)
        - Uses Get-Cluster cmdlet from VMware PowerCLI
        - Throws a terminating error if the cluster is not found or any error occurs
        - Returns the ExtensionData.MoRef.Value property which is the identifier expected by VCF PowerCLI 9 APIs
        - The returned ID format is "domain-cXXXX" without the "ClusterComputeResource-" prefix
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName
    )

    Write-LogMessage -Type DEBUG -Message "Entered Get-ClusterId function..."

    $connectionTest = Test-VcenterConnection
    if (-not $connectionTest.IsConnected) {
        Write-LogMessage -Type ERROR -Message "Not connected to vCenter `"$Script:vCenterName`": $($connectionTest.ErrorMessage)"
        throw [VcfDeploymentException]::new("Not connected to vCenter `"$Script:vCenterName`": $($connectionTest.ErrorMessage)")
    }

    try {
        $clusterObject = Get-Cluster -Name $ClusterName -Server $Script:vCenterName -ErrorAction Stop

        # Extract the MoRef ID (e.g., "domain-c2045") from ExtensionData
        # VCF PowerCLI 9 API expects just the MoRef value, not the full type-prefixed ID.

        $clusterId = $clusterObject.ExtensionData.MoRef.Value

        return $clusterId

    } catch [System.UnauthorizedAccessException] {
        Write-LogMessage -Type ERROR -Message "Cannot get cluster id for `"$ClusterName`" on `"$Script:vCenterName`" due to authorization issues: $($_.Exception.Message)"
        throw [VcfDeploymentException]::new("Cannot get cluster id for `"$ClusterName`" on `"$Script:vCenterName`" due to authorization issues: $($_.Exception.Message)")
    }
    catch [System.TimeoutException] {
        Write-LogMessage -Type ERROR -Message "Cannot get cluster id for `"$ClusterName`" on `"$Script:vCenterName`" due to network/timeout issues: $($_.Exception.Message)"
        throw [VcfDeploymentException]::new("Cannot get cluster id for `"$ClusterName`" on `"$Script:vCenterName`" due to network/timeout issues: $($_.Exception.Message)")
    } catch [VcfDeploymentException] {
        throw  # already logged and typed — propagate without re-wrapping
    } catch {
        Write-LogMessage -Type ERROR -Message "Failed to get cluster id for `"$ClusterName`" on `"$Script:vCenterName`": $($_.Exception.Message)"
        throw [VcfDeploymentException]::new("Failed to get cluster id for `"$ClusterName`" on `"$Script:vCenterName`": $($_.Exception.Message)")
    }
}
Function Get-VcenterSupervisorCount {

    <#
        .SYNOPSIS
        Returns the number of vSphere Supervisors (supervisor-enabled clusters) in the connected vCenter.

        .DESCRIPTION
        Queries vCenter via Invoke-ListNamespaceManagementSoftwareClusters (VCF PowerCLI 9) to list all
        supervisor software clusters and returns the count plus optional cluster IDs and names. Use this
        to check how many supervisors are running in a vCenter.

        .PARAMETER IncludeDetails
        If set, the output includes ClusterIds and ClusterNames arrays; otherwise only Count is returned.

        .OUTPUTS
        PSCustomObject with:
        - Count: Number of supervisor-enabled clusters.
        - ClusterIds: (when IncludeDetails) MoRef values of clusters (e.g., "domain-c8").
        - ClusterNames: (when IncludeDetails) Cluster names resolved from vCenter.

        .EXAMPLE
        $result = Get-VcenterSupervisorCount
        Write-Output "Supervisors in vCenter: $($result.Count)"

        .EXAMPLE
        $result = Get-VcenterSupervisorCount -IncludeDetails
        $result.ClusterNames | ForEach-Object { Write-Output $_ }

        .NOTES
        Requires an active connection to vCenter ($Script:vCenterName). Uses Invoke-ListNamespaceManagementSoftwareClusters.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [Switch]$IncludeDetails
    )

    Write-LogMessage -Type DEBUG -Message "Entered Get-VcenterSupervisorCount function..."

    $connectionTest = Test-VcenterConnection
    if (-not $connectionTest.IsConnected) {
        Write-LogMessage -Type ERROR -Message "Not connected to vCenter `"$Script:vCenterName`": $($connectionTest.ErrorMessage)"
        throw [VcfDeploymentException]::new("Not connected to vCenter. Connect first (e.g. Connect-Vcenter), then run Get-VcenterSupervisorCount.")
    }

    try {
        $softwareClusters = Invoke-ListNamespaceManagementSoftwareClusters -ErrorAction Stop
        $count = if ($null -eq $softwareClusters) { 0 } else { @($softwareClusters).Count }

        $result = [PSCustomObject]@{ Count = $count }

        if ($IncludeDetails -and $count -gt 0) {
            $clusterIds = @($softwareClusters | ForEach-Object { $_.Cluster })
            $clusterNames = [System.Collections.ArrayList]::new()
            foreach ($clusterId in $clusterIds) {
                $clusterObj = Get-Cluster -Server $Script:vCenterName -ErrorAction SilentlyContinue | Where-Object { $_.ExtensionData.MoRef.Value -eq $clusterId } | Select-Object -First 1
                $name = if ($clusterObj) { $clusterObj.Name } else { $clusterId }
                [void]$clusterNames.Add($name)
            }
            $result = [PSCustomObject]@{
                Count        = $count
                ClusterIds   = $clusterIds
                ClusterNames = $clusterNames.ToArray()
            }
        }

        return $result
    } catch [VcfDeploymentException] {
        throw  # already logged and typed — propagate without re-wrapping
    } catch {
        Write-LogMessage -Type ERROR -Message "Failed to list supervisors in vCenter `"$Script:vCenterName`": $($_.Exception.Message)"
        throw [VcfDeploymentException]::new("Failed to get supervisor count. Check logs for details.")
    }
}
Function Get-ClusterNameFromPrefix {

    <#
        .SYNOPSIS
        Generates a cluster name from a prefix and edge site identifier.

        .DESCRIPTION
        Combines a cluster name prefix with an edge site identifier using a dash separator
        to create a unique cluster name. Format: prefix-edgeSite

        .PARAMETER ClusterNamePrefix
        The prefix for cluster names (e.g., "cl0").

        .PARAMETER EdgeSite
        The edge site identifier (e.g., "site1").

        .OUTPUTS
        String - The generated cluster name (e.g., "cl0-site1").

        .EXAMPLE
        $clusterName = Get-ClusterNameFromPrefix -ClusterNamePrefix "cl0" -EdgeSite "site1"
        # Returns: "cl0-site1".
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterNamePrefix,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EdgeSite
    )

    return "$ClusterNamePrefix-$EdgeSite"
}
Function Get-DatastoreNameFromPrefix {

    <#
        .SYNOPSIS
        Generates a datastore name from a prefix and edge site identifier.

        .DESCRIPTION
        Combines a datastore name prefix with an edge site identifier using a dash separator
        to create a unique datastore name. Format: prefix-edgeSite

        .PARAMETER DatastoreNamePrefix
        The prefix for datastore names (e.g., "datastore").

        .PARAMETER EdgeSite
        The edge site identifier (e.g., "site1").

        .OUTPUTS
        String - The generated datastore name (e.g., "datastore-site1").

        .EXAMPLE
        $datastoreName = Get-DatastoreNameFromPrefix -DatastoreNamePrefix "datastore" -EdgeSite "site1"
        # Returns: "datastore-site1".
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DatastoreNamePrefix,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EdgeSite
    )

    return "$DatastoreNamePrefix-$EdgeSite"
}
Function Get-VdsNameFromPrefix {

    <#
        .SYNOPSIS
        Generates a VDS name from a prefix and edge site identifier.

        .DESCRIPTION
        Combines a VDS name prefix with an edge site identifier using a dash separator
        to create a unique VDS name. Format: prefix-edgeSite

        .PARAMETER VdsNamePrefix
        The prefix for VDS names (e.g., "VDS").

        .PARAMETER EdgeSite
        The edge site identifier (e.g., "site1").

        .OUTPUTS
        String - The generated VDS name (e.g., "VDS-site1").

        .EXAMPLE
        $vdsName = Get-VdsNameFromPrefix -VdsNamePrefix "VDS" -EdgeSite "site1"
        # Returns: "VDS-site1".
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VdsNamePrefix,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EdgeSite
    )

    return "$VdsNamePrefix-$EdgeSite"
}
Function Get-SupervisorNameFromPrefix {

    <#
        .SYNOPSIS
        Generates a supervisor name from a prefix and edge site identifier.

        .DESCRIPTION
        Combines a supervisor name prefix with an edge site identifier using a dash separator
        to create a unique supervisor name. Natural casing is preserved (e.g. "supervisor-OSA").
        The Kubernetes StorageClass is lowercased separately in New-HarborDataValuesFile; the
        supervisor name, vCenter tags, and storage policies should not be forcibly lowercased.

        .PARAMETER SupervisorNamePrefix
        The prefix for supervisor names (e.g., "supervisor").

        .PARAMETER EdgeSite
        The edge site identifier (e.g., "OSA" or "site1"). Casing is preserved as-is.

        .OUTPUTS
        String - The generated supervisor name (e.g., "supervisor-OSA").

        .EXAMPLE
        $supervisorName = Get-SupervisorNameFromPrefix -SupervisorNamePrefix "supervisor" -EdgeSite "OSA"
        # Returns: "supervisor-OSA"
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorNamePrefix,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EdgeSite
    )

    return "$SupervisorNamePrefix-$EdgeSite"
}
Function Get-PortGroupId {

    <#
        .SYNOPSIS
        Retrieves the unique identifier (ExtensionData.Key) for a vSphere Distributed Switch (VDS) port group.

        .DESCRIPTION
        The function Get-PortGroupId queries the vCenter to find a VDS port group by name and returns its unique identifier.
        This identifier is used for configuring supervisor clusters and other vSphere networking components. The function will
        terminate the script with an error if the port group is not found or if any other error occurs during the lookup.

        .EXAMPLE
        Get-PortGroupId -PortGroupName "management"
        Returns the unique identifier for the "management" port group.

        .EXAMPLE
        $mgmtPortGroupId = Get-PortGroupId -PortGroupName "mgmt-network"
        Stores the port group ID in a variable for later use in supervisor cluster configuration.

        .PARAMETER PortGroupName
        The name of the VDS port group for which to retrieve the unique identifier. This parameter is mandatory.

        .NOTES
        - Requires an active connection to vCenter (uses $Script:vCenterName)
        - Uses Get-VDPortgroup cmdlet from VMware PowerCLI
        - Throws a terminating error if the port group is not found or any error occurs
        - Returns the ExtensionData.Key property which is the unique identifier used by vSphere APIs
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$PortGroupName
    )
    Write-LogMessage -Type DEBUG -Message "Entered Get-PortGroupId function..."

    $connectionTest = Test-VcenterConnection
    if (-not $connectionTest.IsConnected) {
        Write-LogMessage -Type ERROR -Message "Not connected to vCenter `"$Script:vCenterName`": $($connectionTest.ErrorMessage)"
        throw [VcfDeploymentException]::new("Not connected to vCenter `"$Script:vCenterName`": $($connectionTest.ErrorMessage)")
    }

    try {
        # Get VDS Port group ID from name.

        $pgObject = Get-VDPortgroup -Name $PortGroupName -Server $Script:vCenterName -WarningAction SilentlyContinue -ErrorAction Stop
        $pgId = $pgObject.ExtensionData.Key
        return $pgId

    } catch [System.UnauthorizedAccessException] {
        Write-LogMessage -Type ERROR -Message "Cannot get port group id for `"$PortGroupName`" on `"$Script:vCenterName`" due to authorization issues: $($_.Exception.Message)"
        throw [VcfDeploymentException]::new("Cannot get port group id for `"$PortGroupName`" on `"$Script:vCenterName`" due to authorization issues: $($_.Exception.Message)")
    }
    catch [System.TimeoutException] {
        Write-LogMessage -Type ERROR -Message "Cannot get port group id for `"$PortGroupName`" on `"$Script:vCenterName`" due to network/timeout issues: $($_.Exception.Message)"
        throw [VcfDeploymentException]::new("Cannot get port group id for `"$PortGroupName`" on `"$Script:vCenterName`" due to network/timeout issues: $($_.Exception.Message)")
    } catch [VcfDeploymentException] {
        throw  # already logged and typed — propagate without re-wrapping
    } catch {
        Write-LogMessage -Type ERROR -Message "Failed to get port group id for `"$PortGroupName`" on `"$Script:vCenterName`": $($_.Exception.Message)"
        throw [VcfDeploymentException]::new("Failed to get port group id for `"$PortGroupName`" on `"$Script:vCenterName`": $($_.Exception.Message)")
    }
}
Function Set-NewDatastore {

    <#
        .SYNOPSIS
        Creates a new datastore on an ESX host if it doesn't already exist and applies a specified tag.

        .DESCRIPTION
        The Set-NewDatastore function creates a new datastore on the specified ESX host using the provided disk canonical name.
        It first checks if a datastore with the same name already exists on the vCenter to avoid naming conflicts.
        If the datastore exists on the vCenter but not on the specified ESX host, the function will exit with an error
        to prevent conflicts. If the datastore already exists on the specified ESX host, the function will return safely
        and proceed to tag the datastore. If the datastore doesn't exist, it will create a new datastore and wait for it
        to become available with configurable wait times. After successful creation or verification, the function applies
        the specified tag to the datastore for identification and management purposes.

        .EXAMPLE
        Set-NewDatastore -DatastoreName "MyDatastore" -EsxHost "esx01.example.com" -DiskCanonicalName "naa:600508b1001c1234567890abcdef" -TagName "Production"

        This example creates a new VMFS datastore named "MyDatastore" on the ESX host "esx01.example.com" using the specified
        disk canonical name and applies the "Production" tag to the datastore.

        .EXAMPLE
        Set-NewDatastore -DatastoreName "vSAN-Datastore" -EsxHost "esx02.example.com" -DiskCanonicalName "naa:600508b1001c987654321fedcba" -TagName "vSAN-Storage" -TotalWaitTime 180 -CheckInterval 15

        This example creates a datastore with custom wait parameters (3 minutes total, checking every 15 seconds) and tags it
        appropriately for storage management.

        .PARAMETER CheckInterval
        The interval in seconds between checks when waiting for the datastore to become available. Default is 5 seconds.

        .PARAMETER DatastoreName
        The name of the datastore to be created. This name must be unique within the vCenter.

        .PARAMETER DiskCanonicalName
        (Mandatory) The canonical name of the disk device to be used for creating the datastore. This should be in the format
        "naa:xxxxx" or similar device identifier visible to the ESX host.

        .PARAMETER EsxHost
        The name or FQDN of the ESX host where the datastore will be created.

        .PARAMETER TagName
        The name of the tag to be applied to the datastore after creation or verification. This tag is used for identification
        and management purposes within vCenter.

        .PARAMETER TotalWaitTime
        The maximum time in seconds to wait for the datastore to become available after creation. Default is 120 seconds (2 minutes).

        .OUTPUTS
        System.Boolean
        Returns $true if the datastore already existed before this call (nothing was newly created),
        $false if the datastore was created during this call. Callers can use this to skip
        idempotent post-creation work such as vLCM compliance checks.

        .NOTES
        - Requires an active connection to vCenter (uses $Script:vCenterName)
        - Uses New-Datastore and New-TagAssignment cmdlets from VMware PowerCLI
        - Throws a terminating error if any errors occur during datastore creation or tagging
        - Displays progress indicator while waiting for datastore to become available
        - The specified tag must already exist in vCenter before calling this function
        - Handles authorization and timeout exceptions with appropriate error messages
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(1, [int]::MaxValue)] [Int]$CheckInterval=5,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DatastoreName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DiskCanonicalName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EsxHost,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$TagName,
        [Parameter(Mandatory = $false)] [ValidateRange(1, [int]::MaxValue)] [Int]$TotalWaitTime=120
    )

    Write-LogMessage -Type DEBUG -Message "Entered Set-NewDatastore function..."

    $connectionTest = Test-VcenterConnection
    if (-not $connectionTest.IsConnected) {
        Write-LogMessage -Type ERROR -Message "Not connected to vCenter `"$Script:vCenterName`": $($connectionTest.ErrorMessage)"
        throw [VcfDeploymentException]::new("Not connected to vCenter `"$Script:vCenterName`": $($connectionTest.ErrorMessage)")
    }

    $existingDatastore = Get-Datastore -Name $DatastoreName -Server $Script:vCenterName -ErrorAction SilentlyContinue
    $datastoreFoundOnVcenter = ($existingDatastore -and $existingDatastore.State -eq 'Available')
    $datastoreFoundOnEsx = $false  # Initialize variable to avoid undefined variable issues

    if ($datastoreFoundOnVcenter) {
        $conflictingDatastore = $false
        try {
            # Use Get-View to check the datastore's mounted host list, avoiding deprecated VMHost.DatastoreIdList.
            $dsView = Get-View -Id $existingDatastore.Id -Property host -Server $Script:vCenterName -ErrorAction Stop
            if ($dsView.Host) {
                foreach ($mountEntry in $dsView.Host) {
                    $mountedHost = Get-VMHost -Id $mountEntry.Key -Server $Script:vCenterName -ErrorAction SilentlyContinue
                    if ($mountedHost -and $mountedHost.Name -eq $EsxHost) {
                        $datastoreFoundOnEsx = $true
                        break
                    }
                }
            }
            if (-not $datastoreFoundOnEsx) {
                $conflictingDatastore = $true
            }
        }
        catch [System.UnauthorizedAccessException] {
            Write-LogMessage -Type ERROR -Message "Cannot access datastore `"$DatastoreName`" on ESX host `"$EsxHost`" due to authorization issues: $($_.Exception.Message)"
            throw [VcfDeploymentException]::new("Cannot access datastore `"$DatastoreName`" on ESX host `"$EsxHost`" due to authorization issues: $($_.Exception.Message)")
        }
        catch [System.TimeoutException] {
            Write-LogMessage -Type ERROR -Message "Cannot access datastore `"$DatastoreName`" on ESX host `"$EsxHost`" due to network/timeout issues: $($_.Exception.Message)"
            throw [VcfDeploymentException]::new("Cannot access datastore `"$DatastoreName`" on ESX host `"$EsxHost`" due to network/timeout issues: $($_.Exception.Message)")
        } catch [VcfDeploymentException] {
            throw  # already logged and typed — propagate without re-wrapping
        } catch {
            Write-LogMessage -Type ERROR -Message "Error checking datastore `"$DatastoreName`" on ESX host `"$EsxHost`": $($_.Exception.Message)"
            throw [VcfDeploymentException]::new("Error checking datastore `"$DatastoreName`" on ESX host `"$EsxHost`": $($_.Exception.Message)")
        }

        if ($conflictingDatastore) {
            Write-LogMessage -Type ERROR -Message "The datastore `"$DatastoreName`" name is already being used by another server on vCenter `"$Script:vCenterName`". Exiting."
            throw [VcfDeploymentException]::new("The datastore `"$DatastoreName`" name is already being used by another server on vCenter `"$Script:vCenterName`". Exiting.")
        }
    }

    $datastoreAlreadyExisted = $false
    if ($datastoreFoundOnEsx) {
        $datastoreAlreadyExisted = $true
        Write-LogMessage -Type INFO -Message "The datastore `"$DatastoreName`" was already created on ESX host `"$EsxHost`". Proceeding to tag assignment."
        # Still need to tag the existing datastore, so continue to tagging section.

    } else {
        try {
            Write-LogMessage -Type INFO -NoNewline -Message "Creating the new datastore `"$DatastoreName`" on ESX host `"$EsxHost`"... "
            New-Datastore -VMHost $EsxHost -Name $DatastoreName -Path $DiskCanonicalName -Vmfs -Server $Script:vCenterName -ErrorAction Stop | Out-Null

            $elapsedTime = 0
            $maxChecks = $TotalWaitTime / $CheckInterval
            $currentCheck = 0
            $datastoreReady = $false

            do {
                $currentCheck++
                $datastoreState = (Get-Datastore -Name $DatastoreName -Server $Script:vCenterName -ErrorAction SilentlyContinue).State

                if ($datastoreState -eq 'Available') {
                    Write-Progress -Activity "Waiting for Datastore to become Available" -Status "Complete" -Completed
                    $datastoreReady = $true
                    break
                } else {
                    $statusMessage = "Check $currentCheck of $maxChecks - State: $datastoreState"
                    $currentStatus = "Elapsed: $elapsedTime seconds"
                    Write-Progress -Activity "Waiting for Datastore to become Available" -Status $statusMessage -CurrentOperation $currentStatus
                    Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Waiting for datastore `"$DatastoreName`" to settle into a connected state... $elapsedTime seconds elapsed)"
                    Start-Sleep $CheckInterval
                    $elapsedTime += $CheckInterval
                }
            } while ($elapsedTime -lt $TotalWaitTime)

            # Clear progress indicator and check final status.

            Write-Progress -Activity "Waiting for Datastore to become Available" -Status "Complete" -Completed

            if (-not $datastoreReady) {
                Write-LogMessage -Type ERROR -CompletePending -Message " Failed (timeout)."
                throw [VcfDeploymentException]::new(" Failed (timeout).")
            }
            Write-LogMessage -Type INFO -CompletePending -Message " Success"
        } catch [System.UnauthorizedAccessException] {
            Write-LogMessage -Type ERROR -CompletePending -Message " Failed (authorization)."
            throw [VcfDeploymentException]::new(" Failed (authorization).")
        }
        catch [System.TimeoutException] {
            Write-LogMessage -Type ERROR -CompletePending -Message " Failed (timeout)."
            throw [VcfDeploymentException]::new(" Failed (timeout).")
        } catch {
            Write-LogMessage -Type ERROR -CompletePending -Message " Failed."
            throw [VcfDeploymentException]::new(" Failed.")
        }
    }
    try {
        $datastoreObject = Get-Datastore -Name $DatastoreName -Server $Script:vCenterName -ErrorAction SilentlyContinue
    } catch [VcfDeploymentException] {
        throw  # already logged and typed — propagate without re-wrapping
    } catch {
        Write-LogMessage -Type ERROR -Message "Failed to get datastore `"$DatastoreName`" on vCenter `"$Script:vCenterName`": $($_.Exception.Message)"
        throw [VcfDeploymentException]::new("Failed to get datastore `"$DatastoreName`" on vCenter `"$Script:vCenterName`": $($_.Exception.Message)")
    }
    # Tag the datastore.
    try {
        # Check if the tag is already assigned to this datastore.
        $existingTagAssignment = Get-TagAssignment -Entity $datastoreObject -Server $Script:vCenterName -ErrorAction SilentlyContinue | Where-Object { $_.Tag.Name -eq $TagName }
        if ($existingTagAssignment) {
            Write-LogMessage -Type INFO -Message "Datastore `"$DatastoreName`" already has tag `"$TagName`" assigned. Skipping tag assignment."
        } else {
            # Tag is not assigned, try to assign it.
            New-TagAssignment -Tag $TagName -Entity $datastoreObject -Server $Script:vCenterName -ErrorAction Stop | Out-Null
            if ($datastoreAlreadyExisted) {
                Write-LogMessage -Type INFO -Message "Successfully tagged existing datastore `"$DatastoreName`" with tag `"$TagName`"."
            } else {
                Write-LogMessage -Type INFO -Message "Successfully tagged datastore `"$DatastoreName`" with tag `"$TagName`"."
            }
        }
    } catch {
        $errorMessage = $_.Exception.Message

        # Check for cardinality violation errors.
        if ($errorMessage -match "cardinality violation") {
            Write-LogMessage -Type ERROR -Message "Cannot assign tag `"$TagName`" to datastore `"$DatastoreName`" due to a cardinality violation."
            Write-LogMessage -Type ERROR -Message "This error occurs when:"
            Write-LogMessage -Type ERROR -Message "  - The tag has a `"single`" cardinality and is already assigned to another datastore"
            Write-LogMessage -Type ERROR -Message "  - The tag has a `"many`" cardinality but has reached its maximum assignment limit"
            Write-Host ""
            Write-LogMessage -Type ERROR -Message "SOLUTION:"
            Write-LogMessage -Type ERROR -Message "  1. Check the tag category cardinality in vCenter: Menu > Tags & Custom Attributes > Tags"
            Write-LogMessage -Type ERROR -Message "  2. If the tag is `"single`" cardinality, remove it from the other datastore first"
            Write-LogMessage -Type ERROR -Message "  3. If the tag is `"many`" cardinality, check if it has reached its limit"
            Write-LogMessage -Type ERROR -Message "  4. Consider using a different tag or modifying the tag category cardinality."
            throw [VcfDeploymentException]::new("  4. Consider using a different tag or modifying the tag category cardinality.")
        }
        else {
            Write-LogMessage -Type ERROR -Message "Error tagging datastore `"$DatastoreName`" with tag `"$TagName`": $errorMessage"
            throw [VcfDeploymentException]::new("Error tagging datastore `"$DatastoreName`" with tag `"$TagName`": $errorMessage")
        }
    }
    return $datastoreAlreadyExisted
}
#vSAN ESA Storage Pool Helper Functions

# Constants for vSAN ESA operations.
$Script:MinHostDiskRetrievalTimeoutSeconds = 60
$Script:DatastoreRenameVerificationDelaySeconds = 2
$Script:VsanStoragePoolDiskType = "singleTier"
$Script:PowerCliTimeoutBufferSeconds = 60
$Script:MaxPowerCliTimeoutSeconds = 7200
$Script:DatastoreWaitLogIntervalSeconds = 30
$Script:VsanOsaEligibleDisksDelaySeconds = 15
$Script:HaNetworkStabilizationDelaySeconds = 10
$Script:HaPostVsanStabilizationDelaySeconds = 30
Function Group-DisksByHost {
    <#
        .SYNOPSIS
        Groups an array of disk objects by their host name.

        .DESCRIPTION
        Takes an array of disk objects (with VMHostName property) and groups them into a hashtable
        where keys are host names and values are arrays of disk objects for that host.

        .PARAMETER Disks
        Array of disk objects to group. Each disk object must have a VMHostName property.

        .OUTPUTS
        Hashtable. Keys are host names (strings), values are arrays of disk objects.

        .EXAMPLE
        $disksByHost = Group-DisksByHost -Disks $selectedDisks
        foreach ($hostName in $disksByHost.Keys) {
            $hostDisks = $disksByHost[$hostName]
            # Process disks for this host
        }
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Array]$Disks
    )

    $disksByHost = @{}
    foreach ($disk in $Disks) {
        $hostName = $disk.VMHostName
        if (-not $disksByHost.ContainsKey($hostName)) {
            $disksByHost[$hostName] = [System.Collections.ArrayList]::new()
        }
        [void]$disksByHost[$hostName].Add($disk)
    }

    return $disksByHost
}
Function Get-VsanDatastoreForCluster {
    <#
        .SYNOPSIS
        Finds vSAN datastores accessible by hosts in a cluster.

        .DESCRIPTION
        Queries vCenter for vSAN datastores and filters them to return only those accessible
        by at least one host in the specified cluster.

        .PARAMETER ClusterHostIds
        Array of host IDs (from VMHost.Id) that belong to the cluster.

        .OUTPUTS
        Array of Datastore objects that are vSAN type and accessible by cluster hosts.
        Returns empty array if no matching datastores found.

        .EXAMPLE
        $clusterHostIds = $clusterHosts | Select-Object -ExpandProperty Id
        $vsanDatastores = Get-VsanDatastoreForCluster -ClusterHostIds $clusterHostIds
    #>

    [OutputType([System.Object[]])]
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Array]$ClusterHostIds
    )

    # Normalize cluster host IDs by removing "HostSystem-" prefix if present for comparison.
    $normalizedClusterHostIds = $ClusterHostIds | ForEach-Object {
        if ($_ -match "^HostSystem-(.+)$") {
            $matches[1]  # Return the part after "HostSystem-"
        } else {
            $_  # Return as-is if no prefix
        }
    }

    $vsanDatastores = Get-Datastore -Server $Script:vCenterName -ErrorAction SilentlyContinue | Where-Object {
        if ($_.Type -ne "vsan") {
            return $false
        }
        # Check if datastore is accessible by any host in the cluster.
        if ($_.ExtensionData.Host) {
            $hostIds = $_.ExtensionData.Host | Select-Object -ExpandProperty Key | Select-Object -ExpandProperty Value
            if ($hostIds) {
                # Compare normalized host IDs (datastore host IDs are already in "host-XXX" format).
                $intersection = $hostIds | Where-Object { $_ -in $normalizedClusterHostIds }
                return ($intersection.Count -gt 0)
            }
        }
        return $false
    }

    if ($vsanDatastores) {
        return @($vsanDatastores)
    }
    return @()
}
Function Invoke-AsyncPowerShellOperation {

    <#
        .SYNOPSIS
        Executes a PowerShell script block asynchronously with progress monitoring and timeout.

        .DESCRIPTION
        Creates a runspace and executes a script block asynchronously, monitoring progress
        and enforcing a timeout. This helper function eliminates code duplication for async
        operations that need progress indicators.

        .PARAMETER ScriptBlock
        Script block to execute asynchronously. The script block should be a string that will
        be executed in the runspace.

        .PARAMETER Variables
        Hashtable of variable names and values to set in the runspace session state.

        .PARAMETER ActivityName
        Name of the activity for progress indicator display.

        .PARAMETER TimeoutSeconds
        Maximum time in seconds to wait for the operation to complete.

        .PARAMETER CheckInterval
        Interval in seconds between progress checks. Default is 5 seconds.

        .PARAMETER OverallStartTime
        Optional DateTime object representing the overall start time for cumulative timeout calculations.
        If provided, timeout is calculated as remaining time from overall start.

        .PARAMETER MinTimeoutSeconds
        Minimum timeout in seconds to use when calculating remaining timeout from overall start time.
        Default is 60 seconds.

        .PARAMETER RequiredModule
        Name of the PowerShell module to import into the runspace before executing the script block.
        The runspace uses an empty initial session state and does not inherit the caller's loaded modules,
        so the module providing the cmdlets used in ScriptBlock must be explicitly imported. Defaults to
        'VMware.VimAutomation.Storage' (required for Get-VsanEsaEligibleDisk).

        .OUTPUTS
        PSCustomObject with properties:
        - Result: The output from the script block execution (may be $null if operation returns no data)
        - Error: Error message if operation failed, null otherwise
        - Success: Boolean indicating if operation succeeded

        .NOTES
        - When Success is $true but Result is $null, this indicates the operation completed successfully
          but returned no data. This is valid for operations like Get-VsanEsaEligibleDisk when no
          eligible disks are found.
        - The OverallStartTime parameter is useful for cumulative timeout calculations across
          multiple operations (e.g., retrieving disks from multiple hosts).
        - All runspaces and PowerShell instances are properly disposed in finally blocks to prevent
          resource leaks.

        .EXAMPLE
        $result = Invoke-AsyncPowerShellOperation `
            -ScriptBlock "Get-VsanEsaEligibleDisk -VMHost `$vmHost -ErrorAction Stop" `
            -Variables @{ vmHost = $vmHost } `
            -ActivityName "Retrieving vSAN ESA eligible disks" `
            -TimeoutSeconds 900 `
            -CheckInterval 5
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ActivityName,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 60)] [Int]$CheckInterval = 5,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 300)] [Int]$MinTimeoutSeconds = 60,
        [Parameter(Mandatory = $false)] [DateTime]$OverallStartTime,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$RequiredModule = "VMware.VimAutomation.Storage",
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ScriptBlock,
        [Parameter(Mandatory = $true)] [ValidateRange(1, 3600)] [Int]$TimeoutSeconds,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Hashtable]$Variables
    )

    $runspace = [RunspaceFactory]::CreateRunspace()
    $runspace.Open()

    # Import the required module into the runspace. A bare [RunspaceFactory]::CreateRunspace() uses an
    # empty initial session state and does not inherit the parent session's loaded modules. The import
    # adds ~1s to first-use but is negligible relative to the disk retrieval timeout (default 900s).
    $psImport = [PowerShell]::Create()
    $psImport.Runspace = $runspace
    $null = $psImport.AddScript("Import-Module $RequiredModule -ErrorAction Stop").Invoke()
    if ($psImport.HadErrors) {
        $importError = if ($psImport.Streams.Error.Count -gt 0) { $psImport.Streams.Error[0].Exception.Message } else { "unknown error" }
        $psImport.Dispose()
        $runspace.Close()
        $runspace.Dispose()
        Write-LogMessage -Type WARNING -Message "$RequiredModule could not be imported into async runspace: $importError. Falling back to synchronous disk retrieval."
        return [PSCustomObject]@{ Result = $null; Error = "Module import failed in runspace: $importError"; Success = $false }
    }
    $psImport.Dispose()

    $ps = [PowerShell]::Create()
    $ps.Runspace = $runspace
    $ps.AddScript($ScriptBlock) | Out-Null

    $operationStartTime = Get-Date

    try {
        # Set variables in runspace session state.
        foreach ($varName in $Variables.Keys) {
            $runspace.SessionStateProxy.SetVariable($varName, $Variables[$varName])
        }
    } catch {
        $runspace.Close()
        $runspace.Dispose()
        Write-LogMessage -Type ERROR -Message "Failed to set runspace variables: $($_.Exception.Message)"
        return [PSCustomObject]@{
            Result = $null
            Error = "Failed to set runspace variables: $($_.Exception.Message)"
            Success = $false
        }
    }

    Write-LogMessage -Type DEBUG -Message "Starting operation `"$ActivityName`" in runspace (progress and timeout monitored) at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $asyncResult = $ps.BeginInvoke()
    Write-LogMessage -Type DEBUG -Message "Operation `"$ActivityName`" BeginInvoke() returned. IsCompleted: $($asyncResult.IsCompleted)"

    # Monitor progress while operation runs.
    while (-not $asyncResult.IsCompleted) {
        $operationElapsed = [math]::Floor(((Get-Date) - $operationStartTime).TotalSeconds)

        # Calculate timeout: use overall start time if provided, otherwise use simple timeout.
        $remainingTimeout = $TimeoutSeconds
        if ($OverallStartTime) {
            $overallElapsed = [math]::Floor(((Get-Date) - $OverallStartTime).TotalSeconds)
            $remainingTimeout = [math]::Max($MinTimeoutSeconds, $TimeoutSeconds - $overallElapsed)
        }

        if ($operationElapsed -ge $remainingTimeout) {
            try {
                $ps.Stop()
            } catch {
                Write-LogMessage -Type DEBUG -Message "Suppressed when stopping runspace: $($_.Exception.Message)"
            }
            finally {
                $ps.Dispose()
                $runspace.Close()
                $runspace.Dispose()
            }
            Write-Progress -Activity $ActivityName -Status "Timeout" -Completed
            [Console]::Out.Flush()
            $errorMessage = "Operation timed out after $operationElapsed seconds."
            Write-LogMessage -Type ERROR -Message "$ActivityName - $errorMessage"
            return [PSCustomObject]@{
                Result = $null
                Error = $errorMessage
                Success = $false
            }
        }

        $statusMessage = "Elapsed: $operationElapsed seconds..."
        Write-Progress -Activity $ActivityName -Status $statusMessage
        [Console]::Out.Flush()
        Start-Sleep -Seconds $CheckInterval
    }

    # Get results.
    $operationResult = $null
    $operationError = $null
    try {
        $operationResult = $ps.EndInvoke($asyncResult)
        if ($ps.Streams.Error.Count -gt 0) {
            $operationError = $ps.Streams.Error[0].Exception.Message
        }
    } catch {
        $operationError = $_.Exception.Message
    }
    finally {
        $ps.Dispose()
        $runspace.Close()
        $runspace.Dispose()
    }

    if ($operationError) {
        Write-LogMessage -Type ERROR -Message "$ActivityName failed: $operationError"
        return [PSCustomObject]@{
            Result = $null
            Error = $operationError
            Success = $false
        }
    }

    return [PSCustomObject]@{
        Result = $operationResult
        Error = $null
        Success = $true
    }
}
Function Get-VsanEsaEligibleDisksFromCluster {
    <#
        .SYNOPSIS
        Retrieves all vSAN ESA eligible disks from all hosts in a cluster.

        .DESCRIPTION
        Queries each host in the cluster individually for vSAN ESA eligible disks and aggregates
        the results. This is necessary because Get-VsanEsaEligibleDisk may only return disks from
        one host when called with -Cluster parameter.

        .PARAMETER ClusterName
        Name of the cluster to retrieve disks from.

        .PARAMETER ClusterHosts
        Array of VMHost objects in the cluster.

        .PARAMETER TimeoutSeconds
        Maximum time in seconds to wait for disk retrieval from all hosts. Default is 900 seconds.

        .PARAMETER CheckInterval
        Interval in seconds between progress checks. Default is 5 seconds.

        .OUTPUTS
        Array of vSAN ESA eligible disk objects from all hosts in the cluster.

        .EXAMPLE
        $clusterHosts = Get-VMHost -Location $clusterObject -Server $Script:vCenterName
        $eligibleDisks = Get-VsanEsaEligibleDisksFromCluster `
            -ClusterName "MyCluster" `
            -ClusterHosts $clusterHosts `
            -TimeoutSeconds 900 `
            -CheckInterval 5
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(1, 60)] [Int]$CheckInterval = 5,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Array]$ClusterHosts,
        [Parameter(Mandatory = $false)] [ValidateRange(60, 3600)] [Int]$TimeoutSeconds = 900
    )

    Write-LogMessage -Type INFO -Message "Retrieving vSAN ESA eligible disks for cluster `"$ClusterName`" from all hosts..."

    if (-not $ClusterHosts -or $ClusterHosts.Count -eq 0) {
        Write-LogMessage -Type ERROR -Message "Cluster `"$ClusterName`" does not contain any hosts."
        throw [VcfDeploymentException]::new("Cluster `"$ClusterName`" does not contain any hosts.")
    }

    Write-LogMessage -Type DEBUG -Message "Cluster `"$ClusterName`" contains $($ClusterHosts.Count) host(s): $($ClusterHosts.Name -join ', ')"
    Write-LogMessage -Type DEBUG -Message "Retrieving eligible disks from $($ClusterHosts.Count) host(s) in cluster `"$ClusterName`"."

    # Collect eligible disks from all hosts. Force array so a single VMHost is still enumerated once per host.
    $allEligibleDisks = [System.Collections.ArrayList]::new()
    $overallStartTime = Get-Date
    $hostsToQuery = @($ClusterHosts)

    foreach ($vmHost in $hostsToQuery) {
        $hostName = $vmHost.Name
        Write-LogMessage -Type DEBUG -Message "Retrieving vSAN ESA eligible disks from host `"$hostName`"..."

        $scriptBlock = "Get-VsanEsaEligibleDisk -VMHost `$vmHost -ErrorAction Stop"
        $variables = @{ vmHost = $vmHost }
        $activityName = "Retrieving vSAN ESA eligible disks for cluster `"$ClusterName`""

        $result = Invoke-AsyncPowerShellOperation `
            -ActivityName $activityName `
            -CheckInterval $CheckInterval `
            -MinTimeoutSeconds $Script:MinHostDiskRetrievalTimeoutSeconds `
            -OverallStartTime $overallStartTime `
            -ScriptBlock $scriptBlock `
            -TimeoutSeconds $TimeoutSeconds `
            -Variables $variables

        if (-not $result.Success) {
            Write-LogMessage -Type WARNING -Message "Failed to retrieve vSAN ESA eligible disks from host `"$hostName`": $($result.Error). Continuing with other hosts..."
            continue
        }

        # Force array so runspace output of a single object is still enumerated (avoids losing disks when pipeline returns one object).
        $hostEligibleDisks = if ($null -eq $result.Result) { @() } else { @($result.Result) }
        $addedCount = 0
        foreach ($disk in $hostEligibleDisks) {
            if ($null -ne $disk) {
                [void]$allEligibleDisks.Add($disk)
                $addedCount++
            }
        }

        # If async returned no disks, retry synchronously as a safety net. VMware.VimAutomation types may not
        # deserialize correctly across a runspace boundary even when VCF.PowerCLI is imported; this fallback
        # ensures disk retrieval always succeeds even if the async path produces an empty result.
        if ($addedCount -eq 0) {
            try {
                $syncDisks = @(Get-VsanEsaEligibleDisk -VMHost $vmHost -ErrorAction Stop)
                foreach ($disk in $syncDisks) {
                    if ($null -ne $disk) {
                        [void]$allEligibleDisks.Add($disk)
                        $addedCount++
                    }
                }
                if ($addedCount -gt 0) {
                    Write-LogMessage -Type INFO -Message "Async returned no disks from host `"$hostName`" but synchronous Get-VsanEsaEligibleDisk found $addedCount disk(s). Using synchronous result."
                }
            } catch {
                Write-LogMessage -Type DEBUG -Message "Synchronous Get-VsanEsaEligibleDisk fallback for host `"$hostName`" failed: $($_.Exception.Message)."
                # Intentional: use async result (empty); no rethrow so we continue with other hosts.
            }
        }

        if ($addedCount -gt 0) {
            Write-LogMessage -Type DEBUG -Message "Found $addedCount eligible disk(s) from host `"$hostName`"."
        } else {
            Write-LogMessage -Type DEBUG -Message "No eligible disks found on host `"$hostName`"."
        }
    }

    Write-Progress -Activity "Retrieving vSAN ESA eligible disks for cluster `"$ClusterName`"" -Status "Completed" -Completed
    [Console]::Out.Flush()

    $eligibleDisks = $allEligibleDisks.ToArray()

    if (-not $eligibleDisks -or $eligibleDisks.Count -eq 0) {
        # Check if cluster hosts already have vSAN ESA storage pool disks (disks already claimed are not "eligible").
        $existingPoolDiskCountByHost = @{}
        foreach ($vmHost in $hostsToQuery) {
            $poolDisks = @()
            try {
                $poolDisks = @(Get-VsanStoragePoolDisk -VMHost $vmHost -Server $Script:vCenterName -ErrorAction SilentlyContinue)
            } catch {
                Write-LogMessage -Type DEBUG -Message "Get-VsanStoragePoolDisk for host `"$($vmHost.Name)`" failed (used only for error message): $($_.Exception.Message)."
            }
            if ($poolDisks -and $poolDisks.Count -gt 0) {
                $existingPoolDiskCountByHost[$vmHost.Name] = $poolDisks.Count
            }
        }
        if ($existingPoolDiskCountByHost.Count -gt 0) {
            $poolSummary = ($existingPoolDiskCountByHost.GetEnumerator() | ForEach-Object { "`"$($_.Key)`": $($_.Value) disk(s)" } | Sort-Object) -join "; "
            Write-LogMessage -Type ERROR -Message "No vSAN ESA eligible (unclaimed) disks found for cluster `"$ClusterName`". Hosts already have vSAN ESA storage pool disks: $poolSummary. Eligible disks are only unclaimed disks; disks already in a storage pool are not returned by Get-VsanEsaEligibleDisk. If the vSAN datastore exists under a different name, use that name in your configuration or check vCenter for the current datastore name."
            throw [VcfDeploymentException]::new("Deployment failed. No eligible disks; cluster hosts already have vSAN storage pool disks ($poolSummary). Check logs for details.")
        }
        Write-LogMessage -Type ERROR -Message "No vSAN ESA eligible disks found for cluster `"$ClusterName`"."
        throw [VcfDeploymentException]::new("No vSAN ESA eligible disks found for cluster `"$ClusterName`".")
    }

    Write-LogMessage -Type INFO -Message "Found $($eligibleDisks.Count) eligible disk(s) for cluster `"$ClusterName`"."

    # Group disks by host and log host distribution.
    $disksByHost = @{}
    foreach ($disk in $eligibleDisks) {
        $hostName = $disk.VMHost.Name
        if (-not $disksByHost.ContainsKey($hostName)) {
            $disksByHost[$hostName] = 0
        }
        $disksByHost[$hostName]++
    }
    $distributionMessage = ($disksByHost.GetEnumerator() | ForEach-Object { "$($_.Key): $($_.Value) disk(s)" } | Sort-Object) -join ', '
    Write-LogMessage -Type DEBUG -Message "Eligible disks distribution by host: $distributionMessage"

    return $eligibleDisks
}
Function Get-VsanOsaDiskGroupsOnHost {
    <#
        .SYNOPSIS
        Returns whether a host (including a standalone witness) has vSAN OSA disk groups, using the HostVsanSystem API.

        .DESCRIPTION
        Get-VsanDiskGroup only returns disk groups when the host is part of a vSAN cluster. For a standalone
        witness host, use this function instead. It uses Get-View to read HostVsanSystem.config (disk mapping)
        from the vSphere API, which works for any host with vSAN enabled.

        .PARAMETER VMHost
        The VMHost object (e.g. from Get-VMHost) to query.

        .PARAMETER Server
        vCenter server name (default: $Script:vCenterName). Used for Get-View.

        .OUTPUTS
        PSCustomObject with:
        - HasValidOsaGroup: True if the host has at least one OSA disk group with cache and at least one capacity disk.
        - DiskGroupCount: Number of disk groups found on the host (from config).

        .EXAMPLE
        $result = Get-VsanOsaDiskGroupsOnHost -VMHost $witnessHost -Server $Script:vCenterName
        if ($result.HasValidOsaGroup) { Write-Output "Witness already has OSA disk group." }

        .NOTES
        A single witness host may be used for many clusters; the workflow is not always creating the storage group.
        Uses HostVsanSystem.config (VsanHostConfigInfo). StorageInfo.DiskMapping or Config.diskMapping
        is traversed; each mapping with ssd (cache) and nonSsd (capacity) counts as a valid OSA disk group.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] $VMHost,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$Server = $Script:vCenterName
    )

    $hasValidOsaGroup = $false
    $diskGroupCount = 0

    try {
        $hostView = Get-View -Id $VMHost.Id -Server $Server -Property ConfigManager -ErrorAction Stop
        $vsanSystemRef = $hostView.ConfigManager.VsanSystem
        if (-not $vsanSystemRef) {
            Write-LogMessage -Type DEBUG -Message "Host `"$($VMHost.Name)`" has no VsanSystem; no OSA disk groups."
            return [PSCustomObject]@{ HasValidOsaGroup = $false; DiskGroupCount = 0 }
        }
        $vsanSystemView = Get-View -Id $vsanSystemRef -Server $Server -Property Config -ErrorAction Stop
        $config = $vsanSystemView.Config
        if (-not $config) {
            Write-LogMessage -Type DEBUG -Message "Host `"$($VMHost.Name)`" VsanSystem has no Config; no OSA disk groups."
            return [PSCustomObject]@{ HasValidOsaGroup = $false; DiskGroupCount = 0 }
        }
        # VsanHostConfigInfo: disk mappings may be under config.StorageInfo.diskMapping or config.diskMapping (API version dependent; casing may vary).
        $mappings = $null
        $storageInfo = if ($config.PSObject.Properties['StorageInfo']) { $config.StorageInfo } elseif ($config.PSObject.Properties['storageInfo']) { $config.storageInfo } else { $null }
        if ($storageInfo -and $storageInfo.PSObject.Properties['diskMapping']) {
            $mappings = $storageInfo.diskMapping
        } elseif ($storageInfo -and $storageInfo.PSObject.Properties['DiskMapping']) {
            $mappings = $storageInfo.DiskMapping
        } elseif ($config.PSObject.Properties['diskMapping']) {
            $mappings = $config.diskMapping
        } elseif ($config.PSObject.Properties['DiskMapping']) {
            $mappings = $config.DiskMapping
        }
        if (-not $mappings) {
            Write-LogMessage -Type DEBUG -Message "Host `"$($VMHost.Name)`" VsanSystem config has no disk mappings; no OSA disk groups."
            return [PSCustomObject]@{ HasValidOsaGroup = $false; DiskGroupCount = 0 }
        }
        $mappingArray = @($mappings)
        $diskGroupCount = $mappingArray.Count
        foreach ($mapping in $mappingArray) {
            if (-not $mapping) { continue }
            $hasCache = $false
            $capacityCount = 0
            $cacheDiskRef = if ($mapping.PSObject.Properties['ssd']) { $mapping.ssd } elseif ($mapping.PSObject.Properties['Ssd']) { $mapping.Ssd } else { $null }
            if ($null -ne $cacheDiskRef) {
                $hasCache = $true
            }
            $capacityDisksRef = if ($mapping.PSObject.Properties['nonSsd']) { $mapping.nonSsd } elseif ($mapping.PSObject.Properties['NonSsd']) { $mapping.NonSsd } else { $null }
            if ($capacityDisksRef) {
                $capacityCount = @($capacityDisksRef).Count
            }
            if ($hasCache -and $capacityCount -ge 1) {
                $hasValidOsaGroup = $true
                Write-LogMessage -Type DEBUG -Message "Host `"$($VMHost.Name)`" has at least one OSA disk group with cache and capacity (from HostVsanSystem.config)."
                break
            }
        }
        if (-not $hasValidOsaGroup -and $diskGroupCount -gt 0) {
            Write-LogMessage -Type DEBUG -Message "Host `"$($VMHost.Name)`" has $diskGroupCount disk mapping(s) but none with both cache and capacity."
        }
    } catch {
        Write-LogMessage -Type DEBUG -Message "Get-VsanOsaDiskGroupsOnHost failed for `"$($VMHost.Name)`": $($_.Exception.Message). Treating as no disk groups."
        $diskGroupCount = 0
    }

    # Fallback for standalone witness: HostVsanSystem.config may not expose disk mappings when the host is not in a cluster; use esxcli vsan storage list to detect existing OSA disk groups.
    if (-not $hasValidOsaGroup -and $diskGroupCount -eq 0) {
        $presentViaEsxcli = Test-VsanOsaDiskGroupPresentViaEsxcli -VMHost $VMHost -Server $Server
        if ($presentViaEsxcli) {
            $hasValidOsaGroup = $true
            $diskGroupCount = 1
            Write-LogMessage -Type DEBUG -Message "Host `"$($VMHost.Name)`" has vSAN OSA disk group(s) per esxcli vsan storage list (HostVsanSystem had no mappings)."
        }
    }

    return [PSCustomObject]@{ HasValidOsaGroup = $hasValidOsaGroup; DiskGroupCount = $diskGroupCount }
}
Function Test-VsanOsaDiskGroupPresentViaEsxcli {
    <#
        .SYNOPSIS
        Detects whether a host has vSAN disks in a disk group using esxcli vsan storage list (fallback when HostVsanSystem.config has no mappings).

        .DESCRIPTION
        Get-VsanOsaDiskGroupsOnHost uses HostVsanSystem.config, which may be empty for a standalone witness. This function runs
        esxcli vsan storage list on the host and returns True if any disk is reported as part of a vSAN disk group (has a non-empty
        VSAN Disk Group UUID). Used so the script skips creating a disk group when one already exists.

        .PARAMETER VMHost
        The VMHost object to query.

        .PARAMETER Server
        vCenter server name (default: $Script:vCenterName). Used for Get-EsxCli.

        .OUTPUTS
        Boolean. True if at least one disk on the host is in a vSAN disk group; otherwise False (including when esxcli is unavailable or fails).

        .NOTES
        A single witness may be used for many clusters; we skip creating the disk group when one already exists.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] $VMHost,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$Server = $Script:vCenterName
    )

    try {
        $esxcli = Get-EsxCli -VMHost $VMHost -V2 -Server $Server -ErrorAction Stop
        $listCmd = $esxcli.vsan.storage.list
        if (-not $listCmd) {
            return $false
        }
        $result = $listCmd.Invoke()
        if (-not $result) {
            return $false
        }
        $items = @($result)
        foreach ($item in $items) {
            $uuid = $null
            if ($item.PSObject.Properties['VsanDiskGroupUuid']) { $uuid = $item.VsanDiskGroupUuid }
            elseif ($item.PSObject.Properties['vsanDiskGroupUuid']) { $uuid = $item.vsanDiskGroupUuid }
            elseif ($item.PSObject.Properties['VSANDiskGroupUUID']) { $uuid = $item.VSANDiskGroupUUID }
            if (-not [String]::IsNullOrWhiteSpace([string]$uuid)) {
                return $true
            }
        }
        # Fallback: parse CLI-style text (e.g. "VSAN Disk Group UUID: 527f4fe8-...").
        $resultStr = $result | Out-String
        if ($resultStr -match 'VSAN\s+Disk\s+Group\s+UUID:\s*\S+') {
            return $true
        }
    } catch {
        Write-LogMessage -Type DEBUG -Message "Test-VsanOsaDiskGroupPresentViaEsxcli failed for `"$($VMHost.Name)`": $($_.Exception.Message)."
    }
    return $false
}
Function Get-VsanOsaEligibleDisksFromCluster {
    <#
        .SYNOPSIS
        Retrieves all vSAN OSA (Original Storage Architecture) eligible disks from all hosts in a cluster.

        .DESCRIPTION
        Queries each host in the cluster individually for vSAN eligible disks via the vSphere API
        (HostVsanSystem.QueryDisksForVsan) and aggregates the results. Disks are used for OSA disk
        groups (cache SSD + capacity). Each disk object includes VMHost reference; cache vs capacity
        is determined by SSD vs non-SSD (IsSsd).

        .PARAMETER ClusterName
        Name of the cluster to retrieve disks from.

        .PARAMETER ClusterHosts
        Array of VMHost objects in the cluster.

        .OUTPUTS
        Array of PSCustomObject disk objects from all hosts with VMHost, CanonicalName, CapacityGB,
        Model, and IsSsd (for OSA disk groups).

        .EXAMPLE
        $clusterHosts = Get-VMHost -Location $clusterObject -Server $Script:vCenterName
        $eligibleDisks = Get-VsanOsaEligibleDisksFromCluster -ClusterName "MyCluster" -ClusterHosts $clusterHosts

        .NOTES
        Uses Get-View and HostVsanSystem.QueryDisksForVsan() per host (vSphere API). Get-VsanEligibleDisk
        is not available in VCF PowerCLI 9; this API-based approach is compatible with all supported versions.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Array]$ClusterHosts
    )

    $hostCount = if ($ClusterHosts) { @($ClusterHosts).Count } else { 0 }
    if ($hostCount -eq 1) {
        Write-LogMessage -Type INFO -Message "Retrieving vSAN OSA eligible disks for cluster `"$ClusterName`" from 1 host (witness or single host): $($ClusterHosts.Name)."
    } else {
        Write-LogMessage -Type INFO -Message "Retrieving vSAN OSA eligible disks for cluster `"$ClusterName`" from all hosts..."
    }

    if (-not $ClusterHosts -or $hostCount -eq 0) {
        Write-LogMessage -Type ERROR -Message "Cluster `"$ClusterName`" does not contain any hosts."
        throw [VcfDeploymentException]::new("Cluster `"$ClusterName`" does not contain any hosts.")
    }

    Write-LogMessage -Type DEBUG -Message "Cluster `"$ClusterName`" contains $($ClusterHosts.Count) host(s): $($ClusterHosts.Name -join ', ')"
    Write-LogMessage -Type DEBUG -Message "Retrieving eligible disks from $($ClusterHosts.Count) host(s) in cluster `"$ClusterName`" (HostVsanSystem.QueryDisksForVsan)."

    # Collect eligible disks from each host via HostVsanSystem.QueryDisksForVsan (vSphere API).
    $allEligibleDisks = [System.Collections.ArrayList]::new()
    $hostsToQuery = @($ClusterHosts)

    foreach ($vmHost in $hostsToQuery) {
        $hostName = $vmHost.Name
        Write-LogMessage -Type DEBUG -Message "Retrieving vSAN OSA eligible disks from host `"$hostName`"..."

        try {
            $hostView = Get-View -Id $vmHost.Id -Server $Script:vCenterName -Property ConfigManager -ErrorAction Stop
            $vsanSystemRef = $hostView.ConfigManager.VsanSystem
            if (-not $vsanSystemRef) {
                Write-LogMessage -Type WARNING -Message "Host `"$hostName`" has no VsanSystem. Skipping."
                continue
            }
            $vsanSystem = Get-View -Id $vsanSystemRef -Server $Script:vCenterName -ErrorAction Stop
            # QueryDisksForVsan(optional canonicalName[]) returns items with .state and .disk; pass $null to query all disks.
            $diskResults = $vsanSystem.QueryDisksForVsan($null)
        } catch {
            Write-LogMessage -Type WARNING -Message "Failed to retrieve vSAN OSA eligible disks from host `"$hostName`": $($_.Exception.Message). Continuing with other hosts..."
            continue
        }

        if (-not $diskResults) {
            Write-LogMessage -Type DEBUG -Message "No disk results from host `"$hostName`"."
            continue
        }

        # Each result item has .state ("eligible" etc.) and .disk (capacity, canonicalName, model, ssd).
        $eligibleCountThisHost = 0
        $rawStatesThisHost = [System.Collections.ArrayList]::new()
        # Log every disk and its state from QueryDisksForVsan so we can see why some disks (e.g. boot) are not eligible.
        foreach ($resultItem in $diskResults) {
            $state = if ($null -ne $resultItem -and $resultItem.PSObject.Properties['state']) { $resultItem.state } else { "(no state)" }
            $canonical = if ($resultItem -and $resultItem.disk -and $resultItem.disk.canonicalName) { $resultItem.disk.canonicalName } else { "(no canonical)" }
            Write-LogMessage -Type DEBUG -Message "QueryDisksForVsan host `"$hostName`" disk $canonical state=$state."
            if ($null -ne $resultItem -and $resultItem.PSObject.Properties['state']) {
                [void]$rawStatesThisHost.Add($resultItem.state)
            }
            if ($null -eq $resultItem -or $resultItem.state -ne "eligible") {
                continue
            }
            $rawDisk = $resultItem.disk
            if (-not $rawDisk -or -not $rawDisk.canonicalName) {
                continue
            }
            $capacityBytes = 0
            if ($rawDisk.capacity -and $rawDisk.capacity.block -and $rawDisk.capacity.blockSize) {
                $capacityBytes = $rawDisk.capacity.block * $rawDisk.capacity.blockSize
            }
            $capacityGB = [math]::Round($capacityBytes / 1GB, 2)
            $model = if ($rawDisk.model) { $rawDisk.model } else { "" }
            if ($rawDisk.vendor -and $model) {
                $model = "$($rawDisk.vendor) $model"
            } elseif ($rawDisk.vendor) {
                $model = $rawDisk.vendor
            }
            $isSsd = $false
            if ($null -ne $rawDisk.PSObject.Properties['ssd'] -and $rawDisk.ssd -eq $true) {
                $isSsd = $true
            }
            $eligibleDiskObject = [PSCustomObject]@{
                VMHost       = $vmHost
                CanonicalName = $rawDisk.canonicalName
                CapacityGB   = $capacityGB
                Model        = $model
                IsSsd        = $isSsd
            }
            [void]$allEligibleDisks.Add($eligibleDiskObject)
            $eligibleCountThisHost++
        }
        if ($eligibleCountThisHost -gt 0) {
            Write-LogMessage -Type DEBUG -Message "Found $eligibleCountThisHost eligible disk(s) from host `"$hostName`"."
        } else {
            $rawCount = if ($diskResults) { @($diskResults).Count } else { 0 }
            $statesSummary = if ($rawStatesThisHost.Count -gt 0) { ($rawStatesThisHost | Sort-Object) -join ", " } else { "(none)" }
            Write-LogMessage -Type DEBUG -Message "No eligible disks found on host `"$hostName`". QueryDisksForVsan returned $rawCount raw item(s); state(s): $statesSummary."
        }
    }

    $eligibleDisks = $allEligibleDisks.ToArray()

    if (-not $eligibleDisks -or $eligibleDisks.Count -eq 0) {
        $queriedHostNames = ($hostsToQuery | ForEach-Object { $_.Name }) -join ", "
        $queriedHostIds = ($hostsToQuery | ForEach-Object { $_.Id }) -join "; "
        Write-LogMessage -Type DEBUG -Message "Get-VsanOsaEligibleDisksFromCluster: total eligible disks=0. Queried host(s): $queriedHostNames. Host Id(s): $queriedHostIds."
        $errorDetail = "No vSAN OSA eligible disks found for cluster `"$ClusterName`" (queried host(s): $queriedHostNames)."
        if ($hostsToQuery.Count -eq 1) {
            $errorDetail += " The host may have no local disks, or disks may already be in use (e.g. in a disk group or VMFS). For a vSAN witness host, ensure it has at least one SSD for cache and at least one disk for capacity (capacity can be HDD or SSD)."
        }
        Write-LogMessage -Type ERROR -Message $errorDetail
        throw $errorDetail
    }

    Write-LogMessage -Type INFO -Message "Found $($eligibleDisks.Count) eligible disk(s) for cluster `"$ClusterName`"."

    # Log distribution by host for diagnostics.
    $disksByHost = @{}
    foreach ($disk in $eligibleDisks) {
        $diskHostName = $disk.VMHost.Name
        if (-not $disksByHost.ContainsKey($diskHostName)) {
            $disksByHost[$diskHostName] = 0
        }
        $disksByHost[$diskHostName]++
    }
    $distributionMessage = ($disksByHost.GetEnumerator() | ForEach-Object { "$($_.Key): $($_.Value) disk(s)" } | Sort-Object) -join ', '
    Write-LogMessage -Type DEBUG -Message "Eligible disks distribution by host: $distributionMessage"

    foreach ($vmHost in $hostsToQuery) {
        $hName = $vmHost.Name
        $countForHost = if ($disksByHost.ContainsKey($hName)) { $disksByHost[$hName] } else { 0 }
        if ($hostCount -ge 2 -and $countForHost -eq 0) {
            Write-LogMessage -Type WARNING -Message "Host `"$hName`" contributed 0 eligible disks. vSAN may not be ready on that host yet, or the host has no unused disks (e.g. all in use or not visible to vSAN). Check vSAN VMkernel connectivity and disk availability."
        }
    }

    foreach ($diskHostName in ($disksByHost.Keys | Sort-Object)) {
        $disksForHost = @($eligibleDisks | Where-Object { $_.VMHost.Name -eq $diskHostName })
        $orderStr = ($disksForHost | ForEach-Object { "$($_.CanonicalName)/$($_.CapacityGB)/IsSsd=$($_.IsSsd)" }) -join ", "
        Write-LogMessage -Type DEBUG -Message "Get-VsanOsaEligibleDisksFromCluster: host `"$diskHostName`" API return order: $orderStr"
    }

    return $eligibleDisks
}
Function Get-UserDiskSelection {
    <#
        .SYNOPSIS
        Displays eligible disks to the user and collects their selection.

        .DESCRIPTION
        Creates display objects for eligible disks with IDs, displays them in a formatted table,
        and allows the user to de-select specific disks. By default, all disks are selected.

        .PARAMETER ClusterName
        Name of the cluster (for display purposes).

        .PARAMETER EligibleDisks
        Array of vSAN eligible disk objects to display and select from.

        .PARAMETER StorageType
        Type of vSAN storage architecture: "ESA" (Express Storage Architecture) or "OSA" (Original Storage Architecture).
        Default is "ESA". This parameter is used in display messages to indicate the storage type.

        .OUTPUTS
        PSCustomObject with properties:
        - SelectedDisks: Array of disk display objects that were selected
        - ExcludedDisks: Array of disk display objects that were excluded
        - DisksWereDeselected: Boolean indicating if user actively deselected any disks
        - DiskDisplayList: Array of all disk display objects with IDs

        .EXAMPLE
        $selection = Get-UserDiskSelection -ClusterName "MyCluster" -EligibleDisks $eligibleDisks -StorageType "ESA"
        $selectedDisks = $selection.SelectedDisks
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Array]$EligibleDisks,
        [Parameter(Mandatory = $false)] [ValidateSet("ESA", "OSA")] [String]$StorageType = "ESA"
    )

    # Create display objects with IDs.
    $diskDisplayList = [System.Collections.ArrayList]::new()
    $diskIdCounter = 1

    foreach ($disk in $EligibleDisks) {
        $hostName = $disk.VMHost.Name

        $diskDisplayObject = [PSCustomObject]@{
            Id = $diskIdCounter
            VMHostName = $hostName
            CanonicalName = $disk.CanonicalName
            CapacityGB = $disk.CapacityGB
            Model = $disk.Model
            DiskObject = $disk
        }

        [void]$diskDisplayList.Add($diskDisplayObject)
        $diskIdCounter++
    }

    # Display all disks in a single table.
    Write-Host ""
    Write-Output "vSAN $StorageType Eligible Disks for cluster `"$ClusterName`":"
    $tableOutput = $diskDisplayList | Format-Table -Property Id, VMHostName, CanonicalName, CapacityGB, Model -AutoSize | Out-String
    # Remove trailing newlines from Out-String, then write table.
    $tableOutput = $tableOutput.TrimEnd()
    # Table and blank line use Write-Host so interactive table renders correctly; Write-Output can introduce regression.
    Write-Host $tableOutput
    Write-Host ""

    # By default, select all disks.
    $selectedDiskIds = 1..$diskDisplayList.Count
    $disksWereDeselected = $false

    # Ask user if they want to de-select any disks.
    # Remove colon from prompt message as Read-Host adds it automatically.
    $deselectPrompt = "Would you like to de-select any disks? (Y/N, default: N)"
    $deselectResponse = Read-Host $deselectPrompt
    Write-Host ""

    if ($deselectResponse -eq "Y" -or $deselectResponse -eq "y") {
        Write-Host ""
        Write-Output "Enter the IDs of disks to de-select (comma-separated, e.g., 1,3,5) or 'C' to cancel:"
        $deselectInput = Read-Host "Disk IDs to de-select"

        if ($deselectInput -eq "C" -or $deselectInput -eq "c") {
            Write-LogMessage -Type INFO -Message "User cancelled disk selection workflow."
            throw "Deployment cancelled by user."
        }

        # Parse the input and remove selected IDs from the default selection.
        $idsToDeselect = [System.Collections.ArrayList]::new()
        if ($deselectInput -and $deselectInput.Trim()) {
            $inputParts = $deselectInput -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ }
            foreach ($part in $inputParts) {
                $parsedId = 0
                if ([int]::TryParse($part, [ref]$parsedId)) {
                    [void]$idsToDeselect.Add($parsedId)
                }
                else {
                    Write-LogMessage -Type ERROR -Message "Invalid disk ID format: `"$part`". Expected numeric value."
                    throw [VcfDeploymentException]::new("Invalid disk ID format: `"$part`". Expected numeric value.")
                }
            }
        }

        # Validate IDs are within range.
        $idsToDeselectArray = $idsToDeselect.ToArray()
        $invalidIds = $idsToDeselectArray | Where-Object { $_ -lt 1 -or $_ -gt $diskDisplayList.Count }
        if ($invalidIds) {
            Write-LogMessage -Type ERROR -Message "Invalid disk ID(s) provided: $($invalidIds -join ', '). Valid range is 1-$($diskDisplayList.Count)."
            throw [VcfDeploymentException]::new("Invalid disk ID(s) provided: $($invalidIds -join ', '). Valid range is 1-$($diskDisplayList.Count).")
        }

        # Remove deselected IDs from the selected list.
        $selectedDiskIds = $selectedDiskIds | Where-Object { $idsToDeselectArray -notcontains $_ }

        if ($selectedDiskIds.Count -eq 0) {
            Write-LogMessage -Type ERROR -Message "No disks selected. At least one disk must be selected."
            throw [VcfDeploymentException]::new("No disks selected. At least one disk must be selected.")
        }

        $disksWereDeselected = $true
        Write-Host ""
        Write-LogMessage -Type INFO -Message "User de-selected disk ID(s): $($idsToDeselectArray -join ', '). $($selectedDiskIds.Count) disk(s) remain selected."
    }

    # Get selected and excluded disk objects.
    $selectedDisks = $diskDisplayList | Where-Object { $selectedDiskIds -contains $_.Id }
    $excludedDisks = $diskDisplayList | Where-Object { $selectedDiskIds -notcontains $_.Id }

    # Display summary only if disks were deselected, otherwise show simple confirmation.
    if ($disksWereDeselected) {
        # Display summary tables for included and excluded disks.
        Write-Host ""
        Write-Output "Disk Selection Summary:"
        Write-Host ""

        # Display included disks table.
        Write-Output "Included Disks:"
        if ($selectedDisks.Count -gt 0) {
            $selectedDisks | Format-Table -Property Id, VMHostName, CanonicalName, CapacityGB, Model -AutoSize
        } else {
            Write-Output "  (No disks included)"
        }
        Write-Host ""

        # Display excluded disks table.
        Write-Output "Excluded Disks:"
        if ($excludedDisks.Count -gt 0) {
            $excludedDisks | Format-Table -Property Id, VMHostName, CanonicalName, CapacityGB, Model -AutoSize
        } else {
            Write-Output "  (No disks excluded)"
        }
        Write-Host ""
    } else {
        # Simple confirmation when all disks are selected.
        Write-LogMessage -Type INFO -Message "All $($diskDisplayList.Count) disk(s) will be added to vSAN $StorageType storage pools."
    }

    # Log included and excluded disks to debug log.
    Write-LogMessage -Type DEBUG -Message "Included disks ($($selectedDisks.Count) total):"
    foreach ($disk in $selectedDisks) {
        Write-LogMessage -Type DEBUG -Message "  - ID $($disk.Id): Host=$($disk.VMHostName), CanonicalName=$($disk.CanonicalName), CapacityGB=$($disk.CapacityGB), Model=$($disk.Model)"
    }

    if ($excludedDisks.Count -gt 0) {
        Write-LogMessage -Type DEBUG -Message "Excluded disks ($($excludedDisks.Count) total):"
        foreach ($disk in $excludedDisks) {
            Write-LogMessage -Type DEBUG -Message "  - ID $($disk.Id): Host=$($disk.VMHostName), CanonicalName=$($disk.CanonicalName), CapacityGB=$($disk.CapacityGB), Model=$($disk.Model)"
        }
    }
    else {
        Write-LogMessage -Type DEBUG -Message "No disks excluded - all disks are included."
    }

    # Validate that at least one disk is selected before proceeding.
    if ($selectedDisks.Count -eq 0) {
        Write-LogMessage -Type ERROR -Message "No disks selected for vSAN $StorageType storage pool. At least one disk must be selected to create a vSAN datastore."
        throw [VcfDeploymentException]::new("No disks selected for vSAN $StorageType storage pool. At least one disk must be selected to create a vSAN datastore.")
    }

    return [PSCustomObject]@{
        SelectedDisks = $selectedDisks
        ExcludedDisks = $excludedDisks
        DisksWereDeselected = $disksWereDeselected
        DiskDisplayList = $diskDisplayList.ToArray()
    }
}
Function Add-VsanOsaDiskToDiskGroup {
    <#
        .SYNOPSIS
        Creates vSAN OSA disk groups on each host using the selected cache and capacity disks.

        .DESCRIPTION
        Takes a hashtable of per-host cache and capacity disk selections (built automatically:
        smallest SSD per host = cache, rest = capacity) and runs New-VsanDiskGroup on each host.

        .PARAMETER SelectionByHost
        Hashtable where keys are host names and values are PSCustomObject with CacheDisk (single disk
        display object) and CapacityDisks (array of disk display objects). Each has CanonicalName.

        .PARAMETER TimeoutSeconds
        Maximum time in seconds to wait for disk group creation per host. Default is 1800. If operations
        time out, consider increasing WebOperationTimeoutSeconds via Set-PowerCLIConfiguration.

        .EXAMPLE
        Add-VsanOsaDiskGroupToCluster -ClusterName "MyCluster" -DatastoreName "datastore-site1"

        .NOTES
        Uses New-VsanDiskGroup (VCF PowerCLI). Each host must have at least one cache (SSD) and one
        or more capacity disks. Logs and errors use Get-CleanVsanErrorMessage for user-facing output.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Hashtable]$SelectionByHost,
        [Parameter(Mandatory = $false)] [ValidateRange(60, 3600)] [Int]$TimeoutSeconds = 1800
    )

    foreach ($hostName in ($SelectionByHost.Keys | Sort-Object)) {
        $hostSelection = $SelectionByHost[$hostName]
        $cacheDisk = $hostSelection.CacheDisk
        $capacityDisks = $hostSelection.CapacityDisks
        if (-not $cacheDisk) {
            Write-LogMessage -Type ERROR -Message "No cache disk defined for host `"$hostName`"."
            throw [VcfDeploymentException]::new("No cache disk defined for host `"$hostName`".")
        }
        $capacityCanonicalNames = @()
        if ($capacityDisks -and $capacityDisks.Count -gt 0) {
            $capacityCanonicalNames = $capacityDisks | ForEach-Object { $_.CanonicalName }
        }
        Write-LogMessage -Type INFO -Message "Creating vSAN OSA disk group on host `"$hostName`" (1 cache, $($capacityCanonicalNames.Count) capacity disk(s))."

        try {
            $vmHostObject = Get-VMHost -Name $hostName -Server $Script:vCenterName -ErrorAction Stop
            Write-LogMessage -Type DEBUG -Message "Retrieved VMHost object for `"$hostName`". Starting New-VsanDiskGroup at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')..."

            $operationStartTime = Get-Date
            try {
                if ($capacityCanonicalNames.Count -eq 0) {
                    Write-LogMessage -Type ERROR -Message "At least one capacity disk is required per host for vSAN OSA disk group on `"$hostName`"."
                    throw [VcfDeploymentException]::new("At least one capacity disk is required per host for vSAN OSA disk group on `"$hostName`".")
                }
                # Pass as array so cmdlet receives string[] and does not enumerate a single string as characters (avoids "Sequence contains no elements").
                $dataDiskArray = @($capacityCanonicalNames)
                New-VsanDiskGroup -VMHost $vmHostObject -SsdCanonicalName $cacheDisk.CanonicalName -DataDiskCanonicalName $dataDiskArray -ErrorAction Stop | Out-Null

                $operationEndTime = Get-Date
                $operationDuration = [math]::Round(($operationEndTime - $operationStartTime).TotalSeconds, 2)
                Write-LogMessage -Type DEBUG -Message "New-VsanDiskGroup completed for host `"$hostName`" after $operationDuration seconds."
                Write-LogMessage -Type INFO -Message "Successfully created vSAN OSA disk group on host `"$hostName`"."
            } catch {
                $operationEndTime = Get-Date
                $operationDuration = [math]::Round(($operationEndTime - $operationStartTime).TotalSeconds, 2)
                Write-LogMessage -Type DEBUG -Message "New-VsanDiskGroup failed for host `"$hostName`" after $operationDuration seconds."

                $errMsg = $_.Exception.Message
                if ($_.Exception.InnerException) { $errMsg = $_.Exception.InnerException.Message }
                switch -Regex ($errMsg) {
                    "request channel timed out|SendTimeout|00:05:00" {
                        $recommendedTimeout = [Math]::Min($TimeoutSeconds + $Script:PowerCliTimeoutBufferSeconds, $Script:MaxPowerCliTimeoutSeconds)
                        Write-LogMessage -Type ERROR -Message "Disk group creation failed due to PowerCLI web operation timeout."
                        Write-LogMessage -Type ERROR -Message "Consider running: Set-PowerCLIConfiguration -WebOperationTimeoutSeconds $recommendedTimeout -Scope Session"
                        Write-LogMessage -Type ERROR -Message "Then re-run the deployment. Failed for host `"$hostName`": $errMsg"
                        break
                    }
                    "Sequence contains no elements" {
                        Write-LogMessage -Type ERROR -Message "Failed to create vSAN OSA disk group on host `"$hostName`": one or more disks could not be resolved (cache: $($cacheDisk.CanonicalName), capacity: $($capacityCanonicalNames -join ', ')). Verify canonical names on the host and that disks are not in use."
                        break
                    }
                    default {
                        Write-LogMessage -Type ERROR -Message "Failed to create vSAN OSA disk group on host `"$hostName`": $errMsg"
                    }
                }
                throw "Failed to create vSAN OSA disk group on host `"$hostName`": $errMsg. Check logs for details."
            }
        } catch [VcfDeploymentException] {
            throw  # already logged and typed — propagate without re-wrapping
        } catch {
            Write-LogMessage -Type ERROR -Message "Failed to create vSAN OSA disk group on host `"$hostName`": $($_.Exception.Message)"
            throw [VcfDeploymentException]::new("Failed to create vSAN OSA disk group on host `"$hostName`": $($_.Exception.Message)")
        }
    }
}
Function Add-VsanEsaDiskToStoragePool {
    <#
        .SYNOPSIS
        Adds selected disks to vSAN ESA storage pools for each host.

        .DESCRIPTION
        Takes a hashtable of disks grouped by host and adds them to vSAN ESA storage pools
        using Add-VsanStoragePoolDisk. Each host is processed sequentially with progress monitoring.

        .PARAMETER ClaimRetryDelaySeconds
        Delay between retries when Add-VsanStoragePoolDisk fails with a transient host or object state error. Default is 15.

        .PARAMETER ClaimRetryMaxAttempts
        Maximum attempts per host for Add-VsanStoragePoolDisk when the server returns a retryable invalid-state error. Default is 4.

        .PARAMETER DisksByHost
        Hashtable where keys are host names and values are arrays of disk display objects.

        .PARAMETER TimeoutSeconds
        Maximum time in seconds to wait for disk addition to complete. Default is 1800 seconds (30 minutes).

        .EXAMPLE
        $disksByHost = Group-DisksByHost -Disks $selectedDisks
        Add-VsanEsaDiskToStoragePool -DisksByHost $disksByHost
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(5, 120)] [Int]$ClaimRetryDelaySeconds = 15,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 12)] [Int]$ClaimRetryMaxAttempts = 4,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Hashtable]$DisksByHost,
        [Parameter(Mandatory = $false)] [ValidateRange(60, 3600)] [Int]$TimeoutSeconds = 1800
    )

    foreach ($hostName in ($DisksByHost.Keys | Sort-Object)) {
        $hostDisks = $DisksByHost[$hostName]
        # Create array of canonical names as strings.
        $canonicalNames = [System.Collections.ArrayList]::new()
        foreach ($disk in $hostDisks) {
            [void]$canonicalNames.Add($disk.CanonicalName)
        }
        # Convert to array for cmdlet parameter.
        $canonicalNames = $canonicalNames.ToArray()

        Write-LogMessage -Type INFO -NoNewline -Message "Adding $($hostDisks.Count) disk(s) to vSAN ESA datastore from host `"$hostName`"... "

        try {
            $vmHostObject = Get-VMHost -Name $hostName -Server $Script:vCenterName -ErrorAction Stop
            Write-LogMessage -Type DEBUG -Message "Retrieved VMHost object for `"$hostName`". Starting disk addition operation at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')..."

            $rescanStorageCmd = Get-Command -Name "Get-VMHostStorage" -ErrorAction SilentlyContinue
            if ($null -ne $rescanStorageCmd -and $rescanStorageCmd.Parameters.ContainsKey("RescanAllHba")) {
                try {
                    $null = Get-VMHostStorage -VMHost $vmHostObject -RescanAllHba -Server $Script:vCenterName -ErrorAction Stop
                    Write-LogMessage -Type DEBUG -Message "Rescanned storage (all HBAs) on host `"$hostName`" before vSAN ESA storage pool disk claim."
                } catch {
                    Write-LogMessage -Type DEBUG -Message "Storage rescan before ESA disk claim failed on `"$hostName`" (non-fatal): $($_.Exception.Message)."
                }
            }

            # Execute Add-VsanStoragePoolDisk with retries for transient invalid object state while vSAN/VMOM catches up with vCenter.
            $operationStartTime = Get-Date
            try {
                $claimAttempt = 0
                while ($claimAttempt -lt $ClaimRetryMaxAttempts) {
                    $claimAttempt++
                    try {
                        Add-VsanStoragePoolDisk -VMHost $vmHostObject -VsanStoragePoolDiskType $Script:VsanStoragePoolDiskType -DiskCanonicalName $canonicalNames -ErrorAction Stop | Out-Null
                        break
                    } catch {
                        $rawMsg = $_.Exception.Message
                        if ($_.Exception.InnerException) {
                            $rawMsg = "$rawMsg $($_.Exception.InnerException.Message)"
                        }
                        $isTransientState = $rawMsg -match "Operation is not valid due to the current state of the object|invalid state|InvalidState|not allowed in the current state"
                        if ($isTransientState -and $claimAttempt -lt $ClaimRetryMaxAttempts) {
                            Write-LogMessage -Type WARNING -Message "Add-VsanStoragePoolDisk attempt $claimAttempt of $ClaimRetryMaxAttempts on host `"$hostName`" failed (transient object state). Waiting $ClaimRetryDelaySeconds seconds before retry."
                            Start-Sleep -Seconds $ClaimRetryDelaySeconds
                            continue
                        }
                        throw
                    }
                }

                $operationEndTime = Get-Date
                $operationDuration = [math]::Round(($operationEndTime - $operationStartTime).TotalSeconds, 2)
                Write-LogMessage -Type DEBUG -Message "Add-VsanStoragePoolDisk operation completed for host `"$hostName`" after $operationDuration seconds."

                Write-LogMessage -Type INFO -CompletePending -Message "Success"
            } catch {
                $operationEndTime = Get-Date
                $operationDuration = [math]::Round(($operationEndTime - $operationStartTime).TotalSeconds, 2)
                Write-LogMessage -Type DEBUG -Message "Add-VsanStoragePoolDisk operation failed for host `"$hostName`" after $operationDuration seconds."

                # Check if the error is a PowerCLI web operation timeout (default is 5 minutes).
                $errorReason = Get-CleanVsanErrorMessage -ErrorMessage $_.Exception.Message
                if ($_.Exception.Message -match "request channel timed out|SendTimeout|00:05:00") {
                    $recommendedTimeout = [Math]::Min($TimeoutSeconds + $Script:PowerCliTimeoutBufferSeconds, $Script:MaxPowerCliTimeoutSeconds)
                    Write-LogMessage -Type ERROR -CompletePending -Message " Failed."
                    Write-LogMessage -Type ERROR -Message "Add disk(s) to datastore failed due to PowerCLI web operation timeout (default is 5 minutes)."
                    Write-LogMessage -Type ERROR -Message "To resolve this, increase the PowerCLI web operation timeout by running:"
                    Write-LogMessage -Type ERROR -Message "    Set-PowerCLIConfiguration -WebOperationTimeoutSeconds $recommendedTimeout -Scope Session"
                    Write-LogMessage -Type ERROR -Message "Then re-run the deployment. The recommended timeout is $recommendedTimeout seconds (based on operation timeout of $TimeoutSeconds seconds)."
                    Write-LogMessage -Type ERROR -Message "Failed to add disks to vSAN ESA datastore from host `"$hostName`": $errorReason"
                } else {
                    Write-LogMessage -Type ERROR -CompletePending -Message " Failed."
                    Write-LogMessage -Type ERROR -Message "Failed to add disks to vSAN ESA datastore from host `"$hostName`": $errorReason"
                }
                throw "Failed to add disks to vSAN ESA datastore from host `"$hostName`": $errorReason"
            }
        } catch {
            if ($null -ne $Script:LogMessagePending) {
                Write-LogMessage -Type ERROR -CompletePending -Message " Failed."
            }
            $errorReason = Get-CleanVsanErrorMessage -ErrorMessage $_.Exception.Message
            Write-LogMessage -Type ERROR -Message "Failed to add disks to vSAN ESA datastore from host `"$hostName`": $errorReason"
            throw [VcfDeploymentException]::new("Failed to add disks to vSAN ESA datastore from host `"$hostName`": $errorReason")
        }
    }
}
Function Wait-ForVsanDatastoreAndRename {
    <#
        .SYNOPSIS
        Waits for a vSAN datastore to appear and renames it to the specified name.

        .DESCRIPTION
        Polls vCenter for vSAN datastores accessible by cluster hosts. When found, renames the
        datastore to the specified name and verifies the rename succeeded.

        .PARAMETER DatastoreName
        Target name for the vSAN datastore.

        .PARAMETER ClusterHosts
        Array of VMHost objects in the cluster.

        .PARAMETER TimeoutSeconds
        Maximum time in seconds to wait for the datastore to appear. Default is 300 seconds.

        .PARAMETER CheckInterval
        Interval in seconds between checks. Default is 5 seconds.

        .EXAMPLE
        Wait-ForVsanDatastoreAndRename `
            -DatastoreName "datastore-site1" `
            -ClusterHosts $clusterHosts `
            -TimeoutSeconds 300 `
            -CheckInterval 5
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(1, 60)] [Int]$CheckInterval = 5,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Array]$ClusterHosts,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DatastoreName,
        [Parameter(Mandatory = $false)] [ValidateRange(60, 1800)] [Int]$TimeoutSeconds = 300
    )

    Write-LogMessage -Type INFO -NoNewline -Message "Waiting for vSAN datastore to become available and renaming to `"$DatastoreName`"... "

    # Cache cluster host IDs outside the loop for efficiency.
    $clusterHostIds = $ClusterHosts | Select-Object -ExpandProperty Id
    Write-LogMessage -Type DEBUG -Message "Cached cluster host IDs: $($clusterHostIds.Count) host(s). Starting datastore search at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

    $datastoreFound = $false
    $startTime = Get-Date
    $checkCount = 0
    $lastLoggedTime = 0
    $logIntervalSeconds = $Script:DatastoreWaitLogIntervalSeconds

    while (-not $datastoreFound) {
        $checkCount++
        $elapsedTime = [math]::Floor(((Get-Date) - $startTime).TotalSeconds)
        if ($elapsedTime -ge $TimeoutSeconds) {
            Write-LogMessage -Type ERROR -CompletePending -Message " Failed."
            Write-LogMessage -Type ERROR -Message "vSAN datastore did not appear within $TimeoutSeconds seconds after $checkCount check(s)."
            # Perform a final comprehensive check before failing.
            Write-LogMessage -Type DEBUG -Message "Performing final comprehensive datastore check..."
            $allDatastores = Get-Datastore -Server $Script:vCenterName -ErrorAction SilentlyContinue
            $vsanDatastoresAll = $allDatastores | Where-Object { $_.Type -eq "vsan" }
            $dsNames = $vsanDatastoresAll | Select-Object -ExpandProperty Name
            Write-LogMessage -Type DEBUG -Message "Found $($vsanDatastoresAll.Count) vSAN datastore(s) total in vCenter: $($dsNames -join ', ')"
            if ($vsanDatastoresAll.Count -gt 0) {
                Write-LogMessage -Type WARNING -Message "vSAN datastore(s) exist but may not be accessible by cluster hosts. Cluster host IDs: $($clusterHostIds -join ', ')"
                foreach ($ds in $vsanDatastoresAll) {
                    if ($ds.ExtensionData.Host) {
                        $dsHostIds = $ds.ExtensionData.Host | Select-Object -ExpandProperty Key | Select-Object -ExpandProperty Value
                        Write-LogMessage -Type DEBUG -Message "  Datastore `"$($ds.Name)`" accessible by host IDs: $($dsHostIds -join ', ')"
                    }
                }
            }
            throw "Deployment failed. vSAN datastore was not created within the timeout period. Check logs for details."
        }

        # Look for vSAN datastores accessible by hosts in the cluster.
        $vsanDatastores = Get-VsanDatastoreForCluster -ClusterHostIds $clusterHostIds

        # Only log periodically to reduce verbosity, or when datastore count changes.
        if (($elapsedTime - $lastLoggedTime) -ge $logIntervalSeconds -or ($vsanDatastores.Count -gt 0)) {
            Write-LogMessage -Type DEBUG -Message "Check #$checkCount (elapsed: $elapsedTime seconds): Found $($vsanDatastores.Count) vSAN datastore(s) accessible by cluster hosts."
            $lastLoggedTime = $elapsedTime
        }

        if ($vsanDatastores -and $vsanDatastores.Count -gt 0) {
            Write-LogMessage -Type DEBUG -Message "vSAN datastore found: `"$($vsanDatastores[0].Name)`" (Type: $($vsanDatastores[0].Type))"
            $vsanDatastore = $vsanDatastores | Select-Object -First 1

            if ($vsanDatastore.Name -ne $DatastoreName) {
                try {
                    $vsanDatastore | Set-Datastore -Name $DatastoreName -Server $Script:vCenterName -ErrorAction Stop | Out-Null

                    # Verify the rename succeeded by re-querying the datastore.
                    Start-Sleep -Seconds $Script:DatastoreRenameVerificationDelaySeconds
                    $renamedDatastore = Get-Datastore -Name $DatastoreName -Server $Script:vCenterName -ErrorAction SilentlyContinue
                    if (-not $renamedDatastore) {
                        Write-LogMessage -Type ERROR -Message "Failed to verify vSAN datastore rename. Datastore `"$DatastoreName`" not found after rename operation."
                        throw [VcfDeploymentException]::new("Deployment failed. vSAN datastore rename verification failed. Check logs for details.")
                    }

                    Write-LogMessage -Type INFO -CompletePending -Message "Success"
                } catch [VcfDeploymentException] {
                    throw  # already logged and typed — propagate without re-wrapping
                } catch {
                    Write-LogMessage -Type ERROR -CompletePending -Message " Failed."
                    Write-LogMessage -Type ERROR -Message "Failed to rename vSAN datastore from `"$($vsanDatastore.Name)`" to `"$DatastoreName`": $($_.Exception.Message)"
                    throw [VcfDeploymentException]::new("Deployment failed. vSAN datastore rename failed. Check logs for details.")
                }
            }

            # Final verification that the datastore exists with the expected name.
            $finalDatastore = Get-Datastore -Name $DatastoreName -Server $Script:vCenterName -ErrorAction SilentlyContinue
            if (-not $finalDatastore) {
                Write-LogMessage -Type ERROR -Message "vSAN datastore `"$DatastoreName`" not found after configuration."
                throw [VcfDeploymentException]::new("Deployment failed. vSAN datastore `"$DatastoreName`" not found. Check logs for details.")
            }
            # Suppress output from datastore object to prevent table display.
            $null = $finalDatastore

            $datastoreFound = $true
            Write-LogMessage -Type DEBUG -Message "vSAN datastore `"$DatastoreName`" is available."
            break
        }

        $statusMessage = "Elapsed: $elapsedTime seconds - Waiting for vSAN datastore..."
        Write-Progress -Activity "Waiting for vSAN datastore" -Status $statusMessage
        [Console]::Out.Flush()
        Start-Sleep -Seconds $CheckInterval
    }

    Write-Progress -Activity "Waiting for vSAN datastore" -Status "Complete" -Completed
    [Console]::Out.Flush()
}
Function Get-CleanVsanErrorMessage {
    <#
        .SYNOPSIS
        Extracts a concise reason from vSAN/API error messages for user-facing output.

        .DESCRIPTION
        API and PowerCLI errors often include timestamps, cmdlet names, and multi-part "Reason 1:", "Reason 2:" text.
        This helper returns only the essential reason (e.g. "Reason 1:" text, or "Server task failed:" message, trimmed).
        Pattern order matters: first match wins (e.g. "Reason 1:" is preferred over "Reason:" when both exist).

        .EXAMPLE
        Get-CleanVsanErrorMessage -ErrorMessage "Reason: Disk group already exists. Reason 2: Other"
        Returns "Disk group already exists." (text before "Reason 2:" is used).

        .NOTES
        Whitespace-only input is returned unchanged. When no pattern matches, the original message is returned.
    #>
    Param ([Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ErrorMessage)

    if ([string]::IsNullOrWhiteSpace($ErrorMessage)) {
        return $ErrorMessage
    }

    switch -Regex ($ErrorMessage) {
        # New-VsanDiskGroup / API returns "Sequence contains no elements" when disk lookup returns empty.
        "Sequence contains no elements" {
            return "vSAN disk group creation failed: one or more disks could not be resolved on the host (Sequence contains no elements). Verify cache and capacity disk canonical names on the witness host and that disks are not in use."
        }
        # Witness host not found: "date time   Get-VMHost   VMHost with name 'X' was not found using the specified filter(s)."
        "VMHost with name\s+'([^']+)'\s+was not found" {
            return "vSAN witness host `"$($Matches[1])`" was not found in vCenter. Add the witness host to vCenter and ensure the name or IP in configuration (common.vSanWitnessVmName or clusters[].vSanWitnessVmName) matches the host name in vCenter."
        }
        "VMHost with name .+ was not found using the specified filter" {
            return "vSAN witness host was not found in vCenter. Add the witness host to vCenter and ensure the name or IP in configuration (common.vSanWitnessVmName or clusters[].vSanWitnessVmName) matches the host name in vCenter."
        }
        # PowerCLI server task format: "date time      CmdletName         Server task failed: reason" - use the reason after the colon.
        "Server task failed:\s*(.+)" {
            return $Matches[1].Trim()
        }
        # Prefer "Reason 1: ..." and stop at "Reason 2:" or end of string.
        "Reason\s*1:\s*(.+?)(?=\s*Reason\s*2:|\s*$)" {
            return $Matches[1].Trim()
        }
        # Single "Reason: ..." - use it, but trim at "Reason 2:" if present.
        "Reason:\s*(.+)" {
            $reasonText = $Matches[1].Trim()
            if ($reasonText -match "^(.+?)\s*Reason\s*2:") {
                return $Matches[1].Trim()
            }
            return $reasonText
        }
        default {
            return $ErrorMessage
        }
    }
}
Function Initialize-VsanWitnessDiskGroup {
    <#
        .SYNOPSIS
        Ensures the vSAN witness host has a valid disk group; creates it if missing.

        .DESCRIPTION
        This function is called before Set-VsanWitness when the witness host
        already has a vSAN ESA storage pool disk or a vSAN OSA disk group with cache and capacity, the
        function returns without changes. For ESA: the witness uses a single disk (or zero); the script
        does not add a disk pool to the witness and the witness is configured without a witness storage pool.
        For OSA: if the witness has no disk group, automatic selection is used (smallest SSD as cache, remaining
        disks as capacity). When only one disk is vSAN-eligible (e.g. boot device excluded by the host), the
        script attempts a single-disk disk group for official vSAN OSA witness appliance compatibility; if the
        platform rejects it, the error instructs adding a second non-boot disk. Cluster-level VsanDiskClaimMode
        Automatic does not apply to the witness (the witness host is not in the data cluster).

        .PARAMETER ClusterName
        The cluster name (used for OSA eligible disk retrieval logging).

        .PARAMETER MinWitnessEsaCapacityGB
        Minimum capacity in GB for the largest eligible disk when auto-creating the vSAN ESA witness storage pool. Disks below this are rejected to avoid "Failed to add disks to vSAN" from the server. Default 32.

        .PARAMETER StoragePolicyType
        vSAN-ESA or vSAN-OSA.

        .PARAMETER vSanWitnessVmName
        FQDN or IP of the witness host.

        .NOTES
        Detecting the correct witness type: the script reads the advanced setting VSAN.HostDeployedFromWitnessOVF on the witness host (1 = OSA witness OVA, 2 = ESA witness OVA) and validates that it matches the cluster storage policy type (vSAN-ESA vs vSAN-OSA). A mismatch causes deployment to fail with guidance to deploy the correct witness OVA. If the setting is absent, the script also checks disk layout (OSA disk group vs ESA storage pool) and fails if the witness type does not match.
        A single witness may be used for many clusters; the workflow is not always creating the storage group. When the witness already has an OSA disk group (e.g. from another cluster), creation is skipped.
        Called when vSanWitnessVmName is set. ESA witness: uses a single disk (or zero); no disk pool is added by this script. OSA witness: automatic selection (smallest SSD = cache, rest = capacity). The official vSAN OSA witness OVF configures only one vSAN data disk (T1:L0); T0 is boot. When only one eligible disk is reported, single-disk disk group is attempted; if the API rejects it, add a second non-boot disk. Ensure the witness ran OVF firstboot so HostDeployedFromWitnessOVF and vsanWitnessVirtualAppliance are set.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 10000)] [int]$MinWitnessEsaCapacityGB = 32,
        [Parameter(Mandatory = $true)] [ValidateSet("vSAN-ESA", "vSAN-OSA")] [String]$StoragePolicyType,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$vSanWitnessVmName
    )

    Write-LogMessage -Type DEBUG -Message "Entered Initialize-VsanWitnessDiskGroup for witness `"$vSanWitnessVmName`", storage type `"$StoragePolicyType`"."

    $witnessHost = Get-VMHost -Name $vSanWitnessVmName -Server $Script:vCenterName -ErrorAction Stop
    if (-not $witnessHost) {
        Write-LogMessage -Type ERROR -Message "Witness host `"$vSanWitnessVmName`" not found in vCenter."
        throw [VcfDeploymentException]::new("Deployment failed. Witness host `"$vSanWitnessVmName`" not found. Ensure the witness host is added to vCenter.")
    }

    # Check HostDeployedFromWitnessOVF (set by official witness OVF at firstboot): 1 = OSA witness OVA, 2 = ESA witness OVA. If present and mismatched, tell the user they deployed the wrong OVA.
    $hostDeployedFromWitnessOvf = $null
    try {
        $advSetting = Get-AdvancedSetting -Entity $witnessHost -Name "VSAN.HostDeployedFromWitnessOVF" -ErrorAction SilentlyContinue
        if ($advSetting -and $null -ne $advSetting.Value) {
            $hostDeployedFromWitnessOvf = [int]$advSetting.Value
            Write-LogMessage -Type DEBUG -Message "Witness host `"$vSanWitnessVmName`" HostDeployedFromWitnessOVF=$hostDeployedFromWitnessOvf (1=OSA witness OVA, 2=ESA witness OVA)."
        }
    } catch {
        Write-LogMessage -Type DEBUG -Message "Could not read HostDeployedFromWitnessOVF from witness `"$vSanWitnessVmName`": $($_.Exception.Message). Skipping OVA-type check."
    }
    if ($null -ne $hostDeployedFromWitnessOvf) {
        if ($StoragePolicyType -eq "vSAN-OSA" -and $hostDeployedFromWitnessOvf -eq 2) {
            Write-LogMessage -Type ERROR -Message "Witness host `"$vSanWitnessVmName`" was deployed from the vSAN ESA witness OVA (HostDeployedFromWitnessOVF=2). For an OSA cluster use the vSAN OSA witness appliance OVA."
            throw [VcfDeploymentException]::new("Deployment failed. This witness was deployed from the vSAN ESA witness OVA. For an OSA cluster use the vSAN OSA witness appliance OVA (and vice versa for ESA). Redeploy the correct witness OVA and re-run.")
        }
        if ($StoragePolicyType -eq "vSAN-ESA" -and $hostDeployedFromWitnessOvf -eq 1) {
            Write-LogMessage -Type ERROR -Message "Witness host `"$vSanWitnessVmName`" was deployed from the vSAN OSA witness OVA (HostDeployedFromWitnessOVF=1). For an ESA cluster use the vSAN ESA witness appliance OVA."
            throw [VcfDeploymentException]::new("Deployment failed. This witness was deployed from the vSAN OSA witness OVA. For an ESA cluster use the vSAN ESA witness appliance OVA (and vice versa for OSA). Redeploy the correct witness OVA and re-run.")
        }
    }

    # Fail if witness disk layout does not match requested storage type (OSA vs ESA). Prevents using an OSA witness for ESA or vice versa.
    if ($StoragePolicyType -eq "vSAN-ESA") {
        $witnessOsaResult = Get-VsanOsaDiskGroupsOnHost -VMHost $witnessHost -Server $Script:vCenterName
        if ($witnessOsaResult.HasValidOsaGroup) {
            Write-LogMessage -Type ERROR -Message "Witness host `"$vSanWitnessVmName`" has a vSAN OSA disk group (cache + capacity). This witness is for vSAN OSA, not ESA. Use an ESA witness or remove the OSA disk group from this host."
            throw [VcfDeploymentException]::new("Deployment failed. Witness host `"$vSanWitnessVmName`" has a vSAN OSA disk group (cache + capacity). This witness is for vSAN OSA, not ESA. Use a different host for the ESA witness or remove the OSA disk group from this host. Deployment will roll back.")
        }
    }
    elseif ($StoragePolicyType -eq "vSAN-OSA") {
        $witnessPoolDisks = Get-VsanStoragePoolDisk -VMHost $witnessHost -Server $Script:vCenterName -ErrorAction SilentlyContinue
        $witnessPoolDiskCount = if ($witnessPoolDisks) { @($witnessPoolDisks).Count } else { 0 }
        if ($witnessPoolDiskCount -ge 1) {
            Write-LogMessage -Type ERROR -Message "Witness host `"$vSanWitnessVmName`" has a vSAN ESA storage pool (all-flash). This witness is for vSAN ESA, not OSA. Use an OSA witness or remove the ESA storage pool from this host."
            throw [VcfDeploymentException]::new("Deployment failed. Witness host `"$vSanWitnessVmName`" has a vSAN ESA storage pool (all-flash). This witness is for vSAN ESA, not OSA. Use a different host for the OSA witness or remove the ESA storage pool from this host. Deployment will roll back.")
        }
    }

    if ($StoragePolicyType -eq "vSAN-ESA") {
        $witnessPoolDisks = Get-VsanStoragePoolDisk -VMHost $witnessHost -Server $Script:vCenterName -ErrorAction SilentlyContinue
        $witnessPoolDiskCount = if ($witnessPoolDisks) { @($witnessPoolDisks).Count } else { 0 }
        if ($witnessPoolDiskCount -ge 1) {
            Write-LogMessage -Type DEBUG -Message "Witness host `"$vSanWitnessVmName`" already has $witnessPoolDiskCount vSAN ESA storage pool disk(s). Skipping."
            return
        }
        # ESA witness with no disk pool is a supported configuration; no disk is added to the witness host. MinWitnessEsaCapacityGB is reserved for future disk selection if we add ESA witness disk pool creation.
        Write-LogMessage -Type INFO -Message "ESA witness: no disk pool is added to the witness host (supported configuration). MinWitnessEsaCapacityGB=$MinWitnessEsaCapacityGB is reserved for future use."
        return
    }

    if ($StoragePolicyType -eq "vSAN-OSA") {
        # Use HostVsanSystem API so witness is detected even when not in a cluster (Get-VsanDiskGroup requires cluster membership).
        $witnessOsaResult = Get-VsanOsaDiskGroupsOnHost -VMHost $witnessHost -Server $Script:vCenterName
        $hasValidOsaGroup = $witnessOsaResult.HasValidOsaGroup -or ($witnessOsaResult.DiskGroupCount -gt 0)
        if ($witnessOsaResult.DiskGroupCount -gt 0) {
            Write-LogMessage -Type DEBUG -Message "Witness host `"$vSanWitnessVmName`" has $($witnessOsaResult.DiskGroupCount) OSA disk group(s) (HostVsanSystem.config). HasValidOsaGroup=$($witnessOsaResult.HasValidOsaGroup)."
        }
        if ($hasValidOsaGroup) {
            Write-LogMessage -Type INFO -Message "Witness host `"$vSanWitnessVmName`" already has a vSAN OSA disk group. Skipping auto-create."
            return
        }
        $witnessHostsArray = @($witnessHost)
        Write-LogMessage -Type DEBUG -Message "Initialize-VsanWitnessDiskGroup (OSA): calling Get-VsanOsaEligibleDisksFromCluster with ClusterHosts count=$($witnessHostsArray.Count), host name=`"$($witnessHost.Name)`" (witness only)."
        $eligibleDisks = Get-VsanOsaEligibleDisksFromCluster -ClusterName $ClusterName -ClusterHosts $witnessHostsArray
        Write-LogMessage -Type DEBUG -Message "Initialize-VsanWitnessDiskGroup (OSA): witness host returned $($eligibleDisks.Count) eligible disk(s)."
        if (-not $eligibleDisks -or $eligibleDisks.Count -eq 0) {
            Write-LogMessage -Type ERROR -Message "Witness host `"$vSanWitnessVmName`" has no vSAN OSA eligible disks. The boot device is typically excluded from vSAN; add at least one non-boot disk (e.g. a second virtual disk) to the witness appliance."
            throw [VcfDeploymentException]::new("Deployment failed. Witness host `"$vSanWitnessVmName`" has no eligible disks. Add at least one non-boot disk to the witness and re-run. Check logs for details.")
        }
        # Official vSAN OSA witness appliance (see provision script sets numVsanSsds=1 and marks only mpx.vmhba0:C0:T1:L0 as SSD; T0 is boot and is not used for vSAN. So only one disk is vSAN-eligible. Try that one disk as cache+capacity; if the platform rejects it, we throw and ask for a second disk.
        $singleSsdWitness = $false
        if ($eligibleDisks.Count -eq 1) {
            $onlyDisk = $eligibleDisks[0]
            if ($onlyDisk.IsSsd) {
                $singleSsdWitness = $true
                Write-LogMessage -Type INFO -Message "Witness has one eligible SSD; attempting single-disk OSA witness disk group (official witness appliance compatibility)."
            } else {
                Write-LogMessage -Type ERROR -Message "Witness host `"$vSanWitnessVmName`" has only one eligible disk (not SSD). vSAN OSA requires one SSD for cache. Add a non-boot SSD or a second disk to the witness appliance and re-run."
                throw [VcfDeploymentException]::new("Deployment failed. Witness host `"$vSanWitnessVmName`" needs at least one SSD for cache. Add an SSD or a second disk. Check logs for details.")
            }
        }
        # Cache must be SSD (New-VsanDiskGroup -SsdCanonicalName requires SSD). Capacity can be HDD or SSD. Use smallest SSD as cache so assignment is deterministic (API disk order can vary).
        $ssds = @($eligibleDisks | Where-Object { $_.IsSsd } | Sort-Object -Property CapacityGB)
        $nonSsds = @($eligibleDisks | Where-Object { -not $_.IsSsd })
        if ($ssds.Count -gt 0) {
            $cacheDisk = $ssds[0]
            $witnessOsaApiOrderStr = ($eligibleDisks | ForEach-Object { "$($_.CanonicalName)/$($_.CapacityGB)/$($_.IsSsd)" }) -join ", "
            Write-LogMessage -Type DEBUG -Message "Initialize-VsanWitnessDiskGroup (OSA): witness disks (API order) CanonicalName/CapacityGB/IsSsd: $witnessOsaApiOrderStr. Chosen cache: $($cacheDisk.CanonicalName), CapacityGB=$($cacheDisk.CapacityGB)."
            if ($singleSsdWitness) {
                $capacityDisksList = @($cacheDisk)
            } else {
                $capacityDisksList = $nonSsds + ($ssds | Select-Object -Skip 1)
            }
        } else {
            Write-LogMessage -Type ERROR -Message "Witness host `"$vSanWitnessVmName`" has no SSD among eligible disks. vSAN OSA requires one SSD for cache; capacity can be HDD or SSD. The boot device is typically excluded; add a non-boot SSD to the witness."
            throw [VcfDeploymentException]::new("Deployment failed. Witness host `"$vSanWitnessVmName`" must have at least one SSD for the OSA witness cache tier. Add an SSD; capacity disk(s) can be HDD or SSD. Check logs for details.")
        }
        $capacityDisksList = @($capacityDisksList)
        if ($capacityDisksList.Count -eq 0 -and -not $singleSsdWitness) {
            Write-LogMessage -Type ERROR -Message "Witness host `"$vSanWitnessVmName`" has only one eligible disk (SSD). Add a second non-boot disk to the witness appliance and re-run."
            throw [VcfDeploymentException]::new("Deployment failed. Witness host `"$vSanWitnessVmName`" needs two eligible disks for OSA: one SSD for cache and one distinct disk for capacity. Add a second non-boot disk and re-run. Check logs for details.")
        }
        # Validate cache disk has a valid CanonicalName.
        if ([String]::IsNullOrWhiteSpace($cacheDisk.CanonicalName)) {
            Write-LogMessage -Type ERROR -Message "Witness host `"$vSanWitnessVmName`" cache SSD disk has no valid CanonicalName."
            throw [VcfDeploymentException]::new("Deployment failed. Witness host `"$vSanWitnessVmName`" cache SSD disk missing CanonicalName. Check logs for details.")
        }
        # Build capacity canonical names; exclude null/empty to avoid "Sequence contains no elements" from New-VsanDiskGroup.
        $capacityCanonicalNames = [string[]]@($capacityDisksList | ForEach-Object { $_.CanonicalName } | Where-Object { -not [String]::IsNullOrWhiteSpace($_) })
        if ($capacityCanonicalNames.Count -eq 0) {
            Write-LogMessage -Type ERROR -Message "Witness host `"$vSanWitnessVmName`" capacity disk(s) have no valid CanonicalName."
            throw [VcfDeploymentException]::new("Deployment failed. Witness host `"$vSanWitnessVmName`" capacity disks missing CanonicalName. Check logs for details.")
        }
        Write-LogMessage -Type INFO -Message "Creating vSAN OSA witness disk group on `"$vSanWitnessVmName`" (cache SSD: $($cacheDisk.CanonicalName), capacity: $($capacityCanonicalNames -join ', '))."
        # Pre-validate that cache and capacity disks are visible on the witness host (Get-ScsiLun). Resolve to the LUN's CanonicalName so New-VsanDiskGroup receives the format the host uses (e.g. NAA); QueryDisksForVsan may return mpx path, which can cause "Sequence contains no elements" when the cmdlet looks up by NAA.
        $requiredCanonicalNames = @($cacheDisk.CanonicalName) + @($capacityCanonicalNames)
        $visibleLuns = Get-ScsiLun -VMHost $witnessHost -LunType disk -ErrorAction SilentlyContinue
        $visibleCanonicalNames = @($visibleLuns | ForEach-Object { $_.CanonicalName } | Select-Object -Unique)
        $visibleRuntimeNames = @($visibleLuns | ForEach-Object { if ($_.PSObject.Properties['RuntimeName']) { $_.RuntimeName } else { $null } } | Where-Object { -not [String]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
        $missingDisks = @($requiredCanonicalNames | Where-Object {
            $cn = $_
            $visibleCanonicalNames -notcontains $cn -and $visibleRuntimeNames -notcontains $cn
        })
        if ($missingDisks.Count -gt 0) {
            Write-LogMessage -Type ERROR -Message "Witness host `"$vSanWitnessVmName`" cannot see one or more disks that were reported as eligible. Missing on host: $($missingDisks -join ', '). Visible disk count: $($visibleCanonicalNames.Count)."
            throw [VcfDeploymentException]::new("Deployment failed. vSAN witness disk group creation failed on `"$vSanWitnessVmName`": the following disk(s) are not visible on the witness host (or may be in use): $($missingDisks -join ', '). Ensure these canonical names match the disks on the witness host and that the disks are not in use. If the error persists, create the OSA disk group manually on the witness host and re-run.")
        }
        # Resolve each disk to the ScsiLun's CanonicalName (typically NAA) so New-VsanDiskGroup receives the format the host/vSAN API expects; avoids "Sequence contains no elements" when QueryDisksForVsan returns mpx and the cmdlet looks up by NAA.
        $cacheLun = $visibleLuns | Where-Object { $_.CanonicalName -eq $cacheDisk.CanonicalName -or ($_.PSObject.Properties['RuntimeName'] -and $_.RuntimeName -eq $cacheDisk.CanonicalName) } | Select-Object -First 1
        $cacheNameForCmdlet = if ($cacheLun) { $cacheLun.CanonicalName } else { $cacheDisk.CanonicalName }
        $capacityNamesForCmdlet = [System.Collections.ArrayList]::new()
        foreach ($capName in $capacityCanonicalNames) {
            $capLun = $visibleLuns | Where-Object { $_.CanonicalName -eq $capName -or ($_.PSObject.Properties['RuntimeName'] -and $_.RuntimeName -eq $capName) } | Select-Object -First 1
            $nameToAdd = if ($capLun) { $capLun.CanonicalName } else { $capName }
            [void]$capacityNamesForCmdlet.Add($nameToAdd)
        }
        $dataDiskArray = @($capacityNamesForCmdlet)
        if ($cacheNameForCmdlet -ne $cacheDisk.CanonicalName -or ($capacityNamesForCmdlet -join ',') -ne ($capacityCanonicalNames -join ',')) {
            Write-LogMessage -Type DEBUG -Message "Initialize-VsanWitnessDiskGroup (OSA): resolved disk names for New-VsanDiskGroup (cache: $cacheNameForCmdlet, capacity: $($dataDiskArray -join ', '))."
        }
        try {
            New-VsanDiskGroup -VMHost $witnessHost -SsdCanonicalName $cacheNameForCmdlet -DataDiskCanonicalName $dataDiskArray -ErrorAction Stop | Out-Null
        } catch {
            $msg = $_.Exception.Message
            if ($_.Exception.InnerException) { $msg = $_.Exception.InnerException.Message }
            if ($singleSsdWitness) {
                Write-LogMessage -Type WARNING -Message "Single-disk witness disk group failed on `"$vSanWitnessVmName`": $msg. This platform requires distinct cache and capacity disks."
                throw "Deployment failed. Witness host `"$vSanWitnessVmName`" has only one vSAN-eligible disk; this platform requires one distinct cache (SSD) and one distinct capacity disk. Add a second non-boot disk to the witness appliance and re-run. Check logs for details."
            }
            if ($msg -match "Sequence contains no elements") {
                # Disks may already be in a vSAN disk group (e.g. created earlier or by another process); re-check and treat as success if so.
                $witnessOsaRecheck = Get-VsanOsaDiskGroupsOnHost -VMHost $witnessHost -Server $Script:vCenterName
                if ($witnessOsaRecheck.HasValidOsaGroup -or $witnessOsaRecheck.DiskGroupCount -gt 0) {
                    Write-LogMessage -Type DEBUG -Message "New-VsanDiskGroup failed with Sequence contains no elements; witness `"$vSanWitnessVmName`" already has a vSAN OSA disk group. Treating as success."
                    return
                }
                Write-LogMessage -Type ERROR -Message "New-VsanDiskGroup failed on witness `"$vSanWitnessVmName`" with Sequence contains no elements. Names passed to cmdlet: cache=$cacheNameForCmdlet, capacity=$($dataDiskArray -join ', '). Disks were visible via Get-ScsiLun; the failure may be due to disk state (e.g. in use) or a VCF PowerCLI lookup difference."
                throw [VcfDeploymentException]::new("Deployment failed. vSAN witness disk group creation failed on `"$vSanWitnessVmName`": the host could not resolve one or more disks (cache: $cacheNameForCmdlet, capacity: $($dataDiskArray -join ', ')). Ensure these canonical names match the disks visible on the witness host and that the disks are not in use. If the error persists, create the OSA disk group manually on the witness host and re-run.")
            }
            throw
        }
        if ($singleSsdWitness) {
            Write-LogMessage -Type INFO -Message "Successfully created vSAN OSA witness disk group on host `"$vSanWitnessVmName`" (single eligible disk; official witness appliance compatibility)."
        } else {
            Write-LogMessage -Type INFO -Message "Successfully created vSAN OSA witness disk group on host `"$vSanWitnessVmName`"."
        }
    }
}
Function Set-VsanWitness {
    <#
        .SYNOPSIS
        Configures a vSAN witness host for a cluster.

        .DESCRIPTION
        This function configures a vSAN witness host for a vSAN cluster (OSA or ESA).
        The witness host is used to provide quorum in two-node vSAN deployments.
        The function configures the witness host with the preferred fault domain using
        the first ESX host in the cluster. When creating fault domains, the preferred (first host) is named
        "Primary" and the other is named "Secondary". Existing fault domains can be resolved by "Primary", PreferredFaultDomainName (e.g. edge site), or by host.

        .PARAMETER ClusterName
        The name of the vSAN cluster for which to configure the witness host. Must be a non-empty string.

        .PARAMETER LabEnvironment
        When $true (e.g. common.labenvironment in infrastructure JSON), a witness/data host ESX version or build mismatch is logged as WARNING and the workflow continues without prompting. When $false, the user is prompted to continue or not.

        .PARAMETER PreferredFaultDomainName
        Used to resolve an existing preferred fault domain by name (e.g. edge site name). When fault domains are created by this function, the preferred is named "Primary" and the other is "Secondary". Must be a non-empty string.

        .PARAMETER StoragePolicyType
        The vSAN storage type: vSAN-OSA (requires witness host with at least 8 GB memory) or vSAN-ESA (requires at least 16 GB). The function enforces the minimum memory for the witness host based on this type.

        .PARAMETER vSanWitnessVmName
        The FQDN or IP address of the witness host. Must be a non-empty string.

        .EXAMPLE
        Set-VsanWitness -ClusterName "cl0-site1" -PreferredFaultDomainName "site1" -StoragePolicyType "vSAN-ESA" -vSanWitnessVmName "10.191.174.201"

        Configures the witness host "10.191.174.201" for an ESA cluster "cl0-site1". Validates the witness has at least 16 GB memory. If fault domains are created, they are named Primary and Secondary.

        .NOTES
        - Requires connection to vCenter via PowerCLI
        - Uses Get-Cluster, Get-VMHost, and Set-VsanClusterConfiguration cmdlets
        - The witness host must be accessible and properly configured
        - This function should be called after disk groups are added to the vSAN datastore
        - For ESA: the witness may have zero storage pool disks (supported configuration). Before configuring the witness, the function calls Enable-VsanAutomaticDiskClaimIfSupported to set vSAN automatic disk claim (VsanDiskClaimMode Automatic) when the cmdlet supports it; this applies to both OSA and ESA.
        - When creating fault domains, the first ESX host is assigned to "Primary", remaining host(s) to "Secondary"
        - Witness memory requirements: vSAN-OSA at least 8 GB; vSAN-ESA at least 16 GB
        - Data nodes and the witness must be on the exact same ESX release (same version and build number). The function checks witness and cluster hosts before configuring the witness. If any version or build differs: when LabEnvironment is $true, a WARNING is logged and the workflow continues; when LabEnvironment is $false, the user is prompted (Y/N) and the function throws if they decline.
        - Per the vSAN Stretched Cluster Guide (vmware.com/docs/vsan-stretched-cluster-guide): the witness must not be a member of any cluster; it must reside in vCenter inventory outside the cluster. The function enforces this and throws if the witness is in the cluster.
        - To avoid partition: ensure connectivity between data hosts and witness (vmkping from data hosts to witness vSAN VMkernel; UDP 23451 and 12321 open). The witness must communicate with each data site directly. After configuration, the function re-applies vSAN cluster config and checks for partition.
        - When supported by PowerCLI, Site Read Locality is enabled on the stretched cluster so reads use the local site and reduce inter-site traffic.
        - For full alignment with the guide, after deployment configure HA (admission control 50% for site failure, host isolation response "Power off and restart VMs", isolation addresses on vSAN network) and DRS host/VM groups and rules. See VSAN_CLUSTER_LOGIC_AND_POWERCLI_EXAMPLES.md.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [bool]$LabEnvironment = $false,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$PreferredFaultDomainName,
        [Parameter(Mandatory = $true)] [ValidateSet("vSAN-ESA", "vSAN-OSA")] [String]$StoragePolicyType,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$vSanWitnessVmName
    )

    Write-LogMessage -Type DEBUG -Message "Entered Set-VsanWitness function for cluster: `"$ClusterName`" with witness host: `"$vSanWitnessVmName`", preferred fault domain: `"$PreferredFaultDomainName`", storage type: `"$StoragePolicyType`"."

    # Minimum witness host memory (GB) by vSAN type: OSA 8 GB, ESA 16 GB.
    $minimumWitnessMemoryGB = switch ($StoragePolicyType) {
        "vSAN-OSA" { 8 }
        "vSAN-ESA" { 16 }
        default { 0 }
    }

    $connectionTest = Test-VcenterConnection
    if (-not $connectionTest.IsConnected) {
        Write-LogMessage -Type ERROR -Message "Not connected to vCenter `"$Script:vCenterName`": $($connectionTest.ErrorMessage)"
        throw [VcfDeploymentException]::new("Deployment failed configuring vSAN witness for cluster `"$ClusterName`": not connected to vCenter. $($connectionTest.ErrorMessage)")
    }

    try {
        # Get the cluster object.
        Write-LogMessage -Type DEBUG -Message "Retrieving cluster object for cluster `"$ClusterName`"."
        $cluster = Get-Cluster -Name $ClusterName -Server $Script:vCenterName -ErrorAction Stop
        if (-not $cluster) {
            Write-LogMessage -Type ERROR -Message "Failed to retrieve cluster `"$ClusterName`"."
            throw [VcfDeploymentException]::new("Deployment failed configuring vSAN witness for cluster `"$ClusterName`": cluster not found.")
        }

        # Get the witness host object.
        Write-LogMessage -Type DEBUG -Message "Retrieving witness host object for `"$vSanWitnessVmName`"."
        $witnessHost = Get-VMHost -Name $vSanWitnessVmName -Server $Script:vCenterName -ErrorAction Stop
        if (-not $witnessHost) {
            Write-LogMessage -Type ERROR -Message "Failed to retrieve witness host `"$vSanWitnessVmName`"."
            throw [VcfDeploymentException]::new("Deployment failed configuring vSAN witness for cluster `"$ClusterName`": witness host `"$vSanWitnessVmName`" not found in vCenter. Ensure the witness host is added to vCenter.")
        }

        # Check HostDeployedFromWitnessOVF (set by official witness OVF at firstboot): 1 = OSA witness OVA, 2 = ESA witness OVA. If mismatched, tell the user they deployed the wrong OVA.
        $hostDeployedFromWitnessOvf = $null
        try {
            $advSetting = Get-AdvancedSetting -Entity $witnessHost -Name "VSAN.HostDeployedFromWitnessOVF" -ErrorAction SilentlyContinue
            if ($advSetting -and $null -ne $advSetting.Value) {
                $hostDeployedFromWitnessOvf = [int]$advSetting.Value
                Write-LogMessage -Type DEBUG -Message "Witness host `"$vSanWitnessVmName`" HostDeployedFromWitnessOVF=$hostDeployedFromWitnessOvf (1=OSA witness OVA, 2=ESA witness OVA)."
            }
        } catch {
            Write-LogMessage -Type DEBUG -Message "Could not read HostDeployedFromWitnessOVF from witness `"$vSanWitnessVmName`": $($_.Exception.Message). Skipping OVA-type check."
        }
        if ($null -ne $hostDeployedFromWitnessOvf) {
            if ($StoragePolicyType -eq "vSAN-OSA" -and $hostDeployedFromWitnessOvf -eq 2) {
                Write-LogMessage -Type ERROR -Message "Witness host `"$vSanWitnessVmName`" was deployed from the vSAN ESA witness OVA (HostDeployedFromWitnessOVF=2). For an OSA cluster use the vSAN OSA witness appliance OVA."
                throw [VcfDeploymentException]::new("Deployment failed configuring vSAN witness for cluster `"$ClusterName`": this witness was deployed from the vSAN ESA witness OVA. For an OSA cluster use the vSAN OSA witness appliance OVA (and vice versa for ESA). Redeploy the correct witness OVA and re-run.")
            }
            if ($StoragePolicyType -eq "vSAN-ESA" -and $hostDeployedFromWitnessOvf -eq 1) {
                Write-LogMessage -Type ERROR -Message "Witness host `"$vSanWitnessVmName`" was deployed from the vSAN OSA witness OVA (HostDeployedFromWitnessOVF=1). For an ESA cluster use the vSAN ESA witness appliance OVA."
                throw [VcfDeploymentException]::new("Deployment failed configuring vSAN witness for cluster `"$ClusterName`": this witness was deployed from the vSAN OSA witness OVA. For an ESA cluster use the vSAN ESA witness appliance OVA (and vice versa for OSA). Redeploy the correct witness OVA and re-run.")
            }
        }

        # Fail if witness disk layout does not match requested storage type (OSA vs ESA). Prevents using an OSA witness for ESA or vice versa.
        if ($StoragePolicyType -eq "vSAN-ESA") {
            $witnessOsaResult = Get-VsanOsaDiskGroupsOnHost -VMHost $witnessHost -Server $Script:vCenterName
            if ($witnessOsaResult.HasValidOsaGroup) {
                Write-LogMessage -Type ERROR -Message "Witness host `"$vSanWitnessVmName`" has a vSAN OSA disk group (cache + capacity). This witness is for vSAN OSA, not ESA. Use an ESA witness or remove the OSA disk group from this host."
                throw [VcfDeploymentException]::new("Deployment failed configuring vSAN witness for cluster `"$ClusterName`": witness host `"$vSanWitnessVmName`" has a vSAN OSA disk group (cache + capacity). This witness is for vSAN OSA, not ESA. Use a different host for the ESA witness or remove the OSA disk group from this host. Deployment will roll back.")
            }
        }
        elseif ($StoragePolicyType -eq "vSAN-OSA") {
            $witnessStoragePoolDisksForMismatch = Get-VsanStoragePoolDisk -VMHost $witnessHost -Server $Script:vCenterName -ErrorAction SilentlyContinue
            $witnessEsaPoolCount = if ($witnessStoragePoolDisksForMismatch) { @($witnessStoragePoolDisksForMismatch).Count } else { 0 }
            if ($witnessEsaPoolCount -ge 1) {
                Write-LogMessage -Type ERROR -Message "Witness host `"$vSanWitnessVmName`" has a vSAN ESA storage pool (all-flash). This witness is for vSAN ESA, not OSA. Use an OSA witness or remove the ESA storage pool from this host."
                throw [VcfDeploymentException]::new("Deployment failed configuring vSAN witness for cluster `"$ClusterName`": witness host `"$vSanWitnessVmName`" has a vSAN ESA storage pool (all-flash). This witness is for vSAN ESA, not OSA. Use a different host for the OSA witness or remove the ESA storage pool from this host. Deployment will roll back.")
            }
        }

        # Enforce witness host minimum memory based on storage type (OSA 8 GB, ESA 16 GB).
        $witnessMemoryGB = $witnessHost.MemoryTotalGB
        if ($witnessMemoryGB -lt $minimumWitnessMemoryGB) {
            Write-LogMessage -Type ERROR -Message "Witness host `"$vSanWitnessVmName`" has $witnessMemoryGB GB memory; $StoragePolicyType requires at least $minimumWitnessMemoryGB GB to enable a witness."
            throw [VcfDeploymentException]::new("The witness host `"$vSanWitnessVmName`" has $witnessMemoryGB GB of memory. You must upgrade the witness host to at least $minimumWitnessMemoryGB GB of memory to enable a witness for a $StoragePolicyType cluster.")
        }

        # Enforce witness host disk configuration: ESA may have zero storage pool disks (supported configuration); OSA requires a disk group with one cache and one capacity disk.
        if ($StoragePolicyType -eq "vSAN-ESA") {
            $witnessStoragePoolDisks = Get-VsanStoragePoolDisk -VMHost $witnessHost -Server $Script:vCenterName -ErrorAction SilentlyContinue
            $witnessPoolDiskCount = if ($witnessStoragePoolDisks) { @($witnessStoragePoolDisks).Count } else { 0 }
            Write-LogMessage -Type DEBUG -Message "Witness host `"$vSanWitnessVmName`" has $witnessPoolDiskCount vSAN ESA storage pool disk(s). ESA witness with zero disks is supported."
        }
        elseif ($StoragePolicyType -eq "vSAN-OSA") {
            # Use HostVsanSystem API so witness is validated even when not in a cluster (Get-VsanDiskGroup requires cluster membership).
            $witnessOsaResult = Get-VsanOsaDiskGroupsOnHost -VMHost $witnessHost -Server $Script:vCenterName
            if ($witnessOsaResult.DiskGroupCount -lt 1) {
                Write-LogMessage -Type ERROR -Message "Witness host `"$vSanWitnessVmName`" has no vSAN OSA disk group. A vSAN witness for OSA requires a disk group with one cache and one capacity disk. Create a disk group on the witness host, then re-run."
                throw [VcfDeploymentException]::new("Deployment failed configuring vSAN witness for cluster `"$ClusterName`": witness host `"$vSanWitnessVmName`" has no vSAN OSA disk group. Create a disk group with one cache (SSD) and one capacity disk on the witness host, then re-run.")
            }
            if (-not $witnessOsaResult.HasValidOsaGroup) {
                Write-LogMessage -Type ERROR -Message "Witness host `"$vSanWitnessVmName`" has vSAN OSA disk group(s) but none has both cache and capacity. A vSAN witness for OSA requires one cache (SSD) and one capacity disk. Add the required disks to a disk group on the witness host, then re-run."
                throw [VcfDeploymentException]::new("Deployment failed configuring vSAN witness for cluster `"$ClusterName`": witness host `"$vSanWitnessVmName`" disk group(s) do not have both cache and capacity disk. Create or update a disk group with one cache (SSD) and one capacity disk, then re-run.")
            }
            Write-LogMessage -Type DEBUG -Message "Witness host `"$vSanWitnessVmName`" has $($witnessOsaResult.DiskGroupCount) vSAN OSA disk group(s) with valid cache and capacity."
        }

        # Ensure the witness host has at least one VMkernel with vSAN traffic enabled (required for witness participation).
        # Do not add witness traffic type (-T witness) on the witness host; only data hosts get esxcli vsan network ip add -i vmkx -T witness (Broadcom stretched cluster doc).
        $witnessVsanCheck = Test-VmkernelVsanAndWitnessTraffic -VMHost $witnessHost -RequireWitnessTraffic $false
        if (-not $witnessVsanCheck.HasCompliantInterface -and $witnessVsanCheck.Vmk0Adapter) {
            try {
                # Witness host only needs vSAN traffic on vmk0; do not set witness traffic type on the witness host (per Broadcom: do not configure the witness traffic type on the witness host).
                $witnessSetParams = @{ VirtualNic = $witnessVsanCheck.Vmk0Adapter; VsanTrafficEnabled = $true }
                Set-VMHostNetworkAdapter @witnessSetParams -Confirm:$false -ErrorAction Stop | Out-Null
                Write-LogMessage -Type INFO -Message "vSAN witness host `"$vSanWitnessVmName`" had no VMkernel with vSAN traffic enabled; vSAN traffic has been enabled on vmk0."
            } catch [VcfDeploymentException] {
                throw  # already logged and typed — propagate without re-wrapping
            } catch {
                Write-LogMessage -Type ERROR -Message "Failed to enable vSAN traffic on vmk0 on witness host `"$vSanWitnessVmName`": $($_.Exception.Message). vSAN traffic is required for the witness; deployment will roll back."
                throw [VcfDeploymentException]::new("vSAN traffic is required for the witness host. Could not ensure an interface is tagged for vSAN traffic on witness `"$vSanWitnessVmName`". Deployment will roll back.")
            }
            $witnessRecheck = Test-VmkernelVsanAndWitnessTraffic -VMHost $witnessHost -RequireWitnessTraffic $false
            if (-not $witnessRecheck.HasCompliantInterface) {
                Write-LogMessage -Type ERROR -Message "After enabling vSAN traffic on witness host `"$vSanWitnessVmName`", interface is still not tagged. vSAN traffic is required for the witness; deployment will roll back."
                throw [VcfDeploymentException]::new("vSAN traffic is required for the witness host. Could not ensure an interface is tagged for vSAN traffic on witness `"$vSanWitnessVmName`". Deployment will roll back.")
            }
        }
        elseif (-not $witnessVsanCheck.HasCompliantInterface) {
            Write-LogMessage -Type ERROR -Message "Witness host `"$vSanWitnessVmName`" has no VMkernel with vSAN traffic enabled and vmk0 was not found. vSAN traffic is required for the witness; deployment will roll back."
            throw [VcfDeploymentException]::new("vSAN traffic is required for the witness host. Witness `"$vSanWitnessVmName`" has no VMkernel with vSAN traffic enabled (vmk0 not found). Enable vSAN traffic on at least one VMkernel on the witness host, then re-run. Deployment will roll back.")
        }

        # Get all hosts in the cluster and select the first one as the preferred fault domain host.
        Write-LogMessage -Type DEBUG -Message "Retrieving ESX hosts in cluster `"$ClusterName`"."
        $clusterHosts = Get-VMHost -Location $cluster -Server $Script:vCenterName -ErrorAction Stop
        if (-not $clusterHosts -or $clusterHosts.Count -eq 0) {
            Write-LogMessage -Type ERROR -Message "Cluster `"$ClusterName`" does not contain any hosts."
            throw [VcfDeploymentException]::new("Deployment failed configuring vSAN witness for cluster `"$ClusterName`": cluster has no hosts.")
        }

        # Require exact same ESX release (version and build) on all data hosts and the witness. A different build on the witness can cause vSAN stretched cluster issues; fail early and let the caller roll back.
        $witnessVersion = $null
        $witnessBuild = $null
        if ($witnessHost.PSObject.Properties['Version']) { $witnessVersion = [string]$witnessHost.Version }
        if ([String]::IsNullOrWhiteSpace($witnessVersion) -and $witnessHost.ExtensionData -and $witnessHost.ExtensionData.Config -and $witnessHost.ExtensionData.Config.Product) { $witnessVersion = [string]$witnessHost.ExtensionData.Config.Product.Version }
        if ($witnessHost.PSObject.Properties['Build']) { $witnessBuild = [string]$witnessHost.Build }
        if ([String]::IsNullOrWhiteSpace($witnessBuild) -and $witnessHost.ExtensionData -and $witnessHost.ExtensionData.Config -and $witnessHost.ExtensionData.Config.Product) { $witnessBuild = [string]$witnessHost.ExtensionData.Config.Product.Build }
        $referenceHost = $clusterHosts[0]
        $refVersion = $null
        $refBuild = $null
        if ($referenceHost.PSObject.Properties['Version']) { $refVersion = [string]$referenceHost.Version }
        if ([String]::IsNullOrWhiteSpace($refVersion) -and $referenceHost.ExtensionData -and $referenceHost.ExtensionData.Config -and $referenceHost.ExtensionData.Config.Product) { $refVersion = [string]$referenceHost.ExtensionData.Config.Product.Version }
        if ($referenceHost.PSObject.Properties['Build']) { $refBuild = [string]$referenceHost.Build }
        if ([String]::IsNullOrWhiteSpace($refBuild) -and $referenceHost.ExtensionData -and $referenceHost.ExtensionData.Config -and $referenceHost.ExtensionData.Config.Product) { $refBuild = [string]$referenceHost.ExtensionData.Config.Product.Build }
        $versionMismatch = $false
        $mismatchDetail = $null
        if ([String]::IsNullOrWhiteSpace($witnessVersion) -or [String]::IsNullOrWhiteSpace($refVersion)) {
            Write-LogMessage -Type WARNING -Message "Could not read ESX version for version check (witness or cluster host). Skipping strict version check."
        } else {
            if ($witnessVersion -ne $refVersion) {
                $versionMismatch = $true
                $mismatchDetail = "Witness `"$vSanWitnessVmName`" has ESX version `"$witnessVersion`" (build $witnessBuild); cluster data hosts have version `"$refVersion`" (build $refBuild). All must be the same release."
            }
            if (-not $versionMismatch -and -not [String]::IsNullOrWhiteSpace($witnessBuild) -and -not [String]::IsNullOrWhiteSpace($refBuild) -and $witnessBuild -ne $refBuild) {
                $versionMismatch = $true
                $mismatchDetail = "Witness `"$vSanWitnessVmName`" has ESX build `"$witnessBuild`" (version $witnessVersion); cluster data hosts have build `"$refBuild`" (version $refVersion). Data nodes and witness must be the exact same ESX release (same build number)."
            }
            if (-not $versionMismatch) {
                foreach ($dataHost in @($clusterHosts)) {
                    $dv = if ($dataHost.PSObject.Properties['Version']) { [string]$dataHost.Version } else { $null }
                    if ([String]::IsNullOrWhiteSpace($dv) -and $dataHost.ExtensionData -and $dataHost.ExtensionData.Config -and $dataHost.ExtensionData.Config.Product) { $dv = [string]$dataHost.ExtensionData.Config.Product.Version }
                    $db = if ($dataHost.PSObject.Properties['Build']) { [string]$dataHost.Build } else { $null }
                    if ([String]::IsNullOrWhiteSpace($db) -and $dataHost.ExtensionData -and $dataHost.ExtensionData.Config -and $dataHost.ExtensionData.Config.Product) { $db = [string]$dataHost.ExtensionData.Config.Product.Build }
                    if (-not [String]::IsNullOrWhiteSpace($dv) -and $dv -ne $refVersion) {
                        $versionMismatch = $true
                        $mismatchDetail = "Cluster host `"$($dataHost.Name)`" has ESX version `"$dv`" (build $db); expected same as reference version `"$refVersion`" (build $refBuild). All data hosts and witness must be the same release."
                        break
                    }
                    if (-not [String]::IsNullOrWhiteSpace($db) -and -not [String]::IsNullOrWhiteSpace($refBuild) -and $db -ne $refBuild) {
                        $versionMismatch = $true
                        $mismatchDetail = "Cluster host `"$($dataHost.Name)`" has ESX build `"$db`"; expected build `"$refBuild`" (version $refVersion). All data hosts and witness must be the exact same ESX release."
                        break
                    }
                }
            }
        }
        if ($versionMismatch -and $mismatchDetail) {
            if ($LabEnvironment) {
                Write-LogMessage -Type WARNING -Message "ESX version/build mismatch (lab environment; continuing without prompt): $mismatchDetail."
                $continueAnyway = $true
            } else {
                Write-LogMessage -Type ERROR -Message "ESX version/build mismatch: $mismatchDetail."
                $continuePrompt = "Witness and data hosts have different ESX builds. Continue anyway? (Y/N; press Enter for N)"
                $continueAnyway = $false
                try {
                    do {
                        $response = Read-Host $continuePrompt
                        $response = if ($response) { $response.Trim() } else { "" }
                        if ($response -match '^[yY](es)?$') {
                            $continueAnyway = $true
                            Write-LogMessage -Type WARNING -Message "User chose to continue despite witness/data host ESX build mismatch. Proceeding with vSAN witness configuration."
                            break
                        }
                        if ([String]::IsNullOrWhiteSpace($response) -or $response -match '^[nN](o)?$') {
                            break
                        }
                        Write-LogMessage -Type WARNING -Message "Invalid response. Please enter Y or N (or press Enter for N)."
                    } while ($true)
                } catch {
                    Write-LogMessage -Type WARNING -Message "Read-Host failed (non-interactive?): $($_.Exception.Message). Treating as N; deployment will fail."
                }
            }
            if (-not $continueAnyway) {
                throw "Deployment failed configuring vSAN witness for cluster `"$ClusterName`": $mismatchDetail Upgrade or patch the witness and data hosts to the same ESX release (same build number), then re-run. The deployment will be rolled back."
            }
        } else {
            Write-LogMessage -Type DEBUG -Message "Witness and cluster hosts have matching ESX release (version $refVersion, build $refBuild)."
        }

        # Per vSAN Stretched Cluster Guide: the witness host must not be a member of any cluster. It resides in vCenter inventory but not in the cluster. Having the witness in the cluster can cause partitioning or undefined behavior.
        $witnessMoRefValue = $null
        if ($witnessHost.ExtensionData -and $witnessHost.ExtensionData.MoRef) {
            $witnessMoRefValue = $witnessHost.ExtensionData.MoRef.Value
        }
        $witnessIsInCluster = $false
        if ($witnessMoRefValue) {
            $witnessIsInCluster = @($clusterHosts | Where-Object { $_.ExtensionData -and $_.ExtensionData.MoRef -and $_.ExtensionData.MoRef.Value -eq $witnessMoRefValue }).Count -gt 0
        }
        if (-not $witnessIsInCluster) {
            $witnessIsInCluster = @($clusterHosts | Where-Object { $_.Id -eq $witnessHost.Id -or $_.Name -eq $witnessHost.Name }).Count -gt 0
        }
        if ($witnessIsInCluster) {
            Write-LogMessage -Type ERROR -Message "Witness host `"$vSanWitnessVmName`" is a member of cluster `"$ClusterName`". Per the vSAN Stretched Cluster Guide, the witness must not be a member of any cluster; it must reside in vCenter inventory outside the cluster. Remove the witness host from the cluster, then re-run."
            throw [VcfDeploymentException]::new("Deployment failed configuring vSAN witness for cluster `"$ClusterName`": witness host must not be a member of the cluster. Remove the witness from the cluster and add it to the data center (or folder) outside the cluster, then re-run.")
        }

        # Ensure every cluster host has vSAN (and witness) traffic; vmk0 is mgmt + vSAN witness only (no vSAN). Clear only vSAN from vmk0 if present.
        foreach ($dataHost in @($clusterHosts)) {
            $dataHostName = $dataHost.Name
            $vmk0 = Get-VMHostNetworkAdapter -VMHost $dataHost -VMKernel -Server $Script:vCenterName -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq "vmk0" }
            if ($vmk0 -and $vmk0.PSObject.Properties["VsanTrafficEnabled"] -and $vmk0.VsanTrafficEnabled -eq $true) {
                try {
                    Set-VMHostNetworkAdapter -VirtualNic $vmk0 -VsanTrafficEnabled $false -Confirm:$false -ErrorAction Stop | Out-Null
                    Write-LogMessage -Type INFO -Message "Cleared vSAN traffic from mgmt (vmk0) on host `"$dataHostName`" (vmk0 is mgmt + vSAN witness only)."
                } catch {
                    Write-LogMessage -Type WARNING -Message "Could not clear vSAN from vmk0 on host `"$dataHostName`": $($_.Exception.Message). Clear manually if needed."
                }
            }
            $vsanCheck = Test-VmkernelVsanAndWitnessTraffic -VMHost $dataHost
            if (-not $vsanCheck.HasCompliantInterface) {
                Write-LogMessage -Type ERROR -Message "Cluster host `"$dataHostName`" has no VMkernel with vSAN and vSAN witness traffic enabled. Use vmk2 (or vmk3) for vSAN; vmk0 may carry vSAN witness only."
                throw [VcfDeploymentException]::new("Deployment failed configuring vSAN witness for cluster `"$ClusterName`": cluster host `"$dataHostName`" requires at least one VMkernel with vSAN (e.g. vmk2) and at least one with vSAN witness (vmk0 or vmk3). Configure networkingVmKernelInterfaces and ensure VMkernels exist. Check logs for details.")
            }
            if (-not (Test-VsanTrafficVmkernelHasValidIp -VMHost $dataHost)) {
                Write-LogMessage -Type ERROR -Message "Cluster host `"$dataHostName`" has vSAN traffic enabled but the VMkernel has no IPv4 or IPv6 address configured."
                throw [VcfDeploymentException]::new("Deployment failed configuring vSAN witness for cluster `"$ClusterName`": neither IPv4 nor IPv6 is properly configured for vSAN traffic on all hosts. On host `"$dataHostName`", the VMkernel(s) with vSAN traffic have no IP. Configure a static IPv4 (or IPv6) on the dedicated vSAN VMkernel (e.g. vmk2) on each cluster host, then re-run.")
            }
        }

        $preferredHost = $clusterHosts[0]
        Write-LogMessage -Type DEBUG -Message "Using first ESX host `"$($preferredHost.Name)`" as preferred fault domain host."

        # Get the current vSAN cluster configuration.
        Write-LogMessage -Type DEBUG -Message "Retrieving current vSAN cluster configuration for cluster `"$ClusterName`"."
        $vsanClusterConfig = Get-VsanClusterConfiguration -Cluster $ClusterName -Server $Script:vCenterName -ErrorAction Stop
        if (-not $vsanClusterConfig) {
            Write-LogMessage -Type ERROR -Message "Failed to retrieve vSAN cluster configuration for cluster `"$ClusterName`"."
            throw [VcfDeploymentException]::new("Deployment failed configuring vSAN witness for cluster `"$ClusterName`": vSAN cluster configuration not available.")
        }

        # Check if witness host is already configured.
        if ($vsanClusterConfig.WitnessHost -and $vsanClusterConfig.WitnessHost.Name -eq $vSanWitnessVmName) {
            Write-LogMessage -Type INFO -Message "Witness host `"$vSanWitnessVmName`" is already configured for cluster `"$ClusterName`"."
            return
        }

        # Resolve preferred fault domain object for stretched cluster (API requires both witness host and preferred fault domain).
        # Suppress VMHost.State deprecation warning; PowerCLI vSAN cmdlets may read deprecated .State when given VMHost. We use ConnectionState in our code.
        $previousWarningPreference = $WarningPreference
        $WarningPreference = 'SilentlyContinue'
        try {
            $preferredFaultDomain = $null
            $primaryFaultDomainName = "Primary"
            $secondaryFaultDomainName = "Secondary"
            try {
                # Resolve by "Primary" first (our created naming), then by caller-provided name (e.g. edge site), then by VMHost.
                $preferredFaultDomain = Get-VsanFaultDomain -Cluster $cluster -Name $primaryFaultDomainName -Server $Script:vCenterName -ErrorAction SilentlyContinue | Select-Object -First 1
                if (-not $preferredFaultDomain -and $PreferredFaultDomainName -ne $primaryFaultDomainName) {
                    $preferredFaultDomain = Get-VsanFaultDomain -Cluster $cluster -Name $PreferredFaultDomainName -Server $Script:vCenterName -ErrorAction SilentlyContinue | Select-Object -First 1
                }
                if (-not $preferredFaultDomain) {
                    $preferredFaultDomain = Get-VsanFaultDomain -Cluster $cluster -VMHost $preferredHost -Server $Script:vCenterName -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($preferredFaultDomain) {
                        Write-LogMessage -Type DEBUG -Message "Resolved preferred fault domain by VMHost: `"$($preferredFaultDomain.Name)`" (Id: $($preferredFaultDomain.Id))."
                    }
                } else {
                    Write-LogMessage -Type DEBUG -Message "Resolved preferred fault domain by name: `"$($preferredFaultDomain.Name)`" (Id: $($preferredFaultDomain.Id))."
                }
            } catch {
                Write-LogMessage -Type DEBUG -Message "Could not resolve VsanFaultDomain (Get-VsanFaultDomain): $($_.Exception.Message). Proceeding without -PreferredFaultDomain."
            }

        # If no fault domains exist, create them for stretched cluster. Preferred (first host) is named "Primary"; the other is "Secondary" for consistent UI and resolution.
        if (-not $preferredFaultDomain) {
            $existingFaultDomains = Get-VsanFaultDomain -Cluster $cluster -Server $Script:vCenterName -ErrorAction SilentlyContinue
            if (-not $existingFaultDomains -or $existingFaultDomains.Count -eq 0) {
                $preferredFdCreateName = $primaryFaultDomainName
                Write-LogMessage -Type INFO -Message "No vSAN fault domains found for cluster `"$ClusterName`". Creating FDs `"$preferredFdCreateName`" and `"$secondaryFaultDomainName`"."
                try {
                    New-VsanFaultDomain -Name $preferredFdCreateName -VMHost $preferredHost -Server $Script:vCenterName -ErrorAction Stop | Out-Null
                    Write-LogMessage -Type DEBUG -Message "Created fault domain `"$preferredFdCreateName`" (preferred) with host `"$($preferredHost.Name)`"."
                    $remainingHosts = $clusterHosts | Where-Object { $_.Id -ne $preferredHost.Id }
                    if ($remainingHosts -and $remainingHosts.Count -gt 0) {
                        New-VsanFaultDomain -Name $secondaryFaultDomainName -VMHost $remainingHosts -Server $Script:vCenterName -ErrorAction Stop | Out-Null
                        Write-LogMessage -Type DEBUG -Message "Created fault domain `"$secondaryFaultDomainName`" with host(s): $(($remainingHosts | ForEach-Object { $_.Name }) -join ', ')."
                    }
                    $preferredFaultDomain = Get-VsanFaultDomain -Cluster $cluster -Name $preferredFdCreateName -Server $Script:vCenterName -ErrorAction Stop | Select-Object -First 1
                    if ($preferredFaultDomain) {
                        Write-LogMessage -Type DEBUG -Message "Resolved preferred fault domain after creation: `"$($preferredFaultDomain.Name)`" (Id: $($preferredFaultDomain.Id))."
                    }
                } catch [VcfDeploymentException] {
                    throw  # already logged and typed — propagate without re-wrapping
                } catch {
                    Write-LogMessage -Type ERROR -Message "Failed to create vSAN fault domains for cluster `"$ClusterName`": $($_.Exception.Message)"
                    throw [VcfDeploymentException]::new("Deployment failed configuring vSAN witness for cluster `"$ClusterName`": could not create fault domains. $($_.Exception.Message)")
                }
            } else {
                Write-LogMessage -Type WARNING -Message "Could not resolve VsanFaultDomain for name `"$primaryFaultDomainName`" or `"$PreferredFaultDomainName`" or for host `"$($preferredHost.Name)`". Cluster has $($existingFaultDomains.Count) fault domain(s) but none match. Ensure preferred fault domain name matches an existing fault domain or create fault domains with New-VsanFaultDomain. Set-VsanClusterConfiguration may fail with preferred fault domain not specified."
            }
        }

        # Enable vSAN automatic disk claim (VsanDiskClaimMode Automatic) when supported (OSA and ESA). Re-fetch config if we changed it.
        if (Enable-VsanAutomaticDiskClaimIfSupported -ClusterName $ClusterName) {
            $vsanClusterConfig = Get-VsanClusterConfiguration -Cluster $ClusterName -Server $Script:vCenterName -ErrorAction Stop
        }

        # Configure the vSAN witness host and stretched cluster. API requires both -WitnessHost and -PreferredFaultDomain when enabling stretched cluster.
        # Per vSAN Stretched Cluster Guide: validate connectivity between data hosts and witness before/after configuration to avoid partition. Use vmkping from each data site to the witness vSAN VMkernel IP; ensure UDP 23451 (vSAN clustering) and 12321 (unicast agent to witness) are open. The witness must communicate with each data site directly, not through the other site.
        Write-LogMessage -Type INFO -Message "Ensure connectivity between cluster hosts and witness through vSAN Witness VMkernel interface."
        if (-not $preferredFaultDomain) {
            Write-LogMessage -Type WARNING -Message "Preferred fault domain not resolved. Set-VsanClusterConfiguration may fail with preferred fault domain not specified."
        }
        Write-LogMessage -Type DEBUG -Message "Attempting Set-VsanClusterConfiguration for cluster `"$ClusterName`" with vSanWitnessVmName=`"$vSanWitnessVmName`", preferred fault domain host=`"$($preferredHost.Name)`", PreferredFaultDomain resolved=$($null -ne $preferredFaultDomain)."
        Write-LogMessage -Type INFO -Message "Enabling stretched cluster mode and configuring witness host `"$vSanWitnessVmName`" for cluster `"$ClusterName`"..."
        $progressActivity = "Configuring vSAN witness for cluster `"$ClusterName`""
        try {
            Write-Progress -Activity $progressActivity -Status "Enabling stretched cluster mode and configuring witness host. This may take several minutes..." -PercentComplete -1
            [Console]::Out.Flush()
            $setParams = @{
                Configuration            = $vsanClusterConfig
                StretchedClusterEnabled  = $true
                WitnessHost              = $witnessHost
                Server                   = $Script:vCenterName
            }
            if ($preferredFaultDomain) {
                $setParams["PreferredFaultDomain"] = $preferredFaultDomain
            }
            # Per vSAN Stretched Cluster Guide: enable Site Read Locality so reads come from the local site and reduce traffic across the ISL.
            if ((Get-Command Set-VsanClusterConfiguration -ErrorAction SilentlyContinue).Parameters.ContainsKey("SiteReadLocalityEnabled")) {
                $setParams["SiteReadLocalityEnabled"] = $true
                Write-LogMessage -Type DEBUG -Message "Enabling Site Read Locality on stretched cluster per vSAN Stretched Cluster Guide."
            }
            Set-VsanClusterConfiguration @setParams -ErrorAction Stop | Out-Null
        }
        finally {
            Write-Progress -Activity $progressActivity -Status "Complete" -Completed
            [Console]::Out.Flush()
        }
        # Verify the configuration was applied.
        $updatedConfig = Get-VsanClusterConfiguration -Cluster $ClusterName -Server $Script:vCenterName -ErrorAction SilentlyContinue
        if ($updatedConfig -and $updatedConfig.WitnessHost -and $updatedConfig.WitnessHost.Name -eq $vSanWitnessVmName) {
            Write-LogMessage -Type INFO -Message "Successfully configured witness host `"$vSanWitnessVmName`" for cluster `"$ClusterName`"."
            # Enable vSAN automatic rebalancing at 30% then re-apply vSAN cluster configuration so vCenter pushes config to all hosts including the witness.
            $rebalanceEnabled = Enable-VsanAutomaticRebalance -ClusterName $ClusterName -AutomaticRebalanceThreshold 30
            if ($rebalanceEnabled -and -not (Test-VsanAutomaticRebalanceAtThreshold -ClusterName $ClusterName -ExpectedThresholdPercent 30)) {
                Write-LogMessage -Type DEBUG -Message "vSAN automatic rebalance at 30% may not be applied on cluster `"$ClusterName`"; config re-apply will push cluster settings."
            }
            $reapplySucceeded = Invoke-VsanClusterConfigReapply -ClusterName $ClusterName
            if ($reapplySucceeded) {
                Write-LogMessage -Type DEBUG -Message "Re-applied vSAN config after witness setup to help witness sync with cluster (reduce partition risk)."
            }
            # Check for partition per vSAN Stretched Cluster Guide; if connectivity or routing is wrong, the cluster can end up in multiple partitions.
            $healthSummary = Get-VsanClusterHealthSummaryViaView -ClusterName $ClusterName -FetchFromCache $true
            if ($healthSummary -and (Test-VsanClusterPartitioned -HealthSummary $healthSummary)) {
                Write-LogMessage -Type ERROR -Message "vSAN cluster `"$ClusterName`" appears partitioned after witness configuration. Ensure the witness is at a third site, data hosts can reach the witness vSAN VMkernel (vmkping), and UDP 23451/12321 are allowed. See vSAN Stretched Cluster Guide (vmware.com/docs/vsan-stretched-cluster-guide)."
            }
        } else {
            Write-LogMessage -Type WARNING -Message "Witness host configuration may not have been applied correctly. Verification failed."
        }
        }
        finally {
            $WarningPreference = $previousWarningPreference
        }
    }
    catch [System.UnauthorizedAccessException] {
        $errorMessage = $_.Exception.Message
        $reason = Get-CleanVsanErrorMessage -ErrorMessage $errorMessage
        if ($reason -eq $errorMessage) { $reason = "authorization error. $errorMessage" }
        $cleanMessage = "Failed to configure vSAN witness for cluster `"$ClusterName`". Reason: $reason"
        Write-LogMessage -Type ERROR -Message $cleanMessage
        throw [VcfDeploymentException]::new("Deployment failed. $cleanMessage")
    }
    catch [System.TimeoutException] {
        $errorMessage = $_.Exception.Message
        $reason = Get-CleanVsanErrorMessage -ErrorMessage $errorMessage
        if ($reason -eq $errorMessage) { $reason = "network/timeout. $errorMessage" }
        $cleanMessage = "Failed to configure vSAN witness for cluster `"$ClusterName`". Reason: $reason"
        Write-LogMessage -Type ERROR -Message $cleanMessage
        throw [VcfDeploymentException]::new("Deployment failed. $cleanMessage")
    } catch {
        $errorMessage = $_.Exception.Message
        $reason = Get-CleanVsanErrorMessage -ErrorMessage $errorMessage
        $cleanMessage = "Failed to configure vSAN witness for cluster `"$ClusterName`". Reason: $reason"
        Write-LogMessage -Type ERROR -Message $cleanMessage
        if ($errorMessage -match "preferred fault domain|witness host is not specified|witness.*not specified") {
            Write-LogMessage -Type ERROR -Message "vSAN stretched cluster requires both a witness host and a preferred fault domain. Ensure common.vSanWitnessVmName (or cluster-level clusters[].vSanWitnessVmName) and the preferred fault domain name (e.g. edge site name) are set. If the API still reports missing preferred fault domain, the PowerCLI/API version may not expose it; check VCF PowerCLI documentation for Set-VsanClusterConfiguration."
        }
        throw "Deployment failed. $cleanMessage"
    }
}
Function Get-VsanClusterHealthSummaryViaView {

    <#
        .SYNOPSIS
        Retrieves vSAN cluster health summary using Get-VsanView and the vSAN Health API.

        .DESCRIPTION
        Gets the VsanVcClusterHealthSystem view and calls VsanQueryVcClusterHealthSummary for the
        specified cluster. Used by Invoke-VsanClusterHealthCheckAfterWitness to check overall health
        and partition status.

        .PARAMETER ClusterName
        The name of the vSAN cluster. Must be a non-empty string.

        .PARAMETER FetchFromCache
        If true, returns cached health result (fast). If false, runs a full health check (slower).
        Default is false for an accurate post-witness check.

        .OUTPUTS
        VsanClusterHealthSummary object, or $null if the health query fails.

        .NOTES
        Requires connection to vCenter. Uses Get-VsanView and VsanQueryVcClusterHealthSummary (VCF PowerCLI 9).
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [bool]$FetchFromCache = $false
    )

    $clusterObject = Get-Cluster -Name $ClusterName -Server $Script:vCenterName -ErrorAction SilentlyContinue
    # Validate cluster exists before proceeding.
    if (-not $clusterObject) {
        Write-LogMessage -Type ERROR -Message "Cluster `"$ClusterName`" not found."
        return $null
    }

    # Get the cluster MoRef and vSAN health system view.
    $clusterMoRef = $clusterObject.ExtensionData.MoRef
    $healthSystemView = Get-VsanView -Id "VsanVcClusterHealthSystem-vsan-cluster-health-system" -Server $Script:vCenterName -ErrorAction SilentlyContinue
    if (-not $healthSystemView) {
        Write-LogMessage -Type ERROR -Message "Failed to get VsanVcClusterHealthSystem view."
        return $null
    }

    # Get the requested fields for the health summary (include advCfgSync for vCenter-to-host config sync check).
    $requestedFields = @('advCfgSync', 'groups', 'networkHealth', 'overallHealth', 'overallHealthDescription')
    try {
        # Call the vSAN health API to get the health summary.
        $healthSummary = $healthSystemView.VsanQueryVcClusterHealthSummary($clusterMoRef, $null, $null, $null, $requestedFields, $FetchFromCache, $null, $null, $null)
        return $healthSummary
    }
    # Handle any errors that occur while calling the vSAN health API.
    catch {
        Write-LogMessage -Type ERROR -Message "VsanQueryVcClusterHealthSummary failed: $($_.Exception.Message)"
        Write-LogMessage -Type DEBUG -Message "vSAN health summary unavailable; caller will log health_summary_null next steps. Verify vCenter connection and cluster name; ensure VsanVcClusterHealthSystem (vCenter /vsanHealth) is available."
        return $null
    }
}
Function Test-VsanClusterPartitioned {

    <#
        .SYNOPSIS
        Determines whether the vSAN cluster health summary indicates a cluster partition.

        .DESCRIPTION
        Checks the VsanClusterHealthSummary for partition-related findings (e.g. Server cluster
        partition check, or overall/network health description mentioning partition).
        Returns $true if the cluster is considered partitioned.

        .PARAMETER HealthSummary
        The VsanClusterHealthSummary object returned by Get-VsanClusterHealthSummaryViaView.

        .OUTPUTS
        Boolean. $true if partitioned, $false otherwise.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] $HealthSummary
    )

    # Null or invalid summary: treat as not partitioned.
    if (-not $HealthSummary) {
        return $false
    }

    # Authoritative check: VsanClusterNetworkHealthResult.partitions (vSAN API). Multiple partition entries = cluster partitioned.
    $networkHealth = $HealthSummary.networkHealth
    if ($networkHealth) {
        $partitions = $networkHealth.partitions
        if ($partitions -and ($partitions.Count -ge 2)) {
            return $true
        }

        # Hosts in vSAN but not in vCenter cluster, or comm failure/disconnected, indicate partition or sync issue.
        $otherHosts = $networkHealth.otherHostsInVsanCluster
        if ($otherHosts -and ($otherHosts.Count -gt 0)) {
            return $true
        }
        $hostsCommFailure = $networkHealth.hostsCommFailure
        if ($hostsCommFailure -and ($hostsCommFailure.Count -gt 0)) {
            return $true
        }
        $hostsDisconnected = $networkHealth.hostsDisconnected
        if ($hostsDisconnected -and ($hostsDisconnected.Count -gt 0)) {
            return $true
        }

        # Network health status/description fallback: if not green and description mentions partition.
        $networkStatus = $networkHealth.status
        if ($networkStatus -and $networkStatus -ne 'green') {
            $networkDescription = $networkHealth.description
            if ($networkDescription -and ($networkDescription -match 'partition')) {
                return $true
            }
        }
    }

    # Fallback: overall health description for partition wording (e.g. "multiple partitions detected").
    $overallDescription = $HealthSummary.overallHealthDescription
    if ($overallDescription -and ($overallDescription -match 'partition')) {
        return $true
    }

    # Walk health groups and their tests; if any group or test name mentions "partition" and status is not green, partitioned.
    $healthGroups = $HealthSummary.groups
    if (-not $healthGroups) {
        return $false
    }

    foreach ($healthGroup in $healthGroups) {
        # Use PSObject.Properties because the API may return dynamic objects without direct property access.
        $groupName = $healthGroup.PSObject.Properties['groupName'].Value
        if ($groupName -and ($groupName -match 'partition')) {
            $groupHealthStatus = $healthGroup.PSObject.Properties['health'].Value
            if ($groupHealthStatus -and $groupHealthStatus -ne 'green') {
                return $true
            }
        }
        $groupTests = $healthGroup.PSObject.Properties['tests'].Value
        if ($groupTests) {
            foreach ($healthTest in $groupTests) {
                $testName = $healthTest.PSObject.Properties['testName'].Value
                if ($testName -and ($testName -match 'partition')) {
                    $testStatus = $healthTest.PSObject.Properties['health'].Value
                    if (-not $testStatus) { $testStatus = $healthTest.PSObject.Properties['status'].Value }
                    if ($testStatus -and $testStatus -ne 'green') {
                        return $true
                    }
                }
            }
        }
    }

    # No partition indicators found in overall, network, or group health.
    return $false
}
Function Write-VsanHealthFailureDebugInfo {

    <#
        .SYNOPSIS
        Writes DEBUG log entries with vSAN health/partition details and suggested next steps for troubleshooting.

        .DESCRIPTION
        When the vSAN health check fails or reports partition, this logs API-level details (partitions,
        hostsCommFailure, hostsDisconnected, etc.) and next steps so support can determine corrective action.

        .PARAMETER ClusterName
        The vSAN cluster name (for next-step messages).

        .PARAMETER Context
        Short context: 'partition_detected', 'partition_after_repair', 'health_red', 'health_summary_null', 'repair_failed'.

        .PARAMETER HealthSummary
        Current VsanClusterHealthSummary when available (null for health_summary_null or repair_failed).
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateSet('partition_detected', 'partition_after_repair', 'health_red', 'health_summary_null', 'repair_failed')] [String]$Context,
        [Parameter(Mandatory = $false)] $HealthSummary
    )

    $networkHealth = if ($HealthSummary -and $HealthSummary.networkHealth) { $HealthSummary.networkHealth } else { $null }
    if ($networkHealth) {
        # Report network diagnostics when partition context (per VsanClusterNetworkHealthResult API).
        if ($Context -match 'partition') {
            $pingOk = $networkHealth.pingTestSuccess
            $largePingOk = $networkHealth.largePingTestSuccess
            $issueFound = $networkHealth.issueFound
            $unicast = $networkHealth.clusterInUnicastMode
            $vmknicPresent = $networkHealth.vsanVmknicPresent
            $diagParts = @()
            if ($null -ne $pingOk) {
                $diagParts += "pingTestSuccess=$pingOk"
            }
            if ($null -ne $largePingOk) {
                $diagParts += "largePingTestSuccess=$largePingOk"
            }
            if ($null -ne $issueFound) {
                $diagParts += "issueFound=$issueFound"
            }
            if ($null -ne $unicast) {
                $diagParts += "clusterInUnicastMode=$unicast"
            }
            if ($null -ne $vmknicPresent) {
                $diagParts += "vsanVmknicPresent=$vmknicPresent"
            }
            if ($diagParts.Count -gt 0) {
                Write-LogMessage -Type WARNING -Message "vSAN cluster `"$ClusterName`" network health: $($diagParts -join ', ')."
            }
        }

        # Partition list: log partition IDs per partition (host names not resolved).
        $partitions = $networkHealth.partitions
        $partitionsCount = if ($partitions) { $partitions.Count } else { 0 }
        Write-LogMessage -Type DEBUG -Message "vSAN health debug: networkHealth.partitions count=$partitionsCount."
        if ($partitions -and $partitions.Count -gt 0) {
            $partitionSummaries = @()
            for ($index = 0; $index -lt $partitions.Count; $index++) {
                $partitionInfo = $partitions[$index]
                $hosts = $partitionInfo.PSObject.Properties['hosts'].Value
                $partitionUnknown = $partitionInfo.PSObject.Properties['partitionUnknown'].Value
                $partitionIdList = if ($hosts -and $hosts.Count -gt 0) { ($hosts -join ', ') } else { '(none)' }
                Write-LogMessage -Type DEBUG -Message "vSAN health debug: partition[$index] partition IDs: $partitionIdList."
                $unknownLabel = if ($partitionUnknown) { ' (unknown to collector)' } else { '' }
                $partitionSummaries += "Partition $($index + 1)${unknownLabel}: $partitionIdList"
            }
            $hostsPerPartition = $partitionSummaries -join '; '
            Write-LogMessage -Type DEBUG -Message "vSAN cluster `"$ClusterName`" partition (partition IDs per partition): $hostsPerPartition."
        }

        # Hosts in vSAN but not in vCenter; comm failure; disconnected.
        $otherHosts = $networkHealth.otherHostsInVsanCluster
        if ($otherHosts -and $otherHosts.Count -gt 0) {
            $otherList = $otherHosts -join ', '
            Write-LogMessage -Type DEBUG -Message "vSAN health debug: otherHostsInVsanCluster (hosts in vSAN not in vCenter): $otherList."
            if ($Context -match 'partition') {
                Write-LogMessage -Type WARNING -Message "vSAN cluster `"$ClusterName`" hosts in vSAN but not in vCenter: $otherList."
            }
        }
        $commFailure = $networkHealth.hostsCommFailure
        if ($commFailure -and $commFailure.Count -gt 0) {
            $commList = $commFailure -join ', '
            Write-LogMessage -Type DEBUG -Message "vSAN health debug: hostsCommFailure: $commList."
            if ($Context -match 'partition') {
                Write-LogMessage -Type WARNING -Message "vSAN cluster `"$ClusterName`" hosts with vSAN service comm failure: $commList."
            }
        }
        $disconnected = $networkHealth.hostsDisconnected
        if ($disconnected -and $disconnected.Count -gt 0) {
            $discList = $disconnected -join ', '
            Write-LogMessage -Type DEBUG -Message "vSAN health debug: hostsDisconnected: $discList."
            if ($Context -match 'partition') {
                Write-LogMessage -Type WARNING -Message "vSAN cluster `"$ClusterName`" hosts disconnected from vCenter: $discList."
            }
        }
    }

    # Overall description and failure reasons (for any context).
    if ($HealthSummary) {
        $overallDesc = $HealthSummary.overallHealthDescription
        if ($overallDesc) {
            Write-LogMessage -Type DEBUG -Message "vSAN health debug: overallHealthDescription=$overallDesc."
        }
        $reasons = Get-VsanHealthFailureReasons -HealthSummary $HealthSummary
        if ($reasons) {
            Write-LogMessage -Type DEBUG -Message "vSAN health debug: failureReasons=$reasons."
        }
    }

    # Context-specific next steps.
    switch ($Context) {
        'partition_detected' {
            Write-LogMessage -Type DEBUG -Message "vSAN health next steps: Resolve network partition (e.g. unicast agent list, network connectivity between hosts). Check vSAN cluster network in vCenter UI for cluster `"$ClusterName`", then re-run deployment."
        }
        'partition_after_repair' {
            Write-LogMessage -Type DEBUG -Message "vSAN health next steps: Partition still present after repair. Verify network/unicast configuration and host connectivity; resolve partition in vCenter vSAN Health for cluster `"$ClusterName`", then re-run deployment."
        }
        'health_red' {
            Write-LogMessage -Type DEBUG -Message "vSAN health next steps: Fix red health issues in vCenter vSAN Health for cluster `"$ClusterName`" (see failureReasons above). Re-run deployment after health is green or yellow."
        }
        'health_summary_null' {
            Write-LogMessage -Type DEBUG -Message "vSAN health next steps: Could not retrieve health summary. Verify vCenter connection and cluster name; ensure VsanVcClusterHealthSystem is available (vCenter /vsanHealth endpoint). Re-run after fixing."
        }
        'repair_failed' {
            Write-LogMessage -Type DEBUG -Message "vSAN health next steps: Object repair did not complete. Verify vCenter and ESX connectivity; check vSAN Health in vCenter UI for cluster `"$ClusterName`". Resolve network/partition then re-run deployment."
        }
    }
}
Function Test-VsanHealthSuggestsPartitionOrNetwork {
    <#
        .SYNOPSIS
        Returns whether the health summary suggests a network partition or initial sync issue.

        .DESCRIPTION
        When overall health is not green, failure text like "Network misconfiguration" may indicate
        a temporary partition or initial sync. This helper identifies such cases so the caller can
        run the repair path (trigger resync, wait, recheck) instead of only waiting and retrying.

        .PARAMETER HealthSummary
        The VsanClusterHealthSummary object from Get-VsanClusterHealthSummaryViaView.

        .OUTPUTS
        Boolean. $true if the summary suggests partition/network/initial sync; $false otherwise.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] $HealthSummary
    )

    if (-not $HealthSummary) {
        return $false
    }

    # Check overall description for partition/network wording.
    $overallDescription = $HealthSummary.overallHealthDescription
    if ($overallDescription -and ($overallDescription -match 'Network misconfiguration|partition|network')) {
        return $true
    }

    # Check formatted failure reasons.
    $failureReasonsText = Get-VsanHealthFailureReasons -HealthSummary $HealthSummary
    if ($failureReasonsText -and ($failureReasonsText -match 'Network misconfiguration|partition|network')) {
        return $true
    }

    # Check network health description.
    $networkHealth = $HealthSummary.networkHealth
    if ($networkHealth -and $networkHealth.description -and ($networkHealth.description -match 'Network misconfiguration|partition|network')) {
        return $true
    }
    return $false
}
Function Test-VsanClusterAdvCfgSyncInSync {
    <#
        .SYNOPSIS
        Returns whether vSAN advanced configuration is in sync across all hosts (vCenter config pushed to ESX).

        .DESCRIPTION
        Checks VsanClusterHealthSummary.advCfgSync. If any entry has inSync = false, vCenter configuration
        is not fully propagated to all ESX hosts. Used after witness/config changes to ensure cluster consistency.

        .PARAMETER HealthSummary
        The VsanClusterHealthSummary object from Get-VsanClusterHealthSummaryViaView (must request advCfgSync field).

        .OUTPUTS
        Boolean. $true if advCfgSync is absent or all entries report inSync; $false if any entry is out of sync.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] $HealthSummary
    )

    if (-not $HealthSummary) {
        return $true
    }
    $advCfgSync = $HealthSummary.advCfgSync
    if (-not $advCfgSync) {
        return $true
    }

    # Any entry with inSync = false means config not fully propagated. Property may be 'inSync' or 'InSync' (PowerCLI/.NET casing).
    foreach ($entry in $advCfgSync) {
        $inSyncProp = $entry.PSObject.Properties | Where-Object { $_.Name -eq 'inSync' -or $_.Name -eq 'InSync' } | Select-Object -First 1
        $inSync = if ($inSyncProp) { $inSyncProp.Value } else { $null }
        if ($inSync -eq $false) {
            return $false
        }
    }
    return $true
}
Function Enable-VsanAutomaticRebalance {
    <#
        .SYNOPSIS
        Enables vSAN automatic disk rebalancing at a given threshold before re-applying vSAN configuration.

        .DESCRIPTION
        Enables automatic rebalance (vSAN 6.7 U3+) via Set-VsanClusterConfiguration -ProactiveRebalanceEnabled $true
        and -ProactiveRebalanceThreshold when the cmdlet supports them. Rebalance runs when capacity variance between
        disks exceeds the threshold. Non-fatal on failure or unsupported PowerCLI. Logs an INFO message when the step runs.

        .PARAMETER ClusterName
        Name of the vSAN cluster.

        .PARAMETER AutomaticRebalanceThreshold
        Imbalance threshold in percent (25-75). Automatic rebalance runs when variance between disks exceeds this. Default is 30.

        .OUTPUTS
        Boolean. $true if automatic rebalance was enabled or already set; $false on error or unsupported cmdlet.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [ValidateRange(25, 75)] [int]$AutomaticRebalanceThreshold = 30
    )
    $setCmd = Get-Command Set-VsanClusterConfiguration -ErrorAction SilentlyContinue
    if (-not $setCmd -or -not $setCmd.Parameters.ContainsKey("ProactiveRebalanceEnabled")) {
        Write-LogMessage -Type DEBUG -Message "Set-VsanClusterConfiguration does not support -ProactiveRebalanceEnabled. Skipping vSAN automatic rebalance enablement."
        return $false
    }
    try {
        $cluster = Get-Cluster -Name $ClusterName -Server $Script:vCenterName -ErrorAction Stop
        $config = Get-VsanClusterConfiguration -Cluster $cluster -Server $Script:vCenterName -ErrorAction Stop
        $params = @{
            Configuration = $config
            ProactiveRebalanceEnabled = $true
            Server = $Script:vCenterName
        }
        if ($setCmd.Parameters.ContainsKey("ProactiveRebalanceThreshold")) {
            $params["ProactiveRebalanceThreshold"] = $AutomaticRebalanceThreshold
        }
        Set-VsanClusterConfiguration @params -ErrorAction Stop | Out-Null
        Write-LogMessage -Type DEBUG -Message "Enabled vSAN automatic rebalancing at $AutomaticRebalanceThreshold% for cluster `"$ClusterName`"."
        return $true
    } catch {
        Write-LogMessage -Type WARNING -Message "Failed to enable vSAN automatic rebalancing for cluster `"$ClusterName`": $($_.Exception.Message). Continuing."
        return $false
    }
}
Function Test-VsanAutomaticRebalanceAtThreshold {

    <#
        .SYNOPSIS
        Returns whether vSAN automatic rebalancing is enabled at the expected threshold for the cluster.

        .DESCRIPTION
        Reads Get-VsanClusterConfiguration and checks ProactiveRebalanceEnabled and ProactiveRebalanceThreshold
        when the configuration object exposes them. Used to verify that Enable-VsanAutomaticRebalance was applied
        (e.g. 30% threshold for disk rebalance).

        .PARAMETER ClusterName
        Name of the vSAN cluster.

        .PARAMETER ExpectedThresholdPercent
        Expected imbalance threshold in percent (25-75). Default is 30.

        .PARAMETER Server
        vCenter server name. Default is $Script:vCenterName.

        .OUTPUTS
        Boolean. $true if proactive rebalance is enabled and threshold matches; $false if not set, mismatch, or unsupported.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [ValidateRange(25, 75)] [Int]$ExpectedThresholdPercent = 30,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$Server = $Script:vCenterName
    )

    try {
        $cluster = Get-Cluster -Name $ClusterName -Server $Server -ErrorAction Stop
        $config = Get-VsanClusterConfiguration -Cluster $cluster -Server $Server -ErrorAction Stop
        if (-not $config) { return $false }
        $enabled = $config.PSObject.Properties['ProactiveRebalanceEnabled']
        if (-not $enabled -or $enabled.Value -ne $true) {
            Write-LogMessage -Type DEBUG -Message "vSAN cluster `"$ClusterName`": automatic rebalance state not reported by API (or not at 30%); will ensure rebalance is enabled if needed."
            return $false
        }
        $thresholdProp = $config.PSObject.Properties['ProactiveRebalanceThreshold']
        if (-not $thresholdProp) {
            Write-LogMessage -Type DEBUG -Message "vSAN cluster `"$ClusterName`": ProactiveRebalanceThreshold not in config; assuming threshold check N/A."
            return $true
        }
        $currentThreshold = $thresholdProp.Value
        if ($null -eq $currentThreshold -or [int]$currentThreshold -ne $ExpectedThresholdPercent) {
            Write-LogMessage -Type DEBUG -Message "vSAN cluster `"$ClusterName`": ProactiveRebalanceThreshold is $currentThreshold (expected $ExpectedThresholdPercent)."
            return $false
        }
        return $true
    } catch {
        Write-LogMessage -Type DEBUG -Message "Test-VsanAutomaticRebalanceAtThreshold failed for `"$ClusterName`": $($_.Exception.Message)."
        return $false
    }
}
Function Enable-VsanAutomaticDiskClaimIfSupported {
    <#
        .SYNOPSIS
        Enables vSAN automatic disk claim (VsanDiskClaimMode Automatic) when the cmdlet supports it.

        .DESCRIPTION
        Sets the vSAN cluster disk claim mode to Automatic via Set-VsanClusterConfiguration -VsanDiskClaimMode
        when the installed PowerCLI exposes that parameter. Applicable to both vSAN OSA and vSAN ESA:
        automatic claim lets vSAN claim compatible disks on cluster hosts without manual selection.
        The published Set-VsanClusterConfiguration reference may not list -VsanDiskClaimMode; this
        function checks at runtime and skips if the parameter is absent. Non-fatal on failure.

        .PARAMETER ClusterName
        Name of the vSAN cluster.

        .OUTPUTS
        Boolean. $true if Automatic was set or already active; $false if parameter unsupported or on error.

        .NOTES
        Best practices when using automatic claim: ensure uniform host configurations (same number of
        disk groups and similar disk types/sizes); OSA allows max 5 disk groups per host with up to
        7 capacity devices per group. After autoclaim, validate with Get-VsanDisk (or Get-VsanStoragePoolDisk for ESA).
        See https://developer.broadcom.com/powercli/latest/vmware.vimautomation.storage/commands/set-vsanclusterconfiguration
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName
    )
    $setCmd = Get-Command Set-VsanClusterConfiguration -ErrorAction SilentlyContinue
    if (-not $setCmd -or -not $setCmd.Parameters.ContainsKey("VsanDiskClaimMode")) {
        Write-LogMessage -Type DEBUG -Message "Set-VsanClusterConfiguration does not support -VsanDiskClaimMode in this PowerCLI version. Skipping vSAN Managed Disk Claim enablement."
        return $false
    }
    try {
        $vsanClusterConfig = Get-VsanClusterConfiguration -Cluster $ClusterName -Server $Script:vCenterName -ErrorAction Stop
        if (-not $vsanClusterConfig) {
            return $false
        }
        $currentMode = $vsanClusterConfig.VsanDiskClaimMode
        $automaticClaimValue = $null
        $claimModeType = $null
        if ($null -ne $vsanClusterConfig.VsanDiskClaimMode) {
            $claimModeType = $vsanClusterConfig.VsanDiskClaimMode.GetType()
        } elseif ($setCmd.Parameters["VsanDiskClaimMode"].ParameterType.IsEnum) {
            $claimModeType = $setCmd.Parameters["VsanDiskClaimMode"].ParameterType
        }
        if ($null -ne $claimModeType -and $claimModeType.IsEnum) {
            try {
                $automaticClaimValue = [Enum]::Parse($claimModeType, "Automatic", $true)
            } catch {
                Write-LogMessage -Type DEBUG -Message "Could not parse VsanDiskClaimMode Automatic: $($_.Exception.Message). Skipping vSAN Managed Disk Claim enablement."
                return $false
            }
        } else {
            Write-LogMessage -Type DEBUG -Message "Could not resolve VsanDiskClaimMode enum type. Skipping vSAN Managed Disk Claim enablement."
            return $false
        }
        if ($null -ne $automaticClaimValue -and $currentMode -ne $automaticClaimValue) {
            Write-LogMessage -Type INFO -Message "Enabling vSAN Managed Disk Claim (VsanDiskClaimMode Automatic) for cluster `"$ClusterName`"."
            Set-VsanClusterConfiguration -Configuration $vsanClusterConfig -VsanDiskClaimMode $automaticClaimValue -Server $Script:vCenterName -ErrorAction Stop | Out-Null
            Write-LogMessage -Type DEBUG -Message "vSAN Managed Disk Claim enabled for cluster `"$ClusterName`"."
            return $true
        }
        Write-LogMessage -Type DEBUG -Message "vSAN Managed Disk Claim already Automatic or unchanged (current mode: $currentMode)."
        return $true
    } catch {
        Write-LogMessage -Type WARNING -Message "Failed to enable vSAN Managed Disk Claim for cluster `"$ClusterName`": $($_.Exception.Message). Continuing."
        return $false
    }
}
Function Invoke-VsanClusterConfigReapply {

    <#
        .SYNOPSIS
        Re-applies the current vSAN cluster configuration from vCenter to ESX hosts via PowerCLI.

        .DESCRIPTION
        Retrieves the current vSAN cluster configuration with Get-VsanClusterConfiguration and
        re-applies it with Set-VsanClusterConfiguration. No settings are changed; the same config
        is pushed from vCenter to all ESX hosts in the cluster. Used when advCfgSync (vSAN health
        advanced config sync) reports one or more hosts out of sync, so that vCenter re-sends the
        config and hosts can converge. Requires $Script:vCenterName to be set (vCenter connection).

        .PARAMETER ClusterName
        The vSAN cluster name. Must match a cluster visible to the current vCenter connection.

        .OUTPUTS
        Boolean. $true if re-apply succeeded; $false if Get-VsanClusterConfiguration or
        Set-VsanClusterConfiguration failed (caller may then wait and recheck advCfgSync).

        .EXAMPLE
        Invoke-VsanClusterConfigReapply -ClusterName "cl0-site1"
        Re-applies the current vSAN config for cluster "cl0-site1" from vCenter to hosts.

        .NOTES
        Called by Test-VsanAdvCfgSyncAndWaitIfNeeded when advCfgSync is out of sync. Uses
        Get-VsanClusterConfiguration and Set-VsanClusterConfiguration (VCF PowerCLI / VMware.VimAutomation.Storage).
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName
    )

    try {
        $vsanClusterConfig = Get-VsanClusterConfiguration -Cluster $ClusterName -Server $Script:vCenterName -ErrorAction Stop
        if (-not $vsanClusterConfig) {
            Write-LogMessage -Type WARNING -Message "Could not retrieve vSAN cluster configuration for cluster `"$ClusterName`". Skipping config re-apply."
            return $false
        }
        Set-VsanClusterConfiguration -Configuration $vsanClusterConfig -Server $Script:vCenterName -ErrorAction Stop | Out-Null
        Write-LogMessage -Type DEBUG -Message "Re-applied vSAN cluster configuration for cluster `"$ClusterName`" (config pushed from vCenter to hosts)."
        return $true
    } catch {
        Write-LogMessage -Type WARNING -Message "Failed to re-apply vSAN cluster configuration for cluster `"$ClusterName`": $($_.Exception.Message). Will wait and recheck advCfgSync."
        return $false
    }
}
Function Get-VsanClusterTriggeredAlarms {
    <#
        .SYNOPSIS
        Returns triggered vCenter alarms for a vSAN cluster.

        .DESCRIPTION
        Gets the cluster view and reads TriggeredAlarmState (the cluster managed object property that lists
        currently firing alarms; each entry has an alarm reference and status). For each triggered alarm,
        retrieves the alarm definition view to obtain the alarm name. Used by Invoke-VsanClusterAlarmCheckAndRemediate
        to detect fixable alarms (e.g. advanced config sync) and report others as warnings.

        .PARAMETER ClusterName
        The name of the vSAN cluster. Must match a cluster visible to the current vCenter connection.

        .OUTPUTS
        Array of PSCustomObject with AlarmName and Status (OverallStatus). Empty array if none or on error.

        .NOTES
        Requires connection to vCenter. Uses Get-Cluster, Get-View, and alarm definition view (VCF PowerCLI 9).
    #>

    [OutputType([System.Object[]])]
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName
    )

    $clusterObject = Get-Cluster -Name $ClusterName -Server $Script:vCenterName -ErrorAction SilentlyContinue
    if (-not $clusterObject) {
        Write-LogMessage -Type DEBUG -Message "Get-VsanClusterTriggeredAlarms: cluster `"$ClusterName`" not found."
        return @()
    }

    try {
        $view = Get-View -Id $clusterObject.ExtensionData.MoRef -Property Name, TriggeredAlarmState -Server $Script:vCenterName -ErrorAction Stop
    } catch {
        Write-LogMessage -Type DEBUG -Message "Get-VsanClusterTriggeredAlarms: failed to get cluster view for `"$ClusterName`": $($_.Exception.Message)"
        return @()
    }

    $triggeredStates = $view.TriggeredAlarmState
    if (-not $triggeredStates -or $triggeredStates.Count -eq 0) {
        return @()
    }

    $result = [System.Collections.ArrayList]::new()
    foreach ($triggered in $triggeredStates) {
        $alarmName = $null
        $status = $triggered.OverallStatus
        try {
            $alarmView = Get-View -Id $triggered.Alarm -Property Info -Server $Script:vCenterName -ErrorAction Stop
            if ($alarmView -and $alarmView.Info -and $alarmView.Info.Name) {
                $alarmName = $alarmView.Info.Name
            }
        } catch {
            Write-LogMessage -Type DEBUG -Message "Get-VsanClusterTriggeredAlarms: could not get alarm definition for alarm id $($triggered.Alarm): $($_.Exception.Message)"
        }
        if (-not $alarmName) {
            $alarmName = "Unknown alarm (id: $($triggered.Alarm))"
        }
        [void]$result.Add([PSCustomObject]@{ AlarmName = $alarmName; Status = $status })
    }
    return $result
}
Function Test-VsanTriggeredAlarmIsStatsPrimaryElection {

    <#
        .SYNOPSIS
        Returns whether a triggered cluster alarm is the vSAN performance-service Stats primary election/selection alarm.

        .DESCRIPTION
        Matches the same name patterns used in Invoke-VsanClusterAlarmCheckAndRemediate and
        Invoke-VsanClusterHealthCheckAfterWitness so red alarm gating can align with the
        post-witness vSAN health path (transient perfsvc election; see Broadcom KB 401679).

        .PARAMETER TriggeredAlarm
        Object with AlarmName (e.g. from Get-VsanClusterTriggeredAlarms).

        .OUTPUTS
        [bool] True when the alarm name matches Stats primary election/selection.
    #>

    [CmdletBinding()]
    [OutputType([bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] $TriggeredAlarm
    )

    if (-not (Get-Member -InputObject $TriggeredAlarm -Name "AlarmName" -MemberType Properties -ErrorAction SilentlyContinue)) {
        return $false
    }
    $name = $TriggeredAlarm.AlarmName
    if ([String]::IsNullOrWhiteSpace([string]$name)) {
        return $false
    }
    return [string]$name -match "Stats primary election|Stats primary selection|performance service alarm 'Stats primary|stats primary election|stats primary selection"
}
Function Test-VsanTriggeredAlarmIsHclRelated {

    <#
        .SYNOPSIS
        Returns whether a triggered cluster alarm reflects a vSAN HCL or hardware-compatibility finding.

        .DESCRIPTION
        Matches alarm names that correspond to the vSAN Health checks Set-VsanLabSilentChecksIfRequested
        silences in lab mode (controlleronhcl, controllerdiskmode, controllerfirmware, controllerdriver,
        hclhostbadstate) plus the umbrella "vSAN hardware compatibility issues" and "Host Hardware vSAN
        Support Compliance" alarms. Used by Invoke-VsanClusterAlarmCheckAndRemediate to explain that
        accepting these red alarms does not fix the underlying HCL state and that WCP supervisor
        enablement will still enforce cluster/host HCL conformance downstream.

        .PARAMETER TriggeredAlarm
        Object with AlarmName (e.g. from Get-VsanClusterTriggeredAlarms).

        .OUTPUTS
        [bool] True when the alarm name matches an HCL or hardware-compatibility check.
    #>

    [CmdletBinding()]
    [OutputType([bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] $TriggeredAlarm
    )

    if (-not (Get-Member -InputObject $TriggeredAlarm -Name "AlarmName" -MemberType Properties -ErrorAction SilentlyContinue)) {
        return $false
    }
    $name = [string]$TriggeredAlarm.AlarmName
    if ([String]::IsNullOrWhiteSpace($name)) {
        return $false
    }
    # HCL acronym is distinctive in vSAN alarm naming; hardware compatibility / vSAN support strings cover the umbrella alarms. Controller firmware/driver/disk-mode/on-HCL map 1:1 to the silenced health check IDs.
    return $name -match "(?i)\bHCL\b|hardware\s+compatibility|hardware\s+vSAN\s+support|controller\s+(firmware|driver|disk\s*mode|on\s+HCL)"
}
Function Set-VsanDomNetworkSchedulerThrottleOnHost {

    <#
        .SYNOPSIS
        Sets the vSAN DOM network scheduler throttle advanced option on a single ESX host (for vSAN cluster compliance on 10G ESA).

        .DESCRIPTION
        Runs esxcli system settings advanced set -o /VSAN/DOMNetworkSchedulerThrottleComponent -i 1 on the host.
        Per Broadcom KB 394932/388455, this can resolve "vSAN cluster compliance" when using vSAN ESA on 10G networks.
        The setting is immediate and persistent.

        .PARAMETER Server
        vCenter server name. Used for Get-EsxCli.

        .PARAMETER VMHost
        The VMHost object (or name) for the ESX host.

        .OUTPUTS
        PSCustomObject with Applied (bool) and AlreadySet (bool). Applied is $true when the setting was set this call; AlreadySet is $true when already 1 (skipped). Both $false on error.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Server,
        [Parameter(Mandatory = $true)] $VMHost
    )
    $hostNameForLogging = if ($VMHost.Name) { $VMHost.Name } else { [string]$VMHost }
    try {
        $esxcli = Get-EsxCli -VMHost $VMHost -V2 -Server $Server -ErrorAction Stop
        # Idempotent: read current value; skip if already 1.
        $listCmd = $esxcli.system.settings.advanced.list
        if ($listCmd) {
            try {
                $listArgs = $listCmd.CreateArgs()
                if ($listArgs.PSObject.Properties['option']) { $listArgs.option = "/VSAN/DOMNetworkSchedulerThrottleComponent" }
                elseif ($listArgs.PSObject.Properties['name']) { $listArgs.name = "/VSAN/DOMNetworkSchedulerThrottleComponent" }
                $listResult = $listCmd.Invoke($listArgs)
                if ($listResult) {
                    # Result may be single object or array (one item per setting); property may be IntValue or intvalue.
                    $items = if ($listResult -is [Array] -or ($listResult -is [System.Collections.IEnumerable] -and $listResult -isnot [string])) { @($listResult) } else { @($listResult) }
                    foreach ($item in $items) {
                        $optionName = $item.Option, $item.option, $item.Name, $item.name, $item.Path, $item.PSObject.Properties['Option'].Value, $item.PSObject.Properties['option'].Value | Where-Object { $_ } | Select-Object -First 1
                        if ($optionName -eq "/VSAN/DOMNetworkSchedulerThrottleComponent") {
                            $currentVal = $item.IntValue, $item.intvalue, $item.PSObject.Properties['IntValue'].Value, $item.PSObject.Properties['intvalue'].Value | Where-Object { $null -ne $_ } | Select-Object -First 1
                            if ($null -ne $currentVal -and [int]$currentVal -eq 1) {
                                return [PSCustomObject]@{ Applied = $false; AlreadySet = $true }
                            }
                            break
                        }
                    }
                    # Single-option list returns one object; it may not have Option property set, so check IntValue if we have only one item.
                    if ($items.Count -eq 1) {
                        $currentVal = $items[0].IntValue, $items[0].intvalue, $items[0].PSObject.Properties['IntValue'].Value, $items[0].PSObject.Properties['intvalue'].Value | Where-Object { $null -ne $_ } | Select-Object -First 1
                        if ($null -ne $currentVal -and [int]$currentVal -eq 1) {
                            return [PSCustomObject]@{ Applied = $false; AlreadySet = $true }
                        }
                    }
                }
            } catch {
                Write-LogMessage -Type DEBUG -Message "Set-VsanDomNetworkSchedulerThrottleOnHost: Could not read current value on `"$hostNameForLogging`": $($_.Exception.Message). Proceeding to set."
            }
        }
        $setCmd = $esxcli.system.settings.advanced.set
        if (-not $setCmd) {
            Write-LogMessage -Type DEBUG -Message "esxcli system settings advanced set not available on host `"$hostNameForLogging`"."
            return [PSCustomObject]@{ Applied = $false; AlreadySet = $false }
        }
        $argsObj = $setCmd.CreateArgs()
        $argsObj.option = "/VSAN/DOMNetworkSchedulerThrottleComponent"
        $argsObj.intvalue = "1"
        $setCmd.Invoke($argsObj) | Out-Null
        Write-LogMessage -Type DEBUG -Message "Set DOM throttle (10G alarm suppression, Broadcom KB 394932) on host `"$hostNameForLogging`"."
        return [PSCustomObject]@{ Applied = $true; AlreadySet = $false }
    } catch {
        Write-LogMessage -Type WARNING -Message "Could not set /VSAN/DOMNetworkSchedulerThrottleComponent on host `"$hostNameForLogging`": $($_.Exception.Message)."
        return [PSCustomObject]@{ Applied = $false; AlreadySet = $false }
    }
}
Function Set-VsanDomNetworkSchedulerThrottleOnCluster {

    <#
        .SYNOPSIS
        Sets the vSAN DOM network scheduler throttle advanced option on all hosts in a vSAN cluster.

        .DESCRIPTION
        Gets all VMHosts in the cluster and calls Set-VsanDomNetworkSchedulerThrottleOnHost on each.
        Used to remediate "vSAN cluster compliance" alarm when using vSAN ESA on 10G (Broadcom KB 394932, 388455).
        Also applied proactively by Invoke-VsanClusterAlarmCheckAndRemediate before querying alarms.
        Failures on individual hosts are logged; the function does not throw.

        .PARAMETER ClusterName
        Name of the vSAN cluster.

        .PARAMETER Server
        vCenter server name. Default is $Script:vCenterName.

        .OUTPUTS
        Boolean. $true if the setting was applied on at least one host; $false if no hosts or all failed.

        .NOTES
        For stretched clusters, only data hosts are in the cluster; the witness is a separate host. This function applies the setting to all hosts in the cluster (data hosts) only. Ensure the correct witness type (ESA vs OSA witness appliance) is configured for your cluster; see Initialize-VsanWitnessDiskGroup and the advanced setting VSAN.HostDeployedFromWitnessOVF (1=OSA, 2=ESA).
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$Server = $Script:vCenterName
    )
    $clusterObject = Get-Cluster -Name $ClusterName -Server $Server -ErrorAction SilentlyContinue
    if (-not $clusterObject) {
        Write-LogMessage -Type DEBUG -Message "Set-VsanDomNetworkSchedulerThrottleOnCluster: cluster `"$ClusterName`" not found."
        return $false
    }
    $clusterHosts = Get-VMHost -Location $clusterObject -Server $Server -ErrorAction SilentlyContinue
    if (-not $clusterHosts -or $clusterHosts.Count -eq 0) {
        Write-LogMessage -Type DEBUG -Message "Set-VsanDomNetworkSchedulerThrottleOnCluster: no hosts in cluster `"$ClusterName`"."
        return $false
    }
    $appliedCount = 0
    $alreadySetCount = 0
    foreach ($vmHost in @($clusterHosts)) {
        $result = Set-VsanDomNetworkSchedulerThrottleOnHost -VMHost $vmHost -Server $Server
        if ($result.Applied) { $appliedCount++ }
        elseif ($result.AlreadySet) { $alreadySetCount++ }
    }
    if ($appliedCount -gt 0) {
        Write-LogMessage -Type DEBUG -Message "Suppress 10 GB networking alarm if present (Broadcom KB 394932) on $appliedCount/$($clusterHosts.Count) host(s) in cluster `"$ClusterName`"."
        return $true
    }
    if ($alreadySetCount -eq $clusterHosts.Count) {
        Write-LogMessage -Type DEBUG -Message "DOM throttle (10G alarm suppression) already set on all $($clusterHosts.Count) host(s) in cluster `"$ClusterName`". Skipping."
    }
    return $appliedCount -gt 0
}
Function Invoke-VsanClusterAlarmCheckAndRemediate {

    <#
        .SYNOPSIS
        Queries vCenter alarms on a vSAN cluster; fixes fixable alarms via API or reports others as warnings.

        .DESCRIPTION
        After vSAN cluster creation, always sets /VSAN/DOMNetworkSchedulerThrottleComponent=1 on all cluster hosts (vSAN ESA on 10G; Broadcom KB 394932, 388455), then queries triggered alarms on the cluster. If an alarm is one we can fix via API (e.g. "Advanced vSAN configuration in sync"), we attempt remediation (re-apply vSAN cluster config). All other alarms are reported as warnings only.         After remediation, triggered alarms are re-read: any **red** alarm (except lab-suppressed third-party IO filter when LabEnvironment is true, and except **Stats primary election/selection** red alarms, which are treated as the same transient perfsvc case as Invoke-VsanClusterHealthCheckAfterWitness) requires an explicit opt-in to continue, or deployment stops with the same failure path as other pre-supervisor errors (rollback prompt in the main catch). When any blocking red alarm matches an HCL/hardware-compatibility check (Test-VsanTriggeredAlarmIsHclRelated), the prompt and AcceptBadCheckResults message are extended to warn that accepting risk does not fix the underlying HCL state and WCP supervisor enablement will likely fail; the same check IDs are silenced in lab mode by Set-VsanLabSilentChecksIfRequested. **Yellow**-only alarms log a summary warning and do not block.

        .PARAMETER AcceptBadCheckResults
        When set (e.g. **Start-VcfEdgeAtScale -AcceptBadCheckResults**), proceeds without prompting when triggered alarms remain **red**.

        .PARAMETER ClusterName
        The name of the vSAN cluster. Must match a cluster visible to the current vCenter connection.

        .PARAMETER HaPolicy
        Passed to Invoke-ReconfigureClusterHA when remediating "vSphere HA host status" so admission control matches deployment (slotBased, reservationBased, or disabled).

        .PARAMETER LabEnvironment
        When $true (e.g. common.labenvironment in infrastructure JSON), the "Registration/unregistration of third-party IO filter storage providers fails on a host" alarm is treated as known lab noise and logged at DEBUG only instead of WARNING, and is **not** counted toward the red-alarm gate. Red "Stats primary election" / performance-service election alarms are **not** counted toward the red-alarm gate (same transient handling as post-witness vSAN health); the first pass still logs them at DEBUG with KB 401679 guidance.

        .PARAMETER PostRemediationWaitSeconds
        Seconds to wait after re-applying vSAN cluster configuration (remediation) before re-querying alarms. Default is 10.

        .NOTES
        Requires connection to vCenter. Called after vSAN storage configuration for the cluster.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [Switch]$AcceptBadCheckResults,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [ValidateSet("disabled", "reservationBased", "slotBased")] [String]$HaPolicy = "reservationBased",
        [Parameter(Mandatory = $false)] [bool]$LabEnvironment = $false,
        [Parameter(Mandatory = $false)] [ValidateRange(0, 120)] [Int]$PostRemediationWaitSeconds = 10
    )

    # Always set DOM network scheduler throttle on cluster (vSAN ESA on 10G; Broadcom KB 394932, 388455). Not only when "vSAN cluster compliance" alarm is present.
    $throttleSet = Set-VsanDomNetworkSchedulerThrottleOnCluster -ClusterName $ClusterName
    if (-not $throttleSet) {
        Write-LogMessage -Type DEBUG -Message "Set-VsanDomNetworkSchedulerThrottleOnCluster returned false for cluster `"$ClusterName`" (cluster not found or no hosts)."
    }

    $alarms = Get-VsanClusterTriggeredAlarms -ClusterName $ClusterName
    if (-not $alarms -or $alarms.Count -eq 0) {
        return
    }

    # Alarm handling order: (1) advCfgSync alarms are remediated once by re-applying vSAN cluster config; (2) for all other alarms we run pattern-based handling: Performance service (enable programmatically), Stats primary election (DEBUG guidance; post-witness gate uses re-trigger in Invoke-VsanClusterHealthCheckAfterWitness), vSAN cluster compliance (set DOM throttle on hosts). Alarms we cannot remediate are logged as WARNING and collected in remainingAlarms.
    $advCfgSyncPattern = "advanced\s*(virtual\s*)?san\s*configuration\s*in\s*sync|advCfgSync|configuration\s*in\s*sync"
    $attemptedFix = $false
    $remainingAlarms = [System.Collections.ArrayList]::new()

    foreach ($alarm in $alarms) {
        $name = $alarm.AlarmName
        if ($name -match $advCfgSyncPattern) {
            if (-not $attemptedFix) {
                Write-LogMessage -Type INFO -Message "vSAN cluster `"$ClusterName`" has alarm: `"$name`". Attempting remediation (re-apply vSAN cluster configuration)."
                $reapplyOk = Invoke-VsanClusterConfigReapply -ClusterName $ClusterName
                $attemptedFix = $true
                if ($reapplyOk) {
                    Start-Sleep -Seconds $PostRemediationWaitSeconds
                    $afterAlarms = Get-VsanClusterTriggeredAlarms -ClusterName $ClusterName
                    foreach ($alarmItem in $afterAlarms) {
                        if ($alarmItem.AlarmName -match $advCfgSyncPattern) {
                            [void]$remainingAlarms.Add($alarmItem)
                        }
                    }
                }
                else {
                    [void]$remainingAlarms.Add($alarm)
                }
            }
            # When attemptedFix is already true, remaining advCfgSync alarms were captured from re-query; do not add again from initial list.
        }
        else {
            # "vSphere HA host status": re-apply HA/DRS so vCenter re-evaluates management network for heartbeats (e.g. after vDS migration or vSAN/vLCM activity).
            if ($name -match "vSphere\s+HA\s+host\s+status|vsphere\s+ha\s+host\s+status") {
                Write-LogMessage -Type INFO -Message "vSAN cluster `"$ClusterName`" has alarm: `"$name`" (status: $($alarm.Status)). Auto-remediating by re-applying HA and DRS so vCenter re-evaluates management network for heartbeats."
                Invoke-ReconfigureClusterHA -ClusterName $ClusterName -DelaySeconds $Script:HaPostVsanStabilizationDelaySeconds -HaPolicy $HaPolicy
            }
            # "Performance service status" (perfsvcstatus): enable programmatically via Set-VsanClusterConfiguration -PerformanceServiceEnabled): perfsvcConfig.enabled / createStatsObject). Often clears within a few minutes if already enabled.
            elseif ($name -match "Performance service status|perfsvcstatus|performance service alarm 'Performance service status'") {
                Write-LogMessage -Type INFO -Message "vSAN cluster `"$ClusterName`" has alarm: `"$name`" (status: $($alarm.Status)). Attempting to enable vSAN performance service programmatically."
                Enable-VsanPerformanceService -ClusterName $ClusterName
                Write-LogMessage -Type INFO -Message "If the alarm persists, it often clears within a few minutes as the performance service starts. Otherwise enable in vCenter (vSAN Services) or check vSAN Health > Performance service."
            }
            # Stats primary election (perfsvc.masterexist): transient after power-on or duplicate .vsan.stats paths; silenced for health gates; log guidance only (KB 401679).
            elseif ($name -match "Stats primary election|Stats primary selection|performance service alarm 'Stats primary|stats primary election|stats primary selection") {
                Write-LogMessage -Type DEBUG -Message "vSAN cluster `"$ClusterName`" has Stats primary election/selection alarm: `"$name`" (status: $($alarm.Status)). Post-witness health uses re-trigger + optional proceed-with-warning when this is the only failing test. If performance service stays unhealthy, see Broadcom KB 401679 (remove duplicate .vsan.stats-* folders, restart vsanmgmtd on hosts, re-enable performance service, RETEST) or RVC vsan.perf.stats_object_delete/create."
            }
            # Lab only: third-party IO filter / VAIO provider alarm is common (KB 406493, 402809); do not warn so deployment logs stay clean.
            elseif ($LabEnvironment -and $name -match "Registration/unregistration of third-party IO filter storage providers fails on a host") {
                Write-LogMessage -Type DEBUG -Message "vSAN cluster `"$ClusterName`" has alarm (lab-suppressed): `"$name`" (status: $($alarm.Status)). Known lab/VAIO issue; resolve manually if needed (e.g. SSL/cert on port 9080)."
            }
            else {
                Write-LogMessage -Type WARNING -Message "vSAN cluster `"$ClusterName`" has alarm (not auto-remediated): `"$name`" (status: $($alarm.Status)). Resolve manually if needed."
            }
        }
    }

    foreach ($alarmItem in $remainingAlarms) {
        Write-LogMessage -Type WARNING -Message "vSAN cluster `"$ClusterName`" alarm still present after remediation attempt: `"$($alarmItem.AlarmName)`" (status: $($alarmItem.Status)). Resolve manually if needed."
    }

    # Re-query alarms so red/yellow gating reflects state after auto-remediation (performance service, HA reconfig, etc.).
    $refreshedAlarms = Get-VsanClusterTriggeredAlarms -ClusterName $ClusterName
    if (-not $refreshedAlarms -or $refreshedAlarms.Count -eq 0) {
        return
    }

    $labThirdPartyPattern = "Registration/unregistration of third-party IO filter storage providers fails on a host"
    $blockingRedAlarms = [System.Collections.ArrayList]::new()
    $yellowAlarms = [System.Collections.ArrayList]::new()
    foreach ($a in $refreshedAlarms) {
        $statusText = ([string]$a.Status).ToLower()
        $alarmLabel = $a.AlarmName
        if ($LabEnvironment -and $alarmLabel -match [regex]::Escape($labThirdPartyPattern)) {
            continue
        }
        switch -Regex ($statusText) {
            '^red$' {
                if (Test-VsanTriggeredAlarmIsStatsPrimaryElection -TriggeredAlarm $a) {
                    Write-LogMessage -Type WARNING -Message "vSAN cluster `"$ClusterName`" has red triggered alarm (not blocking on this gate): `"$($a.AlarmName)`". Same transient Stats primary handling as post-witness health; if supervisor or host preflight still fails, align witness and data node ESX builds, then see Broadcom KB 401679."
                    continue
                }
                [void]$blockingRedAlarms.Add($a)
            }
            '^yellow$' {
                [void]$yellowAlarms.Add($a)
            }
        }
    }

    if ($blockingRedAlarms.Count -gt 0) {
        Write-LogMessage -Type ERROR -Message "vSAN cluster `"$ClusterName`" has one or more triggered alarms with red status. This indicates a serious vSAN fault; stretched-cluster configuration (including witness reachability and routing) may be incorrect. Verify vSAN Health in vCenter and confirm witness network connectivity and witness VM health before continuing."
        foreach ($ra in $blockingRedAlarms) {
            Write-LogMessage -Type WARNING -Message "  Red alarm: `"$($ra.AlarmName)`" (status: $($ra.Status))."
        }
        # When any blocking red alarm matches an HCL/hardware-compatibility check (the same set lab mode silences), warn that accepting the risk does not fix the underlying HCL state and that WCP supervisor enablement will still enforce cluster/host HCL conformance downstream.
        $hclRedAlarms = @($blockingRedAlarms | Where-Object { Test-VsanTriggeredAlarmIsHclRelated -TriggeredAlarm $_ })
        if ($hclRedAlarms.Count -gt 0) {
            $hclNames = ($hclRedAlarms | ForEach-Object { "`"$($_.AlarmName)`"" }) -join ", "
            Write-LogMessage -Type WARNING -Message "Red alarm(s) on cluster `"$ClusterName`" include vSAN HCL/hardware-compatibility findings: $hclNames. These would be hidden by common.labenvironment=true but the underlying HCL state (storage controller on HCL, controller firmware/driver/disk mode, host HCL DB state) is unchanged. Accepting risk here will almost certainly not produce a working supervisor: WCP supervisor enablement enforces cluster/host HCL conformance downstream of this gate. Resolve by using HCL-listed storage controllers, firmware, and drivers, then retry; do not simply acknowledge the alarms in vCenter."
        }
        if ($AcceptBadCheckResults.IsPresent) {
            if ($hclRedAlarms.Count -gt 0) {
                Write-LogMessage -Type WARNING -Message "AcceptBadCheckResults is set; proceeding despite red vSAN HCL alarm(s) for cluster `"$ClusterName`". Supervisor enablement will likely fail until the cluster is HCL-conformant."
            } else {
                Write-LogMessage -Type WARNING -Message "AcceptBadCheckResults is set; proceeding despite red vSAN triggered alarm(s) for cluster `"$ClusterName`"."
            }
        }
        else {
            $continuePrompt = if ($hclRedAlarms.Count -gt 0) {
                "Continue deployment despite red vSAN HCL/hardware-compatibility alarm(s)? Supervisor enablement is expected to fail. Type Y to accept risk, or N to stop [default: N]"
            } else {
                "Continue deployment despite red vSAN alarm(s)? Type Y to accept risk, or N to stop [default: N]"
            }
            do {
                $continueResponse = Read-Host $continuePrompt
                $continueResponse = if ($null -ne $continueResponse) { $continueResponse.Trim() } else { "" }
                if ($continueResponse -match '^[yY](es)?$') {
                    if ($hclRedAlarms.Count -gt 0) {
                        Write-LogMessage -Type WARNING -Message "User chose to continue despite red vSAN HCL alarm(s) for cluster `"$ClusterName`". Accepting risk; supervisor enablement may fail on non-HCL-conformant hardware."
                    } else {
                        Write-LogMessage -Type WARNING -Message "User chose to continue despite red vSAN triggered alarm(s) for cluster `"$ClusterName`". Accepting risk."
                    }
                    break
                }
                if ([String]::IsNullOrWhiteSpace($continueResponse) -or $continueResponse -match '^[nN](o)?$') {
                    $redNames = ($blockingRedAlarms | ForEach-Object { $_.AlarmName }) -join "; "
                    Write-LogMessage -Type INFO -Message "User declined to continue (or accepted default N) due to red vSAN triggered alarm(s) on cluster `"$ClusterName`". Deployment will stop; you will be prompted whether to roll back compute if applicable."
                    throw "Deployment failed. vSAN cluster `"$ClusterName`" has triggered alarm(s) with red status: $redNames"
                }
                Write-LogMessage -Type WARNING -Message "Invalid response. Enter Y or N (or press Enter for N)."
            } while ($true)
        }
    }
    elseif ($yellowAlarms.Count -gt 0) {
        Write-LogMessage -Type WARNING -Message "vSAN cluster `"$ClusterName`" has $($yellowAlarms.Count) triggered alarm(s) with yellow status (no red); continuing without blocking. Resolve in vCenter when convenient."
    }
}
Function Wait-VsanClusterConfigSyncOrTimeout {

    <#
        .SYNOPSIS
        Waits until vSAN advanced configuration is in sync on all hosts or the timeout is reached.

        .DESCRIPTION
        Polls vSAN health (advCfgSync) to verify vCenter configuration has propagated to all ESX hosts.
        Use after Invoke-VsanClusterConfigReapply before adding storage pool disks so hosts have ESA enabled.
        Polling (every CheckIntervalSeconds) returns as soon as all hosts report in sync instead of waiting a single long sleep.

        .PARAMETER CheckIntervalSeconds
        Seconds between each advCfgSync check. Default is 15.

        .PARAMETER ClusterName
        The vSAN cluster name.

        .PARAMETER TimeoutSeconds
        Maximum seconds to wait for config sync. 0 skips waiting and returns $false. Default is 180.

        .OUTPUTS
        Boolean. $true if advCfgSync reported in sync within the timeout; $false if timeout or health unavailable.

        .NOTES
        Uses Get-VsanClusterHealthSummaryViaView and Test-VsanClusterAdvCfgSyncInSync.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(5, 120)] [Int]$CheckIntervalSeconds = 15,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [ValidateRange(0, 600)] [Int]$TimeoutSeconds = 180
    )

    if ($TimeoutSeconds -le 0) {
        return $false
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $checkCount = 0
    while ((Get-Date) -lt $deadline) {
        $checkCount++
        $healthSummary = Get-VsanClusterHealthSummaryViaView -ClusterName $ClusterName -FetchFromCache $false
        if ($healthSummary -and (Test-VsanClusterAdvCfgSyncInSync -HealthSummary $healthSummary)) {
            Write-LogMessage -Type INFO -Message "vSAN cluster configuration is in sync on all hosts for cluster `"$ClusterName`" (check #$checkCount)."
            return $true
        }
        $remaining = [math]::Max(0, [int](($deadline - (Get-Date)).TotalSeconds))
        if ($remaining -gt 0) {
            $sleepSeconds = [math]::Min($CheckIntervalSeconds, $remaining)
            Write-LogMessage -Type DEBUG -Message "vSAN config not yet in sync for cluster `"$ClusterName`" (check #$checkCount). Waiting $CheckIntervalSeconds seconds (timeout in $remaining s)."
            Start-Sleep -Seconds $sleepSeconds
        }
    }

    Write-LogMessage -Type WARNING -Message "vSAN cluster configuration did not report in sync for cluster `"$ClusterName`" within $TimeoutSeconds seconds ($checkCount check(s)). Proceeding; if you see 'vSAN ESA is disabled on this host', increase VsanConfigSyncTimeoutSeconds or check vCenter-to-host connectivity."
    return $false
}
Function Test-VsanAdvCfgSyncAndWaitIfNeeded {

    <#
        .SYNOPSIS
        Pushes vCenter vSAN configuration to all ESX hosts when advCfgSync is out of sync; no wait or polling.

        .DESCRIPTION
        If advCfgSync shows any host out of sync, re-applies the current vSAN cluster config via PowerCLI
        (Invoke-VsanClusterConfigReapply) to push config from vCenter to hosts, then proceeds. Does not set
        automatic rebalance (already set in main flow and/or after witness). Sync may complete asynchronously; no polling or timeout. Caller continues without waiting.

        .PARAMETER ClusterName
        The vSAN cluster name (for re-apply).

        .PARAMETER HealthSummary
        Current VsanClusterHealthSummary (must include advCfgSync field).
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] $HealthSummary
    )

    if (-not (Test-VsanClusterAdvCfgSyncInSync -HealthSummary $HealthSummary)) {
        Write-LogMessage -Type INFO -Message "vSAN advanced config not in sync on all hosts for cluster `"$ClusterName`". Pushing current vSAN cluster config from vCenter to hosts."
        # Re-apply only; rebalance at 30% is already set in main flow and/or after witness (Set-VsanWitness).
        Invoke-VsanClusterConfigReapply -ClusterName $ClusterName | Out-Null
        Write-LogMessage -Type INFO -Message "vSAN cluster config re-applied for cluster `"$ClusterName`". Sync may complete asynchronously; proceeding."
    }
}
Function Get-VsanHealthFailureReasons {

    <#
        .SYNOPSIS
        Builds a string describing why vSAN cluster health is not green.

        .DESCRIPTION
        Uses overallHealthDescription and, if useful, group/test details from the health summary
        to report why health is yellow or red.

        .PARAMETER HealthSummary
        The VsanClusterHealthSummary object from Get-VsanClusterHealthSummaryViaView.

        .OUTPUTS
        [string] Non-empty string with reason(s); [string]::Empty if summary is null or overall health is green.
    #>

    [CmdletBinding()]
    [OutputType([string])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] $HealthSummary
    )

    $emptyResult = [string]::Empty

    # Null or green: no failure reasons.
    if (-not $HealthSummary) {
        return $emptyResult
    }
    $overallHealth = $HealthSummary.overallHealth
    if ($overallHealth -eq 'green') {
        return $emptyResult
    }

    # Build reasons from overall description and non-green groups/tests (full findings detail).
    [string[]]$failureReasons = @()
    $overallDescription = $HealthSummary.overallHealthDescription
    if ($overallDescription) {
        $failureReasons += [string]$overallDescription
    }

    $healthGroups = $HealthSummary.groups
    if ($healthGroups) {
        foreach ($healthGroup in $healthGroups) {
            $groupHealthStatus = $healthGroup.PSObject.Properties['health'].Value
            if (-not $groupHealthStatus -or $groupHealthStatus -eq 'green') {
                continue
            }
            $groupName = $healthGroup.PSObject.Properties['groupName'].Value
            if ($groupName) {
                $failureReasons += [string]("Group: $groupName ($groupHealthStatus)")
            }
            # Include per-test detail for non-green groups so red/yellow findings are fully visible.
            $tests = $healthGroup.PSObject.Properties['tests'].Value
            if ($tests -and (@($tests).Count -gt 0)) {
                foreach ($test in @($tests)) {
                    $testHealth = $test.PSObject.Properties['health'].Value
                    if (-not $testHealth -or $testHealth -eq 'green') {
                        continue
                    }
                    $testName = $test.PSObject.Properties['testName'].Value
                    if (-not $testName) { $testName = $test.PSObject.Properties['testId'].Value }
                    if (-not $testName) { $testName = "Test" }
                    $testDesc = $test.PSObject.Properties['description'].Value
                    $testLine = [string]("  Test: $testName ($testHealth)")
                    if ($testDesc) {
                        $testLine = [string]($testLine + ": $testDesc")
                    }
                    $failureReasons += $testLine
                }
            }
        }
    }

    if ($failureReasons.Count -eq 0) {
        return [string]("Health status: $overallHealth")
    }
    return [string]($failureReasons -join "; ")
}
Function Invoke-VsanClusterObjectRepairAndWait {

    <#
        .SYNOPSIS
        Triggers vSAN object repair (resync) for the cluster and waits for the task to complete.

        .DESCRIPTION
        Calls VsanHealthRepairClusterObjectsImmediate to queue absent/degraded objects for repair,
        then polls the task until it completes or the timeout is reached.

        .PARAMETER ClusterName
        The name of the vSAN cluster. Must be a non-empty string.

        .PARAMETER PollIntervalSeconds
        Seconds between task state polls while waiting for the repair task. Default is 15.

        .PARAMETER TimeoutSeconds
        Maximum seconds to wait for the repair task. Default is 600 (10 minutes).

        .OUTPUTS
        Boolean. $true if the repair task completed successfully; $false on failure or timeout.

        .NOTES
        The API task completes when objects are queued for repair; actual resync runs in the background.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [ValidateRange(5, 60)] [int]$PollIntervalSeconds = 15,
        [Parameter(Mandatory = $false)] [ValidateRange(60, 3600)] [int]$TimeoutSeconds = 600
    )

    $clusterObject = Get-Cluster -Name $ClusterName -Server $Script:vCenterName -ErrorAction SilentlyContinue
    if (-not $clusterObject) {
        Write-LogMessage -Type ERROR -Message "Cluster `"$ClusterName`" not found for repair."
        return $false
    }
    $clusterMoRef = $clusterObject.ExtensionData.MoRef
    $healthSystemView = Get-VsanView -Id "VsanVcClusterHealthSystem-vsan-cluster-health-system" -Server $Script:vCenterName -ErrorAction SilentlyContinue
    if (-not $healthSystemView) {
        Write-LogMessage -Type ERROR -Message "Failed to get VsanVcClusterHealthSystem view for repair."
        Write-LogMessage -Type DEBUG -Message "vSAN repair next steps: VsanVcClusterHealthSystem view unavailable. Verify vCenter connection and vSAN Health service (vCenter /vsanHealth endpoint)."
        Write-VsanHealthFailureDebugInfo -ClusterName $ClusterName -Context 'repair_failed'
        return $false
    }
    try {
        # Trigger repair for all absent/degraded objects (uuids = $null).
        $repairTaskRef = $healthSystemView.VsanHealthRepairClusterObjectsImmediate($clusterMoRef, $null)
        if (-not $repairTaskRef) {
            # No task ref means nothing to repair; treat as success.
            Write-LogMessage -Type WARNING -Message "VsanHealthRepairClusterObjectsImmediate returned no task."
            return $true
        }
    } catch {
        Write-LogMessage -Type ERROR -Message "VsanHealthRepairClusterObjectsImmediate failed: $($_.Exception.Message)"
        $innerMsg = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { "" }
        Write-LogMessage -Type DEBUG -Message "vSAN repair API exception: $($_.Exception.Message). Inner: $innerMsg"
        Write-VsanHealthFailureDebugInfo -ClusterName $ClusterName -Context 'repair_failed'
        return $false
    }
    $taskDeadline = (Get-Date).AddSeconds($TimeoutSeconds)
    # Poll the repair task until success, error, or timeout.
    while ((Get-Date) -lt $taskDeadline) {
        $taskView = Get-View -Id $repairTaskRef -Server $Script:vCenterName -ErrorAction SilentlyContinue
        if (-not $taskView) {
            # Task view may be unavailable briefly; retry after poll interval.
            Start-Sleep -Seconds $PollIntervalSeconds
            continue
        }
        $taskState = $taskView.Info.State
        switch ($taskState) {
            'success' {
                Write-LogMessage -Type INFO -Message "vSAN object repair task completed successfully for cluster `"$ClusterName`"."
                return $true
            }
            'error' {
                $taskError = $taskView.Info.Error
                if ($taskError) {
                    Write-LogMessage -Type ERROR -Message "vSAN repair task failed: $($taskError.LocalizedMessage)"
                    Write-LogMessage -Type DEBUG -Message "vSAN repair task error detail: LocalizedMessage=$($taskError.LocalizedMessage); Fault=$($taskError.Fault)."
                } else { Write-LogMessage -Type ERROR -Message "vSAN repair task failed." }
                Write-VsanHealthFailureDebugInfo -ClusterName $ClusterName -Context 'repair_failed'
                return $false
            }
            default {
                # Task still running (e.g. queued); keep polling.
                Write-LogMessage -Type DEBUG -Message "vSAN repair task state: $taskState. Waiting..."
                Start-Sleep -Seconds $PollIntervalSeconds
            }
        }
    }
    $lastState = if ($taskState) { $taskState } else { 'unknown' }
    Write-LogMessage -Type ERROR -Message "vSAN object repair task did not complete within $TimeoutSeconds seconds for cluster `"$ClusterName`"."
    Write-LogMessage -Type DEBUG -Message "vSAN repair task timed out; last observed state was $lastState. Consider increasing TimeoutSeconds or resolving cluster/network issues."
    Write-VsanHealthFailureDebugInfo -ClusterName $ClusterName -Context 'repair_failed'
    return $false
}
Function Enable-VsanHealthAlarms {

    <#
        .SYNOPSIS
        Re-enables vSAN health alarms by removing all health checks from the silent list.

        .DESCRIPTION
        When "vSAN health alarms are suppressed", health checks are in the silent list and show as Skipped.
        This function retrieves the current list of silenced checks via VsanHealthGetVsanClusterSilentChecks
        and removes them using Set-VsanClusterConfiguration -RemoveSilentHealthCheck so alarms are active again.

        .PARAMETER ClusterName
        Name of the vSAN cluster.

        .OUTPUTS
        Boolean. $true if alarms were re-enabled or no silent checks were set; $false on error.

        .NOTES
        Requires VsanVcClusterHealthSystem view and Set-VsanClusterConfiguration -RemoveSilentHealthCheck.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName
    )
    $clusterObject = Get-Cluster -Name $ClusterName -Server $Script:vCenterName -ErrorAction SilentlyContinue
    if (-not $clusterObject) {
        Write-LogMessage -Type WARNING -Message "Cluster `"$ClusterName`" not found. Cannot enable vSAN health alarms."
        return $false
    }
    $healthSystemView = Get-VsanView -Id "VsanVcClusterHealthSystem-vsan-cluster-health-system" -Server $Script:vCenterName -ErrorAction SilentlyContinue
    if (-not $healthSystemView) {
        Write-LogMessage -Type DEBUG -Message "VsanVcClusterHealthSystem view not available. Skipping enable vSAN health alarms."
        return $false
    }
    $clusterMoRef = $clusterObject.ExtensionData.MoRef
    $silentTestIds = $null
    try {
        $silentTestIds = $healthSystemView.VsanHealthGetVsanClusterSilentChecks($clusterMoRef)
    } catch {
        Write-LogMessage -Type DEBUG -Message "VsanHealthGetVsanClusterSilentChecks failed: $($_.Exception.Message). Skipping enable vSAN health alarms."
        return $false
    }
    if (-not $silentTestIds -or (@($silentTestIds).Count -eq 0)) {
        Write-LogMessage -Type DEBUG -Message "No vSAN health checks are silenced for cluster `"$ClusterName`". Alarms are already active."
        return $true
    }
    $idList = @($silentTestIds)
    $setCmd = Get-Command Set-VsanClusterConfiguration -ErrorAction SilentlyContinue
    if (-not $setCmd -or -not $setCmd.Parameters.ContainsKey("RemoveSilentHealthCheck")) {
        Write-LogMessage -Type DEBUG -Message "Set-VsanClusterConfiguration does not support -RemoveSilentHealthCheck. Cannot enable vSAN health alarms via this path."
        return $false
    }
    try {
        $config = Get-VsanClusterConfiguration -Cluster $clusterObject -Server $Script:vCenterName -ErrorAction Stop
        Set-VsanClusterConfiguration -Configuration $config -RemoveSilentHealthCheck $idList -Server $Script:vCenterName -ErrorAction Stop | Out-Null
        Write-LogMessage -Type INFO -Message "Re-enabled vSAN health alarms for cluster `"$ClusterName`" (removed $($idList.Count) check(s) from silent list)."
        return $true
    } catch {
        Write-LogMessage -Type WARNING -Message "Failed to re-enable vSAN health alarms for cluster `"$ClusterName`": $($_.Exception.Message)."
        return $false
    }
}
Function Invoke-AbandonHciWorkflowIfInProgress {

    <#
        .SYNOPSIS
        Skips the vCenter Quickstart (HCI) workflow on the cluster so the "vSAN health alarms are suppressed" warning can clear.

        .DESCRIPTION
        When a cluster is created or vSAN is enabled, vCenter may mark it as in the Quickstart (HCI) workflow. While workflowState is in_progress, the health service shows the "vSAN health alarms are suppressed" (hciskip) alarm. This function calls the cluster's AbandonHciWorkflow API to opt out of the workflow so that alarm can turn green. Non-fatal if the API is unavailable or the workflow is already completed/skipped.

        .PARAMETER ClusterName
        Name of the vSAN cluster.

        .OUTPUTS
        None.

        .NOTES
        Requires cluster ExtensionData to expose AbandonHciWorkflow. "The operation is not allowed in the current state" means the workflow is already skipped and is treated as success.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName
    )
    $clusterObject = Get-Cluster -Name $ClusterName -Server $Script:vCenterName -ErrorAction SilentlyContinue
    if (-not $clusterObject) {
        Write-LogMessage -Type DEBUG -Message "Cluster `"$ClusterName`" not found. Skipping AbandonHciWorkflow."
        return
    }
    $ext = $clusterObject.ExtensionData
    if (-not $ext -or -not (Get-Member -InputObject $ext -Name "AbandonHciWorkflow" -MemberType Method -ErrorAction SilentlyContinue)) {
        Write-LogMessage -Type DEBUG -Message "AbandonHciWorkflow not available on cluster `"$ClusterName`". Skipping (vCenter may not support HCI workflow skip)."
        return
    }
    try {
        $ext.AbandonHciWorkflow()
        Write-LogMessage -Type INFO -Message "Enabled vSAN health Alarms on cluster `"$ClusterName`"."
    } catch {
        $msg = $_.Exception.Message
        if ($msg -match "not allowed in the current state") {
            Write-LogMessage -Type DEBUG -Message "Quickstart workflow already skipped for cluster `"$ClusterName`" (not allowed in current state)."
            return
        }
        Write-LogMessage -Type DEBUG -Message "AbandonHciWorkflow failed for cluster `"$ClusterName`": $msg. Non-fatal; vSAN health alarms suppressed warning may persist."
    }
}
Function Add-VsanClusterSilentHealthChecks {

    <#
        .SYNOPSIS
        Adds vSAN health check IDs to the cluster silent-check list.

        .DESCRIPTION
        Uses VsanHealthGetVsanClusterSilentChecks and VsanHealthSetVsanClusterSilentChecks to append IDs
        that are not already silenced, in batches, so one invalid testId does not block the rest.
        Used whenever callers need to append silent-check IDs (for example Set-VsanLabSilentChecksIfRequested for
        lab-only lists). Stats Primary election is not silenced here; Invoke-VsanClusterHealthCheckAfterWitness uses
        re-trigger logic instead.

        .PARAMETER ClusterName
        Name of the vSAN cluster.

        .PARAMETER LogContext
        Short phrase included in INFO logs (for example lab environment or Stats Primary election).

        .PARAMETER SilentCheckBatchSize
        Maximum IDs per VsanHealthSetVsanClusterSilentChecks call. Default is 3.

        .PARAMETER SilentCheckIds
        vSAN health test IDs to add to the silent list.

        .NOTES
        Non-fatal when the cluster or VsanVcClusterHealthSystem view is missing; per-batch failures log WARNING.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$LogContext = "vSAN health",
        [Parameter(Mandatory = $false)] [ValidateRange(1, 10)] [Int]$SilentCheckBatchSize = 3,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [string[]]$SilentCheckIds
    )

    $checkIdsToApply = @($SilentCheckIds | Where-Object { -not [String]::IsNullOrWhiteSpace($_) })
    if ($checkIdsToApply.Count -eq 0) {
        Write-LogMessage -Type DEBUG -Message "No vSAN silent check IDs to apply for cluster `"$ClusterName`" ($LogContext). Skipping."
        return
    }
    $clusterObject = Get-Cluster -Name $ClusterName -Server $Script:vCenterName -ErrorAction SilentlyContinue
    if (-not $clusterObject) {
        Write-LogMessage -Type DEBUG -Message "Cluster `"$ClusterName`" not found. Skipping vSAN silent checks ($LogContext)."
        return
    }
    $healthSystemView = Get-VsanView -Id "VsanVcClusterHealthSystem-vsan-cluster-health-system" -Server $Script:vCenterName -ErrorAction SilentlyContinue
    if (-not $healthSystemView) {
        Write-LogMessage -Type DEBUG -Message "VsanVcClusterHealthSystem view not available. Skipping vSAN silent checks ($LogContext) for cluster `"$ClusterName`"."
        return
    }
    $clusterMoRef = $clusterObject.ExtensionData.MoRef
    $currentSilent = $null
    try {
        $currentSilent = $healthSystemView.VsanHealthGetVsanClusterSilentChecks($clusterMoRef)
    } catch {
        Write-LogMessage -Type DEBUG -Message "VsanHealthGetVsanClusterSilentChecks failed for cluster `"$ClusterName`" ($LogContext): $($_.Exception.Message). Skipping."
        return
    }
    $currentList = @($currentSilent)
    $toAdd = @($checkIdsToApply | Where-Object { $currentList -notcontains $_ })
    if ($toAdd.Count -eq 0) {
        $checksDisplay = $checkIdsToApply -join ", "
        Write-LogMessage -Type DEBUG -Message "vSAN checks ($checksDisplay) already silenced for cluster `"$ClusterName`" ($LogContext). Skipping."
        return
    }
    $batchSize = $SilentCheckBatchSize
    $failed = [System.Collections.ArrayList]::new()
    for ($i = 0; $i -lt $toAdd.Count; $i += $batchSize) {
        $endIdx = [Math]::Min($i + $batchSize - 1, $toAdd.Count - 1)
        $chunk = @($toAdd[$i..$endIdx])
        try {
            $healthSystemView.VsanHealthSetVsanClusterSilentChecks($clusterMoRef, $chunk, $null) | Out-Null
            Write-LogMessage -Type DEBUG -Message "Silenced vSAN health check ID(s) on cluster `"$ClusterName`" ($LogContext): $($chunk -join ', ')."
        } catch {
            Write-LogMessage -Type WARNING -Message "VsanHealthSetVsanClusterSilentChecks failed for cluster `"$ClusterName`" ($LogContext, batch: $($chunk -join ', ')): $($_.Exception.Message). Skipping this batch."
            [void]$failed.AddRange($chunk)
        }
    }
    if ($failed.Count -gt 0) {
        Write-LogMessage -Type DEBUG -Message "vSAN checks not silenced for cluster `"$ClusterName`" ($LogContext; invalid or unsupported testIds): $($failed -join ', ')."
    }
}
Function Set-VsanLabSilentChecksIfRequested {

    <#
        .SYNOPSIS
        Silences specified vSAN health checks when lab environment is enabled.

        .DESCRIPTION
        When LabEnvironmentEnabled is $true, calls Add-VsanClusterSilentHealthChecks with the default lab
        ID list (advcfgsync, controller disk/HCL-related IDs, and so on). When LabEnvironmentEnabled is
        $false or SilentCheckIds is empty after filtering, does nothing.

        .PARAMETER ClusterName
        Name of the vSAN cluster.

        .PARAMETER LabEnvironmentEnabled
        When $true, add the checks in SilentCheckIds to the cluster silent check list. When $false, no-op.

        .PARAMETER SilentCheckBatchSize
        Maximum number of check IDs per VsanHealthSetVsanClusterSilentChecks API call. Default is 3. Larger values may cause "General vSAN error" if any ID in the batch is invalid.

        .PARAMETER SilentCheckIds
        Array of vSAN health check IDs to silence. Default includes advcfgsync, controllerdiskmode, controlleronhcl, and additional Hardware Compatibility IDs (controllerfirmware, controllerdriver, hclhostbadstate) to help silence "vSAN hardware compatibility issues" in lab. When empty, no API calls are made. Applied in batches of SilentCheckBatchSize; unsupported IDs cause only that batch to be skipped.

        .EXAMPLE
        Set-VsanLabSilentChecksIfRequested -ClusterName "cl0-site1" -LabEnvironmentEnabled $true

        Silences the default lab checks for cluster cl0-site1.

        .NOTES
        Used only when infrastructure common.labenvironment is true. Non-fatal on API failure.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [bool]$LabEnvironmentEnabled,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 10)] [Int]$SilentCheckBatchSize = 3,
        [Parameter(Mandatory = $false)] [string[]]$SilentCheckIds = @("advcfgsync", "controllerdiskmode", "controlleronhcl", "controllerfirmware", "controllerdriver", "hclhostbadstate")
    )
    if (-not $LabEnvironmentEnabled) {
        return
    }
    $checkIdsToApply = @($SilentCheckIds | Where-Object { -not [String]::IsNullOrWhiteSpace($_) })
    if ($checkIdsToApply.Count -eq 0) {
        Write-LogMessage -Type DEBUG -Message "No lab vSAN silent check IDs specified. Skipping."
        return
    }
    # Flag HCL/hardware-compatibility checks separately from transient-sync. Silencing HCL checks masks
    # a real hardware non-conformance signal that WCP still enforces during supervisor enablement, so
    # a cluster that deploys cleanly in lab mode may fail to enable supervisor on the same hardware
    # outside lab mode. See Invoke-VsanClusterAlarmCheckAndRemediate for the matching alarm-gate warning.
    $hclMaskingIds = @("controllerdiskmode", "controlleronhcl", "controllerfirmware", "controllerdriver", "hclhostbadstate")
    $hclIdsBeingSilenced = @($checkIdsToApply | Where-Object { $hclMaskingIds -contains $_ })
    if ($hclIdsBeingSilenced.Count -gt 0) {
        Write-LogMessage -Type WARNING -Message "Lab mode (common.labenvironment=true) will silence vSAN HCL/hardware-compatibility health checks on cluster `"$ClusterName`": $($hclIdsBeingSilenced -join ', '). These mask red vSAN alarms that would otherwise block the pre-supervisor alarm gate; the underlying hardware state is unchanged. WCP supervisor enablement enforces cluster/host HCL conformance downstream, so the same hardware may succeed in lab mode and fail to deploy supervisor outside lab mode. Use HCL-listed storage controllers, firmware, and drivers for production-equivalent deployments."
    }
    Add-VsanClusterSilentHealthChecks -ClusterName $ClusterName -LogContext "lab environment" -SilentCheckBatchSize $SilentCheckBatchSize -SilentCheckIds $checkIdsToApply
}
Function Invoke-VsanClusterHealthRetestAfterDeployment {

    <#
        .SYNOPSIS
        Runs an on-demand vSAN cluster health test after a successful edge deployment.

        .DESCRIPTION
        When Test-VsanClusterHealth is available (VCF PowerCLI / VMware.Storage), invokes it without
        -UseCache so vCenter runs a full health evaluation similar to choosing RETEST in the vSAN Health UI.
        Passes -VMCreateTimeoutSeconds when the cmdlet supports it so VM-creation subtests honor a bounded timeout.
        Failures are non-fatal so automation completes; operators can review vSAN Health in vCenter afterward.

        .PARAMETER ClusterName
        The vSAN cluster name.

        .PARAMETER Server
        vCenter FQDN. Defaults to $Script:vCenterName.

        .PARAMETER VmCreateTimeoutSeconds
        When supported by Test-VsanClusterHealth, limits VM creation test duration (default 120). Raise only if Broadcom guidance or support recommends a longer window.

        .NOTES
        Does not SSH to ESX or restart vsanmgmtd; for Stats Primary election remediation see Broadcom KB 401679.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$Server = $Script:vCenterName,
        [Parameter(Mandatory = $false)] [ValidateRange(60, 900)] [Int]$VmCreateTimeoutSeconds = 120
    )

    $testCmd = Get-Command -Name "Test-VsanClusterHealth" -ErrorAction SilentlyContinue
    if (-not $testCmd) {
        Write-LogMessage -Type DEBUG -Message "Test-VsanClusterHealth is not available; skipping post-deployment vSAN health retest for cluster `"$ClusterName`"."
        return
    }
    try {
        $clusterObject = Get-Cluster -Name $ClusterName -Server $Server -ErrorAction Stop
        $invokeParams = @{
            Cluster = $clusterObject
            ErrorAction = "Stop"
            Server = $Server
        }
        if ($testCmd.Parameters.ContainsKey("VMCreateTimeoutSeconds")) {
            $invokeParams["VMCreateTimeoutSeconds"] = $VmCreateTimeoutSeconds
        }
        $timeoutNote = if ($invokeParams.ContainsKey("VMCreateTimeoutSeconds")) { "VMCreateTimeoutSeconds=$VmCreateTimeoutSeconds" } else { "VMCreateTimeoutSeconds=cmdlet default" }
        Write-LogMessage -Type INFO -Message "Running on-demand vSAN health test for cluster `"$ClusterName`" (vSAN Health RETEST equivalent after deployment; $timeoutNote)."
        $null = Test-VsanClusterHealth @invokeParams
        Write-LogMessage -Type INFO -Message "On-demand vSAN health test completed for cluster `"$ClusterName`". Refresh vSAN Health in vCenter to review current status."
    } catch {
        Write-LogMessage -Type WARNING -Message "Post-deployment vSAN health test failed for cluster `"$ClusterName`" (non-fatal): $($_.Exception.Message). Run vSAN Health > RETEST in vCenter if you need an updated evaluation."
    }
}
Function Enable-VsanPerformanceService {

    <#
        .SYNOPSIS
        Enables the vSAN performance service on a cluster after vSAN configuration is complete.

        .DESCRIPTION
        Calls Set-VsanClusterConfiguration -PerformanceServiceEnabled $true when the cmdlet supports that parameter. The performance service stores history in a vSAN object; enabling it is non-fatal to skip on failure or unsupported PowerCLI.

        .PARAMETER ClusterName
        Name of the vSAN cluster.

        .PARAMETER Server
        vCenter server. Default is $Script:vCenterName.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$Server = $Script:vCenterName
    )
    $setCmd = Get-Command Set-VsanClusterConfiguration -ErrorAction SilentlyContinue
    if (-not $setCmd -or -not $setCmd.Parameters.ContainsKey("PerformanceServiceEnabled")) {
        Write-LogMessage -Type DEBUG -Message "Set-VsanClusterConfiguration does not support -PerformanceServiceEnabled. Skipping vSAN performance service enablement."
        return
    }
    try {
        $cluster = Get-Cluster -Name $ClusterName -Server $Server -ErrorAction Stop
        $config = Get-VsanClusterConfiguration -Cluster $cluster -Server $Server -ErrorAction Stop
        if ($config.PerformanceServiceEnabled -eq $true) {
            Write-LogMessage -Type DEBUG -Message "vSAN performance service (stats/health) is already enabled on cluster `"$ClusterName`". Skipping."
            return
        }
        Set-VsanClusterConfiguration -Configuration $config -PerformanceServiceEnabled $true -Server $Server -ErrorAction Stop | Out-Null
        Write-LogMessage -Type DEBUG -Message "Enabled vSAN performance service on cluster `"$ClusterName`"."
    } catch {
        Write-LogMessage -Type WARNING -Message "Failed to enable vSAN performance service on cluster `"$ClusterName`": $($_.Exception.Message). Continuing."
    }
}
Function Test-VsanHealthTestDetailsStatsPrimaryElection {

    <#
        .SYNOPSIS
        Returns whether a vSAN health test object describes Stats Primary election/selection.

        .PARAMETER Test
        A single test entry from the vSAN health summary groups[].tests collection.

        .OUTPUTS
        Boolean.
    #>

    [CmdletBinding()]
    [OutputType([bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] $Test
    )

    $testId = $Test.PSObject.Properties["testId"].Value
    $testName = $Test.PSObject.Properties["testName"].Value
    $description = $Test.PSObject.Properties["description"].Value
    $blob = " $testId $testName $description "
    # Broadcom documents perfsvc.masterexist; older builds may alter separators or append suffixes in testId/testName.
    if ($blob -match "(?i)perfsvc\.masterexist|perfsvc[^\w]{0,12}masterexist") {
        return $true
    }
    if ($blob -match "(?i)stats\s+primary\s+election") {
        return $true
    }
    if ($blob -match "(?i)stats\s+primary\s+selection") {
        return $true
    }
    return $false
}
Function Test-VsanHealthFailureTextOnlyStatsPrimaryElection {

    <#
        .SYNOPSIS
        Heuristic: failure text appears limited to Stats Primary election/selection themes.

        .PARAMETER FailureText
        Concatenated failure reasons (for example from Get-VsanHealthFailureReasons).

        .OUTPUTS
        Boolean.
    #>

    [CmdletBinding()]
    [OutputType([bool])]
    Param (
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [String]$FailureText
    )

    if ([String]::IsNullOrWhiteSpace($FailureText)) {
        return $false
    }
    if ($FailureText -notmatch "(?i)stats\s+primary\s+(election|selection)|perfsvc\.masterexist|perfsvc[^\w]{0,12}masterexist") {
        return $false
    }
    if ($FailureText -match "(?i)partition|network misconfiguration|resync|disk data|I/O|corrupt|inconsistent|inaccessible|advCfgSync|HCL|hardware compatibility") {
        return $false
    }
    return $true
}
Function Test-VsanHealthSummaryNonGreenOnlyStatsPrimaryElection {

    <#
        .SYNOPSIS
        Returns true when overall health is not green and every non-green test looks like Stats Primary election/selection.

        .PARAMETER HealthSummary
        vSAN cluster health summary from Get-VsanClusterHealthSummaryViaView.

        .OUTPUTS
        Boolean.
    #>

    [CmdletBinding()]
    [OutputType([bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] $HealthSummary
    )

    $overallHealth = $HealthSummary.overallHealth
    if (-not $overallHealth -or $overallHealth -eq "green") {
        return $false
    }
    $healthGroups = $HealthSummary.groups
    $anyNonGreenTest = $false
    if ($healthGroups) {
        foreach ($healthGroup in @($healthGroups)) {
            $tests = $healthGroup.PSObject.Properties["tests"].Value
            if (-not $tests) {
                continue
            }
            foreach ($test in @($tests)) {
                $testHealth = $test.PSObject.Properties["health"].Value
                if (-not $testHealth -or $testHealth -eq "green") {
                    continue
                }
                $anyNonGreenTest = $true
                if (-not (Test-VsanHealthTestDetailsStatsPrimaryElection -Test $test)) {
                    return $false
                }
            }
        }
    }
    if ($anyNonGreenTest) {
        return $true
    }
    $failureText = Get-VsanHealthFailureReasons -HealthSummary $HealthSummary
    return (Test-VsanHealthFailureTextOnlyStatsPrimaryElection -FailureText $failureText)
}
Function Invoke-VsanClusterHealthRetriggerForStatsPrimary {

    <#
        .SYNOPSIS
        Re-triggers vSAN Health evaluation for transient Stats Primary election/selection without silencing tests.

        .DESCRIPTION
        Ensures the vSAN performance service is enabled, runs Test-VsanClusterHealth when the cmdlet exists
        (passes -VMCreateTimeoutSeconds when supported), then waits so vCenter can refresh summaries.

        .PARAMETER ClusterName
        Cluster name.

        .PARAMETER Server
        vCenter server. Default is $Script:vCenterName.

        .PARAMETER VmCreateTimeoutSeconds
        Passed to Test-VsanClusterHealth when the parameter exists (default 120).

        .PARAMETER WaitAfterTriggerSeconds
        Seconds to sleep after re-trigger actions before callers re-fetch health. Default 45.

        .NOTES
        Non-fatal when Test-VsanClusterHealth throws; callers should re-query Get-VsanClusterHealthSummaryViaView.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$Server = $Script:vCenterName,
        [Parameter(Mandatory = $false)] [ValidateRange(5, 600)] [Int]$WaitAfterTriggerSeconds = 45,
        [Parameter(Mandatory = $false)] [ValidateRange(60, 900)] [Int]$VmCreateTimeoutSeconds = 120
    )

    Enable-VsanPerformanceService -ClusterName $ClusterName -Server $Server | Out-Null
    $testCmd = Get-Command -Name "Test-VsanClusterHealth" -ErrorAction SilentlyContinue
    if (-not $testCmd) {
        Write-LogMessage -Type DEBUG -Message "Test-VsanClusterHealth is not available; Stats Primary re-trigger for cluster `"$ClusterName`" will use performance service and wait only."
    } else {
        try {
            $clusterObject = Get-Cluster -Name $ClusterName -Server $Server -ErrorAction Stop
            $invokeParams = @{
                Cluster = $clusterObject
                ErrorAction = "Stop"
                Server = $Server
            }
            if ($testCmd.Parameters.ContainsKey("VMCreateTimeoutSeconds")) {
                $invokeParams["VMCreateTimeoutSeconds"] = $VmCreateTimeoutSeconds
            }
            $timeoutNote = if ($invokeParams.ContainsKey("VMCreateTimeoutSeconds")) { "VMCreateTimeoutSeconds=$VmCreateTimeoutSeconds" } else { "VMCreateTimeoutSeconds=cmdlet default" }
            Write-LogMessage -Type INFO -Message "Running Test-VsanClusterHealth to refresh vSAN Health for cluster `"$ClusterName`" ($timeoutNote)."
            $null = Test-VsanClusterHealth @invokeParams
        } catch {
            Write-LogMessage -Type WARNING -Message "Test-VsanClusterHealth failed during Stats Primary re-trigger for cluster `"$ClusterName`" (non-fatal): $($_.Exception.Message). A newer vCenter build or PowerCLI module may expose this cmdlet; otherwise use vSAN Health > RETEST in the UI."
        }
    }
    if ($WaitAfterTriggerSeconds -gt 0) {
        Write-LogMessage -Type DEBUG -Message "Waiting $WaitAfterTriggerSeconds seconds after Stats Primary re-trigger for cluster `"$ClusterName`"."
        Start-Sleep -Seconds $WaitAfterTriggerSeconds
    }
}
Function Invoke-VsanClusterHealthCheckAfterWitness {

    <#
        .SYNOPSIS
        Runs vSAN cluster health check after the vSAN cluster and witness have been configured.

        .DESCRIPTION
        Called after vSAN cluster creation and witness addition. Checks overall health and partition
        status. If the cluster is partitioned, triggers object repair (resync), waits for the repair
        task, then rechecks partition. If not partitioned, evaluates health: green proceeds; not
        green reports why, waits RetryWaitSeconds, then rechecks once. Yellow results in a warning and
        proceed; red on the second check offers the user the option to proceed and accept the risk or exit.
        When health is not green only because of Stats Primary election/selection (transient performance-service
        leader election), the function re-triggers evaluation (performance service + Test-VsanClusterHealth when
        available + wait) up to StatsPrimaryElectionRetryMaxAttempts without silencing checks; if still only that
        finding, it proceeds with a warning. Older vCenter builds may use different test labels; Test-VsanHealthSummaryNonGreenOnlyStatsPrimaryElection matches common strings and testId text.

        .PARAMETER ClusterName
        The name of the vSAN cluster. Must be a non-empty string.

        .PARAMETER RepairTaskTimeoutSeconds
        Maximum seconds to wait for the object repair task when partition is detected. Default is 600.

        .PARAMETER RetryWaitSeconds
        Seconds to wait before rechecking health when not green. Default is 180 (3 minutes).

        .PARAMETER StatsPrimaryElectionRetryMaxAttempts
        How many times to re-trigger health when the only non-green findings match Stats Primary election/selection. Default is 4.

        .PARAMETER StatsPrimaryElectionRetryWaitSeconds
        Seconds to wait after each re-trigger before re-reading health. Default is 45.

        .PARAMETER StatsPrimaryHealthTestVmCreateTimeoutSeconds
        Passed to Test-VsanClusterHealth -VMCreateTimeoutSeconds when supported. Default is 120.

        .PARAMETER StoragePolicyType
        vSAN-OSA or vSAN-ESA. Required when the user declines to proceed with red health (N) so that rollback can be initiated. If not provided and user declines, rollback is still performed by the caller after this function throws.

        .PARAMETER AcceptBadCheckResults
        When specified, automatically proceed when vSAN cluster health is red (no Y/N prompt). Equivalent to answering Y to accept the risk.

        .PARAMETER HciWorkflowClearWaitSeconds
        Seconds to wait after skipping the vCenter Quickstart (HCI) workflow before fetching health, so the "vSAN health alarms are suppressed" state can clear. Default is 20. Use 0 to skip the wait.

        .PARAMETER LabEnvironment
        When $true (e.g. common.labenvironment is true), silences additional lab-oriented vSAN health checks (see Set-VsanLabSilentChecksIfRequested defaults) before evaluating health. Stats Primary election is not silenced; transient cases use re-trigger + optional proceed-with-warning logic instead.

        .NOTES
        Requires connection to vCenter. Uses Get-VsanView and vSAN Health API (VCF PowerCLI 9).
        When vSAN health is red and the user chooses not to proceed (N), this function initiates Invoke-VsanDeploymentRollback before throwing, so the cluster is cleaned up.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [Switch]$AcceptBadCheckResults,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [ValidateRange(0, 120)] [int]$HciWorkflowClearWaitSeconds = 20,
        [Parameter(Mandatory = $false)] [bool]$LabEnvironment = $false,
        [Parameter(Mandatory = $false)] [ValidateRange(60, 3600)] [int]$RepairTaskTimeoutSeconds = 600,
        [Parameter(Mandatory = $false)] [ValidateRange(60, 600)] [int]$RetryWaitSeconds = 180,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 12)] [Int]$StatsPrimaryElectionRetryMaxAttempts = 4,
        [Parameter(Mandatory = $false)] [ValidateRange(5, 600)] [Int]$StatsPrimaryElectionRetryWaitSeconds = 45,
        [Parameter(Mandatory = $false)] [ValidateRange(60, 900)] [Int]$StatsPrimaryHealthTestVmCreateTimeoutSeconds = 120,
        [Parameter(Mandatory = $false)] [ValidateSet("vSAN-ESA", "vSAN-OSA")] [String]$StoragePolicyType
    )

    Write-LogMessage -Type DEBUG -Message "Running vSAN cluster health check for cluster `"$ClusterName`" (after witness)."

    # Validate vCenter connection before proceeding.
    $connectionTest = Test-VcenterConnection
    if (-not $connectionTest.IsConnected) {
        Write-LogMessage -Type ERROR -Message "Not connected to vCenter: $($connectionTest.ErrorMessage)"
        throw [VcfDeploymentException]::new("Deployment failed. vSAN health check requires vCenter connection.")
    }

    # Re-enable vSAN health alarms if they are suppressed so we evaluate real health and get full findings.
    Enable-VsanHealthAlarms -ClusterName $ClusterName | Out-Null

    # Skip vCenter Quickstart (HCI) workflow so the "vSAN health alarms are suppressed" (hciskip) warning can clear.
    Invoke-AbandonHciWorkflowIfInProgress -ClusterName $ClusterName

    if ($HciWorkflowClearWaitSeconds -gt 0) {
        Write-LogMessage -Type DEBUG -Message "Waiting $HciWorkflowClearWaitSeconds seconds for vSAN health service to reflect HCI workflow skip."
        Start-Sleep -Seconds $HciWorkflowClearWaitSeconds
    }

    # When lab environment is enabled, silence additional lab-oriented checks so lab deployments do not fail on those findings.
    if ($LabEnvironment) {
        Set-VsanLabSilentChecksIfRequested -ClusterName $ClusterName -LabEnvironmentEnabled $true
    }

    # Get the health summary for the cluster.
    $healthSummary = Get-VsanClusterHealthSummaryViaView -ClusterName $ClusterName -FetchFromCache $false
    if (-not $healthSummary) {
        Write-VsanHealthFailureDebugInfo -ClusterName $ClusterName -Context 'health_summary_null'
        Write-LogMessage -Type ERROR -Message "Could not retrieve vSAN health summary for cluster `"$ClusterName`"."
        throw [VcfDeploymentException]::new("Deployment failed. vSAN health check could not retrieve health summary.")
    }

    # Check if the cluster is partitioned.
    $clusterPartitioned = Test-VsanClusterPartitioned -HealthSummary $healthSummary
    if ($clusterPartitioned) {
        Write-VsanHealthFailureDebugInfo -ClusterName $ClusterName -Context 'partition_detected' -HealthSummary $healthSummary
        # Partition detected: trigger repair, wait for task, then recheck partition.
        Write-LogMessage -Type WARNING -Message "vSAN cluster `"$ClusterName`" is partitioned. Triggering object repair (resync)."
        $repairSucceeded = Invoke-VsanClusterObjectRepairAndWait -ClusterName $ClusterName -TimeoutSeconds $RepairTaskTimeoutSeconds
        if (-not $repairSucceeded) {
            Write-VsanHealthFailureDebugInfo -ClusterName $ClusterName -Context 'repair_failed'
            Write-LogMessage -Type ERROR -Message "vSAN object repair did not complete successfully for cluster `"$ClusterName`"."
            throw [VcfDeploymentException]::new("Deployment failed. vSAN cluster is partitioned and repair did not complete. Resolve partition (e.g. network/unicast) and retry.")
        }
        # Recheck the health summary after repair.
        Write-LogMessage -Type INFO -Message "Rechecking partition status for cluster `"$ClusterName`"."
        $healthSummary = Get-VsanClusterHealthSummaryViaView -ClusterName $ClusterName -FetchFromCache $false
        if (-not $healthSummary) {
            Write-VsanHealthFailureDebugInfo -ClusterName $ClusterName -Context 'health_summary_null'
            Write-LogMessage -Type ERROR -Message "Could not retrieve vSAN health summary after repair."
            throw [VcfDeploymentException]::new("Deployment failed. vSAN health recheck failed after repair.")
        }
        # Check if the cluster is partitioned again after repair.
        $clusterPartitioned = Test-VsanClusterPartitioned -HealthSummary $healthSummary
        if ($clusterPartitioned) {
            Write-VsanHealthFailureDebugInfo -ClusterName $ClusterName -Context 'partition_after_repair' -HealthSummary $healthSummary
            Write-LogMessage -Type ERROR -Message "vSAN cluster `"$ClusterName`" is still partitioned after repair."
            throw [VcfDeploymentException]::new("Deployment failed. vSAN cluster remains partitioned after repair. Resolve network/partition (e.g. unicast agent list) and retry.")
        }
        Write-LogMessage -Type INFO -Message "Partition resolved for cluster `"$ClusterName`". Proceeding to health check."
    }
    # Check if the cluster is green.
    $overallHealth = $healthSummary.overallHealth
    if (-not $overallHealth) { $overallHealth = 'unknown' }
    if ($overallHealth -eq 'green') {
        Test-VsanAdvCfgSyncAndWaitIfNeeded -ClusterName $ClusterName -HealthSummary $healthSummary
        Write-LogMessage -Type INFO -Message "vSAN cluster health is green for cluster `"$ClusterName`". Proceeding."
        return
    }

    # Transient Stats Primary election/selection: re-enable performance service, run Test-VsanClusterHealth when available, wait, and re-fetch—without silencing health checks.
    $statsRetryIdx = 0
    while (
        ($overallHealth -ne 'green') -and
        (Test-VsanHealthSummaryNonGreenOnlyStatsPrimaryElection -HealthSummary $healthSummary) -and
        ($statsRetryIdx -lt $StatsPrimaryElectionRetryMaxAttempts)
    ) {
        $statsRetryIdx++
        Write-LogMessage -Type INFO -Message "vSAN health is not green but only Stats Primary election/selection is reported for cluster `"$ClusterName`"; re-triggering health evaluation (attempt $statsRetryIdx of $StatsPrimaryElectionRetryMaxAttempts). No silent-check API calls are used."
        Invoke-VsanClusterHealthRetriggerForStatsPrimary -ClusterName $ClusterName -Server $Script:vCenterName -VmCreateTimeoutSeconds $StatsPrimaryHealthTestVmCreateTimeoutSeconds -WaitAfterTriggerSeconds $StatsPrimaryElectionRetryWaitSeconds
        $healthSummary = Get-VsanClusterHealthSummaryViaView -ClusterName $ClusterName -FetchFromCache $false
        if (-not $healthSummary) {
            Write-LogMessage -Type WARNING -Message "Could not refresh vSAN health summary after Stats Primary re-trigger for cluster `"$ClusterName`"; stopping retry loop."
            break
        }
        $overallHealth = $healthSummary.overallHealth
        if (-not $overallHealth) { $overallHealth = 'unknown' }
        if ($overallHealth -eq 'green') {
            Test-VsanAdvCfgSyncAndWaitIfNeeded -ClusterName $ClusterName -HealthSummary $healthSummary
            Write-LogMessage -Type INFO -Message "vSAN cluster health is green for cluster `"$ClusterName`" after Stats Primary re-trigger. Proceeding."
            return
        }
    }
    if (($overallHealth -ne 'green') -and ($healthSummary) -and (Test-VsanHealthSummaryNonGreenOnlyStatsPrimaryElection -HealthSummary $healthSummary)) {
        Write-LogMessage -Type WARNING -Message "Stats Primary election/selection still reported after $StatsPrimaryElectionRetryMaxAttempts re-trigger attempt(s) for cluster `"$ClusterName`"; treating as transient and proceeding. Monitor vSAN Health and Broadcom KB 401679 if the performance service stays unhealthy."
        Test-VsanAdvCfgSyncAndWaitIfNeeded -ClusterName $ClusterName -HealthSummary $healthSummary
        return
    }

    $failureReasons = Get-VsanHealthFailureReasons -HealthSummary $healthSummary
    $overallDescription = $healthSummary.overallHealthDescription
    $networkDesc = if ($healthSummary.networkHealth -and $healthSummary.networkHealth.description) { $healthSummary.networkHealth.description } else { $null }

    Write-LogMessage -Type DEBUG -Message "vSAN health not green. overallHealth=$overallHealth, overallHealthDescription=$overallDescription, failureReasons=$failureReasons, networkHealthDescription=$networkDesc"
    Write-LogMessage -Type WARNING -Message "vSAN cluster health is not green for `"$ClusterName`" (status: $overallHealth): $failureReasons"

    # When the only reported issue is "vSAN health alarms are suppressed", wait and re-abandon HCI workflow then recheck; proceed if still suppressed so deployment does not block.
    $onlySuppressedAlarm = ($failureReasons -match 'alarms are suppressed|hciskip') -and ($failureReasons -notmatch 'partition|Network misconfiguration|resync')
    if ($onlySuppressedAlarm -and $HciWorkflowClearWaitSeconds -gt 0) {
        Write-LogMessage -Type INFO -Message "Only failure is vSAN health alarms suppressed; waiting $HciWorkflowClearWaitSeconds seconds and re-skipping HCI workflow before recheck."
        Start-Sleep -Seconds $HciWorkflowClearWaitSeconds
        Invoke-AbandonHciWorkflowIfInProgress -ClusterName $ClusterName
        $healthSummarySuppressed = Get-VsanClusterHealthSummaryViaView -ClusterName $ClusterName -FetchFromCache $false
        if ($healthSummarySuppressed) {
            $overallSuppressed = $healthSummarySuppressed.overallHealth
            if (-not $overallSuppressed) { $overallSuppressed = 'unknown' }
            if ($overallSuppressed -eq 'green') {
                Test-VsanAdvCfgSyncAndWaitIfNeeded -ClusterName $ClusterName -HealthSummary $healthSummarySuppressed
                Write-LogMessage -Type INFO -Message "vSAN cluster health is green after HCI workflow re-skip for cluster `"$ClusterName`". Proceeding."
                return
            }
            $failureReasonsSuppressed = Get-VsanHealthFailureReasons -HealthSummary $healthSummarySuppressed
            $stillOnlySuppressed = ($failureReasonsSuppressed -match 'alarms are suppressed|hciskip') -and ($failureReasonsSuppressed -notmatch 'partition|Network misconfiguration|resync')
            if ($stillOnlySuppressed) {
                Write-LogMessage -Type WARNING -Message "vSAN health alarms suppressed warning persists for `"$ClusterName`"; proceeding. Alarm may clear shortly in vCenter."
                return
            }
            # Other issues appeared; use the refreshed summary and fall through to partition/repair and retry logic.
            $healthSummary = $healthSummarySuppressed
            $failureReasons = $failureReasonsSuppressed
            $overallHealth = $overallSuppressed
        }
    }

    $suggestsPartitionOrNetwork = Test-VsanHealthSuggestsPartitionOrNetwork -HealthSummary $healthSummary

    if ($suggestsPartitionOrNetwork) {

        Write-LogMessage -Type DEBUG -Message "Treating as possible network partition or initial sync; triggering object repair (resync) for cluster `"$ClusterName`"."
        Write-LogMessage -Type INFO -Message "Triggering vSAN object repair (resync) for cluster `"$ClusterName`" (possible network/partition or initial sync)."

        $repairSucceeded = Invoke-VsanClusterObjectRepairAndWait -ClusterName $ClusterName -TimeoutSeconds $RepairTaskTimeoutSeconds

        if (-not $repairSucceeded) {
            Write-VsanHealthFailureDebugInfo -ClusterName $ClusterName -Context 'repair_failed'
            Write-LogMessage -Type WARNING -Message "vSAN object repair did not complete successfully for cluster `"$ClusterName`"; will wait and recheck health."
        } else {
            Write-LogMessage -Type INFO -Message "Rechecking health after repair for cluster `"$ClusterName`"."
            $healthSummary = Get-VsanClusterHealthSummaryViaView -ClusterName $ClusterName -FetchFromCache $false

            if ($healthSummary) {
                $clusterPartitioned = Test-VsanClusterPartitioned -HealthSummary $healthSummary
                if ($clusterPartitioned) {
                    Write-VsanHealthFailureDebugInfo -ClusterName $ClusterName -Context 'partition_after_repair' -HealthSummary $healthSummary
                    Write-LogMessage -Type ERROR -Message "vSAN cluster `"$ClusterName`" is partitioned after repair."
                    throw [VcfDeploymentException]::new("Deployment failed. vSAN cluster is partitioned after repair. Resolve network/partition (e.g. unicast agent list) and retry.")
                }
                $overallHealth = $healthSummary.overallHealth

                if (-not $overallHealth) { $overallHealth = 'unknown' }
                if ($overallHealth -eq 'green') {
                    Test-VsanAdvCfgSyncAndWaitIfNeeded -ClusterName $ClusterName -HealthSummary $healthSummary
                    Write-LogMessage -Type INFO -Message "vSAN cluster health is green after repair for cluster `"$ClusterName`". Proceeding."
                    return
                }
                $failureReasons = Get-VsanHealthFailureReasons -HealthSummary $healthSummary
                Write-LogMessage -Type DEBUG -Message "Health still not green after repair. overallHealth=$overallHealth, failureReasons=$failureReasons"
            }
        }
    }
    # Not green: wait, then recheck once. Yellow proceeds with warning; red fails.
    Write-LogMessage -Type INFO -Message "Waiting $RetryWaitSeconds seconds before rechecking health."
    Start-Sleep -Seconds $RetryWaitSeconds
    # Recheck the health summary after waiting.
    $healthSummary = Get-VsanClusterHealthSummaryViaView -ClusterName $ClusterName -FetchFromCache $true
    if (-not $healthSummary) {
        Write-VsanHealthFailureDebugInfo -ClusterName $ClusterName -Context 'health_summary_null'
        Write-LogMessage -Type WARNING -Message "Could not retrieve health on retry; using previous status."
    } else {
        # Get the overall health from the health summary.
        $overallHealth = $healthSummary.overallHealth
        if (-not $overallHealth) { $overallHealth = 'unknown' }
    }
    # Evaluate retry result: green proceed, yellow warn and proceed, red fail.
    # When retry failed to get a new summary ($healthSummary is null), keep using pre-wait $failureReasons.
    if ($healthSummary) {
        $retryFailureReasons = Get-VsanHealthFailureReasons -HealthSummary $healthSummary
    } else {
        $retryFailureReasons = $failureReasons
    }
    $proceedReason = $null
    switch ($overallHealth) {
        'green' {
            $proceedReason = 'green'
        }
        'yellow' {
            $proceedReason = 'yellow'
        }
        'red' {
            Write-VsanHealthFailureDebugInfo -ClusterName $ClusterName -Context 'health_red' -HealthSummary $healthSummary
            Write-LogMessage -Type ERROR -Message "vSAN cluster health is red for `"$ClusterName`" (second check): $retryFailureReasons"
            if ($AcceptBadCheckResults.IsPresent) {
                Write-LogMessage -Type WARNING -Message "AcceptBadCheckResults is set; proceeding despite vSAN red health for cluster `"$ClusterName`"."
                return
            }
            Write-LogMessage -Type WARNING -Message "vSAN cluster health is red. You may proceed and accept the risk (Y), or decline (N) to stop deployment and run rollback so you can resolve vSAN issues first."
            $proceedPrompt = "Proceed anyway and accept the risk? (Y/N)"
            do {
                $proceedResponse = Read-Host $proceedPrompt
                $proceedResponse = if ($proceedResponse) { $proceedResponse.Trim() } else { "" }
                if ($proceedResponse -match '^Y(es)?$') {
                    Write-LogMessage -Type WARNING -Message "User chose to proceed despite vSAN red health for cluster `"$ClusterName`". Accepting risk."
                    return
                }
                if ($proceedResponse -match '^N(o)?$') {
                    Write-LogMessage -Type INFO -Message "User chose not to proceed due to vSAN red health for cluster `"$ClusterName`". You will be prompted whether to roll back (same sequence as cleanup)."
                    if (-not $StoragePolicyType) {
                        Write-LogMessage -Type WARNING -Message "StoragePolicyType not passed to health check; caller will need to perform rollback."
                    }
                    throw "Deployment failed. vSAN cluster health is red: $retryFailureReasons"
                }
                Write-LogMessage -Type WARNING -Message "Invalid response. Please enter Y or N."
            } while ($true)
        }
        default {
            $proceedReason = 'unknown'
        }
    }
    if ($proceedReason) {
        if ($healthSummary) {
            Test-VsanAdvCfgSyncAndWaitIfNeeded -ClusterName $ClusterName -HealthSummary $healthSummary
        }
        switch ($proceedReason) {
            'green' { Write-LogMessage -Type INFO -Message "vSAN cluster health is green on retry for cluster `"$ClusterName`". Proceeding." }
            'yellow' { Write-LogMessage -Type WARNING -Message "vSAN cluster health is yellow for `"$ClusterName`" after retry: $retryFailureReasons. Proceeding with warning." }
            default { Write-LogMessage -Type WARNING -Message "vSAN cluster health status is `"$overallHealth`" for `"$ClusterName`". Proceeding with warning." }
        }
    }
}
Function Remove-StorageTag {
    <#
        .SYNOPSIS
        Removes the storage tag (tag definition) from vCenter. Used during vSAN deployment rollback to clean up the tag created for the storage policy.

        .DESCRIPTION
        Looks up the tag by name and category, then removes it from vCenter (Remove-Tag). Removing the tag
        also removes any tag assignments to datastores or other entities. Best-effort: logs warnings and
        does not throw so callers (e.g. rollback) can continue.

        .PARAMETER TagName
        The name of the tag to remove (e.g. the supervisor name used for storage policy).

        .PARAMETER TagCatalog
        The tag category (catalog) name containing the tag.

        .PARAMETER Server
        vCenter server name. Default is $Script:vCenterName.

        .EXAMPLE
        Remove-StorageTag -TagName "SupervisorCluster01" -TagCatalog "EdgeNodePolicy" -Server $Script:vCenterName

        .NOTES
        Requires connection to vCenter. Uses Get-Tag and Remove-Tag. If the tag does not exist, the function returns without error.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$TagName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$TagCatalog,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$Server = $Script:vCenterName
    )

    try {
        $tagObject = Get-Tag -Name $TagName -Category $TagCatalog -Server $Server -ErrorAction SilentlyContinue
        if (-not $tagObject) {
            Write-LogMessage -Type DEBUG -Message "Storage tag `"$TagName`" (catalog `"$TagCatalog`") not found; nothing to remove."
            return
        }
        Write-LogMessage -Type INFO -NoNewline -Message "Removing storage tag `"$TagName`" (catalog `"$TagCatalog`") from vCenter... "
        Remove-Tag -Tag $tagObject -Server $Server -Confirm:$false -ErrorAction Stop
        Write-LogMessage -Type INFO -CompletePending -Message "Removed"
    } catch {
        if ($null -ne $Script:LogMessagePending) {
            Write-LogMessage -Type WARNING -CompletePending -Message " Failed."
        }
        Write-LogMessage -Type WARNING -Message "Could not remove storage tag `"$TagName`" (catalog `"$TagCatalog`"): $($_.Exception.Message). Tag may need to be removed manually."
    }
}
Function Remove-TagCategoryIfEmpty {

    <#
        .SYNOPSIS
        Removes a tag category from vCenter only if it has no tags associated with it.

        .DESCRIPTION
        Looks up the tag category by name and checks whether any tags exist in that category.
        If no tags are present, removes the category (Remove-TagCategory). If other tags exist,
        the category is left in place. Used during storage deployment cleanup so the catalog
        created for the deployment can be removed when it is empty. Best-effort: logs warnings
        and does not throw.

        .PARAMETER TagCatalog
        The tag category (catalog) name to remove if empty.

        .PARAMETER Server
        vCenter server name. Default is $Script:vCenterName.

        .EXAMPLE
        Remove-TagCategoryIfEmpty -TagCatalog "Storage-TagCatalog" -Server $Script:vCenterName

        .NOTES
        Requires connection to vCenter. Uses Get-TagCategory, Get-Tag, and Remove-TagCategory.
        Call after Remove-StorageTag during rollback when the category may have no remaining tags.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$TagCatalog,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$Server = $Script:vCenterName
    )

    try {
        $categoryObject = Get-TagCategory -Name $TagCatalog -Server $Server -ErrorAction SilentlyContinue
        if (-not $categoryObject) {
            Write-LogMessage -Type DEBUG -Message "Tag category `"$TagCatalog`" not found; nothing to remove."
            return
        }
        $tagsInCategory = Get-Tag -Category $TagCatalog -Server $Server -ErrorAction SilentlyContinue
        $tagCount = if ($tagsInCategory) { @($tagsInCategory).Count } else { 0 }
        if ($tagCount -gt 0) {
            Write-LogMessage -Type DEBUG -Message "Tag category `"$TagCatalog`" has $tagCount other tag(s); leaving category in place."
            return
        }
        Write-LogMessage -Type INFO -NoNewline -Message "Removing empty tag category `"$TagCatalog`" from vCenter... "
        Remove-TagCategory -Category $categoryObject -Server $Server -Confirm:$false -ErrorAction Stop
        Write-LogMessage -Type INFO -CompletePending -Message "Removed"
    } catch {
        if ($null -ne $Script:LogMessagePending) {
            Write-LogMessage -Type WARNING -CompletePending -Message " Failed."
        }
        Write-LogMessage -Type WARNING -Message "Could not remove tag category `"$TagCatalog`": $($_.Exception.Message). Category may need to be removed manually."
    }
}
Function Invoke-PauseBeforeRollbackIfRequested {

    <#
        .SYNOPSIS
        Determines whether to proceed with rollback or skip (continue to next site) based on -RollbackOnFailure and optional user prompt.

        .DESCRIPTION
        When -RollbackOnFailure was $true (always rollback), returns "ProceedWithRollback". When $false (never rollback), returns "DoNotRollback".
        When -RollbackOnFailure was omitted (prompt mode), prompts "Do you want to rollback? (Y=yes / N=no, leave broken and continue to next site / A=always rollback for all remaining sites)". When -SingleSite is set, the A option is omitted (no next site). Y and A return "ProceedWithRollback" (A also sets RollbackAlwaysFromPrompt); N or an empty response (Enter) returns "DoNotRollback". When $Script:CleanUpOnly is $true, returns "ProceedWithRollback" without prompting. Call at the start of any rollback workflow; callers must throw when return is "DoNotRollback" so the main loop can continue to the next site.

        .PARAMETER MaxPromptRetries
        Maximum number of Read-Host prompts before skipping rollback to prevent runaway. Default is 5.

        .PARAMETER RollbackContext
        Short description of the rollback (e.g. "vSAN deployment (cluster \"cl0-site1\")") for the log message.

        .PARAMETER ForcePrompt
        When set, always show the Y/N prompt for this rollback (ignore -RollbackOnFailure $true). Use for ArgoCD-only rollback so the user can choose to leave the namespace in place.

        .PARAMETER SingleSite
        When set, only Y/N is offered (no A=always), since there is no next site. Use when deploying to a single edge site only.

        .OUTPUTS
        "ProceedWithRollback" or "DoNotRollback".

        .NOTES
        Uses Read-Host for Y/N/A in prompt mode. One invalid response skips rollback (DoNotRollback) to avoid log flood in non-interactive runs. MaxPromptRetries prevents runaway if Read-Host returns immediately. Use -RollbackOnFailure $true to rollback without prompt.

        Answering N (or -RollbackOnFailure $false) is intended for extended manual debugging while the site stays in its failed state. When you are done debugging, run the appropriate scoped cleanup (for example -CleanUp ArgoCD, -CleanUp Harbor, -CleanUp Supervisor, -CleanUp Compute, or -CleanUp All with -EdgeSite as needed) before the next full deployment so the retry starts from a consistent baseline.
    #>

    [CmdletBinding()]
    [OutputType([System.String])]
    Param (
        [Parameter(Mandatory = $false)] [Switch]$ForcePrompt,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 20)] [Int]$MaxPromptRetries = 5,
        [Parameter(Mandatory = $false)] [String]$RollbackContext = "rollback",
        [Parameter(Mandatory = $false)] [Switch]$SingleSite
    )

    if ($Script:CleanUpOnly -and -not $ForcePrompt.IsPresent) {
        Write-LogMessage -Type DEBUG -Message "Invoke-PauseBeforeRollbackIfRequested: proceeding with rollback without prompt (cleanup mode)."
        return "ProceedWithRollback"
    }
    if (-not $ForcePrompt.IsPresent -and $null -ne $Script:RollbackOnFailurePreference -and $Script:RollbackOnFailurePreference -eq $true) {
        Write-LogMessage -Type INFO -Message "Proceeding with rollback without prompt (RollbackOnFailure=true). $RollbackContext"
        return "ProceedWithRollback"
    }
    if ($null -ne $Script:RollbackOnFailurePreference -and $Script:RollbackOnFailurePreference -eq $false) {
        Write-LogMessage -Type INFO -Message "Rollback skipped (RollbackOnFailure=false). Leaving site in current state; continuing to next site if any ($RollbackContext)."
        return "DoNotRollback"
    }
    if ($Script:RollbackAlwaysFromPrompt) {
        Write-LogMessage -Type DEBUG -Message "Invoke-PauseBeforeRollbackIfRequested: proceeding with rollback (user previously chose Always)."
        return "ProceedWithRollback"
    }
    $singleSitePrompt = $SingleSite.IsPresent
    if ($singleSitePrompt) {
        Write-LogMessage -Type INFO -Message "Rollback decision required. Do you want to rollback? (Y=yes / N=no, leave broken; press Enter for no)"
        $prompt = "Rollback? (Y/N, Enter=no)"
    } else {
        Write-LogMessage -Type INFO -Message "Rollback decision required. Do you want to rollback? (Y=yes / N=no, leave broken and continue to next site / A=always rollback for all remaining sites; press Enter for no)"
        $prompt = "Rollback? (Y/N/A, Enter=no)"
    }
    $loopCount = 0
    try {
        while ($true) {
            $loopCount++
            if ($loopCount -gt $MaxPromptRetries) {
                Write-LogMessage -Type WARNING -Message "Rollback prompt iteration limit ($MaxPromptRetries) reached; skipping rollback to prevent runaway. Use -RollbackOnFailure `$true to rollback without prompt."
                return "DoNotRollback"
            }
            $response = Read-Host $prompt
            $response = if ($response) { $response.Trim() } else { "" }
            if ([string]::IsNullOrWhiteSpace($response)) {
                Write-LogMessage -Type INFO -Message "No input (default no rollback); leaving site in broken state, continuing to next site if any ($RollbackContext)."
                return "DoNotRollback"
            }
            if ($response -match '^Y(es)?$') {
                Write-LogMessage -Type INFO -Message "User chose to rollback ($RollbackContext)."
                return "ProceedWithRollback"
            }
            if (-not $singleSitePrompt -and $response -match '^A(lways)?$') {
                $Script:RollbackAlwaysFromPrompt = $true
                Write-LogMessage -Type INFO -Message "User chose Always: rollback for this and all remaining sites ($RollbackContext)."
                return "ProceedWithRollback"
            }
            if ($response -match '^N(o)?$') {
                Write-LogMessage -Type INFO -Message "User chose not to rollback; leaving site in broken state, continuing to next site if any ($RollbackContext)."
                return "DoNotRollback"
            }
            $validOptions = if ($singleSitePrompt) { "Y or N" } else { "Y, N, or A" }
            Write-LogMessage -Type WARNING -Message "Invalid response `"$response`". Please enter $validOptions."
        }
    } catch {
        Write-LogMessage -Type WARNING -Message "Read-Host failed (non-interactive?): $($_.Exception.Message). Skipping rollback; pass -RollbackOnFailure `$true to rollback without prompt."
        return "DoNotRollback"
    }
}

#Remove-VsanDiskClaimsFromHost helpers
Function Get-CanonicalNameFromVsanStoragePoolDisk {
    <#
        .SYNOPSIS
        Returns the disk canonical name from a VsanStoragePoolDisk object for use with Get-VsanStoragePoolDisk -DiskCanonicalName.
        .DESCRIPTION
        Checks CanonicalName, Disk.CanonicalName, ExtensionData.disk.canonicalName, and any property whose name contains Canonical.
        .OUTPUTS
        String or $null.
    #>
    [CmdletBinding()]
    Param ([Parameter(Mandatory = $true)] $VsanStoragePoolDisk)
    $disk = $VsanStoragePoolDisk
    if ($disk.PSObject.Properties['CanonicalName'] -and -not [string]::IsNullOrWhiteSpace([string]$disk.CanonicalName)) {
        return $disk.CanonicalName
    }
    if ($disk.PSObject.Properties['Disk'] -and $null -ne $disk.Disk -and $disk.Disk.PSObject.Properties['CanonicalName'] -and -not [string]::IsNullOrWhiteSpace([string]$disk.Disk.CanonicalName)) {
        return $disk.Disk.CanonicalName
    }
    $extensionData = $disk.ExtensionData
    if ($null -ne $extensionData) {
        if ($extensionData.PSObject.Properties['disk'] -and $null -ne $extensionData.disk -and $extensionData.disk.PSObject.Properties['canonicalName'] -and -not [string]::IsNullOrWhiteSpace([string]$extensionData.disk.canonicalName)) {
            return $extensionData.disk.canonicalName
        }
        if ($extensionData.PSObject.Properties['Disk'] -and $null -ne $extensionData.Disk -and $extensionData.Disk.PSObject.Properties['CanonicalName'] -and -not [string]::IsNullOrWhiteSpace([string]$extensionData.Disk.CanonicalName)) {
            return $extensionData.Disk.CanonicalName
        }
    }
    foreach ($property in $disk.PSObject.Properties) {
        if ($property.Name -match 'canonical|Canonical' -and $null -ne $property.Value -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            return $property.Value
        }
    }
    return $null
}
Function Invoke-EsxcliVsanStoragePoolRemoveFallback {
    <#
        .SYNOPSIS
        Attempts to remove vSAN ESA storage pool disks via esxcli when PowerCLI could not remove them.
        .DESCRIPTION
        Runs esxcli vsan storagepool list, then remove for each disk (by disk name or UUID). Used when Get-VsanStoragePoolDisk returns objects with null Key.
        .OUTPUTS
        PSCustomObject with RemainingCount and RemovedCount, or $null on failure.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] $VMHost,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Server,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$HostNameForLogging
    )
    $diskNamePropertyNames = @('Disk', 'disk', 'DiskName', 'diskName', 'CanonicalName', 'canonicalName', 'Device', 'device')
    $uuidPropertyNames = @('UUID', 'Uuid', 'uuid', 'vsanUuid', 'VsanUuid', 'diskUuid')
    try {
        $esxcli = Get-EsxCli -VMHost $VMHost -V2 -Server $Server -ErrorAction Stop
        if (-not $esxcli.vsan.PSObject.Properties['storagepool']) { return $null }
        $listResult = $esxcli.vsan.storagepool.list.Invoke()
        $listItems = @()
        if ($null -ne $listResult) {
            $asArray = @($listResult)
            if ($asArray.Count -eq 1 -and $asArray[0].PSObject.Properties['disks']) { $listItems = @($asArray[0].disks) }
            elseif ($asArray.Count -eq 1 -and $asArray[0].PSObject.Properties['Disks']) { $listItems = @($asArray[0].Disks) }
            else { $listItems = $asArray }
        }
        $removeCmd = $esxcli.vsan.storagepool.remove
        $removedCount = 0
        foreach ($listItem in $listItems) {
            if ($null -eq $listItem) { continue }
            $diskIdentifier = $null
            $useUuidParam = $false
            foreach ($propertyName in $diskNamePropertyNames) {
                if ($listItem.PSObject.Properties[$propertyName] -and -not [string]::IsNullOrWhiteSpace([string]$listItem.$propertyName)) {
                    $diskIdentifier = $listItem.$propertyName
                    break
                }
            }
            if (-not $diskIdentifier) {
                foreach ($propertyName in $uuidPropertyNames) {
                    if ($listItem.PSObject.Properties[$propertyName] -and -not [string]::IsNullOrWhiteSpace([string]$listItem.$propertyName)) {
                        $diskIdentifier = $listItem.$propertyName
                        $useUuidParam = $true
                        break
                    }
                }
            }
            if ([string]::IsNullOrWhiteSpace([string]$diskIdentifier)) { continue }
            $removeParamName = $null
            $createArgs = $removeCmd.CreateArgs()
            if ($createArgs) {
                foreach ($param in $createArgs.PSObject.Properties) {
                    if ([string]::IsNullOrWhiteSpace([string]$param.Name)) { continue }
                    if ($useUuidParam -and $param.Name -match '^uuid$|^u$') { $removeParamName = $param.Name; break }
                    if (-not $useUuidParam -and $param.Name -match '^disk$|^d$') { $removeParamName = $param.Name; break }
                }
                if (-not $removeParamName -and $useUuidParam) {
                    foreach ($param in $createArgs.PSObject.Properties) { if ($param.Name -match '^uuid$|^u$') { $removeParamName = $param.Name; break } }
                }
                if (-not $removeParamName) {
                    foreach ($param in $createArgs.PSObject.Properties) { if ($param.Name -match '^disk$|^d$') { $removeParamName = $param.Name; break } }
                }
            }
            $invokeArgs = if ($removeParamName) { @{ $removeParamName = $diskIdentifier } } else { @{ disk = $diskIdentifier } }
            try {
                $null = $removeCmd.Invoke($invokeArgs)
                $removedCount++
                Write-LogMessage -Type DEBUG -Message "Removed vSAN ESA storage pool disk via esxcli on host `"$HostNameForLogging`" (identifier: $diskIdentifier)."
            } catch {
                Write-LogMessage -Type DEBUG -Message "esxcli vsan storagepool remove failed on host `"$HostNameForLogging`" for $diskIdentifier : $($_.Exception.Message)."
            }
        }
        $remainingDisks = Get-VsanStoragePoolDisk -VMHost $VMHost -Server $Server -ErrorAction SilentlyContinue
        $remainingCount = if ($remainingDisks) { @($remainingDisks).Count } else { 0 }
        return [PSCustomObject]@{ RemainingCount = $remainingCount; RemovedCount = $removedCount }
    } catch {
        Write-LogMessage -Type DEBUG -Message "esxcli vsan storagepool fallback failed on host `"$HostNameForLogging`": $($_.Exception.Message)."
        return $null
    }
}
Function Remove-VsanDiskClaimsFromHost {
    <#
        .SYNOPSIS
        Removes vSAN disk pools and their claimed disks (ESA storage pool or OSA disk groups) from a single host. Best-effort; logs warnings.

        .DESCRIPTION
        Used by Invoke-VsanDeploymentRollback for cluster hosts, orphaned config hosts, and witness. For ESA removes the storage pool and its claimed disks; for OSA removes disk groups and their claimed disks.

        .PARAMETER DiskRemovalRoundDelaySeconds
        Seconds to wait between rounds of querying and removing storage pool disks (ESA). Allows vCenter to update after each removal round. Default is 2.

        .PARAMETER RemoveRetryDelaySeconds
        Seconds to wait before retrying Remove-VsanStoragePoolDisk when a retryable vSAN error occurs (ESA). Default is 15.

        .PARAMETER Server
        vCenter server name. Default is $Script:vCenterName.

        .PARAMETER StoragePolicyType
        vSAN-ESA or vSAN-OSA.

        .PARAMETER VMHost
        The VMHost from which to remove disk pools and their claimed disks.

        .NOTES
        Caller must run disk removal before vsan cluster leave (Broadcom KB 326861). Removing the disk from the storage pool (Remove-VsanStoragePoolDisk) is what unclaims it (KB 394820).         ESA and OSA: removal uses no-data-migration mode. ESA: re-queries each round (up to 5). CanonicalName from disk, ExtensionData.disk, or property name containing Canonical. When PowerCLI cannot remove (null Key, no CanonicalName), esxcli vsan storagepool list/remove fallback. DEBUG logs disk property names when skipping; verifies unclaim (0 = all unclaimed).
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(0, 60)] [Int]$DiskRemovalRoundDelaySeconds = 2,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 120)] [Int]$RemoveRetryDelaySeconds = 15,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$Server = $Script:vCenterName,
        [Parameter(Mandatory = $true)] [ValidateSet("vSAN-ESA", "vSAN-OSA")] [String]$StoragePolicyType,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] $VMHost
    )
    $hostName = $VMHost.Name
    if ($StoragePolicyType -eq "vSAN-ESA") {
        try {
            $poolDisksBefore = Get-VsanStoragePoolDisk -VMHost $VMHost -Server $Server -ErrorAction SilentlyContinue
            $poolCountBefore = if ($poolDisksBefore) { @($poolDisksBefore).Count } else { 0 }
            Write-LogMessage -Type DEBUG -Message "vSAN ESA unclaim: host `"$hostName`" has $poolCountBefore storage pool disk(s) before removal (unclaim = remove from pool per Broadcom)."
            $maxRounds = 5
            $maxRemoveAttempts = 2
            $totalRemoved = 0
            for ($round = 1; $round -le $maxRounds; $round++) {
                $poolDisks = Get-VsanStoragePoolDisk -VMHost $VMHost -Server $Server -ErrorAction SilentlyContinue
                $poolDisksArray = @($poolDisks)
                if (-not $poolDisksArray -or $poolDisksArray.Count -eq 0) {
                    if ($round -eq 1) { return }
                    break
                }
                $validDisks = @($poolDisksArray | Where-Object { $null -ne $_ })
                if ($validDisks.Count -eq 0) {
                    if ($round -eq 1) {
                        Write-LogMessage -Type DEBUG -Message "No vSAN ESA storage pool disk objects to remove on host `"$hostName`". Skipping."
                        return
                    }
                    break
                }
                if ($round -eq 1) {
                    Write-LogMessage -Type DEBUG -Message "Removing vSAN ESA storage pool disk(s) from host `"$hostName`" (re-query each round until empty)."
                }
                $removedThisRound = 0
                foreach ($disk in $validDisks) {
                    $diskId = $null
                    if ($disk.PSObject.Properties['Id']) { $diskId = $disk.PSObject.Properties['Id'].Value }
                    if ($null -eq $diskId -or [string]::IsNullOrWhiteSpace([string]$diskId)) {
                        Write-LogMessage -Type DEBUG -Message "Skipping vSAN ESA storage pool disk with null or missing Id on host `"$hostName`" (avoids Remove-VsanStoragePoolDisk 'key' error)."
                        continue
                    }
                    $diskKey = $null
                    if ($disk.PSObject.Properties['Key']) { $diskKey = $disk.PSObject.Properties['Key'].Value }
                    $keyIsNull = ($null -eq $diskKey -or [string]::IsNullOrWhiteSpace([string]$diskKey))
                    if ($keyIsNull) {
                        $removedViaNullKeyAttempt = $false
                        try {
                            $null = Remove-VsanStoragePoolDisk -VsanStoragePoolDisk $disk -VsanDataMigrationMode NoDataMigration -Confirm:$false -ErrorAction Stop
                            $removedThisRound++
                            $totalRemoved++
                            $removedViaNullKeyAttempt = $true
                            Write-LogMessage -Type DEBUG -Message "Removed vSAN ESA storage pool disk (object with null Key accepted) from host `"$hostName`"."
                        } catch {
                            $errorMessage = $_.Exception.Message
                            $isKeyError = ($errorMessage -match "Parameter 'key'|Value cannot be null.*key")
                            if ($isKeyError) {
                                $canonicalName = Get-CanonicalNameFromVsanStoragePoolDisk -VsanStoragePoolDisk $disk
                                if ($canonicalName) {
                                    $refetchedDisks = @(Get-VsanStoragePoolDisk -VMHost $VMHost -DiskCanonicalName $canonicalName -Server $Server -ErrorAction SilentlyContinue | Where-Object { $null -ne $_ })
                                    foreach ($refetchedDisk in $refetchedDisks) {
                                        $refetchedKey = $null
                                        if ($refetchedDisk.PSObject.Properties['Key']) { $refetchedKey = $refetchedDisk.PSObject.Properties['Key'].Value }
                                        if ($null -ne $refetchedKey -and -not [string]::IsNullOrWhiteSpace([string]$refetchedKey)) {
                                            try {
                                                $null = Remove-VsanStoragePoolDisk -VsanStoragePoolDisk $refetchedDisk -VsanDataMigrationMode NoDataMigration -Confirm:$false -ErrorAction Stop
                                                Write-LogMessage -Type DEBUG -Message "Removed vSAN ESA storage pool disk (re-queried by canonical name) from host `"$hostName`"."
                                                $removedThisRound++
                                                $totalRemoved++
                                                $removedViaNullKeyAttempt = $true
                                            } catch {
                                                Write-LogMessage -Type DEBUG -Message "Remove-VsanStoragePoolDisk after re-query by canonical name failed: $($_.Exception.Message)."
                                            }
                                            break
                                        }
                                    }
                                }
                                if (-not $removedViaNullKeyAttempt) {
                                    $diskPropertyNames = @($disk.PSObject.Properties | Where-Object { $_.Name } | Select-Object -ExpandProperty Name)
                                    Write-LogMessage -Type DEBUG -Message "Skipping vSAN ESA storage pool disk with null Key and no CanonicalName on host `"$hostName`". Disk object properties: $($diskPropertyNames -join ', '). Remove manually in vCenter if needed."
                                }
                            } else {
                                Write-LogMessage -Type WARNING -Message "Remove-VsanStoragePoolDisk failed for disk with null Key on host `"$hostName`": $errorMessage"
                            }
                        }
                        continue
                    }
                    for ($attempt = 1; $attempt -le $maxRemoveAttempts; $attempt++) {
                        try {
                            $null = Remove-VsanStoragePoolDisk -VsanStoragePoolDisk $disk -VsanDataMigrationMode NoDataMigration -Confirm:$false -ErrorAction Stop
                            Write-LogMessage -Type DEBUG -Message "Removed one vSAN ESA storage pool disk from host `"$hostName`"."
                            $removedThisRound++
                            $totalRemoved++
                            break
                        } catch {
                            $errorMessage = $_.Exception.Message
                            $isKeyNullError = ($errorMessage -match "Parameter 'key'|Value cannot be null.*key")
                            if ($isKeyNullError) {
                                Write-LogMessage -Type WARNING -Message "Skipping vSAN ESA storage pool disk on host `"$hostName`" (cmdlet reported null key). Remove manually in vCenter if needed."
                                break
                            }
                            $isRetryableVsanError = ($errorMessage -match "Failed to delete storage pool disk|General vSAN error")
                            if ($attempt -lt $maxRemoveAttempts -and $isRetryableVsanError) {
                                Write-LogMessage -Type DEBUG -Message "Remove-VsanStoragePoolDisk failed (attempt $attempt of $maxRemoveAttempts); retrying in $RemoveRetryDelaySeconds seconds. Error: $errorMessage"
                                Start-Sleep -Seconds $RemoveRetryDelaySeconds
                            } else {
                                Write-LogMessage -Type WARNING -Message "Failed to remove one vSAN ESA storage pool disk from host `"$hostName`": $errorMessage"
                                if ($isRetryableVsanError) {
                                    Write-LogMessage -Type WARNING -Message "If the cluster is still in use or rebalancing, remove the disk manually via vCenter (put host in maintenance mode first if needed) or retry rollback when vSAN is idle."
                                }
                                break
                            }
                        }
                    }
                }
                if ($removedThisRound -eq 0) { break }
                Start-Sleep -Seconds $DiskRemovalRoundDelaySeconds
            }
            $remainingDisks = Get-VsanStoragePoolDisk -VMHost $VMHost -Server $Server -ErrorAction SilentlyContinue
            $stillCount = if ($remainingDisks) { @($remainingDisks).Count } else { 0 }
            Write-LogMessage -Type DEBUG -Message "vSAN ESA unclaim verification: host `"$hostName`" Get-VsanStoragePoolDisk returns $stillCount disk(s) after removal (0 = all disks unclaimed)."
            if ($stillCount -gt 0) {
                $fallbackResult = Invoke-EsxcliVsanStoragePoolRemoveFallback -VMHost $VMHost -Server $Server -HostNameForLogging $hostName
                if ($null -ne $fallbackResult) {
                    $stillCount = $fallbackResult.RemainingCount
                    $totalRemoved += $fallbackResult.RemovedCount
                }
                if ($stillCount -gt 0) {
                    Write-LogMessage -Type WARNING -Message "PowerCLI left $stillCount vSAN ESA storage pool disk(s) on host `"$hostName`". Remove manually in vCenter (Storage > select cluster > host > Configure > vSAN > Storage > remove disk) or retry rollback."
                }
            } else {
                Write-LogMessage -Type DEBUG -Message "vSAN ESA unclaim verified: host `"$hostName`" has no storage pool disks; all disks are unclaimed."
            }
            Write-LogMessage -Type DEBUG -Message "Completed vSAN ESA storage pool disk removal from host `"$hostName`" ($totalRemoved disk(s) removed; $stillCount remaining)."
        } catch {
            Write-LogMessage -Type WARNING -Message "Failed to remove vSAN ESA storage pool disks from host `"$hostName`": $($_.Exception.Message)"
        }
    }
    elseif ($StoragePolicyType -eq "vSAN-OSA") {
        try {
            $diskGroups = Get-VsanDiskGroup -VMHost $VMHost -Server $Server -ErrorAction SilentlyContinue
            if (-not $diskGroups -or (@($diskGroups).Count -eq 0)) { return }
            $diskGroupCount = @($diskGroups).Count
            Write-LogMessage -Type DEBUG -Message "Removing $diskGroupCount vSAN OSA disk group(s) from host `"$hostName`"."
            $removeFailCount = 0
            foreach ($diskGroup in @($diskGroups)) {
                try {
                    Write-LogMessage -Type DEBUG -Message "Removing vSAN OSA disk group from host `"$hostName`"."
                    Remove-VsanDiskGroup -VsanDiskGroup $diskGroup -DataMigrationMode NoDataMigration -Confirm:$false -ErrorAction Stop
                    Write-LogMessage -Type DEBUG -Message "Removed vSAN OSA disk group from host `"$hostName`"."
                } catch {
                    $removeFailCount++
                    Write-LogMessage -Type WARNING -Message "Failed to remove vSAN OSA disk group on host `"$hostName`": $($_.Exception.Message)"
                }
            }
            if ($removeFailCount -eq 0) {
                Write-LogMessage -Type DEBUG -Message "Completed vSAN OSA disk group removal from host `"$hostName`" ($diskGroupCount group(s))."
            } else {
                Write-LogMessage -Type INFO -Message "Attempted vSAN OSA disk group removal from host `"$hostName`"; $removeFailCount of $diskGroupCount removal(s) failed (see warnings above)."
                Write-LogMessage -Type DEBUG -Message "($($diskGroupCount - $removeFailCount) of $diskGroupCount group(s) removed; $removeFailCount failed."
            }

        } catch {
            Write-LogMessage -Type WARNING -Message "Failed to get or remove vSAN OSA disk groups on host `"$hostName`": $($_.Exception.Message)"
        }
    }
}
Function Remove-VmfsDatastoreForCluster {

    <#
        .SYNOPSIS
        Removes a VMFS datastore by name from vCenter. Used during VMFS deployment cleanup (-CleanUp Compute or All) as the final step before cluster removal.

        .DESCRIPTION
        Looks up the datastore by name on the connected vCenter server. If found, removes the datastore (unmounts and deletes).
        If the datastore does not exist, logs at DEBUG and returns. Failures during removal are logged as warnings and not rethrown.
        Call this after supervisor deactivation and VDS removal when cleaning up a VMFS-based edge cluster.

        .PARAMETER ClusterName
        Name of the cluster (for logging context). Not used for datastore lookup.

        .PARAMETER DatastoreName
        Name of the VMFS datastore to remove (e.g. from Get-DatastoreNameFromPrefix).

        .PARAMETER Server
        vCenter server name or connection. Defaults to $Script:vCenterName when not specified.

        .EXAMPLE
        Remove-VmfsDatastoreForCluster -ClusterName "cl0-site1" -DatastoreName "datastore-site1"

        .NOTES
        Requires an active vCenter connection. Uses Get-Datastore, Get-View (datastore host mount) and Get-VMHost -Id to obtain a host for Remove-Datastore -VMHost, avoiding deprecated VMHost.DatastoreIdList. Best-effort; logs warnings on failure.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DatastoreName,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$Server
    )

    $vcenter = if ($Server) { $Server } else { $Script:vCenterName }
    if (-not $vcenter) {
        Write-LogMessage -Type WARNING -Message "Remove-VmfsDatastoreForCluster: vCenter name not available; skipping VMFS datastore removal for cluster `"$ClusterName`"."
        return
    }

    $connectionTest = Test-VcenterConnection
    if (-not $connectionTest.IsConnected) {
        Write-LogMessage -Type WARNING -Message "Not connected to vCenter; skipping VMFS datastore removal for cluster `"$ClusterName`"."
        return
    }

    $datastore = Get-Datastore -Name $DatastoreName -Server $vcenter -ErrorAction SilentlyContinue
    if (-not $datastore) {
        Write-LogMessage -Type DEBUG -Message "VMFS datastore `"$DatastoreName`" not found on vCenter; nothing to remove for cluster `"$ClusterName`"."
        return
    }

    # Get a host that has this datastore mounted via Get-View (avoids Get-VMHost -Datastore which uses deprecated VMHost.DatastoreIdList).
    $dsView = Get-View -Id $datastore.Id -Property host -Server $vcenter -ErrorAction SilentlyContinue
    $vmhost = $null
    if ($dsView -and $dsView.Host -and $dsView.Host.Count -gt 0) {
        $hostKey = $dsView.Host[0].Key
        $vmhost = Get-VMHost -Id $hostKey -Server $vcenter -ErrorAction SilentlyContinue
    }
    if (-not $vmhost) {
        Write-LogMessage -Type WARNING -Message "No VMHost found with datastore `"$DatastoreName`"; cannot remove. Unmount/remove the datastore manually in vCenter if desired."
        return
    }

    try {
        Write-LogMessage -Type INFO -NoNewline -Message "Removing VMFS datastore `"$DatastoreName`" for cluster `"$ClusterName`"... "
        Remove-Datastore -Datastore $datastore -VMHost $vmhost -Confirm:$false -WarningAction SilentlyContinue -ErrorAction Stop
        Write-LogMessage -Type INFO -CompletePending -Message "Success"
    } catch {
        Write-LogMessage -Type WARNING -CompletePending -Message " Failed."
        Write-LogMessage -Type WARNING -Message "Could not remove VMFS datastore `"$DatastoreName`" for cluster `"$ClusterName`": $($_.Exception.Message). Remove the datastore manually in vCenter if desired."
    }
}

#Invoke-VsanDeploymentRollback helpers
Function Invoke-VsanClusterLeaveOnHostWithRetry {

    <#
        .SYNOPSIS
        Runs esxcli vsan cluster leave on a single host with retries. Used by Invoke-VsanDeploymentRollback.
        .OUTPUTS
        $true if leave succeeded or host was not in a vSAN cluster; $false if leave failed after retries or command not available.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] $VMHost,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Server,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 10)] [Int]$MaxRetries = 3,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 120)] [Int]$RetryDelaySeconds = 15,
        [Parameter(Mandatory = $false)] [String]$LogContext = ""
    )
    $hostNameForLogging = $VMHost.Name
    $contextSuffix = if ([string]::IsNullOrWhiteSpace($LogContext)) { "" } else { " ($LogContext)" }
    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            $esxcli = Get-EsxCli -VMHost $VMHost -V2 -Server $Server -ErrorAction Stop
            if (-not $esxcli.vsan.cluster.leave) {
                Write-LogMessage -Type WARNING -Message "esxcli vsan cluster leave not available on host `"$hostNameForLogging`"; host may already have left or vSAN not enabled."
                return $false
            }
            Write-LogMessage -Type DEBUG -Message "Invoking esxcli vsan cluster leave on host `"$hostNameForLogging`" (attempt $attempt/$MaxRetries)$contextSuffix."
            $null = $esxcli.vsan.cluster.leave.Invoke()
            Write-LogMessage -Type DEBUG -Message "Host `"$hostNameForLogging`" left vSAN cluster."
            return $true
        } catch {
            $errorMessage = $_.Exception.Message
            if ($errorMessage -match "not in a vSAN|not in a vSAN or client cluster") {
                Write-LogMessage -Type INFO -Message "Host `"$hostNameForLogging`" is not in a vSAN cluster (already left or never joined); skipping vsan cluster leave."
                return $true
            }
            if ($attempt -lt $MaxRetries -and $errorMessage -match "retried|retry") {
                Write-LogMessage -Type INFO -Message "vsan cluster leave on host `"$hostNameForLogging`" failed (attempt $attempt/$MaxRetries); retrying in $RetryDelaySeconds seconds: $errorMessage"
                Start-Sleep -Seconds $RetryDelaySeconds
            } else {
                Write-LogMessage -Type WARNING -Message "Could not run vsan cluster leave on host `"$hostNameForLogging`": $errorMessage. Host may need to leave vSAN manually."
                return $false
            }
        }
    }
    return $false
}
Function Invoke-VsanDeploymentRollback {
    <#
        .SYNOPSIS
        Best-effort rollback when vSAN (ESA or OSA) deployment fails: removes disk pools and their claimed disks, then attempts to disable vSAN on the cluster.

        .DESCRIPTION
        Call this when Add-VsanEsaStoragePoolDisk or Add-VsanOsaDiskGroupToCluster fails, or during -CleanUp Compute/All.
        Cleanup order (same for ESA and OSA per Broadcom KB 326861): (1) Remove disks from disk groups (OSA) or storage pools (ESA) on each data host, (2) run esxcli vsan cluster leave on each data host, (3) tag and cluster removal. The witness is never modified.
        Rollback is best-effort: errors are logged and not rethrown; the original deployment failure remains the one thrown to the caller.
        The witness host is shared by multiple clusters; cleanup must never modify the witness storage pool or disk claims. Only data host storage is removed.

        .PARAMETER ClusterName
        The name of the cluster for which to perform rollback.

        .PARAMETER EsxHostNames
        Optional. Array of ESX host names (e.g. from config). When the cluster is not found, rollback will still remove orphaned vSAN disk pools and their claimed disks from these hosts and run vsan cluster leave. Used by -CleanUp to clean hosts that were intended for the cluster but the cluster no longer exists.

        .PARAMETER MaxVsanLeaveRetries
        Maximum number of attempts for esxcli vsan cluster leave per host. Default is 3.

        .PARAMETER StoragePolicyTagCatalog
        Optional. Tag category (catalog) containing the storage tag. Required for storage tag removal when StoragePolicyTagName is provided.

        .PARAMETER StoragePolicyTagName
        Optional. Name of the storage tag (e.g. supervisor name) to delete during rollback. When provided with StoragePolicyTagCatalog, Remove-StorageTag is called to clean up the tag.

        .PARAMETER SkipClusterRemoval
        Callers must pass -SkipClusterRemoval for full teardown. This function only performs disk/leave/tags; it never removes the VDS or cluster. The caller must remove VMkernel adapters, restore management to VSS, remove the VDS(es), then remove the cluster (same order as -CleanUp Compute).

        .PARAMETER StoragePolicyType
        vSAN type: vSAN-ESA (storage pool disks) or vSAN-OSA (disk groups).

        .PARAMETER SuppressPrompt
        When set, skips the Y/N/A rollback prompt (caller already prompted or uses -RollbackOnFailure). Used by the main deployment catch when it prompts once then runs the full rollback sequence.

        .PARAMETER VsanLeaveRetryDelaySeconds
        Seconds to wait between retry attempts for esxcli vsan cluster leave. Default is 15.

        .PARAMETER WitnessHostName
        Optional. Witness host name (FQDN or IP). The witness is shared by multiple clusters; cleanup never modifies the witness storage pool or disk claims. When provided, used only for logging; no changes are made to the witness.

        .EXAMPLE
        Invoke-VsanDeploymentRollback -ClusterName "cl0-site1" -StoragePolicyType "vSAN-OSA"

        .EXAMPLE
        Invoke-VsanDeploymentRollback -ClusterName "cl0-site1" -StoragePolicyType "vSAN-OSA" -StoragePolicyTagName "Supervisor01" -StoragePolicyTagCatalog "EdgeNodePolicy"

        .NOTES
        This function only performs vSAN teardown (disk/leave/tags). It never removes the VDS or cluster. Callers must use -SkipClusterRemoval and then run the same sequence as cleanup: Remove-NonVmk0VmkernelInterfacesFromVds, Invoke-ManagementRestoreForCleanup, Invoke-VsanDeploymentRollback (with -SkipClusterRemoval), Remove-EdgeClusterDistributedSwitch for each VDS, then Remove-ClusterSafely. Disk cleanup order follows Broadcom KB 326861: remove disks or disk groups first, then vsan cluster leave. (1) Remove disks from disk groups (OSA) or storage pools (ESA) on each cluster (data) host only; the witness is shared. (2) Run esxcli vsan cluster leave on each data host. (3) Remove storage tag and category if provided.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [String[]]$EsxHostNames,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 10)] [Int]$MaxVsanLeaveRetries = 3,
        [Parameter(Mandatory = $false)] [switch]$SkipClusterRemoval,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$StoragePolicyTagCatalog,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$StoragePolicyTagName,
        [Parameter(Mandatory = $true)] [ValidateSet("vSAN-ESA", "vSAN-OSA")] [String]$StoragePolicyType,
        [Parameter(Mandatory = $false)] [switch]$SuppressPrompt,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 120)] [Int]$VsanLeaveRetryDelaySeconds = 15,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$WitnessHostName
    )

    if (-not $SuppressPrompt.IsPresent) {
        $rollbackDecision = Invoke-PauseBeforeRollbackIfRequested -RollbackContext "vSAN rollback (cluster `"$ClusterName`")"
        if ($rollbackDecision -eq "DoNotRollback") {
            throw [RollbackSkippedException]::new()
        }
    }

    $Script:RollbackAttempted = $true
    Write-LogMessage -Type INFO -Message "Starting vSAN deployment rollback for cluster `"$ClusterName`" ($StoragePolicyType)..."
    $connectionTest = Test-VcenterConnection
    if (-not $connectionTest.IsConnected) {
        Write-LogMessage -Type WARNING -Message "Not connected to vCenter; skipping vSAN rollback."
        return
    }

    try {
        $clusterObject = Get-Cluster -Name $ClusterName -Server $Script:vCenterName -ErrorAction SilentlyContinue
        $clusterHosts = $null
        $hasHosts = $false
        if ($clusterObject) {
            $clusterHosts = Get-VMHost -Location $clusterObject -Server $Script:vCenterName -ErrorAction SilentlyContinue
            $hasHosts = $clusterHosts -and $clusterHosts.Count -gt 0
        }

        if (-not $clusterObject) {
            #Orphaned cluster cleanup (cluster not found)
            $hostsToClean = [System.Collections.Generic.List[object]]::new()
            if ($EsxHostNames -and $EsxHostNames.Count -gt 0) {
                foreach ($hostNameInConfig in $EsxHostNames) {
                    $resolvedHost = Get-VMHost -Name $hostNameInConfig -Server $Script:vCenterName -ErrorAction SilentlyContinue
                    if ($resolvedHost) { $hostsToClean.Add($resolvedHost) } else { Write-LogMessage -Type DEBUG -Message "Orphaned host `"$hostNameInConfig`" not found in vCenter; skipping." }
                }
            }
            $isVsanOrphaned = ($StoragePolicyType -eq "vSAN-ESA" -or $StoragePolicyType -eq "vSAN-OSA") -and $hostsToClean.Count -gt 0
            if ($hostsToClean.Count -eq 0) {
                # No message here; caller will log "cluster not found; nothing to remove" when appropriate.
            }
            elseif ($isVsanOrphaned) {
                Write-LogMessage -Type WARNING -Message "Cluster `"$ClusterName`" not found; cleaning orphaned disk pools and their claimed disks from $($hostsToClean.Count) config host(s) (witness not modified)."
            }
            else {
                Write-LogMessage -Type WARNING -Message "Cluster `"$ClusterName`" not found; running cleanup on $($hostsToClean.Count) config host(s)."
            }
            # Per Broadcom KB 326861: remove disks (or disk groups) first, then vsan cluster leave. Same for ESA and OSA.
            if ($hostsToClean.Count -gt 0 -and $StoragePolicyType -eq "vSAN-ESA") {
                Write-LogMessage -Type INFO -Message "vSAN ESA orphaned cleanup: removing storage pool disks from $($hostsToClean.Count) host(s), then vSAN cluster leave."
            }
            if ($hostsToClean.Count -gt 0 -and $StoragePolicyType -eq "vSAN-OSA") {
                Write-LogMessage -Type INFO -Message "Removing vSAN disk claims from $($hostsToClean.Count) orphaned host(s) (OSA disk groups), then vSAN cluster leave."
            }
            if ($WitnessHostName -and $hostsToClean.Count -gt 0) {
                Write-LogMessage -Type DEBUG -Message "Witness host `"$WitnessHostName`" is shared by multiple clusters; cleanup never modifies witness storage pool or disk claims."
            }
            foreach ($vmHost in $hostsToClean) {
                Remove-VsanDiskClaimsFromHost -VMHost $vmHost -StoragePolicyType $StoragePolicyType -Server $Script:vCenterName
            }
            if ($hostsToClean.Count -gt 0 -and ($StoragePolicyType -eq "vSAN-OSA" -or $StoragePolicyType -eq "vSAN-ESA")) {
                Write-LogMessage -Type INFO -Message "vSAN disk removal completed for $($hostsToClean.Count) host(s)."
            }
            foreach ($vmHost in $hostsToClean) {
                $null = Invoke-VsanClusterLeaveOnHostWithRetry -VMHost $vmHost -Server $Script:vCenterName -MaxRetries $MaxVsanLeaveRetries -RetryDelaySeconds $VsanLeaveRetryDelaySeconds -LogContext "orphaned cleanup"
            }
            if ($StoragePolicyTagName -and $StoragePolicyTagCatalog) {
                Remove-StorageTag -TagName $StoragePolicyTagName -TagCatalog $StoragePolicyTagCatalog -Server $Script:vCenterName
                Remove-TagCategoryIfEmpty -TagCatalog $StoragePolicyTagCatalog -Server $Script:vCenterName
            }
            if ($hostsToClean.Count -gt 0) {
                Write-LogMessage -Type INFO -Message "vSAN deployment rollback completed for cluster `"$ClusterName`"."
            }
            return
        }

        #Data host disk removal and vsan leave
        if (-not $hasHosts) {
            Write-LogMessage -Type DEBUG -Message "No hosts in cluster `"$ClusterName`"; will try config hosts (EsxHostNames) for disk removal and vsan leave if provided, then tag cleanup and cluster removal."
        }

        if ($WitnessHostName) {
            Write-LogMessage -Type DEBUG -Message "Witness host `"$WitnessHostName`" is shared by multiple clusters; cleanup never modifies witness storage pool or disk claims."
        }

        $hostsForDiskRemoval = [System.Collections.Generic.List[object]]::new()
        if ($hasHosts) {
            foreach ($h in $clusterHosts) { $hostsForDiskRemoval.Add($h) }
        } elseif ($EsxHostNames -and $EsxHostNames.Count -gt 0) {
            foreach ($hostNameInConfig in $EsxHostNames) {
                $resolvedHost = Get-VMHost -Name $hostNameInConfig -Server $Script:vCenterName -ErrorAction SilentlyContinue
                if ($resolvedHost) { $hostsForDiskRemoval.Add($resolvedHost) } else { Write-LogMessage -Type DEBUG -Message "Config host `"$hostNameInConfig`" not found in vCenter; skipping disk removal for this host." }
            }
        }

        # Per Broadcom KB 326861: remove disks (or disk groups) first, then run vsan cluster leave. Same order for ESA and OSA.
        if ($hostsForDiskRemoval.Count -gt 0 -and $StoragePolicyType -eq "vSAN-OSA") {
            Write-LogMessage -Type INFO -Message "Removing vSAN disk claims from $($hostsForDiskRemoval.Count) host(s) (OSA disk groups), then vsan cluster leave."
        }
        if ($hostsForDiskRemoval.Count -gt 0 -and $StoragePolicyType -eq "vSAN-ESA") {
            Write-LogMessage -Type INFO -Message "Removing vSAN ESA storage pool disk claims from $($hostsForDiskRemoval.Count) host(s), then vsan cluster leave."
        }
        foreach ($vmHost in $hostsForDiskRemoval) {
            Remove-VsanDiskClaimsFromHost -VMHost $vmHost -StoragePolicyType $StoragePolicyType -Server $Script:vCenterName
        }
        if ($hostsForDiskRemoval.Count -gt 0 -and ($StoragePolicyType -eq "vSAN-OSA" -or $StoragePolicyType -eq "vSAN-ESA")) {
            Write-LogMessage -Type INFO -Message "vSAN disk removal completed for $($hostsForDiskRemoval.Count) host(s)."
        }
        if ($hostsForDiskRemoval.Count -gt 0) {
            foreach ($vmHost in $hostsForDiskRemoval) {
                $null = Invoke-VsanClusterLeaveOnHostWithRetry -VMHost $vmHost -Server $Script:vCenterName -MaxRetries $MaxVsanLeaveRetries -RetryDelaySeconds $VsanLeaveRetryDelaySeconds
            }
            Write-LogMessage -Type INFO -Message "vSAN cluster leave completed for cluster `"$ClusterName`"."
        }

        if ($StoragePolicyTagName -and $StoragePolicyTagCatalog) {
            Remove-StorageTag -TagName $StoragePolicyTagName -TagCatalog $StoragePolicyTagCatalog -Server $Script:vCenterName
            Remove-TagCategoryIfEmpty -TagCatalog $StoragePolicyTagCatalog -Server $Script:vCenterName
        }

        Write-LogMessage -Type INFO -Message "vSAN deployment rollback completed for cluster `"$ClusterName`"."
        if (-not $SkipClusterRemoval.IsPresent) {
            Write-LogMessage -Type WARNING -Message "vSAN rollback only performs disk/leave/tags. Caller must remove VDS then cluster (same order as cleanup: VMkernel removal, management restore, VDS removal, cluster removal). Use -CleanUp Compute or run the full teardown sequence; do not call Invoke-VsanDeploymentRollback without -SkipClusterRemoval for full teardown."
        }
    } catch {
        $Script:RollbackFailed = $true
        Write-LogMessage -Type ERROR -Message "vSAN rollback encountered an error: $($_.Exception.Message). Script will exit with failure."
        throw
    }
}

#endregion
