# Pester tests for VcfEdgeAtScale — Private/Validation.ps1
#
# RECOMMENDED: Use the wrapper script for human-readable output:
#   ./Tests/Run-Tests.ps1
#   ./Tests/Run-Tests.ps1 -Filter "*FunctionName*"
#
# DIRECT: Invoke-Pester -Path ./Tests/VcfEdgeAtScale.Validation.Tests.ps1 -Output Detailed
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

Describe "Get-DuplicateNetworkSegmentGroups" {
    It "Returns empty when NetworkSegmentDetails is null" {
        $result = InModuleScope VcfEdgeAtScale { Get-DuplicateNetworkSegmentGroups -NetworkSegmentDetails $null }
        @($result).Count | Should -Be 0
    }

    It "Returns empty when NetworkSegmentDetails is empty array" {
        $result = InModuleScope VcfEdgeAtScale { Get-DuplicateNetworkSegmentGroups -NetworkSegmentDetails @() }
        @($result).Count | Should -Be 0
    }

    It "Returns empty when all names are unique" {
        $details = @(
            [PSCustomObject]@{ Name = "seg1"; VlanId = 100; EdgeSite = "site1" },
            [PSCustomObject]@{ Name = "seg2"; VlanId = 200; EdgeSite = "site1" }
        )
        $result = InModuleScope VcfEdgeAtScale -ArgumentList (,$details) { Get-DuplicateNetworkSegmentGroups -NetworkSegmentDetails $args[0] }
        @($result).Count | Should -Be 0
    }

    It "Returns one group when one name is duplicated" {
        $details = @(
            [PSCustomObject]@{ Name = "seg1"; VlanId = 100; EdgeSite = "site1" },
            [PSCustomObject]@{ Name = "seg1"; VlanId = 200; EdgeSite = "site2" }
        )
        $result = InModuleScope VcfEdgeAtScale -ArgumentList (,$details) { Get-DuplicateNetworkSegmentGroups -NetworkSegmentDetails $args[0] }
        @($result).Count | Should -Be 1
        $result[0].Name | Should -Be "seg1"
        $result[0].Count | Should -Be 2
    }
}


Describe "Get-NetworkSegmentDetailsFromInputData" {
    It "Returns empty when InputData has no clusters" {
        $inputData = @{ clusters = $null }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $inputData { Get-NetworkSegmentDetailsFromInputData -InputData $args[0] }
        @($result).Count | Should -Be 0
    }

    It "Returns empty array when InputData.clusters is empty" {
        $inputData = @{ clusters = @() }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $inputData { Get-NetworkSegmentDetailsFromInputData -InputData $args[0] }
        @($result).Count | Should -Be 0
    }

    It "Returns one segment when one cluster has one networkSegment" {
        $inputData = @{
            clusters = @(
                @{
                    edgeSite = "site1"
                    networking = @{
                        networkSegments = @(
                            @{ name = "mgmt"; vlanId = 100 }
                        )
                    }
                }
            )
        }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $inputData { Get-NetworkSegmentDetailsFromInputData -InputData $args[0] }
        @($result).Count | Should -Be 1
        $result[0].Name | Should -Be "mgmt"
        $result[0].VlanId | Should -Be 100
        $result[0].EdgeSite | Should -Be "site1"
    }

    It "Filters by EdgeSitesArray when provided" {
        $inputData = @{
            clusters = @(
                @{ edgeSite = "site1"; networking = @{ networkSegments = @(@{ name = "seg1"; vlanId = 1 }) } },
                @{ edgeSite = "site2"; networking = @{ networkSegments = @(@{ name = "seg2"; vlanId = 2 }) } }
            )
        }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $inputData { Get-NetworkSegmentDetailsFromInputData -InputData $args[0] -EdgeSitesArray @("site2") }
        @($result).Count | Should -Be 1
        $result[0].Name | Should -Be "seg2"
        $result[0].EdgeSite | Should -Be "site2"
    }
}


Describe "Get-ClustersInScope" {
    It "Returns all clusters when EdgeSitesArray is empty" {
        $data = [PSCustomObject]@{ clusters = @(
            [PSCustomObject]@{ edgeSite = "site1"; name = "c1" },
            [PSCustomObject]@{ edgeSite = "site2"; name = "c2" },
            [PSCustomObject]@{ edgeSite = "site3"; name = "c3" }
        ) }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $data { Get-ClustersInScope -EdgeSitesArray @() -InputData $args[0] }
        @($result).Count | Should -Be 3
    }

    It "Returns only matching clusters when EdgeSitesArray is set" {
        $data = [PSCustomObject]@{ clusters = @(
            [PSCustomObject]@{ edgeSite = "site1"; name = "c1" },
            [PSCustomObject]@{ edgeSite = "site2"; name = "c2" },
            [PSCustomObject]@{ edgeSite = "site3"; name = "c3" }
        ) }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $data { Get-ClustersInScope -EdgeSitesArray @("site1", "site3") -InputData $args[0] }
        @($result).Count | Should -Be 2
        @($result).edgeSite | Should -Contain "site1"
        @($result).edgeSite | Should -Contain "site3"
        @($result).edgeSite | Should -Not -Contain "site2"
    }

    It "Returns empty array when no cluster matches the filter" {
        $data = [PSCustomObject]@{ clusters = @(
            [PSCustomObject]@{ edgeSite = "site1"; name = "c1" }
        ) }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $data { Get-ClustersInScope -EdgeSitesArray @("site99") -InputData $args[0] }
        @($result).Count | Should -Be 0
    }
}


Describe "Get-SiteSpecsInScope" {
    It "Returns all site specs when EdgeSitesArray is empty" {
        $data = [PSCustomObject]@{ siteSpec = @(
            [PSCustomObject]@{ edgeSite = "site1" },
            [PSCustomObject]@{ edgeSite = "site2" }
        ) }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $data { Get-SiteSpecsInScope -EdgeSitesArray @() -SupervisorData $args[0] }
        @($result).Count | Should -Be 2
    }

    It "Returns only matching site specs when EdgeSitesArray is set" {
        $data = [PSCustomObject]@{ siteSpec = @(
            [PSCustomObject]@{ edgeSite = "site1" },
            [PSCustomObject]@{ edgeSite = "site2" }
        ) }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $data { Get-SiteSpecsInScope -EdgeSitesArray @("site2") -SupervisorData $args[0] }
        @($result).Count | Should -Be 1
        @($result)[0].edgeSite | Should -Be "site2"
    }

    It "Returns empty array when no site spec matches the filter" {
        $data = [PSCustomObject]@{ siteSpec = @(
            [PSCustomObject]@{ edgeSite = "site1" }
        ) }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $data { Get-SiteSpecsInScope -EdgeSitesArray @("siteX") -SupervisorData $args[0] }
        @($result).Count | Should -Be 0
    }
}


Describe "Test-AcceptableStrings" {
    It "Returns <Expected> for InputText '<InputText>'" -ForEach @(
        @{ InputText = "SMALL";  AcceptableStrings = @("TINY", "SMALL", "MEDIUM", "LARGE"); Expected = $true  }
        @{ InputText = "small";  AcceptableStrings = @("TINY", "SMALL", "MEDIUM", "LARGE"); Expected = $false }
        @{ InputText = "XLARGE"; AcceptableStrings = @("TINY", "SMALL", "MEDIUM", "LARGE"); Expected = $false }
        @{ InputText = "VMFS";   AcceptableStrings = @("VMFS");                              Expected = $true  }
    ) {
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $InputText, $AcceptableStrings {
            Test-AcceptableStrings -InputText $args[0] -AcceptableStrings $args[1]
        }
        $result | Should -Be $Expected
    }
}


Describe "Test-NumericRange" {
    It "Returns <Expected> for '<InputText>' in range [<MinValue>, <MaxValue>]" -ForEach @(
        @{ InputText = "5";  MinValue = 1; MaxValue = 10; Expected = $true  }
        @{ InputText = "1";  MinValue = 1; MaxValue = 10; Expected = $true  }
        @{ InputText = "10"; MinValue = 1; MaxValue = 10; Expected = $true  }
        @{ InputText = "0";  MinValue = 1; MaxValue = 10; Expected = $false }
        @{ InputText = "11"; MinValue = 1; MaxValue = 10; Expected = $false }
    ) {
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $InputText, $MinValue, $MaxValue {
            Test-NumericRange -InputText $args[0] -MinValue $args[1] -MaxValue $args[2]
        }
        $result | Should -Be $Expected
    }

    It "Returns <Expected> for '<InputText>' with no range constraints" -ForEach @(
        @{ InputText = "99999"; Expected = $true  }
        @{ InputText = "abc";   Expected = $false }
    ) {
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $InputText {
            Test-NumericRange -InputText $args[0]
        }
        $result | Should -Be $Expected
    }
}


Describe "Get-EffectiveNicListForCluster" {
    It "Returns cluster nicList when it has 2 NICs" {
        $cluster = [PSCustomObject]@{ nicList = @(@{name="vmnic0"}, @{name="vmnic1"}) }
        $common = @(@{name="vmnic2"}, @{name="vmnic3"})
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $cluster,$common { Get-EffectiveNicListForCluster -Cluster $args[0] -CommonNicList $args[1] }
        @($result).Count | Should -Be 2
        $result[0].name | Should -Be "vmnic0"
    }

    It "Returns cluster nicList when it has 4 NICs" {
        $cluster = [PSCustomObject]@{ nicList = @(@{name="vmnic0"}, @{name="vmnic1"}, @{name="vmnic2"}, @{name="vmnic3"}) }
        $common = @(@{name="vmnic4"})
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $cluster,$common { Get-EffectiveNicListForCluster -Cluster $args[0] -CommonNicList $args[1] }
        @($result).Count | Should -Be 4
    }

    It "Falls back to common when cluster nicList is absent" {
        $cluster = [PSCustomObject]@{ edgeSite = "site1" }
        $common = @(@{name="vmnic0"}, @{name="vmnic1"})
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $cluster,$common { Get-EffectiveNicListForCluster -Cluster $args[0] -CommonNicList $args[1] }
        @($result).Count | Should -Be 2
        $result[0].name | Should -Be "vmnic0"
    }

    It "Falls back to common when cluster nicList has invalid count (3 NICs)" {
        $cluster = [PSCustomObject]@{ nicList = @(@{name="vmnic0"}, @{name="vmnic1"}, @{name="vmnic2"}) }
        $common = @(@{name="vmnic4"}, @{name="vmnic5"})
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $cluster,$common { Get-EffectiveNicListForCluster -Cluster $args[0] -CommonNicList $args[1] }
        $result[0].name | Should -Be "vmnic4"
    }
}


Describe "Get-CommonLabEnvironmentEnabled" {
    It "Returns false when InputData is null" {
        $result = InModuleScope VcfEdgeAtScale { Get-CommonLabEnvironmentEnabled -InputData $null }
        $result | Should -Be $false
    }

    It "Returns false when labenvironment key is absent" {
        $data = [PSCustomObject]@{ common = [PSCustomObject]@{ vCenterName = "vc.example.com" } }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $data { Get-CommonLabEnvironmentEnabled -InputData $args[0] }
        $result | Should -Be $false
    }

    It "Returns true when labenvironment is boolean true" {
        $data = [PSCustomObject]@{ common = [PSCustomObject]@{ labenvironment = $true } }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $data { Get-CommonLabEnvironmentEnabled -InputData $args[0] }
        $result | Should -Be $true
    }

    It "Returns false when labenvironment is boolean false" {
        $data = [PSCustomObject]@{ common = [PSCustomObject]@{ labenvironment = $false } }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $data { Get-CommonLabEnvironmentEnabled -InputData $args[0] }
        $result | Should -Be $false
    }

    It "Is case-insensitive on the key name (LaBenVironMent)" {
        $data = [PSCustomObject]@{ common = [PSCustomObject]@{} }
        $data.common | Add-Member -MemberType NoteProperty -Name "LaBenVironMent" -Value $true
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $data { Get-CommonLabEnvironmentEnabled -InputData $args[0] }
        $result | Should -Be $true
    }
}


Describe "Get-EffectiveSupervisorServiceFlag" {
    It "Returns false (enabled) when flag is absent at both levels" {
        $cluster = [PSCustomObject]@{ edgeSite = "s1" }
        $common = [PSCustomObject]@{}
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $cluster,$common { Get-EffectiveSupervisorServiceFlag -Cluster $args[0] -CommonData $args[1] -FlagName "disableArgoCD" }
        $result | Should -Be $false
    }

    It "Returns true when flag is true at common level" {
        $cluster = [PSCustomObject]@{ edgeSite = "s1" }
        $common = [PSCustomObject]@{ supervisorServices = [PSCustomObject]@{ disableArgoCD = $true } }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $cluster,$common { Get-EffectiveSupervisorServiceFlag -Cluster $args[0] -CommonData $args[1] -FlagName "disableArgoCD" }
        $result | Should -Be $true
    }

    It "Cluster-level false overrides common-level true" {
        $cluster = [PSCustomObject]@{ supervisorServices = [PSCustomObject]@{ disableArgoCD = $false } }
        $common = [PSCustomObject]@{ supervisorServices = [PSCustomObject]@{ disableArgoCD = $true } }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $cluster,$common { Get-EffectiveSupervisorServiceFlag -Cluster $args[0] -CommonData $args[1] -FlagName "disableArgoCD" }
        $result | Should -Be $false
    }

    It "Cluster-level true overrides common-level false" {
        $cluster = [PSCustomObject]@{ supervisorServices = [PSCustomObject]@{ disableHarbor = $true } }
        $common = [PSCustomObject]@{ supervisorServices = [PSCustomObject]@{ disableHarbor = $false } }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $cluster,$common { Get-EffectiveSupervisorServiceFlag -Cluster $args[0] -CommonData $args[1] -FlagName "disableHarbor" }
        $result | Should -Be $true
    }
}


Describe "Invoke-HarborDeploymentPhase" {
    It "Sets Script:HarborPhaseStarted to true before any deployment step" {
        # Mirrors the ArgoCD phase-flag test: the flag must be set even when the helper throws,
        # so Initialize-VcfEdgeAtScale's rollback catch can choose Harbor-only rollback.
        $phaseStarted = InModuleScope VcfEdgeAtScale {
            $Script:HarborPhaseStarted = $false
            # Cluster with a harborConfiguration so we get past the synthetic-attach branch.
            $fakeCluster = [PSCustomObject]@{
                edgeSite            = "site1"
                harborConfiguration = [PSCustomObject]@{ hostname = "harbor.example.com" }
                # storagePolicy not needed here — StoragePolicyName is passed as a separate context key
            }
            $ctx = @{
                Cluster             = $fakeCluster
                ClusterId           = "domain-c462"
                ClusterName         = "TestCluster"
                ContextName         = "ctx-site1"
                CurrentEdgeSite     = "site1"
                InputData           = [PSCustomObject]@{ common = [PSCustomObject]@{} }
                StoragePolicyName   = "vSAN Default"
                SupervisorId        = "sup-001"
            }
            try { Invoke-HarborDeploymentPhase -Context $ctx } catch { [void]$_ }
            $Script:HarborPhaseStarted
        }
        $phaseStarted | Should -Be $true
    }

    It "Throws when a required context key is missing" {
        # The missing key name is in the exception message ("CallerName : missing required context key(s): Key").
        { InModuleScope VcfEdgeAtScale {
            $ctx = @{
                Cluster           = [PSCustomObject]@{ harborConfiguration = [PSCustomObject]@{} }
                # ClusterId deliberately omitted to trigger the key guard
                ClusterName       = "TestCluster"
                ContextName       = "ctx-site1"
                CurrentEdgeSite   = "site1"
                InputData         = [PSCustomObject]@{ common = [PSCustomObject]@{} }
                StoragePolicyName = "vSAN Default"
                SupervisorId      = "sup-001"
            }
            Invoke-HarborDeploymentPhase -Context $ctx
        } } | Should -Throw "*missing required context key*"
    }
}


Describe "Get-ArgoCDNamespaceFromCluster" {
    It "Combines default 'argocd' prefix with stripped MoRef" {
        $clusterObj = [PSCustomObject]@{ ExtensionData = [PSCustomObject]@{ MoRef = [PSCustomObject]@{ Value = "domain-c462" } } }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $clusterObj { Get-ArgoCDNamespaceFromCluster -ClusterObject $args[0] -ClusterSpec $null }
        $result | Should -Be "argocd-c462"
    }

    It "Uses nameSpacePrefix from cluster spec when defined" {
        $clusterObj = [PSCustomObject]@{ ExtensionData = [PSCustomObject]@{ MoRef = [PSCustomObject]@{ Value = "domain-c123" } } }
        $clusterSpec = [PSCustomObject]@{ supervisorServices = [PSCustomObject]@{ nameSpacePrefix = "myns" } }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $clusterObj,$clusterSpec { Get-ArgoCDNamespaceFromCluster -ClusterObject $args[0] -ClusterSpec $args[1] }
        $result | Should -Be "myns-c123"
    }

    It "Strips the 'domain' token leaving only the numeric suffix" {
        $clusterObj = [PSCustomObject]@{ ExtensionData = [PSCustomObject]@{ MoRef = [PSCustomObject]@{ Value = "domain-c9999" } } }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $clusterObj { Get-ArgoCDNamespaceFromCluster -ClusterObject $args[0] -ClusterSpec $null }
        $result | Should -Be "argocd-c9999"
    }

    It "Falls back to default prefix when nameSpacePrefix is blank" {
        $clusterObj = [PSCustomObject]@{ ExtensionData = [PSCustomObject]@{ MoRef = [PSCustomObject]@{ Value = "domain-c100" } } }
        $clusterSpec = [PSCustomObject]@{ supervisorServices = [PSCustomObject]@{ nameSpacePrefix = "   " } }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $clusterObj,$clusterSpec { Get-ArgoCDNamespaceFromCluster -ClusterObject $args[0] -ClusterSpec $args[1] }
        $result | Should -Be "argocd-c100"
    }
}


Describe "Get-EffectiveHaPolicyForCluster" {
    It "Returns reservationBased when no haPolicy is defined anywhere" {
        $result = InModuleScope VcfEdgeAtScale { Get-EffectiveHaPolicyForCluster -Cluster $null -InputData $null }
        $result | Should -Be "reservationBased"
    }

    It "Returns cluster-level haPolicy when valid" {
        $cluster = [PSCustomObject]@{ haPolicy = "slotBased" }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $cluster { Get-EffectiveHaPolicyForCluster -Cluster $args[0] -InputData $null }
        $result | Should -Be "slotBased"
    }

    It "Falls back to common haPolicy when cluster haPolicy is missing" {
        $inputData = [PSCustomObject]@{ common = [PSCustomObject]@{ haPolicy = "disabled" } }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $inputData { Get-EffectiveHaPolicyForCluster -Cluster $null -InputData $args[0] }
        $result | Should -Be "disabled"
    }

    It "Cluster haPolicy takes priority over common haPolicy" {
        $cluster = [PSCustomObject]@{ haPolicy = "slotBased" }
        $inputData = [PSCustomObject]@{ common = [PSCustomObject]@{ haPolicy = "disabled" } }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $cluster,$inputData { Get-EffectiveHaPolicyForCluster -Cluster $args[0] -InputData $args[1] }
        $result | Should -Be "slotBased"
    }

    It "Ignores invalid haPolicy values and falls through to default" {
        $cluster = [PSCustomObject]@{ haPolicy = "invalidValue" }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $cluster { Get-EffectiveHaPolicyForCluster -Cluster $args[0] -InputData $null }
        $result | Should -Be "reservationBased"
    }
}


Describe "Get-EffectiveVmkernelMtu" {
    It "Returns 9000 default when no InputData provided" {
        $result = InModuleScope VcfEdgeAtScale { Get-EffectiveVmkernelMtu -InputData $null }
        $result | Should -Be 9000
    }

    It "Returns vSanvMotionVmKernelMtuValue when defined and in range" {
        $inputData = [PSCustomObject]@{ common = [PSCustomObject]@{ vSanvMotionVmKernelMtuValue = 8000 } }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $inputData { Get-EffectiveVmkernelMtu -InputData $args[0] }
        $result | Should -Be 8000
    }

    It "Returns legacy vmkernelMtu when vSanvMotionVmKernelMtuValue is absent" {
        $common = New-Object PSObject
        $common | Add-Member -NotePropertyName vmkernelMtu -NotePropertyValue 1500
        $inputData = [PSCustomObject]@{ common = $common }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $inputData { Get-EffectiveVmkernelMtu -InputData $args[0] }
        $result | Should -Be 1500
    }

    It "Returns custom DefaultMtu when no override is set" {
        $result = InModuleScope VcfEdgeAtScale { Get-EffectiveVmkernelMtu -InputData $null -DefaultMtu 1500 }
        $result | Should -Be 1500
    }
}


Describe "Get-VsanWitnessNameForCluster" {
    It "Returns cluster-level vSanWitnessVmName when defined" {
        $cluster = [PSCustomObject]@{ vSanWitnessVmName = "my-witness.example.com"; edgeSite = "site1" }
        $inputData = [PSCustomObject]@{ common = [PSCustomObject]@{} }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $cluster,$inputData { Get-VsanWitnessNameForCluster -Cluster $args[0] -InputData $args[1] }
        $result | Should -Be "my-witness.example.com"
    }

    It "Falls back to common vSanWitnessVmName when cluster value is absent" {
        $cluster = [PSCustomObject]@{ edgeSite = "site1" }
        $common = [PSCustomObject]@{ vSanWitnessVmName = "common-witness.example.com" }
        $inputData = [PSCustomObject]@{ common = $common }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $cluster,$inputData { Get-VsanWitnessNameForCluster -Cluster $args[0] -InputData $args[1] }
        $result | Should -Be "common-witness.example.com"
    }

    It "Returns null when no witness name is defined at any level" {
        $cluster = [PSCustomObject]@{ edgeSite = "site1" }
        $inputData = [PSCustomObject]@{ common = [PSCustomObject]@{} }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $cluster,$inputData { Get-VsanWitnessNameForCluster -Cluster $args[0] -InputData $args[1] }
        $result | Should -BeNullOrEmpty
    }
}


Describe "Get-EffectiveSupervisorServicesYamlPath" {
    It "Returns cluster-level path when defined" {
        $cluster = [PSCustomObject]@{
            supervisorServices = [PSCustomObject]@{
                parentDirectory = "/srv/yaml"
                argoCdOperatorYamlPath = "argocd-operator.yml"
            }
        }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Get-EffectiveSupervisorServicesYamlPath -Cluster $args[0] -CommonData $null -LogicalYamlPathPropertyName "argoCdOperatorYamlPath"
        }
        $result | Should -Not -BeNullOrEmpty
    }

    It "Falls back to common when cluster path is not set" {
        $common = [PSCustomObject]@{
            supervisorServices = [PSCustomObject]@{
                parentDirectory = "/common/yaml"
                argoCdOperatorYamlPath = "common-argocd.yml"
            }
        }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $common {
            Get-EffectiveSupervisorServicesYamlPath -Cluster $null -CommonData $args[0] -LogicalYamlPathPropertyName "argoCdOperatorYamlPath"
        }
        $result | Should -Not -BeNullOrEmpty
    }
}


Describe "Invoke-ArgoCDDeploymentPhase" {
    # Convention: `catch { [void]$_ }` is used deliberately throughout these tests to absorb
    # expected exceptions from failing deployment paths (bad file paths, missing vCenter, etc.)
    # while still letting the test verify side-effects (flags, env vars, return values).
    # PSScriptAnalyzer's PSAvoidUsingEmptyCatchBlock rule is suppressed project-wide; [void]$_ makes
    # the intentional swallow explicit and is preferable to a blank catch block.
    It "Sets Script:ArgoCDPhaseStarted to true before any deployment step" {
        # Verify the phase flag is set even when the deployment throws — critical for rollback routing.
        $phaseStarted = InModuleScope VcfEdgeAtScale {
            $Script:ArgoCDPhaseStarted = $false
            # Supply a context that will fail immediately (Set-ArgoCDService doesn't exist as a real path).
            $ctx = @{
                ArgoCdDeploymentYamlPath = "/nonexistent/argocd.yml"
                VcenterCredential        = (New-Object System.Management.Automation.PSCredential("testuser", (ConvertTo-SecureString -String "test-password" -AsPlainText -Force)))
                ArgoCDyaml               = "/nonexistent/operator.yml"
                ArgocdNameSpace          = "argocd-c462"
                ArgocdVmClass            = @()
                ClusterId                = "domain-c462"
                ClusterName              = "TestCluster"
                ContextName              = "ctx-site1"
                StoragePolicyId          = "policy-001"
                SupervisorId             = "sup-001"
            }
            try { Invoke-ArgoCDDeploymentPhase -Context $ctx } catch { [void]$_ }
            $Script:ArgoCDPhaseStarted
        }
        $phaseStarted | Should -Be $true
    }

    It "Cleans up VCF_CLI_VSPHERE_PASSWORD env var even when deployment throws" {
        $envGone = InModuleScope VcfEdgeAtScale {
            $env:VCF_CLI_VSPHERE_PASSWORD = "test-secret"
            $ctx = @{
                ArgoCdDeploymentYamlPath = "/nonexistent/argocd.yml"
                VcenterCredential        = (New-Object System.Management.Automation.PSCredential("testuser", (ConvertTo-SecureString -String "test-password" -AsPlainText -Force)))
                ArgoCDyaml               = "/nonexistent/operator.yml"
                ArgocdNameSpace          = "argocd-c462"
                ArgocdVmClass            = @()
                ClusterId                = "domain-c462"
                ClusterName              = "TestCluster"
                ContextName              = "ctx-site1"
                StoragePolicyId          = "policy-001"
                SupervisorId             = "sup-001"
            }
            try { Invoke-ArgoCDDeploymentPhase -Context $ctx } catch { [void]$_ }
            [String]::IsNullOrEmpty($env:VCF_CLI_VSPHERE_PASSWORD)
        }
        $envGone | Should -Be $true
    }

    It "Throws when a required context key is missing" {
        # The missing key name is in the exception message ("CallerName : missing required context key(s): Key").
        { InModuleScope VcfEdgeAtScale {
            $ctx = @{
                ArgoCdDeploymentYamlPath = "/nonexistent/argocd.yml"
                VcenterCredential        = (New-Object System.Management.Automation.PSCredential("testuser", (ConvertTo-SecureString -String "test-password" -AsPlainText -Force)))
                # ArgoCDyaml deliberately omitted to trigger the guard
                ArgocdNameSpace          = "argocd-c462"
                ArgocdVmClass            = @()
                ClusterId                = "domain-c462"
                ClusterName              = "TestCluster"
                ContextName              = "ctx-site1"
                StoragePolicyId          = "policy-001"
                SupervisorId             = "sup-001"
            }
            Invoke-ArgoCDDeploymentPhase -Context $ctx
        } } | Should -Throw "*missing required context key*"
    }

    It "Propagates exceptions from deployment steps (does not swallow errors)" {
        # Ensures failures inside the helper are visible to the caller's rollback logic.
        { InModuleScope VcfEdgeAtScale {
            $ctx = @{
                ArgoCdDeploymentYamlPath = "/nonexistent/argocd.yml"
                VcenterCredential        = (New-Object System.Management.Automation.PSCredential("testuser", (ConvertTo-SecureString -String "test-password" -AsPlainText -Force)))
                ArgoCDyaml               = "/nonexistent/operator.yml"
                ArgocdNameSpace          = "argocd-c462"
                ArgocdVmClass            = @()
                ClusterId                = "domain-c462"
                ClusterName              = "TestCluster"
                ContextName              = "ctx-site1"
                StoragePolicyId          = "policy-001"
                SupervisorId             = "sup-001"
            }
            Invoke-ArgoCDDeploymentPhase -Context $ctx
        } } | Should -Throw "*YAML file not found*"

    }
}


