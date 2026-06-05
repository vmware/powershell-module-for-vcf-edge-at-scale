# Pester tests for VcfEdgeAtScale — Private/Deployment.ps1
#
# RECOMMENDED: Use the wrapper script for human-readable output:
#   ./Tests/Run-Tests.ps1
#   ./Tests/Run-Tests.ps1 -Filter "*FunctionName*"
#
# DIRECT: Invoke-Pester -Path ./Tests/VcfEdgeAtScale.Deployment.Tests.ps1 -Output Detailed
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

Describe "Confirm-CleanupForCluster" {

    It "Logs ADVISORY 'Skipping cleanup confirmation' and bypasses Read-Host when ForceBypassPrompt is set" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            function Read-Host {
                [CmdletBinding()] Param([Parameter(Position = 0)] [Object]$Prompt)
                throw "Read-Host must not be called when ForceBypassPrompt is set"
            }
            { Confirm-CleanupForCluster -CleanUpScope "All" -ClusterName "cl01" -DatastoreName "ds-site1" -EdgeSite "site1" -ForceBypassPrompt } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'ADVISORY' -and $Message -match 'Skipping cleanup confirmation' }
        }
    }

    It "Logs ADVISORY scope advisory and no ERROR when the operator types the correct confirmation phrase" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            function Read-Host {
                [CmdletBinding()] Param([Parameter(Position = 0)] [Object]$Prompt)
                return "delete all for site1"
            }
            { Confirm-CleanupForCluster -CleanUpScope "All" -ClusterName "cl01" -DatastoreName "ds-site1" -EdgeSite "site1" } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'ADVISORY' -and $Message -match 'remove all resources' }
            Should -Not -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'ERROR' }
        }
    }

    It "Throws VcfDeploymentException when the operator types the wrong phrase" {
        { InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            function Read-Host {
                [CmdletBinding()] Param([Parameter(Position = 0)] [Object]$Prompt)
                return "wrong input"
            }
            Confirm-CleanupForCluster -CleanUpScope "All" -ClusterName "cl01" -DatastoreName "ds-site1" -EdgeSite "site1"
        } } | Should -Throw
    }

    It "Throws VcfDeploymentException when the operator presses Enter without typing anything" {
        { InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            function Read-Host {
                [CmdletBinding()] Param([Parameter(Position = 0)] [Object]$Prompt)
                return ""
            }
            Confirm-CleanupForCluster -CleanUpScope "Supervisor" -ClusterName "cl01" -DatastoreName "ds-site1" -EdgeSite "site1"
        } } | Should -Throw
    }

    It "Logs the exact confirmation phrase the operator must copy/paste" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            function Read-Host {
                [CmdletBinding()] Param([Parameter(Position = 0)] [Object]$Prompt)
                return "delete supervisor for site2"
            }
            { Confirm-CleanupForCluster -CleanUpScope "Supervisor" -ClusterName "cl01" -DatastoreName "ds-site2" -EdgeSite "site2" } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'INFO' -and $Message -match 'delete supervisor for site2' }
        }
    }
}

# ── Invoke-ClusterRollbackPhase — storage-type routing ───────────────────────


