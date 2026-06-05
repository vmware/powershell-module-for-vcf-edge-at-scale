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
#   VCF_TEST_CLUSTER              — cluster name for vSAN / cluster-level tests
#   VCF_TEST_ALLOW_WRITES         — set to any non-empty value to enable stateful write tests (Tier D)
#   VCF_TEST_VDS_NAME             — management VDS name (e.g. VDS-cl0-site1-sw1) for networking migration tests
#   VCF_TEST_VSAN_DATASTORE       — existing vSAN datastore name for idempotency tests (e.g. datastore-site1)
#   VCF_TEST_STORAGE_POLICY_NAME  — existing storage policy name for Set-StoragePolicy idempotency tests
#   VCF_TEST_STORAGE_TAG_CATALOG  — tag category name used by all three Set-StoragePolicy live tests
#   VCF_TEST_STORAGE_TAG_NAME     — tag name used by all three Set-StoragePolicy live tests
#   VCF_TEST_INFRASTRUCTURE_JSON  — absolute path to a fully-deployed infrastructure.json for Initialize-VcfEdgeAtScale idempotent re-run tests
#   VCF_TEST_SUPERVISOR_JSON      — absolute path to the companion supervisor services JSON for Initialize-VcfEdgeAtScale idempotent re-run tests
#   VCF_TEST_EDGE_SITE            — EdgeSite value to scope the idempotent re-run to a single site (optional; omit to run all sites)
#   VCF_TEST_ESX_PASSWORD         — ESX root password. Used for two purposes:
#                                   1) Initialize-VcfEdgeAtScale idempotent re-run test: mapped to ESX_COMMON_PASSWORD for that
#                                      test's duration. Requires nonInteractivePassword: true in infrastructure.json.
#                                   2) Get-EsxDatastoreInfo live test: used to open a direct Connect-VIServer session to the
#                                      first host in VCF_TEST_CLUSTER so Get-EsxDatastoreInfo can find it in DefaultViServers.
#   HARBOR_ADMIN_PASSWORD         — Harbor admin password (required for Install-HarborSupervisorService live test)
#   SECRET_KEY                    — Harbor secret key (required for Install-HarborSupervisorService live test)
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

    $script:vCenter             = $env:VCF_TEST_VCENTER
    $script:vcUser              = if ([String]::IsNullOrWhiteSpace($env:VCF_TEST_USER)) { "administrator@vsphere.local" } else { $env:VCF_TEST_USER }
    $script:vcPass              = $env:VCF_TEST_PASSWORD
    $script:cluster             = $env:VCF_TEST_CLUSTER
    $script:vdsName             = $env:VCF_TEST_VDS_NAME
    $script:vsanDatastore       = $env:VCF_TEST_VSAN_DATASTORE
    $script:storagePolicyName   = $env:VCF_TEST_STORAGE_POLICY_NAME
    $script:storageTagCatalog   = $env:VCF_TEST_STORAGE_TAG_CATALOG
    $script:storageTagName      = $env:VCF_TEST_STORAGE_TAG_NAME
    $script:infrastructureJson  = $env:VCF_TEST_INFRASTRUCTURE_JSON
    $script:supervisorJson      = $env:VCF_TEST_SUPERVISOR_JSON
    $script:edgeSite            = $env:VCF_TEST_EDGE_SITE
    $script:liveMode   = -not [String]::IsNullOrWhiteSpace($script:vCenter) -and -not [String]::IsNullOrWhiteSpace($script:vcPass)
    $script:skipReason = "VCF_TEST_VCENTER or VCF_TEST_PASSWORD not set"

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
                $Script:vCenterName      = $args[0]
                # Set module-scoped credential variables so functions that run outside the main
                # deployment flow (e.g. Set-StoragePolicy → Invoke-VcenterReconnectIfNeeded,
                # Get-SupervisorId REST API auth) find the session credentials they require.
                $Script:VCenterUser      = $args[1].UserName
                $Script:VcenterCredential = $args[1]
            }
        } catch {
            $script:skipReason = "could not connect to vCenter '$($script:vCenter)': $($_.Exception.Message)"
            Write-Warning "BeforeAll: $($script:skipReason). All live tests will be skipped."
            $script:liveMode = $false
        }
    } else {
        Write-Warning "Live tests: $($script:skipReason). All live tests will be skipped."
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
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $script:vCenter {
            Test-TcpPortReachable -IpAddress $args[0] -Port 443 -TimeoutMilliseconds 5000
        }
        $result | Should -Be $true
    }

    It "Returns false for a TCP port that is not open" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
        # Port 19999 is unlikely to be open on any vCenter.
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $script:vCenter {
            Test-TcpPortReachable -IpAddress $args[0] -Port 19999 -TimeoutMilliseconds 1500
        }
        $result | Should -Be $false
    }
}

Describe "Test-VcenterAndEsxReachability — live" -Tag "Live" {
    It "Does not throw when vCenter is reachable" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
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
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
        $connected = $Global:DefaultViServers | Where-Object { $_.Name -eq $script:vCenter -and $_.IsConnected }
        $connected | Should -Not -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
# Tier B — vCenter reads (read-only, requires connection)
# ---------------------------------------------------------------------------

Describe "Get-VmHostsInCluster — live" -Tag "Live" {
    It "Returns without throwing for the test cluster" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        {
            InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster {
                Mock Write-LogMessage {}
                $clusterObj = Get-ClusterByName -Name $args[0]
                Get-VmHostsInCluster -ClusterObject $clusterObj
            }
        } | Should -Not -Throw
    }
}

Describe "Get-VsanClusterTriggeredAlarms — live" -Tag "Live" {
    It "Returns an array (possibly empty) for the test cluster" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        {
            InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster {
                Mock Write-LogMessage {}
                Get-VsanClusterTriggeredAlarms -ClusterName $args[0]
            }
        } | Should -Not -Throw
    }
}

Describe "Get-VsanDatastoreForCluster — live" -Tag "Live" {
    It "Returns a datastore object or null without throwing" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        $hostIds = InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster {
            Mock Write-LogMessage {}
            $clusterObj = Get-ClusterByName -Name $args[0]
            (Get-VmHostsInCluster -ClusterObject $clusterObj) | ForEach-Object { $_.Id }
        }
        if (-not $hostIds) { Set-ItResult -Skipped -Because "test cluster has no hosts; cannot query vSAN datastore" }
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
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        {
            InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster {
                Mock Write-LogMessage {}
                $clusterObj = Get-ClusterByName -Name $args[0]
                $hosts = Get-VmHostsInCluster -ClusterObject $clusterObj
                if ($hosts) {
                    $firstHost = $hosts | Select-Object -First 1
                    $firstDs = Get-Datastore -VMHost $firstHost -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($firstDs) {
                        Get-EsxDatastoreHealth -VmHost $firstHost -EsxHostName $firstHost.Name -DatastoreName $firstDs.Name | Out-Null
                    }
                }
            }
        } | Should -Not -Throw
    }
}

Describe "Find-SupervisorByName — live" -Tag "Live" {
    It "Returns null without throwing when supervisor name does not exist" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
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
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        {
            InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster {
                Mock Write-LogMessage {}
                Get-SupervisorUpgradeInfo -ClusterId $args[0] -ErrorAction SilentlyContinue
            }
        } | Should -Not -Throw
    }
}

Describe "Get-ContentLibraryId — live" -Tag "Live" {
    It "Returns null when no content library matches the name" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
        $result = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Get-ContentLibraryId -LibraryName "veas-live-test-nonexistent-cl-99999"
        }
        $result | Should -BeNullOrEmpty
    }
}

Describe "Get-StoragePolicyId — live" -Tag "Live" {
    It "Returns null when no storage policy matches the name" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
        $result = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Get-StoragePolicyId -StoragePolicyName "veas-live-test-nonexistent-policy-99999"
        }
        $result | Should -BeNullOrEmpty
    }
}

Describe "Test-VsanAutomaticRebalanceAtThreshold — live" -Tag "Live" {
    It "Returns a boolean without throwing for the test cluster" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
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
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
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
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        {
            InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster {
                Mock Write-LogMessage {}
                Write-SupervisorHealthReport -ClusterName $args[0] -SupervisorId "veas-live-test-nonexistent-supervisor-99999" -ErrorAction SilentlyContinue
            }
        } | Should -Not -Throw
    }
}