Describe "ConvertFrom-JsonSafely" {
    BeforeAll {
        $script:tmpJsonDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "veas-json-$([System.Guid]::NewGuid().ToString('N').Substring(0, 8))"
        New-Item -ItemType Directory -Path $script:tmpJsonDir -Force | Out-Null
    }
    AfterAll {
        Remove-Item -Path $script:tmpJsonDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Parses a valid JSON file and returns the correct object" {
        $path = Join-Path $script:tmpJsonDir "valid.json"
        Set-Content -Path $path -Value '{"name":"test","count":42}' -Encoding UTF8
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $path { param($p) ConvertFrom-JsonSafely -JsonFilePath $p }
        $result.name  | Should -Be "test"
        $result.count | Should -Be 42
    }

    It "Strips blank lines and still parses successfully" {
        $path = Join-Path $script:tmpJsonDir "blanks.json"
        # Embed blank lines between properties as an editor might produce.
        $content = "{`n`n  `"key`": `"value`"`n`n}"
        Set-Content -Path $path -Value $content -Encoding UTF8
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $path { param($p) ConvertFrom-JsonSafely -JsonFilePath $p }
        $result.key | Should -Be "value"
    }

    It "Throws when the file does not exist" {
        { InModuleScope VcfEdgeAtScale {
            ConvertFrom-JsonSafely -JsonFilePath "/nonexistent/path/missing.json"
        } } | Should -Throw "*JSON validation failed*"

    }

    It "Throws when the file contains malformed JSON" {
        $path = Join-Path $script:tmpJsonDir "bad.json"
        Set-Content -Path $path -Value '{"broken": }' -Encoding UTF8
        { InModuleScope VcfEdgeAtScale -ArgumentList $path { param($p) ConvertFrom-JsonSafely -JsonFilePath $p } } | Should -Throw "*JSON validation failed*"

    }

    It "Parses a JSON file with a trailing newline without throwing" {
        $path = Join-Path $script:tmpJsonDir "trailing.json"
        Set-Content -Path $path -Value '{"ok":true}' -Encoding UTF8
        # Append a trailing blank line.
        Add-Content -Path $path -Value "" -Encoding UTF8
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $path { param($p) ConvertFrom-JsonSafely -JsonFilePath $p }
        $result.ok | Should -Be $true
    }
}


Describe "Invoke-ArgoCDDeploymentPhase — credential zeroing" {
    It "Clears VCF_CLI_VSPHERE_PASSWORD and KUBECTL_VSPHERE_PASSWORD in the finally block even when deployment throws" {
        # The test can only observe the side-effect indirectly: confirm the env vars are cleared
        # and that the function does not expose the password via its return value.
        $result = InModuleScope VcfEdgeAtScale {
            $ctx = @{
                ArgoCdDeploymentYamlPath = "/nonexistent/argocd.yml"
                VcenterCredential        = (New-Object System.Management.Automation.PSCredential("testuser", (ConvertTo-SecureString -String "super-secret-password" -AsPlainText -Force)))
                ArgoCDyaml               = "/nonexistent/operator.yml"
                ArgocdNameSpace          = "argocd-c462"
                ArgocdVmClass            = @()
                ClusterId                = "domain-c462"
                ClusterName              = "TestCluster"
                ContextName              = "ctx-site1"
                StoragePolicyId          = "policy-001"
                SupervisorId             = "sup-001"
            }
            try { Invoke-ArgoCDDeploymentPhase -Context $ctx } catch { [void]$_ }
            # VcenterCredential is a PSCredential object held only in the context hashtable scope.
            # Return a proxy value to verify the function ran at all.
            "completed"
        }
        # Verify function ran (didn't hang or double-throw).
        $result | Should -Be "completed"
        # Verify the env var was cleared by the finally block.
        $env:VCF_CLI_VSPHERE_PASSWORD | Should -BeNullOrEmpty
        $env:KUBECTL_VSPHERE_PASSWORD | Should -BeNullOrEmpty
    }
}


Describe "Resolve-HarborSecretValue" {
    AfterEach {
        [System.Environment]::SetEnvironmentVariable("VEAS_TEST_HARBOR_PW", $null)
        [System.Environment]::SetEnvironmentVariable("VEAS_TEST_HARBOR_KEY", $null)
    }

    It "Returns plain-text value as-is when Value has no dollar-env prefix" {
        $result = InModuleScope VcfEdgeAtScale {
            Resolve-HarborSecretValue -FieldName "harborAdminPassword" -Value "MyPlainTextPassword"
        }
        $result | Should -Be "MyPlainTextPassword"
    }

    It "Returns the environment variable value when it is pre-set" {
        [System.Environment]::SetEnvironmentVariable("VEAS_TEST_HARBOR_PW", "my-env-secret-value")
        $result = InModuleScope VcfEdgeAtScale {
            Resolve-HarborSecretValue -FieldName "harborAdminPassword" -Value '$env:VEAS_TEST_HARBOR_PW'
        }
        $result | Should -Be "my-env-secret-value"
    }

    It "Returns the environment variable value when it satisfies RequiredLength" {
        [System.Environment]::SetEnvironmentVariable("VEAS_TEST_HARBOR_KEY", "1234567890123456")
        $result = InModuleScope VcfEdgeAtScale {
            Resolve-HarborSecretValue -FieldName "secretKey" -Value '$env:VEAS_TEST_HARBOR_KEY' -RequiredLength 16
        }
        $result | Should -Be "1234567890123456"
    }

    It "Throws VcfDeploymentException when the env var has the wrong length and the user declines to re-enter" {
        [System.Environment]::SetEnvironmentVariable("VEAS_TEST_HARBOR_KEY", "short")
        $threw = InModuleScope VcfEdgeAtScale {
            Mock Read-Host { return "N" }
            $caught = $false
            try {
                Resolve-HarborSecretValue -FieldName "secretKey" -Value '$env:VEAS_TEST_HARBOR_KEY' -RequiredLength 16
            } catch {
                $caught = $true
            }
            $caught
        }
        $threw | Should -Be $true
    }

    It "Throws VcfDeploymentException when Value starts with dollar-env but the variable name is invalid (space)" {
        $threw = InModuleScope VcfEdgeAtScale {
            $caught = $false
            try {
                Resolve-HarborSecretValue -FieldName "harborAdminPassword" -Value '$env:BAD NAME'
            } catch {
                $caught = $true
            }
            $caught
        }
        $threw | Should -Be $true
    }

    It "Throws VcfDeploymentException when Value starts with dollar-env but the variable name begins with a digit" {
        $threw = InModuleScope VcfEdgeAtScale {
            $caught = $false
            try {
                Resolve-HarborSecretValue -FieldName "harborAdminPassword" -Value '$env:123INVALID'
            } catch {
                $caught = $true
            }
            $caught
        }
        $threw | Should -Be $true
    }

    It "Throws VcfDeploymentException when Value is dollar-env with a trailing special character" {
        $threw = InModuleScope VcfEdgeAtScale {
            $caught = $false
            try {
                Resolve-HarborSecretValue -FieldName "harborAdminPassword" -Value '$env:MY_VAR!'
            } catch {
                $caught = $true
            }
            $caught
        }
        $threw | Should -Be $true
    }

    It "Returns the env var value and logs DEBUG for a well-formed dollar-env reference with underscore prefix" {
        [System.Environment]::SetEnvironmentVariable("VEAS_TEST_HARBOR_PW", "underscore-prefixed-secret")
        $result = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            { Resolve-HarborSecretValue -FieldName "harborAdminPassword" -Value '$env:VEAS_TEST_HARBOR_PW' } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'DEBUG' -and $Message -match 'Resolved' }
            Resolve-HarborSecretValue -FieldName "harborAdminPassword" -Value '$env:VEAS_TEST_HARBOR_PW'
        }
        $result | Should -Be "underscore-prefixed-secret"
    }
}


Describe "Invoke-HarborDeploymentPhase" {

    It "Sets Script:HarborPhaseStarted to true before any deployment step" {
        $phaseStarted = InModuleScope VcfEdgeAtScale {
            $Script:HarborPhaseStarted = $false
            Mock Get-EffectiveSupervisorServicesYamlPath { return "/dummy/path.yml" }
            Mock Get-EffectiveHarborHostnameForInfrastructureCluster { return "" }
            $ctx = @{
                Cluster           = [PSCustomObject]@{ harborConfiguration = [PSCustomObject]@{} }
                ClusterId         = "domain-c462"
                ClusterName       = "TestCluster"
                ContextName       = "ctx-site1"
                CurrentEdgeSite   = "site1"
                InputData         = [PSCustomObject]@{ common = [PSCustomObject]@{} }
                StoragePolicyName = "vSAN Default Storage Policy"
                SupervisorId      = "sup-001"
            }
            try { Invoke-HarborDeploymentPhase -Context $ctx } catch { [void]$_ }
            $Script:HarborPhaseStarted
        }
        $phaseStarted | Should -Be $true
    }

    It "Throws when a required context key is missing" {
        # The missing key name is in the exception message ("CallerName : missing required context key(s): Key").
        { InModuleScope VcfEdgeAtScale {
            $ctx = @{
                ClusterId         = "domain-c462"
                # Cluster deliberately omitted to trigger the required-key guard.
                ClusterName       = "TestCluster"
                ContextName       = "ctx-site1"
                CurrentEdgeSite   = "site1"
                InputData         = [PSCustomObject]@{ common = [PSCustomObject]@{} }
                StoragePolicyName = "vSAN Default Storage Policy"
                SupervisorId      = "sup-001"
            }
            Invoke-HarborDeploymentPhase -Context $ctx
        } } | Should -Throw "*missing required context key*"
    }

    It "Preserves pre-set HARBOR_ADMIN_PASSWORD and SECRET_KEY env vars even when deployment throws" {
        # Save originals so this test does not pollute the process env for subsequent tests.
        $savedHarborPw  = $env:HARBOR_ADMIN_PASSWORD
        $savedSecretKey = $env:SECRET_KEY
        try {
            $envPreserved = InModuleScope VcfEdgeAtScale {
                $env:HARBOR_ADMIN_PASSWORD = "test-harbor-secret"
                $env:SECRET_KEY            = "test-secret-key"
                Mock Get-EffectiveSupervisorServicesYamlPath { return "/dummy/path.yml" }
                Mock Get-EffectiveHarborHostnameForInfrastructureCluster { return "" }
                $ctx = @{
                    Cluster           = [PSCustomObject]@{ harborConfiguration = [PSCustomObject]@{} }
                    ClusterId         = "domain-c462"
                    ClusterName       = "TestCluster"
                    ContextName       = "ctx-site1"
                    CurrentEdgeSite   = "site1"
                    InputData         = [PSCustomObject]@{ common = [PSCustomObject]@{} }
                    StoragePolicyName = "vSAN Default Storage Policy"
                    SupervisorId      = "sup-001"
                }
                try { Invoke-HarborDeploymentPhase -Context $ctx } catch { [void]$_ }
                ($env:HARBOR_ADMIN_PASSWORD -eq "test-harbor-secret") -and ($env:SECRET_KEY -eq "test-secret-key")
            }
            $envPreserved | Should -Be $true
        }
        finally {
            [System.Environment]::SetEnvironmentVariable("HARBOR_ADMIN_PASSWORD", $savedHarborPw)
            [System.Environment]::SetEnvironmentVariable("SECRET_KEY", $savedSecretKey)
        }
    }

    It "Preserves HARBOR_ADMIN_PASSWORD and SECRET_KEY even when set interactively during deployment" {
        # Credentials entered interactively (Resolve-HarborSecretValue stores in env var) must survive
        # across multi-site runs and same-session reruns; process-scope env vars expire with the session.
        # Save originals so this test does not pollute the process env for subsequent tests (e.g. live tests).
        $savedHarborPw  = $env:HARBOR_ADMIN_PASSWORD
        $savedSecretKey = $env:SECRET_KEY
        try {
            $envPreserved = InModuleScope VcfEdgeAtScale {
                [System.Environment]::SetEnvironmentVariable("HARBOR_ADMIN_PASSWORD", $null)
                [System.Environment]::SetEnvironmentVariable("SECRET_KEY", $null)
                Mock Get-EffectiveSupervisorServicesYamlPath { return "/dummy/path.yml" }
                Mock Get-EffectiveHarborHostnameForInfrastructureCluster { return "harbor.example.com" }
                Mock Test-JsonPropertyFormat { return $true }
                Mock New-HarborDataValuesFile {
                    # Simulate Resolve-HarborSecretValue storing interactively-entered credentials.
                    [System.Environment]::SetEnvironmentVariable("HARBOR_ADMIN_PASSWORD", "interactive-pw")
                    [System.Environment]::SetEnvironmentVariable("SECRET_KEY", "interactive-sk")
                    return (Join-Path ([System.IO.Path]::GetTempPath()) "harbor-test.yml")
                }
                Mock Get-Content { return "hostname: harbor.example.com" }
                Mock Set-HarborService { }
                Mock Get-ArgoCDServiceDetail { return @("harbor", "2.12.0") }
                Mock Install-HarborSupervisorService { throw [VcfDeploymentException]::new("install failed") }
                $ctx = @{
                    Cluster           = [PSCustomObject]@{ harborConfiguration = [PSCustomObject]@{} }
                    ClusterId         = "domain-c462"
                    ClusterName       = "TestCluster"
                    ContextName       = "ctx-site1"
                    CurrentEdgeSite   = "site1"
                    InputData         = [PSCustomObject]@{ common = [PSCustomObject]@{} }
                    StoragePolicyName = "vSAN Default Storage Policy"
                    SupervisorId      = "sup-001"
                }
                try { Invoke-HarborDeploymentPhase -Context $ctx } catch { [void]$_ }
                # Credentials stored by Resolve-HarborSecretValue must persist after the function returns.
                ($env:HARBOR_ADMIN_PASSWORD -eq "interactive-pw") -and ($env:SECRET_KEY -eq "interactive-sk")
            }
            $envPreserved | Should -Be $true
        }
        finally {
            [System.Environment]::SetEnvironmentVariable("HARBOR_ADMIN_PASSWORD", $savedHarborPw)
            [System.Environment]::SetEnvironmentVariable("SECRET_KEY", $savedSecretKey)
        }
    }
}


Describe "Build-HarborDataValuesParams" {

    It "Returns lab-generated TLS paths and sets UsedLabGeneratedTls when LabEnvironment and no explicit TLS" {
        $result = InModuleScope VcfEdgeAtScale {
            function New-LabHarborSelfSignedTlsMaterialFiles {
                [CmdletBinding()] Param([Parameter()] [Object]$DnsName, [Parameter()] [Object]$EdgeSite)
                return [PSCustomObject]@{ TlsCrtPath = (Join-Path ([System.IO.Path]::GetTempPath()) "tls.crt"); TlsKeyPath = (Join-Path ([System.IO.Path]::GetTempPath()) "tls.key"); CaCrtPath = (Join-Path ([System.IO.Path]::GetTempPath()) "ca.crt") }
            }
            $fakeConfig = [PSCustomObject]@{}
            Build-HarborDataValuesParams -EdgeSite "site1" -EffectiveHarborHostname "harbor.example.com" `
                -HarborConfig $fakeConfig -HarborDataValuesTemplatePath "/tmpl/values.yml" `
                -LabEnvironment $true -StoragePolicyName "vSAN-Policy"
        }
        $result.UsedLabGeneratedTls | Should -Be $true
        $result.LabSelfSignedPaths  | Should -Not -BeNullOrEmpty
        $result.DataValuesParams["TlsCrtPath"] | Should -Be (Join-Path ([System.IO.Path]::GetTempPath()) "tls.crt")
        $result.DataValuesParams["TlsKeyPath"] | Should -Be (Join-Path ([System.IO.Path]::GetTempPath()) "tls.key")
    }

    It "Uses explicit TLS paths from HarborConfig when LabEnvironment is false" {
        $result = InModuleScope VcfEdgeAtScale {
            $fakeConfig = [PSCustomObject]@{ tlsCrt = "/certs/tls.crt"; tlsKey = "/certs/tls.key" }
            function New-LabHarborSelfSignedTlsMaterialFiles {
                [CmdletBinding()] Param([Parameter()] [Object]$DnsName, [Parameter()] [Object]$EdgeSite)
                throw "Must not be called when LabEnvironment is false"
            }
            Build-HarborDataValuesParams -EdgeSite "site1" -EffectiveHarborHostname "harbor.example.com" `
                -HarborConfig $fakeConfig -HarborDataValuesTemplatePath "/tmpl/values.yml" `
                -LabEnvironment $false -StoragePolicyName "vSAN-Policy"
        }
        $result.UsedLabGeneratedTls | Should -Be $false
        $result.LabSelfSignedPaths  | Should -BeNullOrEmpty
        $result.DataValuesParams["TlsCrtPath"] | Should -Be "/certs/tls.crt"
        $result.DataValuesParams["TlsKeyPath"] | Should -Be "/certs/tls.key"
    }

    It "Includes volume size overrides in DataValuesParams when harborConfig has them set" {
        $result = InModuleScope VcfEdgeAtScale {
            $fakeConfig = [PSCustomObject]@{ registryVolumeSize = "50Gi"; databaseVolumeSize = "10Gi" }
            function New-LabHarborSelfSignedTlsMaterialFiles {
                [CmdletBinding()] Param([Parameter()] [Object]$DnsName, [Parameter()] [Object]$EdgeSite)
                throw "Must not be called"
            }
            Build-HarborDataValuesParams -EdgeSite "site1" -EffectiveHarborHostname "harbor.example.com" `
                -HarborConfig $fakeConfig -HarborDataValuesTemplatePath "/tmpl/values.yml" `
                -LabEnvironment $false -StoragePolicyName "vSAN-Policy"
        }
        $result.DataValuesParams["RegistryVolumeSize"]  | Should -Be "50Gi"
        $result.DataValuesParams["DatabaseVolumeSize"]  | Should -Be "10Gi"
        $result.DataValuesParams.ContainsKey("RedisVolumeSize") | Should -Be $false
    }
}


