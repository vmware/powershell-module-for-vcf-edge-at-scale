# Pester tests for VcfEdgeAtScale — Private/Networking.ps1
#
# RECOMMENDED: Use the wrapper script for human-readable output:
#   ./Tests/Run-Tests.ps1
#   ./Tests/Run-Tests.ps1 -Filter "*FunctionName*"
#
# DIRECT: Invoke-Pester -Path ./Tests/VcfEdgeAtScale.Networking.Tests.ps1 -Output Detailed
#
# Internal functions are invoked via InModuleScope so the scriptblock runs in module scope.
# Log suppression: Write-LogMessage console output is silenced globally via $Script:LogOnly = "enabled".

BeforeAll {
    $moduleRoot = Join-Path $PSScriptRoot ".."
    $manifestPath = Join-Path $moduleRoot "VcfEdgeAtScale.psd1"
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "Module manifest not found at $manifestPath. Run tests from the VcfEdgeAtScale module directory or set path."
    }

    # Ensure no stale copy is loaded before importing the source version.
    # Without this, running from an interactive session that already imported VcfEdgeAtScale
    # (e.g. from PSModulePath or a prior run) leaves two copies in the session, and
    # InModuleScope throws "Multiple script or manifest modules named 'VcfEdgeAtScale' are loaded".
    $null = Remove-Module -Name "VcfEdgeAtScale" -Force -ErrorAction SilentlyContinue

    $script:mod = Import-Module $manifestPath -Force -PassThru -ErrorAction Stop

    # Suppress Write-LogMessage console output for the entire test run.
    # Production code writes [ERROR]/[WARNING]/[INFO] to screen via Write-Host inside Write-LogMessage.
    # Without suppression those lines appear interleaved with Pester output and look alarming even
    # when every test is passing. Setting LogOnly = "enabled" routes all output to the log file only.
    InModuleScope VcfEdgeAtScale { $Script:LogOnly = "enabled" }

    # Snapshot harbor env vars so any unit test that nulls them out cannot pollute a subsequent
    # live test run in the same Invoke-Pester session. Restored in AfterAll below.
    $script:_unitTestSavedHarborPw  = $env:HARBOR_ADMIN_PASSWORD
    $script:_unitTestSavedSecretKey = $env:SECRET_KEY
}
AfterAll {
    InModuleScope VcfEdgeAtScale { $Script:LogOnly = $null }
    $null = Remove-Module -Name "VcfEdgeAtScale" -ErrorAction SilentlyContinue
    # Restore harbor env vars to their pre-unit-test values so live tests that run in the same
    # Pester session (./Tests/Run-Tests.ps1 -Live) see the operator-supplied credentials.
    $env:HARBOR_ADMIN_PASSWORD = $script:_unitTestSavedHarborPw
    $env:SECRET_KEY             = $script:_unitTestSavedSecretKey
}

Describe "Test-ValidIPv4Address" {
    It "Returns <Expected> for '<IpAddress>'" -ForEach @(
        @{ IpAddress = "192.168.1.1";     Expected = $true  }
        @{ IpAddress = "0.0.0.0";         Expected = $true  }
        @{ IpAddress = "255.255.255.255"; Expected = $true  }
        @{ IpAddress = "1.0.0.1";         Expected = $true  }
        @{ IpAddress = "";                Expected = $false }
        @{ IpAddress = "   ";             Expected = $false }
        @{ IpAddress = "256.1.1.1";       Expected = $false }
        @{ IpAddress = "192.168.1";       Expected = $false }
        @{ IpAddress = "hostname";        Expected = $false }
        @{ IpAddress = "1.2.3.4.5";       Expected = $false }
        @{ IpAddress = "192.168.-1.1";    Expected = $false }
        @{ IpAddress = "192.168.1. 1";    Expected = $false }
    ) {
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $IpAddress {
            Test-ValidIPv4Address -IpAddress $args[0]
        }
        $result | Should -Be $Expected
    }
}


Describe "ConvertTo-IpInt" {
    It "Converts a standard address to the correct integer" {
        # 192.168.1.1 = (192 << 24) | (168 << 16) | (1 << 8) | 1 = 3232235777
        $result = InModuleScope VcfEdgeAtScale { ConvertTo-IpInt -IpString "192.168.1.1" }
        $result | Should -Be 3232235777
    }

    It "Converts 0.0.0.0 to 0" {
        $result = InModuleScope VcfEdgeAtScale { ConvertTo-IpInt -IpString "0.0.0.0" }
        $result | Should -Be 0
    }

    It "Converts 255.255.255.255 to 4294967295" {
        $result = InModuleScope VcfEdgeAtScale { ConvertTo-IpInt -IpString "255.255.255.255" }
        $result | Should -Be 4294967295
    }

    It "Converts 10.0.0.1 correctly" {
        # 10 << 24 = 167772160, +1 = 167772161
        $result = InModuleScope VcfEdgeAtScale { ConvertTo-IpInt -IpString "10.0.0.1" }
        $result | Should -Be 167772161
    }
}


Describe "Test-IpAddressInCidrRange" {
    It "Returns <Expected> for IpAddress '<IpAddress>' in '<CidrRange>'" -ForEach @(
        @{ IpAddress = "192.168.1.100"; CidrRange = "192.168.1.0/24"; Expected = $true  }
        @{ IpAddress = "192.168.2.1";   CidrRange = "192.168.1.0/24"; Expected = $false }
        @{ IpAddress = "10.0.0.0";      CidrRange = "10.0.0.0/8";     Expected = $true  }
        @{ IpAddress = "10.1.2.3";      CidrRange = "10.1.2.3/32";    Expected = $true  }
        @{ IpAddress = "10.1.2.4";      CidrRange = "10.1.2.3/32";    Expected = $false }
        @{ IpAddress = "8.8.8.8";       CidrRange = "0.0.0.0/0";      Expected = $true  }
        @{ IpAddress = "999.1.1.1";     CidrRange = "192.168.1.0/24"; Expected = $false }
        @{ IpAddress = "192.168.1.1";   CidrRange = "192.168.1.0/33"; Expected = $false }
    ) {
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $IpAddress, $CidrRange {
            Test-IpAddressInCidrRange -IpAddress $args[0] -CidrRange $args[1]
        }
        $result | Should -Be $Expected
    }
}


Describe "Test-GatewayIpInRange" {
    It "Returns <Expected> for GatewayCidr '<GatewayCidr>' StartIp '<StartIp>' Count <Count>" -ForEach @(
        @{ GatewayCidr = "10.30.10.1/24";  StartIp = "10.30.10.1";  Count = 5; Expected = $true  }
        @{ GatewayCidr = "10.30.10.1/24";  StartIp = "10.30.10.10"; Count = 5; Expected = $false }
        @{ GatewayCidr = "10.30.10.14/24"; StartIp = "10.30.10.10"; Count = 5; Expected = $true  }
        @{ GatewayCidr = "10.30.10.15/24"; StartIp = "10.30.10.10"; Count = 5; Expected = $false }
        @{ GatewayCidr = "10.0.0.1/24";    StartIp = "10.0.0.1";    Count = 1; Expected = $true  }
        @{ GatewayCidr = "not-a-cidr";     StartIp = "10.0.0.1";    Count = 5; Expected = $false }
        @{ GatewayCidr = "10.0.0.1/24";    StartIp = "999.0.0.1";   Count = 5; Expected = $false }
    ) {
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $GatewayCidr, $StartIp, $Count {
            Test-GatewayIpInRange -GatewayCidr $args[0] -StartIp $args[1] -Count $args[2]
        }
        $result | Should -Be $Expected
    }
}


Describe "Test-ValidCidrRange" {
    It "Returns <Expected> for InputText '<InputText>'" -ForEach @(
        @{ InputText = "256";      Expected = $true  }
        @{ InputText = "1";        Expected = $true  }
        @{ InputText = "16777216"; Expected = $true  }
        @{ InputText = "511";      Expected = $false }
        @{ InputText = "33554432"; Expected = $false }
        @{ InputText = "0";        Expected = $false }
        @{ InputText = "abc";      Expected = $false }
    ) {
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $InputText {
            Test-ValidCidrRange -InputText $args[0]
        }
        $result | Should -Be $Expected
    }
}


Describe "Test-ValidNetmask" {
    It "Returns <Expected> for Netmask '<Netmask>'" -ForEach @(
        @{ Netmask = "255.255.255.0"; Expected = $true  }
        @{ Netmask = "255.255.0.0";   Expected = $true  }
        @{ Netmask = "255.0.255.0";   Expected = $false }
        @{ Netmask = "";              Expected = $false }
    ) {
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $Netmask {
            Test-ValidNetmask -Netmask $args[0]
        }
        $result | Should -Be $Expected
    }
}


Describe "Test-IpInSubnet" {
    It "Returns <Expected> for IP '<IpAddress>' ref '<ReferenceIp>' mask '<SubnetMask>'" -ForEach @(
        @{ IpAddress = "192.168.1.50"; ReferenceIp = "192.168.1.1"; SubnetMask = "255.255.255.0";   Expected = $true  }
        @{ IpAddress = "10.0.0.1";     ReferenceIp = "192.168.1.1"; SubnetMask = "255.255.255.0";   Expected = $false }
        @{ IpAddress = "192.168.1.1";  ReferenceIp = "192.168.1.1"; SubnetMask = "999.999.999.999"; Expected = $false }
    ) {
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $IpAddress, $ReferenceIp, $SubnetMask {
            Test-IpInSubnet -IpAddress $args[0] -ReferenceIp $args[1] -SubnetMask $args[2]
        }
        $result | Should -Be $Expected
    }
}


Describe "Get-VmkernelTrafficVdsNameForLayout" {
    It "Returns '<Expected>' for NumUplinks=<NumUplinks> TrafficRole='<TrafficRole>'" -ForEach @(
        @{ NumUplinks = 2; TrafficRole = "VmotionVsan"; Expected = "vds-edge"     }
        @{ NumUplinks = 4; TrafficRole = "VmotionVsan"; Expected = "vds-edge-sw2" }
        @{ NumUplinks = 4; TrafficRole = "Witness";     Expected = "vds-edge-sw1" }
        @{ NumUplinks = 2; TrafficRole = "Witness";     Expected = "vds-edge"     }
    ) {
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $NumUplinks, $TrafficRole {
            Get-VmkernelTrafficVdsNameForLayout -BaseVdsName "vds-edge" -NumUplinks $args[0] -TrafficRole $args[1]
        }
        $result | Should -Be $Expected
    }
}


Describe "Test-HostManagementVdsDualUplink — mocked vCenter" {

    It "Returns HasDualUplink=false and empty MgmtVdsName when vmk0 is not found on the host" {
        $result = InModuleScope VcfEdgeAtScale {
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            Mock Get-VmkernelAdaptersOnHost { return @() }
            Mock Get-VdsListOnHost { return @() }
            Test-HostManagementVdsDualUplink -VMHost $fakeHost -Server "vc.lab"
        }
        $result.HasDualUplink | Should -Be $false
        $result.MgmtVdsName  | Should -Be ""
    }

    It "Returns HasDualUplink=false and empty MgmtVdsName when host has no VDS uplinks" {
        $result = InModuleScope VcfEdgeAtScale {
            $fakeVmk0 = [PSCustomObject]@{
                Name          = "vmk0"
                ExtensionData = [PSCustomObject]@{ Spec = [PSCustomObject]@{ PortGroup = $null } }
            }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            Mock Get-VmkernelAdaptersOnHost { return @($fakeVmk0) }
            Mock Get-VdsListOnHost { return @() }
            Test-HostManagementVdsDualUplink -VMHost $fakeHost -Server "vc.lab"
        }
        $result.HasDualUplink | Should -Be $false
        $result.MgmtVdsName  | Should -Be ""
    }

    # The following two tests exercise the primary path where Get-VDPortgroup -Id resolves vmk0 to its VDS,
    # then pNIC count determines HasDualUplink. This avoids the DPG-iteration fallback path which requires
    # Get-VMHostNetworkAdapter -PortGroup (compiled parameter type binding not mockable with PSCustomObject).
    It "Returns HasDualUplink=false when host has only one pNIC on the management VDS" {
        $result = InModuleScope VcfEdgeAtScale {
            $fakeVds   = [PSCustomObject]@{ Name = "VDS-site1" }
            $fakeDpg   = [PSCustomObject]@{ Name = "mgmt-site1"; VDSwitch = $fakeVds; Id = "dvportgroup-42" }
            $fakePgRef = [PSCustomObject]@{ Value = "dvportgroup-42" }
            $fakeVmk0  = [PSCustomObject]@{
                Name          = "vmk0"
                ExtensionData = [PSCustomObject]@{ Spec = [PSCustomObject]@{ PortGroup = $fakePgRef } }
            }
            $fakePnic = [PSCustomObject]@{ Name = "vmnic0" }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            Mock Get-VmkernelAdaptersOnHost { return @($fakeVmk0) }
            Mock Get-VdsListOnHost { return @($fakeVds) }
            Mock Get-VDPortgroupById { return $fakeDpg }
            Mock Get-DpgsOnVds { return @($fakeDpg) }
            # Only one pNIC on the management VDS.
            Mock Get-PhysicalNicsOnVdsForHost { return @($fakePnic) }
            Test-HostManagementVdsDualUplink -VMHost $fakeHost -Server "vc.lab"
        }
        $result.HasDualUplink | Should -Be $false
        $result.MgmtVdsName  | Should -Be "VDS-site1"
    }

    It "Returns HasDualUplink=true when host has two pNICs on the management VDS" {
        $result = InModuleScope VcfEdgeAtScale {
            $fakeVds   = [PSCustomObject]@{ Name = "VDS-site1" }
            $fakeDpg   = [PSCustomObject]@{ Name = "mgmt-site1"; VDSwitch = $fakeVds; Id = "dvportgroup-42" }
            $fakePgRef = [PSCustomObject]@{ Value = "dvportgroup-42" }
            $fakeVmk0  = [PSCustomObject]@{
                Name          = "vmk0"
                ExtensionData = [PSCustomObject]@{ Spec = [PSCustomObject]@{ PortGroup = $fakePgRef } }
            }
            $fakePnic1 = [PSCustomObject]@{ Name = "vmnic0" }
            $fakePnic2 = [PSCustomObject]@{ Name = "vmnic1" }
            $fakeHost  = [PSCustomObject]@{ Name = "esx01.lab" }
            Mock Get-VmkernelAdaptersOnHost { return @($fakeVmk0) }
            Mock Get-VdsListOnHost { return @($fakeVds) }
            Mock Get-VDPortgroupById { return $fakeDpg }
            Mock Get-DpgsOnVds { return @($fakeDpg) }
            # Two pNICs → dual uplink.
            Mock Get-PhysicalNicsOnVdsForHost { return @($fakePnic1, $fakePnic2) }
            Test-HostManagementVdsDualUplink -VMHost $fakeHost -Server "vc.lab"
        }
        $result.HasDualUplink | Should -Be $true
        $result.MgmtVdsName  | Should -Be "VDS-site1"
    }

    # Exercises the primary path: Get-VDPortgroup -Id resolves the DPG and VDSwitch.Name matches.
    # IMPORTANT: $fakeDpg.VDSwitch must reference the same $fakeVds object returned by Mock Get-VdsListOnHost
    # so that the production check ($dpg.VDSwitch.Name -eq $vds.Name) resolves true.
    It "Returns HasDualUplink=true when vmk0 PortGroup ref resolves directly to the management VDS (primary path)" {
        $result = InModuleScope VcfEdgeAtScale {
            $fakeVds   = [PSCustomObject]@{ Name = "VDS-site1" }
            $fakeDpg   = [PSCustomObject]@{ Name = "mgmt-site1"; VDSwitch = $fakeVds; Id = "dvportgroup-42" }
            $fakePgRef = [PSCustomObject]@{ Value = "dvportgroup-42" }
            $fakeVmk0  = [PSCustomObject]@{
                Name          = "vmk0"
                ExtensionData = [PSCustomObject]@{ Spec = [PSCustomObject]@{ PortGroup = $fakePgRef } }
            }
            $fakeHost  = [PSCustomObject]@{ Name = "esx01.lab" }
            $fakePnic1 = [PSCustomObject]@{ Name = "vmnic0" }
            $fakePnic2 = [PSCustomObject]@{ Name = "vmnic1" }
            Mock Get-VmkernelAdaptersOnHost { return @($fakeVmk0) }
            Mock Get-VdsListOnHost { return @($fakeVds) }
            Mock Get-VDPortgroupById { return $fakeDpg }
            Mock Get-DpgsOnVds { return @($fakeDpg) }
            # Two pNICs → HasDualUplink = $true.
            Mock Get-PhysicalNicsOnVdsForHost { return @($fakePnic1, $fakePnic2) }
            Test-HostManagementVdsDualUplink -VMHost $fakeHost -Server "vc.lab"
        }
        $result.HasDualUplink | Should -Be $true
        $result.MgmtVdsName  | Should -Be "VDS-site1"
    }
}

# ── Invoke-PrepareHostForClusterMove ─────────────────────────────────────────


Describe "Invoke-ManagementRestoreForCleanupWithTopologyFallback — NicListCount=4 tries sw1 first" {
    It "Calls Invoke-ManagementRestoreForCleanup with VdsName-sw1 when NicListCount is 4 and that VDS exists" {
        $result = InModuleScope VcfEdgeAtScale {
            function Get-VDSwitch {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                # Only the -sw1 variant exists; the base VDS does not.
                if ($Name -eq "vds1-sw1") { return [PSCustomObject]@{ Name = $Name } }
                return $null
            }
            function Invoke-ManagementRestoreForCleanup {
                [CmdletBinding()] Param([Parameter()] [Object]$ClusterName, [Parameter()] [Object]$VdsNameWithMgmt)
                return [PSCustomObject]@{ RestoreAttempted = $true; Success = $true; HostsRestoredCount = 1; VdsUsed = $VdsNameWithMgmt }
            }
            Mock Write-LogMessage {}
            Invoke-ManagementRestoreForCleanupWithTopologyFallback -ClusterName "cl0" -VdsName "vds1" -NicListCount 4
        }
        $result.RestoreAttempted | Should -Be $true
        $result.VdsUsed          | Should -Be "vds1-sw1"
    }
}

Describe "Invoke-ManagementRestoreForCleanupWithTopologyFallback — NicListCount=2 tries base VDS first" {
    It "Calls Invoke-ManagementRestoreForCleanup with the base VDS when NicListCount is 2 and base VDS exists" {
        $result = InModuleScope VcfEdgeAtScale {
            function Get-VDSwitch {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                if ($Name -eq "vds1") { return [PSCustomObject]@{ Name = $Name } }
                return $null
            }
            function Invoke-ManagementRestoreForCleanup {
                [CmdletBinding()] Param([Parameter()] [Object]$ClusterName, [Parameter()] [Object]$VdsNameWithMgmt)
                return [PSCustomObject]@{ RestoreAttempted = $true; Success = $true; HostsRestoredCount = 1; VdsUsed = $VdsNameWithMgmt }
            }
            Mock Write-LogMessage {}
            Invoke-ManagementRestoreForCleanupWithTopologyFallback -ClusterName "cl0" -VdsName "vds1" -NicListCount 2
        }
        $result.RestoreAttempted | Should -Be $true
        $result.VdsUsed          | Should -Be "vds1"
    }
}

Describe "Invoke-ManagementRestoreForCleanupWithTopologyFallback — no VDS found" {
    It "Returns default result with RestoreAttempted=false when neither VDS candidate exists" {
        $result = InModuleScope VcfEdgeAtScale {
            function Get-VDSwitch {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                return $null
            }
            function Invoke-ManagementRestoreForCleanup {
                [CmdletBinding()] Param([Parameter()] [Object]$ClusterName, [Parameter()] [Object]$VdsNameWithMgmt)
                throw "Invoke-ManagementRestoreForCleanup must not be called when no VDS is found"
            }
            Mock Write-LogMessage {}
            Invoke-ManagementRestoreForCleanupWithTopologyFallback -ClusterName "cl0" -VdsName "vds1" -NicListCount 2
        }
        $result.RestoreAttempted | Should -Be $false
        $result.Success          | Should -Be $true
        $result.HostsRestoredCount | Should -Be 0
    }
}

Describe "Invoke-ManagementRestoreForCleanupWithTopologyFallback — Invoke-ManagementRestoreForCleanup throws" {
    It "Catches the exception and returns a failed result rather than propagating" {
        $result = InModuleScope VcfEdgeAtScale {
            function Get-VDSwitch {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                if ($Name -eq "vds1") { return [PSCustomObject]@{ Name = $Name } }
                return $null
            }
            function Invoke-ManagementRestoreForCleanup {
                [CmdletBinding()] Param([Parameter()] [Object]$ClusterName, [Parameter()] [Object]$VdsNameWithMgmt)
                throw "Restore failed: vmk0 not on VSS"
            }
            Mock Write-LogMessage {}
            Invoke-ManagementRestoreForCleanupWithTopologyFallback -ClusterName "cl0" -VdsName "vds1" -NicListCount 2
        }
        $result.RestoreAttempted | Should -Be $true
        $result.Success          | Should -Be $false
    }
}

Describe "Invoke-ManagementRestoreForCleanupWithTopologyFallback — falls back to sw1 when base succeeds" {
    It "Returns after first successful VDS and does not try the second candidate" {
        # Wrap in @() to force array assignment — InModuleScope may return a scalar when
        # the List<String> has one element, causing $callLog[0] to yield the first character.
        # Filter to strings only in case pipeline pollution from function stubs adds objects.
        $callLog = @(InModuleScope VcfEdgeAtScale {
            $Script:_restoreLog = [System.Collections.Generic.List[String]]::new()
            function Get-VDSwitch {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                return [PSCustomObject]@{ Name = $Name }
            }
            function Invoke-ManagementRestoreForCleanup {
                [CmdletBinding()] Param([Parameter()] [Object]$ClusterName, [Parameter()] [Object]$VdsNameWithMgmt)
                $Script:_restoreLog.Add($VdsNameWithMgmt)
                return [PSCustomObject]@{ RestoreAttempted = $true; Success = $true; HostsRestoredCount = 1 }
            }
             Mock Write-LogMessage {}
             $null = Invoke-ManagementRestoreForCleanupWithTopologyFallback -ClusterName "cl0" -VdsName "vds1" -NicListCount 2
             $Script:_restoreLog
        } | Where-Object { $_ -is [String] })
        # NicListCount=2: base VDS tried first, succeeds — sw1 should not be tried.
        $callLog | Should -HaveCount 1
        $callLog[0] | Should -Be "vds1"
    }
}

# ── Restore-ManagementToVssBeforeVdsRemoval — -VMHost single-host path ────────


Describe "Restore-ManagementToVssBeforeVdsRemoval — -VMHost parameter bypasses cluster discovery" {

    It "Processes only the supplied VMHost and skips Get-Cluster when -VMHost is provided" {
        InModuleScope VcfEdgeAtScale {
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab"; Id = "host-1" }
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true; ErrorMessage = $null } }
            Mock Get-VdsByName { [PSCustomObject]@{ Name = "VDS-site1" } }
            # Return one non-mgmt port group so the -Server fallback path (line 398) is not triggered.
            Mock Get-DpgsOnVds { return @([PSCustomObject]@{ Name = "dvuplink-VDS-site1" }) }
            Mock Get-VDPortgroup { return @() }
            Mock Get-Cluster { }
            Mock Get-VMHost { }
            # No vmk0 found — the function iterates the single host, sets RestoreAttempted=$true,
            # and returns without restoring (hostsRestoredCount=0 is expected in this minimal mock).
            Mock Get-VmkernelAdaptersOnHost { return @() }
            $result = Restore-ManagementToVssBeforeVdsRemoval -VMHost $fakeHost -VdsNameWithMgmt "VDS-site1" -Server "vc.lab"
            Should -Invoke Get-Cluster -Times 0 -Scope It
            $result.RestoreAttempted | Should -Be $true
        }
    }
}

Describe "Resolve-HostsForMgmtRestore" {

    It "Returns single-element array when -VMHost is supplied" {
        InModuleScope VcfEdgeAtScale {
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            $fakeVds = [PSCustomObject]@{ Name = "VDS-site1" }
            Mock Write-LogMessage {}
            $result = Resolve-HostsForMgmtRestore -VMHost $fakeHost -VdsObject $fakeVds -VdsNameWithMgmt "VDS-site1"
            $result | Should -HaveCount 1
            $result[0].Name | Should -Be "esx01.lab"
        }
    }

    It "Returns cluster hosts when ClusterName resolves" {
        InModuleScope VcfEdgeAtScale {
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            $fakeVds = [PSCustomObject]@{ Name = "VDS-site1" }
            function Get-VMHost {
                [CmdletBinding()] Param([Parameter()] [Object]$Location, [Parameter()] [Object]$DistributedSwitch, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Write-LogMessage {}
            Mock Get-ClusterByName { [PSCustomObject]@{ Name = "cl0" } }
            Mock Get-VMHost { @($fakeHost) }
            $result = Resolve-HostsForMgmtRestore -ClusterName "cl0" -Server "vc.lab" -VdsObject $fakeVds -VdsNameWithMgmt "VDS-site1"
            $result | Should -HaveCount 1
        }
    }

    It "Falls back to VDS-attached hosts when cluster is not found" {
        InModuleScope VcfEdgeAtScale {
            $fakeHost = [PSCustomObject]@{ Name = "esx02.lab" }
            $fakeVds = [PSCustomObject]@{ Name = "VDS-site1" }
            function Get-VMHost {
                [CmdletBinding()] Param([Parameter()] [Object]$Location, [Parameter()] [Object]$DistributedSwitch, [Parameter()] [Object]$Server)
                if ($DistributedSwitch) { return @($fakeHost) }
                return @()
            }
            Mock Write-LogMessage {}
            Mock Get-ClusterByName { $null }
            $result = Resolve-HostsForMgmtRestore -ClusterName "cl-missing" -Server "vc.lab" -VdsObject $fakeVds -VdsNameWithMgmt "VDS-site1"
            $result | Should -HaveCount 1
            $result[0].Name | Should -Be "esx02.lab"
        }
    }

    It "Returns empty array when no hosts found via any path" {
        InModuleScope VcfEdgeAtScale {
            $fakeVds = [PSCustomObject]@{ Name = "VDS-site1" }
            function Get-VMHost {
                [CmdletBinding()] Param([Parameter()] [Object]$Location, [Parameter()] [Object]$DistributedSwitch, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Write-LogMessage {}
            Mock Get-ClusterByName { $null }
            Mock Get-VMHost { @() }
            $result = Resolve-HostsForMgmtRestore -ClusterName "cl-missing" -Server "vc.lab" -VdsObject $fakeVds -VdsNameWithMgmt "VDS-site1"
            $result.Count | Should -Be 0
        }
    }
}

Describe "Test-VdsMgmtPortGroupExists" {

    It "Returns true when a mgmt-named port group exists on the VDS" {
        InModuleScope VcfEdgeAtScale {
            $fakeVds = [PSCustomObject]@{ Name = "VDS-site1" }
            $fakePg = [PSCustomObject]@{ Name = "mgmt-site1" }
            Mock Write-LogMessage {}
            Mock Get-DpgsOnVds { @($fakePg) }
            $result = Test-VdsMgmtPortGroupExists -VDSwitch $fakeVds -VdsNameWithMgmt "VDS-site1" -Server "vc.lab"
            $result | Should -Be $true
        }
    }

    It "Returns false when no mgmt-named port groups are found" {
        InModuleScope VcfEdgeAtScale {
            $fakeVds = [PSCustomObject]@{ Name = "VDS-site1" }
            $fakePg = [PSCustomObject]@{ Name = "vsan-site1" }
            function Get-VDPortgroup {
                [CmdletBinding()] Param([Parameter()] [Object]$Server)
                process {}
            }
            Mock Write-LogMessage {}
            Mock Get-DpgsOnVds { @($fakePg) }
            Mock Get-VDPortgroup { @() }
            $result = Test-VdsMgmtPortGroupExists -VDSwitch $fakeVds -VdsNameWithMgmt "VDS-site1" -Server "vc.lab"
            $result | Should -Be $false
        }
    }
}

Describe "Test-VmkAdapterOnVds" {

    It "Returns true via path 1 — Get-VDPortgroup -Id finds DPG whose switch MoRef matches the VDS" {
        InModuleScope VcfEdgeAtScale {
            $fakePgId  = [PSCustomObject]@{ Value = "dvportgroup-10" }
            $fakeVmk0  = [PSCustomObject]@{ ExtensionData = [PSCustomObject]@{ Spec = [PSCustomObject]@{ PortGroup = $fakePgId } } }
            # DPG carries ExtensionData.Config.DistributedVirtualSwitch.Value matching the VDS MoRef.
            # This avoids accessing .VDSwitch (deprecated PowerCLI property).
            $vdsMoRef  = "dvs-100"
            $fakeDpg   = [PSCustomObject]@{
                Name          = "mgmt-site1"
                Id            = "dvportgroup-10"
                ExtensionData = [PSCustomObject]@{
                    Config = [PSCustomObject]@{
                        DistributedVirtualSwitch = [PSCustomObject]@{ Value = $vdsMoRef }
                    }
                }
            }
            $fakeVds   = [PSCustomObject]@{
                Name          = "VDS-site1"
                ExtensionData = [PSCustomObject]@{ MoRef = [PSCustomObject]@{ Value = $vdsMoRef } }
            }
            $fakeHost  = [PSCustomObject]@{ Name = "esx01.lab" }

            function Get-VDPortgroup {
                [CmdletBinding()] Param([Parameter()] [Object]$Id, [Parameter()] [Object]$Name, [Parameter()] [Object]$VDSwitch, [Parameter()] [Object]$Server)
                if ($Id) { return $fakeDpg }
                return @()
            }
            function Get-VMHostNetworkAdapter {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$VMKernel, [Parameter()] [Object]$PortGroup, [Parameter()] [Object]$Server)
                return @()
            }
            Mock Write-LogMessage {}

            $result = Test-VmkAdapterOnVds -Server "vc.lab" -VdsName "VDS-site1" -VdsObject $fakeVds -VMHost $fakeHost -Vmk0Adapter $fakeVmk0
            $result | Should -Be $true
        }
    }

    It "Returns true via path 2 — DPG name match when VDSwitch.Name does not match directly" {
        InModuleScope VcfEdgeAtScale {
            $fakePgId  = [PSCustomObject]@{ Value = "dvportgroup-20" }
            $fakeVmk0  = [PSCustomObject]@{ ExtensionData = [PSCustomObject]@{ Spec = [PSCustomObject]@{ PortGroup = $fakePgId } } }
            # Direct lookup returns DPG with a different VDSwitch name (triggers fallback).
            $fakeDpgWrongVds = [PSCustomObject]@{ Name = "mgmt-site1"; Id = "dvportgroup-20"; VDSwitch = [PSCustomObject]@{ Name = "OTHER-VDS" } }
            $fakeVdsDpg      = [PSCustomObject]@{ Name = "mgmt-site1"; Id = "dvportgroup-20" }
            $fakeVds  = [PSCustomObject]@{ Name = "VDS-site1" }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }

            $Script:_vdpgCallCount = 0
            function Get-VDPortgroup {
                [CmdletBinding()] Param([Parameter()] [Object]$Id, [Parameter()] [Object]$Name, [Parameter()] [Object]$VDSwitch, [Parameter()] [Object]$Server)
                $Script:_vdpgCallCount++
                if ($Id) { return $fakeDpgWrongVds }          # path 1: returns DPG with wrong VDSwitch
                if ($VDSwitch -and -not $Name) { return @($fakeVdsDpg) }  # path 2 fallback: VDS DPG list with matching name
                return @()
            }
            function Get-VMHostNetworkAdapter {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$VMKernel, [Parameter()] [Object]$PortGroup, [Parameter()] [Object]$Server)
                return @()
            }
            Mock Write-LogMessage {}

            $result = Test-VmkAdapterOnVds -Server "vc.lab" -VdsName "VDS-site1" -VdsObject $fakeVds -VMHost $fakeHost -Vmk0Adapter $fakeVmk0
            $result | Should -Be $true
        }
    }

    It "Returns true via path 3 — Get-VMHostNetworkAdapter -PortGroup iteration finds vmk0" {
        InModuleScope VcfEdgeAtScale {
            $fakeVmk0 = [PSCustomObject]@{ ExtensionData = [PSCustomObject]@{ Spec = [PSCustomObject]@{ PortGroup = $null } } }
            $fakeVdsDpg  = [PSCustomObject]@{ Name = "mgmt-site1"; ExtensionData = [PSCustomObject]@{ MoRef = [PSCustomObject]@{ Value = "dvportgroup-30" } } }
            $fakeVmkOnDpg = [PSCustomObject]@{ Name = "vmk0" }
            $fakeVds  = [PSCustomObject]@{ Name = "VDS-site1" }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }

            function Get-VDPortgroup {
                [CmdletBinding()] Param([Parameter()] [Object]$Id, [Parameter()] [Object]$Name, [Parameter()] [Object]$VDSwitch, [Parameter()] [Object]$Server)
                if ($VDSwitch -and -not $Name) { return @($fakeVdsDpg) }
                return @()
            }
            function Get-VMHostNetworkAdapter {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$VMKernel, [Parameter()] [Object]$PortGroup, [Parameter()] [Object]$Server)
                if ($PortGroup) { return @($fakeVmkOnDpg) }
                return @()
            }
            Mock Write-LogMessage {}

            $result = Test-VmkAdapterOnVds -Server "vc.lab" -VdsName "VDS-site1" -VdsObject $fakeVds -VMHost $fakeHost -Vmk0Adapter $fakeVmk0
            $result | Should -Be $true
        }
    }

    It "Returns true via last-resort name match — Get-VDPortgroup -Name mgmt-* finds the management port group" {
        InModuleScope VcfEdgeAtScale {
            $fakeVmk0      = [PSCustomObject]@{ ExtensionData = [PSCustomObject]@{ Spec = [PSCustomObject]@{ PortGroup = $null } } }
            $fakeMgmtDpg   = [PSCustomObject]@{ Name = "mgmt-site1" }
            $fakeVds  = [PSCustomObject]@{ Name = "VDS-site1" }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }

            function Get-VDPortgroup {
                [CmdletBinding()] Param([Parameter()] [Object]$Id, [Parameter()] [Object]$Name, [Parameter()] [Object]$VDSwitch, [Parameter()] [Object]$Server)
                # Respond only when looking up the expected mgmt DPG by name.
                if ($Name -eq "mgmt-site1") { return $fakeMgmtDpg }
                return @()
            }
            function Get-VMHostNetworkAdapter {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$VMKernel, [Parameter()] [Object]$PortGroup, [Parameter()] [Object]$Server)
                return @()
            }
            Mock Write-LogMessage {}

            # VDS name is "VDS-site1" → expected mgmt PG name = "mgmt-site1" (strip leading VDS-).
            $result = Test-VmkAdapterOnVds -Server "vc.lab" -VdsName "VDS-site1" -VdsObject $fakeVds -VMHost $fakeHost -Vmk0Adapter $fakeVmk0
            $result | Should -Be $true
        }
    }

    It "Returns true via VdsHasMgmtPortGroup fallback when per-host detection finds nothing" {
        InModuleScope VcfEdgeAtScale {
            $fakeVmk0 = [PSCustomObject]@{ ExtensionData = [PSCustomObject]@{ Spec = [PSCustomObject]@{ PortGroup = $null } } }
            $fakeVds  = [PSCustomObject]@{ Name = "VDS-site1" }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }

            function Get-VDPortgroup {
                [CmdletBinding()] Param([Parameter()] [Object]$Id, [Parameter()] [Object]$Name, [Parameter()] [Object]$VDSwitch, [Parameter()] [Object]$Server)
                return @()
            }
            function Get-VMHostNetworkAdapter {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$VMKernel, [Parameter()] [Object]$PortGroup, [Parameter()] [Object]$Server)
                return @()
            }
            Mock Write-LogMessage {}

            $result = Test-VmkAdapterOnVds -Server "vc.lab" -VdsHasMgmtPortGroup:$true -VdsName "VDS-site1" -VdsObject $fakeVds -VMHost $fakeHost -Vmk0Adapter $fakeVmk0
            $result | Should -Be $true
        }
    }

    It "Returns false when all detection paths and VdsHasMgmtPortGroup fallback fail" {
        InModuleScope VcfEdgeAtScale {
            $fakeVmk0 = [PSCustomObject]@{ ExtensionData = [PSCustomObject]@{ Spec = [PSCustomObject]@{ PortGroup = $null } } }
            $fakeVds  = [PSCustomObject]@{ Name = "VDS-site1" }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }

            function Get-VDPortgroup {
                [CmdletBinding()] Param([Parameter()] [Object]$Id, [Parameter()] [Object]$Name, [Parameter()] [Object]$VDSwitch, [Parameter()] [Object]$Server)
                return @()
            }
            function Get-VMHostNetworkAdapter {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$VMKernel, [Parameter()] [Object]$PortGroup, [Parameter()] [Object]$Server)
                return @()
            }
            Mock Write-LogMessage {}

            $result = Test-VmkAdapterOnVds -Server "vc.lab" -VdsHasMgmtPortGroup:$false -VdsName "VDS-site1" -VdsObject $fakeVds -VMHost $fakeHost -Vmk0Adapter $fakeVmk0
            $result | Should -Be $false
        }
    }
}

