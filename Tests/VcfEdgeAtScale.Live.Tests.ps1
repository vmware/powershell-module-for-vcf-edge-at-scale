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
# Live integration tests for VcfEdgeAtScale.
#
# These tests require a real vCenter and are NOT run by default. Enable them via:
#   ./Tests/Run-Tests.ps1 -Live
#
# Required environment variables:
#   VCF_TEST_VCENTER   — vCenter FQDN or IP
#   VCF_TEST_USER      — username (default: administrator@vsphere.local)
#   VCF_TEST_PASSWORD  — password
#
# Optional environment variables:
#   VCF_TEST_CLUSTER         — cluster name for vSAN / cluster-level tests
#   VCF_TEST_ALLOW_WRITES    — set to any non-empty value to enable stateful write tests (Tier D)
#
# All Describe blocks are tagged [Tag "Live"] so -Filter "*" -Tag "Live" isolates them.
# When VCF_TEST_VCENTER is not set, every test is skipped gracefully.
#
# Test tiers:
#   Tier A — Network/connectivity (least invasive, no vCenter state required)
#   Tier B — vCenter reads  (read-only, requires connection)
#   Tier C — vSAN diagnostics and health report functions (read-only)
#   Tier D — Stateful vCenter writes (gated by VCF_TEST_ALLOW_WRITES)

BeforeAll {
    $moduleRoot = Join-Path $PSScriptRoot ".."
    $manifestPath = Join-Path $moduleRoot "VcfEdgeAtScale.psd1"
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "Module manifest not found at $manifestPath."
    }
    $null = Remove-Module -Name "VcfEdgeAtScale" -Force -ErrorAction SilentlyContinue
    $script:liveModule = Import-Module $manifestPath -Force -PassThru -ErrorAction Stop

    $script:vCenter  = $env:VCF_TEST_VCENTER
    $script:vcUser   = if ([String]::IsNullOrWhiteSpace($env:VCF_TEST_USER)) { "administrator@vsphere.local" } else { $env:VCF_TEST_USER }
    $script:vcPass   = $env:VCF_TEST_PASSWORD
    $script:cluster  = $env:VCF_TEST_CLUSTER
    $script:liveMode = -not [String]::IsNullOrWhiteSpace($script:vCenter) -and -not [String]::IsNullOrWhiteSpace($script:vcPass)

    if ($script:liveMode) {
        InModuleScope VcfEdgeAtScale {
            $Script:LogOnly = "enabled"
        }
        # Connect to vCenter for all Tier B-D tests.
        $securePass = ConvertTo-SecureString -String $script:vcPass -AsPlainText -Force
        $cred       = [System.Management.Automation.PSCredential]::new($script:vcUser, $securePass)
        try {
            InModuleScope VcfEdgeAtScale -ArgumentList $script:vCenter, $cred {
                Connect-Vcenter -ServerName $args[0] -ServerCredential $args[1] -ServerType "vCenter"
            }
        } catch {
            Write-Warning "BeforeAll: Could not connect to vCenter '$($script:vCenter)': $($_.Exception.Message). Some live tests will skip."
            $script:liveMode = $false
        }
    } else {
        Write-Warning "Live tests: VCF_TEST_VCENTER or VCF_TEST_PASSWORD not set. All live tests will be skipped."
    }
}

AfterAll {
    if ($script:liveMode) {
        try {
            InModuleScope VcfEdgeAtScale {
                Disconnect-Vcenter -AllServers -Silence -ErrorAction SilentlyContinue
            }
        } catch {}
    }
}

# ---------------------------------------------------------------------------
# Tier A — Network / connectivity (no vCenter session required)
# ---------------------------------------------------------------------------

Describe "Test-TcpPortReachable — live" -Tag "Live" {
    It "Returns true when connecting to vCenter on port 443" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because "VCF_TEST_VCENTER or VCF_TEST_PASSWORD not set" }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $script:vCenter {
            Test-TcpPortReachable -IpAddress $args[0] -Port 443 -TimeoutMilliseconds 5000
        }
        $result | Should -Be $true
    }

    It "Returns false for a TCP port that is not open" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because "VCF_TEST_VCENTER or VCF_TEST_PASSWORD not set" }
        # Port 19999 is unlikely to be open on any vCenter.
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $script:vCenter {
            Test-TcpPortReachable -IpAddress $args[0] -Port 19999 -TimeoutMilliseconds 1500
        }
        $result | Should -Be $false
    }
}

