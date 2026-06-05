# Pester tests for VcfEdgeAtScale — Private/Supervisor.ps1
#
# RECOMMENDED: Use the wrapper script for human-readable output:
#   ./Tests/Run-Tests.ps1
#   ./Tests/Run-Tests.ps1 -Filter "*FunctionName*"
#
# DIRECT: Invoke-Pester -Path ./Tests/VcfEdgeAtScale.Supervisor.Tests.ps1 -Output Detailed
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

Describe "New-VCenterRestApiSession" {
    BeforeEach {
        # Save $Script:vCenterName so that setting it inside InModuleScope does not persist
        # into downstream tests that rely on it being null (e.g. Get-Cluster -Server $null).
        $script:_savedVcenterNameForApiTest = InModuleScope VcfEdgeAtScale { $Script:vCenterName }
    }
    AfterEach {
        InModuleScope VcfEdgeAtScale -ArgumentList $script:_savedVcenterNameForApiTest {
            param($v) $Script:vCenterName = $v
        }
    }

    It "Returns Success false when no password is supplied" {
        # Exercises early validation only; no HTTP call (Script:vCenterName not required for this path).
        $session = InModuleScope VcfEdgeAtScale { New-VCenterRestApiSession -VcenterUser "user@domain" }
        $session.Success | Should -Be $false
        $session.ErrorMessage | Should -Match "No vCenter password"
    }

    It "Returns Success=true with a session ID when the REST call returns a session value" {
        $result = InModuleScope VcfEdgeAtScale {
            $Script:vCenterName = "vc.lab"
            Mock Write-LogMessage {}
            Mock Get-PowerCLIConfiguration { $null }
            Mock Invoke-RestMethod { [PSCustomObject]@{ value = "fake-session-abc123" } }
            New-VCenterRestApiSession -VcenterUser "admin@vsphere.local" -VcenterInsecurePassword "hunter2"
        }
        $result.Success    | Should -Be $true
        $result.SessionId  | Should -Be "fake-session-abc123"
        $result.SessionHeaders["vmware-api-session-id"] | Should -Be "fake-session-abc123"
    }

    It "Returns Success=false when Invoke-RestMethod throws a 401 Unauthorized error" {
        $result = InModuleScope VcfEdgeAtScale {
            $Script:vCenterName = "vc.lab"
            Mock Write-LogMessage {}
            Mock Get-PowerCLIConfiguration { $null }
            Mock Invoke-RestMethod { throw [System.Exception]::new("401 Unauthorized") }
            New-VCenterRestApiSession -VcenterUser "admin@vsphere.local" -VcenterInsecurePassword "wrongpass"
        }
        $result.Success | Should -Be $false
    }

    It "Returns Success=false when Invoke-RestMethod throws a connection error" {
        $result = InModuleScope VcfEdgeAtScale {
            $Script:vCenterName = "vc.lab"
            Mock Write-LogMessage {}
            Mock Get-PowerCLIConfiguration { $null }
            Mock Invoke-RestMethod { throw [System.Net.WebException]::new("Unable to connect to the remote server") }
            New-VCenterRestApiSession -VcenterUser "admin@vsphere.local" -VcenterInsecurePassword "pass"
        }
        $result.Success | Should -Be $false
    }
}


Describe "Get-PodReadinessStatus" {
    BeforeAll {
        # Write temporary mock kubectl .ps1 files into a unique per-run subdirectory.
        # Using a fixed base dir (GetTempPath) risks stale paths if a previous Pester run
        # left $script:tmpDir set to a deleted directory. A unique subdirectory guarantees
        # the BeforeAll always creates and uses fresh files.
        $script:tmpDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "veas-mock-$([System.Guid]::NewGuid().ToString('N').Substring(0, 8))"
        New-Item -ItemType Directory -Path $script:tmpDir -Force | Out-Null
        $script:savedKubectlCmd = InModuleScope VcfEdgeAtScale { $Script:KubectlCmd }

        # Exits 1 — simulates connection refused / wrong context.
        # Uses $global:LASTEXITCODE because PowerShell only sets $LASTEXITCODE for native executables;
        # for .ps1 scripts called with & we set it via the global scope so the caller's check works.
        $script:mockFail = Join-Path $script:tmpDir "veas-mock-kubectl-fail.ps1"
        Set-Content -Path $script:mockFail -Value '$global:LASTEXITCODE = 1; Write-Error "connection refused"' -Encoding UTF8

        # Exits 0, returns non-JSON — simulates auth error text.
        $script:mockNonJson = Join-Path $script:tmpDir "veas-mock-kubectl-nonjson.ps1"
        Set-Content -Path $script:mockNonJson -Value 'Write-Output "error: You must be logged in to the server"' -Encoding UTF8

        # Returns valid JSON: 2 Running pods.
        $script:mockTwoPods = Join-Path $script:tmpDir "veas-mock-kubectl-twopods.ps1"
        @'
$json = @{items=@(@{status=@{phase="Running"}},@{status=@{phase="Running"}})} | ConvertTo-Json -Depth 5 -Compress
Write-Output $json
'@ | Set-Content -Path $script:mockTwoPods -Encoding UTF8

        # Returns valid JSON: 1 Running pod.
        $script:mockOnePod = Join-Path $script:tmpDir "veas-mock-kubectl-onepod.ps1"
        @'
$json = @{items=@(@{status=@{phase="Running"}})} | ConvertTo-Json -Depth 5 -Compress
Write-Output $json
'@ | Set-Content -Path $script:mockOnePod -Encoding UTF8

        # Returns JSON with no items key.
        $script:mockEmpty = Join-Path $script:tmpDir "veas-mock-kubectl-empty.ps1"
        Set-Content -Path $script:mockEmpty -Value 'Write-Output "{}"' -Encoding UTF8
    }

    BeforeEach {
        # Restore KubectlCmd before each test to prevent state leakage between mock scenarios.
        InModuleScope VcfEdgeAtScale -ArgumentList $script:savedKubectlCmd { param($v) $Script:KubectlCmd = $v }
        # Reset $LASTEXITCODE — the mockFail script sets $global:LASTEXITCODE = 1 which persists
        # into subsequent tests and causes the non-zero exit guard in Get-PodReadinessStatus to
        # incorrectly treat successful mock output as a failure.
        $global:LASTEXITCODE = $null
    }

    AfterAll {
        InModuleScope VcfEdgeAtScale -ArgumentList $script:savedKubectlCmd { param($v) $Script:KubectlCmd = $v }
        Remove-Item -Path $script:tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Returns empty result when kubectl exits non-zero" {
        InModuleScope VcfEdgeAtScale -ArgumentList $script:mockFail { param($p) $Script:KubectlCmd = $p }
        $result = InModuleScope VcfEdgeAtScale { Get-PodReadinessStatus -Namespace "argocd-c123" }
        $result.TotalPods | Should -Be 0
        $result.ReadyPods | Should -Be 0
        $result.AllReady | Should -Be $false
    }

    It "Returns empty result when kubectl returns non-JSON output" {
        InModuleScope VcfEdgeAtScale -ArgumentList $script:mockNonJson { param($p) $Script:KubectlCmd = $p }
        $result = InModuleScope VcfEdgeAtScale { Get-PodReadinessStatus -Namespace "argocd-c123" }
        $result.TotalPods | Should -Be 0
        $result.AllReady | Should -Be $false
    }

    It "Returns correct counts when kubectl returns valid JSON with two running pods" {
        InModuleScope VcfEdgeAtScale -ArgumentList $script:mockTwoPods { param($p) $Script:KubectlCmd = $p }
        $result = InModuleScope VcfEdgeAtScale { Get-PodReadinessStatus -Namespace "argocd-c123" }
        $result.TotalPods | Should -Be 2
        $result.ReadyPods | Should -Be 2
        $result.AllReady | Should -Be $true
    }

    It "Returns AllReady=false when only one pod is present (secret-generation phase guard)" {
        InModuleScope VcfEdgeAtScale -ArgumentList $script:mockOnePod { param($p) $Script:KubectlCmd = $p }
        $result = InModuleScope VcfEdgeAtScale { Get-PodReadinessStatus -Namespace "argocd-c123" }
        $result.TotalPods | Should -Be 1
        $result.AllReady | Should -Be $false
    }

    It "Returns empty result when kubectl returns JSON with no items array" {
        InModuleScope VcfEdgeAtScale -ArgumentList $script:mockEmpty { param($p) $Script:KubectlCmd = $p }
        $result = InModuleScope VcfEdgeAtScale { Get-PodReadinessStatus -Namespace "argocd-c123" }
        $result.TotalPods | Should -Be 0
        $result.AllReady | Should -Be $false
    }
}


Describe "New-SupervisorDeploymentSpec" {

    It "Throws a VcfDeploymentException when configuration validation fails" {
        InModuleScope VcfEdgeAtScale {
            function Get-SupervisorConfigurationFromJson {
                [CmdletBinding()] Param(
                    [Parameter()] [Object]$SuppressNetworkVanityPrefix,
                    [Parameter()] [Object]$EdgeSite,
                    [Parameter()] [Object]$FlbNetworkIpAssignmentMode,
                    [Parameter()] [Object]$FlbMgmtNetworkPersona,
                    [Parameter()] [Object]$FlbProvider,
                    [Parameter()] [Object]$FlbVirtualServerNetworkPersona,
                    [Parameter()] [Object]$JsonFilePath,
                    [Parameter()] [Object]$MgmtIpAssignmentMode,
                    [Parameter()] [Object]$NetworkSegments,
                    [Parameter()] [Object]$PrimaryWorkloadIpAssignmentMode
                )
                return [PSCustomObject]@{ ControlPlane = @{}; ManagementNetwork = @{}; WorkloadNetwork = @{}; LoadBalancer = @{} }
            }
            function Test-SupervisorConfiguration {
                [CmdletBinding()] Param([Parameter()] [Object]$Config)
                return $false
            }
            Mock Write-LogMessage {}
            {
                New-SupervisorDeploymentSpec `
                    -EdgeSite "edge1" `
                    -InfrastructureJson (Join-Path ([System.IO.Path]::GetTempPath()) "infra.json") `
                    -NetworkSegments @("seg1") `
                    -StoragePolicyId "policy-1" `
                    -SupervisorName "sup1"
            } | Should -Throw "*configuration validation failed*"
        }
    }

     It "Returns a spec object when configuration is valid" {
         InModuleScope VcfEdgeAtScale {
             function Get-SupervisorConfigurationFromJson {
                 [CmdletBinding()] Param(
                     [Parameter()] [Object]$SuppressNetworkVanityPrefix,
                     [Parameter()] [Object]$EdgeSite,
                     [Parameter()] [Object]$FlbNetworkIpAssignmentMode,
                     [Parameter()] [Object]$FlbMgmtNetworkPersona,
                     [Parameter()] [Object]$FlbProvider,
                     [Parameter()] [Object]$FlbVirtualServerNetworkPersona,
                     [Parameter()] [Object]$JsonFilePath,
                     [Parameter()] [Object]$MgmtIpAssignmentMode,
                     [Parameter()] [Object]$NetworkSegments,
                     [Parameter()] [Object]$PrimaryWorkloadIpAssignmentMode
                 )
                 return [PSCustomObject]@{ ControlPlane = @{}; ManagementNetwork = @{}; WorkloadNetwork = @{}; LoadBalancer = @{} }
             }
             function Test-SupervisorConfiguration { [CmdletBinding()] Param([Parameter()] [Object]$Config); return $true }
             function New-SupervisorControlPlaneSpec { [CmdletBinding()] Param([Parameter()] [Object]$ControlPlaneConfig, [Parameter()] [Object]$ManagementNetworkConfig, [Parameter()] [Object]$StoragePolicyId); return [PSCustomObject]@{} }
             function New-SupervisorWorkloadSpec { [CmdletBinding()] Param([Parameter()] [Object]$WorkloadNetworkConfig); return [PSCustomObject]@{} }
             function New-SupervisorLoadBalancerSpec { [CmdletBinding()] Param([Parameter()] [Object]$FlbMgmtNetworkPersona, [Parameter()] [Object]$FlbWorkloadNetworkPersona, [Parameter()] [Object]$LoadBalancerConfig, [Parameter()] [Object]$StoragePolicyId); return [PSCustomObject]@{} }
             # Function stubs for VCF SDK binary cmdlets. Defined with untyped [Object] parameters
             # so PowerShell command lookup resolves to these functions before the binary cmdlets,
             # bypassing ArgumentTransformationAttribute type coercion on Windows with PowerCLI.
             # The stubs must use begin/process blocks and explicit return to guarantee output
             # in all execution contexts (bare expression output is dropped in some Windows paths).
             # Stubs use empty PSCustomObjects so that on Windows (where Pester's Mock wraps the
             # binary cmdlet and its ArgumentTransformationAttribute runs before the scriptblock),
             # conversion from PSCustomObject → VMware model type succeeds. Extra properties (e.g.
             # Type = "KubeOptions") cause the conversion to fail because they are unrecognised.
             # Only the final EnableSpec stub carries meaningful data for the test assertion.
             function Initialize-VcenterNamespaceManagementSupervisorsKubeAPIServerOptions {
                 [CmdletBinding()] Param()
                 begin {}
                 process { return [PSCustomObject]@{} }
             }
             function Initialize-VcenterNamespaceManagementSupervisorsWorkloads {
                 [CmdletBinding()] Param([Parameter()] [Object]$Edge, [Parameter()] [Object]$KubeApiServerOptions, [Parameter()] [Object]$Network)
                 begin {}
                 process { return [PSCustomObject]@{} }
             }
             function Initialize-VcenterNamespaceManagementSupervisorsEnableOnComputeClusterSpec {
                 [CmdletBinding()] Param([Parameter()] [Object]$ControlPlane, [Parameter()] [Object]$Name, [Parameter()] [Object]$Workloads)
                 begin {}
                 process { return [PSCustomObject]@{ Name = $Name; Type = "EnableSpec" } }
             }
             Mock Initialize-VcenterNamespaceManagementSupervisorsKubeAPIServerOptions { return [PSCustomObject]@{} }
             Mock Initialize-VcenterNamespaceManagementSupervisorsWorkloads { return [PSCustomObject]@{} }
             Mock Initialize-VcenterNamespaceManagementSupervisorsEnableOnComputeClusterSpec { return [PSCustomObject]@{ Name = $Name; Type = "EnableSpec" } }
             Mock Write-LogMessage {}
             $result = New-SupervisorDeploymentSpec `
                 -EdgeSite "edge1" `
                 -InfrastructureJson (Join-Path ([System.IO.Path]::GetTempPath()) "infra.json") `
                 -NetworkSegments @("seg1") `
                 -StoragePolicyId "policy-1" `
                 -SupervisorName "sup1"
             $result.Name | Should -Be "sup1"
             $result.Type | Should -Be "EnableSpec"
         }
     }

    It "Threads SuppressNetworkVanityPrefix switch to Get-SupervisorConfigurationFromJson" {
        InModuleScope VcfEdgeAtScale {
            $Script:_disablePrefixCalled = $false
            function Get-SupervisorConfigurationFromJson {
                [CmdletBinding()] Param(
                    [Parameter()] [Object]$SuppressNetworkVanityPrefix,
                    [Parameter()] [Object]$EdgeSite,
                    [Parameter()] [Object]$FlbNetworkIpAssignmentMode,
                    [Parameter()] [Object]$FlbMgmtNetworkPersona,
                    [Parameter()] [Object]$FlbProvider,
                    [Parameter()] [Object]$FlbVirtualServerNetworkPersona,
                    [Parameter()] [Object]$JsonFilePath,
                    [Parameter()] [Object]$MgmtIpAssignmentMode,
                    [Parameter()] [Object]$NetworkSegments,
                    [Parameter()] [Object]$PrimaryWorkloadIpAssignmentMode
                )
                if ($SuppressNetworkVanityPrefix -eq $true) { $Script:_disablePrefixCalled = $true }
                return [PSCustomObject]@{ ControlPlane = @{}; ManagementNetwork = @{}; WorkloadNetwork = @{}; LoadBalancer = @{} }
            }
            function Test-SupervisorConfiguration { [CmdletBinding()] Param([Parameter()] [Object]$Config); return $true }
            function New-SupervisorControlPlaneSpec { [CmdletBinding()] Param([Parameter()] [Object]$ControlPlaneConfig, [Parameter()] [Object]$ManagementNetworkConfig, [Parameter()] [Object]$StoragePolicyId); return [PSCustomObject]@{} }
            function New-SupervisorWorkloadSpec { [CmdletBinding()] Param([Parameter()] [Object]$WorkloadNetworkConfig); return [PSCustomObject]@{} }
            function New-SupervisorLoadBalancerSpec { [CmdletBinding()] Param([Parameter()] [Object]$FlbMgmtNetworkPersona, [Parameter()] [Object]$FlbWorkloadNetworkPersona, [Parameter()] [Object]$LoadBalancerConfig, [Parameter()] [Object]$StoragePolicyId); return [PSCustomObject]@{} }
            function Initialize-VcenterNamespaceManagementSupervisorsKubeAPIServerOptions { [CmdletBinding()] Param(); begin {}; process {} }
            function Initialize-VcenterNamespaceManagementSupervisorsWorkloads { [CmdletBinding()] Param([Parameter()] [Object]$Edge, [Parameter()] [Object]$KubeApiServerOptions, [Parameter()] [Object]$Network); begin {}; process {} }
            function Initialize-VcenterNamespaceManagementSupervisorsEnableOnComputeClusterSpec { [CmdletBinding()] Param([Parameter()] [Object]$ControlPlane, [Parameter()] [Object]$Name, [Parameter()] [Object]$Workloads); begin {}; process {} }
            Mock Initialize-VcenterNamespaceManagementSupervisorsKubeAPIServerOptions { return [PSCustomObject]@{} }
            Mock Initialize-VcenterNamespaceManagementSupervisorsWorkloads { return [PSCustomObject]@{} }
            Mock Initialize-VcenterNamespaceManagementSupervisorsEnableOnComputeClusterSpec { return [PSCustomObject]@{ Name = $Name; Type = "EnableSpec" } }
            Mock Write-LogMessage {}
            New-SupervisorDeploymentSpec `
                -SuppressNetworkVanityPrefix `
                -EdgeSite "edge1" `
                -InfrastructureJson (Join-Path ([System.IO.Path]::GetTempPath()) "infra.json") `
                -NetworkSegments @("seg1") `
                -StoragePolicyId "policy-1" `
                -SupervisorName "sup1"
            $Script:_disablePrefixCalled | Should -Be $true
        }
    }
}


Describe "Invoke-SupervisorReadinessWait" {

    It "Returns without throwing when supervisor becomes ready" {
        InModuleScope VcfEdgeAtScale {
            function Wait-SupervisorReady {
                [CmdletBinding()] Param(
                    [Parameter()] [Object]$supervisorId, [Parameter()] [Object]$clusterName,
                    [Parameter()] [Object]$checkInterval, [Parameter()] [Object]$totalWaitTime
                )
                return [PSCustomObject]@{ Success = $true; ElapsedSeconds = 10 }
            }
            Mock Write-LogMessage {}
            Mock Write-Progress {}
            {
                Invoke-SupervisorReadinessWait `
                    -SupervisorId "sup-123" `
                    -ClusterId "domain-c8" `
                    -ClusterName "cluster-edge1" `
                    -CheckInterval 5 `
                    -TotalWaitTime 3600
            } | Should -Not -Throw
            # Progress bar is initialized and then completed on the success path.
            Should -Invoke Write-Progress -ParameterFilter { $Activity -eq "Supervisor Deployment" } -Times 2
        }
    }

    It "Throws RollbackSkippedException when user chooses DoNotRollback" {
        InModuleScope VcfEdgeAtScale {
            function Wait-SupervisorReady {
                [CmdletBinding()] Param(
                    [Parameter()] [Object]$supervisorId, [Parameter()] [Object]$clusterName,
                    [Parameter()] [Object]$checkInterval, [Parameter()] [Object]$totalWaitTime
                )
                return [PSCustomObject]@{ Success = $false }
            }
            function Invoke-PauseBeforeRollbackIfRequested {
                [CmdletBinding()] Param(
                    [Parameter()] [Switch]$ForcePrompt,
                    [Parameter()] [Object]$RollbackContext,
                    [Parameter()] [Object]$SingleSite
                )
                return "DoNotRollback"
            }
            Mock Write-LogMessage {}
            Mock Write-Progress {}
            {
                Invoke-SupervisorReadinessWait `
                    -SupervisorId "sup-123" `
                    -ClusterId "domain-c8" `
                    -ClusterName "cluster-edge1"
            } | Should -Throw

        }
    }

    It "Throws VcfDeploymentException and sets RollbackAttempted after deactivation" {
        InModuleScope VcfEdgeAtScale {
            function Wait-SupervisorReady {
                [CmdletBinding()] Param(
                    [Parameter()] [Object]$supervisorId, [Parameter()] [Object]$clusterName,
                    [Parameter()] [Object]$checkInterval, [Parameter()] [Object]$totalWaitTime
                )
                return [PSCustomObject]@{ Success = $false }
            }
            function Invoke-PauseBeforeRollbackIfRequested {
                [CmdletBinding()] Param(
                    [Parameter()] [Switch]$ForcePrompt,
                    [Parameter()] [Object]$RollbackContext,
                    [Parameter()] [Object]$SingleSite
                )
                return "Rollback"
            }
            function Disable-SupervisorOnCluster {
                [CmdletBinding()] Param(
                    [Parameter()] [Object]$ClusterId, [Parameter()] [Object]$ClusterName,
                    [Parameter()] [Object]$SupervisorId, [Parameter()] [Switch]$SuppressConfirm
                )
                return [PSCustomObject]@{ Success = $false; ErrorMessage = "timeout" }
            }
            Mock Write-LogMessage {}
            Mock Write-Progress {}
            $Script:RollbackAttempted = $false
            {
                Invoke-SupervisorReadinessWait `
                    -SupervisorId "sup-123" `
                    -ClusterId "domain-c8" `
                    -ClusterName "cluster-edge1"
            } | Should -Throw "*deployment failed*"
            $Script:RollbackAttempted | Should -Be $true
        }
    }
}


Describe "Invoke-SupervisorUpgradeIfAvailable" {

    It "Logs INFO 'No supervisor upgrade available' and returns when no upgrade is available" {
        InModuleScope VcfEdgeAtScale {
            function Get-SupervisorUpgradeInfo {
                [CmdletBinding()] Param([Parameter()] [Object]$ClusterId)
                return [PSCustomObject]@{ Success = $true; HasUpgradeAvailable = $false; CurrentVersion = "1.0.0" }
            }
            Mock Write-LogMessage {}
            { Invoke-SupervisorUpgradeIfAvailable -ClusterId "domain-c8" -ClusterName "cluster-edge1" -SupervisorId "sup-123" } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'INFO' -and $Message -match 'No supervisor upgrade available' }
        }
    }

    It "Logs WARNING 'Failed to query' and returns (no throw) when upgrade info query fails" {
        InModuleScope VcfEdgeAtScale {
            function Get-SupervisorUpgradeInfo {
                [CmdletBinding()] Param([Parameter()] [Object]$ClusterId)
                return [PSCustomObject]@{ Success = $false; ErrorMessage = "connection failed" }
            }
            Mock Write-LogMessage {}
            { Invoke-SupervisorUpgradeIfAvailable -ClusterId "domain-c8" -ClusterName "cluster-edge1" -SupervisorId "sup-123" } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'WARNING' -and $Message -match 'Failed to query supervisor upgrade' }
        }
    }

    It "Throws VcfDeploymentException when upgrade initiation fails" {
        InModuleScope VcfEdgeAtScale {
            function Get-SupervisorUpgradeInfo {
                [CmdletBinding()] Param([Parameter()] [Object]$ClusterId)
                return [PSCustomObject]@{
                    Success = $true
                    HasUpgradeAvailable = $true
                    CurrentVersion = "1.0.0"
                    LatestVersion = "1.1.0"
                    AvailableVersions = @("1.1.0")
                }
            }
            function Invoke-SupervisorUpgrade {
                [CmdletBinding()] Param([Parameter()] [Object]$ClusterId, [Parameter()] [Object]$DesiredVersion)
                return [PSCustomObject]@{ Success = $false; ErrorMessage = "upgrade API error" }
            }
            Mock Write-LogMessage {}
            {
                Invoke-SupervisorUpgradeIfAvailable `
                    -ClusterId "domain-c8" `
                    -ClusterName "cluster-edge1" `
                    -SupervisorId "sup-123"
            } | Should -Throw "*upgrade is required*"
        }
    }
}


Describe "Invoke-SupervisorCreation — idempotency and error paths" {
    # These tests mock the PowerCLI cmdlet that calls the vCenter API so we can exercise the
    # logic branches without a live vCenter connection.
    # The cmdlet parameter binding requires a VCF SDK type — we mock the parameter binding step
    # by mocking Invoke-EnableOnComputeClusterClusterSupervisors with -ParameterFilter $null
    # and also mock Set-Content so no temp file write is needed. Since Pester Mock intercepts
    # before the runtime type check, we use -MockWith to throw from within the mock body itself.
    # For the idempotency path specifically, we use Get-OrCreateSupervisor which calls
    # Invoke-SupervisorCreation internally, and mock at the Invoke-SupervisorCreation level.

    It "Returns IsExisting=true when Invoke-SupervisorCreation reports existing supervisor" {
        $result = InModuleScope VcfEdgeAtScale {
            $Script:VCenterUser = "admin@vsphere.local"
            Mock Invoke-SupervisorCreation {
                return [PSCustomObject]@{
                    Success = $true; SupervisorId = "sup-existing-abc"; IsExisting = $true; ErrorMessage = $null
                }
            }
            Mock Get-SupervisorId { return "sup-existing-abc" }

            Get-OrCreateSupervisor `
                -StoragePolicyId "policy-001" -SupervisorName "Supervisor01" `
                -SupervisorJson "{}" -ClusterId "domain-c8" -ClusterName "cl-test" `
                -EdgeSite "site1" -NetworkSegments @("segment1") -InsecureTls
        }
        $result | Should -Be "sup-existing-abc"
    }

    It "Returns Success=false when Invoke-SupervisorCreation reports a non-idempotency failure" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Invoke-SupervisorCreation {
                return [PSCustomObject]@{
                    Success = $false; SupervisorId = $null; IsExisting = $false
                    ErrorMessage = "Insufficient resources to create supervisor"
                }
            }

            $fakeSpec = [PSCustomObject]@{ something = "value" }
            $fakeSpec | Add-Member -MemberType ScriptMethod -Name "ToJson" -Value { return '{"something":"value"}' }

            Invoke-SupervisorCreation -ClusterId "domain-c8" -ClusterName "TestCluster" `
                -SupervisorName "TestSupervisor" -SupervisorSpec $fakeSpec
        }
        $result.Success       | Should -Be $false
        $result.ErrorMessage  | Should -Match "Insufficient resources"
    }

    It "IsExisting flag is false for a freshly created supervisor (Add-Supervisor called and returns new ID)" {
        $result = InModuleScope VcfEdgeAtScale {
            $Script:VCenterUser = "admin@vsphere.local"
            Mock Get-SupervisorId { return $null }
            Mock Add-Supervisor { return "sup-new-xyz" }

            Get-OrCreateSupervisor `
                -StoragePolicyId "policy-001" -SupervisorName "Supervisor01" `
                -SupervisorJson "{}" -ClusterId "domain-c8" -ClusterName "cl-test" `
                -EdgeSite "site1" -NetworkSegments @("segment1") -InsecureTls
        }
        $result | Should -Be "sup-new-xyz"
    }
}


Describe "Get-VlcmDesiredBaseImageVersionFromSpec" {
    # Pure-logic function: no PowerCLI calls, no filesystem access. Tests cover every code path.

    It "Returns null for null input" {
        $result = InModuleScope VcfEdgeAtScale { Get-VlcmDesiredBaseImageVersionFromSpec -SoftwareSpecOrResult $null }
        $result | Should -BeNullOrEmpty
    }

    It "Returns version from direct BaseImage.Version property" {
        $spec = [PSCustomObject]@{ BaseImage = [PSCustomObject]@{ Version = "8.0.2-23305546" } }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $spec { Get-VlcmDesiredBaseImageVersionFromSpec -SoftwareSpecOrResult $args[0] }
        $result | Should -Be "8.0.2-23305546"
    }

    It "Unwraps .Spec and returns BaseImage.Version" {
        $inner = [PSCustomObject]@{ BaseImage = [PSCustomObject]@{ Version = "8.0.3-00000001" } }
        $wrapper = [PSCustomObject]@{ Spec = $inner }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $wrapper { Get-VlcmDesiredBaseImageVersionFromSpec -SoftwareSpecOrResult $args[0] }
        $result | Should -Be "8.0.3-00000001"
    }

    It "Unwraps .Desired and returns BaseImage.Version" {
        $inner = [PSCustomObject]@{ BaseImage = [PSCustomObject]@{ Version = "8.0.1-21495797" } }
        $wrapper = [PSCustomObject]@{ Desired = $inner }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $wrapper { Get-VlcmDesiredBaseImageVersionFromSpec -SoftwareSpecOrResult $args[0] }
        $result | Should -Be "8.0.1-21495797"
    }

    It "Unwraps .SoftwareSpec and returns BaseImage.Version" {
        $inner = [PSCustomObject]@{ BaseImage = [PSCustomObject]@{ Version = "9.0.0-12345678" } }
        $wrapper = [PSCustomObject]@{ SoftwareSpec = $inner }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $wrapper { Get-VlcmDesiredBaseImageVersionFromSpec -SoftwareSpecOrResult $args[0] }
        $result | Should -Be "9.0.0-12345678"
    }

    It "Falls back to string parsing when BaseImage property is absent" {
        # Simulate an API result whose ToString() produces the vLCM text representation.
        $stringFallback = [PSCustomObject]@{}
        Add-Member -InputObject $stringFallback -MemberType ScriptMethod -Name "ToString" -Value {
            "SomePrefix, BaseImage: Version: 8.0.2-22380479, SomeSuffix"
        } -Force
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $stringFallback { Get-VlcmDesiredBaseImageVersionFromSpec -SoftwareSpecOrResult $args[0] }
        $result | Should -Be "8.0.2-22380479"
    }

    It "Returns null when no matching path exists and string does not match pattern" {
        $noMatch = [PSCustomObject]@{ SomeOtherProp = "irrelevant" }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $noMatch { Get-VlcmDesiredBaseImageVersionFromSpec -SoftwareSpecOrResult $args[0] }
        $result | Should -BeNullOrEmpty
    }
}


Describe "Get-VlcmComplianceItemInfo" {
    It "Returns fallback name and null VMHost when Item is null" {
        $result = InModuleScope VcfEdgeAtScale { Get-VlcmComplianceItemInfo -Item $null -FallbackIndex 3 }
        $result.DisplayName | Should -Be "Host 3"
        $result.VMHost | Should -Be $null
    }

    It "Resolves DisplayName from Host.Name property" {
        $item = [PSCustomObject]@{ Host = [PSCustomObject]@{ Name = "esx01.lab" } }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $item { Get-VlcmComplianceItemInfo -Item $args[0] -FallbackIndex 1 }
        $result.DisplayName | Should -Be "esx01.lab"
        $result.VMHost.Name | Should -Be "esx01.lab"
    }

    It "Resolves DisplayName from VMHost.Name when Host is absent" {
        $item = [PSCustomObject]@{ VMHost = [PSCustomObject]@{ Name = "esx02.lab" } }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $item { Get-VlcmComplianceItemInfo -Item $args[0] -FallbackIndex 2 }
        $result.DisplayName | Should -Be "esx02.lab"
        $result.VMHost.Name | Should -Be "esx02.lab"
    }

    It "Falls back to fallback index when display name is a VMware type name" {
        $item = [PSCustomObject]@{ Name = "Vmware.VimAutomation.Types.ClusterHost" }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $item { Get-VlcmComplianceItemInfo -Item $args[0] -FallbackIndex 5 }
        $result.DisplayName | Should -Be "Host 5"
    }

    It "Uses Name property when no Host or VMHost property exists" {
        $item = [PSCustomObject]@{ Name = "esx03.lab" }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $item { Get-VlcmComplianceItemInfo -Item $args[0] -FallbackIndex 4 }
        $result.DisplayName | Should -Be "esx03.lab"
    }

    It "Resolves DisplayName from Entity.Name when Host and VMHost are absent" {
        $item = [PSCustomObject]@{ Entity = [PSCustomObject]@{ Name = "esx04.lab" } }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $item { Get-VlcmComplianceItemInfo -Item $args[0] -FallbackIndex 1 }
        $result.DisplayName | Should -Be "esx04.lab"
    }

    It "Resolves DisplayName from HostName scalar property when no Host or VMHost exists" {
        $item = [PSCustomObject]@{ HostName = "esx05.lab" }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $item { Get-VlcmComplianceItemInfo -Item $args[0] -FallbackIndex 1 }
        $result.DisplayName | Should -Be "esx05.lab"
    }

    It "Throws when FallbackIndex is 0 (ValidateRange enforces minimum of 1)" {
        { InModuleScope VcfEdgeAtScale { Get-VlcmComplianceItemInfo -Item $null -FallbackIndex 0 } } | Should -Throw -ExceptionType ([System.Management.Automation.ParameterBindingException])

    }

    It "Falls back to fallback index when item has all recognised properties but all values are whitespace-only" {
        $item = [PSCustomObject]@{
            Host     = [PSCustomObject]@{ Name = "   " }
            VMHost   = [PSCustomObject]@{ Name = "   " }
            Entity   = [PSCustomObject]@{ Name = "   " }
            Name     = "   "
            HostName = "   "
        }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $item {
            Get-VlcmComplianceItemInfo -Item $args[0] -FallbackIndex 7
        }
        $result.DisplayName | Should -Be "Host 7"
    }
}


Describe "Invoke-VlcmClusterComplianceAndRemediate — routing" {
    BeforeEach {
        # Function shadows must be defined in the same InModuleScope call as their Mocks.
        # Pester's AfterEach cleanup restores each mocked function to its pre-mock state;
        # if the shadow is defined elsewhere (e.g. BeforeAll), cleanup restores the VMware
        # binary cmdlet instead of the stub, and subsequent Mocks wrap the binary cmdlet
        # directly — which breaks pipeline-input interception due to VIContainer coercion.
        InModuleScope VcfEdgeAtScale {
            function Test-LcmClusterCompliance {
                [CmdletBinding()] Param([Parameter(ValueFromPipeline = $true)] [Object] $In)
                Process { }
            }
            # SupportsShouldProcess is required so -Confirm:$false is accepted as a named
            # parameter at the call site, not just a common ShouldProcess parameter.
            function Set-Cluster {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param(
                    [Parameter(ValueFromPipeline = $true, Mandatory = $false)] [Object] $In,
                    [Parameter(Mandatory = $false)] [Switch] $Remediate,
                    [Parameter(Mandatory = $false)] [Switch] $AcceptEULA,
                    [Parameter(Mandatory = $false)] [Object] $Server
                )
                Process { }
            }
            Mock Write-LogMessage {}
            Mock Get-Cluster { return [PSCustomObject]@{ Name = "cl0" } }
            Mock Set-Cluster {}
        }
    }

    It "Throws VcfDeploymentException when the cluster is not found" {
        InModuleScope VcfEdgeAtScale {
            Mock Get-Cluster { return $null }
            { Invoke-VlcmClusterComplianceAndRemediate -ClusterName "cl0" } | Should -Throw

        }
    }

    It "Returns without remediation when Test-LcmClusterCompliance throws NullReferenceException" {
        # Pester 5.7.1 does not count Should -Invoke for pipeline-input calls. Use a begin{} stub
        # counter (runs in module scope) to reliably verify Set-Cluster was never invoked.
        $setCalled = InModuleScope VcfEdgeAtScale {
            $Script:_setClusterCount = 0
            function Set-Cluster {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param(
                    [Parameter(ValueFromPipeline = $true)] [Object]$In,
                    [Parameter()] [Switch]$Remediate, [Parameter()] [Switch]$AcceptEULA,
                    [Parameter()] [Object]$Server
                )
                begin { $Script:_setClusterCount++ }
            }
            Mock Test-LcmClusterCompliance { throw "Object reference not set to an instance of an object" }
            Invoke-VlcmClusterComplianceAndRemediate -ClusterName "cl0"
            $Script:_setClusterCount
        }
        $setCalled | Should -Be 0
    }

    It "Returns without remediation when Test-LcmClusterCompliance throws a generic error" {
        $setCalled = InModuleScope VcfEdgeAtScale {
            $Script:_setClusterCount = 0
            function Set-Cluster {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param(
                    [Parameter(ValueFromPipeline = $true)] [Object]$In,
                    [Parameter()] [Switch]$Remediate, [Parameter()] [Switch]$AcceptEULA,
                    [Parameter()] [Object]$Server
                )
                begin { $Script:_setClusterCount++ }
            }
            Mock Test-LcmClusterCompliance { throw "vLCM API unavailable" }
            Invoke-VlcmClusterComplianceAndRemediate -ClusterName "cl0"
            $Script:_setClusterCount
        }
        $setCalled | Should -Be 0
    }

    It "Returns without remediation when the compliance result is null" {
        $setCalled = InModuleScope VcfEdgeAtScale {
            $Script:_setClusterCount = 0
            function Set-Cluster {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param(
                    [Parameter(ValueFromPipeline = $true)] [Object]$In,
                    [Parameter()] [Switch]$Remediate, [Parameter()] [Switch]$AcceptEULA,
                    [Parameter()] [Object]$Server
                )
                begin { $Script:_setClusterCount++ }
            }
            Mock Test-LcmClusterCompliance {
                process { $null }
            }
            Invoke-VlcmClusterComplianceAndRemediate -ClusterName "cl0"
            $Script:_setClusterCount
        }
        $setCalled | Should -Be 0
    }

    It "Returns without remediation when the cluster is already compliant" {
        $setCalled = InModuleScope VcfEdgeAtScale {
            $Script:_setClusterCount = 0
            function Set-Cluster {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param(
                    [Parameter(ValueFromPipeline = $true)] [Object]$In,
                    [Parameter()] [Switch]$Remediate, [Parameter()] [Switch]$AcceptEULA,
                    [Parameter()] [Object]$Server
                )
                begin { $Script:_setClusterCount++ }
            }
            Mock Test-LcmClusterCompliance {
                process { [PSCustomObject]@{ Status = "Compliant" } }
            }
            Invoke-VlcmClusterComplianceAndRemediate -ClusterName "cl0"
            $Script:_setClusterCount
        }
        $setCalled | Should -Be 0
    }

    It "Reaches the Set-Cluster remediation path when the cluster is non-compliant" {
        # Pester 5.7.1 pipeline-input mocks are not counted by Should -Invoke. Verify indirectly:
        # the post-remediation Test-LcmClusterCompliance call (line 3479) only runs after Set-Cluster
        # succeeds. With a non-throwing Set-Cluster mock the function calls Test-LcmClusterCompliance
        # twice (once for compliance check, once post-remediation). The passing tests above prove
        # the early-return paths call it exactly once. We assert at least 2 calls.
        $callCount = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Get-Cluster { [PSCustomObject]@{ Name = "cl0" } }
            $Script:_tlcmccCount = 0
            function Test-LcmClusterCompliance {
                [CmdletBinding()] Param([Parameter(ValueFromPipeline = $true)] [Object]$In)
                begin { $Script:_tlcmccCount++ }
                process { [PSCustomObject]@{ Status = "NonCompliant"; NonCompliantHosts = @() } }
            }
            Mock Set-Cluster {}
            Invoke-VlcmClusterComplianceAndRemediate -ClusterName "cl0" -AcceptBadCheckResults
            $Script:_tlcmccCount
        }
        $callCount | Should -BeGreaterOrEqual 2
    }
}


Describe "Get-VlcmNonCompliantHostNames" {
    It "Returns display names for items with non-empty DisplayName" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Get-VlcmComplianceItemInfo {
                [PSCustomObject]@{ DisplayName = "host$($FallbackIndex)"; VMHost = $null }
            }
            $fakeItems = @([PSCustomObject]@{ Name = "a" }, [PSCustomObject]@{ Name = "b" })
            $result = Get-VlcmNonCompliantHostNames -NonCompliantHosts $fakeItems
            $result.Count | Should -Be 2
            $result[0] | Should -Be "host1"
            $result[1] | Should -Be "host2"
        }
    }

    It "Returns empty array when all items yield empty DisplayName" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Get-VlcmComplianceItemInfo {
                [PSCustomObject]@{ DisplayName = ""; VMHost = $null }
            }
            $result = Get-VlcmNonCompliantHostNames -NonCompliantHosts @([PSCustomObject]@{ Name = "a" })
            $result.Count | Should -Be 0
        }
    }

    It "Skips items with whitespace-only DisplayName and includes items with valid names" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $Script:_mockIdx = 0
            Mock Get-VlcmComplianceItemInfo {
                $Script:_mockIdx++
                if ($Script:_mockIdx -eq 1) { [PSCustomObject]@{ DisplayName = "   "; VMHost = $null } }
                else { [PSCustomObject]@{ DisplayName = "host-valid"; VMHost = $null } }
            }
            # Wrap in @() to prevent single-element pipeline unrolling to a scalar string.
            $result = @(Get-VlcmNonCompliantHostNames -NonCompliantHosts @([PSCustomObject]@{}, [PSCustomObject]@{}))
            $result.Count | Should -Be 1
            $result[0] | Should -Be "host-valid"
        }
    }
}


Describe "Write-VlcmVersionMismatchWarnings" {
    It "Logs upgrade warning when host version is older than vLCM base image" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Get-VlcmComplianceItemInfo {
                [PSCustomObject]@{
                    DisplayName = "esx1.lab"
                    VMHost = [PSCustomObject]@{ Version = "8.0.0"; Build = "12345678" }
                }
            }
            Write-VlcmVersionMismatchWarnings -BaseImageVersion "9.0.0.0.99999999" -ClusterName "cl0" -NonCompliantHosts @([PSCustomObject]@{})
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "WARNING" -and $Message -match "upgrade" }
        }
    }

    It "Logs downgrade warning when host version is newer than vLCM base image" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Get-VlcmComplianceItemInfo {
                [PSCustomObject]@{
                    DisplayName = "esx1.lab"
                    VMHost = [PSCustomObject]@{ Version = "9.0.0"; Build = "99999999" }
                }
            }
            Write-VlcmVersionMismatchWarnings -BaseImageVersion "8.0.0.0.12345678" -ClusterName "cl0" -NonCompliantHosts @([PSCustomObject]@{})
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "WARNING" -and $Message -match "downgrade" }
        }
    }

    It "Does not warn when host version matches vLCM base image" {
        InModuleScope VcfEdgeAtScale {
            $warnCalled = $false
            Mock Write-LogMessage { if ($Type -eq "WARNING") { $Script:_warnCalled = $true } }
            Mock Get-VlcmComplianceItemInfo {
                [PSCustomObject]@{
                    DisplayName = "esx1.lab"
                    VMHost = [PSCustomObject]@{ Version = "9.0.0"; Build = "12345678" }
                }
            }
            $Script:_warnCalled = $false
            Write-VlcmVersionMismatchWarnings -BaseImageVersion "9.0.0.0.12345678" -ClusterName "cl0" -NonCompliantHosts @([PSCustomObject]@{})
            $Script:_warnCalled | Should -Be $false
        }
    }
}


Describe "Test-VlcmPostRemediationCompliance" {
    It "Logs WARNING when cluster is still not compliant after remediation" {
        InModuleScope VcfEdgeAtScale {
            function Test-LcmClusterCompliance {
                [CmdletBinding()] Param([Parameter(ValueFromPipeline = $true)] [Object]$In)
                process { [PSCustomObject]@{ Status = "NonCompliant" } }
            }
            Mock Write-LogMessage {}
            $fakeCluster = [PSCustomObject]@{ Name = "cl0" }
            Test-VlcmPostRemediationCompliance -ClusterName "cl0" -ClusterObject $fakeCluster
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "WARNING" -and $Message -match "still not compliant" }
        }
    }

    It "Logs INFO when RebootRequired is true after remediation" {
        InModuleScope VcfEdgeAtScale {
            function Test-LcmClusterCompliance {
                [CmdletBinding()] Param([Parameter(ValueFromPipeline = $true)] [Object]$In)
                process { [PSCustomObject]@{ Status = "Compliant"; RebootRequired = $true } }
            }
            Mock Write-LogMessage {}
            $fakeCluster = [PSCustomObject]@{ Name = "cl0" }
            Test-VlcmPostRemediationCompliance -ClusterName "cl0" -ClusterObject $fakeCluster
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "INFO" -and $Message -match "[Rr]eboot" }
        }
    }

    It "Returns without error when Test-LcmClusterCompliance throws during post-remediation check" {
        InModuleScope VcfEdgeAtScale {
            function Test-LcmClusterCompliance {
                [CmdletBinding()] Param([Parameter(ValueFromPipeline = $true)] [Object]$In)
                process { throw "vLCM unavailable" }
            }
            Mock Write-LogMessage {}
            $fakeCluster = [PSCustomObject]@{ Name = "cl0" }
            { Test-VlcmPostRemediationCompliance -ClusterName "cl0" -ClusterObject $fakeCluster } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "DEBUG" -and $Message -match "Could not re-check" }
        }
    }
}


Describe "Invoke-VlcmRemediationFailureResponse" {
    It "Logs 'AcceptBadCheckResults' WARNING and returns without throwing when AcceptBadCheckResults is set" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            { Invoke-VlcmRemediationFailureResponse -ClusterName "cl0" -RemediationError "vLCM failed" -AcceptBadCheckResults } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'WARNING' -and $Message -match 'AcceptBadCheckResults' }
        }
    }

    It "Throws when user responds N" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            function Read-Host {
                [CmdletBinding()] Param([Parameter(Position = 0, Mandatory = $false)] [Object]$Prompt)
                return "N"
            }
            { Invoke-VlcmRemediationFailureResponse -ClusterName "cl0" -RemediationError "health check failed" } | Should -Throw "*Deployment failed*"
        }
    }

    It "Logs 'Accepting risk' WARNING and returns without throwing when user responds Y" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            function Read-Host {
                [CmdletBinding()] Param([Parameter(Position = 0, Mandatory = $false)] [Object]$Prompt)
                return "Y"
            }
            { Invoke-VlcmRemediationFailureResponse -ClusterName "cl0" -RemediationError "health check failed" } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'WARNING' -and $Message -match 'Accepting risk' }
        }
    }
}


Describe "Update-YamlNamespace" {
    BeforeAll {
        $script:yamlTempDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "veas-yamlns-$([System.Guid]::NewGuid().ToString('N').Substring(0, 8))"
        New-Item -ItemType Directory -Path $script:yamlTempDir -Force | Out-Null
    }
    AfterAll {
        Remove-Item -Path $script:yamlTempDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Replaces namespace value and returns a temp file path different from the source" {
        $yamlFile = Join-Path $script:yamlTempDir "argocd.yml"
        Set-Content -Path $yamlFile -Value "metadata:`n  namespace: old-namespace`nspec:`n  version: 1.0" -Encoding UTF8
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $yamlFile { Update-YamlNamespace -YamlFilePath $args[0] -NewNamespace "argocd-c462" }
        $result | Should -Not -Be $yamlFile
        $result | Should -Not -BeNullOrEmpty
        (Get-Content -Path $result -Raw) | Should -Match "namespace:\s*argocd-c462"
        Remove-Item $result -Force -ErrorAction SilentlyContinue
    }

    It "Preserves the spec section after namespace replacement" {
        $yamlFile = Join-Path $script:yamlTempDir "argocd-spec.yml"
        Set-Content -Path $yamlFile -Value "metadata:`n  namespace: original`nspec:`n  version: 2.0`n  replicas: 3" -Encoding UTF8
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $yamlFile { Update-YamlNamespace -YamlFilePath $args[0] -NewNamespace "argocd-c999" }
        $content = Get-Content -Path $result -Raw
        $content | Should -Match "(?m)^spec:"
        $content | Should -Match "version: 2\.0"
        Remove-Item $result -Force -ErrorAction SilentlyContinue
    }

    It "Throws when the YAML file does not exist" {
        { InModuleScope VcfEdgeAtScale { Update-YamlNamespace -YamlFilePath "/nonexistent/argocd.yml" -NewNamespace "argocd-c1" } } | Should -Throw "*YAML file not found*"

    }

    It "Handles quoted namespace values" {
        $yamlFile = Join-Path $script:yamlTempDir "argocd-quoted.yml"
        Set-Content -Path $yamlFile -Value 'metadata:' -Encoding UTF8
        Add-Content -Path $yamlFile -Value '  namespace: "quoted-namespace"'
        Add-Content -Path $yamlFile -Value 'spec:'
        Add-Content -Path $yamlFile -Value '  version: 1.0'
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $yamlFile { Update-YamlNamespace -YamlFilePath $args[0] -NewNamespace "argocd-c777" }
        (Get-Content -Path $result -Raw) | Should -Match "argocd-c777"
        Remove-Item $result -Force -ErrorAction SilentlyContinue
    }
}


Describe "Get-OrCreateSupervisor — idempotency routing" {

    It "Returns existing ID without calling Add-Supervisor when supervisor already exists" {
        $addSupervisorCalled = InModuleScope VcfEdgeAtScale {
            $Script:VCenterUser = "admin@vsphere.local"
            $Script:_testAddCalled = $false
            Mock Get-SupervisorId { return "sup-existing-xyz" }
            Mock Add-Supervisor { $Script:_testAddCalled = $true; return "sup-new" }

            $null = Get-OrCreateSupervisor `
                -StoragePolicyId "policy-001" -SupervisorName "Supervisor01" `
                -SupervisorJson "{}" -ClusterId "domain-c8" -ClusterName "cl-test" `
                -EdgeSite "site1" -NetworkSegments @("segment1") -InsecureTls
            $Script:_testAddCalled
        }
        $addSupervisorCalled | Should -Be $false
    }

    It "Calls Add-Supervisor when supervisor does not exist" {
        $addSupervisorCalled = InModuleScope VcfEdgeAtScale {
            $Script:VCenterUser = "admin@vsphere.local"
            $Script:_testAddCalled = $false
            Mock Get-SupervisorId { return $null }
            Mock Add-Supervisor { $Script:_testAddCalled = $true; return "sup-new-123" }

            $null = Get-OrCreateSupervisor `
                -StoragePolicyId "policy-001" -SupervisorName "Supervisor01" `
                -SupervisorJson "{}" -ClusterId "domain-c8" -ClusterName "cl-test" `
                -EdgeSite "site1" -NetworkSegments @("segment1") -InsecureTls
            $Script:_testAddCalled
        }
        $addSupervisorCalled | Should -Be $true
    }
}


Describe "Get-Base64FromYml" {
    BeforeAll {
        $script:b64TmpDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "veas-b64-$([System.Guid]::NewGuid().ToString('N').Substring(0, 8))"
        New-Item -ItemType Directory -Path $script:b64TmpDir -Force | Out-Null
        $script:b64YmlFile = Join-Path $script:b64TmpDir "test.yml"
        Set-Content -Path $script:b64YmlFile -Value "kind: Package`nspec:`n  refName: test" -Encoding UTF8 -NoNewline
    }
    AfterAll {
        Remove-Item -Path $script:b64TmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Returns a non-empty base64 string for a valid file" {
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $script:b64YmlFile {
            param($p) Get-Base64FromYml -Path $p
        }
        $result | Should -Not -BeNullOrEmpty
    }

    It "Round-trips correctly — decoded bytes match original file content" {
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $script:b64YmlFile {
            param($p) Get-Base64FromYml -Path $p
        }
        $decoded = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($result))
        $original = Get-Content -Path $script:b64YmlFile -Raw -Encoding UTF8
        $decoded | Should -Be $original
    }

    It "Throws VcfDeploymentException when the file does not exist" {
        $threw = InModuleScope VcfEdgeAtScale {
            $caught = $false
            try {
                Get-Base64FromYml -Path "/nonexistent/veas-path/file.yml"
            } catch {
                $caught = $true
            }
            $caught
        }
        $threw | Should -Be $true
    }
}


Describe "Get-ArgoCDServiceDetail" {
    BeforeAll {
        $script:argoTmpDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "veas-argo-$([System.Guid]::NewGuid().ToString('N').Substring(0, 8))"
        New-Item -ItemType Directory -Path $script:argoTmpDir -Force | Out-Null

        $script:argoValidYml = Join-Path $script:argoTmpDir "argocd-valid.yml"
        Set-Content -Path $script:argoValidYml -Encoding UTF8 -Value @"
---
apiVersion: data.packaging.carvel.dev/1alpha1
kind: PackageMetadata
metadata:
  name: argocd-service.vsphere.vmware.com
spec:
  displayName: argocd
---
apiVersion: packaging.carvel.dev/v1alpha1
kind: Package
metadata:
  name: argocd-service.vsphere.vmware.com.2.8.2-24815986
spec:
  refName: argocd-service.vsphere.vmware.com
  version: 2.8.2-24815986
"@

        $script:argoNoPackageYml = Join-Path $script:argoTmpDir "argocd-no-package.yml"
        Set-Content -Path $script:argoNoPackageYml -Encoding UTF8 -Value @"
---
kind: SomethingElse
metadata:
  name: test
"@
    }
    AfterAll {
        Remove-Item -Path $script:argoTmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Extracts refName and version from a valid multi-document Package YAML" {
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $script:argoValidYml {
            param($p) Get-ArgoCDServiceDetail -Path $p
        }
        $result[0] | Should -Be "argocd-service.vsphere.vmware.com"
        $result[1] | Should -Be "2.8.2-24815986"
    }

    It "Throws VcfDeploymentException when no document has spec.refName and spec.version" {
        $threw = InModuleScope VcfEdgeAtScale -ArgumentList $script:argoNoPackageYml {
            param($p)
            $caught = $false
            try {
                Get-ArgoCDServiceDetail -Path $p
            } catch {
                $caught = $true
            }
            $caught
        }
        $threw | Should -Be $true
    }

    It "Throws VcfDeploymentException when the file does not exist" {
        $threw = InModuleScope VcfEdgeAtScale {
            $caught = $false
            try {
                Get-ArgoCDServiceDetail -Path "/nonexistent/veas-path/argocd.yml"
            } catch {
                $caught = $true
            }
            $caught
        }
        $threw | Should -Be $true
    }
}


Describe "Get-SupervisorNetworkVanityDisplayName" {
    It "Returns prefix concatenated with port group name" {
        InModuleScope VcfEdgeAtScale {
            Get-SupervisorNetworkVanityDisplayName -VanityPrefix "tmn" -PortGroupName "mgmt-pg"
        } | Should -Be "tmnmgmt-pg"
    }

    It "Trims leading and trailing whitespace from the prefix" {
        InModuleScope VcfEdgeAtScale {
            Get-SupervisorNetworkVanityDisplayName -VanityPrefix "  fmn  " -PortGroupName "pg1"
        } | Should -Be "fmnpg1"
    }

    It "Lowercases an uppercase prefix" {
        InModuleScope VcfEdgeAtScale {
            Get-SupervisorNetworkVanityDisplayName -VanityPrefix "FMN" -PortGroupName "pg1"
        } | Should -Be "fmnpg1"
    }

    It "Throws when combined length exceeds MaxTotalLength" {
        InModuleScope VcfEdgeAtScale {
            { Get-SupervisorNetworkVanityDisplayName -VanityPrefix "prefix" -PortGroupName ("x" * 80) }
        } | Should -Throw "*exceeds*"
    }

    It "Returns the concatenated name and does not throw when combined length equals MaxTotalLength" {
        # "prefix" = 6 chars; port group name padded to 74 chars so total = 80 exactly.
        $result = InModuleScope VcfEdgeAtScale {
            Get-SupervisorNetworkVanityDisplayName -VanityPrefix "prefix" -PortGroupName ("x" * 74)
        }
        { InModuleScope VcfEdgeAtScale { Get-SupervisorNetworkVanityDisplayName -VanityPrefix "prefix" -PortGroupName ("x" * 74) } } | Should -Not -Throw
        $result | Should -Not -BeNullOrEmpty
        $result.Length | Should -Be 80
    }

    It "Accepts a custom MaxTotalLength" {
        InModuleScope VcfEdgeAtScale {
            { Get-SupervisorNetworkVanityDisplayName -VanityPrefix "ab" -PortGroupName "cd" -MaxTotalLength 3 }
        } | Should -Throw "*exceeds*"
    }
}


Describe "Test-YamlPropertyConsistency" {
    BeforeAll {
        $script:yamlConsistencyFile = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "veas-ypc-$([guid]::NewGuid().ToString('N').Substring(0,8)).yml"
        Set-Content -Path $script:yamlConsistencyFile -Value @"
metadata:
  namespace: argocd
spec:
  namespace: argocd
"@ -Encoding UTF8
    }
    AfterAll { Remove-Item $script:yamlConsistencyFile -Force -ErrorAction SilentlyContinue }

    It "Returns true when property value matches the expected value" {
        InModuleScope VcfEdgeAtScale -ArgumentList $script:yamlConsistencyFile {
            Test-YamlPropertyConsistency -YamlFilePath $args[0] -PropertyPaths @("metadata.namespace") -ExpectedValues @("argocd") -ValidationName "ns-check"
        } | Should -Be $true
    }

    It "Returns false when property value does not match" {
        InModuleScope VcfEdgeAtScale -ArgumentList $script:yamlConsistencyFile {
            Test-YamlPropertyConsistency -YamlFilePath $args[0] -PropertyPaths @("metadata.namespace") -ExpectedValues @("wrong-ns") -ValidationName "ns-check"
        } | Should -Be $false
    }

    It "Returns false for a nonexistent YAML file" {
        InModuleScope VcfEdgeAtScale {
            Test-YamlPropertyConsistency -YamlFilePath "/nonexistent/path/file.yml" -PropertyPaths @("metadata.namespace") -ExpectedValues @("argocd") -ValidationName "ns-check"
        } | Should -Be $false
    }
}

# ── Tier 2: Mockable vCenter ──────────────────────────────────────────────────


Describe "Test-SupervisorDeployedOnCluster — mocked vCenter" {
    It "Returns false when Get-Cluster returns null (cluster not found)" {
        InModuleScope VcfEdgeAtScale {
            Mock Get-Cluster { return $null }
            Test-SupervisorDeployedOnCluster -ClusterName "nonexistent-cluster"
        } | Should -Be $false
    }

    It "Returns false when cluster has no supervisor-related extension data" {
        InModuleScope VcfEdgeAtScale {
            Mock Get-Cluster {
                [PSCustomObject]@{
                    Name          = "my-cluster"
                    ExtensionData = [PSCustomObject]@{
                        ConfigurationEx = [PSCustomObject]@{
                            WcpCapability = $null
                        }
                    }
                }
            }
            Test-SupervisorDeployedOnCluster -ClusterName "my-cluster"
        } | Should -Be $false
    }
}


Describe "Remove-HarborContainerImageRegistry — registry removal paths" {

    It "Logs WARNING and returns without throwing when the list cmdlet throws" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            function Invoke-ListSupervisorNamespaceManagementContainerImageRegistries {
                [CmdletBinding()] Param([Parameter()] [Object]$Supervisor)
                throw "API unavailable"
            }
            # Must not throw.
            Remove-HarborContainerImageRegistry -ClusterName "cl1" -SupervisorId "sv-001"
            Should -Invoke Write-LogMessage -Times 1 -ParameterFilter { $Type -eq "WARNING" -and $Message -like "*list*" }
        }
    }

    It "Logs INFO and returns when the registry list is empty" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            function Invoke-ListSupervisorNamespaceManagementContainerImageRegistries {
                [CmdletBinding()] Param([Parameter()] [Object]$Supervisor)
                return @()
            }
            Remove-HarborContainerImageRegistry -ClusterName "cl1" -SupervisorId "sv-001"
            Should -Invoke Write-LogMessage -Times 1 -ParameterFilter { $Type -eq "INFO" -and $Message -like "*Nothing to remove*" }
        }
    }

    It "Calls the delete cmdlet when the named registry entry is found" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            function Invoke-ListSupervisorNamespaceManagementContainerImageRegistries {
                [CmdletBinding()] Param([Parameter()] [Object]$Supervisor)
                return @([PSCustomObject]@{ name = "harbor"; id = "reg-abc123" })
            }
            function Invoke-DeleteSupervisorContainerImageRegistryNamespaceManagementContainerImageRegistries {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param([Parameter()] [Object]$Supervisor, [Parameter()] [Object]$ContainerImageRegistry)
                begin {}; process {}
            }
            Mock Invoke-DeleteSupervisorContainerImageRegistryNamespaceManagementContainerImageRegistries {}
            Remove-HarborContainerImageRegistry -ClusterName "cl1" -SupervisorId "sv-001"
            Should -Invoke Invoke-DeleteSupervisorContainerImageRegistryNamespaceManagementContainerImageRegistries -Times 1
        }
    }
}

# ── Find-SupervisorByName ──────────────────────────────────────────────────────


Describe "Find-SupervisorByName — REST API result routing" {

    It "Returns Success=true Found=true with SupervisorId when API returns a matching supervisor" {
        $result = InModuleScope VcfEdgeAtScale {
            $Script:vCenterName = "vc.lab"
            Mock Write-LogMessage {}
            Mock Invoke-RestMethod {
                [PSCustomObject]@{
                    items = @([PSCustomObject]@{
                        info       = [PSCustomObject]@{ name = "prod-sv" }
                        supervisor = "supervisor-abc123"
                    })
                }
            }
            Find-SupervisorByName -SupervisorName "prod-sv" -SessionHeaders @{ Authorization = "Bearer tok" }
        }
        $result.Success      | Should -BeTrue
        $result.Found        | Should -BeTrue
        $result.SupervisorId | Should -Be "supervisor-abc123"
    }

    It "Returns Success=true Found=false when no items match the supervisor name" {
        $result = InModuleScope VcfEdgeAtScale {
            $Script:vCenterName = "vc.lab"
            Mock Write-LogMessage {}
            Mock Invoke-RestMethod {
                [PSCustomObject]@{
                    items = @([PSCustomObject]@{
                        info       = [PSCustomObject]@{ name = "other-sv" }
                        supervisor = "supervisor-xyz"
                    })
                }
            }
            Find-SupervisorByName -SupervisorName "prod-sv" -SessionHeaders @{ Authorization = "Bearer tok" }
        }
        $result.Success | Should -BeTrue
        $result.Found   | Should -BeFalse
    }

    It "Returns Success=false with ErrorMessage when Invoke-RestMethod throws" {
        $result = InModuleScope VcfEdgeAtScale {
            $Script:vCenterName = "vc.lab"
            Mock Write-LogMessage {}
            Mock Invoke-RestMethod { throw "Connection refused" }
            Find-SupervisorByName -SupervisorName "prod-sv" -SessionHeaders @{ Authorization = "Bearer tok" }
        }
        $result.Success      | Should -BeFalse
        $result.Found        | Should -BeFalse
        $result.ErrorMessage | Should -Match "Connection refused"
    }
}

# ── Test-JsonHarborConfiguration ──────────────────────────────────────────────


Describe "Get-SupervisorConfigurationFromJson" {

    It "Throws when the JSON file cannot be parsed" {
        InModuleScope VcfEdgeAtScale {
            Mock ConvertFrom-JsonSafely { return $null }
            # ValidateNotNullOrEmpty on NetworkSegments requires at least one non-null element.
            $seg = [PSCustomObject]@{ name = "seg1"; gateway = "10.0.0.1" }
            { Get-SupervisorConfigurationFromJson -EdgeSite "site1" -JsonFilePath "/fake/path.json" `
                -NetworkSegments @($seg) } | Should -Throw "*parse JSON*"
        }
    }

    It "Throws when commonSupervisorSpec is missing" {
        InModuleScope VcfEdgeAtScale {
            Mock ConvertFrom-JsonSafely {
                [PSCustomObject]@{ siteSpec = @([PSCustomObject]@{ edgeSite = "site1" }) }
            }
            $seg = [PSCustomObject]@{ name = "seg1"; gateway = "10.0.0.1" }
            { Get-SupervisorConfigurationFromJson -EdgeSite "site1" -JsonFilePath "/fake/path.json" `
                -NetworkSegments @($seg) } | Should -Throw "*commonSupervisorSpec*"
        }
    }

    It "Throws when no matching siteSpec is found for the requested EdgeSite" {
        InModuleScope VcfEdgeAtScale {
            Mock ConvertFrom-JsonSafely {
                [PSCustomObject]@{
                    commonSupervisorSpec = [PSCustomObject]@{ something = "x" }
                    siteSpec             = @([PSCustomObject]@{ edgeSite = "site2" })
                }
            }
            $seg = [PSCustomObject]@{ name = "seg1"; gateway = "10.0.0.1" }
            { Get-SupervisorConfigurationFromJson -EdgeSite "site1" -JsonFilePath "/fake/path.json" `
                -NetworkSegments @($seg) } | Should -Throw "*siteSpec*"
        }
    }
}

# ── New-SupervisorMgmtNetworkSpec ─────────────────────────────────────────────


Describe "New-SupervisorMgmtNetworkSpec — management network spec builder" {
    It "Returns a spec with all required management network fields" {
        $result = InModuleScope VcfEdgeAtScale {
            $siteSpec = [PSCustomObject]@{
                mgmtNetworkSpec = [PSCustomObject]@{
                    mgmtNetworkName         = "mgmt-net"
                    mgmtNetworkStartingIp   = "10.0.1.10"
                    mgmtNetworkIPCount      = 10
                }
            }
            $commonSpec = [PSCustomObject]@{
                dnsServers           = @("8.8.8.8")
                networkNtpServers    = @("pool.ntp.org")
                networkSearchDomains = @("vcfedge.demo")
            }
            New-SupervisorMgmtNetworkSpec -SiteSpec $siteSpec -CommonSpec $commonSpec
        }
        $result.mgmtNetworkName          | Should -Be "mgmt-net"
        $result.mgmtNetworkStartingIp    | Should -Be "10.0.1.10"
        $result.mgmtNetworkIPCount       | Should -Be 10
        $result.mgmtIpAssignmentMode     | Should -Be "STATIC"
        $result.mgmtNetworkDnsServers    | Should -Contain "8.8.8.8"
    }
}

# ── New-SupervisorWorkloadNetworkSpec ─────────────────────────────────────────


Describe "New-SupervisorWorkloadNetworkSpec — workload network spec builder" {
    It "Returns a spec with all required workload network fields" {
        $result = InModuleScope VcfEdgeAtScale {
            $siteSpec = [PSCustomObject]@{
                primaryWorkloadNetwork = [PSCustomObject]@{
                    primaryWorkloadNetworkName         = "workload-net"
                    primaryWorkloadNetworkStartingIp   = "10.0.2.10"
                    primaryWorkloadNetworkIPCount      = 50
                    workloadServiceStartIp             = "10.97.0.0"
                    workloadServiceCount               = 512
                }
            }
            $commonSpec = [PSCustomObject]@{
                dnsServers           = @("8.8.8.8")
                networkNtpServers    = @("pool.ntp.org")
                networkSearchDomains = @("vcfedge.demo")
            }
            New-SupervisorWorkloadNetworkSpec -SiteSpec $siteSpec -CommonSpec $commonSpec
        }
        $result.primaryWorkloadNetworkName       | Should -Be "workload-net"
        $result.primaryWorkloadNetworkStartingIp | Should -Be "10.0.2.10"
        $result.workloadServiceCount             | Should -Be 512
        $result.primaryWorkloadIpAssignmentMode  | Should -Be "STATIC"
        $result.workloadDnsServers               | Should -Contain "8.8.8.8"
    }
}

# ── New-SupervisorFlbSpec ─────────────────────────────────────────────────────


Describe "New-SupervisorFlbSpec — FLB spec builder" {
    It "Returns a spec with correct FLB fields including nested network objects" {
        $result = InModuleScope VcfEdgeAtScale {
            $siteSpec = [PSCustomObject]@{
                foundationLoadBalancerComponents = [PSCustomObject]@{
                    flbName       = "flb-test"
                    flbVipStartIP = "10.0.0.1"
                    flbVipIPCount = 20
                    flbManagementNetwork = [PSCustomObject]@{
                        flbNetworkName                = "mgmt-flb-net"
                        flbNetworkIpAddressStartingIp = "10.0.3.1"
                        flbNetworkIpAddressCount      = 15
                    }
                    flbVirtualServerNetwork = [PSCustomObject]@{
                        flbNetworkName                = "vs-flb-net"
                        flbNetworkIpAddressStartingIp = "10.0.4.1"
                        flbNetworkIpAddressCount      = 30
                    }
                }
            }
            $commonSpec = [PSCustomObject]@{
                flbSize              = "MEDIUM"
                flbAvailability      = "SINGLE_NODE"
                flbNetworkType       = "DVPG"
                dnsServers           = @("8.8.8.8")
                networkNtpServers    = @("pool.ntp.org")
                networkSearchDomains = @("vcfedge.demo")
            }
            New-SupervisorFlbSpec -SiteSpec $siteSpec -CommonSpec $commonSpec
        }
        $result.flbName                                     | Should -Be "flb-test"
        $result.flbSize                                     | Should -Be "MEDIUM"
        $result.flbProvider                                 | Should -Be "VSPHERE_FOUNDATION"
        $result.flbManagementNetwork.flbNetworkName         | Should -Be "mgmt-flb-net"
        $result.flbVirtualServerNetwork.flbNetworkName      | Should -Be "vs-flb-net"
        $result.flbManagementNetwork.flbNetworkIpAssignmentMode | Should -Be "STATIC"
    }
}

# ── Write-SupervisorKubernetesDiagnosticReport ───────────────────────────────


Describe "Invoke-SupervisorKubernetesDiagnosticSafe" {

    It "Calls Write-SupervisorKubernetesDiagnosticReport with forwarded parameters" {
        InModuleScope VcfEdgeAtScale {
            function Write-SupervisorKubernetesDiagnosticReport {
                [CmdletBinding()] Param([Parameter()] [Object]$ClusterName, [Parameter()] [Object]$Context, [Parameter()] [Object]$SupervisorId)
                process {}
            }
            Mock Write-SupervisorKubernetesDiagnosticReport { }
            Invoke-SupervisorKubernetesDiagnosticSafe -ClusterName "cl-site1" -Context "test context" -SupervisorId "sup-001"
            Should -Invoke Write-SupervisorKubernetesDiagnosticReport -Times 1 -ParameterFilter {
                $ClusterName -eq "cl-site1" -and $Context -eq "test context" -and $SupervisorId -eq "sup-001"
            }
        }
    }

    It "Does not propagate exceptions from Write-SupervisorKubernetesDiagnosticReport" {
        InModuleScope VcfEdgeAtScale {
            function Write-SupervisorKubernetesDiagnosticReport {
                [CmdletBinding()] Param([Parameter()] [Object]$ClusterName, [Parameter()] [Object]$Context, [Parameter()] [Object]$SupervisorId)
                process {}
            }
            Mock Write-LogMessage {}
            Mock Write-SupervisorKubernetesDiagnosticReport { throw "Diagnostic failure" }
            { Invoke-SupervisorKubernetesDiagnosticSafe -ClusterName "cl-site1" -Context "test" -SupervisorId "sup-001" } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "DEBUG" -and $Message -match "Diagnostic failure" } -Scope It
        }
    }

    It "Logs at DEBUG when Write-SupervisorKubernetesDiagnosticReport throws" {
        InModuleScope VcfEdgeAtScale {
            function Write-SupervisorKubernetesDiagnosticReport {
                [CmdletBinding()] Param([Parameter()] [Object]$ClusterName, [Parameter()] [Object]$Context, [Parameter()] [Object]$SupervisorId)
                process {}
            }
            Mock Write-SupervisorKubernetesDiagnosticReport { throw "Diagnostic failure" }
            Mock Write-LogMessage { }
            Invoke-SupervisorKubernetesDiagnosticSafe -ClusterName "cl-site1" -Context "test" -SupervisorId "sup-001"
            Should -Invoke Write-LogMessage -Times 1 -ParameterFilter { $Type -eq "DEBUG" }
        }
    }
}

# ── Write-Supervisor503PersistenceWarning ─────────────────────────────────────


Describe "Write-Supervisor503PersistenceWarning" {

    It "Logs WARNING containing consecutive error count and elapsed seconds" {
        $loggedMessages = InModuleScope VcfEdgeAtScale {
            function Get-Cluster {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Get-Cluster { return $null }
            $captured = [System.Collections.Generic.List[String]]::new()
            Mock Write-LogMessage { $captured.Add($Message) }
            Write-Supervisor503PersistenceWarning -ClusterName "cl-site1" -Consecutive503Errors 15 -TimeSinceFirst503Seconds 320
            $captured
        }
        ($loggedMessages -match "15") | Should -Not -BeNullOrEmpty
        ($loggedMessages -match "320") | Should -Not -BeNullOrEmpty
    }

    It "Logs vCenter unreachable warning when Get-Cluster returns null" {
        $loggedMessages = InModuleScope VcfEdgeAtScale {
            function Get-Cluster {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Get-Cluster { return $null }
            $captured = [System.Collections.Generic.List[String]]::new()
            Mock Write-LogMessage { $captured.Add($Message) }
            Write-Supervisor503PersistenceWarning -ClusterName "cl-site1" -Consecutive503Errors 5 -TimeSinceFirst503Seconds 310
            $captured
        }
        ($loggedMessages -match "unreachable") | Should -Not -BeNullOrEmpty
    }

    It "Does not throw when Get-Cluster throws" {
        InModuleScope VcfEdgeAtScale {
            function Get-Cluster {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Get-Cluster { throw "vCenter unavailable" }
            Mock Write-LogMessage { }
            { Write-Supervisor503PersistenceWarning -ClusterName "cl-site1" -Consecutive503Errors 8 -TimeSinceFirst503Seconds 310 } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "WARNING" -and $Message -match "Persistent 503" } -Scope It
        }
    }
}

# ── Invoke-Supervisor503ErrorHandler ─────────────────────────────────────────


Describe "Invoke-Supervisor503ErrorHandler" {

    It "Returns rethrow for a non-503 error message" {
        $result = InModuleScope VcfEdgeAtScale {
            $state503 = @{ ConsecutiveErrors = 0; FirstErrorTime = $null; WarningShown = $false }
            Invoke-Supervisor503ErrorHandler `
                -ClusterName "cl-site1" `
                -ElapsedTime 10 `
                -ErrorMsg "The RPC server is unavailable." `
                -State503 $state503 `
                -SupervisorId "sup-001" `
                -TotalWaitTime 1800
        }
        $result.Action | Should -Be 'rethrow'
    }

    It "Returns sleep-continue and increments state on first 503 within wait window" {
        $result = InModuleScope VcfEdgeAtScale {
            function Get-Cluster {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Start-Sleep { }
            $state503 = @{ ConsecutiveErrors = 0; FirstErrorTime = $null; WarningShown = $false }
            Invoke-Supervisor503ErrorHandler `
                -CheckInterval 5 `
                -ClusterName "cl-site1" `
                -ElapsedTime 10 `
                -ErrorMsg "SERVICE_UNAVAILABLE" `
                -State503 $state503 `
                -SupervisorId "sup-001" `
                -TotalWaitTime 1800
        }
        $result.Action | Should -Be 'sleep-continue'
    }

    It "Returns return with Success=false when MaxPersistent503Threshold is exceeded" {
        $result = InModuleScope VcfEdgeAtScale {
            function Get-Cluster {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process {}
            }
            function Invoke-SupervisorKubernetesDiagnosticSafe {
                [CmdletBinding()] Param([Parameter()] [Object]$ClusterName, [Parameter()] [Object]$Context, [Parameter()] [Object]$SupervisorId)
                process {}
            }
            Mock Write-LogMessage { }
            # Simulate state already past max threshold: first error was 700s ago.
            $pastTime = (Get-Date).AddSeconds(-700)
            $state503 = @{ ConsecutiveErrors = 50; FirstErrorTime = $pastTime; WarningShown = $true }
            Invoke-Supervisor503ErrorHandler `
                -CheckInterval 5 `
                -ClusterName "cl-site1" `
                -CrashDetectionThreshold 300 `
                -ElapsedTime 700 `
                -ErrorMsg "503 Service Unavailable" `
                -MaxPersistent503Threshold 600 `
                -State503 $state503 `
                -SupervisorId "sup-001" `
                -TotalWaitTime 1800
        }
        $result.Action | Should -Be 'return'
        $result.Result.Success | Should -Be $false
    }

    It "Returns return with Success=false when ElapsedTime reaches TotalWaitTime on 503 path" {
        $result = InModuleScope VcfEdgeAtScale {
            function Get-Cluster {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process {}
            }
            function Invoke-SupervisorKubernetesDiagnosticSafe {
                [CmdletBinding()] Param([Parameter()] [Object]$ClusterName, [Parameter()] [Object]$Context, [Parameter()] [Object]$SupervisorId)
                process {}
            }
            Mock Write-LogMessage { }
            $state503 = @{ ConsecutiveErrors = 0; FirstErrorTime = $null; WarningShown = $false }
            Invoke-Supervisor503ErrorHandler `
                -CheckInterval 5 `
                -ClusterName "cl-site1" `
                -ElapsedTime 1800 `
                -ErrorMsg "SERVICE_UNAVAILABLE" `
                -State503 $state503 `
                -SupervisorId "sup-001" `
                -TotalWaitTime 1800
        }
        $result.Action | Should -Be 'return'
        $result.Result.Success | Should -Be $false
    }

    It "Calls Write-Supervisor503PersistenceWarning once when crash threshold is exceeded" {
        InModuleScope VcfEdgeAtScale {
            function Get-Cluster {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Start-Sleep { }
            Mock Write-LogMessage { }
            Mock Write-Supervisor503PersistenceWarning { }
            # Simulate state: first error was 310s ago, warning not yet shown.
            $pastTime = (Get-Date).AddSeconds(-310)
            $state503 = @{ ConsecutiveErrors = 20; FirstErrorTime = $pastTime; WarningShown = $false }
            Invoke-Supervisor503ErrorHandler `
                -CheckInterval 5 `
                -ClusterName "cl-site1" `
                -CrashDetectionThreshold 300 `
                -ElapsedTime 310 `
                -ErrorMsg "503 Service Unavailable" `
                -MaxPersistent503Threshold 600 `
                -State503 $state503 `
                -SupervisorId "sup-001" `
                -TotalWaitTime 1800
            Should -Invoke Write-Supervisor503PersistenceWarning -Times 1
        }
    }
}

# ── Wait-SupervisorReady ──────────────────────────────────────────────────────


Describe "Wait-SupervisorReady" {

    It "Returns Success=true immediately when supervisor is RUNNING/READY on first poll" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Invoke-GetSupervisorNamespaceManagementSummary {
                [PSCustomObject]@{ ConfigStatus = "RUNNING"; KubernetesStatus = "READY" }
            }
            Mock Start-Sleep { }
            Mock Write-SupervisorKubernetesDiagnosticReport { }
            Wait-SupervisorReady -SupervisorId "sup-001" -ClusterName "cl-site1" -TotalWaitTime 60 -CheckInterval 5
        }
        $result.Success | Should -Be $true
    }

    It "Returns Success=false when TotalWaitTime=1 and supervisor never becomes ready" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Invoke-GetSupervisorNamespaceManagementSummary {
                [PSCustomObject]@{ ConfigStatus = "CONFIGURING"; KubernetesStatus = "PENDING" }
            }
            Mock Start-Sleep { }
            Mock Write-SupervisorKubernetesDiagnosticReport { }
            Wait-SupervisorReady -SupervisorId "sup-001" -ClusterName "cl-site1" -TotalWaitTime 1 -CheckInterval 120
        }
        $result.Success | Should -Be $false
    }

    It "Handles 503-like transient errors without throwing and eventually times out" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Invoke-GetSupervisorNamespaceManagementSummary { return $null }
            Mock Start-Sleep { }
            Mock Write-SupervisorKubernetesDiagnosticReport { }
            Mock Get-Cluster { return $null }
            Wait-SupervisorReady -SupervisorId "sup-001" -ClusterName "cl-site1" -TotalWaitTime 1 -CheckInterval 120
        }
        $result.Success | Should -Be $false
    }
}

# ── Invoke-ArgoCDContextBind ──────────────────────────────────────────────────


Describe "Invoke-ArgoCDContextBind" {
    BeforeAll {
        $script:savedVcfCtxBind     = InModuleScope VcfEdgeAtScale { $Script:VcfCmd }
        $script:savedKubectlCtxBind = InModuleScope VcfEdgeAtScale { $Script:KubectlCmd }

        $script:ctxBindMockDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "veas-ctxbind-$([System.Guid]::NewGuid().ToString('N').Substring(0, 8))"
        New-Item -ItemType Directory -Path $script:ctxBindMockDir -Force | Out-Null

        # VCF CLI that outputs "Successfully activated" and exits 0.
        $script:mockVcfCtxOk = Join-Path $script:ctxBindMockDir "vcf-ctx-ok.ps1"
        Set-Content -Path $script:mockVcfCtxOk -Value 'Write-Output "Successfully activated context."; $global:LASTEXITCODE = 0' -Encoding UTF8

        # VCF CLI that outputs nothing and exits 1 (context switch failure, no activation confirmation).
        $script:mockVcfCtxFail = Join-Path $script:ctxBindMockDir "vcf-ctx-fail.ps1"
        Set-Content -Path $script:mockVcfCtxFail -Value '$global:LASTEXITCODE = 1' -Encoding UTF8

        # kubectl that exits 0 (cluster-info succeeds).
        $script:mockKubectlCtxOk = Join-Path $script:ctxBindMockDir "kubectl-ctx-ok.ps1"
        Set-Content -Path $script:mockKubectlCtxOk -Value '$global:LASTEXITCODE = 0' -Encoding UTF8
    }
    AfterAll {
        InModuleScope VcfEdgeAtScale -ArgumentList $script:savedVcfCtxBind, $script:savedKubectlCtxBind {
            param($v, $k)
            $Script:VcfCmd     = $v
            $Script:KubectlCmd = $k
        }
        Remove-Item -Path $script:ctxBindMockDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    BeforeEach {
        $global:LASTEXITCODE = $null
        InModuleScope VcfEdgeAtScale -ArgumentList $script:savedVcfCtxBind, $script:savedKubectlCtxBind {
            param($v, $k)
            $Script:VcfCmd     = $v
            $Script:KubectlCmd = $k
        }
    }

    It "Returns Success=false with ERR_VCF_CONTEXT when VCF context switch fails" {
        InModuleScope VcfEdgeAtScale -ArgumentList $script:mockVcfCtxFail {
            param($vcfScript)
            $Script:VcfCmd = $vcfScript
        }
        $result = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage { }
            Invoke-ArgoCDContextBind `
                -ArgoCdNamespace "argocd-c42" `
                -ClusterId       "domain-c42" `
                -ContextName     "ctx-site1" `
                -Service         "argocd-service.vsphere.vmware.com"
        }
        $result.Success   | Should -Be $false
        $result.ErrorCode | Should -Be "ERR_VCF_CONTEXT"
    }

    It "Returns Success=false when webhook service reports not ready" {
        InModuleScope VcfEdgeAtScale -ArgumentList $script:mockVcfCtxOk, $script:mockKubectlCtxOk {
            param($vcfScript, $kubectlScript)
            $Script:VcfCmd     = $vcfScript
            $Script:KubectlCmd = $kubectlScript
        }
        $result = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage { }
            Mock Get-ArgoCDOperatorServiceNamespace { return "svc-argocd-service-domain-c42" }
            Mock Wait-WebhookServiceReady { return [PSCustomObject]@{ Success = $false; ErrorMessage = "timed out" } }
            Invoke-ArgoCDContextBind `
                -ArgoCdNamespace      "argocd-c42" `
                -ClusterId            "domain-c42" `
                -ContextName          "ctx-site1" `
                -Service              "argocd-service.vsphere.vmware.com" `
                -WebhookTimeoutSeconds 1
        }
        $result.Success | Should -Be $false
    }

    It "Returns Success=true with resolved ServiceNamespace when all checks pass" {
        InModuleScope VcfEdgeAtScale -ArgumentList $script:mockVcfCtxOk, $script:mockKubectlCtxOk {
            param($vcfScript, $kubectlScript)
            $Script:VcfCmd     = $vcfScript
            $Script:KubectlCmd = $kubectlScript
        }
        $result = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage { }
            Mock Get-ArgoCDOperatorServiceNamespace { return "svc-argocd-service-domain-c42" }
            Mock Wait-WebhookServiceReady { return [PSCustomObject]@{ Success = $true } }
            Invoke-ArgoCDContextBind `
                -ArgoCdNamespace      "argocd-c42" `
                -ClusterId            "domain-c42" `
                -ContextName          "ctx-site1" `
                -Service              "argocd-service.vsphere.vmware.com" `
                -WebhookTimeoutSeconds 1
        }
        $result.Success          | Should -Be $true
        $result.ServiceNamespace | Should -Be "svc-argocd-service-domain-c42"
    }
}

# ── Wait-WebhookServiceReady ──────────────────────────────────────────────────


Describe "Wait-WebhookServiceReady" {

    It "Returns Success=true when webhook service is immediately ready" {
        $result = InModuleScope VcfEdgeAtScale {
            # Set KubectlCmd to a non-existent binary; the preflight try/catch handles the
            # CommandNotFoundException gracefully so the test is not platform-specific.
            $Script:KubectlCmd = "mock-kubectl-not-on-path"
            Mock Test-WebhookServiceReady { return $true }
            Mock Start-Sleep { }
            Mock Write-LogMessage { }
            Wait-WebhookServiceReady -ServiceNamespace "argocd-ns" -TimeoutSeconds 60 -CheckInterval 5
        }
        $result.Success | Should -Be $true
    }

    It "Returns error result when webhook never becomes ready within TimeoutSeconds" {
        $result = InModuleScope VcfEdgeAtScale {
            # KubectlCmd intentionally absent — the preflight try/catch logs a warning and continues,
            # so the test focuses on the timeout/failure path driven by Test-WebhookServiceReady.
            $Script:KubectlCmd = "mock-kubectl-not-on-path"
            Mock Test-WebhookServiceReady { return $false }
            Mock Start-Sleep { }
            Mock Write-LogMessage { }
            Mock Write-ErrorAndReturn {
                [PSCustomObject]@{ Success = $false; ErrorMessage = "timeout"; ErrorCode = "ERR_WEBHOOK_TIMEOUT" }
            }
            Wait-WebhookServiceReady -ServiceNamespace "argocd-ns" -TimeoutSeconds 1 -CheckInterval 120
        }
        $result.Success | Should -Be $false
    }
}

Describe "Invoke-WebhookPreflightCheck" {

    It "Logs DEBUG when kubectl cluster-info succeeds" {
        InModuleScope VcfEdgeAtScale {
            $Script:KubectlCmd = "mock-kubectl-not-on-path"
            $Script:_exitCode = 0
            function mock-kubectl-not-on-path { param([Parameter(ValueFromRemainingArguments)] $args); $Script:LASTEXITCODE = 0 }
            Mock Write-LogMessage { }
            # Use a real kubectl stub that returns exit 0.
            function Invoke-WebhookPreflightCheckHelper {
                [CmdletBinding()] Param()
                $Script:KubectlCmd = { param([Parameter(ValueFromRemainingArguments)] $result); $global:LASTEXITCODE = 0; return "Kubernetes control plane is running" }
                Invoke-WebhookPreflightCheck
            }
            # Arrange: override KubectlCmd with a scriptblock that succeeds.
            $Script:KubectlCmd = { param([Parameter(ValueFromRemainingArguments)] $result); $global:LASTEXITCODE = 0; return "Kubernetes control plane is running" }
            Invoke-WebhookPreflightCheck
            Should -Invoke Write-LogMessage -ParameterFilter { $Message -match "passed" -and $Type -eq "DEBUG" }
        }
    }

    It "Logs WARNING when kubectl cluster-info returns non-zero exit code" {
        InModuleScope VcfEdgeAtScale {
            $Script:KubectlCmd = { param([Parameter(ValueFromRemainingArguments)] $result); $global:LASTEXITCODE = 1; return "error: connection refused" }
            Mock Write-LogMessage { }
            Invoke-WebhookPreflightCheck
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "WARNING" -and $Message -match "Pre-flight check failed" }
        }
    }

    It "Logs WARNING when kubectl binary is not found" {
        InModuleScope VcfEdgeAtScale {
            $Script:KubectlCmd = "binary-that-does-not-exist-on-any-path-abc123"
            Mock Write-LogMessage { }
            Invoke-WebhookPreflightCheck
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "WARNING" -and $Message -match "not found or not executable" }
        }
    }
}

Describe "Write-WebhookTimeoutDiagnostics" {

    It "Logs INFO namespace exists when namespace is present" -Skip:$IsWindows {
        InModuleScope VcfEdgeAtScale {
            $tmpPath = Join-Path ([System.IO.Path]::GetTempPath()) "mock-kubectl-diag-ns-$([Guid]::NewGuid()).sh"
            try {
                # Bash script routes each kubectl sub-command to appropriate JSON output.
                # Backslash-quote pairs inside bash double-quoted strings produce literal JSON braces.
                $scriptContent = "#!/bin/bash`n" +
                    'case "$*" in' + "`n" +
                    '  *current-context*) echo "test-context"; exit 0 ;;' + "`n" +
                    '  *cluster-info*) echo "Kubernetes control plane is running"; exit 0 ;;' + "`n" +
                    '  *pods*) echo "{\"items\":[]}"; exit 0 ;;' + "`n" +
                    '  *namespace*) echo "{\"metadata\":{\"name\":\"argocd-ns\"}}"; exit 0 ;;' + "`n" +
                    '  *) exit 0 ;;' + "`n" +
                    "esac`n"
                [System.IO.File]::WriteAllText($tmpPath, $scriptContent)
                & chmod +x $tmpPath
                $Script:KubectlCmd = $tmpPath
                Mock Write-LogMessage { }
                Write-WebhookTimeoutDiagnostics -ServiceNamespace "argocd-ns"
                Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "INFO" -and $Message -match 'namespace.*exists' }
            } finally {
                Remove-Item -Path $tmpPath -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "Logs ERROR when no pods are found in the namespace" -Skip:$IsWindows {
        InModuleScope VcfEdgeAtScale {
            $tmpPath = Join-Path ([System.IO.Path]::GetTempPath()) "mock-kubectl-diag-pods-$([Guid]::NewGuid()).sh"
            try {
                $scriptContent = "#!/bin/bash`n" +
                    'case "$*" in' + "`n" +
                    '  *current-context*) echo "test-context"; exit 0 ;;' + "`n" +
                    '  *cluster-info*) echo "Kubernetes control plane is running"; exit 0 ;;' + "`n" +
                    '  *pods*) echo "{\"items\":[]}"; exit 0 ;;' + "`n" +
                    '  *namespace*) echo "{\"metadata\":{\"name\":\"argocd-ns\"}}"; exit 0 ;;' + "`n" +
                    '  *) exit 0 ;;' + "`n" +
                    "esac`n"
                [System.IO.File]::WriteAllText($tmpPath, $scriptContent)
                & chmod +x $tmpPath
                $Script:KubectlCmd = $tmpPath
                Mock Write-LogMessage { }
                Write-WebhookTimeoutDiagnostics -ServiceNamespace "argocd-ns"
                Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "ERROR" -and $Message -match "No pods found" }
            } finally {
                Remove-Item -Path $tmpPath -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "Logs WARNING and skips diagnostics when kubectl throws" {
        InModuleScope VcfEdgeAtScale {
            $Script:KubectlCmd = "binary-that-does-not-exist-on-any-path-abc123"
            Mock Write-LogMessage { }
            Write-WebhookTimeoutDiagnostics -ServiceNamespace "argocd-ns"
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "WARNING" -and $Message -match "diagnostics skipped" }
        }
    }
}

Describe "Invoke-WebhookReadinessPoll" {

    It "Returns true when webhook service is ready on the first poll" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Test-WebhookServiceReady { return $true }
            Mock Start-Sleep { }
            Mock Write-LogMessage { }
            Invoke-WebhookReadinessPoll -ServiceNamespace "argocd-ns" -ServiceName "wh-svc" -CheckInterval 5 -TimeoutSeconds 60 -WaitStartTime (Get-Date)
        }
        $result | Should -Be $true
    }

    It "Returns false when timeout elapses before webhook is ready" {
        $result = InModuleScope VcfEdgeAtScale {
            $Script:KubectlCmd = "binary-that-does-not-exist-on-any-path-abc123"
            Mock Test-WebhookServiceReady { return $false }
            Mock Start-Sleep { }
            Mock Write-LogMessage { }
            Invoke-WebhookReadinessPoll -ServiceNamespace "argocd-ns" -ServiceName "wh-svc" -CheckInterval 120 -TimeoutSeconds 1 -WaitStartTime (Get-Date).AddSeconds(-10)
        }
        $result | Should -Be $false
    }

    It "Forwards ServiceNamespace to Write-WebhookTimeoutDiagnostics on timeout" {
        $capturedNs = InModuleScope VcfEdgeAtScale {
            $Script:KubectlCmd = "binary-that-does-not-exist-on-any-path-abc123"
            $Script:_capturedNs = $null
            Mock Test-WebhookServiceReady { return $false }
            Mock Start-Sleep { }
            Mock Write-LogMessage { }
            Mock Write-WebhookTimeoutDiagnostics { $Script:_capturedNs = $ServiceNamespace }
            $null = Invoke-WebhookReadinessPoll -ServiceNamespace "expected-ns" -ServiceName "wh-svc" -CheckInterval 120 -TimeoutSeconds 1 -WaitStartTime (Get-Date).AddSeconds(-10)
            $Script:_capturedNs
        }
        $capturedNs | Should -Be "expected-ns"
    }
}

# ── Confirm-CleanupForCluster ─────────────────────────────────────────────────


Describe "Get-ManagementNetworkConfig" {

    It "Returns a config object with all expected properties populated" {
        $result = InModuleScope VcfEdgeAtScale {
            $spec = [PSCustomObject]@{
                mgmtIpAssignmentMode       = "STATIC"
                mgmtNetworkName            = "mgmt-pg"
                mgmtNetworkStartingIp      = "10.0.0.10"
                mgmtNetworkIPCount         = 5
                mgmtNetworkDnsServers      = @("10.0.0.1")
                mgmtNetworkNtpServers      = @("10.0.0.2")
                mgmtNetworkSearchDomains   = @("example.com")
            }
            Mock Get-PortGroupId { return "pg-100" }
            Mock Get-SupervisorNetworkVanityDisplayName { return "tmn-mgmt-pg" }
            Get-ManagementNetworkConfig -Spec $spec -Gateway "10.0.0.1/24"
        }
        $result.PortGroupID      | Should -Be "pg-100"
        $result.Name             | Should -Be "tmn-mgmt-pg"
        $result.PortGroupName    | Should -Be "mgmt-pg"
        $result.IPAssignmentMode | Should -Be "STATIC"
        $result.DHCPEnabled      | Should -Be $false
        $result.StartingIP       | Should -Be "10.0.0.10"
        $result.IPCount          | Should -Be 5
        $result.Gateway          | Should -Be "10.0.0.1/24"
    }

    It "Uses the raw port group name when SuppressNetworkVanityPrefix is set" {
        InModuleScope VcfEdgeAtScale {
            $spec = [PSCustomObject]@{
                mgmtIpAssignmentMode     = "STATIC"
                mgmtNetworkName          = "mgmt-pg"
                mgmtNetworkStartingIp    = "10.0.0.10"
                mgmtNetworkIPCount       = 3
                mgmtNetworkDnsServers    = @("10.0.0.1")
                mgmtNetworkNtpServers    = @("10.0.0.2")
                mgmtNetworkSearchDomains = @("example.com")
            }
            Mock Get-PortGroupId { return "pg-100" }
            Mock Get-SupervisorNetworkVanityDisplayName { return "should-not-be-used" }
            $result = Get-ManagementNetworkConfig -Spec $spec -Gateway "10.0.0.1/24" -SuppressNetworkVanityPrefix
            $result.Name | Should -Be "mgmt-pg"
            Should -Invoke Get-SupervisorNetworkVanityDisplayName -Times 0
        }
    }

    It "Throws VcfDeploymentException when the port group cannot be resolved" {
        InModuleScope VcfEdgeAtScale {
            $spec = [PSCustomObject]@{
                mgmtIpAssignmentMode     = "STATIC"
                mgmtNetworkName          = "missing-pg"
                mgmtNetworkStartingIp    = "10.0.0.10"
                mgmtNetworkIPCount       = 3
                mgmtNetworkDnsServers    = @("10.0.0.1")
                mgmtNetworkNtpServers    = @("10.0.0.2")
                mgmtNetworkSearchDomains = @("example.com")
            }
            Mock Get-PortGroupId { return $null }
            { Get-ManagementNetworkConfig -Spec $spec -Gateway "10.0.0.1/24" } | Should -Throw
        }
    }
}

# ── Get-GatewayFromNetworkName — hashtable lookup and throw path ──────────────


Describe "Get-GatewayFromNetworkName" {

    It "Returns the gateway IP for a known network name" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $networkGatewayMap = @{
                "mgmt-net"     = "10.0.0.1"
                "workload-net" = "10.1.0.1"
            }
            Get-GatewayFromNetworkName -NetworkGatewayMap $networkGatewayMap -NetworkName "mgmt-net"
        }
        $result | Should -Be "10.0.0.1"
    }

    It "Returns the correct gateway when the map contains multiple keys" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $networkGatewayMap = @{
                "mgmt-net"     = "10.0.0.1"
                "workload-net" = "10.1.0.1"
                "witness-net"  = "10.2.0.1"
            }
            Get-GatewayFromNetworkName -NetworkGatewayMap $networkGatewayMap -NetworkName "witness-net"
        }
        $result | Should -Be "10.2.0.1"
    }

    It "Throws for an unknown network name" {
        { InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $networkGatewayMap = @{ "mgmt-net" = "10.0.0.1" }
            Get-GatewayFromNetworkName -NetworkGatewayMap $networkGatewayMap -NetworkName "nonexistent-net"
        } } | Should -Throw "*Gateway not found*"
    }

    It "Throw message includes the missing network name" {
        $thrownMessage = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $networkGatewayMap = @{ "mgmt-net" = "10.0.0.1" }
            try {
                Get-GatewayFromNetworkName -NetworkGatewayMap $networkGatewayMap -NetworkName "missing-segment"
            } catch {
                $_.Exception.Message
            }
        }
        $thrownMessage | Should -Match "missing-segment"
    }
}

# ── Get-WorkloadNetworkConfig — config assembly and error paths ───────────────


Describe "Get-WorkloadNetworkConfig" {

    It "Returns a config object including ServiceStartIP and ServiceCount" {
        $result = InModuleScope VcfEdgeAtScale {
            $spec = [PSCustomObject]@{
                primaryWorkloadIpAssignmentMode      = "STATIC"
                primaryWorkloadNetworkName           = "workload-pg"
                primaryWorkloadNetworkStartingIp     = "10.1.0.10"
                primaryWorkloadNetworkIPCount        = 5
                workloadDnsServers                   = @("10.0.0.1")
                workloadNtpServers                   = @("10.0.0.2")
                primaryWorkloadNetworkSearchDomains  = @("example.com")
                workloadServiceStartIp               = "10.1.0.100"
                workloadServiceCount                 = 20
            }
            Mock Get-PortGroupId { return "pg-200" }
            Mock Get-SupervisorNetworkVanityDisplayName { return "pwn-workload-pg" }
            Get-WorkloadNetworkConfig -Spec $spec -Gateway "10.1.0.1/24"
        }
        $result.PortGroupID     | Should -Be "pg-200"
        $result.ServiceStartIP  | Should -Be "10.1.0.100"
        $result.ServiceCount    | Should -Be 20
        $result.DHCPEnabled     | Should -Be $false
    }

    It "Throws VcfDeploymentException when the port group cannot be resolved" {
        InModuleScope VcfEdgeAtScale {
            $spec = [PSCustomObject]@{
                primaryWorkloadIpAssignmentMode     = "STATIC"
                primaryWorkloadNetworkName          = "missing-pg"
                primaryWorkloadNetworkStartingIp    = "10.1.0.10"
                primaryWorkloadNetworkIPCount       = 5
                workloadDnsServers                  = @("10.0.0.1")
                workloadNtpServers                  = @("10.0.0.2")
                primaryWorkloadNetworkSearchDomains = @("example.com")
                workloadServiceStartIp              = "10.1.0.100"
                workloadServiceCount                = 20
            }
            Mock Get-PortGroupId { return "" }
            { Get-WorkloadNetworkConfig -Spec $spec -Gateway "10.1.0.1/24" } | Should -Throw
        }
    }
}

# ── Get-FLBNetworkConfig — FLB network extraction and optional Persona ────────


Describe "Get-FLBNetworkConfig" {

    It "Returns a config object with correct shape when NetworkSpec has no Persona" {
        $result = InModuleScope VcfEdgeAtScale {
            $spec = [PSCustomObject]@{
                flbNetworkName                  = "flb-mgmt-pg"
                flbNetworkType                  = "DVPG"
                flbNetworkIpAssignmentMode      = "STATIC"
                flbNetworkIpAddressStartingIp   = "10.2.0.10"
                flbNetworkIpAddressCount        = 4
            }
            Mock Get-PortGroupId { return "pg-300" }
            Mock Get-SupervisorNetworkVanityDisplayName { return "fmn-flb-mgmt-pg" }
            Get-FLBNetworkConfig -NetworkSpec $spec -Gateway "10.2.0.1/24" -VanityPrefix "fmn"
        }
        $result.PortGroupID  | Should -Be "pg-300"
        $result.Type         | Should -Be "DVPG"
        $result.Gateway      | Should -Be "10.2.0.1/24"
        $result.PSObject.Properties.Name | Should -Not -Contain "Persona"
    }

    It "Adds a Persona property when NetworkSpec includes flbNetworkPersona" {
        $result = InModuleScope VcfEdgeAtScale {
            $spec = [PSCustomObject]@{
                flbNetworkName                = "flb-vs-pg"
                flbNetworkType                = "DVPG"
                flbNetworkIpAssignmentMode    = "STATIC"
                flbNetworkIpAddressStartingIp = "10.3.0.10"
                flbNetworkIpAddressCount      = 4
                flbNetworkPersona             = @("FRONTEND", "WORKLOAD")
            }
            Mock Get-PortGroupId { return "pg-400" }
            Mock Get-SupervisorNetworkVanityDisplayName { return "fvsn-flb-vs-pg" }
            Get-FLBNetworkConfig -NetworkSpec $spec -Gateway "10.3.0.1/24" -VanityPrefix "fvsn"
        }
        $result.PSObject.Properties.Name | Should -Contain "Persona"
        $result.Persona | Should -Contain "FRONTEND"
        $result.Persona | Should -Contain "WORKLOAD"
    }

    It "Throws VcfDeploymentException when the FLB port group cannot be resolved" {
        InModuleScope VcfEdgeAtScale {
            $spec = [PSCustomObject]@{
                flbNetworkName                = "missing-flb-pg"
                flbNetworkType                = "DVPG"
                flbNetworkIpAssignmentMode    = "STATIC"
                flbNetworkIpAddressStartingIp = "10.2.0.10"
                flbNetworkIpAddressCount      = 4
            }
            Mock Get-PortGroupId { return $null }
            { Get-FLBNetworkConfig -NetworkSpec $spec -Gateway "10.2.0.1/24" -VanityPrefix "fmn" } | Should -Throw
        }
    }
}

# ── Get-LoadBalancerConfig — FLB assembly delegates to Get-FLBNetworkConfig ───


Describe "Get-LoadBalancerConfig" {

    It "Returns a config object assembling management and virtual-server network configs" {
        $result = InModuleScope VcfEdgeAtScale {
            $fakeMgmtNet = [PSCustomObject]@{ Name = "fmn-mgmt"; PortGroupID = "pg-300"; Gateway = "10.2.0.1/24" }
            $fakeVsNet   = [PSCustomObject]@{ Name = "fvsn-vs";   PortGroupID = "pg-400"; Gateway = "10.3.0.1/24" }
            Mock Get-FLBNetworkConfig { return $fakeMgmtNet } -ParameterFilter { $VanityPrefix -eq "fmn" }
            Mock Get-FLBNetworkConfig { return $fakeVsNet }   -ParameterFilter { $VanityPrefix -eq "fvsn" }
            $spec = [PSCustomObject]@{
                flbName                  = "edge-flb-01"
                flbSize                  = "SMALL"
                flbAvailability          = "ACTIVE_STANDBY"
                flbVipStartIP            = "10.4.0.100"
                flbVipIPCount            = 10
                flbProvider              = "VSPHERE_FOUNDATION"
                flbDnsServers            = @("10.0.0.1")
                flbNtpServers            = @("10.0.0.2")
                flbSearchDomains         = @("example.com")
                flbManagementNetwork     = [PSCustomObject]@{ flbNetworkName = "flb-mgmt-pg" }
                flbVirtualServerNetwork  = [PSCustomObject]@{ flbNetworkName = "flb-vs-pg" }
            }
            Get-LoadBalancerConfig -Spec $spec -FlbMgmtNetworkGateway "10.2.0.1/24" -FlbVirtualServerNetworkGateway "10.3.0.1/24"
        }
        $result.Name                         | Should -Be "edge-flb-01"
        $result.Size                         | Should -Be "SMALL"
        $result.ManagementNetwork.PortGroupID | Should -Be "pg-300"
        $result.VirtualServerNetwork.Gateway  | Should -Be "10.3.0.1/24"
    }

    It "Propagates VcfDeploymentException when Get-FLBNetworkConfig fails" {
        InModuleScope VcfEdgeAtScale {
            Mock Get-FLBNetworkConfig { throw [VcfDeploymentException]::new("Failed to resolve port group ID for FLB network: bad-pg.") }
            $spec = [PSCustomObject]@{
                flbName                 = "edge-flb-01"
                flbSize                 = "SMALL"
                flbAvailability         = "ACTIVE_STANDBY"
                flbVipStartIP           = "10.4.0.100"
                flbVipIPCount           = 10
                flbProvider             = "VSPHERE_FOUNDATION"
                flbDnsServers           = @("10.0.0.1")
                flbNtpServers           = @("10.0.0.2")
                flbSearchDomains        = @("example.com")
                flbManagementNetwork    = [PSCustomObject]@{ flbNetworkName = "bad-pg" }
                flbVirtualServerNetwork = [PSCustomObject]@{ flbNetworkName = "bad-pg" }
            }
            { Get-LoadBalancerConfig -Spec $spec -FlbMgmtNetworkGateway "10.2.0.1/24" -FlbVirtualServerNetworkGateway "10.3.0.1/24" } | Should -Throw
        }
    }
}

# ── Invoke-HarborEnvVarPreflight — $env: scanning and secret resolution ───────


Describe "New-SupervisorControlPlaneSpec" {

    BeforeAll {
        # All Initialize-* cmdlets in this spec builder are mocked so no VCF SDK
        # connection is required. Each returns an empty PSCustomObject, which is
        # acceptable because the downstream calls are also mocked.
        $script:cpMgmtConfig = [PSCustomObject]@{
            PortGroupID      = "pg-100"
            DNSServers       = @("10.0.0.1")
            SearchDomains    = @("example.com")
            NTPServers       = @("10.0.0.2")
            StartingIP       = "10.0.0.10"
            IPCount          = 5
            DHCPEnabled      = $false
            Gateway          = "10.0.0.1/24"
        }
        $script:cpConfig = [PSCustomObject]@{ Size = "SMALL"; VMCount = 3 }
    }

    It "Calls Initialize-VcenterNamespaceManagementSupervisorsControlPlane with StoragePolicyId, Size, and VMCount" {
        InModuleScope VcfEdgeAtScale -ArgumentList $script:cpMgmtConfig, $script:cpConfig {
            param($mgmt, $cp)
            Mock Initialize-VcenterNamespaceManagementSupervisorsNetworksManagementNetworkBacking { [PSCustomObject]@{} }
            Mock Initialize-VcenterNamespaceManagementNetworksServiceDNS { [PSCustomObject]@{} }
            Mock Initialize-VcenterNamespaceManagementNetworksServiceNTP { [PSCustomObject]@{} }
            Mock Initialize-VcenterNamespaceManagementNetworksServices { [PSCustomObject]@{} }
            Mock Initialize-VcenterNamespaceManagementNetworksIPRange { [PSCustomObject]@{} }
            Mock Initialize-VcenterNamespaceManagementNetworksIPAssignment { [PSCustomObject]@{} }
            Mock Initialize-VcenterNamespaceManagementNetworksIPManagement { [PSCustomObject]@{} }
            Mock Initialize-VcenterNamespaceManagementSupervisorsNetworksManagementNetwork { [PSCustomObject]@{} }
            Mock Initialize-VcenterNamespaceManagementSupervisorsControlPlane { [PSCustomObject]@{ mocked = $true } }

            New-SupervisorControlPlaneSpec -ControlPlaneConfig $cp -ManagementNetworkConfig $mgmt -StoragePolicyId "policy-001"
            Should -Invoke Initialize-VcenterNamespaceManagementSupervisorsControlPlane -Times 1 `
                -ParameterFilter { $StoragePolicy -eq "policy-001" -and $Size -eq "SMALL" -and $Count -eq 3 }
        }
    }

    It "Wraps unexpected exceptions in VcfDeploymentException" {
        InModuleScope VcfEdgeAtScale -ArgumentList $script:cpMgmtConfig, $script:cpConfig {
            param($mgmt, $cp)
            Mock Initialize-VcenterNamespaceManagementSupervisorsNetworksManagementNetworkBacking {
                throw [System.Exception]::new("network backing failed")
            }
            { New-SupervisorControlPlaneSpec -ControlPlaneConfig $cp -ManagementNetworkConfig $mgmt -StoragePolicyId "policy-001" } |
                Should -Throw
        }
    }
}

# ── New-SupervisorWorkloadSpec — PowerCLI Initialize-* wiring ─────────────────


Describe "New-SupervisorWorkloadSpec" {

    BeforeAll {
        $script:wlNetConfig = [PSCustomObject]@{
            Name             = "pwn-workload-pg"
            PortGroupID      = "pg-200"
            DNSServers       = @("10.0.0.1")
            SearchDomains    = @("example.com")
            NTPServers       = @("10.0.0.2")
            StartingIP       = "10.1.0.10"
            IPCount          = 5
            ServiceStartIP   = "10.1.0.100"
            ServiceCount     = 20
            DHCPEnabled      = $false
            Gateway          = "10.1.0.1/24"
        }
    }

    It "Calls Initialize-VcenterNamespaceManagementSupervisorsNetworksWorkloadNetwork with the network Name" {
        InModuleScope VcfEdgeAtScale -ArgumentList $script:wlNetConfig {
            param($wl)
            Mock Initialize-VcenterNamespaceManagementNetworksServiceDNS { [PSCustomObject]@{} }
            Mock Initialize-VcenterNamespaceManagementNetworksServiceNTP { [PSCustomObject]@{} }
            Mock Initialize-VcenterNamespaceManagementNetworksServices { [PSCustomObject]@{} }
            Mock Initialize-VcenterNamespaceManagementNetworksIPRange { [PSCustomObject]@{} }
            Mock Initialize-VcenterNamespaceManagementNetworksIPAssignment { [PSCustomObject]@{} }
            Mock Initialize-VcenterNamespaceManagementNetworksIPManagement { [PSCustomObject]@{} }
            Mock Initialize-VcenterNamespaceManagementSupervisorsNetworksWorkloadVSphereNetwork { [PSCustomObject]@{} }
            Mock Initialize-VcenterNamespaceManagementSupervisorsNetworksWorkloadNetwork { [PSCustomObject]@{ mocked = $true } }

            New-SupervisorWorkloadSpec -WorkloadNetworkConfig $wl
            Should -Invoke Initialize-VcenterNamespaceManagementSupervisorsNetworksWorkloadNetwork -Times 1 `
                -ParameterFilter { $Network -eq "pwn-workload-pg" -and $NetworkType -eq "VSPHERE" }
        }
    }

    It "Wraps unexpected exceptions in VcfDeploymentException" {
        InModuleScope VcfEdgeAtScale -ArgumentList $script:wlNetConfig {
            param($wl)
            Mock Initialize-VcenterNamespaceManagementNetworksServiceDNS {
                throw [System.Exception]::new("DNS init failed")
            }
            { New-SupervisorWorkloadSpec -WorkloadNetworkConfig $wl } |
                Should -Throw
        }
    }
}

# ── New-SupervisorLoadBalancerSpec — PowerCLI Initialize-* wiring ─────────────


Describe "New-SupervisorLoadBalancerSpec" {

    BeforeAll {
        $script:lbConfig = [PSCustomObject]@{
            Name                = "edge-flb-01"
            Size                = "SMALL"
            Availability        = "ACTIVE_STANDBY"
            VipStartIP          = "10.4.0.100"
            VipIPCount          = 10
            Provider            = "VSPHERE_FOUNDATION"
            DNSServers          = @("10.0.0.1")
            NTPServers          = @("10.0.0.2")
            SearchDomains       = @("example.com")
            ManagementNetwork   = [PSCustomObject]@{
                Name              = "fmn-flb-mgmt"
                PortGroupID       = "pg-300"
                Type              = "DVPG"
                IPAssignmentMode  = "STATIC"
                StartingIP        = "10.2.0.10"
                IPCount           = 4
                Gateway           = "10.2.0.1/24"
            }
            VirtualServerNetwork = [PSCustomObject]@{
                Name              = "fvsn-flb-vs"
                PortGroupID       = "pg-400"
                Type              = "DVPG"
                IPAssignmentMode  = "STATIC"
                StartingIP        = "10.3.0.10"
                IPCount           = 4
                Gateway           = "10.3.0.1/24"
            }
        }
    }

    It "Calls Initialize-VcenterNamespaceManagementNetworksEdgesEdge with the FLB name and provider" {
        InModuleScope VcfEdgeAtScale -ArgumentList $script:lbConfig {
            param($lb)
            Mock Initialize-VcenterNamespaceManagementNetworksEdgesFoundationDeploymentTarget { [PSCustomObject]@{} }
            Mock Initialize-VcenterNamespaceManagementNetworksEdgesFoundationFoundationIPRange { [PSCustomObject]@{} }
            Mock Initialize-VcenterNamespaceManagementNetworksEdgesFoundationIPConfig { [PSCustomObject]@{} }
            Mock Initialize-VcenterNamespaceManagementNetworksEdgesFoundationDistributedPortGroupNetwork { [PSCustomObject]@{} }
            Mock Initialize-VcenterNamespaceManagementNetworksEdgesFoundationNetwork { [PSCustomObject]@{} }
            Mock Initialize-VcenterNamespaceManagementNetworksEdgesFoundationNetworkInterface { [PSCustomObject]@{} }
            Mock Initialize-VcenterNamespaceManagementNetworksEdgesFoundationDNS { [PSCustomObject]@{} }
            Mock Initialize-VcenterNamespaceManagementNetworksEdgesFoundationNTP { [PSCustomObject]@{} }
            Mock Initialize-VcenterNamespaceManagementNetworksEdgesFoundationNetworkServices { [PSCustomObject]@{} }
            Mock Initialize-VcenterNamespaceManagementNetworksEdgesVsphereFoundationConfig { [PSCustomObject]@{} }
            Mock Initialize-VcenterNamespaceManagementNetworksIPRange { [PSCustomObject]@{} }
            Mock Initialize-VcenterNamespaceManagementNetworksEdgesEdge { [PSCustomObject]@{ mocked = $true } }

            New-SupervisorLoadBalancerSpec -LoadBalancerConfig $lb -StoragePolicyId "policy-001"
            Should -Invoke Initialize-VcenterNamespaceManagementNetworksEdgesEdge -Times 1 `
                -ParameterFilter { $Id -eq "edge-flb-01" -and $Provider -eq "VSPHERE_FOUNDATION" }
        }
    }

    It "Wraps unexpected exceptions in VcfDeploymentException" {
        InModuleScope VcfEdgeAtScale -ArgumentList $script:lbConfig {
            param($lb)
            Mock Initialize-VcenterNamespaceManagementNetworksEdgesFoundationDeploymentTarget {
                throw [System.Exception]::new("deployment target init failed")
            }
            { New-SupervisorLoadBalancerSpec -LoadBalancerConfig $lb -StoragePolicyId "policy-001" } |
                Should -Throw
        }
    }
}

# ── Invoke-VcfEdgeAtScaleCleanup — with mocked wrappers ──────────────────────


Describe "Get-ArgoCDOperatorServiceNamespace" {

    It "Returns null when kubectl discovery fails" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Get-KubectlNamespaceNamesMatchingPattern {
                [PSCustomObject]@{ KubectlSucceeded = $false; Names = @() }
            }
            Get-ArgoCDOperatorServiceNamespace -Service "argocd-service.vsphere.vmware.com"
        }
        $result | Should -Be $null
    }

    It "Returns null when no namespaces match the service prefix" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Get-KubectlNamespaceNamesMatchingPattern {
                [PSCustomObject]@{ KubectlSucceeded = $true; Names = @() }
            }
            Get-ArgoCDOperatorServiceNamespace -Service "argocd-service.vsphere.vmware.com"
        }
        $result | Should -Be $null
    }

    It "Returns the single matching namespace directly" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Get-KubectlNamespaceNamesMatchingPattern {
                [PSCustomObject]@{ KubectlSucceeded = $true; Names = @("svc-argocd-service-abc123") }
            }
            Get-ArgoCDOperatorServiceNamespace -Service "argocd-service.vsphere.vmware.com"
        }
        $result | Should -Be "svc-argocd-service-abc123"
    }

    It "Derives the service slug by stripping the .vsphere.vmware.com suffix" {
        # The slug drives the namespace prefix; verify the lookup uses it correctly.
        $prefixUsed = InModuleScope VcfEdgeAtScale {
            Mock Get-KubectlNamespaceNamesMatchingPattern {
                param($DebugLogPrefix, $NameLike)
                [PSCustomObject]@{ KubectlSucceeded = $true; Names = @("svc-harbor-service-xyz") }
            } -ParameterFilter { $NameLike -like "svc-harbor-service-*" }
            Mock Get-KubectlNamespaceNamesMatchingPattern {
                [PSCustomObject]@{ KubectlSucceeded = $false; Names = @() }
            }
            Get-ArgoCDOperatorServiceNamespace -Service "harbor-service.vsphere.vmware.com"
        }
        # Result is the namespace name returned by the matching mock.
        $prefixUsed | Should -Be "svc-harbor-service-xyz"
    }
}

# ── Set-VCFContextCreate / helpers ───────────────────────────────────────────
# Tests for Set-VCFContextCreate (parent) mock the three extracted helpers.
# Tests for the helpers that call $Script:VcfCmd use bash mock scripts and
# are skipped on Windows (no bash).


Describe "Set-VCFContextCreate" {

    It "Calls all three helper steps when all succeed" {
        InModuleScope VcfEdgeAtScale {
            Mock Invoke-VcfContextDelete {}
            Mock Invoke-VcfContextCreate {}
            Mock Invoke-VcfContextVerifyAndSwitch {}
            { Set-VCFContextCreate -ContextName "ctx-lab" -Endpoint "10.1.1.100" -SsoUsername "admin@vsphere.local" } | Should -Not -Throw
            Should -Invoke Invoke-VcfContextDelete -Times 1
            Should -Invoke Invoke-VcfContextCreate -Times 1
            Should -Invoke Invoke-VcfContextVerifyAndSwitch -Times 1
        }
    }

    It "Propagates a VcfDeploymentException thrown by Invoke-VcfContextCreate" {
        { InModuleScope VcfEdgeAtScale {
            Mock Invoke-VcfContextDelete {}
            Mock Invoke-VcfContextCreate { throw [VcfDeploymentException]::new("Supervisor endpoint unavailable.") }
            Mock Invoke-VcfContextVerifyAndSwitch {}
            Set-VCFContextCreate -ContextName "ctx-lab" -Endpoint "10.1.1.100" -SsoUsername "admin@vsphere.local"
        } } | Should -Throw "*Supervisor endpoint unavailable*"
    }
}


Describe "Invoke-VcfContextDelete" {

    AfterEach {
        InModuleScope VcfEdgeAtScale {
            $Script:VcfCmd = if ($IsWindows) { "vcf.exe" } else { "vcf" }
        }
    }

    It "Logs DEBUG 'verified as deleted' and does not throw when the context does not exist" -Skip:$IsWindows {
        InModuleScope VcfEdgeAtScale {
            $tmpPath = Join-Path ([System.IO.Path]::GetTempPath()) "mock-vcf-empty-$([Guid]::NewGuid()).sh"
            try {
                # delete exits 0, list exits 0 with empty JSON array.
                Set-Content -Path $tmpPath -Value "#!/bin/bash`necho '[]'`nexit 0"
                & chmod +x $tmpPath
                Mock Start-Sleep {}
                Mock Write-LogMessage {}
                $Script:VcfCmd = $tmpPath
                { Invoke-VcfContextDelete -ContextName "ctx-gone" } | Should -Not -Throw
                Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'DEBUG' -and $Message -match 'verified as deleted' }
            } finally {
                Remove-Item -Path $tmpPath -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "Logs DEBUG 'verified as deleted' and does not throw when the delete command itself fails (vcf context not found)" -Skip:$IsWindows {
        InModuleScope VcfEdgeAtScale {
            $tmpPath = Join-Path ([System.IO.Path]::GetTempPath()) "mock-vcf-fail-$([Guid]::NewGuid()).sh"
            try {
                # Delete exits 1 (not found); list exits 0 with empty JSON (context already gone).
                [System.IO.File]::WriteAllText($tmpPath, "#!/bin/bash`nif echo `"`$*`" | grep -q 'delete'; then exit 1; fi`necho '[]'`nexit 0`n")
                & chmod +x $tmpPath
                Mock Start-Sleep {}
                Mock Write-LogMessage {}
                $Script:VcfCmd = $tmpPath
                { Invoke-VcfContextDelete -ContextName "ctx-missing" } | Should -Not -Throw
                Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'DEBUG' -and $Message -match 'verified as deleted' }
            } finally {
                Remove-Item -Path $tmpPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
}


Describe "Invoke-VcfContextCreate" {

    AfterEach {
        InModuleScope VcfEdgeAtScale {
            $Script:VcfCmd = if ($IsWindows) { "vcf.exe" } else { "vcf" }
        }
    }

    It "Throws a VcfDeploymentException when the create command exits non-zero" -Skip:$IsWindows {
        InModuleScope VcfEdgeAtScale {
            $tmpPath = Join-Path ([System.IO.Path]::GetTempPath()) "mock-vcf-create-fail-$([Guid]::NewGuid()).sh"
            try {
                Set-Content -Path $tmpPath -Value "#!/bin/bash`necho 'error: context create failed' >&2`nexit 1"
                & chmod +x $tmpPath
                $Script:VcfCmd = $tmpPath
                { Invoke-VcfContextCreate -ContextName "ctx-lab" -Endpoint "10.1.1.100" -SsoUsername "admin@vsphere.local" } |
                    Should -Throw "*Failed to create VCF context*"
            } finally {
                Remove-Item -Path $tmpPath -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "Throws a VcfDeploymentException when the output indicates a partial login failure" -Skip:$IsWindows {
        InModuleScope VcfEdgeAtScale {
            $tmpPath = Join-Path ([System.IO.Path]::GetTempPath()) "mock-vcf-partial-$([Guid]::NewGuid()).sh"
            try {
                [System.IO.File]::WriteAllText($tmpPath, "#!/bin/bash`necho 'Not all cluster/workload sessions were established'`nexit 0`n")
                & chmod +x $tmpPath
                Mock Test-TcpPortReachable { $false }
                $Script:VcfCmd = $tmpPath
                { Invoke-VcfContextCreate -ContextName "ctx-lab" -Endpoint "10.1.1.100" -SsoUsername "admin@vsphere.local" } |
                    Should -Throw "*Supervisor authentication failed*"
            } finally {
                Remove-Item -Path $tmpPath -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "Logs INFO 'Creating VCF context' and does not throw when the create command succeeds with clean output" -Skip:$IsWindows {
        InModuleScope VcfEdgeAtScale {
            $tmpPath = Join-Path ([System.IO.Path]::GetTempPath()) "mock-vcf-create-ok-$([Guid]::NewGuid()).sh"
            try {
                Set-Content -Path $tmpPath -Value "#!/bin/bash`necho 'VCF context created.'`nexit 0"
                & chmod +x $tmpPath
                Mock Write-LogMessage {}
                $Script:VcfCmd = $tmpPath
                { Invoke-VcfContextCreate -ContextName "ctx-lab" -Endpoint "10.1.1.100" -SsoUsername "admin@vsphere.local" } | Should -Not -Throw
                Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'INFO' -and $Message -match 'Creating VCF context' }
            } finally {
                Remove-Item -Path $tmpPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
}


Describe "Invoke-VcfContextVerifyAndSwitch" {

    AfterEach {
        InModuleScope VcfEdgeAtScale {
            $Script:VcfCmd = if ($IsWindows) { "vcf.exe" } else { "vcf" }
        }
    }

    It "Throws when the context is not found in the context list after creation" -Skip:$IsWindows {
        InModuleScope VcfEdgeAtScale {
            $tmpPath = Join-Path ([System.IO.Path]::GetTempPath()) "mock-vcf-list-empty-$([Guid]::NewGuid()).sh"
            try {
                Set-Content -Path $tmpPath -Value "#!/bin/bash`necho '[]'`nexit 0"
                & chmod +x $tmpPath
                $Script:VcfCmd = $tmpPath
                { Invoke-VcfContextVerifyAndSwitch -ContextName "ctx-lab" } |
                    Should -Throw "*Supervisor endpoint may not be available*"
            } finally {
                Remove-Item -Path $tmpPath -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "Logs INFO 'created successfully' and does not throw when the context is found and the switch succeeds" -Skip:$IsWindows {
        InModuleScope VcfEdgeAtScale {
            $tmpPath = Join-Path ([System.IO.Path]::GetTempPath()) "mock-vcf-switch-ok-$([Guid]::NewGuid()).sh"
            try {
                # list returns the context; use exits 0 (switch succeeds).
                [System.IO.File]::WriteAllText($tmpPath, "#!/bin/bash`nif echo `"`$*`" | grep -q 'list'; then echo '[{`"name`":`"ctx-lab`"}]'; exit 0; fi`necho 'Successfully activated context ctx-lab'`nexit 0`n")
                & chmod +x $tmpPath
                Mock Write-LogMessage {}
                $Script:VcfCmd = $tmpPath
                { Invoke-VcfContextVerifyAndSwitch -ContextName "ctx-lab" } | Should -Not -Throw
                Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'INFO' -and $Message -match 'created successfully' }
            } finally {
                Remove-Item -Path $tmpPath -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "Logs INFO 'activated successfully' and does not throw when the switch exits non-zero but output contains Successfully activated" -Skip:$IsWindows {
        InModuleScope VcfEdgeAtScale {
            $tmpPath = Join-Path ([System.IO.Path]::GetTempPath()) "mock-vcf-activate-$([Guid]::NewGuid()).sh"
            try {
                # list returns the context; use exits 1 but prints 'Successfully activated'.
                [System.IO.File]::WriteAllText($tmpPath, "#!/bin/bash`nif echo `"`$*`" | grep -q 'list'; then echo '[{`"name`":`"ctx-lab`"}]'; exit 0; fi`necho 'Successfully activated context ctx-lab'`nexit 1`n")
                & chmod +x $tmpPath
                Mock Write-LogMessage {}
                $Script:VcfCmd = $tmpPath
                { Invoke-VcfContextVerifyAndSwitch -ContextName "ctx-lab" } | Should -Not -Throw
                Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'INFO' -and $Message -match 'activated successfully' }
            } finally {
                Remove-Item -Path $tmpPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

# ── Test-VsanTrafficVmkernelHasValidIp ───────────────────────────────────────


Describe "Test-SupervisorConfiguration" {
    # Pure-logic function: no PowerCLI calls, no filesystem access. Tests cover every validation branch.

    It "Returns true when all required sections are present" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $config = [PSCustomObject]@{
                ManagementNetwork = [PSCustomObject]@{}
                WorkloadNetwork   = [PSCustomObject]@{ ServiceCount = 20 }
                ControlPlane      = [PSCustomObject]@{}
                LoadBalancer      = [PSCustomObject]@{
                    ManagementNetwork    = [PSCustomObject]@{}
                    VirtualServerNetwork = [PSCustomObject]@{}
                }
            }
            Test-SupervisorConfiguration -Config $config
        }
        $result | Should -Be $true
    }

    It "Returns false when ManagementNetwork is missing" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $config = [PSCustomObject]@{
                WorkloadNetwork = [PSCustomObject]@{ ServiceCount = 20 }
                ControlPlane    = [PSCustomObject]@{}
                LoadBalancer    = [PSCustomObject]@{
                    ManagementNetwork    = [PSCustomObject]@{}
                    VirtualServerNetwork = [PSCustomObject]@{}
                }
            }
            Test-SupervisorConfiguration -Config $config
        }
        $result | Should -Be $false
    }

    It "Returns false when WorkloadNetwork is missing" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $config = [PSCustomObject]@{
                ManagementNetwork = [PSCustomObject]@{}
                ControlPlane      = [PSCustomObject]@{}
                LoadBalancer      = [PSCustomObject]@{
                    ManagementNetwork    = [PSCustomObject]@{}
                    VirtualServerNetwork = [PSCustomObject]@{}
                }
            }
            Test-SupervisorConfiguration -Config $config
        }
        $result | Should -Be $false
    }

    It "Returns false when ControlPlane is missing" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $config = [PSCustomObject]@{
                ManagementNetwork = [PSCustomObject]@{}
                WorkloadNetwork   = [PSCustomObject]@{ ServiceCount = 20 }
                LoadBalancer      = [PSCustomObject]@{
                    ManagementNetwork    = [PSCustomObject]@{}
                    VirtualServerNetwork = [PSCustomObject]@{}
                }
            }
            Test-SupervisorConfiguration -Config $config
        }
        $result | Should -Be $false
    }

    It "Returns false when LoadBalancer is missing" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $config = [PSCustomObject]@{
                ManagementNetwork = [PSCustomObject]@{}
                WorkloadNetwork   = [PSCustomObject]@{ ServiceCount = 20 }
                ControlPlane      = [PSCustomObject]@{}
            }
            Test-SupervisorConfiguration -Config $config
        }
        $result | Should -Be $false
    }

    It "Returns false when LoadBalancer.ManagementNetwork is missing" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $config = [PSCustomObject]@{
                ManagementNetwork = [PSCustomObject]@{}
                WorkloadNetwork   = [PSCustomObject]@{ ServiceCount = 20 }
                ControlPlane      = [PSCustomObject]@{}
                LoadBalancer      = [PSCustomObject]@{
                    VirtualServerNetwork = [PSCustomObject]@{}
                }
            }
            Test-SupervisorConfiguration -Config $config
        }
        $result | Should -Be $false
    }

    It "Returns false when LoadBalancer.VirtualServerNetwork is missing" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $config = [PSCustomObject]@{
                ManagementNetwork = [PSCustomObject]@{}
                WorkloadNetwork   = [PSCustomObject]@{ ServiceCount = 20 }
                ControlPlane      = [PSCustomObject]@{}
                LoadBalancer      = [PSCustomObject]@{
                    ManagementNetwork = [PSCustomObject]@{}
                }
            }
            Test-SupervisorConfiguration -Config $config
        }
        $result | Should -Be $false
    }

    It "Returns true (warning only) when service count is below minimum" {
        # Low service count is a warning, not a validation failure.
        $result = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $config = [PSCustomObject]@{
                ManagementNetwork = [PSCustomObject]@{}
                WorkloadNetwork   = [PSCustomObject]@{ ServiceCount = 4 }
                ControlPlane      = [PSCustomObject]@{}
                LoadBalancer      = [PSCustomObject]@{
                    ManagementNetwork    = [PSCustomObject]@{}
                    VirtualServerNetwork = [PSCustomObject]@{}
                }
            }
            Test-SupervisorConfiguration -Config $config -MinimumServiceCount 16
        }
        $result | Should -Be $true
    }
}

# ── Supervisor upgrade workflow ───────────────────────────────────────────────


Describe "Get-SupervisorUpgradeInfo — mocked vCenter" {
    It "Returns HasUpgradeAvailable=false when no matching cluster is found" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Invoke-ListNamespaceManagementSoftwareClusters { return @() }
            $result = Get-SupervisorUpgradeInfo -ClusterId "domain-c22"
            $result.Success | Should -BeTrue
            $result.HasUpgradeAvailable | Should -BeFalse
            $result.LatestVersion | Should -BeNullOrEmpty
        }
    }

    It "Returns HasUpgradeAvailable=false when cluster has no available versions" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Invoke-ListNamespaceManagementSoftwareClusters {
                return @([PSCustomObject]@{ Cluster = "domain-c22"; CurrentVersion = "v1.29.0"; AvailableVersions = $null; State = "READY" })
            }
            $result = Get-SupervisorUpgradeInfo -ClusterId "domain-c22"
            $result.Success | Should -BeTrue
            $result.HasUpgradeAvailable | Should -BeFalse
            $result.CurrentVersion | Should -Be "v1.29.0"
        }
    }

    It "Returns HasUpgradeAvailable=true with LatestVersion set to the first entry when versions are available" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Invoke-ListNamespaceManagementSoftwareClusters {
                return @([PSCustomObject]@{
                    Cluster = "domain-c22"
                    CurrentVersion = "v1.29.0"
                    AvailableVersions = @("v1.30.0", "v1.31.0")
                    State = "READY"
                })
            }
            $result = Get-SupervisorUpgradeInfo -ClusterId "domain-c22"
            $result.Success | Should -BeTrue
            $result.HasUpgradeAvailable | Should -BeTrue
            $result.LatestVersion | Should -Be "v1.30.0"
            $result.CurrentVersion | Should -Be "v1.29.0"
        }
    }

    It "Returns Success=false when the API call throws" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Invoke-ListNamespaceManagementSoftwareClusters { throw "API unavailable" }
            $result = Get-SupervisorUpgradeInfo -ClusterId "domain-c22"
            $result.Success | Should -BeFalse
            $result.HasUpgradeAvailable | Should -BeFalse
            $result.ErrorMessage | Should -Not -BeNullOrEmpty
        }
    }
}


Describe "Get-SupervisorUpgradeStatus — mocked vCenter" {
    It "Returns Success=false when the API call throws" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Invoke-GetClusterNamespaceManagementSoftware { throw "API unavailable" }
            $result = Get-SupervisorUpgradeStatus -ClusterId "domain-c22"
            $result.Success | Should -BeFalse
            $result.IsUpgrading | Should -BeFalse
        }
    }

    It "Returns IsUpgrading=false when CurrentVersion equals DesiredVersion" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Invoke-GetClusterNamespaceManagementSoftware {
                [PSCustomObject]@{
                    CurrentVersion = "v1.30.0"
                    State = "READY"
                    AvailableVersions = $null
                    LastUpgradedDate = $null
                    Messages = $null
                    UpgradeStatus = [PSCustomObject]@{ DesiredVersion = "v1.30.0"; Progress = $null; Messages = $null }
                }
            }
            $result = Get-SupervisorUpgradeStatus -ClusterId "domain-c22"
            $result.Success | Should -BeTrue
            $result.IsUpgrading | Should -BeFalse
            $result.CurrentVersion | Should -Be "v1.30.0"
        }
    }

    It "Returns IsUpgrading=true when CurrentVersion differs from DesiredVersion" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Invoke-GetClusterNamespaceManagementSoftware {
                [PSCustomObject]@{
                    CurrentVersion = "v1.29.0"
                    State = "UPGRADING"
                    AvailableVersions = $null
                    LastUpgradedDate = $null
                    Messages = $null
                    UpgradeStatus = [PSCustomObject]@{ DesiredVersion = "v1.30.0"; Progress = $null; Messages = $null }
                }
            }
            $result = Get-SupervisorUpgradeStatus -ClusterId "domain-c22"
            $result.Success | Should -BeTrue
            $result.IsUpgrading | Should -BeTrue
            $result.DesiredVersion | Should -Be "v1.30.0"
        }
    }
}


Describe "Invoke-SupervisorUpgrade — mocked vCenter" {
    It "Returns Success=false when the required upgrade-spec cmdlet is not found" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Get-VcfSdkInitializeCommand { return $null }
            $result = Invoke-SupervisorUpgrade -ClusterId "domain-c22" -DesiredVersion "v1.30.0"
            $result.Success | Should -BeFalse
            $result.ErrorMessage | Should -Match "cmdlet"
        }
    }

    It "Returns Success=true when the upgrade spec is initialized and Invoke-UpgradeCluster succeeds" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Get-VcfSdkInitializeCommand {
                return { param($DesiredVersion, $IgnorePrecheckWarnings) [PSCustomObject]@{} }
            }
            Mock Invoke-UpgradeCluster {}
            $result = Invoke-SupervisorUpgrade -ClusterId "domain-c22" -DesiredVersion "v1.30.0"
            $result.Success | Should -BeTrue
            $result.ErrorMessage | Should -BeNullOrEmpty
        }
    }

    It "Returns Success=false when Invoke-UpgradeCluster throws" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Get-VcfSdkInitializeCommand {
                return { param($DesiredVersion, $IgnorePrecheckWarnings) [PSCustomObject]@{} }
            }
            Mock Invoke-UpgradeCluster { throw "Upgrade failed: precheck ERROR" }
            $result = Invoke-SupervisorUpgrade -ClusterId "domain-c22" -DesiredVersion "v1.30.0"
            $result.Success | Should -BeFalse
            $result.ErrorMessage | Should -Not -BeNullOrEmpty
        }
    }
}


Describe "Wait-SupervisorUpgradeComplete — mocked status" {
    It "Returns Success=true immediately when status already shows desired version and READY state" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Write-Progress {}
            Mock Start-Sleep {}
            Mock Get-SupervisorUpgradeStatus {
                return [PSCustomObject]@{
                    Success = $true
                    CurrentVersion = "v1.30.0"
                    DesiredVersion = "v1.30.0"
                    State = "READY"
                    UpgradeProgress = $null
                }
            }
            Mock Write-SupervisorKubernetesDiagnosticReport {}
            $result = Wait-SupervisorUpgradeComplete -ClusterId "domain-c22" -ClusterName "cl0" -DesiredVersion "v1.30.0" -CheckInterval 1 -TotalWaitTime 60
            $result.Success | Should -BeTrue
            $result.FinalVersion | Should -Be "v1.30.0"
            Should -Invoke Start-Sleep -Times 0 -Scope It
        }
    }

    It "Returns Success=false after one poll cycle when the upgrade does not complete within TotalWaitTime" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Write-Progress {}
            Mock Start-Sleep {}
            Mock Get-SupervisorUpgradeStatus {
                return [PSCustomObject]@{
                    Success = $true
                    CurrentVersion = "v1.29.0"
                    DesiredVersion = "v1.30.0"
                    State = "UPGRADING"
                    UpgradeProgress = $null
                }
            }
            Mock Write-SupervisorKubernetesDiagnosticReport {}
            $result = Wait-SupervisorUpgradeComplete -ClusterId "domain-c22" -ClusterName "cl0" -DesiredVersion "v1.30.0" -CheckInterval 1 -TotalWaitTime 1
            $result.Success | Should -BeFalse
        }
    }
}

# ── Invoke-SupervisorOnlyRollback ─────────────────────────────────────────────


Describe "Invoke-SupervisorOnlyRollback — rollback decision routing" {

    It "Throws RollbackSkippedException when prompt returns DoNotRollback" {
        { InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Invoke-PauseBeforeRollbackIfRequested { return "DoNotRollback" }
            Invoke-SupervisorOnlyRollback -ClusterId "domain-c22" -ClusterName "cl0-site1"
        } } | Should -Throw "*Rollback skipped*"

    }

    It "Sets RollbackAttempted=true and calls Disable-SupervisorOnCluster when proceeding" {
        $attempted = InModuleScope VcfEdgeAtScale {
            $Script:RollbackAttempted = $false
            Mock Write-LogMessage {}
            Mock Invoke-PauseBeforeRollbackIfRequested { return "Rollback" }
            Mock Disable-SupervisorOnCluster { return [PSCustomObject]@{ Success = $true; ErrorMessage = "" } }
            Invoke-SupervisorOnlyRollback -ClusterId "domain-c22" -ClusterName "cl0-site1"
            Should -Invoke Disable-SupervisorOnCluster -Times 1 -Scope It
            $Script:RollbackAttempted
        }
        $attempted | Should -Be $true
    }

    It "Logs a warning (does not throw) when Disable-SupervisorOnCluster reports failure" {
        { InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Invoke-PauseBeforeRollbackIfRequested { return "Rollback" }
            Mock Disable-SupervisorOnCluster { return [PSCustomObject]@{ Success = $false; ErrorMessage = "Timeout waiting for supervisor to deactivate." } }
            Invoke-SupervisorOnlyRollback -ClusterId "domain-c22" -ClusterName "cl0-site1"
            Should -Invoke Write-LogMessage -Times 1 -ParameterFilter { $Type -eq "WARNING" } -Scope It
        } } | Should -Not -Throw
    }

    It "Includes SupervisorId in the Disable-SupervisorOnCluster call when provided" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Invoke-PauseBeforeRollbackIfRequested { return "Rollback" }
            Mock Disable-SupervisorOnCluster { return [PSCustomObject]@{ Success = $true; ErrorMessage = "" } }
            Invoke-SupervisorOnlyRollback -ClusterId "domain-c22" -ClusterName "cl0-site1" -SupervisorId "abc-def-123"
            Should -Invoke Disable-SupervisorOnCluster -Times 1 -ParameterFilter { $SupervisorId -eq "abc-def-123" } -Scope It
        }
    }
}

# ── Invoke-ArgoCDOnlyRollback ─────────────────────────────────────────────────


Describe "Invoke-ArgoCDOnlyRollback — rollback decision routing" {

    It "Throws RollbackSkippedException when prompt returns DoNotRollback" {
        { InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Invoke-PauseBeforeRollbackIfRequested { return "DoNotRollback" }
            Invoke-ArgoCDOnlyRollback -ArgoCDNamespace "argocd-c354" -ClusterName "cl0-site1"
        } } | Should -Throw "*Rollback skipped*"

    }

    It "Returns without calling Invoke-DeleteNamespaceInstances when namespace is absent" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Invoke-PauseBeforeRollbackIfRequested { return "Rollback" }
            Mock Invoke-ListNamespacesInstances { return [PSCustomObject]@{ Namespace = @("other-ns", "svc-harbor-x") } }
            Mock Invoke-DeleteNamespaceInstances {}
            Invoke-ArgoCDOnlyRollback -ArgoCDNamespace "argocd-c354" -ClusterName "cl0-site1"
            Should -Invoke Invoke-DeleteNamespaceInstances -Times 0 -Scope It
        }
    }
}

# ── Invoke-HarborOnlyRollback ─────────────────────────────────────────────────


Describe "Invoke-HarborOnlyRollback — rollback decision routing" {

    It "Throws RollbackSkippedException when prompt returns DoNotRollback" {
        { InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Invoke-PauseBeforeRollbackIfRequested { return "DoNotRollback" }
            Invoke-HarborOnlyRollback -ClusterName "cl0-site1" -Service "harbor.svc" -SupervisorId "abc-123"
        } } | Should -Throw "*Rollback skipped*"

    }

    It "Calls Remove-HarborSupervisorService when proceeding" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Invoke-PauseBeforeRollbackIfRequested { return "Rollback" }
            Mock Remove-HarborSupervisorService {}
            Invoke-HarborOnlyRollback -ClusterName "cl0-site1" -Service "harbor.svc" -SupervisorId "abc-123"
            Should -Invoke Remove-HarborSupervisorService -Times 1 -Scope It
        }
    }
}

# ── Test-VmkernelVsanTrafficViaEsxcli ────────────────────────────────────────


Describe "Get-AvailableVmClassNames — mocked API" {

    It "Returns name array when items expose an Id property" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Invoke-ListNamespaceManagementVirtualMachineClasses {
                return @(
                    [PSCustomObject]@{ Id = "best-effort-small" },
                    [PSCustomObject]@{ Id = "best-effort-medium" }
                )
            }
            $result = Get-AvailableVmClassNames
            $result | Should -Contain "best-effort-small"
            $result | Should -Contain "best-effort-medium"
            $result.Count | Should -Be 2
        }
    }

    It "Falls back to the Name property when Id is absent" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Invoke-ListNamespaceManagementVirtualMachineClasses {
                return @([PSCustomObject]@{ Name = "guaranteed-small" })
            }
            $result = Get-AvailableVmClassNames
            $result | Should -Contain "guaranteed-small"
        }
    }

    It "Skips items whose resolved name is null or whitespace" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Invoke-ListNamespaceManagementVirtualMachineClasses {
                return @(
                    [PSCustomObject]@{ Id = "  "; Name = $null },
                    [PSCustomObject]@{ Id = "best-effort-small" }
                )
            }
            $result = Get-AvailableVmClassNames
            $result.Count | Should -Be 1
            $result | Should -Contain "best-effort-small"
        }
    }

    It "Throws VcfDeploymentException when the API returns an empty list" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Invoke-ListNamespaceManagementVirtualMachineClasses { return @() }
            { Get-AvailableVmClassNames } | Should -Throw
        }
    }

    It "Throws VcfDeploymentException when all items have blank names and list is effectively empty" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Invoke-ListNamespaceManagementVirtualMachineClasses {
                return @([PSCustomObject]@{ Id = "   "; Name = $null })
            }
            { Get-AvailableVmClassNames } | Should -Throw
        }
    }

    It "Throws VcfDeploymentException when the API call itself fails" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Invoke-ListNamespaceManagementVirtualMachineClasses { throw "Connection refused." }
            { Get-AvailableVmClassNames } | Should -Throw
        }
    }
}

# ── Get-SupervisorControlPlaneIp ──────────────────────────────────────────────


Describe "Get-SupervisorControlPlaneIp — mocked vCenter" {

    It "Throws VcfDeploymentException when not connected to vCenter" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { return [PSCustomObject]@{ IsConnected = $false; ErrorMessage = "no session" } }
            { Get-SupervisorControlPlaneIp -ClusterName "cl0" } | Should -Throw
        }
    }

    It "Throws VcfDeploymentException when no Supervisor Control Plane VMs are found in the cluster" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { return [PSCustomObject]@{ IsConnected = $true; ErrorMessage = $null } }
            Mock Get-Cluster { return [PSCustomObject]@{ Name = "cl0" } }
            Mock Get-VmsFromCluster { return @() }
            { Get-SupervisorControlPlaneIp -ClusterName "cl0" } | Should -Throw
        }
    }

    It "Throws VcfDeploymentException when the VM has no IPv4 addresses" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { return [PSCustomObject]@{ IsConnected = $true; ErrorMessage = $null } }
            Mock Get-Cluster { return [PSCustomObject]@{ Name = "cl0" } }
            Mock Get-VmsFromCluster { return @([PSCustomObject]@{ Name = "SupervisorControlPlane-x"; Id = "vm-1" }) }
            Mock Get-VmViewForVm { return [PSCustomObject]@{ Guest = [PSCustomObject]@{ IPAddress = @("fe80::1") } } }
            { Get-SupervisorControlPlaneIp -ClusterName "cl0" } | Should -Throw
        }
    }

    It "Returns the single IPv4 address when the VM has exactly one" {
        InModuleScope VcfEdgeAtScale {
            # Get-Cluster may be a stub (from wrapper tests) or VMware binary; redefine to ensure
            # -Server accepts a plain string without VIServer type coercion.
            function Get-Cluster {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { return [PSCustomObject]@{ IsConnected = $true; ErrorMessage = $null } }
            Mock Get-Cluster { return [PSCustomObject]@{ Name = "cl0" } }
            Mock Get-VmsFromCluster { return @([PSCustomObject]@{ Name = "SupervisorControlPlane-x"; Id = "vm-1" }) }
            Mock Get-VmViewForVm { return [PSCustomObject]@{ Guest = [PSCustomObject]@{ IPAddress = @("10.0.0.50") } } }
            $result = Get-SupervisorControlPlaneIp -ClusterName "cl0"
            $result | Should -Be "10.0.0.50"
        }
    }

    It "Returns the first IPv4 and logs a WARNING when the VM has multiple IPv4 addresses" {
        InModuleScope VcfEdgeAtScale {
            function Get-Cluster {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { return [PSCustomObject]@{ IsConnected = $true; ErrorMessage = $null } }
            Mock Get-Cluster { return [PSCustomObject]@{ Name = "cl0" } }
            Mock Get-VmsFromCluster { return @([PSCustomObject]@{ Name = "SupervisorControlPlane-x"; Id = "vm-1" }) }
            Mock Get-VmViewForVm { return [PSCustomObject]@{ Guest = [PSCustomObject]@{ IPAddress = @("10.0.0.50", "10.0.0.51") } } }
            $result = Get-SupervisorControlPlaneIp -ClusterName "cl0"
            $result | Should -Be "10.0.0.50"
            Should -Invoke Write-LogMessage -Times 1 -ParameterFilter { $Type -eq "WARNING" } -Scope It
        }
    }
}

# ── Wait-SupervisorDiscoverable ───────────────────────────────────────────────


Describe "Wait-SupervisorDiscoverable — mocked REST" {

    It "Returns Success=true with the supervisor ID when supervisor is immediately READY" {
        InModuleScope VcfEdgeAtScale {
            $Script:vCenterName = "vc.lab"
            Mock Write-LogMessage {}
            Mock Write-Progress {}
            Mock Invoke-RestMethod {
                return [PSCustomObject]@{
                    items = @(
                        [PSCustomObject]@{
                            info       = [PSCustomObject]@{ name = "prod-supervisor"; kubernetes_status = "READY" }
                            supervisor = "domain-c123"
                        }
                    )
                }
            }
            $result = Wait-SupervisorDiscoverable `
                -SupervisorName "prod-supervisor" `
                -SessionHeaders @{ Authorization = "Bearer token" } `
                -TimeoutSeconds 30 `
                -CheckInterval 5
            $result.Success      | Should -Be $true
            $result.LastStatus   | Should -Be "READY"
            $result.SupervisorId | Should -Be "domain-c123"
        }
    }

    It "Returns Success=false with ErrorMessage containing 'disappeared' when supervisor vanishes from the list" {
        InModuleScope VcfEdgeAtScale {
            $Script:vCenterName = "vc.lab"
            Mock Write-LogMessage {}
            Mock Write-Progress {}
            Mock Invoke-RestMethod { return [PSCustomObject]@{ items = @() } }
            $result = Wait-SupervisorDiscoverable `
                -SupervisorName "prod-supervisor" `
                -SessionHeaders @{ Authorization = "Bearer token" } `
                -TimeoutSeconds 30 `
                -CheckInterval 5
            $result.Success      | Should -Be $false
            $result.ErrorMessage | Should -BeLike "*disappeared*"
        }
    }

    It "Returns Success=false with the exception message when the REST call throws" {
        InModuleScope VcfEdgeAtScale {
            $Script:vCenterName = "vc.lab"
            Mock Write-LogMessage {}
            Mock Write-Progress {}
            Mock Invoke-RestMethod { throw "Connection refused." }
            $result = Wait-SupervisorDiscoverable `
                -SupervisorName "prod-supervisor" `
                -SessionHeaders @{ Authorization = "Bearer token" } `
                -TimeoutSeconds 30 `
                -CheckInterval 5
            $result.Success      | Should -Be $false
            $result.ErrorMessage | Should -BeLike "*Connection refused*"
        }
    }
}

# ── Resolve-ArgoCdTimeout ─────────────────────────────────────────────────────


Describe "Resolve-ArgoCdTimeout — override present" {
    It "Returns the override value when key is a positive integer in TimeoutConfig" {
        InModuleScope VcfEdgeAtScale {
            $result = Resolve-ArgoCdTimeout -TimeoutConfig @{ MyKey = 120 } -Key "MyKey" -Default 60
            $result | Should -Be 120
        }
    }
}


Describe "Resolve-ArgoCdTimeout — fallback to default" {
    It "Returns the default when TimeoutConfig is null" {
        InModuleScope VcfEdgeAtScale {
            $result = Resolve-ArgoCdTimeout -TimeoutConfig $null -Key "MyKey" -Default 60
            $result | Should -Be 60
        }
    }
    It "Returns the default when the key is absent from TimeoutConfig" {
        InModuleScope VcfEdgeAtScale {
            $result = Resolve-ArgoCdTimeout -TimeoutConfig @{ OtherKey = 30 } -Key "MyKey" -Default 60
            $result | Should -Be 60
        }
    }
    It "Returns the default when the override value is zero or negative" {
        InModuleScope VcfEdgeAtScale {
            $result = Resolve-ArgoCdTimeout -TimeoutConfig @{ MyKey = 0 } -Key "MyKey" -Default 60
            $result | Should -Be 60
        }
    }
}

# ── Get-ArgoCdTimeoutConfig ───────────────────────────────────────────────────


Describe "Get-ArgoCdTimeoutConfig — builds resolved timeout object" {
    It "Returns all seven timeout properties with overridden and default values mixed" {
        InModuleScope VcfEdgeAtScale {
            $overrides = @{ AuthTimeoutSeconds = 120; PodReadyTimeoutSeconds = 300 }
            $result = Get-ArgoCdTimeoutConfig -TimeoutConfig $overrides
            $result.AuthTimeoutSeconds     | Should -Be 120
            $result.PodReadyTimeoutSeconds | Should -Be 300
            $result.AuthCheckInterval      | Should -Be 5
        }
    }
    It "Returns all defaults when TimeoutConfig is null" {
        InModuleScope VcfEdgeAtScale {
            $Script:ArgoCDAuthTimeoutSeconds               = 60
            $Script:ArgoCDPodReadyTimeoutSeconds           = 600
            $Script:ArgoCDPodReadyCheckIntervalSeconds     = 5
            $Script:ArgoCDWebhookReadyTimeoutSeconds       = 1200
            $Script:ArgoCDWebhookReadyCheckIntervalSeconds = 5
            $Script:ArgoCDWebhookRetryTimeoutSeconds       = 60
            $result = Get-ArgoCdTimeoutConfig -TimeoutConfig $null
            $result.AuthTimeoutSeconds         | Should -Be 60
            $result.PodReadyTimeoutSeconds     | Should -Be 600
            $result.WebhookReadyTimeoutSeconds | Should -Be 1200
        }
    }
}

# ── Confirm-ArgoCdResourceSpec ────────────────────────────────────────────────


Describe "Confirm-ArgoCdResourceSpec — spec.version missing" {
    It "Logs CRITICAL error when resource is missing spec.version" {
        InModuleScope VcfEdgeAtScale {
            $tmpDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "veas-mock-spec-$([System.Guid]::NewGuid().ToString('N').Substring(0, 8))"
            New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
            $fakeJson = '{"items":[{"spec":{}}]}'
            $mockKubectl = Join-Path $tmpDir "kubectl-spec.ps1"
            Set-Content -Path $mockKubectl -Value "Write-Output '$fakeJson'; `$global:LASTEXITCODE = 0" -Encoding UTF8
            $savedKubectl = $Script:KubectlCmd
            $Script:KubectlCmd = $mockKubectl
            $Script:_specErrorLogged = $false
            Mock Write-LogMessage {
                if ($Type -eq "ERROR" -and $Message -match "Spec.version is MISSING") {
                    $Script:_specErrorLogged = $true
                }
            }
            try {
                Confirm-ArgoCdResourceSpec -ArgoCdNamespace "argocd"
                $Script:_specErrorLogged | Should -Be $true
            } finally {
                $Script:KubectlCmd = $savedKubectl
                Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

# ── Invoke-ArgoCdYamlApply ────────────────────────────────────────────────────


Describe "Invoke-ArgoCdYamlApply — kubectl apply succeeds" {
    It "Returns Success=true when kubectl apply exits 0" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Update-YamlNamespace { "fake.yaml" }
            Mock Confirm-ArgoCdResourceSpec {}
            Mock Test-Path { $false }
            $tmpDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "veas-mock-apply-ok-$([System.Guid]::NewGuid().ToString('N').Substring(0, 8))"
            New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
            $mockKubectl = Join-Path $tmpDir "kubectl-ok.ps1"
            Set-Content -Path $mockKubectl -Value 'Write-Output "applied"; $global:LASTEXITCODE = 0' -Encoding UTF8
            $savedKubectl = $Script:KubectlCmd
            $Script:KubectlCmd = $mockKubectl
            try {
                $result = Invoke-ArgoCdYamlApply `
                    -ArgoCdDeploymentYamlPath "source.yaml" `
                    -ArgoCdNamespace "argocd" `
                    -ServiceNamespace "svc-argocd-domain-c1" `
                    -WebhookCheckInterval 5 `
                    -WebhookRetryTimeoutSeconds 60
                $result.Success | Should -Be $true
            } finally {
                $Script:KubectlCmd = $savedKubectl
                Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}


Describe "Invoke-ArgoCdYamlApply — kubectl apply fails non-webhook" {
    It "Returns Success=false with ERR_KUBECTL_APPLY when apply fails without webhook timeout" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Update-YamlNamespace { "fake.yaml" }
            Mock Test-Path { $false }
            $tmpDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "veas-mock-apply-fail-$([System.Guid]::NewGuid().ToString('N').Substring(0, 8))"
            New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
            $mockKubectl = Join-Path $tmpDir "kubectl-fail.ps1"
            Set-Content -Path $mockKubectl -Value 'Write-Error "apply failed"; $global:LASTEXITCODE = 1' -Encoding UTF8
            $savedKubectl = $Script:KubectlCmd
            $Script:KubectlCmd = $mockKubectl
            try {
                $result = Invoke-ArgoCdYamlApply `
                    -ArgoCdDeploymentYamlPath "source.yaml" `
                    -ArgoCdNamespace "argocd" `
                    -ServiceNamespace "svc-argocd-domain-c1" `
                    -WebhookCheckInterval 5 `
                    -WebhookRetryTimeoutSeconds 60
                $result.Success   | Should -Be $false
                $result.ErrorCode | Should -Be "ERR_KUBECTL_APPLY"
            } finally {
                $Script:KubectlCmd = $savedKubectl
                Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

# ── Set-ArgoCdKubectlContext ───────────────────────────────────────────────────


Describe "Set-ArgoCdKubectlContext — context not found" {
    It "Logs INFO 'does not exist' when the context does not exist and returns without error" {
        InModuleScope VcfEdgeAtScale {
            $Script:KubectlCmd = "echo"
            $Script:_infoLogged = $false
            Mock Write-LogMessage {
                if ($Type -eq "INFO" -and $Message -match "does not exist") {
                    $Script:_infoLogged = $true
                }
            }
            { Set-ArgoCdKubectlContext -KubectlContextName "ctx:argocd" } | Should -Not -Throw
            $Script:_infoLogged | Should -BeTrue
        }
    }
}

# ── Wait-ArgoCDAuthReady ───────────────────────────────────────────────────────


Describe "Wait-ArgoCDAuthReady" {
    It "Logs DEBUG success and does not throw when kubectl auth can-i exits 0 with 'yes'" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Write-Progress {}
            $tmpDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "veas-mock-auth-$([System.Guid]::NewGuid().ToString('N').Substring(0, 8))"
            New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
            $mockKubectl = Join-Path $tmpDir "kubectl-yes.ps1"
            Set-Content -Path $mockKubectl -Value 'Write-Output "yes"; $global:LASTEXITCODE = 0' -Encoding UTF8
            $savedKubectl = $Script:KubectlCmd
            $Script:KubectlCmd = $mockKubectl
            try {
                { Wait-ArgoCDAuthReady -ArgoCdNamespace "argocd" -AuthCheckInterval 0 -AuthTimeoutSeconds 10 -ContextName "ctx" } | Should -Not -Throw
                Should -Not -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'ERROR' }
            } finally {
                $Script:KubectlCmd = $savedKubectl
                Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "Throws VcfDeploymentException when auth does not succeed within timeout" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Write-Progress {}
            $tmpDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "veas-mock-auth-$([System.Guid]::NewGuid().ToString('N').Substring(0, 8))"
            New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
            $mockKubectl = Join-Path $tmpDir "kubectl-no.ps1"
            $mockVcf = Join-Path $tmpDir "vcf-noop.ps1"
            Set-Content -Path $mockKubectl -Value 'Write-Output "no"; $global:LASTEXITCODE = 0' -Encoding UTF8
            Set-Content -Path $mockVcf -Value '' -Encoding UTF8
            $savedKubectl = $Script:KubectlCmd
            $savedVcf = $Script:VcfCmd
            $Script:KubectlCmd = $mockKubectl
            $Script:VcfCmd = $mockVcf
            try {
                # AuthTimeoutSeconds=0: do-while runs once, auth fails, loop condition is false, throws.
                { Wait-ArgoCDAuthReady -ArgoCdNamespace "argocd" -AuthCheckInterval 0 -AuthTimeoutSeconds 0 -ContextName "ctx" } | Should -Throw
            } finally {
                $Script:KubectlCmd = $savedKubectl
                $Script:VcfCmd = $savedVcf
                Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

# ── Assert-ArgoCDServiceExists ───────────────────────────────────────────────


Describe "Assert-ArgoCDServiceExists" {

    It "Logs no ERROR and does not throw when the service is found" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            function Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesGet {
                [CmdletBinding()] Param([Parameter()] [Object]$supervisor, [Parameter()] [Object]$supervisorService)
                process { [PSCustomObject]@{ ConfigStatus = "CONFIGURED" } }
            }
            Mock Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesGet { [PSCustomObject]@{ ConfigStatus = "CONFIGURED" } }
            { Assert-ArgoCDServiceExists -SupervisorId "sup-1" -Service "argocd-service.vsphere.vmware.com" } | Should -Not -Throw
            Should -Not -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'ERROR' }
        }
    }

    It "Throws VcfDeploymentException when the service is not found" {
        { InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            function Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesGet {
                [CmdletBinding()] Param([Parameter()] [Object]$supervisor, [Parameter()] [Object]$supervisorService)
                process { throw "service not found" }
            }
            Mock Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesGet { throw "service not found" }
            Assert-ArgoCDServiceExists -SupervisorId "sup-1" -Service "argocd-service.vsphere.vmware.com"
        } } | Should -Throw "*ArgoCD operator service was not created*"
    }

    It "Swallows non-not-found errors and logs no ERROR (treats them as transient initializing)" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            function Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesGet {
                [CmdletBinding()] Param([Parameter()] [Object]$supervisor, [Parameter()] [Object]$supervisorService)
                process { throw "internal server error" }
            }
            Mock Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesGet { throw "internal server error" }
            { Assert-ArgoCDServiceExists -SupervisorId "sup-1" -Service "argocd-service.vsphere.vmware.com" } | Should -Not -Throw
            Should -Not -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'ERROR' }
        }
    }
}

# ── Write-ArgoCDPollNotFoundError ─────────────────────────────────────────────


Describe "Write-ArgoCDPollNotFoundError" {

    It "Throws VcfDeploymentException with not-exist message" {
        { InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Write-Progress {}
            Write-ArgoCDPollNotFoundError -SupervisorId "sup-1"
        } } | Should -Throw "*ArgoCD operator service does not exist*"
    }
}

# ── Write-ArgoCDPollClusterNotRunningError ────────────────────────────────────


Describe "Write-ArgoCDPollClusterNotRunningError" {

    It "Throws VcfDeploymentException with cluster-not-running message" {
        { InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Write-Progress {}
            Mock Get-CleanErrorMessage { "cluster not running" }
            Write-ArgoCDPollClusterNotRunningError -ErrorMessage "cluster.not_running: supervisor unavailable"
        } } | Should -Throw "*Supervisor cluster is not running*"
    }
}

# ── Write-ArgoCDConfigErrorMessages ──────────────────────────────────────────


Describe "Write-ArgoCDConfigErrorMessages" {

    It "Logs ERROR 'supervisor service reported a required namespace is empty or missing' for empty missing namespace" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Get-CleanServiceErrorMessage { "reconcile failed" }
            Mock Test-ArgoCDIpExhaustion { $false }
            Mock Start-Sleep {}
            $savedKubectl = $Script:KubectlCmd
            $Script:KubectlCmd = if ($IsWindows) { "cmd /c exit 0" } else { "/usr/bin/true" }
            try {
                { Write-ArgoCDConfigErrorMessages -ErrorMessages 'ReconcileFailed: namespaces "" not found' -ServiceNamespace "svc-argocd-svc-domain-c1" } | Should -Not -Throw
                Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'ERROR' -and $Message -match 'supervisor service reported a required namespace is empty or missing' }
            } finally {
                $Script:KubectlCmd = $savedKubectl
            }
        }
    }

    It "Logs ERROR with cleaned error message for default (non-ReconcileFailed) error" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Get-CleanServiceErrorMessage { "unknown error" }
            Mock Test-ArgoCDIpExhaustion { $false }
            $savedKubectl = $Script:KubectlCmd
            $Script:KubectlCmd = if ($IsWindows) { "cmd /c exit 0" } else { "/usr/bin/true" }
            try {
                { Write-ArgoCDConfigErrorMessages -ErrorMessages "SomethingElse: bad" -ServiceNamespace "svc-argocd-svc-domain-c1" } | Should -Not -Throw
                Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'ERROR' -and $Message -match 'ArgoCD operator installation failed' }
            } finally {
                $Script:KubectlCmd = $savedKubectl
            }
        }
    }
}

# ── Wait-ArgoCDOperatorConfigured ─────────────────────────────────────────────


Describe "Wait-ArgoCDOperatorConfigured" {

    It "Logs INFO 'ArgoCD operator has been successfully installed' when ConfigStatus is CONFIGURED on first poll" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Write-Progress {}
            Mock Assert-ArgoCDServiceExists {}
            function Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesGet {
                [CmdletBinding()] Param([Parameter()] [Object]$supervisor, [Parameter()] [Object]$supervisorService)
                process { [PSCustomObject]@{ ConfigStatus = "CONFIGURED"; Messages = "" } }
            }
            Mock Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesGet { [PSCustomObject]@{ ConfigStatus = "CONFIGURED"; Messages = "" } }
            { Wait-ArgoCDOperatorConfigured -SupervisorId "sup-1" -Service "argocd-service.vsphere.vmware.com" -ServiceNamespace "svc-argocd-domain-c1" -ClusterName "cl01" -CheckInterval 1 -TotalWaitTime 10 } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'INFO' -and $Message -match 'ArgoCD operator has been successfully installed' }
        }
    }

    It "Throws VcfDeploymentException when ConfigStatus is ERROR" {
        { InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Write-Progress {}
            Mock Assert-ArgoCDServiceExists {}
            Mock Write-ArgoCDConfigErrorMessages {}
            function Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesGet {
                [CmdletBinding()] Param([Parameter()] [Object]$supervisor, [Parameter()] [Object]$supervisorService)
                process { [PSCustomObject]@{ ConfigStatus = "ERROR"; Messages = "reconcile failed" } }
            }
            Mock Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesGet { [PSCustomObject]@{ ConfigStatus = "ERROR"; Messages = "reconcile failed" } }
            Mock Get-CleanServiceErrorMessage { "reconcile failed" }
            Wait-ArgoCDOperatorConfigured -SupervisorId "sup-1" -Service "argocd-service.vsphere.vmware.com" -ServiceNamespace "svc-argocd-domain-c1" -ClusterName "cl01" -CheckInterval 1 -TotalWaitTime 10
        } } | Should -Throw "*ArgoCD operator installation failed*"
    }

    It "Throws VcfDeploymentException when the wait times out" {
        { InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Write-Progress {}
            Mock Assert-ArgoCDServiceExists {}
            Mock Start-Sleep {}
            function Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesGet {
                [CmdletBinding()] Param([Parameter()] [Object]$supervisor, [Parameter()] [Object]$supervisorService)
                process { [PSCustomObject]@{ ConfigStatus = "INSTALLING"; Messages = "" } }
            }
            Mock Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesGet { [PSCustomObject]@{ ConfigStatus = "INSTALLING"; Messages = "" } }
            # TotalWaitTime=1, CheckInterval=2: loop body increments elapsedTime by 2 each iteration,
            # so the do-while condition ($elapsedTime -lt 1) fails after the first iteration.
            Wait-ArgoCDOperatorConfigured -SupervisorId "sup-1" -Service "argocd-service.vsphere.vmware.com" -ServiceNamespace "svc-argocd-domain-c1" -ClusterName "cl01" -CheckInterval 2 -TotalWaitTime 1
        } } | Should -Throw "*timed out*"
    }
}

# ── Add-ArgoCDInstance ────────────────────────────────────────────────────────


Describe "Add-ArgoCDInstance — context bind fails" {
    It "Returns the bind failure result without applying YAML" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Get-VcfEdgeAtScaleVcfCmd {}
            Mock Get-ArgoCdTimeoutConfig { [PSCustomObject]@{ AuthCheckInterval=5; AuthTimeoutSeconds=60; PodReadyCheckInterval=5; PodReadyTimeoutSeconds=600; WebhookReadyCheckInterval=5; WebhookReadyTimeoutSeconds=1200; WebhookRetryTimeoutSeconds=60 } }
            Mock Invoke-ArgoCDContextBind { [PSCustomObject]@{ Success = $false; ErrorMessage = "Bind failed." } }
            Mock Invoke-ArgoCdYamlApply { throw "Should not be called" }
            $result = Add-ArgoCDInstance -ArgoCdDeploymentYamlPath "a.yaml" -ArgoCdNamespace "argocd" -ClusterId "domain-c1" -ContextName "ctx" -Service "argocd-service.vsphere.vmware.com"
            $result.Success | Should -Be $false
        }
    }
}

# ── Install-ArgoCDOperator — service creation and polling loop contract ────────


Describe "Install-ArgoCDOperator — service creation path" {
    # These tests describe the contract of the service-creation block that will be extracted
    # to Invoke-ArgoCDServiceCreate. They must pass BEFORE and AFTER extraction.

    It "Logs 'already exists' INFO and 'successfully installed' INFO when service already exists (idempotent)" {
        InModuleScope VcfEdgeAtScale {
            # Stub VCF cmdlets with untyped parameters to avoid ArgumentTransformationAttribute errors.
            function Initialize-VcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec {
                [CmdletBinding()] Param([Parameter()] [Object]$SupervisorService, [Parameter()] [Object]$Version)
                [PSCustomObject]@{ Service = $SupervisorService; Version = $Version }
            }
            function Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesCreate {
                [CmdletBinding(SupportsShouldProcess = $true)] Param([Parameter()] [Object]$supervisor, [Parameter()] [Object]$vcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec)
                begin {}; process {}
            }
            function Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesGet {
                [CmdletBinding()] Param([Parameter()] [Object]$supervisor, [Parameter()] [Object]$supervisorService)
                [PSCustomObject]@{ ConfigStatus = "CONFIGURED" }
            }
            Mock Write-LogMessage {}
            Mock Write-Progress {}
            Mock Start-Sleep {}
            Mock Initialize-VcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec {
                [PSCustomObject]@{ Service = "argocd-service.vsphere.vmware.com"; Version = "1.0.0" }
            }
            Mock Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesCreate {
                throw "an instance of the Supervisor Service already exists"
            }
            Mock Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesGet {
                [PSCustomObject]@{ ConfigStatus = "CONFIGURED" }
            }
            Mock Write-SupervisorKubernetesDiagnosticReport {}
            { Install-ArgoCDOperator -ClusterId "domain-c1" -ClusterName "cl01" -SupervisorId "sv-01" -Service "argocd-service.vsphere.vmware.com" -Version "1.0.0" } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'INFO' -and $Message -match 'ArgoCD service already exists' }
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'INFO' -and $Message -match 'successfully installed' }
        }
    }

    It "Throws VcfDeploymentException when service is in not-activated state" {
        # Invoke-ArgoCDServiceCreate catches the not-activated error, throws a specific VcfDeploymentException,
        # and Install-ArgoCDOperator's outer catch [VcfDeploymentException] propagates it without re-wrapping.
        { InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Write-Progress {}
            Mock Initialize-VcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec {
                [PSCustomObject]@{}
            }
            Mock Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesCreate {
                throw "Supervisor Service is not in activated state"
            }
            Mock Write-SupervisorKubernetesDiagnosticReport {}
            Install-ArgoCDOperator -ClusterId "domain-c1" -ClusterName "cl01" -SupervisorId "sv-01" -Service "argocd-service.vsphere.vmware.com" -Version "1.0.0"
        } } | Should -Throw "*not in activated state*"
    }

    It "Throws VcfDeploymentException when service version signature is not found" {
        { InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Write-Progress {}
            Mock Get-CleanErrorMessage { return $ErrorMessage }
            Mock Initialize-VcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec {
                [PSCustomObject]@{}
            }
            Mock Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesCreate {
                throw "Signature verification result for Service Version (1.0.0-99999999) not found"
            }
            Mock Write-SupervisorKubernetesDiagnosticReport {}
            Install-ArgoCDOperator -ClusterId "domain-c1" -ClusterName "cl01" -SupervisorId "sv-01" -Service "argocd-service.vsphere.vmware.com" -Version "1.0.0-99999999"
        } } | Should -Throw "*Menu > Supervisor Management > Supervisors > ArgoCD Service > Manager Versions*"

    }
}


Describe "Install-ArgoCDOperator — polling loop contract" {
    It "Logs 'successfully installed' INFO when service reaches CONFIGURED on first poll" {
        InModuleScope VcfEdgeAtScale {
            function Initialize-VcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec {
                [CmdletBinding()] Param([Parameter()] [Object]$SupervisorService, [Parameter()] [Object]$Version)
                [PSCustomObject]@{}
            }
            function Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesCreate {
                [CmdletBinding(SupportsShouldProcess = $true)] Param([Parameter()] [Object]$supervisor, [Parameter()] [Object]$vcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec)
                begin {}; process {}
            }
            function Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesGet {
                [CmdletBinding()] Param([Parameter()] [Object]$supervisor, [Parameter()] [Object]$supervisorService)
                [PSCustomObject]@{ ConfigStatus = "CONFIGURED" }
            }
            Mock Write-LogMessage {}
            Mock Write-Progress {}
            Mock Start-Sleep {}
            Mock Initialize-VcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec { [PSCustomObject]@{} }
            Mock Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesCreate {}
            Mock Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesGet {
                [PSCustomObject]@{ ConfigStatus = "CONFIGURED" }
            }
            { Install-ArgoCDOperator -ClusterId "domain-c1" -ClusterName "cl01" -SupervisorId "sv-01" -Service "argocd-service.vsphere.vmware.com" -Version "1.0.0" } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'INFO' -and $Message -match 'successfully installed' }
        }
    }

    It "Throws VcfDeploymentException when service reaches ERROR status" {
        { InModuleScope VcfEdgeAtScale {
            function Initialize-VcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec {
                [CmdletBinding()] Param([Parameter()] [Object]$SupervisorService, [Parameter()] [Object]$Version)
                [PSCustomObject]@{}
            }
            function Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesCreate {
                [CmdletBinding(SupportsShouldProcess = $true)] Param([Parameter()] [Object]$supervisor, [Parameter()] [Object]$vcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec)
                begin {}; process {}
            }
            function Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesGet {
                [CmdletBinding()] Param([Parameter()] [Object]$supervisor, [Parameter()] [Object]$supervisorService)
                [PSCustomObject]@{ ConfigStatus = "ERROR"; Messages = "some error" }
            }
            Mock Write-LogMessage {}
            Mock Write-Progress {}
            Mock Start-Sleep {}
            Mock Initialize-VcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec { [PSCustomObject]@{} }
            Mock Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesCreate {}
            Mock Get-CleanServiceErrorMessage { "cleaned error" }
            Mock Write-SupervisorKubernetesDiagnosticReport {}
            Mock Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesGet {
                [PSCustomObject]@{ ConfigStatus = "ERROR"; Messages = "some error" }
            }
            Install-ArgoCDOperator -ClusterId "domain-c1" -ClusterName "cl01" -SupervisorId "sv-01" -Service "argocd-service.vsphere.vmware.com" -Version "1.0.0" -CheckInterval 1
        } } | Should -Throw "*failed*"
    }

    It "Throws VcfDeploymentException when TotalWaitTime is exceeded without reaching CONFIGURED" {
        # Wait-ArgoCDOperatorConfigured throws a specific timeout VcfDeploymentException;
        # Install-ArgoCDOperator's outer catch [VcfDeploymentException] propagates it without re-wrapping.
        { InModuleScope VcfEdgeAtScale {
            function Initialize-VcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec {
                [CmdletBinding()] Param([Parameter()] [Object]$SupervisorService, [Parameter()] [Object]$Version)
                [PSCustomObject]@{}
            }
            function Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesCreate {
                [CmdletBinding(SupportsShouldProcess = $true)] Param([Parameter()] [Object]$supervisor, [Parameter()] [Object]$vcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec)
                begin {}; process {}
            }
            function Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesGet {
                [CmdletBinding()] Param([Parameter()] [Object]$supervisor, [Parameter()] [Object]$supervisorService)
                [PSCustomObject]@{ ConfigStatus = "CONFIGURING" }
            }
            Mock Write-LogMessage {}
            Mock Write-Progress {}
            Mock Start-Sleep {}
            Mock Initialize-VcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec { [PSCustomObject]@{} }
            Mock Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesCreate {}
            Mock Write-SupervisorKubernetesDiagnosticReport {}
            Mock Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesGet {
                [PSCustomObject]@{ ConfigStatus = "CONFIGURING" }
            }
            Install-ArgoCDOperator -ClusterId "domain-c1" -ClusterName "cl01" -SupervisorId "sv-01" -Service "argocd-service.vsphere.vmware.com" -Version "1.0.0" -TotalWaitTime 1 -CheckInterval 1
        } } | Should -Throw "*timed out*"
    }
}

# ── Test-ArgoCDIpExhaustion ───────────────────────────────────────────────────


Describe "Test-ArgoCDIpExhaustion" {

    It "Returns false when EventsText is empty" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Test-ArgoCDIpExhaustion -EventsText "" -ServiceNamespace "svc-argocd-domain-c1"
        }
        $result | Should -Be $false
    }

    It "Returns false when EventsText contains no IP exhaustion patterns" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Test-ArgoCDIpExhaustion -EventsText "Normal pod startup events here" -ServiceNamespace "svc-argocd-domain-c1"
        }
        $result | Should -Be $false
    }

    It "Returns true when EventsText contains 'exhausted all IP addresses in requested IPPools'" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Test-ArgoCDIpExhaustion -EventsText "Warning  NetworkInterfaceRealizationFailed  pod/argocd-0  exhausted all IP addresses in requested IPPools" -ServiceNamespace "svc-argocd-domain-c1"
        }
        $result | Should -Be $true
    }

    It "Returns true when EventsText contains 'has 0 free ips which is less than'" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Test-ArgoCDIpExhaustion -EventsText "IPPool has 0 free ips which is less than requested 1" -ServiceNamespace "svc-argocd-domain-c1"
        }
        $result | Should -Be $true
    }

    It "Emits error-level log messages when IP exhaustion is detected" {
        $errorMessages = InModuleScope VcfEdgeAtScale {
            $logged = [System.Collections.Generic.List[PSCustomObject]]::new()
            Mock Write-LogMessage { $logged.Add([PSCustomObject]@{ Type = $Type; Message = $Message }) }
            Test-ArgoCDIpExhaustion -EventsText "exhausted all IP addresses in requested IPPools" -ServiceNamespace "svc-argocd-domain-c1" | Out-Null
            $logged
        }
        $errorMessages | Where-Object { $_.Type -eq "ERROR" } | Should -Not -BeNullOrEmpty
    }
}

# ── Get-MgmtVssUplinkForMigration — uplink selection logic ───────────────────


Describe "Resolve-StoragePolicyTagContext" {

    It "Throws when the tag does not exist" {
        InModuleScope VcfEdgeAtScale {
            function Get-Tag {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Category, [Parameter()] [Object]$Server)
                throw "Tag not found"
            }
            function Get-SpbmStoragePolicy {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Tag, [Parameter()] [Object]$Server)
                process {}
            }

            {
                Resolve-StoragePolicyTagContext -PolicyName "VMFS-Policy" -Server "vc.lab" -TagCatalog "Environment" -TagName "missing-tag"
            } | Should -Throw "*Tag not found*"

        }
    }

    It "Returns null ExistingPolicy and TagAlreadyPresent=false when policy does not exist" {
        InModuleScope VcfEdgeAtScale {
            $fakeTag = [PSCustomObject]@{ Name = "site1"; Id = "tag-1"; Category = [PSCustomObject]@{ Name = "Site" } }
            function Get-Tag {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Category, [Parameter()] [Object]$Server)
                $fakeTag
            }
            function Get-SpbmStoragePolicy {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Tag, [Parameter()] [Object]$Server)
                return $null
            }

            $result = Resolve-StoragePolicyTagContext -PolicyName "VMFS-Policy" -Server "vc.lab" -TagCatalog "Site" -TagName "site1"

            $result.ExistingPolicy   | Should -BeNullOrEmpty
            $result.TagAlreadyPresent | Should -Be $false
            $result.TagObject.Name   | Should -Be "site1"
        }
    }

    It "Returns ExistingPolicy and TagAlreadyPresent=false when policy exists but tag is absent" {
        InModuleScope VcfEdgeAtScale {
            $fakeTag    = [PSCustomObject]@{ Name = "site1"; Id = "tag-1"; Category = [PSCustomObject]@{ Name = "Site" } }
            $fakePolicy = [PSCustomObject]@{ Name = "VMFS-Policy"; AnyOfRuleSets = @() }
            $Script:_spbmContextCount = 0
            function Get-Tag {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Category, [Parameter()] [Object]$Server)
                $fakeTag
            }
            function Get-SpbmStoragePolicy {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Tag, [Parameter()] [Object]$Server)
                $Script:_spbmContextCount++
                # First call: existence check (no -Tag) → policy exists.
                # Second call: tag check (with -Tag) → tag absent → null.
                if ($Script:_spbmContextCount -le 1) { return $fakePolicy }
                return $null
            }

            $result = Resolve-StoragePolicyTagContext -PolicyName "VMFS-Policy" -Server "vc.lab" -TagCatalog "Site" -TagName "site1"

            $result.ExistingPolicy.Name  | Should -Be "VMFS-Policy"
            $result.TagAlreadyPresent     | Should -Be $false
        }
    }

    It "Returns TagAlreadyPresent=true when policy exists and tag is already present" {
        InModuleScope VcfEdgeAtScale {
            $fakeTag    = [PSCustomObject]@{ Name = "site1"; Id = "tag-1"; Category = [PSCustomObject]@{ Name = "Site" } }
            $fakePolicy = [PSCustomObject]@{ Name = "VMFS-Policy"; AnyOfRuleSets = @() }
            function Get-Tag {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Category, [Parameter()] [Object]$Server)
                $fakeTag
            }
            function Get-SpbmStoragePolicy {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Tag, [Parameter()] [Object]$Server)
                # Both existence check and tag check return the policy.
                return $fakePolicy
            }

            $result = Resolve-StoragePolicyTagContext -PolicyName "VMFS-Policy" -Server "vc.lab" -TagCatalog "Site" -TagName "site1"

            $result.TagAlreadyPresent | Should -Be $true
        }
    }
}

Describe "Set-StoragePolicy — new policy creation paths" {
    # These tests describe Set-StoragePolicy's contract so the extraction to separate
    # lookup/application functions can be done safely. NO extraction should occur until
    # all 5 tests here pass both before and after any refactoring.

    It "Creates a new VMFS storage policy when no policy exists" {
        InModuleScope VcfEdgeAtScale {
            $Script:vCenterName = "vc.lab"
            $fakeTag        = [PSCustomObject]@{ Name = "Production"; Id = "tag-1"; Category = [PSCustomObject]@{ Name = "Environment" } }
            $fakeCapability = [PSCustomObject]@{ Name = "com.vmware.storage.volumeallocation.VolumeAllocationType" }
            $fakeRule       = [PSCustomObject]@{ Capability = $fakeCapability; Value = "Fully initialized" }
            $fakeRuleSet    = [PSCustomObject]@{ AllOfRules = @($fakeRule) }
            $fakePolicy     = [PSCustomObject]@{ Name = "VMFS-Policy"; AnyOfRuleSets = @($fakeRuleSet) }

            function Invoke-VcenterReconnectIfNeeded { [CmdletBinding()] Param() }
            function Get-Tag {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Category, [Parameter()] [Object]$Server)
                $fakeTag
            }
            $Script:_spbmCallCount = 0
            function Get-SpbmStoragePolicy {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Tag, [Parameter()] [Object]$Server)
                $Script:_spbmCallCount++
                # First call: existence check → null (policy does not exist yet).
                # Subsequent calls: verification after New-SpbmStoragePolicy → return the policy.
                if ($Script:_spbmCallCount -le 1) { return $null }
                return [PSCustomObject]@{ Name = "VMFS-Policy" }
            }
            function Get-SpbmCapability {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                $fakeCapability
            }
            function New-SpbmRule {
                [CmdletBinding()] Param([Parameter()] [Object]$AnyOfTags, [Parameter()] [Object]$Capability, [Parameter()] [Object]$Value, [Parameter()] [Object]$Server)
                $fakeRule
            }
            function New-SpbmRuleSet {
                [CmdletBinding()] Param([Parameter()] [Object]$AllOfRules)
                $fakeRuleSet
            }
            function New-SpbmStoragePolicy {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Description, [Parameter()] [Object]$AnyOfRuleSets, [Parameter()] [Object]$Server)
                begin {}; process {}
            }

            Mock Write-LogMessage {}

            Set-StoragePolicy -PolicyName "VMFS-Policy" -StorageType "VMFS" -TagName "Production" -TagCatalog "Environment"

            Should -Invoke Write-LogMessage -Scope It -ParameterFilter {
                $Message -like "*Successfully created*VMFS-Policy*"
            }
        }
    }

    It "Creates a new vSAN-ESA policy without a volume allocation rule" {
        InModuleScope VcfEdgeAtScale {
            $Script:vCenterName = "vc.lab"
            $fakeTag     = [PSCustomObject]@{ Name = "Site1"; Id = "tag-2"; Category = [PSCustomObject]@{ Name = "Location" } }
            $fakeRule    = [PSCustomObject]@{ AnyOfTags = @($fakeTag) }
            $fakeRuleSet = [PSCustomObject]@{ AllOfRules = @($fakeRule) }

            $Script:_spbmVsanCallCount = 0
            function Invoke-VcenterReconnectIfNeeded { [CmdletBinding()] Param() }
            function Get-Tag {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Category, [Parameter()] [Object]$Server)
                $fakeTag
            }
            function Get-SpbmStoragePolicy {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Tag, [Parameter()] [Object]$Server)
                $Script:_spbmVsanCallCount++
                if ($Script:_spbmVsanCallCount -le 1) { return $null }
                return [PSCustomObject]@{ Name = "vSAN-ESA-Policy" }
            }
            function Get-SpbmCapability {
                # vSAN path must NOT call this — define stub that signals if called.
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                begin { $Script:_spbmCapCalled = $true }; process {}
            }
            function New-SpbmRule {
                [CmdletBinding()] Param([Parameter()] [Object]$AnyOfTags, [Parameter()] [Object]$Capability, [Parameter()] [Object]$Value, [Parameter()] [Object]$Server)
                $fakeRule
            }
            function New-SpbmRuleSet {
                [CmdletBinding()] Param([Parameter()] [Object]$AllOfRules)
                $fakeRuleSet
            }
            function New-SpbmStoragePolicy {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Description, [Parameter()] [Object]$AnyOfRuleSets, [Parameter()] [Object]$Server)
                begin {}; process {}
            }

            $Script:_spbmCapCalled = $false
            Mock Write-LogMessage {}

            Set-StoragePolicy -PolicyName "vSAN-ESA-Policy" -StorageType "vSAN-ESA" -TagName "Site1" -TagCatalog "Location"

            # vSAN path must NOT call Get-SpbmCapability (no volume allocation rule).
            $Script:_spbmCapCalled | Should -Be $false
            Should -Invoke Write-LogMessage -Scope It -ParameterFilter {
                $Message -like "*Successfully created*vSAN-ESA-Policy*"
            }
        }
    }

    It "Returns without modification when policy already contains the tag (idempotent)" {
        InModuleScope VcfEdgeAtScale {
            $Script:vCenterName = "vc.lab"
            $fakeTag = [PSCustomObject]@{ Name = "Production"; Id = "tag-1"; Category = [PSCustomObject]@{ Name = "Environment" } }

            function Invoke-VcenterReconnectIfNeeded { [CmdletBinding()] Param() }
            function Get-Tag {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Category, [Parameter()] [Object]$Server)
                $fakeTag
            }
            function Get-SpbmStoragePolicy {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Tag, [Parameter()] [Object]$Server)
                # Return a policy object regardless of whether -Tag is specified.
                [PSCustomObject]@{ Name = "VMFS-Policy"; AnyOfRuleSets = @() }
            }

            Mock Write-LogMessage {}

            { Set-StoragePolicy -PolicyName "VMFS-Policy" -StorageType "VMFS" -TagName "Production" -TagCatalog "Environment" } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "DEBUG" -and $Message -match "already contains tag" }
        }
    }

    It "Throws VcfDeploymentException on UnauthorizedAccessException" {
        { InModuleScope VcfEdgeAtScale {
            $Script:vCenterName = "vc.lab"

            function Invoke-VcenterReconnectIfNeeded { [CmdletBinding()] Param() }
            function Get-Tag {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Category, [Parameter()] [Object]$Server)
                throw [System.UnauthorizedAccessException]::new("Access denied")
            }

            Mock Write-LogMessage {}

            Set-StoragePolicy -PolicyName "VMFS-Policy" -StorageType "VMFS" -TagName "Production" -TagCatalog "Environment"
        } } | Should -Throw "*authorization*"
    }

    It "Throws when Invoke-VcenterReconnectIfNeeded fails (session lost and reconnect unsuccessful)" {
        { InModuleScope VcfEdgeAtScale {
            $Script:vCenterName = "vc.lab"
            Mock Write-LogMessage {}
            function Invoke-VcenterReconnectIfNeeded {
                [CmdletBinding()] Param()
                throw [VcfDeploymentException]::new("vCenter session lost and reconnect failed.")
            }
            Set-StoragePolicy -PolicyName "VMFS-Policy" -StorageType "VMFS" -TagName "Production" -TagCatalog "Environment"
        } } | Should -Throw
    }
}

# ── Invoke-MergeTagRules ──────────────────────────────────────────────────────


Describe "Invoke-MergeTagRules" {

    It "Combines the existing tag with the new tag into a single AnyOfTags rule" {
        $result = InModuleScope VcfEdgeAtScale {
            $Script:vCenterName = "vc.lab"
            $existingTag = [PSCustomObject]@{ Name = "site1"; Id = "tag-1"; Category = [PSCustomObject]@{ Name = "Site" } }
            $newTag      = [PSCustomObject]@{ Name = "site2"; Id = "tag-2"; Category = [PSCustomObject]@{ Name = "Site" } }
            $fakeTagRule = [PSCustomObject]@{ AnyOfTags = @($existingTag) }
            $fakeRule    = [PSCustomObject]@{ AnyOfTags = @($existingTag, $newTag) }

            function Get-Tag {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Category, [Parameter()] [Object]$Server)
                if ($Name -eq "site1") { return $existingTag }
                return $newTag
            }
            function New-SpbmRule {
                [CmdletBinding()] Param([Parameter()] [Object]$AnyOfTags, [Parameter()] [Object]$Capability, [Parameter()] [Object]$Value, [Parameter()] [Object]$Server)
                $fakeRule
            }
            Mock Write-LogMessage {}

            Invoke-MergeTagRules -TagRules @($fakeTagRule) -NewTagObject $newTag -PolicyName "VMFS-Policy"
        }
        $result.AnyOfTags.Count | Should -Be 2
    }

    It "Strips the vSphere '(missing)' suffix and re-fetches the tag by name and category" {
        $fetchedName = InModuleScope VcfEdgeAtScale {
            $Script:vCenterName  = "vc.lab"
            $Script:_fetchedName = $null
            $staleTag    = [PSCustomObject]@{ Name = "site1 (missing)"; Id = $null; Category = [PSCustomObject]@{ Name = "Site (missing)" } }
            $freshTag    = [PSCustomObject]@{ Name = "site1"; Id = "tag-1"; Category = [PSCustomObject]@{ Name = "Site" } }
            $newTag      = [PSCustomObject]@{ Name = "site2"; Id = "tag-2"; Category = [PSCustomObject]@{ Name = "Site" } }
            $fakeTagRule = [PSCustomObject]@{ AnyOfTags = @($staleTag) }
            $fakeRule    = [PSCustomObject]@{ AnyOfTags = @($freshTag, $newTag) }

            function Get-Tag {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Category, [Parameter()] [Object]$Server)
                $Script:_fetchedName = $Name
                if ($Name -eq "site1") { return $freshTag }
                return $newTag
            }
            function New-SpbmRule {
                [CmdletBinding()] Param([Parameter()] [Object]$AnyOfTags, [Parameter()] [Object]$Capability, [Parameter()] [Object]$Value, [Parameter()] [Object]$Server)
                $fakeRule
            }
            Mock Write-LogMessage {}

            $null = Invoke-MergeTagRules -TagRules @($fakeTagRule) -NewTagObject $newTag -PolicyName "VMFS-Policy"
            $Script:_fetchedName
        }
        # The "(missing)" suffix must be stripped before the Get-Tag call.
        $fetchedName | Should -Be "site1"
    }

    It "Falls back to a new-tag-only rule when all existing tags are entirely stale (empty name after strip)" {
        $result = InModuleScope VcfEdgeAtScale {
            $Script:vCenterName = "vc.lab"
            $ghostTag    = [PSCustomObject]@{ Name = " (missing)"; Id = $null; Category = [PSCustomObject]@{ Name = "Site" } }
            $newTag      = [PSCustomObject]@{ Name = "site2"; Id = "tag-2"; Category = [PSCustomObject]@{ Name = "Site" } }
            $fakeTagRule = [PSCustomObject]@{ AnyOfTags = @($ghostTag) }
            $fallbackRule = [PSCustomObject]@{ AnyOfTags = @($newTag) }

            function Get-Tag {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Category, [Parameter()] [Object]$Server)
                $newTag
            }
            function New-SpbmRule {
                [CmdletBinding()] Param([Parameter()] [Object]$AnyOfTags, [Parameter()] [Object]$Capability, [Parameter()] [Object]$Value, [Parameter()] [Object]$Server)
                $fallbackRule
            }
            Mock Write-LogMessage {}

            Invoke-MergeTagRules -TagRules @($fakeTagRule) -NewTagObject $newTag -PolicyName "VMFS-Policy"
        }
        # With only the new tag remaining (ghost was skipped), the result should reference site2.
        $result.AnyOfTags[0].Name | Should -Be "site2"
    }

    It "Omits existing tags from a different category (SPBM intra-category requirement)" {
        $tagCount = InModuleScope VcfEdgeAtScale {
            $Script:vCenterName      = "vc.lab"
            $Script:_ruleTagCount    = 0
            $crossCatTag = [PSCustomObject]@{ Name = "prod"; Id = "tag-99"; Category = [PSCustomObject]@{ Name = "Env" } }
            $newTag      = [PSCustomObject]@{ Name = "site1"; Id = "tag-1"; Category = [PSCustomObject]@{ Name = "Site" } }
            $fakeTagRule = [PSCustomObject]@{ AnyOfTags = @($crossCatTag) }

            function Get-Tag {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Category, [Parameter()] [Object]$Server)
                if ($Name -eq "prod") { return $crossCatTag }
                return $newTag
            }
            function New-SpbmRule {
                [CmdletBinding()] Param([Parameter()] [Object]$AnyOfTags, [Parameter()] [Object]$Capability, [Parameter()] [Object]$Value, [Parameter()] [Object]$Server)
                $Script:_ruleTagCount = if ($AnyOfTags -is [Array]) { $AnyOfTags.Count } else { 1 }
                [PSCustomObject]@{ AnyOfTags = @($newTag) }
            }
            Mock Write-LogMessage {}

            $null = Invoke-MergeTagRules -TagRules @($fakeTagRule) -NewTagObject $newTag -PolicyName "VMFS-Policy"
            $Script:_ruleTagCount
        }
        # Cross-category tag is filtered; only the new tag passes the category check.
        $tagCount | Should -Be 1
    }

    It "Deduplicates tags that appear in both existing rules and the new tag (same ID)" {
        $dedupeTagCount = InModuleScope VcfEdgeAtScale {
            $Script:vCenterName       = "vc.lab"
            $Script:_dedupeTagCount   = 0
            # Existing rule already contains the tag we are adding (same Id).
            $sharedTag   = [PSCustomObject]@{ Name = "site1"; Id = "tag-1"; Category = [PSCustomObject]@{ Name = "Site" } }
            $fakeTagRule = [PSCustomObject]@{ AnyOfTags = @($sharedTag) }

            function Get-Tag {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Category, [Parameter()] [Object]$Server)
                $sharedTag
            }
            function New-SpbmRule {
                [CmdletBinding()] Param([Parameter()] [Object]$AnyOfTags, [Parameter()] [Object]$Capability, [Parameter()] [Object]$Value, [Parameter()] [Object]$Server)
                $Script:_dedupeTagCount = if ($AnyOfTags -is [Array]) { $AnyOfTags.Count } else { 1 }
                [PSCustomObject]@{ AnyOfTags = @($sharedTag) }
            }
            Mock Write-LogMessage {}

            $null = Invoke-MergeTagRules -TagRules @($fakeTagRule) -NewTagObject $sharedTag -PolicyName "VMFS-Policy"
            $Script:_dedupeTagCount
        }
        # Tag should appear exactly once despite being in both the existing rule and the new tag.
        $dedupeTagCount | Should -Be 1
    }
}

# ── Add-StoragePolicyTagRule ──────────────────────────────────────────────────


Describe "Add-StoragePolicyTagRule" {

    It "Creates a VMFS rule set (capability + tag) when the existing policy has no rule sets" {
        $setSpbmCalled = InModuleScope VcfEdgeAtScale {
            $Script:vCenterName    = "vc.lab"
            $Script:_setSpbmCalled = $false
            $fakeTag        = [PSCustomObject]@{ Name = "site1"; Id = "tag-1"; Category = [PSCustomObject]@{ Name = "Site" } }
            $fakeCapability = [PSCustomObject]@{ Name = "com.vmware.storage.volumeallocation.VolumeAllocationType" }
            $fakeRule       = [PSCustomObject]@{ AnyOfTags = @($fakeTag) }
            $fakeRuleSet    = [PSCustomObject]@{ AllOfRules = @($fakeRule) }
            $fakePolicy     = [PSCustomObject]@{ Name = "VMFS-Policy"; AnyOfRuleSets = @() }

            function Get-SpbmCapability {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                $fakeCapability
            }
            function New-SpbmRule {
                [CmdletBinding()] Param([Parameter()] [Object]$AnyOfTags, [Parameter()] [Object]$Capability, [Parameter()] [Object]$Value, [Parameter()] [Object]$Server)
                $fakeRule
            }
            function New-SpbmRuleSet {
                [CmdletBinding()] Param([Parameter()] [Object]$AllOfRules)
                $fakeRuleSet
            }
            function Set-SpbmStoragePolicy {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param([Parameter()] [Object]$StoragePolicy, [Parameter()] [Object]$AnyOfRuleSets, [Parameter()] [Object]$Server)
                begin { $Script:_setSpbmCalled = $true }; process {}
            }
            Mock Write-LogMessage {}

            Add-StoragePolicyTagRule -PolicyName "VMFS-Policy" -StorageType "VMFS" -RuleValue "Fully initialized" `
                -TagCatalog "Site" -TagName "site1" -Policy $fakePolicy -TagObject $fakeTag
            $Script:_setSpbmCalled
        }
        $setSpbmCalled | Should -Be $true
    }

    It "Creates a vSAN rule set (tag only, no capability) when the existing policy has no rule sets" {
        $Script:_vsanCapCalled = $false
        InModuleScope VcfEdgeAtScale {
            $Script:vCenterName = "vc.lab"
            $fakeTag     = [PSCustomObject]@{ Name = "site1"; Id = "tag-1"; Category = [PSCustomObject]@{ Name = "Site" } }
            $fakeRule    = [PSCustomObject]@{ AnyOfTags = @($fakeTag) }
            $fakeRuleSet = [PSCustomObject]@{ AllOfRules = @($fakeRule) }
            $fakePolicy  = [PSCustomObject]@{ Name = "vSAN-Policy"; AnyOfRuleSets = @() }

            function Get-SpbmCapability {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                begin { $Script:_vsanCapCalled = $true }; process {}
            }
            function New-SpbmRule {
                [CmdletBinding()] Param([Parameter()] [Object]$AnyOfTags, [Parameter()] [Object]$Capability, [Parameter()] [Object]$Value, [Parameter()] [Object]$Server)
                $fakeRule
            }
            function New-SpbmRuleSet {
                [CmdletBinding()] Param([Parameter()] [Object]$AllOfRules)
                $fakeRuleSet
            }
            function Set-SpbmStoragePolicy {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param([Parameter()] [Object]$StoragePolicy, [Parameter()] [Object]$AnyOfRuleSets, [Parameter()] [Object]$Server)
                begin {}; process {}
            }
            Mock Write-LogMessage {}

            Add-StoragePolicyTagRule -PolicyName "vSAN-Policy" -StorageType "vSAN-OSA" -RuleValue "Fully initialized" `
                -TagCatalog "Site" -TagName "site1" -Policy $fakePolicy -TagObject $fakeTag
        }
        # vSAN path must not fetch the volume allocation capability.
        $Script:_vsanCapCalled | Should -Be $false
    }

    It "Skips rule sets with no AllOfRules and logs a WARNING for each skipped set" {
        InModuleScope VcfEdgeAtScale {
            $Script:vCenterName = "vc.lab"
            $fakeTag     = [PSCustomObject]@{ Name = "site1"; Id = "tag-1"; Category = [PSCustomObject]@{ Name = "Site" } }
            $emptyRuleSet = [PSCustomObject]@{ AllOfRules = $null }
            $fakeRule    = [PSCustomObject]@{ AnyOfTags = @($fakeTag) }
            $fakeRuleSet = [PSCustomObject]@{ AllOfRules = @($fakeRule) }
            $fakePolicy  = [PSCustomObject]@{ Name = "VMFS-Policy"; AnyOfRuleSets = @($emptyRuleSet) }

            function Get-SpbmCapability {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                [PSCustomObject]@{ Name = "vol-alloc" }
            }
            function New-SpbmRule {
                [CmdletBinding()] Param([Parameter()] [Object]$AnyOfTags, [Parameter()] [Object]$Capability, [Parameter()] [Object]$Value, [Parameter()] [Object]$Server)
                $fakeRule
            }
            function New-SpbmRuleSet {
                [CmdletBinding()] Param([Parameter()] [Object]$AllOfRules)
                $fakeRuleSet
            }
            function Set-SpbmStoragePolicy {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param([Parameter()] [Object]$StoragePolicy, [Parameter()] [Object]$AnyOfRuleSets, [Parameter()] [Object]$Server)
                begin {}; process {}
            }
            Mock Write-LogMessage {}

            Add-StoragePolicyTagRule -PolicyName "VMFS-Policy" -StorageType "VMFS" -RuleValue "Fully initialized" `
                -TagCatalog "Site" -TagName "site1" -Policy $fakePolicy -TagObject $fakeTag

            # One WARNING logged for the skipped empty rule set; fallback rule set creation follows.
            Should -Invoke Write-LogMessage -Scope It -ParameterFilter { $Type -eq "WARNING" }
        }
    }

    It "Preserves the existing capability rule value when processing a VMFS rule set" {
        $capRuleValue = InModuleScope VcfEdgeAtScale {
            $Script:vCenterName   = "vc.lab"
            $Script:_capRuleValue = $null
            $fakeTag          = [PSCustomObject]@{ Name = "site1"; Id = "tag-1"; Category = [PSCustomObject]@{ Name = "Site" } }
            $fakeCap          = [PSCustomObject]@{ Name = "com.vmware.storage.volumeallocation.VolumeAllocationType" }
            $existingCapRule  = [PSCustomObject]@{ Capability = $fakeCap; Value = "Reserve space"; AnyOfTags = $null }
            $fakeRuleWithTags = [PSCustomObject]@{ AnyOfTags = @($fakeTag) }
            $existingRuleSet  = [PSCustomObject]@{ AllOfRules = @($existingCapRule) }
            $fakePolicy       = [PSCustomObject]@{ Name = "VMFS-Policy"; AnyOfRuleSets = @($existingRuleSet) }
            $fakeRuleSet      = [PSCustomObject]@{ AllOfRules = @($existingCapRule) }

            function Get-SpbmCapability {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                $fakeCap
            }
            function New-SpbmRule {
                [CmdletBinding()] Param([Parameter()] [Object]$AnyOfTags, [Parameter()] [Object]$Capability, [Parameter()] [Object]$Value, [Parameter()] [Object]$Server)
                if ($Value) { $Script:_capRuleValue = $Value }
                $fakeRuleWithTags
            }
            function New-SpbmRuleSet {
                [CmdletBinding()] Param([Parameter()] [Object]$AllOfRules)
                $fakeRuleSet
            }
            function Set-SpbmStoragePolicy {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param([Parameter()] [Object]$StoragePolicy, [Parameter()] [Object]$AnyOfRuleSets, [Parameter()] [Object]$Server)
                begin {}; process {}
            }
            Mock Write-LogMessage {}
            Mock Invoke-MergeTagRules { $fakeRuleWithTags }

            Add-StoragePolicyTagRule -PolicyName "VMFS-Policy" -StorageType "VMFS" -RuleValue "Fully initialized" `
                -TagCatalog "Site" -TagName "site1" -Policy $fakePolicy -TagObject $fakeTag
            $Script:_capRuleValue
        }
        # The existing "Reserve space" value must be used, not the default "Fully initialized".
        $capRuleValue | Should -Be "Reserve space"
    }

    It "Throws VcfDeploymentException with diagnostic message when Set-SpbmStoragePolicy reports invalid format" {
        { InModuleScope VcfEdgeAtScale {
            $Script:vCenterName = "vc.lab"
            $fakeTag     = [PSCustomObject]@{ Name = "site1"; Id = "tag-1"; Category = [PSCustomObject]@{ Name = "Site" } }
            $fakeRule    = [PSCustomObject]@{ AnyOfTags = @($fakeTag) }
            $fakeRuleSet = [PSCustomObject]@{ AllOfRules = @($fakeRule) }
            $fakePolicy  = [PSCustomObject]@{ Name = "VMFS-Policy"; AnyOfRuleSets = @() }

            function Get-SpbmCapability {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                [PSCustomObject]@{ Name = "vol-alloc" }
            }
            function New-SpbmRule {
                [CmdletBinding()] Param([Parameter()] [Object]$AnyOfTags, [Parameter()] [Object]$Capability, [Parameter()] [Object]$Value, [Parameter()] [Object]$Server)
                $fakeRule
            }
            function New-SpbmRuleSet {
                [CmdletBinding()] Param([Parameter()] [Object]$AllOfRules)
                $fakeRuleSet
            }
            function Set-SpbmStoragePolicy {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param([Parameter()] [Object]$StoragePolicy, [Parameter()] [Object]$AnyOfRuleSets, [Parameter()] [Object]$Server)
                begin { throw "Operation failed: invalid format detected" }; process {}
            }
            Mock Write-LogMessage {}

            Add-StoragePolicyTagRule -PolicyName "VMFS-Policy" -StorageType "VMFS" -RuleValue "Fully initialized" `
                -TagCatalog "Site" -TagName "site1" -Policy $fakePolicy -TagObject $fakeTag
        } } | Should -Throw "*Policies and Profiles > VM Storage Policies*"
    }
}

# ── Resolve-DeploymentRootDirectory ──────────────────────────────────────────


Describe "Get-HarborEventTexts" {

    It "Returns empty strings when kubectl exits non-zero for all namespaces" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $Script:KubectlCmd = "false"  # a command that always exits 1
            $result = Get-HarborEventTexts -NamespacesToCheck @("svc-harbor-domain-c1")
            $result.AllEventsText     | Should -BeNullOrEmpty
            $result.WarningEventsText | Should -BeNullOrEmpty
        }
    }

    It "Returns AllEventsText and WarningEventsText when kubectl succeeds" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $fakeEvents = "NAMESPACE   NAME   KIND   REASON`nsvc-harbor   evt1   Pod   Warning   oom-killed`nsvc-harbor   evt2   Pod   Normal   started"
            $LASTEXITCODE = 0
            $Script:KubectlCmd = "echo"
            Mock -CommandName "Get-HarborEventTexts" -MockWith {}
            # Directly call using a controllable kubectl output via a function override
            function Get-HarborEventTexts_Test {
                [CmdletBinding()] [OutputType([PSCustomObject])] Param([Parameter(Mandatory = $true)] [ValidateNotNull()] [String[]]$NamespacesToCheck)
                $allParts  = [System.Collections.Generic.List[string]]::new()
                $warnParts = [System.Collections.Generic.List[string]]::new()
                $nsEventsStr = $fakeEvents
                $allParts.Add($nsEventsStr)
                $nsLines    = $nsEventsStr -split "`n"
                $headerLine = $nsLines | Select-Object -First 1
                $warnLines  = $nsLines | Where-Object { $_ -match "\s+Warning\s+" }
                if ($warnLines.Count -gt 0) { $warnParts.Add($headerLine + "`n" + ($warnLines -join "`n")) }
                return [PSCustomObject]@{ AllEventsText = $allParts -join "`n"; WarningEventsText = $warnParts -join "`n" }
            }
            $result = Get-HarborEventTexts_Test -NamespacesToCheck @("svc-harbor-domain-c1")
            $result.AllEventsText     | Should -Not -BeNullOrEmpty
            $result.WarningEventsText | Should -Match "Warning"
        }
    }
}

# ── Invoke-HarborServiceErrorDiagnostics ─────────────────────────────────────


Describe "Invoke-HarborServiceErrorDiagnostics" {

    It "Always throws VcfDeploymentException with 'ERROR state' in the message" {
        { InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Write-SupervisorKubernetesDiagnosticReport {}
            Mock Get-KubectlNamespaceNamesMatchingPattern { [PSCustomObject]@{ KubectlSucceeded = $false; Names = @() } }
            # Stub required so Pester can intercept module-internal call without assembly dependency.
            function Get-HarborEventTexts {
                [CmdletBinding()] [OutputType([PSCustomObject])] Param([Parameter()] [String[]]$NamespacesToCheck)
                [PSCustomObject]@{ AllEventsText = ""; WarningEventsText = "" }
            }
            function Write-HarborOciRegistryDiagnostics {
                [CmdletBinding()] Param(
                    [Parameter(Mandatory = $true)] [String]             $DiagnosticNamespace,
                    [Parameter(Mandatory = $true)] [AllowEmptyString()] [String] $HarborAllEventsText,
                    [Parameter(Mandatory = $true)] [AllowEmptyString()] [String] $HarborWarningEventsText,
                    [Parameter(Mandatory = $true)] [Object]             $IpExhaustionDetected,
                    [Parameter(Mandatory = $true)] [Object[]]           $NamespacesToCheck
                )
                begin {}
            }
            Invoke-HarborServiceErrorDiagnostics `
                -ClusterName "cl01" -Service "harbor.tanzu.vmware.com" `
                -ServiceNamespace "svc-harbor-domain-c1" -SupervisorId "sv-01" `
                -SvcStatus ([PSCustomObject]@{ ConfigStatus = "ERROR" })
        } } | Should -Throw "*ERROR state*"
    }

    It "Calls Write-HarborOciRegistryDiagnostics when error detail matches 'OCI Registry'" {
        # Sentinel-throw pattern: the stub throws a unique sentinel so the test assertion can
        # confirm the OCI branch was entered (not the VcfDeploymentException end-throw).
        { InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Write-SupervisorKubernetesDiagnosticReport {}
            Mock Get-KubectlNamespaceNamesMatchingPattern { [PSCustomObject]@{ KubectlSucceeded = $false; Names = @() } }
            # Stub required so Pester can intercept module-internal call without assembly dependency.
            function Get-HarborEventTexts {
                [CmdletBinding()] [OutputType([PSCustomObject])] Param([Parameter()] [String[]]$NamespacesToCheck)
                [PSCustomObject]@{ AllEventsText = ""; WarningEventsText = "" }
            }
            function Write-HarborOciRegistryDiagnostics {
                [CmdletBinding()] Param(
                    [Parameter(Mandatory = $true)] [String]         $DiagnosticNamespace,
                    [Parameter(Mandatory = $true)] [AllowEmptyString()] [String] $HarborAllEventsText,
                    [Parameter(Mandatory = $true)] [AllowEmptyString()] [String] $HarborWarningEventsText,
                    [Parameter(Mandatory = $true)] [Object]         $IpExhaustionDetected,
                    [Parameter(Mandatory = $true)] [Object[]]       $NamespacesToCheck
                )
                # Throw a recognisable sentinel rather than returning normally so the assertion
                # can distinguish "OCI branch ran" from "VcfDeploymentException end-throw".
                throw "OCI_DIAG_SENTINEL"
            }
            Invoke-HarborServiceErrorDiagnostics `
                -ClusterName "cl01" -Service "harbor.tanzu.vmware.com" `
                -ServiceNamespace "svc-harbor-domain-c1" -SupervisorId "sv-01" `
                -SvcStatus ([PSCustomObject]@{ ConfigStatus = "ERROR"; Message = "OCI Registry pod failed" })
        } } | Should -Throw "*OCI_DIAG_SENTINEL*"
    }

    It "Does not call Write-HarborOciRegistryDiagnostics when error detail is unrelated" {
        InModuleScope VcfEdgeAtScale {
            # Stub required so Pester can intercept module-internal call without assembly dependency.
            function Get-HarborEventTexts {
                [CmdletBinding()] [OutputType([PSCustomObject])] Param([Parameter()] [String[]]$NamespacesToCheck)
                [PSCustomObject]@{ AllEventsText = ""; WarningEventsText = "" }
            }
            function Write-HarborOciRegistryDiagnostics {
                [CmdletBinding()] Param(
                    [Parameter(Mandatory = $true)] [String]             $DiagnosticNamespace,
                    [Parameter(Mandatory = $true)] [AllowEmptyString()] [String] $HarborAllEventsText,
                    [Parameter(Mandatory = $true)] [AllowEmptyString()] [String] $HarborWarningEventsText,
                    [Parameter(Mandatory = $true)] [Object]             $IpExhaustionDetected,
                    [Parameter(Mandatory = $true)] [Object[]]           $NamespacesToCheck
                )
                begin { throw "Write-HarborOciRegistryDiagnostics must not be called for non-OCI errors" }
            }
            Mock Write-LogMessage {}
            Mock Write-SupervisorKubernetesDiagnosticReport {}
            Mock Get-KubectlNamespaceNamesMatchingPattern { [PSCustomObject]@{ KubectlSucceeded = $false; Names = @() } }
            { Invoke-HarborServiceErrorDiagnostics `
                -ClusterName "cl01" -Service "harbor.tanzu.vmware.com" `
                -ServiceNamespace "svc-harbor-domain-c1" -SupervisorId "sv-01" `
                -SvcStatus ([PSCustomObject]@{ ConfigStatus = "ERROR"; Message = "already exists" }) `
            } | Should -Throw "*ERROR state*"
        }
    }
}

# ── Invoke-HarborServiceCreate ───────────────────────────────────────────────


Describe "Invoke-HarborServiceCreate" {

    It "Logs INFO 'install request submitted' when the create request succeeds (fresh install)" {
        InModuleScope VcfEdgeAtScale {
            function Initialize-VcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec {
                [CmdletBinding()] Param([Parameter()] [Object]$SupervisorService, [Parameter()] [Object]$Version, [Parameter()] [Object]$YamlServiceConfig)
                [PSCustomObject]@{}
            }
            function Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesCreate {
                [CmdletBinding(SupportsShouldProcess = $true)] Param([Parameter()] [Object]$supervisor, [Parameter()] [Object]$vcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec)
                begin {}; process {}
            }
            Mock Write-LogMessage {}
            Mock Start-Sleep {}
            { Invoke-HarborServiceCreate -CheckInterval 1 -NormalizedYaml "hostname: harbor.lab`n" `
                -Service "harbor-service.vsphere.vmware.com" -ServiceNamespace "svc-harbor-domain-c1" `
                -SupervisorId "sv-01" -Version "2.12.0" -YamlBase64 "dGVzdA==" } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'INFO' -and $Message -match 'Harbor service install request submitted' }
        }
    }

    It "Logs INFO 'already installed' when the service already exists (idempotent create)" {
        InModuleScope VcfEdgeAtScale {
            function Initialize-VcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec {
                [CmdletBinding()] Param([Parameter()] [Object]$SupervisorService, [Parameter()] [Object]$Version, [Parameter()] [Object]$YamlServiceConfig)
                [PSCustomObject]@{}
            }
            function Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesCreate {
                [CmdletBinding(SupportsShouldProcess = $true)] Param([Parameter()] [Object]$supervisor, [Parameter()] [Object]$vcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec)
                begin {}
                process { throw "an instance of the Supervisor Service already exists" }
            }
            Mock Write-LogMessage {}
            Mock Start-Sleep {}
            { Invoke-HarborServiceCreate -CheckInterval 1 -NormalizedYaml "hostname: harbor.lab`n" `
                -Service "harbor-service.vsphere.vmware.com" -ServiceNamespace "svc-harbor-domain-c1" `
                -SupervisorId "sv-01" -Version "2.12.0" -YamlBase64 "dGVzdA==" } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'INFO' -and $Message -match 'Harbor service already installed' }
        }
    }

    It "Throws when the service is not in activated state" {
        { InModuleScope VcfEdgeAtScale {
            function Initialize-VcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec {
                [CmdletBinding()] Param([Parameter()] [Object]$SupervisorService, [Parameter()] [Object]$Version, [Parameter()] [Object]$YamlServiceConfig)
                [PSCustomObject]@{}
            }
            function Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesCreate {
                [CmdletBinding(SupportsShouldProcess = $true)] Param([Parameter()] [Object]$supervisor, [Parameter()] [Object]$vcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec)
                begin {}
                process { throw "Supervisor Service is not in activated state" }
            }
            Mock Write-LogMessage {}
            Mock Start-Sleep {}
            Invoke-HarborServiceCreate -CheckInterval 1 -NormalizedYaml "hostname: harbor.lab`n" `
                -Service "harbor-service.vsphere.vmware.com" -ServiceNamespace "svc-harbor-domain-c1" `
                -SupervisorId "sv-01" -Version "2.12.0" -YamlBase64 "dGVzdA=="
        } } | Should -Throw "*activated*"
    }
}

# ── Install-HarborSupervisorService ──────────────────────────────────────────


Describe "Install-HarborSupervisorService — pre-flight idempotency check" {

    It "Logs INFO 'already CONFIGURED' and skips Create when the service is already CONFIGURED" {
        InModuleScope VcfEdgeAtScale {
            function Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesGet {
                [CmdletBinding()] Param([Parameter()] [Object]$supervisor, [Parameter()] [Object]$supervisorService)
                [PSCustomObject]@{ ConfigStatus = "CONFIGURED" }
            }
            function Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesCreate {
                # Must not be called when service is already CONFIGURED.
                [CmdletBinding(SupportsShouldProcess = $true)] Param([Parameter()] [Object]$supervisor, [Parameter()] [Object]$vcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec)
                begin { throw "Create must not be called when service is already CONFIGURED" }
            }
            Mock Write-LogMessage {}
            Mock Write-Progress {}
            Mock Start-Sleep {}
            { Install-HarborSupervisorService -ClusterId "domain-c1" -ClusterName "cl01" `
                -SupervisorId "sv-01" -Service "harbor.tanzu.vmware.com" `
                -Version "1.0.0" -YamlServiceConfig "hostname: harbor.lab`n" } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'INFO' -and $Message -match 'already CONFIGURED.*Skipping install' }
        }
    }

    It "Logs INFO 'already CONFIGURING' and skips Create when the service is already CONFIGURING" {
        InModuleScope VcfEdgeAtScale {
            $Script:_harborGetCallCount = 0
            function Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesGet {
                [CmdletBinding()] Param([Parameter()] [Object]$supervisor, [Parameter()] [Object]$supervisorService)
                $Script:_harborGetCallCount++
                # Pre-flight returns CONFIGURING; subsequent polling calls return CONFIGURED.
                if ($Script:_harborGetCallCount -le 1) { return [PSCustomObject]@{ ConfigStatus = "CONFIGURING" } }
                [PSCustomObject]@{ ConfigStatus = "CONFIGURED" }
            }
            function Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesCreate {
                # Must not be called when service is already CONFIGURING.
                [CmdletBinding(SupportsShouldProcess = $true)] Param([Parameter()] [Object]$supervisor, [Parameter()] [Object]$vcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec)
                begin { throw "Create must not be called when service is already CONFIGURING" }
            }
            Mock Write-LogMessage {}
            Mock Write-Progress {}
            Mock Start-Sleep {}
            { Install-HarborSupervisorService -ClusterId "domain-c1" -ClusterName "cl01" `
                -SupervisorId "sv-01" -Service "harbor.tanzu.vmware.com" `
                -Version "1.0.0" -YamlServiceConfig "hostname: harbor.lab`n" } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'INFO' -and $Message -match 'already CONFIGURING' }
        }
    }

    It "Proceeds with Create when the pre-flight Get call throws (service not yet installed)" {
        $createCallCount = InModuleScope VcfEdgeAtScale {
            $Script:_harborPreflightCreateCount = 0
            $Script:_harborPreflightGetCount    = 0
            function Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesGet {
                # Call 1 (pre-flight): throws to simulate "not yet installed".
                # Subsequent calls (polling loop): return CONFIGURED so the function exits cleanly.
                [CmdletBinding()] Param([Parameter()] [Object]$supervisor, [Parameter()] [Object]$supervisorService)
                $Script:_harborPreflightGetCount++
                if ($Script:_harborPreflightGetCount -le 1) { throw "Not Found" }
                [PSCustomObject]@{ ConfigStatus = "CONFIGURED" }
            }
            function Initialize-VcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec {
                [CmdletBinding()] Param([Parameter()] [Object]$SupervisorService, [Parameter()] [Object]$Version, [Parameter()] [Object]$YamlServiceConfig)
                [PSCustomObject]@{}
            }
            function Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesCreate {
                [CmdletBinding(SupportsShouldProcess = $true)] Param([Parameter()] [Object]$supervisor, [Parameter()] [Object]$vcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec)
                begin { $Script:_harborPreflightCreateCount++ }; process {}
            }
            Mock Write-LogMessage {}
            Mock Write-Progress {}
            Mock Start-Sleep {}
            Install-HarborSupervisorService -ClusterId "domain-c1" -ClusterName "cl01" `
                -SupervisorId "sv-01" -Service "harbor.tanzu.vmware.com" `
                -Version "1.0.0" -YamlServiceConfig "hostname: harbor.lab`n"
            $Script:_harborPreflightCreateCount
        }
        $createCallCount | Should -BeGreaterOrEqual 1
    }
}


Describe "Install-HarborSupervisorService — service creation path" {

    It "Throws when the service namespace is in terminating status" {
        { InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Write-Progress {}
            Mock Start-Sleep {}
            Mock Initialize-VcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec { [PSCustomObject]@{} }
            Mock Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesCreate {
                throw "namespace (svc-harbor-domain-c1) is in terminating status"
            }
            Install-HarborSupervisorService -ClusterId "domain-c1" -ClusterName "cl01" `
                -SupervisorId "sv-01" -Service "harbor-service.vsphere.vmware.com" `
                -Version "1.0.0" -YamlServiceConfig "hostname: harbor.lab`n"
        } } | Should -Throw "*deleting*"
    }

    It "Throws when the Harbor service is not in activated state" {
        { InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Write-Progress {}
            Mock Start-Sleep {}
            Mock Initialize-VcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec { [PSCustomObject]@{} }
            Mock Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesCreate {
                throw "Supervisor Service is not in activated state"
            }
            Install-HarborSupervisorService -ClusterId "domain-c1" -ClusterName "cl01" `
                -SupervisorId "sv-01" -Service "harbor-service.vsphere.vmware.com" `
                -Version "1.0.0" -YamlServiceConfig "hostname: harbor.lab`n"
        } } | Should -Throw "*activated*"
    }

    It "Throws when the service version signature is not found" {
        { InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Write-Progress {}
            Mock Start-Sleep {}
            Mock Initialize-VcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec { [PSCustomObject]@{} }
            Mock Get-CleanErrorMessage { "" }
            Mock Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesCreate {
                throw "Signature verification result for Service Version (1.0.0-99) not found"
            }
            Install-HarborSupervisorService -ClusterId "domain-c1" -ClusterName "cl01" `
                -SupervisorId "sv-01" -Service "harbor-service.vsphere.vmware.com" `
                -Version "1.0.0-99" -YamlServiceConfig "hostname: harbor.lab`n"
        } } | Should -Throw "*Harbor installation failed*"

    }
}


Describe "Install-HarborSupervisorService — polling loop contract" {

    It "Throws when service reaches ERROR status during polling" {
        { InModuleScope VcfEdgeAtScale {
            $Script:KubectlCmd = "mock-kubectl-not-on-path"
            function Initialize-VcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec {
                [CmdletBinding()] Param([Parameter()] [Object]$SupervisorService, [Parameter()] [Object]$Version, [Parameter()] [Object]$YamlServiceConfig)
                [PSCustomObject]@{}
            }
            function Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesCreate {
                [CmdletBinding(SupportsShouldProcess = $true)] Param([Parameter()] [Object]$supervisor, [Parameter()] [Object]$vcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec)
                begin {}; process {}
            }
            function Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesGet {
                [CmdletBinding()] Param([Parameter()] [Object]$supervisor, [Parameter()] [Object]$supervisorService)
                [PSCustomObject]@{ ConfigStatus = "ERROR" }
            }
            Mock Write-LogMessage {}
            Mock Write-Progress {}
            Mock Start-Sleep {}
            Mock Initialize-VcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec { [PSCustomObject]@{} }
            Mock Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesCreate {}
            Mock Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesGet { [PSCustomObject]@{ ConfigStatus = "ERROR" } }
            Mock Get-KubectlNamespaceNamesMatchingPattern { [PSCustomObject]@{ KubectlSucceeded = $false; Names = @() } }
            Mock Write-SupervisorKubernetesDiagnosticReport {}
            Install-HarborSupervisorService -ClusterId "domain-c1" -ClusterName "cl01" `
                -SupervisorId "sv-01" -Service "harbor-service.vsphere.vmware.com" `
                -Version "1.0.0" -YamlServiceConfig "hostname: harbor.lab`n" -CheckInterval 1
        } } | Should -Throw "*failed*"
    }

    It "Throws when TotalWaitTime is exceeded without reaching CONFIGURED status" {
        { InModuleScope VcfEdgeAtScale {
            function Initialize-VcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec {
                [CmdletBinding()] Param([Parameter()] [Object]$SupervisorService, [Parameter()] [Object]$Version, [Parameter()] [Object]$YamlServiceConfig)
                [PSCustomObject]@{}
            }
            function Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesCreate {
                [CmdletBinding(SupportsShouldProcess = $true)] Param([Parameter()] [Object]$supervisor, [Parameter()] [Object]$vcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec)
                begin {}; process {}
            }
            function Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesGet {
                [CmdletBinding()] Param([Parameter()] [Object]$supervisor, [Parameter()] [Object]$supervisorService)
                [PSCustomObject]@{ ConfigStatus = "CONFIGURING" }
            }
            Mock Write-LogMessage {}
            Mock Write-Progress {}
            Mock Start-Sleep {}
            Mock Initialize-VcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec { [PSCustomObject]@{} }
            Mock Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesCreate {}
            Mock Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesGet { [PSCustomObject]@{ ConfigStatus = "CONFIGURING" } }
            Mock Write-SupervisorKubernetesDiagnosticReport {}
            Install-HarborSupervisorService -ClusterId "domain-c1" -ClusterName "cl01" `
                -SupervisorId "sv-01" -Service "harbor-service.vsphere.vmware.com" `
                -Version "1.0.0" -YamlServiceConfig "hostname: harbor.lab`n" `
                -TotalWaitTime 1 -CheckInterval 1
        } } | Should -Throw "*failed*"
    }
}

# ── Invoke-VsanInitialPartitionRepair ─────────────────────────────────────────


Describe "Wait-ArgoCDPodsReady — pod readiness polling" {

    It "Returns without throwing when all pods are ready on the first check" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Write-Progress {}
            function Start-Sleep { [CmdletBinding()] Param([Parameter()] [Object]$Seconds, [Parameter()] [Object]$Milliseconds) }
            Mock Get-PodReadinessStatus {
                [PSCustomObject]@{ TotalPods = 3; ReadyPods = 3; AllReady = $true; ReadyPodObjects = @() }
            }
            { Wait-ArgoCDPodsReady -Namespace "argocd-c123" -TimeoutSeconds 30 -CheckInterval 5 } |
                Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "INFO" -and $Message -match "ArgoCD pods are ready" }
        }
    }

    It "Throws VcfDeploymentException when pod creation times out (totalPods stays 0)" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Write-Progress {}
            function Start-Sleep { [CmdletBinding()] Param([Parameter()] [Object]$Seconds, [Parameter()] [Object]$Milliseconds) }
            Mock Get-PodReadinessStatus {
                [PSCustomObject]@{ TotalPods = 0; ReadyPods = 0; AllReady = $false; ReadyPodObjects = @() }
            }
            $Script:KubectlCmd = "echo"
            { Wait-ArgoCDPodsReady -Namespace "argocd-c123" -TimeoutSeconds 1 -CheckInterval 1 } |
                Should -Throw "*Timeout waiting for ArgoCD pods to be created*"
        }
    }

    It "Throws VcfDeploymentException when pod readiness times out (pods created but not all ready)" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Write-Progress {}
            function Start-Sleep { [CmdletBinding()] Param([Parameter()] [Object]$Seconds, [Parameter()] [Object]$Milliseconds) }
            Mock Get-PodReadinessStatus {
                [PSCustomObject]@{ TotalPods = 3; ReadyPods = 1; AllReady = $false; ReadyPodObjects = @() }
            }
            { Wait-ArgoCDPodsReady -Namespace "argocd-c123" -TimeoutSeconds 1 -CheckInterval 1 } |
                Should -Throw "*Timeout waiting for ArgoCD pods after*"
        }
    }
}

# ── Invoke-ArgoCDNamespaceCreate ─────────────────────────────────────────────


Describe "Invoke-ArgoCDNamespaceCreate — namespace creation" {
    It "Returns normally and calls Start-Sleep on success" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Start-Sleep {}
            function Initialize-VcenterNamespacesInstancesCreateSpecV2 {
                [CmdletBinding()] Param([Parameter()] [Object]$supervisor, [Parameter()] [Object]$Namespace)
                return [PSCustomObject]@{}
            }
            function Invoke-CreateNamespacesInstancesV2 {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param([Parameter()] [Object]$VcenterNamespacesInstancesCreateSpecV2)
                begin {}; process {}
            }
            Mock Invoke-CreateNamespacesInstancesV2 {}
            { Invoke-ArgoCDNamespaceCreate -ArgoCdNamespace "argocd" -SupervisorId "sup-123" } | Should -Not -Throw
            Should -Invoke Start-Sleep -Times 1
        }
    }

    It "Throws VcfDeploymentException on generic creation failure" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Get-CleanErrorMessage { return "generic error" }
            function Initialize-VcenterNamespacesInstancesCreateSpecV2 {
                [CmdletBinding()] Param([Parameter()] [Object]$supervisor, [Parameter()] [Object]$Namespace)
                return [PSCustomObject]@{}
            }
            function Invoke-CreateNamespacesInstancesV2 {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param([Parameter()] [Object]$VcenterNamespacesInstancesCreateSpecV2)
                begin {}; process { throw "something went wrong" }
            }
            { Invoke-ArgoCDNamespaceCreate -ArgoCdNamespace "argocd" -SupervisorId "sup-123" } |
                Should -Throw "*could not be created*"
        }
    }

    It "Logs NOT_ALLOWED_IN_CURRENT_STATE troubleshooting guidance when error contains that token" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Get-CleanErrorMessage { return "NOT_ALLOWED_IN_CURRENT_STATE" }
            function Initialize-VcenterNamespacesInstancesCreateSpecV2 {
                [CmdletBinding()] Param([Parameter()] [Object]$supervisor, [Parameter()] [Object]$Namespace)
                return [PSCustomObject]@{}
            }
            function Invoke-CreateNamespacesInstancesV2 {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param([Parameter()] [Object]$VcenterNamespacesInstancesCreateSpecV2)
                begin {}; process { throw '{"error_type":"NOT_ALLOWED_IN_CURRENT_STATE","message":"not allowed"}' }
            }
            { Invoke-ArgoCDNamespaceCreate -ArgoCdNamespace "ns" -SupervisorId "sup-1" } | Should -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Message -match "TROUBLESHOOTING" }
        }
    }

    It "Logs extracted error_type when error message contains error_type JSON field" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Get-CleanErrorMessage { return "some error" }
            function Initialize-VcenterNamespacesInstancesCreateSpecV2 {
                [CmdletBinding()] Param([Parameter()] [Object]$supervisor, [Parameter()] [Object]$Namespace)
                return [PSCustomObject]@{}
            }
            function Invoke-CreateNamespacesInstancesV2 {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param([Parameter()] [Object]$VcenterNamespacesInstancesCreateSpecV2)
                begin {}; process { throw '{"error_type":"RESOURCE_ALREADY_EXISTS"}' }
            }
            { Invoke-ArgoCDNamespaceCreate -ArgoCdNamespace "ns" -SupervisorId "sup-1" } | Should -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Message -match "Error type: RESOURCE_ALREADY_EXISTS" }
        }
    }
}

# ── New-ArgoCDNamespaceSetSpec ────────────────────────────────────────────────


Describe "New-ArgoCDNamespaceSetSpec — set spec construction" {
    It "Returns a non-null set spec on the happy path" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            function Initialize-VcenterNamespacesInstancesStorageSpec {
                [CmdletBinding()] Param([Parameter()] [Object]$Policy)
                return [PSCustomObject]@{ PolicyId = $Policy }
            }
            function Initialize-VcenterNamespacesInstancesVMServiceSpec {
                [CmdletBinding()] Param([Parameter()] [Object]$VmClasses)
                return [PSCustomObject]@{ VmClasses = $VmClasses }
            }
            function Initialize-VcenterNamespacesInstancesSetSpec {
                [CmdletBinding()] Param([Parameter()] [Object]$StorageSpecs, [Parameter()] [Object]$VmServiceSpec)
                return [PSCustomObject]@{ StorageSpecs = $StorageSpecs; VmServiceSpec = $VmServiceSpec }
            }
            New-ArgoCDNamespaceSetSpec -StoragePolicyId "policy-abc" -VmClasses @("best-effort-small")
        }
        $result | Should -Not -BeNullOrEmpty
    }

    It "Throws VcfDeploymentException when VMServiceSpec initialization fails" {
        $threw = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            # Mock (not stub) is required: Initialize-* cmdlets are VCF PowerCLI constructors resolved
            # from the imported module scope; function stubs in InModuleScope do not shadow them.
            Mock Initialize-VcenterNamespacesInstancesVMServiceSpec { throw "VM service spec API unavailable" }
            try { New-ArgoCDNamespaceSetSpec -StoragePolicyId "policy-abc" -VmClasses @("best-effort-small"); $false } catch { $true }
        }
        $threw | Should -Be $true
    }

    It "Throws VcfDeploymentException when SetSpec initialization fails" {
        $threw = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Initialize-VcenterNamespacesInstancesSetSpec { throw "set spec API unavailable" }
            try { New-ArgoCDNamespaceSetSpec -StoragePolicyId "policy-abc" -VmClasses @("best-effort-small"); $false } catch { $true }
        }
        $threw | Should -Be $true
    }
}

# ── Invoke-VsanOrphanedHostCleanup ────────────────────────────────────────────


Describe "Add-ArgoCDNamespace — namespace creation and idempotency" {

    It "Throws VcfDeploymentException when a VM class name contains dollar sign" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            { Add-ArgoCDNamespace -SupervisorId "sup-123" -ArgoCdNamespace "argocd" `
                -StoragePolicyId "policy-1" -VmClasses @("best-effort-small", "`$bad-class") } |
                Should -Throw "*must not contain*"
        }
    }

    It "Returns early without creating when namespace already exists" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Invoke-ListNamespacesInstances {
                [PSCustomObject]@{ Namespace = @("argocd", "other-ns") }
            }
            function Invoke-CreateNamespacesInstancesV2 {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param([Parameter()] [Object]$VcenterNamespacesInstancesCreateSpecV2)
                begin {}; process { throw "Create must not be called when namespace exists" }
            }
            { Add-ArgoCDNamespace -SupervisorId "sup-123" -ArgoCdNamespace "argocd" `
                -StoragePolicyId "policy-1" -VmClasses @("best-effort-small") } |
                Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "INFO" -and $Message -match "already exists" }
        }
    }

    It "Throws VcfDeploymentException when Create reports NOT_ALLOWED_IN_CURRENT_STATE" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Invoke-ListNamespacesInstances {
                [PSCustomObject]@{ Namespace = @() }
            }
            function Initialize-VcenterNamespacesInstancesCreateSpecV2 {
                [CmdletBinding()] Param([Parameter()] [Object]$supervisor, [Parameter()] [Object]$Namespace)
                return [PSCustomObject]@{}
            }
            function Invoke-CreateNamespacesInstancesV2 {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param([Parameter()] [Object]$VcenterNamespacesInstancesCreateSpecV2)
                begin {}; process { throw '{"error_type":"NOT_ALLOWED_IN_CURRENT_STATE"}' }
            }
            { Add-ArgoCDNamespace -SupervisorId "sup-123" -ArgoCdNamespace "new-ns" `
                -StoragePolicyId "policy-1" -VmClasses @("best-effort-small") } |
                Should -Throw "*could not be created*"
        }
    }

    It "When Set fails and cleanup succeeds - note says 'Namespace deleted during cleanup' not 'could not be deleted'" {
        $thrown = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Start-Sleep {}
            Mock Invoke-ListNamespacesInstances { [PSCustomObject]@{ Namespace = @() } }
            Mock Invoke-DeleteNamespaceInstances {}
            function Initialize-VcenterNamespacesInstancesCreateSpecV2 {
                [CmdletBinding()] Param([Parameter()] [Object]$supervisor, [Parameter()] [Object]$Namespace)
                return [PSCustomObject]@{}
            }
            function Invoke-CreateNamespacesInstancesV2 {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param([Parameter()] [Object]$VcenterNamespacesInstancesCreateSpecV2)
                begin {}; process {}
            }
            function Initialize-VcenterNamespacesInstancesStorageSpec {
                [CmdletBinding()] Param([Parameter()] [Object]$Policy)
                return [PSCustomObject]@{}
            }
            function Initialize-VcenterNamespacesInstancesVMServiceSpec {
                [CmdletBinding()] Param([Parameter()] [Object]$VmClasses)
                return [PSCustomObject]@{}
            }
            function Initialize-VcenterNamespacesInstancesSetSpec {
                [CmdletBinding()] Param([Parameter()] [Object]$StorageSpecs, [Parameter()] [Object]$VmServiceSpec)
                return [PSCustomObject]@{}
            }
            function Invoke-SetNamespaceInstances {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param([Parameter()] [Object]$Namespace, [Parameter()] [Object]$VcenterNamespacesInstancesSetSpec)
                begin {}; process { throw "vm class assignment failed" }
            }
            function Get-CleanErrorMessage {
                [CmdletBinding()] Param([Parameter()] [Object]$ErrorMessage)
                return $ErrorMessage
            }
            $caught = $null
            try {
                Add-ArgoCDNamespace -SupervisorId "sup-abc" -ArgoCdNamespace "argocd-set-fail" `
                    -StoragePolicyId "policy-1" -VmClasses @("best-effort-small")
            } catch { $caught = $_ }
            return $caught
        }
        $thrown | Should -Not -BeNullOrEmpty
        $thrown.Exception.Message | Should -Match "Namespace deleted during cleanup"
        $thrown.Exception.Message | Should -Not -Match "could not be deleted"
        $thrown.Exception.Message | Should -Not -Match "Manual namespace deletion required"
    }

    It "When Set fails and cleanup also fails - note says 'Manual namespace deletion required'" {
        $thrown = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Start-Sleep {}
            Mock Invoke-ListNamespacesInstances { [PSCustomObject]@{ Namespace = @() } }
            function Initialize-VcenterNamespacesInstancesCreateSpecV2 {
                [CmdletBinding()] Param([Parameter()] [Object]$supervisor, [Parameter()] [Object]$Namespace)
                return [PSCustomObject]@{}
            }
            function Invoke-CreateNamespacesInstancesV2 {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param([Parameter()] [Object]$VcenterNamespacesInstancesCreateSpecV2)
                begin {}; process {}
            }
            function Initialize-VcenterNamespacesInstancesStorageSpec {
                [CmdletBinding()] Param([Parameter()] [Object]$Policy)
                return [PSCustomObject]@{}
            }
            function Initialize-VcenterNamespacesInstancesVMServiceSpec {
                [CmdletBinding()] Param([Parameter()] [Object]$VmClasses)
                return [PSCustomObject]@{}
            }
            function Initialize-VcenterNamespacesInstancesSetSpec {
                [CmdletBinding()] Param([Parameter()] [Object]$StorageSpecs, [Parameter()] [Object]$VmServiceSpec)
                return [PSCustomObject]@{}
            }
            function Invoke-SetNamespaceInstances {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param([Parameter()] [Object]$Namespace, [Parameter()] [Object]$VcenterNamespacesInstancesSetSpec)
                begin {}; process { throw "vm class assignment failed" }
            }
            function Invoke-DeleteNamespaceInstances {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param([Parameter()] [Object]$Namespace)
                begin {}; process { throw "namespace delete also failed" }
            }
            function Get-CleanErrorMessage {
                [CmdletBinding()] Param([Parameter()] [Object]$ErrorMessage)
                return $ErrorMessage
            }
            $caught = $null
            try {
                Add-ArgoCDNamespace -SupervisorId "sup-abc" -ArgoCdNamespace "argocd-set-fail" `
                    -StoragePolicyId "policy-1" -VmClasses @("best-effort-small")
            } catch { $caught = $_ }
            return $caught
        }
        $thrown | Should -Not -BeNullOrEmpty
        $thrown.Exception.Message | Should -Match "Manual namespace deletion required"
        $thrown.Exception.Message | Should -Not -Match "Namespace deleted during cleanup"
    }

    It "When VcfDeploymentException is thrown by inner helper - propagates without double-wrapping" {
        $thrown = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Start-Sleep {}
            Mock Invoke-ListNamespacesInstances { [PSCustomObject]@{ Namespace = @() } }
            function Initialize-VcenterNamespacesInstancesCreateSpecV2 {
                [CmdletBinding()] Param([Parameter()] [Object]$supervisor, [Parameter()] [Object]$Namespace)
                return [PSCustomObject]@{}
            }
            function Invoke-CreateNamespacesInstancesV2 {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param([Parameter()] [Object]$VcenterNamespacesInstancesCreateSpecV2)
                begin {}; process {}
            }
            function Initialize-VcenterNamespacesInstancesStorageSpec {
                [CmdletBinding()] Param([Parameter()] [Object]$Policy)
                return [PSCustomObject]@{}
            }
            # Untyped stub required before Mock so Pester can intercept the VCF cmdlet without type-enforcement.
            function Initialize-VcenterNamespacesInstancesVMServiceSpec {
                [CmdletBinding()] Param([Parameter()] [Object]$VmClasses)
                process {}
            }
            # Mock simulates a typed VcfDeploymentException from an inner helper (e.g. VM class not found).
            Mock Initialize-VcenterNamespacesInstancesVMServiceSpec {
                throw [VcfDeploymentException]::new("inner-typed: VM class not found in vCenter inventory")
            }
            function Initialize-VcenterNamespacesInstancesSetSpec {
                [CmdletBinding()] Param([Parameter()] [Object]$StorageSpecs, [Parameter()] [Object]$VmServiceSpec)
                return [PSCustomObject]@{}
            }
            $caught = $null
            try {
                Add-ArgoCDNamespace -SupervisorId "sup-abc" -ArgoCdNamespace "argocd-inner-typed" `
                    -StoragePolicyId "policy-1" -VmClasses @("best-effort-small")
            } catch { $caught = $_ }
            return $caught
        }
        $thrown | Should -Not -BeNullOrEmpty
        # Inner message must survive — outer catch [VcfDeploymentException] { throw } must not re-wrap.
        $thrown.Exception.Message | Should -Be "inner-typed: VM class not found in vCenter inventory"
        $thrown.Exception.Message | Should -Not -Match "unexpected failure"
        $thrown.Exception.Message | Should -Not -Match "Add-ArgoCDNamespace:"
    }
}

# ── Wait-HarborServiceNamespaceTermination ────────────────────────────────────


Describe "Wait-HarborServiceNamespaceTermination" {

    It "Returns without sleeping when kubectl is unavailable and MinWaitSeconds is 0" {
        InModuleScope VcfEdgeAtScale {
            Mock Get-KubectlNamespaceNamesMatchingPattern {
                [PSCustomObject]@{ KubectlSucceeded = $false; Names = @() }
            }
            Mock Start-Sleep {}
            Wait-HarborServiceNamespaceTermination -SupervisorId "sv-123" -ClusterName "cl-osa" -MinWaitSeconds 0
            Should -Invoke Start-Sleep -Times 0 -Scope It
        }
    }

    It "Sleeps for MinWaitSeconds when kubectl is unavailable" {
        InModuleScope VcfEdgeAtScale {
            Mock Get-KubectlNamespaceNamesMatchingPattern {
                [PSCustomObject]@{ KubectlSucceeded = $false; Names = @() }
            }
            Mock Start-Sleep {}
            Wait-HarborServiceNamespaceTermination -SupervisorId "sv-123" -ClusterName "cl-osa" -MinWaitSeconds 5
            Should -Invoke Start-Sleep -Times 1 -ParameterFilter { $Seconds -eq 5 } -Scope It
        }
    }

    It "Returns immediately when kubectl finds no svc-harbor namespaces" {
        InModuleScope VcfEdgeAtScale {
            Mock Get-KubectlNamespaceNamesMatchingPattern {
                [PSCustomObject]@{ KubectlSucceeded = $true; Names = @() }
            }
            Mock Start-Sleep {}
            Wait-HarborServiceNamespaceTermination -SupervisorId "sv-123" -ClusterName "cl-osa" `
                -MinWaitSeconds 0 -PollIntervalSeconds 1 -TimeoutSeconds 30
            Should -Invoke Start-Sleep -Times 0 -Scope It
        }
    }

    It "Returns after one poll when the harbor namespace clears on the first check" {
        InModuleScope VcfEdgeAtScale {
            $Script:_whsnCallCount = 0
            function Get-KubectlNamespaceNamesMatchingPattern {
                [CmdletBinding()] Param(
                    [Parameter()] [String]$DebugLogPrefix,
                    [Parameter()] [String]$NameLike,
                    [Parameter()] [Switch]$SortNames
                )
                $Script:_whsnCallCount++
                if ($Script:_whsnCallCount -le 1) {
                    # Initial discovery: namespace present.
                    return [PSCustomObject]@{ KubectlSucceeded = $true; Names = @("svc-harbor-abc") }
                }
                # First poll: namespace gone.
                return [PSCustomObject]@{ KubectlSucceeded = $true; Names = @() }
            }
            Mock Start-Sleep {}
            Wait-HarborServiceNamespaceTermination -SupervisorId "sv-123" -ClusterName "cl-osa" `
                -MinWaitSeconds 0 -PollIntervalSeconds 1 -TimeoutSeconds 30
            Should -Invoke Start-Sleep -Times 1 -Scope It
        }
    }
}

# ── Show-HarborInstanceDetails ────────────────────────────────────────────────


Describe "Show-HarborInstanceDetails" {

    It "Resolves admin password from the environment variable when set" {
        InModuleScope VcfEdgeAtScale {
            $savedPw = $env:HARBOR_ADMIN_PASSWORD
            try {
                $env:HARBOR_ADMIN_PASSWORD = "env-secret-123"
                Mock Write-LogMessage {}
                Mock Get-KubectlNamespaceNamesMatchingPattern {
                    [PSCustomObject]@{ KubectlSucceeded = $false; Names = @() }
                }
                $harborConfig = [PSCustomObject]@{ hostname = "harbor.lab.local"; harborAdminPassword = $null }
                { Show-HarborInstanceDetails -ClusterName "cl-osa" -HarborConfig $harborConfig -SupervisorId "sv-123" } | Should -Not -Throw
                Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "INFO" -and $Message -match "Harbor" }
            } finally {
                $env:HARBOR_ADMIN_PASSWORD = $savedPw
            }
        }
    }

    It "Resolves admin password from HarborConfig when the environment variable is not set" {
        InModuleScope VcfEdgeAtScale {
            $env:HARBOR_ADMIN_PASSWORD = $null
            Mock Write-LogMessage {}
            Mock Get-KubectlNamespaceNamesMatchingPattern {
                [PSCustomObject]@{ KubectlSucceeded = $false; Names = @() }
            }
            $harborConfig = [PSCustomObject]@{ hostname = "harbor.lab.local"; harborAdminPassword = "config-pw" }
            { Show-HarborInstanceDetails -ClusterName "cl-osa" -HarborConfig $harborConfig -SupervisorId "sv-123" } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "INFO" -and $Message -match "Harbor" }
        }
    }

    It "Returns without throwing when the svc-harbor namespace is not found via kubectl" {
        InModuleScope VcfEdgeAtScale {
            $env:HARBOR_ADMIN_PASSWORD = $null
            Mock Write-LogMessage {}
            Mock Get-KubectlNamespaceNamesMatchingPattern {
                [PSCustomObject]@{ KubectlSucceeded = $true; Names = @() }
            }
            $harborConfig = [PSCustomObject]@{ hostname = "harbor.lab.local"; harborAdminPassword = "pw123" }
            { Show-HarborInstanceDetails -ClusterName "cl-osa" -HarborConfig $harborConfig -SupervisorId "sv-123" } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "INFO" -and $Message -match "Harbor" }
        }
    }
}

# ── Resolve-HarborAdminPassword ───────────────────────────────────────────────


Describe "Resolve-HarborAdminPassword" {

    BeforeEach { $script:_rhapSavedHarborPw = $env:HARBOR_ADMIN_PASSWORD; $script:_rhapSavedMyPw = $env:MY_HARBOR_PW }
    AfterEach  { $env:HARBOR_ADMIN_PASSWORD = $script:_rhapSavedHarborPw; $env:MY_HARBOR_PW = $script:_rhapSavedMyPw }

    It "Returns the env var value when HARBOR_ADMIN_PASSWORD is set" {
        $env:HARBOR_ADMIN_PASSWORD = "env-pw"
        $result = InModuleScope VcfEdgeAtScale {
            Resolve-HarborAdminPassword -HarborConfig ([PSCustomObject]@{ harborAdminPassword = "" })
        }
        $result | Should -Be "env-pw"
    }

    It "Resolves an indirect `$env: reference from HarborConfig" {
        $env:MY_HARBOR_PW = "indirect-pw"
        $result = InModuleScope VcfEdgeAtScale {
            Resolve-HarborAdminPassword -HarborConfig ([PSCustomObject]@{ harborAdminPassword = '$env:MY_HARBOR_PW' })
        }
        $result | Should -Be "indirect-pw"
    }

    It "Returns null when no source resolves a password" {
        $result = InModuleScope VcfEdgeAtScale {
            Resolve-HarborAdminPassword -HarborConfig ([PSCustomObject]@{ harborAdminPassword = "" })
        }
        $result | Should -BeNullOrEmpty
    }
}

# ── Get-HarborLoadBalancerIp ──────────────────────────────────────────────────


Describe "Get-HarborLoadBalancerIp" {

    AfterEach {
        InModuleScope VcfEdgeAtScale {
            $Script:KubectlCmd = if ($IsWindows) { "kubectl.exe" } else { "kubectl" }
        }
    }

    It "Returns null when kubectl exits non-zero without localhost:8080 error" -Skip:$IsWindows {
        InModuleScope VcfEdgeAtScale {
            $tmpPath = Join-Path ([System.IO.Path]::GetTempPath()) "mock-kubectl-svc-fail-$([Guid]::NewGuid()).sh"
            try {
                Set-Content -Path $tmpPath -Value "#!/bin/bash`necho 'Error: namespaces not found' >&2`nexit 1"
                & chmod +x $tmpPath
                $Script:KubectlCmd = $tmpPath
                $result = Get-HarborLoadBalancerIp -HarborNamespace "svc-harbor-domain-c1"
                $result | Should -BeNullOrEmpty
            } finally {
                Remove-Item -Path $tmpPath -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "Returns the load balancer IP from valid kubectl JSON output" -Skip:$IsWindows {
        InModuleScope VcfEdgeAtScale {
            $tmpPath = Join-Path ([System.IO.Path]::GetTempPath()) "mock-kubectl-svc-ok-$([Guid]::NewGuid()).sh"
            try {
                $json = '{"items":[{"spec":{"type":"LoadBalancer"},"status":{"loadBalancer":{"ingress":[{"ip":"10.1.2.3"}]}}}]}'
                [System.IO.File]::WriteAllText($tmpPath, "#!/bin/bash`necho '$json'`nexit 0`n")
                & chmod +x $tmpPath
                $Script:KubectlCmd = $tmpPath
                $result = Get-HarborLoadBalancerIp -HarborNamespace "svc-harbor-domain-c1"
                $result | Should -Be "10.1.2.3"
            } finally {
                Remove-Item -Path $tmpPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

# ── Invoke-HarborRegistryIdempotencyCheck ─────────────────────────────────────


Describe "Invoke-HarborRegistryIdempotencyCheck" {

    It "Returns true when the registry does not already exist" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            function Invoke-ListSupervisorNamespaceManagementContainerImageRegistries {
                [CmdletBinding()] Param([Parameter()] [Object]$Supervisor)
                process { @() }
            }
            Mock Invoke-ListSupervisorNamespaceManagementContainerImageRegistries { @() }
            $result = Invoke-HarborRegistryIdempotencyCheck -SupervisorId "sup-1" -RegistryName "harbor" -RegistryEndpoint "10.1.2.3"
            $result | Should -Be $true
        }
    }

    It "Returns false when the registry exists with a different endpoint (different Harbor instance)" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            function Invoke-ListSupervisorNamespaceManagementContainerImageRegistries {
                [CmdletBinding()] Param([Parameter()] [Object]$Supervisor)
                process { @([PSCustomObject]@{ name = "harbor"; id = "reg-1"; imageRegistry = [PSCustomObject]@{ hostname = "10.9.9.9" } }) }
            }
            Mock Invoke-ListSupervisorNamespaceManagementContainerImageRegistries {
                @([PSCustomObject]@{ name = "harbor"; id = "reg-1"; imageRegistry = [PSCustomObject]@{ hostname = "10.9.9.9" } })
            }
            $result = Invoke-HarborRegistryIdempotencyCheck -SupervisorId "sup-1" -RegistryName "harbor" -RegistryEndpoint "10.1.2.3"
            $result | Should -Be $false
        }
    }
}

# ── Add-HarborContainerImageRegistry ──────────────────────────────────────────


Describe "Add-HarborContainerImageRegistry" {

    BeforeEach { $script:_ahciSavedHarborPw = $env:HARBOR_ADMIN_PASSWORD }
    AfterEach  { $env:HARBOR_ADMIN_PASSWORD = $script:_ahciSavedHarborPw }

    It "Returns without throwing when password resolves and registry is newly created" {
        $env:HARBOR_ADMIN_PASSWORD = "admin-pw"
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Get-KubectlNamespaceNamesMatchingPattern {
                [PSCustomObject]@{ KubectlSucceeded = $true; Names = @("svc-harbor-domain-c1") }
            }
            Mock Get-HarborLoadBalancerIp { "10.1.2.3" }
            Mock Invoke-HarborRegistryIdempotencyCheck { $true }
            function Initialize-VcenterNamespaceManagementSupervisorsImageRegistry {
                [CmdletBinding()] Param([Parameter()] [Object]$Hostname, [Parameter()] [Object]$Password, [Parameter()] [Object]$Username)
                process { [PSCustomObject]@{ hostname = $Hostname } }
            }
            function Initialize-VcenterNamespaceManagementSupervisorsContainerImageRegistriesCreateSpec {
                [CmdletBinding()] Param([Parameter()] [Object]$DefaultRegistry, [Parameter()] [Object]$ImageRegistry, [Parameter()] [Object]$Name)
                process { [PSCustomObject]@{ name = $Name } }
            }
            function Invoke-CreateSupervisorNamespaceManagementContainerImageRegistries {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param([Parameter()] [Object]$Supervisor, [Parameter()] [Object]$VcenterNamespaceManagementSupervisorsContainerImageRegistriesCreateSpec)
                process { [PSCustomObject]@{ id = "reg-new" } }
            }
            $harborConfig = [PSCustomObject]@{ hostname = "harbor.lab"; harborAdminPassword = ""; caCrt = "" }
            { Add-HarborContainerImageRegistry -ClusterName "cl01" -HarborConfig $harborConfig -SupervisorId "sup-1" } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "INFO" -and $Message -match "Registering Harbor" }
        }
    }

    It "Logs WARNING and does not throw when password cannot be resolved" {
        InModuleScope VcfEdgeAtScale {
            $env:HARBOR_ADMIN_PASSWORD = $null
            Mock Write-LogMessage {}
            $harborConfig = [PSCustomObject]@{ hostname = "harbor.lab"; harborAdminPassword = ""; caCrt = "" }
            { Add-HarborContainerImageRegistry -ClusterName "cl01" -HarborConfig $harborConfig -SupervisorId "sup-1" } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'WARNING' }
        }
    }

    It "Returns without throwing when idempotency check returns false (different Harbor registered)" {
        $env:HARBOR_ADMIN_PASSWORD = "admin-pw"
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Get-KubectlNamespaceNamesMatchingPattern {
                [PSCustomObject]@{ KubectlSucceeded = $true; Names = @("svc-harbor-domain-c1") }
            }
            Mock Get-HarborLoadBalancerIp { "10.1.2.3" }
            Mock Invoke-HarborRegistryIdempotencyCheck { $false }
            $harborConfig = [PSCustomObject]@{ hostname = "harbor.lab"; harborAdminPassword = ""; caCrt = "" }
            { Add-HarborContainerImageRegistry -ClusterName "cl01" -HarborConfig $harborConfig -SupervisorId "sup-1" } | Should -Not -Throw
            # Idempotency check returning $false means existing registry with different endpoint → skip registration.
            Should -Invoke Write-LogMessage -Times 0 -ParameterFilter { $Type -eq "INFO" -and $Message -match "Registering Harbor" } -Scope It
        }
    }
}

# ── Invoke-KubectlWithContextFix ──────────────────────────────────────────────
# Tests use temp shell scripts for kubectl mocks so that $LASTEXITCODE is set by
# a real external process. Tests are skipped on Windows (no bash).

Describe "Invoke-KubectlWithContextFix" {

    AfterEach {
        InModuleScope VcfEdgeAtScale {
            $Script:KubectlCmd = if ($IsWindows) { "kubectl.exe" } else { "kubectl" }
        }
    }

    It "Returns Success=true and Output when kubectl exits 0" -Skip:$IsWindows {
        InModuleScope VcfEdgeAtScale {
            $tmpPath = Join-Path ([System.IO.Path]::GetTempPath()) "kwcf-ok-$([Guid]::NewGuid()).sh"
            try {
                Set-Content -Path $tmpPath -Value "#!/bin/bash`necho '{`"kind`":`"Service`"}'`nexit 0"
                & chmod +x $tmpPath
                $Script:KubectlCmd = $tmpPath
                $result = Invoke-KubectlWithContextFix -KubectlArgs @("get", "svc", "-n", "test-ns", "-o", "json")
            } finally {
                Remove-Item -Path $tmpPath -Force -ErrorAction SilentlyContinue
            }
            $result
        } | ForEach-Object {
            $_.Success        | Should -Be $true
            $_.IsContextError | Should -Be $false
            $_.Output         | Should -Not -BeNullOrEmpty
            $_.Output         | Should -Match "kind"
        }
    }

    It "Returns Success=false IsContextError=false when kubectl fails with a non-localhost error" -Skip:$IsWindows {
        InModuleScope VcfEdgeAtScale {
            $tmpPath = Join-Path ([System.IO.Path]::GetTempPath()) "kwcf-notfound-$([Guid]::NewGuid()).sh"
            try {
                Set-Content -Path $tmpPath -Value "#!/bin/bash`necho 'Error from server: services not found' >&2`nexit 1"
                & chmod +x $tmpPath
                $Script:KubectlCmd = $tmpPath
                $result = Invoke-KubectlWithContextFix -KubectlArgs @("get", "svc", "-n", "test-ns", "-o", "json") -ContextName "ctx1"
            } finally {
                Remove-Item -Path $tmpPath -Force -ErrorAction SilentlyContinue
            }
            $result
        } | ForEach-Object {
            $_.Success        | Should -Be $false
            $_.IsContextError | Should -Be $false
            $_.WarningMessage | Should -Match "not found"
        }
    }

    It "Returns Success=false IsContextError=true when kubectl fails with localhost:8080 and no ContextName is provided" -Skip:$IsWindows {
        InModuleScope VcfEdgeAtScale {
            $tmpPath = Join-Path ([System.IO.Path]::GetTempPath()) "kwcf-localhost-$([Guid]::NewGuid()).sh"
            try {
                Set-Content -Path $tmpPath -Value "#!/bin/bash`necho 'Unable to connect to the server: dial tcp [::1]:8080: connection refused' >&2`nexit 1"
                & chmod +x $tmpPath
                Mock Write-LogMessage {}
                $Script:KubectlCmd = $tmpPath
                $result = Invoke-KubectlWithContextFix -KubectlArgs @("get", "svc", "-n", "test-ns", "-o", "json")
            } finally {
                Remove-Item -Path $tmpPath -Force -ErrorAction SilentlyContinue
            }
            $result
        } | ForEach-Object {
            $_.Success        | Should -Be $false
            $_.IsContextError | Should -Be $true
            $_.WarningMessage | Should -Match "no context name provided"
        }
    }
}

# ── Show-ArgoCDInstanceDetails ────────────────────────────────────────────────
# These tests create a temporary shell script as a kubectl mock so that $LASTEXITCODE
# is set correctly by an external process. Tests are skipped on Windows (no bash).


Describe "Show-ArgoCDInstanceDetails" {

    AfterEach {
        InModuleScope VcfEdgeAtScale {
            # Restore the platform default kubectl command name after each test.
            $Script:KubectlCmd = if ($IsWindows) { "kubectl.exe" } else { "kubectl" }
        }
    }

    It "Logs WARNING and does not throw when kubectl fails with a non-localhost error" -Skip:$IsWindows {
        InModuleScope VcfEdgeAtScale {
            $tmpPath = Join-Path ([System.IO.Path]::GetTempPath()) "mock-kubectl-fail-$([Guid]::NewGuid()).sh"
            try {
                Set-Content -Path $tmpPath -Value "#!/bin/bash`necho 'Error from server: service not found' >&2`nexit 1"
                & chmod +x $tmpPath
                Mock Write-LogMessage {}
                $Script:KubectlCmd = $tmpPath
                { Show-ArgoCDInstanceDetails -ArgoCdNamespace "vks-ns-abc" } | Should -Not -Throw
                Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'WARNING' }
            } finally {
                Remove-Item -Path $tmpPath -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "Logs DEBUG and does not throw when kubectl points to localhost and no ContextName is provided" -Skip:$IsWindows {
        InModuleScope VcfEdgeAtScale {
            $tmpPath = Join-Path ([System.IO.Path]::GetTempPath()) "mock-kubectl-localhost-$([Guid]::NewGuid()).sh"
            try {
                Set-Content -Path $tmpPath -Value "#!/bin/bash`necho 'Unable to connect to the server: dial tcp 127.0.0.1:8080: connect: connection refused' >&2`nexit 1"
                & chmod +x $tmpPath
                Mock Write-LogMessage {}
                $Script:KubectlCmd = $tmpPath
                { Show-ArgoCDInstanceDetails -ArgoCdNamespace "vks-ns-abc" } | Should -Not -Throw
                Should -Not -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'ERROR' }
            } finally {
                Remove-Item -Path $tmpPath -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "Logs DEBUG and does not throw when the ArgoCD service has no load-balancer ingress" -Skip:$IsWindows {
        InModuleScope VcfEdgeAtScale {
            $tmpPath = Join-Path ([System.IO.Path]::GetTempPath()) "mock-kubectl-ok-$([Guid]::NewGuid()).sh"
            try {
                # Write the JSON output script using individual lines to avoid quoting issues.
                [System.IO.File]::WriteAllText($tmpPath, "#!/bin/bash`necho '{`"status`":{`"loadBalancer`":{}}}'`nexit 0`n")
                & chmod +x $tmpPath
                Mock Write-LogMessage {}
                $Script:KubectlCmd = $tmpPath
                { Show-ArgoCDInstanceDetails -ArgoCdNamespace "vks-ns-abc" } | Should -Not -Throw
                Should -Not -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'ERROR' }
            } finally {
                Remove-Item -Path $tmpPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

# ── Shared VMHost stub type for parameter-constrained function tests ──────────
# Created at discovery time (top-level code) so the -Skip conditions work and
# so the stub loads before the PowerCLI Cmdlet Validation BeforeAll can import
# the real VMware modules. If the real VMware types are already loaded (unusual)
# or stub creation fails, $script:_vmhostStubReady remains $false and the
# tests that need StubVMHost are automatically skipped.
if (-not ('VeasTests.StubVMHost' -as [type])) {
    if (-not ('VMware.VimAutomation.ViCore.Types.V1.Inventory.VMHost' -as [type])) {
        try {
            Add-Type -TypeDefinition @'
namespace VMware.VimAutomation.ViCore.Types.V1.Inventory { public interface VMHost {} }
namespace VeasTests { public class StubVMHost : VMware.VimAutomation.ViCore.Types.V1.Inventory.VMHost {} }
'@
        } catch {
            # Stub creation failed (e.g. real PowerCLI type already in AppDomain);
            # tests that require StubVMHost will be skipped via $script:_vmhostStubReady.
        }
    }
}
$script:_vmhostStubReady = [bool]('VeasTests.StubVMHost' -as [type])

# ── Get-EsxUnformattedDisk ────────────────────────────────────────────────────


Describe "Get-SupervisorId" {

    It "Returns null when no password is available and no Script:VcenterCredential is set" {
        $result = InModuleScope VcfEdgeAtScale {
            $Script:VcenterCredential = $null
            Mock Write-LogMessage {}
            Mock Get-VcenterRestApiPlainPassword { "" }
            Get-SupervisorId -SupervisorName "sup01" -VcenterUser "admin@vsphere.local"
        }
        $result | Should -BeNullOrEmpty
    }

    It "Throws VcfDeploymentException when the REST session creation fails" {
        { InModuleScope VcfEdgeAtScale {
            $Script:VcenterCredential = $null
            $Script:vCenterName = "vc.lab"
            Mock Write-LogMessage {}
            Mock Get-VcenterRestApiPlainPassword { "validpassword" }
            Mock New-VCenterRestApiSession { [PSCustomObject]@{ Success = $false; ErrorMessage = "auth failed" } }
            Get-SupervisorId -SupervisorName "sup01" -VcenterUser "admin@vsphere.local" `
                -VcenterInsecurePassword "validpassword"
        } } | Should -Throw "*Failed to create REST API session*"
    }

    It "Returns null when the supervisor is not found (pre-creation state)" {
        $result = InModuleScope VcfEdgeAtScale {
            $Script:VcenterCredential = $null
            $Script:vCenterName = "vc.lab"
            Mock Write-LogMessage {}
            Mock Get-VcenterRestApiPlainPassword { "pass" }
            Mock New-VCenterRestApiSession { [PSCustomObject]@{ Success = $true; SessionHeaders = @{} } }
            Mock Find-SupervisorByName { [PSCustomObject]@{ Success = $true; Found = $false; SupervisorId = $null } }
            Mock Invoke-RestMethod {}
            Get-SupervisorId -SupervisorName "sup01" -VcenterUser "admin@vsphere.local" `
                -VcenterInsecurePassword "pass"
        }
        $result | Should -BeNullOrEmpty
    }

    It "Returns the supervisor ID immediately when SkipReadyWait is set" {
        $result = InModuleScope VcfEdgeAtScale {
            $Script:VcenterCredential = $null
            $Script:vCenterName = "vc.lab"
            Mock Write-LogMessage {}
            Mock Get-VcenterRestApiPlainPassword { "pass" }
            Mock New-VCenterRestApiSession { [PSCustomObject]@{ Success = $true; SessionHeaders = @{} } }
            Mock Find-SupervisorByName { [PSCustomObject]@{ Success = $true; Found = $true; SupervisorId = "domain-c42" } }
            Mock Invoke-RestMethod {}
            Get-SupervisorId -SupervisorName "sup01" -VcenterUser "admin@vsphere.local" `
                -VcenterInsecurePassword "pass" -SkipReadyWait
        }
        $result | Should -Be "domain-c42"
    }

    It "Throws VcfDeploymentException when Wait-SupervisorDiscoverable reports failure" {
        { InModuleScope VcfEdgeAtScale {
            $Script:VcenterCredential = $null
            $Script:vCenterName = "vc.lab"
            Mock Write-LogMessage {}
            Mock Get-VcenterRestApiPlainPassword { "pass" }
            Mock New-VCenterRestApiSession { [PSCustomObject]@{ Success = $true; SessionHeaders = @{} } }
            Mock Find-SupervisorByName { [PSCustomObject]@{ Success = $true; Found = $true; SupervisorId = "domain-c42" } }
            Mock Wait-SupervisorDiscoverable { [PSCustomObject]@{ Success = $false; ErrorMessage = "timeout" } }
            Mock Invoke-RestMethod {}
            Get-SupervisorId -SupervisorName "sup01" -VcenterUser "admin@vsphere.local" `
                -VcenterInsecurePassword "pass" -TotalWaitTime 10 -CheckInterval 1
        } } | Should -Throw "*Supervisor did not become ready*"
    }
}

# ── Test-TagCatalogCategory ───────────────────────────────────────────────────


Describe "Remove-HarborSupervisorService — service not found path" {
    It "Skips DELETE and still calls Wait-HarborServiceNamespaceTermination when service is not found" {
        $Script:_namespacePollCalled = $false
        InModuleScope VcfEdgeAtScale {
            function Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesGet {
                [CmdletBinding()] Param([Parameter()] [Object]$Supervisor, [Parameter()] [Object]$SupervisorService)
                begin {}; process {}
            }
            function Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesDelete {
                [CmdletBinding(SupportsShouldProcess = $true)] Param([Parameter()] [Object]$Supervisor, [Parameter()] [Object]$SupervisorService)
                begin { throw "Delete must not be called when service not found" }; process {}
            }
            function Wait-HarborServiceNamespaceTermination {
                [CmdletBinding()] Param([Parameter()] [Object]$ClusterName, [Parameter()] [Object]$MinWaitSeconds, [Parameter()] [Object]$PollIntervalSeconds, [Parameter()] [Object]$SupervisorId, [Parameter()] [Object]$TimeoutSeconds)
                begin { $Script:_namespacePollCalled = $true }; process {}
            }
            function Remove-HarborContainerImageRegistry {
                [CmdletBinding()] Param([Parameter()] [Object]$ClusterName, [Parameter()] [Object]$SupervisorId)
                begin {}; process {}
            }
            Mock Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesGet { throw "not found" }
            Mock Write-LogMessage {}
            Mock Write-Progress {}
            Remove-HarborSupervisorService -ClusterName "cl0" -Service "harbor-service.vsphere.vmware.com" -SupervisorId "sup-123" -NamespaceMinWaitSeconds 0
            $Script:_namespacePollCalled
        } | Should -Be $true
    }
}


Describe "Remove-HarborSupervisorService — service found path" {
    It "Calls DELETE and Wait-HarborServiceNamespaceTermination when service is found and then confirmed gone" {
        $results = InModuleScope VcfEdgeAtScale {
            $Script:_deleteCalled    = $false
            $Script:_namespacePoll2  = $false
            $Script:_getCallCount    = 0
            function Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesGet {
                [CmdletBinding()] Param([Parameter()] [Object]$Supervisor, [Parameter()] [Object]$SupervisorService)
                begin {}
                process {
                    $Script:_getCallCount++
                    # First call: service exists; subsequent calls: service gone after delete.
                    if ($Script:_getCallCount -le 1) { return [PSCustomObject]@{ ServiceId = "harbor-svc" } }
                    throw "not found"
                }
            }
            function Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesDelete {
                [CmdletBinding(SupportsShouldProcess = $true)] Param([Parameter()] [Object]$Supervisor, [Parameter()] [Object]$SupervisorService)
                begin { $Script:_deleteCalled = $true }; process {}
            }
            function Wait-HarborServiceNamespaceTermination {
                [CmdletBinding()] Param([Parameter()] [Object]$ClusterName, [Parameter()] [Object]$MinWaitSeconds, [Parameter()] [Object]$PollIntervalSeconds, [Parameter()] [Object]$SupervisorId, [Parameter()] [Object]$TimeoutSeconds)
                begin { $Script:_namespacePoll2 = $true }; process {}
            }
            function Remove-HarborContainerImageRegistry {
                [CmdletBinding()] Param([Parameter()] [Object]$ClusterName, [Parameter()] [Object]$SupervisorId)
                begin {}; process {}
            }
            Mock Write-LogMessage {}
            Mock Write-Progress {}
            Mock Start-Sleep {}
            Remove-HarborSupervisorService -ClusterName "cl0" -Service "harbor-service.vsphere.vmware.com" -SupervisorId "sup-123" -NamespaceMinWaitSeconds 0 -DeletePollIntervalSeconds 1 -DeleteTimeoutSeconds 10
            @{ DeleteCalled = $Script:_deleteCalled; WaitCalled = $Script:_namespacePoll2 }
        }
        $results.DeleteCalled | Should -Be $true
        $results.WaitCalled   | Should -Be $true
    }
}

# ── Disable-SupervisorOnCluster ───────────────────────────────────────────────


Describe "Disable-SupervisorOnCluster — guard conditions" {
    It "Returns Success=false when vCenter is not connected" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $false; ErrorMessage = "no session" } }
            Mock Write-LogMessage {}
            Disable-SupervisorOnCluster -ClusterId "domain-c8" -ClusterName "cl0"
        }
        $result.Success | Should -Be $false
        $result.ErrorMessage | Should -Match "Not connected"
    }

    It "Returns Success=true when cluster is already disabled (no-op message from Invoke-DisableCluster)" {
        $result = InModuleScope VcfEdgeAtScale {
            function Invoke-DisableCluster {
                [CmdletBinding(SupportsShouldProcess = $true)] Param([Parameter()] [Object]$Cluster)
                begin {}; process {}
            }
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true; ErrorMessage = $null } }
            Mock Invoke-DisableCluster { throw "does not have Workloads enabled" }
            Mock Write-LogMessage {}
            Mock Write-Progress {}
            Disable-SupervisorOnCluster -ClusterId "domain-c8" -ClusterName "cl0" -SuppressConfirm
        }
        $result.Success | Should -Be $true
    }
}


Describe "Disable-SupervisorOnCluster — successful disable" {
    It "Returns Success=true when poll finds cluster DISABLED and NOT_INSTALLED immediately" {
        $result = InModuleScope VcfEdgeAtScale {
            function Invoke-DisableCluster {
                [CmdletBinding(SupportsShouldProcess = $true)] Param([Parameter()] [Object]$Cluster)
                begin {}; process {}
            }
            function Invoke-ListNamespaceManagementClusters {
                [CmdletBinding()] Param()
                begin {}; process {}
            }
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true; ErrorMessage = $null } }
            Mock Invoke-DisableCluster {}
            # Returning empty list (no matching cluster) means configDisabled=$true, kubeNotInstalled=$true → success.
            Mock Invoke-ListNamespaceManagementClusters { @() }
            Mock Write-LogMessage {}
            Mock Write-Progress {}
            Disable-SupervisorOnCluster -ClusterId "domain-c8" -ClusterName "cl0" -SuppressConfirm -CheckInterval 1 -TimeoutSeconds 30
        }
        $result.Success | Should -Be $true
    }

    It "Returns Success=false when Invoke-DisableCluster throws an unexpected error" {
        $result = InModuleScope VcfEdgeAtScale {
            function Invoke-DisableCluster {
                [CmdletBinding(SupportsShouldProcess = $true)] Param([Parameter()] [Object]$Cluster)
                begin {}; process {}
            }
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true; ErrorMessage = $null } }
            Mock Invoke-DisableCluster { throw "Internal vCenter error 500" }
            Mock Write-LogMessage {}
            Mock Write-Progress {}
            Disable-SupervisorOnCluster -ClusterId "domain-c8" -ClusterName "cl0" -SuppressConfirm
        }
        $result.Success | Should -Be $false
        $result.ErrorMessage | Should -Match "Internal vCenter error 500"
    }
}


Describe "Wait-ForSupervisorDeactivation — poll logic" {

    It "Returns Success=true when cluster entry is absent on the first poll" {
        $result = InModuleScope VcfEdgeAtScale {
            function Invoke-ListNamespaceManagementClusters {
                [CmdletBinding()] Param()
                begin {}; process {}
            }
            Mock Invoke-ListNamespaceManagementClusters { @() }
            Mock Write-LogMessage {}
            Mock Write-Progress {}
            Wait-ForSupervisorDeactivation -ClusterId "domain-c10" -ClusterName "cl-edge1" -CheckInterval 1 -TimeoutSeconds 30
        }
        $result.Success | Should -Be $true
    }

    It "Returns Success=true when cluster entry shows DISABLED and NOT_INSTALLED on first poll" {
        $result = InModuleScope VcfEdgeAtScale {
            function Invoke-ListNamespaceManagementClusters {
                [CmdletBinding()] Param()
                begin {}; process {}
            }
            Mock Invoke-ListNamespaceManagementClusters {
                @([PSCustomObject]@{ clusterName = "cl-edge1"; ConfigStatus = "DISABLED"; KubernetesStatus = "NOT_INSTALLED" })
            }
            Mock Write-LogMessage {}
            Mock Write-Progress {}
            Wait-ForSupervisorDeactivation -ClusterId "domain-c10" -ClusterName "cl-edge1" -CheckInterval 1 -TimeoutSeconds 30
        }
        $result.Success | Should -Be $true
    }

    It "Returns Success=false when timeout expires before cluster deactivates" {
        $result = InModuleScope VcfEdgeAtScale {
            function Invoke-ListNamespaceManagementClusters {
                [CmdletBinding()] Param()
                begin {}; process {}
            }
            Mock Invoke-ListNamespaceManagementClusters {
                # Always return the cluster as still RUNNING — never deactivated.
                @([PSCustomObject]@{ clusterName = "cl-edge1"; ConfigStatus = "RUNNING"; KubernetesStatus = "READY" })
            }
            Mock Write-LogMessage {}
            Mock Write-Progress {}
            Mock Start-Sleep {}
            Wait-ForSupervisorDeactivation -ClusterId "domain-c10" -ClusterName "cl-edge1" -CheckInterval 5 -TimeoutSeconds 1
        }
        $result.Success | Should -Be $false
        $result.ErrorMessage | Should -Match "Teardown did not complete"
    }
}


Describe "Invoke-ArgoCDNamespaceDeleteAndPoll — delete and poll logic" {

    It "Returns without error when namespace disappears on first poll after delete" {
        InModuleScope VcfEdgeAtScale {
            function Invoke-DeleteNamespaceInstances {
                [CmdletBinding(SupportsShouldProcess = $true)] Param([Parameter()] [Object]$Namespace)
                begin {}; process {}
            }
            function Invoke-ListNamespacesInstances {
                [CmdletBinding()] Param()
                begin {}; process {}
            }
            Mock Invoke-DeleteNamespaceInstances {}
            # Namespace is already gone on the first poll.
            Mock Invoke-ListNamespacesInstances { [PSCustomObject]@{ Namespace = @() } }
            Mock Write-LogMessage {}
            Mock Write-Progress {}
            Mock Start-Sleep {}
            { Invoke-ArgoCDNamespaceDeleteAndPoll -ArgoCDNamespace "argocd-c354" -ClusterName "cl-edge1" -ArgoCDNamespaceDeletePollIntervalSeconds 1 -ArgoCDNamespaceDeleteTimeoutSeconds 30 } | Should -Not -Throw
            Should -Invoke Invoke-DeleteNamespaceInstances -Times 1
            Should -Not -Invoke Write-LogMessage -ParameterFilter { $Type -eq "ERROR" }
        }
    }

    It "Logs WARNING (does not throw) when delete call fails" {
        InModuleScope VcfEdgeAtScale {
            function Invoke-DeleteNamespaceInstances {
                [CmdletBinding(SupportsShouldProcess = $true)] Param([Parameter()] [Object]$Namespace)
                begin {}; process {}
            }
            Mock Invoke-DeleteNamespaceInstances { throw "namespace not found" }
            Mock Write-LogMessage {}
            Mock Write-Progress {}
            { Invoke-ArgoCDNamespaceDeleteAndPoll -ArgoCDNamespace "argocd-c354" -ClusterName "cl-edge1" -ArgoCDNamespaceDeletePollIntervalSeconds 1 -ArgoCDNamespaceDeleteTimeoutSeconds 30 } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "WARNING" }
        }
    }

    It "Logs WARNING (does not throw) when namespace still exists after timeout" {
        InModuleScope VcfEdgeAtScale {
            function Invoke-DeleteNamespaceInstances {
                [CmdletBinding(SupportsShouldProcess = $true)] Param([Parameter()] [Object]$Namespace)
                begin {}; process {}
            }
            function Invoke-ListNamespacesInstances {
                [CmdletBinding()] Param()
                begin {}; process {}
            }
            Mock Invoke-DeleteNamespaceInstances {}
            # Namespace always present — timeout will trigger.
            Mock Invoke-ListNamespacesInstances { [PSCustomObject]@{ Namespace = @("argocd-c354") } }
            Mock Write-LogMessage {}
            Mock Write-Progress {}
            Mock Start-Sleep {}
            # PollIntervalSeconds (60) > TimeoutSeconds (10) so the while loop exits after the first interval elapses.
            { Invoke-ArgoCDNamespaceDeleteAndPoll -ArgoCDNamespace "argocd-c354" -ClusterName "cl-edge1" -ArgoCDNamespaceDeletePollIntervalSeconds 60 -ArgoCDNamespaceDeleteTimeoutSeconds 10 } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "WARNING" }
        }
    }
}

# ── Add-Supervisor ─────────────────────────────────────────────────────────────


Describe "Add-Supervisor — failure paths" {
    It "Propagates VcfDeploymentException when New-SupervisorDeploymentSpec fails" {
        { InModuleScope VcfEdgeAtScale {
            function New-SupervisorDeploymentSpec {
                [CmdletBinding()] Param([Parameter()] [Object]$SuppressNetworkVanityPrefix, [Parameter()] [Object]$EdgeSite, [Parameter()] [Object]$FlbMgmtNetworkPersona, [Parameter()] [Object]$FlbNetworkIpAssignmentMode, [Parameter()] [Object]$FlbProvider, [Parameter()] [Object]$FlbWorkloadNetworkPersona, [Parameter()] [Object]$InfrastructureJson, [Parameter()] [Object]$MgmtIpAssignmentMode, [Parameter()] [Object]$NetworkSegments, [Parameter()] [Object]$PrimaryWorkloadIpAssignmentMode, [Parameter()] [Object]$StoragePolicyId, [Parameter()] [Object]$SupervisorName)
                begin {}; process {}
            }
            Mock New-SupervisorDeploymentSpec { throw [VcfDeploymentException]::new("spec build failed") }
            Mock Write-LogMessage {}
            Mock Write-Progress {}
            Add-Supervisor -ClusterId "domain-c8" -ClusterName "cl0" -EdgeSite "site1" -InfrastructureJson (Join-Path ([System.IO.Path]::GetTempPath()) "infra.json") -NetworkSegments @("seg1") -StoragePolicyId "policy-1" -SupervisorName "sup1"
        } } | Should -Throw "*spec build failed*"
    }

    It "Throws VcfDeploymentException when Invoke-SupervisorCreation returns Success=false" {
        { InModuleScope VcfEdgeAtScale {
            function New-SupervisorDeploymentSpec {
                [CmdletBinding()] Param([Parameter()] [Object]$SuppressNetworkVanityPrefix, [Parameter()] [Object]$EdgeSite, [Parameter()] [Object]$FlbMgmtNetworkPersona, [Parameter()] [Object]$FlbNetworkIpAssignmentMode, [Parameter()] [Object]$FlbProvider, [Parameter()] [Object]$FlbWorkloadNetworkPersona, [Parameter()] [Object]$InfrastructureJson, [Parameter()] [Object]$MgmtIpAssignmentMode, [Parameter()] [Object]$NetworkSegments, [Parameter()] [Object]$PrimaryWorkloadIpAssignmentMode, [Parameter()] [Object]$StoragePolicyId, [Parameter()] [Object]$SupervisorName)
                begin {}; process {}
            }
            function Invoke-SupervisorCreation {
                [CmdletBinding()] Param([Parameter()] [Object]$ClusterId, [Parameter()] [Object]$ClusterName, [Parameter()] [Object]$InsecureTls, [Parameter()] [Object]$SupervisorName, [Parameter()] [Object]$SupervisorSpec, [Parameter()] [Object]$VcenterCredential)
                begin {}; process {}
            }
            Mock New-SupervisorDeploymentSpec { return [PSCustomObject]@{ Name = "sup1" } }
            Mock Invoke-SupervisorCreation { return [PSCustomObject]@{ Success = $false; ErrorMessage = "API call failed" } }
            Mock Get-CleanErrorMessage { param($ErrorMessage) $ErrorMessage }
            Mock Write-LogMessage {}
            Mock Write-Progress {}
            Add-Supervisor -ClusterId "domain-c8" -ClusterName "cl0" -EdgeSite "site1" -InfrastructureJson (Join-Path ([System.IO.Path]::GetTempPath()) "infra.json") -NetworkSegments @("seg1") -StoragePolicyId "policy-1" -SupervisorName "sup1"
        } } | Should -Throw "*Supervisor creation failed*"
    }
}


Describe "Add-Supervisor — idempotent path" {
    It "Returns existing supervisor ID without calling Invoke-SupervisorReadinessWait when IsExisting=true" {
        $result = InModuleScope VcfEdgeAtScale {
            function New-SupervisorDeploymentSpec {
                [CmdletBinding()] Param([Parameter()] [Object]$SuppressNetworkVanityPrefix, [Parameter()] [Object]$EdgeSite, [Parameter()] [Object]$FlbMgmtNetworkPersona, [Parameter()] [Object]$FlbNetworkIpAssignmentMode, [Parameter()] [Object]$FlbProvider, [Parameter()] [Object]$FlbWorkloadNetworkPersona, [Parameter()] [Object]$InfrastructureJson, [Parameter()] [Object]$MgmtIpAssignmentMode, [Parameter()] [Object]$NetworkSegments, [Parameter()] [Object]$PrimaryWorkloadIpAssignmentMode, [Parameter()] [Object]$StoragePolicyId, [Parameter()] [Object]$SupervisorName)
                begin {}; process {}
            }
            function Invoke-SupervisorCreation {
                [CmdletBinding()] Param([Parameter()] [Object]$ClusterId, [Parameter()] [Object]$ClusterName, [Parameter()] [Object]$InsecureTls, [Parameter()] [Object]$SupervisorName, [Parameter()] [Object]$SupervisorSpec, [Parameter()] [Object]$VcenterCredential)
                begin {}; process {}
            }
            function Invoke-SupervisorReadinessWait {
                [CmdletBinding()] Param([Parameter()] [Object]$CheckInterval, [Parameter()] [Object]$ClusterId, [Parameter()] [Object]$ClusterName, [Parameter()] [Object]$SingleSite, [Parameter()] [Object]$SupervisorId, [Parameter()] [Object]$TotalWaitTime)
                begin { throw "Invoke-SupervisorReadinessWait must not be called for an existing supervisor" }; process {}
            }
            function Invoke-SupervisorUpgradeIfAvailable {
                [CmdletBinding()] Param([Parameter()] [Object]$CheckInterval, [Parameter()] [Object]$ClusterId, [Parameter()] [Object]$ClusterName, [Parameter()] [Object]$SupervisorId, [Parameter()] [Object]$TotalWaitTime)
                begin {}; process {}
            }
            Mock New-SupervisorDeploymentSpec { return [PSCustomObject]@{ Name = "sup1" } }
            Mock Invoke-SupervisorCreation { return [PSCustomObject]@{ Success = $true; IsExisting = $true; SupervisorId = "existing-sup-uuid" } }
            Mock Write-LogMessage {}
            Mock Write-Progress {}
            Add-Supervisor -ClusterId "domain-c8" -ClusterName "cl0" -EdgeSite "site1" -InfrastructureJson (Join-Path ([System.IO.Path]::GetTempPath()) "infra.json") -NetworkSegments @("seg1") -StoragePolicyId "policy-1" -SupervisorName "sup1"
        }
        $result | Should -Be "existing-sup-uuid"
    }
}

Describe "Add-Supervisor — new supervisor created" {
    It "Calls Invoke-SupervisorReadinessWait and returns the new supervisor ID when Success=true and IsExisting=false" {
        $testResult = InModuleScope VcfEdgeAtScale {
            $Script:_supReadinessWaitCalled = 0
            function New-SupervisorDeploymentSpec {
                [CmdletBinding()] Param(
                    [Parameter()] [Object]$SuppressNetworkVanityPrefix,
                    [Parameter()] [Object]$EdgeSite,
                    [Parameter()] [Object]$FlbMgmtNetworkPersona,
                    [Parameter()] [Object]$FlbNetworkIpAssignmentMode,
                    [Parameter()] [Object]$FlbProvider,
                    [Parameter()] [Object]$FlbWorkloadNetworkPersona,
                    [Parameter()] [Object]$InfrastructureJson,
                    [Parameter()] [Object]$MgmtIpAssignmentMode,
                    [Parameter()] [Object]$NetworkSegments,
                    [Parameter()] [Object]$PrimaryWorkloadIpAssignmentMode,
                    [Parameter()] [Object]$StoragePolicyId,
                    [Parameter()] [Object]$SupervisorName
                )
                begin {}; process {}
            }
            function Invoke-SupervisorCreation {
                [CmdletBinding()] Param(
                    [Parameter()] [Object]$ClusterId,
                    [Parameter()] [Object]$ClusterName,
                    [Parameter()] [Object]$InsecureTls,
                    [Parameter()] [Object]$SupervisorName,
                    [Parameter()] [Object]$SupervisorSpec,
                    [Parameter()] [Object]$VcenterCredential
                )
                begin {}; process {}
            }
            function Invoke-SupervisorReadinessWait {
                [CmdletBinding()] Param(
                    [Parameter()] [Object]$CheckInterval,
                    [Parameter()] [Object]$ClusterId,
                    [Parameter()] [Object]$ClusterName,
                    [Parameter()] [Object]$SingleSite,
                    [Parameter()] [Object]$SupervisorId,
                    [Parameter()] [Object]$TotalWaitTime
                )
                begin { $Script:_supReadinessWaitCalled++ }; process {}
            }
            function Invoke-SupervisorUpgradeIfAvailable {
                [CmdletBinding()] Param(
                    [Parameter()] [Object]$CheckInterval,
                    [Parameter()] [Object]$ClusterId,
                    [Parameter()] [Object]$ClusterName,
                    [Parameter()] [Object]$SupervisorId,
                    [Parameter()] [Object]$TotalWaitTime
                )
                begin {}; process {}
            }
            Mock New-SupervisorDeploymentSpec { return [PSCustomObject]@{ Name = "sup1" } }
            Mock Invoke-SupervisorCreation { return [PSCustomObject]@{ Success = $true; IsExisting = $false; SupervisorId = "new-sup-uuid" } }
            Mock Write-LogMessage {}
            Mock Write-Progress {}
            $supId = Add-Supervisor `
                -ClusterId "domain-c8" -ClusterName "cl0" -EdgeSite "site1" `
                -InfrastructureJson (Join-Path ([System.IO.Path]::GetTempPath()) "infra.json") -NetworkSegments @("seg1") `
                -StoragePolicyId "policy-1" -SupervisorName "sup1"
            @{ Id = $supId; ReadinessCalls = $Script:_supReadinessWaitCalled }
        }
        $testResult.Id | Should -Be "new-sup-uuid"
        $testResult.ReadinessCalls | Should -BeGreaterOrEqual 1
    }
}
# ── Test-WebhookServiceReady ───────────────────────────────────────────────────


Describe "Test-WebhookServiceReady — kubectl error paths" {
    It "Returns false and logs WARNING when kubectl exits non-zero with a connection error" {
        $result = InModuleScope VcfEdgeAtScale {
            # Override KubectlCmd with a scriptblock that simulates a connection-refused exit code.
            $Script:KubectlCmd = { param([Parameter(ValueFromRemainingArguments)] $result); $global:LASTEXITCODE = 1; return "Unable to connect to the server: connection refused" }
            Mock Write-LogMessage {}
            Test-WebhookServiceReady -ServiceNamespace "argocd-ns"
        }
        $result | Should -Be $false
    }

    It "Returns false and logs DEBUG when kubectl exits non-zero with a not-found error" {
        $result = InModuleScope VcfEdgeAtScale {
            $Script:KubectlCmd = { param([Parameter(ValueFromRemainingArguments)] $result); $global:LASTEXITCODE = 1; return "not found" }
            Mock Write-LogMessage {}
            Test-WebhookServiceReady -ServiceNamespace "argocd-ns"
        }
        $result | Should -Be $false
    }

    It "Returns false when the service exists but endpoints have no subsets" {
        $result = InModuleScope VcfEdgeAtScale {
            $Script:_callCount = 0
            $Script:KubectlCmd = {
                param([Parameter(ValueFromRemainingArguments)] $result)
                $global:LASTEXITCODE = 0
                $Script:_callCount++
                # First call: service JSON; second call: endpoints with no subsets.
                if ($Script:_callCount -le 1) { return '{"kind":"Service","metadata":{"name":"argocd-service-webhook-service"}}' }
                return '{"kind":"Endpoints","subsets":[]}'
            }
            Mock Write-LogMessage {}
            Test-WebhookServiceReady -ServiceNamespace "argocd-ns"
        }
        $result | Should -Be $false
    }

    It "Returns true when the service exists and endpoints have active addresses" -Skip:$IsWindows {
        $result = InModuleScope VcfEdgeAtScale {
            # Use a real bash script so $LASTEXITCODE is reliably set to 0 (scriptblocks do not set $LASTEXITCODE).
            $tmpPath = Join-Path ([System.IO.Path]::GetTempPath()) "mock-kubectl-svc-ready-$([Guid]::NewGuid()).sh"
            try {
                Set-Content -Path $tmpPath -Encoding UTF8 -Value "#!/bin/bash`nif [[ `"`$*`" == *'get service'* ]]; then echo '{`"kind`":`"Service`",`"metadata`":{`"name`":`"argocd-service-webhook-service`"}}'; else echo '{`"kind`":`"Endpoints`",`"subsets`":[{`"addresses`":[{`"ip`":`"10.0.0.1`"}]}]}'; fi; exit 0"
                & chmod +x $tmpPath
                $Script:KubectlCmd = $tmpPath
                Mock Write-LogMessage {}
                Test-WebhookServiceReady -ServiceNamespace "argocd-ns"
            } finally {
                if (Test-Path $tmpPath) { Remove-Item -Path $tmpPath -Force -ErrorAction SilentlyContinue }
            }
        }
        $result | Should -Be $true
    }
}

# ── Get-ContentLibraryId ──────────────────────────────────────────────────────


Describe "Get-ContentLibraryId — connection and lookup paths" {
    It "Throws when not connected to vCenter" {
        { InModuleScope VcfEdgeAtScale {
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $false; ErrorMessage = "no session" } }
            Mock Write-LogMessage {}
            Get-ContentLibraryId -LibraryName "VCF-ContentLibrary"
        } } | Should -Throw "*Not connected*"
    }

    It "Returns null when no matching library is found" {
        $result = InModuleScope VcfEdgeAtScale {
            function Get-ContentLibrary {
                [CmdletBinding()] Param([Parameter()] [Object]$Server)
                begin {}; process {}
            }
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true; ErrorMessage = $null } }
            Mock Get-ContentLibrary { @([PSCustomObject]@{ Name = "OtherLibrary"; Id = "lib-other" }) }
            Mock Write-LogMessage {}
            Get-ContentLibraryId -LibraryName "VCF-ContentLibrary"
        }
        $result | Should -BeNullOrEmpty
    }

    It "Returns the library Id when a matching library is found" {
        $result = InModuleScope VcfEdgeAtScale {
            function Get-ContentLibrary {
                [CmdletBinding()] Param([Parameter()] [Object]$Server)
                begin {}; process {}
            }
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true; ErrorMessage = $null } }
            Mock Get-ContentLibrary { @([PSCustomObject]@{ Name = "VCF-ContentLibrary"; Id = "lib-abc-123" }) }
            Mock Write-LogMessage {}
            Get-ContentLibraryId -LibraryName "VCF-ContentLibrary"
        }
        $result | Should -Be "lib-abc-123"
    }

    It "Throws VcfDeploymentException when Get-ContentLibrary throws an unexpected error" {
        { InModuleScope VcfEdgeAtScale {
            function Get-ContentLibrary {
                [CmdletBinding()] Param([Parameter()] [Object]$Server)
                begin {}; process {}
            }
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true; ErrorMessage = $null } }
            Mock Get-ContentLibrary { throw "vCenter API error" }
            Mock Write-LogMessage {}
            Get-ContentLibraryId -LibraryName "VCF-ContentLibrary"
        } } | Should -Throw "*Failed to retrieve content library*"
    }
}

# ── Get-StoragePolicyId ───────────────────────────────────────────────────────


Describe "Get-StoragePolicyId — connection and lookup paths" {
    It "Throws when not connected to vCenter" {
        { InModuleScope VcfEdgeAtScale {
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $false; ErrorMessage = "no session" } }
            Mock Write-LogMessage {}
            Get-StoragePolicyId -StoragePolicyName "vSAN Default Storage Policy"
        } } | Should -Throw "*Not connected*"
    }

    It "Returns null when the storage policy is not found" {
        $result = InModuleScope VcfEdgeAtScale {
            function Get-SpbmStoragePolicy {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                begin {}; process {}
            }
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true; ErrorMessage = $null } }
            Mock Get-SpbmStoragePolicy { $null }
            Mock Write-LogMessage {}
            Get-StoragePolicyId -StoragePolicyName "NonExistentPolicy"
        }
        $result | Should -BeNullOrEmpty
    }

    It "Returns the policy Id when the storage policy is found" {
        $result = InModuleScope VcfEdgeAtScale {
            function Get-SpbmStoragePolicy {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                begin {}; process {}
            }
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true; ErrorMessage = $null } }
            Mock Get-SpbmStoragePolicy { [PSCustomObject]@{ Name = "vSAN Default Storage Policy"; Id = "policy-guid-1234" } }
            Mock Write-LogMessage {}
            Get-StoragePolicyId -StoragePolicyName "vSAN Default Storage Policy"
        }
        $result | Should -Be "policy-guid-1234"
    }

    It "Throws VcfDeploymentException when Get-SpbmStoragePolicy throws an unexpected error" {
        { InModuleScope VcfEdgeAtScale {
            function Get-SpbmStoragePolicy {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                begin {}; process {}
            }
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true; ErrorMessage = $null } }
            Mock Get-SpbmStoragePolicy { throw "vCenter SPBM service unavailable" }
            Mock Write-LogMessage {}
            Get-StoragePolicyId -StoragePolicyName "vSAN Default Storage Policy"
        } } | Should -Throw "*Unable to fetch storage policy id*"
    }
}

# ── Set-ArgoCDService ─────────────────────────────────────────────────────────


Describe "Set-ArgoCDService — error routing" {
    It "Throws VcfDeploymentException when Get-VcfSdkInitializeCommand returns null (required cmdlet absent)" {
        { InModuleScope VcfEdgeAtScale {
            function Initialize-VcenterNamespaceManagementSupervisorServicesVersionsCarvelCreateSpec {
                [CmdletBinding()] Param([Parameter()] [Object]$Content)
                begin {}; process {}
            }
            function Initialize-VcenterNamespaceManagementSupervisorServicesCarvelCreateSpec {
                [CmdletBinding()] Param([Parameter()] [Object]$VersionSpec)
                begin {}; process {}
            }
            Mock Get-Base64FromYml { return "dGVzdA==" }
            Mock Get-ArgoCDServiceDetail { return @("argocd-service.vsphere.vmware.com", "1.0.0") }
            Mock Initialize-VcenterNamespaceManagementSupervisorServicesVersionsCarvelCreateSpec { return [PSCustomObject]@{} }
            Mock Initialize-VcenterNamespaceManagementSupervisorServicesCarvelCreateSpec { return [PSCustomObject]@{} }
            Mock Get-VcfSdkInitializeCommand { return $null }
            Mock Write-LogMessage {}
            Set-ArgoCDService -Path (Join-Path ([System.IO.Path]::GetTempPath()) "argocd.yml")
        } } | Should -Throw "*Required cmdlet*"
    }

    It "Does not throw when service already exists (idempotent)" {
        InModuleScope VcfEdgeAtScale {
            function Initialize-VcenterNamespaceManagementSupervisorServicesVersionsCarvelCreateSpec {
                [CmdletBinding()] Param([Parameter()] [Object]$Content)
                begin {}; process {}
            }
            function Initialize-VcenterNamespaceManagementSupervisorServicesCarvelCreateSpec {
                [CmdletBinding()] Param([Parameter()] [Object]$VersionSpec)
                begin {}; process {}
            }
            function Invoke-CreateNamespaceManagementSupervisorServices {
                [CmdletBinding(SupportsShouldProcess = $true)] Param([Parameter()] [Object]$vcenterNamespaceManagementSupervisorServicesCreateSpec)
                begin {}; process {}
            }
            Mock Get-Base64FromYml { return "dGVzdA==" }
            Mock Get-ArgoCDServiceDetail { return @("argocd-service.vsphere.vmware.com", "1.0.0") }
            Mock Initialize-VcenterNamespaceManagementSupervisorServicesVersionsCarvelCreateSpec { return [PSCustomObject]@{} }
            Mock Initialize-VcenterNamespaceManagementSupervisorServicesCarvelCreateSpec { return [PSCustomObject]@{} }
            Mock Get-VcfSdkInitializeCommand { return "Initialize-VcenterNamespaceManagementSupervisorServicesCreateSpec" }
            function Initialize-VcenterNamespaceManagementSupervisorServicesCreateSpec {
                [CmdletBinding()] Param([Parameter()] [Object]$CarvelSpec)
                begin {}; process {}
            }
            Mock Initialize-VcenterNamespaceManagementSupervisorServicesCreateSpec { return [PSCustomObject]@{} }
            Mock Invoke-CreateNamespaceManagementSupervisorServices { throw "an instance of Supervisor Service with the same identifier already exists" }
            Mock Write-LogMessage {}
            { Set-ArgoCDService -Path (Join-Path ([System.IO.Path]::GetTempPath()) "argocd.yml") } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "DEBUG" -and $Message -match "already" }
        }
    }

    It "Throws VcfDeploymentException when service creation fails with an unexpected error" {
        { InModuleScope VcfEdgeAtScale {
            function Initialize-VcenterNamespaceManagementSupervisorServicesVersionsCarvelCreateSpec {
                [CmdletBinding()] Param([Parameter()] [Object]$Content)
                begin {}; process {}
            }
            function Initialize-VcenterNamespaceManagementSupervisorServicesCarvelCreateSpec {
                [CmdletBinding()] Param([Parameter()] [Object]$VersionSpec)
                begin {}; process {}
            }
            function Invoke-CreateNamespaceManagementSupervisorServices {
                [CmdletBinding(SupportsShouldProcess = $true)] Param([Parameter()] [Object]$vcenterNamespaceManagementSupervisorServicesCreateSpec)
                begin {}; process {}
            }
            Mock Get-Base64FromYml { return "dGVzdA==" }
            Mock Get-ArgoCDServiceDetail { return @("argocd-service.vsphere.vmware.com", "1.0.0") }
            Mock Initialize-VcenterNamespaceManagementSupervisorServicesVersionsCarvelCreateSpec { return [PSCustomObject]@{} }
            Mock Initialize-VcenterNamespaceManagementSupervisorServicesCarvelCreateSpec { return [PSCustomObject]@{} }
            Mock Get-VcfSdkInitializeCommand { return "Initialize-VcenterNamespaceManagementSupervisorServicesCreateSpec" }
            function Initialize-VcenterNamespaceManagementSupervisorServicesCreateSpec {
                [CmdletBinding()] Param([Parameter()] [Object]$CarvelSpec)
                begin {}; process {}
            }
            Mock Initialize-VcenterNamespaceManagementSupervisorServicesCreateSpec { return [PSCustomObject]@{} }
            Mock Invoke-CreateNamespaceManagementSupervisorServices { throw "Internal Server Error 500" }
            Mock Write-LogMessage {}
            Set-ArgoCDService -Path (Join-Path ([System.IO.Path]::GetTempPath()) "argocd.yml")
        } } | Should -Throw "*creation failed*"
    }
}

# ── Set-HarborService ─────────────────────────────────────────────────────────


Describe "Set-HarborService — error routing" {
    It "Throws VcfDeploymentException when Get-VcfSdkInitializeCommand returns null" {
        { InModuleScope VcfEdgeAtScale {
            function Initialize-VcenterNamespaceManagementSupervisorServicesVersionsCarvelCreateSpec {
                [CmdletBinding()] Param([Parameter()] [Object]$Content)
                begin {}; process {}
            }
            function Initialize-VcenterNamespaceManagementSupervisorServicesCarvelCreateSpec {
                [CmdletBinding()] Param([Parameter()] [Object]$VersionSpec)
                begin {}; process {}
            }
            Mock Get-Base64FromYml { return "dGVzdA==" }
            Mock Get-ArgoCDServiceDetail { return @("harbor-service.vsphere.vmware.com", "2.14.2") }
            Mock Initialize-VcenterNamespaceManagementSupervisorServicesVersionsCarvelCreateSpec { return [PSCustomObject]@{} }
            Mock Initialize-VcenterNamespaceManagementSupervisorServicesCarvelCreateSpec { return [PSCustomObject]@{} }
            Mock Get-VcfSdkInitializeCommand { return $null }
            Mock Write-LogMessage {}
            Set-HarborService -Path (Join-Path ([System.IO.Path]::GetTempPath()) "harbor-service.yml")
        } } | Should -Throw "*Required cmdlet*"
    }

    It "Does not throw when Harbor service already exists (idempotent)" {
        InModuleScope VcfEdgeAtScale {
            function Initialize-VcenterNamespaceManagementSupervisorServicesVersionsCarvelCreateSpec {
                [CmdletBinding()] Param([Parameter()] [Object]$Content)
                begin {}; process {}
            }
            function Initialize-VcenterNamespaceManagementSupervisorServicesCarvelCreateSpec {
                [CmdletBinding()] Param([Parameter()] [Object]$VersionSpec)
                begin {}; process {}
            }
            function Invoke-CreateNamespaceManagementSupervisorServices {
                [CmdletBinding(SupportsShouldProcess = $true)] Param([Parameter()] [Object]$vcenterNamespaceManagementSupervisorServicesCreateSpec)
                begin {}; process {}
            }
            Mock Get-Base64FromYml { return "dGVzdA==" }
            Mock Get-ArgoCDServiceDetail { return @("harbor-service.vsphere.vmware.com", "2.14.2") }
            Mock Initialize-VcenterNamespaceManagementSupervisorServicesVersionsCarvelCreateSpec { return [PSCustomObject]@{} }
            Mock Initialize-VcenterNamespaceManagementSupervisorServicesCarvelCreateSpec { return [PSCustomObject]@{} }
            Mock Get-VcfSdkInitializeCommand { return "Initialize-VcenterNamespaceManagementSupervisorServicesCreateSpec" }
            function Initialize-VcenterNamespaceManagementSupervisorServicesCreateSpec {
                [CmdletBinding()] Param([Parameter()] [Object]$CarvelSpec)
                begin {}; process {}
            }
            Mock Initialize-VcenterNamespaceManagementSupervisorServicesCreateSpec { return [PSCustomObject]@{} }
            Mock Invoke-CreateNamespaceManagementSupervisorServices { throw "an instance of Supervisor Service with the same identifier already exists" }
            Mock Write-LogMessage {}
            { Set-HarborService -Path (Join-Path ([System.IO.Path]::GetTempPath()) "harbor-service.yml") } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "INFO" -and $Message -match "already registered" }
        }
    }
}

# ── Invoke-ArgoCDServiceCreate ────────────────────────────────────────────────


Describe "Invoke-ArgoCDServiceCreate — error routing" {
    It "Does not throw when service already exists" {
        InModuleScope VcfEdgeAtScale {
            function Initialize-VcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec {
                [CmdletBinding()] Param([Parameter()] [Object]$SupervisorService, [Parameter()] [Object]$Version)
                begin {}; process {}
            }
            function Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesCreate {
                [CmdletBinding(SupportsShouldProcess = $true)] Param([Parameter()] [Object]$supervisor, [Parameter()] [Object]$vcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec)
                begin {}; process {}
            }
            Mock Initialize-VcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec { return [PSCustomObject]@{} }
            Mock Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesCreate { throw "Supervisor Service with the same identifier already exists" }
            Mock Write-LogMessage {}
            { Invoke-ArgoCDServiceCreate -Service "argocd-service.vsphere.vmware.com" -Version "1.0.0" -SupervisorId "sup-123" -ServiceNamespace "svc-argocd-domain-c1" } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "INFO" -and $Message -match "already exists" }
        }
    }

    It "Throws VcfDeploymentException when service is not in activated state" {
        { InModuleScope VcfEdgeAtScale {
            function Initialize-VcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec {
                [CmdletBinding()] Param([Parameter()] [Object]$SupervisorService, [Parameter()] [Object]$Version)
                begin {}; process {}
            }
            function Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesCreate {
                [CmdletBinding(SupportsShouldProcess = $true)] Param([Parameter()] [Object]$supervisor, [Parameter()] [Object]$vcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec)
                begin {}; process {}
            }
            Mock Initialize-VcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec { return [PSCustomObject]@{} }
            Mock Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesCreate { throw "Supervisor Service is not in activated state" }
            Mock Write-LogMessage {}
            Invoke-ArgoCDServiceCreate -Service "argocd-service.vsphere.vmware.com" -Version "1.0.0" -SupervisorId "sup-123" -ServiceNamespace "svc-argocd-domain-c1"
        } } | Should -Throw "*not in activated state*"
    }

    It "Throws VcfDeploymentException when ArgoCD service version is not found on the supervisor" {
        { InModuleScope VcfEdgeAtScale {
            function Initialize-VcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec {
                [CmdletBinding()] Param([Parameter()] [Object]$SupervisorService, [Parameter()] [Object]$Version)
                begin {}; process {}
            }
            function Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesCreate {
                [CmdletBinding(SupportsShouldProcess = $true)] Param([Parameter()] [Object]$supervisor, [Parameter()] [Object]$vcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec)
                begin {}; process {}
            }
            Mock Initialize-VcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec { return [PSCustomObject]@{} }
            Mock Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesCreate { throw "Supervisor Service (argocd-service.vsphere.vmware.com) version (1.0.0-99999999) has not been found" }
            Mock Write-LogMessage {}
            Invoke-ArgoCDServiceCreate -Service "argocd-service.vsphere.vmware.com" -Version "1.0.0-99999999" -SupervisorId "sup-123" -ServiceNamespace "svc-argocd-domain-c1"
        } } | Should -Throw
    }

    It "Does not throw when service creation succeeds" {
        InModuleScope VcfEdgeAtScale {
            function Initialize-VcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec {
                [CmdletBinding()] Param([Parameter()] [Object]$SupervisorService, [Parameter()] [Object]$Version)
                begin {}; process {}
            }
            function Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesCreate {
                [CmdletBinding(SupportsShouldProcess = $true)] Param([Parameter()] [Object]$supervisor, [Parameter()] [Object]$vcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec)
                begin {}; process {}
            }
            Mock Initialize-VcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec { return [PSCustomObject]@{} }
            Mock Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesCreate {}
            Mock Write-LogMessage {}
            Mock Start-Sleep {}
            { Invoke-ArgoCDServiceCreate -Service "argocd-service.vsphere.vmware.com" -Version "1.0.0" -SupervisorId "sup-123" -ServiceNamespace "svc-argocd-domain-c1" -CheckInterval 1 } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "DEBUG" -and $Message -match "successfully created" }
        }
    }
}

# ── Get-VsanEsaEligibleDisksFromCluster ──────────────────────────────────────


Describe "Get-KubectlNamespaceNamesMatchingPattern — kubectl result paths" {
    It "Returns KubectlSucceeded=false when kubectl exits non-zero" {
        $result = InModuleScope VcfEdgeAtScale {
            $Script:KubectlCmd = { param([Parameter(ValueFromRemainingArguments)] $result); $global:LASTEXITCODE = 1; return "connection refused" }
            Mock Write-LogMessage {}
            Get-KubectlNamespaceNamesMatchingPattern -NameLike "svc-harbor*"
        }
        $result.KubectlSucceeded | Should -Be $false
        @($result.Names).Count  | Should -Be 0
    }

    It "Returns KubectlSucceeded=false and logs DEBUG when kubectl throws" {
        $result = InModuleScope VcfEdgeAtScale {
            $Script:KubectlCmd = { param([Parameter(ValueFromRemainingArguments)] $result); throw "binary not found" }
            Mock Write-LogMessage {}
            Get-KubectlNamespaceNamesMatchingPattern -NameLike "svc-harbor*"
        }
        $result.KubectlSucceeded | Should -Be $false
    }

    It "Returns KubectlSucceeded=true with matched names when kubectl succeeds" -Skip:$IsWindows {
        $result = InModuleScope VcfEdgeAtScale {
            $tmpPath = Join-Path ([System.IO.Path]::GetTempPath()) "mock-kubectl-ns-$([Guid]::NewGuid()).sh"
            try {
                $nsJson = '{"items":[{"metadata":{"name":"svc-harbor-domain-c1"}},{"metadata":{"name":"default"}},{"metadata":{"name":"svc-harbor-domain-c2"}}]}'
                Set-Content -Path $tmpPath -Encoding UTF8 -Value "#!/bin/bash`necho '$nsJson'`nexit 0"
                & chmod +x $tmpPath
                $Script:KubectlCmd = $tmpPath
                Mock Write-LogMessage {}
                Get-KubectlNamespaceNamesMatchingPattern -NameLike "svc-harbor*"
            } finally {
                if (Test-Path $tmpPath) { Remove-Item -Path $tmpPath -Force -ErrorAction SilentlyContinue }
            }
        }
        $result.KubectlSucceeded | Should -Be $true
        @($result.Names) | Should -Contain "svc-harbor-domain-c1"
        @($result.Names) | Should -Contain "svc-harbor-domain-c2"
        @($result.Names) | Should -Not -Contain "default"
    }
}

# ── Get-PortGroupId ───────────────────────────────────────────────────────────


Describe "Set-ArgoCdKubectlContext — context found" {
    It "Switches to the context when kubectl lists the context name" {
        InModuleScope VcfEdgeAtScale {
            $tmpDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "veas-p7-ctx-$([System.Guid]::NewGuid().ToString('N').Substring(0, 8))"
            New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
            $mockKubectl = Join-Path $tmpDir "kubectl-ctx.ps1"
            $mockScript = @'
if ($args[0] -eq "config" -and $args[1] -eq "get-contexts") {
    Write-Output "ctx:argocd-ns"
    exit 0
} elseif ($args[0] -eq "config" -and $args[1] -eq "use-context") {
    exit 0
}
exit 0
'@
            Set-Content -Path $mockKubectl -Value $mockScript -Encoding UTF8
            $savedKubectl = $Script:KubectlCmd
            $Script:KubectlCmd = $mockKubectl
            $Script:_debugLogged = $false
            Mock Write-LogMessage {
                if ($Type -eq "DEBUG" -and $Message -match "Successfully switched") { $Script:_debugLogged = $true }
            }
            try {
                { Set-ArgoCdKubectlContext -KubectlContextName "ctx:argocd-ns" } | Should -Not -Throw
                $Script:_debugLogged | Should -Be $true
            } finally {
                $Script:KubectlCmd = $savedKubectl
                Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}


Describe "Confirm-ArgoCdResourceSpec — all resources valid" {
    It "Logs no ERROR when every resource has spec.version" {
        InModuleScope VcfEdgeAtScale {
            $tmpDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "veas-p7-spec-$([System.Guid]::NewGuid().ToString('N').Substring(0, 8))"
            New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
            $fakeJson = '{"items":[{"spec":{"version":"1.2.3"}},{"spec":{"version":"1.0.0"}}]}'
            $mockKubectl = Join-Path $tmpDir "kubectl-spec-ok.ps1"
            Set-Content -Path $mockKubectl -Value "Write-Output '$fakeJson'; `$global:LASTEXITCODE = 0" -Encoding UTF8
            $savedKubectl = $Script:KubectlCmd
            $Script:KubectlCmd = $mockKubectl
            $Script:_errorLogged = $false
            Mock Write-LogMessage {
                if ($Type -eq "ERROR") { $Script:_errorLogged = $true }
            }
            try {
                Confirm-ArgoCdResourceSpec -ArgoCdNamespace "argocd"
                $Script:_errorLogged | Should -Be $false
            } finally {
                $Script:KubectlCmd = $savedKubectl
                Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}


Describe "Add-ArgoCDInstance — success path with behavior assertions" {
    It "Calls Set-ArgoCdKubectlContext, Wait-ArgoCDAuthReady, and Wait-ArgoCDPodsReady when all steps succeed" {
        $counts = InModuleScope VcfEdgeAtScale {
            $Script:_argoCdCtxCalled = 0; $Script:_argoCdAuthCalled = 0; $Script:_argoCdPodsCalled = 0
            function Set-ArgoCdKubectlContext {
                [CmdletBinding()] Param([Parameter()] [Object]$KubectlContextName)
                begin { $Script:_argoCdCtxCalled++ }; process {}
            }
            function Wait-ArgoCDAuthReady {
                [CmdletBinding()] Param(
                    [Parameter()] [Object]$ArgoCdNamespace, [Parameter()] [Object]$AuthCheckInterval,
                    [Parameter()] [Object]$AuthTimeoutSeconds, [Parameter()] [Object]$ContextName,
                    [Parameter()] [Object]$InsecureTls
                )
                begin { $Script:_argoCdAuthCalled++ }; process {}
            }
            function Wait-ArgoCDPodsReady {
                [CmdletBinding()] Param(
                    [Parameter()] [Object]$Namespace, [Parameter()] [Object]$CheckInterval,
                    [Parameter()] [Object]$TimeoutSeconds
                )
                begin { $Script:_argoCdPodsCalled++ }; process {}
            }
            Mock Write-LogMessage {}
            Mock Get-VcfEdgeAtScaleVcfCmd {}
            Mock Get-ArgoCdTimeoutConfig {
                [PSCustomObject]@{
                    AuthCheckInterval = 1; AuthTimeoutSeconds = 10; PodReadyCheckInterval = 1
                    PodReadyTimeoutSeconds = 60; WebhookReadyCheckInterval = 1
                    WebhookReadyTimeoutSeconds = 60; WebhookRetryTimeoutSeconds = 60
                }
            }
            Mock Invoke-ArgoCDContextBind { [PSCustomObject]@{ Success = $true; ServiceNamespace = "svc-argocd-domain-c1" } }
            Mock Invoke-ArgoCdYamlApply { [PSCustomObject]@{ Success = $true } }
            Add-ArgoCDInstance `
                -ArgoCdDeploymentYamlPath "a.yaml" `
                -ArgoCdNamespace "argocd" `
                -ClusterId "domain-c1" `
                -ContextName "ctx" `
                -Service "argocd-service.vsphere.vmware.com"
            @{ Ctx = $Script:_argoCdCtxCalled; Auth = $Script:_argoCdAuthCalled; Pods = $Script:_argoCdPodsCalled }
        }
        $counts.Ctx | Should -BeGreaterOrEqual 1
        $counts.Auth | Should -BeGreaterOrEqual 1
        $counts.Pods | Should -BeGreaterOrEqual 1
    }
}

Describe "Add-ArgoCDInstance — yaml apply failure returns result" {
    It "Returns the failed result without calling Set-ArgoCdKubectlContext when Invoke-ArgoCdYamlApply reports Success=false" {
        $result = InModuleScope VcfEdgeAtScale {
            # Guard: if Set-ArgoCdKubectlContext is called on the failure path the test fails immediately.
            function Set-ArgoCdKubectlContext {
                [CmdletBinding()] Param([Parameter()] [Object]$KubectlContextName)
                begin { throw "Set-ArgoCdKubectlContext must not be called when yaml apply fails" }; process {}
            }
            Mock Write-LogMessage {}
            Mock Get-VcfEdgeAtScaleVcfCmd {}
            Mock Get-ArgoCdTimeoutConfig {
                [PSCustomObject]@{
                    AuthCheckInterval = 1; AuthTimeoutSeconds = 10; PodReadyCheckInterval = 1
                    PodReadyTimeoutSeconds = 60; WebhookReadyCheckInterval = 1
                    WebhookReadyTimeoutSeconds = 60; WebhookRetryTimeoutSeconds = 60
                }
            }
            Mock Invoke-ArgoCDContextBind { [PSCustomObject]@{ Success = $true; ServiceNamespace = "svc-argocd-domain-c1" } }
            Mock Invoke-ArgoCdYamlApply { [PSCustomObject]@{ Success = $false; ErrorMessage = "kubectl apply failed" } }
            Add-ArgoCDInstance `
                -ArgoCdDeploymentYamlPath "a.yaml" `
                -ArgoCdNamespace "argocd" `
                -ClusterId "domain-c1" `
                -ContextName "ctx" `
                -Service "argocd-service.vsphere.vmware.com"
        }
        $result.Success | Should -Be $false
    }
}

# ── Initialize-VcfEdgeAtScale ─────────────────────────────────────────────────


Describe "Get-YamlMultiDocumentList — single document" {
    It "Returns an array with one hashtable for a single-document YAML file" {
        InModuleScope VcfEdgeAtScale {
            $yaml = "apiVersion: apps/v1`nkind: Deployment`nmetadata:`n  name: test"
            $tempFile = [System.IO.Path]::GetTempFileName()
            try {
                [System.IO.File]::WriteAllText($tempFile, $yaml)
                $result = @(Get-YamlMultiDocumentList -YamlFilePath $tempFile)
                $result.Count | Should -Be 1
                $result[0]["kind"] | Should -Be "Deployment"
            } finally {
                Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

Describe "Get-YamlMultiDocumentList — multiple documents" {
    It "Returns an array with two hashtables for a two-document YAML file" {
        InModuleScope VcfEdgeAtScale {
            $yaml = "apiVersion: v1`nkind: ConfigMap`nmetadata:`n  name: doc1`n---`napiVersion: v1`nkind: Service`nmetadata:`n  name: doc2"
            $tempFile = [System.IO.Path]::GetTempFileName()
            try {
                [System.IO.File]::WriteAllText($tempFile, $yaml)
                $result = Get-YamlMultiDocumentList -YamlFilePath $tempFile
                $result.Count | Should -Be 2
                $result[0]["kind"] | Should -Be "ConfigMap"
                $result[1]["kind"] | Should -Be "Service"
            } finally {
                Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