Describe "Invoke-ClusterRollbackPhase" {

    It "Returns false when VMFS management restore is not needed and VDS/cluster removal succeeds" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Get-SupervisorNameFromPrefix { return "sup-site1" }
            Mock Get-VdsNameFromPrefix { return "VDS-site1" }
            Mock Get-EffectiveNicListForCluster { return @("nic1", "nic2") }
            Mock Remove-NonVmk0VmkernelInterfacesFromVds { }
            Mock Invoke-ManagementRestoreForCleanupWithTopologyFallback {
                return [PSCustomObject]@{ RestoreAttempted = $false; Success = $true; Message = "" }
            }
            Mock Remove-EdgeClusterDistributedSwitch { }
            Mock Get-DatastoreNameFromPrefix { return "ds-site1" }
            Mock Remove-ClusterSafely { }
            Mock Remove-VmfsDatastoreForCluster { }

            $fakeSpec  = [PSCustomObject]@{ esxHosts = @(); vSanWitnessVmName = "" }
            $fakeInput = [PSCustomObject]@{ common = [PSCustomObject]@{ nicList = @("nic1", "nic2"); vSanWitnessVmName = "" } }
            Invoke-ClusterRollbackPhase -ClusterName "cl-site1" -ClusterSpec $fakeSpec `
                -DatastoreNamePrefix "ds" -EdgeSite "site1" -InputData $fakeInput `
                -StoragePolicyType "VMFS" -SupervisorNamePrefix "sup" -VdsNamePrefix "VDS"
        }
        $result | Should -Be $false
    }

    It "Returns false and calls Invoke-VsanDeploymentRollback when storage type is vSAN-ESA" {
        $rollbackCalled = InModuleScope VcfEdgeAtScale {
            $Script:_rollbackCallCount = 0
            function Invoke-VsanDeploymentRollback {
                [CmdletBinding()]
                Param (
                    [Parameter()] [Object]$ClusterName, [Parameter()] [Object]$EsxHostNames,
                    [Parameter()] [Object]$SkipClusterRemoval, [Parameter()] [Object]$StoragePolicyTagCatalog,
                    [Parameter()] [Object]$StoragePolicyTagName, [Parameter()] [Object]$StoragePolicyType,
                    [Parameter()] [Object]$WitnessHostName
                )
                $Script:_rollbackCallCount++
            }
            Mock Get-SupervisorNameFromPrefix { return "sup-site1" }
            Mock Get-VdsNameFromPrefix { return "VDS-site1" }
            Mock Get-EffectiveNicListForCluster { return @("nic1", "nic2") }
            Mock Remove-NonVmk0VmkernelInterfacesFromVds { }
            Mock Invoke-ManagementRestoreForCleanupWithTopologyFallback {
                return [PSCustomObject]@{ RestoreAttempted = $false; Success = $true; Message = "" }
            }
            Mock Remove-EdgeClusterDistributedSwitch { }
            Mock Remove-ClusterSafely { }

            $fakeSpec  = [PSCustomObject]@{ esxHosts = @("esx1"); vSanWitnessVmName = "witness1" }
            $fakeInput = [PSCustomObject]@{ common = [PSCustomObject]@{ nicList = @("nic1", "nic2"); vSanWitnessVmName = "" } }
            $null = Invoke-ClusterRollbackPhase -ClusterName "cl-site1" -ClusterSpec $fakeSpec `
                -DatastoreNamePrefix "ds" -EdgeSite "site1" -InputData $fakeInput `
                -StoragePolicyTagCatalog "vSAN-ESA-TagCatalog" -StoragePolicyType "vSAN-ESA" `
                -SupervisorNamePrefix "sup" -VdsNamePrefix "VDS"
            $Script:_rollbackCallCount
        }
        $rollbackCalled | Should -BeGreaterOrEqual 1
    }

    It "Calls Remove-NonVmk0VmkernelInterfacesFromVds a second time after Invoke-VsanDeploymentRollback for vSAN-OSA" {
        # Verifies the fix for VDS cleanup failure: vSAN vmkernels can only be removed after vSAN
        # cluster leave (Invoke-VsanDeploymentRollback). The second pass runs after rollback so port
        # groups are free before VDS removal.
        $vmkCallCount = InModuleScope VcfEdgeAtScale {
            $Script:_vmkRemoveCount = 0
            function Invoke-VsanDeploymentRollback {
                [CmdletBinding()]
                Param (
                    [Parameter()] [Object]$ClusterName, [Parameter()] [Object]$EsxHostNames,
                    [Parameter()] [Object]$SkipClusterRemoval, [Parameter()] [Object]$StoragePolicyTagCatalog,
                    [Parameter()] [Object]$StoragePolicyTagName, [Parameter()] [Object]$StoragePolicyType,
                    [Parameter()] [Object]$WitnessHostName
                )
            }
            Mock Get-SupervisorNameFromPrefix { return "sup-site1" }
            Mock Get-VdsNameFromPrefix { return "VDS-site1" }
            Mock Get-EffectiveNicListForCluster { return @("nic1", "nic2") }
            Mock Remove-NonVmk0VmkernelInterfacesFromVds { $Script:_vmkRemoveCount++ }
            Mock Invoke-ManagementRestoreForCleanupWithTopologyFallback {
                return [PSCustomObject]@{ RestoreAttempted = $false; Success = $true; Message = "" }
            }
            Mock Remove-EdgeClusterDistributedSwitch { }
            Mock Remove-ClusterSafely { }

            $fakeSpec  = [PSCustomObject]@{ esxHosts = @("esx1"); vSanWitnessVmName = "" }
            $fakeInput = [PSCustomObject]@{ common = [PSCustomObject]@{ nicList = @("nic1", "nic2"); vSanWitnessVmName = "" } }
            $null = Invoke-ClusterRollbackPhase -ClusterName "cl-site1" -ClusterSpec $fakeSpec `
                -DatastoreNamePrefix "ds" -EdgeSite "site1" -InputData $fakeInput `
                -StoragePolicyType "vSAN-OSA" -SupervisorNamePrefix "sup" -VdsNamePrefix "VDS"
            $Script:_vmkRemoveCount
        }
        # Two calls: once before management restore (early pass) and once after vSAN cluster leave.
        $vmkCallCount | Should -Be 2
    }

    It "Returns true and skips VDS removal when management restore fails" {
        $result = InModuleScope VcfEdgeAtScale {
            function Remove-EdgeClusterDistributedSwitch {
                [CmdletBinding()] Param([Parameter()] [Object]$ClusterName, [Parameter()] [Object]$VdsName)
                throw "Remove-EdgeClusterDistributedSwitch must not be called when restore failed"
            }
            Mock Get-SupervisorNameFromPrefix { return "sup-site1" }
            Mock Get-VdsNameFromPrefix { return "VDS-site1" }
            Mock Get-EffectiveNicListForCluster { return @("nic1", "nic2") }
            Mock Remove-NonVmk0VmkernelInterfacesFromVds { }
            Mock Invoke-ManagementRestoreForCleanupWithTopologyFallback {
                return [PSCustomObject]@{ RestoreAttempted = $true; Success = $false; Message = "restore failed" }
            }

            $fakeSpec  = [PSCustomObject]@{ esxHosts = @(); vSanWitnessVmName = "" }
            $fakeInput = [PSCustomObject]@{ common = [PSCustomObject]@{ nicList = @("nic1", "nic2"); vSanWitnessVmName = "" } }
            Invoke-ClusterRollbackPhase -ClusterName "cl-site1" -ClusterSpec $fakeSpec `
                -DatastoreNamePrefix "ds" -EdgeSite "site1" -InputData $fakeInput `
                -StoragePolicyType "VMFS" -SupervisorNamePrefix "sup" -VdsNamePrefix "VDS"
        }
        $result | Should -Be $true
    }

    It "Re-throws when Invoke-ManagementRestoreForCleanupWithTopologyFallback throws" {
        # When the management restore helper throws, the function must propagate the exception
        # so the caller (Invoke-ComputeCleanupForCluster) can set cleanupHadErrors.
        { InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Get-SupervisorNameFromPrefix { return "sup-site1" }
            Mock Get-VdsNameFromPrefix { return "VDS-site1" }
            Mock Get-EffectiveNicListForCluster { return @("nic1", "nic2") }
            Mock Remove-NonVmk0VmkernelInterfacesFromVds {}
            Mock Invoke-ManagementRestoreForCleanupWithTopologyFallback {
                throw [VcfDeploymentException]::new("Restore threw unexpectedly.")
            }
            $fakeSpec  = [PSCustomObject]@{ esxHosts = @(); vSanWitnessVmName = "" }
            $fakeInput = [PSCustomObject]@{ common = [PSCustomObject]@{ nicList = @("nic1", "nic2"); vSanWitnessVmName = "" } }
            Invoke-ClusterRollbackPhase -ClusterName "cl-site1" -ClusterSpec $fakeSpec `
                -DatastoreNamePrefix "ds" -EdgeSite "site1" -InputData $fakeInput `
                -StoragePolicyType "VMFS" -SupervisorNamePrefix "sup" -VdsNamePrefix "VDS"
        } } | Should -Throw
    }
}

# ── Invoke-SupervisorDeploymentPhase — phase entry conditions ─────────────────


Describe "Invoke-SupervisorDeploymentPhase" {

    It "Skips Invoke-ArgoCDDeploymentPhase when SkipArgoCDDeployment is true" {
        $result = InModuleScope VcfEdgeAtScale {
            function Get-Cluster {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process { return [PSCustomObject]@{ Name = $Name; MoRef = "domain-c1" } }
            }
            function Get-OrCreateSupervisor {
                [CmdletBinding()] Param(
                    [Parameter()] [Object]$StoragePolicyId,
                    [Parameter()] [Object]$SupervisorName,
                    [Parameter()] [Object]$VcenterCredential,
                    [Parameter()] [Object]$SupervisorJson,
                    [Parameter()] [Object]$ClusterId,
                    [Parameter()] [Object]$ClusterName,
                    [Parameter()] [Object]$EdgeSite,
                    [Parameter()] [Object]$NetworkSegments,
                    [Parameter()] [Switch]$SingleSite,
                    [Parameter()] [Switch]$InsecureTls
                )
                return "sup-abc-123"
            }
            $Script:_argoCdCallCount = 0
            function Invoke-ArgoCDDeploymentPhase {
                [CmdletBinding()] Param([Parameter()] [Hashtable]$Context)
                $Script:_argoCdCallCount++
            }
            Mock Invoke-HarborDeploymentPhase { }
            Mock Write-ClusterEsxiNodeHealthReport { }
            Mock Write-SupervisorHealthReport { }

            $ctx = @{
                ArgoCdDeploymentYamlPath     = ""
                ArgoCDyaml                   = ""
                ArgocdNameSpacePrefix        = "argocd"
                ArgocdVmClass                = $null
                Cluster                      = [PSCustomObject]@{ edgeSite = "site1" }
                ClusterId                    = "domain-c1"
                ClusterName                  = "cluster-site1"
                ClustersToProcessCount       = 1
                ContextName                  = "ctx1"
                CurrentEdgeSite              = "site1"
                SkipArgoCDDeployment                = $true
                SkipHarborDeployment                = $true
                InfrastructureJson           = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "infra.json")
                InputData                    = [PSCustomObject]@{ common = [PSCustomObject]@{} }
                LabEnvironment               = $false
                NetworkSegments              = @()
                PreserveAutoGeneratedKeyCert = $false
                SaveHarborYaml               = $false
                StoragePolicyId              = "spbm-001"
                StoragePolicyName            = "sup-site1"
                StoragePolicyType            = "VMFS"
                SupervisorJson               = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "sup.json")
                VcenterCredential            = (New-Object System.Management.Automation.PSCredential("testuser", (ConvertTo-SecureString -String "fake-password" -AsPlainText -Force)))
            }
            $null = Invoke-SupervisorDeploymentPhase -Context $ctx
            $Script:_argoCdCallCount
        }
        $result | Should -Be 0
    }

    It "Skips Invoke-HarborDeploymentPhase when SkipHarborDeployment is true but still calls ArgoCD" {
        $result = InModuleScope VcfEdgeAtScale {
            function Get-Cluster {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process { return [PSCustomObject]@{ Name = $Name; MoRef = "domain-c2" } }
            }
            function Get-OrCreateSupervisor {
                [CmdletBinding()] Param(
                    [Parameter()] [Object]$StoragePolicyId, [Parameter()] [Object]$SupervisorName,
                    [Parameter()] [Object]$VcenterCredential, [Parameter()] [Object]$SupervisorJson,
                    [Parameter()] [Object]$ClusterId, [Parameter()] [Object]$ClusterName,
                    [Parameter()] [Object]$EdgeSite, [Parameter()] [Object]$NetworkSegments,
                    [Parameter()] [Switch]$SingleSite, [Parameter()] [Switch]$InsecureTls
                )
                return "sup-def-456"
            }
            function Get-ArgoCDNamespaceFromCluster {
                [CmdletBinding()] Param([Parameter()] [Object]$ClusterObject, [Parameter()] [Object]$ClusterSpec)
                return "argocd-c2"
            }
            function Test-YamlPropertyConsistency {
                [CmdletBinding()] Param(
                    [Parameter()] [Object]$yamlFilePath, [Parameter()] [Object]$allowMissingProperties,
                    [Parameter()] [Object]$expectedValues, [Parameter()] [Object]$validationName
                )
                return $true
            }
            $Script:_argoCdCallCount = 0
            $Script:_harborCallCount = 0
            function Invoke-ArgoCDDeploymentPhase {
                [CmdletBinding()] Param([Parameter()] [Hashtable]$Context)
                $Script:_argoCdCallCount++
                return $Context.ArgocdVmClass
            }
            function Invoke-HarborDeploymentPhase {
                [CmdletBinding()] Param([Parameter()] [Hashtable]$Context)
                $Script:_harborCallCount++
                return "harbor-svc"
            }
            Mock Write-ClusterEsxiNodeHealthReport { }
            Mock Write-SupervisorHealthReport { }

            $ctx = @{
                ArgoCdDeploymentYamlPath     = "argocd-deploy.yaml"
                ArgoCDyaml                   = "argocd-operator.yaml"
                ArgocdNameSpacePrefix        = "argocd"
                ArgocdVmClass                = $null
                Cluster                      = [PSCustomObject]@{ edgeSite = "site2" }
                ClusterId                    = "domain-c2"
                ClusterName                  = "cluster-site2"
                ClustersToProcessCount       = 2
                ContextName                  = "ctx2"
                CurrentEdgeSite              = "site2"
                SkipArgoCDDeployment                = $false
                SkipHarborDeployment                = $true
                InfrastructureJson           = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "infra.json")
                InputData                    = [PSCustomObject]@{ common = [PSCustomObject]@{} }
                LabEnvironment               = $false
                NetworkSegments              = @()
                PreserveAutoGeneratedKeyCert = $false
                SaveHarborYaml               = $false
                StoragePolicyId              = "spbm-002"
                StoragePolicyName            = "sup-site2"
                StoragePolicyType            = "VMFS"
                SupervisorJson               = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "sup.json")
                VcenterCredential            = (New-Object System.Management.Automation.PSCredential("testuser", (ConvertTo-SecureString -String "fake-password" -AsPlainText -Force)))
            }
            $null = Invoke-SupervisorDeploymentPhase -Context $ctx
            [PSCustomObject]@{ ArgoCD = $Script:_argoCdCallCount; Harbor = $Script:_harborCallCount }
        }
        $result.ArgoCD | Should -Be 1
        $result.Harbor | Should -Be 0
    }

    It "Returns false (success) and calls both ArgoCD and Harbor when both are enabled" {
        $result = InModuleScope VcfEdgeAtScale {
            function Get-Cluster {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process { return [PSCustomObject]@{ Name = $Name; MoRef = "domain-c3" } }
            }
            function Get-OrCreateSupervisor {
                [CmdletBinding()] Param(
                    [Parameter()] [Object]$StoragePolicyId, [Parameter()] [Object]$SupervisorName,
                    [Parameter()] [Object]$VcenterCredential, [Parameter()] [Object]$SupervisorJson,
                    [Parameter()] [Object]$ClusterId, [Parameter()] [Object]$ClusterName,
                    [Parameter()] [Object]$EdgeSite, [Parameter()] [Object]$NetworkSegments,
                    [Parameter()] [Switch]$SingleSite, [Parameter()] [Switch]$InsecureTls
                )
                return "sup-ghi-789"
            }
            function Get-ArgoCDNamespaceFromCluster {
                [CmdletBinding()] Param([Parameter()] [Object]$ClusterObject, [Parameter()] [Object]$ClusterSpec)
                return "argocd-c3"
            }
            function Test-YamlPropertyConsistency {
                [CmdletBinding()] Param(
                    [Parameter()] [Object]$yamlFilePath, [Parameter()] [Object]$allowMissingProperties,
                    [Parameter()] [Object]$expectedValues, [Parameter()] [Object]$validationName
                )
                return $true
            }
            $Script:_argoCdCallCount = 0
            $Script:_harborCallCount = 0
            function Invoke-ArgoCDDeploymentPhase {
                [CmdletBinding()] Param([Parameter()] [Hashtable]$Context)
                $Script:_argoCdCallCount++
                return $Context.ArgocdVmClass
            }
            function Invoke-HarborDeploymentPhase {
                [CmdletBinding()] Param([Parameter()] [Hashtable]$Context)
                $Script:_harborCallCount++
                return "harbor-svc"
            }
            Mock Write-ClusterEsxiNodeHealthReport { }
            Mock Write-SupervisorHealthReport { }

            $ctx = @{
                ArgoCdDeploymentYamlPath     = "argocd-deploy.yaml"
                ArgoCDyaml                   = "argocd-operator.yaml"
                ArgocdNameSpacePrefix        = "argocd"
                ArgocdVmClass                = $null
                Cluster                      = [PSCustomObject]@{ edgeSite = "site3" }
                ClusterId                    = "domain-c3"
                ClusterName                  = "cluster-site3"
                ClustersToProcessCount       = 1
                ContextName                  = "ctx3"
                CurrentEdgeSite              = "site3"
                SkipArgoCDDeployment                = $false
                SkipHarborDeployment                = $false
                InfrastructureJson           = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "infra.json")
                InputData                    = [PSCustomObject]@{ common = [PSCustomObject]@{} }
                LabEnvironment               = $false
                NetworkSegments              = @()
                PreserveAutoGeneratedKeyCert = $false
                SaveHarborYaml               = $false
                StoragePolicyId              = "spbm-003"
                StoragePolicyName            = "sup-site3"
                StoragePolicyType            = "VMFS"
                SupervisorJson               = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "sup.json")
                VcenterCredential            = (New-Object System.Management.Automation.PSCredential("testuser", (ConvertTo-SecureString -String "fake-password" -AsPlainText -Force)))
            }
            $returnValue = Invoke-SupervisorDeploymentPhase -Context $ctx
            [PSCustomObject]@{
                ReturnValue = $returnValue
                ArgoCD      = $Script:_argoCdCallCount
                Harbor      = $Script:_harborCallCount
            }
        }
        $result.ReturnValue | Should -Be $false
        $result.ArgoCD | Should -Be 1
        $result.Harbor | Should -Be 1
    }

    It "Re-throws VcfDeploymentException when Get-OrCreateSupervisor fails (rollback path)" {
        InModuleScope VcfEdgeAtScale {
            # SkipArgoCDDeployment skips YAML validation so the failure point is Get-OrCreateSupervisor.
            # supervisorCreationAttemptedThisSite becomes true before the throw, so the rollback
            # branch (not the pre-attempt re-throw branch) is taken, which ends with throw [VcfDeploymentException].
            function Get-OrCreateSupervisor {
                [CmdletBinding()] Param(
                    [Parameter()] [Object]$StoragePolicyId,
                    [Parameter()] [Object]$SupervisorName,
                    [Parameter()] [Object]$VcenterCredential,
                    [Parameter()] [Object]$SupervisorJson,
                    [Parameter()] [Object]$ClusterId,
                    [Parameter()] [Object]$ClusterName,
                    [Parameter()] [Object]$EdgeSite,
                    [Parameter()] [Object]$NetworkSegments,
                    [Parameter()] [Switch]$SingleSite,
                    [Parameter()] [Switch]$InsecureTls
                )
                throw [VcfDeploymentException]::new("supervisor creation failed")
            }
            function Invoke-SupervisorOnlyRollback {
                [CmdletBinding()] Param(
                    [Parameter()] [Object]$ClusterId,
                    [Parameter()] [Object]$ClusterName,
                    [Parameter()] [Switch]$SingleSite,
                    [Parameter()] [Object]$SupervisorId
                )
            }
            $Script:RollbackFailed   = $false
            $Script:RollbackAttempted = $false
            $Script:HarborPhaseStarted = $false
            $Script:ArgoCDPhaseStarted = $false
            Mock Write-LogMessage {}
            $ctx = @{
                ArgoCdDeploymentYamlPath     = ""
                ArgoCDyaml                   = ""
                ArgocdNameSpacePrefix        = "argocd"
                ArgocdVmClass                = $null
                Cluster                      = [PSCustomObject]@{ edgeSite = "site-ex" }
                ClusterId                    = "domain-cEx"
                ClusterName                  = "cluster-site-ex"
                ClustersToProcessCount       = 1
                ContextName                  = "ctx-ex"
                CurrentEdgeSite              = "site-ex"
                SkipArgoCDDeployment                = $true
                SkipHarborDeployment                = $true
                InfrastructureJson           = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "infra.json")
                InputData                    = [PSCustomObject]@{ common = [PSCustomObject]@{} }
                LabEnvironment               = $false
                NetworkSegments              = @()
                PreserveAutoGeneratedKeyCert = $false
                SaveHarborYaml               = $false
                StoragePolicyId              = "spbm-ex"
                StoragePolicyName            = "sup-site-ex"
                StoragePolicyType            = "VMFS"
                SupervisorJson               = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "sup.json")
                VcenterCredential            = $null
            }
            { Invoke-SupervisorDeploymentPhase -Context $ctx } | Should -Throw
        }
    }
}

# ── Invoke-StorageProvisioningPhase — routing and return value ────────────────


Describe "Invoke-StorageProvisioningPhase" {

    It "Returns true (storageAlreadyProvisioned) when vSAN-ESA datastore tag is already assigned" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Enable-VsanAutomaticDiskClaimIfSupported { }
            Mock Get-VsanClusterHealthSummaryViaView { return $null }
            Mock Test-VsanAutomaticRebalanceAtThreshold { return $true }
            Mock Add-VsanEsaStoragePoolDisk { }
            $Script:_fakeTagId = "tag-001"
            function Get-Datastore {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                return [PSCustomObject]@{ Name = "datastore-vsan-edge1"; Id = "ds-001" }
            }
            function Get-Tag {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Category, [Parameter()] [Object]$Server)
                return [PSCustomObject]@{ Name = "supervisor-vsan-edge1"; Id = $Script:_fakeTagId }
            }
            # Get-TagAssignment -Entity has a VMware type constraint; stub with [Object] to bypass coercion.
            function Get-TagAssignment {
                [CmdletBinding()] Param([Parameter()] [Object]$Entity, [Parameter()] [Object]$Server)
                return @([PSCustomObject]@{ Tag = [PSCustomObject]@{ Id = $Script:_fakeTagId } })
            }
            Mock Set-StoragePolicy { }
            Mock Enable-VsanPerformanceService { }
            Mock Invoke-VsanClusterAlarmCheckAndRemediate { }
            function Get-SpbmStoragePolicy {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                return [PSCustomObject]@{ Name = "supervisor-vsan-edge1" }
            }
            function Get-SpbmCompatibleStorage {
                [CmdletBinding()] Param([Parameter()] [Object]$StoragePolicy, [Parameter()] [Object]$Server)
                return @([PSCustomObject]@{ Name = "datastore-vsan-edge1" })
            }
            $Script:SupervisorName = "supervisor-vsan-edge1"
            $Script:vCenterName = $null
            $ctx = @{
                AcceptBadCheckResults   = $false
                ClusterName             = "cluster-vsan-edge1"
                CurrentEdgeSite         = "vsan-edge1"
                DatastoreName           = "datastore-vsan-edge1"
                DiskCanonicalName       = $null
                EffectiveHaPolicy       = "reservationBased"
                EsxHosts                = @("esx1.lab.local")
                LabEnvironment          = $false
                StoragePolicyName       = "supervisor-vsan-edge1"
                StoragePolicyTagCatalog = "vSAN-ESA-Storage-TagCatalog"
                StoragePolicyType       = "vSAN-ESA"
                VsanWitnessVmName       = $null
            }
            Invoke-StorageProvisioningPhase -Context $ctx
        }
        $result | Should -Be $true
    }

    It "Returns false (new provisioning) when VMFS datastore is created for the first time" {
        $result = InModuleScope VcfEdgeAtScale {
            $fakeHost = [PSCustomObject]@{ Name = "esx1.lab.local" }
            function Get-VMHost {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process { return $fakeHost }
            }
            # Set-NewDatastore returns $false when a new datastore was just created (not already present).
            Mock Set-NewDatastore { return $false }
            Mock Set-StoragePolicy { }
            Mock Invoke-VlcmClusterComplianceAndRemediate { }
            Mock Write-Progress { }
            $fakePolicy = [PSCustomObject]@{ Name = "supervisor-vmfs-edge1" }
            function Get-SpbmStoragePolicy {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                return $fakePolicy
            }
            function Get-SpbmCompatibleStorage {
                [CmdletBinding()] Param([Parameter()] [Object]$StoragePolicy, [Parameter()] [Object]$Server)
                return @([PSCustomObject]@{ Name = "datastore-vmfs-edge1" })
            }
            $Script:SupervisorName = "supervisor-vmfs-edge1"
            $Script:vCenterName = $null
            $ctx = @{
                AcceptBadCheckResults   = $false
                ClusterName             = "cluster-vmfs-edge1"
                CurrentEdgeSite         = "vmfs-edge1"
                DatastoreName           = "datastore-vmfs-edge1"
                DiskCanonicalName       = "naa.600001234567890"
                EffectiveHaPolicy       = "disabled"
                EsxHosts                = @("esx1.lab.local")
                LabEnvironment          = $false
                StoragePolicyName       = "supervisor-vmfs-edge1"
                StoragePolicyTagCatalog = "VMFS-Storage-TagCatalog"
                StoragePolicyType       = "VMFS"
                VsanWitnessVmName       = $null
            }
            Invoke-StorageProvisioningPhase -Context $ctx
        }
        $result | Should -Be $false
    }

    It "Throws VcfDeploymentException when no compatible storage is found for the policy" {
        InModuleScope VcfEdgeAtScale {
            $fakeHost = [PSCustomObject]@{ Name = "esx1.lab.local" }
            function Get-VMHost {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process { return $fakeHost }
            }
            Mock Set-NewDatastore { return $false }
            Mock Set-StoragePolicy { }
            Mock Invoke-VlcmClusterComplianceAndRemediate { }
            Mock Write-Progress { }
            $fakePolicy = [PSCustomObject]@{ Name = "supervisor-vmfs-edge1" }
            function Get-SpbmStoragePolicy {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                return $fakePolicy
            }
            function Get-SpbmCompatibleStorage {
                [CmdletBinding()] Param([Parameter()] [Object]$StoragePolicy, [Parameter()] [Object]$Server)
                return @()
            }
            $Script:SupervisorName = "supervisor-vmfs-edge1"
            $Script:vCenterName = $null
            $ctx = @{
                AcceptBadCheckResults   = $false
                ClusterName             = "cluster-vmfs-edge1"
                CurrentEdgeSite         = "vmfs-edge1"
                DatastoreName           = "datastore-vmfs-edge1"
                DiskCanonicalName       = "naa.600001234567890"
                EffectiveHaPolicy       = "disabled"
                EsxHosts                = @("esx1.lab.local")
                LabEnvironment          = $false
                StoragePolicyName       = "supervisor-vmfs-edge1"
                StoragePolicyTagCatalog = "VMFS-Storage-TagCatalog"
                StoragePolicyType       = "VMFS"
                VsanWitnessVmName       = $null
            }
            { Invoke-StorageProvisioningPhase -Context $ctx } | Should -Throw

        }
    }
}

# ── Invoke-EsxCredentialAndDatastoreSetup — routing and return value ──────────


Describe "Invoke-EsxCredentialAndDatastoreSetup" {

    It "Returns DiskCanonicalName from Find-Datastore and EsxUsedEnvPassword unchanged on VMFS success" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Connect-Vcenter { }
            Mock Test-ESXVersion { return [PSCustomObject]@{ Success = $true; ErrorMessage = "" } }
            Mock Find-Datastore { return "naa.60001234" }
            Mock Disconnect-Vcenter { }
            $secureStr    = New-Object System.Security.SecureString
            $esxCred      = New-Object System.Management.Automation.PSCredential("root", $secureStr)
            $esxPasswords      = @{ "esx1.lab.local" = $esxCred }
            $esxVersionChecked = @{}
            $ctx = @{
                DatastoreName      = "datastore-vmfs-edge1"
                EsxHosts           = @("esx1.lab.local")
                EsxPasswords       = $esxPasswords
                EsxUniquePassword  = $true
                EsxUsedEnvPassword = $false
                EsxUser            = "root"
                EsxVersionChecked  = $esxVersionChecked
                StoragePolicyType  = "VMFS"
            }
            Invoke-EsxCredentialAndDatastoreSetup -Context $ctx
        }
        $result.DiskCanonicalName  | Should -Be "naa.60001234"
        $result.EsxUsedEnvPassword | Should -Be $false
    }

    It "Returns DiskCanonicalName = null for vSAN-OSA when credential validation succeeds" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Connect-Vcenter { }
            Mock Test-ESXVersion { return [PSCustomObject]@{ Success = $true; ErrorMessage = "" } }
            Mock Disconnect-Vcenter { }
            $secureStr    = New-Object System.Security.SecureString
            $esxCred      = New-Object System.Management.Automation.PSCredential("root", $secureStr)
            $esxPasswords      = @{ "esx1.lab.local" = $esxCred }
            $esxVersionChecked = @{}
            $ctx = @{
                DatastoreName      = "datastore-vsan-edge1"
                EsxHosts           = @("esx1.lab.local")
                EsxPasswords       = $esxPasswords
                EsxUniquePassword  = $true
                EsxUsedEnvPassword = $false
                EsxUser            = "root"
                EsxVersionChecked  = $esxVersionChecked
                StoragePolicyType  = "vSAN-OSA"
            }
            Invoke-EsxCredentialAndDatastoreSetup -Context $ctx
        }
        $result.DiskCanonicalName  | Should -BeNullOrEmpty
        $result.EsxUsedEnvPassword | Should -Be $false
    }

    It "Throws VcfDeploymentException when a VMFS ESX host cannot be reached" {
        InModuleScope VcfEdgeAtScale {
            Mock Connect-Vcenter { throw "Connection refused to esx1.lab.local" }
            Mock Disconnect-Vcenter { }
            $esxPasswords      = @{ "esx1.lab.local" = [PSCustomObject]@{ UserName = "root" } }
            $esxVersionChecked = @{}
            $ctx = @{
                DatastoreName      = "datastore-vmfs-edge1"
                EsxHosts           = @("esx1.lab.local")
                EsxPasswords       = $esxPasswords
                EsxUniquePassword  = $true
                EsxUsedEnvPassword = $false
                EsxUser            = "root"
                EsxVersionChecked  = $esxVersionChecked
                StoragePolicyType  = "VMFS"
            }
            { Invoke-EsxCredentialAndDatastoreSetup -Context $ctx } | Should -Throw

        }
    }
}


Describe "Invoke-ClusterPreSupervisorPhase" {

    It "Returns ClusterId, StoragePolicyId, and ShouldContinue = false when ComputeOnly is false" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Test-TagCatalogCategory { }
            Mock Test-Tag { }
            Mock Invoke-StorageProvisioningPhase { return @{ StorageAlreadyProvisioned = $false } }
            Mock Get-ClusterId { return "domain-c10" }
            Mock Get-StoragePolicyId { return "policy-001" }
            $Script:DidMigrateVmk0ToVdsThisRun = $false
            $fakeCluster  = [PSCustomObject]@{ vSanWitnessVmName = $null }
            $fakeInputData = [PSCustomObject]@{ common = [PSCustomObject]@{ vSanWitnessVmName = $null } }
            $ctx = @{
                AcceptBadCheckResults   = $false
                Cluster                 = $fakeCluster
                ClusterName             = "cluster-vsan-edge1"
                ComputeOnly             = $false
                CurrentEdgeSite         = "vsan-edge1"
                DatastoreName           = "datastore-vsan-edge1"
                DiskCanonicalName       = $null
                EffectiveHaPolicy       = "reservationBased"
                EsxHosts                = @("esx1.lab.local")
                InputData               = $fakeInputData
                LabEnvironment          = $false
                StoragePolicyName       = "supervisor-vsan-edge1"
                StoragePolicyTagCatalog = "vSAN-OSA-Storage-TagCatalog"
                StoragePolicyType       = "vSAN-OSA"
                SupervisorName          = "supervisor-vsan-edge1"
            }
            Invoke-ClusterPreSupervisorPhase -Context $ctx
        }
        $result.ShouldContinue   | Should -Be $false
        $result.ClusterId        | Should -Be "domain-c10"
        $result.StoragePolicyId  | Should -Be "policy-001"
    }

    It "Returns ShouldContinue = true and calls health reports when ComputeOnly is true (vSAN-ESA)" {
        $healthRetestCalled = InModuleScope VcfEdgeAtScale {
            $Script:_healthRetestCount = 0
            Mock Test-TagCatalogCategory { }
            Mock Test-Tag { }
            Mock Invoke-StorageProvisioningPhase { return @{ StorageAlreadyProvisioned = $false } }
            Mock Get-ClusterId { return "domain-c20" }
            Mock Get-StoragePolicyId { return "policy-002" }
            Mock Invoke-VsanClusterHealthRetestAfterDeployment { $Script:_healthRetestCount++ }
            Mock Write-VsanClusterHealthReport { }
            Mock Write-ClusterEsxiNodeHealthReport { }
            $Script:DidMigrateVmk0ToVdsThisRun = $false
            $fakeCluster   = [PSCustomObject]@{ vSanWitnessVmName = $null }
            $fakeInputData = [PSCustomObject]@{ common = [PSCustomObject]@{ vSanWitnessVmName = $null } }
            $ctx = @{
                AcceptBadCheckResults   = $false
                Cluster                 = $fakeCluster
                ClusterName             = "cluster-vsan-edge1"
                ComputeOnly             = $true
                CurrentEdgeSite         = "vsan-edge1"
                DatastoreName           = "datastore-vsan-edge1"
                DiskCanonicalName       = $null
                EffectiveHaPolicy       = "reservationBased"
                EsxHosts                = @("esx1.lab.local")
                InputData               = $fakeInputData
                LabEnvironment          = $false
                StoragePolicyName       = "supervisor-vsan-edge1"
                StoragePolicyTagCatalog = "vSAN-ESA-Storage-TagCatalog"
                StoragePolicyType       = "vSAN-ESA"
                SupervisorName          = "supervisor-vsan-edge1"
            }
            $result = Invoke-ClusterPreSupervisorPhase -Context $ctx
            # Return the ShouldContinue flag and health retest count for assertions.
            @{ ShouldContinue = $result.ShouldContinue; HealthRetestCount = $Script:_healthRetestCount }
        }
        $healthRetestCalled.ShouldContinue   | Should -Be $true
        $healthRetestCalled.HealthRetestCount | Should -Be 1
    }

    It "Discards vSAN witness name when StoragePolicyType is VMFS (witness not relevant)" {
        $witnessPassedToStorage = InModuleScope VcfEdgeAtScale {
            $Script:_storageCtxWitness = "unset"
            Mock Test-TagCatalogCategory { }
            Mock Test-Tag { }
            Mock Invoke-StorageProvisioningPhase {
                $Script:_storageCtxWitness = $Context.VsanWitnessVmName
                return @{ StorageAlreadyProvisioned = $false }
            }
            Mock Get-ClusterId { return "domain-c30" }
            Mock Get-StoragePolicyId { return "policy-003" }
            $Script:DidMigrateVmk0ToVdsThisRun = $false
            # Cluster has a witness configured, but storage type is VMFS — witness must be discarded.
            $fakeCluster   = [PSCustomObject]@{ vSanWitnessVmName = "witness-vm-1" }
            $fakeInputData = [PSCustomObject]@{ common = [PSCustomObject]@{ vSanWitnessVmName = $null } }
            $ctx = @{
                AcceptBadCheckResults   = $false
                Cluster                 = $fakeCluster
                ClusterName             = "cluster-vmfs-edge1"
                ComputeOnly             = $false
                CurrentEdgeSite         = "vmfs-edge1"
                DatastoreName           = "datastore-vmfs-edge1"
                DiskCanonicalName       = "naa.60001234"
                EffectiveHaPolicy       = "disabled"
                EsxHosts                = @("esx1.lab.local")
                InputData               = $fakeInputData
                LabEnvironment          = $false
                StoragePolicyName       = "supervisor-vmfs-edge1"
                StoragePolicyTagCatalog = "VMFS-Storage-TagCatalog"
                StoragePolicyType       = "VMFS"
                SupervisorName          = "supervisor-vmfs-edge1"
            }
            $null = Invoke-ClusterPreSupervisorPhase -Context $ctx
            $Script:_storageCtxWitness
        }
        # Invoke-StorageProvisioningPhase must receive VsanWitnessVmName = $null for VMFS.
        $witnessPassedToStorage | Should -BeNullOrEmpty
    }
}


Describe "Invoke-ClusterHostAdditionPhase" {

    It "Calls Add-HostToCluster for each ESX host and skips Add-VmkernelInterfacesFromNetworkingConfig on VMFS" {
        $addHostCallCount = InModuleScope VcfEdgeAtScale {
            $Script:_addHostCount = 0
            function Add-HostToCluster {
                [CmdletBinding()] Param([Parameter()] [Object]$ClusterName, [Parameter()] [Object]$EsxCredential, [Parameter()] [Object]$EsxHostName, [Parameter()] [Object]$NicList, [Parameter()] [Object]$StoragePolicyType)
                $Script:_addHostCount++
            }
            function Add-VmkernelInterfacesFromNetworkingConfig {
                [CmdletBinding()] Param([Parameter()] [Object]$ClusterName, [Parameter()] [Object]$EsxHostNames, [Parameter()] [Object]$NetworkingVmKernelInterfaces, [Parameter()] [Object]$NumUplinks, [Parameter()] [Object]$VdsName, [Parameter()] [Object]$VmkernelMtu)
                throw "Add-VmkernelInterfacesFromNetworkingConfig must not be called for VMFS"
            }
            function Set-VirtualDistributedSwitch {
                [CmdletBinding()] Param([Parameter()] [Object]$ClusterName, [Parameter()] [Object]$DatacenterName, [Parameter()] [Object]$Mtu, [Parameter()] [Object]$NicList, [Parameter()] [Object]$NumUplinks, [Parameter()] [Object]$PortGroups, [Parameter()] [Object]$VdsName)
            }
            Mock Get-EffectiveVmkernelMtu { return 9000 }
            $secureStr  = New-Object System.Security.SecureString
            $esxCred    = New-Object System.Management.Automation.PSCredential("root", $secureStr)
            $esxPasswords = @{ "esx1.lab.local" = $esxCred; "esx2.lab.local" = $esxCred }
            $fakeCluster = [PSCustomObject]@{ networking = [PSCustomObject]@{ networkingVmKernelInterfaces = $null } }
            $ctx = @{
                Cluster                          = $fakeCluster
                ClusterName                      = "cluster-vmfs-edge1"
                DatacenterName                   = "Datacenter"
                DelayBeforeAddingNextHostSeconds = 0
                EsxHosts                         = @("esx1.lab.local", "esx2.lab.local")
                EsxPasswords                     = $esxPasswords
                EsxUniquePassword                = $true
                EsxUser                          = "root"
                InputData                        = [PSCustomObject]@{ common = [PSCustomObject]@{} }
                NetworkSegments                  = @()
                NicList                          = @("vmnic0", "vmnic1")
                NumUplinks                       = 2
                StoragePolicyType                = "VMFS"
                VdsName                          = "VDS-vmfs-edge1-sw1"
            }
            Invoke-ClusterHostAdditionPhase -Context $ctx
            $Script:_addHostCount
        }
        $addHostCallCount | Should -Be 2
    }

    It "Calls Add-VmkernelInterfacesFromNetworkingConfig once for vSAN-ESA with networkingVmKernelInterfaces" {
        $vmkCallCount = InModuleScope VcfEdgeAtScale {
            $Script:_vmkCount = 0
            function Add-HostToCluster {
                [CmdletBinding()] Param([Parameter()] [Object]$ClusterName, [Parameter()] [Object]$EsxCredential, [Parameter()] [Object]$EsxHostName, [Parameter()] [Object]$NicList, [Parameter()] [Object]$StoragePolicyType)
            }
            function Add-VmkernelInterfacesFromNetworkingConfig {
                [CmdletBinding()] Param([Parameter()] [Object]$ClusterName, [Parameter()] [Object]$EsxHostNames, [Parameter()] [Object]$NetworkingVmKernelInterfaces, [Parameter()] [Object]$NumUplinks, [Parameter()] [Object]$VdsName, [Parameter()] [Object]$VmkernelMtu)
                $Script:_vmkCount++
            }
            function Get-Cluster {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                return [PSCustomObject]@{ Name = $Name }
            }
            function Get-VMHost {
                [CmdletBinding()] Param([Parameter()] [Object]$Location, [Parameter()] [Object]$Server)
                # Return empty array: vSAN witness traffic loop does not execute.
                return @()
            }
            function Set-VirtualDistributedSwitch {
                [CmdletBinding()] Param([Parameter()] [Object]$ClusterName, [Parameter()] [Object]$DatacenterName, [Parameter()] [Object]$Mtu, [Parameter()] [Object]$NicList, [Parameter()] [Object]$NumUplinks, [Parameter()] [Object]$PortGroups, [Parameter()] [Object]$VdsName)
            }
            Mock Get-EffectiveVmkernelMtu { return 9000 }
            $secureStr    = New-Object System.Security.SecureString
            $esxCred      = New-Object System.Management.Automation.PSCredential("root", $secureStr)
            $esxPasswords = @{ "esx1.lab.local" = $esxCred }
            $vmkIfaces    = @(
                [PSCustomObject]@{ service = "vMotion" },
                [PSCustomObject]@{ service = "vSAN" }
            )
            $fakeCluster = [PSCustomObject]@{ networking = [PSCustomObject]@{ networkingVmKernelInterfaces = $vmkIfaces } }
            $ctx = @{
                Cluster                          = $fakeCluster
                ClusterName                      = "cluster-vsan-edge1"
                DatacenterName                   = "Datacenter"
                DelayBeforeAddingNextHostSeconds = 0
                EsxHosts                         = @("esx1.lab.local")
                EsxPasswords                     = $esxPasswords
                EsxUniquePassword                = $true
                EsxUser                          = "root"
                InputData                        = [PSCustomObject]@{ common = [PSCustomObject]@{} }
                NetworkSegments                  = @()
                NicList                          = @("vmnic0", "vmnic1")
                NumUplinks                       = 2
                StoragePolicyType                = "vSAN-ESA"
                VdsName                          = "VDS-vsan-edge1-sw1"
            }
            Invoke-ClusterHostAdditionPhase -Context $ctx
            $Script:_vmkCount
        }
        $vmkCallCount | Should -Be 1
    }

    It "Removes EsxPasswords entries for each host when EsxUniquePassword is false" {
        $remainingPasswords = InModuleScope VcfEdgeAtScale {
            function Add-HostToCluster {
                [CmdletBinding()] Param([Parameter()] [Object]$ClusterName, [Parameter()] [Object]$EsxCredential, [Parameter()] [Object]$EsxHostName, [Parameter()] [Object]$NicList, [Parameter()] [Object]$StoragePolicyType)
            }
            function Add-VmkernelInterfacesFromNetworkingConfig {
                [CmdletBinding()] Param([Parameter()] [Object]$ClusterName, [Parameter()] [Object]$EsxHostNames, [Parameter()] [Object]$NetworkingVmKernelInterfaces, [Parameter()] [Object]$NumUplinks, [Parameter()] [Object]$VdsName, [Parameter()] [Object]$VmkernelMtu)
            }
            function Set-VirtualDistributedSwitch {
                [CmdletBinding()] Param([Parameter()] [Object]$ClusterName, [Parameter()] [Object]$DatacenterName, [Parameter()] [Object]$Mtu, [Parameter()] [Object]$NicList, [Parameter()] [Object]$NumUplinks, [Parameter()] [Object]$PortGroups, [Parameter()] [Object]$VdsName)
            }
            Mock Get-EffectiveVmkernelMtu { return 9000 }
            $secureStr  = New-Object System.Security.SecureString
            $esxCred    = New-Object System.Management.Automation.PSCredential("root", $secureStr)
            # EsxUniquePassword false = per-host passwords; should be cleared after use.
            $esxPasswords = @{ "esx1.lab.local" = $esxCred; "esx2.lab.local" = $esxCred }
            $fakeCluster = [PSCustomObject]@{ networking = [PSCustomObject]@{ networkingVmKernelInterfaces = $null } }
            $ctx = @{
                Cluster                          = $fakeCluster
                ClusterName                      = "cluster-vmfs-edge1"
                DatacenterName                   = "Datacenter"
                DelayBeforeAddingNextHostSeconds = 0
                EsxHosts                         = @("esx1.lab.local", "esx2.lab.local")
                EsxPasswords                     = $esxPasswords
                EsxUniquePassword                = $false
                EsxUser                          = "root"
                InputData                        = [PSCustomObject]@{ common = [PSCustomObject]@{} }
                NetworkSegments                  = @()
                NicList                          = @("vmnic0", "vmnic1")
                NumUplinks                       = 2
                StoragePolicyType                = "VMFS"
                VdsName                          = "VDS-vmfs-edge1-sw1"
            }
            Invoke-ClusterHostAdditionPhase -Context $ctx
            $esxPasswords.Count
        }
        $remainingPasswords | Should -Be 0
    }

    It "Propagates exception when Add-HostToCluster throws" {
        InModuleScope VcfEdgeAtScale {
            function Add-HostToCluster {
                [CmdletBinding()] Param([Parameter()] [Object]$ClusterName, [Parameter()] [Object]$EsxCredential, [Parameter()] [Object]$EsxHostName, [Parameter()] [Object]$NicList, [Parameter()] [Object]$StoragePolicyType)
                throw [VcfDeploymentException]::new("Add-HostToCluster simulated failure.")
            }
            function Set-VirtualDistributedSwitch {
                [CmdletBinding()] Param([Parameter()] [Object]$ClusterName, [Parameter()] [Object]$DatacenterName, [Parameter()] [Object]$Mtu, [Parameter()] [Object]$NicList, [Parameter()] [Object]$NumUplinks, [Parameter()] [Object]$PortGroups, [Parameter()] [Object]$VdsName)
            }
            Mock Get-EffectiveVmkernelMtu { return 9000 }
            $secureStr    = New-Object System.Security.SecureString
            $esxCred      = New-Object System.Management.Automation.PSCredential("root", $secureStr)
            $esxPasswords = @{ "esx1.lab.local" = $esxCred }
            $fakeCluster  = [PSCustomObject]@{ networking = [PSCustomObject]@{ networkingVmKernelInterfaces = $null } }
            $ctx = @{
                Cluster                          = $fakeCluster
                ClusterName                      = "cluster-edge1"
                DatacenterName                   = "Datacenter"
                DelayBeforeAddingNextHostSeconds = 0
                EsxHosts                         = @("esx1.lab.local")
                EsxPasswords                     = $esxPasswords
                EsxUniquePassword                = $true
                EsxUser                          = "root"
                InputData                        = [PSCustomObject]@{ common = [PSCustomObject]@{} }
                NetworkSegments                  = @()
                NicList                          = @("vmnic0", "vmnic1")
                NumUplinks                       = 2
                StoragePolicyType                = "VMFS"
                VdsName                          = "VDS-edge1-sw1"
            }
            { Invoke-ClusterHostAdditionPhase -Context $ctx } | Should -Throw
        }
    }
}


Describe "Invoke-ClusterPerSiteVariables" {

    It "Returns EdgeSite, ClusterName, VMFS storage fields, and HA policy disabled for a VMFS cluster" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Get-EffectiveClusterName           { "cluster-vmfs-edge1" }
            Mock Get-DatastoreNameFromPrefix        { "datastore-vmfs-edge1" }
            Mock Get-VdsNameFromPrefix              { "VDS-vmfs-edge1" }
            Mock Get-SupervisorNameFromPrefix       { "supervisor-vmfs-edge1" }
            Mock Get-EffectiveArgoCdYamlPath        { "/path/argocd.yaml" }
            Mock Get-EffectiveSupervisorServiceFlag { $false }
            Mock Get-EffectiveNicListForCluster     { @("vmnic0", "vmnic1") }
            $cluster = @{
                edgeSite      = "vmfs-edge1"
                esxHosts      = @("esx1.lab")
                networking    = @{ networkSegments = @{ mgmt = "172.16.0.0/24" } }
                storagePolicy = @{ storageType = "VMFS"; storagePolicyName = "VMFS-Policy"; storagePolicyTagCatalog = "VMFS-TagCatalog" }
                supervisorServices = $null
            }
            $inputData = @{ common = @{ nicList = @("vmnic0", "vmnic1") } }
            Invoke-ClusterPerSiteVariables -Cluster $cluster -ClusterNamePrefix "cluster" `
                -DatastoreNamePrefix "datastore" -InputData $inputData `
                -SupervisorNamePrefix "supervisor" -VdsNamePrefix "VDS"
        }
        $result.EdgeSite                   | Should -Be "vmfs-edge1"
        $result.ClusterName                | Should -Be "cluster-vmfs-edge1"
        $result.StoragePolicyType          | Should -Be "VMFS"
        $result.StoragePolicyName          | Should -Be "VMFS-Policy"
        $result.StoragePolicyTagCatalog    | Should -Be "VMFS-TagCatalog"
        $result.EffectiveMultiHostHaPolicy | Should -Be "disabled"
        $result.NicList                    | Should -HaveCount 2
        $result.NumUplinks                 | Should -Be 2
        $result.SupervisorName             | Should -Be "supervisor-vmfs-edge1"
    }

    It "Falls back StoragePolicyName to SupervisorName and derives default TagCatalog for vSAN-ESA when names absent" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Get-EffectiveClusterName           { "cluster-vsan-edge2" }
            Mock Get-DatastoreNameFromPrefix        { "datastore-vsan-edge2" }
            Mock Get-VdsNameFromPrefix              { "VDS-vsan-edge2" }
            Mock Get-SupervisorNameFromPrefix       { "supervisor-vsan-edge2" }
            Mock Get-EffectiveArgoCdYamlPath        { $null }
            Mock Get-EffectiveSupervisorServiceFlag { $false }
            Mock Get-EffectiveHaPolicyForCluster    { "reservationBased" }
            Mock Get-EffectiveNicListForCluster     { @("vmnic0", "vmnic1", "vmnic2", "vmnic3") }
            $cluster = @{
                edgeSite      = "vsan-edge2"
                esxHosts      = @("esx1.lab", "esx2.lab")
                networking    = @{ networkSegments = @{ mgmt = "172.16.1.0/24" } }
                storagePolicy = @{ storageType = "vSAN-ESA"; storagePolicyTagCatalog = $null }
                supervisorServices = $null
            }
            $inputData = @{ common = @{ nicList = @("vmnic0", "vmnic1", "vmnic2", "vmnic3") } }
            Invoke-ClusterPerSiteVariables -Cluster $cluster -ClusterNamePrefix "cluster" `
                -DatastoreNamePrefix "datastore" -InputData $inputData `
                -SupervisorNamePrefix "supervisor" -VdsNamePrefix "VDS"
        }
        $result.StoragePolicyName          | Should -Be "supervisor-vsan-edge2"
        $result.StoragePolicyTagCatalog    | Should -Be "vSAN-ESA-Storage-TagCatalog"
        $result.EffectiveMultiHostHaPolicy | Should -Be "reservationBased"
        $result.NumUplinks                 | Should -Be 4
    }

    It "Throws VcfDeploymentException when Cluster.networking.networkSegments is absent" {
        InModuleScope VcfEdgeAtScale {
            Mock Get-EffectiveClusterName           { "cluster-edge3" }
            Mock Get-DatastoreNameFromPrefix        { "datastore-edge3" }
            Mock Get-VdsNameFromPrefix              { "VDS-edge3" }
            Mock Get-SupervisorNameFromPrefix       { "supervisor-edge3" }
            Mock Get-EffectiveArgoCdYamlPath        { $null }
            Mock Get-EffectiveSupervisorServiceFlag { $false }
            Mock Get-EffectiveNicListForCluster     { @("vmnic0", "vmnic1") }
            $cluster = @{
                edgeSite      = "edge3"
                esxHosts      = @("esx1.lab")
                networking    = @{}
                storagePolicy = @{ storageType = "VMFS"; storagePolicyName = "pol"; storagePolicyTagCatalog = "cat" }
                supervisorServices = $null
            }
            $inputData = @{ common = @{ nicList = @("vmnic0", "vmnic1") } }
            {
                Invoke-ClusterPerSiteVariables -Cluster $cluster -ClusterNamePrefix "cluster" `
                    -DatastoreNamePrefix "datastore" -InputData $inputData `
                    -SupervisorNamePrefix "supervisor" -VdsNamePrefix "VDS"
            } | Should -Throw
        }
    }
}


Describe "Invoke-ClusterCreationPhase" {

    It "Calls Add-Cluster with VsanEsaEnabled and cluster-level vLcmImageName for vSAN-ESA" {
        $addClusterArgs = InModuleScope VcfEdgeAtScale {
            $Script:_addClusterArgs = $null
            function Invoke-VcenterReconnectIfNeeded { [CmdletBinding()] Param() }
            function Add-Cluster {
                [CmdletBinding()] Param(
                    [Parameter()] [Object]$ClusterName,
                    [Parameter()] [Object]$DataCenterName,
                    [Parameter()] [Object]$VsanEsaEnabled,
                    [Parameter()] [Object]$VsanOsaEnabled,
                    [Parameter()] [Object]$VlcmImageName
                )
                $Script:_addClusterArgs = @{
                    ClusterName    = $ClusterName
                    VsanEsaEnabled = $VsanEsaEnabled
                    VsanOsaEnabled = $VsanOsaEnabled
                    VlcmImageName  = $VlcmImageName
                }
            }
            $cluster   = @{ vLcmImageName = "cluster-image-1.0" }
            $inputData = @{ common = @{ vLcmImageName = "common-image-2.0" } }
            Invoke-ClusterCreationPhase -Cluster $cluster -ClusterName "cluster-vsan-edge1" `
                -DatacenterName "DC" -InputData $inputData -StoragePolicyType "vSAN-ESA"
            $Script:_addClusterArgs
        }
        $addClusterArgs.VsanEsaEnabled | Should -Be $true
        $addClusterArgs.VsanOsaEnabled | Should -Be $false
        $addClusterArgs.VlcmImageName  | Should -Be "cluster-image-1.0"
    }

    It "Falls back to common vLcmImageName when cluster.vLcmImageName is absent (vSAN-OSA)" {
        $addClusterArgs = InModuleScope VcfEdgeAtScale {
            $Script:_addClusterArgs = $null
            function Invoke-VcenterReconnectIfNeeded { [CmdletBinding()] Param() }
            function Add-Cluster {
                [CmdletBinding()] Param(
                    [Parameter()] [Object]$ClusterName,
                    [Parameter()] [Object]$DataCenterName,
                    [Parameter()] [Object]$VsanEsaEnabled,
                    [Parameter()] [Object]$VsanOsaEnabled,
                    [Parameter()] [Object]$VlcmImageName
                )
                $Script:_addClusterArgs = @{
                    VsanEsaEnabled = $VsanEsaEnabled
                    VsanOsaEnabled = $VsanOsaEnabled
                    VlcmImageName  = $VlcmImageName
                }
            }
            $cluster   = @{ vLcmImageName = $null }
            $inputData = @{ common = @{ vLcmImageName = "common-image-2.0" } }
            Invoke-ClusterCreationPhase -Cluster $cluster -ClusterName "cluster-vsan-edge2" `
                -DatacenterName "DC" -InputData $inputData -StoragePolicyType "vSAN-OSA"
            $Script:_addClusterArgs
        }
        $addClusterArgs.VsanEsaEnabled | Should -Be $false
        $addClusterArgs.VsanOsaEnabled | Should -Be $true
        $addClusterArgs.VlcmImageName  | Should -Be "common-image-2.0"
    }

    It "Passes null VlcmImageName to Add-Cluster when neither cluster nor common defines it (VMFS)" {
        $addClusterArgs = InModuleScope VcfEdgeAtScale {
            $Script:_addClusterArgs = $null
            function Invoke-VcenterReconnectIfNeeded { [CmdletBinding()] Param() }
            function Add-Cluster {
                [CmdletBinding()] Param(
                    [Parameter()] [Object]$ClusterName,
                    [Parameter()] [Object]$DataCenterName,
                    [Parameter()] [Object]$VsanEsaEnabled,
                    [Parameter()] [Object]$VsanOsaEnabled,
                    [Parameter()] [Object]$VlcmImageName
                )
                $Script:_addClusterArgs = @{
                    VsanEsaEnabled = $VsanEsaEnabled
                    VsanOsaEnabled = $VsanOsaEnabled
                    VlcmImageName  = $VlcmImageName
                }
            }
            $cluster   = @{ vLcmImageName = $null }
            $inputData = @{ common = @{ vLcmImageName = $null } }
            Invoke-ClusterCreationPhase -Cluster $cluster -ClusterName "cluster-vmfs-edge3" `
                -DatacenterName "DC" -InputData $inputData -StoragePolicyType "VMFS"
            $Script:_addClusterArgs
        }
        $addClusterArgs.VsanEsaEnabled | Should -Be $false
        $addClusterArgs.VsanOsaEnabled | Should -Be $false
        $addClusterArgs.VlcmImageName  | Should -BeNullOrEmpty
    }

    It "Propagates exception when Add-Cluster throws" {
        InModuleScope VcfEdgeAtScale {
            function Invoke-VcenterReconnectIfNeeded { [CmdletBinding()] Param() }
            function Add-Cluster {
                [CmdletBinding()] Param(
                    [Parameter()] [Object]$ClusterName, [Parameter()] [Object]$DataCenterName,
                    [Parameter()] [Object]$VsanEsaEnabled, [Parameter()] [Object]$VsanOsaEnabled,
                    [Parameter()] [Object]$VlcmImageName
                )
                throw [VcfDeploymentException]::new("Add-Cluster simulated failure.")
            }
            $cluster   = @{ vLcmImageName = $null }
            $inputData = @{ common = @{ vLcmImageName = $null } }
            {
                Invoke-ClusterCreationPhase -Cluster $cluster -ClusterName "cluster-edge1" `
                    -DatacenterName "DC" -InputData $inputData -StoragePolicyType "vSAN-ESA"
            } | Should -Throw
        }
    }
}

# ── Invoke-EsxCredentialCollection ───────────────────────────────────────────


Describe "Invoke-EsxCredentialCollection" {

    It "Returns empty EsxPasswords and EsxUsedEnvPassword = false when EsxUniquePassword is false" {
        InModuleScope VcfEdgeAtScale {
            $hosts = [System.Collections.Generic.List[object]]::new()
            $hosts.Add("esx1.lab.local")

            $result = Invoke-EsxCredentialCollection `
                -AllEsxHosts $hosts -EsxUniquePassword $false -EsxUser "root" -NonInteractivePassword $false

            $result.EsxPasswords.Count  | Should -Be 0
            $result.EsxUsedEnvPassword  | Should -Be $false
        }
    }

    It "Returns populated EsxPasswords and EsxUsedEnvPassword = true when NonInteractivePassword and env var are set" {
        InModuleScope VcfEdgeAtScale {
            $hosts = [System.Collections.Generic.List[object]]::new()
            $hosts.Add("esx1.lab.local")

            function ConvertTo-SecureStringForCredential {
                [CmdletBinding()] Param([Parameter()] [Object]$PlainText)
                return (ConvertTo-SecureString -String "envpass" -AsPlainText -Force)
            }

            $env:ESX_COMMON_PASSWORD = "envpass"
            try {
                $result = Invoke-EsxCredentialCollection `
                    -AllEsxHosts $hosts -EsxUniquePassword $true -EsxUser "root" -NonInteractivePassword $true

                $result.EsxUsedEnvPassword            | Should -Be $true
                $result.EsxPasswords["esx1.lab.local"] | Should -Not -BeNullOrEmpty
                $result.EsxPasswords["esx1.lab.local"].UserName | Should -Be "root"
            } finally {
                Remove-Item Env:ESX_COMMON_PASSWORD -ErrorAction SilentlyContinue
            }
        }
    }

    It "Returns populated EsxPasswords via interactive prompt when NonInteractivePassword is false" {
        InModuleScope VcfEdgeAtScale {
            $hosts = [System.Collections.Generic.List[object]]::new()
            $hosts.Add("esx2.lab.local")

            function Get-InteractiveInput {
                [CmdletBinding()] Param([Parameter()] [Object]$PromptMessage, [Parameter()] [Switch]$AsSecureString, [Parameter()] [Switch]$AllowEmpty)
                return (ConvertTo-SecureString -String "promptpass" -AsPlainText -Force)
            }

            $result = Invoke-EsxCredentialCollection `
                -AllEsxHosts $hosts -EsxUniquePassword $true -EsxUser "root" -NonInteractivePassword $false

            $result.EsxUsedEnvPassword            | Should -Be $false
            $result.EsxPasswords["esx2.lab.local"] | Should -Not -BeNullOrEmpty
            $result.EsxPasswords["esx2.lab.local"].UserName | Should -Be "root"
        }
    }
}

# ── Invoke-WitnessHostPreflightCheck ─────────────────────────────────────────


Describe "Invoke-WitnessHostPreflightCheck" {

    It "Completes without throwing when vSAN witness is present in vCenter inventory" {
        InModuleScope VcfEdgeAtScale {
            $fakeCluster = [PSCustomObject]@{
                edgeSite      = "edge1"
                storagePolicy = [PSCustomObject]@{ storageType = "vSAN-ESA" }
            }
            $fakeInputData = [PSCustomObject]@{ common = [PSCustomObject]@{ vSanWitnessVmName = "witness.lab.local" } }

            function Get-VsanWitnessNameForCluster {
                [CmdletBinding()] Param([Parameter()] [Object]$Cluster, [Parameter()] [Object]$InputData)
                return "witness.lab.local"
            }
            function Get-VMHost {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                return [PSCustomObject]@{ Name = "witness.lab.local" }
            }
            Mock Write-LogMessage {}

            { Invoke-WitnessHostPreflightCheck -ClustersToProcess @($fakeCluster) -InputData $fakeInputData } |
                Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "DEBUG" -and $Message -match "is present in vCenter inventory" }
        }
    }

    It "Throws VcfDeploymentException when vSAN witness is absent from vCenter inventory" {
        InModuleScope VcfEdgeAtScale {
            $fakeCluster = [PSCustomObject]@{
                edgeSite      = "edge1"
                storagePolicy = [PSCustomObject]@{ storageType = "vSAN-ESA" }
            }
            $fakeInputData = [PSCustomObject]@{ common = [PSCustomObject]@{ vSanWitnessVmName = "missing-witness.lab.local" } }

            function Get-VsanWitnessNameForCluster {
                [CmdletBinding()] Param([Parameter()] [Object]$Cluster, [Parameter()] [Object]$InputData)
                return "missing-witness.lab.local"
            }
            function Get-VMHost {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                return $null
            }

            { Invoke-WitnessHostPreflightCheck -ClustersToProcess @($fakeCluster) -InputData $fakeInputData } |
                Should -Throw
        }
    }

    It "Does NOT throw when witness is absent but cluster is VMFS (non-vSAN)" {
        InModuleScope VcfEdgeAtScale {
            $fakeCluster = [PSCustomObject]@{
                edgeSite      = "edge1"
                storagePolicy = [PSCustomObject]@{ storageType = "VMFS" }
            }
            $fakeInputData = [PSCustomObject]@{ common = [PSCustomObject]@{ vSanWitnessVmName = "witness.lab.local" } }

            function Get-VsanWitnessNameForCluster {
                [CmdletBinding()] Param([Parameter()] [Object]$Cluster, [Parameter()] [Object]$InputData)
                return "witness.lab.local"
            }
            function Get-VMHost {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                return $null
            }
            Mock Write-LogMessage {}

            { Invoke-WitnessHostPreflightCheck -ClustersToProcess @($fakeCluster) -InputData $fakeInputData } |
                Should -Not -Throw
            # Non-vSAN: missing witness logs DEBUG only, never ERROR.
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "DEBUG" -and $Message -match "not required" }
        }
    }
}