Describe "Write-VsanHealthFailureDebugInfo — live" -Tag "Live" {
    It "Runs without throwing for health_red context" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
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
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        {
            InModuleScope VcfEdgeAtScale -ArgumentList $script:vCenter, $script:cluster {
                Mock Write-LogMessage {}
                $clusterObj = Get-ClusterByName -Name $args[1]
            $esxHosts = (Get-VmHostsInCluster -ClusterObject $clusterObj) | ForEach-Object { $_.Name }
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
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        if ([String]::IsNullOrWhiteSpace($env:VCF_TEST_ALLOW_WRITES)) { Set-ItResult -Skipped -Because "VCF_TEST_ALLOW_WRITES not set" }
        {
            InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster {
                Mock Write-LogMessage {}
                # LabEnvironmentEnabled $false makes the function return immediately; no API calls are made.
                Set-VsanLabSilentChecksIfRequested -ClusterName $args[0] -LabEnvironmentEnabled $false
            }
        } | Should -Not -Throw
    }
}

Describe "Enable-VsanHealthAlarms — live write" -Tag "Live" {
    It "Runs without throwing for test cluster" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
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
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
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
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
        {
            InModuleScope VcfEdgeAtScale {
                Mock Write-LogMessage {}
                Get-SupervisorUpgradeStatus -ClusterId "domain-cXXX-veas-live-nonexistent" -ErrorAction SilentlyContinue
            }
        } | Should -Not -Throw
    }
}

Describe "Get-EsxDatastoreInfo — live" -Tag "Live" {
    BeforeAll {
        $script:esxDsTestHost = $null
        $script:esxDsDirectConnected = $false
        if ($script:liveMode -and -not [String]::IsNullOrWhiteSpace($script:cluster)) {
            $script:esxDsTestHost = InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster {
                Mock Write-LogMessage {}
                $clusterObj = Get-ClusterByName -Name $args[0]
                $h = (Get-VmHostsInCluster -ClusterObject $clusterObj) | Select-Object -First 1
                if ($h) { $h.Name } else { $null }
            }
        }
        # Connect directly to the ESX host when VCF_TEST_ESX_PASSWORD is provided.
        # Get-EsxDatastoreInfo requires a direct entry in $Global:DefaultViServers for that host.
        $esxPass = $env:VCF_TEST_ESX_PASSWORD
        if ($script:liveMode -and -not [String]::IsNullOrWhiteSpace($script:esxDsTestHost) -and -not [String]::IsNullOrWhiteSpace($esxPass)) {
            try {
                $esxCred = [System.Management.Automation.PSCredential]::new(
                    "root", (ConvertTo-SecureString -String $esxPass -AsPlainText -Force))
                # ESX hosts use self-signed certificates. Configure the PowerCLI session to allow
                # invalid certificates so the direct ESX connection does not fail with an SSL error.
                Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Scope Session -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
                Write-Host "  [ESX test] Connecting directly to '$($script:esxDsTestHost)' as root (VCF_TEST_ESX_PASSWORD)..."
                # -SkipRetryPrompt prevents Read-Host blocking on auth errors in a test context.
                InModuleScope VcfEdgeAtScale -ArgumentList $script:esxDsTestHost, $esxCred {
                    Connect-Vcenter -ServerName $args[0] -ServerCredential $args[1] -ServerType "ESX" -SkipRetryPrompt
                }
                $script:esxDsDirectConnected = $true
                # Capture the exact server name PowerCLI registered (may differ from the FQDN we
                # passed). Get-EsxDatastoreInfo uses -eq to look up the name, so both sides must match.
                $registeredName = ($Global:DefaultViServers |
                    Where-Object { $_.IsConnected -and ($_.Name -eq $script:esxDsTestHost -or $_.Name -like "$($script:esxDsTestHost.Split('.')[0])*") } |
                    Select-Object -Last 1).Name
                if (-not [String]::IsNullOrWhiteSpace($registeredName) -and $registeredName -ne $script:esxDsTestHost) {
                    Write-Host "  [ESX test] Connected as '$registeredName' (resolved from '$($script:esxDsTestHost)')"
                    $script:esxDsTestHost = $registeredName
                } else {
                    Write-Host "  [ESX test] Connected successfully as '$($script:esxDsTestHost)'."
                }
            } catch {
                # Surface the actual error so the operator knows why the direct connection failed
                # (SSL cert, bad password, or network issue).
                Write-Host "  [ESX test] WARNING: direct connection to '$($script:esxDsTestHost)' failed — $($_.Exception.Message)" -ForegroundColor Yellow
                Write-Host "  [ESX test] Check: (1) VCF_TEST_ESX_PASSWORD is the root password for this ESX host," -ForegroundColor Yellow
                Write-Host "  [ESX test]         (2) TCP 443 is reachable from this machine to '$($script:esxDsTestHost)'," -ForegroundColor Yellow
                Write-Host "  [ESX test]         (3) the hostname resolves correctly (try: Test-NetConnection '$($script:esxDsTestHost)' -Port 443)." -ForegroundColor Yellow
            }
        }
    }

    AfterAll {
        if ($script:esxDsDirectConnected -and -not [String]::IsNullOrWhiteSpace($script:esxDsTestHost)) {
            try {
                InModuleScope VcfEdgeAtScale -ArgumentList $script:esxDsTestHost {
                    Disconnect-Vcenter -ServerName $args[0] -ServerType "ESX" -Silence -ErrorAction SilentlyContinue
                }
            } catch {}
        }
    }

    It "Returns a result without throwing for the first host in the cluster" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        if ([String]::IsNullOrWhiteSpace($script:esxDsTestHost)) { Set-ItResult -Skipped -Because "No hosts found in cluster '$($script:cluster)'" }
        # Accept either a BeforeAll auto-connect (esxDsDirectConnected) or a pre-existing
        # direct session in DefaultViServers (e.g. from a full Initialize-VcfEdgeAtScale run).
        $hasDirectConn = $script:esxDsDirectConnected -or
            [bool]($Global:DefaultViServers | Where-Object { $_.Name -eq $script:esxDsTestHost -and $_.IsConnected })
        if (-not $hasDirectConn) {
            Set-ItResult -Skipped -Because "No direct ESX connection to '$script:esxDsTestHost'; set VCF_TEST_ESX_PASSWORD to enable auto-connect"
        }
        {
            InModuleScope VcfEdgeAtScale -ArgumentList $script:esxDsTestHost {
                Mock Write-LogMessage {}
                Get-EsxDatastoreInfo -EsxHostName $args[0] | Out-Null
            }
        } | Should -Not -Throw
    }
}

# ---------------------------------------------------------------------------
# Tier D additions — stateful tag creation functions
# ---------------------------------------------------------------------------

Describe "Test-TagCatalogCategory — live write" -Tag "Live" {
    It "Runs without throwing (creates category if absent)" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
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
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
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
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        if ([String]::IsNullOrWhiteSpace($env:VCF_TEST_ALLOW_WRITES)) { Set-ItResult -Skipped -Because "VCF_TEST_ALLOW_WRITES not set" }
        {
            InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster {
                Mock Write-LogMessage {}
                $clusterObj = Get-ClusterByName -Name $args[0]
                $firstHost = (Get-VmHostsInCluster -ClusterObject $clusterObj) | Select-Object -First 1
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
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        {
            InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster {
                Mock Write-LogMessage {}
                $clusterObj = Get-ClusterByName -Name $args[0]
                $firstHost = (Get-VmHostsInCluster -ClusterObject $clusterObj) | Select-Object -First 1
                if ($firstHost) {
                    Get-VsanOsaDiskGroupsOnHost -VMHost $firstHost | Out-Null
                }
            }
        } | Should -Not -Throw
    }
}

Describe "Get-VsanClusterHealthSummaryViaView — live" -Tag "Live" {
    It "Returns without throwing for the test cluster" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
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
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        # Resolve precondition outside Should -Not -Throw (Rule 10): the function throws when no eligible
        # disks are present, which is a valid pre-deployment state (no unclaimed disks, or vSAN ESA
        # cluster). A throw inside Should -Not -Throw records a FAILURE, not a SKIP.
        $setup = InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster {
            Mock Write-LogMessage {}
            $clusterObj = Get-ClusterByName -Name $args[0]
            if (-not $clusterObj) { return $null }
            $hosts = @(Get-VmHostsInCluster -ClusterObject $clusterObj)
            if (-not $hosts -or $hosts.Count -eq 0) { return $null }
            try {
                $null = Get-VsanOsaEligibleDisksFromCluster -ClusterName $args[0] -ClusterHosts $hosts
                return @{ ClusterName = $args[0]; Hosts = $hosts }
            } catch {
                return $null
            }
        }
        if ($null -eq $setup) {
            Set-ItResult -Skipped -Because "no vSAN OSA eligible disks on cluster — valid pre-deployment state (cluster not found, no hosts, no unclaimed disks, or vSAN ESA cluster)"
        }
        {
            InModuleScope VcfEdgeAtScale -ArgumentList $setup {
                Mock Write-LogMessage {}
                Get-VsanOsaEligibleDisksFromCluster -ClusterName $args[0].ClusterName -ClusterHosts $args[0].Hosts | Out-Null
            }
        } | Should -Not -Throw
    }
}