Describe "Test-VcenterAndEsxReachability — live" -Tag "Live" {
    It "Does not throw when vCenter is reachable" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because "VCF_TEST_VCENTER or VCF_TEST_PASSWORD not set" }
        {
            InModuleScope VcfEdgeAtScale -ArgumentList $script:vCenter {
                Mock Write-LogMessage {}
                Test-VcenterAndEsxReachability -VcenterName $args[0]
            }
        } | Should -Not -Throw
    }
}

Describe "Connect-Vcenter and Disconnect-Vcenter — live" -Tag "Live" {
    It "Establishes a vCenter session visible in DefaultViServers" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because "VCF_TEST_VCENTER or VCF_TEST_PASSWORD not set" }
        $connected = $Global:DefaultViServers | Where-Object { $_.Name -eq $script:vCenter -and $_.IsConnected }
        $connected | Should -Not -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
# Tier B — vCenter reads (read-only, requires connection)
# ---------------------------------------------------------------------------

Describe "Get-VmHostsInCluster — live" -Tag "Live" {
    It "Returns at least one host for the test cluster" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because "VCF_TEST_VCENTER or VCF_TEST_PASSWORD not set" }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        $hosts = InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster {
            Mock Write-LogMessage {}
            Get-VmHostsInCluster -ClusterName $args[0]
        }
        $hosts | Should -Not -BeNullOrEmpty
    }
}

Describe "Get-VsanClusterTriggeredAlarms — live" -Tag "Live" {
    It "Returns an array (possibly empty) for the test cluster" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because "VCF_TEST_VCENTER or VCF_TEST_PASSWORD not set" }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        $alarms = InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster {
            Mock Write-LogMessage {}
            Get-VsanClusterTriggeredAlarms -ClusterName $args[0]
        }
        $alarms | Should -Not -Be $null
    }
}

Describe "Get-VsanDatastoreForCluster — live" -Tag "Live" {
    It "Returns a datastore object or null without throwing" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because "VCF_TEST_VCENTER or VCF_TEST_PASSWORD not set" }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        $hostIds = InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster {
            Mock Write-LogMessage {}
            (Get-VmHostsInCluster -ClusterName $args[0]) | ForEach-Object { $_.Id }
        }
        {
            InModuleScope VcfEdgeAtScale -ArgumentList (, $hostIds) {
                Mock Write-LogMessage {}
                Get-VsanDatastoreForCluster -ClusterHostIds $args[0]
            }
        } | Should -Not -Throw
    }
}

Describe "Get-EsxDatastoreHealth — live" -Tag "Live" {
    It "Returns a result object without throwing" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because "VCF_TEST_VCENTER or VCF_TEST_PASSWORD not set" }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        {
            InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster {
                Mock Write-LogMessage {}
                $hosts = Get-VmHostsInCluster -ClusterName $args[0]
                if ($hosts) {
                    Get-EsxDatastoreHealth -VMHost ($hosts | Select-Object -First 1) | Out-Null
                }
            }
        } | Should -Not -Throw
    }
}

Describe "Find-SupervisorByName — live" -Tag "Live" {
    It "Returns null without throwing when supervisor name does not exist" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because "VCF_TEST_VCENTER or VCF_TEST_PASSWORD not set" }
        {
            InModuleScope VcfEdgeAtScale -ArgumentList $script:vcUser, $script:vcPass {
                Mock Write-LogMessage {}
                $session = New-VCenterRestApiSession -VcenterUser $args[0] -VcenterInsecurePassword $args[1]
                if ($session.Success) {
                    Find-SupervisorByName -SupervisorName "veas-live-test-nonexistent-supervisor-12345" -SessionHeaders $session.SessionHeaders | Out-Null
                }
            }
        } | Should -Not -Throw
    }
}

Describe "Get-SupervisorUpgradeInfo and Get-SupervisorUpgradeStatus — live" -Tag "Live" {
    It "Runs without throwing when supervisor is not found" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because "VCF_TEST_VCENTER or VCF_TEST_PASSWORD not set" }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        {
            InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster {
                Mock Write-LogMessage {}
                Get-SupervisorUpgradeInfo -ClusterName $args[0] -ErrorAction SilentlyContinue
            }
        } | Should -Not -Throw
    }
}