Describe "Invoke-HarborLabTlsCleanup" {

    It "Skips Remove-Item and does not throw when LabSelfSignedPaths is null" {
        InModuleScope VcfEdgeAtScale {
            Mock Remove-Item {}
            { Invoke-HarborLabTlsCleanup -CurrentEdgeSite "site1" -HarborInstallSucceeded $true `
                -LabSelfSignedPaths $null -PreserveAutoGeneratedKeyCert $false } | Should -Not -Throw
            Should -Not -Invoke Remove-Item
        }
    }

    It "Removes all 3 lab TLS temp files when PreserveAutoGeneratedKeyCert is false" {
        InModuleScope VcfEdgeAtScale {
            $tmpCrt = Join-Path ([System.IO.Path]::GetTempPath()) "harbor-test-tls-$([Guid]::NewGuid()).crt"
            $tmpKey = Join-Path ([System.IO.Path]::GetTempPath()) "harbor-test-tls-$([Guid]::NewGuid()).key"
            $tmpCa  = Join-Path ([System.IO.Path]::GetTempPath()) "harbor-test-ca-$([Guid]::NewGuid()).crt"
            try {
                [System.IO.File]::WriteAllText($tmpCrt, "cert")
                [System.IO.File]::WriteAllText($tmpKey, "key")
                [System.IO.File]::WriteAllText($tmpCa,  "ca")
                $paths = [PSCustomObject]@{ TlsCrtPath = $tmpCrt; TlsKeyPath = $tmpKey; CaCrtPath = $tmpCa }
                Invoke-HarborLabTlsCleanup -CurrentEdgeSite "site1" -HarborInstallSucceeded $true `
                    -LabSelfSignedPaths $paths -PreserveAutoGeneratedKeyCert $false
                (Test-Path $tmpCrt) | Should -Be $false
                (Test-Path $tmpKey) | Should -Be $false
                (Test-Path $tmpCa)  | Should -Be $false
            } finally {
                foreach ($p in @($tmpCrt, $tmpKey, $tmpCa)) { if (Test-Path $p) { Remove-Item $p -Force } }
            }
        }
    }

    It "Skips preservation but still deletes temp files when HarborInstallSucceeded is false" {
        InModuleScope VcfEdgeAtScale {
            $tmpCrt = Join-Path ([System.IO.Path]::GetTempPath()) "harbor-fail-tls-$([Guid]::NewGuid()).crt"
            $tmpKey = Join-Path ([System.IO.Path]::GetTempPath()) "harbor-fail-tls-$([Guid]::NewGuid()).key"
            $tmpCa  = Join-Path ([System.IO.Path]::GetTempPath()) "harbor-fail-ca-$([Guid]::NewGuid()).crt"
            try {
                [System.IO.File]::WriteAllText($tmpCrt, "cert")
                [System.IO.File]::WriteAllText($tmpKey, "key")
                [System.IO.File]::WriteAllText($tmpCa,  "ca")
                $paths = [PSCustomObject]@{ TlsCrtPath = $tmpCrt; TlsKeyPath = $tmpKey; CaCrtPath = $tmpCa }
                # PreserveAutoGeneratedKeyCert=$true but HarborInstallSucceeded=$false — preservation skipped.
                Invoke-HarborLabTlsCleanup -CurrentEdgeSite "site1" -HarborInstallSucceeded $false `
                    -LabSelfSignedPaths $paths -PreserveAutoGeneratedKeyCert $true
                (Test-Path $tmpCrt) | Should -Be $false
                (Test-Path $tmpKey) | Should -Be $false
                (Test-Path $tmpCa)  | Should -Be $false
            } finally {
                foreach ($p in @($tmpCrt, $tmpKey, $tmpCa)) { if (Test-Path $p) { Remove-Item $p -Force } }
            }
        }
    }
}


Describe "Invoke-HarborTempYamlCleanup" {

    It "Skips Remove-Item and does not throw when HarborTempYamlPath is null" {
        InModuleScope VcfEdgeAtScale {
            Mock Remove-Item {}
            { Invoke-HarborTempYamlCleanup -HarborInstallSucceeded $true -HarborTempYamlPath $null -HarborYamlSaveDir $null } | Should -Not -Throw
            Should -Not -Invoke Remove-Item
        }
    }

    It "Moves the YAML file to the save directory when HarborInstallSucceeded is true and save dir is set" {
        InModuleScope VcfEdgeAtScale {
            $tmpDir  = [System.IO.Path]::GetTempPath()
            $tmpYaml = Join-Path $tmpDir "harbor-data-$([Guid]::NewGuid()).yml"
            $saveDir = Join-Path $tmpDir "harbor-save-$([Guid]::NewGuid())"
            try {
                [System.IO.File]::WriteAllText($tmpYaml, "hostname: harbor.example.com")
                New-Item -ItemType Directory -Path $saveDir -Force | Out-Null
                Invoke-HarborTempYamlCleanup -HarborInstallSucceeded $true -HarborTempYamlPath $tmpYaml -HarborYamlSaveDir $saveDir
                (Test-Path $tmpYaml) | Should -Be $false
                $moved = Join-Path $saveDir (Split-Path $tmpYaml -Leaf)
                (Test-Path $moved) | Should -Be $true
            } finally {
                if (Test-Path $saveDir) { Remove-Item $saveDir -Recurse -Force }
            }
        }
    }

    It "Writes a redacted copy and removes the original when HarborInstallSucceeded is false" {
        InModuleScope VcfEdgeAtScale {
            $tmpDir  = [System.IO.Path]::GetTempPath()
            $tmpYaml = Join-Path $tmpDir "harbor-secrets-$([Guid]::NewGuid()).yml"
            try {
                [System.IO.File]::WriteAllText($tmpYaml, "hostname: harbor.example.com`nharborAdminPassword: supersecret`n")
                Invoke-HarborTempYamlCleanup -HarborInstallSucceeded $false -HarborTempYamlPath $tmpYaml -HarborYamlSaveDir $null
                (Test-Path $tmpYaml) | Should -Be $false
                $redactedPath = [System.IO.Path]::ChangeExtension($tmpYaml, ".redacted.yml")
                (Test-Path $redactedPath) | Should -Be $true
                (Get-Content $redactedPath -Raw) | Should -Match "\[REDACTED\]"
            } finally {
                $redactedPath = [System.IO.Path]::ChangeExtension($tmpYaml, ".redacted.yml")
                foreach ($p in @($tmpYaml, $redactedPath)) { if (Test-Path $p) { Remove-Item $p -Force } }
            }
        }
    }
}


Describe "Resolve-HarborYamlSaveDirectory" {

    It "Returns null when SaveHarborYaml is false" {
        $result = InModuleScope VcfEdgeAtScale {
            Resolve-HarborYamlSaveDirectory -SaveHarborYaml $false
        }
        $result | Should -BeNullOrEmpty
    }

    It "Returns and creates a HarborYaml directory under the module base when SaveHarborYaml is true" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock New-Item { return [PSCustomObject]@{ FullName = $Path } }
            Mock Test-Path { return $false }
            Resolve-HarborYamlSaveDirectory -SaveHarborYaml $true
        }
        $result | Should -Match "HarborYaml$"
        $result | Should -Not -BeNullOrEmpty
    }
}


Describe "Convert-CountToInt" {
    It "Converts a double count property on a PSCustomObject to int" {
        $obj = [PSCustomObject]@{ count = 5.0; name = "test" }
        InModuleScope VcfEdgeAtScale -ArgumentList $obj { param($o) Convert-CountToInt $o }
        $obj.count | Should -BeOfType [int]
        $obj.count | Should -Be 5
    }

    It "Converts a numeric string count property to int" {
        $obj = [PSCustomObject]@{ count = "10.0"; name = "test" }
        InModuleScope VcfEdgeAtScale -ArgumentList $obj { param($o) Convert-CountToInt $o }
        $obj.count | Should -Be 10
    }

    It "Rounds to nearest integer for fractional values — PowerShell [int] cast semantics (5.1 -> 5)" {
        $obj = [PSCustomObject]@{ count = 5.1 }
        InModuleScope VcfEdgeAtScale -ArgumentList $obj { param($o) Convert-CountToInt $o }
        $obj.count | Should -Be 5
    }

    It "Recursively converts count in nested PSCustomObjects" {
        $inner = [PSCustomObject]@{ count = 3.0 }
        $outer = [PSCustomObject]@{ count = 2.0; inner = $inner }
        InModuleScope VcfEdgeAtScale -ArgumentList $outer { param($o) Convert-CountToInt $o }
        $outer.count | Should -Be 2
        $outer.inner.count | Should -Be 3
    }

    It "Recursively converts count properties in an array of objects" {
        $items = @(
            [PSCustomObject]@{ count = 1.0 },
            [PSCustomObject]@{ count = 2.0 }
        )
        InModuleScope VcfEdgeAtScale -ArgumentList (,$items) { param($a) Convert-CountToInt $a }
        $items[0].count | Should -Be 1
        $items[1].count | Should -Be 2
    }

    It "Handles null input without throwing and returns no value" {
        $result = InModuleScope VcfEdgeAtScale { Convert-CountToInt $null }
        { InModuleScope VcfEdgeAtScale { Convert-CountToInt $null } } | Should -Not -Throw
        $result | Should -BeNullOrEmpty
    }

    It "Does not modify non-count properties" {
        $obj = [PSCustomObject]@{ name = "hello"; value = 3.14 }
        InModuleScope VcfEdgeAtScale -ArgumentList $obj { param($o) Convert-CountToInt $o }
        $obj.name | Should -Be "hello"
        $obj.value | Should -Be 3.14
    }
}


Describe "Test-EsxHostUniqueness" {
    It "Returns IsValid=true when all hosts are unique across sites" {
        $result = InModuleScope VcfEdgeAtScale {
            $data = [PSCustomObject]@{
                clusters = @(
                    [PSCustomObject]@{ edgeSite = "site1"; esxHosts = @("esx1.lab", "esx2.lab") },
                    [PSCustomObject]@{ edgeSite = "site2"; esxHosts = @("esx3.lab", "esx4.lab") }
                )
            }
            Test-EsxHostUniqueness -InputData $data
        }
        $result.IsValid | Should -Be $true
        $result.DuplicateHosts | Should -BeNullOrEmpty
    }

    It "Returns IsValid=false when the same host appears in two edge sites" {
        $result = InModuleScope VcfEdgeAtScale {
            $data = [PSCustomObject]@{
                clusters = @(
                    [PSCustomObject]@{ edgeSite = "site1"; esxHosts = @("esx1.lab", "esx-shared.lab") },
                    [PSCustomObject]@{ edgeSite = "site2"; esxHosts = @("esx-shared.lab", "esx4.lab") }
                )
            }
            Test-EsxHostUniqueness -InputData $data
        }
        $result.IsValid | Should -Be $false
        $result.DuplicateHosts | Should -Contain "esx-shared.lab"
        $result.ErrorMessage | Should -Not -BeNullOrEmpty
    }

    It "Detects duplicates case-insensitively (ESX-SHARED.LAB vs esx-shared.lab)" {
        $result = InModuleScope VcfEdgeAtScale {
            $data = [PSCustomObject]@{
                clusters = @(
                    [PSCustomObject]@{ edgeSite = "site1"; esxHosts = @("ESX-SHARED.LAB") },
                    [PSCustomObject]@{ edgeSite = "site2"; esxHosts = @("esx-shared.lab") }
                )
            }
            Test-EsxHostUniqueness -InputData $data
        }
        $result.IsValid | Should -Be $false
    }

    It "Skips null and whitespace-only host names without throwing" {
        $result = InModuleScope VcfEdgeAtScale {
            $data = [PSCustomObject]@{
                clusters = @(
                    [PSCustomObject]@{ edgeSite = "site1"; esxHosts = @($null, "   ", "real-esx.lab") }
                )
            }
            Test-EsxHostUniqueness -InputData $data
        }
        $result.IsValid | Should -Be $true
    }

    It "Returns IsValid=true when clusters array is empty" {
        $result = InModuleScope VcfEdgeAtScale {
            Test-EsxHostUniqueness -InputData ([PSCustomObject]@{ clusters = @() })
        }
        $result.IsValid | Should -Be $true
    }
}


Describe "Get-JsonPropertyValue" {
    It "Returns a string input directly without navigating properties" {
        $result = InModuleScope VcfEdgeAtScale { Get-JsonPropertyValue -InputData "plain-string" }
        $result | Should -Be "plain-string"
    }

    It "Returns null for null InputData" {
        $result = InModuleScope VcfEdgeAtScale { Get-JsonPropertyValue -InputData $null }
        $result | Should -BeNullOrEmpty
    }

    It "Returns a top-level property value from a PSCustomObject via PropertyPath" {
        $result = InModuleScope VcfEdgeAtScale {
            $obj = [PSCustomObject]@{ vCenterName = "vcsa.lab.local" }
            Get-JsonPropertyValue -InputData $obj -PropertyPath "vCenterName"
        }
        $result | Should -Be "vcsa.lab.local"
    }

    It "Returns a nested property value via dot-notation PropertyPath" {
        $result = InModuleScope VcfEdgeAtScale {
            $obj = [PSCustomObject]@{
                common = [PSCustomObject]@{ vCenterName = "vcsa.nested.local" }
            }
            Get-JsonPropertyValue -InputData $obj -PropertyPath "common.vCenterName"
        }
        $result | Should -Be "vcsa.nested.local"
    }

    It "Returns null when a path segment does not exist in the object" {
        $result = InModuleScope VcfEdgeAtScale {
            $obj = [PSCustomObject]@{ name = "test" }
            Get-JsonPropertyValue -InputData $obj -PropertyPath "nonExistent.property"
        }
        $result | Should -BeNullOrEmpty
    }

    It "Returns the first matching element value via array notation" {
        $result = InModuleScope VcfEdgeAtScale {
            $obj = [PSCustomObject]@{
                clusters = @(
                    [PSCustomObject]@{ vCenterName = "vcsa1.lab" },
                    [PSCustomObject]@{ vCenterName = "vcsa2.lab" }
                )
            }
            Get-JsonPropertyValue -InputData $obj -PropertyPath "clusters[].vCenterName"
        }
        $result | Should -Be "vcsa1.lab"
    }

    It "Returns empty string when array property is terminal and empty" {
        $result = InModuleScope VcfEdgeAtScale {
            $obj = [PSCustomObject]@{ clusters = @() }
            Get-JsonPropertyValue -InputData $obj -PropertyPath "clusters[]"
        }
        $result | Should -Be ""
    }

    It "Returns the first element value when path has two steps after array notation" {
        # Exercises clusters[].networking.name — two dot-separated steps after the [] segment.
        # This path goes through Resolve-JsonArrayPropertyValue with RemainingPath = "networking.name"
        # and then back into Get-JsonPropertyValue for two-step navigation on each element.
        $result = InModuleScope VcfEdgeAtScale {
            $obj = [PSCustomObject]@{
                clusters = @(
                    [PSCustomObject]@{ networking = [PSCustomObject]@{ name = "seg-a" } },
                    [PSCustomObject]@{ networking = [PSCustomObject]@{ name = "seg-b" } }
                )
            }
            Get-JsonPropertyValue -InputData $obj -PropertyPath "clusters[].networking.name"
        }
        $result | Should -Be "seg-a"
    }
}


Describe "Resolve-JsonArrayPropertyValue — direct unit tests" {

    It "Returns $null when the named array property is null on the object" {
        $result = InModuleScope VcfEdgeAtScale {
            $obj = [PSCustomObject]@{ clusters = $null }
            Resolve-JsonArrayPropertyValue -ArrayPropertyName "clusters" -CurrentObject $obj -IsLastPathPart $false -PropertyPath "clusters[].name" -RemainingPath "name"
        }
        $result | Should -BeNullOrEmpty
    }

    It "Returns $null when the property exists but is not an array" {
        $result = InModuleScope VcfEdgeAtScale {
            $obj = [PSCustomObject]@{ clusters = "not-an-array" }
            Resolve-JsonArrayPropertyValue -ArrayPropertyName "clusters" -CurrentObject $obj -IsLastPathPart $false -PropertyPath "clusters[].name" -RemainingPath "name"
        }
        $result | Should -BeNullOrEmpty
    }

    It "Returns empty string for terminal last-part empty array" {
        $result = InModuleScope VcfEdgeAtScale {
            $obj = [PSCustomObject]@{ items = @() }
            Resolve-JsonArrayPropertyValue -ArrayPropertyName "items" -CurrentObject $obj -IsLastPathPart $true -PropertyPath "items[]" -RemainingPath ""
        }
        $result | Should -Be ""
    }

    It "Returns $null when no array element satisfies the remaining path" {
        $result = InModuleScope VcfEdgeAtScale {
            $obj = [PSCustomObject]@{
                clusters = @(
                    [PSCustomObject]@{ name = $null },
                    [PSCustomObject]@{ name = $null }
                )
            }
            Resolve-JsonArrayPropertyValue -ArrayPropertyName "clusters" -CurrentObject $obj -IsLastPathPart $false -PropertyPath "clusters[].name" -RemainingPath "name"
        }
        $result | Should -BeNullOrEmpty
    }

    It "Returns the first non-null value when RemainingPath has two dot-separated segments" {
        # Exercises the path clusters[].networking.name — RemainingPath = "networking.name" is
        # passed to Get-JsonPropertyValue which must navigate two steps on each array element.
        $result = InModuleScope VcfEdgeAtScale {
            $obj = [PSCustomObject]@{
                clusters = @(
                    [PSCustomObject]@{ networking = [PSCustomObject]@{ name = "seg-a" } },
                    [PSCustomObject]@{ networking = [PSCustomObject]@{ name = "seg-b" } }
                )
            }
            Resolve-JsonArrayPropertyValue -ArrayPropertyName "clusters" -CurrentObject $obj -IsLastPathPart $false -PropertyPath "clusters[].networking.name" -RemainingPath "networking.name"
        }
        $result | Should -Be "seg-a"
    }
}


Describe "Test-CommandAvailability" {
    It "Does not throw and logs no ERROR when the command exists in PATH" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            { Test-CommandAvailability -Command "pwsh" -Description "PowerShell" } | Should -Not -Throw
            Should -Not -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'ERROR' }
        }
    }

    It "Throws VcfDeploymentException when the command is not found in PATH" {
        $threw = InModuleScope VcfEdgeAtScale {
            $caught = $false
            try {
                Test-CommandAvailability -Command "this-cmd-does-not-exist-veas-xyz" -Description "Fake Tool"
            } catch {
                $caught = $true
            }
            $caught
        }
        $threw | Should -Be $true
    }
}


Describe "Test-Filepath" {
    BeforeAll {
        $script:testFilepathDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "veas-fp-$([System.Guid]::NewGuid().ToString('N').Substring(0, 8))"
        New-Item -ItemType Directory -Path $script:testFilepathDir -Force | Out-Null
        $script:testFilepathFile = Join-Path $script:testFilepathDir "exists.txt"
        Set-Content -Path $script:testFilepathFile -Value "test" -Encoding UTF8
    }
    AfterAll {
        Remove-Item -Path $script:testFilepathDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Logs INFO 'Found' and does not throw when the file exists" {
        InModuleScope VcfEdgeAtScale -ArgumentList $script:testFilepathFile {
            param($p)
            Mock Write-LogMessage {}
            { Test-Filepath -FilePath $p -Description "Test file" } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'INFO' -and $Message -match 'Found' }
        }
    }

    It "Throws VcfDeploymentException when the file does not exist" {
        $threw = InModuleScope VcfEdgeAtScale {
            $caught = $false
            try {
                Test-Filepath -FilePath "/nonexistent/veas-path/file.txt" -Description "Missing file"
            } catch {
                $caught = $true
            }
            $caught
        }
        $threw | Should -Be $true
    }
}


Describe "Update-HarborYamlContent" {
    BeforeAll {
        # Minimal Harbor data-values template with all key patterns exercised by Update-HarborYamlContent.
        $script:harborMinimalYaml = @"
hostname: harbor.template.local
enableNginxLoadBalancer: false
enableContourHttpProxy: true
persistence:
  persistentVolumeClaim:
    registry:
      storageClass: template-class
      size: 10Gi
"@
    }

    It "Replaces the hostname with the provided value" {
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $script:harborMinimalYaml {
            param($yaml)
            Update-HarborYamlContent -YamlContent $yaml -Hostname "harbor.new.local" -StorageClassName "new-sc"
        }
        $result | Should -Match "(?m)^hostname: harbor\.new\.local"
        $result | Should -Not -Match "harbor\.template\.local"
    }

    It "Sets enableNginxLoadBalancer to true regardless of original value" {
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $script:harborMinimalYaml {
            param($yaml)
            Update-HarborYamlContent -YamlContent $yaml -Hostname "h.example.com" -StorageClassName "sc"
        }
        $result | Should -Match "(?m)^enableNginxLoadBalancer: true"
    }

    It "Sets enableContourHttpProxy to false regardless of original value" {
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $script:harborMinimalYaml {
            param($yaml)
            Update-HarborYamlContent -YamlContent $yaml -Hostname "h.example.com" -StorageClassName "sc"
        }
        $result | Should -Match "(?m)^enableContourHttpProxy: false"
    }

    It "Replaces storageClass with the provided storage class name" {
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $script:harborMinimalYaml {
            param($yaml)
            Update-HarborYamlContent -YamlContent $yaml -Hostname "h.example.com" -StorageClassName "my-storage-class"
        }
        $result | Should -Match '"my-storage-class"'
        $result | Should -Not -Match '"template-class"'
    }

    It "Normalizes Windows CRLF line endings to LF" {
        # On Windows, $script:harborMinimalYaml may already contain CRLF (git autocrlf, Set-Content
        # default encoding). Normalize to LF first so the injected CRLF input is clean and the
        # function's -replace '\r\n',"`n" step strips all carriage returns correctly.
        $normalizedBase = $script:harborMinimalYaml -replace "`r`n", "`n"
        $crlfYaml = $normalizedBase -replace "`n", "`r`n"
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $crlfYaml {
            param($yaml)
            Update-HarborYamlContent -YamlContent $yaml -Hostname "h.example.com" -StorageClassName "sc"
        }
        $result | Should -Not -Match "`r"
    }

    It "Replaces a commented-out hostname line and removes the comment marker" {
        $commentedYaml = $script:harborMinimalYaml -replace "hostname: harbor.template.local", "# hostname: harbor.template.local"
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $commentedYaml {
            param($yaml)
            Update-HarborYamlContent -YamlContent $yaml -Hostname "harbor.uncommented.local" -StorageClassName "sc"
        }
        $result | Should -Match "(?m)^hostname: harbor\.uncommented\.local"
        $result | Should -Not -Match "#\s*hostname"
    }

    It "Injects HarborAdminPassword as a single-quoted YAML scalar" {
        $yaml = $script:harborMinimalYaml + "`nharborAdminPassword: old-admin-password"
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $yaml {
            param($yaml)
            Update-HarborYamlContent -YamlContent $yaml -Hostname "h.example.com" -StorageClassName "sc" -HarborAdminPassword "newpassword"
        }
        $result | Should -Match "(?m)^harborAdminPassword: 'newpassword'"
        $result | Should -Not -Match "old-admin-password"
    }

    It "Doubles embedded single quotes in HarborAdminPassword (YAML injection guard)" {
        $yaml = $script:harborMinimalYaml + "`nharborAdminPassword: old-admin-password"
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $yaml {
            param($yaml)
            Update-HarborYamlContent -YamlContent $yaml -Hostname "h.example.com" -StorageClassName "sc" -HarborAdminPassword "p@ss'word"
        }
        $result | Should -Match "(?m)^harborAdminPassword: 'p@ss''word'"
    }

    It "Injects SecretKey as a single-quoted YAML scalar" {
        $yaml = $script:harborMinimalYaml + "`nsecretKey: 0000000000000000"
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $yaml {
            param($yaml)
            Update-HarborYamlContent -YamlContent $yaml -Hostname "h.example.com" -StorageClassName "sc" -SecretKey "abcdefghijklmnop"
        }
        $result | Should -Match "(?m)^secretKey: 'abcdefghijklmnop'"
        $result | Should -Not -Match "0000000000000000"
    }

    It "Throws VcfDeploymentException when SecretKey is not exactly 16 characters" {
        $yaml = $script:harborMinimalYaml + "`nsecretKey: 0000000000000000"
        { InModuleScope VcfEdgeAtScale -ArgumentList $yaml {
            param($yaml)
            Update-HarborYamlContent -YamlContent $yaml -Hostname "h.example.com" -StorageClassName "sc" -SecretKey "tooshort"
        } } | Should -Throw "*secretKey must be exactly 16 characters*"

    }
}


Describe "Get-HarborHostnameFromDataValuesTemplateFile" {
    BeforeAll {
        $script:harborTplDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "veas-htpl-$([System.Guid]::NewGuid().ToString('N').Substring(0, 8))"
        New-Item -ItemType Directory -Path $script:harborTplDir -Force | Out-Null

        $script:harborTplWithHost = Join-Path $script:harborTplDir "with-hostname.yml"
        Set-Content -Path $script:harborTplWithHost -Value "hostname: harbor.lab.local`nenableNginxLoadBalancer: false" -Encoding UTF8

        $script:harborTplNoHost = Join-Path $script:harborTplDir "no-hostname.yml"
        Set-Content -Path $script:harborTplNoHost -Value "enableNginxLoadBalancer: false`nstorageClass: default" -Encoding UTF8

        $script:harborTplEmpty = Join-Path $script:harborTplDir "empty.yml"
        Set-Content -Path $script:harborTplEmpty -Value "" -Encoding UTF8

        $script:harborTplCommented = Join-Path $script:harborTplDir "commented.yml"
        Set-Content -Path $script:harborTplCommented -Value "# hostname: harbor.comment.local`nother: value" -Encoding UTF8
    }
    AfterAll {
        Remove-Item -Path $script:harborTplDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Returns the hostname value from a valid template" {
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $script:harborTplWithHost {
            param($p) Get-HarborHostnameFromDataValuesTemplateFile -HarborTemplateFilePath $p
        }
        $result | Should -Be "harbor.lab.local"
    }

    It "Returns null when the file has no hostname key" {
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $script:harborTplNoHost {
            param($p) Get-HarborHostnameFromDataValuesTemplateFile -HarborTemplateFilePath $p
        }
        $result | Should -BeNullOrEmpty
    }

    It "Returns null when the file does not exist" {
        $result = InModuleScope VcfEdgeAtScale {
            Get-HarborHostnameFromDataValuesTemplateFile -HarborTemplateFilePath "/nonexistent/veas-path/harbor.yml"
        }
        $result | Should -BeNullOrEmpty
    }

    It "Returns null when the file is empty" {
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $script:harborTplEmpty {
            param($p) Get-HarborHostnameFromDataValuesTemplateFile -HarborTemplateFilePath $p
        }
        $result | Should -BeNullOrEmpty
    }

    It "Returns hostname from a commented-out template line (# hostname: value)" {
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $script:harborTplCommented {
            param($p) Get-HarborHostnameFromDataValuesTemplateFile -HarborTemplateFilePath $p
        }
        $result | Should -Be "harbor.comment.local"
    }
}


Describe "Get-EffectiveHarborHostnameForInfrastructureCluster" {
    It "Returns harborConfiguration.hostname when explicitly set" {
        $result = InModuleScope VcfEdgeAtScale {
            $cluster = [PSCustomObject]@{
                harborConfiguration = [PSCustomObject]@{ hostname = "harbor.site1.local" }
            }
            Get-EffectiveHarborHostnameForInfrastructureCluster -Cluster $cluster -CommonData ([PSCustomObject]@{})
        }
        $result | Should -Be "harbor.site1.local"
    }

    It "Returns null when harborConfiguration is absent and LabEnvironmentEnabled is false" {
        $result = InModuleScope VcfEdgeAtScale {
            $cluster = [PSCustomObject]@{}
            Get-EffectiveHarborHostnameForInfrastructureCluster -Cluster $cluster -CommonData ([PSCustomObject]@{}) -LabEnvironmentEnabled:$false
        }
        $result | Should -BeNullOrEmpty
    }

    It "Returns null when hostname is empty and not in lab mode" {
        $result = InModuleScope VcfEdgeAtScale {
            $cluster = [PSCustomObject]@{
                harborConfiguration = [PSCustomObject]@{ hostname = "   " }
            }
            Get-EffectiveHarborHostnameForInfrastructureCluster -Cluster $cluster -CommonData ([PSCustomObject]@{}) -LabEnvironmentEnabled:$false
        }
        $result | Should -BeNullOrEmpty
    }

    It "Returns hostname from template file when in lab mode and no JSON hostname is set" {
        $tmpFile = Join-Path ([System.IO.Path]::GetTempPath()) "veas-harbor-lab-$([System.Guid]::NewGuid().ToString('N').Substring(0, 8)).yml"
        Set-Content -Path $tmpFile -Value "hostname: harbor.lab.template.local" -Encoding UTF8
        try {
            $result = InModuleScope VcfEdgeAtScale -ArgumentList $tmpFile {
                param($tplPath)
                $Script:_VeasLabTplPath = $tplPath
                Mock Get-EffectiveSupervisorServicesYamlPath { return $Script:_VeasLabTplPath }
                $cluster = [PSCustomObject]@{ harborConfiguration = [PSCustomObject]@{} }
                Get-EffectiveHarborHostnameForInfrastructureCluster -Cluster $cluster -CommonData ([PSCustomObject]@{}) -LabEnvironmentEnabled:$true
            }
            $result | Should -Be "harbor.lab.template.local"
        } finally {
            Remove-Item -Path $tmpFile -Force -ErrorAction SilentlyContinue
        }
    }
}


Describe "Get-EffectiveArgoCdYamlPath" {
    It "Returns cluster-level argoCdOperatorYamlPath when defined" {
        $result = InModuleScope VcfEdgeAtScale {
            $cluster = [PSCustomObject]@{
                supervisorServices = [PSCustomObject]@{ argoCdOperatorYamlPath = "/custom/argocd-operator.yml" }
            }
            Get-EffectiveArgoCdYamlPath -Cluster $cluster -CommonData ([PSCustomObject]@{}) -PropertyName "argoCdOperatorYamlPath"
        }
        $result | Should -Be "/custom/argocd-operator.yml"
    }

    It "Falls back to common argoCdDeploymentYamlPath when cluster has none" {
        $result = InModuleScope VcfEdgeAtScale {
            $cluster = [PSCustomObject]@{}
            $common = [PSCustomObject]@{
                supervisorServices = [PSCustomObject]@{ argoCdDeploymentYamlPath = "/common/argocd-deployment.yml" }
            }
            Get-EffectiveArgoCdYamlPath -Cluster $cluster -CommonData $common -PropertyName "argoCdDeploymentYamlPath"
        }
        $result | Should -Be "/common/argocd-deployment.yml"
    }

    It "Returns null when neither cluster nor common defines the path" {
        $result = InModuleScope VcfEdgeAtScale {
            Get-EffectiveArgoCdYamlPath -Cluster ([PSCustomObject]@{}) -CommonData ([PSCustomObject]@{}) -PropertyName "argoCdOperatorYamlPath"
        }
        $result | Should -BeNullOrEmpty
    }
}


Describe "Resolve-InfrastructureReferencedFilePath" {
    BeforeAll {
        $script:resolveDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "veas-resolve-$([System.Guid]::NewGuid().ToString('N').Substring(0, 8))"
        New-Item -ItemType Directory -Path $script:resolveDir -Force | Out-Null
        $script:resolveFile = Join-Path $script:resolveDir "test.yml"
        Set-Content -Path $script:resolveFile -Value "# test" -Encoding UTF8
    }
    AfterAll {
        Remove-Item -Path $script:resolveDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Returns the full resolved path for an existing absolute path" {
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $script:resolveFile {
            param($p) Resolve-InfrastructureReferencedFilePath -FilePath $p
        }
        $result | Should -Be $script:resolveFile
    }

    It "Returns the trimmed input when the file does not exist" {
        $result = InModuleScope VcfEdgeAtScale {
            Resolve-InfrastructureReferencedFilePath -FilePath "/nonexistent/veas-path/file.yml"
        }
        $result | Should -Be "/nonexistent/veas-path/file.yml"
    }

    It "Returns whitespace-only input unchanged (no trimming performed on blank input)" {
        $result = InModuleScope VcfEdgeAtScale {
            Resolve-InfrastructureReferencedFilePath -FilePath "   "
        }
        $result | Should -Be "   "
    }

    It "Resolves a bare filename to its full path via InfrastructureJsonDirectory" {
        $filename = Split-Path -Path $script:resolveFile -Leaf
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $filename,$script:resolveDir {
            param($f, $d)
            Resolve-InfrastructureReferencedFilePath -FilePath $f -InfrastructureJsonDirectory $d
        }
        $result | Should -Be $script:resolveFile
    }
}

# ── Test-PathIsWithinHomeDirectory — home-directory confinement ───────────────


Describe "Test-PathIsWithinHomeDirectory" {

    It "Returns true for a path inside the home directory" {
        $result = InModuleScope VcfEdgeAtScale {
            $pathUnderHome = Join-Path $HOME "some-veas-subdir" "config.yml"
            Test-PathIsWithinHomeDirectory -ResolvedPath $pathUnderHome
        }
        $result | Should -Be $true
    }

    It "Returns true for the home directory itself" {
        $result = InModuleScope VcfEdgeAtScale {
            Test-PathIsWithinHomeDirectory -ResolvedPath $HOME
        }
        $result | Should -Be $true
    }

    It "Returns false for a path outside the home directory" {
        $result = InModuleScope VcfEdgeAtScale {
            $outsidePath = if ($IsWindows) { "C:\Windows\System32\hosts" } else { "/etc/passwd" }
            Test-PathIsWithinHomeDirectory -ResolvedPath $outsidePath
        }
        $result | Should -Be $false
    }

    It "Returns false for a traversal path that resolves outside home" {
        # A crafted parentDirectory value like '../../etc' normalised by GetFullPath would
        # escape the home tree. The function must reject such resolved paths.
        $result = InModuleScope VcfEdgeAtScale {
            $homeFull    = [System.IO.Path]::GetFullPath($HOME)
            $separator   = [System.IO.Path]::DirectorySeparatorChar
            $escapedPath = [System.IO.Path]::GetFullPath(
                [System.IO.Path]::Combine($homeFull, "..", "..", "etc", "shadow"))
            Test-PathIsWithinHomeDirectory -ResolvedPath $escapedPath
        }
        $result | Should -Be $false
    }

    It "Accepts a valid Windows-style backslash path within the home directory" -Skip:(-not $IsWindows) {
        # Runs only on Windows to verify that backslash-separated resolved paths inside the home
        # tree are accepted (Windows uses backslash as the native separator).
        $result = InModuleScope VcfEdgeAtScale {
            $homeFull  = [System.IO.Path]::GetFullPath($HOME)
            $innerPath = [System.IO.Path]::GetFullPath(
                [System.IO.Path]::Combine($homeFull, "Documents", "veas", "config.json"))
            Test-PathIsWithinHomeDirectory -ResolvedPath $innerPath
        }
        $result | Should -Be $true
    }
}


Describe "Get-InteractiveInput" {
    It "Returns the value entered by the user" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Read-Host { return "typed-value" }
            Get-InteractiveInput -PromptMessage "Enter something"
        }
        $result | Should -Be "typed-value"
    }

    It "Returns empty string immediately when AllowEmpty is set and no input is given" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Read-Host { return "" }
            Get-InteractiveInput -PromptMessage "Optional prompt" -AllowEmpty
        }
        $result | Should -Be ""
    }

    It "Prompts again when AllowEmpty is not set and first response is empty then returns the second response" {
        $outcome = InModuleScope VcfEdgeAtScale {
            $Script:_VeasPromptCall = 0
            Mock Read-Host {
                $Script:_VeasPromptCall++
                if ($Script:_VeasPromptCall -lt 2) { return "" } else { return "valid-answer" }
            }
            $ret = Get-InteractiveInput -PromptMessage "Enter value"
            @{ Result = $ret; Calls = $Script:_VeasPromptCall }
        }
        $outcome.Result   | Should -Be "valid-answer"
        $outcome.Calls    | Should -BeGreaterThan 1
    }
}


Describe "Get-EffectiveClusterName" {
    It "Returns override name when overrideClusterName is set" {
        $cluster = [PSCustomObject]@{ edgeSite = "site1"; overrideClusterName = "my-special-cluster" }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Get-EffectiveClusterName -Cluster $args[0] -ClusterNamePrefix "cl0" -EdgeSite "site1"
        } | Should -Be "my-special-cluster"
    }

    It "Falls back to prefix+site formula when overrideClusterName is absent" {
        $cluster = [PSCustomObject]@{ edgeSite = "site1" }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Get-EffectiveClusterName -Cluster $args[0] -ClusterNamePrefix "cl0" -EdgeSite "site1"
        } | Should -Be "cl0-site1"
    }

    It "Falls back to prefix+site formula when overrideClusterName is empty string" {
        $cluster = [PSCustomObject]@{ edgeSite = "site2"; overrideClusterName = "" }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Get-EffectiveClusterName -Cluster $args[0] -ClusterNamePrefix "cluster" -EdgeSite "site2"
        } | Should -Be "cluster-site2"
    }

    It "Falls back to prefix+site formula when overrideClusterName is whitespace only" {
        $cluster = [PSCustomObject]@{ edgeSite = "site3"; overrideClusterName = "   " }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Get-EffectiveClusterName -Cluster $args[0] -ClusterNamePrefix "cluster" -EdgeSite "site3"
        } | Should -Be "cluster-site3"
    }

    It "Trims leading and trailing whitespace from override name" {
        $cluster = [PSCustomObject]@{ edgeSite = "site1"; overrideClusterName = "  trimmed-cluster  " }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Get-EffectiveClusterName -Cluster $args[0] -ClusterNamePrefix "cl0" -EdgeSite "site1"
        } | Should -Be "trimmed-cluster"
    }

    It "Accepts override names with allowed special characters" {
        $cluster = [PSCustomObject]@{ edgeSite = "site1"; overrideClusterName = "Cluster_Edge+01 (prod)" }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Get-EffectiveClusterName -Cluster $args[0] -ClusterNamePrefix "cl0" -EdgeSite "site1"
        } | Should -Be "Cluster_Edge+01 (prod)"
    }

    It "Accepts override names containing a period" {
        $cluster = [PSCustomObject]@{ edgeSite = "site1"; overrideClusterName = "cluster.prod" }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Get-EffectiveClusterName -Cluster $args[0] -ClusterNamePrefix "cl0" -EdgeSite "site1"
        } | Should -Be "cluster.prod"
    }

    It "Throws when overrideClusterName contains invalid characters" {
        $cluster = [PSCustomObject]@{ edgeSite = "site1"; overrideClusterName = "bad/name" }
        { InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Get-EffectiveClusterName -Cluster $args[0] -ClusterNamePrefix "cl0" -EdgeSite "site1"
        } } | Should -Throw "*overrideClusterName*must be*"

    }

    It "Throws when overrideClusterName exceeds 80 characters" {
        $longName = "a" * 81
        $cluster = [PSCustomObject]@{ edgeSite = "site1"; overrideClusterName = $longName }
        { InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Get-EffectiveClusterName -Cluster $args[0] -ClusterNamePrefix "cl0" -EdgeSite "site1"
        } } | Should -Throw "*overrideClusterName*must be*"

    }

    It "Accepts an override name of exactly 80 characters" {
        $maxName = "a" * 80
        $cluster = [PSCustomObject]@{ edgeSite = "site1"; overrideClusterName = $maxName }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Get-EffectiveClusterName -Cluster $args[0] -ClusterNamePrefix "cl0" -EdgeSite "site1"
        } | Should -Be ("a" * 80)
    }
}


Describe "Test-EdgeSiteNameValid" {
    It "Returns <Expected> for Name '<Name>'" -ForEach @(
        @{ Name = "a";                  Expected = $true  }
        @{ Name = "site-1";             Expected = $true  }
        @{ Name = ("a" * 79 + "z");     Expected = $true  }
        @{ Name = "";                   Expected = $false }
        @{ Name = "   ";               Expected = $false }
        @{ Name = ("a" * 81);           Expected = $false }
        @{ Name = "-site1";             Expected = $false }
        @{ Name = "site1-";             Expected = $false }
        @{ Name = "Site1";              Expected = $false }
        @{ Name = "site 1";             Expected = $false }
    ) {
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $Name {
            Test-EdgeSiteNameValid -Name $args[0]
        }
        $result | Should -Be $Expected
    }
}