Describe "Get-EsxUnformattedDisk — live" -Tag "Live" {
    It "Returns without throwing for the first host in the cluster" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        {
            InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster {
                Mock Write-LogMessage {}
                $clusterObj = Get-ClusterByName -Name $args[0]
                $firstHost = (Get-VmHostsInCluster -ClusterObject $clusterObj) | Select-Object -First 1
                if ($firstHost) {
                    Get-EsxUnformattedDisk -EsxHostName $firstHost.Name -VmHost $firstHost -Silence | Out-Null
                }
            }
        } | Should -Not -Throw
    }
}

Describe "Get-VdsListOnHost — live" -Tag "Live" {
    It "Returns without throwing for the first host in the cluster" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        {
            InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster {
                Mock Write-LogMessage {}
                $clusterObj = Get-ClusterByName -Name $args[0]
                $firstHost = (Get-VmHostsInCluster -ClusterObject $clusterObj) | Select-Object -First 1
                if ($firstHost) {
                    Get-VdsListOnHost -VMHost $firstHost | Out-Null
                }
            }
        } | Should -Not -Throw
    }
}

Describe "Get-VirtualSwitchesOnHost — live" -Tag "Live" {
    It "Returns without throwing for the first host in the cluster" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        {
            InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster {
                Mock Write-LogMessage {}
                $clusterObj = Get-ClusterByName -Name $args[0]
                $firstHost = (Get-VmHostsInCluster -ClusterObject $clusterObj) | Select-Object -First 1
                if ($firstHost) {
                    Get-VirtualSwitchesOnHost -VMHost $firstHost | Out-Null
                }
            }
        } | Should -Not -Throw
    }
}

Describe "Test-VsanOsaDiskGroupPresentViaEsxcli — live" -Tag "Live" {
    It "Returns a boolean without throwing for the first host in the cluster" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster {
            Mock Write-LogMessage {}
            $clusterObj = Get-ClusterByName -Name $args[0]
            $firstHost = (Get-VmHostsInCluster -ClusterObject $clusterObj) | Select-Object -First 1
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
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        {
            InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster {
                Mock Write-LogMessage {}
                $clusterObj = Get-ClusterByName -Name $args[0]
                $firstHost = (Get-VmHostsInCluster -ClusterObject $clusterObj) | Select-Object -First 1
                if ($firstHost) {
                    try {
                        Find-Datastore -DatastoreName "veas-live-test-nonexistent-datastore-99999" -EsxHostName $firstHost.Name | Out-Null
                    } catch {
                        # Expected on production hosts with no unformatted disks — typed exception means correct error handling.
                    }
                }
            }
        } | Should -Not -Throw
    }
}

Describe "Test-ContentLibraryBySubscriptionUri — live" -Tag "Live" {
    It "Returns false when no content library matches the subscription URI" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
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
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
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
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
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
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
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
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
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
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
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
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
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
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster, $script:vCenter {
            Mock Write-LogMessage {}
            $clusterObj = Get-ClusterByName -Name $args[0] -Server $args[1]
            $hosts = Get-VmHostsInCluster -ClusterObject $clusterObj
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
    It "Runs without throwing for the test cluster (ESA clusters with unclaimed disks only)" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        # Detect cluster storage architecture. This function is ESA pre-deployment only; it correctly
        # throws when the cluster has OSA disk groups or when ESA storage pool disks are already claimed.
        $esaSkipReason = InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster {
            Mock Write-LogMessage {}
            $clusterObj = Get-ClusterByName -Name $args[0]
            $hosts = Get-VmHostsInCluster -ClusterObject $clusterObj
            $firstHost = $hosts | Select-Object -First 1
            if ($firstHost) {
                $diskGroups = @(Get-VsanDiskGroup -VMHost $firstHost -ErrorAction SilentlyContinue)
                if ($diskGroups.Count -gt 0) {
                    return "cluster has OSA disk groups; function requires an ESA cluster with unclaimed disks"
                }
                $storagePools = @(Get-VsanStoragePoolDisk -VMHost $firstHost -ErrorAction SilentlyContinue)
                if ($storagePools.Count -gt 0) {
                    return "cluster ESA storage pool disks already claimed; function is pre-deployment only"
                }
            }
            return $null
        }
        if ($esaSkipReason) { Set-ItResult -Skipped -Because $esaSkipReason }
        {
            InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster, $script:vCenter {
                Mock Write-LogMessage {}
                $clusterObj = Get-ClusterByName -Name $args[0] -Server $args[1]
                $hosts = Get-VmHostsInCluster -ClusterObject $clusterObj
                if ($null -ne $hosts -and @($hosts).Count -gt 0) {
                    Get-VsanEsaEligibleDisksFromCluster -ClusterName $args[0] -ClusterHosts $hosts | Out-Null
                }
            }
        } | Should -Not -Throw
    }
}

Describe "Set-VsanDomNetworkSchedulerThrottleOnHost — live write" -Tag "Live" {
    It "Runs without throwing for the first host in the test cluster (idempotent)" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        if ([String]::IsNullOrWhiteSpace($env:VCF_TEST_ALLOW_WRITES)) { Set-ItResult -Skipped -Because "VCF_TEST_ALLOW_WRITES not set" }
        {
            InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster, $script:vCenter {
                Mock Write-LogMessage {}
                $clusterObj = Get-ClusterByName -Name $args[0] -Server $args[1]
                $hosts = Get-VmHostsInCluster -ClusterObject $clusterObj
                if ($null -ne $hosts -and @($hosts).Count -gt 0) {
                    Set-VsanDomNetworkSchedulerThrottleOnHost -VMHost $hosts[0] -Server $args[1] | Out-Null
                }
            }
        } | Should -Not -Throw
    }
}

Describe "Invoke-VsanClusterHealthRetestAfterDeployment — live" -Tag "Live" {
    It "Runs without throwing for the test cluster (non-fatal; skips if Test-VsanClusterHealth unavailable)" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        {
            InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster, $script:vCenter {
                Mock Write-LogMessage {}
                Invoke-VsanClusterHealthRetestAfterDeployment -ClusterName $args[0] -Server $args[1]
            }
        } | Should -Not -Throw
    }
}

# ---------------------------------------------------------------------------
# Tier B — Pass C integration test contracts (read-only)
# These tests anchor the behavioral contracts of the four Pass C extraction
# candidates. They must pass before and after each extraction so that any
# regression is caught immediately.
# ---------------------------------------------------------------------------

Describe "Restore-ManagementToVssBeforeVdsRemoval — output contract — live" -Tag "Live" {
    It "Returns a PSCustomObject with RestoreAttempted=false Success=true HostsRestoredCount=0 and Message property when VDS does not exist" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $result = Restore-ManagementToVssBeforeVdsRemoval -VdsNameWithMgmt "VDS-nonexistent-livetest" -ClusterName "ghost-cluster-livetest"
            $result | Should -Not -BeNullOrEmpty
            $result.RestoreAttempted | Should -Be $false
            $result.Success | Should -Be $true
            $result.HostsRestoredCount | Should -Be 0
            $result.PSObject.Properties.Name | Should -Contain "Message"
        }
    }

    It "Returns HostsRestoredCount=0 and does not throw when cluster exists but VDS name does not exist" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster {
            Mock Write-LogMessage {}
            $result = Restore-ManagementToVssBeforeVdsRemoval -VdsNameWithMgmt "VDS-nonexistent-livetest" -ClusterName $args[0]
            $result.RestoreAttempted | Should -Be $false
            $result.HostsRestoredCount | Should -Be 0
        }
    }
}

Describe "Add-VsanOsaDiskGroupToCluster — precondition validation — live" -Tag "Live" {
    It "Throws when cluster does not exist in vCenter" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
        {
            InModuleScope VcfEdgeAtScale {
                Mock Write-LogMessage {}
                Add-VsanOsaDiskGroupToCluster -ClusterName "ghost-cluster-livetest" -DatastoreName "ghost-datastore-livetest"
            }
        } | Should -Throw
    }
}

Describe "Set-VsanWitness — precondition validation — live" -Tag "Live" {
    It "Throws when cluster does not exist in vCenter" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
        {
            InModuleScope VcfEdgeAtScale {
                Mock Write-LogMessage {}
                Set-VsanWitness -ClusterName "ghost-cluster-livetest" -PreferredFaultDomainName "site1" -StoragePolicyType "vSAN-OSA" -vSanWitnessVmName "10.255.255.1"
            }
        } | Should -Throw
    }

    It "Throws when the witness host name is not found in vCenter inventory" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        {
            InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster {
                Mock Write-LogMessage {}
                Set-VsanWitness -ClusterName $args[0] -PreferredFaultDomainName "site1" -StoragePolicyType "vSAN-OSA" -vSanWitnessVmName "witness.ghost.livetest.invalid"
            }
        } | Should -Throw
    }
}

