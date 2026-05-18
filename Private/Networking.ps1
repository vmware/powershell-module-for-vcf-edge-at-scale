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
Function Remove-NonVmk0VmkernelInterfacesFromVds {

    <#
        .SYNOPSIS
        Removes non-vmk0 VMkernel interfaces (e.g. vMotion, vSAN, vSAN Witness) from hosts on the given VDS. Used during cleanup so port groups are no longer in use before VDS removal.

        .DESCRIPTION
        For each specified VDS, finds hosts (from cluster or attached to the VDS), then removes every VMkernel adapter on that VDS except vmk0. No migration is required; these interfaces are deleted so a fully cleaned host has only management until provisioned again.

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

    # Suppress PowerCLI deprecation (VmwareVDPortgroup.VirtualSwitch) while querying DPGs and VMkernel adapters.
    $savedWarningPreference = $WarningPreference
    $WarningPreference = "SilentlyContinue"
    try {
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

            # Get all user port groups on this VDS (exclude system DVUplinks). Build sets of Ids and names for fallback lookup.
            $userPortGroupsOnVds = @(Get-VDPortgroup -VDSwitch $distributedSwitch -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike "*DVUplinks*" })
            $portGroupIdsOnVds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            $portGroupNamesOnVds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($portGroup in $userPortGroupsOnVds) {
                $portGroupId = if ($portGroup.Id) { $portGroup.Id } elseif ($portGroup.ExtensionData -and $portGroup.ExtensionData.MoRef -and $portGroup.ExtensionData.MoRef.Value) { $portGroup.ExtensionData.MoRef.Value } else { $null }
                if ($portGroupId) { [void]$portGroupIdsOnVds.Add($portGroupId) }
                if (-not [String]::IsNullOrWhiteSpace($portGroup.Name)) { [void]$portGroupNamesOnVds.Add($portGroup.Name) }
            }

            $totalRemoved = 0
            Write-LogMessage -Type INFO -NoNewline -Message "Removing non-management VMkernel interfaces from hosts on VDS `"$currentVdsName`"... "

            foreach ($esxHost in $hostsOnVds) {
                $hostNameForLog = $esxHost.Name

                # Primary path: for each port group, get VMkernel adapters on that DPG and remove any that are not vmk0.
                foreach ($portGroup in $userPortGroupsOnVds) {
                    $vmkernelAdaptersOnPortGroup = @(Get-VMHostNetworkAdapter -VMHost $esxHost -VMKernel -PortGroup $portGroup -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue)
                    foreach ($adapter in $vmkernelAdaptersOnPortGroup) {
                        if ($adapter.Name -eq "vmk0") { continue }
                        try {
                            Remove-VMHostNetworkAdapter -Nic $adapter -Confirm:$false -ErrorAction Stop
                            $totalRemoved++
                            Write-LogMessage -Type DEBUG -Message "Removed non-management VMkernel `"$($adapter.Name)`" (port group `"$($portGroup.Name)`") from host `"$hostNameForLog`" during cleanup."
                        } catch {
                            Write-LogMessage -Type WARNING -Message "Could not remove VMkernel `"$($adapter.Name)`" on host `"$hostNameForLog`": $($_.Exception.Message)."
                        }
                    }
                }

                # Fallback: on some PowerCLI/vCenter versions, Get-VMHostNetworkAdapter -PortGroup returns nothing. Find VMkernels on this VDS by matching port group Id or name and remove them.
                $allVmkernelAdaptersOnHost = @(Get-VMHostNetworkAdapter -VMHost $esxHost -VMKernel -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue)
                foreach ($adapter in $allVmkernelAdaptersOnHost) {
                    if ($adapter.Name -eq "vmk0") { continue }
                    try {
                        $adapterPortGroupRef = $null
                        if ($adapter.ExtensionData -and $adapter.ExtensionData.Spec -and $adapter.ExtensionData.Spec.PortGroup) {
                            $adapterPortGroupRef = $adapter.ExtensionData.Spec.PortGroup
                        }
                        if (-not $adapterPortGroupRef) { continue }
                        $adapterPortGroupId = if ($adapterPortGroupRef.Value) { $adapterPortGroupRef.Value } else { [string]$adapterPortGroupRef }
                        if ([String]::IsNullOrWhiteSpace($adapterPortGroupId)) { continue }
                        $adapterOnThisVds = $portGroupIdsOnVds.Contains($adapterPortGroupId)
                        if (-not $adapterOnThisVds) {
                            $resolvedPg = Get-VDPortgroup -Id $adapterPortGroupId -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
                            if ($resolvedPg -and -not [String]::IsNullOrWhiteSpace($resolvedPg.Name) -and $portGroupNamesOnVds.Contains($resolvedPg.Name)) {
                                $adapterOnThisVds = $true
                            }
                        }
                        if (-not $adapterOnThisVds) { continue }
                        Remove-VMHostNetworkAdapter -Nic $adapter -Confirm:$false -ErrorAction Stop
                        $totalRemoved++
                        Write-LogMessage -Type DEBUG -Message "Removed non-management VMkernel `"$($adapter.Name)`" (port group Id $adapterPortGroupId) from host `"$hostNameForLog`" during cleanup (fallback by Id/name)."
                    } catch {
                        Write-LogMessage -Type DEBUG -Message "Fallback VMkernel removal skipped or failed for `"$($adapter.Name)`" on host `"$hostNameForLog`": $($_.Exception.Message)."
                    }
                }
            }

            Write-LogMessage -Type INFO -CompletePending -Message "Removed $totalRemoved interface(s) from $($hostsOnVds.Count) host(s)."
        }
    }
    finally {
        $WarningPreference = $savedWarningPreference
    }
}
Function Invoke-ManagementRestoreForCleanup {

    <#
        .SYNOPSIS
        Invokes Restore-ManagementToVssBeforeVdsRemoval when the VDS exists so management can be moved off the VDS before removal.

        .DESCRIPTION
        When the VDS that carries management exists, calls Restore-ManagementToVssBeforeVdsRemoval to move vmk0 to a standard switch (via HostNetworkSystem.UpdateVirtualNic). When the VDS does not exist, calls restore with no validation (restore no-ops).

        .PARAMETER ClusterName
        Name of the cluster (for logging and restore).

        .PARAMETER VdsNameWithMgmt
        Name of the VDS that may have the management port group.

        .OUTPUTS
        PSCustomObject from Restore-ManagementToVssBeforeVdsRemoval (RestoreAttempted, Success, HostsRestoredCount, Message).
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VdsNameWithMgmt
    )
    return Restore-ManagementToVssBeforeVdsRemoval -ClusterName $ClusterName -VdsNameWithMgmt $VdsNameWithMgmt
}
Function Invoke-ManagementRestoreForCleanupWithTopologyFallback {

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
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [ValidateSet(2, 4)] [Int]$NicListCount = 2,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$Server = $Script:vCenterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VdsName
    )

    $orderedNames = if ($NicListCount -eq 4) {
        @("$VdsName-sw1", $VdsName)
    } else {
        @($VdsName, "$VdsName-sw1")
    }

    $seenKeys = @{}
    $candidates = [System.Collections.ArrayList]::new()
    foreach ($n in $orderedNames) {
        if ([string]::IsNullOrWhiteSpace($n)) {
            continue
        }

        $key = $n.ToLowerInvariant()
        if ($seenKeys.ContainsKey($key)) {
            continue
        }

        $seenKeys[$key] = $true
        [void]$candidates.Add($n)
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

Function Get-VdsByName {

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

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Name,
        [Parameter(Mandatory = $false)] [String]$Server = $Script:vCenterName
    )

    Get-VDSwitch -Name $Name -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
}