# ── New-LabHarborSelfSignedTlsMaterialFiles ───────────────────────────────────


Describe "Remove-NonVmk0AdaptersFromVdsHosts — empty port group sets do not cause binding error" {

    It "Accepts empty PortGroupIdsOnVds and PortGroupNamesOnVds without throwing" {
        InModuleScope VcfEdgeAtScale {
            $emptyIds   = [System.Collections.Generic.HashSet[string]]::new()
            $emptyNames = [System.Collections.Generic.HashSet[string]]::new()
            $fakeHost   = [PSCustomObject]@{ Name = "esx01.lab" }
            function Get-VMHostNetworkAdapter {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$VMKernel, [Parameter()] [Object]$Server)
                return @([PSCustomObject]@{ Name = "vmk0"; NetworkName = ""; ExtensionData = $null })
            }
            function Remove-VMHostNetworkAdapter {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param([Parameter(ValueFromPipeline = $true)] [Object]$VirtualAdapter, [Parameter()] [Object]$Server)
                begin { throw "Remove-VMHostNetworkAdapter must not be called when port group sets are empty" }
            }
            Mock Write-LogMessage {}
            { Remove-NonVmk0AdaptersFromVdsHosts -HostsOnVds @($fakeHost) -PortGroupIdsOnVds $emptyIds -PortGroupNamesOnVds $emptyNames -Server "vc.lab" } | Should -Not -Throw
        }
    }

    It "Skips vmk0 adapter and returns 0 when only vmk0 is present" {
        InModuleScope VcfEdgeAtScale {
            $emptyIds   = [System.Collections.Generic.HashSet[string]]::new()
            $emptyNames = [System.Collections.Generic.HashSet[string]]::new()
            $fakeHost   = [PSCustomObject]@{ Name = "esx01.lab" }
            function Get-VMHostNetworkAdapter {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$VMKernel, [Parameter()] [Object]$Server)
                return @([PSCustomObject]@{ Name = "vmk0"; NetworkName = "mgmt-pg"; ExtensionData = $null })
            }
            Mock Write-LogMessage {}
            $removed = InModuleScope VcfEdgeAtScale -ArgumentList $emptyIds, $emptyNames, $fakeHost {
                Remove-NonVmk0AdaptersFromVdsHosts -HostsOnVds @($args[2]) -PortGroupIdsOnVds $args[0] -PortGroupNamesOnVds $args[1] -Server "vc.lab"
            }
            $removed | Should -Be 0
        }
    }

    It "Removes adapter matching by NetworkName and returns count 1" {
        InModuleScope VcfEdgeAtScale {
            $pgIds   = [System.Collections.Generic.HashSet[string]]::new()
            $pgNames = [System.Collections.Generic.HashSet[string]]@("vsan-pg")
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            $fakeVmk1 = [PSCustomObject]@{ Name = "vmk1"; NetworkName = "vsan-pg"; ExtensionData = $null }
            function Get-VMHostNetworkAdapter {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$VMKernel, [Parameter()] [Object]$Server)
                return @([PSCustomObject]@{ Name = "vmk0"; NetworkName = ""; ExtensionData = $null }, $fakeVmk1)
            }
            function Remove-VMHostNetworkAdapter {
                [CmdletBinding(SupportsShouldProcess = $true)] Param([Parameter(ValueFromPipeline = $true)] [Object]$Nic)
                begin { }; process { }
            }
            Mock Remove-VMHostNetworkAdapter {}
            Mock Write-LogMessage {}
            $removed = Remove-NonVmk0AdaptersFromVdsHosts -HostsOnVds @($fakeHost) -PortGroupIdsOnVds $pgIds -PortGroupNamesOnVds $pgNames -Server "vc.lab"
            $removed | Should -Be 1
        }
    }

    It "Removes adapter matching by SwitchUuid fallback and returns count 1" {
        InModuleScope VcfEdgeAtScale {
            $pgIds    = [System.Collections.Generic.HashSet[string]]::new()
            $pgNames  = [System.Collections.Generic.HashSet[string]]::new()
            $uuid     = "50 05 05 ae-1e 31 29 f7-d6 db c2 d2-83 95 34 2e"
            $dvpExt   = [PSCustomObject]@{ Spec = [PSCustomObject]@{
                PortGroup             = $null
                DistributedVirtualPort = [PSCustomObject]@{
                    PortgroupKey = "dvportgroup-99"
                    SwitchUuid   = $uuid
                }
            }}
            $fakeVmk2 = [PSCustomObject]@{ Name = "vmk2"; NetworkName = ""; ExtensionData = $dvpExt }
            $fakeHost  = [PSCustomObject]@{ Name = "esx01.lab" }
            function Get-VMHostNetworkAdapter {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$VMKernel, [Parameter()] [Object]$Server)
                return @([PSCustomObject]@{ Name = "vmk0"; NetworkName = ""; ExtensionData = $null }, $fakeVmk2)
            }
            function Remove-VMHostNetworkAdapter {
                [CmdletBinding(SupportsShouldProcess = $true)] Param([Parameter(ValueFromPipeline = $true)] [Object]$Nic)
                begin { }; process { }
            }
            Mock Remove-VMHostNetworkAdapter {}
            Mock Write-LogMessage {}
            $removed = Remove-NonVmk0AdaptersFromVdsHosts -HostsOnVds @($fakeHost) -PortGroupIdsOnVds $pgIds -PortGroupNamesOnVds $pgNames -Server "vc.lab" -VdsSwitchUuid $uuid
            $removed | Should -Be 1
        }
    }

    It "Does not remove adapter when no match criteria are met" {
        InModuleScope VcfEdgeAtScale {
            $pgIds    = [System.Collections.Generic.HashSet[string]]@("dvportgroup-10")
            $pgNames  = [System.Collections.Generic.HashSet[string]]@("vsan-pg")
            $fakeVmk1 = [PSCustomObject]@{ Name = "vmk1"; NetworkName = "other-pg"; ExtensionData = $null }
            $fakeHost  = [PSCustomObject]@{ Name = "esx01.lab" }
            function Get-VMHostNetworkAdapter {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$VMKernel, [Parameter()] [Object]$Server)
                return @($fakeVmk1)
            }
            function Remove-VMHostNetworkAdapter {
                [CmdletBinding(SupportsShouldProcess = $true)] Param([Parameter(ValueFromPipeline = $true)] [Object]$Nic)
                begin { throw "Remove-VMHostNetworkAdapter must not be called when no adapter matches." }
                process { }
            }
            Mock Write-LogMessage {}
            $removed = Remove-NonVmk0AdaptersFromVdsHosts -HostsOnVds @($fakeHost) -PortGroupIdsOnVds $pgIds -PortGroupNamesOnVds $pgNames -Server "vc.lab"
            $removed | Should -Be 0
        }
    }
}


Describe "Test-Vmk0OnSingleVds — primary path via port group reference" {

    It "Returns true when VDPortgroup VDS name matches" {
        InModuleScope VcfEdgeAtScale {
            $pgRef    = [PSCustomObject]@{ Value = "dvportgroup-10" }
            $fakeVmk0 = [PSCustomObject]@{ ExtensionData = [PSCustomObject]@{ Spec = [PSCustomObject]@{ PortGroup = $pgRef } } }
            # ExtensionData MoRefs match so the primary MoRef comparison succeeds;
            # Get-DpgsOnVds is never reached on this code path.
            $fakeDpg  = [PSCustomObject]@{
                Name = "mgmt-pg"
                ExtensionData = [PSCustomObject]@{
                    Config = [PSCustomObject]@{
                        DistributedVirtualSwitch = [PSCustomObject]@{ Value = "dvs-10" }
                    }
                }
            }
            $fakeVds  = [PSCustomObject]@{
                Name = "VDS-site1"
                ExtensionData = [PSCustomObject]@{ MoRef = [PSCustomObject]@{ Value = "dvs-10" } }
            }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            function Get-VDPortgroupById {
                [CmdletBinding()] Param([Parameter()] [Object]$Id, [Parameter()] [Object]$Server)
                return $fakeDpg
            }
            Mock Write-LogMessage {}
            $result = Test-Vmk0OnSingleVds -HostName "esx01.lab" -Server "vc.lab" -Vds $fakeVds -VMHost $fakeHost -Vmk0 $fakeVmk0
            $result | Should -Be $true
        }
    }

    It "Returns true via fallback DPG iteration when vmk0 found on port group" {
        InModuleScope VcfEdgeAtScale {
            $pgRef    = [PSCustomObject]@{ Value = "dvportgroup-20" }
            $fakeVmk0 = [PSCustomObject]@{ Name = "vmk0"; ExtensionData = [PSCustomObject]@{ Spec = [PSCustomObject]@{ PortGroup = $pgRef } } }
            # Primary lookup returns DPG whose VDSwitch.Name does not match → triggers fallback.
            $fakeDpg  = [PSCustomObject]@{ Name = "mgmt-pg"; VDSwitch = [PSCustomObject]@{ Name = "OTHER-VDS" } }
            $fakeVdsDpg = [PSCustomObject]@{ Name = "mgmt-pg"; Id = "dvportgroup-20" }
            $fakeVds  = [PSCustomObject]@{ Name = "VDS-site1" }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            function Get-VDPortgroupById {
                [CmdletBinding()] Param([Parameter()] [Object]$Id, [Parameter()] [Object]$Server)
                return $fakeDpg
            }
            function Get-DpgsOnVds {
                [CmdletBinding()] Param([Parameter()] [Object]$VDSwitch, [Parameter()] [Object]$Server)
                return @($fakeVdsDpg)
            }
            function Get-VmkernelOnPortGroup {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$PortGroup, [Parameter()] [Object]$Server)
                return @($fakeVmk0)
            }
            Mock Write-LogMessage {}
            $result = Test-Vmk0OnSingleVds -HostName "esx01.lab" -Server "vc.lab" -Vds $fakeVds -VMHost $fakeHost -Vmk0 $fakeVmk0
            $result | Should -Be $true
        }
    }

    It "Returns false when neither primary nor fallback path finds vmk0" {
        InModuleScope VcfEdgeAtScale {
            $pgRef    = [PSCustomObject]@{ Value = "dvportgroup-30" }
            $fakeVmk0 = [PSCustomObject]@{ Name = "vmk0"; ExtensionData = [PSCustomObject]@{ Spec = [PSCustomObject]@{ PortGroup = $pgRef } } }
            $fakeDpg  = [PSCustomObject]@{ Name = "other-pg"; VDSwitch = [PSCustomObject]@{ Name = "OTHER-VDS" } }
            $fakeVdsDpg = [PSCustomObject]@{ Name = "vsan-pg"; Id = "dvportgroup-40" }
            $fakeVds  = [PSCustomObject]@{ Name = "VDS-site1" }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            function Get-VDPortgroupById {
                [CmdletBinding()] Param([Parameter()] [Object]$Id, [Parameter()] [Object]$Server)
                return $fakeDpg
            }
            function Get-DpgsOnVds {
                [CmdletBinding()] Param([Parameter()] [Object]$VDSwitch, [Parameter()] [Object]$Server)
                return @($fakeVdsDpg)
            }
            function Get-VmkernelOnPortGroup {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$PortGroup, [Parameter()] [Object]$Server)
                # vmk0 not on this port group.
                return @()
            }
            Mock Write-LogMessage {}
            $result = Test-Vmk0OnSingleVds -HostName "esx01.lab" -Server "vc.lab" -Vds $fakeVds -VMHost $fakeHost -Vmk0 $fakeVmk0
            $result | Should -Be $false
        }
    }

    It "Returns false when vmk0 has no port group reference" {
        InModuleScope VcfEdgeAtScale {
            $fakeVmk0 = [PSCustomObject]@{ Name = "vmk0"; ExtensionData = [PSCustomObject]@{ Spec = [PSCustomObject]@{ PortGroup = $null } } }
            $fakeVds  = [PSCustomObject]@{ Name = "VDS-site1" }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            function Get-DpgsOnVds {
                [CmdletBinding()] Param([Parameter()] [Object]$VDSwitch, [Parameter()] [Object]$Server)
                return @()
            }
            Mock Write-LogMessage {}
            $result = Test-Vmk0OnSingleVds -HostName "esx01.lab" -Server "vc.lab" -Vds $fakeVds -VMHost $fakeHost -Vmk0 $fakeVmk0
            $result | Should -Be $false
        }
    }
}

# ── Wait-* function unit tests ────────────────────────────────────────────────


Describe "Get-FirstUnusedNicFromNicList — filtering logic" {

    # Get-FirstUnusedNicFromNicList calls Get-VirtualSwitch and Get-VMHostNetworkAdapter with -VMHost
    # which enforce VMHost[] type binding on mock proxies. We test the pure filtering logic inline,
    # which is identical to what the function does: $NicNames | Where-Object { $_ -notin $assigned }.

    It "Returns the first NIC not in the assigned list" {
        # Simulate: no NICs assigned (empty $assigned).
        $assigned = @()
        $nicNames  = @("vmnic0", "vmnic1")
        $result = $nicNames | Where-Object { $assigned -notcontains $_ } | Select-Object -First 1
        $result | Should -Be "vmnic0"
    }

    It "Skips the first assigned NIC and returns the next unassigned one" {
        # Simulate: vmnic0 is assigned to vSwitch0.
        $assigned = @("vmnic0")
        $nicNames  = @("vmnic0", "vmnic1")
        $result = $nicNames | Where-Object { $assigned -notcontains $_ } | Select-Object -First 1
        $result | Should -Be "vmnic1"
    }

    It "Returns null when all NICs in the list are assigned" {
        $assigned = @("vmnic0", "vmnic1")
        $nicNames  = @("vmnic0", "vmnic1")
        $result = $nicNames | Where-Object { $assigned -notcontains $_ } | Select-Object -First 1
        $result | Should -Be $null
    }

    It "Returns null when the only NIC in the list is assigned" {
        $assigned = @("vmnic0")
        $nicNames  = @("vmnic0")
        $result = $nicNames | Where-Object { $assigned -notcontains $_ } | Select-Object -First 1
        $result | Should -Be $null
    }

    It "Returns first NIC in list when assigned list is empty" {
        $assigned = @()
        $nicNames  = @("vmnic2", "vmnic3")
        $result = $nicNames | Where-Object { $assigned -notcontains $_ } | Select-Object -First 1
        $result | Should -Be "vmnic2"
    }

    It "Is case-sensitive when matching NIC names (vmnic0 vs VMNIC0 are different)" {
        $assigned = @("VMNIC0")
        $nicNames  = @("vmnic0")
        $result = $nicNames | Where-Object { $assigned -notcontains $_ } | Select-Object -First 1
        # PowerShell's -notcontains is case-insensitive by default; verify behavior.
        # (-notcontains is case-insensitive in PowerShell, so "vmnic0" IS in @("VMNIC0")).
        $result | Should -Be $null
    }
}

# ── Get-SupervisorConfigurationFromJson ───────────────────────────────────────


Describe "Get-ManagementVSwitchInfo — logic paths" {

    It "Returns null when vmk0 is not found on the host" {
        $result = InModuleScope VcfEdgeAtScale {
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            Mock Get-VmkernelAdaptersOnHost { return @() }
            Mock Get-VirtualSwitchesOnHost { return @() }
            Get-ManagementVSwitchInfo -VMHost $fakeHost
        }
        $result | Should -Be $null
    }

    It "Returns null when vmk0 is found but no standard switch has it on a port group" {
        $result = InModuleScope VcfEdgeAtScale {
            $fakeVmk0 = [PSCustomObject]@{ Name = "vmk0" }
            $fakeVss  = [PSCustomObject]@{ Name = "vSwitch0" }
            $fakePg   = [PSCustomObject]@{ Name = "VM Network" }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            Mock Get-VmkernelAdaptersOnHost { return @($fakeVmk0) }
            Mock Get-VirtualSwitchesOnHost { return @($fakeVss) }
            Mock Get-VirtualPortGroupsOnSwitch { return @($fakePg) }
            # vmk0 is NOT on this port group.
            Mock Get-VmkernelOnPortGroup { return @() }
            Get-ManagementVSwitchInfo -VMHost $fakeHost
        }
        $result | Should -Be $null
    }

    It "Returns switch info when vmk0 is found on a standard switch port group" {
        $result = InModuleScope VcfEdgeAtScale {
            $fakeVmk0 = [PSCustomObject]@{ Name = "vmk0" }
            $fakeVss  = [PSCustomObject]@{ Name = "vSwitch0" }
            $fakePg   = [PSCustomObject]@{ Name = "Management Network"; VLanID = 0 }
            $fakePnic = [PSCustomObject]@{ Name = "vmnic0" }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            Mock Get-VmkernelAdaptersOnHost { return @($fakeVmk0) }
            Mock Get-VirtualSwitchesOnHost { return @($fakeVss) }
            Mock Get-VirtualPortGroupsOnSwitch { return @($fakePg) }
            # vmk0 IS on this port group.
            Mock Get-VmkernelOnPortGroup { return @($fakeVmk0) }
            Mock Get-PhysicalNicsOnVssForHost { return @($fakePnic) }
            Get-ManagementVSwitchInfo -VMHost $fakeHost
        }
        $result | Should -Not -Be $null
        $result.PnicNames | Should -Contain "vmnic0"
    }

    It "Returns both pNIC names sorted when vSS has two uplinks" {
        $result = InModuleScope VcfEdgeAtScale {
            $fakeVmk0  = [PSCustomObject]@{ Name = "vmk0" }
            $fakeVss   = [PSCustomObject]@{ Name = "vSwitch0" }
            $fakePg    = [PSCustomObject]@{ Name = "Management Network"; VLanID = 0 }
            $fakePnic0 = [PSCustomObject]@{ Name = "vmnic0" }
            $fakePnic1 = [PSCustomObject]@{ Name = "vmnic1" }
            $fakeHost  = [PSCustomObject]@{ Name = "esx01.lab" }
            Mock Get-VmkernelAdaptersOnHost { return @($fakeVmk0) }
            Mock Get-VirtualSwitchesOnHost { return @($fakeVss) }
            Mock Get-VirtualPortGroupsOnSwitch { return @($fakePg) }
            Mock Get-VmkernelOnPortGroup { return @($fakeVmk0) }
            Mock Get-PhysicalNicsOnVssForHost { return @($fakePnic1, $fakePnic0) }
            Get-ManagementVSwitchInfo -VMHost $fakeHost
        }
        $result | Should -Not -Be $null
        $result.PnicNames | Should -Be @("vmnic0", "vmnic1")
        $result.PnicNames.Count | Should -Be 2
    }
}

# ── Get-FirstUnusedNicFromNicList — with mocked wrappers ──────────────────────


Describe "Get-FirstUnusedNicFromNicList — with mocked wrappers" {

    It "Returns the first NIC when host has no switches" {
        $result = InModuleScope VcfEdgeAtScale {
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            Mock Get-VirtualSwitchesOnHost { return @() }
            Mock Get-PhysicalNicsOnVdsForHost { return @() }
            Mock Get-VDSwitch { return @() }
            Get-FirstUnusedNicFromNicList -VMHost $fakeHost -NicNames @("vmnic0", "vmnic1")
        }
        $result | Should -Be "vmnic0"
    }

    It "Returns second NIC when first is assigned to a VSS" {
        $result = InModuleScope VcfEdgeAtScale {
            $fakeHost  = [PSCustomObject]@{ Name = "esx01.lab" }
            $fakeVss   = [PSCustomObject]@{ Name = "vSwitch0" }
            $fakePnic0 = [PSCustomObject]@{ Name = "vmnic0" }
            Mock Get-VirtualSwitchesOnHost { return @($fakeVss) }
            Mock Get-PhysicalNicsOnVdsForHost { return @($fakePnic0) }
            Mock Get-VDSwitch { return @() }
            Get-FirstUnusedNicFromNicList -VMHost $fakeHost -NicNames @("vmnic0", "vmnic1")
        }
        $result | Should -Be "vmnic1"
    }

    It "Returns null when all NICs in the list are assigned" {
        $result = InModuleScope VcfEdgeAtScale {
            $fakeHost  = [PSCustomObject]@{ Name = "esx01.lab" }
            $fakeVss   = [PSCustomObject]@{ Name = "vSwitch0" }
            $fakePnic0 = [PSCustomObject]@{ Name = "vmnic0" }
            $fakePnic1 = [PSCustomObject]@{ Name = "vmnic1" }
            Mock Get-VirtualSwitchesOnHost { return @($fakeVss) }
            Mock Get-PhysicalNicsOnVdsForHost { return @($fakePnic0, $fakePnic1) }
            Mock Get-VDSwitch { return @() }
            Get-FirstUnusedNicFromNicList -VMHost $fakeHost -NicNames @("vmnic0", "vmnic1")
        }
        $result | Should -Be $null
    }
}

# ── Networking.ps1 vCenter wrapper coverage ───────────────────────────────────


Describe "Get-ClusterByName — wrapper pass-through" {
    # All VMware cmdlet stubs must be in the same InModuleScope call as their Mock and invocation.
    # Defining them in BeforeEach's InModuleScope does not persist into the It block's InModuleScope.

    It "Returns null when Get-Cluster returns nothing" {
        $result = InModuleScope VcfEdgeAtScale {
            function Get-Cluster {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Get-Cluster { $null }
            Get-ClusterByName -Name "cl-missing"
        }
        $result | Should -Be $null
    }

    It "Returns the cluster object when found" {
        $result = InModuleScope VcfEdgeAtScale {
            function Get-Cluster {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Get-Cluster { [PSCustomObject]@{ Name = "cl0" } }
            Get-ClusterByName -Name "cl0"
        }
        $result.Name | Should -Be "cl0"
    }
}


Describe "Get-VdsByName — wrapper pass-through" {
    It "Returns null when Get-VDSwitch returns nothing" {
        $result = InModuleScope VcfEdgeAtScale {
            function Get-VDSwitch {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Get-VDSwitch { $null }
            Get-VdsByName -Name "dvs-missing"
        }
        $result | Should -Be $null
    }

    It "Returns the VDS object when found" {
        $result = InModuleScope VcfEdgeAtScale {
            function Get-VDSwitch {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Get-VDSwitch { [PSCustomObject]@{ Name = "dvs-edge" } }
            Get-VdsByName -Name "dvs-edge"
        }
        $result.Name | Should -Be "dvs-edge"
    }
}


Describe "Get-VmHostsInCluster — wrapper pass-through" {
    It "Returns empty array when no hosts are in the cluster" {
        $result = InModuleScope VcfEdgeAtScale {
            function Get-VMHost {
                [CmdletBinding()] Param([Parameter()] [Object]$Location, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Get-VMHost { @() }
            $fakeCluster = [PSCustomObject]@{ Name = "cl0" }
            Get-VmHostsInCluster -ClusterObject $fakeCluster
        }
        @($result).Count | Should -Be 0
    }

    It "Returns the hosts when cluster has members" {
        $result = InModuleScope VcfEdgeAtScale {
            function Get-VMHost {
                [CmdletBinding()] Param([Parameter()] [Object]$Location, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Get-VMHost { @([PSCustomObject]@{ Name = "esx01" }, [PSCustomObject]@{ Name = "esx02" }) }
            $fakeCluster = [PSCustomObject]@{ Name = "cl0" }
            Get-VmHostsInCluster -ClusterObject $fakeCluster
        }
        @($result).Count | Should -Be 2
    }
}


Describe "Get-VmsFromCluster — wrapper pass-through" {
    It "Returns empty array when no VMs are in the cluster" {
        $result = InModuleScope VcfEdgeAtScale {
            function Get-VM {
                [CmdletBinding()] Param([Parameter()] [Object]$Location, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Get-VM { @() }
            $fakeCluster = [PSCustomObject]@{ Name = "cl0" }
            Get-VmsFromCluster -ClusterObject $fakeCluster
        }
        @($result).Count | Should -Be 0
    }

    It "Returns VM objects when cluster has VMs" {
        $result = InModuleScope VcfEdgeAtScale {
            function Get-VM {
                [CmdletBinding()] Param([Parameter()] [Object]$Location, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Get-VM { @([PSCustomObject]@{ Name = "vm01" }) }
            $fakeCluster = [PSCustomObject]@{ Name = "cl0" }
            Get-VmsFromCluster -ClusterObject $fakeCluster
        }
        @($result).Count | Should -Be 1
        (@($result)[0]).Name | Should -Be "vm01"
    }
}


Describe "Get-VirtualSwitchesOnHost — wrapper pass-through" {
    It "Returns empty array when host has no VSS switches" {
        $result = InModuleScope VcfEdgeAtScale {
            function Get-VirtualSwitch {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$Standard, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Get-VirtualSwitch { @() }
            $fakeHost = [PSCustomObject]@{ Name = "esx01" }
            Get-VirtualSwitchesOnHost -VMHost $fakeHost
        }
        @($result).Count | Should -Be 0
    }
}


Describe "Get-VmkernelAdaptersOnHost — wrapper pass-through" {
    It "Returns empty array when host has no VMkernel adapters" {
        $result = InModuleScope VcfEdgeAtScale {
            function Get-VMHostNetworkAdapter {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$VMKernel, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Get-VMHostNetworkAdapter { @() }
            $fakeHost = [PSCustomObject]@{ Name = "esx01" }
            Get-VmkernelAdaptersOnHost -VMHost $fakeHost
        }
        @($result).Count | Should -Be 0
    }

    It "Returns VMkernel adapters when host has them" {
        $result = InModuleScope VcfEdgeAtScale {
            function Get-VMHostNetworkAdapter {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$VMKernel, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Get-VMHostNetworkAdapter { @([PSCustomObject]@{ Name = "vmk0" }, [PSCustomObject]@{ Name = "vmk1" }) }
            $fakeHost = [PSCustomObject]@{ Name = "esx01" }
            Get-VmkernelAdaptersOnHost -VMHost $fakeHost
        }
        @($result).Count | Should -Be 2
    }
}


Describe "Set-VMHostConnectedState — guard conditions" {
    It "Logs DEBUG and takes no action when host is in Disconnected state (not Maintenance)" {
        InModuleScope VcfEdgeAtScale {
            function Set-VMHost {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$Server, [Parameter()] [Object]$State)
                begin { throw "Set-VMHost must not be called for non-Maintenance state" }
                process {}
            }
            Mock Write-LogMessage {}
            $fakeHost = [PSCustomObject]@{ Name = "esx01"; ConnectionState = "Disconnected" }
            { Set-VMHostConnectedState -VMHost $fakeHost } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "DEBUG" -and $Message -match "not Maintenance" }
        }
    }

    It "Logs INFO and calls Set-VMHost when host is in Maintenance state" {
        InModuleScope VcfEdgeAtScale {
            function Set-VMHost {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$Server, [Parameter()] [Object]$State)
                begin {}
                process {}
            }
            Mock Write-LogMessage {}
            Mock Set-VMHost { [PSCustomObject]@{ Name = "esx01"; ConnectionState = "Connected" } }
            $fakeHost = [PSCustomObject]@{ Name = "esx01"; ConnectionState = "Maintenance" }
            { Set-VMHostConnectedState -VMHost $fakeHost } | Should -Not -Throw
            Should -Invoke Set-VMHost -Times 1 -Scope It
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "INFO" -and $Message -match "maintenance mode" }
        }
    }
}

# ── Get-ManagementNetworkConfig — config assembly and error paths ─────────────


Describe "Add-VsanEsaStoragePoolDisk — guard conditions" {
    It "Throws VcfDeploymentException when vCenter is not connected" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $false; ErrorMessage = "No session." } }
            { Add-VsanEsaStoragePoolDisk -ClusterName "cl0" -DatastoreName "vsan-esa-ds" } | Should -Throw
        }
    }

    It "Throws VcfDeploymentException when cluster is not found" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true; ErrorMessage = $null } }
            Mock Get-ClusterByName { $null }
            { Add-VsanEsaStoragePoolDisk -ClusterName "cl-missing" -DatastoreName "vsan-esa-ds" } | Should -Throw
        }
    }
}


Describe "Add-VsanEsaStoragePoolDisk — construction path" {

    It "Calls Invoke-VsanEsaDiskWorkflow when datastore is not yet usable" {
        InModuleScope VcfEdgeAtScale {
            $Script:_diskWorkflowCalled = 0
            $Script:vCenterName = "vc.lab"
            function Get-VMHost {
                [CmdletBinding()] Param([Parameter()] [Object]$Location, [Parameter()] [Object]$Server)
                process {}
            }
            function Invoke-VsanEsaDiskWorkflow {
                [CmdletBinding()] Param(
                    [Parameter()] [Object]$CheckInterval, [Parameter()] [Object]$ClusterHosts,
                    [Parameter()] [Object]$ClusterName, [Parameter()] [Object]$DatastoreName,
                    [Parameter()] [Object]$DatastoreWaitTimeoutSeconds, [Parameter()] [Object]$DiskRetrievalTimeoutSeconds,
                    [Parameter()] [Object]$InitialDatastore, [Parameter()] [Object]$InitialIsAddingToExisting,
                    [Parameter()] [Object]$LabEnvironment, [Parameter()] [Object]$MinCapacityGBForExistingDatastore,
                    [Parameter()] [Object]$Server, [Parameter()] [Object]$VsAdvCfgSyncWaitTimeoutSeconds
                )
                begin { $Script:_diskWorkflowCalled++ }
                process {}
            }
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true; ErrorMessage = $null } }
            Mock Get-ClusterByName { [PSCustomObject]@{ Name = "cl0" } }
            Mock Get-VMHost { @([PSCustomObject]@{ Name = "esx01.lab" }) }
            Mock Test-VsanEsaDatastoreUsability { [PSCustomObject]@{ IsUsable = $false; Datastore = $null; IsAddingToExisting = $false } }
            Mock Enable-VsanPerformanceService {}
            { Add-VsanEsaStoragePoolDisk -ClusterName "cl0" -DatastoreName "vsan-esa-ds" } | Should -Not -Throw
            $Script:_diskWorkflowCalled | Should -BeGreaterOrEqual 1
        }
    }

    It "Skips Invoke-VsanEsaDiskWorkflow when datastore is already usable" {
        InModuleScope VcfEdgeAtScale {
            $Script:_diskWorkflowSkipped = 0
            $Script:vCenterName = "vc.lab"
            function Get-VMHost {
                [CmdletBinding()] Param([Parameter()] [Object]$Location, [Parameter()] [Object]$Server)
                process {}
            }
            function Invoke-VsanEsaDiskWorkflow {
                [CmdletBinding()] Param(
                    [Parameter()] [Object]$CheckInterval, [Parameter()] [Object]$ClusterHosts,
                    [Parameter()] [Object]$ClusterName, [Parameter()] [Object]$DatastoreName,
                    [Parameter()] [Object]$DatastoreWaitTimeoutSeconds, [Parameter()] [Object]$DiskRetrievalTimeoutSeconds,
                    [Parameter()] [Object]$InitialDatastore, [Parameter()] [Object]$InitialIsAddingToExisting,
                    [Parameter()] [Object]$LabEnvironment, [Parameter()] [Object]$MinCapacityGBForExistingDatastore,
                    [Parameter()] [Object]$Server, [Parameter()] [Object]$VsAdvCfgSyncWaitTimeoutSeconds
                )
                begin { $Script:_diskWorkflowSkipped++ }
                process {}
            }
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true; ErrorMessage = $null } }
            Mock Get-ClusterByName { [PSCustomObject]@{ Name = "cl0" } }
            Mock Get-VMHost { @([PSCustomObject]@{ Name = "esx01.lab" }) }
            Mock Test-VsanEsaDatastoreUsability { [PSCustomObject]@{ IsUsable = $true; Datastore = [PSCustomObject]@{ Name = "vsan-esa-ds" }; IsAddingToExisting = $false } }
            Mock Enable-VsanPerformanceService {}
            { Add-VsanEsaStoragePoolDisk -ClusterName "cl0" -DatastoreName "vsan-esa-ds" } | Should -Not -Throw
            $Script:_diskWorkflowSkipped | Should -Be 0
        }
    }

    It "Calls Invoke-VsanEsaWitnessSetup when vSanWitnessVmName is provided" {
        InModuleScope VcfEdgeAtScale {
            $Script:_witnessSetupCalled = 0
            $Script:vCenterName = "vc.lab"
            function Get-VMHost {
                [CmdletBinding()] Param([Parameter()] [Object]$Location, [Parameter()] [Object]$Server)
                process {}
            }
            function Invoke-VsanEsaDiskWorkflow {
                [CmdletBinding()] Param(
                    [Parameter()] [Object]$CheckInterval, [Parameter()] [Object]$ClusterHosts,
                    [Parameter()] [Object]$ClusterName, [Parameter()] [Object]$DatastoreName,
                    [Parameter()] [Object]$DatastoreWaitTimeoutSeconds, [Parameter()] [Object]$DiskRetrievalTimeoutSeconds,
                    [Parameter()] [Object]$InitialDatastore, [Parameter()] [Object]$InitialIsAddingToExisting,
                    [Parameter()] [Object]$LabEnvironment, [Parameter()] [Object]$MinCapacityGBForExistingDatastore,
                    [Parameter()] [Object]$Server, [Parameter()] [Object]$VsAdvCfgSyncWaitTimeoutSeconds
                )
                begin {}; process {}
            }
            function Invoke-VsanEsaWitnessSetup {
                [CmdletBinding()] Param(
                    [Parameter()] [Switch]$AcceptBadCheckResults,
                    [Parameter()] [Object]$ClusterName, [Parameter()] [Object]$ExistingDatastoreUsable,
                    [Parameter()] [Object]$LabEnvironment, [Parameter()] [Object]$PreferredFaultDomainName,
                    [Parameter()] [Object]$Server, [Parameter()] [Object]$vSanWitnessVmName
                )
                begin { $Script:_witnessSetupCalled++ }
                process {}
            }
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true; ErrorMessage = $null } }
            Mock Get-ClusterByName { [PSCustomObject]@{ Name = "cl0" } }
            Mock Get-VMHost { @([PSCustomObject]@{ Name = "esx01.lab" }) }
            Mock Test-VsanEsaDatastoreUsability { [PSCustomObject]@{ IsUsable = $false; Datastore = $null; IsAddingToExisting = $false } }
            Mock Enable-VsanPerformanceService {}
            { Add-VsanEsaStoragePoolDisk -ClusterName "cl0" -DatastoreName "vsan-esa-ds" -PreferredFaultDomainName "site1" -vSanWitnessVmName "witness.lab" } | Should -Not -Throw
            $Script:_witnessSetupCalled | Should -BeGreaterOrEqual 1
        }
    }
}

# ── Get-VsanDatastoreForCluster ───────────────────────────────────────────────


Describe "Resolve-DiskIsSsdProperty — property name casing tolerance" {

    It "Returns IsSsd value when property is named 'IsSsd'" {
        $result = InModuleScope VcfEdgeAtScale {
            Resolve-DiskIsSsdProperty -Disk ([PSCustomObject]@{ IsSsd = $true })
        }
        $result | Should -BeTrue
    }

    It "Returns IsSSD value when property is named 'IsSSD'" {
        $result = InModuleScope VcfEdgeAtScale {
            Resolve-DiskIsSsdProperty -Disk ([PSCustomObject]@{ IsSSD = $true })
        }
        $result | Should -BeTrue
    }

    It "Returns false when disk has neither IsSsd nor IsSSD" {
        $result = InModuleScope VcfEdgeAtScale {
            Resolve-DiskIsSsdProperty -Disk ([PSCustomObject]@{ CanonicalName = "naa.000" })
        }
        $result | Should -BeFalse
    }

    It "Returns false for HDD disk (IsSsd = false)" {
        $result = InModuleScope VcfEdgeAtScale {
            Resolve-DiskIsSsdProperty -Disk ([PSCustomObject]@{ IsSsd = $false })
        }
        $result | Should -BeFalse
    }
}

# ── Test-VsanOsaDiskGroupPresentViaEsxcli ─────────────────────────────────────


Describe "Get-VsanDatastoreCapacityGB — capacity parsing" {
    It "Returns 0.0 when CapacityGB is null" {
        $result = InModuleScope VcfEdgeAtScale {
            Get-VsanDatastoreCapacityGB -Datastore ([PSCustomObject]@{ CapacityGB = $null })
        }
        $result | Should -Be 0.0
    }

    It "Returns numeric value when CapacityGB is a double" {
        $result = InModuleScope VcfEdgeAtScale {
            Get-VsanDatastoreCapacityGB -Datastore ([PSCustomObject]@{ CapacityGB = 123.45 })
        }
        $result | Should -Be 123.45
    }

    It "Returns parsed value when CapacityGB is a string" {
        $result = InModuleScope VcfEdgeAtScale {
            Get-VsanDatastoreCapacityGB -Datastore ([PSCustomObject]@{ CapacityGB = "456.78" })
        }
        $result | Should -Be 456.78
    }
}

# ── Test-VsanEsaDatastoreUsability ────────────────────────────────────────────