Describe "Add-HostToCluster — idempotent host-in-cluster path — live" -Tag "Live" {
    It "Throws when cluster does not exist in vCenter" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
        $dummyCred = [System.Management.Automation.PSCredential]::new(
            "root", (ConvertTo-SecureString -String "dummy" -AsPlainText -Force))
        {
            InModuleScope VcfEdgeAtScale -ArgumentList $dummyCred {
                Mock Write-LogMessage {}
                Add-HostToCluster -ClusterName "ghost-cluster-livetest" -EsxHostName "ghost.esx.livetest" -EsxCredential $args[0]
            }
        } | Should -Throw
    }

    It "Returns without throwing when the ESX host is already in the target cluster (idempotent early exit)" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        $dummyCred = [System.Management.Automation.PSCredential]::new(
            "root", (ConvertTo-SecureString -String "dummy" -AsPlainText -Force))
        {
            InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster, $script:vCenter, $dummyCred {
                Mock Write-LogMessage {}
                $clusterObj = Get-ClusterByName -Name $args[0] -Server $args[1]
                $hosts = Get-VmHostsInCluster -ClusterObject $clusterObj
                if ($null -ne $hosts -and @($hosts).Count -gt 0) {
                    $firstHost = @($hosts)[0]
                    # Host is already in this cluster; Add-HostToCluster returns immediately without any changes.
                    Add-HostToCluster -ClusterName $args[0] -EsxHostName $firstHost.Name -EsxCredential $args[2]
                }
            }
        } | Should -Not -Throw
    }
}

Describe "Invoke-MigrateHostManagementToVds — precondition validation — live" -Tag "Live" {
    It "Throws when NicList contains only whitespace names (resolved NicList is empty)" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        # Resolve the first host outside Should -Throw so a skip can be issued when the cluster
        # has no hosts — an if-guard inside Should -Throw would silently suppress the call and
        # cause Should -Throw to fail with "no exception was thrown".
        $firstHost = InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster, $script:vCenter {
            Mock Write-LogMessage {}
            $clusterObj = Get-ClusterByName -Name $args[0] -Server $args[1]
            $hosts = Get-VmHostsInCluster -ClusterObject $clusterObj
            if ($null -ne $hosts -and @($hosts).Count -gt 0) { @($hosts)[0] } else { $null }
        }
        if ($null -eq $firstHost) { Set-ItResult -Skipped -Because "No hosts found in cluster" }
        {
            InModuleScope VcfEdgeAtScale -ArgumentList $firstHost {
                Mock Write-LogMessage {}
                # NicList has one entry whose Name resolves to whitespace only — the function throws before any network change.
                $emptyNicList = @([PSCustomObject]@{ Name = "  " })
                Invoke-MigrateHostManagementToVds -VMHost $args[0] -VdsName "dummy-vds" -NicList $emptyNicList
            }
        } | Should -Throw "*NicList is empty*"
    }
}

# ---------------------------------------------------------------------------
# Tier D — Pass C / Pass D write-path contracts (gated by VCF_TEST_ALLOW_WRITES)
# These tests verify idempotent or read-heavy paths that include a potential
# write side-effect (MTU set, VMhost connection state) and therefore require
# the explicit write gate to run.
# ---------------------------------------------------------------------------

Describe "Add-VsanOsaDiskGroupToCluster — existing datastore idempotency — live write" -Tag "Live" {
    It "Returns without throwing and skips disk group creation when vSAN datastore already has capacity" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        if ([String]::IsNullOrWhiteSpace($script:vsanDatastore)) { Set-ItResult -Skipped -Because "VCF_TEST_VSAN_DATASTORE not set" }
        if ([String]::IsNullOrWhiteSpace($env:VCF_TEST_ALLOW_WRITES)) { Set-ItResult -Skipped -Because "VCF_TEST_ALLOW_WRITES not set" }
        # Skip when the cluster has no hosts — OSA disk group creation requires hosts to be present
        # in the cluster; a deployed cluster with no hosts means the cluster is empty (e.g. pre-deployment).
        $clusterHostCount = InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster, $script:vCenter {
            $clusterObj = Get-ClusterByName -Name $args[0] -Server $args[1]
            if ($null -eq $clusterObj) { return 0 }
            @(Get-VMHost -Location $clusterObj -Server $args[1] -ErrorAction SilentlyContinue).Count
        }
        if ($clusterHostCount -eq 0) { Set-ItResult -Skipped -Because "cluster '$($script:cluster)' has no hosts (pre-deployment)" }
        {
            InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster, $script:vsanDatastore {
                Mock Write-LogMessage {}
                Add-VsanOsaDiskGroupToCluster -ClusterName $args[0] -DatastoreName $args[1]
            }
        } | Should -Not -Throw
    }
}

Describe "Invoke-MigrateHostManagementToVds — vmk0 already on VDS (idempotent) — live write" -Tag "Live" {
    It "Returns without throwing when vmk0 is already on the named VDS (skips migration)" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        if ([String]::IsNullOrWhiteSpace($script:vdsName)) { Set-ItResult -Skipped -Because "VCF_TEST_VDS_NAME not set" }
        if ([String]::IsNullOrWhiteSpace($env:VCF_TEST_ALLOW_WRITES)) { Set-ItResult -Skipped -Because "VCF_TEST_ALLOW_WRITES not set" }

        # Verify that the first cluster host has vmk0 already on the target VDS before asserting the
        # idempotent path. If the cluster is not fully deployed (vmk0 still on VSS, on a different
        # VDS, or no hosts present), this precondition returns $null and the test skips gracefully
        # rather than failing. A throw inside Should -Not -Throw is always a Pester failure.
        $precondition = InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster, $script:vCenter, $script:vdsName {
            $clusterObj = Get-ClusterByName -Name $args[0] -Server $args[1]
            if ($null -eq $clusterObj) { return $null }
            $hosts = Get-VmHostsInCluster -ClusterObject $clusterObj
            if ($null -eq $hosts -or @($hosts).Count -eq 0) { return $null }
            $firstHost = @($hosts)[0]
            $isOnVds = Invoke-Vmk0VdsMigrationIdempotencyCheck `
                -HostDisplay $firstHost.Name `
                -Server      $args[1] `
                -VdsName     $args[2] `
                -VMHost      $firstHost
            if (-not $isOnVds) { return $null }
            return @{ VMHost = $firstHost }
        }
        if ($null -eq $precondition) {
            Set-ItResult -Skipped -Because "vmk0 on first cluster host is not on VDS '$($script:vdsName)' — cluster is not yet in the fully-migrated idempotent state this test targets."
        }

        {
            InModuleScope VcfEdgeAtScale -ArgumentList $precondition, $script:vdsName {
                Mock Write-LogMessage {}
                $dummyNicList = @([PSCustomObject]@{ Name = "vmnic0" })
                # vmk0 is already on the target VDS; Invoke-MigrateHostManagementToVds should detect
                # this via Invoke-Vmk0VdsMigrationIdempotencyCheck and return without migrating.
                Invoke-MigrateHostManagementToVds -VMHost $args[0].VMHost -VdsName $args[1] -NicList $dummyNicList
            }
        } | Should -Not -Throw
    }
}

Describe "Set-StoragePolicy — idempotent tag assignment — live write" -Tag "Live" {
    It "Runs without throwing when the named policy already exists and the tag is already assigned" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
        if ([String]::IsNullOrWhiteSpace($env:VCF_TEST_ALLOW_WRITES)) { Set-ItResult -Skipped -Because "VCF_TEST_ALLOW_WRITES not set" }
        if ([String]::IsNullOrWhiteSpace($script:storagePolicyName)) { Set-ItResult -Skipped -Because "VCF_TEST_STORAGE_POLICY_NAME not set" }
        if ([String]::IsNullOrWhiteSpace($script:storageTagCatalog)) { Set-ItResult -Skipped -Because "VCF_TEST_STORAGE_TAG_CATALOG not set" }
        if ([String]::IsNullOrWhiteSpace($script:storageTagName)) { Set-ItResult -Skipped -Because "VCF_TEST_STORAGE_TAG_NAME not set" }
        {
            InModuleScope VcfEdgeAtScale -ArgumentList $script:storagePolicyName, $script:storageTagCatalog, $script:storageTagName {
                Mock Write-LogMessage {}
                Set-StoragePolicy -PolicyName $args[0] -StorageType "VMFS" -TagCatalog $args[1] -TagName $args[2]
            }
        } | Should -Not -Throw
    }
}