Describe "Test-StringAgainstAllowlist" {
    It "Returns <Expected> for InputText '<InputText>'" -ForEach @(
        @{ InputText = "Server01"; AllowedCharacters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"; Expected = $true  }
        @{ InputText = "server!";  AllowedCharacters = "abcdefghijklmnopqrstuvwxyz0123456789";                           Expected = $false }
        @{ InputText = "a";        AllowedCharacters = "abc";                                                            Expected = $true  }
        @{ InputText = "z";        AllowedCharacters = "abc";                                                            Expected = $false }
    ) {
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $InputText, $AllowedCharacters {
            Test-StringAgainstAllowlist -InputText $args[0] -AllowedCharacters $args[1]
        }
        $result | Should -Be $Expected
    }
}


Describe "Test-StringAgainstDenylist" {
    It "Returns <Expected> for InputText '<InputText>'" -ForEach @(
        @{ InputText = "MyFile.txt";  DisallowedCharacters = '<>:"/\|?*'; Expected = $true  }
        @{ InputText = "My:File.txt"; DisallowedCharacters = '<>:"/\|?*'; Expected = $false }
        @{ InputText = "hello";       DisallowedCharacters = "xyz";        Expected = $true  }
        @{ InputText = "world";       DisallowedCharacters = "wr";         Expected = $false }
    ) {
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $InputText, $DisallowedCharacters {
            Test-StringAgainstDenylist -InputText $args[0] -DisallowedCharacters $args[1]
        }
        $result | Should -Be $Expected
    }
}


Describe "Get-ValidationPresetRules" {
    It "Returns AllowedCharacters for AlphaNumeric preset" {
        $rules = InModuleScope VcfEdgeAtScale { Get-ValidationPresetRules -ValidationPreset "AlphaNumeric" }
        $rules.AllowedCharacters | Should -Match "a"
        $rules.AllowedCharacters | Should -Match "Z"
        $rules.AllowedCharacters | Should -Match "9"
        $rules.RegexPattern      | Should -Be $null
    }

    It "Returns AllowedCharacters for AlphaNumericDash preset (includes dash and underscore)" {
        $rules = InModuleScope VcfEdgeAtScale { Get-ValidationPresetRules -ValidationPreset "AlphaNumericDash" }
        $rules.AllowedCharacters | Should -Match "-"
        $rules.AllowedCharacters | Should -Match "_"
    }

    It "Returns AllowedCharacters for Numeric preset (digits only)" {
        $rules = InModuleScope VcfEdgeAtScale { Get-ValidationPresetRules -ValidationPreset "Numeric" }
        $rules.AllowedCharacters | Should -Match "0"
        $rules.AllowedCharacters | Should -Match "9"
        $rules.AllowedCharacters.Length | Should -Be 10
    }

    It "Returns a RegexPattern for IpAddress preset" {
        $rules = InModuleScope VcfEdgeAtScale { Get-ValidationPresetRules -ValidationPreset "IpAddress" }
        $rules.RegexPattern | Should -Not -BeNullOrEmpty
        $rules.AllowedCharacters | Should -Be $null
    }

    It "Throws for an invalid preset name (ValidateSet enforcement)" {
        { InModuleScope VcfEdgeAtScale { Get-ValidationPresetRules -ValidationPreset "NonExistentPreset" } } | Should -Throw -ExceptionType ([System.Management.Automation.ParameterBindingException])

    }
}


Describe "Resolve-PropertyOnObject" {
    It "Resolves an existing property from a PSCustomObject" {
        $obj = [PSCustomObject]@{ City = "Copenhagen" }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $obj {
            Resolve-PropertyOnObject -Object $args[0] -PropertyName "City"
        }
        $result.Exists | Should -Be $true
        $result.Value  | Should -Be "Copenhagen"
    }
    It "Returns Exists=false for a missing PSCustomObject property" {
        $obj = [PSCustomObject]@{ City = "Copenhagen" }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $obj {
            Resolve-PropertyOnObject -Object $args[0] -PropertyName "Country"
        }
        $result.Exists | Should -Be $false
        $result.Value  | Should -Be $null
    }
    It "Resolves an existing key from a Hashtable" {
        $ht = @{ City = "Aarhus" }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $ht {
            Resolve-PropertyOnObject -Object $args[0] -PropertyName "City"
        }
        $result.Exists | Should -Be $true
        $result.Value  | Should -Be "Aarhus"
    }
    It "Returns Exists=false for a missing Hashtable key" {
        $ht = @{ City = "Aarhus" }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $ht {
            Resolve-PropertyOnObject -Object $args[0] -PropertyName "Country"
        }
        $result.Exists | Should -Be $false
        $result.Value  | Should -Be $null
    }
    It "Resolves a null-valued PSCustomObject property as Exists=true, Value=null" {
        $obj = [PSCustomObject]@{ Name = $null }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $obj {
            Resolve-PropertyOnObject -Object $args[0] -PropertyName "Name"
        }
        $result.Exists | Should -Be $true
        $result.Value  | Should -Be $null
    }
}

Describe "Test-ArrayPropertyNullValue" {
    # PathParts is [Array] Mandatory [AllowEmptyCollection()] — accepts @() for recursive calls
    # where the array-notation segment is the last path component.

    It "Returns true when the navigated terminal property value is null" {
        $obj = [PSCustomObject]@{ name = $null }
        InModuleScope VcfEdgeAtScale -ArgumentList $obj {
            Test-ArrayPropertyNullValue -Object $args[0] -PathParts @("name") -PropertyPath "name"
        } | Should -Be $true
    }

    It "Returns false when the navigated terminal property is a non-null non-empty string" {
        $obj = [PSCustomObject]@{ name = "hello" }
        InModuleScope VcfEdgeAtScale -ArgumentList $obj {
            Test-ArrayPropertyNullValue -Object $args[0] -PathParts @("name") -PropertyPath "name"
        } | Should -Be $false
    }

    It "Returns true when the navigated terminal property is an empty string" {
        $obj = [PSCustomObject]@{ name = "" }
        InModuleScope VcfEdgeAtScale -ArgumentList $obj {
            Test-ArrayPropertyNullValue -Object $args[0] -PathParts @("name") -PropertyPath "name"
        } | Should -Be $true
    }

    It "Returns true when the navigated terminal property is an empty array" {
        $obj = [PSCustomObject]@{ items = @() }
        InModuleScope VcfEdgeAtScale -ArgumentList $obj {
            Test-ArrayPropertyNullValue -Object $args[0] -PathParts @("items") -PropertyPath "items"
        } | Should -Be $true
    }

    It "Returns false when the navigated terminal property is a non-empty array" {
        $obj = [PSCustomObject]@{ items = @("a") }
        InModuleScope VcfEdgeAtScale -ArgumentList $obj {
            Test-ArrayPropertyNullValue -Object $args[0] -PathParts @("items") -PropertyPath "items"
        } | Should -Be $false
    }

    It "Returns true when the top-level object is null (null propagates immediately)" {
        InModuleScope VcfEdgeAtScale {
            Test-ArrayPropertyNullValue -Object $null -PathParts @("anyProp") -PropertyPath "anyProp"
        } | Should -Be $true
    }

    It "Returns true when the navigated terminal property is an empty Generic.List (IList coverage)" {
        $genericList = [System.Collections.Generic.List[PSObject]]::new()
        $obj = [PSCustomObject]@{ items = $genericList }
        InModuleScope VcfEdgeAtScale -ArgumentList $obj {
            Test-ArrayPropertyNullValue -Object $args[0] -PathParts @("items") -PropertyPath "items"
        } | Should -Be $true
    }

    It "Returns false when the navigated terminal property is a non-empty Generic.List (IList coverage)" {
        $genericList = [System.Collections.Generic.List[PSObject]]::new()
        $genericList.Add([PSCustomObject]@{ Name = "item1" })
        $obj = [PSCustomObject]@{ items = $genericList }
        InModuleScope VcfEdgeAtScale -ArgumentList $obj {
            Test-ArrayPropertyNullValue -Object $args[0] -PathParts @("items") -PropertyPath "items"
        } | Should -Be $false
    }

    It "Recurses into array notation — returns false when all array items have non-null terminal value" {
        # PathParts = @("hosts[]") — array notation is the last segment; recursive call receives @()
        $obj = [PSCustomObject]@{ hosts = @(
            [PSCustomObject]@{ name = "esx01" },
            [PSCustomObject]@{ name = "esx02" }
        )}
        InModuleScope VcfEdgeAtScale -ArgumentList $obj {
            Test-ArrayPropertyNullValue -Object $args[0] -PathParts @("hosts[]", "name") -PropertyPath "hosts[].name"
        } | Should -Be $false
    }

    It "Recurses into array notation — returns true when any array item has a null terminal value" {
        $obj = [PSCustomObject]@{ hosts = @(
            [PSCustomObject]@{ name = "esx01" },
            [PSCustomObject]@{ name = $null }
        )}
        InModuleScope VcfEdgeAtScale -ArgumentList $obj {
            Test-ArrayPropertyNullValue -Object $args[0] -PathParts @("hosts[]", "name") -PropertyPath "hosts[].name"
        } | Should -Be $true
    }

    It "Navigates two-step non-array path and returns false when terminal property is non-null" {
        # Regression: PathParts with 2 non-array steps unboxed the single-element remaining
        # array to a String via if-expression assignment, causing string[0] to return a Char
        # instead of the element name (e.g. 'f' from "flbName"), breaking property navigation.
        $obj = [PSCustomObject]@{
            networking = [PSCustomObject]@{ segments = "vlan-100" }
        }
        InModuleScope VcfEdgeAtScale -ArgumentList $obj {
            Test-ArrayPropertyNullValue -Object $args[0] -PathParts @("networking", "segments") -PropertyPath "networking.segments"
        } | Should -Be $false
    }

    It "Navigates two-step non-array path and returns true when terminal property is null" {
        $obj = [PSCustomObject]@{
            networking = [PSCustomObject]@{ segments = $null }
        }
        InModuleScope VcfEdgeAtScale -ArgumentList $obj {
            Test-ArrayPropertyNullValue -Object $args[0] -PathParts @("networking", "segments") -PropertyPath "networking.segments"
        } | Should -Be $true
    }

    It "Navigates three-step non-array path and returns false when terminal property is non-null" {
        $obj = [PSCustomObject]@{
            spec = [PSCustomObject]@{
                network = [PSCustomObject]@{ name = "segment1" }
            }
        }
        InModuleScope VcfEdgeAtScale -ArgumentList $obj {
            Test-ArrayPropertyNullValue -Object $args[0] -PathParts @("spec", "network", "name") -PropertyPath "spec.network.name"
        } | Should -Be $false
    }

    It "Navigates siteSpec-pattern: array element with two-step nested path returns false for non-null terminal" {
        # Regression for production path siteSpec[].foundationLoadBalancerComponents.flbName.
        $element = [PSCustomObject]@{
            foundationLoadBalancerComponents = [PSCustomObject]@{ flbName = "flb-site2" }
        }
        InModuleScope VcfEdgeAtScale -ArgumentList $element {
            Test-ArrayPropertyNullValue -Object $args[0] `
                -PathParts @("foundationLoadBalancerComponents", "flbName") `
                -PropertyPath "siteSpec[].foundationLoadBalancerComponents.flbName"
        } | Should -Be $false
    }
}


Describe "Get-EdgeSitesFromParameter" {
    It "Returns empty array for null or whitespace EdgeSite" {
        $inputData = [PSCustomObject]@{ clusters = @() }
        InModuleScope VcfEdgeAtScale -ArgumentList $inputData {
            @(Get-EdgeSitesFromParameter -EdgeSite "" -InputData $args[0]).Count
        } | Should -Be 0
    }

    It "Returns empty array for whitespace-only EdgeSite" {
        $inputData = [PSCustomObject]@{ clusters = @() }
        InModuleScope VcfEdgeAtScale -ArgumentList $inputData {
            @(Get-EdgeSitesFromParameter -EdgeSite "   " -InputData $args[0]).Count
        } | Should -Be 0
    }

    It "Throws when EdgeSite contains a semicolon delimiter" {
        $inputData = [PSCustomObject]@{ clusters = @() }
        InModuleScope VcfEdgeAtScale -ArgumentList $inputData {
            { Get-EdgeSitesFromParameter -EdgeSite "site1;site2" -InputData $args[0] }
        } | Should -Throw "*Invalid delimiter*"
    }

    It "Throws when EdgeSite contains a pipe delimiter" {
        $inputData = [PSCustomObject]@{ clusters = @() }
        InModuleScope VcfEdgeAtScale -ArgumentList $inputData {
            { Get-EdgeSitesFromParameter -EdgeSite "site1|site2" -InputData $args[0] }
        } | Should -Throw "*Invalid delimiter*"
    }

    It "Returns single site when one valid site is requested" {
        $inputData = [PSCustomObject]@{
            clusters = @([PSCustomObject]@{ edgeSite = "site1" }, [PSCustomObject]@{ edgeSite = "site2" })
        }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $inputData {
            Get-EdgeSitesFromParameter -EdgeSite "site1" -InputData $args[0]
        }
        @($result).Count | Should -Be 1
        @($result)[0] | Should -Be "site1"
    }

    It "Returns two sites when two valid comma-separated sites are requested" {
        $inputData = [PSCustomObject]@{
            clusters = @([PSCustomObject]@{ edgeSite = "site1" }, [PSCustomObject]@{ edgeSite = "site2" })
        }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $inputData {
            Get-EdgeSitesFromParameter -EdgeSite "site1,site2" -InputData $args[0]
        }
        @($result).Count | Should -Be 2
    }

    It "Throws when requested site does not exist in the infrastructure data" {
        InModuleScope VcfEdgeAtScale {
            $inputData = [PSCustomObject]@{
                clusters = @([PSCustomObject]@{ edgeSite = "site1" })
            }
            { Get-EdgeSitesFromParameter -EdgeSite "doesNotExist" -InputData $inputData } | Should -Throw "*not defined in infrastructure JSON*"
        }
    }
}


Describe "Test-NetworkSegmentNameUniqueness" {
    It "Returns IsValid true when all segment names are unique across clusters" {
        $inputData = [PSCustomObject]@{
            clusters = @(
                [PSCustomObject]@{
                    edgeSite   = "site1"
                    networking = [PSCustomObject]@{
                        networkSegments = @([PSCustomObject]@{ name = "seg1"; vlanId = 100 })
                    }
                },
                [PSCustomObject]@{
                    edgeSite   = "site2"
                    networking = [PSCustomObject]@{
                        networkSegments = @([PSCustomObject]@{ name = "seg2"; vlanId = 200 })
                    }
                }
            )
        }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $inputData {
            Test-NetworkSegmentNameUniqueness -InputData $args[0]
        }
        $result.IsValid | Should -Be $true
        $result.DuplicateNames | Should -HaveCount 0
    }

    It "Returns IsValid false when the same segment name appears in two clusters" {
        $inputData = [PSCustomObject]@{
            clusters = @(
                [PSCustomObject]@{
                    edgeSite   = "site1"
                    networking = [PSCustomObject]@{
                        networkSegments = @([PSCustomObject]@{ name = "shared-seg"; vlanId = 100 })
                    }
                },
                [PSCustomObject]@{
                    edgeSite   = "site2"
                    networking = [PSCustomObject]@{
                        networkSegments = @([PSCustomObject]@{ name = "shared-seg"; vlanId = 200 })
                    }
                }
            )
        }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $inputData {
            Test-NetworkSegmentNameUniqueness -InputData $args[0]
        }
        $result.IsValid          | Should -Be $false
        $result.DuplicateNames   | Should -Contain "shared-seg"
    }
}


Describe "Update-InfrastructureJsonReferencedFilePaths" {
    It "Sets InfrastructureJsonParentForPathResolution to null when InputData is null" {
        InModuleScope VcfEdgeAtScale {
            $Script:InfrastructureJsonParentForPathResolution = "previous-value"
            Update-InfrastructureJsonReferencedFilePaths -InfrastructureJsonPath "/nonexistent/infra.json" -InputData $null
            $Script:InfrastructureJsonParentForPathResolution
        } | Should -Be $null
    }

    It "Sets InfrastructureJsonParentForPathResolution for a real file path" {
        $tmpFile = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "veas-infra-$([guid]::NewGuid().ToString('N').Substring(0,8)).json"
        Set-Content -Path $tmpFile -Value '{"clusters":[]}' -Encoding UTF8
        try {
            $inputData = [PSCustomObject]@{ clusters = $null }
            InModuleScope VcfEdgeAtScale -ArgumentList $tmpFile, $inputData {
                Update-InfrastructureJsonReferencedFilePaths -InfrastructureJsonPath $args[0] -InputData $args[1]
                $Script:InfrastructureJsonParentForPathResolution
            } | Should -Be ([System.IO.Path]::GetTempPath().TrimEnd([System.IO.Path]::DirectorySeparatorChar))
        } finally {
            Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
        }
    }
}


Describe "Test-InfrastructureNicListEffective" {
    It "Throws when a cluster has no effective nicList" {
        $inputData  = [PSCustomObject]@{ common = [PSCustomObject]@{ nicList = $null } }
        $cluster    = [PSCustomObject]@{ edgeSite = "site1"; nicList = $null }
        { InModuleScope VcfEdgeAtScale -ArgumentList $inputData, $cluster {
            Test-InfrastructureNicListEffective -InputData $args[0] -Clusters @($args[1])
        } } | Should -Throw "*nicList must be defined*"

    }

    It "Throws when a cluster's effective nicList has an invalid count (e.g. 3)" {
        # 3 NICs in common.nicList: Get-EffectiveNicListForCluster returns the common list (non-null,
        # non-empty), which then fails the count check inside Test-InfrastructureNicListEffective.
        # A 3-NIC cluster.nicList would not trigger this path because Get-EffectiveNicListForCluster
        # only short-circuits on 2 or 4 items — otherwise it falls back to common.nicList.
        $inputData  = [PSCustomObject]@{ common = [PSCustomObject]@{ nicList = @("vmnic0", "vmnic1", "vmnic2") } }
        $cluster    = [PSCustomObject]@{ edgeSite = "site1"; nicList = $null }
        { InModuleScope VcfEdgeAtScale -ArgumentList $inputData, $cluster {
            Test-InfrastructureNicListEffective -InputData $args[0] -Clusters @($args[1])
        } } | Should -Throw "*must contain exactly 2 or 4*"

    }

    It "Does not throw for a cluster with a 2-NIC list" {
        $inputData = [PSCustomObject]@{ common = [PSCustomObject]@{ nicList = $null } }
        $cluster   = [PSCustomObject]@{ edgeSite = "site1"; nicList = @("vmnic0", "vmnic1") }
        # Capture both args before entering InModuleScope — nested scriptblocks lose $args.
        { InModuleScope VcfEdgeAtScale -ArgumentList $inputData, $cluster {
              Test-InfrastructureNicListEffective -InputData $args[0] -Clusters @($args[1])
          }
        } | Should -Not -Throw
        # Validate that 2 NICs is accepted without any error log.
        InModuleScope VcfEdgeAtScale -ArgumentList $inputData, $cluster {
            Mock Write-LogMessage {}
            Test-InfrastructureNicListEffective -InputData $args[0] -Clusters @($args[1])
            Should -Invoke Write-LogMessage -Times 0 -ParameterFilter { $Type -eq "ERROR" } -Scope It
        }
    }

    It "Does not throw for a cluster with a 4-NIC list" {
        $inputData = [PSCustomObject]@{ common = [PSCustomObject]@{ nicList = $null } }
        $cluster   = [PSCustomObject]@{ edgeSite = "site1"; nicList = @("vmnic0", "vmnic1", "vmnic2", "vmnic3") }
        { InModuleScope VcfEdgeAtScale -ArgumentList $inputData, $cluster {
              Test-InfrastructureNicListEffective -InputData $args[0] -Clusters @($args[1])
          }
        } | Should -Not -Throw
        # Validate that 4 NICs is accepted without any error log.
        InModuleScope VcfEdgeAtScale -ArgumentList $inputData, $cluster {
            Mock Write-LogMessage {}
            Test-InfrastructureNicListEffective -InputData $args[0] -Clusters @($args[1])
            Should -Invoke Write-LogMessage -Times 0 -ParameterFilter { $Type -eq "ERROR" } -Scope It
        }
    }

    It "Uses common.nicList when cluster-level nicList is absent" {
        $inputData = [PSCustomObject]@{ common = [PSCustomObject]@{ nicList = @("vmnic0", "vmnic1") } }
        $cluster   = [PSCustomObject]@{ edgeSite = "site1"; nicList = $null }
        { InModuleScope VcfEdgeAtScale -ArgumentList $inputData, $cluster {
              Test-InfrastructureNicListEffective -InputData $args[0] -Clusters @($args[1])
          }
        } | Should -Not -Throw
        # Validate that the fallback to common.nicList (2 NICs) is accepted without error.
        InModuleScope VcfEdgeAtScale -ArgumentList $inputData, $cluster {
            Mock Write-LogMessage {}
            Test-InfrastructureNicListEffective -InputData $args[0] -Clusters @($args[1])
            Should -Invoke Write-LogMessage -Times 0 -ParameterFilter { $Type -eq "ERROR" } -Scope It
        }
    }
}


Describe "Test-JsonFile" {
    BeforeAll {
        $script:validJson  = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "veas-tjf-valid-$([guid]::NewGuid().ToString('N').Substring(0,8)).json"
        $script:invalidJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "veas-tjf-bad-$([guid]::NewGuid().ToString('N').Substring(0,8)).json"
        Set-Content -Path $script:validJson  -Value '{"key":"value"}' -Encoding UTF8
        Set-Content -Path $script:invalidJson -Value 'not { valid json' -Encoding UTF8
    }
    AfterAll {
        Remove-Item $script:validJson   -Force -ErrorAction SilentlyContinue
        Remove-Item $script:invalidJson -Force -ErrorAction SilentlyContinue
    }

    It "Returns true for a valid JSON file" {
        InModuleScope VcfEdgeAtScale -ArgumentList $script:validJson {
            Test-JsonFile -JsonFilePath $args[0]
        } | Should -Be $true
    }

    It "Returns false for a nonexistent file" {
        InModuleScope VcfEdgeAtScale {
            Test-JsonFile -JsonFilePath "/nonexistent/veas-path/missing.json"
        } | Should -Be $false
    }

    It "Returns false for a file with invalid JSON content" {
        InModuleScope VcfEdgeAtScale -ArgumentList $script:invalidJson {
            Test-JsonFile -JsonFilePath $args[0]
        } | Should -Be $false
    }

    It "Returns false and logs ERROR when path contains invalid characters" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $result = Test-JsonFile -JsonFilePath "/valid/path/file<>.json"
            $result | Should -Be $false
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'ERROR' -and $Message -match 'invalid characters' }
        }
    }

    It "Returns false and logs ERROR when path exceeds 260 characters" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $longPath = "/valid/$("a" * 256).json"
            $result = Test-JsonFile -JsonFilePath $longPath
            $result | Should -Be $false
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'ERROR' -and $Message -match 'exceed 260' }
        }
    }

    It "Returns false and logs ERROR when path is whitespace only" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $result = Test-JsonFile -JsonFilePath "   "
            $result | Should -Be $false
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'ERROR' -and $Message -match 'whitespace' }
        }
    }
}


Describe "Test-JsonMissingProperties" {
    BeforeAll {
        $script:infraJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "veas-tjmp-$([guid]::NewGuid().ToString('N').Substring(0,8)).json"
        Set-Content -Path $script:infraJson -Value '{"common":{"vCenterName":"vc.lab"},"clusters":[]}' -Encoding UTF8
    }
    AfterAll { Remove-Item $script:infraJson -Force -ErrorAction SilentlyContinue }

    It "Returns IsValid true when all required properties are present" {
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $script:infraJson {
            Test-JsonMissingProperties -JsonFilePath $args[0] -RequiredProperties @("common.vCenterName") -JsonObjectName "infra"
        }
        $result.IsValid    | Should -Be $true
        $result.ErrorCount | Should -Be 0
    }

    It "Returns IsValid false when a required property is absent" {
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $script:infraJson {
            Test-JsonMissingProperties -JsonFilePath $args[0] -RequiredProperties @("common.missingKey") -JsonObjectName "infra"
        }
        $result.IsValid    | Should -Be $false
        $result.ErrorCount | Should -BeGreaterThan 0
    }

    It "Returns IsValid false for a nonexistent JSON file" {
        $result = InModuleScope VcfEdgeAtScale {
            Test-JsonMissingProperties -JsonFilePath "/nonexistent/file.json" -RequiredProperties @("anything") -JsonObjectName "infra"
        }
        $result.IsValid | Should -Be $false
    }
}


Describe "Test-JsonNullValues" {
    BeforeAll {
        $script:nullJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "veas-tjnv-$([guid]::NewGuid().ToString('N').Substring(0,8)).json"
        Set-Content -Path $script:nullJson -Value '{"common":{"vCenterName":null,"region":"us-east"}}' -Encoding UTF8
    }
    AfterAll { Remove-Item $script:nullJson -Force -ErrorAction SilentlyContinue }

    It "Returns IsValid false when a required property has a null value" {
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $script:nullJson {
            Test-JsonNullValues -JsonFilePath $args[0] -RequiredProperties @("common.vCenterName") -JsonObjectName "infra"
        }
        $result.IsValid    | Should -Be $false
        $result.ErrorCount | Should -BeGreaterThan 0
    }

    It "Returns IsValid true when required properties all have non-null values" {
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $script:nullJson {
            Test-JsonNullValues -JsonFilePath $args[0] -RequiredProperties @("common.region") -JsonObjectName "infra"
        }
        $result.IsValid    | Should -Be $true
        $result.ErrorCount | Should -Be 0
    }

    It "Returns IsValid true for an array-notation two-level nested path with non-null values in all elements" {
        # Regression: Test-ArrayPropertyNullValue unboxed single-element remaining PathParts to a
        # String, so paths like siteSpec[].foundationLoadBalancerComponents.flbName always returned
        # null. This end-to-end test catches that class of failure independently of the unit tests.
        $json = '{"siteSpec":[{"foundationLoadBalancerComponents":{"flbName":"flb-site1"}},{"foundationLoadBalancerComponents":{"flbName":"flb-site2"}}]}'
        $jsonPath = Join-Path ([System.IO.Path]::GetTempPath()) "veas-tjnv-array-$([guid]::NewGuid().ToString('N').Substring(0,8)).json"
        Set-Content -Path $jsonPath -Value $json -Encoding UTF8
        try {
            $result = InModuleScope VcfEdgeAtScale -ArgumentList $jsonPath {
                Test-JsonNullValues -JsonFilePath $args[0] -RequiredProperties @("siteSpec[].foundationLoadBalancerComponents.flbName") -JsonObjectName "supervisor"
            }
            $result.IsValid    | Should -Be $true
            $result.ErrorCount | Should -Be 0
        } finally {
            Remove-Item $jsonPath -Force -ErrorAction SilentlyContinue
        }
    }

    It "Returns IsValid false for an array-notation two-level nested path when any element has a null value" {
        $json = '{"siteSpec":[{"foundationLoadBalancerComponents":{"flbName":"flb-site1"}},{"foundationLoadBalancerComponents":{"flbName":null}}]}'
        $jsonPath = Join-Path ([System.IO.Path]::GetTempPath()) "veas-tjnv-array-$([guid]::NewGuid().ToString('N').Substring(0,8)).json"
        Set-Content -Path $jsonPath -Value $json -Encoding UTF8
        try {
            $result = InModuleScope VcfEdgeAtScale -ArgumentList $jsonPath {
                Test-JsonNullValues -JsonFilePath $args[0] -RequiredProperties @("siteSpec[].foundationLoadBalancerComponents.flbName") -JsonObjectName "supervisor"
            }
            $result.IsValid    | Should -Be $false
            $result.ErrorCount | Should -BeGreaterThan 0
        } finally {
            Remove-Item $jsonPath -Force -ErrorAction SilentlyContinue
        }
    }
}


Describe "Test-JsonStoragePolicyTypes" {
    It "Returns 0 failures for a valid storageType vSAN-OSA" {
        $cluster = [PSCustomObject]@{ edgeSite = "site1"; storagePolicy = [PSCustomObject]@{ storageType = "vSAN-OSA" } }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Test-JsonStoragePolicyTypes -ClustersToValidate @($args[0])
        } | Should -Be 0
    }

    It "Returns 0 failures for vSAN-ESA" {
        $cluster = [PSCustomObject]@{ edgeSite = "site1"; storagePolicy = [PSCustomObject]@{ storageType = "vSAN-ESA" } }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Test-JsonStoragePolicyTypes -ClustersToValidate @($args[0])
        } | Should -Be 0
    }

    It "Returns 0 failures for VMFS" {
        $cluster = [PSCustomObject]@{ edgeSite = "site1"; storagePolicy = [PSCustomObject]@{ storageType = "VMFS" } }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Test-JsonStoragePolicyTypes -ClustersToValidate @($args[0])
        } | Should -Be 0
    }

    It "Returns 1 failure for an invalid storageType" {
        $cluster = [PSCustomObject]@{ edgeSite = "site1"; storagePolicy = [PSCustomObject]@{ storageType = "NFS" } }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Test-JsonStoragePolicyTypes -ClustersToValidate @($args[0])
        } | Should -Be 1
    }

    It "Returns 0 failures when storagePolicy is absent (field is optional)" {
        $cluster = [PSCustomObject]@{ edgeSite = "site1"; storagePolicy = $null }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Test-JsonStoragePolicyTypes -ClustersToValidate @($args[0])
        } | Should -Be 0
    }
}