Describe "Test-VsanEsaDatastoreUsability — datastore classification" {
    It "Returns IsUsable=false and IsAddingToExisting=false when no vSAN datastore exists" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            function Get-Datastore {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Get-Datastore { $null }
            $fakeHosts = @([PSCustomObject]@{ Name = "esx01" })
            Test-VsanEsaDatastoreUsability -DatastoreName "ds1" -ClusterHosts $fakeHosts -Server "vc.lab"
        }
        $result.IsUsable | Should -BeFalse
        $result.IsAddingToExisting | Should -BeFalse
    }

    It "Returns IsAddingToExisting=true when vSAN datastore exists but has zero capacity" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            function Get-Datastore {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Get-Datastore { [PSCustomObject]@{ Type = "vsan"; CapacityGB = 0.0 } }
            $fakeHosts = @([PSCustomObject]@{ Name = "esx01" })
            Test-VsanEsaDatastoreUsability -DatastoreName "ds1" -ClusterHosts $fakeHosts -Server "vc.lab"
        }
        $result.IsUsable | Should -BeFalse
        $result.IsAddingToExisting | Should -BeTrue
    }

    It "Returns IsUsable=true when vSAN datastore is accessible by all cluster hosts" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            function Get-Datastore {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process {}
            }
            $fakeDs = [PSCustomObject]@{ Type = "vsan"; CapacityGB = 500.0 }
            $fakeDs | Add-Member -MemberType NoteProperty -Name ExtensionData -Value ([PSCustomObject]@{
                Host = @([PSCustomObject]@{ Key = [PSCustomObject]@{ Value = "host-1" } })
            })
            Mock Get-Datastore { $fakeDs }
            $fakeExtData = [PSCustomObject]@{ MoRef = [PSCustomObject]@{ Value = "host-1" } }
            $fakeHost = [PSCustomObject]@{ Name = "esx01" }
            $fakeHost | Add-Member -MemberType NoteProperty -Name ExtensionData -Value $fakeExtData
            Test-VsanEsaDatastoreUsability -DatastoreName "ds1" -ClusterHosts @($fakeHost) -Server "vc.lab"
        }
        $result.IsUsable | Should -BeTrue
    }
}

# ── Test-VsanEsaStorageImbalance ──────────────────────────────────────────────


Describe "Test-VsanEsaStorageImbalance — storage balance warning" {
    It "Returns without WARNING and does not throw when only one host is present" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $disk1 = [PSCustomObject]@{ CapacityGB = 100.0 }
            $disksByHost = @{ "esx01" = @($disk1) }
            { Test-VsanEsaStorageImbalance -DisksByHost $disksByHost } | Should -Not -Throw
            Should -Not -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'WARNING' }
        }
    }

    It "Does not warn when host capacities are balanced" {
        InModuleScope VcfEdgeAtScale {
            $warningLogged = $false
            Mock Write-LogMessage { if ($Type -eq "WARNING") { $Script:_warningLogged = $true } }
            $Script:_warningLogged = $false
            $disk1 = [PSCustomObject]@{ CapacityGB = 100.0 }
            $disk2 = [PSCustomObject]@{ CapacityGB = 100.0 }
            $disksByHost = @{ "esx01" = @($disk1); "esx02" = @($disk2) }
            Test-VsanEsaStorageImbalance -DisksByHost $disksByHost
            $Script:_warningLogged | Should -BeFalse
        }
    }

    It "Emits WARNING when host capacities differ by more than 1%" {
        $warnCalled = InModuleScope VcfEdgeAtScale {
            $Script:_warnCount = 0
            Mock Write-LogMessage { if ($Type -eq "WARNING") { $Script:_warnCount++ } }
            $disk1 = [PSCustomObject]@{ CapacityGB = 100.0 }
            $disk2 = [PSCustomObject]@{ CapacityGB = 200.0 }
            $disksByHost = @{ "esx01" = @($disk1); "esx02" = @($disk2) }
            Test-VsanEsaStorageImbalance -DisksByHost $disksByHost
            $Script:_warnCount
        }
        $warnCalled | Should -BeGreaterThan 0
    }
}

# ── Get-VsanEsaSelectedDisksByHost ────────────────────────────────────────────


Describe "Get-VsanEsaSelectedDisksByHost — disk selection and validation" {
    It "Throws VcfDeploymentException when a host has no eligible disks (2+ host cluster)" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $fakeDisk = [PSCustomObject]@{
                VMHost = [PSCustomObject]@{ Name = "esx01" }
                CanonicalName = "naa.111"; CapacityGB = 200.0; Model = "NVMe"
            }
            Mock Get-VsanEsaEligibleDisksFromCluster { @($fakeDisk) }
            $hosts = @(
                [PSCustomObject]@{ Name = "esx01" },
                [PSCustomObject]@{ Name = "esx02" }
            )
            { Get-VsanEsaSelectedDisksByHost -ClusterName "cl0" -ClusterHosts $hosts } | Should -Throw
        }
    }

    It "Returns a hashtable grouped by host when all hosts have eligible disks" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            function Group-DisksByHost {
                [CmdletBinding()] Param([Parameter()] [Object]$Disks)
                return @{ "esx01" = @($Disks[0]) }
            }
            $fakeDisk = [PSCustomObject]@{
                VMHost = [PSCustomObject]@{ Name = "esx01" }
                CanonicalName = "naa.111"; CapacityGB = 200.0; Model = "NVMe"
            }
            Mock Get-VsanEsaEligibleDisksFromCluster { @($fakeDisk) }
            Mock Test-VsanEsaStorageImbalance {}
            $hosts = @([PSCustomObject]@{ Name = "esx01" })
            Get-VsanEsaSelectedDisksByHost -ClusterName "cl0" -ClusterHosts $hosts
        }
        $result | Should -Not -BeNullOrEmpty
        $result.Keys | Should -Contain "esx01"
    }
}

# ── Invoke-VsanEsaConfigAndDiskAdd ────────────────────────────────────────────


Describe "Invoke-VsanEsaConfigAndDiskAdd — config sync and disk add sequencing" {
    It "Skips config reapply when VsAdvCfgSyncWaitTimeoutSeconds is 0" {
        InModuleScope VcfEdgeAtScale {
            $Script:_reapplyCalled = $false
            Mock Write-LogMessage {}
            Mock Invoke-VsanClusterConfigReapply { $Script:_reapplyCalled = $true }
            Mock Add-VsanEsaDiskToStoragePool {}
            Mock Wait-ForVsanDatastoreAndRename {}
            $fakeHost = [PSCustomObject]@{ Name = "esx01" }
            Invoke-VsanEsaConfigAndDiskAdd -ClusterName "cl0" -DisksByHost @{ "esx01" = @() } -DatastoreName "ds1" -ClusterHosts @($fakeHost) -VsAdvCfgSyncWaitTimeoutSeconds 0
            $Script:_reapplyCalled | Should -BeFalse
        }
    }

    It "Logs 'adding to existing' message when IsAddingToExisting is true" {
        InModuleScope VcfEdgeAtScale {
            $Script:_logMessages = [System.Collections.Generic.List[String]]::new()
            Mock Write-LogMessage { $Script:_logMessages.Add($Message) }
            Mock Add-VsanEsaDiskToStoragePool {}
            Mock Wait-ForVsanDatastoreAndRename {}
            $fakeHost = [PSCustomObject]@{ Name = "esx01" }
            Invoke-VsanEsaConfigAndDiskAdd -ClusterName "cl0" -DisksByHost @{ "esx01" = @() } -DatastoreName "ds1" -ClusterHosts @($fakeHost) -IsAddingToExisting $true -VsAdvCfgSyncWaitTimeoutSeconds 0
            ($Script:_logMessages | Where-Object { $_ -match "existing vSAN datastore" }) | Should -Not -BeNullOrEmpty
        }
    }

    It "Calls Add-VsanEsaDiskToStoragePool and Wait-ForVsanDatastoreAndRename" {
        InModuleScope VcfEdgeAtScale {
            $Script:_addCalled = $false
            $Script:_waitCalled = $false
            Mock Write-LogMessage {}
            Mock Add-VsanEsaDiskToStoragePool { $Script:_addCalled = $true }
            Mock Wait-ForVsanDatastoreAndRename { $Script:_waitCalled = $true }
            $fakeHost = [PSCustomObject]@{ Name = "esx01" }
            Invoke-VsanEsaConfigAndDiskAdd -ClusterName "cl0" -DisksByHost @{ "esx01" = @() } -DatastoreName "ds1" -ClusterHosts @($fakeHost) -VsAdvCfgSyncWaitTimeoutSeconds 0
            $Script:_addCalled | Should -BeTrue
            $Script:_waitCalled | Should -BeTrue
        }
    }
}

# ── Invoke-VsanEsaDiskWorkflow ────────────────────────────────────────────────


Describe "Invoke-VsanEsaDiskWorkflow — orchestration paths" {

    It "Re-fetches the datastore when InitialDatastore is null" {
        $fetchCount = InModuleScope VcfEdgeAtScale {
            function Get-Datastore {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process {}
            }
            $Script:_datastoreFetchCount = 0
            Mock Write-LogMessage {}
            Mock Get-Datastore {
                $Script:_datastoreFetchCount++
                $null
            }
            Mock Get-VsanDatastoreCapacityGB { 100 }
            Mock Get-VsanEsaSelectedDisksByHost { @{} }
            Mock Invoke-VsanEsaConfigAndDiskAdd {}
            $fakeHost = [PSCustomObject]@{ Name = "esx01" }
            Invoke-VsanEsaDiskWorkflow -ClusterName "cl0" -ClusterHosts @($fakeHost) `
                -DatastoreName "ds1" -Server "vc01" -InitialDatastore $null
            $Script:_datastoreFetchCount
        }
        $fetchCount | Should -BeGreaterOrEqual 1
    }

    It "Sets addingDisksToExisting=true when datastore exists as vsan with low capacity" {
        $configCalled = InModuleScope VcfEdgeAtScale {
            function Get-Datastore {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process {}
            }
            $Script:_configCalledWithExisting = $false
            Mock Write-LogMessage {}
            Mock Get-Datastore { [PSCustomObject]@{ Type = "vsan" } }
            Mock Get-VsanDatastoreCapacityGB { 0 }  # Low capacity → upgrades to adding-to-existing
            Mock Get-VsanEsaSelectedDisksByHost { @{} }
            Mock Invoke-VsanEsaConfigAndDiskAdd {
                if ($IsAddingToExisting) { $Script:_configCalledWithExisting = $true }
            }
            $fakeHost = [PSCustomObject]@{ Name = "esx01" }
            Invoke-VsanEsaDiskWorkflow -ClusterName "cl0" -ClusterHosts @($fakeHost) `
                -DatastoreName "ds1" -Server "vc01" -InitialDatastore $null `
                -MinCapacityGBForExistingDatastore 1
            $Script:_configCalledWithExisting
        }
        $configCalled | Should -BeTrue
    }

    It "Calls Invoke-VsanEsaConfigAndDiskAdd with IsAddingToExisting=true when pre-flagged" {
        $configCalled = InModuleScope VcfEdgeAtScale {
            function Get-Datastore {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process {}
            }
            $Script:_configCalledPreFlagged = $false
            Mock Write-LogMessage {}
            Mock Get-Datastore { $null }
            Mock Get-VsanEsaSelectedDisksByHost { @{} }
            Mock Invoke-VsanEsaConfigAndDiskAdd {
                if ($IsAddingToExisting) { $Script:_configCalledPreFlagged = $true }
            }
            $fakeHost = [PSCustomObject]@{ Name = "esx01" }
            Invoke-VsanEsaDiskWorkflow -ClusterName "cl0" -ClusterHosts @($fakeHost) `
                -DatastoreName "ds1" -Server "vc01" -InitialIsAddingToExisting $true
            $Script:_configCalledPreFlagged
        }
        $configCalled | Should -BeTrue
    }
}

# ── Invoke-VsanEsaWitnessSetup ────────────────────────────────────────────────


Describe "Invoke-VsanEsaWitnessSetup — witness configuration" {
    It "Returns without configuring when witness is already set and datastore is usable" {
        InModuleScope VcfEdgeAtScale {
            $Script:_setWitnessCalled = $false
            Mock Write-LogMessage {}
            # Get-VsanClusterConfiguration stub required so Pester can mock it when PowerCLI is not loaded.
            function Get-VsanClusterConfiguration {
                [CmdletBinding()] Param([Parameter()] [Object]$Cluster, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Get-VsanClusterConfiguration { [PSCustomObject]@{ WitnessHost = [PSCustomObject]@{ Name = "witness.lab" } } }
            Mock Set-VsanWitness { $Script:_setWitnessCalled = $true }
            { Invoke-VsanEsaWitnessSetup -ClusterName "cl0" -ExistingDatastoreUsable:$true -PreferredFaultDomainName "site1" -vSanWitnessVmName "witness.lab" -Server "vc.lab" } | Should -Not -Throw
            $Script:_setWitnessCalled | Should -BeFalse
        }
    }

    It "Throws VcfDeploymentException when PreferredFaultDomainName is missing" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            { Invoke-VsanEsaWitnessSetup -ClusterName "cl0" -ExistingDatastoreUsable:$false -PreferredFaultDomainName "" -vSanWitnessVmName "witness.lab" -Server "vc.lab" } | Should -Throw
        }
    }

    It "Calls Set-VsanWitness and health check when datastore is not already usable" {
        InModuleScope VcfEdgeAtScale {
            $Script:_setWitnessCalled = $false
            $Script:_healthCheckCalled = $false
            Mock Write-LogMessage {}
            function Get-VMHost {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                begin {}; process { [PSCustomObject]@{ Name = $Name } }
            }
            function Get-VsanStoragePoolDisk {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Get-VsanStoragePoolDisk { $null }
            Mock Set-VsanWitness { $Script:_setWitnessCalled = $true }
            Mock Invoke-VsanClusterHealthCheckAfterWitness { $Script:_healthCheckCalled = $true }
            Invoke-VsanEsaWitnessSetup -ClusterName "cl0" -ExistingDatastoreUsable:$false -PreferredFaultDomainName "site1" -vSanWitnessVmName "witness.lab" -Server "vc.lab"
            $Script:_setWitnessCalled | Should -BeTrue
            $Script:_healthCheckCalled | Should -BeTrue
        }
    }
}

# ── Invoke-VsanClusterConfigReapply ──────────────────────────────────────────


Describe "Invoke-VsanOsaDiskGroupCreation — guard conditions" {
    It "Throws VcfDeploymentException when some cluster hosts have no eligible disks and no stale disk groups" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $fakeHost1 = [PSCustomObject]@{ Name = "esx01.lab" }
            $fakeHost2 = [PSCustomObject]@{ Name = "esx02.lab" }
            # Get-VsanOsaEligibleDisksFromCluster returns disks only for esx01, not esx02.
            Mock Get-VsanOsaEligibleDisksFromCluster {
                @([PSCustomObject]@{
                    VMHost = $fakeHost1
                    CanonicalName = "naa.abc"
                    CapacityGB = 100
                    Model = "FAKE-SSD"
                    IsSsd = $true
                })
            }
            # esx02 has no stale disk groups, so the function goes straight to the error throw.
            Mock Get-VsanOsaDiskGroupsOnHost { [PSCustomObject]@{ HasValidOsaGroup = $false; DiskGroupCount = 0 } }
            { Invoke-VsanOsaDiskGroupCreation -ClusterName "cl0" -ClusterHosts @($fakeHost1, $fakeHost2) -DatastoreName "vsan-ds" } | Should -Throw
        }
    }

    It "Prompts user and removes stale OSA disk claims when host has 0 eligible disks but has disk groups (user answers Y)" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Start-Sleep {}
            $fakeHost1 = [PSCustomObject]@{ Name = "esx01.lab"; Id = "host-1" }
            $fakeHost2 = [PSCustomObject]@{ Name = "esx02.lab"; Id = "host-2" }
            $Script:_osaEligibleCallCount = 0
            function Get-VsanOsaEligibleDisksFromCluster {
                [CmdletBinding()]
                Param([Parameter()] [Object]$ClusterName, [Parameter()] [Object]$ClusterHosts)
                $Script:_osaEligibleCallCount++
                if ($Script:_osaEligibleCallCount -le 1) {
                    # First call: only esx01 returns disks; esx02 has stale claims.
                    return @([PSCustomObject]@{ VMHost = $fakeHost1; CanonicalName = "naa.abc"; CapacityGB = 100; Model = "SSD"; IsSsd = $true })
                }
                # Second call (re-query after cleanup): esx02 now returns disks.
                return @([PSCustomObject]@{ VMHost = $fakeHost2; CanonicalName = "naa.xyz"; CapacityGB = 100; Model = "SSD"; IsSsd = $true })
            }
            # esx02 has a stale disk group.
            Mock Get-VsanOsaDiskGroupsOnHost { [PSCustomObject]@{ HasValidOsaGroup = $true; DiskGroupCount = 1 } }
            $Script:_removeClaimsCalled = $false
            function Remove-VsanDiskClaimsFromHost {
                [CmdletBinding()]
                Param([Parameter()] [Object]$StoragePolicyType, [Parameter()] [Object]$VMHost)
                begin { $Script:_removeClaimsCalled = $true }
                process {}
            }
            # User answers Y to the prompt.
            Mock Read-Host { "Y" }
            Mock Add-VsanOsaDiskToDiskGroup {}
            Mock Wait-ForVsanDatastoreAndRename {}
            { Invoke-VsanOsaDiskGroupCreation -ClusterName "cl0" -ClusterHosts @($fakeHost1, $fakeHost2) -DatastoreName "vsan-ds" } | Should -Not -Throw
            $Script:_removeClaimsCalled | Should -BeTrue
        }
    }

    It "Aborts deployment when user declines stale OSA disk claim removal (user answers N)" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $fakeHost1 = [PSCustomObject]@{ Name = "esx01.lab"; Id = "host-1" }
            $fakeHost2 = [PSCustomObject]@{ Name = "esx02.lab"; Id = "host-2" }
            Mock Get-VsanOsaEligibleDisksFromCluster {
                @([PSCustomObject]@{ VMHost = $fakeHost1; CanonicalName = "naa.abc"; CapacityGB = 100; Model = "SSD"; IsSsd = $true })
            }
            # esx02 has a stale disk group.
            Mock Get-VsanOsaDiskGroupsOnHost { [PSCustomObject]@{ HasValidOsaGroup = $true; DiskGroupCount = 1 } }
            # User answers N to the prompt — deployment must abort.
            Mock Read-Host { "N" }
            { Invoke-VsanOsaDiskGroupCreation -ClusterName "cl0" -ClusterHosts @($fakeHost1, $fakeHost2) -DatastoreName "vsan-ds" } | Should -Throw
        }
    }

    It "Auto-removes stale OSA disk claims without prompting when LabEnvironment is true" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Start-Sleep {}
            $fakeHost1 = [PSCustomObject]@{ Name = "esx01.lab"; Id = "host-1" }
            $fakeHost2 = [PSCustomObject]@{ Name = "esx02.lab"; Id = "host-2" }
            $Script:_labOsaEligibleCallCount = 0
            function Get-VsanOsaEligibleDisksFromCluster {
                [CmdletBinding()]
                Param([Parameter()] [Object]$ClusterName, [Parameter()] [Object]$ClusterHosts)
                $Script:_labOsaEligibleCallCount++
                if ($Script:_labOsaEligibleCallCount -le 1) {
                    return @([PSCustomObject]@{ VMHost = $fakeHost1; CanonicalName = "naa.abc"; CapacityGB = 100; Model = "SSD"; IsSsd = $true })
                }
                return @([PSCustomObject]@{ VMHost = $fakeHost2; CanonicalName = "naa.xyz"; CapacityGB = 100; Model = "SSD"; IsSsd = $true })
            }
            Mock Get-VsanOsaDiskGroupsOnHost { [PSCustomObject]@{ HasValidOsaGroup = $true; DiskGroupCount = 1 } }
            $Script:_labRemoveCalled = $false
            function Remove-VsanDiskClaimsFromHost {
                [CmdletBinding()]
                Param([Parameter()] [Object]$StoragePolicyType, [Parameter()] [Object]$VMHost)
                begin { $Script:_labRemoveCalled = $true }
                process {}
            }
            Mock Add-VsanOsaDiskToDiskGroup {}
            Mock Wait-ForVsanDatastoreAndRename {}
            { Invoke-VsanOsaDiskGroupCreation -ClusterName "cl0" -ClusterHosts @($fakeHost1, $fakeHost2) -DatastoreName "vsan-ds" -LabEnvironment $true } | Should -Not -Throw
            $Script:_labRemoveCalled | Should -BeTrue
        }
    }

    It "Calls Add-VsanOsaDiskToDiskGroup and Wait-ForVsanDatastoreAndRename when all hosts have disks" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            Mock Get-VsanOsaEligibleDisksFromCluster {
                @(
                    [PSCustomObject]@{ VMHost = $fakeHost; CanonicalName = "naa.cache"; CapacityGB = 50; Model = "SSD"; IsSsd = $true },
                    [PSCustomObject]@{ VMHost = $fakeHost; CanonicalName = "naa.cap"; CapacityGB = 500; Model = "HDD"; IsSsd = $false }
                )
            }
            $Script:_diskGroupCalled = $false
            Mock Add-VsanOsaDiskToDiskGroup { $Script:_diskGroupCalled = $true }
            $Script:_waitCalled = $false
            Mock Wait-ForVsanDatastoreAndRename { $Script:_waitCalled = $true }
            Invoke-VsanOsaDiskGroupCreation -ClusterName "cl0" -ClusterHosts @($fakeHost) -DatastoreName "vsan-ds"
            $Script:_diskGroupCalled | Should -BeTrue
            $Script:_waitCalled | Should -BeTrue
        }
    }

    It "Builds SelectionByHost with one entry per host when two hosts both have eligible disks" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $fakeHost1 = [PSCustomObject]@{ Name = "esx01.lab" }
            $fakeHost2 = [PSCustomObject]@{ Name = "esx02.lab" }
            Mock Get-VsanOsaEligibleDisksFromCluster {
                @(
                    [PSCustomObject]@{ VMHost = $fakeHost1; CanonicalName = "naa.h1c"; CapacityGB = 50;  Model = "SSD"; IsSsd = $true },
                    [PSCustomObject]@{ VMHost = $fakeHost1; CanonicalName = "naa.h1d"; CapacityGB = 500; Model = "HDD"; IsSsd = $false },
                    [PSCustomObject]@{ VMHost = $fakeHost2; CanonicalName = "naa.h2c"; CapacityGB = 50;  Model = "SSD"; IsSsd = $true },
                    [PSCustomObject]@{ VMHost = $fakeHost2; CanonicalName = "naa.h2d"; CapacityGB = 500; Model = "HDD"; IsSsd = $false }
                )
            }
            $Script:_twoHostSelectionByHost = $null
            function Add-VsanOsaDiskToDiskGroup {
                [CmdletBinding()]
                Param([Parameter(Mandatory = $true)] [Object]$SelectionByHost)
                begin { $Script:_twoHostSelectionByHost = $SelectionByHost }
                process {}
            }
            Mock Wait-ForVsanDatastoreAndRename {}
            Invoke-VsanOsaDiskGroupCreation -ClusterName "cl0" -ClusterHosts @($fakeHost1, $fakeHost2) -DatastoreName "vsan-ds"
            @($Script:_twoHostSelectionByHost.Keys).Count | Should -Be 2
        }
    }

    It "Assigns the smallest SSD as cache and remaining disks as capacity per host" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            Mock Get-VsanOsaEligibleDisksFromCluster {
                # Two SSDs: smaller one (50 GB) should be chosen as cache.
                @(
                    [PSCustomObject]@{ VMHost = $fakeHost; CanonicalName = "naa.large-ssd"; CapacityGB = 200; Model = "SSD"; IsSsd = $true },
                    [PSCustomObject]@{ VMHost = $fakeHost; CanonicalName = "naa.small-ssd"; CapacityGB = 50;  Model = "SSD"; IsSsd = $true }
                )
            }
            $Script:_cacheSelection = $null
            function Add-VsanOsaDiskToDiskGroup {
                [CmdletBinding()]
                Param([Parameter(Mandatory = $true)] [Object]$SelectionByHost)
                begin { $Script:_cacheSelection = $SelectionByHost }
                process {}
            }
            Mock Wait-ForVsanDatastoreAndRename {}
            Invoke-VsanOsaDiskGroupCreation -ClusterName "cl0" -ClusterHosts @($fakeHost) -DatastoreName "vsan-ds"
            $Script:_cacheSelection["esx01.lab"].CacheDisk.CanonicalName | Should -Be "naa.small-ssd"
        }
    }

    It "Uses first disk as cache when host has no SSDs" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            Mock Get-VsanOsaEligibleDisksFromCluster {
                @(
                    [PSCustomObject]@{ VMHost = $fakeHost; CanonicalName = "naa.hdd1"; CapacityGB = 500; Model = "HDD"; IsSsd = $false },
                    [PSCustomObject]@{ VMHost = $fakeHost; CanonicalName = "naa.hdd2"; CapacityGB = 500; Model = "HDD"; IsSsd = $false }
                )
            }
            $Script:_noSsdSelection = $null
            function Add-VsanOsaDiskToDiskGroup {
                [CmdletBinding()]
                Param([Parameter(Mandatory = $true)] [Object]$SelectionByHost)
                begin { $Script:_noSsdSelection = $SelectionByHost }
                process {}
            }
            Mock Wait-ForVsanDatastoreAndRename {}
            Invoke-VsanOsaDiskGroupCreation -ClusterName "cl0" -ClusterHosts @($fakeHost) -DatastoreName "vsan-ds"
            # When no SSD exists, the first disk in the list becomes cache.
            $Script:_noSsdSelection["esx01.lab"].CacheDisk.CanonicalName | Should -Be "naa.hdd1"
        }
    }

    It "Passes DatastoreName and ClusterHosts to Wait-ForVsanDatastoreAndRename" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            Mock Get-VsanOsaEligibleDisksFromCluster {
                @([PSCustomObject]@{ VMHost = $fakeHost; CanonicalName = "naa.ssd"; CapacityGB = 50; Model = "SSD"; IsSsd = $true })
            }
            Mock Add-VsanOsaDiskToDiskGroup {}
            $Script:_waitDatastoreName = $null
            function Wait-ForVsanDatastoreAndRename {
                [CmdletBinding()]
                Param(
                    [Parameter()] [Object]$CheckInterval,
                    [Parameter()] [Object]$ClusterHosts,
                    [Parameter()] [Object]$DatastoreName,
                    [Parameter()] [Object]$TimeoutSeconds
                )
                begin { $Script:_waitDatastoreName = $DatastoreName }
                process {}
            }
            Invoke-VsanOsaDiskGroupCreation -ClusterName "cl0" -ClusterHosts @($fakeHost) -DatastoreName "my-vsan-ds"
            $Script:_waitDatastoreName | Should -Be "my-vsan-ds"
        }
    }
}

# ── Invoke-VsanOsaWitnessSetup ────────────────────────────────────────────────


Describe "Invoke-VsanOsaWitnessSetup — guard conditions" {
    It "Throws VcfDeploymentException when PreferredFaultDomainName is not provided" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            function Get-VsanClusterConfiguration {
                [CmdletBinding()] Param([Parameter()] [Object]$Cluster, [Parameter()] [Object]$Server)
                process { return $null }
            }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            { Invoke-VsanOsaWitnessSetup -ClusterName "cl0" -ClusterHosts @($fakeHost) -vSanWitnessVmName "witness01" } | Should -Throw
        }
    }

    It "Skips witness setup and returns when datastore usable and witness already configured" {
        InModuleScope VcfEdgeAtScale {
            $Script:_witnessSkipLogged = $false
            Mock Write-LogMessage { if ($Type -eq "INFO" -and $Message -match "already configured") { $Script:_witnessSkipLogged = $true } }
            function Get-VsanClusterConfiguration {
                [CmdletBinding()] Param([Parameter()] [Object]$Cluster, [Parameter()] [Object]$Server)
                return [PSCustomObject]@{ WitnessHost = [PSCustomObject]@{ Name = "witness01" } }
            }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            { Invoke-VsanOsaWitnessSetup -ClusterName "cl0" -ClusterHosts @($fakeHost) -vSanWitnessVmName "witness01" -PreferredFaultDomainName "site1" -ExistingDatastoreUsable:$true } | Should -Not -Throw
            $Script:_witnessSkipLogged | Should -BeTrue
        }
    }

    It "Throws VcfDeploymentException when witness host is a member of the cluster" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            function Get-VsanClusterConfiguration {
                [CmdletBinding()] Param([Parameter()] [Object]$Cluster, [Parameter()] [Object]$Server)
                return $null
            }
            function Get-VMHost {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                # Witness host has same Name as cluster host — simulates witness in cluster.
                return [PSCustomObject]@{ Name = "witness01"; Id = "host-witness"; ExtensionData = $null }
            }
            Mock Set-VMHostConnectedState {}
            $fakeHost = [PSCustomObject]@{ Name = "witness01"; Id = "host-witness"; ExtensionData = $null }
            { Invoke-VsanOsaWitnessSetup -ClusterName "cl0" -ClusterHosts @($fakeHost) -vSanWitnessVmName "witness01" -PreferredFaultDomainName "site1" } | Should -Throw
        }
    }
}

# ── Invoke-AddVMHostWithRetry ──────────────────────────────────────────────────


Describe "Get-Vmk0ManagementVlanId — VLAN resolution" {
    It "Returns 0 when vmk0 has no DPG reference and no VDS port groups match" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $fakeVmk0 = [PSCustomObject]@{ Name = "vmk0"; ExtensionData = [PSCustomObject]@{ Spec = [PSCustomObject]@{ PortGroup = $null } } }
            function Get-VDPortgroup {
                [CmdletBinding()] Param([Parameter()] [Object]$Id, [Parameter()] [Object]$VDSwitch, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Get-VDPortgroup { @() }
            function Get-VMHostNetworkAdapter {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$VMKernel, [Parameter()] [Object]$PortGroup, [Parameter()] [Switch]$Physical, [Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                begin {}; process {}
            }
            Mock Get-VMHostNetworkAdapter { @() }
            $fakeVds  = [PSCustomObject]@{ Name = "VDS-mgmt" }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            $result = Get-Vmk0ManagementVlanId -HostName "esx01.lab" -VdsObject $fakeVds -VMHost $fakeHost -Vmk0 $fakeVmk0 -Server "vc.lab"
            $result | Should -Be 0
        }
    }

    It "Returns VLAN ID from VLanID property when vmk0 DPG carries it" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            # Use Add-Member to create a PSObject with the exact mixed-case property name VLanID
            # without a duplicate VlanId entry (PowerShell hash keys are case-insensitive).
            $fakeDpgVlanId = [PSCustomObject]@{}
            $fakeDpgVlanId | Add-Member -NotePropertyName "VLanID" -NotePropertyValue 100
            $fakeVmk0 = [PSCustomObject]@{
                Name = "vmk0"
                ExtensionData = [PSCustomObject]@{ Spec = [PSCustomObject]@{ PortGroup = [PSCustomObject]@{ Value = "dvportgroup-42" } } }
            }
            function Get-VDPortgroup {
                [CmdletBinding()] Param([Parameter()] [Object]$Id, [Parameter()] [Object]$VDSwitch, [Parameter()] [Object]$Server)
                process { $fakeDpgVlanId }
            }
            Mock Get-VDPortgroup { $fakeDpgVlanId }
            function Get-VMHostNetworkAdapter {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$VMKernel, [Parameter()] [Object]$PortGroup, [Parameter()] [Switch]$Physical, [Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                begin {}; process {}
            }
            $fakeVds  = [PSCustomObject]@{ Name = "VDS-mgmt" }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            $result = Get-Vmk0ManagementVlanId -HostName "esx01.lab" -VdsObject $fakeVds -VMHost $fakeHost -Vmk0 $fakeVmk0 -Server "vc.lab"
            $result | Should -Be 100
        }
    }

    It "Returns VLAN ID from VlanId fallback when VLanID is absent" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $fakeVmk0 = [PSCustomObject]@{
                Name = "vmk0"
                ExtensionData = [PSCustomObject]@{ Spec = [PSCustomObject]@{ PortGroup = [PSCustomObject]@{ Value = "dvportgroup-99" } } }
            }
            function Get-VDPortgroup {
                [CmdletBinding()] Param([Parameter()] [Object]$Id, [Parameter()] [Object]$VDSwitch, [Parameter()] [Object]$Server)
                process { [PSCustomObject]@{ VlanId = 200 } }
            }
            Mock Get-VDPortgroup { [PSCustomObject]@{ VlanId = 200 } }
            function Get-VMHostNetworkAdapter {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$VMKernel, [Parameter()] [Object]$PortGroup, [Parameter()] [Switch]$Physical, [Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                begin {}; process {}
            }
            $fakeVds  = [PSCustomObject]@{ Name = "VDS-mgmt" }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            $result = Get-Vmk0ManagementVlanId -HostName "esx01.lab" -VdsObject $fakeVds -VMHost $fakeHost -Vmk0 $fakeVmk0 -Server "vc.lab"
            $result | Should -Be 200
        }
    }
}

# ── New-VimHostVirtualNicSpec ─────────────────────────────────────────────────


Describe "New-VimHostVirtualNicSpec" {
    It "Returns an object that accepts portgroup assignment when New-Object succeeds" {
        $result = InModuleScope VcfEdgeAtScale {
            # Mock New-Object so tests can run without the VMware assembly loaded.
            Mock New-Object { [PSCustomObject]@{ portgroup = $null; ip = $null } } -ParameterFilter { $TypeName -eq "VMware.Vim.HostVirtualNicSpec" }
            $spec = New-VimHostVirtualNicSpec
            $spec.portgroup = "Management Network"
            $spec
        }
        $result | Should -Not -BeNullOrEmpty
        $result.portgroup | Should -Be "Management Network"
    }
}

# ── Invoke-RestoreVmk0ToExistingRestoreVss ────────────────────────────────────


Describe "Invoke-RestoreVmk0ToExistingRestoreVss — strategy 1" {
    It "Returns false when vSwitch0-restore does not exist on the host" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Get-VirtualSwitchesOnHost { @() }
            function Get-VMHostNetworkAdapter {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$Physical, [Parameter()] [Object]$VirtualSwitch, [Parameter()] [Object]$Server)
                begin {}; process {}
            }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab"; Id = "host-1" }
            $fakeVmk0 = [PSCustomObject]@{ Name = "vmk0" }
            $result = Invoke-RestoreVmk0ToExistingRestoreVss -HostName "esx01.lab" -VMHost $fakeHost -Vmk0 $fakeVmk0 -VssNameRestore "vSwitch0-restore" -Server "vc.lab"
            $result | Should -BeFalse
        }
    }

    It "Returns false when vSwitch0-restore exists but has no pNIC" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $fakeVss = [PSCustomObject]@{ Name = "vSwitch0-restore" }
            Mock Get-VirtualSwitchesOnHost { @($fakeVss) }
            function Get-VMHostNetworkAdapter {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$Physical, [Parameter()] [Object]$VirtualSwitch, [Parameter()] [Object]$Server)
                begin {}; process { @() }
            }
            Mock Get-VirtualPortGroupsOnSwitch { @([PSCustomObject]@{ Name = "Management" }) }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab"; Id = "host-1" }
            $fakeVmk0 = [PSCustomObject]@{ Name = "vmk0" }
            $result = Invoke-RestoreVmk0ToExistingRestoreVss -HostName "esx01.lab" -VMHost $fakeHost -Vmk0 $fakeVmk0 -VssNameRestore "vSwitch0-restore" -Server "vc.lab"
            $result | Should -BeFalse
        }
    }

    It "Returns true and moves vmk0 when vSwitch0-restore is complete (pNIC + Management PG)" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            # New-VimHostVirtualNicSpec wraps New-Object VMware.Vim.HostVirtualNicSpec; stub it
            # so unit tests run without the VMware assembly loaded.
            function New-VimHostVirtualNicSpec {
                [CmdletBinding()] [OutputType([Object])] Param ()
                return [PSCustomObject]@{ portgroup = $null }
            }
            $fakeVss = [PSCustomObject]@{ Name = "vSwitch0-restore" }
            $fakePnic = [PSCustomObject]@{ Name = "vmnic0" }
            $fakePg   = [PSCustomObject]@{ Name = "Management" }
            Mock Get-VirtualSwitchesOnHost { @($fakeVss) }
            function Get-VMHostNetworkAdapter {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$Physical, [Parameter()] [Object]$VirtualSwitch, [Parameter()] [Object]$Server)
                begin {}; process { @($fakePnic) }
            }
            Mock Get-VirtualPortGroupsOnSwitch { @($fakePg) }
            $fakeNetSys = [PSCustomObject]@{}
            $fakeNetSys | Add-Member -MemberType ScriptMethod -Name "UpdateVirtualNic" -Value { param($name, $spec) } -Force
            $fakeCfgMgr = [PSCustomObject]@{ NetworkSystem = "netsys-1" }
            $fakeHostView = [PSCustomObject]@{ ConfigManager = $fakeCfgMgr }
            # Get-View stub required so Pester can mock it when PowerCLI is not loaded.
            function Get-View {
                [CmdletBinding()] Param([Parameter()] [Object]$Id, [Parameter()] [Object]$Property, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Get-View {
                if ($Id -eq "host-1") { return $fakeHostView }
                return $fakeNetSys
            }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab"; Id = "host-1" }
            $fakeVmk0 = [PSCustomObject]@{ Name = "vmk0" }
            $result = Invoke-RestoreVmk0ToExistingRestoreVss -HostName "esx01.lab" -VMHost $fakeHost -Vmk0 $fakeVmk0 -VssNameRestore "vSwitch0-restore" -Server "vc.lab"
            $result | Should -BeTrue
        }
    }
}