# ── Invoke-EsxPreFlightVersionCheck ──────────────────────────────────────────


Describe "Invoke-EsxPreFlightVersionCheck" {

    It "Returns empty hashtable when AllEsxHosts list is empty" {
        InModuleScope VcfEdgeAtScale {
            $hosts    = [System.Collections.Generic.List[object]]::new()
            $passwords = @{}

            $result = Invoke-EsxPreFlightVersionCheck -AllEsxHosts $hosts -EsxPasswords $passwords
            $result | Should -BeOfType [System.Collections.Hashtable]
            $result.Count | Should -Be 0
        }
    }

    It "Returns hashtable with host marked true when version check passes" {
        InModuleScope VcfEdgeAtScale {
            $hosts = [System.Collections.Generic.List[object]]::new()
            $hosts.Add("esx1.lab.local")
            $fakeCredential = [PSCustomObject]@{ UserName = "root" }
            $passwords = @{ "esx1.lab.local" = $fakeCredential }

            function Connect-Vcenter {
                [CmdletBinding()] Param([Parameter()] [Object]$ServerName, [Parameter()] [Object]$ServerCredential, [Parameter()] [Object]$ServerType, [Parameter()] [Switch]$SkipRetryPrompt)
            }
            function Test-ESXVersion {
                [CmdletBinding()] Param([Parameter()] [Object]$ServerName, [Parameter()] [Object]$MinimumVersion)
                return @{ Success = $true; ErrorMessage = "" }
            }
            function Disconnect-Vcenter {
                [CmdletBinding()] Param([Parameter()] [Object]$ServerName, [Parameter()] [Object]$ServerType, [Parameter()] [Switch]$Silence)
            }

            $result = Invoke-EsxPreFlightVersionCheck -AllEsxHosts $hosts -EsxPasswords $passwords
            $result["esx1.lab.local"] | Should -Be $true
        }
    }

    It "Throws VcfDeploymentException and does NOT add host to result when Test-ESXVersion reports unsupported version" {
        InModuleScope VcfEdgeAtScale {
            $hosts = [System.Collections.Generic.List[object]]::new()
            $hosts.Add("esx2.lab.local")
            $fakeCredential = [PSCustomObject]@{ UserName = "root" }
            $passwords = @{ "esx2.lab.local" = $fakeCredential }

            function Connect-Vcenter {
                [CmdletBinding()] Param([Parameter()] [Object]$ServerName, [Parameter()] [Object]$ServerCredential, [Parameter()] [Object]$ServerType, [Parameter()] [Switch]$SkipRetryPrompt)
            }
            function Test-ESXVersion {
                [CmdletBinding()] Param([Parameter()] [Object]$ServerName, [Parameter()] [Object]$MinimumVersion)
                return @{ Success = $false; ErrorMessage = "ESX version 8.0.3 is below the required minimum of 9.0.0." }
            }
            function Disconnect-Vcenter {
                [CmdletBinding()] Param([Parameter()] [Object]$ServerName, [Parameter()] [Object]$ServerType, [Parameter()] [Switch]$Silence)
            }

            { Invoke-EsxPreFlightVersionCheck -AllEsxHosts $hosts -EsxPasswords $passwords } |
                Should -Throw
        }
    }
}

# ── Get-InitializationConfigFromJson ─────────────────────────────────────────


Describe "Get-InitializationConfigFromJson" {

    It "Returns correct config values and sets Script: vars when all fields present" {
        $result = InModuleScope VcfEdgeAtScale {
            function ConvertFrom-JsonSafely {
                [CmdletBinding()] Param([Parameter()] [Object]$JsonFilePath)
                return [PSCustomObject]@{
                    common   = [PSCustomObject]@{
                        vCenterName          = "vc.lab"
                        vCenterUser          = "administrator@vsphere.local"
                        labenvironment       = $true
                        esxUniquePasswordPerHost = $true
                        nonInteractivePassword   = $true
                        preserveAutoGeneratedKeyCertPair = $true
                        datacenterName       = "DC1"
                        contextName          = "ctx1"
                        clusterNamePrefix    = "edge"
                        datastoreNamePrefix  = "ds"
                        vdsNamePrefix        = "VDS"
                        supervisorNamePrefix = "sup"
                        esxUser              = "root"
                    }
                    clusters = @([PSCustomObject]@{ edgeSite = "site1" })
                }
            }
            function Update-InfrastructureJsonReferencedFilePaths {
                [CmdletBinding()] Param([Parameter()] [Object]$InfrastructureJsonPath, [Parameter()] [Object]$InputData)
            }

            Get-InitializationConfigFromJson -InfrastructureJson "/fake/infra.json"
        }
        $result.LabEnvironment                           | Should -Be $true
        $result.EsxUniquePassword                        | Should -Be $false   # inverted: esxUniquePasswordPerHost=true → EsxUniquePassword=false
        $result.NonInteractivePassword                   | Should -Be $true
        $result.PreserveAutoGeneratedKeyCertPair         | Should -Be $true
        $result.DatacenterName                           | Should -Be "DC1"
        $result.ContextName                              | Should -Be "ctx1"
        $result.ClusterNamePrefix                        | Should -Be "edge"
        $result.ClustersToProcess.Count                  | Should -Be 1
    }

    It "Returns built-in defaults when optional fields are absent from JSON" {
        $result = InModuleScope VcfEdgeAtScale {
            function ConvertFrom-JsonSafely {
                [CmdletBinding()] Param([Parameter()] [Object]$JsonFilePath)
                return [PSCustomObject]@{
                    common   = [PSCustomObject]@{
                        vCenterName = "vc.lab"
                        vCenterUser = "administrator@vsphere.local"
                        datacenterName = "DC1"
                        contextName    = "ctx1"
                    }
                    clusters = @([PSCustomObject]@{ edgeSite = "site1" })
                }
            }
            function Update-InfrastructureJsonReferencedFilePaths {
                [CmdletBinding()] Param([Parameter()] [Object]$InfrastructureJsonPath, [Parameter()] [Object]$InputData)
            }

            Get-InitializationConfigFromJson -InfrastructureJson "/fake/infra.json"
        }
        $result.LabEnvironment           | Should -Be $false
        $result.EsxUniquePassword        | Should -Be $true     # default: one password for all hosts
        $result.NonInteractivePassword   | Should -Be $false
        $result.ClusterNamePrefix        | Should -Be "cluster"
        $result.DatastoreNamePrefix      | Should -Be "datastore"
        $result.VdsNamePrefix            | Should -Be "VDS"
        $result.SupervisorNamePrefix     | Should -Be "supervisor"
        $result.EsxUser                  | Should -Be "root"
    }

    It "Throws VcfDeploymentException when JSON has no clusters" {
        {
            InModuleScope VcfEdgeAtScale {
                function ConvertFrom-JsonSafely {
                    [CmdletBinding()] Param([Parameter()] [Object]$JsonFilePath)
                    return [PSCustomObject]@{
                        common = [PSCustomObject]@{
                            vCenterName = "vc.lab"
                            vCenterUser = "administrator@vsphere.local"
                            datacenterName = "DC1"
                            contextName    = "ctx1"
                        }
                        # No clusters property
                    }
                }
                function Update-InfrastructureJsonReferencedFilePaths {
                    [CmdletBinding()] Param([Parameter()] [Object]$InfrastructureJsonPath, [Parameter()] [Object]$InputData)
                }

                Get-InitializationConfigFromJson -InfrastructureJson "/fake/infra.json"
            }
        } | Should -Throw

    }
}

# ── Invoke-VcenterConnectionAndValidation ────────────────────────────────────


Describe "Invoke-VcenterConnectionAndValidation" {

    It "Returns PSCredential and stores it via Set-ScriptVcenterCredential when env-var auth succeeds" {
        $result = InModuleScope VcfEdgeAtScale {
            function ConvertTo-SecureStringForCredential {
                [CmdletBinding()] Param([Parameter()] [Object]$PlainText)
                return (ConvertTo-SecureString -String "env-vcpass" -AsPlainText -Force)
            }
            function Connect-Vcenter {
                [CmdletBinding()] Param([Parameter()] [Object]$ServerName, [Parameter()] [Object]$ServerCredential, [Parameter()] [Object]$ServerType)
            }
            function Disconnect-Vcenter {
                [CmdletBinding()] Param([Parameter()] [Object]$ServerName, [Parameter()] [Object]$ServerType, [Parameter()] [Switch]$AllServers, [Parameter()] [Switch]$Silence)
            }
            function Test-VCenterVersion {
                [CmdletBinding()] Param([Parameter()] [Object]$MinimumVersion)
                return @{ Success = $true; ErrorMessage = "" }
            }
            function Get-VcenterSupervisorCount {
                [CmdletBinding()] Param()
                return @{ Count = 3 }
            }
            function Set-ScriptVcenterCredential {
                [CmdletBinding()] Param([Parameter()] [Object]$Credential)
            }

            $env:VCENTER_COMMON_PASSWORD = "env-vcpass"
            try {
                Invoke-VcenterConnectionAndValidation `
                    -MaximumSupervisorsPerVcenter 50 `
                    -NonInteractivePassword $true `
                    -VcenterName "vc.lab" `
                    -VcenterUser "administrator@vsphere.local"
            } finally {
                Remove-Item Env:VCENTER_COMMON_PASSWORD -ErrorAction SilentlyContinue
            }
        }
        $result | Should -BeOfType [PSCredential]
        $result.UserName | Should -Be "administrator@vsphere.local"
    }

    It "Falls back to interactive prompt and returns PSCredential when env-var auth fails with authentication error" {
        $result = InModuleScope VcfEdgeAtScale {
            $Script:_connectCalls = 0
            function ConvertTo-SecureStringForCredential {
                [CmdletBinding()] Param([Parameter()] [Object]$PlainText)
                return (ConvertTo-SecureString -String "bad-pass" -AsPlainText -Force)
            }
            function Connect-Vcenter {
                [CmdletBinding()] Param([Parameter()] [Object]$ServerName, [Parameter()] [Object]$ServerCredential, [Parameter()] [Object]$ServerType)
                $Script:_connectCalls++
                # First call (env-var attempt) throws auth error; second call (interactive) succeeds.
                if ($Script:_connectCalls -eq 1) { throw "incorrect user name or password" }
            }
            function Disconnect-Vcenter {
                [CmdletBinding()] Param([Parameter()] [Object]$ServerName, [Parameter()] [Object]$ServerType, [Parameter()] [Switch]$AllServers, [Parameter()] [Switch]$Silence)
            }
            function Get-InteractiveInput {
                [CmdletBinding()] Param([Parameter()] [Object]$PromptMessage, [Parameter()] [Switch]$AsSecureString, [Parameter()] [Switch]$AllowEmpty)
                return (ConvertTo-SecureString -String "prompt-vcpass" -AsPlainText -Force)
            }
            function Test-VCenterVersion {
                [CmdletBinding()] Param([Parameter()] [Object]$MinimumVersion)
                return @{ Success = $true; ErrorMessage = "" }
            }
            function Get-VcenterSupervisorCount {
                [CmdletBinding()] Param()
                return @{ Count = 0 }
            }
            function Set-ScriptVcenterCredential {
                [CmdletBinding()] Param([Parameter()] [Object]$Credential)
            }

            $env:VCENTER_COMMON_PASSWORD = "bad-pass"
            try {
                Invoke-VcenterConnectionAndValidation `
                    -MaximumSupervisorsPerVcenter 50 `
                    -NonInteractivePassword $true `
                    -VcenterName "vc.lab" `
                    -VcenterUser "administrator@vsphere.local"
            } finally {
                Remove-Item Env:VCENTER_COMMON_PASSWORD -ErrorAction SilentlyContinue
            }
        }
        $result | Should -BeOfType [PSCredential]
    }

    It "Throws VcfDeploymentException when supervisor count equals MaximumSupervisorsPerVcenter" {
        InModuleScope VcfEdgeAtScale {
            function ConvertTo-SecureStringForCredential {
                [CmdletBinding()] Param([Parameter()] [Object]$PlainText)
                return (ConvertTo-SecureString -String "pass" -AsPlainText -Force)
            }
            function Connect-Vcenter {
                [CmdletBinding()] Param([Parameter()] [Object]$ServerName, [Parameter()] [Object]$ServerCredential, [Parameter()] [Object]$ServerType)
            }
            function Disconnect-Vcenter {
                [CmdletBinding()] Param([Parameter()] [Object]$ServerName, [Parameter()] [Object]$ServerType, [Parameter()] [Switch]$AllServers, [Parameter()] [Switch]$Silence)
            }
            function Test-VCenterVersion {
                [CmdletBinding()] Param([Parameter()] [Object]$MinimumVersion)
                return @{ Success = $true; ErrorMessage = "" }
            }
            function Get-VcenterSupervisorCount {
                [CmdletBinding()] Param()
                return @{ Count = 10 }
            }
            function Set-ScriptVcenterCredential {
                [CmdletBinding()] Param([Parameter()] [Object]$Credential)
            }

            $env:VCENTER_COMMON_PASSWORD = "pass"
            try {
                { Invoke-VcenterConnectionAndValidation `
                    -MaximumSupervisorsPerVcenter 10 `
                    -NonInteractivePassword $true `
                    -VcenterName "vc.lab" `
                    -VcenterUser "administrator@vsphere.local"
                } | Should -Throw
            } finally {
                Remove-Item Env:VCENTER_COMMON_PASSWORD -ErrorAction SilentlyContinue
            }
        }
    }
}

Describe "Invoke-ClusterDeploymentIteration" {
    It "Returns ShouldContinue=true when Invoke-ClusterPreSupervisorPhase indicates skip" {
        $result = InModuleScope VcfEdgeAtScale {
            function Invoke-ClusterPerSiteVariables {
                [CmdletBinding()] Param([Parameter()] [Object]$Cluster, [Parameter()] [Object]$ClusterNamePrefix, [Parameter()] [Object]$DatastoreNamePrefix, [Parameter()] [Object]$InputData, [Parameter()] [Object]$SupervisorNamePrefix, [Parameter()] [Object]$VdsNamePrefix)
                return [PSCustomObject]@{ EdgeSite = "edge1"; SupervisorName = "sup-edge1"; ClusterName = "cl-edge1"; DatastoreName = "ds-edge1"; VdsName = "VDS-edge1"; EsxHosts = @("esx1.lab"); NetworkSegments = @(); ArgoCDYaml = ""; ArgoCdDeploymentYamlPath = ""; ArgocdNameSpacePrefix = "argocd"; ArgocdVmClass = "vm"; SkipArgoCDDeployment = $true; SkipHarborDeployment = $true; StoragePolicyName = "pol"; StoragePolicyTagCatalog = "cat"; StoragePolicyType = "vSAN-OSA"; EffectiveMultiHostHaPolicy = "ha"; NicList = @("nic1"); NumUplinks = 2 }
            }
            function Invoke-EsxCredentialAndDatastoreSetup {
                [CmdletBinding()] Param([Parameter()] [Object]$Context)
                return @{ DiskCanonicalName = $null; EsxUsedEnvPassword = $false }
            }
            function Invoke-ClusterCreationPhase { [CmdletBinding()] Param([Parameter()] [Object]$Cluster, [Parameter()] [Object]$ClusterName, [Parameter()] [Object]$DatacenterName, [Parameter()] [Object]$InputData, [Parameter()] [Object]$StoragePolicyType) }
            function Invoke-ClusterHostAdditionPhase { [CmdletBinding()] Param([Parameter()] [Object]$Context); begin {}; process {} }
            function Invoke-ClusterPreSupervisorPhase {
                [CmdletBinding()] Param([Parameter()] [Object]$Context)
                return @{ ShouldContinue = $true; ClusterId = $null; StoragePolicyId = $null }
            }
            Mock Write-LogMessage { }
            $fakeCluster = [PSCustomObject]@{ edgeSite = "edge1" }
            $ctx = @{ AcceptBadCheckResults = $false; Cluster = $fakeCluster; ClusterIndex = 1; ClusterNamePrefix = "cl-"; ClustersToProcessCount = 1; ComputeOnly = $false; ContextName = "ctx"; DatacenterName = "dc1"; DatastoreNamePrefix = "ds-"; DelayBeforeAddingNextHostSeconds = 0; EsxPasswords = @{}; EsxUniquePassword = $false; EsxUsedEnvPassword = $false; EsxUser = "root"; EsxVersionChecked = @{}; InfrastructureJson = "infra.json"; InputData = [PSCustomObject]@{ clusters = @($fakeCluster); common = [PSCustomObject]@{ } }; LabEnvironment = $false; PreserveAutoGeneratedKeyCertPair = $false; SaveHarborYaml = $false; SupervisorContentLibraryDatastore = ""; SupervisorContentLibraryDatastorePresent = $false; SupervisorContentLibrarySubscriptionUrl = ""; SupervisorJson = "sup.json"; SupervisorNamePrefix = "sup-"; VdsNamePrefix = "VDS-" }
            Invoke-ClusterDeploymentIteration -Context $ctx
        }
        $result.ShouldContinue | Should -Be $true
    }

    It "Returns ShouldContinue=true when a RollbackSkippedException is thrown" {
        $result = InModuleScope VcfEdgeAtScale {
            function Invoke-ClusterPerSiteVariables {
                [CmdletBinding()] Param([Parameter()] [Object]$Cluster, [Parameter()] [Object]$ClusterNamePrefix, [Parameter()] [Object]$DatastoreNamePrefix, [Parameter()] [Object]$InputData, [Parameter()] [Object]$SupervisorNamePrefix, [Parameter()] [Object]$VdsNamePrefix)
                return [PSCustomObject]@{ EdgeSite = "edge1"; SupervisorName = "sup-edge1"; ClusterName = "cl-edge1"; DatastoreName = "ds-edge1"; VdsName = "VDS-edge1"; EsxHosts = @("esx1.lab"); NetworkSegments = @(); ArgoCDYaml = ""; ArgoCdDeploymentYamlPath = ""; ArgocdNameSpacePrefix = "argocd"; ArgocdVmClass = "vm"; SkipArgoCDDeployment = $true; SkipHarborDeployment = $true; StoragePolicyName = "pol"; StoragePolicyTagCatalog = "cat"; StoragePolicyType = "vSAN-OSA"; EffectiveMultiHostHaPolicy = "ha"; NicList = @("nic1"); NumUplinks = 2 }
            }
            function Invoke-EsxCredentialAndDatastoreSetup {
                [CmdletBinding()] Param([Parameter()] [Object]$Context)
                throw [RollbackSkippedException]::new()
            }
            # Sentinel: if the generic catch fires instead of catch [RollbackSkippedException], this throws
            # and the test fails with a clear message rather than blocking on Read-Host.
            function Invoke-ComputePreSupervisorRollback {
                [CmdletBinding()] Param([Parameter()] [Object]$Context)
                throw "UNEXPECTED: generic catch fired — RollbackSkippedException was not caught by typed catch"
            }
            Mock Write-LogMessage { }
            $fakeCluster = [PSCustomObject]@{ edgeSite = "edge1" }
            $ctx = @{ AcceptBadCheckResults = $false; Cluster = $fakeCluster; ClusterIndex = 1; ClusterNamePrefix = "cl-"; ClustersToProcessCount = 1; ComputeOnly = $false; ContextName = "ctx"; DatacenterName = "dc1"; DatastoreNamePrefix = "ds-"; DelayBeforeAddingNextHostSeconds = 0; EsxPasswords = @{}; EsxUniquePassword = $false; EsxUsedEnvPassword = $false; EsxUser = "root"; EsxVersionChecked = @{}; InfrastructureJson = "infra.json"; InputData = [PSCustomObject]@{ clusters = @($fakeCluster); common = [PSCustomObject]@{ } }; LabEnvironment = $false; PreserveAutoGeneratedKeyCertPair = $false; SaveHarborYaml = $false; SupervisorContentLibraryDatastore = ""; SupervisorContentLibraryDatastorePresent = $false; SupervisorContentLibrarySubscriptionUrl = ""; SupervisorJson = "sup.json"; SupervisorNamePrefix = "sup-"; VdsNamePrefix = "VDS-" }
            Invoke-ClusterDeploymentIteration -Context $ctx
        }
        $result.ShouldContinue | Should -Be $true
    }

    It "Returns ShouldContinue=false when all phases succeed" {
        $result = InModuleScope VcfEdgeAtScale {
            function Invoke-ClusterPerSiteVariables {
                [CmdletBinding()] Param([Parameter()] [Object]$Cluster, [Parameter()] [Object]$ClusterNamePrefix, [Parameter()] [Object]$DatastoreNamePrefix, [Parameter()] [Object]$InputData, [Parameter()] [Object]$SupervisorNamePrefix, [Parameter()] [Object]$VdsNamePrefix)
                return [PSCustomObject]@{ EdgeSite = "edge1"; SupervisorName = "sup-edge1"; ClusterName = "cl-edge1"; DatastoreName = "ds-edge1"; VdsName = "VDS-edge1"; EsxHosts = @("esx1.lab"); NetworkSegments = @(); ArgoCDYaml = ""; ArgoCdDeploymentYamlPath = ""; ArgocdNameSpacePrefix = "argocd"; ArgocdVmClass = "vm"; SkipArgoCDDeployment = $true; SkipHarborDeployment = $true; StoragePolicyName = "pol"; StoragePolicyTagCatalog = "cat"; StoragePolicyType = "vSAN-OSA"; EffectiveMultiHostHaPolicy = "ha"; NicList = @("nic1"); NumUplinks = 2 }
            }
            function Invoke-EsxCredentialAndDatastoreSetup {
                [CmdletBinding()] Param([Parameter()] [Object]$Context)
                return @{ DiskCanonicalName = $null; EsxUsedEnvPassword = $false }
            }
            function Invoke-ClusterCreationPhase { [CmdletBinding()] Param([Parameter()] [Object]$Cluster, [Parameter()] [Object]$ClusterName, [Parameter()] [Object]$DatacenterName, [Parameter()] [Object]$InputData, [Parameter()] [Object]$StoragePolicyType) }
            function Invoke-ClusterHostAdditionPhase { [CmdletBinding()] Param([Parameter()] [Object]$Context); begin {}; process {} }
            function Invoke-ClusterPreSupervisorPhase {
                [CmdletBinding()] Param([Parameter()] [Object]$Context)
                return @{ ShouldContinue = $false; ClusterId = "cid1"; StoragePolicyId = "sp1" }
            }
            function Invoke-SupervisorDeploymentPhase {
                [CmdletBinding()] Param([Parameter()] [Object]$Context)
                return $false
            }
            Mock Write-LogMessage { }
            $fakeCluster = [PSCustomObject]@{ edgeSite = "edge1" }
            $ctx = @{ AcceptBadCheckResults = $false; Cluster = $fakeCluster; ClusterIndex = 1; ClusterNamePrefix = "cl-"; ClustersToProcessCount = 1; ComputeOnly = $false; ContextName = "ctx"; DatacenterName = "dc1"; DatastoreNamePrefix = "ds-"; DelayBeforeAddingNextHostSeconds = 0; EsxPasswords = @{}; EsxUniquePassword = $false; EsxUsedEnvPassword = $false; EsxUser = "root"; EsxVersionChecked = @{}; InfrastructureJson = "infra.json"; InputData = [PSCustomObject]@{ clusters = @($fakeCluster); common = [PSCustomObject]@{ } }; LabEnvironment = $false; PreserveAutoGeneratedKeyCertPair = $false; SaveHarborYaml = $false; SupervisorContentLibraryDatastore = ""; SupervisorContentLibraryDatastorePresent = $false; SupervisorContentLibrarySubscriptionUrl = ""; SupervisorJson = "sup.json"; SupervisorNamePrefix = "sup-"; VdsNamePrefix = "VDS-" }
            Invoke-ClusterDeploymentIteration -Context $ctx
        }
        $result.ShouldContinue | Should -Be $false
    }
}