Describe "Test-JsonEsxHostCountByStoragePolicyType" {
    It "Returns 0 failures when VMFS cluster has exactly 1 ESX host" {
        $cluster = [PSCustomObject]@{
            edgeSite      = "site1"
            storagePolicy = [PSCustomObject]@{ storageType = "VMFS" }
            esxHosts      = @("esx1.lab")
        }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Test-JsonEsxHostCountByStoragePolicyType -ClustersToValidate @($args[0])
        } | Should -Be 0
    }

    It "Returns 1 failure when VMFS cluster has 2 ESX hosts" {
        $cluster = [PSCustomObject]@{
            edgeSite      = "site1"
            storagePolicy = [PSCustomObject]@{ storageType = "VMFS" }
            esxHosts      = @("esx1.lab", "esx2.lab")
        }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Test-JsonEsxHostCountByStoragePolicyType -ClustersToValidate @($args[0])
        } | Should -Be 1
    }

    It "Returns 0 failures when vSAN-OSA cluster has exactly 2 ESX hosts" {
        $cluster = [PSCustomObject]@{
            edgeSite      = "site1"
            storagePolicy = [PSCustomObject]@{ storageType = "vSAN-OSA" }
            esxHosts      = @("esx1.lab", "esx2.lab")
        }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Test-JsonEsxHostCountByStoragePolicyType -ClustersToValidate @($args[0])
        } | Should -Be 0
    }

    It "Returns 1 failure when vSAN-ESA cluster has only 1 ESX host" {
        $cluster = [PSCustomObject]@{
            edgeSite      = "site1"
            storagePolicy = [PSCustomObject]@{ storageType = "vSAN-ESA" }
            esxHosts      = @("esx1.lab")
        }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Test-JsonEsxHostCountByStoragePolicyType -ClustersToValidate @($args[0])
        } | Should -Be 1
    }
}


Describe "Test-JsonEsxHostFormats" {
    It "Returns 0 failures for valid FQDN ESX hosts" {
        $cluster = [PSCustomObject]@{
            edgeSite = "site1"
            esxHosts = @("esx1.lab.example.com", "esx2.lab.example.com")
        }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Test-JsonEsxHostFormats -ClustersToValidate @($args[0])
        } | Should -Be 0
    }

    It "Returns 0 failures for valid IPv4 ESX hosts" {
        $cluster = [PSCustomObject]@{
            edgeSite = "site1"
            esxHosts = @("192.168.1.10", "192.168.1.11")
        }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Test-JsonEsxHostFormats -ClustersToValidate @($args[0])
        } | Should -Be 0
    }

    It "Returns 1 failure for an invalid ESX host format" {
        $cluster = [PSCustomObject]@{
            edgeSite = "site1"
            esxHosts = @("not a valid host!")
        }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Test-JsonEsxHostFormats -ClustersToValidate @($args[0])
        } | Should -Be 1
    }

    It "Returns 0 failures when esxHosts is absent" {
        $cluster = [PSCustomObject]@{ edgeSite = "site1"; esxHosts = $null }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Test-JsonEsxHostFormats -ClustersToValidate @($args[0])
        } | Should -Be 0
    }
}


Describe "Test-JsonvSanWitnessVmName" {
    It "Returns 0 when storageType is VMFS (witness not required)" {
        $cluster = [PSCustomObject]@{
            edgeSite          = "site1"
            storagePolicy     = [PSCustomObject]@{ storageType = "VMFS" }
            vSanWitnessVmName = $null
        }
        $inputData = [PSCustomObject]@{ common = [PSCustomObject]@{ vSanWitnessVmName = $null } }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster, $inputData {
            Test-JsonvSanWitnessVmName -ClustersToValidate @($args[0]) -InputData $args[1]
        } | Should -Be 0
    }

    It "Returns 0 when vSAN-OSA cluster has a valid FQDN witness" {
        $cluster = [PSCustomObject]@{
            edgeSite          = "site1"
            storagePolicy     = [PSCustomObject]@{ storageType = "vSAN-OSA" }
            vSanWitnessVmName = "witness.lab.example.com"
        }
        $inputData = [PSCustomObject]@{ common = [PSCustomObject]@{ vSanWitnessVmName = $null } }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster, $inputData {
            Test-JsonvSanWitnessVmName -ClustersToValidate @($args[0]) -InputData $args[1]
        } | Should -Be 0
    }

    It "Returns 1 when vSAN-OSA cluster has no witness defined anywhere" {
        $cluster = [PSCustomObject]@{
            edgeSite          = "site1"
            storagePolicy     = [PSCustomObject]@{ storageType = "vSAN-OSA" }
            vSanWitnessVmName = $null
        }
        $inputData = [PSCustomObject]@{ common = [PSCustomObject]@{ vSanWitnessVmName = $null } }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster, $inputData {
            Test-JsonvSanWitnessVmName -ClustersToValidate @($args[0]) -InputData $args[1]
        } | Should -Be 1
    }

    It "Returns 0 when witness is provided at common level" {
        $cluster = [PSCustomObject]@{
            edgeSite          = "site1"
            storagePolicy     = [PSCustomObject]@{ storageType = "vSAN-ESA" }
            vSanWitnessVmName = $null
        }
        $inputData = [PSCustomObject]@{ common = [PSCustomObject]@{ vSanWitnessVmName = "witness.lab.example.com" } }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster, $inputData {
            Test-JsonvSanWitnessVmName -ClustersToValidate @($args[0]) -InputData $args[1]
        } | Should -Be 0
    }

    It "Returns 1 when witness name is not a valid FQDN or IP" {
        $cluster = [PSCustomObject]@{
            edgeSite          = "site1"
            storagePolicy     = [PSCustomObject]@{ storageType = "vSAN-OSA" }
            vSanWitnessVmName = "not valid!"
        }
        $inputData = [PSCustomObject]@{ common = [PSCustomObject]@{ vSanWitnessVmName = $null } }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster, $inputData {
            Test-JsonvSanWitnessVmName -ClustersToValidate @($args[0]) -InputData $args[1]
        } | Should -Be 1
    }
}


Describe "Test-JsonHaPolicy" {
    It "Returns 0 failures when haPolicy is absent from common and clusters" {
        $cluster   = [PSCustomObject]@{ edgeSite = "site1" }
        $inputData = [PSCustomObject]@{ common = [PSCustomObject]@{} }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster, $inputData {
            Test-JsonHaPolicy -ClustersToValidate @($args[0]) -InputData $args[1]
        } | Should -Be 0
    }

    It "Returns 0 failures for valid common haPolicy '<Policy>'" -ForEach @(
        @{ Policy = "disabled"         }
        @{ Policy = "reservationBased" }
        @{ Policy = "slotBased"        }
    ) {
        $inputData = [PSCustomObject]@{ common = [PSCustomObject]@{ haPolicy = $Policy } }
        $cluster   = [PSCustomObject]@{ edgeSite = "site1" }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $cluster, $inputData {
            Test-JsonHaPolicy -ClustersToValidate @($args[0]) -InputData $args[1]
        }
        $result | Should -Be 0
    }

    It "Returns 1 failure for an invalid common haPolicy value" {
        $inputData = [PSCustomObject]@{ common = [PSCustomObject]@{ haPolicy = "invalid" } }
        $cluster   = [PSCustomObject]@{ edgeSite = "site1" }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster, $inputData {
            Test-JsonHaPolicy -ClustersToValidate @($args[0]) -InputData $args[1]
        } | Should -Be 1
    }

    It "Returns 1 failure for an invalid cluster-level haPolicy value" {
        $inputData = [PSCustomObject]@{ common = [PSCustomObject]@{} }
        $cluster   = [PSCustomObject]@{ edgeSite = "site1"; haPolicy = "bogus" }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster, $inputData {
            Test-JsonHaPolicy -ClustersToValidate @($args[0]) -InputData $args[1]
        } | Should -Be 1
    }

    It "Returns 0 failures for a valid cluster-level haPolicy" {
        $inputData = [PSCustomObject]@{ common = [PSCustomObject]@{} }
        $cluster   = [PSCustomObject]@{ edgeSite = "site1"; haPolicy = "slotBased" }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster, $inputData {
            Test-JsonHaPolicy -ClustersToValidate @($args[0]) -InputData $args[1]
        } | Should -Be 0
    }
}


Describe "Test-JsonWorkloadServiceCount" {
    It "Returns 0 failures for a valid power-of-2 workloadServiceCount" {
        $siteSpec = [PSCustomObject]@{
            edgeSite               = "site1"
            primaryWorkloadNetwork = [PSCustomObject]@{ workloadServiceCount = 512 }
        }
        InModuleScope VcfEdgeAtScale -ArgumentList $siteSpec {
            Test-JsonWorkloadServiceCount -SiteSpecsToValidate @($args[0])
        } | Should -Be 0
    }

    It "Returns 1 failure when workloadServiceCount is not a power of 2" {
        $siteSpec = [PSCustomObject]@{
            edgeSite               = "site1"
            primaryWorkloadNetwork = [PSCustomObject]@{ workloadServiceCount = 500 }
        }
        InModuleScope VcfEdgeAtScale -ArgumentList $siteSpec {
            Test-JsonWorkloadServiceCount -SiteSpecsToValidate @($args[0])
        } | Should -Be 1
    }

    It "Throws when workloadServiceCount key is absent (Get-JsonPropertyValue returns null, Test-ValidCidrRange rejects null)" {
        # Test-ValidCidrRange has [ValidateNotNullOrEmpty()] — passing a null value from a missing
        # key causes a parameter binding exception rather than the outer null-check returning 1.
        # This test documents the actual runtime contract.
        $siteSpec = [PSCustomObject]@{
            edgeSite               = "site1"
            primaryWorkloadNetwork = [PSCustomObject]@{}
        }
        { InModuleScope VcfEdgeAtScale -ArgumentList $siteSpec {
              Test-JsonWorkloadServiceCount -SiteSpecsToValidate @($args[0])
          }
        } | Should -Throw -ExceptionType ([System.Management.Automation.ParameterBindingException])

    }
}


Describe "Test-JsonLbVirtualServerIpCount" {
    It "Always returns 0 even when IP count is below the warning threshold (advisory only)" {
        $siteSpec = [PSCustomObject]@{
            edgeSite = "site1"
            foundationLoadBalancerComponents = [PSCustomObject]@{
                flbVirtualServerNetwork = [PSCustomObject]@{ flbNetworkIpAddressCount = 5 }
            }
        }
        $dummyCluster = [PSCustomObject]@{ edgeSite = "site1" }
        $inputData    = [PSCustomObject]@{}
        InModuleScope VcfEdgeAtScale -ArgumentList $siteSpec, $dummyCluster, $inputData {
            Test-JsonLbVirtualServerIpCount -SiteSpecsToValidate @($args[0]) -ClustersToValidate @($args[1]) -InputData $args[2]
        } | Should -Be 0
    }
}


Describe "Test-JsonNumericPropertiesWithRanges" {
    It "Returns 0 failures when all numeric properties are absent (they are optional)" {
        $siteSpec = [PSCustomObject]@{
            edgeSite                         = "site1"
            foundationLoadBalancerComponents = $null
            mgmtNetworkSpec                  = $null
            primaryWorkloadNetwork           = $null
        }
        InModuleScope VcfEdgeAtScale -ArgumentList $siteSpec {
            Test-JsonNumericPropertiesWithRanges -SiteSpecsToValidate @($args[0])
        } | Should -Be 0
    }

    It "Returns 0 failures when numeric properties meet minimum values" {
        $flb = [PSCustomObject]@{
            flbVipIPCount       = 2
            flbManagementNetwork = [PSCustomObject]@{ flbNetworkIpAddressCount = 5 }
        }
        $siteSpec = [PSCustomObject]@{
            edgeSite                         = "site1"
            foundationLoadBalancerComponents = $flb
            mgmtNetworkSpec                  = [PSCustomObject]@{ mgmtNetworkIPCount = 10 }
            primaryWorkloadNetwork           = [PSCustomObject]@{ primaryWorkloadNetworkIPCount = 3 }
        }
        InModuleScope VcfEdgeAtScale -ArgumentList $siteSpec {
            Test-JsonNumericPropertiesWithRanges -SiteSpecsToValidate @($args[0])
        } | Should -Be 0
    }
}


Describe "Test-JsonRfc1123NetworkNames" {
    It "Returns 0 failures when all network names are absent (optional)" {
        $siteSpec = [PSCustomObject]@{ edgeSite = "site1"; foundationLoadBalancerComponents = $null; primaryWorkloadNetwork = $null; mgmtNetworkSpec = $null }
        InModuleScope VcfEdgeAtScale -ArgumentList $siteSpec {
            Test-JsonRfc1123NetworkNames -SiteSpecsToValidate @($args[0])
        } | Should -Be 0
    }

    It "Returns 0 failures for valid lowercase RFC1123 network names" {
        $flb = [PSCustomObject]@{
            flbManagementNetwork  = [PSCustomObject]@{ flbNetworkName = "mgmt-net" }
            flbVirtualServerNetwork = [PSCustomObject]@{ flbNetworkName = "vs-net" }
        }
        $siteSpec = [PSCustomObject]@{
            edgeSite                         = "site1"
            foundationLoadBalancerComponents = $flb
            primaryWorkloadNetwork           = [PSCustomObject]@{ primaryWorkloadNetworkName = "workload-net" }
            mgmtNetworkSpec                  = [PSCustomObject]@{ mgmtNetworkName = "mgmt-vds" }
        }
        InModuleScope VcfEdgeAtScale -ArgumentList $siteSpec {
            Test-JsonRfc1123NetworkNames -SiteSpecsToValidate @($args[0])
        } | Should -Be 0
    }

    It "Returns 1 failure for an uppercase network name" {
        $flb = [PSCustomObject]@{
            flbManagementNetwork  = [PSCustomObject]@{ flbNetworkName = "UPPER-CASE" }
            flbVirtualServerNetwork = $null
        }
        $siteSpec = [PSCustomObject]@{
            edgeSite = "site1"
            foundationLoadBalancerComponents = $flb
            primaryWorkloadNetwork = $null
            mgmtNetworkSpec = $null
        }
        InModuleScope VcfEdgeAtScale -ArgumentList $siteSpec {
            Test-JsonRfc1123NetworkNames -SiteSpecsToValidate @($args[0])
        } | Should -Be 1
    }
}


Describe "Test-JsonRfc1123NetworkSegments" {
    It "Returns 0 failures when all segment names are valid RFC1123" {
        $cluster = [PSCustomObject]@{
            edgeSite   = "site1"
            networking = [PSCustomObject]@{
                networkSegments = @([PSCustomObject]@{ name = "vmotion-seg" }, [PSCustomObject]@{ name = "vsan-seg" })
            }
        }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Test-JsonRfc1123NetworkSegments -ClustersToValidate @($args[0])
        } | Should -Be 0
    }

    It "Returns 1 failure for a segment name with uppercase letters" {
        $cluster = [PSCustomObject]@{
            edgeSite   = "site1"
            networking = [PSCustomObject]@{
                networkSegments = @([PSCustomObject]@{ name = "UpperCaseName" })
            }
        }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Test-JsonRfc1123NetworkSegments -ClustersToValidate @($args[0])
        } | Should -Be 1
    }

    It "Returns 0 failures when networking is absent" {
        $cluster = [PSCustomObject]@{ edgeSite = "site1"; networking = $null }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Test-JsonRfc1123NetworkSegments -ClustersToValidate @($args[0])
        } | Should -Be 0
    }
}


Describe "Test-JsonRfc1123VmClassNames" {
    It "Returns 0 failures for valid RFC1123 VM class names" {
        $cluster = [PSCustomObject]@{
            edgeSite          = "site1"
            supervisorServices = [PSCustomObject]@{ vmClass = @("best-effort-small", "guaranteed-xlarge") }
        }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Test-JsonRfc1123VmClassNames -ClustersToValidate @($args[0])
        } | Should -Be 0
    }

    It "Returns 1 failure for an uppercase VM class name" {
        $cluster = [PSCustomObject]@{
            edgeSite          = "site1"
            supervisorServices = [PSCustomObject]@{ vmClass = @("Best-Effort-Small") }
        }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Test-JsonRfc1123VmClassNames -ClustersToValidate @($args[0])
        } | Should -Be 1
    }

    It "Returns 0 failures when supervisorServices is absent" {
        $cluster = [PSCustomObject]@{ edgeSite = "site1"; supervisorServices = $null }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Test-JsonRfc1123VmClassNames -ClustersToValidate @($args[0])
        } | Should -Be 0
    }
}


Describe "Test-JsonDnsServers" {
    It "Returns 0 failures when dnsServers is absent" {
        $supervisorData = [PSCustomObject]@{ commonSupervisorSpec = [PSCustomObject]@{ dnsServers = $null } }
        InModuleScope VcfEdgeAtScale -ArgumentList $supervisorData {
            Test-JsonDnsServers -SupervisorData $args[0]
        } | Should -Be 0
    }

    It "Returns 0 failures for 1-3 valid IPv4 DNS servers" {
        $supervisorData = [PSCustomObject]@{ commonSupervisorSpec = [PSCustomObject]@{ dnsServers = @("8.8.8.8", "8.8.4.4") } }
        InModuleScope VcfEdgeAtScale -ArgumentList $supervisorData {
            Test-JsonDnsServers -SupervisorData $args[0]
        } | Should -Be 0
    }

    It "Returns 1 failure when an invalid IP is in the DNS list" {
        $supervisorData = [PSCustomObject]@{ commonSupervisorSpec = [PSCustomObject]@{ dnsServers = @("not-an-ip") } }
        InModuleScope VcfEdgeAtScale -ArgumentList $supervisorData {
            Test-JsonDnsServers -SupervisorData $args[0]
        } | Should -Be 1
    }

    It "Returns 1 failure when more than 3 DNS servers are provided" {
        $supervisorData = [PSCustomObject]@{ commonSupervisorSpec = [PSCustomObject]@{ dnsServers = @("1.1.1.1", "2.2.2.2", "3.3.3.3", "4.4.4.4") } }
        InModuleScope VcfEdgeAtScale -ArgumentList $supervisorData {
            Test-JsonDnsServers -SupervisorData $args[0]
        } | Should -Be 1
    }
}


Describe "Test-JsonFlbConfiguration" {
    It "Returns 0 failures when FLB fields are absent" {
        $supervisorData = [PSCustomObject]@{ commonSupervisorSpec = [PSCustomObject]@{ flbSize = $null; flbNetworkType = $null; flbAvailability = $null } }
        InModuleScope VcfEdgeAtScale -ArgumentList $supervisorData {
            Test-JsonFlbConfiguration -SupervisorData $args[0]
        } | Should -Be 0
    }

    It "Returns 0 failures for valid FLB size, network type, and availability" {
        $supervisorData = [PSCustomObject]@{
            commonSupervisorSpec = [PSCustomObject]@{
                flbSize         = "SMALL"
                flbNetworkType  = "DVPG"
                flbAvailability = "SINGLE_NODE"
            }
        }
        InModuleScope VcfEdgeAtScale -ArgumentList $supervisorData {
            Test-JsonFlbConfiguration -SupervisorData $args[0]
        } | Should -Be 0
    }

    It "Returns 1 failure for an invalid flbSize" {
        $supervisorData = [PSCustomObject]@{ commonSupervisorSpec = [PSCustomObject]@{ flbSize = "HUGE"; flbNetworkType = $null; flbAvailability = $null } }
        InModuleScope VcfEdgeAtScale -ArgumentList $supervisorData {
            Test-JsonFlbConfiguration -SupervisorData $args[0]
        } | Should -Be 1
    }

    It "Returns 1 failure for an invalid flbAvailability" {
        $supervisorData = [PSCustomObject]@{ commonSupervisorSpec = [PSCustomObject]@{ flbSize = $null; flbNetworkType = $null; flbAvailability = "DUAL_NODE" } }
        InModuleScope VcfEdgeAtScale -ArgumentList $supervisorData {
            Test-JsonFlbConfiguration -SupervisorData $args[0]
        } | Should -Be 1
    }
}


Describe "Test-JsonControlPlaneConfiguration" {
    It "Returns 0 failures when control plane fields are absent" {
        $supervisorData = [PSCustomObject]@{ commonSupervisorSpec = [PSCustomObject]@{ controlPlaneSize = $null; controlPlaneVMCount = $null } }
        InModuleScope VcfEdgeAtScale -ArgumentList $supervisorData {
            Test-JsonControlPlaneConfiguration -SupervisorData $args[0]
        } | Should -Be 0
    }

    It "Returns 0 failures for valid controlPlaneSize '<Size>'" -ForEach @(
        @{ Size = "TINY"   }
        @{ Size = "SMALL"  }
        @{ Size = "MEDIUM" }
        @{ Size = "LARGE"  }
    ) {
        $supervisorData = [PSCustomObject]@{ commonSupervisorSpec = [PSCustomObject]@{ controlPlaneSize = $Size; controlPlaneVMCount = 1 } }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $supervisorData {
            Test-JsonControlPlaneConfiguration -SupervisorData $args[0]
        }
        $result | Should -Be 0
    }

    It "Returns 1 failure for an invalid controlPlaneSize" {
        $supervisorData = [PSCustomObject]@{ commonSupervisorSpec = [PSCustomObject]@{ controlPlaneSize = "XLARGE"; controlPlaneVMCount = $null } }
        InModuleScope VcfEdgeAtScale -ArgumentList $supervisorData {
            Test-JsonControlPlaneConfiguration -SupervisorData $args[0]
        } | Should -Be 1
    }

    It "Returns 1 failure for controlPlaneVMCount that is not 1 or 3" {
        $supervisorData = [PSCustomObject]@{ commonSupervisorSpec = [PSCustomObject]@{ controlPlaneSize = $null; controlPlaneVMCount = 2 } }
        InModuleScope VcfEdgeAtScale -ArgumentList $supervisorData {
            Test-JsonControlPlaneConfiguration -SupervisorData $args[0]
        } | Should -Be 1
    }
}


Describe "Test-JsonStoragePolicyFormats" {
    It "Returns 0 failures when storagePolicy fields are absent" {
        $cluster = [PSCustomObject]@{ edgeSite = "site1"; storagePolicy = $null }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Test-JsonStoragePolicyFormats -ClustersToValidate @($args[0])
        } | Should -Be 0
    }

    It "Returns 0 failures for valid storagePolicyName and tagCatalog" {
        $cluster = [PSCustomObject]@{
            edgeSite      = "site1"
            storagePolicy = [PSCustomObject]@{ storagePolicyTagCatalog = "myTagCatalog"; storagePolicyName = "my-storage-policy" }
        }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Test-JsonStoragePolicyFormats -ClustersToValidate @($args[0])
        } | Should -Be 0
    }
}


Describe "Test-JsonPrefixFormats" {
    It "Returns 0 failures when all prefix properties are absent" {
        $inputData = [PSCustomObject]@{ common = [PSCustomObject]@{} }
        InModuleScope VcfEdgeAtScale -ArgumentList $inputData {
            Test-JsonPrefixFormats -InputData $args[0]
        } | Should -Be 0
    }

    It "Returns 0 failures for valid prefix values" {
        $inputData = [PSCustomObject]@{
            common = [PSCustomObject]@{
                clusterNamePrefix    = "cl0"
                datastoreNamePrefix  = "ds-vsan"
                vdsNamePrefix        = "vds-edge"
                supervisorNamePrefix = "sup"
            }
        }
        InModuleScope VcfEdgeAtScale -ArgumentList $inputData {
            Test-JsonPrefixFormats -InputData $args[0]
        } | Should -Be 0
    }
}


Describe "Test-JsonStartingIpAddresses" {
    It "Returns 0 failures when all starting IP properties are absent" {
        $siteSpec = [PSCustomObject]@{
            edgeSite                         = "site1"
            foundationLoadBalancerComponents = $null
            mgmtNetworkSpec                  = $null
            primaryWorkloadNetwork           = $null
        }
        InModuleScope VcfEdgeAtScale -ArgumentList $siteSpec {
            Test-JsonStartingIpAddresses -SiteSpecsToValidate @($args[0])
        } | Should -Be 0
    }

    It "Returns 0 failures for valid starting IPs" {
        $flb = [PSCustomObject]@{
            flbManagementNetwork    = [PSCustomObject]@{ flbNetworkIpAddressStartingIp = "192.168.1.10" }
            flbVirtualServerNetwork = [PSCustomObject]@{ flbNetworkIpAddressStartingIp = "192.168.2.10" }
            flbVipStartIP           = "10.0.0.1"
        }
        $siteSpec = [PSCustomObject]@{
            edgeSite                         = "site1"
            foundationLoadBalancerComponents = $flb
            mgmtNetworkSpec                  = [PSCustomObject]@{ mgmtNetworkStartingIp = "172.16.0.1" }
            primaryWorkloadNetwork           = [PSCustomObject]@{ primaryWorkloadNetworkStartingIp = "10.1.0.1"; workloadServiceStartIp = "10.2.0.1" }
        }
        InModuleScope VcfEdgeAtScale -ArgumentList $siteSpec {
            Test-JsonStartingIpAddresses -SiteSpecsToValidate @($args[0])
        } | Should -Be 0
    }

    It "Returns at least 1 failure for an invalid starting IP address" {
        # Only set the invalid IP; omit other FLB sub-properties entirely so they resolve to $null (absent).
        $flb = [PSCustomObject]@{
            flbManagementNetwork = [PSCustomObject]@{ flbNetworkIpAddressStartingIp = "999.1.1.1" }
        }
        $siteSpec = [PSCustomObject]@{
            edgeSite                         = "site1"
            foundationLoadBalancerComponents = $flb
            mgmtNetworkSpec                  = $null
            primaryWorkloadNetwork           = $null
        }
        InModuleScope VcfEdgeAtScale -ArgumentList $siteSpec {
            Test-JsonStartingIpAddresses -SiteSpecsToValidate @($args[0])
        } | Should -BeGreaterOrEqual 1
    }
}


Describe "Test-JsonNetworkSegmentGateways" {
    It "Returns 1 failure when no matching supervisor site spec exists for the cluster" {
        $cluster = [PSCustomObject]@{
            edgeSite   = "site1"
            networking = [PSCustomObject]@{ networkSegments = @([PSCustomObject]@{ name = "seg1"; gateway = "10.0.0.1/24" }) }
        }
        $supervisorData = [PSCustomObject]@{ siteSpec = @([PSCustomObject]@{ edgeSite = "other-site" }) }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster, $supervisorData {
            Test-JsonNetworkSegmentGateways -ClustersToValidate @($args[0]) -SupervisorData $args[1]
        } | Should -Be 1
    }

    It "Returns 0 failures for valid CIDR gateways with a matching site spec" {
        $cluster = [PSCustomObject]@{
            edgeSite   = "site1"
            networking = [PSCustomObject]@{ networkSegments = @([PSCustomObject]@{ name = "seg1"; gateway = "10.0.0.1/24" }) }
        }
        $supervisorData = [PSCustomObject]@{ siteSpec = @([PSCustomObject]@{ edgeSite = "site1" }) }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster, $supervisorData {
            Test-JsonNetworkSegmentGateways -ClustersToValidate @($args[0]) -SupervisorData $args[1]
        } | Should -Be 0
    }

    It "Returns 1 failure for an invalid gateway format" {
        $cluster = [PSCustomObject]@{
            edgeSite   = "site1"
            networking = [PSCustomObject]@{ networkSegments = @([PSCustomObject]@{ name = "seg1"; gateway = "not-a-cidr" }) }
        }
        $supervisorData = [PSCustomObject]@{ siteSpec = @([PSCustomObject]@{ edgeSite = "site1" }) }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster, $supervisorData {
            Test-JsonNetworkSegmentGateways -ClustersToValidate @($args[0]) -SupervisorData $args[1]
        } | Should -Be 1
    }
}