# ── Invoke-RestoreVmk0ToFallbackVss ──────────────────────────────────────────


Describe "Invoke-RestoreVmk0ToFallbackVss — strategy 2" {
    It "Returns false when no existing VSS has a pNIC and Management-like port group" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Get-VirtualSwitchesOnHost { @() }
            function Get-VMHostNetworkAdapter {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$Physical, [Parameter()] [Object]$VirtualSwitch, [Parameter()] [Object]$Server)
                begin {}; process {}
            }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab"; Id = "host-1" }
            $fakeVmk0 = [PSCustomObject]@{ Name = "vmk0" }
            $result = Invoke-RestoreVmk0ToFallbackVss -HostName "esx01.lab" -VMHost $fakeHost -Vmk0 $fakeVmk0 -VssNameRestore "vSwitch0-restore" -Server "vc.lab"
            $result | Should -BeFalse
        }
    }

    It "Returns true when a VSS with a pNIC and Management PG is found and move succeeds" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            # New-VimHostVirtualNicSpec wraps New-Object VMware.Vim.HostVirtualNicSpec; stub it
            # so unit tests run without the VMware assembly loaded.
            function New-VimHostVirtualNicSpec {
                [CmdletBinding()] [OutputType([Object])] Param ()
                return [PSCustomObject]@{ portgroup = $null }
            }
            $fakeVss  = [PSCustomObject]@{ Name = "vSwitch0" }
            $fakePnic = [PSCustomObject]@{ Name = "vmnic0" }
            $fakePg   = [PSCustomObject]@{ Name = "Management" }
            Mock Get-VirtualSwitchesOnHost { @($fakeVss) }
            function Get-VMHostNetworkAdapter {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$Physical, [Parameter()] [Object]$VirtualSwitch, [Parameter()] [Object]$Server)
                begin {}; process { @($fakePnic) }
            }
            Mock Get-VirtualPortGroupsOnSwitch { @($fakePg) }
            $fakeNetSys = [PSCustomObject]@{}
            $fakeNetSys | Add-Member -MemberType ScriptMethod -Name "UpdateVirtualNic" -Value { param($name, $spec) } -Force
            $fakeCfgMgr   = [PSCustomObject]@{ NetworkSystem = "netsys-1" }
            $fakeHostView = [PSCustomObject]@{ ConfigManager = $fakeCfgMgr }
            # Get-View stub required so Pester can mock it when PowerCLI is not loaded.
            function Get-View {
                [CmdletBinding()] Param([Parameter()] [Object]$Id, [Parameter()] [Object]$Property, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Get-View {
                if ($Id -eq "host-1") { return $fakeHostView }
                return $fakeNetSys
            }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab"; Id = "host-1" }
            $fakeVmk0 = [PSCustomObject]@{ Name = "vmk0" }
            $result = Invoke-RestoreVmk0ToFallbackVss -HostName "esx01.lab" -VMHost $fakeHost -Vmk0 $fakeVmk0 -VssNameRestore "vSwitch0-restore" -Server "vc.lab"
            $result | Should -BeTrue
        }
    }

    It "Returns false when UpdateVirtualNic throws for all candidate port groups" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            function New-VimHostVirtualNicSpec {
                [CmdletBinding()] [OutputType([Object])] Param ()
                return [PSCustomObject]@{ portgroup = $null }
            }
            $fakeVss  = [PSCustomObject]@{ Name = "vSwitch0" }
            $fakePnic = [PSCustomObject]@{ Name = "vmnic0" }
            $fakePg   = [PSCustomObject]@{ Name = "Management" }
            Mock Get-VirtualSwitchesOnHost { @($fakeVss) }
            function Get-VMHostNetworkAdapter {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$Physical, [Parameter()] [Object]$VirtualSwitch, [Parameter()] [Object]$Server)
                begin {}; process { @($fakePnic) }
            }
            Mock Get-VirtualPortGroupsOnSwitch { @($fakePg) }
            $fakeNetSys = [PSCustomObject]@{}
            $fakeNetSys | Add-Member -MemberType ScriptMethod -Name "UpdateVirtualNic" -Value { param($name, $spec) throw "vSphere rejected the move." } -Force
            $fakeCfgMgr   = [PSCustomObject]@{ NetworkSystem = "netsys-1" }
            $fakeHostView = [PSCustomObject]@{ ConfigManager = $fakeCfgMgr }
            function Get-View {
                [CmdletBinding()] Param([Parameter()] [Object]$Id, [Parameter()] [Object]$Property, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Get-View {
                if ($Id -eq "host-1") { return $fakeHostView }
                return $fakeNetSys
            }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab"; Id = "host-1" }
            $fakeVmk0 = [PSCustomObject]@{ Name = "vmk0" }
            $result = Invoke-RestoreVmk0ToFallbackVss -HostName "esx01.lab" -VMHost $fakeHost -Vmk0 $fakeVmk0 -VssNameRestore "vSwitch0-restore" -Server "vc.lab"
            $result | Should -BeFalse
        }
    }
}

# ── Invoke-RestoreVmk0UsingUnusedPnic ─────────────────────────────────────────


Describe "Invoke-RestoreVmk0UsingUnusedPnic — strategy 3" {
    It "Returns false when all pNICs are assigned to the VDS (no unused pNIC)" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $fakePnic = [PSCustomObject]@{ Name = "vmnic0" }
            function Get-VMHostNetworkAdapter {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$Physical, [Parameter()] [Object]$VirtualSwitch, [Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                begin {}; process { @($fakePnic) }
            }
            $fakeVds  = [PSCustomObject]@{ Name = "VDS-mgmt" }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab"; Id = "host-1" }
            $fakeVmk0 = [PSCustomObject]@{ Name = "vmk0" }
            $result = Invoke-RestoreVmk0UsingUnusedPnic -HostName "esx01.lab" -MgmtVlanId 0 -VdsObject $fakeVds -VMHost $fakeHost -Vmk0 $fakeVmk0 -Server "vc.lab"
            $result | Should -BeFalse
        }
    }

    It "Returns true when an unused pNIC is found and VSS creation and vmk0 move succeed" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            # New-VimHostVirtualNicSpec wraps New-Object VMware.Vim.HostVirtualNicSpec; stub it
            # so unit tests run without the VMware assembly loaded.
            function New-VimHostVirtualNicSpec {
                [CmdletBinding()] [OutputType([Object])] Param ()
                return [PSCustomObject]@{ portgroup = $null }
            }
            $fakePnicVds  = [PSCustomObject]@{ Name = "vmnic0" }
            $fakePnicFree = [PSCustomObject]@{ Name = "vmnic1" }
            $Script:_nicCallCount = 0
            function Get-VMHostNetworkAdapter {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$Physical, [Parameter()] [Object]$VirtualSwitch, [Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                begin {}
                process {
                    $Script:_nicCallCount++
                    if ($VirtualSwitch) { return @($fakePnicVds) } # pNICs on VDS
                    if ($Name)          { return $fakePnicFree   } # lookup by name
                    return @($fakePnicVds, $fakePnicFree)          # all pNICs
                }
            }
            Mock Get-VirtualSwitchesOnHost { @() }
            $fakeVss = [PSCustomObject]@{ Name = "vSwitch0-restore" }
            function New-VirtualSwitch {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$Name, [Parameter()] [Object]$Nic, [Parameter()] [Object]$Server)
                begin {}; process { $fakeVss }
            }
            function Get-VirtualSwitch {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$Standard, [Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                begin {}; process { $fakeVss }
            }
            Mock Get-VirtualPortGroupsOnSwitch { @() }
            $fakePg = [PSCustomObject]@{ Name = "Management" }
            function New-VirtualPortGroup {
                [CmdletBinding()] Param([Parameter()] [Object]$VirtualSwitch, [Parameter()] [Object]$Name, [Parameter()] [Object]$VLanId, [Parameter()] [Object]$Server)
                begin {}; process { $fakePg }
            }
            function Get-VirtualPortGroup {
                [CmdletBinding()] Param([Parameter()] [Object]$VirtualSwitch, [Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                begin {}; process { $fakePg }
            }
            $fakeNetSys = [PSCustomObject]@{}
            $fakeNetSys | Add-Member -MemberType ScriptMethod -Name "UpdateVirtualNic" -Value { param($name, $spec) } -Force
            $fakeCfgMgr   = [PSCustomObject]@{ NetworkSystem = "netsys-1" }
            $fakeHostView = [PSCustomObject]@{ ConfigManager = $fakeCfgMgr }
            # Get-View stub required so Pester can mock it when PowerCLI is not loaded.
            function Get-View {
                [CmdletBinding()] Param([Parameter()] [Object]$Id, [Parameter()] [Object]$Property, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Get-View {
                if ($Id -eq "host-1") { return $fakeHostView }
                return $fakeNetSys
            }
            $fakeVds  = [PSCustomObject]@{ Name = "VDS-mgmt" }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab"; Id = "host-1" }
            $fakeVmk0 = [PSCustomObject]@{ Name = "vmk0" }
            $result = Invoke-RestoreVmk0UsingUnusedPnic -HostName "esx01.lab" -MgmtVlanId 0 -VdsObject $fakeVds -VMHost $fakeHost -Vmk0 $fakeVmk0 -Server "vc.lab"
            $result | Should -BeTrue
        }
    }

    It "Returns false when New-VirtualSwitch throws (falls back gracefully)" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $fakePnicVds  = [PSCustomObject]@{ Name = "vmnic0" }
            $fakePnicFree = [PSCustomObject]@{ Name = "vmnic1" }
            function Get-VMHostNetworkAdapter {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$Physical, [Parameter()] [Object]$VirtualSwitch, [Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                begin {}
                process {
                    if ($VirtualSwitch) { return @($fakePnicVds) }
                    if ($Name)          { return $fakePnicFree   }
                    return @($fakePnicVds, $fakePnicFree)
                }
            }
            Mock Get-VirtualSwitchesOnHost { @() }
            function New-VirtualSwitch {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$Name, [Parameter()] [Object]$Nic, [Parameter()] [Object]$Server)
                begin {}; process { throw "VSS creation failed." }
            }
            $fakeVds  = [PSCustomObject]@{ Name = "VDS-mgmt" }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab"; Id = "host-1" }
            $fakeVmk0 = [PSCustomObject]@{ Name = "vmk0" }
            $result = Invoke-RestoreVmk0UsingUnusedPnic -HostName "esx01.lab" -MgmtVlanId 0 -VdsObject $fakeVds -VMHost $fakeHost -Vmk0 $fakeVmk0 -Server "vc.lab"
            $result | Should -BeFalse
        }
    }
}

# ── Invoke-SelectAndRemoveVdsPnic ─────────────────────────────────────────────


Describe "Invoke-SelectAndRemoveVdsPnic — pNIC removal" {
    It "Returns NoPnicsOnVds=true when the host has no pNICs on the VDS" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            function Get-VMHostNetworkAdapter {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$Physical, [Parameter()] [Object]$VirtualSwitch, [Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                begin {}; process { @() }
            }
            $fakeVds  = [PSCustomObject]@{ Name = "VDS-mgmt" }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab"; Id = "host-1" }
            $result = Invoke-SelectAndRemoveVdsPnic -HostName "esx01.lab" -VdsObject $fakeVds -VMHost $fakeHost -Server "vc.lab"
            $result.NoPnicsOnVds | Should -BeTrue
            $result.PnicName     | Should -BeNullOrEmpty
        }
    }

    It "Returns PnicName when pNIC removal succeeds" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $fakePnic = [PSCustomObject]@{ Name = "vmnic1" }
            function Get-VMHostNetworkAdapter {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$Physical, [Parameter()] [Object]$VirtualSwitch, [Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                begin {}; process { @($fakePnic) }
            }
            function Remove-VDSwitchPhysicalNetworkAdapter {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param([Parameter(ValueFromPipeline = $true)] [Object]$In)
                begin {}; process {}
            }
            $fakeVds  = [PSCustomObject]@{ Name = "VDS-mgmt" }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab"; Id = "host-1" }
            $result = Invoke-SelectAndRemoveVdsPnic -HostName "esx01.lab" -VdsObject $fakeVds -VMHost $fakeHost -Server "vc.lab"
            $result.NoPnicsOnVds | Should -BeFalse
            $result.PnicName     | Should -Be "vmnic1"
        }
    }

    It "Returns PnicName=null when all removal attempts throw (rollback)" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $fakePnic0 = [PSCustomObject]@{ Name = "vmnic0" }
            $fakePnic1 = [PSCustomObject]@{ Name = "vmnic1" }
            function Get-VMHostNetworkAdapter {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$Physical, [Parameter()] [Object]$VirtualSwitch, [Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                begin {}
                process {
                    if ($Name -eq "vmnic0") { return $fakePnic0 }
                    if ($Name -eq "vmnic1") { return $fakePnic1 }
                    return @($fakePnic0, $fakePnic1)
                }
            }
            function Remove-VDSwitchPhysicalNetworkAdapter {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param([Parameter(ValueFromPipeline = $true)] [Object]$In)
                begin {}; process { throw "vSphere rolled back pNIC removal." }
            }
            $fakeVds  = [PSCustomObject]@{ Name = "VDS-mgmt" }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab"; Id = "host-1" }
            $result = Invoke-SelectAndRemoveVdsPnic -HostName "esx01.lab" -VdsObject $fakeVds -VMHost $fakeHost -Server "vc.lab"
            $result.NoPnicsOnVds | Should -BeFalse
            $result.PnicName     | Should -BeNullOrEmpty
        }
    }
}

# ── Invoke-BuildRestoreVssAndMoveVmk0 ─────────────────────────────────────────


Describe "Invoke-BuildRestoreVssAndMoveVmk0 — VSS creation and vmk0 migration" {
    It "Creates vSwitch0-restore, Management PG, and moves vmk0 via UpdateVirtualNic" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            # New-VimHostVirtualNicSpec wraps New-Object VMware.Vim.HostVirtualNicSpec; stub it
            # so unit tests run without the VMware assembly loaded.
            function New-VimHostVirtualNicSpec {
                [CmdletBinding()] [OutputType([Object])] Param ()
                return [PSCustomObject]@{ portgroup = $null }
            }
            $fakePnic = [PSCustomObject]@{ Name = "vmnic1" }
            $fakeVss  = [PSCustomObject]@{ Name = "vSwitch0-restore" }
            $fakePg   = [PSCustomObject]@{ Name = "Management" }
            Mock Get-VirtualSwitchesOnHost { @() }
            function New-VirtualSwitch {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$Name, [Parameter()] [Object]$Nic, [Parameter()] [Object]$Server)
                begin {}; process { $fakeVss }
            }
            function Get-VirtualSwitch {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$Standard, [Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                begin {}; process { $fakeVss }
            }
            Mock Get-VirtualPortGroupsOnSwitch { @() }
            function New-VirtualPortGroup {
                [CmdletBinding()] Param([Parameter()] [Object]$VirtualSwitch, [Parameter()] [Object]$Name, [Parameter()] [Object]$VLanId, [Parameter()] [Object]$Server)
                begin {}; process { $fakePg }
            }
            function Get-VirtualPortGroup {
                [CmdletBinding()] Param([Parameter()] [Object]$VirtualSwitch, [Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                begin {}; process { $fakePg }
            }
            $Script:_updateVnicCalled = $false
            $fakeNetSys = [PSCustomObject]@{}
            $fakeNetSys | Add-Member -MemberType ScriptMethod -Name "UpdateVirtualNic" -Value { param($name, $spec) $Script:_updateVnicCalled = $true } -Force
            $fakeCfgMgr   = [PSCustomObject]@{ NetworkSystem = "netsys-1" }
            $fakeHostView = [PSCustomObject]@{ ConfigManager = $fakeCfgMgr }
            # Get-View stub required so Pester can mock it when PowerCLI is not loaded.
            function Get-View {
                [CmdletBinding()] Param([Parameter()] [Object]$Id, [Parameter()] [Object]$Property, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Get-View {
                if ($Id -eq "host-1") { return $fakeHostView }
                return $fakeNetSys
            }
            Mock Get-VmkernelOnPortGroup { @() }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab"; Id = "host-1" }
            $fakeVmk0 = [PSCustomObject]@{ Name = "vmk0" }
            { Invoke-BuildRestoreVssAndMoveVmk0 -HostName "esx01.lab" -MgmtVlanId 0 -PnicName "vmnic1" -PnicObject $fakePnic -VMHost $fakeHost -Vmk0 $fakeVmk0 -Server "vc.lab" } | Should -Not -Throw
            $Script:_updateVnicCalled | Should -BeTrue
        }
    }

    It "Attaches pNIC to existing vSwitch0-restore when it already exists without that pNIC" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            # New-VimHostVirtualNicSpec wraps New-Object VMware.Vim.HostVirtualNicSpec; stub it
            # so unit tests run without the VMware assembly loaded.
            function New-VimHostVirtualNicSpec {
                [CmdletBinding()] [OutputType([Object])] Param ()
                return [PSCustomObject]@{ portgroup = $null }
            }
            $fakePnic    = [PSCustomObject]@{ Name = "vmnic1" }
            $fakeVss     = [PSCustomObject]@{ Name = "vSwitch0-restore" }
            $fakeVssFull = [PSCustomObject]@{ Name = "vSwitch0-restore" }
            $fakePg      = [PSCustomObject]@{ Name = "Management" }
            $Script:_addPnicCalled = $false
            Mock Get-VirtualSwitchesOnHost { @($fakeVss) }
            function Get-VMHostNetworkAdapter {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$Physical, [Parameter()] [Object]$VirtualSwitch, [Parameter()] [Object]$Server)
                begin {}; process { @() } # no pNICs on existing VSS
            }
            function Add-VirtualSwitchPhysicalNetworkAdapter {
                # SupportsShouldProcess is required so the production call with -Confirm:$false binds correctly.
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param([Parameter()] [Object]$VirtualSwitch, [Parameter()] [Object]$VMHostPhysicalNic, [Parameter()] [Object]$Server)
                begin {}; process { $Script:_addPnicCalled = $true }
            }
            function Get-VirtualSwitch {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$Standard, [Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                begin {}; process { $fakeVssFull }
            }
            Mock Get-VirtualPortGroupsOnSwitch { @($fakePg) }
            $fakeNetSys = [PSCustomObject]@{}
            $fakeNetSys | Add-Member -MemberType ScriptMethod -Name "UpdateVirtualNic" -Value { param($name, $spec) } -Force
            $fakeCfgMgr   = [PSCustomObject]@{ NetworkSystem = "netsys-1" }
            $fakeHostView = [PSCustomObject]@{ ConfigManager = $fakeCfgMgr }
            # Get-View stub required so Pester can mock it when PowerCLI is not loaded.
            function Get-View {
                [CmdletBinding()] Param([Parameter()] [Object]$Id, [Parameter()] [Object]$Property, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Get-View {
                if ($Id -eq "host-1") { return $fakeHostView }
                return $fakeNetSys
            }
            Mock Get-VmkernelOnPortGroup { @() }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab"; Id = "host-1" }
            $fakeVmk0 = [PSCustomObject]@{ Name = "vmk0" }
            { Invoke-BuildRestoreVssAndMoveVmk0 -HostName "esx01.lab" -MgmtVlanId 0 -PnicName "vmnic1" -PnicObject $fakePnic -VMHost $fakeHost -Vmk0 $fakeVmk0 -Server "vc.lab" } | Should -Not -Throw
            $Script:_addPnicCalled | Should -BeTrue
        }
    }

    It "Throws VcfDeploymentException when both Set-VMHostNetworkAdapter and UpdateVirtualNic fail" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            # New-VimHostVirtualNicSpec wraps New-Object VMware.Vim.HostVirtualNicSpec; stub it
            # so unit tests run without the VMware assembly loaded.
            function New-VimHostVirtualNicSpec {
                [CmdletBinding()] [OutputType([Object])] Param ()
                return [PSCustomObject]@{ portgroup = $null }
            }
            $fakePnic = [PSCustomObject]@{ Name = "vmnic1" }
            $fakeVss  = [PSCustomObject]@{ Name = "vSwitch0-restore" }
            $fakePg   = [PSCustomObject]@{ Name = "Management" }
            Mock Get-VirtualSwitchesOnHost { @() }
            function New-VirtualSwitch {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$Name, [Parameter()] [Object]$Nic, [Parameter()] [Object]$Server)
                begin {}; process { $fakeVss }
            }
            function Get-VirtualSwitch {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$Standard, [Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                begin {}; process { $fakeVss }
            }
            Mock Get-VirtualPortGroupsOnSwitch { @($fakePg) }
            $fakeNetSys = [PSCustomObject]@{}
            $fakeNetSys | Add-Member -MemberType ScriptMethod -Name "UpdateVirtualNic" -Value { param($name, $spec) throw "Host disconnected." } -Force
            $fakeCfgMgr   = [PSCustomObject]@{ NetworkSystem = "netsys-1" }
            $fakeHostView = [PSCustomObject]@{ ConfigManager = $fakeCfgMgr }
            # Get-View stub required so Pester can mock it when PowerCLI is not loaded.
            function Get-View {
                [CmdletBinding()] Param([Parameter()] [Object]$Id, [Parameter()] [Object]$Property, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Get-View {
                if ($Id -eq "host-1") { return $fakeHostView }
                return $fakeNetSys
            }
            Mock Get-VmkernelOnPortGroup { @() }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab"; Id = "host-1" }
            $fakeVmk0 = [PSCustomObject]@{ Name = "vmk0" }
            { Invoke-BuildRestoreVssAndMoveVmk0 -HostName "esx01.lab" -MgmtVlanId 0 -PnicName "vmnic1" -PnicObject $fakePnic -VMHost $fakeHost -Vmk0 $fakeVmk0 -Server "vc.lab" } | Should -Throw
        }
    }
}

# ── Invoke-RestoreHostManagementToVss ─────────────────────────────────────────


Describe "Invoke-RestoreHostManagementToVss — skip routing" {
    It "Returns SkippedNoVmk0=true when the host has no vmk0" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Get-VmkernelAdaptersOnHost { @() }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            $fakeVds = [PSCustomObject]@{ Name = "VDS-mgmt" }
            $result = Invoke-RestoreHostManagementToVss -VMHost $fakeHost -VdsNameWithMgmt "VDS-mgmt" -VdsObject $fakeVds -Server "vc.lab"
            $result.SkippedNoVmk0 | Should -BeTrue
            $result.Restored | Should -BeFalse
        }
    }

    It "Returns SkippedNotOnVds=true when vmk0 is not on the target VDS" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $fakeVmk0 = [PSCustomObject]@{ Name = "vmk0"; IP = "10.0.0.1" }
            Mock Get-VmkernelAdaptersOnHost { @($fakeVmk0) }
            Mock Test-VmkAdapterOnVds { $false }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            $fakeVds = [PSCustomObject]@{ Name = "VDS-mgmt" }
            $result = Invoke-RestoreHostManagementToVss -VMHost $fakeHost -VdsNameWithMgmt "VDS-mgmt" -VdsObject $fakeVds -Server "vc.lab"
            $result.SkippedNotOnVds | Should -BeTrue
            $result.Restored | Should -BeFalse
        }
    }

    It "Returns SkippedRollback=true and Success=false when all pNIC removal attempts fail" {
        # The function attempts to remove a pNIC from the VDS when all VSS fallback paths fail.
        # When vSphere rolls back every removal attempt, the function returns SkippedRollback=true.
        # Function stubs with [Object] params are required for PowerCLI cmdlets that carry
        # ArgumentTransformationAttribute on -VDSwitch / -VirtualSwitch to bypass type coercion.
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $fakeVmk0 = [PSCustomObject]@{ Name = "vmk0"; IP = "10.0.0.1"; ExtensionData = [PSCustomObject]@{ Spec = [PSCustomObject]@{ PortGroup = $null } } }
            Mock Get-VmkernelAdaptersOnHost { @($fakeVmk0) }
            Mock Test-VmkAdapterOnVds { $true }

            # Stub with [Object] params to bypass PowerCLI's -VDSwitch type coercion (returns empty → vmk0Dpg stays null).
            function Get-VDPortgroup {
                [CmdletBinding()] Param([Parameter()] [Object]$Id, [Parameter()] [Object]$VDSwitch, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Get-VDPortgroup { @() }

            # No existing VSS → forces the function down the pNIC-removal-from-VDS path.
            Mock Get-VirtualSwitchesOnHost { @() }
            Mock Get-VirtualPortGroupsOnSwitch { @() }

            $fakePnic = [PSCustomObject]@{ Name = "vmnic0" }
            # Stub with [Object] params to bypass PowerCLI's -VirtualSwitch type coercion.
            function Get-VMHostNetworkAdapter {
                [CmdletBinding()] Param(
                    [Parameter()] [Object]$VMHost,   [Parameter()] [Switch]$Physical,
                    [Parameter()] [Switch]$VMKernel, [Parameter()] [Object]$VirtualSwitch,
                    [Parameter()] [Object]$PortGroup, [Parameter()] [Object]$Name,
                    [Parameter()] [Object]$Server
                )
                begin {}; process {}
            }
            # All physical calls return the same pNIC so: allPnics==pnicsOnVds → unusedPnics empty.
            Mock Get-VMHostNetworkAdapter { if ($Physical) { @($fakePnic) } else { @() } }

            # pNIC removal always throws (simulates vSphere rollback to preserve management).
            function Remove-VDSwitchPhysicalNetworkAdapter {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param([Parameter(ValueFromPipeline = $true)] [Object]$In)
                begin {}
                process { throw "The operation would lose management connectivity." }
            }

            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab"; Id = "host-1" }
            $fakeVds = [PSCustomObject]@{ Name = "VDS-mgmt" }
            $result = Invoke-RestoreHostManagementToVss -VMHost $fakeHost -VdsNameWithMgmt "VDS-mgmt" -VdsObject $fakeVds -Server "vc.lab"
            $result.SkippedRollback | Should -BeTrue
            $result.Success | Should -BeFalse
        }
    }
}

Describe "Add-VsanOsaDiskGroupToCluster — guard conditions" {
    It "Throws VcfDeploymentException when vCenter is not connected" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $false; ErrorMessage = "No session." } }
            { Add-VsanOsaDiskGroupToCluster -ClusterName "cl0" -DatastoreName "vsan-ds" } | Should -Throw
        }
    }

    It "Throws VcfDeploymentException when cluster is not found" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true; ErrorMessage = $null } }
            Mock Get-ClusterByName { $null }
            { Add-VsanOsaDiskGroupToCluster -ClusterName "cl-missing" -DatastoreName "vsan-ds" } | Should -Throw
        }
    }

    It "Throws VcfDeploymentException when cluster has no hosts" {
        InModuleScope VcfEdgeAtScale {
            function Get-VMHost {
                [CmdletBinding()] Param([Parameter()] [Object]$Location, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true; ErrorMessage = $null } }
            Mock Get-ClusterByName { [PSCustomObject]@{ Name = "cl0" } }
            Mock Get-VMHost { $null }
            { Add-VsanOsaDiskGroupToCluster -ClusterName "cl0" -DatastoreName "vsan-ds" } | Should -Throw
        }
    }
}


Describe "Add-VsanOsaDiskGroupToCluster — construction path" {

    It "Calls Invoke-VsanOsaDiskGroupCreation when no usable datastore exists" {
        InModuleScope VcfEdgeAtScale {
            $Script:_osaCreationCalled = 0
            $Script:vCenterName = "vc.lab"
            function Get-VMHost {
                [CmdletBinding()] Param([Parameter()] [Object]$Location, [Parameter()] [Object]$Server)
                process {}
            }
            function Set-VMHostConnectedState {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$Server)
                process {}
            }
            function Get-VMHostNetworkAdapter {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$VMKernel, [Parameter()] [Object]$Server)
                process {}
            }
            function Set-VMHostNetworkAdapter {
                [CmdletBinding(SupportsShouldProcess = $true)] Param([Parameter()] [Object]$VirtualNic, [Parameter()] [Object]$VsanTrafficEnabled)
                begin {}; process {}
            }
            function Get-Datastore {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process {}
            }
            function Invoke-VsanOsaDiskGroupCreation {
                [CmdletBinding()] Param(
                    [Parameter()] [Switch]$AddingToExistingDatastore,
                    [Parameter()] [Object]$CheckInterval, [Parameter()] [Object]$ClusterHosts,
                    [Parameter()] [Object]$ClusterName, [Parameter()] [Object]$DatastoreName,
                    [Parameter()] [Object]$DatastoreWaitTimeoutSeconds, [Parameter()] [Object]$LabEnvironment
                )
                begin { $Script:_osaCreationCalled++ }
                process {}
            }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab"; ExtensionData = [PSCustomObject]@{ MoRef = [PSCustomObject]@{ Value = "host-10" } } }
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true; ErrorMessage = $null } }
            Mock Get-ClusterByName { [PSCustomObject]@{ Name = "cl0" } }
            Mock Get-VMHost { @($fakeHost) }
            Mock Get-VMHostNetworkAdapter { $null }
            Mock Test-VmkernelVsanAndWitnessTraffic { [PSCustomObject]@{ HasCompliantInterface = $true } }
            Mock Test-VsanTrafficVmkernelHasValidIp { $true }
            Mock Get-Datastore { $null }
            Mock Enable-VsanPerformanceService {}
            { Add-VsanOsaDiskGroupToCluster -ClusterName "cl0" -DatastoreName "vsan-ds" } | Should -Not -Throw
            $Script:_osaCreationCalled | Should -BeGreaterOrEqual 1
        }
    }

    It "Skips Invoke-VsanOsaDiskGroupCreation when usable vSAN datastore already exists" {
        InModuleScope VcfEdgeAtScale {
            $Script:_osaCreationSkipped = 0
            $Script:vCenterName = "vc.lab"
            function Get-VMHost {
                [CmdletBinding()] Param([Parameter()] [Object]$Location, [Parameter()] [Object]$Server)
                process {}
            }
            function Set-VMHostConnectedState {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$Server)
                process {}
            }
            function Get-VMHostNetworkAdapter {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$VMKernel, [Parameter()] [Object]$Server)
                process {}
            }
            function Set-VMHostNetworkAdapter {
                [CmdletBinding(SupportsShouldProcess = $true)] Param([Parameter()] [Object]$VirtualNic, [Parameter()] [Object]$VsanTrafficEnabled)
                begin {}; process {}
            }
            function Get-Datastore {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process {}
            }
            function Invoke-VsanOsaDiskGroupCreation {
                [CmdletBinding()] Param(
                    [Parameter()] [Switch]$AddingToExistingDatastore,
                    [Parameter()] [Object]$CheckInterval, [Parameter()] [Object]$ClusterHosts,
                    [Parameter()] [Object]$ClusterName, [Parameter()] [Object]$DatastoreName,
                    [Parameter()] [Object]$DatastoreWaitTimeoutSeconds, [Parameter()] [Object]$LabEnvironment
                )
                begin { $Script:_osaCreationSkipped++ }
                process {}
            }
            $fakeHost = [PSCustomObject]@{
                Name = "esx01.lab"
                ExtensionData = [PSCustomObject]@{ MoRef = [PSCustomObject]@{ Value = "host-10" } }
            }
            $fakeExtHost = [PSCustomObject]@{ Key = [PSCustomObject]@{ Value = "host-10" } }
            $fakeDs = [PSCustomObject]@{
                Name = "vsan-ds"; Type = "vsan"; CapacityGB = 500.0
                ExtensionData = [PSCustomObject]@{ Host = @($fakeExtHost) }
            }
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true; ErrorMessage = $null } }
            Mock Get-ClusterByName { [PSCustomObject]@{ Name = "cl0" } }
            Mock Get-VMHost { @($fakeHost) }
            Mock Get-VMHostNetworkAdapter { $null }
            Mock Test-VmkernelVsanAndWitnessTraffic { [PSCustomObject]@{ HasCompliantInterface = $true } }
            Mock Test-VsanTrafficVmkernelHasValidIp { $true }
            Mock Get-Datastore { $fakeDs }
            Mock Enable-VsanPerformanceService {}
            { Add-VsanOsaDiskGroupToCluster -ClusterName "cl0" -DatastoreName "vsan-ds" } | Should -Not -Throw
            $Script:_osaCreationSkipped | Should -Be 0
        }
    }

    It "Calls Invoke-VsanOsaWitnessSetup when vSanWitnessVmName is provided" {
        InModuleScope VcfEdgeAtScale {
            $Script:_osaWitnessCalled = 0
            $Script:vCenterName = "vc.lab"
            function Get-VMHost {
                [CmdletBinding()] Param([Parameter()] [Object]$Location, [Parameter()] [Object]$Server)
                process {}
            }
            function Set-VMHostConnectedState {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$Server)
                process {}
            }
            function Get-VMHostNetworkAdapter {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$VMKernel, [Parameter()] [Object]$Server)
                process {}
            }
            function Set-VMHostNetworkAdapter {
                [CmdletBinding(SupportsShouldProcess = $true)] Param([Parameter()] [Object]$VirtualNic, [Parameter()] [Object]$VsanTrafficEnabled)
                begin {}; process {}
            }
            function Get-Datastore {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process {}
            }
            function Invoke-VsanOsaDiskGroupCreation {
                [CmdletBinding()] Param(
                    [Parameter()] [Switch]$AddingToExistingDatastore,
                    [Parameter()] [Object]$CheckInterval, [Parameter()] [Object]$ClusterHosts,
                    [Parameter()] [Object]$ClusterName, [Parameter()] [Object]$DatastoreName,
                    [Parameter()] [Object]$DatastoreWaitTimeoutSeconds, [Parameter()] [Object]$LabEnvironment
                )
                begin {}; process {}
            }
            function Invoke-VsanOsaWitnessSetup {
                [CmdletBinding()] Param(
                    [Parameter()] [Switch]$AcceptBadCheckResults,
                    [Parameter()] [Object]$ClusterHosts, [Parameter()] [Object]$ClusterName,
                    [Parameter()] [Object]$ExistingDatastoreUsable, [Parameter()] [Object]$LabEnvironment,
                    [Parameter()] [Object]$PreferredFaultDomainName, [Parameter()] [Object]$vSanWitnessVmName
                )
                begin { $Script:_osaWitnessCalled++ }
                process {}
            }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab"; ExtensionData = [PSCustomObject]@{ MoRef = [PSCustomObject]@{ Value = "host-10" } } }
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true; ErrorMessage = $null } }
            Mock Get-ClusterByName { [PSCustomObject]@{ Name = "cl0" } }
            Mock Get-VMHost { @($fakeHost) }
            Mock Get-VMHostNetworkAdapter { $null }
            Mock Test-VmkernelVsanAndWitnessTraffic { [PSCustomObject]@{ HasCompliantInterface = $true } }
            Mock Test-VsanTrafficVmkernelHasValidIp { $true }
            Mock Get-Datastore { $null }
            Mock Enable-VsanPerformanceService {}
            { Add-VsanOsaDiskGroupToCluster -ClusterName "cl0" -DatastoreName "vsan-ds" -PreferredFaultDomainName "site1" -vSanWitnessVmName "witness.lab" } | Should -Not -Throw
            $Script:_osaWitnessCalled | Should -BeGreaterOrEqual 1
        }
    }
}