Describe "Get-ContentLibraryId — live" -Tag "Live" {
    It "Returns null when no content library matches the name" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because "VCF_TEST_VCENTER or VCF_TEST_PASSWORD not set" }
        $result = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Get-ContentLibraryId -ContentLibraryName "veas-live-test-nonexistent-cl-99999"
        }
        $result | Should -BeNullOrEmpty
    }
}

Describe "Get-StoragePolicyId — live" -Tag "Live" {
    It "Returns null when no storage policy matches the name" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because "VCF_TEST_VCENTER or VCF_TEST_PASSWORD not set" }
        $result = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Get-StoragePolicyId -StoragePolicyName "veas-live-test-nonexistent-policy-99999"
        }
        $result | Should -BeNullOrEmpty
    }
}

Describe "Test-VsanAutomaticRebalanceAtThreshold — live" -Tag "Live" {
    It "Returns a boolean without throwing for the test cluster" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because "VCF_TEST_VCENTER or VCF_TEST_PASSWORD not set" }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster, $script:vCenter {
            Mock Write-LogMessage {}
            Test-VsanAutomaticRebalanceAtThreshold -ClusterName $args[0] -Server $args[1]
        }
        $result | Should -BeOfType [bool]
    }
}

# ---------------------------------------------------------------------------
# Tier C — vSAN diagnostics and health report functions (read-only)
# ---------------------------------------------------------------------------

Describe "Write-VsanClusterHealthReport — live" -Tag "Live" {
    It "Runs without throwing for the test cluster" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because "VCF_TEST_VCENTER or VCF_TEST_PASSWORD not set" }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        {
            InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster {
                Mock Write-LogMessage {}
                Write-VsanClusterHealthReport -ClusterName $args[0] -ErrorAction SilentlyContinue
            }
        } | Should -Not -Throw
    }
}

Describe "Write-SupervisorHealthReport — live" -Tag "Live" {
    It "Runs without throwing for the test cluster" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because "VCF_TEST_VCENTER or VCF_TEST_PASSWORD not set" }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        {
            InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster {
                Mock Write-LogMessage {}
                Write-SupervisorHealthReport -ClusterName $args[0] -ErrorAction SilentlyContinue
            }
        } | Should -Not -Throw
    }
}

Describe "Write-VsanHealthFailureDebugInfo — live" -Tag "Live" {
    It "Runs without throwing for health_red context" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because "VCF_TEST_VCENTER or VCF_TEST_PASSWORD not set" }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        {
            InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster {
                Mock Write-LogMessage {}
                Write-VsanHealthFailureDebugInfo -ClusterName $args[0] -Context "health_red"
            }
        } | Should -Not -Throw
    }
}

Describe "Test-VcenterAndEsxReachability live — all hosts in cluster" -Tag "Live" {
    It "Does not throw when all cluster hosts are reachable" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because "VCF_TEST_VCENTER or VCF_TEST_PASSWORD not set" }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        {
            InModuleScope VcfEdgeAtScale -ArgumentList $script:vCenter, $script:cluster {
                Mock Write-LogMessage {}
                $esxHosts = (Get-VmHostsInCluster -ClusterName $args[1]) | ForEach-Object { $_.Name }
                Test-VcenterAndEsxReachability -VcenterName $args[0] -EsxHosts $esxHosts
            }
        } | Should -Not -Throw
    }
}

# ---------------------------------------------------------------------------
# Tier D — Stateful vCenter writes (opt-in via VCF_TEST_ALLOW_WRITES)
# ---------------------------------------------------------------------------

Describe "Set-VsanLabSilentChecksIfRequested — live write" -Tag "Live" {
    It "Runs without throwing for test cluster (no-op when lab silent checks not requested)" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because "VCF_TEST_VCENTER or VCF_TEST_PASSWORD not set" }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        if ([String]::IsNullOrWhiteSpace($env:VCF_TEST_ALLOW_WRITES)) { Set-ItResult -Skipped -Because "VCF_TEST_ALLOW_WRITES not set" }
        {
            InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster {
                Mock Write-LogMessage {}
                # Call without -EnableLabSilentChecks so it is a no-op.
                Set-VsanLabSilentChecksIfRequested -ClusterName $args[0]
            }
        } | Should -Not -Throw
    }
}