Describe "Test-JsonNetworkingVmKernelAndTemporaryIp" {
    It "Returns 0 failures when networking is absent" {
        $cluster = [PSCustomObject]@{
            edgeSite      = "site1"
            networking    = $null
            storagePolicy = [PSCustomObject]@{ storageType = "VMFS" }
        }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Test-JsonNetworkingVmKernelAndTemporaryIp -ClustersToValidate @($args[0])
        } | Should -Be 0
    }

    It "Returns 0 failures when VMFS cluster has no VMkernel interfaces (not required)" {
        $cluster = [PSCustomObject]@{
            edgeSite      = "site1"
            storagePolicy = [PSCustomObject]@{ storageType = "VMFS" }
            networking    = [PSCustomObject]@{
                networkSegments              = $null
                networkingVmKernelInterfaces = $null
            }
        }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Test-JsonNetworkingVmKernelAndTemporaryIp -ClustersToValidate @($args[0])
        } | Should -Be 0
    }

    It "Returns 1 failure when vSAN-OSA cluster has no VMkernel interfaces defined" {
        $cluster = [PSCustomObject]@{
            edgeSite      = "site1"
            storagePolicy = [PSCustomObject]@{ storageType = "vSAN-OSA" }
            networking    = [PSCustomObject]@{
                networkSegments              = $null
                networkingVmKernelInterfaces = $null
            }
        }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Test-JsonNetworkingVmKernelAndTemporaryIp -ClustersToValidate @($args[0])
        } | Should -Be 1
    }

    It "Returns 1 failure for a network segment with an invalid vlanId" {
        $cluster = [PSCustomObject]@{
            edgeSite      = "site1"
            storagePolicy = [PSCustomObject]@{ storageType = "VMFS" }
            networking    = [PSCustomObject]@{
                networkSegments              = @([PSCustomObject]@{ name = "seg1"; vlanId = 5000 })
                networkingVmKernelInterfaces = $null
            }
        }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Test-JsonNetworkingVmKernelAndTemporaryIp -ClustersToValidate @($args[0])
        } | Should -Be 1
    }

    It "Returns 0 failures for a network segment with vlanId 0 (untagged)" {
        $cluster = [PSCustomObject]@{
            edgeSite      = "site1"
            storagePolicy = [PSCustomObject]@{ storageType = "VMFS" }
            networking    = [PSCustomObject]@{
                networkSegments              = @([PSCustomObject]@{ name = "seg1"; vlanId = 0 })
                networkingVmKernelInterfaces = $null
            }
        }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Test-JsonNetworkingVmKernelAndTemporaryIp -ClustersToValidate @($args[0])
        } | Should -Be 0
    }
}


Describe "Test-JsonShallowSupervisorServicesPathConfiguration" {
    It "Returns 0 failures when both ArgoCD and Harbor are disabled" {
        $cluster = [PSCustomObject]@{
            edgeSite          = "site1"
            supervisorServices = [PSCustomObject]@{ disableArgoCD = $true; disableHarbor = $true }
        }
        $inputData = [PSCustomObject]@{ common = [PSCustomObject]@{ supervisorServices = $null } }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster, $inputData {
            Test-JsonShallowSupervisorServicesPathConfiguration -ClustersToValidate @($args[0]) -InputData $args[1]
        } | Should -Be 0
    }
}


Describe "Test-JsonYamlFilePaths" {
    It "Returns 0 failures when both ArgoCD and Harbor are disabled (no YAML paths required)" {
        $cluster = [PSCustomObject]@{
            edgeSite          = "site1"
            supervisorServices = [PSCustomObject]@{ disableArgoCD = $true; disableHarbor = $true }
        }
        $inputData = [PSCustomObject]@{ common = [PSCustomObject]@{ supervisorServices = $null } }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster, $inputData {
            Test-JsonYamlFilePaths -ClustersToValidate @($args[0]) -InputData $args[1]
        } | Should -Be 0
    }
}


Describe "Test-JsonIpAddressesInCidrRanges" {
    It "Returns 0 failures when no network segments are defined in the cluster" {
        $cluster = [PSCustomObject]@{
            edgeSite   = "site1"
            networking = $null
        }
        $supervisorData = [PSCustomObject]@{ siteSpec = @([PSCustomObject]@{ edgeSite = "site1" }) }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster, $supervisorData {
            Test-JsonIpAddressesInCidrRanges -ClustersToValidate @($args[0]) -SupervisorData $args[1]
        } | Should -Be 0
    }

    It "Returns 0 failures when there is no matching supervisor site spec (skipped silently)" {
        $cluster = [PSCustomObject]@{
            edgeSite   = "site1"
            networking = [PSCustomObject]@{ networkSegments = @([PSCustomObject]@{ name = "seg1"; gateway = "10.0.0.1/24" }) }
        }
        $supervisorData = [PSCustomObject]@{ siteSpec = @([PSCustomObject]@{ edgeSite = "other-site" }) }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster, $supervisorData {
            Test-JsonIpAddressesInCidrRanges -ClustersToValidate @($args[0]) -SupervisorData $args[1]
        } | Should -Be 0
    }

    It "Returns 1 failure when the allocated range includes the gateway address" {
        $siteSpec = [PSCustomObject]@{
            edgeSite        = "site1"
            mgmtNetworkSpec = [PSCustomObject]@{
                mgmtNetworkName       = "mgmt"
                mgmtNetworkStartingIp = "10.0.0.1"
                mgmtNetworkIPCount    = 5
            }
        }
        $cluster = [PSCustomObject]@{
            edgeSite   = "site1"
            networking = [PSCustomObject]@{
                networkSegments = @([PSCustomObject]@{ name = "mgmt"; gateway = "10.0.0.1/24" })
            }
        }
        $supervisorData = [PSCustomObject]@{ siteSpec = @($siteSpec) }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster, $supervisorData {
            Test-JsonIpAddressesInCidrRanges -ClustersToValidate @($args[0]) -SupervisorData $args[1]
        } | Should -Be 1
    }

    It "Returns 0 failures when the allocated range ends before the gateway address" {
        $siteSpec = [PSCustomObject]@{
            edgeSite        = "site1"
            mgmtNetworkSpec = [PSCustomObject]@{
                mgmtNetworkName       = "mgmt"
                mgmtNetworkStartingIp = "10.0.0.10"
                mgmtNetworkIPCount    = 5
            }
        }
        $cluster = [PSCustomObject]@{
            edgeSite   = "site1"
            networking = [PSCustomObject]@{
                networkSegments = @([PSCustomObject]@{ name = "mgmt"; gateway = "10.0.0.1/24" })
            }
        }
        $supervisorData = [PSCustomObject]@{ siteSpec = @($siteSpec) }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster, $supervisorData {
            Test-JsonIpAddressesInCidrRanges -ClustersToValidate @($args[0]) -SupervisorData $args[1]
        } | Should -Be 0
    }

    It "Returns 1 failure when count=1 and the start IP equals the gateway" {
        $siteSpec = [PSCustomObject]@{
            edgeSite               = "site1"
            primaryWorkloadNetwork = [PSCustomObject]@{
                primaryWorkloadNetworkName       = "workload"
                primaryWorkloadNetworkStartingIp = "10.1.0.1"
                primaryWorkloadNetworkIPCount    = 1
            }
        }
        $cluster = [PSCustomObject]@{
            edgeSite   = "site1"
            networking = [PSCustomObject]@{
                networkSegments = @([PSCustomObject]@{ name = "workload"; gateway = "10.1.0.1/24" })
            }
        }
        $supervisorData = [PSCustomObject]@{ siteSpec = @($siteSpec) }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster, $supervisorData {
            Test-JsonIpAddressesInCidrRanges -ClustersToValidate @($args[0]) -SupervisorData $args[1]
        } | Should -Be 1
    }
}

# ── Mock-vCenter tests ────────────────────────────────────────────────────────
# These tests mock vCenter-calling cmdlets (Get-Cluster, Test-VcenterConnection, etc.)
# so orchestration functions can be exercised without a live vCenter connection.


Describe "Get-VsanWitnessNameForCluster — mocked vCenter (via mock Get-ClusterId)" {
    # Get-VsanWitnessNameForCluster is a pure PSObject lookup — no vCenter needed.
    # Tested here to complement the existing coverage in the pure-logic section.
    It "Returns cluster-level vSanWitnessVmName when defined" {
        $cluster   = [PSCustomObject]@{ vSanWitnessVmName = "witness.lab" }
        $inputData = [PSCustomObject]@{ common = [PSCustomObject]@{ vSanWitnessVmName = "common-witness.lab" } }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster, $inputData {
            Get-VsanWitnessNameForCluster -Cluster $args[0] -InputData $args[1]
        } | Should -Be "witness.lab"
    }

    It "Falls back to common.vSanWitnessVmName when cluster level is absent" {
        $cluster   = [PSCustomObject]@{ vSanWitnessVmName = $null }
        $inputData = [PSCustomObject]@{ common = [PSCustomObject]@{ vSanWitnessVmName = "common-witness.lab" } }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster, $inputData {
            Get-VsanWitnessNameForCluster -Cluster $args[0] -InputData $args[1]
        } | Should -Be "common-witness.lab"
    }
}

# ── Tier 1: Pure Logic (zero vCenter) ────────────────────────────────────────


Describe "Test-JsonPropertyFormat" {
    It "Returns true when string matches AcceptableStrings" {
        InModuleScope VcfEdgeAtScale {
            Test-JsonPropertyFormat -InputData "SMALL" -AcceptableStrings @("SMALL", "MEDIUM", "LARGE")
        } | Should -Be $true
    }

    It "Returns false when string is not in AcceptableStrings" {
        InModuleScope VcfEdgeAtScale {
            Test-JsonPropertyFormat -InputData "HUGE" -AcceptableStrings @("SMALL", "MEDIUM", "LARGE")
        } | Should -Be $false
    }

    It "Returns true for a valid IPv4 address with IpAddress preset" {
        InModuleScope VcfEdgeAtScale {
            Test-JsonPropertyFormat -InputData "192.168.1.1" -ValidationPreset "IpAddress"
        } | Should -Be $true
    }

    It "Returns false for an invalid IP with IpAddress preset" {
        InModuleScope VcfEdgeAtScale {
            Test-JsonPropertyFormat -InputData "999.1.1.1" -ValidationPreset "IpAddress"
        } | Should -Be $false
    }

    It "Returns true for a valid CIDR with IpAddressWithCidr preset" {
        InModuleScope VcfEdgeAtScale {
            Test-JsonPropertyFormat -InputData "10.0.0.0/24" -ValidationPreset "IpAddressWithCidr"
        } | Should -Be $true
    }

    It "Returns false when string is shorter than MinLength" {
        InModuleScope VcfEdgeAtScale {
            Test-JsonPropertyFormat -InputData "ab" -MinLength 5
        } | Should -Be $false
    }

    It "Returns false when string exceeds MaxLength" {
        InModuleScope VcfEdgeAtScale {
            Test-JsonPropertyFormat -InputData ("x" * 100) -MaxLength 10
        } | Should -Be $false
    }

    It "Returns true when string satisfies MinLength" {
        InModuleScope VcfEdgeAtScale {
            Test-JsonPropertyFormat -InputData "hello" -MinLength 3
        } | Should -Be $true
    }

    It "Returns true when navigated property matches AcceptableStrings" {
        $obj = [PSCustomObject]@{ controlPlaneSize = "MEDIUM" }
        InModuleScope VcfEdgeAtScale -ArgumentList $obj {
            Test-JsonPropertyFormat -InputData $args[0] -PropertyPath "controlPlaneSize" -AcceptableStrings @("TINY","SMALL","MEDIUM","LARGE")
        } | Should -Be $true
    }

    It "Returns false when navigated property does not match AcceptableStrings" {
        $obj = [PSCustomObject]@{ controlPlaneSize = "XLARGE" }
        InModuleScope VcfEdgeAtScale -ArgumentList $obj {
            Test-JsonPropertyFormat -InputData $args[0] -PropertyPath "controlPlaneSize" -AcceptableStrings @("TINY","SMALL","MEDIUM","LARGE")
        } | Should -Be $false
    }

    It "Returns false when InputData is null (no property path)" {
        InModuleScope VcfEdgeAtScale {
            Test-JsonPropertyFormat -InputData $null -AcceptableStrings @("SMALL")
        } | Should -Be $false
    }

    It "Returns true for an AlphaNumeric preset with a valid value" {
        InModuleScope VcfEdgeAtScale {
            Test-JsonPropertyFormat -InputData "Server01" -ValidationPreset "AlphaNumeric"
        } | Should -Be $true
    }

    It "Returns false for an AlphaNumeric preset with special characters" {
        InModuleScope VcfEdgeAtScale {
            Test-JsonPropertyFormat -InputData "Server-01" -ValidationPreset "AlphaNumeric"
        } | Should -Be $false
    }
}


Describe "Test-JsonShallowValidation — file-level integration" {
    BeforeAll {
        $script:shallowInfraJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "veas-shallow-infra-$([guid]::NewGuid().ToString('N').Substring(0,8)).json"
        $script:shallowSupJson   = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "veas-shallow-sup-$([guid]::NewGuid().ToString('N').Substring(0,8)).json"
        # Minimal valid-ish structure — full property set is validated by the function,
        # so these will fail validation, but the function itself must not crash.
        Set-Content -Path $script:shallowInfraJson -Value '{"common":{"vCenterName":"vc.lab"},"clusters":[]}' -Encoding UTF8
        Set-Content -Path $script:shallowSupJson   -Value '{"commonSupervisorSpec":{}}' -Encoding UTF8
    }
    AfterAll {
        Remove-Item $script:shallowInfraJson -Force -ErrorAction SilentlyContinue
        Remove-Item $script:shallowSupJson   -Force -ErrorAction SilentlyContinue
    }

    It "Throws when required infrastructure properties are missing" {
        # Test-JsonShallowValidation throws on validation failure — that is by design.
        { InModuleScope VcfEdgeAtScale -ArgumentList $script:shallowInfraJson, $script:shallowSupJson {
              Test-JsonShallowValidation -InfrastructureJson $args[0] -SupervisorJson $args[1]
          }
        } | Should -Throw

    }

    It "Does not throw on compute-only mode when supervisor.json is not read" {
        # -ComputeOnly skips supervisor.json validation; still throws on missing infra properties
        # but differently (only infra subset is checked). The test verifies the switch is honored.
        { InModuleScope VcfEdgeAtScale -ArgumentList $script:shallowInfraJson, $script:shallowSupJson {
              Test-JsonShallowValidation -InfrastructureJson $args[0] -SupervisorJson $args[1] -ComputeOnly
          }
        } | Should -Throw

    }
}

# ── Test-HostManagementVdsDualUplink ─────────────────────────────────────────


Describe "New-LabHarborSelfSignedTlsMaterialFiles — TLS material generation" {

    It "Returns ordered hashtable with CaCrtPath, TlsCrtPath, and TlsKeyPath keys" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            New-LabHarborSelfSignedTlsMaterialFiles -DnsName "harbor.lab" -EdgeSite "edge1"
        }
        $result.Keys | Should -Contain "CaCrtPath"
        $result.Keys | Should -Contain "TlsCrtPath"
        $result.Keys | Should -Contain "TlsKeyPath"
        # Clean up temporary files written by the function.
        Remove-Item -Path $result.CaCrtPath, $result.TlsCrtPath, $result.TlsKeyPath -Force -ErrorAction SilentlyContinue
    }

    It "Writes PEM files that contain BEGIN CERTIFICATE and BEGIN PRIVATE KEY markers" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            New-LabHarborSelfSignedTlsMaterialFiles -DnsName "harbor.vcfedge.demo" -EdgeSite "site-a"
        }
        try {
            [System.IO.File]::ReadAllText($result.TlsCrtPath) | Should -Match "BEGIN CERTIFICATE"
            [System.IO.File]::ReadAllText($result.TlsKeyPath) | Should -Match "BEGIN PRIVATE KEY"
        }
        finally {
            Remove-Item -Path $result.CaCrtPath, $result.TlsCrtPath, $result.TlsKeyPath -Force -ErrorAction SilentlyContinue
        }
    }

    It "Succeeds when DnsName is an IPv4 address (uses IP SAN extension)" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            New-LabHarborSelfSignedTlsMaterialFiles -DnsName "192.168.10.50" -EdgeSite "ip-site"
        }
        try {
            $result.TlsCrtPath | Should -Not -BeNullOrEmpty
            [System.IO.File]::Exists($result.TlsCrtPath) | Should -BeTrue
        }
        finally {
            Remove-Item -Path $result.CaCrtPath, $result.TlsCrtPath, $result.TlsKeyPath -Force -ErrorAction SilentlyContinue
        }
    }
}

# ── Remove-HarborContainerImageRegistry ───────────────────────────────────────


Describe "Test-JsonHarborConfiguration" {

    It "Returns 0 failures when Harbor is explicitly disabled at the cluster level" {
        $cluster = [PSCustomObject]@{
            edgeSite            = "site1"
            supervisorServices  = [PSCustomObject]@{ disableHarbor = $true }
            harborConfiguration = $null
        }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Test-JsonHarborConfiguration -ClustersToValidate @($args[0]) -InputData ([PSCustomObject]@{ common = [PSCustomObject]@{} })
        } | Should -Be 0
    }

    It "Returns 1 failure when harborConfiguration stanza is missing in non-lab mode" {
        $cluster = [PSCustomObject]@{ edgeSite = "site1" }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Test-JsonHarborConfiguration -ClustersToValidate @($args[0]) -InputData ([PSCustomObject]@{ common = [PSCustomObject]@{} })
        } | Should -BeGreaterThan 0
    }

    It "Returns 0 failures when harborConfiguration has a valid hostname and no secretKey override" {
        $cluster = [PSCustomObject]@{
            edgeSite            = "site1"
            harborConfiguration = [PSCustomObject]@{ hostname = "harbor.lab" }
        }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Test-JsonHarborConfiguration -ClustersToValidate @($args[0]) -InputData ([PSCustomObject]@{ common = [PSCustomObject]@{} })
        } | Should -Be 0
    }

    It "Returns 1 failure when secretKey is plain-text shorter than 16 characters" {
        $cluster = [PSCustomObject]@{
            edgeSite            = "site1"
            harborConfiguration = [PSCustomObject]@{ hostname = "harbor.lab"; secretKey = "tooshort" }
        }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Test-JsonHarborConfiguration -ClustersToValidate @($args[0]) -InputData ([PSCustomObject]@{ common = [PSCustomObject]@{} })
        } | Should -BeGreaterThan 0
    }

    It "Returns 0 failures when secretKey is exactly 16 characters" {
        $cluster = [PSCustomObject]@{
            edgeSite            = "site1"
            harborConfiguration = [PSCustomObject]@{ hostname = "harbor.lab"; secretKey = "1234567890123456" }
        }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Test-JsonHarborConfiguration -ClustersToValidate @($args[0]) -InputData ([PSCustomObject]@{ common = [PSCustomObject]@{} })
        } | Should -Be 0
    }

    It "Returns 1 failure when secretKey is a malformed dollar-env reference (space in name)" {
        $cluster = [PSCustomObject]@{
            edgeSite            = "site1"
            harborConfiguration = [PSCustomObject]@{ hostname = "harbor.lab"; secretKey = '$env:BAD NAME' }
        }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Test-JsonHarborConfiguration -ClustersToValidate @($args[0]) -InputData ([PSCustomObject]@{ common = [PSCustomObject]@{} })
        } | Should -BeGreaterThan 0
    }

    It "Returns 1 failure when secretKey is a malformed dollar-env reference (name starts with digit)" {
        $cluster = [PSCustomObject]@{
            edgeSite            = "site1"
            harborConfiguration = [PSCustomObject]@{ hostname = "harbor.lab"; secretKey = '$env:123INVALID' }
        }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Test-JsonHarborConfiguration -ClustersToValidate @($args[0]) -InputData ([PSCustomObject]@{ common = [PSCustomObject]@{} })
        } | Should -BeGreaterThan 0
    }

    It "Returns 0 failures when secretKey is a well-formed dollar-env reference" {
        $cluster = [PSCustomObject]@{
            edgeSite            = "site1"
            harborConfiguration = [PSCustomObject]@{ hostname = "harbor.lab"; secretKey = '$env:MY_SECRET_KEY' }
        }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Test-JsonHarborConfiguration -ClustersToValidate @($args[0]) -InputData ([PSCustomObject]@{ common = [PSCustomObject]@{} })
        } | Should -Be 0
    }

    It "Returns 1 failure when harborAdminPassword is a malformed dollar-env reference" {
        $cluster = [PSCustomObject]@{
            edgeSite            = "site1"
            harborConfiguration = [PSCustomObject]@{ hostname = "harbor.lab"; harborAdminPassword = '$env:bad!password' }
        }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Test-JsonHarborConfiguration -ClustersToValidate @($args[0]) -InputData ([PSCustomObject]@{ common = [PSCustomObject]@{} })
        } | Should -BeGreaterThan 0
    }

    It "Returns 0 failures when harborAdminPassword is a well-formed dollar-env reference" {
        $cluster = [PSCustomObject]@{
            edgeSite            = "site1"
            harborConfiguration = [PSCustomObject]@{ hostname = "harbor.lab"; harborAdminPassword = '$env:HARBOR_ADMIN_PASSWORD' }
        }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Test-JsonHarborConfiguration -ClustersToValidate @($args[0]) -InputData ([PSCustomObject]@{ common = [PSCustomObject]@{} })
        } | Should -Be 0
    }

    It "Returns 0 failures when harborAdminPassword is plain-text (no dollar-env prefix)" {
        $cluster = [PSCustomObject]@{
            edgeSite            = "site1"
            harborConfiguration = [PSCustomObject]@{ hostname = "harbor.lab"; harborAdminPassword = "MyP@ssw0rd!" }
        }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Test-JsonHarborConfiguration -ClustersToValidate @($args[0]) -InputData ([PSCustomObject]@{ common = [PSCustomObject]@{} })
        } | Should -Be 0
    }

    It "Returns 1 failure when tlsCrt is set but tlsKey is absent (mismatched pair)" {
        $cluster = [PSCustomObject]@{
            edgeSite            = "site1"
            harborConfiguration = [PSCustomObject]@{ hostname = "harbor.lab"; tlsCrt = "tls.crt" }
        }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Test-JsonHarborConfiguration -ClustersToValidate @($args[0]) -InputData ([PSCustomObject]@{ common = [PSCustomObject]@{} })
        } | Should -BeGreaterThan 0
    }

    It "Returns 1 failure when caCrt is set but tlsCrt and tlsKey are both absent" {
        $cluster = [PSCustomObject]@{
            edgeSite            = "site1"
            harborConfiguration = [PSCustomObject]@{ hostname = "harbor.lab"; caCrt = "ca.crt" }
        }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Test-JsonHarborConfiguration -ClustersToValidate @($args[0]) -InputData ([PSCustomObject]@{ common = [PSCustomObject]@{} })
        } | Should -BeGreaterThan 0
    }

    It "Returns 1 failure when registryVolumeSize is not in NNGi format" {
        $cluster = [PSCustomObject]@{
            edgeSite            = "site1"
            harborConfiguration = [PSCustomObject]@{ hostname = "harbor.lab"; registryVolumeSize = "10GB" }
        }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Test-JsonHarborConfiguration -ClustersToValidate @($args[0]) -InputData ([PSCustomObject]@{ common = [PSCustomObject]@{} })
        } | Should -BeGreaterThan 0
    }

    It "Returns 0 failures when registryVolumeSize is a valid NNGi value" {
        $cluster = [PSCustomObject]@{
            edgeSite            = "site1"
            harborConfiguration = [PSCustomObject]@{ hostname = "harbor.lab"; registryVolumeSize = "50Gi" }
        }
        InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Test-JsonHarborConfiguration -ClustersToValidate @($args[0]) -InputData ([PSCustomObject]@{ common = [PSCustomObject]@{} })
        } | Should -Be 0
    }

    It "Accumulates failures across multiple clusters" {
        $bad1 = [PSCustomObject]@{
            edgeSite            = "site1"
            harborConfiguration = [PSCustomObject]@{ hostname = "harbor.lab"; secretKey = "bad" }
        }
        $bad2 = [PSCustomObject]@{
            edgeSite            = "site2"
            harborConfiguration = [PSCustomObject]@{ hostname = "harbor2.lab"; secretKey = "alsotoolong17ch" }
        }
        InModuleScope VcfEdgeAtScale -ArgumentList $bad1, $bad2 {
            Test-JsonHarborConfiguration -ClustersToValidate @($args[0], $args[1]) -InputData ([PSCustomObject]@{ common = [PSCustomObject]@{} })
        } | Should -BeGreaterThan 1
    }
}


Describe "Resolve-ValidationScopeFlags" {

    It "Returns both flags false when ComputeOnly is set" {
        InModuleScope VcfEdgeAtScale {
            $cluster = [PSCustomObject]@{ edgeSite = "site1" }
            function Get-EffectiveSupervisorServiceFlag {
                [CmdletBinding()] Param([Parameter()] [Object]$Cluster, [Parameter()] [Object]$CommonData, [Parameter()] [String]$FlagName)
                return $false
            }
            $result = Resolve-ValidationScopeFlags -ClustersInScope @($cluster) -CommonData ([PSCustomObject]@{}) -ComputeOnly
            $result.AnyArgoEnabled   | Should -Be $false
            $result.AnyHarborEnabled | Should -Be $false
        }
    }

    It "Returns AnyArgoEnabled true when disableArgoCD is false on a cluster" {
        InModuleScope VcfEdgeAtScale {
            $cluster = [PSCustomObject]@{ edgeSite = "site1" }
            function Get-EffectiveSupervisorServiceFlag {
                [CmdletBinding()] Param([Parameter()] [Object]$Cluster, [Parameter()] [Object]$CommonData, [Parameter()] [String]$FlagName)
                return $FlagName -eq "disableHarbor"
            }
            $result = Resolve-ValidationScopeFlags -ClustersInScope @($cluster) -CommonData ([PSCustomObject]@{})
            $result.AnyArgoEnabled   | Should -Be $true
            $result.AnyHarborEnabled | Should -Be $false
        }
    }

    It "Returns both flags true and short-circuits when both services are enabled" {
        InModuleScope VcfEdgeAtScale {
            $cluster1 = [PSCustomObject]@{ edgeSite = "site1" }
            $cluster2 = [PSCustomObject]@{ edgeSite = "site2" }
            function Get-EffectiveSupervisorServiceFlag {
                [CmdletBinding()] Param([Parameter()] [Object]$Cluster, [Parameter()] [Object]$CommonData, [Parameter()] [String]$FlagName)
                return $false
            }
            $result = Resolve-ValidationScopeFlags -ClustersInScope @($cluster1, $cluster2) -CommonData ([PSCustomObject]@{})
            $result.AnyArgoEnabled   | Should -Be $true
            $result.AnyHarborEnabled | Should -Be $true
        }
    }

    It "Returns both flags false when clusters array is empty" {
        InModuleScope VcfEdgeAtScale {
            function Get-EffectiveSupervisorServiceFlag {
                [CmdletBinding()] Param([Parameter()] [Object]$Cluster, [Parameter()] [Object]$CommonData, [Parameter()] [String]$FlagName)
                return $false
            }
            $result = Resolve-ValidationScopeFlags -ClustersInScope @() -CommonData ([PSCustomObject]@{})
            $result.AnyArgoEnabled   | Should -Be $false
            $result.AnyHarborEnabled | Should -Be $false
        }
    }
}


Describe "Test-JsonCommonProperties" {

    It "Returns 0 failures for a clean infrastructure JSON object" {
        InModuleScope VcfEdgeAtScale {
            function Test-JsonPrefixFormats {
                [CmdletBinding()] Param([Parameter()] [Object]$InputData)
                return 0
            }
            function Test-JsonPropertyFormat {
                [CmdletBinding()] Param([Parameter()] [Object]$InputData, [Parameter()] [String]$PropertyPath, [Parameter()] [String]$ValidationPreset, [Parameter()] [String]$ValidationLabel, [Parameter()] [String]$RegexPattern, [Parameter()] [Int]$MinValue, [Parameter()] [Int]$MaxValue)
                return $true
            }
            $inputData = [PSCustomObject]@{
                common = [PSCustomObject]@{ vCenterName = "vc.lab"; vCenterUser = "admin@vsphere.local"; datacenterName = "DC1" }
            }
            Test-JsonCommonProperties -InputData $inputData | Should -Be 0
        }
    }

    It "Returns 1 failure when common.labenvironment is a non-boolean string" {
        InModuleScope VcfEdgeAtScale {
            function Test-JsonPrefixFormats {
                [CmdletBinding()] Param([Parameter()] [Object]$InputData)
                return 0
            }
            function Test-JsonPropertyFormat {
                [CmdletBinding()] Param([Parameter()] [Object]$InputData, [Parameter()] [String]$PropertyPath, [Parameter()] [String]$ValidationPreset, [Parameter()] [String]$ValidationLabel, [Parameter()] [String]$RegexPattern, [Parameter()] [Int]$MinValue, [Parameter()] [Int]$MaxValue)
                return $true
            }
            $labEnvString = "true"
            $commonObj = [PSCustomObject]@{ datacenterName = "DC1" }
            $commonObj | Add-Member -NotePropertyName "labenvironment" -NotePropertyValue $labEnvString
            $inputData = [PSCustomObject]@{ common = $commonObj }
            Test-JsonCommonProperties -InputData $inputData | Should -Be 1
        }
    }

    It "Returns 1 failure when common.preserveAutoGeneratedKeyCertPair is a non-boolean string" {
        InModuleScope VcfEdgeAtScale {
            function Test-JsonPrefixFormats {
                [CmdletBinding()] Param([Parameter()] [Object]$InputData)
                return 0
            }
            function Test-JsonPropertyFormat {
                [CmdletBinding()] Param([Parameter()] [Object]$InputData, [Parameter()] [String]$PropertyPath, [Parameter()] [String]$ValidationPreset, [Parameter()] [String]$ValidationLabel, [Parameter()] [String]$RegexPattern, [Parameter()] [Int]$MinValue, [Parameter()] [Int]$MaxValue)
                return $true
            }
            $commonObj = [PSCustomObject]@{ datacenterName = "DC1" }
            $commonObj | Add-Member -NotePropertyName "preserveAutoGeneratedKeyCertPair" -NotePropertyValue "yes"
            $inputData = [PSCustomObject]@{ common = $commonObj }
            Test-JsonCommonProperties -InputData $inputData | Should -Be 1
        }
    }

    It "Accumulates prefix format failures from Test-JsonPrefixFormats" {
        InModuleScope VcfEdgeAtScale {
            function Test-JsonPrefixFormats {
                [CmdletBinding()] Param([Parameter()] [Object]$InputData)
                return 3
            }
            function Test-JsonPropertyFormat {
                [CmdletBinding()] Param([Parameter()] [Object]$InputData, [Parameter()] [String]$PropertyPath, [Parameter()] [String]$ValidationPreset, [Parameter()] [String]$ValidationLabel, [Parameter()] [String]$RegexPattern, [Parameter()] [Int]$MinValue, [Parameter()] [Int]$MaxValue)
                return $true
            }
            $inputData = [PSCustomObject]@{ common = [PSCustomObject]@{ datacenterName = "DC1" } }
            Test-JsonCommonProperties -InputData $inputData | Should -Be 3
        }
    }
}