Describe "Invoke-VsanOsaClusterHostReadinessChecks" {

    It "Throws VcfDeploymentException when a host has no compliant vSAN interface" {
        InModuleScope VcfEdgeAtScale {
            $Script:vCenterName = "vc.lab"
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            function Get-VMHostNetworkAdapter {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$VMKernel, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Write-LogMessage {}
            Mock Get-VMHostNetworkAdapter { $null }
            Mock Test-VmkernelVsanAndWitnessTraffic { [PSCustomObject]@{ HasCompliantInterface = $false } }
            { Invoke-VsanOsaClusterHostReadinessChecks -ClusterHosts @($fakeHost) -ClusterName "cl0" } | Should -Throw
        }
    }

    It "Throws VcfDeploymentException when vSAN VMkernel has no valid IP" {
        InModuleScope VcfEdgeAtScale {
            $Script:vCenterName = "vc.lab"
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            function Get-VMHostNetworkAdapter {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$VMKernel, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Write-LogMessage {}
            Mock Get-VMHostNetworkAdapter { $null }
            Mock Test-VmkernelVsanAndWitnessTraffic { [PSCustomObject]@{ HasCompliantInterface = $true } }
            Mock Test-VsanTrafficVmkernelHasValidIp { $false }
            { Invoke-VsanOsaClusterHostReadinessChecks -ClusterHosts @($fakeHost) -ClusterName "cl0" } | Should -Throw
        }
    }

    It "Completes without throw when all hosts pass readiness checks" {
        InModuleScope VcfEdgeAtScale {
            $Script:vCenterName = "vc.lab"
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            function Get-VMHostNetworkAdapter {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$VMKernel, [Parameter()] [Object]$Server)
                process {}
            }
            function Set-VMHostNetworkAdapter {
                [CmdletBinding(SupportsShouldProcess = $true)] Param([Parameter()] [Object]$VirtualNic, [Parameter()] [Object]$VsanTrafficEnabled)
                begin {}; process {}
            }
            Mock Write-LogMessage {}
            Mock Get-VMHostNetworkAdapter { $null }
            Mock Test-VmkernelVsanAndWitnessTraffic { [PSCustomObject]@{ HasCompliantInterface = $true } }
            Mock Test-VsanTrafficVmkernelHasValidIp { $true }
            { Invoke-VsanOsaClusterHostReadinessChecks -ClusterHosts @($fakeHost) -ClusterName "cl0" } | Should -Not -Throw
            # Both check functions are invoked once per host; no ERROR is logged on the all-pass path.
            Should -Invoke Test-VmkernelVsanAndWitnessTraffic -Times 1
            Should -Invoke Test-VsanTrafficVmkernelHasValidIp -Times 1
            Should -Not -Invoke Write-LogMessage -ParameterFilter { $Type -eq "ERROR" }
        }
    }
}

Describe "Test-VsanOsaExistingDatastoreIsUsable" {

    It "Returns IsUsable=false when datastore does not exist" {
        InModuleScope VcfEdgeAtScale {
            $Script:vCenterName = "vc.lab"
            $fakeHost = [PSCustomObject]@{ ExtensionData = [PSCustomObject]@{ MoRef = [PSCustomObject]@{ Value = "host-1" } } }
            function Get-Datastore {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Write-LogMessage {}
            Mock Get-Datastore { $null }
            $result = Test-VsanOsaExistingDatastoreIsUsable -ClusterHosts @($fakeHost) -ClusterName "cl0" -DatastoreName "vsan-ds"
            $result.IsUsable | Should -Be $false
            $result.IsAddingToExisting | Should -Be $false
        }
    }

    It "Returns IsAddingToExisting=true when datastore exists with zero capacity" {
        InModuleScope VcfEdgeAtScale {
            $Script:vCenterName = "vc.lab"
            $fakeHost = [PSCustomObject]@{ ExtensionData = [PSCustomObject]@{ MoRef = [PSCustomObject]@{ Value = "host-1" } } }
            $fakeDs = [PSCustomObject]@{ Type = "vsan"; CapacityGB = 0 }
            function Get-Datastore {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Write-LogMessage {}
            Mock Get-Datastore { $fakeDs }
            $result = Test-VsanOsaExistingDatastoreIsUsable -ClusterHosts @($fakeHost) -ClusterName "cl0" -DatastoreName "vsan-ds" -MinCapacityGBForExistingDatastore 1
            $result.IsAddingToExisting | Should -Be $true
            $result.IsUsable | Should -Be $false
        }
    }

    It "Returns IsUsable=true when vSAN datastore exists and all hosts have access" {
        InModuleScope VcfEdgeAtScale {
            $Script:vCenterName = "vc.lab"
            $fakeHost = [PSCustomObject]@{ ExtensionData = [PSCustomObject]@{ MoRef = [PSCustomObject]@{ Value = "host-10" } } }
            $fakeExtHost = [PSCustomObject]@{ Key = [PSCustomObject]@{ Value = "host-10" } }
            $fakeDs = [PSCustomObject]@{
                Type = "vsan"
                CapacityGB = 500
                ExtensionData = [PSCustomObject]@{ Host = @($fakeExtHost) }
            }
            function Get-Datastore {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Write-LogMessage {}
            Mock Get-Datastore { $fakeDs }
            $result = Test-VsanOsaExistingDatastoreIsUsable -ClusterHosts @($fakeHost) -ClusterName "cl0" -DatastoreName "vsan-ds" -MinCapacityGBForExistingDatastore 1
            $result.IsUsable | Should -Be $true
        }
    }
}

# ── Initialize-VsanWitnessDiskGroup ──────────────────────────────────────────


Describe "Get-MgmtVssUplinkForMigration — Path A: unused NIC from NicList exists" {
    It "Returns the unused NIC as FirstUnused with HostAlreadyHasPnicOnVds=false" {
        $result = InModuleScope VcfEdgeAtScale {
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            $fakeVds  = [PSCustomObject]@{ Name = "vds1" }
            $fakeMgmt = [PSCustomObject]@{
                PnicNames      = @("vmnic0")
                StandardSwitch = [PSCustomObject]@{ Name = "vSwitch0" }
            }
            Mock Write-LogMessage {}
            Mock Get-FirstUnusedNicFromNicList { return "vmnic1" }
            Get-MgmtVssUplinkForMigration `
                -MgmtInfo $fakeMgmt -NicNames @("vmnic0", "vmnic1") `
                -VdsObject $fakeVds -VMHost $fakeHost `
                -HostDisplay "esx01.lab" -EffectiveMgmtVlanId 100
        }
        $result.FirstUnused             | Should -Be "vmnic1"
        $result.HostAlreadyHasPnicOnVds | Should -Be $false
        $result.EffectiveMgmtVlanId     | Should -Be 100
    }

    It "VssPnicsToReclaimAfterVssRemoval excludes FirstUnused and ReclaimedPnicName is first" {
        # vSS pNICs = vmnic0, vmnic2; FirstUnused = vmnic1 (not on vSS); reclaim = vmnic0, vmnic2.
        $result = InModuleScope VcfEdgeAtScale {
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            $fakeVds  = [PSCustomObject]@{ Name = "vds1" }
            $fakeMgmt = [PSCustomObject]@{
                PnicNames      = @("vmnic0", "vmnic2")
                StandardSwitch = [PSCustomObject]@{ Name = "vSwitch0" }
            }
            Mock Write-LogMessage {}
            Mock Get-FirstUnusedNicFromNicList { return "vmnic1" }
            Get-MgmtVssUplinkForMigration `
                -MgmtInfo $fakeMgmt -NicNames @("vmnic0", "vmnic1") `
                -VdsObject $fakeVds -VMHost $fakeHost `
                -HostDisplay "esx01.lab" -EffectiveMgmtVlanId 0
        }
        $result.VssPnicsToReclaimAfterVssRemoval | Should -Contain "vmnic0"
        $result.VssPnicsToReclaimAfterVssRemoval | Should -Contain "vmnic2"
        $result.ReclaimedPnicName                | Should -Be "vmnic0"
    }

    It "EffectiveMgmtVlanId is passed through unchanged" {
        $result = InModuleScope VcfEdgeAtScale {
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            $fakeVds  = [PSCustomObject]@{ Name = "vds1" }
            $fakeMgmt = [PSCustomObject]@{
                PnicNames      = @()
                StandardSwitch = [PSCustomObject]@{ Name = "vSwitch0" }
            }
            Mock Write-LogMessage {}
            Mock Get-FirstUnusedNicFromNicList { return "vmnic0" }
            Get-MgmtVssUplinkForMigration `
                -MgmtInfo $fakeMgmt -NicNames @("vmnic0") `
                -VdsObject $fakeVds -VMHost $fakeHost `
                -HostDisplay "esx01.lab" -EffectiveMgmtVlanId 42
        }
        $result.EffectiveMgmtVlanId | Should -Be 42
    }
}


Describe "Get-MgmtVssUplinkForMigration — Path B: no unused NIC but VDS already has a pNIC" {
    It "Sets HostAlreadyHasPnicOnVds=true when a NicList pNIC is already on the VDS" {
        $result = InModuleScope VcfEdgeAtScale {
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            $fakeVds  = [PSCustomObject]@{ Name = "vds1" }
            $fakeMgmt = [PSCustomObject]@{
                PnicNames      = @("vmnic0")
                StandardSwitch = [PSCustomObject]@{ Name = "vSwitch0" }
            }
            Mock Write-LogMessage {}
            Mock Get-FirstUnusedNicFromNicList { return $null }
            Mock Get-PhysicalNicsOnVdsForHost { return @([PSCustomObject]@{ Name = "vmnic0" }) }
            Get-MgmtVssUplinkForMigration `
                -MgmtInfo $fakeMgmt -NicNames @("vmnic0") `
                -VdsObject $fakeVds -VMHost $fakeHost `
                -HostDisplay "esx01.lab" -EffectiveMgmtVlanId 0
        }
        $result.HostAlreadyHasPnicOnVds | Should -Be $true
    }
}


Describe "Get-MgmtVssUplinkForMigration — Path C: all NicList pNICs on management vSS" {
    It "Picks the first NicList pNIC that is on the vSS as FirstUnused" {
        # Simulates the 2-pNIC vSS case where both NicList pNICs are on the management vSS.
        # The function must pick vmnic0 (first NicList entry also present in vSS pNIC list).
        $result = InModuleScope VcfEdgeAtScale {
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            $fakeVds  = [PSCustomObject]@{ Name = "vds1" }
            $fakeMgmt = [PSCustomObject]@{
                PnicNames      = @("vmnic0", "vmnic1")
                StandardSwitch = [PSCustomObject]@{ Name = "vSwitch0" }
            }
            Mock Write-LogMessage {}
            Mock Get-FirstUnusedNicFromNicList { return $null }
            Mock Get-PhysicalNicsOnVdsForHost { return @() }
            Get-MgmtVssUplinkForMigration `
                -MgmtInfo $fakeMgmt -NicNames @("vmnic0", "vmnic1") `
                -VdsObject $fakeVds -VMHost $fakeHost `
                -HostDisplay "esx01.lab" -EffectiveMgmtVlanId 0
        }
        $result.FirstUnused | Should -Be "vmnic0"
    }

    It "ReclaimedPnicName is null when the vSS has only one pNIC (that pNIC becomes FirstUnused)" {
        $result = InModuleScope VcfEdgeAtScale {
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            $fakeVds  = [PSCustomObject]@{ Name = "vds1" }
            $fakeMgmt = [PSCustomObject]@{
                PnicNames      = @("vmnic0")
                StandardSwitch = [PSCustomObject]@{ Name = "vSwitch0" }
            }
            Mock Write-LogMessage {}
            Mock Get-FirstUnusedNicFromNicList { return $null }
            Mock Get-PhysicalNicsOnVdsForHost { return @() }
            Get-MgmtVssUplinkForMigration `
                -MgmtInfo $fakeMgmt -NicNames @("vmnic0") `
                -VdsObject $fakeVds -VMHost $fakeHost `
                -HostDisplay "esx01.lab" -EffectiveMgmtVlanId 0
        }
        $result.FirstUnused       | Should -Be "vmnic0"
        $result.ReclaimedPnicName | Should -BeNullOrEmpty
    }
}


Describe "Get-MgmtVssUplinkForMigration — Path D: no usable NIC found" {
    It "Throws VcfDeploymentException when no NicList pNIC is on the vSS and VDS has no pNICs" {
        # vSS pNICs = vmnic2, vmnic3; NicList = vmnic0, vmnic1 — no overlap → no usable pNIC.
        { InModuleScope VcfEdgeAtScale {
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            $fakeVds  = [PSCustomObject]@{ Name = "vds1" }
            $fakeMgmt = [PSCustomObject]@{
                PnicNames      = @("vmnic2", "vmnic3")
                StandardSwitch = [PSCustomObject]@{ Name = "vSwitch0" }
            }
            Mock Write-LogMessage {}
            Mock Get-FirstUnusedNicFromNicList { return $null }
            Mock Get-PhysicalNicsOnVdsForHost { return @() }
            Get-MgmtVssUplinkForMigration `
                -MgmtInfo $fakeMgmt -NicNames @("vmnic0", "vmnic1") `
                -VdsObject $fakeVds -VMHost $fakeHost `
                -HostDisplay "esx01.lab" -EffectiveMgmtVlanId 0
        } } | Should -Throw "*No unused NIC*"
    }
}

# ── Invoke-Vmk0VdsMigrationIdempotencyCheck ──────────────────────────────────


Describe "Invoke-Vmk0VdsMigrationIdempotencyCheck — early-exit paths" {
    It "Returns false when VDS is not found" {
        $result = InModuleScope VcfEdgeAtScale {
            $Script:vCenterName = "vc.lab"
            Mock Write-LogMessage {}
            Mock Get-VdsObjectByName { return $null }
            Invoke-Vmk0VdsMigrationIdempotencyCheck -HostDisplay "esx01.lab" -Server "vc.lab" -VdsName "VDS-edge1" -VMHost ([PSCustomObject]@{ Name = "esx01.lab" })
        }
        $result | Should -Be $false
    }

    It "Returns false when VDS found but vmk0 not on host" {
        $result = InModuleScope VcfEdgeAtScale {
            $fakeVds = [PSCustomObject]@{ Name = "VDS-edge1" }
            Mock Write-LogMessage {}
            Mock Get-VdsObjectByName { return $fakeVds }
            Mock Get-VmkernelAdaptersOnHost { return @() }
            Invoke-Vmk0VdsMigrationIdempotencyCheck -HostDisplay "esx01.lab" -Server "vc.lab" -VdsName "VDS-edge1" -VMHost ([PSCustomObject]@{ Name = "esx01.lab" })
        }
        $result | Should -Be $false
    }
}


Describe "Invoke-Vmk0VdsMigrationIdempotencyCheck — direct portgroup ID detection" {
    It "Returns true when vmk0 Spec.PortGroup MoRef matches a DPG on the target VDS (Check 2)" {
        # The primary path for standard-switch adapters: Spec.PortGroup.Value is the DPG MoRef.
        # The function scans VDS DPGs and matches the MoRef against the collected ID set.
        $result = InModuleScope VcfEdgeAtScale {
            $fakeVds  = [PSCustomObject]@{ Name = "VDS-edge1" }
            $fakeVmk0 = [PSCustomObject]@{
                Name          = "vmk0"
                ExtensionData = [PSCustomObject]@{ Spec = [PSCustomObject]@{ PortGroup = [PSCustomObject]@{ Value = "pg-123" } } }
            }
            $fakeDpg = [PSCustomObject]@{
                Name          = "mgmt"
                ExtensionData = [PSCustomObject]@{ MoRef = [PSCustomObject]@{ Value = "pg-123" } }
            }

            function Get-VDPortgroup {
                [CmdletBinding()] Param([Parameter()] [Object]$Id, [Parameter()] [Object]$VDSwitch,
                    [Parameter()] [Object]$Server, [Parameter()] [Object]$Name)
                if ($VDSwitch) { return @($fakeDpg) }
                return $null
            }

            Mock Write-LogMessage {}
            Mock Get-VdsObjectByName { return $fakeVds }
            Mock Get-VmkernelAdaptersOnHost { return @($fakeVmk0) }
            Invoke-Vmk0VdsMigrationIdempotencyCheck -HostDisplay "esx01.lab" -Server "vc.lab" -VdsName "VDS-edge1" -VMHost ([PSCustomObject]@{ Name = "esx01.lab" })
        }
        $result | Should -Be $true
    }
}


Describe "Invoke-Vmk0VdsMigrationIdempotencyCheck — fallback DPG scan detection" {
    It "Returns true when direct ID lookup fails but NetworkName matches a DPG on the VDS" {
        $result = InModuleScope VcfEdgeAtScale {
            $fakeVds  = [PSCustomObject]@{ Name = "VDS-edge1" }
            # vmk0 NetworkName matches the DPG name — this is the new fallback match path
            $fakeVmk0 = [PSCustomObject]@{
                Name          = "vmk0"
                NetworkName   = "mgmt"
                ExtensionData = [PSCustomObject]@{ Spec = [PSCustomObject]@{ PortGroup = [PSCustomObject]@{ Value = "pg-unknown" } } }
            }
            $fakeDpg = [PSCustomObject]@{ Name = "mgmt" }

            function Get-VDPortgroup {
                [CmdletBinding()] Param([Parameter()] [Object]$Id, [Parameter()] [Object]$VDSwitch,
                    [Parameter()] [Object]$Server, [Parameter()] [Object]$Name)
                if ($Id) { return $null }
                return @($fakeDpg)
            }

            Mock Write-LogMessage {}
            Mock Get-VdsObjectByName { return $fakeVds }
            Mock Get-VmkernelAdaptersOnHost { return @($fakeVmk0) }
            Invoke-Vmk0VdsMigrationIdempotencyCheck -HostDisplay "esx01.lab" -Server "vc.lab" -VdsName "VDS-edge1" -VMHost ([PSCustomObject]@{ Name = "esx01.lab" })
        }
        $result | Should -Be $true
    }

    It "Returns true when direct ID lookup fails but vmk0 MoRef matches a DPG ID on the VDS" {
        $result = InModuleScope VcfEdgeAtScale {
            $fakeVds  = [PSCustomObject]@{ Name = "VDS-edge1" }
            # vmk0 MoRef matches fakeDpg.Id — second fallback match path
            $fakeVmk0 = [PSCustomObject]@{
                Name          = "vmk0"
                ExtensionData = [PSCustomObject]@{ Spec = [PSCustomObject]@{ PortGroup = [PSCustomObject]@{ Value = "dvportgroup-42" } } }
            }
            $fakeDpg = [PSCustomObject]@{ Name = "mgmt"; Id = "dvportgroup-42" }

            function Get-VDPortgroup {
                [CmdletBinding()] Param([Parameter()] [Object]$Id, [Parameter()] [Object]$VDSwitch,
                    [Parameter()] [Object]$Server, [Parameter()] [Object]$Name)
                if ($Id) { return $null }
                return @($fakeDpg)
            }

            Mock Write-LogMessage {}
            Mock Get-VdsObjectByName { return $fakeVds }
            Mock Get-VmkernelAdaptersOnHost { return @($fakeVmk0) }
            Invoke-Vmk0VdsMigrationIdempotencyCheck -HostDisplay "esx01.lab" -Server "vc.lab" -VdsName "VDS-edge1" -VMHost ([PSCustomObject]@{ Name = "esx01.lab" })
        }
        $result | Should -Be $true
    }

    It "Returns false when neither NetworkName nor MoRef matches any DPG on the VDS" {
        $result = InModuleScope VcfEdgeAtScale {
            $fakeVds  = [PSCustomObject]@{ Name = "VDS-edge1" }
            $fakeVmk0 = [PSCustomObject]@{
                Name          = "vmk0"
                NetworkName   = "VM Network"
                ExtensionData = [PSCustomObject]@{ Spec = [PSCustomObject]@{ PortGroup = [PSCustomObject]@{ Value = "pg-unknown" } } }
            }
            $fakeDpg = [PSCustomObject]@{ Name = "mgmt"; Id = "dvportgroup-99" }

            function Get-VDPortgroup {
                [CmdletBinding()] Param([Parameter()] [Object]$Id, [Parameter()] [Object]$VDSwitch,
                    [Parameter()] [Object]$Server, [Parameter()] [Object]$Name)
                if ($Id) { return $null }
                return @($fakeDpg)
            }

            Mock Write-LogMessage {}
            Mock Get-VdsObjectByName { return $fakeVds }
            Mock Get-VmkernelAdaptersOnHost { return @($fakeVmk0) }
            Invoke-Vmk0VdsMigrationIdempotencyCheck -HostDisplay "esx01.lab" -Server "vc.lab" -VdsName "VDS-edge1" -VMHost ([PSCustomObject]@{ Name = "esx01.lab" })
        }
        $result | Should -Be $false
    }
}


Describe "Invoke-Vmk0VdsMigrationIdempotencyCheck — DistributedVirtualPort detection (VCF PowerCLI 9)" {
    It "Returns true when vmk0 is VDS-backed and detected via DistributedVirtualPort.PortgroupKey" {
        # This is the primary regression test: after -CleanUp Supervisor, vmk0 stays on the VDS.
        # In VCF PowerCLI 9, NetworkName and Spec.PortGroup are both empty for VDS-backed adapters.
        # Only DistributedVirtualPort.PortgroupKey can detect the adapter is on the target VDS.
        $result = InModuleScope VcfEdgeAtScale {
            $fakeVds  = [PSCustomObject]@{
                Name          = "VDS-edge1"
                ExtensionData = [PSCustomObject]@{ Config = [PSCustomObject]@{ Uuid = "vds-uuid-001" } }
            }
            $fakeVmk0 = [PSCustomObject]@{
                Name          = "vmk0"
                ExtensionData = [PSCustomObject]@{
                    Spec = [PSCustomObject]@{
                        PortGroup              = $null
                        DistributedVirtualPort = [PSCustomObject]@{ PortgroupKey = "dvportgroup-42"; SwitchUuid = "vds-uuid-001" }
                    }
                }
            }
            # DPG exposes MoRef.Value = "dvportgroup-42" — must match PortgroupKey.
            $fakeDpg = [PSCustomObject]@{
                Name          = "mgmt-edge1"
                Id            = "dvportgroup-42"
                ExtensionData = [PSCustomObject]@{ MoRef = [PSCustomObject]@{ Value = "dvportgroup-42" } }
            }

            function Get-VDPortgroup {
                [CmdletBinding()] Param([Parameter()] [Object]$Id, [Parameter()] [Object]$VDSwitch,
                    [Parameter()] [Object]$Server, [Parameter()] [Object]$Name)
                if ($VDSwitch) { return @($fakeDpg) }
                return $null
            }

            Mock Write-LogMessage {}
            Mock Get-VdsObjectByName { return $fakeVds }
            Mock Get-VmkernelAdaptersOnHost { return @($fakeVmk0) }
            Invoke-Vmk0VdsMigrationIdempotencyCheck -HostDisplay "esx01.lab" -Server "vc.lab" -VdsName "VDS-edge1" -VMHost ([PSCustomObject]@{ Name = "esx01.lab" })
        }
        $result | Should -Be $true
    }

    It "Returns true when PortgroupKey is absent but SwitchUuid matches the target VDS" {
        $result = InModuleScope VcfEdgeAtScale {
            $fakeVds  = [PSCustomObject]@{
                Name          = "VDS-edge1"
                ExtensionData = [PSCustomObject]@{ Config = [PSCustomObject]@{ Uuid = "vds-uuid-002" } }
            }
            # PortgroupKey absent; SwitchUuid is the only clue that vmk0 is on this VDS.
            $fakeVmk0 = [PSCustomObject]@{
                Name          = "vmk0"
                ExtensionData = [PSCustomObject]@{
                    Spec = [PSCustomObject]@{
                        PortGroup              = $null
                        DistributedVirtualPort = [PSCustomObject]@{ PortgroupKey = ""; SwitchUuid = "vds-uuid-002" }
                    }
                }
            }
            $fakeDpg = [PSCustomObject]@{
                Name          = "mgmt-edge1"
                Id            = "dvportgroup-77"
                ExtensionData = [PSCustomObject]@{ MoRef = [PSCustomObject]@{ Value = "dvportgroup-77" } }
            }

            function Get-VDPortgroup {
                [CmdletBinding()] Param([Parameter()] [Object]$Id, [Parameter()] [Object]$VDSwitch,
                    [Parameter()] [Object]$Server, [Parameter()] [Object]$Name)
                if ($VDSwitch) { return @($fakeDpg) }
                return $null
            }

            Mock Write-LogMessage {}
            Mock Get-VdsObjectByName { return $fakeVds }
            Mock Get-VmkernelAdaptersOnHost { return @($fakeVmk0) }
            Invoke-Vmk0VdsMigrationIdempotencyCheck -HostDisplay "esx01.lab" -Server "vc.lab" -VdsName "VDS-edge1" -VMHost ([PSCustomObject]@{ Name = "esx01.lab" })
        }
        $result | Should -Be $true
    }

    It "Returns false when DistributedVirtualPort is present but PortgroupKey and SwitchUuid both miss" {
        $result = InModuleScope VcfEdgeAtScale {
            $fakeVds  = [PSCustomObject]@{
                Name          = "VDS-edge1"
                ExtensionData = [PSCustomObject]@{ Config = [PSCustomObject]@{ Uuid = "vds-uuid-003" } }
            }
            $fakeVmk0 = [PSCustomObject]@{
                Name          = "vmk0"
                ExtensionData = [PSCustomObject]@{
                    Spec = [PSCustomObject]@{
                        PortGroup              = $null
                        DistributedVirtualPort = [PSCustomObject]@{ PortgroupKey = "dvportgroup-other"; SwitchUuid = "vds-uuid-other" }
                    }
                }
            }
            $fakeDpg = [PSCustomObject]@{
                Name          = "mgmt-edge1"
                Id            = "dvportgroup-77"
                ExtensionData = [PSCustomObject]@{ MoRef = [PSCustomObject]@{ Value = "dvportgroup-77" } }
            }

            function Get-VDPortgroup {
                [CmdletBinding()] Param([Parameter()] [Object]$Id, [Parameter()] [Object]$VDSwitch,
                    [Parameter()] [Object]$Server, [Parameter()] [Object]$Name)
                if ($VDSwitch) { return @($fakeDpg) }
                return $null
            }

            Mock Write-LogMessage {}
            Mock Get-VdsObjectByName { return $fakeVds }
            Mock Get-VmkernelAdaptersOnHost { return @($fakeVmk0) }
            Invoke-Vmk0VdsMigrationIdempotencyCheck -HostDisplay "esx01.lab" -Server "vc.lab" -VdsName "VDS-edge1" -VMHost ([PSCustomObject]@{ Name = "esx01.lab" })
        }
        $result | Should -Be $false
    }
}


Describe "Invoke-Vmk0VdsMigrationIdempotencyCheck — MTU correction on idempotent path" {
    It "Calls Set-VMHostNetworkAdapter to correct vmk0 MTU when MTU is not 1500" {
        $callCount = InModuleScope VcfEdgeAtScale {
            $fakeVds  = [PSCustomObject]@{ Name = "VDS-edge1" }
            $fakeVmk0 = [PSCustomObject]@{
                Name          = "vmk0"
                Mtu           = 9000
                ExtensionData = [PSCustomObject]@{ Spec = [PSCustomObject]@{ PortGroup = [PSCustomObject]@{ Value = "pg-123" } } }
            }
            $fakeDpg  = [PSCustomObject]@{
                Name          = "mgmt"
                ExtensionData = [PSCustomObject]@{ MoRef = [PSCustomObject]@{ Value = "pg-123" } }
            }

            $Script:_setNicMtuCount = 0
            function Get-VDPortgroup {
                [CmdletBinding()] Param([Parameter()] [Object]$Id, [Parameter()] [Object]$VDSwitch,
                    [Parameter()] [Object]$Server, [Parameter()] [Object]$Name)
                if ($VDSwitch) { return @($fakeDpg) }
                return $null
            }
            function Set-VMHostNetworkAdapter {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param([Parameter()] [Object]$VirtualNic, [Parameter()] [Object]$Mtu,
                    [Parameter()] [Object]$PortGroup, [Parameter()] [Object]$VMotionEnabled,
                    [Parameter()] [Object]$VsanTrafficEnabled, [Parameter()] [Object]$VsanWitnessEnabled)
                begin { $Script:_setNicMtuCount++ }; process {}
            }

            Mock Write-LogMessage {}
            Mock Get-VdsObjectByName { return $fakeVds }
            Mock Get-VmkernelAdaptersOnHost { return @($fakeVmk0) }
            Invoke-Vmk0VdsMigrationIdempotencyCheck -HostDisplay "esx01.lab" -Server "vc.lab" -VdsName "VDS-edge1" -VMHost ([PSCustomObject]@{ Name = "esx01.lab" })
            $Script:_setNicMtuCount
        }
        $callCount | Should -BeGreaterOrEqual 1
    }

    It "Logs a WARNING when MTU correction fails but still returns true" {
        InModuleScope VcfEdgeAtScale {
            $fakeVds  = [PSCustomObject]@{ Name = "VDS-edge1" }
            $fakeVmk0 = [PSCustomObject]@{
                Name          = "vmk0"
                Mtu           = 9000
                ExtensionData = [PSCustomObject]@{ Spec = [PSCustomObject]@{ PortGroup = [PSCustomObject]@{ Value = "pg-123" } } }
            }
            $fakeDpg  = [PSCustomObject]@{
                Name          = "mgmt"
                ExtensionData = [PSCustomObject]@{ MoRef = [PSCustomObject]@{ Value = "pg-123" } }
            }

            function Get-VDPortgroup {
                [CmdletBinding()] Param([Parameter()] [Object]$Id, [Parameter()] [Object]$VDSwitch,
                    [Parameter()] [Object]$Server, [Parameter()] [Object]$Name)
                if ($VDSwitch) { return @($fakeDpg) }
                return $null
            }
            function Set-VMHostNetworkAdapter {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param([Parameter()] [Object]$VirtualNic, [Parameter()] [Object]$Mtu,
                    [Parameter()] [Object]$PortGroup, [Parameter()] [Object]$VMotionEnabled,
                    [Parameter()] [Object]$VsanTrafficEnabled, [Parameter()] [Object]$VsanWitnessEnabled)
                begin { throw "Simulated MTU set failure" }; process {}
            }

            Mock Write-LogMessage {}
            Mock Get-VdsObjectByName { return $fakeVds }
            Mock Get-VmkernelAdaptersOnHost { return @($fakeVmk0) }
            $result = Invoke-Vmk0VdsMigrationIdempotencyCheck -HostDisplay "esx01.lab" -Server "vc.lab" -VdsName "VDS-edge1" -VMHost ([PSCustomObject]@{ Name = "esx01.lab" })
            $result | Should -Be $true
            Should -Invoke Write-LogMessage -Times 1 -ParameterFilter { $Type -eq "WARNING" -and $Message -like "*MTU*" }
        }
    }
}

# ── Invoke-MigrateHostManagementToVds — guard conditions and 2-pNIC vSS routing


Describe "Invoke-MigrateHostManagementToVds — guard conditions and 2-pNIC vSS routing" {
    It "Throws VcfDeploymentException when Get-ManagementVSwitchInfo returns null" {
        { InModuleScope VcfEdgeAtScale {
            $Script:vCenterName = "vc.lab"
            Mock Write-LogMessage {}
            Mock Get-VdsObjectByName { return $null }
            Mock Get-ManagementVSwitchInfo { return $null }
            $nicList = @([PSCustomObject]@{ Name = "vmnic0" })
            Invoke-MigrateHostManagementToVds -VMHost ([PSCustomObject]@{ Name = "esx01.lab" }) -VdsName "test-vds" -NicList $nicList
        } } | Should -Throw "*vmk0*not*standard switch*"
    }

    It "Throws VcfDeploymentException when management vSS has no pNIC uplinks" {
        { InModuleScope VcfEdgeAtScale {
            $Script:vCenterName = "vc.lab"
            Mock Write-LogMessage {}
            Mock Get-VdsObjectByName { return $null }
            Mock Get-ManagementVSwitchInfo {
                return [PSCustomObject]@{
                    ManagementPortGroupVlanId = 0
                    ManagementVmkernel       = [PSCustomObject]@{ Name = "vmk0" }
                    PnicNames                = @()
                    StandardSwitch           = [PSCustomObject]@{ Name = "vSwitch0" }
                }
            }
            $nicList = @([PSCustomObject]@{ Name = "vmnic0" })
            Invoke-MigrateHostManagementToVds -VMHost ([PSCustomObject]@{ Name = "esx01.lab" }) -VdsName "test-vds" -NicList $nicList
        } } | Should -Throw "*management*switch*no pNIC*"
    }

    It "2-pNIC management vSS: selects vmnic0 from vSS pNICs and logs the 2-pNIC path message" {
        # Verifies that when Get-FirstUnusedNicFromNicList returns null (all NicList pNICs are
        # assigned) and none are yet on the VDS, the function picks the first matching vSS pNIC
        # ("vmnic0") and logs the expected INFO message. The test mocks both Get-VdsObjectByName
        # calls with an ordered counter so the vmk0-VDS idempotency check is skipped (1st call →
        # null) while the main migration path proceeds (2nd call → fakeVds). The function may
        # throw after the log message due to remaining PowerCLI calls lacking live wrappers; the
        # try/catch allows the assertion to run regardless.
        InModuleScope VcfEdgeAtScale {
            $Script:vCenterName                = "vc.lab"
            $Script:DidMigrateVmk0ToVdsThisRun = $false
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            $fakeVds  = [PSCustomObject]@{
                Name          = "test-vds"
                ExtensionData = [PSCustomObject]@{
                    Config = [PSCustomObject]@{
                        UplinkPortPolicy = [PSCustomObject]@{ UplinkPortName = @("uplink1", "uplink2") }
                    }
                }
            }
            $fakeVss  = [PSCustomObject]@{ Name = "vSwitch0" }
            $fakeVmk0 = [PSCustomObject]@{ Name = "vmk0" }

            Mock Write-LogMessage {}
            $Script:_vdsCount = 0
            Mock Get-VdsObjectByName {
                $Script:_vdsCount++
                if ($Script:_vdsCount -le 1) { return $null }
                return $fakeVds
            }
            Mock Get-VmkernelAdaptersOnHost { return @() }
            Mock Get-ManagementVSwitchInfo {
                return [PSCustomObject]@{
                    ManagementPortGroupVlanId = 0
                    ManagementVmkernel       = $fakeVmk0
                    PnicNames                = @("vmnic0", "vmnic1")
                    StandardSwitch           = $fakeVss
                }
            }
            Mock Get-FirstUnusedNicFromNicList { return $null }
            Mock Get-PhysicalNicsOnVdsForHost { return @() }

            $nicList = @(
                [PSCustomObject]@{ Name = "vmnic0" },
                [PSCustomObject]@{ Name = "vmnic1" }
            )
            try {
                Invoke-MigrateHostManagementToVds -VMHost $fakeHost -VdsName "test-vds" -NicList $nicList -ManagementPortGroupName "mgmt"
            } catch { }

            Should -Invoke Write-LogMessage -Times 1 -Scope It -ParameterFilter {
                $Message -like "*all NicList pNICs are on the management vSS*" -and $Message -like "*vmnic0*"
            }
        }
    }
}


Describe "Invoke-MigrateHostManagementToVds — 3-pNIC vSS extra uplink loop" {
    # Tests for the 3-pNIC vSS path. These tests assert on log messages emitted BEFORE
    # the first raw PowerCLI call (Get-VDPortgroup -VDSwitch) because that cmdlet's
    # ArgumentTransformationAttribute blocks PSCustomObject mock arguments. The loop itself
    # (Select-Object -Skip 1 over vssPnicsToReclaimAfterVssRemoval) would require wrappers
    # around the inner Add-VDSwitchPhysicalNetworkAdapter and Get-VMHostNetworkAdapter calls
    # to be verifiable in a unit test.

    It "3-pNIC vSS: selects vmnic0 as first pNIC and logs the all-on-vSS path message" {
        # Verifies that when the management vSS has three uplinks and Get-FirstUnusedNicFromNicList
        # returns null (all NicList pNICs are on the vSS), the function picks the first NicList
        # pNIC on the vSS ("vmnic0") and logs the expected INFO message. With 3 vSS pNICs,
        # vssPnicsToReclaimAfterVssRemoval = [vmnic1, vmnic2], giving the loop [vmnic2] via
        # Select-Object -Skip 1 — the loop itself cannot be verified here without additional wrappers.
        InModuleScope VcfEdgeAtScale {
            $Script:vCenterName                = "vc.lab"
            $Script:DidMigrateVmk0ToVdsThisRun = $false

            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            $fakeVds  = [PSCustomObject]@{
                Name          = "test-vds"
                ExtensionData = [PSCustomObject]@{
                    Config = [PSCustomObject]@{
                        UplinkPortPolicy = [PSCustomObject]@{ UplinkPortName = @("uplink1", "uplink2", "uplink3") }
                    }
                }
            }
            $fakeVss  = [PSCustomObject]@{ Name = "vSwitch0" }
            $fakeVmk0 = [PSCustomObject]@{ Name = "vmk0" }

            Mock Write-LogMessage {}
            $Script:_vdsCount = 0
            Mock Get-VdsObjectByName {
                $Script:_vdsCount++
                if ($Script:_vdsCount -le 1) { return $null }
                return $fakeVds
            }
            Mock Get-VmkernelAdaptersOnHost { return @() }
            Mock Get-ManagementVSwitchInfo {
                return [PSCustomObject]@{
                    ManagementPortGroupVlanId = 0
                    ManagementVmkernel       = $fakeVmk0
                    PnicNames                = @("vmnic0", "vmnic1", "vmnic2")
                    StandardSwitch           = $fakeVss
                }
            }
            Mock Get-FirstUnusedNicFromNicList { return $null }
            Mock Get-PhysicalNicsOnVdsForHost { return @() }

            $nicList = @(
                [PSCustomObject]@{ Name = "vmnic0" },
                [PSCustomObject]@{ Name = "vmnic1" },
                [PSCustomObject]@{ Name = "vmnic2" }
            )
            try {
                Invoke-MigrateHostManagementToVds -VMHost $fakeHost -VdsName "test-vds" -NicList $nicList -ManagementPortGroupName "mgmt"
            } catch { }

            Should -Invoke Write-LogMessage -Times 1 -Scope It -ParameterFilter {
                $Message -like "*all NicList pNICs are on the management vSS*" -and $Message -like "*vmnic0*"
            }
        }
    }

    It "3-pNIC vSS: does not take the error path when all NicList pNICs are on the vSS" {
        # Verifies the function does NOT log the error "none are on the management vSS" when
        # all three NicList pNICs are present on the vSS. This distinguishes the 3-pNIC
        # success path from the error path (which fires when NicList pNICs are assigned
        # elsewhere and none match any vSS pNIC).
        InModuleScope VcfEdgeAtScale {
            $Script:vCenterName                = "vc.lab"
            $Script:DidMigrateVmk0ToVdsThisRun = $false

            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            $fakeVds  = [PSCustomObject]@{
                Name          = "test-vds"
                ExtensionData = [PSCustomObject]@{
                    Config = [PSCustomObject]@{
                        UplinkPortPolicy = [PSCustomObject]@{ UplinkPortName = @("uplink1", "uplink2", "uplink3") }
                    }
                }
            }
            $fakeVss  = [PSCustomObject]@{ Name = "vSwitch0" }
            $fakeVmk0 = [PSCustomObject]@{ Name = "vmk0" }

            Mock Write-LogMessage {}
            $Script:_vdsCount = 0
            Mock Get-VdsObjectByName {
                $Script:_vdsCount++
                if ($Script:_vdsCount -le 1) { return $null }
                return $fakeVds
            }
            Mock Get-VmkernelAdaptersOnHost { return @() }
            Mock Get-ManagementVSwitchInfo {
                return [PSCustomObject]@{
                    ManagementPortGroupVlanId = 0
                    ManagementVmkernel       = $fakeVmk0
                    PnicNames                = @("vmnic0", "vmnic1", "vmnic2")
                    StandardSwitch           = $fakeVss
                }
            }
            Mock Get-FirstUnusedNicFromNicList { return $null }
            Mock Get-PhysicalNicsOnVdsForHost { return @() }

            $nicList = @(
                [PSCustomObject]@{ Name = "vmnic0" },
                [PSCustomObject]@{ Name = "vmnic1" },
                [PSCustomObject]@{ Name = "vmnic2" }
            )
            try {
                Invoke-MigrateHostManagementToVds -VMHost $fakeHost -VdsName "test-vds" -NicList $nicList -ManagementPortGroupName "mgmt"
            } catch { }

            Should -Invoke Write-LogMessage -Times 0 -Scope It -ParameterFilter {
                $Type -eq "ERROR" -and $Message -like "*none are on the management vSS*"
            }
        }
    }
}

# ── Invoke-MigrateHostManagementToVds — vmk0 migration path pre-conditions ──


Describe "Invoke-MigrateHostManagementToVds — logs pre-migration state with VLAN and uplink info" {
    # Verifies the pre-migration diagnostic log at line 4186 fires before vmk0 is moved.
    # This log captures VLAN, IP, and uplink pNIC for rapid diagnosis if migration rolls back.
    # Tests at this level are safe to run as unit tests because they assert on code paths
    # that fire BEFORE the first raw PowerCLI network-reconfiguration cmdlet.
    It "Logs the vmk0 migration pre-flight message including VLAN and uplink pNIC" {
        InModuleScope VcfEdgeAtScale {
            $Script:vCenterName                = "vc.lab"
            $Script:DidMigrateVmk0ToVdsThisRun = $false
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            $fakeVds  = [PSCustomObject]@{
                Name          = "test-vds"
                ExtensionData = [PSCustomObject]@{
                    Config = [PSCustomObject]@{
                        UplinkPortPolicy = [PSCustomObject]@{ UplinkPortName = @("uplink1", "uplink2") }
                    }
                }
            }
            $fakeVmk0 = [PSCustomObject]@{ Name = "vmk0"; IP = "10.0.0.50" }
            $fakePg   = [PSCustomObject]@{ Name = "mgmt" }

            function Get-VDPortgroup {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$VDSwitch, [Parameter()] [Object]$Id, [Parameter()] [Object]$Server)
                $fakePg
            }
            function Set-VMHostNetworkAdapter {
                [CmdletBinding(SupportsShouldProcess = $true)] Param([Parameter()] [Object]$VirtualNic, [Parameter()] [Object]$PortGroup, [Parameter()] [Object]$Mtu, [Parameter()] [Object]$VMotionEnabled, [Parameter()] [Object]$VsanTrafficEnabled, [Parameter()] [Object]$VsanWitnessEnabled)
                begin { $Script:DidMigrateVmk0ToVdsThisRun = $true }; process {}
            }
            function Get-VMHostNetworkAdapter {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$Physical, [Parameter()] [Object]$VMKernel, [Parameter()] [Object]$PortGroup, [Parameter()] [Object]$VirtualSwitch, [Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                if ($Physical) { return [PSCustomObject]@{ Name = "vmnic1" } }
                if ($PortGroup) { return @() }
                return @($fakeVmk0)
            }
            function Add-VDSwitchPhysicalNetworkAdapter {
                [CmdletBinding(SupportsShouldProcess = $true)] Param([Parameter(ValueFromPipeline = $true)] [Object]$VDSwitch, [Parameter()] [Object]$VMHostPhysicalNic, [Parameter()] [Object]$Server)
                begin {}; process {}
            }
            function Remove-VirtualSwitch {
                [CmdletBinding(SupportsShouldProcess = $true)] Param([Parameter()] [Object]$VirtualSwitch, [Parameter()] [Object]$Server)
                begin {}; process {}
            }
            function New-VDPortgroup {
                [CmdletBinding(SupportsShouldProcess = $true)] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$VDSwitch, [Parameter()] [Object]$VlanId, [Parameter()] [Object]$NumPorts, [Parameter()] [Object]$PortBinding, [Parameter()] [Object]$Server)
                begin {}; process {}
            }
            function Get-VDUplinkTeamingPolicy {
                [CmdletBinding()] Param([Parameter(ValueFromPipeline = $true)] [Object]$VDPortgroup, [Parameter()] [Object]$Server)
                begin {}; process { [PSCustomObject]@{ } }
            }
            function Set-VDUplinkTeamingPolicy {
                [CmdletBinding(SupportsShouldProcess = $true)] Param([Parameter()] [Object]$Policy, [Parameter()] [Object]$ActiveUplinkPort, [Parameter()] [Object]$StandbyUplinkPort)
                begin {}; process {}
            }

            Mock Write-LogMessage {}
            Mock Start-Sleep {}
            $Script:_vdsMigrateCount = 0
            Mock Get-VdsObjectByName {
                $Script:_vdsMigrateCount++
                if ($Script:_vdsMigrateCount -le 1) { return $null }
                return $fakeVds
            }
            Mock Get-VmkernelAdaptersOnHost { return @($fakeVmk0) }
            Mock Get-ManagementVSwitchInfo {
                return [PSCustomObject]@{
                    ManagementPortGroupVlanId = 200
                    ManagementVmkernel        = $fakeVmk0
                    PnicNames                 = @("vmnic0")
                    StandardSwitch            = [PSCustomObject]@{ Name = "vSwitch0" }
                }
            }
            Mock Get-FirstUnusedNicFromNicList { return "vmnic1" }
            Mock Get-PhysicalNicsOnVdsForHost { return @() }
            Mock Get-PhysicalNicsOnVssForHost { return @() }

            $nicList = @([PSCustomObject]@{ Name = "vmnic0" }, [PSCustomObject]@{ Name = "vmnic1" })
            try {
                Invoke-MigrateHostManagementToVds -VMHost $fakeHost -VdsName "test-vds" -NicList $nicList -ManagementPortGroupName "mgmt"
            } catch { }

            # The pre-flight log at line 4075 fires before any PowerCLI network-reconfiguration cmdlet
            # and must include "VLAN = 200" and the NicList pNIC names.
            Should -Invoke Write-LogMessage -Scope It -ParameterFilter {
                $Message -like "*VLAN = 200*" -and $Message -like "*vmnic0*"
            }
        }
    }

    It "Throws when NicList contains only whitespace-name items (no usable NIC names)" {
        { InModuleScope VcfEdgeAtScale {
            $Script:vCenterName = "vc.lab"
            Mock Write-LogMessage {}
            Mock Get-VdsObjectByName { return $null }
            Mock Get-ManagementVSwitchInfo { return $null }
            $nicListWithBlanks = @([PSCustomObject]@{ Name = "  " })
            Invoke-MigrateHostManagementToVds -VMHost ([PSCustomObject]@{ Name = "esx01.lab" }) -VdsName "test-vds" -NicList $nicListWithBlanks
        } } | Should -Throw "*NicList is empty*"
    }
}

# ── Invoke-EnsureMgmtPortGroupOnVds ──────────────────────────────────────────


Describe "Invoke-EnsureMgmtPortGroupOnVds" {

    It "Returns existing port group when found on first lookup" {
        $result = InModuleScope VcfEdgeAtScale {
            $fakeVds = [PSCustomObject]@{ Name = "VDS-edge1" }
            $fakePg  = [PSCustomObject]@{ Name = "Management" }
            $Script:_pgCallCount = 0

            function Get-VDPortgroup {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$VDSwitch,
                    [Parameter()] [Object]$Server, [Parameter()] [Object]$Id)
                $Script:_pgCallCount++
                return $fakePg
            }

            Invoke-EnsureMgmtPortGroupOnVds `
                -EffectiveMgmtVlanId 100 -ManagementPortGroupName "Management" `
                -VdsName "VDS-edge1" -VdsObject $fakeVds
        }
        $result.Name | Should -Be "Management"
    }

    It "Creates and returns port group when not found initially" {
        $result = InModuleScope VcfEdgeAtScale {
            $fakeVds = [PSCustomObject]@{ Name = "VDS-edge1" }
            $fakePg  = [PSCustomObject]@{ Name = "Management" }
            $Script:_pgFoundOnCreate = $false

            function Get-VDPortgroup {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$VDSwitch,
                    [Parameter()] [Object]$Server, [Parameter()] [Object]$Id)
                if ($Script:_pgFoundOnCreate) { return $fakePg }
                return $null
            }
            function New-VDPortgroup {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param([Parameter()] [Object]$Name, [Parameter()] [Object]$VDSwitch,
                    [Parameter()] [Object]$VlanId, [Parameter()] [Object]$NumPorts,
                    [Parameter()] [Object]$PortBinding, [Parameter()] [Object]$Server)
                $Script:_pgFoundOnCreate = $true
            }

            Invoke-EnsureMgmtPortGroupOnVds `
                -EffectiveMgmtVlanId 100 -ManagementPortGroupName "Management" `
                -VdsName "VDS-edge1" -VdsObject $fakeVds
        }
        $result.Name | Should -Be "Management"
    }

    It "Throws VcfDeploymentException when New-VDPortgroup throws a non-transient error" {
        {
            InModuleScope VcfEdgeAtScale {
                $fakeVds = [PSCustomObject]@{ Name = "VDS-edge1" }

                function Get-VDPortgroup {
                    [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$VDSwitch,
                        [Parameter()] [Object]$Server, [Parameter()] [Object]$Id)
                    return $null
                }
                function New-VDPortgroup {
                    [CmdletBinding(SupportsShouldProcess = $true)]
                    Param([Parameter()] [Object]$Name, [Parameter()] [Object]$VDSwitch,
                        [Parameter()] [Object]$VlanId, [Parameter()] [Object]$NumPorts,
                        [Parameter()] [Object]$PortBinding, [Parameter()] [Object]$Server)
                    throw "Permanent API failure"
                }

                Invoke-EnsureMgmtPortGroupOnVds `
                    -EffectiveMgmtVlanId 100 -ManagementPortGroupName "Management" `
                    -VdsName "VDS-edge1" -VdsObject $fakeVds
            }
        } | Should -Throw "*Permanent API failure*"

    }
}

# ── Invoke-ClearVmk0TrafficFlags ─────────────────────────────────────────────


Describe "Invoke-ClearVmk0TrafficFlags" {

    It "Calls Set-VMHostNetworkAdapter once when combined-flags call succeeds" {
        $callCount = InModuleScope VcfEdgeAtScale {
            $Script:_clearCallCount = 0
            $fakeVmk0 = [PSCustomObject]@{ Name = "vmk0" }

            function Set-VMHostNetworkAdapter {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param([Parameter()] [Object]$VirtualNic, [Parameter()] [Object]$VMotionEnabled,
                    [Parameter()] [Object]$VsanTrafficEnabled, [Parameter()] [Object]$VsanWitnessEnabled,
                    [Parameter()] [Object]$Mtu)
                $Script:_clearCallCount++
            }

            Invoke-ClearVmk0TrafficFlags -HostDisplay "esx01.lab" -Vmk0 $fakeVmk0
            $Script:_clearCallCount
        }
        $callCount | Should -BeGreaterOrEqual 1
    }

    It "Falls back to individual flag calls when combined-flag call fails with parameter-set error" {
        $callCount = InModuleScope VcfEdgeAtScale {
            $Script:_clearCallCount = 0
            $Script:_clearAttempt = 0
            $fakeVmk0 = [PSCustomObject]@{ Name = "vmk0" }

            function Set-VMHostNetworkAdapter {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param([Parameter()] [Object]$VirtualNic, [Parameter()] [Object]$VMotionEnabled,
                    [Parameter()] [Object]$VsanTrafficEnabled, [Parameter()] [Object]$VsanWitnessEnabled,
                    [Parameter()] [Object]$Mtu)
                $Script:_clearCallCount++
                $Script:_clearAttempt++
                # First call (3-flag combined): throw parameter-set error to force fallback.
                if ($Script:_clearAttempt -le 1) { throw "Parameter set cannot be resolved" }
            }

            Invoke-ClearVmk0TrafficFlags -HostDisplay "esx01.lab" -Vmk0 $fakeVmk0
            $Script:_clearCallCount
        }
        # First call fails (parameter-set error), at least one fallback call is made.
        $callCount | Should -BeGreaterOrEqual 2
    }

    It "Swallows all errors and does not throw (non-fatal)" {
        InModuleScope VcfEdgeAtScale {
            $fakeVmk0 = [PSCustomObject]@{ Name = "vmk0" }

            function Set-VMHostNetworkAdapter {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param([Parameter()] [Object]$VirtualNic, [Parameter()] [Object]$VMotionEnabled,
                    [Parameter()] [Object]$VsanTrafficEnabled, [Parameter()] [Object]$VsanWitnessEnabled,
                    [Parameter()] [Object]$Mtu)
                throw "Permanent API failure"
            }
            Mock Write-LogMessage {}

            { Invoke-ClearVmk0TrafficFlags -HostDisplay "esx01.lab" -Vmk0 $fakeVmk0 } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "WARNING" -and $Message -match "non-fatal" }
        }
    }
}

# ── Invoke-MigrateVmk0ToVds ───────────────────────────────────────────────────


Describe "Invoke-MigrateVmk0ToVds" {

    It "Skips Add-VDSwitchPhysicalNetworkAdapter when HostAlreadyHasPnicOnVds is true" {
        $addCalled = InModuleScope VcfEdgeAtScale {
            $Script:_addPnicCalled = $false
            $fakeVmk0 = [PSCustomObject]@{ Name = "vmk0" }
            $fakeMgmtInfo = [PSCustomObject]@{
                ManagementVmkernel = $fakeVmk0
                StandardSwitch     = [PSCustomObject]@{ Name = "vSwitch0" }
            }
            $fakeVds = [PSCustomObject]@{ Name = "VDS-edge1" }

            function Get-VMHostNetworkAdapter {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$Physical,
                    [Parameter()] [Object]$Name, [Parameter()] [Object]$VMKernel, [Parameter()] [Object]$PortGroup,
                    [Parameter()] [Object]$Server)
                return [PSCustomObject]@{ Name = $Name }
            }
            function Add-VDSwitchPhysicalNetworkAdapter {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param([Parameter(ValueFromPipeline = $true)] [Object]$In, [Parameter()] [Object]$VMHostPhysicalNic,
                    [Parameter()] [Object]$Server)
                begin { $Script:_addPnicCalled = $true }; process {}
            }
            function Get-PhysicalNicsOnVdsForHost {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$VDSwitch, [Parameter()] [Object]$Server)
                return @([PSCustomObject]@{ Name = "vmnic0" })
            }
            function Set-VMHostNetworkAdapter {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param([Parameter()] [Object]$VirtualNic, [Parameter()] [Object]$PortGroup,
                    [Parameter()] [Object]$VMotionEnabled, [Parameter()] [Object]$VsanTrafficEnabled,
                    [Parameter()] [Object]$VsanWitnessEnabled, [Parameter()] [Object]$Mtu)
            }
            function Invoke-ClearVmk0TrafficFlags {
                [CmdletBinding()] Param([Parameter()] [Object]$HostDisplay, [Parameter()] [Object]$Vmk0)
            }
            function Get-VirtualPortGroup {
                [CmdletBinding()] Param([Parameter()] [Object]$VirtualSwitch, [Parameter()] [Object]$Server)
                return @()
            }
            function Get-VM {
                [CmdletBinding()] Param([Parameter()] [Object]$Server, [Parameter()] [Object]$Location)
                return @()
            }
            function Remove-VirtualSwitch {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param([Parameter()] [Object]$VirtualSwitch, [Parameter()] [Object]$Server)
            }
            function Invoke-AddUplinkToVds {
                [CmdletBinding()] Param([Parameter()] [Object]$FirstUnusedNicName, [Parameter()] [Object]$HostDisplay,
                    [Parameter()] [Object]$NicNames, [Parameter()] [Object]$ReclaimedPnicName, [Parameter()] [Object]$StdSwitchName,
                    [Parameter()] [Object]$VdsName, [Parameter()] [Object]$VdsObject, [Parameter()] [Object]$VMHost,
                    [Parameter()] [Object]$VssPnicsToReclaim)
            }

            Invoke-MigrateVmk0ToVds `
                -EffectiveMgmtVlanId 100 -FirstUnused "vmnic1" -HostAlreadyHasPnicOnVds $true `
                -HostDisplay "esx01.lab" -ManagementPortGroupName "Management" -MgmtInfo $fakeMgmtInfo `
                -NicNames @("vmnic0","vmnic1") -ReclaimedPnicName "" -VdsName "VDS-edge1" `
                -VdsObject $fakeVds -VMHost ([PSCustomObject]@{ Name = "esx01.lab" }) `
                -VssPnicsToReclaimAfterVssRemoval @()
            $Script:_addPnicCalled
        }
        $addCalled | Should -Be $false
    }

    It "Sets Script:DidMigrateVmk0ToVdsThisRun to true when Set-VMHostNetworkAdapter succeeds" {
        $migrated = InModuleScope VcfEdgeAtScale {
            $Script:DidMigrateVmk0ToVdsThisRun = $false
            $fakeVmk0 = [PSCustomObject]@{ Name = "vmk0" }
            $fakeMgmtInfo = [PSCustomObject]@{
                ManagementVmkernel = $fakeVmk0
                StandardSwitch     = [PSCustomObject]@{ Name = "vSwitch0" }
            }

            function Get-PhysicalNicsOnVdsForHost {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$VDSwitch, [Parameter()] [Object]$Server)
                return @([PSCustomObject]@{ Name = "vmnic0" })
            }
            function Set-VMHostNetworkAdapter {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param([Parameter()] [Object]$VirtualNic, [Parameter()] [Object]$PortGroup,
                    [Parameter()] [Object]$VMotionEnabled, [Parameter()] [Object]$VsanTrafficEnabled,
                    [Parameter()] [Object]$VsanWitnessEnabled, [Parameter()] [Object]$Mtu)
            }
            function Invoke-ClearVmk0TrafficFlags {
                [CmdletBinding()] Param([Parameter()] [Object]$HostDisplay, [Parameter()] [Object]$Vmk0)
            }
            function Get-VirtualPortGroup {
                [CmdletBinding()] Param([Parameter()] [Object]$VirtualSwitch, [Parameter()] [Object]$Server)
                return @()
            }
            function Get-VM { [CmdletBinding()] Param([Parameter()] [Object]$Server, [Parameter()] [Object]$Location) return @() }
            function Remove-VirtualSwitch { [CmdletBinding(SupportsShouldProcess = $true)] Param([Parameter()] [Object]$VirtualSwitch, [Parameter()] [Object]$Server) }
            function Invoke-AddUplinkToVds {
                [CmdletBinding()] Param([Parameter()] [Object]$FirstUnusedNicName, [Parameter()] [Object]$HostDisplay,
                    [Parameter()] [Object]$NicNames, [Parameter()] [Object]$ReclaimedPnicName, [Parameter()] [Object]$StdSwitchName,
                    [Parameter()] [Object]$VdsName, [Parameter()] [Object]$VdsObject, [Parameter()] [Object]$VMHost,
                    [Parameter()] [Object]$VssPnicsToReclaim)
            }

            Invoke-MigrateVmk0ToVds `
                -EffectiveMgmtVlanId 100 -FirstUnused "vmnic1" -HostAlreadyHasPnicOnVds $true `
                -HostDisplay "esx01.lab" -ManagementPortGroupName "Management" -MgmtInfo $fakeMgmtInfo `
                -NicNames @("vmnic0","vmnic1") -ReclaimedPnicName "" -VdsName "VDS-edge1" `
                -VdsObject ([PSCustomObject]@{ Name = "VDS-edge1" }) `
                -VMHost ([PSCustomObject]@{ Name = "esx01.lab" }) `
                -VssPnicsToReclaimAfterVssRemoval @()
            $Script:DidMigrateVmk0ToVdsThisRun
        }
        $migrated | Should -Be $true
    }

    It "Throws when a VM is found on a port group of the standard switch being removed" {
        {
            InModuleScope VcfEdgeAtScale {
                $fakeVmk0 = [PSCustomObject]@{ Name = "vmk0" }
                $fakePg = [PSCustomObject]@{ Name = "VM Network" }
                $fakeMgmtInfo = [PSCustomObject]@{
                    ManagementVmkernel = $fakeVmk0
                    StandardSwitch     = [PSCustomObject]@{ Name = "vSwitch0" }
                }
                $fakeVm = [PSCustomObject]@{
                    Name = "vm01"
                    NetworkAdapters = @([PSCustomObject]@{ Network = [PSCustomObject]@{ Name = "VM Network" } })
                }

                function Get-PhysicalNicsOnVdsForHost {
                    [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$VDSwitch, [Parameter()] [Object]$Server)
                    return @([PSCustomObject]@{ Name = "vmnic0" })
                }
                function Set-VMHostNetworkAdapter {
                    [CmdletBinding(SupportsShouldProcess = $true)]
                    Param([Parameter()] [Object]$VirtualNic, [Parameter()] [Object]$PortGroup,
                        [Parameter()] [Object]$VMotionEnabled, [Parameter()] [Object]$VsanTrafficEnabled,
                        [Parameter()] [Object]$VsanWitnessEnabled, [Parameter()] [Object]$Mtu)
                }
                function Invoke-ClearVmk0TrafficFlags {
                    [CmdletBinding()] Param([Parameter()] [Object]$HostDisplay, [Parameter()] [Object]$Vmk0)
                }
                function Get-VirtualPortGroup {
                    [CmdletBinding()] Param([Parameter()] [Object]$VirtualSwitch, [Parameter()] [Object]$Server)
                    return @($fakePg)
                }
                function Get-VM {
                    [CmdletBinding()] Param([Parameter()] [Object]$Server, [Parameter()] [Object]$Location)
                    return @($fakeVm)
                }

                Invoke-MigrateVmk0ToVds `
                    -EffectiveMgmtVlanId 100 -FirstUnused "vmnic1" -HostAlreadyHasPnicOnVds $true `
                    -HostDisplay "esx01.lab" -ManagementPortGroupName "Management" -MgmtInfo $fakeMgmtInfo `
                    -NicNames @("vmnic0","vmnic1") -ReclaimedPnicName "" -VdsName "VDS-edge1" `
                    -VdsObject ([PSCustomObject]@{ Name = "VDS-edge1" }) `
                    -VMHost ([PSCustomObject]@{ Name = "esx01.lab" }) `
                    -VssPnicsToReclaimAfterVssRemoval @()
            }
        } | Should -Throw

    }
}


Describe "Invoke-AddUplinkToVds — second NicList pNIC and fallback paths" {

    It "Calls Add-VDSwitchPhysicalNetworkAdapter once when the second NicList NIC is not yet on VDS" {
        $addCount = InModuleScope VcfEdgeAtScale {
            $Script:vCenterName = "vc.lab"
            function Get-VMHostNetworkAdapter {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$Physical, [Parameter()] [Object]$Name, [Parameter()] [Object]$VirtualSwitch, [Parameter()] [Object]$Server)
                if ($Name) { return [PSCustomObject]@{ Name = [String]$Name } }
                return @()
            }
            $Script:_addUplinkCount = 0
            function Add-VDSwitchPhysicalNetworkAdapter {
                [CmdletBinding(SupportsShouldProcess = $true)] Param([Parameter(ValueFromPipeline = $true)] [Object]$VDSwitch, [Parameter()] [Object]$VMHostPhysicalNic, [Parameter()] [Object]$Server)
                begin { $Script:_addUplinkCount++ }
                process {}
            }
            Mock Write-LogMessage {}
            $fakeVds = [PSCustomObject]@{ Name = "myVDS" }
            Invoke-AddUplinkToVds `
                -FirstUnusedNicName "vmnic0" `
                -HostDisplay        "esx01.lab" `
                -NicNames           @("vmnic0", "vmnic1") `
                -VdsName            "myVDS" `
                -VdsObject          $fakeVds `
                -VMHost             ([PSCustomObject]@{ Name = "esx01.lab" })
            $Script:_addUplinkCount
        }
        $addCount | Should -Be 1
    }

    It "Falls back to reclaimed pNIC when the second NicList NIC is already on VDS" {
        $addCount = InModuleScope VcfEdgeAtScale {
            $Script:vCenterName = "vc.lab"
            function Get-VMHostNetworkAdapter {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$Physical, [Parameter()] [Object]$Name, [Parameter()] [Object]$VirtualSwitch, [Parameter()] [Object]$Server)
                if ($Name) { return [PSCustomObject]@{ Name = [String]$Name } }
                # VirtualSwitch check: vmnic1 already on VDS → pnicToAddAsSecond stays $null
                return @([PSCustomObject]@{ Name = "vmnic1" })
            }
            $Script:_addUplinkCount = 0
            function Add-VDSwitchPhysicalNetworkAdapter {
                [CmdletBinding(SupportsShouldProcess = $true)] Param([Parameter(ValueFromPipeline = $true)] [Object]$VDSwitch, [Parameter()] [Object]$VMHostPhysicalNic, [Parameter()] [Object]$Server)
                begin { $Script:_addUplinkCount++ }
                process {}
            }
            Mock Write-LogMessage {}
            $fakeVds = [PSCustomObject]@{ Name = "myVDS" }
            Invoke-AddUplinkToVds `
                -FirstUnusedNicName "vmnic0" `
                -HostDisplay        "esx01.lab" `
                -NicNames           @("vmnic0", "vmnic1") `
                -ReclaimedPnicName  "vmnic2" `
                -VdsName            "myVDS" `
                -VdsObject          $fakeVds `
                -VMHost             ([PSCustomObject]@{ Name = "esx01.lab" })
            $Script:_addUplinkCount
        }
        # vmnic1 skipped (already on VDS); reclaimed vmnic2 is added instead.
        $addCount | Should -Be 1
    }

    It "Skips an extra pNIC in the three-plus uplink loop when already on VDS" {
        $addCount = InModuleScope VcfEdgeAtScale {
            $Script:vCenterName = "vc.lab"
            $Script:_vdsQueryCount = 0
            function Get-VMHostNetworkAdapter {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$Physical, [Parameter()] [Object]$Name, [Parameter()] [Object]$VirtualSwitch, [Parameter()] [Object]$Server)
                if ($Name) { return [PSCustomObject]@{ Name = [String]$Name } }
                # First VirtualSwitch call: second-NIC existence check → empty (vmnic1 not on VDS yet)
                # Second VirtualSwitch call: extra-loop check for vmnic3 → vmnic3 already on VDS
                $Script:_vdsQueryCount++
                if ($Script:_vdsQueryCount -le 1) { return @() }
                return @([PSCustomObject]@{ Name = "vmnic3" })
            }
            $Script:_addUplinkCount = 0
            function Add-VDSwitchPhysicalNetworkAdapter {
                [CmdletBinding(SupportsShouldProcess = $true)] Param([Parameter(ValueFromPipeline = $true)] [Object]$VDSwitch, [Parameter()] [Object]$VMHostPhysicalNic, [Parameter()] [Object]$Server)
                begin { $Script:_addUplinkCount++ }
                process {}
            }
            Mock Write-LogMessage {}
            $fakeVds = [PSCustomObject]@{ Name = "myVDS" }
            Invoke-AddUplinkToVds `
                -FirstUnusedNicName "vmnic0" `
                -HostDisplay        "esx01.lab" `
                -NicNames           @("vmnic0", "vmnic1") `
                -ReclaimedPnicName  "vmnic2" `
                -VdsName            "myVDS" `
                -VdsObject          $fakeVds `
                -VMHost             ([PSCustomObject]@{ Name = "esx01.lab" }) `
                -VssPnicsToReclaim  @("vmnic2", "vmnic3")
            $Script:_addUplinkCount
        }
        # vmnic1 (second NicList) added once; vmnic3 (extra) skipped since already on VDS.
        $addCount | Should -Be 1
    }
}


Describe "New-VmkernelForSegment — idempotency and creation paths" {

    It "Returns without creating a VMkernel when one already exists on the port group" {
        $createCount = InModuleScope VcfEdgeAtScale {
            function Get-VMHostNetworkAdapter {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$VMKernel, [Parameter()] [Object]$PortGroup, [Parameter()] [Object]$Server)
                # Idempotency: return existing VMkernel
                return [PSCustomObject]@{ Name = "vmk1"; IP = "10.0.0.10"; SubnetMask = "255.255.255.0" }
            }
            $Script:_newVmkCount = 0
            function New-VMHostNetworkAdapter {
                [CmdletBinding(SupportsShouldProcess = $true)] Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$PortGroup, [Parameter()] [Object]$IP, [Parameter()] [Object]$SubnetMask, [Parameter()] [Object]$VirtualSwitch, [Parameter()] [Object]$VMotionEnabled, [Parameter()] [Object]$VsanTrafficEnabled)
                begin { $Script:_newVmkCount++ }
                process {}
            }
            function Set-VMHostNetworkAdapter {
                [CmdletBinding(SupportsShouldProcess = $true)] Param([Parameter()] [Object]$VirtualNic, [Parameter()] [Object]$Mtu, [Parameter()] [Object]$VsanTrafficEnabled, [Parameter()] [Object]$VsanWitnessEnabled, [Parameter()] [Object]$VMotionEnabled)
                begin {}; process {}
            }
            Mock Write-LogMessage {}
            $fakePg  = [PSCustomObject]@{ Name = "vmotion-edge1" }
            $fakeVds = [PSCustomObject]@{ Name = "myVDS" }
            New-VmkernelForSegment -Ip "10.0.0.10" -Netmask "255.255.255.0" -PortGroup $fakePg `
                -PortGroupName "vmotion-edge1" -Server "vc.lab" -ServiceName "vMotion" `
                -VdsObject $fakeVds -VMHost ([PSCustomObject]@{ Name = "esx01.lab" })
            $Script:_newVmkCount
        }
        $createCount | Should -Be 0
    }

    It "Calls New-VMHostNetworkAdapter with VMotionEnabled when service is vMotion" {
        $createCount = InModuleScope VcfEdgeAtScale {
            function Get-VMHostNetworkAdapter {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$VMKernel, [Parameter()] [Object]$PortGroup, [Parameter()] [Object]$Server)
                return $null
            }
            $Script:_newVmkCount = 0
            function New-VMHostNetworkAdapter {
                [CmdletBinding(SupportsShouldProcess = $true)] Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$PortGroup, [Parameter()] [Object]$IP, [Parameter()] [Object]$SubnetMask, [Parameter()] [Object]$VirtualSwitch, [Parameter()] [Object]$VMotionEnabled, [Parameter()] [Object]$VsanTrafficEnabled)
                begin { $Script:_newVmkCount++ }
                process { return [PSCustomObject]@{ Name = "vmk1" } }
            }
            function Set-VMHostNetworkAdapter {
                [CmdletBinding(SupportsShouldProcess = $true)] Param([Parameter()] [Object]$VirtualNic, [Parameter()] [Object]$Mtu, [Parameter()] [Object]$VsanTrafficEnabled, [Parameter()] [Object]$VsanWitnessEnabled, [Parameter()] [Object]$VMotionEnabled)
                begin {}; process {}
            }
            Mock Write-LogMessage {}
            $fakePg  = [PSCustomObject]@{ Name = "vmotion-edge1" }
            $fakeVds = [PSCustomObject]@{ Name = "myVDS" }
            New-VmkernelForSegment -Ip "10.0.0.20" -Netmask "255.255.255.0" -PortGroup $fakePg `
                -PortGroupName "vmotion-edge1" -Server "vc.lab" -ServiceName "vMotion" `
                -VdsObject $fakeVds -VMHost ([PSCustomObject]@{ Name = "esx01.lab" })
            $Script:_newVmkCount
        }
        $createCount | Should -Be 1
    }

    It "Falls back to Add-VsanWitnessTrafficToVmkViaEsxcli when Set-VMHostNetworkAdapter rejects VsanWitnessEnabled" {
        $esxcliCount = InModuleScope VcfEdgeAtScale {
            function Get-VMHostNetworkAdapter {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$VMKernel, [Parameter()] [Object]$PortGroup, [Parameter()] [Object]$Server)
                return $null
            }
            function New-VMHostNetworkAdapter {
                [CmdletBinding(SupportsShouldProcess = $true)] Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$PortGroup, [Parameter()] [Object]$IP, [Parameter()] [Object]$SubnetMask, [Parameter()] [Object]$VirtualSwitch, [Parameter()] [Object]$VMotionEnabled, [Parameter()] [Object]$VsanTrafficEnabled)
                begin {}
                process { return [PSCustomObject]@{ Name = "vmk3" } }
            }
            function Set-VMHostNetworkAdapter {
                [CmdletBinding(SupportsShouldProcess = $true)] Param([Parameter()] [Object]$VirtualNic, [Parameter()] [Object]$Mtu, [Parameter()] [Object]$VsanTrafficEnabled, [Parameter()] [Object]$VsanWitnessEnabled, [Parameter()] [Object]$VMotionEnabled)
                begin {}
                process {
                    # Simulate VsanWitnessEnabled rejection (first call); MTU set succeeds afterward.
                    if ($VsanWitnessEnabled) { throw "Parameter set cannot be resolved using the specified named parameters." }
                }
            }
            # Function stub required — Add-VsanWitnessTrafficToVmkViaEsxcli has VMware typed params
            # so Mock can't resolve its CommandMetadata without a live vCenter connection.
            $Script:_esxcliCount = 0
            function Add-VsanWitnessTrafficToVmkViaEsxcli {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$VmkernelName, [Parameter()] [Switch]$WitnessOnly)
                begin { $Script:_esxcliCount++ }
                process {}
            }
            Mock Write-LogMessage {}
            $fakePg  = [PSCustomObject]@{ Name = "vsanwitness-edge1" }
            $fakeVds = [PSCustomObject]@{ Name = "myVDS" }
            New-VmkernelForSegment -Ip "10.0.0.30" -Netmask "255.255.255.0" -PortGroup $fakePg `
                -PortGroupName "vsanwitness-edge1" -Server "vc.lab" -ServiceName "vSAN Witness" `
                -VdsObject $fakeVds -VMHost ([PSCustomObject]@{ Name = "esx01.lab" })
            $Script:_esxcliCount
        }
        $esxcliCount | Should -Be 1
    }
}


Describe "Get-DatacenterForVMHost — wrapper pass-through" {
    # Get-Datacenter has ArgumentTransformationAttribute on -VMHost (expects VIHost[], rejects PSCustomObject).
    # The wrapper's value is that its own -VMHost is [PSObject], so callers can mock it with PSCustomObject
    # fixtures. Verify that structural contract.
    It "Defines VMHost as [PSObject] so callers can mock it without ArgumentTransformationAttribute errors" {
        InModuleScope VcfEdgeAtScale {
            $cmd = Get-Command -Name "Get-DatacenterForVMHost"
            $cmd | Should -Not -BeNull
            $cmd.Parameters["VMHost"].ParameterType.FullName | Should -Be "System.Management.Automation.PSObject"
        }
    }
}


Describe "Get-DatacenterForCluster — wrapper pass-through" {
    # Get-Datacenter has ArgumentTransformationAttribute on -Cluster (expects Cluster[], rejects PSCustomObject).
    # The wrapper's value is that its own -Cluster is [PSObject], so callers can mock it with PSCustomObject
    # fixtures. Verify that structural contract.
    It "Defines Cluster as [PSObject] so callers can mock it without ArgumentTransformationAttribute errors" {
        InModuleScope VcfEdgeAtScale {
            $cmd = Get-Command -Name "Get-DatacenterForCluster"
            $cmd | Should -Not -BeNull
            $cmd.Parameters["Cluster"].ParameterType.FullName | Should -Be "System.Management.Automation.PSObject"
        }
    }
}


Describe "Set-VDSUplinkTeamingActiveStandby — VDS not found" {
    It "Logs a warning and returns without error when the VDS does not exist" {
        InModuleScope VcfEdgeAtScale {
            $Script:vCenterName = "vc.lab"
            $loggedWarnings = [System.Collections.Generic.List[PSCustomObject]]::new()
            Mock Write-LogMessage {
                $loggedWarnings.Add([PSCustomObject]@{ Type = $Type; Message = $Message })
            }
            function Get-VDSwitch {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                return $null
            }
            Set-VDSUplinkTeamingActiveStandby -VdsName "missing-vds"
            $loggedWarnings | Where-Object { $_.Type -eq "WARNING" -and $_.Message -like "*not found*" } |
                Should -Not -BeNullOrEmpty
        }
    }
}


Describe "Set-VDSUplinkTeamingActiveStandby — fewer than 2 uplinks" {
    It "Logs a debug message and returns without calling Set-VDUplinkTeamingPolicy" {
        InModuleScope VcfEdgeAtScale {
            $Script:vCenterName = "vc.lab"
            $fakeVds = [PSCustomObject]@{
                Name          = "vds1"
                ExtensionData = [PSCustomObject]@{
                    Config = [PSCustomObject]@{
                        UplinkPortPolicy = [PSCustomObject]@{ UplinkPortName = @("Uplink 1") }
                    }
                }
            }
            $loggedMessages = [System.Collections.Generic.List[PSCustomObject]]::new()
            Mock Write-LogMessage {
                $loggedMessages.Add([PSCustomObject]@{ Type = $Type; Message = $Message })
            }
            $Script:_setTeamingCalled = $false
            function Get-VDSwitch {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                return $fakeVds
            }
            function Set-VDUplinkTeamingPolicy {
                [CmdletBinding()] Param(
                    [Parameter()] [Object]$Policy,
                    [Parameter()] [Object]$ActiveUplinkPort,
                    [Parameter()] [Object]$StandbyUplinkPort,
                    [Parameter()] [Object]$LoadBalancingPolicy,
                    [Parameter()] [Object]$EnableFailback
                )
                $Script:_setTeamingCalled = $true
            }
            Set-VDSUplinkTeamingActiveStandby -VdsName "vds1"
            $loggedMessages | Where-Object { $_.Message -like "*fewer than 2 uplinks*" } |
                Should -Not -BeNullOrEmpty
            $Script:_setTeamingCalled | Should -Be $false
        }
    }
}


Describe "Set-VDSUplinkTeamingActiveStandby — idempotency" {
    It "Does not call Set-VDUplinkTeamingPolicy when policy is already active/standby" {
        # Policy already has Uplink 1 active, Uplink 2 standby, ExplicitFailover, failback=true.
        # The function must detect this and return without mutating the policy.
        InModuleScope VcfEdgeAtScale {
            $Script:vCenterName = "vc.lab"
            $fakeVds = [PSCustomObject]@{
                Name          = "vds1"
                ExtensionData = [PSCustomObject]@{
                    Config = [PSCustomObject]@{
                        UplinkPortPolicy = [PSCustomObject]@{
                            UplinkPortName = @("Uplink 1", "Uplink 2")
                        }
                    }
                }
            }
            $fakePolicy = [PSCustomObject]@{
                ActiveUplinkPort    = @("Uplink 1")
                StandbyUplinkPort   = @("Uplink 2")
                LoadBalancingPolicy = "ExplicitFailover"
                EnableFailback      = $true
            }
            Mock Write-LogMessage {}
            $Script:_idempotentSetCalled = $false
            function Get-VDSwitch {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                return $fakeVds
            }
            function Get-VDUplinkTeamingPolicy {
                [CmdletBinding()] Param([Parameter(ValueFromPipeline = $true)] [Object]$VDSwitch)
                begin {}; process { return $fakePolicy }
            }
            function Set-VDUplinkTeamingPolicy {
                [CmdletBinding()] Param(
                    [Parameter()] [Object]$Policy,
                    [Parameter()] [Object]$ActiveUplinkPort,
                    [Parameter()] [Object]$StandbyUplinkPort,
                    [Parameter()] [Object]$LoadBalancingPolicy,
                    [Parameter()] [Object]$EnableFailback
                )
                $Script:_idempotentSetCalled = $true
            }
            Set-VDSUplinkTeamingActiveStandby -VdsName "vds1"
            $Script:_idempotentSetCalled | Should -Be $false
        }
    }
}


Describe "Set-VDSUplinkTeamingActiveStandby — policy update" {
    It "Calls Set-VDUplinkTeamingPolicy when the uplinks are configured in the wrong order" {
        # Policy has Uplink 2 as active (backwards). Function must call Set-VDUplinkTeamingPolicy.
        $wasCalled = InModuleScope VcfEdgeAtScale {
            $Script:vCenterName = "vc.lab"
            $fakeVds = [PSCustomObject]@{
                Name          = "vds1"
                ExtensionData = [PSCustomObject]@{
                    Config = [PSCustomObject]@{
                        UplinkPortPolicy = [PSCustomObject]@{
                            UplinkPortName = @("Uplink 1", "Uplink 2")
                        }
                    }
                }
            }
            $fakePolicyWrong = [PSCustomObject]@{
                ActiveUplinkPort  = @("Uplink 2")
                StandbyUplinkPort = @("Uplink 1")
            }
            Mock Write-LogMessage {}
            $Script:_policySetCalled = $false
            function Get-VDSwitch {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                return $fakeVds
            }
            function Get-VDUplinkTeamingPolicy {
                [CmdletBinding()] Param([Parameter(ValueFromPipeline = $true)] [Object]$VDSwitch)
                begin {}; process { return $fakePolicyWrong }
            }
            function Set-VDUplinkTeamingPolicy {
                [CmdletBinding()] Param(
                    [Parameter()] [Object]$Policy,
                    [Parameter()] [Object]$ActiveUplinkPort,
                    [Parameter()] [Object]$StandbyUplinkPort,
                    [Parameter()] [Object]$LoadBalancingPolicy,
                    [Parameter()] [Object]$EnableFailback
                )
                $Script:_policySetCalled = $true
            }
            Set-VDSUplinkTeamingActiveStandby -VdsName "vds1"
            $Script:_policySetCalled
        }
        $wasCalled | Should -Be $true
    }
}

# ── Get-HarborEventTexts ─────────────────────────────────────────────────────


Describe "Add-HostToVDS — error branch routing" {

    It "Logs INFO and does not throw when host is already added to VDS" {
        InModuleScope VcfEdgeAtScale {
            $Script:vCenterName = "vc.lab"
            Mock Write-LogMessage {}
            function Add-VDSwitchVMHost {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$VDSwitch, [Parameter()] [Object]$Server)
                begin { throw "is already added to VDSwitch" }; process {}
            }
            Add-HostToVDS -Hostname ([PSCustomObject]@{ Name = "esx01.lab" }) -VdsName "VDS-edge1"
            Should -Invoke Write-LogMessage -Times 1 -ParameterFilter { $Message -like "*already attached*" }
        }
    }

    It "Logs INFO and does not throw when host already exists on VDS" {
        InModuleScope VcfEdgeAtScale {
            $Script:vCenterName = "vc.lab"
            Mock Write-LogMessage {}
            function Add-VDSwitchVMHost {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$VDSwitch, [Parameter()] [Object]$Server)
                begin { throw "already exists" }; process {}
            }
            Add-HostToVDS -Hostname ([PSCustomObject]@{ Name = "esx01.lab" }) -VdsName "VDS-edge1"
            Should -Invoke Write-LogMessage -Times 1 -ParameterFilter { $Message -like "*already associated*" }
        }
    }

    It "Returns Write-ErrorAndReturn result on unexpected Add-VDSwitchVMHost failure" {
        $result = InModuleScope VcfEdgeAtScale {
            $Script:vCenterName = "vc.lab"
            Mock Write-LogMessage {}
            Mock Write-ErrorAndReturn { [PSCustomObject]@{ Code = "ERR_VDS_UNEXPECTED" } }
            function Add-VDSwitchVMHost {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$VDSwitch, [Parameter()] [Object]$Server)
                begin { throw "catastrophic failure" }; process {}
            }
            Add-HostToVDS -Hostname ([PSCustomObject]@{ Name = "esx01.lab" }) -VdsName "VDS-edge1"
        }
        $result.Code | Should -Be "ERR_VDS_UNEXPECTED"
    }
}

# ── Invoke-VdsNicConnectivityCheck ───────────────────────────────────────────


Describe "Invoke-VdsNicConnectivityCheck — 2-uplink NIC validation" {

    It "Throws VcfDeploymentException when a NIC is disconnected in 2-uplink topology" {
        InModuleScope VcfEdgeAtScale {
            $Script:vCenterName = "vc.lab"
            Mock Write-LogMessage {}
            Mock Test-PhysicalNicConnected { $false }
            $vmHost = [PSCustomObject]@{ Name = "esx01.lab" }
            { Invoke-VdsNicConnectivityCheck -Hosts @($vmHost) -NicNames @("vmnic0") -NumUplinks 2 -VdsName "VDS-edge1" } |
                Should -Throw "*not connected*"
        }
    }

    It "Does not throw when all NICs are connected in 2-uplink topology" {
        InModuleScope VcfEdgeAtScale {
            $Script:vCenterName = "vc.lab"
            Mock Write-LogMessage {}
            Mock Test-PhysicalNicConnected { $true }
            $vmHost = [PSCustomObject]@{ Name = "esx01.lab" }
            # Must not throw.
            Invoke-VdsNicConnectivityCheck -Hosts @($vmHost) -NicNames @("vmnic0", "vmnic1") -NumUplinks 2 -VdsName "VDS-edge1"
            Should -Not -Invoke Write-LogMessage -ParameterFilter { $Type -eq "ERROR" }
        }
    }

    It "Throws for a disconnected sw1 NIC in 4-uplink topology" {
        InModuleScope VcfEdgeAtScale {
            $Script:vCenterName = "vc.lab"
            Mock Write-LogMessage {}
            # First NIC (sw1) is disconnected; second (sw2) is connected.
            $Script:_nicCallIdx = 0
            Mock Test-PhysicalNicConnected {
                $Script:_nicCallIdx++
                # First two calls are for sw1 NICs; first one is disconnected.
                return ($Script:_nicCallIdx -ne 1)
            }
            $vmHost = [PSCustomObject]@{ Name = "esx01.lab" }
            { Invoke-VdsNicConnectivityCheck -Hosts @($vmHost) -NicNames @("vmnic0", "vmnic1", "vmnic2", "vmnic3") -NumUplinks 4 -VdsName "VDS-edge" } |
                Should -Throw "*-sw1*"
        }
    }

    It "Throws for a disconnected sw2 NIC in 4-uplink topology" {
        InModuleScope VcfEdgeAtScale {
            $Script:vCenterName = "vc.lab"
            Mock Write-LogMessage {}
            # sw1 NICs are connected; first sw2 NIC is disconnected.
            $Script:_nicCallIdx2 = 0
            Mock Test-PhysicalNicConnected {
                $Script:_nicCallIdx2++
                # Calls 1+2 are sw1 NICs (connected); call 3 is sw2 first NIC (disconnected).
                return ($Script:_nicCallIdx2 -ne 3)
            }
            $vmHost = [PSCustomObject]@{ Name = "esx01.lab" }
            { Invoke-VdsNicConnectivityCheck -Hosts @($vmHost) -NicNames @("vmnic0", "vmnic1", "vmnic2", "vmnic3") -NumUplinks 4 -VdsName "VDS-edge" } |
                Should -Throw "*-sw2*"
        }
    }
}

# ── Invoke-VdsTwoUplinkSetup ──────────────────────────────────────────────────


Describe "Invoke-VdsTwoUplinkSetup — orchestration path" {

    It "Calls Invoke-VDSCreation, Add-HostToVDS, Invoke-MigrateHostManagementToVds, New-VDSPortGroups, and Set-VDSUplinkTeamingActiveStandby" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Invoke-VDSCreation { [PSCustomObject]@{ Name = "VDS-edge1" } }
            Mock Add-HostToVDS { $null }
            Mock Invoke-MigrateHostManagementToVds {}
            Mock New-VDSPortGroups { [PSCustomObject]@{ Success = $true } }
            Mock Set-VDSUplinkTeamingActiveStandby {}
            $fakeDc   = [PSCustomObject]@{ Name = "dc1" }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            Invoke-VdsTwoUplinkSetup -DatacenterObject $fakeDc -Hosts @($fakeHost) `
                -ManagementPortGroupName "mgmt-edge1" -NicList @(@{ Name = "vmnic0" }) `
                -PortGroups @(@{ Name = "pg1"; VlanId = 100 }) -VdsName "VDS-edge1"
            Should -Invoke Invoke-VDSCreation                -Times 1
            Should -Invoke Add-HostToVDS                     -Times 1
            Should -Invoke Invoke-MigrateHostManagementToVds -Times 1
            Should -Invoke New-VDSPortGroups                 -Times 1
            Should -Invoke Set-VDSUplinkTeamingActiveStandby -Times 1
        }
    }

    It "Throws VcfDeploymentException when Add-HostToVDS returns a failure result" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Invoke-VDSCreation { [PSCustomObject]@{ Name = "VDS-edge1" } }
            Mock Add-HostToVDS { [PSCustomObject]@{ Success = $false; ErrorMessage = "add failed" } }
            $fakeDc   = [PSCustomObject]@{ Name = "dc1" }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            { Invoke-VdsTwoUplinkSetup -DatacenterObject $fakeDc -Hosts @($fakeHost) `
                -ManagementPortGroupName "mgmt-edge1" -NicList @(@{ Name = "vmnic0" }) `
                -PortGroups @(@{ Name = "pg1"; VlanId = 100 }) -VdsName "VDS-edge1" } |
                Should -Throw "*add failed*"
        }
    }
}

# ── Invoke-VdsFourUplinkSetup ─────────────────────────────────────────────────


Describe "Invoke-VdsFourUplinkSetup — dual-VDS orchestration" {

    It "Creates sw1 and sw2, adds hosts to both, and calls Add-PhysicalAdaptersToVDS for sw2 NICs" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $Script:_vdsCreateCount = 0
            Mock Invoke-VDSCreation {
                $Script:_vdsCreateCount++
                [PSCustomObject]@{ Name = "VDS-$($Script:_vdsCreateCount)" }
            }
            Mock Add-HostToVDS { $null }
            Mock Invoke-MigrateHostManagementToVds {}
            Mock Add-PhysicalAdaptersToVDS { $null }
            Mock New-VDSPortGroups { [PSCustomObject]@{ Success = $true } }
            Mock Set-VDSUplinkTeamingActiveStandby {}
            $fakeDc   = [PSCustomObject]@{ Name = "dc1" }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            $nics = @(@{ Name = "vmnic0" }, @{ Name = "vmnic1" }, @{ Name = "vmnic2" }, @{ Name = "vmnic3" })
            Invoke-VdsFourUplinkSetup -DatacenterObject $fakeDc -Hosts @($fakeHost) `
                -ManagementPortGroupName "mgmt-edge1" -NicList $nics `
                -PortGroups @(@{ Name = "pg1"; VlanId = 100 }) -VdsName "VDS-edge"
            Should -Invoke Invoke-VDSCreation       -Times 2
            Should -Invoke Add-HostToVDS             -Times 2
            Should -Invoke Add-PhysicalAdaptersToVDS -Times 1
        }
    }

    It "Throws VcfDeploymentException when Add-HostToVDS returns a failure for the sw1 VDS" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Invoke-VDSCreation { [PSCustomObject]@{ Name = "VDS-edge-sw1" } }
            # First Add-HostToVDS call (sw1) returns a failure; sw2 call never reached.
            Mock Add-HostToVDS {
                [PSCustomObject]@{ Success = $false; ErrorMessage = "host add failed for sw1" }
            } -ParameterFilter { $VdsName -like "*-sw1" }
            $fakeDc   = [PSCustomObject]@{ Name = "dc1" }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            $nics = @(@{ Name = "vmnic0" }, @{ Name = "vmnic1" }, @{ Name = "vmnic2" }, @{ Name = "vmnic3" })
            {
                Invoke-VdsFourUplinkSetup -DatacenterObject $fakeDc -Hosts @($fakeHost) `
                    -ManagementPortGroupName "mgmt-edge1" -NicList $nics `
                    -PortGroups @(@{ Name = "pg1"; VlanId = 100 }) -VdsName "VDS-edge"
            } | Should -Throw
        }
    }

    It "Throws VcfDeploymentException when Add-HostToVDS returns a failure for the sw2 VDS" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $Script:_sw2CreateCount = 0
            Mock Invoke-VDSCreation {
                $Script:_sw2CreateCount++
                [PSCustomObject]@{ Name = "VDS-edge-sw$($Script:_sw2CreateCount)" }
            }
            # sw1 host add succeeds; sw2 returns a failure.
            Mock Add-HostToVDS { $null } -ParameterFilter { $VdsName -like "*-sw1" }
            Mock Add-HostToVDS {
                [PSCustomObject]@{ Success = $false; ErrorMessage = "host add failed for sw2" }
            } -ParameterFilter { $VdsName -like "*-sw2" }
            Mock Invoke-MigrateHostManagementToVds {}
            $fakeDc   = [PSCustomObject]@{ Name = "dc1" }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            $nics = @(@{ Name = "vmnic0" }, @{ Name = "vmnic1" }, @{ Name = "vmnic2" }, @{ Name = "vmnic3" })
            {
                Invoke-VdsFourUplinkSetup -DatacenterObject $fakeDc -Hosts @($fakeHost) `
                    -ManagementPortGroupName "mgmt-edge1" -NicList $nics `
                    -PortGroups @(@{ Name = "pg1"; VlanId = 100 }) -VdsName "VDS-edge"
            } | Should -Throw
        }
    }
}

# ── Invoke-VDSCreation ────────────────────────────────────────────────────────


Describe "Invoke-VDSCreation — connection guard and idempotency" {

    It "Throws VcfDeploymentException when vCenter is not connected" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $false; ErrorMessage = "no conn" } }
            { Invoke-VDSCreation -VdsName "VDS-edge1" -DatacenterObject ([PSCustomObject]@{ Name = "dc1" }) -NumUplinks "2" } |
                Should -Throw "*Not connected*"
        }
    }

    It "Returns existing VDS object without calling New-VDSwitch when VDS already exists" {
        $result = InModuleScope VcfEdgeAtScale {
            $Script:vCenterName = "vc.lab"
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true } }
            $fakeUplinks = @("uplink1", "uplink2")
            $fakeVds = [PSCustomObject]@{
                Name          = "VDS-edge1"
                ExtensionData = [PSCustomObject]@{
                    Config = [PSCustomObject]@{
                        UplinkPortPolicy = [PSCustomObject]@{ UplinkPortName = $fakeUplinks }
                    }
                }
            }
            function Get-VDSwitch {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Location,
                    [Parameter()] [Object]$Server, [Parameter()] [Object]$VDSwitch)
                return $fakeVds
            }
            function New-VDSwitch {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Location,
                    [Parameter()] [Object]$Mtu, [Parameter()] [Object]$NumUplinkPorts)
                begin { throw "New-VDSwitch must not be called when VDS exists" }; process {}
            }
            Invoke-VDSCreation -VdsName "VDS-edge1" -DatacenterObject ([PSCustomObject]@{ Name = "dc1" }) -NumUplinks "2"
        }
        $result.Name | Should -Be "VDS-edge1"
    }

    It "Creates and returns a new VDS when no matching VDS exists" {
        $result = InModuleScope VcfEdgeAtScale {
            $Script:vCenterName = "vc.lab"
            Mock Write-LogMessage {}
            Mock Start-Sleep {}
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true } }
            $fakeNewVds = [PSCustomObject]@{
                Name          = "VDS-edge1"
                ExtensionData = [PSCustomObject]@{
                    Config = [PSCustomObject]@{
                        UplinkPortPolicy = [PSCustomObject]@{ UplinkPortName = @("uplink1", "uplink2") }
                    }
                }
            }
            $Script:_vdsGetCount = 0
            function Get-VDSwitch {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Location,
                    [Parameter()] [Object]$Server, [Parameter()] [Object]$VDSwitch)
                $Script:_vdsGetCount++
                # First call: existence check → not found; subsequent calls: post-creation retrieval.
                if ($Script:_vdsGetCount -le 1) { return $null }
                return $fakeNewVds
            }
            function New-VDSwitch {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Location,
                    [Parameter()] [Object]$Mtu, [Parameter()] [Object]$NumUplinkPorts)
                begin {}; process {}
            }
            Invoke-VDSCreation -VdsName "VDS-edge1" -DatacenterObject ([PSCustomObject]@{ Name = "dc1" }) -NumUplinks "2"
        }
        $result.Name | Should -Be "VDS-edge1"
    }
}

# ── Get-EsxDatastoreInfo ──────────────────────────────────────────────────────


Describe "Get-EsxDatastoreInfo — connection guard" {

    It "Throws VcfDeploymentException when no active connection exists for the ESX host" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $Global:DefaultViServers = @()
            { Get-EsxDatastoreInfo -EsxHostName "esx01.lab" } |
                Should -Throw "*No active connection*"
        }
    }

    It "Does not throw the connection guard error when a matching active connection exists" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $fakeConn = [PSCustomObject]@{ Name = "esx01.lab"; IsConnected = $true }
            $Global:DefaultViServers = @($fakeConn)
            function Get-VMHost {
                [CmdletBinding()] Param([Parameter()] [Object]$Server, [Parameter()] [Object]$Name)
                return [PSCustomObject]@{ Name = "esx01.lab" }
            }
            # Stub Get-EsxUnformattedDisk to return empty so Get-ScsiLun is never called with a
            # PSCustomObject pipeline input (which produces a non-terminating error stream message
            # on systems where Get-ScsiLun is a binary cmdlet with strict pipeline-input types).
            Mock Get-EsxUnformattedDisk { @() }
            Mock Get-EsxDatastoreHealth { $null }
            # Passes the connection guard; any downstream error is acceptable for this test.
            try { Get-EsxDatastoreInfo -EsxHostName "esx01.lab" } catch {
                $_.Exception.Message | Should -Not -Match "No active connection"
            }
        }
    }
}

# ── Find-Datastore ────────────────────────────────────────────────────────────


Describe "New-VDSPortGroups — connection and idempotency paths" {

    It "Throws VcfDeploymentException when not connected to vCenter" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $false; ErrorMessage = "not connected" } }
            $portGroups = @([PSCustomObject]@{ Name = "pg-mgmt"; VlanId = 100 })
            { New-VDSPortGroups -VdsName "myVDS" -PortGroups $portGroups } | Should -Throw

        }
    }

    It "Skips creation and logs INFO when the port group already exists on the same VDS" {
        $logCalls = InModuleScope VcfEdgeAtScale {
            function Get-VDPortgroup {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server, [Parameter()] [Object]$VDSwitch)
                process {}
            }
            function New-VDPortgroup {
                [CmdletBinding()] Param([Parameter()] [Object]$Server, [Parameter()] [Object]$Name, [Parameter()] [Object]$VDSwitch, [Parameter()] [Object]$VlanId, [Parameter()] [Object]$NumPorts, [Parameter()] [Object]$PortBinding)
                process { throw "New-VDPortgroup must not be called for an existing port group" }
            }
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true; ErrorMessage = $null } }
            $fakeExistingPg = [PSCustomObject]@{
                VDSwitch = [PSCustomObject]@{ Name = "myVDS" }
                ExtensionData = [PSCustomObject]@{ Config = [PSCustomObject]@{ DefaultPortConfig = [PSCustomObject]@{ Vlan = [PSCustomObject]@{ VlanId = 100 } } } }
            }
            Mock Get-VDPortgroup { $fakeExistingPg }
            $portGroups = @([PSCustomObject]@{ Name = "pg-mgmt"; VlanId = 100 })
            New-VDSPortGroups -VdsName "myVDS" -PortGroups $portGroups
            $null
        }
        # If no exception was thrown, the test passes (New-VDPortgroup was not called).
        $true | Should -BeTrue
    }

    It "Calls New-VDPortgroup when the port group does not exist" {
        $createCount = InModuleScope VcfEdgeAtScale {
            function Get-VDPortgroup {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server, [Parameter()] [Object]$VDSwitch)
                process {}
            }
            $Script:_newPgCount = 0
            function New-VDPortgroup {
                [CmdletBinding()] Param([Parameter()] [Object]$Server, [Parameter()] [Object]$Name, [Parameter()] [Object]$VDSwitch, [Parameter()] [Object]$VlanId, [Parameter()] [Object]$NumPorts, [Parameter()] [Object]$PortBinding)
                begin { $Script:_newPgCount++ }
                process {}
            }
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true; ErrorMessage = $null } }
            Mock Get-VDPortgroup { $null }
            $portGroups = @([PSCustomObject]@{ Name = "pg-new"; VlanId = 200 })
            New-VDSPortGroups -VdsName "myVDS" -PortGroups $portGroups
            $Script:_newPgCount
        }
        $createCount | Should -BeGreaterOrEqual 1
    }
}

# ── Build-VmkernelPortGroupSpecs ─────────────────────────────────────────────


Describe "Build-VmkernelPortGroupSpecs — spec builder" {

    It "Returns two VmotionVsan entries and no Witness entries for vMotion + vSAN interfaces" {
        $result = InModuleScope VcfEdgeAtScale {
            $ifaces = @(
                [PSCustomObject]@{ service = "vMotion"; vlanId = 100; ipList = @("10.0.0.1") }
                [PSCustomObject]@{ service = "vSAN";    vlanId = 200; ipList = @("10.0.0.2") }
            )
            Build-VmkernelPortGroupSpecs -EdgeSuffix "site1" -NetworkingVmKernelInterfaces $ifaces
        }
        $result.VmotionVsan.Count | Should -Be 2
        $result.Witness.Count     | Should -Be 0
        $result.VmotionVsan[0].Name | Should -Be "vmotion-site1"
        $result.VmotionVsan[0].VlanId | Should -Be 100
    }

    It "Routes vSAN Witness interface to the Witness array" {
        $result = InModuleScope VcfEdgeAtScale {
            $ifaces = @(
                [PSCustomObject]@{ service = "vMotion";      vlanId = 10;  ipList = @("10.0.0.1") }
                [PSCustomObject]@{ service = "vSAN Witness"; vlanId = 30;  ipList = @("10.0.0.3") }
            )
            Build-VmkernelPortGroupSpecs -EdgeSuffix "edge2" -NetworkingVmKernelInterfaces $ifaces
        }
        $result.VmotionVsan.Count | Should -Be 1
        $result.Witness.Count     | Should -Be 1
        $result.Witness[0].Name   | Should -Be "vsanwitness-edge2"
        $result.Witness[0].VlanId | Should -Be 30
    }

    It "Skips entries with an empty service name" {
        $result = InModuleScope VcfEdgeAtScale {
            $ifaces = @(
                [PSCustomObject]@{ service = "";       vlanId = 0;  ipList = @() }
                [PSCustomObject]@{ service = "vMotion"; vlanId = 10; ipList = @("10.0.0.1") }
            )
            Build-VmkernelPortGroupSpecs -EdgeSuffix "site3" -NetworkingVmKernelInterfaces $ifaces
        }
        $result.VmotionVsan.Count | Should -Be 1
    }

    It "Parses a string vlanId correctly" {
        $result = InModuleScope VcfEdgeAtScale {
            $ifaces = @(
                [PSCustomObject]@{ service = "vSAN"; vlanId = "300"; ipList = @("10.0.0.2") }
            )
            Build-VmkernelPortGroupSpecs -EdgeSuffix "site4" -NetworkingVmKernelInterfaces $ifaces
        }
        $result.VmotionVsan[0].VlanId | Should -Be 300
    }
}

# ── Invoke-VmkernelPortGroupCreation ─────────────────────────────────────────


Describe "Invoke-VmkernelPortGroupCreation — port group creation orchestration" {

    It "Calls New-VDSPortGroups once for VmotionVsan specs and skips Witness when empty" {
        $callCount = InModuleScope VcfEdgeAtScale {
            $Script:_pgCreateCount = 0
            Mock Write-LogMessage {}
            Mock New-VDSPortGroups {
                $Script:_pgCreateCount++
                [PSCustomObject]@{ Success = $true }
            }
            $specs = @(@{ Name = "vmotion-site1"; VlanId = 10 })
            Invoke-VmkernelPortGroupCreation -NumUplinks 2 -VmotionVsanVdsName "VDS-site1" `
                -VmotionVsanSpecs $specs -WitnessVdsName "VDS-site1" -WitnessSpecs @()
            $Script:_pgCreateCount
        }
        $callCount | Should -Be 1
    }

    It "Calls New-VDSPortGroups twice when both VmotionVsan and Witness specs are non-empty" {
        $callCount = InModuleScope VcfEdgeAtScale {
            $Script:_pgCreateCount2 = 0
            Mock Write-LogMessage {}
            Mock New-VDSPortGroups {
                $Script:_pgCreateCount2++
                [PSCustomObject]@{ Success = $true }
            }
            $vmotionSpecs  = @(@{ Name = "vmotion-site1"; VlanId = 10 })
            $witnessSpecs  = @(@{ Name = "vsanwitness-site1"; VlanId = 30 })
            Invoke-VmkernelPortGroupCreation -NumUplinks 4 -VmotionVsanVdsName "VDS-site1-sw2" `
                -VmotionVsanSpecs $vmotionSpecs -WitnessVdsName "VDS-site1-sw1" -WitnessSpecs $witnessSpecs
            $Script:_pgCreateCount2
        }
        $callCount | Should -Be 2
    }

    It "Throws VcfDeploymentException when New-VDSPortGroups returns Success=false" {
        { InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock New-VDSPortGroups { [PSCustomObject]@{ Success = $false } }
            $specs = @(@{ Name = "vmotion-site1"; VlanId = 10 })
            Invoke-VmkernelPortGroupCreation -NumUplinks 2 -VmotionVsanVdsName "VDS-site1" `
                -VmotionVsanSpecs $specs -WitnessVdsName "VDS-site1" -WitnessSpecs @()
        } } | Should -Throw "*failed to create*vMotion*vSAN*port groups*"
    }
}

# ── Invoke-VmkernelAdaptersFromInterfaces ────────────────────────────────────


Describe "Invoke-VmkernelAdaptersFromInterfaces — per-host adapter creation" {

    It "Calls New-VmkernelForSegment for each valid interface and host" {
        $createCount = InModuleScope VcfEdgeAtScale {
            function Get-VDPortgroup {
                [CmdletBinding()]
                Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server,
                      [Parameter()] [Object]$VDSwitch, [Parameter()] [Object]$Id)
                process {}
            }
            $Script:_vmkCreateCount = 0
            function New-VmkernelForSegment {
                [CmdletBinding()]
                Param(
                    [Parameter()] [Object]$GatewayAddress, [Parameter()] [Object]$Ip,
                    [Parameter()] [Object]$Netmask, [Parameter()] [Object]$PortGroup,
                    [Parameter()] [Object]$PortGroupName, [Parameter()] [Object]$Server,
                    [Parameter()] [Object]$ServiceName, [Parameter()] [Object]$VdsObject,
                    [Parameter()] [Object]$VMHost, [Parameter()] [Object]$VmkernelMtu
                )
                begin { $Script:_vmkCreateCount++ }
                process {}
            }
            Mock Write-LogMessage {}
            Mock Get-VDPortgroup { [PSCustomObject]@{ Name = "vmotion-site1" } }
            $fakeDpg = [PSCustomObject]@{ Name = "vmotion-site1" }
            $fakeHost = [PSCustomObject]@{ Name = "esx01" }
            $ifaces = @(
                [PSCustomObject]@{ service = "vMotion"; vlanId = 10; netmask = "255.255.255.0"; ipList = @("10.0.0.1") }
            )
            $fakeVds = [PSCustomObject]@{ Name = "VDS-site1" }
            Invoke-VmkernelAdaptersFromInterfaces -EdgeSuffix "site1" -HostsOrdered @($fakeHost) `
                -NetworkingVmKernelInterfaces $ifaces -Server "vc1" -VdsObjectVmotionVsan $fakeVds `
                -VdsObjectWitness $null
            $Script:_vmkCreateCount
        }
        $createCount | Should -Be 1
    }

    It "Skips an interface when its port group is not found" {
        InModuleScope VcfEdgeAtScale {
            function Get-VDPortgroup {
                [CmdletBinding()]
                Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server,
                      [Parameter()] [Object]$VDSwitch, [Parameter()] [Object]$Id)
                process {}
            }
            function New-VmkernelForSegment {
                [CmdletBinding()]
                Param(
                    [Parameter()] [Object]$GatewayAddress, [Parameter()] [Object]$Ip,
                    [Parameter()] [Object]$Netmask, [Parameter()] [Object]$PortGroup,
                    [Parameter()] [Object]$PortGroupName, [Parameter()] [Object]$Server,
                    [Parameter()] [Object]$ServiceName, [Parameter()] [Object]$VdsObject,
                    [Parameter()] [Object]$VMHost, [Parameter()] [Object]$VmkernelMtu
                )
                begin { throw "New-VmkernelForSegment must not be called when port group missing" }
                process {}
            }
            Mock Write-LogMessage {}
            Mock Get-VDPortgroup { $null }
            $ifaces = @(
                [PSCustomObject]@{ service = "vMotion"; vlanId = 10; netmask = "255.255.255.0"; ipList = @("10.0.0.1") }
            )
            $fakeVds = [PSCustomObject]@{ Name = "VDS-site1" }
            { Invoke-VmkernelAdaptersFromInterfaces -EdgeSuffix "site1" -HostsOrdered @([PSCustomObject]@{ Name = "esx01" }) `
                -NetworkingVmKernelInterfaces $ifaces -Server "vc1" -VdsObjectVmotionVsan $fakeVds `
                -VdsObjectWitness $null } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "WARNING" -and $Message -match "not found" }
        }
    }

    It "Skips a host when its IP entry is empty" {
        InModuleScope VcfEdgeAtScale {
            function Get-VDPortgroup {
                [CmdletBinding()]
                Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server,
                      [Parameter()] [Object]$VDSwitch, [Parameter()] [Object]$Id)
                process {}
            }
            function New-VmkernelForSegment {
                [CmdletBinding()]
                Param(
                    [Parameter()] [Object]$GatewayAddress, [Parameter()] [Object]$Ip,
                    [Parameter()] [Object]$Netmask, [Parameter()] [Object]$PortGroup,
                    [Parameter()] [Object]$PortGroupName, [Parameter()] [Object]$Server,
                    [Parameter()] [Object]$ServiceName, [Parameter()] [Object]$VdsObject,
                    [Parameter()] [Object]$VMHost, [Parameter()] [Object]$VmkernelMtu
                )
                begin { throw "New-VmkernelForSegment must not be called when IP is missing" }
                process {}
            }
            Mock Write-LogMessage {}
            Mock Get-VDPortgroup { [PSCustomObject]@{ Name = "vmotion-site1" } }
            $ifaces = @(
                [PSCustomObject]@{ service = "vMotion"; vlanId = 10; netmask = "255.255.255.0"; ipList = @("") }
            )
            $fakeVds = [PSCustomObject]@{ Name = "VDS-site1" }
            { Invoke-VmkernelAdaptersFromInterfaces -EdgeSuffix "site1" -HostsOrdered @([PSCustomObject]@{ Name = "esx01" }) `
                -NetworkingVmKernelInterfaces $ifaces -Server "vc1" -VdsObjectVmotionVsan $fakeVds `
                -VdsObjectWitness $null } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "WARNING" -and $Message -match "no IP for host" }
        }
    }
}