Describe "Enable-VsanHealthAlarms — live write" -Tag "Live" {
    It "Runs without throwing for test cluster" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because "VCF_TEST_VCENTER or VCF_TEST_PASSWORD not set" }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        if ([String]::IsNullOrWhiteSpace($env:VCF_TEST_ALLOW_WRITES)) { Set-ItResult -Skipped -Because "VCF_TEST_ALLOW_WRITES not set" }
        {
            InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster {
                Mock Write-LogMessage {}
                Enable-VsanHealthAlarms -ClusterName $args[0]
            }
        } | Should -Not -Throw
    }
}

Describe "Set-VclsRetreatModeForCluster — live write" -Tag "Live" {
    It "Runs without throwing (no state change: RetreatMode not requested)" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because "VCF_TEST_VCENTER or VCF_TEST_PASSWORD not set" }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        if ([String]::IsNullOrWhiteSpace($env:VCF_TEST_ALLOW_WRITES)) { Set-ItResult -Skipped -Because "VCF_TEST_ALLOW_WRITES not set" }
        {
            InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster {
                Mock Write-LogMessage {}
                Set-VclsRetreatModeForCluster -ClusterName $args[0] -RetreatMode $false
            }
        } | Should -Not -Throw
    }
}

# ---------------------------------------------------------------------------
# Tier B additions — remaining read-only functions
# ---------------------------------------------------------------------------

Describe "Get-SupervisorUpgradeInfo and Get-SupervisorUpgradeStatus — live ClusterId" -Tag "Live" {
    It "Get-SupervisorUpgradeStatus returns without throwing for a non-existent ClusterId" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because "VCF_TEST_VCENTER or VCF_TEST_PASSWORD not set" }
        {
            InModuleScope VcfEdgeAtScale {
                Mock Write-LogMessage {}
                Get-SupervisorUpgradeStatus -ClusterId "domain-cXXX-veas-live-nonexistent" -ErrorAction SilentlyContinue
            }
        } | Should -Not -Throw
    }
}

Describe "Get-EsxDatastoreInfo — live" -Tag "Live" {
    It "Returns a result without throwing for the first host in the cluster" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because "VCF_TEST_VCENTER or VCF_TEST_PASSWORD not set" }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        {
            InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster {
                Mock Write-LogMessage {}
                $firstHost = (Get-VmHostsInCluster -ClusterName $args[0]) | Select-Object -First 1
                if ($firstHost) {
                    Get-EsxDatastoreInfo -EsxHostName $firstHost.Name | Out-Null
                }
            }
        } | Should -Not -Throw
    }
}

# ---------------------------------------------------------------------------
# Tier D additions — stateful tag creation functions
# ---------------------------------------------------------------------------

Describe "Test-TagCatalogCategory — live write" -Tag "Live" {
    It "Runs without throwing (creates category if absent)" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because "VCF_TEST_VCENTER or VCF_TEST_PASSWORD not set" }
        if ([String]::IsNullOrWhiteSpace($env:VCF_TEST_ALLOW_WRITES)) { Set-ItResult -Skipped -Because "VCF_TEST_ALLOW_WRITES not set" }
        {
            InModuleScope VcfEdgeAtScale {
                Mock Write-LogMessage {}
                Test-TagCatalogCategory -TagCatalog "veas-live-test-catalog"
            }
        } | Should -Not -Throw
    }
}

Describe "Test-Tag — live write" -Tag "Live" {
    It "Runs without throwing (creates tag if absent)" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because "VCF_TEST_VCENTER or VCF_TEST_PASSWORD not set" }
        if ([String]::IsNullOrWhiteSpace($env:VCF_TEST_ALLOW_WRITES)) { Set-ItResult -Skipped -Because "VCF_TEST_ALLOW_WRITES not set" }
        {
            InModuleScope VcfEdgeAtScale {
                Mock Write-LogMessage {}
                Test-Tag -TagCatalog "veas-live-test-catalog" -TagName "veas-live-test-tag"
            }
        } | Should -Not -Throw
    }
}

