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
#region Private — VDS, VMkernel cleanup, management restore
function Remove-NonVmk0AdaptersFromVdsHosts {

    <#
    .SYNOPSIS
        Removes non-vmk0 VMkernel adapters from all hosts on a VDS using three membership checks.
    .DESCRIPTION
        For each host and each non-vmk0 adapter, determines VDS membership via: (1) NetworkName string
        match, (2) Spec.PortGroup MoRef match, and (3) DistributedVirtualPort.PortgroupKey / SwitchUuid
        match. Removes matching adapters and returns the total count removed.
    .PARAMETER HostsOnVds
        Array of VMHost objects whose adapters should be checked.
    .PARAMETER PortGroupIdsOnVds
        HashSet of port group MoRef values for this VDS. May be empty when the VDS has no
        non-DVUplinks port groups; the SwitchUuid fallback still identifies VDS-backed adapters.
    .PARAMETER PortGroupNamesOnVds
        HashSet of port group display names for this VDS. May be empty when the VDS has no
        non-DVUplinks port groups.
    .PARAMETER Server
        vCenter server connection name.
    .PARAMETER VdsSwitchUuid
        VDS switch UUID used as the final membership check. May be $null.
    .EXAMPLE
        $removed = Remove-NonVmk0AdaptersFromVdsHosts -HostsOnVds $hosts -PortGroupIdsOnVds $pgIds -PortGroupNamesOnVds $pgNames -Server $Script:vCenterName -VdsSwitchUuid $uuid
    .NOTES
        Called by Remove-NonVmk0VmkernelInterfacesFromVds. NetworkName is empty for VDS-backed
        adapters in VCF PowerCLI 9, which is why three fallback checks are required.
    #>

    [CmdletBinding()]
    [OutputType([Int])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object[]]$HostsOnVds,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [ValidateNotNull()] [System.Collections.Generic.HashSet[string]]$PortGroupIdsOnVds,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [ValidateNotNull()] [System.Collections.Generic.HashSet[string]]$PortGroupNamesOnVds,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Server,
        [Parameter(Mandatory = $false)] [String]$VdsSwitchUuid
    )

    $totalRemoved = 0
    foreach ($esxHost in $HostsOnVds) {
        $hostNameForLog = $esxHost.Name
        $allVmkernelAdaptersOnHost = @(Get-VMHostNetworkAdapter -VMHost $esxHost -VMKernel -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue)
        foreach ($adapter in $allVmkernelAdaptersOnHost) {
            if ($adapter.Name -eq "vmk0") { continue }
            $adapterIsOnVds = $PortGroupNamesOnVds.Contains($adapter.NetworkName)
            if (-not $adapterIsOnVds -and $adapter.ExtensionData -and $adapter.ExtensionData.Spec -and $adapter.ExtensionData.Spec.PortGroup) {
                $pgRef = $adapter.ExtensionData.Spec.PortGroup
                $pgId  = if ($pgRef.Value) { $pgRef.Value } else { [String]$pgRef }
                if (-not [String]::IsNullOrWhiteSpace($pgId)) { $adapterIsOnVds = $PortGroupIdsOnVds.Contains($pgId) }
            }
            if (-not $adapterIsOnVds -and $adapter.ExtensionData -and $adapter.ExtensionData.Spec -and $adapter.ExtensionData.Spec.DistributedVirtualPort) {
                $dvp = $adapter.ExtensionData.Spec.DistributedVirtualPort
                $pgKey = $dvp.PortgroupKey
                if (-not [String]::IsNullOrWhiteSpace($pgKey)) { $adapterIsOnVds = $PortGroupIdsOnVds.Contains($pgKey) }
                if (-not $adapterIsOnVds -and -not [String]::IsNullOrWhiteSpace($VdsSwitchUuid) -and -not [String]::IsNullOrWhiteSpace($dvp.SwitchUuid)) {
                    $adapterIsOnVds = ($dvp.SwitchUuid -eq $VdsSwitchUuid)
                }
            }
            if (-not $adapterIsOnVds) { continue }
            try {
                Remove-VMHostNetworkAdapter -Nic $adapter -Confirm:$false -WarningAction SilentlyContinue -ErrorAction Stop
                $totalRemoved++
                $pgDisplayName = if (-not [String]::IsNullOrWhiteSpace($adapter.NetworkName)) {
                    $adapter.NetworkName
                } elseif ($adapter.ExtensionData -and $adapter.ExtensionData.Spec -and $adapter.ExtensionData.Spec.DistributedVirtualPort -and -not [String]::IsNullOrWhiteSpace($adapter.ExtensionData.Spec.DistributedVirtualPort.PortgroupKey)) {
                    "dvportgroup-key:$($adapter.ExtensionData.Spec.DistributedVirtualPort.PortgroupKey)"
                } else { "(unknown)" }
                Write-LogMessage -Type DEBUG -Message "Removed non-management VMkernel `"$($adapter.Name)`" (port group `"$pgDisplayName`") from host `"$hostNameForLog`" during cleanup."
            } catch {
                Write-LogMessage -Type WARNING -Message "Could not remove VMkernel `"$($adapter.Name)`" on host `"$hostNameForLog`": $($_.Exception.Message)."
            }
        }
    }
    return $totalRemoved
}
function Remove-NonVmk0VmkernelInterfacesFromVds {

    <#
        .SYNOPSIS
        Removes non-vmk0 VMkernel interfaces (e.g. vMotion, vSAN, vSAN Witness) from hosts on the given VDS. Used during cleanup so port groups are no longer in use before VDS removal.

        .DESCRIPTION
        For each specified VDS, finds hosts (from cluster or attached to the VDS), then removes every VMkernel adapter on that VDS except vmk0. No migration is required; these interfaces are deleted so a fully cleaned host has only management until provisioned again. Each VMkernel adapter is matched against the VDS using three checks in order: (1) NetworkName against port group name (works when PowerCLI resolves the VDS port group name), (2) Spec.PortGroup MoRef against port group IDs (standard-switch adapters), and (3) Spec.DistributedVirtualPort.PortgroupKey / SwitchUuid — the definitive check for VDS-backed adapters such as vSAN and vMotion VMkernel adapters where checks 1 and 2 return empty in VCF PowerCLI 9.

        .PARAMETER ClusterName
        Name of the cluster whose hosts to process. Used to get the host list when the cluster exists.

        .PARAMETER Server
        vCenter server name. Defaults to $Script:vCenterName.

        .PARAMETER VdsNames
        Array of VDS names to process (e.g. the cluster's main VDS and -sw1/-sw2 when 4-NIC). Non-vmk0 VMkernels on any of these switches are removed.

        .OUTPUTS
        None. Failures are logged as WARNING; removal continues for other hosts and VDSes.

        .NOTES
        Called during -CleanUp Compute/All before moving vmk0 to VSS and removing the VDS. Without this step, vmotion/vsan/vsanwitness port groups remain in use and VDS removal can fail.
    
        .EXAMPLE
        Remove-NonVmk0VmkernelInterfacesFromVds -ClusterName "edge-cluster-1" -VdsNames "resource-name"
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$Server = $Script:vCenterName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [String[]]$VdsNames
    )

    # Require vCenter connection; exit early if not connected.
    $connectionTest = Test-VcenterConnection
    if (-not $connectionTest.IsConnected) {
        Write-LogMessage -Type WARNING -Message "Remove-NonVmk0VmkernelInterfacesFromVds: not connected to vCenter `"$Server`"; skipping non-vmk0 VMkernel removal."
        return
    }

    # VCF PowerCLI 9 accesses .VirtualSwitch internally when any VmwareVDPortgroup object is passed to a
    # cmdlet parameter (parameter binding fires the warning before -WarningAction takes effect).
    # The loop below avoids -PortGroup entirely: it gets all VMkernels and matches by NetworkName (string)
    # then by MoRef ID — no VmwareVDPortgroup object is ever forwarded to a cmdlet.
    $clusterInVcenter = Get-ClusterByName -Name $ClusterName -Server $Server

    foreach ($currentVdsName in $VdsNames) {
        if ([String]::IsNullOrWhiteSpace($currentVdsName)) { continue }

        $distributedSwitch = Get-VDSwitch -Name $currentVdsName -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
        if (-not $distributedSwitch) {
            Write-LogMessage -Type DEBUG -Message "Remove-NonVmk0VmkernelInterfacesFromVds: VDS `"$currentVdsName`" not found; skipping."
            continue
        }

        # Resolve host list: prefer hosts in the cluster, otherwise hosts attached to this VDS.
        $hostsOnVds = @()
        if ($clusterInVcenter) {
            $hostsOnVds = @(Get-VMHost -Location $clusterInVcenter -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue)
        }
        if (-not $hostsOnVds -or $hostsOnVds.Count -eq 0) {
            $hostsOnVds = @(Get-VMHost -DistributedSwitch $distributedSwitch -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue)
        }
        if (-not $hostsOnVds -or $hostsOnVds.Count -eq 0) {
            Write-LogMessage -Type DEBUG -Message "Remove-NonVmk0VmkernelInterfacesFromVds: no hosts for VDS `"$currentVdsName`"; skipping."
            continue
        }

        # Build port group name and Id sets from this VDS, excluding system DVUplinks port groups.
        # Objects are NOT stored in a variable; names and Ids are extracted immediately in the pipeline
        # so no VmwareVDPortgroup object escapes to later code that could trigger the deprecation warning.
        $portGroupIdsOnVds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $portGroupNamesOnVds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        Get-VDPortgroup -VDSwitch $distributedSwitch -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notlike "*DVUplinks*" } |
            ForEach-Object {
                # Prefer MoRef.Value (e.g. "dvportgroup-124") as the canonical ID to match against
                # DistributedVirtualPort.PortgroupKey on the adapter side. Fall back to .Id only when
                # MoRef is absent (non-standard PowerCLI builds).
                $pgId = if ($_.ExtensionData -and $_.ExtensionData.MoRef -and $_.ExtensionData.MoRef.Value) { $_.ExtensionData.MoRef.Value } elseif ($_.Id) { $_.Id } else { $null }
                if ($pgId) { [Void]$portGroupIdsOnVds.Add($pgId) }
                if (-not [String]::IsNullOrWhiteSpace($_.Name)) { [Void]$portGroupNamesOnVds.Add($_.Name) }
            }

        # VDS SwitchUuid for the definitive VDS-membership check (see third fallback below).
        $vdsSwitchUuid = if ($distributedSwitch.ExtensionData -and $distributedSwitch.ExtensionData.Config) { $distributedSwitch.ExtensionData.Config.Uuid } else { $null }

        Write-LogMessage -Type INFO -NoNewline -Message "Removing non-management VMkernel interfaces from hosts on VDS `"$currentVdsName`"... "
        $totalRemoved = Remove-NonVmk0AdaptersFromVdsHosts `
            -HostsOnVds $hostsOnVds `
            -PortGroupIdsOnVds $portGroupIdsOnVds `
            -PortGroupNamesOnVds $portGroupNamesOnVds `
            -Server $Server `
            -VdsSwitchUuid $vdsSwitchUuid
        Write-LogMessage -Type INFO -CompletePending -Message "Removed $totalRemoved interface(s) from $($hostsOnVds.Count) host(s)."
    }
}
function Invoke-ManagementRestoreForCleanup {

    <#
        .SYNOPSIS
        Thin wrapper around Restore-ManagementToVssBeforeVdsRemoval used as a named mock boundary in tests.

        .DESCRIPTION
        Delegates directly to Restore-ManagementToVssBeforeVdsRemoval. The wrapper exists so that
        Invoke-ManagementRestoreForCleanupWithTopologyFallback can be unit-tested by stubbing this
        function, rather than the deeper Restore-ManagementToVssBeforeVdsRemoval which has complex
        VDS and network logic.

        .PARAMETER ClusterName
        Name of the cluster (for logging and restore).

        .PARAMETER VdsNameWithMgmt
        Name of the VDS that may have the management port group.

        .OUTPUTS
        PSCustomObject from Restore-ManagementToVssBeforeVdsRemoval (RestoreAttempted, Success, HostsRestoredCount, Message).

        .EXAMPLE
        Invoke-ManagementRestoreForCleanup -ClusterName "edge-cluster-1" -VdsNameWithMgmt "resource-name"
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VdsNameWithMgmt
    )
    return Restore-ManagementToVssBeforeVdsRemoval -ClusterName $ClusterName -VdsNameWithMgmt $VdsNameWithMgmt
}
function Invoke-ManagementRestoreForCleanupWithTopologyFallback {

    <#
        .SYNOPSIS
        Runs management restore for cleanup or rollback, trying alternate VDS names when JSON nicList may not match deployed topology.

        .DESCRIPTION
        Cleanup derives the management VDS from the current infrastructure JSON (two NICs = base VdsName, four NICs = VdsName-sw1).
        If nicList was edited between deployment and cleanup in either direction (two vs four NICs), vmk0 can remain on the VDS from the deployed topology while JSON implies the other (e.g. JSON now has four NICs but hosts still use base VdsName for management, or JSON now has two NICs but management stayed on VdsName-sw1). Candidates are ordered by current JSON (four NICs: try VdsName-sw1 then base; two NICs: try base then VdsName-sw1). This function calls Invoke-ManagementRestoreForCleanup for each existing VDS in that order until at least one host is moved to the standard switch or all candidates are exhausted.

        .PARAMETER ClusterName
        Cluster whose hosts are restored.

        .PARAMETER NicListCount
        Effective NIC count from JSON (2 or 4). Order of candidates: 4 → try sw1 then base; 2 → try base then sw1.

        .PARAMETER Server
        vCenter server (default Script:vCenterName).

        .PARAMETER VdsName
        Base VDS name (no -sw1/-sw2 suffix).

        .OUTPUTS
        PSCustomObject from the last Invoke-ManagementRestoreForCleanup attempt (or a default object if no VDS existed).
    
        .EXAMPLE
        Invoke-ManagementRestoreForCleanupWithTopologyFallback -ClusterName "edge-cluster-1" -VdsName "resource-name"
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [ValidateSet(2, 4)] [Int]$NicListCount = 2,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$Server = $Script:vCenterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VdsName
    )

    if ($NicListCount -eq 4) {
        $orderedNames = @("$VdsName-sw1", $VdsName)
    } else {
        $orderedNames = @($VdsName, "$VdsName-sw1")
    }

    $seenKeys = @{}
    $candidates = [System.Collections.Generic.List[String]]::new()
    foreach ($candidateName in $orderedNames) {
        if ([String]::IsNullOrWhiteSpace($candidateName)) {
            continue
        }

        $key = $candidateName.ToLowerInvariant()
        if ($seenKeys.ContainsKey($key)) {
            continue
        }

        $seenKeys[$key] = $true
        [Void]$candidates.Add($candidateName)
    }

    $lastResult = [PSCustomObject]@{
        RestoreAttempted = $false
        Success = $true
        HostsRestoredCount = 0
        Message = "No VDS candidates (base or sw1) were found for topology fallback."
    }

    foreach ($cand in $candidates) {
        $sw = Get-VDSwitch -Name $cand -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
        if (-not $sw) {
            Write-LogMessage -Type DEBUG -Message "Topology fallback: VDS `"$cand`" not found; trying next candidate."
            continue
        }

        Write-LogMessage -Type INFO -Message "Management restore: trying VDS `"$cand`" (JSON nic count $NicListCount; alternate tried if deployment used the other topology)."
        try {
            $lastResult = Invoke-ManagementRestoreForCleanup -ClusterName $ClusterName -VdsNameWithMgmt $cand
        } catch {
            Write-LogMessage -Type WARNING -Message "Management restore threw for candidate `"$cand`": $($_.Exception.Message)"
            $lastResult = [PSCustomObject]@{
                RestoreAttempted = $true
                Success = $false
                HostsRestoredCount = 0
                Message = $_.Exception.Message
            }
        }

        if ($lastResult.HostsRestoredCount -gt 0) {
            break
        }
    }

    return $lastResult
}
function Get-VdsByName {

    <#
        .SYNOPSIS
        Returns a VDS by name. Thin wrapper over Get-VDSwitch enabling unit tests to mock this call without fighting PowerCLI type constraints on the -Server parameter.

        .PARAMETER Name
        Name of the VDS to retrieve.

        .PARAMETER Server
        vCenter server name or connection object.

        .EXAMPLE
        Get-VdsByName -Name "VDS-site1" -Server "vc.lab"
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Name,
        [Parameter(Mandatory = $false)] [String]$Server = $Script:vCenterName
    )

    Get-VDSwitch -Name $Name -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
}
function Test-VmkAdapterOnVds {

    <#
        .SYNOPSIS
        Determines whether vmk0 on a host is currently attached to a specific VDS.

        .DESCRIPTION
        Runs up to five detection passes in order of reliability:
        (1) Get-VDPortgroup -Id on vmk0's port group reference;
        (2) DPG Id and Name matching against all port groups on the VDS;
        (3) Get-VMHostNetworkAdapter -PortGroup per DPG iteration;
        (4) MoRef comparison between vmk0's port group reference and each DPG on the VDS;
        (5) Last resort — if the VDS has a management-named (mgmt-*) port group, assume vmk0 is on it.
        Returns $true as soon as any pass confirms the binding; returns $false when all passes fail and
        neither the per-host check nor the VdsHasMgmtPortGroup flag applies.

        .PARAMETER Server
        vCenter server name.

        .PARAMETER VdsHasMgmtPortGroup
        Pre-computed flag: true when the VDS has at least one port group whose name matches mgmt-* (computed once before the host loop in Restore-ManagementToVssBeforeVdsRemoval to avoid repeated VDS queries).

        .PARAMETER VdsName
        Name of the VDS to test against.

        .PARAMETER VdsObject
        VDS object (output of Get-VDSwitch).

        .PARAMETER VMHost
        The ESX host object to test.

        .PARAMETER Vmk0Adapter
        The vmk0 VMkernel adapter object from Get-VmkernelAdaptersOnHost.

        .OUTPUTS
        [Bool] $true when vmk0 is confirmed or assumed to be on the VDS; $false otherwise.

        .EXAMPLE
        $isOnVds = Test-VmkAdapterOnVds -Server $Server -VdsHasMgmtPortGroup:$vdsHasMgmtPortGroup -VdsName $VdsNameWithMgmt -VdsObject $vdsObject -VMHost $vmhost -Vmk0Adapter $vmk0
        if ($isOnVds) { Write-LogMessage -Type INFO -Message "vmk0 is on the VDS; restore will proceed." }
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Server,
        [Parameter(Mandatory = $false)] [Switch]$VdsHasMgmtPortGroup,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VdsName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$VdsObject,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$VMHost,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$Vmk0Adapter
    )

    $hostName = $VMHost.Name
    $vmk0OnThisVds = $false
    $dpg = $null
    try {
        $pgId = $Vmk0Adapter.ExtensionData.Spec.PortGroup
        if ($pgId) {
            $pgIdValue = if ($pgId.Value) { $pgId.Value } else { $pgId }
            $dpg = Get-VDPortgroup -Id $pgIdValue -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
            # Avoid accessing $dpg.VDSwitch.Name — PowerCLI accesses .VirtualSwitch internally on
            # VmwareVDPortgroup and emits a deprecation warning before -WarningAction takes effect.
            # Instead confirm VDS membership by checking whether the DPG's own VDSwitch Id matches
            # via ExtensionData, falling back to name comparison which does not touch .VirtualSwitch.
            if ($dpg) {
                $dpgSwitchName = $null
                if ($dpg.ExtensionData -and $dpg.ExtensionData.Config -and $dpg.ExtensionData.Config.DistributedVirtualSwitch -and $dpg.ExtensionData.Config.DistributedVirtualSwitch.Value) {
                    $dpgSwitchMoRef = $dpg.ExtensionData.Config.DistributedVirtualSwitch.Value
                    $vdsSwitchMoRef = if ($VdsObject.ExtensionData -and $VdsObject.ExtensionData.MoRef) { $VdsObject.ExtensionData.MoRef.Value } else { $null }
                    if ($dpgSwitchMoRef -and $vdsSwitchMoRef -and $dpgSwitchMoRef -eq $vdsSwitchMoRef) {
                        $vmk0OnThisVds = $true
                    }
                }
                # Fallback: match by DPG name against this VDS's port groups (avoids .VirtualSwitch entirely).
                if (-not $vmk0OnThisVds -and $dpg.Name) {
                    $vdsPgNames = @(Get-VDPortgroup -VDSwitch $VdsObject -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike "*DVUplinks*" } | Select-Object -ExpandProperty Name)
                    if ($vdsPgNames -contains $dpg.Name) {
                        $vmk0OnThisVds = $true
                    }
                }
            }
        }
    } catch {
        Write-LogMessage -Type DEBUG -Message "Could not determine vmk0 port group (vmk0 may be on standard switch): $($_.Exception.Message)."
    }
    if ($dpg -and -not $vmk0OnThisVds) {
        $vdsPgList = @(Get-VDPortgroup -VDSwitch $VdsObject -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike "*DVUplinks*" })
        foreach ($vdsPg in $vdsPgList) {
            if ($vdsPg.Id -and $dpg.Id -and $vdsPg.Id -eq $dpg.Id) {
                $vmk0OnThisVds = $true
                Write-LogMessage -Type DEBUG -Message "Host `"$hostName`" vmk0 found on VDS `"$VdsName`" via DPG Id match (VDSwitch property unavailable or did not match)."
                break
            }
            if ($vdsPg.Name -and $dpg.Name -and $vdsPg.Name -eq $dpg.Name) {
                $vmk0OnThisVds = $true
                Write-LogMessage -Type DEBUG -Message "Host `"$hostName`" vmk0 found on VDS `"$VdsName`" via DPG name match (VDSwitch property unavailable or did not match)."
                break
            }
        }
    }
    if (-not $vmk0OnThisVds -and $pgId) {
        # Get-VDPortgroup -Id may have returned null (e.g. Id format not accepted). Match vmk0's port group MoRef against each DPG on the VDS by Id/MoRef in multiple forms.
        $pgId = $Vmk0Adapter.ExtensionData.Spec.PortGroup
        $pgIdValueForMatch = if ($pgId.Value) { $pgId.Value.ToString().Trim() } else { $pgId.ToString().Trim() }
        $vdsPgListForMatch = @(Get-VDPortgroup -VDSwitch $VdsObject -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike "*DVUplinks*" })
        foreach ($vdsPg in $vdsPgListForMatch) {
            $vdsPgId = if ($vdsPg.Id) { $vdsPg.Id.ToString().Trim() } else { "" }
            $vdsPgMoRef = if ($vdsPg.ExtensionData -and $vdsPg.ExtensionData.MoRef -and $vdsPg.ExtensionData.MoRef.Value) { $vdsPg.ExtensionData.MoRef.Value.ToString().Trim() } else { "" }
            $match = $false
            if ($pgIdValueForMatch -and $vdsPgId -and $pgIdValueForMatch -eq $vdsPgId) { $match = $true }
            if (-not $match -and $pgIdValueForMatch -and $vdsPgMoRef -and $pgIdValueForMatch -eq $vdsPgMoRef) { $match = $true }
            if ($match) {
                $vmk0OnThisVds = $true
                Write-LogMessage -Type DEBUG -Message "Host `"$hostName`" vmk0 found on VDS `"$VdsName`" via MoRef/Id match when Get-VDPortgroup -Id returned null (vmk0 pg ref: $pgIdValueForMatch)."
                break
            }
        }
    }
    if (-not $vmk0OnThisVds) {
        # Get-VMHostNetworkAdapter -PortGroup <string> triggers an internal .VirtualSwitch property
        # access on VmwareVDPortgroup that emits the deprecation warning before -WarningAction takes
        # effect; using PortGroupName on the already-retrieved adapter avoids this entirely.
        $vdPgNames = @(Get-VDPortgroup -VDSwitch $VdsObject -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notlike "*DVUplinks*" } | Select-Object -ExpandProperty Name)
        if ($Vmk0Adapter.PortGroupName -and $vdPgNames -contains $Vmk0Adapter.PortGroupName) {
            $vmk0OnThisVds = $true
            Write-LogMessage -Type DEBUG -Message "Host `"$hostName`" vmk0 found on VDS `"$VdsName`" via port group name match (DPG `"$($Vmk0Adapter.PortGroupName)`" present on VDS)."
        }
    }
    if (-not $vmk0OnThisVds -and $Vmk0Adapter.ExtensionData.Spec.PortGroup) {
        # Fallback: compare vmk0 port group MoRef to DPG MoRefs on this VDS (Get-VMHostNetworkAdapter -PortGroup may not return vmk0 on some PowerCLI/vCenter versions).
        $vmk0PgRef = $Vmk0Adapter.ExtensionData.Spec.PortGroup
        $vmk0PgRefStr = if ($vmk0PgRef.Value) { $vmk0PgRef.Value.ToString().Trim() } else { $vmk0PgRef.ToString().Trim() }
        if (-not [String]::IsNullOrWhiteSpace($vmk0PgRefStr)) {
            $vdPgsForRef = Get-VDPortgroup -VDSwitch $VdsObject -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
            foreach ($vdPgRef in @($vdPgsForRef)) {
                $dpgRef = $vdPgRef.ExtensionData.MoRef
                $dpgRefStr = if ($dpgRef.Value) { $dpgRef.Value.ToString().Trim() } elseif ($vdPgRef.Id) { $vdPgRef.Id.ToString().Trim() } else { "" }
                if ($dpgRefStr -and $vmk0PgRefStr -eq $dpgRefStr) {
                    $vmk0OnThisVds = $true
                    Write-LogMessage -Type DEBUG -Message "Host `"$hostName`" vmk0 found on VDS `"$VdsName`" via MoRef match (port group ref: $vmk0PgRefStr)."
                    break
                }
            }
        }
    }
    if (-not $vmk0OnThisVds) {
        # Last resort: this VDS may be the management VDS from our deployment with an mgmt-* port group (e.g. mgmt-VMFS). If so, vmk0 may be on it; attempt restore so cleanup can remove the port group.
        $expectedMgmtPgName = "mgmt-$($VdsName -replace '^VDS-', '')"
        $mgmtPgByName = Get-VDPortgroup -Name $expectedMgmtPgName -VDSwitch $VdsObject -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
        if (-not $mgmtPgByName) {
            $mgmtPgByName = Get-VDPortgroup -Name $expectedMgmtPgName -VDSwitch $VdsObject -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
        }
        if ($mgmtPgByName) {
            $vmk0OnThisVds = $true
            Write-LogMessage -Type DEBUG -Message "Host `"$hostName`" vmk0 assumed on VDS `"$VdsName`" (management port group `"$expectedMgmtPgName`" found by name; all other detection failed). Attempting restore."
        }
        if (-not $vmk0OnThisVds) {
            $userPgsOnVds = @(Get-VDPortgroup -VDSwitch $VdsObject -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike "*DVUplinks*" })
            $hasMgmtPg = @($userPgsOnVds | Where-Object { $_.Name -eq $expectedMgmtPgName -or $_.Name -like "mgmt-*" }).Count -gt 0
            if ($hasMgmtPg) {
                $vmk0OnThisVds = $true
                $mgmtPgNames = @($userPgsOnVds | Where-Object { $_.Name -eq $expectedMgmtPgName -or $_.Name -like "mgmt-*" } | Select-Object -ExpandProperty Name)
                Write-LogMessage -Type DEBUG -Message "Host `"$hostName`" vmk0 assumed on VDS `"$VdsName`" (management port group(s) present: $($mgmtPgNames -join ', '); all other detection failed). Attempting restore."
            }
        }
    }
    if (-not $vmk0OnThisVds -and $VdsHasMgmtPortGroup) {
        # VDS has mgmt-* port group but per-host detection did not find vmk0 on it (e.g. Get-VMHostNetworkAdapter -PortGroup or MoRef match failed). Assume vmk0 is on this VDS and attempt restore so we do not leave the port group in use.
        $vmk0OnThisVds = $true
        Write-LogMessage -Type DEBUG -Message "Host `"$hostName`" vmk0 assumed on VDS `"$VdsName`" (VDS has management port group; per-host detection missed). Attempting restore."
    }
    return $vmk0OnThisVds
}
function Get-Vmk0ManagementVlanId {

    <#
        .SYNOPSIS
        Resolves the VLAN ID of the management distributed port group that vmk0 is connected to.

        .DESCRIPTION
        Attempts to identify the VDPortgroup that vmk0 is on (via MoRef, or by scanning all
        non-uplink VDS port groups for a vmk0 match). Tries VLanID, VlanId, ExtensionData.Config,
        and ExtensionData.Spec property paths in sequence. Returns 0 when no tagged VLAN is found.

        .PARAMETER HostName
        Display name of the host (for log messages).

        .PARAMETER Server
        vCenter server name.

        .PARAMETER VdsObject
        The VDS object to scan port groups on when direct MoRef lookup fails.

        .PARAMETER VMHost
        The host whose vmk0 VLAN is being queried.

        .PARAMETER Vmk0
        The vmk0 VMkernel adapter object.

        .EXAMPLE
        $vlanId = Get-Vmk0ManagementVlanId -HostName "esx01.lab" -VdsObject $vds -VMHost $esxHost -Vmk0 $vmk0Adapter
    #>

    [CmdletBinding()]
    [OutputType([Int])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$HostName,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$Server = $Script:vCenterName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$VdsObject,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$VMHost,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$Vmk0
    )

    $vmk0Dpg = $null
    if ($Vmk0.ExtensionData.Spec.PortGroup) {
        $pgRef = $Vmk0.ExtensionData.Spec.PortGroup
        $pgRefValue = if ($pgRef.Value) { $pgRef.Value } else { $pgRef }
        $vmk0Dpg = Get-VDPortgroup -Id $pgRefValue -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
    }
    if (-not $vmk0Dpg) {
        $vdPgs = @(Get-VDPortgroup -VDSwitch $VdsObject -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike "*DVUplinks*" })
        # PortGroupName avoids Get-VMHostNetworkAdapter -PortGroup which internally accesses
        # .VirtualSwitch on VmwareVDPortgroup and emits the deprecation warning regardless of -WarningAction.
        $vmk0PgName = $Vmk0.PortGroupName
        if (-not [String]::IsNullOrWhiteSpace($vmk0PgName)) {
            $vmk0Dpg = $vdPgs | Where-Object { $_.Name -eq $vmk0PgName } | Select-Object -First 1
        }
    }
    $mgmtVlanId = 0
    if ($vmk0Dpg) {
        if ($vmk0Dpg.PSObject.Properties['VLanID'] -and $null -ne $vmk0Dpg.VLanID) {
            $mgmtVlanId = [Int]$vmk0Dpg.VLanID
        } elseif ($vmk0Dpg.PSObject.Properties['VlanId'] -and $null -ne $vmk0Dpg.VlanId) {
            $mgmtVlanId = [Int]$vmk0Dpg.VlanId
        } elseif ($vmk0Dpg.ExtensionData -and $vmk0Dpg.ExtensionData.Config -and $vmk0Dpg.ExtensionData.Config.DefaultPortConfig -and $vmk0Dpg.ExtensionData.Config.DefaultPortConfig.Vlan -and $vmk0Dpg.ExtensionData.Config.DefaultPortConfig.Vlan.PSObject.Properties['VlanId']) {
            $mgmtVlanId = [Int]$vmk0Dpg.ExtensionData.Config.DefaultPortConfig.Vlan.VlanId
        } elseif ($vmk0Dpg.ExtensionData -and $vmk0Dpg.ExtensionData.Spec -and $vmk0Dpg.ExtensionData.Spec.PSObject.Properties['VlanId'] -and $null -ne $vmk0Dpg.ExtensionData.Spec.VlanId) {
            $mgmtVlanId = [Int]$vmk0Dpg.ExtensionData.Spec.VlanId
        }
    }
    if ($mgmtVlanId -gt 0) {
        Write-LogMessage -Type DEBUG -Message "Host `"$HostName`" vmk0 is on a tagged VLAN ($mgmtVlanId); VSS restore port group will use VLanId $mgmtVlanId."
    } elseif ($vmk0Dpg -and $mgmtVlanId -eq 0) {
        Write-LogMessage -Type WARNING -Message "Host `"$HostName`": could not read VLAN from management DPG `"$($vmk0Dpg.Name)`"; VSS restore port group will use VLanId 0 (untagged). If management is on a tagged VLAN, connectivity may be lost."
    }
    return $mgmtVlanId
}
function New-VimHostVirtualNicSpec {

    <#
        .SYNOPSIS
        Creates a new VMware.Vim.HostVirtualNicSpec instance.

        .DESCRIPTION
        Wrapper around New-Object VMware.Vim.HostVirtualNicSpec so that tests can mock
        it without requiring the VMware assembly to be loaded.

        .EXAMPLE
        $nicSpec = New-VimHostVirtualNicSpec
        $nicSpec.portgroup = "Management"
    #>

    [CmdletBinding()]
    [OutputType([Object])]
    Param ()

    return New-Object VMware.Vim.HostVirtualNicSpec
}
function Invoke-RestoreVmk0ToExistingRestoreVss {

    <#
        .SYNOPSIS
        Attempts to move vmk0 to an already-complete vSwitch0-restore VSS (pNIC present and Management port group present).

        .DESCRIPTION
        If vSwitch0-restore already exists with at least one physical uplink and a Management port
        group, moves vmk0 there via HostNetworkSystem.UpdateVirtualNic. Returns $true on success,
        $false when the switch does not exist, is incomplete, or the move fails (allowing the caller
        to try the next strategy).

        .PARAMETER HostName
        Display name of the host (for log messages).

        .PARAMETER Server
        vCenter server name.

        .PARAMETER VMHost
        The host whose vmk0 is being restored.

        .PARAMETER Vmk0
        The vmk0 VMkernel adapter object.

        .PARAMETER VssNameRestore
        Name of the designated restore VSS (e.g. "vSwitch0-restore").

        .EXAMPLE
        if (Invoke-RestoreVmk0ToExistingRestoreVss -HostName "esx01" -VMHost $h -Vmk0 $vmk0 -VssNameRestore "vSwitch0-restore") { ... }
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$HostName,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$Server = $Script:vCenterName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$VMHost,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$Vmk0,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VssNameRestore
    )

    $existingRestoreVss = Get-VirtualSwitchesOnHost -VMHost $VMHost -Server $Server | Where-Object { $_.Name -eq $VssNameRestore }
    if (-not $existingRestoreVss) { return $false }
    $pnicsOnVss = @(Get-VMHostNetworkAdapter -VMHost $VMHost -Physical -VirtualSwitch $existingRestoreVss -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue)
    $stdPgManagement = Get-VirtualPortGroupsOnSwitch -VirtualSwitch $existingRestoreVss -Server $Server | Where-Object { $_.Name -eq "Management" } | Select-Object -First 1
    if (-not $pnicsOnVss -or $pnicsOnVss.Count -eq 0 -or -not $stdPgManagement) { return $false }
    try {
        $hostView = Get-View -Id $VMHost.Id -Server $Server -Property ConfigManager -ErrorAction Stop
        $netSys = Get-View -Id $hostView.ConfigManager.NetworkSystem -Server $Server -ErrorAction Stop
        $nicSpec = New-VimHostVirtualNicSpec
        $nicSpec.portgroup = $stdPgManagement.Name
        $netSys.UpdateVirtualNic($Vmk0.Name, $nicSpec)
        Write-LogMessage -Type INFO -Message "Host `"$HostName`": moved vmk0 to existing `"$VssNameRestore`"/Management."
        return $true
    } catch {
        Write-LogMessage -Type DEBUG -Message "Could not move vmk0 to existing `"$VssNameRestore`" on host `"$HostName`": $($_.Exception.Message). Will create or complete vSwitch then retry."
        return $false
    }
}
function Invoke-RestoreVmk0ToFallbackVss {

    <#
        .SYNOPSIS
        Attempts to move vmk0 to any existing standard switch (other than the restore VSS) that has a pNIC and a Management-like port group.

        .DESCRIPTION
        Used when vSwitch0-restore cannot be created immediately (no unused pNICs and vSphere
        blocks pNIC removal). Tries all standard switches except vSwitch0-restore; skips switches
        with no physical uplinks. Returns $true as soon as vmk0 is moved to any matching port group.

        .PARAMETER HostName
        Display name of the host (for log messages).

        .PARAMETER Server
        vCenter server name.

        .PARAMETER VMHost
        The host whose vmk0 is being restored.

        .PARAMETER Vmk0
        The vmk0 VMkernel adapter object.

        .PARAMETER VssNameRestore
        Name of the designated restore VSS to exclude from the fallback scan (e.g. "vSwitch0-restore").

        .EXAMPLE
        if (Invoke-RestoreVmk0ToFallbackVss -HostName "esx01" -VMHost $h -Vmk0 $vmk0 -VssNameRestore "vSwitch0-restore") { ... }
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$HostName,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$Server = $Script:vCenterName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$VMHost,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$Vmk0,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VssNameRestore
    )

    $existingVssList = @(Get-VirtualSwitchesOnHost -VMHost $VMHost -Server $Server | Where-Object { $_.Name -ne $VssNameRestore })
    foreach ($vss in $existingVssList) {
        $pnicsOnVss = @(Get-VMHostNetworkAdapter -VMHost $VMHost -Physical -VirtualSwitch $vss -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue)
        if (-not $pnicsOnVss -or $pnicsOnVss.Count -eq 0) { continue }
        $stdPgs = @(Get-VirtualPortGroupsOnSwitch -VirtualSwitch $vss -Server $Server)
        foreach ($stdPg in $stdPgs) {
            $targetPgName = $stdPg.Name
            if ($targetPgName -notmatch "Management|VM Network|mgmt") { continue }
            try {
                $hostView = Get-View -Id $VMHost.Id -Server $Server -Property ConfigManager -ErrorAction Stop
                $netSys = Get-View -Id $hostView.ConfigManager.NetworkSystem -Server $Server -ErrorAction Stop
                $nicSpec = New-VimHostVirtualNicSpec
                $nicSpec.portgroup = $targetPgName
                $netSys.UpdateVirtualNic($Vmk0.Name, $nicSpec)
                Write-LogMessage -Type INFO -Message "Host `"$HostName`": moved vmk0 to existing standard switch `"$($vss.Name)`"/`"$targetPgName`" (fallback when vSwitch0-restore cannot be created)."
                return $true
            } catch {
                Write-LogMessage -Type DEBUG -Message "Could not move vmk0 to `"$($vss.Name)`"/`"$targetPgName`" on host `"$HostName`": $($_.Exception.Message). Trying next."
            }
        }
    }
    return $false
}
function Invoke-RestoreVmk0UsingUnusedPnic {

    <#
        .SYNOPSIS
        Uses an unused pNIC (one not currently assigned to the VDS) to build vSwitch0-restore and move vmk0.

        .DESCRIPTION
        Finds any pNIC not present on the specified VDS, creates or completes vSwitch0-restore with
        that pNIC, creates the Management port group with the supplied VLAN ID, and moves vmk0 there.
        This path avoids removing a pNIC from the VDS and also recovers from a partial previous attempt
        (pNIC removed but vSwitch not yet created). Returns $true on success, $false when no unused pNIC
        is available or the operation fails.

        .PARAMETER HostName
        Display name of the host (for log messages).

        .PARAMETER MgmtVlanId
        VLAN ID to use when creating the Management port group on vSwitch0-restore.

        .PARAMETER Server
        vCenter server name.

        .PARAMETER VdsObject
        The VDS object used to detect which pNICs are already assigned.

        .PARAMETER VMHost
        The host whose vmk0 is being restored.

        .PARAMETER Vmk0
        The vmk0 VMkernel adapter object.

        .EXAMPLE
        if (Invoke-RestoreVmk0UsingUnusedPnic -HostName "esx01" -MgmtVlanId 0 -VdsObject $vds -VMHost $h -Vmk0 $vmk0) { ... }
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$HostName,
        [Parameter(Mandatory = $true)] [ValidateRange(0, 4094)] [Int]$MgmtVlanId,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$Server = $Script:vCenterName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$VdsObject,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$VMHost,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$Vmk0
    )

    $allPnics = @(Get-VMHostNetworkAdapter -VMHost $VMHost -Physical -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue)
    $pnicsOnVds = @(Get-VMHostNetworkAdapter -VMHost $VMHost -Physical -VirtualSwitch $VdsObject -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue)
    $pnicNamesOnVds = @($pnicsOnVds | Select-Object -ExpandProperty Name)
    $unusedPnics = @($allPnics | Where-Object { $_.Name -notin $pnicNamesOnVds })
    if (-not $unusedPnics -or $unusedPnics.Count -eq 0) { return $false }
    $unusedPnicName = ($unusedPnics | Select-Object -ExpandProperty Name | Sort-Object)[0]
    $unusedPnic = Get-VMHostNetworkAdapter -VMHost $VMHost -Physical -Name $unusedPnicName -Server $Server -ErrorAction SilentlyContinue
    if (-not $unusedPnic) { return $false }
    Write-LogMessage -Type INFO -Message "Host `"$HostName`": using pNIC `"$unusedPnicName`" (not on VDS) for vSwitch0-restore; no VDS change required (also recovers retry after partial failure)."
    $vssName = "vSwitch0-restore"
    try {
        $existingVss = Get-VirtualSwitchesOnHost -VMHost $VMHost -Server $Server | Where-Object { $_.Name -eq $vssName }
        if (-not $existingVss) {
            New-VirtualSwitch -VMHost $VMHost -Name $vssName -Nic $unusedPnicName -Server $Server -ErrorAction Stop | Out-Null
            Write-LogMessage -Type DEBUG -Message "Created standard switch `"$vssName`" with unused pNIC `"$unusedPnicName`" on host `"$HostName`"."
        } else {
            $pnicsOnExisting = @(Get-VMHostNetworkAdapter -VMHost $VMHost -Physical -VirtualSwitch $existingVss -Server $Server -ErrorAction SilentlyContinue)
            if (-not ($pnicsOnExisting | Where-Object { $_.Name -eq $unusedPnicName })) {
                Add-VirtualSwitchPhysicalNetworkAdapter -VirtualSwitch $existingVss -VMHostPhysicalNic $unusedPnic -Server $Server -Confirm:$false -ErrorAction Stop
                Write-LogMessage -Type DEBUG -Message "Attached pNIC `"$unusedPnicName`" to existing `"$vssName`" on host `"$HostName`" (retry after partial failure)."
            }
        }
        $vss = Get-VirtualSwitch -VMHost $VMHost -Standard -Name $vssName -Server $Server -ErrorAction Stop
        $mgmtPgName = "Management"
        $stdPg = Get-VirtualPortGroupsOnSwitch -VirtualSwitch $vss -Server $Server | Where-Object { $_.Name -eq $mgmtPgName } | Select-Object -First 1
        if (-not $stdPg) {
            New-VirtualPortGroup -VirtualSwitch $vss -Name $mgmtPgName -VLanId $MgmtVlanId -Server $Server -ErrorAction Stop | Out-Null
            $stdPg = Get-VirtualPortGroup -VirtualSwitch $vss -Name $mgmtPgName -Server $Server -ErrorAction Stop
        }
        $hostView = Get-View -Id $VMHost.Id -Server $Server -Property ConfigManager -ErrorAction Stop
        $netSys = Get-View -Id $hostView.ConfigManager.NetworkSystem -Server $Server -ErrorAction Stop
        $nicSpec = New-VimHostVirtualNicSpec
        $nicSpec.portgroup = $mgmtPgName
        $netSys.UpdateVirtualNic($Vmk0.Name, $nicSpec)
        Write-LogMessage -Type DEBUG -Message "Moved vmk0 to `"$vssName`"/`"$mgmtPgName`" (VLAN $MgmtVlanId) using unused pNIC `"$unusedPnicName`" on host `"$HostName`"."
        return $true
    } catch {
        Write-LogMessage -Type DEBUG -Message "Could not use unused pNIC `"$unusedPnicName`" for restore on host `"$HostName`": $($_.Exception.Message). Falling back to pNIC removal from VDS."
        return $false
    }
}
function Invoke-SelectAndRemoveVdsPnic {

    <#
        .SYNOPSIS
        Selects and removes one pNIC from the VDS to free it for building vSwitch0-restore.

        .DESCRIPTION
        Tries pNICs in highest-numbered-first order (e.g. vmnic1 before vmnic0) so the lowest-numbered
        NIC remains on the VDS until it is removed. Returns a result object whose PnicName is $null
        when no pNIC can be removed (vSphere rollback). NoPnicsOnVds is $true when the host has no
        pNICs on the specified VDS at all.

        .PARAMETER HostName
        Display name of the host (for log messages).

        .PARAMETER Server
        vCenter server name.

        .PARAMETER VdsObject
        The VDS object from which to remove a pNIC.

        .PARAMETER VMHost
        The host from which to remove the pNIC.

        .EXAMPLE
        $pnicResult = Invoke-SelectAndRemoveVdsPnic -HostName "esx01" -VdsObject $vds -VMHost $h
        if ($pnicResult.NoPnicsOnVds) { ... } elseif (-not $pnicResult.PnicName) { ... rollback ... }
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$HostName,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$Server = $Script:vCenterName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$VdsObject,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$VMHost
    )

    $pnicsOnVds = @(Get-VMHostNetworkAdapter -VMHost $VMHost -Physical -VirtualSwitch $VdsObject -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue)
    if (-not $pnicsOnVds -or $pnicsOnVds.Count -eq 0) {
        return [PSCustomObject]@{ PnicName = $null; PnicObject = $null; NoPnicsOnVds = $true }
    }
    $pnicNamesSorted = @($pnicsOnVds | Select-Object -ExpandProperty Name | Sort-Object)
    $orderToTry = if ($pnicNamesSorted.Count -ge 2) { @($pnicNamesSorted[-1], $pnicNamesSorted[0]) } else { @($pnicNamesSorted[0]) }
    Write-LogMessage -Type INFO -Message "Host `"$HostName`": removing a pNIC from VDS (trying: $($orderToTry -join ', ')); only after removal will we create vSwitch0-restore and Management port group, then move vmk0."
    foreach ($chosenNicName in $orderToTry) {
        $pnicObj = Get-VMHostNetworkAdapter -VMHost $VMHost -Physical -Name $chosenNicName -Server $Server -ErrorAction SilentlyContinue
        if (-not $pnicObj) { continue }
        try {
            $pnicObj | Remove-VDSwitchPhysicalNetworkAdapter -Confirm:$false -WarningAction SilentlyContinue -ErrorAction Stop
            Write-LogMessage -Type DEBUG -Message "Host `"$HostName`": removed pNIC `"$chosenNicName`" from VDS; creating vSwitch0-restore and moving vmk0."
            return [PSCustomObject]@{ PnicName = $chosenNicName; PnicObject = $pnicObj; NoPnicsOnVds = $false }
        } catch {
            Write-LogMessage -Type WARNING -Message "Host `"$HostName`": could not remove pNIC `"$chosenNicName`" from VDS (vSphere may have rolled back): $($_.Exception.Message). Trying next pNIC."
        }
    }
    return [PSCustomObject]@{ PnicName = $null; PnicObject = $null; NoPnicsOnVds = $false }
}
function Invoke-BuildRestoreVssAndMoveVmk0 {

    <#
        .SYNOPSIS
        Creates or completes vSwitch0-restore with the specified pNIC, creates the Management port group, and moves vmk0.

        .DESCRIPTION
        Used after a pNIC has been freed from the VDS. Creates vSwitch0-restore (or ensures the pNIC
        is attached if it already exists), creates a Management port group with the supplied VLAN ID,
        then migrates vmk0. Tries Set-VMHostNetworkAdapter first (for DistributedPortGroup objects),
        then falls back to HostNetworkSystem.UpdateVirtualNic. If the port group already has another
        VMkernel adapter, removes it before retrying the move. Throws VcfDeploymentException when
        the move cannot be completed by either path.

        .PARAMETER HostName
        Display name of the host (for log messages).

        .PARAMETER MgmtVlanId
        VLAN ID to assign to the Management port group on vSwitch0-restore.

        .PARAMETER PnicObject
        The physical NIC object to attach to vSwitch0-restore.

        .PARAMETER PnicName
        The name of the pNIC (e.g. "vmnic1") to use as the uplink.

        .PARAMETER Server
        vCenter server name.

        .PARAMETER VMHost
        The host on which to build vSwitch0-restore.

        .PARAMETER Vmk0
        The vmk0 VMkernel adapter to migrate to the Management port group.

        .EXAMPLE
        Invoke-BuildRestoreVssAndMoveVmk0 -HostName "esx01" -MgmtVlanId 100 -PnicName "vmnic1" -PnicObject $pnic -VMHost $h -Vmk0 $vmk0
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$HostName,
        [Parameter(Mandatory = $true)] [ValidateRange(0, 4094)] [Int]$MgmtVlanId,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$PnicName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$PnicObject,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$Server = $Script:vCenterName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$VMHost,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$Vmk0
    )

    $vssName = "vSwitch0-restore"
    $existingVss = Get-VirtualSwitchesOnHost -VMHost $VMHost -Server $Server | Where-Object { $_.Name -eq $vssName }
    if ($existingVss) {
        $pnicsOnVss = Get-VMHostNetworkAdapter -VMHost $VMHost -Physical -VirtualSwitch $existingVss -Server $Server -ErrorAction SilentlyContinue
        if (-not ($pnicsOnVss | Where-Object { $_.Name -eq $PnicName })) {
            Add-VirtualSwitchPhysicalNetworkAdapter -VirtualSwitch $existingVss -VMHostPhysicalNic $PnicObject -Server $Server -Confirm:$false -ErrorAction Stop
            Write-LogMessage -Type DEBUG -Message "Attached pNIC `"$PnicName`" to existing `"$vssName`" on host `"$HostName`"."
        }
    } else {
        New-VirtualSwitch -VMHost $VMHost -Name $vssName -Nic $PnicName -Server $Server -ErrorAction Stop | Out-Null
        Write-LogMessage -Type DEBUG -Message "Created standard switch `"$vssName`" with pNIC `"$PnicName`" on host `"$HostName`"."
    }
    $vss = Get-VirtualSwitch -VMHost $VMHost -Standard -Name $vssName -Server $Server -ErrorAction Stop
    $mgmtPgName = "Management"
    $stdPg = Get-VirtualPortGroupsOnSwitch -VirtualSwitch $vss -Server $Server | Where-Object { $_.Name -eq $mgmtPgName } | Select-Object -First 1
    if (-not $stdPg) {
        New-VirtualPortGroup -VirtualSwitch $vss -Name $mgmtPgName -VLanId $MgmtVlanId -Server $Server -ErrorAction Stop | Out-Null
        $stdPg = Get-VirtualPortGroup -VirtualSwitch $vss -Name $mgmtPgName -Server $Server -ErrorAction Stop
        Write-LogMessage -Type DEBUG -Message "Created port group `"$mgmtPgName`" on `"$vssName`" (VLAN $MgmtVlanId) on host `"$HostName`"."
    }
    $moved = $false
    $pgTypeName = $stdPg.GetType().FullName
    if ($pgTypeName -match "Distributed|VDPortgroup") {
        try {
            Set-VMHostNetworkAdapter -VirtualNic $Vmk0 -PortGroup $stdPg -Confirm:$false -WarningAction SilentlyContinue -ErrorAction Stop 3>$null
            $moved = $true
            Write-LogMessage -Type DEBUG -Message "Moved management (vmk0) to standard switch on host `"$HostName`"."
        } catch {
            Write-LogMessage -Type DEBUG -Message "Set-VMHostNetworkAdapter to port group failed: $($_.Exception.Message). Trying HostNetworkSystem.UpdateVirtualNic."
        }
    }
    if (-not $moved) {
        try {
            $hostView = Get-View -Id $VMHost.Id -Server $Server -Property ConfigManager -ErrorAction Stop
            $netSys = Get-View -Id $hostView.ConfigManager.NetworkSystem -Server $Server -ErrorAction Stop
            $nicSpec = New-VimHostVirtualNicSpec
            $nicSpec.portgroup = $stdPg.Name
            $netSys.UpdateVirtualNic($Vmk0.Name, $nicSpec)
            $moved = $true
            Write-LogMessage -Type DEBUG -Message "Moved management (vmk0) to standard switch on host `"$HostName`"."
        } catch {
            Write-LogMessage -Type DEBUG -Message "HostNetworkSystem.UpdateVirtualNic failed: $($_.Exception.Message)."
        }
        # Remove existing VMkernel adapters on the port group and retry when UpdateVirtualNic fails with AlreadyExists.
        $existingOnStdPg = Get-VmkernelOnPortGroup -VMHost $VMHost -PortGroup $stdPg -Server $Server
        if (-not $moved -and $existingOnStdPg) {
            try {
                $existingOnStdPg | ForEach-Object { Remove-VMHostNetworkAdapter -Nic $_ -Confirm:$false -ErrorAction Stop }
                Write-LogMessage -Type DEBUG -Message "Removed existing VMkernel(s) from `"$mgmtPgName`" on host `"$HostName`" so vmk0 can be moved there."
                $hostView2b = Get-View -Id $VMHost.Id -Server $Server -Property ConfigManager -ErrorAction Stop
                $netSys2b = Get-View -Id $hostView2b.ConfigManager.NetworkSystem -Server $Server -ErrorAction Stop
                $nicSpec2b = New-VimHostVirtualNicSpec
                $nicSpec2b.portgroup = $stdPg.Name
                $netSys2b.UpdateVirtualNic($Vmk0.Name, $nicSpec2b)
                $moved = $true
                Write-LogMessage -Type DEBUG -Message "Moved management (vmk0) to standard switch on host `"$HostName`" via HostNetworkSystem.UpdateVirtualNic (after removing existing VMkernel on VSS)."
            } catch {
                Write-LogMessage -Type DEBUG -Message "UpdateVirtualNic after removing existing VMkernel failed: $($_.Exception.Message)."
            }
        }
    }
    if (-not $moved) {
        $errorMsg = "Moving vmk0 to VSS failed on host `"$HostName`" (Set-VMHostNetworkAdapter and HostNetworkSystem.UpdateVirtualNic did not succeed). In vCenter use Networking → Migrate VMkernel Adapter to move vmk0 to the standard switch (e.g. vSwitch0-restore / Management), then retry cleanup."
        Write-LogMessage -Type ERROR -Message $errorMsg
        throw [VcfDeploymentException]::new($errorMsg)
    }
    Write-LogMessage -Type DEBUG -Message "Moved vmk0 to `"$vssName`"/`"$mgmtPgName`" (VLAN $MgmtVlanId) using pNIC `"$PnicName`" on host `"$HostName`"."
}
function Invoke-RestoreHostManagementToVss {

    <#
        .SYNOPSIS
        Restores the vmk0 management adapter on a single host from the VDS to a standard switch.

        .DESCRIPTION
        Attempts to move vmk0 from the specified VDS to a standard switch (vSwitch0-restore) using
        these strategies in order:
        1. If vSwitch0-restore already exists with a pNIC and Management port group, move vmk0 there.
        2. Try any other existing standard switch that has a pNIC and a Management-like port group.
        3. Use any unused pNIC (not on the VDS) to build vSwitch0-restore, then move vmk0.
        4. Remove one pNIC from the VDS (highest-numbered first), create vSwitch0-restore, then move vmk0.
        Returns a status object indicating whether a restore was attempted, succeeded, was skipped,
        or was blocked by vSphere rollback.

        .PARAMETER Server
        vCenter server name.

        .PARAMETER VdsHasMgmtPortGroup
        When $true, force-assume vmk0 may be on the VDS even if per-host detection is inconclusive.

        .PARAMETER VdsNameWithMgmt
        Name of the VDS that carries management traffic.

        .PARAMETER VdsObject
        The VDS object (from Get-VDSwitch).

        .PARAMETER VMHost
        The host to restore management on.

        .EXAMPLE
        $hostResult = Invoke-RestoreHostManagementToVss -VMHost $esxHost -VdsNameWithMgmt "VDS-vsan-edge1-sw1" -VdsObject $vdsObject -VdsHasMgmtPortGroup -Server $Script:vCenterName

        .OUTPUTS
        PSCustomObject with: Success (bool), Restored (bool), SkippedNoVmk0 (bool),
        SkippedNotOnVds (bool), SkippedRollback (bool), ErrorMessage (string).
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$Server = $Script:vCenterName,
        [Parameter(Mandatory = $false)] [Switch]$VdsHasMgmtPortGroup,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VdsNameWithMgmt,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$VdsObject,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$VMHost
    )

    $hostResult = [PSCustomObject]@{
        Success          = $true
        Restored         = $false
        SkippedNoVmk0    = $false
        SkippedNotOnVds  = $false
        SkippedRollback  = $false
        ErrorMessage     = ""
    }

    $hostName = $VMHost.Name
    $vmk0 = Get-VmkernelAdaptersOnHost -VMHost $VMHost -Server $Server | Where-Object { $_.Name -eq "vmk0" }
    if (-not $vmk0) {
        Write-LogMessage -Type DEBUG -Message "Host `"$hostName`" has no vmk0; skipping."
        $hostResult.SkippedNoVmk0 = $true
        return $hostResult
    }

    $vmk0OnThisVds = Test-VmkAdapterOnVds -Server $Server -VdsHasMgmtPortGroup:$VdsHasMgmtPortGroup -VdsName $VdsNameWithMgmt -VdsObject $VdsObject -VMHost $VMHost -Vmk0Adapter $vmk0
    if (-not $vmk0OnThisVds) {
        Write-LogMessage -Type DEBUG -Message "Host `"$hostName`" vmk0 is not on VDS `"$VdsNameWithMgmt`"; skipping."
        $hostResult.SkippedNotOnVds = $true
        return $hostResult
    }

    Write-LogMessage -Type INFO -Message "Attempting management restore for host `"$hostName`" (vmk0 on VDS `"$VdsNameWithMgmt`")."

    $ip = $vmk0.IP
    if ([String]::IsNullOrWhiteSpace($ip)) {
        Write-LogMessage -Type WARNING -Message "Host `"$hostName`" vmk0 has no IP; cannot restore to VSS. Skipping."
        $hostResult.SkippedNoVmk0 = $true
        return $hostResult
    }

    $mgmtVlanId = Get-Vmk0ManagementVlanId -HostName $hostName -Server $Server -VdsObject $VdsObject -VMHost $VMHost -Vmk0 $vmk0
    $vssNameRestore = "vSwitch0-restore"

    if (Invoke-RestoreVmk0ToExistingRestoreVss -HostName $hostName -Server $Server -VMHost $VMHost -Vmk0 $vmk0 -VssNameRestore $vssNameRestore) {
        $hostResult.Restored = $true
        return $hostResult
    }
    if (Invoke-RestoreVmk0ToFallbackVss -HostName $hostName -Server $Server -VMHost $VMHost -Vmk0 $vmk0 -VssNameRestore $vssNameRestore) {
        $hostResult.Restored = $true
        return $hostResult
    }
    if (Invoke-RestoreVmk0UsingUnusedPnic -HostName $hostName -MgmtVlanId $mgmtVlanId -Server $Server -VdsObject $VdsObject -VMHost $VMHost -Vmk0 $vmk0) {
        $hostResult.Restored = $true
        return $hostResult
    }

    $pnicResult = Invoke-SelectAndRemoveVdsPnic -HostName $hostName -Server $Server -VdsObject $VdsObject -VMHost $VMHost
    if ($pnicResult.NoPnicsOnVds) {
        Write-LogMessage -Type WARNING -Message "Host `"$hostName`" has no pNICs on VDS `"$VdsNameWithMgmt`"; cannot restore management to VSS. Skipping."
        $hostResult.SkippedNotOnVds = $true
        return $hostResult
    }
    if (-not $pnicResult.PnicName) {
        Write-LogMessage -Type WARNING -Message "Host `"$hostName`": could not remove any pNIC from VDS `"$VdsNameWithMgmt`" (vSphere rolled back to avoid losing management). vSwitch0-restore and Management port group were not created because we must remove a pNIC first to build the restore switch; move vmk0 to a standard switch manually in vCenter (create vSwitch0-restore and Management if needed, then Migrate VMkernel Adapter), then retry cleanup."
        $hostResult.SkippedRollback = $true
        $hostResult.Success = $false
        $hostResult.ErrorMessage = "vSphere rolled back pNIC removal on host `"$hostName`"."
        return $hostResult
    }

    try {
        Write-LogMessage -Type DEBUG -Message "Removed pNIC `"$($pnicResult.PnicName)`" from VDS `"$VdsNameWithMgmt`" on host `"$hostName`" for management restore."
        Invoke-BuildRestoreVssAndMoveVmk0 -HostName $hostName -MgmtVlanId $mgmtVlanId -PnicName $pnicResult.PnicName -PnicObject $pnicResult.PnicObject -Server $Server -VMHost $VMHost -Vmk0 $vmk0
        $hostResult.Restored = $true
        return $hostResult
    } catch {
        $rollbackMsg = "disconnected the host"
        if ($_.Exception.Message -match [Regex]::Escape($rollbackMsg)) {
            Write-LogMessage -Type ERROR -Message "vSphere rolled back the change on host `"$hostName`" to avoid losing management. In vCenter: create a standard switch (e.g. vSwitch0-restore) with one pNIC, add a Management port group, move vmk0 to that port group, then retry cleanup."
        }
        Write-LogMessage -Type ERROR -Message "Failed to restore management to VSS on host `"$hostName`": $($_.Exception.Message)"
        $hostResult.Success = $false
        $hostResult.ErrorMessage = "Failed on host `"$hostName`": $($_.Exception.Message)"
        return $hostResult
    }
}
function Resolve-HostsForMgmtRestore {

    <#
        .SYNOPSIS
        Resolves the list of ESX hosts on which management (vmk0) should be restored before VDS removal.

        .DESCRIPTION
        Three resolution paths:
        (a) $VMHost is supplied: returns a single-element array containing that host.
        (b) $ClusterName resolves to a cluster: returns all hosts in that cluster.
        (c) Fallback: returns all hosts attached to $VdsObject (used when the cluster was already removed).
        Returns an empty array when no hosts are found via any path.

        .PARAMETER ClusterName
        Name of the cluster to look up when $VMHost is not supplied.

        .PARAMETER Server
        vCenter server name.

        .PARAMETER VdsNameWithMgmt
        Display name of the VDS carrying management traffic, used only in log messages.

        .PARAMETER VdsObject
        The VDS PowerCLI object, used for the VDS-attached-host fallback path.

        .PARAMETER VMHost
        When supplied, the single host to process. Bypasses cluster and VDS host discovery.

        .EXAMPLE
        $vmHosts = Resolve-HostsForMgmtRestore -ClusterName "cl0" -Server $vcenterName -VdsNameWithMgmt "VDS-site1" -VdsObject $vds

        .NOTES
        Logs DEBUG and INFO messages for each resolution path. Does not throw; callers must check for an
        empty return array and act accordingly (e.g. return early with no restore attempted).
    #>

    [CmdletBinding()]
    [OutputType([Object[]])]
    Param (
        [Parameter(Mandatory = $false)] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [String]$Server,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VdsNameWithMgmt,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$VdsObject,
        [Parameter(Mandatory = $false)] [PSObject]$VMHost = $null
    )

    if ($VMHost) {
        return @($VMHost)
    }

    if ([String]::IsNullOrWhiteSpace($ClusterName)) {
        Write-LogMessage -Type WARNING -Message "Resolve-HostsForMgmtRestore: neither -VMHost nor -ClusterName was supplied; attempting host discovery from VDS `"$VdsNameWithMgmt`" only."
    }

    $clusterObject = Get-ClusterByName -Name $ClusterName -Server $Server
    if ($clusterObject) {
        return @(Get-VMHost -Location $clusterObject -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue)
    }

    # Cluster not found or empty; try hosts attached to the VDS so management can be restored before VDS removal
    # even when the cluster was already removed (e.g. partial cleanup retry).
    $hosts = @()
    try {
        $hosts = @(Get-VMHost -DistributedSwitch $VdsObject -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue)
    } catch {
        Write-LogMessage -Type DEBUG -Message "Could not get hosts from VDS `"$VdsNameWithMgmt`": $($_.Exception.Message)."
    }
    if (-not $hosts -or $hosts.Count -eq 0) {
        Write-LogMessage -Type DEBUG -Message "Cluster `"$ClusterName`" not found and no hosts on VDS `"$VdsNameWithMgmt`"; nothing to restore."
        return @()
    }
    Write-LogMessage -Type INFO -Message "Cluster `"$ClusterName`" not found; restoring management on $($hosts.Count) host(s) attached to VDS `"$VdsNameWithMgmt`"."
    return $hosts
}
function Test-VdsMgmtPortGroupExists {

    <#
        .SYNOPSIS
        Returns $true when the specified VDS has one or more management-named port groups.

        .DESCRIPTION
        Uses Get-DpgsOnVds first; falls back to Get-VDPortgroup when no non-uplink port groups are returned.
        A port group is considered management-named when its name equals "mgmt-<VdsBaseName>" (VdsBaseName is
        the VDS name after stripping the leading "VDS-" prefix) or matches the "mgmt-*" wildcard.

        .PARAMETER Server
        vCenter server name.

        .PARAMETER VDSwitch
        The VDS PowerCLI object.

        .PARAMETER VdsNameWithMgmt
        Display name of the VDS, used to derive the expected management port group name pattern and in log messages.

        .EXAMPLE
        $hasMgmt = Test-VdsMgmtPortGroupExists -VDSwitch $vds -VdsNameWithMgmt "VDS-site1" -Server $vcenterName

        .NOTES
        Does not throw. Returns $false when no management-named port groups are found.
        Called by Restore-ManagementToVssBeforeVdsRemoval to determine whether to attempt restore even when
        per-host vmk0 detection does not positively confirm vmk0 is on the VDS.
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $false)] [String]$Server,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VdsNameWithMgmt,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$VDSwitch
    )

    $expectedPattern = "mgmt-$($VdsNameWithMgmt -replace '^VDS-', '')"
    $vdsUserPgs = @(Get-DpgsOnVds -VDSwitch $VDSwitch -Server $Server)
    if ($vdsUserPgs.Count -eq 0) {
        # Fallback using -VDSwitch parameter directly — avoids the deprecated .VDSwitch property access
        # that would be needed to filter a server-wide Get-VDPortgroup result by VDS name.
        $vdsUserPgs = @(Get-VDPortgroup -VDSwitch $VDSwitch -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notlike "*DVUplinks*" })
    }
    $hasMgmt = @($vdsUserPgs | Where-Object { $_.Name -eq $expectedPattern -or $_.Name -like "mgmt-*" }).Count -gt 0
    Write-LogMessage -Type DEBUG -Message "VDS `"$VdsNameWithMgmt`" user port groups: $($vdsUserPgs.Count) ($(@($vdsUserPgs | Select-Object -ExpandProperty Name | Sort-Object) -join ', ')). Management-named (mgmt-*): $hasMgmt."
    if ($hasMgmt) {
        Write-LogMessage -Type DEBUG -Message "VDS `"$VdsNameWithMgmt`" has management-named port group(s); will attempt restore on each host if vmk0 detection fails."
    }
    return $hasMgmt
}
function Restore-ManagementToVssBeforeVdsRemoval {

    <#
        .SYNOPSIS
        Restores host management (vmk0) from the VDS to a new standard switch so the host remains reachable when the VDS is removed.

        .DESCRIPTION
        Before removing a VDS that carries management traffic, this function removes one pNIC from the specified VDS on each host, attaches it to a new VSS, and moves vmk0 back to the VSS with the same IP. When removing from the VDS, it tries the pNIC that is last alphabetically first (e.g. vmnic1 before vmnic0), so the lowest-numbered NIC remains on the VDS until the VDS is deleted and is then unassigned. On re-deploy, Get-FirstUnusedNicFromNicList (NicList order) adds that lowest-numbered NIC first, giving deterministic deploy/restore/deploy and VDS uplinks that match the approved NicList. The pNIC chosen for restore is from this VDS (not from NicList). When -VMHost is supplied, only that host is processed regardless of -ClusterName.

        .PARAMETER ClusterName
        Name of the cluster whose hosts to process. Optional when -VMHost is supplied; ignored when -VMHost is provided.

        .PARAMETER Server
        vCenter server name. Defaults to $Script:vCenterName.

        .PARAMETER VdsNameWithMgmt
        Name of the VDS that currently has the management port group (e.g. VdsName for 2-NIC, VdsName-sw1 for 4-NIC).

        .PARAMETER VMHost
        When supplied, restores management on this single host only. Bypasses cluster/VDS host discovery. Use for single-host reclaim scenarios (e.g. moving a host from one cluster to another).

        .OUTPUTS
        PSCustomObject with RestoreAttempted (bool), Success (bool), HostsRestoredCount (int), Message (string).
        Caller should skip VDS removal when RestoreAttempted is true and Success is false.

        .NOTES
        Skips hosts that do not have vmk0 on the specified VDS. Restore is only ever to vSwitch0-restore/Management; the restore vSwitch is created before any move. Order: (1) if vSwitch0-restore already exists with a pNIC and Management port group, move vmk0 there; (2) else if the host has an unused pNIC (not on the VDS), create or complete vSwitch0-restore and Management port group then move vmk0—this path also recovers retry after partial failure; (3) else remove one pNIC from the VDS, create vSwitch0-restore and Management port group, then move vmk0. When creating the Management port group, the VLAN ID from the current management DPG is applied. When removing a pNIC from the VDS, tries highest-numbered first (e.g. vmnic1 before vmnic0) so the lowest-numbered NIC (typically vmnic0, the original management-bearing NIC) remains on the VDS until it is deleted and is then unassigned. On re-deploy, Get-FirstUnusedNicFromNicList (NicList order) adds that lowest-numbered NIC first, giving deterministic deploy/restore/deploy cycles. Moves vmk0 via HostNetworkSystem.UpdateVirtualNic. When move fails, throws with instructions to use vCenter Migrate VMkernel Adapter and retry.
    
        .EXAMPLE
        Restore-ManagementToVssBeforeVdsRemoval -VdsNameWithMgmt "resource-name"
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$Server = $Script:vCenterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VdsNameWithMgmt,
        [Parameter(Mandatory = $false)] [PSObject]$VMHost = $null
    )

    $result = [PSCustomObject]@{ RestoreAttempted = $false; Success = $true; HostsRestoredCount = 0; Message = "" }

    $connectionTest = Test-VcenterConnection
    if (-not $connectionTest.IsConnected) {
        Write-LogMessage -Type ERROR -Message "Not connected to vCenter `"$Server`": $($connectionTest.ErrorMessage)"
        $result.RestoreAttempted = $true
        $result.Success = $false
        $result.Message = "Not connected to vCenter."
        return $result
    }

    $vdsObject = Get-VdsByName -Name $VdsNameWithMgmt -Server $Server
    if (-not $vdsObject) {
        Write-LogMessage -Type DEBUG -Message "VDS `"$VdsNameWithMgmt`" not found; nothing to restore for management."
        return $result
    }

    $hosts = @(Resolve-HostsForMgmtRestore `
        -ClusterName $ClusterName `
        -Server $Server `
        -VdsObject $vdsObject `
        -VdsNameWithMgmt $VdsNameWithMgmt `
        -VMHost $VMHost)
    if (-not $hosts -or $hosts.Count -eq 0) {
        return $result
    }

    $result.RestoreAttempted = $true
    $hostsRestoredCount = 0
    $restoreSkippedDueToRollback = $false
    # Determine if the VDS has a management-named port group; passed to Invoke-RestoreHostManagementToVss
    # so it can attempt restore even when per-host vmk0 detection misses it.
    $vdsHasMgmtPortGroup = Test-VdsMgmtPortGroupExists -VDSwitch $vdsObject -VdsNameWithMgmt $VdsNameWithMgmt -Server $Server
    Write-LogMessage -Type INFO -NoNewline -Message "Restoring management (vmk0) to standard switch on hosts... "

    foreach ($vmhost in $hosts) {
        $hostResult = Invoke-RestoreHostManagementToVss `
            -Server $Server `
            -VdsHasMgmtPortGroup:$vdsHasMgmtPortGroup `
            -VdsNameWithMgmt $VdsNameWithMgmt `
            -VdsObject $vdsObject `
            -VMHost $vmhost

        if ($hostResult.SkippedNoVmk0 -or $hostResult.SkippedNotOnVds) {
            continue
        }
        if ($hostResult.SkippedRollback) {
            $restoreSkippedDueToRollback = $true
            continue
        }
        if (-not $hostResult.Success) {
            Write-LogMessage -Type INFO -CompletePending -Message " Failed."
            $result.Success = $false
            $result.HostsRestoredCount = $hostsRestoredCount
            $result.Message = $hostResult.ErrorMessage
            return $result
        }
        if ($hostResult.Restored) {
            $hostsRestoredCount++
        }
    }
    $result.HostsRestoredCount = $hostsRestoredCount
    if ($hostsRestoredCount -gt 0) {
        Write-LogMessage -Type INFO -CompletePending -Message "Moved management to VSS on $hostsRestoredCount host(s)."
    }
    elseif ($restoreSkippedDueToRollback) {
        Write-LogMessage -Type INFO -CompletePending -Message "No hosts restored; pNIC removal was blocked (vSphere rollback), so vSwitch0-restore and Management port group were never created."
        $result.Success = $false
        $result.Message = "vSphere rolled back pNIC removal (host would have been disconnected). vSwitch0-restore and Management port group were not created. Create them in vCenter, move vmk0 to the standard switch (Migrate VMkernel Adapter), then retry cleanup."
    }
    else {
        Write-LogMessage -Type INFO -CompletePending -Message "No hosts required restore (vmk0 not on VDS)."
    }
    return $result
}
function Get-VDPortgroupById {

    <#
        .SYNOPSIS
        Returns a distributed port group by its MoRef ID. Thin wrapper over Get-VDPortgroup enabling unit tests to mock this call without fighting PowerCLI type constraints on the -Server parameter.

        .PARAMETER Id
        MoRef ID of the distributed port group (e.g. "dvportgroup-42").

        .PARAMETER Server
        vCenter server name or connection object.

        .EXAMPLE
        Get-VDPortgroupById -Id "dvportgroup-42" -Server "vc.lab"
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Id,
        [Parameter(Mandatory = $false)] [String]$Server = $Script:vCenterName
    )

    Get-VDPortgroup -Id $Id -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
}
function Get-DpgsOnVds {

    <#
        .SYNOPSIS
        Returns all non-DVUplinks distributed port groups on a VDS. Thin wrapper over Get-VDPortgroup enabling unit tests to mock this call without fighting PowerCLI type constraints.

        .PARAMETER Server
        vCenter server name or connection object.

        .PARAMETER VDSwitch
        The VDS object whose port groups are returned.

        .EXAMPLE
        Get-DpgsOnVds -VDSwitch $vdsObj -Server "vc.lab"
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$Server = $Script:vCenterName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$VDSwitch
    )

    Get-VDPortgroup -VDSwitch $VDSwitch -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike "*DVUplinks*" }
}
function Get-PhysicalNicsOnVdsForHost {

    <#
        .SYNOPSIS
        Returns the physical NICs (pNICs) a host contributes as uplinks to a VDS. Thin wrapper over Get-VMHostNetworkAdapter enabling unit tests to mock this call without fighting PowerCLI type constraints.

        .PARAMETER Server
        vCenter server name or connection object.

        .PARAMETER VDSwitch
        The VDS object to check pNIC membership for.

        .PARAMETER VMHost
        The VMHost object whose pNICs are inspected.

        .EXAMPLE
        Get-PhysicalNicsOnVdsForHost -VMHost $vmhostObj -VDSwitch $vdsObj -Server "vc.lab"
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [String]$Server = $Script:vCenterName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$VDSwitch,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$VMHost
    )

    Get-VMHostNetworkAdapter -VMHost $VMHost -Physical -VirtualSwitch $VDSwitch -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
}
function Get-PhysicalNicsOnVssForHost {

    <#
        .SYNOPSIS
        Returns the physical NICs (pNICs) on a standard virtual switch for a host. Thin wrapper over
        Get-VMHostNetworkAdapter enabling unit tests to mock this call without fighting PowerCLI type
        constraints on the -VMHost parameter.

        .PARAMETER VMHost
        The VMHost object whose pNICs are inspected.

        .PARAMETER VirtualSwitch
        The standard virtual switch (VSS) object to query pNIC membership for.

        .PARAMETER Server
        vCenter server name or connection object.

        .EXAMPLE
        Get-PhysicalNicsOnVssForHost -VMHost $vmhostObj -VirtualSwitch $vssObj -Server "vc.lab"
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [String]$Server = $Script:vCenterName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$VirtualSwitch,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$VMHost
    )

    Get-VMHostNetworkAdapter -VMHost $VMHost -Physical -VirtualSwitch $VirtualSwitch -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
}
function Get-VmkernelAdaptersOnHost {

    <#
        .SYNOPSIS
        Returns all VMkernel adapters for a host. Thin wrapper over Get-VMHostNetworkAdapter enabling unit tests to mock this call without fighting PowerCLI type constraints.

        .PARAMETER Server
        vCenter server name or connection object.

        .PARAMETER VMHost
        The VMHost object whose VMkernel adapters are returned.

        .EXAMPLE
        Get-VmkernelAdaptersOnHost -VMHost $vmhostObj -Server "vc.lab"
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [String]$Server = $Script:vCenterName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$VMHost
    )

    Get-VMHostNetworkAdapter -VMHost $VMHost -VMKernel -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
}
function Get-VdsListOnHost {

    <#
        .SYNOPSIS
        Returns all VDSes a host participates in. Thin wrapper over Get-VDSwitch enabling unit tests to mock this call without fighting PowerCLI type constraints.

        .PARAMETER Server
        vCenter server name or connection object.

        .PARAMETER VMHost
        The VMHost object whose VDS memberships are returned.

        .EXAMPLE
        Get-VdsListOnHost -VMHost $vmhostObj -Server "vc.lab"
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$Server = $Script:vCenterName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$VMHost
    )

    Get-VDSwitch -VMHost $VMHost -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
}
function Get-ClusterByName {

    <#
        .SYNOPSIS
        Returns a cluster by name. Thin wrapper over Get-Cluster enabling unit tests to mock this call without fighting PowerCLI type constraints on the -Server parameter.

        .PARAMETER Name
        Name of the cluster to retrieve.

        .PARAMETER Server
        vCenter server name or connection object.

        .EXAMPLE
        Get-ClusterByName -Name "Cluster01" -Server "vc.lab"
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Name,
        [Parameter(Mandatory = $false)] [String]$Server = $Script:vCenterName
    )

    Get-Cluster -Name $Name -Server $Server -ErrorAction SilentlyContinue
}
function Get-VmHostsInCluster {

    <#
        .SYNOPSIS
        Returns all VMHosts in a cluster. Thin wrapper over Get-VMHost enabling unit tests to mock this call without fighting PowerCLI type constraints on the -Location parameter.

        .PARAMETER ClusterObject
        The cluster object whose hosts are returned.

        .EXAMPLE
        Get-VmHostsInCluster -ClusterObject $clusterObj
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$ClusterObject
    )

    Get-VMHost -Location $ClusterObject -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
}
function Get-VmsFromCluster {

    <#
        .SYNOPSIS
        Returns all VMs in a cluster. Thin wrapper over Get-VM enabling unit tests to mock this call without fighting PowerCLI pipeline-input binding constraints.

        .PARAMETER ClusterObject
        The cluster object whose VMs are returned.

        .PARAMETER Server
        vCenter server name or connection object.

        .EXAMPLE
        Get-VmsFromCluster -ClusterObject $clusterObj -Server "vc.lab"
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$ClusterObject,
        [Parameter(Mandatory = $false)] [String]$Server = $Script:vCenterName
    )

    Get-VM -Location $ClusterObject -Server $Server -ErrorAction SilentlyContinue
}
function Get-VmViewForVm {

    <#
        .SYNOPSIS
        Returns the View object for a VM. Thin wrapper over Get-View enabling unit tests to mock this call without fighting PowerCLI ArgumentTransformationAttribute constraints on the -VIObject parameter.

        .PARAMETER VmObject
        The VM object whose View is returned.

        .EXAMPLE
        Get-VmViewForVm -VmObject $vm
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$VmObject
    )

    Get-View -VIObject $VmObject -ErrorAction SilentlyContinue
}
function Get-DatacenterForVMHost {

    <#
        .SYNOPSIS
        Returns the datacenter that contains a VMHost. Thin wrapper over Get-Datacenter enabling unit
        tests to mock this call without fighting PowerCLI ArgumentTransformationAttribute constraints
        on the -VMHost parameter.

        .PARAMETER VMHost
        The VMHost object whose parent datacenter is returned.

        .PARAMETER Server
        vCenter server name or connection object.

        .EXAMPLE
        Get-DatacenterForVMHost -VMHost $vmhostObj -Server "vc.lab"
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $false)] [String]$Server = $Script:vCenterName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$VMHost
    )

    Get-Datacenter -VMHost $VMHost -Server $Server -ErrorAction SilentlyContinue
}
function Get-DatacenterForCluster {

    <#
        .SYNOPSIS
        Returns the datacenter that contains a cluster. Thin wrapper over Get-Datacenter enabling unit
        tests to mock this call without fighting PowerCLI ArgumentTransformationAttribute constraints
        on the -Cluster parameter.

        .PARAMETER Cluster
        The cluster object whose parent datacenter is returned.

        .PARAMETER Server
        vCenter server name or connection object.

        .EXAMPLE
        Get-DatacenterForCluster -Cluster $clusterObj -Server "vc.lab"
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$Cluster,
        [Parameter(Mandatory = $false)] [String]$Server = $Script:vCenterName
    )

    Get-Datacenter -Cluster $Cluster -Server $Server -ErrorAction SilentlyContinue
}
function Get-VirtualSwitchesOnHost {

    <#
        .SYNOPSIS
        Returns all standard virtual switches on a host. Thin wrapper over Get-VirtualSwitch enabling unit tests to mock this call without fighting PowerCLI type constraints on the -VMHost parameter.

        .PARAMETER Server
        vCenter server name or connection object.

        .PARAMETER VMHost
        The VMHost object whose standard switches are returned.

        .EXAMPLE
        Get-VirtualSwitchesOnHost -VMHost $vmhostObj -Server "vc.lab"
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [String]$Server = $Script:vCenterName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$VMHost
    )

    Get-VirtualSwitch -VMHost $VMHost -Standard -Server $Server -ErrorAction SilentlyContinue
}
function Get-VirtualPortGroupsOnSwitch {

    <#
        .SYNOPSIS
        Returns all port groups on a standard virtual switch. Thin wrapper over Get-VirtualPortGroup enabling unit tests to mock this call without fighting PowerCLI type constraints on the -VirtualSwitch parameter.

        .PARAMETER Server
        vCenter server name or connection object.

        .PARAMETER VirtualSwitch
        The standard virtual switch object whose port groups are returned.

        .EXAMPLE
        Get-VirtualPortGroupsOnSwitch -VirtualSwitch $vssObj -Server "vc.lab"
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [String]$Server = $Script:vCenterName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$VirtualSwitch
    )

    Get-VirtualPortGroup -VirtualSwitch $VirtualSwitch -Server $Server -ErrorAction SilentlyContinue
}
function Get-VmkernelOnPortGroup {

    <#
        .SYNOPSIS
        Returns VMkernel adapters on a specific port group for a host. Thin wrapper over Get-VMHostNetworkAdapter enabling unit tests to mock this call without fighting PowerCLI type constraints on the -PortGroup and -VMHost parameters.

        .PARAMETER PortGroup
        The port group object to filter VMkernel adapters by.

        .PARAMETER Server
        vCenter server name or connection object.

        .PARAMETER VMHost
        The VMHost object whose VMkernel adapters are inspected.

        .EXAMPLE
        Get-VmkernelOnPortGroup -VMHost $vmhostObj -PortGroup $pgObj -Server "vc.lab"
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$PortGroup,
        [Parameter(Mandatory = $false)] [String]$Server = $Script:vCenterName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$VMHost
    )

    # 3>$null suppresses the VmwareVDPortgroup.VirtualSwitch binding-time warning that -WarningAction alone cannot reach.
    Get-VMHostNetworkAdapter -VMHost $VMHost -VMKernel -PortGroup $PortGroup -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue 3>$null
}
function Test-Vmk0OnSingleVds {

    <#
        .SYNOPSIS
        Returns whether vmk0 is connected to the specified VDS on a host.

        .DESCRIPTION
        Performs a two-stage check. Primary: resolves vmk0's port group reference from
        ExtensionData.Spec.PortGroup and matches it against the VDS via Get-VDPortgroupById
        and DPG MoRef/Id comparison. Fallback: iterates each DPG on the VDS and checks whether
        Get-VmkernelOnPortGroup returns vmk0. Returns $true when either stage confirms vmk0 is
        on the VDS, $false when neither does.

        .PARAMETER HostName
        Host display name used only in DEBUG log messages.

        .PARAMETER Server
        vCenter server name for PowerCLI cmdlet calls.

        .PARAMETER Vds
        The Distributed Virtual Switch object to test vmk0 membership against.

        .PARAMETER Vmk0
        The vmk0 VMkernel adapter object for the host.

        .PARAMETER VMHost
        The VMHost object used by the fallback DPG-iteration path.

        .EXAMPLE
        $onVds = Test-Vmk0OnSingleVds -HostName "esx01.lab" -Vmk0 $vmk0 -Vds $vds -VMHost $vmhost -Server "vc.lab"

        .NOTES
        Called by Test-HostManagementVdsDualUplink in a foreach loop over all VDSes on the host.
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$HostName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Server,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$Vds,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$VMHost,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$Vmk0
    )

    $vmk0OnThisVds = $false

    # Primary: resolve vmk0's port group reference and match against this VDS.
    # Using Get-VDSwitch -VMHost is more reliable than resolving the port group reference via Get-VDPortgroup -Id,
    # which fails silently on certain PowerCLI/vCenter combinations when the MoRef format is not accepted.
    try {
        $pgRef = $Vmk0.ExtensionData.Spec.PortGroup
        if ($pgRef) {
            $pgRefValue = if ($pgRef.Value) { $pgRef.Value.ToString().Trim() } else { $pgRef.ToString().Trim() }
            $dpg = Get-VDPortgroupById -Id $pgRefValue -Server $Server
            if ($dpg) {
                # Avoid .VDSwitch (deprecated) — compare VDS membership via ExtensionData MoRef.
                $dpgVdsMoRef = if ($dpg.ExtensionData -and $dpg.ExtensionData.Config -and $dpg.ExtensionData.Config.DistributedVirtualSwitch) { $dpg.ExtensionData.Config.DistributedVirtualSwitch.Value } else { $null }
                $vdsMoRef = if ($Vds.ExtensionData -and $Vds.ExtensionData.MoRef) { $Vds.ExtensionData.MoRef.Value } else { $null }
                if ($dpgVdsMoRef -and $vdsMoRef -and $dpgVdsMoRef -eq $vdsMoRef) {
                    $vmk0OnThisVds = $true
                }
            }
            if (-not $vmk0OnThisVds -and $dpg) {
                $vdsPgs = @(Get-DpgsOnVds -VDSwitch $Vds -Server $Server)
                foreach ($vdsPg in $vdsPgs) {
                    if (($vdsPg.Id -and $dpg.Id -and $vdsPg.Id -eq $dpg.Id) -or ($vdsPg.Name -and $dpg.Name -and $vdsPg.Name -eq $dpg.Name)) {
                        $vmk0OnThisVds = $true
                        break
                    }
                    $dpgMoRef = if ($vdsPg.ExtensionData.MoRef.Value) { $vdsPg.ExtensionData.MoRef.Value.ToString().Trim() } else { "" }
                    # Normalize both MoRef values to just the dvportgroup-NNN portion before comparing to
                    # avoid wildcard substring false positives (e.g. "dvportgroup-12" matching "dvportgroup-123").
                    if ($dpgMoRef) {
                        $normRef   = if ($pgRefValue -match '([A-Za-z]+-\d+)') { $Matches[1] } else { $pgRefValue }
                        $normMoRef = if ($dpgMoRef  -match '([A-Za-z]+-\d+)') { $Matches[1] } else { $dpgMoRef }
                        if ($normRef -eq $normMoRef) {
                            $vmk0OnThisVds = $true
                            break
                        }
                    }
                }
            }
        }
    } catch {
        Write-LogMessage -Type DEBUG -Message "Test-HostManagementVdsDualUplink: port group reference check failed for host `"$HostName`" on VDS `"$($Vds.Name)`": $($_.Exception.Message)."
    }

    # Fallback: iterate each DPG on the VDS and check if Get-VMHostNetworkAdapter -PortGroup returns vmk0.
    if (-not $vmk0OnThisVds) {
        $vdsPgsIter = @(Get-DpgsOnVds -VDSwitch $Vds -Server $Server)
        foreach ($pg in $vdsPgsIter) {
            $vmksOnPg = Get-VmkernelOnPortGroup -VMHost $VMHost -PortGroup $pg.Name -Server $Server
            if ($vmksOnPg | Where-Object { $_.Name -eq "vmk0" }) {
                $vmk0OnThisVds = $true
                Write-LogMessage -Type DEBUG -Message "Test-HostManagementVdsDualUplink: vmk0 on host `"$HostName`" confirmed on VDS `"$($Vds.Name)`" via DPG iteration."
                break
            }
        }
    }

    return $vmk0OnThisVds
}
function Test-HostManagementVdsDualUplink {

    <#
        .SYNOPSIS
        Checks whether the VDS carrying management (vmk0) on a host has at least two physical NIC uplinks from that host.

        .DESCRIPTION
        Locates the Distributed Virtual Switch that vmk0 is connected to by inspecting the port group reference on the VMkernel adapter, then counts the physical NICs this host contributes to that VDS as uplinks. Returns a result object indicating whether the dual-uplink prerequisite is met and the name of the management VDS.

        .PARAMETER Server
        vCenter server name. Defaults to $Script:vCenterName.

        .PARAMETER VMHost
        The VMHost object to inspect.

        .OUTPUTS
        PSCustomObject with HasDualUplink (bool) and MgmtVdsName (string). MgmtVdsName is empty when vmk0 is not on a VDS.

        .EXAMPLE
        $uplinkResult = Test-HostManagementVdsDualUplink -VMHost $vmHostObject
        if (-not $uplinkResult.HasDualUplink) {
            Write-LogMessage -Type WARNING -Message "Host does not have dual uplinks on the management VDS."
        }

        .NOTES
        When vmk0 is already on a standard switch, HasDualUplink is $false and MgmtVdsName is empty. Callers should treat the empty-MgmtVdsName case as "no VDS cleanup needed" rather than a failure.
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$Server = $Script:vCenterName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$VMHost
    )

    $result = [PSCustomObject]@{ HasDualUplink = $false; MgmtVdsName = "" }
    $hostName = $VMHost.Name

    $vmk0 = Get-VmkernelAdaptersOnHost -VMHost $VMHost -Server $Server |
        Where-Object { $_.Name -eq "vmk0" }
    if (-not $vmk0) {
        Write-LogMessage -Type DEBUG -Message "Test-HostManagementVdsDualUplink: vmk0 not found on host `"$hostName`"."
        return $result
    }

    # Enumerate all VDSes this host has uplinks on; for each, check if vmk0 is on one of its port groups.
    $mgmtVds = $null
    $allVdsOnHost = @(Get-VdsListOnHost -VMHost $VMHost -Server $Server)
    foreach ($vds in $allVdsOnHost) {
        if (Test-Vmk0OnSingleVds -HostName $hostName -Vmk0 $vmk0 -Vds $vds -VMHost $VMHost -Server $Server) {
            $mgmtVds = $vds
            break
        }
    }

    if (-not $mgmtVds) {
        Write-LogMessage -Type DEBUG -Message "Test-HostManagementVdsDualUplink: vmk0 on host `"$hostName`" is not on any VDS (may already be on a standard switch)."
        return $result
    }

    $result.MgmtVdsName = $mgmtVds.Name
    $pnicsOnVds = @(Get-PhysicalNicsOnVdsForHost -VMHost $VMHost -VDSwitch $mgmtVds -Server $Server)
    $pnicCount = if ($pnicsOnVds) { $pnicsOnVds.Count } else { 0 }
    Write-LogMessage -Type DEBUG -Message "Test-HostManagementVdsDualUplink: host `"$hostName`" has $pnicCount pNIC(s) on management VDS `"$($mgmtVds.Name)`"."
    $result.HasDualUplink = ($pnicCount -ge 2)
    return $result
}
function Invoke-VdsPnicDetach {

    <#
        .SYNOPSIS
        Removes all pNICs from a VDS across all attached hosts.

        .DESCRIPTION
        Enumerates every host on the VDS and removes each physical NIC from the switch.
        Failures per-pNIC are logged as WARNING and do not stop the loop. Used before
        port group removal so the switch is in a clean state.

        .PARAMETER Server
        vCenter server name.

        .PARAMETER VdsName
        Name of the VDS; used in log messages.

        .PARAMETER VdsObject
        The VDS object returned by Get-VDSwitch.

        .EXAMPLE
        Invoke-VdsPnicDetach -Server $Script:vCenterName -VdsName "VDS-site1" -VdsObject $vdsObject
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Server,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VdsName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$VdsObject
    )

    $hostsOnVds = @(Get-VMHost -DistributedSwitch $VdsObject -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue)
    if (-not ($hostsOnVds -and $hostsOnVds.Count -gt 0)) { return }
    Write-LogMessage -Type DEBUG -Message "Detaching $($hostsOnVds.Count) host(s) from VDS `"$VdsName`" (removing pNICs)..."
    foreach ($vmhost in $hostsOnVds) {
        $hostName = $vmhost.Name
        $pnicsOnVds = @(Get-VMHostNetworkAdapter -VMHost $vmhost -Physical -VirtualSwitch $VdsObject -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue)
        foreach ($pnic in $pnicsOnVds) {
            try {
                $pnic | Remove-VDSwitchPhysicalNetworkAdapter -Confirm:$false -WarningAction SilentlyContinue -ErrorAction Stop
                Write-LogMessage -Type DEBUG -Message "Removed pNIC `"$($pnic.Name)`" from VDS `"$VdsName`" on host `"$hostName`"."
            } catch {
                Write-LogMessage -Type WARNING -Message "Failed to remove pNIC `"$($pnic.Name)`" from VDS on host `"$hostName`": $($_.Exception.Message). Port group removal may fail."
            }
        }
    }
}
function Invoke-VdsPortGroupFirstPass {

    <#
        .SYNOPSIS
        Removes all non-DVUplinks port groups from a VDS in a single pass.

        .DESCRIPTION
        Checks each port group for attached VMs (throws VcfDeploymentException if any are found),
        then removes each port group. Port groups that fail removal are added to FailedPortGroupNames.

        .PARAMETER FailedPortGroupNames
        List that will be populated with the names of port groups that could not be removed.
        Mutated in-place by this function.

        .PARAMETER Server
        vCenter server name.

        .PARAMETER VdsName
        Name of the VDS; used in log messages.

        .PARAMETER VdsObject
        The VDS object returned by Get-VDSwitch.

        .EXAMPLE
        Invoke-VdsPortGroupFirstPass -FailedPortGroupNames $failedPortGroupNames -Server $Script:vCenterName -VdsName "VDS-site1" -VdsObject $vdsObject
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [ValidateNotNull()] [System.Collections.Generic.List[String]]$FailedPortGroupNames,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Server,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VdsName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$VdsObject
    )

    $portGroups = Get-VDPortgroup -VDSwitch $VdsObject -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
    if (-not $portGroups) { return }
    # Exclude system DVUplinks port group(s); removed automatically when the switch is deleted.
    $portGroupsToCheckForVms = @($portGroups) | Where-Object { $_.Name -notlike "*DVUplinks*" }
    foreach ($portGroup in $portGroupsToCheckForVms) {
        # Get VMs connected to this port group without using -Network (not available in VCF PowerCLI 9).
        $vmsOnPg = Get-VM -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue | Where-Object {
            $_.NetworkAdapters | Where-Object { $_.Network -and ($_.Network.Id -eq $portGroup.Id -or $_.Network.Name -eq $portGroup.Name) }
        }
        if ($vmsOnPg -and @($vmsOnPg).Count -gt 0) {
            $vmList = @($vmsOnPg)
            $vmNames = $vmList | Select-Object -ExpandProperty Name
            $err = "Cannot remove VDS `"$VdsName`": port group `"$($portGroup.Name)`" has $($vmList.Count) VM(s) attached: $($vmNames -join ', '). Migrate or power off VMs first."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
    }
    $customPortGroups = @($portGroups) | Where-Object { $_.Name -notlike "*DVUplinks*" }
    $portGroupRemoveCount = 0
    Write-LogMessage -Type DEBUG -Message "Removing distributed port groups from VDS `"$VdsName`"..."
    foreach ($pg in $customPortGroups) {
        try {
            Remove-VDPortgroup -VDPortgroup $pg -Server $Server -Confirm:$false -WarningAction SilentlyContinue -ErrorAction Stop
            $portGroupRemoveCount++
            Write-LogMessage -Type DEBUG -Message "Removed port group `"$($pg.Name)`" from VDS `"$VdsName`"."
        } catch {
            Write-LogMessage -Type WARNING -Message "Failed to remove port group `"$($pg.Name)`": $($_.Exception.Message) Skipping; will still try to remove other port groups and the switch."
            [Void]$FailedPortGroupNames.Add($pg.Name)
        }
    }
    if ($FailedPortGroupNames.Count -eq 0) {
        Write-LogMessage -Type DEBUG -Message "Removed $portGroupRemoveCount port group(s) from VDS `"$VdsName`"."
    } else {
        Write-LogMessage -Type DEBUG -Message "Removed $portGroupRemoveCount port group(s) from VDS `"$VdsName`"; $($FailedPortGroupNames.Count) skipped (in use: $($FailedPortGroupNames -join ', '))."
    }
    if ($FailedPortGroupNames.Count -gt 0) {
        Write-LogMessage -Type INFO -Message "Port group(s) not removed from VDS `"$VdsName`" (in use): $($FailedPortGroupNames -join ', '). Move VMkernel adapters and VMs off these port groups, then remove the VDS manually or retry cleanup."
    }
}
function Invoke-VdsPortGroupRestoreFallback {

    <#
        .SYNOPSIS
        Attempts to restore management to VSS and then retries port group removal.

        .DESCRIPTION
        When the first-pass port group removal leaves some groups in use, calls
        Restore-ManagementToVssBeforeVdsRemoval and retries Remove-VDPortgroup on any
        remaining port groups. Updates FailedPortGroupNames in-place. Non-fatal: errors
        during restore are logged as WARNING, not thrown.

        .PARAMETER ClusterName
        Cluster name passed to Restore-ManagementToVssBeforeVdsRemoval.

        .PARAMETER FailedPortGroupNames
        List of port group names still in use. Cleared and re-populated by this function.

        .PARAMETER Server
        vCenter server name.

        .PARAMETER VdsName
        Name of the VDS.

        .EXAMPLE
        Invoke-VdsPortGroupRestoreFallback -ClusterName "cl0" -FailedPortGroupNames $failedPortGroupNames -Server $Script:vCenterName -VdsName "VDS-site1"
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [ValidateNotNull()] [System.Collections.Generic.List[String]]$FailedPortGroupNames,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Server,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VdsName
    )

    Write-LogMessage -Type INFO -Message "Port groups still in use on VDS `"$VdsName`"; attempting management restore to VSS on cluster `"$ClusterName`", then retrying port group removal (helps when JSON nicList no longer matches the deployed VDS)."
    try {
        $restoreAfterPgFail = Restore-ManagementToVssBeforeVdsRemoval -ClusterName $ClusterName -Server $Server -VdsNameWithMgmt $VdsName
        if ($restoreAfterPgFail.RestoreAttempted -and $restoreAfterPgFail.HostsRestoredCount -gt 0) {
            $vdsObjectRetry = Get-VDSwitch -Name $VdsName -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
            if (-not $vdsObjectRetry) { return }
            $portGroupsRetry = Get-VDPortgroup -VDSwitch $vdsObjectRetry -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
            $customPortGroupsRetry = @($portGroupsRetry) | Where-Object { $_.Name -notlike "*DVUplinks*" }
            $FailedPortGroupNames.Clear()
            $portGroupRemoveCountRetry = 0
            Write-LogMessage -Type DEBUG -Message "Retrying distributed port group removal on VDS `"$VdsName`" after management restore..."
            foreach ($pgRetry in $customPortGroupsRetry) {
                try {
                    Remove-VDPortgroup -VDPortgroup $pgRetry -Server $Server -Confirm:$false -WarningAction SilentlyContinue -ErrorAction Stop
                    $portGroupRemoveCountRetry++
                    Write-LogMessage -Type DEBUG -Message "Retry pass removed port group `"$($pgRetry.Name)`" from VDS `"$VdsName`"."
                } catch {
                    Write-LogMessage -Type WARNING -Message "Retry: failed to remove port group `"$($pgRetry.Name)`": $($_.Exception.Message)"
                    [Void]$FailedPortGroupNames.Add($pgRetry.Name)
                }
            }
            if ($FailedPortGroupNames.Count -eq 0) {
                Write-LogMessage -Type DEBUG -Message "Retry: removed $portGroupRemoveCountRetry port group(s) from VDS `"$VdsName`"."
            } else {
                Write-LogMessage -Type DEBUG -Message "Retry: removed $portGroupRemoveCountRetry; $($FailedPortGroupNames.Count) still in use ($($FailedPortGroupNames -join ', '))."
            }
            if ($FailedPortGroupNames.Count -gt 0) {
                Write-LogMessage -Type INFO -Message "Port group(s) still in use after restore retry: $($FailedPortGroupNames -join ', ')."
            }
        }
    } catch {
        Write-LogMessage -Type WARNING -Message "Management restore fallback before VDS removal failed for `"$VdsName`": $($_.Exception.Message)"
    }
}
function Remove-EdgeClusterDistributedSwitch {

    <#
        .SYNOPSIS
        Removes a Virtual Distributed Switch (VDS) and its distributed port groups belonging to an edge cluster. Used for rollback.

        .DESCRIPTION
        Ensures no VMs are attached to any distributed port group on the specified VDS, then removes each user-created
        distributed port group and finally the VDS. The DVUplinks port group is not removed explicitly; it is removed
        when the switch is deleted. If any VM is connected to a port group on the VDS, the function throws and no
        removal is performed.

        .PARAMETER ClusterName
        Name of the edge cluster. Used for logging context and for the port-group-in-use restore fallback.

        .PARAMETER Server
        Optional. vCenter server name. Defaults to $Script:vCenterName.

        .PARAMETER VdsName
        Name of the Virtual Distributed Switch to remove. Must be unique within the datacenter.

        .EXAMPLE
        Remove-EdgeClusterDistributedSwitch -ClusterName "cl0-site1" -VdsName "VDS-site1"

        .NOTES
        Requires an active vCenter connection. Uses Get-VDSwitch, Get-VDPortgroup, Get-VM (filtered by NetworkAdapters.Network), Remove-VDPortgroup,
        and Remove-VDSwitch. VMs on each port group are detected by filtering Get-VM results (no -Network parameter, for VCF PowerCLI 9 compatibility).         Only port groups whose name does not contain "DVUplinks" are removed (vCenter names the system uplinks e.g. "VDS-name-DVUplinks-12314"); the DVUplinks port group is removed automatically when the switch is deleted. If a port group cannot be removed (e.g. port in use by a VMkernel adapter), it is skipped and removal continues with other port groups; the VDS may then fail to remove until VMkernel adapters and VMs are moved off the remaining port groups. When ClusterName is set and port groups remain in use after the first pass, the function attempts Restore-ManagementToVssBeforeVdsRemoval for this VDS and retries port group removal once (covers JSON nicList changes vs deployed topology). PowerCLI deprecation warnings (VmwareVDPortgroup.VirtualSwitch, VMHost.DatastoreIdList) are suppressed at Get-VDSwitch, Get-VMHost, Get-VMHostNetworkAdapter, Get-VM, Remove-VDPortgroup, Remove-VDSwitchPhysicalNetworkAdapter, and Remove-VDSwitch using -WarningAction SilentlyContinue.

        .PARAMETER RemoveVdsRetryDelaySeconds
        When VDS removal fails due to object state, seconds to wait before retrying once. Default is 10.

        .PARAMETER SkipPortGroupInUseRestoreFallback
        When set, do not call Restore-ManagementToVssBeforeVdsRemoval after port group removal leaves DPGs in use (e.g. mgmt still on the VDS). Default is to try one restore-and-retry pass when ClusterName is provided.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 120)] [Int]$RemoveVdsRetryDelaySeconds = 10,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$Server = $Script:vCenterName,
        [Parameter(Mandatory = $false)] [Switch]$SkipPortGroupInUseRestoreFallback,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VdsName
    )

    $logContext = if ($ClusterName) { "cluster `"$ClusterName`", VDS `"$VdsName`"" } else { "VDS `"$VdsName`"" }

    Write-LogMessage -Type DEBUG -Message "Entered Remove-EdgeClusterDistributedSwitch for $logContext."

    Assert-VcenterConnected

    $vdsObject = Get-VDSwitch -Name $VdsName -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
    if (-not $vdsObject) {
        Write-LogMessage -Type DEBUG -Message "VDS `"$VdsName`" not found; nothing to remove."
        return
    }

    $failedPortGroupNames = [System.Collections.Generic.List[String]]::new()

    # Detach all pNICs from the VDS before port group removal to avoid "Operation is not valid due to the current state of the object" errors.
    Invoke-VdsPnicDetach -Server $Server -VdsName $VdsName -VdsObject $vdsObject

    Invoke-VdsPortGroupFirstPass -FailedPortGroupNames $failedPortGroupNames -Server $Server -VdsName $VdsName -VdsObject $vdsObject

    if ($failedPortGroupNames.Count -gt 0 -and -not [String]::IsNullOrWhiteSpace($ClusterName) -and -not $SkipPortGroupInUseRestoreFallback.IsPresent) {
        Invoke-VdsPortGroupRestoreFallback -ClusterName $ClusterName -FailedPortGroupNames $failedPortGroupNames -Server $Server -VdsName $VdsName
    }

    Write-LogMessage -Type DEBUG -Message "Removing Virtual Distributed Switch `"$VdsName`"..."
    $removeVdsAttempt = 1
    do {
        try {
            Remove-VDSwitch -VDSwitch $vdsObject -Server $Server -Confirm:$false -WarningAction SilentlyContinue -ErrorAction Stop
            Write-LogMessage -Type DEBUG -Message "Removed VDS `"$VdsName`"."
            break
        } catch {
            $removeErr = $_.Exception.Message
            if ($removeErr -match "Operation is not valid due to the current state of the object" -and $removeVdsAttempt -eq 1) {
                Write-LogMessage -Type WARNING -Message "VDS removal failed (object in transitional state). Waiting $RemoveVdsRetryDelaySeconds s before retry."
                Start-Sleep -Seconds $RemoveVdsRetryDelaySeconds
                $removeVdsAttempt++
                $vdsObject = Get-VDSwitch -Name $VdsName -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
                if (-not $vdsObject) {
                    Write-LogMessage -Type DEBUG -Message "VDS `"$VdsName`" no longer exists; removal may have completed. Skipping retry."
                    break
                }
            } else {
                if ($failedPortGroupNames -and $failedPortGroupNames.Count -gt 0) {
                    $err = "Failed to remove VDS `"$VdsName`". Port group(s) in use: $($failedPortGroupNames -join ', '). Move VMkernel adapters and VMs off these port groups, then remove the VDS manually or retry cleanup."
                    Write-LogMessage -Type ERROR -Message $err
                    throw [VcfDeploymentException]::new($err)
                } else {
                    $err = "Failed to remove VDS `"$VdsName`": $removeErr"
                    Write-LogMessage -Type ERROR -Message $err
                    throw [VcfDeploymentException]::new($err)
                }
            }
        }
    } while ($removeVdsAttempt -le 2)
}
function Set-VMHostConnectedState {

    <#
        .SYNOPSIS
        Sets a VMHost to connected state; exits maintenance mode if the host is in maintenance.

        .DESCRIPTION
        vSAN disk group operations require hosts to be in connected state. This function
        checks the host ConnectionState and, if it is Maintenance, calls Set-VMHost -State
        Connected so the host exits maintenance mode.

        .PARAMETER VMHost
        The VMHost object to check (e.g. from Get-VMHost).

        .PARAMETER Server
        vCenter server name (default: $Script:vCenterName).

        .EXAMPLE
        Set-VMHostConnectedState -VMHost $clusterHost -Server $Script:vCenterName

        .NOTES
        Uses ConnectionState property; value "Maintenance" triggers Set-VMHost -State Connected.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$Server = $Script:vCenterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] $VMHost
    )

    $hostName = $VMHost.Name
    $connectionState = $VMHost.ConnectionState
    if ($connectionState -eq "Maintenance") {
        Write-LogMessage -Type INFO -Message "Host `"$hostName`" is in maintenance mode. Exiting maintenance mode (Set-VMHost -State Connected)..."
        try {
            Set-VMHost -VMHost $VMHost -Server $Server -State Connected -Confirm:$false -ErrorAction Stop | Out-Null
            Write-LogMessage -Type INFO -Message "Host `"$hostName`" exited maintenance mode successfully."
        } catch [VcfDeploymentException] {
            throw  # already logged and typed — propagate without re-wrapping
        } catch {
            $err = "Failed to exit maintenance mode on host `"$hostName`": $($_.Exception.Message)"
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
    }
    elseif ($connectionState -ne "Connected") {
        Write-LogMessage -Type DEBUG -Message "Host `"$hostName`" connection state is `"$connectionState`" (not Maintenance). No action taken."
    }
}
function Resolve-DiskIsSsdProperty {

    <#
        .SYNOPSIS
        Returns whether a vSAN eligible disk object is an SSD, tolerating VCF PowerCLI
        9 API property-name casing variation.

        .DESCRIPTION
        VCF PowerCLI 9 returns disk objects where the SSD indicator may be named
        'IsSsd' or 'IsSSD' depending on the call path. This helper checks both names
        and returns $false when neither is present.
        Returns $true on success, $false on any error (error is logged before returning).

        .PARAMETER Disk
        A vSAN eligible disk PSCustomObject returned by Get-VsanOsaEligibleDisk.

        .OUTPUTS
        System.Boolean

        .EXAMPLE
        $isSsd = Resolve-DiskIsSsdProperty -Disk $disk
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$Disk
    )

    if ($null -ne $Disk.PSObject.Properties['IsSsd']) { return $Disk.IsSsd }
    if ($null -ne $Disk.PSObject.Properties['IsSSD']) { return $Disk.IsSSD }
    return $false
}
function Invoke-VsanOsaStaleDiskClaimResolution {

    <#
        .SYNOPSIS
        Checks for hosts with 0 eligible vSAN OSA disks and offers to remove stale disk claims.

        .DESCRIPTION
        When one or more cluster hosts have no eligible vSAN OSA disks, this function queries each
        affected host for stale disk groups from a prior deployment. If found, it either prompts the
        operator (interactive) or auto-removes them (lab environment), then re-queries and appends
        newly eligible disks to DiskDisplayList. Throws VcfDeploymentException when the operator
        declines cleanup, when cleanup fails to free all disks, or when hosts have no eligible disks
        and no stale groups.

        .PARAMETER ClusterHosts
        All VMHost objects in the cluster (used to detect which hosts are missing disks).

        .PARAMETER ClusterName
        Cluster display name used in log and exception messages.

        .PARAMETER DiskDisplayList
        A Generic.List[PSObject] populated with the initial eligible-disk display entries. Mutated
        in place: additional entries are appended when re-queried disks become available after cleanup.

        .PARAMETER LabEnvironment
        When $true, stale disk claims are removed automatically without operator confirmation.

        .EXAMPLE
        Invoke-VsanOsaStaleDiskClaimResolution -ClusterHosts $clusterHosts -ClusterName "cl0" -DiskDisplayList $diskDisplayList -LabEnvironment:$false

        .NOTES
        Deployment helper — throws VcfDeploymentException on failure. Caller must be inside a top-level
        try/catch that surfaces VcfDeploymentException to the user.
        Write-Host is the primary output mechanism in this function; all Write-Host calls are
        intentional interactive console output. Use Write-LogMessage for diagnostic logging.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object[]]$ClusterHosts,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$DiskDisplayList,
        [Parameter(Mandatory = $false)] [Switch]$LabEnvironment
    )

    $uniqueHostNames = $DiskDisplayList | Select-Object -ExpandProperty VMHostName -Unique
    $hostsWithDisks = @($uniqueHostNames)
    $hostsMissingDisks = @($ClusterHosts | Where-Object { $hostsWithDisks -notcontains $_.Name } | Select-Object -ExpandProperty Name)
    if ($hostsMissingDisks.Count -eq 0) { return }

    $hostsWithStaleClaims = [System.Collections.Generic.List[PSObject]]::new()
    foreach ($missingHostName in $hostsMissingDisks) {
        $missingHostObj = $ClusterHosts | Where-Object { $_.Name -eq $missingHostName } | Select-Object -First 1
        if (-not $missingHostObj) { continue }
        $diskGroupResult = Get-VsanOsaDiskGroupsOnHost -VMHost $missingHostObj
        if ($diskGroupResult.HasValidOsaGroup) {
            $hostsWithStaleClaims.Add([PSCustomObject]@{ Host = $missingHostObj; HostName = $missingHostName; DiskGroupCount = $diskGroupResult.DiskGroupCount })
            Write-LogMessage -Type WARNING -Message "Host `"$missingHostName`" has $($diskGroupResult.DiskGroupCount) stale vSAN OSA disk group(s) from a prior deployment. These must be removed to free the disks."
        }
    }

    if ($hostsWithStaleClaims.Count -eq 0) {
        $err = "vSAN OSA auto-claim requires eligible disks from every data host. The following host(s) contributed 0 eligible disks: $($hostsMissingDisks -join ', '). Run -CleanUp Compute first to clear any leftover disk claims, or ensure each host has unused disks visible to vSAN."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }

    $staleHostList = ($hostsWithStaleClaims | ForEach-Object { "`"$($_.HostName)`" ($($_.DiskGroupCount) disk group(s))" }) -join ", "
    $shouldCleanup = $false
    if ($LabEnvironment) {
        Write-LogMessage -Type WARNING -Message "Lab environment: auto-removing stale vSAN OSA disk claims on $staleHostList without prompting."
        $shouldCleanup = $true
    } else {
        Write-LogMessage -Type WARNING -Message "Stale vSAN OSA disk group(s) found on: $staleHostList. Remove these to free disks for this deployment."
        # Write-Host: interactive deployment prompt — cannot use Write-LogMessage here as prompts require direct console interaction.
        Write-Host ""
        $promptAnswer = Read-Host "Remove stale disk claims on these host(s) and continue? (Y=yes / N=no, abort deployment)"
        $shouldCleanup = ($promptAnswer -match '^[Yy]')
    }

    if (-not $shouldCleanup) {
        Write-LogMessage -Type INFO -Message "User chose not to remove stale disk claims. Aborting deployment."
        throw [VcfDeploymentException]::new("Deployment aborted. Stale vSAN OSA disk claims on $($hostsWithStaleClaims.Count) host(s) must be removed before deployment can proceed.")
    }

    foreach ($staleEntry in $hostsWithStaleClaims) {
        Write-LogMessage -Type INFO -Message "Removing stale vSAN OSA disk claims from host `"$($staleEntry.HostName)`"..."
        try {
            Remove-VsanDiskClaimsFromHost -StoragePolicyType "vSAN-OSA" -VMHost $staleEntry.Host
        } catch {
            Write-LogMessage -Type WARNING -Message "Stale disk claim removal on `"$($staleEntry.HostName)`" had errors (non-fatal, will re-check eligibility): $($_.Exception.Message)."
        }
    }
    if ($Script:VsanOsaEligibleDisksDelaySeconds -gt 0) {
        Write-LogMessage -Type DEBUG -Message "Waiting $($Script:VsanOsaEligibleDisksDelaySeconds)s for vSAN to reflect disk claim removal on host(s): $($hostsWithStaleClaims.HostName -join ', ')."
        Start-Sleep -Seconds $Script:VsanOsaEligibleDisksDelaySeconds
    }
    $cleanedHostObjs = @($hostsWithStaleClaims | Select-Object -ExpandProperty Host)
    Write-LogMessage -Type DEBUG -Message "Re-querying vSAN OSA eligible disks from $($cleanedHostObjs.Count) cleaned host(s): $(($hostsWithStaleClaims | Select-Object -ExpandProperty HostName) -join ', ')."
    $requeried = @(Get-VsanOsaEligibleDisksFromCluster -ClusterName $ClusterName -ClusterHosts $cleanedHostObjs)
    $diskIdCounter = $DiskDisplayList.Count + 1
    foreach ($disk in $requeried) {
        $DiskDisplayList.Add([PSCustomObject]@{
            Id            = $diskIdCounter
            VMHostName    = $disk.VMHost.Name
            CanonicalName = $disk.CanonicalName
            CapacityGB    = $disk.CapacityGB
            Model         = $disk.Model
            IsSsd         = Resolve-DiskIsSsdProperty -Disk $disk
            DiskObject    = $disk
        })
        $diskIdCounter++
    }
    $updatedUniqueHostNames = $DiskDisplayList | Select-Object -ExpandProperty VMHostName -Unique
    $updatedHostsWithDisks = @($updatedUniqueHostNames)
    $remainingMissingDisks = @($ClusterHosts | Where-Object { $updatedHostsWithDisks -notcontains $_.Name } | Select-Object -ExpandProperty Name)
    if ($remainingMissingDisks.Count -gt 0) {
        $err = "vSAN OSA auto-claim requires eligible disks from every data host. After stale disk claim removal, the following host(s) still have no eligible disks: $($remainingMissingDisks -join ', '). Ensure each host has unused disks visible to vSAN."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
    Write-LogMessage -Type INFO -Message "Stale disk claims removed. All $($ClusterHosts.Count) host(s) now have eligible disks."
}
function Invoke-VsanOsaStorageImbalanceWarning {

    <#
        .SYNOPSIS
        Logs a WARNING when vSAN OSA cache or total capacity disk sizes differ significantly across data hosts.

        .DESCRIPTION
        Compares the cache disk size and total capacity disk size for each host in SelectionByHost.
        When the range between the minimum and maximum exceeds StorageImbalanceThresholdPercent of the
        minimum value, a WARNING is logged to alert the operator.

        .PARAMETER SelectionByHost
        Hashtable keyed by host name, each entry containing CacheDisk and CapacityDisks[].

        .PARAMETER StorageImbalanceThresholdPercent
        Percentage difference threshold above which an imbalance WARNING is emitted. Defaults to 1.

        .PARAMETER UniqueHostNames
        Array of host names to inspect (data hosts only, no witness).

        .EXAMPLE
        Invoke-VsanOsaStorageImbalanceWarning -SelectionByHost $selectionByHost -UniqueHostNames $uniqueHostNames

        .NOTES
        Deployment helper — does not throw; only emits WARNING log messages.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Hashtable]$SelectionByHost,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 50)] [Int]$StorageImbalanceThresholdPercent = 1,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object[]]$UniqueHostNames
    )

    if ($UniqueHostNames.Count -lt 2) { return }

    $osaCacheByHost = @{}
    $osaCapacityTotalByHost = @{}
    foreach ($dataHostName in $UniqueHostNames) {
        $selection = $SelectionByHost[$dataHostName]
        $cacheGB = 0
        if ($null -ne $selection.CacheDisk -and $null -ne $selection.CacheDisk.CapacityGB) {
            $cacheGB = [Double]$selection.CacheDisk.CapacityGB
        }
        $osaCacheByHost[$dataHostName] = $cacheGB
        $capTotal = 0
        if ($selection.CapacityDisks) {
            foreach ($capacityDisk in $selection.CapacityDisks) {
                if ($null -ne $capacityDisk.CapacityGB) { $capTotal += [Double]$capacityDisk.CapacityGB }
            }
        }
        $osaCapacityTotalByHost[$dataHostName] = $capTotal
    }
    $cacheValues = @($osaCacheByHost.Values)
    $cacheMin = ($cacheValues | Measure-Object -Minimum).Minimum
    $cacheMax = ($cacheValues | Measure-Object -Maximum).Maximum
    if ($cacheMin -gt 0 -and $cacheMax -gt $cacheMin -and (($cacheMax - $cacheMin) / $cacheMin) -gt ($StorageImbalanceThresholdPercent / 100.0)) {
        $cacheList = ($osaCacheByHost.GetEnumerator() | Sort-Object -Property Name | ForEach-Object { "`"$($_.Key)`": $([Math]::Round($_.Value, 2)) GB" }) -join "; "
        Write-LogMessage -Type WARNING -Message "vSAN OSA: data host cache disk sizes differ by more than $StorageImbalanceThresholdPercent%. Cache capacity per host (GB): $cacheList."
    }
    $capValues = @($osaCapacityTotalByHost.Values)
    $capMin = ($capValues | Measure-Object -Minimum).Minimum
    $capMax = ($capValues | Measure-Object -Maximum).Maximum
    if ($capMin -gt 0 -and $capMax -gt $capMin -and (($capMax - $capMin) / $capMin) -gt ($StorageImbalanceThresholdPercent / 100.0)) {
        $capList = ($osaCapacityTotalByHost.GetEnumerator() | Sort-Object -Property Name | ForEach-Object { "`"$($_.Key)`": $([Math]::Round($_.Value, 2)) GB" }) -join "; "
        Write-LogMessage -Type WARNING -Message "vSAN OSA: data host total capacity disk sizes differ by more than $StorageImbalanceThresholdPercent%. Capacity total per host (GB): $capList."
    }
}
function Get-VsanOsaCacheDiskSelectionByHost {

    <#
        .SYNOPSIS
        Builds a per-host cache/capacity disk selection map from a vSAN OSA disk display list.

        .DESCRIPTION
        For each unique host in DiskDisplayList, selects the smallest SSD as cache and all remaining
        disks (SSDs and non-SSDs) as capacity. When no SSDs are present, the first disk is used as
        cache. Returns a hashtable keyed by host name, each value containing CacheDisk and
        CapacityDisks.

        .PARAMETER DiskDisplayList
        A Generic.List[PSObject] of disk display entries with VMHostName, Id, CanonicalName,
        CapacityGB, IsSsd, and DiskObject properties.

        .PARAMETER UniqueHostNames
        Array of unique host names to process (derived from DiskDisplayList).

        .EXAMPLE
        $selectionByHost = Get-VsanOsaCacheDiskSelectionByHost -DiskDisplayList $diskDisplayList -UniqueHostNames @($uniqueHostNames)

        .OUTPUTS
        System.Collections.Hashtable — keyed by host name with CacheDisk and CapacityDisks entries.
    #>

    [CmdletBinding()]
    [OutputType([Hashtable])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$DiskDisplayList,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object[]]$UniqueHostNames
    )

    $selectionByHost = @{}
    foreach ($currentHostName in $UniqueHostNames) {
        $disksOnCurrentHost = $DiskDisplayList | Where-Object { $_.VMHostName -eq $currentHostName }
        $ssdsOnHost = @($disksOnCurrentHost | Where-Object { $_.IsSsd } | Sort-Object -Property CapacityGB)
        $nonSsdsOnHost = $disksOnCurrentHost | Where-Object { -not $_.IsSsd }
        $cacheDisk = $null
        $capacityDisks = [System.Collections.Generic.List[PSObject]]::new()
        if ($ssdsOnHost -and $ssdsOnHost.Count -gt 0) {
            $cacheDisk = $ssdsOnHost[0]
            $autoclaimApiOrderStr = ($disksOnCurrentHost | ForEach-Object { "$($_.Id)/$($_.CapacityGB)/$($_.IsSsd)" }) -join ", "
            Write-LogMessage -Type DEBUG -Message "OSA autoclaim host `"$currentHostName`": disks (API order) Id/CapacityGB/IsSsd: $autoclaimApiOrderStr. Chosen cache: Id=$($cacheDisk.Id), CanonicalName=$($cacheDisk.CanonicalName), CapacityGB=$($cacheDisk.CapacityGB)."
            foreach ($disk in $ssdsOnHost) { if ($disk -ne $cacheDisk) { $capacityDisks.Add($disk) } }
        } else {
            Write-LogMessage -Type WARNING -Message "No SSD found on host `"$currentHostName`"; using first disk as cache for OSA disk group."
            $cacheDisk = $disksOnCurrentHost[0]
            Write-LogMessage -Type DEBUG -Message "OSA autoclaim host `"$currentHostName`": no SSDs; using first disk as cache: Id=$($cacheDisk.Id), CanonicalName=$($cacheDisk.CanonicalName), CapacityGB=$($cacheDisk.CapacityGB)."
            foreach ($capacityIndex in 1..($disksOnCurrentHost.Count - 1)) { $capacityDisks.Add($disksOnCurrentHost[$capacityIndex]) }
        }
        foreach ($disk in $nonSsdsOnHost) { $capacityDisks.Add($disk) }
        $capacitySizes = ($capacityDisks | Select-Object -ExpandProperty CapacityGB) -join ", "
        Write-LogMessage -Type DEBUG -Message "OSA autoclaim host `"$currentHostName`": cache CapacityGB=$($cacheDisk.CapacityGB); capacity disk count=$($capacityDisks.Count), CapacityGB=($capacitySizes)."
        $selectionByHost[$currentHostName] = [PSCustomObject]@{ CacheDisk = $cacheDisk; CapacityDisks = $capacityDisks.ToArray() }
    }
    return $selectionByHost
}
function Invoke-VsanOsaDiskGroupCreation {

    <#
        .SYNOPSIS
        Queries eligible OSA disks, assigns cache/capacity per host, creates disk groups, and waits for the vSAN datastore.

        .DESCRIPTION
        Retrieves vSAN OSA eligible disks from all cluster hosts, automatically selects the smallest SSD on each
        host as the cache disk and all remaining disks as capacity, displays an assignment summary table, calls
        Add-VsanOsaDiskToDiskGroup to create the disk groups, and then waits for the vSAN datastore to appear
        and renames it. Delegates stale-disk-claim resolution to Invoke-VsanOsaStaleDiskClaimResolution and
        storage imbalance checking to Invoke-VsanOsaStorageImbalanceWarning.

        .PARAMETER AddingToExistingDatastore
        When $true, the target vSAN datastore already exists but has no disks; skip the "no existing datastore" log.

        .PARAMETER CheckInterval
        Seconds between progress checks while waiting for the vSAN datastore.

        .PARAMETER ClusterHosts
        Array of VMHost objects in the cluster (used for disk query and datastore wait).

        .PARAMETER ClusterName
        Cluster name; used in error messages and disk queries.

        .PARAMETER DatastoreName
        Name to assign to the vSAN datastore after it appears.

        .PARAMETER DatastoreWaitTimeoutSeconds
        Maximum seconds to wait for the vSAN datastore to appear.

        .PARAMETER LabEnvironment
        When true, bypasses the stale disk claim confirmation prompt and auto-removes without prompting.

        .EXAMPLE
        Invoke-VsanOsaDiskGroupCreation -ClusterName "cl0" -ClusterHosts $clusterHosts -DatastoreName "vsan-ds" -CheckInterval 5 -DatastoreWaitTimeoutSeconds 300

        .NOTES
        Requires a live vCenter connection. Calls Add-VsanOsaDiskToDiskGroup and Wait-ForVsanDatastoreAndRename.
        Write-Host is the primary output mechanism in this function; all Write-Host calls are
        intentional interactive console output. Use Write-LogMessage for diagnostic logging.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [Switch]$AddingToExistingDatastore,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 60)] [Int]$CheckInterval = 5,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object[]]$ClusterHosts,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DatastoreName,
        [Parameter(Mandatory = $false)] [ValidateRange(60, 1800)] [Int]$DatastoreWaitTimeoutSeconds = 300,
        [Parameter(Mandatory = $false)] [Switch]$LabEnvironment
    )

    if ($AddingToExistingDatastore) {
        Write-LogMessage -Type DEBUG -Message "Adding disk groups to existing vSAN datastore `"$DatastoreName`" (no disks attached)."
    } else {
        Write-LogMessage -Type DEBUG -Message "No existing vSAN datastore `"$DatastoreName`" found. Proceeding with disk retrieval and disk group creation."
    }

    if ($Script:VsanOsaEligibleDisksDelaySeconds -gt 0) {
        Write-LogMessage -Type DEBUG -Message "Waiting $($Script:VsanOsaEligibleDisksDelaySeconds) seconds for vSAN on all hosts to be ready before querying eligible disks."
        Start-Sleep -Seconds $Script:VsanOsaEligibleDisksDelaySeconds
    }
    Write-LogMessage -Type DEBUG -Message "Querying cluster hosts (not witness) for vSAN OSA eligible disks: $($ClusterHosts.Count) host(s) ($($ClusterHosts.Name -join ', '))."
    $eligibleDisks = Get-VsanOsaEligibleDisksFromCluster -ClusterName $ClusterName -ClusterHosts $ClusterHosts

    $diskDisplayList = [System.Collections.Generic.List[PSObject]]::new()
    $diskIdCounter = 1
    foreach ($disk in $eligibleDisks) {
        $diskDisplayList.Add([PSCustomObject]@{
            Id            = $diskIdCounter
            VMHostName    = $disk.VMHost.Name
            CanonicalName = $disk.CanonicalName
            CapacityGB    = $disk.CapacityGB
            Model         = $disk.Model
            IsSsd         = Resolve-DiskIsSsdProperty -Disk $disk
            DiskObject    = $disk
        })
        $diskIdCounter++
    }

    # When 2+ hosts are required and some have 0 eligible disks, attempt stale claim resolution.
    if ($ClusterHosts.Count -ge 2) {
        Invoke-VsanOsaStaleDiskClaimResolution -ClusterHosts $ClusterHosts -ClusterName $ClusterName -DiskDisplayList $diskDisplayList -LabEnvironment:$LabEnvironment.IsPresent
    }

    $uniqueHostNames = $diskDisplayList | Select-Object -ExpandProperty VMHostName -Unique

    $selectionByHost = Get-VsanOsaCacheDiskSelectionByHost -DiskDisplayList $diskDisplayList -UniqueHostNames @($uniqueHostNames)

    Invoke-VsanOsaStorageImbalanceWarning -SelectionByHost $selectionByHost -UniqueHostNames @($uniqueHostNames)

    foreach ($disk in $diskDisplayList) {
        $cacheDiskForRole = $selectionByHost[$disk.VMHostName].CacheDisk
        $defaultRole = if ($disk.Id -eq $cacheDiskForRole.Id) { "Cache" } else { "Capacity" }
        Add-Member -InputObject $disk -NotePropertyName "DefaultRole" -NotePropertyValue $defaultRole -Force
    }
    # Write-Host: blank line and table output use Write-Host so the interactive table renders correctly; Write-Output can introduce rendering regression.
    Write-Host ""
    Write-Host "vSAN OSA disks claimed for cluster `"$ClusterName`" (cache/capacity per host):"
    $diskDisplayList | Format-Table -Property Id, VMHostName, CanonicalName, CapacityGB, Model, IsSsd, DefaultRole -AutoSize | Out-Host
    Write-LogMessage -Type INFO -Message "vSAN OSA disk group assignment completed for $($uniqueHostNames.Count) host(s) (default cache/capacity)."

    Add-VsanOsaDiskToDiskGroup -SelectionByHost $selectionByHost

    if ($AddingToExistingDatastore) {
        Write-LogMessage -Type INFO -Message "Successfully added disk groups to existing vSAN datastore `"$DatastoreName`" for cluster `"$ClusterName`"."
    } else {
        Write-LogMessage -Type INFO -Message "Successfully configured vSAN OSA disk groups for all hosts in cluster `"$ClusterName`"."
    }

    Wait-ForVsanDatastoreAndRename `
        -CheckInterval $CheckInterval `
        -ClusterHosts $ClusterHosts `
        -DatastoreName $DatastoreName `
        -TimeoutSeconds $DatastoreWaitTimeoutSeconds
}
function Invoke-VsanOsaWitnessSetup {

    <#
        .SYNOPSIS
        Configures the vSAN OSA witness host and runs the post-witness health check for a cluster.

        .DESCRIPTION
        Checks whether the witness is already configured (idempotency when the datastore is usable).
        When configuration is needed: validates the witness disk group, creates one when absent,
        calls Set-VsanWitness to configure the stretched cluster, and runs
        Invoke-VsanClusterHealthCheckAfterWitness.

        .PARAMETER AcceptBadCheckResults
        When specified, automatically proceeds when vSAN health is red after witness configuration.

        .PARAMETER ClusterHosts
        Array of VMHost objects in the cluster; used to detect whether the witness is a cluster member.

        .PARAMETER ClusterName
        Cluster name; passed to Set-VsanWitness and health check.

        .PARAMETER ExistingDatastoreUsable
        When $true, attempts to skip witness + health check if the witness is already configured.

        .PARAMETER LabEnvironment
        Passed to Set-VsanWitness; suppresses interactive prompts in lab environments.

        .PARAMETER PreferredFaultDomainName
        Required when vSanWitnessVmName is provided; passed to Set-VsanWitness.

        .PARAMETER vSanWitnessVmName
        FQDN or IP of the witness host.

        .EXAMPLE
        Invoke-VsanOsaWitnessSetup -ClusterName "cl0" -ClusterHosts $clusterHosts -vSanWitnessVmName "witness01.example.com" -PreferredFaultDomainName "site1" -LabEnvironment:$false -ExistingDatastoreUsable:$false

        .NOTES
        Throws VcfDeploymentException when PreferredFaultDomainName is not provided, when the witness is
        a member of the cluster, or when Set-VsanWitness fails.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [Switch]$AcceptBadCheckResults,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object[]]$ClusterHosts,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [Switch]$ExistingDatastoreUsable,
        [Parameter(Mandatory = $false)] [Switch]$LabEnvironment,
        [Parameter(Mandatory = $false)] [String]$PreferredFaultDomainName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$vSanWitnessVmName
    )

    if ($ExistingDatastoreUsable) {
        try {
            $vsanConfig = Get-VsanClusterConfiguration -Cluster $ClusterName -Server $Script:vCenterName -ErrorAction SilentlyContinue
            if ($vsanConfig -and $vsanConfig.WitnessHost -and $vsanConfig.WitnessHost.Name -eq $vSanWitnessVmName) {
                Write-LogMessage -Type INFO -Message "vSAN datastore already exists and witness `"$vSanWitnessVmName`" is already configured for cluster `"$ClusterName`". Skipping witness configuration and health check."
                return
            }
        } catch {
            Write-LogMessage -Type DEBUG -Message "Could not check existing vSAN witness configuration for cluster `"$ClusterName`" ($($_.Exception.Message)); proceeding with witness block."
        }
    }

    Write-LogMessage -Type INFO -Message "Configuring vSAN witness for cluster `"$ClusterName`" (witness host: `"$vSanWitnessVmName`")."
    if (-not $PreferredFaultDomainName) {
        $err = "PreferredFaultDomainName is required when vSanWitnessVmName is provided."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }

    $witnessHost = Get-VMHost -Name $vSanWitnessVmName -Server $Script:vCenterName -ErrorAction Stop
    Write-LogMessage -Type DEBUG -Message "Witness host resolved: Name=`"$($witnessHost.Name)`", Id=`"$($witnessHost.Id)`"."

    # Ensure witness host is not in maintenance mode (vSAN witness operations require connected state).
    Set-VMHostConnectedState -VMHost $witnessHost -Server $Script:vCenterName

    $witnessMoRef = if ($witnessHost.PSObject.Properties['ExtensionData'] -and $witnessHost.ExtensionData -and $witnessHost.ExtensionData.MoRef) { $witnessHost.ExtensionData.MoRef.Value } else { $null }
    Write-LogMessage -Type DEBUG -Message "Witness host MoRef.Value=`"$witnessMoRef`". Cluster hosts: $($ClusterHosts.Count) host(s) ($($ClusterHosts.Name -join ', '))."

    $witnessIsInCluster = $witnessMoRef -and (@($ClusterHosts | Where-Object { $_.ExtensionData -and $_.ExtensionData.MoRef -and $_.ExtensionData.MoRef.Value -eq $witnessMoRef }).Count -gt 0)
    if (-not $witnessIsInCluster) {
        $witnessIsInCluster = @($ClusterHosts | Where-Object { $_.Id -eq $witnessHost.Id -or $_.Name -eq $witnessHost.Name }).Count -gt 0
    }
    if ($witnessIsInCluster) {
        $err = "Witness host `"$vSanWitnessVmName`" is a member of cluster `"$ClusterName`". Per the vSAN Stretched Cluster Guide, the witness must not be a member of any cluster. Remove the witness host from the cluster and add it to the data center (or folder) outside the cluster, then re-run."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }

    Write-LogMessage -Type INFO -Message "Checking whether witness host `"$vSanWitnessVmName`" already has a vSAN OSA disk group..."
    # Use HostVsanSystem API so witness is detected even when not in a cluster (Get-VsanDiskGroup requires cluster membership).
    $witnessOsaResult = Get-VsanOsaDiskGroupsOnHost -VMHost $witnessHost -Server $Script:vCenterName
    $hasValidOsaGroup = $witnessOsaResult.HasValidOsaGroup -or ($witnessOsaResult.DiskGroupCount -gt 0)
    Write-LogMessage -Type DEBUG -Message "Witness host disk group check (HostVsanSystem.config): DiskGroupCount=$($witnessOsaResult.DiskGroupCount), HasValidOsaGroup=$($witnessOsaResult.HasValidOsaGroup)."
    if ($hasValidOsaGroup) {
        $statusMsg = if ($witnessOsaResult.HasValidOsaGroup) { "already has a vSAN OSA disk group. Skipping disk group creation." } else { "has $($witnessOsaResult.DiskGroupCount) existing vSAN disk group(s); treating as valid and skipping creation." }
        Write-LogMessage -Type INFO -Message "Witness host `"$vSanWitnessVmName`" $statusMsg"
    }

    # A single witness may be used for many clusters; only create a disk group when the witness has none.
    if (-not $hasValidOsaGroup) {
        Write-LogMessage -Type INFO -Message "No existing witness disk group found. Creating vSAN OSA witness disk group on `"$vSanWitnessVmName`" (automatic cache/capacity selection)."
        Initialize-VsanWitnessDiskGroup -ClusterName $ClusterName -StoragePolicyType "vSAN-OSA" -vSanWitnessVmName $vSanWitnessVmName
    }

    Write-LogMessage -Type DEBUG -Message "Calling Set-VsanWitness for cluster `"$ClusterName`" with PreferredFaultDomainName=`"$PreferredFaultDomainName`", vSanWitnessVmName=`"$vSanWitnessVmName`", StoragePolicyType vSAN-OSA."
    Write-LogMessage -Type INFO -Message "Configuring vSAN witness host for cluster `"$ClusterName`"..."
    Set-VsanWitness -ClusterName $ClusterName -LabEnvironment:$LabEnvironment.IsPresent -PreferredFaultDomainName $PreferredFaultDomainName -StoragePolicyType "vSAN-OSA" -vSanWitnessVmName $vSanWitnessVmName
    Invoke-VsanClusterHealthCheckAfterWitness -AcceptBadCheckResults:$AcceptBadCheckResults.IsPresent -ClusterName $ClusterName -LabEnvironment:$LabEnvironment.IsPresent -StoragePolicyType "vSAN-OSA"
}
function Invoke-VsanOsaClusterHostReadinessChecks {

    <#
        .SYNOPSIS
        Validates that all cluster hosts meet the VMkernel requirements for vSAN OSA disk group creation.

        .DESCRIPTION
        For each host in $ClusterHosts:
        - Clears vSAN traffic from vmk0 when it is set (vmk0 carries management and vSAN witness only; vSAN data uses a dedicated vmk).
        - Verifies at least one VMkernel has vSAN traffic and one has vSAN witness traffic via Test-VmkernelVsanAndWitnessTraffic.
        - Verifies the vSAN-traffic VMkernel has a valid IPv4 or IPv6 address via Test-VsanTrafficVmkernelHasValidIp.
        Throws [VcfDeploymentException] on the first failure.

        .PARAMETER ClusterHosts
        Array of VMHost objects from the cluster.

        .PARAMETER ClusterName
        Display name of the cluster, used in exception messages.

        .EXAMPLE
        Invoke-VsanOsaClusterHostReadinessChecks -ClusterHosts $clusterHosts -ClusterName "cl0-site1"

        .NOTES
        Deployment helper — throws [VcfDeploymentException] on failure. Caller must be inside a top-level
        try/catch that surfaces VcfDeploymentException to the user.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object[]]$ClusterHosts,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName
    )

    foreach ($clusterHost in @($ClusterHosts)) {
        $hostName = $clusterHost.Name
        $vmk0 = Get-VMHostNetworkAdapter -VMHost $clusterHost -VMKernel -Server $Script:vCenterName -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq "vmk0" }
        if ($vmk0 -and $vmk0.PSObject.Properties["VsanTrafficEnabled"] -and $vmk0.VsanTrafficEnabled -eq $true) {
            try {
                Set-VMHostNetworkAdapter -VirtualNic $vmk0 -VsanTrafficEnabled $false -Confirm:$false -WarningAction SilentlyContinue -ErrorAction Stop | Out-Null
                Write-LogMessage -Type INFO -Message "Cleared vSAN traffic from mgmt (vmk0) on host `"$hostName`" (vmk0 is mgmt + vSAN witness only)."
            } catch {
                Write-LogMessage -Type WARNING -Message "Could not clear vSAN from vmk0 on host `"$hostName`": $($_.Exception.Message). Clear manually if needed."
            }
        }
        $vsanCheck = Test-VmkernelVsanAndWitnessTraffic -VMHost $clusterHost
        if (-not $vsanCheck.HasCompliantInterface) {
            $err = "Cluster host `"$hostName`" has no VMkernel with vSAN and vSAN witness traffic enabled. Use vmk2 (or vmk3) for vSAN; vmk0 may carry vSAN witness only."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
        if (-not (Test-VsanTrafficVmkernelHasValidIp -VMHost $clusterHost)) {
            $err = "Cluster host `"$hostName`" has vSAN traffic enabled but the VMkernel has no IPv4 or IPv6 address configured."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
    }
}
function Test-VsanOsaExistingDatastoreIsUsable {

    <#
        .SYNOPSIS
        Checks whether a named vSAN datastore already exists and is fully accessible by all cluster hosts.

        .DESCRIPTION
        Returns a PSCustomObject with:
          IsUsable          — $true when the datastore exists, is of type vsan, has capacity ≥
                              MinCapacityGBForExistingDatastore, and all cluster hosts have access (MoRef comparison).
          IsAddingToExisting — $true when the datastore exists as vsan type but its capacity is below the minimum
                              threshold, indicating disk groups must be created on an existing diskless vSAN datastore.
        Returns @{ IsUsable = $false; IsAddingToExisting = $false } when the datastore is not found or not vSAN type.

        .PARAMETER ClusterHosts
        Array of VMHost objects in the cluster. Used for MoRef-based host access validation.

        .PARAMETER ClusterName
        Display name of the cluster, used in diagnostic log messages.

        .PARAMETER DatastoreName
        Name of the vSAN datastore to check.

        .PARAMETER MinCapacityGBForExistingDatastore
        Minimum capacity in GB for an existing datastore to be considered usable. Default 1.

        .EXAMPLE
        $status = Test-VsanOsaExistingDatastoreIsUsable -ClusterHosts $clusterHosts -ClusterName "cl0" -DatastoreName "ds-site1"

        .NOTES
        Does not throw. Logs INFO and WARNING for each path. All vSAN datastore lookup uses $Script:vCenterName.
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object[]]$ClusterHosts,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DatastoreName,
        [Parameter(Mandatory = $false)] [Double]$MinCapacityGBForExistingDatastore = 1
    )

    $result = [PSCustomObject]@{ IsUsable = $false; IsAddingToExisting = $false }
    Write-LogMessage -Type DEBUG -Message "Checking if vSAN datastore `"$DatastoreName`" already exists for cluster `"$ClusterName`"."
    $existingDatastore = Get-Datastore -Name $DatastoreName -Server $Script:vCenterName -ErrorAction SilentlyContinue
    if (-not $existingDatastore -or $existingDatastore.Type -ne "vsan") {
        return $result
    }
    $capacityGB = 0
    if ($null -ne $existingDatastore.CapacityGB) {
        $rawCapacity = $existingDatastore.CapacityGB
        if ($rawCapacity -is [double] -or $rawCapacity -is [int] -or $rawCapacity -is [long]) {
            $capacityGB = [Double]$rawCapacity
        } else {
            $parsed = 0.0
            if ([Double]::TryParse([String]$rawCapacity, [System.Globalization.NumberStyles]::Any, [System.Globalization.CultureInfo]::InvariantCulture, [Ref]$parsed)) {
                $capacityGB = $parsed
            }
        }
    }
    if ($capacityGB -lt $MinCapacityGBForExistingDatastore) {
        Write-LogMessage -Type INFO -Message "vSAN datastore `"$DatastoreName`" exists but has no disks attached (capacity: $capacityGB GB). Proceeding with disk retrieval and disk group creation."
        $result.IsAddingToExisting = $true
        return $result
    }
    $clusterHostMoRefValues = $ClusterHosts | ForEach-Object { $_.ExtensionData.MoRef.Value }
    $datastoreHostIds = $existingDatastore.ExtensionData.Host | Select-Object -ExpandProperty Key | Select-Object -ExpandProperty Value
    $allHostsHaveAccess = $true
    foreach ($hostMoRefValue in $clusterHostMoRefValues) {
        if ($datastoreHostIds -notcontains $hostMoRefValue) {
            $allHostsHaveAccess = $false
            break
        }
    }
    if ($allHostsHaveAccess) {
        Write-LogMessage -Type INFO -Message "vSAN datastore `"$DatastoreName`" already exists with capacity $([Math]::Round($capacityGB, 2)) GB and is accessible by all cluster hosts. Skipping disk retrieval and disk group creation."
        $result.IsUsable = $true
    } else {
        Write-LogMessage -Type WARNING -Message "vSAN datastore `"$DatastoreName`" exists but is not accessible by all cluster hosts. Proceeding with disk retrieval and disk group creation."
    }
    return $result
}
function Add-VsanOsaDiskGroupToCluster {

    <#
        .SYNOPSIS
        Automatically assigns cache and capacity disks and creates vSAN OSA disk groups for each host in a cluster.

        .DESCRIPTION
        Retrieves vSAN OSA eligible disks, assigns cache (smallest SSD per host) and capacity (rest) automatically,
        creates disk groups with New-VsanDiskGroup, waits for the vSAN datastore and renames it,
        then optionally configures the vSAN witness and runs a health check. Mirrors the flow of
        Add-VsanEsaStoragePoolDisk for OSA (Original Storage Architecture).

        .PARAMETER AcceptBadCheckResults
        When specified, automatically proceed when vSAN cluster health is red after witness (no Y/N prompt).

        .PARAMETER CheckInterval
        Interval in seconds between progress checks. Default is 5 seconds.

        .PARAMETER ClusterName
        The name of the cluster for which to configure vSAN OSA disk groups.

        .PARAMETER DatastoreName
        The name to use for the vSAN datastore.

        .PARAMETER DatastoreWaitTimeoutSeconds
        Maximum time in seconds to wait for vSAN datastore to appear. Default is 300.

        .PARAMETER MinCapacityGBForExistingDatastore
        Minimum capacity in GB for an existing vSAN datastore to be considered usable. Default is 1.

        .PARAMETER PreferredFaultDomainName
        Optional. Required if vSanWitnessVmName is provided (e.g. edge site name).

        .PARAMETER vSanWitnessVmName
        Optional. FQDN or IP of the vSAN witness host. If provided, witness is configured after the datastore is ready.

        .PARAMETER LabEnvironment
        When $true (e.g. common.labenvironment is true), silences only controlleronhcl, advcfgsync, and controllerdiskmode vSAN health checks before the post-witness health check.

        .EXAMPLE
        Add-VsanOsaDiskGroupToCluster -ClusterName "MyCluster" -DatastoreName "datastore-site1"

        .NOTES
        Requires vCenter connection. Uses Get-VsanOsaEligibleDisksFromCluster (HostVsanSystem.QueryDisksForVsan API) and New-VsanDiskGroup (VCF PowerCLI).
        Cluster hosts and the witness host (if specified) are checked for maintenance mode; any host in maintenance mode
        is set to connected state via Set-VMHostConnectedState before disk group or witness operations.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [Switch]$AcceptBadCheckResults,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 60)] [Int]$CheckInterval = 5,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DatastoreName,
        [Parameter(Mandatory = $false)] [ValidateRange(60, 1800)] [Int]$DatastoreWaitTimeoutSeconds = 300,
        [Parameter(Mandatory = $false)] [Switch]$LabEnvironment,
        [Parameter(Mandatory = $false)] [ValidateRange(0, 10000)] [Double]$MinCapacityGBForExistingDatastore = 1,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$PreferredFaultDomainName,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$vSanWitnessVmName
    )

    Write-LogMessage -Type DEBUG -Message "Entered Add-VsanOsaDiskGroupToCluster for cluster: `"$ClusterName`"."

    Assert-VcenterConnected

    try {
        $clusterObject = Get-ClusterByName -Name $ClusterName -Server $Script:vCenterName
        if (-not $clusterObject) {
            throw [VcfDeploymentException]::new("Cluster `"$ClusterName`" not found in vCenter `"$Script:vCenterName`".")
        }
        $clusterHosts = Get-VMHost -Location $clusterObject -Server $Script:vCenterName -ErrorAction Stop

        if (-not $clusterHosts -or $clusterHosts.Count -eq 0) {
            $err = "Cluster `"$ClusterName`" does not contain any hosts."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }

        # Ensure no cluster host is in maintenance mode (vSAN disk group operations require connected state).
        foreach ($clusterHost in @($clusterHosts)) {
            Set-VMHostConnectedState -VMHost $clusterHost -Server $Script:vCenterName
        }

        Invoke-VsanOsaClusterHostReadinessChecks -ClusterHosts $clusterHosts -ClusterName $ClusterName

        # vSAN config sync (rebalance + reapply) is done once in the main deployment flow before calling this function.
        $datastoreStatus = Test-VsanOsaExistingDatastoreIsUsable `
            -ClusterHosts $clusterHosts `
            -ClusterName $ClusterName `
            -DatastoreName $DatastoreName `
            -MinCapacityGBForExistingDatastore $MinCapacityGBForExistingDatastore

        if (-not $datastoreStatus.IsUsable) {
            Invoke-VsanOsaDiskGroupCreation `
                -AddingToExistingDatastore:$datastoreStatus.IsAddingToExisting `
                -CheckInterval $CheckInterval `
                -ClusterHosts $clusterHosts `
                -ClusterName $ClusterName `
                -DatastoreName $DatastoreName `
                -DatastoreWaitTimeoutSeconds $DatastoreWaitTimeoutSeconds `
                -LabEnvironment:$LabEnvironment.IsPresent
        }

        if ($vSanWitnessVmName) {
            Invoke-VsanOsaWitnessSetup `
                -AcceptBadCheckResults:$AcceptBadCheckResults.IsPresent `
                -ClusterHosts $clusterHosts `
                -ClusterName $ClusterName `
                -ExistingDatastoreUsable:$datastoreStatus.IsUsable `
                -LabEnvironment:$LabEnvironment.IsPresent `
                -PreferredFaultDomainName $PreferredFaultDomainName `
                -vSanWitnessVmName $vSanWitnessVmName
        }
        Enable-VsanPerformanceService -ClusterName $ClusterName
    }
    catch {
        if ($_.Exception.Message -match "Deployment cancelled by user" -or $_.Exception.Message -match "^Deployment failed\.") {
            throw
        }
        $errorMessage = $_.Exception.Message
        if ($_.Exception.InnerException) {
            Write-LogMessage -Type DEBUG -Message "Inner exception: $($_.Exception.InnerException.Message)"
            $errorMessage = $_.Exception.InnerException.Message
        }
        $reasonPrefix = switch ($_.Exception.GetType().Name) {
            'UnauthorizedAccessException' { "authorization error. " }
            'TimeoutException'            { "network/timeout. " }
            default                       { "" }
        }
        $reason = Get-CleanVsanErrorMessage -ErrorMessage $errorMessage
        if ($reason -eq $errorMessage) { $reason = "$reasonPrefix$errorMessage" }
        $cleanMessage = "Failed to configure vSAN OSA datastore for cluster `"$ClusterName`". Reason: $reason"
        Write-LogMessage -Type ERROR -Message $cleanMessage
        throw [VcfDeploymentException]::new("Deployment failed. $cleanMessage")
    }
}
function Get-VsanDatastoreCapacityGB {

    <#
        .SYNOPSIS
        Parses the CapacityGB property of a datastore object into a double.

        .DESCRIPTION
        Handles double, int, long, or string values that vCenter may return for CapacityGB.
        Returns 0.0 when the value is null or cannot be parsed.

        .PARAMETER Datastore
        The datastore object whose CapacityGB property is to be parsed.

        .EXAMPLE
        $capacityGB = Get-VsanDatastoreCapacityGB -Datastore $existingDatastore
    #>

    [CmdletBinding()]
    [OutputType([Double])]
    Param (
        [Parameter(Mandatory = $true)] [Object]$Datastore
    )

    if ($null -eq $Datastore -or $null -eq $Datastore.CapacityGB) { return 0.0 }
    $raw = $Datastore.CapacityGB
    if ($raw -is [double] -or $raw -is [int] -or $raw -is [long]) { return [Double]$raw }
    $parsed = 0.0
    if ([Double]::TryParse([String]$raw, [System.Globalization.NumberStyles]::Any, [System.Globalization.CultureInfo]::InvariantCulture, [Ref]$parsed)) {
        return $parsed
    }
    return 0.0
}
function Test-VsanEsaDatastoreUsability {

    <#
        .SYNOPSIS
        Determines whether an existing vSAN ESA datastore is fully usable or has no disks attached.

        .DESCRIPTION
        Fetches the named datastore from vCenter and classifies its state into one of three outcomes:
        IsUsable (fully provisioned, all hosts have access), IsAddingToExisting (exists but no disks),
        or neither (absent, non-vSAN, or not accessible by all cluster hosts).

        .PARAMETER ClusterHosts
        Host objects for all hosts in the cluster.

        .PARAMETER DatastoreName
        Name of the vSAN datastore to evaluate.

        .PARAMETER MinCapacityGBForExistingDatastore
        Minimum capacity in GB for the datastore to be considered usable. Default is 1.

        .PARAMETER Server
        vCenter server name.

        .EXAMPLE
        $dsStatus = Test-VsanEsaDatastoreUsability -DatastoreName "ds-site1" -ClusterHosts $hosts -Server "vc.lab"
        if ($dsStatus.IsUsable) { Write-Output "Already provisioned." }
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [Object[]]$ClusterHosts,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DatastoreName,
        [Parameter(Mandatory = $false)] [Double]$MinCapacityGBForExistingDatastore = 1,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Server
    )

    $result = [PSCustomObject]@{ IsUsable = $false; IsAddingToExisting = $false; Datastore = $null }
    Write-LogMessage -Type DEBUG -Message "Checking if vSAN datastore `"$DatastoreName`" already exists for cluster disk provisioning."
    $ds = Get-Datastore -Name $DatastoreName -Server $Server -ErrorAction SilentlyContinue
    $result.Datastore = $ds
    if (-not $ds -or $ds.Type -ne "vsan") { return $result }
    $capacityGB = Get-VsanDatastoreCapacityGB -Datastore $ds
    if ($capacityGB -lt $MinCapacityGBForExistingDatastore) {
        Write-LogMessage -Type INFO -Message "vSAN datastore `"$DatastoreName`" exists but has no disks attached (capacity: $capacityGB GB). Proceeding with disk retrieval and addition."
        $result.IsAddingToExisting = $true
        return $result
    }
    $clusterHostMoRefValues = $ClusterHosts | ForEach-Object { $_.ExtensionData.MoRef.Value }
    $dsHostIds = $ds.ExtensionData.Host | Select-Object -ExpandProperty Key | Select-Object -ExpandProperty Value
    $allHostsHaveAccess = -not ($clusterHostMoRefValues | Where-Object { $dsHostIds -notcontains $_ })
    if ($allHostsHaveAccess) {
        Write-LogMessage -Type INFO -Message "vSAN datastore `"$DatastoreName`" already exists with capacity $([Math]::Round($capacityGB, 2)) GB and is accessible by all cluster hosts. Skipping vSAN steps."
        $result.IsUsable = $true
    } else {
        Write-LogMessage -Type WARNING -Message "vSAN datastore `"$DatastoreName`" exists but is not accessible by all cluster hosts. Proceeding with disk retrieval and addition."
    }
    return $result
}
function Test-VsanEsaStorageImbalance {

    <#
        .SYNOPSIS
        Logs a warning when data hosts contributing vSAN ESA storage differ by more than a threshold.

        .DESCRIPTION
        Computes the total disk capacity per host from the grouped disk map and emits a WARNING if
        (max - min) / min exceeds StorageImbalanceThresholdPercent. An uneven distribution risks
        vSAN hotspots after initial provisioning.

        .PARAMETER DisksByHost
        Hashtable of host name to list of disk objects (each with a CapacityGB property).

        .PARAMETER StorageImbalanceThresholdPercent
        Percentage threshold above which a warning is emitted. Default is 1.

        .EXAMPLE
        Test-VsanEsaStorageImbalance -DisksByHost $selectedDisksByHost
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [Hashtable]$DisksByHost,
        [Parameter(Mandatory = $false)] [ValidateRange(0, 100)] [Double]$StorageImbalanceThresholdPercent = 1
    )

    $capacityByHost = @{}
    foreach ($hostName in $DisksByHost.Keys) {
        $totalGB = 0.0
        foreach ($disk in $DisksByHost[$hostName]) {
            if ($null -ne $disk.PSObject.Properties["CapacityGB"] -and $null -ne $disk.CapacityGB) {
                if ($disk.CapacityGB -is [double] -or $disk.CapacityGB -is [int] -or $disk.CapacityGB -is [long]) {
                    $totalGB += [Double]$disk.CapacityGB
                } else {
                    $parsed = 0.0
                    if ([Double]::TryParse([String]$disk.CapacityGB, [System.Globalization.NumberStyles]::Any, [System.Globalization.CultureInfo]::InvariantCulture, [Ref]$parsed)) {
                        $totalGB += $parsed
                    }
                }
            }
        }
        $capacityByHost[$hostName] = $totalGB
    }
    if ($capacityByHost.Count -lt 2) { return }
    $capValues = @($capacityByHost.Values | Where-Object { $_ -ge 0 })
    $minCap = if ($capValues.Count -gt 0) { ($capValues | Measure-Object -Minimum).Minimum } else { 0 }
    $maxCap = if ($capValues.Count -gt 0) { ($capValues | Measure-Object -Maximum).Maximum } else { 0 }
    if ($minCap -gt 0 -and $maxCap -gt $minCap) {
        $ratio = ($maxCap - $minCap) / $minCap
        if ($ratio -gt ($StorageImbalanceThresholdPercent / 100.0)) {
            $capacityList = ($capacityByHost.GetEnumerator() | Sort-Object -Property Name | ForEach-Object { "`"$($_.Key)`": $([Math]::Round($_.Value, 2)) GB" }) -join "; "
            Write-LogMessage -Type WARNING -Message "vSAN ESA: data host storage totals differ by more than $StorageImbalanceThresholdPercent%. Capacity per host (GB): $capacityList."
        }
    }
}
function Invoke-VsanEsaStaleClaimRemediation {

    <#
    .SYNOPSIS
        Detects and optionally removes stale vSAN ESA storage pool disk claims blocking disk eligibility.
    .DESCRIPTION
        For each host listed in HostsMissing, queries for stale storage-pool disks from a prior
        deployment. If any are found, prompts the operator (or auto-proceeds in LabEnvironment) to
        remove them, then re-queries eligibility and appends newly eligible disks to DiskDisplayList.
        Throws VcfDeploymentException when no stale claims are found but disks are still missing, when
        the operator declines cleanup, or when disks are still missing after cleanup.
    .PARAMETER CheckInterval
        Seconds to wait after removing claims before re-querying eligibility.
    .PARAMETER ClusterHosts
        All hosts in the cluster.
    .PARAMETER ClusterName
        Cluster name, passed to Get-VsanEsaEligibleDisksFromCluster.
    .PARAMETER DiskDisplayList
        Mutable Generic List receiving newly discovered eligible disk rows.
    .PARAMETER DiskIdCounterRef
        Reference to the running disk ID counter, incremented for each new row added.
    .PARAMETER DiskRetrievalTimeoutSeconds
        Timeout for the re-query call.
    .PARAMETER HostsMissing
        Array of host names with no eligible disks yet.
    .PARAMETER LabEnvironment
        When set, stale claims are removed automatically without prompting.
    .EXAMPLE
        Invoke-VsanEsaStaleClaimRemediation -CheckInterval 15 -ClusterHosts $hosts -ClusterName "cl1" -DiskDisplayList $list -DiskIdCounterRef ([Ref]$counter) -DiskRetrievalTimeoutSeconds 120 -HostsMissing $missing -LabEnvironment:$true
    .NOTES
        Uses $Script:vCenterName. Throws VcfDeploymentException on unrecoverable state.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateRange(1, 300)] [Int]$CheckInterval,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object[]]$ClusterHosts,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [System.Collections.Generic.List[PSObject]]$DiskDisplayList,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Ref]$DiskIdCounterRef,
        [Parameter(Mandatory = $true)] [ValidateRange(1, 3600)] [Int]$DiskRetrievalTimeoutSeconds,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [String[]]$HostsMissing,
        [Parameter(Mandatory = $false)] [Switch]$LabEnvironment
    )

    $hostsWithStaleClaims = [System.Collections.Generic.List[PSObject]]::new()
    foreach ($missingHostName in $HostsMissing) {
        $missingHostObj = $ClusterHosts | Where-Object { $_.Name -eq $missingHostName } | Select-Object -First 1
        if (-not $missingHostObj) { continue }
        $stalePoolDisks = @(Get-VsanStoragePoolDisk -VMHost $missingHostObj -Server $Script:vCenterName -ErrorAction SilentlyContinue)
        if ($stalePoolDisks.Count -gt 0) {
            $hostsWithStaleClaims.Add([PSCustomObject]@{ Host = $missingHostObj; HostName = $missingHostName; PoolDiskCount = $stalePoolDisks.Count })
            Write-LogMessage -Type WARNING -Message "Host `"$missingHostName`" has $($stalePoolDisks.Count) stale vSAN ESA storage pool disk(s) from a prior deployment. These must be removed to free the disks."
        }
    }

    if ($hostsWithStaleClaims.Count -eq 0) {
        $err = "vSAN ESA auto-claim requires eligible disks from every data host. Host(s) with no eligible disks: $($HostsMissing -join ', '). Run -CleanUp Compute first or ensure each host has unused disks visible to vSAN."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }

    $staleHostList = ($hostsWithStaleClaims | ForEach-Object { "`"$($_.HostName)`" ($($_.PoolDiskCount) pool disk(s))" }) -join ", "
    $shouldCleanup = $false
    if ($LabEnvironment) {
        Write-LogMessage -Type WARNING -Message "Lab environment: auto-removing stale vSAN ESA disk claims on $staleHostList without prompting."
        $shouldCleanup = $true
    } else {
        Write-LogMessage -Type WARNING -Message "Stale vSAN ESA storage pool disk(s) found on: $staleHostList. Remove these to free disks for this deployment."
        # Write-Host: interactive deployment prompt — cannot use Write-LogMessage here as prompts require direct console interaction.
        Write-Host ""
        $promptAnswer = Read-Host "Remove stale disk claims on these host(s) and continue? (Y=yes / N=no, abort deployment)"
        $shouldCleanup = ($promptAnswer -match '^[Yy]')
    }

    if (-not $shouldCleanup) {
        Write-LogMessage -Type INFO -Message "User chose not to remove stale disk claims. Aborting deployment."
        throw [VcfDeploymentException]::new("Deployment aborted. Stale vSAN ESA disk claims on $($hostsWithStaleClaims.Count) host(s) must be removed before deployment can proceed.")
    }

    foreach ($staleEntry in $hostsWithStaleClaims) {
        Write-LogMessage -Type INFO -Message "Removing stale vSAN ESA disk claims from host `"$($staleEntry.HostName)`"..."
        try {
            Remove-VsanDiskClaimsFromHost -StoragePolicyType "vSAN-ESA" -VMHost $staleEntry.Host
        } catch {
            Write-LogMessage -Type WARNING -Message "Stale disk claim removal on `"$($staleEntry.HostName)`" had errors (non-fatal, will re-check eligibility): $($_.Exception.Message)."
        }
    }
    Write-LogMessage -Type DEBUG -Message "Waiting $CheckInterval seconds for disk claims to clear on host(s): $(($hostsWithStaleClaims | Select-Object -ExpandProperty HostName) -join ', ')."
    Start-Sleep -Seconds $CheckInterval

    $cleanedHostObjs = @($hostsWithStaleClaims | Select-Object -ExpandProperty Host)
    Write-LogMessage -Type DEBUG -Message "Re-querying vSAN ESA eligible disks from $($cleanedHostObjs.Count) cleaned host(s): $(($hostsWithStaleClaims | Select-Object -ExpandProperty HostName) -join ', ')."
    $requeried = @(Get-VsanEsaEligibleDisksFromCluster -ClusterName $ClusterName -ClusterHosts $cleanedHostObjs -TimeoutSeconds $DiskRetrievalTimeoutSeconds -CheckInterval $CheckInterval)
    foreach ($disk in $requeried) {
        $DiskDisplayList.Add([PSCustomObject]@{
            Id            = $DiskIdCounterRef.Value
            VMHostName    = $disk.VMHost.Name
            CanonicalName = $disk.CanonicalName
            CapacityGB    = $disk.CapacityGB
            Model         = $disk.Model
            DiskObject    = $disk
        })
        $DiskIdCounterRef.Value++
    }

    $hostsWithDisks = @($DiskDisplayList | Select-Object -ExpandProperty VMHostName -Unique)
    $stillMissing = @($ClusterHosts | Where-Object { $hostsWithDisks -notcontains $_.Name } | Select-Object -ExpandProperty Name)
    if ($stillMissing.Count -gt 0) {
        $err = "vSAN ESA auto-claim requires eligible disks from every data host. After stale disk claim removal, the following host(s) still have no eligible disks: $($stillMissing -join ', '). Ensure each host has unused disks visible to vSAN."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
    Write-LogMessage -Type INFO -Message "Stale disk claims removed. All $($ClusterHosts.Count) host(s) now have eligible disks."
}
function Get-VsanEsaSelectedDisksByHost {

    <#
        .SYNOPSIS
        Retrieves eligible vSAN ESA disks for a cluster, validates per-host coverage, displays the
        disk table, and returns the disks grouped by host.

        .DESCRIPTION
        Calls Get-VsanEsaEligibleDisksFromCluster and validates that every data host (when there are
        two or more) contributes at least one eligible disk. Displays a formatted disk table and logs a
        warning when host storage totals are unequal beyond the default threshold.

        .PARAMETER CheckInterval
        Polling interval in seconds for disk retrieval. Default 5.

        .PARAMETER ClusterHosts
        VMHost objects for all hosts in the cluster.

        .PARAMETER ClusterName
        Name of the cluster.

        .PARAMETER DiskRetrievalTimeoutSeconds
        Maximum seconds to wait for disk retrieval. Default 900.

        .PARAMETER LabEnvironment
        When true, bypasses the stale disk claim confirmation prompt and auto-removes without prompting.

        .EXAMPLE
        $disksByHost = Get-VsanEsaSelectedDisksByHost -ClusterName "site1" -ClusterHosts $hosts

        .NOTES
        Write-Host is the primary output mechanism in this function; all Write-Host calls are
        intentional interactive console output. Use Write-LogMessage for diagnostic logging.
    #>

    [CmdletBinding()]
    [OutputType([Hashtable])]
    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(1, 60)] [Int]$CheckInterval = 5,
        [Parameter(Mandatory = $true)] [Object[]]$ClusterHosts,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [ValidateRange(60, 3600)] [Int]$DiskRetrievalTimeoutSeconds = 900,
        [Parameter(Mandatory = $false)] [Switch]$LabEnvironment
    )

    $eligibleDisks = Get-VsanEsaEligibleDisksFromCluster `
        -ClusterName $ClusterName `
        -ClusterHosts $ClusterHosts `
        -TimeoutSeconds $DiskRetrievalTimeoutSeconds `
        -CheckInterval $CheckInterval
    $diskDisplayList = [System.Collections.Generic.List[PSObject]]::new()
    $diskIdCounter = 1
    foreach ($disk in $eligibleDisks) {
        $diskDisplayList.Add([PSCustomObject]@{
            Id            = $diskIdCounter
            VMHostName    = $disk.VMHost.Name
            CanonicalName = $disk.CanonicalName
            CapacityGB    = $disk.CapacityGB
            Model         = $disk.Model
            DiskObject    = $disk
        })
        $diskIdCounter++
    }
    if ($ClusterHosts.Count -ge 2) {
        $hostsWithDisks = @($diskDisplayList | Select-Object -ExpandProperty VMHostName -Unique)
        $hostsMissing = @($ClusterHosts | Where-Object { $hostsWithDisks -notcontains $_.Name } | Select-Object -ExpandProperty Name)
        if ($hostsMissing.Count -gt 0) {
            Invoke-VsanEsaStaleClaimRemediation `
                -CheckInterval $CheckInterval `
                -ClusterHosts $ClusterHosts `
                -ClusterName $ClusterName `
                -DiskDisplayList $diskDisplayList `
                -DiskIdCounterRef ([Ref]$diskIdCounter) `
                -DiskRetrievalTimeoutSeconds $DiskRetrievalTimeoutSeconds `
                -HostsMissing $hostsMissing `
                -LabEnvironment:$LabEnvironment.IsPresent
        }
    }
    # Write-Host: blank line and table output use Write-Host so the interactive table renders correctly; Write-Output can introduce rendering regression.
    Write-Host ""
    Write-Host "vSAN ESA disks claimed for cluster `"$ClusterName`":"
    $diskDisplayList | Format-Table -Property Id, VMHostName, CanonicalName, CapacityGB, Model -AutoSize | Out-Host
    Write-LogMessage -Type INFO -Message "vSAN ESA storage pool: all $($diskDisplayList.Count) eligible disk(s) will be added."
    $selectedDisksByHost = Group-DisksByHost -Disks @($diskDisplayList)
    Test-VsanEsaStorageImbalance -DisksByHost $selectedDisksByHost
    return $selectedDisksByHost
}
function Invoke-VsanEsaConfigAndDiskAdd {

    <#
        .SYNOPSIS
        Re-applies the vSAN cluster configuration, waits for advanced config sync, adds disks to
        storage pools, and waits for the datastore to appear or gain capacity.

        .DESCRIPTION
        Sequences the mandatory steps immediately before and after Add-VsanEsaDiskToStoragePool:
        config re-apply, advCfgSync wait, disk addition, and datastore-appearance wait. Separating
        these from disk selection allows retry logic to target only the addition phase.

        .PARAMETER CheckInterval
        Polling interval in seconds. Default 5.

        .PARAMETER ClusterHosts
        VMHost objects for all hosts in the cluster.

        .PARAMETER ClusterName
        Name of the cluster.

        .PARAMETER DatastoreName
        Name to assign to the vSAN datastore.

        .PARAMETER DatastoreWaitTimeoutSeconds
        Seconds to wait for the datastore to appear. Default 300.

        .PARAMETER DisksByHost
        Hashtable of host name to disk list, as returned by Get-VsanEsaSelectedDisksByHost.

        .PARAMETER IsAddingToExisting
        When true, the datastore already exists with no disks; log message is adjusted accordingly.

        .PARAMETER VsAdvCfgSyncWaitTimeoutSeconds
        Seconds to wait for advCfgSync. Set 0 to skip. Default 180.

        .EXAMPLE
        Invoke-VsanEsaConfigAndDiskAdd -ClusterName "site1" -DisksByHost $disksByHost -DatastoreName "ds-site1" -IsAddingToExisting:$false -ClusterHosts $hosts
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(1, 60)] [Int]$CheckInterval = 5,
        [Parameter(Mandatory = $true)] [Object[]]$ClusterHosts,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DatastoreName,
        [Parameter(Mandatory = $false)] [ValidateRange(60, 3600)] [Int]$DatastoreWaitTimeoutSeconds = 300,
        [Parameter(Mandatory = $true)] [Hashtable]$DisksByHost,
        [Parameter(Mandatory = $false)] [Switch]$IsAddingToExisting,
        [Parameter(Mandatory = $false)] [ValidateRange(0, 600)] [Int]$VsAdvCfgSyncWaitTimeoutSeconds = 180
    )

    if ($VsAdvCfgSyncWaitTimeoutSeconds -gt 0) {
        Write-LogMessage -Type INFO -Message "Preparing hosts for vSAN ESA storage pool disk claim: re-applying vSAN cluster configuration and waiting up to $VsAdvCfgSyncWaitTimeoutSeconds second(s) for advanced config sync on cluster `"$ClusterName`"."
        Invoke-VsanClusterConfigReapply -ClusterName $ClusterName | Out-Null
        $null = Wait-VsanClusterConfigSyncOrTimeout -CheckIntervalSeconds 15 -ClusterName $ClusterName -TimeoutSeconds $VsAdvCfgSyncWaitTimeoutSeconds
    }
    Add-VsanEsaDiskToStoragePool -DisksByHost $DisksByHost
    if ($IsAddingToExisting) {
        Write-LogMessage -Type INFO -Message "Successfully added disks to existing vSAN datastore `"$DatastoreName`" for cluster `"$ClusterName`"."
    } else {
        Write-LogMessage -Type INFO -Message "Successfully configured vSAN ESA datastore for all hosts in cluster `"$ClusterName`"."
    }
    Wait-ForVsanDatastoreAndRename `
        -CheckInterval $CheckInterval `
        -ClusterHosts $ClusterHosts `
        -DatastoreName $DatastoreName `
        -TimeoutSeconds $DatastoreWaitTimeoutSeconds
}
function Invoke-VsanEsaDiskWorkflow {

    <#
        .SYNOPSIS
        Orchestrates eligible disk retrieval, storage pool addition, and datastore setup for a cluster.

        .DESCRIPTION
        Called when the vSAN datastore is absent or not fully provisioned. Re-classifies the
        datastore state (in case it changed since the initial usability test), retrieves and validates
        eligible disks, adds them to storage pools, and waits for the datastore to become available.

        .PARAMETER CheckInterval
        Polling interval in seconds. Default 5.

        .PARAMETER ClusterHosts
        VMHost objects for all hosts in the cluster.

        .PARAMETER ClusterName
        Name of the cluster.

        .PARAMETER DatastoreName
        Name for the vSAN datastore.

        .PARAMETER DatastoreWaitTimeoutSeconds
        Seconds to wait for the vSAN datastore to appear. Default 300.

        .PARAMETER DiskRetrievalTimeoutSeconds
        Seconds to wait for eligible disk retrieval. Default 900.

        .PARAMETER InitialDatastore
        Datastore object returned by the initial usability check (may be null).

        .PARAMETER InitialIsAddingToExisting
        Whether the initial usability check flagged the datastore as needing disks added.

        .PARAMETER MinCapacityGBForExistingDatastore
        Minimum capacity in GB for the datastore to be considered usable. Default 1.

        .PARAMETER Server
        vCenter server name.

        .PARAMETER LabEnvironment
        When true, bypasses the stale disk claim confirmation prompt and auto-removes without prompting.

        .PARAMETER VsAdvCfgSyncWaitTimeoutSeconds
        Seconds to wait for vSAN advCfgSync. Set 0 to skip. Default 180.

        .EXAMPLE
        Invoke-VsanEsaDiskWorkflow -ClusterName "site1" -ClusterHosts $hosts -DatastoreName "ds-site1" -InitialDatastore $null -InitialIsAddingToExisting:$false -Server "vc.lab"
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(1, 60)] [Int]$CheckInterval = 5,
        [Parameter(Mandatory = $true)] [Object[]]$ClusterHosts,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DatastoreName,
        [Parameter(Mandatory = $false)] [ValidateRange(60, 3600)] [Int]$DatastoreWaitTimeoutSeconds = 300,
        [Parameter(Mandatory = $false)] [ValidateRange(60, 3600)] [Int]$DiskRetrievalTimeoutSeconds = 900,
        [Parameter(Mandatory = $false)] [Object]$InitialDatastore,
        [Parameter(Mandatory = $false)] [Switch]$InitialIsAddingToExisting,
        [Parameter(Mandatory = $false)] [Switch]$LabEnvironment,
        [Parameter(Mandatory = $false)] [Double]$MinCapacityGBForExistingDatastore = 1,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Server,
        [Parameter(Mandatory = $false)] [ValidateRange(0, 600)] [Int]$VsAdvCfgSyncWaitTimeoutSeconds = 180
    )

    $addingDisksToExistingDatastore = $InitialIsAddingToExisting.IsPresent
    $existingDatastore = $InitialDatastore

    # Re-fetch the datastore when the initial check found none, in case it was created since.
    if (-not $existingDatastore) {
        $existingDatastore = Get-Datastore -Name $DatastoreName -Server $Server -ErrorAction SilentlyContinue
    }
    # Re-classify the datastore as "adding to existing" when it exists as vSAN with low capacity
    # but was not flagged that way by the initial check (e.g. access check ran first).
    if ($existingDatastore -and $existingDatastore.Type -eq "vsan" -and -not $addingDisksToExistingDatastore) {
        $capacityGB = Get-VsanDatastoreCapacityGB -Datastore $existingDatastore
        if ($capacityGB -lt $MinCapacityGBForExistingDatastore) {
            $addingDisksToExistingDatastore = $true
        }
    }
    if ($addingDisksToExistingDatastore) {
        Write-LogMessage -Type DEBUG -Message "Adding disks to existing vSAN datastore `"$DatastoreName`" (no disks attached)."
    } else {
        Write-LogMessage -Type DEBUG -Message "No fully usable vSAN datastore `"$DatastoreName`" found. Proceeding with disk retrieval and addition."
    }
    $disksByHost = Get-VsanEsaSelectedDisksByHost `
        -CheckInterval $CheckInterval `
        -ClusterHosts $ClusterHosts `
        -ClusterName $ClusterName `
        -DiskRetrievalTimeoutSeconds $DiskRetrievalTimeoutSeconds `
        -LabEnvironment:$LabEnvironment.IsPresent
    Invoke-VsanEsaConfigAndDiskAdd `
        -CheckInterval $CheckInterval `
        -ClusterHosts $ClusterHosts `
        -ClusterName $ClusterName `
        -DatastoreName $DatastoreName `
        -DatastoreWaitTimeoutSeconds $DatastoreWaitTimeoutSeconds `
        -DisksByHost $disksByHost `
        -IsAddingToExisting:$addingDisksToExistingDatastore `
        -VsAdvCfgSyncWaitTimeoutSeconds $VsAdvCfgSyncWaitTimeoutSeconds
}
function Invoke-VsanEsaWitnessSetup {

    <#
        .SYNOPSIS
        Configures a vSAN witness host for a cluster and runs the post-witness health check.

        .DESCRIPTION
        When the datastore was already usable before this call, first checks whether the witness is
        already configured and skips silently if so. Otherwise, validates PreferredFaultDomainName,
        calls Set-VsanWitness, and triggers the health check.

        .PARAMETER AcceptBadCheckResults
        When specified, bypasses the health check prompt even when the cluster is in a red state.

        .PARAMETER ClusterName
        Name of the cluster.

        .PARAMETER ExistingDatastoreUsable
        True when the datastore was already provisioned before entering this function.

        .PARAMETER LabEnvironment
        When true, silences non-critical vSAN health checks.

        .PARAMETER PreferredFaultDomainName
        Required when configuring the witness. Typically the edge-site name.

        .PARAMETER Server
        vCenter server name.

        .PARAMETER vSanWitnessVmName
        FQDN or IP address of the vSAN witness VM.

        .EXAMPLE
        Invoke-VsanEsaWitnessSetup -ClusterName "site1" -ExistingDatastoreUsable -LabEnvironment:$false -PreferredFaultDomainName "edge-site1" -vSanWitnessVmName "witness.lab" -Server "vc.lab"
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [Switch]$AcceptBadCheckResults,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [Switch]$ExistingDatastoreUsable,
        [Parameter(Mandatory = $false)] [Switch]$LabEnvironment,
        [Parameter(Mandatory = $false)] [String]$PreferredFaultDomainName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Server,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$vSanWitnessVmName
    )

    if ($ExistingDatastoreUsable) {
        try {
            $vsanConfig = Get-VsanClusterConfiguration -Cluster $ClusterName -Server $Server -ErrorAction SilentlyContinue
            if ($vsanConfig -and $vsanConfig.WitnessHost -and $vsanConfig.WitnessHost.Name -eq $vSanWitnessVmName) {
                Write-LogMessage -Type INFO -Message "vSAN datastore already exists and witness `"$vSanWitnessVmName`" is already configured for cluster `"$ClusterName`". Skipping witness configuration and health check."
                return
            }
        } catch {
            Write-LogMessage -Type DEBUG -Message "Could not check existing vSAN witness configuration for cluster `"$ClusterName`" ($($_.Exception.Message)); proceeding with witness block."
        }
    }
    if (-not $PreferredFaultDomainName) {
        $err = "PreferredFaultDomainName is required when vSanWitnessVmName is provided."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
    $witnessHost = Get-VMHost -Name $vSanWitnessVmName -Server $Server -ErrorAction Stop
    $witnessPoolDisks = Get-VsanStoragePoolDisk -VMHost $witnessHost -Server $Server -ErrorAction SilentlyContinue
    $witnessPoolDiskCount = if ($witnessPoolDisks) { @($witnessPoolDisks).Count } else { 0 }
    Write-LogMessage -Type DEBUG -Message "Witness host `"$vSanWitnessVmName`": checked for existing vSAN ESA storage pool; found $witnessPoolDiskCount disk(s). ESA witness with zero disks is supported."
    Write-LogMessage -Type DEBUG -Message "Calling Set-VsanWitness for cluster `"$ClusterName`" with PreferredFaultDomainName=`"$PreferredFaultDomainName`", vSanWitnessVmName=`"$vSanWitnessVmName`"."
    Write-LogMessage -Type INFO -Message "Configuring vSAN witness host for cluster `"$ClusterName`"."
    Set-VsanWitness -ClusterName $ClusterName -LabEnvironment:$LabEnvironment.IsPresent -PreferredFaultDomainName $PreferredFaultDomainName -StoragePolicyType "vSAN-ESA" -vSanWitnessVmName $vSanWitnessVmName
    Invoke-VsanClusterHealthCheckAfterWitness -AcceptBadCheckResults:$AcceptBadCheckResults.IsPresent -ClusterName $ClusterName -LabEnvironment:$LabEnvironment.IsPresent -StoragePolicyType "vSAN-ESA"
}
function Add-VsanEsaStoragePoolDisk {

    <#
        .SYNOPSIS
        Interactively selects and adds eligible disks to vSAN ESA storage pools for each host in a cluster.

        .DESCRIPTION
        The Add-VsanEsaStoragePoolDisk function retrieves all vSAN ESA eligible disks for a cluster,
        displays them in a formatted table, and allows the user to select which disks to add to the
        vSAN storage pools. By default, all eligible disks are selected. The user can choose to
        de-select specific disks or proceed with all disks. For each host, the selected disks are
        added to the vSAN ESA storage pool using Add-VsanStoragePoolDisk. After all disks are added,
        the function waits for the vSAN datastore to appear and renames it using the provided name.

        .PARAMETER AcceptBadCheckResults
        When specified, automatically proceed when vSAN cluster health is red after witness (no Y/N prompt).

        .PARAMETER CheckInterval
        The interval in seconds between progress checks. Default is 5 seconds.

        .PARAMETER ClusterName
        The name of the cluster for which to configure vSAN ESA storage pools.

        .PARAMETER DatastoreName
        The name to use for the vSAN datastore (generated from datastoreNamePrefix).

        .PARAMETER DiskRetrievalTimeoutSeconds
        Maximum time in seconds to wait for disk retrieval. Default is 900 seconds (15 minutes).

        .PARAMETER DatastoreWaitTimeoutSeconds
        Maximum time in seconds to wait for vSAN datastore to appear. Default is 300 seconds (5 minutes).

        .PARAMETER MinCapacityGBForExistingDatastore
        Minimum capacity in GB for an existing vSAN datastore to be considered usable. If capacity is below this, the datastore is treated as having no disks attached. Default is 1.

        .PARAMETER PreferredFaultDomainName
        Optional. The name of the preferred fault domain (typically the edgeSite name). Required if vSanWitnessVmName is provided.

        .PARAMETER LabEnvironment
        When $true (e.g. common.labenvironment is true), silences only controlleronhcl, advcfgsync, and controllerdiskmode vSAN health checks before the post-witness health check.

        .PARAMETER VsAdvCfgSyncWaitTimeoutSeconds
        Seconds to wait for vSAN advanced configuration (advCfgSync) to report in sync on all hosts after a config re-apply, immediately before Add-VsanStoragePoolDisk. Helps avoid "Operation is not valid due to the current state of the object" when vCenter has enabled ESA on the cluster but hosts have not finished applying it. Default 180; set 0 to skip (faster but riskier on slow hosts).

        .PARAMETER vSanWitnessVmName
        Optional. The FQDN or IP address of the vSAN witness host. If provided, the witness will be configured after the datastore is ready.

        .EXAMPLE
        Add-VsanEsaStoragePoolDisk -ClusterName "MyCluster" -DatastoreName "datastore-site1"

        This example retrieves eligible disks for "MyCluster", displays them to the user for selection,
        and adds the selected disks to the vSAN ESA storage pools for each host.

        .NOTES
        - Requires an active connection to vCenter (uses $Script:vCenterName)
        - Uses Get-VsanEsaEligibleDisk and Add-VsanStoragePoolDisk cmdlets from VCF PowerCLI
        - All operations are logged using Write-LogMessage
        - Function will throw on errors to allow proper error handling by calling code
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [Switch]$AcceptBadCheckResults,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 60)] [Int]$CheckInterval = 5,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DatastoreName,
        [Parameter(Mandatory = $false)] [ValidateRange(60, 1800)] [Int]$DatastoreWaitTimeoutSeconds = 300,
        [Parameter(Mandatory = $false)] [ValidateRange(60, 3600)] [Int]$DiskRetrievalTimeoutSeconds = 900,
        [Parameter(Mandatory = $false)] [Switch]$LabEnvironment,
        [Parameter(Mandatory = $false)] [ValidateRange(0, 10000)] [Double]$MinCapacityGBForExistingDatastore = 1,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$PreferredFaultDomainName,
        [Parameter(Mandatory = $false)] [ValidateRange(0, 600)] [Int]$VsAdvCfgSyncWaitTimeoutSeconds = 180,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$vSanWitnessVmName
    )

    Write-LogMessage -Type DEBUG -Message "Entered Add-VsanEsaStoragePoolDisk function for cluster: `"$ClusterName`"."

    Assert-VcenterConnected

    try {
        $clusterObject = Get-ClusterByName -Name $ClusterName -Server $Script:vCenterName
        if (-not $clusterObject) {
            throw [VcfDeploymentException]::new("Cluster `"$ClusterName`" not found in vCenter `"$Script:vCenterName`".")
        }
        $clusterHosts = Get-VMHost -Location $clusterObject -Server $Script:vCenterName -ErrorAction Stop
        if (-not $clusterHosts -or $clusterHosts.Count -eq 0) {
            $err = "Cluster `"$ClusterName`" does not contain any hosts."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }

        $dsStatus = Test-VsanEsaDatastoreUsability -ClusterHosts $clusterHosts -DatastoreName $DatastoreName `
            -MinCapacityGBForExistingDatastore $MinCapacityGBForExistingDatastore -Server $Script:vCenterName

        if (-not $dsStatus.IsUsable) {
            $diskWorkflowParams = @{
                CheckInterval = $CheckInterval; ClusterHosts = $clusterHosts; ClusterName = $ClusterName
                DatastoreName = $DatastoreName; DatastoreWaitTimeoutSeconds = $DatastoreWaitTimeoutSeconds
                DiskRetrievalTimeoutSeconds = $DiskRetrievalTimeoutSeconds
                InitialDatastore = $dsStatus.Datastore; InitialIsAddingToExisting = $dsStatus.IsAddingToExisting
                LabEnvironment = $LabEnvironment
                MinCapacityGBForExistingDatastore = $MinCapacityGBForExistingDatastore
                Server = $Script:vCenterName; VsAdvCfgSyncWaitTimeoutSeconds = $VsAdvCfgSyncWaitTimeoutSeconds
            }
            Invoke-VsanEsaDiskWorkflow @diskWorkflowParams
        }

        if ($vSanWitnessVmName) {
            Invoke-VsanEsaWitnessSetup -AcceptBadCheckResults:$AcceptBadCheckResults.IsPresent `
                -ClusterName $ClusterName -ExistingDatastoreUsable:$dsStatus.IsUsable `
                -LabEnvironment:$LabEnvironment.IsPresent -PreferredFaultDomainName $PreferredFaultDomainName `
                -Server $Script:vCenterName -vSanWitnessVmName $vSanWitnessVmName
        }
        Enable-VsanPerformanceService -ClusterName $ClusterName
    }
    catch [System.UnauthorizedAccessException] {
        $errorMessage = $_.Exception.Message
        $reason = Get-CleanVsanErrorMessage -ErrorMessage $errorMessage
        if ($reason -eq $errorMessage) { $reason = "authorization error. $errorMessage" }
        $cleanMessage = "Failed to configure vSAN ESA datastore for cluster `"$ClusterName`". Reason: $reason"
        Write-LogMessage -Type ERROR -Message $cleanMessage
        throw [VcfDeploymentException]::new("Deployment failed. $cleanMessage")
    }
    catch [System.TimeoutException] {
        $errorMessage = $_.Exception.Message
        $reason = Get-CleanVsanErrorMessage -ErrorMessage $errorMessage
        if ($reason -eq $errorMessage) { $reason = "network/timeout. $errorMessage" }
        $cleanMessage = "Failed to configure vSAN ESA datastore for cluster `"$ClusterName`". Reason: $reason"
        Write-LogMessage -Type ERROR -Message $cleanMessage
        throw [VcfDeploymentException]::new("Deployment failed. $cleanMessage")
    } catch {
        if ($_.Exception.Message -match "Deployment cancelled by user" -or $_.Exception.Message -match "^Deployment failed\.") {
            throw
        }
        $errorMessage = $_.Exception.Message
        if ($_.Exception.InnerException) {
            Write-LogMessage -Type DEBUG -Message "Inner exception: $($_.Exception.InnerException.Message)"
            $errorMessage = $_.Exception.InnerException.Message
        }
        $reason = Get-CleanVsanErrorMessage -ErrorMessage $errorMessage
        $ovaHint = ""
        if ($reason -match "not supported on the object|operation is not supported") {
            $ovaHint = " You may have deployed the vSAN witness OVA for OSA instead of the vSAN ESA witness appliance; for an ESA cluster use the vSAN ESA witness appliance (and vice versa for OSA)."
        }
        $cleanMessage = "Failed to configure vSAN ESA datastore for cluster `"$ClusterName`". Reason: $reason$ovaHint"
        Write-LogMessage -Type ERROR -Message $cleanMessage
        throw [VcfDeploymentException]::new("Deployment failed. $cleanMessage")
    }
}
function Get-EsxUnformattedDisk {

    <#
        .SYNOPSIS
        Scans an ESX host for unformatted disks (disks not in use by any datastore).

        .DESCRIPTION
        Identifies all SCSI LUNs on an ESX host that are not currently used by any VMFS datastore.
        Returns detailed information about each unformatted disk including capacity, vendor, and model.

        This is a helper function extracted from Get-EsxDatastoreInfo to follow the Single Responsibility Principle.
        It focuses solely on disk scanning logic without UI or validation concerns.

        .PARAMETER VmHost
        The VMHost object representing the ESX host to scan. Must be a valid PowerCLI VMHost object.

        .PARAMETER EsxHostName
        The hostname or IP address of the ESX host (used for logging only).

        .PARAMETER Silence
        Switch to suppress console output. When enabled, logs are written to file only.

        .OUTPUTS
        Array of PSCustomObject with properties: ID, CanonicalName, UUID, CapacityGB, Vendor, Model, MultipathPolicy, RuntimeName.
        Returns empty array if no unformatted disks are found.

        .NOTES
        - Requires an active connection to the ESX host
        - Filters out pseudo disks (disks without a multipath policy)
        - Assigns sequential IDs (1, 2, 3...) for interactive selection
    
        .EXAMPLE
        $esxUnformattedDisk = Get-EsxUnformattedDisk -EsxHostName "resource-name" -VmHost $vmHostObject
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EsxHostName,
        [Parameter(Mandatory = $false)] [Switch]$Silence,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$VmHost
    )

    Write-LogMessage -Type DEBUG -Message "Entered Get-EsxUnformattedDisk function..."
    Write-LogMessage -Type INFO -SuppressOutputToScreen:$Silence -Message "Scanning for unformatted disks/LUNs on ESX host `"$EsxHostName`"..."

    try {
        $allDisks = $VmHost | Get-ScsiLun -LunType disk
        $mountedDatastores = Get-Datastore -VMHost $VmHost

        $usedDisks = [System.Collections.Generic.List[String]]::new()
        foreach ($ds in $mountedDatastores) {
            $dsExt = $ds.ExtensionData
            if ($dsExt -and $dsExt.Info -and $dsExt.Info.Vmfs) {
                foreach ($extent in $dsExt.Info.Vmfs.Extent) {
                    $usedDisks.Add($extent.DiskName)
                }
            }
        }

        $usedDisksArray = $usedDisks.ToArray()
        $unformattedDisks = $allDisks | Where-Object {
            $diskUuid = $_.CanonicalName
            $usedDisksArray -notcontains $diskUuid -and
            $null -ne $_.MultipathPolicy  # Exclude pseudo disks.
        }

        $unformattedDiskArray = [System.Collections.Generic.List[PSObject]]::new()

        if ($unformattedDisks -and $unformattedDisks.Count -gt 0) {
            Write-LogMessage -Type INFO -SuppressOutputToScreen:$Silence -Message "Found $($unformattedDisks.Count) unformatted disk(s) on ESX host `"$EsxHostName`"."

            $diskId = 1
            foreach ($disk in $unformattedDisks) {
                $unformattedInfo = [PSCustomObject]@{
                    ID = $diskId
                    CanonicalName = $disk.CanonicalName
                    UUID = $disk.Uuid
                    CapacityGB = [Math]::Round(($disk.CapacityGB), 2)
                    Vendor = $disk.Vendor
                    Model = $disk.Model
                    MultipathPolicy = $disk.MultipathPolicy
                    RuntimeName = $disk.RuntimeName
                }
                $unformattedDiskArray.Add($unformattedInfo)

                Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Unformatted: $($unformattedInfo.CanonicalName) - UUID: $($unformattedInfo.UUID) - Capacity: $($unformattedInfo.CapacityGB) GB - Vendor: $($unformattedInfo.Vendor)"
                $diskId++
            }
        }
        else {
            Write-LogMessage -Type INFO -SuppressOutputToScreen:$Silence -Message "No unformatted disks found on ESX host `"$EsxHostName`"."
        }

        return $unformattedDiskArray.ToArray()
    } catch [VcfDeploymentException] {
        throw  # already logged and typed — propagate without re-wrapping
    } catch {
        $err = "Failed to scan for unformatted disks on ESX host `"$EsxHostName`": $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
}
function Get-DatastoreHealthAssessment {

    <#
        .SYNOPSIS
        Computes health status and free-space percentage for a datastore object.

        .DESCRIPTION
        Determines whether the datastore is in the "Available" state and whether free space is
        below the warning threshold. Returns a PSCustomObject with IsHealthy (bool), HealthIssues
        (array of issue strings), and FreeSpacePercent (decimal).

        .PARAMETER Datastore
        A PowerCLI Datastore object returned by Get-Datastore.

        .PARAMETER FreeSpaceWarningThreshold
        Free-space percentage below which a warning issue is recorded. Default is 10.

        .EXAMPLE
        $health = Get-DatastoreHealthAssessment -Datastore $targetDatastore -FreeSpaceWarningThreshold 10

        .NOTES
        Called by Get-EsxDatastoreHealth. Pure data computation; does not write to any log.
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$Datastore,
        [Parameter(Mandatory = $false)] [ValidateRange(0, 100)] [Int]$FreeSpaceWarningThreshold = 10
    )

    $isHealthy = $true
    $healthIssues = @()

    # Use State instead of the deprecated Accessible property; "Available" means healthy.
    if ($Datastore.State -ne "Available") {
        $isHealthy = $false
        $healthIssues += "Datastore state is: $($Datastore.State)"
    }

    $freeSpacePercent = if ($Datastore.CapacityGB -gt 0) {
        [Math]::Round(($Datastore.FreeSpaceGB / $Datastore.CapacityGB * 100), 2)
    } else {
        0
    }
    if ($freeSpacePercent -lt $FreeSpaceWarningThreshold) {
        $healthIssues += "Low free space: $freeSpacePercent%"
    }

    return [PSCustomObject]@{ FreeSpacePercent = $freeSpacePercent; HealthIssues = $healthIssues; IsHealthy = $isHealthy }
}
function Get-EsxDatastoreHealth {

    <#
        .SYNOPSIS
        Validates the health and properties of a specific datastore on an ESX host.

        .DESCRIPTION
        Performs comprehensive health checks on a mounted datastore including:
        - Mount status verification
        - VMFS version detection
        - Accessibility checks
        - Capacity and free space analysis
        - State validation

        This is a helper function extracted from Get-EsxDatastoreInfo to follow the Single Responsibility Principle.
        It focuses solely on datastore validation logic.

        .PARAMETER VmHost
        The VMHost object representing the ESX host. Must be a valid PowerCLI VMHost object.

        .PARAMETER EsxHostName
        The hostname or IP address of the ESX host (used for logging only).

        .PARAMETER DatastoreName
        The name of the datastore to validate.

        .PARAMETER FreeSpaceWarningThreshold
        The free space percentage threshold below which a warning is generated. Default is 10.

        .PARAMETER Silence
        Switch to suppress console output. When enabled, logs are written to file only.

        .OUTPUTS
        PSCustomObject with datastore health properties:
        - Name, IsMounted, Type, IsVMFS, FileSystemVersion, UUID, CanonicalName
        - CapacityGB, FreeSpaceGB, FreeSpacePercent, Accessible, State
        - IsHealthy, HealthIssues, ExtentCount, Extents

        .NOTES
        - Health check thresholds: free space warning if < FreeSpaceWarningThreshold (default 10%)
        - Returns IsMounted=$false if datastore not found
        - Includes extent information for VMFS datastores
    
        .EXAMPLE
        $esxDatastoreHealth = Get-EsxDatastoreHealth -DatastoreName "resource-name" -EsxHostName "resource-name" -VmHost $vmHostObject
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DatastoreName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EsxHostName,
        [Parameter(Mandatory = $false)] [ValidateRange(0, 100)] [Int]$FreeSpaceWarningThreshold = 10,
        [Parameter(Mandatory = $false)] [Switch]$Silence,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$VmHost
    )

    Write-LogMessage -Type DEBUG -Message "Entered Get-EsxDatastoreHealth function..."
    Write-LogMessage -Type DEBUG -SuppressOutputToScreen:$Silence -Message "Validating mounted datastore `"$DatastoreName`" on ESX host `"$EsxHostName`"..."

    try {
        $targetDatastore = Get-Datastore -Name $DatastoreName -VMHost $VmHost -ErrorAction Stop

        $dsView = $targetDatastore.ExtensionData
        $isVmfs = $targetDatastore.Type -eq "VMFS"
        $vmfsVersion = if ($isVmfs -and $dsView.Info.Vmfs) { $dsView.Info.Vmfs.Version } else { $null }
        $datastoreUuid = if ($isVmfs -and $dsView.Info.Vmfs) { $dsView.Info.Vmfs.Uuid } else { $null }

        $health = Get-DatastoreHealthAssessment -Datastore $targetDatastore -FreeSpaceWarningThreshold $FreeSpaceWarningThreshold
        $isHealthy = $health.IsHealthy
        $healthIssues = $health.HealthIssues
        $freeSpacePercent = $health.FreeSpacePercent

        $datastoreStatus = [PSCustomObject]@{
            Name = $targetDatastore.Name
            IsMounted = $true
            Type = $targetDatastore.Type
            IsVMFS = $isVmfs
            FileSystemVersion = $vmfsVersion
            UUID = $datastoreUuid
            CanonicalName = if ($isVmfs -and $dsView.Info.Vmfs -and $dsView.Info.Vmfs.Extent.Count -gt 0) { $dsView.Info.Vmfs.Extent[0].DiskName } else { $null }
            CapacityGB = [Math]::Round($targetDatastore.CapacityGB, 2)
            FreeSpaceGB = [Math]::Round($targetDatastore.FreeSpaceGB, 2)
            FreeSpacePercent = $freeSpacePercent
            State = $targetDatastore.State
            IsHealthy = $isHealthy
            HealthIssues = if ($healthIssues.Count -gt 0) { $healthIssues -join "; " } else { "None" }
            ExtentCount = if ($isVmfs -and $dsView.Info.Vmfs) { $dsView.Info.Vmfs.Extent.Count } else { 0 }
            Extents = if ($isVmfs -and $dsView.Info.Vmfs) {
                ($dsView.Info.Vmfs.Extent | ForEach-Object {
                    [PSCustomObject]@{
                        DiskName = $_.DiskName
                        Partition = $_.Partition
                    }
                })
            } else { @() }
        }

        if ($isVmfs) {
            if ($isHealthy) {
                Write-LogMessage -Type INFO -SuppressOutputToScreen:$Silence -Message "Datastore `"$DatastoreName`" is mounted, VMFS v$vmfsVersion formatted, and healthy on ESX host `"$EsxHostName`"."
                Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "UUID: $datastoreUuid - Capacity: $($datastoreStatus.CapacityGB) GB - Free: $($datastoreStatus.FreeSpaceGB) GB ($($datastoreStatus.FreeSpacePercent)%)"
            }
            else {
                Write-LogMessage -Type WARNING -SuppressOutputToScreen:$Silence -Message "Datastore `"$DatastoreName`" is mounted and VMFS v$vmfsVersion formatted but has issues on ESX host `"$EsxHostName`": $($healthIssues -join ', ')"
            }
        }
        else {
            Write-LogMessage -Type INFO -SuppressOutputToScreen:$Silence -Message "Datastore `"$DatastoreName`" is mounted on ESX host `"$EsxHostName`" but is NOT VMFS formatted (Type: $($targetDatastore.Type))."
            if (-not $isHealthy) {
                Write-LogMessage -Type WARNING -SuppressOutputToScreen:$Silence -Message "Datastore has issues: $($healthIssues -join ', ')"
            }
        }

        return $datastoreStatus
    } catch {
        Write-LogMessage -Type WARNING -SuppressOutputToScreen:$Silence -Message "Datastore `"$DatastoreName`" not found or not mounted on ESX host `"$EsxHostName`": $($_.Exception.Message)"
        return [PSCustomObject]@{
            Name = $DatastoreName
            IsMounted = $false
            IsVMFS = $false
            IsHealthy = $false
            HealthIssues = "Datastore not found or not mounted"
        }
    }
}
function Get-EsxDatastoreInfo {

    <#
        .SYNOPSIS
        Scans an ESX host for unformatted datastores and validates mounted datastores.

        .DESCRIPTION
        Orchestrator function that provides backward-compatible interface to datastore scanning operations.
        Delegates to specialized helper functions for improved maintainability:
        - Get-EsxUnformattedDisk: Scans for unformatted disks
        - Get-EsxDatastoreHealth: Validates datastore health

        The function reports UUID, capacity, and health status for discovered datastores.

        Key features:
        - Identifies unformatted storage devices available for use
        - Validates health of mounted datastores including accessibility, state, and free space
        - Provides detailed capacity information for all discovered storage
        - Returns structured data for programmatic processing

        .PARAMETER EsxHostName
        The hostname or IP address of the ESX host to scan. This parameter is mandatory.
        The host must be visible to the connected vCenter server.

        .PARAMETER DatastoreName
        Optional. Name of a specific mounted datastore to validate.
        When specified, the function ONLY checks this specific datastore and skips unformatted disk scans.
        Performs health checks including mount status, VMFS formatting, accessibility, state, and free space validation.

        .PARAMETER Silence
        Switch to suppress all console output.
        When enabled, all log messages are written to the log file only (using -SuppressOutputToScreen).
        Useful for automation scenarios where console output should be minimized.

        .EXAMPLE
        Get-EsxDatastoreInfo -EsxHostName "esx01.example.com"

        Scans the ESX host for all unformatted disks/LUNs.

        .EXAMPLE
        Get-EsxDatastoreInfo -EsxHostName "esx01.example.com" -DatastoreName "datastore1"

        Validates that datastore "datastore1" is mounted and healthy on the specified host.
        Checks if it is VMFS formatted and reports the VMFS version if applicable.

        .EXAMPLE
        Get-EsxDatastoreInfo -DatastoreName "datastore1" -EsxHostName "esx01.example.com" -Silence

        Validates datastore "datastore1" health with all output suppressed to console.
        Logs are written only to the log file (useful for automation).

        .OUTPUTS
        PSCustomObject with properties:
        - EsxHost: The hostname or IP of the scanned ESX host
        - UnformattedDisks: Array of unformatted disks/LUNs with UUID, capacity, and vendor info
        - MountedDatastoreStatus: Health status of specified datastore with the following properties:
          * IsMounted: Boolean indicating if datastore is mounted
          * IsVMFS: Boolean indicating if datastore is VMFS formatted
          * Type: Datastore type (VMFS, NFS, vVOL, etc.)
          * FileSystemVersion: VMFS version number (if VMFS formatted)
          * UUID: Datastore UUID (if VMFS formatted)
          * CanonicalName: Canonical name of the underlying disk device (e.g., "naa:xxxxx") for the first extent
          * Name, CapacityGB, FreeSpaceGB, FreeSpacePercent, Accessible, State, IsHealthy, HealthIssues

        .NOTES
        - Requires an active direct connection to the ESX host
        - Requires PowerCLI modules to be installed (VMware.VimAutomation.Core)
        - Health check criteria includes accessibility, state, and free space (warning if < 10%)
        - Uses Write-LogMessage with -SuppressOutputToScreen for consistent logging throughout the script
        - Follows the error handling patterns of the VcfEdgeAtScale module
        - Refactored into modular helper functions for improved maintainability and testability
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$DatastoreName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EsxHostName,
        [Parameter(Mandatory = $false)] [Switch]$Silence
    )

    Write-LogMessage -Type DEBUG -Message "Entered Get-EsxDatastoreInfo function..."

    $esxConn = $Global:DefaultViServers | Where-Object { $_.Name -eq $EsxHostName -and $_.IsConnected } | Select-Object -First 1
    if (-not $esxConn) {
        $err = "No active connection to ESX host `"$EsxHostName`". Connect first with Connect-Vcenter."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }

    try {
        # If datastoreName is specified, only check that specific datastore.
        if ($DatastoreName) {
            Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Checking for specific datastore `"$DatastoreName`" only."
        }
        else {
            Write-LogMessage -Type INFO -SuppressOutputToScreen:$Silence -Message "Starting datastore scan on ESX host `"$EsxHostName`"..."
        }

        try {
            $vmHost = Get-VMHost -Server $esxConn -ErrorAction Stop | Select-Object -First 1
            if (-not $vmHost) {
                throw [VcfDeploymentException]::new("Get-VMHost returned no host objects from direct connection to `"$EsxHostName`".")
            }
        }
        catch [System.UnauthorizedAccessException] {
            $err = "Cannot access ESX host `"$EsxHostName`" due to authorization issues: $($_.Exception.Message)"
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
        catch [System.TimeoutException] {
            $err = "Cannot access ESX host `"$EsxHostName`" due to network/timeout issues: $($_.Exception.Message)"
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        } catch [VcfDeploymentException] {
            throw  # already logged and typed — propagate without re-wrapping
        } catch {
            $err = "Failed to get ESX host `"$EsxHostName`": $($_.Exception.Message)"
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }

        $result = [PSCustomObject]@{
            EsxHost = $EsxHostName
            UnformattedDisks = @()
            MountedDatastoreStatus = $null
            SelectedDatastoreUUID = $null
        }

        if (-not $DatastoreName) {
            $result.UnformattedDisks = Get-EsxUnformattedDisk -EsxHostName $EsxHostName -Silence:$Silence -VmHost $vmHost
            Write-LogMessage -Type INFO -SuppressOutputToScreen:$Silence -Message "Datastore scan completed on ESX host `"$EsxHostName`". Unformatted disks: $($result.UnformattedDisks.Count)"
        }

        if ($DatastoreName) {
            $result.MountedDatastoreStatus = Get-EsxDatastoreHealth -DatastoreName $DatastoreName -EsxHostName $EsxHostName -Silence:$Silence -VmHost $vmHost
        }

        return $result
    } catch [VcfDeploymentException] {
        throw  # already logged and typed — propagate without re-wrapping
    } catch {
        $errorMsg = "Failed to scan ESX host `"$EsxHostName`": $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -SuppressOutputToScreen:$Silence -Message $errorMsg
        throw [VcfDeploymentException]::new($errorMsg)
    }
}

#endregion
function Get-ManagementVSwitchInfo {

    <#
        .SYNOPSIS
        Returns the standard vSwitch that has the management VMkernel (vmk0) and its physical NIC(s).

        .DESCRIPTION
        Finds the standard switch that hosts vmk0 and returns its associated pNIC uplinks, sorted
        alphabetically for determinism. Returns $null if vmk0 is not found or is not on a standard
        switch. PnicNames may contain zero entries (vSS has no uplinks), one entry (typical fresh
        install), or two or more entries (dual-uplink management switch).

        .PARAMETER VMHost
        The VMHost object (from Get-VMHost).

        .OUTPUTS
        PSCustomObject with StandardSwitch, ManagementVmkernel, PnicNames (alphabetically sorted
        array of pNIC names on the management vSS — may be empty, one, or many), and
        ManagementPortGroupVlanId (VLAN ID of the port group vmk0 is on, or 0 if not determinable),
        or $null.
    
        .EXAMPLE
        $managementVSwitchInfo = Get-ManagementVSwitchInfo -VMHost $vmHostObject
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
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
                $pnics = Get-PhysicalNicsOnVssForHost -VMHost $VMHost -VirtualSwitch $vSwitch -Server $Script:vCenterName
                $pnicNames = @($pnics | Select-Object -ExpandProperty Name | Sort-Object)
                $mgmtVlanId = 0
                if ($pg.PSObject.Properties["VLanID"]) {
                    $mgmtVlanId = [Int]$pg.VLanID
                } elseif ($pg.PSObject.Properties["VlanId"]) {
                    $mgmtVlanId = [Int]$pg.VlanId
                } elseif ($null -ne $pg.ExtensionData -and $null -ne $pg.ExtensionData.Spec -and $null -ne $pg.ExtensionData.Spec.VlanId) {
                    $mgmtVlanId = [Int]$pg.ExtensionData.Spec.VlanId
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
function Get-FirstUnusedNicFromNicList {

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
    
        .EXAMPLE
        $firstUnusedNicFromNicList = Get-FirstUnusedNicFromNicList -NicNames "resource-name" -VMHost $vmHostObject
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String[]]$NicNames,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [PSObject]$VMHost
    )

    $assigned = [System.Collections.Generic.List[String]]::new()
    $stdSwitches = Get-VirtualSwitchesOnHost -VMHost $VMHost -Server $Script:vCenterName
    foreach ($sw in $stdSwitches) {
        $pnics = Get-PhysicalNicsOnVdsForHost -VMHost $VMHost -VDSwitch $sw -Server $Script:vCenterName
        if ($pnics) {
            $assigned.AddRange([String[]]($pnics | Select-Object -ExpandProperty Name))
        }
    }
    $allVds = Get-VDSwitch -Server $Script:vCenterName -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
    foreach ($vds in $allVds) {
        $pnics = Get-PhysicalNicsOnVdsForHost -VMHost $VMHost -VDSwitch $vds -Server $Script:vCenterName
        if ($pnics) {
            $assigned.AddRange([String[]]($pnics | Select-Object -ExpandProperty Name))
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
function Get-VdsObjectByName {

    <#
        .SYNOPSIS
        Thin wrapper over Get-VDSwitch enabling unit tests to mock this call without fighting
        PowerCLI ArgumentTransformationAttribute constraints on the -Server parameter.

        .PARAMETER Name
        VDS name.

        .PARAMETER Server
        vCenter server name. Defaults to $Script:vCenterName.

        .EXAMPLE
        Get-VdsObjectByName -Name "Production-VDS" -Server "vc.lab"
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Name,
        [Parameter(Mandatory = $false)] [String]$Server = $Script:vCenterName
    )

    Get-VDSwitch -Name $Name -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
}
function Get-MgmtVssUplinkForMigration {

    <#
        .SYNOPSIS
        Determines which pNIC to use as the initial VDS uplink during management-to-VDS migration.

        .DESCRIPTION
        Pure-read helper for Invoke-MigrateHostManagementToVds. Given the management vSS info,
        the NicList, and the VDS object, determines:
        - $FirstUnused: the pNIC to add to the VDS first (either a free NIC or the first NicList
          NIC on the vSS when all NicList pNICs are on the management vSS).
        - $HostAlreadyHasPnicOnVds: $true when a NicList pNIC is already on the VDS.
        - $VssPnicsToReclaimAfterVssRemoval: pNICs freed when the vSS is removed.
        - $ReclaimedPnicName: first pNIC to be reclaimed (or $null).
        - $EffectiveMgmtVlanId: VLAN to use for the management DPG.

        Throws VcfDeploymentException when no usable pNIC can be found.

        .PARAMETER EffectiveMgmtVlanId
        VLAN ID resolved from the host's current management port group (or the fallback parameter).

        .PARAMETER HostDisplay
        Host display name for log messages.

        .PARAMETER MgmtInfo
        PSCustomObject returned by Get-ManagementVSwitchInfo.

        .PARAMETER NicNames
        Array of NIC name strings from the NicList parameter (already extracted/trimmed).

        .PARAMETER VdsObject
        The VDS object returned by Get-VdsObjectByName.

        .PARAMETER VMHost
        The VMHost object used to query physical NICs on the VDS.

        .OUTPUTS
        PSCustomObject with FirstUnused, HostAlreadyHasPnicOnVds, VssPnicsToReclaimAfterVssRemoval,
        ReclaimedPnicName, and EffectiveMgmtVlanId.

        .EXAMPLE
        $uplinkInfo = Get-MgmtVssUplinkForMigration -MgmtInfo $mgmtInfo -NicNames $nicNames -VdsObject $vdsObject -VMHost $VMHost -HostDisplay $hostDisplay -EffectiveMgmtVlanId $vlan
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateRange(0, 4094)] [Int]$EffectiveMgmtVlanId,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$HostDisplay,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$MgmtInfo,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [String[]]$NicNames,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$VdsObject,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$VMHost
    )

    $vssPnicNames = $MgmtInfo.PnicNames
    $firstUnused = Get-FirstUnusedNicFromNicList -VMHost $VMHost -NicNames $NicNames
    $hostAlreadyHasPnicOnVds = $false

    if (-not $firstUnused) {
        $pnicsOnTargetVds = @(Get-PhysicalNicsOnVdsForHost -VMHost $VMHost -VDSwitch $VdsObject -Server $Script:vCenterName)
        if ($pnicsOnTargetVds -and $pnicsOnTargetVds.Count -gt 0) {
            $hostAlreadyHasPnicOnVds = $true
            Write-LogMessage -Type INFO -Message "Host `"$HostDisplay`" has no unused NIC from NicList (all assigned); at least one pNIC is already on VDS. Proceeding to migrate vmk0 only."
        } else {
            # All NicList pNICs are "assigned" because they are on the management vSS. Pick the first
            # NicList pNIC that is on the vSS to add to VDS first; Add-VDSwitchPhysicalNetworkAdapter
            # atomically moves it off the vSS so the remaining uplink(s) keep management alive.
            # The other vSS pNICs are freed when the vSS is removed and are added to VDS afterward.
            $firstUnused = @($NicNames | Where-Object { $vssPnicNames -contains $_ })[0]
            if ([String]::IsNullOrWhiteSpace($firstUnused)) {
                $err = "No unused NIC from NicList found on host `"$HostDisplay`". All of [$($NicNames -join ', ')] are already assigned and none are on the management vSS."
                Write-LogMessage -Type ERROR -Message $err
                throw [VcfDeploymentException]::new($err)
            }
            Write-LogMessage -Type INFO -Message "Host `"$HostDisplay`": all NicList pNICs are on the management vSS `"$($MgmtInfo.StandardSwitch.Name)`"; adding `"$firstUnused`" to VDS first (atomically migrates it off the vSS), then migrating vmk0."
        }
    }

    $vssPnicsToReclaimAfterVssRemoval = @($vssPnicNames | Where-Object { $_ -ne $firstUnused })
    $reclaimedPnicName = if ($vssPnicsToReclaimAfterVssRemoval.Count -gt 0) { $vssPnicsToReclaimAfterVssRemoval[0] } else { $null }

    return [PSCustomObject]@{
        FirstUnused                    = $firstUnused
        HostAlreadyHasPnicOnVds        = $hostAlreadyHasPnicOnVds
        VssPnicsToReclaimAfterVssRemoval = $vssPnicsToReclaimAfterVssRemoval
        ReclaimedPnicName              = $reclaimedPnicName
        EffectiveMgmtVlanId            = $EffectiveMgmtVlanId
    }
}
function Invoke-AddUplinkToVds {

    <#
        .SYNOPSIS
        Adds the second (and any additional) pNIC uplinks to the VDS after the management standard switch has been removed.

        .DESCRIPTION
        Called after vmk0 has been migrated and the management standard switch removed. Selects the second
        NicList pNIC and adds it to the VDS; falls back to the first reclaimed vSS pNIC if the second NicList
        pNIC is unavailable or already on the VDS. Also adds any additional pNICs freed when the vSS was
        removed (relevant when the original management vSS had three or more uplinks).

        .PARAMETER FirstUnusedNicName
        Name of the first pNIC already added to the VDS. Used to identify which NicList entry to skip when
        selecting the second uplink candidate.

        .PARAMETER HostDisplay
        Host name string for log messages.

        .PARAMETER NicNames
        Ordered list of NIC names from NicList. The first entry not equal to FirstUnusedNicName is selected
        as the second uplink candidate.

        .PARAMETER ReclaimedPnicName
        The first pNIC reclaimed from the vSS after removal. Used as fallback when the second NicList pNIC
        is unavailable or already on the VDS.

        .PARAMETER StdSwitchName
        Name of the management standard switch that was removed. Used for a diagnostic log message when
        the switch was the cleanup restore vSS ("vSwitch0-restore").

        .PARAMETER VdsName
        VDS name for log messages.

        .PARAMETER VdsObject
        The VDS object to add pNICs to.

        .PARAMETER VMHost
        The VMHost object.

        .PARAMETER VssPnicsToReclaim
        All pNIC names that were on the management vSS prior to removal. Index [0] is ReclaimedPnicName
        (handled by the second-uplink fallback path); indices 1+ are added as additional uplinks in a
        best-effort loop.

        .EXAMPLE
        Invoke-AddUplinkToVds -FirstUnusedNicName "vmnic0" -HostDisplay "esx01.lab" `
            -NicNames @("vmnic0", "vmnic1") -ReclaimedPnicName "vmnic2" -VdsName "myVDS" `
            -VdsObject $vds -VMHost $vmHost -VssPnicsToReclaim @("vmnic2", "vmnic3")

        .NOTES
        Called exclusively from Invoke-MigrateHostManagementToVds after the vSS has been removed.
        Failures adding extra pNICs are logged as WARNING and do not block the migration.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$FirstUnusedNicName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$HostDisplay,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String[]]$NicNames,
        [Parameter(Mandatory = $false)] [String]$ReclaimedPnicName = "",
        [Parameter(Mandatory = $false)] [String]$StdSwitchName = "",
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VdsName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] $VdsObject,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] $VMHost,
        [Parameter(Mandatory = $false)] [String[]]$VssPnicsToReclaim = @()
    )

    $secondFromNicList = @($NicNames | Where-Object { $_ -ne $FirstUnusedNicName })[0]
    $pnicToAddAsSecond = $null
    if (-not [String]::IsNullOrWhiteSpace($secondFromNicList)) {
        try {
            $candidatePnic = Get-VMHostNetworkAdapter -VMHost $VMHost -Physical -Name $secondFromNicList -Server $Script:vCenterName -ErrorAction Stop
            $pnicsAlreadyOnVds = @(Get-VMHostNetworkAdapter -VMHost $VMHost -Physical -VirtualSwitch $VdsObject -Server $Script:vCenterName -WarningAction SilentlyContinue -ErrorAction SilentlyContinue)
            $alreadyOnVds = @($pnicsAlreadyOnVds | Where-Object { $_.Name -eq $secondFromNicList })
            if (-not $alreadyOnVds -and $candidatePnic) {
                $pnicToAddAsSecond = $candidatePnic
            }
        } catch {
            Write-LogMessage -Type DEBUG -Message "Second NIC from NicList `"$secondFromNicList`" not available on host `"$HostDisplay`": $($_.Exception.Message). Using reclaimed pNIC."
        }
    }
    if ($null -eq $pnicToAddAsSecond) {
        if (-not [String]::IsNullOrWhiteSpace($ReclaimedPnicName)) {
            $pnicToAddAsSecond = Get-VMHostNetworkAdapter -VMHost $VMHost -Physical -Name $ReclaimedPnicName -Server $Script:vCenterName -ErrorAction Stop
            $null = $VdsObject | Add-VDSwitchPhysicalNetworkAdapter -VMHostPhysicalNic $pnicToAddAsSecond -Server $Script:vCenterName -Confirm:$false -WarningAction SilentlyContinue -ErrorAction Stop
            Write-LogMessage -Type DEBUG -Message "Added reclaimed pNIC `"$ReclaimedPnicName`" to VDS `"$VdsName`" on host `"$HostDisplay`"."
        }
    } else {
        try {
            $null = $VdsObject | Add-VDSwitchPhysicalNetworkAdapter -VMHostPhysicalNic $pnicToAddAsSecond -Server $Script:vCenterName -Confirm:$false -WarningAction SilentlyContinue -ErrorAction Stop
            Write-LogMessage -Type DEBUG -Message "Added pNIC `"$secondFromNicList`" to VDS `"$VdsName`" on host `"$HostDisplay`" (second from NicList)."
            if ($StdSwitchName -eq "vSwitch0-restore") {
                Write-LogMessage -Type DEBUG -Message "Management was on restore VSS; used second from NicList so VDS uplinks match NicList on re-deploy after cleanup."
            }
        } catch {
            Write-LogMessage -Type WARNING -Message "Could not add pNIC `"$secondFromNicList`" to VDS (e.g. already on another switch): $($_.Exception.Message). Adding reclaimed pNIC `"$ReclaimedPnicName`"."
            if (-not [String]::IsNullOrWhiteSpace($ReclaimedPnicName)) {
                $pnicToAddAsSecond = Get-VMHostNetworkAdapter -VMHost $VMHost -Physical -Name $ReclaimedPnicName -Server $Script:vCenterName -ErrorAction Stop
                $null = $VdsObject | Add-VDSwitchPhysicalNetworkAdapter -VMHostPhysicalNic $pnicToAddAsSecond -Server $Script:vCenterName -Confirm:$false -WarningAction SilentlyContinue -ErrorAction Stop
                Write-LogMessage -Type DEBUG -Message "Added reclaimed pNIC `"$ReclaimedPnicName`" to VDS `"$VdsName`" on host `"$HostDisplay`"."
            }
        }
    }
    # Index [0] of VssPnicsToReclaim is ReclaimedPnicName, already handled above as the second-uplink fallback.
    foreach ($extraPnicName in @($VssPnicsToReclaim | Select-Object -Skip 1)) {
        if ([String]::IsNullOrWhiteSpace($extraPnicName)) { continue }
        try {
            $pnicsCurrentlyOnVds = @(Get-VMHostNetworkAdapter -VMHost $VMHost -Physical -VirtualSwitch $VdsObject -Server $Script:vCenterName -WarningAction SilentlyContinue -ErrorAction SilentlyContinue)
            if ($pnicsCurrentlyOnVds | Where-Object { $_.Name -eq $extraPnicName }) {
                Write-LogMessage -Type DEBUG -Message "pNIC `"$extraPnicName`" is already on VDS `"$VdsName`" on host `"$HostDisplay`"; skipping."
                continue
            }
            $extraPnic = Get-VMHostNetworkAdapter -VMHost $VMHost -Physical -Name $extraPnicName -Server $Script:vCenterName -ErrorAction Stop
            $null = $VdsObject | Add-VDSwitchPhysicalNetworkAdapter -VMHostPhysicalNic $extraPnic -Server $Script:vCenterName -Confirm:$false -WarningAction SilentlyContinue -ErrorAction Stop
            Write-LogMessage -Type DEBUG -Message "Added additional reclaimed pNIC `"$extraPnicName`" to VDS `"$VdsName`" on host `"$HostDisplay`"."
        } catch {
            Write-LogMessage -Type WARNING -Message "Could not add additional reclaimed pNIC `"$extraPnicName`" to VDS `"$VdsName`" on host `"$HostDisplay`": $($_.Exception.Message)."
        }
    }
}
function Invoke-EnsureMgmtPortGroupOnVds {

    <#
        .SYNOPSIS
        Ensures a management port group exists on a VDS, creating it if absent.

        .DESCRIPTION
        Looks up the port group by name on the specified VDS (with a Server-qualified fallback for vCenter
        resolution). When not found, creates the port group using a retry loop that handles both transient
        "operation not valid" errors and "already exists" races. Throws VcfDeploymentException if the port
        group cannot be resolved after all retries.

        .PARAMETER EffectiveMgmtVlanId
        VLAN ID to assign when creating the port group.

        .PARAMETER ManagementPortGroupName
        Name of the management port group to find or create.

        .PARAMETER MaxAttempts
        Maximum creation attempts when the server returns a transient error.

        .PARAMETER NumPorts
        Number of static ports to allocate when creating the port group.

        .PARAMETER PostCreatePollAttempts
        Number of re-query attempts after an "already exists" creation error.

        .PARAMETER PostCreatePollIntervalSeconds
        Seconds to wait between post-create re-query attempts.

        .PARAMETER RetryDelaySeconds
        Seconds to wait between transient-failure creation retries.

        .PARAMETER VdsName
        Name of the VDS; used in log and error messages.

        .PARAMETER VdsObject
        The VDS object on which the port group is managed.

        .EXAMPLE
        $portGroup = Invoke-EnsureMgmtPortGroupOnVds -EffectiveMgmtVlanId 100 -ManagementPortGroupName "Management" -VdsName "VDS-edge1" -VdsObject $vds

        .NOTES
        Returns the resolved or newly created VmwareVDPortgroup object. Uses $Script:vCenterName for
        server-qualified API calls; the caller must be connected to vCenter before invoking this function.
    #>

    [CmdletBinding()]
    [OutputType([Object])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateRange(0, 4094)] [Int]$EffectiveMgmtVlanId,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ManagementPortGroupName,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 20)]  [Int]$MaxAttempts = 3,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 512)] [Int]$NumPorts = 128,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 10)]  [Int]$PostCreatePollAttempts = 3,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 30)]  [Int]$PostCreatePollIntervalSeconds = 3,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 60)]  [Int]$RetryDelaySeconds = 10,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VdsName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$VdsObject
    )

    $mgmtPortGroup = Get-VDPortgroup -Name $ManagementPortGroupName -VDSwitch $VdsObject -Server $Script:vCenterName -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
    if (-not $mgmtPortGroup) {
        $mgmtPortGroup = Get-VDPortgroup -Name $ManagementPortGroupName -VDSwitch $VdsObject -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
    }
    if (-not $mgmtPortGroup) {
        $mgmtPgAttempt = 1
        do {
            try {
                Write-LogMessage -Type INFO -Message "Creating management port group `"$ManagementPortGroupName`" on VDS `"$VdsName`" (VLAN $EffectiveMgmtVlanId)."
                New-VDPortgroup -Name $ManagementPortGroupName -VDSwitch $VdsObject -VlanId $EffectiveMgmtVlanId -NumPorts $NumPorts -PortBinding Static -Server $Script:vCenterName -WarningAction SilentlyContinue -ErrorAction Stop | Out-Null
                $mgmtPortGroup = Get-VDPortgroup -Name $ManagementPortGroupName -VDSwitch $VdsObject -Server $Script:vCenterName -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
                if (-not $mgmtPortGroup) { $mgmtPortGroup = Get-VDPortgroup -Name $ManagementPortGroupName -VDSwitch $VdsObject -WarningAction SilentlyContinue -ErrorAction Stop }
                break
            } catch {
                $pgErr = $_.Exception.Message
                # Port group may have been created on server despite error (same as VDS). Re-query first.
                $mgmtPortGroup = Get-VDPortgroup -Name $ManagementPortGroupName -VDSwitch $VdsObject -Server $Script:vCenterName -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
                if (-not $mgmtPortGroup) { $mgmtPortGroup = Get-VDPortgroup -Name $ManagementPortGroupName -VDSwitch $VdsObject -WarningAction SilentlyContinue -ErrorAction SilentlyContinue }
                if ($null -ne $mgmtPortGroup) {
                    Write-LogMessage -Type INFO -Message "Management port group `"$ManagementPortGroupName`" exists on VDS `"$VdsName`" after New-VDPortgroup reported error; using existing."
                    break
                }
                if ($pgErr -match "already exists") {
                    Write-LogMessage -Type INFO -Message "Management port group `"$ManagementPortGroupName`" already exists on VDS `"$VdsName`"; resolving existing port group."
                    $mgmtPortGroup = Get-VDPortgroup -Name $ManagementPortGroupName -VDSwitch $VdsObject -Server $Script:vCenterName -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
                    if (-not $mgmtPortGroup) { $mgmtPortGroup = Get-VDPortgroup -Name $ManagementPortGroupName -VDSwitch $VdsObject -WarningAction SilentlyContinue -ErrorAction SilentlyContinue }
                    $getPgAttempt = 0
                    while (-not $mgmtPortGroup -and $getPgAttempt -lt $PostCreatePollAttempts) {
                        $getPgAttempt++
                        Write-LogMessage -Type DEBUG -Message "Management port group not found yet (attempt $getPgAttempt of $PostCreatePollAttempts); waiting $PostCreatePollIntervalSeconds s for vCenter consistency."
                        Start-Sleep -Seconds $PostCreatePollIntervalSeconds
                        $mgmtPortGroup = Get-VDPortgroup -Name $ManagementPortGroupName -VDSwitch $VdsObject -Server $Script:vCenterName -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
                        if (-not $mgmtPortGroup) { $mgmtPortGroup = Get-VDPortgroup -Name $ManagementPortGroupName -VDSwitch $VdsObject -WarningAction SilentlyContinue -ErrorAction SilentlyContinue }
                    }
                    if (-not $mgmtPortGroup) {
                        $err = "Management port group `"$ManagementPortGroupName`" was reported as already existing on VDS `"$VdsName`" but could not be found. Check the VDS in vCenter and retry, or remove the conflicting port group if it exists on another switch."
                        Write-LogMessage -Type ERROR -Message $err
                        throw [VcfDeploymentException]::new($err)
                    }
                    break
                }
                if ($pgErr -match "Operation is not valid due to the current state of the object" -and $mgmtPgAttempt -lt $MaxAttempts) {
                    Write-LogMessage -Type WARNING -Message "Management port group creation failed (attempt $mgmtPgAttempt of $MaxAttempts): $pgErr. Waiting $RetryDelaySeconds s before retry."
                    Start-Sleep -Seconds $RetryDelaySeconds
                    $mgmtPgAttempt++
                } else {
                    throw
                }
            }
        } while ($mgmtPgAttempt -le $MaxAttempts)
    }
    if (-not $mgmtPortGroup) {
        $err = "Deployment failed. Could not get or create management port group `"$ManagementPortGroupName`" on VDS `"$VdsName`"."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
    return $mgmtPortGroup
}
function Invoke-ClearVmk0TrafficFlags {

    <#
        .SYNOPSIS
        Removes vMotion, vSAN, and vSAN-witness traffic designations from a VMkernel adapter.

        .DESCRIPTION
        Attempts to clear all three traffic flags in a single Set-VMHostNetworkAdapter call. When the build
        rejects that parameter combination, falls back to clearing vMotion+vSAN together, then each flag
        individually. All failures are non-fatal: they are logged at WARNING level and the function returns
        normally so the caller can continue the migration.

        .PARAMETER HostDisplay
        Display name of the host; used in log messages.

        .PARAMETER Vmk0
        The VMkernel adapter (vmk0) to update.

        .EXAMPLE
        Invoke-ClearVmk0TrafficFlags -HostDisplay "esx01.lab" -Vmk0 $vmk0Adapter

        .NOTES
        Designed to be called immediately after vmk0 is migrated to the VDS, before removing the standard
        switch, to ensure vmk0 carries only management traffic on the new distributed port group.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$HostDisplay,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$Vmk0
    )

    # Ensure vmk0 is management-only (no vMotion, vSAN, or vSAN witness traffic). Prefer single
    # Set-VMHostNetworkAdapter call. Some builds reject all three parameters together; fallback tries
    # VMotion+Vsan then Witness, then each flag in its own try/catch so one failure does not prevent others.
    try {
        $vmk0Cleared = $false
        try {
            Set-VMHostNetworkAdapter -VirtualNic $Vmk0 -VMotionEnabled $false -VsanTrafficEnabled $false -VsanWitnessEnabled $false -Confirm:$false -WarningAction SilentlyContinue -ErrorAction Stop 3>$null | Out-Null
            $vmk0Cleared = $true
        } catch {
            if ($_.Exception.Message -notmatch "Parameter set cannot be resolved|cannot be used together|insufficient number of parameters|parameter cannot be found") {
                throw
            }
            Write-LogMessage -Type DEBUG -Message "Set-VMHostNetworkAdapter with all three traffic flags failed; trying fallbacks: $($_.Exception.Message)."
        }
        if (-not $vmk0Cleared) {
            try {
                Set-VMHostNetworkAdapter -VirtualNic $Vmk0 -VMotionEnabled $false -VsanTrafficEnabled $false -Confirm:$false -WarningAction SilentlyContinue -ErrorAction Stop 3>$null | Out-Null
                $vmk0Cleared = $true
            } catch {
                Write-LogMessage -Type DEBUG -Message "Set-VMHostNetworkAdapter VMotion+Vsan false failed: $($_.Exception.Message)."
            }
        }
        if (-not $vmk0Cleared) {
            try {
                Set-VMHostNetworkAdapter -VirtualNic $Vmk0 -VsanWitnessEnabled $false -Confirm:$false -WarningAction SilentlyContinue -ErrorAction Stop 3>$null | Out-Null
            } catch {
                Write-LogMessage -Type DEBUG -Message "Set-VMHostNetworkAdapter VsanWitnessEnabled false failed: $($_.Exception.Message)."
            }
            try {
                Set-VMHostNetworkAdapter -VirtualNic $Vmk0 -VMotionEnabled $false -Confirm:$false -WarningAction SilentlyContinue -ErrorAction Stop 3>$null | Out-Null
            } catch {
                Write-LogMessage -Type DEBUG -Message "Set-VMHostNetworkAdapter VMotionEnabled false failed: $($_.Exception.Message)."
            }
            try {
                Set-VMHostNetworkAdapter -VirtualNic $Vmk0 -VsanTrafficEnabled $false -Confirm:$false -WarningAction SilentlyContinue -ErrorAction Stop 3>$null | Out-Null
            } catch {
                Write-LogMessage -Type DEBUG -Message "Set-VMHostNetworkAdapter VsanTrafficEnabled false failed: $($_.Exception.Message)."
            }
        }
        Write-LogMessage -Type DEBUG -Message "Ensured vmk0 is management-only (vMotion/vSAN/vSAN witness disabled) on host `"$HostDisplay`"."
    } catch {
        Write-LogMessage -Type WARNING -Message "Could not clear vMotion/vSAN from vmk0 on host `"$HostDisplay`" (non-fatal): $($_.Exception.Message)."
    }
}
function Invoke-MigrateVmk0ToVds {

    <#
        .SYNOPSIS
        Performs the atomic vmk0 migration from the management vSS to a VDS port group.

        .DESCRIPTION
        Optionally adds the first unused pNIC to the VDS if the host has no NIC there yet, moves vmk0
        to the distributed management port group, normalizes the MTU, clears vMotion/vSAN traffic flags,
        removes the now-empty standard switch, and adds remaining pNIC uplinks to the VDS.

        .PARAMETER EffectiveMgmtVlanId
        VLAN ID used for the log preflight message.

        .PARAMETER FirstUnused
        Name of the first unused NIC that is not yet on the VDS and will be added as the initial uplink.

        .PARAMETER HostAlreadyHasPnicOnVds
        When true, skips the first-unused-NIC add step (a pNIC is already on the VDS).

        .PARAMETER HostDisplay
        Display name of the host for log messages.

        .PARAMETER ManagementPortGroupName
        Name of the management distributed port group; passed directly to Set-VMHostNetworkAdapter.

        .PARAMETER MgmtInfo
        Management VSS information from Get-ManagementVSwitchInfo; contains ManagementVmkernel and StandardSwitch.

        .PARAMETER NicNames
        Array of NIC names for the target VDS uplink set.

        .PARAMETER ReclaimedPnicName
        Name of a pNIC reclaimed from the vSS uplinks; passed through to Invoke-AddUplinkToVds.

        .PARAMETER VdsName
        VDS name for log messages and Invoke-AddUplinkToVds.

        .PARAMETER VdsObject
        VDS object used for pNIC and port-group operations.

        .PARAMETER VMHost
        ESX host object.

        .PARAMETER VssPnicsToReclaimAfterVssRemoval
        List of pNIC names that become available once the vSS is removed.

        .EXAMPLE
        Invoke-MigrateVmk0ToVds -EffectiveMgmtVlanId 100 -FirstUnused "vmnic1" -HostAlreadyHasPnicOnVds $false -HostDisplay "esx01.lab" -ManagementPortGroupName "Management" -MgmtInfo $mgmtInfo -NicNames @("vmnic0","vmnic1") -ReclaimedPnicName "" -VdsName "VDS-edge1" -VdsObject $vds -VMHost $vmHost -VssPnicsToReclaimAfterVssRemoval @()

        .NOTES
        Sets $Script:DidMigrateVmk0ToVdsThisRun = $true after the Set-VMHostNetworkAdapter call succeeds.
        The caller is responsible for ensuring Invoke-EnsureMgmtPortGroupOnVds succeeded before calling this function.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateRange(0, 4094)] [Int]$EffectiveMgmtVlanId,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$FirstUnused,
        [Parameter(Mandatory = $true)] [Bool]$HostAlreadyHasPnicOnVds,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$HostDisplay,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ManagementPortGroupName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSCustomObject]$MgmtInfo,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object[]]$NicNames,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [String]$ReclaimedPnicName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VdsName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$VdsObject,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$VMHost,
        [Parameter(Mandatory = $false)] [AllowNull()] [Object]$VssPnicsToReclaimAfterVssRemoval
    )

    if (-not $HostAlreadyHasPnicOnVds) {
        # Add first unused NIC to VDS so we have connectivity before moving vmk0.
        $pnicToAdd = Get-VMHostNetworkAdapter -VMHost $VMHost -Physical -Name $FirstUnused -Server $Script:vCenterName -ErrorAction Stop
        $null = $VdsObject | Add-VDSwitchPhysicalNetworkAdapter -VMHostPhysicalNic $pnicToAdd -Server $Script:vCenterName -Confirm:$false -WarningAction SilentlyContinue -ErrorAction Stop
        Write-LogMessage -Type DEBUG -Message "Added pNIC `"$FirstUnused`" to VDS `"$VdsName`" on host `"$HostDisplay`"."
    }

    # Log the full vmk0 migration picture before the atomic move. If Set-VMHostNetworkAdapter rolls back
    # with "disconnected the host", this block surfaces the VLAN, IP, and uplink pNIC for rapid diagnosis.
    $vmk0PreMigrate = $MgmtInfo.ManagementVmkernel
    $vmk0Ip = if ($vmk0PreMigrate -and $vmk0PreMigrate.PSObject.Properties["IP"]) { $vmk0PreMigrate.IP } else { "unknown" }
    $uplinkSummary = if ($HostAlreadyHasPnicOnVds) {
        $existingVdsPnics = @(Get-PhysicalNicsOnVdsForHost -VMHost $VMHost -VDSwitch $VdsObject -Server $Script:vCenterName)
        ($existingVdsPnics | Select-Object -ExpandProperty Name) -join ", "
    } else {
        $FirstUnused
    }
    Write-LogMessage -Type DEBUG -Message "Host `"$HostDisplay`" vmk0 migration: moving vmk0 IP=$vmk0Ip from vSS `"$($MgmtInfo.StandardSwitch.Name)`" to VDS `"$VdsName`" port group `"$ManagementPortGroupName`" (VLAN $EffectiveMgmtVlanId) via uplink pNIC `"$uplinkSummary`". A rollback error here means pNIC `"$uplinkSummary`" cannot reach the management network — verify physical switch VLAN and cabling."

    # Migrate vmk0 to the distributed port group (same IP preserved by PowerCLI). VCF PowerCLI 9 does not support -Server on Set-VMHostNetworkAdapter. Use -Confirm:$false to avoid interactive prompt.
    # PowerCLI's argument-transformation for -PortGroup accesses .VirtualSwitch on VmwareVDPortgroup during parameter binding — before -WarningAction takes effect.
    # 3>$null (warning-stream redirect) applies at the call-site level including binding and is the only reliable suppression for this class of warning.
    $vmk0 = $MgmtInfo.ManagementVmkernel
    Set-VMHostNetworkAdapter -VirtualNic $vmk0 -PortGroup $ManagementPortGroupName -Confirm:$false -WarningAction SilentlyContinue -ErrorAction Stop 3>$null | Out-Null
    $Script:DidMigrateVmk0ToVdsThisRun = $true
    Write-LogMessage -Type DEBUG -Message "Migrated management (vmk0) to VDS `"$VdsName`" port group `"$ManagementPortGroupName`" on host `"$HostDisplay`"."
    $mgmtMtu = 1500
    $currentMtu = $null
    if ($vmk0.PSObject.Properties["Mtu"]) { $currentMtu = $vmk0.Mtu }
    if ($null -ne $currentMtu -and [Int]$currentMtu -ne $mgmtMtu) {
        try {
            $null = Set-VMHostNetworkAdapter -VirtualNic $vmk0 -Mtu $mgmtMtu -Confirm:$false -WarningAction SilentlyContinue -ErrorAction Stop 3>$null
            Write-LogMessage -Type DEBUG -Message "Set vmk0 MTU to $mgmtMtu on host `"$HostDisplay`" (was $currentMtu; mgmt is always 1500)."
        } catch {
            Write-LogMessage -Type WARNING -Message "Could not set vmk0 MTU to $mgmtMtu on host `"$HostDisplay`": $($_.Exception.Message)."
        }
    }

    Invoke-ClearVmk0TrafficFlags -HostDisplay $HostDisplay -Vmk0 $vmk0

    # Confirm standard switch has no VMs, then remove it.
    $stdSwitch = $MgmtInfo.StandardSwitch
    $portGroupsOnSwitch = Get-VirtualPortGroup -VirtualSwitch $stdSwitch -Server $Script:vCenterName -ErrorAction SilentlyContinue
    foreach ($pg in $portGroupsOnSwitch) {
        # Use .NetworkName (a direct string property) rather than .Network.Name — accessing .Network
        # returns a VmwareVDPortgroup which triggers the PowerCLI VirtualSwitch deprecation warning
        # before -WarningAction can take effect.
        $vmsOnPg = Get-VM -Server $Script:vCenterName -Location $VMHost -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Where-Object {
            $_.NetworkAdapters | Where-Object { $_.NetworkName -eq $pg.Name }
        }
        if ($vmsOnPg -and @($vmsOnPg).Count -gt 0) {
            $vmNames = @($vmsOnPg) | Select-Object -ExpandProperty Name
            $err = "Cannot remove standard switch `"$($stdSwitch.Name)`" on host `"$HostDisplay`": port group `"$($pg.Name)`" has $($vmNames.Count) VM(s): $($vmNames -join ', ')."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
    }
    Remove-VirtualSwitch -VirtualSwitch $stdSwitch -Server $Script:vCenterName -Confirm:$false -ErrorAction Stop
    Write-LogMessage -Type DEBUG -Message "Removed standard switch `"$($stdSwitch.Name)`" from host `"$HostDisplay`"."

    Invoke-AddUplinkToVds `
        -FirstUnusedNicName $FirstUnused `
        -HostDisplay        $HostDisplay `
        -NicNames           $NicNames `
        -ReclaimedPnicName  $ReclaimedPnicName `
        -StdSwitchName      $stdSwitch.Name `
        -VdsName            $VdsName `
        -VdsObject          $VdsObject `
        -VMHost             $VMHost `
        -VssPnicsToReclaim  $VssPnicsToReclaimAfterVssRemoval

    # Active/standby teaming for the VDS is configured by the caller via Set-VDSUplinkTeamingActiveStandby
    # after all hosts complete migration. No per-host teaming step is needed here.
}
function Invoke-Vmk0VdsMigrationIdempotencyCheck {

    <#
        .SYNOPSIS
        Checks whether host management vmk0 is already on the target VDS and skips migration if so.

        .DESCRIPTION
        Returns $true (and performs an MTU correction to 1500 if needed) when vmk0 is already on
        the target VDS, allowing the caller to skip the full migration path. Uses two detection
        methods: a direct portgroup ID lookup via Get-VDPortgroup -Id, and a fallback scan of all
        DPGs on the VDS. Returns $false when the VDS does not exist, vmk0 is not present on the
        host, or vmk0 is not on the target VDS.

        .PARAMETER HostDisplay
        Display name of the host used in log messages.

        .PARAMETER Server
        vCenter server name for all PowerCLI calls.

        .PARAMETER VdsName
        Name of the target VDS.

        .PARAMETER VMHost
        The VMHost object.

        .OUTPUTS
        [Bool] $true if vmk0 is already on the target VDS (migration skipped), $false otherwise.

        .EXAMPLE
        if (Invoke-Vmk0VdsMigrationIdempotencyCheck -HostDisplay "esx01" -Server $vCenterName -VdsName "VDS-edge1" -VMHost $vmHostObj) {
            return
        }

        .NOTES
        Invoked exclusively by Invoke-MigrateHostManagementToVds. Not intended for direct use.
        VmwareVDPortgroup objects are never passed to cmdlet parameters: VCF PowerCLI 9 accesses
        .VirtualSwitch internally during parameter binding and emits a deprecation warning before
        -WarningAction takes effect. DPG IDs and names are collected into sets, and vmk0 is matched
        using three checks in the same order as Remove-NonVmk0VmkernelInterfacesFromVds:
        (1) NetworkName string against DPG names on the VDS.
        (2) Spec.PortGroup MoRef against DPG IDs (standard-switch adapters only).
        (3) Spec.DistributedVirtualPort.PortgroupKey against DPG IDs, then SwitchUuid match — the
            definitive check for VDS-backed adapters where checks (1) and (2) return empty in VCF PowerCLI 9.
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$HostDisplay,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Server,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VdsName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [PSObject]$VMHost
    )

    $vdsObject = Get-VdsObjectByName -Name $VdsName -Server $Server
    if (-not $vdsObject) { return $false }

    $vmk0 = Get-VmkernelAdaptersOnHost -VMHost $VMHost -Server $Server | Where-Object { $_.Name -eq "vmk0" }
    if (-not $vmk0) { return $false }

    # Collect DPG IDs (prefer MoRef.Value — matches DistributedVirtualPort.PortgroupKey format)
    # and names from this VDS. No VmwareVDPortgroup objects are retained; names and IDs are
    # extracted immediately so no object escapes to a later cmdlet parameter that would trigger
    # the .VirtualSwitch deprecation warning.
    $dpgIds   = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $dpgNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    Get-VDPortgroup -VDSwitch $vdsObject -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike "*DVUplinks*" } |
        ForEach-Object {
            $pgId = if ($_.ExtensionData -and $_.ExtensionData.MoRef -and $_.ExtensionData.MoRef.Value) { $_.ExtensionData.MoRef.Value } elseif ($_.Id) { $_.Id } else { $null }
            if ($pgId) { [Void]$dpgIds.Add($pgId) }
            if (-not [String]::IsNullOrWhiteSpace($_.Name)) { [Void]$dpgNames.Add($_.Name) }
        }

    # VDS SwitchUuid for the final guard in Check 3 (handles partial-removal edge cases).
    $vdsSwitchUuid = if ($vdsObject.ExtensionData -and $vdsObject.ExtensionData.Config) { $vdsObject.ExtensionData.Config.Uuid } else { $null }

    $vmk0OnTargetVds = $false

    # Check 1: NetworkName string match. Works for standard-switch adapters and for VDS adapters
    # when PowerCLI resolves the DPG name correctly.
    $vmk0NetworkName = if ($vmk0.PSObject.Properties["NetworkName"]) { $vmk0.NetworkName } else { $null }
    if (-not [String]::IsNullOrWhiteSpace($vmk0NetworkName) -and $dpgNames.Contains($vmk0NetworkName)) {
        $vmk0OnTargetVds = $true
    }

    # Check 2: Spec.PortGroup MoRef match. Populated for standard-switch VMkernel adapters;
    # null for VDS-backed adapters, so this check is skipped when vmk0 is on a VDS.
    if (-not $vmk0OnTargetVds -and $vmk0.ExtensionData -and $vmk0.ExtensionData.Spec -and $vmk0.ExtensionData.Spec.PortGroup) {
        $pgRef = $vmk0.ExtensionData.Spec.PortGroup
        $pgId  = if ($pgRef.Value) { $pgRef.Value } else { [String]$pgRef }
        if (-not [String]::IsNullOrWhiteSpace($pgId) -and $dpgIds.Contains($pgId)) {
            $vmk0OnTargetVds = $true
        }
    }

    # Check 3: DistributedVirtualPort.PortgroupKey — the definitive identifier for VDS-backed
    # adapters. In VCF PowerCLI 9, NetworkName and Spec.PortGroup are both empty for VDS-connected
    # VMkernel adapters, so checks (1) and (2) always fail when vmk0 is on the VDS. This check
    # detects that case (e.g. after -CleanUp Supervisor which leaves the VDS and vmk0 in place).
    if (-not $vmk0OnTargetVds -and $vmk0.ExtensionData -and $vmk0.ExtensionData.Spec -and $vmk0.ExtensionData.Spec.DistributedVirtualPort) {
        $dvp   = $vmk0.ExtensionData.Spec.DistributedVirtualPort
        $pgKey = $dvp.PortgroupKey
        if (-not [String]::IsNullOrWhiteSpace($pgKey) -and $dpgIds.Contains($pgKey)) {
            $vmk0OnTargetVds = $true
        }
        # Final guard: match by SwitchUuid when PortgroupKey is absent or not in the set
        # (handles edge cases where the port group was partially removed from the VDS).
        if (-not $vmk0OnTargetVds -and -not [String]::IsNullOrWhiteSpace($vdsSwitchUuid) -and -not [String]::IsNullOrWhiteSpace($dvp.SwitchUuid)) {
            $vmk0OnTargetVds = ($dvp.SwitchUuid -eq $vdsSwitchUuid)
        }
    }

    if (-not $vmk0OnTargetVds) { return $false }

    Write-LogMessage -Type INFO -Message "Host `"$HostDisplay`" management (vmk0) is already on VDS `"$VdsName`". Skipping migration."
    $currentMtu = $null
    if ($vmk0.PSObject.Properties["Mtu"]) { $currentMtu = $vmk0.Mtu }
    if ($null -ne $currentMtu -and [Int]$currentMtu -ne 1500) {
        try {
            $null = Set-VMHostNetworkAdapter -VirtualNic $vmk0 -Mtu 1500 -Confirm:$false -WarningAction SilentlyContinue -ErrorAction Stop
            Write-LogMessage -Type DEBUG -Message "Set vmk0 MTU to 1500 on host `"$HostDisplay`" (was $currentMtu)."
        } catch {
            Write-LogMessage -Type WARNING -Message "Could not set vmk0 MTU to 1500 on host `"$HostDisplay`": $($_.Exception.Message)."
        }
    }
    return $true
}
function Invoke-MigrateHostManagementToVds {

    <#
        .SYNOPSIS
        Migrates the host management VMkernel (vmk0) from a standard switch to the VDS with the same IP, then reclaims the pNIC(s).

        .DESCRIPTION
        Handles management vSwitches with one or more physical uplinks. Adds the first unused NIC from
        NicList (or, when all NicList pNICs are already on the management vSS, atomically migrates the
        first NicList pNIC off the vSS) to the VDS, creates a management distributed port group,
        migrates vmk0 to it (same IP), removes the standard switch after confirming no VMs (or only
        VM Network with no VMs), adds all reclaimed pNICs to the VDS, and sets active/passive teaming.

        .PARAMETER VMHost
        The VMHost object.

        .PARAMETER VdsName
        Name of the VDS (must already exist; host must already be added to the VDS).

        .PARAMETER NicList
        Array of NIC config objects (e.g. from common.nicList with Name property). The first unused NIC
        (or first NicList pNIC on the management vSS) is used for the initial VDS attach; any remaining
        pNICs freed when the vSS is removed are added afterward.

        .PARAMETER ManagementPortGroupName
        Name for the management distributed port group. Default "mgmt".

        .PARAMETER ManagementVlanId
        Fallback VLAN ID for the management port group when the host's current vmk0 port group VLAN cannot be read. Default 0. The VLAN used when creating the DPG is normally sourced from the host's existing management port group (Get-ManagementVSwitchInfo) so the host is not disconnected by a VLAN change.

        .NOTES
        Throws if vmk0 is not on a standard switch, if the management vSwitch has no pNIC uplinks, or if migration fails.
        PowerCLI accesses .VirtualSwitch on VmwareVDPortgroup during argument transformation (parameter binding), before -WarningAction takes effect. -WarningAction SilentlyContinue on its own cannot suppress this class of warning. The definitive fix is 3>$null (warning-stream redirect) at each call site; it applies at call-site scope including binding. Applied to Set-VMHostNetworkAdapter -PortGroup and Get-VMHostNetworkAdapter -PortGroup calls. Add-VDSwitchPhysicalNetworkAdapter and Get-VDPortgroup calls use -WarningAction SilentlyContinue (those warnings come from cmdlet execution, not binding). Active/standby teaming is handled by the caller (Set-VDSUplinkTeamingActiveStandby) after all hosts migrate; no per-host teaming step is performed here.
    
        .EXAMPLE
        Invoke-MigrateHostManagementToVds -NicList "value" -VdsName "resource-name" -VMHost $vmHostObject
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$ManagementPortGroupName = "mgmt",
        [Parameter(Mandatory = $false)] [ValidateRange(0, 4094)] [Int]$ManagementVlanId = 0,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [System.Object[]]$NicList,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VdsName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [PSObject]$VMHost
    )

    $hostDisplay = $VMHost.Name
    $nicNames = [System.Collections.Generic.List[String]]::new()
    foreach ($item in $NicList) {
        $name = if ($item -is [String]) { $item.Trim() } else { $item.Name }
        if (-not [String]::IsNullOrWhiteSpace($name)) { $nicNames.Add($name) }
    }
    if ($nicNames.Count -eq 0) {
        $err = "Deployment failed. NicList is empty for host `"$hostDisplay`"."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }

    # If vmk0 is already on the target VDS, skip migration (idempotent). Required for re-runs (e.g. -Force) when cluster and VDS already exist.
    if (Invoke-Vmk0VdsMigrationIdempotencyCheck -HostDisplay $hostDisplay -Server $Script:vCenterName -VdsName $VdsName -VMHost $VMHost) {
        return
    }

    $mgmtInfo = Get-ManagementVSwitchInfo -VMHost $VMHost
    if (-not $mgmtInfo) {
        $err = "Host `"$hostDisplay`": vmk0 not found on a standard switch; cannot migrate management to VDS `"$VdsName`"."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
    if ($mgmtInfo.PnicNames.Count -eq 0) {
        $err = "Host `"$hostDisplay`": management standard switch `"$($mgmtInfo.StandardSwitch.Name)`" has no pNIC uplinks; cannot migrate."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }

    # Use the VLAN from the host's current management port group so the DPG matches and we do not disconnect the host.
    $effectiveMgmtVlanId = if ($null -ne $mgmtInfo.PSObject.Properties["ManagementPortGroupVlanId"]) { $mgmtInfo.ManagementPortGroupVlanId } else { $ManagementVlanId }
    $vlanSource = if ($null -ne $mgmtInfo.PSObject.Properties["ManagementPortGroupVlanId"]) { "host vSS port group" } else { "parameter default ($ManagementVlanId)" }
    Write-LogMessage -Type DEBUG -Message "Host `"$hostDisplay`" management migration pre-flight: VLAN = $effectiveMgmtVlanId (source: $vlanSource); vSS uplink(s) currently carrying management = $($mgmtInfo.PnicNames -join ', '); NicList pNIC(s) targeted for VDS = $($nicNames -join ', '). Ensure the NicList pNIC(s) are on the same management network segment and physical switch VLAN as the existing vSS uplinks."

    $vdsObject = Get-VdsObjectByName -Name $VdsName -Server $Script:vCenterName
    if (-not $vdsObject) {
        $err = "VDS `"$VdsName`" not found on vCenter `"$Script:vCenterName`"; cannot complete management migration for host `"$hostDisplay`"."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }

    $uplinkInfo = Get-MgmtVssUplinkForMigration `
        -EffectiveMgmtVlanId $effectiveMgmtVlanId `
        -HostDisplay         $hostDisplay `
        -MgmtInfo            $mgmtInfo `
        -NicNames            $nicNames `
        -VdsObject           $vdsObject `
        -VMHost              $VMHost

    $firstUnused                     = $uplinkInfo.FirstUnused
    $hostAlreadyHasPnicOnVds         = $uplinkInfo.HostAlreadyHasPnicOnVds
    $vssPnicsToReclaimAfterVssRemoval = $uplinkInfo.VssPnicsToReclaimAfterVssRemoval
    $reclaimedPnicName               = $uplinkInfo.ReclaimedPnicName

    Invoke-EnsureMgmtPortGroupOnVds `
        -EffectiveMgmtVlanId    $effectiveMgmtVlanId `
        -ManagementPortGroupName $ManagementPortGroupName `
        -VdsName                $VdsName `
        -VdsObject              $vdsObject | Out-Null

    Invoke-MigrateVmk0ToVds `
        -EffectiveMgmtVlanId             $effectiveMgmtVlanId `
        -FirstUnused                     $firstUnused `
        -HostAlreadyHasPnicOnVds         $hostAlreadyHasPnicOnVds `
        -HostDisplay                     $hostDisplay `
        -ManagementPortGroupName         $ManagementPortGroupName `
        -MgmtInfo                        $mgmtInfo `
        -NicNames                        $nicNames `
        -ReclaimedPnicName               $reclaimedPnicName `
        -VdsName                         $VdsName `
        -VdsObject                       $vdsObject `
        -VMHost                          $VMHost `
        -VssPnicsToReclaimAfterVssRemoval $vssPnicsToReclaimAfterVssRemoval
}
function Invoke-VDSCreation {

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
        Error Handling: Deployment helper. Returns VDS object on success. Throws VcfDeploymentException
        on failure after logging. Callers in orchestrators are protected by the outer try/catch.
    #>

    [CmdletBinding()]
    [OutputType([Object])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [PSObject]$DatacenterObject,
        [Parameter(Mandatory = $false)] [ValidateRange(1500, 9190)] [Int]$Mtu = 9000,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$NumUplinks,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 10)] [Int]$VdsCreationRetryCount = 5,
        [Parameter(Mandatory = $false)] [ValidateRange(5, 120)] [Int]$VdsCreationRetryDelaySeconds = 15,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VdsName
    )

    Write-LogMessage -Type DEBUG -Message "Entered Invoke-VDSCreation function..."

    Assert-VcenterConnected

    $numUplinksInt = [Int]$NumUplinks
    try {
        $vdsObject = Get-VDSwitch -Name $VdsName -Server $Script:vCenterName -WarningAction SilentlyContinue -ErrorAction SilentlyContinue

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
            $err = "Failed to retrieve VDS `"$VdsName`" after creation."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
    } catch [VcfDeploymentException] {
        throw  # already logged and typed — propagate without re-wrapping
    } catch {
        if ($null -ne $Script:LogMessagePending) {
            Write-LogMessage -Type ERROR -CompletePending -Message " Failed."
        }
        $err = "Failed to create VDS `"$VdsName`": $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
}
function Add-HostToVDS {

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

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [PSObject]$Hostname,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VdsName
    )

    Write-LogMessage -Type DEBUG -Message "Entered Add-HostToVDS function..."

    try {
        Add-VDSwitchVMHost -VMHost $Hostname -VDSwitch $VdsName -Server $Script:vCenterName -WarningAction SilentlyContinue -ErrorAction Stop | Out-Null
    } catch {
        $errMsg = $_.Exception.Message

        if ($errMsg -match "is already added to VDSwitch") {
            Write-LogMessage -Type INFO -Message "The ESX host `"$Hostname`" is already attached to VDS `"$VdsName`". Skipping attachment."
        } elseif ($errMsg -match "already exists") {
            Write-LogMessage -Type INFO -Message "The ESX host `"$Hostname`" is already associated with VDS `"$VdsName`" (already exists). Skipping attachment."
        } else {
            return Write-ErrorAndReturn -ErrorMessage "Unexpected error adding ESX host `"$Hostname`" to VDS `"$VdsName`": $_" -ErrorCode "ERR_VDS_UNEXPECTED"
        }
    }
}
function New-VDSPortGroups {

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
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [System.Object[]]$PortGroups,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VdsName
    )

    Write-LogMessage -Type DEBUG -Message "Entered New-VDSPortGroups function..."

    Assert-VcenterConnected

    foreach ($portGroup in $PortGroups) {
        try {
            # Query the target VDS directly first — avoids accessing the deprecated .VDSwitch property
            # on a server-wide Get-VDPortgroup result to determine VDS membership.
            # 3>$null: passing a string to -VDSwitch triggers a binding-time warning that -WarningAction cannot reach.
            $existingOnTargetVds = Get-VDPortgroup -Name $($portGroup.Name) -VDSwitch $VdsName -Server $Script:vCenterName -WarningAction SilentlyContinue -ErrorAction SilentlyContinue 3>$null

            if ($existingOnTargetVds) {
                # Handle case where multiple port groups with same name exist on the target VDS.
                if (@($existingOnTargetVds).Count -gt 1) {
                    $err = "Two or more port groups named `"$($portGroup.Name)`" were found on VDS `"$VdsName`" in vCenter `"$Script:vCenterName`". Please delete the duplicate port groups or update your configuration."
                    Write-LogMessage -Type ERROR -Message $err
                    throw [VcfDeploymentException]::new($err)
                }
                try {
                    $existingVlanId = $existingOnTargetVds.ExtensionData.Config.DefaultPortConfig.Vlan.VlanId
                } catch {
                    $existingVlanId = "Unknown"
                }
                Write-LogMessage -Type INFO -Message "Port group `"$($portGroup.Name)`" already exists on VDS `"$VdsName`" with VLAN ID $existingVlanId. Skipping creation."
            } else {
                # Not on the target VDS; check if it exists on any other VDS (to warn before skipping).
                $existingElsewhere = Get-VDPortgroup -Name $($portGroup.Name) -Server $Script:vCenterName -WarningAction SilentlyContinue -ErrorAction SilentlyContinue 3>$null
                if ($existingElsewhere) {
                    if (@($existingElsewhere).Count -gt 1) {
                        $err = "Two or more port groups named `"$($portGroup.Name)`" were found in vCenter `"$Script:vCenterName`". Please delete the duplicate port groups or update your configuration."
                        Write-LogMessage -Type ERROR -Message $err
                        throw [VcfDeploymentException]::new($err)
                    }
                    try {
                        $existingVlanId = $existingElsewhere.ExtensionData.Config.DefaultPortConfig.Vlan.VlanId
                    } catch {
                        $existingVlanId = "Unknown"
                    }
                    # Resolve the actual VDS name via ExtensionData MoRef — avoids the deprecated .VDSwitch property.
                    $elseVdsMoRef = if ($existingElsewhere.ExtensionData -and $existingElsewhere.ExtensionData.Config -and $existingElsewhere.ExtensionData.Config.DistributedVirtualSwitch) { $existingElsewhere.ExtensionData.Config.DistributedVirtualSwitch.Value } else { $null }
                    $elseVdsName = if ($elseVdsMoRef) {
                        $elseVdsObj = Get-VDSwitch -Server $Script:vCenterName -WarningAction SilentlyContinue -ErrorAction SilentlyContinue 3>$null | Where-Object { $_.ExtensionData.MoRef.Value -eq $elseVdsMoRef } | Select-Object -First 1
                        if ($elseVdsObj) { $elseVdsObj.Name } else { $elseVdsMoRef }
                    } else { "unknown" }
                    Write-LogMessage -Type WARNING -Message "Port group `"$($portGroup.Name)`" already exists on VDS `"$elseVdsName`" with VLAN ID $existingVlanId but not on target VDS `"$VdsName`". Skipping creation to avoid conflicts."
                } else {
                    # Port group doesn't exist anywhere; create it.
                    Write-LogMessage -Type INFO -NoNewline -Message "Creating port group `"$($portGroup.Name)`" on VDS `"$VdsName`" with VLAN ID $($portGroup.VlanId)... "
                    New-VDPortgroup -Server $Script:vCenterName -Name $($portGroup.Name) -VDSwitch $VdsName -VlanId $($portGroup.VlanId) -NumPorts 128 -PortBinding Static -WarningAction SilentlyContinue -ErrorAction Stop 3>$null | Out-Null
                    Write-LogMessage -Type INFO -CompletePending -Message "Success"
                }
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
function Set-VDSUplinkTeamingActiveStandby {

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
    
        .EXAMPLE
        Set-VDSUplinkTeamingActiveStandby -VdsName "resource-name"
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$Server = $Script:vCenterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VdsName
    )

    Write-LogMessage -Type DEBUG -Message "Entered Set-VDSUplinkTeamingActiveStandby for VDS `"$VdsName`"."

    $vdsObject = Get-VDSwitch -Name $VdsName -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
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
        $policy = Get-VDSwitch -Name $VdsName -Server $Server -WarningAction SilentlyContinue -ErrorAction Stop | Get-VDUplinkTeamingPolicy -WarningAction SilentlyContinue -ErrorAction Stop
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
        Set-VDUplinkTeamingPolicy -Policy $policy -ActiveUplinkPort $activeUplink -StandbyUplinkPort $standbyUplink -LoadBalancingPolicy ExplicitFailover -EnableFailback $true -WarningAction SilentlyContinue -ErrorAction Stop | Out-Null
        Write-LogMessage -Type INFO -Message "VDS `"$VdsName`": configured active/standby teaming (active: $activeUplink, standby: $standbyUplink, failback enabled)."
    } catch {
        Write-LogMessage -Type WARNING -Message "Set-VDSUplinkTeamingActiveStandby: Could not set active/standby on VDS `"$VdsName`": $($_.Exception.Message)."
    }
}
function Assert-NicNotAssignedElsewhere {

    <#
    .SYNOPSIS
        Throws if any of the specified NICs are already assigned to a switch other than the target VDS.
    .DESCRIPTION
        Queries all standard vSwitches and all VDSes except the target VDS to build the set of pNIC
        names in use elsewhere on the host. Throws VcfDeploymentException for the first conflicting NIC
        so the caller can abort before touching the VDS.
    .PARAMETER Hostname
        The VMHost object to inspect.
    .PARAMETER HostDisplay
        Host name string used in error messages.
    .PARAMETER NicNames
        Array of NIC names to check.
    .PARAMETER VdsName
        Name of the target VDS to exclude from the conflict check.
    .EXAMPLE
        Assert-NicNotAssignedElsewhere -Hostname $host -HostDisplay "esx1.lab" -NicNames @("vmnic0","vmnic1") -VdsName "VDS-site1"
    .NOTES
        Uses $Script:vCenterName. Throws VcfDeploymentException on conflict.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$HostDisplay,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [PSObject]$Hostname,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [String[]]$NicNames,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VdsName
    )

    $assignedToOtherSwitches = [System.Collections.Generic.List[String]]::new()
    $stdSwitches = Get-VirtualSwitch -VMHost $Hostname -Standard -Server $Script:vCenterName -ErrorAction SilentlyContinue
    foreach ($sw in $stdSwitches) {
        $pnics = Get-VMHostNetworkAdapter -VMHost $Hostname -Physical -VirtualSwitch $sw -Server $Script:vCenterName -ErrorAction SilentlyContinue
        if ($pnics) { $assignedToOtherSwitches.AddRange([String[]]($pnics | Select-Object -ExpandProperty Name)) }
    }
    $otherVds = Get-VDSwitch -Server $Script:vCenterName -WarningAction SilentlyContinue -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne $VdsName }
    foreach ($vds in $otherVds) {
        $pnics = Get-VMHostNetworkAdapter -VMHost $Hostname -Physical -VirtualSwitch $vds -Server $Script:vCenterName -ErrorAction SilentlyContinue
        if ($pnics) { $assignedToOtherSwitches.AddRange([String[]]($pnics | Select-Object -ExpandProperty Name)) }
    }
    $assignedToOtherSwitches = $assignedToOtherSwitches | Select-Object -Unique

    foreach ($nicName in $NicNames) {
        if ($assignedToOtherSwitches -contains $nicName) {
            $err = "Network adapter `"$nicName`" on host `"$HostDisplay`" is already assigned to another switch. Unassign it before adding to VDS `"$VdsName`"."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
    }
}
function Add-PhysicalAdaptersToVDS {

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

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [PSObject]$Hostname,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [System.Object[]]$NicList,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VdsName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [PSObject]$VdsObject
    )

    Write-LogMessage -Type DEBUG -Message "Entered Add-PhysicalAdaptersToVDS function..."

    Assert-VcenterConnected

    try {
        # Normalize NicList to adapter names (support object with .Name or string). Fail if any entry has no name.
        $nicNames = [System.Collections.Generic.List[String]]::new()
        foreach ($item in $NicList) {
            $name = if ($item -is [String]) { $item.Trim() } else { $item.Name }
            if ([String]::IsNullOrWhiteSpace($name)) {
                $err = "NicList contains an entry with no Name. Each entry must be a string or an object with a Name property."
                Write-LogMessage -Type ERROR -Message $err
                throw [VcfDeploymentException]::new($err)
            }
            $nicNames.Add($name)
        }

        $hostDisplay = if ($Hostname.Name) { $Hostname.Name } else { [String]$Hostname }

        # Validate each NIC exists on the host.
        foreach ($nicName in $nicNames) {
            $adapter = Get-VMHostNetworkAdapter -VMHost $Hostname -Physical -Name $nicName -Server $Script:vCenterName -ErrorAction SilentlyContinue
            if (-not $adapter) {
                $err = "Network adapter `"$nicName`" does not exist on host `"$hostDisplay`"."
                Write-LogMessage -Type ERROR -Message $err
                throw [VcfDeploymentException]::new($err)
            }
        }

        Assert-NicNotAssignedElsewhere -Hostname $Hostname -HostDisplay $hostDisplay -NicNames $nicNames -VdsName $VdsName

        # Get currently assigned physical adapters on this VDS for this host (for idempotent skip).
        $assignedAdapters = @()
        try {
            $vdsHostConfig = $VdsObject.ExtensionData.Config.Host | Where-Object { $_.Host.Value -eq $Hostname.ExtensionData.MoRef.Value }
            if ($vdsHostConfig -and $vdsHostConfig.Config.Backing.PnicSpec) {
                $assignedAdapters = $vdsHostConfig.Config.Backing.PnicSpec | Select-Object -ExpandProperty PnicDevice
            }
        } catch {
            Write-LogMessage -Type DEBUG -Message "ExtensionData path for assigned adapters failed; trying Get-VMHostNetworkAdapter -VirtualSwitch."
        }
        if ($assignedAdapters.Count -eq 0) {
            $pnicsOnThisVds = Get-VMHostNetworkAdapter -VMHost $Hostname -Physical -VirtualSwitch $VdsObject -Server $Script:vCenterName -ErrorAction SilentlyContinue
            if ($pnicsOnThisVds) {
                $assignedAdapters = @($pnicsOnThisVds | Select-Object -ExpandProperty Name)
                Write-LogMessage -Type DEBUG -Message "Retrieved $($assignedAdapters.Count) adapter(s) already on VDS `"$VdsName`" for host `"$hostDisplay`" via Get-VMHostNetworkAdapter."
            }
        }

        foreach ($nicName in $nicNames) {
            if ($assignedAdapters -contains $nicName) {
                Write-LogMessage -Type DEBUG -Message "Network adapter `"$nicName`" is already attached to VDS `"$VdsName`" on host `"$hostDisplay`"; skipping."
            } else {
                try {
                    $vmhostNetworkAdapter = Get-VMHostNetworkAdapter -VMHost $Hostname -Physical -Name $nicName -Server $Script:vCenterName -ErrorAction Stop
                    $VdsObject | Add-VDSwitchPhysicalNetworkAdapter -VMHostPhysicalNic $vmhostNetworkAdapter -Server $Script:vCenterName -Confirm:$false -WarningAction SilentlyContinue
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
function Get-VmkernelTrafficVdsNameForLayout {

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
    
        .EXAMPLE
        $vmkernelTrafficVdsNameForLayout = Get-VmkernelTrafficVdsNameForLayout -BaseVdsName "resource-name" -NumUplinks "value" -TrafficRole "value"
    #>

    [CmdletBinding()]
    [OutputType([String])]
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
function New-VmkernelForSegment {

    <#
        .SYNOPSIS
        Creates a VMkernel adapter for a single service segment on one host with the correct traffic flags.

        .DESCRIPTION
        Idempotency-aware: skips if a VMkernel already exists on the port group for this host. Otherwise,
        creates the VMkernel via New-VMHostNetworkAdapter, sets the traffic type flag (VMotionEnabled,
        VsanTrafficEnabled, or VsanWitnessEnabled), applies MTU, and configures the static IPv4 gateway
        for vSAN Witness VMkernels. The VsanTrafficEnabled and VsanWitnessEnabled fallback paths handle
        PowerCLI builds that reject multi-flag parameter sets.

        .PARAMETER GatewayAddress
        Static IPv4 gateway for vSAN Witness VMkernels. Ignored for vMotion and vSAN segments.

        .PARAMETER Ip
        IPv4 address to assign to the VMkernel. Must not be empty.

        .PARAMETER Netmask
        IPv4 subnet mask. Default "255.255.255.0".

        .PARAMETER PortGroup
        Distributed port group object to use for the idempotency check and creation.

        .PARAMETER PortGroupName
        Port group name string used for VMkernel creation and log messages.

        .PARAMETER Server
        vCenter server hostname.

        .PARAMETER ServiceName
        Traffic type: "vMotion", "vSAN", or "vSAN Witness".

        .PARAMETER VdsObject
        VDS object used for VMkernel creation (VirtualSwitch parameter of New-VMHostNetworkAdapter).

        .PARAMETER VMHost
        The ESX host on which to create the VMkernel.

        .PARAMETER VmkernelMtu
        MTU for the VMkernel (1500-9190). vSAN Witness always uses 1500 regardless of this parameter.
        Default is 9000.

        .EXAMPLE
        New-VmkernelForSegment -Ip "10.0.0.10" -Netmask "255.255.255.0" -PortGroup $dpg `
            -PortGroupName "vmotion-edge1" -Server "vc.lab" -ServiceName "vMotion" `
            -VdsObject $vds -VMHost $vmhost

        .NOTES
        Throws VcfDeploymentException when creation fails. Called exclusively from
        Add-VmkernelInterfacesFromNetworkingConfig.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [String]$GatewayAddress = "",
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Ip,
        [Parameter(Mandatory = $false)] [String]$Netmask = "255.255.255.0",
        [Parameter(Mandatory = $true)] [ValidateNotNull()] $PortGroup,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$PortGroupName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Server,
        [Parameter(Mandatory = $true)] [ValidateSet("vMotion", "vSAN", "vSAN Witness")] [String]$ServiceName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] $VdsObject,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] $VMHost,
        [Parameter(Mandatory = $false)] [ValidateRange(1500, 9190)] [Int]$VmkernelMtu = 9000
    )

    $hostName = $VMHost.Name
    $existingVmk = Get-VMHostNetworkAdapter -VMHost $VMHost -VMKernel -PortGroup $PortGroupName -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
    if ($existingVmk) {
        if ($ServiceName -eq "vSAN Witness" -and -not [String]::IsNullOrWhiteSpace($GatewayAddress)) {
            $exIp = $null
            $exMask = $null
            if ($existingVmk | Get-Member -Name IP -MemberType Properties -ErrorAction SilentlyContinue) { $exIp = [String]$existingVmk.IP }
            if ($existingVmk | Get-Member -Name SubnetMask -MemberType Properties -ErrorAction SilentlyContinue) { $exMask = [String]$existingVmk.SubnetMask }
            if ($exIp -and $exMask) {
                Set-VmkernelIpv4StaticGatewayViaEsxcli -GatewayAddress $GatewayAddress -Ipv4Address $exIp -Server $Server -SubnetMask $exMask -VMHost $VMHost -VmkernelName $existingVmk.Name
            } else {
                Write-LogMessage -Type WARNING -Message "Witness gateway is set in JSON but IP/SubnetMask could not be read from existing VMkernel `"$($existingVmk.Name)`" on `"$hostName`"; set the default gateway on that VMkernel manually if witness traffic requires it."
            }
        }
        Write-LogMessage -Type DEBUG -Message "Host `"$hostName`" already has a VMkernel on port group `"$PortGroupName`"; skipping create for service `"$ServiceName`"."
        return
    }
    $createParams = @{
        VMHost        = $VMHost
        PortGroup     = $PortGroupName
        IP            = $Ip
        SubnetMask    = $Netmask
        VirtualSwitch = $VdsObject
        Confirm       = $false
        ErrorAction   = 'Stop'
    }
    if ($ServiceName -eq "vMotion") { $createParams["VMotionEnabled"] = $true }
    if ($ServiceName -eq "vSAN")    { $createParams["VsanTrafficEnabled"] = $true }
    try {
        $newVmk = $null
        try {
            $newVmk = New-VMHostNetworkAdapter @createParams -WarningAction SilentlyContinue
        } catch {
            if ($ServiceName -eq "vSAN" -and $_.Exception.Message -match "Parameter set cannot be resolved|cannot be used together|insufficient number of parameters") {
                $createParamsWithoutVsan = @{
                    VMHost        = $VMHost
                    PortGroup     = $PortGroupName
                    IP            = $Ip
                    SubnetMask    = $Netmask
                    VirtualSwitch = $VdsObject
                    Confirm       = $false
                    ErrorAction   = 'Stop'
                }
                $newVmk = New-VMHostNetworkAdapter @createParamsWithoutVsan -WarningAction SilentlyContinue
                $null = Set-VMHostNetworkAdapter -VirtualNic $newVmk -VsanTrafficEnabled $true -Confirm:$false -WarningAction SilentlyContinue -ErrorAction Stop
            } else {
                throw
            }
        }
        if ($ServiceName -eq "vSAN Witness" -and $newVmk) {
            try {
                $null = Set-VMHostNetworkAdapter -VirtualNic $newVmk -VsanWitnessEnabled $true -Confirm:$false -WarningAction SilentlyContinue -ErrorAction Stop
            } catch {
                if ($_.Exception.Message -match "Parameter set cannot be resolved|cannot be used together|VsanWitnessEnabled|VsanWitnessTrafficEnabled|parameter cannot be found") {
                    Add-VsanWitnessTrafficToVmkViaEsxcli -VMHost $VMHost -VmkernelName $newVmk.Name -WitnessOnly | Out-Null
                } else { throw }
            }
        }
        if ($newVmk) {
            $mtuForThisVmk = if ($ServiceName -eq "vSAN Witness") { 1500 } else { $VmkernelMtu }
            try {
                $null = Set-VMHostNetworkAdapter -VirtualNic $newVmk -Mtu $mtuForThisVmk -Confirm:$false -WarningAction SilentlyContinue -ErrorAction Stop
            } catch {
                Write-LogMessage -Type WARNING -Message "Could not set MTU $mtuForThisVmk on VMkernel `"$($newVmk.Name)`" on host `"$hostName`": $($_.Exception.Message). vSAN/vMotion health checks may report MTU or connectivity failures if MTU is inconsistent."
            }
            if ($ServiceName -eq "vSAN Witness" -and -not [String]::IsNullOrWhiteSpace($GatewayAddress)) {
                Set-VmkernelIpv4StaticGatewayViaEsxcli -GatewayAddress $GatewayAddress -Ipv4Address $Ip -Server $Server -SubnetMask $Netmask -VMHost $VMHost -VmkernelName $newVmk.Name
            }
        }
        Write-LogMessage -Type INFO -Message "Created VMkernel for `"$ServiceName`" on host `"$hostName`" (port group `"$PortGroupName`", IP $Ip, MTU $(if ($ServiceName -eq 'vSAN Witness') { 1500 } else { $VmkernelMtu }))."
    } catch [VcfDeploymentException] {
        throw
    } catch {
        $err = "Failed to create VMkernel for `"$ServiceName`" on host `"$hostName`": $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
}
function Build-VmkernelPortGroupSpecs {

    <#
        .SYNOPSIS
        Builds port group spec lists from networkingVmKernelInterfaces configuration.

        .DESCRIPTION
        Iterates the interface list and produces two arrays of port group specs: one for vMotion/vSAN
        services and one for vSAN Witness services. Each spec contains Name and VlanId.

        .PARAMETER EdgeSuffix
        Suffix appended to the service name (lower-cased, spaces stripped) to form the port group name.

        .PARAMETER NetworkingVmKernelInterfaces
        Array of interface config objects, each with service, vlanId (optional), and ipList.

        .OUTPUTS
        Hashtable with keys VmotionVsan and Witness, each holding an array of spec hashtables.

        .NOTES
        Helper for Add-VmkernelInterfacesFromNetworkingConfig. Not intended for direct call.
    
        .EXAMPLE
        Build-VmkernelPortGroupSpecs -EdgeSuffix "value" -NetworkingVmKernelInterfaces "10.0.0.0/24"
    #>

    [CmdletBinding()]
    [OutputType([hashtable])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EdgeSuffix,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [System.Object[]]$NetworkingVmKernelInterfaces
    )

    $vmotionVsanSpecs = [System.Collections.Generic.List[Hashtable]]::new()
    $witnessSpecs     = [System.Collections.Generic.List[Hashtable]]::new()
    foreach ($vmk in $NetworkingVmKernelInterfaces) {
        $serviceName = if ($vmk.service) { [String]$vmk.service.Trim() } else { "" }
        if ([String]::IsNullOrWhiteSpace($serviceName)) { continue }
        $pgName = "$($serviceName.ToLower().Replace(' ', ''))-$EdgeSuffix"
        $vlanId = 0
        if ($null -ne $vmk.vlanId) {
            if ($vmk.vlanId -is [int]) {
                $vlanId = $vmk.vlanId
            } else {
                $parsed = 0
                if ([Int]::TryParse([String]$vmk.vlanId, [Ref]$parsed)) { $vlanId = $parsed }
            }
        }
        $specEntry = @{ Name = $pgName; VlanId = $vlanId }
        if ($serviceName -eq "vSAN Witness") {
            $witnessSpecs.Add($specEntry)
        } else {
            $vmotionVsanSpecs.Add($specEntry)
        }
    }
    return @{ VmotionVsan = $vmotionVsanSpecs.ToArray(); Witness = $witnessSpecs.ToArray() }
}
function Invoke-VmkernelPortGroupCreation {

    <#
        .SYNOPSIS
        Creates distributed port groups for vMotion/vSAN and vSAN Witness VMkernel services.

        .DESCRIPTION
        Calls New-VDSPortGroups for each non-empty spec list. For 4-uplink layouts, logs that
        vSAN Witness port groups land on the first VDS. Throws [VcfDeploymentException] on failure.

        .PARAMETER NumUplinks
        2 or 4 — used only for the 4-uplink debug log.

        .PARAMETER VmotionVsanSpecs
        Array of port group specs (@{ Name; VlanId }) for vMotion and vSAN traffic.

        .PARAMETER VmotionVsanVdsName
        VDS name where vMotion/vSAN port groups are created.

        .PARAMETER WitnessSpecs
        Array of port group specs for vSAN Witness traffic (may be empty).

        .PARAMETER WitnessVdsName
        VDS name where vSAN Witness port groups are created.

        .NOTES
        Helper for Add-VmkernelInterfacesFromNetworkingConfig. Not intended for direct call.
    
        .EXAMPLE
        Invoke-VmkernelPortGroupCreation -NumUplinks "value" -VmotionVsanSpecs $resourceObject -VmotionVsanVdsName "resource-name" -WitnessSpecs $resourceObject
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateRange(2, 4)] [Int]$NumUplinks,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [Object[]]$VmotionVsanSpecs,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VmotionVsanVdsName,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [Object[]]$WitnessSpecs,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$WitnessVdsName
    )

    if ($VmotionVsanSpecs.Count -gt 0) {
        $vmotionVsanPgResult = New-VDSPortGroups -PortGroups $VmotionVsanSpecs -VdsName $VmotionVsanVdsName
        if ($vmotionVsanPgResult -and -not $vmotionVsanPgResult.Success) {
            $err = "Add-VmkernelInterfacesFromNetworkingConfig: failed to create vMotion/vSAN vmkernel port groups on VDS `"$VmotionVsanVdsName`"."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
    }
    if ($WitnessSpecs.Count -gt 0) {
        if ($NumUplinks -eq 4) {
            Write-LogMessage -Type DEBUG -Message "Add-VmkernelInterfacesFromNetworkingConfig: vSAN Witness vmkernel port group(s) are created on the first VDS (`"$WitnessVdsName`") for four-uplink layouts."
        }
        $witnessPgResult = New-VDSPortGroups -PortGroups $WitnessSpecs -VdsName $WitnessVdsName
        if ($witnessPgResult -and -not $witnessPgResult.Success) {
            $err = "Add-VmkernelInterfacesFromNetworkingConfig: failed to create vSAN Witness vmkernel port groups on VDS `"$WitnessVdsName`"."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
    }
}
function Invoke-VmkernelAdaptersFromInterfaces {

    <#
        .SYNOPSIS
        Iterates networkingVmKernelInterfaces and calls New-VmkernelForSegment for each host.

        .DESCRIPTION
        For each VMkernel interface spec, locates the distributed port group on the correct VDS,
        then calls New-VmkernelForSegment for every host in HostsOrdered. Skips entries with no
        service name, missing port groups, or missing IPs with a WARNING.

        .PARAMETER EdgeSuffix
        Suffix appended to the lower-cased service name to form the port group name.

        .PARAMETER HostsOrdered
        Resolved VMHost objects in the same order as the ipList arrays in each interface spec.

        .PARAMETER NetworkingVmKernelInterfaces
        Array of interface specs (service, vlanId, netmask, ipList, optional gateway).

        .PARAMETER Server
        vCenter server name.

        .PARAMETER VdsObjectVmotionVsan
        Resolved VDS object for vMotion and vSAN traffic.

        .PARAMETER VdsObjectWitness
        Resolved VDS object for vSAN Witness traffic (may be $null when no witness spec exists).

        .PARAMETER VmkernelMtu
        MTU for vMotion and vSAN VMkernel adapters (1500-9190). Defaults to 9000.

        .NOTES
        Helper for Add-VmkernelInterfacesFromNetworkingConfig. Not intended for direct call.
    
        .EXAMPLE
        Invoke-VmkernelAdaptersFromInterfaces -EdgeSuffix "value" -HostsOrdered "value" -NetworkingVmKernelInterfaces "10.0.0.0/24" -Server $vcenterConnection
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EdgeSuffix,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object[]]$HostsOrdered,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [System.Object[]]$NetworkingVmKernelInterfaces,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Server,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$VdsObjectVmotionVsan,
        [Parameter(Mandatory = $false)] [AllowNull()] [Object]$VdsObjectWitness = $null,
        [Parameter(Mandatory = $false)] [ValidateRange(1500, 9190)] [Int]$VmkernelMtu = 9000
    )

    foreach ($vmk in $NetworkingVmKernelInterfaces) {
        $serviceName = if ($vmk.service) { [String]$vmk.service.Trim() } else { "" }
        if ([String]::IsNullOrWhiteSpace($serviceName)) { continue }
        $pgName = "$($serviceName.ToLower().Replace(' ', ''))-$EdgeSuffix"
        $ipList = @($vmk.ipList)
        $netmask = if ($vmk.netmask) { [String]$vmk.netmask.Trim() } else { "255.255.255.0" }
        $vdsObjectForService = if ($serviceName -eq "vSAN Witness") { $VdsObjectWitness } else { $VdsObjectVmotionVsan }
        $dpg = Get-VDPortgroup -Name $pgName -VDSwitch $vdsObjectForService -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
        if (-not $dpg) {
            Write-LogMessage -Type WARNING -Message "Add-VmkernelInterfacesFromNetworkingConfig: port group `"$pgName`" not found on VDS `"$($vdsObjectForService.Name)`"; skipping VMkernel creation for service `"$serviceName`"."
            continue
        }
        $gwRaw = if ($vmk.gateway) { [String]$vmk.gateway.Trim() } else { "" }
        for ($hostIndex = 0; $hostIndex -lt $HostsOrdered.Count; $hostIndex++) {
            $vmhost = $HostsOrdered[$hostIndex]
            $ip = if ($hostIndex -lt $ipList.Count) { [String]$ipList[$hostIndex].Trim() } else { $null }
            if ([String]::IsNullOrWhiteSpace($ip)) {
                Write-LogMessage -Type WARNING -Message "Add-VmkernelInterfacesFromNetworkingConfig: no IP for host index $hostIndex (service `"$serviceName`"); skipping."
                continue
            }
            New-VmkernelForSegment `
                -GatewayAddress $gwRaw `
                -Ip             $ip `
                -Netmask        $netmask `
                -PortGroup      $dpg `
                -PortGroupName  $pgName `
                -Server         $Server `
                -ServiceName    $serviceName `
                -VdsObject      $vdsObjectForService `
                -VMHost         $vmhost `
                -VmkernelMtu    $VmkernelMtu
        }
    }
}
function Add-VmkernelInterfacesFromNetworkingConfig {

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
    
        .EXAMPLE
        Add-VmkernelInterfacesFromNetworkingConfig -ClusterName "edge-cluster-1" -EsxHostNames "resource-name" -NetworkingVmKernelInterfaces "10.0.0.0/24" -NumUplinks "value"
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [System.Object[]]$EsxHostNames,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [System.Object[]]$NetworkingVmKernelInterfaces,
        [Parameter(Mandatory = $true)] [ValidateSet(2, 4)] [Int]$NumUplinks,
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
    $specs = Build-VmkernelPortGroupSpecs -EdgeSuffix $edgeSuffix -NetworkingVmKernelInterfaces $NetworkingVmKernelInterfaces
    if (($specs.VmotionVsan.Count -eq 0) -and ($specs.Witness.Count -eq 0)) {
        Write-LogMessage -Type DEBUG -Message "Add-VmkernelInterfacesFromNetworkingConfig: no valid port group specs; skipping."
        return
    }
    Invoke-VmkernelPortGroupCreation -NumUplinks $NumUplinks -VmotionVsanSpecs $specs.VmotionVsan `
        -VmotionVsanVdsName $vmotionVsanVdsName -WitnessSpecs $specs.Witness `
        -WitnessVdsName $witnessVmkernelVdsName
    $vdsObjectVmotionVsan = Get-VDSwitch -Name $vmotionVsanVdsName -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
    if (-not $vdsObjectVmotionVsan) {
        Write-LogMessage -Type WARNING -Message "Add-VmkernelInterfacesFromNetworkingConfig: VDS `"$vmotionVsanVdsName`" not found; skipping VMkernel creation."
        return
    }
    $vdsObjectWitness = $null
    if ($specs.Witness.Count -gt 0) {
        if ($witnessVmkernelVdsName -eq $vmotionVsanVdsName) {
            $vdsObjectWitness = $vdsObjectVmotionVsan
        } else {
            $vdsObjectWitness = Get-VDSwitch -Name $witnessVmkernelVdsName -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
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
    $hostsOrdered = [System.Collections.Generic.List[PSObject]]::new()
    foreach ($hName in $EsxHostNames) {
        $vmhost = Get-VMHost -Name $hName -Server $Server -ErrorAction SilentlyContinue
        if ($vmhost) { $hostsOrdered.Add($vmhost) }
    }
    if ($hostsOrdered.Count -eq 0) {
        Write-LogMessage -Type WARNING -Message "Add-VmkernelInterfacesFromNetworkingConfig: no hosts resolved from EsxHostNames; skipping VMkernel creation."
        return
    }
    Invoke-VmkernelAdaptersFromInterfaces `
        -EdgeSuffix                    $edgeSuffix `
        -HostsOrdered                  $hostsOrdered `
        -NetworkingVmKernelInterfaces  $NetworkingVmKernelInterfaces `
        -Server                        $Server `
        -VmkernelMtu                   $VmkernelMtu `
        -VdsObjectVmotionVsan          $vdsObjectVmotionVsan `
        -VdsObjectWitness              $vdsObjectWitness
}
function Test-PhysicalNicConnected {

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
    
        .EXAMPLE
        Test-PhysicalNicConnected -NicName "resource-name" -Server $vcenterConnection -VMHost $vmHostObject
    #>

    [CmdletBinding()]
    [OutputType([Boolean])]
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
        if ($null -ne $speedMb -and [Int]$speedMb -eq 0) {
            return $false
        }
        return $true
    } catch {
        return $false
    }
}
function Invoke-VdsNicConnectivityCheck {

    <#
        .SYNOPSIS
        Validates that required physical NICs are link-connected on every cluster host before VDS creation.

        .DESCRIPTION
        For 2-uplink topology, validates all NIC names against each host.
        For 4-uplink topology, validates the first two NIC names (sw1 uplinks) and last two (sw2 uplinks)
        separately so the error message names the correct VDS switch.
        Throws [VcfDeploymentException] on the first disconnected NIC found.

        .PARAMETER Hosts
        Array of VMHost objects to check.

        .PARAMETER NicNames
        Physical NIC names to validate (e.g. @("vmnic1","vmnic2")).

        .PARAMETER NumUplinks
        2 or 4 — determines which split logic applies.

        .PARAMETER VdsName
        Base VDS name used in error messages; "-sw1" / "-sw2" suffixes are appended for 4-uplink topology.

        .NOTES
        Helper for Set-VirtualDistributedSwitch. Not intended for direct call.
    
        .EXAMPLE
        Invoke-VdsNicConnectivityCheck -Hosts "value" -NicNames "resource-name" -NumUplinks "value" -VdsName "resource-name"
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object[]]$Hosts,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String[]]$NicNames,
        [Parameter(Mandatory = $true)] [ValidateSet(2, 4)] [Int]$NumUplinks,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VdsName
    )

    foreach ($vmHost in $Hosts) {
        $hostDisplay = if ($vmHost.Name) { $vmHost.Name } else { [String]$vmHost }
        if ($NumUplinks -eq 2) {
            $disconnected = @($NicNames | Where-Object { -not (Test-PhysicalNicConnected -NicName $_ -Server $Script:vCenterName -VMHost $vmHost) })
            if ($disconnected.Count -gt 0) {
                $nicListStr = $disconnected -join ", "
                $err = "Cannot create VDS `"$VdsName`": physical NIC(s) $nicListStr on host `"$hostDisplay`" are not connected (link down). Connect the cable(s) or fix the link before creating the VDS."
                Write-LogMessage -Type ERROR -Message $err
                throw [VcfDeploymentException]::new($err)
            }
        } else {
            $nicListFirstTwo = @($NicNames | Select-Object -First 2)
            $nicListLastTwo  = @($NicNames | Select-Object -Skip 2 -First 2)
            $disconnectedSw1 = @($nicListFirstTwo | Where-Object { -not (Test-PhysicalNicConnected -NicName $_ -Server $Script:vCenterName -VMHost $vmHost) })
            $disconnectedSw2 = @($nicListLastTwo  | Where-Object { -not (Test-PhysicalNicConnected -NicName $_ -Server $Script:vCenterName -VMHost $vmHost) })
            if ($disconnectedSw1.Count -gt 0) {
                $nicListStr = $disconnectedSw1 -join ", "
                $err = "Cannot create VDS `"$VdsName-sw1`": physical NIC(s) $nicListStr on host `"$hostDisplay`" are not connected (link down). Connect the cable(s) or fix the link before creating the VDS."
                Write-LogMessage -Type ERROR -Message $err
                throw [VcfDeploymentException]::new($err)
            }
            if ($disconnectedSw2.Count -gt 0) {
                $nicListStr = $disconnectedSw2 -join ", "
                $err = "Cannot create VDS `"$VdsName-sw2`": physical NIC(s) $nicListStr on host `"$hostDisplay`" are not connected (link down). Connect the cable(s) or fix the link before creating the VDS."
                Write-LogMessage -Type ERROR -Message $err
                throw [VcfDeploymentException]::new($err)
            }
        }
    }
}
function Invoke-VdsTwoUplinkSetup {

    <#
        .SYNOPSIS
        Orchestrates the two-uplink (single VDS) path for Set-VirtualDistributedSwitch.

        .DESCRIPTION
        Creates the VDS, adds all cluster hosts, migrates vmk0 management to the VDS on each host,
        creates distributed port groups, and sets active/standby uplink teaming policy.

        .PARAMETER DatacenterObject
        vCenter datacenter where the VDS is created.

        .PARAMETER Hosts
        Cluster host objects to add to the VDS.

        .PARAMETER ManagementPortGroupName
        DPG name to create for vmk0 management traffic.

        .PARAMETER Mtu
        MTU for the VDS (1500–9190). Default 9000.

        .PARAMETER NicList
        Physical NIC list passed through to Invoke-MigrateHostManagementToVds and Add-PhysicalAdaptersToVDS.

        .PARAMETER PortGroups
        Array of objects with Name and VlanId — each becomes a DPG on the VDS.

        .PARAMETER VdsName
        Name of the VDS to create.

        .NOTES
        Helper for Set-VirtualDistributedSwitch. Not intended for direct call.
    
        .EXAMPLE
        Invoke-VdsTwoUplinkSetup -DatacenterObject $parsedConfig -Hosts "value" -ManagementPortGroupName "resource-name" -NicList "value"
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [PSObject]$DatacenterObject,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object[]]$Hosts,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ManagementPortGroupName,
        [Parameter(Mandatory = $false)] [ValidateRange(1500, 9190)] [Int]$Mtu = 9000,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [System.Object[]]$NicList,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [System.Object[]]$PortGroups,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VdsName
    )

    $null = Invoke-VDSCreation -DatacenterObject $DatacenterObject -Mtu $Mtu -NumUplinks "2" -VdsName $VdsName
    foreach ($vmHost in $Hosts) {
        $result = Add-HostToVDS -Hostname $vmHost -VdsName $VdsName
        if ($result -and -not $result.Success) {
            $err = "Failed to add host `"$vmHost`" to VDS `"$VdsName`": $($result.ErrorMessage)"
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
    }
    Write-LogMessage -Type INFO -NoNewline -Message "Migrating management (vmk0) to VDS `"$VdsName`" for $($Hosts.Count) host(s)... "
    foreach ($vmHost in $Hosts) {
        Invoke-MigrateHostManagementToVds -VMHost $vmHost -VdsName $VdsName -NicList $NicList -ManagementPortGroupName $ManagementPortGroupName 3>$null
    }
    Write-LogMessage -Type INFO -CompletePending -Message "Done"
    $result = New-VDSPortGroups -PortGroups $PortGroups -VdsName $VdsName
    if ($result -and -not $result.Success) {
        $err = "Failed to create VDS port groups on `"$VdsName`": $($result.ErrorMessage)"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
    Set-VDSUplinkTeamingActiveStandby -VdsName $VdsName
}
function Invoke-VdsFourUplinkSetup {

    <#
        .SYNOPSIS
        Orchestrates the four-uplink (dual VDS) path for Set-VirtualDistributedSwitch.

        .DESCRIPTION
        Creates two VDS instances (-sw1 and -sw2), adds all cluster hosts to both, migrates vmk0
        management to sw1 using the first two NICs, assigns the last two NICs to sw2, creates port
        groups on sw1, and sets active/standby teaming on both VDS instances.

        .PARAMETER DatacenterObject
        vCenter datacenter where the VDS instances are created.

        .PARAMETER Hosts
        Cluster host objects to add to both VDS instances.

        .PARAMETER ManagementPortGroupName
        DPG name for vmk0 management traffic on sw1.

        .PARAMETER Mtu
        MTU for both VDS instances (1500–9190). Default 9000.

        .PARAMETER NicList
        Four-element physical NIC list; first two go to sw1, last two to sw2.

        .PARAMETER PortGroups
        Array of objects with Name and VlanId — DPGs created on sw1 only.

        .PARAMETER VdsName
        Base VDS name; "-sw1" and "-sw2" suffixes are appended automatically.

        .NOTES
        Helper for Set-VirtualDistributedSwitch. Not intended for direct call.
    
        .EXAMPLE
        Invoke-VdsFourUplinkSetup -DatacenterObject $parsedConfig -Hosts "value" -ManagementPortGroupName "resource-name" -NicList "value"
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [PSObject]$DatacenterObject,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object[]]$Hosts,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ManagementPortGroupName,
        [Parameter(Mandatory = $false)] [ValidateRange(1500, 9190)] [Int]$Mtu = 9000,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [System.Object[]]$NicList,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [System.Object[]]$PortGroups,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VdsName
    )

    $vdsNameSw1 = "$VdsName-sw1"
    $vdsNameSw2 = "$VdsName-sw2"
    $null       = Invoke-VDSCreation -DatacenterObject $DatacenterObject -Mtu $Mtu -NumUplinks "2" -VdsName $vdsNameSw1
    $vdsObjectSw2 = Invoke-VDSCreation -DatacenterObject $DatacenterObject -Mtu $Mtu -NumUplinks "2" -VdsName $vdsNameSw2
    foreach ($vmHost in $Hosts) {
        $result = Add-HostToVDS -Hostname $vmHost -VdsName $vdsNameSw1
        if ($result -and -not $result.Success) {
            $err = "Failed to add host `"$vmHost`" to VDS `"$vdsNameSw1`": $($result.ErrorMessage)"
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
        $result = Add-HostToVDS -Hostname $vmHost -VdsName $vdsNameSw2
        if ($result -and -not $result.Success) {
            $err = "Failed to add host `"$vmHost`" to VDS `"$vdsNameSw2`": $($result.ErrorMessage)"
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
    }
    $nicListFirstTwo = @($NicList | Select-Object -First 2)
    Write-LogMessage -Type INFO -NoNewline -Message "Migrating management (vmk0) to VDS `"$vdsNameSw1`" for $($Hosts.Count) host(s)... "
    foreach ($vmHost in $Hosts) {
        Invoke-MigrateHostManagementToVds -VMHost $vmHost -VdsName $vdsNameSw1 -NicList $nicListFirstTwo -ManagementPortGroupName $ManagementPortGroupName 3>$null
    }
    Write-LogMessage -Type INFO -CompletePending -Message "Done"
    $nicListLastTwo = @($NicList | Select-Object -Skip 2 -First 2)
    foreach ($vmHost in $Hosts) {
        $result = Add-PhysicalAdaptersToVDS -Hostname $vmHost -NicList $nicListLastTwo -VdsName $vdsNameSw2 -VdsObject $vdsObjectSw2
        if ($result -and -not $result.Success) {
            $err = "Failed to add physical adapters for host `"$vmHost`" to VDS `"$vdsNameSw2`": $($result.ErrorMessage)"
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
    }
    $result = New-VDSPortGroups -PortGroups $PortGroups -VdsName $vdsNameSw1
    if ($result -and -not $result.Success) {
        $err = "Failed to create VDS port groups on `"$vdsNameSw1`": $($result.ErrorMessage)"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
    Set-VDSUplinkTeamingActiveStandby -VdsName $vdsNameSw1
    Set-VDSUplinkTeamingActiveStandby -VdsName $vdsNameSw2
}
function Set-VirtualDistributedSwitch {

       <#
        .SYNOPSIS
        Creates and configures a VDS with distributed port groups and physical NIC assignments.

        .DESCRIPTION
        Orchestrates VDS infrastructure in order: (1) create the VDS, (2) add cluster hosts,
        (3) create distributed port groups, (4) assign physical NICs to uplinks.
        All steps are idempotent — existing resources produce a warning, not an error.
        Validates that each NIC exists and is not already claimed before assignment.
        Throws on critical failures; warns on duplicate resources.

        .PARAMETER VdsName
        Name for the new VDS, unique within the datacenter.

        .PARAMETER DatacenterName
        vCenter datacenter where the VDS will be created.

        .PARAMETER NumUplinks
        Number of uplink ports as a string (e.g., "2"). Common values: 2, 4, 8.

        .PARAMETER ClusterName
        All hosts in this cluster are added to the VDS.

        .PARAMETER PortGroups
        Array of objects with Name and VlanId properties. Each becomes a static-binding DPG with 128 ports.

        .PARAMETER NicList
        Array of objects with a Name property (e.g., @{Name="vmnic1"}). Each NIC is validated before assignment.

        .EXAMPLE
        Set-VirtualDistributedSwitch -ClusterName "Cluster1" -DatacenterName "DC1" -NicList @(@{Name="vmnic1"}) -NumUplinks "2" -PortGroups @(@{Name="mgmt";VlanId=100}) -VdsName "prod-VDS"

        .LINK
        Invoke-VDSCreation
        Add-HostToVDS
        New-VDSPortGroups
        Add-PhysicalAdaptersToVDS
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

    Assert-VcenterConnected

    $numUplinksInt = [Int]$NumUplinks
    if ($numUplinksInt -ne 2 -and $numUplinksInt -ne 4) {
        $err = "Set-VirtualDistributedSwitch requires NumUplinks 2 or 4. Got: $NumUplinks."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }

    # Derive edge suffix from VdsName (e.g. VDS-VMFS -> VMFS, VDS-VMFS-sw1 -> VMFS) so management and port group names are unique per edge.
    $edgeSuffixFromVds = ($VdsName -replace '^VDS-', '') -replace '-sw[12]$', ''
    $managementPortGroupName = "mgmt-$edgeSuffixFromVds"

    try {

        $datacenterObject = Get-Datacenter -Name $DatacenterName -Server $Script:vCenterName
        $clusterObject = Get-Cluster -Name $ClusterName -Server $Script:vCenterName
        $hosts = @(Get-VMHost -Location $clusterObject -Server $Script:vCenterName)
        if (-not $hosts -or $hosts.Count -eq 0) {
            Write-LogMessage -Type ERROR -Message "Cluster `"$ClusterName`" has no hosts."
            throw [VcfDeploymentException]::new("Cluster `"$ClusterName`" has no hosts.")
        }

        # Normalize NicList to adapter names.
        $allNicNames = [System.Collections.Generic.List[String]]::new()
        foreach ($item in $NicList) {
            $name = if ($item -is [String]) { $item.Trim() } else { $item.Name }
            if (-not [String]::IsNullOrWhiteSpace($name)) {
                $allNicNames.Add($name)
            }
        }
        if (-not $allNicNames -or $allNicNames.Count -eq 0) {
            $err = "NicList is empty or has no valid adapter names."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }

        # Validate NIC link state before creating the VDS; throws if any required NIC is link-down.
        Invoke-VdsNicConnectivityCheck -Hosts $hosts -NicNames $allNicNames -NumUplinks $numUplinksInt -VdsName $VdsName

        if ($numUplinksInt -eq 2) {
            Invoke-VdsTwoUplinkSetup -DatacenterObject $datacenterObject -Hosts $hosts `
                -ManagementPortGroupName $managementPortGroupName -Mtu $Mtu `
                -NicList $NicList -PortGroups $PortGroups -VdsName $VdsName
        } else {
            Invoke-VdsFourUplinkSetup -DatacenterObject $datacenterObject -Hosts $hosts `
                -ManagementPortGroupName $managementPortGroupName -Mtu $Mtu `
                -NicList $NicList -PortGroups $PortGroups -VdsName $VdsName
        }
    } catch [System.UnauthorizedAccessException] {
        $err = "Cannot configure distributed switch `"$VdsName`" due to authorization issues: $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    } catch [System.TimeoutException] {
        $err = "Cannot configure distributed switch `"$VdsName`" due to network/timeout issues: $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    } catch [VcfDeploymentException] {
        throw  # already logged and typed — propagate without re-wrapping
    } catch {
        $err = "Failed to configure distributed switch `"$VdsName`": $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
}
function ConvertTo-IpInt {

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
    
        .EXAMPLE
        ConvertTo-IpInt -IpString "10.0.0.1"
    #>

    [CmdletBinding()]
    [OutputType([Int64])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$IpString
    )

    $octets = $IpString.Split('.')
    return ([Int64]$octets[0] -shl 24) -bor ([Int64]$octets[1] -shl 16) -bor ([Int64]$octets[2] -shl 8) -bor [Int64]$octets[3]
}
function Test-IpAddressInCidrRange {

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
    [OutputType([Bool])]

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$CidrRange,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$IpAddress

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
        $prefixLength = [Int]$cidrParts[1]

        if ($prefixLength -eq 0) {
            $subnetMask = 0
        } else {
            $subnetMask = [Int64][Math]::Pow(2, 32) - [Int64][Math]::Pow(2, (32 - $prefixLength))
        }

        $ipInt = ConvertTo-IpInt -IpString $IpAddress
        $networkInt = ConvertTo-IpInt -IpString $networkAddress

        $ipNetwork = $ipInt -band $subnetMask
        $cidrNetwork = $networkInt -band $subnetMask

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
function Test-GatewayIpInRange {

    <#
        .SYNOPSIS
        Returns $true when the gateway IP (host part of a CIDR) falls within the IP range [StartIp, StartIp+Count-1].

        .DESCRIPTION
        Extracts the host address from GatewayCidr and checks whether it is consumed by the IP block
        defined by StartIp and Count. Used to prevent allocating an IP range that overwrites the
        network gateway address.

        .PARAMETER GatewayCidr
        The gateway CIDR (e.g. 10.0.0.1/24). Only the host portion is used as the gateway IP.

        .PARAMETER StartIp
        The first IP address of the range to test.

        .PARAMETER Count
        The number of consecutive IPs in the range. Must be a positive integer.

        .OUTPUTS
        [Boolean] $true when the gateway IP is within [StartIp, StartIp+Count-1].

        .EXAMPLE
        Test-GatewayIpInRange -GatewayCidr "10.30.10.1/24" -StartIp "10.30.10.1" -Count 50
        Returns $true — the gateway 10.30.10.1 is the start IP.

        .EXAMPLE
        Test-GatewayIpInRange -GatewayCidr "10.30.10.1/24" -StartIp "10.30.10.2" -Count 50
        Returns $false — the gateway 10.30.10.1 is below the range.

        .NOTES
        Calls Test-ValidIPv4Address to guard against malformed inputs; returns $false on any parse failure.
    #>

    [CmdletBinding()]
    [OutputType([Boolean])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateRange(1, [Int]::MaxValue)] [Int]$Count,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$GatewayCidr,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$StartIp
    )

    try {
        $gatewayIp = $GatewayCidr.Split('/')[0]
        if (-not (Test-ValidIPv4Address -IpAddress $gatewayIp) -or -not (Test-ValidIPv4Address -IpAddress $StartIp)) {
            return $false
        }
        $gwInt    = ConvertTo-IpInt -IpString $gatewayIp
        $startInt = ConvertTo-IpInt -IpString $StartIp
        $endInt   = $startInt + $Count - 1
        return ($gwInt -ge $startInt -and $gwInt -le $endInt)
    }
    catch {
        return $false
    }
}
function Test-ValidCidrRange {

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

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$InputText,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [String]$PropertyPath
    )

    Write-LogMessage -Type DEBUG -Message "Entered Test-ValidCidrRange function..."

    Write-LogMessage -Type DEBUG -Message "Validating CIDR range for IP count: '$InputText'"

    # Attempt to parse as integer.
    $number = $null
    $isInteger = [Int]::TryParse($InputText, [Ref]$number)

    if (-not $isInteger) {
        $pathInfo = if ($PropertyPath) { " for property `"$PropertyPath`"" } else { "" }
        Write-LogMessage -Type ERROR -Message "CIDR range validation failed${pathInfo}: Value `"$InputText`" is not a valid integer"
        return $false
    }

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

        $nearestLower = [Math]::Pow(2, [Math]::Floor([Math]::Log($number, 2)))
        $nearestUpper = [Math]::Pow(2, [Math]::Ceiling([Math]::Log($number, 2)))

        Write-LogMessage -Type ERROR -Message "CIDR range validation failed${pathInfo}: Value $number is not a power of 2 (not a complete CIDR block). Nearest valid values: $nearestLower or $nearestUpper"
        return $false
    }

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
function Test-ValidIPv4Address {

    <#
        .SYNOPSIS
        Returns $true when the supplied string is a valid dotted-decimal IPv4 address; $false otherwise.
        .PARAMETER IpAddress
        The string to test. Null, empty, and whitespace-only values return $false.
    
        .EXAMPLE
        $validIPv4AddressResult = Test-ValidIPv4Address
        if (-not $validIPv4AddressResult.IsValid) {
            Write-LogMessage -Type ERROR -Message $validIPv4AddressResult.Summary
        }
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param ([Parameter(Mandatory = $false)] [String]$IpAddress = "")
    if ([String]::IsNullOrWhiteSpace($IpAddress)) { return $false }
    return $IpAddress -match '^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$'
}
function Test-ValidNetmask {

    <#
        .SYNOPSIS
        Returns $true when the supplied string is a valid contiguous IPv4 subnet mask (e.g. 255.255.255.0); $false otherwise.
        .DESCRIPTION
        A valid netmask must be a dotted-decimal IPv4 address whose binary representation is all 1s followed by all 0s (contiguous).
        .PARAMETER Netmask
        The string to test. Null, empty, whitespace-only, and non-contiguous masks return $false.
    
        .EXAMPLE
        $validNetmaskResult = Test-ValidNetmask
        if (-not $validNetmaskResult.IsValid) {
            Write-LogMessage -Type ERROR -Message $validNetmaskResult.Summary
        }
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param ([Parameter(Mandatory = $false)] [String]$Netmask = "")
    if ([String]::IsNullOrWhiteSpace($Netmask)) { return $false }
    if (-not (Test-ValidIPv4Address -IpAddress $Netmask)) { return $false }
    $octets = $Netmask -split '\.'
    if ($octets.Count -ne 4) { return $false }
    $binary = ($octets | ForEach-Object { [Convert]::ToString([Int]$_, 2).PadLeft(8, '0') }) -join ''
    if ($binary -notmatch '^1*0*$') { return $false }
    return $true
}
function Test-IpInSubnet {

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
    
        .EXAMPLE
        Test-IpInSubnet -IpAddress "10.0.0.1" -ReferenceIp "10.0.0.1" -SubnetMask "10.0.0.0/24"
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$IpAddress,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ReferenceIp,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SubnetMask
    )
    if (-not (Test-ValidIPv4Address -IpAddress $IpAddress) -or -not (Test-ValidIPv4Address -IpAddress $ReferenceIp) -or -not (Test-ValidNetmask -Netmask $SubnetMask)) {
        return $false
    }
    $ipOctets = $IpAddress -split '\.' | ForEach-Object { [Int]$_ }
    $refOctets = $ReferenceIp -split '\.' | ForEach-Object { [Int]$_ }
    $maskOctets = $SubnetMask -split '\.' | ForEach-Object { [Int]$_ }
    $ipInt = 0; foreach ($octet in $ipOctets) { $ipInt = ($ipInt -shl 8) + $octet }
    $refInt = 0; foreach ($octet in $refOctets) { $refInt = ($refInt -shl 8) + $octet }
    $maskInt = 0; foreach ($octet in $maskOctets) { $maskInt = ($maskInt -shl 8) + $octet }
    return ($ipInt -band $maskInt) -eq ($refInt -band $maskInt)
}
function Test-TcpPortReachable {

    <#
        .SYNOPSIS
        Tests whether a TCP port on a remote host is reachable within a given timeout.

        .DESCRIPTION
        Opens a non-blocking TCP connection attempt to the specified IP address and port.
        Returns $true when the connection completes within the timeout window, $false otherwise.
        Connection errors (refused, unreachable) are caught and treated as not reachable.

        .PARAMETER IpAddress
        The IPv4 address or hostname to connect to.

        .PARAMETER Port
        The TCP port to test. Defaults to 443.

        .PARAMETER TimeoutMilliseconds
        Maximum time in milliseconds to wait for the connection. Defaults to 3000 ms.

        .OUTPUTS
        [Bool] $true when the port is reachable, $false otherwise.

        .EXAMPLE
        $reachable = Test-TcpPortReachable -IpAddress "192.168.1.10" -Port 443
        if (-not $reachable) { throw [VcfDeploymentException]::new("Host is not reachable on port 443.") }

        .NOTES
        Uses non-blocking async TCP connect with WaitOne to avoid indefinite hangs. Safe to call
        in a loop against multiple hosts. Always returns a boolean — never throws.
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$IpAddress,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 65535)] [Int]$Port = 443,
        [Parameter(Mandatory = $false)] [ValidateRange(1, [Int]::MaxValue)] [Int]$TimeoutMilliseconds = 3000
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