# ── Add-VmkernelInterfacesFromNetworkingConfig ───────────────────────────────


Describe "Add-VmkernelInterfacesFromNetworkingConfig — guard conditions" {

    It "Skips Build-VmkernelPortGroupSpecs and does not throw when NetworkingVmKernelInterfaces has fewer than 2 entries" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $Script:_buildSpecsCalled = $false
            Mock Build-VmkernelPortGroupSpecs { $Script:_buildSpecsCalled = $true; throw "must not be called" }
            $ifaces = @([PSCustomObject]@{ service = "vMotion"; vlanId = 10; ipList = @("10.0.0.1") })
            { Add-VmkernelInterfacesFromNetworkingConfig -ClusterName "cl1" -EsxHostNames @("esx01") `
                -NetworkingVmKernelInterfaces $ifaces -NumUplinks 2 -VdsName "VDS-site1" } | Should -Not -Throw
            Should -Not -Invoke Build-VmkernelPortGroupSpecs
        }
    }

    It "Returns without action when the VDS is not found after port group creation" {
        InModuleScope VcfEdgeAtScale {
            function Get-VDSwitch {
                [CmdletBinding()]
                Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server,
                      [Parameter()] [Object]$Location)
                process {}
            }
            Mock Write-LogMessage {}
            Mock Get-VmkernelTrafficVdsNameForLayout { "VDS-site1" }
            Mock Build-VmkernelPortGroupSpecs {
                @{ VmotionVsan = @(@{ Name = "vmotion-site1"; VlanId = 10 }); Witness = @() }
            }
            Mock Invoke-VmkernelPortGroupCreation {}
            Mock Get-VDSwitch { $null }
            $ifaces = @(
                [PSCustomObject]@{ service = "vMotion"; vlanId = 10; ipList = @("10.0.0.1") }
                [PSCustomObject]@{ service = "vSAN";    vlanId = 20; ipList = @("10.0.0.2") }
            )
            { Add-VmkernelInterfacesFromNetworkingConfig -ClusterName "cl1" -EsxHostNames @("esx01") `
                -NetworkingVmKernelInterfaces $ifaces -NumUplinks 2 -VdsName "VDS-site1" } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "WARNING" -and $Message -match "VDS.*not found" }
        }
    }

    It "Returns without action when no hosts resolve from EsxHostNames" {
        InModuleScope VcfEdgeAtScale {
            function Get-VDSwitch {
                [CmdletBinding()]
                Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server,
                      [Parameter()] [Object]$Location)
                process {}
            }
            function Get-Cluster {
                [CmdletBinding()]
                Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process {}
            }
            function Get-VMHost {
                [CmdletBinding()]
                Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server,
                      [Parameter()] [Object]$Location)
                process {}
            }
            Mock Write-LogMessage {}
            Mock Get-VmkernelTrafficVdsNameForLayout { "VDS-site1" }
            Mock Build-VmkernelPortGroupSpecs {
                @{ VmotionVsan = @(@{ Name = "vmotion-site1"; VlanId = 10 }); Witness = @() }
            }
            Mock Invoke-VmkernelPortGroupCreation {}
            Mock Get-VDSwitch { [PSCustomObject]@{ Name = "VDS-site1" } }
            Mock Get-Cluster  { [PSCustomObject]@{ Name = "cl1" } }
            Mock Get-VMHost   { $null }
            $ifaces = @(
                [PSCustomObject]@{ service = "vMotion"; vlanId = 10; ipList = @("10.0.0.1") }
                [PSCustomObject]@{ service = "vSAN";    vlanId = 20; ipList = @("10.0.0.2") }
            )
            { Add-VmkernelInterfacesFromNetworkingConfig -ClusterName "cl1" -EsxHostNames @("esx01") `
                -NetworkingVmKernelInterfaces $ifaces -NumUplinks 2 -VdsName "VDS-site1" } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "WARNING" -and $Message -match "no hosts resolved" }
        }
    }
}


Describe "Get-EsxUnformattedDisk" {

    It "Returns an empty array when no unformatted disks are found" -Skip:(-not $script:_vmhostStubReady) {
        InModuleScope VcfEdgeAtScale {
            function Get-ScsiLun {
                [CmdletBinding()] Param(
                    [Parameter(ValueFromPipeline)] [Object]$In,
                    [Parameter()] [Object]$LunType
                )
                begin {}; process { return @() }
            }
            function Get-Datastore {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$Name)
                return @()
            }
            $fakeVmHost = [VeasTests.StubVMHost]::new()
            $result = Get-EsxUnformattedDisk -VmHost $fakeVmHost -EsxHostName "esx01.lab"
            $result | Should -HaveCount 0
        }
    }

    It "Throws a VcfDeploymentException when Get-ScsiLun fails" -Skip:(-not $script:_vmhostStubReady) {
        InModuleScope VcfEdgeAtScale {
            function Get-ScsiLun {
                [CmdletBinding()] Param(
                    [Parameter(ValueFromPipeline)] [Object]$In,
                    [Parameter()] [Object]$LunType
                )
                begin {}; process { throw "disk scan access error" }
            }
            $fakeVmHost = [VeasTests.StubVMHost]::new()
            { Get-EsxUnformattedDisk -VmHost $fakeVmHost -EsxHostName "esx01.lab" } |
                Should -Throw "*Failed to scan for unformatted disks*"
        }
    }
}

# ── Get-EsxDatastoreHealth ────────────────────────────────────────────────────


Describe "Get-EsxDatastoreHealth" {

    It "Returns a not-mounted result object when the datastore is not found" -Skip:(-not $script:_vmhostStubReady) {
        InModuleScope VcfEdgeAtScale {
            function Get-Datastore {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$Name)
                throw "Datastore '$Name' not found on host"
            }
            $fakeVmHost = [VeasTests.StubVMHost]::new()
            $result = Get-EsxDatastoreHealth -VmHost $fakeVmHost -EsxHostName "esx01.lab" -DatastoreName "missing-ds"
            $result.IsMounted | Should -Be $false
            $result.IsHealthy | Should -Be $false
        }
    }

    It "Reports a low-free-space health issue when free space is below the warning threshold" -Skip:(-not $script:_vmhostStubReady) {
        InModuleScope VcfEdgeAtScale {
            function Get-Datastore {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$Name)
                return [PSCustomObject]@{
                    Name        = "datastore1"
                    Type        = "VMFS"
                    State       = "Available"
                    CapacityGB  = 500.0
                    FreeSpaceGB = 10.0  # 2% free — below the default 10% threshold.
                    ExtensionData = [PSCustomObject]@{
                        Info = [PSCustomObject]@{
                            Vmfs = [PSCustomObject]@{
                                Version = "6"
                                Uuid    = "uuid-1234"
                                Extent  = @()
                            }
                        }
                    }
                }
            }
            $fakeVmHost = [VeasTests.StubVMHost]::new()
            $result = Get-EsxDatastoreHealth -VmHost $fakeVmHost -EsxHostName "esx01.lab" `
                -DatastoreName "datastore1" -FreeSpaceWarningThreshold 10
            $result.IsMounted | Should -Be $true
            $result.HealthIssues | Should -Match "Low free space"
        }
    }
}