Describe "Invoke-ClusterPhaseSequence" {
    It "Returns ShouldContinue=false and EsxUsedEnvPassword from ESX setup when all phases succeed" {
        $result = InModuleScope VcfEdgeAtScale {
            function Invoke-EsxCredentialAndDatastoreSetup {
                [CmdletBinding()] Param([Parameter()] [Object]$Context)
                return @{ DiskCanonicalName = "naa.abc"; EsxUsedEnvPassword = $true }
            }
            function Invoke-ClusterCreationPhase { [CmdletBinding()] Param([Parameter()] [Object]$Cluster, [Parameter()] [Object]$ClusterName, [Parameter()] [Object]$DatacenterName, [Parameter()] [Object]$InputData, [Parameter()] [Object]$StoragePolicyType) }
            function Invoke-ClusterHostAdditionPhase { [CmdletBinding()] Param([Parameter()] [Object]$Context); begin {}; process {} }
            function Invoke-ClusterPreSupervisorPhase {
                [CmdletBinding()] Param([Parameter()] [Object]$Context)
                return @{ ShouldContinue = $false; ClusterId = "cid1"; StoragePolicyId = "sp1" }
            }
            function Invoke-SupervisorDeploymentPhase {
                [CmdletBinding()] Param([Parameter()] [Object]$Context)
                return $false
            }
            Mock Write-LogMessage {}
            $fakeCluster = [PSCustomObject]@{ edgeSite = "edge1" }
            $ctx = @{ AcceptBadCheckResults = $false; Cluster = $fakeCluster; ClustersToProcessCount = 1; ComputeOnly = $false; ContextName = "ctx"; DatacenterName = "dc1"; DelayBeforeAddingNextHostSeconds = 0; EsxPasswords = @{}; EsxUniquePassword = $false; EsxUsedEnvPassword = $false; EsxUser = "root"; EsxVersionChecked = @{}; InfrastructureJson = "infra.json"; InputData = [PSCustomObject]@{}; LabEnvironment = $false; PreserveAutoGeneratedKeyCertPair = $false; SaveHarborYaml = $false; SupervisorContentLibraryDatastore = ""; SupervisorContentLibraryDatastorePresent = $false; SupervisorContentLibrarySubscriptionUrl = ""; SupervisorJson = "sup.json" }
            $siteVars = [PSCustomObject]@{ EdgeSite = "edge1"; SupervisorName = "sup-edge1"; ClusterName = "cl-edge1"; DatastoreName = "ds-edge1"; VdsName = "VDS-edge1"; EsxHosts = @("esx1.lab"); NetworkSegments = @(); ArgoCDYaml = ""; ArgoCdDeploymentYamlPath = ""; ArgocdNameSpacePrefix = "argocd"; ArgocdVmClass = "vm"; SkipArgoCDDeployment = $true; SkipHarborDeployment = $true; StoragePolicyName = "pol"; StoragePolicyTagCatalog = "cat"; StoragePolicyType = "vSAN-OSA"; EffectiveMultiHostHaPolicy = "ha"; NicList = @("nic1"); NumUplinks = 2 }
            Invoke-ClusterPhaseSequence -Context $ctx -SiteVars $siteVars
        }
        $result.ShouldContinue | Should -Be $false
        $result.EsxUsedEnvPassword | Should -Be $true
    }

    It "Returns ShouldContinue=true when Invoke-ClusterPreSupervisorPhase requests skip" {
        $result = InModuleScope VcfEdgeAtScale {
            function Invoke-EsxCredentialAndDatastoreSetup {
                [CmdletBinding()] Param([Parameter()] [Object]$Context)
                return @{ DiskCanonicalName = $null; EsxUsedEnvPassword = $false }
            }
            function Invoke-ClusterCreationPhase { [CmdletBinding()] Param([Parameter()] [Object]$Cluster, [Parameter()] [Object]$ClusterName, [Parameter()] [Object]$DatacenterName, [Parameter()] [Object]$InputData, [Parameter()] [Object]$StoragePolicyType) }
            function Invoke-ClusterHostAdditionPhase { [CmdletBinding()] Param([Parameter()] [Object]$Context); begin {}; process {} }
            function Invoke-ClusterPreSupervisorPhase {
                [CmdletBinding()] Param([Parameter()] [Object]$Context)
                return @{ ShouldContinue = $true; ClusterId = $null; StoragePolicyId = $null }
            }
            Mock Write-LogMessage {}
            $fakeCluster = [PSCustomObject]@{ edgeSite = "edge1" }
            $ctx = @{ AcceptBadCheckResults = $false; Cluster = $fakeCluster; ClustersToProcessCount = 1; ComputeOnly = $false; ContextName = "ctx"; DatacenterName = "dc1"; DelayBeforeAddingNextHostSeconds = 0; EsxPasswords = @{}; EsxUniquePassword = $false; EsxUsedEnvPassword = $false; EsxUser = "root"; EsxVersionChecked = @{}; InfrastructureJson = "infra.json"; InputData = [PSCustomObject]@{}; LabEnvironment = $false; PreserveAutoGeneratedKeyCertPair = $false; SaveHarborYaml = $false; SupervisorContentLibraryDatastore = ""; SupervisorContentLibraryDatastorePresent = $false; SupervisorContentLibrarySubscriptionUrl = ""; SupervisorJson = "sup.json" }
            $siteVars = [PSCustomObject]@{ EdgeSite = "edge1"; SupervisorName = "sup-edge1"; ClusterName = "cl-edge1"; DatastoreName = "ds-edge1"; VdsName = "VDS-edge1"; EsxHosts = @("esx1.lab"); NetworkSegments = @(); ArgoCDYaml = ""; ArgoCdDeploymentYamlPath = ""; ArgocdNameSpacePrefix = "argocd"; ArgocdVmClass = "vm"; SkipArgoCDDeployment = $true; SkipHarborDeployment = $true; StoragePolicyName = "pol"; StoragePolicyTagCatalog = "cat"; StoragePolicyType = "vSAN-OSA"; EffectiveMultiHostHaPolicy = "ha"; NicList = @("nic1"); NumUplinks = 2 }
            Invoke-ClusterPhaseSequence -Context $ctx -SiteVars $siteVars
        }
        $result.ShouldContinue | Should -Be $true
    }

    It "Returns ShouldContinue=true when Invoke-SupervisorDeploymentPhase returns true" {
        $result = InModuleScope VcfEdgeAtScale {
            function Invoke-EsxCredentialAndDatastoreSetup {
                [CmdletBinding()] Param([Parameter()] [Object]$Context)
                return @{ DiskCanonicalName = $null; EsxUsedEnvPassword = $false }
            }
            function Invoke-ClusterCreationPhase { [CmdletBinding()] Param([Parameter()] [Object]$Cluster, [Parameter()] [Object]$ClusterName, [Parameter()] [Object]$DatacenterName, [Parameter()] [Object]$InputData, [Parameter()] [Object]$StoragePolicyType) }
            function Invoke-ClusterHostAdditionPhase { [CmdletBinding()] Param([Parameter()] [Object]$Context); begin {}; process {} }
            function Invoke-ClusterPreSupervisorPhase {
                [CmdletBinding()] Param([Parameter()] [Object]$Context)
                return @{ ShouldContinue = $false; ClusterId = "cid1"; StoragePolicyId = "sp1" }
            }
            function Invoke-SupervisorDeploymentPhase {
                [CmdletBinding()] Param([Parameter()] [Object]$Context)
                return $true
            }
            Mock Write-LogMessage {}
            $fakeCluster = [PSCustomObject]@{ edgeSite = "edge1" }
            $ctx = @{ AcceptBadCheckResults = $false; Cluster = $fakeCluster; ClustersToProcessCount = 1; ComputeOnly = $false; ContextName = "ctx"; DatacenterName = "dc1"; DelayBeforeAddingNextHostSeconds = 0; EsxPasswords = @{}; EsxUniquePassword = $false; EsxUsedEnvPassword = $false; EsxUser = "root"; EsxVersionChecked = @{}; InfrastructureJson = "infra.json"; InputData = [PSCustomObject]@{}; LabEnvironment = $false; PreserveAutoGeneratedKeyCertPair = $false; SaveHarborYaml = $false; SupervisorContentLibraryDatastore = ""; SupervisorContentLibraryDatastorePresent = $false; SupervisorContentLibrarySubscriptionUrl = ""; SupervisorJson = "sup.json" }
            $siteVars = [PSCustomObject]@{ EdgeSite = "edge1"; SupervisorName = "sup-edge1"; ClusterName = "cl-edge1"; DatastoreName = "ds-edge1"; VdsName = "VDS-edge1"; EsxHosts = @("esx1.lab"); NetworkSegments = @(); ArgoCDYaml = ""; ArgoCdDeploymentYamlPath = ""; ArgocdNameSpacePrefix = "argocd"; ArgocdVmClass = "vm"; SkipArgoCDDeployment = $true; SkipHarborDeployment = $true; StoragePolicyName = "pol"; StoragePolicyTagCatalog = "cat"; StoragePolicyType = "vSAN-OSA"; EffectiveMultiHostHaPolicy = "ha"; NicList = @("nic1"); NumUplinks = 2 }
            Invoke-ClusterPhaseSequence -Context $ctx -SiteVars $siteVars
        }
        $result.ShouldContinue | Should -Be $true
    }

    It "Propagates exceptions without catching — RollbackSkippedException reaches caller" {
        { InModuleScope VcfEdgeAtScale {
            function Invoke-EsxCredentialAndDatastoreSetup {
                [CmdletBinding()] Param([Parameter()] [Object]$Context)
                throw [RollbackSkippedException]::new()
            }
            Mock Write-LogMessage {}
            $ctx = @{ Cluster = [PSCustomObject]@{}; ClustersToProcessCount = 1; ComputeOnly = $false; ContextName = "ctx"; DatacenterName = "dc1"; DelayBeforeAddingNextHostSeconds = 0; EsxPasswords = @{}; EsxUniquePassword = $false; EsxUsedEnvPassword = $false; EsxUser = "root"; EsxVersionChecked = @{}; InfrastructureJson = ""; InputData = [PSCustomObject]@{}; LabEnvironment = $false; PreserveAutoGeneratedKeyCertPair = $false; SaveHarborYaml = $false; SupervisorContentLibraryDatastore = ""; SupervisorContentLibraryDatastorePresent = $false; SupervisorContentLibrarySubscriptionUrl = ""; SupervisorJson = ""; AcceptBadCheckResults = $false }
            $siteVars = [PSCustomObject]@{ EdgeSite = "edge1"; ClusterName = "cl1"; DatastoreName = "ds1"; EsxHosts = @(); NetworkSegments = @(); ArgoCDYaml = ""; ArgoCdDeploymentYamlPath = ""; ArgocdNameSpacePrefix = "argocd"; ArgocdVmClass = "vm"; SkipArgoCDDeployment = $true; SkipHarborDeployment = $true; StoragePolicyName = "pol"; StoragePolicyTagCatalog = "cat"; StoragePolicyType = "vSAN-OSA"; EffectiveMultiHostHaPolicy = "ha"; NicList = @(); NumUplinks = 2; VdsName = "VDS-1" }
            Invoke-ClusterPhaseSequence -Context $ctx -SiteVars $siteVars
        } } | Should -Throw
    }
}

# ── Invoke-ComputePreSupervisorRollback ──────────────────────────────────────


Describe "Invoke-ComputePreSupervisorRollback" {

    It "Returns ShouldContinue = true when operator declines rollback on VMFS cluster" {
        $result = InModuleScope VcfEdgeAtScale {
            function Invoke-PauseBeforeRollbackIfRequested {
                [CmdletBinding()] Param([Parameter()] [Object]$RollbackContext, [Parameter()] [Switch]$ForcePrompt, [Parameter()] [Switch]$SingleSite)
                return "DoNotRollback"
            }
            function Get-EffectiveNicListForCluster {
                [CmdletBinding()] Param([Parameter()] [Object]$Cluster, [Parameter()] [Object]$CommonNicList)
                return @("vmnic0", "vmnic1")
            }

            $ctx = @{
                Cluster                 = [PSCustomObject]@{ vSanWitnessVmName = $null }
                ClusterName             = "cl0"
                ClustersToProcessCount  = 2
                CurrentEdgeSite         = "edge1"
                DatastoreName           = "datastore-edge1"
                EsxHosts                = @()
                InputData               = [PSCustomObject]@{ common = [PSCustomObject]@{ nicList = @("vmnic0", "vmnic1") } }
                StoragePolicyTagCatalog = "TestTagCatalog"
                StoragePolicyType       = "VMFS"
                VdsName                 = "VDS-edge1"
            }
            Invoke-ComputePreSupervisorRollback -Context $ctx
        }
        $result.ShouldContinue | Should -Be $true
    }

    It "Returns ShouldContinue = true when operator declines rollback on vSAN-ESA cluster" {
        $result = InModuleScope VcfEdgeAtScale {
            function Invoke-PauseBeforeRollbackIfRequested {
                [CmdletBinding()] Param([Parameter()] [Object]$RollbackContext, [Parameter()] [Switch]$ForcePrompt, [Parameter()] [Switch]$SingleSite)
                return "DoNotRollback"
            }
            function Get-EffectiveNicListForCluster {
                [CmdletBinding()] Param([Parameter()] [Object]$Cluster, [Parameter()] [Object]$CommonNicList)
                return @("vmnic0", "vmnic1")
            }

            $ctx = @{
                Cluster                 = [PSCustomObject]@{ vSanWitnessVmName = $null }
                ClusterName             = "cl0"
                ClustersToProcessCount  = 1
                CurrentEdgeSite         = "edge1"
                DatastoreName           = "datastore-edge1"
                EsxHosts                = @()
                InputData               = [PSCustomObject]@{ common = [PSCustomObject]@{ nicList = @("vmnic0", "vmnic1") } }
                StoragePolicyTagCatalog = "TestTagCatalog"
                StoragePolicyType       = "vSAN-ESA"
                VdsName                 = "VDS-edge1"
            }
            Invoke-ComputePreSupervisorRollback -Context $ctx
        }
        $result.ShouldContinue | Should -Be $true
    }

    It "Throws VcfDeploymentException when VMFS rollback detects an active supervisor blocking VDS removal" {
        InModuleScope VcfEdgeAtScale {
            function Invoke-PauseBeforeRollbackIfRequested {
                [CmdletBinding()] Param([Parameter()] [Object]$RollbackContext, [Parameter()] [Switch]$ForcePrompt, [Parameter()] [Switch]$SingleSite)
                return "Rollback"
            }
            function Get-EffectiveNicListForCluster {
                [CmdletBinding()] Param([Parameter()] [Object]$Cluster, [Parameter()] [Object]$CommonNicList)
                return @("vmnic0", "vmnic1")
            }
            function Remove-NonVmk0VmkernelInterfacesFromVds {
                [CmdletBinding()] Param([Parameter()] [Object]$ClusterName, [Parameter()] [Object]$VdsNames)
            }
            function Invoke-ManagementRestoreForCleanupWithTopologyFallback {
                [CmdletBinding()] Param([Parameter()] [Object]$ClusterName, [Parameter()] [Object]$NicListCount, [Parameter()] [Object]$VdsName)
                return @{ RestoreAttempted = $false; Success = $true }
            }
            function Test-SupervisorDeployedOnCluster {
                [CmdletBinding()] Param([Parameter()] [Object]$ClusterName)
                # Supervisor is still running — rollback must abort.
                return $true
            }

            $ctx = @{
                Cluster                 = [PSCustomObject]@{ vSanWitnessVmName = $null }
                ClusterName             = "cl0"
                ClustersToProcessCount  = 1
                CurrentEdgeSite         = "edge1"
                DatastoreName           = "datastore-edge1"
                EsxHosts                = @()
                InputData               = [PSCustomObject]@{ common = [PSCustomObject]@{ nicList = @("vmnic0", "vmnic1") } }
                StoragePolicyTagCatalog = $null
                StoragePolicyType       = "VMFS"
                VdsName                 = "VDS-edge1"
            }
            { Invoke-ComputePreSupervisorRollback -Context $ctx } | Should -Throw
        }
    }
}

# ── Invoke-AllSupervisorPreRemoval ────────────────────────────────────────────


Describe "Invoke-AllSupervisorPreRemoval" {

    It "Returns ShouldSkipCluster = false when supervisor ID resolves, Harbor yaml absent, and ArgoCD namespace not found" {
        InModuleScope VcfEdgeAtScale {
            $fakeClusterObject = [PSCustomObject]@{
                ExtensionData = [PSCustomObject]@{ MoRef = [PSCustomObject]@{ Value = "domain-c10" } }
            }
            $ctx = @{
                ArgoCDNamespaceDeletePollIntervalSeconds = 5
                ArgoCDNamespaceDeleteTimeoutSeconds      = 30
                ClusterName                              = "cl0-edge1"
                ClusterObjectForCleanup                  = $fakeClusterObject
                ClusterSpec                              = [PSCustomObject]@{ edgeSite = "edge1" }
                CurrentEdgeSite                          = "edge1"
                HarborServiceDeletePollIntervalSeconds   = 10
                HarborServiceDeleteTimeoutSeconds        = 60
                HarborServiceYamlPath                    = ""
                LabEnvironment                           = $false
                SupervisorNamePrefix                     = "sup"
            }
            function Get-SupervisorNameFromPrefix {
                [CmdletBinding()] Param([Parameter()] [Object]$SupervisorNamePrefix, [Parameter()] [Object]$EdgeSite)
                return "sup-edge1"
            }
            function Get-SupervisorId {
                [CmdletBinding()] Param([Parameter()] [Object]$supervisorName, [Parameter()] [Object]$VcenterUser, [Parameter()] [Object]$VcenterCredential)
                return "supervisor-id-abc"
            }
            function Get-ArgoCDNamespaceFromCluster {
                [CmdletBinding()] Param([Parameter()] [Object]$ClusterObject, [Parameter()] [Object]$ClusterSpec)
                return "argocd-edge1"
            }
            function Invoke-ListNamespacesInstances {
                [CmdletBinding()] Param()
                return [PSCustomObject]@{ Namespace = @("other-ns") }
            }
            function Disable-SupervisorOnCluster {
                [CmdletBinding()] Param([Parameter()] [Object]$ClusterId, [Parameter()] [Object]$ClusterName, [Parameter()] [Switch]$SuppressConfirm)
                return @{ Success = $true; ErrorMessage = "" }
            }

            $result = Invoke-AllSupervisorPreRemoval -Context $ctx
            $result.ShouldSkipCluster | Should -Be $false
        }
    }

    It "Returns ShouldSkipCluster = false when Get-SupervisorId throws but Disable-SupervisorOnCluster succeeds" {
        InModuleScope VcfEdgeAtScale {
            $fakeClusterObject = [PSCustomObject]@{
                ExtensionData = [PSCustomObject]@{ MoRef = [PSCustomObject]@{ Value = "domain-c11" } }
            }
            $ctx = @{
                ArgoCDNamespaceDeletePollIntervalSeconds = 5
                ArgoCDNamespaceDeleteTimeoutSeconds      = 30
                ClusterName                              = "cl0-edge1"
                ClusterObjectForCleanup                  = $fakeClusterObject
                ClusterSpec                              = [PSCustomObject]@{ edgeSite = "edge1" }
                CurrentEdgeSite                          = "edge1"
                HarborServiceDeletePollIntervalSeconds   = 10
                HarborServiceDeleteTimeoutSeconds        = 60
                HarborServiceYamlPath                    = ""
                LabEnvironment                           = $false
                SupervisorNamePrefix                     = "sup"
            }
            function Get-SupervisorNameFromPrefix {
                [CmdletBinding()] Param([Parameter()] [Object]$SupervisorNamePrefix, [Parameter()] [Object]$EdgeSite)
                return "sup-edge1"
            }
            function Get-SupervisorId {
                [CmdletBinding()] Param([Parameter()] [Object]$supervisorName, [Parameter()] [Object]$VcenterUser, [Parameter()] [Object]$VcenterCredential)
                throw "Supervisor unreachable"
            }
            function Disable-SupervisorOnCluster {
                [CmdletBinding()] Param([Parameter()] [Object]$ClusterId, [Parameter()] [Object]$ClusterName, [Parameter()] [Switch]$SuppressConfirm)
                return @{ Success = $true; ErrorMessage = "" }
            }

            $result = Invoke-AllSupervisorPreRemoval -Context $ctx
            $result.ShouldSkipCluster | Should -Be $false
        }
    }

    It "Returns ShouldSkipCluster = true when Disable-SupervisorOnCluster reports failure" {
        InModuleScope VcfEdgeAtScale {
            $fakeClusterObject = [PSCustomObject]@{
                ExtensionData = [PSCustomObject]@{ MoRef = [PSCustomObject]@{ Value = "domain-c12" } }
            }
            $ctx = @{
                ArgoCDNamespaceDeletePollIntervalSeconds = 5
                ArgoCDNamespaceDeleteTimeoutSeconds      = 30
                ClusterName                              = "cl0-edge1"
                ClusterObjectForCleanup                  = $fakeClusterObject
                ClusterSpec                              = [PSCustomObject]@{ edgeSite = "edge1" }
                CurrentEdgeSite                          = "edge1"
                HarborServiceDeletePollIntervalSeconds   = 10
                HarborServiceDeleteTimeoutSeconds        = 60
                HarborServiceYamlPath                    = ""
                LabEnvironment                           = $false
                SupervisorNamePrefix                     = "sup"
            }
            function Get-SupervisorNameFromPrefix {
                [CmdletBinding()] Param([Parameter()] [Object]$SupervisorNamePrefix, [Parameter()] [Object]$EdgeSite)
                return "sup-edge1"
            }
            function Get-SupervisorId {
                [CmdletBinding()] Param([Parameter()] [Object]$supervisorName, [Parameter()] [Object]$VcenterUser, [Parameter()] [Object]$VcenterCredential)
                return "supervisor-id-xyz"
            }
            function Get-ArgoCDNamespaceFromCluster {
                [CmdletBinding()] Param([Parameter()] [Object]$ClusterObject, [Parameter()] [Object]$ClusterSpec)
                return "argocd-edge1"
            }
            function Invoke-ListNamespacesInstances {
                [CmdletBinding()] Param()
                return [PSCustomObject]@{ Namespace = @() }
            }
            function Disable-SupervisorOnCluster {
                [CmdletBinding()] Param([Parameter()] [Object]$ClusterId, [Parameter()] [Object]$ClusterName, [Parameter()] [Switch]$SuppressConfirm)
                return @{ Success = $false; ErrorMessage = "Deactivation timed out." }
            }

            $result = Invoke-AllSupervisorPreRemoval -Context $ctx
            $result.ShouldSkipCluster | Should -Be $true
        }
    }
}

# ── Get-ClusterCleanupState ──────────────────────────────────────────────────


Describe "Get-ClusterCleanupState" {

    It "Returns SupervisorEnabled=false when no WCP cluster entry matches" {
        InModuleScope VcfEdgeAtScale {
            $Script:vCenterName = $null
            $fakeCluster = [PSCustomObject]@{
                edgeSite      = "site1"
                storagePolicy = [PSCustomObject]@{ storageType = "VMFS"; storagePolicyTagCatalog = "" }
            }
            Mock Get-ClusterNameFromPrefix { return "cl-site1" }
            Mock Get-ClusterByName { [PSCustomObject]@{ Name = "cl-site1" } }
            Mock Invoke-ListNamespaceManagementClusters { @() }
            $result = Get-ClusterCleanupState -Cluster $fakeCluster -CleanUpScope "All" -ClusterNamePrefix "cl" -DatastoreNamePrefix "ds"
            $result.SupervisorEnabled | Should -Be $false
            $result.ClusterName | Should -Be "cl-site1"
            $result.StoragePolicyType | Should -Be "VMFS"
        }
    }

    It "Returns SupervisorEnabled=true when WCP cluster entry has RUNNING/READY status" {
        InModuleScope VcfEdgeAtScale {
            $Script:vCenterName = $null
            $fakeCluster = [PSCustomObject]@{
                edgeSite      = "site2"
                storagePolicy = [PSCustomObject]@{ storageType = "vSAN-ESA"; storagePolicyTagCatalog = "" }
            }
            Mock Get-ClusterNameFromPrefix { return "cl-site2" }
            Mock Get-ClusterByName { [PSCustomObject]@{ Name = "cl-site2" } }
            Mock Invoke-ListNamespaceManagementClusters {
                @([PSCustomObject]@{ clusterName = "cl-site2"; ConfigStatus = "RUNNING"; KubernetesStatus = "READY" })
            }
            $result = Get-ClusterCleanupState -Cluster $fakeCluster -CleanUpScope "All" -ClusterNamePrefix "cl" -DatastoreNamePrefix "ds"
            $result.SupervisorEnabled | Should -Be $true
            $result.StoragePolicyType | Should -Be "vSAN-ESA"
        }
    }

    It "Throws VcfDeploymentException when Compute scope requested but supervisor is enabled" {
        InModuleScope VcfEdgeAtScale {
            $Script:vCenterName = $null
            $fakeCluster = [PSCustomObject]@{
                edgeSite      = "site1"
                storagePolicy = [PSCustomObject]@{ storageType = "VMFS"; storagePolicyTagCatalog = "" }
            }
            Mock Get-ClusterNameFromPrefix { return "cl-site1" }
            Mock Get-ClusterByName { [PSCustomObject]@{ Name = "cl-site1" } }
            Mock Invoke-ListNamespaceManagementClusters {
                @([PSCustomObject]@{ clusterName = "cl-site1"; ConfigStatus = "RUNNING"; KubernetesStatus = "READY" })
            }
            { Get-ClusterCleanupState -Cluster $fakeCluster -CleanUpScope "Compute" -ClusterNamePrefix "cl" -DatastoreNamePrefix "ds" } |
                Should -Throw
        }
    }
}

# ── Invoke-NamedServiceScopedCleanup ─────────────────────────────────────────