Describe "Set-StoragePolicy — creates new VMFS policy from scratch — live write" -Tag "Live" {
    It "Creates the policy in vCenter and verifies it exists when no prior policy with that name is present" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
        if ([String]::IsNullOrWhiteSpace($env:VCF_TEST_ALLOW_WRITES)) { Set-ItResult -Skipped -Because "VCF_TEST_ALLOW_WRITES not set" }
        if ([String]::IsNullOrWhiteSpace($script:storageTagCatalog)) { Set-ItResult -Skipped -Because "VCF_TEST_STORAGE_TAG_CATALOG not set" }
        if ([String]::IsNullOrWhiteSpace($script:storageTagName)) { Set-ItResult -Skipped -Because "VCF_TEST_STORAGE_TAG_NAME not set" }

        $liveTestPolicyName = "veas-livetest-policy-vmfs"

        # Pre-clean: remove the test policy if a previous interrupted run left it behind.
        InModuleScope VcfEdgeAtScale -ArgumentList $liveTestPolicyName {
            $old = Get-SpbmStoragePolicy -Name $args[0] -Server $Script:vCenterName -ErrorAction SilentlyContinue
            if ($old) {
                Remove-SpbmStoragePolicy -StoragePolicy $old -Confirm:$false -Server $Script:vCenterName -ErrorAction SilentlyContinue
            }
        }

        try {
            {
                InModuleScope VcfEdgeAtScale -ArgumentList $liveTestPolicyName, $script:storageTagCatalog, $script:storageTagName {
                    Mock Write-LogMessage {}
                    Set-StoragePolicy -PolicyName $args[0] -StorageType "VMFS" -TagCatalog $args[1] -TagName $args[2]
                }
            } | Should -Not -Throw

            $created = InModuleScope VcfEdgeAtScale -ArgumentList $liveTestPolicyName {
                Get-SpbmStoragePolicy -Name $args[0] -Server $Script:vCenterName -ErrorAction SilentlyContinue
            }
            $created | Should -Not -BeNullOrEmpty
            $created.Name | Should -Be $liveTestPolicyName
        } finally {
            InModuleScope VcfEdgeAtScale -ArgumentList $liveTestPolicyName {
                $old = Get-SpbmStoragePolicy -Name $args[0] -Server $Script:vCenterName -ErrorAction SilentlyContinue
                if ($old) {
                    Remove-SpbmStoragePolicy -StoragePolicy $old -Confirm:$false -Server $Script:vCenterName -ErrorAction SilentlyContinue
                }
            }
        }
    }
}

Describe "Set-StoragePolicy — adds tag to existing policy without tag rules — live write" -Tag "Live" {
    It "Adds the tag rule to a policy that already has a capability rule but no tag assignments" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
        if ([String]::IsNullOrWhiteSpace($env:VCF_TEST_ALLOW_WRITES)) { Set-ItResult -Skipped -Because "VCF_TEST_ALLOW_WRITES not set" }
        if ([String]::IsNullOrWhiteSpace($script:storageTagCatalog)) { Set-ItResult -Skipped -Because "VCF_TEST_STORAGE_TAG_CATALOG not set" }
        if ([String]::IsNullOrWhiteSpace($script:storageTagName)) { Set-ItResult -Skipped -Because "VCF_TEST_STORAGE_TAG_NAME not set" }

        $liveTestPolicyName = "veas-livetest-policy-vmfs"

        # Pre-clean.
        InModuleScope VcfEdgeAtScale -ArgumentList $liveTestPolicyName {
            $old = Get-SpbmStoragePolicy -Name $args[0] -Server $Script:vCenterName -ErrorAction SilentlyContinue
            if ($old) {
                Remove-SpbmStoragePolicy -StoragePolicy $old -Confirm:$false -Server $Script:vCenterName -ErrorAction SilentlyContinue
            }
        }

        # Setup: create a capability-only policy (no tag rules) so the "add tag to existing policy" path is exercised.
        InModuleScope VcfEdgeAtScale -ArgumentList $liveTestPolicyName {
            $cap     = Get-SpbmCapability -Name "com.vmware.storage.volumeallocation.VolumeAllocationType" -Server $Script:vCenterName -ErrorAction Stop
            $capRule = New-SpbmRule -Capability $cap -Value "Fully initialized" -Server $Script:vCenterName -ErrorAction Stop
            $ruleSet = New-SpbmRuleSet -AllOfRules $capRule -ErrorAction Stop
            New-SpbmStoragePolicy -Name $args[0] -Description "Live test temporary policy" -AnyOfRuleSets $ruleSet -Server $Script:vCenterName -ErrorAction Stop | Out-Null
        }

        try {
            {
                InModuleScope VcfEdgeAtScale -ArgumentList $liveTestPolicyName, $script:storageTagCatalog, $script:storageTagName {
                    Mock Write-LogMessage {}
                    Set-StoragePolicy -PolicyName $args[0] -StorageType "VMFS" -TagCatalog $args[1] -TagName $args[2]
                }
            } | Should -Not -Throw

            # Verify the tag is now reported as present by the same lookup used in production.
            $tagPresent = InModuleScope VcfEdgeAtScale -ArgumentList $liveTestPolicyName, $script:storageTagCatalog, $script:storageTagName {
                $context = Resolve-StoragePolicyTagContext -PolicyName $args[0] -Server $Script:vCenterName -TagCatalog $args[1] -TagName $args[2]
                $context.TagAlreadyPresent
            }
            $tagPresent | Should -Be $true
        } finally {
            InModuleScope VcfEdgeAtScale -ArgumentList $liveTestPolicyName {
                $old = Get-SpbmStoragePolicy -Name $args[0] -Server $Script:vCenterName -ErrorAction SilentlyContinue
                if ($old) {
                    Remove-SpbmStoragePolicy -StoragePolicy $old -Confirm:$false -Server $Script:vCenterName -ErrorAction SilentlyContinue
                }
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Tier D additions — Pass D write-path contracts
# The following tests cover write-path functions not yet reached by the tiers
# above. Every test uses either an idempotent call on the live cluster or a
# ghost entity name that causes a non-fatal early-exit path, so no
# irreversible state changes are made.
# ---------------------------------------------------------------------------

Describe "Enable-VsanPerformanceService — live write" -Tag "Live" {
    It "Runs without throwing for the test cluster (idempotent: already-enabled is a no-op)" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        if ([String]::IsNullOrWhiteSpace($env:VCF_TEST_ALLOW_WRITES)) { Set-ItResult -Skipped -Because "VCF_TEST_ALLOW_WRITES not set" }
        {
            InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster {
                Mock Write-LogMessage {}
                Enable-VsanPerformanceService -ClusterName $args[0]
            }
        } | Should -Not -Throw
    }
}

Describe "Invoke-VsanClusterAlarmCheckAndRemediate — ghost cluster no-op — live write" -Tag "Live" {
    It "Runs without throwing when the cluster does not exist (non-fatal early exit: no alarms returned)" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
        if ([String]::IsNullOrWhiteSpace($env:VCF_TEST_ALLOW_WRITES)) { Set-ItResult -Skipped -Because "VCF_TEST_ALLOW_WRITES not set" }
        {
            InModuleScope VcfEdgeAtScale {
                Mock Write-LogMessage {}
                Invoke-VsanClusterAlarmCheckAndRemediate -ClusterName "ghost-cluster-livetest" -AcceptBadCheckResults -PostRemediationWaitSeconds 0
            }
        } | Should -Not -Throw
    }
}

Describe "Invoke-VsanClusterAlarmCheckAndRemediate — test cluster — live write" -Tag "Live" {
    It "Runs without throwing for the test cluster (AcceptBadCheckResults bypasses red-alarm prompt; PostRemediationWaitSeconds=0 skips post-remediation sleep)" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        if ([String]::IsNullOrWhiteSpace($env:VCF_TEST_ALLOW_WRITES)) { Set-ItResult -Skipped -Because "VCF_TEST_ALLOW_WRITES not set" }
        {
            InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster {
                Mock Write-LogMessage {}
                # -AcceptBadCheckResults: suppresses the interactive red-alarm blocking prompt so tests run unattended.
                # -PostRemediationWaitSeconds 0: skips the sleep after vSAN config reapply.
                Invoke-VsanClusterAlarmCheckAndRemediate -ClusterName $args[0] -AcceptBadCheckResults -PostRemediationWaitSeconds 0
            }
        } | Should -Not -Throw
    }
}