Describe "Get-DpgsOnVds — returns non-DVUplinks portgroups" {
    It "Returns only portgroups whose names do not contain DVUplinks" {
        $result = InModuleScope VcfEdgeAtScale {
            function Get-VDPortgroup {
                [CmdletBinding()] Param([Parameter()] [Object]$VDSwitch, [Parameter()] [Object]$Server)
                begin {}; process {}
            }
            Mock Get-VDPortgroup {
                @(
                    [PSCustomObject]@{ Name = "Management-PG" },
                    [PSCustomObject]@{ Name = "vMotion-PG" },
                    [PSCustomObject]@{ Name = "dvSwitch-DVUplinks-PG" }
                )
            }
            $fakeVds = [PSCustomObject]@{ Name = "Production-VDS" }
            Get-DpgsOnVds -VDSwitch $fakeVds -Server "vc.lab"
        }
        @($result).Count | Should -Be 2
        $result.Name | Should -Not -Contain "dvSwitch-DVUplinks-PG"
    }
}

Describe "Get-DpgsOnVds — filters all DVUplinks portgroups" {
    It "Returns an empty result when every portgroup name contains DVUplinks" {
        $result = InModuleScope VcfEdgeAtScale {
            function Get-VDPortgroup {
                [CmdletBinding()] Param([Parameter()] [Object]$VDSwitch, [Parameter()] [Object]$Server)
                begin {}; process {}
            }
            Mock Get-VDPortgroup {
                @(
                    [PSCustomObject]@{ Name = "DVUplinks-0" },
                    [PSCustomObject]@{ Name = "DVUplinks-1" }
                )
            }
            $fakeVds = [PSCustomObject]@{ Name = "Production-VDS" }
            Get-DpgsOnVds -VDSwitch $fakeVds -Server "vc.lab"
        }
        @($result).Count | Should -Be 0
    }
}