Describe "Invoke-NamedServiceScopedCleanup" {

    It "Returns Handled=true HadErrors=false for Supervisor scope when supervisor not enabled" {
        InModuleScope VcfEdgeAtScale {
            $ctx = @{
                ArgoCDNamespaceDeletePollIntervalSeconds = 5
                ArgoCDNamespaceDeleteTimeoutSeconds      = 120
                CleanUpScope                             = "Supervisor"
                HarborServiceDeletePollIntervalSeconds   = 10
                HarborServiceDeleteTimeoutSeconds        = 180
                LabEnvironment                           = $false
                SupervisorNamePrefix                     = "sup"
            }
            $state = [PSCustomObject]@{ ClusterName = "cl-s1"; CurrentEdgeSite = "s1"; ClusterObject = $null; SupervisorEnabled = $false }
            $clusterSpec = [PSCustomObject]@{ edgeSite = "s1" }
            $result = Invoke-NamedServiceScopedCleanup -Context $ctx -CleanupState $state -ClusterSpec $clusterSpec
            $result.Handled | Should -Be $true
            $result.HadErrors | Should -Be $false
        }
    }

    It "Returns Handled=true HadErrors=false for ArgoCD scope when cluster object is null (warning path)" {
        InModuleScope VcfEdgeAtScale {
            $ctx = @{
                ArgoCDNamespaceDeletePollIntervalSeconds = 5
                ArgoCDNamespaceDeleteTimeoutSeconds      = 120
                CleanUpScope                             = "ArgoCD"
                HarborServiceDeletePollIntervalSeconds   = 10
                HarborServiceDeleteTimeoutSeconds        = 180
                LabEnvironment                           = $false
                SupervisorNamePrefix                     = "sup"
            }
            $state = [PSCustomObject]@{ ClusterName = "cl-s1"; CurrentEdgeSite = "s1"; ClusterObject = $null; SupervisorEnabled = $false }
            $clusterSpec = [PSCustomObject]@{ edgeSite = "s1" }
            $result = Invoke-NamedServiceScopedCleanup -Context $ctx -CleanupState $state -ClusterSpec $clusterSpec
            $result.Handled | Should -Be $true
            $result.HadErrors | Should -Be $false
        }
    }

    It "Returns Handled=true with HadErrors from ArgoCD helper when cluster exists" {
        InModuleScope VcfEdgeAtScale {
            $ctx = @{
                ArgoCDNamespaceDeletePollIntervalSeconds = 5
                ArgoCDNamespaceDeleteTimeoutSeconds      = 120
                CleanUpScope                             = "ArgoCD"
                HarborServiceDeletePollIntervalSeconds   = 10
                HarborServiceDeleteTimeoutSeconds        = 180
                LabEnvironment                           = $false
                SupervisorNamePrefix                     = "sup"
            }
            $fakeClusterObj = [PSCustomObject]@{ Name = "cl-s1" }
            $state = [PSCustomObject]@{ ClusterName = "cl-s1"; CurrentEdgeSite = "s1"; ClusterObject = $fakeClusterObj; SupervisorEnabled = $false }
            $clusterSpec = [PSCustomObject]@{ edgeSite = "s1" }
            Mock Invoke-ArgoCDNamespaceCleanupForCluster { @{ HadErrors = $true } }
            $result = Invoke-NamedServiceScopedCleanup -Context $ctx -CleanupState $state -ClusterSpec $clusterSpec
            $result.Handled | Should -Be $true
            $result.HadErrors | Should -Be $true
        }
    }

    It "Returns Handled=false for Compute scope (not a named service)" {
        InModuleScope VcfEdgeAtScale {
            $ctx = @{
                ArgoCDNamespaceDeletePollIntervalSeconds = 5
                ArgoCDNamespaceDeleteTimeoutSeconds      = 120
                CleanUpScope                             = "Compute"
                HarborServiceDeletePollIntervalSeconds   = 10
                HarborServiceDeleteTimeoutSeconds        = 180
                LabEnvironment                           = $false
                SupervisorNamePrefix                     = "sup"
            }
            $state = [PSCustomObject]@{ ClusterName = "cl-s1"; CurrentEdgeSite = "s1"; ClusterObject = $null; SupervisorEnabled = $false }
            $clusterSpec = [PSCustomObject]@{ edgeSite = "s1" }
            $result = Invoke-NamedServiceScopedCleanup -Context $ctx -CleanupState $state -ClusterSpec $clusterSpec
            $result.Handled | Should -Be $false
        }
    }

    It "Returns Handled=true HadErrors=false for Harbor scope when cluster object is null (warning path)" {
        InModuleScope VcfEdgeAtScale {
            $ctx = @{
                ArgoCDNamespaceDeletePollIntervalSeconds = 5
                ArgoCDNamespaceDeleteTimeoutSeconds      = 120
                CleanUpScope                             = "Harbor"
                HarborServiceDeletePollIntervalSeconds   = 10
                HarborServiceDeleteTimeoutSeconds        = 180
                HarborServiceYamlPath                    = ""
                LabEnvironment                           = $false
                SupervisorNamePrefix                     = "sup"
            }
            $state = [PSCustomObject]@{ ClusterName = "cl-s1"; CurrentEdgeSite = "s1"; ClusterObject = $null; SupervisorEnabled = $false }
            $clusterSpec = [PSCustomObject]@{ edgeSite = "s1" }
            $result = Invoke-NamedServiceScopedCleanup -Context $ctx -CleanupState $state -ClusterSpec $clusterSpec
            $result.Handled | Should -Be $true
            $result.HadErrors | Should -Be $false
        }
    }

    It "Returns Handled=true with HadErrors from Harbor helper when cluster exists" {
        InModuleScope VcfEdgeAtScale {
            $ctx = @{
                ArgoCDNamespaceDeletePollIntervalSeconds = 5
                ArgoCDNamespaceDeleteTimeoutSeconds      = 120
                CleanUpScope                             = "Harbor"
                HarborServiceDeletePollIntervalSeconds   = 10
                HarborServiceDeleteTimeoutSeconds        = 180
                HarborServiceYamlPath                    = ""
                LabEnvironment                           = $false
                SupervisorNamePrefix                     = "sup"
            }
            $fakeClusterObj = [PSCustomObject]@{ Name = "cl-s1" }
            $state = [PSCustomObject]@{ ClusterName = "cl-s1"; CurrentEdgeSite = "s1"; ClusterObject = $fakeClusterObj; SupervisorEnabled = $false }
            $clusterSpec = [PSCustomObject]@{ edgeSite = "s1" }
            Mock Invoke-HarborServiceCleanupForCluster { @{ HadErrors = $true } }
            $result = Invoke-NamedServiceScopedCleanup -Context $ctx -CleanupState $state -ClusterSpec $clusterSpec
            $result.Handled | Should -Be $true
            $result.HadErrors | Should -Be $true
        }
    }
}

# ── Invoke-ComputeCleanupForCluster ──────────────────────────────────────────


Describe "Invoke-ComputeCleanupForCluster" {

    It "Returns HadErrors=false without calling rollback when All-scope pre-removal signals ShouldSkipCluster" {
        InModuleScope VcfEdgeAtScale {
            $ctx = @{
                ArgoCDNamespaceDeletePollIntervalSeconds = 5
                ArgoCDNamespaceDeleteTimeoutSeconds      = 120
                CleanUpScope                             = "All"
                ClusterExistenceCheckDelaySeconds        = 2
                ClusterExistenceCheckRetryDelaySeconds   = 10
                DatastoreNamePrefix                      = "ds"
                HarborServiceDeletePollIntervalSeconds   = 10
                HarborServiceDeleteTimeoutSeconds        = 180
                HarborServiceYamlPath                    = ""
                InputData                                = [PSCustomObject]@{}
                LabEnvironment                           = $false
                SupervisorNamePrefix                     = "sup"
                VdsNamePrefix                            = "VDS"
            }
            $fakeObj = [PSCustomObject]@{ Name = "cl-s1" }
            $state = [PSCustomObject]@{
                ClusterName = "cl-s1"; CurrentEdgeSite = "s1"; ClusterObject = $fakeObj
                SupervisorEnabled = $true; StoragePolicyType = "VMFS"; StoragePolicyTagCatalog = "VMFS-TagCatalog"
            }
            $clusterSpec = [PSCustomObject]@{ edgeSite = "s1" }
            Mock Invoke-AllSupervisorPreRemoval { @{ ShouldSkipCluster = $true } }
            function Invoke-ClusterRollbackPhase {
                [CmdletBinding()] Param([Parameter()] [Object]$ClusterName)
                process { throw "Invoke-ClusterRollbackPhase must not be called when ShouldSkipCluster" }
            }
            $result = Invoke-ComputeCleanupForCluster -Context $ctx -CleanupState $state -ClusterSpec $clusterSpec
            $result.HadErrors | Should -Be $false
        }
    }

    It "Returns HadErrors=false and logs debug when storage type is not a known type" {
        InModuleScope VcfEdgeAtScale {
            $ctx = @{
                ArgoCDNamespaceDeletePollIntervalSeconds = 5
                ArgoCDNamespaceDeleteTimeoutSeconds      = 120
                CleanUpScope                             = "Compute"
                ClusterExistenceCheckDelaySeconds        = 2
                ClusterExistenceCheckRetryDelaySeconds   = 10
                DatastoreNamePrefix                      = "ds"
                HarborServiceDeletePollIntervalSeconds   = 10
                HarborServiceDeleteTimeoutSeconds        = 180
                HarborServiceYamlPath                    = ""
                InputData                                = [PSCustomObject]@{}
                LabEnvironment                           = $false
                SupervisorNamePrefix                     = "sup"
                VdsNamePrefix                            = "VDS"
            }
            $state = [PSCustomObject]@{
                ClusterName = "cl-s1"; CurrentEdgeSite = "s1"; ClusterObject = $null
                SupervisorEnabled = $false; StoragePolicyType = "UnknownType"; StoragePolicyTagCatalog = ""
            }
            $clusterSpec = [PSCustomObject]@{ edgeSite = "s1" }
            function Invoke-ClusterRollbackPhase {
                [CmdletBinding()] Param([Parameter()] [Object]$ClusterName)
                process { throw "Invoke-ClusterRollbackPhase must not be called for unknown storage type" }
            }
            $result = Invoke-ComputeCleanupForCluster -Context $ctx -CleanupState $state -ClusterSpec $clusterSpec
            $result.HadErrors | Should -Be $false
        }
    }

    It "Returns HadErrors=true when Invoke-ClusterRollbackPhase returns true" {
        InModuleScope VcfEdgeAtScale {
            $ctx = @{
                ArgoCDNamespaceDeletePollIntervalSeconds = 5
                ArgoCDNamespaceDeleteTimeoutSeconds      = 120
                CleanUpScope                             = "Compute"
                ClusterExistenceCheckDelaySeconds        = 2
                ClusterExistenceCheckRetryDelaySeconds   = 10
                DatastoreNamePrefix                      = "ds"
                HarborServiceDeletePollIntervalSeconds   = 10
                HarborServiceDeleteTimeoutSeconds        = 180
                HarborServiceYamlPath                    = ""
                InputData                                = [PSCustomObject]@{}
                LabEnvironment                           = $false
                SupervisorNamePrefix                     = "sup"
                VdsNamePrefix                            = "VDS"
            }
            $state = [PSCustomObject]@{
                ClusterName = "cl-s1"; CurrentEdgeSite = "s1"; ClusterObject = $null
                SupervisorEnabled = $false; StoragePolicyType = "VMFS"; StoragePolicyTagCatalog = "VMFS-TagCatalog"
            }
            $clusterSpec = [PSCustomObject]@{ edgeSite = "s1" }
            Mock Invoke-ClusterRollbackPhase { return $true }
            $result = Invoke-ComputeCleanupForCluster -Context $ctx -CleanupState $state -ClusterSpec $clusterSpec
            $result.HadErrors | Should -Be $true
        }
    }
}

# ── Invoke-ClusterScopedCleanup ──────────────────────────────────────────────


Describe "Invoke-ClusterScopedCleanup" {

    It "Returns named-service result immediately when Invoke-NamedServiceScopedCleanup reports Handled=true" {
        InModuleScope VcfEdgeAtScale {
            $ctx = @{ CleanUpScope = "Supervisor"; DatastoreNamePrefix = "ds"; ForceBypassPrompt = $true; VdsNamePrefix = "VDS" }
            $state = [PSCustomObject]@{ ClusterName = "cl-s1"; CurrentEdgeSite = "s1"; ClusterObject = $null; SupervisorEnabled = $false }
            $clusterSpec = [PSCustomObject]@{ edgeSite = "s1" }
            # VDS-existence guard: ClusterObject=null and SupervisorEnabled=false triggers a Get-VDSwitch lookup.
            # Return a non-null object so the guard is satisfied and execution reaches the dispatch logic under test.
            Mock Get-VdsNameFromPrefix { return "VDS-s1" }
            function Get-VDSwitch {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process { return [PSCustomObject]@{ Name = $Name } }
            }
            Mock Get-DatastoreNameFromPrefix { return "ds-s1" }
            Mock Confirm-CleanupForCluster { }
            Mock Invoke-NamedServiceScopedCleanup { [PSCustomObject]@{ Handled = $true; HadErrors = $false } }
            function Invoke-ComputeCleanupForCluster {
                [CmdletBinding()] Param([Parameter()] [Object]$Context, [Parameter()] [Object]$CleanupState, [Parameter()] [Object]$ClusterSpec)
                process { throw "Invoke-ComputeCleanupForCluster must not be called when named service handled the scope" }
            }
            $result = Invoke-ClusterScopedCleanup -Context $ctx -CleanupState $state -ClusterSpec $clusterSpec
            $result.Handled | Should -Be $true
        }
    }

    It "Delegates to Invoke-ComputeCleanupForCluster when named service returns Handled=false" {
        InModuleScope VcfEdgeAtScale {
            $ctx = @{ CleanUpScope = "Compute"; DatastoreNamePrefix = "ds"; ForceBypassPrompt = $true; VdsNamePrefix = "VDS" }
            $state = [PSCustomObject]@{ ClusterName = "cl-s1"; CurrentEdgeSite = "s1"; ClusterObject = $null; SupervisorEnabled = $false }
            $clusterSpec = [PSCustomObject]@{ edgeSite = "s1" }
            Mock Get-VdsNameFromPrefix { return "VDS-s1" }
            function Get-VDSwitch {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process { return [PSCustomObject]@{ Name = $Name } }
            }
            Mock Get-DatastoreNameFromPrefix { return "ds-s1" }
            Mock Confirm-CleanupForCluster { }
            Mock Invoke-NamedServiceScopedCleanup { [PSCustomObject]@{ Handled = $false; HadErrors = $false } }
            Mock Invoke-ComputeCleanupForCluster { [PSCustomObject]@{ HadErrors = $false } }
            $result = Invoke-ClusterScopedCleanup -Context $ctx -CleanupState $state -ClusterSpec $clusterSpec
            $result.HadErrors | Should -Be $false
            Should -Invoke Invoke-ComputeCleanupForCluster -Times 1
        }
    }

    It "Calls Confirm-CleanupForCluster before dispatching" {
        InModuleScope VcfEdgeAtScale {
            $ctx = @{ CleanUpScope = "Harbor"; DatastoreNamePrefix = "ds"; ForceBypassPrompt = $false; LabEnvironment = $false; VdsNamePrefix = "VDS" }
            $state = [PSCustomObject]@{ ClusterName = "cl-s1"; CurrentEdgeSite = "s1"; ClusterObject = $null; SupervisorEnabled = $false }
            $clusterSpec = [PSCustomObject]@{ edgeSite = "s1" }
            Mock Get-VdsNameFromPrefix { return "VDS-s1" }
            function Get-VDSwitch {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process { return [PSCustomObject]@{ Name = $Name } }
            }
            Mock Get-DatastoreNameFromPrefix { return "ds-s1" }
            Mock Confirm-CleanupForCluster { }
            Mock Invoke-NamedServiceScopedCleanup { [PSCustomObject]@{ Handled = $true; HadErrors = $false } }
            $null = Invoke-ClusterScopedCleanup -Context $ctx -CleanupState $state -ClusterSpec $clusterSpec
            Should -Invoke Confirm-CleanupForCluster -Times 1
        }
    }

    It "Skips confirmation and returns HadErrors=false when cluster, supervisor, and all VDS candidates are absent" {
        # Regression guard: when an operator runs cleanup on an already-torn-down edge site, the
        # pre-flight check must detect that nothing exists and return immediately — no confirmation
        # prompt, no wasted operator time.
        InModuleScope VcfEdgeAtScale {
            function Get-VDSwitch {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process { return $null }
            }
            $ctx = @{
                CleanUpScope    = "All"
                DatastoreNamePrefix = "ds"
                ForceBypassPrompt   = $false
                VdsNamePrefix       = "VDS"
            }
            $state = [PSCustomObject]@{
                ClusterName     = "cluster-vsan-edge1"
                CurrentEdgeSite = "vsan-edge1"
                ClusterObject   = $null
                SupervisorEnabled = $false
            }
            $clusterSpec = [PSCustomObject]@{ edgeSite = "vsan-edge1" }
            Mock Get-VdsNameFromPrefix { return "VDS-vsan-edge1" }
            Mock Write-LogMessage {}
            function Confirm-CleanupForCluster {
                throw "Confirm-CleanupForCluster must not be called when nothing exists"
            }
            $result = Invoke-ClusterScopedCleanup -Context $ctx -CleanupState $state -ClusterSpec $clusterSpec
            $result.HadErrors | Should -Be $false
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "INFO" -and $Message -match "already cleaned up or never deployed" }
        }
    }
}

# ── Invoke-VcfEdgeAtScaleCleanup — control flow ───────────────────────────────


Describe "Invoke-VcfEdgeAtScaleCleanup" {

    It "Throws when Compute cleanup is requested but Supervisor is still enabled on a cluster" {
        InModuleScope VcfEdgeAtScale {
            $fakeCluster = [PSCustomObject]@{
                edgeSite      = "site1"
                storagePolicy = [PSCustomObject]@{ storageType = "VMFS"; storagePolicyTagCatalog = "" }
            }
            $fakeInputData = [PSCustomObject]@{
                common = [PSCustomObject]@{ nicList = @() }
            }
            # Set vCenterName to $null to avoid -Server [VIServer[]] type binding on Get-Cluster mock.
            $Script:vCenterName = $null
            Mock Get-ClusterNameFromPrefix { return "cl0-site1" }
            Mock Get-ClusterByName { [PSCustomObject]@{ Name = "cl0-site1" } }
            Mock Invoke-ListNamespaceManagementClusters {
                @([PSCustomObject]@{ clusterName = "cl0-site1"; ConfigStatus = "RUNNING"; KubernetesStatus = "READY" })
            }
            {
                Invoke-VcfEdgeAtScaleCleanup -CleanUp "Compute" -ClusterNamePrefix "cl" `
                    -ClustersToProcess @($fakeCluster) -DatastoreNamePrefix "ds" `
                    -InputData $fakeInputData -LabEnvironment $false -SupervisorNamePrefix "sup" `
                    -VdsNamePrefix "VDS"
            } | Should -Throw

        }
    }

    It "Throws when cleanupHadErrors is set (cluster still exists after removal attempt)" {
        InModuleScope VcfEdgeAtScale {
            $fakeCluster = [PSCustomObject]@{
                edgeSite      = "site1"
                storagePolicy = [PSCustomObject]@{ storageType = "VMFS"; storagePolicyTagCatalog = "" }
            }
            $fakeInputData = [PSCustomObject]@{ common = [PSCustomObject]@{ nicList = @() } }
            $Script:vCenterName = $null
            Mock Get-ClusterNameFromPrefix { return "cl0-site1" }
            # Cluster exists but Supervisor is disabled → Compute cleanup proceeds.
            Mock Get-ClusterByName { [PSCustomObject]@{ Name = "cl0-site1" } }
            Mock Invoke-ListNamespaceManagementClusters {
                @([PSCustomObject]@{ clusterName = "cl0-site1"; ConfigStatus = "DISABLED"; KubernetesStatus = "NOT_INSTALLED" })
            }
            # Prompt → bypass by mocking Read-Host to return "y".
            Mock Read-Host { return "y" }
            # Stub inner cleanup functions.
            Mock Remove-NonVmk0VmkernelInterfacesFromVds { }
            Mock Invoke-ManagementRestoreForCleanupWithTopologyFallback { }
            Mock Remove-EdgeClusterDistributedSwitch { }
            Mock Remove-VsanDiskClaimsFromHost { }
            Mock Remove-VmfsDatastoreForCluster { }
            Mock Invoke-VsanDeploymentRollback { }
            Mock Remove-ClusterSafely { throw "Removal failed." }
            Mock Start-Sleep { }
            # Cluster still exists after removal attempt.
            $Script:_cleanupCheckCount = 0
            Mock Get-ClusterByName -ParameterFilter { $Name -eq "cl0-site1" } {
                $Script:_cleanupCheckCount++
                [PSCustomObject]@{ Name = "cl0-site1" }
            }
            {
                Invoke-VcfEdgeAtScaleCleanup -CleanUp "Compute" -ClusterNamePrefix "cl" `
                    -ClustersToProcess @($fakeCluster) -DatastoreNamePrefix "ds" `
                    -InputData $fakeInputData -LabEnvironment $true -Force `
                    -SupervisorNamePrefix "sup" -VdsNamePrefix "VDS"
            } | Should -Throw

        }
    }

    It "-CleanUp Supervisor calls Harbor removal before ArgoCD before supervisor (enforced call ordering)" {
        # Tests that Invoke-NamedServiceScopedCleanup for Supervisor scope calls the three teardown
        # helpers in the correct order: Harbor first (PVCs gone before storage), ArgoCD second, supervisor last.
        $callOrder = InModuleScope VcfEdgeAtScale {
            $Script:_cleanupCallOrder = [System.Collections.Generic.List[String]]::new()
            Mock Write-LogMessage {}
            function Get-EffectiveClusterName {
                [CmdletBinding()] Param([Parameter()] [Object]$Cluster, [Parameter()] [Object]$ClusterNamePrefix, [Parameter()] [Object]$EdgeSite)
                return "cl0-site1"
            }
            function Get-ArgoCDNamespaceFromCluster {
                [CmdletBinding()] Param([Parameter()] [Object]$ClusterObject, [Parameter()] [Object]$ClusterSpec)
                return "argocd-edge1"
            }
            function Get-SupervisorNameFromPrefix {
                [CmdletBinding()] Param([Parameter()] [Object]$SupervisorNamePrefix, [Parameter()] [Object]$EdgeSite)
                return "sup-site1"
            }
            Mock Invoke-HarborServiceCleanupForCluster {
                $Script:_cleanupCallOrder.Add("Harbor") | Out-Null
                [PSCustomObject]@{ HadErrors = $false }
            }
            Mock Invoke-ArgoCDNamespaceCleanupForCluster {
                $Script:_cleanupCallOrder.Add("ArgoCD") | Out-Null
                [PSCustomObject]@{ HadErrors = $false }
            }
            Mock Disable-SupervisorOnCluster {
                $Script:_cleanupCallOrder.Add("Supervisor") | Out-Null
                [PSCustomObject]@{ Success = $true; ErrorMessage = "" }
            }
            $ctx = @{
                CleanUpScope                             = "Supervisor"
                ArgoCDNamespaceDeletePollIntervalSeconds = 5
                ArgoCDNamespaceDeleteTimeoutSeconds      = 30
                HarborServiceDeletePollIntervalSeconds   = 10
                HarborServiceDeleteTimeoutSeconds        = 60
                HarborServiceYamlPath                    = ""
                LabEnvironment                           = $false
                SupervisorNamePrefix                     = "sup"
            }
            $fakeClusterObj = [PSCustomObject]@{ Name = "cl0-site1"; ExtensionData = [PSCustomObject]@{ MoRef = [PSCustomObject]@{ Value = "domain-c8" } } }
            $cleanupState = [PSCustomObject]@{
                ClusterName      = "cl0-site1"
                ClusterObject    = $fakeClusterObj
                CurrentEdgeSite  = "site1"
                SupervisorEnabled = $true
            }
            $clusterSpec = [PSCustomObject]@{ edgeSite = "site1" }
            Invoke-NamedServiceScopedCleanup -Context $ctx -CleanupState $cleanupState -ClusterSpec $clusterSpec | Out-Null
            $Script:_cleanupCallOrder
        }
        $callOrder[0] | Should -Be "Harbor"
        $callOrder[1] | Should -Be "ArgoCD"
        $callOrder[2] | Should -Be "Supervisor"
    }

    It "-CleanUp Supervisor scope on a cluster with no supervisor skips Harbor and ArgoCD removal" {
        # When SupervisorEnabled = $false, service removal steps must be completely bypassed.
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            function Invoke-HarborServiceCleanupForCluster {
                [CmdletBinding()] Param(
                    [Parameter()] [Object]$ClusterName, [Parameter()] [Object]$CurrentEdgeSite,
                    [Parameter()] [Object]$HarborServiceDeletePollIntervalSeconds, [Parameter()] [Object]$HarborServiceDeleteTimeoutSeconds,
                    [Parameter()] [Object]$HarborServiceYamlPath, [Parameter()] [Object]$LabEnvironment, [Parameter()] [Object]$SupervisorNamePrefix
                )
                throw "Invoke-HarborServiceCleanupForCluster must not be called when supervisor is disabled"
            }
            function Invoke-ArgoCDNamespaceCleanupForCluster {
                [CmdletBinding()] Param(
                    [Parameter()] [Object]$ArgoCDNamespaceDeletePollIntervalSeconds, [Parameter()] [Object]$ArgoCDNamespaceDeleteTimeoutSeconds,
                    [Parameter()] [Object]$ClusterName, [Parameter()] [Object]$ClusterObject, [Parameter()] [Object]$ClusterSpec, [Parameter()] [Object]$CurrentEdgeSite
                )
                throw "Invoke-ArgoCDNamespaceCleanupForCluster must not be called when supervisor is disabled"
            }
            $ctx = @{
                CleanUpScope                             = "Supervisor"
                ArgoCDNamespaceDeletePollIntervalSeconds = 5
                ArgoCDNamespaceDeleteTimeoutSeconds      = 30
                HarborServiceDeletePollIntervalSeconds   = 10
                HarborServiceDeleteTimeoutSeconds        = 60
                HarborServiceYamlPath                    = ""
                LabEnvironment                           = $false
                SupervisorNamePrefix                     = "sup"
            }
            $cleanupState = [PSCustomObject]@{
                ClusterName      = "cl0-site1"
                ClusterObject    = $null
                CurrentEdgeSite  = "site1"
                SupervisorEnabled = $false
            }
            $clusterSpec = [PSCustomObject]@{ edgeSite = "site1" }
            $result = Invoke-NamedServiceScopedCleanup -Context $ctx -CleanupState $cleanupState -ClusterSpec $clusterSpec
            $result.Handled   | Should -Be $true
            $result.HadErrors | Should -Be $false
        }
    }

    It "Invoke-VcfEdgeAtScaleCleanup processes all clusters even when one has errors" {
        # Verifies that the per-cluster loop continues after a failure; cleanupHadErrors causes a final throw.
        InModuleScope VcfEdgeAtScale {
            $Script:_clustersProcessed = [System.Collections.Generic.List[String]]::new()
            Mock Write-LogMessage {}
            Mock Read-Host { return "y" }
            Mock Start-Sleep {}
            function Get-EffectiveClusterName {
                [CmdletBinding()] Param([Parameter()] [Object]$Cluster, [Parameter()] [Object]$ClusterNamePrefix, [Parameter()] [Object]$EdgeSite)
                return "cl-$($Cluster.edgeSite)"
            }
            function Get-DatastoreNameFromPrefix {
                [CmdletBinding()] Param([Parameter()] [Object]$DatastoreNamePrefix, [Parameter()] [Object]$EdgeSite)
                return "ds-$EdgeSite"
            }
            function Confirm-CleanupForCluster { [CmdletBinding()] Param([Parameter()] [Object]$ArgoCDNamespace, [Parameter()] [Object]$CleanUpScope, [Parameter()] [Object]$ClusterName, [Parameter()] [Object]$DatastoreName, [Parameter()] [Object]$EdgeSite, [Parameter()] [Switch]$ForceBypassPrompt) }
            function Get-ClusterByName {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                # Return a cluster object so Supervisor state can be checked.
                return [PSCustomObject]@{ Name = $Name }
            }
            Mock Invoke-ListNamespaceManagementClusters {
                @([PSCustomObject]@{ clusterName = "cl-site1"; ConfigStatus = "DISABLED"; KubernetesStatus = "NOT_INSTALLED" })
            }
            function Invoke-ClusterScopedCleanup {
                [CmdletBinding()] Param([Parameter()] [Object]$Context, [Parameter()] [Object]$CleanupState, [Parameter()] [Object]$ClusterSpec)
                $Script:_clustersProcessed.Add($CleanupState.ClusterName) | Out-Null
                # Cluster site1 succeeds; cluster site2 returns HadErrors.
                $hadErrors = ($CleanupState.CurrentEdgeSite -eq "site2")
                return [PSCustomObject]@{ HadErrors = $hadErrors }
            }
            $fakeCluster1 = [PSCustomObject]@{ edgeSite = "site1"; storagePolicy = [PSCustomObject]@{ storageType = "VMFS"; storagePolicyTagCatalog = "" } }
            $fakeCluster2 = [PSCustomObject]@{ edgeSite = "site2"; storagePolicy = [PSCustomObject]@{ storageType = "VMFS"; storagePolicyTagCatalog = "" } }
            $fakeInputData = [PSCustomObject]@{ common = [PSCustomObject]@{ nicList = @() } }
            $Script:vCenterName = $null
            {
                Invoke-VcfEdgeAtScaleCleanup -CleanUp "Compute" -ClusterNamePrefix "cl" `
                    -ClustersToProcess @($fakeCluster1, $fakeCluster2) -DatastoreNamePrefix "ds" `
                    -InputData $fakeInputData -LabEnvironment $true -Force `
                    -SupervisorNamePrefix "sup" -VdsNamePrefix "VDS"
            } | Should -Throw
            # Both clusters must have been processed before the throw.
            $Script:_clustersProcessed | Should -Contain "cl-site1"
            $Script:_clustersProcessed | Should -Contain "cl-site2"
        }
    }
}

# ── Invoke-ArgoCDNamespaceCleanupForCluster ───────────────────────────────────


Describe "Invoke-ArgoCDNamespaceCleanupForCluster" {

    It "Returns HadErrors = false and logs nothing-to-remove when ArgoCD namespace does not exist" {
        $result = InModuleScope VcfEdgeAtScale {
            $fakeClusterObj = [PSCustomObject]@{ Name = "cl0" }
            $fakeClusterSpec = [PSCustomObject]@{ edgeSite = "edge1" }

            function Get-ArgoCDNamespaceFromCluster {
                [CmdletBinding()] Param([Parameter()] [Object]$ClusterObject, [Parameter()] [Object]$ClusterSpec)
                return "argocd-edge1"
            }
            function Invoke-ListNamespacesInstances {
                [CmdletBinding()] Param()
                return [PSCustomObject]@{ Namespace = @("other-ns") }
            }

            Invoke-ArgoCDNamespaceCleanupForCluster `
                -ArgoCDNamespaceDeletePollIntervalSeconds 5 `
                -ArgoCDNamespaceDeleteTimeoutSeconds 30 `
                -ClusterName "cl0" -ClusterObject $fakeClusterObj `
                -ClusterSpec $fakeClusterSpec -CurrentEdgeSite "edge1"
        }
        $result.HadErrors | Should -Be $false
    }

    It "Returns HadErrors = true when Invoke-DeleteNamespaceInstances throws" {
        $result = InModuleScope VcfEdgeAtScale {
            $fakeClusterObj = [PSCustomObject]@{ Name = "cl0" }
            $fakeClusterSpec = [PSCustomObject]@{ edgeSite = "edge1" }

            function Get-ArgoCDNamespaceFromCluster {
                [CmdletBinding()] Param([Parameter()] [Object]$ClusterObject, [Parameter()] [Object]$ClusterSpec)
                return "argocd-edge1"
            }
            function Invoke-ListNamespacesInstances {
                [CmdletBinding()] Param()
                return [PSCustomObject]@{ Namespace = @("argocd-edge1") }
            }
            function Invoke-DeleteNamespaceInstances {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param([Parameter()] [Object]$Namespace)
                throw "Namespace deletion failed: API error"
            }

            Invoke-ArgoCDNamespaceCleanupForCluster `
                -ArgoCDNamespaceDeletePollIntervalSeconds 5 `
                -ArgoCDNamespaceDeleteTimeoutSeconds 30 `
                -ClusterName "cl0" -ClusterObject $fakeClusterObj `
                -ClusterSpec $fakeClusterSpec -CurrentEdgeSite "edge1"
        }
        $result.HadErrors | Should -Be $true
    }

    It "Returns HadErrors = false when namespace is deleted and disappears on first poll" {
        $result = InModuleScope VcfEdgeAtScale {
            $fakeClusterObj = [PSCustomObject]@{ Name = "cl0" }
            $fakeClusterSpec = [PSCustomObject]@{ edgeSite = "edge1" }
            $Script:_listCallCount = 0

            function Get-ArgoCDNamespaceFromCluster {
                [CmdletBinding()] Param([Parameter()] [Object]$ClusterObject, [Parameter()] [Object]$ClusterSpec)
                return "argocd-edge1"
            }
            function Invoke-ListNamespacesInstances {
                [CmdletBinding()] Param()
                $Script:_listCallCount++
                # First call: existence check returns namespace present; second call (poll): gone.
                if ($Script:_listCallCount -le 1) { return [PSCustomObject]@{ Namespace = @("argocd-edge1") } }
                return [PSCustomObject]@{ Namespace = @("other-ns") }
            }
            function Invoke-DeleteNamespaceInstances {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param([Parameter()] [Object]$Namespace)
            }
            function Start-Sleep { [CmdletBinding()] Param([Parameter()] [Object]$Seconds) }

            Invoke-ArgoCDNamespaceCleanupForCluster `
                -ArgoCDNamespaceDeletePollIntervalSeconds 1 `
                -ArgoCDNamespaceDeleteTimeoutSeconds 30 `
                -ClusterName "cl0" -ClusterObject $fakeClusterObj `
                -ClusterSpec $fakeClusterSpec -CurrentEdgeSite "edge1"
        }
        $result.HadErrors | Should -Be $false
    }
}

# ── Invoke-HarborServiceCleanupForCluster ─────────────────────────────────────


Describe "Invoke-HarborServiceCleanupForCluster" {

    It "Returns HadErrors = false when supervisor ID lookup throws (non-fatal skip)" {
        $result = InModuleScope VcfEdgeAtScale {
            function Get-SupervisorNameFromPrefix {
                [CmdletBinding()] Param([Parameter()] [Object]$SupervisorNamePrefix, [Parameter()] [Object]$EdgeSite)
                return "sup-edge1"
            }
            function Get-SupervisorId {
                [CmdletBinding()] Param([Parameter()] [Object]$supervisorName, [Parameter()] [Object]$VcenterUser,
                    [Parameter()] [Object]$VcenterCredential, [Parameter()] [Switch]$InsecureTls,
                    [Parameter()] [Switch]$Silence, [Parameter()] [Switch]$SkipReadyWait)
                throw "Supervisor not found"
            }

            Invoke-HarborServiceCleanupForCluster `
                -ClusterName "cl0" -CurrentEdgeSite "edge1" `
                -HarborServiceDeletePollIntervalSeconds 10 -HarborServiceDeleteTimeoutSeconds 60 `
                -HarborServiceYamlPath "" -LabEnvironment:$false -SupervisorNamePrefix "sup"
        }
        $result.HadErrors | Should -Be $false
    }

    It "Returns HadErrors = false when HarborServiceYamlPath is empty (service identifier unknown — skip)" {
        $result = InModuleScope VcfEdgeAtScale {
            function Get-SupervisorNameFromPrefix {
                [CmdletBinding()] Param([Parameter()] [Object]$SupervisorNamePrefix, [Parameter()] [Object]$EdgeSite)
                return "sup-edge1"
            }
            function Get-SupervisorId {
                [CmdletBinding()] Param([Parameter()] [Object]$supervisorName, [Parameter()] [Object]$VcenterUser,
                    [Parameter()] [Object]$VcenterCredential, [Parameter()] [Switch]$InsecureTls,
                    [Parameter()] [Switch]$Silence, [Parameter()] [Switch]$SkipReadyWait)
                return "supervisor-uuid-1234"
            }

            Invoke-HarborServiceCleanupForCluster `
                -ClusterName "cl0" -CurrentEdgeSite "edge1" `
                -HarborServiceDeletePollIntervalSeconds 10 -HarborServiceDeleteTimeoutSeconds 60 `
                -HarborServiceYamlPath "" -LabEnvironment:$false -SupervisorNamePrefix "sup"
        }
        $result.HadErrors | Should -Be $false
    }

    It "Returns HadErrors = true when Remove-HarborSupervisorService throws" {
        $result = InModuleScope VcfEdgeAtScale {
            function Get-SupervisorNameFromPrefix {
                [CmdletBinding()] Param([Parameter()] [Object]$SupervisorNamePrefix, [Parameter()] [Object]$EdgeSite)
                return "sup-edge1"
            }
            function Get-SupervisorId {
                [CmdletBinding()] Param([Parameter()] [Object]$supervisorName, [Parameter()] [Object]$VcenterUser,
                    [Parameter()] [Object]$VcenterCredential, [Parameter()] [Switch]$InsecureTls,
                    [Parameter()] [Switch]$Silence, [Parameter()] [Switch]$SkipReadyWait)
                return "supervisor-uuid-1234"
            }
            function Get-ArgoCDServiceDetail {
                [CmdletBinding()] Param([Parameter()] [Object]$Path)
                return @("harbor-service-v1.0.0", $null)
            }
            function Test-Path {
                [CmdletBinding()] Param([Parameter()] [Object]$Path)
                return $true
            }
            function Remove-HarborSupervisorService {
                [CmdletBinding()] Param([Parameter()] [Object]$ClusterName, [Parameter()] [Object]$DeletePollIntervalSeconds,
                    [Parameter()] [Object]$DeleteTimeoutSeconds, [Parameter()] [Object]$Service, [Parameter()] [Object]$SupervisorId)
                throw "Harbor service removal failed"
            }

            Invoke-HarborServiceCleanupForCluster `
                -ClusterName "cl0" -CurrentEdgeSite "edge1" `
                -HarborServiceDeletePollIntervalSeconds 10 -HarborServiceDeleteTimeoutSeconds 60 `
                -HarborServiceYamlPath "/fake/harbor-service.yml" -LabEnvironment:$false -SupervisorNamePrefix "sup"
        }
        $result.HadErrors | Should -Be $true
    }
}