Function Restore-ManagementToVssBeforeVdsRemoval {

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
        Skips hosts that do not have vmk0 on the specified VDS. Restore is only ever to vSwitch0-restore/Management; the restore vSwitch is created before any move. Order: (1) if vSwitch0-restore already exists with a pNIC and Management port group, move vmk0 there; (2) else if the host has an unused pNIC (not on the VDS), create or complete vSwitch0-restore and Management port group then move vmk0—this path also recovers retry after partial failure; (3) else remove one pNIC from the VDS, create vSwitch0-restore and Management port group, then move vmk0. When creating the Management port group, the VLAN ID from the current management DPG is applied. When removing a pNIC from the VDS, tries lowest-numbered first (e.g. vmnic0 then vmnic1). Moves vmk0 via HostNetworkSystem.UpdateVirtualNic. When move fails, throws with instructions to use vCenter Migrate VMkernel Adapter and retry.
        Returns a result object: RestoreAttempted (bool), Success (bool), HostsRestoredCount (int), Message (string).
        Caller should skip VDS removal when RestoreAttempted is true and Success is false.
    #>

    [CmdletBinding()]
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

    $prevWarningPreference = $WarningPreference
    $WarningPreference = "SilentlyContinue"
    try {
    $vdsObject = Get-VdsByName -Name $VdsNameWithMgmt -Server $Server
    if (-not $vdsObject) {
        Write-LogMessage -Type DEBUG -Message "VDS `"$VdsNameWithMgmt`" not found; nothing to restore for management."
        return $result
    }

    if (-not $VMHost -and [String]::IsNullOrWhiteSpace($ClusterName)) {
        Write-LogMessage -Type WARNING -Message "Restore-ManagementToVssBeforeVdsRemoval: neither -VMHost nor -ClusterName was supplied; attempting host discovery from VDS `"$VdsNameWithMgmt`" only."
    }

    $hosts = @()
    if ($VMHost) {
        $hosts = @($VMHost)
    } else {
        $clusterObject = Get-ClusterByName -Name $ClusterName -Server $Server
        if ($clusterObject) {
            $hosts = @(Get-VMHost -Location $clusterObject -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue)
        }
        if (-not $hosts -or $hosts.Count -eq 0) {
            # Cluster not found or empty; try hosts attached to the VDS so we can restore before VDS removal (e.g. cluster already removed).
            try {
                $hosts = @(Get-VMHost -DistributedSwitch $vdsObject -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue)
            } catch {
                Write-LogMessage -Type DEBUG -Message "Could not get hosts from VDS `"$VdsNameWithMgmt`": $($_.Exception.Message)."
            }
            if (-not $hosts -or $hosts.Count -eq 0) {
                Write-LogMessage -Type DEBUG -Message "Cluster `"$ClusterName`" not found and no hosts on VDS `"$VdsNameWithMgmt`"; nothing to restore."
                return $result
            }
            Write-LogMessage -Type INFO -Message "Cluster `"$ClusterName`" not found; restoring management on $($hosts.Count) host(s) attached to VDS `"$VdsNameWithMgmt`"."
        }
    }

    $result.RestoreAttempted = $true
    $hostsRestoredCount = 0
    $restoreSkippedDueToRollback = $false
    # Pre-check: if the VDS has a management-named port group (e.g. mgmt-VMFS), we will assume vmk0 may be on it when per-host detection fails (avoids "No hosts required restore" when vmk0 is on the VDS but detection quirks miss it).
    $expectedMgmtPgNamePattern = "mgmt-" + ($VdsNameWithMgmt -replace '^VDS-', '')
    $vdsUserPgs = @(Get-DpgsOnVds -VDSwitch $vdsObject -Server $Server)
    if ($vdsUserPgs.Count -eq 0) {
        $vdsUserPgs = @(Get-VDPortgroup -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue | Where-Object { ($_.Name -notlike "*DVUplinks*") -and ($_.VDSwitch -and $_.VDSwitch.Name -eq $VdsNameWithMgmt) })
    }
    $vdsHasMgmtPortGroup = @($vdsUserPgs | Where-Object { $_.Name -eq $expectedMgmtPgNamePattern -or $_.Name -like "mgmt-*" }).Count -gt 0
    Write-LogMessage -Type DEBUG -Message "VDS `"$VdsNameWithMgmt`" user port groups: $($vdsUserPgs.Count) ($($vdsUserPgs | ForEach-Object { $_.Name } | Sort-Object) -join ', '). Management-named (mgmt-*): $vdsHasMgmtPortGroup."
    if ($vdsHasMgmtPortGroup) {
        Write-LogMessage -Type DEBUG -Message "VDS `"$VdsNameWithMgmt`" has management-named port group(s); will attempt restore on each host if vmk0 detection fails."
    }
    Write-LogMessage -Type INFO -NoNewline -Message "Restoring management (vmk0) to standard switch on hosts... "

    foreach ($vmhost in $hosts) {
        $hostName = $vmhost.Name
        $vmk0 = Get-VmkernelAdaptersOnHost -VMHost $vmhost -Server $Server | Where-Object { $_.Name -eq "vmk0" }
        if (-not $vmk0) {
            Write-LogMessage -Type DEBUG -Message "Host `"$hostName`" has no vmk0; skipping."
            continue
        }

        # Check if vmk0 is on the specified VDS. Use port group Id (MoRef .Value) for Get-VDPortgroup -Id; fallback: DPG Id/Name in VDS list (VDSwitch may be deprecated/unavailable in some PowerCLI); then iterate DPGs and check Get-VMHostNetworkAdapter -PortGroup; final fallback: compare vmk0 port group MoRef to DPG MoRefs on the VDS.
        $vmk0OnThisVds = $false
        $dpg = $null
        try {
            $pgId = $vmk0.ExtensionData.Spec.PortGroup
            if ($pgId) {
                $pgIdValue = if ($pgId.Value) { $pgId.Value } else { $pgId }
                $dpg = Get-VDPortgroup -Id $pgIdValue -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
                if ($dpg -and $dpg.VDSwitch.Name -eq $VdsNameWithMgmt) {
                    $vmk0OnThisVds = $true
                }
            }
        } catch {
            Write-LogMessage -Type DEBUG -Message "Could not determine vmk0 port group (vmk0 may be on standard switch): $($_.Exception.Message)."
        }
        if ($dpg -and -not $vmk0OnThisVds) {
            $vdsPgList = @(Get-VDPortgroup -VDSwitch $vdsObject -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike "*DVUplinks*" })
            foreach ($vdsPg in $vdsPgList) {
                if ($vdsPg.Id -and $dpg.Id -and $vdsPg.Id -eq $dpg.Id) {
                    $vmk0OnThisVds = $true
                    Write-LogMessage -Type DEBUG -Message "Host `"$hostName`" vmk0 found on VDS `"$VdsNameWithMgmt`" via DPG Id match (VDSwitch property unavailable or did not match)."
                    break
                }
                if ($vdsPg.Name -and $dpg.Name -and $vdsPg.Name -eq $dpg.Name) {
                    $vmk0OnThisVds = $true
                    Write-LogMessage -Type DEBUG -Message "Host `"$hostName`" vmk0 found on VDS `"$VdsNameWithMgmt`" via DPG name match (VDSwitch property unavailable or did not match)."
                    break
                }
            }
        }
        if (-not $vmk0OnThisVds -and $pgId) {
            # Get-VDPortgroup -Id may have returned null (e.g. Id format not accepted). Match vmk0's port group MoRef against each DPG on the VDS by Id/MoRef in multiple forms.
            $pgIdValueForMatch = if ($pgId.Value) { $pgId.Value.ToString().Trim() } else { $pgId.ToString().Trim() }
            $vdsPgListForMatch = @(Get-VDPortgroup -VDSwitch $vdsObject -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike "*DVUplinks*" })
            foreach ($vdsPg in $vdsPgListForMatch) {
                $vdsPgId = if ($vdsPg.Id) { $vdsPg.Id.ToString().Trim() } else { "" }
                $vdsPgMoRef = if ($vdsPg.ExtensionData -and $vdsPg.ExtensionData.MoRef -and $vdsPg.ExtensionData.MoRef.Value) { $vdsPg.ExtensionData.MoRef.Value.ToString().Trim() } else { "" }
                $match = $false
                if ($pgIdValueForMatch -and $vdsPgId -and ($pgIdValueForMatch -eq $vdsPgId -or $pgIdValueForMatch -like "*$vdsPgId*" -or $vdsPgId -like "*$pgIdValueForMatch*")) { $match = $true }
                if (-not $match -and $pgIdValueForMatch -and $vdsPgMoRef -and ($pgIdValueForMatch -eq $vdsPgMoRef -or $pgIdValueForMatch -like "*$vdsPgMoRef*" -or $vdsPgMoRef -like "*$pgIdValueForMatch*")) { $match = $true }
                if ($match) {
                    $vmk0OnThisVds = $true
                    Write-LogMessage -Type DEBUG -Message "Host `"$hostName`" vmk0 found on VDS `"$VdsNameWithMgmt`" via MoRef/Id match when Get-VDPortgroup -Id returned null (vmk0 pg ref: $pgIdValueForMatch)."
                    break
                }
            }
        }
        if (-not $vmk0OnThisVds) {
            # -WarningAction SilentlyContinue suppresses PowerCLI deprecation for VmwareVDPortgroup.VirtualSwitch (cmdlet uses .VirtualSwitch internally).
            $vdPgs = Get-VDPortgroup -VDSwitch $vdsObject -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
            foreach ($dpg in $vdPgs) {
                $vmkernelsOnDpg = Get-VMHostNetworkAdapter -VMHost $vmhost -VMKernel -PortGroup $dpg -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
                if ($vmkernelsOnDpg | Where-Object { $_.Name -eq "vmk0" }) {
                    $vmk0OnThisVds = $true
                    Write-LogMessage -Type DEBUG -Message "Host `"$hostName`" vmk0 found on VDS `"$VdsNameWithMgmt`" via DPG iteration (Id check did not match)."
                    break
                }
            }
        }
        if (-not $vmk0OnThisVds -and $vmk0.ExtensionData.Spec.PortGroup) {
            # Fallback: compare vmk0 port group MoRef to DPG MoRefs on this VDS (Get-VMHostNetworkAdapter -PortGroup may not return vmk0 on some PowerCLI/vCenter versions).
            $vmk0PgRef = $vmk0.ExtensionData.Spec.PortGroup
            $vmk0PgRefStr = if ($vmk0PgRef.Value) { $vmk0PgRef.Value.ToString().Trim() } else { $vmk0PgRef.ToString().Trim() }
            if (-not [String]::IsNullOrWhiteSpace($vmk0PgRefStr)) {
                $vdPgsForRef = Get-VDPortgroup -VDSwitch $vdsObject -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
                foreach ($dpg in @($vdPgsForRef)) {
                    $dpgRef = $dpg.ExtensionData.MoRef
                    $dpgRefStr = if ($dpgRef.Value) { $dpgRef.Value.ToString().Trim() } elseif ($dpg.Id) { $dpg.Id.ToString().Trim() } else { "" }
                    if ($dpgRefStr -and ($vmk0PgRefStr -eq $dpgRefStr -or $vmk0PgRefStr -like "*$dpgRefStr*" -or $dpgRefStr -like "*$vmk0PgRefStr*")) {
                        $vmk0OnThisVds = $true
                        Write-LogMessage -Type DEBUG -Message "Host `"$hostName`" vmk0 found on VDS `"$VdsNameWithMgmt`" via MoRef match (port group ref: $vmk0PgRefStr)."
                        break
                    }
                }
            }
        }
        if (-not $vmk0OnThisVds) {
            # Last resort: this VDS may be the management VDS from our deployment with an mgmt-* port group (e.g. mgmt-VMFS). If so, vmk0 may be on it; attempt restore so cleanup can remove the port group.
            $expectedMgmtPgName = "mgmt-" + ($VdsNameWithMgmt -replace '^VDS-', '')
            $mgmtPgByName = Get-VDPortgroup -Name $expectedMgmtPgName -VDSwitch $vdsObject -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
            if (-not $mgmtPgByName) {
                $mgmtPgByName = Get-VDPortgroup -Name $expectedMgmtPgName -VDSwitch $vdsObject -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
            }
            if ($mgmtPgByName) {
                $vmk0OnThisVds = $true
                Write-LogMessage -Type DEBUG -Message "Host `"$hostName`" vmk0 assumed on VDS `"$VdsNameWithMgmt`" (management port group `"$expectedMgmtPgName`" found by name; all other detection failed). Attempting restore."
            }
            if (-not $vmk0OnThisVds) {
                $userPgsOnVds = @(Get-VDPortgroup -VDSwitch $vdsObject -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike "*DVUplinks*" })
                $hasMgmtPg = @($userPgsOnVds | Where-Object { $_.Name -eq $expectedMgmtPgName -or $_.Name -like "mgmt-*" }).Count -gt 0
                if ($hasMgmtPg) {
                    $vmk0OnThisVds = $true
                    $mgmtPgNames = @($userPgsOnVds | Where-Object { $_.Name -eq $expectedMgmtPgName -or $_.Name -like "mgmt-*" } | Select-Object -ExpandProperty Name)
                    Write-LogMessage -Type DEBUG -Message "Host `"$hostName`" vmk0 assumed on VDS `"$VdsNameWithMgmt`" (management port group(s) present: $($mgmtPgNames -join ', '); all other detection failed). Attempting restore."
                }
            }
        }
        if (-not $vmk0OnThisVds -and $vdsHasMgmtPortGroup) {
            # VDS has mgmt-* port group but per-host detection did not find vmk0 on it (e.g. Get-VMHostNetworkAdapter -PortGroup or MoRef match failed). Assume vmk0 is on this VDS and attempt restore so we do not leave the port group in use.
            $vmk0OnThisVds = $true
            Write-LogMessage -Type DEBUG -Message "Host `"$hostName`" vmk0 assumed on VDS `"$VdsNameWithMgmt`" (VDS has management port group; per-host detection missed). Attempting restore."
        }
        if (-not $vmk0OnThisVds) {
            Write-LogMessage -Type DEBUG -Message "Host `"$hostName`" vmk0 is not on VDS `"$VdsNameWithMgmt`"; skipping."
            continue
        }

        Write-LogMessage -Type INFO -Message "Attempting management restore for host `"$hostName`" (vmk0 on VDS `"$VdsNameWithMgmt`")."

        $ip = $vmk0.IP
        if ([String]::IsNullOrWhiteSpace($ip)) {
            Write-LogMessage -Type WARNING -Message "Host `"$hostName`" vmk0 has no IP; cannot restore to VSS. Skipping."
            continue
        }

        # Resolve the DPG that vmk0 is on and get its VLAN ID. The VSS Management port group must use the same VLAN so the host stays reachable (tagged management networks).
        $vmk0Dpg = $null
        if ($vmk0.ExtensionData.Spec.PortGroup) {
            $pgRef = $vmk0.ExtensionData.Spec.PortGroup
            $pgRefValue = if ($pgRef.Value) { $pgRef.Value } else { $pgRef }
            $vmk0Dpg = Get-VDPortgroup -Id $pgRefValue -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
        }
        if (-not $vmk0Dpg) {
            $vdPgsForVlan = @(Get-VDPortgroup -VDSwitch $vdsObject -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike "*DVUplinks*" })
            foreach ($pg in $vdPgsForVlan) {
                $vmkOnPg = Get-VMHostNetworkAdapter -VMHost $vmhost -VMKernel -PortGroup $pg -Server $Server -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq "vmk0" }
                if ($vmkOnPg) {
                    $vmk0Dpg = $pg
                    break
                }
            }
        }
        $mgmtVlanId = 0
        if ($vmk0Dpg) {
            if ($vmk0Dpg.PSObject.Properties['VLanID'] -and $null -ne $vmk0Dpg.VLanID) {
                $mgmtVlanId = [int]$vmk0Dpg.VLanID
            }
            elseif ($vmk0Dpg.PSObject.Properties['VlanId'] -and $null -ne $vmk0Dpg.VlanId) {
                $mgmtVlanId = [int]$vmk0Dpg.VlanId
            }
            elseif ($vmk0Dpg.ExtensionData -and $vmk0Dpg.ExtensionData.Config -and $vmk0Dpg.ExtensionData.Config.DefaultPortConfig -and $vmk0Dpg.ExtensionData.Config.DefaultPortConfig.Vlan -and $vmk0Dpg.ExtensionData.Config.DefaultPortConfig.Vlan.PSObject.Properties['VlanId']) {
                $mgmtVlanId = [int]$vmk0Dpg.ExtensionData.Config.DefaultPortConfig.Vlan.VlanId
            }
            elseif ($vmk0Dpg.ExtensionData -and $vmk0Dpg.ExtensionData.Spec -and $vmk0Dpg.ExtensionData.Spec.PSObject.Properties['VlanId'] -and $null -ne $vmk0Dpg.ExtensionData.Spec.VlanId) {
                $mgmtVlanId = [int]$vmk0Dpg.ExtensionData.Spec.VlanId
            }
        }
        if ($mgmtVlanId -gt 0) {
            Write-LogMessage -Type DEBUG -Message "Host `"$hostName`" vmk0 is on a tagged VLAN ($mgmtVlanId); VSS restore port group will use VLanId $mgmtVlanId."
        }
        elseif ($vmk0Dpg -and $mgmtVlanId -eq 0) {
            Write-LogMessage -Type WARNING -Message "Host `"$hostName`": could not read VLAN from management DPG `"$($vmk0Dpg.Name)`"; VSS restore port group will use VLanId 0 (untagged). If management is on a tagged VLAN, connectivity may be lost."
        }

        # Only restore (move vmk0) to the designated restore vSwitch (vSwitch0-restore). If it already exists with a pNIC and Management port group, move vmk0 there. Otherwise we create it first (unused pNIC or remove pNIC) then move—never move to any other VSS.
        $vssNameRestore = "vSwitch0-restore"
        $existingRestoreVss = Get-VirtualSwitchesOnHost -VMHost $vmhost -Server $Server | Where-Object { $_.Name -eq $vssNameRestore }
        if ($existingRestoreVss) {
            $pnicsOnRestoreVss = @(Get-VMHostNetworkAdapter -VMHost $vmhost -Physical -VirtualSwitch $existingRestoreVss -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue)
            $stdPgManagement = Get-VirtualPortGroupsOnSwitch -VirtualSwitch $existingRestoreVss -Server $Server | Where-Object { $_.Name -eq "Management" } | Select-Object -First 1
            if ($pnicsOnRestoreVss -and $pnicsOnRestoreVss.Count -gt 0 -and $stdPgManagement) {
                try {
                    $hostView = Get-View -Id $vmhost.Id -Server $Server -Property ConfigManager -ErrorAction Stop
                    $netSys = Get-View -Id $hostView.ConfigManager.NetworkSystem -Server $Server -ErrorAction Stop
                    $nicSpec = New-Object VMware.Vim.HostVirtualNicSpec
                    $nicSpec.portgroup = $stdPgManagement.Name
                    $netSys.UpdateVirtualNic($vmk0.Name, $nicSpec)
                    Write-LogMessage -Type INFO -Message "Host `"$hostName`": moved vmk0 to existing `"$vssNameRestore`"/Management."
                    $hostsRestoredCount++
                    continue
                } catch {
                    Write-LogMessage -Type DEBUG -Message "Could not move vmk0 to existing `"$vssNameRestore`" on host `"$hostName`": $($_.Exception.Message). Will create or complete vSwitch then retry."
                }
            }
        }

        # Fallback: if vSwitch0-restore does not exist and we will need to remove a pNIC (no unused pNIC), try moving vmk0 to any other existing standard switch that has a pNIC and a Management-like port group (e.g. vSwitch0 from ESX install). Allows cleanup when vSphere blocks pNIC removal.
        $movedToFallbackVss = $false
        $existingVssList = @(Get-VirtualSwitchesOnHost -VMHost $vmhost -Server $Server | Where-Object { $_.Name -ne $vssNameRestore })
        foreach ($vss in $existingVssList) {
            if ($movedToFallbackVss) { break }
            $pnicsOnVss = @(Get-VMHostNetworkAdapter -VMHost $vmhost -Physical -VirtualSwitch $vss -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue)
            if (-not $pnicsOnVss -or $pnicsOnVss.Count -eq 0) { continue }
            $stdPgs = @(Get-VirtualPortGroupsOnSwitch -VirtualSwitch $vss -Server $Server)
            foreach ($stdPg in $stdPgs) {
                $targetPgName = $stdPg.Name
                if ($targetPgName -notmatch "Management|VM Network|mgmt") { continue }
                try {
                    $hostView = Get-View -Id $vmhost.Id -Server $Server -Property ConfigManager -ErrorAction Stop
                    $netSys = Get-View -Id $hostView.ConfigManager.NetworkSystem -Server $Server -ErrorAction Stop
                    $nicSpec = New-Object VMware.Vim.HostVirtualNicSpec
                    $nicSpec.portgroup = $targetPgName
                    $netSys.UpdateVirtualNic($vmk0.Name, $nicSpec)
                    Write-LogMessage -Type INFO -Message "Host `"$hostName`": moved vmk0 to existing standard switch `"$($vss.Name)`"/`"$targetPgName`" (fallback when vSwitch0-restore cannot be created)."
                    $hostsRestoredCount++
                    $movedToFallbackVss = $true
                    break
                } catch {
                    Write-LogMessage -Type DEBUG -Message "Could not move vmk0 to `"$($vss.Name)`"/`"$targetPgName`" on host `"$hostName`": $($_.Exception.Message). Trying next."
                }
            }
        }
        if ($movedToFallbackVss) { continue }

        # Use any pNIC not on the VDS (unused) to build vSwitch0-restore and move vmk0 without removing a pNIC from the VDS. This also recovers retry after partial failure (e.g. previous run removed a pNIC but failed before creating the vSwitch).
        $allPnics = @(Get-VMHostNetworkAdapter -VMHost $vmhost -Physical -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue)
        $pnicsOnVds = @(Get-VMHostNetworkAdapter -VMHost $vmhost -Physical -VirtualSwitch $vdsObject -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue)
        $pnicNamesOnVds = @($pnicsOnVds | ForEach-Object { $_.Name })
        $unusedPnics = @($allPnics | Where-Object { $_.Name -notin $pnicNamesOnVds })
        if ($unusedPnics -and $unusedPnics.Count -gt 0) {
            $unusedPnicName = ($unusedPnics | ForEach-Object { $_.Name } | Sort-Object)[0]
            $unusedPnic = Get-VMHostNetworkAdapter -VMHost $vmhost -Physical -Name $unusedPnicName -Server $Server -ErrorAction SilentlyContinue
            if ($unusedPnic) {
                Write-LogMessage -Type INFO -Message "Host `"$hostName`": using pNIC `"$unusedPnicName`" (not on VDS) for vSwitch0-restore; no VDS change required (also recovers retry after partial failure)."
                try {
                    $vssName = "vSwitch0-restore"
                    $existingVss = Get-VirtualSwitchesOnHost -VMHost $vmhost -Server $Server | Where-Object { $_.Name -eq $vssName }
                    if (-not $existingVss) {
                        New-VirtualSwitch -VMHost $vmhost -Name $vssName -Nic $unusedPnicName -Server $Server -ErrorAction Stop | Out-Null
                        Write-LogMessage -Type DEBUG -Message "Created standard switch `"$vssName`" with unused pNIC `"$unusedPnicName`" on host `"$hostName`"."
                    } else {
                        $pnicsOnExisting = @(Get-VMHostNetworkAdapter -VMHost $vmhost -Physical -VirtualSwitch $existingVss -Server $Server -ErrorAction SilentlyContinue)
                        if (-not ($pnicsOnExisting | Where-Object { $_.Name -eq $unusedPnicName })) {
                            Add-VirtualSwitchPhysicalNetworkAdapter -VirtualSwitch $existingVss -VMHostPhysicalNic $unusedPnic -Server $Server -Confirm:$false -ErrorAction Stop
                            Write-LogMessage -Type DEBUG -Message "Attached pNIC `"$unusedPnicName`" to existing `"$vssName`" on host `"$hostName`" (retry after partial failure)."
                        }
                    }
                    $vss = Get-VirtualSwitch -VMHost $vmhost -Standard -Name $vssName -Server $Server -ErrorAction Stop
                    $mgmtPgName = "Management"
                    $stdPg = Get-VirtualPortGroupsOnSwitch -VirtualSwitch $vss -Server $Server | Where-Object { $_.Name -eq $mgmtPgName } | Select-Object -First 1
                    if (-not $stdPg) {
                        New-VirtualPortGroup -VirtualSwitch $vss -Name $mgmtPgName -VLanId $mgmtVlanId -Server $Server -ErrorAction Stop | Out-Null
                        $stdPg = Get-VirtualPortGroup -VirtualSwitch $vss -Name $mgmtPgName -Server $Server -ErrorAction Stop
                    }
                    $hostView = Get-View -Id $vmhost.Id -Server $Server -Property ConfigManager -ErrorAction Stop
                    $netSys = Get-View -Id $hostView.ConfigManager.NetworkSystem -Server $Server -ErrorAction Stop
                    $nicSpec = New-Object VMware.Vim.HostVirtualNicSpec
                    $nicSpec.portgroup = $mgmtPgName
                    $netSys.UpdateVirtualNic($vmk0.Name, $nicSpec)
                    Write-LogMessage -Type DEBUG -Message "Moved vmk0 to `"$vssName`"/`"$mgmtPgName`" (VLAN $mgmtVlanId) using unused pNIC `"$unusedPnicName`" on host `"$hostName`"."
                    $hostsRestoredCount++
                    continue
                } catch {
                    Write-LogMessage -Type DEBUG -Message "Could not use unused pNIC `"$unusedPnicName`" for restore on host `"$hostName`": $($_.Exception.Message). Falling back to pNIC removal from VDS."
                }
            }
        }

        # No existing VSS worked and no unused pNIC. Remove one pNIC from the VDS to build vSwitch0-restore. Try lowest-numbered first (e.g. vmnic0) so the other (e.g. vmnic1) stays on the VDS; vSphere often uses the higher uplink for management and may roll back if we remove it first.
        $pnicsOnVds = @(Get-VMHostNetworkAdapter -VMHost $vmhost -Physical -VirtualSwitch $vdsObject -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue)
        if (-not $pnicsOnVds -or $pnicsOnVds.Count -eq 0) {
            Write-LogMessage -Type WARNING -Message "Host `"$hostName`" has no pNICs on VDS `"$VdsNameWithMgmt`"; cannot restore management to VSS. Skipping."
            continue
        }
        $pnicNamesSorted = @($pnicsOnVds | ForEach-Object { $_.Name } | Sort-Object)
        $pnicToRemove = $null
        $pnicNameForRestore = $null
        $orderToTry = if ($pnicNamesSorted.Count -ge 2) { @($pnicNamesSorted[0], $pnicNamesSorted[-1]) } else { @($pnicNamesSorted[0]) }
        Write-LogMessage -Type INFO -Message "Host `"$hostName`": removing a pNIC from VDS (trying: $($orderToTry -join ', ')); only after removal will we create vSwitch0-restore and Management port group, then move vmk0."
        foreach ($chosenNicName in $orderToTry) {
            $pnicToRemove = Get-VMHostNetworkAdapter -VMHost $vmhost -Physical -Name $chosenNicName -Server $Server -ErrorAction SilentlyContinue
            if (-not $pnicToRemove) { continue }
            try {
                $pnicToRemove | Remove-VDSwitchPhysicalNetworkAdapter -Confirm:$false -ErrorAction Stop
                $pnicNameForRestore = $chosenNicName
                Write-LogMessage -Type DEBUG -Message "Host `"$hostName`": removed pNIC `"$chosenNicName`" from VDS; creating vSwitch0-restore and moving vmk0."
                break
            } catch {
                Write-LogMessage -Type WARNING -Message "Host `"$hostName`": could not remove pNIC `"$chosenNicName`" from VDS (vSphere may have rolled back): $($_.Exception.Message). Trying next pNIC."
            }
        }
        if (-not $pnicNameForRestore) {
            $restoreSkippedDueToRollback = $true
            Write-LogMessage -Type WARNING -Message "Host `"$hostName`": could not remove any pNIC from VDS `"$VdsNameWithMgmt`" (vSphere rolled back to avoid losing management). vSwitch0-restore and Management port group were not created because we must remove a pNIC first to build the restore switch; move vmk0 to a standard switch manually in vCenter (create vSwitch0-restore and Management if needed, then Migrate VMkernel Adapter), then retry cleanup."
            continue
        }
        $pnic = $pnicToRemove

        try {
            Write-LogMessage -Type DEBUG -Message "Removed pNIC `"$pnicNameForRestore`" from VDS `"$VdsNameWithMgmt`" on host `"$hostName`" for management restore."

            # Create standard switch with one pNIC (or reuse existing and add pNIC if needed).
            $vssName = "vSwitch0-restore"
                    $existingVss = Get-VirtualSwitchesOnHost -VMHost $vmhost -Server $Server | Where-Object { $_.Name -eq $vssName }
                    if ($existingVss) {
                        Write-LogMessage -Type DEBUG -Message "Standard switch `"$vssName`" already exists on host `"$hostName`"; ensuring pNIC is attached."
                        $pnicsOnVss = Get-VMHostNetworkAdapter -VMHost $vmhost -Physical -VirtualSwitch $existingVss -Server $Server -ErrorAction SilentlyContinue
                if (-not ($pnicsOnVss | Where-Object { $_.Name -eq $pnicNameForRestore })) {
                    Add-VirtualSwitchPhysicalNetworkAdapter -VirtualSwitch $existingVss -VMHostPhysicalNic $pnic -Server $Server -Confirm:$false -ErrorAction Stop
                    Write-LogMessage -Type DEBUG -Message "Attached pNIC `"$pnicNameForRestore`" to existing VSS `"$vssName`" on host `"$hostName`"."
                }
            } else {
                New-VirtualSwitch -VMHost $vmhost -Name $vssName -Nic $pnicNameForRestore -Server $Server -ErrorAction Stop | Out-Null
                Write-LogMessage -Type DEBUG -Message "Created standard switch `"$vssName`" with pNIC `"$pnicNameForRestore`" on host `"$hostName`"."
            }

            $vss = Get-VirtualSwitch -VMHost $vmhost -Standard -Name $vssName -Server $Server -ErrorAction Stop
            $mgmtPgName = "Management"
            $stdPg = Get-VirtualPortGroupsOnSwitch -VirtualSwitch $vss -Server $Server | Where-Object { $_.Name -eq $mgmtPgName } | Select-Object -First 1
            if (-not $stdPg) {
                New-VirtualPortGroup -VirtualSwitch $vss -Name $mgmtPgName -VLanId $mgmtVlanId -Server $Server -ErrorAction Stop | Out-Null
                $stdPg = Get-VirtualPortGroup -VirtualSwitch $vss -Name $mgmtPgName -Server $Server -ErrorAction Stop
                Write-LogMessage -Type DEBUG -Message "Created port group `"$mgmtPgName`" on `"$vssName`" (VLAN $mgmtVlanId) on host `"$hostName`"."
            }

            # Move vmk0 to the standard port group. Same sequence as vSphere Client "Migrate VMkernel Adapter"
            # VCF PowerCLI 9 Set-VMHostNetworkAdapter -PortGroup accepts only DistributedPortGroup; standard port groups (VirtualPortGroupImpl) must use the API path.
            $moved = $false
            $pgTypeName = $stdPg.GetType().FullName
            if ($pgTypeName -match "Distributed|VDPortgroup") {
                try {
                    Set-VMHostNetworkAdapter -VirtualNic $vmk0 -PortGroup $stdPg -Confirm:$false -ErrorAction Stop
                    $moved = $true
                    Write-LogMessage -Type DEBUG -Message "Moved management (vmk0) to standard switch on host `"$hostName`"."
                } catch {
                    Write-LogMessage -Type DEBUG -Message "Set-VMHostNetworkAdapter to port group failed: $($_.Exception.Message). Trying HostNetworkSystem.UpdateVirtualNic."
                }
            }

            if (-not $moved) {
                # Try 2: HostNetworkSystem.UpdateVirtualNic (vim API used by vSphere Client "Migrate VMkernel Adapter" wizard).
                $updateVnicError = $null
                try {
                    $hostView = Get-View -Id $vmhost.Id -Server $Server -Property ConfigManager -ErrorAction Stop
                    $netSys = Get-View -Id $hostView.ConfigManager.NetworkSystem -Server $Server -ErrorAction Stop
                    $nicSpec = New-Object VMware.Vim.HostVirtualNicSpec
                    $nicSpec.portgroup = $stdPg.Name
                    $netSys.UpdateVirtualNic($vmk0.Name, $nicSpec)
                    $moved = $true
                    Write-LogMessage -Type DEBUG -Message "Moved management (vmk0) to standard switch on host `"$hostName`"."
                } catch {
                    $updateVnicError = $_.Exception.Message
                    Write-LogMessage -Type DEBUG -Message "HostNetworkSystem.UpdateVirtualNic failed: $updateVnicError."
                }
                # Try 2b: If port group already has a VMkernel (UpdateVirtualNic AlreadyExists, or create-new would fail), remove existing VMkernel(s) on the VSS then retry UpdateVirtualNic.
                $existingOnStdPg = Get-VmkernelOnPortGroup -VMHost $vmhost -PortGroup $stdPg -Server $Server
                if (-not $moved -and $existingOnStdPg) {
                    try {
                        $existingOnStdPg | ForEach-Object { Remove-VMHostNetworkAdapter -Nic $_ -Confirm:$false -ErrorAction Stop }
                        Write-LogMessage -Type DEBUG -Message "Removed existing VMkernel(s) from `"$mgmtPgName`" on host `"$hostName`" so vmk0 can be moved there."
                        $hostView2b = Get-View -Id $vmhost.Id -Server $Server -Property ConfigManager -ErrorAction Stop
                        $netSys2b = Get-View -Id $hostView2b.ConfigManager.NetworkSystem -Server $Server -ErrorAction Stop
                        $nicSpec2b = New-Object VMware.Vim.HostVirtualNicSpec
                        $nicSpec2b.portgroup = $stdPg.Name
                        $netSys2b.UpdateVirtualNic($vmk0.Name, $nicSpec2b)
                        $moved = $true
                        Write-LogMessage -Type DEBUG -Message "Moved management (vmk0) to standard switch on host `"$hostName`" via HostNetworkSystem.UpdateVirtualNic (after removing existing VMkernel on VSS)."
                    } catch {
                        Write-LogMessage -Type DEBUG -Message "UpdateVirtualNic after removing existing VMkernel failed: $($_.Exception.Message)."
                    }
                }
                if (-not $moved) {
                    Write-LogMessage -Type DEBUG -Message "HostNetworkSystem.UpdateVirtualNic and fallbacks did not succeed. Throwing with instructions."
                }
            }

            if (-not $moved) {
                Write-LogMessage -Type ERROR -Message "Moving vmk0 to VSS failed on host `"$hostName`" (Set-VMHostNetworkAdapter and HostNetworkSystem.UpdateVirtualNic did not succeed). In vCenter use Networking → Migrate VMkernel Adapter to move vmk0 to the standard switch (e.g. vSwitch0-restore / Management), then retry cleanup."
                throw [VcfDeploymentException]::new()
            }
            $hostsRestoredCount++
        } catch {
            Write-LogMessage -Type INFO -CompletePending -Message " Failed."
            $rollbackMsg = "disconnected the host"
            if ($_.Exception.Message -match [regex]::Escape($rollbackMsg)) {
                Write-LogMessage -Type ERROR -Message "vSphere rolled back the change on host `"$hostName`" to avoid losing management. In vCenter: create a standard switch (e.g. vSwitch0-restore) with one pNIC, add a Management port group, move vmk0 to that port group, then retry cleanup."
            }
            Write-LogMessage -Type ERROR -Message "Failed to restore management to VSS on host `"$hostName`": $($_.Exception.Message)"
            $result.Success = $false
            $result.HostsRestoredCount = $hostsRestoredCount
            $result.Message = "Failed on host `"$hostName`": $($_.Exception.Message)"
            return $result
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
    finally {
        $WarningPreference = $prevWarningPreference
    }
}
Function Get-VDPortgroupById {

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

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Id,
        [Parameter(Mandatory = $false)] [String]$Server = $Script:vCenterName
    )

    Get-VDPortgroup -Id $Id -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
}

Function Get-DpgsOnVds {

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

    Param (
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$Server = $Script:vCenterName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$VDSwitch
    )

    Get-VDPortgroup -VDSwitch $VDSwitch -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike "*DVUplinks*" }
}

Function Get-PhysicalNicsOnVdsForHost {

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

    Param (
        [Parameter(Mandatory = $false)] [String]$Server = $Script:vCenterName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$VDSwitch,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$VMHost
    )

    Get-VMHostNetworkAdapter -VMHost $VMHost -Physical -VirtualSwitch $VDSwitch -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
}

Function Get-VmkernelAdaptersOnHost {

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

    Param (
        [Parameter(Mandatory = $false)] [String]$Server = $Script:vCenterName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$VMHost
    )

    Get-VMHostNetworkAdapter -VMHost $VMHost -VMKernel -Server $Server -ErrorAction SilentlyContinue
}

Function Get-VdsListOnHost {

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

    Param (
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$Server = $Script:vCenterName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$VMHost
    )

    Get-VDSwitch -VMHost $VMHost -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
}

Function Get-ClusterByName {

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

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Name,
        [Parameter(Mandatory = $false)] [String]$Server = $Script:vCenterName
    )

    Get-Cluster -Name $Name -Server $Server -ErrorAction SilentlyContinue
}

Function Get-VmHostsInCluster {

    <#
        .SYNOPSIS
        Returns all VMHosts in a cluster. Thin wrapper over Get-VMHost enabling unit tests to mock this call without fighting PowerCLI type constraints on the -Location parameter.

        .PARAMETER ClusterObject
        The cluster object whose hosts are returned.

        .PARAMETER Server
        vCenter server name or connection object.

        .EXAMPLE
        Get-VmHostsInCluster -ClusterObject $clusterObj -Server "vc.lab"
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$ClusterObject,
        [Parameter(Mandatory = $false)] [String]$Server = $Script:vCenterName
    )

    Get-VMHost -Location $ClusterObject -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
}

Function Get-VirtualSwitchesOnHost {

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

    Param (
        [Parameter(Mandatory = $false)] [String]$Server = $Script:vCenterName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$VMHost
    )

    Get-VirtualSwitch -VMHost $VMHost -Standard -Server $Server -ErrorAction SilentlyContinue
}

Function Get-VirtualPortGroupsOnSwitch {

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

    Param (
        [Parameter(Mandatory = $false)] [String]$Server = $Script:vCenterName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$VirtualSwitch
    )

    Get-VirtualPortGroup -VirtualSwitch $VirtualSwitch -Server $Server -ErrorAction SilentlyContinue
}

Function Get-VmkernelOnPortGroup {

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

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$PortGroup,
        [Parameter(Mandatory = $false)] [String]$Server = $Script:vCenterName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$VMHost
    )

    Get-VMHostNetworkAdapter -VMHost $VMHost -VMKernel -PortGroup $PortGroup -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
}

Function Test-HostManagementVdsDualUplink {

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
        $result = Test-HostManagementVdsDualUplink -VMHost $vmhost
        if (-not $result.HasDualUplink) { Write-Host "Prerequisite not met." }

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
    # Using Get-VDSwitch -VMHost is more reliable than resolving the port group reference via Get-VDPortgroup -Id,
    # which fails silently on certain PowerCLI/vCenter combinations when the MoRef format is not accepted.
    $mgmtVds = $null
    $allVdsOnHost = @(Get-VdsListOnHost -VMHost $VMHost -Server $Server)
    foreach ($vds in $allVdsOnHost) {
        $vmk0OnThisVds = $false

        # Primary: resolve vmk0's port group reference and match against this VDS.
        try {
            $pgRef = $vmk0.ExtensionData.Spec.PortGroup
            if ($pgRef) {
                $pgRefValue = if ($pgRef.Value) { $pgRef.Value.ToString().Trim() } else { $pgRef.ToString().Trim() }
                $dpg = Get-VDPortgroupById -Id $pgRefValue -Server $Server
                if ($dpg -and $dpg.VDSwitch -and $dpg.VDSwitch.Name -eq $vds.Name) {
                    $vmk0OnThisVds = $true
                }
                if (-not $vmk0OnThisVds -and $dpg) {
                    $vdsPgs = @(Get-DpgsOnVds -VDSwitch $vds -Server $Server)
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
            Write-LogMessage -Type DEBUG -Message "Test-HostManagementVdsDualUplink: port group reference check failed for host `"$hostName`" on VDS `"$($vds.Name)`": $($_.Exception.Message)."
        }

        # Fallback: iterate each DPG on the VDS and check if Get-VMHostNetworkAdapter -PortGroup returns vmk0.
        if (-not $vmk0OnThisVds) {
            $vdsPgsIter = @(Get-DpgsOnVds -VDSwitch $vds -Server $Server)
            foreach ($pg in $vdsPgsIter) {
                $vmksOnPg = Get-VmkernelOnPortGroup -VMHost $VMHost -PortGroup $pg -Server $Server
                if ($vmksOnPg | Where-Object { $_.Name -eq "vmk0" }) {
                    $vmk0OnThisVds = $true
                    Write-LogMessage -Type DEBUG -Message "Test-HostManagementVdsDualUplink: vmk0 on host `"$hostName`" confirmed on VDS `"$($vds.Name)`" via DPG iteration."
                    break
                }
            }
        }

        if ($vmk0OnThisVds) {
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
Function Remove-EdgeClusterDistributedSwitch {
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

    $connectionTest = Test-VcenterConnection
    if (-not $connectionTest.IsConnected) {
        Write-LogMessage -Type ERROR -Message "Not connected to vCenter `"$Server`": $($connectionTest.ErrorMessage)"
        throw [VcfDeploymentException]::new("Not connected to vCenter `"$Server`": $($connectionTest.ErrorMessage)")
    }

    $vdsObject = Get-VDSwitch -Name $VdsName -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
    if (-not $vdsObject) {
        Write-LogMessage -Type DEBUG -Message "VDS `"$VdsName`" not found; nothing to remove."
        return
    }

    $failedPortGroupNames = [System.Collections.ArrayList]::new()

    # Detach all hosts from the VDS (remove every pNIC from the VDS) so port groups can be removed. Without this, Remove-VDPortgroup can fail with "Operation is not valid due to the current state of the object" when hosts are still attached. -WarningAction SilentlyContinue suppresses VMHost.DatastoreIdList deprecation.
    $hostsOnVds = @(Get-VMHost -DistributedSwitch $vdsObject -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue)
    if ($hostsOnVds -and $hostsOnVds.Count -gt 0) {
        Write-LogMessage -Type DEBUG -Message "Detaching $($hostsOnVds.Count) host(s) from VDS `"$VdsName`" (removing pNICs)..."
        foreach ($vmhost in $hostsOnVds) {
            $hostName = $vmhost.Name
            $pnicsOnVds = @(Get-VMHostNetworkAdapter -VMHost $vmhost -Physical -VirtualSwitch $vdsObject -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue)
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

    $portGroups = Get-VDPortgroup -VDSwitch $vdsObject -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
    if ($portGroups) {
        # Exclude system DVUplinks port group(s); vCenter names them e.g. "VDS-site2-DVUplinks-12314". Do not remove them; they are removed when the switch is deleted.
        $portGroupsToCheckForVms = @($portGroups) | Where-Object { $_.Name -notlike "*DVUplinks*" }
        foreach ($portGroup in $portGroupsToCheckForVms) {
            # Get VMs connected to this port group without using -Network (not available in VCF PowerCLI 9). -WarningAction suppresses VmwareVDPortgroup.VirtualSwitch when VM.NetworkAdapters.Network is accessed.
            $vmsOnPg = Get-VM -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue | Where-Object {
                $_.NetworkAdapters | Where-Object { $_.Network -and ($_.Network.Id -eq $portGroup.Id -or $_.Network.Name -eq $portGroup.Name) }
            }
            if ($vmsOnPg -and @($vmsOnPg).Count -gt 0) {
                $vmList = @($vmsOnPg)
                $vmNames = $vmList | Select-Object -ExpandProperty Name
                Write-LogMessage -Type ERROR -Message "Cannot remove VDS `"$VdsName`": port group `"$($portGroup.Name)`" has $($vmList.Count) VM(s) attached: $($vmNames -join ', '). Migrate or power off VMs first."
                throw [VcfDeploymentException]::new("Deployment failed. VDS has VMs attached. Migrate or power off VMs before removing the distributed switch.")
            }
        }

        # Remove all non-DVUplinks port groups; then remove the switch (which removes DVUplinks automatically).
        # If a port group is in use (VMkernel adapter or other client; VMs already checked above), skip it and continue with others so we remove what we can.
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
                [void]$failedPortGroupNames.Add($pg.Name)
            }
        }
        if ($failedPortGroupNames.Count -eq 0) {
            Write-LogMessage -Type DEBUG -Message "Removed $portGroupRemoveCount port group(s) from VDS `"$VdsName`"."
        } else {
            Write-LogMessage -Type DEBUG -Message "Removed $portGroupRemoveCount port group(s) from VDS `"$VdsName`"; $($failedPortGroupNames.Count) skipped (in use: $($failedPortGroupNames -join ', '))."
        }

        if ($failedPortGroupNames.Count -gt 0) {
            Write-LogMessage -Type INFO -Message "Port group(s) not removed from VDS `"$VdsName`" (in use): $($failedPortGroupNames -join ', '). Move VMkernel adapters and VMs off these port groups, then remove the VDS manually or retry cleanup."
        }
    }

    if ($failedPortGroupNames.Count -gt 0 -and -not [String]::IsNullOrWhiteSpace($ClusterName) -and -not $SkipPortGroupInUseRestoreFallback.IsPresent) {
        Write-LogMessage -Type INFO -Message "Port groups still in use on VDS `"$VdsName`"; attempting management restore to VSS on cluster `"$ClusterName`", then retrying port group removal (helps when JSON nicList no longer matches the deployed VDS)."
        try {
            $restoreAfterPgFail = Restore-ManagementToVssBeforeVdsRemoval -ClusterName $ClusterName -Server $Server -VdsNameWithMgmt $VdsName
            if ($restoreAfterPgFail.RestoreAttempted -and $restoreAfterPgFail.HostsRestoredCount -gt 0) {
                $vdsObject = Get-VDSwitch -Name $VdsName -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
                if ($vdsObject) {
                    $portGroupsRetry = Get-VDPortgroup -VDSwitch $vdsObject -Server $Server -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
                    $customPortGroupsRetry = @($portGroupsRetry) | Where-Object { $_.Name -notlike "*DVUplinks*" }
                    $failedPortGroupNames.Clear()
                    $portGroupRemoveCountRetry = 0
                    Write-LogMessage -Type DEBUG -Message "Retrying distributed port group removal on VDS `"$VdsName`" after management restore..."
                    foreach ($pgRetry in $customPortGroupsRetry) {
                        try {
                            Remove-VDPortgroup -VDPortgroup $pgRetry -Server $Server -Confirm:$false -WarningAction SilentlyContinue -ErrorAction Stop
                            $portGroupRemoveCountRetry++
                            Write-LogMessage -Type DEBUG -Message "Retry pass removed port group `"$($pgRetry.Name)`" from VDS `"$VdsName`"."
                        } catch {
                            Write-LogMessage -Type WARNING -Message "Retry: failed to remove port group `"$($pgRetry.Name)`": $($_.Exception.Message)"
                            [void]$failedPortGroupNames.Add($pgRetry.Name)
                        }
                    }

                    if ($failedPortGroupNames.Count -eq 0) {
                        Write-LogMessage -Type DEBUG -Message "Retry: removed $portGroupRemoveCountRetry port group(s) from VDS `"$VdsName`"."
                    } else {
                        Write-LogMessage -Type DEBUG -Message "Retry: removed $portGroupRemoveCountRetry; $($failedPortGroupNames.Count) still in use ($($failedPortGroupNames -join ', '))."
                    }

                    if ($failedPortGroupNames.Count -gt 0) {
                        Write-LogMessage -Type INFO -Message "Port group(s) still in use after restore retry: $($failedPortGroupNames -join ', ')."
                    }
                }
            }
        } catch {
            Write-LogMessage -Type WARNING -Message "Management restore fallback before VDS removal failed for `"$VdsName`": $($_.Exception.Message)"
        }
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
                    Write-LogMessage -Type ERROR -Message "Failed to remove VDS `"$VdsName`". Port group(s) in use: $($failedPortGroupNames -join ', '). Move VMkernel adapters and VMs off these port groups, then remove the VDS manually or retry cleanup."
                    throw [VcfDeploymentException]::new("Deployment failed. VDS could not be removed: one or more port groups are in use ($($failedPortGroupNames -join ', ')). Move VMkernel adapters to another switch and migrate VMs off the port groups, then retry or remove the VDS manually.")
                } else {
                    Write-LogMessage -Type ERROR -Message "Failed to remove VDS `"$VdsName`": $removeErr"
                    throw [VcfDeploymentException]::new("Failed to remove VDS `"$VdsName`": $removeErr")
                }
            }
        }
    } while ($removeVdsAttempt -le 2)
}
Function Set-VMHostConnectedState {
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
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] $VMHost,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$Server = $Script:vCenterName
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
            Write-LogMessage -Type ERROR -Message "Failed to exit maintenance mode on host `"$hostName`": $($_.Exception.Message)"
            throw [VcfDeploymentException]::new("Deployment failed. Host `"$hostName`" is in maintenance mode and could not be set to Connected. Exit maintenance mode manually, then re-run.")
        }
    }
    elseif ($connectionState -ne "Connected") {
        Write-LogMessage -Type DEBUG -Message "Host `"$hostName`" connection state is `"$connectionState`" (not Maintenance). No action taken."
    }
}
Function Add-VsanOsaDiskGroupToCluster {
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
        [Parameter(Mandatory = $false)] [ValidateRange(0, 10000)] [Double]$MinCapacityGBForExistingDatastore = 1,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$PreferredFaultDomainName,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$vSanWitnessVmName,
        [Parameter(Mandatory = $false)] [bool]$LabEnvironment = $false
    )

    Write-LogMessage -Type DEBUG -Message "Entered Add-VsanOsaDiskGroupToCluster for cluster: `"$ClusterName`"."

    $connectionTest = Test-VcenterConnection
    if (-not $connectionTest.IsConnected) {
        Write-LogMessage -Type ERROR -Message "Not connected to vCenter `"$Script:vCenterName`": $($connectionTest.ErrorMessage)"
        throw [VcfDeploymentException]::new("Not connected to vCenter `"$Script:vCenterName`": $($connectionTest.ErrorMessage)")
    }

    try {
        $clusterObject = Get-ClusterByName -Name $ClusterName -Server $Script:vCenterName
        if (-not $clusterObject) {
            throw [VcfDeploymentException]::new("Cluster `"$ClusterName`" not found in vCenter `"$Script:vCenterName`".")
        }
        $clusterHosts = Get-VMHost -Location $clusterObject -Server $Script:vCenterName -ErrorAction Stop

        if (-not $clusterHosts -or $clusterHosts.Count -eq 0) {
            Write-LogMessage -Type ERROR -Message "Cluster `"$ClusterName`" does not contain any hosts."
            throw [VcfDeploymentException]::new("Cluster `"$ClusterName`" does not contain any hosts.")
        }

        # Ensure no cluster host is in maintenance mode (vSAN disk group operations require connected state).
        foreach ($clusterHost in @($clusterHosts)) {
            Set-VMHostConnectedState -VMHost $clusterHost -Server $Script:vCenterName
        }

        # Ensure every cluster host has vSAN traffic (and witness if stretched); vmk0 is mgmt + vSAN witness only (no vSAN). Clear only vSAN from vmk0 if present.
        foreach ($clusterHost in @($clusterHosts)) {
            $hostName = $clusterHost.Name
            $vmk0 = Get-VMHostNetworkAdapter -VMHost $clusterHost -VMKernel -Server $Script:vCenterName -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq "vmk0" }
            if ($vmk0 -and $vmk0.PSObject.Properties["VsanTrafficEnabled"] -and $vmk0.VsanTrafficEnabled -eq $true) {
                try {
                    Set-VMHostNetworkAdapter -VirtualNic $vmk0 -VsanTrafficEnabled $false -Confirm:$false -ErrorAction Stop | Out-Null
                    Write-LogMessage -Type INFO -Message "Cleared vSAN traffic from mgmt (vmk0) on host `"$hostName`" (vmk0 is mgmt + vSAN witness only)."
                } catch {
                    Write-LogMessage -Type WARNING -Message "Could not clear vSAN from vmk0 on host `"$hostName`": $($_.Exception.Message). Clear manually if needed."
                }
            }
            $vsanCheck = Test-VmkernelVsanAndWitnessTraffic -VMHost $clusterHost
            if (-not $vsanCheck.HasCompliantInterface) {
                Write-LogMessage -Type ERROR -Message "Cluster host `"$hostName`" has no VMkernel with vSAN and vSAN witness traffic enabled. Use vmk2 (or vmk3) for vSAN; vmk0 may carry vSAN witness only."
                throw [VcfDeploymentException]::new("Deployment failed configuring vSAN OSA datastore for cluster `"$ClusterName`": cluster host `"$hostName`" requires at least one VMkernel with vSAN (e.g. vmk2) and at least one with vSAN witness (vmk0 or vmk3). Configure networkingVmKernelInterfaces and ensure VMkernels exist. Check logs for details.")
            }
            if (-not (Test-VsanTrafficVmkernelHasValidIp -VMHost $clusterHost)) {
                Write-LogMessage -Type ERROR -Message "Cluster host `"$hostName`" has vSAN traffic enabled but the VMkernel has no IPv4 or IPv6 address configured."
                throw [VcfDeploymentException]::new("Deployment failed configuring vSAN OSA datastore for cluster `"$ClusterName`": neither IPv4 nor IPv6 is properly configured for vSAN traffic on all hosts. On host `"$hostName`", the VMkernel(s) with vSAN traffic have no IP. Configure a static IPv4 (or IPv6) on the dedicated vSAN VMkernel (e.g. vmk2) on each cluster host, then re-run.")
            }
        }

        # vSAN config sync (rebalance + reapply) is done once in the main deployment flow before calling this function.

        Write-LogMessage -Type DEBUG -Message "Checking if vSAN datastore `"$DatastoreName`" already exists for cluster `"$ClusterName`"."
        $existingDatastore = Get-Datastore -Name $DatastoreName -Server $Script:vCenterName -ErrorAction SilentlyContinue
        $existingDatastoreUsable = $false
        $addingDisksToExistingDatastore = $false
        if ($existingDatastore -and $existingDatastore.Type -eq "vsan") {
            $capacityGB = 0
            if ($null -ne $existingDatastore.CapacityGB) {
                $rawCapacity = $existingDatastore.CapacityGB
                if ($rawCapacity -is [double] -or $rawCapacity -is [int] -or $rawCapacity -is [long]) {
                    $capacityGB = [double]$rawCapacity
                } else {
                    $parsed = 0.0
                    if ([double]::TryParse([string]$rawCapacity, [System.Globalization.NumberStyles]::Any, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
                        $capacityGB = $parsed
                    }
                }
            }
            if ($capacityGB -lt $MinCapacityGBForExistingDatastore) {
                Write-LogMessage -Type INFO -Message "vSAN datastore `"$DatastoreName`" exists but has no disks attached (capacity: $capacityGB GB). Proceeding with disk retrieval and disk group creation."
                $addingDisksToExistingDatastore = $true
            } else {
                $clusterHostMoRefValues = $clusterHosts | ForEach-Object { $_.ExtensionData.MoRef.Value }
                $datastoreHostIds = $existingDatastore.ExtensionData.Host | Select-Object -ExpandProperty Key | Select-Object -ExpandProperty Value
                $allHostsHaveAccess = $true
                foreach ($hostMoRefValue in $clusterHostMoRefValues) {
                    if ($datastoreHostIds -notcontains $hostMoRefValue) {
                        $allHostsHaveAccess = $false
                        break
                    }
                }
                if ($allHostsHaveAccess) {
                    Write-LogMessage -Type INFO -Message "vSAN datastore `"$DatastoreName`" already exists with capacity $([math]::Round($capacityGB, 2)) GB and is accessible by all cluster hosts. Skipping disk retrieval and disk group creation."
                    $existingDatastoreUsable = $true
                } else {
                    Write-LogMessage -Type WARNING -Message "vSAN datastore `"$DatastoreName`" exists but is not accessible by all cluster hosts. Proceeding with disk retrieval and disk group creation."
                    $existingDatastoreUsable = $false
                }
            }
        }

        if ($existingDatastoreUsable) {
            # Existing vSAN datastore is usable; skip disk retrieval and disk group creation.
        } else {
            if ($addingDisksToExistingDatastore) {
                Write-LogMessage -Type DEBUG -Message "Adding disk groups to existing vSAN datastore `"$DatastoreName`" (no disks attached)."
            } elseif ($existingDatastore -and $existingDatastore.Type -eq "vsan") {
                Write-LogMessage -Type DEBUG -Message "vSAN datastore `"$DatastoreName`" exists but is not accessible by all cluster hosts. Proceeding with disk retrieval and disk group creation."
            } else {
                Write-LogMessage -Type DEBUG -Message "No existing vSAN datastore `"$DatastoreName`" found. Proceeding with disk retrieval and disk group creation."
            }

            if ($Script:VsanOsaEligibleDisksDelaySeconds -gt 0) {
                Write-LogMessage -Type DEBUG -Message "Waiting $($Script:VsanOsaEligibleDisksDelaySeconds) seconds for vSAN on all hosts to be ready before querying eligible disks."
                Start-Sleep -Seconds $Script:VsanOsaEligibleDisksDelaySeconds
            }
            Write-LogMessage -Type DEBUG -Message "Querying cluster hosts (not witness) for vSAN OSA eligible disks: $($clusterHosts.Count) host(s) ($($clusterHosts.Name -join ', '))."
            $eligibleDisks = Get-VsanOsaEligibleDisksFromCluster `
                -ClusterName $ClusterName `
                -ClusterHosts $clusterHosts

            $diskDisplayList = [System.Collections.ArrayList]::new()
            $diskIdCounter = 1
            foreach ($disk in $eligibleDisks) {
                $hostName = $disk.VMHost.Name
                $isSsd = $false
                if ($null -ne $disk.PSObject.Properties['IsSsd']) { $isSsd = $disk.IsSsd }
                elseif ($null -ne $disk.PSObject.Properties['IsSSD']) { $isSsd = $disk.IsSSD }
                $diskDisplayObject = [PSCustomObject]@{
                    Id = $diskIdCounter
                    VMHostName = $hostName
                    CanonicalName = $disk.CanonicalName
                    CapacityGB = $disk.CapacityGB
                    Model = $disk.Model
                    IsSsd = $isSsd
                    DiskObject = $disk
                }
                [void]$diskDisplayList.Add($diskDisplayObject)
                $diskIdCounter++
            }
            $uniqueHostNames = $diskDisplayList | Select-Object -ExpandProperty VMHostName -Unique
            # Safety: require eligible disks from every data host when 2+ hosts (OSA auto-claim).
            if ($clusterHosts.Count -ge 2) {
                $hostsWithDisks = @($uniqueHostNames)
                $hostsMissingDisks = @($clusterHosts | Where-Object { $hostsWithDisks -notcontains $_.Name } | ForEach-Object { $_.Name })
                if ($hostsMissingDisks.Count -gt 0) {
                    Write-LogMessage -Type ERROR -Message "vSAN OSA auto-claim requires eligible disks from every data host. The following host(s) contributed 0 eligible disks: $($hostsMissingDisks -join ', '). Run -CleanUp Compute first to clear any leftover disk claims, or ensure each host has unused disks visible to vSAN."
                    throw [VcfDeploymentException]::new("Deployment failed. Not all data hosts have eligible disks for vSAN OSA. Host(s) with no eligible disks: $($hostsMissingDisks -join ', '). Check logs and run cleanup if needed.")
                }
            }
            $selectionByHost = @{}
            foreach ($currentHostName in $uniqueHostNames) {
                $disksOnCurrentHost = $diskDisplayList | Where-Object { $_.VMHostName -eq $currentHostName }
                $ssdsOnHost = @($disksOnCurrentHost | Where-Object { $_.IsSsd } | Sort-Object -Property CapacityGB)
                $nonSsdsOnHost = $disksOnCurrentHost | Where-Object { -not $_.IsSsd }
                $cacheDisk = $null
                $capacityDisks = [System.Collections.ArrayList]::new()
                if ($ssdsOnHost -and $ssdsOnHost.Count -gt 0) {
                    $cacheDisk = $ssdsOnHost[0]
                    $autoclaimApiOrderStr = ($disksOnCurrentHost | ForEach-Object { "$($_.Id)/$($_.CapacityGB)/$($_.IsSsd)" }) -join ", "
                    Write-LogMessage -Type DEBUG -Message "OSA autoclaim host `"$currentHostName`": disks (API order) Id/CapacityGB/IsSsd: $autoclaimApiOrderStr. Chosen cache: Id=$($cacheDisk.Id), CanonicalName=$($cacheDisk.CanonicalName), CapacityGB=$($cacheDisk.CapacityGB)."
                    foreach ($disk in $ssdsOnHost) { if ($disk -ne $cacheDisk) { [void]$capacityDisks.Add($disk) } }
                } else {
                    Write-LogMessage -Type WARNING -Message "No SSD found on host `"$currentHostName`"; using first disk as cache for OSA disk group."
                    $cacheDisk = $disksOnCurrentHost[0]
                    Write-LogMessage -Type DEBUG -Message "OSA autoclaim host `"$currentHostName`": no SSDs; using first disk as cache: Id=$($cacheDisk.Id), CanonicalName=$($cacheDisk.CanonicalName), CapacityGB=$($cacheDisk.CapacityGB)."
                    foreach ($capacityIndex in 1..($disksOnCurrentHost.Count - 1)) { [void]$capacityDisks.Add($disksOnCurrentHost[$capacityIndex]) }
                }
                foreach ($disk in $nonSsdsOnHost) { [void]$capacityDisks.Add($disk) }
                $capacitySizes = ($capacityDisks | ForEach-Object { $_.CapacityGB }) -join ", "
                Write-LogMessage -Type DEBUG -Message "OSA autoclaim host `"$currentHostName`": cache CapacityGB=$($cacheDisk.CapacityGB); capacity disk count=$($capacityDisks.Count), CapacityGB=($capacitySizes)."
                $selectionByHost[$currentHostName] = [PSCustomObject]@{ CacheDisk = $cacheDisk; CapacityDisks = $capacityDisks.ToArray() }
            }
            # Warn if data hosts (non-witness) have cache or total capacity differing by more than 1%.
            $storageImbalanceThresholdPercent = 1
            $osaDataHostNames = @($uniqueHostNames)
            if ($osaDataHostNames.Count -ge 2) {
                $osaCacheByHost = @{}
                $osaCapacityTotalByHost = @{}
                foreach ($dataHostName in $osaDataHostNames) {
                    $selection = $selectionByHost[$dataHostName]
                    $cacheGB = 0
                    if ($null -ne $selection.CacheDisk -and $null -ne $selection.CacheDisk.CapacityGB) {
                        $cacheGB = [double]$selection.CacheDisk.CapacityGB
                    }
                    $osaCacheByHost[$dataHostName] = $cacheGB
                    $capTotal = 0
                    if ($selection.CapacityDisks) {
                        foreach ($capacityDisk in $selection.CapacityDisks) {
                            if ($null -ne $capacityDisk.CapacityGB) { $capTotal += [double]$capacityDisk.CapacityGB }
                        }
                    }
                    $osaCapacityTotalByHost[$dataHostName] = $capTotal
                }
                $cacheValues = @($osaCacheByHost.Values)
                $cacheMin = ($cacheValues | Measure-Object -Minimum).Minimum
                $cacheMax = ($cacheValues | Measure-Object -Maximum).Maximum
                if ($cacheMin -gt 0 -and $cacheMax -gt $cacheMin -and (($cacheMax - $cacheMin) / $cacheMin) -gt ($storageImbalanceThresholdPercent / 100.0)) {
                    $cacheList = ($osaCacheByHost.GetEnumerator() | Sort-Object -Property Name | ForEach-Object { "`"$($_.Key)`": $([math]::Round($_.Value, 2)) GB" }) -join "; "
                    Write-LogMessage -Type WARNING -Message "vSAN OSA: data host cache disk sizes differ by more than $storageImbalanceThresholdPercent%. Cache capacity per host (GB): $cacheList."
                }
                $capValues = @($osaCapacityTotalByHost.Values)
                $capMin = ($capValues | Measure-Object -Minimum).Minimum
                $capMax = ($capValues | Measure-Object -Maximum).Maximum
                if ($capMin -gt 0 -and $capMax -gt $capMin -and (($capMax - $capMin) / $capMin) -gt ($storageImbalanceThresholdPercent / 100.0)) {
                    $capList = ($osaCapacityTotalByHost.GetEnumerator() | Sort-Object -Property Name | ForEach-Object { "`"$($_.Key)`": $([math]::Round($_.Value, 2)) GB" }) -join "; "
                    Write-LogMessage -Type WARNING -Message "vSAN OSA: data host total capacity disk sizes differ by more than $storageImbalanceThresholdPercent%. Capacity total per host (GB): $capList."
                }
            }
            foreach ($disk in $diskDisplayList) {
                $cacheDisk = $selectionByHost[$disk.VMHostName].CacheDisk
                $defaultRole = if ($disk.Id -eq $cacheDisk.Id) { "Cache" } else { "Capacity" }
                Add-Member -InputObject $disk -NotePropertyName "DefaultRole" -NotePropertyValue $defaultRole -Force
            }
            Write-Host ""
            Write-Output "vSAN OSA disks claimed for cluster `"$ClusterName`" (cache/capacity per host):"
            $diskDisplayList | Format-Table -Property Id, VMHostName, CanonicalName, CapacityGB, Model, IsSsd, DefaultRole -AutoSize
            Write-LogMessage -Type INFO -Message "vSAN OSA disk group assignment completed for $($uniqueHostNames.Count) host(s) (default cache/capacity)."

            Add-VsanOsaDiskToDiskGroup -SelectionByHost $selectionByHost

            if ($addingDisksToExistingDatastore) {
                Write-LogMessage -Type INFO -Message "Successfully added disk groups to existing vSAN datastore `"$DatastoreName`" for cluster `"$ClusterName`"."
            } else {
                Write-LogMessage -Type INFO -Message "Successfully configured vSAN OSA disk groups for all hosts in cluster `"$ClusterName`"."
            }

            Wait-ForVsanDatastoreAndRename `
                -CheckInterval $CheckInterval `
                -ClusterHosts $clusterHosts `
                -DatastoreName $DatastoreName `
                -TimeoutSeconds $DatastoreWaitTimeoutSeconds
        }

        if ($vSanWitnessVmName) {
            $skipWitnessAndHealthCheck = $false
            if ($existingDatastoreUsable) {
                try {
                    $vsanConfig = Get-VsanClusterConfiguration -Cluster $ClusterName -Server $Script:vCenterName -ErrorAction SilentlyContinue
                    if ($vsanConfig -and $vsanConfig.WitnessHost -and $vsanConfig.WitnessHost.Name) {
                        $configuredWitnessName = $vsanConfig.WitnessHost.Name
                        if ($configuredWitnessName -eq $vSanWitnessVmName) {
                            $skipWitnessAndHealthCheck = $true
                            Write-LogMessage -Type INFO -Message "vSAN datastore already exists and witness `"$vSanWitnessVmName`" is already configured for cluster `"$ClusterName`". Skipping witness configuration and health check."
                        }
                    }
                } catch {
                    Write-LogMessage -Type DEBUG -Message "Could not check existing vSAN witness configuration for cluster `"$ClusterName`" ($($_.Exception.Message)); proceeding with witness block."
                }
            }
            if (-not $skipWitnessAndHealthCheck) {
                Write-LogMessage -Type INFO -Message "Configuring vSAN witness for cluster `"$ClusterName`" (witness host: `"$vSanWitnessVmName`")."
                if (-not $PreferredFaultDomainName) {
                    Write-LogMessage -Type ERROR -Message "PreferredFaultDomainName is required when vSanWitnessVmName is provided."
                    throw [VcfDeploymentException]::new("Deployment failed configuring vSAN OSA datastore for cluster `"$ClusterName`": PreferredFaultDomainName is required when configuring vSAN witness (vSanWitnessVmName=`"$vSanWitnessVmName`"). Set common.vSanWitnessVmName (or clusters[].vSanWitnessVmName) and the preferred fault domain name (e.g. edge site name) in your input JSON.")
                }
                $witnessHost = Get-VMHost -Name $vSanWitnessVmName -Server $Script:vCenterName -ErrorAction Stop
                Write-LogMessage -Type DEBUG -Message "Witness host resolved: Name=`"$($witnessHost.Name)`", Id=`"$($witnessHost.Id)`"."
                # Ensure witness host is not in maintenance mode (vSAN witness operations require connected state).
                Set-VMHostConnectedState -VMHost $witnessHost -Server $Script:vCenterName
                $hasValidOsaGroup = $false
                $witnessMoRef = $null
                if ($witnessHost.PSObject.Properties['ExtensionData'] -and $witnessHost.ExtensionData -and $witnessHost.ExtensionData.MoRef) {
                    $witnessMoRef = $witnessHost.ExtensionData.MoRef.Value
                    Write-LogMessage -Type DEBUG -Message "Witness host MoRef.Value=`"$witnessMoRef`". Cluster hosts: $($clusterHosts.Count) host(s) ($($clusterHosts.Name -join ', '))."
                } else {
                    Write-LogMessage -Type DEBUG -Message "Witness host has no ExtensionData.MoRef. Cluster hosts: $($clusterHosts.Count) host(s) ($($clusterHosts.Name -join ', '))."
                }
                $witnessIsInCluster = $false
                if ($witnessMoRef) {
                    $witnessIsInCluster = @($clusterHosts | Where-Object { $_.ExtensionData -and $_.ExtensionData.MoRef -and $_.ExtensionData.MoRef.Value -eq $witnessMoRef }).Count -gt 0
                    if ($witnessIsInCluster) { Write-LogMessage -Type DEBUG -Message "Witness detected as in cluster (MoRef match)." }
                }
                if (-not $witnessIsInCluster) {
                    $witnessIsInCluster = @($clusterHosts | Where-Object { $_.Id -eq $witnessHost.Id -or $_.Name -eq $witnessHost.Name }).Count -gt 0
                    if ($witnessIsInCluster) { Write-LogMessage -Type DEBUG -Message "Witness detected as in cluster (Id or Name match)." }
                }
                if (-not $witnessIsInCluster) {
                    Write-LogMessage -Type DEBUG -Message "Witness is a separate host (not in cluster). Will check existing disk groups or query witness for eligible disks."
                }
                if ($witnessIsInCluster) {
                    Write-LogMessage -Type ERROR -Message "Witness host `"$vSanWitnessVmName`" is a member of cluster `"$ClusterName`". Per the vSAN Stretched Cluster Guide, the witness must not be a member of any cluster. Remove the witness host from the cluster and add it to the data center (or folder) outside the cluster, then re-run."
                    throw [VcfDeploymentException]::new("Deployment failed configuring vSAN OSA datastore for cluster `"$ClusterName`": witness host must not be a member of the cluster. Remove the witness from the cluster and add it to the data center outside the cluster, then re-run.")
                }
                if (-not $hasValidOsaGroup) {
                    Write-LogMessage -Type INFO -Message "Checking whether witness host `"$vSanWitnessVmName`" already has a vSAN OSA disk group..."
                    # Use HostVsanSystem API so witness is detected even when not in a cluster (Get-VsanDiskGroup requires cluster membership).
                    $witnessOsaResult = Get-VsanOsaDiskGroupsOnHost -VMHost $witnessHost -Server $Script:vCenterName
                    $hasValidOsaGroup = $witnessOsaResult.HasValidOsaGroup -or ($witnessOsaResult.DiskGroupCount -gt 0)
                    Write-LogMessage -Type DEBUG -Message "Witness host disk group check (HostVsanSystem.config): DiskGroupCount=$($witnessOsaResult.DiskGroupCount), HasValidOsaGroup=$($witnessOsaResult.HasValidOsaGroup)."
                    if ($hasValidOsaGroup) {
                        if ($witnessOsaResult.HasValidOsaGroup) {
                            Write-LogMessage -Type INFO -Message "Witness host `"$vSanWitnessVmName`" already has a vSAN OSA disk group. Skipping disk group creation."
                        } else {
                            Write-LogMessage -Type INFO -Message "Witness host `"$vSanWitnessVmName`" has $($witnessOsaResult.DiskGroupCount) existing vSAN disk group(s); treating as valid and skipping creation."
                        }
                    }
                    Write-LogMessage -Type DEBUG -Message "Witness hasValidOsaGroup=$hasValidOsaGroup after disk group check."
                }
                # A single witness may be used for many clusters; we only create a disk group when the witness has none.
                if (-not $hasValidOsaGroup) {
                    Write-LogMessage -Type INFO -Message "No existing witness disk group found. Creating vSAN OSA witness disk group on `"$vSanWitnessVmName`" (automatic cache/capacity selection)."
                    Initialize-VsanWitnessDiskGroup -ClusterName $ClusterName -StoragePolicyType "vSAN-OSA" -vSanWitnessVmName $vSanWitnessVmName
                }
                Write-LogMessage -Type DEBUG -Message "Calling Set-VsanWitness for cluster `"$ClusterName`" with PreferredFaultDomainName=`"$PreferredFaultDomainName`", vSanWitnessVmName=`"$vSanWitnessVmName`", StoragePolicyType vSAN-OSA."
                Write-LogMessage -Type INFO -Message "Configuring vSAN witness host for cluster `"$ClusterName`"..."
                Set-VsanWitness -ClusterName $ClusterName -LabEnvironment $LabEnvironment -PreferredFaultDomainName $PreferredFaultDomainName -StoragePolicyType "vSAN-OSA" -vSanWitnessVmName $vSanWitnessVmName
                Invoke-VsanClusterHealthCheckAfterWitness -AcceptBadCheckResults:$AcceptBadCheckResults.IsPresent -ClusterName $ClusterName -LabEnvironment $LabEnvironment -StoragePolicyType "vSAN-OSA"
            }
        }
        Enable-VsanPerformanceService -ClusterName $ClusterName
    }
    catch [System.UnauthorizedAccessException] {
        $errorMessage = $_.Exception.Message
        $reason = Get-CleanVsanErrorMessage -ErrorMessage $errorMessage
        if ($reason -eq $errorMessage) { $reason = "authorization error. $errorMessage" }
        $cleanMessage = "Failed to configure vSAN OSA datastore for cluster `"$ClusterName`". Reason: $reason"
        Write-LogMessage -Type ERROR -Message $cleanMessage
        throw [VcfDeploymentException]::new("Deployment failed. $cleanMessage")
    }
    catch [System.TimeoutException] {
        $errorMessage = $_.Exception.Message
        $reason = Get-CleanVsanErrorMessage -ErrorMessage $errorMessage
        if ($reason -eq $errorMessage) { $reason = "network/timeout. $errorMessage" }
        $cleanMessage = "Failed to configure vSAN OSA datastore for cluster `"$ClusterName`". Reason: $reason"
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
        $cleanMessage = "Failed to configure vSAN OSA datastore for cluster `"$ClusterName`". Reason: $reason"
        Write-LogMessage -Type ERROR -Message $cleanMessage
        throw [VcfDeploymentException]::new("Deployment failed. $cleanMessage")
    }
}
Function Add-VsanEsaStoragePoolDisk {

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
        [Parameter(Mandatory = $false)] [bool]$LabEnvironment = $false,
        [Parameter(Mandatory = $false)] [ValidateRange(0, 10000)] [Double]$MinCapacityGBForExistingDatastore = 1,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$PreferredFaultDomainName,
        [Parameter(Mandatory = $false)] [ValidateRange(0, 600)] [Int]$VsAdvCfgSyncWaitTimeoutSeconds = 180,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$vSanWitnessVmName
    )

    Write-LogMessage -Type DEBUG -Message "Entered Add-VsanEsaStoragePoolDisk function for cluster: `"$ClusterName`"."

    $connectionTest = Test-VcenterConnection
    if (-not $connectionTest.IsConnected) {
        Write-LogMessage -Type ERROR -Message "Not connected to vCenter `"$Script:vCenterName`": $($connectionTest.ErrorMessage)"
        throw [VcfDeploymentException]::new("Not connected to vCenter `"$Script:vCenterName`": $($connectionTest.ErrorMessage)")
    }

    try {
        $clusterObject = Get-ClusterByName -Name $ClusterName -Server $Script:vCenterName
        if (-not $clusterObject) {
            throw [VcfDeploymentException]::new("Cluster `"$ClusterName`" not found in vCenter `"$Script:vCenterName`".")
        }
        $clusterHosts = Get-VMHost -Location $clusterObject -Server $Script:vCenterName -ErrorAction Stop

        if (-not $clusterHosts -or $clusterHosts.Count -eq 0) {
            Write-LogMessage -Type ERROR -Message "Cluster `"$ClusterName`" does not contain any hosts."
            throw [VcfDeploymentException]::new("Cluster `"$ClusterName`" does not contain any hosts.")
        }

        # Check first if a vSAN datastore with the expected name already exists and is usable. If so, skip re-apply, config sync wait, and disk addition entirely.
        Write-LogMessage -Type DEBUG -Message "Checking if vSAN datastore `"$DatastoreName`" already exists for cluster `"$ClusterName`"."
        $existingDatastore = Get-Datastore -Name $DatastoreName -Server $Script:vCenterName -ErrorAction SilentlyContinue
        $existingDatastoreUsable = $false
        $addingDisksToExistingDatastore = $false
        if ($existingDatastore -and $existingDatastore.Type -eq "vsan") {
            $capacityGB = 0
            if ($null -ne $existingDatastore.CapacityGB) {
                $rawCapacity = $existingDatastore.CapacityGB
                if ($rawCapacity -is [double] -or $rawCapacity -is [int] -or $rawCapacity -is [long]) {
                    $capacityGB = [double]$rawCapacity
                } else {
                    $parsed = 0.0
                    if ([double]::TryParse([string]$rawCapacity, [System.Globalization.NumberStyles]::Any, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
                        $capacityGB = $parsed
                    }
                }
            }
            if ($capacityGB -lt $MinCapacityGBForExistingDatastore) {
                Write-LogMessage -Type INFO -Message "vSAN datastore `"$DatastoreName`" exists but has no disks attached (capacity: $capacityGB GB). Proceeding with disk retrieval and addition."
                $addingDisksToExistingDatastore = $true
            } else {
                $clusterHostMoRefValues = $clusterHosts | ForEach-Object { $_.ExtensionData.MoRef.Value }
                $dsHostIds = $existingDatastore.ExtensionData.Host | Select-Object -ExpandProperty Key | Select-Object -ExpandProperty Value
                $allHostsHaveAccess = $true
                foreach ($hostMoRefValue in $clusterHostMoRefValues) {
                    if ($dsHostIds -notcontains $hostMoRefValue) {
                        $allHostsHaveAccess = $false
                        break
                    }
                }
                if ($allHostsHaveAccess) {
                    Write-LogMessage -Type INFO -Message "vSAN datastore `"$DatastoreName`" already exists with capacity $([math]::Round($capacityGB, 2)) GB and is accessible by all cluster hosts. Skipping vSAN steps."
                    $existingDatastoreUsable = $true
                } else {
                    Write-LogMessage -Type WARNING -Message "vSAN datastore `"$DatastoreName`" exists but is not accessible by all cluster hosts. Proceeding with disk retrieval and addition."
                    $existingDatastoreUsable = $false
                }
            }
        }

        if ($existingDatastoreUsable) {
            # Existing vSAN datastore is usable; skip config sync wait, disk retrieval, and addition.
        } else {
            # vSAN config sync (rebalance + reapply) is done once in the main deployment flow before calling this function.

            # Re-check existing datastore in case it was created or changed (e.g. empty datastore name exists).
            if (-not $existingDatastore) {
                $existingDatastore = Get-Datastore -Name $DatastoreName -Server $Script:vCenterName -ErrorAction SilentlyContinue
            }
            if ($existingDatastore -and $existingDatastore.Type -eq "vsan" -and -not $existingDatastoreUsable -and -not $addingDisksToExistingDatastore) {
                $capacityGB = 0
                if ($null -ne $existingDatastore.CapacityGB) {
                    $rawCapacity = $existingDatastore.CapacityGB
                    if ($rawCapacity -is [double] -or $rawCapacity -is [int] -or $rawCapacity -is [long]) {
                        $capacityGB = [double]$rawCapacity
                    } else {
                        $parsed = 0.0
                        if ([double]::TryParse([string]$rawCapacity, [System.Globalization.NumberStyles]::Any, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
                            $capacityGB = $parsed
                        }
                    }
                }
                if ($capacityGB -lt $MinCapacityGBForExistingDatastore) {
                    $addingDisksToExistingDatastore = $true
                }
            }

        if ($existingDatastoreUsable) {
            # Already handled above; no disk work.
        } else {
            # Proceed with disk retrieval and addition.
            if ($addingDisksToExistingDatastore) {
                Write-LogMessage -Type DEBUG -Message "Adding disks to existing vSAN datastore `"$DatastoreName`" (no disks attached)."
            } elseif ($existingDatastore -and $existingDatastore.Type -eq "vsan") {
                Write-LogMessage -Type DEBUG -Message "vSAN datastore `"$DatastoreName`" exists but is not accessible by all cluster hosts. Proceeding with disk retrieval and addition."
            } else {
                Write-LogMessage -Type DEBUG -Message "No existing vSAN datastore `"$DatastoreName`" found. Proceeding with disk retrieval and addition."
            }

            # Retrieve eligible disks from all hosts in the cluster.
            $eligibleDisks = Get-VsanEsaEligibleDisksFromCluster `
                -ClusterName $ClusterName `
                -ClusterHosts $clusterHosts `
                -TimeoutSeconds $DiskRetrievalTimeoutSeconds `
                -CheckInterval $CheckInterval

            $diskDisplayList = [System.Collections.ArrayList]::new()
            $diskIdCounter = 1
            foreach ($disk in $eligibleDisks) {
                $diskDisplayObject = [PSCustomObject]@{
                    Id = $diskIdCounter
                    VMHostName = $disk.VMHost.Name
                    CanonicalName = $disk.CanonicalName
                    CapacityGB = $disk.CapacityGB
                    Model = $disk.Model
                    DiskObject = $disk
                }
                [void]$diskDisplayList.Add($diskDisplayObject)
                $diskIdCounter++
            }
            # Safety: require eligible disks from every data host when 2+ hosts (ESA auto-claim).
            if ($clusterHosts.Count -ge 2) {
                $uniqueHostNamesEsa = $diskDisplayList | Select-Object -ExpandProperty VMHostName -Unique
                $hostsWithDisksEsa = @($uniqueHostNamesEsa)
                $hostsMissingDisksEsa = @($clusterHosts | Where-Object { $hostsWithDisksEsa -notcontains $_.Name } | ForEach-Object { $_.Name })
                if ($hostsMissingDisksEsa.Count -gt 0) {
                    Write-LogMessage -Type ERROR -Message "vSAN ESA auto-claim requires eligible disks from every data host. The following host(s) contributed 0 eligible disks: $($hostsMissingDisksEsa -join ', '). Run -CleanUp Compute first to clear any leftover disk claims, or ensure each host has unused disks visible to vSAN."
                    throw [VcfDeploymentException]::new("Deployment failed. Not all data hosts have eligible disks for vSAN ESA. Host(s) with no eligible disks: $($hostsMissingDisksEsa -join ', '). Check logs and run cleanup if needed.")
                }
            }
            Write-Host ""
            Write-Output "vSAN ESA disks claimed for cluster `"$ClusterName`":"
            $diskDisplayList | Format-Table -Property Id, VMHostName, CanonicalName, CapacityGB, Model -AutoSize
            Write-LogMessage -Type INFO -Message "vSAN ESA storage pool: all $($diskDisplayList.Count) eligible disk(s) will be added."
            $selection = [PSCustomObject]@{
                SelectedDisks = @($diskDisplayList)
                ExcludedDisks = @()
                DisksWereDeselected = $false
                DiskDisplayList = $diskDisplayList
            }

            # Group selected disks by host.
            $selectedDisksByHost = Group-DisksByHost -Disks $selection.SelectedDisks

            # Warn if data hosts (non-witness) contributing storage differ by more than 1% in total capacity.
            $storageImbalanceThresholdPercent = 1
            $esaCapacityByHost = @{}
            foreach ($hostName in $selectedDisksByHost.Keys) {
                $totalGB = 0
                foreach ($disk in $selectedDisksByHost[$hostName]) {
                    $cap = 0
                    if ($null -ne $disk.PSObject.Properties["CapacityGB"] -and $null -ne $disk.CapacityGB) {
                        if ($disk.CapacityGB -is [double] -or $disk.CapacityGB -is [int] -or $disk.CapacityGB -is [long]) {
                            $cap = [double]$disk.CapacityGB
                        } else {
                            $parsed = 0.0
                            if ([double]::TryParse([string]$disk.CapacityGB, [System.Globalization.NumberStyles]::Any, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
                                $cap = $parsed
                            }
                        }
                    }
                    $totalGB += $cap
                }
                $esaCapacityByHost[$hostName] = $totalGB
            }
            $esaHostCount = $esaCapacityByHost.Count
            if ($esaHostCount -ge 2) {
                $esaCapValues = @($esaCapacityByHost.Values | Where-Object { $_ -ge 0 })
                $esaMin = if ($esaCapValues.Count -gt 0) { ($esaCapValues | Measure-Object -Minimum).Minimum } else { 0 }
                $esaMax = if ($esaCapValues.Count -gt 0) { ($esaCapValues | Measure-Object -Maximum).Maximum } else { 0 }
                if ($esaMin -gt 0 -and $esaMax -gt $esaMin) {
                    $esaRatio = ($esaMax - $esaMin) / $esaMin
                    if ($esaRatio -gt ($storageImbalanceThresholdPercent / 100.0)) {
                        $esaCapacityList = ($esaCapacityByHost.GetEnumerator() | Sort-Object -Property Name | ForEach-Object { "`"$($_.Key)`": $([math]::Round($_.Value, 2)) GB" }) -join "; "
                        Write-LogMessage -Type WARNING -Message "vSAN ESA: data host storage totals differ by more than $storageImbalanceThresholdPercent%. Capacity per host (GB): $esaCapacityList."
                    }
                }
            }

            # Push vSAN cluster config and wait for advCfgSync before claiming disks (hosts must have ESA state applied or Add-VsanStoragePoolDisk can fail with invalid object state).
            if ($VsAdvCfgSyncWaitTimeoutSeconds -gt 0) {
                Write-LogMessage -Type INFO -Message "Preparing hosts for vSAN ESA storage pool disk claim: re-applying vSAN cluster configuration and waiting up to $VsAdvCfgSyncWaitTimeoutSeconds second(s) for advanced config sync on cluster `"$ClusterName`"."
                Invoke-VsanClusterConfigReapply -ClusterName $ClusterName | Out-Null
                $null = Wait-VsanClusterConfigSyncOrTimeout -CheckIntervalSeconds 15 -ClusterName $ClusterName -TimeoutSeconds $VsAdvCfgSyncWaitTimeoutSeconds
            }

            # Add selected disks to storage pools for each host.
            Add-VsanEsaDiskToStoragePool -DisksByHost $selectedDisksByHost

            if ($addingDisksToExistingDatastore) {
                Write-LogMessage -Type INFO -Message "Successfully added disks to existing vSAN datastore `"$DatastoreName`" for cluster `"$ClusterName`"."
            } else {
                Write-LogMessage -Type INFO -Message "Successfully configured vSAN ESA datastore for all hosts in cluster `"$ClusterName`"."
            }

            # Wait for vSAN datastore to appear (or have capacity after adding disks) and rename if needed.
            Wait-ForVsanDatastoreAndRename `
                -CheckInterval $CheckInterval `
                -ClusterHosts $clusterHosts `
                -DatastoreName $DatastoreName `
                -TimeoutSeconds $DatastoreWaitTimeoutSeconds
        }
        }

        # Configure vSAN witness if provided. When datastore already existed and is usable, skip if witness is already configured.
        if ($vSanWitnessVmName) {
            $skipWitnessAndHealthCheck = $false
            if ($existingDatastoreUsable) {
                try {
                    $vsanConfig = Get-VsanClusterConfiguration -Cluster $ClusterName -Server $Script:vCenterName -ErrorAction SilentlyContinue
                    if ($vsanConfig -and $vsanConfig.WitnessHost -and $vsanConfig.WitnessHost.Name) {
                        $configuredWitnessName = $vsanConfig.WitnessHost.Name
                        if ($configuredWitnessName -eq $vSanWitnessVmName) {
                            $skipWitnessAndHealthCheck = $true
                            Write-LogMessage -Type INFO -Message "vSAN datastore already exists and witness `"$vSanWitnessVmName`" is already configured for cluster `"$ClusterName`". Skipping witness configuration and health check."
                        }
                    }
                } catch {
                    Write-LogMessage -Type DEBUG -Message "Could not check existing vSAN witness configuration for cluster `"$ClusterName`" ($($_.Exception.Message)); proceeding with witness block."
                }
            }
            if (-not $skipWitnessAndHealthCheck) {
                if (-not $PreferredFaultDomainName) {
                    Write-LogMessage -Type ERROR -Message "PreferredFaultDomainName is required when vSanWitnessVmName is provided."
                    throw [VcfDeploymentException]::new("Deployment failed configuring vSAN ESA datastore for cluster `"$ClusterName`": PreferredFaultDomainName is required when configuring vSAN witness (vSanWitnessVmName=`"$vSanWitnessVmName`"). Set common.vSanWitnessVmName (or clusters[].vSanWitnessVmName) and the preferred fault domain name (e.g. edge site name) in your input JSON.")
                }
                $witnessHost = Get-VMHost -Name $vSanWitnessVmName -Server $Script:vCenterName -ErrorAction Stop
                $witnessPoolDisks = Get-VsanStoragePoolDisk -VMHost $witnessHost -Server $Script:vCenterName -ErrorAction SilentlyContinue
                $witnessPoolDiskCount = if ($witnessPoolDisks) { @($witnessPoolDisks).Count } else { 0 }
                Write-LogMessage -Type DEBUG -Message "Witness host `"$vSanWitnessVmName`": checked for existing vSAN ESA storage pool; found $witnessPoolDiskCount disk(s). ESA witness with zero disks is supported."
                Write-LogMessage -Type DEBUG -Message "Calling Set-VsanWitness for cluster `"$ClusterName`" with PreferredFaultDomainName=`"$PreferredFaultDomainName`", vSanWitnessVmName=`"$vSanWitnessVmName`"."
                Write-LogMessage -Type INFO -Message "Configuring vSAN witness host for cluster `"$ClusterName`"."
                Set-VsanWitness -ClusterName $ClusterName -LabEnvironment $LabEnvironment -PreferredFaultDomainName $PreferredFaultDomainName -StoragePolicyType "vSAN-ESA" -vSanWitnessVmName $vSanWitnessVmName
                Invoke-VsanClusterHealthCheckAfterWitness -AcceptBadCheckResults:$AcceptBadCheckResults.IsPresent -ClusterName $ClusterName -LabEnvironment $LabEnvironment -StoragePolicyType "vSAN-ESA"
            }
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
Function Get-EsxUnformattedDisk {

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
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EsxHostName,
        [Parameter(Mandatory = $false)] [Switch]$Silence,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [VMware.VimAutomation.ViCore.Types.V1.Inventory.VMHost]$VmHost
    )

    Write-LogMessage -Type DEBUG -Message "Entered Get-EsxUnformattedDisk function..."
    Write-LogMessage -Type INFO -SuppressOutputToScreen:$Silence -Message "Scanning for unformatted disks/LUNs on ESX host `"$EsxHostName`"..."

    try {
        $allDisks = $VmHost | Get-ScsiLun -LunType disk
        $mountedDatastores = Get-Datastore -VMHost $VmHost

        $usedDisks = [System.Collections.ArrayList]::new()
        foreach ($ds in $mountedDatastores) {
            $dsView = Get-View -Id $ds.ExtensionData.MoRef -Server $Script:vCenterName
            if ($dsView.Info.Vmfs) {
                foreach ($extent in $dsView.Info.Vmfs.Extent) {
                    [void]$usedDisks.Add($extent.DiskName)
                }
            }
        }

        $usedDisksArray = $usedDisks.ToArray()
        $unformattedDisks = $allDisks | Where-Object {
            $diskUuid = $_.CanonicalName
            $usedDisksArray -notcontains $diskUuid -and
            $null -ne $_.MultipathPolicy  # Exclude pseudo disks.
        }

        $unformattedDiskArray = [System.Collections.ArrayList]::new()

        if ($unformattedDisks -and $unformattedDisks.Count -gt 0) {
            Write-LogMessage -Type INFO -SuppressOutputToScreen:$Silence -Message "Found $($unformattedDisks.Count) unformatted disk(s) on ESX host `"$EsxHostName`"."

            $diskId = 1
            foreach ($disk in $unformattedDisks) {
                $unformattedInfo = [PSCustomObject]@{
                    ID = $diskId
                    CanonicalName = $disk.CanonicalName
                    UUID = $disk.Uuid
                    CapacityGB = [math]::Round(($disk.CapacityGB), 2)
                    Vendor = $disk.Vendor
                    Model = $disk.Model
                    MultipathPolicy = $disk.MultipathPolicy
                    RuntimeName = $disk.RuntimeName
                }
                [void]$unformattedDiskArray.Add($unformattedInfo)

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
        Write-LogMessage -Type ERROR -Message "Failed to scan for unformatted disks on ESX host `"$EsxHostName`": $($_.Exception.Message)"
        throw [VcfDeploymentException]::new("Failed to scan for unformatted disks on ESX host `"$EsxHostName`": $($_.Exception.Message)")
    }
}
Function Get-EsxDatastoreHealth {

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
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DatastoreName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EsxHostName,
        [Parameter(Mandatory = $false)] [ValidateRange(0, 100)] [Int]$FreeSpaceWarningThreshold = 10,
        [Parameter(Mandatory = $false)] [Switch]$Silence,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [VMware.VimAutomation.ViCore.Types.V1.Inventory.VMHost]$VmHost
    )

    Write-LogMessage -Type DEBUG -Message "Entered Get-EsxDatastoreHealth function..."
    Write-LogMessage -Type DEBUG -SuppressOutputToScreen:$Silence -Message "Validating mounted datastore `"$DatastoreName`" on ESX host `"$EsxHostName`"..."

    try {
        $targetDatastore = Get-Datastore -Name $DatastoreName -VMHost $VmHost -ErrorAction Stop

        $dsView = Get-View -Id $targetDatastore.ExtensionData.MoRef
        $isVmfs = $targetDatastore.Type -eq "VMFS"
        $vmfsVersion = if ($isVmfs -and $dsView.Info.Vmfs) { $dsView.Info.Vmfs.Version } else { $null }
        $datastoreUuid = if ($isVmfs -and $dsView.Info.Vmfs) { $dsView.Info.Vmfs.Uuid } else { $null }

        $isHealthy = $true
        $healthIssues = @()

        # Use State instead of the deprecated Accessible property; "Available" means healthy.

        if ($targetDatastore.State -ne "Available") {
            $isHealthy = $false
            $healthIssues += "Datastore state is: $($targetDatastore.State)"
        }

        $freeSpacePercent = if ($targetDatastore.CapacityGB -gt 0) {
            [math]::Round(($targetDatastore.FreeSpaceGB / $targetDatastore.CapacityGB * 100), 2)
        } else {
            0
        }
        if ($freeSpacePercent -lt $FreeSpaceWarningThreshold) {
            $healthIssues += "Low free space: $freeSpacePercent%"
        }

        $datastoreStatus = [PSCustomObject]@{
            Name = $targetDatastore.Name
            IsMounted = $true
            Type = $targetDatastore.Type
            IsVMFS = $isVmfs
            FileSystemVersion = $vmfsVersion
            UUID = $datastoreUuid
            CanonicalName = if ($isVmfs -and $dsView.Info.Vmfs -and $dsView.Info.Vmfs.Extent.Count -gt 0) { $dsView.Info.Vmfs.Extent[0].DiskName } else { $null }
            CapacityGB = [math]::Round($targetDatastore.CapacityGB, 2)
            FreeSpaceGB = [math]::Round($targetDatastore.FreeSpaceGB, 2)
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
Function Get-EsxDatastoreInfo {

    <#
        .SYNOPSIS
        Scans an ESX host for unformatted datastores and validates mounted datastores.

        .DESCRIPTION
        Orchestrator function that provides backward-compatible interface to datastore scanning operations.
        Delegates to specialized helper functions for improved maintainability:
        - Get-EsxUnformattedDisk: Scans for unformatted disks
        - Get-EsxDatastoreHealth: Validates datastore health

        The function reports UUID, capacity, and health status for discovered datastores.
        This function requires a direct connection to the ESX host.

        Key features:
        - Identifies unformatted storage devices available for use
        - Validates health of mounted datastores including accessibility, state, and free space
        - Provides detailed capacity information for all discovered storage
        - Returns structured data for programmatic processing

        .PARAMETER EsxHostName
        The hostname or IP address of the ESX host to scan. This parameter is mandatory.
        Requires an active direct connection to the ESX host.

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

    Param (
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$DatastoreName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EsxHostName,
        [Parameter(Mandatory = $false)] [Switch]$Silence
    )

    Write-LogMessage -Type DEBUG -Message "Entered Get-EsxDatastoreInfo function..."

    $connectionTest = Test-VcenterConnection
    if (-not $connectionTest.IsConnected) {
        Write-LogMessage -Type ERROR -Message "Not connected to vCenter `"$Script:vCenterName`": $($connectionTest.ErrorMessage)"
        throw [VcfDeploymentException]::new("Not connected to vCenter `"$Script:vCenterName`": $($connectionTest.ErrorMessage)")
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
            $vmHost = Get-VMHost -Name $EsxHostName -Server $EsxHostName -ErrorAction Stop
        }
        catch [System.UnauthorizedAccessException] {
            Write-LogMessage -Type ERROR -Message "Cannot access ESX host `"$EsxHostName`" due to authorization issues: $($_.Exception.Message)"
            throw [VcfDeploymentException]::new("Cannot access ESX host `"$EsxHostName`" due to authorization issues: $($_.Exception.Message)")
        }
        catch [System.TimeoutException] {
            Write-LogMessage -Type ERROR -Message "Cannot access ESX host `"$EsxHostName`" due to network/timeout issues: $($_.Exception.Message)"
            throw [VcfDeploymentException]::new("Cannot access ESX host `"$EsxHostName`" due to network/timeout issues: $($_.Exception.Message)")
        } catch [VcfDeploymentException] {
            throw  # already logged and typed — propagate without re-wrapping
        } catch {
            Write-LogMessage -Type ERROR -Message "Failed to get ESX host `"$EsxHostName`": $($_.Exception.Message)"
            throw [VcfDeploymentException]::new("Failed to get ESX host `"$EsxHostName`": $($_.Exception.Message)")
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

        # Return the result object.
        return $result
    } catch [VcfDeploymentException] {
        throw  # already logged and typed — propagate without re-wrapping
    } catch {
        Write-LogMessage -Type ERROR -SuppressOutputToScreen:$Silence -Message "Failed to scan ESX host `"$EsxHostName`": $($_.Exception.Message)"
        throw [VcfDeploymentException]::new()
    }
}

#endregion