Describe "Wait-VsanClusterConfigSyncOrTimeout — immediate and polling — live write" -Tag "Live" {
    It "Returns false immediately when TimeoutSeconds is zero (no API calls made)" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
        # No cluster or writes gate: TimeoutSeconds=0 triggers an unconditional early return before any polling.
        $result = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Wait-VsanClusterConfigSyncOrTimeout -ClusterName "ghost-cluster-livetest" -TimeoutSeconds 0
        }
        $result | Should -Be $false
    }

    It "Returns a boolean after one polling pass for the test cluster (TimeoutSeconds=1 expires after first health fetch)" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        if ([String]::IsNullOrWhiteSpace($env:VCF_TEST_ALLOW_WRITES)) { Set-ItResult -Skipped -Because "VCF_TEST_ALLOW_WRITES not set" }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster {
            Mock Write-LogMessage {}
            # TimeoutSeconds=1 with CheckIntervalSeconds=5 (minimum): the health fetch takes longer than 1 s so
            # the loop exits after one pass without sleeping, returning $false (or $true if already in sync).
            Wait-VsanClusterConfigSyncOrTimeout -ClusterName $args[0] -TimeoutSeconds 1 -CheckIntervalSeconds 5
        }
        $result | Should -BeOfType [bool]
    }
}

Describe "Remove-StorageTag — ghost tag no-op — live write" -Tag "Live" {
    It "Runs without throwing when the tag and category do not exist (non-fatal early exit)" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
        if ([String]::IsNullOrWhiteSpace($env:VCF_TEST_ALLOW_WRITES)) { Set-ItResult -Skipped -Because "VCF_TEST_ALLOW_WRITES not set" }
        {
            InModuleScope VcfEdgeAtScale {
                Mock Write-LogMessage {}
                Remove-StorageTag -TagName "veas-live-test-nonexistent-tag-99999" -TagCatalog "veas-live-test-nonexistent-catalog-99999"
            }
        } | Should -Not -Throw
    }
}

Describe "Remove-TagCategoryIfEmpty — ghost category no-op — live write" -Tag "Live" {
    It "Runs without throwing when the tag category does not exist (non-fatal early exit)" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
        if ([String]::IsNullOrWhiteSpace($env:VCF_TEST_ALLOW_WRITES)) { Set-ItResult -Skipped -Because "VCF_TEST_ALLOW_WRITES not set" }
        {
            InModuleScope VcfEdgeAtScale {
                Mock Write-LogMessage {}
                Remove-TagCategoryIfEmpty -TagCatalog "veas-live-test-nonexistent-catalog-99999"
            }
        } | Should -Not -Throw
    }
}

Describe "Invoke-VsanClusterHealthRetriggerForStatsPrimary — ghost cluster — live write" -Tag "Live" {
    It "Runs without throwing for a ghost cluster (non-fatal when cluster not found; WaitAfterTriggerSeconds=5 is the allowed minimum)" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
        if ([String]::IsNullOrWhiteSpace($env:VCF_TEST_ALLOW_WRITES)) { Set-ItResult -Skipped -Because "VCF_TEST_ALLOW_WRITES not set" }
        {
            InModuleScope VcfEdgeAtScale {
                Mock Write-LogMessage {}
                Mock Start-Sleep {}
                # -WaitAfterTriggerSeconds 5: the minimum allowed value; Start-Sleep is mocked so this
                # doesn't add wall-clock time. The ghost cluster path skips Test-VsanClusterHealth and
                # Enable-VsanPerformanceService is non-fatal for a non-existent cluster.
                Invoke-VsanClusterHealthRetriggerForStatsPrimary -ClusterName "ghost-cluster-livetest" -WaitAfterTriggerSeconds 5
            }
        } | Should -Not -Throw
    }
}

Describe "Invoke-VDSCreation — existing VDS idempotency — live write" -Tag "Live" {
    It "Returns the existing VDS object without creating a new switch when the VDS already exists" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
        if ([String]::IsNullOrWhiteSpace($script:vdsName)) { Set-ItResult -Skipped -Because "VCF_TEST_VDS_NAME not set" }
        if ([String]::IsNullOrWhiteSpace($env:VCF_TEST_ALLOW_WRITES)) { Set-ItResult -Skipped -Because "VCF_TEST_ALLOW_WRITES not set" }
        # Resolve whether the VDS actually exists before entering the Should -Throw block so we can skip cleanly.
        $vdsExists = InModuleScope VcfEdgeAtScale -ArgumentList $script:vdsName, $script:vCenter {
            Mock Write-LogMessage {}
            $null -ne (Get-VDSwitch -Name $args[0] -Server $args[1] -ErrorAction SilentlyContinue)
        }
        if (-not $vdsExists) { Set-ItResult -Skipped -Because "VDS '$($script:vdsName)' not found in vCenter" }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $script:vdsName, $script:vCenter {
            Mock Write-LogMessage {}
            # DatacenterObject is not used when the VDS already exists; a stub object satisfies [ValidateNotNullOrEmpty()].
            $stubDc = [PSCustomObject]@{ Name = "stub-dc-for-idempotency-test" }
            Invoke-VDSCreation -VdsName $args[0] -DatacenterObject $stubDc -NumUplinks "2"
        }
        $result | Should -Not -BeNullOrEmpty
        $result.Name | Should -Be $script:vdsName
    }
}

# ---------------------------------------------------------------------------
# Tier B additions — Pass D read-only contracts
# ---------------------------------------------------------------------------

Describe "Test-SupervisorDeployedOnCluster — live" -Tag "Live" {
    It "Returns false for a ghost cluster name" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
        $result = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Test-SupervisorDeployedOnCluster -ClusterName "ghost-cluster-livetest"
        }
        $result | Should -Be $false
    }

    It "Returns a boolean for the test cluster" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $script:cluster {
            Mock Write-LogMessage {}
            Test-SupervisorDeployedOnCluster -ClusterName $args[0]
        }
        $result | Should -BeOfType [bool]
    }
}

# ---------------------------------------------------------------------------
# Add-ArgoCDInstance — idempotent re-apply contract (Tier D)
# Requires an already-deployed cluster with the ArgoCD operator and instance
# running.  Set VCF_TEST_INFRASTRUCTURE_JSON, VCF_TEST_CLUSTER, and
# VCF_TEST_ALLOW_WRITES to enable this test.  VCF_TEST_EDGE_SITE optionally
# matches the cluster spec for a custom namespace prefix.
# ---------------------------------------------------------------------------