# ── Get-ManagementVSwitchInfo — logic paths ───────────────────────────────────


Describe "Invoke-VcfEdgeAtScaleCleanup — Compute scope with mocked cluster lookup" {

    It "Throws when Supervisor is still enabled and Compute cleanup is requested" {
        InModuleScope VcfEdgeAtScale {
            $fakeCluster = [PSCustomObject]@{
                edgeSite      = "site1"
                storagePolicy = [PSCustomObject]@{ storageType = "VMFS"; storagePolicyTagCatalog = "" }
            }
            $fakeInputData = [PSCustomObject]@{ common = [PSCustomObject]@{ nicList = @() } }
            Mock Get-ClusterNameFromPrefix { return "cl0-site1" }
            Mock Get-ClusterByName { [PSCustomObject]@{ Name = "cl0-site1" } }
            Mock Invoke-ListNamespaceManagementClusters {
                @([PSCustomObject]@{ clusterName = "cl0-site1"; ConfigStatus = "RUNNING"; KubernetesStatus = "READY" })
            }
            {
                Invoke-VcfEdgeAtScaleCleanup -CleanUp "Compute" -ClusterNamePrefix "cl" `
                    -ClustersToProcess @($fakeCluster) -DatastoreNamePrefix "ds" `
                    -InputData $fakeInputData -LabEnvironment $false -SupervisorNamePrefix "sup" `
                    -VdsNamePrefix "VDS"
            } | Should -Throw

        }
    }
}

# ── Update-HelpJsonIfStale — help JSON version-comparison and copy logic ──────


Describe "Initialize-VcfEdgeAtScale — propagates exception from invalid configuration" {
    It "Throws when Get-InitializationConfigFromJson fails (e.g. JSON file does not exist)" {
        { InModuleScope VcfEdgeAtScale {
            # Mock the very first call inside the try block so the function
            # propagates the exception without reaching any interactive prompts.
            # Disconnect-Vcenter is called in finally; stub it so it does not error.
            Mock Get-InitializationConfigFromJson { throw "JSON file not found: fake.json" }
            Mock Disconnect-Vcenter {}
            Mock Write-LogMessage {}
            Initialize-VcfEdgeAtScale -InfrastructureJson "fake.json" -SupervisorJson "fake-sup.json"
        } } | Should -Throw
    }
}

Describe "Initialize-VcfEdgeAtScale — CleanUp dispatches to Invoke-VcfEdgeAtScaleCleanup" {
    It "Calls Invoke-VcfEdgeAtScaleCleanup exactly once and exits without deploying when -CleanUp All is set" {
        $cleanupCount = InModuleScope VcfEdgeAtScale {
            $Script:_cleanupCallCount = 0
            function Get-InitializationConfigFromJson {
                [CmdletBinding()] Param([Parameter()] [Object]$EdgeSite, [Parameter()] [Object]$InfrastructureJson)
                return [PSCustomObject]@{
                    InputData                                = [PSCustomObject]@{ common = @{} }
                    LabEnvironment                           = $false
                    EsxUniquePassword                        = $false
                    NonInteractivePassword                   = $false
                    PreserveAutoGeneratedKeyCertPair         = $false
                    DatacenterName                           = "dc1"
                    ContextName                              = "ctx1"
                    SupervisorContentLibraryDatastorePresent = $false
                    SupervisorContentLibraryDatastore        = $null
                    SupervisorContentLibrarySubscriptionUrl  = $null
                    ClusterNamePrefix                        = "cluster"
                    DatastoreNamePrefix                      = "datastore"
                    VdsNamePrefix                            = "vds"
                    SupervisorNamePrefix                     = "supervisor"
                    EsxUser                                  = "root"
                    ClustersToProcess                        = @()
                }
            }
            function Get-VcfEdgeAtScaleVcfCmd { [CmdletBinding()] Param() }
            function Test-CommandAvailability {
                [CmdletBinding()] Param([Parameter()] [Object]$Command, [Parameter()] [Object]$Description)
            }
            function Test-VcenterAndEsxReachability {
                [CmdletBinding()] Param([Parameter()] [Object]$EsxHosts, [Parameter()] [Object]$Port, [Parameter()] [Object]$VcenterName)
            }
            function Invoke-VcenterConnectionAndValidation {
                [CmdletBinding()] Param([Parameter()] [Object]$MaximumSupervisorsPerVcenter, [Parameter()] [Object]$NonInteractivePassword, [Parameter()] [Object]$VcenterName, [Parameter()] [Object]$VcenterUser)
            }
            function Invoke-VcfEdgeAtScaleCleanup {
                [CmdletBinding()] Param([Parameter()] [Object]$CleanUp, [Parameter()] [Object]$ClusterNamePrefix, [Parameter()] [Object]$ClustersToProcess, [Parameter()] [Object]$DatastoreNamePrefix, [Parameter()] [Object]$Force, [Parameter()] [Object]$InputData, [Parameter()] [Object]$LabEnvironment, [Parameter()] [Object]$SupervisorNamePrefix, [Parameter()] [Object]$VdsNamePrefix)
                begin { $Script:_cleanupCallCount++ }; process {}
            }
            function Disconnect-Vcenter {
                [CmdletBinding()] Param([Parameter()] [Switch]$AllServers, [Parameter()] [Switch]$Silence)
            }
            Mock Write-LogMessage {}
            Initialize-VcfEdgeAtScale -InfrastructureJson "fake.json" -SupervisorJson "fake-sup.json" -CleanUp "All"
            $Script:_cleanupCallCount
        }
        $cleanupCount | Should -Be 1
    }
}

Describe "Initialize-VcfEdgeAtScale — per-cluster loop calls Invoke-ClusterDeploymentIteration" {
    It "Calls Invoke-ClusterDeploymentIteration once for each cluster in ClustersToProcess" {
        $iterationCount = InModuleScope VcfEdgeAtScale {
            $Script:_iterationCallCount = 0
            $fakeClusters = @(
                @{ edgeSite = "site1"; esxHosts = @("esx01.lab") },
                @{ edgeSite = "site2"; esxHosts = @("esx02.lab") }
            )
            function Get-InitializationConfigFromJson {
                [CmdletBinding()] Param([Parameter()] [Object]$EdgeSite, [Parameter()] [Object]$InfrastructureJson)
                return [PSCustomObject]@{
                    InputData                                = [PSCustomObject]@{ common = @{} }
                    LabEnvironment                           = $false
                    EsxUniquePassword                        = $false
                    NonInteractivePassword                   = $false
                    PreserveAutoGeneratedKeyCertPair         = $false
                    DatacenterName                           = "dc1"
                    ContextName                              = "ctx1"
                    SupervisorContentLibraryDatastorePresent = $false
                    SupervisorContentLibraryDatastore        = $null
                    SupervisorContentLibrarySubscriptionUrl  = $null
                    ClusterNamePrefix                        = "cluster"
                    DatastoreNamePrefix                      = "datastore"
                    VdsNamePrefix                            = "vds"
                    SupervisorNamePrefix                     = "supervisor"
                    EsxUser                                  = "root"
                    ClustersToProcess                        = $Script:_fakeClusters
                }
            }
            $Script:_fakeClusters = $fakeClusters
            function Get-VcfEdgeAtScaleVcfCmd { [CmdletBinding()] Param() }
            function Test-CommandAvailability {
                [CmdletBinding()] Param([Parameter()] [Object]$Command, [Parameter()] [Object]$Description)
            }
            function Test-VcenterAndEsxReachability {
                [CmdletBinding()] Param([Parameter()] [Object]$EsxHosts, [Parameter()] [Object]$Port, [Parameter()] [Object]$VcenterName)
            }
            function Invoke-VcenterConnectionAndValidation {
                [CmdletBinding()] Param([Parameter()] [Object]$MaximumSupervisorsPerVcenter, [Parameter()] [Object]$NonInteractivePassword, [Parameter()] [Object]$VcenterName, [Parameter()] [Object]$VcenterUser)
            }
            function Invoke-WitnessHostPreflightCheck {
                [CmdletBinding()] Param([Parameter()] [Object]$ClustersToProcess, [Parameter()] [Object]$InputData)
            }
            function Invoke-EsxCredentialCollection {
                [CmdletBinding()] Param([Parameter()] [Object]$AllEsxHosts, [Parameter()] [Object]$EsxUniquePassword, [Parameter()] [Object]$EsxUser, [Parameter()] [Object]$NonInteractivePassword)
                return @{ EsxPasswords = @{}; EsxUsedEnvPassword = $false }
            }
            function Invoke-EsxPreFlightVersionCheck {
                [CmdletBinding()] Param([Parameter()] [Object]$AllEsxHosts, [Parameter()] [Object]$EsxPasswords)
                return $false
            }
            function Invoke-ClusterDeploymentIteration {
                [CmdletBinding()] Param([Parameter()] [Object]$Context)
                $Script:_iterationCallCount++
                return @{ ShouldContinue = $false; EsxUsedEnvPassword = $false }
            }
            function Disconnect-Vcenter {
                [CmdletBinding()] Param([Parameter()] [Switch]$AllServers, [Parameter()] [Switch]$Silence)
            }
            Mock Write-LogMessage {}
            # -ComputeOnly exits cleanly after the cluster loop without requiring supervisor stubs.
            Initialize-VcfEdgeAtScale -InfrastructureJson "fake.json" -SupervisorJson "fake-sup.json" -ComputeOnly
            $Script:_iterationCallCount
        }
        $iterationCount | Should -Be 2
    }
}

Describe "Initialize-VcfEdgeAtScale — ComputeOnly exits after cluster loop without supervisor" {
    It "Runs per-cluster iterations but exits with ComputeOnly message rather than proceeding to supervisor" {
        $iterCount = InModuleScope VcfEdgeAtScale {
            $Script:_computeIterCount = 0
            function Get-InitializationConfigFromJson {
                [CmdletBinding()] Param([Parameter()] [Object]$EdgeSite, [Parameter()] [Object]$InfrastructureJson)
                return [PSCustomObject]@{
                    InputData                                = [PSCustomObject]@{ common = @{} }
                    LabEnvironment                           = $false
                    EsxUniquePassword                        = $false
                    NonInteractivePassword                   = $false
                    PreserveAutoGeneratedKeyCertPair         = $false
                    DatacenterName                           = "dc1"
                    ContextName                              = "ctx1"
                    SupervisorContentLibraryDatastorePresent = $false
                    SupervisorContentLibraryDatastore        = $null
                    SupervisorContentLibrarySubscriptionUrl  = $null
                    ClusterNamePrefix                        = "cluster"
                    DatastoreNamePrefix                      = "datastore"
                    VdsNamePrefix                            = "vds"
                    SupervisorNamePrefix                     = "supervisor"
                    EsxUser                                  = "root"
                    ClustersToProcess                        = @(@{ edgeSite = "site1"; esxHosts = @() })
                }
            }
            function Get-VcfEdgeAtScaleVcfCmd { [CmdletBinding()] Param() }
            function Test-CommandAvailability {
                [CmdletBinding()] Param([Parameter()] [Object]$Command, [Parameter()] [Object]$Description)
            }
            function Test-VcenterAndEsxReachability {
                [CmdletBinding()] Param([Parameter()] [Object]$EsxHosts, [Parameter()] [Object]$Port, [Parameter()] [Object]$VcenterName)
            }
            function Invoke-VcenterConnectionAndValidation {
                [CmdletBinding()] Param([Parameter()] [Object]$MaximumSupervisorsPerVcenter, [Parameter()] [Object]$NonInteractivePassword, [Parameter()] [Object]$VcenterName, [Parameter()] [Object]$VcenterUser)
            }
            function Invoke-WitnessHostPreflightCheck {
                [CmdletBinding()] Param([Parameter()] [Object]$ClustersToProcess, [Parameter()] [Object]$InputData)
            }
            function Invoke-EsxCredentialCollection {
                [CmdletBinding()] Param([Parameter()] [Object]$AllEsxHosts, [Parameter()] [Object]$EsxUniquePassword, [Parameter()] [Object]$EsxUser, [Parameter()] [Object]$NonInteractivePassword)
                return @{ EsxPasswords = @{}; EsxUsedEnvPassword = $false }
            }
            function Invoke-EsxPreFlightVersionCheck {
                [CmdletBinding()] Param([Parameter()] [Object]$AllEsxHosts, [Parameter()] [Object]$EsxPasswords)
                return $false
            }
            function Invoke-ClusterDeploymentIteration {
                [CmdletBinding()] Param([Parameter()] [Object]$Context)
                $Script:_computeIterCount++
                return @{ ShouldContinue = $false; EsxUsedEnvPassword = $false }
            }
            function Disconnect-Vcenter {
                [CmdletBinding()] Param([Parameter()] [Switch]$AllServers, [Parameter()] [Switch]$Silence)
            }
            Mock Write-LogMessage {}
            # -ComputeOnly: the loop runs but supervisor deployment is not initiated.
            Initialize-VcfEdgeAtScale -InfrastructureJson "fake.json" -SupervisorJson "fake-sup.json" -ComputeOnly
            $Script:_computeIterCount
        }
        $iterCount | Should -Be 1
    }
}

Describe "Invoke-ClusterDeploymentIteration — content library initialized when flag set" {
    It "Calls Initialize-SupervisorContentLibrary once when SupervisorContentLibraryDatastorePresent is true" {
        $callCount = InModuleScope VcfEdgeAtScale {
            $Script:_clCount = 0
            function Invoke-ClusterPerSiteVariables {
                [CmdletBinding()] Param([Parameter()] [Object]$Cluster, [Parameter()] [Object]$ClusterNamePrefix, [Parameter()] [Object]$DatastoreNamePrefix, [Parameter()] [Object]$InputData, [Parameter()] [Object]$SupervisorNamePrefix, [Parameter()] [Object]$VdsNamePrefix)
                return [PSCustomObject]@{ EdgeSite = "edge1"; SupervisorName = "sup-edge1"; ClusterName = "cl-edge1"; DatastoreName = "ds-edge1"; VdsName = "VDS-edge1"; EsxHosts = @("esx1.lab"); NetworkSegments = @(); ArgoCDYaml = ""; ArgoCdDeploymentYamlPath = ""; ArgocdNameSpacePrefix = "argocd"; ArgocdVmClass = "vm"; SkipArgoCDDeployment = $true; SkipHarborDeployment = $true; StoragePolicyName = "pol"; StoragePolicyTagCatalog = "cat"; StoragePolicyType = "vSAN-OSA"; EffectiveMultiHostHaPolicy = "ha"; NicList = @("nic1"); NumUplinks = 2 }
            }
            function Invoke-EsxCredentialAndDatastoreSetup {
                [CmdletBinding()] Param([Parameter()] [Object]$Context)
                return @{ DiskCanonicalName = $null; EsxUsedEnvPassword = $false }
            }
            function Initialize-SupervisorContentLibrary {
                [CmdletBinding()] Param([Parameter()] [Object]$DatastoreName, [Parameter()] [Object]$LibraryName, [Parameter()] [Object]$SubscriptionUrl)
                begin { $Script:_clCount++ }
                process {}
            }
            function Invoke-ClusterCreationPhase { [CmdletBinding()] Param([Parameter()] [Object]$Cluster, [Parameter()] [Object]$ClusterName, [Parameter()] [Object]$DatacenterName, [Parameter()] [Object]$InputData, [Parameter()] [Object]$StoragePolicyType) }
            function Invoke-ClusterHostAdditionPhase { [CmdletBinding()] Param([Parameter()] [Object]$Context); begin {}; process {} }
            function Invoke-ClusterPreSupervisorPhase {
                [CmdletBinding()] Param([Parameter()] [Object]$Context)
                return @{ ShouldContinue = $true; ClusterId = $null; StoragePolicyId = $null }
            }
            Mock Write-LogMessage {}
            $fakeCluster = [PSCustomObject]@{ edgeSite = "edge1" }
            $ctx = @{ AcceptBadCheckResults = $false; Cluster = $fakeCluster; ClusterIndex = 1; ClusterNamePrefix = "cl-"; ClustersToProcessCount = 1; ComputeOnly = $false; ContextName = "ctx"; DatacenterName = "dc1"; DatastoreNamePrefix = "ds-"; DelayBeforeAddingNextHostSeconds = 0; EsxPasswords = @{}; EsxUniquePassword = $false; EsxUsedEnvPassword = $false; EsxUser = "root"; EsxVersionChecked = @{}; InfrastructureJson = "infra.json"; InputData = [PSCustomObject]@{ clusters = @($fakeCluster); common = [PSCustomObject]@{ } }; LabEnvironment = $false; PreserveAutoGeneratedKeyCertPair = $false; SaveHarborYaml = $false; SupervisorContentLibraryDatastore = "ContentDS"; SupervisorContentLibraryDatastorePresent = $true; SupervisorContentLibrarySubscriptionUrl = "https://lib.example.com"; SupervisorJson = "sup.json"; SupervisorNamePrefix = "sup-"; VdsNamePrefix = "VDS-" }
             $null = Invoke-ClusterDeploymentIteration -Context $ctx
             $Script:_clCount
         }
         $callCount | Should -Be 1
    }
}

Describe "Invoke-ClusterDeploymentIteration — supervisor phase returns continue" {
    It "Returns ShouldContinue=true when Invoke-SupervisorDeploymentPhase returns true" {
        $result = InModuleScope VcfEdgeAtScale {
            function Invoke-ClusterPerSiteVariables {
                [CmdletBinding()] Param([Parameter()] [Object]$Cluster, [Parameter()] [Object]$ClusterNamePrefix, [Parameter()] [Object]$DatastoreNamePrefix, [Parameter()] [Object]$InputData, [Parameter()] [Object]$SupervisorNamePrefix, [Parameter()] [Object]$VdsNamePrefix)
                return [PSCustomObject]@{ EdgeSite = "edge1"; SupervisorName = "sup-edge1"; ClusterName = "cl-edge1"; DatastoreName = "ds-edge1"; VdsName = "VDS-edge1"; EsxHosts = @("esx1.lab"); NetworkSegments = @(); ArgoCDYaml = ""; ArgoCdDeploymentYamlPath = ""; ArgocdNameSpacePrefix = "argocd"; ArgocdVmClass = "vm"; SkipArgoCDDeployment = $true; SkipHarborDeployment = $true; StoragePolicyName = "pol"; StoragePolicyTagCatalog = "cat"; StoragePolicyType = "vSAN-OSA"; EffectiveMultiHostHaPolicy = "ha"; NicList = @("nic1"); NumUplinks = 2 }
            }
            function Invoke-EsxCredentialAndDatastoreSetup {
                [CmdletBinding()] Param([Parameter()] [Object]$Context)
                return @{ DiskCanonicalName = $null; EsxUsedEnvPassword = $false }
            }
            function Invoke-ClusterCreationPhase { [CmdletBinding()] Param([Parameter()] [Object]$Cluster, [Parameter()] [Object]$ClusterName, [Parameter()] [Object]$DatacenterName, [Parameter()] [Object]$InputData, [Parameter()] [Object]$StoragePolicyType) }
            function Invoke-ClusterHostAdditionPhase { [CmdletBinding()] Param([Parameter()] [Object]$Context); begin {}; process {} }
            function Invoke-ClusterPreSupervisorPhase {
                [CmdletBinding()] Param([Parameter()] [Object]$Context)
                return @{ ShouldContinue = $false; ClusterId = "cid1"; StoragePolicyId = "sp1" }
            }
            function Invoke-SupervisorDeploymentPhase {
                [CmdletBinding()] Param([Parameter()] [Object]$Context)
                return $true
            }
            Mock Write-LogMessage {}
            $fakeCluster = [PSCustomObject]@{ edgeSite = "edge1" }
            $ctx = @{ AcceptBadCheckResults = $false; Cluster = $fakeCluster; ClusterIndex = 1; ClusterNamePrefix = "cl-"; ClustersToProcessCount = 1; ComputeOnly = $false; ContextName = "ctx"; DatacenterName = "dc1"; DatastoreNamePrefix = "ds-"; DelayBeforeAddingNextHostSeconds = 0; EsxPasswords = @{}; EsxUniquePassword = $false; EsxUsedEnvPassword = $false; EsxUser = "root"; EsxVersionChecked = @{}; InfrastructureJson = "infra.json"; InputData = [PSCustomObject]@{ clusters = @($fakeCluster); common = [PSCustomObject]@{ } }; LabEnvironment = $false; PreserveAutoGeneratedKeyCertPair = $false; SaveHarborYaml = $false; SupervisorContentLibraryDatastore = ""; SupervisorContentLibraryDatastorePresent = $false; SupervisorContentLibrarySubscriptionUrl = ""; SupervisorJson = "sup.json"; SupervisorNamePrefix = "sup-"; VdsNamePrefix = "VDS-" }
            Invoke-ClusterDeploymentIteration -Context $ctx
        }
        $result.ShouldContinue | Should -Be $true
    }
}

Describe "Invoke-ClusterDeploymentIteration — RollbackFailed rethrows without calling rollback" {
    It "Throws and does not call Invoke-ComputePreSupervisorRollback when Script:RollbackFailed is true" {
        { InModuleScope VcfEdgeAtScale {
            function Invoke-ClusterPerSiteVariables {
                [CmdletBinding()] Param([Parameter()] [Object]$Cluster, [Parameter()] [Object]$ClusterNamePrefix, [Parameter()] [Object]$DatastoreNamePrefix, [Parameter()] [Object]$InputData, [Parameter()] [Object]$SupervisorNamePrefix, [Parameter()] [Object]$VdsNamePrefix)
                return [PSCustomObject]@{ EdgeSite = "edge1"; SupervisorName = "sup-edge1"; ClusterName = "cl-edge1"; DatastoreName = "ds-edge1"; VdsName = "VDS-edge1"; EsxHosts = @("esx1.lab"); NetworkSegments = @(); ArgoCDYaml = ""; ArgoCdDeploymentYamlPath = ""; ArgocdNameSpacePrefix = "argocd"; ArgocdVmClass = "vm"; SkipArgoCDDeployment = $true; SkipHarborDeployment = $true; StoragePolicyName = "pol"; StoragePolicyTagCatalog = "cat"; StoragePolicyType = "vSAN-OSA"; EffectiveMultiHostHaPolicy = "ha"; NicList = @("nic1"); NumUplinks = 2 }
            }
            function Invoke-EsxCredentialAndDatastoreSetup {
                [CmdletBinding()] Param([Parameter()] [Object]$Context)
                $Script:RollbackFailed = $true
                throw "simulated compute failure after rollback already failed"
            }
            # Sentinel: if the generic catch incorrectly reaches rollback, the test fails loudly.
            function Invoke-ComputePreSupervisorRollback {
                [CmdletBinding()] Param([Parameter()] [Object]$Context)
                throw "SENTINEL: Invoke-ComputePreSupervisorRollback must not be called when RollbackFailed is true"
            }
            Mock Write-LogMessage {}
            $fakeCluster = [PSCustomObject]@{ edgeSite = "edge1" }
            $ctx = @{ AcceptBadCheckResults = $false; Cluster = $fakeCluster; ClusterIndex = 1; ClusterNamePrefix = "cl-"; ClustersToProcessCount = 1; ComputeOnly = $false; ContextName = "ctx"; DatacenterName = "dc1"; DatastoreNamePrefix = "ds-"; DelayBeforeAddingNextHostSeconds = 0; EsxPasswords = @{}; EsxUniquePassword = $false; EsxUsedEnvPassword = $false; EsxUser = "root"; EsxVersionChecked = @{}; InfrastructureJson = "infra.json"; InputData = [PSCustomObject]@{ clusters = @($fakeCluster); common = [PSCustomObject]@{ } }; LabEnvironment = $false; PreserveAutoGeneratedKeyCertPair = $false; SaveHarborYaml = $false; SupervisorContentLibraryDatastore = ""; SupervisorContentLibraryDatastorePresent = $false; SupervisorContentLibrarySubscriptionUrl = ""; SupervisorJson = "sup.json"; SupervisorNamePrefix = "sup-"; VdsNamePrefix = "VDS-" }
            Invoke-ClusterDeploymentIteration -Context $ctx
        } } | Should -Throw
    }
}

Describe "Invoke-ClusterDeploymentIteration — compute rollback called on generic error" {
    It "Returns ShouldContinue=true when Invoke-ComputePreSupervisorRollback succeeds and returns ShouldContinue=true" {
        $result = InModuleScope VcfEdgeAtScale {
            function Invoke-ClusterPerSiteVariables {
                [CmdletBinding()] Param([Parameter()] [Object]$Cluster, [Parameter()] [Object]$ClusterNamePrefix, [Parameter()] [Object]$DatastoreNamePrefix, [Parameter()] [Object]$InputData, [Parameter()] [Object]$SupervisorNamePrefix, [Parameter()] [Object]$VdsNamePrefix)
                return [PSCustomObject]@{ EdgeSite = "edge1"; SupervisorName = "sup-edge1"; ClusterName = "cl-edge1"; DatastoreName = "ds-edge1"; VdsName = "VDS-edge1"; EsxHosts = @("esx1.lab"); NetworkSegments = @(); ArgoCDYaml = ""; ArgoCdDeploymentYamlPath = ""; ArgocdNameSpacePrefix = "argocd"; ArgocdVmClass = "vm"; SkipArgoCDDeployment = $true; SkipHarborDeployment = $true; StoragePolicyName = "pol"; StoragePolicyTagCatalog = "cat"; StoragePolicyType = "vSAN-OSA"; EffectiveMultiHostHaPolicy = "ha"; NicList = @("nic1"); NumUplinks = 2 }
            }
            function Invoke-EsxCredentialAndDatastoreSetup {
                [CmdletBinding()] Param([Parameter()] [Object]$Context)
                throw "compute error: disk not found"
            }
            function Invoke-ComputePreSupervisorRollback {
                [CmdletBinding()] Param([Parameter()] [Object]$Context)
                return @{ ShouldContinue = $true }
            }
            Mock Write-LogMessage {}
            $fakeCluster = [PSCustomObject]@{ edgeSite = "edge1" }
            $ctx = @{ AcceptBadCheckResults = $false; Cluster = $fakeCluster; ClusterIndex = 1; ClusterNamePrefix = "cl-"; ClustersToProcessCount = 1; ComputeOnly = $false; ContextName = "ctx"; DatacenterName = "dc1"; DatastoreNamePrefix = "ds-"; DelayBeforeAddingNextHostSeconds = 0; EsxPasswords = @{}; EsxUniquePassword = $false; EsxUsedEnvPassword = $false; EsxUser = "root"; EsxVersionChecked = @{}; InfrastructureJson = "infra.json"; InputData = [PSCustomObject]@{ clusters = @($fakeCluster); common = [PSCustomObject]@{ } }; LabEnvironment = $false; PreserveAutoGeneratedKeyCertPair = $false; SaveHarborYaml = $false; SupervisorContentLibraryDatastore = ""; SupervisorContentLibraryDatastorePresent = $false; SupervisorContentLibrarySubscriptionUrl = ""; SupervisorJson = "sup.json"; SupervisorNamePrefix = "sup-"; VdsNamePrefix = "VDS-" }
            Invoke-ClusterDeploymentIteration -Context $ctx
        }
        $result.ShouldContinue | Should -Be $true
    }
}

Describe "Invoke-ClusterDeploymentIteration — phase order" {
    It "Calls Invoke-ClusterCreationPhase before Invoke-SupervisorDeploymentPhase on the happy path" {
        $phaseOrder = InModuleScope VcfEdgeAtScale {
            $Script:_phaseOrder = [System.Collections.Generic.List[String]]::new()
            function Invoke-ClusterPerSiteVariables {
                [CmdletBinding()] Param([Parameter()] [Object]$Cluster, [Parameter()] [Object]$ClusterNamePrefix, [Parameter()] [Object]$DatastoreNamePrefix, [Parameter()] [Object]$InputData, [Parameter()] [Object]$SupervisorNamePrefix, [Parameter()] [Object]$VdsNamePrefix)
                return [PSCustomObject]@{ EdgeSite = "edge1"; SupervisorName = "sup-edge1"; ClusterName = "cl-edge1"; DatastoreName = "ds-edge1"; VdsName = "VDS-edge1"; EsxHosts = @("esx1.lab"); NetworkSegments = @(); ArgoCDYaml = ""; ArgoCdDeploymentYamlPath = ""; ArgocdNameSpacePrefix = "argocd"; ArgocdVmClass = "vm"; SkipArgoCDDeployment = $true; SkipHarborDeployment = $true; StoragePolicyName = "pol"; StoragePolicyTagCatalog = "cat"; StoragePolicyType = "vSAN-OSA"; EffectiveMultiHostHaPolicy = "ha"; NicList = @("nic1"); NumUplinks = 2 }
            }
            function Invoke-EsxCredentialAndDatastoreSetup {
                [CmdletBinding()] Param([Parameter()] [Object]$Context)
                $Script:_phaseOrder.Add("EsxSetup")
                return @{ DiskCanonicalName = $null; EsxUsedEnvPassword = $false }
            }
            function Invoke-ClusterCreationPhase {
                [CmdletBinding()] Param([Parameter()] [Object]$Cluster, [Parameter()] [Object]$ClusterName, [Parameter()] [Object]$DatacenterName, [Parameter()] [Object]$InputData, [Parameter()] [Object]$StoragePolicyType)
                $Script:_phaseOrder.Add("ClusterCreation")
            }
            function Invoke-ClusterHostAdditionPhase {
                [CmdletBinding()] Param([Parameter()] [Object]$Context)
                $Script:_phaseOrder.Add("HostAddition")
            }
            function Invoke-ClusterPreSupervisorPhase {
                [CmdletBinding()] Param([Parameter()] [Object]$Context)
                $Script:_phaseOrder.Add("PreSupervisor")
                # ShouldContinue=$false means proceed to supervisor; $true means skip to next site.
                return @{ ShouldContinue = $false; ClusterId = "cid1"; StoragePolicyId = "sp1" }
            }
            function Invoke-SupervisorDeploymentPhase {
                [CmdletBinding()] Param([Parameter()] [Object]$Context)
                $Script:_phaseOrder.Add("SupervisorDeployment")
                return $false
            }
            # Guard: if the catch block fires unexpectedly, rollback would call Invoke-ComputePreSupervisorRollback.
            function Invoke-ComputePreSupervisorRollback {
                [CmdletBinding()] Param([Parameter()] [Object]$Context)
                throw "SENTINEL: Invoke-ComputePreSupervisorRollback must not be called on the happy path"
            }
            Mock Write-LogMessage {}
            $fakeCluster = [PSCustomObject]@{ edgeSite = "edge1" }
            $ctx = @{ AcceptBadCheckResults = $false; Cluster = $fakeCluster; ClusterIndex = 1; ClusterNamePrefix = "cl-"; ClustersToProcessCount = 1; ComputeOnly = $false; ContextName = "ctx"; DatacenterName = "dc1"; DatastoreNamePrefix = "ds-"; DelayBeforeAddingNextHostSeconds = 0; EsxPasswords = @{}; EsxUniquePassword = $false; EsxUsedEnvPassword = $false; EsxUser = "root"; EsxVersionChecked = @{}; InfrastructureJson = "infra.json"; InputData = [PSCustomObject]@{ clusters = @($fakeCluster); common = [PSCustomObject]@{ } }; LabEnvironment = $false; PreserveAutoGeneratedKeyCertPair = $false; SaveHarborYaml = $false; SupervisorContentLibraryDatastore = ""; SupervisorContentLibraryDatastorePresent = $false; SupervisorContentLibrarySubscriptionUrl = ""; SupervisorJson = "sup.json"; SupervisorNamePrefix = "sup-"; VdsNamePrefix = "VDS-" }
            $null = Invoke-ClusterDeploymentIteration -Context $ctx
            @($Script:_phaseOrder)
        }
        $phaseOrder | Should -Contain "ClusterCreation"
        $phaseOrder | Should -Contain "SupervisorDeployment"
        [array]::IndexOf($phaseOrder, "ClusterCreation") | Should -BeLessThan ([array]::IndexOf($phaseOrder, "SupervisorDeployment"))
        [array]::IndexOf($phaseOrder, "EsxSetup") | Should -BeLessThan ([array]::IndexOf($phaseOrder, "ClusterCreation"))
    }
}

Describe "Initialize-VcfEdgeAtScale — Disconnect-Vcenter called on normal exit" {
    It "Calls Disconnect-Vcenter in the finally block after a successful run" {
        $disconnectCount = InModuleScope VcfEdgeAtScale {
            $Script:_disconnectNormal = 0
            function Get-InitializationConfigFromJson {
                [CmdletBinding()] Param([Parameter()] [Object]$EdgeSite, [Parameter()] [Object]$InfrastructureJson)
                return [PSCustomObject]@{ InputData = [PSCustomObject]@{ common = @{} }; LabEnvironment = $false; EsxUniquePassword = $false; NonInteractivePassword = $false; PreserveAutoGeneratedKeyCertPair = $false; DatacenterName = "dc1"; ContextName = "ctx1"; SupervisorContentLibraryDatastorePresent = $false; SupervisorContentLibraryDatastore = $null; SupervisorContentLibrarySubscriptionUrl = $null; ClusterNamePrefix = "cluster"; DatastoreNamePrefix = "datastore"; VdsNamePrefix = "vds"; SupervisorNamePrefix = "supervisor"; EsxUser = "root"; ClustersToProcess = @() }
            }
            function Get-VcfEdgeAtScaleVcfCmd { [CmdletBinding()] Param() }
            function Test-CommandAvailability { [CmdletBinding()] Param([Parameter()] [Object]$Command, [Parameter()] [Object]$Description) }
            function Test-VcenterAndEsxReachability { [CmdletBinding()] Param([Parameter()] [Object]$EsxHosts, [Parameter()] [Object]$Port, [Parameter()] [Object]$VcenterName) }
            function Get-AllEsxHostsFromClusters {
                [CmdletBinding()] Param([Parameter()] [Object]$ClustersToProcess)
                return [System.Collections.Generic.List[object]]::new()
            }
            function Invoke-VcenterConnectionAndValidation { [CmdletBinding()] Param([Parameter()] [Object]$MaximumSupervisorsPerVcenter, [Parameter()] [Object]$NonInteractivePassword, [Parameter()] [Object]$VcenterName, [Parameter()] [Object]$VcenterUser) }
            function Invoke-WitnessHostPreflightCheck { [CmdletBinding()] Param([Parameter()] [Object]$ClustersToProcess, [Parameter()] [Object]$InputData) }
            function Invoke-EsxCredentialCollection {
                [CmdletBinding()] Param([Parameter()] [Object]$AllEsxHosts, [Parameter()] [Object]$EsxUniquePassword, [Parameter()] [Object]$EsxUser, [Parameter()] [Object]$NonInteractivePassword)
                return @{ EsxPasswords = @{}; EsxUsedEnvPassword = $false }
            }
            function Invoke-EsxPreFlightVersionCheck { [CmdletBinding()] Param([Parameter()] [Object]$AllEsxHosts, [Parameter()] [Object]$EsxPasswords); return $false }
            function Disconnect-Vcenter {
                [CmdletBinding()] Param([Parameter()] [Switch]$AllServers, [Parameter()] [Switch]$Silence)
                begin { $Script:_disconnectNormal++ }
                process {}
            }
            Mock Write-LogMessage {}
            # -ComputeOnly exits cleanly after the (empty) cluster loop without requiring supervisor stubs.
            Initialize-VcfEdgeAtScale -InfrastructureJson "fake.json" -SupervisorJson "fake-sup.json" -ComputeOnly
            $Script:_disconnectNormal
        }
        $disconnectCount | Should -BeGreaterOrEqual 1
    }
}

Describe "Initialize-VcfEdgeAtScale — Disconnect-Vcenter called on exception" {
    It "Calls Disconnect-Vcenter in the finally block even when an exception is thrown" {
        $disconnectCount = InModuleScope VcfEdgeAtScale {
            $Script:_disconnectException = 0
            function Get-InitializationConfigFromJson {
                [CmdletBinding()] Param([Parameter()] [Object]$EdgeSite, [Parameter()] [Object]$InfrastructureJson)
                throw "simulated config load failure"
            }
            function Disconnect-Vcenter {
                [CmdletBinding()] Param([Parameter()] [Switch]$AllServers, [Parameter()] [Switch]$Silence)
                begin { $Script:_disconnectException++ }
                process {}
            }
            Mock Write-LogMessage {}
            try {
                Initialize-VcfEdgeAtScale -InfrastructureJson "fake.json" -SupervisorJson "fake-sup.json"
            } catch {}
            $Script:_disconnectException
        }
        $disconnectCount | Should -BeGreaterOrEqual 1
    }
}

Describe "Initialize-VcfEdgeAtScale — ShouldContinue=true advances to next cluster" {
    It "Runs both cluster iterations when the first iteration returns ShouldContinue=true" {
        $iterCount = InModuleScope VcfEdgeAtScale {
            $Script:_advanceIterCount = 0
            function Get-InitializationConfigFromJson {
                [CmdletBinding()] Param([Parameter()] [Object]$EdgeSite, [Parameter()] [Object]$InfrastructureJson)
                return [PSCustomObject]@{ InputData = [PSCustomObject]@{ common = @{} }; LabEnvironment = $false; EsxUniquePassword = $false; NonInteractivePassword = $false; PreserveAutoGeneratedKeyCertPair = $false; DatacenterName = "dc1"; ContextName = "ctx1"; SupervisorContentLibraryDatastorePresent = $false; SupervisorContentLibraryDatastore = $null; SupervisorContentLibrarySubscriptionUrl = $null; ClusterNamePrefix = "cluster"; DatastoreNamePrefix = "datastore"; VdsNamePrefix = "vds"; SupervisorNamePrefix = "supervisor"; EsxUser = "root"; ClustersToProcess = @(@{ edgeSite = "site1"; esxHosts = @() }, @{ edgeSite = "site2"; esxHosts = @() }) }
            }
            function Get-VcfEdgeAtScaleVcfCmd { [CmdletBinding()] Param() }
            function Test-CommandAvailability { [CmdletBinding()] Param([Parameter()] [Object]$Command, [Parameter()] [Object]$Description) }
            function Test-VcenterAndEsxReachability { [CmdletBinding()] Param([Parameter()] [Object]$EsxHosts, [Parameter()] [Object]$Port, [Parameter()] [Object]$VcenterName) }
            function Invoke-VcenterConnectionAndValidation { [CmdletBinding()] Param([Parameter()] [Object]$MaximumSupervisorsPerVcenter, [Parameter()] [Object]$NonInteractivePassword, [Parameter()] [Object]$VcenterName, [Parameter()] [Object]$VcenterUser) }
            function Invoke-WitnessHostPreflightCheck { [CmdletBinding()] Param([Parameter()] [Object]$ClustersToProcess, [Parameter()] [Object]$InputData) }
            function Invoke-EsxCredentialCollection { [CmdletBinding()] Param([Parameter()] [Object]$AllEsxHosts, [Parameter()] [Object]$EsxUniquePassword, [Parameter()] [Object]$EsxUser, [Parameter()] [Object]$NonInteractivePassword); return @{ EsxPasswords = @{}; EsxUsedEnvPassword = $false } }
            function Invoke-EsxPreFlightVersionCheck { [CmdletBinding()] Param([Parameter()] [Object]$AllEsxHosts, [Parameter()] [Object]$EsxPasswords); return $false }
            function Invoke-ClusterDeploymentIteration {
                [CmdletBinding()] Param([Parameter()] [Object]$Context)
                $Script:_advanceIterCount++
                # First call: continue to next site; subsequent calls: complete normally.
                if ($Script:_advanceIterCount -eq 1) { return @{ ShouldContinue = $true; EsxUsedEnvPassword = $false } }
                return @{ ShouldContinue = $false; EsxUsedEnvPassword = $false }
            }
            function Disconnect-Vcenter { [CmdletBinding()] Param([Parameter()] [Switch]$AllServers, [Parameter()] [Switch]$Silence) }
            Mock Write-LogMessage {}
            # -ComputeOnly exits cleanly after the cluster loop without requiring supervisor stubs.
            Initialize-VcfEdgeAtScale -InfrastructureJson "fake.json" -SupervisorJson "fake-sup.json" -ComputeOnly
            $Script:_advanceIterCount
        }
        $iterCount | Should -Be 2
    }
}

Describe "Initialize-VcfEdgeAtScale — CleanUp=Harbor resolves harbor YAML path" {
    It "Passes the harbor service YAML path to Invoke-VcfEdgeAtScaleCleanup when Harbor is enabled and CleanUp=Harbor" {
        $capturedPath = InModuleScope VcfEdgeAtScale {
            $Script:_capturedHarborYamlPath = $null
            function Get-InitializationConfigFromJson {
                [CmdletBinding()] Param([Parameter()] [Object]$EdgeSite, [Parameter()] [Object]$InfrastructureJson)
                return [PSCustomObject]@{ InputData = [PSCustomObject]@{ common = [PSCustomObject]@{}; clusters = @([PSCustomObject]@{ edgeSite = "site1" }) }; LabEnvironment = $false; EsxUniquePassword = $false; NonInteractivePassword = $false; PreserveAutoGeneratedKeyCertPair = $false; DatacenterName = "dc1"; ContextName = "ctx1"; SupervisorContentLibraryDatastorePresent = $false; SupervisorContentLibraryDatastore = $null; SupervisorContentLibrarySubscriptionUrl = $null; ClusterNamePrefix = "cluster"; DatastoreNamePrefix = "datastore"; VdsNamePrefix = "vds"; SupervisorNamePrefix = "supervisor"; EsxUser = "root"; ClustersToProcess = @([PSCustomObject]@{ edgeSite = "site1" }) }
            }
            function Get-VcfEdgeAtScaleVcfCmd { [CmdletBinding()] Param() }
            function Test-CommandAvailability { [CmdletBinding()] Param([Parameter()] [Object]$Command, [Parameter()] [Object]$Description) }
            function Test-VcenterAndEsxReachability { [CmdletBinding()] Param([Parameter()] [Object]$EsxHosts, [Parameter()] [Object]$Port, [Parameter()] [Object]$VcenterName) }
            function Invoke-VcenterConnectionAndValidation { [CmdletBinding()] Param([Parameter()] [Object]$MaximumSupervisorsPerVcenter, [Parameter()] [Object]$NonInteractivePassword, [Parameter()] [Object]$VcenterName, [Parameter()] [Object]$VcenterUser) }
            # Harbor is enabled (not disabled) so the harbor YAML path lookup runs.
            function Get-EffectiveSupervisorServiceFlag { [CmdletBinding()] Param([Parameter()] [Object]$Cluster, [Parameter()] [Object]$CommonData, [Parameter()] [Object]$FlagName); return $false }
            function Get-EffectiveSupervisorServicesYamlPath { [CmdletBinding()] Param([Parameter()] [Object]$Cluster, [Parameter()] [Object]$CommonData, [Parameter()] [Object]$LogicalYamlPathPropertyName); return "harbor-svc.yml" }
            function Invoke-VcfEdgeAtScaleCleanup {
                [CmdletBinding()] Param([Parameter()] [Object]$CleanUp, [Parameter()] [Object]$ClusterNamePrefix, [Parameter()] [Object]$ClustersToProcess, [Parameter()] [Object]$DatastoreNamePrefix, [Parameter()] [Object]$Force, [Parameter()] [Object]$HarborServiceYamlPath, [Parameter()] [Object]$InputData, [Parameter()] [Object]$LabEnvironment, [Parameter()] [Object]$SupervisorNamePrefix, [Parameter()] [Object]$VdsNamePrefix)
                $Script:_capturedHarborYamlPath = $HarborServiceYamlPath
            }
            function Disconnect-Vcenter { [CmdletBinding()] Param([Parameter()] [Switch]$AllServers, [Parameter()] [Switch]$Silence) }
            Mock Write-LogMessage {}
            Initialize-VcfEdgeAtScale -InfrastructureJson "fake.json" -SupervisorJson "fake-sup.json" -CleanUp "Harbor"
            $Script:_capturedHarborYamlPath
        }
        $capturedPath | Should -Be "harbor-svc.yml"
    }
}

Describe "Initialize-VcfEdgeAtScale — Invoke-ClusterDeploymentIteration throws — Disconnect-Vcenter still called" {
    It "Calls Disconnect-Vcenter in the finally block even when the cluster iteration throws" {
        $disconnectCount = InModuleScope VcfEdgeAtScale {
            $Script:_disconnectIterThrow = 0
            function Get-InitializationConfigFromJson {
                [CmdletBinding()] Param([Parameter()] [Object]$EdgeSite, [Parameter()] [Object]$InfrastructureJson)
                return [PSCustomObject]@{ InputData = [PSCustomObject]@{ common = @{} }; LabEnvironment = $false; EsxUniquePassword = $false; NonInteractivePassword = $false; PreserveAutoGeneratedKeyCertPair = $false; DatacenterName = "dc1"; ContextName = "ctx1"; SupervisorContentLibraryDatastorePresent = $false; SupervisorContentLibraryDatastore = $null; SupervisorContentLibrarySubscriptionUrl = $null; ClusterNamePrefix = "cluster"; DatastoreNamePrefix = "datastore"; VdsNamePrefix = "vds"; SupervisorNamePrefix = "supervisor"; EsxUser = "root"; ClustersToProcess = @(@{ edgeSite = "site1"; esxHosts = @() }) }
            }
            function Get-VcfEdgeAtScaleVcfCmd { [CmdletBinding()] Param() }
            function Test-CommandAvailability { [CmdletBinding()] Param([Parameter()] [Object]$Command, [Parameter()] [Object]$Description) }
            function Test-VcenterAndEsxReachability { [CmdletBinding()] Param([Parameter()] [Object]$EsxHosts, [Parameter()] [Object]$Port, [Parameter()] [Object]$VcenterName) }
            function Invoke-VcenterConnectionAndValidation { [CmdletBinding()] Param([Parameter()] [Object]$MaximumSupervisorsPerVcenter, [Parameter()] [Object]$NonInteractivePassword, [Parameter()] [Object]$VcenterName, [Parameter()] [Object]$VcenterUser) }
            function Invoke-WitnessHostPreflightCheck { [CmdletBinding()] Param([Parameter()] [Object]$ClustersToProcess, [Parameter()] [Object]$InputData) }
            function Invoke-EsxCredentialCollection { [CmdletBinding()] Param([Parameter()] [Object]$AllEsxHosts, [Parameter()] [Object]$EsxUniquePassword, [Parameter()] [Object]$EsxUser, [Parameter()] [Object]$NonInteractivePassword); return @{ EsxPasswords = @{}; EsxUsedEnvPassword = $false } }
            function Invoke-EsxPreFlightVersionCheck { [CmdletBinding()] Param([Parameter()] [Object]$AllEsxHosts, [Parameter()] [Object]$EsxPasswords); return $false }
            function Invoke-ClusterDeploymentIteration {
                [CmdletBinding()] Param([Parameter()] [Object]$Context)
                throw [VcfDeploymentException]::new("Cluster iteration simulated failure.")
            }
            function Disconnect-Vcenter {
                [CmdletBinding()] Param([Parameter()] [Switch]$AllServers, [Parameter()] [Switch]$Silence)
                begin { $Script:_disconnectIterThrow++ }
                process {}
            }
            Mock Write-LogMessage {}
            try {
                Initialize-VcfEdgeAtScale -InfrastructureJson "fake.json" -SupervisorJson "fake-sup.json"
            } catch {}
            $Script:_disconnectIterThrow
        }
        $disconnectCount | Should -BeGreaterOrEqual 1
    }
}

Describe "Initialize-VcfEdgeAtScale — ShouldContinue=false both clusters run to completion" {
    It "Processes both clusters when all iterations return ShouldContinue=false (clean completion)" {
        $iterCount = InModuleScope VcfEdgeAtScale {
            $Script:_normalIterCount = 0
            function Get-InitializationConfigFromJson {
                [CmdletBinding()] Param([Parameter()] [Object]$EdgeSite, [Parameter()] [Object]$InfrastructureJson)
                return [PSCustomObject]@{ InputData = [PSCustomObject]@{ common = @{} }; LabEnvironment = $false; EsxUniquePassword = $false; NonInteractivePassword = $false; PreserveAutoGeneratedKeyCertPair = $false; DatacenterName = "dc1"; ContextName = "ctx1"; SupervisorContentLibraryDatastorePresent = $false; SupervisorContentLibraryDatastore = $null; SupervisorContentLibrarySubscriptionUrl = $null; ClusterNamePrefix = "cluster"; DatastoreNamePrefix = "datastore"; VdsNamePrefix = "vds"; SupervisorNamePrefix = "supervisor"; EsxUser = "root"; ClustersToProcess = @(@{ edgeSite = "site1"; esxHosts = @() }, @{ edgeSite = "site2"; esxHosts = @() }) }
            }
            function Get-VcfEdgeAtScaleVcfCmd { [CmdletBinding()] Param() }
            function Test-CommandAvailability { [CmdletBinding()] Param([Parameter()] [Object]$Command, [Parameter()] [Object]$Description) }
            function Test-VcenterAndEsxReachability { [CmdletBinding()] Param([Parameter()] [Object]$EsxHosts, [Parameter()] [Object]$Port, [Parameter()] [Object]$VcenterName) }
            function Invoke-VcenterConnectionAndValidation { [CmdletBinding()] Param([Parameter()] [Object]$MaximumSupervisorsPerVcenter, [Parameter()] [Object]$NonInteractivePassword, [Parameter()] [Object]$VcenterName, [Parameter()] [Object]$VcenterUser) }
            function Invoke-WitnessHostPreflightCheck { [CmdletBinding()] Param([Parameter()] [Object]$ClustersToProcess, [Parameter()] [Object]$InputData) }
            function Invoke-EsxCredentialCollection { [CmdletBinding()] Param([Parameter()] [Object]$AllEsxHosts, [Parameter()] [Object]$EsxUniquePassword, [Parameter()] [Object]$EsxUser, [Parameter()] [Object]$NonInteractivePassword); return @{ EsxPasswords = @{}; EsxUsedEnvPassword = $false } }
            function Invoke-EsxPreFlightVersionCheck { [CmdletBinding()] Param([Parameter()] [Object]$AllEsxHosts, [Parameter()] [Object]$EsxPasswords); return $false }
            function Invoke-ClusterDeploymentIteration {
                [CmdletBinding()] Param([Parameter()] [Object]$Context)
                $Script:_normalIterCount++
                return @{ ShouldContinue = $false; EsxUsedEnvPassword = $false }
            }
            function Disconnect-Vcenter { [CmdletBinding()] Param([Parameter()] [Switch]$AllServers, [Parameter()] [Switch]$Silence) }
            Mock Write-LogMessage {}
            Initialize-VcfEdgeAtScale -InfrastructureJson "fake.json" -SupervisorJson "fake-sup.json" -ComputeOnly
            $Script:_normalIterCount
        }
        $iterCount | Should -Be 2
    }
}

Describe "Get-AllEsxHostsFromClusters" {

    It "Returns de-duplicated ESX host list from multiple clusters" {
        InModuleScope VcfEdgeAtScale {
            $clusters = @(
                [PSCustomObject]@{ esxHosts = @("esx01.lab", "esx02.lab") },
                [PSCustomObject]@{ esxHosts = @("esx02.lab", "esx03.lab") }
            )
            $result = Get-AllEsxHostsFromClusters -ClustersToProcess $clusters
            $result.Count | Should -Be 3
            $result | Should -Contain "esx01.lab"
            $result | Should -Contain "esx02.lab"
            $result | Should -Contain "esx03.lab"
        }
    }

    It "Returns empty list when no cluster has esxHosts" {
        InModuleScope VcfEdgeAtScale {
            $clusters = @([PSCustomObject]@{ esxHosts = @() })
            $result = Get-AllEsxHostsFromClusters -ClustersToProcess $clusters
            $result.Count | Should -Be 0
        }
    }
}

Describe "Invoke-PreDeployCleanupIfRequested" {

    It "Returns false and does not call cleanup when CleanUp is not in supported set" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Invoke-VcfEdgeAtScaleCleanup {}
            Mock Get-EffectiveSupervisorServiceFlag { $true }
            $inputData = [PSCustomObject]@{ common = [PSCustomObject]@{} }
            $result = Invoke-PreDeployCleanupIfRequested `
                -CleanUp "InvalidScope" `
                -ClusterNamePrefix "cl-" `
                -ClustersToProcess @([PSCustomObject]@{}) `
                -DatastoreNamePrefix "ds-" `
                -InputData $inputData `
                -SupervisorNamePrefix "sup-" `
                -VdsNamePrefix "vds-"
            $result | Should -Be $false
            Should -Invoke Invoke-VcfEdgeAtScaleCleanup -Times 0 -Scope It
        }
    }

    It "Returns true and calls Invoke-VcfEdgeAtScaleCleanup when CleanUp=Supervisor" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Invoke-VcfEdgeAtScaleCleanup {}
            Mock Get-EffectiveSupervisorServiceFlag { $true }
            $inputData = [PSCustomObject]@{ common = [PSCustomObject]@{} }
            $result = Invoke-PreDeployCleanupIfRequested `
                -CleanUp "Supervisor" `
                -ClusterNamePrefix "cl-" `
                -ClustersToProcess @([PSCustomObject]@{}) `
                -DatastoreNamePrefix "ds-" `
                -InputData $inputData `
                -SupervisorNamePrefix "sup-" `
                -VdsNamePrefix "vds-"
            $result | Should -Be $true
            Should -Invoke Invoke-VcfEdgeAtScaleCleanup -Times 1 -Scope It
        }
    }
}

Describe "Assert-ContextKeys — all required keys present" {
    It "Does not throw when all required keys are present and non-null" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $ctx = @{ ClusterName = "cl0"; StoragePolicyType = "vSAN-ESA"; EsxHosts = @("esx1") }
            { Assert-ContextKeys -CallerName "Test-Caller" -Context $ctx -RequiredKeys @("ClusterName", "StoragePolicyType", "EsxHosts") } | Should -Not -Throw
        }
    }
}

Describe "Assert-ContextKeys — missing required key" {
    It "Throws VcfDeploymentException and logs ERROR when a required key is absent" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $ctx = @{ ClusterName = "cl0" }
            { Assert-ContextKeys -CallerName "Test-Caller" -Context $ctx -RequiredKeys @("ClusterName", "MissingKey") } |
                Should -Throw -ExceptionType ([VcfDeploymentException])
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "ERROR" -and $Message -match "MissingKey" }
        }
    }
}

Describe "Assert-ContextKeys — null value for required key" {
    It "Throws VcfDeploymentException when a required key is present but null" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $ctx = @{ ClusterName = "cl0"; StoragePolicyType = $null }
            { Assert-ContextKeys -CallerName "Test-Caller" -Context $ctx -RequiredKeys @("ClusterName", "StoragePolicyType") } |
                Should -Throw -ExceptionType ([VcfDeploymentException])
        }
    }
}

Describe "Assert-StoragePolicyReady — compatible storage found" {
    It "Does not throw when at least one compatible datastore exists" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            function Get-SpbmStoragePolicy {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process { return [PSCustomObject]@{ Name = $Name } }
            }
            function Get-SpbmCompatibleStorage {
                [CmdletBinding()] Param([Parameter()] [Object]$StoragePolicy, [Parameter()] [Object]$Server)
                process { return @([PSCustomObject]@{ Name = "ds-supervisor" }) }
            }
            Mock Get-SpbmStoragePolicy { [PSCustomObject]@{ Name = "supervisor-site1" } }
            Mock Get-SpbmCompatibleStorage { @([PSCustomObject]@{ Name = "ds-supervisor" }) }
            { Assert-StoragePolicyReady -StoragePolicyName "supervisor-site1" -StoragePolicyTagCatalog "vSAN-ESA-Storage-TagCatalog" } | Should -Not -Throw
        }
    }
}

Describe "Assert-StoragePolicyReady — no compatible storage" {
    It "Throws VcfDeploymentException and logs ERROR when no compatible datastores exist" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            function Get-SpbmStoragePolicy {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process { return [PSCustomObject]@{ Name = $Name } }
            }
            function Get-SpbmCompatibleStorage {
                [CmdletBinding()] Param([Parameter()] [Object]$StoragePolicy, [Parameter()] [Object]$Server)
                process { return @() }
            }
            Mock Get-SpbmStoragePolicy { [PSCustomObject]@{ Name = "supervisor-site1" } }
            Mock Get-SpbmCompatibleStorage { @() }
            { Assert-StoragePolicyReady -StoragePolicyName "supervisor-site1" -StoragePolicyTagCatalog "vSAN-ESA-Storage-TagCatalog" } |
                Should -Throw -ExceptionType ([VcfDeploymentException])
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "ERROR" }
        }
    }
}

Describe "Assert-StoragePolicyReady — Get-SpbmCompatibleStorage throws" {
    It "Throws VcfDeploymentException when Get-SpbmCompatibleStorage itself throws" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            function Get-SpbmStoragePolicy {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process { return [PSCustomObject]@{ Name = $Name } }
            }
            Mock Get-SpbmStoragePolicy { [PSCustomObject]@{ Name = "supervisor-site1" } }
            Mock Get-SpbmCompatibleStorage { throw [System.Exception]::new("vCenter error") }
            { Assert-StoragePolicyReady -StoragePolicyName "supervisor-site1" -StoragePolicyTagCatalog "vSAN-ESA-Storage-TagCatalog" } |
                Should -Throw -ExceptionType ([VcfDeploymentException])
        }
    }
}

Describe "Invoke-VmfsPreSupervisorRollbackCore — happy path calls teardown helpers" {
    It "Calls Remove-NonVmk0VmkernelInterfacesFromVds, Invoke-ManagementRestoreForCleanupWithTopologyFallback, and Remove-VdsTrioAndCluster" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Remove-NonVmk0VmkernelInterfacesFromVds {}
            Mock Invoke-ManagementRestoreForCleanupWithTopologyFallback {
                [PSCustomObject]@{ RestoreAttempted = $true; Success = $true }
            }
            Mock Remove-VdsTrioAndCluster {}
            Mock Remove-DatastoreByName {}
            Invoke-VmfsPreSupervisorRollbackCore `
                -ClusterName "cl0" `
                -CurrentEdgeSite "site1" `
                -DatastoreName "ds-cl0" `
                -NicListCountForRestore 2 `
                -VdsName "cl0-vds" `
                -VdsNamesForCleanup @("cl0-vds")
            Should -Invoke Remove-NonVmk0VmkernelInterfacesFromVds -Times 1 -Scope It
            Should -Invoke Invoke-ManagementRestoreForCleanupWithTopologyFallback -Times 1 -Scope It
        }
    }
}

Describe "Invoke-VmfsPreSupervisorRollbackCore — non-fatal errors do not throw" {
    It "Does not throw when Remove-NonVmk0VmkernelInterfacesFromVds throws (non-fatal path)" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Remove-NonVmk0VmkernelInterfacesFromVds { throw [VcfDeploymentException]::new("vmk removal failed") }
            Mock Invoke-ManagementRestoreForCleanupWithTopologyFallback {
                [PSCustomObject]@{ RestoreAttempted = $true; Success = $true }
            }
            Mock Remove-VdsTrioAndCluster {}
            Mock Remove-DatastoreByName {}
            { Invoke-VmfsPreSupervisorRollbackCore `
                -ClusterName "cl0" `
                -CurrentEdgeSite "site1" `
                -DatastoreName "ds-cl0" `
                -NicListCountForRestore 2 `
                -VdsName "cl0-vds" `
                -VdsNamesForCleanup @("cl0-vds") } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "WARNING" }
        }
    }
}

# ── M6: Remove-VdsTrioAndCluster — partial VDS failure ───────────────────────


Describe "Remove-VdsTrioAndCluster — VDS removal failure skips cluster" {

    It "Skips cluster removal when a VDS removal fails" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Remove-EdgeClusterDistributedSwitch { throw "VDS remove failed" }
            Mock Remove-ClusterSafely {}
            $null = Remove-VdsTrioAndCluster -ClusterName "cl0" -VdsNamesForCleanup @("cl0-vds")
            Should -Invoke Remove-ClusterSafely -Times 0 -Scope It
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "WARNING" -and $Message -match "skipping cluster removal" }
        }
    }

    It "Removes cluster when all VDS removals succeed" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Remove-EdgeClusterDistributedSwitch {}
            Mock Remove-ClusterSafely {}
            Remove-VdsTrioAndCluster -ClusterName "cl0" -VdsNamesForCleanup @("cl0-vds")
            Should -Invoke Remove-ClusterSafely -Times 1 -Scope It
        }
    }
}

# ── M7: Invoke-ClusterRollbackPhase — 4-NIC restore VDS selection ────────────


Describe "Invoke-ClusterRollbackPhase — 4-NIC restore VDS selection" {

    It "Passes NicListCount=4 to restore helper when cluster has 4 NICs" {
        $capturedNicListCount = InModuleScope VcfEdgeAtScale {
            $Script:_nicListCountCaptured = $null
            Mock Write-LogMessage {}
            Mock Get-SupervisorNameFromPrefix { return "sup-site1" }
            Mock Get-VdsNameFromPrefix { return "VDS-site1" }
            Mock Get-EffectiveNicListForCluster { return @("vmnic0", "vmnic1", "vmnic2", "vmnic3") }
            Mock Remove-NonVmk0VmkernelInterfacesFromVds {}
            Mock Invoke-ManagementRestoreForCleanupWithTopologyFallback {
                $Script:_nicListCountCaptured = $NicListCount
                return [PSCustomObject]@{ RestoreAttempted = $false; Success = $true; Message = "" }
            }
            Mock Invoke-VdsTrioRemoval { return $true }
            Mock Get-DatastoreNameFromPrefix { return "ds-site1" }
            Mock Remove-ClusterWithExistenceRetry { return $false }
            Mock Remove-VmfsDatastoreForCluster {}

            $fakeSpec  = [PSCustomObject]@{ esxHosts = @(); vSanWitnessVmName = "" }
            $fakeInput = [PSCustomObject]@{
                common = [PSCustomObject]@{ nicList = @("vmnic0","vmnic1","vmnic2","vmnic3"); vSanWitnessVmName = "" }
            }
            $null = Invoke-ClusterRollbackPhase -ClusterName "cl-site1" -ClusterSpec $fakeSpec `
                -DatastoreNamePrefix "ds" -EdgeSite "site1" -InputData $fakeInput `
                -StoragePolicyType "VMFS" -SupervisorNamePrefix "sup" -VdsNamePrefix "VDS"
            $Script:_nicListCountCaptured
        }
        $capturedNicListCount | Should -Be 4
    }
}

# ── M8: Invoke-VmfsEsxDiscovery — VMFS datastore discovery ───────────────────


Describe "Invoke-VmfsEsxDiscovery — VMFS datastore discovery" {

    It "Returns DiskCanonicalName from Find-Datastore when ESX connection succeeds" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Connect-Vcenter {}
            Mock Disconnect-Vcenter {}
            Mock Test-ESXVersion { [PSCustomObject]@{ Success = $true; ErrorMessage = "" } }
            Mock Find-Datastore { return "naa.600000000000001" }

            $fakeCred = [PSCredential]::new("root", (ConvertTo-SecureString "pass" -AsPlainText -Force))
            $ctx = @{
                DatastoreName = "ds-vmfs-edge1"
                EsxHosts      = @("esx01.lab")
                EsxUser       = "root"
            }
            $esxPasswords     = @{ "esx01.lab" = $fakeCred }
            $esxVersionChecked = @{ "esx01.lab" = $true }

            Invoke-VmfsEsxDiscovery -Context $ctx -EsxPasswords $esxPasswords `
                -EsxVersionChecked $esxVersionChecked -EsxUsedEnvPassword:$false
        }
        $result.DiskCanonicalName | Should -Be "naa.600000000000001"
    }
}

