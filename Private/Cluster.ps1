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
function Enable-VsanEsaOnExistingCluster {

    <#
        .SYNOPSIS
        Ensures vSAN ESA is enabled on a cluster found to already exist by Add-Cluster.

        .DESCRIPTION
        vSAN 9.1 introduced a strict API precheck that reads vsanEsaEnabled directly from the vCenter
        database before allowing an ESA witness to join a stretched cluster. A cluster created by an
        older version of this script, created manually, or where New-Cluster -VsanEsaEnabled was
        silently ignored will have vsanEsaEnabled=false, causing witness configuration to fail with
        "This witness host does not support joining vSAN ESA disabled cluster."

        This function calls Set-Cluster -VsanEnabled $true -VsanEsaEnabled $true to set the flag.
        The call is idempotent when ESA is already enabled.

        Failure is treated as non-fatal (WARNING + continue) for two reasons:
          1. vCenter 9.0 does not have the strict witness precheck so even if this call is
             rejected by the API the witness join will still succeed.
          2. A transient API error here should not abort a deployment that may otherwise succeed.

        If this call fails and the environment is vCenter 9.1+, the witness join step will later
        emit a targeted actionable error via Set-VsanWitness, directing the operator to either
        re-run the deployment or recreate the cluster with storageType: vSAN-ESA.

        .PARAMETER Cluster
        The cluster object returned by Get-Cluster.

        .PARAMETER ClusterName
        The cluster name, used for logging.

        .OUTPUTS
        None. Non-fatal — logs WARNING on failure and returns; never throws.

        .EXAMPLE
        Enable-VsanEsaOnExistingCluster -Cluster $clusterObject -ClusterName "cluster-vsan-edge1"

        .NOTES
        Called exclusively from Add-Cluster when the cluster already exists and -VsanEsaEnabled is set.
        Safe to call on clusters that already have ESA enabled (idempotent via Set-Cluster).
        Non-fatal design preserves vCenter 9.0 compatibility.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] $Cluster,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName
    )

    Write-LogMessage -Type DEBUG -Message "Ensuring vSAN ESA is enabled on existing cluster `"$ClusterName`" (vSAN 9.1+ requires vsanEsaEnabled=true before ESA witness configuration)."
    try {
        Set-Cluster -Cluster $Cluster -VsanEnabled $true -VsanEsaEnabled $true `
            -Server $Script:vCenterName -Confirm:$false -ErrorAction Stop | Out-Null
        Write-LogMessage -Type DEBUG -Message "vSAN ESA confirmed/applied on existing cluster `"$ClusterName`"."
    } catch {
        # Non-fatal: vCenter 9.0 does not enforce the ESA precheck, so if this API call is
        # unsupported on the installed vCenter version the witness join will still succeed.
        # On vCenter 9.1+ the witness join step will surface a targeted actionable error if
        # the flag was genuinely required and this call failed.
        Write-LogMessage -Type WARNING -Message "Could not apply vSAN ESA flag to existing cluster `"$ClusterName`": $($_.Exception.Message). Continuing — if the witness join fails with an ESA-disabled error, delete this cluster and re-run with storageType: vSAN-ESA in infrastructure.json."
    }
}
function Add-Cluster {

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
        Add-Cluster -ClusterName $clusterName -DataCenterName $datacenterName

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
        [Parameter(Mandatory = $false)] [ValidateRange(0, [Int]::MaxValue)] [Int]$ClusterCreationDelaySeconds = 5,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DataCenterName,
        [Parameter(Mandatory = $false)] [AllowNull()] [String]$VlcmImageName,
        [Parameter(Mandatory = $false)] [Switch]$VsanEsaEnabled,
        [Parameter(Mandatory = $false)] [Switch]$VsanOsaEnabled
    )

    Write-LogMessage -Type DEBUG -Message "Entered Add-Cluster function..."
    $vlcmImageNameParamDisplay = if ([String]::IsNullOrWhiteSpace($VlcmImageName)) { "(none)" } else { "`"$VlcmImageName`"" }
    Write-LogMessage -Type DEBUG -Message "Add-Cluster parameters: ClusterName=`"$ClusterName`", DataCenterName=`"$DataCenterName`", VsanEsaEnabled=$($VsanEsaEnabled.IsPresent), VsanOsaEnabled=$($VsanOsaEnabled.IsPresent), VlcmImageName=$vlcmImageNameParamDisplay."

    Assert-VcenterConnected

    try {
        $dataCenterFound = Get-Datacenter -Name $DataCenterName -Server $Script:vCenterName -ErrorAction Ignore
    } catch [System.UnauthorizedAccessException] {
        $err = "Cannot perform Get-Datacenter operation for `"$DataCenterName`" due to authorization issues: $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
    catch [System.TimeoutException] {
        $err = "Cannot perform Get-Datacenter operation for `"$DataCenterName`" due to network/timeout issues: $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    } catch [VcfDeploymentException] {
        throw  # already logged and typed — propagate without re-wrapping
    } catch {
        $err = "Failed to perform Get-Datacenter operation on `"$DataCenterName`" : $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -AppendNewLine -Message $err
        throw [VcfDeploymentException]::new($err)
    }

    if (-not $dataCenterFound) {
        $err = "The datacenter `"$DataCenterName`" could not be found on vCenter `"$Script:vCenterName`". Exiting."
        Write-LogMessage -Type ERROR -AppendNewLine -Message $err
        throw [VcfDeploymentException]::new($err)
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
                $err = "Failed to retrieve software specification with ID `"$softwareSpecificationId`": $($_.Exception.Message)"
                Write-LogMessage -Type ERROR -Message $err
                throw [VcfDeploymentException]::new($err)
            }
            if ($null -eq $softwareSpecification) {
                $err = "Software specification with ID `"$softwareSpecificationId`" was not found."
                Write-LogMessage -Type ERROR -Message $err
                throw [VcfDeploymentException]::new($err)
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
            throw [VcfDeploymentException]::new("Cluster creation failed (authorization): insufficient permissions to create cluster `"$ClusterName`" on `"$Script:vCenterName`".")
        }
        catch [System.TimeoutException] {
            Write-LogMessage -Type ERROR -CompletePending -Message " Failed (timeout)."
            throw [VcfDeploymentException]::new("Cluster creation timed out for `"$ClusterName`" on `"$Script:vCenterName`".")
        } catch {
            Write-LogMessage -Type ERROR -CompletePending -Message " Failed."
            throw [VcfDeploymentException]::new("Cluster creation failed for `"$ClusterName`" on `"$Script:vCenterName`": $($_.Exception.Message)")
        }
    } else {
        Write-LogMessage -Type INFO -Message "The cluster `"$ClusterName`" in datacenter `"$DataCenterName`" is already present. Skipping cluster creation."
        if ($VsanEsaEnabled) {
            Enable-VsanEsaOnExistingCluster -Cluster $clusterFound -ClusterName $ClusterName
        }
        return
    }

    if ($clusterFound) {
        Write-LogMessage -Type INFO -CompletePending -Message " Success"
    } else {
        $err = "Cluster `"$ClusterName`" was not found in datacenter `"$DataCenterName`" on vCenter `"$Script:vCenterName`" after creation attempt."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
}
function Remove-ClusterSafely {

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

    Assert-VcenterConnected

    $clusterObject = Get-ClusterByName -Name $ClusterName -Server $Script:vCenterName
    if (-not $clusterObject) {
        Write-LogMessage -Type WARNING -Message "Cluster `"$ClusterName`" not found; nothing to remove."
        return
    }

    $vmsInCluster = Get-VM -Location $clusterObject -Server $Script:vCenterName -ErrorAction SilentlyContinue
    $runningVms = $null
    if ($vmsInCluster) {
        $runningVms = @($vmsInCluster | Where-Object { $_.PowerState -eq 'PoweredOn' })
    }
    $blockingVms = [System.Collections.Generic.List[PSObject]]::new()
    $vclsPhotonCrxGuestName = "VMware Photon CRX (64-bit)"
    if ($runningVms -and $runningVms.Count -gt 0) {
        foreach ($vm in @($runningVms)) {
            if ($vm.Name -notlike "vCLS-*") {
                $blockingVms.Add($vm)
                continue
            }
            $guestFullName = $null
            try {
                # The outer try-catch handles any property-access errors; no pre-flight guards needed.
                $guestFullName = $vm.ExtensionData.Guest.GuestFullName
                if (-not $guestFullName) {
                    $vmView = Get-View -Id $vm.Id -Server $Script:vCenterName -Property Guest -ErrorAction SilentlyContinue
                    $guestFullName = $vmView.Guest.GuestFullName
                }
            } catch {
                Write-LogMessage -Type DEBUG -Message "Could not read guest OS for VM `"$($vm.Name)`"; treating as blocking for cluster removal."
            }
            if ($guestFullName -eq $vclsPhotonCrxGuestName) {
                Write-LogMessage -Type DEBUG -Message "Excluding running VM `"$($vm.Name)`" (vCLS with guest $vclsPhotonCrxGuestName) from cluster-removal check."
                continue
            }
            $blockingVms.Add($vm)
        }
    }
    if ($blockingVms.Count -gt 0) {
        $blockingNames = $blockingVms | Select-Object -ExpandProperty Name
        $err = "Cannot remove cluster `"$ClusterName`": $($blockingVms.Count) running VM(s) found: $($blockingNames -join ', '). Power off or migrate VMs first."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }

    Write-LogMessage -Type INFO -NoNewline -Message "Removing cluster `"$ClusterName`" (no running VMs)... "
    if ($PSCmdlet.ShouldProcess("cluster `"$ClusterName`" on vCenter `"$Script:vCenterName`"", "Remove-Cluster")) {
        Remove-Cluster -Cluster $clusterObject -Server $Script:vCenterName -Confirm:$false -ErrorAction Stop
    }
    Write-LogMessage -Type INFO -CompletePending -Message "Removed"
}
function New-ClusterDasConfigSpec {

    <#
        .SYNOPSIS
        Builds a ClusterConfigSpecEx with HostMonitoring and VmMonitoring pre-set to the standard deployment values.

        .DESCRIPTION
        Constructs and returns a VMware.Vim.ClusterConfigSpecEx seeded from the current cluster DAS configuration,
        with HostMonitoring="enabled" and VmMonitoring="vmMonitoringOnly" already applied. Used by
        Set-MultiHostClusterHA to eliminate the identical 4-line setup block that would otherwise appear in all
        three switch branches.

        .PARAMETER ClusterView
        The cluster view object retrieved via Get-View.

        .OUTPUTS
        VMware.Vim.ClusterConfigSpecEx pre-configured for standard HA monitoring settings.

        .EXAMPLE
        $clusterView = Get-View -Id $cluster.Id -Server $Script:vCenterName
        $configSpec = New-ClusterDasConfigSpec -ClusterView $clusterView
        $configSpec.dasConfig.AdmissionControlEnabled = $false
        $clusterView.ReconfigureComputeResource_Task($configSpec, $true) | Out-Null
    #>

    [CmdletBinding()]
    [OutputType([VMware.Vim.ClusterConfigSpecEx])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$ClusterView
    )

    $configSpec = New-Object VMware.Vim.ClusterConfigSpecEx
    $configSpec.dasConfig = $ClusterView.ConfigurationEx.DasConfig
    $configSpec.dasConfig.HostMonitoring = "enabled"
    $configSpec.dasConfig.VmMonitoring = "vmMonitoringOnly"
    return $configSpec
}
function Set-MultiHostClusterHA {

    <#
    .SYNOPSIS
        Applies HA and DRS admission-control settings to a multi-host vSphere cluster.
    .DESCRIPTION
        Issues the appropriate Set-Cluster and/or ReconfigureComputeResource_Task calls for the
        three supported HA policies: slotBased, reservationBased, and disabled. Should only be
        called when the cluster has 2 or more hosts.
    .PARAMETER Cluster
        The cluster object returned by Get-Cluster.
    .PARAMETER ClusterName
        Name of the cluster, used in log messages.
    .PARAMETER HaClusterResourceFailoverPercent
        For reservationBased: explicit failover percentage (1–100). Pass 0 to auto-compute.
    .PARAMETER HaPolicy
        Admission control policy: slotBased, reservationBased, or disabled.
    .PARAMETER HostCount
        Number of hosts in the cluster, used to auto-compute the reservation percentage.
    .EXAMPLE
        Set-MultiHostClusterHA -Cluster $cluster -ClusterName "cl02" -HaClusterResourceFailoverPercent 0 -HaPolicy "slotBased" -HostCount 3
    .NOTES
        Uses $Script:vCenterName. Throws on any PowerCLI failure.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$Cluster,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateRange(0, 100)] [Int]$HaClusterResourceFailoverPercent,
        [Parameter(Mandatory = $true)] [ValidateSet("disabled", "reservationBased", "slotBased")] [String]$HaPolicy,
        [Parameter(Mandatory = $true)] [ValidateRange(2, [Int]::MaxValue)] [Int]$HostCount
    )

    switch ($HaPolicy) {
        "slotBased" {
            $haFailoverLevel = 1
            $Cluster | Set-Cluster -DrsEnabled:$true -HAEnabled:$true -DrsAutomationLevel FullyAutomated -HAAdmissionControlEnabled:$true -HAFailoverLevel $haFailoverLevel -Confirm:$false -Server $Script:vCenterName -ErrorAction Stop | Out-Null
            $clusterView = Get-View -Id $Cluster.Id -Server $Script:vCenterName
            $currentDas = $clusterView.ConfigurationEx.DasConfig
            $currentVmMonitoring = if ($null -ne $currentDas.VmMonitoring) { $currentDas.VmMonitoring } else { $currentDas.VMMonitoring }
            if (($currentDas.HostMonitoring -ne "enabled") -or ($currentVmMonitoring -ne "vmMonitoringOnly")) {
                $configSpec = New-ClusterDasConfigSpec -ClusterView $clusterView
                $clusterView.ReconfigureComputeResource_Task($configSpec, $true) | Out-Null
            }
            Write-LogMessage -Type DEBUG -Message "Cluster `"$ClusterName`" ($HostCount host(s)): HA admission control set to slot-based (host failures tolerated: $haFailoverLevel)."
        }
        "reservationBased" {
            $Cluster | Set-Cluster -DrsEnabled:$true -HAEnabled:$true -DrsAutomationLevel FullyAutomated -HAAdmissionControlEnabled:$false -Confirm:$false -Server $Script:vCenterName -ErrorAction Stop | Out-Null
            $clusterView = Get-View -Id $Cluster.Id -Server $Script:vCenterName
            $failoverResourcePercent = if ($HaClusterResourceFailoverPercent -eq 0) { [Int][Math]::Min(100, [Math]::Ceiling(100.0 / $HostCount)) } else { $HaClusterResourceFailoverPercent }
            $configSpec = New-ClusterDasConfigSpec -ClusterView $clusterView
            $configSpec.dasConfig.AdmissionControlEnabled = $true
            $resourcePctPolicy = New-Object VMware.Vim.ClusterFailoverResourcesAdmissionControlPolicy
            $resourcePctPolicy.CpuFailoverResourcesPercent = $failoverResourcePercent
            $resourcePctPolicy.MemoryFailoverResourcesPercent = $failoverResourcePercent
            $configSpec.dasConfig.AdmissionControlPolicy = $resourcePctPolicy
            $clusterView.ReconfigureComputeResource_Task($configSpec, $true) | Out-Null
            Write-LogMessage -Type DEBUG -Message "Cluster `"$ClusterName`" ($HostCount host(s)): HA admission control set to cluster resource percentage ($failoverResourcePercent% CPU and memory reserved for failover)."
        }
        "disabled" {
            $Cluster | Set-Cluster -DrsEnabled:$true -HAEnabled:$true -DrsAutomationLevel FullyAutomated -HAAdmissionControlEnabled:$false -Confirm:$false -Server $Script:vCenterName -ErrorAction Stop | Out-Null
            $clusterView = Get-View -Id $Cluster.Id -Server $Script:vCenterName
            $configSpec = New-ClusterDasConfigSpec -ClusterView $clusterView
            $configSpec.dasConfig.AdmissionControlEnabled = $false
            $clusterView.ReconfigureComputeResource_Task($configSpec, $true) | Out-Null
            Write-LogMessage -Type INFO -Message "Cluster `"$ClusterName`" ($HostCount host(s)): HA enabled with admission control disabled (VM restart only; no capacity reservation)."
        }
    }
}
function Update-Cluster {

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

    Assert-VcenterConnected

    try {
        $cluster = Get-Cluster -Name $ClusterName -Server $Script:vCenterName -ErrorAction Stop
        if (-not $cluster) {
            $err = "The cluster `"$ClusterName`" in vCenter `"$Script:vCenterName`" was not found."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        } else {
            # VCF PowerCLI 9: Get-VMHost uses -Location for cluster (no -Cluster parameter). -WarningAction SilentlyContinue suppresses VMHost.DatastoreIdList deprecation.
            $hostCount = (Get-VMHost -Location $cluster -WarningAction SilentlyContinue -ErrorAction Stop).Count
            Write-LogMessage -Type DEBUG -Message "Update-Cluster: cluster `"$ClusterName`" has $hostCount host(s)."

            if ($hostCount -eq 0) {
                Write-LogMessage -Type WARNING -Message "Update-Cluster: cluster `"$ClusterName`" has no hosts; skipping HA/DRS configuration."
                return
            }
            if ($hostCount -eq 1) {
                # Single-host cluster: enable HA with admission control disabled (no failover capacity). Supervisor requires HA enabled.
                $cluster | Set-Cluster -DrsEnabled:$true -HAEnabled:$true -HAAdmissionControlEnabled $false -DrsAutomationLevel FullyAutomated -Confirm:$false -Server $Script:vCenterName -ErrorAction Stop | Out-Null
                Write-LogMessage -Type INFO -Message "Cluster `"$ClusterName`" has one host; HA enabled (admission control disabled), DRS enabled."
            } else {
                Set-MultiHostClusterHA -Cluster $cluster -ClusterName $ClusterName -HaClusterResourceFailoverPercent $HaClusterResourceFailoverPercent -HaPolicy $HaPolicy -HostCount $hostCount
            }
        }
    } catch [System.UnauthorizedAccessException] {
        $err = "Cannot update settings on cluster `"$ClusterName`" on `"$Script:vCenterName`" due to authorization issues: $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
    catch [System.TimeoutException] {
        $err = "Cannot update settings on cluster `"$ClusterName`" on `"$Script:vCenterName`" due to network/timeout issues: $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    } catch [VcfDeploymentException] {
        throw  # already logged and typed — propagate without re-wrapping
    } catch {
        $err = "Failed to update settings on cluster `"$ClusterName`" on `"$Script:vCenterName`" : $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -AppendNewLine -Message $err
        throw [VcfDeploymentException]::new($err)
    }
}
function Invoke-ReconfigureClusterHA {

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
        Multi-host clusters only (ignored for single-host): reservationBased, slotBased, or disabled. Passed through to Update-Cluster. Deployment sets this from common/clusters haPolicy for vSAN-OSA and vSAN-ESA. VMFS is always single-host; Update-Cluster forces HAAdmissionControlEnabled=$false regardless of this value.

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

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [ValidateRange(0, 300)] [Int]$DelaySeconds = 10,
        [Parameter(Mandatory = $false)] [ValidateSet("disabled", "reservationBased", "slotBased")] [String]$HaPolicy = "reservationBased"
    )

    $connectionTest = Test-VcenterConnection
    if (-not $connectionTest.IsConnected) {
        $err = "Not connected to vCenter `"$Script:vCenterName`": $($connectionTest.ErrorMessage)"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
    if ($DelaySeconds -gt 0) {
        Write-LogMessage -Type DEBUG -Message "Waiting $DelaySeconds seconds for vCenter to see management network on all hosts before applying HA settings."
        Start-Sleep -Seconds $DelaySeconds
    }
    Update-Cluster -ClusterName $ClusterName -HaPolicy $HaPolicy
}
function Test-VmkernelVsanAndWitnessTraffic {

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
    
        .EXAMPLE
        Test-VmkernelVsanAndWitnessTraffic -VMHost $vmHostObject
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $false)] [Bool]$RequireWitnessTraffic = $true,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$VMHost
    )

    $hostName = $VMHost.Name
    $trafficDesc = if ($RequireWitnessTraffic) { "vSAN and vSAN witness traffic" } else { "vSAN traffic only (witness host)" }
    Write-LogMessage -Type DEBUG -Message "Test-VmkernelVsanAndWitnessTraffic: Checking VMkernel interfaces on host `"$hostName`" for $trafficDesc."

    $vmkernelAdapters = Get-VmkernelAdaptersOnHost -VMHost $VMHost
    $adapterCount = if ($vmkernelAdapters) { @($vmkernelAdapters).Count } else { 0 }
    Write-LogMessage -Type DEBUG -Message "Test-VmkernelVsanAndWitnessTraffic: Host `"$hostName`" has $adapterCount VMkernel adapter(s)."

    $hasVsanProperty = $false
    $hasWitnessProperty = $false
    $vmk0Adapter = $null
    $hasCompliantInterface = $false

    if ($vmkernelAdapters -and $vmkernelAdapters.Count -gt 0) {
        $firstAdapter = $vmkernelAdapters | Select-Object -First 1
        $hasVsanProperty = $null -ne $firstAdapter.PSObject.Properties["VsanTrafficEnabled"]
        $hasWitnessProperty = $null -ne $firstAdapter.PSObject.Properties["VsanWitnessTrafficEnabled"]
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
function Get-VsanTrafficByInterface {

    <#
    .SYNOPSIS
        Aggregates vSAN traffic type strings per interface from an esxcli vsan network list result.
    .DESCRIPTION
        Iterates the items array returned by esxcli vsan network list, extracting the traffic type
        and interface name from each item using case-insensitive property lookups. Returns a hashtable
        keyed by interface name with arrays of traffic-type strings as values.
    .PARAMETER Items
        Array of objects from esxcli vsan network list.
    .EXAMPLE
        $trafficMap = Get-VsanTrafficByInterface -Items $items
    .NOTES
        Called by Test-VmkernelVsanTrafficViaEsxcli. Property names vary by ESXi version.
    #>

    [CmdletBinding()]
    [OutputType([Hashtable])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object[]]$Items
    )

    # Discover which property name variants are present once using the first item —
    # esxcli result sets use a consistent schema for all rows, so probing each item is redundant.
    $trafficPropName = $null
    $ifacePropName = $null
    if ($Items.Count -gt 0) {
        $firstItem = $Items[0]
        $trafficPropName = @('TrafficType', 'traffictype', 'Traffic type') |
            Where-Object { $firstItem.PSObject.Properties[$_] } | Select-Object -First 1
        $ifacePropName = @('Interface', 'interface', 'InterfaceName', 'interfacename', 'VmkNicName', 'vmknicname', 'Name') |
            Where-Object { $firstItem.PSObject.Properties[$_] } | Select-Object -First 1
    }

    $trafficByInterface = @{}
    $itemIndex = 0
    foreach ($item in $Items) {
        $trafficType = if ($trafficPropName) { $item.$trafficPropName } else { $item.ToString() }
        $trafficStr = if ($null -eq $trafficType) { "" }
                      elseif ($trafficType -is [Array] -or $trafficType -is [System.Collections.IEnumerable]) {
                          ($trafficType | ForEach-Object { [String]$_ }) -join ","
                      } else { [String]$trafficType }
        if ([String]::IsNullOrWhiteSpace($trafficStr)) { $itemIndex++; continue }
        $ifaceKey = if ($ifacePropName) { [String]$item.$ifacePropName } else { $null }
        if (-not $ifaceKey) { $ifaceKey = "item_$itemIndex" }
        if (-not $trafficByInterface[$ifaceKey]) { $trafficByInterface[$ifaceKey] = @() }
        $trafficByInterface[$ifaceKey] += $trafficStr
        $itemIndex++
    }
    return $trafficByInterface
}
function Test-AggregatedVsanTraffic {

    <#
    .SYNOPSIS
        Tests whether the aggregated esxcli vsan network list result shows the required traffic types.
    .DESCRIPTION
        Checks the per-interface traffic map for vSAN and (optionally) Witness traffic. When the
        structured check fails, falls back to regex parsing of the raw result string. Returns $true
        when required traffic is present, $false otherwise with a diagnostic log.
    .PARAMETER HostName
        Host name used in log messages.
    .PARAMETER Items
        Original items array used to build the diagnostic log on failure.
    .PARAMETER RequireWitnessTraffic
        When set, both vSAN and Witness traffic must be present.
    .PARAMETER Result
        Raw result from the esxcli vsan network list invocation, used for text fallback parsing.
    .PARAMETER TrafficByInterface
        Hashtable built by Get-VsanTrafficByInterface.
    .EXAMPLE
        $ok = Test-AggregatedVsanTraffic -HostName "esx1" -Items $items -RequireWitnessTraffic -Result $result -TrafficByInterface $trafficMap
    .NOTES
        Called by Test-VmkernelVsanTrafficViaEsxcli.
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$HostName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object[]]$Items,
        [Parameter(Mandatory = $false)] [Switch]$RequireWitnessTraffic,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$Result,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Hashtable]$TrafficByInterface
    )

    $anyVsan = $false
    $anyWitness = $false
    foreach ($iface in $TrafficByInterface.Keys) {
        $combined = ($TrafficByInterface[$iface] | ForEach-Object { $_.Trim() }) -join ","
        if ([String]::IsNullOrWhiteSpace($combined)) { continue }
        $hasVsan    = $combined -match 'vsan'
        $hasWitness = $combined -match 'witness'
        if ($hasVsan) { $anyVsan = $true }
        if ($hasWitness) { $anyWitness = $true }
        if ($hasVsan -and (-not $RequireWitnessTraffic -or $hasWitness)) {
            Write-LogMessage -Type DEBUG -Message "Test-VmkernelVsanTrafficViaEsxcli: Host `"$HostName`" has required vSAN traffic per esxcli (interface $iface): `"$combined`"."
            return $true
        }
    }
    if ($RequireWitnessTraffic -and $anyVsan -and $anyWitness) {
        Write-LogMessage -Type DEBUG -Message "Test-VmkernelVsanTrafficViaEsxcli: Host `"$HostName`" has vSAN on one interface and witness on another per esxcli; treating as compliant."
        return $true
    }
    $resultStr = $Result | Out-String
    foreach ($match in [Regex]::Matches($resultStr, 'Traffic Type:\s*([^\r\n]+)')) {
        $trafficStr = $match.Groups[1].Value.Trim()
        if ([String]::IsNullOrWhiteSpace($trafficStr)) { continue }
        $hasVsan    = $trafficStr -match 'vsan'
        $hasWitness = $trafficStr -match 'witness'
        if ($hasVsan) { $anyVsan = $true }
        if ($hasWitness) { $anyWitness = $true }
        if ($hasVsan -and (-not $RequireWitnessTraffic -or $hasWitness)) {
            Write-LogMessage -Type DEBUG -Message "Test-VmkernelVsanTrafficViaEsxcli: Host `"$HostName`" has required vSAN traffic per esxcli (parsed from text): `"$trafficStr`"."
            return $true
        }
    }
    if ($RequireWitnessTraffic -and $anyVsan -and $anyWitness) {
        Write-LogMessage -Type DEBUG -Message "Test-VmkernelVsanTrafficViaEsxcli: Host `"$HostName`" has vSAN and witness (text parse); treating as compliant."
        return $true
    }
    $sampleLog = "none"
    if ($Items.Count -gt 0) {
        $keys = @($Items[0].PSObject.Properties.Name)
        $firstCombined = ($TrafficByInterface.Values | Select-Object -First 1) -join ","
        $sampleLog = "first item keys: $($keys -join ', '); combined traffic sample: $firstCombined"
    }
    Write-LogMessage -Type DEBUG -Message "Test-VmkernelVsanTrafficViaEsxcli: Host `"$HostName`" esxcli vsan network list did not show required traffic (RequireWitnessTraffic=$RequireWitnessTraffic). $sampleLog"
    return $false
}
function Test-VmkernelVsanTrafficViaEsxcli {

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
    
        .EXAMPLE
        Test-VmkernelVsanTrafficViaEsxcli -VMHost $vmHostObject
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $false)] [Bool]$RequireWitnessTraffic = $true,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$VMHost
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
        $trafficByInterface = Get-VsanTrafficByInterface -Items $items
        return Test-AggregatedVsanTraffic `
            -HostName $hostName `
            -Items $items `
            -RequireWitnessTraffic:$RequireWitnessTraffic `
            -Result $result `
            -TrafficByInterface $trafficByInterface
    } catch {
        Write-LogMessage -Type DEBUG -Message "Test-VmkernelVsanTrafficViaEsxcli: Failed on host `"$hostName`": $($_.Exception.Message)."
        return $false
    }
}
function Test-VsanTrafficVmkernelHasValidIp {

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
    
        .EXAMPLE
        Test-VsanTrafficVmkernelHasValidIp -VMHost $vmHostObject
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$VMHost
    )
    $vmkernelAdapters = Get-VmkernelAdaptersOnHost -VMHost $VMHost
    if (-not $vmkernelAdapters) { return $false }
    $hasVsanProperty = $null -ne ($vmkernelAdapters | Select-Object -First 1).PSObject.Properties["VsanTrafficEnabled"]
    if (-not $hasVsanProperty) { return $false }
    foreach ($adapter in $vmkernelAdapters) {
        if ($adapter.VsanTrafficEnabled -ne $true) { continue }
        $ip = $null
        if ($adapter.PSObject.Properties['IP']) { $ip = $adapter.IP }
        if ([String]::IsNullOrWhiteSpace($ip) -and $adapter.PSObject.Properties['Address']) { $ip = $adapter.Address }
        if (-not [String]::IsNullOrWhiteSpace($ip)) { return $true }
    }
    return $false
}
function Get-VsanNetworkTrafficByInterface {

    <#
        .SYNOPSIS
        Reads esxcli vsan network list and returns a hashtable mapping VMkernel name to traffic-type strings.

        .DESCRIPTION
        Invokes esxcli.vsan.network.list and normalizes the result regardless of API return shape (array,
        enumerable, or scalar) into a hashtable keyed by interface name. Values are arrays of traffic-type
        strings. Returns an empty hashtable when the list command is unavailable.

        .PARAMETER EsxcliInstance
        The esxcli V2 instance returned by Get-EsxCli.

        .OUTPUTS
        Hashtable mapping VMkernel name to an array of traffic-type strings.

        .NOTES
        Callers should wrap in try/catch to handle unexpected Invoke() exceptions.
    
        .EXAMPLE
        $vsanNetworkTrafficByInterface = Get-VsanNetworkTrafficByInterface -EsxcliInstance "value"
    #>

    [CmdletBinding()]
    [OutputType([Hashtable])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$EsxcliInstance
    )

    $listCmd = $EsxcliInstance.vsan.network.list
    if (-not $listCmd) { return @{} }
    $listResult = $listCmd.Invoke()
    $items = if ($listResult -is [Array] -or ($listResult -is [System.Collections.IEnumerable] -and $listResult -isnot [string])) {
        @($listResult)
    } else {
        $listProp = $listResult.PSObject.Properties | Where-Object { $_.Value -is [Array] -or $_.Value -is [System.Collections.IEnumerable] } | Select-Object -First 1
        if ($listProp) { @($listProp.Value) } else { @($listResult) }
    }
    $trafficByInterface = @{}
    foreach ($item in $items) {
        $trafficPropName = @('TrafficType', 'traffictype') |
            Where-Object { $null -ne $item.PSObject.Properties[$_] } | Select-Object -First 1
        $trafficStr = if ($trafficPropName) { $item.$trafficPropName } else { $null }
        $trafficStr = if ($null -eq $trafficStr) { "" }
            elseif ($trafficStr -is [Array]) { ($trafficStr | ForEach-Object { [String]$_ }) -join "," }
            else { [String]$trafficStr }
        $ifacePropName = @('Interface', 'interface', 'InterfaceName', 'interfacename', 'VmkNicName', 'vmknicname') |
            Where-Object { $null -ne $item.PSObject.Properties[$_] } | Select-Object -First 1
        $ifaceKey = if ($ifacePropName) { $item.$ifacePropName } else { $null }
        if (-not $ifaceKey) { continue }
        $ifaceKey = [String]$ifaceKey
        if (-not $trafficByInterface[$ifaceKey]) { $trafficByInterface[$ifaceKey] = @() }
        $trafficByInterface[$ifaceKey] += $trafficStr
    }
    return $trafficByInterface
}
function Invoke-EsxcliVsanNetworkVariants {

    <#
        .SYNOPSIS
        Tries five known parameter-name variants for an esxcli vsan network ip command.

        .DESCRIPTION
        Some ESX hosts expose esxcli vsan network ip add/set with different parameter name conventions
        (e.g. interfacename, interface-name, InterfaceName). This function iterates all known variants
        until one succeeds or all fail.

        .PARAMETER Command
        The esxcli vsan network ip add or set command object.

        .PARAMETER TrafficTypes
        Array of traffic type strings to assign (e.g. @("witness") or @("vsan","witness")).

        .PARAMETER VmkernelName
        VMkernel adapter name (e.g. vmk0).

        .OUTPUTS
        PSCustomObject with .Invoked (bool), .AlreadyInUse (bool), .LastError (string).
    
        .EXAMPLE
        Invoke-EsxcliVsanNetworkVariants -Command "value" -TrafficTypes "value" -VmkernelName "resource-name"
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$Command,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object[]]$TrafficTypes,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VmkernelName
    )

    $paramSets = @(
        @{ interfacename = $VmkernelName; traffictype = $TrafficTypes },
        @{ "interface-name" = $VmkernelName; "traffic-type" = $TrafficTypes },
        @{ interface_name = $VmkernelName; traffic_type = $TrafficTypes },
        @{ i = $VmkernelName; T = $TrafficTypes },
        @{ InterfaceName = $VmkernelName; TrafficType = $TrafficTypes }
    )
    $lastError = $null
    $alreadyInUse = $false
    foreach ($params in $paramSets) {
        try {
            $Command.Invoke($params) | Out-Null
            return [PSCustomObject]@{ Invoked = $true; AlreadyInUse = $false; LastError = $null }
        } catch {
            $lastError = $_.Exception.Message
            if ($lastError -match "already in use|Can't add again|use 'set' command") { $alreadyInUse = $true }
        }
    }
    return [PSCustomObject]@{ Invoked = $false; AlreadyInUse = $alreadyInUse; LastError = $lastError }
}
function Invoke-VsanAddWithCreateArgs {

    <#
        .SYNOPSIS
        Attempts esxcli vsan network ip add using CreateArgs() parameter introspection.

        .DESCRIPTION
        Calls AddCommand.CreateArgs() to obtain the host's exact parameter names, then builds the argument
        object and invokes the command. Handles hashtable, collection, and property-based args objects.
        Returns a result object so callers can fall back to named-variant iteration if this path fails.

        .PARAMETER AddCommand
        The esxcli vsan network ip add command object.

        .PARAMETER TrafficTypes
        Traffic types to assign (e.g. @("vsan","witness")).

        .PARAMETER VmkernelName
        VMkernel adapter name (e.g. vmk0).

        .OUTPUTS
        PSCustomObject with .Invoked (bool), .AlreadyInUse (bool), .LastError (string), .ArgNamesLog (string).
    
        .EXAMPLE
        Invoke-VsanAddWithCreateArgs -AddCommand "value" -TrafficTypes "value" -VmkernelName "resource-name"
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$AddCommand,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object[]]$TrafficTypes,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VmkernelName
    )

    try {
        $argsObj = $AddCommand.CreateArgs()
        if ($null -eq $argsObj) {
            return [PSCustomObject]@{ Invoked = $false; AlreadyInUse = $false; LastError = $null; ArgNamesLog = $null }
        }
        $isHashtable = $argsObj -is [System.Collections.IDictionary]
        $isCollection = -not $isHashtable -and $argsObj -is [System.Collections.IEnumerable] -and $argsObj -isnot [string]
        $argNames = if ($isHashtable) {
            @($argsObj.Keys | ForEach-Object { $_ })
        } elseif ($isCollection) {
            @($argsObj | ForEach-Object { if ($_.PSObject.Properties['Name']) { $_.Name } elseif ($_.Key) { $_.Key } else { $_ } })
        } else {
            @($argsObj.PSObject.Properties | ForEach-Object { $_.Name })
        }
        $argNamesLog = "CreateArgs parameter names: ($($argNames -join ', '))."
        $interfaceParam = $argNames | Where-Object { $_ -and $_ -match "interface|^i$" } | Select-Object -First 1
        $trafficParam = $argNames | Where-Object { $_ -and $_ -match "traffic|^T$" } | Select-Object -First 1
        if (-not ($interfaceParam -and $trafficParam)) {
            return [PSCustomObject]@{ Invoked = $false; AlreadyInUse = $false; LastError = $null; ArgNamesLog = $argNamesLog }
        }
        if ($isHashtable -or $isCollection) {
            $AddCommand.Invoke(@{ $interfaceParam = $VmkernelName; $trafficParam = $TrafficTypes }) | Out-Null
        } else {
            $argsObj.$interfaceParam = $VmkernelName
            $argsObj.$trafficParam = $TrafficTypes
            $AddCommand.Invoke($argsObj) | Out-Null
        }
        return [PSCustomObject]@{ Invoked = $true; AlreadyInUse = $false; LastError = $null; ArgNamesLog = $argNamesLog }
    } catch {
        $errMsg = $_.Exception.Message
        return [PSCustomObject]@{
            Invoked      = $false
            AlreadyInUse = $errMsg -match "already in use|Can't add again|use 'set' command"
            LastError    = $errMsg
            ArgNamesLog  = $null
        }
    }
}
function Invoke-VsanSetPathVerification {

    <#
        .SYNOPSIS
        Verifies vSAN witness traffic persisted after using the ip set path, and retries with witness-only add if needed.

        .DESCRIPTION
        On some hosts, esxcli vsan network ip set does not persist the witness traffic type. After a successful
        set, this function reads the current vSAN network list and, if only vsan (not witness) is present for the
        VMkernel, retries with a witness-only add. Non-fatal: failures are logged at DEBUG level.

        .PARAMETER AddCommand
        The esxcli vsan network ip add command object for the retry attempt.

        .PARAMETER EsxcliInstance
        The esxcli V2 instance used to read the current vSAN network list.

        .PARAMETER HostName
        Host name for log messages.

        .PARAMETER PostSuccessDelaySeconds
        Seconds to sleep after a successful witness-only add retry.

        .PARAMETER VmkernelName
        VMkernel adapter name being configured.
    
        .EXAMPLE
        Invoke-VsanSetPathVerification -AddCommand "value" -EsxcliInstance "value" -HostName "resource-name" -VmkernelName "resource-name"
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$AddCommand,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$EsxcliInstance,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$HostName,
        [Parameter(Mandatory = $false)] [ValidateRange(0, 300)] [Int]$PostSuccessDelaySeconds = 5,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VmkernelName
    )

    try {
        $trafficAfterSet = Get-VsanNetworkTrafficByInterface -EsxcliInstance $EsxcliInstance
        $listStr = ($trafficAfterSet | Out-String).Trim()
        Write-LogMessage -Type DEBUG -Message "Invoke-VsanSetPathVerification: After set, vsan network list on `"$HostName`": $listStr"
        $combinedTraffic = if ($trafficAfterSet[$VmkernelName]) { $trafficAfterSet[$VmkernelName] -join "," } else { "" }
        if ($combinedTraffic -match 'vsan' -and $combinedTraffic -notmatch 'witness') {
            Write-LogMessage -Type DEBUG -Message "Invoke-VsanSetPathVerification: List after set shows vsan but not witness; trying add with witness only."
            $witnessResult = Invoke-EsxcliVsanNetworkVariants -Command $AddCommand -VmkernelName $VmkernelName -TrafficTypes @("witness")
            if ($witnessResult.Invoked) {
                Write-LogMessage -Type INFO -Message "Added vSAN witness traffic to $VmkernelName on host `"$HostName`" via add (witness only) after set."
                if ($PostSuccessDelaySeconds -gt 0) { Start-Sleep -Seconds $PostSuccessDelaySeconds }
            }
        }
    } catch {
        Write-LogMessage -Type DEBUG -Message "Invoke-VsanSetPathVerification: Could not run vsan network list after set on `"$HostName`": $($_.Exception.Message)"
    }
}
function Add-VsanWitnessTrafficToVmkViaEsxcli {

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
    
        .EXAMPLE
        Add-VsanWitnessTrafficToVmkViaEsxcli -VMHost $vmHostObject
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(0, 300)] [Int]$PostSuccessDelaySeconds = 5,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$VMHost,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$VmkernelName = "vmk0",
        [Parameter(Mandatory = $false)] [Switch]$WitnessOnly
    )

    $hostName = $VMHost.Name
    # vmk0 (mgmt + witness only) and dedicated vmk3 get only witness; shared vSAN VMkernel gets both vsan and witness.
    $trafficTypes = if ($WitnessOnly.IsPresent) { @("witness") } else { @("vsan", "witness") }
    try {
        $esxcli = Get-EsxCli -VMHost $VMHost -V2 -Server $Script:vCenterName -ErrorAction Stop
        try {
            $trafficByInterface = Get-VsanNetworkTrafficByInterface -EsxcliInstance $esxcli
            $existing = if ($trafficByInterface[$VmkernelName]) { $trafficByInterface[$VmkernelName] -join "," } else { "" }
            if ($existing -match 'witness') {
                Write-LogMessage -Type DEBUG -Message "vSAN witness traffic already configured on $VmkernelName on host `"$hostName`". Skipping witness traffic add."
                return $true
            }
        } catch {
            Write-LogMessage -Type DEBUG -Message "Add-VsanWitnessTrafficToVmkViaEsxcli: Could not check vsan network list for idempotency on `"$hostName`": $($_.Exception.Message). Proceeding to add."
        }
        $addCmd = $esxcli.vsan.network.ip.add
        if (-not $addCmd) {
            $err = "esxcli vsan network ip add not available on host `"$hostName`". vSAN witness traffic is required; deployment will roll back."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
        $caResult = Invoke-VsanAddWithCreateArgs -AddCommand $addCmd -VmkernelName $VmkernelName -TrafficTypes $trafficTypes
        $invoked = $caResult.Invoked
        $addFailedWithAlreadyInUse = $caResult.AlreadyInUse
        $createArgsArgNamesLog = $caResult.ArgNamesLog
        $lastError = $caResult.LastError
        if (-not $invoked -and $caResult.LastError) {
            Write-LogMessage -Type DEBUG -Message "Add-VsanWitnessTrafficToVmkViaEsxcli: CreateArgs/Invoke path failed: $($caResult.LastError)"
        }
        if (-not $invoked) {
            $varResult = Invoke-EsxcliVsanNetworkVariants -Command $addCmd -VmkernelName $VmkernelName -TrafficTypes $trafficTypes
            if ($varResult.Invoked) { $invoked = $true }
            if ($varResult.AlreadyInUse) {
                $addFailedWithAlreadyInUse = $true
                Write-LogMessage -Type DEBUG -Message "Add-VsanWitnessTrafficToVmkViaEsxcli: Add reported interface already in use; trying vsan network ip set."
            }
            $lastError = $varResult.LastError
        }
        if (-not $invoked -and $addFailedWithAlreadyInUse) {
            $setCmd = $esxcli.vsan.network.ip.set
            if ($setCmd) {
                $setResult = Invoke-EsxcliVsanNetworkVariants -Command $setCmd -VmkernelName $VmkernelName -TrafficTypes $trafficTypes
                if ($setResult.Invoked) { $invoked = $true; $usedSetPath = $true }
                else { $lastError = $setResult.LastError }
            } else {
                Write-LogMessage -Type DEBUG -Message "Add-VsanWitnessTrafficToVmkViaEsxcli: vsan network ip set command not available on host."
            }
        }
        if (-not $invoked) {
            if ($lastError -match "already in use|Can't add again") {
                Write-LogMessage -Type DEBUG -Message "vSAN witness traffic already configured on $VmkernelName on host `"$hostName`" (esxcli reported already in use). Skipping witness traffic add."
                return $true
            }
            $summary = if ($createArgsArgNamesLog) { " $createArgsArgNamesLog" } else { " CreateArgs returned null or no usable params." }
            $errorMsg = "Add-VsanWitnessTrafficToVmkViaEsxcli: All attempts failed.$summary Last error: $lastError"
            Write-LogMessage -Type ERROR -Message $errorMsg
            throw [VcfDeploymentException]::new($errorMsg)
        }
        Write-LogMessage -Type INFO -Message "Added vSAN witness traffic to $VmkernelName on host `"$hostName`"."
        if ($PostSuccessDelaySeconds -gt 0) { Start-Sleep -Seconds $PostSuccessDelaySeconds }
        if ($usedSetPath) {
            Invoke-VsanSetPathVerification -AddCommand $addCmd -EsxcliInstance $esxcli -HostName $hostName -PostSuccessDelaySeconds $PostSuccessDelaySeconds -VmkernelName $VmkernelName
        }
        return $true
    } catch [VcfDeploymentException] {
        throw
    } catch {
        $err = "Could not add vSAN witness traffic to $VmkernelName on host `"$hostName`" via esxcli: $($_.Exception.Message). vSAN witness traffic is required; deployment will roll back."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
}
function Invoke-EsxcliIpv4SetViaCreateArgs {

    <#
    .SYNOPSIS
        Attempts to invoke esxcli network ip interface ipv4 set using the CreateArgs introspection path.
    .DESCRIPTION
        Calls CreateArgs() on the esxcli set command to discover parameter names at runtime, then
        populates and invokes the command. Returns $true when the invocation succeeds. Returns $false
        when the CreateArgs object is null, required parameters are missing, or any exception occurs.
        On failure, writes the error to LastErrorRef so the caller can fall through to a static
        fallback parameter set.
    .PARAMETER GatewayAddress
        Cleaned IPv4 gateway address (no prefix suffix).
    .PARAMETER HostName
        ESX host name, used in log messages.
    .PARAMETER Ipv4Address
        Static IPv4 address to assign to the VMkernel.
    .PARAMETER LastErrorRef
        Reference variable updated with the last exception message when the path fails.
    .PARAMETER SetCmd
        The esxcli network ip interface ipv4 set command object.
    .PARAMETER SubnetMask
        IPv4 netmask for the VMkernel.
    .PARAMETER VmkernelName
        VMkernel device name (e.g. vmk3).
    .EXAMPLE
        $ok = Invoke-EsxcliIpv4SetViaCreateArgs -GatewayAddress "10.30.12.1" -HostName "esx1" -Ipv4Address "10.30.12.5" -LastErrorRef ([Ref]$lastError) -SetCmd $setCmd -SubnetMask "255.255.255.0" -VmkernelName "vmk3"
    .NOTES
        Returns $true on success; $false on any failure (error is written to LastErrorRef).
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$GatewayAddress,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$HostName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Ipv4Address,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Ref]$LastErrorRef,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$SetCmd,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SubnetMask,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VmkernelName
    )

    try {
        $argsObj = $SetCmd.CreateArgs()
        if ($null -eq $argsObj) { return $false }

        $isHashtable = $argsObj -is [System.Collections.IDictionary]
        $isCollection = -not $isHashtable -and $argsObj -is [System.Collections.IEnumerable] -and $argsObj -isnot [string]
        $argNames = if ($isHashtable) {
            @($argsObj.Keys | ForEach-Object { $_ })
        } elseif ($isCollection) {
            @($argsObj | ForEach-Object { if ($_.PSObject.Properties["Name"]) { $_.Name } elseif ($_.Key) { $_.Key } else { $_ } })
        } else {
            @($argsObj.PSObject.Properties | ForEach-Object { $_.Name })
        }

        $ifaceParam = $argNames | Where-Object { $_ -and ($_ -match "^i$|^interfacename$|interface-name|interface_name") } | Select-Object -First 1
        $ipParam    = $argNames | Where-Object { $_ -and ($_ -match "^ipv4$|^I$|^-I$") } | Select-Object -First 1
        $maskParam  = $argNames | Where-Object { $_ -and ($_ -match "netmask|^N$") } | Select-Object -First 1
        $gwParam    = $argNames | Where-Object { $_ -and ($_ -match "gateway|^g$") } | Select-Object -First 1
        $typeParam  = $argNames | Where-Object { $_ -and ($_ -match "^type$|^t$") } | Select-Object -First 1

        if (-not ($ifaceParam -and $ipParam -and $maskParam -and $typeParam)) { return $false }

        if ($isHashtable -or $isCollection) {
            $invokeTable = @{ $ifaceParam = $VmkernelName; $ipParam = $Ipv4Address; $maskParam = $SubnetMask; $typeParam = "static" }
            if ($gwParam) { $invokeTable[$gwParam] = $GatewayAddress }
            $SetCmd.Invoke($invokeTable) | Out-Null
        } else {
            $argsObj.$ifaceParam = $VmkernelName
            $argsObj.$ipParam    = $Ipv4Address
            $argsObj.$maskParam  = $SubnetMask
            if ($gwParam) { $argsObj.$gwParam = $GatewayAddress }
            $argsObj.$typeParam  = "static"
            $SetCmd.Invoke($argsObj) | Out-Null
        }

        Write-LogMessage -Type INFO -Message "Set default gateway $GatewayAddress on $VmkernelName on host `"$HostName`" (esxcli network ip interface ipv4 set)."
        return $true
    } catch {
        $LastErrorRef.Value = $_.Exception.Message
        Write-LogMessage -Type DEBUG -Message "Set-VmkernelIpv4StaticGatewayViaEsxcli: CreateArgs path failed: $($_.Exception.Message)"
        return $false
    }
}
function Set-VmkernelIpv4StaticGatewayViaEsxcli {

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
    
        .EXAMPLE
        Set-VmkernelIpv4StaticGatewayViaEsxcli -GatewayAddress "10.0.0.1" -Ipv4Address "10.0.0.1" -SubnetMask "10.0.0.0/24" -VMHost $vmHostObject
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

    $hostName = if ($VMHost.Name) { $VMHost.Name } else { [String]$VMHost }
    $gw = $GatewayAddress.Trim()
    if ($gw -match "/") {
        $gw = ($gw -split "/")[0].Trim()
    }
    if (-not (Test-ValidIPv4Address -IpAddress $gw)) {
        $err = "Set-VmkernelIpv4StaticGatewayViaEsxcli: gateway `"$gw`" is not a valid IPv4 address for host `"$hostName`"."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
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
        $err = "Set-VmkernelIpv4StaticGatewayViaEsxcli: esxcli network ip interface ipv4 set is not available on host `"$hostName`"."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }

    $lastError = $null
    if (Invoke-EsxcliIpv4SetViaCreateArgs -GatewayAddress $gw -HostName $hostName -Ipv4Address $Ipv4Address -LastErrorRef ([Ref]$lastError) -SetCmd $setCmd -SubnetMask $SubnetMask -VmkernelName $VmkernelName) {
        return
    }

    $paramSets = @(
        @{ interfacename = $VmkernelName; ipv4 = $Ipv4Address; netmask = $SubnetMask; gateway = $gw; type = "static" },
        @{ "interface-name" = $VmkernelName; ipv4 = $Ipv4Address; netmask = $SubnetMask; gateway = $gw; type = "static" },
        @{ interface_name = $VmkernelName; ipv4 = $Ipv4Address; netmask = $SubnetMask; gateway = $gw; type = "static" }
    )
    foreach ($paramSet in $paramSets) {
        try {
            $setCmd.Invoke($paramSet) | Out-Null
            Write-LogMessage -Type INFO -Message "Set default gateway $gw on $VmkernelName on host `"$hostName`" (esxcli fallback parameter set)."
            return
        } catch {
            $lastError = $_.Exception.Message
            continue
        }
    }
    $err = "Set-VmkernelIpv4StaticGatewayViaEsxcli: all attempts failed on `"$hostName`" for $VmkernelName. Last error: $lastError"
    Write-LogMessage -Type ERROR -Message $err
    throw [VcfDeploymentException]::new($err)
}
function Invoke-HostVdsCleanupForClusterMove {

    <#
        .SYNOPSIS
        Removes non-management VMkernel adapters, restores vmk0 to a standard switch, and detaches pNICs from all VDSes on a host.

        .DESCRIPTION
        Executes the three-step VDS cleanup sequence required before moving a host to a different cluster
        when vmk0 is on a VDS: (1) removes non-management VMkernel interfaces; (2) calls
        Restore-ManagementToVssBeforeVdsRemoval to migrate vmk0 to vSwitch0-restore; (3) removes all
        physical NIC uplinks from every VDS on the host. Throws VcfDeploymentException when management
        restore fails. Non-fatal warnings are logged for VMkernel or pNIC removal failures.

        .PARAMETER EsxHostName
        FQDN or IP address of the host, used in log messages.

        .PARAMETER MgmtVdsName
        Name of the management VDS (where vmk0 currently resides), passed to Restore-ManagementToVssBeforeVdsRemoval.

        .PARAMETER Server
        vCenter server name for PowerCLI cmdlet calls.

        .PARAMETER VMHost
        The VMHost object for the host to clean up.

        .EXAMPLE
        Invoke-HostVdsCleanupForClusterMove -EsxHostName "esx01.lab" -MgmtVdsName "vds-mgmt" -VMHost $vmh -Server "vc.lab"

        .NOTES
        Called by Invoke-PrepareHostForClusterMove when vmk0 is on a VDS with dual uplinks.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EsxHostName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$MgmtVdsName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Server,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$VMHost
    )

    $vmkAdapters      = @(Get-NonMgmtVmkernelAdaptersOnHost -VMHost $VMHost -Server $Server)
    $vmkRemovalFailed = $false
    foreach ($vmk in $vmkAdapters) {
        try {
            Remove-VMHostNetworkAdapter -Nic $vmk -Confirm:$false -ErrorAction Stop
            Write-LogMessage -Type DEBUG -Message "Removed VMkernel `"$($vmk.Name)`" from host `"$EsxHostName`"."
        } catch {
            Write-LogMessage -Type WARNING -Message "Could not remove VMkernel `"$($vmk.Name)`" from host `"$EsxHostName`": $($_.Exception.Message). Proceeding with management restore; verify host state after move."
            $vmkRemovalFailed = $true
        }
    }
    if ($vmkRemovalFailed) {
        Write-LogMessage -Type WARNING -Message "One or more non-management VMkernel adapters could not be removed from host `"$EsxHostName`". Verify and clean up stale VMkernel adapters manually after the cluster move."
    }

    $restoreResult = Restore-ManagementToVssBeforeVdsRemoval -VMHost $VMHost -VdsNameWithMgmt $MgmtVdsName -Server $Server
    if ($restoreResult.RestoreAttempted -and -not $restoreResult.Success) {
        $err = "Could not restore management to standard switch on host `"$EsxHostName`": $($restoreResult.Message)"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }

    $allVdsOnHost = @(Get-VdsListOnHost -VMHost $VMHost -Server $Server)
    foreach ($vds in $allVdsOnHost) {
        $pnicsOnVds = @(Get-VMHostNetworkAdapter -VMHost $VMHost -Physical -VirtualSwitch $vds -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue)
        foreach ($pnic in $pnicsOnVds) {
            try {
                $pnic | Remove-VDSwitchPhysicalNetworkAdapter -Confirm:$false -WarningAction SilentlyContinue -ErrorAction Stop
                Write-LogMessage -Type DEBUG -Message "Detached pNIC `"$($pnic.Name)`" from VDS `"$($vds.Name)`" on host `"$EsxHostName`"."
            } catch {
                Write-LogMessage -Type WARNING -Message "Could not detach pNIC `"$($pnic.Name)`" from VDS `"$($vds.Name)`" on host `"$EsxHostName`": $($_.Exception.Message)."
            }
        }
    }
}
function Invoke-PrepareHostForClusterMove {

    <#
        .SYNOPSIS
        Prepares a host in one cluster for migration to another cluster within the same vCenter.

        .DESCRIPTION
        When a host with no powered-on VMs is found in vCenter inventory under a different cluster than the deployment target, this function: (1) checks whether vmk0 is already on a standard switch or on a VDS; (2) prompts the operator to confirm the cluster move in both cases; (3) if vmk0 is on a VDS, verifies that VDS has at least two physical NIC uplinks (prerequisite for automated restore), then removes all non-management VMkernel interfaces, migrates vmk0 to a standard switch (vSwitch0-restore) via Restore-ManagementToVssBeforeVdsRemoval, and detaches the host from all Distributed Virtual Switches; (4) if vmk0 is already on a standard switch, skips the VDS cleanup steps entirely. After this function returns, Add-HostToCluster uses Move-VMHost to relocate the host within the vCenter hierarchy.

        .PARAMETER DestinationClusterName
        Name of the cluster the host will be added to.

        .PARAMETER EsxHostName
        FQDN or IP of the host, used in log messages and prompts.

        .PARAMETER Server
        vCenter server name. Defaults to $Script:vCenterName.

        .PARAMETER SourceClusterName
        Name of the cluster the host currently belongs to.

        .PARAMETER VMHost
        The VMHost object for the host to prepare.

        .EXAMPLE
        Invoke-PrepareHostForClusterMove -DestinationClusterName "cl0-site2" -EsxHostName "esx01.example.com" -SourceClusterName "cl0-site1" -VMHost $vmhost

        .NOTES
        Throws [VcfDeploymentException] when the dual-uplink prerequisite is not met, the operator declines the move, or management restore fails. VDS objects are not deleted; only the host's physical NIC uplinks are removed. Requires Restore-ManagementToVssBeforeVdsRemoval and Test-HostManagementVdsDualUplink (Networking.ps1).
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DestinationClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EsxHostName,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$Server = $Script:vCenterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SourceClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$VMHost
    )

    Write-LogMessage -Type INFO -Message "Host `"$EsxHostName`" is in vCenter `"$Server`" under cluster `"$SourceClusterName`" with no powered-on VMs."

    # Check whether vmk0 is already on a standard switch or on a VDS. When vmk0 is already on a
    # standard switch (MgmtVdsName is empty), no VDS cleanup is needed — we skip straight to the
    # operator prompt and then the Add-VMHost call. When vmk0 is on a VDS we must also verify
    # dual uplinks before proceeding, since the automated restore path requires them.
    $dualUplinkCheck = Test-HostManagementVdsDualUplink -VMHost $VMHost -Server $Server
    $vmk0OnStandardSwitch = [String]::IsNullOrWhiteSpace($dualUplinkCheck.MgmtVdsName)

    if ($vmk0OnStandardSwitch) {
        Write-LogMessage -Type INFO -Message "Host `"$EsxHostName`" management (vmk0) is already on a standard vSwitch; no VDS cleanup required before cluster move."
    } else {
        # vmk0 is on a VDS — verify dual uplinks before committing to the automated restore path.
        if (-not $dualUplinkCheck.HasDualUplink) {
            $err = "Host `"$EsxHostName`" management VDS `"$($dualUplinkCheck.MgmtVdsName)`" has fewer than two physical NIC uplinks. Manually move vmk0 to a standard vSwitch in vCenter before re-running deployment to reclaim this host."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
    }

    # Prompt operator to confirm the cluster move in all cases — whether vmk0 is on a VSS or a VDS.
    try {
        $confirmed = $false
        while (-not $confirmed) {
            $response = (Read-Host "Move host `"$EsxHostName`" from cluster `"$SourceClusterName`" to `"$DestinationClusterName`"? (y/N; press Enter for N)").Trim()
            switch -Regex ($response) {
                '^[yY](es)?$' {
                    $actionDetail = if ($vmk0OnStandardSwitch) { "no VDS cleanup required" } else { "will clean up VDS attachments" }
                    Write-LogMessage -Type INFO -Message "User confirmed move of host `"$EsxHostName`" from cluster `"$SourceClusterName`" to `"$DestinationClusterName`" ($actionDetail)."
                    $confirmed = $true
                }
                '^$|^[nN](o)?$' {
                    $errorMsg = "Deployment aborted. User declined to move host `"$EsxHostName`" from cluster `"$SourceClusterName`" to `"$DestinationClusterName`"."
                    Write-LogMessage -Type ERROR -Message $errorMsg
                    throw [VcfDeploymentException]::new($errorMsg)
                }
                default { Write-LogMessage -Type WARNING -Message "Invalid response. Enter Y or N (or press Enter for N)." }
            }
        }
    } catch [VcfDeploymentException] {
        throw
    } catch {
        Write-LogMessage -Type WARNING -Message "Read-Host failed (non-interactive?): $($_.Exception.Message). Treating as N."
        throw [VcfDeploymentException]::new("User confirmation failed (non-interactive mode): $($_.Exception.Message)")
    }

    # When vmk0 is already on a standard switch, the host is ready to move — no VDS cleanup needed.
    if ($vmk0OnStandardSwitch) {
        Write-LogMessage -Type INFO -Message "Host `"$EsxHostName`" ready for cluster move (vmk0 already on standard switch). Proceeding to add to cluster `"$DestinationClusterName`"."
        return
    }

    # vmk0 is on a VDS with dual uplinks — remove non-management VMkernel adapters, restore vmk0
    # to a standard switch, then detach all pNICs from every VDS on the host.
    Invoke-HostVdsCleanupForClusterMove `
        -EsxHostName  $EsxHostName `
        -MgmtVdsName  $dualUplinkCheck.MgmtVdsName `
        -Server       $Server `
        -VMHost       $VMHost

    Write-LogMessage -Type INFO -Message "Host `"$EsxHostName`" VDS cleanup complete. Proceeding to add to cluster `"$DestinationClusterName`"."
}
function Get-RunningVmsOnHost {

    <#
        .SYNOPSIS
        Returns all powered-on VMs on a host. Thin wrapper over Get-VM -Location enabling unit tests to mock this call without fighting PowerCLI type constraints.

        .PARAMETER Server
        vCenter server name or connection object.

        .PARAMETER VMHost
        The VMHost object to filter VMs for.

        .EXAMPLE
        Get-RunningVmsOnHost -VMHost $vmhostObj -Server "vc.lab"
    #>

    [CmdletBinding()]
    [OutputType([Object[]])]
    Param (
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$Server = $Script:vCenterName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$VMHost
    )

    @(Get-VM -Location $VMHost -Server $Server -ErrorAction SilentlyContinue |
        Where-Object { $_.PowerState -eq "PoweredOn" })
}
function Get-NonMgmtVmkernelAdaptersOnHost {

    <#
        .SYNOPSIS
        Returns all non-management VMkernel adapters (vmk1 and above) for a host. Thin wrapper over Get-VMHostNetworkAdapter enabling unit tests to mock this call without fighting PowerCLI type constraints.

        .PARAMETER Server
        vCenter server name or connection object.

        .PARAMETER VMHost
        The VMHost object whose non-management VMkernel adapters are returned.

        .EXAMPLE
        Get-NonMgmtVmkernelAdaptersOnHost -VMHost $vmhostObj -Server "vc.lab"
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$Server = $Script:vCenterName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$VMHost
    )

    Get-VMHostNetworkAdapter -VMHost $VMHost -VMKernel -Server $Server -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne "vmk0" }
}
function Get-PhysicalNicAdapterOnHost {

    <#
        .SYNOPSIS
        Returns the named physical NIC adapter object on a host, or null if not found. Thin wrapper over
        Get-VMHostNetworkAdapter enabling unit tests to mock this call without fighting PowerCLI type constraints.

        .PARAMETER NicName
        Physical network adapter name (e.g. vmnic0).

        .PARAMETER Server
        vCenter server name or connection object.

        .PARAMETER VMHost
        The VMHost object to query.

        .EXAMPLE
        Get-PhysicalNicAdapterOnHost -NicName "vmnic1" -VMHost $vmhostObj -Server "vc.lab"
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$NicName,
        [Parameter(Mandatory = $false)] [String]$Server = $Script:vCenterName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$VMHost
    )

    Get-VMHostNetworkAdapter -VMHost $VMHost -Physical -Name $NicName -Server $Server -ErrorAction SilentlyContinue
}
function Test-HostHasRequiredNics {

    <#
        .SYNOPSIS
        Validates that a host physically has all NICs required by the destination cluster NIC list.

        .DESCRIPTION
        Extracts NIC names from NicList (each entry may be a string or an object with a Name property) and
        checks that each adapter is physically present on the host using Get-PhysicalNicAdapterOnHost.
        Used as a pre-flight guard on the cluster-move path: if any required NIC is absent the host
        cannot support the vSS-to-VDS migration and the takeover is rejected before any disruptive
        changes are made.

        .PARAMETER EsxHostName
        FQDN or IP of the host, used in log messages.

        .PARAMETER NicList
        Array of NIC entries (strings or objects with a Name property) from the effective NIC list for
        the destination cluster.

        .PARAMETER Server
        vCenter server name. Defaults to $Script:vCenterName.

        .PARAMETER VMHost
        The VMHost object for the host to validate.

        .OUTPUTS
        PSCustomObject with:
          IsValid     — $true when all NICs are present; $false when one or more are missing.
          MissingNics — Array of missing NIC names (empty when IsValid is $true).

        .EXAMPLE
        $check = Test-HostHasRequiredNics -EsxHostName "esx01.lab" -NicList $nicList -VMHost $vmhostObj
        if (-not $check.IsValid) { throw [VcfDeploymentException]::new("Missing NICs: $($check.MissingNics -join ', ')") }
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EsxHostName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object[]]$NicList,
        [Parameter(Mandatory = $false)] [String]$Server = $Script:vCenterName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$VMHost
    )

    $missingNics = [System.Collections.Generic.List[String]]::new()
    foreach ($item in $NicList) {
        $nicName = if ($item -is [String]) {
            $item.Trim()
        } elseif ($null -ne $item.PSObject.Properties["Name"]) {
            ([String]$item.Name).Trim()
        } else {
            Write-LogMessage -Type WARNING -Message "Test-HostHasRequiredNics: NicList entry on host `"$EsxHostName`" has no Name property; skipping — verify NicList format."
            continue
        }
        if ([String]::IsNullOrWhiteSpace($nicName)) {
            continue
        }
        $adapter = Get-PhysicalNicAdapterOnHost -NicName $nicName -Server $Server -VMHost $VMHost
        if (-not $adapter) {
            Write-LogMessage -Type DEBUG -Message "Host `"$EsxHostName`": required NIC `"$nicName`" not found on the host."
            $missingNics.Add($nicName)
        }
    }

    return [PSCustomObject]@{
        IsValid     = ($missingNics.Count -eq 0)
        MissingNics = $missingNics.ToArray()
    }
}
function Get-AllVmsFromServer {

    <#
        .SYNOPSIS
        Thin wrapper over Get-VM enabling unit tests to mock this call without fighting
        PowerCLI ArgumentTransformationAttribute constraints on the -Server parameter.

        .PARAMETER Server
        vCenter server name. Defaults to $Script:vCenterName.

        .EXAMPLE
        Get-AllVmsFromServer -Server "vc.lab"
    #>

    [CmdletBinding()]
    [OutputType([PSObject[]])]
    Param (
        [Parameter(Mandatory = $false)] [String]$Server = $Script:vCenterName
    )

    Get-VM -Server $Server -ErrorAction SilentlyContinue
}
function Get-VMHostByName {

    <#
        .SYNOPSIS
        Thin wrapper over Get-VMHost -Name enabling unit tests to mock this call without fighting
        PowerCLI ArgumentTransformationAttribute constraints on the -Server parameter.

        .PARAMETER Name
        ESX host name or FQDN.

        .PARAMETER Server
        vCenter server name. Defaults to $Script:vCenterName.

        .EXAMPLE
        Get-VMHostByName -Name "esx01.lab" -Server "vc.lab"
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Name,
        [Parameter(Mandatory = $false)] [String]$Server = $Script:vCenterName
    )

    Get-VMHost -Name $Name -Server $Server -ErrorAction SilentlyContinue
}
function Set-VMHostState {

    <#
        .SYNOPSIS
        Thin wrapper over Set-VMHost -State enabling unit tests to mock this call without fighting
        PowerCLI ArgumentTransformationAttribute constraints on the -VMHost parameter.

        .PARAMETER Server
        vCenter server name. Defaults to $Script:vCenterName.

        .PARAMETER State
        Connection state to set (Connected, Disconnected, Maintenance).

        .PARAMETER VMHost
        ESX host name or FQDN.

        .EXAMPLE
        Set-VMHostState -VMHost "esx01.lab" -State "Disconnected" -Server "vc.lab"
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [String]$Server = $Script:vCenterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$State,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VMHost
    )

    Set-VMHost -VMHost $VMHost -Server $Server -State $State -Confirm:$false -ErrorAction Stop | Out-Null
}
function Remove-VMHostFromVCenter {

    <#
        .SYNOPSIS
        Thin wrapper over Remove-VMHost enabling unit tests to mock this call without fighting
        PowerCLI ArgumentTransformationAttribute constraints on the -VMHost parameter.

        .PARAMETER Server
        vCenter server name. Defaults to $Script:vCenterName.

        .PARAMETER VMHost
        ESX host name or FQDN.

        .EXAMPLE
        Remove-VMHostFromVCenter -VMHost "esx01.lab" -Server "vc.lab"
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [String]$Server = $Script:vCenterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VMHost
    )

    Remove-VMHost -VMHost $VMHost -Server $Server -Confirm:$false -ErrorAction Stop
}
function Invoke-AddVMHostToCluster {

    <#
        .SYNOPSIS
        Thin wrapper over Add-VMHost enabling unit tests to mock this call without fighting
        PowerCLI ArgumentTransformationAttribute constraints on the -Location parameter.

        .PARAMETER Credential
        Credentials used to authenticate to the ESX host.

        .PARAMETER Location
        Cluster or container object to add the host to.

        .PARAMETER Name
        ESX host name or FQDN.

        .PARAMETER RunAsync
        When set, runs the add operation asynchronously and returns the task object.

        .PARAMETER Server
        vCenter server name. Defaults to $Script:vCenterName.

        .EXAMPLE
        Invoke-AddVMHostToCluster -Name "esx01.lab" -Credential $cred -Location $clusterObj -Server "vc.lab"
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSCredential]$Credential,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$Location,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Name,
        [Parameter(Mandatory = $false)] [Switch]$RunAsync,
        [Parameter(Mandatory = $false)] [String]$Server = $Script:vCenterName
    )

    if ($RunAsync.IsPresent) {
        return Add-VMHost -Name $Name -Credential $Credential -Location $Location -Force -Server $Server -RunAsync -ErrorAction Stop
    }
    Add-VMHost -Name $Name -Credential $Credential -Location $Location -Force -Server $Server -ErrorAction Stop | Out-Null
}
function Invoke-AddHostToClusterRunningVmSafetyCheck {

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
    
        .EXAMPLE
        Invoke-AddHostToClusterRunningVmSafetyCheck -ClusterName "edge-cluster-1" -EsxHostName "resource-name" -VMHost $vmHostObject
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EsxHostName,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$Server = $Script:vCenterName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$VMHost
    )

    $inventoryLocation = "n/a"
    try {
        if ($VMHost.Parent -and $VMHost.Parent.Name) {
            $inventoryLocation = [String]$VMHost.Parent.Name
        }
    } catch {
        $inventoryLocation = "(unknown)"
    }

    $runningVms = @(
        Get-AllVmsFromServer -Server $Server |
            Where-Object { $_.VMHost.Name -eq $VMHost.Name -and "$($_.PowerState)" -eq "PoweredOn" }
    )

    if ($runningVms.Count -eq 0) {
        Write-LogMessage -Type DEBUG -Message "Add-HostToCluster running-VM safety: host `"$EsxHostName`" has no powered-on VMs on vCenter `"$Server`"."
        return
    }

    Write-LogMessage -Type WARNING -Message "Host `"$EsxHostName`" is managed by vCenter `"$Server`" (inventory parent: `"$inventoryLocation`"). Powered-on VM count: $($runningVms.Count)."
    foreach ($vm in ($runningVms | Sort-Object -Property Name)) {
        $guestOs = "n/a"
        try {
            if ($vm.Guest -and $vm.Guest.OSFullName) { $guestOs = [String]$vm.Guest.OSFullName }
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
        $errorMsg = "Deployment aborted. Host `"$EsxHostName`" has $($runningVms.Count) powered-on VM(s) on vCenter `"$Server`". Power off or migrate the VMs, then re-run."
        Write-LogMessage -Type ERROR -Message $errorMsg
        throw [VcfDeploymentException]::new($errorMsg)
    }
}
function Invoke-MoveVMHostToDestination {

    <#
        .SYNOPSIS
        Thin wrapper around Move-VMHost to support mocking in unit tests.

        .DESCRIPTION
        Move-VMHost has an ArgumentTransformationAttribute on its -VMHost parameter that blocks
        direct mocking. This wrapper accepts [PSObject] so tests can mock it with a PSCustomObject,
        following the same pattern as Get-ClusterObjectByName and Get-VsanClusterConfigurationForCluster.

        .PARAMETER Destination
        The target cluster or folder object to move the host into.

        .PARAMETER Server
        vCenter server name.

        .PARAMETER VMHost
        The VMHost object to move.

        .EXAMPLE
        Invoke-MoveVMHostToDestination -VMHost $vmhostObj -Destination $clusterObj -Server "vc.lab"

        .OUTPUTS
        None. Throws [VcfDeploymentException] on failure.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$Destination,
        [Parameter(Mandatory = $false)] [String]$Server = $Script:vCenterName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$VMHost
    )

    Move-VMHost -VMHost $VMHost -Destination $Destination -Server $Server -Confirm:$false -ErrorAction Stop | Out-Null
}
function Wait-AddVMHostTask {

    <#
        .SYNOPSIS
        Polls an async Add-VMHost task until it succeeds, errors, or times out.

        .DESCRIPTION
        Calls Get-Task in a loop until the task reaches Success or Error state, or until
        the deadline is exceeded. Returns a result object indicating success and any error message.

        .PARAMETER AddHostTaskPollIntervalSeconds
        Seconds between Get-Task polls. Default is 5.

        .PARAMETER Deadline
        The DateTime after which the function considers the wait timed out.

        .PARAMETER Server
        vCenter server name used in the Get-Task call.

        .PARAMETER Task
        The task object returned by the async Add-VMHost call.

        .PARAMETER WaitForAddHostTaskTimeoutSeconds
        Original timeout value; used only to build the timeout error message.

        .OUTPUTS
        PSCustomObject with Succeeded ([Bool]) and ErrorMessage ([String]) properties.

        .EXAMPLE
        $result = Wait-AddVMHostTask -Task $task -Deadline $deadline -Server $Script:vCenterName -AddHostTaskPollIntervalSeconds 5 -WaitForAddHostTaskTimeoutSeconds 300
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(1, 60)] [Int]$AddHostTaskPollIntervalSeconds = 5,
        [Parameter(Mandatory = $true)] [DateTime]$Deadline,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Server,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$Task,
        [Parameter(Mandatory = $false)] [ValidateRange(0, 900)] [Int]$WaitForAddHostTaskTimeoutSeconds = 300
    )

    $succeeded = $false
    $errorMessage = $null

    while ((Get-Date) -lt $Deadline) {
        $currentTask = Get-Task -Id $Task.Id -Server $Server -ErrorAction SilentlyContinue
        if ($currentTask) {
            $state = if ($currentTask.PSObject.Properties['State']) { $currentTask.State } else { $currentTask.Status }
            if ($state -eq 'Success') {
                $succeeded = $true
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
                break
            }
        }
        Start-Sleep -Seconds $AddHostTaskPollIntervalSeconds
    }

    if (-not $succeeded -and -not $errorMessage) {
        $errorMessage = "Add host task did not complete within $WaitForAddHostTaskTimeoutSeconds seconds."
    }

    return [PSCustomObject]@{ Succeeded = $succeeded; ErrorMessage = $errorMessage }
}
function Invoke-AddVMHostWithRetry {

    <#
        .SYNOPSIS
        Adds an ESX host to a cluster via Add-VMHost with automatic retry on transient errors.

        .DESCRIPTION
        Calls Invoke-AddVMHostToCluster (with or without -RunAsync based on WaitForAddHostTaskTimeoutSeconds)
        and retries on "already exists", "current state of the object", or task-timeout errors.
        Throws VcfDeploymentException on all non-retryable errors or when all retry attempts are exhausted.
        This helper implements only the Add-VMHost path; use Move-VMHost for hosts already managed by this vCenter.

        .PARAMETER AddHostRetryCount
        Maximum number of Add-VMHost attempts before failing.

        .PARAMETER AddHostRetryDelaySeconds
        Seconds to wait between retry attempts.

        .PARAMETER AddHostTaskPollIntervalSeconds
        Seconds between Get-Task polls when waiting for the async add task.

        .PARAMETER ClusterName
        Destination cluster name; used in exception messages.

        .PARAMETER ClusterObject
        The cluster object (from Get-Cluster) used as the -Location for Add-VMHost.

        .PARAMETER EsxCredential
        Credentials for authenticating with the ESX host.

        .PARAMETER EsxHostName
        FQDN or IP of the ESX host to add.

        .PARAMETER HostAppearanceRecheckDelaySeconds
        Seconds to wait after an "already exists" error before re-querying the cluster inventory.

        .PARAMETER Server
        vCenter server name.

        .PARAMETER WaitForAddHostTaskTimeoutSeconds
        When greater than 0, uses -RunAsync and polls the task for completion. Set to 0 for synchronous Add-VMHost.

        .EXAMPLE
        Invoke-AddVMHostWithRetry -EsxHostName "esx01.example.com" -EsxCredential $credential -ClusterObject $cluster -ClusterName "cl0" -Server $Script:vCenterName

        .NOTES
        This function is intentionally narrow: it does not handle the Move-VMHost (relocation) path or
        post-add verification. Those are handled by the caller (Add-HostToCluster).
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(1, 10)] [Int]$AddHostRetryCount = 3,
        [Parameter(Mandatory = $false)] [ValidateRange(5, 120)] [Int]$AddHostRetryDelaySeconds = 10,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 60)] [Int]$AddHostTaskPollIntervalSeconds = 5,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$ClusterObject,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [PSCredential]$EsxCredential,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EsxHostName,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 60)] [Int]$HostAppearanceRecheckDelaySeconds = 5,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$Server = $Script:vCenterName,
        [Parameter(Mandatory = $false)] [ValidateRange(0, 900)] [Int]$WaitForAddHostTaskTimeoutSeconds = 300
    )

    Write-LogMessage -Type INFO -NoNewline -Message "Adding ESX host `"$EsxHostName`" to cluster `"$ClusterName`"... "
    $addHostSucceeded = $false
    $addHostAttempt = 1

    do {
        $errorMessage = $null
        $task = $null

        if ($WaitForAddHostTaskTimeoutSeconds -gt 0) {
            try {
                $task = Invoke-AddVMHostToCluster -Name $EsxHostName -Credential $EsxCredential -Location $ClusterObject -RunAsync -Server $Server
            } catch [System.UnauthorizedAccessException] {
                $err = "Cannot add host `"$EsxHostName`" to cluster `"$ClusterName`" in vCenter `"$Server`" due to authorization issues: $($_.Exception.Message)"
                Write-LogMessage -Type ERROR -Message $err
                throw [VcfDeploymentException]::new($err)
            } catch [System.TimeoutException] {
                $err = "Cannot add host `"$EsxHostName`" to cluster `"$ClusterName`" in vCenter `"$Server`" due to network/timeout issues: $($_.Exception.Message)"
                Write-LogMessage -Type ERROR -Message $err
                throw [VcfDeploymentException]::new($err)
            } catch [VMware.VimAutomation.ViCore.Types.V1.ErrorHandling.InvalidLogin] {
                $err = "vCenter session was logged out or expired while adding host `"$EsxHostName`". Do not log out the vCenter user session while Add-VMHost or other deployment tasks are in progress. Re-run the deployment to reconnect and retry."
                Write-LogMessage -Type ERROR -Message $err
                throw [VcfDeploymentException]::new($err)
            } catch [VMware.VimAutomation.Sdk.Types.V1.ErrorHandling.VimException.ViServerConnectionException] {
                $err = "vCenter connection was lost while adding host `"$EsxHostName`" (session logged out, vCenter restart, or network issue). Re-run the deployment to reconnect and retry."
                Write-LogMessage -Type ERROR -Message $err
                throw [VcfDeploymentException]::new($err)
            } catch {
                $errorMessage = $_.Exception.Message
            }

            if ($task -and -not $errorMessage) {
                $deadline = (Get-Date).AddSeconds($WaitForAddHostTaskTimeoutSeconds)
                $taskResult = Wait-AddVMHostTask -AddHostTaskPollIntervalSeconds $AddHostTaskPollIntervalSeconds -Deadline $deadline -Server $Server -Task $task -WaitForAddHostTaskTimeoutSeconds $WaitForAddHostTaskTimeoutSeconds
                $addHostSucceeded = $taskResult.Succeeded
                $errorMessage = $taskResult.ErrorMessage
                if (-not $addHostSucceeded) {
                    Write-LogMessage -Type DEBUG -Message "Add-VMHost task did not succeed (attempt $addHostAttempt): $errorMessage"
                }
            }
        } else {
            try {
                Invoke-AddVMHostToCluster -Name $EsxHostName -Credential $EsxCredential -Location $ClusterObject -Server $Server
                $addHostSucceeded = $true
                break
            } catch [System.UnauthorizedAccessException] {
                $err = "Cannot add host `"$EsxHostName`" to cluster `"$ClusterName`" in vCenter `"$Server`" due to authorization issues: $($_.Exception.Message)"
                Write-LogMessage -Type ERROR -Message $err
                throw [VcfDeploymentException]::new($err)
            } catch [System.TimeoutException] {
                $err = "Cannot add host `"$EsxHostName`" to cluster `"$ClusterName`" in vCenter `"$Server`" due to network/timeout issues: $($_.Exception.Message)"
                Write-LogMessage -Type ERROR -Message $err
                throw [VcfDeploymentException]::new($err)
            } catch [VMware.VimAutomation.ViCore.Types.V1.ErrorHandling.InvalidLogin] {
                $err = "vCenter session was logged out or expired while adding host `"$EsxHostName`". Do not log out the vCenter user session while Add-VMHost or other deployment tasks are in progress. Re-run the deployment to reconnect and retry."
                Write-LogMessage -Type ERROR -Message $err
                throw [VcfDeploymentException]::new($err)
            } catch [VMware.VimAutomation.Sdk.Types.V1.ErrorHandling.VimException.ViServerConnectionException] {
                $err = "vCenter connection was lost while adding host `"$EsxHostName`" (session logged out, vCenter restart, or network issue). Re-run the deployment to reconnect and retry."
                Write-LogMessage -Type ERROR -Message $err
                throw [VcfDeploymentException]::new($err)
            } catch {
                $errorMessage = $_.Exception.Message
            }
        }

        if ($addHostSucceeded) { break }
        if (-not $errorMessage) { $errorMessage = "Add host failed (no task or error details)." }

        if ($errorMessage -match "already being managed|already managed by this vSphere server") {
            Write-LogMessage -Type DEBUG -Message "Add-VMHost threw (attempt $addHostAttempt): $errorMessage"
            $hostInVc = Get-VMHost -Name $EsxHostName -Server $Server -ErrorAction SilentlyContinue
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
            $err = "Host `"$EsxHostName`" is already managed by vCenter `"$Server`" (in cluster: `"$otherCluster`"). Remove the host from that cluster in vCenter, or remove it from vCenter, then re-run the deployment."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }

        if ($errorMessage -match "vSAN cluster UUID mismatch|vSAN host cannot be moved to the destination cluster") {
            $err = "Host `"$EsxHostName`" belongs to a different vSAN cluster (vSAN cluster UUID mismatch). Remove the host from the other vSAN cluster in vCenter, or remove it from vCenter, then re-run the deployment. Moving a vSAN host between clusters requires removing it first."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }

        if ($errorMessage -match "already exists|current state of the object|did not complete within") {
            Write-LogMessage -Type DEBUG -Message "Add-VMHost threw (attempt $addHostAttempt): $errorMessage"
            $hostNowInCluster = $ClusterObject | Get-VMHost -Name $EsxHostName -Server $Server -ErrorAction SilentlyContinue
            if ($hostNowInCluster) {
                Write-LogMessage -Type INFO -Message "Host `"$EsxHostName`" is in cluster `"$ClusterName`" (add completed despite error; host may still be connecting). Proceeding."
                $addHostSucceeded = $true
                break
            }
            if ($addHostAttempt -lt $AddHostRetryCount) {
                Write-LogMessage -Type WARNING -Message "Add-VMHost failed (attempt $addHostAttempt of $AddHostRetryCount). Error: $errorMessage. Waiting $HostAppearanceRecheckDelaySeconds seconds to recheck cluster, then retry."
                Start-Sleep -Seconds $HostAppearanceRecheckDelaySeconds
                $hostNowInCluster = $ClusterObject | Get-VMHost -Name $EsxHostName -Server $Server -ErrorAction SilentlyContinue
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
            $err = "Add-VMHost failed after $AddHostRetryCount attempt(s). If the host is in another cluster, remove it from vCenter and re-run. Otherwise check vCenter logs and re-run."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }

        if ($errorMessage -match "session|logged out|expired|InvalidLogin|Authentication failed") {
            $err = "The vCenter session may have been logged out during the operation. Do not log out the vCenter user session while deployment tasks are in progress. Re-run the deployment to reconnect."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }

        $err = "Failed to add host `"$EsxHostName`" to cluster `"$ClusterName`" in vCenter `"$Server`": $errorMessage"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    } while ($addHostAttempt -le $AddHostRetryCount -and -not $addHostSucceeded)
}
function Invoke-HostRelocationPrecheck {

    <#
        .SYNOPSIS
        Checks whether an ESX host is already in vCenter inventory and resolves cross-datacenter move metadata.

        .DESCRIPTION
        Queries vCenter for the host. When found: runs the running-VM safety check; when no running VMs exist,
        looks up the source cluster, validates the destination NIC list, calls Invoke-PrepareHostForClusterMove,
        and detects whether the source and destination datacenters differ. Returns a PSCustomObject with the
        resolved HostForRunningVmCheck, IsCrossDatacenterMove, SourceDatacenterName, and DestDatacenterName.

        .PARAMETER ClusterName
        Destination cluster name; used to compare against the host's current parent cluster.

        .PARAMETER ClusterObject
        Cluster object for the destination cluster; passed to Get-DatacenterForCluster.

        .PARAMETER EsxHostName
        FQDN or IP of the ESX host.

        .PARAMETER NicList
        Required NICs for the destination cluster. When non-empty and the host is being taken from another
        cluster, each NIC must be present on the host or the function throws VcfDeploymentException.

        .PARAMETER Server
        vCenter server name.

        .EXAMPLE
        $precheck = Invoke-HostRelocationPrecheck -ClusterName "dest-cl" -ClusterObject $clObj -EsxHostName "esx01.lab" -Server $Script:vCenterName

        .NOTES
        Called exclusively by Add-HostToCluster before any disruptive vCenter operations.
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$ClusterObject,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EsxHostName,
        [Parameter(Mandatory = $false)] [AllowNull()] [Object[]]$NicList = $null,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Server
    )

    $isCrossDatacenterMove = $false
    $sourceDatacenterName = ""
    $destDatacenterName = ""
    $hostForRunningVmCheck = Get-VMHostByName -Name $EsxHostName -Server $Server
    if ($hostForRunningVmCheck) {
        $runningVms = Get-RunningVmsOnHost -VMHost $hostForRunningVmCheck -Server $Server
        if ($runningVms.Count -gt 0) {
            Invoke-AddHostToClusterRunningVmSafetyCheck -ClusterName $ClusterName -EsxHostName $EsxHostName -Server $Server -VMHost $hostForRunningVmCheck
        } else {
            $sourceCluster = $null
            try {
                if ($hostForRunningVmCheck.Parent -and $hostForRunningVmCheck.Parent.Name) {
                    $sourceCluster = Get-ClusterObjectByName -ClusterName $hostForRunningVmCheck.Parent.Name -Server $Server
                }
            } catch {
                $sourceCluster = $null
            }
            if ($null -ne $sourceCluster -and $sourceCluster.Name -ne $ClusterName) {
                # Validate that the host has every physical NIC required by the destination cluster's NIC list
                # before taking any disruptive action. A host missing one or more required NICs cannot support
                # the vSS-to-VDS migration and must not be taken over.
                if ($null -ne $NicList -and $NicList.Count -gt 0) {
                    $nicCheck = Test-HostHasRequiredNics -EsxHostName $EsxHostName -NicList $NicList -Server $Server -VMHost $hostForRunningVmCheck
                    if (-not $nicCheck.IsValid) {
                        $missingStr = $nicCheck.MissingNics -join ", "
                        $err = "Host `"$EsxHostName`" is missing required physical NIC(s) [$missingStr] from the configured NIC list. The vSS-to-VDS migration cannot proceed without these NICs. Remove this host from the deployment configuration or install the required NIC hardware and re-run."
                        Write-LogMessage -Type ERROR -Message $err
                        throw [VcfDeploymentException]::new($err)
                    }
                }
                Invoke-PrepareHostForClusterMove -DestinationClusterName $ClusterName -EsxHostName $EsxHostName -Server $Server -SourceClusterName $sourceCluster.Name -VMHost $hostForRunningVmCheck
                try {
                    $srcDc = Get-DatacenterForVMHost -VMHost $hostForRunningVmCheck -Server $Server
                    $dstDc = Get-DatacenterForCluster -Cluster $ClusterObject -Server $Server
                    if ($null -ne $srcDc -and $null -ne $dstDc -and $srcDc.Id -ne $dstDc.Id) {
                        $isCrossDatacenterMove = $true
                        $sourceDatacenterName = $srcDc.Name
                        $destDatacenterName = $dstDc.Name
                        Write-LogMessage -Type INFO -Message "Host `"$EsxHostName`" is in datacenter `"$sourceDatacenterName`" but destination cluster `"$ClusterName`" is in datacenter `"$destDatacenterName`". Move-VMHost cannot cross datacenter boundaries; will disconnect, remove from source inventory, and re-add to destination cluster."
                    }
                } catch {
                    Write-LogMessage -Type DEBUG -Message "Datacenter lookup for host `"$EsxHostName`" or cluster `"$ClusterName`" failed: $($_.Exception.Message). Assuming same datacenter."
                }
            } else {
                $parentDisplayName = if ($hostForRunningVmCheck.Parent -and $hostForRunningVmCheck.Parent.Name) { $hostForRunningVmCheck.Parent.Name } else { "(no cluster parent)" }
                Write-LogMessage -Type DEBUG -Message "Add-HostToCluster: host `"$EsxHostName`" is in vCenter inventory with no powered-on VMs and no cluster move required (parent: `"$parentDisplayName`"). Proceeding to add."
            }
        }
    } else {
        Write-LogMessage -Type DEBUG -Message "Add-HostToCluster: host `"$EsxHostName`" not in vCenter inventory before add; skipping powered-on VM check (VMs are not enumerable until the host is managed by this vCenter)."
    }

    return [PSCustomObject]@{
        HostForRunningVmCheck = $hostForRunningVmCheck
        IsCrossDatacenterMove = $isCrossDatacenterMove
        SourceDatacenterName  = $sourceDatacenterName
        DestDatacenterName    = $destDatacenterName
    }
}
function Invoke-ManagedHostMoveOrAdd {

    <#
        .SYNOPSIS
        Moves a managed host to the destination cluster or adds an unmanaged host via Add-VMHost.

        .DESCRIPTION
        When HostForRunningVmCheck is non-null (host is already in vCenter inventory):
          - Ensures the host is in maintenance mode before relocation.
          - Cross-datacenter: disconnects and removes from source inventory so Add-VMHost can re-add it.
          - Same-datacenter: calls Invoke-MoveVMHostToDestination and returns; the Add-VMHost path is skipped.
        When HostForRunningVmCheck is null (new host, or cross-DC after remove): delegates to Invoke-AddVMHostWithRetry.
        Manages ProgressPreference suppression internally via try/finally.

        .PARAMETER AddHostRetryCount
        Number of Add-VMHost retries on transient errors.

        .PARAMETER AddHostRetryDelaySeconds
        Seconds between Add-VMHost retry attempts.

        .PARAMETER AddHostTaskPollIntervalSeconds
        Poll interval for async Add-VMHost task completion.

        .PARAMETER ClusterName
        Destination cluster name; used in log messages and passed to Invoke-AddVMHostWithRetry.

        .PARAMETER ClusterObject
        Destination cluster object; used as the Move-VMHost destination and Add-VMHost location.

        .PARAMETER EsxCredential
        Credentials for authenticating with the ESX host via Add-VMHost.

        .PARAMETER EsxHostName
        FQDN or IP of the ESX host.

        .PARAMETER HostAppearanceRecheckDelaySeconds
        Seconds to wait before rechecking cluster after an Add-VMHost "already exists" error.

        .PARAMETER HostForRunningVmCheck
        Host object returned from a prior Get-VMHostByName call; null means the host is not yet managed by this vCenter.

        .PARAMETER IsCrossDatacenterMove
        When true, the host must be disconnected and removed before re-adding to the destination datacenter.

        .PARAMETER Server
        vCenter server name.

        .PARAMETER SourceDatacenterName
        Name of the source datacenter; used in log messages during cross-datacenter disconnect.

        .PARAMETER WaitForAddHostTaskTimeoutSeconds
        Timeout for the async Add-VMHost task; 0 uses synchronous Add-VMHost.

        .EXAMPLE
        Invoke-ManagedHostMoveOrAdd -ClusterName "dest-cl" -ClusterObject $clObj -EsxCredential $cred -EsxHostName "esx01.lab" -HostForRunningVmCheck $hostObj -IsCrossDatacenterMove:$false -Server $Script:vCenterName

        .NOTES
        Called exclusively by Add-HostToCluster after Invoke-HostRelocationPrecheck.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(1, 10)] [Int]$AddHostRetryCount = 3,
        [Parameter(Mandatory = $false)] [ValidateRange(5, 120)] [Int]$AddHostRetryDelaySeconds = 10,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 60)] [Int]$AddHostTaskPollIntervalSeconds = 5,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$ClusterObject,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [PSCredential]$EsxCredential,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EsxHostName,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 60)] [Int]$HostAppearanceRecheckDelaySeconds = 5,
        [Parameter(Mandatory = $false)] [AllowNull()] [PSObject]$HostForRunningVmCheck = $null,
        [Parameter(Mandatory = $false)] [Switch]$IsCrossDatacenterMove,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$Server = $Script:vCenterName,
        [Parameter(Mandatory = $false)] [String]$SourceDatacenterName = "",
        [Parameter(Mandatory = $false)] [ValidateRange(0, 900)] [Int]$WaitForAddHostTaskTimeoutSeconds = 300
    )

    $savedProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        if ($null -ne $HostForRunningVmCheck) {
            # vSphere requires the host to be in maintenance mode before an inter-cluster relocation.
            if ($HostForRunningVmCheck.ConnectionState -ne "Maintenance") {
                Write-LogMessage -Type INFO -NoNewline -Message "Entering maintenance mode on host `"$EsxHostName`" before cluster move... "
                try {
                    Set-VMHostState -VMHost $EsxHostName -State "Maintenance" -Server $Server
                    $hostStateRefresh = Get-VMHostByName -Name $EsxHostName -Server $Server
                    if ($null -eq $hostStateRefresh -or $hostStateRefresh.ConnectionState -ne "Maintenance") {
                        $actualState = if ($hostStateRefresh) { $hostStateRefresh.ConnectionState } else { "not found in vCenter" }
                        Write-LogMessage -Type ERROR -CompletePending -Message "Failed."
                        $err = "Host `"$EsxHostName`" state is `"$actualState`" after maintenance mode request (expected: Maintenance). Place the host in maintenance mode manually in vCenter and re-run the deployment."
                        Write-LogMessage -Type ERROR -Message $err
                        throw [VcfDeploymentException]::new($err)
                    }
                    Write-LogMessage -Type INFO -CompletePending -Message "Done."
                } catch [VcfDeploymentException] {
                    throw
                } catch {
                    Write-LogMessage -Type ERROR -CompletePending -Message "Failed."
                    $err = "Failed to enter maintenance mode on host `"$EsxHostName`" before cluster move: $($_.Exception.Message). To recover: place `"$EsxHostName`" in maintenance mode manually in vCenter and re-run the deployment."
                    Write-LogMessage -Type ERROR -Message $err
                    throw [VcfDeploymentException]::new($err)
                }
            } else {
                Write-LogMessage -Type DEBUG -Message "Host `"$EsxHostName`" is already in maintenance mode; skipping maintenance mode entry before cluster move."
            }
            if ($IsCrossDatacenterMove) {
                # Move-VMHost cannot relocate a host between virtual datacenters. Disconnect and
                # remove from the source datacenter's inventory, then re-add via Add-VMHost below.
                Write-LogMessage -Type INFO -NoNewline -Message "Disconnecting host `"$EsxHostName`" from source datacenter `"$SourceDatacenterName`"... "
                try {
                    Set-VMHostState -VMHost $EsxHostName -State "Disconnected" -Server $Server
                    Write-LogMessage -Type INFO -CompletePending -Message "Done."
                } catch {
                    Write-LogMessage -Type ERROR -CompletePending -Message "Failed."
                    $err = "Failed to disconnect host `"$EsxHostName`" before cross-datacenter re-add: $($_.Exception.Message)"
                    Write-LogMessage -Type ERROR -Message $err
                    throw [VcfDeploymentException]::new($err)
                }
                Write-LogMessage -Type INFO -NoNewline -Message "Removing host `"$EsxHostName`" from source vCenter inventory (cross-datacenter re-add)... "
                try {
                    Remove-VMHostFromVCenter -VMHost $EsxHostName -Server $Server
                    Write-LogMessage -Type INFO -CompletePending -Message "Done."
                } catch {
                    Write-LogMessage -Type ERROR -CompletePending -Message "Failed."
                    $err = "Failed to remove host `"$EsxHostName`" from source vCenter inventory: $($_.Exception.Message)"
                    Write-LogMessage -Type ERROR -Message $err
                    throw [VcfDeploymentException]::new($err)
                }
            } else {
                Write-LogMessage -Type INFO -NoNewline -Message "Moving ESX host `"$EsxHostName`" to cluster `"$ClusterName`"... "
                try {
                    Invoke-MoveVMHostToDestination -VMHost $HostForRunningVmCheck -Destination $ClusterObject -Server $Server
                    Write-LogMessage -Type INFO -CompletePending -Message "Done."
                } catch [VcfDeploymentException] {
                    throw
                } catch {
                    Write-LogMessage -Type ERROR -CompletePending -Message "Failed."
                    $err = "Failed to move host `"$EsxHostName`" to cluster `"$ClusterName`" in vCenter `"$Server`": $($_.Exception.Message)"
                    Write-LogMessage -Type ERROR -Message $err
                    throw [VcfDeploymentException]::new($err)
                }
                return  # Same-datacenter Move-VMHost path complete; skip Add-VMHost.
            }
        }
        # Host is new or cross-datacenter path after remove; use Add-VMHost.
        Invoke-AddVMHostWithRetry `
            -AddHostRetryCount $AddHostRetryCount `
            -AddHostRetryDelaySeconds $AddHostRetryDelaySeconds `
            -AddHostTaskPollIntervalSeconds $AddHostTaskPollIntervalSeconds `
            -ClusterName $ClusterName `
            -ClusterObject $ClusterObject `
            -EsxCredential $EsxCredential `
            -EsxHostName $EsxHostName `
            -HostAppearanceRecheckDelaySeconds $HostAppearanceRecheckDelaySeconds `
            -Server $Server `
            -WaitForAddHostTaskTimeoutSeconds $WaitForAddHostTaskTimeoutSeconds
    } finally {
        $ProgressPreference = $savedProgress
    }
}
function Confirm-VMHostAddedToCluster {

    <#
        .SYNOPSIS
        Verifies that an ESX host was successfully added or moved to the destination cluster and sets it to Connected.

        .DESCRIPTION
        Optionally waits for the Add-VMHost async operation to settle (IsAddPath = true), verifies the vCenter
        connection, queries the host in inventory, confirms it is in the correct cluster, and sets its
        ConnectionState to Connected when needed.

        .PARAMETER ClusterName
        Destination cluster name; verified against the host's Parent.Name after the add/move.

        .PARAMETER EsxHostName
        FQDN or IP of the ESX host to verify.

        .PARAMETER HostStateChangeDelaySeconds
        Seconds to sleep before querying the host when IsAddPath is true (async Add-VMHost settling period).

        .PARAMETER IsAddPath
        When true, the host was added via Add-VMHost (async) and a settling delay is applied before verification.

        .PARAMETER Server
        vCenter server name used for all queries.

        .EXAMPLE
        Confirm-VMHostAddedToCluster -ClusterName "dest-cl" -EsxHostName "esx01.lab" -IsAddPath -Server $Script:vCenterName

        .NOTES
        Called exclusively by Add-HostToCluster after Invoke-ManagedHostMoveOrAdd completes.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EsxHostName,
        [Parameter(Mandatory = $false)] [ValidateRange(0, [Int]::MaxValue)] [Int]$HostStateChangeDelaySeconds = 10,
        [Parameter(Mandatory = $false)] [Switch]$IsAddPath,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$Server = $Script:vCenterName
    )

    # Add-VMHost is async; allow state to settle before querying.
    if ($IsAddPath) {
        Start-Sleep $HostStateChangeDelaySeconds
    }
    $connectionAfterAdd = Test-VcenterConnection
    if (-not $connectionAfterAdd.IsConnected) {
        $err = "vCenter session is no longer valid after host add/move (session may have been logged out while the task was in progress): $($connectionAfterAdd.ErrorMessage). Re-run the deployment to reconnect and verify the host was added."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
    try {
        $verifyHost = Get-VMHostByName -Name $EsxHostName -Server $Server
        if (-not $verifyHost) {
            throw [VcfDeploymentException]::new("Host `"$EsxHostName`" was not found in vCenter `"$Server`" after the add/move operation. Re-run the deployment to verify the operation succeeded.")
        }
    } catch [VMware.VimAutomation.ViCore.Types.V1.ErrorHandling.InvalidLogin] {
        $err = "vCenter session was logged out or expired. Re-run the deployment to reconnect and verify host `"$EsxHostName`" was added."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    } catch [VMware.VimAutomation.Sdk.Types.V1.ErrorHandling.VimException.ViServerConnectionException] {
        $err = "vCenter connection was lost. Re-run the deployment to reconnect and verify host `"$EsxHostName`" was added."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    } catch [VcfDeploymentException] {
        throw  # already logged and typed — propagate without re-wrapping
    } catch {
        $err = "Failed to verify host `"$EsxHostName`" in vCenter `"$Server`": $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }

    if ($verifyHost.Parent.Name -ne $ClusterName) {
        $err = "Failed to add `"$EsxHostName`" to cluster `"$ClusterName`" in vCenter `"$Server`". Host is in cluster: `"$($verifyHost.Parent.Name)`""
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }

    # vSAN/vSAN witness VMkernel traffic is ensured after Set-VirtualDistributedSwitch (once mgmt vmk0 is on VDS). See post-VDS step in main deployment.

    # Set host to Connected: for the Move path this exits maintenance mode; for the Add path this handles
    # a newly added host coming up Disconnected.
    if ($verifyHost.ConnectionState -ne "Connected") {
        Write-LogMessage -Type INFO -NoNewline -Message "Setting host `"$EsxHostName`" to connected state (current state: `"$($verifyHost.ConnectionState)`")... "
        try {
            Set-VMHostState -VMHost $EsxHostName -State "Connected" -Server $Server
            Write-LogMessage -Type INFO -CompletePending -Message "Set"
        } catch [System.UnauthorizedAccessException] {
            Write-LogMessage -Type ERROR -CompletePending -Message " Failed."
            throw [VcfDeploymentException]::new("Failed to set host `"$EsxHostName`" to Connected state (authorization): $($_.Exception.Message)")
        } catch [System.TimeoutException] {
            Write-LogMessage -Type ERROR -CompletePending -Message " Failed."
            throw [VcfDeploymentException]::new("Failed to set host `"$EsxHostName`" to Connected state (timeout).")
        } catch [VMware.VimAutomation.ViCore.Types.V1.ErrorHandling.InvalidLogin] {
            Write-LogMessage -Type ERROR -CompletePending -Message " Failed."
            throw [VcfDeploymentException]::new("Failed to set host `"$EsxHostName`" to Connected state (authentication error): $($_.Exception.Message)")
        } catch [VMware.VimAutomation.Sdk.Types.V1.ErrorHandling.VimException.ViServerConnectionException] {
            Write-LogMessage -Type ERROR -CompletePending -Message " Failed."
            throw [VcfDeploymentException]::new("Failed to set host `"$EsxHostName`" to Connected state (server connection error): $($_.Exception.Message)")
        } catch {
            Write-LogMessage -Type ERROR -CompletePending -Message " Failed."
            throw [VcfDeploymentException]::new("Failed to set host `"$EsxHostName`" to Connected state: $($_.Exception.Message)")
        }
    }
}
function Add-HostToCluster {

    <#
        .SYNOPSIS
        Adds an ESX host to an existing vSphere cluster and verifies successful integration.

        .DESCRIPTION
        This function adds or moves an ESX host into a specified vSphere cluster.
        It performs the following operations:
        1. Retrieves the target cluster object from vCenter
        2. If the host is already in vCenter inventory, checks for powered-on VMs; if any exist, logs them and prompts Y/N (default N) before continuing
        3a. If the host is already in vCenter inventory (different cluster): validates required physical NICs; detects whether source and destination clusters are in different virtual datacenters — if so, disconnects the host, removes it from the source inventory, and re-adds it via Add-VMHost (Move-VMHost cannot cross datacenter boundaries); otherwise uses Move-VMHost to relocate it within the same datacenter
        3b. If the host is not yet in vCenter inventory: uses Add-VMHost with the provided credentials
        4. Verifies that the host is in the correct cluster after the operation
        5. Provides appropriate logging for success or failure scenarios

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

        .PARAMETER NicList
        Effective NIC list for the destination cluster (cluster-level or common). When the host is being
        moved from another cluster, each NIC in this list must be physically present on the host or the
        takeover is rejected before any disruptive changes are made. Optional; when omitted, the NIC
        presence check is skipped.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(1, 10)] [Int]$AddHostRetryCount = 3,
        [Parameter(Mandatory = $false)] [ValidateRange(5, 120)] [Int]$AddHostRetryDelaySeconds = 10,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 60)] [Int]$AddHostTaskPollIntervalSeconds = 5,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [PSCredential]$EsxCredential,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EsxHostName,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 60)] [Int]$HostAppearanceRecheckDelaySeconds = 5,
        [Parameter(Mandatory = $false)] [ValidateRange(0, [Int]::MaxValue)] [Int]$HostStateChangeDelaySeconds = 10,
        [Parameter(Mandatory = $false)] [AllowNull()] [Object[]]$NicList = $null,
        [Parameter(Mandatory = $false)] [ValidateSet("VMFS", "vSAN-ESA", "vSAN-OSA")] [String]$StoragePolicyType = "VMFS",
        [Parameter(Mandatory = $false)] [ValidateRange(0, 900)] [Int]$WaitForAddHostTaskTimeoutSeconds = 300
    )

    Write-LogMessage -Type DEBUG -Message "Entered Add-HostToCluster function..."

    Assert-VcenterConnected

    $isAddPath = $false
    try {
        try {
            $clusterObject = Get-ClusterObjectByName -ClusterName $ClusterName -Server $Script:vCenterName
        } catch [System.UnauthorizedAccessException] {
            $err = "Cannot perform Get-Cluster operation for cluster `"$ClusterName`" on vCenter `"$Script:vCenterName`" due to authorization issues: $($_.Exception.Message)"
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        } catch [System.TimeoutException] {
            $err = "Cannot perform Get-Cluster operation for cluster `"$ClusterName`" on vCenter `"$Script:vCenterName`" due to network/timeout issues: $($_.Exception.Message)"
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        } catch [VMware.VimAutomation.ViCore.Types.V1.ErrorHandling.InvalidLogin] {
            $err = "vCenter session was logged out or expired. Do not log out the vCenter user session during deployment. Re-run the deployment to reconnect."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        } catch [VMware.VimAutomation.Sdk.Types.V1.ErrorHandling.VimException.ViServerConnectionException] {
            $err = "vCenter connection was lost (session logged out, vCenter restart, or network). Re-run the deployment to reconnect."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        } catch [VcfDeploymentException] {
            throw  # already logged and typed — propagate without re-wrapping
        } catch {
            $err = "Failed to perform Get-Cluster operation for cluster `"$ClusterName`" on vCenter `"$Script:vCenterName`": $($_.Exception.Message)"
            Write-LogMessage -Type ERROR -AppendNewLine -Message $err
            throw [VcfDeploymentException]::new($err)
        }

        try {
            $existingHost = Get-VMHost -Name $EsxHostName -Location $clusterObject -Server $Script:vCenterName -ErrorAction SilentlyContinue
        } catch {
            $existingHost = $null
        }
        if ($existingHost) {
            Write-LogMessage -Type INFO -Message "Host `"$EsxHostName`" is already in cluster `"$ClusterName`". Skipping host add."
            return
        }

        $precheckResult = Invoke-HostRelocationPrecheck -ClusterName $ClusterName -ClusterObject $clusterObject `
            -EsxHostName $EsxHostName -NicList $NicList -Server $Script:vCenterName
        $isAddPath = (-not $precheckResult.HostForRunningVmCheck) -or $precheckResult.IsCrossDatacenterMove

        Invoke-ManagedHostMoveOrAdd `
            -AddHostRetryCount $AddHostRetryCount `
            -AddHostRetryDelaySeconds $AddHostRetryDelaySeconds `
            -AddHostTaskPollIntervalSeconds $AddHostTaskPollIntervalSeconds `
            -ClusterName $ClusterName -ClusterObject $clusterObject `
            -EsxCredential $EsxCredential -EsxHostName $EsxHostName `
            -HostAppearanceRecheckDelaySeconds $HostAppearanceRecheckDelaySeconds `
            -HostForRunningVmCheck $precheckResult.HostForRunningVmCheck `
            -IsCrossDatacenterMove:$precheckResult.IsCrossDatacenterMove `
            -Server $Script:vCenterName -SourceDatacenterName $precheckResult.SourceDatacenterName `
            -WaitForAddHostTaskTimeoutSeconds $WaitForAddHostTaskTimeoutSeconds

        Confirm-VMHostAddedToCluster -ClusterName $ClusterName -EsxHostName $EsxHostName `
            -HostStateChangeDelaySeconds $HostStateChangeDelaySeconds -IsAddPath:$isAddPath `
            -Server $Script:vCenterName

        if ($isAddPath) {
            Write-LogMessage -Type INFO -CompletePending -Message "Success"
        }
    } catch {
        if ($isAddPath) {
            Write-LogMessage -Type ERROR -CompletePending -Message " Failed."
        }
        if ($StoragePolicyType -eq "vSAN-ESA" -or $StoragePolicyType -eq "vSAN-OSA") {
            Write-LogMessage -Type INFO -Message "vSAN witness traffic or host add failed for cluster `"$ClusterName`". You will be prompted whether to roll back (same sequence as cleanup: VMkernel removal, management restore, vSAN disk/leave/tags, VDS removal, cluster removal)."
        }
        throw
    }
}
function Get-ClusterId {

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

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName
    )

    Write-LogMessage -Type DEBUG -Message "Entered Get-ClusterId function..."

    Assert-VcenterConnected

    try {
        $clusterObject = Get-Cluster -Name $ClusterName -Server $Script:vCenterName -ErrorAction Stop

        # Extract the MoRef ID (e.g., "domain-c2045") from ExtensionData
        # VCF PowerCLI 9 API expects just the MoRef value, not the full type-prefixed ID.

        $clusterId = $clusterObject.ExtensionData.MoRef.Value

        return $clusterId

    } catch [System.UnauthorizedAccessException] {
        $err = "Cannot get cluster id for `"$ClusterName`" on `"$Script:vCenterName`" due to authorization issues: $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
    catch [System.TimeoutException] {
        $err = "Cannot get cluster id for `"$ClusterName`" on `"$Script:vCenterName`" due to network/timeout issues: $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    } catch [VcfDeploymentException] {
        throw  # already logged and typed — propagate without re-wrapping
    } catch {
        $err = "Failed to get cluster id for `"$ClusterName`" on `"$Script:vCenterName`": $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
}
function Get-VcenterSupervisorCount {

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
    [OutputType([Int])]
    Param (
        [Parameter(Mandatory = $false)] [Switch]$IncludeDetails
    )

    Write-LogMessage -Type DEBUG -Message "Entered Get-VcenterSupervisorCount function..."

    $connectionTest = Test-VcenterConnection
    if (-not $connectionTest.IsConnected) {
        $err = "Not connected to vCenter `"$Script:vCenterName`": $($connectionTest.ErrorMessage)"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }

    try {
        $softwareClusters = Invoke-ListNamespaceManagementSoftwareClusters -ErrorAction Stop
        $count = if ($null -eq $softwareClusters) { 0 } else { @($softwareClusters).Count }

        $result = [PSCustomObject]@{ Count = $count }

        if ($IncludeDetails -and $count -gt 0) {
            $clusterIds = @($softwareClusters | Select-Object -ExpandProperty Cluster)
            $clusterNames = [System.Collections.Generic.List[String]]::new()
            foreach ($clusterId in $clusterIds) {
                $clusterObj = Get-Cluster -Server $Script:vCenterName -ErrorAction SilentlyContinue | Where-Object { $_.ExtensionData.MoRef.Value -eq $clusterId } | Select-Object -First 1
                $name = if ($clusterObj) { $clusterObj.Name } else { $clusterId }
                $clusterNames.Add($name)
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
        $err = "Failed to list supervisors in vCenter `"$Script:vCenterName`": $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
}
function Get-ClusterNameFromPrefix {

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

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterNamePrefix,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EdgeSite
    )

    return "$ClusterNamePrefix-$EdgeSite"
}
function Get-DatastoreNameFromPrefix {

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

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DatastoreNamePrefix,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EdgeSite
    )

    return "$DatastoreNamePrefix-$EdgeSite"
}
function Get-VdsNameFromPrefix {

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

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EdgeSite,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VdsNamePrefix
    )

    return "$VdsNamePrefix-$EdgeSite"
}
function Get-SupervisorNameFromPrefix {

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

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EdgeSite,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorNamePrefix
    )

    return "$SupervisorNamePrefix-$EdgeSite"
}
function Get-PortGroupId {

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

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$PortGroupName
    )
    Write-LogMessage -Type DEBUG -Message "Entered Get-PortGroupId function..."

    Assert-VcenterConnected

    try {

        $pgObject = Get-VDPortgroup -Name $PortGroupName -Server $Script:vCenterName -WarningAction SilentlyContinue -ErrorAction Stop
        $pgId = $pgObject.ExtensionData.Key
        return $pgId

    } catch [System.UnauthorizedAccessException] {
        $err = "Cannot get port group id for `"$PortGroupName`" on `"$Script:vCenterName`" due to authorization issues: $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
    catch [System.TimeoutException] {
        $err = "Cannot get port group id for `"$PortGroupName`" on `"$Script:vCenterName`" due to network/timeout issues: $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    } catch [VcfDeploymentException] {
        throw  # already logged and typed — propagate without re-wrapping
    } catch {
        $err = "Failed to get port group id for `"$PortGroupName`" on `"$Script:vCenterName`": $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
}
function Invoke-DatastoreCreationAndWait {

    <#
        .SYNOPSIS
        Creates a VMFS datastore on an ESX host and waits for it to reach Available state.

        .DESCRIPTION
        Calls New-Datastore, then polls until the datastore state is Available or the wait
        timeout expires. Throws VcfDeploymentException on creation failure, auth error,
        timeout, or any other error.

        .PARAMETER CheckInterval
        Seconds between availability polls. Default is 5.

        .PARAMETER DatastoreName
        Name of the datastore to create.

        .PARAMETER DiskCanonicalName
        Canonical name of the disk device (e.g. "naa:xxxxx").

        .PARAMETER EsxHost
        FQDN or name of the ESX host on which to create the datastore.

        .PARAMETER TotalWaitTime
        Maximum seconds to wait for Available state. Default is 120.

        .EXAMPLE
        Invoke-DatastoreCreationAndWait -DatastoreName "ds0" -DiskCanonicalName "naa:abc" -EsxHost "esx01.example.com" -CheckInterval 5 -TotalWaitTime 120
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(1, [Int]::MaxValue)] [Int]$CheckInterval = 5,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DatastoreName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DiskCanonicalName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EsxHost,
        [Parameter(Mandatory = $false)] [ValidateRange(1, [Int]::MaxValue)] [Int]$TotalWaitTime = 120
    )

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

        Write-Progress -Activity "Waiting for Datastore to become Available" -Status "Complete" -Completed

        if (-not $datastoreReady) {
            Write-LogMessage -Type ERROR -CompletePending -Message " Failed (timeout)."
            throw [VcfDeploymentException]::new("Datastore `"$DatastoreName`" did not reach a ready state within the timeout period.")
        }
        Write-LogMessage -Type INFO -CompletePending -Message " Success"
    } catch [System.UnauthorizedAccessException] {
        Write-LogMessage -Type ERROR -CompletePending -Message " Failed (authorization)."
        throw [VcfDeploymentException]::new("Datastore wait failed for `"$DatastoreName`" (authorization): $($_.Exception.Message)")
    } catch [System.TimeoutException] {
        Write-LogMessage -Type ERROR -CompletePending -Message " Failed (timeout)."
        throw [VcfDeploymentException]::new("Datastore `"$DatastoreName`" on `"$Script:vCenterName`" timed out.")
    } catch [VcfDeploymentException] {
        throw  # already logged and typed — propagate without re-wrapping
    } catch {
        Write-LogMessage -Type ERROR -CompletePending -Message " Failed."
        throw [VcfDeploymentException]::new("Datastore wait failed for `"$DatastoreName`": $($_.Exception.Message)")
    }
}
function Invoke-DatastoreTagAssignment {

    <#
        .SYNOPSIS
        Assigns a tag to a datastore, with cardinality-violation guidance on error.

        .DESCRIPTION
        Retrieves the named datastore from vCenter, checks whether the tag is already
        assigned, and assigns it if not. Throws VcfDeploymentException on any error,
        including cardinality violations (with actionable guidance logged).

        .PARAMETER DatastoreAlreadyExisted
        When $true the "already existed" variant of the success message is logged.

        .PARAMETER DatastoreName
        Name of the datastore to tag.

        .PARAMETER TagName
        Tag to assign to the datastore.

        .EXAMPLE
        Invoke-DatastoreTagAssignment -DatastoreAlreadyExisted $false -DatastoreName "ds0" -TagName "supervisor-OSA"
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [Bool]$DatastoreAlreadyExisted,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DatastoreName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$TagName
    )

    try {
        $datastoreObject = Get-Datastore -Name $DatastoreName -Server $Script:vCenterName -ErrorAction SilentlyContinue
    } catch [VcfDeploymentException] {
        throw  # already logged and typed — propagate without re-wrapping
    } catch {
        $err = "Failed to get datastore `"$DatastoreName`" on vCenter `"$Script:vCenterName`": $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
    try {
        $existingTagAssignment = Get-TagAssignment -Entity $datastoreObject -Server $Script:vCenterName -ErrorAction SilentlyContinue | Where-Object { $_.Tag.Name -eq $TagName }
        if ($existingTagAssignment) {
            Write-LogMessage -Type INFO -Message "Datastore `"$DatastoreName`" already has tag `"$TagName`" assigned. Skipping tag assignment."
        } else {
            New-TagAssignment -Tag $TagName -Entity $datastoreObject -Server $Script:vCenterName -ErrorAction Stop | Out-Null
            if ($DatastoreAlreadyExisted) {
                Write-LogMessage -Type INFO -Message "Successfully tagged existing datastore `"$DatastoreName`" with tag `"$TagName`"."
            } else {
                Write-LogMessage -Type INFO -Message "Successfully tagged datastore `"$DatastoreName`" with tag `"$TagName`"."
            }
        }
    } catch {
        $errorMessage = $_.Exception.Message
        if ($errorMessage -match "cardinality violation") {
            Write-LogMessage -Type ERROR -Message "Cannot assign tag `"$TagName`" to datastore `"$DatastoreName`" due to a cardinality violation."
            Write-LogMessage -Type ERROR -Message "This error occurs when:"
            Write-LogMessage -Type ERROR -Message "  - The tag has a `"single`" cardinality and is already assigned to another datastore"
            Write-LogMessage -Type ERROR -Message "  - The tag has a `"many`" cardinality but has reached its maximum assignment limit"
            Write-LogMessage -Type INFO -Message ""
            Write-LogMessage -Type ERROR -Message "SOLUTION:"
            Write-LogMessage -Type ERROR -Message "  1. Check the tag category cardinality in vCenter: Menu > Tags & Custom Attributes > Tags"
            Write-LogMessage -Type ERROR -Message "  2. If the tag is `"single`" cardinality, remove it from the other datastore first"
            Write-LogMessage -Type ERROR -Message "  3. If the tag is `"many`" cardinality, check if it has reached its limit"
            $err = "  4. Consider using a different tag or modifying the tag category cardinality."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        } else {
            $err = "Error tagging datastore `"$DatastoreName`" with tag `"$TagName`": $errorMessage"
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
    }
}
function Set-NewDatastore {

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
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(1, [Int]::MaxValue)] [Int]$CheckInterval = 5,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DatastoreName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DiskCanonicalName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EsxHost,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$TagName,
        [Parameter(Mandatory = $false)] [ValidateRange(1, [Int]::MaxValue)] [Int]$TotalWaitTime = 120
    )

    Write-LogMessage -Type DEBUG -Message "Entered Set-NewDatastore function..."

    Assert-VcenterConnected

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
            $err = "Cannot access datastore `"$DatastoreName`" on ESX host `"$EsxHost`" due to authorization issues: $($_.Exception.Message)"
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
        catch [System.TimeoutException] {
            $err = "Cannot access datastore `"$DatastoreName`" on ESX host `"$EsxHost`" due to network/timeout issues: $($_.Exception.Message)"
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        } catch [VcfDeploymentException] {
            throw  # already logged and typed — propagate without re-wrapping
        } catch {
            $err = "Error checking datastore `"$DatastoreName`" on ESX host `"$EsxHost`": $($_.Exception.Message)"
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }

        if ($conflictingDatastore) {
            $err = "The datastore `"$DatastoreName`" name is already being used by another server on vCenter `"$Script:vCenterName`". Exiting."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
    }

    $datastoreAlreadyExisted = $false
    if ($datastoreFoundOnEsx) {
        $datastoreAlreadyExisted = $true
        Write-LogMessage -Type INFO -Message "The datastore `"$DatastoreName`" was already created on ESX host `"$EsxHost`". Proceeding to tag assignment."
        # Still need to tag the existing datastore, so continue to tagging section.

    } else {
        Invoke-DatastoreCreationAndWait -CheckInterval $CheckInterval -DatastoreName $DatastoreName -DiskCanonicalName $DiskCanonicalName -EsxHost $EsxHost -TotalWaitTime $TotalWaitTime
    }
    Invoke-DatastoreTagAssignment -DatastoreAlreadyExisted $datastoreAlreadyExisted -DatastoreName $DatastoreName -TagName $TagName
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
function Group-DisksByHost {

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
        }
    #>

    [CmdletBinding()]
    [OutputType([Hashtable])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Object[]]$Disks
    )

    $disksByHost = @{}
    foreach ($disk in $Disks) {
        $hostName = $disk.VMHostName
        if (-not $disksByHost.ContainsKey($hostName)) {
            $disksByHost[$hostName] = [System.Collections.Generic.List[PSObject]]::new()
        }
        $disksByHost[$hostName].Add($disk)
    }

    return $disksByHost
}
function Get-VsanDatastoreForCluster {

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

    [CmdletBinding()]
    [OutputType([System.Object[]])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Object[]]$ClusterHostIds
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
function Invoke-AsyncWaitAndCollect {

    <#
    .SYNOPSIS
        Monitors a running async PowerShell operation and collects its results.
    .DESCRIPTION
        Polls the IAsyncResult until the operation completes or times out, writing progress output.
        On timeout: stops and disposes the PowerShell instance and runspace, then returns an error
        result. On completion: calls EndInvoke, disposes resources, and returns a success result.
    .PARAMETER ActivityName
        Display name shown in Write-Progress and error log messages.
    .PARAMETER AsyncResult
        IAsyncResult handle from BeginInvoke.
    .PARAMETER CheckInterval
        Seconds to sleep between progress polls.
    .PARAMETER MinTimeoutSeconds
        Minimum remaining timeout when adjusting for overall elapsed time.
    .PARAMETER OperationStartTime
        DateTime when this specific operation started, used for elapsed-time calculation.
    .PARAMETER OverallStartTime
        Optional overall start time; when supplied, the timeout is adjusted by overall elapsed time.
    .PARAMETER PsInstance
        PowerShell instance running the operation.
    .PARAMETER Runspace
        Runspace hosting the PowerShell instance.
    .PARAMETER TimeoutSeconds
        Maximum seconds to wait for the operation.
    .EXAMPLE
        $result = Invoke-AsyncWaitAndCollect -ActivityName "Disk scan" -AsyncResult $ar -CheckInterval 5 -MinTimeoutSeconds 30 -OperationStartTime (Get-Date) -PsInstance $ps -Runspace $rs -TimeoutSeconds 300
    .NOTES
        Called by Invoke-AsyncPowerShellOperation. Always disposes PsInstance and Runspace.
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ActivityName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$AsyncResult,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 60)] [Int]$CheckInterval = 5,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 3600)] [Int]$MinTimeoutSeconds = 30,
        [Parameter(Mandatory = $true)] [DateTime]$OperationStartTime,
        [Parameter(Mandatory = $false)] [Nullable[DateTime]]$OverallStartTime,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$PsInstance,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$Runspace,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 86400)] [Int]$TimeoutSeconds = 900
    )

    while (-not $AsyncResult.IsCompleted) {
        $operationElapsed = [Math]::Floor(((Get-Date) - $OperationStartTime).TotalSeconds)
        $remainingTimeout = $TimeoutSeconds
        if ($OverallStartTime) {
            $overallElapsed = [Math]::Floor(((Get-Date) - $OverallStartTime).TotalSeconds)
            $remainingTimeout = [Math]::Max($MinTimeoutSeconds, $TimeoutSeconds - $overallElapsed)
        }
        if ($operationElapsed -ge $remainingTimeout) {
            try { $PsInstance.Stop() } catch { Write-LogMessage -Type DEBUG -Message "Suppressed when stopping runspace: $($_.Exception.Message)" }
            finally { $PsInstance.Dispose(); $Runspace.Close(); $Runspace.Dispose() }
            Write-Progress -Activity $ActivityName -Status "Timeout" -Completed
            [Console]::Out.Flush()
            $timeoutMsg = "Operation timed out after $operationElapsed seconds."
            Write-LogMessage -Type ERROR -Message "$ActivityName - $timeoutMsg"
            return [PSCustomObject]@{ Result = $null; Error = $timeoutMsg; Success = $false }
        }
        Write-Progress -Activity $ActivityName -Status "Elapsed: $operationElapsed seconds..."
        [Console]::Out.Flush()
        Start-Sleep -Seconds $CheckInterval
    }

    $operationResult = $null
    $operationError  = $null
    try {
        $operationResult = $PsInstance.EndInvoke($AsyncResult)
        if ($PsInstance.Streams.Error.Count -gt 0) { $operationError = $PsInstance.Streams.Error[0].Exception.Message }
    } catch {
        $operationError = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
    }
    finally { $PsInstance.Dispose(); $Runspace.Close(); $Runspace.Dispose() }

    if ($operationError) {
        Write-LogMessage -Type ERROR -Message "$ActivityName failed: $operationError"
        return [PSCustomObject]@{ Result = $null; Error = $operationError; Success = $false }
    }
    return [PSCustomObject]@{ Result = $operationResult; Error = $null; Success = $true }
}
function Invoke-AsyncPowerShellOperation {

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
    [OutputType([PSCustomObject])]
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

    $psInstance = [PowerShell]::Create()
    $psInstance.Runspace = $runspace
    $psInstance.AddScript($ScriptBlock) | Out-Null

    $operationStartTime = Get-Date

    try {
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
    $asyncResult = $psInstance.BeginInvoke()
    Write-LogMessage -Type DEBUG -Message "Operation `"$ActivityName`" BeginInvoke() returned. IsCompleted: $($asyncResult.IsCompleted)"

    return Invoke-AsyncWaitAndCollect `
        -ActivityName $ActivityName `
        -AsyncResult $asyncResult `
        -CheckInterval $CheckInterval `
        -MinTimeoutSeconds $MinTimeoutSeconds `
        -OperationStartTime $operationStartTime `
        -OverallStartTime $OverallStartTime `
        -PsInstance $psInstance `
        -Runspace $runspace `
        -TimeoutSeconds $TimeoutSeconds
}
function Get-EsaEligibleDisksFromHosts {

    <#
    .SYNOPSIS
        Retrieves vSAN ESA eligible disks from all hosts in a cluster using async + sync fallback.
    .DESCRIPTION
        For each host, runs Get-VsanEsaEligibleDisk asynchronously via Invoke-AsyncPowerShellOperation.
        If the async result is empty, retries synchronously in case VMware type serialization across the
        runspace boundary produced an empty list. Returns a generic List of all disk objects collected.
    .PARAMETER CheckInterval
        Seconds between async progress polls.
    .PARAMETER ClusterName
        Cluster display name used in log messages.
    .PARAMETER HostsToQuery
        Array of VMHost objects to query.
    .PARAMETER TimeoutSeconds
        Per-host maximum async wait time.
    .EXAMPLE
        $disks = Get-EsaEligibleDisksFromHosts -CheckInterval 5 -ClusterName "cl1" -HostsToQuery $hosts -TimeoutSeconds 900
    .NOTES
        Called by Get-VsanEsaEligibleDisksFromCluster. Uses $Script:MinHostDiskRetrievalTimeoutSeconds.
    #>

    [CmdletBinding()]
    [OutputType([System.Collections.Generic.List[PSObject]])]
    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(1, 60)] [Int]$CheckInterval = 5,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object[]]$HostsToQuery,
        [Parameter(Mandatory = $false)] [ValidateRange(30, 86400)] [Int]$TimeoutSeconds = 900
    )

    $allEligibleDisks = [System.Collections.Generic.List[PSObject]]::new()
    $overallStartTime = Get-Date
    $activityName     = "Retrieving vSAN ESA eligible disks for cluster `"$ClusterName`""
    foreach ($vmHost in $HostsToQuery) {
        $hostName = $vmHost.Name
        Write-LogMessage -Type DEBUG -Message "Retrieving vSAN ESA eligible disks from host `"$hostName`"..."
        $result = Invoke-AsyncPowerShellOperation `
            -ActivityName $activityName `
            -CheckInterval $CheckInterval `
            -MinTimeoutSeconds $Script:MinHostDiskRetrievalTimeoutSeconds `
            -OverallStartTime $overallStartTime `
            -ScriptBlock "Get-VsanEsaEligibleDisk -VMHost `$vmHost -ErrorAction Stop" `
            -TimeoutSeconds $TimeoutSeconds `
            -Variables @{ vmHost = $vmHost }
        if (-not $result.Success) {
            Write-LogMessage -Type WARNING -Message "Failed to retrieve vSAN ESA eligible disks from host `"$hostName`": $($result.Error). Continuing with other hosts..."
            continue
        }
        $hostEligibleDisks = if ($null -eq $result.Result) { @() } else { @($result.Result) }
        $addedCount = 0
        foreach ($disk in $hostEligibleDisks) { if ($null -ne $disk) { $allEligibleDisks.Add($disk); $addedCount++ } }
        if ($addedCount -eq 0) {
            try {
                foreach ($disk in @(Get-VsanEsaEligibleDisk -VMHost $vmHost -ErrorAction Stop)) {
                    if ($null -ne $disk) { $allEligibleDisks.Add($disk); $addedCount++ }
                }
                if ($addedCount -gt 0) {
                    Write-LogMessage -Type INFO -Message "Async returned no disks from host `"$hostName`" but synchronous Get-VsanEsaEligibleDisk found $addedCount disk(s). Using synchronous result."
                }
            } catch {
                Write-LogMessage -Type DEBUG -Message "Synchronous Get-VsanEsaEligibleDisk fallback for host `"$hostName`" failed: $($_.Exception.Message)."
            }
        }
        if ($addedCount -gt 0) {
            Write-LogMessage -Type DEBUG -Message "Found $addedCount eligible disk(s) from host `"$hostName`"."
        } else {
            Write-LogMessage -Type DEBUG -Message "No eligible disks found on host `"$hostName`"."
        }
    }
    return $allEligibleDisks
}
function Get-VsanEsaEligibleDisksFromCluster {

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
    [OutputType([PSObject[]])]
    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(1, 60)] [Int]$CheckInterval = 5,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Object[]]$ClusterHosts,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [ValidateRange(60, 3600)] [Int]$TimeoutSeconds = 900
    )

    Write-LogMessage -Type INFO -Message "Retrieving vSAN ESA eligible disks for cluster `"$ClusterName`" from all hosts..."

    if (-not $ClusterHosts -or $ClusterHosts.Count -eq 0) {
        $err = "Cluster `"$ClusterName`" does not contain any hosts."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }

    Write-LogMessage -Type DEBUG -Message "Cluster `"$ClusterName`" contains $($ClusterHosts.Count) host(s): $($ClusterHosts.Name -join ', ')"
    Write-LogMessage -Type DEBUG -Message "Retrieving eligible disks from $($ClusterHosts.Count) host(s) in cluster `"$ClusterName`"."

    $hostsToQuery = @($ClusterHosts)
    $allEligibleDisks = Get-EsaEligibleDisksFromHosts `
        -CheckInterval $CheckInterval `
        -ClusterName $ClusterName `
        -HostsToQuery $hostsToQuery `
        -TimeoutSeconds $TimeoutSeconds

    Write-Progress -Activity "Retrieving vSAN ESA eligible disks for cluster `"$ClusterName`"" -Status "Completed" -Completed
    [Console]::Out.Flush()

    # Use @() to safely convert; pipeline unwraps List to $null when empty.
    $eligibleDisks = @($allEligibleDisks)

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
            $err = "No vSAN ESA eligible (unclaimed) disks found for cluster `"$ClusterName`". Hosts already have vSAN ESA storage pool disks: $poolSummary. Eligible disks are only unclaimed disks; disks already in a storage pool are not returned by Get-VsanEsaEligibleDisk. If the vSAN datastore exists under a different name, use that name in your configuration or check vCenter for the current datastore name."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
        $err = "No vSAN ESA eligible disks found for cluster `"$ClusterName`"."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
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
function Get-VsanOsaDiskGroupsOnHost {

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
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$Server = $Script:vCenterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] $VMHost
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
function Test-VsanOsaDiskGroupPresentViaEsxcli {

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
    
        .EXAMPLE
        Test-VsanOsaDiskGroupPresentViaEsxcli -VMHost $vmHostObject
    #>
    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$Server = $Script:vCenterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] $VMHost
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
            if (-not [String]::IsNullOrWhiteSpace([String]$uuid)) {
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
function Get-OsaEligibleDisksFromHosts {

    <#
    .SYNOPSIS
        Queries vSAN OSA eligible disks from each host in a list using HostVsanSystem.QueryDisksForVsan.
    .DESCRIPTION
        Iterates the provided host list, queries each host's VsanSystem via the vSphere API, and
        returns all disks whose state is "eligible" as a PSObject array. Hosts that cannot be
        queried (no VsanSystem, API error) emit a warning and are skipped.
    .PARAMETER ClusterName
        Cluster name for log messages.
    .PARAMETER HostsToQuery
        Array of VMHost objects to query.
    .EXAMPLE
        $disks = Get-OsaEligibleDisksFromHosts -ClusterName "cl1" -HostsToQuery $clusterHosts
    .OUTPUTS
        [PSObject[]] Array of eligible disk objects (VMHost, CanonicalName, CapacityGB, Model, IsSsd).
    .NOTES
        Called by Get-VsanOsaEligibleDisksFromCluster.
    #>

    [CmdletBinding()]
    [OutputType([PSObject[]])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object[]]$HostsToQuery
    )

    $allEligibleDisks = [System.Collections.Generic.List[PSObject]]::new()
    foreach ($vmHost in $HostsToQuery) {
        $hostName = $vmHost.Name
        Write-LogMessage -Type DEBUG -Message "Retrieving vSAN OSA eligible disks from host `"$hostName`"..."
        try {
            $hostView = Get-View -Id $vmHost.Id -Server $Script:vCenterName -Property ConfigManager -ErrorAction Stop
            $vsanSystemRef = $hostView.ConfigManager.VsanSystem
            if (-not $vsanSystemRef) { Write-LogMessage -Type WARNING -Message "Host `"$hostName`" has no VsanSystem. Skipping."; continue }
            $vsanSystem = Get-View -Id $vsanSystemRef -Server $Script:vCenterName -ErrorAction Stop
            $diskResults = $vsanSystem.QueryDisksForVsan($null)
        } catch {
            Write-LogMessage -Type WARNING -Message "Failed to retrieve vSAN OSA eligible disks from host `"$hostName`": $($_.Exception.Message). Continuing with other hosts..."
            continue
        }
        if (-not $diskResults) { Write-LogMessage -Type DEBUG -Message "No disk results from host `"$hostName`"."; continue }
        $eligibleCountThisHost = 0
        $rawStatesThisHost = [System.Collections.Generic.List[String]]::new()
        foreach ($resultItem in $diskResults) {
            $state = if ($null -ne $resultItem -and $resultItem.PSObject.Properties['state']) { $resultItem.state } else { "(no state)" }
            $canonical = if ($resultItem -and $resultItem.disk -and $resultItem.disk.canonicalName) { $resultItem.disk.canonicalName } else { "(no canonical)" }
            Write-LogMessage -Type DEBUG -Message "QueryDisksForVsan host `"$hostName`" disk $canonical state=$state."
            if ($null -ne $resultItem -and $resultItem.PSObject.Properties['state']) { $rawStatesThisHost.Add($resultItem.state) }
            if ($null -eq $resultItem -or $resultItem.state -ne "eligible") { continue }
            $rawDisk = $resultItem.disk
            if (-not $rawDisk -or -not $rawDisk.canonicalName) { continue }
            $capacityBytes = 0
            if ($rawDisk.capacity -and $rawDisk.capacity.block -and $rawDisk.capacity.blockSize) { $capacityBytes = $rawDisk.capacity.block * $rawDisk.capacity.blockSize }
            $capacityGB = [Math]::Round($capacityBytes / 1GB, 2)
            $model = if ($rawDisk.model) { $rawDisk.model } else { "" }
            if ($rawDisk.vendor -and $model) { $model = "$($rawDisk.vendor) $model" } elseif ($rawDisk.vendor) { $model = $rawDisk.vendor }
            $isSsd = ($null -ne $rawDisk.PSObject.Properties['ssd'] -and $rawDisk.ssd -eq $true)
            $allEligibleDisks.Add([PSCustomObject]@{ VMHost = $vmHost; CanonicalName = $rawDisk.canonicalName; CapacityGB = $capacityGB; Model = $model; IsSsd = $isSsd })
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
    return @($allEligibleDisks)
}
function Get-VsanOsaEligibleDisksFromCluster {

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
    [OutputType([PSObject[]])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Object[]]$ClusterHosts,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName
    )

    $hostCount = if ($ClusterHosts) { @($ClusterHosts).Count } else { 0 }
    if ($hostCount -eq 1) {
        Write-LogMessage -Type INFO -Message "Retrieving vSAN OSA eligible disks for cluster `"$ClusterName`" from 1 host (witness or single host): $($ClusterHosts.Name)."
    } else {
        Write-LogMessage -Type INFO -Message "Retrieving vSAN OSA eligible disks for cluster `"$ClusterName`" from all hosts..."
    }

    if (-not $ClusterHosts -or $hostCount -eq 0) {
        $err = "Cluster `"$ClusterName`" does not contain any hosts."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }

    Write-LogMessage -Type DEBUG -Message "Cluster `"$ClusterName`" contains $($ClusterHosts.Count) host(s): $($ClusterHosts.Name -join ', ')"
    Write-LogMessage -Type DEBUG -Message "Retrieving eligible disks from $($ClusterHosts.Count) host(s) in cluster `"$ClusterName`" (HostVsanSystem.QueryDisksForVsan)."

    $hostsToQuery = @($ClusterHosts)
    $eligibleDisks = @(Get-OsaEligibleDisksFromHosts -ClusterName $ClusterName -HostsToQuery $hostsToQuery)

    if (-not $eligibleDisks -or $eligibleDisks.Count -eq 0) {
        $queriedHostNames = ($hostsToQuery | Select-Object -ExpandProperty Name) -join ", "
        $queriedHostIds = ($hostsToQuery | Select-Object -ExpandProperty Id) -join "; "
        Write-LogMessage -Type DEBUG -Message "Get-VsanOsaEligibleDisksFromCluster: total eligible disks=0. Queried host(s): $queriedHostNames. Host Id(s): $queriedHostIds."
        $singleHostHint = " The host may have no local disks, or disks may already be in use (e.g. in a disk group or VMFS). For a vSAN witness host, ensure it has at least one SSD for cache and at least one disk for capacity (capacity can be HDD or SSD)."
        $err = "No vSAN OSA eligible disks found for cluster `"$ClusterName`" (queried host(s): $queriedHostNames).$(if ($hostsToQuery.Count -eq 1) { $singleHostHint })"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
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
function New-DiskDisplayList {

    <#
        .SYNOPSIS
        Builds a numbered display object list from eligible disk objects.

        .DESCRIPTION
        Pure transformation — no I/O. Converts vSAN eligible disk objects into PSCustomObjects
        with a sequential Id, VMHostName, CanonicalName, CapacityGB, Model, and the original
        DiskObject. Used by Get-UserDiskSelection and testable without mocking any I/O.

        .PARAMETER EligibleDisks
        Array of vSAN eligible disk objects to transform.

        .OUTPUTS
        System.Collections.Generic.List[PSObject] with sequential integer Id starting at 1.

        .EXAMPLE
        $displayList = New-DiskDisplayList -EligibleDisks $eligibleDisks
    #>

    [CmdletBinding()]
    [OutputType([System.Collections.Generic.List[PSObject]])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Object[]]$EligibleDisks
    )

    $list = [System.Collections.Generic.List[PSObject]]::new()
    $id = 1
    foreach ($disk in $EligibleDisks) {
        $list.Add([PSCustomObject]@{
            Id            = $id++
            VMHostName    = $disk.VMHost.Name
            CanonicalName = $disk.CanonicalName
            CapacityGB    = $disk.CapacityGB
            Model         = $disk.Model
            DiskObject    = $disk
        })
    }
    return $list
}
function Show-EligibleDiskTable {

    <#
        .SYNOPSIS
        Displays the eligible disk list as a formatted console table.

        .DESCRIPTION
        Writes a header line and a Format-Table | Out-String table to the console via Write-Host.
        Display only — no return value.

        .PARAMETER ClusterName
        Name of the cluster, used in the header line.

        .PARAMETER DiskDisplayList
        Array of disk display objects (output of New-DiskDisplayList).

        .PARAMETER StorageType
        Storage architecture label for the header: "ESA" or "OSA".

        .EXAMPLE
        Show-EligibleDiskTable -DiskDisplayList $list -ClusterName "cl01" -StorageType "ESA"

        .NOTES
        Write-Host is the primary output mechanism in this function; all Write-Host calls are
        intentional interactive console output. Use Write-LogMessage for diagnostic logging.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object[]]$DiskDisplayList,
        [Parameter(Mandatory = $false)] [ValidateSet("ESA", "OSA")] [String]$StorageType = "ESA"
    )

    Write-Host ""
    Write-Host "vSAN $StorageType Eligible Disks for cluster `"$ClusterName`":"
    $tableOutput = ($DiskDisplayList | Format-Table -Property Id, VMHostName, CanonicalName, CapacityGB, Model -AutoSize | Out-String).TrimEnd()
    Write-Host $tableOutput
    Write-Host ""
}
function Show-DiskSelectionSummary {

    <#
        .SYNOPSIS
        Displays included and excluded disk tables after a deselection operation.

        .DESCRIPTION
        Writes a summary section with separate tables for included and excluded disks.
        Display only — no return value. Called only when the user deselected at least one disk.

        .PARAMETER ExcludedDisks
        Array of disk display objects that were excluded.

        .PARAMETER SelectedDisks
        Array of disk display objects that remain selected.

        .EXAMPLE
        Show-DiskSelectionSummary -SelectedDisks $selected -ExcludedDisks $excluded

        .NOTES
        Write-Host is the primary output mechanism in this function; all Write-Host calls are
        intentional interactive console output. Use Write-LogMessage for diagnostic logging.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [AllowEmptyCollection()] [Object[]]$ExcludedDisks,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [AllowEmptyCollection()] [Object[]]$SelectedDisks
    )

    Write-Host ""
    Write-Host "Disk Selection Summary:"
    Write-Host ""
    Write-Host "Included Disks:"
    if ($SelectedDisks.Count -gt 0) {
        $SelectedDisks | Format-Table -Property Id, VMHostName, CanonicalName, CapacityGB, Model -AutoSize | Out-Host
    } else {
        Write-Host "  (No disks included)"
    }
    Write-Host ""
    Write-Host "Excluded Disks:"
    if ($ExcludedDisks.Count -gt 0) {
        $ExcludedDisks | Format-Table -Property Id, VMHostName, CanonicalName, CapacityGB, Model -AutoSize | Out-Host
    } else {
        Write-Host "  (No disks excluded)"
    }
    Write-Host ""
}
function Read-DiskDeselectionInput {

    <#
        .SYNOPSIS
        Prompts the user to optionally deselect disks from the displayed list.

        .DESCRIPTION
        Asks whether the user wants to deselect any disks. If yes, collects a comma-separated list
        of integer IDs to exclude, validates each ID, and returns the remaining selected IDs.
        Input collection only — no display formatting.

        .PARAMETER DiskDisplayList
        Array of disk display objects (output of New-DiskDisplayList). Used for ID range validation.

        .OUTPUTS
        PSCustomObject with:
          SelectedDiskIds     — int[] of IDs that remain selected (1-based).
          DisksWereDeselected — $true when the user actively removed at least one disk.

        .EXAMPLE
        $input = Read-DiskDeselectionInput -DiskDisplayList $list

        .NOTES
        Throws [RollbackSkippedException] when the user enters "C" to cancel.
        Throws [VcfDeploymentException] when a non-numeric or out-of-range ID is entered, or
        when all disks are deselected.
        Write-Host is the primary output mechanism in this function; all Write-Host calls are
        intentional interactive console output. Use Write-LogMessage for diagnostic logging.
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object[]]$DiskDisplayList
    )

    $selectedDiskIds = 1..$DiskDisplayList.Count
    $deselectResponse = Read-Host "Would you like to de-select any disks? (Y/N, default: N)"
    Write-Host ""

    if ($deselectResponse -ne "Y" -and $deselectResponse -ne "y") {
        return [PSCustomObject]@{ SelectedDiskIds = $selectedDiskIds; DisksWereDeselected = $false }
    }

    Write-Host ""
    Write-Host "Enter the IDs of disks to de-select (comma-separated, e.g., 1,3,5) or 'C' to cancel:"
    $deselectInput = Read-Host "Disk IDs to de-select"

    if ($deselectInput -ieq "C") {
        Write-LogMessage -Type INFO -Message "User cancelled disk selection workflow."
        throw [RollbackSkippedException]::new()
    }

    $idsToDeselect = [System.Collections.Generic.List[Int]]::new()
    if ($deselectInput -and $deselectInput.Trim()) {
        foreach ($part in ($deselectInput -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
            $parsedId = 0
            if ([Int]::TryParse($part, [Ref]$parsedId)) {
                $idsToDeselect.Add($parsedId)
            } else {
                $errorMsg = "Invalid disk ID format: `"$part`". Expected numeric value."
                Write-LogMessage -Type ERROR -Message $errorMsg
                throw [VcfDeploymentException]::new($errorMsg)
            }
        }
    }

    $idsToDeselectArray = $idsToDeselect.ToArray()
    $invalidIds = $idsToDeselectArray | Where-Object { $_ -lt 1 -or $_ -gt $DiskDisplayList.Count }
    if ($invalidIds) {
        $errorMsg = "Invalid disk ID(s) provided: $($invalidIds -join ', '). Valid range is 1-$($DiskDisplayList.Count)."
        Write-LogMessage -Type ERROR -Message $errorMsg
        throw [VcfDeploymentException]::new($errorMsg)
    }

    $selectedDiskIds = $selectedDiskIds | Where-Object { $idsToDeselectArray -notcontains $_ }
    if ($selectedDiskIds.Count -eq 0) {
        $errorMsg = "No disks selected. At least one disk must be selected."
        Write-LogMessage -Type ERROR -Message $errorMsg
        throw [VcfDeploymentException]::new($errorMsg)
    }

    Write-Host ""
    Write-LogMessage -Type INFO -Message "User de-selected disk ID(s): $($idsToDeselectArray -join ', '). $($selectedDiskIds.Count) disk(s) remain selected."
    return [PSCustomObject]@{ SelectedDiskIds = $selectedDiskIds; DisksWereDeselected = $true }
}
function Get-UserDiskSelection {

    <#
        .SYNOPSIS
        Displays eligible disks to the user and collects their selection.

        .DESCRIPTION
        Coordinator: builds the display list via New-DiskDisplayList, shows the eligible disk
        table via Show-EligibleDiskTable, collects deselection input via Read-DiskDeselectionInput,
        logs the result, optionally shows a summary via Show-DiskSelectionSummary, and returns
        the selected and excluded disk objects.

        .PARAMETER ClusterName
        Name of the cluster (for display purposes).

        .PARAMETER EligibleDisks
        Array of vSAN eligible disk objects to display and select from.

        .PARAMETER StorageType
        Type of vSAN storage architecture: "ESA" or "OSA". Default is "ESA".

        .OUTPUTS
        PSCustomObject with properties:
        - SelectedDisks: Array of disk display objects that were selected.
        - ExcludedDisks: Array of disk display objects that were excluded.
        - DisksWereDeselected: Boolean indicating if the user actively deselected any disks.
        - DiskDisplayList: Array of all disk display objects with IDs.

        .EXAMPLE
        $selection = Get-UserDiskSelection -ClusterName "MyCluster" -EligibleDisks $eligibleDisks -StorageType "ESA"
        $selectedDisks = $selection.SelectedDisks

        .NOTES
        Write-Host is the primary output mechanism in this function; all Write-Host calls are
        intentional interactive console output. Use Write-LogMessage for diagnostic logging.
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Object[]]$EligibleDisks,
        [Parameter(Mandatory = $false)] [ValidateSet("ESA", "OSA")] [String]$StorageType = "ESA"
    )

    $diskDisplayList = @(New-DiskDisplayList -EligibleDisks $EligibleDisks)
    Show-EligibleDiskTable -DiskDisplayList $diskDisplayList -ClusterName $ClusterName -StorageType $StorageType

    $inputResult    = Read-DiskDeselectionInput -DiskDisplayList $diskDisplayList
    $selectedDiskIds     = $inputResult.SelectedDiskIds
    $disksWereDeselected = $inputResult.DisksWereDeselected

    $selectedDisks = @($diskDisplayList | Where-Object { $selectedDiskIds -contains $_.Id })
    $excludedDisks = @($diskDisplayList | Where-Object { $selectedDiskIds -notcontains $_.Id })

    if ($disksWereDeselected) {
        Show-DiskSelectionSummary -SelectedDisks $selectedDisks -ExcludedDisks $excludedDisks
    } else {
        Write-LogMessage -Type INFO -Message "All $($diskDisplayList.Count) disk(s) will be added to vSAN $StorageType storage pools."
    }

    Write-LogMessage -Type DEBUG -Message "Included disks ($($selectedDisks.Count) total):"
    foreach ($disk in $selectedDisks) {
        Write-LogMessage -Type DEBUG -Message "  - ID $($disk.Id): Host=$($disk.VMHostName), CanonicalName=$($disk.CanonicalName), CapacityGB=$($disk.CapacityGB), Model=$($disk.Model)"
    }
    if ($excludedDisks.Count -gt 0) {
        Write-LogMessage -Type DEBUG -Message "Excluded disks ($($excludedDisks.Count) total):"
        foreach ($disk in $excludedDisks) {
            Write-LogMessage -Type DEBUG -Message "  - ID $($disk.Id): Host=$($disk.VMHostName), CanonicalName=$($disk.CanonicalName), CapacityGB=$($disk.CapacityGB), Model=$($disk.Model)"
        }
    } else {
        Write-LogMessage -Type DEBUG -Message "No disks excluded - all disks are included."
    }

    if ($selectedDisks.Count -eq 0) {
        $errorMsg = "No disks selected for vSAN $StorageType storage pool. At least one disk must be selected to create a vSAN datastore."
        Write-LogMessage -Type ERROR -Message $errorMsg
        throw [VcfDeploymentException]::new($errorMsg)
    }

    return [PSCustomObject]@{
        SelectedDisks       = $selectedDisks
        ExcludedDisks       = $excludedDisks
        DisksWereDeselected = $disksWereDeselected
        DiskDisplayList     = $diskDisplayList
    }
}
function Add-VsanOsaDiskToDiskGroup {

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
            $err = "No cache disk defined for host `"$hostName`"."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
        $capacityCanonicalNames = @()
        if ($capacityDisks -and $capacityDisks.Count -gt 0) {
            $capacityCanonicalNames = $capacityDisks | Select-Object -ExpandProperty CanonicalName
        }
        Write-LogMessage -Type INFO -Message "Creating vSAN OSA disk group on host `"$hostName`" (1 cache, $($capacityCanonicalNames.Count) capacity disk(s))."

        try {
            $vmHostObject = Get-VMHost -Name $hostName -Server $Script:vCenterName -ErrorAction Stop
            Write-LogMessage -Type DEBUG -Message "Retrieved VMHost object for `"$hostName`". Starting New-VsanDiskGroup at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')..."

            $operationStartTime = Get-Date
            try {
                if ($capacityCanonicalNames.Count -eq 0) {
                    $err = "At least one capacity disk is required per host for vSAN OSA disk group on `"$hostName`"."
                    Write-LogMessage -Type ERROR -Message $err
                    throw [VcfDeploymentException]::new($err)
                }
                # Pass as array so cmdlet receives string[] and does not enumerate a single string as characters (avoids "Sequence contains no elements").
                $dataDiskArray = @($capacityCanonicalNames)
                New-VsanDiskGroup -VMHost $vmHostObject -SsdCanonicalName $cacheDisk.CanonicalName -DataDiskCanonicalName $dataDiskArray -ErrorAction Stop | Out-Null

                $operationEndTime = Get-Date
                $operationDuration = [Math]::Round(($operationEndTime - $operationStartTime).TotalSeconds, 2)
                Write-LogMessage -Type DEBUG -Message "New-VsanDiskGroup completed for host `"$hostName`" after $operationDuration seconds."
                Write-LogMessage -Type INFO -Message "Successfully created vSAN OSA disk group on host `"$hostName`"."
            } catch {
                $operationEndTime = Get-Date
                $operationDuration = [Math]::Round(($operationEndTime - $operationStartTime).TotalSeconds, 2)
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
                        $errorMsg = "Failed to create vSAN OSA disk group on host `"$hostName`": $errMsg"
                        Write-LogMessage -Type ERROR -Message $errorMsg
                    }
                }
                throw [VcfDeploymentException]::new($errorMsg)
            }
        } catch [VcfDeploymentException] {
            throw  # already logged and typed — propagate without re-wrapping
        } catch {
            $err = "Failed to create vSAN OSA disk group on host `"$hostName`": $($_.Exception.Message)"
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
    }
}
function Invoke-VsanStoragePoolDiskWithRetry {

    <#
        .SYNOPSIS
        Calls Add-VsanStoragePoolDisk for a host with retry logic for transient invalid-state errors.

        .DESCRIPTION
        Executes Add-VsanStoragePoolDisk for the given host and disks, retrying up to
        ClaimRetryMaxAttempts times when a transient invalid-object-state error is returned.
        On final failure, logs the error reason (with a PowerCLI timeout hint when applicable)
        and throws VcfDeploymentException.

        .PARAMETER CanonicalNames
        Array of disk canonical names to add to the vSAN ESA storage pool.

        .PARAMETER ClaimRetryDelaySeconds
        Delay in seconds between retry attempts. Default is 15.

        .PARAMETER ClaimRetryMaxAttempts
        Maximum number of attempts before giving up. Default is 4.

        .PARAMETER HostName
        Host display name used in log messages and error text.

        .PARAMETER TimeoutSeconds
        PowerCLI web operation timeout value used to compute a recommended timeout hint. Default is 1800.

        .PARAMETER VMHostObject
        The VMHost PowerCLI object for the target host.

        .EXAMPLE
        Invoke-VsanStoragePoolDiskWithRetry -HostName "esx01.lab" -VMHostObject $vmh -CanonicalNames @("naa.xxx") -ClaimRetryMaxAttempts 4 -ClaimRetryDelaySeconds 15 -TimeoutSeconds 1800

        .NOTES
        Called by Add-VsanEsaDiskToStoragePool for each cluster host.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String[]]$CanonicalNames,
        [Parameter(Mandatory = $false)] [ValidateRange(5, 120)] [Int]$ClaimRetryDelaySeconds = 15,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 12)] [Int]$ClaimRetryMaxAttempts = 4,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$HostName,
        [Parameter(Mandatory = $false)] [ValidateRange(60, 3600)] [Int]$TimeoutSeconds = 1800,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$VMHostObject
    )

    $operationStartTime = Get-Date
    try {
        $claimAttempt = 0
        while ($claimAttempt -lt $ClaimRetryMaxAttempts) {
            $claimAttempt++
            try {
                Add-VsanStoragePoolDisk -VMHost $VMHostObject -VsanStoragePoolDiskType $Script:VsanStoragePoolDiskType -DiskCanonicalNames $CanonicalNames -ErrorAction Stop | Out-Null
                break
            } catch {
                $rawMsg = $_.Exception.Message
                if ($_.Exception.InnerException) {
                    $rawMsg = "$rawMsg $($_.Exception.InnerException.Message)"
                }
                $isTransientState = $rawMsg -match "Operation is not valid due to the current state of the object|invalid state|InvalidState|not allowed in the current state"
                if ($isTransientState -and $claimAttempt -lt $ClaimRetryMaxAttempts) {
                    Write-LogMessage -Type WARNING -Message "Add-VsanStoragePoolDisk attempt $claimAttempt of $ClaimRetryMaxAttempts on host `"$HostName`" failed (transient object state). Waiting $ClaimRetryDelaySeconds seconds before retry."
                    Start-Sleep -Seconds $ClaimRetryDelaySeconds
                    continue
                }
                throw
            }
        }
        $operationDuration = [Math]::Round(((Get-Date) - $operationStartTime).TotalSeconds, 2)
        Write-LogMessage -Type DEBUG -Message "Add-VsanStoragePoolDisk operation completed for host `"$HostName`" after $operationDuration seconds."
        Write-LogMessage -Type INFO -CompletePending -Message "Success"
    } catch {
        $operationDuration = [Math]::Round(((Get-Date) - $operationStartTime).TotalSeconds, 2)
        Write-LogMessage -Type DEBUG -Message "Add-VsanStoragePoolDisk operation failed for host `"$HostName`" after $operationDuration seconds."
        $errorReason = Get-CleanVsanErrorMessage -ErrorMessage $_.Exception.Message
        if ($_.Exception.Message -match "request channel timed out|SendTimeout|00:05:00") {
            $recommendedTimeout = [Math]::Min($TimeoutSeconds + $Script:PowerCliTimeoutBufferSeconds, $Script:MaxPowerCliTimeoutSeconds)
            Write-LogMessage -Type ERROR -CompletePending -Message " Failed."
            Write-LogMessage -Type ERROR -Message "Add disk(s) to datastore failed due to PowerCLI web operation timeout (default is 5 minutes)."
            Write-LogMessage -Type ERROR -Message "To resolve this, increase the PowerCLI web operation timeout by running:"
            Write-LogMessage -Type ERROR -Message "    Set-PowerCLIConfiguration -WebOperationTimeoutSeconds $recommendedTimeout -Scope Session"
            Write-LogMessage -Type ERROR -Message "Then re-run the deployment. The recommended timeout is $recommendedTimeout seconds (based on operation timeout of $TimeoutSeconds seconds)."
            Write-LogMessage -Type ERROR -Message "Failed to add disks to vSAN ESA datastore from host `"$HostName`": $errorReason"
        } else {
            Write-LogMessage -Type ERROR -CompletePending -Message " Failed."
            $errorMsg = "Failed to add disks to vSAN ESA datastore from host `"$HostName`": $errorReason"
            Write-LogMessage -Type ERROR -Message $errorMsg
        }
        throw [VcfDeploymentException]::new($errorMsg)
    }
}
function Add-VsanEsaDiskToStoragePool {

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
        $canonicalNames = [System.Collections.Generic.List[String]]::new()
        foreach ($disk in $hostDisks) {
            $canonicalNames.Add($disk.CanonicalName)
        }
        # .ToArray() required: the cmdlet parameter does not accept List[T] directly.
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

            Invoke-VsanStoragePoolDiskWithRetry `
                -CanonicalNames        $canonicalNames `
                -ClaimRetryDelaySeconds $ClaimRetryDelaySeconds `
                -ClaimRetryMaxAttempts  $ClaimRetryMaxAttempts `
                -HostName               $hostName `
                -TimeoutSeconds         $TimeoutSeconds `
                -VMHostObject           $vmHostObject
        } catch {
            if ($null -ne $Script:LogMessagePending) {
                Write-LogMessage -Type ERROR -CompletePending -Message " Failed."
            }
            $errorReason = Get-CleanVsanErrorMessage -ErrorMessage $_.Exception.Message
            $err = "Failed to add disks to vSAN ESA datastore from host `"$hostName`": $errorReason"
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
    }
}
function Invoke-VsanDatastoreRenameAndVerify {

    <#
    .SYNOPSIS
        Renames a vSAN datastore and verifies the rename succeeded.
    .DESCRIPTION
        If the datastore name already matches DatastoreName no action is taken. Otherwise,
        Set-Datastore is called and the result is confirmed by re-querying vCenter after a
        brief delay. Throws VcfDeploymentException on any failure.
    .PARAMETER DatastoreName
        Target name for the vSAN datastore.
    .PARAMETER VsanDatastore
        The datastore object returned by Get-Datastore.
    .EXAMPLE
        Invoke-VsanDatastoreRenameAndVerify -DatastoreName "datastore-site1" -VsanDatastore $ds
    .NOTES
        Uses $Script:vCenterName and $Script:DatastoreRenameVerificationDelaySeconds.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DatastoreName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$VsanDatastore
    )

    Write-LogMessage -Type DEBUG -Message "vSAN datastore found: `"$($VsanDatastore.Name)`" (Type: $($VsanDatastore.Type))"

    if ($VsanDatastore.Name -ne $DatastoreName) {
        try {
            $VsanDatastore | Set-Datastore -Name $DatastoreName -Server $Script:vCenterName -ErrorAction Stop | Out-Null

            Start-Sleep -Seconds $Script:DatastoreRenameVerificationDelaySeconds
            $renamedDatastore = Get-Datastore -Name $DatastoreName -Server $Script:vCenterName -ErrorAction SilentlyContinue
            if (-not $renamedDatastore) {
                $err = "Failed to verify vSAN datastore rename. Datastore `"$DatastoreName`" not found after rename operation."
                Write-LogMessage -Type ERROR -Message $err
                throw [VcfDeploymentException]::new($err)
            }

            Write-LogMessage -Type INFO -CompletePending -Message "Success"
        } catch [VcfDeploymentException] {
            throw
        } catch {
            Write-LogMessage -Type ERROR -CompletePending -Message " Failed."
            $err = "Failed to rename vSAN datastore from `"$($VsanDatastore.Name)`" to `"$DatastoreName`": $($_.Exception.Message)"
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
    }

    $finalDatastore = Get-Datastore -Name $DatastoreName -Server $Script:vCenterName -ErrorAction SilentlyContinue
    if (-not $finalDatastore) {
        $err = "vSAN datastore `"$DatastoreName`" not found after configuration."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
    $null = $finalDatastore
}
function Wait-ForVsanDatastoreAndRename {

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
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Object[]]$ClusterHosts,
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
        $elapsedTime = [Math]::Floor(((Get-Date) - $startTime).TotalSeconds)
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
            $errorMsg = "Deployment failed. vSAN datastore was not created within the timeout period. Check logs for details."
            Write-LogMessage -Type ERROR -Message $errorMsg
            throw [VcfDeploymentException]::new($errorMsg)
        }

        # Look for vSAN datastores accessible by hosts in the cluster.
        $vsanDatastores = Get-VsanDatastoreForCluster -ClusterHostIds $clusterHostIds

        # Only log periodically to reduce verbosity, or when datastore count changes.
        if (($elapsedTime - $lastLoggedTime) -ge $logIntervalSeconds -or ($vsanDatastores.Count -gt 0)) {
            Write-LogMessage -Type DEBUG -Message "Check #$checkCount (elapsed: $elapsedTime seconds): Found $($vsanDatastores.Count) vSAN datastore(s) accessible by cluster hosts."
            $lastLoggedTime = $elapsedTime
        }

        if ($vsanDatastores -and $vsanDatastores.Count -gt 0) {
            $vsanDatastore = $vsanDatastores | Select-Object -First 1
            Invoke-VsanDatastoreRenameAndVerify -DatastoreName $DatastoreName -VsanDatastore $vsanDatastore
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
function Get-CleanVsanErrorMessage {

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

    [CmdletBinding()]
    [OutputType([String])]
    Param ([Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ErrorMessage)

    if ([String]::IsNullOrWhiteSpace($ErrorMessage)) {
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
function Resolve-VsanWitnessOsaDiskNames {

    <#
        .SYNOPSIS
        Pre-validates that selected OSA witness disks are visible on the host and resolves canonical names to NAA format.

        .DESCRIPTION
        Verifies that the cache and capacity disks selected for an OSA witness disk group are visible on the
        witness host via Get-ScsiLun. Resolves each disk's canonical name to the ScsiLun CanonicalName
        (typically NAA format) so New-VsanDiskGroup receives the format the host/vSAN API expects.
        QueryDisksForVsan may return mpx paths while New-VsanDiskGroup looks up by NAA; this resolution
        avoids "Sequence contains no elements" errors from New-VsanDiskGroup.
        Throws a VcfDeploymentException if any required disk is not visible on the host.

        .PARAMETER CacheDisk
        The selected cache disk object (must have a CanonicalName property).

        .PARAMETER CapacityCanonicalNames
        String array of canonical names for the capacity disk(s).

        .PARAMETER VMHost
        The witness VMHost object.

        .PARAMETER VMHostName
        The witness host name string (used for log messages and exception text).

        .EXAMPLE
        $diskNames = Resolve-VsanWitnessOsaDiskNames -CacheDisk $cacheDisk -CapacityCanonicalNames $capNames -VMHost $witnessHost -VMHostName "witness01.lab.local"
        New-VsanDiskGroup -VMHost $witnessHost -SsdCanonicalName $diskNames.CacheNameForCmdlet -DataDiskCanonicalName $diskNames.DataDiskArray

        .OUTPUTS
        PSCustomObject with CacheNameForCmdlet (String) and DataDiskArray (String[]).
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] $CacheDisk,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [String[]]$CapacityCanonicalNames,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] $VMHost,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VMHostName
    )

    $requiredCanonicalNames = @($CacheDisk.CanonicalName) + @($CapacityCanonicalNames)
    $visibleLuns = Get-ScsiLun -VMHost $VMHost -LunType disk -ErrorAction SilentlyContinue
    $visibleCanonicalNames = @($visibleLuns | Select-Object -ExpandProperty CanonicalName | Select-Object -Unique)
    $visibleRuntimeNames = @($visibleLuns | ForEach-Object {
        if ($_.PSObject.Properties['RuntimeName']) { $_.RuntimeName } else { $null }
    } | Where-Object { -not [String]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    $missingDisks = @($requiredCanonicalNames | Where-Object {
        $cn = $_
        $visibleCanonicalNames -notcontains $cn -and $visibleRuntimeNames -notcontains $cn
    })
    if ($missingDisks.Count -gt 0) {
        $err = "Witness host `"$VMHostName`" cannot see one or more disks that were reported as eligible. Missing on host: $($missingDisks -join ', '). Visible disk count: $($visibleCanonicalNames.Count)."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
    $cacheLun = $visibleLuns | Where-Object {
        $_.CanonicalName -eq $CacheDisk.CanonicalName -or ($_.PSObject.Properties['RuntimeName'] -and $_.RuntimeName -eq $CacheDisk.CanonicalName)
    } | Select-Object -First 1
    $cacheNameForCmdlet = if ($cacheLun) { $cacheLun.CanonicalName } else { $CacheDisk.CanonicalName }
    $capacityNamesForCmdlet = [System.Collections.Generic.List[String]]::new()
    foreach ($capName in $CapacityCanonicalNames) {
        $capLun = $visibleLuns | Where-Object {
            $_.CanonicalName -eq $capName -or ($_.PSObject.Properties['RuntimeName'] -and $_.RuntimeName -eq $capName)
        } | Select-Object -First 1
        $capacityNamesForCmdlet.Add($(if ($capLun) { $capLun.CanonicalName } else { $capName }))
    }
    $dataDiskArray = @($capacityNamesForCmdlet)
    if ($cacheNameForCmdlet -ne $CacheDisk.CanonicalName -or ($capacityNamesForCmdlet -join ',') -ne ($CapacityCanonicalNames -join ',')) {
        Write-LogMessage -Type DEBUG -Message "Resolve-VsanWitnessOsaDiskNames: resolved disk names for New-VsanDiskGroup (cache: $cacheNameForCmdlet, capacity: $($dataDiskArray -join ', '))."
    }
    return [PSCustomObject]@{ CacheNameForCmdlet = $cacheNameForCmdlet; DataDiskArray = $dataDiskArray }
}
function Invoke-VsanOsaWitnessDiskGroupCreation {

    <#
        .SYNOPSIS
        Creates a vSAN OSA disk group on a witness host if one does not already exist.

        .DESCRIPTION
        Handles the full OSA witness disk group creation path: checks for an existing disk group, retrieves
        eligible disks, selects the cache disk (smallest SSD) and capacity disk(s), validates canonical
        names via Resolve-VsanWitnessOsaDiskNames, and calls New-VsanDiskGroup.

        Supports single-SSD witness appliance compatibility: the official vSAN OSA witness OVF marks only
        one disk as SSD (T0 is boot, excluded). When one eligible SSD is found, single-disk disk group
        creation is attempted; if the platform rejects it, a VcfDeploymentException is thrown requesting a
        second non-boot disk.

        .PARAMETER ClusterName
        Cluster name (used for eligible disk retrieval logging).

        .PARAMETER VMHost
        The witness VMHost object.

        .PARAMETER VMHostName
        The witness host name string (used in log messages and exception text).

        .EXAMPLE
        Invoke-VsanOsaWitnessDiskGroupCreation -ClusterName "MyCluster" -VMHost $witnessHost -VMHostName "witness01.lab.local"

        Ensures the OSA witness disk group exists on witness01.lab.local.

        .NOTES
        Called by Initialize-VsanWitnessDiskGroup when StoragePolicyType is vSAN-OSA.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] $VMHost,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VMHostName
    )

    $witnessOsaResult = Get-VsanOsaDiskGroupsOnHost -VMHost $VMHost -Server $Script:vCenterName
    $hasValidOsaGroup = $witnessOsaResult.HasValidOsaGroup -or ($witnessOsaResult.DiskGroupCount -gt 0)
    if ($witnessOsaResult.DiskGroupCount -gt 0) {
        Write-LogMessage -Type DEBUG -Message "Witness host `"$VMHostName`" has $($witnessOsaResult.DiskGroupCount) OSA disk group(s) (HostVsanSystem.config). HasValidOsaGroup=$($witnessOsaResult.HasValidOsaGroup)."
    }
    if ($hasValidOsaGroup) {
        Write-LogMessage -Type INFO -Message "Witness host `"$VMHostName`" already has a vSAN OSA disk group. Skipping auto-create."
        return
    }
    $witnessHostsArray = @($VMHost)
    Write-LogMessage -Type DEBUG -Message "Invoke-VsanOsaWitnessDiskGroupCreation: calling Get-VsanOsaEligibleDisksFromCluster for witness host `"$VMHostName`" (ClusterHosts count=$($witnessHostsArray.Count))."
    $eligibleDisks = Get-VsanOsaEligibleDisksFromCluster -ClusterName $ClusterName -ClusterHosts $witnessHostsArray
    Write-LogMessage -Type DEBUG -Message "Invoke-VsanOsaWitnessDiskGroupCreation: witness host returned $($eligibleDisks.Count) eligible disk(s)."
    if (-not $eligibleDisks -or $eligibleDisks.Count -eq 0) {
        $err = "Witness host `"$VMHostName`" has no vSAN OSA eligible disks. The boot device is typically excluded from vSAN; add at least one non-boot disk (e.g. a second virtual disk) to the witness appliance."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
    $singleSsdWitness = $false
    if ($eligibleDisks.Count -eq 1) {
        $onlyDisk = $eligibleDisks[0]
        if ($onlyDisk.IsSsd) {
            $singleSsdWitness = $true
            Write-LogMessage -Type INFO -Message "Witness has one eligible SSD; attempting single-disk OSA witness disk group (official witness appliance compatibility)."
        } else {
            $err = "Witness host `"$VMHostName`" has only one eligible disk (not SSD). vSAN OSA requires one SSD for cache. Add a non-boot SSD or a second disk to the witness appliance and re-run."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
    }
    $ssds = @($eligibleDisks | Where-Object { $_.IsSsd } | Sort-Object -Property CapacityGB)
    $nonSsds = @($eligibleDisks | Where-Object { -not $_.IsSsd })
    if ($ssds.Count -eq 0) {
        $err = "Witness host `"$VMHostName`" has no SSD among eligible disks. vSAN OSA requires one SSD for cache; capacity can be HDD or SSD. The boot device is typically excluded; add a non-boot SSD to the witness."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
    $cacheDisk = $ssds[0]
    $witnessOsaApiOrderStr = ($eligibleDisks | ForEach-Object { "$($_.CanonicalName)/$($_.CapacityGB)/$($_.IsSsd)" }) -join ", "
    Write-LogMessage -Type DEBUG -Message "Invoke-VsanOsaWitnessDiskGroupCreation: witness disks (API order) CanonicalName/CapacityGB/IsSsd: $witnessOsaApiOrderStr. Chosen cache: $($cacheDisk.CanonicalName), CapacityGB=$($cacheDisk.CapacityGB)."
    $capacityDisksList = @(if ($singleSsdWitness) { @($cacheDisk) } else { $nonSsds + ($ssds | Select-Object -Skip 1) })
    if ($capacityDisksList.Count -eq 0 -and -not $singleSsdWitness) {
        $err = "Witness host `"$VMHostName`" has only one eligible disk (SSD). Add a second non-boot disk to the witness appliance and re-run."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
    if ([String]::IsNullOrWhiteSpace($cacheDisk.CanonicalName)) {
        $err = "Witness host `"$VMHostName`" cache SSD disk has no valid CanonicalName."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
    $capacityCanonicalNames = [string[]]@($capacityDisksList | Select-Object -ExpandProperty CanonicalName | Where-Object { -not [String]::IsNullOrWhiteSpace($_) })
    if ($capacityCanonicalNames.Count -eq 0) {
        $err = "Witness host `"$VMHostName`" capacity disk(s) have no valid CanonicalName."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
    Write-LogMessage -Type INFO -Message "Creating vSAN OSA witness disk group on `"$VMHostName`" (cache SSD: $($cacheDisk.CanonicalName), capacity: $($capacityCanonicalNames -join ', '))."
    $resolvedNames = Resolve-VsanWitnessOsaDiskNames -CacheDisk $cacheDisk -CapacityCanonicalNames $capacityCanonicalNames -VMHost $VMHost -VMHostName $VMHostName
    try {
        New-VsanDiskGroup -VMHost $VMHost -SsdCanonicalName $resolvedNames.CacheNameForCmdlet -DataDiskCanonicalName $resolvedNames.DataDiskArray -ErrorAction Stop | Out-Null
    } catch {
        $msg = $_.Exception.Message
        if ($_.Exception.InnerException) { $msg = $_.Exception.InnerException.Message }
        if ($singleSsdWitness) {
            $errorMsg = "Deployment failed. Witness host `"$VMHostName`" has only one vSAN-eligible disk; this platform requires one distinct cache (SSD) and one distinct capacity disk. Add a second non-boot disk to the witness appliance and re-run."
            Write-LogMessage -Type ERROR -Message $errorMsg
            throw [VcfDeploymentException]::new($errorMsg)
        }
        if ($msg -match "Sequence contains no elements") {
            $witnessOsaRecheck = Get-VsanOsaDiskGroupsOnHost -VMHost $VMHost -Server $Script:vCenterName
            if ($witnessOsaRecheck.HasValidOsaGroup -or $witnessOsaRecheck.DiskGroupCount -gt 0) {
                Write-LogMessage -Type DEBUG -Message "New-VsanDiskGroup failed with Sequence contains no elements; witness `"$VMHostName`" already has a vSAN OSA disk group. Treating as success."
                return
            }
            $err = "New-VsanDiskGroup failed on witness `"$VMHostName`" with Sequence contains no elements. Names passed to cmdlet: cache=$($resolvedNames.CacheNameForCmdlet), capacity=$($resolvedNames.DataDiskArray -join ', '). Disks were visible via Get-ScsiLun; the failure may be due to disk state (e.g. in use) or a VCF PowerCLI lookup difference."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
        throw
    }
    if ($singleSsdWitness) {
        Write-LogMessage -Type INFO -Message "Successfully created vSAN OSA witness disk group on host `"$VMHostName`" (single eligible disk; official witness appliance compatibility)."
    } else {
        Write-LogMessage -Type INFO -Message "Successfully created vSAN OSA witness disk group on host `"$VMHostName`"."
    }
}
function Initialize-VsanWitnessDiskGroup {

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
    
        .EXAMPLE
        Initialize-VsanWitnessDiskGroup -ClusterName "edge-cluster-1" -StoragePolicyType "storage-policy" -StoragePolicyType "storage-policy"
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 10000)] [Int]$MinWitnessEsaCapacityGB = 32,
        [Parameter(Mandatory = $true)] [ValidateSet("vSAN-ESA", "vSAN-OSA")] [String]$StoragePolicyType,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$vSanWitnessVmName
    )

    Write-LogMessage -Type DEBUG -Message "Entered Initialize-VsanWitnessDiskGroup for witness `"$vSanWitnessVmName`", storage type `"$StoragePolicyType`"."

    $witnessHost = Get-VMHost -Name $vSanWitnessVmName -Server $Script:vCenterName -ErrorAction Stop
    if (-not $witnessHost) {
        $err = "Witness host `"$vSanWitnessVmName`" not found in vCenter."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }

    # Check HostDeployedFromWitnessOVF (set by official witness OVF at firstboot): 1 = OSA witness OVA, 2 = ESA witness OVA. If present and mismatched, tell the user they deployed the wrong OVA.
    $hostDeployedFromWitnessOvf = $null
    try {
        $advSetting = Get-AdvancedSetting -Entity $witnessHost -Name "VSAN.HostDeployedFromWitnessOVF" -ErrorAction SilentlyContinue
        if ($advSetting -and $null -ne $advSetting.Value) {
            $hostDeployedFromWitnessOvf = [Int]$advSetting.Value
            Write-LogMessage -Type DEBUG -Message "Witness host `"$vSanWitnessVmName`" HostDeployedFromWitnessOVF=$hostDeployedFromWitnessOvf (1=OSA witness OVA, 2=ESA witness OVA)."
        }
    } catch {
        Write-LogMessage -Type DEBUG -Message "Could not read HostDeployedFromWitnessOVF from witness `"$vSanWitnessVmName`": $($_.Exception.Message). Skipping OVA-type check."
    }
    if ($null -ne $hostDeployedFromWitnessOvf) {
        if ($StoragePolicyType -eq "vSAN-OSA" -and $hostDeployedFromWitnessOvf -eq 2) {
            $err = "Witness host `"$vSanWitnessVmName`" was deployed from the vSAN ESA witness OVA (HostDeployedFromWitnessOVF=2). For an OSA cluster use the vSAN OSA witness appliance OVA."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
        if ($StoragePolicyType -eq "vSAN-ESA" -and $hostDeployedFromWitnessOvf -eq 1) {
            $err = "Witness host `"$vSanWitnessVmName`" was deployed from the vSAN OSA witness OVA (HostDeployedFromWitnessOVF=1). For an ESA cluster use the vSAN ESA witness appliance OVA."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
    }

    # Fail if witness disk layout does not match requested storage type (OSA vs ESA). Prevents using an OSA witness for ESA or vice versa.
    if ($StoragePolicyType -eq "vSAN-ESA") {
        $witnessOsaResult = Get-VsanOsaDiskGroupsOnHost -VMHost $witnessHost -Server $Script:vCenterName
        if ($witnessOsaResult.HasValidOsaGroup) {
            $err = "Witness host `"$vSanWitnessVmName`" has a vSAN OSA disk group (cache + capacity). This witness is for vSAN OSA, not ESA. Use an ESA witness or remove the OSA disk group from this host."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
    }
    elseif ($StoragePolicyType -eq "vSAN-OSA") {
        $witnessPoolDisks = Get-VsanStoragePoolDisk -VMHost $witnessHost -Server $Script:vCenterName -ErrorAction SilentlyContinue
        $witnessPoolDiskCount = if ($witnessPoolDisks) { @($witnessPoolDisks).Count } else { 0 }
        if ($witnessPoolDiskCount -ge 1) {
            $err = "Witness host `"$vSanWitnessVmName`" has a vSAN ESA storage pool (all-flash). This witness is for vSAN ESA, not OSA. Use an OSA witness or remove the ESA storage pool from this host."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
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
        Invoke-VsanOsaWitnessDiskGroupCreation -ClusterName $ClusterName -VMHost $witnessHost -VMHostName $vSanWitnessVmName
    }
}
function Test-VsanDataHostVersionConsistency {

    <#
        .SYNOPSIS
        Checks all data hosts in a vSAN cluster for consistent ESX version and build against a reference.

        .DESCRIPTION
        Iterates each cluster data host and compares its version and build against the provided reference
        values. Returns on the first mismatch found. Returns HasMismatch=$false when all hosts match or
        when version/build is unreadable on a host.

        .PARAMETER ClusterHosts
        Array of VMHost objects representing the cluster data hosts.

        .PARAMETER RefBuild
        Expected ESX build number (from the first data host used as the reference).

        .PARAMETER RefVersion
        Expected ESX version string (from the first data host used as the reference).

        .EXAMPLE
        $check = Test-VsanDataHostVersionConsistency -ClusterHosts $hosts -RefVersion "8.0.0" -RefBuild "21313628"

        .NOTES
        Called by Confirm-VsanWitnessVersionMatch after the witness/reference-host comparison.
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object[]]$ClusterHosts,
        [Parameter(Mandatory = $false)] [String]$RefBuild,
        [Parameter(Mandatory = $false)] [String]$RefVersion
    )

    foreach ($dataHost in @($ClusterHosts)) {
        $hostVersion = if ($dataHost.PSObject.Properties['Version']) { [String]$dataHost.Version } else { $null }
        if ([String]::IsNullOrWhiteSpace($hostVersion) -and $dataHost.ExtensionData -and $dataHost.ExtensionData.Config -and $dataHost.ExtensionData.Config.Product) { $hostVersion = [String]$dataHost.ExtensionData.Config.Product.Version }
        $hostBuild = if ($dataHost.PSObject.Properties['Build']) { [String]$dataHost.Build } else { $null }
        if ([String]::IsNullOrWhiteSpace($hostBuild) -and $dataHost.ExtensionData -and $dataHost.ExtensionData.Config -and $dataHost.ExtensionData.Config.Product) { $hostBuild = [String]$dataHost.ExtensionData.Config.Product.Build }
        if (-not [String]::IsNullOrWhiteSpace($hostVersion) -and $hostVersion -ne $RefVersion) {
            $detail = "Cluster host `"$($dataHost.Name)`" has ESX version `"$hostVersion`" (build $hostBuild); expected same as reference version `"$RefVersion`" (build $RefBuild). All data hosts and witness must be the same release."
            return [PSCustomObject]@{ HasMismatch = $true; MismatchDetail = $detail }
        }
        if (-not [String]::IsNullOrWhiteSpace($hostBuild) -and -not [String]::IsNullOrWhiteSpace($RefBuild) -and $hostBuild -ne $RefBuild) {
            $detail = "Cluster host `"$($dataHost.Name)`" has ESX build `"$hostBuild`"; expected build `"$RefBuild`" (version $RefVersion). All data hosts and witness must be the exact same ESX release."
            return [PSCustomObject]@{ HasMismatch = $true; MismatchDetail = $detail }
        }
    }
    return [PSCustomObject]@{ HasMismatch = $false; MismatchDetail = $null }
}
function Confirm-VsanWitnessVersionMatch {

    <#
        .SYNOPSIS
        Validates that the witness host and all cluster data hosts are on the exact same ESX release.

        .DESCRIPTION
        Compares ESX version and build numbers between the witness host and each cluster data host.
        When a mismatch is detected and LabEnvironment is $true, logs a WARNING and returns.
        When a mismatch is detected and LabEnvironment is $false, prompts the user (Y/N); throws
        VcfDeploymentException when the user declines.

        .PARAMETER ClusterHosts
        Array of VMHost objects representing the cluster data hosts.

        .PARAMETER ClusterName
        Cluster name used in thrown exception messages.

        .PARAMETER LabEnvironment
        When $true, logs a WARNING on mismatch instead of prompting for confirmation.

        .PARAMETER vSanWitnessVmName
        Witness host FQDN or IP used in log and exception messages.

        .PARAMETER WitnessHost
        The witness VMHost object whose version and build are compared against the cluster hosts.

        .EXAMPLE
        Confirm-VsanWitnessVersionMatch -WitnessHost $witnessHost -ClusterHosts $clusterHosts -ClusterName "cl0" -vSanWitnessVmName "witness01.example.com" -LabEnvironment:$false

        .NOTES
        Throws VcfDeploymentException when the user declines continuation on a version/build mismatch.
        When ESX version or build cannot be read from the witness or reference host, a WARNING is logged
        and strict version checking is skipped.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object[]]$ClusterHosts,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [Switch]$LabEnvironment,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$vSanWitnessVmName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$WitnessHost
    )

    $witnessVersion = $null
    $witnessBuild = $null
    if ($WitnessHost.PSObject.Properties['Version']) { $witnessVersion = [String]$WitnessHost.Version }
    if ([String]::IsNullOrWhiteSpace($witnessVersion) -and $WitnessHost.ExtensionData -and $WitnessHost.ExtensionData.Config -and $WitnessHost.ExtensionData.Config.Product) { $witnessVersion = [String]$WitnessHost.ExtensionData.Config.Product.Version }
    if ($WitnessHost.PSObject.Properties['Build']) { $witnessBuild = [String]$WitnessHost.Build }
    if ([String]::IsNullOrWhiteSpace($witnessBuild) -and $WitnessHost.ExtensionData -and $WitnessHost.ExtensionData.Config -and $WitnessHost.ExtensionData.Config.Product) { $witnessBuild = [String]$WitnessHost.ExtensionData.Config.Product.Build }

    $referenceHost = $ClusterHosts[0]
    $refVersion = $null
    $refBuild = $null
    if ($referenceHost.PSObject.Properties['Version']) { $refVersion = [String]$referenceHost.Version }
    if ([String]::IsNullOrWhiteSpace($refVersion) -and $referenceHost.ExtensionData -and $referenceHost.ExtensionData.Config -and $referenceHost.ExtensionData.Config.Product) { $refVersion = [String]$referenceHost.ExtensionData.Config.Product.Version }
    if ($referenceHost.PSObject.Properties['Build']) { $refBuild = [String]$referenceHost.Build }
    if ([String]::IsNullOrWhiteSpace($refBuild) -and $referenceHost.ExtensionData -and $referenceHost.ExtensionData.Config -and $referenceHost.ExtensionData.Config.Product) { $refBuild = [String]$referenceHost.ExtensionData.Config.Product.Build }

    if ([String]::IsNullOrWhiteSpace($witnessVersion) -or [String]::IsNullOrWhiteSpace($refVersion)) {
        Write-LogMessage -Type WARNING -Message "Could not read ESX version for version check (witness or cluster host). Skipping strict version check."
        return
    }

    $versionMismatch = $false
    $mismatchDetail = $null
    if ($witnessVersion -ne $refVersion) {
        $versionMismatch = $true
        $mismatchDetail = "Witness `"$vSanWitnessVmName`" has ESX version `"$witnessVersion`" (build $witnessBuild); cluster data hosts have version `"$refVersion`" (build $refBuild). All must be the same release."
    }
    if (-not $versionMismatch -and -not [String]::IsNullOrWhiteSpace($witnessBuild) -and -not [String]::IsNullOrWhiteSpace($refBuild) -and $witnessBuild -ne $refBuild) {
        $versionMismatch = $true
        $mismatchDetail = "Witness `"$vSanWitnessVmName`" has ESX build `"$witnessBuild`" (version $witnessVersion); cluster data hosts have build `"$refBuild`" (version $refVersion). Data nodes and witness must be the exact same ESX release (same build number)."
    }
    if (-not $versionMismatch) {
        $dataHostCheck = Test-VsanDataHostVersionConsistency -ClusterHosts $ClusterHosts -RefVersion $refVersion -RefBuild $refBuild
        if ($dataHostCheck.HasMismatch) {
            $versionMismatch = $true
            $mismatchDetail  = $dataHostCheck.MismatchDetail
        }
    }

    if (-not $versionMismatch) {
        Write-LogMessage -Type DEBUG -Message "Witness and cluster hosts have matching ESX release (version $refVersion, build $refBuild)."
        return
    }

    if ($LabEnvironment) {
        Write-LogMessage -Type WARNING -Message "ESX version/build mismatch (lab environment; continuing without prompt): $mismatchDetail."
        return
    }

    Write-LogMessage -Type ERROR -Message "ESX version/build mismatch: $mismatchDetail."
    $continueAnyway = $false
    $continuePrompt = "Witness and data hosts have different ESX builds. Continue anyway? (Y/N; press Enter for N)"
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

    if (-not $continueAnyway) {
        $errorMsg = "Deployment failed configuring vSAN witness for cluster `"$ClusterName`": $mismatchDetail Upgrade or patch the witness and data hosts to the same ESX release (same build number), then re-run. The deployment will be rolled back."
        Write-LogMessage -Type ERROR -Message $errorMsg
        throw [VcfDeploymentException]::new($errorMsg)
    }
}
function Resolve-VsanPreferredFaultDomain {

    <#
        .SYNOPSIS
        Resolves or creates the preferred vSAN fault domain for a stretched cluster.

        .DESCRIPTION
        Attempts to resolve the preferred fault domain by name "Primary" first, then by the
        caller-provided PreferredFaultDomainName, and finally by VMHost. When no fault domains
        exist at all, creates a "Primary" (preferred) and "Secondary" fault domain pair and
        returns the preferred one. Returns $null when existing fault domains are present but
        none match the expected names or host.

        .PARAMETER Cluster
        The cluster object obtained from Get-Cluster.

        .PARAMETER ClusterHosts
        Array of VMHost objects in the cluster. The first host is assigned to the "Primary"
        fault domain when creating fault domains.

        .PARAMETER ClusterName
        Cluster name used in exception messages.

        .PARAMETER PreferredFaultDomainName
        Caller-provided name to resolve (e.g. edge site name). "Primary" is always tried first.

        .PARAMETER PreferredHost
        The first cluster host, used when resolving by VMHost and when creating the primary
        fault domain.

        .PARAMETER Server
        vCenter server name.

        .EXAMPLE
        $faultDomain = Resolve-VsanPreferredFaultDomain -Cluster $cluster -ClusterHosts $clusterHosts -ClusterName "cl0" -PreferredFaultDomainName "site1" -PreferredHost $clusterHosts[0] -Server $Script:vCenterName

        .NOTES
        Get-VsanFaultDomain and New-VsanFaultDomain emit VMHost.State deprecation warnings that
        do not accept -WarningAction. Each call uses -WarningAction SilentlyContinue directly.
        Returns $null when existing fault domains are present but none match — the caller must
        log a warning and decide whether to proceed without a preferred fault domain.
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$Cluster,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object[]]$ClusterHosts,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$PreferredFaultDomainName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$PreferredHost,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Server
    )

    $primaryFaultDomainName = "Primary"
    $secondaryFaultDomainName = "Secondary"
    $preferredFaultDomain = $null

    try {
        $preferredFaultDomain = Get-VsanFaultDomain -Cluster $Cluster -Name $primaryFaultDomainName -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $preferredFaultDomain -and $PreferredFaultDomainName -ne $primaryFaultDomainName) {
            $preferredFaultDomain = Get-VsanFaultDomain -Cluster $Cluster -Name $PreferredFaultDomainName -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue | Select-Object -First 1
        }
        if (-not $preferredFaultDomain) {
            $preferredFaultDomain = Get-VsanFaultDomain -Cluster $Cluster -VMHost $PreferredHost -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($preferredFaultDomain) {
                Write-LogMessage -Type DEBUG -Message "Resolved preferred fault domain by VMHost: `"$($preferredFaultDomain.Name)`" (Id: $($preferredFaultDomain.Id))."
            }
        } else {
            Write-LogMessage -Type DEBUG -Message "Resolved preferred fault domain by name: `"$($preferredFaultDomain.Name)`" (Id: $($preferredFaultDomain.Id))."
        }
    } catch {
        Write-LogMessage -Type DEBUG -Message "Could not resolve VsanFaultDomain (Get-VsanFaultDomain): $($_.Exception.Message). Proceeding without -PreferredFaultDomain."
    }

    if ($preferredFaultDomain) {
        return $preferredFaultDomain
    }

    $existingFaultDomains = Get-VsanFaultDomain -Cluster $Cluster -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
    if ($existingFaultDomains -and $existingFaultDomains.Count -gt 0) {
        Write-LogMessage -Type WARNING -Message "Could not resolve VsanFaultDomain for name `"$primaryFaultDomainName`" or `"$PreferredFaultDomainName`" or for host `"$($PreferredHost.Name)`". Cluster has $($existingFaultDomains.Count) fault domain(s) but none match. Ensure preferred fault domain name matches an existing fault domain or create fault domains with New-VsanFaultDomain. Set-VsanClusterConfiguration may fail with preferred fault domain not specified."
        return $null
    }

    Write-LogMessage -Type INFO -Message "No vSAN fault domains found for cluster `"$ClusterName`". Creating FDs `"$primaryFaultDomainName`" and `"$secondaryFaultDomainName`"."
    try {
        New-VsanFaultDomain -Name $primaryFaultDomainName -VMHost $PreferredHost -Server $Server -WarningAction SilentlyContinue -ErrorAction Stop | Out-Null
        Write-LogMessage -Type DEBUG -Message "Created fault domain `"$primaryFaultDomainName`" (preferred) with host `"$($PreferredHost.Name)`"."
        $remainingHosts = $ClusterHosts | Where-Object { $_.Id -ne $PreferredHost.Id }
        if ($remainingHosts -and $remainingHosts.Count -gt 0) {
            New-VsanFaultDomain -Name $secondaryFaultDomainName -VMHost $remainingHosts -Server $Server -WarningAction SilentlyContinue -ErrorAction Stop | Out-Null
            Write-LogMessage -Type DEBUG -Message "Created fault domain `"$secondaryFaultDomainName`" with host(s): $(($remainingHosts | Select-Object -ExpandProperty Name) -join ', ')."
        }
        $preferredFaultDomain = Get-VsanFaultDomain -Cluster $Cluster -Name $primaryFaultDomainName -Server $Server -WarningAction SilentlyContinue -ErrorAction Stop | Select-Object -First 1
        if ($preferredFaultDomain) {
            Write-LogMessage -Type DEBUG -Message "Resolved preferred fault domain after creation: `"$($preferredFaultDomain.Name)`" (Id: $($preferredFaultDomain.Id))."
        }
        return $preferredFaultDomain
    } catch [VcfDeploymentException] {
        throw  # already logged and typed — propagate without re-wrapping
    } catch {
        $err = "Failed to create vSAN fault domains for cluster `"$ClusterName`": $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
}
function Invoke-WitnessFaultDomainSetup {

    <#
        .SYNOPSIS
        Resolves or creates the vSAN preferred fault domain and activates stretched cluster mode.

        .DESCRIPTION
        Performs the three-phase witness activation after all pre-condition checks pass:
        (1) Resolves or creates the preferred fault domain via Resolve-VsanPreferredFaultDomain.
        (2) Enables vSAN automatic disk claim when the cmdlet supports it, then re-fetches the
            cluster configuration if the claim mode changed.
        (3) Calls Set-VsanClusterConfiguration to enable stretched cluster mode with the witness
            host and preferred fault domain, then verifies the result and runs post-configuration
            tasks (automatic rebalance, config re-apply, partition check).

        .PARAMETER Cluster
        The cluster object returned by Get-Cluster.

        .PARAMETER ClusterHosts
        Array of VMHost objects in the cluster, used when creating new fault domains.

        .PARAMETER ClusterName
        The name of the cluster. Used for logging and vSAN cmdlet calls.

        .PARAMETER PreferredFaultDomainName
        Name used to resolve an existing preferred fault domain (e.g. edge site name). When fault
        domains are newly created, the preferred is named "Primary".

        .PARAMETER PreferredHost
        The first ESX host in the cluster; assigned to the "Primary" fault domain on creation.

        .PARAMETER VsanClusterConfig
        The current vSAN cluster configuration object. Internally superseded when
        Enable-VsanAutomaticDiskClaimIfSupported triggers a config change.

        .PARAMETER vSanWitnessVmName
        FQDN or IP of the witness host. Used for logging and post-configuration verification.

        .PARAMETER WitnessHost
        The VMHost object for the witness host.

        .NOTES
        Called exclusively by Set-VsanWitness after all pre-condition checks pass and the
        idempotency guard confirms the witness is not yet configured. Any thrown
        VcfDeploymentException is caught by the outer try/catch in Set-VsanWitness.
    
        .EXAMPLE
        Invoke-WitnessFaultDomainSetup -Cluster $clusterObject -ClusterHosts $inputObject -ClusterName "edge-cluster-1" -PreferredFaultDomainName "resource-name"
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] $Cluster,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] $ClusterHosts,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$PreferredFaultDomainName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] $PreferredHost,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] $VsanClusterConfig,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$vSanWitnessVmName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] $WitnessHost
    )

    $preferredFaultDomain = Resolve-VsanPreferredFaultDomain `
        -Cluster $Cluster `
        -ClusterHosts $ClusterHosts `
        -ClusterName $ClusterName `
        -PreferredFaultDomainName $PreferredFaultDomainName `
        -PreferredHost $PreferredHost `
        -Server $Script:vCenterName

    # Re-fetch vSAN cluster config if automatic disk claim was just enabled so Set-VsanClusterConfiguration receives the latest configuration object.
    if (Enable-VsanAutomaticDiskClaimIfSupported -ClusterName $ClusterName) {
        $VsanClusterConfig = Get-VsanClusterConfiguration -Cluster $ClusterName -Server $Script:vCenterName -ErrorAction Stop
    }

    # Per vSAN Stretched Cluster Guide: validate connectivity between data hosts and witness before/after configuration (UDP 23451/12321, vmkping from each site to witness vSAN VMkernel IP).
    Write-LogMessage -Type INFO -Message "Ensure connectivity between cluster hosts and witness through vSAN Witness VMkernel interface."
    if (-not $preferredFaultDomain) {
        Write-LogMessage -Type WARNING -Message "Preferred fault domain not resolved. Set-VsanClusterConfiguration may fail with preferred fault domain not specified."
    }
    Write-LogMessage -Type DEBUG -Message "Attempting Set-VsanClusterConfiguration for cluster `"$ClusterName`" with vSanWitnessVmName=`"$vSanWitnessVmName`", preferred fault domain host=`"$($PreferredHost.Name)`", PreferredFaultDomain resolved=$($null -ne $preferredFaultDomain)."
    Write-LogMessage -Type INFO -Message "Enabling stretched cluster mode and configuring witness host `"$vSanWitnessVmName`" for cluster `"$ClusterName`"..."

    $progressActivity = "Configuring vSAN witness for cluster `"$ClusterName`""
    try {
        Write-Progress -Activity $progressActivity -Status "Enabling stretched cluster mode and configuring witness host. This may take several minutes..." -PercentComplete -1
        [Console]::Out.Flush()
        $setParams = @{
            Configuration           = $VsanClusterConfig
            StretchedClusterEnabled = $true
            WitnessHost             = $WitnessHost
            Server                  = $Script:vCenterName
        }
        if ($preferredFaultDomain) {
            $setParams["PreferredFaultDomain"] = $preferredFaultDomain
        }
        # Per vSAN Stretched Cluster Guide: enable Site Read Locality so reads come from the local site and reduce traffic across the ISL.
        if ((Get-Command Set-VsanClusterConfiguration -ErrorAction SilentlyContinue).Parameters.ContainsKey("SiteReadLocalityEnabled")) {
            $setParams["SiteReadLocalityEnabled"] = $true
            Write-LogMessage -Type DEBUG -Message "Enabling Site Read Locality on stretched cluster per vSAN Stretched Cluster Guide."
        }
        # -WarningAction SilentlyContinue suppresses VMHost.State deprecation warnings emitted by this cmdlet.
        Set-VsanClusterConfiguration @setParams -WarningAction SilentlyContinue -ErrorAction Stop | Out-Null
    }
    finally {
        Write-Progress -Activity $progressActivity -Status "Complete" -Completed
        [Console]::Out.Flush()
    }

    $updatedConfig = Get-VsanClusterConfiguration -Cluster $ClusterName -Server $Script:vCenterName -ErrorAction SilentlyContinue
    if ($updatedConfig -and $updatedConfig.WitnessHost -and $updatedConfig.WitnessHost.Name -eq $vSanWitnessVmName) {
        Write-LogMessage -Type INFO -Message "Successfully configured witness host `"$vSanWitnessVmName`" for cluster `"$ClusterName`"."
        $rebalanceEnabled = Enable-VsanAutomaticRebalance -ClusterName $ClusterName -AutomaticRebalanceThreshold 30
        if ($rebalanceEnabled -and -not (Test-VsanAutomaticRebalanceAtThreshold -ClusterName $ClusterName -ExpectedThresholdPercent 30)) {
            Write-LogMessage -Type DEBUG -Message "vSAN automatic rebalance at 30% may not be applied on cluster `"$ClusterName`"; config re-apply will push cluster settings."
        }
        $reapplySucceeded = Invoke-VsanClusterConfigReapply -ClusterName $ClusterName
        if ($reapplySucceeded) {
            Write-LogMessage -Type DEBUG -Message "Re-applied vSAN config after witness setup to help witness sync with cluster (reduce partition risk)."
        }
        # Check for partition per vSAN Stretched Cluster Guide; if connectivity or routing is wrong, the cluster can end up in multiple partitions.
        $healthSummary = Get-VsanClusterHealthSummaryViaView -ClusterName $ClusterName -FetchFromCache
        if ($healthSummary -and (Test-VsanClusterPartitioned -HealthSummary $healthSummary)) {
            Write-LogMessage -Type ERROR -Message "vSAN cluster `"$ClusterName`" appears partitioned after witness configuration. Ensure the witness is at a third site, data hosts can reach the witness vSAN VMkernel (vmkping), and UDP 23451/12321 are allowed. See vSAN Stretched Cluster Guide (vmware.com/docs/vsan-stretched-cluster-guide)."
        }
    } else {
        Write-LogMessage -Type WARNING -Message "Witness host configuration may not have been applied correctly. Verification failed."
    }
}
function Confirm-VsanWitnessConfiguration {

    <#
        .SYNOPSIS
        Validates OVA type, disk configuration, and memory requirements for a vSAN witness host.

        .DESCRIPTION
        Checks that the witness host was deployed from the correct witness OVA (OSA vs ESA), has the disk
        configuration matching the requested storage type (OSA: disk group required; ESA: storage pool
        optional), and meets the minimum memory requirement for the storage type (OSA: 8 GB; ESA: 16 GB).

        .PARAMETER ClusterName
        The vSAN cluster name; used in exception messages only.

        .PARAMETER StoragePolicyType
        The vSAN storage type: vSAN-OSA or vSAN-ESA.

        .PARAMETER vSanWitnessVmName
        The FQDN or IP of the witness host; used in log and error messages.

        .PARAMETER WitnessHost
        The PowerCLI VMHost object representing the witness host.

        .EXAMPLE
        Confirm-VsanWitnessConfiguration -ClusterName "cl0-site1" -StoragePolicyType "vSAN-ESA" -vSanWitnessVmName "10.1.1.10" -WitnessHost $witnessHost

        Validates the witness has the correct ESA OVA, no OSA disk group, and at least 16 GB of memory.

        .NOTES
        Throws [VcfDeploymentException] when any validation fails.
        Minimum memory by StoragePolicyType: OSA 8 GB; ESA 16 GB.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateSet("vSAN-ESA", "vSAN-OSA")] [String]$StoragePolicyType,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$vSanWitnessVmName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$WitnessHost
    )

    $minimumMemoryGB = if ($StoragePolicyType -eq "vSAN-ESA") { 16 } else { 8 }

    # OVA type check: 1=OSA witness OVA, 2=ESA witness OVA. If mismatched, the user deployed the wrong OVA.
    $hostDeployedFromWitnessOvf = $null
    try {
        $advSetting = Get-AdvancedSetting -Entity $WitnessHost -Name "VSAN.HostDeployedFromWitnessOVF" -ErrorAction SilentlyContinue
        if ($advSetting -and $null -ne $advSetting.Value) {
            $hostDeployedFromWitnessOvf = [Int]$advSetting.Value
            Write-LogMessage -Type DEBUG -Message "Witness host `"$vSanWitnessVmName`" HostDeployedFromWitnessOVF=$hostDeployedFromWitnessOvf (1=OSA witness OVA, 2=ESA witness OVA)."
        }
    } catch {
        Write-LogMessage -Type DEBUG -Message "Could not read HostDeployedFromWitnessOVF from witness `"$vSanWitnessVmName`": $($_.Exception.Message). Skipping OVA-type check."
    }
    if ($null -ne $hostDeployedFromWitnessOvf) {
        if ($StoragePolicyType -eq "vSAN-OSA" -and $hostDeployedFromWitnessOvf -eq 2) {
            $err = "Witness host `"$vSanWitnessVmName`" was deployed from the vSAN ESA witness OVA (HostDeployedFromWitnessOVF=2). For an OSA cluster use the vSAN OSA witness appliance OVA."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
        if ($StoragePolicyType -eq "vSAN-ESA" -and $hostDeployedFromWitnessOvf -eq 1) {
            $err = "Witness host `"$vSanWitnessVmName`" was deployed from the vSAN OSA witness OVA (HostDeployedFromWitnessOVF=1). For an ESA cluster use the vSAN ESA witness appliance OVA."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
    }

    # Fail if witness disk layout does not match requested storage type (OSA vs ESA). Prevents using an OSA witness for ESA or vice versa.
    if ($StoragePolicyType -eq "vSAN-ESA") {
        $witnessOsaResult = Get-VsanOsaDiskGroupsOnHost -VMHost $WitnessHost -Server $Script:vCenterName
        if ($witnessOsaResult.HasValidOsaGroup) {
            $err = "Witness host `"$vSanWitnessVmName`" has a vSAN OSA disk group (cache + capacity). This witness is for vSAN OSA, not ESA. Use an ESA witness or remove the OSA disk group from this host."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
    } elseif ($StoragePolicyType -eq "vSAN-OSA") {
        $witnessPoolDisks = Get-VsanStoragePoolDisk -VMHost $WitnessHost -Server $Script:vCenterName -ErrorAction SilentlyContinue
        $witnessEsaPoolCount = if ($witnessPoolDisks) { @($witnessPoolDisks).Count } else { 0 }
        if ($witnessEsaPoolCount -ge 1) {
            $err = "Witness host `"$vSanWitnessVmName`" has a vSAN ESA storage pool (all-flash). This witness is for vSAN ESA, not OSA. Use an OSA witness or remove the ESA storage pool from this host."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
    }

    $witnessMemoryGB = $WitnessHost.MemoryTotalGB
    if ($witnessMemoryGB -lt $minimumMemoryGB) {
        $err = "Witness host `"$vSanWitnessVmName`" has $witnessMemoryGB GB memory; $StoragePolicyType requires at least $minimumMemoryGB GB to enable a witness."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }

    # Enforce disk configuration: ESA may have zero storage pool disks (supported); OSA requires a disk group with cache + capacity.
    if ($StoragePolicyType -eq "vSAN-ESA") {
        $witnessPoolDisks = Get-VsanStoragePoolDisk -VMHost $WitnessHost -Server $Script:vCenterName -ErrorAction SilentlyContinue
        $witnessPoolDiskCount = if ($witnessPoolDisks) { @($witnessPoolDisks).Count } else { 0 }
        Write-LogMessage -Type DEBUG -Message "Witness host `"$vSanWitnessVmName`" has $witnessPoolDiskCount vSAN ESA storage pool disk(s). ESA witness with zero disks is supported."
    } elseif ($StoragePolicyType -eq "vSAN-OSA") {
        $witnessOsaResult = Get-VsanOsaDiskGroupsOnHost -VMHost $WitnessHost -Server $Script:vCenterName
        if ($witnessOsaResult.DiskGroupCount -lt 1) {
            $err = "Witness host `"$vSanWitnessVmName`" has no vSAN OSA disk group. A vSAN witness for OSA requires a disk group with one cache and one capacity disk. Create a disk group on the witness host, then re-run."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
        if (-not $witnessOsaResult.HasValidOsaGroup) {
            $err = "Witness host `"$vSanWitnessVmName`" has vSAN OSA disk group(s) but none has both cache and capacity. A vSAN witness for OSA requires one cache (SSD) and one capacity disk. Add the required disks to a disk group on the witness host, then re-run."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
        Write-LogMessage -Type DEBUG -Message "Witness host `"$vSanWitnessVmName`" has $($witnessOsaResult.DiskGroupCount) vSAN OSA disk group(s) with valid cache and capacity."
    }
}
function Invoke-EnsureWitnessVsanTraffic {

    <#
        .SYNOPSIS
        Ensures vSAN traffic is enabled on the witness host's VMkernel interface.

        .DESCRIPTION
        Checks whether the witness host has a VMkernel adapter with vSAN traffic enabled.
        If not, enables vSAN traffic on vmk0 (the witness host requires vSAN traffic for quorum
        participation). Per Broadcom documentation, the witness traffic type must NOT be configured
        on the witness host itself; only vSAN traffic is required.

        .PARAMETER ClusterName
        The vSAN cluster name; used in exception messages only.

        .PARAMETER vSanWitnessVmName
        The FQDN or IP of the witness host; used in log and error messages.

        .PARAMETER WitnessHost
        The PowerCLI VMHost object representing the witness host.

        .EXAMPLE
        Invoke-EnsureWitnessVsanTraffic -ClusterName "cl0-site1" -vSanWitnessVmName "10.1.1.10" -WitnessHost $witnessHost

        Ensures the witness host has at least one VMkernel with vSAN traffic enabled.

        .NOTES
        Throws [VcfDeploymentException] when vSAN traffic cannot be enabled or verified.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$vSanWitnessVmName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$WitnessHost
    )

    $witnessVsanCheck = Test-VmkernelVsanAndWitnessTraffic -VMHost $WitnessHost -RequireWitnessTraffic $false
    if (-not $witnessVsanCheck.HasCompliantInterface -and $witnessVsanCheck.Vmk0Adapter) {
        try {
            # Witness host only needs vSAN traffic on vmk0; do not set witness traffic type on the witness host (per Broadcom docs).
            $witnessSetParams = @{ VirtualNic = $witnessVsanCheck.Vmk0Adapter; VsanTrafficEnabled = $true }
            Set-VMHostNetworkAdapter @witnessSetParams -Confirm:$false -WarningAction SilentlyContinue -ErrorAction Stop | Out-Null
            Write-LogMessage -Type INFO -Message "vSAN witness host `"$vSanWitnessVmName`" had no VMkernel with vSAN traffic enabled; vSAN traffic has been enabled on vmk0."
        } catch [VcfDeploymentException] {
            throw  # already logged and typed — propagate without re-wrapping
        } catch {
            $err = "Failed to enable vSAN traffic on vmk0 on witness host `"$vSanWitnessVmName`": $($_.Exception.Message). vSAN traffic is required for the witness; deployment will roll back."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
        $witnessRecheck = Test-VmkernelVsanAndWitnessTraffic -VMHost $WitnessHost -RequireWitnessTraffic $false
        if (-not $witnessRecheck.HasCompliantInterface) {
            $err = "After enabling vSAN traffic on witness host `"$vSanWitnessVmName`", interface is still not tagged. vSAN traffic is required for the witness; deployment will roll back."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
    } elseif (-not $witnessVsanCheck.HasCompliantInterface) {
        $err = "Witness host `"$vSanWitnessVmName`" has no VMkernel with vSAN traffic enabled and vmk0 was not found. vSAN traffic is required for the witness; deployment will roll back."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
}
function Confirm-VsanClusterReadinessForWitness {

    <#
        .SYNOPSIS
        Retrieves cluster hosts, validates version compatibility with the witness, confirms the witness is not a cluster member, and verifies vSAN traffic on each data host.

        .DESCRIPTION
        Retrieves all VMHost objects in the cluster. Calls Confirm-VsanWitnessVersionMatch to verify
        all data hosts and the witness are on the same ESX release. Confirms the witness host is not a
        member of the cluster (required by the vSAN Stretched Cluster Guide). Checks that each data host
        has a VMkernel with both vSAN and vSAN witness traffic enabled. Returns the cluster hosts and the
        preferred (first) host for fault domain assignment.

        .PARAMETER Cluster
        The PowerCLI Cluster object.

        .PARAMETER ClusterName
        The name of the vSAN cluster; used in log and error messages.

        .PARAMETER LabEnvironment
        When $true, version mismatches are logged as WARNING without prompting.

        .PARAMETER vSanWitnessVmName
        The FQDN or IP of the witness host; used in log and error messages.

        .PARAMETER WitnessHost
        The PowerCLI VMHost object representing the witness host.

        .EXAMPLE
        $setup = Confirm-VsanClusterReadinessForWitness -Cluster $cluster -ClusterName "cl0-site1" -LabEnvironment:$false -vSanWitnessVmName "10.1.1.10" -WitnessHost $witnessHost
        $clusterHosts  = $setup.ClusterHosts
        $preferredHost = $setup.PreferredHost

        Returns ClusterHosts and PreferredHost after all validation passes.

        .NOTES
        Throws [VcfDeploymentException] when: cluster has no hosts; witness is a cluster member; or any data host lacks the required VMkernel traffic types or IP.
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$Cluster,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [Switch]$LabEnvironment,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$vSanWitnessVmName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$WitnessHost
    )

    Write-LogMessage -Type DEBUG -Message "Retrieving ESX hosts in cluster `"$ClusterName`"."
    $clusterHosts = Get-VMHost -Location $Cluster -Server $Script:vCenterName -ErrorAction Stop
    if (-not $clusterHosts -or $clusterHosts.Count -eq 0) {
        $err = "Cluster `"$ClusterName`" does not contain any hosts."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }

    Confirm-VsanWitnessVersionMatch `
        -ClusterHosts $clusterHosts `
        -ClusterName $ClusterName `
        -LabEnvironment:$LabEnvironment.IsPresent `
        -vSanWitnessVmName $vSanWitnessVmName `
        -WitnessHost $WitnessHost

    # Per vSAN Stretched Cluster Guide: the witness host must not be a member of any cluster. Having the witness in the cluster can cause partitioning or undefined behavior.
    $witnessMoRefValue = $null
    if ($WitnessHost.ExtensionData -and $WitnessHost.ExtensionData.MoRef) {
        $witnessMoRefValue = $WitnessHost.ExtensionData.MoRef.Value
    }
    $witnessIsInCluster = $false
    if ($witnessMoRefValue) {
        $witnessIsInCluster = @($clusterHosts | Where-Object { $_.ExtensionData -and $_.ExtensionData.MoRef -and $_.ExtensionData.MoRef.Value -eq $witnessMoRefValue }).Count -gt 0
    }
    if (-not $witnessIsInCluster) {
        $witnessIsInCluster = @($clusterHosts | Where-Object { $_.Id -eq $WitnessHost.Id -or $_.Name -eq $WitnessHost.Name }).Count -gt 0
    }
    if ($witnessIsInCluster) {
        $err = "Witness host `"$vSanWitnessVmName`" is a member of cluster `"$ClusterName`". Per the vSAN Stretched Cluster Guide, the witness must not be a member of any cluster; it must reside in vCenter inventory outside the cluster. Remove the witness host from the cluster, then re-run."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }

    # Ensure every cluster host has vSAN (and witness) traffic; vmk0 is mgmt + vSAN witness only (no vSAN). Clear vSAN from vmk0 if present.
    foreach ($dataHost in @($clusterHosts)) {
        $dataHostName = $dataHost.Name
        $vmk0 = Get-VMHostNetworkAdapter -VMHost $dataHost -VMKernel -Server $Script:vCenterName -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq "vmk0" }
        if ($vmk0 -and $vmk0.PSObject.Properties["VsanTrafficEnabled"] -and $vmk0.VsanTrafficEnabled -eq $true) {
            try {
                Set-VMHostNetworkAdapter -VirtualNic $vmk0 -VsanTrafficEnabled $false -Confirm:$false -WarningAction SilentlyContinue -ErrorAction Stop | Out-Null
                Write-LogMessage -Type INFO -Message "Cleared vSAN traffic from mgmt (vmk0) on host `"$dataHostName`" (vmk0 is mgmt + vSAN witness only)."
            } catch {
                Write-LogMessage -Type WARNING -Message "Could not clear vSAN from vmk0 on host `"$dataHostName`": $($_.Exception.Message). Clear manually if needed."
            }
        }
        $vsanCheck = Test-VmkernelVsanAndWitnessTraffic -VMHost $dataHost
        if (-not $vsanCheck.HasCompliantInterface) {
            $err = "Cluster host `"$dataHostName`" has no VMkernel with vSAN and vSAN witness traffic enabled. Use vmk2 (or vmk3) for vSAN; vmk0 may carry vSAN witness only."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
        if (-not (Test-VsanTrafficVmkernelHasValidIp -VMHost $dataHost)) {
            $err = "Cluster host `"$dataHostName`" has vSAN traffic enabled but the VMkernel has no IPv4 or IPv6 address configured."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
    }

    $preferredHost = $clusterHosts[0]
    Write-LogMessage -Type DEBUG -Message "Using first ESX host `"$($preferredHost.Name)`" as preferred fault domain host."
    return [PSCustomObject]@{ ClusterHosts = $clusterHosts; PreferredHost = $preferredHost }
}
function Set-VsanWitness {

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
        [Parameter(Mandatory = $false)] [Switch]$LabEnvironment,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$PreferredFaultDomainName,
        [Parameter(Mandatory = $true)] [ValidateSet("vSAN-ESA", "vSAN-OSA")] [String]$StoragePolicyType,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$vSanWitnessVmName
    )

    Write-LogMessage -Type DEBUG -Message "Entered Set-VsanWitness function for cluster: `"$ClusterName`" with witness host: `"$vSanWitnessVmName`", preferred fault domain: `"$PreferredFaultDomainName`", storage type: `"$StoragePolicyType`"."

    $connectionTest = Test-VcenterConnection
    if (-not $connectionTest.IsConnected) {
        $err = "Not connected to vCenter `"$Script:vCenterName`": $($connectionTest.ErrorMessage)"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }

    try {
        Write-LogMessage -Type DEBUG -Message "Retrieving cluster object for cluster `"$ClusterName`"."
        $cluster = Get-Cluster -Name $ClusterName -Server $Script:vCenterName -ErrorAction Stop
        if (-not $cluster) {
            $err = "Failed to retrieve cluster `"$ClusterName`"."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }

        Write-LogMessage -Type DEBUG -Message "Retrieving witness host object for `"$vSanWitnessVmName`"."
        $witnessHost = Get-VMHost -Name $vSanWitnessVmName -Server $Script:vCenterName -ErrorAction Stop
        if (-not $witnessHost) {
            $err = "Failed to retrieve witness host `"$vSanWitnessVmName`"."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }

        Confirm-VsanWitnessConfiguration `
            -ClusterName $ClusterName `
            -StoragePolicyType $StoragePolicyType `
            -vSanWitnessVmName $vSanWitnessVmName `
            -WitnessHost $witnessHost

        Invoke-EnsureWitnessVsanTraffic `
            -ClusterName $ClusterName `
            -vSanWitnessVmName $vSanWitnessVmName `
            -WitnessHost $witnessHost

        $clusterSetup = Confirm-VsanClusterReadinessForWitness `
            -Cluster $cluster `
            -ClusterName $ClusterName `
            -LabEnvironment:$LabEnvironment.IsPresent `
            -vSanWitnessVmName $vSanWitnessVmName `
            -WitnessHost $witnessHost
        $clusterHosts  = $clusterSetup.ClusterHosts
        $preferredHost = $clusterSetup.PreferredHost

        Write-LogMessage -Type DEBUG -Message "Retrieving current vSAN cluster configuration for cluster `"$ClusterName`"."
        $vsanClusterConfig = Get-VsanClusterConfiguration -Cluster $ClusterName -Server $Script:vCenterName -ErrorAction Stop
        if (-not $vsanClusterConfig) {
            $err = "Failed to retrieve vSAN cluster configuration for cluster `"$ClusterName`"."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }

        if ($vsanClusterConfig.WitnessHost -and $vsanClusterConfig.WitnessHost.Name -eq $vSanWitnessVmName) {
            Write-LogMessage -Type INFO -Message "Witness host `"$vSanWitnessVmName`" is already configured for cluster `"$ClusterName`"."
            return
        }

        Invoke-WitnessFaultDomainSetup `
            -Cluster $cluster `
            -ClusterHosts $clusterHosts `
            -ClusterName $ClusterName `
            -PreferredFaultDomainName $PreferredFaultDomainName `
            -PreferredHost $preferredHost `
            -VsanClusterConfig $vsanClusterConfig `
            -vSanWitnessVmName $vSanWitnessVmName `
            -WitnessHost $witnessHost
    } catch {
        $errorMessage = $_.Exception.Message
        $reason = Get-CleanVsanErrorMessage -ErrorMessage $errorMessage
        if ($reason -eq $errorMessage) {
            if ($_.Exception -is [System.UnauthorizedAccessException]) { $reason = "authorization error. $errorMessage" }
            elseif ($_.Exception -is [System.TimeoutException]) { $reason = "network/timeout. $errorMessage" }
        }
        $cleanMessage = "Failed to configure vSAN witness for cluster `"$ClusterName`". Reason: $reason"
        Write-LogMessage -Type ERROR -Message $cleanMessage
        if ($errorMessage -match "preferred fault domain|witness host is not specified|witness.*not specified") {
            Write-LogMessage -Type ERROR -Message "vSAN stretched cluster requires both a witness host and a preferred fault domain. Ensure common.vSanWitnessVmName (or cluster-level clusters[].vSanWitnessVmName) and the preferred fault domain name (e.g. edge site name) are set. If the API still reports missing preferred fault domain, the PowerCLI/API version may not expose it; check VCF PowerCLI documentation for Set-VsanClusterConfiguration."
        }
        if ($errorMessage -match "ESA disabled cluster|witnessVsan1NotSupported|does not support joining vSAN ESA") {
            Write-LogMessage -Type ERROR -Message "Cluster `"$ClusterName`" does not have vSAN ESA enabled in the vCenter database (vsanEsaEnabled=false). vSAN 9.1+ enforces this before an ESA witness can join. This is usually caused by an existing cluster that predates this requirement. Re-run the deployment script — Add-Cluster now applies Set-Cluster -VsanEsaEnabled automatically. If the cluster is vSAN OSA, delete it and recreate with storageType: vSAN-ESA in infrastructure.json."
        }
        throw [VcfDeploymentException]::new("Deployment failed. $cleanMessage")
    }
}
function Get-VsanClusterHealthSummaryViaView {

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
    
        .EXAMPLE
        $vsanClusterHealthSummaryViaView = Get-VsanClusterHealthSummaryViaView -ClusterName "edge-cluster-1"
    #>
    [OutputType([PSObject])]

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [Switch]$FetchFromCache
    )

    $clusterObject = Get-ClusterByName -Name $ClusterName -Server $Script:vCenterName
    # Validate cluster exists before proceeding.
    if (-not $clusterObject) {
        Write-LogMessage -Type ERROR -Message "Cluster `"$ClusterName`" not found."
        return $null
    }

    $clusterMoRef = $clusterObject.ExtensionData.MoRef
    $healthSystemView = Get-VsanView -Id "VsanVcClusterHealthSystem-vsan-cluster-health-system" -Server $Script:vCenterName -ErrorAction SilentlyContinue
    if (-not $healthSystemView) {
        Write-LogMessage -Type ERROR -Message "Failed to get VsanVcClusterHealthSystem view."
        return $null
    }

    # Get the requested fields for the health summary (include advCfgSync for vCenter-to-host config sync check).
    $requestedFields = @('advCfgSync', 'groups', 'networkHealth', 'overallHealth', 'overallHealthDescription')
    try {
        $healthSummary = $healthSystemView.VsanQueryVcClusterHealthSummary($clusterMoRef, $null, $null, $null, $requestedFields, $FetchFromCache, $null, $null, $null)
        return $healthSummary
    }
    catch {
        Write-LogMessage -Type ERROR -Message "VsanQueryVcClusterHealthSummary failed: $($_.Exception.Message)"
        Write-LogMessage -Type DEBUG -Message "vSAN health summary unavailable; caller will log health_summary_null next steps. Verify vCenter connection and cluster name; ensure VsanVcClusterHealthSystem (vCenter /vsanHealth) is available."
        return $null
    }
}
function Test-VsanClusterPartitioned {

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
    
        .EXAMPLE
        Test-VsanClusterPartitioned -HealthSummary "Operation failed."
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
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
function Write-VsanNetworkHealthDebugInfo {

    <#
    .SYNOPSIS
        Logs DEBUG/WARNING details from a vSAN networkHealth object.
    .DESCRIPTION
        Reports per-context network diagnostics (ping test results, partition list, comm failures,
        disconnected hosts) from the networkHealth property of a vSAN health summary. Partition-
        context fields are logged at WARNING; everything else at DEBUG.
    .PARAMETER ClusterName
        Cluster name used in log messages.
    .PARAMETER Context
        Health-check context string; controls whether partition fields are escalated to WARNING.
    .PARAMETER NetworkHealth
        The networkHealth object from the vSAN health summary.
    .EXAMPLE
        Write-VsanNetworkHealthDebugInfo -ClusterName "cl1" -Context "partition_detected" -NetworkHealth $summary.networkHealth
    .NOTES
        Called from Write-VsanHealthFailureDebugInfo.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Context,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$NetworkHealth
    )

    if ($Context -match 'partition') {
        $diagParts = [System.Collections.Generic.List[String]]::new()
        foreach ($field in @('pingTestSuccess', 'largePingTestSuccess', 'issueFound', 'clusterInUnicastMode', 'vsanVmknicPresent')) {
            $val = $NetworkHealth.$field
            if ($null -ne $val) { $diagParts.Add("$field=$val") }
        }
        if ($diagParts.Count -gt 0) {
            Write-LogMessage -Type WARNING -Message "vSAN cluster `"$ClusterName`" network health: $($diagParts -join ', ')."
        }
    }

    $partitions = $NetworkHealth.partitions
    Write-LogMessage -Type DEBUG -Message "vSAN health debug: networkHealth.partitions count=$(if ($partitions) { $partitions.Count } else { 0 })."
    if ($partitions -and $partitions.Count -gt 0) {
        $partitionSummaries = [System.Collections.Generic.List[String]]::new()
        for ($index = 0; $index -lt $partitions.Count; $index++) {
            $partitionInfo = $partitions[$index]
            $hosts = $partitionInfo.PSObject.Properties['hosts'].Value
            $partitionUnknown = $partitionInfo.PSObject.Properties['partitionUnknown'].Value
            $partitionIdList = if ($hosts -and $hosts.Count -gt 0) { ($hosts -join ', ') } else { '(none)' }
            Write-LogMessage -Type DEBUG -Message "vSAN health debug: partition[$index] partition IDs: $partitionIdList."
            $unknownLabel = if ($partitionUnknown) { ' (unknown to collector)' } else { '' }
            $partitionSummaries.Add("Partition $($index + 1)${unknownLabel}: $partitionIdList")
        }
        Write-LogMessage -Type DEBUG -Message "vSAN cluster `"$ClusterName`" partition (partition IDs per partition): $($partitionSummaries -join '; ')."
    }

    foreach ($fieldInfo in @(
        @{ Field = 'otherHostsInVsanCluster'; Label = 'otherHostsInVsanCluster (hosts in vSAN not in vCenter)'; WarnMsg = "hosts in vSAN but not in vCenter" },
        @{ Field = 'hostsCommFailure';         Label = 'hostsCommFailure';                                       WarnMsg = "hosts with vSAN service comm failure" },
        @{ Field = 'hostsDisconnected';        Label = 'hostsDisconnected';                                      WarnMsg = "hosts disconnected from vCenter" }
    )) {
        $hostList = $NetworkHealth.($fieldInfo.Field)
        if ($hostList -and $hostList.Count -gt 0) {
            $list = $hostList -join ', '
            Write-LogMessage -Type DEBUG -Message "vSAN health debug: $($fieldInfo.Label): $list."
            if ($Context -match 'partition') {
                Write-LogMessage -Type WARNING -Message "vSAN cluster `"$ClusterName`" $($fieldInfo.WarnMsg): $list."
            }
        }
    }
}
function Write-VsanHealthFailureDebugInfo {

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
    
        .EXAMPLE
        Write-VsanHealthFailureDebugInfo -ClusterName "edge-cluster-1" -Context "vcf-context"
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateSet('partition_detected', 'partition_after_repair', 'health_red', 'health_summary_null', 'repair_failed')] [String]$Context,
        [Parameter(Mandatory = $false)] $HealthSummary
    )

    $networkHealth = if ($HealthSummary -and $HealthSummary.networkHealth) { $HealthSummary.networkHealth } else { $null }
    if ($networkHealth) {
        Write-VsanNetworkHealthDebugInfo -ClusterName $ClusterName -Context $Context -NetworkHealth $networkHealth
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
function Test-VsanHealthSuggestsPartitionOrNetwork {

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
    
        .EXAMPLE
        Test-VsanHealthSuggestsPartitionOrNetwork -HealthSummary "Operation failed."
    #>
    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] $HealthSummary
    )

    if (-not $HealthSummary) {
        return $false
    }

    $overallDescription = $HealthSummary.overallHealthDescription
    if ($overallDescription -and ($overallDescription -match 'Network misconfiguration|partition|network')) {
        return $true
    }

    $failureReasonsText = Get-VsanHealthFailureReasons -HealthSummary $HealthSummary
    if ($failureReasonsText -and ($failureReasonsText -match 'Network misconfiguration|partition|network')) {
        return $true
    }

    $networkHealth = $HealthSummary.networkHealth
    if ($networkHealth -and $networkHealth.description -and ($networkHealth.description -match 'Network misconfiguration|partition|network')) {
        return $true
    }
    return $false
}
function Test-VsanClusterAdvCfgSyncInSync {

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
    
        .EXAMPLE
        Test-VsanClusterAdvCfgSyncInSync -HealthSummary "Operation failed."
    #>
    [CmdletBinding()]
    [OutputType([Bool])]
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
function Enable-VsanAutomaticRebalance {

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
    
        .EXAMPLE
        Enable-VsanAutomaticRebalance -ClusterName "edge-cluster-1"
    #>
    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(25, 75)] [Int]$AutomaticRebalanceThreshold = 30,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName
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
function Get-ClusterObjectByName {

    <#
        .SYNOPSIS
        Thin wrapper around Get-Cluster to support mocking in unit tests.

        .DESCRIPTION
        Get-Cluster has an ArgumentTransformationAttribute on its -Server parameter that blocks
        direct mocking. This wrapper accepts plain [String] parameters so tests can mock it with
        a PSCustomObject cluster, following the same pattern as Get-VmkernelAdaptersOnHost.

        .PARAMETER ClusterName
        Name of the cluster to retrieve.

        .PARAMETER Server
        vCenter server name.

        .OUTPUTS
        Cluster object, or throws on error.
    
        .EXAMPLE
        $clusterObjectByName = Get-ClusterObjectByName -ClusterName "edge-cluster-1"
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [String]$Server = $Script:vCenterName
    )

    Get-Cluster -Name $ClusterName -Server $Server -ErrorAction Stop
}
function Get-VsanClusterConfigurationForCluster {

    <#
        .SYNOPSIS
        Thin wrapper around Get-VsanClusterConfiguration to support mocking in unit tests.

        .DESCRIPTION
        Get-VsanClusterConfiguration has an ArgumentTransformationAttribute on its -Cluster parameter
        that blocks direct mocking. This wrapper accepts [PSObject] so tests can mock this function
        with a PSCustomObject cluster, following the same pattern as Get-VmkernelAdaptersOnHost.

        .PARAMETER Cluster
        Cluster object (e.g. from Get-Cluster) to retrieve the vSAN configuration for.

        .PARAMETER Server
        vCenter server name.

        .OUTPUTS
        VsanClusterConfiguration object, or $null on error.
    
        .EXAMPLE
        $vsanClusterConfigurationForCluster = Get-VsanClusterConfigurationForCluster -Cluster $clusterObject
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$Cluster,
        [Parameter(Mandatory = $false)] [String]$Server = $Script:vCenterName
    )

    # 3>$null 6>$null suppress the "Not found vSAN default storage policy" noise emitted by
    # PowerCLI when Get-VsanClusterConfiguration is called on an ESA cluster.
    Get-VsanClusterConfiguration -Cluster $Cluster -Server $Server -ErrorAction SilentlyContinue 3>$null 6>$null
}
function Test-VsanAutomaticRebalanceAtThreshold {

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
    
        .EXAMPLE
        Test-VsanAutomaticRebalanceAtThreshold -ClusterName "edge-cluster-1"
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [ValidateRange(25, 75)] [Int]$ExpectedThresholdPercent = 30,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$Server = $Script:vCenterName
    )

    try {
        $cluster = Get-ClusterObjectByName -ClusterName $ClusterName -Server $Server
        $config = Get-VsanClusterConfigurationForCluster -Cluster $cluster -Server $Server
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
        if ($null -eq $currentThreshold -or [Int]$currentThreshold -ne $ExpectedThresholdPercent) {
            Write-LogMessage -Type DEBUG -Message "vSAN cluster `"$ClusterName`": ProactiveRebalanceThreshold is $currentThreshold (expected $ExpectedThresholdPercent)."
            return $false
        }
        return $true
    } catch {
        Write-LogMessage -Type DEBUG -Message "Test-VsanAutomaticRebalanceAtThreshold failed for `"$ClusterName`": $($_.Exception.Message)."
        return $false
    }
}
function Enable-VsanAutomaticDiskClaimIfSupported {

    <#
        .SYNOPSIS
        Enables vSAN automatic disk claim (VsanDiskClaimMode Automatic) when the cmdlet supports it.

        .DESCRIPTION
        Sets the vSAN cluster disk claim mode to Automatic. Tries Set-VsanClusterConfiguration
        -VsanDiskClaimMode first; if that parameter is absent in the installed PowerCLI, falls back
        to Set-Cluster -VsanDiskClaimMode (available in VCF PowerCLI 9 even when
        Set-VsanClusterConfiguration lacks the parameter). Applicable to both vSAN OSA and vSAN ESA.
        Non-fatal on failure — skips with a WARNING when neither cmdlet supports the parameter.

        .PARAMETER ClusterName
        Name of the vSAN cluster.

        .OUTPUTS
        Boolean. $true if Automatic was set or already active; $false if parameter unsupported or on error.

        .NOTES
        VsanDiskClaimMode is marked deprecated in VCF PowerCLI 9 but remains functional for triggering
        automatic disk claim on both OSA and ESA clusters. The [Obsolete] attribute on the parameter does
        not indicate a no-op in this environment. 3>$null 6>$null on Get-VsanClusterConfiguration reduce
        PowerCLI stream noise; Write-Host-based output from PowerCLI internals may still reach the console.
        See https://developer.broadcom.com/powercli/latest/vmware.vimautomation.storage/commands/set-vsanclusterconfiguration

        .EXAMPLE
        Enable-VsanAutomaticDiskClaimIfSupported -ClusterName "edge-cluster-1"
    #>
    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName
    )
    $setVsanCmd = Get-Command Set-VsanClusterConfiguration -ErrorAction SilentlyContinue
    $setClusterCmd = Get-Command Set-Cluster -ErrorAction SilentlyContinue
    $vsanCmdHasParam = $setVsanCmd -and $setVsanCmd.Parameters.ContainsKey("VsanDiskClaimMode")
    $clusterCmdHasParam = $setClusterCmd -and $setClusterCmd.Parameters.ContainsKey("VsanDiskClaimMode")
    if (-not $vsanCmdHasParam -and -not $clusterCmdHasParam) {
        Write-LogMessage -Type DEBUG -Message "Set-VsanClusterConfiguration and Set-Cluster both lack -VsanDiskClaimMode in this PowerCLI version. Skipping vSAN Managed Disk Claim enablement."
        return $false
    }
    if (-not $vsanCmdHasParam) {
        Write-LogMessage -Type DEBUG -Message "Set-VsanClusterConfiguration lacks -VsanDiskClaimMode; using Set-Cluster fallback."
    }
    $paramSource = if ($vsanCmdHasParam) { $setVsanCmd } else { $setClusterCmd }
    try {
        # 3>$null 6>$null suppress PowerCLI stream noise from Get-VsanClusterConfiguration on ESA clusters.
        # Write-Host-based output from PowerCLI internals may still reach the console regardless.
        $vsanClusterConfig = Get-VsanClusterConfiguration -Cluster $ClusterName -Server $Script:vCenterName -ErrorAction Stop 3>$null 6>$null
        if (-not $vsanClusterConfig) {
            return $false
        }
        $currentMode = $vsanClusterConfig.VsanDiskClaimMode
        $automaticClaimValue = $null
        $claimModeType = $null
        if ($null -ne $vsanClusterConfig.VsanDiskClaimMode) {
            $claimModeType = $vsanClusterConfig.VsanDiskClaimMode.GetType()
        } elseif ($paramSource.Parameters["VsanDiskClaimMode"].ParameterType.IsEnum) {
            $claimModeType = $paramSource.Parameters["VsanDiskClaimMode"].ParameterType
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
            if ($vsanCmdHasParam) {
                $setVsanParams = @{ Configuration = $vsanClusterConfig; Server = $Script:vCenterName; ErrorAction = 'Stop' }
                $setVsanParams['VsanDiskClaimMode'] = $automaticClaimValue
                Set-VsanClusterConfiguration @setVsanParams 3>$null | Out-Null
            } else {
                $cluster = Get-Cluster -Name $ClusterName -Server $Script:vCenterName -ErrorAction Stop
                Set-Cluster -Cluster $cluster -VsanDiskClaimMode $automaticClaimValue `
                    -Server $Script:vCenterName -Confirm:$false -ErrorAction Stop 3>$null | Out-Null
            }
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
function Invoke-VsanClusterConfigReapply {

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
    [OutputType([Bool])]
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
function Get-VsanClusterTriggeredAlarms {

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
    
        .EXAMPLE
        Get-VsanClusterTriggeredAlarms -ClusterName "edge-cluster-1"
    #>

    [CmdletBinding()]
    [OutputType([System.Object[]], [System.Collections.Generic.List[PSObject]])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName
    )

    $clusterObject = Get-ClusterByName -Name $ClusterName -Server $Script:vCenterName
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

    $result = [System.Collections.Generic.List[PSObject]]::new()
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
        $result.Add([PSCustomObject]@{ AlarmName = $alarmName; Status = $status })
    }
    return $result
}
function Test-VsanTriggeredAlarmIsStatsPrimaryElection {

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
    
        .EXAMPLE
        Test-VsanTriggeredAlarmIsStatsPrimaryElection -TriggeredAlarm "value"
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
    if ([String]::IsNullOrWhiteSpace([String]$name)) {
        return $false
    }
    return [String]$name -match "Stats primary election|Stats primary selection|performance service alarm 'Stats primary|stats primary election|stats primary selection"
}
function Test-VsanTriggeredAlarmIsHclRelated {

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
    
        .EXAMPLE
        Test-VsanTriggeredAlarmIsHclRelated -TriggeredAlarm "value"
    #>

    [CmdletBinding()]
    [OutputType([bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] $TriggeredAlarm
    )

    if (-not (Get-Member -InputObject $TriggeredAlarm -Name "AlarmName" -MemberType Properties -ErrorAction SilentlyContinue)) {
        return $false
    }
    $name = [String]$TriggeredAlarm.AlarmName
    if ([String]::IsNullOrWhiteSpace($name)) {
        return $false
    }
    # HCL acronym is distinctive in vSAN alarm naming; hardware compatibility / vSAN support strings cover the umbrella alarms. Controller firmware/driver/disk-mode/on-HCL map 1:1 to the silenced health check IDs.
    return $name -match "(?i)\bHCL\b|hardware\s+compatibility|hardware\s+vSAN\s+support|controller\s+(firmware|driver|disk\s*mode|on\s+HCL)"
}
function Set-VsanDomNetworkSchedulerThrottleOnHost {

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
    
        .EXAMPLE
        Set-VsanDomNetworkSchedulerThrottleOnHost -Server $vcenterConnection -VMHost $vmHostObject
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Server,
        [Parameter(Mandatory = $true)] $VMHost
    )
    $hostNameForLogging = if ($VMHost.Name) { $VMHost.Name } else { [String]$VMHost }
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
                    $items = @($listResult)
                    foreach ($item in $items) {
                        $optionName = $item.Option, $item.option, $item.Name, $item.name, $item.Path, $item.PSObject.Properties['Option'].Value, $item.PSObject.Properties['option'].Value | Where-Object { $_ } | Select-Object -First 1
                        if ($optionName -eq "/VSAN/DOMNetworkSchedulerThrottleComponent") {
                            $currentVal = $item.IntValue, $item.intvalue, $item.PSObject.Properties['IntValue'].Value, $item.PSObject.Properties['intvalue'].Value | Where-Object { $null -ne $_ } | Select-Object -First 1
                            if ($null -ne $currentVal -and [Int]$currentVal -eq 1) {
                                return [PSCustomObject]@{ Applied = $false; AlreadySet = $true }
                            }
                            break
                        }
                    }
                    # Single-option list returns one object; it may not have Option property set, so check IntValue if we have only one item.
                    if ($items.Count -eq 1) {
                        $currentVal = $items[0].IntValue, $items[0].intvalue, $items[0].PSObject.Properties['IntValue'].Value, $items[0].PSObject.Properties['intvalue'].Value | Where-Object { $null -ne $_ } | Select-Object -First 1
                        if ($null -ne $currentVal -and [Int]$currentVal -eq 1) {
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
function Set-VsanDomNetworkSchedulerThrottleOnCluster {

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
    
        .EXAMPLE
        Set-VsanDomNetworkSchedulerThrottleOnCluster -ClusterName "edge-cluster-1"
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$Server = $Script:vCenterName
    )
    $clusterObject = try { Get-ClusterByName -Name $ClusterName -Server $Server } catch { $null }
    if (-not $clusterObject) {
        Write-LogMessage -Type DEBUG -Message "Set-VsanDomNetworkSchedulerThrottleOnCluster: cluster `"$ClusterName`" not found."
        return $false
    }
    $clusterHosts = Get-VmHostsInCluster -ClusterObject $clusterObject
    if (-not $clusterHosts -or @($clusterHosts).Count -eq 0) {
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
    $totalHostCount = @($clusterHosts).Count
    if ($appliedCount -gt 0) {
        Write-LogMessage -Type DEBUG -Message "Suppress 10 GB networking alarm if present (Broadcom KB 394932) on $appliedCount/$totalHostCount host(s) in cluster `"$ClusterName`"."
        return $true
    }
    if ($alreadySetCount -eq $totalHostCount) {
        Write-LogMessage -Type DEBUG -Message "DOM throttle (10G alarm suppression) already set on all $totalHostCount host(s) in cluster `"$ClusterName`". Skipping."
    }
    return $appliedCount -gt 0
}
function Invoke-VsanAlarmRemediation {

    <#
        .SYNOPSIS
        Iterates triggered vSAN alarms and dispatches each to its auto-remediation action.

        .DESCRIPTION
        Handles advCfgSync alarms (re-apply vSAN cluster config and re-check), HA host status alarms
        (reconfigure HA/DRS), performance service alarms (enable programmatically), Stats primary
        election alarms (log guidance; not blocking), and lab-only third-party IO filter alarms
        (debug log only). Unrecognized alarms are logged as WARNING. Remaining alarms that could not
        be cleared after remediation are logged as WARNING.

        .PARAMETER Alarms
        Initial set of triggered alarms returned by Get-VsanClusterTriggeredAlarms.

        .PARAMETER ClusterName
        Name of the vSAN cluster.

        .PARAMETER HaPolicy
        HA policy for Invoke-ReconfigureClusterHA (disabled, reservationBased, or slotBased).

        .PARAMETER HaStabilizationDelaySeconds
        Delay passed to Invoke-ReconfigureClusterHA after HA reconfig.

        .PARAMETER LabEnvironment
        When $true, the third-party IO filter alarm is logged at DEBUG and not added to WARNING output.

        .PARAMETER PostRemediationWaitSeconds
        Seconds to wait after a successful vSAN config re-apply before re-querying alarms.

        .NOTES
        Helper for Invoke-VsanClusterAlarmCheckAndRemediate. Not intended for direct call.
    
        .EXAMPLE
        Invoke-VsanAlarmRemediation -Alarms "value" -ClusterName "edge-cluster-1"
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [Object[]]$Alarms,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [ValidateSet("disabled", "reservationBased", "slotBased")] [String]$HaPolicy = "reservationBased",
        [Parameter(Mandatory = $false)] [ValidateRange(0, 600)] [Int]$HaStabilizationDelaySeconds = 0,
        [Parameter(Mandatory = $false)] [Switch]$LabEnvironment,
        [Parameter(Mandatory = $false)] [ValidateRange(0, 120)] [Int]$PostRemediationWaitSeconds = 10
    )

    $advCfgSyncPattern = "advanced\s*(virtual\s*)?san\s*configuration\s*in\s*sync|advCfgSync|configuration\s*in\s*sync"
    $attemptedFix = $false
    $remainingAlarms = [System.Collections.Generic.List[PSObject]]::new()

    foreach ($alarm in $Alarms) {
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
                        if ($alarmItem.AlarmName -match $advCfgSyncPattern) { $remainingAlarms.Add($alarmItem) }
                    }
                } else {
                    $remainingAlarms.Add($alarm)
                }
            }
        } else {
            if ($name -match "vSphere\s+HA\s+host\s+status|vsphere\s+ha\s+host\s+status") {
                Write-LogMessage -Type INFO -Message "vSAN cluster `"$ClusterName`" has alarm: `"$name`" (status: $($alarm.Status)). Auto-remediating by re-applying HA and DRS so vCenter re-evaluates management network for heartbeats."
                Invoke-ReconfigureClusterHA -ClusterName $ClusterName -DelaySeconds $HaStabilizationDelaySeconds -HaPolicy $HaPolicy
            } elseif ($name -match "Performance service status|perfsvcstatus|performance service alarm 'Performance service status'") {
                Write-LogMessage -Type INFO -Message "vSAN cluster `"$ClusterName`" has alarm: `"$name`" (status: $($alarm.Status)). Attempting to enable vSAN performance service programmatically."
                Enable-VsanPerformanceService -ClusterName $ClusterName
                Write-LogMessage -Type INFO -Message "If the alarm persists, it often clears within a few minutes as the performance service starts. Otherwise enable in vCenter (vSAN Services) or check vSAN Health > Performance service."
            } elseif ($name -match "Stats primary election|Stats primary selection|performance service alarm 'Stats primary|stats primary election|stats primary selection") {
                Write-LogMessage -Type DEBUG -Message "vSAN cluster `"$ClusterName`" has Stats primary election/selection alarm: `"$name`" (status: $($alarm.Status)). Post-witness health uses re-trigger + optional proceed-with-warning when this is the only failing test. If performance service stays unhealthy, see Broadcom KB 401679 (remove duplicate .vsan.stats-* folders, restart vsanmgmtd on hosts, re-enable performance service, RETEST) or RVC vsan.perf.stats_object_delete/create."
            } elseif ($LabEnvironment -and $name -match "Registration/unregistration of third-party IO filter storage providers fails on a host") {
                Write-LogMessage -Type DEBUG -Message "vSAN cluster `"$ClusterName`" has alarm (lab-suppressed): `"$name`" (status: $($alarm.Status)). Known lab/VAIO issue; resolve manually if needed (e.g. SSL/cert on port 9080)."
            } elseif ($LabEnvironment -and (Test-VsanTriggeredAlarmIsHclRelated -TriggeredAlarm $alarm)) {
                Write-LogMessage -Type DEBUG -Message "vSAN cluster `"$ClusterName`" has alarm (lab-suppressed HCL): `"$name`" (status: $($alarm.Status)). HCL/hardware-compatibility checks are silenced in lab mode; alarm not counted toward red gate."
            } else {
                Write-LogMessage -Type WARNING -Message "vSAN cluster `"$ClusterName`" has alarm (not auto-remediated): `"$name`" (status: $($alarm.Status)). Resolve manually if needed."
            }
        }
    }
    foreach ($alarmItem in $remainingAlarms) {
        Write-LogMessage -Type WARNING -Message "vSAN cluster `"$ClusterName`" alarm still present after remediation attempt: `"$($alarmItem.AlarmName)`" (status: $($alarmItem.Status)). Resolve manually if needed."
    }
}
function Invoke-VsanRefreshedAlarmGate {

    <#
        .SYNOPSIS
        Re-queries vSAN cluster alarms and gates on red alarms (AcceptBadCheckResults or interactive prompt).

        .DESCRIPTION
        After auto-remediation, re-reads triggered alarms. Stats primary election and (in lab mode)
        third-party IO filter alarms are excluded from the gate. Remaining red alarms require an
        explicit AcceptBadCheckResults flag or a user Y response; otherwise throws [VcfDeploymentException].
        Yellow-only alarms log a summary warning without blocking.

        .PARAMETER AcceptBadCheckResults
        When set, proceeds without prompting when red alarms remain after remediation.

        .PARAMETER ClusterName
        Name of the vSAN cluster.

        .PARAMETER LabEnvironment
        When $true, suppresses the third-party IO filter alarm and HCL/hardware-compatibility alarms from the red gate.

        .NOTES
        Helper for Invoke-VsanClusterAlarmCheckAndRemediate. Not intended for direct call.
    
        .EXAMPLE
        Invoke-VsanRefreshedAlarmGate -ClusterName "edge-cluster-1"
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [Switch]$AcceptBadCheckResults,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [Switch]$LabEnvironment
    )

    $refreshedAlarms = Get-VsanClusterTriggeredAlarms -ClusterName $ClusterName
    if (-not $refreshedAlarms -or $refreshedAlarms.Count -eq 0) { return }

    $labThirdPartyPattern = "Registration/unregistration of third-party IO filter storage providers fails on a host"
    $blockingRedAlarms = [System.Collections.Generic.List[PSObject]]::new()
    $yellowAlarms      = [System.Collections.Generic.List[PSObject]]::new()
    foreach ($alarm in $refreshedAlarms) {
        $statusText = ([String]$alarm.Status).ToLower()
        if ($LabEnvironment -and $alarm.AlarmName -match [Regex]::Escape($labThirdPartyPattern)) { continue }
        if ($LabEnvironment -and (Test-VsanTriggeredAlarmIsHclRelated -TriggeredAlarm $alarm)) {
            Write-LogMessage -Type DEBUG -Message "vSAN cluster `"$ClusterName`" has alarm (lab-suppressed HCL): `"$($alarm.AlarmName)`" (status: $($alarm.Status)). HCL/hardware-compatibility checks are silenced in lab mode; alarm not counted toward red gate."
            continue
        }
        switch -Regex ($statusText) {
            '^red$' {
                if (Test-VsanTriggeredAlarmIsStatsPrimaryElection -TriggeredAlarm $alarm) {
                    Write-LogMessage -Type WARNING -Message "vSAN cluster `"$ClusterName`" has red triggered alarm (not blocking on this gate): `"$($alarm.AlarmName)`". Same transient Stats primary handling as post-witness health; if supervisor or host preflight still fails, align witness and data node ESX builds, then see Broadcom KB 401679."
                    continue
                }
                $blockingRedAlarms.Add($alarm)
            }
            '^yellow$' { $yellowAlarms.Add($alarm) }
        }
    }

    if ($blockingRedAlarms.Count -gt 0) {
        Write-LogMessage -Type ERROR -Message "vSAN cluster `"$ClusterName`" has one or more triggered alarms with red status. This indicates a serious vSAN fault; stretched-cluster configuration (including witness reachability and routing) may be incorrect. Verify vSAN Health in vCenter and confirm witness network connectivity and witness VM health before continuing."
        foreach ($redAlarm in $blockingRedAlarms) {
            Write-LogMessage -Type WARNING -Message "  Red alarm: `"$($redAlarm.AlarmName)`" (status: $($redAlarm.Status))."
        }
        $hclRedAlarms = @($blockingRedAlarms | Where-Object { Test-VsanTriggeredAlarmIsHclRelated -TriggeredAlarm $_ })
        if ($hclRedAlarms.Count -gt 0) {
            $hclNames = ($hclRedAlarms | ForEach-Object { "`"$($_.AlarmName)`"" }) -join ", "
            Write-LogMessage -Type WARNING -Message "Red alarm(s) on cluster `"$ClusterName`" include vSAN HCL/hardware-compatibility findings: $hclNames. These would be hidden by common.labenvironment=true but the underlying HCL state (storage controller on HCL, controller firmware/driver/disk mode, host HCL DB state) is unchanged. Accepting risk here will almost certainly not produce a working supervisor: WCP supervisor enablement enforces cluster/host HCL conformance downstream of this gate. Resolve by using HCL-listed storage controllers, firmware, and drivers, then retry; do not simply acknowledge the alarms in vCenter."
        }
        if ($AcceptBadCheckResults.IsPresent) {
            $acceptMsg = if ($hclRedAlarms.Count -gt 0) {
                "AcceptBadCheckResults is set; proceeding despite red vSAN HCL alarm(s) for cluster `"$ClusterName`". Supervisor enablement will likely fail until the cluster is HCL-conformant."
            } else {
                "AcceptBadCheckResults is set; proceeding despite red vSAN triggered alarm(s) for cluster `"$ClusterName`"."
            }
            Write-LogMessage -Type WARNING -Message $acceptMsg
        } else {
            $continuePrompt = if ($hclRedAlarms.Count -gt 0) {
                "Continue deployment despite red vSAN HCL/hardware-compatibility alarm(s)? Supervisor enablement is expected to fail. Type Y to accept risk, or N to stop [default: N]"
            } else {
                "Continue deployment despite red vSAN alarm(s)? Type Y to accept risk, or N to stop [default: N]"
            }
            do {
                $continueResponse = Read-Host $continuePrompt
                $continueResponse = if ($null -ne $continueResponse) { $continueResponse.Trim() } else { "" }
                if ($continueResponse -match '^[yY](es)?$') {
                    $acceptRiskMsg = if ($hclRedAlarms.Count -gt 0) {
                        "User chose to continue despite red vSAN HCL alarm(s) for cluster `"$ClusterName`". Accepting risk; supervisor enablement may fail on non-HCL-conformant hardware."
                    } else {
                        "User chose to continue despite red vSAN triggered alarm(s) for cluster `"$ClusterName`". Accepting risk."
                    }
                    Write-LogMessage -Type WARNING -Message $acceptRiskMsg
                    break
                }
                if ([String]::IsNullOrWhiteSpace($continueResponse) -or $continueResponse -match '^[nN](o)?$') {
                    $redNames = ($blockingRedAlarms | Select-Object -ExpandProperty AlarmName) -join "; "
                    $errorMsg = "Deployment failed. vSAN cluster `"$ClusterName`" has triggered alarm(s) with red status: $redNames"
                    Write-LogMessage -Type ERROR -Message $errorMsg
                    throw [VcfDeploymentException]::new($errorMsg)
                }
                Write-LogMessage -Type WARNING -Message "Invalid response. Enter Y or N (or press Enter for N)."
            } while ($true)
        }
    } elseif ($yellowAlarms.Count -gt 0) {
        Write-LogMessage -Type WARNING -Message "vSAN cluster `"$ClusterName`" has $($yellowAlarms.Count) triggered alarm(s) with yellow status (no red); continuing without blocking. Resolve in vCenter when convenient."
    }
}
function Invoke-VsanClusterAlarmCheckAndRemediate {

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
    
        .EXAMPLE
        Invoke-VsanClusterAlarmCheckAndRemediate -ClusterName "edge-cluster-1"
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [Switch]$AcceptBadCheckResults,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [ValidateSet("disabled", "reservationBased", "slotBased")] [String]$HaPolicy = "reservationBased",
        [Parameter(Mandatory = $false)] [Switch]$LabEnvironment,
        [Parameter(Mandatory = $false)] [ValidateRange(0, 120)] [Int]$PostRemediationWaitSeconds = 10
    )

    # Always set DOM network scheduler throttle on cluster (vSAN ESA on 10G; Broadcom KB 394932, 388455).
    $throttleSet = Set-VsanDomNetworkSchedulerThrottleOnCluster -ClusterName $ClusterName
    if (-not $throttleSet) {
        Write-LogMessage -Type DEBUG -Message "Set-VsanDomNetworkSchedulerThrottleOnCluster returned false for cluster `"$ClusterName`" (cluster not found or no hosts)."
    }
    $alarms = Get-VsanClusterTriggeredAlarms -ClusterName $ClusterName
    if (-not $alarms -or $alarms.Count -eq 0) { return }
    Invoke-VsanAlarmRemediation `
        -Alarms                       $alarms `
        -ClusterName                  $ClusterName `
        -HaPolicy                     $HaPolicy `
        -HaStabilizationDelaySeconds  $Script:HaPostVsanStabilizationDelaySeconds `
        -LabEnvironment:$LabEnvironment.IsPresent `
        -PostRemediationWaitSeconds   $PostRemediationWaitSeconds
    Invoke-VsanRefreshedAlarmGate `
        -AcceptBadCheckResults:$AcceptBadCheckResults.IsPresent `
        -ClusterName                  $ClusterName `
        -LabEnvironment:$LabEnvironment.IsPresent
}
function Wait-VsanClusterConfigSyncOrTimeout {

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
    
        .EXAMPLE
        Wait-VsanClusterConfigSyncOrTimeout -ClusterName "edge-cluster-1"
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
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
        $healthSummary = Get-VsanClusterHealthSummaryViaView -ClusterName $ClusterName -FetchFromCache:$false
        if ($healthSummary -and (Test-VsanClusterAdvCfgSyncInSync -HealthSummary $healthSummary)) {
            Write-LogMessage -Type INFO -Message "vSAN cluster configuration is in sync on all hosts for cluster `"$ClusterName`" (check #$checkCount)."
            return $true
        }
        $remaining = [Math]::Max(0, [int](($deadline - (Get-Date)).TotalSeconds))
        if ($remaining -gt 0) {
            $sleepSeconds = [Math]::Min($CheckIntervalSeconds, $remaining)
            Write-LogMessage -Type DEBUG -Message "vSAN config not yet in sync for cluster `"$ClusterName`" (check #$checkCount). Waiting $CheckIntervalSeconds seconds (timeout in $remaining s)."
            Start-Sleep -Seconds $sleepSeconds
        }
    }

    Write-LogMessage -Type WARNING -Message "vSAN cluster configuration did not report in sync for cluster `"$ClusterName`" within $TimeoutSeconds seconds ($checkCount check(s)). Proceeding; if you see 'vSAN ESA is disabled on this host', increase VsanConfigSyncTimeoutSeconds or check vCenter-to-host connectivity."
    return $false
}
function Test-VsanAdvCfgSyncAndWaitIfNeeded {

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
    
        .EXAMPLE
        $vsanAdvCfgSyncAndWaitIfNeededResult = Test-VsanAdvCfgSyncAndWaitIfNeeded -ClusterName "edge-cluster-1" -HealthSummary "Operation failed."
        if (-not $vsanAdvCfgSyncAndWaitIfNeededResult.IsValid) { Write-LogMessage -Type ERROR -Message $vsanAdvCfgSyncAndWaitIfNeededResult.Summary }
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
function Get-VsanHealthFailureReasons {

    <#
        .SYNOPSIS
        Builds a string describing why vSAN cluster health is not green.

        .DESCRIPTION
        Uses overallHealthDescription and, if useful, group/test details from the health summary
        to report why health is yellow or red.

        .PARAMETER HealthSummary
        The VsanClusterHealthSummary object from Get-VsanClusterHealthSummaryViaView.

        .OUTPUTS
        [string] Non-empty string with reason(s); [String]::Empty if summary is null or overall health is green.
    
        .EXAMPLE
        $vsanHealthFailureReasons = Get-VsanHealthFailureReasons -HealthSummary "Operation failed."
    #>

    [CmdletBinding()]
    [OutputType([string])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] $HealthSummary
    )

    $emptyResult = [String]::Empty

    # Null or green: no failure reasons.
    if (-not $HealthSummary) {
        return $emptyResult
    }
    $overallHealth = $HealthSummary.overallHealth
    if ($overallHealth -eq 'green') {
        return $emptyResult
    }

    # Build reasons from overall description and non-green groups/tests (full findings detail).
    $failureReasons = [System.Collections.Generic.List[String]]::new()
    $overallDescription = $HealthSummary.overallHealthDescription
    if ($overallDescription) {
        $failureReasons.Add([String]$overallDescription)
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
                $failureReasons.Add([string]("Group: $groupName ($groupHealthStatus)"))
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
                        $testLine = "$($testLine): $testDesc"
                    }
                    $failureReasons.Add($testLine)
                }
            }
        }
    }

    if ($failureReasons.Count -eq 0) {
        return [string]("Health status: $overallHealth")
    }
    return [string]($failureReasons -join "; ")
}
function Invoke-VsanClusterObjectRepairAndWait {

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
    
        .EXAMPLE
        Invoke-VsanClusterObjectRepairAndWait -ClusterName "edge-cluster-1"
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [ValidateRange(5, 60)] [Int]$PollIntervalSeconds = 15,
        [Parameter(Mandatory = $false)] [ValidateRange(60, 3600)] [Int]$TimeoutSeconds = 600
    )

    $clusterObject = Get-ClusterByName -Name $ClusterName -Server $Script:vCenterName
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
function Enable-VsanHealthAlarms {

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
    
        .EXAMPLE
        Enable-VsanHealthAlarms -ClusterName "edge-cluster-1"
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName
    )
    $clusterObject = Get-ClusterByName -Name $ClusterName -Server $Script:vCenterName
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
function Invoke-AbandonHciWorkflowIfInProgress {

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
    
        .EXAMPLE
        Invoke-AbandonHciWorkflowIfInProgress -ClusterName "edge-cluster-1"
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName
    )
    $clusterObject = Get-ClusterByName -Name $ClusterName -Server $Script:vCenterName
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
function Add-VsanClusterSilentHealthChecks {

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
    
        .EXAMPLE
        Add-VsanClusterSilentHealthChecks -ClusterName "edge-cluster-1" -SilentCheckIds "domain-c123"
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
    $clusterObject = Get-ClusterByName -Name $ClusterName -Server $Script:vCenterName
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
    $failed = [System.Collections.Generic.List[String]]::new()
    for ($i = 0; $i -lt $toAdd.Count; $i += $batchSize) {
        $endIdx = [Math]::Min($i + $batchSize - 1, $toAdd.Count - 1)
        $chunk = @($toAdd[$i..$endIdx])
        try {
            $healthSystemView.VsanHealthSetVsanClusterSilentChecks($clusterMoRef, $chunk, $null) | Out-Null
            Write-LogMessage -Type DEBUG -Message "Silenced vSAN health check ID(s) on cluster `"$ClusterName`" ($LogContext): $($chunk -join ', ')."
        } catch {
            Write-LogMessage -Type WARNING -Message "VsanHealthSetVsanClusterSilentChecks failed for cluster `"$ClusterName`" ($LogContext, batch: $($chunk -join ', ')): $($_.Exception.Message). Skipping this batch."
            $failed.AddRange([String[]]$chunk)
        }
    }
    if ($failed.Count -gt 0) {
        Write-LogMessage -Type DEBUG -Message "vSAN checks not silenced for cluster `"$ClusterName`" ($LogContext; invalid or unsupported testIds): $($failed -join ', ')."
    }
}
function Set-VsanLabSilentChecksIfRequested {

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
        [Parameter(Mandatory = $true)] [Bool]$LabEnvironmentEnabled,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 10)] [Int]$SilentCheckBatchSize = 3,
        [Parameter(Mandatory = $false)] [String[]]$SilentCheckIds = @("advcfgsync", "controllerdiskmode", "controlleronhcl", "controllerfirmware", "controllerdriver", "hclhostbadstate")
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
function Invoke-VsanClusterHealthRetestAfterDeployment {

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
    
        .EXAMPLE
        Invoke-VsanClusterHealthRetestAfterDeployment -ClusterName "edge-cluster-1"
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
function Enable-VsanPerformanceService {

    <#
        .SYNOPSIS
        Enables the vSAN performance service on a cluster after vSAN configuration is complete.

        .DESCRIPTION
        Calls Set-VsanClusterConfiguration -PerformanceServiceEnabled $true when the cmdlet supports that parameter. The performance service stores history in a vSAN object; enabling it is non-fatal to skip on failure or unsupported PowerCLI.

        .PARAMETER ClusterName
        Name of the vSAN cluster.

        .PARAMETER Server
        vCenter server. Default is $Script:vCenterName.
    
        .EXAMPLE
        Enable-VsanPerformanceService -ClusterName "edge-cluster-1"
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
function Test-VsanHealthTestDetailsStatsPrimaryElection {

    <#
        .SYNOPSIS
        Returns whether a vSAN health test object describes Stats Primary election/selection.

        .PARAMETER Test
        A single test entry from the vSAN health summary groups[].tests collection.

        .OUTPUTS
        Boolean.
    
        .EXAMPLE
        Test-VsanHealthTestDetailsStatsPrimaryElection -Test "value"
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
function Test-VsanHealthFailureTextOnlyStatsPrimaryElection {

    <#
        .SYNOPSIS
        Heuristic: failure text appears limited to Stats Primary election/selection themes.

        .PARAMETER FailureText
        Concatenated failure reasons (for example from Get-VsanHealthFailureReasons).

        .OUTPUTS
        Boolean.
    
        .EXAMPLE
        Test-VsanHealthFailureTextOnlyStatsPrimaryElection -FailureText "Operation failed."
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
function Test-VsanHealthSummaryNonGreenOnlyStatsPrimaryElection {

    <#
        .SYNOPSIS
        Returns true when overall health is not green and every non-green test looks like Stats Primary election/selection.

        .PARAMETER HealthSummary
        vSAN cluster health summary from Get-VsanClusterHealthSummaryViaView.

        .OUTPUTS
        Boolean.
    
        .EXAMPLE
        Test-VsanHealthSummaryNonGreenOnlyStatsPrimaryElection -HealthSummary "Operation failed."
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
function Invoke-VsanClusterHealthRetriggerForStatsPrimary {

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
    
        .EXAMPLE
        Invoke-VsanClusterHealthRetriggerForStatsPrimary -ClusterName "edge-cluster-1"
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$Server = $Script:vCenterName,
        [Parameter(Mandatory = $false)] [ValidateRange(60, 900)] [Int]$VmCreateTimeoutSeconds = 120,
        [Parameter(Mandatory = $false)] [ValidateRange(5, 600)] [Int]$WaitAfterTriggerSeconds = 45
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
function Invoke-VsanHealthCheckRound {

    <#
        .SYNOPSIS
        Waits, refetches vSAN health, and evaluates the retry result after an initial non-green finding.

        .DESCRIPTION
        Waits RetryWaitSeconds, refetches the vSAN health summary, and evaluates the overall health:
        - green   — proceeds
        - yellow  — proceeds with a warning log
        - red     — prompts the user (or auto-proceeds if AcceptBadCheckResults is set); throws on decline
        - unknown — proceeds with a warning log

        When the health summary cannot be refetched, the FallbackOverallHealth and
        FallbackFailureReasons values from the pre-wait check are used so the caller has a
        deterministic outcome even if vCenter is temporarily unresponsive.

        .PARAMETER AcceptBadCheckResults
        When set, automatically proceeds on red health without prompting the user.

        .PARAMETER ClusterName
        Name of the vSAN cluster. Used in log messages and health queries.

        .PARAMETER FallbackFailureReasons
        Failure reasons string from the pre-wait check. Used when the retry health fetch fails.

        .PARAMETER FallbackOverallHealth
        Overall health string from the pre-wait check (e.g. "yellow", "red"). Used when the
        retry health fetch fails so the switch statement still has a deterministic value.

        .PARAMETER RetryWaitSeconds
        Seconds to wait before refetching health. Passed directly from Invoke-VsanClusterHealthCheckAfterWitness.

        .PARAMETER StoragePolicyType
        vSAN-OSA or vSAN-ESA. Logged when the user declines to proceed on red health so the
        caller can initiate the correct rollback path.

        .NOTES
        Internal helper for Invoke-VsanClusterHealthCheckAfterWitness. Separated to keep the parent
        function under the 80-line AST body guideline and to make the wait/evaluate contract independently
        testable. Throws VcfDeploymentException when the user declines to proceed on a red health result.
    
        .EXAMPLE
        Invoke-VsanHealthCheckRound -ClusterName "edge-cluster-1" -RetryWaitSeconds 30
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [Switch]$AcceptBadCheckResults,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$FallbackFailureReasons = "",
        [Parameter(Mandatory = $false)] [String]$FallbackOverallHealth = "unknown",
        [Parameter(Mandatory = $true)] [ValidateRange(60, 600)] [Int]$RetryWaitSeconds,
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [ValidateSet("vSAN-ESA", "vSAN-OSA", "")] [String]$StoragePolicyType = ""
    )

    Write-LogMessage -Type INFO -Message "Waiting $RetryWaitSeconds seconds before rechecking health."
    Start-Sleep -Seconds $RetryWaitSeconds

    $healthSummary = Get-VsanClusterHealthSummaryViaView -ClusterName $ClusterName -FetchFromCache
    $overallHealth = $FallbackOverallHealth
    if (-not $healthSummary) {
        Write-VsanHealthFailureDebugInfo -ClusterName $ClusterName -Context "health_summary_null"
        Write-LogMessage -Type WARNING -Message "Could not retrieve health on retry; using previous status."
    } else {
        $overallHealth = $healthSummary.overallHealth
        if (-not $overallHealth) { $overallHealth = "unknown" }
    }

    $retryFailureReasons = if ($healthSummary) {
        Get-VsanHealthFailureReasons -HealthSummary $healthSummary
    } else {
        $FallbackFailureReasons
    }

    $proceedReason = $null
    switch ($overallHealth) {
        "green"  { $proceedReason = "green" }
        "yellow" { $proceedReason = "yellow" }
        "red" {
            Write-VsanHealthFailureDebugInfo -ClusterName $ClusterName -Context "health_red" -HealthSummary $healthSummary
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
                if ($proceedResponse -match "^Y(es)?$") {
                    Write-LogMessage -Type WARNING -Message "User chose to proceed despite vSAN red health for cluster `"$ClusterName`". Accepting risk."
                    return
                }
                if ($proceedResponse -match "^N(o)?$") {
                    Write-LogMessage -Type INFO -Message "User chose not to proceed due to vSAN red health for cluster `"$ClusterName`". You will be prompted whether to roll back (same sequence as cleanup)."
                    if (-not $StoragePolicyType) {
                        Write-LogMessage -Type WARNING -Message "StoragePolicyType not passed to health check; caller will need to perform rollback."
                    }
                    $errorMsg = "Deployment failed. vSAN cluster health is red: $retryFailureReasons"
                    Write-LogMessage -Type ERROR -Message $errorMsg
                    throw [VcfDeploymentException]::new($errorMsg)
                }
                Write-LogMessage -Type WARNING -Message "Invalid response. Please enter Y or N."
            } while ($true)
        }
        default { $proceedReason = "unknown" }
    }

    if ($proceedReason) {
        if ($healthSummary) {
            Test-VsanAdvCfgSyncAndWaitIfNeeded -ClusterName $ClusterName -HealthSummary $healthSummary
        }
        switch ($proceedReason) {
            "green"  { Write-LogMessage -Type INFO    -Message "vSAN cluster health is green on retry for cluster `"$ClusterName`". Proceeding." }
            "yellow" { Write-LogMessage -Type WARNING -Message "vSAN cluster health is yellow for `"$ClusterName`" after retry: $retryFailureReasons. Proceeding with warning." }
            default  { Write-LogMessage -Type WARNING -Message "vSAN cluster health status is `"$overallHealth`" for `"$ClusterName`". Proceeding with warning." }
        }
    }
}
function Invoke-VsanInitialPartitionRepair {

    <#
        .SYNOPSIS
        Triggers vSAN object repair when a partition is detected on the initial health check, then
        rechecks the partition status.

        .DESCRIPTION
        Called when Test-VsanClusterPartitioned returns $true on the first health summary fetch after
        vSAN cluster and witness configuration. Triggers Invoke-VsanClusterObjectRepairAndWait, then
        refetches the health summary and rechecks partition. Throws VcfDeploymentException if repair
        fails, if the post-repair health fetch fails, or if the cluster is still partitioned after repair.

        .PARAMETER ClusterName
        The vSAN cluster name. Must be a non-empty string.

        .PARAMETER HealthSummary
        The health summary object at the time partition was detected.

        .PARAMETER RepairTaskTimeoutSeconds
        Maximum seconds to wait for the repair task. Default is 600.

        .EXAMPLE
        $updatedSummary = Invoke-VsanInitialPartitionRepair -ClusterName "cl-site1" -HealthSummary $healthSummary -RepairTaskTimeoutSeconds 600

        .NOTES
        Returns the post-repair health summary. Throws on any unresolved partition or repair failure.
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$HealthSummary,
        [Parameter(Mandatory = $false)] [ValidateRange(60, 3600)] [Int]$RepairTaskTimeoutSeconds = 600
    )

    Write-VsanHealthFailureDebugInfo -ClusterName $ClusterName -Context 'partition_detected' -HealthSummary $HealthSummary
    Write-LogMessage -Type WARNING -Message "vSAN cluster `"$ClusterName`" is partitioned. Triggering object repair (resync)."
    $repairSucceeded = Invoke-VsanClusterObjectRepairAndWait -ClusterName $ClusterName -TimeoutSeconds $RepairTaskTimeoutSeconds
    if (-not $repairSucceeded) {
        Write-VsanHealthFailureDebugInfo -ClusterName $ClusterName -Context 'repair_failed'
        $err = "vSAN object repair did not complete successfully for cluster `"$ClusterName`"."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }

    Write-LogMessage -Type INFO -Message "Rechecking partition status for cluster `"$ClusterName`"."
    $newHealthSummary = Get-VsanClusterHealthSummaryViaView -ClusterName $ClusterName -FetchFromCache:$false
    if (-not $newHealthSummary) {
        Write-VsanHealthFailureDebugInfo -ClusterName $ClusterName -Context 'health_summary_null'
        $err = "Could not retrieve vSAN health summary after repair."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }

    $clusterPartitioned = Test-VsanClusterPartitioned -HealthSummary $newHealthSummary
    if ($clusterPartitioned) {
        Write-VsanHealthFailureDebugInfo -ClusterName $ClusterName -Context 'partition_after_repair' -HealthSummary $newHealthSummary
        $err = "vSAN cluster `"$ClusterName`" is still partitioned after repair."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }

    Write-LogMessage -Type INFO -Message "Partition resolved for cluster `"$ClusterName`". Proceeding to health check."
    return $newHealthSummary
}
function Invoke-VsanStatsPrimaryRetry {

    <#
        .SYNOPSIS
        Re-triggers vSAN health evaluation when the only non-green finding is Stats Primary
        election/selection, waiting between attempts and checking if health resolves to green.

        .DESCRIPTION
        Runs up to RetryMaxAttempts iterations of: invoke health retrigger, wait, refetch health.
        If health becomes green during retries, returns $null to signal the caller should return.
        If after all retries only Stats Primary election remains, proceeds with a warning and
        returns $null. If the health issue is something other than Stats Primary, returns a
        PSCustomObject with the updated HealthSummary and OverallHealth for the caller to continue.

        .PARAMETER ClusterName
        The vSAN cluster name.

        .PARAMETER HealthSummary
        The health summary after the green check failed.

        .PARAMETER OverallHealth
        The overallHealth string (e.g. "yellow", "red", "unknown").

        .PARAMETER RetryMaxAttempts
        Maximum retry attempts. Default is 4.

        .PARAMETER RetryWaitSeconds
        Seconds to wait after each re-trigger. Default is 45.

        .PARAMETER VmCreateTimeoutSeconds
        Passed to Invoke-VsanClusterHealthRetriggerForStatsPrimary. Default is 120.

        .EXAMPLE
        $result = Invoke-VsanStatsPrimaryRetry -ClusterName "cl-site1" -HealthSummary $summary -OverallHealth "yellow" -RetryMaxAttempts 4 -RetryWaitSeconds 45 -VmCreateTimeoutSeconds 120
        if ($null -eq $result) { return }

        .NOTES
        Returns $null when the situation is fully handled (green or proceed-with-warning).
        Returns a PSCustomObject with HealthSummary and OverallHealth when the caller should continue.
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$HealthSummary,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$OverallHealth,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 12)] [Int]$RetryMaxAttempts = 4,
        [Parameter(Mandatory = $false)] [ValidateRange(5, 600)] [Int]$RetryWaitSeconds = 45,
        [Parameter(Mandatory = $false)] [ValidateRange(60, 900)] [Int]$VmCreateTimeoutSeconds = 120
    )

    $retryIdx = 0
    while (
        ($OverallHealth -ne 'green') -and
        (Test-VsanHealthSummaryNonGreenOnlyStatsPrimaryElection -HealthSummary $HealthSummary) -and
        ($retryIdx -lt $RetryMaxAttempts)
    ) {
        $retryIdx++
        Write-LogMessage -Type INFO -Message "vSAN health is not green but only Stats Primary election/selection is reported for cluster `"$ClusterName`"; re-triggering health evaluation (attempt $retryIdx of $RetryMaxAttempts). No silent-check API calls are used."
        Invoke-VsanClusterHealthRetriggerForStatsPrimary -ClusterName $ClusterName -Server $Script:vCenterName -VmCreateTimeoutSeconds $VmCreateTimeoutSeconds -WaitAfterTriggerSeconds $RetryWaitSeconds
        $HealthSummary = Get-VsanClusterHealthSummaryViaView -ClusterName $ClusterName -FetchFromCache:$false
        if (-not $HealthSummary) {
            Write-LogMessage -Type WARNING -Message "Could not refresh vSAN health summary after Stats Primary re-trigger for cluster `"$ClusterName`"; stopping retry loop."
            break
        }
        $OverallHealth = if ($HealthSummary.overallHealth) { $HealthSummary.overallHealth } else { 'unknown' }
        if ($OverallHealth -eq 'green') {
            Test-VsanAdvCfgSyncAndWaitIfNeeded -ClusterName $ClusterName -HealthSummary $HealthSummary
            Write-LogMessage -Type INFO -Message "vSAN cluster health is green for cluster `"$ClusterName`" after Stats Primary re-trigger. Proceeding."
            return $null
        }
    }

    if (($OverallHealth -ne 'green') -and $HealthSummary -and (Test-VsanHealthSummaryNonGreenOnlyStatsPrimaryElection -HealthSummary $HealthSummary)) {
        Write-LogMessage -Type WARNING -Message "Stats Primary election/selection still reported after $RetryMaxAttempts re-trigger attempt(s) for cluster `"$ClusterName`"; treating as transient and proceeding. Monitor vSAN Health and Broadcom KB 401679 if the performance service stays unhealthy."
        Test-VsanAdvCfgSyncAndWaitIfNeeded -ClusterName $ClusterName -HealthSummary $HealthSummary
        return $null
    }

    return [PSCustomObject]@{ HealthSummary = $HealthSummary; OverallHealth = $OverallHealth }
}
function Invoke-VsanSuppressedAlarmRecheck {

    <#
        .SYNOPSIS
        Rechecks vSAN health after re-skipping the HCI workflow when the only non-green finding is
        "vSAN health alarms are suppressed".

        .DESCRIPTION
        Waits HciWorkflowClearWaitSeconds, re-abandons the HCI workflow, then refetches the health
        summary. Returns $null to signal the caller should return when health is green or when the
        suppressed-alarm warning persists (proceed with warning). Returns a PSCustomObject with
        updated HealthSummary, OverallHealth, and FailureReasons when other non-green issues appear.
        Returns a PSCustomObject with the original values when the health refetch fails.

        .PARAMETER ClusterName
        The vSAN cluster name.

        .PARAMETER FailureReasons
        The failure reasons string from the current health summary.

        .PARAMETER HealthSummary
        The current health summary (used as fallback when refetch fails).

        .PARAMETER HciWorkflowClearWaitSeconds
        Seconds to wait before abandoning HCI workflow and rechecking.

        .PARAMETER OverallHealth
        The current overallHealth string (used as fallback when refetch fails).

        .EXAMPLE
        $result = Invoke-VsanSuppressedAlarmRecheck -ClusterName "cl-site1" -HealthSummary $summary -FailureReasons $reasons -OverallHealth "yellow" -HciWorkflowClearWaitSeconds 20
        if ($null -eq $result) { return }

        .NOTES
        Returns $null when handled (caller should return). Returns a PSCustomObject when the caller
        should continue with the returned HealthSummary, OverallHealth, and FailureReasons.
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [String]$FailureReasons,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 120)] [Int]$HciWorkflowClearWaitSeconds = 20,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$HealthSummary,
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [String]$OverallHealth
    )

    Write-LogMessage -Type INFO -Message "Only failure is vSAN health alarms suppressed; waiting $HciWorkflowClearWaitSeconds seconds and re-skipping HCI workflow before recheck."
    Start-Sleep -Seconds $HciWorkflowClearWaitSeconds
    Invoke-AbandonHciWorkflowIfInProgress -ClusterName $ClusterName
    $newHealthSummary = Get-VsanClusterHealthSummaryViaView -ClusterName $ClusterName -FetchFromCache:$false
    if (-not $newHealthSummary) {
        return [PSCustomObject]@{ HealthSummary = $HealthSummary; OverallHealth = $OverallHealth; FailureReasons = $FailureReasons }
    }

    $newOverallHealth = if ($newHealthSummary.overallHealth) { $newHealthSummary.overallHealth } else { 'unknown' }
    if ($newOverallHealth -eq 'green') {
        Test-VsanAdvCfgSyncAndWaitIfNeeded -ClusterName $ClusterName -HealthSummary $newHealthSummary
        Write-LogMessage -Type INFO -Message "vSAN cluster health is green after HCI workflow re-skip for cluster `"$ClusterName`". Proceeding."
        return $null
    }

    $newFailureReasons = Get-VsanHealthFailureReasons -HealthSummary $newHealthSummary
    $stillOnlySuppressed = ($newFailureReasons -match 'alarms are suppressed|hciskip') -and ($newFailureReasons -notmatch 'partition|Network misconfiguration|resync')
    if ($stillOnlySuppressed) {
        Write-LogMessage -Type WARNING -Message "vSAN health alarms suppressed warning persists for `"$ClusterName`"; proceeding. Alarm may clear shortly in vCenter."
        return $null
    }

    return [PSCustomObject]@{ HealthSummary = $newHealthSummary; OverallHealth = $newOverallHealth; FailureReasons = $newFailureReasons }
}
function Invoke-VsanNetworkPartitionRepairAndRecheck {

    <#
        .SYNOPSIS
        Triggers vSAN object repair when health suggests a network partition or initial sync, then
        rechecks health to determine if the cluster recovered.

        .DESCRIPTION
        Called when Test-VsanHealthSuggestsPartitionOrNetwork returns $true after non-green health
        evaluation. Triggers repair, waits, then refetches health. Returns $null to signal green
        (caller should return). Returns a PSCustomObject with updated health state when the cluster
        is not yet green (so the caller can delegate to Invoke-VsanHealthCheckRound). Throws
        VcfDeploymentException if the cluster is partitioned after repair.

        .PARAMETER ClusterName
        The vSAN cluster name.

        .PARAMETER FailureReasons
        The current failure reasons string (used as fallback when refetch fails).

        .PARAMETER HealthSummary
        The current health summary object (used as fallback when refetch fails or repair fails).

        .PARAMETER OverallHealth
        The current overallHealth string (used as fallback when refetch fails or repair fails).

        .PARAMETER RepairTaskTimeoutSeconds
        Maximum seconds to wait for repair. Default is 600.

        .EXAMPLE
        $result = Invoke-VsanNetworkPartitionRepairAndRecheck -ClusterName "cl-site1" -HealthSummary $summary -FailureReasons $reasons -OverallHealth "yellow" -RepairTaskTimeoutSeconds 600
        if ($null -eq $result) { return }

        .NOTES
        Returns $null when handled (green, caller should return). Returns a PSCustomObject with
        HealthSummary, OverallHealth, and FailureReasons when caller should continue.
        Throws VcfDeploymentException on partition-after-repair.
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [String]$FailureReasons,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$HealthSummary,
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [String]$OverallHealth,
        [Parameter(Mandatory = $false)] [ValidateRange(60, 3600)] [Int]$RepairTaskTimeoutSeconds = 600
    )

    Write-LogMessage -Type DEBUG -Message "Treating as possible network partition or initial sync; triggering object repair (resync) for cluster `"$ClusterName`"."
    Write-LogMessage -Type INFO -Message "Triggering vSAN object repair (resync) for cluster `"$ClusterName`" (possible network/partition or initial sync)."
    $repairSucceeded = Invoke-VsanClusterObjectRepairAndWait -ClusterName $ClusterName -TimeoutSeconds $RepairTaskTimeoutSeconds
    if (-not $repairSucceeded) {
        Write-VsanHealthFailureDebugInfo -ClusterName $ClusterName -Context 'repair_failed'
        Write-LogMessage -Type WARNING -Message "vSAN object repair did not complete successfully for cluster `"$ClusterName`"; will wait and recheck health."
        return [PSCustomObject]@{ HealthSummary = $HealthSummary; OverallHealth = $OverallHealth; FailureReasons = $FailureReasons }
    }

    Write-LogMessage -Type INFO -Message "Rechecking health after repair for cluster `"$ClusterName`"."
    $newHealthSummary = Get-VsanClusterHealthSummaryViaView -ClusterName $ClusterName -FetchFromCache:$false
    if (-not $newHealthSummary) {
        return [PSCustomObject]@{ HealthSummary = $HealthSummary; OverallHealth = $OverallHealth; FailureReasons = $FailureReasons }
    }

    $clusterPartitioned = Test-VsanClusterPartitioned -HealthSummary $newHealthSummary
    if ($clusterPartitioned) {
        Write-VsanHealthFailureDebugInfo -ClusterName $ClusterName -Context 'partition_after_repair' -HealthSummary $newHealthSummary
        $err = "vSAN cluster `"$ClusterName`" is partitioned after repair."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }

    $newOverallHealth = if ($newHealthSummary.overallHealth) { $newHealthSummary.overallHealth } else { 'unknown' }
    if ($newOverallHealth -eq 'green') {
        Test-VsanAdvCfgSyncAndWaitIfNeeded -ClusterName $ClusterName -HealthSummary $newHealthSummary
        Write-LogMessage -Type INFO -Message "vSAN cluster health is green after repair for cluster `"$ClusterName`". Proceeding."
        return $null
    }

    $newFailureReasons = Get-VsanHealthFailureReasons -HealthSummary $newHealthSummary
    Write-LogMessage -Type DEBUG -Message "Health still not green after repair. overallHealth=$newOverallHealth, failureReasons=$newFailureReasons"
    return [PSCustomObject]@{ HealthSummary = $newHealthSummary; OverallHealth = $newOverallHealth; FailureReasons = $newFailureReasons }
}
function Invoke-VsanClusterHealthCheckAfterWitness {

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
    
        .EXAMPLE
        Invoke-VsanClusterHealthCheckAfterWitness -ClusterName "edge-cluster-1"
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [Switch]$AcceptBadCheckResults,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [ValidateRange(0, 120)] [Int]$HciWorkflowClearWaitSeconds = 20,
        [Parameter(Mandatory = $false)] [Switch]$LabEnvironment,
        [Parameter(Mandatory = $false)] [ValidateRange(60, 3600)] [Int]$RepairTaskTimeoutSeconds = 600,
        [Parameter(Mandatory = $false)] [ValidateRange(60, 600)] [Int]$RetryWaitSeconds = 180,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 12)] [Int]$StatsPrimaryElectionRetryMaxAttempts = 4,
        [Parameter(Mandatory = $false)] [ValidateRange(5, 600)] [Int]$StatsPrimaryElectionRetryWaitSeconds = 45,
        [Parameter(Mandatory = $false)] [ValidateRange(60, 900)] [Int]$StatsPrimaryHealthTestVmCreateTimeoutSeconds = 120,
        [Parameter(Mandatory = $false)] [ValidateSet("vSAN-ESA", "vSAN-OSA")] [String]$StoragePolicyType
    )

    Write-LogMessage -Type DEBUG -Message "Running vSAN cluster health check for cluster `"$ClusterName`" (after witness)."

    $connectionTest = Test-VcenterConnection
    if (-not $connectionTest.IsConnected) {
        $err = "Not connected to vCenter: $($connectionTest.ErrorMessage)"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }

    Enable-VsanHealthAlarms -ClusterName $ClusterName | Out-Null
    Invoke-AbandonHciWorkflowIfInProgress -ClusterName $ClusterName
    if ($HciWorkflowClearWaitSeconds -gt 0) {
        Write-LogMessage -Type DEBUG -Message "Waiting $HciWorkflowClearWaitSeconds seconds for vSAN health service to reflect HCI workflow skip."
        Start-Sleep -Seconds $HciWorkflowClearWaitSeconds
    }
    if ($LabEnvironment) {
        Set-VsanLabSilentChecksIfRequested -ClusterName $ClusterName -LabEnvironmentEnabled $true
    }

    $healthSummary = Get-VsanClusterHealthSummaryViaView -ClusterName $ClusterName -FetchFromCache:$false
    if (-not $healthSummary) {
        Write-VsanHealthFailureDebugInfo -ClusterName $ClusterName -Context 'health_summary_null'
        $err = "Could not retrieve vSAN health summary for cluster `"$ClusterName`"."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }

    if (Test-VsanClusterPartitioned -HealthSummary $healthSummary) {
        $healthSummary = Invoke-VsanInitialPartitionRepair -ClusterName $ClusterName -HealthSummary $healthSummary -RepairTaskTimeoutSeconds $RepairTaskTimeoutSeconds
    }

    $overallHealth = if ($healthSummary.overallHealth) { $healthSummary.overallHealth } else { 'unknown' }
    if ($overallHealth -eq 'green') {
        Test-VsanAdvCfgSyncAndWaitIfNeeded -ClusterName $ClusterName -HealthSummary $healthSummary
        Write-LogMessage -Type INFO -Message "vSAN cluster health is green for cluster `"$ClusterName`". Proceeding."
        return
    }

    # Transient Stats Primary election/selection: re-trigger health evaluation without silencing checks.
    $statsResult = Invoke-VsanStatsPrimaryRetry -ClusterName $ClusterName -HealthSummary $healthSummary `
        -OverallHealth $overallHealth -RetryMaxAttempts $StatsPrimaryElectionRetryMaxAttempts `
        -RetryWaitSeconds $StatsPrimaryElectionRetryWaitSeconds -VmCreateTimeoutSeconds $StatsPrimaryHealthTestVmCreateTimeoutSeconds
    if ($null -eq $statsResult) { return }
    $healthSummary = $statsResult.HealthSummary
    $overallHealth = $statsResult.OverallHealth

    $failureReasons = Get-VsanHealthFailureReasons -HealthSummary $healthSummary
    $overallDescription = $healthSummary.overallHealthDescription
    $networkDesc = if ($healthSummary.networkHealth -and $healthSummary.networkHealth.description) { $healthSummary.networkHealth.description } else { $null }
    Write-LogMessage -Type DEBUG -Message "vSAN health not green. overallHealth=$overallHealth, overallHealthDescription=$overallDescription, failureReasons=$failureReasons, networkHealthDescription=$networkDesc"
    Write-LogMessage -Type WARNING -Message "vSAN cluster health is not green for `"$ClusterName`" (status: $overallHealth): $failureReasons"

    # When the only reported issue is "vSAN health alarms are suppressed", recheck after re-skipping HCI workflow.
    $onlySuppressedAlarm = ($failureReasons -match 'alarms are suppressed|hciskip') -and ($failureReasons -notmatch 'partition|Network misconfiguration|resync')
    if ($onlySuppressedAlarm -and $HciWorkflowClearWaitSeconds -gt 0) {
        $suppressedResult = Invoke-VsanSuppressedAlarmRecheck -ClusterName $ClusterName -HealthSummary $healthSummary `
            -FailureReasons $failureReasons -OverallHealth $overallHealth -HciWorkflowClearWaitSeconds $HciWorkflowClearWaitSeconds
        if ($null -eq $suppressedResult) { return }
        $healthSummary = $suppressedResult.HealthSummary
        $failureReasons = $suppressedResult.FailureReasons
        $overallHealth = $suppressedResult.OverallHealth
    }

    if (Test-VsanHealthSuggestsPartitionOrNetwork -HealthSummary $healthSummary) {
        $repairResult = Invoke-VsanNetworkPartitionRepairAndRecheck -ClusterName $ClusterName -HealthSummary $healthSummary `
            -FailureReasons $failureReasons -OverallHealth $overallHealth -RepairTaskTimeoutSeconds $RepairTaskTimeoutSeconds
        if ($null -eq $repairResult) { return }
        $healthSummary = $repairResult.HealthSummary
        $overallHealth = $repairResult.OverallHealth
        $failureReasons = $repairResult.FailureReasons
    }

    $roundParams = @{
        ClusterName            = $ClusterName
        RetryWaitSeconds       = $RetryWaitSeconds
        FallbackFailureReasons = $failureReasons
        FallbackOverallHealth  = $overallHealth
        AcceptBadCheckResults  = $AcceptBadCheckResults.IsPresent
    }
    if ($StoragePolicyType) { $roundParams["StoragePolicyType"] = $StoragePolicyType }
    Invoke-VsanHealthCheckRound @roundParams
}
function Remove-StorageTag {

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
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$Server = $Script:vCenterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$TagCatalog,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$TagName
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
function Remove-TagCategoryIfEmpty {

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
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$Server = $Script:vCenterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$TagCatalog
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
function Invoke-PauseBeforeRollbackIfRequested {

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
    
        .EXAMPLE
        Invoke-PauseBeforeRollbackIfRequested
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
            if ([String]::IsNullOrWhiteSpace($response)) {
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
function Get-CanonicalNameFromVsanStoragePoolDisk {
    <#
        .SYNOPSIS
        Returns the disk canonical name from a VsanStoragePoolDisk object for use with Get-VsanStoragePoolDisk -DiskCanonicalName.
        .DESCRIPTION
        Checks CanonicalName, Disk.CanonicalName, ExtensionData.disk.canonicalName, and any property whose name contains Canonical.
        .OUTPUTS
        String or $null.
    
        .EXAMPLE
        $canonicalNameFromVsanStoragePoolDisk = Get-CanonicalNameFromVsanStoragePoolDisk -VsanStoragePoolDisk "value"
    #>
    [CmdletBinding()]
    [OutputType([String])]
    Param ([Parameter(Mandatory = $true)] $VsanStoragePoolDisk)
    $disk = $VsanStoragePoolDisk
    if ($disk.PSObject.Properties['CanonicalName'] -and -not [String]::IsNullOrWhiteSpace([String]$disk.CanonicalName)) {
        return $disk.CanonicalName
    }
    if ($disk.PSObject.Properties['Disk'] -and $null -ne $disk.Disk -and $disk.Disk.PSObject.Properties['CanonicalName'] -and -not [String]::IsNullOrWhiteSpace([String]$disk.Disk.CanonicalName)) {
        return $disk.Disk.CanonicalName
    }
    $extensionData = $disk.ExtensionData
    if ($null -ne $extensionData) {
        if ($extensionData.PSObject.Properties['disk'] -and $null -ne $extensionData.disk -and $extensionData.disk.PSObject.Properties['canonicalName'] -and -not [String]::IsNullOrWhiteSpace([String]$extensionData.disk.canonicalName)) {
            return $extensionData.disk.canonicalName
        }
        if ($extensionData.PSObject.Properties['Disk'] -and $null -ne $extensionData.Disk -and $extensionData.Disk.PSObject.Properties['CanonicalName'] -and -not [String]::IsNullOrWhiteSpace([String]$extensionData.Disk.CanonicalName)) {
            return $extensionData.Disk.CanonicalName
        }
    }
    foreach ($property in $disk.PSObject.Properties) {
        if ($property.Name -match 'canonical|Canonical' -and $null -ne $property.Value -and -not [String]::IsNullOrWhiteSpace([String]$property.Value)) {
            return $property.Value
        }
    }
    return $null
}
function Invoke-EsxcliVsanStoragePoolRemoveFallback {
    <#
        .SYNOPSIS
        Attempts to remove vSAN ESA storage pool disks via esxcli when PowerCLI could not remove them.
        .DESCRIPTION
        Runs esxcli vsan storagepool list, then remove for each disk (by disk name or UUID). Used when Get-VsanStoragePoolDisk returns objects with null Key.
        .OUTPUTS
        PSCustomObject with RemainingCount and RemovedCount, or $null on failure.
    
        .EXAMPLE
        Invoke-EsxcliVsanStoragePoolRemoveFallback -HostNameForLogging "resource-name" -Server $vcenterConnection -VMHost $vmHostObject
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$HostNameForLogging,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Server,
        [Parameter(Mandatory = $true)] $VMHost
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
                if ($listItem.PSObject.Properties[$propertyName] -and -not [String]::IsNullOrWhiteSpace([String]$listItem.$propertyName)) {
                    $diskIdentifier = $listItem.$propertyName
                    break
                }
            }
            if (-not $diskIdentifier) {
                foreach ($propertyName in $uuidPropertyNames) {
                    if ($listItem.PSObject.Properties[$propertyName] -and -not [String]::IsNullOrWhiteSpace([String]$listItem.$propertyName)) {
                        $diskIdentifier = $listItem.$propertyName
                        $useUuidParam = $true
                        break
                    }
                }
            }
            if ([String]::IsNullOrWhiteSpace([String]$diskIdentifier)) { continue }
            $removeParamName = $null
            $createArgs = $removeCmd.CreateArgs()
            if ($createArgs) {
                foreach ($param in $createArgs.PSObject.Properties) {
                    if ([String]::IsNullOrWhiteSpace([String]$param.Name)) { continue }
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
function Invoke-VsanOsaDiskGroupRemoval {

    <#
        .SYNOPSIS
        Removes a single vSAN OSA disk group from a host and returns whether it succeeded.

        .DESCRIPTION
        Calls Remove-VsanDiskGroup in no-data-migration mode. Logs a DEBUG message before and after
        removal. On failure, logs a WARNING and returns $false. Returns $true on success.

        .PARAMETER DiskGroup
        The vSAN OSA disk group object to remove.

        .PARAMETER HostName
        The host name string (used in log messages).

        .EXAMPLE
        if (-not (Invoke-VsanOsaDiskGroupRemoval -DiskGroup $diskGroup -HostName $hostName)) { $removeFailCount++ }

        .OUTPUTS
        Bool: $true if removal succeeded, $false if it failed.
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] $DiskGroup,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$HostName
    )

    try {
        Write-LogMessage -Type DEBUG -Message "Removing vSAN OSA disk group from host `"$HostName`"."
        Remove-VsanDiskGroup -VsanDiskGroup $DiskGroup -DataMigrationMode NoDataMigration -Confirm:$false -ErrorAction Stop
        Write-LogMessage -Type DEBUG -Message "Removed vSAN OSA disk group from host `"$HostName`"."
        return $true
    } catch {
        Write-LogMessage -Type WARNING -Message "Failed to remove vSAN OSA disk group on host `"$HostName`": $($_.Exception.Message)"
        return $false
    }
}
function Invoke-VsanEsaStoragePoolDiskRemoval {

    <#
        .SYNOPSIS
        Removes a single vSAN ESA storage pool disk from a host, with null-key and retry handling.

        .DESCRIPTION
        Attempts to remove one vSAN ESA storage pool disk from the host. Handles the null-key corner case
        (disk object with a missing Key property) by first attempting removal as-is, then re-querying by
        CanonicalName to obtain a key-bearing object. For normal disks, retries once on retryable vSAN
        errors (e.g. "Failed to delete storage pool disk", "General vSAN error").

        Returns 1 if the disk was removed, or 0 if it was skipped or removal failed.

        .PARAMETER Disk
        The vSAN storage pool disk object to remove.

        .PARAMETER HostName
        The host name string (used in log messages).

        .PARAMETER MaxRemoveAttempts
        Number of removal attempts for retryable errors. Default is 2.

        .PARAMETER RemoveRetryDelaySeconds
        Seconds to wait between removal retries. Default is 15.

        .PARAMETER Server
        vCenter server name. Default is $Script:vCenterName.

        .PARAMETER VMHost
        The VMHost object (used to re-query by canonical name when the disk Key is null).

        .EXAMPLE
        $removedCount = Invoke-VsanEsaStoragePoolDiskRemoval -Disk $disk -HostName $hostName -VMHost $vmHost -Server $Script:vCenterName

        .OUTPUTS
        Int: 1 if the disk was removed, 0 if skipped or failed.
    #>

    [CmdletBinding()]
    [OutputType([Int])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] $Disk,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$HostName,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 10)] [Int]$MaxRemoveAttempts = 2,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 120)] [Int]$RemoveRetryDelaySeconds = 15,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$Server = $Script:vCenterName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] $VMHost
    )

    $diskId = $null
    if ($Disk.PSObject.Properties['Id']) { $diskId = $Disk.PSObject.Properties['Id'].Value }
    if ($null -eq $diskId -or [String]::IsNullOrWhiteSpace([String]$diskId)) {
        Write-LogMessage -Type DEBUG -Message "Skipping vSAN ESA storage pool disk with null or missing Id on host `"$HostName`" (avoids Remove-VsanStoragePoolDisk 'key' error)."
        return 0
    }
    $diskKey = $null
    if ($Disk.PSObject.Properties['Key']) { $diskKey = $Disk.PSObject.Properties['Key'].Value }
    $keyIsNull = ($null -eq $diskKey -or [String]::IsNullOrWhiteSpace([String]$diskKey))
    if ($keyIsNull) {
        $removedViaNullKeyAttempt = $false
        try {
            $null = Remove-VsanStoragePoolDisk -VsanStoragePoolDisk $Disk -VsanDataMigrationMode NoDataMigration -Confirm:$false -ErrorAction Stop
            $removedViaNullKeyAttempt = $true
            Write-LogMessage -Type DEBUG -Message "Removed vSAN ESA storage pool disk (object with null Key accepted) from host `"$HostName`"."
        } catch {
            $errorMessage = $_.Exception.Message
            if ($errorMessage -match "Parameter 'key'|Value cannot be null.*key") {
                $canonicalName = Get-CanonicalNameFromVsanStoragePoolDisk -VsanStoragePoolDisk $Disk
                if ($canonicalName) {
                    $refetchedDisks = @(Get-VsanStoragePoolDisk -VMHost $VMHost -DiskCanonicalName $canonicalName -Server $Server -ErrorAction SilentlyContinue | Where-Object { $null -ne $_ })
                    foreach ($refetchedDisk in $refetchedDisks) {
                        $refetchedKey = $null
                        if ($refetchedDisk.PSObject.Properties['Key']) { $refetchedKey = $refetchedDisk.PSObject.Properties['Key'].Value }
                        if ($null -ne $refetchedKey -and -not [String]::IsNullOrWhiteSpace([String]$refetchedKey)) {
                            try {
                                $null = Remove-VsanStoragePoolDisk -VsanStoragePoolDisk $refetchedDisk -VsanDataMigrationMode NoDataMigration -Confirm:$false -ErrorAction Stop
                                Write-LogMessage -Type DEBUG -Message "Removed vSAN ESA storage pool disk (re-queried by canonical name) from host `"$HostName`"."
                                $removedViaNullKeyAttempt = $true
                            } catch {
                                Write-LogMessage -Type DEBUG -Message "Remove-VsanStoragePoolDisk after re-query by canonical name failed: $($_.Exception.Message)."
                            }
                            break
                        }
                    }
                }
                if (-not $removedViaNullKeyAttempt) {
                    $diskPropertyNames = @($Disk.PSObject.Properties | Where-Object { $_.Name } | Select-Object -ExpandProperty Name)
                    Write-LogMessage -Type DEBUG -Message "Skipping vSAN ESA storage pool disk with null Key and no CanonicalName on host `"$HostName`". Disk object properties: $($diskPropertyNames -join ', '). Remove manually in vCenter if needed."
                }
            } else {
                Write-LogMessage -Type WARNING -Message "Remove-VsanStoragePoolDisk failed for disk with null Key on host `"$HostName`": $errorMessage"
            }
        }
        return [Int]$removedViaNullKeyAttempt
    }
    for ($attempt = 1; $attempt -le $MaxRemoveAttempts; $attempt++) {
        try {
            $null = Remove-VsanStoragePoolDisk -VsanStoragePoolDisk $Disk -VsanDataMigrationMode NoDataMigration -Confirm:$false -ErrorAction Stop
            Write-LogMessage -Type DEBUG -Message "Removed one vSAN ESA storage pool disk from host `"$HostName`"."
            return 1
        } catch {
            $errorMessage = $_.Exception.Message
            if ($errorMessage -match "Parameter 'key'|Value cannot be null.*key") {
                Write-LogMessage -Type WARNING -Message "Skipping vSAN ESA storage pool disk on host `"$HostName`" (cmdlet reported null key). Remove manually in vCenter if needed."
                return 0
            }
            $isRetryableVsanError = ($errorMessage -match "Failed to delete storage pool disk|General vSAN error")
            if ($attempt -lt $MaxRemoveAttempts -and $isRetryableVsanError) {
                Write-LogMessage -Type DEBUG -Message "Remove-VsanStoragePoolDisk failed (attempt $attempt of $MaxRemoveAttempts); retrying in $RemoveRetryDelaySeconds seconds. Error: $errorMessage"
                Start-Sleep -Seconds $RemoveRetryDelaySeconds
            } else {
                Write-LogMessage -Type WARNING -Message "Failed to remove one vSAN ESA storage pool disk from host `"$HostName`": $errorMessage"
                if ($isRetryableVsanError) {
                    Write-LogMessage -Type WARNING -Message "If the cluster is still in use or rebalancing, remove the disk manually via vCenter (put host in maintenance mode first if needed) or retry rollback when vSAN is idle."
                }
                return 0
            }
        }
    }
    return 0
}
function Remove-VsanDiskClaimsFromHost {

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
    
        .EXAMPLE
        Remove-VsanDiskClaimsFromHost -StoragePolicyType "storage-policy" -VMHost $vmHostObject
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
                    $removedCount = Invoke-VsanEsaStoragePoolDiskRemoval -Disk $disk -HostName $hostName -MaxRemoveAttempts $maxRemoveAttempts -RemoveRetryDelaySeconds $RemoveRetryDelaySeconds -Server $Server -VMHost $VMHost
                    $removedThisRound += $removedCount
                    $totalRemoved += $removedCount
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
                if (-not (Invoke-VsanOsaDiskGroupRemoval -DiskGroup $diskGroup -HostName $hostName)) { $removeFailCount++ }
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
function Remove-VmfsDatastoreForCluster {

    <#
        .SYNOPSIS
        Removes a VMFS datastore by name from vCenter. Used during VMFS deployment cleanup (-CleanUp Compute or All) as the final step before cluster removal.

        .DESCRIPTION
        Looks up the datastore by name on the connected vCenter server. If found, removes the datastore (unmounts and deletes).
        If the datastore does not exist, logs at DEBUG and returns. Failures during removal are logged as warnings and not rethrown.
        Call this after supervisor deactivation and VDS removal when cleaning up a VMFS-based edge cluster.

        When the datastore reports "in use" (typically a brief window after VDS removal while the host
        reconfiguration settles), the removal is retried up to MaxRetries times before giving up.

        .PARAMETER ClusterName
        Name of the cluster (for logging context). Not used for datastore lookup.

        .PARAMETER DatastoreName
        Name of the VMFS datastore to remove (e.g. from Get-DatastoreNameFromPrefix).

        .PARAMETER MaxRetries
        Number of additional attempts to make when the datastore reports "in use". Defaults to 3.

        .PARAMETER RetryDelaySeconds
        Seconds to wait between retry attempts. Defaults to 15.

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
        [Parameter(Mandatory = $false)] [ValidateRange(0, 10)] [Int]$MaxRetries = 3,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 120)] [Int]$RetryDelaySeconds = 15,
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

    $attempt = 0
    while ($attempt -le $MaxRetries) {
        try {
            Write-LogMessage -Type INFO -NoNewline -Message "Removing VMFS datastore `"$DatastoreName`" for cluster `"$ClusterName`"... "
            Remove-Datastore -Datastore $datastore -VMHost $vmhost -Confirm:$false -WarningAction SilentlyContinue -ErrorAction Stop
            Write-LogMessage -Type INFO -CompletePending -Message "Done"
            return
        } catch {
            $errMsg = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
            # Strip the PowerCLI warning prefix (e.g. "5/28/2026 7:32:21 AM       Remove-Datastore                ") that
            # PowerCLI embeds in the exception message when a non-terminating error is promoted by -ErrorAction Stop.
            $errMsg = ($errMsg -replace '^\d{1,2}/\d{1,2}/\d{4}\s+\d{1,2}:\d{2}:\d{2}\s+[AP]M\s+\S+\s+', '').Trim()
            # "in use" is a transient condition that occurs briefly after VDS removal while the host
            # reconfiguration task settles. Retry with a delay rather than failing immediately.
            $isInUse = $errMsg -match "in use"
            if ($isInUse -and $attempt -lt $MaxRetries) {
                Write-LogMessage -Type INFO -CompletePending -Message "In use (attempt $($attempt + 1)/$($MaxRetries + 1)); retrying in $RetryDelaySeconds s..."
                Start-Sleep -Seconds $RetryDelaySeconds
                $attempt++
            } else {
                Write-LogMessage -Type INFO -CompletePending -Message "Failed."
                Write-LogMessage -Type WARNING -Message "Could not remove VMFS datastore `"$DatastoreName`" for cluster `"$ClusterName`": $errMsg. Remove the datastore manually in vCenter if desired."
                return
            }
        }
    }
}

#Invoke-VsanDeploymentRollback helpers
function Invoke-VsanClusterLeaveOnHostWithRetry {

    <#
        .SYNOPSIS
        Runs esxcli vsan cluster leave on a single host with retries. Used by Invoke-VsanDeploymentRollback.
        .OUTPUTS
        $true if leave succeeded or host was not in a vSAN cluster; $false if leave failed after retries or command not available.
    
        .EXAMPLE
        Invoke-VsanClusterLeaveOnHostWithRetry -Server $vcenterConnection -VMHost $vmHostObject
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $false)] [String]$LogContext = "",
        [Parameter(Mandatory = $false)] [ValidateRange(1, 10)] [Int]$MaxRetries = 3,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 120)] [Int]$RetryDelaySeconds = 15,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Server,
        [Parameter(Mandatory = $true)] $VMHost
    )
    $hostNameForLogging = $VMHost.Name
    $contextSuffix = if ([String]::IsNullOrWhiteSpace($LogContext)) { "" } else { " ($LogContext)" }
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
function Invoke-VsanOrphanedHostCleanup {

    <#
        .SYNOPSIS
        Cleans up vSAN disk claims and runs vSAN cluster leave on orphaned config hosts when the target cluster is no longer in vCenter.

        .DESCRIPTION
        Called by Invoke-VsanDeploymentRollback when the target cluster object is not found.
        Resolves each host from EsxHostNames, removes disk claims (or disk groups for OSA) per
        Broadcom KB 326861, runs esxcli vsan cluster leave, and removes the storage tag/category
        when provided. The witness host is never modified. Hosts not found in vCenter are skipped
        with a DEBUG log.

        .PARAMETER ClusterName
        Cluster name used for log messages only (the cluster is not present).

        .PARAMETER EsxHostNames
        Array of ESX host names from the deployment configuration to resolve and clean.

        .PARAMETER MaxVsanLeaveRetries
        Maximum number of retry attempts for esxcli vsan cluster leave per host.

        .PARAMETER StoragePolicyTagCatalog
        Tag category containing the storage tag. Required when StoragePolicyTagName is provided.

        .PARAMETER StoragePolicyTagName
        Name of the storage tag to delete during cleanup.

        .PARAMETER StoragePolicyType
        vSAN type: vSAN-ESA or vSAN-OSA.

        .PARAMETER VsanLeaveRetryDelaySeconds
        Seconds to wait between retry attempts for esxcli vsan cluster leave.

        .PARAMETER WitnessHostName
        Witness host name for logging only; cleanup never modifies the witness.

        .EXAMPLE
        Invoke-VsanOrphanedHostCleanup -ClusterName "cl0" -EsxHostNames @("esx1.lab") -StoragePolicyType "vSAN-OSA" -MaxVsanLeaveRetries 3 -VsanLeaveRetryDelaySeconds 15

        .NOTES
        Private helper for Invoke-VsanDeploymentRollback. Optional string parameters
        ($StoragePolicyTagCatalog, $StoragePolicyTagName, $WitnessHostName) intentionally omit
        [ValidateNotNullOrEmpty()] because the parent forwards them as $null when the caller
        did not supply them; each is guarded by an explicit null check before use.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [String[]]$EsxHostNames,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 10)] [Int]$MaxVsanLeaveRetries = 3,
        [Parameter(Mandatory = $false)] [String]$StoragePolicyTagCatalog,
        [Parameter(Mandatory = $false)] [String]$StoragePolicyTagName,
        [Parameter(Mandatory = $true)] [ValidateSet("vSAN-ESA", "vSAN-OSA")] [String]$StoragePolicyType,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 120)] [Int]$VsanLeaveRetryDelaySeconds = 15,
        [Parameter(Mandatory = $false)] [String]$WitnessHostName
    )

    $hostsToClean = [System.Collections.Generic.List[object]]::new()
    if ($EsxHostNames -and $EsxHostNames.Count -gt 0) {
        foreach ($hostNameInConfig in $EsxHostNames) {
            $resolvedHost = Get-VMHost -Name $hostNameInConfig -Server $Script:vCenterName -ErrorAction SilentlyContinue
            if ($resolvedHost) { $hostsToClean.Add($resolvedHost) } else { Write-LogMessage -Type DEBUG -Message "Orphaned host `"$hostNameInConfig`" not found in vCenter; skipping." }
        }
    }
    $isVsanOrphaned = ($StoragePolicyType -eq "vSAN-ESA" -or $StoragePolicyType -eq "vSAN-OSA") -and $hostsToClean.Count -gt 0
    if ($hostsToClean.Count -gt 0) {
        if ($isVsanOrphaned) {
            Write-LogMessage -Type WARNING -Message "Cluster `"$ClusterName`" not found; cleaning orphaned disk pools and their claimed disks from $($hostsToClean.Count) config host(s) (witness not modified)."
        } else {
            Write-LogMessage -Type WARNING -Message "Cluster `"$ClusterName`" not found; running cleanup on $($hostsToClean.Count) config host(s)."
        }
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
}
function Invoke-VsanDataHostDiskCleanup {

    <#
        .SYNOPSIS
        Removes vSAN disk claims, runs vSAN cluster leave, and removes the storage tag for data hosts in an existing cluster.

        .DESCRIPTION
        Called by Invoke-VsanDeploymentRollback when the target cluster exists. Determines the hosts
        to clean from the live cluster object (preferred) or from EsxHostNames as fallback. Removes
        disk claims per Broadcom KB 326861 (disks first, then vSAN cluster leave), then removes the
        storage tag and category when provided. Logs the SkipClusterRemoval warning when the caller
        must handle VDS and cluster removal separately.

        .PARAMETER ClusterHosts
        Resolved host objects from Get-VMHost on the cluster. May be $null when HasHosts is $false.

        .PARAMETER ClusterName
        Cluster name used for log messages.

        .PARAMETER EsxHostNames
        Fallback host name list from configuration. Used when HasHosts is $false.

        .PARAMETER HasHosts
        Pre-computed flag: $true when ClusterHosts is non-empty.

        .PARAMETER MaxVsanLeaveRetries
        Maximum number of retry attempts for esxcli vsan cluster leave per host.

        .PARAMETER SkipClusterRemoval
        When set, emits the caller-responsibility warning. Indicates the caller will handle VDS and cluster removal.

        .PARAMETER StoragePolicyTagCatalog
        Tag category containing the storage tag. Required when StoragePolicyTagName is provided.

        .PARAMETER StoragePolicyTagName
        Name of the storage tag to delete during cleanup.

        .PARAMETER StoragePolicyType
        vSAN type: vSAN-ESA or vSAN-OSA.

        .PARAMETER VsanLeaveRetryDelaySeconds
        Seconds to wait between retry attempts for esxcli vsan cluster leave.

        .PARAMETER WitnessHostName
        Witness host name for logging only; cleanup never modifies the witness.

        .EXAMPLE
        Invoke-VsanDataHostDiskCleanup -ClusterHosts $clusterHosts -ClusterName "cl0" -HasHosts $true -StoragePolicyType "vSAN-OSA" -MaxVsanLeaveRetries 3 -VsanLeaveRetryDelaySeconds 15

        .NOTES
        Private helper for Invoke-VsanDeploymentRollback. Optional string parameters
        ($StoragePolicyTagCatalog, $StoragePolicyTagName, $WitnessHostName) intentionally omit
        [ValidateNotNullOrEmpty()] because the parent forwards them as $null when the caller
        did not supply them; each is guarded by an explicit null check before use.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [AllowNull()] [Object[]]$ClusterHosts,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [String[]]$EsxHostNames,
        [Parameter(Mandatory = $true)] [Bool]$HasHosts,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 10)] [Int]$MaxVsanLeaveRetries = 3,
        [Parameter(Mandatory = $false)] [Switch]$SkipClusterRemoval,
        [Parameter(Mandatory = $false)] [String]$StoragePolicyTagCatalog,
        [Parameter(Mandatory = $false)] [String]$StoragePolicyTagName,
        [Parameter(Mandatory = $true)] [ValidateSet("vSAN-ESA", "vSAN-OSA")] [String]$StoragePolicyType,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 120)] [Int]$VsanLeaveRetryDelaySeconds = 15,
        [Parameter(Mandatory = $false)] [String]$WitnessHostName
    )

    if (-not $HasHosts) {
        Write-LogMessage -Type DEBUG -Message "No hosts in cluster `"$ClusterName`"; will try config hosts (EsxHostNames) for disk removal and vsan leave if provided, then tag cleanup and cluster removal."
    }
    if ($WitnessHostName) {
        Write-LogMessage -Type DEBUG -Message "Witness host `"$WitnessHostName`" is shared by multiple clusters; cleanup never modifies witness storage pool or disk claims."
    }
    $hostsForDiskRemoval = [System.Collections.Generic.List[object]]::new()
    if ($HasHosts) {
        foreach ($clusterHost in $ClusterHosts) { $hostsForDiskRemoval.Add($clusterHost) }
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
}
function Invoke-VsanDeploymentRollback {

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
        Sets $Script:RollbackAttempted = $true to signal that a rollback was performed;
        the deployment orchestrator checks this flag to determine the final run status.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [String[]]$EsxHostNames,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 10)] [Int]$MaxVsanLeaveRetries = 3,
        [Parameter(Mandatory = $false)] [Switch]$SkipClusterRemoval,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$StoragePolicyTagCatalog,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$StoragePolicyTagName,
        [Parameter(Mandatory = $true)] [ValidateSet("vSAN-ESA", "vSAN-OSA")] [String]$StoragePolicyType,
        [Parameter(Mandatory = $false)] [Switch]$SuppressPrompt,
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
        $clusterObject = Get-ClusterByName -Name $ClusterName -Server $Script:vCenterName
        $clusterHosts = $null
        $hasHosts = $false
        if ($clusterObject) {
            $clusterHosts = Get-VMHost -Location $clusterObject -Server $Script:vCenterName -ErrorAction SilentlyContinue
            $hasHosts = $clusterHosts -and $clusterHosts.Count -gt 0
        }

        if (-not $clusterObject) {
            Invoke-VsanOrphanedHostCleanup `
                -ClusterName $ClusterName `
                -EsxHostNames $EsxHostNames `
                -MaxVsanLeaveRetries $MaxVsanLeaveRetries `
                -StoragePolicyTagCatalog $StoragePolicyTagCatalog `
                -StoragePolicyTagName $StoragePolicyTagName `
                -StoragePolicyType $StoragePolicyType `
                -VsanLeaveRetryDelaySeconds $VsanLeaveRetryDelaySeconds `
                -WitnessHostName $WitnessHostName
            return
        }

        Invoke-VsanDataHostDiskCleanup `
            -ClusterHosts $clusterHosts `
            -ClusterName $ClusterName `
            -EsxHostNames $EsxHostNames `
            -HasHosts $hasHosts `
            -MaxVsanLeaveRetries $MaxVsanLeaveRetries `
            -SkipClusterRemoval:$SkipClusterRemoval.IsPresent `
            -StoragePolicyTagCatalog $StoragePolicyTagCatalog `
            -StoragePolicyTagName $StoragePolicyTagName `
            -StoragePolicyType $StoragePolicyType `
            -VsanLeaveRetryDelaySeconds $VsanLeaveRetryDelaySeconds `
            -WitnessHostName $WitnessHostName
    } catch {
        $Script:RollbackFailed = $true
        Write-LogMessage -Type ERROR -Message "vSAN rollback encountered an error: $($_.Exception.Message). Script will exit with failure."
        throw
    }
}

#endregion
function Find-Datastore {

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

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DatastoreName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EsxHostName
    )
    Write-LogMessage -Type DEBUG -Message "Entered Find-Datastore function..."

    $getDatastoreParams = @{
        esxHostName = $EsxHostName
        datastoreName = $DatastoreName
        silence = $true
    }
    $result = Get-EsxDatastoreInfo @getDatastoreParams

    if (-not $result.MountedDatastoreStatus.IsMounted) {
        Write-LogMessage -Type INFO -Message "Datastore `"$DatastoreName`" not found on ESX host `"$EsxHostName`"."
        $unformattedOnlyParams = @{
            EsxHostName = $EsxHostName
            Silence = $true
        }
        $unformattedResult = Get-EsxDatastoreInfo @unformattedOnlyParams
        $unformattedDisks = $unformattedResult.UnformattedDisks
        if (-not $unformattedDisks -or $unformattedDisks.Count -eq 0) {
            $err = "No unformatted disks found on ESX host `"$EsxHostName`". Cannot create VMFS datastore `"$DatastoreName`"."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
        $selectedDisk = $unformattedDisks | Sort-Object -Property @{ Expression = { [Double]$_.CapacityGB }; Descending = $true }, @{ Expression = { $_.CanonicalName }; Ascending = $true } | Select-Object -First 1
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
                $err = "Could not retrieve canonical name for datastore `"$DatastoreName`""
                Write-LogMessage -Type ERROR -Message $err
                throw [VcfDeploymentException]::new($err)
            }
        }
        else {
            $err = "Datastore `"$DatastoreName`" is mounted, but in unexpected type: (Type: $($result.MountedDatastoreStatus.Type)). Cannot proceed."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
    }
}
function Get-SoftwareSpecComponents {

    <#
        .SYNOPSIS
        Extracts vLCM SoftwareSpec components into a flat ordered hashtable for display.

        .DESCRIPTION
        Handles two input forms returned by different VCF PowerCLI / vCenter versions:
        - PSObject: walks properties using a field map with IsVersion and IsCollection flags.
        - String:   parses the serialized representation (e.g. "BaseImage: Version: 9.0.0").
        Returns an ordered hashtable keyed by component name (AlternativeImages, AddOn, BaseImage,
        Components, HardwareSupport, RemovedComponents, Solutions); missing fields are $null.

        .PARAMETER SoftwareSpec
        The SoftwareSpec value from a vLCM image record. May be a PSObject, string, or $null.

        .OUTPUTS
        [ordered] hashtable with one key per SoftwareSpec component field.

        .NOTES
        The field map drives both the PSObject and string-parsing paths so both stay in sync when
        new fields are added. Internal helper for Find-VlcmImage — not intended for direct use.
    
        .EXAMPLE
        $softwareSpecComponents = Get-SoftwareSpecComponents -SoftwareSpec $resourceObject
    #>

    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    Param (
        [Parameter(Mandatory = $true)] [AllowNull()] [PSObject]$SoftwareSpec
    )

    $fieldMap = @(
        @{ Key = "AlternativeImages"; Label = "AlternativeImages"; IsCollection = $true },
        @{ Key = "AddOn";             Label = "AddOn" },
        @{ Key = "BaseImage";         Label = "BaseImage"; IsVersion = $true },
        @{ Key = "Components";        Label = "Components"; IsCollection = $true },
        @{ Key = "HardwareSupport";   Label = "HardwareSupport" },
        @{ Key = "RemovedComponents"; Label = "RemovedComponents"; IsCollection = $true },
        @{ Key = "Solutions";         Label = "Solutions"; IsCollection = $true }
    )

    $results = [ordered]@{ }
    foreach ($field in $fieldMap) {
        $results[$field.Key] = $null
    }

    if ($null -eq $SoftwareSpec) {
        return $results
    }

    if ($SoftwareSpec -isnot [string]) {
        foreach ($field in $fieldMap) {
            $val = $SoftwareSpec.$($field.Key)
            if ($null -ne $val) {
                if ($field.IsVersion -and $null -ne $val.Version) {
                    $results[$field.Key] = $val.Version
                } elseif ($field.IsCollection -and $val.Count -gt 0) {
                    $results[$field.Key] = $val.Keys -join ", "
                } elseif ($val -ne "") {
                    $results[$field.Key] = $val
                }
            }
        }
    } else {
        # vCenter API returned a serialized string instead of a typed object; parse it.
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
            } else {
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
function Build-VlcmImageSelectionData {

    <#
        .SYNOPSIS
        Builds the numbered display list and column roster for Find-VlcmImage's interactive table.

        .DESCRIPTION
        Two-pass processing of a vLCM image record array:
        - Pass 1: scans every record to discover which optional SoftwareSpec columns are populated.
        - Pass 2: constructs a PSCustomObject per record containing the ID counter, DisplayName,
          BaseImage version, ImageId (hidden), and any populated optional columns.
        Returns a PSCustomObject with ColumnList (ordered for Select-Object / Format-Table) and
        SelectionList (list of display rows).

        .PARAMETER ImageRecords
        The Records array from Invoke-EsxSettingsRepositorySoftwareList output.

        .OUTPUTS
        [PSCustomObject] with ColumnList ([String[]]) and SelectionList ([List[PSCustomObject]]).

        .EXAMPLE
        $data = Build-VlcmImageSelectionData -ImageRecords $imageList.Records
        $data.SelectionList | Select-Object $data.ColumnList | Format-Table -AutoSize | Out-Host

        .NOTES
        Internal helper for Find-VlcmImage. Not intended for direct use.
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [Object[]]$ImageRecords
    )

    $optionalKeys = @('AddOn', 'Components', 'Solutions', 'HardwareSupport', 'RemovedComponents', 'AlternativeImages')
    $availableColumns = @{}
    foreach ($key in $optionalKeys) { $availableColumns[$key] = $false }

    foreach ($record in $ImageRecords) {
        $specComponents = Get-SoftwareSpecComponents -SoftwareSpec $record.SoftwareSpec
        foreach ($key in $optionalKeys) {
            if ($null -ne $specComponents[$key] -and $specComponents[$key] -ne "") {
                $availableColumns[$key] = $true
            }
        }
    }

    $columnList = [System.Collections.Generic.List[string]]@('ID', 'DisplayName', 'BaseImage')
    foreach ($key in $optionalKeys) {
        if ($availableColumns[$key]) { $columnList.Add($key) }
    }

    $selectionList = [System.Collections.Generic.List[PSCustomObject]]::new()
    $index = 1
    foreach ($record in $ImageRecords) {
        $specComponents = Get-SoftwareSpecComponents -SoftwareSpec $record.SoftwareSpec
        $imageHash = @{
            ID          = $index
            DisplayName = $record.DisplayName
            BaseImage   = if ($specComponents.BaseImage) { $specComponents.BaseImage } else { "(not available)" }
            ImageId     = $record.Id
        }
        foreach ($key in $optionalKeys) {
            if ($availableColumns[$key]) {
                $imageHash[$key] = if ($specComponents[$key]) { $specComponents[$key] } else { "" }
            }
        }
        $selectionList.Add([PSCustomObject]$imageHash)
        $index++
    }

    return [PSCustomObject]@{ ColumnList = $columnList; SelectionList = $selectionList }
}
function Invoke-VlcmImageSelectionPrompt {

    <#
        .SYNOPSIS
        Presents the numbered vLCM image table and waits for the user to pick one.

        .DESCRIPTION
        Displays the pre-built selection list, then loops on Read-Host until a valid row number
        is entered or the user types "c" to cancel. On valid input returns the chosen ImageId.
        On cancel throws VcfDeploymentException.

        .PARAMETER ImageSelectionList
        The numbered list of PSCustomObjects produced by Build-VlcmImageSelectionData.

        .PARAMETER ColumnList
        Column name list for Select-Object / Format-Table, also from Build-VlcmImageSelectionData.

        .OUTPUTS
        System.String — ImageId of the chosen vLCM image.

        .EXAMPLE
        $data = Build-VlcmImageSelectionData -ImageRecords $imageList.Records
        $imageId = Invoke-VlcmImageSelectionPrompt -ImageSelectionList $data.SelectionList -ColumnList $data.ColumnList

        .NOTES
        Write-Host is the primary output mechanism in this function; all Write-Host calls are
        intentional interactive console output. Use Write-LogMessage for diagnostic logging.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$ColumnList,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$ImageSelectionList
    )

    Write-LogMessage -Type INFO -Message "Available vLCM images:"
    # Write-Host: blank line and table output use Write-Host so the interactive table renders correctly; Write-Output can introduce rendering regression.
    Write-Host ($ImageSelectionList | Select-Object $ColumnList | Format-Table -AutoSize | Out-String).TrimEnd()
    Write-Host ""

    while ($true) {
        Write-Host "Enter the ID of the image to select (1-$($ImageSelectionList.Count)) or `"c`" to cancel: " -NoNewline
        $userInput = Read-Host

        if ($userInput -eq 'c' -or $userInput -eq 'C') {
            Write-LogMessage -Type WARNING -Message "User cancelled vLCM image selection."
            $err = "vLCM image selection cancelled. Cannot proceed with deployment."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
        elseif ($userInput -match '^\d+$') {
            $selectedId = [Int]$userInput
            if ($selectedId -ge 1 -and $selectedId -le $ImageSelectionList.Count) {
                $selectedImage = $ImageSelectionList | Where-Object { $_.ID -eq $selectedId }
                Write-LogMessage -Type DEBUG -Message "Selected image: $($selectedImage.DisplayName) - ID: $($selectedImage.ImageId)"
                return $selectedImage.ImageId
            }
            Write-LogMessage -Type WARNING -Message "Invalid selection. Please enter a number between 1 and $($ImageSelectionList.Count), or `"c`" to cancel."
        }
        else {
            Write-LogMessage -Type WARNING -Message "Invalid input. Please enter a number between 1 and $($ImageSelectionList.Count), or `"c`" to cancel."
        }
    }
}
function Find-VlcmImage {

    <#
        .SYNOPSIS
        Retrieves available vLCM images from vCenter and prompts for interactive selection.

        .DESCRIPTION
        Calls Invoke-EsxSettingsRepositorySoftwareList, displays a numbered table of images with
        their SoftwareSpec details, and waits for the user to select one by number.
        Entering "c" cancels by throwing an exception. When VlcmImageName is provided, attempts
        a non-interactive match by Id or DisplayName first; falls back to interactive if no match.

        .PARAMETER VlcmImageName
        Optional. Attempts non-interactive match by Id or DisplayName; falls back to interactive
        selection with a warning when no match is found.

        .EXAMPLE
        $imageId = Find-VlcmImage
        $imageId = Find-VlcmImage -VlcmImageName $inputData.common.vlcmImageName

        .OUTPUTS
        System.String — the Id of the selected vLCM image.

        .NOTES
        Requires an active vCenter connection. Interactive path cannot be automated.
        Write-Host is the primary output mechanism in this function; all Write-Host calls are
        intentional interactive console output. Use Write-LogMessage for diagnostic logging.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $false)] [AllowNull()] [String]$VlcmImageName
    )

    Write-LogMessage -Type DEBUG -Message "Entered Find-VlcmImage function..."

    if ([String]::IsNullOrWhiteSpace($VlcmImageName)) {
        Write-LogMessage -Type INFO -PrependNewLine -Message "Retrieving list of vLCM images from vCenter's Image Catalog..."
    }
    try {
        $imageList = Invoke-EsxSettingsRepositorySoftwareList -ErrorAction Stop
    } catch [VcfDeploymentException] {
        throw
    } catch {
        $err = "Failed to retrieve vLCM images: $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }

    $imageCount = if ($null -ne $imageList -and $null -ne $imageList.Records) { $imageList.Records.Count } else { 0 }
    if ($imageCount -eq 0) {
        $err = "No vLCM images found in the repository. Cannot proceed with deployment."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }

    Write-LogMessage -Type DEBUG -Message "Found $imageCount vLCM image(s) available."

    # Non-interactive path: match by Id or DisplayName and return without prompting.
    if (-not [String]::IsNullOrWhiteSpace($VlcmImageName)) {
        $matchedRecord = $imageList.Records | Where-Object { $_.Id -eq $VlcmImageName -or $_.DisplayName -eq $VlcmImageName } | Select-Object -First 1
        if ($matchedRecord) {
            $specComponents = Get-SoftwareSpecComponents -SoftwareSpec $matchedRecord.SoftwareSpec
            $oneRow = [PSCustomObject]@{
                DisplayName = $matchedRecord.DisplayName
                BaseImage   = if ($specComponents.BaseImage) { $specComponents.BaseImage } else { "(not available)" }
            }
            Write-LogMessage -Type INFO -Message "Using vLCM image from configuration: `"$VlcmImageName`"."
            # Write-Host: blank line and table output use Write-Host so the interactive table renders correctly; Write-Output can introduce rendering regression.
            $oneRow | Format-Table -AutoSize | Out-String | ForEach-Object { $_.TrimEnd() } | Write-Host
            Write-LogMessage -Type DEBUG -Message "Find-VlcmImage: matched image Id=$($matchedRecord.Id), DisplayName=$($matchedRecord.DisplayName)."
            return $matchedRecord.Id
        }
        Write-LogMessage -Type WARNING -Message "Specified vLcmImageName `"$VlcmImageName`" was not found in vCenter image library. Showing available images for selection."
    }

    $selectionData = Build-VlcmImageSelectionData -ImageRecords $imageList.Records
    return Invoke-VlcmImageSelectionPrompt -ImageSelectionList $selectionData.SelectionList -ColumnList $selectionData.ColumnList
}

#endregion