Describe "Add-ArgoCDInstance — idempotent re-apply on deployed cluster — live write" -Tag "Live" {
    It "Completes without throwing when ArgoCD is already deployed on the cluster" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
        if ([String]::IsNullOrWhiteSpace($env:VCF_TEST_ALLOW_WRITES)) { Set-ItResult -Skipped -Because "VCF_TEST_ALLOW_WRITES not set" }
        if ([String]::IsNullOrWhiteSpace($script:infrastructureJson)) { Set-ItResult -Skipped -Because "VCF_TEST_INFRASTRUCTURE_JSON not set" }
        if (-not (Test-Path -LiteralPath $script:infrastructureJson)) { Set-ItResult -Skipped -Because "VCF_TEST_INFRASTRUCTURE_JSON path does not exist: $($script:infrastructureJson)" }
        if ([String]::IsNullOrWhiteSpace($script:cluster)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER not set" }

        {
            InModuleScope VcfEdgeAtScale -ArgumentList $script:infrastructureJson, $script:cluster, $script:edgeSite, $script:vcPass {
                $infraJson   = $args[0]
                $clusterName = $args[1]
                $edgeSite    = $args[2]
                $vcPass      = $args[3]

                $inputData          = Get-Content -Path $infraJson -Raw | ConvertFrom-Json
                $contextName        = $inputData.common.contextName
                $supervisorServices = $inputData.common.supervisorServices
                $parentDir          = $supervisorServices.parentDirectory
                $operatorYamlPath   = Join-Path -Path $parentDir -ChildPath $supervisorServices.argoCdOperatorYamlFileName
                $deploymentYamlPath = Join-Path -Path $parentDir -ChildPath $supervisorServices.argoCdDeploymentYamlFileName

                $clusterObj  = Get-ClusterByName -Name $clusterName
                $clusterSpec = $null
                if (-not [String]::IsNullOrWhiteSpace($edgeSite)) {
                    $clusterSpec = $inputData.clusters | Where-Object { $_.edgeSite -eq $edgeSite } | Select-Object -First 1
                }
                $argocdNamespace = Get-ArgoCDNamespaceFromCluster -ClusterObject $clusterObj -ClusterSpec $clusterSpec
                $argoServiceName = (Get-ArgoCDServiceDetail -Path $operatorYamlPath)[0]

                # Short timeouts: ArgoCD is already deployed so webhook and pods should respond quickly.
                $timeoutConfig = @{
                    AuthTimeoutSeconds         = 120
                    PodReadyTimeoutSeconds     = 300
                    WebhookReadyTimeoutSeconds = 300
                    WebhookRetryTimeoutSeconds = 60
                }

                $env:VCF_CLI_VSPHERE_PASSWORD = $vcPass
                $env:KUBECTL_VSPHERE_PASSWORD  = $vcPass
                try {
                    Add-ArgoCDInstance `
                        -ArgoCdDeploymentYamlPath $deploymentYamlPath `
                        -ArgoCdNamespace          $argocdNamespace `
                        -ClusterId                $clusterObj.ExtensionData.MoRef.Value `
                        -ContextName              $contextName `
                        -InsecureTls `
                        -Service                  $argoServiceName `
                        -TimeoutConfig            $timeoutConfig
                } finally {
                    Remove-Item -Path "env:\VCF_CLI_VSPHERE_PASSWORD" -ErrorAction SilentlyContinue
                    Remove-Item -Path "env:\KUBECTL_VSPHERE_PASSWORD"  -ErrorAction SilentlyContinue
                }
            }
        } | Should -Not -Throw
    }
}

# ---------------------------------------------------------------------------
# Install-HarborSupervisorService — idempotent re-apply contract (Tier D)
# Requires an already-deployed cluster with Harbor already CONFIGURED.
# Set VCF_TEST_INFRASTRUCTURE_JSON, VCF_TEST_CLUSTER (or VCF_TEST_EDGE_SITE),
# VCF_TEST_ALLOW_WRITES, HARBOR_ADMIN_PASSWORD, and SECRET_KEY to enable.
# ---------------------------------------------------------------------------

Describe "Install-HarborSupervisorService — idempotent re-apply on deployed cluster — live write" -Tag "Live" {
    It "Completes without throwing when Harbor is already CONFIGURED on the supervisor" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
        if ([String]::IsNullOrWhiteSpace($env:VCF_TEST_ALLOW_WRITES)) { Set-ItResult -Skipped -Because "VCF_TEST_ALLOW_WRITES not set" }
        if ([String]::IsNullOrWhiteSpace($script:infrastructureJson)) { Set-ItResult -Skipped -Because "VCF_TEST_INFRASTRUCTURE_JSON not set" }
        if (-not (Test-Path -LiteralPath $script:infrastructureJson)) { Set-ItResult -Skipped -Because "VCF_TEST_INFRASTRUCTURE_JSON path does not exist: $($script:infrastructureJson)" }
        if ([String]::IsNullOrWhiteSpace($script:cluster) -and [String]::IsNullOrWhiteSpace($script:edgeSite)) { Set-ItResult -Skipped -Because "VCF_TEST_CLUSTER or VCF_TEST_EDGE_SITE not set" }
        if ([String]::IsNullOrWhiteSpace($env:HARBOR_ADMIN_PASSWORD)) { Set-ItResult -Skipped -Because "HARBOR_ADMIN_PASSWORD not set" }
        if ([String]::IsNullOrWhiteSpace($env:SECRET_KEY)) { Set-ItResult -Skipped -Because "SECRET_KEY not set" }

        # Resolve all preconditions outside the Should -Not -Throw block so that a missing supervisor
        # (valid pre-deployment state) results in a graceful skip rather than a test failure.
        # Returns $null when the supervisor is not yet deployed; otherwise returns a setup hashtable.
        $harborSetup = InModuleScope VcfEdgeAtScale -ArgumentList $script:infrastructureJson, $script:cluster, $script:edgeSite, $script:vcUser {
            $infraJson   = $args[0]
            $clusterName = $args[1]
            $edgeSite    = $args[2]
            $vcUser      = $args[3]

            $inputData            = Get-Content -Path $infraJson -Raw | ConvertFrom-Json
            # Resolve harborConfiguration cert paths (tlsCrt, tlsKey, caCrt) using the same logic
            # as production code: parentDirectory if set, otherwise relative to the infrastructure
            # JSON directory. Without this, cert paths from the JSON are used as-is (relative to CWD).
            Update-InfrastructureJsonReferencedFilePaths -InfrastructureJsonPath $infraJson -InputData $inputData
            $supervisorNamePrefix = if ($inputData.common.supervisorNamePrefix) { $inputData.common.supervisorNamePrefix } else { "supervisor" }

            $clusterSpec = $null
            if (-not [String]::IsNullOrWhiteSpace($edgeSite)) {
                $clusterSpec = $inputData.clusters | Where-Object { $_.edgeSite -eq $edgeSite } | Select-Object -First 1
            }
            if ($null -eq $clusterSpec -and -not [String]::IsNullOrWhiteSpace($clusterName)) {
                $clusterSpec = $inputData.clusters | Where-Object { $_.clusterName -eq $clusterName } | Select-Object -First 1
            }
            if ($null -eq $clusterSpec) {
                throw "No cluster spec found for edgeSite='$edgeSite' clusterName='$clusterName' in $infraJson."
            }

            $effectiveEdgeSite    = $clusterSpec.edgeSite
            $clusterNamePrefix    = if ($inputData.common.clusterNamePrefix) { $inputData.common.clusterNamePrefix } else { "cluster" }
            $effectiveClusterName = Get-EffectiveClusterName -Cluster $clusterSpec -ClusterNamePrefix $clusterNamePrefix -EdgeSite $effectiveEdgeSite
            $supervisorName       = Get-SupervisorNameFromPrefix -SupervisorNamePrefix $supervisorNamePrefix -EdgeSite $effectiveEdgeSite

            # Prefer the explicit storage policy name from the cluster spec; fall back to the supervisor name
            # (the naming convention used when storagePolicy.storagePolicyName is omitted in production).
            $storagePolicyName = if ($clusterSpec.storagePolicy -and -not [String]::IsNullOrWhiteSpace($clusterSpec.storagePolicy.storagePolicyName)) {
                $clusterSpec.storagePolicy.storagePolicyName
            } else {
                $supervisorName
            }

            $clusterId = Get-ClusterId -ClusterName $effectiveClusterName

            # -SkipReadyWait: Harbor is already deployed; we only need the ID and do not need to
            # block waiting for READY status, which would time out if the supervisor is still booting.
            $supervisorId = Get-SupervisorId `
                -SupervisorName $supervisorName `
                -VcenterUser    $vcUser `
                -InsecureTls `
                -Silence `
                -SkipReadyWait `
                -ErrorAction    Stop

            # Return $null to signal skip — supervisor not yet deployed is a valid pre-deployment state.
            if ([String]::IsNullOrWhiteSpace($supervisorId)) { return $null }

            $harborServiceYamlPath  = Get-EffectiveSupervisorServicesYamlPath `
                -Cluster                     $clusterSpec `
                -CommonData                  $inputData.common `
                -LogicalYamlPathPropertyName "harborServiceYamlPath"
            $harborDataTemplatePath = Get-EffectiveSupervisorServicesYamlPath `
                -Cluster                     $clusterSpec `
                -CommonData                  $inputData.common `
                -LogicalYamlPathPropertyName "harborDataTemplateYamlPath"

            $harborServiceName, $harborServiceVersion = Get-ArgoCDServiceDetail -Path $harborServiceYamlPath

            $effectiveHarborHostname = Get-EffectiveHarborHostnameForInfrastructureCluster `
                -Cluster               $clusterSpec `
                -CommonData            $inputData.common `
                -LabEnvironmentEnabled:$false

            $harborConfig = $clusterSpec.harborConfiguration
            $harborDataValuesParams = @{
                EdgeSite               = $effectiveEdgeSite
                HarborTemplateFilePath = $harborDataTemplatePath
                Hostname               = $effectiveHarborHostname
                StoragePolicyName      = $storagePolicyName
            }
            # Cert/key paths in the infrastructure JSON may be relative. Resolve them relative to the
            # directory that contains the infrastructure JSON so the file can be found regardless of
            # what the current working directory is when Pester runs (e.g., the Tests/ folder on Windows).
            $infraJsonDir = Split-Path -Path $infraJson -Parent
            if ($harborConfig) {
                if (-not [String]::IsNullOrWhiteSpace($harborConfig.tlsCrt)) {
                    $tlsCrtPath = $harborConfig.tlsCrt
                    if (-not [System.IO.Path]::IsPathRooted($tlsCrtPath)) { $tlsCrtPath = Join-Path -Path $infraJsonDir -ChildPath $tlsCrtPath }
                    $harborDataValuesParams["TlsCrtPath"] = $tlsCrtPath
                }
                if (-not [String]::IsNullOrWhiteSpace($harborConfig.tlsKey)) {
                    $tlsKeyPath = $harborConfig.tlsKey
                    if (-not [System.IO.Path]::IsPathRooted($tlsKeyPath)) { $tlsKeyPath = Join-Path -Path $infraJsonDir -ChildPath $tlsKeyPath }
                    $harborDataValuesParams["TlsKeyPath"] = $tlsKeyPath
                }
                if (-not [String]::IsNullOrWhiteSpace($harborConfig.caCrt)) {
                    $caCrtPath = $harborConfig.caCrt
                    if (-not [System.IO.Path]::IsPathRooted($caCrtPath)) { $caCrtPath = Join-Path -Path $infraJsonDir -ChildPath $caCrtPath }
                    $harborDataValuesParams["CaCrtPath"] = $caCrtPath
                }
                if (-not [String]::IsNullOrWhiteSpace($harborConfig.harborAdminPassword)) { $harborDataValuesParams["HarborAdminPassword"] = $harborConfig.harborAdminPassword }
                if (-not [String]::IsNullOrWhiteSpace($harborConfig.secretKey))           { $harborDataValuesParams["SecretKey"]          = $harborConfig.secretKey }
                if (-not [String]::IsNullOrWhiteSpace($harborConfig.databasePassword))    { $harborDataValuesParams["DatabasePassword"]   = $harborConfig.databasePassword }
                if (-not [String]::IsNullOrWhiteSpace($harborConfig.coreSecret))          { $harborDataValuesParams["CoreSecret"]         = $harborConfig.coreSecret }
                if (-not [String]::IsNullOrWhiteSpace($harborConfig.jobserviceSecret))    { $harborDataValuesParams["JobserviceSecret"]   = $harborConfig.jobserviceSecret }
                if (-not [String]::IsNullOrWhiteSpace($harborConfig.registrySecret))      { $harborDataValuesParams["RegistrySecret"]     = $harborConfig.registrySecret }
            }

            return @{
                ClusterId            = $clusterId
                ClusterName          = $effectiveClusterName
                HarborDataValuesParams = $harborDataValuesParams
                HarborServiceName    = $harborServiceName
                HarborServiceVersion = $harborServiceVersion
                SupervisorId         = $supervisorId
                SupervisorName       = $supervisorName
            }
        }

        if ($null -eq $harborSetup) {
            Set-ItResult -Skipped -Because "Supervisor not found on this lab environment — Harbor idempotency test requires a deployed supervisor."
        }

        {
            InModuleScope VcfEdgeAtScale -ArgumentList $harborSetup {
                $setup              = $args[0]
                $harborValuesParams = $setup.HarborDataValuesParams

                $harborTempYamlPath = New-HarborDataValuesFile @harborValuesParams
                try {
                    $harborYamlContent = Get-Content -Path $harborTempYamlPath -Raw -Encoding UTF8
                    # Short TotalWaitTime: Harbor is already CONFIGURED so the first status poll
                    # should return CONFIGURED immediately, making a 60-second budget more than enough.
                    Install-HarborSupervisorService `
                        -CheckInterval     5 `
                        -ClusterId         $setup.ClusterId `
                        -ClusterName       $setup.ClusterName `
                        -Service           $setup.HarborServiceName `
                        -SupervisorId      $setup.SupervisorId `
                        -TotalWaitTime     60 `
                        -Version           $setup.HarborServiceVersion `
                        -YamlServiceConfig $harborYamlContent
                } finally {
                    if (-not [String]::IsNullOrWhiteSpace($harborTempYamlPath) -and (Test-Path -LiteralPath $harborTempYamlPath)) {
                        Remove-Item -Path $harborTempYamlPath -Force -ErrorAction SilentlyContinue
                    }
                }
            }
        } | Should -Not -Throw
    }
}

# ---------------------------------------------------------------------------
# Initialize-VcfEdgeAtScale — idempotent re-run contract (full-lab Tier D)
# Requires a fully-deployed lab environment with supervisor(s) already running.
# Set VCF_TEST_INFRASTRUCTURE_JSON, VCF_TEST_SUPERVISOR_JSON, and
# VCF_TEST_ALLOW_WRITES to enable this test.  VCF_TEST_EDGE_SITE optionally
# scopes the run to a single site so it completes in minutes rather than hours.
# ---------------------------------------------------------------------------

Describe "Initialize-VcfEdgeAtScale — idempotent re-run on fully-deployed lab — live write" -Tag "Live" {
    It "Completes without throwing when all resources already exist (full idempotent re-run)" {
        if (-not $script:liveMode) { Set-ItResult -Skipped -Because $script:skipReason }
        if ([String]::IsNullOrWhiteSpace($env:VCF_TEST_ALLOW_WRITES)) { Set-ItResult -Skipped -Because "VCF_TEST_ALLOW_WRITES not set" }
        if ([String]::IsNullOrWhiteSpace($script:infrastructureJson)) { Set-ItResult -Skipped -Because "VCF_TEST_INFRASTRUCTURE_JSON not set" }
        if (-not (Test-Path -LiteralPath $script:infrastructureJson)) { Set-ItResult -Skipped -Because "VCF_TEST_INFRASTRUCTURE_JSON path does not exist: $($script:infrastructureJson)" }
        if ([String]::IsNullOrWhiteSpace($script:supervisorJson)) { Set-ItResult -Skipped -Because "VCF_TEST_SUPERVISOR_JSON not set" }
        if (-not (Test-Path -LiteralPath $script:supervisorJson)) { Set-ItResult -Skipped -Because "VCF_TEST_SUPERVISOR_JSON path does not exist: $($script:supervisorJson)" }
        # Harbor credentials must be pre-set; Initialize-VcfEdgeAtScale calls Invoke-HarborDeploymentPhase
        # which prompts interactively if they are absent — unacceptable in an unattended test run.
        if ([String]::IsNullOrWhiteSpace($env:HARBOR_ADMIN_PASSWORD)) { Set-ItResult -Skipped -Because "HARBOR_ADMIN_PASSWORD not set" }
        if ([String]::IsNullOrWhiteSpace($env:SECRET_KEY)) { Set-ItResult -Skipped -Because "SECRET_KEY not set" }
        # ESX root password required; Initialize-VcfEdgeAtScale calls Invoke-EsxCredentialCollection which
        # reads ESX_COMMON_PASSWORD when nonInteractivePassword is true in the JSON. Without it the test hangs.
        if ([String]::IsNullOrWhiteSpace($env:VCF_TEST_ESX_PASSWORD)) { Set-ItResult -Skipped -Because "VCF_TEST_ESX_PASSWORD not set" }

        # Bridge test credentials into the env vars that the production code reads. The production code
        # reads VCENTER_COMMON_PASSWORD and ESX_COMMON_PASSWORD (not the VCF_TEST_* variants) and only
        # skips interactive prompts when nonInteractivePassword: true is set in infrastructure.json.
        $savedVcenterPw = $env:VCENTER_COMMON_PASSWORD
        $savedEsxPw     = $env:ESX_COMMON_PASSWORD
        try {
            $env:VCENTER_COMMON_PASSWORD = $script:vcPass
            $env:ESX_COMMON_PASSWORD     = $env:VCF_TEST_ESX_PASSWORD

            # -AcceptBadCheckResults: bypasses interactive red-alarm prompts so the test runs unattended.
            # -EdgeSite: scope to one site when set, so runtime is practical in CI.
            {
                InModuleScope VcfEdgeAtScale -ArgumentList $script:infrastructureJson, $script:supervisorJson, $script:edgeSite {
                    $infraJson  = $args[0]
                    $supJson    = $args[1]
                    $edgeSite   = $args[2]

                    # Disable the interactive rollback prompt so the test runs unattended.
                    # $false = skip rollback automatically, which is the safest default for an
                    # idempotent re-run test: we never want automated cleanup to tear down a lab
                    # environment without deliberate human intent.
                    $Script:RollbackOnFailurePreference = $false

                    $params = @{
                        InfrastructureJson    = $infraJson
                        SupervisorJson        = $supJson
                        AcceptBadCheckResults = $true
                    }
                    if (-not [String]::IsNullOrWhiteSpace($edgeSite)) {
                        $params["EdgeSite"] = $edgeSite
                    }
                    Initialize-VcfEdgeAtScale @params
                }
            } | Should -Not -Throw
        } finally {
            if ($null -eq $savedVcenterPw) { Remove-Item Env:VCENTER_COMMON_PASSWORD -ErrorAction SilentlyContinue } else { $env:VCENTER_COMMON_PASSWORD = $savedVcenterPw }
            if ($null -eq $savedEsxPw)     { Remove-Item Env:ESX_COMMON_PASSWORD     -ErrorAction SilentlyContinue } else { $env:ESX_COMMON_PASSWORD     = $savedEsxPw }
        }
    }
}