# ── Invoke-PostSupervisorDeploymentActions ────────────────────────────────────


Describe "Invoke-PostSupervisorDeploymentActions — ArgoCD and Harbor dispatch" {

    It "Calls Invoke-ArgoCDDeploymentPhase when SkipArgoCDDeployment is false" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Write-ClusterEsxiNodeHealthReport {}
            Mock Write-SupervisorHealthReport {}
            Mock Invoke-VsanClusterHealthRetestAfterDeployment {}
            Mock Write-VsanClusterHealthReport {}
            Mock Invoke-ArgoCDDeploymentPhase { return "vmclass-001" }
            Mock Invoke-HarborDeploymentPhase { return "harbor-svc-1" }
            $ctx = @{
                ArgoCdDeploymentYamlPath     = "argocd.yaml"
                ArgoCDyaml                   = "argocd-op.yaml"
                ArgocdVmClass                = $null
                Cluster                      = [PSCustomObject]@{ edgeSite = "site1" }
                ContextName                  = "ctx1"
                InputData                    = [PSCustomObject]@{ common = [PSCustomObject]@{} }
                LabEnvironment               = $false
                PreserveAutoGeneratedKeyCert = $false
                SaveHarborYaml               = $false
                StoragePolicyId              = "spbm-001"
                StoragePolicyName            = "sup-site1"
                StoragePolicyType            = "VMFS"
                VcenterCredential            = [PSCredential]::new("u", (ConvertTo-SecureString "p" -AsPlainText -Force))
            }
            Invoke-PostSupervisorDeploymentActions -ArgocdNameSpace "argocd-ns" -ClusterId "domain-c1" `
                -ClusterName "cl-site1" -Context $ctx -CurrentEdgeSite "site1" `
                -SkipArgoCDDeployment:$false -SkipHarborDeployment:$false -SupervisorId "sup-001"
            Should -Invoke Invoke-ArgoCDDeploymentPhase -Times 1 -Scope It
        }
    }

    It "Does not call Invoke-ArgoCDDeploymentPhase when SkipArgoCDDeployment is true" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Write-ClusterEsxiNodeHealthReport {}
            Mock Write-SupervisorHealthReport {}
            Mock Invoke-VsanClusterHealthRetestAfterDeployment {}
            Mock Write-VsanClusterHealthReport {}
            Mock Invoke-ArgoCDDeploymentPhase { return "vmclass-001" }
            Mock Invoke-HarborDeploymentPhase { return "harbor-svc-1" }
            $ctx = @{
                ArgoCdDeploymentYamlPath     = "argocd.yaml"
                ArgoCDyaml                   = "argocd-op.yaml"
                ArgocdVmClass                = $null
                Cluster                      = [PSCustomObject]@{ edgeSite = "site1" }
                ContextName                  = "ctx1"
                InputData                    = [PSCustomObject]@{ common = [PSCustomObject]@{} }
                LabEnvironment               = $false
                PreserveAutoGeneratedKeyCert = $false
                SaveHarborYaml               = $false
                StoragePolicyId              = "spbm-001"
                StoragePolicyName            = "sup-site1"
                StoragePolicyType            = "VMFS"
                VcenterCredential            = [PSCredential]::new("u", (ConvertTo-SecureString "p" -AsPlainText -Force))
            }
            Invoke-PostSupervisorDeploymentActions -ArgocdNameSpace "argocd-ns" -ClusterId "domain-c1" `
                -ClusterName "cl-site1" -Context $ctx -CurrentEdgeSite "site1" `
                -SkipArgoCDDeployment:$true -SkipHarborDeployment:$false -SupervisorId "sup-001"
            Should -Invoke Invoke-ArgoCDDeploymentPhase -Times 0 -Scope It
        }
    }

    It "Does not call Invoke-HarborDeploymentPhase when SkipHarborDeployment is true" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Write-ClusterEsxiNodeHealthReport {}
            Mock Write-SupervisorHealthReport {}
            Mock Invoke-VsanClusterHealthRetestAfterDeployment {}
            Mock Write-VsanClusterHealthReport {}
            Mock Invoke-ArgoCDDeploymentPhase { return "vmclass-001" }
            Mock Invoke-HarborDeploymentPhase { return "harbor-svc-1" }
            $ctx = @{
                ArgoCdDeploymentYamlPath     = "argocd.yaml"
                ArgoCDyaml                   = "argocd-op.yaml"
                ArgocdVmClass                = $null
                Cluster                      = [PSCustomObject]@{ edgeSite = "site1" }
                ContextName                  = "ctx1"
                InputData                    = [PSCustomObject]@{ common = [PSCustomObject]@{} }
                LabEnvironment               = $false
                PreserveAutoGeneratedKeyCert = $false
                SaveHarborYaml               = $false
                StoragePolicyId              = "spbm-001"
                StoragePolicyName            = "sup-site1"
                StoragePolicyType            = "VMFS"
                VcenterCredential            = [PSCredential]::new("u", (ConvertTo-SecureString "p" -AsPlainText -Force))
            }
            Invoke-PostSupervisorDeploymentActions -ArgocdNameSpace "argocd-ns" -ClusterId "domain-c1" `
                -ClusterName "cl-site1" -Context $ctx -CurrentEdgeSite "site1" `
                -SkipArgoCDDeployment:$false -SkipHarborDeployment:$true -SupervisorId "sup-001"
            Should -Invoke Invoke-HarborDeploymentPhase -Times 0 -Scope It
        }
    }
}