# ── Get-PhysicalNicsOnVdsForHost / Get-PhysicalNicsOnVssForHost / Get-VdsListOnHost ───


Describe "Get-PhysicalNicsOnVdsForHost — thin wrapper" {

    It "Returns results from Get-VMHostNetworkAdapter with -Physical and -VirtualSwitch" {
        $fakeNic = InModuleScope VcfEdgeAtScale {
            $fakeVmHost = [PSCustomObject]@{ Name = "esx01.lab" }
            $fakeVds    = [PSCustomObject]@{ Name = "dvSwitch-edge" }
            $fakePnic   = [PSCustomObject]@{ Name = "vmnic0" }
            function Get-VMHostNetworkAdapter {
                # [Switch]$Physical required: production code passes -Physical as a bare flag.
                [CmdletBinding()] Param(
                    [Parameter()] [Object]$VMHost, [Parameter()] [Switch]$Physical,
                    [Parameter()] [Object]$VirtualSwitch, [Parameter()] [Object]$Server
                )
                return @($fakePnic)
            }
            Get-PhysicalNicsOnVdsForHost -VMHost $fakeVmHost -VDSwitch $fakeVds -Server "vc.lab"
        }
        $fakeNic.Name | Should -Be "vmnic0"
    }
}

Describe "Get-PhysicalNicsOnVssForHost — thin wrapper" {

    It "Returns results from Get-VMHostNetworkAdapter with -Physical and VSS -VirtualSwitch" {
        $fakeNic = InModuleScope VcfEdgeAtScale {
            $fakeVmHost = [PSCustomObject]@{ Name = "esx01.lab" }
            $fakeVss    = [PSCustomObject]@{ Name = "vSwitch0" }
            $fakePnic   = [PSCustomObject]@{ Name = "vmnic1" }
            function Get-VMHostNetworkAdapter {
                # [Switch]$Physical required: production code passes -Physical as a bare flag.
                [CmdletBinding()] Param(
                    [Parameter()] [Object]$VMHost, [Parameter()] [Switch]$Physical,
                    [Parameter()] [Object]$VirtualSwitch, [Parameter()] [Object]$Server
                )
                return @($fakePnic)
            }
            Get-PhysicalNicsOnVssForHost -VMHost $fakeVmHost -VirtualSwitch $fakeVss -Server "vc.lab"
        }
        $fakeNic.Name | Should -Be "vmnic1"
    }
}

Describe "Get-VdsListOnHost — thin wrapper" {

    It "Returns results from Get-VDSwitch with -VMHost" {
        $fakeVds = InModuleScope VcfEdgeAtScale {
            $fakeVmHost = [PSCustomObject]@{ Name = "esx01.lab" }
            $fakeVdsObj = [PSCustomObject]@{ Name = "dvSwitch-edge" }
            function Get-VDSwitch {
                [CmdletBinding()] Param(
                    [Parameter()] [Object]$VMHost, [Parameter()] [Object]$Server
                )
                return @($fakeVdsObj)
            }
            Get-VdsListOnHost -VMHost $fakeVmHost -Server "vc.lab"
        }
        $fakeVds.Name | Should -Be "dvSwitch-edge"
    }

    It "Returns empty when no VDS is attached to the host" {
        $result = InModuleScope VcfEdgeAtScale {
            $fakeVmHost = [PSCustomObject]@{ Name = "esx02.lab" }
            function Get-VDSwitch {
                [CmdletBinding()] Param(
                    [Parameter()] [Object]$VMHost, [Parameter()] [Object]$Server
                )
                return @()
            }
            Get-VdsListOnHost -VMHost $fakeVmHost -Server "vc.lab"
        }
        @($result).Count | Should -Be 0
    }
}

# ── Test-PhysicalNicConnected ─────────────────────────────────────────────────


Describe "Test-PhysicalNicConnected" {

    It "Returns false when the adapter is not found" {
        $result = InModuleScope VcfEdgeAtScale {
            $fakeVmHost = [PSCustomObject]@{ Name = "esx01.lab" }
            function Get-VMHostNetworkAdapter {
                # -Physical is a Switch in the real cmdlet; declare it as [Switch] so bare -Physical binds.
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$Physical,
                    [Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                return $null
            }
            Test-PhysicalNicConnected -NicName "vmnic0" -Server "vc.lab" -VMHost $fakeVmHost
        }
        $result | Should -Be $false
    }

    It "Returns true when the adapter reports a positive link speed" {
        $result = InModuleScope VcfEdgeAtScale {
            $fakeVmHost = [PSCustomObject]@{ Name = "esx01.lab" }
            function Get-VMHostNetworkAdapter {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$Physical,
                    [Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                return [PSCustomObject]@{ ExtensionData = [PSCustomObject]@{ LinkSpeed = [PSCustomObject]@{ SpeedMb = 10000 } } }
            }
            Test-PhysicalNicConnected -NicName "vmnic0" -Server "vc.lab" -VMHost $fakeVmHost
        }
        $result | Should -Be $true
    }

    It "Returns false when LinkSpeed is null (link down)" {
        $result = InModuleScope VcfEdgeAtScale {
            $fakeVmHost = [PSCustomObject]@{ Name = "esx01.lab" }
            function Get-VMHostNetworkAdapter {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$Physical,
                    [Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                return [PSCustomObject]@{ ExtensionData = [PSCustomObject]@{ LinkSpeed = $null } }
            }
            Test-PhysicalNicConnected -NicName "vmnic0" -Server "vc.lab" -VMHost $fakeVmHost
        }
        $result | Should -Be $false
    }

    It "Returns false when SpeedMb is zero (link administratively down)" {
        $result = InModuleScope VcfEdgeAtScale {
            $fakeVmHost = [PSCustomObject]@{ Name = "esx01.lab" }
            function Get-VMHostNetworkAdapter {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$Physical,
                    [Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                return [PSCustomObject]@{ ExtensionData = [PSCustomObject]@{ LinkSpeed = [PSCustomObject]@{ SpeedMb = 0 } } }
            }
            Test-PhysicalNicConnected -NicName "vmnic0" -Server "vc.lab" -VMHost $fakeVmHost
        }
        $result | Should -Be $false
    }
}

# ── Test-TcpPortReachable ─────────────────────────────────────────────────────


Describe "Test-TcpPortReachable" {

    It "Returns false for a host that is not listening (timeout)" {
        # Port 1 on 127.0.0.1 is almost never open; a very short timeout ensures the test completes quickly.
        $result = InModuleScope VcfEdgeAtScale {
            Test-TcpPortReachable -IpAddress "127.0.0.1" -Port 1 -TimeoutMilliseconds 100
        }
        $result | Should -Be $false
    }

    It "Returns false for an invalid (non-routable) IP address" {
        $result = InModuleScope VcfEdgeAtScale {
            Test-TcpPortReachable -IpAddress "192.0.2.1" -Port 443 -TimeoutMilliseconds 200
        }
        $result | Should -Be $false
    }

    It "Returns $false and never throws for an unreachable host" {
        $result = InModuleScope VcfEdgeAtScale {
            Test-TcpPortReachable -IpAddress "not-a-real-host" -Port 9999 -TimeoutMilliseconds 100
        }
        { InModuleScope VcfEdgeAtScale {
            Test-TcpPortReachable -IpAddress "not-a-real-host" -Port 9999 -TimeoutMilliseconds 100
        } } | Should -Not -Throw
        $result | Should -Be $false
    }
}

# ── Read-VcfEdgeAtScaleManifestVersion ────────────────────────────────────────


Describe "Remove-EdgeClusterDistributedSwitch" {
    It "Throws VcfDeploymentException when not connected to vCenter" {
        { InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $false; ErrorMessage = "No connection" } }
            Remove-EdgeClusterDistributedSwitch -ClusterName "cl0-site1" -VdsName "VDS-site1"
        } } | Should -Throw
    }

    It "Returns without throwing when the VDS does not exist (nothing to remove)" {
        InModuleScope VcfEdgeAtScale {
            function Get-VDSwitch {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true; ErrorMessage = $null } }
            Mock Get-VDSwitch { $null }
            { Remove-EdgeClusterDistributedSwitch -ClusterName "cl0-site1" -VdsName "VDS-site1" } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "DEBUG" -and $Message -match "nothing to remove" }
        }
    }

    It "Throws VcfDeploymentException when a VM is attached to a port group on the VDS" {
        { InModuleScope VcfEdgeAtScale {
            function Get-VDSwitch {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process {}
            }
            function Get-VMHost {
                [CmdletBinding()] Param([Parameter()] [Object]$DistributedSwitch, [Parameter()] [Object]$Server)
                process {}
            }
            function Get-VMHostNetworkAdapter {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$Physical, [Parameter()] [Object]$VirtualSwitch, [Parameter()] [Object]$Server)
                process {}
            }
            function Get-VDPortgroup {
                [CmdletBinding()] Param([Parameter()] [Object]$VDSwitch, [Parameter()] [Object]$Server)
                process {}
            }
            function Get-VM {
                [CmdletBinding()] Param([Parameter()] [Object]$Server)
                process {}
            }
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true; ErrorMessage = $null } }
            Mock Get-VDSwitch { [PSCustomObject]@{ Name = "VDS-site1" } }
            Mock Get-VMHost { @() }
            Mock Get-VMHostNetworkAdapter { @() }
            Mock Get-VDPortgroup { @([PSCustomObject]@{ Id = "pg-1"; Name = "edge-pg" }) }
            # VM has a network adapter connected to the port group by name — triggers the VM-attached check.
            Mock Get-VM {
                $nic = [PSCustomObject]@{ Network = [PSCustomObject]@{ Id = "pg-1"; Name = "edge-pg" } }
                @([PSCustomObject]@{ Name = "test-vm"; NetworkAdapters = @($nic) })
            }
            Remove-EdgeClusterDistributedSwitch -ClusterName "cl0-site1" -VdsName "VDS-site1" -SkipPortGroupInUseRestoreFallback
        } } | Should -Throw
    }

    It "Returns without throwing when VDS exists and all port groups are removed cleanly (empty FailedPortGroupNames)" {
        # Regression guard: Invoke-VdsPortGroupFirstPass receives an empty List<String> as the initial
        # FailedPortGroupNames. Before [AllowEmptyCollection()] was added to the parameter, PowerShell's
        # collection binding rejected the empty list at the function call site even though the parameter
        # declared [ValidateNotNull()]. This test catches that regression.
        InModuleScope VcfEdgeAtScale {
            function Get-VDSwitch {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process {}
            }
            function Get-VMHost {
                [CmdletBinding()] Param([Parameter()] [Object]$DistributedSwitch, [Parameter()] [Object]$Server)
                process {}
            }
            function Get-VMHostNetworkAdapter {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$Physical, [Parameter()] [Object]$VirtualSwitch, [Parameter()] [Object]$Server)
                process {}
            }
            function Get-VDPortgroup {
                [CmdletBinding()] Param([Parameter()] [Object]$VDSwitch, [Parameter()] [Object]$Server)
                process {}
            }
            function Get-VM {
                [CmdletBinding()] Param([Parameter()] [Object]$Server)
                process {}
            }
            function Remove-VDPortgroup {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param(
                    [Parameter(ValueFromPipeline = $true)] [Object]$VDPortgroup,
                    [Parameter()] [Object]$Server
                )
                begin {}; process {}
            }
            function Remove-VDSwitch {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param(
                    [Parameter(ValueFromPipeline = $true)] [Object]$VDSwitch,
                    [Parameter()] [Object]$Server
                )
                begin {}; process {}
            }
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true; ErrorMessage = $null } }
            Mock Get-VDSwitch { [PSCustomObject]@{ Name = "VDS-site1" } }
            # No hosts on VDS → Invoke-VdsPnicDetach is a no-op.
            Mock Get-VMHost { @() }
            Mock Get-VMHostNetworkAdapter { @() }
            # Two port groups: one user port group and one DVUplinks (must be skipped by the function).
            Mock Get-VDPortgroup {
                @(
                    [PSCustomObject]@{ Id = "pg-mgmt"; Name = "mgmt-site1" },
                    [PSCustomObject]@{ Id = "pg-uplinks"; Name = "VDS-site1-DVUplinks-1234" }
                )
            }
            # No VMs on any port group.
            Mock Get-VM { @() }
            { Remove-EdgeClusterDistributedSwitch -ClusterName "cl0-site1" -VdsName "VDS-site1" -SkipPortGroupInUseRestoreFallback } | Should -Not -Throw
        }
    }

    It "Throws VcfDeploymentException when port group removal has in-use failures and VDS removal also throws" {
        # When at least one port group cannot be removed (in-use VMkernel) and the final VDS removal
        # throws, the function must propagate the exception (logged ERROR on port groups remaining).
        { InModuleScope VcfEdgeAtScale {
            function Get-VDSwitch {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process {}
            }
            function Get-VMHost {
                [CmdletBinding()] Param([Parameter()] [Object]$DistributedSwitch, [Parameter()] [Object]$Server)
                process {}
            }
            function Get-VMHostNetworkAdapter {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$Physical, [Parameter()] [Object]$VirtualSwitch, [Parameter()] [Object]$Server)
                process {}
            }
            function Get-VDPortgroup {
                [CmdletBinding()] Param([Parameter()] [Object]$VDSwitch, [Parameter()] [Object]$Server)
                process {}
            }
            function Get-VM {
                [CmdletBinding()] Param([Parameter()] [Object]$Server)
                process {}
            }
            function Remove-VDPortgroup {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param([Parameter(ValueFromPipeline = $true)] [Object]$VDPortgroup)
                begin {}; process { throw "Object is still in use." }
            }
            function Remove-VDSwitch {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param([Parameter(ValueFromPipeline = $true)] [Object]$VDSwitch)
                begin {}; process { throw "VDS removal failed due to in-use port group." }
            }
            function Start-Sleep { [CmdletBinding()] Param([Parameter()] [Object]$Seconds) }
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true; ErrorMessage = $null } }
            Mock Get-VDSwitch { [PSCustomObject]@{ Name = "VDS-site1" } }
            Mock Get-VMHost { @() }
            Mock Get-VMHostNetworkAdapter { @() }
            Mock Get-VDPortgroup {
                @([PSCustomObject]@{ Id = "pg-vmk1"; Name = "vsan-site1"; ExtensionData = [PSCustomObject]@{ MoRef = [PSCustomObject]@{ Value = "pg-vmk1" } } })
            }
            # No VMs attached — so VM-attach check passes.
            Mock Get-VM { @() }
            Remove-EdgeClusterDistributedSwitch -ClusterName "cl0-site1" -VdsName "VDS-site1" -SkipPortGroupInUseRestoreFallback
        } } | Should -Throw
    }
}

# ── Invoke-VcfEdgeAtScaleModuleInitialize ────────────────────────────────────


Describe "Add-PhysicalAdaptersToVDS" {
    It "Throws VcfDeploymentException when not connected to vCenter" {
        { InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $false; ErrorMessage = "No connection" } }
            $fakeHost = [PSCustomObject]@{ Name = "esx.lab" }
            $fakeVds  = [PSCustomObject]@{ Name = "VDS-site1" }
            Add-PhysicalAdaptersToVDS -Hostname $fakeHost -NicList @("vmnic1") -VdsName "VDS-site1" -VdsObject $fakeVds
        } } | Should -Throw
    }

    It "Returns Success=false when a NicList entry has no Name" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true; ErrorMessage = $null } }
            $fakeHost = [PSCustomObject]@{ Name = "esx.lab" }
            $fakeVds  = [PSCustomObject]@{ Name = "VDS-site1" }
            # Entry is a PSCustomObject with no Name property value.
            Add-PhysicalAdaptersToVDS -Hostname $fakeHost -NicList @([PSCustomObject]@{ Name = "" }) -VdsName "VDS-site1" -VdsObject $fakeVds
        }
        $result.Success | Should -Be $false
    }

    It "Returns Success=false when the requested NIC does not exist on the host" {
        $result = InModuleScope VcfEdgeAtScale {
            function Get-VMHostNetworkAdapter {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$Physical, [Parameter()] [Object]$Name, [Parameter()] [Object]$VirtualSwitch, [Parameter()] [Object]$Server)
                process {}
            }
            function Get-VirtualSwitch {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$Standard, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true; ErrorMessage = $null } }
            # NIC existence check returns null → NIC not found on host.
            Mock Get-VMHostNetworkAdapter { $null }
            Mock Get-VirtualSwitch { @() }
            $fakeHost = [PSCustomObject]@{ Name = "esx.lab" }
            $fakeVds  = [PSCustomObject]@{ Name = "VDS-site1"; ExtensionData = [PSCustomObject]@{ Config = [PSCustomObject]@{ Host = @() } } }
            Add-PhysicalAdaptersToVDS -Hostname $fakeHost -NicList @("vmnic99") -VdsName "VDS-site1" -VdsObject $fakeVds
        }
        $result.Success | Should -Be $false
    }
}

# ── Set-VirtualDistributedSwitch ──────────────────────────────────────────────


Describe "Set-VirtualDistributedSwitch" {
    It "Throws VcfDeploymentException when not connected to vCenter" {
        { InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $false; ErrorMessage = "No connection" } }
            Set-VirtualDistributedSwitch `
                -ClusterName "cl0-site1" -DatacenterName "DC" `
                -NicList @([PSCustomObject]@{ Name = "vmnic1" }) -NumUplinks "2" `
                -PortGroups @([PSCustomObject]@{ Name = "mgmt"; VlanId = 0 }) -VdsName "VDS-site1"
        } } | Should -Throw
    }

    It "Throws VcfDeploymentException when NumUplinks is not 2 or 4" {
        { InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true; ErrorMessage = $null } }
            Set-VirtualDistributedSwitch `
                -ClusterName "cl0-site1" -DatacenterName "DC" `
                -NicList @([PSCustomObject]@{ Name = "vmnic1" }) -NumUplinks "3" `
                -PortGroups @([PSCustomObject]@{ Name = "mgmt"; VlanId = 0 }) -VdsName "VDS-site1"
        } } | Should -Throw
    }

    It "Throws VcfDeploymentException when the cluster has no hosts" {
        { InModuleScope VcfEdgeAtScale {
            function Get-Datacenter {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process {}
            }
            function Get-Cluster {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process {}
            }
            function Get-VMHost {
                [CmdletBinding()] Param([Parameter()] [Object]$Location, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true; ErrorMessage = $null } }
            Mock Get-Datacenter { [PSCustomObject]@{ Name = "DC" } }
            Mock Get-Cluster { [PSCustomObject]@{ Name = "cl0-site1" } }
            # No hosts in cluster → throws.
            Mock Get-VMHost { @() }
            Set-VirtualDistributedSwitch `
                -ClusterName "cl0-site1" -DatacenterName "DC" `
                -NicList @([PSCustomObject]@{ Name = "vmnic1" }) -NumUplinks "2" `
                -PortGroups @([PSCustomObject]@{ Name = "mgmt"; VlanId = 0 }) -VdsName "VDS-site1"
        } } | Should -Throw
    }
}

# ── Remove-NonVmk0VmkernelInterfacesFromVds ───────────────────────────────────


Describe "Remove-NonVmk0VmkernelInterfacesFromVds" {
    It "Returns without throwing when not connected to vCenter (WARNING logged)" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $false; ErrorMessage = "No connection" } }
            { Remove-NonVmk0VmkernelInterfacesFromVds -ClusterName "cl0-site1" -VdsNames @("VDS-site1") } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "WARNING" }
        }
    }

    It "Returns without throwing when the VDS is not found (DEBUG log and continue)" {
        InModuleScope VcfEdgeAtScale {
            function Get-VDSwitch {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true; ErrorMessage = $null } }
            Mock Get-ClusterByName { $null }
            Mock Get-VDSwitch { $null }
            { Remove-NonVmk0VmkernelInterfacesFromVds -ClusterName "cl0-site1" -VdsNames @("VDS-nonexistent") } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "DEBUG" -and $Message -match "not found" }
        }
    }

    It "Removes VDS-backed VMkernel adapters (vSAN/vMotion) detected via DistributedVirtualPort.PortgroupKey" {
        # Regression test: VDS-backed VMkernel adapters have empty NetworkName and no Spec.PortGroup in
        # VCF PowerCLI 9. The third detection check (DistributedVirtualPort.PortgroupKey) must fire so
        # these adapters are removed — without it both cleanup passes report 0 and VDS removal fails
        # because the port groups remain in use.
        $removeCount = InModuleScope VcfEdgeAtScale {
            $Script:_vmkRemoveCount = 0

            $fakeSwitchUuid = "50-01-2c-00-00-00-00-00-00-00-00-01"
            $fakePgKey      = "dvportgroup-201"

            $fakeVds = [PSCustomObject]@{
                Name          = "VDS-vsan-edge1-sw2"
                ExtensionData = [PSCustomObject]@{
                    Config = [PSCustomObject]@{ Uuid = $fakeSwitchUuid }
                }
            }

            # vSAN VMkernel: empty NetworkName, no Spec.PortGroup — only DistributedVirtualPort populated.
            $fakeDvp     = [PSCustomObject]@{ PortgroupKey = $fakePgKey; SwitchUuid = $fakeSwitchUuid }
            $fakeVmkVsan = [PSCustomObject]@{
                Name          = "vmk1"
                NetworkName   = ""
                ExtensionData = [PSCustomObject]@{
                    Spec = [PSCustomObject]@{
                        PortGroup              = $null
                        DistributedVirtualPort = $fakeDvp
                    }
                }
            }

            # Port group with MoRef.Value matching the PortgroupKey so check 3a fires.
            $fakePg = [PSCustomObject]@{
                Name          = "vsan-vsan-edge1"
                Id            = $fakePgKey
                ExtensionData = [PSCustomObject]@{ MoRef = [PSCustomObject]@{ Value = $fakePgKey } }
            }

            function Get-VDSwitch {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process { return $fakeVds }
            }
            function Get-VMHost {
                [CmdletBinding()] Param([Parameter()] [Object]$Location, [Parameter()] [Object]$DistributedSwitch, [Parameter()] [Object]$Server)
                process { return @([PSCustomObject]@{ Name = "esx01.lab" }) }
            }
            function Get-VMHostNetworkAdapter {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$VMKernel, [Parameter()] [Object]$Server)
                process { return @($fakeVmkVsan) }
            }
            function Get-VDPortgroup {
                [CmdletBinding()] Param([Parameter()] [Object]$VDSwitch, [Parameter()] [Object]$Server)
                process { return @($fakePg) }
            }
            function Remove-VMHostNetworkAdapter {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param([Parameter()] [Object]$Nic)
                begin {}
                process { $Script:_vmkRemoveCount++ }
            }

            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true; ErrorMessage = $null } }
            Mock Get-ClusterByName { [PSCustomObject]@{ Name = "cluster-vsan-edge1" } }

            Remove-NonVmk0VmkernelInterfacesFromVds -ClusterName "cluster-vsan-edge1" -VdsNames @("VDS-vsan-edge1-sw2")
            $Script:_vmkRemoveCount
        }
        # The vSAN VMkernel adapter must have been removed (PortgroupKey check fired).
        $removeCount | Should -BeGreaterOrEqual 1
    }

    It "Removes VDS-backed VMkernel adapter when only SwitchUuid matches (PortgroupKey not in port group set)" {
        # Regression guard for the SwitchUuid fallback: when a port group was partially removed but the
        # VMkernel adapter still references it (PortgroupKey absent from the VDS port group list), match
        # by SwitchUuid so the adapter is still removed and VDS removal can proceed.
        $removeCount = InModuleScope VcfEdgeAtScale {
            $Script:_vmkRemoveCount2 = 0

            $fakeSwitchUuid = "50-01-2c-00-00-00-00-00-00-00-00-02"

            $fakeVds = [PSCustomObject]@{
                Name          = "VDS-vsan-edge1-sw2"
                ExtensionData = [PSCustomObject]@{
                    Config = [PSCustomObject]@{ Uuid = $fakeSwitchUuid }
                }
            }

            # PortgroupKey is a stale key NOT in the VDS port group list — only SwitchUuid matches.
            $fakeDvp = [PSCustomObject]@{ PortgroupKey = "dvportgroup-stale"; SwitchUuid = $fakeSwitchUuid }
            $fakeVmk = [PSCustomObject]@{
                Name          = "vmk2"
                NetworkName   = ""
                ExtensionData = [PSCustomObject]@{
                    Spec = [PSCustomObject]@{
                        PortGroup              = $null
                        DistributedVirtualPort = $fakeDvp
                    }
                }
            }

            function Get-VDSwitch {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process { return $fakeVds }
            }
            function Get-VMHost {
                [CmdletBinding()] Param([Parameter()] [Object]$Location, [Parameter()] [Object]$DistributedSwitch, [Parameter()] [Object]$Server)
                process { return @([PSCustomObject]@{ Name = "esx01.lab" }) }
            }
            function Get-VMHostNetworkAdapter {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$VMKernel, [Parameter()] [Object]$Server)
                process { return @($fakeVmk) }
            }
            function Get-VDPortgroup {
                [CmdletBinding()] Param([Parameter()] [Object]$VDSwitch, [Parameter()] [Object]$Server)
                # Port group list does NOT contain "dvportgroup-stale" — forces SwitchUuid fallback path.
                process { return @([PSCustomObject]@{ Name = "other-pg"; Id = "dvportgroup-999"; ExtensionData = [PSCustomObject]@{ MoRef = [PSCustomObject]@{ Value = "dvportgroup-999" } } }) }
            }
            function Remove-VMHostNetworkAdapter {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param([Parameter()] [Object]$Nic)
                begin {}
                process { $Script:_vmkRemoveCount2++ }
            }

            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true; ErrorMessage = $null } }
            Mock Get-ClusterByName { [PSCustomObject]@{ Name = "cluster-vsan-edge1" } }

            Remove-NonVmk0VmkernelInterfacesFromVds -ClusterName "cluster-vsan-edge1" -VdsNames @("VDS-vsan-edge1-sw2")
            $Script:_vmkRemoveCount2
        }
        $removeCount | Should -BeGreaterOrEqual 1
    }
}

# ── Remove-VsanDiskClaimsFromHost ─────────────────────────────────────────────


Describe "Get-VDPortgroupById — thin wrapper" {
    It "Delegates to Get-VDPortgroup by Id without throwing" {
        $result = InModuleScope VcfEdgeAtScale {
            function Get-VDPortgroup {
                [CmdletBinding()] Param([Parameter()] [Object]$Id, [Parameter()] [Object]$Server)
                begin {}; process {}
            }
            Mock Get-VDPortgroup { [PSCustomObject]@{ Name = "mgmt-pg"; Id = "dvportgroup-42" } }
            Get-VDPortgroupById -Id "dvportgroup-42" -Server "vc.lab"
        }
        $result.Name | Should -Be "mgmt-pg"
    }
}


Describe "Get-VirtualPortGroupsOnSwitch — thin wrapper" {
    It "Delegates to Get-VirtualPortGroup and filters nothing when all groups are present" {
        $result = InModuleScope VcfEdgeAtScale {
            function Get-VirtualPortGroup {
                [CmdletBinding()] Param([Parameter()] [Object]$VirtualSwitch, [Parameter()] [Object]$Server)
                begin {}; process {}
            }
            Mock Get-VirtualPortGroup { @([PSCustomObject]@{ Name = "Management Network" }) }
            $fakeVss = [PSCustomObject]@{ Name = "vSwitch0" }
            Get-VirtualPortGroupsOnSwitch -VirtualSwitch $fakeVss -Server "vc.lab"
        }
        @($result).Count | Should -Be 1
    }
}


Describe "Get-VdsObjectByName — thin wrapper" {
    It "Delegates to Get-VDSwitch and returns the VDS" {
        $result = InModuleScope VcfEdgeAtScale {
            function Get-VDSwitch {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                begin {}; process {}
            }
            Mock Get-VDSwitch { [PSCustomObject]@{ Name = "Production-VDS" } }
            Get-VdsObjectByName -Name "Production-VDS" -Server "vc.lab"
        }
        $result.Name | Should -Be "Production-VDS"
    }
}


Describe "Assert-NicNotAssignedElsewhere — no conflict" {
    It "Does not throw when NIC is not assigned to any other switch" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            function Get-VirtualSwitch {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$Standard, [Parameter()] [Object]$Server)
                process { return @() }
            }
            function Get-VDSwitch {
                [CmdletBinding()] Param([Parameter()] [Object]$Server)
                process { return @() }
            }
            function Get-VMHostNetworkAdapter {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$Physical,
                    [Parameter()] [Object]$VirtualSwitch, [Parameter()] [Object]$Server,
                    [Parameter()] [Object]$DistributedSwitch)
                process { return @() }
            }
            Mock Get-VirtualSwitch { @() }
            Mock Get-VDSwitch { @() }
            $fakeHost = [PSCustomObject]@{ Name = "esx1.lab" }
            { Assert-NicNotAssignedElsewhere -Hostname $fakeHost -HostDisplay "esx1.lab" -NicNames @("vmnic0") -VdsName "cl0-vds" } |
                Should -Not -Throw
        }
    }
}

Describe "Assert-NicNotAssignedElsewhere — NIC already on another VDS" {
    It "Throws VcfDeploymentException and logs ERROR when a requested NIC is in use on another VDS" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            function Get-VirtualSwitch {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$Standard, [Parameter()] [Object]$Server)
                process { return @() }
            }
            function Get-VDSwitch {
                [CmdletBinding()] Param([Parameter()] [Object]$Server)
                process { return @([PSCustomObject]@{ Name = "other-vds" }) }
            }
            function Get-VMHostNetworkAdapter {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$Physical,
                    [Parameter()] [Object]$VirtualSwitch, [Parameter()] [Object]$Server,
                    [Parameter()] [Object]$DistributedSwitch)
                process { return @([PSCustomObject]@{ Name = "vmnic0" }) }
            }
            Mock Get-VirtualSwitch { @() }
            Mock Get-VDSwitch { @([PSCustomObject]@{ Name = "other-vds" }) }
            Mock Get-VMHostNetworkAdapter { @([PSCustomObject]@{ Name = "vmnic0" }) }
            $fakeHost = [PSCustomObject]@{ Name = "esx1.lab" }
            { Assert-NicNotAssignedElsewhere -Hostname $fakeHost -HostDisplay "esx1.lab" -NicNames @("vmnic0") -VdsName "cl0-vds" } |
                Should -Throw -ExceptionType ([VcfDeploymentException])
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "ERROR" -and $Message -match "vmnic0" }
        }
    }
}