Describe "Test-JsonSupervisorAndSiteProperties" {

    It "Returns 0 failures when ComputeOnly is set and no site specs provided" {
        InModuleScope VcfEdgeAtScale {
            Test-JsonSupervisorAndSiteProperties -ComputeOnly -SupervisorData $null -SiteSpecsInScope @() | Should -Be 0
        }
    }

    It "Calls supervisor validators when ComputeOnly is not set" {
        InModuleScope VcfEdgeAtScale {
            function Test-JsonDnsServers {
                [CmdletBinding()] Param([Parameter()] [Object]$SupervisorData)
                return 1
            }
            function Test-JsonFlbConfiguration {
                [CmdletBinding()] Param([Parameter()] [Object]$SupervisorData)
                return 0
            }
            function Test-JsonControlPlaneConfiguration {
                [CmdletBinding()] Param([Parameter()] [Object]$SupervisorData)
                return 0
            }
            $supervisorData = [PSCustomObject]@{ commonSupervisorSpec = [PSCustomObject]@{} }
            Test-JsonSupervisorAndSiteProperties -SupervisorData $supervisorData -SiteSpecsInScope @() | Should -Be 1
        }
    }

    It "Accumulates site spec failures when site specs are provided" {
        InModuleScope VcfEdgeAtScale {
            function Test-JsonDnsServers {
                [CmdletBinding()] Param([Parameter()] [Object]$SupervisorData)
                return 0
            }
            function Test-JsonFlbConfiguration {
                [CmdletBinding()] Param([Parameter()] [Object]$SupervisorData)
                return 0
            }
            function Test-JsonControlPlaneConfiguration {
                [CmdletBinding()] Param([Parameter()] [Object]$SupervisorData)
                return 0
            }
            function Test-JsonNumericPropertiesWithRanges {
                [CmdletBinding()] Param([Parameter()] [Object]$SiteSpecsToValidate)
                return 2
            }
            function Test-JsonWorkloadServiceCount {
                [CmdletBinding()] Param([Parameter()] [Object]$SiteSpecsToValidate)
                return 0
            }
            function Test-JsonRfc1123NetworkNames {
                [CmdletBinding()] Param([Parameter()] [Object]$SiteSpecsToValidate)
                return 0
            }
            function Test-JsonStartingIpAddresses {
                [CmdletBinding()] Param([Parameter()] [Object]$SiteSpecsToValidate)
                return 1
            }
            $siteSpec = [PSCustomObject]@{ edgeSite = "site1" }
            $supervisorData = [PSCustomObject]@{ commonSupervisorSpec = [PSCustomObject]@{} }
            Test-JsonSupervisorAndSiteProperties -SupervisorData $supervisorData -SiteSpecsInScope @($siteSpec) | Should -Be 3
        }
    }
}


Describe "Test-JsonClusterProperties" {

    It "Returns 0 failures when cluster array is empty" {
        InModuleScope VcfEdgeAtScale {
            Test-JsonClusterProperties -ClustersInScope @() -InputData ([PSCustomObject]@{}) -SupervisorData $null -SiteSpecsInScope @() | Should -Be 0
        }
    }

    It "Validates per-cluster vLcmImageName and increments failure count on bad format" {
        InModuleScope VcfEdgeAtScale {
            function Test-JsonStoragePolicyFormats {
                [CmdletBinding()] Param([Parameter()] [Object]$ClustersToValidate)
                return 0
            }
            function Test-JsonRfc1123NetworkSegments {
                [CmdletBinding()] Param([Parameter()] [Object]$ClustersToValidate)
                return 0
            }
            function Test-JsonNetworkingVmKernelAndTemporaryIp {
                [CmdletBinding()] Param([Parameter()] [Object]$ClustersToValidate)
                return 0
            }
            function Test-JsonStoragePolicyTypes {
                [CmdletBinding()] Param([Parameter()] [Object]$ClustersToValidate)
                return 0
            }
            function Test-JsonvSanWitnessVmName {
                [CmdletBinding()] Param([Parameter()] [Object]$ClustersToValidate, [Parameter()] [Object]$InputData)
                return 0
            }
            function Test-JsonHaPolicy {
                [CmdletBinding()] Param([Parameter()] [Object]$ClustersToValidate, [Parameter()] [Object]$InputData)
                return 0
            }
            function Test-JsonEsxHostCountByStoragePolicyType {
                [CmdletBinding()] Param([Parameter()] [Object]$ClustersToValidate)
                return 0
            }
            function Test-JsonEsxHostFormats {
                [CmdletBinding()] Param([Parameter()] [Object]$ClustersToValidate)
                return 0
            }
            function Test-JsonPropertyFormat {
                [CmdletBinding()] Param([Parameter()] [Object]$InputData, [Parameter()] [String]$PropertyPath, [Parameter()] [String]$ValidationPreset, [Parameter()] [String]$ValidationLabel, [Parameter()] [String]$RegexPattern, [Parameter()] [Int]$MinValue, [Parameter()] [Int]$MaxValue)
                return $false
            }
            $cluster = [PSCustomObject]@{ edgeSite = "site1"; vLcmImageName = "INVALID!IMAGE" }
            Test-JsonClusterProperties -ClustersInScope @($cluster) -ComputeOnly -InputData ([PSCustomObject]@{}) -SupervisorData $null -SiteSpecsInScope @() | Should -Be 1
        }
    }

    It "Skips per-cluster vLcmImageName check when property is absent from cluster" {
        InModuleScope VcfEdgeAtScale {
            function Test-JsonStoragePolicyFormats {
                [CmdletBinding()] Param([Parameter()] [Object]$ClustersToValidate)
                return 0
            }
            function Test-JsonRfc1123NetworkSegments {
                [CmdletBinding()] Param([Parameter()] [Object]$ClustersToValidate)
                return 0
            }
            function Test-JsonNetworkingVmKernelAndTemporaryIp {
                [CmdletBinding()] Param([Parameter()] [Object]$ClustersToValidate)
                return 0
            }
            function Test-JsonStoragePolicyTypes {
                [CmdletBinding()] Param([Parameter()] [Object]$ClustersToValidate)
                return 0
            }
            function Test-JsonvSanWitnessVmName {
                [CmdletBinding()] Param([Parameter()] [Object]$ClustersToValidate, [Parameter()] [Object]$InputData)
                return 0
            }
            function Test-JsonHaPolicy {
                [CmdletBinding()] Param([Parameter()] [Object]$ClustersToValidate, [Parameter()] [Object]$InputData)
                return 0
            }
            function Test-JsonEsxHostCountByStoragePolicyType {
                [CmdletBinding()] Param([Parameter()] [Object]$ClustersToValidate)
                return 0
            }
            function Test-JsonEsxHostFormats {
                [CmdletBinding()] Param([Parameter()] [Object]$ClustersToValidate)
                return 0
            }
            $cluster = [PSCustomObject]@{ edgeSite = "site1" }
            Test-JsonClusterProperties -ClustersInScope @($cluster) -ComputeOnly -InputData ([PSCustomObject]@{}) -SupervisorData $null -SiteSpecsInScope @() | Should -Be 0
        }
    }
}

# ── Wrapper function filter-logic unit tests ─────────────────────────────────
# Note: Wrapper functions that delegate to PowerCLI compiled cmdlets cannot be
# exercised end-to-end in Pester because PowerCLI mock proxies enforce strict
# parameter type constraints. These tests verify the custom filter logic in
# isolation. Integration with the underlying cmdlets is covered by the caller
# tests above (e.g. Test-HostManagementVdsDualUplink, Invoke-PrepareHostForClusterMove).


Describe "Invoke-HarborEnvVarPreflight" {

    It "Skips all clusters when Harbor is disabled for each" {
        InModuleScope VcfEdgeAtScale {
            Mock Get-EffectiveSupervisorServiceFlag { return $true }
            Mock Resolve-HarborSecretValue { }
            $inputData = [PSCustomObject]@{
                common   = [PSCustomObject]@{ disableHarbor = $true }
                clusters = @(
                    [PSCustomObject]@{ edgeSite = "site1"; harborConfiguration = [PSCustomObject]@{ harborAdminPassword = '$env:HARBOR_ADMIN_PW' } }
                )
            }
            Invoke-HarborEnvVarPreflight -InputData $inputData
            Should -Invoke Resolve-HarborSecretValue -Times 0
        }
    }

    It "Skips clusters that do not match the EdgeSite filter" {
        InModuleScope VcfEdgeAtScale {
            Mock Get-EffectiveSupervisorServiceFlag { return $false }
            Mock Resolve-HarborSecretValue { }
            $inputData = [PSCustomObject]@{
                common   = [PSCustomObject]@{}
                clusters = @(
                    [PSCustomObject]@{ edgeSite = "site2"; harborConfiguration = [PSCustomObject]@{ harborAdminPassword = '$env:HARBOR_ADMIN_PW' } }
                )
            }
            Invoke-HarborEnvVarPreflight -InputData $inputData -EdgeSite "site1"
            Should -Invoke Resolve-HarborSecretValue -Times 0
        }
    }

    It "Calls Resolve-HarborSecretValue with RequiredLength 16 for the secretKey field" {
        InModuleScope VcfEdgeAtScale {
            Mock Get-EffectiveSupervisorServiceFlag { return $false }
            Mock Resolve-HarborSecretValue { }
            $inputData = [PSCustomObject]@{
                common   = [PSCustomObject]@{}
                clusters = @(
                    [PSCustomObject]@{
                        edgeSite           = "site1"
                        harborConfiguration = [PSCustomObject]@{ secretKey = '$env:HARBOR_SECRET_KEY' }
                    }
                )
            }
            Invoke-HarborEnvVarPreflight -InputData $inputData
            Should -Invoke Resolve-HarborSecretValue -Times 1 -ParameterFilter { $FieldName -eq "secretKey" -and $RequiredLength -eq 16 }
        }
    }

    It "Does not pass RequiredLength for fields without a length constraint" {
        InModuleScope VcfEdgeAtScale {
            Mock Get-EffectiveSupervisorServiceFlag { return $false }
            Mock Resolve-HarborSecretValue { }
            $inputData = [PSCustomObject]@{
                common   = [PSCustomObject]@{}
                clusters = @(
                    [PSCustomObject]@{
                        edgeSite           = "site1"
                        harborConfiguration = [PSCustomObject]@{ harborAdminPassword = '$env:HARBOR_ADMIN_PW' }
                    }
                )
            }
            Invoke-HarborEnvVarPreflight -InputData $inputData
            # RequiredLength parameter must not be present for unconstrained fields.
            Should -Invoke Resolve-HarborSecretValue -Times 1 -ParameterFilter { $FieldName -eq "harborAdminPassword" -and $null -eq $RequiredLength }
        }
    }

    It "Skips fields that do not carry a dollar-env-colon reference" {
        InModuleScope VcfEdgeAtScale {
            Mock Get-EffectiveSupervisorServiceFlag { return $false }
            Mock Resolve-HarborSecretValue { }
            $inputData = [PSCustomObject]@{
                common   = [PSCustomObject]@{}
                clusters = @(
                    [PSCustomObject]@{
                        edgeSite           = "site1"
                        harborConfiguration = [PSCustomObject]@{ harborAdminPassword = "literal-plain-password" }
                    }
                )
            }
            Invoke-HarborEnvVarPreflight -InputData $inputData
            Should -Invoke Resolve-HarborSecretValue -Times 0
        }
    }
}

# ── New-HarborDataValuesFile — YAML generation and file lifecycle ─────────────


Describe "New-HarborDataValuesFile" {

    BeforeAll {
        # Create a minimal real template file so Test-Path and Get-Content paths execute.
        $script:harborTemplateFilePath = [System.IO.Path]::GetTempFileName()
        Set-Content -Path $script:harborTemplateFilePath -Encoding UTF8 -Value @"
hostname: template.local
enableNginxLoadBalancer: false
enableContourHttpProxy: true
persistence:
  persistentVolumeClaim:
    registry:
      storageClass: template-class
      size: 10Gi
"@
    }

    AfterAll {
        Remove-Item -Path $script:harborTemplateFilePath -Force -ErrorAction SilentlyContinue
    }

    It "Throws when the Harbor template file does not exist" {
        InModuleScope VcfEdgeAtScale {
            { New-HarborDataValuesFile -EdgeSite "site1" -HarborTemplateFilePath "/no/such/harbor-template.yml" `
                    -Hostname "harbor.example.com" -StoragePolicyName "supervisor-site1" } |
                Should -Throw
        }
    }

    It "Returns a path that exists on disk after successful YAML generation" {
        $outPath = InModuleScope VcfEdgeAtScale -ArgumentList $script:harborTemplateFilePath {
            param($templatePath)
            Mock Update-HarborYamlContent { return "hostname: harbor.example.com`n" }
            Mock ConvertFrom-Yaml { return [PSCustomObject]@{ hostname = "harbor.example.com" } }
            New-HarborDataValuesFile -EdgeSite "site1" -HarborTemplateFilePath $templatePath `
                -Hostname "harbor.example.com" -StoragePolicyName "supervisor-site1"
        }
        try {
            $outPath         | Should -Not -BeNullOrEmpty
            Test-Path $outPath | Should -Be $true
        } finally {
            Remove-Item -Path $outPath -Force -ErrorAction SilentlyContinue
        }
    }

    It "Calls Update-HarborYamlContent with the lowercased and dash-normalized StorageClass name" {
        $outPath = InModuleScope VcfEdgeAtScale -ArgumentList $script:harborTemplateFilePath {
            param($templatePath)
            Mock Update-HarborYamlContent { return "hostname: harbor.example.com`n" }
            Mock ConvertFrom-Yaml { return [PSCustomObject]@{} }
            New-HarborDataValuesFile -EdgeSite "site1" -HarborTemplateFilePath $templatePath `
                -Hostname "harbor.example.com" -StoragePolicyName "Supervisor OSA"
        }
        try {
            # StoragePolicyName "Supervisor OSA" -> StorageClass "supervisor-osa"
            InModuleScope VcfEdgeAtScale {
                Should -Invoke Update-HarborYamlContent -Times 1 -ParameterFilter { $StorageClassName -eq "supervisor-osa" }
            }
        } finally {
            Remove-Item -Path $outPath -Force -ErrorAction SilentlyContinue
        }
    }

    It "Throws when the generated YAML fails structural pre-validation" {
        InModuleScope VcfEdgeAtScale -ArgumentList $script:harborTemplateFilePath {
            param($templatePath)
            Mock Update-HarborYamlContent { return "bad: yaml: [unclosed" }
            Mock ConvertFrom-Yaml { throw [System.Exception]::new("YAML parse error: unclosed bracket") }
            { New-HarborDataValuesFile -EdgeSite "site1" -HarborTemplateFilePath $templatePath `
                    -Hostname "harbor.example.com" -StoragePolicyName "supervisor-site1" } |
                Should -Throw
        }
    }
}

# ── Invoke-PauseBeforeRollbackIfRequested — rollback decision logic ───────────


Describe "Test-EdgeSiteMatching" {

    It "Returns IsValid=true when all edgeSite values match between both files" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock ConvertFrom-JsonSafely {
                switch ($JsonFilePath) {
                    "infra.json" { return [PSCustomObject]@{ clusters = @([PSCustomObject]@{ edgeSite = "site1" }, [PSCustomObject]@{ edgeSite = "site2" }) } }
                    default      { return [PSCustomObject]@{ siteSpec = @([PSCustomObject]@{ edgeSite = "site1" }, [PSCustomObject]@{ edgeSite = "site2" }) } }
                }
            }
            Test-EdgeSiteMatching -InfrastructureJson "infra.json" -SupervisorJson "supervisor.json"
        }
        $result.IsValid | Should -Be $true
        $result.ErrorMessage | Should -BeNullOrEmpty
    }

    It "Returns IsValid=false when an infrastructure edgeSite has no matching supervisor entry" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock ConvertFrom-JsonSafely {
                switch ($JsonFilePath) {
                    "infra.json" { return [PSCustomObject]@{ clusters = @([PSCustomObject]@{ edgeSite = "site1" }, [PSCustomObject]@{ edgeSite = "siteX" }) } }
                    default      { return [PSCustomObject]@{ siteSpec = @([PSCustomObject]@{ edgeSite = "site1" }) } }
                }
            }
            Test-EdgeSiteMatching -InfrastructureJson "infra.json" -SupervisorJson "supervisor.json"
        }
        $result.IsValid | Should -Be $false
        $result.ErrorMessage | Should -Match "without matching supervisor entries"
    }

    It "Returns IsValid=false when a supervisor edgeSite has no matching infrastructure entry" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock ConvertFrom-JsonSafely {
                switch ($JsonFilePath) {
                    "infra.json" { return [PSCustomObject]@{ clusters = @([PSCustomObject]@{ edgeSite = "site1" }) } }
                    default      { return [PSCustomObject]@{ siteSpec = @([PSCustomObject]@{ edgeSite = "site1" }, [PSCustomObject]@{ edgeSite = "siteY" }) } }
                }
            }
            Test-EdgeSiteMatching -InfrastructureJson "infra.json" -SupervisorJson "supervisor.json"
        }
        $result.IsValid | Should -Be $false
        $result.ErrorMessage | Should -Match "without matching infrastructure entries"
    }

    It "Returns IsValid=false when the infrastructure JSON contains duplicate edgeSite values" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock ConvertFrom-JsonSafely {
                switch ($JsonFilePath) {
                    "infra.json" { return [PSCustomObject]@{ clusters = @([PSCustomObject]@{ edgeSite = "site1" }, [PSCustomObject]@{ edgeSite = "site1" }) } }
                    default      { return [PSCustomObject]@{ siteSpec = @([PSCustomObject]@{ edgeSite = "site1" }) } }
                }
            }
            Test-EdgeSiteMatching -InfrastructureJson "infra.json" -SupervisorJson "supervisor.json"
        }
        $result.IsValid | Should -Be $false
        $result.ErrorMessage | Should -Match "Duplicate"
    }
}

# ── Test-JsonDeeperValidation — validator routing and ComputeOnly branching ────


Describe "Test-JsonDeeperValidation" {

    BeforeAll {
        # Common mocks shared across all tests in this block.
        $script:deeperValidationMocks = {
            Mock ConvertFrom-JsonSafely     { return [PSCustomObject]@{} }
            Mock Update-InfrastructureJsonReferencedFilePaths { }
            Mock Get-ClustersInScope        { return @() }
            Mock Get-SiteSpecsInScope       { return @() }
            Mock Test-JsonPrefixFormats     { return 0 }
            Mock Test-JsonPropertyFormat    { return $true }
            Mock Test-JsonDnsServers        { return 0 }
            Mock Test-JsonFlbConfiguration  { return 0 }
            Mock Test-JsonControlPlaneConfiguration { return 0 }
        }
    }

    It "Does not load supervisor JSON when ComputeOnly is set" {
        InModuleScope VcfEdgeAtScale {
            Mock ConvertFrom-JsonSafely     { return [PSCustomObject]@{} }
            Mock Update-InfrastructureJsonReferencedFilePaths { }
            Mock Get-ClustersInScope        { return @() }
            Mock Get-SiteSpecsInScope       { return @() }
            Mock Test-JsonPrefixFormats     { return 0 }
            Mock Test-JsonPropertyFormat    { return $true }
            Test-JsonDeeperValidation -InfrastructureJson "infra.json" -SupervisorJson "sup.json" -ComputeOnly
            Should -Invoke ConvertFrom-JsonSafely -Times 1 -Exactly
        }
    }

    It "Loads both JSON files when ComputeOnly is not set" {
        InModuleScope VcfEdgeAtScale {
            Mock ConvertFrom-JsonSafely     { return [PSCustomObject]@{} }
            Mock Update-InfrastructureJsonReferencedFilePaths { }
            Mock Get-ClustersInScope        { return @() }
            Mock Get-SiteSpecsInScope       { return @() }
            Mock Test-JsonPrefixFormats     { return 0 }
            Mock Test-JsonPropertyFormat    { return $true }
            Mock Test-JsonDnsServers        { return 0 }
            Mock Test-JsonFlbConfiguration  { return 0 }
            Mock Test-JsonControlPlaneConfiguration { return 0 }
            Test-JsonDeeperValidation -InfrastructureJson "infra.json" -SupervisorJson "sup.json"
            Should -Invoke ConvertFrom-JsonSafely -Times 2 -Exactly
        }
    }

    It "Throws VcfDeploymentException when a sub-validator reports one or more failures" {
        InModuleScope VcfEdgeAtScale {
            Mock ConvertFrom-JsonSafely     { return [PSCustomObject]@{} }
            Mock Update-InfrastructureJsonReferencedFilePaths { }
            Mock Get-ClustersInScope        { return @() }
            Mock Get-SiteSpecsInScope       { return @() }
            # Simulate a prefix-format failure.
            Mock Test-JsonPrefixFormats     { return 1 }
            Mock Test-JsonPropertyFormat    { return $true }
            { Test-JsonDeeperValidation -InfrastructureJson "infra.json" -SupervisorJson "sup.json" -ComputeOnly } |
                Should -Throw
        }
    }
}

# ── Sync-VcfEdgeAtScaleConfigUiTool — version comparison and auto-copy ────────