Describe "Set-VMHostConnectedState — live write" -Tag "Live" {
    It "Runs without throwing for first host in cluster (no-op when already connected)" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because "VCF_TEST_VCENTER or VCF_TEST_PASSWORD not set" }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        if ([String]::IsNullOrWhiteSpace($env:VCF_TEST_ALLOW_WRITES)) { Set-ItResult -Skipped -Because "VCF_TEST_ALLOW_WRITES not set" }
        {
            InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster {
                Mock Write-LogMessage {}
                $firstHost = (Get-VmHostsInCluster -ClusterName $args[0]) | Select-Object -First 1
                if ($firstHost) {
                    Set-VMHostConnectedState -VMHost $firstHost
                }
            }
        } | Should -Not -Throw
    }
}

# ---------------------------------------------------------------------------
# Tier B additions — vSAN storage and networking reads
# ---------------------------------------------------------------------------

Describe "Get-VsanOsaDiskGroupsOnHost — live" -Tag "Live" {
    It "Returns without throwing for the first host in the cluster" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because "VCF_TEST_VCENTER or VCF_TEST_PASSWORD not set" }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        {
            InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster {
                Mock Write-LogMessage {}
                $firstHost = (Get-VmHostsInCluster -ClusterName $args[0]) | Select-Object -First 1
                if ($firstHost) {
                    Get-VsanOsaDiskGroupsOnHost -VMHost $firstHost | Out-Null
                }
            }
        } | Should -Not -Throw
    }
}

Describe "Get-VsanClusterHealthSummaryViaView — live" -Tag "Live" {
    It "Returns without throwing for the test cluster" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because "VCF_TEST_VCENTER or VCF_TEST_PASSWORD not set" }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        {
            InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster {
                Mock Write-LogMessage {}
                Get-VsanClusterHealthSummaryViaView -ClusterName $args[0] | Out-Null
            }
        } | Should -Not -Throw
    }
}

Describe "Get-VsanOsaEligibleDisksFromCluster — live" -Tag "Live" {
    It "Returns without throwing for the test cluster" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because "VCF_TEST_VCENTER or VCF_TEST_PASSWORD not set" }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        {
            InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster {
                Mock Write-LogMessage {}
                $hosts = Get-VmHostsInCluster -ClusterName $args[0]
                if ($hosts) {
                    Get-VsanOsaEligibleDisksFromCluster -ClusterName $args[0] -ClusterHosts @($hosts) | Out-Null
                }
            }
        } | Should -Not -Throw
    }
}

Describe "Get-EsxUnformattedDisk — live" -Tag "Live" {
    It "Returns without throwing for the first host in the cluster" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because "VCF_TEST_VCENTER or VCF_TEST_PASSWORD not set" }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        {
            InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster {
                Mock Write-LogMessage {}
                $firstHost = (Get-VmHostsInCluster -ClusterName $args[0]) | Select-Object -First 1
                if ($firstHost) {
                    Get-EsxUnformattedDisk -EsxHostName $firstHost.Name -VmHost $firstHost -Silence | Out-Null
                }
            }
        } | Should -Not -Throw
    }
}

Describe "Get-VdsListOnHost — live" -Tag "Live" {
    It "Returns without throwing for the first host in the cluster" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because "VCF_TEST_VCENTER or VCF_TEST_PASSWORD not set" }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        {
            InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster {
                Mock Write-LogMessage {}
                $firstHost = (Get-VmHostsInCluster -ClusterName $args[0]) | Select-Object -First 1
                if ($firstHost) {
                    Get-VdsListOnHost -VMHost $firstHost | Out-Null
                }
            }
        } | Should -Not -Throw
    }
}

Describe "Get-VirtualSwitchesOnHost — live" -Tag "Live" {
    It "Returns without throwing for the first host in the cluster" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because "VCF_TEST_VCENTER or VCF_TEST_PASSWORD not set" }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        {
            InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster {
                Mock Write-LogMessage {}
                $firstHost = (Get-VmHostsInCluster -ClusterName $args[0]) | Select-Object -First 1
                if ($firstHost) {
                    Get-VirtualSwitchesOnHost -VMHost $firstHost | Out-Null
                }
            }
        } | Should -Not -Throw
    }
}

Describe "Test-VsanOsaDiskGroupPresentViaEsxcli — live" -Tag "Live" {
    It "Returns a boolean without throwing for the first host in the cluster" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because "VCF_TEST_VCENTER or VCF_TEST_PASSWORD not set" }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster {
            Mock Write-LogMessage {}
            $firstHost = (Get-VmHostsInCluster -ClusterName $args[0]) | Select-Object -First 1
            if ($firstHost) {
                Test-VsanOsaDiskGroupPresentViaEsxcli -VMHost $firstHost
            } else {
                $true
            }
        }
        $result | Should -BeOfType [bool]
    }
}