# ── Invoke-VsanPreProvisioningConfig ─────────────────────────────────────────


Describe "Invoke-VsanPreProvisioningConfig — vSAN configuration functions" {

    It "Calls Enable-VsanAutomaticRebalance when rebalance is not at 30 percent for vSAN-ESA" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Enable-VsanAutomaticDiskClaimIfSupported { return $true }
            Mock Get-VsanClusterHealthSummaryViaView { [PSCustomObject]@{ overallHealth = "green" } }
            Mock Test-VsanClusterAdvCfgSyncInSync { return $true }
            Mock Test-VsanAutomaticRebalanceAtThreshold { return $false }
            Mock Enable-VsanAutomaticRebalance { return $true }
            Invoke-VsanPreProvisioningConfig -ClusterName "cl-esa"
            Should -Invoke Enable-VsanAutomaticRebalance -Times 1 -Scope It
        }
    }

    It "Calls Invoke-VsanClusterConfigReapply when advCfg is out of sync for vSAN-OSA" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Enable-VsanAutomaticDiskClaimIfSupported { return $true }
            Mock Get-VsanClusterHealthSummaryViaView { [PSCustomObject]@{ overallHealth = "yellow" } }
            Mock Test-VsanClusterAdvCfgSyncInSync { return $false }
            Mock Test-VsanAutomaticRebalanceAtThreshold { return $true }
            Mock Invoke-VsanClusterConfigReapply { return $true }
            Invoke-VsanPreProvisioningConfig -ClusterName "cl-osa"
            Should -Invoke Invoke-VsanClusterConfigReapply -Times 1 -Scope It
        }
    }
}

# ── Invoke-VsanEsxCredentialValidation ───────────────────────────────────────


Describe "Invoke-VsanEsxCredentialValidation — credential validation loop" {

    It "Returns updated EsxUsedEnvPassword when validation succeeds for all hosts" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Connect-Vcenter {}
            Mock Disconnect-Vcenter {}
            Mock Test-ESXVersion { [PSCustomObject]@{ Success = $true; ErrorMessage = "" } }
            $fakeCred = [PSCredential]::new("root", (ConvertTo-SecureString "pass" -AsPlainText -Force))
            $ctx = @{ EsxHosts = @("esx01.lab", "esx02.lab"); EsxUser = "root"; StoragePolicyType = "vSAN-ESA" }
            $esxPasswords      = @{ "esx01.lab" = $fakeCred; "esx02.lab" = $fakeCred }
            $esxVersionChecked = @{ "esx01.lab" = $false; "esx02.lab" = $false }
            Invoke-VsanEsxCredentialValidation -Context $ctx -EsxPasswords $esxPasswords `
                -EsxVersionChecked $esxVersionChecked -MaxValidationRetries 3
        }
        $result | Should -Be $false
    }
}

# ── Invoke-AllCleanupServicePreRemoval ────────────────────────────────────────


Describe "Invoke-AllCleanupServicePreRemoval — Harbor and ArgoCD pre-removal" {

    It "Calls Remove-HarborSupervisorService when HarborServiceYamlPath resolves a valid service ID" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $fakeYaml = [System.IO.Path]::GetTempFileName()
            Set-Content -Path $fakeYaml -Value "harbor: true"
            function Get-ArgoCDServiceDetail {
                [CmdletBinding()] Param([Parameter()] [String]$Path)
                return @("harbor-svc-id", $null)
            }
            Mock Remove-HarborSupervisorService {}
            function Get-ArgoCDNamespaceFromCluster {
                [CmdletBinding()] Param([Parameter()] [Object]$ClusterObject, [Parameter()] [Object]$ClusterSpec)
                return "argocd-ns-cl0"
            }
            function Invoke-ListNamespacesInstances {
                [CmdletBinding()] Param()
                return [PSCustomObject]@{ Namespace = @() }
            }
            $fakeClusterObj  = [PSCustomObject]@{ Name = "cl0" }
            $fakeClusterSpec = [PSCustomObject]@{ edgeSite = "edge1" }
            Invoke-AllCleanupServicePreRemoval -ClusterName "cl0" -ClusterObject $fakeClusterObj `
                -ClusterSpec $fakeClusterSpec -HarborServiceYamlPath $fakeYaml -SupervisorId "sup-001" `
                -HarborDeletePollSec 10 -HarborDeleteTimeoutSec 10 -ArgoCDDeletePollSec 5 -ArgoCDDeleteTimeoutSec 10
            Remove-Item $fakeYaml -Force
            Should -Invoke Remove-HarborSupervisorService -Times 1 -Scope It
        }
    }

    It "Calls Invoke-ArgoCDNamespaceDeleteAndPoll when ArgoCD namespace exists" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            function Get-ArgoCDServiceDetail {
                [CmdletBinding()] Param([Parameter()] [String]$Path)
                return @($null, $null)
            }
            function Get-ArgoCDNamespaceFromCluster {
                [CmdletBinding()] Param([Parameter()] [Object]$ClusterObject, [Parameter()] [Object]$ClusterSpec)
                return "argocd-ns-cl0"
            }
            function Invoke-ListNamespacesInstances {
                [CmdletBinding()] Param()
                return [PSCustomObject]@{ Namespace = @("argocd-ns-cl0") }
            }
            Mock Invoke-ArgoCDNamespaceDeleteAndPoll {}
            $fakeClusterObj  = [PSCustomObject]@{ Name = "cl0" }
            $fakeClusterSpec = [PSCustomObject]@{ edgeSite = "edge1" }
            Invoke-AllCleanupServicePreRemoval -ClusterName "cl0" -ClusterObject $fakeClusterObj `
                -ClusterSpec $fakeClusterSpec -HarborServiceYamlPath "" -SupervisorId "sup-001" `
                -HarborDeletePollSec 10 -HarborDeleteTimeoutSec 10 -ArgoCDDeletePollSec 5 -ArgoCDDeleteTimeoutSec 10
            Should -Invoke Invoke-ArgoCDNamespaceDeleteAndPoll -Times 1 -Scope It
        }
    }
}

# ── Invoke-SupervisorPhaseRollback ────────────────────────────────────────────


Describe "Invoke-SupervisorPhaseRollback — rollback dispatch" {

    It "Calls Invoke-SupervisorOnlyRollback when no ArgoCD or Harbor phase started" {
        { InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Invoke-SupervisorOnlyRollback {}
            $Script:RollbackFailed   = $false
            $Script:RollbackAttempted = $false
            $Script:HarborPhaseStarted  = $false
            $Script:ArgoCDPhaseStarted  = $false
            Invoke-SupervisorPhaseRollback -ClusterId "domain-c1" -ClusterName "cl-site1" `
                -CurrentEdgeSite "site1" -SupervisorId "sup-001" `
                -SupervisorCreatedThisSite:$true -SupervisorCreationAttemptedThisSite:$true
        } } | Should -Throw
        InModuleScope VcfEdgeAtScale {
            Should -Invoke Invoke-SupervisorOnlyRollback -Times 1 -Scope Describe
        }
    }

    It "Calls Invoke-ArgoCDOnlyRollback when ArgoCDPhaseStarted is true" {
        { InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Invoke-ArgoCDOnlyRollback {}
            $Script:RollbackFailed   = $false
            $Script:RollbackAttempted = $false
            $Script:HarborPhaseStarted  = $false
            $Script:ArgoCDPhaseStarted  = $true
            Invoke-SupervisorPhaseRollback -ArgocdNameSpace "argocd-ns" -ClusterId "domain-c1" `
                -ClusterName "cl-site1" -CurrentEdgeSite "site1" -SupervisorId "sup-001" `
                -SupervisorCreatedThisSite:$true -SupervisorCreationAttemptedThisSite:$true
        } } | Should -Throw
        InModuleScope VcfEdgeAtScale {
            Should -Invoke Invoke-ArgoCDOnlyRollback -Times 1 -Scope Describe
        }
    }
}

# ── Set-VsanTrafficOnClusterHosts ─────────────────────────────────────────────


Describe "Set-VsanTrafficOnClusterHosts — HasDedicatedVsanWitness permutations" {

    It "Enables vSAN witness traffic on vmk0 when HasDedicatedVsanWitness is null" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $fakeVmk0 = [PSCustomObject]@{ Name = "vmk0"; VsanTrafficEnabled = $false }
            Add-Member -InputObject $fakeVmk0 -MemberType NoteProperty -Name VsanWitnessEnabled -Value $false
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            function Get-Cluster {
                [CmdletBinding()] Param([Parameter()] [String]$Name, [Parameter()] [Object]$Server)
                return [PSCustomObject]@{ Name = $Name }
            }
            function Get-VMHost {
                [CmdletBinding()] Param([Parameter()] [Object]$Location, [Parameter()] [Object]$Server)
                return @($fakeHost)
            }
            function Get-VMHostNetworkAdapter {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$VMKernel, [Parameter()] [Object]$Server)
                return @($fakeVmk0)
            }
            Mock Test-VmkernelVsanAndWitnessTraffic { [PSCustomObject]@{ HasCompliantInterface = $true } }
            $Script:_witnessCallCount = 0
            function Set-VMHostNetworkAdapter {
                [CmdletBinding(SupportsShouldProcess = $true)] Param(
                    [Parameter()] [Object]$VirtualNic,
                    [Parameter()] [Object]$VsanWitnessEnabled,
                    [Parameter()] [Object]$VsanTrafficEnabled
                )
                if ($VsanWitnessEnabled -eq $true) { $Script:_witnessCallCount++ }
                return $fakeVmk0
            }
            Set-VsanTrafficOnClusterHosts -ClusterName "cl1" -HasDedicatedVsanWitness $null `
                -VsanRecheckDelaySeconds 1 -VsanRecheckInitialDelaySeconds 1 -VsanRecheckRetryCount 0
            $Script:_witnessCallCount | Should -Be 1
        }
    }

    It "Skips enabling witness traffic on vmk0 when HasDedicatedVsanWitness is provided" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $fakeVmk0 = [PSCustomObject]@{ Name = "vmk0"; VsanTrafficEnabled = $false }
            Add-Member -InputObject $fakeVmk0 -MemberType NoteProperty -Name VsanWitnessEnabled -Value $false
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            function Get-Cluster {
                [CmdletBinding()] Param([Parameter()] [String]$Name, [Parameter()] [Object]$Server)
                return [PSCustomObject]@{ Name = $Name }
            }
            function Get-VMHost {
                [CmdletBinding()] Param([Parameter()] [Object]$Location, [Parameter()] [Object]$Server)
                return @($fakeHost)
            }
            function Get-VMHostNetworkAdapter {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$VMKernel, [Parameter()] [Object]$Server)
                return @($fakeVmk0)
            }
            Mock Set-VMHostNetworkAdapter { return $fakeVmk0 }
            Mock Test-VmkernelVsanAndWitnessTraffic { [PSCustomObject]@{ HasCompliantInterface = $true } }
            Set-VsanTrafficOnClusterHosts -ClusterName "cl1" -HasDedicatedVsanWitness "vmk3" `
                -VsanRecheckDelaySeconds 1 -VsanRecheckInitialDelaySeconds 1 -VsanRecheckRetryCount 0
            Should -Invoke Set-VMHostNetworkAdapter -Times 0 -Scope It `
                -ParameterFilter { $VsanWitnessEnabled -eq $true }
        }
    }
}