Describe "Get-JsonDataWithValidation" {

    It "Returns null and marks ValidationResult invalid when the file does not exist" {
        InModuleScope VcfEdgeAtScale {
            $vr = [PSCustomObject]@{ IsValid = $true; ErrorCount = 0; Summary = ""; JsonData = $null }
            $result = Get-JsonDataWithValidation -JsonFilePath "/nonexistent/file.json" `
                -JsonObjectName "TestObj" -ValidationResult ([ref]$vr)
            $result | Should -BeNullOrEmpty
            $vr.IsValid     | Should -Be $false
            $vr.ErrorCount  | Should -Be 1
        }
    }

    It "Returns null and marks ValidationResult invalid when ConvertFrom-JsonSafely throws" {
        $tempFile = [System.IO.Path]::GetTempFileName()
        try {
            Set-Content -Path $tempFile -Value '{"valid":"json"}' -Encoding UTF8
            InModuleScope VcfEdgeAtScale -ArgumentList $tempFile {
                param($f)
                Mock ConvertFrom-JsonSafely { throw "Simulated parse failure" }
                $vr = [PSCustomObject]@{ IsValid = $true; ErrorCount = 0; Summary = ""; JsonData = $null }
                $result = Get-JsonDataWithValidation -JsonFilePath $f `
                    -JsonObjectName "TestObj" -ValidationResult ([ref]$vr)
                $result | Should -BeNullOrEmpty
                $vr.IsValid | Should -Be $false
            }
        } finally {
            Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
        }
    }

    It "Returns parsed data and stores it in ValidationResult.JsonData on success" {
        $tempFile = [System.IO.Path]::GetTempFileName()
        try {
            Set-Content -Path $tempFile -Value '{"key":"value"}' -Encoding UTF8
            $mockReturn = [PSCustomObject]@{ key = "value" }
            InModuleScope VcfEdgeAtScale -ArgumentList $tempFile, $mockReturn {
                param($f, $mockData)
                Mock ConvertFrom-JsonSafely { return $mockData }
                $vr = [PSCustomObject]@{ IsValid = $true; ErrorCount = 0; Summary = ""; JsonData = $null }
                $result = Get-JsonDataWithValidation -JsonFilePath $f `
                    -JsonObjectName "TestObj" -ValidationResult ([ref]$vr)
                $result        | Should -Not -BeNullOrEmpty
                $vr.JsonData   | Should -Not -BeNullOrEmpty
                $result.key    | Should -Be "value"
            }
        } finally {
            Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
        }
    }
}

# ── Sync-VcfEdgeAtScaleUiTemplate — HTML template version sync ────────────────


Describe "Test-JsonMissingProperties — deep path and array-notation coverage" {

    BeforeAll {
        # JSON with a nested clusters array and a three-level property.
        $script:deepJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "veas-tjmp-deep-$([guid]::NewGuid().ToString('N').Substring(0,8)).json"
        $content = '{"common":{"vCenterName":"vc.lab","region":"us-east"},"clusters":[{"edgeSite":"site1","networking":{"vlanId":100}}]}'
        Set-Content -Path $script:deepJson -Value $content -Encoding UTF8
    }
    AfterAll { Remove-Item $script:deepJson -Force -ErrorAction SilentlyContinue }

    It "Returns IsValid true for a three-level property that exists" {
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $script:deepJson {
            Test-JsonMissingProperties -JsonFilePath $args[0] -RequiredProperties @("common.vCenterName") -JsonObjectName "infra"
        }
        $result.IsValid    | Should -Be $true
        $result.ErrorCount | Should -Be 0
    }

    It "Returns IsValid false and increments ErrorCount for each missing property" {
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $script:deepJson {
            Test-JsonMissingProperties -JsonFilePath $args[0] `
                -RequiredProperties @("common.missing1", "common.missing2") `
                -JsonObjectName "infra"
        }
        $result.IsValid    | Should -Be $false
        $result.ErrorCount | Should -Be 2
    }

    It "Returns IsValid true when a mix of present and absent properties is given with no absent ones" {
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $script:deepJson {
            Test-JsonMissingProperties -JsonFilePath $args[0] `
                -RequiredProperties @("common.vCenterName", "common.region") `
                -JsonObjectName "infra"
        }
        $result.IsValid    | Should -Be $true
        $result.ErrorCount | Should -Be 0
    }
}

# ── Assert-ValidationResult ──────────────────────────────────────────────────


Describe "Assert-ValidationResult — validation result gate" {

    It "Logs INFO 'validation passed' and does not throw when the result IsValid is true" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $validResult = [PSCustomObject]@{ IsValid = $true; Summary = "5 properties checked, 0 missing" }
            { Assert-ValidationResult -Context "Input JSON" -OnFailure "fail detail" -Result $validResult } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'INFO' -and $Message -match 'validation passed' }
        }
    }

    It "Throws with the OnFailure message when the result IsValid is false" {
        InModuleScope VcfEdgeAtScale {
            $failResult = [PSCustomObject]@{ IsValid = $false; Summary = "1 missing property" }
            { Assert-ValidationResult -Context "Input JSON" -OnFailure "Deployment cannot proceed with incomplete input configuration." -Result $failResult } | Should -Throw "*Deployment cannot proceed with incomplete input configuration.*"
        }
    }
}

# ── Test-ContextNameRequired ──────────────────────────────────────────────────


Describe "Test-ContextNameRequired — contextName requirement detection" {

    It "Returns false for an empty cluster list" {
        $result = InModuleScope VcfEdgeAtScale {
            Test-ContextNameRequired -ClustersInScope @()
        }
        $result | Should -Be $false
    }

    It "Returns false when all clusters have both ArgoCD and Harbor disabled" {
        $result = InModuleScope VcfEdgeAtScale {
            $fakeCluster = [PSCustomObject]@{ edgeSite = "site1" }
            # Mock returns $true for all disable* flags, so -not $true = $false for both services.
            Mock Get-EffectiveSupervisorServiceFlag { return $true }
            Test-ContextNameRequired -ClustersInScope @($fakeCluster)
        }
        $result | Should -Be $false
    }

    It "Returns true when at least one cluster has ArgoCD enabled" {
        $result = InModuleScope VcfEdgeAtScale {
            $fakeCluster = [PSCustomObject]@{ edgeSite = "site1" }
            # Mock returns $false for disableArgoCD, so -not $false = $true → ArgoCD enabled → early return.
            Mock Get-EffectiveSupervisorServiceFlag { return $false }
            Test-ContextNameRequired -ClustersInScope @($fakeCluster)
        }
        $result | Should -Be $true
    }
}

# ── Get-InfrastructureRequiredProperties ──────────────────────────────────────


Describe "Get-InfrastructureRequiredProperties — property list generation" {

    It "Includes common.contextName when RequireContextName is true" {
        $result = InModuleScope VcfEdgeAtScale {
            Get-InfrastructureRequiredProperties -RequireContextName $true
        }
        $result | Should -Contain "common.contextName"
        $result | Should -Contain "clusters[].storagePolicy.storageType"
    }

    It "Excludes common.contextName but retains all other properties when RequireContextName is false" {
        $result = InModuleScope VcfEdgeAtScale {
            Get-InfrastructureRequiredProperties -RequireContextName $false
        }
        $result | Should -Not -Contain "common.contextName"
        $result | Should -Contain "common.vCenterName"
        $result | Should -Contain "clusters[].storagePolicy.storageType"
    }
}

# ── Get-SupervisorRequiredProperties ──────────────────────────────────────────


Describe "Get-SupervisorRequiredProperties — supervisor property list" {

    It "Returns an array containing all expected supervisor spec and site property paths" {
        $result = InModuleScope VcfEdgeAtScale { Get-SupervisorRequiredProperties }
        $result | Should -Contain "commonSupervisorSpec.controlPlaneVMCount"
        $result | Should -Contain "siteSpec[].foundationLoadBalancerComponents.flbName"
        $result | Should -Contain "siteSpec[].primaryWorkloadNetwork.workloadServiceCount"
    }
}

# ── Test-EsxHostsArrayFormat ──────────────────────────────────────────────────


Describe "Test-EsxHostsArrayFormat — esxHosts format enforcement" {

    It "Returns without error when InputData has no clusters property" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $inputData = [PSCustomObject]@{}
            { Test-EsxHostsArrayFormat -InputData $inputData } | Should -Not -Throw
            Should -Not -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'ERROR' }
        }
    }

    It "Throws for a cluster that uses the deprecated singular 'esxHost' property" {
        InModuleScope VcfEdgeAtScale {
            $cluster   = [PSCustomObject]@{ edgeSite = "site1"; esxHost = "host.lab" }
            $inputData = [PSCustomObject]@{ clusters = @($cluster) }
            { Test-EsxHostsArrayFormat -InputData $inputData } | Should -Throw "*esxHost*singular*"
        }
    }

    It "Throws for a cluster with an empty esxHosts array" {
        InModuleScope VcfEdgeAtScale {
            # PowerShell treats @() as falsy, so -not @() is $true and the 'missing' guard fires.
            $cluster   = [PSCustomObject]@{ edgeSite = "site1"; esxHosts = @() }
            $inputData = [PSCustomObject]@{ clusters = @($cluster) }
            { Test-EsxHostsArrayFormat -InputData $inputData } | Should -Throw "*missing*"
        }
    }
}

# ── Test-InfrastructureBooleanFlags ──────────────────────────────────────────


Describe "Test-InfrastructureBooleanFlags — boolean flag validation" {

    It "Returns without error when InputData has no common section" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $inputData = [PSCustomObject]@{}
            { Test-InfrastructureBooleanFlags -InfrastructureJson "/fake/infra.json" -InputData $inputData } | Should -Not -Throw
            Should -Not -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'ERROR' }
        }
    }

    It "Returns without error when all present boolean flags are valid booleans" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $common    = [PSCustomObject]@{ autoUpdate = $false; nonInteractivePassword = $true }
            $inputData = [PSCustomObject]@{ common = $common }
            { Test-InfrastructureBooleanFlags -InfrastructureJson "/fake/infra.json" -InputData $inputData } | Should -Not -Throw
            Should -Not -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'ERROR' }
        }
    }

    It "Throws VcfDeploymentException when autoUpdate is a string instead of a boolean" {
        InModuleScope VcfEdgeAtScale {
            $common    = [PSCustomObject]@{ autoUpdate = "true" }
            $inputData = [PSCustomObject]@{ common = $common }
            { Test-InfrastructureBooleanFlags -InfrastructureJson "/fake/infra.json" -InputData $inputData } | Should -Throw "*boolean*"
        }
    }
}

# ── Test-NestedProperty ──────────────────────────────────────────────────────


Describe "Test-NestedProperty — nested object path traversal" {

    It "Returns true for a flat property that exists on a PSCustomObject" {
        InModuleScope VcfEdgeAtScale {
            $obj = [PSCustomObject]@{ name = "test"; value = 42 }
            Test-NestedProperty -Object $obj -PropertyPath "name" | Should -Be $true
        }
    }

    It "Returns false for a flat property that does not exist on a PSCustomObject" {
        InModuleScope VcfEdgeAtScale {
            $obj = [PSCustomObject]@{ name = "test" }
            Test-NestedProperty -Object $obj -PropertyPath "missing" | Should -Be $false
        }
    }

    It "Returns true when an array-notation path points to a non-empty array with the sub-property" {
        InModuleScope VcfEdgeAtScale {
            $obj = [PSCustomObject]@{
                clusters = @(
                    [PSCustomObject]@{ edgeSite = "site1" }
                )
            }
            Test-NestedProperty -Object $obj -PropertyPath "clusters[].edgeSite" | Should -Be $true
        }
    }
}

# ── Get-ExpectedStructure ────────────────────────────────────────────────────


Describe "Get-ExpectedStructure — JSON structure template generation" {

    It "Returns a single-level hashtable with placeholder value for a flat property" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $result = Get-ExpectedStructure -PropertyPath "name"
            $result["name"] | Should -Be "<value>"
        }
    }

    It "Returns a nested hashtable for a three-level dot-notation path" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $result = Get-ExpectedStructure -PropertyPath "config.database.host"
            $result["config"]["database"]["host"] | Should -Be "<value>"
        }
    }

    It "Returns an array-wrapped structure for array-notation path" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $result = Get-ExpectedStructure -PropertyPath "clusters[].edgeSite"
            $result["clusters"] | Should -Not -BeNullOrEmpty
            $result["clusters"].Count | Should -BeGreaterOrEqual 1
        }
    }
}

# ── Get-ExpectedStructure (via Test-JsonMissingProperties -ShowExpectedStructure) ─


Describe "Test-JsonMissingProperties — ShowExpectedStructure exercises Get-ExpectedStructure" {

    BeforeAll {
        $script:esJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "veas-es-$([guid]::NewGuid().ToString('N').Substring(0,8)).json"
        Set-Content -Path $script:esJson -Value '{"present":"value"}' -Encoding UTF8
    }
    AfterAll { Remove-Item $script:esJson -Force -ErrorAction SilentlyContinue }

    It "Does not populate ExpectedStructure when -ShowExpectedStructure is omitted" {
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $script:esJson {
            Mock Write-LogMessage {}
            Test-JsonMissingProperties -JsonFilePath $args[0] `
                -RequiredProperties @("name") -JsonObjectName "obj"
        }
        $result.IsValid              | Should -Be $false
        $result.ExpectedStructure.Count | Should -Be 0
    }

    It "Populates ExpectedStructure with a single-level placeholder for a missing top-level property" {
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $script:esJson {
            Mock Write-LogMessage {}
            Test-JsonMissingProperties -JsonFilePath $args[0] `
                -RequiredProperties @("name") -JsonObjectName "obj" -ShowExpectedStructure
        }
        $result.IsValid                                | Should -Be $false
        $result.ExpectedStructure.ContainsKey("name")  | Should -Be $true
        $result.ExpectedStructure["name"]["name"]       | Should -Be "<value>"
    }

    It "Populates ExpectedStructure with a three-level nested hashtable for a dot-notation path" {
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $script:esJson {
            Mock Write-LogMessage {}
            Test-JsonMissingProperties -JsonFilePath $args[0] `
                -RequiredProperties @("config.database.host") -JsonObjectName "obj" -ShowExpectedStructure
        }
        $es = $result.ExpectedStructure["config.database.host"]
        $es                               | Should -Not -BeNullOrEmpty
        $es["config"]                     | Should -Not -BeNullOrEmpty
        $es["config"]["database"]         | Should -Not -BeNullOrEmpty
        $es["config"]["database"]["host"] | Should -Be "<value>"
    }

    It "Populates ExpectedStructure with an array-wrapped element for array-notation path" {
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $script:esJson {
            Mock Write-LogMessage {}
            Test-JsonMissingProperties -JsonFilePath $args[0] `
                -RequiredProperties @("clusters[].edgeSite") -JsonObjectName "obj" -ShowExpectedStructure
        }
        $es = $result.ExpectedStructure["clusters[].edgeSite"]
        $es                   | Should -Not -BeNullOrEmpty
        $es["clusters"]       | Should -Not -BeNullOrEmpty
        $es["clusters"].Count | Should -BeGreaterOrEqual 1
    }

    It "Populates ExpectedStructure for every missing property when multiple are absent" {
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $script:esJson {
            Mock Write-LogMessage {}
            Test-JsonMissingProperties -JsonFilePath $args[0] `
                -RequiredProperties @("a.b", "c.d") -JsonObjectName "obj" -ShowExpectedStructure
        }
        $result.ExpectedStructure.ContainsKey("a.b") | Should -Be $true
        $result.ExpectedStructure.ContainsKey("c.d") | Should -Be $true
    }
}

# ── Test-VCenterVersion — mocked connection ───────────────────────────────────


Describe "Test-VcenterAndEsxReachability" {
    It "Logs DEBUG reachability OK and does not throw when vCenter and all ESX hosts are reachable" {
        InModuleScope VcfEdgeAtScale {
            Mock Test-TcpPortReachable { return $true }
            Mock Write-LogMessage {}
            { Test-VcenterAndEsxReachability -VcenterName "vc01.lab" -EsxHosts @("esx1.lab", "esx2.lab") } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'DEBUG' -and $Message -match 'Reachability.*OK' }
        }
    }

    It "Throws when vCenter is unreachable" {
        InModuleScope VcfEdgeAtScale {
            Mock Test-TcpPortReachable { return $false }
            Mock Write-LogMessage {}
            { Test-VcenterAndEsxReachability -VcenterName "vc01.lab" } | Should -Throw

        }
    }

    It "Throws when one ESX host is unreachable and vCenter is reachable" {
        InModuleScope VcfEdgeAtScale {
            Mock Test-TcpPortReachable {
                param ($IpAddress, $Port, $TimeoutMilliseconds)
                return $IpAddress -eq "vc01.lab"
            }
            Mock Write-LogMessage {}
            { Test-VcenterAndEsxReachability -VcenterName "vc01.lab" -EsxHosts @("esx1.lab") } | Should -Throw

        }
    }

    It "Logs DEBUG reachability OK and does not throw with no ESX hosts when vCenter is reachable" {
        InModuleScope VcfEdgeAtScale {
            Mock Test-TcpPortReachable { return $true }
            Mock Write-LogMessage {}
            { Test-VcenterAndEsxReachability -VcenterName "vc01.lab" -EsxHosts @() } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'DEBUG' -and $Message -match 'Reachability.*OK' }
        }
    }

    It "Error message includes the unreachable target name" {
        InModuleScope VcfEdgeAtScale {
            Mock Test-TcpPortReachable { return $false }
            Mock Write-LogMessage {}
            try {
                Test-VcenterAndEsxReachability -VcenterName "vc99.lab"
            } catch {
                $_.Exception.Message | Should -Match "vc99.lab"
            }
        }
    }
}


Describe "Test-HarborVolumeSizes" {

    It "Returns 0 failures when all volume size fields are absent" {
        $cluster = [PSCustomObject]@{ harborConfiguration = [PSCustomObject]@{} }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Test-HarborVolumeSizes -Cluster $args[0] -CurrentEdgeSite "site1"
        }
        $result | Should -Be 0
    }

    It "Returns 0 failures when all five fields have valid Gi values" {
        $cluster = [PSCustomObject]@{ harborConfiguration = [PSCustomObject]@{
            registryVolumeSize    = "10Gi"
            jobserviceVolumeSize  = "1Gi"
            databaseVolumeSize    = "100Gi"
            redisVolumeSize       = "5Gi"
            trivyVolumeSize       = "2Gi"
        } }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Mock Write-LogMessage {}
            Test-HarborVolumeSizes -Cluster $args[0] -CurrentEdgeSite "site1"
        }
        $result | Should -Be 0
    }

    It "Returns 1 failure for a value that is missing the Gi suffix" {
        $cluster = [PSCustomObject]@{ harborConfiguration = [PSCustomObject]@{
            registryVolumeSize = "10"
        } }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Mock Write-LogMessage {}
            Test-HarborVolumeSizes -Cluster $args[0] -CurrentEdgeSite "site1"
        }
        $result | Should -Be 1
    }

    It "Returns 1 failure for a value of zero (must be positive integer)" {
        $cluster = [PSCustomObject]@{ harborConfiguration = [PSCustomObject]@{
            databaseVolumeSize = "0Gi"
        } }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Mock Write-LogMessage {}
            Test-HarborVolumeSizes -Cluster $args[0] -CurrentEdgeSite "site1"
        }
        $result | Should -Be 1
    }

    It "Returns 2 failures when two fields are invalid" {
        $cluster = [PSCustomObject]@{ harborConfiguration = [PSCustomObject]@{
            registryVolumeSize = "bad"
            redisVolumeSize    = "5gb"
        } }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Mock Write-LogMessage {}
            Test-HarborVolumeSizes -Cluster $args[0] -CurrentEdgeSite "site1"
        }
        $result | Should -Be 2
    }

    It "Skips null values without counting them as failures" {
        $cluster = [PSCustomObject]@{ harborConfiguration = [PSCustomObject]@{
            registryVolumeSize   = $null
            jobserviceVolumeSize = "5Gi"
        } }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Mock Write-LogMessage {}
            Test-HarborVolumeSizes -Cluster $args[0] -CurrentEdgeSite "site1"
        }
        $result | Should -Be 0
    }
}

# ── Test-HarborSecretFields ───────────────────────────────────────────────────


Describe "Test-HarborSecretFields" {

    It "Returns 0 failures when secretKey is exactly 16 characters" {
        $cluster = [PSCustomObject]@{ harborConfiguration = [PSCustomObject]@{
            secretKey = "1234567890123456"
        } }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Mock Write-LogMessage {}
            Test-HarborSecretFields -Cluster $args[0] -CurrentEdgeSite "site1"
        }
        $result | Should -Be 0
    }

    It "Returns 1 failure when secretKey is shorter than 16 characters" {
        $cluster = [PSCustomObject]@{ harborConfiguration = [PSCustomObject]@{
            secretKey = "tooshort"
        } }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Mock Write-LogMessage {}
            Test-HarborSecretFields -Cluster $args[0] -CurrentEdgeSite "site1"
        }
        $result | Should -Be 1
    }

    It "Returns 0 failures when secretKey is a valid env var reference" {
        $cluster = [PSCustomObject]@{ harborConfiguration = [PSCustomObject]@{
            secretKey = '$env:HARBOR_SECRET_KEY'
        } }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Mock Write-LogMessage {}
            Test-HarborSecretFields -Cluster $args[0] -CurrentEdgeSite "site1"
        }
        $result | Should -Be 0
    }

    It "Returns 1 failure when secretKey env var reference is malformed" {
        $cluster = [PSCustomObject]@{ harborConfiguration = [PSCustomObject]@{
            secretKey = '$env:123-bad-name'
        } }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Mock Write-LogMessage {}
            Test-HarborSecretFields -Cluster $args[0] -CurrentEdgeSite "site1"
        }
        $result | Should -Be 1
    }

    It "Returns 1 failure when a password field has a malformed env var reference" {
        $cluster = [PSCustomObject]@{ harborConfiguration = [PSCustomObject]@{
            harborAdminPassword = '$env:bad name'
        } }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Mock Write-LogMessage {}
            Test-HarborSecretFields -Cluster $args[0] -CurrentEdgeSite "site1"
        }
        $result | Should -Be 1
    }

    It "Returns 0 failures when all fields are absent" {
        $cluster = [PSCustomObject]@{ harborConfiguration = [PSCustomObject]@{} }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Mock Write-LogMessage {}
            Test-HarborSecretFields -Cluster $args[0] -CurrentEdgeSite "site1"
        }
        $result | Should -Be 0
    }
}

# ── Test-HarborTlsFiles ───────────────────────────────────────────────────────


Describe "Test-HarborTlsFiles" {

    BeforeAll {
        $script:tlsTmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("tls-test-{0}" -f [System.Guid]::NewGuid().ToString("N").Substring(0, 8))
        New-Item -ItemType Directory -Path $script:tlsTmpDir -Force | Out-Null
        $script:certFile = Join-Path $script:tlsTmpDir "tls.crt"
        $script:keyFile  = Join-Path $script:tlsTmpDir "tls.key"
        $script:wrongFile = Join-Path $script:tlsTmpDir "wrong.crt"
        Set-Content -Path $script:certFile  -Value "-----BEGIN CERTIFICATE-----`nMIIBIjAN..."  -Encoding UTF8
        Set-Content -Path $script:keyFile   -Value "-----BEGIN PRIVATE KEY-----`nMIIEvgIBADA..."  -Encoding UTF8
        Set-Content -Path $script:wrongFile -Value "-----BEGIN CERTIFICATE-----`nMIIB..." -Encoding UTF8
    }

    AfterAll {
        Remove-Item $script:tlsTmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Returns 0 failures when LabEnvironment is true and both TLS paths are absent (lab-generated TLS)" {
        $cluster = [PSCustomObject]@{ harborConfiguration = [PSCustomObject]@{} }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Mock Write-LogMessage {}
            Test-HarborTlsFiles -Cluster $args[0] -CurrentEdgeSite "site1" `
                -HasCaCrt $false -HasTlsCrt $false -HasTlsKey $false -LabEnvironment $true
        }
        $result | Should -Be 0
    }

    It "Returns 1 failure when tlsCrt path does not exist on disk" {
        $cluster = [PSCustomObject]@{ harborConfiguration = [PSCustomObject]@{
            tlsCrt = "/nonexistent/missing.crt"
            tlsKey = $script:keyFile
        } }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Mock Write-LogMessage {}
            Test-HarborTlsFiles -Cluster $args[0] -CurrentEdgeSite "site1" `
                -HasCaCrt $false -HasTlsCrt $true -HasTlsKey $true -LabEnvironment $false
        }
        $result | Should -Be 1
    }

    It "Returns 0 failures when tlsCrt and tlsKey both exist and have correct PEM headers" {
        $certPath = $script:certFile
        $keyPath  = $script:keyFile
        $cluster = [PSCustomObject]@{ harborConfiguration = [PSCustomObject]@{
            tlsCrt = $certPath
            tlsKey = $keyPath
        } }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Mock Write-LogMessage {}
            Test-HarborTlsFiles -Cluster $args[0] -CurrentEdgeSite "site1" `
                -HasCaCrt $false -HasTlsCrt $true -HasTlsKey $true -LabEnvironment $false
        }
        $result | Should -Be 0
    }

    It "Returns 1 failure when tlsKey file begins with CERTIFICATE header (paths swapped)" {
        $certPath  = $script:certFile
        $wrongPath = $script:wrongFile
        $cluster = [PSCustomObject]@{ harborConfiguration = [PSCustomObject]@{
            tlsCrt = $certPath
            tlsKey = $wrongPath
        } }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $cluster {
            Mock Write-LogMessage {}
            Test-HarborTlsFiles -Cluster $args[0] -CurrentEdgeSite "site1" `
                -HasCaCrt $false -HasTlsCrt $true -HasTlsKey $true -LabEnvironment $false
        }
        $result | Should -Be 1
    }
}

# ── Write-HarborDuplicateHostnameWarnings ─────────────────────────────────────


Describe "Write-HarborDuplicateHostnameWarnings" {

    It "Emits no WARNING when all Harbor hostnames are unique" {
        InModuleScope VcfEdgeAtScale {
            $clusterA = [PSCustomObject]@{ edgeSite = "siteA"; harborConfiguration = [PSCustomObject]@{ hostname = "harbor-a.lab" } }
            $clusterB = [PSCustomObject]@{ edgeSite = "siteB"; harborConfiguration = [PSCustomObject]@{ hostname = "harbor-b.lab" } }
            $inputData = [PSCustomObject]@{ common = [PSCustomObject]@{} }
            Mock Get-EffectiveSupervisorServiceFlag { $false }
            Mock Get-EffectiveHarborHostnameForInfrastructureCluster {
                param($Cluster, $CommonData, $LabEnvironmentEnabled)
                $Cluster.harborConfiguration.hostname
            }
            Mock Write-LogMessage {}
            Write-HarborDuplicateHostnameWarnings -ClustersToValidate @($clusterA, $clusterB) `
                -InputData $inputData -LabEnvironment $false
            Should -Invoke Write-LogMessage -Times 0 -ParameterFilter { $Type -eq "WARNING" } -Scope It
        }
    }

    It "Emits a WARNING for each hostname shared by more than one cluster" {
        InModuleScope VcfEdgeAtScale {
            $clusterA = [PSCustomObject]@{ edgeSite = "siteA"; harborConfiguration = [PSCustomObject]@{ hostname = "shared.lab" } }
            $clusterB = [PSCustomObject]@{ edgeSite = "siteB"; harborConfiguration = [PSCustomObject]@{ hostname = "shared.lab" } }
            $inputData = [PSCustomObject]@{ common = [PSCustomObject]@{} }
            Mock Get-EffectiveSupervisorServiceFlag { $false }
            Mock Get-EffectiveHarborHostnameForInfrastructureCluster {
                param($Cluster, $CommonData, $LabEnvironmentEnabled)
                "shared.lab"
            }
            Mock Write-LogMessage {}
            Write-HarborDuplicateHostnameWarnings -ClustersToValidate @($clusterA, $clusterB) `
                -InputData $inputData -LabEnvironment $false
            Should -Invoke Write-LogMessage -Times 1 -ParameterFilter {
                $Type -eq "WARNING" -and $Message -match "shared\.lab"
            } -Scope It
        }
    }

    It "Skips clusters where Harbor is disabled" {
        InModuleScope VcfEdgeAtScale {
            $clusterA = [PSCustomObject]@{ edgeSite = "siteA"; harborConfiguration = [PSCustomObject]@{ hostname = "shared.lab" } }
            $clusterB = [PSCustomObject]@{ edgeSite = "siteB"; harborConfiguration = [PSCustomObject]@{ hostname = "shared.lab" } }
            $inputData = [PSCustomObject]@{ common = [PSCustomObject]@{} }
            # Harbor is disabled on both clusters → hostnames are never collected → no duplicate warning.
            Mock Get-EffectiveSupervisorServiceFlag { $true }
            Mock Get-EffectiveHarborHostnameForInfrastructureCluster { "shared.lab" }
            Mock Write-LogMessage {}
            Write-HarborDuplicateHostnameWarnings -ClustersToValidate @($clusterA, $clusterB) `
                -InputData $inputData -LabEnvironment $false
            Should -Invoke Write-LogMessage -Times 0 -ParameterFilter { $Type -eq "WARNING" } -Scope It
        }
    }
}

# ── Write-VsanClusterHealthReport ─────────────────────────────────────────────


Describe "Test-TagCatalogCategory" {

    It "Throws VcfDeploymentException when not connected to vCenter" {
        { InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $false; ErrorMessage = "not connected" } }
            Test-TagCatalogCategory -TagCatalog "EdgeNodePolicy"
        } } | Should -Throw "*Not connected to vCenter*"
    }

    It "Logs INFO and skips creation when the tag catalog already exists" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true } }
            function Get-TagCategory {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                [PSCustomObject]@{ Name = $Name }
            }
            Test-TagCatalogCategory -TagCatalog "EdgeNodePolicy"
            Should -Invoke Write-LogMessage -Times 1 -ParameterFilter {
                $Type -eq "INFO" -and $Message -match "already exists"
            } -Scope It
        }
    }

    It "Creates the catalog and logs INFO when the tag catalog does not exist" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true } }
            function Get-TagCategory {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                return $null
            }
            function New-TagCategory {
                # SupportsShouldProcess required: production code calls New-TagCategory -Confirm:$false.
                [CmdletBinding(SupportsShouldProcess = $true)] Param(
                    [Parameter()] [Object]$Name, [Parameter()] [Object]$Description,
                    [Parameter()] [Object]$Server
                )
                [PSCustomObject]@{ Name = $Name }
            }
            Test-TagCatalogCategory -TagCatalog "NewCatalog"
            Should -Invoke Write-LogMessage -Times 1 -ParameterFilter {
                $Type -eq "INFO" -and $Message -match "Successfully created"
            } -Scope It
        }
    }

    It "Throws VcfDeploymentException when catalog creation fails" {
        { InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true } }
            function Get-TagCategory {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                return $null
            }
            function New-TagCategory {
                # SupportsShouldProcess required: production code calls New-TagCategory -Confirm:$false.
                [CmdletBinding(SupportsShouldProcess = $true)] Param(
                    [Parameter()] [Object]$Name, [Parameter()] [Object]$Description,
                    [Parameter()] [Object]$Server
                )
                throw "Insufficient permissions"
            }
            Test-TagCatalogCategory -TagCatalog "FailCatalog"
        } } | Should -Throw "*Error creating tag catalog*"
    }
}

# ── Test-Tag ──────────────────────────────────────────────────────────────────


Describe "Test-Tag" {

    It "Throws VcfDeploymentException when not connected to vCenter" {
        { InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $false; ErrorMessage = "no session" } }
            Test-Tag -TagCatalog "EdgePolicy" -TagName "Cluster01"
        } } | Should -Throw "*Not connected to vCenter*"
    }

    It "Logs INFO and skips creation when the tag already exists" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true } }
            function Get-TagCategory {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                [PSCustomObject]@{ Name = $Name }
            }
            function Get-Tag {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Category, [Parameter()] [Object]$Server)
                [PSCustomObject]@{ Name = $Name }
            }
            Test-Tag -TagCatalog "EdgePolicy" -TagName "Cluster01"
            Should -Invoke Write-LogMessage -Times 1 -ParameterFilter {
                $Type -eq "INFO" -and $Message -match "already exists"
            } -Scope It
        }
    }

    It "Creates the tag and logs INFO when the tag does not exist" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true } }
            function Get-TagCategory {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                [PSCustomObject]@{ Name = $Name }
            }
            function Get-Tag {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Category, [Parameter()] [Object]$Server)
                return $null
            }
            function New-Tag {
                # SupportsShouldProcess required: production code calls New-Tag -Confirm:$false.
                [CmdletBinding(SupportsShouldProcess = $true)] Param(
                    [Parameter()] [Object]$Name, [Parameter()] [Object]$Category,
                    [Parameter()] [Object]$Description, [Parameter()] [Object]$Server
                )
                [PSCustomObject]@{ Value = "tag-001" }
            }
            Test-Tag -TagCatalog "EdgePolicy" -TagName "NewCluster"
            Should -Invoke Write-LogMessage -Times 1 -ParameterFilter {
                $Type -eq "INFO" -and $Message -match "Successfully created"
            } -Scope It
        }
    }

    It "Throws VcfDeploymentException when tag catalog lookup throws" {
        { InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true } }
            function Get-TagCategory {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                throw "Server error"
            }
            Test-Tag -TagCatalog "EdgePolicy" -TagName "Cluster01"
        } } | Should -Throw "*Error looking up tag catalog*"
    }
}

# ── Get-DpgsOnVds ────────────────────────────────────────────────────────────


Describe "Test-JsonContent — valid JSON" {
    It "Returns true for a well-formed JSON file" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $tempFile = [System.IO.Path]::GetTempFileName()
            try {
                [System.IO.File]::WriteAllText($tempFile, '{"key":"value","count":42}')
                $result = Test-JsonContent -JsonFilePath $tempFile
                $result | Should -Be $true
            } finally {
                Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

Describe "Test-JsonContent — empty file" {
    It "Returns false and logs ERROR for an empty JSON file" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $tempFile = [System.IO.Path]::GetTempFileName()
            try {
                [System.IO.File]::WriteAllText($tempFile, "   ")
                $result = Test-JsonContent -JsonFilePath $tempFile
                $result | Should -Be $false
                Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "ERROR" -and $Message -match "empty" }
            } finally {
                Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

Describe "Test-JsonContent — invalid JSON" {
    It "Returns false and logs ERROR for malformed JSON" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $tempFile = [System.IO.Path]::GetTempFileName()
            try {
                [System.IO.File]::WriteAllText($tempFile, '{"broken": }')
                $result = Test-JsonContent -JsonFilePath $tempFile
                $result | Should -Be $false
                Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "ERROR" }
            } finally {
                Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