Describe "Find-Datastore — live" -Tag "Live" {
    It "Does not throw an untyped exception when the datastore does not exist" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because "VCF_TEST_VCENTER or VCF_TEST_PASSWORD not set" }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        {
            InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster {
                Mock Write-LogMessage {}
                $firstHost = (Get-VmHostsInCluster -ClusterName $args[0]) | Select-Object -First 1
                if ($firstHost) {
                    try {
                        Find-Datastore -DatastoreName "veas-live-test-nonexistent-datastore-99999" -EsxHostName $firstHost.Name | Out-Null
                    } catch [VcfDeploymentException] {
                        # Expected on production hosts with no unformatted disks — typed exception means correct error handling.
                    }
                }
            }
        } | Should -Not -Throw
    }
}

Describe "Test-ContentLibraryBySubscriptionUri — live" -Tag "Live" {
    It "Returns false when no content library matches the subscription URI" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because "VCF_TEST_VCENTER or VCF_TEST_PASSWORD not set" }
        $result = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Test-ContentLibraryBySubscriptionUri -SubscriptionUri "https://veas-live-test-nonexistent.example.com/lib.json"
        }
        $result | Should -Be $false
    }
}

# ---------------------------------------------------------------------------
# Tier D additions — vSAN cluster and HA write operations
# ---------------------------------------------------------------------------

Describe "Invoke-AbandonHciWorkflowIfInProgress — live write" -Tag "Live" {
    It "Runs without throwing for the test cluster (no-op when workflow already skipped)" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because "VCF_TEST_VCENTER or VCF_TEST_PASSWORD not set" }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        if ([String]::IsNullOrWhiteSpace($env:VCF_TEST_ALLOW_WRITES)) { Set-ItResult -Skipped -Because "VCF_TEST_ALLOW_WRITES not set" }
        {
            InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster {
                Mock Write-LogMessage {}
                Invoke-AbandonHciWorkflowIfInProgress -ClusterName $args[0]
            }
        } | Should -Not -Throw
    }
}

Describe "Invoke-VsanClusterConfigReapply — live write" -Tag "Live" {
    It "Runs without throwing for the test cluster" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because "VCF_TEST_VCENTER or VCF_TEST_PASSWORD not set" }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        if ([String]::IsNullOrWhiteSpace($env:VCF_TEST_ALLOW_WRITES)) { Set-ItResult -Skipped -Because "VCF_TEST_ALLOW_WRITES not set" }
        {
            InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster {
                Mock Write-LogMessage {}
                Invoke-VsanClusterConfigReapply -ClusterName $args[0] | Out-Null
            }
        } | Should -Not -Throw
    }
}

Describe "Invoke-ReconfigureClusterHA — live write" -Tag "Live" {
    It "Runs without throwing for the test cluster (re-applies HA/DRS; no state change when already configured)" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because "VCF_TEST_VCENTER or VCF_TEST_PASSWORD not set" }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        if ([String]::IsNullOrWhiteSpace($env:VCF_TEST_ALLOW_WRITES)) { Set-ItResult -Skipped -Because "VCF_TEST_ALLOW_WRITES not set" }
        {
            InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster {
                Mock Write-LogMessage {}
                Invoke-ReconfigureClusterHA -ClusterName $args[0] -DelaySeconds 0
            }
        } | Should -Not -Throw
    }
}

Describe "Set-VsanDomNetworkSchedulerThrottleOnCluster — live write" -Tag "Live" {
    It "Runs without throwing for the test cluster (idempotent: already-set is success)" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because "VCF_TEST_VCENTER or VCF_TEST_PASSWORD not set" }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        if ([String]::IsNullOrWhiteSpace($env:VCF_TEST_ALLOW_WRITES)) { Set-ItResult -Skipped -Because "VCF_TEST_ALLOW_WRITES not set" }
        {
            InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster, $script:vCenter {
                Mock Write-LogMessage {}
                Set-VsanDomNetworkSchedulerThrottleOnCluster -ClusterName $args[0] -Server $args[1] | Out-Null
            }
        } | Should -Not -Throw
    }
}

Describe "Enable-VsanAutomaticRebalance — live write" -Tag "Live" {
    It "Runs without throwing for the test cluster" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because "VCF_TEST_VCENTER or VCF_TEST_PASSWORD not set" }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        if ([String]::IsNullOrWhiteSpace($env:VCF_TEST_ALLOW_WRITES)) { Set-ItResult -Skipped -Because "VCF_TEST_ALLOW_WRITES not set" }
        {
            InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster {
                Mock Write-LogMessage {}
                Enable-VsanAutomaticRebalance -ClusterName $args[0] | Out-Null
            }
        } | Should -Not -Throw
    }
}

Describe "Enable-VsanAutomaticDiskClaimIfSupported — live write" -Tag "Live" {
    It "Runs without throwing for the test cluster" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because "VCF_TEST_VCENTER or VCF_TEST_PASSWORD not set" }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        if ([String]::IsNullOrWhiteSpace($env:VCF_TEST_ALLOW_WRITES)) { Set-ItResult -Skipped -Because "VCF_TEST_ALLOW_WRITES not set" }
        {
            InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster {
                Mock Write-LogMessage {}
                Enable-VsanAutomaticDiskClaimIfSupported -ClusterName $args[0] | Out-Null
            }
        } | Should -Not -Throw
    }
}

Describe "Test-PhysicalNicConnected — live" -Tag "Live" {
    It "Returns a boolean for the first physical NIC on the first cluster host" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because "VCF_TEST_VCENTER or VCF_TEST_PASSWORD not set" }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster, $script:vCenter {
            Mock Write-LogMessage {}
            $hosts = Get-VmHostsInCluster -ClusterName $args[0] -Server $args[1]
            if ($null -ne $hosts -and @($hosts).Count -gt 0) {
                $nics = Get-VMHostNetworkAdapter -VMHost $hosts[0] -Physical -Server $args[1] -ErrorAction SilentlyContinue
                if ($null -ne $nics -and @($nics).Count -gt 0) {
                    $result = Test-PhysicalNicConnected -NicName $nics[0].Name -Server $args[1] -VMHost $hosts[0]
                    $result | Should -BeOfType [bool]
                }
            }
        }
    }
}

Describe "Get-VsanEsaEligibleDisksFromCluster — live" -Tag "Live" {
    It "Runs without throwing for the test cluster (result may be empty on OSA clusters)" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because "VCF_TEST_VCENTER or VCF_TEST_PASSWORD not set" }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        {
            InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster, $script:vCenter {
                Mock Write-LogMessage {}
                $hosts = Get-VmHostsInCluster -ClusterName $args[0] -Server $args[1]
                if ($null -ne $hosts -and @($hosts).Count -gt 0) {
                    Get-VsanEsaEligibleDisksFromCluster -ClusterName $args[0] -ClusterHosts $hosts | Out-Null
                }
            }
        } | Should -Not -Throw
    }
}

Describe "Set-VsanDomNetworkSchedulerThrottleOnHost — live write" -Tag "Live" {
    It "Runs without throwing for the first host in the test cluster (idempotent)" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because "VCF_TEST_VCENTER or VCF_TEST_PASSWORD not set" }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        if ([String]::IsNullOrWhiteSpace($env:VCF_TEST_ALLOW_WRITES)) { Set-ItResult -Skipped -Because "VCF_TEST_ALLOW_WRITES not set" }
        {
            InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster, $script:vCenter {
                Mock Write-LogMessage {}
                $hosts = Get-VmHostsInCluster -ClusterName $args[0] -Server $args[1]
                if ($null -ne $hosts -and @($hosts).Count -gt 0) {
                    Set-VsanDomNetworkSchedulerThrottleOnHost -VMHost $hosts[0] -Server $args[1] | Out-Null
                }
            }
        } | Should -Not -Throw
    }
}

Describe "Invoke-VsanClusterHealthRetestAfterDeployment — live" -Tag "Live" {
    It "Runs without throwing for the test cluster (non-fatal; skips if Test-VsanClusterHealth unavailable)" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because "VCF_TEST_VCENTER or VCF_TEST_PASSWORD not set" }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        {
            InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster, $script:vCenter {
                Mock Write-LogMessage {}
                Invoke-VsanClusterHealthRetestAfterDeployment -ClusterName $args[0] -Server $args[1]
            }
        } | Should -Not -Throw
    }
}
